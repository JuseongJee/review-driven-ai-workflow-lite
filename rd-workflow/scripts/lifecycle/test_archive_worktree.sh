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
# herdr app(HC_TERMINAL_ID)도 같은 이유로 비운다.
export HERDR_ENV=
export HC_TERMINAL_ID=
export RD_CHILD_SESSION=1
# 바깥 셸의 project_root·TASK_STATE_PATH 를 물려받지 않는다. promote.sh·_state_common.sh 는
# 두 값이 있으면 그 값을 루트·상태 파일로 쓰므로, 상속되면 fixture 가 아니라 바깥 저장소를
# 고친다(2026-10-29 실제 저장소에 fr/alpha·fr/beta·fr/delta 가 생긴 사고).
unset project_root TASK_STATE_PATH

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
if out="$( cd "$REPO/.worktrees/alpha" && bash "$ARCHIVE_SH" --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )"; then
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

# T6(mirror-comments-lost-in-promote-baseline, 필수) — archive.sh 가 실제로 재작성한
# 기본 worktree의 CURRENT_TASK.md 파일을 emit_current_task_baseline 재호출 비교가
# 아니라 독립 기대 문자열과 직접 비교한다. emitter 자체가 맞아도 이후 재작성 경로에서
# 주석이 사라지는 회귀를 이 assertion 만이 잡는다.
if awk '
  BEGIN{state=0}
  /^## Status$/{state=1; next}
  state==1 && /^<!-- 허용 상태값은 \.claude\/rules\/rd-workflow\/task-tracking\.md 참조\. 변경은 rd task set-status 경유 -->$/{state=2; next}
  state==1 {next}
  state==2 && /^$/{state=3; next}
  state==3 && /^## Request$/{found=1}
  END{exit(found?0:1)}
' "$REPO/CURRENT_TASK.md"; then
  pass "T6: archive.sh 재작성 CURRENT_TASK.md의 Status 안내 주석 독립 검증"
else
  fail "T6: archive.sh 재작성 CURRENT_TASK.md의 Status 안내 주석 누락"
fi
if awk '
  BEGIN{state=0}
  /^## Source FR$/{state=1; next}
  state==1 && /^<!-- 권위는 rd-workflow-workspace\/\.lifecycle\/task-state\. 변경은 rd task set-source-fr 경유 -->$/{state=2; next}
  state==1 {next}
  state==2 && /^<!-- 복수\(묶은 작업\)이면 미러 쓰기가 자동으로 한 줄에 1건씩 나열합니다 — 여기 직접 목록을 적지 않습니다 -->$/{state=3; next}
  state==3 && /^$/{state=4; next}
  state==4 && /^## Spec$/{found=1}
  END{exit(found?0:1)}
' "$REPO/CURRENT_TASK.md"; then
  pass "T6: archive.sh 재작성 CURRENT_TASK.md의 Source FR 안내 주석 독립 검증"
else
  fail "T6: archive.sh 재작성 CURRENT_TASK.md의 Source FR 안내 주석 누락"
fi
if [[ -z "$(git -C "$REPO/.worktrees/alpha" status --porcelain)" ]] \
  && [[ "$(git -C "$REPO/.worktrees/alpha" ls-files --stage)" == "$alpha_idx_before" ]]; then
  pass "호출 worktree(alpha)가 archive 로 더럽혀지지 않았다"
else
  fail "호출 worktree(alpha) 오염됨"
fi

# archive 가 실제로 state=cleanup-pending 을 색인에 기록했는지 직접 증명한다. 목록 출력만으로는
# 증명되지 않는다 — alpha 는 merge+tag 가 이미 끝나 tasks_publish_evidence 의 동적 판정만으로도
# 같은 "정리 대기" 문구가 나오기 때문이다(리뷰 지적). 지연 정리가 행을 지우기 전에 읽는다.
alpha_state="$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get alpha state' 2>/dev/null )" || alpha_state=""
alpha_publish_tag="$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get alpha publish-tag' 2>/dev/null )" || alpha_publish_tag=""
if [[ "$alpha_state" == "cleanup-pending" && -n "$alpha_publish_tag" ]]; then
  pass "archive 가 색인에 state=cleanup-pending·publish-tag 를 직접 기록했다"
else
  fail "색인 기록 증명 실패 — state='$alpha_state' publish-tag='$alpha_publish_tag'"
fi

# 호출자 worktree 에 미커밋 변경이 있으면 지연 정리는 보류하고, 발행 완료 작업은 rebuild 해도
# '진행 중' 으로 되살아나지 않고 정리 대기로 유지된다.
: > "$REPO/.worktrees/alpha/dirty.tmp"
out="$( cd "$REPO" && bash "$RD_SH" task list --rebuild 2>&1 )"
if [[ "$out" == *"정리 대기"* && "$out" == *"alpha"* && "$out" == *"정리 보류: alpha"* && -d "$REPO/.worktrees/alpha" ]]; then
  pass "발행 완료(alpha)는 미커밋 변경이 있으면 정리 대기로 유지되고 지연 정리는 보류된다"
else
  fail "정리 대기 유지·보류 실패 — 목록: $out"
fi

# 변경을 치우면 기본 체크아웃의 rd task list 가 호출자 worktree·로컬 브랜치·색인 행을 정리한다.
rm -f "$REPO/.worktrees/alpha/dirty.tmp"
out="$( cd "$REPO" && bash "$RD_SH" task list 2>&1 )"
if [[ "$out" == *"정리됨: alpha"* && ! -d "$REPO/.worktrees/alpha" ]] \
  && ! git -C "$REPO" rev-parse --verify --quiet fr/alpha >/dev/null \
  && [[ -z "$( cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get alpha state' 2>/dev/null )" ]]; then
  pass "호출자 worktree(alpha)는 변경이 없어지면 rd task list 가 worktree·브랜치·색인 행을 지연 정리한다"
else
  fail "호출자 worktree 지연 정리 실패 — 목록: $out"
fi

echo "== archive.sh — 제3 worktree에서 --task 로 대상 지정 =="

