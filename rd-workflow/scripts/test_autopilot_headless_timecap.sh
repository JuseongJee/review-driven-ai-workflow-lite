#!/usr/bin/env bash
# test_autopilot_headless_timecap.sh — autopilot_headless.sh 의 FR 경과 시간 상한(중단 조건 8) 테스트.
# claude 를 PATH 의 대역으로 바꿔 실제 프로세스 구조(별도 그룹 손자·TERM 무시·TERM 처리기가 낳는 고아)를
# 만들고, 상한 발동 → 후손 회수 → outcome 기록까지 본다. 소수 분(0.03분=약 2초)과 유예 2초로 줄인다.
# 반환 시간은 단언하지 않는다 — wrapper 가 멈추면 워치독이 잡고, 워치독 상한은 회수 수집 1회 비용(COLLECT_MS)에 비례시킨다.
# 함수 단위 케이스(D1~D3)는 wrapper 에서 함수 정의를 뽑아 직접 호출한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/autopilot_headless.sh"
TMP="$(mktemp -d)" || { echo "test_autopilot_headless_timecap.sh: 임시 디렉터리 생성 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_autopilot_headless_timecap.sh: 임시 디렉터리 검증 실패" >&2; exit 1; }
SLEEPS=""
cleanup() {
  # 변이 주입으로 회수가 실패해도 테스트가 띄운 sleep 이 남지 않게 한다.
  local n
  for n in $SLEEPS; do pkill -KILL -f "^sleep (${n}|$((n + 1)))\$" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

FAIL=0
GRACE=2
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=1; }
check() {  # $1=desc $2=조건 결과(0=참)
  if [[ "$2" == 0 ]]; then pass "$1"; else fail "$1"; fi
}

# 프로세스 조회 도구가 이 환경에서 동작하는지 먼저 본다. 안 되면 wrapper 의 후손 회수도, 이 테스트의 생존 확인·
# 정리도 성립하지 않는다. 그런 환경(리뷰어 샌드박스 등)에서는 후손 회수 사례를 띄우지 않고 env-skip 으로 집계한다 —
# 띄우면 회수하지 못한 sleep 이 고아로 남는다. 조회가 필요 없는 사례(T1d·T3·D*)는 그대로 돈다.
pgrep -f '^__timecap_probe_none__$' >/dev/null 2>&1; _prc=$?
PROC_OK=1
if (( _prc > 1 )) || [[ -z "$(ps -A -o pid= 2>/dev/null)" ]]; then PROC_OK=0; PROC_WHY="pgrep rc=${_prc}"; fi
# need_proc <사례>: 프로세스 조회가 되면 0. 안 되면 건너뜀 표식을 내고 1.
need_proc() {
  (( PROC_OK )) && return 0
  printf 'env-skip: test_autopilot_headless_timecap %s — 프로세스 조회(pgrep/ps)를 쓸 수 없는 환경(%s)\n' "$1" "$PROC_WHY" >&2
  echo "  SKIP: $1 — 프로세스 조회 불가(env-skip)"
  return 1
}
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/claude" <<'STUB'
#!/usr/bin/env bash
# 대역 claude. STUB_MODE 로 동작을 고른다.
case "$STUB_MODE" in
  t1)   # TERM 수용 리더 + 별도 프로세스 그룹의 TERM 무시 손자
    trap 'exit 0' TERM
    bash -c 'set -m; (trap "" TERM; exec sleep $STUB_SLEEP) & echo $! > "$STUB_PIDFILE"; wait' &
    wait ;;
  t1b)  # TERM 처리기가 별도 그룹 자식을 낳고 2초 뒤 종료 → 자식은 고아가 된다 (처리기가 즉시 끝나는 경우는 재현하지 않는다)
    trap 'bash -c "set -m; (trap \"\" TERM; exec sleep $STUB_SLEEP) & disown; sleep 2"; exit 0' TERM
    sleep $((STUB_SLEEP+1)) &
    wait $! ;;
  t1c)  # TERM 처리기가 별도 그룹의 TERM 무시 sleep 을 낳고 곧바로 종료 → sleep 은 부모가 먼저 끝난 채 재부모화된다 (pid 를 기록)
    trap 'bash -c "set -m; (trap \"\" TERM; exec sleep $STUB_SLEEP) & echo \$! > \"$STUB_PIDFILE\"; disown"; exit 0' TERM
    sleep $((STUB_SLEEP+1)) &
    wait $! ;;
  t2)   # completed 기록 뒤에도 자식이 살아 있음. 기록 직후의 해시·mtime 을 남겨 wrapper 가 파일을 다시 쓰는지 본다
    printf 'completed\n' > "$RD_AUTOPILOT_OUTCOME_FILE"
    printf '%s %s' "$(shasum < "$RD_AUTOPILOT_OUTCOME_FILE" | awk '{print $1}')" "$(stat -c %Y "$RD_AUTOPILOT_OUTCOME_FILE" 2>/dev/null || stat -f %m "$RD_AUTOPILOT_OUTCOME_FILE")" > "$STUB_SIGFILE"
    sleep $STUB_SLEEP &
    wait $! ;;
  t2b)  # 상한 시점에는 outcome 이 비어 있고, 유예 중 TERM 처리기가 completed 를 늦게 쓴다
    trap 'printf "completed\n" > "$RD_AUTOPILOT_OUTCOME_FILE"; exit 0' TERM
    sleep $STUB_SLEEP &
    wait $! ;;
  quick) printf 'completed\n' > "$RD_AUTOPILOT_OUTCOME_FILE" ;;
  slow3) sleep 3; printf 'completed\n' > "$RD_AUTOPILOT_OUTCOME_FILE"; : > "$STUB_DONE_FILE" ;;
