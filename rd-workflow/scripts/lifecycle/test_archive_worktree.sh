#!/usr/bin/env bash
# test_archive_worktree.sh — archive.sh 를 작업 worktree/제3 worktree 에서 호출하는
# 경로(Task 6, spec D5·D8·D13)를 검증한다.
# 이름 주의: scripts/batch/test_archive_state.sh 는 전혀 다른 파일(FR batch 의
# archive-state 판정 검증)이다 — self_test.sh 가 이미 그 이름표로 등록해 두었으므로
# 같은 이름을 쓰면 라벨이 같은 두 스텝이 생겨 한쪽 실패를 다른 쪽으로 오독한다.
set -euo pipefail
trap 'ec=$?; echo "  FAIL: 스위트가 line ${LINENO} 에서 rc=${ec} 로 중단됐습니다 (조용한 중단)" >&2' ERR
DONE=0
_ast_cleanup=()
_suite_on_exit() {
  local _ec=$? _d
  for _d in ${_ast_cleanup[@]+"${_ast_cleanup[@]}"}; do [[ -z "$_d" ]] || rm -rf "$_d"; done
  [[ "$DONE" == 1 ]] || echo "  FAIL: 스위트가 결과줄 없이 rc=${_ec} 로 중단됐습니다 (조용한 중단 — 마지막 PASS 줄 다음을 보십시오)" >&2
}
trap _suite_on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# **실제 herdr 호출 차단 (파일 전체 적용).** 이 스위트는 promote.sh 를 여러 번 호출하고,
# 재설계된 promote.sh 는 session_launch 를 호출한다. 이 세션 자체가 herdr pane 안에서
# 돌면 HERDR_ENV=1 이 하위 프로세스로 상속되어, 임시 fixture 에서 promote 를 실행하는
# 것만으로 실제 herdr pane split/agent start 가 발생한다(2026-09-15 실측 사고).
# 첫 테스트 케이스보다 앞에서 export 한다 — 서브셸은 export 된 값을 그대로 물려받으므로
# 이 파일의 모든 케이스에 적용된다.
export HERDR_ENV=
export RD_CHILD_SESSION=1

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

