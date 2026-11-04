#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null; export GIT_CONFIG_SYSTEM=/dev/null
PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }

# 이 파일의 소스(_ROOT_FILES 아래)를 담고 있는 dev repo 루트를 위로 거슬러 찾는다
# (test_integration.sh setup_repo 관례). 배포본(단독 설치)에는 _ROOT_FILES 가 없으므로 skip.
PROJECT_ROOT=""
_search_dir="$SCRIPT_DIR"
while [[ "$_search_dir" != "/" ]]; do
  if [[ -d "$_search_dir/_ROOT_FILES" ]]; then PROJECT_ROOT="$_search_dir"; break; fi
  _search_dir="$(dirname "$_search_dir")"
done
if [[ -z "$PROJECT_ROOT" ]]; then
  printf '  (skip: _ROOT_FILES 없음 — 설치본 단독 환경)\n'
  exit 0
fi

TMP="$(mktemp -d)" || { echo "test_tasks_list.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_tasks_list.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# macOS: /var → /private/var 심링크. git worktree 경로 표현을 일치시키기 위해 정규화한다.
TMP="$(cd "$TMP" && pwd -P)"

# fixture: repo + worktree 2개(alpha/beta 즉시 체크아웃, gamma 는 나중에) + 각자 task-state
# 스크립트 복사는 확장자 글롭이 아니라 디렉터리 단위로 한다 — 사유는 test_integration.sh
# 의 setup_repo() 주석 참조. hook 이 읽는 `.awk` 프로그램이 조용히 빠지는 것을 막는다.
( cd "$TMP" && \
  git init -q -b main && \
  git config user.email test@example.com && \
  git config user.name test && \
  if [[ -f "$PROJECT_ROOT/_ROOT_FILES/CURRENT_TASK.md" ]]; then \
    cp "$PROJECT_ROOT/_ROOT_FILES/CURRENT_TASK.md" CURRENT_TASK.md; \
  else \
    printf '# Current Task\n\n## Short Title\n-\n\n## Status\n대기 중\n' > CURRENT_TASK.md; \
  fi && \
  if [[ -f "$PROJECT_ROOT/_ROOT_FILES/REQUEST.md" ]]; then \
    cp "$PROJECT_ROOT/_ROOT_FILES/REQUEST.md" REQUEST.md; \
  else \
    printf '# Change Request\n\n## Source FR\n-\n' > REQUEST.md; \
  fi && \
  mkdir -p rd-workflow/scripts/lifecycle rd-workflow/scripts/hooks rd-workflow-workspace/.lifecycle && \
  : > rd-workflow-workspace/.gitkeep && \
  cp -R "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/lifecycle/. rd-workflow/scripts/lifecycle/ && \
  cp -R "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/hooks/. rd-workflow/scripts/hooks/ && \
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_state_common.sh rd-workflow/scripts/ && \
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_task_common.sh rd-workflow/scripts/ && \
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_submodule_common.sh rd-workflow/scripts/ && \
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/rd rd-workflow/scripts/ && \
  git add -A && \
  git commit -q -m "init" )

cd "$TMP"
source "$SCRIPT_DIR/_tasks_index.sh"

# 1) 진행 중 작업이 없으면 그 사실을 알린다 (아직 fr 작업이 없다)
out="$(bash "$SCRIPT_DIR/tasks_list.sh" 2>&1)"
[[ "$out" == *"진행 중인 작업이 없습니다"* ]] && pass "빈 목록 안내" || fail "빈 목록"

# alpha/beta: 브랜치를 만들고 각자 커밋을 하나씩 얹은 뒤(merge-base 오판 방지) worktree
# 로 체크아웃한다. gamma 는 브랜치만 먼저 만들고(뒤에서 merge 시나리오에 쓴다) 아직
# worktree 는 만들지 않는다 — "worktree 없음" 표시 케이스로 쓴다.
git branch fr/alpha
git branch fr/beta
git branch fr/gamma
git checkout -q fr/alpha; git commit -q --allow-empty -m "alpha work"; git checkout -q main
git checkout -q fr/beta;  git commit -q --allow-empty -m "beta work";  git checkout -q main
git checkout -q fr/gamma; git commit -q --allow-empty -m "gamma work"; git checkout -q main

# 기본 브랜치를 충분히 전진시켜 alpha/beta 를 "뒤처짐" 임계(기본 20) 이상으로 만든다.
n=0
while [[ "$n" -lt 24 ]]; do
  git commit -q --allow-empty -m "main advance $n"
  n=$((n+1))
done

git worktree add -q .worktrees/alpha fr/alpha
git worktree add -q .worktrees/beta fr/beta

tasks_index_upsert alpha fr-branch=fr/alpha worktree-path="$TMP/.worktrees/alpha" checkout=yes launch=ok
tasks_index_upsert beta  fr-branch=fr/beta  worktree-path="$TMP/.worktrees/beta"  checkout=yes launch=failed
# gamma: fr 브랜치는 있지만 아직 체크아웃되지 않았다 (worktree 없음 케이스).
tasks_index_upsert gamma fr-branch=fr/gamma checkout=no

( cd .worktrees/alpha && bash rd-workflow/scripts/rd task set-status "구현 중" --force >/dev/null )
( cd .worktrees/beta  && bash rd-workflow/scripts/rd task set-status "검증 중" --force >/dev/null )

# 2) 작업 2건(+gamma)이 각자의 워크플로 단계와 함께 나온다
#    (단계는 색인이 아니라 그 worktree 의 task-state 에서 읽는다)
out="$(bash "$SCRIPT_DIR/tasks_list.sh")"
[[ "$out" == *"alpha"* && "$out" == *"beta"* ]] \
  && [[ "$out" == *"구현 중"* && "$out" == *"검증 중"* ]] \
  && pass "두 작업의 단계를 각 worktree 에서 읽는다" || fail "단계 표시"

# 3) 세션 기동 상태와 다음 행동이 함께 나온다
[[ "$out" == *"기동 실패"* || "$out" == *"failed"* ]] && pass "기동 상태 표시" || fail "기동 상태"

# 4) worktree 가 사라진 행은 표시하고 정리 명령을 붙인다
[[ "$out" == *"worktree 없음"* ]] && pass "유실 worktree 표시" || fail "유실 표시"

# gamma 를 이제 체크아웃한다 — 8b 에서 이 worktree 에 커밋해야 하기 때문이다.
git worktree add -q .worktrees/gamma fr/gamma

# 5) --rebuild 가 색인을 지운 뒤에도 목록을 복구하고, launch 를 unknown 으로 둔다
rm -f "$(tasks_index_path)"
out="$(bash "$SCRIPT_DIR/tasks_list.sh" --rebuild)"
[[ "$out" == *"alpha"* ]] && pass "--rebuild 로 복구한다" || fail "rebuild"
[[ "$out" == *"확인 필요"* ]] \
  && pass "복구된 세션 상태는 확인 필요(unknown)" || fail "rebuild 후 launch"

# 6) 뒤처진 작업에 경고가 붙는다 (임계 초과 fixture)
[[ "$out" == *"뒤처짐"* ]] && pass "묵은 작업 경고" || fail "묵음 경고"

# 7) merge 만 되고 archive tag 가 없으면 '정리 대기' 가 아니라 '발행 확인 필요' 다.
#    merge 직후 중단·수동 merge 도 ancestor 를 참으로 만들므로, merge 는 발행의 증거가 아니다.
#    여기서 삭제를 권하면 사용자가 발행하지 못한 일을 완료로 받아들인다.
git -C "$TMP" merge --no-ff -q fr/gamma -m "merge: gamma"
out="$(bash "$SCRIPT_DIR/tasks_list.sh" --rebuild)"
[[ "$out" == *"발행 확인 필요"* && "$out" == *"gamma"* ]] \
  && [[ "$out" != *"git worktree remove"* ]] \
  && pass "merge 만으로는 발행 확인 필요이며 삭제를 권하지 않는다" || fail "발행 증거 판정"

# 8) 실제 규약(fr/<시각>/<slug>)의 **annotated** tag 가 현재 fr tip 을 포함하는 commit 을 가리키면 정리 대기
#    archive.sh 는 `git tag ... -m ...` 으로 annotated tag 를 만든다. lightweight fixture 로는
#    정상 annotated tag 의 회귀(원격 조회가 tag 객체 OID 를 돌려주는 경우)를 잡지 못한다.
git -C "$TMP" tag -a "fr/20260915-2000/gamma" -m "archive: gamma" "$(git -C "$TMP" rev-parse HEAD)"
out="$(bash "$SCRIPT_DIR/tasks_list.sh" --rebuild)"
[[ "$out" == *"정리 대기"* && "$out" == *"gamma"* ]] \
  && pass "tag 계보가 맞으면 정리 대기" || fail "정리 대기 분류"

# 8b) 과거 동일 slug tag 가 남아 있고 **fr 이 더 전진해** 새 tip 을 merge 한 직후 중단한 경우
#     → 이름만 보면 tag 가 있지만 그 tag 는 이번 tip 의 발행 증거가 아니다. 삭제를 권하면 안 된다.
#     주의: 커밋은 **gamma 의 worktree 에서** 해야 fr tip 이 전진한다. 기본 브랜치에서 커밋하면
#           전진하는 것은 기본 브랜치이고 fr/gamma 는 그대로여서 이 케이스를 만들지 못한다.
old_tip="$(git -C "$TMP" rev-parse fr/gamma)"
git -C "$TMP/.worktrees/gamma" commit -q --allow-empty -m "gamma 추가 작업"
new_tip="$(git -C "$TMP" rev-parse fr/gamma)"
[[ "$old_tip" != "$new_tip" ]] || fail "fixture 전제 실패: fr/gamma 가 전진하지 않았다"
git -C "$TMP" merge-base --is-ancestor "$new_tip" "fr/20260915-2000/gamma" \
  && fail "fixture 전제 실패: 새 tip 이 이전 tag 의 조상이다"
git -C "$TMP" merge --no-ff -q fr/gamma -m "merge: gamma 2차"
out="$(bash "$SCRIPT_DIR/tasks_list.sh" --rebuild)"
[[ "$out" == *"발행 확인 필요"* ]] && [[ "$out" != *"git worktree remove"* ]] \
  && pass "과거 tag 는 새 tip 의 발행 증거가 아니다" || fail "tag 계보 검증"

# 9) 기존 cleanup-pending 행은 rebuild 가 덮어쓰지 않고 보존한다 (원격 정리만 실패한 잔여)
git -C "$TMP" branch fr/delta main   # branch 가 남은 행만 보존 대상이다 (낡은 행은 list 가 지운다)
tasks_index_upsert delta state=cleanup-pending published-at=2026-09-15-1900
bash "$SCRIPT_DIR/tasks_list.sh" --rebuild >/dev/null
[[ "$(tasks_index_get delta state)" == "cleanup-pending" ]] \
  && pass "rebuild 가 기존 정리 대기 행을 보존한다" || fail "cleanup-pending 보존"

# ---------------------------------------------------------------------------
# 낡은 정리 대기 행 정리 (A~F) — state=cleanup-pending AND fr branch 없음 AND worktree 디렉터리 없음
# ---------------------------------------------------------------------------
_has_row() { [[ -n "$(tasks_index_all_slugs | grep -x "$1" || true)" ]]; }
git -C "$TMP" branch fr/brn main
mkdir -p "$TMP/.worktrees/pthdir"
tasks_index_upsert stale1 state=cleanup-pending published-at=2026-10-01-1000
tasks_index_upsert stale2 fr-branch=fr/stale2 worktree-path="$TMP/.worktrees/gone" state=cleanup-pending
tasks_index_upsert brn state=cleanup-pending published-at=2026-10-02-1000
tasks_index_upsert pth state=cleanup-pending worktree-path="$TMP/.worktrees/pthdir"
rc=0; out="$(bash "$SCRIPT_DIR/tasks_list.sh" 2>"$TMP/err")" || rc=$?
# A1
if [[ "$rc" -eq 0 ]] && ! _has_row stale1 && ! _has_row stale2 \
   && [[ -z "$(grep -v '^정리:' <<<"$out" | grep -e stale1 -e stale2 || true)" ]]; then
  pass "A1 낡은 정리 대기 행은 색인에서 삭제되고 목록에서 빠진다"
else
  fail "A1 낡은 행이 색인에 남음 (rc=$rc)"
fi
# A2
grep -qxF '정리: 낡은 정리 대기 기록 2건 삭제 (stale1, stale2)' <<<"$out" \
  && pass "A2 정리 안내가 정확한 건수·slug 로 나온다" || fail "A2 정리 안내 없음/불일치: $(grep '^정리:' <<<"$out" || true)"
# B
if _has_row brn && [[ "$(tasks_index_get brn state)" == "cleanup-pending" ]] \
   && [[ -n "$(grep brn <<<"$out" | grep "정리 대기" || true)" ]]; then
  pass "B branch 가 남은 정리 대기 행은 보존되고 정리 대기로 표시된다"
else
  fail "B branch 가 남은 행이 삭제됨"
fi
# C
_has_row pth && pass "C worktree 디렉터리가 남은 정리 대기 행은 보존된다" || fail "C 경로가 남은 행이 삭제됨"
# F
rc=0; out="$(bash "$SCRIPT_DIR/tasks_list.sh" 2>/dev/null)" || rc=$?
if [[ "$rc" -eq 0 && -z "$(grep '^정리:' <<<"$out" || true)" ]]; then
  pass "F 삭제할 행이 없으면 정리 안내가 없다"
else
  fail "F 삭제 0건인데 정리 안내 출력"
fi
# E — 락 점유(살아 있는 pid) / owner pid 가 죽은 불확실 케이스. 색인 불변 + 목록 표시 + rc 0 + stderr 안내
_lockdir="$(tasks_shared_dir)/tasks.lock"
tasks_index_upsert stale4 state=cleanup-pending
for _mode in alive dead; do
  mkdir -p "$_lockdir"
  if [[ "$_mode" == alive ]]; then _pid=$$; else _pid=999999; fi
  printf 'pid=%s\ncmd=other\nslug=x\nstarted-at=2026-10-29-1000\n' "$_pid" > "$_lockdir/owner"
  for _opt in "" "--rebuild"; do
    _before="$(cat "$(tasks_index_path)")"
    rc=0; out="$(bash "$SCRIPT_DIR/tasks_list.sh" $_opt 2>"$TMP/err")" || rc=$?
    if [[ "$rc" -eq 0 && "$(cat "$(tasks_index_path)")" == "$_before" && "$out" == *"brn"* ]] \
       && grep -q "낡은 정리 대기 기록 정리를 건너뜀" "$TMP/err"; then
      pass "E 락 점유($_mode) 중 list ${_opt:-일반}: 색인 불변·목록 표시·rc 0·안내"
    else
      fail "E 락 점유($_mode) 중 list ${_opt:-일반}: rc=$rc 색인변경/목록/안내 확인 필요: $(cat "$TMP/err")"
    fi
  done
  rm -rf "$_lockdir"
done
# D1 — 락이 풀린 뒤 --rebuild 에서도 낡은 행이 삭제된다 (stale4)
rc=0; out="$(bash "$SCRIPT_DIR/tasks_list.sh" --rebuild 2>/dev/null)" || rc=$?
[[ "$rc" -eq 0 ]] && ! _has_row stale4 && grep -qF '정리: 낡은 정리 대기 기록 1건 삭제 (stale4)' <<<"$out" \
  && pass "D1 --rebuild 에서도 낡은 정리 대기 행이 삭제된다" || fail "D1 --rebuild 후 낡은 행이 색인에 남음 (rc=$rc)"
# D2 — rebuild 가 살아 있는 정리 대기 행의 state·published-at 을 보존한다
[[ "$(tasks_index_get brn state)" == "cleanup-pending" && "$(tasks_index_get brn published-at)" == "2026-10-02-1000" ]] \
  && pass "D2 --rebuild 가 branch 가 남은 정리 대기 행의 state·published-at 을 보존한다" \
  || fail "D2 state 가 덮어써짐: $(tasks_index_get brn state)"
# A3 — 정리 대기 stale 행만 있어 목록이 비는 저장소: 빈 안내와 정리 줄이 함께 나온다
MINI="$TMP/mini-empty"; mkdir -p "$MINI"  # $TMP 아래라 종료 trap 이 함께 지운다
( cd "$MINI" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && git commit -q --allow-empty -m init )
rc=0; out="$( cd "$MINI" && project_root="$MINI" bash -c 'source "$1/_tasks_index.sh"; tasks_index_upsert only-stale state=cleanup-pending; tasks_index_upsert only-stale2 state=cleanup-pending; bash "$1/tasks_list.sh"' _ "$SCRIPT_DIR" 2>/dev/null )" || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"진행 중인 작업이 없습니다"* ]] \
   && grep -qxF '정리: 낡은 정리 대기 기록 2건 삭제 (only-stale, only-stale2)' <<<"$out"; then
  pass "A3 목록이 비는 경우에도 빈 안내와 정리 줄이 함께 나온다"
