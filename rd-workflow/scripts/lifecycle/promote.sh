#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"

DRY_RUN=0; SHORT_TITLE=""; WORKTREE_PATH=""; NO_WORKTREE=0; STATUS_VAL="구현 중"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --short-title) SHORT_TITLE="$2"; shift 2 ;;
    --worktree-path) WORKTREE_PATH="$2"; shift 2 ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --status) STATUS_VAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "usage: promote.sh --short-title <slug> [--worktree-path <path>] [--no-worktree] [--status <status>] [--dry-run]"; exit 0 ;;
    *) echo "promote: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# I2 — --no-worktree + --worktree-path 충돌 검출
if [[ "$NO_WORKTREE" -eq 1 && -n "$WORKTREE_PATH" ]]; then
  echo "promote: --no-worktree와 --worktree-path는 함께 사용할 수 없습니다." >&2; exit 1
fi

# Short title 자동 추출 (trim-only — 내부 공백 보존)
if [[ -z "$SHORT_TITLE" && -f CURRENT_TASK.md ]]; then
  SHORT_TITLE="$(awk '/^## Short Title/{flag=1; next} flag && /^[^#]/{sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print; exit}' CURRENT_TASK.md)"
fi
[[ -z "$SHORT_TITLE" || "$SHORT_TITLE" == "-" ]] && { echo "promote: --short-title 필수" >&2; exit 1; }
SLUG="$(normalize_slug "$SHORT_TITLE")"