esac
STUB
chmod +x "${TMP}/bin/claude"

# 이번 호출의 대역이 띄운 sleep(고유 길이) 중 생존한 수. 환경 변수를 읽을 수 있는지와 무관하게 센다.
# 프로세스 조회 자체가 실패하면(pgrep rc>1) 0 이 아니라 ERR 을 낸다 — 관측 실패를 「생존 0」 성공으로 세지 않는다.
alive_sleeps() {
  local out rc
  out="$(pgrep -f "^sleep (${STUB_SLEEP}|$((STUB_SLEEP + 1)))\$" 2>/dev/null)"; rc=$?
  if (( rc > 1 )); then echo ERR; else printf '%s' "$out" | grep -c . | tr -d ' ' || true; fi
}

# 생존 sleep 의 pid·ppid·stat·command. T1b 가 부하에서 드물게 FAIL 하는 원인을 다음 관측 때
# 확정하려는 진단이다(FR autopilot-headless-timecap-orphan-reap-flake, 2026-11-01 부하 20회 재현 0건).
alive_sleeps_detail() {
  local p
  for p in $(pgrep -f "^sleep (${STUB_SLEEP}|$((STUB_SLEEP + 1)))\$" 2>/dev/null); do
    ps -o pid=,ppid=,stat=,command= -p "$p" 2>/dev/null
  done
}

load_fn() {
  local body; body="$(sed -n "/^$1()/,/^}/p" "$WRAPPER")"
  if [[ -z "$body" ]]; then fail "함수 $1 를 wrapper 에서 찾지 못함"; return 1; fi
  eval "$body"
}

