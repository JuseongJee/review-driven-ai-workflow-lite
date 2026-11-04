#!/usr/bin/env bash
# test_archive_merge_position.sh — seal 뒤 main 병합 위치 변경(change spec D2~D5)의 archive 경로 통합 테스트.
# 케이스(T2·T3+T4·T4s·T3c·T8·T8b·T8c·T9)는 promote → 실제 리뷰 세션 → seal → archive.sh 를 그대로 거친다.
# 발행 게이트 자체를 검증하므로 단위 테스트로 대신할 수 없다(케이스당 약 7초).
set -euo pipefail
trap 'ec=$?; echo "  FAIL: 스위트가 line ${LINENO} 에서 rc=${ec} 로 중단됐습니다 (조용한 중단)" >&2' ERR
DONE=0
_cleanup=()
_suite_on_exit() {
  local _ec=$? _d
  for _d in ${_cleanup[@]+"${_cleanup[@]}"}; do [[ -z "$_d" ]] || rm -rf "$_d"; done
  [[ "$DONE" == 1 ]] || echo "  FAIL: 스위트가 결과줄 없이 rc=${_ec} 로 중단됐습니다 (조용한 중단 — 마지막 PASS 줄 다음을 보십시오)" >&2
}
trap _suite_on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RDW_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"          # rd-workflow 디렉터리
GITIGNORE_SRC="$RDW_SRC/../.gitignore"

# 실제 herdr 호출 차단 — promote.sh 가 session_launch 를 부른다 (test_archive_worktree.sh 와 같은 사유).
export HERDR_ENV=
export HC_TERMINAL_ID=
export RD_CHILD_SESSION=1
# 바깥 셸의 값을 물려받으면 fixture 가 아니라 바깥 저장소를 고친다 (2026-10-29 사고).
unset project_root TASK_STATE_PATH

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

