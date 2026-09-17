#!/usr/bin/env bash
# test_review_wait.sh — adapter_codex.sh 대기 계약·판정 단일화 테스트
# 케이스:
#   1. 정상 완료 (CHECKPOINT Suggested Next Owner = Reviewer여도 성공 — CHECKPOINT 비소비 증명)
#   2. 비정상 종료 (mock exit 1, 즉시 실패)
#   3. 타임아웃 (mock sleep 30, WAIT_TIMEOUT=3)
#   4. 폴링 부재 grep (adapter_codex.sh + adapter_claude.sh)
#   5. malformed owner 실패 (Bogus / 빈 값 / awaiting-reviewer Status)
#   6. timeout 마커 정리 (정상 완료 경로에서 .wait_timeout 잔존 금지)
#  16. writable surface 세션 하위 폐쇄 — last-message 는 세션 하위 mktemp(사전 배치 symlink 비추종),
#      --add-dir 는 symlink 를 따라간 세션 physical 경로 (codex-adapter-writable-root)
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
  d="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$d" && -d "$d" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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

  # 마커는 안정 이름을 쓰지 않고 `.wait_timeout.XXXXXX` 로 배타 생성되므로 두 형태를
  # 함께 센다 (안정 이름 잔존은 구버전 회귀 신호이기도 하다).
  local marker_left
  marker_left="$( { ls -d "$sandbox"/.wait_timeout "$sandbox"/.wait_timeout.* 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  if [ "$marker_left" -eq 0 ]; then
    pass "케이스 6: 정상 완료 경로에서 타임아웃 마커 잔존 없음"
  else
    fail "케이스 6: 타임아웃 마커 ${marker_left}개가 정상 완료 후에도 잔존"
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
  harness_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  sandbox="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  sandbox="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  sandbox="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  sandbox="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  harness_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  sandbox="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  harness_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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

  harness_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
  sandbox="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }

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
  sandbox="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }

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
# 케이스 16: writable surface 세션 하위 폐쇄 (codex-adapter-writable-root)
#   (a) last-message 파일은 세션 하위 mktemp 템플릿 — 세션에 미리 놓인 고정명 symlink
#       `.last_message` 를 따라가 세션 밖 파일을 truncate 하지 않는다 (final diff review 002턴).
#   (b) 그 파일은 정상 종료 후 남지 않는다.
#   (c) --add-dir 에는 SESSION_PATH 의 symlink 를 따라간 physical 경로가 전달된다.
#   세션은 symlink 경로로 넘긴다 (team-overlay 재현). 실제 codex 대신 인자를 기록하는 mock.
# ===========================================================================
run_case16() {
  local sandbox victim_dir victim link_root sess_link sess_real
  sandbox="$(make_sandbox)"
  sess_real="$(cd "$sandbox" && pwd -P)"

  # team-overlay 재현: PROJECT_ROOT 안의 symlink 가 세션 실제 위치를 가리킨다
  link_root="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$link_root" && -d "$link_root" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  sess_link="$link_root/sess"
  ln -s "$sess_real" "$sess_link"

  # 세션 밖 피해 후보 + 고정명 symlink 사전 배치 (checkout·이전 비정상 실행 상황 재현)
  victim_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$victim_dir" && -d "$victim_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim="$victim_dir/victim.txt"
  printf 'KEEP\n' > "$victim"
  ln -s "$victim" "$sandbox/.last_message"

  local turn_file="$sandbox/turns/turn-001-reviewer.md"
  local args_out="$sandbox/mock_args.txt"
  write_session "$sandbox" "Author" "awaiting-author"

  # mock: 인자 전부 기록, --output-last-message 경로에 쓰기, 턴 파일 + SESSION 갱신
  local bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CASE16_ARGS_OUT"
lm=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--output-last-message" ]; then j=$((i+1)); lm="${!j}"; fi
done
[ -n "$lm" ] && echo "done" > "$lm"
touch "$CASE16_TURN_FILE"
cat > "$SESSION_PATH/SESSION.md" <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
cat >/dev/null
exit 0
MOCK_EOF
  chmod +x "$bin_dir/codex"

  local rc=0
  CASE16_ARGS_OUT="$args_out" \
  CASE16_TURN_FILE="$turn_file" \
  TOOL_BIN="$bin_dir/codex" \
  SESSION_PATH="$sess_link" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$turn_file" \
  PROJECT_ROOT="$link_root" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 16: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
  else
    # (a) 사전 배치 symlink 비추종 — 피해 후보 내용 보존, symlink 자체도 그대로
    if [ "$(cat "$victim")" = "KEEP" ] && [ -L "$sandbox/.last_message" ]; then
      pass "케이스 16a: 고정명 symlink .last_message 를 따라가지 않음 (세션 밖 파일 보존)"
    else
      fail "케이스 16a: 사전 배치 symlink 추종 — victim='$(cat "$victim" 2>/dev/null)', link=$([ -L "$sandbox/.last_message" ] && echo kept || echo gone)"
    fi

    # last-message 경로: 세션 하위 mktemp 템플릿 (고정명 아님)
    local lm_path
    lm_path="$(awk '/^--output-last-message$/{getline; print}' "$args_out")"
    case "$lm_path" in
      "$sess_link"/.last_message.??????)
        pass "케이스 16: last-message 는 세션 하위 mktemp 템플릿 ($(basename "$lm_path"))" ;;
      *)
        fail "케이스 16: last-message 경로가 세션 하위 템플릿이 아님 — '$lm_path'" ;;
    esac

    # (b) 정상 종료 후 템플릿 파일 잔존 없음 (사전 배치 symlink 만 남아야 한다)
    local leftover
    leftover="$(find "$sandbox" -maxdepth 1 -name '.last_message.*' | wc -l | tr -d ' ')"
    if [ "$leftover" -eq 0 ]; then
      pass "케이스 16b: 정상 종료 후 .last_message.* 잔존 없음"
    else
      fail "케이스 16b: .last_message.* ${leftover}개 잔존"
    fi

    # (c) --add-dir 는 symlink 를 따라간 physical 경로
    local add_dir
    add_dir="$(awk '/^--add-dir$/{getline; print}' "$args_out")"
    if [ "$add_dir" = "$sess_real" ]; then
      pass "케이스 16c: --add-dir 에 세션 physical 경로 전달 (symlink 해석됨)"
    else
      fail "케이스 16c: --add-dir 기대='$sess_real', 실제='$add_dir'"
    fi
  fi

  rm -rf "$sandbox" "$link_root" "$victim_dir"
}

