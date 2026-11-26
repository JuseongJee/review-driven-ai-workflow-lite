#!/usr/bin/env bash
# test_seal_team_pr_subst.sh — 팀 PR merge 뒤 gitlink 치환(spec 3.1·D4·D7 (나)(다))을 검증한다.
#   rd_team_pr_preserved — merge 결과가 리뷰한 head 를 충돌·손 편집 없이 담았는가
#   rd_gitlink_seal_oid  — 두 seal 해시(rd_protected_tree_hash·rd_fr_changes_hash)가 셀 gitlink 커밋
# 모든 저장소는 mktemp -d 아래에 만든다. 팀 쪽 커밋은 plumbing(commit-tree)으로 만들어 reflog 를 남기지 않는다.
# bash 3.2 호환.
set -uo pipefail

export HERDR_ENV=
export HC_TERMINAL_ID=
export ORCA_AGENT_SESSION_ID= ORCA_TERMINAL_HANDLE=
export RD_CHILD_SESSION=1
unset project_root TASK_STATE_PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/hooks/_guard_common.sh"
STATE="$SCRIPT_DIR/_state_common.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (기대=[$2] 실제=[$3])"; fi; }
assert_ne() { if [[ -n "$2" && -n "$3" && "$2" != "$3" ]]; then pass "$1"; else fail "$1 (같거나 빈 값: [$2] [$3])"; fi; }

TROOT="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
trap 'rm -rf "$TROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REC="rd-workflow-workspace/.lifecycle/team-prs.tsv"

# mkc <repo> <f 값> <g 값> <commit-tree 인자...> — 파일 f·g 두 개짜리 커밋을 만들고 OID 를 출력한다.
mkc() {
  local repo="$1" fv="$2" gv="$3" bf bg t
  shift 3
  bf="$(printf '%s\n' "$fv" | git -C "$repo" hash-object -w --stdin)"
  bg="$(printf '%s\n' "$gv" | git -C "$repo" hash-object -w --stdin)"
  t="$(printf '100644 blob %s\tf\n100644 blob %s\tg\n' "$bf" "$bg" | git -C "$repo" mktree)"
  git -C "$repo" commit-tree "$t" -m "f=$fv g=$gv" "$@"
}