# delta 는 beta 와 달리 이 archive 호출의 caller(=beta)의 worktree 가 아니므로 정상
# 정리되어 fr/delta ref 자체가 삭제된다 — merge 확인은 ref 가 아니라 archive 호출 전에
# 캡처해 둔 commit OID 의 main 조상 여부로 한다(ref 삭제와 무관하게 유효하다).
delta_tip_before="$(git -C "$REPO" rev-parse fr/delta)"
before_caller="$(git -C "$REPO/.worktrees/beta" ls-files --stage)"
if out="$( cd "$REPO/.worktrees/beta" && bash "$ARCHIVE_SH" --task delta --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )"; then
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
if out="$( cd "$REPO" && bash "$ARCHIVE_SH" --task nw --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )"; then
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
gamma_out="$( cd "$REPO/.worktrees/gamma" && bash "$ARCHIVE_SH" --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )" || gamma_rc=$?
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
sed -i.bak -e "s/^review-session=.*/review-session=${EPS_SID}/" -e 's/^status=.*/status=아카이브 보류/' "$REPO/.worktrees/eps/rd-workflow-workspace/.lifecycle/task-state"
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
sed -i.bak -e "s/^review-session=.*/review-session=${EPS_SID}/" -e 's/^status=.*/status=아카이브 보류/' "$REPO/.worktrees/zeta/rd-workflow-workspace/.lifecycle/task-state"
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

echo "== archive.sh — D3 발행 대상 Status 검사 (T7) =="

# fr tip Status 가 '구현 중' 인 작업 — 실제 작업 커밋이 있어 merge 가 기본 브랜치 HEAD 를
# 전진시킨다(Status 검사가 merge 뒤로 밀리면 「HEAD 불변」 단언이 잡는다).
# 모든 호출에 --force-skip-review-check 를 줘서 seal 게이트가 먼저 막지 않게 한다 —
# 아래 케이스가 보는 것은 Status 게이트 하나다.
bash "$PROMOTE_SH" --short-title stg --size large --source-fr -
printf 'work-stg\n' > "$REPO/.worktrees/stg/src-stg.txt"
git -C "$REPO/.worktrees/stg" add -A
git -C "$REPO/.worktrees/stg" commit -q -m "구현: stg"
stg_tip_status="$(git -C "$REPO" show fr/stg:rd-workflow-workspace/.lifecycle/task-state | sed -n 's/^status=//p')"
[[ "$stg_tip_status" != "아카이브 보류" ]] && pass "T7: fixture 의 fr tip Status 는 '$stg_tip_status' 이다(아카이브 보류 아님)" \
  || fail "T7: fixture 가 이미 아카이브 보류다 — 시험이 성립하지 않는다"
stg_main_before="$(git -C "$REPO" rev-parse main)"

stg_rc=0; stg_out="$( cd "$REPO/.worktrees/stg" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" 2>&1 )" || stg_rc=$?
[[ "$stg_rc" -ne 0 ]] && pass "T7: Status=구현 중 + force 만 → rc≠0" || fail "T7: Status 검사 없이 발행됨 — $stg_out"
[[ "$stg_out" == *"Status 검사 실패"* && "$stg_out" == *"rd task set-status"* ]] \
  && pass "T7: 거부 안내에 'Status 검사 실패' 와 rd task set-status 순서가 있다" || fail "T7: 거부 안내 누락 — $stg_out"
[[ "$stg_out" == *"'$stg_tip_status'"* ]] && pass "T7: 안내가 대상 Status 값을 보여준다" || fail "T7: Status 값 누락 — $stg_out"
[[ "$(git -C "$REPO" rev-parse main)" == "$stg_main_before" ]] \
  && pass "T7: 거부 후 기본 브랜치 HEAD 불변(merge 전 차단)" || fail "T7: 거부인데 기본 브랜치 HEAD 가 전진했다"
git -C "$REPO" merge-base --is-ancestor fr/stg main 2>/dev/null \
  && fail "T7: 거부인데 fr/stg 가 merge 됐다" || pass "T7: 거부 후 fr/stg 미merge"

# 독립성 — --allow-status-mismatch 만으로는 seal 검사를 우회하지 못한다.
stg_rc=0; stg_out="$( cd "$REPO/.worktrees/stg" && bash "$ARCHIVE_SH" --no-remote --allow-status-mismatch "테스트" 2>&1 )" || stg_rc=$?
[[ "$stg_rc" -ne 0 && "$stg_out" == *"종결 마커 검증 실패"* && "$stg_out" == *"--force-skip-review-check"* ]] \
  && pass "T7: allow 만 → Status 는 통과하고 seal 검사가 거부한다(독립성)" || fail "T7: 독립성 위반 rc=$stg_rc — $stg_out"
[[ "$stg_out" != *"Status 검사 실패"* ]] && pass "T7: allow 만 → Status 거부 문구 없음" || fail "T7: allow 를 줬는데 Status 가 거부했다 — $stg_out"
[[ "$(git -C "$REPO" rev-parse main)" == "$stg_main_before" ]] && pass "T7: seal 거부 후에도 HEAD 불변" || fail "T7: HEAD 전진"

# 사유 없는 --allow-status-mismatch 는 거부
stg_rc=0; stg_out="$( cd "$REPO/.worktrees/stg" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch 2>&1 )" || stg_rc=$?
[[ "$stg_rc" -ne 0 && "$stg_out" == *"--allow-status-mismatch 사유 필수"* ]] \
  && pass "T7: 사유 없는 --allow-status-mismatch → 거부" || fail "T7: 사유 없는 우회가 통과/오문구 rc=$stg_rc — $stg_out"
[[ "$(git -C "$REPO" rev-parse main)" == "$stg_main_before" ]] && pass "T7: 사유 없음 거부 후 HEAD 불변" || fail "T7: HEAD 전진"

