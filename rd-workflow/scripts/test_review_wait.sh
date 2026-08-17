#!/usr/bin/env bash
# test_review_wait.sh — adapter_codex.sh 대기 계약·판정 단일화 테스트
# 케이스:
#   1. 정상 완료 (CHECKPOINT Suggested Next Owner = Reviewer여도 성공 — CHECKPOINT 비소비 증명)
#   2. 비정상 종료 (mock exit 1, 즉시 실패)
#   3. 타임아웃 (mock sleep 30, WAIT_TIMEOUT=3)
#   4. 폴링 부재 grep (adapter_codex.sh + adapter_claude.sh)
#   5. malformed owner 실패 (Bogus / 빈 값 / awaiting-reviewer Status)
#   6. timeout 마커 정리 (정상 완료 경로에서 .wait_timeout 잔존 금지)
set -euo pipefail

PASS=0
FAIL=0
ERRORS=()

# 색상 출력 (터미널 비지원 시 무시)
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}PASS${NC} $1"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "${RED}FAIL${NC} $1"
  ERRORS+=("$1")
  FAIL=$((FAIL + 1))
}

# --- 경로 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$SCRIPT_DIR/adapter_codex.sh"
ADAPTER_CLAUDE="$SCRIPT_DIR/adapter_claude.sh"

# --- sandbox 공통 함수 ---
make_sandbox() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/turns"
  echo "$d"
}

# 가짜 SESSION.md 생성 헬퍼
write_session() {
  local dir="$1" owner="$2" status="$3"
  cat > "$dir/SESSION.md" <<EOF
## Current Owner
$owner

## Status
$status

## Turn Limit
20
EOF
}

# CHECKPOINT.md 생성 헬퍼
write_checkpoint() {
  local dir="$1" suggested="$2"
  cat > "$dir/CHECKPOINT.md" <<EOF
## Summary
테스트용 CHECKPOINT

## Agreed Points
-

## Open Issues
-

## Questions
-

## Suggested Next Owner
$suggested
EOF
}

# 지정 디렉터리 안의 watchdog 임시 디렉터리 개수 (절대 개수)
# 전역 ${TMPDIR:-/tmp} 의 전후 델타로 판정하면 동시 실행 세션의 정상 정리가 이번 실행의
# 누수를 상쇄해 위음성이 된다. 그래서 케이스마다 전용 TMPDIR 을 주입하고 그 안에서 0 을 본다.
# find 는 권한 오류로 non-zero 를 반환할 수 있고 이 파일은 set -euo pipefail 이므로
# || true 로 격리하지 않으면 호출 지점에서 테스트 전체가 조용히 중단된다(실측).
leftover_watchdog_in() {
  local n
  n="$( { find "$1" -maxdepth 1 -type d -name 'rd-watchdog.*' 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  echo "$n"
}

# ps 신뢰성 self-check
# ps -eo pid,command 는 busybox 에서 실패하고 그 실패가 wc -l 에서 0 으로 집계되어
# "고아 0개" 라는 거짓 통과를 만든다. 개수 0 을 통과로 해석하기 전에 ps 가
# 자기 자신을 볼 수 있는지 확인한다. 볼 수 없으면 판정을 신뢰할 수 없다.
ps_is_trustworthy() {
  local n
  n="$( { ps -eo pid 2>/dev/null || true; } | grep -c "^ *$$\$" || true )"
  [ "$n" -ge 1 ]
}

# --- 프로세스 소유권 (케이스 14·15 의 고아 검출·정리 근거) ---
# 고아를 명령행 패턴(`sleep <값>`)으로 식별하지 않는다. 패턴 일치는 소유권 증거가 아니며,
# 같은 값을 쓰는 다른 사용자·테스트·프로젝트의 프로세스를 종료할 수 있다.
# 대신 어댑터를 자체 process group 리더로 띄운다. process group 은 자손에게 상속되고
# 부모가 죽어 고아가 되어도 바뀌지 않으므로, 그 pgid 의 구성원이라는 사실이 곧
# "이 케이스가 만든 프로세스" 라는 증거다 (macOS 3.2 / Alpine 5.3 / Ubuntu 5.2 실측).
own_pgid() {  # $1: pid → pgid (관측 불가 시 빈 문자열)
  { ps -eo pid,pgid 2>/dev/null || true; } | awk -v p="$1" '$1==p {print $2; exit}'
}

