#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"

DRY_RUN=0; FORCE_DIRTY=0; NO_REMOTE=0; FR_BRANCH_OVERRIDE=""; FORCE_SKIP_REVIEW=0; SKIP_REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fr-branch) FR_BRANCH_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force-dirty) FORCE_DIRTY=1; shift ;;
    --no-remote) NO_REMOTE=1; shift ;;
    --force-skip-review-check)
      FORCE_SKIP_REVIEW=1
      # 다음 토큰이 없거나 -로 시작하면 사유 누락 → 빈 값 유지 (precheck에서 차단)
      if [[ $# -ge 2 && "$2" != -* ]]; then SKIP_REASON="$2"; shift 2; else shift 1; fi
      ;;
    -h|--help) printf '%s\n' "usage: archive.sh [--fr-branch <ref>] [--no-remote] [--force-dirty] [--force-skip-review-check <사유>] [--dry-run]"; exit 0 ;;
    *) printf 'archive: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# Step 0 — 기본 브랜치 worktree 검증
MAIN_WT="$(get_main_worktree_path)" || { printf 'archive: 기본 브랜치 worktree 검출 실패\n' >&2; exit 1; }
CURRENT_WT="$(git rev-parse --show-toplevel)" || {
  printf 'archive: git repo 외부에서 실행 불가\n' >&2; exit 1
}
if [[ "$MAIN_WT" != "$CURRENT_WT" ]]; then
  DB="$(get_default_branch)"
  printf 'archive: 기본 브랜치(%s) worktree에서만 호출 가능. 해당 worktree path: %s\n' "$DB" "$MAIN_WT" >&2; exit 1
fi

# Step 0 — clean state (unless --force-dirty)
if [[ "$FORCE_DIRTY" -eq 0 ]]; then
  ensure_worktree_clean || { printf 'archive: worktree dirty — git status 확인 후 commit/stash 후 재실행\n' >&2; exit 1; }
elif ! ensure_worktree_clean; then
  printf 'archive: WARNING — dirty state 강제 진행 (--force-dirty)\n' >&2
fi

# FR identity source-of-truth
FR_BRANCH="$FR_BRANCH_OVERRIDE"
if [[ -z "$FR_BRANCH" ]]; then
  FR_BRANCH="$(metadata_read_field fr-branch)"
fi
if [[ -z "$FR_BRANCH" ]]; then
  printf 'archive: active fr 없음. promote.sh 호출 후 archive 가능합니다.\n' >&2; exit 1
