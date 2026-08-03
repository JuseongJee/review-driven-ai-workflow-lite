#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"

PASS=0; FAIL=0
assert_eq() {
  local got="$1" want="$2" desc="$3"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "  PASS: $desc";
  else FAIL=$((FAIL+1)); echo "  FAIL: $desc — got=[$got] want=[$want]" >&2; fi
}
assert_err() {
  local input="$1" desc="$2"
  if normalize_slug "$input" >/dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "  FAIL: $desc — expected error but got success" >&2
  else PASS=$((PASS+1)); echo "  PASS: $desc"; fi
}

echo "== slug normalization =="
assert_eq "$(normalize_slug 'Foo Bar')" "foo-bar" "공백 + 대문자"
assert_eq "$(normalize_slug 'foo  bar')" "foo-bar" "다중 공백 압축"
assert_eq "$(normalize_slug 'foo_bar')" "foo-bar" "underscore 치환"
assert_eq "$(normalize_slug 'foo.bar')" "foo-bar" "dot 치환"
assert_eq "$(normalize_slug '--foo--')" "foo" "양끝 trim"
assert_eq "$(normalize_slug 'foo--bar')" "foo-bar" "연속 dash 압축"
assert_err "한글" "비-ASCII 거부"
assert_err "foo!bar" "특수문자 거부"
assert_err "" "빈 문자열 거부"
assert_err "   " "공백만 거부"
assert_err "$(printf 'x%.0s' {1..61})" "61자 거부"


# === Task 2: _lifecycle_common.sh fixtures ===
source "$SCRIPT_DIR/_lifecycle_common.sh"

echo "== git state helpers =="
assert_in_set() {
  local got="$1" set="$2" desc="$3"
  if [[ ",$set," == *",$got,"* ]]; then PASS=$((PASS+1)); echo "  PASS: $desc";
  else FAIL=$((FAIL+1)); echo "  FAIL: $desc — got=[$got]" >&2; fi
}

assert_in_set "$(detect_remote_mode)" "remote,local-only" "detect_remote_mode 반환값"
ensure_worktree_clean >/dev/null 2>&1 && rc=0 || rc=$?
assert_in_set "$rc" "0,1" "ensure_worktree_clean exit code"

echo "== metadata I/O =="
TMPDIR_TEST="$(mktemp -d)"
trap "rm -rf '$TMPDIR_TEST'" EXIT
# v2 2b: task-state 경로로 격리 (LIFECYCLE_METADATA_PATH 폐지 — TASK_STATE_PATH 사용)
TASK_STATE_PATH="$TMPDIR_TEST/task-state"
if metadata_exists; then FAIL=$((FAIL+1)); echo "  FAIL: empty metadata 인데 exists 반환" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: metadata 부재 (fr-branch=null 또는 파일 없음)"; fi
metadata_write "fr/foo" "foo" "/path"
if metadata_exists; then PASS=$((PASS+1)); echo "  PASS: write 후 exists (fr-branch=fr/foo)"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: metadata write 실패 — fr-branch 값 없음" >&2; fi
assert_eq "$(metadata_read_field fr-branch)" "fr/foo" "metadata_read fr-branch"
assert_eq "$(metadata_read_field short-title)" "foo" "metadata_read short-title"
assert_eq "$(metadata_read_field worktree-path)" "/path" "metadata_read worktree-path"
# created-at 존재 확인 (write 후 생성)
if grep -q "^created-at=" "$TASK_STATE_PATH" 2>/dev/null; then PASS=$((PASS+1)); echo "  PASS: write 후 created-at 존재"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: created-at 누락" >&2; fi
metadata_clear
# clear 후: fr-branch=null, worktree-path=null, created-at 제거
assert_eq "$(metadata_read_field fr-branch)" "null" "metadata_clear 후 fr-branch=null"
assert_eq "$(metadata_read_field worktree-path)" "null" "metadata_clear 후 worktree-path=null"

echo "== source-fr metadata (promote-source-fr-sync) =="
SRC_T3="rd-workflow-workspace/backlog/items/2026-01-01-baz.md"
metadata_write "fr/bar" "bar" "/path"
assert_eq "$(metadata_read_field source-fr)" "-" "3인자 metadata_write → source-fr=- 기본 (하위 호환)"
metadata_write "fr/baz" "baz" "/path" "$SRC_T3"
assert_eq "$(metadata_read_field source-fr)" "$SRC_T3" "4인자 metadata_write → source-fr 기록"
metadata_clear
assert_eq "$(metadata_read_field source-fr)" "-" "metadata_clear → source-fr=-"

echo "== promote.sh source-fr 결정 (fixture repo) =="
# mk_promote_fixture <dir> <request-source-fr-라인>  ("__NONE__" 이면 Source FR 섹션 없음)
mk_promote_fixture() {
  local dir="$1" src_line="$2"
  mkdir -p "$dir"
  ( cd "$dir" \
    && { git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }; } \
    && git config user.email "t@t" && git config user.name "t" \
    && mkdir -p rd-workflow-workspace/backlog/items \
    && printf '%s\n' "# Current Task" "" "## Short Title" "-" "" "## Status" "대기 중" "" "## Branch / Worktree" "-" > CURRENT_TASK.md \
    && if [[ "$src_line" == "__NONE__" ]]; then
         printf '%s\n' "# Change Request" "" "## Task Type" "change" > REQUEST.md
       else
         printf '%s\n' "# Change Request" "" "## Source FR" "$src_line" > REQUEST.md
       fi \
    && touch "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" \
    && git add -A && git commit -qm init )
}
read_fix_source_fr() { # read_fix_source_fr <dir>
  awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,"");print;exit}' "$1/rd-workflow-workspace/.lifecycle/task-state"
}

