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
DEFAULT_ABS_CAP=7200      # 절대 상한 기본값 (관측 최장 정상 소요 3,284초의 2배 이상)
DEFAULT_IDLE=600          # 유휴 임계 기본값 (관측 최대 무출력 구간 123초의 약 4.9배)
TICK=1                    # 관측·판정 주기(초)
SETTLE_DELAY=0.5          # 턴 완료 후 flush 여유
KILL_GRACE=3              # SIGTERM 후 대기

# 부호 없는 정수인가 (빈 값·부호·소수점·문자 전부 거절)
is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# 절대 상한: WAIT_TIMEOUT → POLL_TIMEOUT → 기본값 순으로 "설정됐고 유효한 첫 값".
# 설정됐지만 무효한 값은 경고 후 **무시하고 다음 원천으로 내려간다**
# ("잘못 쓴 변수는 없는 셈 친다" — REQUEST 유효성 규칙).
resolve_abs_cap() {
  local name val
  for name in WAIT_TIMEOUT POLL_TIMEOUT; do
    eval "val=\"\${$name:-}\""
    [ -n "$val" ] || continue
    if is_uint "$val" && [ "$val" -gt 0 ]; then
      printf '%s' "$val"
      return 0
    fi
    echo "경고: ${name}='${val}' 은 양의 정수가 아닙니다 — 무시하고 다음 원천을 사용합니다." >&2
  done
  printf '%s' "$DEFAULT_ABS_CAP"
}

# 유휴 임계: 0 은 유효하며 "유휴 판별 비활성" 을 뜻한다 (이 변수에서만 특별하다).
resolve_idle() {
  local val="${RD_REVIEW_IDLE_TIMEOUT:-}"
  if [ -z "$val" ]; then
    printf '%s' "$DEFAULT_IDLE"
    return 0
  fi
  if is_uint "$val"; then
    printf '%s' "$val"
    return 0
  fi
  echo "경고: RD_REVIEW_IDLE_TIMEOUT='${val}' 은 0 이상의 정수가 아닙니다 — 기본값 ${DEFAULT_IDLE} 를 사용합니다." >&2
  printf '%s' "$DEFAULT_IDLE"
}

# 양의 정수 환경변수를 읽되 부재면 기본값. **무효값은 경고한다** —
# 조용히 기본값으로 바꾸면 사용자가 자신이 지정한 안전 상한·표시 주기가 적용됐다고 오인한다.
resolve_tunable() {  # $1=변수명 $2=기본값
  local val
  eval "val=\"\${$1:-}\""
  if [ -z "$val" ]; then printf '%s' "$2"; return 0; fi
  if is_uint "$val" && [ "$val" -gt 0 ]; then printf '%s' "$val"; return 0; fi
  echo "경고: $1='${val}' 은 양의 정수가 아닙니다 — 기본값 ${2} 를 사용합니다." >&2
  printf '%s' "$2"
}

ABS_CAP="$(resolve_abs_cap)"
IDLE_TIMEOUT="$(resolve_idle)"
OBSERVER_FALLBACK_CAP="$(resolve_tunable RD_REVIEW_OBSERVER_FALLBACK_CAP 600)"
HEARTBEAT_INTERVAL="$(resolve_tunable RD_REVIEW_HEARTBEAT 60)"

# 유효 상한 계산 — 부수효과 없는 순수 함수. 600초짜리 통합 테스트 없이 검증하기 위해
# 분리한다 (관측기 고장 계약의 핵심 불변식).
effective_cap() {  # $1=abs_cap $2=observer_ok(1|0) $3=fallback_cap → stdout
  if [ "$2" -eq 1 ]; then printf '%s' "$1"; return 0; fi
  if [ "$3" -lt "$1" ]; then printf '%s' "$3"; else printf '%s' "$1"; fi
}

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
status_stream=""
status_stream_fd_open=0
marker_write_fd_open=0
marker_read_fd_open=0

