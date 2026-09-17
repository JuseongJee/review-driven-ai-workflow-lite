#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# project_root 를 source 이전에 확정한다 — _lifecycle_common.sh → _state_common.sh 가
# TASK_STATE_PATH 를 source 시점에 굳히므로, 순서를 바꾸면 상태가 엉뚱한 파일에 기록된다.
# 주입값 우선(테스트), 없으면 스크립트 위치 기준(promote.sh 와 동일 규약 — 이 스크립트의
# "실행 중인 worktree" 판정이 project_root 로 그 worktree 를 식별한다).
if [[ -z "${project_root:-}" ]]; then
  project_root="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
if [[ ! -d "${project_root}/rd-workflow-workspace" ]]; then
  echo "rollback: 프로젝트 루트를 확정할 수 없습니다: '${project_root}' 에 rd-workflow-workspace/ 가 없습니다." >&2
  echo "  확인: ls -d '${project_root}/rd-workflow-workspace'" >&2
  exit 3
fi
export project_root
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"
# 대상 선택은 단일 출처(task_resolve_target, Task 3)를 그대로 쓴다 — 판정 로직을
# 여기서 복제하지 않는다. _task_common.sh 가 tasks_index_*·tasks_lock_*(Task 1) 도
# 함께 source 한다.
source "$SCRIPT_DIR/../_task_common.sh"

# ===========================================================================
# promote_rollback.sh — 여러 FR 작업을 worktree 로 동시에 진행할 수 있게 되면서
# (task-4-brief) rollback 도 "어느 작업을 되돌릴지" 를 골라야 한다. 잘못 고르면
# 다른 작업의 worktree·branch·진행 상태가 지워지는 파괴적 명령이므로, 대상 판정은
# task_resolve_target 에 위임하고 이 스크립트는 그 결과로 나온 "그 작업 하나" 만
# 건드린다.
#
# 기존 설계(단일 진행 FR, main worktree 에 metadata 를 두는 방식)와 달리, 지금은
# main worktree 의 task-state 가 항상 baseline 이고 어느 작업도 대표하지 않는다
# (promote.sh 재설계 확정 사항). 그래서 rollback 이 되돌릴 "그 작업의 상태" 는
# 지워질 fr 브랜치·worktree 안에만 있고, main worktree 의 CURRENT_TASK.md·
# task-state 를 다시 쓸 이유가 없다 — worktree 와 branch 를 지우면 그 작업의
# 상태도 함께 사라진다.
# ===========================================================================

DRY_RUN=0; TASK_ARG=""; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    # `--force` — "살아 있을 수 있는 세션과 커밋되지 않은 작업물을 알고도 버린다" 를
    # 사용자가 표현하는 유일한 경로다 (final diff review F6). rollback 은 원래 취소
    # 명령이므로 보호를 넣되 취소 자체를 불가능하게 만들지 않는다. 이름은 이 저장소의
    # 기존 관례(archive.sh 의 `--force-dirty`·`--force-skip-review-check`)를 따른다.
    --force) FORCE=1; shift ;;
    -h|--help) printf '%s\n' "usage: promote_rollback.sh [--task <slug>] [--force] [--dry-run]"; exit 0 ;;
    # `--fr-branch` 는 받지 않는다. 대상 지정은 작업 단위(`--task <slug>`)로 통일했고,
    # 별칭을 남기면 "브랜치 이름이 대상을 정한다" 는 옛 모형이 함께 살아남는다 —
    # 지금 대상 판정의 단일 출처는 `task_resolve_target` 이고 입력은 slug 다.
    *) printf 'rollback: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

cd "$project_root"

# --- 대상 판정 (읽기 전용 — 여기까지는 아무것도 바꾸지 않는다) ---
#   미지정 + 현재 worktree 가 어느 작업의 checkout: 그 작업이 기본 대상.
#   미지정 + 기본 브랜치 worktree(어느 작업의 checkout 도 아님) + 작업 2건 이상:
#     아무것도 바꾸지 않고 목록 + --task 안내와 함께 실패한다.
RESOLVED="$(task_resolve_target read "$TASK_ARG")" || exit 1
KIND="${RESOLVED%%$'\t'*}"
VALUE="${RESOLVED#*$'\t'}"

