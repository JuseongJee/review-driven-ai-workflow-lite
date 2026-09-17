#!/usr/bin/env bash
# tasks_list.sh — 진행 중인 모든 작업의 현황(단계·worktree·세션·뒤처짐) 출력.
#   herdr 를 호출하지 않는다 — herdr 유무와 무관하게 같은 출력을 낸다(rd task list).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_tasks_index.sh"
source "$SCRIPT_DIR/session_launch.sh"

# project_root — 주입값 우선(rd 가 이미 export). 없으면 git 저장소 루트(cwd 기준) —
# SCRIPT_DIR 기반 추정은 쓰지 않는다: 독립 실행(테스트) 시 SCRIPT_DIR 는 실제 dev repo
# 경로이고 cwd 는 fixture 저장소일 수 있어, SCRIPT_DIR 기반 추정은 엉뚱한 루트를 가리킨다.
if [[ -z "${project_root:-}" ]]; then
  project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || project_root="$PWD"
fi
cd "$project_root"

source "$SCRIPT_DIR/_lifecycle_common.sh"

REBUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift ;;
    *) echo "tasks_list: 알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------------
_tl_stale_threshold() {
  local cfg="${project_root}/rd-workflow/config/workflow.json"
  local v=""
  if [[ -f "$cfg" ]]; then
    v="$(sed -n 's/.*"stale_behind_threshold"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg" | head -1)"
  fi
  [[ -n "$v" ]] && printf '%s\n' "$v" || printf '20\n'
}

DEFAULT_BRANCH="$(get_default_branch 2>/dev/null)" || DEFAULT_BRANCH=""
REMOTE_MODE="$(detect_remote_mode 2>/dev/null)" || REMOTE_MODE="local-only"
THRESHOLD="$(_tl_stale_threshold)"

