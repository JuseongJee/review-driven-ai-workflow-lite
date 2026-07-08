#!/usr/bin/env bash
# adapter_claude.sh — Claude Code CLI 어댑터 (self-review)
# 환경변수: SESSION_PATH, PROMPT_FILE, EXPECTED_TURN_FILE,
#           TOOL_BIN, PROJECT_ROOT,
#           SELF_REVIEW_WARNING (default: true)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/review_common.sh"

claude_bin="${TOOL_BIN:-claude}"

if ! command -v "$claude_bin" &>/dev/null; then
  echo "Claude CLI를 찾을 수 없습니다: $claude_bin" >&2
  exit 1
fi

# 셀프 리뷰 경고 (CLI 출력)
if [[ "${SELF_REVIEW_WARNING:-true}" == "true" ]]; then
  echo "⚠️  독립 리뷰어를 사용할 수 없어 Claude(self-review)로 fallback합니다." >&2
  echo "    셀프 리뷰는 독립성이 보장되지 않습니다." >&2
fi

# --model 옵션 (TOOL_MODEL이 있을 때만)
model_args=()
if [[ -n "${TOOL_MODEL:-}" ]]; then
  model_args=(--model "$TOOL_MODEL")
fi

# Claude CLI 실행
if ! "$claude_bin" -p ${model_args[@]+"${model_args[@]}"} \
  --allowedTools "Edit,Write,Read,Glob,Grep,Bash" \
  < "$PROMPT_FILE"; then
  echo "Claude CLI가 비정상 종료했습니다" >&2
  exit 1
fi

# 턴 파일 생성 확인
if [[ ! -f "$EXPECTED_TURN_FILE" ]]; then
  echo "Claude did not create the expected turn file: $EXPECTED_TURN_FILE" >&2
  exit 1
fi

# 셀프 리뷰 경고를 턴 파일 헤더에 삽입
if [[ "${SELF_REVIEW_WARNING:-true}" == "true" ]]; then
  local_tmp="$(mktemp)"
  chmod 600 "$local_tmp"
  {
    echo '> **⚠️ Self-Review Notice:** 이 턴은 독립 리뷰어 대신 Claude(self-review)가 작성했습니다. 독립성이 보장되지 않으므로 결과를 비판적으로 검토하세요.'
    echo ''
    cat "$EXPECTED_TURN_FILE"
  } > "$local_tmp"
  mv "$local_tmp" "$EXPECTED_TURN_FILE"
fi

exit 0