# **요청 slug 를 끝까지 유지한다** (final diff review F2). 예전에는 resolver 가 준 경로의
# 현재 HEAD 로 TARGET_BRANCH·SLUG 를 다시 정했는데, 색인이 낡아 그 경로가 다른 작업의
# 체크아웃이면 `rollback --task A` 가 **B 의 worktree 를 지우고 B 브랜치를 삭제**했다.
# 지금은 경로의 HEAD 를 대상 산출에 쓰지 않고 **기대와 일치하는지 검사에만** 쓴다 —
# 불일치면 아무것도 바꾸지 않고 멈춘다.
case "$KIND" in
  checkout)
    TARGET_DIR="$VALUE"
    if [[ -n "$TASK_ARG" ]]; then
      SLUG="$TASK_ARG"
      TARGET_BRANCH="fr/${SLUG}"
    else
      # 대상 미지정 — 이 경로 자체가 대상이다(현재 worktree 또는 단일 작업). 이 경우의
      # 요청 slug 는 애초에 "이 체크아웃" 이므로 HEAD 에서 읽는 것이 곧 요청 그대로다.
      TARGET_BRANCH="$(git -C "$TARGET_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" || TARGET_BRANCH=""
      if [[ -z "$TARGET_BRANCH" || "$TARGET_BRANCH" != fr/* ]]; then
        printf 'rollback: worktree(%s) 의 체크아웃 브랜치를 확인할 수 없습니다(fr/* 아님) — 중단합니다 (상태 변경 없음).\n' "$TARGET_DIR" >&2
        exit 1
      fi
      SLUG="${TARGET_BRANCH#fr/}"
    fi
    # 경로의 HEAD 가 기대와 다르면 무변경 중단 — resolver 가 git 대조로 걸러 주지만,
    # 그 사이에 체크아웃이 바뀌었을 수 있으므로 파괴적 동작 직전에 한 번 더 확인한다.
    _head_now="$(git -C "$TARGET_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" || _head_now=""
    if [[ "$_head_now" != "$TARGET_BRANCH" ]]; then
      printf 'rollback: 대상 worktree(%s) 의 체크아웃이 기대와 다릅니다 (기대=%s, 실제=%s) — 중단합니다 (상태 변경 없음).\n' \
        "$TARGET_DIR" "$TARGET_BRANCH" "${_head_now:-detached}" >&2
      printf '  색인이 낡았을 수 있습니다: bash rd-workflow/scripts/rd task list --rebuild\n' >&2
      exit 1
    fi
    ;;
  ref)
    TARGET_BRANCH="$VALUE"
    SLUG="${TARGET_BRANCH#fr/}"
    TARGET_DIR=""
    # 색인은 "비체크아웃" 이라는데 git 은 그 브랜치가 어딘가에 체크아웃돼 있다고 말하면
    # 둘 중 git 이 권위다 — 그 상태로 진행하면 `git branch -D` 가 raw 오류로 죽거나
    # 남의 작업 공간을 건드린다. 무변경으로 멈추고 색인 재구성을 안내한다.
    _wt_of_branch="$(_task_branch_checkout_path "$TARGET_BRANCH" 2>/dev/null)" || _wt_of_branch=""
    if [[ -n "$_wt_of_branch" ]]; then
      printf 'rollback: 색인은 %s 가 비체크아웃이라고 하지만 실제로는 %s 에 체크아웃돼 있습니다 — 중단합니다 (상태 변경 없음).\n' \
        "$TARGET_BRANCH" "$_wt_of_branch" >&2
      printf '  색인을 git 기준으로 다시 맞춘 뒤 재시도하십시오: bash rd-workflow/scripts/rd task list --rebuild\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'rollback: 대상 판정 결과를 해석할 수 없습니다: %s\n' "$RESOLVED" >&2
    exit 1
    ;;
esac

# 대상이 **기본 worktree(main worktree)** 인가 — `--no-worktree` 로 착수하면 그 작업의
# 체크아웃이 곧 기본 worktree 자체다 (final diff review F5). 이 경우 worktree 를 제거하는
# 경로로 가면 안 된다: git 이 main worktree 제거를 거부하고, "기본 worktree 로 가서 같은
# 명령을 실행하라" 는 안내는 이미 거기 서 있는 사용자에게 무한 루프였다. 제거 대신
# **체크아웃을 기본 브랜치로 되돌리고** fr 브랜치·색인 행만 정리한다.
MAIN_WT_PATH="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
IS_MAIN_WT=0
if [[ -n "$TARGET_DIR" ]]; then
  _main_real="$(cd "$MAIN_WT_PATH" 2>/dev/null && pwd -P)" || _main_real=""
  _target_real="$(cd "$TARGET_DIR" && pwd -P)"
  [[ -n "$_main_real" && "$_main_real" == "$_target_real" ]] && IS_MAIN_WT=1
fi

# 대상 worktree 가 현재 실행 중인 worktree 이면 제거하지 않는다 — 이 셸이 서 있는
# 자리 자체를 지우면 이후 모든 동작(락 해제 포함)이 존재하지 않는 cwd 위에서 실행된다.
#   단 **기본 worktree 는 애초에 제거 대상이 아니므로** 이 가드에 걸리지 않는다(위 F5).
if [[ -n "$TARGET_DIR" && "$IS_MAIN_WT" -eq 0 ]]; then
  _cwd_real="$(cd "$project_root" && pwd -P)"
  _target_real="$(cd "$TARGET_DIR" && pwd -P)"
  if [[ "$_cwd_real" == "$_target_real" ]]; then
    printf 'rollback: 대상 worktree(%s)가 현재 실행 중인 worktree 입니다 — 여기서 자기 자신을 지울 수 없습니다 (상태 변경 없음).\n' "$TARGET_DIR" >&2
    printf '  기본 worktree 에서 실행하세요: cd %q && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s\n' "$MAIN_WT_PATH" "$SLUG" >&2
    exit 1
  fi
fi

# Already-archived guard — 동일 slug 의 fr/*/<slug> tag 검색
EXISTING_TAGS="$(git tag --list "fr/*/$SLUG" 2>/dev/null || true)"
if [[ -n "$EXISTING_TAGS" ]]; then
  printf 'rollback: 이 fr 는 이미 archive 되었습니다 (tag: %s). git revert 등 별도 절차 사용.\n' "$EXISTING_TAGS" >&2
  exit 1
fi

# 대상 worktree 의 미커밋 변경 요약 (F6). "무엇을 잃는가" 를 **삭제 전에** 보여주기
# 위한 것이므로, 개수만이 아니라 앞부분 몇 줄을 그대로 낸다.
#
# **실제로 파일이 사라지는 경로에서만 의미가 있다.** 기본 worktree 대상(`--no-worktree`
# 착수)은 worktree 를 제거하지 않고 체크아웃만 되돌리므로 미커밋 변경이 그대로 남는다
# (되돌릴 수 없으면 `git switch` 자체가 거부하고 아래에서 무변경 중단한다). 그 경로까지
# 막으면 지워지지도 않을 파일을 이유로 취소를 거부하게 된다.
#
# `rd-workflow-workspace/.lifecycle/` 아래는 제외한다 — loop-state·review-seals 같은
# 워크플로 장부이고 promote 가 다시 만든다. 사용자의 작업물이 아니라서 이것 때문에
# 취소가 막히면 가드가 본래 지키려던 것(사람이 쓴 코드)과 무관한 마찰만 남는다.
_rb_dirty_lines() {
  [[ "${IS_MAIN_WT:-0}" -eq 0 ]] || return 0
  [[ -n "${TARGET_DIR:-}" && -d "$TARGET_DIR" ]] || return 0
  # **`--untracked-files=all` 을 명시한다** (final diff review F6 잔여). 맨 `status
  # --porcelain` 은 사용자의 `status.showUntrackedFiles` 설정을 따르므로, 그 값이 `no` 인
  # 사용자에게는 **새로 만든 미추적 코드가 검사에서도 `--dry-run` 손실 목록에서도 함께
  # 사라진다** — 보호가 있어야 할 때 조용히 없어지고, 사용자는 취소 전에 위험을 볼 수도
  # 없다. 보호 검사는 표시 설정에 의존해서는 안 되므로 여기서 값을 못박는다.
  # `-c` 로 주는 것은 이 한 번의 호출에만 적용되고 사용자 설정을 바꾸지 않는다.
  git -C "$TARGET_DIR" -c status.showUntrackedFiles=all status --porcelain --untracked-files=all 2>/dev/null \
    | grep -v ' rd-workflow-workspace/\.lifecycle/' || true
}

_rb_print_dirty() {  # <porcelain-output>
  local lines="$1" n
  n="$(printf '%s\n' "$lines" | grep -c '[^[:space:]]' || true)"
  printf '  미커밋 변경 %s건 (앞 10건):\n' "$n" >&2
  printf '%s\n' "$lines" | head -10 | sed 's/^/    /' >&2
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  # dry-run 도 "무엇을 잃는가" 를 보여준다 — 이것이 파괴 전 확인 수단이다.
  _dry_launch="$(tasks_index_get "$SLUG" launch 2>/dev/null)" || _dry_launch=""
  printf 'rollback: 세션 상태 launch=%s\n' "${_dry_launch:-(없음)}"
  _dry_dirty="$(_rb_dirty_lines)"
  if [[ -n "$_dry_dirty" ]]; then
    printf 'rollback: 대상 worktree 에 미커밋 변경이 있습니다 — 실제 실행은 --force 없이는 거부됩니다.\n'
    _rb_print_dirty "$_dry_dirty"
  fi
  if [[ "$IS_MAIN_WT" -eq 1 ]]; then
    printf 'would rollback %s (기본 worktree — 제거하지 않고 기본 브랜치로 되돌림: %s)\n' "$TARGET_BRANCH" "$TARGET_DIR"
  else
    printf 'would rollback %s (worktree=%s)\n' "$TARGET_BRANCH" "${TARGET_DIR:-<미체크아웃>}"
  fi
  exit 0
fi

# --- 공유 색인 락 — 실패하면 무변경 종료. rc 1(정상 점유 중)과 rc 2(owner 불확실 —
#     회수해야 풀린다)는 안내를 구분한다(promote.sh 와 같은 계약). ---
if tasks_lock_acquire rollback "$SLUG"; then
  :
else
  _lock_rc=$?
  if [[ "$_lock_rc" -eq 2 ]]; then
    printf 'rollback: 락 상태가 불확실합니다 — 위 stderr 안내(rm -rf 명령)를 확인해 다른 프로세스가 없음을 검증한 뒤 회수하고 재시도하십시오.\n' >&2
  else
    printf 'rollback: 다른 작업이 색인을 쓰는 중입니다 — 잠시 후 다시 시도하세요.\n' >&2
  fi
  exit 1
fi
LOCK_HELD=1
_rollback_on_exit() {
  local ec=$?
  if [[ "${LOCK_HELD:-0}" -eq 1 ]]; then
    tasks_lock_release
    LOCK_HELD=0
  fi
  return 0
}
trap '_rollback_on_exit' EXIT

# 기동 예약(launching) 중이거나 확정되지 않은(unknown) 세션은 되돌리지 않는다 —
# promote.sh 는 worktree 부착·branch 체크아웃·색인 등록을 먼저 끝낸 뒤 launch=launching
# 을 기록하고 **락을 풀고** 그 밖에서 session_launch 를 호출한다. 그 구간(락이 없고
# worktree 는 이미 완전히 살아 있는 구간)에 rollback 이 끼어들면 막 기동됐거나 기동
# 중인 에이전트 세션의 worktree·branch 를 통째로 지운다(spec 169행 — launching 인
# 작업에 rollback·archive 는 진행하지 않고 무변경으로 멈춘다). unknown 을 none 으로
# 취급하지 않는다 — "확인 안 됨" 은 "없음" 이 아니다.
_launch="$(tasks_index_get "$SLUG" launch 2>/dev/null)" || _launch=""
case "$_launch" in
  launching|unknown)
    printf 'rollback: '"'"'%s'"'"' 의 기동 결과가 아직 확인되지 않았습니다(launch=%s) — rollback 을 진행하지 않습니다 (상태 변경 없음).\n' "$SLUG" "$_launch" >&2
    printf '  확인: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$SLUG" >&2
    printf '  herdr 로 조회할 수 없는 환경이면: bash rd-workflow/scripts/rd task resolve-launch %s --assume-ended\n' "$SLUG" >&2
    exit 1
    ;;
  ok)
    # **보호가 거꾸로였다** (final diff review F6). 예전에는 "살아 있는지 불확실할 때"
    # (launching·unknown) 막고 "살아 있음이 확인됐을 때"(ok) 통과시켰다 — 정상 기동된
    # 세션이 미커밋 코드를 쓰고 있는 동안 그 worktree 를 통째로 지우는 경로였다(AC 16).
    # 지금 생존을 다시 확인해, 살아 있거나 판정이 서지 않으면 보존한다.
    _rb_probe="$(session_probe "$SLUG" "${TARGET_DIR:-}")"
    if [[ "$_rb_probe" == "dead" ]]; then
      printf 'rollback: '"'"'%s'"'"' 세션이 이미 종료된 것으로 확인됐습니다 — 취소를 계속합니다.\n' "$SLUG"
    elif [[ "$FORCE" -eq 1 ]]; then
      printf 'rollback: WARNING — '"'"'%s'"'"' 세션이 살아 있거나 판정이 서지 않습니다(probe=%s). --force 로 계속합니다.\n' "$SLUG" "$_rb_probe" >&2
    else
      printf 'rollback: '"'"'%s'"'"' 에 기동된 에이전트 세션이 있습니다(launch=ok, probe=%s) — 그 세션의 작업을 지우지 않기 위해 취소하지 않습니다 (상태 변경 없음).\n' "$SLUG" "$_rb_probe" >&2
      # **안내는 probe 결과에 따라 갈라야 한다** (final diff review F9 잔여). 예전에는
      # 어느 경우든 「세션을 끝내고 같은 명령을 재시도」만 제시했는데, probe 가 unknown
      # 이면(herdr 밖 셸 등) 실제로 끝낸 뒤 재시도해도 판정이 그대로라 **같은 거부가
      # 반복된다.** 그러면 사용자에게 보이는 유일한 출구가 `--force` 인데, 그것은 생존
      # 가드와 **미커밋 작업물 보호를 함께** 해제한다 — 보호를 지키는 경로를 만들어 놓고
      # 막힌 화면에 적지 않으면 없는 것과 같다.
      if [[ "$_rb_probe" == "alive" ]]; then
        printf '  먼저 그 세션을 끝내십시오 (herdr 화면에서 해당 tab/agent 종료).\n' >&2
        printf '  종료 뒤 재시도: bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s\n' "$SLUG" >&2
      else
        printf '  이 셸에서는 세션 생존을 확인할 수 없습니다 — 끝낸 뒤 그냥 재시도해도 같은 결과가 나옵니다.\n' >&2
        printf '  세션을 끝냈고 그 사실을 직접 확인했다면, 먼저 종료를 확정한 뒤 다시 취소하십시오:\n' >&2
        printf '    bash rd-workflow/scripts/rd task resolve-launch %s --assume-ended\n' "$SLUG" >&2
        printf '    bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s\n' "$SLUG" >&2
        printf '  (이 경로는 커밋되지 않은 작업물 보호를 유지합니다.)\n' >&2
      fi
      printf '  세션째 버려도 된다면: bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s --force\n' "$SLUG" >&2
      printf '    주의 — --force 는 세션 보호뿐 아니라 **커밋되지 않은 작업물 보호까지** 함께 해제합니다.\n' >&2
      exit 1
    fi
    ;;
esac

# 미커밋 작업물 보호 (F6) — worktree 제거는 `--force` 이므로 커밋되지 않은 변경을 되찾을
# 수 없다. 무엇을 잃는지 먼저 보이고, 기본 동작으로는 지우지 않는다.
_rb_dirty="$(_rb_dirty_lines)"
if [[ -n "$_rb_dirty" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    printf 'rollback: WARNING — 미커밋 변경을 --force 로 버립니다.\n' >&2
    _rb_print_dirty "$_rb_dirty"
  else
    printf 'rollback: 대상 worktree(%s)에 커밋되지 않은 변경이 있습니다 — 취소하지 않습니다 (상태 변경 없음).\n' "$TARGET_DIR" >&2
    _rb_print_dirty "$_rb_dirty"
    printf '  남기려면 먼저 커밋하거나 stash 하십시오: git -C %q stash -u\n' "$TARGET_DIR" >&2
    printf '  버려도 된다면: bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s --force\n' "$SLUG" >&2
    exit 1
  fi
fi

# --- 대상 작업의 것만 되돌린다 — 다른 작업의 worktree·branch·상태·색인 행과 실행
#     중인 세션이 만든 변경은 건드리지 않는다(AC 16). ---
if [[ "$IS_MAIN_WT" -eq 1 ]]; then
  # 기본 worktree 는 제거하지 않는다 (F5). 그 체크아웃이 아직 대상 fr 브랜치 위에 있으면
  # 기본 브랜치로 되돌린다 — 되돌리지 않으면 아래 `git branch -D` 가 "체크아웃 중" 이라며
  # 거부한다. 되돌리기에 실패하면(예: 커밋되지 않은 변경) 무변경으로 멈춘다.
  _rb_default="$(get_default_branch 2>/dev/null)" || _rb_default=""
  _rb_head="$(git -C "$TARGET_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" || _rb_head=""
  if [[ "$_rb_head" == "$TARGET_BRANCH" ]]; then
    if [[ -z "$_rb_default" ]]; then
      printf 'rollback: 기본 브랜치를 확인할 수 없어 체크아웃을 되돌리지 못했습니다 — 중단합니다 (상태 변경 없음).\n' >&2
      exit 1
    fi
    if ! git -C "$TARGET_DIR" switch -q "$_rb_default"; then
      printf 'rollback: 기본 브랜치(%s)로 되돌리지 못했습니다 — 커밋되지 않은 변경이 있는지 확인하십시오 (상태 변경 없음).\n' "$_rb_default" >&2
      exit 1
    fi
    printf 'rollback: 기본 worktree 의 체크아웃을 기본 브랜치(%s)로 되돌렸습니다 (--no-worktree 착수).\n' "$_rb_default"
  fi
elif [[ -n "$TARGET_DIR" ]]; then
  if ! git worktree remove --force "$TARGET_DIR"; then
    printf 'rollback: worktree remove %s 실패\n' "$TARGET_DIR" >&2
    exit 1
  fi
fi

# Worktree 등록만 남은 stale entry 정리 (repo 전역이지만 이미 사라진 디렉터리만
# 대상으로 삼는 git 자체 동작이라 살아있는 다른 작업의 worktree 는 건드리지 않는다).
git worktree prune

# Branch 강제 삭제 (대상 branch 만)
if git rev-parse --verify --quiet "refs/heads/${TARGET_BRANCH}" >/dev/null 2>&1; then
  git branch -D "$TARGET_BRANCH"
fi

# 색인 행 제거 (대상 slug 만 — 다른 작업의 행은 tasks_index_remove 의 slug 단위 계약으로 보존된다)
tasks_index_remove "$SLUG"


printf 'rollback: 완료. removed=%s (slug=%s)\n' "$TARGET_BRANCH" "$SLUG"
exit 0