else
  fail "A3 빈 목록에서 안내 없음 (rc=$rc): $out"
fi
rm -rf "$MINI"
for _s in stale1 stale2 brn pth; do tasks_index_remove "$_s"; done
git -C "$TMP" branch -D fr/brn >/dev/null

# ---------------------------------------------------------------------------
# set-status 대상 선택 (spec D4)
# ---------------------------------------------------------------------------
REPO="$TMP"

# 작업 worktree 안: 인자 없이 기존 사용법 그대로 동작한다 (인자를 새로 요구하지 않는다)
( cd "$REPO/.worktrees/alpha" && bash rd-workflow/scripts/rd task set-status "검증 중" ) \
  && pass "작업 worktree 안에서는 자기 작업이 기본 대상" || fail "worktree 기본 대상"

# 기본 worktree: 작업 2건이면 무변경 중단 + 목록·--task 안내
#   nonzero 와 양쪽 task-state 보존을 함께 본다 (|| true 로 종료 코드를 지우지 않는다)
before_a="$(cat "$REPO/.worktrees/alpha/rd-workflow-workspace/.lifecycle/task-state")"
before_b="$(cat "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")"
if out="$( cd "$REPO" && bash rd-workflow/scripts/rd task set-status "검증 중" 2>&1 )"; then
  fail "다건인데 대상 없는 전이가 성공했다"
else
  [[ "$out" == *"--task"* && "$out" == *"alpha"* && "$out" == *"beta"* ]] \
    && [[ "$(cat "$REPO/.worktrees/alpha/rd-workflow-workspace/.lifecycle/task-state")" == "$before_a" ]] \
    && [[ "$(cat "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")" == "$before_b" ]] \
    && pass "다건은 nonzero + 무변경 + 목록 안내" || fail "다건 중단"