T0=$SECONDS
TMP="$(mktemp -d)" || { echo "test_archive_merge_position.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_archive_merge_position.sh: 임시 디렉터리 검증 실패" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
_cleanup+=("$TMP")

# --- seed: promote 전 저장소 한 번 ---
SEED="$TMP/seed"
mkdir -p "$SEED/rd-workflow"
cp -R "$RDW_SRC/." "$SEED/rd-workflow/"
if [[ -f "$GITIGNORE_SRC" ]]; then
  cp "$GITIGNORE_SRC" "$SEED/.gitignore"
else
  printf '.worktrees/\nrd-workflow-workspace/.lifecycle/review-skip-audit.log\n' > "$SEED/.gitignore"
fi
git -C "$SEED" init -q -b main
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
mkdir -p "$SEED/rd-workflow-workspace/.lifecycle" "$SEED/rd-workflow-workspace/backlog/items" "$SEED/rd-workflow-workspace/backlog/request-archive"
bash -c "source '$SEED/rd-workflow/scripts/lifecycle/_lifecycle_common.sh'; emit_current_task_baseline" > "$SEED/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$SEED/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$SEED/REQUEST.md"
printf 'line1\nline2\nline3\n' > "$SEED/shared.txt"
printf 'u1\n' > "$SEED/unrelated.txt"
printf '# short_title\tfrom_status\tto_status\tepoch\n' > "$SEED/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m seed

close_session() {
  local t
  t="$(mktemp "$TMP/out.XXXXXXXX")" || return 1
  awk '/^## Status$/{print; getline; print "closed"; next} {print}' "$1/SESSION.md" > "$t" && cat "$t" > "$1/SESSION.md"
  t="$(mktemp "$TMP/out.XXXXXXXX")" || return 1
  awk '/^## Open Issues$/{s=1; print; next} s && /^## /{s=0} s && $0=="-"{print "- 없음"; next} {print}' "$1/CHECKPOINT.md" > "$t" && cat "$t" > "$1/CHECKPOINT.md"
}

# mk_case <이름> [seal 전 훅 함수] — R·B·W·SES 를 전역으로 둔다. 훅은 구현 커밋·verify_record 뒤, seal 앞에 실행.
mk_case() {
  local name="$1" hook="${2:-}" st
  R="$TMP/$name"; B="$TMP/$name.bare"
  cp -R "$SEED" "$R"
  git init --bare -q -b main "$B"
  git -C "$R" remote add origin "$B"
  git -C "$R" push -q -u origin main
  ( cd "$R" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title t --size large --source-fr - ) >/dev/null 2>&1 || true
  W="$R/.worktrees/t"
  [[ -d "$W" ]] || { fail "$name: promote 가 worktree 를 만들지 못했습니다"; return 1; }
  printf 'line1\nline2-FR\nline3\n' > "$W/shared.txt"
  printf 'fr-only\n' > "$W/fr.txt"
  git -C "$W" add -A && git -C "$W" commit -q -m "구현"
  ( cd "$W" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff ) >/dev/null 2>&1 || true
  SES="$(ls -d "$W"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | tail -1)"
  [[ -n "$SES" ]] || { fail "$name: 리뷰 세션을 만들지 못했습니다"; return 1; }
  close_session "$SES"
  ( cd "$W" && bash rd-workflow/scripts/verify_record.sh -- true ) >/dev/null 2>&1 || { fail "$name: verify_record 실패"; return 1; }
  [[ -z "$hook" ]] || "$hook"
  SEAL_OUT="$( cd "$W" && bash rd-workflow/scripts/rd review seal "$SES" 2>&1 )" && SEAL_RC=0 || SEAL_RC=$?
  [[ "$SEAL_RC" -eq 0 ]] || { fail "$name: seal 실패 rc=${SEAL_RC}: ${SEAL_OUT}"; return 1; }
  for st in "구현 중" "검증 중" "diff review 대기" "아카이브 보류"; do
    ( cd "$W" && bash rd-workflow/scripts/rd task set-status "$st" ) >/dev/null 2>&1 || { fail "$name: set-status ${st} 실패"; return 1; }
  done
  mkdir -p "$W/rd-workflow-workspace/backlog/request-archive"
  cp "$W/REQUEST.md" "$W/rd-workflow-workspace/backlog/request-archive/2026-11-04-0000-t.md"
  git -C "$W" add -A && git -C "$W" commit -q -m "docs: REQUEST 아카이브 + seal"
  SEAL_FILE="$(ls "$W"/rd-workflow-workspace/.lifecycle/review-seals/*.seal | head -1)"
}

archive_main() {  # 출력은 AOUT, rc 는 ARC
  AOUT="$( cd "$R" && bash rd-workflow/scripts/lifecycle/archive.sh --task t 2>&1 )" && ARC=0 || ARC=$?
}
main_commit() {  # main_commit <msg> — 기본 체크아웃에서 커밋·push
  git -C "$R" add -A && git -C "$R" commit -q -m "$1" && git -C "$R" push -q origin main
}
mark() {  # mark <조건 rc> <라벨> [실패 시 출력]
  if [[ "$1" -eq 0 ]]; then pass "$2"; else fail "$2 ${3:+— $3}"; fi
}
has() { printf '%s' "$1" | grep -qF -- "$2"; }
state_hashes() {
  printf '%s|%s|%s' "$(git -C "$R" rev-parse HEAD)" \
    "$(git -C "$R" ls-files --stage -z | git hash-object --stdin)" \
    "$(git -C "$R" status --porcelain=v1 -z | git hash-object --stdin)"
}

echo "== T2: main 무관 변경 → fr 에 main 병합 → archive 통과"
mk_case t2 && {
  tree_marker="$(grep '^tree-hash=' "$SEAL_FILE" | cut -d= -f2)"
  tree_full="$( cd "$R" && bash -c "source rd-workflow/scripts/_state_common.sh; rd_protected_tree_hash fr/t" )"
  [[ "$tree_marker" == "$tree_full" ]]; mark $? "T2-old: 마커 tree-hash 가 전체 보호 트리 해시와 같음" "marker=${tree_marker} full=${tree_full}"
  grep -q '^fr-changes-hash=' "$SEAL_FILE"; mark $? "T2: 한정 마커에 fr-changes-hash 가 있음"
  printf 'u2-main\n' >> "$R/unrelated.txt"; main_commit "main: 무관 변경"
  ( cd "$W" && git merge --no-edit main ) >/dev/null 2>&1
  archive_main
  [[ "$ARC" -eq 0 ]]; mark $? "T2: archive rc=0" "rc=${ARC}: ${AOUT}"
  [[ "$(git -C "$B" show main:shared.txt)" == $'line1\nline2-FR\nline3' ]]; mark $? "T2: 원격 main 의 shared.txt 가 fr 내용"
}

echo "== T3+T4: 코드 충돌 사전 감지, 손 병합 거부"
mk_case t34 && {
  printf 'line1\nline2-MAIN\nline3\n' > "$R/shared.txt"; main_commit "main: shared 충돌 변경"
  before="$(state_hashes)"; origin_before="$(git -C "$B" rev-parse main)"
  archive_main
  after="$(state_hashes)"
  [[ "$ARC" -ne 0 ]]; mark $? "T3: archive rc≠0" "rc=${ARC}"
  rc=0; { has "$AOUT" "코드 충돌이 있습니다" && has "$AOUT" "archive:     - shared.txt" && has "$AOUT" 'set-status "구현 중"'; } || rc=1
  mark $rc "T3: 충돌 안내(첫 줄·경로·set-status 안내)" "$AOUT"
  [[ "$before" == "$after" && ! -e "$R/.git/MERGE_HEAD" ]]; mark $? "T3: main HEAD·인덱스·워킹트리 불변, MERGE_HEAD 없음" "before=${before} after=${after}"
  # T4: 기본 체크아웃이 손으로 병합 → 리뷰하지 않은 해결
  ( cd "$R" && git merge fr/t ) >/dev/null 2>&1 || true
  printf 'line1\nline2-UNREVIEWED\nline3\nsneaky\n' > "$R/shared.txt"
  git -C "$R" add shared.txt && git -C "$R" commit -q --no-edit
  m_oid="$(git -C "$R" rev-parse --short HEAD)"; m_p1="$(git -C "$R" rev-parse HEAD^1)"
  archive_main
  [[ "$ARC" -ne 0 ]]; mark $? "T4: archive rc≠0" "rc=${ARC}"
  rc=0; { has "$AOUT" "main 의 병합 커밋 ${m_oid} 에 리뷰하지 않은 변경이 있습니다" && has "$AOUT" "archive:     - shared.txt" && has "$AOUT" "git reset --keep ${m_p1}"; } || rc=1
  mark $rc "T4: D5 안내(OID·경로·reset --keep)" "$AOUT"
  [[ "$(git -C "$B" rev-parse main)" == "$origin_before" ]]; mark $? "T4: 원격 main OID 불변"
}

echo "== T4s: 손 병합이 ignore=all submodule 의 gitlink 만 바꿈 → 거부"
mk_case t4s && {
  printf '[submodule "s"]\n\tpath = s\n\turl = ../s.git\n\tignore = all\n' > "$R/.gitmodules"
  git -C "$R" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,s"
  # main_commit 의 add -A 는 워킹트리에 없는 s 를 삭제로 올리므로 쓰지 않는다
  git -C "$R" add .gitmodules && git -C "$R" commit -q -m "main: ignore=all submodule 추가" && git -C "$R" push -q origin main
  ( cd "$W" && git merge --no-edit main ) >/dev/null 2>&1
  origin_before="$(git -C "$B" rev-parse main)"
  # 기본 체크아웃이 손으로 병합하면서 리뷰하지 않은 gitlink 이동을 섞는다
  ( cd "$R" && git merge --no-ff --no-commit fr/t ) >/dev/null 2>&1 || true
  git -C "$R" update-index --cacheinfo "160000,2222222222222222222222222222222222222222,s"
  git -C "$R" commit -q --no-edit
  m_oid="$(git -C "$R" rev-parse --short HEAD)"
  archive_main
  rc=0; { [[ "$ARC" -ne 0 ]] && has "$AOUT" "main 의 병합 커밋 ${m_oid} 에 리뷰하지 않은 변경이 있습니다" && has "$AOUT" "archive:     - s"; } || rc=1
  mark $rc "T4s: rc≠0 이고 D5 안내에 gitlink 경로 s" "rc=${ARC}: ${AOUT}"
  [[ "$(git -C "$B" rev-parse main)" == "$origin_before" ]]; mark $? "T4s: 원격 main OID 불변"
}

echo "== T3c: 기록 경로만 충돌 → 통과"
_hook_t3c() {
  printf 't\t구현 중\t검증 중\t1790000001\n' >> "$W/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
  git -C "$W" add -A && git -C "$W" commit -q -m "fr: metrics"
  ( cd "$W" && bash rd-workflow/scripts/verify_record.sh -- true ) >/dev/null 2>&1
}
mk_case t3c _hook_t3c && {
  printf 'm\t구현 중\t검증 중\t1790000002\n' >> "$R/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"; main_commit "main: metrics"
  archive_main
  [[ "$ARC" -eq 0 ]]; mark $? "T3c: archive rc=0 (기록 경로 충돌은 D4 에 걸리지 않음)" "rc=${ARC}: ${AOUT}"
}

echo "== T8: main 에 병합 커밋이 이미 있음(재실행 경로) → 통과"
mk_case t8 && {
  ( cd "$R" && git merge --no-ff fr/t -m "merge: t (archive)" ) >/dev/null 2>&1
  archive_main
  [[ "$ARC" -eq 0 ]]; mark $? "T8: archive rc=0" "rc=${ARC}: ${AOUT}"
}

echo "== T8b: 옛 마커(필드 없음) + fast-forward → 통과"
mk_case t8b && {
  grep -v '^fr-changes-hash=' "$SEAL_FILE" > "$SEAL_FILE.new" && cat "$SEAL_FILE.new" > "$SEAL_FILE" && rm -f "$SEAL_FILE.new"
  git -C "$W" add -A && git -C "$W" commit -q -m "옛 마커로 되돌림"
  ( cd "$R" && git merge --ff-only fr/t ) >/dev/null 2>&1
  archive_main
  [[ "$ARC" -eq 0 ]]; mark $? "T8b: archive rc=0" "rc=${ARC}: ${AOUT}"
}

echo "== T8c: 한정 마커 + fast-forward → 차단"
mk_case t8c && {
  ( cd "$R" && git merge --ff-only fr/t ) >/dev/null 2>&1
  archive_main
  rc=0; { [[ "$ARC" -ne 0 ]] && has "$AOUT" "fast-forward"; } || rc=1; mark $rc "T8c: rc≠0 이고 fast-forward 안내" "rc=${ARC}: ${AOUT}"
}

echo "== T9: 기본 브랜치를 정할 수 없으면 전체 트리 기준 seal"
_hook_t9() { printf '{\n  "default_branch": "nope"\n}\n' > "$W/rd-workflow/config/workflow.json"; }
# 훅이 만든 상태에서 seal 이 통과해야 하므로 mk_case 의 seal 결과(SEAL_OUT)를 그대로 본다.
mk_case t9 _hook_t9 && {
  ! grep -q '^fr-changes-hash=' "$SEAL_FILE"; mark $? "T9: 마커에 fr-changes-hash 없음"
  has "$SEAL_OUT" "전체 트리 기준"; mark $? "T9: 전체 트리 기준 봉인 안내" "$SEAL_OUT"
}

echo ""
echo "총 실행 시간: $((SECONDS-T0))초"
echo "결과: PASS=${PASS} FAIL=${FAIL}"
DONE=1
[[ "$FAIL" -eq 0 ]]
