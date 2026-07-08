#!/bin/bash
# test_guard_state.sh — _guard_common.sh 판정 소스 전환 fixture 테스트
# task-state 존재/부재 × 판정 함수 3종 × 손상 시나리오
# macOS /bin/bash 3.2 호환 (globstar/extglob/연관배열 불사용)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
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
# Fixture 공통 생성 헬퍼
#   fixture 구조: fixture/rd-workflow/scripts/hooks/ (project_root = fixture)
# ---------------------------------------------------------------------------
make_base_fixture() {
  local fixture
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON"  "$fixture/rd-workflow/scripts/_state_common.sh"
  printf '%s' "$fixture"
}

# task-state 파일 쓰기 헬퍼
write_task_state() {
  local fixture="$1" status="$2" short_title="$3"
  local state_path="$fixture/rd-workflow-workspace/.lifecycle/task-state"
  cat > "$state_path" <<EOF
schema=1
short-title=${short_title}
status=${status}
fr-branch=null
worktree-path=null
source-fr=-
EOF
}

# CURRENT_TASK.md 작성 헬퍼
write_current_task() {
  local fixture="$1" status="$2" short_title="$3"
  cat > "$fixture/CURRENT_TASK.md" <<EOF
# Current Task

## Status
${status}

## Short Title
${short_title}
EOF
}

# active-fr 작성 헬퍼
write_active_fr() {
  local fixture="$1" short_title="$2"
  mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
  cat > "$fixture/rd-workflow-workspace/.lifecycle/active-fr" <<EOF
short-title=${short_title}
fr-branch=fr/${short_title}
worktree-path=/tmp/worktree-${short_title}
EOF
}

