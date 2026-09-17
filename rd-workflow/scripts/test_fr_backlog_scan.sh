#!/usr/bin/env bash
# test_fr_backlog_scan.sh — 미병합 브랜치 backlog 대조 검사 (REQUEST AC 15) — self_test lifecycle 그룹
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
T="$(mktemp -d)" || { echo "test_fr_backlog_scan.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$T" && -d "$T" ]] || { echo "test_fr_backlog_scan.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
IDX=rd-workflow-workspace/backlog/FUTURE_REQUESTS.md
mk_repo() { # mk_repo <dir> — 스크립트 사본 + 기본 backlog 를 가진 main 저장소
  mkdir -p "$1" && ( cd "$1" && git init -q && git checkout -q -b main 2>/dev/null \
    && git config user.email t@e.com && git config user.name t \
    && mkdir -p rd-workflow rd-workflow-workspace/backlog/items rd-workflow-workspace/.lifecycle \
    && cp -R "$SCRIPT_DIR" rd-workflow/scripts \
    && printf '# FR\n\n## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |\n|---|---|---|---|---|---|---|\n| 2026-01-01 | base-a | a | tooling | idea | - | [상세](items/2026-01-01-base-a.md) |\n' > "$IDX" \
    && printf '# base-a\n- status: idea\n' > rd-workflow-workspace/backlog/items/2026-01-01-base-a.md \
    && git add -A && git commit -q -m init )
}
add_item() { # add_item <dir> <branch-from> <branch> <slug> [with-row=1] — 브랜치에 items 추가 커밋
  ( cd "$1" && git checkout -q -b "$3" "$2" \
    && printf '# %s\n- status: idea\n' "$4" > "rd-workflow-workspace/backlog/items/2026-03-03-$4.md" \
    && { [[ "${5:-1}" == 1 ]] && printf '| 2026-03-03 | %s | s | tooling | idea | - | [상세](items/2026-03-03-%s.md) |\n' "$4" "$4" >> "$IDX" || true; } \
    && git add -A && git commit -q -m "docs: FR 등록 — $4" && git checkout -q main )
}
scan() { ( cd "$1" && bash rd-workflow/scripts/fr_backlog_scan.sh 2>&1 ); }

R="$T/r"; mk_repo "$R"
out="$(scan "$R")"; rc=$?
[[ "$rc" == 0 && "$out" == *"미병합 브랜치 FR 후보: 없음"* ]] && pass "후보 없음 → 없음, exit 0" || fail "후보 없음 — rc=$rc $out"

# (a) items 추가 파일을 가진 미병합 로컬 브랜치 (인덱스 행 포함)
add_item "$R" main fr/lost-a lost-a
# (c) 회수 완료: 브랜치에 있는 상세가 기본 브랜치에도 같은 경로로 존재
add_item "$R" main fr/recovered rec-b
( cd "$R" && git checkout -q main && git checkout -q fr/recovered -- rd-workflow-workspace/backlog/items/2026-03-03-rec-b.md && git commit -q -m "회수" )
# (b) 같은 tip 을 가리키는 로컬·remote-tracking ref 쌍
( cd "$R" && git update-ref refs/remotes/origin/fr/lost-a refs/heads/fr/lost-a )
# (d) 로컬 기본 브랜치보다 앞선 origin/main (items 추가 커밋 포함)
( cd "$R" && git checkout -q -b tmp-ahead main && printf '# ahead\n' > rd-workflow-workspace/backlog/items/2026-03-04-ahead.md && git add -A && git commit -q -m ahead \
  && git update-ref refs/remotes/origin/main refs/heads/tmp-ahead && git checkout -q main && git branch -q -D tmp-ahead \
  && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main )
# (e) 기본 브랜치 이름이 다른 두 번째 remote (mirror/HEAD → mirror/trunk, items 추가 커밋 포함)
( cd "$R" && git checkout -q -b tmp-trunk main && printf '# trunk\n' > rd-workflow-workspace/backlog/items/2026-03-05-trunk.md && git add -A && git commit -q -m trunk \
  && git update-ref refs/remotes/mirror/trunk refs/heads/tmp-trunk && git checkout -q main && git branch -q -D tmp-trunk \
  && git symbolic-ref refs/remotes/mirror/HEAD refs/remotes/mirror/trunk && git remote add mirror /nonexistent && git remote add origin /nonexistent2 )
# 인덱스 행 없는 상세만 있는 브랜치 (행 유무 병기 확인)
add_item "$R" main fr/norow norow 0

out="$(scan "$R")"; rc=$?
[[ "$rc" == 0 ]] && pass "후보 있음 → exit 0" || fail "rc=$rc"
[[ "$out" == *"scan: candidates=2 refs=2"* ]] && pass "FR 후보 2건(lost-a·norow), 묶음 2개" || fail "집계 불일치 — $out"
[[ "$out" == *"FR lost-a (인덱스 행 있음, 마지막 커밋 "* ]] && pass "(a) lost-a 보고 + 행 있음 + 날짜" || fail "(a) 누락 — $out"
[[ "$out" == *"fr/lost-a"*"origin/fr/lost-a"* || "$out" == *"origin/fr/lost-a"*"fr/lost-a"* ]] && pass "(b) 같은 tip 은 한 묶음에 ref 나열" || fail "(b) 묶음 실패 — $out"
[[ "$out" != *"rec-b"* ]] && pass "(c) 회수 완료 상세는 미보고" || fail "(c) 오보 — $out"
[[ "$out" != *"2026-03-04-ahead"* && "$out" != *"origin/main"* ]] && pass "(d) 앞선 origin/main 제외" || fail "(d) 오보 — $out"
[[ "$out" != *"trunk"* ]] && pass "(e) mirror/HEAD 대상 mirror/trunk 제외" || fail "(e) 오보 — $out"
[[ "$out" == *"FR norow (인덱스 행 없음"* ]] && pass "행 없는 상세는 '행 없음' 병기" || fail "행 유무 병기 실패 — $out"
# (f) 같은 경로·다른 내용: 회수 완료가 아니라 '내용 다름' 후보로 노출
add_item "$R" main fr/diffblob diff-c
( cd "$R" && printf '# diff-c 다른 내용\n' > rd-workflow-workspace/backlog/items/2026-03-03-diff-c.md && git add -A && git commit -q -m "다른 내용" )
# (g) 공통 조상 없는 orphan ref 에 backlog 파일이 있으면 빈 트리 기준으로 보고, 없으면 무시
( cd "$R" && git checkout -q --orphan pages && git rm -rfq . >/dev/null 2>&1; mkdir -p rd-workflow-workspace/backlog/items && printf '# orphan\n' > rd-workflow-workspace/backlog/items/2026-03-06-orphan-o.md && git add -A && git commit -q -m pages \
  && git checkout -q --orphan gh-pages && git rm -rfq . >/dev/null 2>&1; echo site > index.html && git add -A && git commit -q -m site && git checkout -q main )
out="$(scan "$R")"; rc=$?
[[ "$rc" == 0 && "$out" == *"scan: candidates=4 refs=4 errors=0"* ]] && pass "(f)(g) 후보 4건(lost-a·norow·diff-c·orphan-o), exit 0" || fail "(f)(g) 집계 — $out"
[[ "$out" == *"FR diff-c (인덱스 행 있음"*"내용 다름"* ]] && pass "(f) 다른 내용은 '내용 다름' 으로 노출" || fail "(f) 미노출 — $out"
[[ "$out" == *"- pages (tip "*"FR orphan-o"* && "$out" != *"gh-pages"* ]] && pass "(g) orphan 은 빈 트리 기준 보고, backlog 없는 orphan 은 무시" || fail "(g) — $out"

# 기본 브랜치 ref 부재 → exit 3
R3="$T/r3"; mk_repo "$R3"
( cd "$R3" && mkdir -p rd-workflow/config && printf '{"default_branch":"trunk"}\n' > rd-workflow/config/workflow.json )
out="$(scan "$R3")"; rc=$?
[[ "$rc" == 3 ]] && pass "기본 브랜치 ref 부재 → exit 3" || fail "ref 부재 rc=$rc — $out"
echo "fr_backlog_scan: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
