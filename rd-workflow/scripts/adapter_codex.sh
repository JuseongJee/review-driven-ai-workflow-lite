#!/usr/bin/env bash
# adapter_codex.sh — Codex CLI 어댑터
# 환경변수: SESSION_PATH, PROMPT_FILE, EXPECTED_TURN_FILE,
#           TOOL_BIN, PROJECT_ROOT
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/review_common.sh"

codex_bin="${TOOL_BIN:-codex}"

if ! command -v "$codex_bin" &>/dev/null; then
  echo "Codex CLI를 찾을 수 없습니다: $codex_bin" >&2
  exit 1
fi

last_message_file="$(mktemp)"
chmod 600 "$last_message_file"
cleanup() { rm -f "$last_message_file"; }
trap cleanup EXIT

if ! "$codex_bin" --ask-for-approval never exec \
  --cd "$PROJECT_ROOT" \
  --sandbox workspace-write \
  --skip-git-repo-check \
  --output-last-message "$last_message_file" \
  - < "$PROMPT_FILE"; then
  echo "Codex CLI가 비정상 종료했습니다" >&2
  if [[ -s "$last_message_file" ]]; then
    echo "--- codex last message ---" >&2
    cat "$last_message_file" >&2
  fi
  exit 1
fi

# 턴 파일 생성 확인 (상세 검증은 라우터에서 수행)
if [[ ! -f "$EXPECTED_TURN_FILE" ]]; then
  echo "Codex did not create the expected turn file: $EXPECTED_TURN_FILE" >&2
  if [[ -s "$last_message_file" ]]; then
    echo "--- codex last message ---" >&2
    cat "$last_message_file" >&2
  fi
  exit 1
fi

exit 0