# 두 플래그가 모두 있으면 통과하고 audit 에 [status:<값>] 가 남는다
stg_rc=0; stg_out="$( cd "$REPO/.worktrees/stg" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "상태검사 우회 테스트" 2>&1 )" || stg_rc=$?
[[ "$stg_rc" -eq 0 ]] && pass "T7: 두 플래그 → 발행 통과" || fail "T7: 두 플래그인데 실패 rc=$stg_rc — $stg_out"
git -C "$REPO" merge-base --is-ancestor fr/stg main 2>/dev/null && pass "T7: 두 플래그 → fr/stg 가 main 에 merge 됐다" || fail "T7: merge 누락"
grep -qF "[status:$stg_tip_status] 상태검사 우회 테스트" "$REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" \
  && pass "T7: audit 에 [status:$stg_tip_status] 와 사유가 남는다" || fail "T7: audit 줄 누락"

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
# Status 게이트가 seal 검사 앞에 있으므로, review precheck 까지 가려면 fr tip Status 가 보류여야 한다.
sed -i.bak 's/^status=.*/status=아카이브 보류/' "$REPO/.worktrees/noarg/rd-workflow-workspace/.lifecycle/task-state"
rm -f "$REPO/.worktrees/noarg/rd-workflow-workspace/.lifecycle/task-state.bak"
git -C "$REPO/.worktrees/noarg" add -A
git -C "$REPO/.worktrees/noarg" commit -q -m "status: 아카이브 보류(noarg)"

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

