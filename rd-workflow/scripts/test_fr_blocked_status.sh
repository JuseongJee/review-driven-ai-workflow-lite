#!/usr/bin/env bash
# test_fr_blocked_status.sh — blocked FR status 어휘가 정의처에 일관되게 반영됐는지 검증한다.
# FR status 는 skill-markdown 규약이므로 문서 일관성으로 검증한다 (런타임 로직 아님).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # rd-workflow/scripts → repo root

fail=0
must_contain() { # $1 파일  $2 grep패턴  $3 설명
  if grep -q "$2" "$1"; then echo "  ok  $3"; else echo "  FAIL $3 ($1)"; fail=1; fi
}
must_not_contain() {
  if grep -q "$2" "$1"; then echo "  FAIL $3 ($1)"; fail=1; else echo "  ok  $3"; fi
}

STATUS_MD="${ROOT}/rd-workflow/claude_skills/fr/status.md"
LIST_MD="${ROOT}/rd-workflow/claude_skills/fr/list.md"
FR_MD="${ROOT}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
AP_MD="${ROOT}/rd-workflow/claude_skills/autopilot/SKILL.md"

echo "== blocked 어휘 일관성 =="
must_contain "$STATUS_MD" '`blocked`' "status.md 허용값에 blocked"
must_contain "$LIST_MD" '항목만 추린다' "list.md 기본 목록 active-only 유지 (blocked 미포함)"
must_contain "$LIST_MD" 'set-aside' "list.md set-aside 요약 푸터 존재"
must_contain "$FR_MD" '`blocked`' "FUTURE_REQUESTS.md 상태 값에 blocked"
# auto-pick 화이트리스트는 여전히 validated/ready-for-request 만 (blocked 자동 제외 보장)
must_contain "$AP_MD" 'validated / ready-for-request 후보' "auto-pick 화이트리스트 유지"
must_not_contain "$AP_MD" 'validated / ready-for-request / blocked' "auto-pick 에 blocked 미포함"
# Finding 1: 파일 분리 문서가 blocked 인덱스 잔류를 명시해 상태값 목록과 모순되지 않는지
if grep -A4 '## 파일 분리' "$FR_MD" | grep -q 'blocked'; then echo "  ok  파일 분리에 blocked 잔류 명시"; else echo "  FAIL 파일 분리에 blocked 미명시 ($FR_MD)"; fail=1; fi
PRI_MD="${ROOT}/rd-workflow/claude_skills/fr/pri.md"
PUSH_MD="${ROOT}/rd-workflow/claude_skills/fr/push.md"
must_contain "$PRI_MD" 'blocked' "pri.md 에 blocked set-aside 제외 명시"
must_contain "$PUSH_MD" 'blocked' "push.md 에 blocked set-aside 제외 명시"

if [ "$fail" -ne 0 ]; then echo "test_fr_blocked_status: FAIL"; exit 1; fi
echo "test_fr_blocked_status: PASS"
