#!/usr/bin/env bash
# adapter_codex.sh — Codex CLI 어댑터 (background 실행 + watchdog+wait)
# 환경변수: SESSION_PATH, PROMPT_FILE, EXPECTED_TURN_FILE,
#           TOOL_BIN, PROJECT_ROOT,
#           TOOL_EFFORT (선택 — reasoning effort. 빈 값이면 전역 설정을 따름)
#
# TOOL_MODEL 은 의도적으로 사용하지 않는다. 모델은 전역 ~/.codex/config.toml 을
# 단일 진실 원천으로 두어 drift 를 없앤다는 결정이며, 부모가 TOOL_MODEL 을 export 하더라도
# 이 어댑터는 무시한다. 조절 가능한 것은 reasoning effort 뿐이다.
# 그래서 review-tools.json 의 codex stanza 에도 model 필드를 두지 않는다.
#
# effort 값이 현재 모델에서 지원되지 않으면 codex 가 설정을 거부하고 이 어댑터는
# **즉시 실패한다.** effort 없이 자동 재시도하지 않는다 — codex stderr 는 설정 오류 전용
# 채널이 아니라 진행 출력 전체이므로, 문자열 매칭으로는 "agent 실행 전 실패"를 증명할 수
# 없다(빈 last-message 는 agent 미시작이 아니라 최종 메시지 미완성만 뜻한다). 증명되지 않은
# 재시도는 이미 시작된 agent 뒤에 두 번째 agent 를 붙여 세션·워크스페이스를 조용히 오염시킨다.
# 무효값은 다음 턴에도 계속 실패하므로 사용자가 결국 고쳐야 하며, 자동 재시도는 문제를
# 숨기고 지연시킬 뿐이다. 복구 경로는 부모가 출력하는 안내(키 제거 또는
# RD_REVIEW_EFFORT_OVERRIDE=0)다.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/review_common.sh"
source "${script_dir}/review_wait.sh"

RW_TOOL_LABEL="codex"

codex_bin="${TOOL_BIN:-codex}"

if ! command -v "$codex_bin" &>/dev/null; then
  echo "Codex CLI를 찾을 수 없습니다: $codex_bin" >&2
  exit 1
fi

# --- 설정 ---
DEFAULT_ABS_CAP=7200      # 절대 상한 기본값 (관측 최장 정상 소요 3,284초의 2배 이상)
DEFAULT_IDLE=600          # 유휴 임계 기본값 (관측 최대 무출력 구간 123초의 약 4.9배)
TICK=1                    # 관측·판정 주기(초)
SETTLE_DELAY=0.5          # 턴 완료 후 flush 여유
KILL_GRACE=3              # SIGTERM 후 대기

ABS_CAP="$(rw_resolve_abs_cap "$DEFAULT_ABS_CAP")"
IDLE_TIMEOUT="$(rw_resolve_idle "$DEFAULT_IDLE")"
OBSERVER_FALLBACK_CAP="$(rw_resolve_tunable RD_REVIEW_OBSERVER_FALLBACK_CAP 600)"
HEARTBEAT_INTERVAL="$(rw_resolve_tunable RD_REVIEW_HEARTBEAT 60)"

RW_ABS_CAP="$ABS_CAP"
RW_IDLE="$IDLE_TIMEOUT"
RW_FALLBACK_CAP="$OBSERVER_FALLBACK_CAP"
RW_HEARTBEAT="$HEARTBEAT_INTERVAL"
RW_TICK="$TICK"

if [ "$IDLE_TIMEOUT" -gt 0 ] && [ "$IDLE_TIMEOUT" -gt "$ABS_CAP" ]; then
  echo "경고: 유휴 임계(${IDLE_TIMEOUT}초)가 절대 상한(${ABS_CAP}초)보다 큽니다 — 유휴 판별이 발동하지 않습니다." >&2
fi

echo "wait config: cap=${ABS_CAP}s idle=${IDLE_TIMEOUT}s" >&2

# WAIT_TIMEOUT 은 이후 코드에서 쓰지 않는다. 값은 ABS_CAP 이 유일 권위다.

session_dir="${SESSION_PATH}"
session_file="${session_dir}/SESSION.md"
turn_ready_file="${session_dir}/.turn_ready"

# 안정 이름 산출물 두 개. **계약은 「실행 중에는 없고 종료 후 1회 발행된다」** 이므로
# 이름을 여기서(정리보다 먼저) 확정해 둔다 — 아래 stale 정리가 이 값을 쓴다.
STATUS_FILE="${session_dir}/.review_wait_status"
codex_log_stable="${session_dir}/.codex_output.log"

# 엔진(review_wait.sh)이 읽는 RW_* 의존값 — 부모·watchdog 서브셸이 같은 이름으로 읽는다.
RW_SESSION_DIR="$session_dir"
RW_STATUS_FILE="$STATUS_FILE"
RW_LOG_STABLE="$codex_log_stable"
RW_LOG_FD=5
RW_MARKER_FD=7
RW_TIMER_FD=9
RW_STATUS_FD=8

# 타임아웃 마커는 **안정 이름을 쓰지 않는다** (codex spawn 직전에 배타 생성 — 아래 참조).
# 여기서는 아직 경로가 없으므로 빈 값으로 선언해 두고(cleanup 이 부분 초기화 상태에서도
# 호출되므로 set -u 아래에서 반드시 정의되어 있어야 한다) 구버전이 남긴 잔여만 지운다.
timeout_marker=""

# --- stale 산출물 정리 (재실행 방어) ---
rm -f "$turn_ready_file"
rm -f "$EXPECTED_TURN_FILE"
# 구버전 안정 이름 마커와 중단된 실행이 남긴 마커 잔여물
rm -f "${session_dir}/.wait_timeout" "${session_dir}/.wait_timeout."* 2>/dev/null || true

# 이전 실행이 발행한 **안정 이름 산출물**도 여기서 지운다 (codex 가 뜨기 전 = 경쟁자 없음).
# 지우지 않으면 이번 실행이 진행되는 동안 이전 턴의 `.review_wait_status` 가 그대로 남아,
# 안정 경로만 보는 headless 소비자가 **이전 턴의 log_path·observer·보존 결과를 이번 실행의
# 현재 상태로 오인**한다(실측: 이전 안정 파일과 이번 실행 스트림이 동시에 존재). 같은 성질이
# `.codex_output.log` 에도 있으므로 함께 지운다 — 둘 다 이번 실행 종료 시 어차피 덮어쓰이므로
# 잃는 것은 「이번 실행 동안의 이전 로그 열람」뿐이고, 얻는 것은 두 안정 이름의 존재가 곧
# 「이번 실행이 끝났다」를 뜻하는 단일 계약이다.
# `rm -f` 는 symlink 를 **링크째** 지우므로(대상은 건드리지 않는다) 실행 전 심겨 있던
# 외부 symlink 도 안전하게 제거된다. 실제 디렉터리는 지우지 않는다 — 그 형태는 cleanup 의
# `mv_target_prepare` 가 「교체 포기」로 정직하게 보고한다.
if [ ! -d "$STATUS_FILE" ] || [ -L "$STATUS_FILE" ]; then
  rm -f "$STATUS_FILE" 2>/dev/null || true