FIX1="$TMPDIR_TEST/fix-infer"
mk_promote_fixture "$FIX1" '`rd-workflow-workspace/backlog/items/2026-01-01-fix.md`'
( cd "$FIX1" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-infer --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX1")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: REQUEST 백틱 path 추론 기록"

FIX2="$TMPDIR_TEST/fix-none"
mk_promote_fixture "$FIX2" "-"
( cd "$FIX2" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-none --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX2")" "-" "promote: REQUEST '-' → source-fr=-"

FIX3="$TMPDIR_TEST/fix-arg"
mk_promote_fixture "$FIX3" "-"
( cd "$FIX3" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-arg --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX3")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: --source-fr 명시 인자 기록"

FIX4="$TMPDIR_TEST/fix-slug"
mk_promote_fixture "$FIX4" "2026-01-01-fix"
( cd "$FIX4" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-slug --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX4")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: legacy slug 추론 → path 정규화 (실존)"

FIX5="$TMPDIR_TEST/fix-badslug"
mk_promote_fixture "$FIX5" "no-such-item"
( cd "$FIX5" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-badslug --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX5")" "-" "promote: 무효 추론값 → 경고 후 '-'"

FIX6="$TMPDIR_TEST/fix-badarg"
mk_promote_fixture "$FIX6" "-"
rc6=0
( cd "$FIX6" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-badarg --no-worktree \
    --source-fr "/abs/evil.md" >/dev/null 2>&1 ) || rc6=$?
assert_eq "$rc6" "1" "promote: --source-fr 무효값 hard error exit 1"

# dry-run 무변경 계약: idempotent rerun + --dry-run --source-fr 에서도 상태 불변
FIX7="$TMPDIR_TEST/fix-dryrun"
mk_promote_fixture "$FIX7" '`rd-workflow-workspace/backlog/items/2026-01-01-fix.md`'
( cd "$FIX7" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-dryrun --no-worktree >/dev/null 2>&1 )
( cd "$FIX7" && git checkout -q main 2>/dev/null || true )
( cd "$FIX7" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-dryrun --no-worktree --dry-run \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-other.md" >/dev/null 2>&1 || true )
assert_eq "$(read_fix_source_fr "$FIX7")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: --dry-run 은 source-fr 를 변경하지 않음 (idempotent rerun)"

# non-dry idempotent rerun: 동일 값 인자 = no-op 허용 (exit 0), dirty task-state 없음
# Step A(기본 브랜치 worktree 검증) 전제 충족을 위해 첫 promote 후 main 으로 checkout (FIX7과 동일 패턴)
FIX8="$TMPDIR_TEST/fix-rerun-same"
mk_promote_fixture "$FIX8" "-"
( cd "$FIX8" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-same --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
( cd "$FIX8" && git checkout -q main 2>/dev/null || true )
rc8=0
( cd "$FIX8" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-same --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 ) || rc8=$?
assert_eq "$rc8" "0" "promote rerun: 동일 --source-fr no-op 허용 (exit 0)"
assert_eq "$(read_fix_source_fr "$FIX8")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote rerun: 동일 값 유지"
assert_eq "$(cd "$FIX8" && git status --porcelain | grep -c "task-state" || true)" "0" "promote rerun: task-state dirty 없음 (동일 값)"

# non-dry idempotent rerun: 다른 값 인자 = exit 1 거부 + 값 불변 + dirty 없음 (정정은 set-source-fr 일원화)
FIX9="$TMPDIR_TEST/fix-rerun-diff"
mk_promote_fixture "$FIX9" "-"
( cd "$FIX9" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-diff --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
( cd "$FIX9" && git checkout -q main 2>/dev/null || true )
rc9=0
( cd "$FIX9" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-diff --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-02-02-other.md" >/dev/null 2>&1 ) || rc9=$?
assert_eq "$rc9" "1" "promote rerun: 다른 --source-fr 거부 (exit 1)"
assert_eq "$(read_fix_source_fr "$FIX9")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote rerun: 거부 후 값 불변"
assert_eq "$(cd "$FIX9" && git status --porcelain | grep -c "task-state" || true)" "0" "promote rerun: task-state dirty 없음 (거부)"

if grep -q "^created-at=" "$TASK_STATE_PATH" 2>/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: clear 후 created-at 잔존" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: clear 후 created-at 제거"; fi
if metadata_exists; then FAIL=$((FAIL+1)); echo "  FAIL: clear 후에도 metadata_exists true" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: metadata_exists false (fr-branch=null)"; fi

# --- legacy active-fr fallback (수정 2: metadata_read_field legacy fallback) ---
echo "== legacy active-fr fallback =="
LEGACY_AFR_DIR="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle"
mkdir -p "$LEGACY_AFR_DIR"
printf 'fr-branch=fr/legacy-test\nshort-title=legacy-task\nworktree-path=/tmp/legacy\n' > "$LEGACY_AFR_DIR/active-fr"
# task-state 없는 상태 + project_root 격리
(
  set +e
  export project_root="$TMPDIR_TEST/legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle/task-state"
  rm -f "$TASK_STATE_PATH"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  got="$(metadata_read_field fr-branch)"
  if [[ "$got" == "fr/legacy-test" ]]; then
    echo "  PASS: task-state 부재 + active-fr → fr-branch=fr/legacy-test"
    exit 0
  else
    echo "  FAIL: task-state 부재 legacy fallback — got=[$got] want=[fr/legacy-test]" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# task-state 존재 시 legacy active-fr 무시 확인
(
  set +e
  export project_root="$TMPDIR_TEST/legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle/task-state2"
  mkdir -p "$(dirname "$TASK_STATE_PATH")"
  printf 'schema=1\nfr-branch=fr/real-state\nshort-title=real\nstatus=구현 중\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
  # active-fr도 존재 (무시 대상)
  printf 'fr-branch=fr/legacy-test\nshort-title=legacy-task\n' > "$LEGACY_AFR_DIR/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  got="$(metadata_read_field fr-branch)"
  if [[ "$got" == "fr/real-state" ]]; then
    echo "  PASS: task-state 존재 시 active-fr 무시 → fr-branch=fr/real-state"
    exit 0
  else
    echo "  FAIL: task-state 존재 시 legacy 값이 노출됨 — got=[$got] want=[fr/real-state]" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# metadata_clear — legacy active-fr 삭제 확인 (수정 3)
(
  set +e
  export project_root="$TMPDIR_TEST/legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle/task-state3"
  mkdir -p "$(dirname "$TASK_STATE_PATH")"
  printf 'schema=1\nfr-branch=fr/to-clear\nshort-title=clr\nstatus=구현 중\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
  printf 'fr-branch=fr/to-clear\nshort-title=clr\n' > "$LEGACY_AFR_DIR/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  metadata_clear
  if [[ ! -f "$LEGACY_AFR_DIR/active-fr" ]]; then
    echo "  PASS: metadata_clear → legacy active-fr 삭제됨"
    exit 0
  else
    echo "  FAIL: metadata_clear 후 active-fr 잔존" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# metadata_exists — legacy fallback 회귀 테스트
# metadata_exists가 metadata_read_field 경유로 legacy fallback을 공유하는지 검증
echo "== metadata_exists legacy fallback =="
# Case 1: task-state 부재 + active-fr(fr-branch=fr/x) → metadata_exists return 0 (참)
(
  set +e
  export project_root="$TMPDIR_TEST/exists-legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/exists-legacy-root/rd-workflow-workspace/.lifecycle/task-state"
  local_afr="$TMPDIR_TEST/exists-legacy-root/rd-workflow-workspace/.lifecycle"
  mkdir -p "$local_afr"
  rm -f "$TASK_STATE_PATH"
  printf 'fr-branch=fr/x\nshort-title=legacy-x\n' > "$local_afr/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  if metadata_exists; then
    echo "  PASS: task-state 부재 + active-fr(fr/x) → metadata_exists true"
    exit 0
  else
    echo "  FAIL: task-state 부재 + active-fr(fr/x) → metadata_exists false (legacy fallback 미적용)" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# Case 2: task-state 존재(fr-branch=null) + active-fr 잔존(fr-branch=fr/x) → metadata_exists return 1 (task-state 우선)
(
  set +e
  export project_root="$TMPDIR_TEST/exists-ts-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/exists-ts-root/rd-workflow-workspace/.lifecycle/task-state"
  local_afr="$TMPDIR_TEST/exists-ts-root/rd-workflow-workspace/.lifecycle"
  mkdir -p "$local_afr"
  printf 'schema=1\nfr-branch=null\nshort-title=cleared\nstatus=대기 중\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
  printf 'fr-branch=fr/x\nshort-title=legacy-x\n' > "$local_afr/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  if metadata_exists; then
    echo "  FAIL: task-state(fr-branch=null) + active-fr → metadata_exists true (legacy 값이 우선됨)" >&2
    exit 1
  else
    echo "  PASS: task-state(fr-branch=null) + active-fr → metadata_exists false (task-state 우선)"
    exit 0
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# Case 3: task-state 부재 + active-fr 부재 → metadata_exists return 1
(
  set +e
  export project_root="$TMPDIR_TEST/exists-empty-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/exists-empty-root/rd-workflow-workspace/.lifecycle/task-state"
  mkdir -p "$(dirname "$TASK_STATE_PATH")"
  rm -f "$TASK_STATE_PATH" "$TMPDIR_TEST/exists-empty-root/rd-workflow-workspace/.lifecycle/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  if metadata_exists; then
    echo "  FAIL: task-state 부재 + active-fr 부재 → metadata_exists true" >&2
    exit 1
  else
    echo "  PASS: task-state 부재 + active-fr 부재 → metadata_exists false"
    exit 0
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo "== Task 2 누적: PASS=$PASS FAIL=$FAIL =="

echo "== review-gate 헬퍼 (safeguard-review-completion-checks) =="
LITE_HOOKS_DIR="$SCRIPT_DIR/../hooks"
GUARD_ROOT="$(mktemp -d)"
mkdir -p "$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline"
mkdir -p "$GUARD_ROOT/rd-workflow-workspace/.lifecycle"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"

# mk_session <dirname> <status> <open_issues_line> <short_title>
mk_session() {
  local d="$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline/$1"
  mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}

project_root="$GUARD_ROOT"
# v2 2b: task-state 격리 — metadata I/O 테스트의 잔여 상태가 오염되지 않도록 TASK_STATE_PATH 재설정
TASK_STATE_PATH="$GUARD_ROOT/rd-workflow-workspace/.lifecycle/task-state"
# task-state 초기값: 대기 중 (get_current_short_title이 task-state에서 short-title을 읽음)
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
source "$LITE_HOOKS_DIR/_guard_common.sh"

assert_eq "$(get_current_short_title)" "mytask" "get_current_short_title — CURRENT_TASK"

# fr-scope: mytask 세션만 반환, 다른 fr 세션 제외
mk_session "20260101_000000_final-diff-review" "closed" "- 없음" "otherfr"
mk_session "20260102_000000_final-diff-review" "closed" "- 없음" "mytask"
assert_eq "$(basename "$(get_latest_diff_review_dir)")" "20260102_000000_final-diff-review" "fr-scope — mytask 세션만"

RP="$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline"
# (a) closed + 없음 → 종결(0)
mk_session "20260103_000000_final-diff-review" "closed" "- 없음" "mytask"
is_review_session_resolved "$RP/20260103_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + 없음"
# (b) awaiting-user + 없음 → 종결(0)  ※ 운영상 정상 종료 패턴(75%)
mk_session "20260104_000000_final-diff-review" "awaiting-user" "- 없음" "mytask"
is_review_session_resolved "$RP/20260104_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — awaiting-user + 없음 (정상 종료)"
# (c) awaiting-reviewer (루프 진행 중) → 미종결(1)
mk_session "20260105_000000_final-diff-review" "awaiting-reviewer" "- 없음" "mytask"
is_review_session_resolved "$RP/20260105_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — awaiting-reviewer (루프 진행 중)"
# (d) awaiting-user + 실제 이슈 → 미종결(1)
mk_session "20260106_000000_final-diff-review" "awaiting-user" "- 미해결 쟁점" "mytask"
is_review_session_resolved "$RP/20260106_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — awaiting-user + 실제 이슈"
# (e) closed (후행 공백) → trim 후 종결(0)
mk_session "20260107_000000_final-diff-review" "closed " "- 없음" "mytask"
is_review_session_resolved "$RP/20260107_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — 'closed ' trim"
# (f) malformed: CHECKPOINT.md 없음 → fail-closed(1)
mkdir -p "$RP/20260108_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: mytask\n' > "$RP/20260108_000000_final-diff-review/SESSION.md"
is_review_session_resolved "$RP/20260108_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — CHECKPOINT.md 부재"
# (g) malformed: Open Issues 섹션 없음 → fail-closed(1)
mkdir -p "$RP/20260109_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: mytask\n' > "$RP/20260109_000000_final-diff-review/SESSION.md"
printf '# Review Checkpoint\n\n## Current Summary\n-\n' > "$RP/20260109_000000_final-diff-review/CHECKPOINT.md"
is_review_session_resolved "$RP/20260109_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — Open Issues 섹션 부재"

# (h)~(q) canonical 마커 계약 (precheck-open-issues-marker) — 별도 short-title(markertask)로
# 격리해 아래 get_latest_diff_review_dir(mytask 최신=20260109) assert에 간섭하지 않는다.
# (h) closed + None (영어 canonical 마커) → 종결(0)
mk_session "20260301_000000_final-diff-review" "closed" "- None" "markertask"
is_review_session_resolved "$RP/20260301_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + None (영어 마커)"
# (i) closed + None. (후행 마침표 — 실제 관측된 거짓 양성 사례) → 종결(0)
mk_session "20260302_000000_final-diff-review" "closed" "- None." "markertask"
is_review_session_resolved "$RP/20260302_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + None. (후행 마침표)"
# (j) closed + 없음. (한국어 + 후행 마침표) → 종결(0)
mk_session "20260303_000000_final-diff-review" "closed" "- 없음." "markertask"
is_review_session_resolved "$RP/20260303_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + 없음. (후행 마침표)"
# (k) closed + 비마커 산문 → 미종결(1) (fail-closed)
mk_session "20260304_000000_final-diff-review" "closed" "- no issues" "markertask"
is_review_session_resolved "$RP/20260304_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 비마커 산문 (no issues)"
# (l) closed + 마커 뒤 후행 텍스트 → 미종결(1) (라인 전체 매칭, fail-closed 강화)
mk_session "20260305_000000_final-diff-review" "closed" "- 없음 (단, 후속 확인 필요)" "markertask"
is_review_session_resolved "$RP/20260305_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 마커 뒤 후행 텍스트"
# (m) closed + 빈 섹션 (내용 라인 없음) → 미종결(1) (마커 존재 요구)
mk_session "20260306_000000_final-diff-review" "closed" "" "markertask"
is_review_session_resolved "$RP/20260306_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 빈 Open Issues 섹션 (마커 부재)"
# (n) closed + HTML 주석만 → 미종결(1) (주석은 무시, 마커 부재)
mk_session "20260307_000000_final-diff-review" "closed" "<!-- 규약 주석 -->" "markertask"
is_review_session_resolved "$RP/20260307_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 주석만 있는 섹션 (마커 부재)"
# (o) closed + 비-bullet 산문 (dash 없는 None) → 미종결(1)
mk_session "20260308_000000_final-diff-review" "closed" "None" "markertask"
is_review_session_resolved "$RP/20260308_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 비-bullet 산문 (None)"
# (p) closed + 마커와 실제 이슈 혼재 → 미종결(1)
mk_session "20260309_000000_final-diff-review" "closed" "$(printf -- '- 없음\n- 실제 이슈')" "markertask"
is_review_session_resolved "$RP/20260309_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 마커와 실제 이슈 혼재"
# (q) closed + 규약 주석 + 마커 (신규 템플릿 정상 종결 형태) → 종결(0)
mk_session "20260310_000000_final-diff-review" "closed" "$(printf -- '<!-- 규약 주석 -->\n- 없음')" "markertask"
is_review_session_resolved "$RP/20260310_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — 규약 주석 + 마커 (신규 템플릿 형태)"

# fr 세션 부재 시 빈 값 (다른 fr만 존재)
printf '# Current Task\n\n## Short Title\nlonelytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
# v2 2b: task-state도 함께 업데이트 (get_current_short_title이 task-state에서 읽음)
printf 'schema=1\nshort-title=lonelytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
assert_eq "$(get_latest_diff_review_dir)" "" "fr-scope — 현재 fr 세션 없으면 빈 값"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"

# malformed 세션은 short-title 미상 → fr-scope 후보 제외 (legacy/unscoped 통과, 3d 오발화 방지)
mkdir -p "$RP/20260110_000000_final-diff-review"
mkdir -p "$RP/20260111_000000_final-diff-review"
printf '## Status\nclosed\n' > "$RP/20260111_000000_final-diff-review/SESSION.md"
assert_eq "$(basename "$(get_latest_diff_review_dir)")" "20260109_000000_final-diff-review" "malformed 제외 — short-title 매칭 세션만 반환"
printf '# Current Task\n\n## Short Title\nzzz\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=zzz\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
assert_eq "$(get_latest_diff_review_dir)" "" "malformed-only → 빈 값 (unscoped 통과, 오발화 방지)"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"

# archive_review_precheck (3c)
PRECHECK_AUDIT="$GUARD_ROOT/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
rm -f "$PRECHECK_AUDIT"
printf '# Current Task\n\n## Short Title\nlonelytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=lonelytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
archive_review_precheck "0" "" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — 미종결 + force-skip 아님 → 차단"
archive_review_precheck "1" "" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — force-skip + 사유 누락 → 차단"
archive_review_precheck "1" "긴급 핫픽스" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — force-skip + 사유 → 통과"
assert_eq "$(awk -F' \\| ' 'END{print $2}' "$PRECHECK_AUDIT")" "lonelytask" "precheck — audit slug 기록"
assert_eq "$(awk -F' \\| ' 'END{print $3}' "$PRECHECK_AUDIT")" "긴급 핫픽스" "precheck — audit 사유 기록"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
mk_session "20260120_000000_final-diff-review" "closed" "- 없음" "mytask"   # 최신 종결 mytask 세션
archive_review_precheck "0" "" "mytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — 종결 세션 존재 → 통과"

# === archive precheck fr-branch tip 가시성 (archive-precheck-premerge-session-visibility) ===
echo "== archive precheck fr-branch tip 가시성 =="
FT_REPO="$(mktemp -d)"
git -C "$FT_REPO" init -q -b main
git -C "$FT_REPO" config user.email t@t && git -C "$FT_REPO" config user.name t
mkdir -p "$FT_REPO/rd-workflow-workspace/handoffs/review_pipeline" "$FT_REPO/rd-workflow-workspace/.lifecycle"
# 실제 archive 시점 재현: main 의 CURRENT_TASK ## Short Title 은 baseline(-),
# short-title 은 task-state metadata fallback 으로 해소된다(get_current_short_title).
printf '# Current Task\n\n## Short Title\n-\n' > "$FT_REPO/CURRENT_TASK.md"
# v2 2b: active-fr → task-state 전환 (schema=1, fr-branch=fr/fttask)
printf 'schema=1\nshort-title=fttask\nstatus=구현 중\nfr-branch=fr/fttask\nworktree-path=null\nsource-fr=-\ncreated-at=2026-07-05-0000\n' > "$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m seed
# fr branch 에 종결 diff-review 세션 commit
git -C "$FT_REPO" branch fr/fttask
git -C "$FT_REPO" switch -q fr/fttask
FTS="$FT_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260301_000000_final-diff-review"
mkdir -p "$FTS"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/fttask\n- short-title: fttask\n' > "$FTS/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$FTS/CHECKPOINT.md"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "diff-review session on fr"
git -C "$FT_REPO" switch -q main
FT_AUDIT="$FT_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
# sanity 1: short-title 은 task-state fallback 으로 해소 (CURRENT_TASK Short Title=-)
# v2 2b: TASK_STATE_PATH를 명시적으로 FT_REPO 기반으로 설정 (서브셸에서 재설정 필요)
assert_eq "$( ( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; get_current_short_title ) )" "fttask" "fr-tip — metadata fallback 으로 short-title 해소(Short Title=-)"
# sanity 2: 세션은 fr branch tip 에만 있고 main 워킹트리엔 없음
assert_eq "$( ( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; get_latest_diff_review_dir ) )" "" "fr-tip — main 워킹트리에 세션 없음(sanity)"
# Case A (핵심 회귀): main Short Title=- + metadata fallback + fr_ref 지정 → fr tip 종결 세션 인식 → 통과(0)
( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; archive_review_precheck "0" "" "fttask" "$FT_AUDIT" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "fr-tip — 종결 세션을 fr branch tip 에서 검증 → 통과 (metadata fallback 결합)"
# Case B (안전 회귀): fr tip 세션을 미종결로 변경 → 차단(1)
git -C "$FT_REPO" switch -q fr/fttask
printf '## Status\nawaiting-reviewer\n\n## Branch Context\n- fr-branch: fr/fttask\n- short-title: fttask\n' > "$FTS/SESSION.md"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "session unterminated"
git -C "$FT_REPO" switch -q main
( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; archive_review_precheck "0" "" "fttask" "$FT_AUDIT" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "fr-tip — 미종결(awaiting-reviewer) 세션 → 차단 (안전 속성 보존)"
# Case C (audit 정규화): 미종결 fr 세션(위 Case B 상태) + force-skip + 사유 → 통과(0)
#   + audit 의 세션참조 필드가 temp 절대경로가 아닌 repo-상대 경로여야 한다.
FT_AUDIT2="$FT_REPO/rd-workflow-workspace/.lifecycle/audit2.log"
( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; archive_review_precheck "1" "긴급 사유" "fttask" "$FT_AUDIT2" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "fr-tip — force-skip + 사유 → 통과"
assert_eq "$(awk -F' \\| ' 'END{print $4}' "$FT_AUDIT2")" "rd-workflow-workspace/handoffs/review_pipeline/20260301_000000_final-diff-review" "fr-tip — audit 세션참조 repo-상대 경로(temp 절대경로 금지)"
rm -rf "$FT_REPO"

# === Case D~G (archive-precheck-fr-ref-short-title-fallback): fr-branch identity 매칭 ===
# active metadata 없이 archive.sh --fr-branch 호출 시, fr tip SESSION.md 의 Branch Context
# fr-branch == fr_ref 로 후보를 고정해 종결 세션을 인식한다(main 워킹트리 의존 제거).
echo "== archive precheck fr_ref — fr-branch identity 매칭 =="
FT2="$(mktemp -d)"
git -C "$FT2" init -q -b main
git -C "$FT2" config user.email t@t && git -C "$FT2" config user.name t
mkdir -p "$FT2/rd-workflow-workspace/handoffs/review_pipeline" "$FT2/rd-workflow-workspace/.lifecycle"
# main: baseline Short Title=- + task-state 부재 → get_current_short_title "-" 반환(fr-scope 미해소)
# v2 2b: active-fr 폐지 → task-state도 없는 상태로 테스트 (legacy fallback: CURRENT_TASK.md Short Title=-)
printf '# Current Task\n\n## Short Title\n-\n' > "$FT2/CURRENT_TASK.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m seed
FT2_AUDIT="$FT2/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
# task-state 없음 → legacy CURRENT_TASK.md Short Title=- 반환 (TASK_STATE_PATH 격리)
assert_eq "$( ( project_root="$FT2"; TASK_STATE_PATH="$FT2/rd-workflow-workspace/.lifecycle/task-state"; get_current_short_title ) )" "-" "metadata 부재 — short-title 빈 값(회귀 전제)"

# Case D (AC1 — metadata 부재 핵심 회귀): fr/d1 tip 종결 세션(fr-branch=fr/d1) → 통과(0)
git -C "$FT2" branch fr/d1
git -C "$FT2" switch -q fr/d1
D1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260401_000000_final-diff-review"
mkdir -p "$D1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/d1\n- short-title: d1\n' > "$D1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$D1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "diff-review on fr/d1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "d1" "$FT2_AUDIT" "fr/d1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "AC1 — metadata 부재 + fr tip 종결 세션 → 통과 (fr-branch identity)"

# Case E (AC2 — suffix slug): fr/e1-2 tip, 세션 fr-branch=fr/e1-2, slug 인자=e1-2 → 통과(0)
git -C "$FT2" branch fr/e1-2
git -C "$FT2" switch -q fr/e1-2
E1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260402_000000_final-diff-review"
mkdir -p "$E1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/e1-2\n- short-title: e1\n' > "$E1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$E1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "diff-review on fr/e1-2"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "e1-2" "$FT2_AUDIT" "fr/e1-2" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "AC2 — suffix branch fr/e1-2 (fr-branch identity) → 통과 (slug≠short-title)"

# Case F (fail-closed — legacy): fr/f1 tip 세션에 Branch Context 부재 → 매칭 실패 → 차단(1)
git -C "$FT2" branch fr/f1
git -C "$FT2" switch -q fr/f1
F1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260403_000000_final-diff-review"
mkdir -p "$F1S"
printf '## Status\nclosed\n' > "$F1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$F1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "legacy diff-review on fr/f1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "f1" "$FT2_AUDIT" "fr/f1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — fr tip 세션 Branch Context 부재 → 차단"

# Case G (AC8 — stale/unrelated false-positive 차단): fr/g1 tip 최신 세션이 fr-branch=fr/other(종결)
#   이고 fr/g1 매칭 세션 없음 → 차단(1). short-title 역산 설계였다면 통과했을 false-positive 를 차단.
git -C "$FT2" branch fr/g1
git -C "$FT2" switch -q fr/g1
G1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260404_000000_final-diff-review"
mkdir -p "$G1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/other\n- short-title: other\n' > "$G1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$G1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "unrelated closed session on fr/g1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "g1" "$FT2_AUDIT" "fr/g1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "AC8 — stale/unrelated(fr/other) closed 세션만 최신 → 차단 (false-positive 방지)"
rm -rf "$FT2"

# commit_has_archive_signal (review-gate-iteration-commit)
echo "== commit_has_archive_signal =="
SIG_REPO="$(mktemp -d)"
git -C "$SIG_REPO" init -q
git -C "$SIG_REPO" config user.email t@t && git -C "$SIG_REPO" config user.name t
mkdir -p "$SIG_REPO/rd-workflow-workspace/backlog/request-archive" "$SIG_REPO/rd-workflow-workspace/.lifecycle"
printf '# Current Task\n\n## Status\n구현 중\n\n## Short Title\nsigtask\n' > "$SIG_REPO/CURRENT_TASK.md"
# v2 2b: task-state 격리 — TASK_STATE_PATH를 SIG_REPO 기반으로 재설정
TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"
# task-state 초기값: 구현 중, short-title=sigtask (비-baseline)
printf 'schema=1\nshort-title=sigtask\nstatus=구현 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
ARCH="rd-workflow-workspace/backlog/request-archive/2026-05-24-0000-sigtask.md"
# 신호 없음: 비-baseline + staged archive 없음 → 1(허용)
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — 신호 없음 → 1(허용)"
# AS1 경계: untracked stale archive 파일(add 안 함) → 1(허용, false-positive 방지)
printf 'x\n' > "$SIG_REPO/$ARCH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — AS1 untracked stale archive → 1(허용)"
# AS1: staged 추가 → 0(차단)
git -C "$SIG_REPO" add "$ARCH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "0" "archive_signal — AS1 staged request-archive 추가 → 0(차단)"
# AS1 경계: 기존 archive 파일 삭제(staged D) → 1(허용, 추가 아님)
git -C "$SIG_REPO" commit -q -m seed
git -C "$SIG_REPO" rm -q "$ARCH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — request-archive 삭제(staged D) → 1(허용)"
# AS2: task-state baseline(status=대기 중, short-title=-) → 0(차단)
# v2 2b: task-state가 권위 소스 — CURRENT_TASK.md 변경과 함께 task-state도 베이스라인으로 설정
printf '# Current Task\n\n## Status\n대기 중\n\n## Short Title\n-\n' > "$SIG_REPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "0" "archive_signal — AS2 task-state baseline → 0(차단)"
rm -rf "$SIG_REPO"

echo "== review_gate hook exit code (iteration-commit 허용) =="
HOOK_REPO="$(mktemp -d)"
mkdir -p "$HOOK_REPO/rd-workflow/scripts/hooks"
mkdir -p "$HOOK_REPO/rd-workflow/scripts"
mkdir -p "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline"
mkdir -p "$HOOK_REPO/rd-workflow-workspace/backlog/request-archive"
mkdir -p "$HOOK_REPO/rd-workflow-workspace/.lifecycle"
cp "$LITE_HOOKS_DIR/_guard_common.sh" "$HOOK_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/pre_commit_review_gate.sh" "$HOOK_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/../_state_common.sh" "$HOOK_REPO/rd-workflow/scripts/"
git -C "$HOOK_REPO" init -q
git -C "$HOOK_REPO" config user.email t@t && git -C "$HOOK_REPO" config user.name t
printf '# Current Task\n\n## Status\ndiff review 대기\n\n## Short Title\nhooktask\n' > "$HOOK_REPO/CURRENT_TASK.md"
hook_mk_session() {
  local d="$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/$1"
  mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}
run_review_gate() {
  printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
    | bash "$HOOK_REPO/rd-workflow/scripts/hooks/pre_commit_review_gate.sh" >/dev/null 2>&1; echo $?
}
HARCH="rd-workflow-workspace/backlog/request-archive/2026-05-24-0000-hooktask.md"
# 세션 없음 → 통과
assert_eq "$(run_review_gate)" "0" "review_gate — 세션 없음 → 통과 (exit 0)"
# 종결(awaiting-user+없음) → 통과
hook_mk_session "20260201_000000_final-diff-review" "awaiting-user" "- 없음" "hooktask"
assert_eq "$(run_review_gate)" "0" "review_gate — awaiting-user+없음(종결) → 통과"
# A1: 미종결 + iteration(staged archive 없음) → 허용 (신 동작)
hook_mk_session "20260202_000000_final-diff-review" "awaiting-reviewer" "- 없음" "hooktask"
assert_eq "$(run_review_gate)" "0" "review_gate — A1 미종결 + iteration commit → 허용 (exit 0)"
# A1-edge: 미종결 + untracked stale archive(add 안 함) → 허용 (false-positive 방지)
printf 'x\n' > "$HOOK_REPO/$HARCH"
assert_eq "$(run_review_gate)" "0" "review_gate — A1 미종결 + untracked stale archive → 허용"
# B1-AS1: 미종결 + staged request-archive 추가 → 차단
git -C "$HOOK_REPO" add "$HARCH"
assert_eq "$(run_review_gate)" "2" "review_gate — B1(AS1) 미종결 + staged archive 추가 → 차단 (exit 2)"
git -C "$HOOK_REPO" reset -q; rm -f "$HOOK_REPO/$HARCH"
# B1-AS2: 미종결 + task-state baseline(status=대기 중, short-title=-) → 차단 (v2: task-state 우선)
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' \
  > "$HOOK_REPO/rd-workflow-workspace/.lifecycle/task-state"
printf '# Current Task\n\n## Status\n대기 중\n\n## Short Title\n-\n' > "$HOOK_REPO/CURRENT_TASK.md"
assert_eq "$(run_review_gate)" "2" "review_gate — B1(AS2) 미종결 + task-state baseline → 차단 (exit 2)"
printf '# Current Task\n\n## Status\ndiff review 대기\n\n## Short Title\nhooktask\n' > "$HOOK_REPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=hooktask\nstatus=diff review 대기\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' \
  > "$HOOK_REPO/rd-workflow-workspace/.lifecycle/task-state"
# autopilot 활성 + 미종결 + iteration → 허용 (3a 우회 제거 후에도 iteration 은 신호 아님)
touch "$HOOK_REPO/.autopilot_active"
assert_eq "$(run_review_gate)" "0" "review_gate — autopilot + 미종결 + iteration → 허용"
rm -f "$HOOK_REPO/.autopilot_active"
# malformed(Open Issues 섹션 부재) = 미종결 + iteration → 허용 (archive 신호일 때만 fail-closed)
mkdir -p "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260203_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: hooktask\n' > "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260203_000000_final-diff-review/SESSION.md"
printf '# Review Checkpoint\n\n## Current Summary\n-\n' > "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260203_000000_final-diff-review/CHECKPOINT.md"
assert_eq "$(run_review_gate)" "0" "review_gate — malformed + iteration → 허용"
# malformed + staged archive 추가 → 차단 (archive 경로 fail-closed 유지)
printf 'x\n' > "$HOOK_REPO/$HARCH"
git -C "$HOOK_REPO" add "$HARCH"
assert_eq "$(run_review_gate)" "2" "review_gate — malformed + staged archive → 차단 (fail-closed)"
git -C "$HOOK_REPO" reset -q
rm -rf "$HOOK_REPO"

echo "== archive_gate hook exit code =="
AG_REPO="$(mktemp -d)"
mkdir -p "$AG_REPO/rd-workflow/scripts/hooks" "$AG_REPO/rd-workflow/scripts" "$AG_REPO/rd-workflow-workspace/handoffs/review_pipeline" "$AG_REPO/rd-workflow-workspace/backlog/items"
cp "$LITE_HOOKS_DIR/_guard_common.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/pre_commit_archive_gate.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/../_state_common.sh" "$AG_REPO/rd-workflow/scripts/"
printf '# Current Task\n\n## Short Title\nagtask\n' > "$AG_REPO/CURRENT_TASK.md"
printf '# Change Request\n\n## Source FR\n2026-05-15-agtask\n' > "$AG_REPO/REQUEST.md"
printf '# agtask\n- status: idea\n' > "$AG_REPO/rd-workflow-workspace/backlog/items/2026-05-15-agtask.md"
ag_mk_session() {
  local d="$AG_REPO/rd-workflow-workspace/handoffs/review_pipeline/$1"; mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}
run_ag() {
  printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
    | bash "$AG_REPO/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh" >/dev/null 2>&1; echo $?
}
ag_mk_session "20260301_000000_final-diff-review" "closed" "- 없음" "agtask"
touch "$AG_REPO/.autopilot_active"
assert_eq "$(run_ag)" "2" "archive_gate — autopilot active + 종결 + FR not done → 차단"
rm -f "$AG_REPO/.autopilot_active"
printf '# agtask\n- status: done\n' > "$AG_REPO/rd-workflow-workspace/backlog/items/2026-05-15-agtask.md"
assert_eq "$(run_ag)" "0" "archive_gate — FR done → 통과"
rm -rf "$AG_REPO"

echo "== archive.sh dry-run 비파괴성 (precheck 배치) =="
# review precheck(audit write 가능)는 dry-run exit 뒤에 있어야 dry-run --force-skip-review-check 가 audit log를 오염시키지 않는다.
ARCHIVE_SH="$SCRIPT_DIR/archive.sh"
dry_ln="$(grep -n 'DRY_RUN.*-eq 1' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
pc_ln="$(grep -n 'archive_review_precheck "' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$dry_ln" && -n "$pc_ln" && "$pc_ln" -gt "$dry_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: archive_review_precheck($pc_ln) 가 dry-run exit($dry_ln) 뒤 — dry-run 비파괴"
else
  FAIL=$((FAIL+1)); echo "  FAIL: precheck($pc_ln) 가 dry-run($dry_ln) 앞 — dry-run audit 오염 위험" >&2
fi
# fr_ref 배선 회귀 (archive-precheck-premerge-session-visibility): precheck 호출이 $FR_BRANCH 를 5번째 인자로 전달하는지
pc_wire="$(grep -E 'archive_review_precheck "' "$ARCHIVE_SH" | head -1)"
if printf '%s' "$pc_wire" | grep -q '"\$AUDIT_LOG" "\$FR_BRANCH"'; then
  PASS=$((PASS+1)); echo "  PASS: archive.sh precheck 호출이 \$FR_BRANCH 를 5번째 인자로 전달"
else
  FAIL=$((FAIL+1)); echo "  FAIL: archive.sh precheck 호출에 \$FR_BRANCH(5번째 인자) 누락 — [$pc_wire]" >&2
fi

rm -rf "$GUARD_ROOT"

# === safeguard-self-review-block: self-review 게이트 ===
source "$SCRIPT_DIR/../review_common.sh"

echo "== resolve_self_review_policy =="
assert_eq "$(resolve_self_review_policy block "")" "block" "policy=block 그대로"
assert_eq "$(resolve_self_review_policy warn "")"  "warn"  "policy=warn 그대로"
assert_eq "$(resolve_self_review_policy off "")"   "off"   "policy=off 그대로"
assert_eq "$(resolve_self_review_policy "" false)" "off"   "미설정(빈값)+warning=false → off"
assert_eq "$(resolve_self_review_policy "" true)"  "block" "미설정(빈값)+warning=true → block"
assert_eq "$(resolve_self_review_policy "" "")"    "block" "미설정(빈값)+warning 미설정 → block"
assert_eq "$(resolve_self_review_policy bogus "")" "block" "미인식 policy + warning 빈값 → block (fail-safe)"
assert_eq "$(resolve_self_review_policy bogus false)" "block" "미인식 policy + warning=false → block (finding1 회귀방지)"

echo "== evaluate_self_review_gate =="
assert_eq "$(evaluate_self_review_gate off "" "")"   "proceed-silent"    "off → silent"
assert_eq "$(evaluate_self_review_gate warn "" "")"  "proceed-warn"      "warn → warn"
assert_eq "$(evaluate_self_review_gate block 1 "")"  "proceed-autopilot" "block+autopilot → autopilot"
assert_eq "$(evaluate_self_review_gate block "" 1)"  "proceed-warn"      "block+approve → warn"
assert_eq "$(evaluate_self_review_gate block "" "")" "block"             "block+일반 → block"
assert_eq "$(evaluate_self_review_gate block 1 1)"   "proceed-autopilot" "block+autopilot이 approve보다 우선"

echo "== record_self_review_block =="
SR_UA="$(mktemp)"
# 기본 USER_ACTION 템플릿(차단 안내가 지워져야 하는 문구 포함)
printf '# User Action\n\n## Current Recommendation\n-\n\n## Why\n- \n\n## Question For User\n아직 사용자 확인이 필요한 단계가 아닙니다.\n' > "$SR_UA"
record_self_review_block "$SR_UA"
if grep -q "RD_SELF_REVIEW_APPROVE=1" "$SR_UA"; then PASS=$((PASS+1)); echo "  PASS: 승인 재실행 안내 포함"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: 승인 안내 누락" >&2; fi
if grep -q "아직 사용자 확인이 필요한 단계가 아닙니다" "$SR_UA"; then \
  FAIL=$((FAIL+1)); echo "  FAIL: 기본 no-action 문구가 남아 모순(finding3)" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: no-action 문구 제거됨"; fi
sr_snap1="$(cat "$SR_UA")"
record_self_review_block "$SR_UA"
sr_snap2="$(cat "$SR_UA")"
assert_eq "$sr_snap1" "$sr_snap2" "멱등 — 재호출 시 내용 동일"
rm -f "$SR_UA"

echo "== run_review_turn.sh self-review 차단 (script-level 통합) =="
SR_INT="$(mktemp -d)"
mkdir -p "$SR_INT/bin" "$SR_INT/session/turns"
# fake claude: 게이트가 block이면 호출되지 않아야 함 (호출되면 흔적 파일 생성)
cat > "$SR_INT/bin/claude" <<FAKE
#!/bin/sh
touch "$SR_INT/CLAUDE_WAS_CALLED"
exit 99
FAKE
chmod +x "$SR_INT/bin/claude"
# 임시 config: claude만 우선, policy=block
cat > "$SR_INT/review-tools.json" <<'CFG'
{ "default_priority": ["claude"], "tools": { "claude": { "self_review_policy": "block" } } }
CFG
# 최소 세션 fixture (Branch Context 생략 → validate_branch_context가 legacy로 skip)
cat > "$SR_INT/session/SESSION.md" <<'SES'
# Review Session
## Status
awaiting-reviewer
## Current Owner
Reviewer
## Review Type
spec-plan-review
## Review Target
target
## Review Goal
goal
## Turn Limit
20 total turns in `turns/*.md`
SES
printf '# Checkpoint\n## Current Summary\n-\n' > "$SR_INT/session/CHECKPOINT.md"
printf '# User Action\n\n## Current Recommendation\n-\n\n## Why\n- \n\n## Question For User\n아직 사용자 확인이 필요한 단계가 아닙니다.\n' > "$SR_INT/session/USER_ACTION.md"
printf '# Turn 001 Author\n' > "$SR_INT/session/turns/001_author.md"
# 일반 모드 실행 (RD_AUTOPILOT / RD_SELF_REVIEW_APPROVE 미설정)
sr_rc=0
PATH="$SR_INT/bin:$PATH" REVIEW_TOOLS_CONFIG="$SR_INT/review-tools.json" \
  RD_AUTOPILOT="" RD_SELF_REVIEW_APPROVE="" \
  bash "$SCRIPT_DIR/../run_review_turn.sh" "$SR_INT/session" >/dev/null 2>&1 || sr_rc=$?
assert_eq "$sr_rc" "3" "차단 exit code 3"
if [ ! -f "$SR_INT/session/turns/002_reviewer.md" ]; then PASS=$((PASS+1)); echo "  PASS: reviewer turn 미생성"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: reviewer turn 생성됨" >&2; fi
if grep -q "RD_SELF_REVIEW_APPROVE=1" "$SR_INT/session/USER_ACTION.md"; then PASS=$((PASS+1)); echo "  PASS: USER_ACTION 차단 안내 기록"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: USER_ACTION 차단 안내 누락" >&2; fi
assert_eq "$(awk '/^## Status/{getline; gsub(/[ \t]/,"",$0); print; exit}' "$SR_INT/session/SESSION.md")" "awaiting-reviewer" "SESSION Status awaiting-reviewer 유지"
if [ ! -f "$SR_INT/CLAUDE_WAS_CALLED" ]; then PASS=$((PASS+1)); echo "  PASS: fake claude 미호출(게이트가 adapter 전 차단)"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: claude adapter 실행됨" >&2; fi
rm -rf "$SR_INT"

# === get_default_branch resolver (lifecycle-default-branch-generalize) ===
echo "== get_default_branch resolver =="
GDB_TMP="$(mktemp -d)"
make_gdb_repo() {  # <dir> <initial-branch>
  local d="$1" b="$2"
  mkdir -p "$d"
  ( cd "$d" && { git init -q -b "$b" 2>/dev/null || { git init -q; git checkout -q -b "$b"; }; } \
    && git config user.email t@example.com && git config user.name t \
    && git commit -q --allow-empty -m init )
}
gdb_in() { ( cd "$1" && unset project_root && get_default_branch 2>/dev/null ); }

# case 1: config 최우선 (브랜치 실존 여부와 무관하게 config 값 채택)
R="$GDB_TMP/c1"; make_gdb_repo "$R" main
mkdir -p "$R/rd-workflow/config"
printf '{\n  "default_branch": "trunk"\n}\n' > "$R/rd-workflow/config/workflow.json"
assert_eq "$(gdb_in "$R")" "trunk" "config default_branch 최우선"

# case 2: 빈 config 값("")은 미설정 — 다음 체인 진행 (master 유일 매치)
R="$GDB_TMP/c2"; make_gdb_repo "$R" master
mkdir -p "$R/rd-workflow/config"
printf '{\n  "default_branch": ""\n}\n' > "$R/rd-workflow/config/workflow.json"
assert_eq "$(gdb_in "$R")" "master" "빈 config 값 → 자동 검출 fallthrough"

# case 3: origin/HEAD 검출
R="$GDB_TMP/c3"; make_gdb_repo "$R" main
( cd "$R" && git update-ref refs/remotes/origin/devel HEAD \
  && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/devel )
assert_eq "$(gdb_in "$R")" "devel" "origin/HEAD 검출"

# case 4: 로컬 유일 매치 (master만 존재)
R="$GDB_TMP/c4"; make_gdb_repo "$R" master
assert_eq "$(gdb_in "$R")" "master" "main/master 유일 매치"

# case 5: 모호 (main+master 동시 존재) → 에러
R="$GDB_TMP/c5"; make_gdb_repo "$R" main
( cd "$R" && git branch master )
if gdb_in "$R" >/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: 모호 케이스에서 성공 반환" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: main/master 동시 존재 시 에러"; fi

# case 6: 후보 전무 → 에러
R="$GDB_TMP/c6"; make_gdb_repo "$R" work
if gdb_in "$R" >/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: 후보 전무에서 성공 반환" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: 후보 전무 시 에러"; fi

# get_main_worktree_path 일반화: master 유일 repo에서 해당 worktree path 반환
R="$GDB_TMP/c7"; make_gdb_repo "$R" master
assert_eq "$( cd "$R" && get_main_worktree_path )" "$( cd "$R" && pwd -P )" "get_main_worktree_path master 일반화"

rm -rf "$GDB_TMP"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