fi

# 명시 대상이 현재 worktree 의 작업과 달라도 경고 후 진행한다 (관리 진입점 보존)
out="$( cd "$REPO/.worktrees/alpha" && bash rd-workflow/scripts/rd task set-status "검증 중" --task beta 2>&1 )"
rc=$?
[[ "$rc" -eq 0 ]] && [[ "$out" == *"경고"* ]] \
  && [[ "$(grep '^status=' "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")" == "status=검증 중" ]] \
  && pass "불일치 대상은 경고 후 진행" || fail "불일치 경고 진행"

# ---------------------------------------------------------------------------
# rd task resolve-launch (spec D7)
# ---------------------------------------------------------------------------
# 예약 pid 가 살아 있으면 해소하지 않는다 (현재 셸 pid 는 확실히 살아 있다)
tasks_index_upsert alpha launch=launching launch-token="2026-09-15-2000-$$"
if out="$( cd "$REPO" && bash rd-workflow/scripts/rd task resolve-launch alpha 2>&1 )"; then
  fail "살아 있는 launcher 의 예약을 해제했다"
else
  [[ "$out" == *"진행 중"* ]] && pass "살아 있는 예약은 해제하지 않는다" || fail "생존 예약"
fi

# herdr 대역 — pid 가 죽고 세션 조회가 dead/unknown 인 상황을 흉내낸다.
export HERDR_ENV=1
STUB_DEAD="$TMP/.stub-dead"; mkdir -p "$STUB_DEAD"
cat > "$STUB_DEAD/herdr" <<'EOS'
#!/usr/bin/env bash
echo '{"error":{"code":"agent_not_found","message":"agent target not found"},"id":"cli:agent:get"}' >&2
exit 1
EOS
chmod +x "$STUB_DEAD/herdr"
STUB="$STUB_DEAD"

STUB_UNKNOWN="$TMP/.stub-unknown"; mkdir -p "$STUB_UNKNOWN"
cat > "$STUB_UNKNOWN/herdr" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
chmod +x "$STUB_UNKNOWN/herdr"

# pid 가 죽고 세션 조회가 dead 면 failed 로 확정한다
tasks_index_upsert beta launch=launching launch-token="2026-09-15-2000-999999"
out="$( cd "$REPO" && PATH="$STUB:$PATH" bash rd-workflow/scripts/rd task resolve-launch beta )"
[[ "$(tasks_index_get beta launch)" == "failed" ]] \
  && pass "죽은 예약 + dead 조회는 failed 로 확정" || fail "resolve-launch 확정"

# 조회가 unknown 이면 확정하지 않고 unknown 으로 유지한다
tasks_index_upsert gamma launch=launching launch-token="2026-09-15-2000-999998"
if out="$( cd "$REPO" && PATH="$STUB_UNKNOWN:$PATH" bash rd-workflow/scripts/rd task resolve-launch gamma 2>&1 )"; then
  fail "unknown 조회인데 확정했다"
else
  [[ "$(tasks_index_get gamma launch)" == "launching" ]] \
    && pass "죽은 예약 + unknown 조회는 확정하지 않고 유지한다" || fail "resolve-launch unknown 유지"
  [[ "$out" == *"unknown"* || "$out" == *"확인"* ]] \
    && pass "unknown 은 사람이 확인하라는 안내를 낸다" || fail "resolve-launch unknown 안내"
fi

# ---------------------------------------------------------------------------
# F1·F4 (final diff review): 저장된 unknown 도 해소할 수 있어야 하고, 살아 있다고
# 확인되면 **그 자리에서 인계를 전달**해야 한다. 이전에는 launching 이 아니면 probe 도
# 하지 않고 거절해, 신뢰 승인을 마친 사용자가 archive·rollback 차단을 풀 길이 없었다.
# ---------------------------------------------------------------------------
STUB_ALIVE="$TMP/.stub-alive"; mkdir -p "$STUB_ALIVE"
cat > "$STUB_ALIVE/herdr" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_ALIVE/calls.log"
if [[ "\$1 \$2" == "agent get" ]]; then
  echo '{"result":{"agent":{"cwd":"$REPO/.worktrees/alpha"},"type":"agent_info"}}'
fi
exit 0
EOS
chmod +x "$STUB_ALIVE/herdr"
: > "$STUB_ALIVE/calls.log"

tasks_index_upsert alpha launch=unknown worktree-path="$REPO/.worktrees/alpha" checkout=yes
if out="$( cd "$REPO" && PATH="$STUB_ALIVE:$PATH" bash rd-workflow/scripts/rd task resolve-launch alpha 2>&1 )"; then
  [[ "$(tasks_index_get alpha launch)" == "ok" ]] \
    && pass "저장된 unknown 도 생존 확인으로 ok 확정된다 (마감 차단 해소, F1)" || fail "F1 unknown 해소: $(tasks_index_get alpha launch)"
else
  fail "F1: unknown 을 해소하지 못했다 — $out"
fi
# 인계 문구는 여러 줄이라 로그도 여러 줄이다 — 호출 여부와 문구 내용을 따로 본다.
if grep -q '^agent prompt alpha ' "$STUB_ALIVE/calls.log" \
  && grep -Fq "Worktree: $REPO/.worktrees/alpha" "$STUB_ALIVE/calls.log"; then
  pass "생존 확정 시 인계를 실제로 전달한다(slug·worktree 포함, F4)"
else
  fail "F4 인계 전달: [$(cat "$STUB_ALIVE/calls.log")]"
fi

# ---------------------------------------------------------------------------
# F1 잔여 (final diff review): **herdr 밖에서도** unknown 을 끝낼 수 있어야 한다.
# probe 는 herdr 가 없으면 언제나 unknown 을 내므로, 이전에는 `launch=unknown` 인 작업이
# herdr 를 한 번도 쓴 적 없는 환경에서 archive·rollback 에 영구히 막혔다(AC 8·AC 18).
#
# 해소는 **사람이 밝히는 명시적 경로 하나**(`--assume-ended`)뿐이다. 색인의 기록만으로는
# 「기동한 적 없음」과 「기록이 사라짐」을 가를 수 없어(색인이 유실되면 launch-token 도
# 함께 사라진다) 자동 확정은 살아 있는 세션 위 중복 기동을 부른다 — change spec 159행
# 「기동 기록의 부재를 세션 부재로 해석하지 않는다」(review R5). 여기서 확인하는 것은
# ① 기본 동작은 무변경 nonzero ② herdr 없는 셸에 herdr 명령을 권하지 않음
# ③ 명시 경로로는 확정되고 마감 차단이 실제로 풀림 이다.
# ---------------------------------------------------------------------------
git -C "$TMP" branch fr/legacy main
git -C "$TMP" worktree add -q "$TMP/.worktrees/legacy" fr/legacy
# 흡수가 남기는 행의 모양 — 기동 예약이 없었으므로 launch-token 이 없다.
tasks_index_upsert legacy fr-branch=fr/legacy worktree-path="$TMP/.worktrees/legacy" checkout=yes launch=unknown

if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task legacy 2>&1 )"; then
  fail "F1 사전조건: unknown 인데 rollback 이 통과했다"
else
  pass "F1 사전조건 — 기록된 unknown 은 rollback 을 막는다"
fi

# 기본 동작은 확정하지 않는다 — token 이 없어도 마찬가지다(유실과 구별할 수 없다).
if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/rd task resolve-launch legacy 2>&1 )"; then
  fail "F1: herdr 없이 unknown 을 조용히 확정했다"
else
  [[ "$(tasks_index_get legacy launch)" == "unknown" ]] \
    && pass "예약 기록이 없어도 herdr 없이는 확정하지 않는다 (F1·R5)" || fail "F1 unknown 유지 실패"
  [[ "$out" != *"herdr agent get"* ]] \
    && pass "herdr 없는 환경에서 herdr 명령을 권하지 않는다 (F1)" || fail "F1: 실행할 수 없는 herdr 명령을 안내했다"
  [[ "$out" == *"--assume-ended"* ]] \
    && pass "명시 확정 경로(--assume-ended)를 안내한다 (F1)" || fail "F1 안내 누락: $out"
fi

if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/rd task resolve-launch legacy --assume-ended 2>&1 )"; then
  [[ "$(tasks_index_get legacy launch)" == "failed" ]] \
    && pass "--assume-ended 는 사용자 확인으로 failed 확정한다 (F1)" || fail "F1 --assume-ended 확정 실패"
else
  fail "F1: --assume-ended 가 실패했다 — $out"
fi

if ( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task legacy >/dev/null 2>&1 ); then
  pass "확정 뒤 herdr 없이도 마감(rollback)까지 도달한다 (F1, AC 8·AC 18)"
else
  fail "F1: 확정했는데도 차단이 풀리지 않았다"
fi

# 예약(launch-token)이 남아 있는 unknown 도 같은 규칙이다 — token 유무로 갈리지 않는다.
git -C "$TMP" branch fr/pending main
tasks_index_upsert pending fr-branch=fr/pending checkout=no launch=unknown launch-token="2026-09-16-1200-424242"
if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/rd task resolve-launch pending 2>&1 )"; then
  fail "F1: 예약이 있는 unknown 을 herdr 없이 조용히 확정했다"
