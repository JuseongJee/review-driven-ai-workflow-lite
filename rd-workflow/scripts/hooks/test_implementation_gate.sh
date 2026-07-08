#!/bin/bash
# test_implementation_gate.sh — implementation_gate.sh 통과/차단 로직 격리 검증
# macOS /bin/bash 3.2 호환 (globstar/extglob 불사용)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
HOOK_SOURCE="$HOOK_DIR/implementation_gate.sh"
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

# ---------------------------------------------------------------------------
# Fixture 생성
#   $1: Status 값 ("__NONE__" 이면 CURRENT_TASK.md 생성 안 함 = 빈 status)
#   $2: autopilot ("yes" 이면 .autopilot_active 생성)
#   hook 은 script_dir/../../.. 를 project_root 로 계산하므로
#   fixture/rd-workflow/scripts/hooks 에 두면 project_root = fixture 가 된다.
# ---------------------------------------------------------------------------
make_fixture() {
  local status="$1" autopilot="$2"
  local fixture
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  cp "$HOOK_SOURCE" "$fixture/rd-workflow/scripts/hooks/implementation_gate.sh"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON"  "$fixture/rd-workflow/scripts/_state_common.sh"
  if [[ "$status" != "__NONE__" ]]; then
    printf '%s\n' "# Current Task" "" "## Status" "$status" > "$fixture/CURRENT_TASK.md"
  fi
  if [[ "$autopilot" == "yes" ]]; then
    touch "$fixture/.autopilot_active"
  fi
  printf '%s' "$fixture"
}

_hook_last_exit=0
run_hook() {
  local fixture="$1" file_path="$2"
  _hook_last_exit=0
  printf '%s' "{\"tool_input\":{\"file_path\":\"$file_path\"}}" | \
    bash "$fixture/rd-workflow/scripts/hooks/implementation_gate.sh" \
    >/dev/null 2>&1 || _hook_last_exit=$?
}

# ---------------------------------------------------------------------------
# 시나리오 실행
#   $1 num, $2 name, $3 status, $4 autopilot, $5 file_path 템플릿({F}=fixture), $6 expected_exit
# ---------------------------------------------------------------------------
run_scenario() {
  local num="$1" name="$2" status="$3" autopilot="$4" path_tmpl="$5" expected="$6"
  local fixture
  fixture="$(make_fixture "$status" "$autopilot")"
  _current_fixture="$fixture"
  local file_path="${path_tmpl//\{F\}/$fixture}"
  run_hook "$fixture" "$file_path"
  local label="scenario ${num}: ${name}"
  if [[ "$_hook_last_exit" == "$expected" ]]; then
    echo "[PASS] $label (exit=$_hook_last_exit)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected exit=$expected actual=$_hook_last_exit (fixture: $fixture)" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# project_root 밖 경로는 워크플로 단계와 무관하게 통과해야 한다 (FR 핵심)
run_scenario 1 "project_root 밖(plan) + 진행중 → 통과" \
  "검증 중" "no" "/outside/.claude/plans/x.md" 0
run_scenario 9 "project_root 밖(메모리) + 진행중 → 통과" \
  "diff review 대기" "no" "/Users/x/.claude/projects/p/memory/m.md" 0

# project_root 안 소스(화이트리스트 밖) + 진행중 → 차단 (회귀 방지)
run_scenario 2 "project_root 안 소스 + 진행중 → 차단" \
  "검증 중" "no" "{F}/rd-workflow/scripts/foo.sh" 2

# 대기 중 / 완료 / 빈 값 → 자유 수정 허용 (cfd356f drift fix)
run_scenario 3 "대기 중 + 소스 → 통과 (drift fix)" \
  "대기 중" "no" "{F}/rd-workflow/scripts/foo.sh" 0
run_scenario 4 "완료 + 소스 → 통과 (drift fix)" \
  "완료" "no" "{F}/rd-workflow/scripts/foo.sh" 0
run_scenario 10 "빈 Status + 소스 → 통과 (drift fix)" \
  "__NONE__" "no" "{F}/rd-workflow/scripts/foo.sh" 0

# 구현 중 / 실행 중 → 통과
run_scenario 5 "구현 중 + 소스 → 통과" \
  "구현 중" "no" "{F}/rd-workflow/scripts/foo.sh" 0

# 워크플로 화이트리스트 파일 + 진행중 → 통과
run_scenario 6 "워크플로 화이트리스트(CURRENT_TASK.md) + 진행중 → 통과" \
  "검증 중" "no" "{F}/CURRENT_TASK.md" 0

# autopilot 활성 → 진행중 + 소스라도 통과
run_scenario 7 "autopilot + 진행중 + 소스 → 통과" \
  "검증 중" "yes" "{F}/rd-workflow/scripts/foo.sh" 0

# 빈 file_path → 통과
run_scenario 8 "빈 file_path → 통과" \
  "검증 중" "no" "" 0

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
