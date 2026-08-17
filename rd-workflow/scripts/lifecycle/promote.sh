#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"

DRY_RUN=0; SHORT_TITLE=""; WORKTREE_PATH=""; NO_WORKTREE=0; STATUS_VAL="구현 중"; SOURCE_FR_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --short-title) SHORT_TITLE="$2"; shift 2 ;;
    --worktree-path) WORKTREE_PATH="$2"; shift 2 ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --status) STATUS_VAL="$2"; shift 2 ;;
    --source-fr) SOURCE_FR_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "usage: promote.sh --short-title <slug> [--worktree-path <path>] [--no-worktree] [--status <status>] [--source-fr <path|->] [--dry-run]"; exit 0 ;;
    *) echo "promote: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --source-fr 명시 인자 검증 (사용자 명시 오류는 hard error — 추론 실패와 구분)
if [[ -n "$SOURCE_FR_ARG" ]] && ! source_fr_validate "$SOURCE_FR_ARG"; then
  echo "promote: --source-fr 값 계약 위반 — '-' 또는 rd-workflow-workspace/backlog/items/<파일>.md 만 허용: $SOURCE_FR_ARG" >&2
  exit 1
fi

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

# source-fr 값 결정: 인자 > REQUEST.md 해석 > '-'
# 해석은 source_fr_resolve(_state_common.sh) 단일 구현이 담당한다 — 여기서 파싱하지 않는다.
# 값이 있는데 해석에 실패하면 return 1 로 승격을 중단시킨다. 조용히 '-' 를 기록하면
# archive 의 FR done 자동 처리가 무동작하고, 그 사실이 작업 종료 시점에야 드러난다.
resolve_source_fr() {
  if [[ -n "$SOURCE_FR_ARG" ]]; then printf '%s\n' "$SOURCE_FR_ARG"; return 0; fi
  # local 선언과 대입을 분리한다 — `local x="$(cmd)"` 는 local 의 종료 코드가
  # 대입을 덮어써 해석 실패가 전파되지 않는다.
  local raw resolved
  raw="$(source_fr_from_request)"
  if ! resolved="$(source_fr_resolve "$raw")"; then return 1; fi
  printf '%s\n' "${resolved:--}"
}

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
    # idempotent rerun 은 source-fr 를 갱신하지 않는다 — rerun 경로는 커밋을 만들지 않으므로
    # 갱신하면 uncommitted dirty task-state 가 남는다 (final diff review Finding 1).
    # 동일 값 인자는 복구 rerun 호환을 위해 no-op 허용, 다른 값은 거부 — 정정 단일 경로는 rd task set-source-fr.
    if [[ -n "$SOURCE_FR_ARG" ]]; then
      STORED_SRC="$(metadata_read_field source-fr)"
      if [[ "$SOURCE_FR_ARG" != "${STORED_SRC:--}" ]]; then
        echo "promote: idempotent rerun 에서는 source-fr 를 갱신하지 않습니다 (stored=${STORED_SRC:--}, 인자=$SOURCE_FR_ARG)." >&2
        echo "  정정하려면: bash rd-workflow/scripts/rd task set-source-fr '$SOURCE_FR_ARG' 실행 후 변경을 정규 커밋에 포함하세요." >&2
        exit 1
      fi
      echo "promote: source-fr 동일 값 재지정 (${SOURCE_FR_ARG}) — 변경 없음"
    fi
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
  # set -e 에 의존하지 않고 명시적으로 검사한다. 이 시점은 metadata_write 직전이며
  # 앞선 Step 0·A 는 읽기·검증뿐이므로, 여기서 끝내면 어떤 상태도 바뀌지 않는다.
  # 해석은 read-only 이므로 --dry-run 조기 종료보다 **앞**에 둔다. 뒤에 두면 사전 점검이
  # 성공을 알리고 실제 실행만 실패해, dry-run 이 반대 신호를 내는 도구가 된다.
  if ! SOURCE_FR_VAL="$(resolve_source_fr)"; then
    echo "promote: REQUEST.md 의 Source FR 을 해석할 수 없어 중단합니다 (상태 변경 없음)." >&2
    echo "  REQUEST.md 를 고친 뒤 같은 명령을 다시 실행하세요." >&2
    exit 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "would create branch $TARGET_BRANCH"; exit 0; fi
  metadata_write "$TARGET_BRANCH" "$SLUG" "${WORKTREE_PATH:-null}" "$SOURCE_FR_VAL"
  # 권위 status를 뷰(Step D CURRENT_TASK.md)와 동일 값으로 기록 — 권위-뷰 이원화 방지
  state_write_fields "status=$STATUS_VAL"
  # v2 2b: LIFECYCLE_METADATA_PATH 폐지 → TASK_STATE_PATH 사용 (LC-05)
  # add 실패를 삼키면 안 된다 — 경로 한정 커밋은 워킹트리 내용을 취하므로
  # "직전 add 로 index 와 워킹트리가 같다" 는 전제가 add 성공에 달려 있다
  # (promote_rollback.sh·archive.sh 와 같은 fail-fast 형태).
  if ! git add "$TASK_STATE_PATH"; then
    echo "promote: task-state staging 실패 — 중단" >&2
    exit 1
  fi
  # --no-verify: git pre-commit·commit-msg hook 우회 (main/master 차단 hook 대응).
  #   차단 대상 브랜치일 때만 붙인다 — trunk 등 커스텀 기본 브랜치는 hook 이 막지 않으므로
  #   붙이면 소비 프로젝트의 검증만 불필요하게 줄어든다
  # RD_LIFECYCLE_BYPASS_REASON: rd-workflow PreToolUse hook 용 — 별개 계층이라 둘 다 필요하다.
  #   이쪽은 브랜치와 무관하게 항상 유지한다
  # pathspec: 사용자가 미리 stage 해 둔 무관한 파일이 이 커밋에 딸려 들어가지 않게 한다
  _nv=""
  if lifecycle_needs_hook_bypass; then _nv="--no-verify"; fi
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit ${_nv:+"$_nv"} \
    -m "chore(lifecycle): promote $SLUG metadata 기록" -- "$TASK_STATE_PATH"
  if [[ -n "$_nv" ]]; then lifecycle_notify_hook_bypass promote; fi
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