else
  [[ "$(tasks_index_get pending launch)" == "unknown" ]] \
    && pass "예약 있는 unknown 도 herdr 없이 확정하지 않는다 (F1)" || fail "F1 unknown 유지 실패(pending)"
fi

# F8 (final diff review): 세션 시작 요약도 `rd task list` 와 **같은 표시 계약**을 쓴다.
# 예전에는 session_start.sh 가 자체 case 문으로 unknown 을 「자동 기동 미수행」이라고
# 했다 — 같은 색인 값을 두고 두 화면이 서로 다른 말을 했다. 여기서는 위에서 만들어 둔
# `pending`(launch=unknown, 확정 전)이 「확인 필요」로 보이는지 확인한다.
ss_out="$( cd "$REPO" && bash rd-workflow/scripts/hooks/session_start.sh 2>&1 )" || ss_out=""
ss_row="$(printf '%s\n' "$ss_out" | grep -E '(^|[[:space:]])pending([[:space:]]|$)' || true)"
if [[ -n "$ss_row" ]]; then
  [[ "$ss_row" == *"확인 필요"* && "$ss_row" != *"자동 기동 미수행"* ]] \
    && pass "세션 시작 요약도 unknown 을 '확인 필요' 로 표시한다 (F8)" \
    || fail "F8 표시 불일치 — pending 행: '$ss_row'"
  [[ "$ss_out" == *"resolve-launch"* ]] \
    && pass "세션 시작 요약이 해소 명령(resolve-launch)으로 연결한다 (F8)" || fail "F8 다음 행동 누락: $ss_out"
else
  fail "F8: 세션 시작 요약에 pending 행이 없다 — $ss_out"
fi

if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/rd task resolve-launch pending --assume-ended 2>&1 )"; then
  [[ "$(tasks_index_get pending launch)" == "failed" ]] \
    && pass "--assume-ended 는 사용자 확인으로 failed 확정한다 (F1)" || fail "F1 --assume-ended 확정 실패"
else
  fail "F1: --assume-ended 가 실패했다 — $out"
fi

# ---------------------------------------------------------------------------
# F9 (final diff review 턴 006): `launch=ok` 도 herdr 밖에서 종료를 확정할 수 있어야 한다.
# 자동 기동에 성공해 ok 가 남은 뒤 사용자가 그 세션을 끝내고 일반 터미널로 옮기면 probe 는
# unknown 이고 rollback 의 생존 가드가 막는다. 그때 `ok` 가 resolve-launch 에서도 막히면
# 남는 길이 `--force` 뿐인데, `--force` 는 **미커밋 작업물 보호까지 함께 해제**한다 —
# 「세션 종료만 확인하고 파일 보호는 유지」하는 정상 취소 경로가 사라진다.
# ---------------------------------------------------------------------------
git -C "$TMP" branch fr/ended main
git -C "$TMP" worktree add -q "$TMP/.worktrees/ended" fr/ended
tasks_index_upsert ended fr-branch=fr/ended worktree-path="$TMP/.worktrees/ended" checkout=yes launch=ok

# 취소가 막히는 **그 화면**에 종료 확정 경로가 보여야 한다 (F9 잔여). 기능만 만들고
# 막힌 자리에 적지 않으면 사용자에게는 없는 것과 같고, 눈에 보이는 유일한 출구가
# 두 보호를 함께 해제하는 --force 가 된다.
rb_out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended 2>&1 )" || true
[[ "$rb_out" == *"resolve-launch ended --assume-ended"* ]] \
  && pass "ok/unknown 취소 거부가 종료 확정 경로를 안내한다 (F9 잔여)" || fail "F9 잔여 안내 누락: $rb_out"
[[ "$rb_out" == *"작업물 보호까지"* ]] \
  && pass "--force 가 작업물 보호까지 해제함을 그 자리에서 알린다 (F9 잔여)" || fail "F9 잔여 --force 경고 누락: $rb_out"
[[ "$rb_out" != *"종료 뒤 재시도"* ]] \
  && pass "판정 불가에서 되풀이되는 재시도를 권하지 않는다 (F9 잔여)" || fail "F9 잔여: 실패하는 재시도를 안내했다"

# 플래그 없이는 여전히 거부한다 — 그때는 해소할 것이 없다.
if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/rd task resolve-launch ended 2>&1 )"; then
  fail "F9: ok 를 플래그 없이 해소했다"
else
  [[ "$(tasks_index_get ended launch)" == "ok" ]] \
    && pass "ok 는 플래그 없이 해소하지 않는다 (F9)" || fail "F9 ok 유지 실패"
  [[ "$out" == *"--assume-ended"* ]] \
    && pass "ok 거부 메시지가 종료 확정 경로를 안내한다 (F9)" || fail "F9 ok 안내 누락: $out"
fi

if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/rd task resolve-launch ended --assume-ended 2>&1 )"; then
  [[ "$(tasks_index_get ended launch)" == "failed" ]] \
    && pass "ok + --assume-ended 는 종료로 확정된다 (F9)" || fail "F9 ok 확정 실패: $(tasks_index_get ended launch)"
else
  fail "F9: ok + --assume-ended 가 실패했다 — $out"
fi

# **미추적 파일은 표시 설정과 무관하게 dirty 로 잡혀야 한다** (F6 잔여).
# `status.showUntrackedFiles=no` 를 켠 상태에서 새 파일이 보호되는지 본다 — 이 설정을 쓰는
# 사용자에게 보호와 손실 안내가 함께 사라지던 자리다.
git -C "$TMP/.worktrees/ended" config status.showUntrackedFiles no
printf 'work in progress\n' > "$TMP/.worktrees/ended/untracked-work.txt"
if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended 2>&1 )"; then
  fail "F6 잔여: showUntrackedFiles=no 에서 미추적 작업물이 있는데 취소가 통과했다"
else
  [[ -f "$TMP/.worktrees/ended/untracked-work.txt" ]] \
    && pass "showUntrackedFiles=no 여도 미추적 작업물이 보존된다 (F6 잔여)" || fail "F6 잔여: 미추적 파일이 사라졌다"
  [[ "$out" == *"untracked-work.txt"* ]] \
    && pass "잃을 파일을 이름으로 보여준다 (F6 잔여)" || fail "F6 잔여: 손실 목록에 파일이 없다: $out"
fi

# dry-run 의 손실 목록도 같은 helper 를 쓴다 — 여기서 비어 보이면 사용자는 취소 전에
# 위험을 볼 수 없다.
dry_out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended --dry-run 2>&1 )" || true
[[ "$dry_out" == *"untracked-work.txt"* ]] \
  && pass "--dry-run 손실 목록에도 미추적 파일이 나온다 (F6 잔여)" || fail "F6 잔여 dry-run 목록: $dry_out"

# --force 로는 버릴 수 있다 — 취소 기능 자체는 살아 있다.
if out="$( cd "$REPO" && env -u HERDR_ENV -u HC_TERMINAL_ID bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended --force 2>&1 )"; then
  [[ ! -d "$TMP/.worktrees/ended" ]] \
    && pass "--force 는 미추적 작업물을 알고도 버리고 완주한다 (F6)" || fail "F6 --force 미완주"
else
  fail "F6: --force 취소가 실패했다 — $out"
fi

# ---------------------------------------------------------------------------
# F2 (final diff review): 색인의 경로는 캐시일 뿐이다. 그 경로가 실제로 등록된
# worktree 이고 HEAD 가 fr/<요청 slug> 인지 git 으로 대조하지 않으면, 경로 재사용·
# 브랜치 전환으로 낡은 행이 생겼을 때 `--task A` 가 B 를 쓰거나 지운다.
#   stale 재현: alpha 의 캐시 경로를 beta 의 worktree 로 돌린다.
# ---------------------------------------------------------------------------
tasks_index_upsert alpha launch=ok worktree-path="$REPO/.worktrees/beta" checkout=yes
beta_state_before="$(cat "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")"
if out="$( cd "$REPO" && bash rd-workflow/scripts/rd task set-status "구현 중" --task alpha 2>&1 )"; then
  fail "stale 경로로 다른 작업(beta)의 task-state 를 썼다"
else
  [[ "$(cat "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")" == "$beta_state_before" ]] \
    && pass "stale 경로 쓰기는 nonzero + 다른 작업의 task-state 보존 (F2)" || fail "F2 set-status 보호"
fi

if out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task alpha 2>&1 )"; then
  fail "stale 색인 상태에서 rollback 이 그대로 진행됐다"
else
  [[ -d "$REPO/.worktrees/beta" ]] \
    && [[ -n "$(git -C "$REPO" rev-parse --verify --quiet fr/beta)" ]] \
    && [[ "$(tasks_index_get beta fr-branch)" == "fr/beta" ]] \
    && [[ "$(cat "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")" == "$beta_state_before" ]] \
    && [[ -n "$(git -C "$REPO" rev-parse --verify --quiet fr/alpha)" ]] \
    && pass "stale 색인 rollback 은 nonzero + 다른 작업의 worktree·브랜치·색인·상태 보존 (F2)" || fail "F2 rollback 보호: $out"
fi