fi
[[ "$FR_BRANCH" == fr/* ]] || { printf 'archive: 잘못된 fr ref: %s\n' "$FR_BRANCH" >&2; exit 1; }

# Override mismatch guard — override 가 active metadata 와 다르면 unrelated FR 정리/metadata 손상을 막기 위해 중단.
if [[ -n "$FR_BRANCH_OVERRIDE" ]] && metadata_exists; then
  ACTIVE_FR="$(metadata_read_field fr-branch)"
  if [[ -n "$ACTIVE_FR" && "$ACTIVE_FR" != "$FR_BRANCH_OVERRIDE" ]]; then
    printf 'archive: --fr-branch %s 가 active metadata (%s) 와 불일치 — 중단합니다.\n' "$FR_BRANCH_OVERRIDE" "$ACTIVE_FR" >&2
    printf '  active FR 을 archive 하려면: 인자 없이 archive.sh 호출\n' >&2
    printf '  active FR 을 다른 ref 로 전환하려면: promote_rollback.sh 후 promote.sh 재호출\n' >&2
    exit 1
  fi
fi

SLUG="${FR_BRANCH#fr/}"
REMOTE_MODE="$(detect_remote_mode)"
[[ "$NO_REMOTE" -eq 1 ]] && REMOTE_MODE="local-only"

# remote tag preflight (hard-stop on fetch failure)
if [[ "$REMOTE_MODE" == "remote" ]]; then
  git fetch --tags origin >/dev/null 2>&1 || {
    printf 'archive: git fetch --tags origin 실패 — preflight 중단. 네트워크/권한 확인 후 재실행 또는 --no-remote 사용.\n' >&2
    exit 1
  }
fi

# Rerun 안전망 — fr branch 부재 + 동일 slug tag 존재 = 이미 archive 완료
if ! git rev-parse --verify "$FR_BRANCH" >/dev/null 2>&1; then
  EXISTING_TAG="$(git tag --list "fr/*/$SLUG" 2>/dev/null | head -1)"
  if [[ -n "$EXISTING_TAG" ]]; then
    printf 'archive: 이미 archive 완료 — nothing to do (tag=%s)\n' "$EXISTING_TAG"
    exit 0
  fi
  printf 'archive: branch %s 미존재\n' "$FR_BRANCH" >&2; exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'would archive: branch=%s (tag는 cleanup commit 부착 후 결정)\n' "$FR_BRANCH"; exit 0
fi

# review 종결성 자체 검증 (dry-run exit 이후 = 실제 archive 경로에만 실행, dry-run 비파괴성 보존).
# 판정/audit/사유검증은 헬퍼에 위임.
project_root="$CURRENT_WT"
source "$SCRIPT_DIR/../hooks/_guard_common.sh"
AUDIT_LOG="$CURRENT_WT/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
archive_review_precheck "$FORCE_SKIP_REVIEW" "$SKIP_REASON" "$SLUG" "$AUDIT_LOG" "$FR_BRANCH" || exit 1

# Step 2 — archive content 휴리스틱 (warning만)
LAST_COMMIT_FILES="$(git log -1 "$FR_BRANCH" --name-only --pretty=format: 2>/dev/null || true)"
if ! grep -qE '(^|/)(REQUEST\.md|CURRENT_TASK\.md|FUTURE_REQUESTS\.md|request-archive/.*\.md)' <<<"$LAST_COMMIT_FILES"; then
  printf 'archive: WARNING — fr branch 마지막 commit 에 archive content 미감지\n' >&2
fi

# Step 3 — merge (idempotent)
if git merge-base --is-ancestor "$FR_BRANCH" HEAD 2>/dev/null; then
  printf 'archive: %s 이미 merge 됨 — skip\n' "$FR_BRANCH"
else
  git merge --no-ff "$FR_BRANCH" -m "merge: $SLUG (autopilot 완료)" || {
    printf 'archive: merge 실패 — conflict resolve 후 재실행\n' >&2; exit 1
  }
fi

# Step 4 — metadata cleanup commit on main (publish 전)
if metadata_exists; then
  metadata_clear
  # LC-14 대칭: archive 완료 시 short-title/status baseline reset (stale 방지 — promote_rollback.sh와 동일 패턴)
  state_write_fields "short-title=-" "status=대기 중"
  # v2 2b: LIFECYCLE_METADATA_PATH 폐지 → TASK_STATE_PATH 사용
  git add "$TASK_STATE_PATH" 2>/dev/null || true
  # legacy active-fr 잔재가 tracked 파일로 존재하면 삭제분도 staged (metadata_clear가 rm -f 처리)
  _legacy_afr_path="$CURRENT_WT/rd-workflow-workspace/.lifecycle/active-fr"
  if git ls-files --error-unmatch "$_legacy_afr_path" >/dev/null 2>&1; then
    git add "$_legacy_afr_path" 2>/dev/null || true
  fi
  if ! git diff --cached --quiet 2>/dev/null; then
    RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit -m "chore(lifecycle): archive $SLUG metadata 정리"
    printf 'archive: metadata cleanup commit 완료\n'
  fi
fi

# Step 5 — Tag (HEAD = cleanup commit, rerun reuse)
TARGET_TAG="$(git tag --list "fr/*/$SLUG" --points-at HEAD 2>/dev/null | head -1)"
if [[ -z "$TARGET_TAG" ]]; then
  TS="$(date +%Y-%m-%d-%H%M)"
  TARGET_TAG="$(resolve_unique_ref tag "fr/$TS/$SLUG")" || {
    printf 'archive: tag ref 생성 실패 (%s, TS=%s)\n' "$SLUG" "$TS" >&2; exit 1
  }
fi

if git rev-parse --verify "refs/tags/$TARGET_TAG" >/dev/null 2>&1; then
  EXISTING="$(git rev-parse "refs/tags/$TARGET_TAG^{commit}")"
  HEAD_REV="$(git rev-parse HEAD)"
  [[ "$EXISTING" == "$HEAD_REV" ]] || {
    printf 'archive: tag %s 충돌 (다른 commit) — 수동 해결 후 재실행: git tag -d %s\n' "$TARGET_TAG" "$TARGET_TAG" >&2
    exit 1
  }
  printf 'archive: tag %s 이미 존재 (HEAD 가리킴) — skip\n' "$TARGET_TAG"
else
  git tag "$TARGET_TAG" -m "archive: $SLUG @ $(date +"%Y-%m-%d %H:%M")"
  printf 'archive: tag %s 부착 (cleanup commit 가리킴)\n' "$TARGET_TAG"
fi

# Step 6 — Remote publish (blocking)
if [[ "$REMOTE_MODE" == "remote" ]]; then
  DEFAULT_BRANCH="$(get_default_branch)" || { printf 'archive: 기본 브랜치 결정 실패 — push 중단\n' >&2; exit 1; }
  git push origin "$DEFAULT_BRANCH" || { printf 'archive: %s push 실패 — 재실행으로 복구\n' "$DEFAULT_BRANCH" >&2; exit 1; }
  git push origin "$TARGET_TAG" || { printf 'archive: tag push 실패 — 재실행으로 복구\n' >&2; exit 1; }
fi

# Step 7 — Worktree teardown (destructive, publish 후, whitespace-safe)
FAILED_WT=""
while IFS= read -r fr_wt; do
  [[ -z "$fr_wt" ]] && continue
  [[ -d "$fr_wt" ]] || continue
  if ! git worktree remove "$fr_wt"; then
    FAILED_WT="$fr_wt"
    break
  fi
done < <(git worktree list --porcelain | awk -v b="$FR_BRANCH" '
  /^worktree /{p=$0; sub(/^worktree /,"",p); next}
  $0=="branch refs/heads/"b{print p}
')
[[ -n "$FAILED_WT" ]] && { printf 'archive: worktree remove %s 실패\n' "$FAILED_WT" >&2; exit 1; }

# Step 8 — Local branch 삭제
git rev-parse --verify "$FR_BRANCH" >/dev/null 2>&1 && git branch -d "$FR_BRANCH"

# Step 9 — Remote branch delete (non-blocking warning)
if [[ "$REMOTE_MODE" == "remote" ]]; then
  git push origin --delete "$FR_BRANCH" 2>&1 | sed 's/^/archive: remote-branch-delete: /' || \
    printf 'archive: WARNING remote branch delete 실패 (non-blocking)\n' >&2
fi

printf 'archive: 완료. tag=%s\n' "$TARGET_TAG"