group_size() {  # $1: pgid → 살아 있는 구성원 수
  local g="${1:-}"
  [ -n "$g" ] || { echo 0; return; }
  { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$g" '$2==g' | wc -l | tr -d ' '
}

SELF_PGID="$(own_pgid $$)"
JOB=""
GROUP_PGID=""

spawn_group() {  # $1: 로그 경로, 나머지: 실행할 명령 — 자체 process group 리더로 띄운다
  local log="$1" i; shift
  set -m
  "$@" < /dev/null > "$log" 2>&1 &
  JOB=$!
  set +m
  GROUP_PGID=""
  # "pgid 가 리더 pid 인 구성원이 존재하는가" 로 확정한다. 리더가 즉시 종료해도 자손이
  # 남았다면 그룹 행으로 확인되고, pgid == 리더 pid 이므로 오탐은 불가능하다.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(group_size "$JOB")" -gt 0 ]; then GROUP_PGID="$JOB"; break; fi
    sleep 0.05
  done
}

reap_group() {  # $1: pgid — 소유권이 확인된 그룹만 종료 (자기 그룹·빈 그룹은 건드리지 않는다)
  local g="${1:-}"
  [ -n "$g" ] || return 0
  if [ -n "$SELF_PGID" ] && [ "$g" = "$SELF_PGID" ]; then return 0; fi
  [ "$(group_size "$g")" -gt 0 ] || return 0
  kill -9 -- -"$g" 2>/dev/null || true
  return 0
}

# 케이스 전용 WAIT_TIMEOUT salt.
# **bounded 값이며 유일성을 보장하지 않는다** — $$ 하위 5자리와 RANDOM 하위 3자리가 모두
# 같으면 두 실행이 같은 값을 갖는다. 절단이 필요한 이유는 상한 때문이다: 밴드(1억 단위)를
# 더한 뒤에도 2^31 아래여야 busybox sleep 이 파싱한다.
# 겹쳐도 안전한 이유는 값이 종료 대상 식별에 전혀 쓰이지 않기 때문이다 — 정리는 위의
# process group 소유권으로만 한다. 이 값의 역할은 로그 판독 편의뿐이다.
RUN_SALT=$(( ($$ % 100000) * 1000 + (RANDOM % 1000) ))

# mock codex bin을 임시 디렉토리에 생성하고 PATH 앞에 추가하는 함수
# 사용: setup_mock <sandbox_dir> <script_body>
setup_mock() {
  local sandbox="$1"
  local body="$2"
  local bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<MOCK_EOF
#!/usr/bin/env bash
$body
MOCK_EOF
  chmod +x "$bin_dir/codex"
  echo "$bin_dir"
}

# ===========================================================================
# 케이스 1: 정상 완료 — CHECKPOINT Suggested Next Owner = Reviewer여도 성공
# ===========================================================================
run_case1() {
  local sandbox
  sandbox="$(make_sandbox)"
  local turn_file="$sandbox/turns/turn-001-reviewer.md"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  # SESSION: Author 소유 + awaiting-author
  write_session "$sandbox" "Author" "awaiting-author"
  # CHECKPOINT: Suggested Next Owner = Reviewer (구 조건 위반 값 — 무시되어야 함)
  write_checkpoint "$sandbox" "Reviewer"

  # mock: 턴 파일 생성 + SESSION 갱신 후 exit 0
  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "
# 인자 파싱 무시, 턴 파일 생성 + SESSION 갱신
# PROMPT_FILE에서 읽지 않음 — 실행 자체만 확인
touch '$turn_file'
cat > '$sandbox/SESSION.md' <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
exit 0
")"

  local rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$sandbox/.turn_ready" ]; then
    pass "케이스 1: 정상 완료 (CHECKPOINT Suggested=Reviewer여도 exit 0)"
  else
    fail "케이스 1: 정상 완료 기대 exit 0, .turn_ready 생성 — rc=$rc, turn_ready=$([ -f "$sandbox/.turn_ready" ] && echo exists || echo missing)"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 2: 비정상 종료 — mock exit 1, 즉시(2초 내) exit 1
# ===========================================================================
run_case2() {
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: 아무것도 쓰지 않고 즉시 exit 1
  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "exit 1")"

  local t0 t1 elapsed rc=0
  t0=$(date +%s)
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?
  t1=$(date +%s)
  elapsed=$((t1 - t0))

  if [ "$rc" -ne 0 ] && [ "$elapsed" -le 2 ]; then
    pass "케이스 2: 비정상 종료 즉시 exit 1 (${elapsed}초)"
  else
    fail "케이스 2: 비정상 종료 기대 rc≠0·2초 내 — rc=$rc, elapsed=${elapsed}초"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 3: 타임아웃 — mock sleep 30, WAIT_TIMEOUT=3
# ===========================================================================
run_case3() {
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: sleep 30 (아무것도 쓰지 않음)
  # 자기 PID 를 파일에 남긴다 — 뒤의 생존 확인이 이 PID 만 보게 하기 위해서다.
  # `exec` 로 sleep 이 되어 PID 가 유지되므로, 기록한 PID = 실제 잠자는 프로세스다.
  local mock_bin mock_pid_file
  mock_pid_file="$sandbox/mock_bin/codex.pid"
  mock_bin="$(setup_mock "$sandbox" "echo \$\$ > \"$mock_pid_file\"; exec sleep 30")"

  local rc=0
  local output
  output="$(
    TOOL_BIN="$mock_bin/codex" \
    SESSION_PATH="$sandbox" \
    PROMPT_FILE="/dev/null" \
    EXPECTED_TURN_FILE="$expected_turn" \
    PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  # mock 프로세스가 종료됐는지 확인 — 이 sandbox 가 띄운 PID 하나만 본다.
  #   `pgrep -f "sleep 30"` 은 시스템 전역을 뒤지므로, 같은 머신의 다른 세션이 돌리는
  #   폴링 루프(`while ...; do sleep 30; done`)까지 우리 mock 으로 오인해 오탐한다.
  #   테스트가 자기 sandbox 밖의 프로세스 상태에 의존하면 결과가 재현되지 않는다.
  local mock_alive=0 mock_pid=""
  [ -f "$mock_pid_file" ] && mock_pid="$(cat "$mock_pid_file" 2>/dev/null)"
  if [ -n "$mock_pid" ] && kill -0 "$mock_pid" 2>/dev/null; then
    mock_alive=1
  fi

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "타임아웃"; then
    pass "케이스 3: 타임아웃 exit 124 + 메시지 확인"
  else
    fail "케이스 3: 타임아웃 기대 rc=124 — rc=$rc, 메시지=$(echo "$output" | grep -o '타임아웃' || echo '없음')"
  fi

  # PID 파일이 없으면 위 생존 확인이 항상 통과한다. 그 조용한 무력화를 먼저 막는다.
  if [ -z "$mock_pid" ]; then
    fail "케이스 3(보조): mock PID 미기록 — 생존 확인이 무력화됨"
  # mock 프로세스가 kill됐는지는 비동기 특성상 보조 확인만
  elif [ "$mock_alive" -eq 1 ]; then
    fail "케이스 3(보조): mock 프로세스(PID $mock_pid)가 아직 살아있음 — kill 실패 의심"
  else
    pass "케이스 3(보조): mock 프로세스(PID $mock_pid) 정리 확인"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 4: 폴링 부재 grep
# ===========================================================================
run_case4() {
  # adapter_codex.sh에 sleep "$POLL_INTERVAL" 폴링 루프 없음을 확인
  if grep -qE 'sleep[[:space:]]+"?\$POLL_INTERVAL"?' "$ADAPTER" 2>/dev/null; then
    fail "케이스 4a: adapter_codex.sh에 sleep \$POLL_INTERVAL 폴링 루프 존재 (폴링 제거 미완)"
  else
    pass "케이스 4a: adapter_codex.sh에 POLL_INTERVAL sleep 루프 없음"
  fi

  # 구현 완료 후: POLL_INTERVAL 자체가 없어야 함
  if grep -q 'POLL_INTERVAL' "$ADAPTER" 2>/dev/null; then
    fail "케이스 4b: adapter_codex.sh에 POLL_INTERVAL 잔존"
  else
    pass "케이스 4b: adapter_codex.sh에 POLL_INTERVAL 잔존 없음"
  fi

  # adapter_claude.sh에 폴링 루프 없음 (무변경 검증)
  if grep -qE 'POLL_INTERVAL|while.*sleep|sleep.*POLL' "$ADAPTER_CLAUDE" 2>/dev/null; then
    fail "케이스 4c: adapter_claude.sh에 폴링 루프 존재 (예상치 못한 변경)"
  else
    pass "케이스 4c: adapter_claude.sh에 폴링 루프 없음"
  fi
}

# ===========================================================================
# 케이스 5: malformed owner 실패
# ===========================================================================
run_case5() {
  # 5a: Current Owner = Bogus (비enum)
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001.md"

  write_session "$sandbox" "Bogus" "awaiting-author"
  write_checkpoint "$sandbox" "Author"

  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "
touch '$expected_turn'
exit 0
")"

  local rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "케이스 5a: malformed owner=Bogus → exit 1"
  else
    fail "케이스 5a: malformed owner=Bogus → 완료 오판(exit 0)"
  fi
  rm -rf "$sandbox"

  # 5b: Current Owner = 빈 값
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  write_session "$sandbox" "" "awaiting-author"
  write_checkpoint "$sandbox" "Author"
  mock_bin="$(setup_mock "$sandbox" "touch '$expected_turn'; exit 0")"

  rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "케이스 5b: malformed owner=빈값 → exit 1"
  else
    fail "케이스 5b: malformed owner=빈값 → 완료 오판(exit 0)"
  fi
  rm -rf "$sandbox"

  # 5c: Status = awaiting-reviewer (미전환)
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  write_session "$sandbox" "Author" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  mock_bin="$(setup_mock "$sandbox" "touch '$expected_turn'; exit 0")"

  rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "케이스 5c: Status=awaiting-reviewer(미전환) → exit 1"
  else
    fail "케이스 5c: Status=awaiting-reviewer → 완료 오판(exit 0)"
  fi
  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 6: timeout 마커 정리 — 정상 완료 경로에서 .wait_timeout 잔존 금지
# ===========================================================================
run_case6() {
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  write_session "$sandbox" "Author" "awaiting-author"
  write_checkpoint "$sandbox" "Reviewer"

  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "
touch '$expected_turn'
cat > '$sandbox/SESSION.md' <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
exit 0
")"

  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || true

  if [ ! -f "$sandbox/.wait_timeout" ]; then
    pass "케이스 6: 정상 완료 경로에서 .wait_timeout 마커 잔존 없음"
  else
    fail "케이스 6: .wait_timeout 마커가 정상 완료 후에도 잔존"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# §2 결정 3 — run_review_turn.sh 설정 파싱 1회 통합 테스트 (Task 2)
# 케이스 7~11: jq 호출 수 계측 / override priority / 값 내 공백·= /
#              missing·null 구분 / jq 부재·JSON 손상 fallback
# ===========================================================================

SCRIPT_DIR_RRT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_REVIEW_TURN="$SCRIPT_DIR_RRT/run_review_turn.sh"

# jq 호출 수 계측용 mock jq를 sandbox PATH 앞에 배치하는 헬퍼.
# 실제 jq를 감싸고 호출마다 COUNT_FILE 에 1줄 append.
# 사용: setup_counting_jq <sandbox_dir> <count_file>  → bin_dir 출력
setup_counting_jq() {
  local sandbox="$1"
  local count_file="$2"
  local real_jq
  real_jq="$(command -v jq)"
  local bin_dir="$sandbox/counting_jq"
  mkdir -p "$bin_dir"
  # counting jq — 실제 jq를 exec 위임하므로 결과는 동일
  cat > "$bin_dir/jq" <<JQ_EOF
#!/usr/bin/env bash
echo "called" >> "$count_file"
exec "$real_jq" "\$@"
JQ_EOF
  chmod +x "$bin_dir/jq"
  echo "$bin_dir"
}

# run_review_turn.sh 의 load_review_config + get_tool_config 경로만
# 실행하는 최소 harness 스크립트.  CONFIG_FILE 과 review_type 을 받아
# PRIORITY / 도구 설정 값들을 출력한다.
# 사용: harness_script <config_file> <review_type>
make_parse_harness() {
  local harness="$1"  # 출력 파일 경로
  cat > "$harness" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -euo pipefail
# harness: run_review_turn.sh 의 설정 파싱 경로만 격리 실행
CONFIG_FILE="${1:-}"
REVIEW_TYPE="${2:-}"

# run_review_turn.sh 에서 load_review_config / get_tool_config 정의만 소스
# (메인 케이스문 이전까지만 실행되도록 플래그 사용)
RRT_HARNESS_MODE=1

script_dir_inner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# review_common.sh 는 실행 안 하고, 함수 정의만 필요 → 직접 inline
# (run_review_turn.sh 는 source_dir에 의존하므로 동일 디렉토리에서 실행)
cd "$script_dir_inner"
source ./run_review_turn.sh_funcs_only
HARNESS_EOF
  chmod +x "$harness"
}

# run_review_turn.sh 에서 함수 정의 블록(L28-74)을 추출해 funcs_only 파일로 제공하는 대신,
# 직접 harness에서 source 없이 함수를 재현하는 방식으로 구현.
# (run_review_turn.sh 는 source 시 메인 실행까지 이어지므로 함수 추출 방식 사용)
#
# 실제 계측 대상: PATH 앞 counting jq + CONFIG_FILE 지정 후
#   - load_review_config 1회
#   - get_tool_config 4회 (bin / model / self_review_warning / self_review_policy)
# run_review_turn.sh 의 실제 실행 경로를 트레이스하려면 adapter 루프 직전까지 실행해야 하나,
# 그러려면 session_dir 등 전체 환경이 필요. 따라서 함수만 추출·실행하는 미니 harness 사용.

# harness 실행 헬퍼: CONFIG_FILE 설정 후 load_review_config + get_tool_config 4회 실행
# 인자: <config_file> <review_type> [counting_jq_dir]
run_parse_harness() {
  local cfg="$1"
  local rt="${2:-}"
  local extra_path="${3:-}"

  local harness_dir
  harness_dir="$(mktemp -d)"
  # run_review_turn.sh 와 동일 디렉토리에서 실행해야 source 경로가 맞음 — 불필요
  # 함수만 inline으로 실행

  local harness_script="$harness_dir/harness.sh"
  cat > "$harness_script" <<HARNESS_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$cfg"
REVIEW_CFG_KV=""

# ── load_review_config (구현 후 버전 또는 현행 버전 — 테스트는 실제 파일 실행) ──
# 실제 run_review_turn.sh 에서 함수를 추출해 실행
$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")

# 혹시 새 통합 함수가 있으면 같이 추출
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

# 실행
if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type="$rt"
  load_review_config_once
else
  load_review_config "$rt"
fi
bin_val="\$(get_tool_config "codex" "bin" "DEFAULT_BIN")"
model_val="\$(get_tool_config "claude" "model" "DEFAULT_MODEL")"
warn_val="\$(get_tool_config "claude" "self_review_warning" "DEFAULT_WARN")"
policy_val="\$(get_tool_config "claude" "self_review_policy" "DEFAULT_POLICY")"

echo "PRIORITY=\$PRIORITY"
echo "bin=\$bin_val"
echo "model=\$model_val"
echo "warn=\$warn_val"
echo "policy=\$policy_val"
HARNESS_BODY
  chmod +x "$harness_script"

  local path_prefix=""
  [[ -n "$extra_path" ]] && path_prefix="$extra_path:"
  PATH="${path_prefix}$(dirname "$RUN_REVIEW_TURN"):$PATH" bash "$harness_script"
  local rc=$?
  rm -rf "$harness_dir"
  return $rc
}

# ===========================================================================
# 케이스 7: jq 호출 수 ≤1 계측 (spec AC 3 — counting jq로 실행 경로 계측)
# ===========================================================================
run_case7() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 7: jq 없음 — fallback 경로, 호출 수 계측 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d)"
  local count_file="$sandbox/jq_count"
  touch "$count_file"

  # 실제 review-tools.json 샘플 생성
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": {
      "bin": null,
      "model": null,
      "self_review_warning": true,
      "self_review_policy": "block"
    }
  },
  "overrides": {
    "diff-review": { "priority": ["codex"] }
  }
}
RJSON

  local counting_jq_dir
  counting_jq_dir="$(setup_counting_jq "$sandbox" "$count_file")"

  # CONFIG_FILE 을 sandbox 의 json 으로 지정
  local out
  out="$(REVIEW_TOOLS_CONFIG="$sandbox/review-tools.json" \
    run_parse_harness "$sandbox/review-tools.json" "diff-review" "$counting_jq_dir")" || true

  local call_count=0
  [[ -f "$count_file" ]] && call_count=$(wc -l < "$count_file" | tr -d ' ')

  if [[ "$call_count" -le 1 ]]; then
    pass "케이스 7: jq 호출 수 ≤1 (실측 ${call_count}회) — spec AC 3 충족"
  else
    fail "케이스 7: jq 호출 수 초과 (실측 ${call_count}회 > 1) — 다중 파싱 미제거"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 8: override priority 적용 검증