fi
if [ ! -d "$codex_log_stable" ] || [ -L "$codex_log_stable" ]; then
  rm -f "$codex_log_stable" 2>/dev/null || true
fi

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
# last-message 파일은 세션 디렉토리 하위에 둔다. codex 가 쓰는 writable surface 를
# SESSION_PATH 하나로 닫아 /tmp 가 writable 이라는 전제를 제거한다 (spec/plan review 004턴).
# 고정명이 아니라 mktemp 템플릿이어야 한다 — 고정명 + `: >` 는 세션 디렉토리에 미리 놓인
# 같은 이름의 symlink 를 따라가 세션 밖 파일을 truncate 하고(codex sandbox 시작 전, 호출자
# 권한으로), 같은 세션의 동시 실행이 서로의 파일을 비우거나 cleanup 으로 지운다.
# mktemp 는 배타적으로 새 파일을 만들므로 둘 다 막힌다 (final diff review 002턴).
last_message_file="$(mktemp "${session_dir}/.last_message.XXXXXX")" || { echo "adapter_codex: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$last_message_file" && -f "$last_message_file" ]] || { echo "adapter_codex: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
chmod 600 "$last_message_file"

# --- 읽기 채널 계약 (fd 전용) ---
# 세션 디렉터리는 실행 중 codex 가 쓸 수 있고, 어댑터는 그 sandbox **밖에서 호출자 권한으로**
# 돈다. 그래서 어댑터가 **가변 경로를 다시 열어 읽는 순간** codex 는 그 이름을 세션 밖의
# 읽기 가능한 파일 symlink 로 바꿔 놓아 그 내용을 stderr·상태 파일로 끌어낼 수 있다
# (confused deputy — 쓰기 경로와 완전히 같은 성질이며, cleanup 의 `log-source-replaced`
# 판정은 내용이 이미 노출된 뒤라 너무 늦다).
# 그래서 **읽기도 codex spawn 전에 열어 둔 fd 로만** 한다:
#   fd 3 — last-message 읽기 (부모)
#   fd 4 — codex 로그 읽기, **부모 전용** (wait 복귀 후 tail)
#   fd 5 — codex 로그 읽기, **watchdog 전용** (매 tick 드레인)
# fd 4·5 를 따로 여는 것이 계약이다. 서브셸이 상속한 fd 는 부모와 **파일 오프셋을 공유**
# 하므로 하나만 열어 양쪽이 읽으면 서로 줄을 놓친다(실측: bash 3.2.57 — 서브셸이 읽은
# 다음 줄이 부모의 다음 read 에서 건너뛰어진다). `exec` 를 두 번 하면 open file
# description 이 둘이 되어 오프셋이 독립한다.
#
# **읽기 채널 open 실패는 시작 실패가 아니다** (쓰기 채널과 대비된다). 쓰기 채널(로그 생성·
# 상태 스트림·마커)이 없으면 이번 실행을 정직하게 수행할 수 없으므로 조기 실패가 옳지만,
# 읽기 채널이 없으면 잃는 것은 **관측·진단**뿐이다. 그래서 기능 저하로 합류시킨다 —
# fd 5 부재는 활동 관측기 고장(wd_observer_ok=0 → 유휴 판별 중지 + 유효 상한 조임)이고,
# fd 3·4 부재는 해당 진단 출력의 생략이다. 대체로 경로 재열기를 하지 않는다.
last_message_fd_open=0
if exec 3< "$last_message_file"; then
  last_message_fd_open=1
else
  echo "경고: last-message 읽기 fd 를 열 수 없습니다 — 조기 종료 시 last message 를 보고하지 않습니다." >&2
fi

# codex stdout+stderr 를 파일로 받는다. **파이프를 쓰지 않는 것이 핵심이다** —
# tee 를 두면 어댑터가 파이프 reader 를 하나 더 갖게 되고, 고아 프로세스가 상속 fd 를
# 붙잡아 호출자 파이프를 닫지 못하는 결함(아래 watchdog 주석 참조)이 재발한다.
# 파일이면 reader 가 없어도 되고, 크기 증가가 그대로 활동 신호가 된다.
# mktemp 로 배타 생성하는 이유는 last_message_file 과 같다 (symlink 추종·동시 실행 충돌 방지).
# **초기화 실패는 fallback 이 아니라 시작 실패다.** 로그를 만들지 못하면 codex 를 시작할
# 출력 대상 자체가 없다 — 관측만 실패하는 상황이 아니다. 세션 디렉토리가 쓰기 불가라는
# 뜻이고 그러면 codex 가 턴 파일도 쓸 수 없으므로 조기 실패가 옳다.
codex_log="$(mktemp "${session_dir}/.codex_output.XXXXXX")" || {
  echo "codex 출력 로그를 만들 수 없습니다: ${session_dir}" >&2
  exit 1
}
chmod 600 "$codex_log"
RW_LOG_PATH="$codex_log"

# 로그 읽기 fd — 부모(fd 4)와 watchdog(fd 5) 가 **각각 독립적으로** 연다 (위 읽기 채널 계약).
# 두 fd 는 지금 이 시점의 inode 를 가리키므로, 이후 codex 가 세션을 열거해 경로를
# unlink·symlink 로 바꿔도 어댑터의 읽기는 세션 밖으로 새지 않는다.
log_read_fd_open=0
if exec 4< "$codex_log"; then
  log_read_fd_open=1
else
  echo "경고: codex 로그 읽기 fd(부모)를 열 수 없습니다 — 종료 후 최근 출력을 보고하지 않습니다." >&2
fi
wd_log_fd_open=0
if exec 5< "$codex_log"; then
  wd_log_fd_open=1
else
  echo "경고: codex 로그 관측 fd 를 열 수 없습니다 — 활동 관측기를 고장으로 간주합니다." >&2
fi
RW_OBSERVER_OK="$wd_log_fd_open"

# 무작위 경로를 사용자가 알 수 있어야 "진행 중 tail -f 가능" 이 참이 된다.
echo "codex 출력 로그: ${codex_log}  (진행 중 확인: tail -f '${codex_log}')" >&2

# --- 상태 snapshot 기반 시설 (산출물 수명 계약) ---
# 세션 디렉토리는 실행 중인 codex 가 쓸 수 있다 (`--sandbox workspace-write` +
# `--add-dir "$session_real"`). 그래서 **codex 가 살아 있는 동안에는 안정 이름
# `.review_wait_status` 로 아무것도 쓰지 않는다.**
#
# 왜 mktemp+원자 교체만으로는 부족한가: 검사(`-L`/`-d`)·삭제·`mv` 는 셸에서 하나의 원자
# 연산이 될 수 없다. codex 가 안정 이름을 세션 밖 디렉터리 symlink 로 **타이트한 루프로
# 계속 재생성**하면 검사와 `mv` 사이의 창을 반복 공략할 수 있고, 한 번만 이겨도 그 교체분이
# 세션 밖으로 나간다("한 번만 미리 배치" 가 아니라 반복 공략이 가능하다).
# 또 임시 경로를 mktemp 로 예측 불가하게 만들어도 codex 는 세션 디렉터리를 **열거**해 그
# 이름을 찾을 수 있으므로, 이름의 무작위성만으로는 경로 기반 쓰기를 지킬 수 없다.
#
# 그래서 수명을 둘로 나눈다:
#   진행 중 — 갱신은 `mktemp` 로 만든 무작위 스트림 파일에만 하고, 쓰기는 **codex spawn 전에
#             열어 둔 fd** 로만 한다. 매 갱신이 경로를 다시 해석하지 않으므로 codex 가 경로를
#             unlink·symlink 로 바꿔도 어댑터의 쓰기는 원래 inode 로 간다. 안정 이름으로의
#             rename 은 **하지 않는다.**
#   종료 후 — cleanup 이 **codex process group 종료를 확인한 뒤** 안정 이름으로 1회 발행한다.
#             그 시점에는 symlink 를 심을 주체가 없으므로 rename 경쟁이 구조적으로 사라진다.
#
# 그 결과 **안정 이름 파일은 「실행 중에는 없고 종료 후에 나타난다」** 로 계약이 바뀐다.
# 진행 가시성은 stderr heartbeat 가 담당하며, heartbeat 줄에 이 스트림의 실제 경로를 함께 낸다.
# (STATUS_FILE 은 stale 정리보다 먼저 확정해 두었다 — 위쪽 참조.)
# 스트림은 append 이므로 갱신마다 이 구분선으로 새 snapshot 블록을 시작한다.
# 발행 시에는 **마지막 블록**만 꺼낸다.
SNAP_DELIM='=== rd-review-wait-snapshot ==='
RW_SNAP_DELIM="$SNAP_DELIM"
status_stream=""
status_stream_fd_open=0
marker_write_fd_open=0
marker_read_fd_open=0

status_stream="$(mktemp "${session_dir}/.review_wait_status.XXXXXX")" || {
  echo "대기 상태 스트림 파일을 만들 수 없습니다: ${session_dir}" >&2
  exit 1
}
chmod 600 "$status_stream" 2>/dev/null || true
RW_STATUS_STREAM_PATH="$status_stream"
# codex spawn 전에 append 로 열어 둔다 (부모와 watchdog 이 fd 를 공유하며 O_APPEND 로 쓴다).
if ! exec 8>> "$status_stream"; then
  echo "대기 상태 스트림 fd open 실패: ${status_stream}" >&2
  exit 1
fi
status_stream_fd_open=1
RW_STATUS_FD_OPEN="$status_stream_fd_open"
echo "대기 상태 스트림: ${status_stream}  (안정 경로 ${STATUS_FILE} 는 종료 후에 발행됩니다)" >&2

# 상태 snapshot·process group 함수(mv_target_prepare·status_append·status_last_snapshot·
# status_init_snapshot·publish_final_status)는 review_wait.sh 로 옮겨졌다(rw_ 접두).
# 로직은 그대로이며 의존값만 RW_* 변수로 읽는다.
rw_status_init_snapshot "$RW_STATUS_FD" "$ABS_CAP" "$IDLE_TIMEOUT"

codex_pid=""
watchdog_pid=""
watchdog_dir=""
watchdog_fd_open=0
codex_pgid=""
cleanup_done=0

# process group 판정(rw_group_alive)·pgid 획득(rw_acquire_pgid)은 review_wait.sh 로
# 옮겨졌다. 구현은 그대로이며 인자로 pgid 를 받는다(전역 codex_pgid 를 암묵적으로
# 읽지 않는다).
#
# cleanup 은 멱등이어야 한다: 신호 핸들러와 EXIT trap 이 연달아 호출되고,
# 부분 초기화 상태(fifo 준비 도중 실패)에서도 호출된다.
cleanup() {
  [ "$cleanup_done" -eq 1 ] && return 0
  cleanup_done=1
  # watchdog 종료 및 reap
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  fi
  # watchdog 타이머 fd 닫기 (부모가 보유)
  # `exec` 는 명령 없이 리다이렉션만 주면 그 리다이렉션이 **현재 셸에 영구 적용**된다.
  # 과거 `exec 9<&- 2>/dev/null` 는 fd 9 를 닫으려던 의도와 달리 셸의 stderr(fd 2)
  # 자체를 /dev/null 로 영구 교체해, 이후 cleanup 이 남기는 모든 stderr 보고(로그
  # 보존 실패 알림 등)를 조용히 삼켰다. `{ }` 그룹으로 감싸 2>/dev/null 을 그룹
  # 실행 동안만(그룹을 벗어나면 원복되는) 임시 리다이렉션으로 좁힌다.
  if [ "$watchdog_fd_open" -eq 1 ]; then
    { exec 9<&-; } 2>/dev/null || true
    watchdog_fd_open=0
  fi
  # watchdog 타이머 fifo·디렉터리 정리 (부분 생성 상태도 남기지 않는다)
  if [ -n "$watchdog_dir" ]; then
    rm -f "${watchdog_dir}/timer" 2>/dev/null || true
    rmdir "${watchdog_dir}/timer" 2>/dev/null || true
    rmdir "$watchdog_dir" 2>/dev/null || true
    watchdog_dir=""
  fi
  # codex 프로세스(및 그 자손) 종료
  # 그룹 종료는 **리더 생존과 독립**이어야 한다. 리더가 이미 죽은 뒤에도(타임아웃으로
  # watchdog 이 리더를 종료한 경우, codex 가 자손을 남기고 정상 종료한 경우) 자손이
  # 상속한 호출자 stderr fd 를 계속 보유하면 파이프가 닫히지 않는다 — 원 결함과 같은
  # 유형이 한 단계 밖에서 재현된다. 그래서 codex_pgid 는 spawn 직후에 조회·검증해
  # 보존해 두고, 여기서는 리더 생존 여부를 보지 않고 그 그룹을 종료한다.
  # grace 후 판단도 리더 PID 가 아니라 **그룹 생존**을 기준으로 한다 — TERM 을 무시하는
  # 자손이 남아 있는데 리더만 죽었다면 리더 기준 판단은 KILL 을 건너뛴다.
  # 그룹에 살아 있는 프로세스가 있을 때만 종료 시퀀스를 수행한다. 무조건 grace 를 기다리면
  # 이미 모두 종료된 정상·비정상 경로에서 KILL_GRACE 만큼 불필요하게 지연된다.
  if [ -n "$codex_pgid" ] && rw_group_alive "$codex_pgid"; then
    kill -- -"$codex_pgid" 2>/dev/null || true
    sleep "$KILL_GRACE"
    if rw_group_alive "$codex_pgid"; then
      kill -9 -- -"$codex_pgid" 2>/dev/null || true
    fi
  elif [ -z "$codex_pgid" ] && [ -n "$codex_pid" ] && kill -0 "$codex_pid" 2>/dev/null; then
    # 그룹이 확인되지 않은 경우의 폴백 — 단일 프로세스만 종료한다
    kill "$codex_pid" 2>/dev/null || true
    sleep "$KILL_GRACE"
    kill -0 "$codex_pid" 2>/dev/null && kill -9 "$codex_pid" 2>/dev/null || true
  fi
  if [ -n "$codex_pid" ]; then
    wait "$codex_pid" 2>/dev/null || true
  fi

  # --- 산출물 발행 (안정 이름) ---
  # **발행 전에 codex process group 이 실제로 종료됐는지 확인한다.** 살아 있는 codex 는
  # 세션 디렉토리에 쓸 수 있으므로, 그 상태에서 안정 이름으로 옮기면 검사와 `mv` 사이에
  # 외부 디렉터리 symlink 를 다시 심는 반복 공략이 되살아난다. 확인한 뒤에만 1회 발행한다.
  local group_dead=1 log_ok=no log_reason="" log_recovery=""
  if [ -n "$codex_pgid" ] && rw_group_alive "$codex_pgid"; then
    group_dead=0
  fi

  if [ "$group_dead" -ne 1 ]; then
    # 아는 것만 말한다 — 정리되지 않은 그룹이 남아 있으면 발행하지 않고 그 사실을 알린다.
    echo "알림: codex process group(${codex_pgid})이 아직 살아 있어 산출물을 안정 경로로 발행하지 않았습니다." >&2
    echo "      codex 출력 로그(임시 경로): ${codex_log}" >&2
    echo "      대기 상태 스트림: ${status_stream}" >&2
    log_reason="codex-group-alive"
  elif [ -n "${codex_log:-}" ]; then
    # codex 출력 로그는 **지우지 않고 안정된 이름으로 보존한다** — 사후 관찰이 목적이다.
    # (last_message_file 은 종전대로 삭제한다.)
    # **이동 결과를 확인한 뒤에만 성공을 기록한다.** `|| true` 로 실패를 흡수하고 곧바로
    # `log_preserved: yes` 를 적으면, I/O·권한 오류로 안정 경로에 로그가 없는데도 보존
    # 성공으로 보고한다 — 이 작업의 핵심인 「아는 것만 말하기」를 정면으로 위반한다.
    # 기대 형태는 "안정 경로가 symlink 가 아닌 정규 파일이고 원본이 사라졌다" 이다.
    if [ -L "$codex_log" ]; then
      # 소스 변조: codex 는 세션을 열거해 무작위 `.codex_output.*` 이름을 찾을 수 있고, 그
      # 경로를 세션 밖 **정규 파일** symlink 로 바꿔 놓을 수 있다. 그러면 `[ -f ]` 는 링크를
      # 따라가 참이 되고 `mv` 는 **symlink 자체**를 안정 경로로 옮긴다 — 남의 파일을 codex
      # 출력이라고 보고하게 되고, 원래 임시 경로는 이미 사라졌으므로 "회수 가능" 은 거짓이다.
      # 그래서 옮기지 않고 링크만 제거하며, **회수 경로를 보고하지 않는다.**
      rm -f "$codex_log" 2>/dev/null || true
      echo "알림: codex 출력 로그 경로가 symlink 로 대체되어 보존하지 못했습니다 (${codex_log})." >&2
      echo "      원본을 회수할 수 없으므로 회수 경로를 보고하지 않습니다." >&2
      log_reason="log-source-replaced"
    elif [ -f "$codex_log" ]; then
      if rw_mv_target_prepare "$codex_log_stable" \
         && mv -f "$codex_log" "$codex_log_stable" 2>/dev/null \
         && [ ! -L "$codex_log_stable" ] && [ -f "$codex_log_stable" ] \
         && [ ! -e "$codex_log" ]; then
        log_ok=yes
      else
        # 안정 경로에 symlink 가 들어앉았다면 남기지 않는다 (링크만 제거 — 대상은 건드리지 않는다).
        if [ -L "$codex_log_stable" ]; then rm -f "$codex_log_stable" 2>/dev/null || true; fi
        echo "알림: codex 출력 로그를 안정 경로로 옮기지 못했습니다 — 안정 경로: ${codex_log_stable}" >&2
        # **실제로 남아 있는 경우에만** 회수 경로를 보고한다.
        if [ -f "$codex_log" ] && [ ! -L "$codex_log" ]; then
          echo "      로그는 임시 경로에 남아 있습니다(회수 가능): ${codex_log}" >&2
          log_reason="log-move-failed"
          log_recovery="$codex_log"
        else
          echo "      임시 경로의 원본도 남아 있지 않아 회수할 수 없습니다 (${codex_log})." >&2
          log_reason="log-move-failed-source-lost"
        fi
      fi
    else
      # 경로가 실행 중 사라진 경우(= 관측기 고장의 원인 그 자체)에는 옮길 원본이 없다.
      # 열린 fd 로 출력이 계속 기록되더라도 경로가 없으면 회수할 수 없다.
      # **복구 설계를 넣지 않고 보존 실패를 명시적으로 알린다** — 안전 링크·fd 복구는
      # 이 결함과 무관한 복잡도이며 그 자체가 새 실패 지점이다.
      echo "알림: codex 출력 로그가 실행 중 사라져 보존하지 못했습니다 (${codex_log})." >&2
      log_reason="log-vanished-during-run"
    fi
  fi

  if [ "$group_dead" -eq 1 ]; then
    if rw_publish_final_status "$log_ok" "$log_reason" "$log_recovery"; then
      # 발행 성공 — 진행 중 스트림은 남기지 않는다 (안정 파일이 최종 권위).
      rm -f "$status_stream" 2>/dev/null || true
    else
      echo "알림: 대기 상태를 안정 경로(${STATUS_FILE})로 발행하지 못했습니다." >&2
      echo "      진행 중 상태는 스트림에 남아 있습니다: ${status_stream}" >&2
    fi
  fi

  # 읽기·쓰기 fd 전부 닫기 (fd 3·4·5·6·7·8 — 모두 codex spawn 전에 부모가 열었다).
  # `exec N<&-` 는 명령 없이 호출하면 리다이렉션이 현재 셸에 **영구 적용**되므로
  # (과거 `exec 9<&- 2>/dev/null` 가 셸 stderr 를 영구 /dev/null 로 바꿨다)
  # 반드시 `{ exec N<&-; } 2>/dev/null || true` 관용구로 좁힌다.
  if [ "$last_message_fd_open" -eq 1 ]; then
    { exec 3<&-; } 2>/dev/null || true
    last_message_fd_open=0
  fi
  if [ "$log_read_fd_open" -eq 1 ]; then
    { exec 4<&-; } 2>/dev/null || true
    log_read_fd_open=0
  fi
  if [ "$wd_log_fd_open" -eq 1 ]; then
    { exec 5<&-; } 2>/dev/null || true
    wd_log_fd_open=0
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
  # 타임아웃 마커 정리 (cleanup 시점 제거 — 안정 이름이 없으므로 이 경로 하나뿐이다)
  if [ -n "$timeout_marker" ]; then
    rm -f "$timeout_marker" 2>/dev/null || true
  fi
  rm -f "$last_message_file"
}
trap cleanup EXIT
# 신호는 명시적으로 처리한다. EXIT trap 만 두어도 cleanup 자체는 실행되지만,
# job control 하에서 INT 의 종료 코드가 129 로 잘못 보고된다(명시적 trap 에서만 130).
# 주의: 어댑터가 background job 으로 시작되면 SIGINT 은 셸 진입 시점에 무시로 설정되어
# trap 자체가 무효다(POSIX). TERM·HUP 은 background job 에서도 정상 전달된다.
# SIGKILL 은 트랩 불가이므로 보장 범위 밖이다.
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- watchdog 타이머 준비 (codex spawn 보다 먼저) ---
# 순서가 계약이다: 여기서 실패하면 codex 는 아직 시작되지 않았으므로
# "이미 시작된 codex 를 누가 종료·reap 하는가" 문제가 발생하지 않는다.
# fd open 도 부모가 한다. 서브셸 안에서 열면 실패 시 fd 없이 read -t 가 즉시 실패해
# t=0 에 거짓 타임아웃(마커 생성 + codex 종료)을 만든다.
watchdog_dir="$(mktemp -d "${TMPDIR:-/tmp}/rd-watchdog.XXXXXX")" || { echo "adapter_codex: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$watchdog_dir" && -d "$watchdog_dir" ]] || { echo "adapter_codex: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
watchdog_fifo="${watchdog_dir}/timer"
if ! mkfifo "$watchdog_fifo" 2>/dev/null; then
  echo "watchdog 타이머 fifo 생성 실패: $watchdog_fifo" >&2
  exit 1
fi
# 읽기·쓰기 양방향으로 열어 writer 부재 시 open 이 블록되지 않게 한다.
if ! exec 9<> "$watchdog_fifo"; then
  echo "watchdog 타이머 fifo open 실패: $watchdog_fifo" >&2
  exit 1
fi
watchdog_fd_open=1

# --- 타임아웃 마커 준비 (codex spawn 보다 먼저) ---
# 안정 이름 `.wait_timeout` 으로의 rename 을 **없앤다.** 안정 이름은 예측 가능하므로 실행 중
# codex 가 그 자리에 세션 밖 디렉터리 symlink 를 심을 수 있고, 그러면 마커가 sandbox 밖으로
# 옮겨져 부모가 **실제 타임아웃을 일반 조기 종료로 오분류**한다(상태 파일과 달리 마커는
# codex 생존 중에 만들어져야 하므로 「종료 후 1회 발행」으로는 해결되지 않는다).
# 대신 **codex 가 존재하기 전에** mktemp 로 배타 생성하고(그 시점엔 사전 심기가 불가능)
# 쓰기 fd 7·읽기 fd 6 을 그 자리에서 열어 둔다. 이후 codex 가 세션을 열거해 경로를
# unlink·symlink 로 바꿔도 두 fd 는 원래 inode 를 가리키므로 마커 전달이 훼손되지 않는다.
# **판정 기준은 존재가 아니라 내용이다** — 파일은 시작부터 존재하고 비어 있다.
# 이 순서도 계약이다: 여기서 실패하면 codex 는 아직 시작되지 않았다.
timeout_marker="$(mktemp "${session_dir}/.wait_timeout.XXXXXX")" || {
  echo "타임아웃 마커를 만들 수 없습니다: ${session_dir}" >&2
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

# reasoning effort 전달 — 빈 값이면 -c 를 붙이지 않는다 (전역 설정을 따름 = 도입 전 동작).
# -c 값은 TOML 로 파싱되므로 문자열을 따옴표로 감싼다.
# bash 3.2 + set -u 에서 빈 배열 전개가 죽으므로 "${arr[@]+"${arr[@]}"}" 관용구가 필수다.
extra_args=()
[ -n "${TOOL_EFFORT:-}" ] && extra_args+=(-c "model_reasoning_effort=\"${TOOL_EFFORT}\"")

# workspace-write sandbox 는 physical 경로 기준으로 쓰기 범위를 판정한다. team-overlay
# 구성에서는 SESSION_PATH 가 PROJECT_ROOT 안의 symlink 를 따라간 실제 위치(overlay repo)에
# 있어 쓰기 금지 영역이 되고, codex 가 턴 파일을 만들지 못한다. 세션 디렉토리의 physical
# 경로를 --add-dir 로 무조건 추가한다 — 비-overlay 구성에서는 이미 PROJECT_ROOT 트리 안이라
# 중복 지정이 무해하므로 overlay 감지 분기를 두지 않는다. 개방 범위는 이 디렉토리 하나다.
session_real="$(cd "$session_dir" && pwd -P)"

# codex 를 자체 process group 리더로 띄운다 (set -m). cleanup 이 그룹 단위로 종료해
# codex 가 남긴 자식까지 정리할 수 있게 하기 위함이며, pgid == codex_pid 를 ps 로 확인한
# 뒤에만 그룹 종료하므로 무관한 그룹을 건드리지 않는다.
set -m
"$codex_bin" --ask-for-approval never exec \
  --cd "$PROJECT_ROOT" \
  --sandbox workspace-write \
  --add-dir "$session_real" \
  --skip-git-repo-check \
  "${extra_args[@]+"${extra_args[@]}"}" \
  --output-last-message "$last_message_file" \
  - < "$PROMPT_FILE" > "$codex_log" 2>&1 3<&- 4<&- 5<&- 6<&- 7>&- 8>&- &
codex_pid=$!
set +m

# pgid 를 spawn 직후에 확정해 보존한다. cleanup 은 리더 생존과 독립적으로 이 그룹을
# 종료하므로, 타임아웃이나 codex 정상 종료 이후에도 자손이 남지 않는다.
#
# 조회는 레이스에 걸릴 수 있다 — spawn 직후 ps 가 아직 그 프로세스를 보여주지 않거나
# codex 가 즉시 종료하면 리더 행 조회가 빈 값을 돌려준다. 실측(Ubuntu)에서 이 레이스로
# 그룹 종료 경로를 놓쳤고, codex 자손이 고아로 남아 호출자 파이프를 계속 붙잡았다.
# 그래서 리더 행만 찾지 않고 **pgid 가 codex_pid 인 구성원이 하나라도 있는지** 조회한다.
# 이 형태가 소유권 확인이면서 레이스에 견딘다 — 리더가 조회 전에 종료했어도 자손이 남았다면
# 그 그룹 행으로 확인되고, 그룹 자체가 없으면 종료할 대상도 없다. 오탐도 불가능하다:
# pgid 는 그 그룹 리더의 pid 이므로 pgid == codex_pid 인 그룹은 codex 의 그룹뿐이다.
# (리더 행만 조회하면 spawn 직후 레이스로 빈 값이 나와 그룹 종료 경로를 놓친다 — Ubuntu 실측)
# 재시도 루프 자체는 review_wait.sh 의 rw_acquire_pgid 로 옮겨졌다(10회 재시도 +
# sleep 0.05, 그룹 행 조회 — 구현 보존).
codex_pgid="$(rw_acquire_pgid "$codex_pid")"
RW_TARGET_PGID="$codex_pgid"
RW_TARGET_PID="$codex_pid"

# --- 대기: watchdog + wait ---
# watchdog 은 sleep 자식을 두지 않는다: 부모가 연 fd 9 를 상속받아 서브셸 자신이
# read -t 로 타이머가 된다. sleep 을 자식으로 두면 kill 이 서브셸만 종료하고 sleep 이
# 고아로 남아 상속한 stderr fd 를 계속 보유하므로, 호출자가 stderr 를 파이프로 받을 때
# 턴이 정상 완료된 뒤에도 대기 시간만큼 hang 한다.
# read -t 의 타임아웃 반환값은 bash 3.2 에서 1, 5.x 에서 142 이므로 성공/실패만 판정한다.
#
# 현행과 달리 read 는 **TICK(1초) 마다 깨어나는 주기 타이머**다. 절대 마감이 아니라
# 매 tick 에서 (1) 활동 관측 (2) 상한 판정 (3) 유휴 판정 (4) heartbeat 를 수행한다.
# watchdog tick 루프 본체(활동 관측·상한/유휴 판정·heartbeat·타임아웃 종료·kill
# escalation)는 rw_watchdog_loop 로 review_wait.sh 에 옮겨졌다. 부모가 설정한 RW_*
# 변수(RW_TARGET_PGID·RW_TARGET_PID·RW_ABS_CAP·RW_IDLE·RW_TICK·RW_HEARTBEAT·
# RW_FALLBACK_CAP·RW_OBSERVER_OK·RW_LOG_FD·RW_MARKER_FD·RW_TIMER_FD·RW_STATUS_FD 등)을
# 서브셸이 상속해 읽는다. codex 는 RW_LINE_FORMATTER·RW_KILL_ESCALATE 를 설정하지
# 않으므로 표시 절단·kill escalation 은 켜지지 않는다(동작 불변).
( rw_watchdog_loop ) &
watchdog_pid=$!

codex_rc=0
wait "$codex_pid" || codex_rc=$?

# --- watchdog 종료 및 reap (진단 읽기보다 먼저) ---
# `wait "$codex_pid"` 가 복귀한 시점에 codex 리더는 이미 종료했다. 그런데 watchdog 은
# 별도 프로세스라 그 사실을 모르고 tick 을 계속 돈다 — 이 자리에서 진단(로그 tail·
# last message)을 먼저 읽으면 그동안 watchdog 이 cap/idle 판정에 도달해 **codex 종료
# 이후에** 타임아웃 마커를 쓸 수 있고, 그러면 실제로는 codex 자체 종료(조기 실패)인데
# "타임아웃" 으로 오분류된다(final diff review 008턴 Important 1). 그래서 codex 종료를
# 확인한 직후, 다른 어떤 것도 읽기 전에 watchdog 을 kill 하고 reap 한다.
#
# 이 순서에서도 **실제** 타임아웃 판정은 훼손되지 않는다: watchdog 이 진짜로 cap·idle
# 에 도달해 codex 를 종료시킨 경우에는 `wd_timeout_exit` 이 마커를 fd 7 에 쓴 뒤에야
# codex process group 을 kill 하므로, 마커는 항상 `wait "$codex_pid"` 가 복귀하기
# **이전에** 이미 존재한다. 즉 여기서 watchdog 을 먼저 죽여도 그 마커는 그대로 남아
# 아래 fd 6 판정에서 정상적으로 읽힌다 — 닫히는 것은 이미 다 쓴 watchdog 의 tick 루프뿐이다.
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
codex_pid=""

# --- 종료 후 진단 자료 확보 (경로 재해석 없음) ---
# 로그 tail 과 last message 를 **spawn 전에 열어 둔 fd 4·3 에서** 한 번만 읽어 변수에 담는다.
# 이후 보고 경로는 이 변수만 쓴다 — 가변 경로(`$codex_log`·`$last_message_file`)를 호출자
# 권한으로 다시 열지 않는다. codex 는 이미 그 이름들을 세션 밖 파일 symlink 로 바꿔 놓았을
# 수 있고, 그것을 읽으면 남의 파일 내용이 stderr 와 상태 파일로 나간다.
# `[ -s "$path" ]` 같은 존재·크기 검사도 쓰지 않는다 — 그 검사 자체는 내용을 노출하지
# 않지만, 통과 여부가 symlink 대상에 좌우되면 「무엇을 읽었는지」의 판단 근거가 흔들린다.
# 대신 **읽어 온 값이 비었는지**로만 판단한다.
#
# tail 은 이미 열린 fd 를 stdin 으로 받는다(`<&4`/`<&3`). 경로를 열지 않으므로 안전하고,
# 정규 파일 stdin 에서는 끝에서부터 찾으므로 큰 로그에서도 셸 루프보다 훨씬 빠르다.
# 파이프라인 실패를 흡수하는 관용구는 `x="$( { cmd 2>/dev/null || true; } )"` 이다
# (pipefail + errexit 함정).
LOG_TAIL_LINES=20
# last message 도 무제한 `cat` 대신 **끝에서부터 상한 바이트만** 담는다 — 진단 표시가
# 목적이므로 전체가 필요하지 않고, 무제한 적재는 성공 경로에서도 메모리를 불필요하게
# 먹으며 이 fd 를 오래 붙잡아 위 경합 창을 넓힌다. `tail -c` 는 fd 3 을 그대로 stdin 으로
# 받으므로 경로를 다시 열지 않는다.
LAST_MESSAGE_MAX_BYTES=65536
log_tail=""
if [ "$log_read_fd_open" -eq 1 ]; then
  log_tail="$( { tail -n "$LOG_TAIL_LINES" <&4 2>/dev/null || true; } )"
fi
last_message=""
if [ "$last_message_fd_open" -eq 1 ]; then
  last_message="$( { tail -c "$LAST_MESSAGE_MAX_BYTES" <&3 2>/dev/null || true; } )"
fi
# 다 읽었으므로 닫는다 (cleanup 이 다시 닫아도 멱등하다).
if [ "$log_read_fd_open" -eq 1 ]; then
  { exec 4<&-; } 2>/dev/null || true
  log_read_fd_open=0
fi
if [ "$last_message_fd_open" -eq 1 ]; then
  { exec 3<&-; } 2>/dev/null || true
  last_message_fd_open=0
fi

# 타임아웃 판정: **마커 내용**으로 판정한다 (kill -0 생존 추정 금지).
# 마커 파일은 codex spawn 전에 만들어져 시작부터 존재하므로 존재는 신호가 아니다.
# 읽기도 경로가 아니라 **spawn 전에 열어 둔 fd 6** 에서 한다 — 실행 중 codex 가 마커
# 경로를 바꿔치기해도 부모는 원래 inode 를 읽는다. fd 는 한 번도 읽지 않았으므로 offset
# 은 0 이고, watchdog 의 쓰기는 codex 종료보다 먼저 일어나므로 여기서 이미 보인다.
timed_out=0
timeout_reason=""
timeout_cap=""
timeout_observer=""
timeout_marker_line=""
if [ "$marker_read_fd_open" -eq 1 ]; then
  # `read` 는 EOF(빈 마커)에서 비영을 돌려주므로 errexit 대비 가드가 필수다.
  { IFS= read -r timeout_marker_line <&6 || true; }
  # 마커 내용은 "<사유> <유효상한> <관측기상태>" — tr 로 공백을 전부 지우면 필드가
  # 뭉개지므로 CR 만 제거하고, 필드 분리는 read 로 한다(공백 구분자 그대로 유지).
  timeout_marker_line="$( { printf '%s' "$timeout_marker_line" 2>/dev/null || true; } | tr -d '\r' )"
fi
if [ -n "$timeout_marker_line" ]; then
  timed_out=1
  IFS=' ' read -r timeout_reason timeout_cap timeout_observer <<<"$timeout_marker_line" || true
fi

# 세션이 재개 가능한 상태인지 **판별한다** (추정하지 않는다).
# 판별 범위는 기계 판정 권위인 SESSION.md 의 두 필드 + 턴 파일 부재뿐이며,
# 그 범위를 메시지에 함께 밝힌다. CHECKPOINT.md 등은 어댑터의 완료 판정에
# 소비되지 않으므로(FILE_BASED_REVIEW_PIPELINE.md 「턴 완료 판정 계약」) 검사하지 않는다.
#
# $1 = 사유 토큰(idle|cap) — 재개에 조정할 변수가 사유마다 다르다.
report_session_state() {
  local reason="$1" owner status resumable=0
  # extract_section 은 awk 기반이며 파일을 열 수 없으면(세션 디렉토리 소실·권한 변경·
  # SESSION.md 를 비원자적으로 갱신하던 중 kill) awk 가 rc=2 를 낸다. pipefail 아래에서
  # 가드 없이 대입하면 set -e 가 이 스크립트 자체를 죽여 타임아웃 메시지를 한 줄도
  # 내지 못한 채 rc=2 로 끝난다 — 그러면 부모가 "어댑터 실행 실패" 오탐을 낸다
  # (final diff review 지적). `|| true` 로 흡수하면 값은 빈 문자열로 남고, 그 값은
  # 아래 재개 조건을 자연히 불만족시켜 "재개 조건 불만족" 으로 정직하게 합류한다.
  owner="$( { extract_section "$session_file" "Current Owner" 2>/dev/null || true; } | trim_blank_lines )"
  status="$( { extract_section "$session_file" "Status" 2>/dev/null || true; } | trim_blank_lines )"

  if [ ! -f "$EXPECTED_TURN_FILE" ] && [ "$owner" = "Reviewer" ] && [ "$status" = "awaiting-reviewer" ]; then
    resumable=1
    echo "세션 상태: 턴 파일이 생성되지 않았고 SESSION.md 의 Current Owner=Reviewer / Status=awaiting-reviewer 가" >&2
    echo "          보존되어 있습니다 → 재실행으로 그대로 이어갈 수 있습니다." >&2
  else
    echo "세션 상태: 재개 가능 조건을 만족하지 않습니다 (턴 파일: $( [ -f "$EXPECTED_TURN_FILE" ] && echo 존재 || echo 부재 ), Current Owner='${owner}', Status='${status}')." >&2
    echo "          세션을 직접 확인한 뒤 이어가십시오." >&2
  fi
  echo "          (이 두 필드와 턴 파일만 확인했습니다. CHECKPOINT.md 등 다른 파일은 검사하지 않았습니다.)" >&2

  # 재개 명령은 **재개 가능할 때만** 낸다. "직접 확인하십시오" 직후 재개 명령을 함께 내면
  # 앞말을 무효화한다.
  # 사유가 idle·cap 둘 다 아니면(마커 손상·레이스로 사유 불명) 어느 변수를 조정해야
  # 하는지 **단정하지 않는다** — 잘못 짚으면(예: 실제 idle 인데 WAIT_TIMEOUT 만 안내)
  # 같은 유휴 타임아웃을 그대로 다시 맞는 "재발하는 조치" 가 된다.
  if [ "$resumable" -eq 1 ]; then
    case "$reason" in
      idle)
        echo "재개:      RD_REVIEW_IDLE_TIMEOUT=<더 큰 값> bash rd-workflow/scripts/run_review_turn.sh ${session_dir}" >&2
        ;;
      cap)
        echo "재개:      WAIT_TIMEOUT=<더 큰 값> bash rd-workflow/scripts/run_review_turn.sh ${session_dir}" >&2
        ;;
      *)
        echo "재개:      사유를 판별할 수 없어 어느 쪽을 조정해야 하는지 말할 수 없습니다." >&2
        echo "          RD_REVIEW_IDLE_TIMEOUT=<더 큰 값> 또는 WAIT_TIMEOUT=<더 큰 값> 를 함께 검토한 뒤" >&2
        echo "          bash rd-workflow/scripts/run_review_turn.sh ${session_dir} 로 재실행하십시오." >&2
        ;;
    esac
  fi

  # 최근 출력은 **fd 4 에서 미리 읽어 둔 변수**($log_tail)에서 낸다 — 경로를 다시 열지
  # 않는다. 타임아웃 보고는 5줄만 쓰므로 변수 안에서 잘라 낸다(파일이 아니라 문자열이므로
  # 여기서의 tail 은 경로를 열지 않는다).
  if [ -n "$log_tail" ]; then
    echo "최근 출력:" >&2
    { printf '%s\n' "$log_tail" | tail -n 5 2>/dev/null || true; } | sed 's/^/          /' >&2
  fi
}