if out="$( cd "$REPO/.worktrees/remotecheck" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )"; then
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
# `exec` 로 owner pid($$)와 sleep pid 를 같게 해, 정리 kill 이 고아 sleep 을 남기지 않는다
# (2026-11-01 관찰: 고아 sleep 60 이 stderr 를 쥐어 스텝 종료가 8초 늦음).
LOCK_HOLDER_PIDFILE="$(mktemp)" || { echo "test_archive_worktree.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$LOCK_HOLDER_PIDFILE" && -e "$LOCK_HOLDER_PIDFILE" ]] || { echo "test_archive_worktree.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_ast_cleanup+=("$LOCK_HOLDER_PIDFILE")
( cd "$REPO" && bash -c '
    source rd-workflow/scripts/lifecycle/_tasks_index.sh
    tasks_lock_acquire promote otherslug || exit 1
    echo $$ > "$1"
    exec sleep 60
  ' _ "$LOCK_HOLDER_PIDFILE" ) &
LOCK_HOLDER_PID=$!
lock_wait=0
while [[ ( ! -d "$LOCK_DIR" || ! -s "$LOCK_HOLDER_PIDFILE" ) && "$lock_wait" -lt 50 ]]; do sleep 0.1; lock_wait=$((lock_wait+1)); done

lock_rc=0
lock_out="$( cd "$REPO/.worktrees/lockcase" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )" || lock_rc=$?
kill "$(cat "$LOCK_HOLDER_PIDFILE" 2>/dev/null)" 2>/dev/null || true
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
if out="$( cd "$REPO/.worktrees/lockcase" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )"; then
  [[ ! -d "$LOCK_DIR" ]] && pass "정상 마감 뒤 락이 남지 않는다 (F7)" || fail "마감 뒤 tasks.lock 잔존"
else
  fail "락 회수 뒤 재시도한 마감이 실패했다: $out"
fi

# 실패 경로에서도 해제된다 — 여기서는 대상 브랜치가 없어 조기 중단하는 호출을 쓴다.
( cd "$REPO" && bash "$ARCHIVE_SH" --task nosuchtask --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" >/dev/null 2>&1 ) || true
[[ ! -d "$LOCK_DIR" ]] && pass "중단 경로에서도 락이 해제된다 (F7)" || fail "중단 경로에서 tasks.lock 잔존"

echo "== archive content 감지 =="

# Step 2 의 archive content 감지는 「기본 브랜치 이후 커밋 전체에 request-archive/*.md 추가가 있는가」 를
# 본다. 마지막 커밋만 보면 아카이브 사본 뒤의 정리 커밋 때문에 거짓 경고가 나고,
# REQUEST.md·CURRENT_TASK.md 변경을 신호로 치면 경고가 영영 나지 않는다.
cd_archive_dir="rd-workflow-workspace/backlog/request-archive"
cd_commit() {  # <slug> <파일> <내용> <메시지> — fr worktree 에 파일 하나를 커밋한다
  mkdir -p "$(dirname "$REPO/.worktrees/$1/$2")"
  printf '%s\n' "$3" >> "$REPO/.worktrees/$1/$2"
  git -C "$REPO/.worktrees/$1" add -A
  git -C "$REPO/.worktrees/$1" commit -q -m "$4"
}

# ok1: 작업 → 아카이브 사본 추가 → 사본과 무관한 후속 커밋 (AC1)
bash "$PROMOTE_SH" --short-title ok1 --size large --source-fr -
cd_commit ok1 src-ok1.txt work "구현: ok1"
cd_commit ok1 "$cd_archive_dir/2026-10-29-0000-ok1.md" archived "archive: ok1"
cd_commit ok1 src-ok1.txt followup "정리: ok1"
ok1_out="$( cd "$REPO/.worktrees/ok1" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )" || true
[[ "$ok1_out" != *"미감지"* ]] \
  && pass "ok1 미감지 없음 — 아카이브 사본 뒤 후속 커밋이 있어도 거짓 경고가 없다" \
  || fail "ok1 미감지 경고가 났다: $ok1_out"

# ok1 재실행: fr 브랜치가 이미 기본 브랜치에 병합된 상태 — 빈 범위를 신호 없음으로 읽지 않는다
ok1b_out="$( cd "$REPO/.worktrees/ok1" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )" || true
[[ "$ok1b_out" == *"감지를 건너뜁니다 (fr 브랜치가 이미 기본 브랜치에 병합됨)"* ]] \
  && pass "ok1 재실행 건너뜁니다 있음" || fail "ok1 재실행 — 건너뜀 문구 없음: $ok1b_out"
[[ "$ok1b_out" != *"미감지"* ]] \
  && pass "ok1 재실행 미감지 없음" || fail "ok1 재실행 — 거짓 미감지 경고: $ok1b_out"

# miss1: REQUEST.md·CURRENT_TASK.md 만 바뀐 커밋 — 진짜 누락이므로 경고한다 (AC2)
bash "$PROMOTE_SH" --short-title miss1 --size large --source-fr -
cd_commit miss1 src-miss1.txt work "구현: miss1"
cd_commit miss1 REQUEST.md edited "request: miss1"
cd_commit miss1 CURRENT_TASK.md edited "task: miss1"
miss1_out="$( cd "$REPO/.worktrees/miss1" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )" || true
[[ "$miss1_out" == *"기본 브랜치 이후 커밋 전체에 archive content(request-archive/*.md 추가) 미감지"* ]] \
  && pass "miss1 미감지 경고 있음" || fail "miss1 미감지 경고 누락: $miss1_out"

# 우회가 성립한 발행은 실패 줄을 먼저 내지 않고, 한 줄에 사유와 마커 상태를 함께 알린다 (AC3·AC4)
for _bp in ok1 miss1; do
  eval "_bp_out=\$${_bp}_out"
  [[ "$_bp_out" != *"종결 마커 검증 실패"* ]] \
    && pass "$_bp 우회 성립 — 종결 마커 검증 실패 줄 없음" || fail "$_bp 우회 성립인데 실패 줄이 났다: $_bp_out"
  [[ "$_bp_out" == *"검증 우회 (사유: 테스트; 종결 마커 상태:"* ]] \
    && pass "$_bp 우회 경고에 종결 마커 상태 포함" || fail "$_bp 우회 경고 문구 누락: $_bp_out"
done

# nobase1: 기본 브랜치를 못 얻으면 감지를 못 했다고 알리고, 마지막 커밋 판정으로 돌아가지 않는다 (AC2b)
bash "$PROMOTE_SH" --short-title nobase1 --size large --source-fr -
cd_commit nobase1 src-nobase1.txt work "구현: nobase1"
# archive.sh 는 기본 체크아웃으로 재실행되므로 기본 브랜치 설정은 기본 체크아웃(main)에 둔다.
# promote 가 끝난 뒤에 넣는다 — promote 도 get_default_branch 를 쓴다.
mkdir -p "$REPO/rd-workflow/config"
printf '{"default_branch": "no-such-branch"}\n' > "$REPO/rd-workflow/config/workflow.json"
git -C "$REPO" add rd-workflow/config/workflow.json
git -C "$REPO" commit -q -m "config: nobase1 기본 브랜치를 없는 이름으로"
nobase1_out="$( cd "$REPO/.worktrees/nobase1" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )" || true
[[ "$nobase1_out" == *"감지를 수행하지 못했습니다"* ]] \
  && pass "nobase1 감지를 수행하지 못했습니다 있음" || fail "nobase1 — 판정 불가 문구 누락: $nobase1_out"
[[ "$nobase1_out" != *"미감지"* ]] \
  && pass "nobase1 미감지 없음" || fail "nobase1 — 판정 불가인데 미감지 경고: $nobase1_out"

# --- merge output ---
echo "== archive.sh — git merge 출력: 성공은 보존, 자동 해소 성공은 보류, 해소 불가는 노출 =="

# 앞 구획(nobase1)이 기본 브랜치를 없는 이름으로 바꿔 두었으므로 되돌린다.
printf '{"default_branch": "main"}\n' > "$REPO/rd-workflow/config/workflow.json"
git -C "$REPO" add rd-workflow/config/workflow.json
git -C "$REPO" commit -q -m "config: 기본 브랜치 복구"

mo_sm="rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
mo_hdr=$'# short_title\tfrom_status\tto_status\tepoch'
# 충돌 시나리오가 쓰는 stage_metrics.tsv 를 형식이 맞는 기준 상태로 맞춘다 (3-way 에 공통 조상이 필요).
printf '%s\nmo-base\t대기 중\t구현 중\t100\n' "$mo_hdr" > "$REPO/$mo_sm"
printf 'base\n' > "$REPO/x.txt"
git -C "$REPO" add -A
RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "mo: 기준 stage_metrics"

# mo_diverge <slug> <main-sm-row> [x]  — fr 와 main 이 stage_metrics.tsv 끝에 서로 다른 행을 추가한다.
#   세 번째 인자 x 가 있으면 x.txt 도 양쪽에서 다르게 바꿔 함께 충돌시킨다.
mo_diverge() {
  local slug="$1" mrow="$2" withx="${3:-}"
  bash "$PROMOTE_SH" --short-title "$slug" --size large --source-fr - >/dev/null 2>&1
  printf '%s\t대기 중\t구현 중\t200\n' "$slug" >> "$REPO/.worktrees/$slug/$mo_sm"
  [[ -z "$withx" ]] || printf 'fr-side\n' > "$REPO/.worktrees/$slug/x.txt"
  printf 'work-%s\n' "$slug" > "$REPO/.worktrees/$slug/src-$slug.txt"
  git -C "$REPO/.worktrees/$slug" add -A
  git -C "$REPO/.worktrees/$slug" commit -q -m "구현: $slug"
  printf '%b' "$mrow" >> "$REPO/$mo_sm"
  [[ -z "$withx" ]] || printf 'main-side\n' > "$REPO/x.txt"
  git -C "$REPO" add -A
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "main 쪽 추가: $slug"
}
mo_archive() {  # <slug> — 출력은 mo_out, 종료코드는 mo_rc
  mo_rc=0
  mo_out="$( cd "$REPO/.worktrees/$1" && bash "$ARCHIVE_SH" --no-remote --force-skip-review-check "테스트" --allow-status-mismatch "테스트" 2>&1 )" || mo_rc=$?
}

# 케이스 1 — 충돌 없는 merge 는 git 이 낸 출력이 그대로 보존된다.
bash "$PROMOTE_SH" --short-title mo1 --size large --source-fr - >/dev/null 2>&1
printf 'work-mo1\n' > "$REPO/.worktrees/mo1/src-mo1.txt"
git -C "$REPO/.worktrees/mo1" add -A
git -C "$REPO/.worktrees/mo1" commit -q -m "구현: mo1"
mo_clone="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
[[ -n "$mo_clone" && -d "$mo_clone" ]] || { echo "mktemp 경로 검증 실패" >&2; exit 1; }
_ast_cleanup+=("$mo_clone")
git clone -q "$REPO" "$mo_clone/c" 2>/dev/null
git -C "$mo_clone/c" config user.email t@t && git -C "$mo_clone/c" config user.name t
mo_expect="$(git -C "$mo_clone/c" merge --no-ff -m x origin/fr/mo1 2>&1)"
mo_expect="${mo_expect%%$'\n'*}"   # 첫 줄 (파이프+head 는 pipefail 에서 SIGPIPE 를 낸다)
mo_archive mo1
if [[ "$mo_rc" -eq 0 && -n "$mo_expect" && "$mo_out" == *"$mo_expect"* ]]; then
  pass "mo1: 충돌 없는 merge 의 git 출력('$mo_expect')이 보존된다"
else
  fail "mo1: git merge 출력 누락 — rc=$mo_rc expect='$mo_expect' out: $mo_out"
fi

# 케이스 2 — stage_metrics.tsv 단독 충돌의 자동 해소 성공은 git 의 실패 출력을 내지 않는다.
mo_diverge mo2 'mo2-main\t대기 중\t구현 중\t300\n'
mo_archive mo2
[[ "$mo_rc" -eq 0 ]] && pass "mo2: 자동 해소 발행이 rc=0 이다" || fail "mo2: rc=$mo_rc — $mo_out"
[[ "$mo_out" == *"줄 합집합으로 해결했습니다"* ]] \
  && pass "mo2: 해소 안내가 있다" || fail "mo2: 해소 안내 누락 — $mo_out"
if [[ "$mo_out" != *"Automatic merge failed"* && "$mo_out" != *"자동 병합이 실패했습니다"* && "$mo_out" != *"CONFLICT"* ]]; then
  pass "mo2: 해소 성공 출력에 git 실패 문구가 없다"
else
  fail "mo2: git 실패 문구가 새어 나왔다 — $mo_out"
fi

# 케이스 3 — stage_metrics.tsv 와 x.txt 동시 충돌은 멈추고 git 출력(CONFLICT)을 낸다.
mo_diverge mo3 'mo3-main\t대기 중\t구현 중\t300\n' x
mo_archive mo3
[[ "$mo_rc" -ne 0 ]] && pass "mo3: 해소 불가 충돌은 rc≠0 이다" || fail "mo3: rc=0 — $mo_out"
# 로케일을 건드리지 않으므로 git 출력의 언어에 의존하지 않고, git 만 내는 충돌 파일명 줄(x.txt)로 본다.
[[ "$mo_out" == *"x.txt"* ]] \
  && pass "mo3: 해소 불가 시 git 의 충돌 출력(x.txt 줄)을 낸다" || fail "mo3: git 충돌 출력 누락 — $mo_out"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true

# 케이스 3b — stage_metrics.tsv 형식 오류(_sm_stop 경로)도 git 출력을 낸다.
mo_diverge mo3b 'mo3b-main\t대기 중\t300\n'
mo_archive mo3b
[[ "$mo_rc" -ne 0 ]] && pass "mo3b: 형식 오류 충돌은 rc≠0 이다" || fail "mo3b: rc=0 — $mo_out"
# archive 자신의 문구는 경로 없이 "stage_metrics.tsv" 만 쓰므로, 전체 경로 줄은 git 출력에서만 온다.
[[ "$mo_out" == *"$mo_sm"* && "$mo_out" == *"형식 오류"* ]] \
  && pass "mo3b: _sm_stop 경로가 사유와 git 출력을 함께 낸다" || fail "mo3b: git 출력/사유 누락 — $mo_out"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true

# CURRENT_TASK.md 충돌 (FR publish-path-interruptions D1) — fr 는 `대기 중` 줄을 `아카이브 보류` 로, main 은 같은 줄을 `구현 중` 으로 바꾼다.
# mo_ct_diverge <slug> [sm|x|ve|vedel|veonly]  — 케이스 사이에 main 의 CURRENT_TASK.md 를 `대기 중` 기준으로 되돌려 둔 뒤 시작한다.
#   ve     : sm + FUTURE_REQUESTS.md + verify-evidence 를 양쪽에서 다르게 바꾼다 (2026-11-01 실사례 네 파일 조합).
#   vedel  : fr 는 verify-evidence 를 지우고 main 은 바꾼다 (stage 3 없음).
#   veonly : verify-evidence 만 양쪽에서 다르게 바꾼다 — CURRENT_TASK.md 는 건드리지 않는다 (단독 충돌).
mo_ve="rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"
mo_idx="rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
mo_ev() {  # mo_ev <command 값> <파일> — 6키 증거 파일을 쓴다
  mkdir -p "$(dirname "$2")"
  printf 'schema=1\ncommand=%s\nexit-code=0\ntree-hash=0\nhead=0\nrecorded-at=0\n' "$1" > "$2"
}
mo_ct_diverge() {
  local slug="$1" extra="${2:-}" ct=1
  [[ "$extra" != veonly ]] || ct=0
  if ! grep -qx '대기 중' "$REPO/CURRENT_TASK.md"; then
    sed -i 's/^구현 중$/대기 중/' "$REPO/CURRENT_TASK.md"
    git -C "$REPO" add -A
    RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "main: CURRENT_TASK 기준 복구 ($slug)"
  fi
  if [[ "$extra" == sm || "$extra" == ve ]]; then  # 앞 케이스(mo3b)가 main 에 남긴 형식 오류 행을 기준 상태로 되돌린다
    printf '%s\nmo-base\t대기 중\t구현 중\t100\n' "$mo_hdr" > "$REPO/$mo_sm"
    git -C "$REPO" add -A
    RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "main: stage_metrics 기준 복구 ($slug)" || true
  fi
  case "$extra" in ve|vedel|veonly)  # 증거(·인덱스) 공통 조상
    mo_ev base "$REPO/$mo_ve"
    [[ "$extra" != ve ]] || printf '# FR\n\n## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |\n|---|---|---|---|---|---|---|\n' > "$REPO/$mo_idx"
    git -C "$REPO" add -A
    RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "main: 증거 기준 ($slug)" || true ;;
  esac
  bash "$PROMOTE_SH" --short-title "$slug" --size large --source-fr - >/dev/null 2>&1
  (( ct )) && sed -i 's/^대기 중$/아카이브 보류/' "$REPO/.worktrees/$slug/CURRENT_TASK.md"
  printf 'work-%s\n' "$slug" > "$REPO/.worktrees/$slug/src-$slug.txt"
  [[ "$extra" != sm && "$extra" != ve ]] || printf '%s\t대기 중\t구현 중\t200\n' "$slug" >> "$REPO/.worktrees/$slug/$mo_sm"
  [[ "$extra" != x ]] || printf 'fr-side-%s\n' "$slug" > "$REPO/.worktrees/$slug/x.txt"
  case "$extra" in
    ve|veonly) mo_ev "fr-$slug" "$REPO/.worktrees/$slug/$mo_ve" ;;
    vedel) git -C "$REPO/.worktrees/$slug" rm -q -- "$mo_ve" ;;
  esac
  [[ "$extra" != ve ]] || printf '| 2026-02-02 | fr-%s | s | tooling | idea | - | [상세](items/fr-%s.md) |\n' "$slug" "$slug" >> "$REPO/.worktrees/$slug/$mo_idx"
  git -C "$REPO/.worktrees/$slug" add -A
  git -C "$REPO/.worktrees/$slug" commit -q -m "구현: $slug"
  (( ct )) && sed -i 's/^대기 중$/구현 중/' "$REPO/CURRENT_TASK.md"
  [[ "$extra" != sm && "$extra" != ve ]] || printf '%s-main\t대기 중\t구현 중\t300\n' "$slug" >> "$REPO/$mo_sm"
  [[ "$extra" != x ]] || printf 'main-side-%s\n' "$slug" > "$REPO/x.txt"
  case "$extra" in ve|vedel|veonly) mo_ev "main-$slug" "$REPO/$mo_ve" ;; esac
  [[ "$extra" != ve ]] || printf '| 2026-02-03 | main-%s | s | tooling | idea | - | [상세](items/main-%s.md) |\n' "$slug" "$slug" >> "$REPO/$mo_idx"
  git -C "$REPO" add -A
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "main: $slug"
}