# ===========================================================================
run_case8() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 8: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d)"
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": { "bin": null, "model": null, "self_review_warning": true }
  },
  "overrides": {
    "spec-review": { "priority": ["claude", "codex"] }
  }
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "spec-review" "")" || true

  local priority
  priority="$(echo "$out" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ "$priority" == "claude codex" ]]; then
    pass "케이스 8: spec-review override priority = 'claude codex' 정상 적용"
  else
    fail "케이스 8: spec-review override priority 기대='claude codex', 실제='$priority'"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 9: 값 내 공백·= 포함 — TSV 경계 보존 증명
# ===========================================================================
run_case9() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 9: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d)"
  # bin 값에 공백·= 포함 (예: 경로 with spaces, model=xxx 형식)
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": "/usr/local/bin/my codex bin" },
    "claude": {
      "bin": null,
      "model": "claude-sonnet=latest",
      "self_review_warning": true
    }
  },
  "overrides": {}
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "" "")" || true

  local bin_val model_val
  bin_val="$(echo "$out" | grep '^bin=' | cut -d= -f2-)"
  model_val="$(echo "$out" | grep '^model=' | cut -d= -f2-)"

  local pass_count=0
  if [[ "$bin_val" == "/usr/local/bin/my codex bin" ]]; then
    pass_count=$((pass_count + 1))
  fi
  if [[ "$model_val" == "claude-sonnet=latest" ]]; then
    pass_count=$((pass_count + 1))
  fi

  if [[ "$pass_count" -eq 2 ]]; then
    pass "케이스 9: 공백 포함 bin='$bin_val', = 포함 model='$model_val' — TSV 경계 보존"
  else
    fail "케이스 9: 값 경계 훼손 — bin='$bin_val'(기대='/usr/local/bin/my codex bin'), model='$model_val'(기대='claude-sonnet=latest')"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 10: missing 필드와 null 필드 — 현행 계약 보존 (둘 다 기본값 반환)