# ===========================================================================
# 케이스 17: 환경변수 해석 — 유효/무효/fallthrough/0
# ===========================================================================
run_case17() {
  local sandbox expected_turn mock_bin
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  # mock: 즉시 턴 파일을 만들고 끝낸다 (대기 로직을 타지 않게)
  mock_bin="$(setup_mock "$sandbox" "printf 'x' > \"$expected_turn\"; exit 0")"

  # 해석 결과를 stderr 에서 읽는다. 형식: "wait config: cap=<N>s idle=<N>s"
  # 주의: BSD/macOS env 는 옵션을 환경 대입보다 **앞**에 두어야 한다.
  #       `env NAME=v -u OTHER` 형태는 -u 를 실행할 명령으로 해석할 수 있다.
  probe() {  # $1..: env 인자(-u 옵션이 먼저, 그다음 NAME=value) → stdout 에 config 줄
    env "$@" \
      TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
      EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
      bash "$ADAPTER" 2>&1 | grep -o 'wait config: cap=[0-9]*s idle=[0-9]*s' || true
  }

  local out
  # (a) 기본값
  out="$(probe -u WAIT_TIMEOUT -u POLL_TIMEOUT -u RD_REVIEW_IDLE_TIMEOUT)"
  [ "$out" = "wait config: cap=7200s idle=600s" ] \
    && pass "케이스 17a: 기본값 cap=7200 idle=600" \
    || fail "케이스 17a: 기대 cap=7200 idle=600 — 실제 [$out]"

  # (b) WAIT_TIMEOUT 유효
  out="$(probe -u POLL_TIMEOUT -u RD_REVIEW_IDLE_TIMEOUT WAIT_TIMEOUT=1234)"
  [ "$out" = "wait config: cap=1234s idle=600s" ] \
    && pass "케이스 17b: WAIT_TIMEOUT 반영" \
    || fail "케이스 17b: 기대 cap=1234 — 실제 [$out]"

  # (c) WAIT_TIMEOUT 무효 + POLL_TIMEOUT 유효 → 다음 원천으로 내려간다
  out="$(probe -u RD_REVIEW_IDLE_TIMEOUT WAIT_TIMEOUT=abc POLL_TIMEOUT=1200)"
  [ "$out" = "wait config: cap=1200s idle=600s" ] \
    && pass "케이스 17c: 무효값은 무시하고 alias 사용" \
    || fail "케이스 17c: 기대 cap=1200 — 실제 [$out]"

  # (d) 둘 다 무효 → 기본값
  out="$(probe -u RD_REVIEW_IDLE_TIMEOUT WAIT_TIMEOUT=-5 POLL_TIMEOUT=3.5)"
  [ "$out" = "wait config: cap=7200s idle=600s" ] \
    && pass "케이스 17d: 둘 다 무효 → 기본값" \
    || fail "케이스 17d: 기대 cap=7200 — 실제 [$out]"

  # (e) IDLE=0 은 유효 (유휴 판별 비활성)
  out="$(probe -u WAIT_TIMEOUT -u POLL_TIMEOUT RD_REVIEW_IDLE_TIMEOUT=0)"
  [ "$out" = "wait config: cap=7200s idle=0s" ] \
    && pass "케이스 17e: IDLE=0 유효(비활성)" \
    || fail "케이스 17e: 기대 idle=0 — 실제 [$out]"

  # (f) IDLE 무효 → 기본값 + 경고
  local warn
  warn="$(env -u WAIT_TIMEOUT -u POLL_TIMEOUT RD_REVIEW_IDLE_TIMEOUT=xyz \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" 2>&1 | grep -c 'RD_REVIEW_IDLE_TIMEOUT' || true)"
  [ "$warn" -ge 1 ] \
    && pass "케이스 17f: IDLE 무효값 경고 출력" \
    || fail "케이스 17f: 경고 미출력"

  # (g) 조정 변수 두 개의 무효값도 경고한다
  local w2
  w2="$(env -u WAIT_TIMEOUT -u POLL_TIMEOUT \
    RD_REVIEW_OBSERVER_FALLBACK_CAP=abc RD_REVIEW_HEARTBEAT=-3 \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" 2>&1)" || true
  if echo "$w2" | grep -q 'RD_REVIEW_OBSERVER_FALLBACK_CAP' \
     && echo "$w2" | grep -q 'RD_REVIEW_HEARTBEAT'; then
    pass "케이스 17g: 조정 변수 무효값 경고"
  else
    fail "케이스 17g: 조정 변수 무효값이 조용히 무시됨"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 18: 활동이 유휴 타이머를 반복 갱신한다 (총 경과 > 유휴 임계)
# ===========================================================================
run_case18() {
  local sandbox expected_turn mock_bin rc=0
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  # mock 이 SESSION.md 를 다시 쓰지 않으므로(턴 파일만 생성) check_turn_complete 가
  # 성공하려면 시작 시점부터 Owner=Author/Status=awaiting-author 여야 한다
  # (케이스 1·6·14 와 동일 관례 — 브리프 원문의 Reviewer/awaiting-reviewer 는
  # check_turn_complete 계약상 rc=0 을 구조적으로 불가능하게 하는 오기이므로 정정한다).
  write_session "$sandbox" "Author" "awaiting-author"
  write_checkpoint "$sandbox" "Reviewer"

  # mock: 1초마다 출력을 내며 6초간 일한 뒤 턴 파일을 만들고 성공.
  # 유휴 임계 2초 < 총 소요 6초 이므로, 유휴 갱신이 없으면 반드시 죽는다.
  mock_bin="$(setup_mock "$sandbox" \
    "for i in 1 2 3 4 5 6; do echo \"progress \$i\"; sleep 1; done; printf 'x' > \"$expected_turn\"; exit 0")"

  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=2 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] \
    && pass "케이스 18: 활동이 유휴 타이머를 갱신 (6초 작업 / 유휴 2초 / rc=0)" \
    || fail "케이스 18: 기대 rc=0 — 실제 rc=$rc (유휴 갱신 실패)"

  [ -s "$sandbox/.codex_output.log" ] \
    && pass "케이스 18(보조): codex 출력 로그 보존" \
    || fail "케이스 18(보조): .codex_output.log 부재 또는 빈 파일"

  grep -q '^log_preserved: yes' "$sandbox/.review_wait_status" 2>/dev/null \
    && pass "케이스 18(보조2): 정상 경로 log_preserved=yes 기록" \
    || fail "케이스 18(보조2): log_preserved 기록 없음"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 19: 무활동은 유휴 임계에서 124 로 종료된다