# ---------------------------------------------------------------------------
# 함수 실행 헬퍼: project_root 주입 후 함수 호출, stdout 반환
# ---------------------------------------------------------------------------
call_guard_fn() {
  local fixture="$1" fn_name="$2"
  # subshell에서 _guard_common.sh source 후 함수 호출
  # project_root를 주입하고, TASK_STATE_PATH도 fixture 경로로 고정
  (
    project_root="$fixture"
    export project_root
    export TASK_STATE_PATH="$fixture/rd-workflow-workspace/.lifecycle/task-state"
    # shellcheck source=/dev/null
    source "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
    "$fn_name"
  ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# assert 헬퍼
# ---------------------------------------------------------------------------
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected='$expected' actual='$actual'" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_fn_return() {
  local label="$1" fn_name="$2" fixture="$3" expected_rc="$4"
  local actual_rc=0
  (
    project_root="$fixture"
    export project_root
    export TASK_STATE_PATH="$fixture/rd-workflow-workspace/.lifecycle/task-state"
    source "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
    "$fn_name"
  ) 2>/dev/null || actual_rc=$?
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo "[PASS] $label (rc=$actual_rc)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected rc=$expected_rc actual rc=$actual_rc" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Fixture 1: task-state(status=구현 중) + CURRENT_TASK.md(Status=완료)
#   get_task_status = "구현 중" — task-state 우선, 뷰 무시 증명
# ---------------------------------------------------------------------------
echo "--- fixture 1: task-state 우선 (뷰 drift 무시) ---"
{
  f="$(make_base_fixture)"
  _current_fixture="$f"
  write_task_state "$f" "구현 중" "my-task"
  write_current_task "$f" "완료" "my-task"

  result="$(call_guard_fn "$f" "get_task_status")"
  assert_eq "fixture 1: task-state(구현 중) + 뷰(완료) → get_task_status='구현 중'" "구현 중" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 2: task-state 부재 + CURRENT_TASK.md(Status=구현 중)
#   get_task_status = "구현 중" — legacy fallback
# ---------------------------------------------------------------------------
echo "--- fixture 2: task-state 부재, legacy fallback ---"
{
  f="$(make_base_fixture)"
  _current_fixture="$f"
  # task-state 미생성
  write_current_task "$f" "구현 중" "legacy-task"

  result="$(call_guard_fn "$f" "get_task_status")"
  assert_eq "fixture 2: task-state 없음 + 뷰(구현 중) → get_task_status='구현 중'" "구현 중" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 3: task-state(short-title=foo) + active-fr(short-title=bar 잔존)
#   get_current_short_title = "foo" — task-state 우선
# ---------------------------------------------------------------------------
echo "--- fixture 3: short-title task-state 우선 (active-fr 비정상 잔존 무시) ---"
{
  f="$(make_base_fixture)"
  _current_fixture="$f"
  write_task_state "$f" "구현 중" "foo"
  write_current_task "$f" "구현 중" "foo"
  write_active_fr "$f" "bar"   # 비정상 잔존

  result="$(call_guard_fn "$f" "get_current_short_title")"
  assert_eq "fixture 3: task-state(short-title=foo) + active-fr(bar) → 'foo'" "foo" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 4: task-state 부재 + CURRENT_TASK.md Short Title '-' + active-fr(short-title=baz)
#   get_current_short_title = "baz" — legacy 체인 유지
# ---------------------------------------------------------------------------
echo "--- fixture 4: legacy 체인 (CURRENT_TASK '-' → active-fr fallback) ---"
{
  f="$(make_base_fixture)"
  _current_fixture="$f"
  write_current_task "$f" "구현 중" "-"
  write_active_fr "$f" "baz"

  result="$(call_guard_fn "$f" "get_current_short_title")"
  assert_eq "fixture 4: task-state 없음 + 뷰 '-' + active-fr(baz) → 'baz'" "baz" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 5: commit_has_archive_signal AS2 검증
#   5a: task-state(status=대기 중, short-title=-) → return 0 (archive 신호)
#   5b: task-state(status=구현 중) → return 1 (archive 신호 없음)
# ---------------------------------------------------------------------------
echo "--- fixture 5: commit_has_archive_signal AS2 ---"
{
  # 5a: 대기 중 + short-title=- → archive 신호 있음 (return 0)
  f="$(make_base_fixture)"
  _current_fixture="$f"
  write_task_state "$f" "대기 중" "-"
  write_current_task "$f" "대기 중" "-"
  # git repo 초기화 (commit_has_archive_signal이 git diff --cached 호출)
  git -C "$f" init -q 2>/dev/null
  git -C "$f" config user.email "test@test.com" 2>/dev/null
  git -C "$f" config user.name "Test" 2>/dev/null

  assert_fn_return "fixture 5a: task-state(대기 중, -) → archive 신호(return 0)" \
    "commit_has_archive_signal" "$f" "0"
  cleanup_fixture
}
{
  # 5b: 구현 중 → archive 신호 없음 (return 1)
  f="$(make_base_fixture)"
  _current_fixture="$f"
  write_task_state "$f" "구현 중" "some-task"
  write_current_task "$f" "구현 중" "some-task"
  git -C "$f" init -q 2>/dev/null
  git -C "$f" config user.email "test@test.com" 2>/dev/null
  git -C "$f" config user.name "Test" 2>/dev/null

  assert_fn_return "fixture 5b: task-state(구현 중) → archive 신호 없음(return 1)" \
    "commit_has_archive_signal" "$f" "1"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 6: 손상 task-state(status=이상한값)
#   get_task_status → 값 그대로 반환("이상한값")
#   is_nonblocking_status "이상한값" → return 1 (차단 대상)
# ---------------------------------------------------------------------------
echo "--- fixture 6: 손상 task-state — 값 반환 + 비차단 판정 ---"
{
  f="$(make_base_fixture)"
  _current_fixture="$f"
  write_task_state "$f" "이상한값" "some-task"
  write_current_task "$f" "구현 중" "some-task"  # 뷰와 달라도 task-state 우선

  # get_task_status는 "이상한값" 그대로 반환해야 함
  result="$(call_guard_fn "$f" "get_task_status")"
  assert_eq "fixture 6a: 손상 task-state(이상한값) → get_task_status='이상한값' 그대로 반환" "이상한값" "$result"

  # is_nonblocking_status "이상한값" → return 1 (차단 대상 = block)
  (
    project_root="$f"
    export project_root
    export TASK_STATE_PATH="$f/rd-workflow-workspace/.lifecycle/task-state"
    source "$f/rd-workflow/scripts/hooks/_guard_common.sh"
    is_nonblocking_status "이상한값"
  ) 2>/dev/null
  rc_nonblocking=$?
  if [[ "$rc_nonblocking" -eq 1 ]]; then
    echo "[PASS] fixture 6b: is_nonblocking_status('이상한값') = return 1(차단 대상)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] fixture 6b: is_nonblocking_status('이상한값') expected rc=1 actual rc=$rc_nonblocking" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 결과
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