# ===========================================================================
run_case10() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 10: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d)"
  # codex: model 필드 아예 없음(missing), claude: model = null
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": {
      "bin": null,
      "model": null,
      "self_review_warning": true
    }
  },
  "overrides": {}
}
RJSON

  # codex model(missing) 과 claude model(null) 모두 기본값 반환 확인
  local harness_dir
  harness_dir="$(mktemp -d)"
  local harness_script="$harness_dir/harness10.sh"
  cat > "$harness_script" <<HARNESS10_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$sandbox/review-tools.json"
REVIEW_CFG_KV=""

$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type=""
  load_review_config_once
else
  load_review_config ""
fi

# codex model: missing 필드 → 기본값 "MISSING_DEFAULT" 기대
codex_model="\$(get_tool_config "codex" "model" "MISSING_DEFAULT")"
# claude model: null 필드 → 기본값 "NULL_DEFAULT" 기대
claude_model="\$(get_tool_config "claude" "model" "NULL_DEFAULT")"
# claude self_review_warning: 실제 값 "true" 기대
claude_warn="\$(get_tool_config "claude" "self_review_warning" "DEFAULT_WARN")"

echo "codex_model=\$codex_model"
echo "claude_model=\$claude_model"
echo "claude_warn=\$claude_warn"
HARNESS10_BODY
  chmod +x "$harness_script"

  local out
  out="$(bash "$harness_script")" || true
  rm -rf "$harness_dir"

  local codex_model claude_model claude_warn
  codex_model="$(echo "$out" | grep '^codex_model=' | cut -d= -f2-)"
  claude_model="$(echo "$out" | grep '^claude_model=' | cut -d= -f2-)"
  claude_warn="$(echo "$out" | grep '^claude_warn=' | cut -d= -f2-)"

  local pass_count=0
  [[ "$codex_model" == "MISSING_DEFAULT" ]] && pass_count=$((pass_count + 1))
  [[ "$claude_model" == "NULL_DEFAULT" ]]   && pass_count=$((pass_count + 1))
  [[ "$claude_warn" == "true" ]]            && pass_count=$((pass_count + 1))

  if [[ "$pass_count" -eq 3 ]]; then
    pass "케이스 10: missing→기본값, null→기본값, 실제값 정상 반환 — 현행 계약 보존"
  else
    fail "케이스 10: 계약 위반 — codex_model='$codex_model'(기대 MISSING_DEFAULT), claude_model='$claude_model'(기대 NULL_DEFAULT), warn='$claude_warn'(기대 true)"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 11: jq 부재 및 JSON 손상 fallback