status_stream="$(mktemp "${session_dir}/.review_wait_status.XXXXXX")" || {
  echo "대기 상태 스트림 파일을 만들 수 없습니다: ${session_dir}" >&2
  exit 1
}
chmod 600 "$status_stream" 2>/dev/null || true
# codex spawn 전에 append 로 열어 둔다 (부모와 watchdog 이 fd 를 공유하며 O_APPEND 로 쓴다).
if ! exec 8>> "$status_stream"; then
  echo "대기 상태 스트림 fd open 실패: ${status_stream}" >&2
  exit 1
fi
status_stream_fd_open=1
echo "대기 상태 스트림: ${status_stream}  (안정 경로 ${STATUS_FILE} 는 종료 후에 발행됩니다)" >&2

# `mv` 는 목적지가 디렉터리(또는 디렉터리를 가리키는 symlink)면 그 **안으로** 옮기고,
# 파일 symlink 면 링크를 따라간다. codex 가 안정 경로 이름으로 세션 밖 디렉터리 symlink 를
# 심으면 산출물이 세션 밖으로 새어 나가고, 상태 파일은 존재하지 않는 경로를 가리킨다.
# 그래서 교체 전에 **그 이름의 symlink 를 링크째 제거**하고(가리키던 대상은 건드리지 않는다),
# 실제 디렉터리면 교체를 **포기**한다(디렉터리는 지우지 않는다).
# 제거와 mv 사이의 좁은 창은 셸 원시 연산으로 닫을 수 없다. 그래서 이 함수는 **codex
# process group 이 종료된 것을 확인한 뒤에만** 호출한다 — 그 시점에는 창을 공략할 주체가
# 없으므로 경쟁이 구조적으로 사라진다(진행 중에는 안정 이름을 아예 건드리지 않는다).
mv_target_prepare() {  # $1=안정 경로 → 0=교체 가능 / 1=포기
  if [ -L "$1" ]; then rm -f "$1" 2>/dev/null || return 1; fi
  [ -d "$1" ] && return 1
  return 0
}

# 진행 중 갱신 — stdin 으로 받은 **완전한 snapshot** 을 구분선과 함께 스트림에 append 한다.
# **경로를 쓰지 않는다** (codex spawn 전에 열어 둔 fd 8). 그래서 실행 중 codex 가 스트림
# 경로를 symlink 로 바꿔도 쓰기가 sandbox 밖으로 새지 않고, 안정 이름과의 경쟁도 없다.
status_append() {
  if [ "$status_stream_fd_open" -ne 1 ]; then
    # stdin 을 비워 writer 가 EPIPE 로 죽지 않게 한다.
    { cat >/dev/null 2>&1 || true; }
    return 1
  fi
  { printf '%s\n' "$SNAP_DELIM"; cat; } >&8 2>/dev/null || return 1
  return 0
}