# ===========================================================================
run_case19() {
  local sandbox expected_turn mock_bin rc=0 output start elapsed
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: 한 줄 찍고 조용히 오래 잔다 → 첫 출력 후 무활동
  mock_bin="$(setup_mock "$sandbox" "echo start; exec sleep 60")"

  start=$(date +%s)
  output="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?
  elapsed=$(( $(date +%s) - start ))

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "유휴"; then
    pass "케이스 19: 무활동 → 유휴 사유로 exit 124 (${elapsed}초)"
  else
    fail "케이스 19: 기대 rc=124 + '유휴' 사유 — rc=$rc"
  fi

  # 상한(60초)이 아니라 유휴(3초)에서 끊겼는지 시간으로 확인한다
  [ "$elapsed" -lt 30 ] \
    && pass "케이스 19(보조): 상한이 아닌 유휴에서 종료 (${elapsed}초 < 30초)" \
    || fail "케이스 19(보조): ${elapsed}초 — 유휴 판정이 동작하지 않음"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 20: 활동 중이어도 절대 상한에서 종료된다
# ===========================================================================
run_case20() {
  local sandbox expected_turn mock_bin rc=0 output
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: 계속 출력하며 절대 끝나지 않는다
  mock_bin="$(setup_mock "$sandbox" "while :; do echo tick; sleep 1; done")"

  output="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=4 RD_REVIEW_IDLE_TIMEOUT=600 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "상한"; then
    pass "케이스 20: 활동 중에도 절대 상한에서 exit 124"
  else
    fail "케이스 20: 기대 rc=124 + '상한' 사유 — rc=$rc"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 21: heartbeat 주기·필드와 상태 파일 보존
# ===========================================================================
run_case21() {
  local sandbox expected_turn mock_bin rc=0 output beats
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  mock_bin="$(setup_mock "$sandbox" \
    "for i in 1 2 3 4 5 6; do echo \"working \$i\"; sleep 1; done; printf 'x' > \"$expected_turn\"; exit 0")"

  # HEARTBEAT_INTERVAL 을 2초로 낮춰 6초 실행에서 최소 2회 나오게 한다
  output="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=30 RD_REVIEW_HEARTBEAT=2 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  beats="$(echo "$output" | grep -c '^\[review wait\]' || true)"
  [ "$beats" -ge 2 ] \
    && pass "케이스 21a: heartbeat 반복 출력 (${beats}회)" \
    || fail "케이스 21a: heartbeat 기대 2회 이상 — 실제 ${beats}회"

  # 네 필드가 모두 있는가
  if echo "$output" | grep -q '^\[review wait\].*경과.*마지막 활동.*유휴여유.*상한'; then
    pass "케이스 21b: heartbeat 네 필드 포함"
  else
    fail "케이스 21b: heartbeat 필드 누락 — $(echo "$output" | grep '^\[review wait\]' | head -1)"
  fi

  # 로그의 마지막 줄이 붙는가
  echo "$output" | grep -q 'codex: working' \
    && pass "케이스 21c: heartbeat 에 로그 마지막 줄 포함" \
    || fail "케이스 21c: 로그 마지막 줄 미포함"

  # 상태 파일이 정상 완료 후에도 보존되는가
  [ -s "$sandbox/.review_wait_status" ] \
    && pass "케이스 21d: 상태 파일 정상 종료 후 보존" \
    || fail "케이스 21d: .review_wait_status 부재"

  rm -rf "$sandbox"
}
# ===========================================================================
# 케이스 22: 로그 경로 unlink 는 **관측을 훼손하지 않는다** (읽기 채널 fd 전용 계약)
#   활동 관측은 codex spawn 전에 열어 둔 fd 로만 하므로, 경로가 사라져도 어댑터는 원래
#   inode 에서 계속 새 바이트를 본다(codex 도 자기 fd 로 같은 inode 에 계속 쓴다).
#   훼손되는 것은 사후 **로그 보존**뿐이며 그것은 log-vanished-during-run 으로 보고된다.
#
#   판별력: 구 코드는 매 tick `wc -c < "$codex_log"` 로 **경로를 다시 열었고**(이번 라운드
#   Critical 의 정보 노출 창) unlink 시점에 관측기 고장으로 판정해 유효 상한 min(60,4)=4초
#   에서 rc=124 로 죽었다. 새 코드는 관측이 유지되므로 mock 이 6초 뒤 턴을 완성하고 rc=0
#   으로 끝난다. FALLBACK_CAP=4 를 그대로 주므로 구 코드로 되돌리면 이 케이스가 깨진다.
# ===========================================================================
run_case22() {
  local sandbox expected_turn mock_bin errlog start elapsed rc=0 i logf out
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  # 완주(rc=0)를 기대하므로 SESSION 은 완료 상태로 둔다 — 어댑터의 완료 판정은 codex
  # 종료 후에만 일어나므로 시작 시점 값이 실행 중 판정을 바꾸지 않는다(케이스 25 와 동일).
  write_session "$sandbox" "Author" "awaiting-author"
  # 1초마다 출력하며 6초 뒤 턴을 완성한다 → 관측이 유지되면 유휴(4초)로 죽지 않는다
  mock_bin="$(setup_mock "$sandbox" \
    "for i in 1 2 3 4 5 6; do echo tick; sleep 1; done; printf 'x' > \"$expected_turn\"; exit 0")"
  errlog="$sandbox/adapter_err.txt"

  # ABS_CAP=60(길게) / IDLE=4(짧게) / fallback 천장=4(짧게)
  #   관측이 유지되면 매초 활동이 갱신되어 유휴 4초가 발동하지 않고 6초를 완주한다.
  #   구 코드에서는 unlink(약 2초) 즉시 관측기 고장 → 유효 상한 4초 → rc=124.
  start=$(date +%s)
  spawn_group "$errlog" env \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=4 RD_REVIEW_OBSERVER_FALLBACK_CAP=4 \
    bash "$ADAPTER"

  # 로그 파일이 생기기를 기다렸다가 **실제로 지운다** (현실의 unlink 장애)
  logf=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    logf="$( { ls "$sandbox"/.codex_output.?????? 2>/dev/null || true; } | head -n 1 )"
    [ -n "$logf" ] && break
    sleep 0.1
  done
  if [ -z "$logf" ]; then
    fail "케이스 22: codex 출력 로그가 생성되지 않아 장애를 주입할 수 없음"
    reap_group "$GROUP_PGID"; rm -rf "$sandbox"; return
  fi
  sleep 2
  rm -f "$logf"

  wait "$JOB" 2>/dev/null || rc=$?
  elapsed=$(( $(date +%s) - start ))
  reap_group "$GROUP_PGID"
  out="$( { cat "$errlog" 2>/dev/null || true; } )"

  # (a) unlink 에도 관측이 유지되어 턴을 완주했는가
  if [ "$rc" -eq 0 ] && [ "$elapsed" -ge 5 ]; then
    pass "케이스 22a: 로그 경로 unlink 에도 관측 유지 — 턴 완주 (${elapsed}초, rc=0)"
  else
    fail "케이스 22a: 기대 rc=0 & elapsed>=5 — rc=$rc elapsed=${elapsed}초 (경로 재열기 관측으로 회귀했을 수 있음)"
  fi

  # (b) 관측기 고장으로 오판하지 않았는가 (전환 경고 고유 접두사로 좁혀 판정)
  local n; n="$( { echo "$out" | grep -c '^경고: 활동 관측기가 동작하지 않습니다' || true; } )"
  if [ "$n" -eq 0 ]; then
    pass "케이스 22b: 경로 소실을 관측기 고장으로 오판하지 않음"
  else
    fail "케이스 22b: 관측기 고장 경고 ${n}회 (fd 채널에서는 발생하지 않아야 함)"
  fi

  # (c) 상태 파일의 관측기 상태가 ok 인가
  { grep -q '^observer: ok' "$sandbox/.review_wait_status" 2>/dev/null; } \
    && pass "케이스 22c: 상태 파일에 observer: ok 기록" \
    || fail "케이스 22c: observer 상태 이상 — $( { grep '^observer' "$sandbox/.review_wait_status" 2>/dev/null || true; } )"

  # (d) 훼손된 것은 **보존**뿐이며 그것을 정직하게 보고했는가
  { echo "$out" | grep -q '보존하지 못했습니다'; } \
    && pass "케이스 22d: 로그 소실 시 stderr 로 보존 실패 보고" \
    || fail "케이스 22d: stderr 보고 없음"

  if { grep -q '^log_preserved: no' "$sandbox/.review_wait_status" 2>/dev/null; } \
     && { grep -q '^log_preserved_reason: log-vanished-during-run' "$sandbox/.review_wait_status" 2>/dev/null; }; then
    pass "케이스 22e: 상태 파일에 보존 실패와 사유 기록"
  else
    fail "케이스 22e: 상태 파일에 log_preserved/사유 없음 — $( { cat "$sandbox/.review_wait_status" 2>/dev/null || true; } | tr '\n' ' ')"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 23: 타임아웃 메시지 — 오염 단정 금지 + 재개 가능 판정
# ===========================================================================
run_case23() {
  local sandbox expected_turn mock_bin rc=0 output
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  mock_bin="$(setup_mock "$sandbox" "echo begin; exec sleep 60")"

  output="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  # (a) 오염을 단정하지 않는다
  echo "$output" | grep -q '오염' \
    && fail "케이스 23a: 타임아웃 경로에 '오염' 단정이 남아 있음" \
    || pass "케이스 23a: 타임아웃 경로에 오염 단정 없음"

  # (b) 재개 가능하다고 말한다
  echo "$output" | grep -q '이어갈 수 있습니다' \
    && pass "케이스 23b: 재개 가능 판정 출력" \
    || fail "케이스 23b: 재개 가능 판정 없음"

  # (c) 검사 범위를 밝힌다
  echo "$output" | grep -q '검사하지 않았습니다' \
    && pass "케이스 23c: 검사 범위 명시" \
    || fail "케이스 23c: 검사 범위 미명시"

  # (d) idle 사유에는 유휴 변수를 안내한다 (절대 상한을 올려도 재발하므로)
  if echo "$output" | grep -q 'RD_REVIEW_IDLE_TIMEOUT=<더 큰 값>'; then
    pass "케이스 23d: idle 사유에 유휴 임계 조정 안내"
  else
    fail "케이스 23d: idle 사유인데 유휴 변수 안내 없음"
  fi

  # (d2) idle 사유에 WAIT_TIMEOUT 을 안내하지 않는다
  echo "$output" | grep -q 'WAIT_TIMEOUT=<더 큰 값>' \
    && fail "케이스 23d2: idle 사유에 절대 상한 조정을 안내함 (재발하는 조치)" \
    || pass "케이스 23d2: idle 사유에 절대 상한 안내 없음"

  # (d3) cap 사유에는 WAIT_TIMEOUT 을 안내하고, 증명되지 않은 단정을 하지 않는다
  local sandbox3 output3 rc3=0 mock3
  sandbox3="$(make_sandbox)"
  write_session "$sandbox3" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox3" "Author"
  mock3="$(setup_mock "$sandbox3" "while :; do echo tick; sleep 1; done")"
  output3="$(
    TOOL_BIN="$mock3/codex" SESSION_PATH="$sandbox3" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$sandbox3/turns/turn-001-reviewer.md" PROJECT_ROOT="$sandbox3" \
    WAIT_TIMEOUT=3 RD_REVIEW_IDLE_TIMEOUT=600 \
      bash "$ADAPTER" 2>&1
  )" || rc3=$?
  echo "$output3" | grep -q 'WAIT_TIMEOUT=<더 큰 값>' \
    && pass "케이스 23d3: cap 사유에 절대 상한 조정 안내" \
    || fail "케이스 23d3: cap 사유에 절대 상한 안내 없음"
  echo "$output3" | grep -q '마지막까지 출력' \
    && fail "케이스 23d4: cap 메시지에 증명되지 않은 단정이 남아 있음" \
    || pass "케이스 23d4: cap 메시지에 미증명 단정 없음"
  echo "$output3" | grep -q '오염' \
    && fail "케이스 23d5: cap 경로에도 '오염' 단정이 남아 있음" \
    || pass "케이스 23d5: cap 경로에 오염 단정 없음"
  rm -rf "$sandbox3"

  # (e) 상태가 어긋나면 재개 가능하다고 말하지 않는다
  local sandbox2 output2 rc2=0
  sandbox2="$(make_sandbox)"
  write_session "$sandbox2" "Bogus" "awaiting-reviewer"
  write_checkpoint "$sandbox2" "Author"
  local mock2
  mock2="$(setup_mock "$sandbox2" "echo begin; exec sleep 60")"
  output2="$(
    TOOL_BIN="$mock2/codex" SESSION_PATH="$sandbox2" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$sandbox2/turns/turn-001-reviewer.md" PROJECT_ROOT="$sandbox2" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc2=$?
  echo "$output2" | grep -q '이어갈 수 있습니다' \
    && fail "케이스 23e: 상태가 어긋났는데 재개 가능하다고 말함" \
    || pass "케이스 23e: 상태 불일치 시 재개 가능 주장 없음"
  # "직접 확인하십시오" 라고 해놓고 재개 명령을 함께 내면 앞말이 무효가 된다
  echo "$output2" | grep -q '^재개:' \
    && fail "케이스 23e2: 상태 불일치인데 재개 명령을 출력함" \
    || pass "케이스 23e2: 상태 불일치 시 재개 명령 없음"
  rm -rf "$sandbox2"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 24: effective_cap 순수 함수 — fallback 불변식
# ===========================================================================
run_case24() {
  # 어댑터를 source 하지 않고 함수만 꺼내 쓴다 (어댑터는 set -e + 즉시 실행 스크립트).
  local fn
  fn="$(sed -n '/^effective_cap() {/,/^}/p' "$ADAPTER")"
  [ -n "$fn" ] || { fail "케이스 24: effective_cap 정의를 찾지 못함"; return; }

  local out rc=0
  # `set -e` 아래에서 명령 치환 대입을 가드 없이 두면, 추출한 함수가 비영 종료할 때
  # 케이스 FAIL 이 아니라 스위트 전체가 요약 없이 중단된다 — `|| true` 로 흡수하고
  # 이어지는 값 비교로 판정한다.
  out="$(bash -c "$fn"'
    effective_cap 7200 1 600
    echo
    effective_cap 7200 0 600
    echo
    effective_cap 3 0 600
    echo
    effective_cap 60 0 4
    echo' 2>/dev/null)" || rc=$?

  local expected="7200
600
3
4"
  if [ "$rc" -ne 0 ]; then
    fail "케이스 24: 추출한 effective_cap 실행이 비영 종료함 (rc=$rc) — 출력 [$out]"
  elif [ "$out" = "$expected" ]; then
    pass "케이스 24: effective_cap — 정상=상한 / 고장=min(상한,천장) / 짧은 상한 보존"
  else
    fail "케이스 24: 기대 [$expected] — 실제 [$out]"
  fi
}

# ===========================================================================
# 케이스 25: 상태 snapshot 은 매 실행 시작에 초기화되고 관리 키는 단일하다
#   (a) 신규 세션의 빠른 종료(첫 heartbeat 전) — 필수 필드가 모두 있다
#   (b) 기존 상태 파일이 있는 빠른 재실행 — 과거 임시 경로·과거 관측기 상태가 남지 않는다
#   판정은 낱말 세기가 아니라 **키 존재와 키 개수(구조)** 로 한다.
# ===========================================================================
run_case25() {
  local sandbox expected_turn mock_bin sf rc=0 k n missing="" dup=""
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"
  mock_bin="$(setup_mock "$sandbox" "echo quick; printf 'x' > \"$expected_turn\"; exit 0")"
  sf="$sandbox/.review_wait_status"

  # (a) 신규 세션 — 1초 안에 끝나므로 heartbeat(기본 60초)는 한 번도 돌지 않는다
  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 25: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
    rm -rf "$sandbox"; return
  fi

  for k in 'log_path:' 'observer:' 'effective_cap:' 'log_preserved:' 'log_path_final:'; do
    if ! { grep -q "^${k}" "$sf" 2>/dev/null; }; then missing="${missing}${k} "; fi
  done
  if [ -z "$missing" ]; then
    pass "케이스 25a: 첫 heartbeat 전 종료에도 필수 필드가 모두 존재"
  else
    fail "케이스 25a: 필드 누락 [$missing] — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
  fi

  # 유효 상한은 이번 실행의 설정값(30초)이어야 한다
  { grep -q '^effective_cap: 30s' "$sf" 2>/dev/null; } \
    && pass "케이스 25a2: effective_cap 이 이번 실행 설정(30s)" \
    || fail "케이스 25a2: effective_cap 불일치 — $( { grep '^effective_cap' "$sf" 2>/dev/null || true; } )"

  # (b) 기존 상태 파일이 남아 있는 빠른 재실행 — 과거 문장이 섞여선 안 된다.
  # 고유 토큰 OLDSTALE 로 판정한다 (production 문구에 의존하지 않는다).
  printf '%s\n' \
    '[review wait] 경과 55m00s | 마지막 활동 3m00s 전 | 유휴여유 2m00s | 상한 1h00m' \
    '  codex: OLDSTALE-progress' \
    "log_path: ${sandbox}/.codex_output.OLDSTALE" \
    'observer: failed' \
    'effective_cap: 4s' \
    'log_preserved: no' \
    'log_preserved_reason: log-vanished-during-run' \
    'log_path_final: (없음)' \
    'log_path_recovery: /tmp/OLDSTALE' > "$sf"

  rc=0
  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 25b: 전제 실패 — 재실행 rc=$rc"
  else
    if { grep -q 'OLDSTALE' "$sf" 2>/dev/null; }; then
      fail "케이스 25b: 이전 턴 snapshot 이 현재 상태로 보존됨 — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
    else
      pass "케이스 25b: 재실행이 과거 snapshot(임시 경로·관측기 상태)을 물려받지 않음"
    fi
    { grep -q '^observer: ok' "$sf" 2>/dev/null; } \
      && pass "케이스 25b2: 관측기 상태가 이번 실행 기준" \
      || fail "케이스 25b2: observer 가 과거 값 — $( { grep '^observer' "$sf" 2>/dev/null || true; } )"
    { grep -q '^log_preserved: yes' "$sf" 2>/dev/null; } \
      && pass "케이스 25b3: 보존 결과가 이번 실행 기준(yes)" \
      || fail "케이스 25b3: log_preserved 가 과거 값 — $( { grep '^log_preserved' "$sf" 2>/dev/null || true; } )"

    for k in log_preserved log_preserved_reason log_path_final log_path_recovery; do
      n="$( { grep -c "^${k}: " "$sf" 2>/dev/null || true; } | tr -d ' ' )"
      [ -n "$n" ] || n=0
      [ "$n" -gt 1 ] && dup="${dup}${k}=${n} "
    done
    if [ -z "$dup" ]; then
      pass "케이스 25b4: 관리 키가 실행마다 중복되지 않음"
    else
      fail "케이스 25b4: 관리 키 중복 [$dup]"
    fi
  fi

  # 임시 파일 잔존 없음
  n="$( { find "$sandbox" -maxdepth 1 -name '.review_wait_status.*' 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  [ "$n" -eq 0 ] \
    && pass "케이스 25c: 상태 파일 임시 잔여물 없음" \
    || fail "케이스 25c: .review_wait_status.* ${n}개 잔존"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 26: 상태 파일 쓰기가 세션 밖 파일을 truncate·유출하지 않는다 (보안 회귀)
#   구 코드는 `.review_wait_status.tmp.$$` 로 썼고 그 `$$` 는 어댑터 PID 이다.
#   background codex 에서 `$PPID` 가 곧 어댑터 PID 이므로 codex 는 그 경로를 정확히
#   계산할 수 있었다 — 그 자리에 세션 밖 파일을 가리키는 symlink 를 심으면 `>` 가 링크를
#   따라가 sandbox 밖 파일을 호출자 권한으로 truncate 한다(confused deputy).
#   안정 경로 `.review_wait_status` 에 세션 밖 **디렉터리** symlink 를 심으면 `mv` 가
#   그 안으로 상태 파일을 옮겨 세션 밖으로 유출시킨다.
#   케이스 16(last_message)과 같은 성질을 상태 파일 두 경로에 대해 고정한다.
# ===========================================================================
run_case26() {
  local sandbox expected_turn bin_dir victim_dir victim leak_dir rc=0 n
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"

  victim_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$victim_dir" && -d "$victim_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim="$victim_dir/sentinel.txt"
  printf 'SENTINEL-KEEP\n' > "$victim"
  leak_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak_dir" && -d "$leak_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# 구 예측 규칙 두 형태를 모두 심는다: 어댑터 PID($PPID)와 mock 자신의 PID($$).
ln -sf "$C26_SENTINEL" "$SESSION_PATH/.review_wait_status.tmp.$PPID" 2>/dev/null || true
ln -sf "$C26_SENTINEL" "$SESSION_PATH/.review_wait_status.tmp.$$" 2>/dev/null || true
# 안정 경로에는 세션 밖 디렉터리 symlink
rm -f "$SESSION_PATH/.review_wait_status" 2>/dev/null || true
ln -sfn "$C26_LEAKDIR" "$SESSION_PATH/.review_wait_status" 2>/dev/null || true
echo working
sleep 2
touch "$C26_TURN_FILE"
cat >/dev/null
exit 0
MOCK_EOF
  chmod +x "$bin_dir/codex"

  C26_SENTINEL="$victim" C26_LEAKDIR="$leak_dir" C26_TURN_FILE="$expected_turn" \
  TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 RD_REVIEW_HEARTBEAT=1 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 26: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
  else
    # (a) 예측 가능 경로 symlink 를 따라가 세션 밖 파일을 truncate 하지 않았다
    if [ "$( { cat "$victim" 2>/dev/null || true; } )" = "SENTINEL-KEEP" ]; then
      pass "케이스 26a: 예측 가능 임시 경로 symlink 비추종 (세션 밖 sentinel 내용 보존)"
    else
      fail "케이스 26a: 세션 밖 sentinel 이 훼손됨 — '$( { cat "$victim" 2>/dev/null || true; } )'"
    fi

    # (b) 안정 경로 디렉터리 symlink 를 따라가 세션 밖으로 상태 파일을 옮기지 않았다
    n="$( { ls -A "$leak_dir" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
    [ "$n" -eq 0 ] \
      && pass "케이스 26b: 안정 경로 디렉터리 symlink 비추종 (세션 밖 유출 없음)" \
      || fail "케이스 26b: 세션 밖 디렉터리로 ${n}개 유출 — $( { ls -A "$leak_dir" 2>/dev/null || true; } | tr '\n' ' ')"

    # (c) 상태 파일은 세션 안의 정규 파일로 남는다
    if [ -f "$sandbox/.review_wait_status" ] && [ ! -L "$sandbox/.review_wait_status" ] \
       && { grep -q '^log_preserved: ' "$sandbox/.review_wait_status" 2>/dev/null; }; then
      pass "케이스 26c: 상태 파일이 세션 안 정규 파일로 기록됨"
    else
      fail "케이스 26c: 상태 파일이 정규 파일이 아니거나 비어 있음"
    fi
  fi

  rm -rf "$sandbox" "$victim_dir" "$leak_dir"
}

# ===========================================================================
# 케이스 27: 로그 최종 이동 실패를 성공으로 보고하지 않는다 (Important 3)
#   (a) 안정 경로에 **실제 디렉터리** — 이동은 반드시 실패해야 하고, 그때
#       log_preserved: no + 기계 판독 사유 + 회수 가능한 임시 경로가 남아야 한다.
#       (구 코드는 `mv ... || true` 뒤에 무조건 yes 를 적었다.)
#   (b) 안정 경로에 **세션 밖 디렉터리 symlink** — 로그가 세션 밖으로 새지 않아야 한다.
# ===========================================================================
run_case27() {
  local sandbox expected_turn mock_bin sf err rc=0 n rec
  # --- (a) 실제 디렉터리 ---
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"
  mock_bin="$(setup_mock "$sandbox" "echo blocked; printf 'x' > \"$expected_turn\"; exit 0")"
  mkdir -p "$sandbox/.codex_output.log"
  sf="$sandbox/.review_wait_status"
  err="$sandbox/err_a.txt"

  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>"$err" || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 27a: 전제 실패 — 어댑터 rc=$rc (턴 자체는 성공해야 함)"
  else
    if { grep -q '^log_preserved: no' "$sf" 2>/dev/null; } \
       && { grep -q '^log_preserved_reason: log-move-failed' "$sf" 2>/dev/null; }; then
      pass "케이스 27a: 이동 실패를 no + log-move-failed 로 기록"
    else
      fail "케이스 27a: 이동 실패인데 보존 성공으로 기록 — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
    fi

    rec="$( { grep '^log_path_recovery: ' "$sf" 2>/dev/null || true; } | sed 's/^log_path_recovery: //' )"
    if [ -n "$rec" ] && [ -f "$rec" ]; then
      pass "케이스 27a2: 회수 가능한 임시 경로를 상태 파일에 남김 ($(basename "$rec"))"
    else
      fail "케이스 27a2: 회수 경로 없음 또는 실재하지 않음 — '$rec'"
    fi

    { grep -q '옮기지 못했습니다' "$err" 2>/dev/null; } \
      && pass "케이스 27a3: stderr 로 이동 실패 보고" \
      || fail "케이스 27a3: stderr 보고 없음"

    n="$( { ls -A "$sandbox/.codex_output.log" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
    [ "$n" -eq 0 ] \
      && pass "케이스 27a4: 디렉터리 안으로 로그를 밀어 넣지 않음" \
      || fail "케이스 27a4: 디렉터리 안에 ${n}개 생성"
  fi
  rm -rf "$sandbox"

  # --- (b) 세션 밖 디렉터리 symlink ---
  local leak_dir sandbox2 expected2 mock2 rc2=0
  sandbox2="$(make_sandbox)"
  expected2="$sandbox2/turns/turn-001-reviewer.md"
  write_session "$sandbox2" "Author" "awaiting-author"
  mock2="$(setup_mock "$sandbox2" "echo leaky; printf 'x' > \"$expected2\"; exit 0")"
  leak_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak_dir" && -d "$leak_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  ln -sfn "$leak_dir" "$sandbox2/.codex_output.log"

  TOOL_BIN="$mock2/codex" SESSION_PATH="$sandbox2" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected2" PROJECT_ROOT="$sandbox2" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc2=$?

  n="$( { ls -A "$leak_dir" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  if [ "$n" -eq 0 ] && [ -f "$sandbox2/.codex_output.log" ] && [ ! -L "$sandbox2/.codex_output.log" ]; then
    pass "케이스 27b: 안정 경로 디렉터리 symlink 로 로그가 세션 밖으로 새지 않음"
  else
    fail "케이스 27b: 유출 ${n}개 / 안정 경로 형태 이상 (rc=$rc2)"
  fi
  rm -rf "$sandbox2" "$leak_dir"
}