# 이전 작업 잔여 초기화 — 미러의 Short Title 이 승격 대상과 다르면 baseline 으로 되돌린다.
#   같으면 건드리지 않는다: 중단 후 재개·재실행에서 그 사이 작성한 내용을 보존해야 한다.
#   baseline 값 '-' 과 빈 값은 "다름" 에 포함된다 — 이미 baseline 인 파일을 다시 baseline 으로
#   덮는 것은 결과가 같고, 분기를 늘리면 규칙만 복잡해진다.
#   대상은 $TASK_FILE 이므로 worktree 승격에서는 대상 worktree 의 미러만 초기화된다.
# 아래 awk 는 verify_field 와 같은 패턴이다(그 함수는 이 지점보다 뒤에 정의되므로 인라인).
# 쓰기는 임시 파일 → mv 교체다. `> "$TASK_FILE"` 로 직접 쓰면 실패 시 미러가 빈 채 남는다.
PREV_SLUG="$(awk '$0=="## Short Title"{flag=1; next} flag && /^[^#]/{print; exit}' "$TASK_FILE")"
if [[ "$PREV_SLUG" != "$SLUG" ]]; then
  _pt_tmp="${TASK_FILE}.baseline.tmp"
  if ! emit_current_task_baseline > "$_pt_tmp" 2>/dev/null; then
    rm -f "$_pt_tmp"
    echo "promote: CURRENT_TASK.md baseline 생성 실패 — 중단 (기존 미러 보존)" >&2; exit 1
  fi
  if ! mv "$_pt_tmp" "$TASK_FILE"; then
    rm -f "$_pt_tmp"
    echo "promote: CURRENT_TASK.md 교체 실패 — 중단 (기존 미러 보존)" >&2; exit 1
  fi
  echo "promote: 이전 작업($PREV_SLUG) 잔여를 baseline 으로 초기화"
fi

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

# 판정·커밋 모두 CURRENT_TASK.md 로 한정한다 — 한정하지 않으면 사용자가 미리 stage 해 둔
# 무관한 변경이 이 커밋에 그대로 흡수되어, 앞선 metadata 커밋의 경로 한정 보호가 같은 실행
# 안에서 무의미해진다 (change spec 결정 5-1 · REQUEST AC6 의 index 보존).
# --no-verify 는 붙이지 않는다 — 이 커밋은 fr 브랜치에서 실행되어 hook 차단 대상이 아니고,
# 붙이면 소비 프로젝트의 검증만 줄어든다 (REQUEST AC2 가 비대상으로 확정).
( cd "$TARGET_DIR" && git add CURRENT_TASK.md && \
  if ! git diff --cached --quiet -- CURRENT_TASK.md; then
    git commit -m "chore(lifecycle): $SLUG fr 브랜치 승격 — CURRENT_TASK 갱신" -- CURRENT_TASK.md
  else
    echo "promote: CURRENT_TASK.md 변경 없음 — commit skip"
  fi
)

echo "promote: 완료. fr-branch=$TARGET_BRANCH"