# T1 — CURRENT_TASK.md 단독 충돌은 main 쪽으로 해소된다.
mo_ct_diverge ct1
mo_archive ct1
[[ "$mo_rc" -eq 0 ]] && pass "T1: CURRENT_TASK.md 단독 충돌 발행이 rc=0 이다" || fail "T1: rc=$mo_rc — $mo_out"
[[ "$mo_out" == *"CURRENT_TASK.md 충돌을 main 쪽으로 해결했습니다"* ]] \
  && pass "T1: 해소 안내가 있다" || fail "T1: 해소 안내 누락 — $mo_out"
grep -qx '대기 중' "$REPO/CURRENT_TASK.md" \
  && pass "T1: 발행 뒤 main 의 CURRENT_TASK.md 가 기준 상태(대기 중)다" || fail "T1: CURRENT_TASK.md 에 '대기 중' 줄 없음"

# T2 — stage_metrics.tsv 충돌과 함께여도 둘 다 해소된다.
mo_ct_diverge ct2 sm
mo_archive ct2
[[ "$mo_rc" -eq 0 ]] && pass "T2: CURRENT_TASK.md + stage_metrics.tsv 충돌 발행이 rc=0 이다" || fail "T2: rc=$mo_rc — $mo_out"
[[ "$mo_out" == *"CURRENT_TASK.md 충돌을 main 쪽"* && "$mo_out" == *"stage_metrics.tsv 충돌을 줄 합집합으로 해결했습니다"* ]] \
  && pass "T2: 두 해소 안내가 모두 있다" || fail "T2: 해소 안내 누락 — $mo_out"