# preserved <repo> <M> <H> <commits> — "rc|원인 코드"
preserved() {
  local out rc
  out="$( source "$STATE" >/dev/null 2>&1 || exit 99; rd_team_pr_preserved "$@" 2>/dev/null )"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

echo "--- rd_team_pr_preserved ---"
P="$(mktemp -d "$TROOT/p.XXXXXX")" || { echo "mktemp 실패" >&2; exit 1; }
git -C "$P" init -q -b main
B0="$(mkc "$P" x 1)"

# squash: 팀 쪽 무관 변경(g) 뒤 head(f) 를 squash → 보존
H="$(mkc "$P" y 1 -p "$B0")"; U="$(mkc "$P" x 2 -p "$B0")"; M="$(mkc "$P" y 2 -p "$U")"
assert_eq "t_preserved_squash: 무관 변경 뒤 squash → 보존" "0|" "$(preserved "$P" "$M" "$H" "")"

# t_preserved_conflict: 같은 줄 충돌을 팀 값으로 해소한 merge
U="$(mkc "$P" w 1 -p "$B0")"; M="$(mkc "$P" w 1 -p "$U" -p "$H")"
assert_eq "t_preserved_conflict: 충돌 해소 merge → content-differs" "1|content-differs" "$(preserved "$P" "$M" "$H" "")"

# t_preserved_markers_committed: merge-tree 의 충돌 마커 트리를 그대로 커밋
MT="$(git -C "$P" merge-tree --write-tree "$U" "$H" | head -n 1)"
M="$(git -C "$P" commit-tree "$MT" -p "$U" -p "$H" -m markers)"
assert_eq "t_preserved_markers_committed: 준비 — 트리가 merge-tree 결과와 같음" "$MT" "$(git -C "$P" rev-parse "$M^{tree}")"
assert_eq "t_preserved_markers_committed: 마커 트리 커밋 → content-differs" "1|content-differs" "$(preserved "$P" "$M" "$H" "")"

# t_preserved_hand_edit: 충돌 없는 merge 결과에 손으로 한 줄을 더함
U="$(mkc "$P" x 2 -p "$B0")"; M="$(mkc "$P" "$(printf 'y\nhand')" 2 -p "$U" -p "$H")"
assert_eq "t_preserved_hand_edit: 손 편집 merge → content-differs" "1|content-differs" "$(preserved "$P" "$M" "$H" "")"

# t_preserved_rebase_k: x→y, y→z 커밋 2개를 무관 커밋 뒤에 cherry-pick 한 rebase merge
H1="$(mkc "$P" y 1 -p "$B0")"; H2="$(mkc "$P" z 1 -p "$H1")"
U="$(mkc "$P" x 2 -p "$B0")"; C1="$(mkc "$P" y 2 -p "$U")"; C2="$(mkc "$P" z 2 -p "$C1")"
git -C "$P" merge-tree --write-tree "$C1" "$H2" >/dev/null 2>&1
assert_eq "t_preserved_rebase_k: 준비 — M^ 기준 merge-tree 는 충돌(rc 1)" "1" "$?"
assert_eq "t_preserved_rebase_k: commits=2 → M~2 로 보존" "0|" "$(preserved "$P" "$C2" "$H2" 2)"
assert_eq "t_preserved_rebase_k: commits 없음 → base-unknown" "1|base-unknown" "$(preserved "$P" "$C2" "$H2" "")"

# 객체 없음 → 판정 불가
assert_eq "t_preserved_missing: 없는 merge 커밋 → objects-missing" "2|objects-missing" \
  "$(preserved "$P" 1111111111111111111111111111111111111111 "$H2" "")"

# t_preserved_laundered_on_head: H 위 손 편집 X 를 그대로 담은 M — T(=X) 가 이미 H 를 포함하므로 보존이 아님
X="$(mkc "$P" y EVIL -p "$H")"
XT="$(git -C "$P" rev-parse "$X^{tree}")"
M="$(git -C "$P" commit-tree "$XT" -p "$X" -m launder1)"
assert_eq "t_preserved_laundered_on_head: 부모 1개(X) → content-differs" "1|content-differs" "$(preserved "$P" "$M" "$H" "")"
M="$(git -C "$P" commit-tree "$XT" -p "$X" -p "$H" -m launder2)"
assert_eq "t_preserved_laundered_on_head: 부모 2개(X, H) → content-differs" "1|content-differs" "$(preserved "$P" "$M" "$H" "")"

echo "--- rd_gitlink_seal_oid (두 seal 해시) ---"
# mk_fix — superproject R(main: gitlink=B0) + submodule s(팀 저장소 clone). fr/x 체크아웃.
#   전역: R, S(=R/s), SB0, SH(head), SU(팀 무관 커밋), SM(squash 결과)
mk_fix() {
  local team
  team="$(mktemp -d "$TROOT/team.XXXXXX")" || { echo "mktemp 실패" >&2; exit 1; }
  git -C "$team" init -q -b main
  printf 'x\n' > "$team/f"; printf '1\n' > "$team/g"
  git -C "$team" add -A; git -C "$team" commit -qm base
  R="$(mktemp -d "$TROOT/super.XXXXXX")" || { echo "mktemp 실패" >&2; exit 1; }
  git -C "$R" init -q -b main
  echo a > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm seed
  git -C "$R" -c protocol.file.allow=always submodule add -q "$team" s >/dev/null 2>&1
  git -C "$R" commit -qm "sub"
  git -C "$R" checkout -q -b fr/x
  S="$R/s"
  SB0="$(git -C "$S" rev-parse HEAD)"
  SH="$(mkc "$S" y 1 -p "$SB0")"
  git -C "$S" update-ref refs/heads/pr "$SH"
  SU="$(mkc "$S" x 2 -p "$SB0")"
  SM="$(mkc "$S" y 2 -p "$SU")"
}

# commit_state <gitlink> <기록 줄|""> — fr/x 에 gitlink·기록 파일을 맞춘 커밋을 남기고 OID 를 출력
commit_state() {
  git -C "$R" update-index --cacheinfo "160000,$1,s"
  mkdir -p "$R/rd-workflow-workspace/.lifecycle"
  if [[ -n "$2" ]]; then
    printf 'path\trepo\tbranch\tbase\turl\thead-oid\tstate\tmerged-oid\tcommits\n%s\n' "$2" > "$R/$REC"
    git -C "$R" add "$REC"
  elif [[ -f "$R/$REC" ]]; then
    git -C "$R" rm -q "$REC"
  fi
  git -C "$R" commit -qm "state $1" --allow-empty
  git -C "$R" rev-parse HEAD
}
# rline <head> <state> <merged> <commits>
rline() { printf 's\tteam\tpr-x\tmain\thttps://example.invalid/pr/1\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"; }

ph() { ( project_root="$R"; export project_root; cd "$R"; source "$GUARD" || exit 99; rd_protected_tree_hash "$1" ${2:+"$2"} ) 2>/dev/null; }
fh() { ( project_root="$R"; export project_root; cd "$R"; source "$GUARD" || exit 99; rd_fr_changes_hash "$1" "${2:-main}" ) 2>/dev/null; }

mk_fix
A="$(commit_state "$SH" "")"
PA="$(ph "$A")"; FA="$(fh "$A")"
[[ -n "$PA" && -n "$FA" ]] || fail "준비: 커밋 A 해시 계산 실패 (ph=[$PA] fh=[$FA])"

B="$(commit_state "$SM" "$(rline "$SH" merged "$SM" 1)")"
assert_eq "t_full_hash_subst: 기록 H→M merged 면 전체 해시가 A 와 같음" "$PA" "$(ph "$B")"
assert_eq "t_fr_hash_subst: 기록 H→M merged 면 한정 해시가 A 와 같음" "$FA" "$(fh "$B")"
# 기본 쪽이 이미 H 를 가리키면(merge-base=A) H→M 이동은 변경 없음으로 빠져야 합니다(old·new 양쪽 치환).
assert_eq "t_fr_hash_subst: 기본 쪽 gitlink=H 면 B 의 M 이동은 변경 없음" "$(fh "$A" "$A")" "$(fh "$B" "$A")"

SX="$(mkc "$S" y-hand 2 -p "$SU")"
C="$(commit_state "$SX" "$(rline "$SH" merged "$SX" "")")"
assert_ne "t_seal_forged_record: 손 편집 X 의 위조 기록 → 전체 해시 상이" "$PA" "$(ph "$C")"
assert_ne "t_seal_forged_record: 손 편집 X 의 위조 기록 → 한정 해시 상이" "$FA" "$(fh "$C")"

SM2="$(git -C "$S" commit-tree "$(git -C "$S" rev-parse "$SM^{tree}")" -p "$SU" -m other)"
E="$(commit_state "$SM2" "$(rline "$SH" merged "$SM" 1)")"
assert_ne "t_subst_requires_exact: gitlink M2≠기록 M → 전체 해시 상이" "$PA" "$(ph "$E")"
assert_ne "t_subst_requires_exact: gitlink M2≠기록 M → 한정 해시 상이" "$FA" "$(fh "$E")"

F="$(commit_state "$SM" "$(rline "$SH" open "$SM" 1)")"
assert_ne "t_subst_requires_merged_state: state=open → 전체 해시 상이" "$PA" "$(ph "$F")"
assert_ne "t_subst_requires_merged_state: state=open → 한정 해시 상이" "$FA" "$(fh "$F")"

D1="$(commit_state "$SH" "$(rline "$SH" open - "")")"
D2="$(commit_state "$SH" "$(rline "$SH" closed - 3)")"
assert_eq "t_record_path_excluded: 기록 파일만 다르면 전체 해시 동일" "$(ph "$D1")" "$(ph "$D2")"
assert_eq "t_record_path_excluded: 기록 파일만 다르면 한정 해시 동일" "$(fh "$D1")" "$(fh "$D2")"
assert_eq "t_record_path_excluded: 기록 없는 A 와도 전체 해시 동일" "$PA" "$(ph "$D2")"

# t_hash_record_commit_arg (AC5 단위) — 기록을 지운 자식 Y 의 해시를 기록이 있던 B 기준으로 셉니다(no-fr rebind).
Y="$(commit_state "$SM" "")"
assert_eq "t_hash_record_commit_arg: ph Y B 는 기록 커밋 B 의 치환을 따라 ph B 와 같음" "$(ph "$B")" "$(ph "$Y" "$B")"
assert_ne "t_hash_record_commit_arg: 둘째 인자 없는 ph Y 는 치환이 없어 ph B 와 다름" "$(ph "$B")" "$(ph "$Y")"

# rb <해시> <발행 OID> [기록 커밋] — archive_publish_rebind_check 를 부르고 "rc|stderr" 를 출력합니다(인자 수를 그대로 넘김).
rb() { ( project_root="$R"; export project_root; cd "$R"; source "$GUARD" >/dev/null 2>&1 || exit 99
         archive_publish_rebind_check "$@" 2>&1 >/dev/null; echo "|rc=$?" ); }

# t_rebind_record_blocks_protected_change (AC5b) — 기록 커밋 B 를 넘겨도 Y 위에서 보호 파일(a.txt)을 바꾼 Z 는 막습니다.
# Z 는 plumbing 으로 만들어 작업 트리·브랜치를 바꾸지 않습니다(뒤 케이스의 해시 비교가 a.txt 변경에 기대지 않게).
ZI="$TROOT/z.index"
GIT_INDEX_FILE="$ZI" git -C "$R" read-tree "$Y"
GIT_INDEX_FILE="$ZI" git -C "$R" update-index --cacheinfo "100644,$(printf 'changed\n' | git -C "$R" hash-object -w --stdin),a.txt"
Z="$(git -C "$R" commit-tree "$(GIT_INDEX_FILE="$ZI" git -C "$R" write-tree)" -p "$Y" -m "보호 파일 변경")"
out="$(rb "$(ph "$B")" "$Z" "$B")"
assert_eq "t_rebind_record_blocks_protected_change: rc 1" "rc=1" "${out##*|}"
case "$out" in *"발행 대상이 리뷰된 트리와 다릅니다"*) pass "t_rebind_record_blocks_protected_change: 안내" ;;
  *) fail "t_rebind_record_blocks_protected_change: 안내 없음 — [$out]" ;; esac