# --rebuild 는 이전 값을 조건으로 삼지 않고 git 대조 결과로 덮어쓴다 — 그러지 않으면
# 한 번 yes 였던 행이 영원히 yes 로 남아 stale 이 복구되지 않는다.
git -C "$TMP" branch fr/epsilon main
tasks_index_upsert epsilon fr-branch=fr/epsilon worktree-path="$REPO/.worktrees/beta" checkout=yes
bash "$SCRIPT_DIR/tasks_list.sh" --rebuild >/dev/null
[[ "$(tasks_index_get epsilon checkout)" == "none" ]] \
  && pass "--rebuild 가 stale checkout=yes 를 git 기준으로 되돌린다 (F2)" || fail "F2 rebuild 갱신: $(tasks_index_get epsilon checkout)"

# ---------------------------------------------------------------------------
# AC 4 회귀: 색인 파일은 존재하는데(worktree 기능을 써 본 저장소) 행이 0건이고,
# 기본 브랜치 worktree 에서 --task 없이 set-status 를 부르면 baseline 을 건드리지
# 않고 nonzero 로 끝나야 한다(final diff review 지적).
# ---------------------------------------------------------------------------
for _s in alpha beta gamma delta epsilon legacy pending; do tasks_index_remove "$_s"; done
[[ -z "$(tasks_index_all_slugs)" ]] || fail "fixture 전제 실패: 색인 행이 남아 있다"
before_baseline="$(cat "$REPO/rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null || printf '')"
if out="$( cd "$REPO" && bash rd-workflow/scripts/rd task set-status "구현 중" 2>&1 )"; then
  fail "색인 0건 + 기본 브랜치인데 baseline 을 대상으로 전이가 성공했다"
else
  after_baseline="$(cat "$REPO/rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null || printf '')"
  [[ "$out" == *"진행 중인 작업이 없습니다"* ]] \
    && [[ "$after_baseline" == "$before_baseline" ]] \
    && pass "색인 0건 + 기본 브랜치는 baseline 을 대상 삼지 않는다 (AC 4)" || fail "AC4 baseline 보호"
fi

# ---------------------------------------------------------------------------
# 정리 대기 행 지연 정리 (S1~S9) — 발행 증거가 있고 worktree 가 깨끗·비점유·미잠금일 때만
# worktree·로컬 브랜치·색인 행을 지운다. 하나라도 어긋나면 전부 보존하고 사유를 출력한다.
# 기본 브랜치가 main 이고 origin 이 없어 local-only 증거(merge + 계보가 맞는 tag)를 쓴다.
# ---------------------------------------------------------------------------
_SW_T0=$SECONDS
# <slug>: fr/<slug> 브랜치 + worktree + merge·tag(발행 증거) + cleanup-pending 행
_sw_mk() {
  git -C "$TMP" branch "fr/$1" main
  git -C "$TMP" worktree add -q "$TMP/.worktrees/$1" "fr/$1"
  git -C "$TMP/.worktrees/$1" commit -q --allow-empty -m "$1 work"
  git -C "$TMP" merge --no-ff -q "fr/$1" -m "merge: $1"
  git -C "$TMP" tag -a "fr/20261029-1200/$1" -m "archive: $1" "$(git -C "$TMP" rev-parse HEAD)"
  tasks_index_upsert "$1" fr-branch="fr/$1" worktree-path="$TMP/.worktrees/$1" state=cleanup-pending
}
_sw_reg() { git -C "$TMP" worktree list --porcelain | grep -qxF "worktree $TMP/.worktrees/$1"; }
_sw_br()  { git -C "$TMP" rev-parse --verify --quiet "refs/heads/fr/$1" >/dev/null; }
_sw_all_kept() { _sw_reg "$1" && _sw_br "$1" && _has_row "$1"; }
_sw_all_gone() { ! _sw_reg "$1" && ! _sw_br "$1" && ! _has_row "$1"; }
_sw_run() { bash "$SCRIPT_DIR/tasks_list.sh" 2>&1 || true; }
_sw_cleanup() {  # 보존된 fixture 를 강제로 치운다(다음 케이스에 영향 없게)
  git -C "$TMP" worktree unlock "$TMP/.worktrees/$1" 2>/dev/null || true
  git -C "$TMP" worktree remove --force "$TMP/.worktrees/$1" 2>/dev/null || true
  git -C "$TMP" branch -D "fr/$1" >/dev/null 2>&1 || true
  tasks_index_remove "$1"
}

# S1 정상 — 행이 전부 사라져 목록이 비어도 결과 줄이 출력된다
_sw_mk s1
out="$(_sw_run)"
if _sw_all_gone s1 && grep -qxF '정리됨: s1 — worktree·로컬 브랜치 제거, 색인 행 삭제' <<<"$out" \
   && [[ "$out" == *"진행 중인 작업이 없습니다"* ]]; then
  pass "S1 증거 + 깨끗한 비점유 worktree 는 worktree·브랜치·행이 모두 정리되고 줄이 나온다"
else
  fail "S1 정리 실패: $out"
fi

# S2 점유 — worktree 안에서 sleep 이 CWD 를 잡고 있으면 보존한다
_sw_mk s2
( cd "$TMP/.worktrees/s2" && exec sleep 30 ) & _sw_pid=$!
sleep 0.5
out="$(_sw_run)"
kill "$_sw_pid" 2>/dev/null || true; wait "$_sw_pid" 2>/dev/null || true
if _sw_all_kept s2 && grep -E '^정리 보류: s2 — ' <<<"$out" | grep -q '점유' \
   && grep -E '^정리 보류: s2 ' <<<"$out" | grep -q '재시도: '; then
  pass "S2 점유된 worktree 는 보존되고 점유 사유와 재시도 안내가 나온다"
else
  fail "S2 점유 보존 실패: $out"
fi
_sw_cleanup s2

# S3 tip 어긋남 — 발행 뒤 fr 브랜치에 새 커밋이 생기면 보존한다
_sw_mk s3
git -C "$TMP/.worktrees/s3" commit -q --allow-empty -m "s3 발행 뒤 추가"
out="$(_sw_run)"
if _sw_all_kept s3 && grep -E '^정리 보류: s3 — ' <<<"$out" | grep -q 'in-progress'; then
  pass "S3 발행 뒤 새 커밋이 있으면 보존되고 증거 판정값이 나온다"
else
  fail "S3 tip 어긋남 보존 실패: $out"
fi
_sw_cleanup s3

# S4 미커밋 — untracked 파일 하나여도 보존하고, git 의 거부(부분 실패)에 기대지 않는다
_sw_mk s4
printf 'wip\n' > "$TMP/.worktrees/s4/wip.txt"
out="$(_sw_run)"
if _sw_all_kept s4 && grep -E '^정리 보류: s4 — ' <<<"$out" | grep -q '미커밋' \
   && ! grep -q '^정리 부분 실패' <<<"$out"; then
  pass "S4 미커밋 파일이 있으면 보류 줄과 함께 보존되고 부분 실패는 나지 않는다"
else
  fail "S4 미커밋 보존 실패: $out"
fi
_sw_cleanup s4

# S5 재시도 — worktree 만 먼저 사라진 상태(브랜치·행 잔존)는 브랜치와 행을 지우고, 다시 돌려도 불변이다
_sw_mk s5
git -C "$TMP" worktree remove "$TMP/.worktrees/s5"
out="$(_sw_run)"
if _sw_all_gone s5 && grep -qxF '정리됨: s5 — 로컬 브랜치 제거, 색인 행 삭제' <<<"$out"; then
  pass "S5 worktree 만 먼저 제거된 행은 브랜치와 행이 정리된다"
else
  fail "S5 재시도 정리 실패: $out"
fi
_sw_before="$(cat "$(tasks_index_path)"; git -C "$TMP" for-each-ref refs/heads)"
out2="$(_sw_run)"
_sw_after="$(cat "$(tasks_index_path)"; git -C "$TMP" for-each-ref refs/heads)"
if [[ "$_sw_before" == "$_sw_after" ]] && ! grep -q '^정리' <<<"$out2"; then
  pass "S5 두 번째 실행은 출력·상태가 변하지 않는다(멱등)"
else
  fail "S5 멱등 실패: $out2"
fi

# S5b 경로 불일치 — 행의 worktree-path 가 실제 등록 경로와 다르면 보존한다
_sw_mk s5b
mkdir -p "$TMP/.worktrees/other-s5b"
tasks_index_upsert s5b worktree-path="$TMP/.worktrees/other-s5b"
out="$(_sw_run)"
if _sw_all_kept s5b && grep -E '^정리 보류: s5b — ' <<<"$out" | grep -q '경로 불일치'; then
  pass "S5b 행 경로와 등록 경로가 다르면 보존되고 경로 불일치 사유가 나온다"
else
  fail "S5b 경로 불일치 보존 실패: $out"
fi
_sw_cleanup s5b

# S7a lsof 실패 — 조회 실패는 rc 2
STUB_LSOF="$TMP/.stub-lsof"; mkdir -p "$STUB_LSOF"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_LSOF/lsof"; chmod +x "$STUB_LSOF/lsof"
rc=0; ( PATH="$STUB_LSOF:$PATH"; tasks_path_occupied "$TMP" ) || rc=$?
[[ "$rc" -eq 2 ]] && pass "S7a lsof 조회가 실패하면 점유 판정은 rc 2" || fail "S7a rc=$rc (기대 2)"