# T3 — 허용 집합 밖 파일(x.txt)이 함께 충돌하면 멈춘다.
mo_ct_diverge ct3 x
mo_archive ct3
[[ "$mo_rc" -ne 0 ]] && pass "T3: 허용 밖 파일이 섞인 충돌은 rc≠0 이다" || fail "T3: rc=0 — $mo_out"
[[ "$mo_out" == *"x.txt"* ]] \
  && pass "T3: git 충돌 출력(x.txt 줄)을 낸다" || fail "T3: git 충돌 출력 누락 — $mo_out"
[[ "$mo_out" != *"충돌은 해결했으나"* && "$mo_out" != *"병합 결과 반영 실패"* && "$mo_out" != *"해결했습니다"* ]] \
  && pass "T3: 자동 해소 분기에 들어가지 않는다" || fail "T3: 허용 밖 파일이 섞였는데 자동 해소를 시도했다 — $mo_out"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true

# T4 — CURRENT_TASK.md·stage_metrics.tsv·FUTURE_REQUESTS.md·verify-evidence 네 파일 동시 충돌(2026-11-01 실사례 조합)이 모두 해소된다.
mo_ct_diverge ct4 ve
# merge-tree 는 충돌이 있으면 exit 1 이다 — 충돌이 기대값이므로 그 exit 는 받아 둔다.
mo_conf="$( { git -C "$REPO" merge-tree --write-tree --name-only main fr/ct4 || true; } | sed -n '2,/^$/p' | sed '/^$/d' | LC_ALL=C sort)"
mo_conf_want="$(printf '%s\n' CURRENT_TASK.md "$mo_sm" "$mo_idx" "$mo_ve" | LC_ALL=C sort)"
[[ "$mo_conf" == "$mo_conf_want" ]] \
  && pass "T4: 충돌 집합이 실사례와 같은 네 파일이다" || fail "T4: 충돌 집합이 다르다 — $mo_conf"
mo_ve_fr="$(git -C "$REPO" show fr/ct4:"$mo_ve")"
mo_archive ct4
[[ "$mo_rc" -eq 0 ]] && pass "T4: 네 파일 동시 충돌 발행이 rc=0 이다" || fail "T4: rc=$mo_rc — $mo_out"
[[ "$mo_out" == *"verify-evidence 충돌을 발행 줄기 쪽으로 해결했습니다"* && "$mo_out" == *"CURRENT_TASK.md 충돌을 main 쪽"* \
   && "$mo_out" == *"stage_metrics.tsv 충돌을 줄 합집합으로 해결했습니다"* && "$mo_out" == *"FUTURE_REQUESTS.md 충돌을 행 집합 병합으로 해결했습니다"* ]] \
  && pass "T4: 네 해소 안내가 모두 있다" || fail "T4: 해소 안내 누락 — $mo_out"
