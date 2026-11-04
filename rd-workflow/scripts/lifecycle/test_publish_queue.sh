#!/usr/bin/env bash
# test_publish_queue.sh — publish_queue.sh 의 큐 저장소·락·설정·조회·취소·request·next·approve 시험.
# 임시 저장소(+로컬 bare 원격)에서만 돈다. 뒤 task 가 run/wait/watch 사례를 이어 붙인다.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
PASS=0; FAIL=0
# 사례는 서브셸에서 병렬로 돌 수 있어, 집계는 파일에 한 줄씩 덧붙여 센다.
fail() { printf 'F\n' >>"$TMP/cnt"; printf '  FAIL: %s\n' "$1" >&2; }
pass() { printf 'P\n' >>"$TMP/cnt"; printf '  PASS: %s\n' "$1"; }

TMP="$(mktemp -d)" || { echo "test_publish_queue.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_publish_queue.sh: 임시 디렉터리 검증 실패" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
: >"$TMP/cnt"
PQ="$SCRIPT_DIR/publish_queue.sh"
T0=$SECONDS

# mk_repo <name>: bare 원격 + 클론(기본 브랜치 master). 클론 경로를 stdout 으로 낸다.
mk_repo() {
  local name="$1" bare="$TMP/$1.git" wc="$TMP/$1"
  git init -q --bare -b master "$bare"
  git clone -q "$bare" "$wc" 2>/dev/null
  git -C "$wc" checkout -q -b master 2>/dev/null || true
  git -C "$wc" config user.name rd-test
  git -C "$wc" config user.email rd-test@example.invalid
  mkdir -p "$wc/rd-workflow/config" "$wc/rd-workflow-workspace/.lifecycle"
  printf 'x\n' >"$wc/README"
  git -C "$wc" add -A && git -C "$wc" commit -q -m init
  git -C "$wc" push -q origin master 2>/dev/null
  printf '%s\n' "$wc"
}

# 저장소 안에서 큐 명령 실행: pq <repo> <args...> — stdout+stderr 를 $OUT, rc 를 $RC 에 담는다.
OUT=""; RC=0
pq() {
  local repo="$1"; shift
  OUT="$(cd "$repo" && project_root="$repo" bash "$PQ" "$@" 2>&1)"; RC=$?
}
# 함수 직접 호출용: pqf <repo> <식>
pqf() {
  local repo="$1"; shift
  (cd "$repo" && project_root="$repo" bash -c 'source "$1"; shift; eval "$@"' _ "$PQ" "$@")
}
# 요청 파일 만들기: mkreq <repo> <slug> k=v...
mkreq() {
  local repo="$1" slug="$2"; shift 2
  pqf "$repo" "pq_set '$slug' $*"
}

R="$(mk_repo r1)"

# 호출 세션 생존 확인용 herdr 대역: `herdr agent list` 가 $AGENTS_OUT 을 낸다.
BIN="$TMP/bin"; mkdir -p "$BIN"
AGENTS_OUT="$TMP/agents.out"
CALLS="$TMP/stub.calls"; : >"$CALLS"
cat >"$BIN/herdr" <<HEOF
#!/usr/bin/env bash
printf 'herdr %s\\n' "\$*" >>"$CALLS"
case "\$1 \$2" in
  "agent list") cat "$AGENTS_OUT" ;;
esac
HEOF
chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nprintf "hc %%s\\n" "$*" >>"%s"\nexit 1\n' "$CALLS" >"$BIN/hc"
chmod +x "$BIN/hc"
export RD_PQ_POLL=0.1 RD_PQ_CALLER_CHECK=0.2
set_agents() {  # set_agents <pane_id>...
  local out="" p
  for p in "$@"; do out="${out:+$out,}{\"pane_id\":\"$p\",\"tab_id\":\"t\",\"name\":\"n\",\"agent_status\":\"working\"}"; done
  printf '{"id":"cli:agent:list","result":{"agents":[%s]}}' "$out" >"$AGENTS_OUT"
}
set_agents wX:p1
export PATH="$BIN:$PATH"

# 기준 저장소(스크립트·code.txt 커밋)를 한 번만 만들고, 사례마다 bare 를 cp -R 해 쓴다.
mk_base() {
  local main s="$SCRIPT_DIR/.."
  main="$(mk_repo base)"
  ( cd "$main" && mkdir -p rd-workflow/scripts/lifecycle rd-workflow/scripts/hooks &&
    cp "$s"/lifecycle/_tasks_index.sh "$s"/lifecycle/session_launch.sh "$s"/lifecycle/slug.sh "$s"/lifecycle/_lifecycle_common.sh rd-workflow/scripts/lifecycle/ &&
    cp "$s"/hooks/_guard_common.sh rd-workflow/scripts/hooks/ &&
    cp "$s"/_state_common.sh "$s"/_task_common.sh "$s"/_submodule_common.sh "$s"/rd rd-workflow/scripts/ &&
    printf '# Current Task\n\n## Short Title\n-\n\n## Status\n대기 중\n' >CURRENT_TASK.md &&
    printf '1\n2\n3\n' >code.txt &&
    git add -A && git commit -q -m scripts && git push -q origin master 2>/dev/null )
}
mk_base