# 회수 수집 1회(ps 1회 + 세션 ID 조회 1회)가 이 환경에서 걸리는 시간을 재서 워치독 상한에 반영한다.
# 부하에서 ps 1회가 0.6초 → 2~4초로 늘면 회수 일정이 비례해 늘기 때문이다.
# 상한 발동 뒤 수집 호출 수의 상한 12 = 첫 수집 1 + 유예 루프 최대 GRACE+1 + 최종 1 + KILL 재확인 최대 6 + 여유 1 (GRACE=2 기준 3).
# 측정은 perl Time::HiRes 로 한다. 실행되는지는 존재 검사가 아니라 실제 실행 rc 로 판정하고, 실패하면 SECONDS 로 폴백한다.
COLLECT_MS=0; COLLECT_PRECISE=""
load_fn ps_all && load_fn session_pairs && load_fn collect_targets && COLLECT_FNS=1 || COLLECT_FNS=0
PRECISE_NOTE=" — 정밀 측정 불가"
if perl -MTime::HiRes=time -e 1 >/dev/null 2>&1; then COLLECT_PRECISE=1; PRECISE_NOTE=""; fi
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
measure_collect_ms() {
  local i t0 t1 d best=0
  if (( COLLECT_FNS )); then
    for i in 1 2 3; do
      if [[ -n "$COLLECT_PRECISE" ]]; then
        t0=$(now_ms); RD_HEADLESS_SID_MODE=setsid collect_targets "$$" "" "" --session >/dev/null 2>&1; t1=$(now_ms); d=$((t1 - t0))
      else
        t0=$SECONDS; RD_HEADLESS_SID_MODE=setsid collect_targets "$$" "" "" --session >/dev/null 2>&1; d=$(( (SECONDS - t0) * 1000 )); (( d < 1000 )) && d=1000
      fi
      (( d > best )) && best=$d
    done
  fi
  COLLECT_MS=$best
  WATCHDOG=$((30 + GRACE + (12 * COLLECT_MS + 999) / 1000))
}

# run_wrapper <mode> <mark> <cwd> <env...> — outcome/stderr/stdout/elapsed 를 ${TMP}/run-* 에 남긴다.
run_wrapper() {
  local mode="$1" mark="$2" cwd="$3"; shift 3
  STUB_SLEEP=$((RANDOM % 4000 + 2000)); export STUB_SLEEP; SLEEPS="$SLEEPS $STUB_SLEEP"
  : > "${TMP}/run-outcome"; rm -f "${TMP}/stub-pid"
  measure_collect_ms
  local t0=$SECONDS
  ( cd "$cwd" && env PATH="${TMP}/bin:$PATH" STUB_MODE="$mode" STUB_MARK="$mark" \
      STUB_PIDFILE="${TMP}/stub-pid" STUB_DONE_FILE="${TMP}/stub-done" STUB_SIGFILE="${TMP}/stub-sig" \
      RD_AUTOPILOT_FR=probe RD_AUTOPILOT_OUTCOME_FILE="${TMP}/run-outcome" \
      RD_FR_WALL_GRACE_SECONDS="$GRACE" "$@" bash "$WRAPPER" ) \
    >"${TMP}/run-stdout" 2>"${TMP}/run-stderr" &
  local wp=$!
  # 변이로 wrapper 가 멈춰도 테스트가 끝나도록 워치독 (WATCHDOG 초, measure_collect_ms 가 정한다)
  local w
  for ((w = 0; w < WATCHDOG; w++)); do kill -0 "$wp" 2>/dev/null || break; sleep 1; done
  if kill -0 "$wp" 2>/dev/null; then kill -KILL "$wp" 2>/dev/null; RUN_HUNG=1; else RUN_HUNG=0; fi
  wait "$wp" 2>/dev/null; RUN_RC=$?
  RUN_ELAPSED=$((SECONDS - t0)); echo "    (${mode}: ${RUN_ELAPSED}초)"
}
outcome_first() { head -n1 "${TMP}/run-outcome" | tr -d '[:space:]'; }
# mtime 은 GNU 형식(stat -c %Y)을 먼저 쓴다. GNU stat 은 `-f` 를 파일시스템 모드로 읽어, BSD 형식을 먼저 쓰면
# 파일시스템 정보(빈 블록 수 등)가 출력에 섞여 「불변」 단언이 Linux 에서 FAIL 한다. BSD stat 은 `-c` 를 거부한다.
sig() { printf '%s %s' "$(shasum < "$1" | awk '{print $1}')" "$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1")"; }

