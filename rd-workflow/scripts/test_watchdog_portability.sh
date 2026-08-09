#!/usr/bin/env bash
# test_watchdog_portability.sh — adapter_codex.sh watchdog 계약·이식성 probe
#
# 실제 어댑터를 호출한다 (로직 재구현 금지 — 재구현하면 어댑터가 회귀해도 통과한다).
#
# 판정 항목
#   0. ps 신뢰성 self-check
#   1. 정상 완료 후 고아 타이머 자손 0개                          (AC1)
#   2. 호출자 파이프가 상한 내 닫힘                                (AC2)
#   3. 타임아웃 경로 exit 124 + 전용 TMPDIR 잔존 0                 (계측 status 매핑 계약 + AC4)
#   4. startup 실패 — mkfifo 실패                                  (AC8a)
#   5. startup 실패 — fifo open 실패(EISDIR)                       (AC8b)
#   6. TMPDIR 미설정 정상 경로                                     (AC10-1)
#   7. TMPDIR 사용자 지정 정상 경로 + 전용 디렉터리 잔존 0          (AC10-2)
#   8. 신호(TERM) 계약 — rc 143 / codex 자손 소멸 / 파이프 / 잔존 0 (AC9)
#   9. 타임아웃 중 codex 가 자손 보유 → 자손 소멸                  (I8)
#  10. codex 가 자손을 남기고 정상 종료 → 자손 소멸                (I8)
#  11. TERM 을 무시하는 자손 → escalation 으로 소멸                (I8)
#
# 이식성 규칙 (모두 실측 근거)
#   - ps 는 `-eo pid,args` / `-eo pid,pgid` 를 쓴다. `-eo pid,command` 는 busybox 에서
#     실패하고 그 실패가 wc -l 에서 0 으로 집계되어 "고아 0개" 라는 거짓 통과를 만든다.
#   - `ps -o ... -p <pid>` 를 쓰지 않는다. busybox 는 -p 를 지원하지 않는다.
#   - 파이프 종료 판정에 kill -0 를 쓰지 않는다. reap 전 좀비를 생존으로 오판한다
#     (Alpine bash 5.3 에서 실제 오판 발생). 파이프라인 뒤에 기록되는 sentinel 로 판정한다.
#   - 자원 누수는 per-sandbox TMPDIR 안에서 절대 개수 0 으로 본다. 전역 개수 델타는
#     동시 실행 세션의 정상 정리가 이번 실행의 누수를 상쇄해 위음성이 된다.
#   - find / ps / grep -c 의 non-zero 종료는 || true 로 격리한다 (set -euo pipefail 아래에서
#     호출 지점이 조용히 중단되는 것을 막는다).
#
# 프로세스 소유권 (검출·정리의 유일한 근거)
#   이 probe 는 결함 코드를 의도적으로 실행하는 gate 이므로 고아를 만들고, 검출한 뒤
#   반드시 회수해야 한다. 회수 대상 식별은 **명령행 패턴이 아니라 process group** 으로 한다.
#     - 명령행 패턴(`sleep <값>`)은 소유권 증거가 아니다. 같은 값을 쓰는 다른 사용자·테스트·
#       프로젝트의 프로세스를 종료할 수 있고, `sleep 3` 같은 흔한 값에서는 특히 위험하다.
#     - 각 판정은 어댑터를 `set -m` 으로 **자체 process group 리더**로 띄운다. process group 은
#       자손에게 상속되고 부모가 죽어 고아가 되어도 바뀌지 않으므로, 그 pgid 의 구성원이라는
#       사실이 곧 "이번 판정이 만든 프로세스" 라는 증거다
#       (macOS bash 3.2 / Alpine bash 5.3 / Ubuntu bash 5.2 에서 그룹 분리·상속·회수 실측).
#     - 고아 검출도 같은 근거를 쓴다 — 어댑터 종료 후 그 그룹에 남은 구성원 수가 곧 고아 수다.
#     - 자기 자신의 그룹과 같으면 종료하지 않는다(fail-safe). 그룹 확정에 실패하면 판정을
#       통과시키지 않고 fail 로 보고한다.
#   WAIT_TIMEOUT 값은 판정 로그를 구분하기 위한 표시이며 **안전 장치가 아니다.** 아래 salt 는
#   bounded 계산이라 유일성을 보장하지 않지만(주석 참조), 값이 겹쳐도 무관한 프로세스를
#   종료할 수 없다 — 종료 대상 식별에 값을 전혀 쓰지 않기 때문이다.
#
# 사용법: bash test_watchdog_portability.sh [adapter_path]
# Linux 검증 (repo 를 마운트해 실제 어댑터를 검사한다):
#   docker run --rm -v "$PWD:/w" -w /w bash:5.3 \
#     bash rd-workflow/scripts/test_watchdog_portability.sh /w/rd-workflow/scripts/adapter_codex.sh
#   docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 \
#     bash rd-workflow/scripts/test_watchdog_portability.sh /w/rd-workflow/scripts/adapter_codex.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="${1:-${script_dir}/adapter_codex.sh}"
FAILS=0
CAP=8          # 파이프 EOF 상한(초)