# mk_work <name> <slug> [nocaller]: 기준 저장소 사본(기본 체크아웃) + 작업 worktree(fr/<slug>).
# 작업 worktree 경로를 stdout 으로 낸다. Status 는 아카이브 보류, 호출 세션 wX:p1(herdr).
mk_work() {
  local name="$1" slug="$2" nocaller="${3:-}" main wt
  main="$TMP/$name"
  cp -R "$TMP/base.git" "$TMP/$name.git"
  git clone -q --local "$TMP/$name.git" "$main" 2>/dev/null
  git -C "$main" config user.name rd-test; git -C "$main" config user.email rd-test@example.invalid
  wt="$TMP/$name-w"
  git -C "$main" worktree add -q -b "fr/$slug" "$wt" master 2>/dev/null
  git -C "$wt" config user.name rd-test; git -C "$wt" config user.email rd-test@example.invalid
  mkdir -p "$wt/rd-workflow-workspace/.lifecycle"
  printf 'schema=1\nshort-title=%s\nstatus=아카이브 보류\nfr-branch=fr/%s\nworktree-path=%s\nsource-fr=-\nreview-session=null\nbase-commit=x\ncreated-at=2026-11-04-0000\n' "$slug" "$slug" "$wt" >"$wt/rd-workflow-workspace/.lifecycle/task-state"
  git -C "$wt" add -A && git -C "$wt" commit -q -m task-state
  if [[ "$nocaller" == nocaller ]]; then
    pqf "$wt" "tasks_index_upsert '$slug' launch=ok" >/dev/null
  else
    pqf "$wt" "tasks_index_upsert '$slug' launch=ok caller-backend=herdr caller-id=wX:p1" >/dev/null
  fi
  printf '%s\n' "$wt"
}
# set_status <wt> <값>: task-state 의 status 를 바꿔 커밋한다.
set_status() {
  local f="$1/rd-workflow-workspace/.lifecycle/task-state"
  awk -v v="$2" 'index($0,"status=")==1{print "status=" v; next}{print}' "$f" >"$f.n" && cat "$f.n" >"$f" && rm -f "$f.n"
  git -C "$1" commit -q -am "status $2"
}
reset_q() { rm -f "$(pqf "$1" pq_dir)"/*.req "$(pqf "$1" pq_dir)/ACTIVE"; }

# --- 설정 (D1)
test_config_default_caller() {
  local got
  got="$(pqf "$R" pq_approval_mode 2>&1)"
  [[ "$got" == "caller" ]] && pass "키 없음·파일 없음 → caller" || fail "기대 caller, 실제 $got"
}
test_config_invalid_user() {
  local got
  printf '{"publish_approval":"maybe"}\n' >"$R/rd-workflow/config/workflow.json"
  got="$(pqf "$R" pq_approval_mode 2>"$TMP/err")"
  if [[ "$got" == "user" ]] && grep -q 'publish_approval' "$TMP/err"; then
    pass "허용 밖 값 → user + 경고"
  else
    fail "허용 밖 값: stdout=$got stderr=$(cat "$TMP/err")"
  fi
  printf '{bad json' >"$R/rd-workflow/config/workflow.json"
  got="$(pqf "$R" pq_approval_mode 2>/dev/null)"
  [[ "$got" == "user" ]] && pass "파싱 실패 → user" || fail "파싱 실패: 기대 user, 실제 $got"
  printf '{"publish_approval":"caller"}\n' >"$R/rd-workflow/config/workflow.json"
  got="$(pqf "$R" pq_approval_mode 2>/dev/null)"
  [[ "$got" == "caller" ]] && pass "명시 caller → caller" || fail "명시 caller: 실제 $got"
  rm -f "$R/rd-workflow/config/workflow.json"
}

# --- 취소 (D10)
test_cancel_granted_releases_slot() {
  mkreq "$R" a state=granted
  pqf "$R" "pq_slot_set a"
  pq "$R" cancel a
  local st slot
  st="$(pqf "$R" "pq_get a state")"; slot="$(pqf "$R" pq_slot_get)"
  if [[ "$RC" -eq 0 && "$st" == "cancelled" && -z "$slot" ]]; then
    pass "granted 취소 → cancelled, 슬롯 반납"
  else
    fail "granted 취소: rc=$RC state=$st $([[ -n "$slot" ]] && echo '슬롯 남음')"
  fi
}
test_cancel_running_refused() {
  mkreq "$R" b state=running
  pqf "$R" "pq_slot_set b"
  pq "$R" cancel b
  if [[ "$RC" -eq 1 && "$OUT" == *recover* && "$(pqf "$R" "pq_get b state")" == "running" ]]; then
    pass "running 취소 거부(rc 1, recover 안내, 상태 유지)"
  else
    fail "running 취소: rc=$RC out=$OUT"
  fi
  pqf "$R" pq_slot_clear
}
test_cancel_terminal_and_missing() {
  mkreq "$R" c state=done
  pq "$R" cancel c
  [[ "$RC" -eq 1 && "$OUT" == *"취소할 요청 없음"* ]] && pass "종단 상태 취소 → 취소할 요청 없음" || fail "종단 취소: rc=$RC out=$OUT"
  pq "$R" cancel nosuch
  [[ "$RC" -eq 1 ]] && pass "없는 요청 취소 → rc 1" || fail "없는 요청: rc=$RC"
}

# --- 조회 (D4)
test_status_line() {
  mkreq "$R" d state=requested seq=100
  pq "$R" status d
  if [[ "$RC" -eq 0 && "$OUT" == *요청됨* && "$OUT" == *"→ 호출 세션이 rd publish next"* && "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" == "1" ]]; then
    pass "status 한 줄에 표시 상태와 → 다음 행동"
  else
    fail "status 줄: rc=$RC out=$OUT"
  fi
}
test_status_orders_by_seq() {
  mkreq "$R" s2 state=requested seq=200
  mkreq "$R" s1 state=granted seq=150
  pq "$R" status
  local order
  order="$(printf '%s\n' "$OUT" | awk '{print $1}' | grep '^s[12]$' | tr '\n' ' ')"
  [[ "$order" == "s1 s2 " ]] && pass "status 목록이 seq 순" || fail "status 정렬: $OUT"
}

# --- 손상 (Review Focus 1)
test_corrupt_req_is_undecidable() {
  local d; d="$(pqf "$R" pq_dir)"
  mkreq "$R" bad state=
  pq "$R" status bad
  [[ "$RC" -eq 3 && "$OUT" == *"판정 불가"* ]] && pass "빈 state → status rc 3 + 사유" || fail "빈 state: rc=$RC out=$OUT"
  [[ "$OUT" == *"$d/bad.req"* && "$OUT" == *"직접 고치거나 삭제"* ]] && pass "손상 문구에 절대 경로와 다음 행동" || fail "손상 문구: $OUT"
  mkreq "$R" bad2 state=zzz
  pq "$R" status bad2
  [[ "$RC" -eq 3 ]] && pass "모르는 state → rc 3" || fail "모르는 state: rc=$RC out=$OUT"
  pq "$R" cancel bad
  [[ "$RC" -eq 3 ]] && pass "손상 요청 cancel → rc 3" || fail "손상 cancel: rc=$RC out=$OUT"
  rm -f "$d/bad.req" "$d/bad2.req"
  : >"$d/ACTIVE"
  pq "$R" status
  [[ "$RC" -eq 3 && "$OUT" == *ACTIVE* && "$OUT" == *"삭제하면 슬롯이 풀립니다"* ]] && pass "빈 ACTIVE → status rc 3 + 삭제 안내" || fail "빈 ACTIVE: rc=$RC out=$OUT"
  pqf "$R" pq_slot_clear
}
test_slot_state_must_hold() {
  local M; M="$(mk_repo sl1)"
  mkreq "$M" x state=done seq=1
  pqf "$M" "pq_slot_set x"
  pq "$M" status
  [[ "$RC" -eq 3 && "$OUT" == *ACTIVE* ]] && pass "ACTIVE 가 done 요청을 가리키면 status rc 3" || fail "슬롯-done status: rc=$RC out=$OUT"
  mkreq "$M" y state=requested seq=2
  pq "$M" next
  [[ "$RC" -eq 3 && "$(pqf "$M" "pq_get y state")" == requested ]] && pass "같은 경우 next rc 3, 허가 없음" || fail "슬롯-done next: rc=$RC out=$OUT"
  pqf "$M" "pq_slot_set nosuch"
  pq "$M" next
  [[ "$RC" -eq 3 ]] && pass "ACTIVE 가 없는 요청을 가리키면 next rc 3" || fail "슬롯-없는요청 next: rc=$RC out=$OUT"
}
# --- 큐 락 (Review Focus 2)
test_stale_lock_reclaimed() {
  local dead d
  ( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null
  d="$(pqf "$R" pq_dir)"
  mkreq "$R" e state=requested
  mkdir "$d/.lock"; printf '%s\n' "$dead" >"$d/.lock/pid"
  OUT="$(cd "$R" && project_root="$R" RD_PQ_LOCK_TRIES=3 bash "$PQ" cancel e 2>&1)"; RC=$?
  if [[ "$RC" -eq 0 && "$(pqf "$R" "pq_get e state")" == "cancelled" && ! -d "$d/.lock" && ! -d "$d/.lock.reclaim" ]]; then
    pass "죽은 pid 의 락을 가드 경로로 회수 후 진행(가드 정리됨)"
  else
    fail "락 회수 실패: rc=$RC out=$OUT"
  fi
}
test_live_lock_blocks() {
  local d
  d="$(pqf "$R" pq_dir)"
  mkreq "$R" f state=requested
  sleep 30 & local lp=$!
  mkdir "$d/.lock"; printf '%s\n' "$lp" >"$d/.lock/pid"
  OUT="$(cd "$R" && project_root="$R" RD_PQ_LOCK_TRIES=2 bash "$PQ" cancel f 2>&1)"; RC=$?
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  rm -rf "$d/.lock"
  [[ "$RC" -eq 1 && "$(pqf "$R" "pq_get f state")" == "requested" ]] && pass "살아 있는 락은 회수하지 않음(rc 1)" || fail "살아 있는 락: rc=$RC out=$OUT"
}

test_stale_guard_cleared() {
  local dead d; ( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null
  d="$(pqf "$R" pq_dir)"
  mkreq "$R" g state=requested
  mkdir "$d/.lock" "$d/.lock.reclaim"
  printf '%s\n' "$dead" >"$d/.lock/pid"; printf '%s\n' "$dead" >"$d/.lock.reclaim/pid"
  OUT="$(cd "$R" && project_root="$R" RD_PQ_LOCK_TRIES=5 bash "$PQ" cancel g 2>&1)"; RC=$?
  [[ "$RC" -eq 0 && ! -d "$d/.lock" && ! -d "$d/.lock.reclaim" ]] && pass "죽은 가드 보유자의 가드를 치우고 락 회수" || fail "낡은 가드: rc=$RC out=$OUT"
}
test_lock_reclaim_rechecks_pid() {
  local dead d lp rc; ( exit 0 ) & dead=$!; wait "$dead" 2>/dev/null
  d="$(pqf "$R" pq_dir)"
  sleep 30 & lp=$!
  mkdir "$d/.lock"; printf '%s\n' "$lp" >"$d/.lock/pid"
  rc=0; pqf "$R" "_pq_lock_reclaim '$d' '$dead'" || rc=$?
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  if [[ "$rc" -eq 1 && -d "$d/.lock" && ! -d "$d/.lock.reclaim" ]]; then
    pass "읽은 뒤 락 pid 가 살아 있는 pid 로 바뀌면 회수하지 않음(가드 반납)"
  else
    fail "재확인: rc=$rc 락=$([[ -d "$d/.lock" ]] && echo 있음 || echo 없음)"
  fi
  rm -rf "$d/.lock"
}
test_lock_without_pid() {
  local d rc; d="$(pqf "$R" pq_dir)"
  mkdir "$d/.lock"
  rc=0; pqf "$R" "_pq_lock_reclaim '$d' ''" || rc=$?
  [[ "$rc" -eq 1 && -d "$d/.lock" ]] && pass "pid 없는 새 락은 회수하지 않음(mkdir 직후 구간)" || fail "새 pid 없는 락: rc=$rc"
  touch -t 200001010000 "$d/.lock"
  mkreq "$R" h state=requested
  OUT="$(cd "$R" && project_root="$R" RD_PQ_LOCK_TRIES=3 bash "$PQ" cancel h 2>&1)"; RC=$?
  [[ "$RC" -eq 0 && "$(pqf "$R" "pq_get h state")" == cancelled && ! -d "$d/.lock" ]] && pass "10초 넘게 pid 가 없는 락은 회수" || fail "오래된 pid 없는 락: rc=$RC out=$OUT"
}
test_unlock_not_owner() {
  local d rc; d="$(pqf "$R" pq_dir)"
  mkdir "$d/.lock"; printf '1\n' >"$d/.lock/pid"
  rc=0; pqf "$R" pq_unlock || rc=$?
  [[ "$rc" -eq 1 && -d "$d/.lock" ]] && pass "pq_unlock 은 남의 락을 지우지 않음" || fail "남의 락 해제: rc=$rc"
  rm -rf "$d/.lock"
}
test_prune_done_path_with_space() {
  local SP d; SP="$(mk_repo "sp ace")"; d="$(pqf "$SP" pq_dir)"
  mkreq "$SP" old state=done seq=1
  mkreq "$SP" young state=done seq=2
  touch -t 200001010000 "$d/old.req"
  pq "$SP" status
  [[ ! -f "$d/old.req" && -f "$d/young.req" ]] && pass "공백 경로에서 7일 지난 done 만 정리" || fail "정리: old=$([[ -f "$d/old.req" ]] && echo 남음) young=$([[ -f "$d/young.req" ]] && echo 있음 || echo 없음)"
}
test_cancel_more_states() {
  mkreq "$R" ua state=user-approval
  pq "$R" cancel ua
  [[ "$RC" -eq 0 && "$(pqf "$R" "pq_get ua state")" == cancelled ]] && pass "user-approval 취소 → cancelled" || fail "user-approval 취소: rc=$RC out=$OUT"
  mkreq "$R" pt state=partial
  pq "$R" cancel pt
  [[ "$RC" -eq 1 && "$OUT" == *recover* && "$(pqf "$R" "pq_get pt state")" == partial ]] && pass "partial 취소 거부(recover 안내, 상태 유지)" || fail "partial 취소: rc=$RC out=$OUT"
}
test_config_file_without_key() {
  mkdir -p "$R/rd-workflow/config"
  printf '{"other":1}\n' >"$R/rd-workflow/config/workflow.json"
  local got; got="$(pqf "$R" pq_approval_mode 2>&1)"
  rm -f "$R/rd-workflow/config/workflow.json"
  [[ "$got" == caller ]] && pass "workflow.json 은 있고 키만 없음 → caller" || fail "키 없음: $got"
}

# --- 디스패치
test_unimplemented_and_usage() {
  pq "$R" bogus; [[ "$RC" -eq 2 ]] && pass "모르는 하위 명령 rc 2" || fail "모르는 명령: rc=$RC"
  pq "$R" cancel '../x'; [[ "$RC" -eq 2 ]] && pass "올바르지 않은 slug rc 2" || fail "slug 검증: rc=$RC"
}


# --- 요청 (D5)
test_request_user_mode() {
  local W; W="$(mk_work rq1 pq-a)"
  mkdir -p "$W/rd-workflow/config"
  printf '{"publish_approval":"user"}\n' >"$W/rd-workflow/config/workflow.json"
  git -C "$W" add -A && git -C "$W" commit -q -m "approval=user"
  pq "$W" request
  if [[ "$RC" -eq 10 && "$OUT" == *"사용자 승인 대상"* && ! -f "$(pqf "$W" pq_dir)/pq-a.req" ]]; then
    pass "설정 user → rc 10, 요청 파일 없음"
  else
    fail "user 모드: rc=$RC out=$OUT"
  fi
}
test_request_no_caller() {
  local W; W="$(mk_work rq2 pq-b nocaller)"
  pq "$W" request
  if [[ "$RC" -eq 10 && ! -f "$(pqf "$W" pq_dir)/pq-b.req" ]]; then
    pass "색인에 caller-id 없음 → rc 10"
  else
    fail "caller 없음: rc=$RC out=$OUT"
  fi
}
test_request_preconditions() {
  local W R2; W="$(mk_work rq3 pq-c)"; R2="$TMP/rq3"
  set_status "$W" "구현 중"
  pq "$W" request
  [[ "$RC" -eq 1 && "$OUT" == *"구현 중"* ]] && pass "Status 구현 중 → rc 1" || fail "Status 사례: rc=$RC out=$OUT"
  set_status "$W" "아카이브 보류"
  printf 'x\n' >"$W/dirty.txt"
  pq "$W" request
  [[ "$RC" -eq 1 && "$OUT" == *dirty.txt* ]] && pass "미커밋 파일 → rc 1" || fail "미커밋 사례: rc=$RC out=$OUT"
  rm -f "$W/dirty.txt"
  printf 'm\n' >"$R2/code.txt"; git -C "$R2" commit -q -am "main code"
  printf 'w\n' >"$W/code.txt"; git -C "$W" commit -q -am "work code"
  pq "$W" request
  [[ "$RC" -eq 1 && "$OUT" == *code.txt* ]] && pass "양쪽이 같은 코드 파일을 고침 → rc 1, 경로 출력" || fail "코드 충돌 사례: rc=$RC out=$OUT"
  [[ ! -f "$(pqf "$W" pq_dir)/pq-c.req" ]] && pass "사전 확인 실패는 요청을 만들지 않음" || fail "실패인데 요청 파일 생김"
}
test_request_auto_files_ok() {
  local W R2; W="$(mk_work rq4 pq-d)"; R2="$TMP/rq4"
  printf 'm\n' >"$R2/CURRENT_TASK.md"; git -C "$R2" commit -q -am "main ct"
  printf 'w\n' >"$W/CURRENT_TASK.md"; git -C "$W" commit -q -am "work ct"
  pq "$W" request
  [[ "$RC" -eq 0 && "$(pqf "$W" "pq_get pq-d state")" == requested ]] && pass "자동 해소 경로만 충돌 → 요청 생성" || fail "자동 해소 사례: rc=$RC out=$OUT"
}
test_request_caller_lost() {
  local W; W="$(mk_work rq5 pq-e)"
  pqf "$W" "tasks_index_upsert pq-e caller-id=wX:p9" >/dev/null
  pq "$W" request
  local st; st="$(pqf "$W" "pq_get pq-e state")"
  [[ "$RC" -eq 11 && "$st" == user-approval ]] && pass "호출 세션 소실 → rc 11, user-approval" || fail "소실 사례: rc=$RC state=$st out=$OUT"
}
test_request_duplicate_updates() {
  local W n s1 s2; W="$(mk_work rq6 pq-f)"
  pq "$W" request; s1="$(pqf "$W" "pq_get pq-f seq")"
  [[ "$RC" -eq 0 ]] || fail "첫 요청: rc=$RC out=$OUT"
  pq "$W" request; s2="$(pqf "$W" "pq_get pq-f seq")"
  n="$(ls "$(pqf "$W" pq_dir)"/*.req | wc -l | tr -d ' ')"
  [[ "$RC" -eq 0 && "$n" == 1 && "$s2" -gt "$s1" ]] && pass "같은 slug 재요청 → 파일 하나, seq 갱신" || fail "재요청: rc=$RC n=$n seq $s1→$s2"
  pqf "$W" "pq_set pq-f state=granted"
  pq "$W" request
  [[ "$RC" -eq 1 && "$(pqf "$W" "pq_get pq-f state")" == granted ]] && pass "granted 상태 재요청 → rc 1" || fail "granted 재요청: rc=$RC out=$OUT"
}

# --- 허가 (D6)
test_next_blocked_by_merge_head() {
  local M; M="$(mk_repo nx1)"
  mkreq "$M" a state=requested seq=1
  : >"$M/.git/MERGE_HEAD"
  pq "$M" next
  local st; st="$(pqf "$M" "pq_get a state")"
  rm -f "$M/.git/MERGE_HEAD"
  [[ "$RC" -eq 1 && "$st" == requested && "$OUT" == *MERGE_HEAD* ]] && pass "MERGE_HEAD → rc 1, 허가 없음" || fail "MERGE_HEAD: rc=$RC state=$st out=$OUT"
  printf 'x\n' >"$M/dirty"
  pq "$M" next
  rm -f "$M/dirty"
  [[ "$RC" -eq 1 && "$(pqf "$M" "pq_get a state")" == requested ]] && pass "기본 체크아웃 미커밋 → rc 1" || fail "미커밋 기본 체크아웃: rc=$RC"
}
test_next_oldest_first() {
  local M; M="$(mk_repo nx2)"
  mkreq "$M" a state=requested seq=2000
  mkreq "$M" b state=requested seq=1000
  pq "$M" next
  if [[ "$RC" -eq 0 && "$(pqf "$M" "pq_get b state")" == granted && "$(pqf "$M" "pq_get a state")" == requested && "$(pqf "$M" pq_slot_get)" == b ]]; then
    pass "가장 오래된 요청 b 허가, 슬롯 b"
  else
    fail "oldest_first: rc=$RC out=$OUT a=$(pqf "$M" "pq_get a state") b=$(pqf "$M" "pq_get b state")"
  fi
  pq "$M" next
  [[ "$RC" -eq 1 && "$OUT" == *b* && "$(pqf "$M" "pq_get a state")" == requested ]] && pass "슬롯 점유 중 두 번째 next → rc 1, 사유에 b" || fail "두 번째 next: rc=$RC out=$OUT"
}
test_next_parallel_single_grant() {
  local M i n=0 gr; M="$(mk_repo nx3)"
  mkreq "$M" a state=requested seq=1
  mkreq "$M" b state=requested seq=2
  ( cd "$M" && project_root="$M" bash "$PQ" next >/dev/null 2>&1 ) &
  ( cd "$M" && project_root="$M" bash "$PQ" next >/dev/null 2>&1 ) &
  wait
  for i in a b; do [[ "$(pqf "$M" "pq_get $i state")" == granted ]] && n=$((n+1)); done
  [[ "$n" -eq 1 ]] && pass "동시 next 두 개 → granted 정확히 하나" || fail "동시 허가: granted ${n}건"
}
test_next_refuses_with_corrupt() {
  local M; M="$(mk_repo nx5)"
  mkreq "$M" a state=requested seq=1
  mkreq "$M" bad state=
  pq "$M" next
  [[ "$RC" -eq 3 && "$(pqf "$M" "pq_get a state")" == requested && -z "$(pqf "$M" pq_slot_get)" && "$OUT" == *"bad.req"* ]] && pass "손상 요청 파일이 있으면 next 는 허가하지 않고 rc 3" || fail "손상 next: rc=$RC out=$OUT"
}
test_approve_user_approval() {
  local M; M="$(mk_repo nx4)"
  mkreq "$M" x state=user-approval seq=1
  mkreq "$M" y state=user-approval seq=2
  pq "$M" approve x
  [[ "$RC" -eq 0 && "$(pqf "$M" "pq_get x state")" == granted && "$(pqf "$M" pq_slot_get)" == x ]] && pass "approve → granted, 슬롯 점유" || fail "approve: rc=$RC out=$OUT"
  pq "$M" approve y
  [[ "$RC" -eq 1 && "$(pqf "$M" "pq_get y state")" == user-approval ]] && pass "슬롯 점유 중 approve → rc 1, 상태 유지" || fail "점유 중 approve: rc=$RC out=$OUT"
  mkreq "$M" z state=requested seq=3
  pqf "$M" pq_slot_clear
  pq "$M" approve z
  [[ "$RC" -eq 1 && "$(pqf "$M" "pq_get z state")" == requested ]] && pass "user-approval 이 아니면 approve 거부" || fail "비대상 approve: rc=$RC out=$OUT"
}

# --- run·recover (D8·D11). archive 대역은 실제 git 병합·tag·push 를 멱등하게 수행한다.
#   PQ_ARCH_WAIT=<표식 파일>  표식이 생길 때까지 대기   REJECT 파일(bare 안)이 있으면 push 거부
cat >"$TMP/archive_double.sh" <<'AEOF'
#!/usr/bin/env bash
echo "called" >>"$PQ_ARCH_LOG"
if [[ -n "${PQ_ARCH_WAIT:-}" ]]; then
  for _i in $(seq 1 100); do [[ -f "$PQ_ARCH_WAIT" ]] && break; sleep 0.1; done
fi
cd "$PQ_MAIN" || exit 1
git merge-base --is-ancestor "fr/$PQ_SLUG" master 2>/dev/null || git merge -q --no-ff -m merge "fr/$PQ_SLUG" || exit 1
git tag --list "fr/*/$PQ_SLUG" | grep -q . || git tag "fr/t/$PQ_SLUG"
git push -q origin master "fr/t/$PQ_SLUG" 2>&1 || exit 1
AEOF
chmod +x "$TMP/archive_double.sh"

# setup_run <name> <slug>: 작업 worktree $W, 기본 체크아웃 $M, bare $B 를 만들고 대역 환경을 건다.
W=""; M=""; B=""
setup_run() {
  W="$(mk_work "$1" "$2")"; M="$TMP/$1"; B="$TMP/$1.git"
  export RD_PQ_ARCHIVE="$TMP/archive_double.sh" PQ_MAIN="$M" PQ_SLUG="$2" PQ_ARCH_LOG="$TMP/$1.log"
  printf '#!/bin/sh\n[ -f "%s/REJECT" ] && { echo reject >&2; exit 1; }\nexit 0\n' "$B" >"$B/hooks/pre-receive"
  chmod +x "$B/hooks/pre-receive"
}
# mkstate <slug> <state> [k=v...]: W 의 HEAD 를 head 로 하는 요청을 만들고, granted|running|partial 이면 슬롯을 쥔다.
mkstate() {
  local slug="$1" st="$2"; shift 2
  pqf "$W" "pq_set '$slug' state=$st head=$(git -C "$W" rev-parse HEAD) seq=1 worktree='$W' fr-branch=fr/$slug $*"
  case "$st" in granted|running|partial) pqf "$W" "pq_slot_set '$slug'" ;; esac
}
logn() { [[ -f "$PQ_ARCH_LOG" ]] && wc -l <"$PQ_ARCH_LOG" | tr -d ' ' || echo 0; }
deadpid() { local p; ( exit 0 ) & p=$!; wait "$p" 2>/dev/null; echo "$p"; }
# waitfor <식>: 최대 5초 동안 식이 참이 되길 기다린다.
waitfor() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }
getk() { pqf "$W" "pq_get '$1' $2"; }

