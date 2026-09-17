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
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/lifecycle/*.sh rd-workflow/scripts/lifecycle/ && \
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/hooks/*.sh rd-workflow/scripts/hooks/ && \
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_state_common.sh rd-workflow/scripts/ && \
  cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_task_common.sh rd-workflow/scripts/ && \
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
tasks_index_upsert delta state=cleanup-pending published-at=2026-09-15-1900
bash "$SCRIPT_DIR/tasks_list.sh" --rebuild >/dev/null
[[ "$(tasks_index_get delta state)" == "cleanup-pending" ]] \
  && pass "rebuild 가 기존 정리 대기 행을 보존한다" || fail "cleanup-pending 보존"

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
echo '{"result":{"agents":[]}}'
exit 0
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
  echo '{"result":{"agents":[{"cwd":"$REPO/.worktrees/alpha"}]}}'
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

if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task legacy 2>&1 )"; then
  fail "F1 사전조건: unknown 인데 rollback 이 통과했다"
else
  pass "F1 사전조건 — 기록된 unknown 은 rollback 을 막는다"
fi

# 기본 동작은 확정하지 않는다 — token 이 없어도 마찬가지다(유실과 구별할 수 없다).
if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/rd task resolve-launch legacy 2>&1 )"; then
  fail "F1: herdr 없이 unknown 을 조용히 확정했다"
else
  [[ "$(tasks_index_get legacy launch)" == "unknown" ]] \
    && pass "예약 기록이 없어도 herdr 없이는 확정하지 않는다 (F1·R5)" || fail "F1 unknown 유지 실패"
  [[ "$out" != *"herdr agent get"* ]] \
    && pass "herdr 없는 환경에서 herdr 명령을 권하지 않는다 (F1)" || fail "F1: 실행할 수 없는 herdr 명령을 안내했다"
  [[ "$out" == *"--assume-ended"* ]] \
    && pass "명시 확정 경로(--assume-ended)를 안내한다 (F1)" || fail "F1 안내 누락: $out"
fi

if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/rd task resolve-launch legacy --assume-ended 2>&1 )"; then
  [[ "$(tasks_index_get legacy launch)" == "failed" ]] \
    && pass "--assume-ended 는 사용자 확인으로 failed 확정한다 (F1)" || fail "F1 --assume-ended 확정 실패"
else
  fail "F1: --assume-ended 가 실패했다 — $out"
fi

if ( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task legacy >/dev/null 2>&1 ); then
  pass "확정 뒤 herdr 없이도 마감(rollback)까지 도달한다 (F1, AC 8·AC 18)"
else
  fail "F1: 확정했는데도 차단이 풀리지 않았다"
fi

# 예약(launch-token)이 남아 있는 unknown 도 같은 규칙이다 — token 유무로 갈리지 않는다.
git -C "$TMP" branch fr/pending main
tasks_index_upsert pending fr-branch=fr/pending checkout=no launch=unknown launch-token="2026-09-16-1200-424242"
if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/rd task resolve-launch pending 2>&1 )"; then
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

if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/rd task resolve-launch pending --assume-ended 2>&1 )"; then
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
rb_out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended 2>&1 )" || true
[[ "$rb_out" == *"resolve-launch ended --assume-ended"* ]] \
  && pass "ok/unknown 취소 거부가 종료 확정 경로를 안내한다 (F9 잔여)" || fail "F9 잔여 안내 누락: $rb_out"
[[ "$rb_out" == *"작업물 보호까지"* ]] \
  && pass "--force 가 작업물 보호까지 해제함을 그 자리에서 알린다 (F9 잔여)" || fail "F9 잔여 --force 경고 누락: $rb_out"
[[ "$rb_out" != *"종료 뒤 재시도"* ]] \
  && pass "판정 불가에서 되풀이되는 재시도를 권하지 않는다 (F9 잔여)" || fail "F9 잔여: 실패하는 재시도를 안내했다"

# 플래그 없이는 여전히 거부한다 — 그때는 해소할 것이 없다.
if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/rd task resolve-launch ended 2>&1 )"; then
  fail "F9: ok 를 플래그 없이 해소했다"
else
  [[ "$(tasks_index_get ended launch)" == "ok" ]] \
    && pass "ok 는 플래그 없이 해소하지 않는다 (F9)" || fail "F9 ok 유지 실패"
  [[ "$out" == *"--assume-ended"* ]] \
    && pass "ok 거부 메시지가 종료 확정 경로를 안내한다 (F9)" || fail "F9 ok 안내 누락: $out"
fi

if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/rd task resolve-launch ended --assume-ended 2>&1 )"; then
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
if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended 2>&1 )"; then
  fail "F6 잔여: showUntrackedFiles=no 에서 미추적 작업물이 있는데 취소가 통과했다"
else
  [[ -f "$TMP/.worktrees/ended/untracked-work.txt" ]] \
    && pass "showUntrackedFiles=no 여도 미추적 작업물이 보존된다 (F6 잔여)" || fail "F6 잔여: 미추적 파일이 사라졌다"
  [[ "$out" == *"untracked-work.txt"* ]] \
    && pass "잃을 파일을 이름으로 보여준다 (F6 잔여)" || fail "F6 잔여: 손실 목록에 파일이 없다: $out"
fi

# dry-run 의 손실 목록도 같은 helper 를 쓴다 — 여기서 비어 보이면 사용자는 취소 전에
# 위험을 볼 수 없다.
dry_out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended --dry-run 2>&1 )" || true
[[ "$dry_out" == *"untracked-work.txt"* ]] \
  && pass "--dry-run 손실 목록에도 미추적 파일이 나온다 (F6 잔여)" || fail "F6 잔여 dry-run 목록: $dry_out"

# --force 로는 버릴 수 있다 — 취소 기능 자체는 살아 있다.
if out="$( cd "$REPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ended --force 2>&1 )"; then
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
[[ -z "$(tasks_index_slugs)" ]] || fail "fixture 전제 실패: 색인 행이 남아 있다"
before_baseline="$(cat "$REPO/rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null || printf '')"
if out="$( cd "$REPO" && bash rd-workflow/scripts/rd task set-status "구현 중" 2>&1 )"; then
  fail "색인 0건 + 기본 브랜치인데 baseline 을 대상으로 전이가 성공했다"
else
  after_baseline="$(cat "$REPO/rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null || printf '')"
  [[ "$out" == *"진행 중인 작업이 없습니다"* ]] \
    && [[ "$after_baseline" == "$before_baseline" ]] \
    && pass "색인 0건 + 기본 브랜치는 baseline 을 대상 삼지 않는다 (AC 4)" || fail "AC4 baseline 보호"
fi

printf 'tasks_list: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
