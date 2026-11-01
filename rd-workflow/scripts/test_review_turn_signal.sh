#!/usr/bin/env bash
# test_review_turn_signal.sh — run_review_turn.sh 의 중단 신호 전달과 유한 정리 검증
# (change spec codex-adapter-turn-loss-and-reap §2.2·§2.3 / §3: T1 T1n T2 T5a T5b T5c T3 T4 T6)
# 출력: `PASS <단언 이름>` / `FAIL <단언 이름>`. 어떤 단언이 실패해도 끝까지 실행하고, FAIL 이 있으면 exit 1.
# 부모는 `bash -c 'set -m; ... &'` 런처로 띄운다 — 비대화형 셸의 `cmd &` 는 SIGINT 를 무시 상태로 상속한다.
set +e
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="${script_dir}/run_review_turn.sh"

FAIL=0
ck() { # $1=이름 $2=상태(0=통과) $3=실패 시 상세
  if [ "$2" -eq 0 ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s %s\n' "$1" "${3:-}"; FAIL=1; fi
}

TMP="$(mktemp -d)" || { echo "test_review_turn_signal.sh: 임시 디렉터리 생성 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_review_turn_signal.sh: 임시 디렉터리 경로 검증 실패" >&2; exit 1; }

# 남은 프로세스 정리: PID 파일에 기록된 프로세스만 (이름 매칭 금지)
cleanup() {
  local f p
  for f in $(find "$TMP" -name '*.pid' 2>/dev/null); do
    p="$(cat "$f" 2>/dev/null)"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    { kill -KILL "$p"; wait "$p"; } 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap 'cleanup 2>/dev/null' EXIT

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time' 2>/dev/null || date +%s; }
fcmp() { awk -v a="$1" -v b="$3" "BEGIN{exit !(a $2 b)}"; } # fcmp 값 연산자 값
alive() { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }
pidof_file() { cat "$1" 2>/dev/null; }
wait_file() { # $1=파일 $2=최대 초 — 나타나면 0
  local n=0 max=$(( $2 * 20 ))
  while [ ! -e "$1" ]; do
    [ "$n" -ge "$max" ] && return 1
    sleep 0.05; n=$(( n + 1 ))
  done
  return 0
}
wait_dead() { # $1=pid $2=최대 초 — 죽으면 0
  local n=0 max=$(( $2 * 20 ))
  while alive "$1"; do
    [ "$n" -ge "$max" ] && return 1
    sleep 0.05; n=$(( n + 1 ))
  done
  return 0
}
count_lines() { # $1=파일 $2=고정 문자열
  grep -cF -- "$2" "$1" 2>/dev/null || true
}

mk_session() { # $1=디렉토리 (test_review_metrics.sh 의 mk_full_session 과 같은 픽스처)
  mkdir -p "$1/turns"
  cat > "$1/SESSION.md" <<'EOF'
# Review Session

## Session ID
signal-test

## Review Type
spec-plan-review

## Review Target
REQUEST.md

## Review Goal
신호 테스트

## Status
awaiting-reviewer

## Current Owner
Reviewer

## Turn Limit
20 total turns in `turns/*.md`

## Branch Context
- fr-branch: null
- worktree-path: null
- short-title: signal-test
- lifecycle-stage: request-review
- remote-mode: local-only

## Review Scope
- execution-path: other
EOF
  cat > "$1/CHECKPOINT.md" <<'EOF'
# Review Checkpoint

## Open Issues
- 없음

## Suggested Next Owner
Reviewer
EOF
  : > "$1/USER_ACTION.md"
  printf '# Turn 001 — Author\n' > "$1/turns/001_author.md"
}

# 가짜 어댑터 본문. $1=케이스 디렉터리 $2=MODE(trap|ignore) $3=TERM trap 지연 초
# trap: TERM 을 받으면 term_seen 을 만들고 지연 뒤 자식을 죽이고 143 종료.
# ignore: TERM 을 무시. 자식 PID 기록·trap 설치가 끝난 **뒤에** ready 를 만든다.
# 자식 sleep 은 무관한 bystander 와 구분하려고 고유한 길이(30417초)를 쓴다.
adapter_body() {
  local d="$1" mode="$2" delay="$3" xrc="${4:-143}"
  printf 'echo $$ > "%s/adapter.pid"\n' "$d"
  printf 'child=""\n'
  if [ "$mode" = "ignore" ]; then
    printf "trap '' TERM\n"
  else
    printf "trap 'touch \"%s/term_seen\"; sleep %s; kill \$child 2>/dev/null; exit %s' TERM\n" "$d" "$delay" "$xrc"
  fi
  printf 'sleep 30417 &\nchild=$!\necho $child > "%s/child.pid"\n' "$d"
  printf 'touch "%s/ready"\nwait\n' "$d"
}

# 실제 run_review_turn.sh 를 가짜 어댑터와 함께 `set -m` 런처로 띄운다.
# $1=케이스 이름 $2=MODE $3=지연 $4=RD_REVIEW_TERM_GRACE → 케이스 디렉터리를 전역 CASE_D 로 낸다.
start_case() {
  local name="$1" mode="$2" delay="$3" grace="$4" d bin
  d="$TMP/$name"; bin="$d/bin"
  mkdir -p "$bin"
  CASE_D="$d"
  cp "$SUBJECT" "${script_dir}/review_common.sh" "$bin/"
  { printf '#!/usr/bin/env bash\n'; adapter_body "$d" "$mode" "$delay"; } > "$bin/adapter_codex.sh"
  chmod +x "$bin/adapter_codex.sh"
  printf '{"default_priority":["codex"],"tools":{"codex":{"effort_default":"high"}},"_comment":"signal test"}' > "$bin/tools.json"
  mk_session "$d/session"
  cat > "$d/launch.sh" <<EOF
set -m
RD_REVIEW_TERM_GRACE=$grace REVIEW_TOOLS_CONFIG="$bin/tools.json" bash "$bin/run_review_turn.sh" "$d/session" >"$d/out" 2>"$d/err" &
echo \$! > "$d/parent.pid"
wait \$!
echo \$? > "$d/parent.rc"
EOF
  # 런처 자신도 `set -m` 서브셸에서 띄운다 — 비동기(`&`)로만 띄우면 런처가 SIGINT 무시 상태로 시작해
  # 그 아래 부모가 INT trap 을 설치해도 INT 가 전달되지 않는다 (실측).
  # 이 테스트 자체가 백그라운드(무시 상태 상속)에서 실행돼도 견디도록 perl 로 INT 를 기본 동작으로 되돌려 exec 한다.
  if command -v perl >/dev/null 2>&1; then
    ( set -m; perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' bash "$d/launch.sh" >/dev/null 2>&1 & )
  else
    ( set -m; bash "$d/launch.sh" >/dev/null 2>&1 & )
  fi
  wait_file "$d/ready" 10
}

start_bystander() { # $1=PID 파일
  sleep 30417 &
  echo $! > "$1"
}

echo "=== T1: HUP·INT·TERM 전달 (GRACE=4) ==="
for sig in HUP INT TERM; do
  case "$sig" in HUP) want=129;; INT) want=130;; TERM) want=143;; esac
  start_case "t1_$sig" trap 0 4
  d="$CASE_D"
  start_bystander "$d/bystander.pid"
  [ -e "$d/ready" ] || ck "t1.ready[$sig]" 1 "(어댑터 ready 없음)"
  t0="$(now)"
  kill -"$sig" "$(pidof_file "$d/parent.pid")" 2>/dev/null
  wait_file "$d/parent.rc" 10; t1="$(now)"
  elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')"
  apid="$(pidof_file "$d/adapter.pid")"; cpid="$(pidof_file "$d/child.pid")"
  wait_dead "$apid" 2; ad=$?; wait_dead "$cpid" 2; cd_=$?
  if [ "$ad" -eq 0 ] && [ "$cd_" -eq 0 ]; then ck "t1.dead[$sig]" 0; else ck "t1.dead[$sig]" 1 "(어댑터 dead=$ad 자식 dead=$cd_)"; fi
  rc="$(pidof_file "$d/parent.rc")"
  if [ "$rc" = "$want" ]; then ck "t1.rc[$sig]" 0; else ck "t1.rc[$sig]" 1 "(기대=$want 실제=${rc:-없음})"; fi
  if alive "$(pidof_file "$d/bystander.pid")"; then ck "t1.bystander[$sig]" 0; else ck "t1.bystander[$sig]" 1; fi
  if fcmp "$elapsed" '<' 3; then ck "t1.fast[$sig]" 0; else ck "t1.fast[$sig]" 1 "(경과 ${elapsed}s)"; fi
  if grep -qF "중단 신호 $sig 수신" "$d/err" 2>/dev/null; then ck "t1.name[$sig]" 0; else ck "t1.name[$sig]" 1; fi
  if grep -qF "정상 종료" "$d/err" 2>/dev/null; then ck "t1.result[$sig]" 0; else ck "t1.result[$sig]" 1; fi
