#!/usr/bin/env bash
set -euo pipefail

# SessionStart 훅 입력(JSON)을 읽는다. 닫히지 않는 stdin 에서도 1초 뒤 진행한다.
# read 는 EOF·시간 초과에서 비 0 을 돌려주므로 `|| true` 가 필요하다(set -e).
hook_input=""
[[ -t 0 ]] || IFS= read -r -t 1 -d '' hook_input || true

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"
source "${script_dir}/../_state_common.sh"
# 작업 집합 요약(baseline 분기)에 필요 — get_default_branch(_lifecycle_common.sh,
# 로컬 git ref 비교만 한다) 와 tasks_index_*(_tasks_index.sh, 색인 읽기만 한다).
# **`tasks_publish_evidence` 는 여기서 쓰지 않는다** — 아래 `_task_set_summary` 주석 참조.
source "${script_dir}/../lifecycle/_lifecycle_common.sh"
source "${script_dir}/../lifecycle/_tasks_index.sh"
# 기동 상태 표시 문구의 단일 출처(`task_launch_label`) — 함수 정의만 있는 파일이라
# source 자체는 아무 동작도 하지 않습니다(herdr 를 부르지 않습니다).
source "${script_dir}/../lifecycle/session_launch.sh"
# 압축 뒤 autopilot 규칙 재독 안내(함수 정의만, source 시 동작 없음)
source "${script_dir}/_compact_hint.sh"

# lite 는 예전에 이 훅의 별도 사본을 썼으나, 사본에는 작업 집합 요약이 없어 worktree 로 띄운
# 작업이 「대기 중」 으로 보였다. 사본 대신 이 블록만 lite 에 더한다(rules.conf 주석 참조).
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " AI Workflow (Lite) 세션 시작"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ! -f "${project_root}/PROJECT_CONTEXT.md" ]]; then
  echo ""
  echo "WARNING: PROJECT_CONTEXT.md가 없습니다."
  echo "  프로젝트 설정을 먼저 완료하세요."
fi
task_file="${project_root}/CURRENT_TASK.md"

# 줄 전체가 완결된 한 줄 주석(`<!-- ... -->`)이면 값이 아니므로 건너뜁니다. 템플릿·archive 초기본의
# Status·Source FR·Next Step 안내 주석이 값으로 보이지 않게 합니다. 첫 `-->` 가 줄 끝에 있을 때만
# 주석으로 봅니다 — `<!-- a --> 본문 <!-- b -->` 처럼 주석 사이에 본문이 있는 줄은 값으로 남깁니다.
extract_section() {
  local file="$1"
  local section="$2"
  awk -v target="## ${section}" '
    $0 == target { in_section = 1; next }
    in_section && /^## / { exit }
    in_section {
      t = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
      if (substr(t, 1, 4) == "<!--" && length(t) >= 7 && index(t, "-->") == length(t) - 2) next
    }
    in_section { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) print }
  ' "$file"
}

if [[ ! -f "$task_file" ]]; then
  echo "[hooks] CURRENT_TASK.md가 없습니다. 작업 추적이 불가합니다." >&2
  exit 0
fi

task="$(extract_section "$task_file" "Task")"
# Status: task-state 존재 시 task-state 읽기 (v2 2b — 판정 소스 단일화)
# 부재(마이그레이션 전)에만 CURRENT_TASK.md 산문 파싱 fallback
if state_file_exists; then
  status="$(state_read_field "status")"
else
  status="$(extract_section "$task_file" "Status")"
fi
next_step="$(extract_section "$task_file" "Next Step")"

# --- 뒤처짐 임계치 (tasks_list.sh 의 _tl_stale_threshold 와 같은 설정 키를 읽는다) ---
_ss_stale_threshold() {
  local cfg="${project_root}/rd-workflow/config/workflow.json" v=""
  if [[ -f "$cfg" ]]; then
    v="$(sed -n 's/.*"stale_behind_threshold"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg" | head -1)"
  fi
  [[ -n "$v" ]] && printf '%s\n' "$v" || printf '20\n'
}

