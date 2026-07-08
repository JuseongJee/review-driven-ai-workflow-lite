#!/bin/bash
# test_stop_task_save_reminder.sh — stop_task_save_reminder.sh 로직 격리 검증
# macOS /bin/bash 3.2 호환 (globstar/extglob/연관배열 불사용)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
HOOK_SOURCE="$HOOK_DIR/stop_task_save_reminder.sh"
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
#   hook은 script_dir/../../.. 를 project_root로 계산하므로
#   fixture/rd-workflow/scripts/hooks 에 두면 project_root = fixture가 된다.
#
#   인자:
#     $1: Status 값 ("__NONE__"이면 CURRENT_TASK.md 미생성)
#     $2: autopilot ("yes"이면 .autopilot_active 생성)
# ---------------------------------------------------------------------------
make_fixture() {
  local status="$1" autopilot="$2"
  local fixture
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  cp "$HOOK_SOURCE" "$fixture/rd-workflow/scripts/hooks/stop_task_save_reminder.sh"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON"  "$fixture/rd-workflow/scripts/_state_common.sh"

  if [[ "$status" != "__NONE__" ]]; then
    printf '%s\n' "# Current Task" "" "## Status" "$status" > "$fixture/CURRENT_TASK.md"
  fi
  if [[ "$autopilot" == "yes" ]]; then
    touch "$fixture/.autopilot_active"
  fi

  # git repo 초기화 (git ls-files를 위해 필수)
  git -C "$fixture" init -q
  git -C "$fixture" config user.email "test@test.com"
  git -C "$fixture" config user.name "Test"

  printf '%s' "$fixture"
}

# ---------------------------------------------------------------------------
# hook 실행: stdin JSON 주입 → stdout / exit code 캡처
# ---------------------------------------------------------------------------
_hook_last_exit=0
_hook_last_stdout=""
run_hook() {
  local fixture="$1" stdin_json="$2"
  _hook_last_exit=0
  _hook_last_stdout=""
  _hook_last_stdout="$(printf '%s' "$stdin_json" | \
    bash "$fixture/rd-workflow/scripts/hooks/stop_task_save_reminder.sh" 2>/dev/null)" \
    || _hook_last_exit=$?
}

# ---------------------------------------------------------------------------
# assert: stdout에 "decision":"block" 포함 여부 확인
# ---------------------------------------------------------------------------
assert_blocked() {
  local label="$1"
  if printf '%s' "$_hook_last_stdout" | grep -q '"decision":"block"'; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — block 신호 없음 (stdout='$_hook_last_stdout', exit=$_hook_last_exit)" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not_blocked() {
  local label="$1"
  if printf '%s' "$_hook_last_stdout" | grep -q '"decision":"block"'; then
    echo "[FAIL] $label — 예상치 못한 block (stdout='$_hook_last_stdout')" >&2
    FAIL=$((FAIL + 1))
  else
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
# 케이스 1: 진행 중 Status(구현 중) + stale → block
#   CURRENT_TASK.md를 오래된 시간으로, 코드 파일을 최신으로 설정
# ---------------------------------------------------------------------------
echo "--- 케이스 1: 진행 중 + stale → block ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  # CURRENT_TASK.md를 과거 시간으로 설정 (2025-01-01 00:00:00)
  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"

  # git에 추적 파일 추가 (src.sh = 코드 파일)
  printf '%s\n' "#!/bin/bash" "echo hello" > "$fixture/src.sh"
  git -C "$fixture" add "$fixture/CURRENT_TASK.md" "$fixture/src.sh"
  git -C "$fixture" commit -q -m "init"

  # src.sh를 현재 시간으로 갱신 (CURRENT_TASK.md보다 최신)
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_blocked "케이스 1: 진행 중 + stale → block"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 2: 대기 중 / 완료 / 빈 Status → block 없음
# ---------------------------------------------------------------------------
echo "--- 케이스 2: 비차단 Status → block 없음 ---"
for st in "대기 중" "완료" "__NONE__"; do
  fixture="$(make_fixture "$st" "no")"
  _current_fixture="$fixture"

  if [[ "$st" != "__NONE__" ]]; then
    touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"
  fi

  # 코드 파일 추가 (stale 조건 갖춤)
  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add . 2>/dev/null || true
  git -C "$fixture" commit -q -m "init" 2>/dev/null || true
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 2: Status='$st' → block 없음"
  cleanup_fixture
done

# ---------------------------------------------------------------------------
# 케이스 3: autopilot 활성 → block 없음
# ---------------------------------------------------------------------------
echo "--- 케이스 3: autopilot 활성 → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "yes")"
  _current_fixture="$fixture"

  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"
  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 3: autopilot 활성 → block 없음"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 4: stop_hook_active=true → block 없음 (무한루프 방지)
# ---------------------------------------------------------------------------
echo "--- 케이스 4: stop_hook_active=true → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"
  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":true}'
  assert_not_blocked "케이스 4: stop_hook_active=true → block 없음"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 5: 진행 중 + CURRENT_TASK.md가 추적 파일보다 최신 → block 없음
# ---------------------------------------------------------------------------
echo "--- 케이스 5: 진행 중 + not stale → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  # src.sh를 먼저 오래된 시간으로, CURRENT_TASK.md를 최신으로
  printf '%s\n' "code" > "$fixture/src.sh"
  touch -t 202501010000.00 "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"

  # CURRENT_TASK.md를 현재 시간으로 갱신 (src.sh보다 최신)
  sleep 2
  touch "$fixture/CURRENT_TASK.md"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 5: CURRENT_TASK.md가 더 최신 → block 없음"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 6: 진행 중 + rd-workflow-workspace/ 하위 파일만 최신 → block 없음
#   (산출물 파일은 stale 판정에서 제외되어야 함)
#   픽스처의 hook 파일(rd-workflow/scripts/hooks/)도 추적되므로
#   모든 파일을 과거 시간으로 설정한 뒤 rd-workflow-workspace/ 파일만 최신으로 만듦.
# ---------------------------------------------------------------------------
echo "--- 케이스 6: rd-workflow-workspace/ 만 최신 → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  mkdir -p "$fixture/rd-workflow-workspace/plans"

  # rd-workflow-workspace/ 하위 파일 (제외 대상)
  printf '%s\n' "plan content" > "$fixture/rd-workflow-workspace/plans/plan.md"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"

  # 추적 파일 전부 + CURRENT_TASK.md를 과거 시간으로 고정
  # (hook 파일 자체도 rd-workflow/ 하위로 추적되므로 함께 과거로 설정)
  _f6=""
  while IFS= read -r _f6; do
    [[ -z "$_f6" ]] && continue
    touch -t 202501010000.00 "$fixture/$_f6" 2>/dev/null || true
  done < <(git -C "$fixture" ls-files)
  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md" 2>/dev/null || true

  # rd-workflow-workspace/ 파일만 현재 시간으로 갱신
  sleep 2
  touch "$fixture/rd-workflow-workspace/plans/plan.md"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 6: rd-workflow-workspace/ 만 최신 → block 없음 (false positive 방지)"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 7: CURRENT_TASK.md 부재 → block 없음 (fail-open)
# ---------------------------------------------------------------------------
echo "--- 케이스 7: CURRENT_TASK.md 부재 → block 없음 ---"
{
  fixture="$(make_fixture "__NONE__" "no")"
  _current_fixture="$fixture"

  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 7: CURRENT_TASK.md 부재 → block 없음 (fail-open)"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 결과 출력
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