# ---------------------------------------------------------------------------
# --rebuild — git 에서 직접 fr ref 를 열거해 색인을 재구성한다.
#   기존 행을 지우지 않는다(키 단위 upsert 만) — cleanup-pending·launch·launch-token 은
#   그 자체로 보존된다(Task 1 계약: upsert 는 넘긴 키만 갱신한다).
# ---------------------------------------------------------------------------
_tl_rebuild() {
  tasks_lock_acquire "tasks-list-rebuild" "-" || {
    echo "tasks_list: --rebuild 락을 얻지 못했습니다 — 다른 작업이 색인을 쓰는 중일 수 있습니다." >&2
    return 1
  }

  # 1) fr ref 를 먼저 열거한다 — 체크아웃된 것만 보면 --no-worktree 작업을 놓친다.
  #
  #    **복구할 수 없는 `launch` 는 `unknown` 으로 둔다** (change spec 159행·D11 판정 4).
  #    rebuild 는 git 에서 ref 만 볼 수 있을 뿐 그 작업에 세션이 떠 있었는지는 모른다 —
  #    그런데 예전에는 이 값을 **아예 쓰지 않아** 새로 복원된 행이 빈 값으로 남았다.
  #    빈 값은 표시상 「확인 필요」지만 promote 의 재착수 판정에서는 「예약 후 기동 시도」
  #    로 떨어지므로, 색인을 잃은 뒤 rebuild 한 사용자가 **살아 있는 세션 위에 두 번째
  #    세션을 띄우게** 된다(review R5 가 막으려던 바로 그 경로가 rebuild 로 열려 있었다).
  #    이미 값이 있는 행은 덮지 않는다 — 그것은 복구할 수 있었던 사실이다.
  local ref slug cur_launch
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    slug="${ref#refs/heads/fr/}"
    [[ -z "$slug" || "$slug" == "$ref" ]] && continue
    tasks_index_upsert "$slug" fr-branch="fr/${slug}" >/dev/null 2>&1 || true
    cur_launch="$(tasks_index_get "$slug" launch 2>/dev/null)" || cur_launch=""
    [[ -z "$cur_launch" ]] && { tasks_index_upsert "$slug" launch=unknown >/dev/null 2>&1 || true; }
  done < <(git for-each-ref --format='%(refname)' 'refs/heads/fr/*' 2>/dev/null)

  # 2) 체크아웃 대조 — git worktree list --porcelain 로 실제 checkout 경로를 찾는다.
  #    여기서 찾은 slug 를 줄 단위로 모아 둔다(bash 3.2 에는 연관배열이 없다). 3) 이
  #    "git 이 체크아웃이라고 말한 작업" 과 그 밖을 가르는 근거다.
  local line wt_path wt_branch
  local found_slugs=""
  wt_path=""; wt_branch=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt_path="${line#worktree }" ;;
      branch\ refs/heads/fr/*)
        wt_branch="${line#branch refs/heads/}"
        slug="${wt_branch#fr/}"
        if [[ -n "$slug" && -n "$wt_path" ]]; then
          tasks_index_upsert "$slug" worktree-path="$wt_path" checkout=yes >/dev/null 2>&1 || true
          found_slugs="${found_slugs}${slug}
"
        fi
        ;;
      "")
        wt_path=""; wt_branch=""
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)

  # 3) fr ref 는 있는데 checkout 대조에서 못 찾은 작업은 checkout=none 으로 **덮어쓴다.**
  #    이전 값(`checkout=yes`)을 조건으로 삼지 않는다 (final diff review F2) — 조건으로
  #    삼으면 한 번 yes 였던 행은 그 경로가 다른 브랜치로 넘어가거나 worktree 가 사라져도
  #    영원히 yes 로 남아, rebuild 가 stale 을 복구하지 못한다. rebuild 의 권위는 git 이다.
  #    (worktree-path 는 손대지 않는다 — 이전에 알던 경로가 있으면 "worktree 없음" 판정에
  #     쓰고, checkout=none 인 행의 경로는 대상 판정에서 어차피 git 대조로 걸러진다.)
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    slug="${ref#refs/heads/fr/}"
    [[ -z "$slug" || "$slug" == "$ref" ]] && continue
    case "
${found_slugs}" in
      *"
${slug}
"*) continue ;;
    esac
    tasks_index_upsert "$slug" checkout=none >/dev/null 2>&1 || true
  done < <(git for-each-ref --format='%(refname)' 'refs/heads/fr/*' 2>/dev/null)

  tasks_lock_release
  return 0
}

[[ "$REBUILD" -eq 1 ]] && _tl_rebuild

# ---------------------------------------------------------------------------
# 발행 증거 판정 (spec D8) — merge 여부는 발행 완료의 증거가 아니다.
#   stdout: in-progress | needs-verify | cleanup-pending
#
# 단일 출처는 `_tasks_index.sh` 의 `tasks_publish_evidence` 다 (2026-09 final diff
# review I2) — promote.sh 의 재착수 판정(D8)도 같은 함수를 쓴다. 이 wrapper 는
# 이 파일 안에서 이미 계산해 둔 DEFAULT_BRANCH·REMOTE_MODE 를 넘기기만 한다.
# ---------------------------------------------------------------------------
_tl_publish_evidence() {
  tasks_publish_evidence "$1" "$2" "$DEFAULT_BRANCH" "$REMOTE_MODE"
}

# ---------------------------------------------------------------------------
# 단계(status) 읽기 — 체크아웃된 작업은 worktree 의 task-state, 비체크아웃(spec D13)은
# fr tip 의 blob 을 읽는다. 지금 checkout 된 baseline task-state 파일을 그대로 읽으면
# 엉뚱한 상태를 보여준다.
# ---------------------------------------------------------------------------
_tl_read_status() {
  local checked_out="$1" wt="$2" fr_ref="$3"
  local raw=""
  if [[ "$checked_out" == "yes" && -n "$wt" && -d "$wt" ]]; then
    raw="$(awk -F'=' '$1=="status"{sub(/^[^=]+=/,""); print; exit}' \
      "${wt}/rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null)" || raw=""
  else
    raw="$(git show "${fr_ref}:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null \
      | awk -F'=' '$1=="status"{sub(/^[^=]+=/,""); print; exit}')" || raw=""
  fi
  [[ -n "$raw" ]] && printf '%s\n' "$raw" || printf '(알 수 없음)\n'
}

# ---------------------------------------------------------------------------
# 세션 열 — launch 값을 한국어로 표시하고, ok 가 아니면 다음 행동 줄을 붙인다.
# ---------------------------------------------------------------------------
# 표시 문구는 `session_launch.sh` 의 `task_launch_label` **한 곳**에서만 만듭니다 (F8).
# 여기에 case 문을 다시 두면 세션 시작 요약과 다시 갈라집니다 — 실제로 갈라졌던 자리입니다.
_tl_launch_label() {  # <launch-raw>
  task_launch_label "${1-}"
}

# **`unknown` 에 기동 명령을 권하지 않는다** (final diff review F1). unknown 은 "세션이
# 없다" 가 아니라 "확인되지 않았다" 이므로, 곧바로 `cd ... && claude` 를 권하면 살아 있는
# 세션 위에 두 번째 세션을 띄우게 된다. 확인·해소·인계 전달을 함께 하는 같은 복구 경로
# (`rd task resolve-launch`)로 연결한다 — 그 명령이 살아 있으면 ok 로 확정하고 인계를
# 전달하며, 죽었으면 failed 로 확정하고 그때 수동 기동 명령을 제시한다.
_tl_launch_action() {  # <slug> <launch-raw> <wt>
  local slug="$1" launch="$2" wt="$3"
  case "$launch" in
    ok) printf '' ;;
    launching|unknown|"")
      printf '→ 확인: rd task resolve-launch %s\n' "$slug" ;;
    failed|none|*)
      if [[ -n "$wt" ]]; then
        printf '→ %s\n' "$(session_launch_command "$wt" "$slug")"
      else
        printf '→ 확인: rd task resolve-launch %s\n' "$slug"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 본문 출력
# ---------------------------------------------------------------------------
SLUGS="$(tasks_index_slugs 2>/dev/null)" || SLUGS=""

MAIN_ROWS=""
PUBLISH_ROWS=""
ANY=0

while IFS= read -r slug; do
  [[ -z "$slug" ]] && continue
  fr_ref="$(tasks_index_get "$slug" fr-branch 2>/dev/null)" || fr_ref=""
  [[ -z "$fr_ref" ]] && fr_ref="fr/${slug}"

  # 색인에 남아 있지만 fr ref 가 실제로 없는(예: fabricated cleanup-pending fixture) 행은
  # "정리 대기" 로 남겨둔 채 별도 구역에 그대로 보여준다 — 삭제하지 않는다.
  state_field="$(tasks_index_get "$slug" state 2>/dev/null)" || state_field=""
  if [[ "$state_field" == "cleanup-pending" ]]; then
    ANY=1
    PUBLISH_ROWS="${PUBLISH_ROWS}${slug}	정리 대기 (기록)	-	-\n"
    continue
  fi

  if ! fr_tip="$(git rev-parse --verify --quiet "refs/heads/${fr_ref}" 2>/dev/null)"; then
    continue
  fi
  ANY=1

  checkout="$(tasks_index_get "$slug" checkout 2>/dev/null)" || checkout=""
  wt="$(tasks_index_get "$slug" worktree-path 2>/dev/null)" || wt=""
  if [[ "$checkout" == "yes" && -n "$wt" && -d "$wt" ]]; then
    checked_out="yes"
  else
    checked_out="no"
  fi

  evidence="$(_tl_publish_evidence "$slug" "$fr_tip")"

  if [[ "$evidence" == "needs-verify" ]]; then
    PUBLISH_ROWS="${PUBLISH_ROWS}${slug}	⚠ 발행 확인 필요	확인: bash rd-workflow/scripts/lifecycle/archive.sh --dry-run	-\n"
    continue
  elif [[ "$evidence" == "cleanup-pending" ]]; then
    PUBLISH_ROWS="${PUBLISH_ROWS}${slug}	정리 대기	git worktree remove ${wt:-<worktree>}	-\n"
    continue
  fi

  # in-progress — 메인 표
  stage="$(_tl_read_status "$checked_out" "$wt" "$fr_ref")"

  if [[ "$checked_out" == "yes" ]]; then
    wt_col="$wt"
  else
    wt_col="(worktree 없음)"
  fi

  launch_raw="$(tasks_index_get "$slug" launch 2>/dev/null)" || launch_raw=""

  behind="-"
  if [[ -n "$DEFAULT_BRANCH" ]]; then
    cnt="$(git rev-list --count "${fr_ref}..${DEFAULT_BRANCH}" 2>/dev/null)" || cnt=""
    if [[ -n "$cnt" && "$cnt" =~ ^[0-9]+$ && "$cnt" -ge "$THRESHOLD" ]]; then
      behind="⚠ ${cnt}커밋"
    fi
  fi

  launch_label="$(_tl_launch_label "$launch_raw")"
  action_wt=""
  [[ "$checked_out" == "yes" ]] && action_wt="$wt"
  # 빈 값을 `none` 으로 바꾸지 않는다 — 표시(label)가 이미 빈 값을 "확인 필요"(unknown)로
  # 다루므로, 행동만 `none`(수동 기동 권유)으로 갈리면 같은 행이 서로 다른 말을 한다.
  action="$(_tl_launch_action "$slug" "$launch_raw" "$action_wt")"

  cleanup_action=""
  if [[ "$checked_out" != "yes" ]]; then
    cleanup_action="→ 정리: git worktree prune"
  fi

  MAIN_ROWS="${MAIN_ROWS}${slug}	${stage}	${wt_col}	${launch_label}	${behind}\n"
  if [[ -n "$action" ]]; then
    MAIN_ROWS="${MAIN_ROWS}	 	 	${action}	\n"
  fi
  if [[ -n "$cleanup_action" ]]; then
    MAIN_ROWS="${MAIN_ROWS}	 	 	${cleanup_action}	\n"
  fi
done <<< "$SLUGS"

if [[ "$ANY" -eq 0 ]]; then
  printf '진행 중인 작업이 없습니다.\n'
  exit 0
fi

if [[ -n "$MAIN_ROWS" ]]; then
  printf '작업\t단계\tworktree\t세션\t뒤처짐\n'
  printf '%b' "$MAIN_ROWS" | column -t -s $'\t' 2>/dev/null || printf '%b' "$MAIN_ROWS"
fi

if [[ -n "$PUBLISH_ROWS" ]]; then
  printf '\n정리 대기 / 발행 확인 필요 (재기동 대상이 아닙니다)\n'
  printf '작업\t상태\t다음 행동\t-\n'
  printf '%b' "$PUBLISH_ROWS" | column -t -s $'\t' 2>/dev/null || printf '%b' "$PUBLISH_ROWS"
fi
