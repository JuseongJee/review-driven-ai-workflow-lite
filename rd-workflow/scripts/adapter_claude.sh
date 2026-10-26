#!/usr/bin/env bash
# adapter_claude.sh — Claude Code CLI 어댑터 (self-review, background 실행 + watchdog+wait)
# 환경변수: SESSION_PATH, PROMPT_FILE, EXPECTED_TURN_FILE,
#           TOOL_BIN, PROJECT_ROOT,
#           SELF_REVIEW_WARNING (default: true)
#
# codex 와 같은 대기 계약(review_wait.sh 공유)을 쓴다. codex 와 다른 것은 호출 형태
# (stream-json 활동 신호)·표시 포맷터(claude_format_line)·last-message 부재·
# TERM 무시 리더에 대한 kill escalation(RW_KILL_ESCALATE) 뿐이다.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/review_common.sh"
source "${script_dir}/review_wait.sh"

RW_TOOL_LABEL=claude

# 최종 상태 파일에 남길 **종료 사유**. 엔진은 이 값이 비어 있지 않을 때만 `outcome:` 필드를
# 렌더링하므로 codex 의 상태 파일은 영향을 받지 않는다.
# 기본값이 `unknown` 인 이유: 진행 중 snapshot 은 정상·타임아웃·중단 어느 경로에서나 같은
# 모습이라, 사유를 적지 않으면 터미널 출력을 놓친 사용자가 **디스크만으로는 무슨 일이
# 있었는지 알 수 없다.** 사유를 확정하지 못한 채 발행되는 경우까지 정직하게 드러낸다.
RW_OUTCOME="unknown"
# 사유의 **종류**. RW_OUTCOME 은 사람이 읽을 문장이고 이 변수는 기계 판정용이다 —
# 문자열 비교로 분기하면 문구를 다듬는 순간 조용히 깨진다.
outcome_kind="unknown"


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

# --- 설정 ---
# 절대 상한은 codex 와 동일(7200). 유휴 임계는 900 — 2026-09-22 실측에서 claude 의
# 최대 무출력 구간은 71.67초였고, 그 침묵은 hang 이 아니라 **마지막 메시지를 생성하는
# 구간**이었다(stream-json 은 메시지 단위로 이벤트를 낸다). 침묵 길이가 생성물 길이에
# 비례해 커지므로 관측값이 상한의 추정치가 되지 못한다. 그래서 codex(123초 → 600, 4.9배)
# 보다 배수를 크게 잡았다(71.67초 → 900, 12.6배).
# **이것은 확률적 완화이지 증명이 아니다** — 긴 Write 도구 호출 하나가 900초를 넘으면
# 일하는 리뷰어를 죽인다. 회수 수단은 WAIT_TIMEOUT 과 RD_REVIEW_IDLE_TIMEOUT=0 이다.
DEFAULT_ABS_CAP=7200
DEFAULT_IDLE=900
RW_TICK=1

RW_ABS_CAP="$(rw_resolve_abs_cap "$DEFAULT_ABS_CAP")"
RW_IDLE="$(rw_resolve_idle "$DEFAULT_IDLE")"
RW_FALLBACK_CAP="$(rw_resolve_tunable RD_REVIEW_OBSERVER_FALLBACK_CAP 600)"
RW_HEARTBEAT="$(rw_resolve_tunable RD_REVIEW_HEARTBEAT 60)"
RW_LINE_FORMATTER=claude_format_line
RW_KILL_ESCALATE=1          # TERM 을 무시하는 리더도 유한 시간에 회수한다 (codex 는 켜지 않음)
RW_KILL_GRACE=3

if [ "$RW_IDLE" -gt 0 ] && [ "$RW_IDLE" -gt "$RW_ABS_CAP" ]; then
  echo "경고: 유휴 임계(${RW_IDLE}초)가 절대 상한(${RW_ABS_CAP}초)보다 큽니다 — 유휴 판별이 발동하지 않습니다." >&2
fi
echo "wait config: cap=${RW_ABS_CAP}s idle=${RW_IDLE}s" >&2

