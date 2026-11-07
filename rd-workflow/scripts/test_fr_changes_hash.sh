#!/usr/bin/env bash
# test_fr_changes_hash.sh — rd_fr_changes_hash(한정 해시)와 rd_seal_verify 의 fr-changes-hash 판정(spec D1·D2)을 검증한다.
# 케이스마다 새 임시 저장소를 만든다. bash 3.2 호환.
set -uo pipefail

# 실제 herdr 호출 차단·바깥 저장소 상속 차단 (lifecycle/test_archive_worktree.sh 와 같은 이유)
export HERDR_ENV=
export HC_TERMINAL_ID=
export RD_CHILD_SESSION=1
unset project_root TASK_STATE_PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/hooks/_guard_common.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (기대=[$2] 실제=[$3])"; fi; }
assert_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1 (두 값이 같음: [$2])"; fi; }

# 임시 저장소는 모두 TROOT 아래에 만든다. mk_repo 는 `R="$(mk_repo)"` 처럼 서브셸에서 불리므로
# 그 안에서 정리 목록에 추가해도 부모 셸에 전달되지 않는다 — 부모가 만든 상위 디렉터리 하나를 지운다.
TROOT="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
trap 'rm -rf "$TROOT"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# mk_repo — main(a.txt 5행·b.txt·CURRENT_TASK.md) + fr/x(a.txt 1행 수정). 마지막에 fr/x 체크아웃. stdout: 경로
mk_repo() {
  local d
  d="$(mktemp -d "$TROOT/repo.XXXXXX")" || { echo "mktemp 실패" >&2; exit 1; }
  git -C "$d" init -q -b main
  printf '1\n2\n3\n4\n5\n' > "$d/a.txt"; echo b > "$d/b.txt"; echo task > "$d/CURRENT_TASK.md"
  git -C "$d" add -A; git -C "$d" commit -qm seed
  git -C "$d" checkout -q -b fr/x
  printf 'one\n2\n3\n4\n5\n' > "$d/a.txt"
  git -C "$d" commit -qam "fr: a.txt"
  printf '%s' "$d"
}
g() { git -C "$R" "$@" >/dev/null 2>&1; }

# fh <commit> [기본 쪽] — 한정 해시 (실패 시 빈 출력과 rc)
fh() {
  ( project_root="$R"; export project_root; cd "$R"
    source "$GUARD" || exit 99
    rd_fr_changes_hash "$@" ) 2>/dev/null
}

# verify_msg <target> <fr> — rd_seal_verify commit 모드. 통과 'OK', 실패 'KIND|MSG'
verify_msg() {
  ( project_root="$R"; export project_root; cd "$R"
    export TASK_STATE_PATH="$R/rd-workflow-workspace/.lifecycle/task-state"
    source "$GUARD" || exit 99
    if rd_seal_verify commit "$@"; then printf 'OK'; else printf '%s|%s' "$RD_SEAL_FAIL_KIND" "$RD_SEAL_FAIL_MSG"; fi ) 2>/dev/null
}

echo "--- T1: 한정 해시 단위 ---"
R="$(mk_repo)"; H0="$(fh fr/x)"
[[ -n "$H0" ]] || { fail "T1 준비: 기준 해시 계산 실패"; H0=""; }

# T1a: main 의 무관한 변경을 fr 이 병합해도 동일
g checkout -q main; echo c > "$R/c.txt"; g add -A; g commit -qm "main: c.txt"
g checkout -q fr/x; g merge -q --no-edit main
assert_eq "T1a: main 무관 병합 뒤 해시 동일" "$H0" "$(fh fr/x)"

# T1b: fr 이 a.txt 를 다시 고침
R="$(mk_repo)"; H0="$(fh fr/x)"
printf 'one\n2\nTHREE\n4\n5\n' > "$R/a.txt"; g commit -qam "fr: a.txt again"
assert_ne "T1b: 리뷰 경로 내용 변경 → 해시 상이" "$H0" "$(fh fr/x)"

# T1e: main 이 a.txt 의 다른 줄을 고치고 fr 이 자동 병합
R="$(mk_repo)"; H0="$(fh fr/x)"
g checkout -q main; printf '1\n2\n3\n4\nfive\n' > "$R/a.txt"; g commit -qam "main: a.txt line5"
g checkout -q fr/x; g merge -q --no-edit main
assert_ne "T1e: main 이 fr 경로를 바꿔 자동 병합 → 해시 상이" "$H0" "$(fh fr/x)"

# T1c: fr 이 d.txt 추가
R="$(mk_repo)"; H0="$(fh fr/x)"
echo d > "$R/d.txt"; g add -A; g commit -qm "fr: d.txt"
assert_ne "T1c: 새 경로 추가 → 해시 상이" "$H0" "$(fh fr/x)"

# T1d: fr 이 seal 뒤 b.txt 삭제
R="$(mk_repo)"; H0="$(fh fr/x)"
g rm -q b.txt; g commit -qm "fr: rm b.txt"
assert_ne "T1d: 삭제 → 해시 상이" "$H0" "$(fh fr/x)"

