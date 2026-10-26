#!/usr/bin/env bash
# review_wait.sh — 리뷰 어댑터 공용 대기 엔진
#
# 두 어댑터(codex·claude)가 공유하는 대기 계약의 단일 구현이다.
# 도구별로 다른 것은 spawn 방식·로그 대상·종료 대상(pgid)·표시 포맷터뿐이다.
# source 전용이며 직접 실행하지 않는다.
#
# 호출자는 아래 RW_* 변수를 **부모 셸에서** 설정한다. watchdog 서브셸은 부모 환경을
# 상속하므로 별도 전달이 없고, 부모의 초기 snapshot·최종 발행도 같은 값을 읽는다.
#
#   RW_TOOL_LABEL                                             — 부모, 어댑터 시작 직후
#   RW_SESSION_DIR RW_STATUS_FILE RW_SNAP_DELIM               — 부모, 쓰기 채널 확보 전
#   RW_LOG_PATH RW_LOG_STABLE RW_STATUS_STREAM_PATH           — 부모, mktemp 직후
#   RW_STATUS_FD RW_STATUS_FD_OPEN RW_LOG_FD RW_MARKER_FD
#   RW_TIMER_FD                                               — 부모, fd open 직후
#   RW_ABS_CAP RW_IDLE RW_TICK RW_HEARTBEAT RW_FALLBACK_CAP
#   RW_OBSERVER_OK                                            — 부모, 임계값 해석 직후
#   RW_TARGET_PGID RW_TARGET_PID                              — 부모, spawn 직후
#   RW_LINE_FORMATTER                                         — 부모 (선택 — codex 는 설정하지 않음)
#   RW_KILL_ESCALATE RW_KILL_GRACE                             — 부모 (선택 — codex 는 설정하지 않음)
#   RW_OUTCOME                                                 — 부모 (선택). 설정하면 최종 상태 파일에
#                                                                `outcome: <값>` 으로 남는다. codex 는 설정하지 않으므로 출력 불변.

# --- 순수 함수 ---

# 부호 없는 정수인가 (빈 값·부호·소수점·문자 전부 거절)
rw_is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# 양의 정수 환경변수를 읽되 부재면 기본값. **무효값은 경고한다** —
# 조용히 기본값으로 바꾸면 사용자가 자신이 지정한 안전 상한·표시 주기가 적용됐다고 오인한다.
rw_resolve_tunable() {  # $1=변수명 $2=기본값
  local name="$1" default="$2" val
  eval "val=\${$name:-}"
  if [ -z "$val" ]; then printf '%s' "$default"; return 0; fi
  if rw_is_uint "$val" && [ "$val" -gt 0 ]; then printf '%s' "$val"; return 0; fi
  echo "경고: $name='${val}' 은 양의 정수가 아닙니다 — 기본값 ${default} 를 사용합니다." >&2
  printf '%s' "$default"
}

# 절대 상한: WAIT_TIMEOUT → POLL_TIMEOUT → 기본값 순으로 "설정됐고 유효한 첫 값".
# 설정됐지만 무효한 값은 경고 후 **무시하고 다음 원천으로 내려간다**
# ("잘못 쓴 변수는 없는 셈 친다" — REQUEST 유효성 규칙).
rw_resolve_abs_cap() {  # $1=기본값
  local default="$1" name val
  for name in WAIT_TIMEOUT POLL_TIMEOUT; do
    eval "val=\"\${$name:-}\""
    [ -n "$val" ] || continue
    if rw_is_uint "$val" && [ "$val" -gt 0 ]; then
      printf '%s' "$val"
      return 0
    fi
    echo "경고: ${name}='${val}' 은 양의 정수가 아닙니다 — 무시하고 다음 원천을 사용합니다." >&2
  done
  printf '%s' "$default"
}

# 유휴 임계: 0 은 유효하며 "유휴 판별 비활성" 을 뜻한다 (이 변수에서만 특별하다).
rw_resolve_idle() {  # $1=기본값
  local default="$1" val="${RD_REVIEW_IDLE_TIMEOUT:-}"
  if [ -z "$val" ]; then
    printf '%s' "$default"
    return 0
  fi
  if rw_is_uint "$val"; then
    printf '%s' "$val"
    return 0
  fi
  echo "경고: RD_REVIEW_IDLE_TIMEOUT='${val}' 은 0 이상의 정수가 아닙니다 — 기본값 ${default} 를 사용합니다." >&2
  printf '%s' "$default"
}