# stream-json 한 줄을 사람이 읽을 표시로 줄인다. 원본 로그는 그대로 남고 활동 관측도
# 영향받지 않는다 — 이것은 heartbeat 표시 전용이다.
# 이 변환이 없으면 긴 text/Write 입력 한 줄이 수십 KB JSON 덩어리로 화면에 쏟아져
# 경과·로그 경로 안내를 가린다(--include-partial-messages 를 기각한 근거가 무너진다).
claude_format_line() {
  local l="$1" out
  case "$l" in
    *'"type":"result"'*)                         out='result' ;;
    *'"type":"system"'*'"subtype":"init"'*)      out='system: init' ;;
    *'"type":"system"'*)                         out='system' ;;
    *'"type":"user"'*)                           out='user: tool_result' ;;
    *'"type":"assistant"'*'"type":"tool_use"'*)
      local n="${l##*'"name":"'}"; n="${n%%'"'*}"
      out="assistant: tool_use ${n}" ;;
    *'"type":"assistant"'*'"type":"thinking"'*)  out='assistant: thinking' ;;
    *'"type":"assistant"'*'"type":"text"'*)      out='assistant: text' ;;
    *) out="$l" ;;   # 미분류 — 아래에서 자기가 절단한다
  esac
  # **빈 문자열을 돌려주지 않는다.** 엔진은 빈 값을 받으면 원본으로 떨어지므로 절단이
  # 무효가 된다. 생략 부호를 포함해 200자 이하로 맞춘다(199 + `…`).
  if [ "${#out}" -gt 200 ]; then
    printf '%s…' "${out:0:199}"
  else
    printf '%s' "$out"
  fi
}

session_dir="${SESSION_PATH}"

RW_SESSION_DIR="$session_dir"
RW_LOG_STABLE="${RW_SESSION_DIR}/.claude_output.log"
RW_STATUS_FILE="${RW_SESSION_DIR}/.review_wait_status"
SNAP_DELIM='=== rd-review-wait-snapshot ==='
RW_SNAP_DELIM="$SNAP_DELIM"

# 안정 이름의 존재가 곧 「이번 실행이 끝났다」를 뜻하게 하는 계약. 이전 턴이 발행한
# 파일이 남아 있으면 실행 중에도 그것이 현재 상태처럼 보인다.
rm -f "$EXPECTED_TURN_FILE"
if [ ! -d "$RW_LOG_STABLE" ] || [ -L "$RW_LOG_STABLE" ]; then
  rm -f "$RW_LOG_STABLE" 2>/dev/null || true
fi
if [ ! -d "$RW_STATUS_FILE" ] || [ -L "$RW_STATUS_FILE" ]; then
  rm -f "$RW_STATUS_FILE" 2>/dev/null || true
fi

# --- 쓰기 채널 확보 (claude spawn 전) — 실패는 시작 실패 ---
RW_LOG_PATH="$(mktemp "${RW_SESSION_DIR}/.claude_output.XXXXXX")" || {
  echo "claude 출력 로그를 만들 수 없습니다: ${RW_SESSION_DIR}" >&2; exit 1; }
chmod 600 "$RW_LOG_PATH"
echo "claude 출력 로그: ${RW_LOG_PATH}  (진행 중 확인: tail -f '${RW_LOG_PATH}')" >&2

status_stream="$(mktemp "${RW_SESSION_DIR}/.review_wait_status.XXXXXX")" || {
  echo "대기 상태 스트림 파일을 만들 수 없습니다: ${RW_SESSION_DIR}" >&2
  exit 1
}
chmod 600 "$status_stream" 2>/dev/null || true
RW_STATUS_STREAM_PATH="$status_stream"
status_stream_fd_open=0
if ! exec 8>> "$status_stream"; then
  echo "대기 상태 스트림 fd open 실패: ${status_stream}" >&2
  exit 1