# 판정별 WAIT_TIMEOUT 값. 타임아웃이 발화하면 안 되는 판정은 충분히 큰 값을 쓴다.
#
# salt 는 **bounded 값이며 유일성을 보장하지 않는다.** $$ 하위 5자리가 같고 RANDOM 하위
# 3자리까지 같으면 두 실행이 같은 값을 갖는다. 절단이 필요한 이유는 상한 때문이다 —
# 밴드(1억 단위)를 더한 뒤에도 2^31 아래여야 busybox sleep 이 파싱한다.
# 겹쳐도 안전한 이유는 값이 종료 대상 식별에 전혀 쓰이지 않기 때문이다(소유권 = process group).
# 이 값의 역할은 판정 로그 판독 편의뿐이다.
RUN_SALT=$(( ($$ % 100000) * 1000 + (RANDOM % 1000) ))
T_ORPHAN=$(( 100000000 + RUN_SALT ))
T_PIPE=$((   200000000 + RUN_SALT ))
T_DESC=$((   300000000 + RUN_SALT ))
T_QUICK=$((  400000000 + RUN_SALT ))
T_SIG=$((    500000000 + RUN_SALT ))
T_EXIT=$((   600000000 + RUN_SALT ))
# mock 자신이 전경에서 대기할 때 쓰는 값 (판정 로그 구분용).
T_MOCK=$((   700000000 + RUN_SALT ))

if [ ! -f "$ADAPTER" ]; then
  echo "어댑터를 찾을 수 없습니다: $ADAPTER" >&2
  exit 1
fi

ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }

ps_trustworthy() {
  local n
  n="$( { ps -eo pid 2>/dev/null || true; } | grep -c "^ *$$\$" || true )"
  [ "$n" -ge 1 ]
}

own_pgid() {  # $1: pid → 그 pid 의 pgid (관측 불가 시 빈 문자열)
  { ps -eo pid,pgid 2>/dev/null || true; } | awk -v p="$1" '$1==p {print $2; exit}'
}