done

echo "=== T1n: TERM trap 이 2초 지연돼도 알림은 정리 시작 전에 나옴 ==="
start_case t1n trap 2 15
d="$CASE_D"
kill -TERM "$(pidof_file "$d/parent.pid")" 2>/dev/null
wait_file "$d/term_seen" 5
if [ ! -e "$d/parent.rc" ] && grep -qF "어댑터 정리 중" "$d/err" 2>/dev/null; then
  ck "t1n.notice_early" 0
else
  ck "t1n.notice_early" 1 "(term_seen 시점에 알림 없음 또는 부모 이미 종료)"
fi
wait_file "$d/parent.rc" 10

echo "=== T2: TERM 무시 어댑터 (GRACE=2) ==="
start_case t2 ignore 0 2
d="$CASE_D"
t0="$(now)"
kill -TERM "$(pidof_file "$d/parent.pid")" 2>/dev/null
wait_file "$d/parent.rc" 10; t1="$(now)"
elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')"
apid="$(pidof_file "$d/adapter.pid")"
if wait_dead "$apid" 2; then ck "t2.killed" 0; else ck "t2.killed" 1 "(어댑터 생존)"; fi
if fcmp "$elapsed" '>=' 2; then ck "t2.lower" 0; else ck "t2.lower" 1 "(경과 ${elapsed}s)"; fi
if fcmp "$elapsed" '<=' 5; then ck "t2.upper" 0; else ck "t2.upper" 1 "(경과 ${elapsed}s)"; fi
rc="$(pidof_file "$d/parent.rc")"
if [ -n "$rc" ] && [ "$rc" != 0 ]; then ck "t2.rc" 0; else ck "t2.rc" 1 "(rc=${rc:-없음})"; fi
if grep -qF "잔존 프로세스 경고" "$d/err" 2>/dev/null; then ck "t2.warn" 0; else ck "t2.warn" 1; fi
# 143 은 어댑터가 cleanup 을 보장하는 신호다 — grace 초과여도 「보장하지 못하는 신호」 라고 말하면 자기모순이다.
if [ "$rc" = 143 ] && ! grep -qF "cleanup 을 보장하지 못하는 신호" "$d/err" 2>/dev/null \
   && grep -qF "대기 상한 안에 끝나지 않아" "$d/err" 2>/dev/null; then ck "t2.no_contradiction" 0; else ck "t2.no_contradiction" 1 "(rc=${rc:-없음})"; fi