# S7b 권한 제한 — 조회는 성공했지만 살아 있는 내 계정 pid 하나가 lsof 출력에서 빠지면 rc 2
# ps·lsof 를 모두 스텁으로 고정한다 — 실제 프로세스 목록의 일시적 읽기 불가가 결과를 가리지 못하게 한다.
# 대상은 어느 프로세스의 CWD 도 아닌 빈 디렉터리다($TMP 는 이 테스트 셸의 CWD 라 점유(rc 0)로 읽힌다).
mkdir -p "$TMP/.s7b-empty"
rc=0
( sleep 30 & _spid=$!
  ps() { printf '%s %s S\n%s %s S\n' "$_spid" "$(id -u)" "$$" "$(id -u)"; }
  lsof() { printf 'p%s\nn/\n' "$$"; }
  TASKS_OCCUPIED_RETRY=0 tasks_path_occupied "$TMP/.s7b-empty"; _r=$?
  kill "$_spid" 2>/dev/null; exit "$_r" ) || rc=$?
[[ "$rc" -eq 2 ]] && pass "S7b 살아 있는 내 계정 pid 의 CWD 를 못 읽었으면 rc 2" || fail "S7b rc=$rc (기대 2)"

# S7d CWD 경로 읽기 실패 — `p<pid>` 는 있어도 `n` 줄이 오류 설명이면 읽은 것으로 치지 않아 rc 2
# 모든 pid 가 `p` 줄은 있으므로, rc 2 는 오직 경로 검증 때문에 나온다(ps·lsof 스텁 고정).
rc=0
( sleep 30 & _spid=$!
  ps() { printf '%s %s S\n' "$_spid" "$(id -u)"; }
  lsof() { printf 'p%s\nn/proc/%s/cwd (readlink: Permission denied)\n' "$_spid" "$_spid"; }
  TASKS_OCCUPIED_RETRY=0 tasks_path_occupied "$TMP/.s7b-empty"; _r=$?
  kill "$_spid" 2>/dev/null; exit "$_r" ) || rc=$?
[[ "$rc" -eq 2 ]] && pass "S7d pid 는 있으나 CWD 경로를 못 읽었으면 rc 2" || fail "S7d rc=$rc (기대 2)"

# S7e ps 실패 — 대조 근거가 없으면 비점유로 흘리지 않고 rc 2
rc=0
( ps() { return 1; }
  lsof() { printf 'p%s\nn/\n' "$$"; }
  TASKS_OCCUPIED_RETRY=0 tasks_path_occupied "$TMP/.s7b-empty" ) || rc=$?
[[ "$rc" -eq 2 ]] && pass "S7e ps 조회가 실패하면 점유 판정은 rc 2" || fail "S7e rc=$rc (기대 2)"

# S7f ps 는 성공했지만 출력이 비어 있음 — 유효한 pid 행이 없으면 대조 근거가 없으므로 rc 2
rc=0
( ps() { return 0; }
  lsof() { printf 'p%s\nn/\n' "$$"; }
  TASKS_OCCUPIED_RETRY=0 tasks_path_occupied "$TMP/.s7b-empty" ) || rc=$?
[[ "$rc" -eq 2 ]] && pass "S7f ps 출력이 비어 있으면 점유 판정은 rc 2" || fail "S7f rc=$rc (기대 2)"

# S7g·S7h 유효 uid 가 다른(setuid) 프로세스 — ps 는 실 uid 로 고르므로 VPN helper·login 같은 setuid 프로세스가
# 내 계정 행으로 들어온다. lsof 가 그 CWD 를 읽지 못해도 판정불가로 세지 않고(S7g), 읽힌 CWD 가 대상 안이면
# 유효 uid 와 관계없이 점유다(S7h). 스텁의 유효 uid 0 이 내 계정과 같아지는 root 실행에서는 건너뛴다.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  SKIP: S7g·S7h root 로 실행 중이라 유효 uid 가 다른 프로세스를 스텁으로 만들 수 없음"
else
  rc=0
  ( sleep 30 & _spid=$!
    ps() { printf '%s 0 S\n%s %s S\n' "$_spid" "$$" "$(id -u)"; }
    lsof() { printf 'p%s\nn/\n' "$$"; }
    TASKS_OCCUPIED_RETRY=0 tasks_path_occupied "$TMP/.s7b-empty"; _r=$?
    kill "$_spid" 2>/dev/null; exit "$_r" ) || rc=$?
  [[ "$rc" -eq 1 ]] && pass "S7g 유효 uid 가 다른(setuid) 프로세스의 CWD 를 못 읽어도 나머지가 대상 밖이면 rc 1" || fail "S7g rc=$rc (기대 1)"

  rc=0
  ( sleep 30 & _spid=$!
    ps() { printf '%s 0 S\n%s %s S\n' "$_spid" "$$" "$(id -u)"; }
    lsof() { printf 'p%s\nn/\np%s\nn%s\n' "$$" "$_spid" "$TMP/.s7b-empty"; }
    TASKS_OCCUPIED_RETRY=0 tasks_path_occupied "$TMP/.s7b-empty"; _r=$?
    kill "$_spid" 2>/dev/null; exit "$_r" ) || rc=$?
  [[ "$rc" -eq 0 ]] && pass "S7h 유효 uid 가 다른 프로세스라도 읽힌 CWD 가 대상 안이면 rc 0" || fail "S7h rc=$rc (기대 0)"
fi

# S7c 판정불가 보류 — lsof 가 실패하면 worktree 를 지우지 않고 다음 행동을 안내한다
_sw_mk s7c
out="$(PATH="$STUB_LSOF:$PATH" _sw_run)"
if _sw_all_kept s7c && grep -E '^정리 보류: s7c — ' <<<"$out" | grep -q '점유 판정불가' \
   && grep -E '^정리 보류: s7c ' <<<"$out" | grep -q 'lsof'; then
  pass "S7c 점유 판정불가는 보존되고 lsof 확인 안내가 나온다"
else
  fail "S7c 판정불가 보존 실패: $out"
fi
_sw_cleanup s7c

# S8 locked — git worktree lock 한 worktree 는 보존한다
_sw_mk s8
git -C "$TMP" worktree lock "$TMP/.worktrees/s8"
out="$(_sw_run)"
if _sw_all_kept s8 && grep -E '^정리 보류: s8 — ' <<<"$out" | grep -q 'locked'; then
  pass "S8 locked worktree 는 보존되고 locked 사유가 나온다"
else
  fail "S8 locked 보존 실패: $out"
fi
_sw_cleanup s8

# S9 기본 체크아웃이 아닌 worktree 에서 부른 rd task list 는 파괴적 정리를 하지 않는다
_sw_mk s9
git -C "$TMP" worktree add -q -b host-s9 "$TMP/.worktrees/host-s9"
out="$( cd "$TMP/.worktrees/host-s9" && project_root="$TMP/.worktrees/host-s9" bash "$SCRIPT_DIR/tasks_list.sh" 2>&1 || true )"
if _sw_all_kept s9 && grep -E '^정리 보류: s9 — ' <<<"$out" | grep -q '기본 체크아웃'; then
  pass "S9 기본 체크아웃이 아닌 worktree 의 목록 조회는 정리하지 않고 기본 체크아웃 안내를 낸다"
else
  fail "S9 비기본 체크아웃 보존 실패: $out"
fi
git -C "$TMP" worktree remove --force "$TMP/.worktrees/host-s9" 2>/dev/null || true
git -C "$TMP" branch -D host-s9 >/dev/null 2>&1 || true
_sw_cleanup s9

# S6 원격 — 접근할 수 없는 origin 이면 원격 증거를 확인할 수 없어 보존한다(local-only 증거는 충족)
_sw_mk s6
git -C "$TMP" remote add origin "$TMP/.no-such-origin"
out="$(_sw_run)"
git -C "$TMP" remote remove origin
if _sw_all_kept s6 && grep -E '^정리 보류: s6 — ' <<<"$out" | grep -q 'needs-verify'; then
  pass "S6 원격 증거를 확인할 수 없으면 보존되고 needs-verify 사유가 나온다"
else
  fail "S6 원격 보존 실패: $out"
fi
_sw_cleanup s6
printf '  (S1~S9 소요 %d초)\n' "$((SECONDS - _SW_T0))"

# T6·T6b — _tl_sweep_pending 은 행마다 락을 잡고 풀며, 발행 대기 표지가 살아 있으면 양보한다.
#   함수만 추출해 별도 임시 저장소에서 스텁과 함께 돌린다(이 저장소·공유 락과 무관).
T6DIR="$TMP/t6repo"; mkdir -p "$T6DIR"
git -C "$T6DIR" init -q
cat >"$TMP/t6run.sh" <<'T6EOF'
set -u
SD="$1"; MODE="$2"; export SD
cd "$3"; export project_root="$3"
source "$SD/_tasks_index.sh"
LOG="$3/events.log"; : >"$LOG"
tasks_index_upsert r1 state=cleanup-pending
tasks_index_upsert r2 state=cleanup-pending
eval "$(sed -n '/^_tl_sweep_pending() {/,/^}/p' "$SD/tasks_list.sh")"
_SWEEP_REMOVED=0; _SWEEP_NAMES=""; PRUNED_NOTE=""
_tl_note() { :; }
_probe() {
  bash -c 'source "$SD/_tasks_index.sh"; tasks_lock_acquire probe x 2>/dev/null || exit 1; tasks_lock_release; exit 0'
}
_n=0
_tl_sweep_one() {
  _n=$((_n + 1)); echo "start $_n" >>"$LOG"
  if _probe; then echo free >>"$LOG"; else echo busy >>"$LOG"; fi
  echo "end $_n" >>"$LOG"
}
eval "$(declare -f tasks_lock_release | sed '1s/tasks_lock_release/_orig_release/')"
tasks_lock_release() {
  local r=0; _orig_release || r=$?
  if _probe; then echo free_after_release >>"$LOG"; fi
  return $r
}
case "$MODE" in
  lock) ;;
  live) sleep 30 & P=$!; echo "$P" >"$(tasks_shared_dir)/archive-waiting" ;;
  dead) true & P=$!; wait "$P"; echo "$P" >"$(tasks_shared_dir)/archive-waiting" ;;