# 유효 상한 계산 — 부수효과 없는 순수 함수. 600초짜리 통합 테스트 없이 검증하기 위해
# 분리한다 (관측기 고장 계약의 핵심 불변식).
rw_effective_cap() {  # $1=abs_cap $2=observer_ok(1|0) $3=fallback_cap → stdout
  if [ "$2" -eq 1 ]; then printf '%s' "$1"; return 0; fi
  if [ "$3" -lt "$1" ]; then printf '%s' "$3"; else printf '%s' "$1"; fi
}

# 초를 사람이 읽는 형태로 (1h55m / 4m12s / 3s)
rw_hms() {
  local s="$1"
  if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else                         printf '%ds' "$s"
  fi
}

# heartbeat 표시 포맷터 훅 — 표시 전용 변환. 원본 로그와 활동 관측은 영향을 받지 않는다
# (관측은 fd 의 새 바이트 유무이지 내용이 아니다).
# 훅이 없으면 **원본 그대로** 반환한다. 여기서 길이를 건드리면 포맷터를 쓰지 않는
# codex 의 출력까지 바뀐다(동작 불변 조건 위반) — **절단 책임은 전적으로 포맷터에 있다.**
rw_display_line() {  # $1=원본 줄 → stdout
  if [ -z "${RW_LINE_FORMATTER:-}" ]; then
    printf '%s' "$1"
    return 0
  fi
  local shown
  shown="$("$RW_LINE_FORMATTER" "$1" 2>/dev/null)" || shown=""
  [ -n "$shown" ] || shown="$1"
  printf '%s' "$shown"
}

# --- 상태 snapshot 기반 시설 (산출물 수명 계약) ---
#
# 세션 디렉토리는 실행 중인 도구가 쓸 수 있다. 그래서 **도구가 살아 있는 동안에는 안정 이름
# `.review_wait_status` 로 아무것도 쓰지 않는다.**
#
# 왜 mktemp+원자 교체만으로는 부족한가: 검사(`-L`/`-d`)·삭제·`mv` 는 셸에서 하나의 원자
# 연산이 될 수 없다. 도구가 안정 이름을 세션 밖 디렉터리 symlink 로 **타이트한 루프로
# 계속 재생성**하면 검사와 `mv` 사이의 창을 반복 공략할 수 있고, 한 번만 이겨도 그 교체분이
# 세션 밖으로 나간다("한 번만 미리 배치" 가 아니라 반복 공략이 가능하다).
# 또 임시 경로를 mktemp 로 예측 불가하게 만들어도 도구는 세션 디렉터리를 **열거**해 그
# 이름을 찾을 수 있으므로, 이름의 무작위성만으로는 경로 기반 쓰기를 지킬 수 없다.
#
# 그래서 수명을 둘로 나눈다:
#   진행 중 — 갱신은 `mktemp` 로 만든 무작위 스트림 파일에만 하고, 쓰기는 **spawn 전에
#             열어 둔 fd** 로만 한다. 매 갱신이 경로를 다시 해석하지 않으므로 도구가 경로를
#             unlink·symlink 로 바꿔도 어댑터의 쓰기는 원래 inode 로 간다. 안정 이름으로의
#             rename 은 **하지 않는다.**
#   종료 후 — cleanup 이 **process group 종료를 확인한 뒤** 안정 이름으로 1회 발행한다.
#             그 시점에는 symlink 를 심을 주체가 없으므로 rename 경쟁이 구조적으로 사라진다.
#
# 그 결과 **안정 이름 파일은 「실행 중에는 없고 종료 후에 나타난다」** 로 계약이 바뀐다.

# `mv` 는 목적지가 디렉터리(또는 디렉터리를 가리키는 symlink)면 그 **안으로** 옮기고,
# 파일 symlink 면 링크를 따라간다. 도구가 안정 경로 이름으로 세션 밖 디렉터리 symlink 를
# 심으면 산출물이 세션 밖으로 새어 나가고, 상태 파일은 존재하지 않는 경로를 가리킨다.
# 그래서 교체 전에 **그 이름의 symlink 를 링크째 제거**하고(가리키던 대상은 건드리지 않는다),
# 실제 디렉터리면 교체를 **포기**한다(디렉터리는 지우지 않는다).
# 제거와 mv 사이의 좁은 창은 셸 원시 연산으로 닫을 수 없다. 그래서 이 함수는 **process
# group 이 종료된 것을 확인한 뒤에만** 호출한다 — 그 시점에는 창을 공략할 주체가
# 없으므로 경쟁이 구조적으로 사라진다(진행 중에는 안정 이름을 아예 건드리지 않는다).
rw_mv_target_prepare() {  # $1=안정 경로 → 0=교체 가능 / 1=포기
  if [ -L "$1" ]; then rm -f "$1" 2>/dev/null || return 1; fi
  [ -d "$1" ] && return 1
  return 0
}