fi
status_stream_fd_open=1
RW_STATUS_FD_OPEN="$status_stream_fd_open"
RW_STATUS_FD=8
echo "대기 상태 스트림: ${status_stream}  (안정 경로 ${RW_STATUS_FILE} 는 종료 후에 발행됩니다)" >&2

# 타임아웃 마커 — **안정 이름을 쓰지 않는다.** claude spawn 전에 mktemp 로 배타 생성하고
# 쓰기 fd 7·읽기 fd 6 을 그 자리에서 연다(codex 와 동일 계약 — adapter_codex.sh:451-475).
timeout_marker=""
marker_write_fd_open=0
marker_read_fd_open=0
timeout_marker="$(mktemp "${RW_SESSION_DIR}/.wait_timeout.XXXXXX")" || {
  echo "타임아웃 마커를 만들 수 없습니다: ${RW_SESSION_DIR}" >&2
  exit 1
}
chmod 600 "$timeout_marker" 2>/dev/null || true
if ! exec 7>> "$timeout_marker"; then
  echo "타임아웃 마커 쓰기 fd open 실패: $timeout_marker" >&2
  exit 1
fi
marker_write_fd_open=1
if ! exec 6< "$timeout_marker"; then
  echo "타임아웃 마커 읽기 fd open 실패: $timeout_marker" >&2
  exit 1
fi
marker_read_fd_open=1
RW_MARKER_FD=7

