#!/usr/bin/env bash
# 이 스위트가 **FAIL 한 줄 없이 rc 1 로 조용히 죽는** 사건이 관측됐는데(1/5 회), 사후에
# 지점을 특정할 방법이 없어 원인 확정이 불가능했습니다. 아래 두 trap 은 다음 재발을
# "판정 불능" 이 아니라 "즉시 인지 + 가능하면 지점 확정" 으로 바꿉니다.
# 기대값을 맞추려고 이 trap 들을 약화시키지 마십시오 — 약화시키는 순간 같은 사건이
# 다시 익명이 됩니다.
#
# **`-E` 는 의도적으로 켜지 않습니다** (실측 근거). `-E` 를 켜면 trap 이 함수·서브셸·명령
# 치환까지 물려받는데, bash 는 errexit 의 "판정 문맥 유예" 를 그 안쪽으로 물려주지
# 않습니다. 그래서 `x="$(cmd)" || true` · `( f ) && rc=0 || rc=1` 처럼 **이미 처리된
# 실패**에서 trap 이 전부 울립니다 (실측: 무관한 지점 9곳 + `stderr 무출력` 단언 1건 파괴).
# 그 실패들은 판정 문맥 안이라 애초에 스위트를 죽이지 못하므로 진단 대상이 아닙니다.
#
# **ERR trap 하나로는 부족합니다** (전수 매트릭스 실측 — task-8b-review §4). 조용한 죽음은
# 세 형태이고 `-E` 없는 ERR trap 은 그중 하나만 잡습니다.
#   - 최상위 단순 명령       → ERR **잡음** (줄번호까지)
#   - 최상위에서 부른 함수 안 → ERR **놓침**
#   - 최상위 서브셸 `( … )` 안 → ERR **놓침**
# 이 스위트는 `ast_reset_marks` 같은 자기 헬퍼 함수와 `( … )` 를 전반에서 쓰므로 놓치는
# 범위가 예외가 아닙니다. 그래서 **EXIT 센티넬**을 함께 겁니다 — 결과줄을 찍고 `DONE=1`
# 을 세우기 전에 셸이 끝나면 무조건 FAIL 을 냅니다. 세 형태를 모두 덮고, 판정 문맥은
# bash 가 부모의 EXIT trap 을 `( … )`·명령 치환 안에서 실행하지 않으므로 오탐이 없습니다.
# 둘의 조합이 "항상 알려 주고, 가능하면 지점까지 짚는" 형태입니다.
set -euo pipefail
trap 'ec=$?; echo "  FAIL: 스위트가 line ${LINENO} 에서 rc=${ec} 로 중단됐습니다 (조용한 중단)" >&2' ERR
# **EXIT trap 은 하나뿐입니다 — 두 번째를 걸면 첫 번째가 조용히 사라집니다.** 그래서
# 임시 디렉터리 정리도 이 핸들러가 함께 합니다 (실측: 센티넬만 따로 걸었더니 아래
# `TMPDIR_TEST` 정리 trap 이 그것을 덮어써 세 형태 모두 검출되지 않았습니다).
# 서브셸 `( … )` 안의 `trap … EXIT` 는 그 서브셸에만 걸리므로 여기와 충돌하지 않습니다.
# 최상위에 EXIT trap 을 새로 걸지 마십시오 — 정리 대상은 `_ast_cleanup` 에 append 하고,
# 그 규칙이 지켜졌는지는 스위트 끝의 `trap -p EXIT` 단언이 실행 시점에 확인합니다.
#
# `local _ec=$?` 를 **첫 줄**에서 붙잡습니다. `[[ … ]] || echo "…$?"` 로 쓰면 `$?` 가
# `[[ ]]` 의 rc(=1)로 전개돼 실제 중단 rc(127·2 …)를 감춥니다 — 메시지가 사실과 다른
# 말을 하게 되고, 이 스위트가 반복해서 고쳐 온 결함이 바로 그것입니다.
DONE=0
_ast_cleanup=()
_suite_on_exit() {
  local _ec=$? _d
  for _d in ${_ast_cleanup[@]+"${_ast_cleanup[@]}"}; do [[ -z "$_d" ]] || rm -rf "$_d"; done
  [[ "$DONE" == 1 ]] || echo "  FAIL: 스위트가 결과줄 없이 rc=${_ec} 로 중단됐습니다 (조용한 중단 — 마지막 PASS 줄 다음을 보십시오)" >&2
}
trap _suite_on_exit EXIT
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
_ast_cleanup+=("$TMPDIR_TEST")   # 최상위 EXIT trap 은 `_suite_on_exit` 하나뿐입니다 (상단 주석)
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
rc5=0
( cd "$FIX5" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-badslug --no-worktree >/dev/null 2>&1 ) || rc5=$?
assert_eq "$rc5" "1" "promote: 해석 실패(no-such-item) → hard error exit 1"
if [[ -f "$FIX5/rd-workflow-workspace/.lifecycle/task-state" ]]; then
  FAIL=$((FAIL+1)); echo "  FAIL: promote: 해석 실패인데 task-state 생성됨" >&2