if [ "$timed_out" -eq 1 ] && ! check_turn_complete; then
  case "$timeout_reason" in
    idle)
      echo "Codex 턴 대기 타임아웃 — 유휴 (${IDLE_TIMEOUT}초 동안 codex 출력이 없었습니다)" >&2
      ;;
    cap)
      # **실제로 적용된 유효 상한**을 보고한다 — 관측기가 고장난 경우 ABS_CAP 이 아니라
      # effective_cap() 이 조인 값(마커에 실려온 $timeout_cap)에서 죽는다. 마커 파싱이
      # 실패해 값이 비어 있으면(레이스) ABS_CAP 을 최후 폴백으로 쓰되 그 사실을 밝힌다.
      # **"codex 는 마지막까지 출력 중이었습니다" 는 단정하지 않는다** — IDLE_TIMEOUT=0,
      # 유휴 임계 > 상한, 관측기 고장 상태에서는 증명되지 않으며, 특히 관측기가 죽었으면
      # 마지막 활동 시각조차 신뢰할 수 없다.
      # "조여짐" 은 실제로 조여졌을 때만 말한다 — effective_cap 은 min(ABS_CAP,FALLBACK)
      # 이므로 FALLBACK >= ABS_CAP 이면 관측기가 고장나도 timeout_cap == ABS_CAP 이고,
      # 그때 "조여짐" 을 말하면 같은 숫자를 대며 자기모순에 빠져 사용자가 상한이
      # 축소됐다고 오인한다.
      if [ -n "$timeout_cap" ]; then
        if [ "$timeout_observer" = "failed" ]; then
          if [ "$timeout_cap" -lt "$ABS_CAP" ]; then
            echo "Codex 턴 대기 타임아웃 — 절대 상한 도달 (유효 상한 ${timeout_cap}초 — 활동 관측기 고장으로 원래 절대 상한 ${ABS_CAP}초에서 조여짐)" >&2
          else
            echo "Codex 턴 대기 타임아웃 — 절대 상한 도달 (${timeout_cap}초 — 활동 관측기 고장, 유효 상한은 절대 상한과 동일)" >&2
          fi
        else
          echo "Codex 턴 대기 타임아웃 — 절대 상한 도달 (${timeout_cap}초, 관측기 정상)" >&2
        fi
      else
        echo "Codex 턴 대기 타임아웃 — 절대 상한 도달 (유효 상한 확인 불가 — 절대 상한 기본값 ${ABS_CAP}초, 관측기 상태 확인 불가)" >&2
      fi
      ;;
    *)
      # 마커 내용이 비어 있거나(위 head 가드가 흡수한 레이스) 예상 밖 값이면 어느 사유인지
      # 단정하지 않는다 — catch-all 을 "절대 상한" 으로 잘못 보고하면 사용자가 관측기
      # 고장 여부를 오판한다.
      echo "Codex 턴 대기 타임아웃 (사유 불명 — 마커 내용: '${timeout_marker_line}')" >&2
      ;;
  esac
  report_session_state "$timeout_reason"
  # last message 도 **fd 3 에서 미리 읽어 둔 변수**에서 낸다 (경로 재해석 없음).
  if [ -n "$last_message" ]; then
    echo "--- codex last message ---" >&2
    printf '%s\n' "$last_message" >&2
  fi
  # 대기 타임아웃은 exit 124 (GNU timeout 관례) — 부모의 계측 status 매핑(timeout/fail 구분)이 소비.
  exit 124
fi

if ! check_turn_complete; then
  echo "Codex 프로세스가 턴 완료 전에 종료되었습니다 (exit: ${codex_rc})" >&2
  if [ -n "$last_message" ]; then
    echo "--- codex last message ---" >&2
    printf '%s\n' "$last_message" >&2
  fi
  # 조기 종료 사유(예: effort 값 거부 시의 "unknown variant ...")는 codex 로그에만
  # 남고 last_message_file 에는 실리지 않는다 — caller 가 원인을 진단할 수 있도록
  # 로그 tail 을 stderr 로 낸다. 타임아웃 경로(5줄)보다 넉넉히 ${LOG_TAIL_LINES}줄을 잡는다 —
  # effort 거부는 짧게 죽지만 다른 조기 종료 원인은 더 위쪽에 있을 수 있다.
  # 값은 fd 4 에서 미리 읽어 둔 $log_tail 이며 경로를 다시 열지 않는다.
  if [ -n "$log_tail" ]; then
    echo "최근 출력:" >&2
    printf '%s\n' "$log_tail" | sed 's/^/          /' >&2
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
