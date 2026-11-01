#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }

TMP="$(mktemp -d)" || { echo "test_tasks_index.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_tasks_index.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# macOS 는 /var -> /private/var 심링크다. mktemp 가 돌려주는 $TMP 는 심링크를 통과한
# 경로이지만, git rev-parse --path-format=absolute 는 실경로(canonical path)를
# 돌려준다. 이 한 줄로 $TMP 자체를 실경로로 맞춰야 아래 접두사 비교가 같은 표현을
# 비교한다 — 비교 로직을 느슨하게 바꾸는 것이 아니라 두 경로 표현을 정규화하는 것이다.
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/rd-workflow-workspace/.lifecycle"
git -C "$TMP" init -q
# fixture 자체의 identity. GIT_CONFIG_GLOBAL=/dev/null 로 전역을 비웠으므로, 이것이 없으면
# 개발자 전역 설정이 있는 머신에서만 commit 이 통과한다.
git -C "$TMP" config user.name "rd-test"
git -C "$TMP" config user.email "rd-test@example.invalid"
export project_root="$TMP"
# tasks_shared_dir 는 `project_root` 의 저장소를 조회한다(아래 10번 회귀). cwd 도 함께
# 맞춰 두어 두 값이 갈리지 않게 한다 — 이 스위트의 다른 케이스는 그 구분을 시험하지 않는다.
cd "$TMP"
source "$SCRIPT_DIR/_tasks_index.sh"
[[ "$(tasks_shared_dir)" == "$TMP"/* ]] \
  || { printf '  FAIL: 공유 위치가 임시 저장소 밖을 가리킨다: %s\n' "$(tasks_shared_dir)" >&2; exit 1; }

# 1) upsert → get
tasks_index_upsert alpha fr-branch=fr/alpha worktree-path=/tmp/a launch=none
[[ "$(tasks_index_get alpha fr-branch)" == "fr/alpha" ]] \
  && pass "upsert 후 get 이 값을 돌려준다" || fail "upsert/get"

# 2) upsert 재호출은 같은 slug 의 행을 늘리지 않고 갱신한다
tasks_index_upsert alpha launch=ok
[[ "$(tasks_index_get alpha launch)" == "ok" ]] \
  && [[ "$(tasks_index_slugs | grep -c '^alpha$')" == "1" ]] \
  && pass "재 upsert 는 행을 늘리지 않고 갱신한다" || fail "upsert 갱신"

# 3) 다른 slug 는 서로 영향을 주지 않는다
tasks_index_upsert beta fr-branch=fr/beta launch=none
[[ "$(tasks_index_get alpha launch)" == "ok" ]] \
  && [[ "$(tasks_index_get beta launch)" == "none" ]] \
  && pass "행끼리 독립이다" || fail "행 독립성"

# 4) remove 는 그 행만 지운다
tasks_index_remove alpha
[[ -z "$(tasks_index_get alpha fr-branch || true)" ]] \
  && [[ "$(tasks_index_get beta fr-branch)" == "fr/beta" ]] \
  && pass "remove 는 대상 행만 지운다" || fail "remove"

# 5) 락: 획득 후 재획득은 실패하고 점유자 정보를 낸다
tasks_lock_acquire promote beta && pass "락 획득" || fail "락 획득"
if tasks_lock_acquire archive gamma 2>"$TMP/err"; then
  fail "점유 중인데 락이 두 번 잡혔다"
else
  grep -q "beta" "$TMP/err" && pass "점유 실패 시 점유자 정보를 낸다" || fail "점유자 정보"
fi

# 6) 해제 후에는 다시 획득된다
tasks_lock_release
tasks_lock_acquire archive gamma && pass "해제 후 재획득" || fail "해제 후 재획득"
tasks_lock_release

# 7) 죽은 pid 의 락은 "불확실" 로 보고 중단하며, 회수 명령을 안내한다 (자동 회수하지 않는다)
#    주의: 락 획득은 반드시 **현재 셸에서** 한다. 서브셸·파이프 안에서 잡으면 $$ 가
#    살아 있어 판정이 뒤집힌다.
mkdir -p "$(tasks_shared_dir)/tasks.lock"
printf 'pid=999999\ncmd=promote\nslug=dead\nstarted-at=2026-01-01-0000\n' \
  > "$(tasks_shared_dir)/tasks.lock/owner"
if tasks_lock_acquire promote delta 2>"$TMP/err2"; then
  fail "죽은 pid 락을 자동 회수해 버렸다 (남의 새 락을 지울 수 있는 경로)"
else
  grep -q "rm -rf" "$TMP/err2" && grep -q "dead" "$TMP/err2" \
    && pass "불확실한 락은 중단하고 회수 명령을 안내한다" || fail "회수 안내"
fi
rm -rf "$(tasks_shared_dir)/tasks.lock"

# 8) owner 가 없는 락(mkdir 직후 중단)도 같은 "불확실" 로 다룬다
mkdir -p "$(tasks_shared_dir)/tasks.lock"
if tasks_lock_acquire promote delta 2>/dev/null; then
  fail "owner 부재 락을 그냥 가져갔다"
else
  pass "owner 부재 락도 중단한다"
fi
rm -rf "$(tasks_shared_dir)/tasks.lock"

# 9) 공유 위치는 브랜치 체크아웃과 무관하다
before="$(tasks_index_path)"
git -C "$TMP" commit -q --allow-empty -m init
git -C "$TMP" checkout -q -b other
[[ "$(tasks_index_path)" == "$before" ]] \
  && pass "브랜치를 바꿔도 공유 위치가 같다" || fail "공유 위치 불변"

# 10) 공유 위치는 **cwd 가 아니라 project_root** 를 따른다 (final diff review)
#     `rd` 는 promote.sh·promote_rollback.sh 와 달리 `cd "$project_root"` 를 하지 않으므로,
#     이 구분이 깨지면 다른 저장소 안에서 부른 `rd task ...` 가 **그 저장소의 색인에 쓴다.**
#     실제로 이 프로젝트의 테스트가 개발자의 실제 저장소 색인에 행을 남긴 사고가 있었다.
OTHER="$(mktemp -d)" || { echo "test_tasks_index.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$OTHER" && -d "$OTHER" ]] || { echo "test_tasks_index.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
OTHER="$(cd "$OTHER" && pwd -P)"
git -C "$OTHER" init -q
(
  cd "$OTHER"                      # ← cwd 는 남의 저장소, project_root 는 $TMP 그대로
  [[ "$(tasks_shared_dir)" == "$TMP"/* ]] || exit 1
  tasks_index_upsert crosscheck fr-branch=fr/crosscheck
) && [[ "$(tasks_index_get crosscheck fr-branch)" == "fr/crosscheck" ]] \
  && pass "공유 위치는 cwd 가 아니라 project_root 를 따른다" || fail "cwd 의 저장소를 색인 대상으로 삼았다"
[[ ! -e "$OTHER/.git/rd-workflow" ]] \
  && pass "cwd 쪽 저장소에는 아무것도 만들지 않는다" || fail "남의 저장소에 .git/rd-workflow 를 만들었다"
rm -rf "$OTHER"

# 11) 정리 대기 행은 진행 중 목록(tasks_index_slugs)에서 빠지고 전체 목록(tasks_index_all_slugs)에는 남는다
tasks_index_upsert live-row fr-branch=fr/live-row launch=ok
tasks_index_upsert pend-row fr-branch=fr/pend-row state=cleanup-pending published-at=2026-10-29-1000
tasks_index_upsert pend-mid state=cleanup-pending
tasks_index_upsert pend-first fr-branch=fr/pend-first
tasks_index_upsert pend-first state=cleanup-pending
_in_progress="$(tasks_index_slugs)"; _all="$(tasks_index_all_slugs)"
if [[ "$_in_progress" == *pend-* ]]; then
  fail "T1a 정리 대기 행이 진행 중 목록에 포함됨"
elif [[ "$_in_progress" == *live-row* ]]; then
  pass "T1a 정리 대기 행은 진행 중 목록에서 제외되고 진행 중 행은 남는다"
else
  fail "T1a 진행 중 행이 진행 중 목록에서 빠짐"
fi
if [[ "$_all" == *live-row* && "$_all" == *pend-row* && "$_all" == *pend-mid* && "$_all" == *pend-first* ]]; then
  pass "T1b 전체 목록에는 정리 대기 행과 진행 중 행이 모두 있다"
else
  fail "T1b 전체 목록에 정리 대기 행 없음"
fi

# 12) tasks_lock_acquire_wait — 점유자가 wait_for_cmd 일 때만 한정 대기한다 (T4~T5c).
#     보유자·대기 호출자는 각각 별도 `bash -c` 프로세스다(서브셸은 $$ 가 부모와 같아 소유자
#     판정이 흐려진다). 동기화는 신호 파일 + 0.1초 폴링 최대 200회(외부 상한)로만 하고
#     시간 단언은 쓰지 않는다. 상한을 넘기면 그 케이스는 FAIL 이다.
SYNC="$TMP/sync"; mkdir -p "$SYNC"
_LOCKDIR="$(tasks_shared_dir)/tasks.lock"
_MARKER="$(tasks_shared_dir)/archive-waiting"
_wait_file() {  # <path>
  local i=0
  while [[ ! -e "$1" ]]; do
    i=$((i + 1)); [[ "$i" -gt 200 ]] && return 1
    sleep 0.1
  done
  return 0
}
_wait_grep() {  # <pattern> <file>
  local i=0
  while ! grep -q -- "$1" "$2" 2>/dev/null; do
    i=$((i + 1)); [[ "$i" -gt 200 ]] && return 1
    sleep 0.1
  done
  return 0
}
_H_PID=""; _W_PID=""
_h_start() {  # <cmd> — 락을 쥐고 held 를 쓴 뒤 release 를 기다린다. swap 파일이 생기면 락을 쥔 채 cmd 를 promote 로 바꾼다
  rm -rf "$_LOCKDIR" "$_MARKER"; rm -f "$SYNC"/*
  bash -c '
    source "$1/_tasks_index.sh"; sd="$3"
    tasks_lock_acquire "$2" - || exit 9
    : >"$sd/held"
    i=0
    while [[ ! -e "$sd/release" && $i -lt 300 ]]; do
      if [[ -e "$sd/swap" && ! -e "$sd/swapped" ]]; then
        printf "pid=%s\ncmd=promote\nslug=-\nstarted-at=x\n" "$$" >"$(tasks_shared_dir)/tasks.lock/owner"
        : >"$sd/swapped"
      fi
      sleep 0.1; i=$((i + 1))
    done
    tasks_lock_release
  ' _ "$SCRIPT_DIR" "$1" "$SYNC" &
  _H_PID=$!
  _wait_file "$SYNC/held"
}
_h_stop() {
  : >"$SYNC/release"
  wait "$_H_PID" 2>/dev/null || true
}
_w_start() {  # <max 또는 빈값> — 대기 호출자. 종료코드를 $SYNC/w.rc, stderr 를 $SYNC/w.err 에 남긴다
  rm -f "$SYNC/w.rc" "$SYNC/w.err"
  bash -c '
    source "$1/_tasks_index.sh"
    tasks_lock_acquire_wait archive s tasks-list-prune ${2:+"$2"} 2>"$3.err"
    rc=$?
    tasks_lock_release || true
    echo "$rc" >"$3.rc"
  ' _ "$SCRIPT_DIR" "$1" "$SYNC/w" &
  _W_PID=$!
}
_w_await() {  # 외부 상한 안에 끝나지 않으면 죽이고 실패
  if _wait_file "$SYNC/w.rc"; then wait "$_W_PID" 2>/dev/null || true; return 0; fi
  kill "$_W_PID" 2>/dev/null || true; wait "$_W_PID" 2>/dev/null || true
  return 1
}

# T4 점유자가 tasks-list-prune 이면 기다렸다가 풀리면 이어간다 (+ T4d 대기 중에는 표지가 있다)
_h_start tasks-list-prune
_w_start 20
_wait_grep '락 대기' "$SYNC/w.err" || fail "T4 대기 문구가 나오지 않음"
_t4d=0; [[ -f "$_MARKER" && "$(cat "$_MARKER")" == "$_W_PID" ]] && _t4d=1
: >"$SYNC/release"
if _w_await && [[ "$(cat "$SYNC/w.rc")" == "0" ]] && grep -q '락을 얻어 이어갑니다' "$SYNC/w.err"; then
  pass "T4 tasks-list-prune 점유를 기다렸다가 풀리면 획득하고 재개 문구를 낸다"
else
  fail "T4 대기 후 획득 실패 (rc=$(cat "$SYNC/w.rc" 2>/dev/null) err=$(cat "$SYNC/w.err" 2>/dev/null))"
fi
[[ "$_t4d" -eq 1 ]] && pass "T4d 대기 중에는 표지 파일에 대기자 pid 가 있다" || fail "T4d 대기 중 표지가 없거나 pid 가 다르다"
[[ ! -e "$_MARKER" ]] && pass "T4c 획득 경로 반환 뒤 표지가 남지 않는다" || fail "T4c 획득 경로에 표지가 남음"
_h_stop

# T4b 상한 환경변수가 무효이면 경고하고 60초를 쓴다
rm -rf "$_LOCKDIR" "$_MARKER"; rm -f "$SYNC"/*
# _w_start 는 max 빈값이면 인자를 생략한다 — 환경변수만 본다
RD_ARCHIVE_LOCK_WAIT_MAX=abc _w_start ""
wait "$_W_PID" 2>/dev/null || true
grep -q '값이 올바르지 않아 60초' "$SYNC/w.err" \
  && pass "T4b 무효 RD_ARCHIVE_LOCK_WAIT_MAX 는 경고 뒤 60초를 쓴다" || fail "T4b 경고 없음: $(cat "$SYNC/w.err" 2>/dev/null)"

# T4e 선행 0 이 있는 상한(`08`)을 8진수로 읽지 않고 십진수 8초로 쓴다 (bash 산술은 08 을 오류로 본다)
_h_start tasks-list-prune
RD_ARCHIVE_LOCK_WAIT_MAX=08 _w_start ""
_wait_grep '락 대기' "$SYNC/w.err" || fail "T4e 대기 문구가 나오지 않음"
: >"$SYNC/release"
_w_await || true
if [[ "$(cat "$SYNC/w.rc" 2>/dev/null)" == "0" ]] && grep -q '상한 8초' "$SYNC/w.err" && ! grep -q 'value too great\|too great for base' "$SYNC/w.err"; then
  pass "T4e 선행 0 상한(08)을 십진수 8초로 정규화한다"
else
  fail "T4e 선행 0 상한 처리 오류 (rc=$(cat "$SYNC/w.rc" 2>/dev/null) err=$(cat "$SYNC/w.err" 2>/dev/null))"
fi
_h_stop

# T5 다른 점유자(promote)는 기다리지 않고 즉시 중단한다 — 상한 3초는 변이 시 걸림을 제한할 뿐이다
_h_start promote
_w_start 3
if _w_await && [[ "$(cat "$SYNC/w.rc")" == "1" ]] \
   && grep -q '락이 이미 점유 중입니다' "$SYNC/w.err" && ! grep -q '락 대기' "$SYNC/w.err"; then
  pass "T5 점유자가 promote 이면 대기 없이 rc=1 과 점유 안내를 낸다"
else
  fail "T5 다른 점유자를 기다림 (rc=$(cat "$SYNC/w.rc" 2>/dev/null) err=$(cat "$SYNC/w.err" 2>/dev/null))"
fi
_h_stop

# T5b 대기 중 점유자가 다른 명령으로 바뀌면 즉시 중단한다 (보유자가 락을 쥔 채 cmd 만 교체 — 결정적)
_h_start tasks-list-prune
_w_start 60   # 외부 상한(20초)보다 길게 — 재확인이 없으면 외부 상한이 FAIL 로 판정한다
_wait_grep '락 대기' "$SYNC/w.err" || fail "T5b 대기 문구가 나오지 않음"
: >"$SYNC/swap"
_wait_file "$SYNC/swapped" || fail "T5b 점유자 교체가 일어나지 않음"
if _w_await && [[ "$(cat "$SYNC/w.rc")" == "1" ]] \
   && grep -q 'cmd=promote' "$SYNC/w.err" && ! grep -q '대기 .*초 후 중단' "$SYNC/w.err"; then
  pass "T5b 대기 중 점유자가 바뀌면 상한 전에 점유 안내와 함께 중단한다"
else
  fail "T5b 점유자 교체 후에도 계속 기다림 (rc=$(cat "$SYNC/w.rc" 2>/dev/null) err=$(cat "$SYNC/w.err" 2>/dev/null))"
fi
_h_stop

# T5c 상한을 넘기면 중단한다 (+ T4c 중단 경로 뒤에도 표지가 남지 않는다)
_h_start tasks-list-prune
_w_start 1
if _w_await && [[ "$(cat "$SYNC/w.rc")" == "1" ]] && grep -q '락 대기 1초 후 중단' "$SYNC/w.err"; then
  pass "T5c 상한(1초)을 넘기면 rc=1 과 중단 문구를 낸다"
else
  fail "T5c 상한을 지키지 않음 (rc=$(cat "$SYNC/w.rc" 2>/dev/null) err=$(cat "$SYNC/w.err" 2>/dev/null))"
fi
[[ ! -e "$_MARKER" ]] && pass "T4c 중단 경로 반환 뒤에도 표지가 남지 않는다" || fail "T4c 중단 경로에 표지가 남음"
_h_stop
rm -rf "$_LOCKDIR" "$_MARKER"

printf 'tasks_index: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