else PASS=$((PASS+1)); echo "  PASS: promote: 해석 실패 시 task-state 미생성 (상태 무변경)"; fi
if ( cd "$FIX5" && git rev-parse --verify fr/fix-badslug >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: promote: 해석 실패인데 fr 브랜치 생성됨" >&2
else PASS=$((PASS+1)); echo "  PASS: promote: 해석 실패 시 fr 브랜치 미생성"; fi

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

# === 미러 초기화: 이전 작업 잔여 제거 (AC4) ===
FIX10="$TMPDIR_TEST/fix-mirror-reset"
mk_promote_fixture "$FIX10" "-"
# 직전 작업 잔여를 재현한다 — baseline 에 없는 서술이 Task·Next Step 에 들어 있는 상태
printf '%s\n' \
  "# Current Task" "" \
  "## Task" "이전 작업 설명 — 남아 있으면 안 된다" "" \
  "## Short Title" "old-task" "" \
  "## Status" "완료" "" \
  "## Spec" "specs/changes/old-spec.md" "" \
  "## Branch / Worktree" "-" "" \
  "## Next Step" "이전 작업의 다음 단계 — 남아 있으면 안 된다" "" \
  "## Notes" "이전 작업 메모" > "$FIX10/CURRENT_TASK.md"
( cd "$FIX10" && git add -A && git commit -qm "stale mirror" )
( cd "$FIX10" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-reset --no-worktree >/dev/null 2>&1 )
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "-" "promote 초기화: Task 가 baseline 으로 리셋"
assert_eq "$(awk '$0=="## Next Step"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "-" "promote 초기화: Next Step 이 baseline 으로 리셋"
assert_eq "$(awk '$0=="## Spec"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "-" "promote 초기화: Spec 이 baseline 으로 리셋"
assert_eq "$(awk '$0=="## Short Title"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "fix-mirror-reset" "promote 초기화: Short Title 은 승격 값"
assert_eq "$(awk '$0=="## Status"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "구현 중" "promote 초기화: Status 는 승격 값"
assert_eq "$(cd "$FIX10" && ls CURRENT_TASK.md.baseline.* 2>/dev/null | wc -l | tr -d ' ')" "0" "promote 초기화: 임시 파일 정리됨"

# === 미러 보존: 같은 slug 재실행 (AC5) ===
FIX11="$TMPDIR_TEST/fix-mirror-keep"
mk_promote_fixture "$FIX11" "-"
( cd "$FIX11" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-keep --no-worktree >/dev/null 2>&1 )
# 승격 후 사용자가 작업 설명을 적었다고 가정한다
( cd "$FIX11" && awk '$0=="## Task"{print; getline; print "작업 중 적어 둔 설명"; next} {print}' CURRENT_TASK.md > .ct.tmp && mv .ct.tmp CURRENT_TASK.md )
( cd "$FIX11" && git add -A && git commit -qm "author note" )
( cd "$FIX11" && git checkout -q main 2>/dev/null || true )
( cd "$FIX11" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-keep --no-worktree >/dev/null 2>&1 )
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX11/CURRENT_TASK.md")" "작업 중 적어 둔 설명" "promote 보존: 같은 slug 재실행 시 작성 내용 유지"

# === worktree 승격: 대상 worktree 만 초기화 (AC4 경로 변형) ===
# TASK_FILE 은 ${TARGET_WT_PATH:-.}/CURRENT_TASK.md 이므로 기본 worktree 의 미러는 불변이어야 한다.
FIX12="$TMPDIR_TEST/fix-mirror-wt"
mk_promote_fixture "$FIX12" "-"
printf '%s\n' \
  "# Current Task" "" \
  "## Task" "기본 worktree 내용 — 유지되어야 한다" "" \
  "## Short Title" "old-wt-task" "" \
  "## Status" "완료" "" \
  "## Branch / Worktree" "-" > "$FIX12/CURRENT_TASK.md"
( cd "$FIX12" && git add -A && git commit -qm "base mirror" )
FIX12_WT="$TMPDIR_TEST/fix-mirror-wt-tree"
( cd "$FIX12" && bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-wt --worktree-path "$FIX12_WT" >/dev/null 2>&1 )
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX12_WT/CURRENT_TASK.md")" "-" "promote worktree: 대상 worktree 미러가 초기화됨"
assert_eq "$(awk '$0=="## Short Title"{getline; print; exit}' "$FIX12_WT/CURRENT_TASK.md")" "fix-mirror-wt" "promote worktree: 대상 worktree Short Title 이 승격 값"
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX12/CURRENT_TASK.md")" "기본 worktree 내용 — 유지되어야 한다" "promote worktree: 기본 worktree 미러는 불변"

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
# 순서 불변식 (미러 확정 → metadata 정리): 실패 주입 테스트가 어려운 대신 배선으로 고정한다.
#   외부 도구 없이 "baseline 생성 실패" 를 fixture 에서 재현하려면 워킹트리를 쓰기 불가로
#   만들어야 하는데, 그러면 Step 4 이전의 merge 부터 실패해 이 경로에 도달하지 못한다.
#   따라서 순서 자체를 소스에서 검증한다 — 이 순서가 뒤집히면 미러 실패가 복구 불가가 된다.
_ord_mirror="$(grep -n '_ct_tmp' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
_ord_clear="$(grep -n '^  metadata_clear$' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$_ord_mirror" && -n "$_ord_clear" && "$_ord_mirror" -lt "$_ord_clear" ]]; then
  PASS=$((PASS+1)); echo "  PASS: archive.sh 미러 확정이 metadata_clear 보다 앞선다 (순서 불변식)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: archive.sh 순서 불변식 위반 — mirror=$_ord_mirror clear=$_ord_clear" >&2
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

# === 아카이브 전 전수 검증 강제 (self-test-runtime-reduction Task 8) =====================
#
# 이 게이트는 축소 실행(smoke)이 미변경 스크립트의 구문 오류를 놓치게 된 대가를 통합 직전에
# 상환하는 **유일한 무우회 지점**입니다. 그래서 아래 단언은 차단 방향뿐 아니라
# **오탐 방향**(정당한 아카이브가 막히지 않는가)도 함께 고정합니다 — 과잉 차단은 사용자가
# 게이트 자체를 들어내게 만들어 결국 같은 손실로 돌아옵니다.
echo "== archive 전수 검증 게이트 =="
AST_GUARD_SH="$SCRIPT_DIR/../hooks/_guard_common.sh"
AST_ARCHIVE_SH="$SCRIPT_DIR/archive.sh"
AST_SMOKE_SH="$SCRIPT_DIR/../_smoke_common.sh"
# 판정 함수는 게이트가 소비하는 것과 **같은 파일**에서 가져옵니다. 테스트가 자체 판정을
# 따로 짜면 두 판정이 갈리는 순간 이 회귀가 거짓 안심을 줍니다.
# shellcheck source=/dev/null
. "$AST_SMOKE_SH"

# 마커 디렉터리는 fixture **밖**에 둡니다 — 안에 두면 그 자체가 untracked 가 되어
# 증명 기록 조건을 깨고, 관측 장치가 관측 대상을 바꿔 버립니다.
AST_MK="$(mktemp -d)"
export AST_MK
ast_reset_marks() { rm -f "$AST_MK/invoked" "$AST_MK/env"; }

# fixture 준비 명령은 감싸서 씁니다. `smoke_proof_fingerprint` 는 `mktemp`·`git` 실패에서
# `return 1` 하는데(부하에 민감합니다), 최상위에서 맨몸으로 두면 `set -e` 가 스위트를
# **FAIL 한 줄 없이** 죽입니다 — 위 ERR trap 이 지점은 짚어 주지만, 죽는 대신 그 단언만
# 실패하게 두는 편이 나머지 단언을 살립니다.
ast_fp() {  # $1 = 기록할 캐시 경로
  if ! smoke_proof_fingerprint "$AST_FX" worktree > "$1"; then
    FAIL=$((FAIL+1)); echo "  FAIL: fixture 증명 지문 생성 실패 — 이후 단언의 전제가 깨졌습니다" >&2
  fi
}
ast_mv() {  # $1 = 원본, $2 = 대상
  if ! mv "$1" "$2"; then
    FAIL=$((FAIL+1)); echo "  FAIL: fixture 파일 이동 실패 ($1 → $2) — 해당 케이스를 만들지 못했습니다" >&2
  fi
}