# t_rebind_empty_record (AC5b) — PR 기록 없는 A: 두 인자 대조는 통과하는 해시인데, 셋째 인자가 빈 값이면 판정 불가로 막습니다.
assert_eq "t_rebind_empty_record: 준비 — 두 인자 대조는 통과" "rc=0" "$(r="$(rb "$PA" "$A")"; echo "${r##*|}")"
out="$(rb "$PA" "$A" "")"
assert_eq "t_rebind_empty_record: rc 1" "rc=1" "${out##*|}"
case "$out" in *"승인한 커밋을 알 수 없어"*) pass "t_rebind_empty_record: 안내" ;;
  *) fail "t_rebind_empty_record: 안내 없음 — [$out]" ;; esac

# t_preserved_laundered_on_head (seal) — 그 M 을 기록 H→M merged 로 적어도 치환하지 않음
SXL="$(mkc "$S" y EVIL -p "$SH")"
SXLT="$(git -C "$S" rev-parse "$SXL^{tree}")"
SML="$(git -C "$S" commit-tree "$SXLT" -p "$SXL" -m launder1)"
L1="$(commit_state "$SML" "$(rline "$SH" merged "$SML" "")")"
assert_ne "t_preserved_laundered_on_head: 부모 1개 M 기록 → 전체 해시 상이" "$PA" "$(ph "$L1")"
assert_ne "t_preserved_laundered_on_head: 부모 1개 M 기록 → 한정 해시 상이" "$FA" "$(fh "$L1")"
SML="$(git -C "$S" commit-tree "$SXLT" -p "$SXL" -p "$SH" -m launder2)"
L2="$(commit_state "$SML" "$(rline "$SH" merged "$SML" "")")"
assert_ne "t_preserved_laundered_on_head: 부모 2개 M 기록 → 전체 해시 상이" "$PA" "$(ph "$L2")"
assert_ne "t_preserved_laundered_on_head: 부모 2개 M 기록 → 한정 해시 상이" "$FA" "$(fh "$L2")"