# ===========================================================================
# 케이스 28: 경쟁 symlink — 안정 이름 rename 제거로 유출 창이 닫혔는가 (Important 3)
#   구 코드는 매 갱신마다 안정 이름(`.review_wait_status`)으로 `mv` 했다. 검사·삭제·mv 는
#   원자 연산이 아니므로 codex 가 그 이름을 **타이트한 루프로 계속** 외부 디렉터리 symlink 로
#   재생성하면 창을 반복 공략해 상태 snapshot 을 세션 밖으로 빼낼 수 있었다.
#   `.wait_timeout` 마커는 그 방어조차 없어 무방비 `mv` 였고, 마커가 밖으로 나가면 부모의
#   존재 검사가 실패해 **실제 타임아웃을 일반 조기 종료로 오분류**했다.
#   새 계약: 진행 중에는 안정 이름을 건드리지 않고(스트림 fd 전용), 마커는 spawn 전에 배타
#   생성한 무작위 경로에 fd 로 쓴다. 그래서 이 mock 이 이겨야 할 창이 존재하지 않는다.
#   판정: ① 외부 디렉터리 유출 0 ② 외부 정규 파일 훼손 없음 ③ 타임아웃 exit 124 보존
#         ④ 사유가 사실대로(유휴) 보고됨
# ===========================================================================
run_case28() {
  local sandbox expected_turn bin_dir leak_dir victim_dir victim rc=0 out n
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  leak_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak_dir" && -d "$leak_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$victim_dir" && -d "$victim_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim="$victim_dir/sentinel.txt"
  printf 'SENTINEL-KEEP\n' > "$victim"

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# "한 번 미리 배치" 가 아니라 **반복 공략**을 재현한다. 안정 이름과, 세션 디렉터리를
# **열거해 찾은 무작위 이름** 둘 다 노린다 (이름의 무작위성만으로는 열거를 막지 못한다).
# 출력을 내지 않으므로 활동 관측기는 진행 없음으로 보고 유휴 타임아웃이 발동한다.
while :; do
  rm -f "$SESSION_PATH/.review_wait_status" 2>/dev/null
  ln -sfn "$C28_LEAKDIR" "$SESSION_PATH/.review_wait_status" 2>/dev/null
  rm -f "$SESSION_PATH/.wait_timeout" 2>/dev/null
  ln -sfn "$C28_LEAKDIR" "$SESSION_PATH/.wait_timeout" 2>/dev/null
  for f in "$SESSION_PATH"/.review_wait_status.?????? "$SESSION_PATH"/.wait_timeout.??????; do
    [ -e "$f" ] || continue
    if [ -L "$f" ]; then continue; fi
    rm -f "$f" 2>/dev/null
    ln -sfn "$C28_SENTINEL" "$f" 2>/dev/null
  done
  sleep 0.01
done
MOCK_EOF
  chmod +x "$bin_dir/codex"

  out="$(
    C28_LEAKDIR="$leak_dir" C28_SENTINEL="$victim" \
    TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 RD_REVIEW_HEARTBEAT=1 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  # (a) 외부 디렉터리로 아무것도 나가지 않았다
  n="$( { ls -A "$leak_dir" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  [ "$n" -eq 0 ] \
    && pass "케이스 28a: 경쟁 symlink 반복 공략에도 외부 디렉터리 유출 0" \
    || fail "케이스 28a: 외부 디렉터리로 ${n}개 유출 — $( { ls -A "$leak_dir" 2>/dev/null || true; } | tr '\n' ' ' )"

  # (b) 외부 정규 파일을 truncate·덮어쓰지 않았다 (fd 전용 쓰기의 증거)
  [ "$( { cat "$victim" 2>/dev/null || true; } )" = "SENTINEL-KEEP" ] \
    && pass "케이스 28b: 외부 정규 파일 내용 보존 (경로 재해석 없는 fd 쓰기)" \
    || fail "케이스 28b: 외부 sentinel 훼손 — '$( { cat "$victim" 2>/dev/null || true; } )'"

  # (c) 타임아웃 종료 코드가 보존됐다 — 마커가 빼돌려지면 조기 종료(exit 1)로 오분류된다
  [ "$rc" -eq 124 ] \
    && pass "케이스 28c: 마커 공략에도 타임아웃 exit 124 보존" \
    || fail "케이스 28c: 기대 rc=124 — 실제 rc=$rc"

  # (d) 사유를 사실대로 보고했다 (마커 내용이 fd 로 전달됐다는 증거)
  echo "$out" | grep -q '유휴' \
    && pass "케이스 28d: 타임아웃 사유(유휴)를 사실대로 보고" \
    || fail "케이스 28d: 사유 보고 누락 — $out"

  reap_group "$GROUP_PGID"
  rm -rf "$sandbox" "$leak_dir" "$victim_dir"

  # --- (e) 마커 오분류 — 결정적 시나리오 ---
  # 위 (c) 는 반복 공략 루프이므로 마커 창을 이기는 시점이 확률적이다. 마커 구멍은
  # **한 번 심고 유지**하면 결정적으로 재현된다: 구 코드는 안정 이름 `.wait_timeout` 으로
  # 무방비 `mv` 했으므로 그 자리에 외부 디렉터리 symlink 가 있으면 마커가 세션 밖으로
  # 옮겨지고, 부모의 `[ -f ]` 가 실패해 **실제 타임아웃을 조기 종료(exit 1)로 오분류**했다.
  local sb2 leak2 out2 rc2=0 n2
  sb2="$(make_sandbox)"
  write_session "$sb2" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sb2" "Author"
  leak2="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak2" && -d "$leak2" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  local mock2
  mock2="$(setup_mock "$sb2" 'ln -sfn "$C28E_LEAKDIR" "$SESSION_PATH/.wait_timeout" 2>/dev/null; exec sleep 60')"

  out2="$(
    C28E_LEAKDIR="$leak2" \
    TOOL_BIN="$mock2/codex" SESSION_PATH="$sb2" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$sb2/turns/turn-001-reviewer.md" PROJECT_ROOT="$sb2" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc2=$?

  n2="$( { ls -A "$leak2" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  if [ "$rc2" -eq 124 ] && [ "$n2" -eq 0 ]; then
    pass "케이스 28e: 안정 이름 마커 symlink 유지에도 타임아웃 보존 (rc=124, 유출 0)"
  else
    fail "케이스 28e: 마커 오분류 또는 유출 — rc=$rc2 (기대 124) 유출=${n2}개"
  fi
  echo "$out2" | grep -q '턴 완료 전에 종료' \
    && fail "케이스 28e2: 실제 타임아웃을 조기 종료로 오분류함" \
    || pass "케이스 28e2: 조기 종료 오분류 없음"

  rm -rf "$sb2" "$leak2"
}