esac
_tl_sweep_pending 2>"$3/sweep.err"
echo "calls=$_n" >>"$LOG"
[[ "$MODE" == live ]] && kill "$P" 2>/dev/null
exit 0
T6EOF
bash "$TMP/t6run.sh" "$SCRIPT_DIR" lock "$T6DIR"
_ev="$(tr '\n' ',' <"$T6DIR/events.log")"
if [[ ",$_ev" != *,free,* ]]; then
  pass "T6 행 처리 중에는 락이 잡혀 있다 (probe 가 모두 busy)"
else
  fail "T6 행 처리 중 락이 비어 있음: $_ev"
fi
if [[ "$_ev" == "start 1,busy,end 1,free_after_release,start 2,busy,end 2,free_after_release,calls=2," ]]; then
  pass "T6 행 사이마다 락이 풀린다 (end 1 과 start 2 사이 해제)"
else
  fail "T6 행 단위 해제 순서가 다름: $_ev"
fi
rm -f "$T6DIR/events.log"
bash "$TMP/t6run.sh" "$SCRIPT_DIR" live "$T6DIR"
if grep -q '^calls=0$' "$T6DIR/events.log" && grep -q '양보함' "$T6DIR/sweep.err"; then
  pass "T6b 표지 pid 가 살아 있으면 정리를 양보한다 (처리 0회·양보함 문구)"
else
  fail "T6b 양보하지 않음: $(tr '\n' ',' <"$T6DIR/events.log") $(cat "$T6DIR/sweep.err")"
fi
rm -f "$T6DIR/events.log" "$T6DIR/.git/rd-workflow/archive-waiting"
bash "$TMP/t6run.sh" "$SCRIPT_DIR" dead "$T6DIR"
if grep -q '^calls=2$' "$T6DIR/events.log" && ! grep -q '양보함' "$T6DIR/sweep.err"; then
  pass "T6b 표지 pid 가 죽어 있으면 무시하고 2건 모두 처리한다"
else
  fail "T6b stale 표지를 무시하지 않음: $(tr '\n' ',' <"$T6DIR/events.log") $(cat "$T6DIR/sweep.err")"
fi

# N1 이름 줄 — herdr 에이전트 이름은 32자에서 잘린다. 잘린 slug(33자 이상)의 행에만
#    실제 이름 줄을 보여 호출 세션이 그 이름으로 herdr 를 부르게 한다. 이름은 계산값이다(herdr 미호출).
_N1_LONG="abcdefghij-abcdefghij-abcdefghij-xyz12345"
_N1_SHORT="short-name"
cd "$TMP"
# 브랜치에 커밋이 있어야 발행 확인 행이 아니라 메인 표 행(in-progress)으로 분류된다.
for _b in "$_N1_LONG" "$_N1_SHORT"; do
  git branch "fr/$_b"
  git checkout -q "fr/$_b"; git commit -q --allow-empty -m "$_b work"; git checkout -q main
done
tasks_index_upsert "$_N1_LONG" fr-branch="fr/$_N1_LONG" checkout=no launch=ok
tasks_index_upsert "$_N1_SHORT" fr-branch="fr/$_N1_SHORT" checkout=no launch=ok
n1_out="$(bash "$SCRIPT_DIR/tasks_list.sh")"
n1_cnt="$(printf '%s\n' "$n1_out" | grep -c -F '→ herdr 이름: abcdefghij-abcdefghij-abcdefghij' || true)"
[[ "$n1_cnt" == "1" ]] \
  && pass "N1 33자 이상 slug 행에 herdr 이름 줄이 1회 나온다" || fail "N1 이름 줄 횟수=$n1_cnt"
n1_cnt="$(printf '%s\n' "$n1_out" | grep -c -F 'herdr 이름' || true)"
[[ "$n1_cnt" == "1" ]] \
  && pass "N1 32자 이하 slug 행에는 herdr 이름 줄이 없다" || fail "N1 짧은 slug 에 이름 줄 있음 (전체 ${n1_cnt}줄)"
# N2 hc 로 기동한 작업(launch-backend=hc)은 hc 명령을 짚는 이름 줄을 낸다 (resume-name spec C6-6)
_N2_LONG="hclong-abcdefghij-abcdefghij-abcdefghij"
git branch "fr/$_N2_LONG"; git checkout -q "fr/$_N2_LONG"; git commit -q --allow-empty -m "n2 work"; git checkout -q main
tasks_index_upsert "$_N2_LONG" fr-branch="fr/$_N2_LONG" checkout=no launch=ok launch-backend=hc
n2_out="$(bash "$SCRIPT_DIR/tasks_list.sh")"
n2_line="$(printf '%s\n' "$n2_out" | grep -F "→ hc 세션 이름: $(bash -c 'source "$1/session_launch.sh"; session_agent_name "$2"' _ "$SCRIPT_DIR" "$_N2_LONG")" || true)"
[[ -n "$n2_line" ]] && pass "N2 hc 작업 행에 hc 세션 이름 줄" || fail "N2 hc 이름 줄 없음: $n2_out"
n1_cnt="$(printf '%s\n' "$n2_out" | grep -c -F 'herdr 이름' || true)"
[[ "$n1_cnt" == "1" ]] && pass "N2 hc 작업 행에는 herdr 이름 줄이 없다(N1 행 1줄만)" || fail "N2 herdr 이름 줄 수=$n1_cnt"
# ---------------------------------------------------------------------------
# resolve-launch 의 hc(herdr app) 갈래 (change spec D6). 기록된 launch-backend 로만 조회·인계 확인을
# 하고, 인계가 처리되기 전에는 launch 를 ok 로 바꾸지 않는다. hc 대역은 `hc get` 응답만 흉내낸다.
# ---------------------------------------------------------------------------
HCT="$TMP/.stub-hc"; mkdir -p "$HCT"
make_hc_get_stub() {  # <scenario: live-same|live-turn0|finished>
  local out
  case "$1" in
    live-same)  out='{"state":"live","cwd":"/tmp/wt","turn":1,"status":{"state":"done"}}' ;;
    live-turn0) out='{"state":"live","cwd":"/tmp/wt","turn":0,"status":null}' ;;
    finished)   out='{"state":"finished","cwd":"/tmp/wt","turn":1,"exit_code":0}' ;;
  esac
  : > "$HCT/hc.log"
  printf '%s' "$out" > "$HCT/hc.out"
  cat > "$HCT/hc" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HCT/hc.log"
cat "$HCT/hc.out"
STUBEOF
  chmod +x "$HCT/hc"
}
hc_resolve() {  # <slug> [env...] — hc 대역을 PATH 앞에 두고 resolve-launch 를 실행한다
  local slug="$1"; shift
  ( cd "$REPO" && env HERDR_ENV= "$@" PATH="$HCT:$PATH" bash rd-workflow/scripts/rd task resolve-launch "$slug" 2>&1 )
}

# 처리 전(turn=0)에는 ok 로 바꾸지 않는다
tasks_index_upsert hc1 launch=unknown launch-backend=hc worktree-path=/tmp/wt checkout=yes
make_hc_get_stub live-turn0
rc=0; out="$(hc_resolve hc1 HC_TERMINAL_ID=t6)" || rc=$?
[[ "$rc" -ne 0 && "$(tasks_index_get hc1 launch)" == "unknown" ]] \
  && pass "hc 인계 미처리는 unknown 유지" || fail "처리 전 ok 확정: rc=$rc launch=$(tasks_index_get hc1 launch)"
[[ "$out" == *"붙여 넣지 마십시오"* ]] \
  && pass "hc 인계 미처리는 붙여 넣지 말라는 안내를 낸다" || fail "hc 미처리 안내 누락: $out"
# 처리됨
make_hc_get_stub live-same
rc=0; out="$(hc_resolve hc1 HC_TERMINAL_ID=t6)" || rc=$?
[[ "$rc" -eq 0 && "$(tasks_index_get hc1 launch)" == "ok" ]] \
  && pass "hc 인계 처리 확인 뒤 launch=ok" || fail "hc 처리 확인 뒤 ok 아님: rc=$rc launch=$(tasks_index_get hc1 launch) out=$out"
grep -q 'send' "$HCT/hc.log" && fail "hc send 호출됨" || pass "hc resolve 는 hc send 를 부르지 않는다"
# 세션 종료
tasks_index_upsert hc1 launch=unknown
make_hc_get_stub finished
rc=0; out="$(hc_resolve hc1 HC_TERMINAL_ID=t6)" || rc=$?
[[ "$(tasks_index_get hc1 launch)" == "failed" ]] \
  && pass "hc 세션 종료는 launch=failed" || fail "hc 종료 failed 아님: $(tasks_index_get hc1 launch)"