REPO="$(mktemp -d)" || { echo "test_archive_worktree.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$REPO" && -d "$REPO" ]] || { echo "test_archive_worktree.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
# macOS /var → /private/var 심링크 때문에 mktemp 경로와 git 절대경로의 표현이 다르다.
# 문자열 비교를 하는 케이스가 있으므로 정규화해 둔다.
REPO="$(cd "$REPO" && pwd -P)"
_ast_cleanup+=("$REPO")

ARCHIVE_SH="$REPO/rd-workflow/scripts/lifecycle/archive.sh"

# 실배포와 같은 진입점(archive.sh · rd-workflow/scripts/rd · promote.sh)을 그대로
# 호출해야 하므로, $REPO 는 이 dev repo 의 scripts/ 트리를 그대로 복사해 갖는다.
mkdir -p "$REPO/rd-workflow"
cp -R "$SCRIPT_DIR/.." "$REPO/rd-workflow/scripts"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
mkdir -p "$REPO/rd-workflow-workspace/.lifecycle" "$REPO/rd-workflow-workspace/backlog/items"
# 실배포 .gitignore 를 그대로 쓴다(로컬 우회를 만들지 않는다) — `.worktrees/` 와
# `rd-workflow-workspace/.lifecycle/review-skip-audit.log` 둘 다 이미 실배포
# `_ROOT_FILES/.gitignore` 에 있다. 후자가 없으면 --force-skip-review-check 로 archive
# 를 여러 번 연속 호출할 때(이 스위트의 핵심 시나리오) 그 로그가 untracked 로 쌓여
# 다음 archive 호출의 clean 검증(Step 0)을 방해한다 — fixture 를 손으로 고치는 대신
# 실배포 .gitignore 자체를 고쳤다(Task 6 리뷰 지적).
cp "$SCRIPT_DIR/../../../.gitignore" "$REPO/.gitignore"
bash -c "source '$SCRIPT_DIR/_lifecycle_common.sh'; emit_current_task_baseline" > "$REPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$REPO/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$REPO/REQUEST.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m seed

PROMOTE_SH="$REPO/rd-workflow/scripts/lifecycle/promote.sh"
RD_SH="$REPO/rd-workflow/scripts/rd"

# alpha·beta·delta 를 병렬 worktree 로 착수한다.
bash "$PROMOTE_SH" --short-title alpha --size large --source-fr -
bash "$PROMOTE_SH" --short-title beta --size large --source-fr -
bash "$PROMOTE_SH" --short-title delta --size large --source-fr -
# --no-worktree 작업(D13 재현)은 여기서 바로 착수하지 않는다 — --no-worktree 는 기본
# worktree($REPO) 자신의 체크아웃을 fr/nw 로 옮겨 그 metadata 를 active 로 만들어
# 버려서, 아래 alpha/beta/delta archive 테스트가 "기본 worktree = baseline" 전제를
# 잃는다. D13 절 직전에 착수한다.

# 각 fr worktree 에 실제 작업 커밋을 하나씩 얹는다 (archive 의 "archive content 미감지"
# 경고와 무관하게, merge 대상에 실질 변경이 있어야 한다). 파일명을 slug 별로 분리한다 —
# 공통 base 에 없던 같은 파일을 여러 branch 가 독립적으로 새로 만들면(추가/추가) 충돌이
# 나고, 뒤이은 merge 가 이 스위트가 검증하려는 것과 무관한 이유로 실패한다.
for slug in alpha beta delta; do
  printf 'work-%s\n' "$slug" >> "$REPO/.worktrees/$slug/src-$slug.txt"
  git -C "$REPO/.worktrees/$slug" add -A
  git -C "$REPO/.worktrees/$slug" commit -q -m "구현: $slug"
done

# beta 를 "검증 중" 으로 만들어 둔다 — alpha archive 이후 beta 보존을 이 값으로 검증한다.
sed -i 's/^status=.*/status=검증 중/' "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state"
git -C "$REPO/.worktrees/beta" add rd-workflow-workspace/.lifecycle/task-state
git -C "$REPO/.worktrees/beta" commit -q -m "progress: 검증 중"

echo "== archive.sh — 작업 worktree 호출(재실행) =="

alpha_idx_before="$(git -C "$REPO/.worktrees/alpha" ls-files --stage)"

# 작업 worktree 안에서 호출해도 merge·tag 가 기본 브랜치에 이뤄진다.
if out="$( cd "$REPO/.worktrees/alpha" && bash "$ARCHIVE_SH" --force-skip-review-check "테스트" 2>&1 )"; then
  pass "작업 worktree 에서 호출한 archive 가 rc=0 으로 끝난다"
else
  fail "작업 worktree 호출 archive — 실패: $out"
fi
git -C "$REPO" merge-base --is-ancestor fr/alpha main \
  && pass "작업 worktree 에서 호출한 archive 가 기본 브랜치에 merge 한다" || fail "worktree 호출 archive — merge 누락"

# 자기 worktree 는 제거하지 않고 정리 명령을 낸다 (skipped-self).
[[ -d "$REPO/.worktrees/alpha" ]] && pass "실행 중 worktree(alpha)를 지우지 않는다" || fail "self 제거됨"

# 다른 작업(beta)은 상태·branch 모두 보존된다.
if [[ -n "$(git -C "$REPO" rev-parse --verify fr/beta 2>/dev/null)" ]] \
  && [[ "$(grep '^status=' "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")" == "status=검증 중" ]]; then
  pass "A(alpha) archive 후 B(beta) 상태 보존"
else
  fail "B(beta) 보존 실패"
fi

# baseline 초기화가 기본 worktree 에 이뤄지고, 호출한 작업 worktree 는 바뀌지 않았다.
if [[ "$(sed -n '/^## Short Title/{n;p;q}' "$REPO/CURRENT_TASK.md")" == "-" ]]; then
  pass "기본 worktree(CURRENT_TASK.md)가 baseline 이 되었다"
else
  fail "baseline 위치 — 기본 worktree 미초기화"
fi
if [[ -z "$(git -C "$REPO/.worktrees/alpha" status --porcelain)" ]] \
  && [[ "$(git -C "$REPO/.worktrees/alpha" ls-files --stage)" == "$alpha_idx_before" ]]; then
  pass "호출 worktree(alpha)가 archive 로 더럽혀지지 않았다"
else
  fail "호출 worktree(alpha) 오염됨"
fi

# 발행 후 그 작업은 '진행 중' 이 아니라 '정리 대기' 로 보인다 (rebuild 해도 되살아나지 않는다).
out="$( cd "$REPO" && bash "$RD_SH" task list --rebuild 2>&1 )"
if [[ "$out" == *"정리 대기"* && "$out" == *"alpha"* ]]; then
  pass "발행 완료(alpha)는 정리 대기로 유지된다"
else
  fail "정리 대기 유지 실패 — 목록: $out"
fi
# 위 출력만으로는 archive.sh 가 실제로 state=cleanup-pending 을 색인에 기록했는지 증명하지
# 못한다 — alpha 는 merge+tag 가 이미 끝나 tasks_publish_evidence 의 동적 판정만으로도
# 같은 "정리 대기" 문구가 나오기 때문이다(정적 기록이 아예 안 됐어도 이 assert 는 PASS
# 한다). 색인 값을 직접 읽어 기록 자체를 증명한다(리뷰 지적).
alpha_state="$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get alpha state' 2>/dev/null )" || alpha_state=""
alpha_publish_tag="$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get alpha publish-tag' 2>/dev/null )" || alpha_publish_tag=""
if [[ "$alpha_state" == "cleanup-pending" && -n "$alpha_publish_tag" ]]; then
  pass "archive 가 색인에 state=cleanup-pending·publish-tag 를 직접 기록했다"
else
  fail "색인 기록 증명 실패 — state='$alpha_state' publish-tag='$alpha_publish_tag'"
fi

echo "== archive.sh — 제3 worktree에서 --task 로 대상 지정 =="

# delta 는 beta 와 달리 이 archive 호출의 caller(=beta)의 worktree 가 아니므로 정상
# 정리되어 fr/delta ref 자체가 삭제된다 — merge 확인은 ref 가 아니라 archive 호출 전에
# 캡처해 둔 commit OID 의 main 조상 여부로 한다(ref 삭제와 무관하게 유효하다).
delta_tip_before="$(git -C "$REPO" rev-parse fr/delta)"
before_caller="$(git -C "$REPO/.worktrees/beta" ls-files --stage)"
if out="$( cd "$REPO/.worktrees/beta" && bash "$ARCHIVE_SH" --task delta --force-skip-review-check "테스트" 2>&1 )"; then
  pass "beta(호출자)에서 --task delta 호출이 rc=0 으로 끝난다"
else
  fail "beta→delta 호출 실패: $out"
fi
git -C "$REPO" merge-base --is-ancestor "$delta_tip_before" main \
  && pass "--task 로 지정한 delta 가 기본 브랜치에 merge 된다" || fail "--task delta merge 누락"
if [[ "$(git -C "$REPO/.worktrees/beta" ls-files --stage)" == "$before_caller" ]]; then
  pass "제3 worktree(beta) 호출이 호출자를 더럽히지 않는다"
else
  fail "재실행 경로 바인딩 실패 — beta index 변경됨"
fi

echo "== archive.sh — D13: --no-worktree 작업을 기본 브랜치로 되돌린 뒤 --task 로 마감 =="

# --no-worktree 작업(D13 재현) — 별도 worktree 없이 기본 체크아웃을 옮겨 쓴다. 이 시점
# 이후 $REPO 자신의 체크아웃이 fr/nw 로 바뀌므로, 그 전의 alpha/beta/delta 테스트는
# 이미 모두 끝나 있어야 한다.
bash "$PROMOTE_SH" --short-title nw --size large --source-fr - --no-worktree
( cd "$REPO" && git switch -q fr/nw )
printf 'work-nw\n' > "$REPO/src-nw.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "구현: nw"
( cd "$REPO" && bash "$RD_SH" task set-status "아카이브 보류" --force )
# set-status 는 task-state/CURRENT_TASK.md 를 파일로만 바꾼다(커밋하지 않는다) — 커밋해
# 두지 않으면 main 으로 되돌아갈 때 두 branch 의 파일 내용이 갈려 checkout 이 거부된다.
( cd "$REPO" && git add -A && git commit -q -m "진행: 아카이브 보류" )
nw_tip_before="$(git -C "$REPO" rev-parse fr/nw)"
( cd "$REPO" && git switch -q main )
if out="$( cd "$REPO" && bash "$ARCHIVE_SH" --task nw --force-skip-review-check "테스트" 2>&1 )"; then
  pass "D13 — --task nw 호출이 rc=0 으로 끝난다"
else
  fail "D13 — --task nw 호출 실패: $out"
fi
# nw 는 별도 worktree 가 없어(--no-worktree) 정상 정리되면 fr/nw ref 자체가 삭제된다 —
# merge 확인은 archive 호출 전에 캡처해 둔 commit OID 기준으로 한다.
git -C "$REPO" merge-base --is-ancestor "$nw_tip_before" main \
  && pass "D13 — 비체크아웃 작업을 fr tip 권위로 마감한다" || fail "D13 마감 경로 실패"

echo "== archive.sh — launching 예약은 발행하지 않는다 (spec D7·plan 1076행) =="

# gamma 를 착수한 뒤, promote 의 실제 기동 경로를 타지 않고(RD_CHILD_SESSION=1 이 이미
# launch=none 으로 귀결시킨다) 색인을 직접 조작해 "예약됐지만 아직 확인되지 않은" 상태를
# 재현한다 — 기존 test_lifecycle.sh 의 race 케이스와 같은 기법이다.
bash "$PROMOTE_SH" --short-title gamma --size large --source-fr -
printf 'work-gamma\n' >> "$REPO/.worktrees/gamma/src-gamma.txt"
git -C "$REPO/.worktrees/gamma" add -A
git -C "$REPO/.worktrees/gamma" commit -q -m "구현: gamma"
( cd "$REPO" && bash -c '
    source rd-workflow/scripts/lifecycle/_tasks_index.sh
    tasks_lock_acquire test-launching gamma
    tasks_index_upsert gamma launch=launching launch-token="$(date -u +%Y-%m-%d-%H%M)-99999"
    tasks_lock_release
  ' )

gamma_fr_before="$(git -C "$REPO" rev-parse --verify fr/gamma)"
gamma_idx_before="$(git -C "$REPO/.worktrees/gamma" ls-files --stage)"
gamma_launch_before="$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get gamma launch' )"

gamma_rc=0
gamma_out="$( cd "$REPO/.worktrees/gamma" && bash "$ARCHIVE_SH" --force-skip-review-check "테스트" 2>&1 )" || gamma_rc=$?
if [[ "$gamma_rc" -ne 0 ]]; then
  pass "launching 예약 중인 작업은 archive 가 nonzero 로 거부한다"
else
  fail "launching 예약인데 archive 가 성공(rc=0)했다 — 출력: $gamma_out"
fi
[[ "$gamma_out" == *"resolve-launch"* ]] && pass "launching 거부 시 resolve-launch 확인 방법을 안내한다" \
  || fail "resolve-launch 안내 누락 — 출력: $gamma_out"

# 상태 보존 — merge 되지 않았고, 대상 worktree 의 파일·index 도 그대로다.
gamma_fr_after="$(git -C "$REPO" rev-parse --verify fr/gamma)"
[[ "$gamma_fr_before" == "$gamma_fr_after" ]] && pass "launching 거부 후 fr/gamma ref 불변" || fail "launching 거부인데 fr/gamma ref 변경됨"
git -C "$REPO" merge-base --is-ancestor fr/gamma main 2>/dev/null \
  && fail "launching 거부인데 fr/gamma 가 main 에 merge 됐다" \
  || pass "launching 거부 — fr/gamma 가 merge 되지 않았다"
if [[ -z "$(git -C "$REPO/.worktrees/gamma" status --porcelain)" ]] \
  && [[ "$(git -C "$REPO/.worktrees/gamma" ls-files --stage)" == "$gamma_idx_before" ]]; then
  pass "launching 거부 — 대상 worktree(gamma) 파일·index 보존"
else
  fail "launching 거부인데 gamma worktree 가 오염됐다"
fi
gamma_launch_after="$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get gamma launch' )"
[[ "$gamma_launch_before" == "$gamma_launch_after" && "$gamma_launch_after" == "launching" ]] \
  && pass "launching 거부 — 색인의 launch 값도 보존됨" || fail "launching 거부인데 색인 launch 값이 바뀜: $gamma_launch_after"

# 정리 — gamma 는 이후 케이스에 영향 없도록 예약을 풀어 둔다(색인만 정리, 실제 세션 없음).
( cd "$REPO" && bash -c '
    source rd-workflow/scripts/lifecycle/_tasks_index.sh
    tasks_lock_acquire test-launching-cleanup gamma
    tasks_index_upsert gamma launch=none
    tasks_lock_release
  ' ) || true

echo "== archive.sh — A 의 seal 로 B 를 발행할 수 없다 (AC 17) =="

# --task 도입으로 "어느 작업의 seal 을 보는가" 가 인자에 좌우되므로, 종결 마커의
# branch-mode·fr-branch 일치 검사가 실제로 교차 작업 재사용을 막는지 회귀 테스트한다.
# --force-skip-review-check 를 쓰지 않고 **진짜 seal 검증 경로** 를 태운다.
bash "$PROMOTE_SH" --short-title eps --size large --source-fr -
bash "$PROMOTE_SH" --short-title zeta --size large --source-fr -
printf 'work-eps\n' > "$REPO/.worktrees/eps/src-eps.txt"
git -C "$REPO/.worktrees/eps" add -A
git -C "$REPO/.worktrees/eps" commit -q -m "구현: eps"
printf 'work-zeta\n' > "$REPO/.worktrees/zeta/src-zeta.txt"
git -C "$REPO/.worktrees/zeta" add -A
git -C "$REPO/.worktrees/zeta" commit -q -m "구현: zeta"

# eps 자신의(진짜) 종결 마커를 만든다. tree-hash 대상 경로(task-state·review-seals/)는
# 보호 트리 해시에서 제외되므로(_state_common.sh RD_RECORD_PATHS), 이 커밋 전에 재도
# 후에 재도 같은 해시가 나온다 — 순서는 무관하다.
eps_head="$(git -C "$REPO" rev-parse fr/eps)"
eps_hash="$( cd "$REPO/.worktrees/eps" && bash -c 'source rd-workflow/scripts/_state_common.sh; rd_protected_tree_hash fr/eps' )"
EPS_SID="eps-review-001"
mkdir -p "$REPO/.worktrees/eps/rd-workflow-workspace/.lifecycle/review-seals"
cat > "$REPO/.worktrees/eps/rd-workflow-workspace/.lifecycle/review-seals/${EPS_SID}.seal" <<SEAL
schema=1
session-id=${EPS_SID}
review-type=diff-review
tree-hash=${eps_hash}
head=${eps_head}
branch-mode=fr
fr-branch=fr/eps
rd-version=unknown
verified=yes
sealed-at=2026-09-16-0000
SEAL
# sed -i.bak + rm 은 BSD(macOS)·GNU 양립 형태다(spec D9 — 신규 코드는 BSD 비호환 금지,
# test_task_cli.sh:1014-1016 와 같은 관례). `sed -i '...' f` 는 macOS stock sed 에서 실패한다.
sed -i.bak "s/^review-session=.*/review-session=${EPS_SID}/" "$REPO/.worktrees/eps/rd-workflow-workspace/.lifecycle/task-state"
rm -f "$REPO/.worktrees/eps/rd-workflow-workspace/.lifecycle/task-state.bak"
git -C "$REPO/.worktrees/eps" add -A
git -C "$REPO/.worktrees/eps" commit -q -m "review: eps seal"

# eps 자신의 archive 가 이 seal 을 소비(fr branch 삭제 등)하기 전에 내용을 캡처해 둔다.
EPS_SEAL_CONTENT="$(cat "$REPO/.worktrees/eps/rd-workflow-workspace/.lifecycle/review-seals/${EPS_SID}.seal")"

# 통제군 — 위조한 seal 이 진짜 포맷과 같다면 eps 자신은 --force-skip-review-check 없이도
# 발행된다. 이 통제군이 없으면 아래 zeta 거부가 "아무 seal 이나 거부해서" 인지 "다른
# 작업의 seal 이라서" 인지 구분되지 않는다.
eps_ctrl_rc=0
eps_ctrl_out="$( cd "$REPO/.worktrees/eps" && bash "$ARCHIVE_SH" 2>&1 )" || eps_ctrl_rc=$?
if [[ "$eps_ctrl_rc" -eq 0 ]]; then
  pass "통제군 — 진짜 seal 로 eps 자신은 우회 없이 발행된다"
else
  fail "통제군 실패 — 위조한 seal 포맷이 실제 검증을 통과하지 못했다: $eps_ctrl_out"
fi

# zeta 에 eps 의 seal 을 그대로 심는다 — 파일명·세션 id 는 유지한다(복사 탐지가 아니라
# branch-mode·fr-branch 불일치 검사가 막는지를 보기 위함이다).
mkdir -p "$REPO/.worktrees/zeta/rd-workflow-workspace/.lifecycle/review-seals"
printf '%s\n' "$EPS_SEAL_CONTENT" > "$REPO/.worktrees/zeta/rd-workflow-workspace/.lifecycle/review-seals/${EPS_SID}.seal"
sed -i.bak "s/^review-session=.*/review-session=${EPS_SID}/" "$REPO/.worktrees/zeta/rd-workflow-workspace/.lifecycle/task-state"
rm -f "$REPO/.worktrees/zeta/rd-workflow-workspace/.lifecycle/task-state.bak"
git -C "$REPO/.worktrees/zeta" add -A
git -C "$REPO/.worktrees/zeta" commit -q -m "review: eps seal 도용 시도(테스트)"

zeta_fr_before="$(git -C "$REPO" rev-parse fr/zeta)"
zeta_idx_before="$(git -C "$REPO/.worktrees/zeta" ls-files --stage)"
zeta_status_before="$(grep '^status=' "$REPO/.worktrees/zeta/rd-workflow-workspace/.lifecycle/task-state")"

zeta_rc=0
zeta_out="$( cd "$REPO/.worktrees/zeta" && bash "$ARCHIVE_SH" 2>&1 )" || zeta_rc=$?
if [[ "$zeta_rc" -ne 0 ]]; then
  pass "AC17 — A(eps) 의 seal 로 B(zeta) 를 발행할 수 없다(nonzero)"
else
  fail "AC17 실패 — eps 의 seal 로 zeta 가 발행됐다(rc=0): $zeta_out"
fi
# "리뷰 대상 불일치"(hash-mismatch) 에도 같은 부분문자열이 있어 느슨한 매칭은 branch
# 모드 검사를 제거해도 통과한다 — 정확한 사유 문구로 좁힌다(2차 리뷰 지적).
[[ "$zeta_out" == *"마커 branch 모드 불일치"* ]] && pass "AC17 — 거부 사유가 branch 모드 불일치를 정확히 가리킨다" \
  || fail "AC17 — 거부 사유가 예상과 다르다: $zeta_out"

# 상태 보존 — merge 되지 않았고, zeta worktree 의 파일·index·status 도 그대로다.
zeta_fr_after="$(git -C "$REPO" rev-parse fr/zeta)"
[[ "$zeta_fr_before" == "$zeta_fr_after" ]] && pass "AC17 — 거부 후 fr/zeta ref 불변" || fail "AC17 — 거부인데 fr/zeta ref 변경됨"
git -C "$REPO" merge-base --is-ancestor fr/zeta main 2>/dev/null \
  && fail "AC17 — 거부인데 zeta 가 main 에 merge 됐다" \
  || pass "AC17 — zeta 가 merge 되지 않았다"
zeta_status_after="$(grep '^status=' "$REPO/.worktrees/zeta/rd-workflow-workspace/.lifecycle/task-state")"
if [[ -z "$(git -C "$REPO/.worktrees/zeta" status --porcelain)" ]] \
  && [[ "$(git -C "$REPO/.worktrees/zeta" ls-files --stage)" == "$zeta_idx_before" ]] \
  && [[ "$zeta_status_before" == "$zeta_status_after" ]]; then
  pass "AC17 — zeta worktree 파일·index·status 보존"
else
  fail "AC17 — 거부인데 zeta 상태가 오염됨"
fi

echo "== archive.sh — 인자 없이 호출해도 재실행 경로가 죽지 않는다 (bash 3.2 빈 배열) =="

# 이 Task 의 대표 사용 경로는 인자 0개 호출이다(CLAUDE.md·claude_skills 안내가 일관되게
# 이 형태를 쓴다). bash 3.2 + set -u 에서 빈 배열의 "${arr[@]}" 는 unbound variable 로
# 죽는다 — 재실행 직전의 `_reexec_args=("${ORIG_ARGS[@]}")` 에 가드가 없으면 인자 0개
# 호출이 항상 이 경로로 죽는다(리뷰 지적, Critical). 진짜 seal 을 만들지 않아 review
# precheck 는 정상적으로 거부하지만, **그 거부 메시지까지 도달한다는 것 자체가** 재실행
# 경로(파싱→대상 확정→cd→재실행→자식의 인자 파싱)가 안 죽고 끝까지 갔다는 증거다.
bash "$PROMOTE_SH" --short-title noarg --size large --source-fr -
printf 'work-noarg\n' > "$REPO/.worktrees/noarg/src-noarg.txt"
git -C "$REPO/.worktrees/noarg" add -A
git -C "$REPO/.worktrees/noarg" commit -q -m "구현: noarg"

noarg_rc=0
noarg_out="$( cd "$REPO/.worktrees/noarg" && bash "$ARCHIVE_SH" 2>&1 )" || noarg_rc=$?
if [[ "$noarg_out" == *"unbound variable"* ]]; then
  fail "인자 0개 호출이 bash 3.2 unbound variable 로 죽었다: $noarg_out"
else
  pass "인자 0개 호출이 unbound variable 로 죽지 않는다"
fi
if [[ "$noarg_rc" -ne 0 && "$noarg_out" == *"종결 마커 검증 실패"* ]]; then
  pass "인자 0개 호출이 재실행을 끝까지 마치고 review precheck 에 정상 도달한다"
else
  fail "인자 0개 호출이 예상 경로(review precheck 거부)에 도달하지 못했다 — rc=$noarg_rc out=$noarg_out"
fi

echo "== archive.sh — origin 이 있는데 --no-remote 로 마감하면 '발행 확인 필요' 가 남는다 (D8 재확인 REMOTE_MODE 회귀) =="

# 지금까지는 $REPO 에 origin 이 없어 REMOTE_MODE 가 항상 local-only 였다 — 그래서
# 재확인이 --no-remote 로 덮어쓴 값을 실수로 넘겨도 detect_remote_mode() 의 결과와
# 우연히 같아 리뷰가 지적한 사고(정적 cleanup-pending 이 needs-verify 를 지움)가
# 드러나지 않는다. 여기서만 origin(bare remote)을 붙여 그 조건을 재현한다.
git init -q --bare "$REPO.git"
_ast_cleanup+=("$REPO.git")
git -C "$REPO" remote add origin "$REPO.git"
git -C "$REPO" push -q origin main

bash "$PROMOTE_SH" --short-title remotecheck --size large --source-fr -
printf 'work-remotecheck\n' > "$REPO/.worktrees/remotecheck/src-remotecheck.txt"
git -C "$REPO/.worktrees/remotecheck" add -A
git -C "$REPO/.worktrees/remotecheck" commit -q -m "구현: remotecheck"

if out="$( cd "$REPO/.worktrees/remotecheck" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" 2>&1 )"; then
  pass "origin 있음 + --no-remote 마감이 rc=0 으로 끝난다"
else
  fail "origin 있음 + --no-remote 마감 실패: $out"
fi
# 로컬 merge+tag 는 끝났지만 원격에는 아무것도 나가지 않았다 — tasks_list.sh 는
# --no-remote 를 모르고 항상 detect_remote_mode()(=remote)로 판정하므로 "⚠ 발행 확인
# 필요" 로 보여야 하고, 정적 "정리 대기" 기록이 이를 덮으면 안 된다.
# **"발행 확인 필요" 부분문자열만 보면 안 된다** — 그 문구는 tasks_list.sh 의 공유
# 섹션 헤더("정리 대기 / 발행 확인 필요 ...")에도 나와, remotecheck 행이 실제로는
# "정리 대기" 여도 헤더 때문에 이 assert 가 우연히 통과한다(실측 확인 — 회귀를 되살려
# 이 실수를 직접 재현했다). remotecheck 행 자체를 grep 해 그 행의 내용을 본다.
rc_list_out="$( cd "$REPO" && bash "$RD_SH" task list --rebuild 2>&1 )"
rc_row="$(printf '%s\n' "$rc_list_out" | grep -E '^remotecheck[[:space:]]')"
if [[ "$rc_row" == *"발행 확인 필요"* && "$rc_row" != *"정리 대기"* ]]; then
  pass "origin 있음 + --no-remote 는 '⚠ 발행 확인 필요' 로 남는다"
else
  fail "origin 있음 + --no-remote 인데 발행 확인 필요가 사라졌다 — remotecheck 행: '$rc_row' / 전체: $rc_list_out"
fi
rc_state="$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get remotecheck state' 2>/dev/null )" || rc_state=""
if [[ "$rc_state" != "cleanup-pending" ]]; then
  pass "origin 있음 + --no-remote 는 정적 state=cleanup-pending 을 기록하지 않는다"
else
  fail "origin 있음 + --no-remote 인데 state=cleanup-pending 이 잘못 기록됐다"
fi

echo "== archive.sh — 발행 구간 전체가 공유 락 안에 있다 (final diff review F7) =="

# 타이밍 경쟁을 재현하지 않는다(프로젝트 규칙 — 불안정하다). 대신 **락을 미리 잡아 둔**
# 결정론적 상태에서 archive 가 ① 자기 변경 없이 거부되고 ② 점유자 정보와 재시도 방법을
# 내는지 본다. 예전에는 기동 상태 조회에서만 잠깐 잡고 놓아, 그 검사를 통과한 뒤의
# merge → cleanup → publish 가 전부 락 밖이었다 (AC 13·AC 14).
LOCK_DIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/rd-workflow/tasks.lock"

bash "$PROMOTE_SH" --short-title lockcase --size large --source-fr -
printf 'work-lockcase\n' > "$REPO/.worktrees/lockcase/src-lockcase.txt"
git -C "$REPO/.worktrees/lockcase" add -A
git -C "$REPO/.worktrees/lockcase" commit -q -m "구현: lockcase"

lock_main_before="$(git -C "$REPO" rev-parse main)"
lock_fr_before="$(git -C "$REPO" rev-parse fr/lockcase)"
lock_tags_before="$(git -C "$REPO" tag --list | sort)"

# 점유자를 **살아 있는 별도 프로세스**로 둔다 — owner pid 가 죽어 있으면 acquire 가
# rc 2(불확실)로 갈라져 우리가 보려는 rc 1(정상 점유) 경로를 타지 않는다.
( cd "$REPO" && bash -c '
    source rd-workflow/scripts/lifecycle/_tasks_index.sh
    tasks_lock_acquire promote otherslug || exit 1
    sleep 60
  ' ) &
LOCK_HOLDER_PID=$!
lock_wait=0
while [[ ! -d "$LOCK_DIR" && "$lock_wait" -lt 50 ]]; do sleep 0.1; lock_wait=$((lock_wait+1)); done

lock_rc=0
lock_out="$( cd "$REPO/.worktrees/lockcase" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" 2>&1 )" || lock_rc=$?
kill "$LOCK_HOLDER_PID" 2>/dev/null || true
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
# 죽은 점유자의 락은 자동 회수되지 않는다(설계) — 테스트가 직접 치운다.
rm -f "$LOCK_DIR/owner"; rmdir "$LOCK_DIR" 2>/dev/null || true

[[ "$lock_rc" -ne 0 ]] && pass "락 점유 중에는 archive 가 nonzero 로 거부한다 (F7)" \
  || fail "락 점유 중인데 archive 가 성공했다 — 출력: $lock_out"
if [[ "$(git -C "$REPO" rev-parse main)" == "$lock_main_before" ]] \
  && [[ "$(git -C "$REPO" rev-parse fr/lockcase)" == "$lock_fr_before" ]] \
  && [[ "$(git -C "$REPO" tag --list | sort)" == "$lock_tags_before" ]] \
  && [[ -d "$REPO/.worktrees/lockcase" ]]; then
  pass "점유 실패 호출은 merge·tag·worktree 어느 것도 바꾸지 않는다 (AC 14)"
else
  fail "점유 실패인데 공유 상태가 바뀌었다 — 출력: $lock_out"
fi
[[ "$lock_out" == *"cmd=promote"* && "$lock_out" == *"slug=otherslug"* && "$lock_out" == *"started-at="* ]] \
  && pass "점유자(cmd·slug·started-at)를 출력한다 (AC 14)" || fail "점유자 정보 누락: $lock_out"
[[ "$lock_out" == *"재시도"* ]] \
  && pass "재시도 방법을 안내한다 (AC 14)" || fail "재시도 안내 누락: $lock_out"

# 정상 경로에서 락이 끝까지 해제되는지 — 남으면 다음 lifecycle 명령이 전부 막힌다.
if out="$( cd "$REPO/.worktrees/lockcase" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" 2>&1 )"; then
  [[ ! -d "$LOCK_DIR" ]] && pass "정상 마감 뒤 락이 남지 않는다 (F7)" || fail "마감 뒤 tasks.lock 잔존"
else
  fail "락 회수 뒤 재시도한 마감이 실패했다: $out"
fi

# 실패 경로에서도 해제된다 — 여기서는 대상 브랜치가 없어 조기 중단하는 호출을 쓴다.
( cd "$REPO" && bash "$ARCHIVE_SH" --task nosuchtask --no-remote --force-skip-review-check "테스트" >/dev/null 2>&1 ) || true
[[ ! -d "$LOCK_DIR" ]] && pass "중단 경로에서도 락이 해제된다 (F7)" || fail "중단 경로에서 tasks.lock 잔존"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
DONE=1
[[ $FAIL -eq 0 ]]
