#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"

DRY_RUN=0; FR_BRANCH_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fr-branch) FR_BRANCH_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) printf '%s\n' "usage: promote_rollback.sh [--fr-branch fr/<ref>] [--dry-run]"; exit 0 ;;
    *) printf 'rollback: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# 기본 브랜치 worktree 검증
MAIN_WT="$(get_main_worktree_path)" || { printf 'rollback: 기본 브랜치 worktree 검출 실패\n' >&2; exit 1; }
CURRENT_WT="$(git rev-parse --show-toplevel)" || { printf 'rollback: git repo 외부에서 실행 불가\n' >&2; exit 1; }
if [[ "$MAIN_WT" != "$CURRENT_WT" ]]; then
  DB="$(get_default_branch)"
  printf 'rollback: 기본 브랜치(%s) worktree에서 호출하세요. 해당 worktree path: %s\n' "$DB" "$MAIN_WT" >&2; exit 1
fi

# FR identity 결정 — --fr-branch > metadata
TARGET="$FR_BRANCH_OVERRIDE"
if [[ -z "$TARGET" ]]; then
  TARGET="$(metadata_read_field fr-branch)"
fi
if [[ -z "$TARGET" ]]; then
  printf 'rollback: target 결정 실패. metadata 부재 시 --fr-branch fr/<ref> 명시 필요.\n' >&2; exit 1
fi
[[ "$TARGET" == fr/* ]] || { printf 'rollback: 잘못된 fr ref: %s\n' "$TARGET" >&2; exit 1; }

# Override mismatch guard — override 가 active metadata 와 다르면 unrelated FR metadata 손상을 막기 위해 중단.
if [[ -n "$FR_BRANCH_OVERRIDE" ]] && metadata_exists; then
  ACTIVE_FR="$(metadata_read_field fr-branch)"
  if [[ -n "$ACTIVE_FR" && "$ACTIVE_FR" != "$FR_BRANCH_OVERRIDE" ]]; then
    printf 'rollback: --fr-branch %s 가 active metadata (%s) 와 불일치 — 중단합니다.\n' "$FR_BRANCH_OVERRIDE" "$ACTIVE_FR" >&2
    printf '  active FR 을 rollback 하려면: 인자 없이 promote_rollback.sh 호출\n' >&2
    printf '  active 가 아닌 다른 ref 를 정리하려면: 먼저 active FR 을 정리한 뒤 호출\n' >&2
    exit 1
  fi
fi

SLUG="${TARGET#fr/}"

# Already-archived guard — 동일 slug 의 fr/*/<slug> tag 검색
EXISTING_TAGS="$(git tag --list "fr/*/$SLUG" 2>/dev/null || true)"
if [[ -n "$EXISTING_TAGS" ]]; then
  printf 'rollback: 이 fr 는 이미 archive 되었습니다 (tag: %s). git revert 등 별도 절차 사용.\n' "$EXISTING_TAGS" >&2; exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'would rollback %s\n' "$TARGET"; exit 0
fi

# Worktree 강제 제거 (whitespace-safe + process substitution)
FAILED_WT=""
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  [[ -d "$p" ]] || continue
  if ! git worktree remove --force "$p"; then
    FAILED_WT="$p"
    break
  fi
done < <(git worktree list --porcelain | awk -v b="$TARGET" '
  /^worktree /{p=$0; sub(/^worktree /,"",p); next}
  $0=="branch refs/heads/"b{print p}
')
[[ -n "$FAILED_WT" ]] && { printf 'rollback: worktree remove %s 실패\n' "$FAILED_WT" >&2; exit 1; }

# Worktree 등록만 남은 stale entry 정리
git worktree prune

# Branch 강제 삭제
if git rev-parse --verify "$TARGET" >/dev/null 2>&1; then
  git branch -D "$TARGET"
fi

# CURRENT_TASK.md baseline reset (inline heredoc, runtime accessible)
emit_current_task_baseline > CURRENT_TASK.md

# Metadata clear + LC-14: task-state baseline reset (fr-branch/worktree-path null + short-title/status 초기화)
metadata_clear
# v2 2b: task-state baseline reset — short-title·status를 sentinel 값으로 되돌림 (LC-14)
state_write_fields "short-title=-" "status=대기 중"

# Commit (CURRENT_TASK.md + task-state 변경)
# v2 2b: LIFECYCLE_METADATA_PATH 폐지 → TASK_STATE_PATH 사용
# add 실패를 삼키면 안 된다 — 경로 한정 커밋은 워킹트리 내용을 취하므로
# "직전 add 로 index 와 워킹트리가 같다" 는 전제가 add 성공에 달려 있다.
# 두 경로 모두 필수이며 존재가 보장된다: 직전의 emit_current_task_baseline 이
# CURRENT_TASK.md 를, state_write_fields 가 task-state 를 각각 반드시 생성한다.
# archive.sh 가 같은 상황에서 이미 fail-fast 하며 그 이유를 주석에 남겼다 — 같은 패턴을 따른다.
if ! git add CURRENT_TASK.md "$TASK_STATE_PATH"; then
  printf 'promote_rollback: CURRENT_TASK.md·task-state staging 실패 — 중단\n' >&2
  exit 1
fi
if ! git diff --cached --quiet -- CURRENT_TASK.md "$TASK_STATE_PATH" 2>/dev/null; then
  # --no-verify + RD_LIFECYCLE_BYPASS_REASON 병기 (서로 다른 hook 계층), pathspec 으로 staged 오염 차단.
  # --no-verify 는 hook 이 실제로 차단하는 브랜치(main|master)에서만 붙인다 —
  # RD_LIFECYCLE_BYPASS_REASON 은 별개 계층이라 브랜치와 무관하게 항상 유지한다.
  _nv=""
  if lifecycle_needs_hook_bypass; then _nv="--no-verify"; fi
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit ${_nv:+"$_nv"} \
    -m "chore(lifecycle): rollback 완료 — $TARGET" -- CURRENT_TASK.md "$TASK_STATE_PATH"
  if [[ -n "$_nv" ]]; then lifecycle_notify_hook_bypass promote_rollback; fi
fi

printf 'rollback: 완료. removed=%s\n' "$TARGET"
exit 0