group_size() {  # $1: pgid → 살아 있는 구성원 수
  local g="${1:-}"
  [ -n "$g" ] || { echo 0; return; }
  { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$g" '$2==g' | wc -l | tr -d ' '
}

SELF_PGID="$(own_pgid $$)"

# 지정 디렉터리 안의 watchdog 임시 디렉터리 개수 (절대 개수)
leftover_in() {
  { find "$1" -maxdepth 1 -type d -name 'rd-watchdog.*' 2>/dev/null || true; } | wc -l | tr -d ' '
}

# 명령을 자체 process group 리더로 띄운다. JOB=리더 pid, GROUP_PGID=확인된 pgid.
# 확인은 "pgid 가 리더 pid 인 구성원이 존재하는가" 로 한다 — 리더가 즉시 종료해도
# 자손이 남았다면 그룹 행으로 확인되고, 오탐은 불가능하다 (pgid == 그룹 리더의 pid).
JOB=""
GROUP_PGID=""
spawn_group() {  # $1: 로그 경로, 나머지: 실행할 명령
  local log="$1" i; shift
  set -m
  "$@" < /dev/null > "$log" 2>&1 &
  JOB=$!
  set +m
  GROUP_PGID=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(group_size "$JOB")" -gt 0 ]; then GROUP_PGID="$JOB"; break; fi
    sleep 0.05
  done
}

# 소유권이 확인된 그룹만 종료한다. 자기 그룹·빈 그룹은 건드리지 않는다.
reap_group() {  # $1: pgid
  local g="${1:-}"
  [ -n "$g" ] || return 0
  if [ -n "$SELF_PGID" ] && [ "$g" = "$SELF_PGID" ]; then return 0; fi
  [ "$(group_size "$g")" -gt 0 ] || return 0
  kill -9 -- -"$g" 2>/dev/null || true
  return 0
}

reap_pidfile() {  # $1: pid 파일 — 우리가 만든 mock 이 기록한 정확한 PID
  local p
  p="$(cat "$1" 2>/dev/null || echo)"
  [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  return 0
}

# 이 판정이 만든 프로세스를 소유권 근거로 전부 회수한다.
#   ① 판정 그룹  — 어댑터·watchdog 고아·파이프의 cat, 그리고 결함 어댑터에서는 codex 자손까지
#                  (결함 어댑터는 set -m 을 쓰지 않아 codex 도 이 그룹에 들어온다)
#   ② codex 그룹  — 수정된 어댑터는 codex 를 자체 그룹으로 띄우므로 ①에 포함되지 않는다.
#                  mock 이 기록한 자기 pid 가 곧 그 그룹의 pgid 다.
#   ③ 기록된 PID  — 우리가 만든 mock 이 남긴 정확한 pid (provenance 로 소유권 확인)
reap_owned() {  # $1: sandbox, $2: 판정 그룹 pgid
  local cp
  reap_group "${2:-}"
  cp="$(cat "$1/codex.pid" 2>/dev/null || echo)"
  if [ -n "$cp" ]; then
    reap_group "$cp"
    kill -9 "$cp" 2>/dev/null || true
  fi
  reap_pidfile "$1/child.pid"
  return 0
}

# 회수 → reap 을 한 묶음으로 수행한다. 순서가 중요하다 — fd 보유자가 남은 채 wait 하면
# cat 이 EOF 를 못 받아 무한 대기한다(Ubuntu 실측).
# 블록 전체의 stderr 를 버리는 이유: 그룹을 kill -9 로 회수하면 bash 가 job 상태 변경을
# `... Killed: 9 ...` 로 보고하는데, 이는 판정과 무관한 소음이며 실패 판정 로그를 가린다.
finish_job() {  # $1: sandbox, $2: 판정 그룹 pgid, $3: job pid
  {
    reap_owned "$1" "${2:-}"
    wait "$3" || true
  } 2>/dev/null
  return 0
}

child_alive() {  # $1: child.pid 경로
  local f="$1" cp
  [ -f "$f" ] || { echo 0; return; }
  cp="$(cat "$f" 2>/dev/null || echo)"
  if [ -n "$cp" ] && kill -0 "$cp" 2>/dev/null; then echo 1; else echo 0; fi
}

# $1: quick | hang | hang_with_child | exit_with_child | stubborn_child
#   quick            : 즉시 턴 완료
#   hang             : 자신이 대기 (exec 로 치환 — 자손 없음. pid 는 유지되므로 codex.pid 유효)
#   hang_with_child  : 자식을 배경 실행하고 자신도 대기 (자손 계약 검증용)
#   exit_with_child  : 자식을 남기고 자신은 턴을 정상 완료 (리더 사망 후 자손 정리 검증)
#   stubborn_child   : TERM 을 무시하는 자식 (escalation 검증)
make_sandbox() {
  local kind="$1" sb
  sb="$(mktemp -d)"
  mkdir -p "$sb/turns" "$sb/mock_bin" "$sb/tmp"
  printf '## Current Owner\nAuthor\n\n## Status\nawaiting-author\n\n## Turn Limit\n20\n' > "$sb/SESSION.md"
  {
    printf '#!/usr/bin/env bash\n'
    # codex 실행 sentinel — 판정 게이트에 쓴다
    printf "echo started > '%s/codex_ran'\n" "$sb"
    # codex 자신의 pid. 수정된 어댑터에서 codex 는 자체 process group 리더이므로
    # 이 값이 곧 그 그룹의 pgid 이며 정리의 소유권 근거가 된다.
    printf "echo \$\$ > '%s/codex.pid'\n" "$sb"
    case "$kind" in
      hang)
        printf 'exec sleep %s\n' "$T_MOCK" ;;
      hang_with_child)
        # 자손 PID 를 파일로 남겨 정확히 추적한다 (패턴 매칭 대신).
        # sleep 에 인자를 2개 주면 BSD sleep 이 usage 오류로 즉시 종료하므로
        # 명령행 태그는 쓸 수 없다. 대신 판정별 duration 을 쓴다.
        printf "sh -c 'exec sleep %s' &\n" "$T_DESC"
        printf "echo \$! > '%s/child.pid'\n" "$sb"
        printf 'sleep %s\n' "$T_MOCK" ;;
      exit_with_child)
        printf "sh -c 'exec sleep %s' &\n" "$T_DESC"
        printf "echo \$! > '%s/child.pid'\n" "$sb"
        printf "touch '%s/turns/turn-001-reviewer.md'\n" "$sb"
        printf "printf '## Current Owner\\nAuthor\\n\\n## Status\\nawaiting-author\\n\\n## Turn Limit\\n20\\n' > '%s/SESSION.md'\n" "$sb"
        printf 'exit 0\n' ;;
      stubborn_child)
        printf "sh -c 'trap \"\" TERM; exec sleep %s' &\n" "$T_DESC"
        printf "echo \$! > '%s/child.pid'\n" "$sb"
        printf 'sleep %s\n' "$T_MOCK" ;;
      *)
        printf "touch '%s/turns/turn-001-reviewer.md'\n" "$sb"
        printf "printf '## Current Owner\\nAuthor\\n\\n## Status\\nawaiting-author\\n\\n## Turn Limit\\n20\\n' > '%s/SESSION.md'\n" "$sb"
        printf 'exit 0\n' ;;
    esac
  } > "$sb/mock_bin/codex"
  chmod +x "$sb/mock_bin/codex"
  echo "$sb"
}