# 격리 fixture: 최소 인프라 트리 + 전수 검증 대역(stub).
# 실제 검증은 분 단위로 걸려 회귀로 쓸 수 없습니다. 대역을 두면
# "정말 실행되는가 / 어떤 인자·환경으로 떨어지는가 / 그 rc 가 판정에 반영되는가" 를
# 초 단위로 관측할 수 있고, 그것이 이 Task 에서 고정해야 할 성질 전부입니다.
ast_make_fx() {  # stdout: fixture root
  local d; d="$(mktemp -d)"
  mkdir -p "$d/rd-workflow/scripts" "$d/rd-workflow-workspace/.lifecycle"
  cp "$AST_SMOKE_SH" "$d/rd-workflow/scripts/_smoke_common.sh"
  printf 'echo a\n' > "$d/rd-workflow/scripts/a_zzfx.sh"
  # tracked 이면서 **증명 집합 밖**(transient)인 파일입니다. "워킹트리 = HEAD" 확인이
  # 증명 범위와 같은 pathspec 을 쓰는지 오탐 방향으로 고정하는 데 씁니다 — 범위를
  # 넓게 잡으면 감사 로그 한 줄에 정당한 아카이브가 막힙니다.
  printf 'v1\n' > "$d/rd-workflow-workspace/.lifecycle/verify-cache"
  cat > "$d/rd-workflow/scripts/self_test.sh" <<'ASTSTUB'
#!/usr/bin/env bash
# 격리 fixture 전용 대역입니다 (실제 전수 검증 아님).
# AST_STUB_RC 로 실패를, AST_STUB_NORECORD 로 "실행은 했는데 증명을 남기지 않는" 형태를,
# AST_STUB_RECORD_THEN_FAIL 로 "증명은 남기면서 rc 는 실패" 형태를 재현합니다.
# 마지막 변형이 있어야 "전수 검증 rc 가 판정에 반영되는가" 를 재대조와 분리해 고정할 수
# 있습니다 (rc 를 무시해도 증명이 없으면 재대조가 대신 막아 단언이 공허해집니다).
# 정상 경로는 실제 기록 함수를 그대로 호출해 기록 조건까지 같게 둡니다.
set -uo pipefail
_r="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
printf 'mode=%s\n' "${1-}" >> "$AST_MK/invoked"
# 전수 검증의 범위·검출력을 낮추거나 실행을 건너뛰게 하는 변수를 **전부** 찍습니다.
# 마지막 ZZFX 는 실재하지 않는 이름입니다 — 게이트가 이름 목록이 아니라 **계열**로
# 떨어뜨리는지(=새 변수가 생겨도 자동으로 닫히는지)를 고정하기 위한 것입니다.
printf 'dryrun=[%s] checkeronly=[%s] stressiter=[%s] mdlimit=[%s] zzfx=[%s]\n' \
  "${RD_SELFTEST_SMOKE_DRYRUN:-}" "${RD_SELFTEST_CHECKER_ONLY:-}" \
  "${RD_EDIT_PROVENANCE_STRESS_ITER:-}" "${CLAUDEMD_LINE_LIMIT:-}" \
  "${RD_SELFTEST_ZZFX:-}" >> "$AST_MK/env"
_ast_record() {
  # shellcheck source=/dev/null
  . "$_r/rd-workflow/scripts/_smoke_common.sh"
  _fp="$(smoke_proof_fingerprint "$_r" worktree)" || exit 1
  _us=0; smoke_untracked_state "$_r" >/dev/null 2>&1 || _us=$?
  # 실제 `consumer` 실행을 흉내내는 변형입니다 — 게이트가 consumer 증명으로 사후 대조를
  # 통과하는지(= 부분 실행이 자기 증명을 무효화하지 않는지) 실측하는 데 씁니다.
  if [[ -n "${AST_STUB_RECORD_CONSUMER:-}" ]]; then
    smoke_record_consumer_pass "$_r" "$_fp" "$_us" 2>/dev/null || true
    return 0
  fi
  smoke_record_full_pass "$_r" "$_fp" "$_us" 2>/dev/null || true
}
if [[ -n "${AST_STUB_RECORD_THEN_FAIL:-}" ]]; then _ast_record; exit 1; fi
if [[ "${AST_STUB_RC:-0}" != "0" ]]; then exit "${AST_STUB_RC}"; fi
if [[ -n "${AST_STUB_NORECORD:-}" ]]; then exit 0; fi
_ast_record
exit 0
ASTSTUB
  git -C "$d" init -q .
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm init >/dev/null 2>&1
  printf '%s\n' "$d"
}

AST_FX="$(ast_make_fx)"
AST_CACHE="$AST_FX/rd-workflow-workspace/.lifecycle/selftest-full-cache"

# --- precheck 단위 ---------------------------------------------------------------
# 증명 헬퍼가 없으면 "확인할 수 없음" 이지 "통과" 가 아닙니다 (fail-closed).
AST_NOH="$(mktemp -d)"; mkdir -p "$AST_NOH/rd-workflow/scripts"
archive_selftest_precheck "$AST_NOH" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — 증명 헬퍼 부재 → 차단"
rm -rf "$AST_NOH"

archive_selftest_precheck "$AST_FX" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — full 기록 없음 → 차단"

# 이 케이스는 호출부의 mode 리터럴을 **행동으로** 못박습니다. `worktree` 가 아닌 값을 넘기면
# 지문 계산이 실패해(모드 검증) 유효한 기록도 무효가 되므로 여기서 바로 깨집니다.
ast_fp "$AST_CACHE"
archive_selftest_precheck "$AST_FX" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — 일치하는 full 기록 → 통과"

# trigger 집합 **밖**의 입력(문서)이 바뀌어도 stale 로 봐야 합니다 —
# "인프라는 그대로인데 문서 변경으로 전수 검증이 깨질 상태" 가 통과하면 안 됩니다.
printf 'note\n' > "$AST_FX/some_doc.md"
git -C "$AST_FX" add -A >/dev/null 2>&1
git -C "$AST_FX" commit -qm doc >/dev/null 2>&1
archive_selftest_precheck "$AST_FX" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — trigger 밖 문서 변경 → 차단"
ast_fp "$AST_CACHE"

printf 'stray\n' > "$AST_FX/stray_zzfx.sh"
archive_selftest_precheck "$AST_FX" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — 유효 캐시 이후 untracked 추가 → 차단"
rm -f "$AST_FX/stray_zzfx.sh"

# 오탐 방향: transient 산출물(감사 로그)은 증명 범위 밖이므로 통과를 막으면 안 됩니다.
printf 'x\n' > "$AST_FX/rd-workflow-workspace/.lifecycle/gate-audit.log"
archive_selftest_precheck "$AST_FX" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — transient 산출물만 생김 → 통과 (오탐 없음)"
rm -f "$AST_FX/rd-workflow-workspace/.lifecycle/gate-audit.log"

# 오탐 방향: 판정 자체가 워킹트리를 바꾸지 않아야 연속 호출이 계속 통과합니다.
archive_selftest_precheck "$AST_FX" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — 상태 불변 시 연속 호출도 통과 (자기 부작용으로 무효화되지 않음)"

printf 'echo b\n' >> "$AST_FX/rd-workflow/scripts/a_zzfx.sh"
archive_selftest_precheck "$AST_FX" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — stale 기록 → 차단"