# 스트림에서 **마지막 snapshot 블록**만 꺼낸다 (마지막 구분선 이후의 줄들).
status_last_snapshot() {  # $1=스트림 경로 → stdout
  { awk -v d="$SNAP_DELIM" '
      $0 == d { buf = ""; started = 1; next }
      started { buf = buf $0 "\n" }
      END { printf "%s", buf }
    ' "$1" 2>/dev/null || true; }
}

# **매 실행 시작 시** 이번 실행의 설정·경로로 완전한 snapshot 을 원자 초기화한다.
# 이것이 없으면 60초(첫 heartbeat) 미만에 끝나는 실행에서 ① 첫 실행은 네 필드 snapshot 이
# 아예 없고 ② 재실행은 이전 턴의 heartbeat·이미 사라진 임시 log_path·과거 observer·과거
# effective_cap 을 현재 상태처럼 물려받는다. headless 사용자는 그것을 이번 턴 정보로 오인한다.
status_init_snapshot() {
  {
    printf '[review wait] 대기 시작 — heartbeat 이전 (cap %ss idle %ss)\n' "$ABS_CAP" "$IDLE_TIMEOUT"
    printf 'log_path: %s\n' "$codex_log"
    printf 'status_stream: %s\n' "$status_stream"
    printf 'observer: ok\n'
    printf 'effective_cap: %ss\n' "$ABS_CAP"
    printf 'log_preserved: pending\n'
    printf 'log_path_final: (미정)\n'
  } | status_append || true
}

# 안정 이름 발행 — **codex process group 종료를 확인한 뒤 cleanup 에서 단 1회** 호출한다.
# 진행 중 스트림의 마지막 snapshot 을 뼈대로 삼고, 관리 키(log_preserved /
# log_preserved_reason / log_path_final / log_path_recovery) 넷을 걷어낸 뒤 이번 실행의
# 최종 값으로 다시 쓴다. 안정 파일은 **터미널 출력을 놓친 사용자의 유일한 사후 단서**다.
# 이 시점에는 경쟁자(codex)가 없으므로 mv 경쟁이 없다. 그래도 목적지 형태 검사는 유지한다 —
# 실행 중 심겨 남아 있는 symlink·디렉터리를 그대로 따라가면 산출물이 세션 밖으로 나간다.
# 실패는 삼키지 않고 1 을 돌려 호출자가 사실대로 보고하게 한다.
publish_final_status() {  # $1=yes|no $2=사유 토큰 $3=회수 가능한 임시 경로(선택)
  local base="" tmp
  # 스트림 경로가 실행 중 symlink 로 대체됐다면 그 내용은 codex 가 고른 파일이므로 읽지 않는다.
  if [ -n "$status_stream" ] && [ -f "$status_stream" ] && [ ! -L "$status_stream" ]; then
    base="$( { status_last_snapshot "$status_stream" \
      | grep -v -E '^(log_preserved|log_preserved_reason|log_path_final|log_path_recovery):' \
      || true; } )"
  fi
  case "$base" in
    *'log_path: '*) ;;
    *)
      base="$(printf '%s\n%s\n%s\n%s\n%s' \
        '[review wait] 진행 중 상태 스트림을 읽지 못했습니다 — 아래 필드는 이번 실행 설정 기준입니다' \
        "log_path: ${codex_log}" "status_stream: ${status_stream}" 'observer: unknown' \
        "effective_cap: ${ABS_CAP}s")"
      ;;
  esac
  tmp="$(mktemp "${session_dir}/.review_wait_status.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp" ] || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  {
    printf '%s\n' "$base"
    printf 'log_preserved: %s\n' "$1"
    [ -n "$2" ] && printf 'log_preserved_reason: %s\n' "$2"
    if [ "$1" = yes ]; then
      printf 'log_path_final: %s\n' "$codex_log_stable"
    else
      printf 'log_path_final: %s\n' '(없음)'
    fi
    [ -n "${3:-}" ] && printf 'log_path_recovery: %s\n' "$3"
    :
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  if ! mv_target_prepare "$STATUS_FILE"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  # 기대 형태를 확인한 뒤에만 성공을 말한다.
  [ -f "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ] || return 1
  return 0
}

status_init_snapshot

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

  # --- 산출물 발행 (안정 이름) ---
  # **발행 전에 codex process group 이 실제로 종료됐는지 확인한다.** 살아 있는 codex 는
  # 세션 디렉토리에 쓸 수 있으므로, 그 상태에서 안정 이름으로 옮기면 검사와 `mv` 사이에
  # 외부 디렉터리 symlink 를 다시 심는 반복 공략이 되살아난다. 확인한 뒤에만 1회 발행한다.
  local group_dead=1 log_ok=no log_reason="" log_recovery=""
  if [ -n "$codex_pgid" ] && codex_group_alive; then
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
      if mv_target_prepare "$codex_log_stable" \
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
    if publish_final_status "$log_ok" "$log_reason" "$log_recovery"; then
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
codex_pgid=""
for _pg_try in 1 2 3 4 5 6 7 8 9 10; do
  _pg_n="$( { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$codex_pid" '$2==g' | wc -l | tr -d ' ' )"
  if [ "$_pg_n" -gt 0 ]; then
    codex_pgid="$codex_pid"
    break
  fi
  sleep 0.05
done