# ===========================================================================
# 케이스 29: 소스 로그가 symlink 로 교체되면 거짓 "회수 가능" 을 보고하지 않는다 (Important 4)
#   codex 는 세션을 열거해 무작위 `.codex_output.*` 이름을 찾을 수 있다. 그 경로를 외부
#   **정규 파일** symlink 로 바꾸면 구 코드의 `[ -f ]` 는 링크를 따라 참이 되고 `mv` 는
#   symlink 자체를 안정 경로로 옮겼다. 이후 `[ ! -L ]` 검증은 실패하지만 원래 임시 경로는
#   이미 사라졌는데도 실패 분기가 무조건 "로그는 임시 경로에 남아 있습니다(회수 가능)" 를
#   출력하고 `log_path_recovery` 에 그 **존재하지 않는 경로**를 적었다.
#   (기존 케이스 27 은 목적지 directory/symlink 만 검사해 이 경로를 고정하지 못했다.)
# ===========================================================================
run_case29() {
  local sandbox expected_turn bin_dir out_dir outside sf err rc=0
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"
  out_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$out_dir" && -d "$out_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  outside="$out_dir/outside.txt"
  printf 'OUTSIDE-CONTENT\n' > "$outside"
  sf="$sandbox/.review_wait_status"
  err="$sandbox/err.txt"

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# 세션을 열거해 소스 로그 경로를 찾아 외부 **정규 파일** symlink 로 바꿔치기한다.
for f in "$SESSION_PATH"/.codex_output.??????; do
  [ -e "$f" ] || continue
  rm -f "$f" 2>/dev/null
  ln -sfn "$C29_OUTSIDE" "$f" 2>/dev/null
done
printf 'x' > "$C29_TURN_FILE"
exit 0
MOCK_EOF
  chmod +x "$bin_dir/codex"

  C29_OUTSIDE="$outside" C29_TURN_FILE="$expected_turn" \
  TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>"$err" || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 29: 전제 실패 — 어댑터 rc=$rc (턴 자체는 성공해야 함)"
  else
    # (a) 변조된 소스를 안정 경로로 끌어오지 않았다 (남의 파일을 codex 출력으로 보고 금지)
    if [ ! -e "$sandbox/.codex_output.log" ] && [ ! -L "$sandbox/.codex_output.log" ]; then
      pass "케이스 29a: symlink 소스를 안정 경로로 옮기지 않음"
    else
      fail "케이스 29a: 안정 경로에 산출물이 생김 (symlink=$( [ -L "$sandbox/.codex_output.log" ] && echo 예 || echo 아니오 ))"
    fi

    # (b) 보존 실패를 **별도 사유**로 정직하게 기록했다
    if { grep -q '^log_preserved: no' "$sf" 2>/dev/null; } \
       && { grep -q '^log_preserved_reason: log-source-replaced' "$sf" 2>/dev/null; }; then
      pass "케이스 29b: 소스 변조를 no + log-source-replaced 로 기록"
    else
      fail "케이스 29b: 사유 기록 누락 — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
    fi

    # (c) 존재하지 않는 경로를 "회수 가능" 으로 보고하지 않았다
    if { grep -q '^log_path_recovery: ' "$sf" 2>/dev/null; }; then
      fail "케이스 29c: 회수할 수 없는데 log_path_recovery 를 기록함 — $( { grep '^log_path_recovery' "$sf" 2>/dev/null || true; } )"
    else
      pass "케이스 29c: 회수 경로를 기록하지 않음"
    fi
    { grep -q '회수 가능' "$err" 2>/dev/null; } \
      && fail "케이스 29c2: stderr 에 거짓 '회수 가능' 안내가 남아 있음" \
      || pass "케이스 29c2: stderr 에 거짓 회수 안내 없음"

    # (d) 외부 파일을 세션 안으로 끌어오거나 옮겨 버리지 않았다
    if [ -f "$outside" ] && [ "$( { cat "$outside" 2>/dev/null || true; } )" = "OUTSIDE-CONTENT" ]; then
      pass "케이스 29d: 외부 정규 파일이 제자리에 그대로 남음"
    else
      fail "케이스 29d: 외부 파일이 사라졌거나 변경됨"
    fi
  fi

  rm -rf "$sandbox" "$out_dir"
}