# ── T1 후손 회수 (진행 중 작업이 있는 임시 저장소에서 실행 — 작업 상태 진단과 작업 파일 불변까지 본다)
# 실제 저장소에서 돌리면 결과가 그 저장소에 진행 중 작업이 있는지에 달려, 작업 없는 저장소(새 clone·소비 프로젝트
# 초기 상태)에서 「작업 상태: 판정 실패」 로 FAIL 했다(FR timecap-test-no-worktree-judgment-fail).
echo "[T1 후손 회수]"
if need_proc T1; then
  FX="${TMP}/t1repo"; mkdir -p "${FX}/rd-workflow-workspace/.lifecycle"
  git -C "$FX" init -q 2>/dev/null || fail "T1 fixture 저장소 생성 실패"
  printf '# Current Task\n\n## Short Title\nt1fx\n\n## Status\n구현 중\n' > "${FX}/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=t1fx\nstatus=구현 중\n' > "${FX}/rd-workflow-workspace/.lifecycle/task-state"
  ct_before="$(sig "${FX}/CURRENT_TASK.md")"; ts_before="$(sig "${FX}/rd-workflow-workspace/.lifecycle/task-state")"
  run_wrapper t1 t1m "$FX" RD_FR_WALL_MINUTES=0.03
  check "wrapper 가 멈추지 않고 반환 (소요 ${RUN_ELAPSED}초, 워치독 ${WATCHDOG}초, 수집 1회 ${COLLECT_MS}ms${PRECISE_NOTE})" "$RUN_HUNG"
  check "exit 20" "$([[ $RUN_RC == 20 ]]; echo $?)"
  check "outcome 첫 줄 blocked:time-cap" "$([[ "$(outcome_first)" == "blocked:time-cap" ]]; echo $?)"
  check "별도 그룹 손자까지 회수 (생존 0)" "$([[ "$(alive_sleeps)" == 0 ]]; echo $?)"
  check "진단 줄: 경과" "$(grep -q '^경과 ' "${TMP}/run-outcome"; echo $?)"
  check "진단 줄: 작업 상태가 fixture 작업을 가리킴" "$(grep -q '^작업 상태: t1fx 구현 중 .*/t1repo$' "${TMP}/run-outcome"; echo $?)"
  check "CURRENT_TASK.md 불변(해시·mtime)" "$([[ "$ct_before" == "$(sig "${FX}/CURRENT_TASK.md")" ]]; echo $?)"
  check "task-state 불변(해시·mtime)" "$([[ "$ts_before" == "$(sig "${FX}/rd-workflow-workspace/.lifecycle/task-state")" ]]; echo $?)"
fi

# ── T1b TERM 처리기가 낳은 고아(재부모화) 회수
echo "[T1b 재부모화 고아]"
if need_proc T1b; then
  run_wrapper t1b t1bm "$TMP" RD_FR_WALL_MINUTES=0.03
  check "wrapper 가 멈추지 않고 반환" "$RUN_HUNG"
  t1b_alive="$(alive_sleeps)"
  check "고아 자식까지 회수 (생존 0)" "$([[ "$t1b_alive" == 0 ]]; echo $?)"
  if [[ "$t1b_alive" != 0 ]]; then alive_sleeps_detail | sed 's/^/    생존: /' >&2; fi
  check "outcome 첫 줄 blocked:time-cap" "$([[ "$(outcome_first)" == "blocked:time-cap" ]]; echo $?)"
fi