drop_sandbox() { rm -rf "$1" 2>/dev/null || true; }

# $1=sandbox $2=WAIT_TIMEOUT ; 나머지 인자는 앞에 붙일 env 래퍼
run_adapter() {
  local sb="$1" wt="$2"; shift 2
  "$@" env WAIT_TIMEOUT="$wt" TOOL_BIN="$sb/mock_bin/codex" SESSION_PATH="$sb" \
    PROMPT_FILE=/dev/null EXPECTED_TURN_FILE="$sb/turns/turn-001-reviewer.md" \
    PROJECT_ROOT="$sb" bash "$ADAPTER"
}

# 파이프 경유 실행 본체. spawn_group 이 이 함수를 자체 그룹으로 띄우므로
# 어댑터·watchdog·cat 이 모두 그 그룹에 들어간다.
# sentinel 은 파이프라인 **뒤에** 기록되므로 cat 종료(= 파이프 EOF)와 시점이 일치한다.
piped_body() {  # $1=sandbox $2=WAIT_TIMEOUT
  run_adapter "$1" "$2" env TMPDIR="$1/tmp" 2>&1 | cat > "$1/piped.log"
  echo done > "$1/.piped_done"
}

# 신호 판정 본체 — launch.sh 가 어댑터 pid 를 기록한 뒤 exec 로 자신을 치환한다.
term_body() {  # $1=sandbox
  ( bash "$1/launch.sh"; echo $? > "$1/adapter.rc" ) 2>&1 | cat > "$1/piped.log"
  echo done > "$1/.piped_done"
}

echo "=== watchdog 계약·이식성 probe ($(uname -s) / bash ${BASH_VERSION}) ==="
echo "어댑터: $ADAPTER"