# 잔존 위험은 실제이므로 재실행 금지 안내는 유지한다.
if grep -qF "확인하기 전에 재실행하지 마십시오" "$d/err" 2>/dev/null; then ck "t2.no_rerun" 0; else ck "t2.no_rerun" 1; fi

echo "=== T2n: SIGINT 무시로 시작한 부모는 한계를 한 번 알린다 ==="
d="$TMP/t2n"; mkdir -p "$d/bin"
cp "$SUBJECT" "${script_dir}/review_common.sh" "$d/bin/"
{ printf '#!/usr/bin/env bash\nexit 0\n'; } > "$d/bin/adapter_codex.sh"; chmod +x "$d/bin/adapter_codex.sh"
printf '{"default_priority":["codex"],"tools":{"codex":{"effort_default":"high"}}}' > "$d/bin/tools.json"
mk_session "$d/session"
( trap '' INT; REVIEW_TOOLS_CONFIG="$d/bin/tools.json" bash "$d/bin/run_review_turn.sh" "$d/session" >"$d/out" 2>"$d/err" )
n="$(count_lines "$d/err" "SIGINT 가 무시된 채 시작되었습니다")"
if [ "$n" = 1 ]; then ck "t2n.notice_once" 0; else ck "t2n.notice_once" 1 "(안내 ${n}회)"; fi