# 진행 중 갱신 — stdin 으로 받은 **완전한 snapshot** 을 구분선과 함께 스트림에 append 한다.
# **경로를 쓰지 않는다** (spawn 전에 열어 둔 스트림 fd). 그래서 실행 중 도구가 스트림
# 경로를 symlink 로 바꿔도 쓰기가 sandbox 밖으로 새지 않고, 안정 이름과의 경쟁도 없다.
rw_status_append() {  # $1=스트림 fd
  local fd="$1"
  if [ "${RW_STATUS_FD_OPEN:-0}" -ne 1 ]; then
    # stdin 을 비워 writer 가 EPIPE 로 죽지 않게 한다.
    { cat >/dev/null 2>&1 || true; }
    return 1
  fi
  { printf '%s\n' "$RW_SNAP_DELIM"; cat; } >&"$fd" 2>/dev/null || return 1
  return 0
}

# 스트림에서 **마지막 snapshot 블록**만 꺼낸다 (마지막 구분선 이후의 줄들).
rw_status_last_snapshot() {  # $1=스트림 경로 → stdout
  { awk -v d="$RW_SNAP_DELIM" '
      $0 == d { buf = ""; started = 1; next }
      started { buf = buf $0 "\n" }
      END { printf "%s", buf }
    ' "$1" 2>/dev/null || true; }
}

# **매 실행 시작 시** 이번 실행의 설정·경로로 완전한 snapshot 을 원자 초기화한다.
# 이것이 없으면 60초(첫 heartbeat) 미만에 끝나는 실행에서 ① 첫 실행은 네 필드 snapshot 이
# 아예 없고 ② 재실행은 이전 턴의 heartbeat·이미 사라진 임시 log_path·과거 observer·과거
# effective_cap 을 현재 상태처럼 물려받는다. headless 사용자는 그것을 이번 턴 정보로 오인한다.
rw_status_init_snapshot() {  # $1=스트림fd $2=cap $3=idle
  {
    printf '[review wait] 대기 시작 — heartbeat 이전 (cap %ss idle %ss)\n' "$2" "$3"
    printf 'log_path: %s\n' "$RW_LOG_PATH"
    printf 'status_stream: %s\n' "$RW_STATUS_STREAM_PATH"
    printf 'observer: ok\n'
    printf 'effective_cap: %ss\n' "$2"
    printf 'log_preserved: pending\n'
    printf 'log_path_final: (미정)\n'
  } | rw_status_append "$1" || true
}

# 안정 이름 발행 — **process group 종료를 확인한 뒤 cleanup 에서 단 1회** 호출한다.
# 진행 중 스트림의 마지막 snapshot 을 뼈대로 삼고, 관리 키(log_preserved /
# log_preserved_reason / log_path_final / log_path_recovery) 넷을 걷어낸 뒤 이번 실행의
# 최종 값으로 다시 쓴다. 안정 파일은 **터미널 출력을 놓친 사용자의 유일한 사후 단서**다.
# 이 시점에는 경쟁자(도구)가 없으므로 mv 경쟁이 없다. 그래도 목적지 형태 검사는 유지한다 —
# 실행 중 심겨 남아 있는 symlink·디렉터리를 그대로 따라가면 산출물이 세션 밖으로 나간다.
# 실패는 삼키지 않고 1 을 돌려 호출자가 사실대로 보고하게 한다.
# **상태 파일만** 발행한다 — 그룹 확인·로그 이동은 호출자(cleanup)의 책임이다.
rw_publish_final_status() {  # $1=yes|no $2=사유 토큰 $3=회수 가능한 임시 경로(선택)
  local base="" tmp
  # 스트림 경로가 실행 중 symlink 로 대체됐다면 그 내용은 도구가 고른 파일이므로 읽지 않는다.
  if [ -n "$RW_STATUS_STREAM_PATH" ] && [ -f "$RW_STATUS_STREAM_PATH" ] && [ ! -L "$RW_STATUS_STREAM_PATH" ]; then
    base="$( { rw_status_last_snapshot "$RW_STATUS_STREAM_PATH" \
      | grep -v -E '^(log_preserved|log_preserved_reason|log_path_final|log_path_recovery):' \
      || true; } )"
  fi
  case "$base" in
    *'log_path: '*) ;;
    *)
      base="$(printf '%s\n%s\n%s\n%s\n%s' \
        '[review wait] 진행 중 상태 스트림을 읽지 못했습니다 — 아래 필드는 이번 실행 설정 기준입니다' \
        "log_path: ${RW_LOG_PATH}" "status_stream: ${RW_STATUS_STREAM_PATH}" 'observer: unknown' \
        "effective_cap: ${RW_ABS_CAP}s")"
      ;;
  esac
  tmp="$(mktemp "${RW_SESSION_DIR}/.review_wait_status.XXXXXX" 2>/dev/null || true)"
  [ -n "$tmp" ] || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  {
    printf '%s\n' "$base"
    printf 'log_preserved: %s\n' "$1"
    [ -n "$2" ] && printf 'log_preserved_reason: %s\n' "$2"
    if [ "$1" = yes ]; then
      printf 'log_path_final: %s\n' "$RW_LOG_STABLE"
    else
      printf 'log_path_final: %s\n' '(없음)'
    fi
    [ -n "${3:-}" ] && printf 'log_path_recovery: %s\n' "$3"
    # 종료 사유 — **`RW_OUTCOME` 이 설정된 경우에만** 렌더링한다. 설정하지 않는 도구
    # (codex)의 상태 파일 내용은 그대로이므로 관측 가능한 동작이 바뀌지 않는다.
    # 이 필드가 없으면 터미널 출력을 놓친 사용자는 디스크만으로 idle/cap/정상/중단을
    # 구별할 수 없다 — 진행 중 snapshot 은 어느 경로에서나 같은 모습이기 때문이다.
    [ -n "${RW_OUTCOME:-}" ] && printf 'outcome: %s\n' "$RW_OUTCOME"
    :
  } > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  if ! rw_mv_target_prepare "$RW_STATUS_FILE"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  mv -f "$tmp" "$RW_STATUS_FILE" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  # 기대 형태를 확인한 뒤에만 성공을 말한다.
  [ -f "$RW_STATUS_FILE" ] && [ ! -L "$RW_STATUS_FILE" ] || return 1
  return 0
}