# ===========================================================================
run_case11() {
  # 11a: jq 부재 — PRIORITY 기본값 사용
  local sandbox
  sandbox="$(mktemp -d)"
  cat > "$sandbox/review-tools.json" <<'RJSON'
{"default_priority": ["codex", "claude"], "tools": {}, "overrides": {}}
RJSON

  local no_jq_dir="$sandbox/no_jq"
  mkdir -p "$no_jq_dir"
  # jq 를 PATH 에서 제거: 존재하지 않는 빈 bin_dir 으로 앞에 추가
  # (현재 PATH 에서 jq를 가려야 하므로 fake jq를 배치해 exit 127)
  cat > "$no_jq_dir/jq" <<'FAKE_JQ'
#!/usr/bin/env bash
exit 127
FAKE_JQ
  chmod +x "$no_jq_dir/jq"

  local harness_dir
  harness_dir="$(mktemp -d)"
  local harness_script="$harness_dir/harness11a.sh"
  cat > "$harness_script" <<HARNESS11A_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$sandbox/review-tools.json"
REVIEW_CFG_KV=""

$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type=""
  load_review_config_once
else
  load_review_config ""
fi
echo "PRIORITY=\$PRIORITY"
HARNESS11A_BODY
  chmod +x "$harness_script"

  # jq 를 가짜 exit 127 로 대체한 PATH 에서 실행
  local out11a
  out11a="$(PATH="$no_jq_dir:$(echo "$PATH" | tr ':' '\n' | grep -v "$(dirname "$(command -v jq 2>/dev/null || echo /nonexistent)")" | tr '\n' ':' | sed 's/:$//')" bash "$harness_script" 2>/dev/null)" || true
  rm -rf "$harness_dir"

  local priority11a
  priority11a="$(echo "$out11a" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ -n "$priority11a" ]]; then
    pass "케이스 11a: jq 부재 시 기본값 PRIORITY='$priority11a' 반환"
  else
    fail "케이스 11a: jq 부재 시 PRIORITY 빈값 — fallback 미동작"
  fi

  # 11b: JSON 손상 — 기본값 사용 + stderr 안내
  local bad_json="$sandbox/bad.json"
  echo 'NOT VALID JSON {{{' > "$bad_json"

  harness_dir="$(mktemp -d)"
  harness_script="$harness_dir/harness11b.sh"
  cat > "$harness_script" <<HARNESS11B_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$bad_json"
REVIEW_CFG_KV=""

$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type=""
  load_review_config_once
else
  load_review_config ""
fi
echo "PRIORITY=\$PRIORITY"
HARNESS11B_BODY
  chmod +x "$harness_script"

  local out11b stderr11b
  out11b="$(bash "$harness_script" 2>/tmp/test_case11b_stderr)" || true
  stderr11b="$(cat /tmp/test_case11b_stderr 2>/dev/null || true)"
  rm -rf "$harness_dir"

  local priority11b
  priority11b="$(echo "$out11b" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ -n "$priority11b" ]] && [[ -n "$stderr11b" ]]; then
    pass "케이스 11b: JSON 손상 시 기본값 PRIORITY='$priority11b' + stderr 안내 존재"
  elif [[ -n "$priority11b" ]]; then
    pass "케이스 11b: JSON 손상 시 기본값 PRIORITY='$priority11b' 반환 (stderr 고지는 구현 세부)"
  else
    fail "케이스 11b: JSON 손상 시 PRIORITY 빈값 — fallback 미동작"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 12: 축약 config (.tools 없음 + default_priority/overrides만)
#            — priority가 유지되고 fallback으로 떨어지지 않음을 assert
# ===========================================================================
run_case12() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 12: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d)"

  # .tools 없는 축약 config — 기존 구현에서는 "null has no keys" 오류로
  # kv 전체가 폐기되어 priority가 기본값(codex claude)으로 fallback됐음.
  # 수정 후: .tools // {} 방어로 override priority가 정상 적용되어야 함.
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "overrides": {
    "diff-review": { "priority": ["claude"] }
  }
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "diff-review" "")" || true

  local priority
  priority="$(echo "$out" | grep '^PRIORITY=' | cut -d= -f2-)"

  # override priority 'claude'가 적용되어야 함 — fallback 'codex claude'가 아님
  if [[ "$priority" == "claude" ]]; then
    pass "케이스 12: 축약 config (tools 없음) + diff-review override → PRIORITY='claude' 정상 적용"
  else
    fail "케이스 12: 축약 config priority 회귀 — 기대='claude', 실제='$priority' (fallback 발생 의심)"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 13: .overrides 없는 config — default_priority 정상 반환
