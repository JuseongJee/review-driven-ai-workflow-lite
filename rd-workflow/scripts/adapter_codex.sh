#!/usr/bin/env bash
# adapter_codex.sh — Codex CLI 어댑터 (background 실행 + polling)
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

# --- 설정 ---
POLL_INTERVAL=3        # 초
POLL_TIMEOUT=600       # 초 (10분)
SETTLE_DELAY=0.5       # 초 (턴 완료 후 flush 여유)
KILL_GRACE=3           # 초 (SIGTERM 후 대기)

session_dir="${SESSION_PATH}"
session_file="${session_dir}/SESSION.md"
checkpoint_file="${session_dir}/CHECKPOINT.md"
turn_ready_file="${session_dir}/.turn_ready"

# --- stale 산출물 정리 (재실행 방어) ---
rm -f "$turn_ready_file"
rm -f "$EXPECTED_TURN_FILE"

# --- 턴 완료 확인 함수 ---
# 반환: 0=완료, 1=미완료
check_turn_complete() {
  [ -f "$EXPECTED_TURN_FILE" ] || return 1
  local owner
  owner="$(extract_section "$session_file" "Current Owner" | trim_blank_lines)"
  [ "$owner" != "Reviewer" ] || return 1
  # CHECKPOINT.md도 갱신되었는지 확인
  local suggested
  suggested="$(extract_section "$checkpoint_file" "Suggested Next Owner" | trim_blank_lines)"
  [ "$suggested" != "Reviewer" ] || return 1
  return 0
}

# --- Codex background 실행 ---
last_message_file="$(mktemp)"
chmod 600 "$last_message_file"

codex_pid=""
cleanup() {
  if [[ -n "$codex_pid" ]] && kill -0 "$codex_pid" 2>/dev/null; then
    kill "$codex_pid" 2>/dev/null || true
    sleep 1
    kill -0 "$codex_pid" 2>/dev/null && kill -9 "$codex_pid" 2>/dev/null || true
  fi
  rm -f "$last_message_file"
}
trap cleanup EXIT

"$codex_bin" --ask-for-approval never exec \
  --cd "$PROJECT_ROOT" \
  --sandbox workspace-write \
  --skip-git-repo-check \
  --output-last-message "$last_message_file" \
  - < "$PROMPT_FILE" &
codex_pid=$!

# --- Polling ---
elapsed=0

while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))

  # 조기 실패 감지: Codex 프로세스가 사라졌는지 확인
  if ! kill -0 "$codex_pid" 2>/dev/null; then
    if check_turn_complete; then
      # 정상 완료 (Codex가 스스로 종료 + 조건 충족)
      codex_pid=""
      break
    fi
    # 비정상 종료
    echo "Codex 프로세스가 턴 완료 전에 종료되었습니다 (PID: $codex_pid)" >&2
    if [ -s "$last_message_file" ]; then
      echo "--- codex last message ---" >&2
      cat "$last_message_file" >&2
    fi
    codex_pid=""
    exit 1
  fi

  # 턴 완료 조건 확인
  if check_turn_complete; then
    break
  fi
done

# --- 타임아웃 처리 ---
if [ "$elapsed" -ge "$POLL_TIMEOUT" ]; then
  echo "Codex 턴 완료 대기 타임아웃 (${POLL_TIMEOUT}초)" >&2
  if [ -s "$last_message_file" ]; then
    echo "--- codex last message ---" >&2
    cat "$last_message_file" >&2
  fi
  exit 1
fi

# --- 성공: flush 대기 + .turn_ready 마커 생성 + PID 정리 ---
sleep "$SETTLE_DELAY"

echo "$EXPECTED_TURN_FILE" > "$turn_ready_file"

# Codex PID 정리 (아직 살아있으면)
if [ -n "$codex_pid" ] && kill -0 "$codex_pid" 2>/dev/null; then
  kill "$codex_pid" 2>/dev/null || true
  sleep "$KILL_GRACE"
  if kill -0 "$codex_pid" 2>/dev/null; then
    kill -9 "$codex_pid" 2>/dev/null || true
  fi
  # wait로 zombie 방지
  wait "$codex_pid" 2>/dev/null || true
fi
codex_pid=""

# 턴 파일 최종 확인
if [ ! -f "$EXPECTED_TURN_FILE" ]; then
  echo "Codex did not create the expected turn file: $EXPECTED_TURN_FILE" >&2
  exit 1
fi

exit 0
