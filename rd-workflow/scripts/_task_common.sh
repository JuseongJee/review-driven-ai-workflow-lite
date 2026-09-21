#!/usr/bin/env bash
# _task_common.sh — task CLI 공용 함수. source 전용 (rd, test_task_cli.sh 사용).
# 정책 준거: docs/v2/policy-spec.md — SEC-01~07, SEC-13, GRD-01/02, LC-18/19/21

_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# project_root — cwd 비의존. 주입값 우선(테스트), 없으면 스크립트 위치 기준.
# 마커(rd-workflow-workspace/)가 없으면 조용히 다른 위치를 루트로 삼지 않고 멈춘다.
# readlink -f / realpath 를 쓰지 않는다 (macOS 부재·환경 차이). 그래서 실행 파일
# 자체가 심볼릭 링크면 마커를 잃고 이 검사에서 걸린다 — 의도된 비지원이다.
if [[ -z "${project_root:-}" ]]; then
  project_root="$(cd "${_TC_DIR}/../.." && pwd)"
fi
if [[ ! -d "${project_root}/rd-workflow-workspace" ]]; then
  echo "프로젝트 루트를 확정할 수 없습니다: '${project_root}' 에 rd-workflow-workspace/ 가 없습니다." >&2
  echo "  스크립트가 프로젝트 구조 밖에 놓여 있거나(사본·잘못된 배치), 실행 파일 자체가 심볼릭 링크일 수 있습니다." >&2
  echo "  확인: ls -d '${project_root}/rd-workflow-workspace'" >&2
  return 3 2>/dev/null || exit 3
fi
export project_root
# 파서 단일화: hooks 공통 파서 재사용 (제3 구현 금지 — spec §3)
source "${_TC_DIR}/hooks/_guard_common.sh"
# slug 정규화 단일 출처 — promote.sh 와 같은 규칙이어야 두 경로가 같은 값을 만든다
source "${_TC_DIR}/lifecycle/slug.sh"
# 작업 집합 색인·락(Task 1) + 세션 기동/조회(Task 2) — task_resolve_target·
# task_resolve_launch 가 이 둘을 함께 쓴다 (rd 의 set-status --task, resolve-launch).
source "${_TC_DIR}/lifecycle/_tasks_index.sh"
source "${_TC_DIR}/lifecycle/session_launch.sh"

# canonical 9종 (LC-19) — `_state_common.sh` 의 STATE_CANONICAL_STATUSES 와 **같은 집합**이어야
# 합니다. 한쪽만 고치면 CLI 는 받아들이는데 권위 파일 검증이 거부하는 어긋난 중간 상태가
# 생깁니다 (self_test 의 LC-19 3자 일치 검증이 이 어긋남을 잡습니다).
# `아카이브 보류` 는 「리뷰 종결·발행 대기」입니다 (change-spec §4.1) — 완료가 아닙니다.
TASK_CANONICAL_STATUSES=("대기 중" "REQUEST review 대기" "spec/plan 작성 중" "spec/plan review 대기" "구현 중" "검증 중" "diff review 대기" "아카이브 보류" "완료")

task_status_canonical() {
  local s="$1" c
  for c in "${TASK_CANONICAL_STATUSES[@]}"; do [[ "$s" == "$c" ]] && return 0; done
  return 1
}

# LC-19 + SEC-13: Status 읽기의 CLI 계약 wrapper.
# canonical → stdout + return 0. legacy alias '실행 중' → stderr warning + stdout 원값 + return 0.
# 빈 값(섹션 부재/파싱 불가) 또는 비canonical → return 3 (상태 파일 파손 — fail-closed).
task_read_status() {
  local s
  s="$(get_task_status)"
  [[ -z "$s" ]] && return 3
  if [[ "$s" == "실행 중" ]]; then
    echo "경고: Status '실행 중' 은 legacy alias 입니다 (canonical: '구현 중')." >&2
    printf '%s\n' "$s"
    return 0
  fi
  task_status_canonical "$s" || return 3
  printf '%s\n' "$s"
}

# SEC-01: 조상 경로 component 단위 symlink 방어 (단일 구현 — 기존 6개 사본 대체)
assert_no_symlink_in_path() {
  local p="$1" d
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  d="$p"
  while [[ "$d" != "/" && -n "$d" ]]; do
    if [[ -L "$d" ]]; then
      echo "경고: path component ($d) 가 symlink 입니다. 보안상 중단합니다." >&2
      return 1
    fi
    d="$(dirname "$d")"
  done
  return 0
}

# LC-19/21: 상태 전이표 — 단일 출처 (spec §5). 모든 상태→'대기 중'은 중단/rollback 경로(LC-14).
# '구현 중→spec/plan 작성 중'은 autopilot 모드 B→A 중간 승격 경로 (autopilot SKILL.md "실행 모드" 참조).
# '아카이브 보류'(change-spec §4.1)는 리뷰 종결과 발행 사이의 상태다. 'diff review 대기' 에서
# 들어와 '완료' 로 나가며, '구현 중' 으로 되돌아갈 수도 있다 — 리뷰 후 변경이 필요해진 경우이고,
# 그때는 보호 트리 해시 판정이 기존 종결을 무효로 만든다.
task_transition_allowed() {
  local from="$1" to="$2"
  [[ "$to" == "대기 중" ]] && return 0
  case "${from}→${to}" in
    "대기 중→REQUEST review 대기"|"대기 중→구현 중"|\
    "REQUEST review 대기→spec/plan 작성 중"|\
    "spec/plan 작성 중→spec/plan review 대기"|\
    "spec/plan review 대기→spec/plan 작성 중"|"spec/plan review 대기→구현 중"|\
    "구현 중→spec/plan 작성 중"|\
    "구현 중→검증 중"|"검증 중→구현 중"|"검증 중→diff review 대기"|\
    "diff review 대기→구현 중"|"diff review 대기→완료"|\
    "diff review 대기→아카이브 보류"|"아카이브 보류→완료"|\
    "아카이브 보류→구현 중") return 0 ;;
  esac
  return 1
}

task_set_status() {
  local to="$1" force="${2:-0}" from rc=0
  if ! task_status_canonical "$to"; then
    echo "허용되지 않은 Status 값: ${to} (canonical 9종만 허용 — LC-19)" >&2
    return 4
  fi
  from="$(task_read_status)" || {
    echo "CURRENT_TASK.md ## Status 파싱 불가 또는 비canonical 값 (상태 파일 파손)" >&2
    return 3
  }
  # legacy alias '실행 중' 은 전이 판정에서 '구현 중' 으로 간주 (파일에는 기록하지 않음)
  [[ "$from" == "실행 중" ]] && from="구현 중"
  if [[ "$from" != "$to" ]] && ! task_transition_allowed "$from" "$to"; then
    if [[ "$force" == "1" ]]; then
      echo "경고: 전이표 외 전이(${from} → ${to})를 --force로 수행합니다." >&2
    else
      echo "전이표 위반: ${from} → ${to} (--force로 우회 가능)" >&2
      return 4
    fi
  fi
  # 미러 섹션 부재를 **권위 쓰기 전에** 잡는다 (final diff review Finding 2).
  # `_task_section_write` 가 섹션 부재를 실패로 바꾼 뒤부터, 뒤에서 잡으면 task-state 는
  # 새 값이고 미러는 그대로인 부분 갱신이 남는다. `|| rc=$?` 는 코드를 보존할 뿐
  # 선행 쓰기를 되돌리지 않는다.
  # 이 검사가 `task_read_status` 로 대체되지 않는 이유: `get_task_status` 는 task-state 가
  # 있으면 그것만 읽으므로 미러의 `## Status` 부재를 보지 못한다.
  if ! _task_section_exists "Status"; then
    echo "set-status: CURRENT_TASK.md 에 '## Status' 섹션이 없어 중단합니다 (상태 변경 없음)." >&2
    echo "  미러가 baseline 형식이 아닙니다. 확인: grep -n '^## ' '${project_root}/CURRENT_TASK.md'" >&2
    return 3
  fi
  # task-state 갱신 (권위) + CURRENT_TASK.md 뷰 미러링 (결정 3: LC-18 3-way 계약 유지)
  if state_file_exists; then
    state_write_fields "status=${to}" || return 3
  fi
  _task_section_write "Status" "$to" || rc=$?
  return "$rc"
}

# _task_worktree_matches_slug <worktree-path> <slug> — 그 경로가 **git 에 실제로 등록된**
# worktree 이고 그 체크아웃이 `fr/<slug>` 인지 확인한다 (final diff review F2).
#
# 색인의 `worktree-path` 는 캐시일 뿐 권위가 아니다. 디렉터리 존재만 보면 ① 그 경로가
# 다른 fr 브랜치로 switch 됐거나 ② 예전 경로가 다른 작업에 재사용된 상태를 구분하지
# 못하고, 그대로 쓰기·삭제 대상으로 승인하면 **요청하지 않은 다른 작업의 worktree·
# 브랜치·task-state 를 건드린다**. 권위는 git 이므로 `git worktree list --porcelain`
# 으로 대조한다 — 불일치면 그 경로를 체크아웃으로 인정하지 않는다.
#
# return: 0 일치 / 1 불일치(경로 미등록·다른 브랜치·git 조회 불가)
_task_worktree_matches_slug() {  # <worktree-path> <slug>
  local want_path="${1:-}" want_slug="${2:-}"
  [[ -n "$want_path" && -n "$want_slug" ]] || return 1
  local want_real=""
  want_real="$(cd "$want_path" 2>/dev/null && pwd -P)" || return 1

  local line cur_path="" cur_branch="" cur_real=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        cur_path="${line#worktree }"
        ;;
      "branch refs/heads/"*)
        cur_branch="${line#branch refs/heads/}"
        if [[ "$cur_branch" == "fr/${want_slug}" && -n "$cur_path" ]]; then
          cur_real="$(cd "$cur_path" 2>/dev/null && pwd -P)" || cur_real=""
          if [[ -n "$cur_real" && "$cur_real" == "$want_real" ]]; then
            return 0
          fi
        fi
        ;;
    esac
  done < <(git -C "${project_root}" worktree list --porcelain 2>/dev/null)
  return 1
}

