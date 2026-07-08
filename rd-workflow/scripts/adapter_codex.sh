#!/usr/bin/env bash
# adapter_codex.sh — Codex CLI 어댑터 (background 실행 + watchdog+wait)
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
# WAIT_TIMEOUT: 대기 최대 시간(초). POLL_TIMEOUT 값이 설정돼 있으면 legacy 호환으로 수용.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-${POLL_TIMEOUT:-600}}"
SETTLE_DELAY=0.5       # 초 (턴 완료 후 flush 여유)
KILL_GRACE=3           # 초 (SIGTERM 후 대기)

session_dir="${SESSION_PATH}"
session_file="${session_dir}/SESSION.md"
turn_ready_file="${session_dir}/.turn_ready"
timeout_marker="${session_dir}/.wait_timeout"

# --- stale 산출물 정리 (재실행 방어) ---
rm -f "$turn_ready_file"
rm -f "$EXPECTED_TURN_FILE"
rm -f "$timeout_marker"

# --- 턴 완료 확인 (SESSION 단일 권위 — CHECKPOINT 비소비, spec §2 결정 2) ---
# 부정 조건("Reviewer가 아님") 금지 — malformed owner를 성공으로 오판.
# 허용 enum·Status를 양성(긍정) 조건으로 검증.
check_turn_complete() {
  [ -f "$EXPECTED_TURN_FILE" ] || return 1
  local owner status
  owner="$(extract_section "$session_file" "Current Owner" | trim_blank_lines)"
  case "$owner" in
    Author|User) ;;
    *) return 1 ;;
  esac
  status="$(extract_section "$session_file" "Status" | trim_blank_lines)"
  case "$status" in
    awaiting-author|awaiting-user) ;;
    *) return 1 ;;
  esac
  return 0
}

# --- Codex background 실행 ---
last_message_file="$(mktemp)"
chmod 600 "$last_message_file"

codex_pid=""
watchdog_pid=""
cleanup() {
  # watchdog 종료 및 reap
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  fi
  # codex 프로세스 종료
  if [ -n "$codex_pid" ] && kill -0 "$codex_pid" 2>/dev/null; then
    kill "$codex_pid" 2>/dev/null || true
    sleep "$KILL_GRACE"
    kill -0 "$codex_pid" 2>/dev/null && kill -9 "$codex_pid" 2>/dev/null || true
    wait "$codex_pid" 2>/dev/null || true
  fi
  # .wait_timeout 마커 정리 (cleanup 시점 제거)
  rm -f "$timeout_marker"
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

# --- 대기: watchdog + wait (폴링 루프 없음, spec §2 결정 1) ---
# 타임아웃 판정 = 마커 파일 원자 생성 (정본 계약 — kill -0 생존 추정 금지)
(
  sleep "$WAIT_TIMEOUT"
  # 타임아웃 마커를 tmp+mv로 원자적으로 생성
  tmpm="$(mktemp "${session_dir}/.wait_timeout.XXXXXX")" && mv "$tmpm" "$timeout_marker"
  kill "$codex_pid" 2>/dev/null || true
) &
watchdog_pid=$!

codex_rc=0
wait "$codex_pid" || codex_rc=$?

# watchdog 종료 및 reap
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
codex_pid=""

# 타임아웃 판정: 마커 파일 존재 여부로만 판정 (kill -0 생존 추정 금지)
timed_out=0
[ -f "$timeout_marker" ] && timed_out=1

if [ "$timed_out" -eq 1 ] && ! check_turn_complete; then
  echo "Codex 턴 완료 대기 타임아웃 (${WAIT_TIMEOUT}초)" >&2
  if [ -s "$last_message_file" ]; then
    echo "--- codex last message ---" >&2
    cat "$last_message_file" >&2
  fi
  exit 1
fi

if ! check_turn_complete; then
  echo "Codex 프로세스가 턴 완료 전에 종료되었습니다 (exit: ${codex_rc})" >&2
  if [ -s "$last_message_file" ]; then
    echo "--- codex last message ---" >&2
    cat "$last_message_file" >&2
  fi
  exit 1
fi

# --- 성공: flush 대기 + .turn_ready 마커 생성 ---
sleep "$SETTLE_DELAY"

echo "$EXPECTED_TURN_FILE" > "$turn_ready_file"

# 턴 파일 최종 확인
if [ ! -f "$EXPECTED_TURN_FILE" ]; then
  echo "Codex did not create the expected turn file: $EXPECTED_TURN_FILE" >&2
  exit 1
fi

exit 0