# T5 계열: 함수를 실제 호출 순서대로 부르고 신호만 틈에 주입한다. 드라이버는 별도 bash 프로세스다.
mk_adapter_file() { # $1=디렉터리 $2=TERM trap 지연 초 $3=TERM trap 종료 코드(기본 143)
  { printf '#!/usr/bin/env bash\n'; adapter_body "$1" trap "$2" "${3:-143}"; } > "$1/adapter.sh"
}

run_driver() { # $1=디렉터리 — 드라이버를 띄우고 driver.pid 가 생길 때까지 기다린다
  bash "$1/driver.sh" >/dev/null 2>"$1/err" &
  wait_file "$1/driver.pid" 5
}

echo "=== T2o: 선행 0 grace (08·010) 는 10진수로 해석된다 ==="
(
  source "$SUBJECT" 2>/dev/null
  set +e
  RD_REVIEW_TERM_GRACE=08
  bash -c 'trap "exit 143" TERM; while :; do sleep 0.2; done' &
  rr_pid=$!
  sleep 0.5
  rr_terminate_adapter 2>"$TMP/o.err" >/dev/null
  echo "$?" > "$TMP/o.rc"
  if kill -0 "$rr_pid" 2>/dev/null; then echo alive > "$TMP/o.alive"; kill -9 "$rr_pid" 2>/dev/null; else echo dead > "$TMP/o.alive"; fi
  RD_REVIEW_TERM_GRACE=010; rr_term_grace > "$TMP/o.g010"
)
if [ "$(cat "$TMP/o.alive" 2>/dev/null)" = dead ] && [ "$(cat "$TMP/o.rc" 2>/dev/null)" = 0 ] && ! grep -q 'value too great' "$TMP/o.err"; then ck "t2.grace08" 0; else ck "t2.grace08" 1 "(alive=$(cat "$TMP/o.alive" 2>/dev/null) rc=$(cat "$TMP/o.rc" 2>/dev/null))"; fi
if [ "$(cat "$TMP/o.g010" 2>/dev/null)" = 10 ]; then ck "t2.grace010" 0; else ck "t2.grace010" 1 "(got=$(cat "$TMP/o.g010" 2>/dev/null))"; fi

echo "=== T5a: 구간 A — spawn 전 신호 ==="
d="$TMP/t5a"; mkdir -p "$d"; mk_adapter_file "$d" 0
cat > "$d/driver.sh" <<EOF
set +e
source "$SUBJECT" 2>/dev/null
set +e
echo \$\$ > "$d/driver.pid"
# spawn 이 불리면 기록한다 (어댑터가 뜨자마자 죽어 adapter.pid 를 못 남기는 경합과 무관하게 판정)
rr_spawn() {
  touch "$d/spawn_called"
  "\$@" &
  rr_spawned=\$!
}
rr_init
rr_on_signal TERM 143
rr_spawn_and_wait bash "$d/adapter.sh"
echo \$? > "$d/rc"
trap -p TERM > "$d/trap_after"
touch "$d/done"
EOF
run_driver "$d"; wait_file "$d/done" 10
if [ ! -e "$d/spawn_called" ] && [ ! -e "$d/adapter.pid" ]; then ck "t5a.notspawned" 0; else ck "t5a.notspawned" 1 "(어댑터가 기동됨)"; fi
rc="$(pidof_file "$d/rc")"
if [ "$rc" = 143 ]; then ck "t5a.rc" 0; else ck "t5a.rc" 1 "(rc=${rc:-없음})"; fi
if [ -e "$d/trap_after" ] && [ ! -s "$d/trap_after" ]; then ck "t5a.restored" 0; else ck "t5a.restored" 1 "(trap -p TERM='$(cat "$d/trap_after" 2>/dev/null)')"; fi

echo "=== T5b: 구간 B — rr_spawn 과 rr_adopt 사이 신호 ==="
d="$TMP/t5b"; mkdir -p "$d"; mk_adapter_file "$d" 2
cat > "$d/driver.sh" <<EOF
set +e
source "$SUBJECT" 2>/dev/null
set +e
echo \$\$ > "$d/driver.pid"
rr_init
rr_spawn bash "$d/adapter.sh"
while [ ! -f "$d/ready" ]; do sleep 0.05; done
rr_on_signal TERM 143
rr_adopt
wait "\$rr_pid" 2>/dev/null
rc="\$rr_sig_rc"
rr_finish
echo "\$rc" > "$d/rc"
touch "$d/done"
EOF
run_driver "$d"
if wait_file "$d/term_seen" 10; then
  sleep 0.3
  # 정리 도중(어댑터 TERM trap 이 2초 지연) 알림이 이미 있어야 한다
  if [ ! -e "$d/done" ] && grep -qF "어댑터 정리 중" "$d/err" 2>/dev/null; then ck "t5b.notice" 0; else ck "t5b.notice" 1 "(정리 도중 알림 없음)"; fi
  # 정리 도중 두 번째 TERM: 잠겨 있어야 한다. (정리가 시작되지 않았으면 보내지 않는다 — 구제가 되어 유실을 가린다)
  kill -TERM "$(pidof_file "$d/driver.pid")" 2>/dev/null