# t_subst_objects_missing — 같은 fixture 를 이어 씁니다(마지막 케이스). 팀 쪽 커밋은 ref 없이 만들었으므로
# gc 가 M·T(=U) 를 지우고, ref(pr) 가 붙은 H 와 그 트리만 남깁니다. 치환이 되던 사실은 위 t_full_hash_subst 가 보였습니다.
git -C "$S" reflog expire --expire=now --all >/dev/null 2>&1
git -C "$S" gc -q --prune=now >/dev/null 2>&1
if git -C "$S" cat-file -e "$SH^{tree}" 2>/dev/null && ! git -C "$S" cat-file -e "$SM" 2>/dev/null \
   && ! git -C "$S" cat-file -e "$SU" 2>/dev/null; then
  pass "t_subst_objects_missing: 준비 — H 와 트리는 남고 M·T 는 없음"
else
  fail "t_subst_objects_missing: 준비 실패 — 객체 상태가 예상과 다름"
fi
assert_eq "t_subst_objects_missing: 준비 — gc 뒤에도 A 의 전체 해시는 그대로" "$PA" "$(ph "$A")"
assert_ne "t_subst_objects_missing: 객체 없음 → 전체 해시 상이(치환 안 함)" "$PA" "$(ph "$B")"
assert_ne "t_subst_objects_missing: 객체 없음 → 한정 해시 상이(치환 안 함)" "$FA" "$(fh "$B")"

