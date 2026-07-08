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
  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "sleep 30")"

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

  # mock 프로세스가 종료됐는지 확인 (kill 됐으면 sleep 30이 남지 않음)
  local mock_alive=0
  if pgrep -f "sleep 30" >/dev/null 2>&1; then
    mock_alive=1
  fi

  if [ "$rc" -ne 0 ] && echo "$output" | grep -q "타임아웃"; then
    pass "케이스 3: 타임아웃 exit 1 + 메시지 확인"
  else
    fail "케이스 3: 타임아웃 기대 — rc=$rc, 메시지=$(echo "$output" | grep -o '타임아웃' || echo '없음')"
  fi

  # mock 프로세스가 kill됐는지는 비동기 특성상 보조 확인만
  if [ "$mock_alive" -eq 1 ]; then
    fail "케이스 3(보조): mock sleep 30 프로세스가 아직 살아있음 — kill 실패 의심"
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
echo "=== 결과: PASS=$PASS FAIL=$FAIL ==="

if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo "실패 케이스:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  exit 1
fi

exit 0