# --- 진행 중인 작업 집합 요약 ---
#
# 이 worktree 의 task-state 가 baseline(작업 없음, status=대기 중)이고 공유 색인에
# 다른 작업이 있으면, "(설정되지 않음)" 대신 그 작업 집합을 보여준다. 작업 worktree
# 에서 열린 세션(또는 --no-worktree 로 기본 worktree 에 fr 브랜치가 체크아웃된 세션)은
# 그 worktree 의 task-state 가 이미 자신의 작업을 담고 있으므로 이 분기에 들어오지
# 않는다 — 호출부가 status=="대기 중" 일 때만 이 함수를 부른다.
#
# **필터링은 색인의 정적 `state` 필드만 본다 — `tasks_publish_evidence`(git ls-remote
# 로 원격을 조회할 수 있는 함수) 를 이 hook 에서는 호출하지 않는다.** 이 환경에는
# `timeout` 명령이 없어, `origin` 이 설정돼 있기만 하면(도달 가능 여부와 무관)
# `remote_mode=="remote"` 로 잡혀 네트워크가 끊기거나 응답이 없을 때 그 호출이
# 무기한 대기한다. 세션 시작은 모든 세션이 지나는 경로이므로 취소 수단 없는 네트워크
# 대기를 넣을 자리가 아니다 — 정확한 발행 증거 판정은 사용자가 명시적으로 부르는
# `rd task list` 가 맡고, 여기서는 요약과 그 명령으로의 진입점만 제공한다.
#
# 정적 `state` 만 보면 "정리 대기가 아직 색인에 기록되지 않은 작업"이 "진행 중"으로
# 보일 수 있다 — 이는 오도가 아니라 보수적이다(실제로 그 작업은 아직 정리되지 않은
# 상태다). 피해야 하는 반대 방향의 오류(이미 발행됐는데 완료로 보여주는 것)는 없다 —
# `state=cleanup-pending` 은 archive.sh 가 발행을 확정한 뒤에만 쓰므로, 이 필드가
# 아직 없다는 것은 최소한 "발행이 완료됐다고 우리가 알고 있지는 않다"는 뜻이다.
_task_set_summary() {
  local slugs slug fr_ref default_branch threshold state_field
  local wt stage launch_raw launch_label wt_col cnt behind_flag
  local rows="" count=0 need_resolve=0

  default_branch="$(get_default_branch 2>/dev/null)" || default_branch=""
  threshold="$(_ss_stale_threshold)"

  slugs="$(tasks_index_slugs 2>/dev/null)" || slugs=""
  [[ -z "$slugs" ]] && return 1

  while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue

    state_field="$(tasks_index_get "$slug" state 2>/dev/null)" || state_field=""
    [[ "$state_field" == "cleanup-pending" ]] && continue

    fr_ref="$(tasks_index_get "$slug" fr-branch 2>/dev/null)" || fr_ref=""
    [[ -z "$fr_ref" ]] && fr_ref="fr/${slug}"

    git -C "$project_root" rev-parse --verify --quiet "refs/heads/${fr_ref}" >/dev/null 2>&1 || continue

    wt="$(tasks_index_get "$slug" worktree-path 2>/dev/null)" || wt=""
    if [[ -n "$wt" && -d "$wt" ]]; then
      wt_col="$wt"
      stage="$(awk -F'=' '$1=="status"{sub(/^[^=]+=/,"");print;exit}' \
        "${wt}/rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null)" || stage=""
    else
      wt_col="(worktree 없음)"
      stage="$(git -C "$project_root" show "${fr_ref}:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null \
        | awk -F'=' '$1=="status"{sub(/^[^=]+=/,"");print;exit}')" || stage=""
    fi
    [[ -z "$stage" ]] && stage="(알 수 없음)"

    launch_raw="$(tasks_index_get "$slug" launch 2>/dev/null)" || launch_raw=""
    # 표시 문구는 `rd task list` 와 **같은 함수**에서 받습니다.
    # 예전에는 여기에 자체 case 문이 있어 `unknown`·빈 값이 「자동 기동 미수행」으로
    # 떨어졌는데, 그 둘은 "세션이 없다" 가 아니라 "확인되지 않았다" 입니다 — 신뢰 승인
    # 대기나 start 타임아웃으로 **살아 있는** 세션을 없다고 안내하던 자리였습니다.
    launch_label="$(task_launch_label "$launch_raw")"
    case "$launch_raw" in
      ok|failed|none) ;;
      *) need_resolve=1 ;;
    esac

    behind_flag=""
    if [[ -n "$default_branch" ]]; then
      cnt="$(git -C "$project_root" rev-list --count "${fr_ref}..${default_branch}" 2>/dev/null)" || cnt=""
      if [[ -n "$cnt" && "$cnt" =~ ^[0-9]+$ && "$cnt" -ge "$threshold" ]]; then
        behind_flag="⚠ ${cnt}커밋 뒤처짐"
      fi
    fi

    count=$((count + 1))
    rows="${rows}  ${slug}\t${stage}\t${wt_col}\t${behind_flag:-$launch_label}\n"
  done <<< "$slugs"

  [[ "$count" -eq 0 ]] && return 1

  echo "[hooks] 진행 중인 작업 ${count}건:"
  printf '%b' "$rows" | column -t -s $'\t' 2>/dev/null || printf '%b' "$rows"
  # 「확인 필요」가 하나라도 있으면 다음 행동을 붙입니다 (F8). 행마다 명령을 붙이면
  # 세션 시작 출력이 길어지므로 한 줄로 모읍니다 — 어느 작업인지는 위 표가 말합니다.
  [[ "$need_resolve" -eq 1 ]] && echo "  (확인 필요: bash rd-workflow/scripts/rd task resolve-launch <slug>)"
  echo "  (상세: bash rd-workflow/scripts/rd task list)"
  return 0
}