# ── T1c 부모가 먼저 끝난 별도 그룹 후손 회수 (TERM 처리기가 sleep 을 낳고 곧바로 종료 — 재부모화된 후손은 부모 관계로 잡히지 않는다)
echo "[T1c 부모가 먼저 끝난 별도 그룹 후손]"
if need_proc T1c; then
  run_wrapper t1c t1cm "$TMP" RD_FR_WALL_MINUTES=0.03
  check "wrapper 가 멈추지 않고 반환" "$RUN_HUNG"
  t1c_alive="$(alive_sleeps)"
  check "부모가 먼저 끝난 별도 그룹 후손 회수 (생존 0)" "$([[ "$t1c_alive" == 0 ]]; echo $?)"
  if [[ "$t1c_alive" != 0 ]]; then alive_sleeps_detail | sed 's/^/    생존: /' >&2; fi
  check "outcome 첫 줄 blocked:time-cap" "$([[ "$(outcome_first)" == "blocked:time-cap" ]]; echo $?)"
fi

# ── T1d python3 를 실행할 수 없으면 종전 방식(set -m)으로 돌고, 세션 추적 불가를 outcome 에 알린다
mkdir -p "${TMP}/nopy"
printf '#!/bin/sh\nexit 127\n' > "${TMP}/nopy/python3"; chmod +x "${TMP}/nopy/python3"
run_wrapper t1 t1dm "$TMP" RD_FR_WALL_MINUTES=0.03 PATH="${TMP}/nopy:${TMP}/bin:$PATH"
echo "[T1d python3 실행 불가 대체 경로]"
check "python3 실행 불가: outcome 에 세션 추적 불가(python3 실행 실패 rc=127) 줄" "$(grep -q '^세션 추적 불가(python3 실행 실패 rc=127)' "${TMP}/run-outcome"; echo $?)"
check "python3 실행 불가: wrapper 가 멈추지 않고 반환" "$RUN_HUNG"

# ── T1e 세션 조회 권한 오류는 회수 성공이 아니다 (macOS 의 python3 getsid 경로 전용)
echo "[T1e 세션 조회 권한 오류]"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "  SKIP: T1e — Linux 는 ps sid 경로라 getsid 주입이 발동하지 않음"
elif need_proc T1e; then
  REAL_PY="$(command -v python3)"
  mkdir -p "${TMP}/eperm"
  # 기동 검사·setsid 기동 호출은 진짜 python3 로 넘기고, getsid 조회 호출에서만 대역이 기록한 후손 pid 하나를 EPERM 으로 답한다.
  cat > "${TMP}/eperm/python3" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *getsid* ]]; then
  prelude="import os, errno
_orig = os.getsid
def _gs(pid):
    try:
        tgt = int(open('${TMP}/stub-pid').read().split()[0])
    except Exception:
        tgt = None
    if pid == tgt:
        open('${TMP}/eperm-mark', 'a').write('x\\n')
        raise OSError(errno.EPERM, 'injected')
    return _orig(pid)
os.getsid = _gs"
  exec "$REAL_PY" -c "\$prelude"\$'\n'"\$2"
fi
exec "$REAL_PY" "\$@"
SHIM
  chmod +x "${TMP}/eperm/python3"; rm -f "${TMP}/eperm-mark"
  run_wrapper t1c t1em "$TMP" RD_FR_WALL_MINUTES=0.03 PATH="${TMP}/eperm:${TMP}/bin:$PATH"
  check "세션 조회 권한 오류: 주입이 실제로 발동함" "$([[ -s "${TMP}/eperm-mark" ]]; echo $?)"
  check "세션 조회 권한 오류: outcome 첫 줄이 blocked:time-cap 아님" "$([[ "$(outcome_first)" == "blocked:time-cap-unreaped" ]]; echo $?)"
  check "세션 조회 권한 오류: 진단 줄에 세션 조회 실패" "$(grep -q '세션 조회 실패' "${TMP}/run-outcome"; echo $?)"
  # 주입으로 일부러 남긴 후손은 대역이 기록한 pid 로만 회수한다.
  if [[ -s "${TMP}/stub-pid" ]]; then kill -KILL "$(cat "${TMP}/stub-pid")" 2>/dev/null; fi