# --- 대기: watchdog + wait ---
# watchdog 은 sleep 자식을 두지 않는다: 부모가 연 fd 9 를 상속받아 서브셸 자신이
# read -t 로 타이머가 된다. sleep 을 자식으로 두면 kill 이 서브셸만 종료하고 sleep 이
# 고아로 남아 상속한 stderr fd 를 계속 보유하므로, 호출자가 stderr 를 파이프로 받을 때
# 턴이 정상 완료된 뒤에도 대기 시간만큼 hang 한다.
# read -t 의 타임아웃 반환값은 bash 3.2 에서 1, 5.x 에서 142 이므로 성공/실패만 판정한다.
#
# 현행과 달리 read 는 **TICK(1초) 마다 깨어나는 주기 타이머**다. 절대 마감이 아니라
# 매 tick 에서 (1) 활동 관측 (2) 상한 판정 (3) 유휴 판정 (4) heartbeat 를 수행한다.
(
  wd_now() { date +%s 2>/dev/null || printf ''; }

  wd_start="$(wd_now)"
  # 시간 원천이 없으면 대기 판정 자체를 할 수 없다. fail-open — 판정을 포기하고
  # 부모의 wait 에 맡긴다 (턴을 죽이지 않는다).
  [ -n "$wd_start" ] || exit 0

  # 부모 전용 fd 는 watchdog 에서 닫는다 — 상속만으로도 오프셋을 공유하므로, 실수로
  # 읽으면 부모의 tail 이 줄을 놓친다. `exec N<&-` 는 명령 없이 호출하면 리다이렉션이
  # 현재 셸에 **영구 적용**되므로(과거 `exec 9<&- 2>/dev/null` 가 셸 stderr 를 영구
  # /dev/null 로 바꾼 결함) `{ } 2>/dev/null` 그룹 관용구로 좁힌다.
  { exec 3<&-; } 2>/dev/null || true
  { exec 4<&-; } 2>/dev/null || true
  { exec 6<&-; } 2>/dev/null || true

  wd_last_activity="$wd_start"
  wd_observer_ok="$wd_log_fd_open"   # 관측 fd 를 확보하지 못했으면 시작부터 고장
  wd_observer_reported=0
  # 드레인 상태 — 완성된 마지막 줄과, 개행 없이 끊긴 꼬리(carry)
  wd_last_line=""
  wd_carry=""
  # 한 tick 에서 읽을 최대 줄 수. 상한이 없으면 폭주 로그에서 드레인이 tick 을 무한히
  # 붙잡는다.
  # 실측(bash 3.2.57/macOS, 80바이트 줄):
  #   정지된 파일        — 2,000줄 62ms (줄당 약 31µs)
  #   초당 약 1.9GB 폭주 — 500줄 196~507ms / 100줄 14~254ms / 2,000줄 152~650ms
  # 폭주 시 비용은 줄 수보다 **쓰기와의 I/O 경합**이 지배하므로 상한을 더 낮춰도 비례해
  # 줄지 않는다. 그래서 표시 신선도와 tick 정밀도의 절충으로 500 을 쓴다.
  # 상한·유휴 판정은 tick 수가 아니라 `date` 벽시계로 하므로 tick 이 밀려도 **판정 자체는
  # 왜곡되지 않는다**(실측: 극단 폭주에서 tick 이 약 2초로 늘어났지만 절대 상한 8초는
  # 8초에 정확히 발동했다). 밀림의 상한도 시계 점프 보정 임계 30초에 한참 못 미친다.
  # 뒤처지는 방향의 부작용은 heartbeat 가 보여주는 마지막 줄이 조금 낡는 것뿐이다 —
  # 활동 판정에는 「한 줄이라도 읽혔는가」만 필요하므로 영향이 없다.
  WD_DRAIN_MAX=500
  # carry 상한 — 개행 없이 무한히 자라는 한 줄이 메모리를 먹지 않게 한다. 초과하면 버린다
  # (활동 판정에는 영향이 없고, 그 병적인 한 줄의 표시 앞부분만 잃는다).
  WD_CARRY_MAX=4096
  wd_prev_tick="$wd_start"
  wd_date_fail_count=0
  # date 연속 실패 임계 — 시작 시(위 wd_start)와 동일한 fail-open 을 루프 안에서도
  # 보장하기 위한 카운터. TICK 이 1이면 최대 약 10초 관측 공백 후 판정을 포기한다.
  WD_DATE_FAIL_LIMIT=10

  # 타임아웃 확정: 마커를 tmp+mv 로 원자 생성하고 codex 를 종료한다.
  # idle·cap 두 사유가 이 한 경로로 합류하는 것이 계약이다.
  # 마커 내용은 "<사유> <유효상한> <관측기상태>" 세 토큰이다 — 첫 토큰이 사유이므로
  # 기존 파싱(첫 필드만 읽는 코드)과 호환된다. 관측기가 고장나면 유효 상한이
  # ABS_CAP 보다 조여지는데(effective_cap), 사유가 idle·cap 두 값으로만 합류하는
  # 탓에 부모가 "몇 초에서 죽었는지"·"관측기가 살아 있었는지"를 마커만으로는 알 수
  # 없었다 — 그 결과 관측기 고장으로 4초 만에 죽었는데 사용자는 "절대 상한 60초
  # 도달" 을 읽는 거짓 진단이 났다. 이 함수는 호출 시점의 $wd_cap(유효 상한)과
  # $wd_observer_ok 를 그대로 실어 보내 부모가 사실대로 보고하게 한다.
  wd_timeout_exit() {
    local reason="$1" observer_state
    observer_state="$( [ "$wd_observer_ok" -eq 1 ] && echo ok || echo failed )"
    # 마커는 **codex spawn 전에 열어 둔 fd 7** 로 쓴다 — 경로를 다시 해석하지 않으므로
    # 실행 중 codex 가 마커 경로를 symlink 로 바꿔도 sandbox 밖으로 새지 않고, 안정 이름
    # 으로의 rename 도 없으므로 경쟁 대상 자체가 없다.
    # 쓰기는 실패할 수 있다(ENOSPC). **그래도 codex 종료는 반드시 수행한다** — 마커 실패 시
    # kill 전에 빠져나가면 watchdog 은 소멸하는데 codex 는 살아남아 부모의 wait 가 영구
    # 블록한다(회귀). 마커 내용이 비면 부모는 timed_out=0 으로 판정해 exit 1 경로(턴
    # 미완료)로 끝나지만, 그것이 무한 대기보다 낫다.
    printf '%s %s %s\n' "$reason" "$wd_cap" "$observer_state" >&7 2>/dev/null || true
    if [ -n "$codex_pgid" ]; then
      kill -- -"$codex_pgid" 2>/dev/null || true
    else
      kill "$codex_pid" 2>/dev/null || true
    fi
    exit 0
  }

  wd_last_beat="$wd_start"

  # 초를 사람이 읽는 형태로 (1h55m / 4m12s / 3s)
  wd_hms() {
    local s="$1"
    if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
    elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
    else                         printf '%ds' "$s"
    fi
  }

  # 활동 관측 — **자기 fd(5) 에서 가용한 줄을 드레인한다.** 경로를 다시 열지 않는다.
  #
  # 관측의 본질은 절대 크기가 아니라 「바이트가 새로 나타났는가」다. 그래서 fd 에서 읽히는
  # 것이 있으면 활동이고, 마지막으로 읽은 완성된 줄이 heartbeat 가 보여줄 줄이다.
  # 정규 파일에서는 EOF 에 도달하면 `read` 가 즉시 실패로 돌아오므로 블록되지 않는다.
  # `set -o pipefail` + `errexit` 아래에서 **EOF 의 read 실패가 서브셸을 죽이지 않게**
  # `|| rc=$?` 로 반드시 가드한다 (드레인 루프가 그 함정 위에 있다).
  # EOF 이면서 값이 비어 있지 않은 경우는 **개행 없이 끊긴 꼬리**이고 그 바이트는 이미
  # 소비됐으므로 carry 에 이어 붙여 다음 tick 의 앞부분으로 되돌린다.
  # 결과는 두 전역: wd_drain_seen(1=새 바이트 있었음) / wd_last_line(완성된 마지막 비공백 줄).
  wd_drain_seen=0
  wd_drain_log() {
    wd_drain_seen=0
    [ "$wd_log_fd_open" -eq 1 ] || return 0
    local n=0 rc line
    while [ "$n" -lt "$WD_DRAIN_MAX" ]; do
      line=""
      rc=0
      IFS= read -r line <&5 || rc=$?
      if [ "$rc" -ne 0 ]; then
        if [ -n "$line" ]; then
          wd_drain_seen=1
          wd_carry="${wd_carry}${line}"
          [ "${#wd_carry}" -gt "$WD_CARRY_MAX" ] && wd_carry=""
        fi
        break
      fi
      n=$(( n + 1 ))
      wd_drain_seen=1
      line="${wd_carry}${line}"
      wd_carry=""
      case "$line" in
        *[![:space:]]*) wd_last_line="$line" ;;
      esac
    done
    return 0
  }

  # 상태 snapshot 쓰기 — **heartbeat 와 분리한다.** heartbeat 주기(기본 60초)에 얹으면
  # 유효 상한이 그보다 짧을 때 상태 파일이 한 번도 갱신되지 않은 채 종료된다.
  # 계약이 설정값에 따라 지켜지기도 안 지켜지기도 하는 상태가 되므로 별도 함수로 둔다.
  # 진행 중 갱신은 **안정 이름을 건드리지 않고** 스트림 fd 에만 append 한다(status_append).
  # 각 블록은 구분선으로 시작하는 **완전한 snapshot** 이므로 읽는 쪽이 마지막 블록만 보면
  # 되고, 부분 기록도 블록 단위로 식별된다.
  # 보존 키(log_preserved / log_path_final)도 함께 써서 **어느 시점의 블록이든 완전**하게
  # 둔다 — 아직 판정되지 않았다는 사실을 pending 으로 정직하게 표현한다.
  wd_write_status() {  # $1=요약줄 $2=로그마지막줄 $3=유효상한
    {
      printf '%s\n' "$1"
      [ -n "$2" ] && printf '  codex: %s\n' "$2"
      printf 'log_path: %s\n' "$codex_log"
      printf 'status_stream: %s\n' "$status_stream"
      printf 'observer: %s\n' "$( [ "$wd_observer_ok" -eq 1 ] && echo ok || echo failed )"
      printf 'effective_cap: %ss\n' "$3"
      printf 'log_preserved: pending\n'
      printf 'log_path_final: (미정)\n'
      :
    } | status_append || true
  }

  # heartbeat 는 **표시 전용**이며 유휴 타이머를 갱신하지 않는다.
  # (어댑터가 스스로 만든 신호로 자기 타이머를 갱신하면 유휴 판별이 무력해진다.)
  wd_emit_beat() {
    local cur="$1" cap="$2" line idle_field last_line=""
    if [ "$IDLE_TIMEOUT" -gt 0 ] && [ "$wd_observer_ok" -eq 1 ]; then
      idle_field="유휴여유 $(wd_hms $(( IDLE_TIMEOUT - (cur - wd_last_activity) )))"
    else
      idle_field="유휴여유 없음(판별 비활성)"
    fi
    line="[review wait] 경과 $(wd_hms $(( cur - wd_start ))) | 마지막 활동 $(wd_hms $(( cur - wd_last_activity ))) 전 | ${idle_field} | 상한 $(wd_hms $(( cap - (cur - wd_start) )))"
    echo "$line" >&2
    # 로그 마지막 줄은 **드레인이 이미 읽어 둔 값**이다 — 경로를 다시 열지 않는다
    # (종전 `grep ... "$codex_log" | tail -1` 이 세션 밖 파일 내용을 stderr 와 상태
    # 스트림으로 끌어낼 수 있었던 지점이다). 개행 없이 끊긴 꼬리는 아직 완성되지 않았으므로
    # 표시하지 않는다 — 다음 tick 에 완성되면 나타난다.
    last_line="$wd_last_line"
    [ -n "$last_line" ] && echo "  └ codex: ${last_line}" >&2
    # 진행 중에는 안정 이름 상태 파일이 없으므로, 상태 snapshot 의 **실제 경로**를 매
    # heartbeat 에 함께 낸다 (진행 가시성의 권위는 이 stderr 줄이다).
    echo "  └ 상태 스트림: ${status_stream}" >&2

    wd_write_status "$line" "$last_line" "$cap"
  }

  while :; do
    # fd 9 에는 아무도 쓰지 않는다 — 이 read 는 순수 TICK 타이머다. 항상 타임아웃으로만
    # 깨어나며(반환값은 성공/실패만 판정, 위 주석 참조), watchdog 의 유일한 종료 경로는
    # 부모의 `kill "$watchdog_pid"`(fd 9 가 닫히며 read 가 즉시 실패로 깨어남) 뿐이다.
    read -t "$TICK" -u 9 _dummy && exit 0

    wd_cur="$(wd_now)"
    if [ -z "$wd_cur" ]; then
      # date 가 계속 실패하면 상한·유휴 판정 자체가 영영 일어나지 않아 watchdog 이
      # 상속한 fd 를 쥔 채 무한히 tick 하는 새 회귀가 생긴다(구 read -t "$ABS_CAP" 는
      # date 와 무관하게 절대 상한을 보장했다). 연속 실패가 임계를 넘으면 시작 시와
      # 동일하게 판정을 포기(exit 0, 부모의 wait 에 위임)한다.
      wd_date_fail_count=$(( wd_date_fail_count + 1 ))
      [ "$wd_date_fail_count" -ge "$WD_DATE_FAIL_LIMIT" ] && exit 0
      continue
    fi
    wd_date_fail_count=0

    # 시계 점프 보정 — 시스템 절전·NTP 스텝으로 tick 간격이 크게 벌어지면(예: 노트북
    # 뚜껑을 12분 닫았다 열기) 그 정지 구간 동안 codex 프로세스도 함께 얼어 있었으므로
    # 진행이 없었던 것을 유휴로 오판하면 안 된다. 초과분을 wd_start 와 wd_last_activity
    # 양쪽에 같이 밀어 넣어 총 경과·유휴 경과 계산에서 정지 구간을 제외한다(둘 다
    # 밀지 않으면 상한 판정만 왜곡되고 유휴 판정은 여전히 오판한다).
    #
    # 보정 임계는 TICK*5 가 아니라 **max(30, TICK*5)** 다 — TICK*5(기본 5초) 하나만
    # 쓰면 고부하·스왑으로 1초 루프가 지속적으로 6초씩 밀리는 상황(codex 는 정상
    # 진행 중)에서도 매 tick 이 "정지 구간"으로 오판되어, tick 마다 회계상 경과가
    # TICK(1초)씩만 늘어난다. 그러면 절대 상한의 의미가 "벽시계 ABS_CAP 초" 가 아니라
    # "ABS_CAP 번의 tick" 으로 바뀌어, 부하가 지속되면 상한이 조용히 몇 배로 늘어난다
    # (유휴 판정도 같은 방식으로 무기한 연기된다). 절대 상한은 유휴 판별이 무력화됐을
    # 때의 최후 방어선이므로 부하 상황에서 늘어나면 안 된다. 30초를 넘는 tick 간격은
    # 통상적인 스케줄링 지연이 아니라 프로세스 자체가 멈춰 있었다는 뜻(시스템 절전·
    # SIGSTOP·극단적 기아)이고, 그런 구간만 codex 도 함께 얼어 있다고 볼 수 있다.
    # TICK 이 커질 수 있으므로 TICK*5 항은 유지하고 둘 중 큰 값을 쓴다(bash 3.2 에
    # max 가 없어 if 로 계산).
    wd_gap=$(( wd_cur - wd_prev_tick ))
    wd_jump_threshold=$(( TICK * 5 ))
    [ "$wd_jump_threshold" -lt 30 ] && wd_jump_threshold=30
    if [ "$wd_gap" -gt "$wd_jump_threshold" ]; then
      wd_jump=$(( wd_gap - TICK ))
      wd_start=$(( wd_start + wd_jump ))
      wd_last_activity=$(( wd_last_activity + wd_jump ))
    fi
    wd_prev_tick="$wd_cur"

    # (1) 활동 관측 — **내 fd 에서 새 바이트가 읽혔는가**가 codex 발 진행의 증거다.
    # 종전의 `wc -c < "$codex_log"` 는 매 tick 가변 경로를 호출자 권한으로 다시 열었고,
    # 그것이 정보 노출 창이었다(경로를 세션 밖 파일 symlink 로 바꾸면 그 마지막 줄이
    # heartbeat 로 새어 나갔다). 이제 경로를 쓰지 않으므로 그 창이 없고, `wc`·`tr` fork 도
    # 사라진다.
    #
    # **크기 감소(truncation) 감지는 이 채널에서 의미를 잃는다.** 기준이 「경로의 절대
    # 크기」가 아니라 「내 fd 에서 새 바이트가 보이는가」로 바뀌었기 때문이다. 외부의
    # truncate·unlink·경로 교체는 내 fd 가 가리키는 inode 를 바꾸지 못하므로 관측을
    # **훼손하지 못한다**(codex 도 spawn 시 열린 자기 fd 로 같은 inode 에 계속 쓴다).
    # 훼손이 가능한 유일한 방향은 「새 바이트가 보이지 않는」 쪽이고, 그것은 활동 없음과
    # 구별할 필요가 없다 — 유휴 판정과 절대 상한이 그대로 받아 안전하게 종료시킨다.
    # 그래서 관측기 고장(wd_observer_ok=0)의 조건은 **관측 채널 자체를 확보하지 못한
    # 경우 하나로 재정의**한다(위 wd_observer_ok 초기화 — codex spawn 전 fd 5 open 실패).
    # 이 재정의로 경로 사보타주는 「관측기 고장」이 아니라 「사후 로그 보존 실패」로만
    # 나타난다(cleanup 의 log-vanished-during-run / log-source-replaced).
    if [ "$wd_observer_ok" -eq 1 ]; then
      wd_drain_log
      if [ "$wd_drain_seen" -eq 1 ]; then
        wd_last_activity="$wd_cur"
      fi
    fi

    # 전환을 1회만 보고한다 (매 tick 반복 금지).
    # **stderr 와 상태 파일 둘 다에 즉시 쓴다** — heartbeat 주기를 기다리지 않는다.
    if [ "$wd_observer_ok" -eq 0 ] && [ "$wd_observer_reported" -eq 0 ]; then
      wd_observer_reported=1
      wd_fb_cap="$(effective_cap "$ABS_CAP" 0 "$OBSERVER_FALLBACK_CAP")"
      echo "경고: 활동 관측기가 동작하지 않습니다(로그 관측 fd 확보 실패) — 유휴 판별을 끄고 유효 상한을 ${wd_fb_cap}초로 조입니다(어댑터 시작 기준 총 경과)." >&2
      wd_write_status \
        "[review wait] 관측기 고장 — 유휴 판별 중지, 유효 상한 ${wd_fb_cap}초(총 경과 기준)" \
        "" "$wd_fb_cap"
    fi

    # (2) 유효 상한 — 관측기가 죽었으면 min(ABS_CAP, OBSERVER_FALLBACK_CAP) 로 조인다.
    #     기준은 **어댑터 시작 시점부터의 총 경과**이며, 고장 시점부터 새로 재지 않는다.
    wd_cap="$(effective_cap "$ABS_CAP" "$wd_observer_ok" "$OBSERVER_FALLBACK_CAP")"
    [ $(( wd_cur - wd_start )) -ge "$wd_cap" ] && wd_timeout_exit cap

    # (3) 유휴 판정 — 관측기가 정상이고 유휴 판별이 켜져 있을 때만.
    if [ "$wd_observer_ok" -eq 1 ] && [ "$IDLE_TIMEOUT" -gt 0 ]; then
      [ $(( wd_cur - wd_last_activity )) -ge "$IDLE_TIMEOUT" ] && wd_timeout_exit idle
    fi

    # (4) heartbeat — 판정 뒤에 둔다. 죽일 tick 에서는 표시하지 않는다.
    if [ $(( wd_cur - wd_last_beat )) -ge "$HEARTBEAT_INTERVAL" ]; then
      wd_emit_beat "$wd_cur" "$wd_cap"
      wd_last_beat="$wd_cur"
    fi
  done
) &
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