if [[ "$status" == "대기 중" || -z "$status" || "$status" == "-" ]] && _task_set_summary; then
  :
else
  [[ "$task" == "-" || -z "$task" ]] && task="(설정되지 않음)"
  [[ "$status" == "-" || -z "$status" ]] && status="(설정되지 않음)"
  [[ "$next_step" == "-" || -z "$next_step" ]] && next_step="(설정되지 않음)"

  echo "[hooks] 현재 작업 상태:"
  echo "  Task: ${task}"
  echo "  Status: ${status}"
  echo "  Next Step: ${next_step}"
fi

compact_hint_emit "$hook_input" "$status" "$(state_read_field short-title)" "$project_root"

# --- diff-review 누락 경고 (Layer 2) ---

if ! is_autopilot_active; then
  review_dir="$(get_latest_diff_review_dir)"

  if [[ -n "$review_dir" ]]; then
    checkpoint="${review_dir}/CHECKPOINT.md"
    if [[ -f "$checkpoint" ]]; then
      has_real_issues="$(awk '
        /^## Open Issues/ { in_section = 1; next }
        in_section && /^## / { exit }
        in_section && /^- / && !/^- 없음/ { found = 1; exit }
        END { print (found ? "yes" : "no") }
      ' "$checkpoint")"

      if [[ "$has_real_issues" == "yes" ]]; then
        echo "[guard] 최신 diff-review에 미해결 이슈가 있습니다." >&2
      fi
    fi
  else
    head_epoch="$(git -C "$project_root" log -1 --format=%ct 2>/dev/null || echo 0)"
    if [[ "$head_epoch" -gt 0 ]]; then
      echo "[guard] diff-review 세션이 없습니다. 새 프로젝트라면 무시해도 됩니다." >&2
    fi
  fi
fi

exit 0
