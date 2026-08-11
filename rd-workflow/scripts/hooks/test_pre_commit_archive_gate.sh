#!/bin/bash
# test_pre_commit_archive_gate.sh — pre_commit_archive_gate.sh Source FR 해석·enforcement 격리 검증
# macOS /bin/bash 3.2 호환. fixture 패턴: test_implementation_gate.sh 준용.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
HOOK_SOURCE="$HOOK_DIR/pre_commit_archive_gate.sh"
GUARD_COMMON="$HOOK_DIR/_guard_common.sh"
STATE_COMMON="$SCRIPTS_DIR/_state_common.sh"
PASS=0
FAIL=0

_current_fixture=""
cleanup_fixture() {
  if [[ -n "$_current_fixture" && -d "$_current_fixture" ]]; then
    rm -rf "$_current_fixture"
    _current_fixture=""
  fi
}
trap 'cleanup_fixture' EXIT INT TERM

# make_fixture <source-fr-값(__NONE__=섹션 없음)> <fr상세파일 상대경로(__NONE__=생성 안 함)> <fr-status>
# hook 은 script_dir/../../.. 를 project_root 로 계산 → fixture/rd-workflow/scripts/hooks 에 배치.
# 종결된 final-diff-review 세션(short-title=t1)을 함께 구성해 enforcement 경로에 도달시킨다.
make_fixture() {
  local src_val="$1" fr_rel="$2" fr_status="$3"
  local fixture
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  cp "$HOOK_SOURCE" "$fixture/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON" "$fixture/rd-workflow/scripts/_state_common.sh"
  # 스캐너를 함께 복사한다. 누락하면 폴백 경로로 테스트되어 새 판정을 검사하지 못한다.
  [[ -f "$HOOK_DIR/_commit_scan.awk" ]] && cp "$HOOK_DIR/_commit_scan.awk" "$fixture/rd-workflow/scripts/hooks/"
  mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
  cat > "$fixture/rd-workflow-workspace/.lifecycle/task-state" <<'TSEOF'
schema=1
short-title=t1
status=diff review 대기
fr-branch=null
worktree-path=null
source-fr=-
TSEOF
  local sess="$fixture/rd-workflow-workspace/handoffs/review_pipeline/20260101_000000_final-diff-review"
  mkdir -p "$sess"
  printf '%s\n' "# Review Session" "" "## Status" "awaiting-user" "" "## Branch Context" "- short-title: t1" > "$sess/SESSION.md"
  printf '%s\n' "# Review Checkpoint" "" "## Open Issues" "- 없음" > "$sess/CHECKPOINT.md"
  if [[ "$src_val" == "__NONE__" ]]; then
    printf '%s\n' "# Change Request" "" "## Task Type" "change" > "$fixture/REQUEST.md"
  else
    printf '%s\n' "# Change Request" "" "## Source FR" "$src_val" > "$fixture/REQUEST.md"
  fi
  if [[ "$fr_rel" != "__NONE__" ]]; then
    mkdir -p "$fixture/$(dirname "$fr_rel")"
    printf '%s\n' "# fr item" "- status: $fr_status" > "$fixture/$fr_rel"
  fi
  printf '%s' "$fixture"
}

_hook_last_exit=0
_hook_last_err=""
run_hook() {
  local fixture="$1" cmd="${2:-git commit -m test}"   # 인자 없으면 현행 동작
  _hook_last_exit=0
  _hook_last_err="$(printf '{"tool_input":{"command":"%s"}}' "$cmd" | \
    bash "$fixture/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh" 2>&1 >/dev/null)" \
    || _hook_last_exit=$?
}

# run_scenario <num> <name> <source-fr값> <fr상세상대경로> <fr-status> <expected_exit> <expected_err_substr(-=검사안함)> [cmd]
run_scenario() {
  local num="$1" name="$2" src="$3" fr_rel="$4" fr_status="$5" expected="$6" err_sub="$7" cmd="${8:-}"
  local fixture
  fixture="$(make_fixture "$src" "$fr_rel" "$fr_status")"
  _current_fixture="$fixture"
  if [[ -n "$cmd" ]]; then run_hook "$fixture" "$cmd"; else run_hook "$fixture"; fi
  local ok=1
  [[ "$_hook_last_exit" == "$expected" ]] || ok=0
  if [[ "$err_sub" != "-" ]]; then
    case "$_hook_last_err" in *"$err_sub"*) ;; *) ok=0 ;; esac
  fi
  if [[ "$ok" == 1 ]]; then
    echo "[PASS] scenario ${num}: ${name} (exit=$_hook_last_exit)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] scenario ${num}: ${name} — expected exit=$expected actual=$_hook_last_exit err=[${_hook_last_err}]" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

ITEM="rd-workflow-workspace/backlog/items/2026-01-01-t1.md"

run_scenario 1 "백틱 path + status idea → 차단" \
  '`'"$ITEM"'`' "$ITEM" "idea" 2 "done/dropped 필요"
run_scenario 2 "백틱 path + status done → 통과" \
  '`'"$ITEM"'`' "$ITEM" "done" 0 "-"
run_scenario 3 "legacy slug + status idea → 차단" \
  "2026-01-01-t1" "$ITEM" "idea" 2 "done/dropped 필요"
run_scenario 4 "legacy slug + status dropped → 통과" \
  "2026-01-01-t1" "$ITEM" "dropped" 0 "-"
run_scenario 5 "Source FR '-' → 통과" \
  "-" "__NONE__" "-" 0 "-"
run_scenario 6 "Source FR 섹션 없음 → 통과" \
  "__NONE__" "__NONE__" "-" 0 "-"
run_scenario 7 "path + FR 파일 미존재 → 경고 + 통과" \
  '`rd-workflow-workspace/backlog/items/2026-01-01-none.md`' "__NONE__" "-" 0 "찾지 못했습니다"
run_scenario 8 "절대경로 → 경고 + 통과" \
  "/etc/passwd" "__NONE__" "-" 0 "형식 위반"
run_scenario 9 ".. 세그먼트 → 경고 + 통과" \
  "rd-workflow-workspace/backlog/items/../../evil.md" "__NONE__" "-" 0 "형식 위반"

# A1: 아카이브 신호 재료 충족 + 데이터 구간(홑따옴표)의 커밋 문자열 → 오탐 해소
run_scenario A1 "데이터 구간 커밋 문자열 → 통과(오탐 해소)" \
  '`'"$ITEM"'`' "$ITEM" "idea" 0 "-" \
  "echo '"'"'git commit -m x'"'"'"

# A2: 같은 fixture + 실제 커밋(-C 형태) → 기존 차단 동작 유지
#     현행 글롭은 git -C … commit 을 미탐으로 통과시켰다. 새 판정은 차단한다.
run_scenario A2 "git -C . 실제 커밋 → 차단 유지" \
  '`'"$ITEM"'`' "$ITEM" "idea" 2 "done/dropped 필요" \
  "git -C . commit -m x"

echo ""
echo "pre_commit_archive_gate: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]] && exit 0 || exit 1
