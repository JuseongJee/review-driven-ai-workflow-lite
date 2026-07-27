#!/usr/bin/env bash
# test_autopilot_headless.sh — autopilot_headless.sh 의 outcome→exit-code 매핑 단위 테스트.
# 라이브 claude 불필요: RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 로 claude -p 호출을 생략하고
# outcome 파일을 심어 exit code 를 단언한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/autopilot_headless.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
assert_exit() {
  local desc="$1" outcome="$2" expected="$3"
  local of="${TMP}/outcome"
  printf '%s\n' "$outcome" > "$of"
  RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$of" \
    bash "$WRAPPER" >/dev/null 2>&1
  local code=$?
  if [[ "$code" == "$expected" ]]; then
    echo "  PASS: ${desc} (exit ${code})"
  else
    echo "  FAIL: ${desc} — expected ${expected}, got ${code}" >&2
    FAIL=1
  fi
}

assert_exit "completed → 0"       "completed"             0
assert_exit "resume → 10"         "resume"                10
assert_exit "blocked → 20"        "blocked:review-50turn" 20
assert_exit "queue-empty → 30"    "queue-empty"           30
assert_exit "unknown → 40"        "garbage"               40

# 빈 outcome 파일 → 40
empty_of="${TMP}/empty"; : > "$empty_of"
RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$empty_of" \
  bash "$WRAPPER" >/dev/null 2>&1
if [[ $? == 40 ]]; then echo "  PASS: 빈 outcome → 40"; else echo "  FAIL: 빈 outcome → 40" >&2; FAIL=1; fi

# 존재하지 않는 outcome 경로 → 40 (harness-error 핵심 경로 — 세션 크래시/무기록)
missing_of="${TMP}/does-not-exist"
RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$missing_of" \
  bash "$WRAPPER" >/dev/null 2>&1
if [[ $? == 40 ]]; then echo "  PASS: 부재 outcome → 40"; else echo "  FAIL: 부재 outcome → 40" >&2; FAIL=1; fi

if [[ $FAIL == 0 ]]; then echo "test_autopilot_headless: PASS"; exit 0
else echo "test_autopilot_headless: FAIL" >&2; exit 1; fi
