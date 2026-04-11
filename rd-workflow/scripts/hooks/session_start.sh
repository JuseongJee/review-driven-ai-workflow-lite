#!/usr/bin/env bash
# session_start.sh — 세션 시작 시 환경 확인
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROJECT_CONTEXT="${PROJECT_ROOT}/PROJECT_CONTEXT.md"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " AI Workflow (Lite) 세션 시작"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ! -f "$PROJECT_CONTEXT" ]]; then
  echo ""
  echo "WARNING: PROJECT_CONTEXT.md가 없습니다."
  echo "  프로젝트 설정을 먼저 완료하세요."
fi