else
  ck "t5b.notice" 1 "(정리가 시작되지 않음: 어댑터가 TERM 을 받지 못함)"
fi
wait_file "$d/done" 10
apid="$(pidof_file "$d/adapter.pid")"; cpid="$(pidof_file "$d/child.pid")"
wait_dead "$apid" 2; ad=$?; wait_dead "$cpid" 2; cd_=$?
if [ "$ad" -eq 0 ] && [ "$cd_" -eq 0 ]; then ck "t5b.dead" 0; else ck "t5b.dead" 1 "(어댑터 dead=$ad 자식 dead=$cd_)"; fi
rc="$(pidof_file "$d/rc")"
if [ "$rc" = 143 ]; then ck "t5b.rc" 0; else ck "t5b.rc" 1 "(rc=${rc:-없음})"; fi
n_notice="$(count_lines "$d/err" "어댑터 정리 중")"; n_result="$(count_lines "$d/err" "어댑터 정리 결과")"
if [ "$n_notice" = 1 ] && [ "$n_result" = 1 ] && [ "$rc" = 143 ]; then ck "t5b.locked" 0; else ck "t5b.locked" 1 "(알림=$n_notice 결과=$n_result rc=${rc:-없음})"; fi

echo "=== T5c: PID 대입 직후 경계 — 정리·알림 중복 없음 ==="
d="$TMP/t5c"; mkdir -p "$d"; mk_adapter_file "$d" 1
cat > "$d/driver.sh" <<EOF
set +e
source "$SUBJECT" 2>/dev/null
set +e
echo \$\$ > "$d/driver.pid"
rr_init
rr_spawn bash "$d/adapter.sh"
while [ ! -f "$d/ready" ]; do sleep 0.05; done
rr_set_pid
rr_on_signal TERM 143
rr_check_pending
wait "\$rr_pid" 2>/dev/null
rc="\$rr_sig_rc"
rr_finish
echo "\$rc" > "$d/rc"
touch "$d/done"
EOF
run_driver "$d"; wait_file "$d/done" 10
n_notice="$(count_lines "$d/err" "어댑터 정리 중")"; n_result="$(count_lines "$d/err" "어댑터 정리 결과")"
if [ "$n_notice" = 1 ] && [ "$n_result" = 1 ]; then ck "t5c.once" 0; else ck "t5c.once" 1 "(알림=$n_notice 결과=$n_result)"; fi
rc="$(pidof_file "$d/rc")"
if [ "$rc" = 143 ]; then ck "t5c.rc" 0; else ck "t5c.rc" 1 "(rc=${rc:-없음})"; fi

echo "=== T5d: 구간 B 신호 뒤 어댑터가 코드 7 로 끝나도 rr_spawn_and_wait 는 143 을 반환 (덮어쓰기) ==="
d="$TMP/t5d"; mkdir -p "$d"; mk_adapter_file "$d" 0 7
cat > "$d/driver.sh" <<EOF
set +e
source "$SUBJECT" 2>/dev/null
set +e
echo \$\$ > "$d/driver.pid"
# 구간 B 재현: spawn 직후(rr_pid 대입 전)에 신호가 기록되도록 rr_spawn 을 감싼다
rr_spawn() {
  "\$@" &
  rr_spawned=\$!
  while [ ! -f "$d/ready" ]; do sleep 0.05; done
  rr_on_signal TERM 143
}
rr_init
rr_spawn_and_wait bash "$d/adapter.sh"
echo \$? > "$d/rc"
touch "$d/done"
EOF
run_driver "$d"; wait_file "$d/done" 10
rc="$(pidof_file "$d/rc")"
if [ "$rc" = 143 ]; then ck "t5d.rc" 0; else ck "t5d.rc" 1 "(rc=${rc:-없음})"; fi