# --worktree-path canonicalize (relative→absolute / parent missing hard error)
if [[ -n "$WORKTREE_PATH" ]]; then
  if [[ "$WORKTREE_PATH" != /* ]]; then
    PARENT="$(dirname "$WORKTREE_PATH")"
    [[ -d "$PARENT" ]] || { echo "promote: --worktree-path parent 미존재: $PARENT" >&2; exit 1; }
    WORKTREE_PATH="$(cd "$PARENT" && pwd)/$(basename "$WORKTREE_PATH")"
  fi
  echo "promote: canonical worktree-path=$WORKTREE_PATH"
fi

# Step 0 — metadata 확인
TARGET_BRANCH=""; STORED_WT=""
if metadata_exists; then
  EXISTING_SHORT="$(metadata_read_field short-title)"
  EXISTING_BRANCH="$(metadata_read_field fr-branch)"
  STORED_WT="$(metadata_read_field worktree-path)"
  # stale 감지 — fr-branch가 실재하는 로컬 브랜치가 아니면 진행 불가 (refs/heads 전용 판정: 동명 tag 배제)
  if ! git rev-parse --verify "refs/heads/$EXISTING_BRANCH" >/dev/null 2>&1; then
    echo "promote: task-state의 fr-branch($EXISTING_BRANCH)가 실재하지 않는 stale 상태입니다 (short-title=$EXISTING_SHORT)." >&2
    echo "  원인 후보: 브랜치 수동 삭제, 또는 이전 archive/rollback 비정상 종료." >&2
    echo "  복구: bash rd-workflow/scripts/lifecycle/promote_rollback.sh (기본 브랜치 worktree — task-state fr 필드 reset 포함) 후 promote 재시도." >&2
    exit 1
  fi
  if [[ "$EXISTING_SHORT" == "$SLUG" ]]; then
    TARGET_BRANCH="$EXISTING_BRANCH"
    echo "promote: metadata 발견 (idempotent rerun) — fr-branch=$TARGET_BRANCH, stored worktree-path=$STORED_WT"
    if [[ -n "$WORKTREE_PATH" && "$WORKTREE_PATH" != "$STORED_WT" ]]; then
      echo "promote: 기존 worktree path 와 다름 (metadata=$STORED_WT, 인자=$WORKTREE_PATH)." >&2
      echo "  metadata 갱신 후 재시도 또는 --worktree-path 인자 생략 권장." >&2; exit 1
    fi
  else
    echo "promote: 이미 진행 중인 fr ($EXISTING_BRANCH, short-title=$EXISTING_SHORT)." >&2
    echo "  archive.sh 또는 promote_rollback.sh 후 재시도." >&2; exit 1
  fi
fi

# Step A — 기본 브랜치 worktree 검증
MAIN_WT="$(get_main_worktree_path)" || { echo "promote: 기본 브랜치 worktree 검출 실패" >&2; exit 1; }
CURRENT_WT="$(git rev-parse --show-toplevel)"
if [[ "$MAIN_WT" != "$CURRENT_WT" ]]; then
  DB="$(get_default_branch)"
  echo "promote: 기본 브랜치($DB) worktree에서 호출하세요. 해당 worktree path: $MAIN_WT" >&2; exit 1
fi

# Step B — metadata 부재 시 신규 결정
if [[ -z "$TARGET_BRANCH" ]]; then
  TARGET_BRANCH="$(resolve_unique_ref branch "fr/$SLUG")"
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "would create branch $TARGET_BRANCH"; exit 0; fi
  metadata_write "$TARGET_BRANCH" "$SLUG" "${WORKTREE_PATH:-null}"
  # 권위 status를 뷰(Step D CURRENT_TASK.md)와 동일 값으로 기록 — 권위-뷰 이원화 방지
  state_write_fields "status=$STATUS_VAL"
  # v2 2b: LIFECYCLE_METADATA_PATH 폐지 → TASK_STATE_PATH 사용 (LC-05)
  git add "$TASK_STATE_PATH"
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit -m "chore(lifecycle): promote $SLUG metadata 기록"
  # 브랜치를 metadata 커밋 뒤에 생성 — fr 브랜치가 task-state 정합 커밋을 포함해 baseline 회귀 방지
  git branch "$TARGET_BRANCH"
  echo "promote: branch $TARGET_BRANCH 생성"
fi

[[ "$DRY_RUN" -eq 1 ]] && { echo "would proceed (idempotent rerun)"; exit 0; }

# Step C — TARGET_WT_PATH 결정 (metadata > 인자)
TARGET_WT_PATH=""
if [[ -n "$STORED_WT" && "$STORED_WT" != "null" ]]; then
  TARGET_WT_PATH="$STORED_WT"
elif [[ -n "$WORKTREE_PATH" ]]; then
  TARGET_WT_PATH="$WORKTREE_PATH"
fi

if [[ -n "$TARGET_WT_PATH" ]]; then
  EXISTING_WT="$(git worktree list --porcelain | awk -v b="$TARGET_BRANCH" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0=="branch refs/heads/"b{print p; exit}')"
  if [[ -n "$EXISTING_WT" ]]; then
    if [[ "$EXISTING_WT" == "$TARGET_WT_PATH" ]]; then
      echo "promote: worktree 이미 존재 ($EXISTING_WT) — skip"
    else
      echo "promote: worktree 가 다른 path 에 있음 (existing=$EXISTING_WT, target=$TARGET_WT_PATH). metadata 갱신 필요" >&2; exit 1
    fi
  elif [[ -e "$TARGET_WT_PATH" ]]; then
    echo "promote: worktree path 이미 존재 (다른 용도)" >&2; exit 1
  else
    git worktree add "$TARGET_WT_PATH" "$TARGET_BRANCH"
  fi
elif [[ "$(git rev-parse --abbrev-ref HEAD)" != "$TARGET_BRANCH" ]]; then
  git switch "$TARGET_BRANCH"
fi

# Step D — CURRENT_TASK.md 갱신 commit (fr branch 위 = TARGET_WT_PATH 또는 기본 브랜치 worktree)
TARGET_DIR="${TARGET_WT_PATH:-.}"
TASK_FILE="$TARGET_DIR/CURRENT_TASK.md"
[[ -f "$TASK_FILE" ]] || { echo "promote: $TASK_FILE 없음" >&2; exit 1; }

if [[ -n "$TARGET_WT_PATH" ]]; then BW_VAL="$TARGET_BRANCH @ $TARGET_WT_PATH"; else BW_VAL="$TARGET_BRANCH"; fi
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
awk -v bw="$BW_VAL" -v st="$STATUS_VAL" -v slug="$SLUG" '
  BEGIN { sec="" }
  /^## Branch \/ Worktree/ { print; sec="bw"; next }
  /^## Status/             { print; sec="st"; next }
  /^## Short Title/        { print; sec="slug"; next }
  /^## /                   { sec=""; print; next }
  sec=="bw" && /^[^#]/      { print bw; sec=""; next }
  sec=="st" && /^[^#]/      { print st; sec=""; next }
  sec=="slug" && /^[^#]/    { print slug; sec=""; next }
  { print }
' "$TASK_FILE" > "$TMP"
cat "$TMP" > "$TASK_FILE"

# C2 — 세 필드 갱신 검증
verify_field() {
  local file="$1" header="$2" expected="$3" desc="$4"
  local actual
  actual="$(awk -v h="$header" '
    $0==h{flag=1; next}
    flag && /^[^#]/{print; exit}
  ' "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "promote: CURRENT_TASK.md 갱신 검증 실패 — $desc (expected=[$expected] got=[$actual])" >&2
    return 1
  fi
}
verify_field "$TASK_FILE" "## Branch / Worktree" "$BW_VAL" "Branch / Worktree" || exit 1
verify_field "$TASK_FILE" "## Status" "$STATUS_VAL" "Status" || exit 1
verify_field "$TASK_FILE" "## Short Title" "$SLUG" "Short Title" || exit 1

( cd "$TARGET_DIR" && git add CURRENT_TASK.md && \
  if ! git diff --cached --quiet; then
    git commit -m "chore(lifecycle): $SLUG fr 브랜치 승격 — CURRENT_TASK 갱신"
  else
    echo "promote: CURRENT_TASK.md 변경 없음 — commit skip"
  fi
)

echo "promote: 완료. fr-branch=$TARGET_BRANCH"