[[ "$(git -C "$REPO" show main:"$mo_ve")" == "$mo_ve_fr" ]] \
  && pass "T4: main 의 verify-evidence 가 발행 줄기 쪽 내용이다" || fail "T4: verify-evidence 가 fr 쪽 내용이 아니다"
git -C "$REPO" show main:"$mo_idx" | grep -q '| fr-ct4 |' && git -C "$REPO" show main:"$mo_idx" | grep -q '| main-ct4 |' \
  && pass "T4: 인덱스에 양쪽 신규 행이 남는다" || fail "T4: 인덱스 행 누락"
[[ "$mo_out" != *"Automatic merge failed"* && "$mo_out" != *"자동 병합이 실패했습니다"* && "$mo_out" != *"CONFLICT"* ]] \
  && pass "T4: 해소 성공 출력에 git 실패 문구가 없다" || fail "T4: git 실패 문구가 새어 나왔다 — $mo_out"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true  # 실패했을 때 다음 케이스로 번지지 않게 한다

# T5 — fr 쪽이 verify-evidence 를 지운 충돌(stage 3 없음)은 멈춘다.
mo_ct_diverge ct5 vedel
mo_archive ct5
[[ "$mo_rc" -ne 0 ]] && pass "T5: 발행 줄기 쪽 증거가 없는 충돌은 rc≠0 이다" || fail "T5: rc=0 — $mo_out"
[[ "$mo_out" == *"verify-evidence 발행 줄기 쪽 버전이 없어"* && "$mo_out" != *"해결했습니다"* ]] \
  && pass "T5: 사유를 내고 자동 해소하지 않는다" || fail "T5: 자동 해소를 시도했거나 사유 누락 — $mo_out"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true

# T6 — verify-evidence 단독 충돌도 자동 해소 분기에 들어간다 (change spec 2026-11-02-0740 D2 의 새 진입 항).
mo_ct_diverge ct6 veonly
mo_ve_fr="$(git -C "$REPO" show fr/ct6:"$mo_ve")"
mo_archive ct6
[[ "$mo_rc" -eq 0 && "$mo_out" == *"verify-evidence 충돌을 발행 줄기 쪽으로 해결했습니다"* ]] \
  && pass "T6: verify-evidence 단독 충돌이 자동 해소된다" || fail "T6: rc=$mo_rc — $mo_out"
[[ "$(git -C "$REPO" show main:"$mo_ve")" == "$mo_ve_fr" ]] \
  && pass "T6: main 의 verify-evidence 가 발행 줄기 쪽 내용이다" || fail "T6: verify-evidence 가 fr 쪽 내용이 아니다"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true

# T1b — main 이 CURRENT_TASK.md 를 삭제하고 fr 이 수정한 delete/modify 충돌은 stage 2 가 없어 멈춘다.
if ! grep -qx '대기 중' "$REPO/CURRENT_TASK.md" 2>/dev/null; then
  git -C "$REPO" checkout -q HEAD -- CURRENT_TASK.md 2>/dev/null || true
  sed -i 's/^구현 중$/대기 중/' "$REPO/CURRENT_TASK.md"
  git -C "$REPO" add -A
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "main: CURRENT_TASK 기준 복구 (ct1b)" || true
fi
bash "$PROMOTE_SH" --short-title ct1b --size large --source-fr - >/dev/null 2>&1
sed -i 's/^대기 중$/아카이브 보류/' "$REPO/.worktrees/ct1b/CURRENT_TASK.md"
printf 'work-ct1b\n' > "$REPO/.worktrees/ct1b/src-ct1b.txt"
git -C "$REPO/.worktrees/ct1b" add -A
git -C "$REPO/.worktrees/ct1b" commit -q -m "구현: ct1b"
git -C "$REPO" rm -q CURRENT_TASK.md
RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$REPO" commit -q -m "main: CURRENT_TASK 삭제 (ct1b)"
mo_archive ct1b
[[ "$mo_rc" -ne 0 ]] && pass "T1b: main 이 삭제한 CURRENT_TASK.md 충돌은 rc≠0 이다" || fail "T1b: rc=0 — $mo_out"
[[ "$mo_out" == *"CURRENT_TASK.md main 쪽 버전이 없어"* ]] \
  && pass "T1b: stage 2 부재 사유로 멈춘다" || fail "T1b: 멈춤 사유 누락 — $mo_out"
git -C "$REPO" merge --abort >/dev/null 2>&1 || true

# T8 — no-fr 에서 cleanup 커밋 이후 push 가 실패한 뒤의 재실행 (D3)
#
# cleanup 커밋은 Status 를 '대기 중' 으로, short-title 을 '-' 로 되돌린다. 재실행은 두
# 게이트(Status·seal)를 각각 자기 플래그로만 우회할 수 있어야 하고, 한 플래그만으로는
# 완료되지 않아야 한다. 최초 실패를 cleanup 이후로 만들기 위해 로컬 bare 원격의
# pre-receive hook 이 push 를 거부한다.
echo "== archive.sh — D3 no-fr cleanup 이후 재실행 (T8) =="
NF="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
NF="$(cd "$NF" && pwd -P)"
_ast_cleanup+=("$NF")
NFR="$NF/w"; NFO="$NF/o.git"
mkdir -p "$NFR/rd-workflow"
cp -R "$SCRIPT_DIR/.." "$NFR/rd-workflow/scripts"
git -C "$NFR" init -q -b main
git -C "$NFR" config user.email t@t && git -C "$NFR" config user.name t
mkdir -p "$NFR/rd-workflow-workspace/.lifecycle" "$NFR/rd-workflow-workspace/backlog/items"
cp "$SCRIPT_DIR/../../../.gitignore" "$NFR/.gitignore"
bash -c "source '$SCRIPT_DIR/_lifecycle_common.sh'; emit_current_task_baseline" > "$NFR/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$NFR/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$NFR/REQUEST.md"
git -C "$NFR" add -A && git -C "$NFR" commit -q -m seed
git init -q --bare "$NFO"
git -C "$NFR" remote add origin "$NFO"
git -C "$NFR" push -q origin main
( cd "$NFR" && bash rd-workflow/scripts/rd task set-title nofr \
  && bash rd-workflow/scripts/rd task set-base HEAD \
  && bash rd-workflow/scripts/rd task set-status "구현 중" ) >/dev/null 2>&1