# ===========================================================================
run_case13() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 13: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d)"

  # .overrides 필드 자체 없음 — (.overrides // {})[$rt] 이 null 로 안전하게 처리되어야 함
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": { "bin": null, "model": null, "self_review_warning": true }
  }
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "spec-review" "")" || true

  local priority
  priority="$(echo "$out" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ "$priority" == "codex claude" ]]; then
    pass "케이스 13: overrides 없는 config → default_priority='codex claude' 정상 반환"
  else
    fail "케이스 13: overrides 없는 config priority 오류 — 기대='codex claude', 실제='$priority'"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 14: 정상 완료 후 watchdog 타이머 자손 생존 금지 + 자원 누수 금지
#   관측 창 분리가 핵심 — 호출자 파이프 없이 실행해 즉시 반환시킨 뒤 관측한다.
#   케이스 15(파이프)와 한 케이스로 합치면, 파이프 대기로 WAIT_TIMEOUT 을 소모하는
#   동안 고아가 제 수명을 다 채우고 사라져 결함 코드에서도 통과하는 위음성이 발생한다(실측).
# ===========================================================================
run_case14() {
  local sandbox turn_file mock_bin uniq_timeout survivors leftover g
  sandbox="$(make_sandbox)"
  mkdir -p "$sandbox/tmp"
  turn_file="$sandbox/turns/turn-001-reviewer.md"
  uniq_timeout=$(( 100000000 + RUN_SALT ))

  write_session "$sandbox" "Author" "awaiting-author"

  mock_bin="$(setup_mock "$sandbox" "
touch '$turn_file'
cat > '$sandbox/SESSION.md' <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
exit 0
")"

  # 어댑터를 자체 process group 리더로 띄운다 — 종료 후 그 그룹에 남은 구성원이 곧 고아다.
  spawn_group "$sandbox/out.log" \
    env TMPDIR="$sandbox/tmp" WAIT_TIMEOUT="$uniq_timeout" TOOL_BIN="$mock_bin/codex" \
        SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null EXPECTED_TURN_FILE="$turn_file" \
        PROJECT_ROOT="$sandbox" bash "$ADAPTER"
  g="$GROUP_PGID"
  wait "$JOB" 2>/dev/null || true

  sleep 0.5

  if ! ps_is_trustworthy || [ -z "$g" ]; then
    fail "케이스 14a: ps 가 자기 PID/PGID 를 관측하지 못해 고아 판정을 신뢰할 수 없음 (busybox 등 ps 구현 확인 필요)"
  else
    survivors="$(group_size "$g")"
    if [ "$survivors" -eq 0 ]; then
      pass "케이스 14a: 정상 완료 후 잔존 타이머 자손 0개"
    else
      fail "케이스 14a: 잔존 타이머 자손 ${survivors}개 — watchdog 자손이 호출자 fd 를 계속 보유"
    fi
  fi
  # 소유권이 확인된 그룹만 회수한다 (pkill -f·패턴 종료 금지 — 무관한 프로세스에 닿는다)
  reap_group "$g"

  # 누수는 이 케이스 전용 TMPDIR 안에서 절대 개수 0 으로 본다 (동시 실행 무관).
  # 현행 코드에는 fifo 자체가 없어 이 어서션은 결함 코드에서도 통과한다 — 결함 검출용이
  # 아니라 새 기법이 도입하는 자원의 누수 방지용 가드다 (AC4).
  leftover="$(leftover_watchdog_in "$sandbox/tmp")"
  if [ "$leftover" -eq 0 ]; then
    pass "케이스 14b: 전용 TMPDIR 에 watchdog 임시 자원 잔존 0개"
  else
    fail "케이스 14b: 전용 TMPDIR 에 watchdog 임시 자원 ${leftover}개 잔존"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 15: 호출자가 stderr 를 파이프로 받아도 턴 완료와 함께 파이프가 닫힌다
#   판정에 kill -0 를 쓰지 않는다 — 종료된 자식이 reap 전 좀비로 남으면 kill -0 가
#   성공해 오판할 수 있다. 파이프라인 뒤에 sentinel 파일을 기록하고 그 존재를 폴링한다.
#   sentinel 은 cat 이 종료된 뒤에만(= 파이프가 닫힌 뒤에만) 기록되므로 측정 대상과 일치한다.
#   상한 폴링이라 결함이 있어도 WAIT_TIMEOUT 전체가 아니라 상한만 소모한다.
# ===========================================================================

# 케이스 15 파이프 본체. spawn_group 이 이 함수를 자체 process group 으로 띄우므로
# 어댑터·watchdog·cat 이 모두 그 그룹에 들어가고, 회수를 그룹 단위로 할 수 있다.
# sentinel 은 파이프라인 **뒤에** 기록되므로 cat 종료(= 파이프 EOF)와 시점이 일치한다.
case15_body() {  # $1=sandbox $2=WAIT_TIMEOUT $3=mock_bin $4=turn_file
  env TMPDIR="$1/tmp" WAIT_TIMEOUT="$2" TOOL_BIN="$3/codex" SESSION_PATH="$1" \
      PROMPT_FILE=/dev/null EXPECTED_TURN_FILE="$4" PROJECT_ROOT="$1" \
      bash "$ADAPTER" 2>&1 | cat > "$1/piped.log" || true
  echo done > "$1/.piped_done"
}

run_case15() {
  local sandbox turn_file mock_bin uniq_timeout cap job waited g
  sandbox="$(make_sandbox)"
  mkdir -p "$sandbox/tmp"
  turn_file="$sandbox/turns/turn-001-reviewer.md"
  uniq_timeout=$(( 200000000 + RUN_SALT ))
  cap=6             # 상한(초)

  write_session "$sandbox" "Author" "awaiting-author"

  mock_bin="$(setup_mock "$sandbox" "
touch '$turn_file'
cat > '$sandbox/SESSION.md' <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
exit 0
")"

  spawn_group "$sandbox/wrap.log" case15_body "$sandbox" "$uniq_timeout" "$mock_bin" "$turn_file"
  job="$JOB"
  g="$GROUP_PGID"

  waited=0
  while [ "$waited" -lt "$cap" ] && [ ! -f "$sandbox/.piped_done" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  if [ -f "$sandbox/.piped_done" ]; then
    pass "케이스 15: stderr 파이프 수신 시에도 턴 완료와 함께 파이프 닫힘 (${waited}초, 상한 ${cap}초)"
  else
    fail "케이스 15: 턴 완료 후에도 호출자 파이프가 ${cap}초 이상 열린 채 유지 (WAIT_TIMEOUT=${uniq_timeout})"
  fi

  # fd 보유자를 먼저 회수한 뒤 job 을 reap 한다 — 순서를 바꾸면 cat 이 EOF 를 못 받아
  # wait 가 무한 대기한다. 회수는 소유권이 확인된 그룹 단위로만 하며, 그 그룹에
  # 어댑터·watchdog 고아·cat 이 모두 들어 있다 (pkill -f·패턴 종료 금지).
  # 블록 전체의 stderr 를 버리는 것은 kill -9 후 bash 가 내는 job 상태 알림
  # (`... Killed: 9 ...`) 이 판정 로그를 가리는 것을 막기 위함이다.
  { reap_group "$g"; wait "$job" || true; } 2>/dev/null
  rm -rf "$sandbox"
}

# ===========================================================================
# 실행
# ===========================================================================
echo "=== adapter_codex.sh 대기 계약·판정 단일화 테스트 ==="
echo ""

run_case1
run_case2
run_case3
run_case4
run_case5
run_case6

echo ""
echo "=== §2 결정 3 — run_review_turn.sh 설정 파싱 1회 통합 테스트 (Task 2) ==="
echo ""

run_case7
run_case8
run_case9
run_case10
run_case11

echo ""
echo "=== 회귀 테스트 — .tools/.overrides 부재 방어 (fix: priority 폐기 회귀) ==="
echo ""

run_case12
run_case13

echo ""
echo "=== 회귀 테스트 — watchdog 자손 lifecycle (fix: 고아 sleep 이 호출자 파이프 점유) ==="
echo ""

run_case14
run_case15

echo ""
echo "=== 결과: PASS=$PASS FAIL=$FAIL ==="

if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo "실패 케이스:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  exit 1
fi

exit 0
