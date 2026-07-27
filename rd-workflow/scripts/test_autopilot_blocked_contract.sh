#!/usr/bin/env bash
# autopilot 무인 blocked 처리 계약이 SKILL.md/AUTONOMY.md 에 남아있는지 grep 회귀 검증한다.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AP="${ROOT}/rd-workflow/claude_skills/autopilot/SKILL.md"
AU="${ROOT}/rd-workflow/docs/flows/AUTONOMY.md"
fail=0
chk() { if grep -q "$2" "$1"; then echo "  ok  $3"; else echo "  FAIL $3 ($1)"; fail=1; fi; }
echo "== autopilot blocked 계약 회귀 =="
chk "$AP" 'status 를 `blocked` 로 기록'  "SKILL: FR status=blocked 기록"
chk "$AP" '중단 사유'                     "SKILL: 중단 사유 병기"
chk "$AP" 'Short Title `-`'              "SKILL: CURRENT_TASK Short Title reset"
chk "$AP" 'ralph_drain.sh'               "SKILL: ralph 진입점 명시"
chk "$AU" 'status 를 `blocked`'          "AUTONOMY: blocked status 기록 갱신"
chk "$AU" 'reset'                         "AUTONOMY: CURRENT_TASK reset 서술"
if [ "$fail" -ne 0 ]; then echo "test_autopilot_blocked_contract: FAIL"; exit 1; fi
echo "test_autopilot_blocked_contract: PASS"