# ===========================================================================
# 케이스 30: 안정 상태 파일은 **실행 중에 존재하지 않는다** (final diff review 006 Important 2)
#   계약: `.review_wait_status` 는 실행 중에는 없고 종료 후 1회 발행된다.
#   구 코드는 시작 정리에서 `.turn_ready`·예상 턴·과거 마커만 지웠으므로 **이전 턴의 안정
#   상태 파일이 이번 실행 중에도 그대로 남았다**(실측: 이전 안정 파일과 이번 실행 스트림
#   동시 존재). 안정 경로만 보는 headless 소비자는 이전 턴의 log_path·observer·보존 결과를
#   현재 실행 상태로 오인한다.
#   판정 시점이 핵심이다 — 케이스 25 는 두 실행을 **모두 완료한 뒤** 최종 파일만 검사해 이
#   구간을 놓친다. 여기서는 mock 을 rendezvous 파일로 붙잡아 **실행 중에** 단정한다.
# ===========================================================================
run_case30() {
  local sandbox expected_turn mock_bin errlog rc=0 i started go n stream
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  # 완주(rc=0)를 기대하므로 SESSION 은 완료 상태로 둔다 — 어댑터의 완료 판정은 codex
  # 종료 후에만 일어나므로 시작 시점 값이 실행 중 판정을 바꾸지 않는다(케이스 25 와 동일).
  write_session "$sandbox" "Author" "awaiting-author"
  started="$sandbox/mock_started"
  go="$sandbox/mock_go"
  errlog="$sandbox/adapter_err.txt"

  # 이전 턴이 남긴 안정 산출물 — 고유 토큰 PREVRUN 으로 판정한다(production 문구 비의존).
  printf '%s\n' \
    '[review wait] 경과 55m00s | 마지막 활동 3m00s 전 | 유휴여유 2m00s | 상한 1h00m' \
    '  codex: PREVRUN-progress' \
    "log_path: ${sandbox}/.codex_output.PREVRUN" \
    'observer: failed' \
    'effective_cap: 4s' \
    'log_preserved: yes' \
    "log_path_final: ${sandbox}/.codex_output.log" > "$sandbox/.review_wait_status"
  printf 'PREVRUN-log-content\n' > "$sandbox/.codex_output.log"

  mock_bin="$(setup_mock "$sandbox" \
    "echo started; printf 's' > \"$started\"; while [ ! -f \"$go\" ]; do sleep 0.1; done; printf 'x' > \"$expected_turn\"; exit 0")"

  spawn_group "$errlog" env \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=30 \
    bash "$ADAPTER"

  # mock 이 실제로 떠 있는(= 실행 중인) 시점까지 기다린다
  for i in $(seq 1 100); do
    [ -f "$started" ] && break
    sleep 0.1
  done
  if [ ! -f "$started" ]; then
    fail "케이스 30: 전제 실패 — mock 이 시작되지 않아 실행 중 관측을 할 수 없음"
    printf 'go' > "$go"; reap_group "$GROUP_PGID"; rm -rf "$sandbox"; return
  fi

  # --- 실행 중 단정 ---
  if [ ! -e "$sandbox/.review_wait_status" ]; then
    pass "케이스 30a: 실행 중 안정 상태 파일 부재 (이전 턴 상태가 남지 않음)"
  else
    fail "케이스 30a: 실행 중에도 안정 상태 파일이 존재 — $( { cat "$sandbox/.review_wait_status" 2>/dev/null || true; } | tr '\n' '|' )"
  fi

  stream="$( { ls "$sandbox"/.review_wait_status.?????? 2>/dev/null || true; } | head -n 1 )"
  [ -n "$stream" ] \
    && pass "케이스 30b: 실행 중 이번 실행의 상태 스트림 존재 ($(basename "$stream"))" \
    || fail "케이스 30b: 이번 실행의 상태 스트림이 없음"

  [ ! -e "$sandbox/.codex_output.log" ] \
    && pass "케이스 30c: 실행 중 안정 로그 부재 (이전 턴 로그가 남지 않음)" \
    || fail "케이스 30c: 실행 중에도 안정 로그가 존재 — $( { cat "$sandbox/.codex_output.log" 2>/dev/null || true; } | tr '\n' '|' )"

  # --- 실행 종료 후 ---
  printf 'go' > "$go"
  wait "$JOB" 2>/dev/null || rc=$?
  reap_group "$GROUP_PGID"

  if [ "$rc" -ne 0 ]; then
    fail "케이스 30d: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
  elif [ -f "$sandbox/.review_wait_status" ] \
       && ! { grep -q 'PREVRUN' "$sandbox/.review_wait_status" 2>/dev/null; }; then
    pass "케이스 30d: 종료 후 이번 실행 기준으로 1회 발행"
  else
    fail "케이스 30d: 발행 누락 또는 이전 턴 내용 잔존 — $( { cat "$sandbox/.review_wait_status" 2>/dev/null || true; } | tr '\n' '|' )"
  fi

  { grep -q 'PREVRUN' "$sandbox/.codex_output.log" 2>/dev/null; } \
    && fail "케이스 30e: 안정 로그가 이전 턴 내용 그대로임" \
    || pass "케이스 30e: 안정 로그가 이번 실행 로그로 대체됨"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 31: 로그·last-message **읽기**가 세션 밖 파일 내용을 노출하지 않는다