test_run_without_grant() {
  setup_run rn1 ra
  mkstate ra requested
  pq "$W" run
  [[ "$RC" -eq 1 && "$(logn)" == 0 ]] && pass "허가 없는 run → rc 1, archive 미호출" || fail "허가 없음: rc=$RC log=$(logn) out=$OUT"
}
test_run_twice() {
  setup_run rn2 rb
  mkstate rb granted
  export PQ_ARCH_WAIT="$TMP/rn2.mark"
  ( cd "$W" && project_root="$W" bash "$PQ" run >"$TMP/rn2.out1" 2>&1 ) &
  local first=$!
  if ! waitfor '[[ -n "$(getk rb archive-pgid)" ]]'; then fail "첫 run 이 archive 에 진입하지 못함"; touch "$PQ_ARCH_WAIT"; wait "$first"; return; fi
  local rp; rp="$(getk rb run-pid)"
  pq "$W" run
  local n2; n2="$(logn)"
  touch "$PQ_ARCH_WAIT"; wait "$first"
  if [[ "$RC" -eq 1 && "$OUT" == *"이미 발행 중"* && "$OUT" == *"$rp"* && "$n2" == 1 && "$(logn)" == 1 ]]; then
    pass "발행 중 두 번째 run → rc 1 '이미 발행 중'(pid), archive 1회"
  else
    fail "run 두 번: rc=$RC out=$OUT archive=$(logn) rp=$rp"
  fi
}
test_run_head_changed() {
  setup_run rn3 rc
  mkstate rc granted
  printf 'z\n' >"$W/z.txt"; git -C "$W" add -A; git -C "$W" commit -q -m more
  pq "$W" run
  if [[ "$RC" -eq 1 && "$(getk rc state)" == failed && -z "$(pqf "$W" pq_slot_get)" && "$(logn)" == 0 ]]; then
    pass "허가 뒤 HEAD 변경 → failed, 슬롯 반납, archive 미호출"
  else
    fail "HEAD 변경: rc=$RC state=$(getk rc state) out=$OUT"
  fi
}
test_run_success() {
  setup_run rn4 rd
  mkstate rd granted
  mkreq "$M" nx state=requested seq=99999999999999
  pq "$W" run
  local tag; tag="$(getk rd result-tag)"
  if [[ "$RC" -eq 0 && "$(getk rd state)" == done && -n "$tag" && -z "$(pqf "$W" pq_slot_get)" ]]; then
    pass "run 성공 → done, result-tag 기록, 슬롯 반납"
  else
    fail "run 성공: rc=$RC state=$(getk rd state) tag=$tag out=$OUT"
  fi
  pq "$M" next
  [[ "$RC" -eq 0 && "$(pqf "$M" "pq_get nx state")" == granted ]] && pass "성공 뒤 다음 요청 next 허가" || fail "성공 뒤 next: rc=$RC out=$OUT"
}
test_partial_retry() {
  setup_run rn5 re
  mkstate re granted
  mkreq "$M" nx state=requested seq=99999999999999
  touch "$B/REJECT"
  pq "$W" run
  [[ "$RC" -eq 1 && "$(getk re state)" == partial && "$(pqf "$W" pq_slot_get)" == re ]] && pass "push 거부 → partial, 슬롯 유지" || fail "partial 1: rc=$RC state=$(getk re state) out=$OUT"
  pq "$W" run
  [[ "$RC" -eq 1 && "$(getk re state)" == partial && "$(pqf "$W" pq_slot_get)" == re ]] && pass "재실행도 거부 → partial 유지" || fail "partial 2: rc=$RC state=$(getk re state) out=$OUT"
  rm -f "$B/REJECT"
  pq "$W" run
  [[ "$RC" -eq 0 && "$(getk re state)" == done ]] && pass "거부 해소 뒤 run → done" || fail "partial 3: rc=$RC state=$(getk re state) out=$OUT"
  pq "$M" next
  [[ "$RC" -eq 0 && "$(pqf "$M" "pq_get nx state")" == granted ]] && pass "복구 완료 뒤 next 허가" || fail "복구 뒤 next: rc=$RC out=$OUT"
}
test_partial_reverify_keeps_slot() {
  setup_run rn6 rf
  mkstate rf partial
  mkreq "$M" nx state=requested seq=99999999999999
  printf 'x\n' >"$M/dirty"
  pq "$W" run
  if [[ "$RC" -eq 1 && "$(getk rf state)" == partial && "$(pqf "$W" pq_slot_get)" == rf && "$(logn)" == 0 ]]; then
    pass "partial 재검증 실패 → partial·슬롯 유지, archive 미호출"
  else
    fail "partial 재검증: rc=$RC state=$(getk rf state) slot=$(pqf "$W" pq_slot_get) out=$OUT"
  fi
  rm -f "$M/dirty"
  pq "$M" next
  [[ "$RC" -eq 1 && "$(pqf "$M" "pq_get nx state")" == requested ]] && pass "슬롯이 유지돼 다른 요청 next 거부" || fail "슬롯 유지 next: rc=$RC out=$OUT"
  pq "$W" run
  [[ "$RC" -eq 0 && "$(getk rf state)" == done ]] && pass "원인 제거 뒤 run → done" || fail "원인 제거 뒤 run: rc=$RC state=$(getk rf state) out=$OUT"
}
test_recover_alive_pid() {
  setup_run rn7 rg
  bash -c 'sleep 30; : publish_queue.sh' & local lp=$!
  mkstate rg running "run-pid=$lp"
  pq "$W" recover rg
  local rc=$RC st; st="$(getk rg state)"
  pkill -P "$lp" 2>/dev/null; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  [[ "$rc" -eq 1 && "$st" == running ]] && pass "run-pid 생존 → recover 거부, running 유지" || fail "생존 pid: rc=$rc state=$st"
}
test_recover_not_merged() {
  setup_run rn8 rh
  mkstate rh running "run-pid=$(deadpid)" run-token=T
  pq "$W" recover rh
  local rc=$RC
  if [[ "$rc" -eq 0 && "$(getk rh state)" == requested && -z "$(pqf "$W" pq_slot_get)" && -z "$(getk rh run-token)" ]]; then
    pass "미병합 recover → requested, 슬롯 반납, 토큰 비움"
  else
    fail "미병합 recover: rc=$rc state=$(getk rh state) slot=$(pqf "$W" pq_slot_get)"
  fi
  pq "$W" status rh
  [[ "$OUT" != *recover* ]] && pass "recover 뒤 status 에 recover 안내 없음" || fail "status: $OUT"
}
test_status_points_recover() {
  setup_run rn9 ri
  mkstate ri running "run-pid=$(deadpid)"
  pq "$W" status ri
  [[ "$OUT" == *"→"*"rd publish recover"* ]] && pass "running status 의 다음 행동이 recover" || fail "status: $OUT"
}
test_recover_orphan_archive() {
  setup_run rn10 rj
  set -m; sleep 30 & local lp=$!; set +m
  local pg; pg="$(ps -o pgid= -p "$lp" | tr -d ' ')"
  mkstate rj running "run-pid=$(deadpid)" "archive-pgid=$pg"
  pq "$W" recover rj
  local rc=$RC st; st="$(getk rj state)"
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  [[ "$rc" -eq 1 && "$st" == running ]] && pass "archive 그룹 생존 → recover 거부" || fail "고아 archive: rc=$rc state=$st out=$OUT"
}
test_recover_lock_owner() {
  setup_run rn11 rk
  sleep 30 & local lp=$!
  mkstate rk running "run-pid=$(deadpid)"
  local ld; ld="$(pqf "$W" tasks_shared_dir)/tasks.lock"
  mkdir "$ld"; printf 'pid=%s\ncmd=archive\nslug=rk\nstarted-at=x\n' "$lp" >"$ld/owner"
  pq "$W" recover rk
  local rc=$RC st; st="$(getk rk state)"
  rm -rf "$ld"; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  [[ "$rc" -eq 1 && "$st" == running ]] && pass "tasks 락 owner(archive, 생존) → recover 거부" || fail "락 owner: rc=$rc state=$st out=$OUT"
}
test_exec_refused_after_recover() {
  setup_run rn12 rl
  mkstate rl running "run-pid=$(deadpid)" run-token=T
  pq "$W" recover rl
  local rc=$RC tok; tok="$(getk rl run-token)"
  pq "$W" _exec rl T
  if [[ "$rc" -eq 0 && -z "$tok" && "$RC" -eq 1 && "$(logn)" == 0 ]]; then
    pass "recover 뒤 늦은 _exec → 거부, archive 미진입, run-token 비움"
  else
    fail "recover 뒤 _exec: recover=$rc token=$tok exec=$RC archive=$(logn)"
  fi
}
test_exec_records_pgid_then_recover_refused() {
  setup_run rn13 rm
  mkstate rm running "run-pid=$(deadpid)" run-token=T
  export PQ_ARCH_WAIT="$TMP/rn13.mark"
  set -m
  ( cd "$W" && project_root="$W" bash "$PQ" _exec rm T >/dev/null 2>&1 ) &
  local ep=$!
  set +m
  if ! waitfor '[[ -n "$(getk rm archive-pgid)" ]]'; then
    fail "archive-pgid 대기 시간 초과"; touch "$PQ_ARCH_WAIT"; wait "$ep"; return
  fi
  pq "$W" recover rm
  local rc=$RC st; st="$(getk rm state)"
  touch "$PQ_ARCH_WAIT"; wait "$ep"
  [[ "$rc" -eq 1 && "$st" == running ]] && pass "_exec 가 pgid 기록 → 죽은 run-pid 에도 recover 거부" || fail "pgid 인계: rc=$rc state=$st out=$OUT"
}
test_exec_stale_token_next_generation() {
  setup_run rn14 rn
  mkstate rn running "run-pid=$(deadpid)" run-token=T2 archive-pgid=77777
  pq "$W" _exec rn T
  if [[ "$RC" -eq 1 && "$(logn)" == 0 && "$(getk rn archive-pgid)" == 77777 ]]; then
    pass "옛 토큰 _exec → 거부, archive 미호출, pgid 그대로"
  else
    fail "옛 토큰: rc=$RC archive=$(logn) pgid=$(getk rn archive-pgid)"
  fi
}
test_exec_refused_non_running_state() {
  setup_run rn15 ro
  mkstate ro requested run-token=T
  pq "$W" _exec ro T
  [[ "$RC" -eq 1 && "$(logn)" == 0 ]] && pass "running 이 아닌 상태의 _exec → 거부" || fail "비 running _exec: rc=$RC archive=$(logn)"
}