# _task_branch_checkout_path <branch> — 그 브랜치를 체크아웃하고 있는 worktree 경로를
# git 에서 찾아 출력한다(없으면 빈 값 + return 1). 색인이 "비체크아웃" 이라고 말하는데
# git 은 어딘가에 체크아웃돼 있다고 말하는 불일치를 호출부가 잡을 수 있게 한다.
_task_branch_checkout_path() {  # <branch>
  local want="${1:-}"
  [[ -n "$want" ]] || return 1
  local line cur_path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur_path="${line#worktree }" ;;
      "branch refs/heads/"*)
        if [[ "${line#branch refs/heads/}" == "$want" && -n "$cur_path" ]]; then
          printf '%s\n' "$cur_path"
          return 0
        fi
        ;;
    esac
  done < <(git -C "${project_root}" worktree list --porcelain 2>/dev/null)
  return 1
}

# task_resolve_target <op:read|write> [<slug>] — 여러 worktree 작업 중 대상 선택 (spec D4·D13)
# 단일 출처: archive.sh·promote_rollback.sh 도 이 함수를 source 해 쓴다 — 판정 로직을
# 복제하지 않는다.
#
#   read  stdout: "checkout\t<worktree-path>" (체크아웃됨) 또는 "ref\tfr/<slug>" (비체크아웃
#         — spec D13, fr tip 의 blob 을 읽으라는 신호일 뿐 이 함수는 blob 을 읽지 않는다)
#   write stdout: "<worktree-path>" (체크아웃된 worktree 만 — 비체크아웃은 오류로 끝낸다)
#
# 대상 선택 규칙 (spec D4):
#   - <slug> 명시: 그 작업이 대상이다. 현재 worktree 가 다른 작업의 checkout 이면 **경고
#     후 진행**한다 (거부가 아니다 — `--no-worktree` 로 기본 checkout 이 작업 worktree가
#     되면 다른 작업을 관리할 진입점이 사라지기 때문).
#   - 미지정 + 현재 worktree 가 어느 작업의 checkout: 그 작업이 기본 대상 (재확인 없음).
#   - 미지정 + 색인에 작업이 없음(0건): **하위 호환** — 이 worktree 자체를 단일 작업으로
#     간주한다 (색인을 쓰지 않는 기존 단일 worktree 사용자·no-fr 직접 작업의 동작을
#     그대로 유지한다). **단, 색인 파일이 실제로 존재하는데**(이 저장소에서 worktree
#     동시 진행 기능을 써 본 적이 있는데) **마침 0건이고, 현재 worktree 가 fr 브랜치가
#     아니면** fallback 하지 않는다(final diff review 지적, AC 4). 기본 브랜치 worktree
#     는 baseline 이지 작업을 대표하지 않는다 — 그 상태에서 자기 자신을 대상 삼으면
#     baseline task-state·CURRENT_TASK.md 를 마치 작업인 양 갱신하게 된다. 색인 파일
#     자체가 없으면(git 저장소가 아닌 단위 테스트, 색인 기능을 전혀 안 써 본 저장소,
#     no-fr 모드로만 쓰는 저장소) 이 검사를 적용하지 않는다 — "기본 브랜치인지" 가
#     애초에 무의미한 맥락이고(no-fr 모드는 정의상 기본 브랜치에서 직접 작업한다), 여기서
#     막으면 색인을 전혀 모르는 기존 사용자가 전부 깨진다.
#   - 미지정 + 색인에 작업이 2건 이상이고 현재 worktree 가 그중 무엇도 아님: 무엇도 고르지
#     않고 목록 + `--task` 안내와 함께 실패한다 (상태를 바꾸지 않는다).
#
# return: 0 성공 / 1 대상 판정 불가(작업 없음이 아니라 다건 미지정) / 2 write인데 비체크아웃
task_resolve_target() {
  local op="$1" explicit="${2:-}"
  local cwd_real="" cwd_slug="" s wt_path wt_real

  cwd_real="$(cd "${project_root}" 2>/dev/null && pwd -P)" || cwd_real=""

  local slugs
  slugs="$(tasks_index_slugs 2>/dev/null)" || slugs=""
  if [[ -n "$cwd_real" && -n "$slugs" ]]; then
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      wt_path="$(tasks_index_get "$s" worktree-path 2>/dev/null)" || wt_path=""
      [[ -z "$wt_path" || ! -d "$wt_path" ]] && continue
      wt_real="$(cd "$wt_path" 2>/dev/null && pwd -P)" || continue
      # 경로가 같다는 것만으로 "여기가 그 작업" 이라고 보지 않는다 — 그 체크아웃이
      # 실제로 fr/<s> 여야 한다(F2). 색인이 낡아 다른 작업의 경로를 들고 있으면
      # 여기서 걸러진다.
      if [[ "$wt_real" == "$cwd_real" ]] && _task_worktree_matches_slug "$wt_path" "$s"; then
        cwd_slug="$s"
        break
      fi
    done <<< "$slugs"
  fi

  local target_slug=""
  if [[ -n "$explicit" ]]; then
    target_slug="$explicit"
    if [[ -n "$cwd_slug" && "$cwd_slug" != "$explicit" ]]; then
      echo "경고: 현재 worktree 의 작업(${cwd_slug})이 아니라 다른 작업(${explicit})을 대상으로 합니다." >&2
    fi
  elif [[ -n "$cwd_slug" ]]; then
    target_slug="$cwd_slug"
  else
    local count=0 only=""
    if [[ -n "$slugs" ]]; then
      while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        count=$((count + 1))
        only="$s"
      done <<< "$slugs"
    fi
    if [[ "$count" -eq 0 ]]; then
      # 색인을 쓰지 않는 기존 단일 worktree 사용(no-fr 직접 작업 포함) — 이 worktree
      # 자체가 대상이다. 단, **색인 파일이 실제로 존재하는데(=이 저장소에서 worktree
      # 동시 진행 기능을 써 본 적이 있는데) 마침 0건이고, 현재 worktree 가 fr 브랜치가
      # 아닐 때는** fallback 하지 않는다(final diff review 지적, AC 4). 기본 브랜치
      # worktree 는 baseline 이지 작업을 대표하지 않는다 — "색인이 0건" 만으로 자기
      # 자신을 대상 삼으면 baseline task-state·CURRENT_TASK.md 를 마치 작업인 양
      # 갱신해 AC 4 를 깬다.
      #   색인 파일 자체가 없으면(이 저장소가 worktree 기능을 아예 안 써 본 경우 — git
      #   저장소가 아닌 단위 테스트 fixture, no-fr 모드로만 쓰는 저장소 등) 이 검사를
      #   적용하지 않는다. 그 경우 "기본 브랜치인지" 는 애초에 무의미한 질문이고
      #   (no-fr 모드는 정의상 기본 브랜치에서 직접 작업한다), 여기서 막으면 색인을
      #   전혀 모르는 기존 단일 worktree·no-fr 사용자가 전부 깨진다.
      local idx_path="" idx_exists=0
      idx_path="$(tasks_index_path 2>/dev/null)" || idx_path=""
      [[ -n "$idx_path" && -f "$idx_path" ]] && idx_exists=1
      local blocked=0
      if [[ "$idx_exists" -eq 1 ]]; then
        local cur_branch=""
        cur_branch="$(git -C "${project_root}" symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur_branch=""
        [[ "$cur_branch" != fr/* ]] && blocked=1
      fi
      if [[ "$blocked" -eq 1 ]]; then
        echo "진행 중인 작업이 없습니다." >&2
        return 1
      fi
      if [[ "$op" == "write" ]]; then
        printf '%s\n' "$project_root"
      else
        printf 'checkout\t%s\n' "$project_root"
      fi
      return 0
    elif [[ "$count" -gt 1 ]]; then
      echo "진행 중인 작업이 여러 건입니다 — --task <slug> 로 대상을 지정하세요:" >&2
      while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        echo "  - $s" >&2
      done <<< "$slugs"
      return 1
    else
      target_slug="$only"
    fi
  fi

  wt_path="$(tasks_index_get "$target_slug" worktree-path 2>/dev/null)" || wt_path=""
  # 권위는 색인이 아니라 git 이다 (F2) — 디렉터리 존재만으로 체크아웃을 인정하지 않는다.
  local checked_out=0
  if [[ -n "$wt_path" && -d "$wt_path" ]] && _task_worktree_matches_slug "$wt_path" "$target_slug"; then
    checked_out=1
  fi

  if [[ "$op" == "write" ]]; then
    if [[ "$checked_out" -eq 1 ]]; then
      printf '%s\n' "$wt_path"
      return 0
    fi
    echo "작업 '${target_slug}' 이 체크아웃되어 있지 않아 쓸 수 없습니다 (상태 변경 없음)." >&2
    echo "  체크아웃: git switch fr/${target_slug}  또는  git worktree add <경로> fr/${target_slug}" >&2
    echo "  색인이 낡았을 수 있습니다: bash rd-workflow/scripts/rd task list --rebuild" >&2
    return 2
  fi

  if [[ "$checked_out" -eq 1 ]]; then
    printf 'checkout\t%s\n' "$wt_path"
  else
    printf 'ref\tfr/%s\n' "$target_slug"
  fi
  return 0
}

# task_resolve_launch <slug> — 기동 예약(launching)과 미확정(unknown)을 사람이 해소하는
# 유일한 진입점 (spec D7). `herdr agent get` 은 관찰만 하므로 색인을 바꾸지 못한다 —
# 이 함수가 그 유일한 경로다.
#
#   대상 상태:
#     launching — 예약 pid 가 살아 있으면 해소하지 않는다 (진행 중 — nonzero, 색인 불변).
#                 pid 가 죽었으면 probe 로 확정한다.
#     unknown(빈 값 포함) — **예약이 없어도 해소한다** (final diff review F1). archive·rollback 이
#                 unknown 을 차단하면서 이 명령을 안내하는데 여기서 받아주지 않으면
#                 사용자가 신뢰 승인을 마치고 작업을 끝내도 마감을 풀 길이 없다.
#                 unknown 에는 예약 token·pid 가 없을 수 있으므로 **pid 검사를 건너뛰고**
#                 곧장 probe 로 확정한다.
#   probe 결과:
#     alive   → 락 아래에서 launch=ok. 확정 뒤 **인계를 전달**한다(F4) — blocked 승인으로
#               살아난 세션은 아직 무엇을 할지 모른 채 입력을 기다리고 있을 수 있다.
#               생존 확정과 인계 전달은 **구분해 보고**한다(전달에 실패해도 생존은 확정된다).
#     dead    → 락 아래에서 launch=failed (+ 수동 기동 명령 제시)
#     unknown → 아래 「조회 불가일 때의 확정 경로」 참조
#
# ── 조회 불가(probe=unknown)일 때의 확정 경로 (final diff review F1) ─────────────
# `session_probe` 는 herdr 가 없거나(HERDR_ENV 미설정·미설치) 조회에 실패하면 **항상**
# unknown 을 돌려준다. 여기서 아무것도 하지 않으면 herdr 밖 사용자는 `unknown` 작업을
# 영원히 끝낼 수 없다 — archive·rollback 이 unknown 을 막으면서 이 명령을 안내하는데,
# 이 명령이 herdr 없이는 아무 상태도 바꾸지 못하기 때문이다.
#
# **그렇다고 조용히 확정하지는 않는다.** 색인의 기록만으로 「기동한 적 없음」과
# 「기록이 사라짐」을 가를 수 없기 때문이다. 한때 `launch-token` 부재를 "이 기계장치로
# 띄운 적 없음" 의 증거로 쓰려 했으나 **틀렸다** — 색인 파일이 유실되면 token 도 행과
# 함께 사라지므로, token 부재는 그 두 경우에서 똑같이 참이다. 기동 사실은 herdr 쪽에만
# 있고 그 유일한 조회 수단이 지금 unknown 을 내고 있는 상황이므로, 저장소 안에는 가를
# 증거가 없다(change spec 159행 「기동 기록의 부재를 세션 부재로 해석하지 않는다」,
# review R5).
#
# 그래서 **사람이 직접 확인했다고 밝히는 명시적 경로 하나**만 둔다: `--assume-ended`.
# 이 플래그는 herdr 없이도 동작하므로 마감이 영구 차단되지 않으며(F1 의 목적),
# 기본 동작은 아무것도 바꾸지 않는 nonzero 다. 안내 문구는 herdr 가 이 셸에서 실제로
# 실행 가능할 때만 herdr 명령을 권한다.
task_resolve_launch() {
  local slug="$1"; shift || true
  [[ -n "$slug" ]] || { echo "resolve-launch: slug 인자가 필요합니다." >&2; return 1; }

  local assume_ended=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --assume-ended) assume_ended=1; shift ;;
      *) echo "resolve-launch: 알 수 없는 인자: $1" >&2; return 1 ;;
    esac
  done

  local launch token pid
  launch="$(tasks_index_get "$slug" launch 2>/dev/null)" || launch=""
  case "$launch" in
    # 빈 값은 `rd task list` 가 이미 unknown 으로 표시하는 값이다(spec D7) — 표시가
    # "확인 필요" 인데 해소 명령이 거부하면 그 행은 다시 막다른 길이 된다.
    launching|unknown|"") ;;
    # `ok` 는 **`--assume-ended` 를 줄 때만** 해소 대상이다 (final diff review F9).
    # 자동 기동에 성공해 `ok` 가 남은 뒤 사용자가 그 세션을 끝내고 herdr 밖 셸로 옮기면
    # `session_probe` 는 unknown 이고, rollback 의 생존 가드는 그것을 거부한다. 그런데
    # `ok` 가 여기서도 막히면 **종료를 직접 확인한 사용자에게 남는 길이 `--force` 뿐**이고,
    # `--force` 는 생존 가드와 함께 미커밋 작업물 보호까지 해제한다 — 「세션 종료만 확인하고
    # 파일 보호는 유지」하는 정상 취소 경로가 사라진다. 그 경로를 여기서 연다.
    # 플래그 없이 부른 `ok` 는 여전히 거부한다 — 그때는 해소할 것이 없다.
    ok)
      if [[ "$assume_ended" -ne 1 ]]; then
        echo "resolve-launch: '${slug}' 는 이미 기동 성공(ok)으로 확정돼 있어 해소할 것이 없습니다." >&2
        echo "  세션을 끝냈고 그 사실을 확인했다면: bash rd-workflow/scripts/rd task resolve-launch ${slug} --assume-ended" >&2
        return 1
      fi
      ;;
    *)
      echo "resolve-launch: '${slug}' 는 해소 대상 상태가 아닙니다 (launch=${launch}) — launching·unknown(미확인), 그리고 --assume-ended 를 준 ok 만 해소합니다." >&2
      return 1
      ;;
  esac

  # pid 검사는 **예약(launching)에만** 적용한다. unknown 은 예약 없이(기동 함수가 판정에
  # 실패해 결과만 unknown 으로 기록된 경우) 도달할 수 있어 token 이 비어 있거나, 남아
  # 있더라도 이미 끝난 예약의 잔재라 "진행 중" 의 근거가 되지 못한다.
  if [[ "$launch" == "launching" ]]; then
    token="$(tasks_index_get "$slug" launch-token 2>/dev/null)" || token=""
    pid="${token##*-}"
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "resolve-launch: '${slug}' 기동이 아직 진행 중입니다 (pid=${pid}) — 해소하지 않습니다." >&2
      return 1
    fi
  fi

  local wt probe
  wt="$(tasks_index_get "$slug" worktree-path 2>/dev/null)" || wt=""
  probe="$(session_probe "$slug" "$wt")"

  # 사람이 확인했다고 밝힌 경우에만 dead 와 같은 처리로 보낸다 (F1).
  if [[ "$probe" == "unknown" && "$assume_ended" -eq 1 ]]; then
    probe="dead"
  fi

  case "$probe" in
    alive)
      tasks_lock_acquire "resolve-launch" "$slug" || {
        echo "resolve-launch: 락을 얻지 못했습니다 — 잠시 후 다시 시도하세요." >&2
        return 1
      }
      tasks_index_upsert "$slug" launch=ok
      tasks_lock_release
      echo "resolve-launch: '${slug}' 세션이 살아 있어 launch=ok 로 확정했습니다."
      echo "resolve-launch: $(session_launch_status_hint ok "$slug")"
      # 인계 전달 (F4) — 락 **밖**에서 한다. 전달은 herdr 응답을 기다리는 일이라 락 안에
      # 두면 다른 작업의 착수·마감이 그 응답을 기다리게 된다. 실패해도 위 생존 확정은
      # 그대로 유효하므로 return 값을 바꾸지 않고 사실만 구분해 알린다.
      local _req=""
      _req="$(session_handoff_request_path "$wt")" || _req=""
      if [[ -n "$_req" ]] && session_handoff_deliver "$slug" "$wt" "$_req"; then
        echo "resolve-launch: 인계를 전달했습니다 (worktree=${wt})."
      else
        echo "resolve-launch: 인계는 전달하지 못했습니다 — 세션 화면에서 직접 지시해 주십시오 (생존 확정은 유효합니다)." >&2
        if [[ -n "$wt" ]]; then
          echo "  인계 문구:" >&2
          session_handoff_text "$slug" "${_req:-<worktree>/REQUEST.md}" "$wt" >&2
          echo "" >&2
        fi
      fi
      return 0
      ;;
    dead)
      tasks_lock_acquire "resolve-launch" "$slug" || {
        echo "resolve-launch: 락을 얻지 못했습니다 — 잠시 후 다시 시도하세요." >&2
        return 1
      }
      tasks_index_upsert "$slug" launch=failed
      tasks_lock_release
      if [[ "$assume_ended" -eq 1 ]]; then
        echo "resolve-launch: 사용자 확인(--assume-ended)에 따라 '${slug}' 를 launch=failed 로 확정했습니다." >&2
      else
        echo "resolve-launch: '${slug}' 세션을 찾을 수 없어 launch=failed 로 확정했습니다." >&2
      fi
      echo "resolve-launch: $(session_launch_status_hint failed)" >&2
      if [[ -n "$wt" ]]; then
        echo "  수동 기동: $(session_launch_command "$wt" "$slug")" >&2
      fi
      return 0
      ;;
    *)
      # 조회가 서지 않는다 — 조용히 확정하지 않는다(위 주석 참조).
      echo "resolve-launch: '${slug}' 세션 상태를 확인할 수 없습니다(unknown) — 확정하지 않고 유지합니다." >&2
      if session_herdr_available; then
        echo "  확인: herdr agent get $(_session_launch_agent_name "$slug")" >&2
      else
        # herdr 가 이 셸에 없다 — 실행할 수 없는 명령을 권하지 않는다.
        echo "  이 셸에서는 herdr 로 조회할 수 없습니다(HERDR_ENV 미설정 또는 herdr 미설치)." >&2
      fi
      echo "  세션이 없거나 이미 끝났음을 직접 확인했다면 다음으로 확정하십시오:" >&2
      echo "    bash rd-workflow/scripts/rd task resolve-launch ${slug} --assume-ended" >&2
      return 1
      ;;
  esac
}

# _task_source_fr_slug_from_path <canonical-path> — canonical source-fr 경로에서 slug 를
# 뽑는다. 'rd-workflow-workspace/backlog/items/YYYY-MM-DD-slug.md' → 'slug'. 날짜 접두가
# 없는(legacy) 파일명은 basename 전체(확장자 제외)를 slug 로 본다.
#
# guard 순위 4(change spec §2.1·§2.2)의 cand↔source-fr 비교 기준이다. cand 는 항상
# normalize_slug 를 거친 short-title slug([a-z0-9-]) 이고, source-fr 집합의 원소는
# canonical **경로**이므로 직접 비교할 수 없다 — 여기서 같은 "slug 자리" 로 투영한 뒤
# 정확 일치로 비교한다(부분·접두 일치 불허).
_task_source_fr_slug_from_path() {
  local p="${1-}" base
  base="${p##*/}"
  base="${base%.md}"
  if [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$base"
  fi
}

# _fr_branch_active — task-state 의 fr-branch 활성 여부 (change spec §2.2).
# stdout 한 단어: inactive(null·빈값·공백, 또는 ref 부재) | active(ref 실재) |
# query-failed(git 아님·조회 오류 — 판정 불가이므로 **활성으로 간주**하되 메시지는 구별한다.
# 호출부가 "ref 실재 확인"과 "조회 실패"를 같은 문구로 섞으면 사람이 없는 브랜치를
# 있다고 믿는다).
# return: 0 = 활성(active·query-failed 모두) / 1 = 비활성(inactive)
_fr_branch_active() {
  local v
  v="$(state_read_field "fr-branch")"
  v="$(_sfr_trim "$v")"
  if [[ -z "$v" || "$v" == "null" ]]; then
    printf 'inactive\n'
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    printf 'query-failed\n'
    return 0
  fi
  # rc 를 `if` 문 자체의 $? 로 얻지 않는다 — POSIX 상 then/else 어느 쪽도 실행되지
  # 않은 if 문의 종료 상태는 조건의 종료 상태가 아니라 **0** 이다. 그 함정에 걸리면
  # ref 부재(rc=1)가 "명령 성공"으로 오판되어 활성/비활성이 뒤집힌다 — 명령을 먼저
  # 실행하고 그 직후의 $? 를 변수에 담은 뒤에 분기한다.
  git -C "$project_root" show-ref --verify --quiet "refs/heads/${v}" 2>/dev/null
  local rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf 'active\n'
    return 0
  fi
  if [[ "$rc" -eq 1 ]]; then
    printf 'inactive\n'
    return 1
  fi
  # rc>1 (예: "fatal: not a git repository") — 조회 자체가 실패. 판정 불가는 보호 쪽으로.
  printf 'query-failed\n'
  return 0
}

# GRD-01/02 + SEC-13: Short Title 3-way + Status guard 통합 판정 (기존 4개 산문 변형 대체)
# stdout: decision=... / message=...  return: 0 진행, 2 차단
# v2 2b: Short Title 읽기는 get_current_short_title(task-state 우선), 쓰기는 task-state + 뷰 미러
task_guard_decide() {
  local cand="$1" mode="$2" src="${3:-}" cur status file="${project_root}/CURRENT_TASK.md"
  # promote 모드 write/rebind 시 기록할 source-fr — 인자 없으면 '-' 리셋 (stale 차단).
  # REQUEST.md 추론을 여기 두지 않는 이유: guard 시점의 REQUEST.md 는 새 작업용으로
  # 작성 전(빈 템플릿 또는 이전 작업 잔재)이라 추론값이 '-' 또는 오염값이다.
  # 실제 FR path 추론·기록은 promote.sh 책임 (change-spec §2 접근 A).
  local src_val="${src:--}"

  # Short Title 읽기 — task-state 우선, fallback: CURRENT_TASK.md 산문
  if state_file_exists; then
    cur="$(state_read_field "short-title")"
  else
    # task-state 부재 시 CURRENT_TASK.md 산문 파싱 (마이그레이션 전 호환)
    if ! grep -q '^## Short Title' "$file" 2>/dev/null; then
      if [[ "$mode" == "fr-add" ]]; then
        echo "decision=proceed-readonly"
        echo "message=CURRENT_TASK.md에 ## Short Title 섹션이 없습니다. 갱신 없이 진행합니다."
        return 0
      fi
      printf '## Short Title\n-\n\n' >> "$file"   # intake/promote: 부재 = write 대상 (`standard` 등급 현행 의미)
    fi
    cur="$(_extract_task_section "Short Title")"
  fi

  # fr-add + ## Short Title 섹션 부재(task-state 없고 뷰 섹션도 없음) → proceed-readonly
  if [[ -z "$cur" && "$mode" == "fr-add" && ! state_file_exists ]]; then
    echo "decision=proceed-readonly"
    echo "message=CURRENT_TASK.md에 ## Short Title 섹션이 없습니다. 갱신 없이 진행합니다."
    return 0
  fi

  if [[ -z "$cur" || "$cur" == "-" ]]; then
    # fr-add + task-state 존재 + short-title 키 부재/빈 값(손상): write 금지 — proceed-readonly (GRD-02)
    # "-"(sentinel)은 정상 상태 → write 허용. ""(키 부재·빈 값)만 손상으로 간주.
    if [[ "$mode" == "fr-add" ]] && state_file_exists && [[ -z "$cur" ]]; then
      echo "decision=proceed-readonly"
      echo "message=task-state의 short-title이 비어있습니다(손상 가능). 갱신 없이 진행합니다."
      return 0
    fi
    # Short Title 쓰기: task-state + 뷰 미러 (결정 3 LC-18)
    if state_file_exists; then
      if [[ "$mode" == "promote" ]]; then
        state_write_fields "short-title=${cand}" "source-fr=${src_val}"
      else
        state_write_fields "short-title=${cand}"
      fi
    fi
    # 뷰에 ## Short Title 섹션이 없으면 append (기존 동작 유지)
    if ! grep -q '^## Short Title' "$file" 2>/dev/null; then
      printf '## Short Title\n-\n\n' >> "$file"
    fi
    _task_section_write "Short Title" "$cand"
    # promote 모드는 source-fr 도 권위에 썼으므로 미러도 함께 맞춘다 (change spec D12-3).
    # 씨앗 값이 없으면 이후 모든 rerun 이 거짓 divergence 를 본다.
    # 미러는 **줄 단위 목록**이고 권위는 직렬화된 한 줄이다 — 저장 형식을 그대로
    # 넘기면 사람이 보는 자리에 `a|b` 가 새고, promote 의 집합 비교가 권위(split 결과)와
    # 달라 정상 상태를 divergence 로 차단한다 (final diff review F2).
    [[ "$mode" == "promote" ]] && _task_source_fr_mirror_write "$(source_fr_split "$src_val" "$project_root")"
    echo "decision=write"
    if [[ "$mode" == "promote" ]]; then
      echo "message=Short Title을 ${cand} 로 기록했습니다 (source-fr=${src_val})."
    else
      echo "message=Short Title을 ${cand} 로 기록했습니다."
    fi
    return 0
  fi
  if [[ "$cur" == "$cand" ]]; then
    echo "decision=proceed-readonly"
    echo "message=동일 Short Title(${cand}) — 변경 없이 진행합니다."
    return 0
  fi
  if [[ "$mode" == "fr-add" ]]; then
    echo "decision=proceed-readonly"
    echo "message=진행 중 작업(${cur})이 있어 Short Title을 변경하지 않고 진행합니다."
    return 0
  fi

  # 순위 4 (신설, change spec §2.1) — cand 가 현재 task-state 의 source-fr 집합
  # 구성원과 slug 기준으로 정확 일치하면 "같은 작업으로 재진입" 으로 보고 상태를
  # 바꾸지 않는다. mode 무관(intake·promote 둘 다) — "현재 작업이 그 FR 의 작업"
  # 이라는 사실은 mode 와 무관하다. 순위 2·3 다음, 순위 5(fr-branch 활성 차단)보다
  # 먼저 판정한다 — 통합 slug 로 자기 source FR 에 재진입하는 정상 흐름이 순위 5 의
  # 보호 확대에 걸리지 않게 하기 위함이다.
  if state_file_exists; then
    local _sfr_raw _sfr_members _sfr_m _sfr_mslug
    _sfr_raw="$(state_read_field "source-fr")"
    _sfr_members="$(source_fr_split "$_sfr_raw" "$project_root")"
    while IFS= read -r _sfr_m; do
      [[ -z "$_sfr_m" ]] && continue
      _sfr_mslug="$(_task_source_fr_slug_from_path "$_sfr_m")"
      if [[ "$_sfr_mslug" == "$cand" ]]; then
        echo "decision=proceed-readonly"
        echo "message=candidate(${cand})가 현재 작업의 source FR(${_sfr_m})과 같은 작업입니다 — Short Title·source-fr·fr-branch 를 바꾸지 않고 진행합니다."
        return 0
      fi
    done <<< "$_sfr_members"
  fi

  # 순위 5 (신설, change spec §2.2) — fr-branch 가 활성(ref 실재, 또는 조회 실패로
  # 판정 불가)이면 순위 2·4 에 해당하지 않는 한 무조건 block-active. 상태를 바꾸지
  # 않는다 — 보호를 넓히는 방향이다(현행에서 rebind 로 통과했던 "승격 완료 + 무관
  # 후보" 를 막는다). 자동 정합화는 하지 않는다 — 사람이 둘 중 하나를 고른다.
  local _fbstate _fb_val
  _fbstate="$(_fr_branch_active)"
  if [[ "$_fbstate" == "active" || "$_fbstate" == "query-failed" ]]; then
    _fb_val="$(state_read_field "fr-branch")"
    echo "decision=block-active"
    if [[ "$_fbstate" == "query-failed" ]]; then
      echo "message=브랜치 ref 를 확인할 수 없습니다(저장소 접근 오류) — 판정 불가로 보호합니다. 현재 작업(Short Title=${cur}, fr-branch=${_fb_val})과 candidate(${cand}) 중 어느 쪽도 자동으로 정리하지 않습니다. 저장소 상태를 확인한 뒤 다시 시도하거나, 정말 다른 작업을 시작하려면 먼저 현재 작업을 archive 하세요."
    else
      echo "message=현재 진행 중인 작업(Short Title=${cur}, fr-branch=${_fb_val})이 archive 되지 않았습니다. candidate(${cand})를 진행하려면 다음 중 하나를 선택하세요: ① 제목을 브랜치 slug(${_fb_val})에 맞춰 그 작업을 계속한다 ② 그 작업을 archive 한 뒤 다시 진입한다."
    fi
    return 2
  fi

  status="$(task_read_status 2>/dev/null)" || {
    echo "decision=block-parse"
    echo "message=## Status 가 없거나 파싱 불가/비canonical 값입니다. 유효한 Status 를 설정한 뒤 다시 진입하세요. (보수적 차단 — SEC-13)"
    return 2
  }
  [[ "$status" == "실행 중" ]] && status="구현 중"
  if [[ "$status" == "대기 중" ]]; then
    # Short Title 쓰기: task-state + 뷰 미러 (결정 3 LC-18)
    if state_file_exists; then
      if [[ "$mode" == "promote" ]]; then
        state_write_fields "short-title=${cand}" "source-fr=${src_val}"
      else
        state_write_fields "short-title=${cand}"
      fi
    fi
    # write 경로와 같은 append 를 둔다 — 없으면 task-state 만 갱신되고 미러는 빠진
    # partial state 가 남는다 (`_task_section_write` 가 섹션 부재를 실패로 바꿨으므로).
    if ! grep -q '^## Short Title' "$file" 2>/dev/null; then
      printf '## Short Title\n-\n\n' >> "$file"
    fi
    _task_section_write "Short Title" "$cand"
    # 미러는 **줄 단위 목록**이고 권위는 직렬화된 한 줄이다 — 저장 형식을 그대로
    # 넘기면 사람이 보는 자리에 `a|b` 가 새고, promote 의 집합 비교가 권위(split 결과)와
    # 달라 정상 상태를 divergence 로 차단한다 (final diff review F2).
    [[ "$mode" == "promote" ]] && _task_source_fr_mirror_write "$(source_fr_split "$src_val" "$project_root")"
    echo "decision=rebind"
    # 순위 6 메시지 보강(AC A-6) — rebind 는 "이전 값이 기존 브랜치명과 어긋나게 되는
    # 경우" 임을 병기한다. fr-branch 가 이미 비활성(null 또는 ref 부재)이라 여기 도달한
    # 것이므로, stale 값을 그대로 두면 이후 브랜치명·source-fr 과 어긋난 채 남는다.
    if [[ "$mode" == "promote" ]]; then
      echo "message=이전 Short Title (${cur}) 이 Status = 대기 중 인 stale 값이라 ${cand} 로 교체하고 진행합니다 (source-fr=${src_val}). 이전 값은 기존 브랜치명과 어긋나게 되는 경우이므로 교체합니다."
    else
      echo "message=이전 Short Title (${cur}) 이 Status = 대기 중 인 stale 값이라 ${cand} 로 교체하고 진행합니다. 이전 값은 기존 브랜치명과 어긋나게 되는 경우이므로 교체합니다."
    fi
    return 0
  fi
  echo "decision=block-active"
  echo "message=현재 진행 중인 작업 (${cur}) 이 archive 되지 않았습니다. ${cand} 을 진행하려면 먼저 현재 작업을 archive 한 뒤 다시 진입하세요."
  return 2
}

# SEC-03/04/05/06: raw-capture 생성 (기존 6개 heredoc 블록 대체).
# stdin: 본문(무가공 passthrough). 실패는 fail-open — 경고 후 return 0 (본 작업 차단 금지).
task_capture_write() {
  local stage="$1" title="$2" src="${3:-routed}"
  # project_root를 physical(non-symlink) path로 resolve — macOS /var→/private/var 등 시스템 symlink 제외
  local _proot
  _proot="$(realpath "$project_root" 2>/dev/null)" \
    || _proot="$(cd -P "$project_root" && pwd)" \
    || _proot="$project_root"
  local dir="${_proot}/rd-workflow-workspace/raw-captures"
  if ! assert_no_symlink_in_path "$dir"; then
    echo "경고: raw-capture 경로 검증 실패 — 캡처를 생략하고 작업은 계속합니다." >&2
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null || { echo "경고: 캡처 디렉토리 생성 실패 — 캡처 생략." >&2; return 0; }
  chmod 0700 "$dir"
  local base dest n=2
  base="${dir}/$(date +%F)-${stage}-${title}.md"
  dest="$base"
  while [[ -e "$dest" || -L "$dest" ]]; do dest="${base%.md}-${n}.md"; n=$((n+1)); done
  ( umask 077
    {
      printf -- '---\ndate: %s\nstage: %s\nshort-title: %s\nsource: %s\n---\n\n' \
        "$(date '+%Y-%m-%d %H:%M')" "$stage" "$title" "$src"
      cat
    } > "$dest"
  ) || { rm -f "$dest"; echo "경고: 캡처 파일 생성 실패 — 작업은 계속합니다." >&2; return 0; }
  printf '%s\n' "$dest"
}

# _task_request_is_empty_template <file> — REQUEST.md 에 **보존할 내용이 하나도 없음**을
# 확인한다 (2026-09-05 FR — backup-request-empty-template-archive).
#
# 판정 방향이 중요하다. "핵심 몇 필드가 기본값처럼 보이는가" 를 보면 그 필드 밖에 적힌
# 내용(제약만 먼저 적은 초안 등)과 placeholder `-` **뒤에** 덧붙인 내용을 놓쳐, 백업 없이
# 덮어써지고 사용자는 "백업할 내용 없음" 이라는 거짓 안내를 받는다 (final diff review F1).
# 그래서 반대로 간다 — **알려진 템플릿 뼈대를 모두 걷어내고 한 줄이라도 남으면 내용이
# 있는 것으로 보고 백업 경로로 보낸다.** 판단할 수 없는 형식도 남으므로 자동으로 백업된다
# (fail-safe 방향: 의심스러우면 보존).
#
# 제외는 **정본 템플릿에서 확인된 뼈대로 한정**한다. `^#` 같은 일반 패턴으로 제거하면
# 사용자가 쓴 `### 소제목` 까지 함께 지워져 내용 부재가 증명되지 않는다 (F1 004 재현).
# 그래서 섹션 헤더는 아래 목록과 **정확히 일치**할 때만 뼈대로 보고, 모르는 제목·항목은
# 내용으로 취급한다. 템플릿에 새 섹션이 생기면 초기 템플릿이 "내용 있음" 으로 판정되어
# 빈 백업이 다시 쌓이는데, 정본 템플릿을 그대로 넣는 회귀 단언이 그 어긋남을 잡는다.
#
# 뼈대: 빈 줄 / 아래 목록의 제목·섹션 헤더 / placeholder `-` 단독 / `- <키>: -` 형태의
# 미작성 항목(Risk Tier 6줄) / 템플릿 기본 선택지 안내 두 줄 / HTML 주석.
#
# 주석은 **닫힘 뒤에 본문이 없을 때만** 버린다 — `<!-- 초안 --> 실제 요구사항` 처럼
# 뒤에 붙은 본문은 렌더링되는 내용이다. 닫히지 않은 주석은 판정 불가이므로 내용으로
# 본다 (fail-safe 방향: 의심스러우면 보존).
#
# return 0 = 보존할 내용 없음(건너뛰어도 됨), 1 = 내용 있음(백업 필요).
_task_request_is_empty_template() {
  local file="$1"
  awk '
    function tail_after_close(s,   p, rest) {
      # **첫** 닫힘 뒤 잔여를 돌려준다. 마지막 닫힘까지 지우면
      # `<!-- 초안 --> 본문 <!-- 확정 -->` 처럼 주석 **사이**에 있는 본문이 사라진다.
      p = index(s, "-->")
      if (p == 0) return ""
      rest = substr(s, p + 3)
      sub(/^[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
      return rest
    }
    BEGIN {
      n = split("Task Type|Execution Path|User Goal|Change Description|Affected Area|" \
                "Platform|Constraints|Acceptance Criteria|AC Bypass Reason|Risks|" \
                "Risk Tier|Source FR", sec, "|")
      for (i = 1; i <= n; i++) known["## " sec[i]] = 1
      known["# Change Request"] = 1
      # Risk Tier 의 미작성 항목은 정본 6개 키에 한정한다 — 일반 패턴으로 열면
      # `- 허용되는 접두 문자: -` 같은 **내용**까지 미작성으로 삼킨다.
      m = split("최종 등급|최초 등급|baseline HEAD|근거 신호|override·상향 이력|" \
                "변경 파일 요약", rt, "|")
      for (i = 1; i <= m; i++) rtkey["- " rt[i] ": -"] = 1
    }
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    in_c {
      # 정본의 주석 블록은 섹션을 넘지 않는다. 넘었다면 닫히지 않은 주석이라
      # **뒤따르는 실제 내용까지 삼키는** 중이므로(다음 섹션의 값이 조용히 사라진다)
      # 판정 불가로 보고 보존한다.
      if (line in known) { found = 1; exit }
      if (index(line, "-->") > 0) {
        in_c = 0
        if (tail_after_close(line) != "") { found = 1; exit }
      }
      next
    }
    line == "" { next }
    line in known { cur = line; next }
    line == "-" { next }
    cur == "## Risk Tier" && (line in rtkey) { next }
    cur == "## Task Type" && line == "new feature / change / bugfix / refactor" { next }
    cur == "## Execution Path" && \
      line == "small-task / existing-code-change / new-feature-or-large-task" { next }
    substr(line, 1, 4) == "<!--" {
      if (index(line, "-->") > 0) {
        if (tail_after_close(line) != "") { found = 1; exit }
        next
      }
      in_c = 1; next
    }
    { found = 1; exit }
    END {
      if (in_c) found = 1
      exit found ? 1 : 0
    }
  ' "$file"
}

# SEC-01/02/05: REQUEST.md collision-safe 백업 (기존 3개 블록 대체). 차단 시 return 2 (fail-closed).
task_backup_request() {
  local title="$1" orphan="${2:-0}"
  # project_root를 physical(non-symlink) path로 resolve — macOS /var→/private/var 등 시스템 symlink 제외
  local _proot
  _proot="$(realpath "$project_root" 2>/dev/null)" \
    || _proot="$(cd -P "$project_root" && pwd)" \
    || _proot="$project_root"
  local dir="${_proot}/rd-workflow-workspace/backlog/request-archive"
  local stamp; stamp="$(date '+%Y-%m-%d-%H%M')"
  local name="${stamp}-${title}.md"
  [[ "$orphan" == "1" ]] && name="${stamp}-orphan.md"
  # SEC-01/02: 원본 REQUEST.md 자체가 symlink 이면 차단 (source-file symlink 방어)
  if [[ -L "${_proot}/REQUEST.md" ]]; then
    echo "경고: REQUEST.md 가 symlink 입니다. 보안상 중단합니다." >&2
    return 2
  fi
  # 초기 템플릿(보존할 내용 0)이면 백업을 건너뛴다 — 호출부(skill 분기 1a/1b)가 실패로
  # 오판해 중단하지 않도록 종료 코드는 0 을 유지한다.
  if _task_request_is_empty_template "${_proot}/REQUEST.md"; then
    echo "건너뜀 — REQUEST.md 가 초기 템플릿 상태입니다 (백업할 내용 없음)"
    return 0
  fi
  assert_no_symlink_in_path "$dir" || return 2
  mkdir -p "$dir"
  local base dest n
  base="${dir}/${name}"; dest="$base"; n=2
  while [[ -e "$dest" || -L "$dest" ]]; do dest="${base%.md}-${n}.md"; n=$((n+1)); done
  if [[ -L "$dest" ]]; then
    echo "경고: archive 대상 ($dest) 이 symlink 입니다. 보안상 중단합니다." >&2
    return 2
  fi
  cp "${_proot}/REQUEST.md" "$dest" && printf '%s\n' "$dest"
}

# SEC-07/17: stage 캡처를 raw-captures/archive/ 로 이동 (frontmatter exact match — 기존 3개 awk 블록 대체).
# stage 경계 책임은 호출부: REQUEST archive 는 request,spec,plan / '/fr archive' 는 fr 만 넘긴다.
task_archive_captures() {
  local stages="$1" title="$2"
  # project_root를 physical(non-symlink) path로 resolve — macOS /var→/private/var 등 시스템 symlink 제외
  local _proot
  _proot="$(realpath "$project_root" 2>/dev/null)" \
    || _proot="$(cd -P "$project_root" && pwd)" \
    || _proot="$project_root"
  local src="${_proot}/rd-workflow-workspace/raw-captures"
  local dst="${src}/archive"
  assert_no_symlink_in_path "$dst" || return 2
  mkdir -p "$dst"
  chmod 0700 "$src" "$dst"
  local stage f
  local IFS=','
  for stage in $stages; do
    find "$src" -maxdepth 1 -type f -name "*-${stage}-*.md" 2>/dev/null \
      | while IFS= read -r f; do
          if awk -v t="$title" -v s="$stage" '
              BEGIN{c=0; st=0; sg=0}
              /^---$/{c++; if(c==2)exit}
              c==1 && $0=="short-title: " t {st=1}
              c==1 && $0=="stage: " s {sg=1}
              END{exit !(st && sg)}
            ' "$f"; then
            mv "$f" "$dst/" && printf '%s\n' "$f"
          fi
        done
  done
}

# 섹션 값 재기록 — 해당 섹션의 첫 비어있지 않은 줄만 교체, 나머지 byte 보존.
# 섹션이 비어 있으면 다음 헤더 직전(또는 EOF)에 값 삽입.
# **섹션 헤더 자체가 없으면 return 1.** 종전에는 입력을 그대로 복사하고 0 으로 끝나서,
# 호출자가 "미러 갱신 성공" 을 받고도 미러는 계속 부재했다 (final diff review Finding 4).
# 헤더를 임의 위치에 새로 만들지는 않는다 — 미러의 섹션 순서는 baseline 계약이고,
# 없다는 것은 파일이 baseline 이 아니라는 신호이므로 사람이 볼 일이다.
_task_section_write() {
  local file="${project_root}/CURRENT_TASK.md" section="$1" value="$2" tmp
  if ! grep -q "^## ${section}\$" "$file" 2>/dev/null; then
    echo "CURRENT_TASK.md 에 '## ${section}' 섹션이 없습니다 — 미러를 갱신할 수 없습니다." >&2
    echo "  확인: grep -n '^## ' '$file'" >&2
    return 1
  fi
  tmp="$(mktemp)" || { echo "_task_section_write: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$tmp" && -f "$tmp" ]] || { echo "_task_section_write: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  awk -v target="## ${section}" -v val="$value" '
    $0 == target { print; in_s=1; replaced=0; next }
    in_s && /^## / { if (!replaced) { print val; replaced=1 } in_s=0; print; next }
    in_s && !replaced && NF { print val; replaced=1; next }
    { print }
    END { if (in_s && !replaced) print val }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# _task_section_exists <section> — 미러에 섹션 헤더가 있는지. 쓰기 전 선검사용.
# task-state 를 먼저 쓰고 미러 쓰기가 실패하면 partial state write 가 남으므로,
# 값 계약 검증과 같은 단계에서 확인한다.
_task_section_exists() {
  grep -q "^## ${1}\$" "${project_root}/CURRENT_TASK.md" 2>/dev/null
}

# _task_section_write_list <section> <multiline-value> — `_task_section_write` 의 목록판.
# 그 함수는 "첫 비어있지 않은 줄만 교체, 나머지 byte 보존" 계약이라 여러 줄 본문을
# 표현할 수 없다(교체해도 두 번째 줄부터는 옛 값이 남는다) — Source FR 미러가 복수
# 목록(change spec §2.3b)을 담아야 해서 신설한다. 섹션의 옛 본문에서 값 줄은 버리고
# 새 값으로 교체하되, **안내 주석(`<!-- ... -->`)은 보존해 값 뒤에 재배치한다** —
# `## Status` 쪽(`_task_section_write`)은 첫 줄만 교체해 뒤따르는 주석이 자동 보존되는데
# Source FR 쪽만 전체 교체라 주석이 함께 사라졌다 (2026-09-18 FR — task-mirror-write-
# strips-source-fr-comments). 헤더 자체가 없으면 `_task_section_write` 와 같은 이유로
# return 1 (임의 위치에 새 헤더를 만들지 않는다 — 부재는 baseline 이 아니라는 신호).
_task_section_write_list() {
  local file="${project_root}/CURRENT_TASK.md" section="$1" value="$2" tmp
  if ! grep -q "^## ${section}\$" "$file" 2>/dev/null; then
    echo "CURRENT_TASK.md 에 '## ${section}' 섹션이 없습니다 — 미러를 갱신할 수 없습니다." >&2
    echo "  확인: grep -n '^## ' '$file'" >&2
    return 1
  fi
  tmp="$(mktemp)" || { echo "_task_section_write_list: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$tmp" && -f "$tmp" ]] || { echo "_task_section_write_list: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  # 값은 `-v` 가 아니라 ENVIRON 으로 넘긴다 — BSD awk(macOS 기본)는 `-v` 값에 개행이
  # 있으면 "newline in string" 으로 죽는다. 그러면 `awk ... && mv` 가 끊겨 **권위는
  # 갱신되고 미러만 안 된 partial state** 가 남는다 (2026-09-10 실측: 2건 이상을
  # 기존 섹션에 쓸 때 재현). 섹션이 없던 픽스처는 append 경로로 빠져 이 결함을
  # 가렸으므로 회귀 테스트는 **섹션이 이미 있는** 상태를 쓴다.
  #
  # 값이 baseline 과 같으면 이 재구성 결과가 원본과 byte-identical 하므로 (주석까지
  # 그대로 재배치) `mv` 후에도 git diff 가 생기지 않는다 — 별도 short-circuit 없이
  # 멱등성이 성립한다.
  _TSWL_VAL="$value" awk -v target="## ${section}" '
    BEGIN { n = split(ENVIRON["_TSWL_VAL"], arr, "\n"); cn=0 }
    $0 == target { print; in_s=1; printed=0; next }
    in_s && /^<!--/ { cn++; cmt[cn]=$0; next }
    in_s && /^## / {
      # 값 뒤에 보존한 안내 주석을 재배치하고, 그 뒤 빈 줄 1개를 유지한다 —
      # baseline 서식(섹션 사이 빈 줄)을 보존하기 위함이다.
      if (!printed) {
        for (i=1;i<=n;i++) print arr[i]
        for (i=1;i<=cn;i++) print cmt[i]
        print ""
        printed=1
      }
      in_s=0; print; next
    }
    in_s { next }
    { print }
    END {
      if (in_s && !printed) {
        for (i=1;i<=n;i++) print arr[i]
        for (i=1;i<=cn;i++) print cmt[i]
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# _task_source_fr_mirror_write <canonical-list> — 미러의 '## Source FR' 갱신. 섹션이
# 없으면 append. 입력은 개행 구분 canonical 목록(원소 1개도 포함, change spec §2.3b) —
# `source_fr_mirror_body` 가 사람이 보는 줄 단위 목록 문자열로 만든 뒤 `_task_section_write_list`
# 로 섹션 본문 전체를 교체한다(저장 형식 '|' 를 노출하지 않는다).
#
# `Status`·`Short Title` 은 섹션 부재를 hard error 로 다루는데(미러가 깨졌다는 뜻) 여기는
# append 한다. 이 섹션은 change spec D12 에서 신설됐으므로, 부재는 "깨졌다" 가 아니라
# **"그 결정 이전에 만들어진 미러"** 라는 다른 사실이다. 같은 hard error 로 다루면
# 진행 중인 기존 작업의 정상 흐름이 끊긴다 (D12-2).
_task_source_fr_mirror_write() {
  local v="${1-}" f="${project_root}/CURRENT_TASK.md" body
  [[ -f "$f" ]] || return 0
  body="$(source_fr_mirror_body "$v")"
  if _task_section_exists "Source FR"; then
    _task_section_write_list "Source FR" "$body"
    return
  fi
  printf '\n## Source FR\n%s\n' "$body" >> "$f" || {
    echo "set-source-fr: CURRENT_TASK.md 에 '## Source FR' 섹션을 추가하지 못했습니다." >&2
    return 1
  }
}

# task_set_source_fr <value>... — 값 계약 검증 후 task-state + 미러 source-fr 갱신.
# 복수 입력(change spec §2.4b — 위치 인자 반복)을 받는다. '-' 단독은 sentinel(값 없음)
# 이고 다른 항목과 섞이면 거부한다(§2.4).
#
# 검증은 전부-또는-전무다 — 항목 하나라도 `source_fr_validate` 를 통과하지 못하면
# **아무것도 쓰지 않고** 실패 항목을 전부 stderr 에 열거한 뒤 return 1.
#
# 검증은 `source_fr_resolve`(raw 서술 해석)가 아니라 **canonical 형식 검증
# (`source_fr_validate`) + 파일 실존 검사**다 — 이 명령의 입력은 사람이 쓰는 서술이
# 아니라 이미 canonical 인 items path 이므로 서술 해석기를 쓰지 않고, 실존은 AC C-13 이
# 요구한다(오등록이 아카이브 게이트의 해석 실패로 **마감 시점에야** 드러나는 것을 막는다).
# 종전 계약은 형식만 봤으며, 그 계약을 인코딩하던 픽스처는 실제 파일 생성으로 바꿨다.
#
# 위반 return 1 (stderr 사유), 쓰기 실패 return 1.
#
# 미러를 함께 쓰는 이유는 표시 편의가 아니라 **대조 출처**다 (change spec D12).
# `source-fr` 만 미러에 없어서, 권위 파일이 사라진 뒤 index 에서 되살리면 이 필드가
# 승격 시점 값으로 돌아간 것을 아무도 판정할 수 없었다 — 실행은 성공하므로 유실이
# 드러나지 않고 archive 가 다른 FR 을 done 처리한다. 미러가 있으면 promote 가 divergence
# 를 보고 멈출 수 있다 (D12-4).
task_set_source_fr() {
  local n=$# item seen="" fail_out="" any_fail=0 dash_count=0 joined
  if [[ "$n" -eq 0 ]]; then
    echo "set-source-fr: 값이 필요합니다 — '-' 또는 rd-workflow-workspace/backlog/items/<파일>.md 를 1개 이상 지정하세요." >&2
    return 1
  fi
  for item in "$@"; do
    [[ "$item" == "-" ]] && dash_count=$((dash_count + 1))
  done
  if [[ "$dash_count" -gt 0 && "$n" -gt 1 ]]; then
    echo "set-source-fr: '-' (값 없음) 은 다른 항목과 함께 지정할 수 없습니다." >&2
    return 1
  fi
  if [[ "$n" -eq 1 && "$1" == "-" ]]; then
    state_write_fields "source-fr=-" || return 1
    _task_source_fr_mirror_write "-" || return 1
    return 0
  fi
  for item in "$@"; do
    if ! source_fr_validate "$item"; then
      any_fail=1
      fail_out="${fail_out:+${fail_out}$'\n'}set-source-fr: 값 계약 위반 — '-' 또는 rd-workflow-workspace/backlog/items/<파일>.md 만 허용 (절대경로/../개행/slug 거부): '${item}'"
      continue
    fi
    # 실존 검사 (change-spec AC C-13). 형식만 보던 종전 계약을 좁힌다 —
    # 오타로 만들어진 없는 경로가 저장되면 아카이브 게이트가 해석에 실패하는
    # **마감 시점**에야 드러난다. 묶음에서는 그 비용이 항목 수만큼 커지므로
    # 쓰기 시점에 막는다. promote 의 `--source-fr` 도 같은 기준이다.
    if [[ ! -f "${project_root}/${item}" ]]; then
      any_fail=1
      fail_out="${fail_out:+${fail_out}$'\n'}set-source-fr: 파일이 존재하지 않습니다: '${item}'"
      continue
    fi
    _sfr_list_contains "$item" "$seen" && continue
    seen="${seen:+${seen}$'\n'}${item}"
  done
  if [[ "$any_fail" -eq 1 ]]; then
    printf '%s\n' "$fail_out" >&2
    return 1
  fi
  joined="$(source_fr_join "$seen")" || return 1
  state_write_fields "source-fr=${joined}" || return 1
  _task_source_fr_mirror_write "$seen" || return 1
}

# task_set_title <slug> [force] — short-title 기록. sentinel '-' → 값 방향만 허용.
# return 0 성공(멱등 포함) / 1 값 계약 위반 / 2 다른 값 존재(force 없음) / 3 쓰기 실패
# 동일 값 재실행은 성공이지만 완전 no-op 이 아니다 — CURRENT_TASK.md 미러가 어긋나 있으면
# 복구한다. prepare_review_pipeline.sh 처럼 미러를 직접 파싱하는 소비처가 틀린 값을
# 계속 보는 것을 막기 위함이다 (change spec D3).
task_set_title() {
  local raw="${1-}" force="${2:-0}" slug cur
  if [[ -z "$raw" ]]; then
    echo "set-title: 빈 값은 허용되지 않습니다." >&2
    return 1
  fi
  if [[ "$raw" == "-" ]]; then
    task_reset_title "$force"
    return $?
  fi
  case "$raw" in
    *"
"*) echo "set-title: 값에 개행을 포함할 수 없습니다." >&2; return 1 ;;
  esac
  slug="$(normalize_slug "$raw")" || return 1
  cur="$(get_current_short_title)"
  if [[ -n "$cur" && "$cur" != "-" && "$cur" != "$slug" && "$force" != "1" ]]; then
    echo "set-title: 이미 다른 작업 이름이 있습니다 — 현재 값: '${cur}'" >&2
    echo "  작업 이름은 시작 시 1회 정하고 archive 까지 유지합니다." >&2
    echo "  정말 바꾸려면 --force 를 쓰세요 (복구 전용)." >&2
    return 2
  fi
  # 미러 섹션 부재를 **task-state 쓰기 전에** 잡는다. 뒤에서 잡으면 권위는 갱신되고
  # 미러만 안 된 partial state 가 남는다 (final diff review Finding 4).
  if ! _task_section_exists "Short Title"; then
    echo "set-title: CURRENT_TASK.md 에 '## Short Title' 섹션이 없어 중단합니다 (상태 변경 없음)." >&2
    echo "  미러가 baseline 형식이 아닙니다. 확인: grep -n '^## ' '${project_root}/CURRENT_TASK.md'" >&2
    return 3
  fi
  if state_file_exists; then
    state_write_fields "short-title=${slug}" || return 3
  fi
  # 값이 같아도 미러는 맞춘다 (drift 복구)
  _task_section_write "Short Title" "$slug" || return 3
  return 0
}

# task_reset_title <force> — `rd task set-title -` 의 reset 경로 (change spec §2.6, D5).
# 허용 조건: Status == 대기 중 그리고 fr-branch 가 비활성(`_fr_branch_active` 기준).
# 둘 다 성립해야 short-title·source-fr 을 함께 sentinel 로 되돌린다(미러 포함).
#
# `--force` 는 이 경로에 받지 않는다 — 열면 그것이 곧 진행 중 작업 보호의 우회
# 통로가 된다(정말 막힌 상태의 정본 경로는 그 작업을 archive 하는 것). 거부 시
# **어떤 상태도 바꾸지 않는다** — 사유 + 다음 행동만 stderr 로 알린다.
# return 0 성공 / 1 --force 동반(계약 위반) / 2 조건 미충족(상태 무변경) /
# 3 Status 파싱 불가·미러 섹션 부재(상태 무변경) 등 판정·쓰기 실패
task_reset_title() {
  local force="${1:-0}" status fb fb_val
  if [[ "$force" == "1" ]]; then
    echo "set-title: reset('-')은 --force 를 지원하지 않습니다 — 진행 중인 작업을 우회로 지우지 못하게 하는 의도된 제약입니다." >&2
    echo "  정말 막혔다면 그 작업을 archive 하세요." >&2
    return 1
  fi
  status="$(task_read_status 2>/dev/null)" || {
    echo "set-title: '## Status' 를 확인할 수 없어 reset 을 거부합니다 (상태 변경 없음)." >&2
    return 3
  }
  [[ "$status" == "실행 중" ]] && status="구현 중"
  fb="$(_fr_branch_active)"
  if [[ "$status" != "대기 중" || "$fb" == "active" || "$fb" == "query-failed" ]]; then
    fb_val="$(state_read_field "fr-branch")"
    echo "set-title: reset 을 거부합니다 (상태 변경 없음) — 조건: Status='대기 중' 이고 fr-branch 가 활성이 아니어야 합니다 (현재 Status='${status}', fr-branch='${fb_val}')." >&2
    echo "  다음 중 하나를 선택하세요: ① 제목을 브랜치 slug 에 맞춰 그 작업을 계속한다 ② 그 작업을 archive 한다." >&2
    return 2
  fi
  if ! _task_section_exists "Short Title"; then
    echo "set-title: CURRENT_TASK.md 에 '## Short Title' 섹션이 없어 중단합니다 (상태 변경 없음)." >&2
    return 3
  fi
  if state_file_exists; then
    state_write_fields "short-title=-" "source-fr=-" || return 3
  fi
  _task_section_write "Short Title" "-" || return 3
  _task_source_fr_mirror_write "-" || return 3
  return 0
}

# ---------------------------------------------------------------------------
# rd task fr-done — 묶은 FR 전부의 items/인덱스 status 를 done 으로 (change spec
# §2.5.1·§2.5.2, 리뷰 F1·F2)
# ---------------------------------------------------------------------------

# _fr_done_items_step <canonical-path> — items/<file>.md 의 '- status:' 를 done 으로.
# stdout: 사람이 보는 한 줄 보고 ("  items: ..."). return: 0=변경함 / 1=실패 / 2=건너뜀(이미 종료 상태)
_fr_done_items_step() {
  local rel="${1-}" abs cur tmp
  abs="${project_root}/${rel}"
  if [[ ! -f "$abs" ]]; then
    printf '  items: 실패 — 파일을 찾을 수 없습니다 (%s)\n' "$rel"
    return 1
  fi
  cur="$(awk -F': *' '/^- status:/{print $2; exit}' "$abs" 2>/dev/null)"
  cur="$(_sfr_trim "$cur")"
  if [[ -z "$cur" ]]; then
    printf "  items: 실패 — '- status:' 필드를 찾을 수 없습니다 (%s)\n" "$rel"
    return 1
  fi
  if [[ "$cur" == "done" || "$cur" == "dropped" ]]; then
    printf '  items: 건너뜀 (이미 %s)\n' "$cur"
    return 2
  fi
  tmp="$(mktemp)" || { printf '  items: 실패 — 임시 파일 생성 실패 (mktemp)\n'; return 1; }
  [[ -n "$tmp" && -f "$tmp" ]] || { printf '  items: 실패 — 임시 파일 경로 검증 실패\n'; return 1; }
  if ! awk 'BEGIN{done=0} /^- status:/ && !done { print "- status: done"; done=1; next } { print }' "$abs" > "$tmp"; then
    rm -f "$tmp"
    printf '  items: 실패 — 쓰기 처리(awk) 실패 (%s)\n' "$rel"
    return 1
  fi
  if ! mv "$tmp" "$abs"; then
    rm -f "$tmp"
    printf '  items: 실패 — 쓰기 실패 (%s)\n' "$rel"
    return 1
  fi
  printf '  items: done (이전값: %s)\n' "$cur"
  return 0
}

# _fr_done_index_step <slug> — FUTURE_REQUESTS.md 인덱스 행의 상태 컬럼을 done 으로.
# 행 매칭 기준: '제목' 컬럼 값이 slug 와 정확히 같은 행. 컬럼 위치는 헤더(`제목`·`상태`
# 라는 이름)에서 계산한다 — 인덱스 스키마가 바뀌어도 하드코딩된 컬럼 번호가 조용히
# 틀린 셀을 바꾸지 않도록 하기 위함이다. '요약' 컬럼처럼 이스케이프된 '\|' 를 담은
# 셀이 실제로 존재하므로, 먼저 '\|' 를 자리표시자로 치환한 뒤 '|' 로 쪼개고 되돌린다.
# stdout: 사람이 보는 한 줄 보고 ("  인덱스: ..."). return: 0=변경함 / 1=실패 /
# 2=건너뜀(이미 종료 상태) / 3=행 부재(실패로 세지 않는다, change spec §2.5.1)
_fr_done_index_step() {
  local slug="${1-}" f="${project_root}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
  local tmp sf found changed rc
  if [[ ! -f "$f" ]]; then
    printf '  인덱스: 행 부재 (FUTURE_REQUESTS.md 없음)\n'
    return 3
  fi
  tmp="$(mktemp)" || { printf '  인덱스: 실패 — 임시 파일 생성 실패 (mktemp)\n'; return 1; }
  [[ -n "$tmp" && -f "$tmp" ]] || { printf '  인덱스: 실패 — 임시 파일 경로 검증 실패\n'; return 1; }
  sf="$(mktemp)" || { rm -f "$tmp"; printf '  인덱스: 실패 — 임시 파일 생성 실패 (mktemp)\n'; return 1; }
  [[ -n "$sf" && -f "$sf" ]] || { rm -f "$tmp" "$sf"; printf '  인덱스: 실패 — 임시 파일 경로 검증 실패\n'; return 1; }
  awk -v slug="$slug" -v newv="done" -v sf="$sf" '
    function esc_split(line, arr,    t, i, n) {
      t = line
      gsub(/\\\|/, "@@ESCPIPE@@", t)
      n = split(t, arr, "|")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+/, "", arr[i]); gsub(/[ \t]+$/, "", arr[i])
        gsub(/@@ESCPIPE@@/, "\\|", arr[i])
      }
      return n
    }
    BEGIN { title_idx = 0; status_idx = 0; found = 0; changed = 0 }
    {
      line = $0
      if (title_idx == 0 && line ~ /^\|/ && index(line, "제목") && index(line, "상태")) {
        n = esc_split(line, hdr)
        for (i = 1; i <= n; i++) {
          if (hdr[i] == "제목") title_idx = i
          if (hdr[i] == "상태") status_idx = i
        }
        print line; next
      }
      if (title_idx > 0 && status_idx > 0 && line ~ /^\|/ && line !~ /^\|[-: ]+\|/) {
        n = esc_split(line, fld)
        if (n >= title_idx && fld[title_idx] == slug) {
          found = 1
          if (n >= status_idx) {
            cur = fld[status_idx]
            if (cur != "done" && cur != "dropped") { fld[status_idx] = newv; changed = 1 }
            # 재구성은 **실제 셀만**(2..n-1) 돈다. split 은 바깥쪽 구분자에 해당하는
            # 처음·마지막 빈 원소도 돌려주므로, 1..n 을 그대로 출력하면 7열 행이
            # 9열이 되어 상태 칸이 한 칸 밀린다 (final diff review F1 — 실측 손상).
            out = "|"
            for (i = 2; i <= n - 1; i++) { out = out " " fld[i] " |" }
            print out
            next
          }
        }
      }
      print line
    }
    END {
      print "FOUND=" found > sf
      print "CHANGED=" changed >> sf
    }
  ' "$f" > "$tmp"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tmp" "$sf"
    printf '  인덱스: 실패 — awk 처리 실패\n'
    return 1
  fi
  found="$(awk -F= '$1=="FOUND"{print $2}' "$sf" 2>/dev/null)"
  changed="$(awk -F= '$1=="CHANGED"{print $2}' "$sf" 2>/dev/null)"
  rm -f "$sf"
  if [[ "$found" != "1" ]]; then
    rm -f "$tmp"
    printf '  인덱스: 행 부재 (slug=%s)\n' "$slug"
    return 3
  fi
  if [[ "$changed" == "1" ]]; then
    if ! mv "$tmp" "$f"; then
      rm -f "$tmp"
      printf '  인덱스: 실패 — 쓰기 실패\n'
      return 1
    fi
    printf '  인덱스: done\n'
    return 0
  fi
  rm -f "$tmp"
  printf '  인덱스: 건너뜀 (이미 종료 상태)\n'
  return 2
}

# task_fr_done [<path>...] — 묶은 FR 전부의 items status + 인덱스 status 를 done 으로
# (change spec §2.5.1·§2.5.2). 인자 없으면 task-state 의 source-fr 집합이 대상이고,
# 인자가 있으면 그 경로들이 대상이다(발행 후 재시도 경로, §2.5.4).
#
# 두 자리(items·인덱스)를 **독립적으로** 판정한다 — items 가 이미 done 이어도 인덱스가
# 활성이면 인덱스만 갱신한다(초안의 "일괄 skip" 이 F1 의 잔존 통로였다). 인덱스 행
# **삭제**는 하지 않는다 — `/fr archive` 몫이다(여기서는 status 만 바꾼다).
#
# FR 단위 판정: 두 단계 중 하나라도 진짜 실패(파일 부재 등)면 그 FR 은 실패다(인덱스
# 행 부재는 실패로 세지 않는다 — return 3). 실패가 없고 둘 중 하나라도 상태를 바꿨다면
# 처리(N), 아니면(둘 다 이미 종료 상태·행 부재) 건너뜀(M)이다.
#
# stdout: FR 별 두 단계 결과 + 요약(`처리 N / 건너뜀 M / 실패 K`) + 실패 목록(이름).
# return: 0 = 실패 없음 / 1 = 실패 1건 이상. 호출부는 이 실패로 발행을 중단하지 않는다
# (AC C-17) — completion report 로 넘긴다.
task_fr_done() {
  local list="" target processed=0 skipped=0 failed=0 fail_names=""
  if [[ $# -gt 0 ]]; then
    # 직접 인자는 **경계 그대로** 검증한다 (final diff review F5). 검증이 없으면
    # `fr-done ../outside.md` 가 items/ 밖 파일의 `- status:` 를 고치고 성공으로
    # 보고한다 — 발행 후 재시도 안내에 잘못된 상대경로를 넣으면 FR 과 무관한
    # 문서가 바뀐다. 개행이 든 인자 하나가 여러 대상이 되는 경계 유실도 함께 막는다.
    local arg_fail=0
    for target in "$@"; do
      case "$target" in
        *"
"*) echo "fr-done: 인자 하나에 개행을 포함할 수 없습니다 (인자마다 따로 지정하세요): '${target}'" >&2
            arg_fail=1; continue ;;
      esac
      if ! source_fr_validate "$target" || [[ "$target" == "-" ]]; then
        echo "fr-done: FR 경로 계약 위반 — ${_SFR_ITEMS_PREFIX}/<파일>.md 만 허용: '${target}'" >&2
        arg_fail=1; continue
      fi
      list="${list:+${list}$'\n'}${target}"
    done
    if [[ "$arg_fail" -eq 1 ]]; then
      echo "fr-done: 인자 검증에 실패해 **아무 것도 바꾸지 않았습니다** (위 항목을 전부 고치세요)." >&2
      return 1
    fi
  else
    local sfr_raw
    sfr_raw="$(state_read_field "source-fr")"
    list="$(source_fr_split "$sfr_raw" "$project_root")"
  fi
  if [[ -z "$(_sfr_trim "$list")" ]]; then
    echo "fr-done: 대상이 없습니다."
    return 0
  fi

  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    echo "FR: ${target}"
    local slug items_out items_rc index_out index_rc
    # 저장값에서 읽은 대상도 쓰기 전에 형식을 본다 — 손상된 task-state 가
    # items/ 밖을 가리키면 그대로 고치게 된다 (final diff review F5).
    if ! source_fr_validate "$target" || [[ "$target" == "-" ]]; then
      printf '  items: 실패 — FR 경로 계약 위반 (%s 만 허용)\n' "${_SFR_ITEMS_PREFIX}/<파일>.md"
      printf '  인덱스: 건너뜀 — 경로 계약 위반으로 판정하지 않음\n'
      failed=$((failed + 1))
      fail_names="${fail_names:+${fail_names}$'\n'}${target}"
      continue
    fi
    slug="$(_task_source_fr_slug_from_path "$target")"
    items_out="$(_fr_done_items_step "$target")"; items_rc=$?
    printf '%s\n' "$items_out"
    index_out="$(_fr_done_index_step "$slug")"; index_rc=$?
    printf '%s\n' "$index_out"

    if [[ "$items_rc" -eq 1 || "$index_rc" -eq 1 ]]; then
      failed=$((failed + 1))
      fail_names="${fail_names:+${fail_names}$'\n'}${target}"
      continue
    fi
    if [[ "$items_rc" -eq 0 || "$index_rc" -eq 0 ]]; then
      processed=$((processed + 1))
    else
      skipped=$((skipped + 1))
    fi
  done <<< "$list"

  echo "---"
  echo "요약: 처리 ${processed} / 건너뜀 ${skipped} / 실패 ${failed}"
  if [[ "$failed" -gt 0 ]]; then
    echo "실패 목록:"
    while IFS= read -r _fn; do
      [[ -n "$_fn" ]] && echo "  - ${_fn}"
    done <<< "$fail_names"
    return 1
  fi
  return 0
}