#            (final diff review 006 Critical 1)
#   위협 모델: 실행 중 codex 는 세션 디렉터리에 쓸 수 있고(`--sandbox workspace-write` +
#   `--add-dir`), 어댑터는 그 sandbox **밖에서 호출자 권한으로** 돈다. 구 코드는 매 tick
#   `wc -c < "$codex_log"`, heartbeat `grep ... "$codex_log" | tail -1`, 타임아웃 `tail -n 5`,
#   조기 종료 `tail -n 20`, 실패 경로 `cat "$last_message_file"` 로 **가변 경로를 다시 열었다.**
#   codex 가 그 이름을 세션 밖의 읽기 가능한 파일 symlink 로 바꾸면 그 내용이 stderr 와
#   상태 파일로 흘러나온다(실측: 수정 전 어댑터에서 stderr 5회 + 안정 상태 파일 1회 노출).
#   cleanup 의 `log-source-replaced` 판정은 **내용이 이미 노출된 뒤라 너무 늦다** — 그래서
#   케이스 29(턴을 정상 완성시켜 heartbeat·오류 tail 경로를 지나지 않는다)로는 잡히지 않는다.
#   이 케이스는 **heartbeat 가 발동하고 조기 종료 보고도 지나는** 시나리오를 만든다.
#   판정: ① sentinel 고유 문자열이 stderr 와 최종 상태 파일 어디에도 없다
#         ② 그 부재가 공허하지 않다 — 두 보고 경로를 실제로 지났고(heartbeat 2회 이상,
#            우리 inode 의 고유 줄이 보고됨) last message 도 fd 로 읽혔다
# ===========================================================================
run_case31() {
  local sandbox expected_turn bin_dir out_dir sentinel err sf rc=0 n beats
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  out_dir="$(mktemp -d)" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$out_dir" && -d "$out_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  sentinel="$out_dir/secret.txt"
  printf 'RDLEAK-SENTINEL-9f3a2b\n' > "$sentinel"
  err="$sandbox/err.txt"
  sf="$sandbox/.review_wait_status"

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# ① 우리 inode 에 식별 가능한 로그를 남긴다 (상속한 stdout fd 로 나가므로 경로 교체와 무관)
i=0
while [ "$i" -lt 40 ]; do printf 'RDLOGLINE-%03d\n' "$i"; i=$((i+1)); done
# ② 정상적인 last message 를 남긴다 (제자리 truncate 쓰기 — 실제 codex 와 같은 형태)
lm=""
for f in "$SESSION_PATH"/.last_message.??????; do [ -e "$f" ] && lm="$f"; done
[ -n "$lm" ] && printf 'RDLASTMSG-OK\n' > "$lm"
# ③ 세션을 열거해 두 경로를 세션 밖 sentinel symlink 로 바꾼다 (무작위 이름은 열거로 찾힌다)
for f in "$SESSION_PATH"/.codex_output.?????? "$SESSION_PATH"/.last_message.??????; do
  [ -e "$f" ] || continue
  rm -f "$f" 2>/dev/null
  ln -sfn "$RD31_SENTINEL" "$f" 2>/dev/null
done
# ④ heartbeat(1초)가 여러 번 지나가게 기다린 뒤 **턴 파일 없이** 종료 → 조기 종료 보고 경로
sleep 3
exit 3
MOCK_EOF
  chmod +x "$bin_dir/codex"

  RD31_SENTINEL="$sentinel" \
  TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 RD_REVIEW_HEARTBEAT=1 \
    bash "$ADAPTER" >/dev/null 2>"$err" || rc=$?

  # (전제) 조기 종료 경로로 끝났는가
  if [ "$rc" -ne 1 ]; then
    fail "케이스 31: 전제 실패 — 기대 rc=1(조기 종료) 실제 rc=$rc"
  fi

  # (a) stderr 에 sentinel 이 없다
  n="$( { grep -c 'RDLEAK-SENTINEL-9f3a2b' "$err" 2>/dev/null || true; } | tr -d ' ' )"
  [ -n "$n" ] || n=0
  [ "$n" -eq 0 ] \
    && pass "케이스 31a: stderr 에 세션 밖 sentinel 노출 없음" \
    || fail "케이스 31a: stderr 로 세션 밖 파일 내용 ${n}회 노출 (읽기 경로 재열기 회귀)"

  # (b) 최종 상태 파일에도 없다 (heartbeat 가 상태 스트림에도 마지막 줄을 싣는다)
  n="$( { grep -c 'RDLEAK-SENTINEL-9f3a2b' "$sf" 2>/dev/null || true; } | tr -d ' ' )"
  [ -n "$n" ] || n=0
  [ "$n" -eq 0 ] \
    && pass "케이스 31b: 최종 상태 파일에 sentinel 노출 없음" \
    || fail "케이스 31b: 상태 파일로 세션 밖 파일 내용 ${n}회 노출"

  # (c) 부재가 공허하지 않다 — heartbeat 가 실제로 발동했다
  beats="$( { grep -c '^\[review wait\]' "$err" 2>/dev/null || true; } | tr -d ' ' )"
  [ -n "$beats" ] || beats=0
  [ "$beats" -ge 2 ] \
    && pass "케이스 31c: heartbeat 경로를 실제로 지남 (${beats}회)" \
    || fail "케이스 31c: heartbeat 미발동 (${beats}회) — 노출 부재 판정이 공허해짐"

  # (d) 두 보고 경로가 **우리 inode** 를 읽었다
  { grep -q 'RDLOGLINE-039' "$err" 2>/dev/null; } \
    && pass "케이스 31d: 로그 보고가 원래 inode 내용을 사용 (fd 채널 동작)" \
    || fail "케이스 31d: 원래 inode 의 로그 줄이 보고되지 않음 — $( { cat "$err" 2>/dev/null || true; } | tr '\n' '|' )"

  # (e) last message 도 fd 로 읽혔다 (경로가 교체된 뒤에도 원래 inode 내용)
  { grep -q 'RDLASTMSG-OK' "$err" 2>/dev/null; } \
    && pass "케이스 31e: last message 를 fd 로 읽어 정상 보고" \
    || fail "케이스 31e: last message 보고 누락 (fd 읽기 회귀)"

  # (f) 세션 밖 파일은 제자리에 그대로 남는다
  if [ -f "$sentinel" ] && [ "$( { cat "$sentinel" 2>/dev/null || true; } )" = "RDLEAK-SENTINEL-9f3a2b" ]; then
    pass "케이스 31f: 세션 밖 파일 내용·위치 보존"
  else
    fail "케이스 31f: 세션 밖 파일이 변경·이동됨"
  fi

  rm -rf "$sandbox" "$out_dir"
}