echo "--- archive_review_precheck 승인 커밋 결속 ---"
# t_precheck_binds_approved_oid (D3-3) — 승인(rd_seal_verify) 직후 HEAD 가 보호 경로 커밋으로 움직여도
# RD_ARCHIVE_REVIEWED_OID 는 승인한 target 입니다. 같은 셸에서 우회 플래그로 다시 부르면 해시·OID 가 모두 빕니다.
# 없으면 새는 실수: 소비 시점의 HEAD 를 승인 커밋으로 넘겨 미검토 커밋을 기록 커밋으로 씁니다 / 앞 승인 값이 우회 실행에 남습니다.
Q="$(mktemp -d "$TROOT/q.XXXXXX")" || { echo "mktemp 실패" >&2; exit 1; }
Q="$(cd "$Q" && pwd -P)"
git -C "$Q" init -q -b main
mkdir -p "$Q/rd-workflow-workspace/.lifecycle/review-seals"
printf 'code\n' > "$Q/src.txt"; git -C "$Q" add -A; git -C "$Q" commit -qm seed
printf 'work\n' >> "$Q/src.txt"; git -C "$Q" commit -qam 구현
QSID="20261118_090000_final-diff-review"
QH="$( ( project_root="$Q"; export project_root; cd "$Q"; source "$GUARD" >/dev/null 2>&1 || exit 99; rd_protected_tree_hash HEAD ) 2>/dev/null )"
printf 'schema=1\nsession-id=%s\nreview-type=diff-review\ntree-hash=%s\nhead=%s\nbranch-mode=no-fr\nfr-branch=null\nrd-version=unknown\nverified=yes\nsealed-at=2026-11-18-0900\n' \
  "$QSID" "$QH" "$(git -C "$Q" rev-parse HEAD)" > "$Q/rd-workflow-workspace/.lifecycle/review-seals/$QSID.seal"
printf 'schema=1\nshort-title=qtask\nstatus=아카이브 보류\nfr-branch=null\nworktree-path=null\nsource-fr=-\nreview-session=%s\n' \
  "$QSID" > "$Q/rd-workflow-workspace/.lifecycle/task-state"
git -C "$Q" add -A; git -C "$Q" commit -qm "기록 커밋 (마커)"
QT="$(git -C "$Q" rev-parse HEAD)"
qout="$( project_root="$Q"; TASK_STATE_PATH="$Q/rd-workflow-workspace/.lifecycle/task-state"; export project_root TASK_STATE_PATH
  cd "$Q"; source "$GUARD" >/dev/null 2>&1 || exit 99
  eval "_q_real_$(declare -f rd_seal_verify)"
  # 진짜 검증이 승인한 뒤에만 보호 경로 커밋으로 HEAD 를 움직입니다(승인과 소비 사이의 창).
  rd_seal_verify() { _q_real_rd_seal_verify "$@" || return $?; echo moved >> src.txt; git commit -qam "승인 뒤 보호 경로 커밋"; }
  archive_review_precheck 0 "" qtask "$Q/audit.log" null >/dev/null 2>&1; r1=$?
  printf 'rc=%s oid=%s head=%s hash=%s\n' "$r1" "$RD_ARCHIVE_REVIEWED_OID" "$(git rev-parse HEAD)" "$RD_ARCHIVE_REVIEWED_TREE_HASH"
  archive_review_precheck 1 "테스트" qtask "$Q/audit.log" null >/dev/null 2>&1; r2=$?
  printf 'rc=%s oid=[%s] hash=[%s]\n' "$r2" "$RD_ARCHIVE_REVIEWED_OID" "$RD_ARCHIVE_REVIEWED_TREE_HASH" )"
q1="$(printf '%s\n' "$qout" | sed -n 1p)"; q2="$(printf '%s\n' "$qout" | sed -n 2p)"
q1h="${q1#*head=}"; q1h="${q1h%% *}"
assert_eq "t_precheck_binds_approved_oid: 준비 — 승인 rc 0, 승인 해시 = 마커 해시" "rc=0 hash=$QH" "${q1%% *} hash=${q1##*hash=}"
assert_ne "t_precheck_binds_approved_oid: 준비 — 승인 뒤 HEAD 가 움직임" "$QT" "$q1h"
q1o="${q1#*oid=}"; q1o="${q1o%% *}"
assert_eq "t_precheck_binds_approved_oid: RD_ARCHIVE_REVIEWED_OID = 승인한 target(움직이기 전 OID)" "$QT" "$q1o"
assert_eq "t_precheck_binds_approved_oid: 우회 재호출 — 해시·OID 모두 빈 값" "rc=0 oid=[] hash=[]" "$q2"

echo
echo "결과: PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" == "0" ]]