printf 'code\n' > "$NFR/src.txt"
git -C "$NFR" add -A && git -C "$NFR" commit -q -m "구현"
nf_archive() {  # <인자...> — 출력은 nf_out, 종료코드는 nf_rc
  nf_rc=0
  nf_out="$( cd "$NFR" && bash rd-workflow/scripts/lifecycle/archive.sh "$@" 2>&1 )" || nf_rc=$?
}
nf_task_field() { sed -n "s/^$1=//p" "$NFR/rd-workflow-workspace/.lifecycle/task-state"; }

printf '#!/bin/sh\necho "pre-receive 거부(테스트)" >&2\nexit 1\n' > "$NFO/hooks/pre-receive"
chmod +x "$NFO/hooks/pre-receive"

# 최초 발행: 유효 seal 도 보류 Status 도 없는 fixture 라 두 플래그가 모두 필요하다.
nf_archive --force-skip-review-check "테스트" --allow-status-mismatch "테스트"
[[ "$nf_rc" -ne 0 && "$nf_out" == *"main push 실패"* && "$nf_out" == *"pre-receive 거부(테스트)"* ]] \
  && pass "T8: 최초 발행이 push 거부(pre-receive)로 실패한다" || fail "T8: 최초 실패 양상이 다르다 rc=$nf_rc — $nf_out"
[[ "$(git -C "$NFR" log -1 --format=%s)" == *"archive nofr metadata 정리"* && "$(nf_task_field status)" == "대기 중" && "$(nf_task_field short-title)" == "-" ]] \
  && pass "T8: 실패 시점에 cleanup 커밋이 이미 있다(Status=대기 중, short-title=-)" || fail "T8: cleanup 이후 실패가 아니다 — $(git -C "$NFR" log -1 --format=%s)"
[[ "$(git -C "$NFO" rev-parse main)" != "$(git -C "$NFR" rev-parse main)" ]] \
  && pass "T8: 원격 main 은 아직 cleanup 커밋을 받지 못했다" || fail "T8: 원격이 이미 따라왔다"

# 재실행 — short-title 이 '-' 이면 slug 단계가 먼저 set-title 을 요구한다. 이 단계는 이 줄기의 변경이 아니다.
nf_archive
[[ "$nf_rc" -ne 0 && "$nf_out" == *"rd task set-title"* ]] \
  && pass "T8: cleanup 직후(short-title=-) 재실행은 set-title 안내로 멈춘다(기존 동작)" || fail "T8: 예상 밖 rc=$nf_rc — $nf_out"
( cd "$NFR" && bash rd-workflow/scripts/rd task set-title nofr ) >/dev/null 2>&1

# 미커밋 상태(HEAD 의 short-title 은 '-')로도 같은 안내에 닿는다 — 판독은 워킹트리가 아니라 HEAD.
nf_archive --force-dirty
[[ "$nf_rc" -ne 0 && "$nf_out" == *"cleanup 이후 상태"* ]] \
  && pass "T8: HEAD(short-title=-, 대기 중) 재실행 → cleanup 이후 안내" || fail "T8: cleanup 안내 누락 rc=$nf_rc — $nf_out"

git -C "$NFR" add -A && git -C "$NFR" commit -q -m "chore: set-title 복구"
nf_head_before="$(git -C "$NFR" rev-parse HEAD)"

nf_archive
[[ "$nf_rc" -ne 0 && "$nf_out" == *"cleanup 이후 상태"* && "$nf_out" == *"--force-skip-review-check"* && "$nf_out" == *"--allow-status-mismatch"* ]] \
  && pass "T8: 플래그 없음 → cleanup 이후 안내와 두 플래그 이름" || fail "T8: 플래그 없음 안내 누락 rc=$nf_rc — $nf_out"
nf_archive --force-skip-review-check "테스트"
[[ "$nf_rc" -ne 0 && "$nf_out" == *"cleanup 이후 상태"* && "$nf_out" != *"종결 마커 검증 실패"* ]] \
  && pass "T8: force 만 → 같은 cleanup 안내로 거부(seal 우회가 Status 를 우회하지 않는다)" || fail "T8: force 만 — rc=$nf_rc — $nf_out"
nf_archive --allow-status-mismatch "테스트"
[[ "$nf_rc" -ne 0 && "$nf_out" == *"종결 마커 검증 실패"* && "$nf_out" != *"cleanup 이후 상태"* ]] \
  && pass "T8: allow 만 → Status 통과 후 seal 검사 문구로 거부" || fail "T8: allow 만 — rc=$nf_rc — $nf_out"
[[ "$(git -C "$NFR" rev-parse HEAD)" == "$nf_head_before" ]] \
  && pass "T8: 거부된 재실행은 HEAD 를 바꾸지 않는다" || fail "T8: 거부인데 HEAD 가 바뀌었다"

rm -f "$NFO/hooks/pre-receive"
nf_archive --force-skip-review-check "테스트" --allow-status-mismatch "테스트"
[[ "$nf_rc" -eq 0 ]] && pass "T8: 두 플래그(hook 제거) → 재실행이 완료된다" || fail "T8: 두 플래그인데 실패 rc=$nf_rc — $nf_out"
[[ "$(git -C "$NFO" rev-parse main)" == "$(git -C "$NFR" rev-parse main)" ]] \
  && pass "T8: 원격 main 이 로컬 main 을 따라왔다" || fail "T8: push 되지 않았다"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
DONE=1
[[ $FAIL -eq 0 ]]