# --- process group 판정·획득 (구현 보존 — kill -0 로 바꾸지 않는다) ---

# 확인된 process group 에 살아 있는 프로세스가 있는가.
# pgid 조회·판정은 반드시 `ps -eo pid,pgid` + awk 로 한다. `ps -o ... -p <pid>` 는
# busybox ps 가 -p 를 지원하지 않아 빈 값을 돌려주고, 그러면 그룹 종료 경로로 넘어가지
# 못해 자식이 고아로 남아 호출자 파이프를 계속 붙잡는다(Alpine 실측).
rw_group_alive() {  # $1=pgid → 0=생존 / 1=없음
  local pgid="${1:-}"
  [ -n "$pgid" ] || return 1
  local n
  n="$( { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$pgid" '$2==g' | wc -l | tr -d ' ' )"
  [ "$n" -gt 0 ]
}

# pgid 를 spawn 직후에 확정한다. cleanup 은 리더 생존과 독립적으로 이 그룹을
# 종료하므로, 타임아웃이나 도구 정상 종료 이후에도 자손이 남지 않는다.
#
# 조회는 레이스에 걸릴 수 있다 — spawn 직후 ps 가 아직 그 프로세스를 보여주지 않거나
# 리더가 즉시 종료하면 리더 행 조회가 빈 값을 돌려준다. 실측(Ubuntu)에서 이 레이스로
# 그룹 종료 경로를 놓쳤고, 자손이 고아로 남아 호출자 파이프를 계속 붙잡았다.
# 그래서 리더 행만 찾지 않고 **pgid 가 리더 pid 인 구성원이 하나라도 있는지** 조회한다.
# 이 형태가 소유권 확인이면서 레이스에 견딘다 — 리더가 조회 전에 종료했어도 자손이 남았다면
# 그 그룹 행으로 확인되고, 그룹 자체가 없으면 종료할 대상도 없다. 오탐도 불가능하다:
# pgid 는 그 그룹 리더의 pid 이므로 pgid == 리더pid 인 그룹은 그 리더의 그룹뿐이다.
# (리더 행만 조회하면 spawn 직후 레이스로 빈 값이 나와 그룹 종료 경로를 놓친다 — Ubuntu 실측)
rw_acquire_pgid() {  # $1=리더pid → stdout: pgid 또는 빈 값 (10회 재시도 + sleep 0.05)
  local leader_pid="$1" pg="" _pg_try _pg_n
  for _pg_try in 1 2 3 4 5 6 7 8 9 10; do
    _pg_n="$( { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$leader_pid" '$2==g' | wc -l | tr -d ' ' )"
    if [ "$_pg_n" -gt 0 ]; then
      pg="$leader_pid"
      break
    fi
    sleep 0.05
  done
  printf '%s' "$pg"
}