# T3·T4·T6: 중단된 턴의 보존 안내 (§2.3). 신호가 필요 없으므로 어댑터가 exit 1 로 끝나는 일반 실패 경로를 쓴다.
# $1=케이스 이름 $2=어댑터가 실행할 셸 조각 → 전역 CASE_D 에 케이스 디렉터리.
run_fail_case() {
  local name="$1" body="$2" d bin
  d="$TMP/$name"; bin="$d/bin"
  mkdir -p "$bin"
  CASE_D="$d"
  cp "$SUBJECT" "${script_dir}/review_common.sh" "$bin/"
  { printf '#!/usr/bin/env bash\n'; printf 'sd="%s/session"\n' "$d"; printf '%s\n' "$body"; printf 'exit 1\n'; } > "$bin/adapter_codex.sh"
  chmod +x "$bin/adapter_codex.sh"
  printf '{"default_priority":["codex"],"tools":{"codex":{"effort_default":"high"}},"_comment":"signal test"}' > "$bin/tools.json"
  mk_session "$d/session"
  REVIEW_TOOLS_CONFIG="$bin/tools.json" bash "$bin/run_review_turn.sh" "$d/session" >"$d/out" 2>"$d/err"
  echo $? > "$d/rc"
}
turn_sum() { cksum < "$1" 2>/dev/null; }
WRITE_TURN='printf "# Turn 002 — Reviewer\n\n부분 기록" > "$sd/turns/002_reviewer.md"'

echo "=== T3: turn 파일만 쓰고 실패 — 보존 안내, CHECKPOINT 같음 ==="
run_fail_case t3 "$WRITE_TURN"
d="$CASE_D"; turn="$d/session/turns/002_reviewer.md"
expect_sum="$(printf '# Turn 002 — Reviewer\n\n부분 기록' | cksum)"
if grep -qF "보존된 턴 파일: " "$d/err" && grep -F "보존된 턴 파일: " "$d/err" | grep -qF "turns/002_reviewer.md"; then ck "t3.path" 0; else ck "t3.path" 1 "(보존 경로 줄 없음)"; fi
if grep -qF "CHECKPOINT.md 내용이 어댑터 실행 전과 같음" "$d/err"; then ck "t3.same" 0; else ck "t3.same" 1; fi
if [ -f "$turn" ] && [ "$(turn_sum "$turn")" = "$expect_sum" ]; then ck "t3.turnsum" 0; else ck "t3.turnsum" 1 "(turn cksum 불일치)"; fi

echo "=== T4: turn + CHECKPOINT 를 쓰고 실패 — CHECKPOINT 다름 ==="
run_fail_case t4 "$WRITE_TURN
printf x >> \"\$sd/CHECKPOINT.md\""
d="$CASE_D"; turn="$d/session/turns/002_reviewer.md"
if grep -qF "CHECKPOINT.md 내용이 어댑터 실행 전과 다름" "$d/err"; then ck "t4.diff" 0; else ck "t4.diff" 1; fi
if [ -f "$turn" ] && [ "$(turn_sum "$turn")" = "$expect_sum" ]; then ck "t4.turnsum" 0; else ck "t4.turnsum" 1 "(turn cksum 불일치)"; fi

echo "=== T6: CHECKPOINT.md 부재 (하네스는 시작 시 CHECKPOINT.md 를 요구하므로 어댑터가 지운다) ==="
run_fail_case t6 "$WRITE_TURN
rm -f \"\$sd/CHECKPOINT.md\"" 
d="$CASE_D"
if grep -qF "CHECKPOINT.md 내용이 어댑터 실행 전과 없음(파일 없음)" "$d/err"; then ck "t6.absent" 0; else ck "t6.absent" 1; fi

echo "=== T3 경로 보강: 어댑터가 124(대기 초과)·143(신호 종료)으로 끝나는 경로에서도 보존 안내가 나온다 ==="
for code in 124 143; do
  run_fail_case "t3x$code" "$WRITE_TURN
exit $code"
  d="$CASE_D"
  if grep -F "보존된 턴 파일: " "$d/err" | grep -qF "turns/002_reviewer.md"; then ck "t3.path.exit$code" 0; else ck "t3.path.exit$code" 1 "(보존 경로 줄 없음)"; fi
done

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAIL"; fi
exit "$FAIL"