# --- 0. ps 신뢰성 ---
if ps_trustworthy && [ -n "$SELF_PGID" ]; then
  ok "0. ps 가 자기 PID·PGID 를 관측 (고아·소유권 판정 신뢰 가능)"
else
  bad "0. ps 가 자기 PID/PGID 를 관측하지 못함 — 이하 고아·소유권 판정을 신뢰할 수 없음"
fi

# --- 1. 고아 타이머 자손 0개 (AC1) ---
# 검출도 소유권 근거로 한다: 어댑터 종료 후 그 판정 그룹에 남은 구성원이 곧 고아다.
sb="$(make_sandbox quick)"
spawn_group "$sb/o.log" run_adapter "$sb" "$T_ORPHAN" env TMPDIR="$sb/tmp"
g="$GROUP_PGID"
wait "$JOB" 2>/dev/null
sleep 1
if [ -z "$g" ]; then
  bad "1. 판정 그룹을 확정하지 못해 고아 판정 불가"
else
  n="$(group_size "$g")"
  if [ "$n" -eq 0 ]; then
    ok "1. 정상 완료 후 판정 그룹 잔존 프로세스 0개"
  else
    bad "1. 판정 그룹에 잔존 프로세스 ${n}개 (고아 타이머 자손)"
  fi
fi
reap_owned "$sb" "$g"
drop_sandbox "$sb"

# --- 2. 호출자 파이프 EOF (AC2) ---
sb="$(make_sandbox quick)"
spawn_group "$sb/wrap.log" piped_body "$sb" "$T_PIPE"
job="$JOB"; g="$GROUP_PGID"
w=0
while [ "$w" -lt "$CAP" ] && [ ! -f "$sb/.piped_done" ]; do sleep 1; w=$((w + 1)); done
if [ -f "$sb/.piped_done" ]; then
  ok "2. stderr 파이프 수신 시 턴 완료와 함께 파이프 닫힘 (${w}초, 상한 ${CAP}초)"
else
  bad "2. 턴 완료 후에도 파이프가 ${CAP}초 이상 열린 채 유지"
fi
# fd 보유자를 먼저 회수한 뒤 job 을 reap 한다. 그룹 종료가 어댑터·고아·cat 을 한 번에 회수한다.
finish_job "$sb" "$g" "$job"
drop_sandbox "$sb"

# --- 3. 타임아웃 경로 exit 124 + 누수 0 (계측 status 매핑 계약 + AC4) ---
# WAIT_TIMEOUT 은 실제로 발화해야 하므로 짧은 값(3)을 쓴다. 정리는 값이 아니라
# 판정 그룹으로 하므로 흔한 값이어도 무관한 프로세스에 닿지 않는다.
sb="$(make_sandbox hang)"
spawn_group "$sb/o.log" run_adapter "$sb" 3 env TMPDIR="$sb/tmp"
g="$GROUP_PGID"
wait "$JOB" 2>/dev/null
rc=$?
reap_owned "$sb" "$g"
left="$(leftover_in "$sb/tmp")"
if [ "$rc" -eq 124 ] && [ "$left" -eq 0 ]; then
  ok "3. 타임아웃 경로 exit 124 + 전용 TMPDIR 잔존 0"
else
  bad "3. 타임아웃 경로 rc=${rc} (기대 124) 잔존=${left} (기대 0)"
fi
drop_sandbox "$sb"