# 기록된 hc 인데 이 셸에서 hc 를 쓸 수 없음
tasks_index_upsert hc1 launch=unknown
make_hc_get_stub live-same
rc=0; out="$(hc_resolve hc1 HC_TERMINAL_ID=)" || rc=$?
[[ "$rc" -ne 0 && "$(tasks_index_get hc1 launch)" == "unknown" ]] \
  && pass "기록 hc + HC_TERMINAL_ID 없음 → unknown 유지" || fail "기록된 백엔드 무시: rc=$rc launch=$(tasks_index_get hc1 launch)"
[[ "$out" == *"herdr app 에서 기동했습니다"* && "$out" == *"--assume-ended"* ]] \
  && pass "hc 사용 불가 안내에 기동 환경과 --assume-ended 가 있다" || fail "기동 환경 안내 누락: $out"
# Review Focus 5 — launch-backend 없는 행(레거시)은 herdr 로 본다. hc 환경이어도 hc 를 부르지 않는다
tasks_index_upsert hc2 launch=unknown worktree-path=/tmp/wt checkout=yes
make_hc_get_stub live-same
rc=0; out="$(hc_resolve hc2 HC_TERMINAL_ID=t6)" || rc=$?
[[ "$rc" -ne 0 && "$(tasks_index_get hc2 launch)" == "unknown" ]] \
  && pass "레거시 행은 herdr 로 보고 unknown 유지" || fail "기록된 백엔드 무시: 레거시 행 rc=$rc launch=$(tasks_index_get hc2 launch)"
[[ "$out" == *"터미널 herdr 에서 기동했습니다"* && ! -s "$HCT/hc.log" ]] \
  && pass "레거시 행은 hc 를 부르지 않고 터미널 herdr 안내를 낸다" || fail "레거시 행 hc 조회: log=$(cat "$HCT/hc.log") out=$out"

# ---------------------------------------------------------------------------
# publish-queue-tab-close Task 8 — 지연 정리의 탭 닫기, 큐 요약 줄, rd publish 디스패치
#   가짜 herdr 는 TB 의 파일로 응답을 정하고 호출을 남긴다. 점유 대역 프로세스는 사례 끝에 반드시 정리한다.
# ---------------------------------------------------------------------------
TB="$TMP/tb"; mkdir -p "$TB/bin"
tb_stub() {  # <agents-json-array 내용>
  : > "$TB/calls.log"; rm -f "$TB/holder.pid"
  printf '{"id":"cli:tab:get","result":{"tab":{"label":"%s","tab_id":"wX:t9"},"type":"tab_info"}}' "$2" > "$TB/tabget.out"
  printf '{"id":"cli:agent:list","result":{"agents":[%s]}}' "$1" > "$TB/list.out"
  cat > "$TB/bin/herdr" <<TBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TB/calls.log"
case "\$1 \$2" in
  "tab get") cat "$TB/tabget.out" ;;
  "agent list") cat "$TB/list.out" ;;
  "tab close") [[ -f "$TB/holder.pid" ]] && kill "\$(cat "$TB/holder.pid")" 2>/dev/null; exit 0 ;;
esac
TBEOF
  chmod +x "$TB/bin/herdr"
}
tb_holder() {  # <slug> — worktree 를 cwd 로 잡는 대역 프로세스(탭 셸 흉내)
  ( cd "$TMP/.worktrees/$1" && exec sleep 30 ) & TB_PID=$!; disown "$TB_PID" 2>/dev/null || true
  echo "$TB_PID" > "$TB/holder.pid"
  sleep 0.5
}
tb_holder_stop() { kill "${TB_PID:-0}" 2>/dev/null || true; wait "${TB_PID:-0}" 2>/dev/null || true; TB_PID=""; }
tb_run() { PATH="$TB/bin:$PATH" bash "$SCRIPT_DIR/tasks_list.sh" 2>&1 || true; }

# test_sweep_closes_ended_tab: 에이전트가 없고 탭 셸이 worktree 를 점유 → 탭을 닫고 정리한다
_sw_mk tb1
tasks_index_upsert tb1 launch-backend=herdr launch-tab=wX:t9
tb_stub "" tb1; tb_holder tb1
out="$(tb_run)"
tb_holder_stop
if _sw_all_gone tb1 && grep -qxF '탭 닫음: tb1' <<<"$out" && grep -q '^tab close' "$TB/calls.log"; then
  pass "끝난 세션의 탭을 닫고 점유가 풀리면 정리한다"
else
  fail "탭 닫기 후 정리 실패: $out"
fi
_sw_cleanup tb1

# test_sweep_keeps_live_tab: 에이전트가 살아 있으면 닫지 않고 보류, 사유에 탭 사정이 붙는다
_sw_mk tb2
tasks_index_upsert tb2 launch-backend=herdr launch-tab=wX:t9
tb_stub '{"pane_id":"p1","tab_id":"wX:t9","name":"n","agent_status":"working"}' tb2; tb_holder tb2
out="$(tb_run)"
tb_holder_stop
if _sw_all_kept tb2 && grep -E '^정리 보류: tb2 — ' <<<"$out" | grep -q '점유 — 세션이 .* 안에 있음 (탭: 세션이 살아 있음)' \
   && ! grep -q '^tab close' "$TB/calls.log"; then
  pass "살아 있는 세션의 탭은 닫지 않고 보류 사유에 탭 사정을 덧붙인다"
else
  fail "살아 있는 탭 보류 실패 (tab close 호출 $(grep -c '^tab close' "$TB/calls.log")회): $out"
fi
_sw_cleanup tb2

# 비점유 worktree 에서는 탭 닫기를 부르지 않는다(herdr 조회 자체가 없다)
_sw_mk tb3
tasks_index_upsert tb3 launch-backend=herdr launch-tab=wX:t9
tb_stub "" tb3
out="$(tb_run)"
if _sw_all_gone tb3 && [[ ! -s "$TB/calls.log" ]]; then
  pass "비점유 worktree 는 herdr 를 호출하지 않고 정리한다"
else
  fail "비점유인데 herdr 호출: $(cat "$TB/calls.log") / $out"
fi
_sw_cleanup tb3

# test_list_shows_queue_summary: 요청 1 + done 1 + 슬롯 없음 → 「요청 1 · 허가 없음」, 요청이 없으면 줄이 없다
out="$(bash "$SCRIPT_DIR/tasks_list.sh" 2>&1 || true)"
[[ "$out" != *"발행 큐:"* ]] && pass "큐 디렉터리가 없으면 요약 줄을 내지 않는다" || fail "큐 없는데 요약 줄: $out"
_qd="$(git -C "$TMP" rev-parse --path-format=absolute --git-common-dir)/rd-workflow/publish-queue"
mkdir -p "$_qd"
printf 'state=done\n' > "$_qd/q-done.req"
out="$(bash "$SCRIPT_DIR/tasks_list.sh" 2>&1 || true)"
[[ "$out" != *"발행 큐:"* ]] && pass "done 만 있으면 요약 줄을 내지 않는다" || fail "done 만인데 요약 줄: $out"
printf 'state=requested\n' > "$_qd/q-req.req"
out="$(bash "$SCRIPT_DIR/tasks_list.sh" 2>&1 || true)"
grep -qxF '발행 큐: 요청 1 · 허가 없음' <<<"$out" && pass "요청 1·done 1·슬롯 없음 → 요청 1 · 허가 없음" || fail "큐 요약: $out"
printf 'state=user-approval\n' > "$_qd/q-ua.req"; printf 'q-ua\n' > "$_qd/ACTIVE"
out="$(bash "$SCRIPT_DIR/tasks_list.sh" 2>&1 || true)"
grep -qxF '발행 큐: 요청 2 · 허가 q-ua' <<<"$out" && pass "user-approval 도 세고 허가 슬롯 slug 를 보인다" || fail "큐 요약 2: $out"
rm -rf "$_qd"

# test_rd_publish_dispatch: rd publish <하위 명령> 이 publish_queue.sh 와 같은 결과·종료 코드를 낸다
_d_rc=0; _d_rd="$(cd "$TMP" && bash rd-workflow/scripts/rd publish status 2>&1)" || _d_rc=$?
_d_pqrc=0; _d_pq="$(cd "$TMP" && bash rd-workflow/scripts/lifecycle/publish_queue.sh status 2>&1)" || _d_pqrc=$?
[[ "$_d_rd" == "$_d_pq" && "$_d_rc" == "$_d_pqrc" && "$_d_rd" != *"알 수 없는 명령"* && "$_d_rd" != *"사용법: bash rd-workflow/scripts/rd task"* ]] \
  && pass "rd publish status 가 publish_queue.sh status 와 같다" || fail "rd publish 디스패치: rd=[$_d_rd]/$_d_rc pq=[$_d_pq]/$_d_pqrc"
_d_rc=0; ( cd "$TMP" && bash rd-workflow/scripts/rd publish no-such-sub >/dev/null 2>&1 ) || _d_rc=$?
_d_pqrc=0; ( cd "$TMP" && bash rd-workflow/scripts/lifecycle/publish_queue.sh no-such-sub >/dev/null 2>&1 ) || _d_pqrc=$?
[[ "$_d_rc" == "$_d_pqrc" ]] && pass "rd publish 는 하위 명령의 종료 코드를 그대로 돌려준다" || fail "종료 코드 불일치: rd=$_d_rc pq=$_d_pqrc"
rm -rf "$(git -C "$TMP" rev-parse --path-format=absolute --git-common-dir)/rd-workflow/publish-queue"

printf 'tasks_list: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
