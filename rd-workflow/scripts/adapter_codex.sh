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
# last-message 파일은 세션 디렉토리 하위에 둔다. codex 가 쓰는 writable surface 를
# SESSION_PATH 하나로 닫아 /tmp 가 writable 이라는 전제를 제거한다 (spec/plan review 004턴).
# 고정명이 아니라 mktemp 템플릿이어야 한다 — 고정명 + `: >` 는 세션 디렉토리에 미리 놓인
# 같은 이름의 symlink 를 따라가 세션 밖 파일을 truncate 하고(codex sandbox 시작 전, 호출자
# 권한으로), 같은 세션의 동시 실행이 서로의 파일을 비우거나 cleanup 으로 지운다.
# mktemp 는 배타적으로 새 파일을 만들므로 둘 다 막힌다 (final diff review 002턴).
last_message_file="$(mktemp "${session_dir}/.last_message.XXXXXX")"
chmod 600 "$last_message_file"

codex_pid=""
watchdog_pid=""
watchdog_dir=""
watchdog_fd_open=0
codex_pgid=""
cleanup_done=0

# 확인된 codex process group 에 살아 있는 프로세스가 있는가.
# pgid 조회·판정은 반드시 `ps -eo pid,pgid` + awk 로 한다. `ps -o ... -p <pid>` 는
# busybox ps 가 -p 를 지원하지 않아 빈 값을 돌려주고, 그러면 그룹 종료 경로로 넘어가지
# 못해 codex 자식이 고아로 남아 호출자 파이프를 계속 붙잡는다(Alpine 실측).
codex_group_alive() {
  [ -n "$codex_pgid" ] || return 1
  local n
  n="$( { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$codex_pgid" '$2==g' | wc -l | tr -d ' ' )"
  [ "$n" -gt 0 ]
}

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
  if [ "$watchdog_fd_open" -eq 1 ]; then
    exec 9<&- 2>/dev/null || true
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
  if [ -n "$codex_pgid" ] && codex_group_alive; then
    kill -- -"$codex_pgid" 2>/dev/null || true
    sleep "$KILL_GRACE"
    if codex_group_alive; then
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
  # .wait_timeout 마커 정리 (cleanup 시점 제거)
  rm -f "$timeout_marker"
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
watchdog_dir="$(mktemp -d "${TMPDIR:-/tmp}/rd-watchdog.XXXXXX")"
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
  - < "$PROMPT_FILE" &
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
codex_pgid=""
for _pg_try in 1 2 3 4 5 6 7 8 9 10; do
  _pg_n="$( { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$codex_pid" '$2==g' | wc -l | tr -d ' ' )"
  if [ "$_pg_n" -gt 0 ]; then
    codex_pgid="$codex_pid"
    break
  fi
  sleep 0.05
done

# --- 대기: watchdog + wait (폴링 루프 없음, spec §2 결정 1) ---
# 타임아웃 판정 = 마커 파일 원자 생성 (정본 계약 — kill -0 생존 추정 금지)
# watchdog 은 sleep 자식을 두지 않는다: 위에서 부모가 연 fd 9 를 상속받아
# 서브셸 자신이 read -t 로 타이머가 된다. sleep 을 자식으로 두면 kill 이 서브셸만 종료하고
# sleep 이 고아로 남아 상속한 stderr fd 를 계속 보유하므로, 호출자가 stderr 를 파이프로 받을 때
# 턴이 정상 완료된 뒤에도 WAIT_TIMEOUT 만큼 hang 한다.
# read -t 의 타임아웃 반환값은 bash 3.2 에서 1, 5.x 에서 142 이므로 성공/실패만 판정한다.
(
  read -t "$WAIT_TIMEOUT" -u 9 _dummy && exit 0
  # 타임아웃 마커를 tmp+mv로 원자적으로 생성
  tmpm="$(mktemp "${session_dir}/.wait_timeout.XXXXXX")" && mv "$tmpm" "$timeout_marker"
  # 검증된 그룹이 있으면 그룹 단위로 종료해 codex 자손까지 즉시 정리한다.
  # 그룹이 없으면 리더만 종료하고, 남은 자손은 부모의 cleanup 이 처리한다.
  if [ -n "$codex_pgid" ]; then
    kill -- -"$codex_pgid" 2>/dev/null || true
  else
    kill "$codex_pid" 2>/dev/null || true
  fi
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
  # 대기 타임아웃은 exit 124 (GNU timeout 관례) — 부모의 계측 status 매핑(timeout/fail 구분)이 소비.
  exit 124
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