# --- 4·5. startup 실패 주입 (AC8a·AC8b) ---
# PATH shim 으로 mkfifo 를 가로챈다. mkfifo 는 빌트인이 아니라 외부 명령이므로
# 결정적으로 대체할 수 있고, mktemp 는 정상 성공한 뒤 fifo 단계만 실패한다.
# chmod 000 은 쓰지 않는다 — fifo 경로가 per-run 고유라 사전 지정 불가이고 root 가 mode 를 우회한다.
i=4
for mode in exit1 makedir; do
  sb="$(make_sandbox quick)"
  shim="$sb/shim"; mkdir -p "$shim"
  if [ "$mode" = "exit1" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/mkfifo"
    label="mkfifo 실패"
  else
    # fifo 대신 디렉터리를 만든다 → 부모의 exec 9<> 가 EISDIR 로 실패 (root 도 우회 불가)
    printf '#!/usr/bin/env bash\nmkdir -p "$1"\n' > "$shim/mkfifo"
    label="fifo open 실패 (EISDIR)"
  fi
  chmod +x "$shim/mkfifo"
  spawn_group "$sb/o.log" run_adapter "$sb" "$T_QUICK" env TMPDIR="$sb/tmp" PATH="$shim:$PATH"
  g="$GROUP_PGID"
  wait "$JOB" 2>/dev/null
  rc=$?
  reap_owned "$sb" "$g"
  left="$(leftover_in "$sb/tmp")"
  marker="$( { ls "$sb"/.wait_timeout* 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  ran="$([ -f "$sb/codex_ran" ] && echo 예 || echo 아니오)"
  if [ "$rc" -eq 1 ] && [ "$marker" -eq 0 ] && [ "$ran" = "아니오" ] && [ "$left" -eq 0 ]; then
    ok "${i}. ${label} → exit 1 / 마커 없음 / codex 미실행 / 전용 TMPDIR 잔존 0"
  else
    bad "${i}. ${label} → rc=${rc} 마커=${marker} codex실행=${ran} 잔존=${left}"
  fi
  drop_sandbox "$sb"
  i=$((i + 1))
done

# --- 6·7. TMPDIR 두 경로 (AC10) ---
sb="$(make_sandbox quick)"
spawn_group "$sb/o.log" run_adapter "$sb" "$T_QUICK" env -u TMPDIR
g="$GROUP_PGID"
wait "$JOB" 2>/dev/null
rc=$?
reap_owned "$sb" "$g"
if [ "$rc" -eq 0 ]; then
  ok "6. TMPDIR 미설정 → exit 0 (기본 위치 /tmp 사용)"
else
  bad "6. TMPDIR 미설정 → rc=${rc}"
fi
drop_sandbox "$sb"

sb="$(make_sandbox quick)"
spawn_group "$sb/o.log" run_adapter "$sb" "$T_QUICK" env TMPDIR="$sb/tmp"
g="$GROUP_PGID"
wait "$JOB" 2>/dev/null
rc=$?
reap_owned "$sb" "$g"
left="$(leftover_in "$sb/tmp")"
if [ "$rc" -eq 0 ] && [ "$left" -eq 0 ]; then
  ok "7. TMPDIR 사용자 지정 → exit 0 + 전용 디렉터리 잔존 0 (동시 실행 무관)"
else
  bad "7. TMPDIR 사용자 지정 → rc=${rc} 잔존=${left}"
fi
drop_sandbox "$sb"

# --- 8. 신호(TERM) 계약 (AC9) ---
# 대표 신호는 TERM 이다. background job 에서 SIGINT 은 진입 시 무시로 설정되어
# 전달되지 않으므로(POSIX) INT 로는 검증이 성립하지 않는다. SIGKILL 은 트랩 불가다.
# bash 3.2 의 서브셸에서 $$ 는 부모 PID 이므로(BASHPID 없음) launcher 프로세스를 쓴다.
# codex 실행 sentinel 을 게이트로 확인한다 — sentinel 이 없으면 codex 가 아예 시작되지 않은
# 경로이므로 rc·잔존·파이프가 모두 정상으로 보여 위양성이 된다.
sb="$(make_sandbox hang_with_child)"
cat > "$sb/launch.sh" <<LAUNCH
#!/usr/bin/env bash
echo \$\$ > "$sb/adapter.pid"
exec env TMPDIR="$sb/tmp" WAIT_TIMEOUT=${T_SIG} TOOL_BIN="$sb/mock_bin/codex" SESSION_PATH="$sb" \\
  PROMPT_FILE=/dev/null EXPECTED_TURN_FILE="$sb/turns/turn-001-reviewer.md" \\
  PROJECT_ROOT="$sb" bash "$ADAPTER"
LAUNCH
chmod +x "$sb/launch.sh"
spawn_group "$sb/wrap.log" term_body "$sb"
job="$JOB"; g="$GROUP_PGID"
i=0
while [ "$i" -lt 20 ] && [ ! -f "$sb/codex_ran" ]; do sleep 0.5; i=$((i + 1)); done
if [ ! -f "$sb/codex_ran" ]; then
  bad "8. TERM 계약: codex 가 시작되지 않아 판정 불가 (sentinel 미생성)"
else
  sleep 1
  pre_child="$(child_alive "$sb/child.pid")"
  apid="$(cat "$sb/adapter.pid" 2>/dev/null || echo)"
  kill -TERM "$apid" 2>/dev/null || true
  w=0
  while [ "$w" -lt "$CAP" ] && [ ! -f "$sb/.piped_done" ]; do sleep 1; w=$((w + 1)); done
  closed="$([ -f "$sb/.piped_done" ] && echo 예 || echo 아니오)"
  arc="$(cat "$sb/adapter.rc" 2>/dev/null || echo 미기록)"
  post_child="$(child_alive "$sb/child.pid")"
  left="$(leftover_in "$sb/tmp")"
  if [ "$pre_child" -lt 1 ]; then
    bad "8. TERM 계약: mock 이 자손을 만들지 못해 계약 검증 불가"
  elif [ "$arc" = "143" ] && [ "$post_child" -eq 0 ] && [ "$closed" = "예" ] && [ "$left" -eq 0 ]; then
    ok "8. TERM → rc 143 / codex 자손 소멸 / 파이프 ${w}초 내 닫힘 / 전용 TMPDIR 잔존 0"
  else
    bad "8. TERM → rc=${arc} 자손잔존=${post_child} 파이프닫힘=${closed} 잔존=${left}"
  fi
fi
# 성공·실패·sentinel 미생성 어느 경로에서도 소유권 근거로 전부 회수한 뒤 reap 한다.
finish_job "$sb" "$g" "$job"
drop_sandbox "$sb"

# --- 9·10·11. codex 자손 lifecycle (I8) ---
# 리더 생존과 독립적으로 그룹이 정리되는지 세 경로로 확인한다.
i=9
for kind in hang_with_child exit_with_child stubborn_child; do
  case "$kind" in
    hang_with_child) wt=3;         label="타임아웃 중 자손 보유" ;;
    exit_with_child) wt="$T_EXIT"; label="codex 정상 종료 후 자손 잔존" ;;
    stubborn_child)  wt=3;         label="TERM 무시 자손 escalation" ;;
  esac
  sb="$(make_sandbox "$kind")"
  spawn_group "$sb/wrap.log" piped_body "$sb" "$wt"
  job="$JOB"; g="$GROUP_PGID"
  k=0
  while [ "$k" -lt 20 ] && [ ! -f "$sb/codex_ran" ]; do sleep 0.5; k=$((k + 1)); done
  if [ ! -f "$sb/codex_ran" ]; then
    bad "${i}. ${label} — codex 미실행 (sentinel 없음)"
  else
    pre="$(child_alive "$sb/child.pid")"
    w=0
    while [ "$w" -lt "$CAP" ] && [ ! -f "$sb/.piped_done" ]; do sleep 1; w=$((w + 1)); done
    closed="$([ -f "$sb/.piped_done" ] && echo 예 || echo 아니오)"
    post="$(child_alive "$sb/child.pid")"
    left="$(leftover_in "$sb/tmp")"
    if [ "$pre" -lt 1 ]; then
      bad "${i}. ${label} — mock 이 자손을 만들지 못해 검증 불가"
    elif [ "$post" -eq 0 ] && [ "$closed" = "예" ] && [ "$left" -eq 0 ]; then
      ok "${i}. ${label} — 자손 소멸 / 파이프 ${w}초 내 닫힘 / 잔존 0"
    else
      bad "${i}. ${label} — 자손잔존=${post} 파이프닫힘=${closed} 잔존=${left}"
    fi
  fi
  finish_job "$sb" "$g" "$job"
  drop_sandbox "$sb"
  i=$((i + 1))
done

echo "fails=$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