# 우회 밸브 부재: 다른 계층의 우회 사유가 환경에 있어도 이 게이트는 열리지 않습니다.
( export RD_LIFECYCLE_BYPASS_REASON=lifecycle RD_SELFTEST_FULL_BYPASS_REASON="사유"
  archive_selftest_precheck "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — 우회 사유 환경변수로도 열리지 않음"
git -C "$AST_FX" checkout -- rd-workflow/scripts/a_zzfx.sh
ast_fp "$AST_CACHE"

# --- 게이트(증명 없으면 그 자리에서 전수 검증) -------------------------------------
ast_reset_marks
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 유효 증명 → 통과"
if [[ ! -f "$AST_MK/invoked" ]]; then PASS=$((PASS+1)); echo "  PASS: gate — 유효 증명이면 전수 검증을 돌리지 않는다 (오탐 없음)";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 유효 증명인데 전수 검증을 실행했다" >&2; fi

rm -f "$AST_CACHE"; ast_reset_marks
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 증명 없음 → 전수 검증 실행 후 통과"
assert_eq "$(cat "$AST_MK/invoked" 2>/dev/null || true)" "mode=consumer" "gate — 검증을 consumer 인자로 1회 실행 (정본 위생 검사는 강제 대상이 아님)"
if [[ -s "$AST_CACHE" ]]; then PASS=$((PASS+1)); echo "  PASS: gate — 실행 결과가 증명으로 기록됨";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 통과했는데 증명이 기록되지 않았다" >&2; fi

# 전수 검증은 **위생적인 환경**에서 돌아야 합니다. 셸에 남은 변수 하나가 검사를 건너뛰거나
# (dry-run·checker-only) 검출력을 조용히 낮추면(스트레스 회차·크기 제한), 통과 기록만
# 정상으로 남아 안전망이 거짓말을 합니다. 특히 낮은 스트레스 회차·높은 크기 제한은
# 허용 범위 안이라 경고조차 나지 않습니다.
# `RD_SELFTEST_ZZFX` 는 실재하지 않는 이름입니다 — 이름을 하나씩 적는 방식이면 새 변수가
# 생길 때마다 조용히 구멍이 늘어나므로, **계열로 떨어뜨리는지**를 여기서 못박습니다.
rm -f "$AST_CACHE"; ast_reset_marks
( export RD_SELFTEST_SMOKE_DRYRUN=1 RD_SELFTEST_CHECKER_ONLY=_hook_repo_root \
         RD_EDIT_PROVENANCE_STRESS_ITER=1 CLAUDEMD_LINE_LIMIT=999999 RD_SELFTEST_ZZFX=1
  archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 검증 약화 환경변수가 있어도 통과(실제 실행)"
assert_eq "$(cat "$AST_MK/env" 2>/dev/null || true)" \
  "dryrun=[] checkeronly=[] stressiter=[] mdlimit=[] zzfx=[]" \
  "gate — 검증 약화 환경변수를 계열째 떨어뜨리고 실행"

# untracked 가 있으면 전수 검증이 통과해도 증명이 기록되지 않아, 실행해 봐야 같은 자리에서
# 무한히 다시 돌게 됩니다. 정상 경로는 clean 검사가 먼저 막으므로 여기에 도달하는 것은
# clean 검사를 강제로 넘긴 경우입니다 — 돌리기 전에 알리고 중단하는 것이 옳습니다.
rm -f "$AST_CACHE"; ast_reset_marks
printf 'stray\n' > "$AST_FX/stray_zzfx.sh"
ast_out="$( ( archive_selftest_gate "$AST_FX" ) 2>&1 )" && rc=0 || rc=1
assert_eq "$rc" "1" "gate — untracked 존재 → 차단"
if [[ ! -f "$AST_MK/invoked" ]]; then PASS=$((PASS+1)); echo "  PASS: gate — untracked 존재 시 전수 검증을 돌리지 않는다 (무한 재실행 방지)";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — untracked 인데 전수 검증을 실행했다 (기록되지 않아 무한 재실행)" >&2; fi
if printf '%s' "$ast_out" | grep -qF 'stray_zzfx.sh'; then PASS=$((PASS+1)); echo "  PASS: gate — 차단 사유에 해당 파일 표시";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 차단 사유에 파일 목록 없음" >&2; fi
if printf '%s' "$ast_out" | grep -qF 'force-dirty'; then PASS=$((PASS+1)); echo "  PASS: gate — clean 검사를 넘긴 경로임을 안내";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — --force-dirty 경로 안내 없음" >&2; fi
rm -f "$AST_FX/stray_zzfx.sh"

# 정상 진행 경로는 stderr 를 쓰지 않아야 합니다. 여기서 사유를 stderr 로 흘리면 아카이브의
# "무출력 계약" 을 검사하는 소비처들이 정상 상태를 결함으로 보고 줄줄이 실패합니다 (실측).
rm -f "$AST_CACHE"; ast_reset_marks
ast_err="$( ( archive_selftest_gate "$AST_FX" ) 2>&1 >/dev/null )" && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 전수 검증 실행 경로도 통과"
assert_eq "$ast_err" "" "gate — 정상 진행 경로는 stderr 무출력"
rm -f "$AST_CACHE"; ast_reset_marks
# 기대 사유는 판정 함수에서 직접 받아옵니다 — 문구를 테스트에 복사하면 판정이 바뀌어도
# 테스트만 통과하는 상태가 생깁니다.
# **게이트가 실제로 쓰는 경계**에서 받아옵니다. 게이트는 `archive-gate 판정`(full 또는
# consumer)을 쓰므로 `full-only 판정` 으로 사유를 뽑으면 문구가 달라 이 단언이 거짓 실패합니다.
if declare -F smoke_archive_gate_valid >/dev/null 2>&1; then
  ast_why="$(smoke_archive_gate_valid "$AST_FX" worktree 2>&1 >/dev/null | head -1)" || true
else
  ast_why="$(smoke_cache_valid "$AST_FX" worktree 2>&1 >/dev/null | head -1)" || true
fi
ast_out="$( ( archive_selftest_gate "$AST_FX" ) 2>/dev/null )" && rc=0 || rc=1
if printf '%s' "$ast_out" | grep -qF '지금 실행합니다'; then PASS=$((PASS+1)); echo "  PASS: gate — 실행 안내를 stdout 으로 표시 (장시간 무반응 방지)";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 실행 안내가 stdout 에 없음 (장시간 무반응)" >&2; fi
if [[ -n "$ast_why" ]] && printf '%s' "$ast_out" | grep -qF -- "$ast_why"; then
  PASS=$((PASS+1)); echo "  PASS: gate — 왜 지금 도는지 사유를 stdout 에 함께 표시"
else
  FAIL=$((FAIL+1)); echo "  FAIL: gate — 실행 사유가 stdout 에 없음 — [$ast_why]" >&2; fi

rm -f "$AST_CACHE"; ast_reset_marks
( export AST_STUB_RC=1; archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 전수 검증 실패 → 차단"

# 위 케이스는 이름이 주장하는 성질(rc 반영)을 고정하지 못합니다 — 실패한 대역이 증명도
# 남기지 않아 **재대조가 대신 막기** 때문입니다 (rc 를 통째로 무시해도 초록입니다).
# 증명은 남기면서 rc 만 실패하는 변형으로 그 성질을 분리해 못박습니다.
rm -f "$AST_CACHE"; ast_reset_marks
( export AST_STUB_RECORD_THEN_FAIL=1; archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 증명이 남아도 전수 검증 rc 가 실패면 차단 (rc 가 판정에 반영)"
if [[ -s "$AST_CACHE" ]]; then PASS=$((PASS+1)); echo "  PASS: gate — 위 케이스가 실제로 '증명 있음 + rc 실패' 였음 (단언이 공허하지 않음)";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 증명이 남지 않아 rc 반영을 분리 검증하지 못했다" >&2; fi

# **우회 밸브 부재는 이 게이트의 유일한 존재 이유입니다.** 아래 행동 회귀가 고정하는
# 범위는 **알려진 이름 2개**(`RD_LIFECYCLE_BYPASS_REASON`·`RD_SELFTEST_FULL_BYPASS_REASON`)
# 뿐입니다 — 이름을 열거하는 점에서 소스 문자열 검사와 사각의 크기가 같습니다.
# 세 번째 이름을 쓰는 밸브는 배선 회귀의 **구조 불변식**(게이트 계열 함수 본문의
# 환경변수 읽기 = 0건)이 이름과 무관하게 잡습니다. 두 축이 함께여야 닫힙니다.
# (a) 다른 계층의 우회 사유가 환경에 있어도 전수 검증 실패를 통과로 바꾸지 못합니다.
rm -f "$AST_CACHE"; ast_reset_marks
( export RD_LIFECYCLE_BYPASS_REASON=lifecycle RD_SELFTEST_FULL_BYPASS_REASON="사유" AST_STUB_RC=1
  archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 우회 사유 환경변수로도 열리지 않음"
# (b) 우회 사유가 있어도 전수 검증을 **실제로 돌립니다**. 밸브가 함수 앞쪽에 놓여
#     조용히 return 0 하면 rc 는 0 이라 (a) 로는 잡히지만, "돌지 않았다" 는 사실 자체를
#     여기서 별도로 못박습니다 (rc 만 보는 단언은 밸브 위치에 따라 새어 나갑니다).
rm -f "$AST_CACHE"; ast_reset_marks
( export RD_LIFECYCLE_BYPASS_REASON=lifecycle RD_SELFTEST_FULL_BYPASS_REASON="사유"
  archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 우회 사유가 있어도 정상 경로는 그대로 통과 (오탐 없음)"
assert_eq "$(cat "$AST_MK/invoked" 2>/dev/null || true)" "mode=consumer" \
  "gate — 우회 사유가 있어도 검증을 건너뛰지 않는다"

# --- 헬퍼 오류 경로의 범위 표시 (final diff review Turn 004 Finding 1) -------
# 헬퍼 부재·구문 오류는 **복구가 필요한 경로**입니다. 여기서 "전수 검증" 이라고 말하면
# 사용자는 dev-only 까지 강제되는 것으로 오인하고 엉뚱한 명령을 돌립니다. 기존 회귀는
# stderr 를 버리고 rc 만 봐서 이 오표시를 잡지 못했습니다.
_ast_helper="$AST_FX/rd-workflow/scripts/_smoke_common.sh"
ast_mv "$_ast_helper" "${_ast_helper}.hidden"
_ast_out="$( ( archive_selftest_gate "$AST_FX" ) 2>&1 )" && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 증명 헬퍼 부재 → 차단"
if printf '%s' "$_ast_out" | grep -qF '전수 검증'; then
  FAIL=$((FAIL+1)); echo "  FAIL: gate — 헬퍼 부재 오류가 '전수 검증' 이라고 표시합니다 (강제 범위는 consumer)" >&2
else PASS=$((PASS+1)); echo "  PASS: gate — 헬퍼 부재 오류에 '전수 검증' 오표시 없음"; fi
if printf '%s' "$_ast_out" | grep -qF '증명 헬퍼가 없습니다'; then
  PASS=$((PASS+1)); echo "  PASS: gate — 헬퍼 부재 사유를 표시 (단언이 공허하지 않음)"
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 헬퍼 부재 사유가 표시되지 않아 위 단언이 공허합니다" >&2; fi
ast_mv "${_ast_helper}.hidden" "$_ast_helper"

# 구문 오류 변형 — 같은 경로의 다른 분기입니다.
cp "$_ast_helper" "${_ast_helper}.bak"
printf 'if then fi(\n' >> "$_ast_helper"
_ast_out="$( ( archive_selftest_gate "$AST_FX" ) 2>&1 )" && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 증명 헬퍼 구문 오류 → 차단"
if printf '%s' "$_ast_out" | grep -qF '전수 검증'; then
  FAIL=$((FAIL+1)); echo "  FAIL: gate — 헬퍼 구문 오류가 '전수 검증' 이라고 표시합니다" >&2
else PASS=$((PASS+1)); echo "  PASS: gate — 헬퍼 구문 오류에 '전수 검증' 오표시 없음"; fi
ast_mv "${_ast_helper}.bak" "$_ast_helper"

# --- 증명 판정 경계 행렬 (AC 6) ----------------------------------------------
# 청중별 증명을 파일로 나눴으므로 **두 판정 경계**가 서로를 오인하지 않아야 합니다.
#   full-only 판정   = smoke_cache_valid          — full 증명만 인정 (전수 요구 지점 전용)
#   archive-gate 판정 = smoke_archive_gate_valid  — full 또는 consumer 인정
#
# 파일을 나눈 것만으로는 미래의 reader 를 보장하지 못하므로 **경계 자체를 관측**합니다.
AST_CONC="$AST_FX/rd-workflow-workspace/.lifecycle/selftest-consumer-cache"

ast_matrix() { # ast_matrix <라벨> <full-only 기대rc> <archive-gate 기대rc>
  local label="$1" want_full="$2" want_gate="$3" rc
  smoke_cache_valid "$AST_FX" worktree >/dev/null 2>&1 && rc=0 || rc=1
  assert_eq "$rc" "$want_full" "proof 행렬 — ${label}: full-only 판정"
  smoke_archive_gate_valid "$AST_FX" worktree >/dev/null 2>&1 && rc=0 || rc=1
  assert_eq "$rc" "$want_gate" "proof 행렬 — ${label}: archive-gate 판정"
}

rm -f "$AST_CACHE" "$AST_CONC"
ast_matrix "둘 다 없음" 1 1

ast_fp "$AST_CONC"
ast_matrix "consumer 증명만 유효" 1 0

ast_fp "$AST_CACHE"
ast_matrix "둘 다 유효" 0 0

rm -f "$AST_CONC"
ast_matrix "full 증명만 유효" 0 0

# 지문 불일치는 양쪽 모두 무효입니다 (무효화 규칙은 기존 지문 방식 그대로).
printf 'bogus
' > "$AST_CACHE"; printf 'bogus
' > "$AST_CONC"
ast_matrix "지문 불일치" 1 1
rm -f "$AST_CACHE" "$AST_CONC"

# **Blocker 회귀**: consumer 캐시가 proof 제외 목록에 없으면, 방금 기록한 증명이 다음
# 판정에서 untracked 로 잡혀 **자기 자신을 무효화**합니다. 그러면 게이트가 영구히 실패합니다.
ast_fp "$AST_CONC"
_ast_us=0; smoke_untracked_state "$AST_FX" >/dev/null 2>&1 || _ast_us=$?
assert_eq "$_ast_us" "0" "proof 제외 — consumer 캐시가 untracked 판정에 잡히지 않음"
smoke_archive_gate_valid "$AST_FX" worktree >/dev/null 2>&1 && _ast_rc=0 || _ast_rc=1
assert_eq "$_ast_rc" "0" "proof 제외 — consumer 증명이 스스로를 무효화하지 않음"
# 중단으로 남은 원자 기록 임시 파일도 같은 취급이어야 합니다.
printf 'partial
' > "${AST_CONC}.tmp123"
_ast_us=0; smoke_untracked_state "$AST_FX" >/dev/null 2>&1 || _ast_us=$?
assert_eq "$_ast_us" "0" "proof 제외 — consumer 캐시 임시 파일도 판정을 바꾸지 않음"
rm -f "${AST_CONC}.tmp123"
# 반대 방향 — `.lifecycle` **밖**의 비슷한 이름은 계속 차단돼야 합니다. 제외 패턴을
# 넓게 잡으면 정작 막아야 할 신규 파일이 조용히 통과합니다.
printf 'x
' > "$AST_FX/selftest-consumer-cache"
_ast_us=0; smoke_untracked_state "$AST_FX" >/dev/null 2>&1 || _ast_us=$?
assert_eq "$_ast_us" "1" "proof 제외 — .lifecycle 밖 동명 파일은 계속 차단"
rm -f "$AST_FX/selftest-consumer-cache"

# 게이트 사후 대조 — 실제 `consumer` 실행이 남기는 증명으로 통과해야 합니다.
# 이것이 성립하지 않으면 게이트는 "돌렸는데 증명이 없다" 며 영구히 막습니다.
rm -f "$AST_CACHE" "$AST_CONC"; ast_reset_marks
( export AST_STUB_RECORD_CONSUMER=1; archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — consumer 증명만 남겨도 사후 대조를 통과"
assert_eq "$(cat "$AST_MK/invoked" 2>/dev/null || true)" "mode=consumer" "gate — 그 경로에서도 consumer 인자로 실행"
if [[ -s "$AST_CONC" ]]; then PASS=$((PASS+1)); echo "  PASS: gate — consumer 증명이 실제로 기록됨 (단언이 공허하지 않음)";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — consumer 증명이 기록되지 않아 위 단언이 공허합니다" >&2; fi
if [[ -e "$AST_CACHE" ]]; then FAIL=$((FAIL+1)); echo "  FAIL: gate — consumer 실행이 full 증명 파일을 만들었습니다 (부분 실행이 전수 통과로 위장)" >&2;
else PASS=$((PASS+1)); echo "  PASS: gate — consumer 실행이 full 증명 파일을 건드리지 않음"; fi

# 유효한 consumer 증명이 있으면 게이트는 **돌리지 않고** 통과합니다 (빠른 경로).
ast_reset_marks
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 유효한 consumer 증명으로 통과"
if [[ ! -f "$AST_MK/invoked" ]]; then PASS=$((PASS+1)); echo "  PASS: gate — 유효한 consumer 증명이 있으면 검증을 다시 돌리지 않음";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 유효한 증명이 있는데 검증을 다시 실행했습니다" >&2; fi
rm -f "$AST_CACHE" "$AST_CONC"

# 게이트가 증명하는 것은 **워킹트리**이고 tag·push 로 발행되는 것은 **HEAD** 입니다.
# 둘이 갈라진 채 통과하면 "검증됐다" 는 말과 실제 발행물이 다릅니다 — untracked 축만
# 보면 `--force-dirty` 의 주 용도인 **tracked dirty** 가 통째로 새어 나갑니다.
rm -f "$AST_CACHE"; ast_reset_marks
printf 'echo dirty\n' >> "$AST_FX/rd-workflow/scripts/a_zzfx.sh"
ast_out="$( ( archive_selftest_gate "$AST_FX" ) 2>&1 )" && rc=0 || rc=1
assert_eq "$rc" "1" "gate — tracked 파일이 커밋되지 않은 채 dirty → 차단"
if [[ ! -f "$AST_MK/invoked" ]]; then PASS=$((PASS+1)); echo "  PASS: gate — 워킹트리≠HEAD 면 전수 검증을 돌리지 않는다";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 워킹트리≠HEAD 인데 전수 검증을 실행했다 (미검증 HEAD 발행)" >&2; fi
if printf '%s' "$ast_out" | grep -qF '발행 대상'; then PASS=$((PASS+1)); echo "  PASS: gate — 증명 대상과 발행 대상이 다르다는 사유를 안내";
else FAIL=$((FAIL+1)); echo "  FAIL: gate — 왜 성립하지 않는지 안내가 없음 — [$ast_out]" >&2; fi
git -C "$AST_FX" checkout -- rd-workflow/scripts/a_zzfx.sh

# **유효한 증명이 이미 있어도** 막아야 합니다. 증명은 "이 워킹트리가 통과했다" 는 말이고
# 발행되는 것은 HEAD 이므로, 둘이 갈라진 상태에서는 증명이 발행물을 증명하지 못합니다.
# 이 확인이 증명 대조보다 **뒤**에 있으면 빠른 경로가 통째로 건너뛰어, 가장 흔한 경우
# (증명이 유효한 상태로 아카이브)에서 그대로 새어 나갑니다.
ast_reset_marks
printf 'echo dirty2\n' >> "$AST_FX/rd-workflow/scripts/a_zzfx.sh"
ast_fp "$AST_CACHE"   # 지금(dirty) 워킹트리로 유효 증명을 만듭니다
( archive_selftest_precheck "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — (전제) dirty 워킹트리에 대한 증명은 그 자체로는 유효"
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 유효 증명이 있어도 워킹트리≠HEAD 면 차단 (빠른 경로도 확인)"
git -C "$AST_FX" checkout -- rd-workflow/scripts/a_zzfx.sh
rm -f "$AST_CACHE"

# staged 만 해도 발행 대상(HEAD)과는 여전히 다릅니다 — `git add` 로 untracked 만 지우고
# 통과하면 커밋되지 않은 내용이 검증된 것으로 기록됩니다.
rm -f "$AST_CACHE"; ast_reset_marks
printf 'echo staged\n' > "$AST_FX/rd-workflow/scripts/b_zzfx.sh"
git -C "$AST_FX" add rd-workflow/scripts/b_zzfx.sh >/dev/null 2>&1
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "gate — staged 이지만 커밋 안 됨 → 차단 (untracked 만 없앤 상태)"
git -C "$AST_FX" rm -q --cached rd-workflow/scripts/b_zzfx.sh >/dev/null 2>&1
rm -f "$AST_FX/rd-workflow/scripts/b_zzfx.sh"

# 오탐 방향 1 — 증명 집합 **밖**(transient)의 tracked 파일이 dirty 인 것으로는 막지
# 않아야 합니다. 범위를 증명 집합보다 넓게 잡으면 감사 로그 한 줄에 정당한 아카이브가
# 막히고, 우회 밸브가 없으므로 사용자는 게이트 자체를 들어내게 됩니다.
rm -f "$AST_CACHE"; ast_reset_marks
printf 'v2\n' > "$AST_FX/rd-workflow-workspace/.lifecycle/verify-cache"
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 증명 범위 밖 transient 만 dirty → 통과 (오탐 없음)"
git -C "$AST_FX" checkout -- rd-workflow-workspace/.lifecycle/verify-cache

# 오탐 방향 2 — 강제 플래그로 clean 검사를 넘겼더라도 **실제로 clean 이면** 통과해야
# 합니다. 판정 근거는 플래그가 아니라 실제 상태입니다.
rm -f "$AST_CACHE"; ast_reset_marks
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "gate — 워킹트리가 실제로 clean 이면 통과 (강제 플래그 무관)"

rm -f "$AST_CACHE"; ast_reset_marks
( export AST_STUB_NORECORD=1; archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 실행만 하고 증명이 남지 않으면 차단"

rm -f "$AST_CACHE"; ast_reset_marks
ast_mv "$AST_FX/rd-workflow/scripts/self_test.sh" "$AST_MK/stub.bak"
( archive_selftest_gate "$AST_FX" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "gate — 전수 검증 스크립트 부재 → 차단"
ast_mv "$AST_MK/stub.bak" "$AST_FX/rd-workflow/scripts/self_test.sh"

rm -rf "$AST_FX" "$AST_MK"

# --- 배선 회귀 (소스 순서·우회 밸브 부재) -------------------------------------------
# 실제 아카이브는 merge·tag·push·브랜치 삭제를 수행해 회귀로 돌릴 수 없습니다. 그래서
# "게이트가 어느 구간에 놓였는가" 는 소스 순서로 고정합니다 — 위쪽 순서 불변식 단언과 같은 방식.
# 주석 줄은 걸러냅니다. 이 저장소는 주석 리터럴이 판정을 오염시킨 전례가 여러 번 있고
# (backlog/items/2026-08-19-closure-comment-literal-pollution.md), 게이트 위치를 설명하는
# 주석에 같은 문자열이 들어가는 것은 충분히 있을 법한 일입니다. `grep -n` 이 먼저라
# 걸러도 원래 줄번호가 보존됩니다.
_ast_gate_ln="$(grep -n 'archive_selftest_gate "' "$AST_ARCHIVE_SH" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)" || true
_ast_dry_ln="$(grep -n 'DRY_RUN.*-eq 1' "$AST_ARCHIVE_SH" | head -1 | cut -d: -f1)" || true
_ast_merge_ln="$(grep -n '^# Step 3 — merge' "$AST_ARCHIVE_SH" | head -1 | cut -d: -f1)" || true
_ast_step4_ln="$(grep -n '^# Step 4 — metadata cleanup' "$AST_ARCHIVE_SH" | head -1 | cut -d: -f1)" || true
_ast_tag_ln="$(grep -n '^# Step 5 — Tag' "$AST_ARCHIVE_SH" | head -1 | cut -d: -f1)" || true
if [[ -n "$_ast_gate_ln" && -n "$_ast_dry_ln" && "$_ast_gate_ln" -gt "$_ast_dry_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: 게이트($_ast_gate_ln)가 dry-run exit($_ast_dry_ln) 뒤 — dry-run 비파괴"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 게이트($_ast_gate_ln)가 dry-run($_ast_dry_ln) 앞 — dry-run 이 검증 시간을 소비" >&2; fi
if [[ -n "$_ast_gate_ln" && -n "$_ast_merge_ln" && "$_ast_gate_ln" -gt "$_ast_merge_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: 게이트($_ast_gate_ln)가 merge($_ast_merge_ln) 뒤 — 아카이브될 내용으로 대조"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 게이트가 merge 앞 — 캐시가 구조적으로 항상 불일치 (gate=$_ast_gate_ln merge=$_ast_merge_ln)" >&2; fi
if [[ -n "$_ast_gate_ln" && -n "$_ast_step4_ln" && "$_ast_gate_ln" -lt "$_ast_step4_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: 게이트($_ast_gate_ln)가 metadata cleanup($_ast_step4_ln) 앞 — 미러 재작성이 지문을 흔들기 전"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 게이트가 metadata cleanup 뒤 — 지문이 구조적으로 항상 불일치 (gate=$_ast_gate_ln step4=$_ast_step4_ln)" >&2; fi
if [[ -n "$_ast_gate_ln" && -n "$_ast_tag_ln" && "$_ast_gate_ln" -lt "$_ast_tag_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: 게이트($_ast_gate_ln)가 tag($_ast_tag_ln) 앞 — 미검증 내용이 발행되지 않음"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 게이트가 tag 뒤 — 미검증 내용이 발행될 수 있음 (gate=$_ast_gate_ln tag=$_ast_tag_ln)" >&2; fi

# --- 전수 검증 실패 시 merge 되돌리기 (final diff review 2026-08-20 Finding 2) ----------
# 닫으려는 경로: merge 성공 → 전수 검증 실패 → 사용자가 **main 워킹트리에서** 고쳐 커밋 →
# 재실행 시 review precheck 는 예전 fr tip 만 보고 통과하고 fr 이 이미 조상이라 merge 는
# skip → **리뷰된 적 없는 main 커밋이 발행**됩니다. 공격적 우회가 아니라 정상 복구 행동이며,
# 이 브랜치가 fr_branch_gate(main 직접 커밋 차단)를 제거해 기계적으로 허용됩니다.
# main 을 merge 이전으로 되돌리면 고칠 곳이 fr branch 밖에 남지 않아 경로가 끊깁니다.
#
# 위 배선 단언과 같은 이유로 소스 검사입니다 (실제 merge·tag·push 를 회귀로 돌릴 수 없음).
# 주석 줄은 전부 걸러냅니다 — 이 처방을 설명하는 주석에 같은 리터럴이 들어가므로
# 걸러내지 않으면 **코드를 지우고 주석만 남겨도 초록**이 됩니다.
# 주석 제외는 `^[^#]*` 로 패턴에 직접 넣습니다. `grep -v | grep` 파이프라인은 이 스위트
# 안에서 같은 입력에 다른 결과를 냈습니다(격리 실행은 통과, 스위트 실행은 실패) — 판정이
# 셸 환경에 의존하면 그 판정 자체를 믿을 수 없으므로 파이프라인을 걷어냈습니다.
# `[^#]*` 는 `#` 를 건너뛰지 못하므로 주석 뒤에 있는 같은 리터럴은 매치되지 않습니다.
if grep -qE '^[^#]*PRE_MERGE_HEAD="\$\(git rev-parse HEAD' "$AST_ARCHIVE_SH"; then
  PASS=$((PASS+1)); echo "  PASS: archive.sh 가 merge 이전 HEAD 를 기록한다 (되돌림 기준점)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: merge 이전 HEAD 기록 없음 — 전수 검증 실패 시 되돌릴 기준점이 없다" >&2; fi
if grep -qE '^[^#]*git reset --hard "\$PRE_MERGE_HEAD"' "$AST_ARCHIVE_SH"; then
  PASS=$((PASS+1)); echo "  PASS: 전수 검증 실패 시 merge 를 되돌린다"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 전수 검증 실패 후 merge 가 main 에 남는다 — main 직접 수정이 리뷰를 우회한다" >&2; fi
# 되돌림은 **이 실행이 만든 merge 가 손대지 않은 채 HEAD 일 때만** 해야 합니다. 이 가드가
# 없으면 사람이 얹은 커밋이나 작업 내용을 지웁니다 — 안전망이 파괴 도구가 됩니다.
# 세 번째 토큰은 clean 판정의 **결과 변수**(`_rb_dirty`)를 봅니다. 판정 명령의 형태
# (`git status …` / `git -C … status …`)를 리터럴로 박으면 그 형태를 고칠 때마다 이 단언이
# 깨집니다 — 실제로 `git -C "$CURRENT_WT"` 를 붙이는 수정에서 깨져 main 에 FAIL 이 발행됐습니다.
# 명령 형태(저장소 루트 기준인지)는 `test_integration.sh` 의 배선 단언이 따로 봅니다.
_ast_rb_guarded=1
for _ast_g in 'MERGE_CREATED_HERE' 'MERGE_BASE_COMMIT' '_rb_dirty'; do
  grep -qE "^[^#]*${_ast_g}" "$AST_ARCHIVE_SH" || _ast_rb_guarded=0
done
if [[ "$_ast_rb_guarded" -eq 1 ]]; then
  PASS=$((PASS+1)); echo "  PASS: 되돌림이 3중 가드(이 실행이 만듦·HEAD 불변·워킹트리 clean) 아래 있다"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 되돌림 가드 누락 — 사람이 얹은 커밋·변경을 지울 수 있다" >&2; fi
# 되돌림이 Step 4 앞에 있어야 합니다. 뒤에 있으면 metadata cleanup 이 이미 HEAD 를
# 전진시킨 뒤라 위 "HEAD 불변" 가드가 항상 거짓이 되어 되돌림이 죽은 코드가 됩니다.
_ast_rb_ln="$(grep -nE '^[^#]*git reset --hard "\$PRE_MERGE_HEAD"' "$AST_ARCHIVE_SH" | head -1 | cut -d: -f1)" || true
if [[ -n "$_ast_rb_ln" && -n "$_ast_step4_ln" && "$_ast_rb_ln" -lt "$_ast_step4_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: 되돌림($_ast_rb_ln)이 metadata cleanup($_ast_step4_ln) 앞 — 가드가 살아 있다"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 되돌림이 metadata cleanup 뒤 — HEAD 불변 가드가 항상 거짓이라 죽은 코드 (rb=$_ast_rb_ln step4=$_ast_step4_ln)" >&2; fi
# 우회 밸브 부재는 **두 파일을 함께** 봅니다. 게이트 본문은 `_guard_common.sh` 에 있고
# 밸브를 넣기 가장 자연스러운 자리가 정확히 거기인데, 호출 한 줄만 남은 `archive.sh` 만
# 보면 그 자리가 통째로 사각이 됩니다 (실측: 그 자리에 밸브 6줄을 넣어도 220/220 초록).
# 주석 줄은 제외합니다 — 밸브는 주석에 있을 수 없고, 설명 주석이 판정을 오염시키면
# 다음 사람이 판정을 피해 주석을 고치게 됩니다.
for _ast_f in "$AST_ARCHIVE_SH" "$AST_GUARD_SH"; do
  if grep -vE '^[[:space:]]*#' "$_ast_f" | grep -qF 'RD_SELFTEST_FULL_BYPASS_REASON'; then
    FAIL=$((FAIL+1)); echo "  FAIL: 아카이브 경로($(basename "$_ast_f"))에 전수 검증 우회 밸브가 생겼다 — 이 게이트의 존재 이유가 사라진다" >&2
  else
    PASS=$((PASS+1)); echo "  PASS: 아카이브 경로($(basename "$_ast_f"))에 전수 검증 우회 밸브 없음"; fi
done
# 위 소스 검사와 행동 회귀는 **둘 다 이름을 열거**합니다. 세 번째 이름을 쓰는 밸브는
# 양쪽을 그대로 통과합니다 (실측: `RD_ARCHIVE_FULL_SKIP` 밸브 5줄을 세 함수 각각에 넣어도
# 전부 `PASS=234 FAIL=0` rc 0 — 완전히 초록이었습니다).
# 이름 대신 밸브의 **구조적 필요조건**을 봅니다 — 밸브는 반드시 환경을 읽고, 게이트 계열
# 함수 본문은 지금 환경변수를 **하나도** 읽지 않습니다. 그래서 "본문의 대문자 변수 읽기
# = 0" 이 성립하고, 이 불변식은 이름을 몰라도 모든 밸브를 잡습니다.
#
# 대상은 **return 0 이 곧 '진행' 으로 귀결되는 함수**들입니다. `archive_selftest_env_denylist`
# 는 제외합니다 — env 자체가 그 함수의 주제이고, 그 함수의 return 0 은 통과가 아니라
# 목록 산출입니다 (그쪽은 계열 산출 단언이 따로 고정합니다).
#
# **이 불변식은 정당한 환경변수 읽기도 막습니다. 그것이 의도입니다.** 이 함수들이 판정에
# 쓰는 입력은 인자로 받은 root 하나여야 하고, 환경에서 무엇이든 읽는 순간 그 판정은
# 호출자의 환경이 흔들 수 있게 됩니다 — 그것이 정확히 이 게이트가 없애려는 성질입니다.
# 앞으로 정말 환경을 읽어야 하면 이 단언을 지우지 말고, (1) 그 읽기가 통과/차단 판정을
# 바꿀 수 없음을 별도 단언으로 못박은 뒤 (2) 그 이름만 좁게 예외로 빼십시오.
#
# 검출 형태는 `$NAME`·`${NAME…}` 직접 확장 + `${!x}` 간접 확장 + `printenv` 입니다.
# **남는 구멍 둘을 적어 둡니다** (닫지 않은 이유도 함께):
#   - `env | grep …` 로 읽는 형태. `env` 는 이 게이트가 **위생적 실행**에 정당하게 쓰는
#     명령이라(`env -u … bash self_test.sh`) 리터럴로 막으면 정상 코드가 막힙니다.
#   - 소문자 이름(`$rd_skip`). 관례상 환경변수가 아니고, 소문자 기본값 전개
#     (`${x:-…}`)는 지역변수에서 흔해 막으면 오탐이 큽니다.
# 둘 다 "이름을 새로 짓는" 것보다 훨씬 노골적인 회피라 diff 에서 눈에 띕니다.
for _ast_fn in archive_selftest_gate archive_selftest_preconditions \
               archive_selftest_precheck _archive_selftest_helper_load; do
  _ast_envread="$(awk "/^${_ast_fn}\(\)/,/^}/" "$AST_GUARD_SH" \
                   | grep -vE '^[[:space:]]*#' | grep -cE '\$\{?[A-Z][A-Z0-9_]{2,}|\$\{!|printenv' || true)"
  # 함수가 사라지거나 이름이 바뀌면 awk 범위가 비어 읽기 0건이 되어 **공허하게 통과**합니다.
  # 이 저장소에서 반복된 "0건 검사로 조용히 초록" 부류라 존재부터 확인합니다.
  if ! grep -qE "^${_ast_fn}\(\)" "$AST_GUARD_SH"; then
    FAIL=$((FAIL+1)); echo "  FAIL: $_ast_fn 정의를 찾지 못해 밸브 불변식이 공허하게 통과한다 — 이름이 바뀌었다면 이 목록도 함께 고치십시오" >&2
  elif [[ "$_ast_envread" -eq 0 ]]; then
    PASS=$((PASS+1)); echo "  PASS: $_ast_fn 본문이 환경변수를 읽지 않음 (이름 무관 밸브 부재)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $_ast_fn 본문이 환경변수를 ${_ast_envread}건 읽는다 — 이름이 무엇이든 우회 밸브가 될 수 있다. 판정 입력은 인자 root 하나여야 한다" >&2; fi
done
# `--force-dirty` 는 **Step 0 의 clean 검사만** 넘깁니다. 게이트의 워킹트리≠HEAD 확인은
# 플래그가 아니라 실제 상태로 판정하므로 그대로 막습니다. 첫 줄이 "강제 진행" 이라고만
# 알리면 사용자는 같은 화면 네 줄 아래의 중단을 모순으로 읽고 게이트를 의심하게 됩니다.
# 안내 문구는 장식이 아니라 계약이므로 여기서 고정합니다.
if grep -vE '^[[:space:]]*#' "$AST_ARCHIVE_SH" | grep -F -- '--force-dirty' | grep -q 'clean 검사만'; then
  PASS=$((PASS+1)); echo "  PASS: --force-dirty 경고가 효과 범위(clean 검사만)를 한정해 알림"
else
  FAIL=$((FAIL+1)); echo "  FAIL: --force-dirty 경고가 '강제 진행' 으로만 알린다 — 아래 게이트 중단과 한 화면에서 모순돼 보인다" >&2; fi
if grep -qF 'smoke_cache_valid "$root" worktree' "$AST_GUARD_SH"; then
  PASS=$((PASS+1)); echo "  PASS: 캐시 대조 mode 가 리터럴 worktree"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 캐시 대조 mode 리터럴이 worktree 가 아니다 — 오타는 '항상 차단' 으로 조용히 굳는다" >&2; fi
# 떨어뜨릴 변수 목록은 **계열**로 산출돼야 합니다. 이름을 하나씩 적어 두면 같은 계열의
# 변수를 새로 만들 때마다 구멍이 하나씩 조용히 늘어납니다 (이 저장소에서 반복된 결함
# 부류입니다). 실재하지 않는 이름 두 개로 계열 산출을 못박습니다.
_ast_deny="$( ( export RD_SELFTEST_ZZFX=1 RD_EDIT_PROVENANCE_ZZFX=1
                archive_selftest_env_denylist ) | tr '\n' ' ' )" || true
_ast_deny_ok=1
for _ast_v in RD_SELFTEST_ZZFX RD_EDIT_PROVENANCE_ZZFX CLAUDEMD_LINE_LIMIT; do
  printf '%s' "$_ast_deny" | grep -qF "$_ast_v" || _ast_deny_ok=0
done
if [[ "$_ast_deny_ok" -eq 1 ]]; then
  PASS=$((PASS+1)); echo "  PASS: 전수 검증 실행 환경에서 떨어뜨릴 변수를 계열로 산출"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 떨어뜨릴 변수 산출이 계열을 덮지 못한다 — 새 변수가 생길 때마다 구멍이 난다 — [$_ast_deny]" >&2; fi

# 조용한 중단 센티넬이 **끝까지 살아 있었는지**를 실행 시점에 확인합니다. bash 는 EXIT trap
# 을 하나만 갖고, 나중에 건 것이 앞의 것을 말없이 지웁니다 — 실제로 그 사고가 있었고
# (임시 디렉터리 정리 trap 이 센티넬을 덮어써 조용한 죽음 3형태가 전부 통과), 소스만 봐서는
# 드러나지 않았습니다. 이 단언이 실패하면 센티넬은 이미 없는 상태입니다.
if [[ "$(trap -p EXIT)" == *_suite_on_exit* ]]; then
  PASS=$((PASS+1)); echo "  PASS: 조용한 중단 센티넬(EXIT trap)이 스위트 끝까지 유지됨"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 최상위 EXIT trap 이 센티넬을 덮어썼다 — 조용한 중단이 다시 익명이 된다. 정리 대상은 _ast_cleanup 에 append 하십시오 — [$(trap -p EXIT)]" >&2; fi

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
# `DONE=1` 은 결과줄 **직후**이고 `[[ $FAIL -eq 0 ]]` **앞**입니다. 뒤에 두면 정상적으로
# FAIL 로 끝나는 실행(rc 1)에서 센티넬이 "조용한 중단" 을 오탐합니다 — 센티넬이 묻는 것은
# "결과를 보고했는가" 이지 "통과했는가" 가 아닙니다.
DONE=1
[[ $FAIL -eq 0 ]]