# 타이머 — watchdog 이 sleep 자식 없이 fd + read -t 로 tick 을 만든다.
watchdog_dir=""
watchdog_fd_open=0
watchdog_dir="$(mktemp -d "${TMPDIR:-/tmp}/rd-watchdog.XXXXXX")" || { echo "adapter_claude: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$watchdog_dir" && -d "$watchdog_dir" ]] || { echo "adapter_claude: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
watchdog_fifo="${watchdog_dir}/timer"
if ! mkfifo "$watchdog_fifo" 2>/dev/null; then
  echo "watchdog 타이머 fifo 생성 실패: $watchdog_fifo" >&2
  exit 1
fi
if ! exec 9<> "$watchdog_fifo"; then
  echo "watchdog 타이머 fifo open 실패: $watchdog_fifo" >&2
  exit 1
fi
watchdog_fd_open=1
RW_TIMER_FD=9

rw_status_init_snapshot "$RW_STATUS_FD" "$RW_ABS_CAP" "$RW_IDLE"

# --- 읽기 채널 확보 (기능 저하만, 시작 실패 아님) ---
log_read_fd_open=0
if exec 4< "$RW_LOG_PATH"; then log_read_fd_open=1
else echo "경고: claude 로그 읽기 fd(부모)를 열 수 없습니다 — 종료 후 최근 출력을 보고하지 않습니다." >&2; fi

log_watch_fd_open=0
if exec 5< "$RW_LOG_PATH"; then log_watch_fd_open=1
else echo "경고: claude 로그 관측 fd 를 열 수 없습니다 — 활동 관측기를 고장으로 간주합니다." >&2; fi
RW_OBSERVER_OK="$log_watch_fd_open"
RW_LOG_FD=5

claude_pid=""
claude_pgid=""
watchdog_pid=""
cleanup_done=0
group_dead=1
log_final=""

# 신호 trap 은 EXIT 와 분리하고 종료 코드를 명시한다. `trap cleanup EXIT HUP INT TERM`
# 한 줄이면 cleanup 뒤 **실행이 계속되어** 129/130/143 계약이 깨진다(bash 3.2.57 실측).
# background job 에서는 SIGINT 가 무시 disposition 을 상속해 trap 이 무효다(POSIX).
# TERM·HUP 은 background 에서도 정상 전달된다. SIGKILL 은 트랩 불가다.
cleanup() {
  [ "$cleanup_done" -eq 1 ] && return 0
  cleanup_done=1

  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  fi
  if [ "$watchdog_fd_open" -eq 1 ]; then
    { exec 9<&-; } 2>/dev/null || true
    watchdog_fd_open=0
  fi
  if [ -n "$watchdog_dir" ]; then
    rm -f "${watchdog_dir}/timer" 2>/dev/null || true
    rmdir "${watchdog_dir}/timer" 2>/dev/null || true
    rmdir "$watchdog_dir" 2>/dev/null || true
    watchdog_dir=""
  fi

  # process group 종료 — 리더 생존과 독립. TERM → KILL_GRACE → KILL.
  if [ -n "$claude_pgid" ] && rw_group_alive "$claude_pgid"; then
    kill -- -"$claude_pgid" 2>/dev/null || true
    sleep "${RW_KILL_GRACE:-3}"
    if rw_group_alive "$claude_pgid"; then
      kill -9 -- -"$claude_pgid" 2>/dev/null || true
    fi
  elif [ -z "$claude_pgid" ] && [ -n "$claude_pid" ] && kill -0 "$claude_pid" 2>/dev/null; then
    kill "$claude_pid" 2>/dev/null || true
    sleep "${RW_KILL_GRACE:-3}"
    kill -0 "$claude_pid" 2>/dev/null && kill -9 "$claude_pid" 2>/dev/null || true
  fi
  if [ -n "$claude_pid" ]; then
    wait "$claude_pid" 2>/dev/null || true
  fi

  # --- 산출물 발행 (안정 이름) — process group 종료 확인 후 1회 ---
  group_dead=1
  local log_ok=no log_reason="" log_recovery=""
  if [ -n "$claude_pgid" ] && rw_group_alive "$claude_pgid"; then
    group_dead=0
  fi

  if [ "$group_dead" -ne 1 ]; then
    echo "알림: claude process group(${claude_pgid})이 아직 살아 있어 산출물을 안정 경로로 발행하지 않았습니다." >&2
    echo "      claude 출력 로그(임시 경로): ${RW_LOG_PATH}" >&2
    echo "      대기 상태 스트림: ${status_stream}" >&2
    log_reason="claude-group-alive"
    log_final="$RW_LOG_PATH"
  elif [ -n "${RW_LOG_PATH:-}" ]; then
    if [ -L "$RW_LOG_PATH" ]; then
      rm -f "$RW_LOG_PATH" 2>/dev/null || true
      echo "알림: claude 출력 로그 경로가 symlink 로 대체되어 보존하지 못했습니다 (${RW_LOG_PATH})." >&2
      echo "      원본을 회수할 수 없으므로 회수 경로를 보고하지 않습니다." >&2
      log_reason="log-source-replaced"
      log_final="log-source-replaced"
    elif [ -f "$RW_LOG_PATH" ]; then
      if rw_mv_target_prepare "$RW_LOG_STABLE" \
         && mv -f "$RW_LOG_PATH" "$RW_LOG_STABLE" 2>/dev/null \
         && [ ! -L "$RW_LOG_STABLE" ] && [ -f "$RW_LOG_STABLE" ] \
         && [ ! -e "$RW_LOG_PATH" ]; then
        log_ok=yes
        log_final="$RW_LOG_STABLE"
      else
        if [ -L "$RW_LOG_STABLE" ]; then rm -f "$RW_LOG_STABLE" 2>/dev/null || true; fi
        echo "알림: claude 출력 로그를 안정 경로로 옮기지 못했습니다 — 안정 경로: ${RW_LOG_STABLE}" >&2
        if [ -f "$RW_LOG_PATH" ] && [ ! -L "$RW_LOG_PATH" ]; then
          echo "      로그는 임시 경로에 남아 있습니다(회수 가능): ${RW_LOG_PATH}" >&2
          log_reason="log-move-failed"
          log_recovery="$RW_LOG_PATH"
          log_final="$RW_LOG_PATH"
        else
          echo "      임시 경로의 원본도 남아 있지 않아 회수할 수 없습니다 (${RW_LOG_PATH})." >&2
          log_reason="log-move-failed-source-lost"
          log_final="(없음)"
        fi
      fi
    else
      echo "알림: claude 출력 로그가 실행 중 사라져 보존하지 못했습니다 (${RW_LOG_PATH})." >&2
      log_reason="log-vanished-during-run"
      log_final="(없음)"
    fi
  fi

  # --- 사유 확정 (발행 직전) ---
  # 여기는 **그룹 종료를 확인한 뒤**이므로 턴 파일을 쓸 주체가 더 없다 — 즉 턴 파일의
  # 존재 여부가 이 시점에 확정된다. 존재 확인은 읽기일 뿐이라 「후처리는 writer 정리
  # 뒤에」 계약을 어기지 않는다(헤더 삽입 같은 쓰기는 그대로 cleanup 뒤에 남는다).
  if [ "$outcome_kind" = "ok-pending" ]; then
    if [ "$group_dead" -eq 1 ] && [ -f "$EXPECTED_TURN_FILE" ]; then
      outcome_kind=ok
      RW_OUTCOME="ok: claude exit 0, 턴 파일 확인됨"
    elif [ "$group_dead" -ne 1 ]; then
      outcome_kind=group-alive
      RW_OUTCOME="group-alive: claude exit 0 이었으나 process group 이 남아 후처리를 하지 않음 (어댑터 exit 1)"
    else
      outcome_kind=turn-missing
      RW_OUTCOME="turn-missing: claude 는 exit 0 이었으나 턴 파일을 만들지 않음 (어댑터 exit 1)"
    fi
  fi

  if [ "$group_dead" -eq 1 ]; then
    if rw_publish_final_status "$log_ok" "$log_reason" "$log_recovery"; then
      rm -f "$status_stream" 2>/dev/null || true
    else
      echo "알림: 대기 상태를 안정 경로(${RW_STATUS_FILE})로 발행하지 못했습니다." >&2
      echo "      진행 중 상태는 스트림에 남아 있습니다: ${status_stream}" >&2
    fi
  fi

  if [ "$log_read_fd_open" -eq 1 ]; then
    { exec 4<&-; } 2>/dev/null || true
    log_read_fd_open=0
  fi
  if [ "$log_watch_fd_open" -eq 1 ]; then
    { exec 5<&-; } 2>/dev/null || true
    log_watch_fd_open=0
  fi
  if [ "$status_stream_fd_open" -eq 1 ]; then
    { exec 8>&-; } 2>/dev/null || true
    status_stream_fd_open=0
  fi
  if [ "$marker_write_fd_open" -eq 1 ]; then
    { exec 7>&-; } 2>/dev/null || true
    marker_write_fd_open=0
  fi
  if [ "$marker_read_fd_open" -eq 1 ]; then
    { exec 6<&-; } 2>/dev/null || true
    marker_read_fd_open=0
  fi
  if [ -n "$timeout_marker" ]; then
    rm -f "$timeout_marker" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# 신호 경로도 사유를 남긴다 — 진행 중 snapshot 이 최종 결과로 오인되지 않게 한다.
trap 'outcome_kind=signal; RW_OUTCOME="signal: SIGHUP (exit 129) — 외부 중단"; cleanup; exit 129' HUP
trap 'outcome_kind=signal; RW_OUTCOME="signal: SIGINT (exit 130) — 외부 중단"; cleanup; exit 130' INT
trap 'outcome_kind=signal; RW_OUTCOME="signal: SIGTERM (exit 143) — 외부 중단"; cleanup; exit 143' TERM

# --- spawn — background + 독립 pgid + 내부 fd 닫아 전달 ---
model_args=()
[[ -n "${TOOL_MODEL:-}" ]] && model_args=(--model "$TOOL_MODEL")

# stream-json 으로 바꾸는 이유는 활동 신호다 — 현행 `-p` 는 종료 직전까지 아무 출력도
# 내지 않아(실측: 29.83초 전 구간 무출력) 유휴 판별이 불가능하다.
# `--include-partial-messages` 는 쓰지 않는다: 침묵은 3.90초로 줄지만 이벤트가 46배,
# 로그가 19배(580KB/80초)로 늘고 heartbeat 의 마지막 줄이 토큰 델타 조각이 된다.
# 미지원 CLI 를 만나도 **조용히 옛 형태로 되돌리지 않는다** — 진단이 숨는다.
set -m
"$claude_bin" -p ${model_args[@]+"${model_args[@]}"} \
  --output-format stream-json --verbose \
  --allowedTools "Edit,Write,Read,Glob,Grep,Bash" \
  < "$PROMPT_FILE" > "$RW_LOG_PATH" 2>&1 4<&- 5<&- 6<&- 7>&- 8>&- 9>&- &
claude_pid=$!
set +m
RW_TARGET_PID="$claude_pid"
claude_pgid="$(rw_acquire_pgid "$claude_pid")"
RW_TARGET_PGID="$claude_pgid"

( rw_watchdog_loop ) &
watchdog_pid=$!

claude_rc=0
wait "$claude_pid" || claude_rc=$?

# watchdog 을 **진단 읽기보다 먼저** 죽이고 reap 한다 (cleanup 도 멱등하게 같은 일을 한다) —
# 그러지 않으면 claude 가 스스로 종료한 뒤에 watchdog 이 cap/idle 에 도달해 마커를 써서,
# 조기 실패가 타임아웃으로 오분류된다. 진짜 타임아웃이면 마커는 kill 이전에 이미 쓰였으므로
# 훼손되지 않는다.
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
# 리더는 위 `wait "$claude_pid"` 로 이미 reap 됐다. cleanup() 은 EXIT trap 경로에서도
# 호출되므로(멱등 가드로 중복 실행은 막힘), 여기서 pid 를 비워 codex 와 같은 계약을
# 지킨다 — cleanup 의 PID fallback 분기(`kill -0 "$claude_pid"`)가 이미 죽은 pid 를
# 다시 건드리지 않게 한다. 그룹 종료는 claude_pgid 로 하므로 이 값을 몰라도 무방하다.
claude_pid=""

# --- ① 마커·로그 tail 을 열린 fd 에서 변수로 확보 (cleanup 이 fd 를 닫기 전에) ---
marker=""
if [ "$marker_read_fd_open" -eq 1 ]; then
  IFS= read -r marker <&6 || true
fi
log_tail=""
if [ "$log_read_fd_open" -eq 1 ]; then
  log_tail="$( { tail -n 20 <&4 2>/dev/null || true; } )"
fi

# --- ①-b 종료 사유 확정 — cleanup 이 발행하기 **전에** 정한다 ---
# 마커와 rc 는 위에서 이미 확보했으므로 여기서 사유가 결정된다. 이 값이 상태 파일의
# `outcome:` 으로 남아, 화면을 놓친 사용자도 디스크만으로 idle/cap/정상/실패를 구별한다.
if [ -n "$marker" ]; then
  _oc_reason="${marker%% *}"; _oc_rest="${marker#* }"
  _oc_cap="${_oc_rest%% *}"; _oc_obs="${_oc_rest##* }"
  outcome_kind=timeout
  RW_OUTCOME="timeout: ${_oc_reason} (유효 상한 ${_oc_cap}s, 관측기 ${_oc_obs}, exit 124)"
elif [ "$claude_rc" -ne 0 ]; then
  outcome_kind=cli-failed
  RW_OUTCOME="cli-failed: claude 종료 코드 ${claude_rc} (어댑터 exit 1)"
else
  # **잠정값이다.** CLI 가 0 으로 끝나도 턴 파일을 만들지 않았으면 어댑터는 실패이며,
  # 그 사실은 writer 가 모두 정리된 뒤에야 확정할 수 있다. cleanup 이 발행 직전에
  # 확정한다 — 여기서 `ok` 로 못박으면 턴 생성 실패가 성공으로 기록된다.
  outcome_kind=ok-pending
  RW_OUTCOME="ok: claude 정상 종료 (exit 0)"
fi

# --- ② cleanup 명시 호출 — 최종화는 이 한 자리가 소유 ---
# **명령 치환 안에서 부르지 않는다** — 서브셸에서 실행되면 부모의 cleanup_done 플래그와
# 결과 변수(log_final·group_dead)가 갱신되지 않아 멱등성이 깨져 중복 발행이 난다.
cleanup

# --- ③ 판정 — 마커 우선, 그 다음 rc ---
if [ -n "$marker" ]; then
  reason="${marker%% *}"; rest="${marker#* }"
  eff_cap="${rest%% *}"; observer_state="${rest##* }"
  case "$reason" in
    idle) echo "리뷰 턴이 유휴 임계(${RW_IDLE}초)를 넘겨 종료되었습니다." >&2 ;;
    cap)  echo "리뷰 턴이 유효 상한(${eff_cap}초)에 도달해 종료되었습니다." >&2 ;;
    *)    echo "리뷰 턴 대기 타임아웃 (사유 불명 — 마커 내용: '${marker}')" >&2 ;;
  esac
  # 관측기가 고장나면 유효 상한이 절대 상한보다 조여진다. 사유는 `cap` 이지만
  # **절대 상한 도달이라고 말하지 않는다** — codex 가 겪은 거짓 진단을 되풀이하지 않는다.
  [ "$observer_state" = failed ] && \
    echo "    활동 관측기가 고장나 유효 상한이 절대 상한(${RW_ABS_CAP}초)보다 조여졌습니다." >&2
  echo "    claude 출력 로그: ${log_final}" >&2
  [ -n "$log_tail" ] && { echo "    최근 출력:" >&2; printf '%s\n' "$log_tail" | sed 's/^/          /' >&2; }
  exit 124