fi

# ── T2 completed 유지
echo "[T2 completed 유지]"
if need_proc T2; then
  run_wrapper t2 t2m "$TMP" RD_FR_WALL_MINUTES=0.03
  check "exit 0" "$([[ $RUN_RC == 0 ]]; echo $?)"
  check "outcome 첫 줄 completed" "$([[ "$(outcome_first)" == completed ]]; echo $?)"
  check "outcome 파일 불변(기록 직후와 해시·mtime 동일)" "$([[ "$(cat "${TMP}/stub-sig")" == "$(sig "${TMP}/run-outcome")" ]]; echo $?)"
  check "stderr 에 완료 후 상한 도달" "$(grep -q '완료 후 상한 도달' "${TMP}/run-stderr"; echo $?)"
  check "잔여 프로세스 회수 (생존 0)" "$([[ "$(alive_sleeps)" == 0 ]]; echo $?)"
fi

# ── T2b 상한 이후(유예 중)에 늦게 기록된 completed 는 완료로 인정하지 않는다
echo "[T2b 늦은 completed]"
if need_proc T2b; then
  run_wrapper t2b t2bm "$TMP" RD_FR_WALL_MINUTES=0.03
  check "exit 20" "$([[ $RUN_RC == 20 ]]; echo $?)"
  check "outcome 첫 줄 blocked:time-cap" "$([[ "$(outcome_first)" == "blocked:time-cap" ]]; echo $?)"
  check "stderr 에 완료 후 상한 도달 문구 없음" "$(! grep -q '완료 후 상한 도달' "${TMP}/run-stderr"; echo $?)"
fi