# --- watchdog tick 루프 ---
#
# 부모가 `( rw_watchdog_loop ) &` 로 서브셸에서 호출한다. 인자를 받지 않고 부모가 설정한
# RW_* 변수를 서브셸이 상속해 읽는다.
#
# read -t 는 **TICK(1초) 마다 깨어나는 주기 타이머**다. 절대 마감이 아니라 매 tick 에서
# (1) 활동 관측 (2) 상한 판정 (3) 유휴 판정 (4) heartbeat 를 수행한다.
rw_watchdog_loop() {
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
  wd_observer_ok="$RW_OBSERVER_OK"   # 관측 fd 를 확보하지 못했으면 시작부터 고장
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

  # 타임아웃 확정: 마커를 tmp+mv 로 원자 생성하고 대상을 종료한다.
  # idle·cap 두 사유가 이 한 경로로 합류하는 것이 계약이다.
  # 마커 내용은 "<사유> <유효상한> <관측기상태>" 세 토큰이다 — 첫 토큰이 사유이므로
  # 기존 파싱(첫 필드만 읽는 코드)과 호환된다. 관측기가 고장나면 유효 상한이
  # ABS_CAP 보다 조여지는데(rw_effective_cap), 사유가 idle·cap 두 값으로만 합류하는
  # 탓에 부모가 "몇 초에서 죽었는지"·"관측기가 살아 있었는지"를 마커만으로는 알 수
  # 없었다 — 그 결과 관측기 고장으로 4초 만에 죽었는데 사용자는 "절대 상한 60초
  # 도달" 을 읽는 거짓 진단이 났다. 이 함수는 호출 시점의 $wd_cap(유효 상한)과
  # $wd_observer_ok 를 그대로 실어 보내 부모가 사실대로 보고하게 한다.
  wd_timeout_exit() {
    local reason="$1" observer_state
    observer_state="$( [ "$wd_observer_ok" -eq 1 ] && echo ok || echo failed )"
    # 마커는 **spawn 전에 열어 둔 마커 fd** 로 쓴다 — 경로를 다시 해석하지 않으므로
    # 실행 중 도구가 마커 경로를 symlink 로 바꿔도 sandbox 밖으로 새지 않고, 안정 이름
    # 으로의 rename 도 없으므로 경쟁 대상 자체가 없다.
    # 쓰기는 실패할 수 있다(ENOSPC). **그래도 대상 종료는 반드시 수행한다** — 마커 실패 시
    # kill 전에 빠져나가면 watchdog 은 소멸하는데 대상은 살아남아 부모의 wait 가 영구
    # 블록한다(회귀). 마커 내용이 비면 부모는 timed_out=0 으로 판정해 exit 1 경로(턴
    # 미완료)로 끝나지만, 그것이 무한 대기보다 낫다.
    printf '%s %s %s\n' "$reason" "$wd_cap" "$observer_state" >&"$RW_MARKER_FD" 2>/dev/null || true
    if [ -n "$RW_TARGET_PGID" ]; then
      kill -- -"$RW_TARGET_PGID" 2>/dev/null || true
    else
      kill "$RW_TARGET_PID" 2>/dev/null || true
    fi

    # 리더가 TERM 을 무시하면 부모의 wait 가 복귀하지 않아 cleanup 의 KILL 단계에 영원히
    # 닿지 못한다. 그래서 **리더의 wait 복귀와 독립적으로** 여기서 escalate 한다.
    # SIGKILL 은 무시할 수 없으므로 부모의 wait 가 반드시 복귀한다.
    # 이 동작은 RW_KILL_ESCALATE=1 일 때만 켜진다 — codex 는 설정하지 않으므로
    # codex 의 관측 가능한 동작은 바뀌지 않는다.
    if [ "${RW_KILL_ESCALATE:-0}" = 1 ]; then
      # grace 는 **`sleep` 자식을 두지 않는다.** watchdog 셸만 kill 되면 sleep 이 고아로
      # 남아 상속한 stderr fd 를 붙잡고, 그동안 호출자의 출력 수집이 끝나지 않는다 —
      # 이 어댑터가 fd + `read -t` 로 타이머를 만든 바로 그 이유다. 이미 열려 있는
      # 타이머 fd 를 그대로 쓴다. `read -t` 의 시간 만료 반환값은 bash 3.2 에서 1,
      # 5.x 에서 142 이므로 값을 보지 않고 가드만 한다.
      read -t "${RW_KILL_GRACE:-3}" -r _rw_discard <&"$RW_TIMER_FD" || true

      # 종료 대상 선택은 **TERM 을 보낸 것과 같은 분기**를 쓴다. pgid 조회가 실패했는데
      # (rw_acquire_pgid 는 빈 값을 돌려줄 수 있다) 그룹 분기만 두면, 리더가 TERM 을
      # 무시했을 때 KILL 이 실행되지 않아 부모의 wait 가 그대로 막힌다.
      if [ -n "$RW_TARGET_PGID" ]; then
        if rw_group_alive "$RW_TARGET_PGID"; then
          kill -9 -- -"$RW_TARGET_PGID" 2>/dev/null || true
        fi
      elif [ -n "$RW_TARGET_PID" ] && kill -0 "$RW_TARGET_PID" 2>/dev/null; then
        # **PID fallback 은 자손 전체 회수를 보장하지 못한다** — 확인되지 않은 pgid 를
        # 추정해 그룹 신호를 보내지 않는다(남의 그룹을 죽일 수 있다). 리더만 회수해
        # 부모의 wait 를 푸는 것이 목적이며, 자손 회수는 보장되지 않는다.
        kill -9 "$RW_TARGET_PID" 2>/dev/null || true
      fi
    fi

    exit 0
  }

  wd_last_beat="$wd_start"

  # 상태 snapshot 쓰기 — **heartbeat 와 분리한다.** heartbeat 주기(기본 60초)에 얹으면
  # 유효 상한이 그보다 짧을 때 상태 파일이 한 번도 갱신되지 않은 채 종료된다.
  # 계약이 설정값에 따라 지켜지기도 안 지켜지기도 하는 상태가 되므로 별도 함수로 둔다.
  # 진행 중 갱신은 **안정 이름을 건드리지 않고** 스트림 fd 에만 append 한다(rw_status_append).
  # 각 블록은 구분선으로 시작하는 **완전한 snapshot** 이므로 읽는 쪽이 마지막 블록만 보면
  # 되고, 부분 기록도 블록 단위로 식별된다.
  # 보존 키(log_preserved / log_path_final)도 함께 써서 **어느 시점의 블록이든 완전**하게
  # 둔다 — 아직 판정되지 않았다는 사실을 pending 으로 정직하게 표현한다.
  wd_write_status() {  # $1=요약줄 $2=로그마지막줄 $3=유효상한
    {
      printf '%s\n' "$1"
      [ -n "$2" ] && printf '  %s: %s\n' "$RW_TOOL_LABEL" "$2"
      printf 'log_path: %s\n' "$RW_LOG_PATH"
      printf 'status_stream: %s\n' "$RW_STATUS_STREAM_PATH"
      printf 'observer: %s\n' "$( [ "$wd_observer_ok" -eq 1 ] && echo ok || echo failed )"
      printf 'effective_cap: %ss\n' "$3"
      printf 'log_preserved: pending\n'
      printf 'log_path_final: (미정)\n'
      :
    } | rw_status_append "$RW_STATUS_FD" || true
  }

  # 활동 관측 — **자기 fd(RW_LOG_FD) 에서 가용한 줄을 드레인한다.** 경로를 다시 열지 않는다.
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
    [ "$RW_OBSERVER_OK" -eq 1 ] || return 0
    local n=0 rc line
    while [ "$n" -lt "$WD_DRAIN_MAX" ]; do
      line=""
      rc=0
      IFS= read -r line <&"$RW_LOG_FD" || rc=$?
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

  # heartbeat 는 **표시 전용**이며 유휴 타이머를 갱신하지 않는다.
  # (도구가 스스로 만든 신호로 자기 타이머를 갱신하면 유휴 판별이 무력해진다.)
  wd_emit_beat() {
    local cur="$1" cap="$2" line idle_field last_line=""
    if [ "$RW_IDLE" -gt 0 ] && [ "$wd_observer_ok" -eq 1 ]; then
      idle_field="유휴여유 $(rw_hms $(( RW_IDLE - (cur - wd_last_activity) )))"
    else
      idle_field="유휴여유 없음(판별 비활성)"
    fi
    line="[review wait] 경과 $(rw_hms $(( cur - wd_start ))) | 마지막 활동 $(rw_hms $(( cur - wd_last_activity ))) 전 | ${idle_field} | 상한 $(rw_hms $(( cap - (cur - wd_start) )))"
    echo "$line" >&2
    # 로그 마지막 줄은 **드레인이 이미 읽어 둔 값**이다 — 경로를 다시 열지 않는다
    # (종전 `grep ... | tail -1` 이 세션 밖 파일 내용을 stderr 와 상태
    # 스트림으로 끌어낼 수 있었던 지점이다). 개행 없이 끊긴 꼬리는 아직 완성되지 않았으므로
    # 표시하지 않는다 — 다음 tick 에 완성되면 나타난다.
    # 표시 포맷터 훅을 거친다 — 훅이 없으면 원본 그대로(codex 는 이 경로로 불변).
    last_line="$(rw_display_line "$wd_last_line")"
    [ -n "$last_line" ] && echo "  └ ${RW_TOOL_LABEL}: ${last_line}" >&2
    # 진행 중에는 안정 이름 상태 파일이 없으므로, 상태 snapshot 의 **실제 경로**를 매
    # heartbeat 에 함께 낸다 (진행 가시성의 권위는 이 stderr 줄이다).
    echo "  └ 상태 스트림: ${RW_STATUS_STREAM_PATH}" >&2

    wd_write_status "$line" "$last_line" "$cap"
  }

  while :; do
    # 타이머 fd 에는 아무도 쓰지 않는다 — 이 read 는 순수 TICK 타이머다. 항상 타임아웃으로만
    # 깨어나며(반환값은 성공/실패만 판정, 위 주석 참조), watchdog 의 유일한 종료 경로는
    # 부모의 `kill "$watchdog_pid"`(타이머 fd 가 닫히며 read 가 즉시 실패로 깨어남) 뿐이다.
    read -t "$RW_TICK" -u "$RW_TIMER_FD" _dummy && exit 0

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
    # 뚜껑을 12분 닫았다 열기) 그 정지 구간 동안 대상 프로세스도 함께 얼어 있었으므로
    # 진행이 없었던 것을 유휴로 오판하면 안 된다. 초과분을 wd_start 와 wd_last_activity
    # 양쪽에 같이 밀어 넣어 총 경과·유휴 경과 계산에서 정지 구간을 제외한다(둘 다
    # 밀지 않으면 상한 판정만 왜곡되고 유휴 판정은 여전히 오판한다).
    #
    # 보정 임계는 TICK*5 가 아니라 **max(30, TICK*5)** 다 — TICK*5(기본 5초) 하나만
    # 쓰면 고부하·스왑으로 1초 루프가 지속적으로 6초씩 밀리는 상황(대상은 정상
    # 진행 중)에서도 매 tick 이 "정지 구간"으로 오판되어, tick 마다 회계상 경과가
    # TICK(1초)씩만 늘어난다. 그러면 절대 상한의 의미가 "벽시계 ABS_CAP 초" 가 아니라
    # "ABS_CAP 번의 tick" 으로 바뀌어, 부하가 지속되면 상한이 조용히 몇 배로 늘어난다
    # (유휴 판정도 같은 방식으로 무기한 연기된다). 절대 상한은 유휴 판별이 무력화됐을
    # 때의 최후 방어선이므로 부하 상황에서 늘어나면 안 된다. 30초를 넘는 tick 간격은
    # 통상적인 스케줄링 지연이 아니라 프로세스 자체가 멈춰 있었다는 뜻(시스템 절전·
    # SIGSTOP·극단적 기아)이고, 그런 구간만 대상도 함께 얼어 있다고 볼 수 있다.
    # TICK 이 커질 수 있으므로 TICK*5 항은 유지하고 둘 중 큰 값을 쓴다(bash 3.2 에
    # max 가 없어 if 로 계산).
    wd_gap=$(( wd_cur - wd_prev_tick ))
    wd_jump_threshold=$(( RW_TICK * 5 ))
    [ "$wd_jump_threshold" -lt 30 ] && wd_jump_threshold=30
    if [ "$wd_gap" -gt "$wd_jump_threshold" ]; then
      wd_jump=$(( wd_gap - RW_TICK ))
      wd_start=$(( wd_start + wd_jump ))
      wd_last_activity=$(( wd_last_activity + wd_jump ))
    fi
    wd_prev_tick="$wd_cur"

    # (1) 활동 관측 — **내 fd 에서 새 바이트가 읽혔는가**가 진행의 증거다.
    # 종전의 `wc -c < 로그경로` 는 매 tick 가변 경로를 호출자 권한으로 다시 열었고,
    # 그것이 정보 노출 창이었다(경로를 세션 밖 파일 symlink 로 바꾸면 그 마지막 줄이
    # heartbeat 로 새어 나갔다). 이제 경로를 쓰지 않으므로 그 창이 없고, `wc`·`tr` fork 도
    # 사라진다.
    #
    # **크기 감소(truncation) 감지는 이 채널에서 의미를 잃는다.** 기준이 「경로의 절대
    # 크기」가 아니라 「내 fd 에서 새 바이트가 보이는가」로 바뀌었기 때문이다. 외부의
    # truncate·unlink·경로 교체는 내 fd 가 가리키는 inode 를 바꾸지 못하므로 관측을
    # **훼손하지 못한다**(대상도 spawn 시 열린 자기 fd 로 같은 inode 에 계속 쓴다).
    # 훼손이 가능한 유일한 방향은 「새 바이트가 보이지 않는」 쪽이고, 그것은 활동 없음과
    # 구별할 필요가 없다 — 유휴 판정과 절대 상한이 그대로 받아 안전하게 종료시킨다.
    # 그래서 관측기 고장(wd_observer_ok=0)의 조건은 **관측 채널 자체를 확보하지 못한
    # 경우 하나로 재정의**한다(위 wd_observer_ok 초기화 — spawn 전 관측 fd open 실패).
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
      wd_fb_cap="$(rw_effective_cap "$RW_ABS_CAP" 0 "$RW_FALLBACK_CAP")"
      echo "경고: 활동 관측기가 동작하지 않습니다(로그 관측 fd 확보 실패) — 유휴 판별을 끄고 유효 상한을 ${wd_fb_cap}초로 조입니다(어댑터 시작 기준 총 경과)." >&2
      wd_write_status \
        "[review wait] 관측기 고장 — 유휴 판별 중지, 유효 상한 ${wd_fb_cap}초(총 경과 기준)" \
        "" "$wd_fb_cap"
    fi

    # (2) 유효 상한 — 관측기가 죽었으면 min(ABS_CAP, FALLBACK_CAP) 로 조인다.
    #     기준은 **어댑터 시작 시점부터의 총 경과**이며, 고장 시점부터 새로 재지 않는다.
    wd_cap="$(rw_effective_cap "$RW_ABS_CAP" "$wd_observer_ok" "$RW_FALLBACK_CAP")"
    [ $(( wd_cur - wd_start )) -ge "$wd_cap" ] && wd_timeout_exit cap

    # (3) 유휴 판정 — 관측기가 정상이고 유휴 판별이 켜져 있을 때만.
    if [ "$wd_observer_ok" -eq 1 ] && [ "$RW_IDLE" -gt 0 ]; then
      [ $(( wd_cur - wd_last_activity )) -ge "$RW_IDLE" ] && wd_timeout_exit idle
    fi

    # (4) heartbeat — 판정 뒤에 둔다. 죽일 tick 에서는 표시하지 않는다.
    if [ $(( wd_cur - wd_last_beat )) -ge "$RW_HEARTBEAT" ]; then
      wd_emit_beat "$wd_cur" "$wd_cap"
      wd_last_beat="$wd_cur"
    fi
  done
}