# T1f: 기록 경로만 바뀜
R="$(mk_repo)"; H0="$(fh fr/x)"
echo more >> "$R/CURRENT_TASK.md"; g commit -qam "fr: record"
assert_eq "T1f: 기록 경로만 변경 → 해시 동일" "$H0" "$(fh fr/x)"

# T1g: main 이 fr 을 --no-ff 로 병합한 뒤 M^1 을 기본 쪽으로 주면 동일, 인자 없으면 상이
R="$(mk_repo)"; H0="$(fh fr/x)"
g checkout -q main; g merge -q --no-ff -m "merge fr" fr/x
M1="$(git -C "$R" rev-parse 'main^1')"
assert_eq "T1g: 병합 뒤 M^1 기준 해시 동일" "$H0" "$(fh fr/x "$M1")"
assert_ne "T1g: 병합 뒤 인자 없이 부르면 해시 상이(목록 빔)" "$H0" "$(fh fr/x)"

# T1h: 기본 브랜치가 모호하면(main·master 둘 다, config·origin/HEAD 없음) 실패
R="$(mk_repo)"; g branch master main
out="$(fh fr/x)"; rc=$?
if [[ "$rc" != "0" && -z "$out" ]]; then pass "T1h: 기본 브랜치 모호 → 해시 실패"; else fail "T1h: 기본 브랜치 모호인데 해시가 성공함 (rc=${rc} out=[$out])"; fi

# T1i: submodule 이 ignore=all 이어도 seal 뒤 gitlink 이동을 잡는다 (diff-tree --ignore-submodules=none)
R="$(mk_repo)"
printf '[submodule "s"]\n\tpath = s\n\turl = ../sub\n\tignore = all\n' > "$R/.gitmodules"
g update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,s"
g add .gitmodules; g commit -qm "fr: sub"
H0s="$(fh fr/x)"
g update-index --cacheinfo "160000,2222222222222222222222222222222222222222,s"; g commit -qm "fr: sub 이동"
H1s="$(fh fr/x)"
if [[ -n "$H0s" && -n "$H1s" && "$H0s" != "$H1s" ]]; then pass "T1i: ignore=all submodule 의 gitlink 이동 → 해시 상이"
else fail "T1i: ignore=all submodule 의 gitlink 이동을 놓침 (H0=[$H0s] H1=[$H1s])"; fi

echo "--- T5: 마커 판정 ---"
SID="20261104_000000_diff-review"
# mk_marker <extra 줄들> — fr/x tip 에 task-state·마커를 커밋. tree-hash 는 일부러 틀린 값.
mk_marker() {
  local mode="${MARK_MODE:-fr}" frb="${MARK_FR:-fr/x}"
  mkdir -p "$R/rd-workflow-workspace/.lifecycle/review-seals"
  printf 'schema=1\nshort-title=x\nstatus=아카이브 보류\nfr-branch=%s\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=%s\n' \
    "$frb" "$SID" > "$R/rd-workflow-workspace/.lifecycle/task-state"
  {
    printf 'schema=1\nsession-id=%s\nreview-type=diff-review\n' "$SID"
    printf 'tree-hash=%s\n' "0000000000000000000000000000000000000000"
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
    printf 'head=%s\nbranch-mode=%s\nfr-branch=%s\nrd-version=9.9.9\nverified=yes\nsealed-at=2026-11-04-1200\n' \
      "$(git -C "$R" rev-parse HEAD)" "$mode" "$( [[ "$mode" == no-fr ]] && echo null || echo "$frb" )"
  } > "$R/rd-workflow-workspace/.lifecycle/review-seals/${SID}.seal"
  g add -A; g commit -qm "record seal"
}

R="$(mk_repo)"; H0="$(fh fr/x)"
mk_marker "fr-changes-hash=${H0}"
g checkout -q main; echo c > "$R/c.txt"; g add -A; g commit -qm "main: c.txt"
g checkout -q fr/x; g merge -q --no-edit main
assert_eq "T5a: 한정 마커 + main 무관 병합 → 통과" "OK" "$(verify_msg fr/x fr/x)"

R="$(mk_repo)"
mk_marker "fr-changes-hash=XYZ"
r="$(verify_msg fr/x fr/x)"
assert_eq "T5b: fr-changes-hash 형식 오류 → malformed" "malformed" "${r%%|*}"
case "$r" in *"fr-changes-hash 형식"*) pass "T5b: 형식 오류 사유 안내" ;; *) fail "T5b: 형식 오류 사유 없음 [$r]" ;; esac

R="$(mk_repo)"
mk_marker "fr-changes-hash="
r="$(verify_msg fr/x fr/x)"
case "$r" in "malformed|"*"fr-changes-hash 형식"*) pass "T5d: 빈 fr-changes-hash → malformed" ;; *) fail "T5d: 빈 fr-changes-hash 가 malformed 가 아님 [$r]" ;; esac

R="$(mk_repo)"
MARK_MODE=no-fr MARK_FR=null mk_marker "fr-changes-hash=${H0}"
r="$(verify_msg HEAD null)"
assert_eq "T5c: no-fr 마커에 fr-changes-hash → malformed" "malformed" "${r%%|*}"
case "$r" in *"no-fr 마커에"*) pass "T5c: no-fr 사유 안내" ;; *) fail "T5c: no-fr 사유 없음 [$r]" ;; esac

echo ""
echo "PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