# --- run 실패 사유 (D8.4)
test_run_failed_reason_last_line() {
  setup_run rn16 rp
  mkstate rp granted
  printf '#!/usr/bin/env bash\necho "시작"\necho "merge 실패 — conflict resolve 후 재실행"\necho\nexit 1\n' >"$TMP/rn16.arch"
  chmod +x "$TMP/rn16.arch"
  export RD_PQ_ARCHIVE="$TMP/rn16.arch"
  pq "$W" run
  local why; why="$(getk rp reason)"
  if [[ "$RC" -eq 1 && "$(getk rp state)" == failed && "$why" == *"종료 코드 1"* && "$why" == *"merge 실패 — conflict resolve 후 재실행"* && "$OUT" == *"conflict resolve"* ]]; then
    pass "archive 실패 → failed, 사유에 종료 코드와 마지막 출력 줄(터미널에도 출력)"
  else
    fail "실패 사유: rc=$RC reason=$why out=$OUT"
  fi
}

# --- wait·watch (D9·D13). 백그라운드 프로세스는 --timeout 으로 스스로 끝나고, 사례 끝에서 한 번 더 정리한다.
bgrun() {  # <repo> <out> <args...>: 큐 명령을 백그라운드로 실행하고 pid 를 BGPID 에 담는다.
  local repo="$1" out="$2"; shift 2
  ( cd "$repo" && project_root="$repo" bash "$PQ" "$@" >"$out" 2>&1 ) &
  BGPID=$!
}
# runlim <초> <repo> <args...>: 상한 안에 끝나지 않으면 죽이고 RC=124. 출력은 $OUT.
runlim() {
  local lim="$1" repo="$2" f i p; shift 2
  f="$(mktemp "$TMP/rl.XXXXXX")" || { RC=125; OUT="mktemp 실패"; return 1; }
  bgrun "$repo" "$f" "$@"; p=$BGPID
  for i in $(seq 1 $((lim*10))); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$p" 2>/dev/null; then bgend "$p"; RC=124; else wait "$p"; RC=$?; fi
  OUT="$(cat "$f")"
}
bgend() { local p="$1"; kill "$p" 2>/dev/null; pkill -P "$p" 2>/dev/null; wait "$p" 2>/dev/null; }
test_wait_wakes_on_grant() {
  local W2 M2 rc; W2="$(mk_work wt1 wa)"; M2="$TMP/wt1"
  mkreq "$W2" wa state=requested seq=1
  bgrun "$W2" "$TMP/wt1.out" wait --timeout 8; local p=$BGPID
  sleep 0.5
  pq "$M2" next
  wait "$p"; rc=$?
  if [[ "$rc" -eq 0 && "$(cat "$TMP/wt1.out")" == *"rd publish run"* ]]; then
    pass "wait → next 허가에 깨어 rc 0, 출력에 rd publish run"
  else
    fail "wait 허가: rc=$rc out=$(cat "$TMP/wt1.out") next=$OUT"
  fi
  bgend "$p"
}
test_wait_timeout() {
  local W2 t0 rc out; W2="$(mk_work wt2 wb)"
  mkreq "$W2" wb state=requested seq=1
  t0=$SECONDS
  runlim 5 "$W2" wait --timeout 1; rc=$RC; out="$OUT"
  if [[ "$rc" -eq 4 && "$out" == *"큐 확인을 요청"* && $((SECONDS-t0)) -le 5 ]]; then
    pass "wait --timeout 1 → rc 4, 호출 세션 확인 안내"
  else
    fail "wait 시간 초과: rc=$rc out=$out"
  fi
}
test_wait_caller_lost() {
  local W2 rc; W2="$(mk_work wt3 wc)"
  pqf "$W2" "tasks_index_upsert wc caller-id=wX:p9" >/dev/null
  mkreq "$W2" wc state=requested seq=1
  bgrun "$W2" "$TMP/wt3.out" wait --timeout 8; local p=$BGPID
  wait "$p"; rc=$?
  if [[ "$rc" -eq 11 && "$(getk_in "$W2" wc state)" == user-approval && "$(cat "$TMP/wt3.out")" == *"rd publish approve"* ]]; then
    pass "wait 중 호출 세션 소실 → rc 11, user-approval, 승인 안내"
  else
    fail "wait 소실: rc=$rc state=$(getk_in "$W2" wc state) out=$(cat "$TMP/wt3.out")"
  fi
  bgend "$p"
}
getk_in() { pqf "$1" "pq_get '$2' $3"; }
test_watch_on_request() {
  local M2 rc; M2="$(mk_repo wt4)"
  bgrun "$M2" "$TMP/wt4.out" watch --timeout 8; local p=$BGPID
  sleep 0.5
  mkreq "$M2" r1 state=requested seq=1
  wait "$p"; rc=$?
  if [[ "$rc" -eq 0 && "$(cat "$TMP/wt4.out")" == *"rd publish next"* && "$(cat "$TMP/wt4.out")" == *"watch"* ]]; then
    pass "watch → 새 요청에 rc 0, 출력에 rd publish next 와 반복 안내"
  else
    fail "watch 요청: rc=$rc out=$(cat "$TMP/wt4.out")"
  fi
  bgend "$p"
}
test_watch_on_result() {
  local M2 rc; M2="$(mk_repo wt5)"
  mkreq "$M2" a state=running seq=1
  pqf "$M2" "pq_slot_set a"
  bgrun "$M2" "$TMP/wt5.out" watch --timeout 8; local p=$BGPID
  sleep 0.5
  mkreq "$M2" a state=done
  pqf "$M2" pq_slot_clear
  wait "$p"; rc=$?
  if [[ "$rc" -eq 0 && "$(cat "$TMP/wt5.out")" == *"성공"* ]]; then
    pass "watch → 슬롯 요청이 done 이 되면 rc 0"
  else
    fail "watch 결과: rc=$rc out=$(cat "$TMP/wt5.out")"
  fi
  bgend "$p"
}
test_watch_result_between_watches() {
  local M2 rc1 rc2 out1 out2; M2="$(mk_repo wt6)"
  mkreq "$M2" a state=requested seq=1
  pq "$M2" next
  mkreq "$M2" a state=done
  pqf "$M2" pq_slot_clear
  runlim 5 "$M2" watch --timeout 3; rc1=$RC; out1="$OUT"
  runlim 5 "$M2" watch --timeout 1; rc2=$RC; out2="$OUT"
  if [[ "$rc1" -eq 0 && "$out1" == *a* && "$out1" == *"성공"* && "$rc2" -eq 4 ]]; then
    pass "감시 사이에 끝난 결과를 다음 watch 가 즉시 보고하고 두 번 보고하지 않음"
  else
    fail "watch 사이 결과: rc1=$rc1 out1=$out1 rc2=$rc2 out2=$out2"
  fi
}
check_no_input_injection() {
  if grep -qE '^(herdr agent prompt|herdr pane send-text|hc send|herdr .*send-text|herdr .*agent prompt)' "$CALLS"; then
    fail "입력 주입 호출 기록: $(grep -E 'prompt|send' "$CALLS" | head -3 | tr '\n' ' ')"
  else
    pass "herdr·hc 대역이 prompt·send-text·send 호출을 받지 않음"
  fi
}