# ===========================================================================
# 케이스 32: codex 종료 후 진단 읽기 지연에도 뒤늦은 마커로 오분류하지 않는다
#            (final diff review 008턴 Important 1)
#   `wait "$codex_pid"` 복귀 시점에 codex 는 이미 (턴 미완료 상태로) 자체 종료했다.
#   구 코드는 watchdog 을 kill 하기 **전에** 로그 tail·last message 를 읽었으므로, 그
#   읽기가 느려지면 그 사이 watchdog 이 계속 tick 하며 codex 생존 여부와 무관하게 cap
#   도달 시 마커를 썼다 — 실제로는 조기 종료인데 "타임아웃" 으로 오분류(rc=124)됐다.
#   이 케이스는 `tail`(로그·last-message 읽기가 경유하는 유일한 외부 명령)을 PATH 로
#   가로채 확률에 기대지 않고 그 지연을 **결정적으로** 재현한다 — mock codex 는 cap
#   보다 훨씬 이전에 턴 파일 없이 자체 종료하므로, 이 지연이 없으면 애초에 cap 에
#   도달할 수 없다. 수정 전 어댑터로 이 fixture 를 겨누면 rc=124 가 나옴을 별도로
#   확인했다(final-diff-review-fix-4 작업 리포트 참조).
#   판정: ① rc=1(조기 종료) — rc=124(오분류 타임아웃) 아님 ② "턴 완료 전에 종료" 보고
#         ③ "타임아웃" 오분류 문구 없음
# ===========================================================================
run_case32() {
  local sandbox expected_turn mock_bin wrap_dir real_tail rc=0 out
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: cap(1초)에 한참 못 미치는 0.2초 만에, 턴 파일 없이 자체 종료한다.
  mock_bin="$(setup_mock "$sandbox" "sleep 0.2; exit 1")"

  # tail 을 PATH 로 가로채 codex 종료 후 진단 읽기(로그 tail·fd 3 last-message 읽기)만
  # 지연시킨다. 실제 tail 경로는 PATH 를 바꾸기 전에 미리 확인해 둔다(환경마다
  # busybox/GNU 등 위치가 다를 수 있어 하드코딩하지 않는다).
  real_tail="$(command -v tail)"
  wrap_dir="$sandbox/wrap"
  mkdir -p "$wrap_dir"
  cat > "$wrap_dir/tail" <<WRAPEOF
#!/usr/bin/env bash
if [ -n "\${RD_TEST_DIAG_DELAY:-}" ]; then
  sleep "\${RD_TEST_DIAG_DELAY}"
fi
exec "$real_tail" "\$@"
WRAPEOF
  chmod +x "$wrap_dir/tail"

  out="$(
    PATH="$wrap_dir:$PATH" \
    RD_TEST_DIAG_DELAY=2 \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=1 RD_REVIEW_IDLE_TIMEOUT=600 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  [ "$rc" -eq 1 ] \
    && pass "케이스 32a: 진단 읽기 지연에도 오분류 없이 rc=1 (조기 종료)" \
    || fail "케이스 32a: 기대 rc=1(조기 종료) — 실제 rc=$rc (124 면 뒤늦은 마커로 오분류 회귀)"

  echo "$out" | grep -q '턴 완료 전에 종료' \
    && pass "케이스 32b: 조기 종료를 사실대로 보고" \
    || fail "케이스 32b: 조기 종료 보고 누락 — $out"

  echo "$out" | grep -q '타임아웃' \
    && fail "케이스 32c: 조기 종료를 타임아웃으로 오분류함 — $out" \
    || pass "케이스 32c: 타임아웃 오분류 문구 없음"

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
echo "=== 회귀 테스트 — writable surface 세션 하위 폐쇄 (codex-adapter-writable-root) ==="
echo ""

run_case16

echo ""
echo "=== 회귀 테스트 — 환경변수 해석 (review-turn-timeout-too-short Task 1) ==="
echo ""

run_case17

echo ""
echo "=== 회귀 테스트 — codex 출력 관측 기반 유휴 판정 (review-turn-timeout-too-short Task 2) ==="
echo ""

run_case18
run_case19
run_case20

echo ""
echo "=== 회귀 테스트 — heartbeat·상태 파일 (review-turn-timeout-too-short Task 3) ==="
echo ""

run_case21

echo ""
echo "=== 회귀 테스트 — 활동 관측 fd 채널·유효 상한 (review-turn-timeout-too-short Task 4 / 턴 006 Critical 1) ==="
echo ""

run_case22
run_case24

echo ""
echo "=== 회귀 테스트 — 타임아웃 메시지 오염 단정 금지 (review-turn-timeout-too-short Task 5) ==="
echo ""

run_case23

echo ""
echo "=== 회귀 테스트 — 상태 snapshot 초기화·관리 키 단일 (final diff review Important 2) ==="
echo ""

run_case25

echo ""
echo "=== 회귀 테스트 — 상태 파일 쓰기 symlink 비추종 (final diff review Critical 1) ==="
echo ""

run_case26

echo ""
echo "=== 회귀 테스트 — 로그 최종 이동 실패 정직 보고 (final diff review Important 3) ==="
echo ""

run_case27

echo ""
echo "=== 회귀 테스트 — 산출물 수명 재설계 (final diff review 턴 004 Important 3·4) ==="
echo ""

run_case28
run_case29

echo ""
echo "=== 회귀 테스트 — 읽기 채널 fd 전용·안정 이름 수명 (final diff review 턴 006 Critical 1·Important 2) ==="
echo ""

run_case30
run_case31

echo ""
echo "=== 회귀 테스트 — 진단 읽기 지연에 의한 뒤늦은 마커 오분류 방지 (final diff review 008턴 Important 1) ==="
echo ""

run_case32

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