# ── T3 설정 해석
echo "[T3 설정]"
run_wrapper quick t3a "$TMP" RD_FR_WALL_MINUTES=abc
check "비숫자 상한: exit 0" "$([[ $RUN_RC == 0 ]]; echo $?)"
check "비숫자 상한: 경고와 기본값 대체 줄" "$(grep -q "기본값(잘못된 값 'abc'" "${TMP}/run-stderr"; echo $?)"
run_wrapper quick t3b "$TMP" RD_FR_WALL_GRACE_SECONDS=99999
check "범위 밖 유예: exit 0" "$([[ $RUN_RC == 0 ]]; echo $?)"
check "범위 밖 유예: 경고 후 30 대체" "$(grep -q '유예.*30' "${TMP}/run-stderr"; echo $?)"
rm -f "${TMP}/stub-done"
run_wrapper slow3 t3c "$TMP" RD_FR_WALL_MINUTES=0
echo "[T3b 상한 0]"
check "exit 0" "$([[ $RUN_RC == 0 ]]; echo $?)"
check "상한 없음 줄" "$(grep -q '상한 없음' "${TMP}/run-stderr"; echo $?)"
check "스텁이 끝까지 실행됨" "$([[ -f "${TMP}/stub-done" ]]; echo $?)"

# ── 함수 단위 (wrapper 에서 정의를 뽑아 직접 호출) — load_fn 정의는 위쪽(run_wrapper 앞)에 있다
echo "[D1 결정]"
if load_fn decide_timecap_outcome; then
  check "미회수 있음 → time-cap-unreaped" "$([[ "$(decide_timecap_outcome 2 blocked:x)" == time-cap-unreaped ]]; echo $?)"
  check "미회수 없음 + completed → completed" "$([[ "$(decide_timecap_outcome 0 completed)" == completed ]]; echo $?)"
  check "미회수 없음 + publish-ready → completed" "$([[ "$(decide_timecap_outcome 0 publish-ready)" == completed ]]; echo $?)"
  check "미회수 없음 + 그 외 → time-cap" "$([[ "$(decide_timecap_outcome 0 '')" == time-cap ]]; echo $?)"
  check "미회수 있음 + completed → time-cap-unreaped" "$([[ "$(decide_timecap_outcome 1 completed)" == time-cap-unreaped ]]; echo $?)"
fi

echo "[D4 후손 수집 — 고정 ps 목록]"
if load_fn collect_targets; then
  # 기록으로 추적 중인 고아(200)가 새 자식(300)을 낳은 상태. child(100)는 이미 없다.
  ps_all() {
    printf '%s\n' \
      '200 S 1 Thu Oct 29 12:00:00 2026 orphan' \
      '300 S 200 Thu Oct 29 12:00:01 2026 new-child' \
      '400 S 1 Thu Oct 29 12:00:02 2026 unrelated'
  }
  printf '200\tThu Oct 29 12:00:00 2026\n' > "${TMP}/d4-seen"; : > "${TMP}/d4-tok"
  got="$(collect_targets 100 "${TMP}/d4-tok" "${TMP}/d4-seen" | tr '\n' ' ')"
  check "기록된 고아와 그 새 자식을 모두 수집" "$([[ "$got" == "200 300 " ]]; echo $?)"
  printf '200\tThu Oct 29 11:00:00 2026\n' > "${TMP}/d4-seen2"
  got="$(collect_targets 100 "${TMP}/d4-tok" "${TMP}/d4-seen2" | tr '\n' ' ')"
  check "시작 시각이 다르면(pid 재사용) 수집하지 않음" "$([[ -z "${got// /}" ]]; echo $?)"
fi

echo "[D5 프로세스 조회 실패 ≠ 회수 성공]"
if load_fn collect_targets && load_fn reap_timecap; then
  ps_all() { return 1; }
  : > "${TMP}/d5-tok"; : > "${TMP}/d5-seen"; : > "${TMP}/d5-ufile"
  collect_targets 999999 "${TMP}/d5-tok" "${TMP}/d5-seen" >/dev/null; crc=$?
  check "목록을 못 얻으면 collect_targets 가 rc 2" "$([[ $crc == 2 ]]; echo $?)"
  reap_timecap 999999 "${TMP}/d5-tok" 1 "${TMP}/d5-ufile" "${TMP}/d5-seen"
  check "조회 실패는 미회수 목록에 기록됨" "$(grep -q '프로세스 목록 조회 실패' "${TMP}/d5-ufile"; echo $?)"
  ps_all() { printf '%s\n' '1 S 0 Thu Oct 29 12:00:00 2026 launchd'; }
  : > "${TMP}/d5-ufile"; rm -f "${TMP}/d5-seen.fail"
  reap_timecap 999999 "${TMP}/d5-tok" 1 "${TMP}/d5-ufile" "${TMP}/d5-seen"
  check "조회가 성공하고 대상이 없으면 미회수 목록이 빔" "$([[ ! -s "${TMP}/d5-ufile" ]]; echo $?)"
fi

echo "[D6 유예 값 정규화]"
if load_fn resolve_grace && load_fn resolve_wall_cap; then
  RD_FR_WALL_MINUTES=1 RD_FR_WALL_GRACE_SECONDS=08 resolve_wall_cap 2>/dev/null
  check "08 → 8 (8진수 오류 없음)" "$([[ "$GRACE" == 8 ]] && (( 0 < GRACE )) 2>/dev/null; echo $?)"
  RD_FR_WALL_MINUTES=1 RD_FR_WALL_GRACE_SECONDS=010 resolve_wall_cap 2>/dev/null
  check "010 → 10" "$([[ "$GRACE" == 10 ]]; echo $?)"
fi

echo "[D2 세션 탐색]"
if load_fn list_open_review_sessions; then
  d2="${TMP}/d2"
  for pair in "a:awaiting-author" "b:awaiting-reviewer" "c:awaiting-user" "d:closed"; do
    dd="${d2}/rd-workflow-workspace/handoffs/review_pipeline/${pair%%:*}"; mkdir -p "$dd"
    printf '## Status\n%s\n' "${pair##*:}" > "${dd}/SESSION.md"
  done
  before="$(for f in "${d2}"/rd-workflow-workspace/handoffs/review_pipeline/*/SESSION.md; do sig "$f"; done)"
  sleep 1
  got="$(list_open_review_sessions "$d2")"
  after="$(for f in "${d2}"/rd-workflow-workspace/handoffs/review_pipeline/*/SESSION.md; do sig "$f"; done)"
  check "awaiting-* 세 개만 출력" "$([[ "$(echo "$got" | grep -c .)" == 3 && "$got" != *"/d" ]]; echo $?)"
  check "fixture 불변(해시·mtime)" "$([[ "$before" == "$after" ]]; echo $?)"
fi

echo "[D2b 진단 줄 (diag_lines)]"
if load_fn diag_lines && load_fn list_open_review_sessions; then
  fx="${TMP}/fx"
  for pair in "open1:awaiting-reviewer" "done1:closed"; do
    d="${fx}/rd-workflow-workspace/handoffs/review_pipeline/${pair%%:*}"; mkdir -p "$d"
    printf '# Review Session\n\n## Status\n%s\n' "${pair##*:}" > "${d}/SESSION.md"
  done
  got="$(cd "$fx" && diag_lines)"
  check "열린 세션 경로가 진단 줄로 나옴" "$(grep -q '^열린 리뷰 세션: .*/open1$' <<<"$got"; echo $?)"
  check "closed 세션은 나오지 않음" "$(! grep -q 'done1' <<<"$got"; echo $?)"
  check "git 밖에서는 작업 상태 판정 실패 표시" "$(grep -q '^작업 상태: 판정 실패$' <<<"$got"; echo $?)"
fi

echo "[D3 outcome 기록]"
if load_fn write_timecap_outcome; then
  diag_lines() { echo "작업 상태: fixture"; }
  OUTCOME_FILE="${TMP}/d3-outcome"
  printf '123 sleep 600\n' > "${TMP}/unreaped"; : > "${TMP}/unreaped-empty"
  write_timecap_outcome time-cap-unreaped 240.0 240 환경변수 "${TMP}/unreaped" 1
  check "첫 줄 blocked:time-cap-unreaped" "$([[ "$(head -n1 "$OUTCOME_FILE")" == blocked:time-cap-unreaped ]]; echo $?)"
  check "잔여 프로세스 줄" "$(grep -q '^잔여 프로세스: 123 sleep 600$' "$OUTCOME_FILE"; echo $?)"
  check "completed 기록 사실 줄" "$(grep -q '^작업은 completed 로 기록됨$' "$OUTCOME_FILE"; echo $?)"
  write_timecap_outcome time-cap 240.0 240 환경변수 "${TMP}/unreaped-empty" 0
  check "일반 time-cap 첫 줄" "$([[ "$(head -n1 "$OUTCOME_FILE")" == blocked:time-cap ]]; echo $?)"
  check "일반 time-cap 에 잔여 프로세스 줄 없음" "$(! grep -q '^잔여 프로세스' "$OUTCOME_FILE"; echo $?)"
  check "일반 time-cap 에 completed 줄 없음" "$(! grep -q 'completed 로 기록됨' "$OUTCOME_FILE"; echo $?)"
  check "일반 time-cap 에 경과·작업 상태 줄" "$(grep -q '^경과 ' "$OUTCOME_FILE" && grep -q '^작업 상태: fixture' "$OUTCOME_FILE"; echo $?)"
fi

if [[ $FAIL == 0 ]]; then echo "test_autopilot_headless_timecap: PASS"; exit 0
else echo "test_autopilot_headless_timecap: FAIL" >&2; exit 1; fi