# 통합: 실제 archive.sh 가 「병합 뒤 push 거부 → 중단 → recover → 재실행(병합 건너뛰고 tag·push)」 을 통과하는지.
# 실제 archive.sh 재실행 경로를 검증하는 유일한 사례라 수 초의 비용을 감수한다(예산 15초).
test_real_archive_partial_recovery() {
  export HERDR_ENV= HC_TERMINAL_ID= RD_CHILD_SESSION=1
  unset project_root TASK_STATE_PATH
  local REPO="$TMP/int" BARE="$TMP/int.git" WT slug=alpha out
  mkdir -p "$REPO/rd-workflow"; cp -R "$SCRIPT_DIR/.." "$REPO/rd-workflow/scripts"
  git init -q -b main "$REPO"; git init -q --bare -b main "$BARE"
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  mkdir -p "$REPO/rd-workflow-workspace/.lifecycle" "$REPO/rd-workflow-workspace/backlog/items"
  cp "$SCRIPT_DIR/../../../.gitignore" "$REPO/.gitignore"
  bash -c "source '$SCRIPT_DIR/_lifecycle_common.sh'; emit_current_task_baseline" >"$REPO/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' >"$REPO/rd-workflow-workspace/.lifecycle/task-state"
  printf '# Change Request\n\n## Source FR\n-\n' >"$REPO/REQUEST.md"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m seed
  git -C "$REPO" remote add origin "$BARE"; git -C "$REPO" push -q origin main 2>/dev/null
  bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title "$slug" --size large --source-fr - >/dev/null 2>&1 || { fail "통합: promote 실패"; return; }
  WT="$REPO/.worktrees/$slug"
  printf 'work\n' >"$WT/src-alpha.txt"; git -C "$WT" add -A; git -C "$WT" commit -q -m impl
  sed -i 's/^status=.*/status=아카이브 보류/' "$WT/rd-workflow-workspace/.lifecycle/task-state"
  git -C "$WT" add -A; git -C "$WT" commit -q -m status
  printf '#!/usr/bin/env bash\nexec bash rd-workflow/scripts/lifecycle/archive.sh --force-skip-review-check 테스트 --allow-status-mismatch 테스트\n' >"$TMP/int-wrap.sh"
  chmod +x "$TMP/int-wrap.sh"
  printf '#!/bin/sh\n[ -f "%s/REJECT" ] && { echo reject >&2; exit 1; }\nexit 0\n' "$BARE" >"$BARE/hooks/pre-receive"
  chmod +x "$BARE/hooks/pre-receive"
  export RD_PQ_ARCHIVE="$TMP/int-wrap.sh"
  PQ="$REPO/rd-workflow/scripts/lifecycle/publish_queue.sh"
  pqf "$WT" "pq_set $slug state=granted head=$(git -C "$WT" rev-parse HEAD) seq=1 worktree='$WT' fr-branch=fr/$slug; pq_slot_set $slug"
  # 1. push 거부 → partial, 슬롯 유지
  touch "$BARE/REJECT"
  pq "$WT" run
  [[ "$RC" -eq 1 && "$(pqf "$WT" "pq_get $slug state")" == partial && "$(pqf "$WT" pq_slot_get)" == "$slug" ]] \
    && pass "통합 1: 병합 뒤 push 거부 → partial, 슬롯 유지" || fail "통합 1: rc=$RC state=$(pqf "$WT" "pq_get $slug state") out=$OUT"
  # 2. 병합 뒤 push 전 중단을 흉내 → recover → partial
  pqf "$WT" "pq_set $slug state=running run-pid=999999 run-token=T archive-pgid="
  pq "$WT" recover "$slug"
  [[ "$RC" -eq 0 && "$(pqf "$WT" "pq_get $slug state")" == partial && "$(pqf "$WT" pq_slot_get)" == "$slug" ]] \
    && pass "통합 2: running 중단 → recover → partial(슬롯 유지)" || fail "통합 2: rc=$RC state=$(pqf "$WT" "pq_get $slug state") out=$OUT"
  # 3. 거부 해소 → 실제 archive.sh 재실행이 tag·push 만 하고 done
  rm -f "$BARE/REJECT"
  pq "$WT" run
  if [[ "$RC" -eq 0 && "$(pqf "$WT" "pq_get $slug state")" == done && -n "$(git -C "$BARE" tag --list "fr/*/$slug")" ]]; then
    pass "통합 3: 재실행이 병합을 건너뛰고 tag·push → done, 원격에 tag"
  else
    fail "통합 3: rc=$RC state=$(pqf "$WT" "pq_get $slug state") tag=$(git -C "$BARE" tag --list) out=$OUT"
  fi
  # 4. 다음 요청 허가
  pqf "$REPO" "pq_set beta state=requested seq=99999999999999"
  pq "$REPO" next
  [[ "$RC" -eq 0 && "$(pqf "$REPO" "pq_get beta state")" == granted ]] && pass "통합 4: 복구 완료 뒤 다음 요청 next 허가" || fail "통합 4: rc=$RC out=$OUT"
}

# 공용 저장소 R 을 쓰는 사례는 순서가 있어 한 서브셸에서 차례로 돌고, 나머지는 사례마다 병렬로 돈다.
# PQ_TEST_ONLY=<함수명> 이면 그 사례만 돈다(변이 확인용).
# --- final diff review 002 보완: 대기 사유 표시·ps 실패 (F2·F3)
test_status_wait_reason() {
  local Q; Q="$(mk_repo sw)"
  mkreq "$Q" sa state=requested seq=1
  mkreq "$Q" sb state=granted seq=2
  pqf "$Q" "pq_slot_set sb"
  pq "$Q" status sa
  [[ "$OUT" == *"앞 요청 sb 가 허가됨"*"→ 앞 발행이 끝나면"* ]] && pass "status: 슬롯 점유 사유와 다음 행동" || fail "슬롯 대기 사유: $OUT"
  pqf "$Q" pq_slot_clear
  printf 'y\n' >"$Q/dirty.txt"
  pq "$Q" status sa
  [[ "$OUT" == *"기본 체크아웃에 미커밋 변경"*"→ 기본 체크아웃을 커밋"* ]] && pass "status: 기본 체크아웃 미커밋 사유와 다음 행동" || fail "미커밋 대기 사유: $OUT"
}
# ps 가 실패하는 환경(샌드박스 등)의 대역 PATH
mk_psfail() { mkdir -p "$TMP/psfail"; printf '#!/bin/sh\necho "ps: Operation not permitted" >&2\nexit 1\n' >"$TMP/psfail/ps"; chmod +x "$TMP/psfail/ps"; }
mk_psfail
test_recover_ps_fail() {
  setup_run rn17 rq
  sleep 30 & local lp=$!
  mkstate rq running "run-pid=$lp"
  OUT="$(cd "$W" && PATH="$TMP/psfail:$PATH" project_root="$W" bash "$PQ" recover rq 2>&1)"; RC=$?
  local st slot; st="$(getk rq state)"; slot="$(pqf "$W" pq_slot_get)"
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  [[ "$RC" -eq 3 && "$st" == running && "$slot" == rq ]] && pass "생존 pid 의 ps 실패 → recover 판정 불가(3), 슬롯 유지" || fail "ps 실패 recover: rc=$RC state=$st slot=$slot out=$OUT"
}
test_exec_ps_fail() {
  setup_run rn18 rr
  mkstate rr running "run-pid=$(deadpid)" run-token=T
  OUT="$(cd "$W" && PATH="$TMP/psfail:$PATH" project_root="$W" bash "$PQ" _exec rr T 2>&1)"; RC=$?
  [[ "$RC" -eq 1 && "$(logn)" == 0 && -z "$(getk rr archive-pgid)" ]] && pass "ps 실패로 pgid 가 없으면 _exec 가 archive 에 들어가지 않음" || fail "ps 실패 _exec: rc=$RC archive=$(logn) pgid=$(getk rr archive-pgid) out=$OUT"
}

SEQ_CASES="test_config_default_caller test_config_invalid_user test_config_file_without_key test_cancel_granted_releases_slot test_cancel_running_refused test_cancel_terminal_and_missing test_cancel_more_states test_status_line test_status_orders_by_seq test_corrupt_req_is_undecidable test_stale_lock_reclaimed test_stale_guard_cleared test_lock_reclaim_rechecks_pid test_lock_without_pid test_unlock_not_owner test_live_lock_blocks test_unimplemented_and_usage"
PAR_CASES="test_slot_state_must_hold test_prune_done_path_with_space test_request_user_mode test_request_no_caller test_request_preconditions test_request_auto_files_ok test_request_caller_lost test_request_duplicate_updates test_next_blocked_by_merge_head test_next_oldest_first test_next_parallel_single_grant test_next_refuses_with_corrupt test_approve_user_approval test_run_without_grant test_run_twice test_run_head_changed test_run_success test_partial_retry test_partial_reverify_keeps_slot test_recover_alive_pid test_recover_not_merged test_status_points_recover test_recover_orphan_archive test_recover_lock_owner test_exec_refused_after_recover test_exec_records_pgid_then_recover_refused test_exec_stale_token_next_generation test_exec_refused_non_running_state test_run_failed_reason_last_line test_wait_wakes_on_grant test_wait_timeout test_wait_caller_lost test_watch_on_request test_watch_on_result test_watch_result_between_watches test_real_archive_partial_recovery test_status_wait_reason test_recover_ps_fail test_exec_ps_fail"
want() { [[ -z "${PQ_TEST_ONLY:-}" || "$PQ_TEST_ONLY" == "$1" ]]; }
for t in $SEQ_CASES $PAR_CASES; do
  case " $SEQ_CASES " in *" $t "*) continue ;; esac
  want "$t" || continue
  "$t" >"$TMP/out.$t" 2>&1 &
done
(
  for t in $SEQ_CASES; do want "$t" && "$t"; done
) >"$TMP/out.0seq" 2>&1 &
wait
for f in "$TMP/out.0seq" "$TMP"/out.test_*; do [[ -f "$f" ]] && cat "$f"; done
[[ -z "${PQ_TEST_ONLY:-}" ]] && check_no_input_injection
PASS="$(grep -c '^P$' "$TMP/cnt")"; FAIL="$(grep -c '^F$' "$TMP/cnt")"

printf 'publish_queue: PASS=%d FAIL=%d (%ds)\n' "$PASS" "$FAIL" "$((SECONDS-T0))"
[[ "$FAIL" -eq 0 ]] && echo "ALL PASS"
[[ "$FAIL" -eq 0 ]]