fi

if [ "$claude_rc" -ne 0 ]; then
  echo "Claude CLI가 비정상 종료했습니다 (exit ${claude_rc})" >&2
  echo "    최근 출력:" >&2
  printf '%s\n' "$log_tail" >&2
  echo "    claude 출력 로그: ${log_final}" >&2
  exit 1
fi

# --- ④ 성공 후처리 — 그룹이 정리됐을 때만 ---
if [ "$group_dead" -ne 1 ]; then
  echo "claude process group(${claude_pgid})이 아직 살아 있어 턴 후처리를 하지 않았습니다." >&2
  echo "    claude 출력 로그: ${log_final}" >&2
  exit 1
fi

if [[ ! -f "$EXPECTED_TURN_FILE" ]]; then
  echo "Claude did not create the expected turn file: $EXPECTED_TURN_FILE" >&2
  echo "    claude 출력 로그: ${log_final}" >&2
  exit 1
fi

# 셀프 리뷰 경고를 턴 파일 헤더에 삽입
if [[ "${SELF_REVIEW_WARNING:-true}" == "true" ]]; then
  local_tmp="$(mktemp)" || { echo "adapter_claude: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  [[ -n "$local_tmp" && -f "$local_tmp" ]] || { echo "adapter_claude: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  chmod 600 "$local_tmp"
  {
    echo '> **⚠️ Self-Review Notice:** 이 턴은 독립 리뷰어 대신 Claude(self-review)가 작성했습니다. 독립성이 보장되지 않으므로 결과를 비판적으로 검토하세요.'
    echo ''
    cat "$EXPECTED_TURN_FILE"
  } > "$local_tmp"
  # 발행은 이미 끝났으므로 여기서의 실패는 상태 파일에 반영할 수 없다. 삼키지 않고
  # 사실을 화면에 남긴다 — 상태 파일의 `outcome: ok` 는 **발행 시점의 사실**이며
  # 헤더 삽입까지 성공했다는 뜻이 아님을 함께 밝힌다.
  if ! mv "$local_tmp" "$EXPECTED_TURN_FILE"; then
    rm -f "$local_tmp" 2>/dev/null || true
    echo "self-review 헤더를 턴 파일에 삽입하지 못했습니다: ${EXPECTED_TURN_FILE}" >&2
    echo "    턴 파일 자체는 남아 있습니다. 상태 파일의 outcome 은 발행 시점(헤더 삽입 이전) 기준입니다: ${RW_STATUS_FILE}" >&2
    exit 1
  fi
fi

exit 0
