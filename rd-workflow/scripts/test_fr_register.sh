#!/usr/bin/env bash
# test_fr_register.sh — rd task fr-register (등록 결과 기본 브랜치 커밋) 격리 테스트. REQUEST AC 1~11 + spec/plan review 보강.
#   시나리오마다 fresh 저장소를 쓰고, tuple 분기는 helper 호출 전에 기본 브랜치 tree 의 사전조건을 먼저 단언한다.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
T="$(mktemp -d)" || { echo "test_fr_register.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$T" && -d "$T" ]] || { echo "test_fr_register.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
IDX=rd-workflow-workspace/backlog/FUTURE_REQUESTS.md
ITEMS=rd-workflow-workspace/backlog/items
CAPS=rd-workflow-workspace/raw-captures
D=2026-02-02
mk_repo() { # mk_repo <dir> — 스크립트 사본 + task-state + 기본 backlog 를 가진 main 저장소
  mkdir -p "$1" && ( cd "$1" && git init -q && git checkout -q -b main 2>/dev/null \
    && git config user.email t@e.com && git config user.name t && git config core.hooksPath "$1/.git/hooks" \
    && mkdir -p rd-workflow rd-workflow-workspace/.lifecycle "$ITEMS" "$CAPS" \
    && cp -R "$SCRIPT_DIR" rd-workflow/scripts \
    && printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > rd-workflow-workspace/.lifecycle/task-state \
    && printf '# Current Task\n\n## Task\n-\n\n## Short Title\n-\n\n## Status\n대기 중\n\n## Notes\n-\n' > CURRENT_TASK.md \
    && printf '# FR\n\n## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |\n|---|---|---|---|---|---|---|\n| 2026-01-01 | base-a | a | tooling | idea | - | [상세](items/2026-01-01-base-a.md) |\n' > "$IDX" \
    && printf '# base-a\n- status: idea\n' > "$ITEMS/2026-01-01-base-a.md" && : > "$CAPS/.gitkeep" \
    && git add -A && git commit -q -m init )
}
row_of() { printf '| %s | %s | 요약 %s | tooling | idea | - | [상세](items/%s-%s.md) |\n' "$D" "$1" "$1" "$D" "$1"; }
detail_of() { printf '# %s %s\n- status: idea\n' "$D" "$1"; }
cap_of() { printf -- '---\nstage: fr\nshort-title: %s\n---\n\n## 원본 입력\nx\n' "$1"; }
add_fr() { # add_fr <dir> <slug> — /fr add 의 쓰기 단계(행·상세·캡처) 모사
  ( cd "$1" && row_of "$2" >> "$IDX" && detail_of "$2" > "$ITEMS/$D-$2.md" && cap_of "$2" > "$CAPS/$D-fr-$2.md" )
}
# main 에 부분 상태를 커밋해 두는 helper 들 (fr 브랜치 생성 전에 부른다)
main_commit_row()    { ( cd "$1" && row_of "$2" >> "$IDX" && git add -A && git commit -q -m "행만 $2" ); }
main_commit_detail() { ( cd "$1" && detail_of "$2" > "$ITEMS/$D-$2.md" && git add -A && git commit -q -m "상세만 $2" ); }
main_commit_cap()    { ( cd "$1" && cap_of "$2" > "$CAPS/$D-fr-$2.md" && git add -A && git commit -q -m "캡처만 $2" ); }
TMPD="$T/tmpd"; mkdir -p "$TMPD"
reg() { ( cd "$1" && TMPDIR="$TMPD" bash rd-workflow/scripts/rd task fr-register --slug "$2" 2>&1 ); }
line1() { printf '%s\n' "$1" | sed -n 1p; }
refs_count() { ( cd "$1" && git for-each-ref | wc -l | tr -d ' ' ); }
wt_count() { ( cd "$1" && git worktree list | wc -l | tr -d ' ' ); }
tmp_clean() { [[ -z "$(ls -A "$TMPD")" ]] && pass "$1: helper 임시 파일(TMPDIR) 잔존 없음" || fail "$1: TMPDIR 잔존 — $(ls -A "$TMPD")"; }
on_main_has() { ( cd "$1" && git cat-file -e "main:$2" 2>/dev/null ); }
main_blob_eq() { [[ "$(cd "$1" && git rev-parse "main:$2")" == "$(cd "$1" && git hash-object "$3")" ]]; }
in_fr() { ( cd "$1" && git checkout -q -b "$2" main ); }

echo "== AC 1: fr 브랜치 세션(기본 브랜치 미체크아웃) =="
R="$T/r1"; mk_repo "$R"; in_fr "$R" fr/x
old="$(cd "$R" && git rev-parse main)"; head0="$(cd "$R" && git rev-parse HEAD)"; nref0="$(refs_count "$R")"
add_fr "$R" x
out="$(reg "$R" x)"; rc=$?
[[ "$rc" == 0 && "$(line1 "$out")" == "result=committed branch=main commit="*" reason=-" ]] && pass "committed, exit 0, reason=-" || fail "rc=$rc — $out"
new="$(cd "$R" && git rev-parse main)"
[[ "$new" != "$old" && "$(cd "$R" && git rev-parse main^)" == "$old" ]] && pass "main 에 커밋 1개 추가" || fail "main 커밋 수 불일치"
[[ "$(cd "$R" && source rd-workflow/scripts/lifecycle/_lifecycle_common.sh; registration_commit_shape main)" == "x" ]] && pass "형태 검증 통과 (행1·상세1·캡처1)" || fail "형태 검증 실패"
[[ "$(cd "$R" && git rev-parse HEAD)" == "$head0" && "$(cd "$R" && git rev-parse --abbrev-ref HEAD)" == "fr/x" ]] && pass "현재 브랜치·HEAD 불변" || fail "HEAD 이동"
( cd "$R" && grep -q "| x |" "$IDX" ) && pass "현재 워킹트리 인덱스에 행 보임" || fail "워킹트리 행 없음"
[[ "$(printf '%s\n' "$out" | sed -n 2p)" == "FR 등록 커밋: main ${new:0:7}" ]] && pass "AC 11 성공 메시지 형식" || fail "메시지 — $out"
[[ "$(refs_count "$R")" == "$nref0" && "$(wt_count "$R")" == 1 ]] && pass "임시 ref·worktree 없음" || fail "임시 ref/worktree 잔존"
tmp_clean "committed"

echo "== AC 10: 같은 slug 재실행 → already / 행 전문 다름 → row-conflict =="
out="$(reg "$R" x)"; rc=$?
[[ "$rc" == 0 && "$(line1 "$out")" == "result=already"* && "$(cd "$R" && git rev-parse main)" == "$new" ]] && pass "already, 커밋 없음" || fail "idempotent 실패 — $out"
( cd "$R" && sed 's/| x | 요약 x |/| x | 바뀐 요약 |/' "$IDX" > "$IDX.n" && mv "$IDX.n" "$IDX" )
out="$(reg "$R" x)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=row-conflict"* && "$(cd "$R" && git rev-parse main)" == "$new" ]] && pass "행 전문 다름 → skipped row-conflict" || fail "row-conflict — $out"
# slug 경계 검증
out="$(reg "$R" "Bad_Slug")"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=bad-slug"* ]] && pass "kebab-case 아닌 slug → skipped bad-slug" || fail "bad-slug — $out"
# 기본 브랜치 인덱스가 개행으로 끝나지 않으면 합성이 마지막 행을 수정으로 만들어 shape-mismatch 에 영구히 걸린다 → 사전 검사로 실행 가능한 사유를 낸다
RNL="$T/r-nl"; mk_repo "$RNL"
( cd "$RNL" && printf '%s' "$(cat "$IDX")" > "$IDX" && git add -A && git commit -q -m no-newline )
[[ -n "$(cd "$RNL" && git cat-file -p "main:$IDX" | tail -c1)" ]] && pass "사전조건: main 인덱스 끝 개행 없음" || fail "사전조건 — 개행 있음"
old_nl="$(cd "$RNL" && git rev-parse main)"
in_fr "$RNL" fr/nl; ( cd "$RNL" && printf '\n' >> "$IDX" ); add_fr "$RNL" nl
out="$(reg "$RNL" nl)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=index-no-newline"* && "$(cd "$RNL" && git rev-parse main)" == "$old_nl" ]] && pass "base 인덱스 개행 없음 → skipped index-no-newline, ref 불변" || fail "index-no-newline — rc=$rc $out"

echo "== AC 2: 내용 단위 격리 =="
R="$T/r2"; mk_repo "$R"; in_fr "$R" fr/y
( cd "$R" && git checkout -q main ) && add_fr "$R" main-only && ( cd "$R" && git add -A && git commit -q -m "main 에만 있는 행" && git checkout -q fr/y )
( cd "$R" && printf '| 2026-02-09 | other-fr | 다른 행 | tooling | idea | - | [상세](items/2026-02-09-other-fr.md) |\n' >> "$IDX" \
  && sed 's/| base-a | a |/| base-a | 사용자편집 |/' "$IDX" > "$IDX.n" && mv "$IDX.n" "$IDX" )
add_fr "$R" y
out="$(reg "$R" y)"; rc=$?
[[ "$rc" == 0 ]] && pass "committed" || fail "rc=$rc — $out"
d="$(cd "$R" && git diff --unified=0 main^ main -- "$IDX" | grep '^[-+]' | grep -v '^+++\|^---')"
[[ "$(printf '%s\n' "$d" | grep -c .)" == 1 && "$d" == "+| $D | y |"* ]] && pass "인덱스 diff = y 행 1개 추가만" || fail "diff — $d"
mi="$(cd "$R" && git show main:"$IDX")"
[[ "$mi" == *"| main-only |"* && "$mi" != *"other-fr"* && "$mi" != *"사용자편집"* ]] && pass "기본 브랜치 행 보존, fr 전용 행·편집 미유입" || fail "유입 — $mi"
( cd "$R" && grep -q "other-fr" "$IDX" && grep -q "사용자편집" "$IDX" ) && pass "fr 워킹트리의 행·편집 그대로" || fail "fr 트리 훼손"

echo "== AC 3: 음성 — 상세 없음 / 행 2개 / 상세 내용 다름 =="
R="$T/r3"; mk_repo "$R"; in_fr "$R" fr/z; old="$(cd "$R" && git rev-parse main)"; nref0="$(refs_count "$R")"
( cd "$R" && row_of nodetail >> "$IDX" )
out="$(reg "$R" nodetail)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=detail-missing"* ]] && pass "상세 없음 → skipped detail-missing" || fail "rc=$rc — $out"
add_fr "$R" twice; ( cd "$R" && r="$(grep "| twice |" "$IDX")" && printf '%s\n' "$r" >> "$IDX" )
out="$(reg "$R" twice)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=row-ambiguous"* ]] && pass "행 2개 → row-ambiguous" || fail "rc=$rc — $out"
[[ "$(cd "$R" && git rev-parse main)" == "$old" && "$(refs_count "$R")" == "$nref0" && "$(wt_count "$R")" == 1 ]] && pass "AC 8: 실패 후 ref 불변·임시 ref·worktree 없음" || fail "ref 이동 또는 임시 자원 잔존"
[[ "$out" == *"복구: bash rd-workflow/scripts/rd task fr-register --slug twice"* ]] && pass "AC 11 skipped 메시지에 복구 명령" || fail "복구 명령 없음 — $out"
tmp_clean "skipped"
# 상세 내용 다름: main 에 다른 내용 상세를 먼저 커밋 → fr 브랜치에서 add_fr(같은 경로, 우리 내용) → detail-conflict
R="$T/r3b"; mk_repo "$R"; ( cd "$R" && printf '# 다른 내용\n' > "$ITEMS/$D-dup.md" && git add -A && git commit -q -m other ); in_fr "$R" fr/z; old="$(cd "$R" && git rev-parse main)"
add_fr "$R" dup
on_main_has "$R" "$ITEMS/$D-dup.md" && ! main_blob_eq "$R" "$ITEMS/$D-dup.md" "$R/$ITEMS/$D-dup.md" && pass "사전조건: main 에 다른 blob 상세 존재" || fail "사전조건 실패"
out="$(reg "$R" dup)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=detail-conflict"* && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "다른 내용 상세 → detail-conflict, ref 불변" || fail "rc=$rc — $out"

echo "== tuple 부분 일치 (fresh repo, 사전조건 단언) =="
# (1) 캡처만 다른 내용으로 main 에 선존 → capture-conflict
R="$T/t1"; mk_repo "$R"; ( cd "$R" && printf 'other capture\n' > "$CAPS/$D-fr-cc.md" && git add -A && git commit -q -m cap ); in_fr "$R" fr/t; old="$(cd "$R" && git rev-parse main)"
add_fr "$R" cc
on_main_has "$R" "$CAPS/$D-fr-cc.md" && ! on_main_has "$R" "$ITEMS/$D-cc.md" && pass "사전조건: main 에 다른 blob 캡처만" || fail "사전조건 실패"
out="$(reg "$R" cc)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=capture-conflict"* && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "캡처 내용 다름 → skipped capture-conflict, ref 불변" || fail "capture-conflict — rc=$rc $out"
# (2) 상세만 같은 내용으로 main 에 선존, 행 없음 → row-missing-on-default
R="$T/t2"; mk_repo "$R"; main_commit_detail "$R" rm1; in_fr "$R" fr/t; old="$(cd "$R" && git rev-parse main)"
add_fr "$R" rm1
on_main_has "$R" "$ITEMS/$D-rm1.md" && main_blob_eq "$R" "$ITEMS/$D-rm1.md" "$R/$ITEMS/$D-rm1.md" && ! ( cd "$R" && git show main:"$IDX" | grep -q "| rm1 |" ) && pass "사전조건: main 에 같은 blob 상세, 행 없음" || fail "사전조건 실패"
out="$(reg "$R" rm1)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=row-missing-on-default"* && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "상세만 있고 행 없음 → skipped row-missing-on-default" || fail "row-missing — rc=$rc $out"
# (3) 행만 main 에 선존, 상세 없음 → row-exists
R="$T/t3"; mk_repo "$R"; main_commit_row "$R" re1; in_fr "$R" fr/t; old="$(cd "$R" && git rev-parse main)"
( cd "$R" && detail_of re1 > "$ITEMS/$D-re1.md" && cap_of re1 > "$CAPS/$D-fr-re1.md" )   # 행은 main 에서 이미 내려옴
( cd "$R" && git show main:"$IDX" | grep -q "| re1 |" ) && ! on_main_has "$R" "$ITEMS/$D-re1.md" && pass "사전조건: main 에 행만" || fail "사전조건 실패"
out="$(reg "$R" re1)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=row-exists"* && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "행만 있고 상세 없음 → skipped row-exists" || fail "row-exists — rc=$rc $out"
# (4) 행·상세는 같은데 캡처가 main 에 없음 → capture-missing-on-default (already 로 오판하지 않음)
R="$T/t4"; mk_repo "$R"; main_commit_row "$R" cm1; main_commit_detail "$R" cm1; in_fr "$R" fr/t; old="$(cd "$R" && git rev-parse main)"
( cd "$R" && cap_of cm1 > "$CAPS/$D-fr-cm1.md" )
on_main_has "$R" "$ITEMS/$D-cm1.md" && ( cd "$R" && git show main:"$IDX" | grep -q "| cm1 |" ) && ! on_main_has "$R" "$CAPS/$D-fr-cm1.md" && pass "사전조건: main 에 행+상세, 캡처 없음" || fail "사전조건 실패"
out="$(reg "$R" cm1)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=capture-missing-on-default"* && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "행·상세 동일 + 캡처 없음 → skipped capture-missing-on-default" || fail "capture-missing — rc=$rc $out"
# (5) 같은 blob 캡처만 main 에 선존 → 캡처 제외 커밋 (경로 2개, 형태 검증은 캡처 없음도 통과)
R="$T/t5"; mk_repo "$R"; main_commit_cap "$R" cs1; in_fr "$R" fr/t
add_fr "$R" cs1
on_main_has "$R" "$CAPS/$D-fr-cs1.md" && main_blob_eq "$R" "$CAPS/$D-fr-cs1.md" "$R/$CAPS/$D-fr-cs1.md" && pass "사전조건: main 에 같은 blob 캡처만" || fail "사전조건 실패"
out="$(reg "$R" cs1)"; rc=$?
[[ "$rc" == 0 && "$(line1 "$out")" == "result=committed"*"reason=-" && "$(cd "$R" && git diff-tree --no-commit-id -r --name-only main^ main | wc -l | tr -d ' ')" == 2 ]] && pass "같은 blob 캡처 선존 → 캡처 제외 커밋(경로 2개)" || fail "캡처 선존 — rc=$rc $out"

echo "== AC 4: 기본 브랜치 체크아웃 + clean / 사후 동기화 실패(index.lock) =="
R="$T/r4"; mk_repo "$R"; add_fr "$R" c1
out="$(reg "$R" c1)"; rc=$?
[[ "$rc" == 0 && "$(cd "$R" && git status --porcelain | wc -l | tr -d ' ')" == 0 ]] && pass "committed + status clean" || fail "rc=$rc status=$(cd "$R" && git status --porcelain) — $out"
[[ "$(wt_count "$R")" == 1 && "$(cd "$R" && git for-each-ref | wc -l | tr -d ' ')" == 1 ]] && pass "임시 ref·worktree 없음" || fail "임시 ref/worktree"
add_fr "$R" l1; ( cd "$R" && : > .git/index.lock ); old="$(cd "$R" && git rev-parse main)"
out="$(reg "$R" l1)"; rc=$?
[[ "$rc" == 0 && "$(line1 "$out")" == "result=committed"*"reason=wt-sync-incomplete" && "$out" == *"복구: git reset -q -- "* && "$(cd "$R" && git rev-parse main)" != "$old" ]] && pass "index.lock → committed + wt-sync-incomplete + 복구 명령" || fail "sync 실패 표시 — rc=$rc $out"
( cd "$R" && rm -f .git/index.lock && eval "$(printf '%s\n' "$out" | sed -n 's/.*복구: //p')" )
[[ -z "$(cd "$R" && git status --porcelain)" ]] && pass "복구 명령 실행 후 clean" || fail "복구 후 dirty — $(cd "$R" && git status --porcelain)"

echo "== AC 5: 기본 브랜치 체크아웃 + dirty =="
R="$T/r5"; mk_repo "$R"
( cd "$R" && echo s > staged.txt && git add staged.txt && echo u > CURRENT_TASK.md && echo n > untracked.txt \
  && sed 's/| base-a | a |/| base-a | 선행편집 |/' "$IDX" > "$IDX.n" && mv "$IDX.n" "$IDX" )
add_fr "$R" d1
out="$(reg "$R" d1)"; rc=$?
[[ "$rc" == 0 ]] && pass "committed" || fail "rc=$rc — $out"
st="$(cd "$R" && git status --porcelain)"
[[ "$st" == *"A  staged.txt"* && "$st" == *" M CURRENT_TASK.md"* && "$st" == *"?? untracked.txt"* ]] && pass "등록 경로 외 staged/unstaged/untracked 상태 보존" || fail "상태 변경 — $st"
[[ "$st" == *" M $IDX"* && "$(cd "$R" && git show main:"$IDX")" != *"선행편집"* ]] && pass "인덱스 unstaged 선행 편집은 unstaged 로 남고 커밋 미포함" || fail "선행 편집 — $st"
[[ "$st" != *"$ITEMS/$D-d1.md"* && "$st" != *"fr-d1.md"* ]] && pass "상세·캡처는 clean" || fail "상세/캡처 dirty — $st"
[[ "$(cd "$R" && git diff-tree --no-commit-id -r --name-only main^ main | wc -l | tr -d ' ')" == 3 ]] && pass "커밋에는 등록 경로 3개만" || fail "커밋 경로 수"
add_fr "$R" d2; ( cd "$R" && git add "$IDX" ); old="$(cd "$R" && git rev-parse main)"
out="$(reg "$R" d2)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=staged"* && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "등록 경로 staged → skipped, ref 불변" || fail "rc=$rc — $out"

echo "== AC 6: 기본 브랜치가 다른 worktree 에 체크아웃 =="
R="$T/r6"; mk_repo "$R"; W="$T/r6-wt"; ( cd "$R" && git worktree add -q -b fr/o "$W" main )
add_fr "$W" o
out="$(reg "$W" o)"; rc=$?
[[ "$rc" == 0 && "$(line1 "$out")" == "result=committed"*"reason=-" ]] && pass "committed" || fail "rc=$rc — $out"
[[ -z "$(cd "$R" && git status --porcelain -- "$IDX" "$ITEMS" "$CAPS")" && -f "$R/$ITEMS/$D-o.md" ]] && pass "기본 브랜치 worktree 파일·index 가 새 HEAD 와 일치" || fail "wt 동기화 — $(cd "$R" && git status --porcelain)"
[[ -z "$(ls "$R/rd-workflow-workspace/backlog"/.frr-* 2>/dev/null)" && -n "$(ls "$R/.git/fr-register"/*-index.md 2>/dev/null)" && "$(cat "$R/.git/fr-register"/*-index.md | head -c 4)" == "# FR" ]] && pass "옮긴 원본 인덱스 inode 는 지우지 않고 .git/fr-register/ 에 보관(worktree 에 .frr-* 잔존 없음)" || fail "보관 — $(ls -A "$R/rd-workflow-workspace/backlog") / $(ls -A "$R/.git/fr-register" 2>/dev/null)"
tmp_clean "다른 worktree committed"
# 실패 fixture: 상세 경로에 빈 디렉터리(git 은 무시 → clean) → hard link 생성 실패 → 인덱스 준비분 rollback
( cd "$R" && mkdir -p "$ITEMS/$D-p.md" && echo e > CURRENT_TASK.md )
before_idx="$(cat "$R/$IDX")"; before_ls="$(cd "$R" && git ls-files -s)"; old="$(cd "$R" && git rev-parse main)"
add_fr "$W" p
out="$(reg "$W" p)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=write-failed"* ]] && pass "쓰기 실패 → skipped write-failed" || fail "rc=$rc — $out"
[[ "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "ref 불변" || fail "ref 이동"
[[ "$(cat "$R/$IDX")" == "$before_idx" && "$(cd "$R" && git ls-files -s)" == "$before_ls" ]] && pass "인덱스 파일 바이트·index 항목 원상 복구 (rollback 경유)" || fail "rollback 실패"
[[ "$(cat "$R/CURRENT_TASK.md")" == "e" && ! -e "$R/$CAPS/$D-fr-p.md" && -d "$R/$ITEMS/$D-p.md" && -z "$(ls -A "$R/$ITEMS/$D-p.md")" ]] && pass "기존 unstaged 변경·디렉터리 보존, 디렉터리 안 .frr-* 링크 무잔존, 캡처 미생성" || fail "부수 효과 — $(ls -A "$R/$ITEMS/$D-p.md")"
( cd "$R" && rmdir "$ITEMS/$D-p.md" )
# 디렉터리 symlink 도 같은 계약 — plain ln 은 symlink 대상 디렉터리 안에 링크를 만들며 성공하므로 사전 거부가 있어야 한다.
# symlink 는 ignored 로 두어 dirty 사전 검사(git status 가 untracked symlink 를 보고함)가 아니라 no-clobber 사전 검사에 도달시킨다
( cd "$R" && printf '%s\n' "$ITEMS/$D-ps.md" > .git/info/exclude && mkdir -p "$T/r6-target-dir" && ln -s "$T/r6-target-dir" "$ITEMS/$D-ps.md" )
before_idx="$(cat "$R/$IDX")"; before_ls="$(cd "$R" && git ls-files -s)"; old="$(cd "$R" && git rev-parse main)"
add_fr "$W" ps
out="$(reg "$W" ps)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=write-failed"* && "$(cd "$R" && git rev-parse main)" == "$old" && "$(cat "$R/$IDX")" == "$before_idx" && "$(cd "$R" && git ls-files -s)" == "$before_ls" && -L "$R/$ITEMS/$D-ps.md" && -z "$(ls -A "$T/r6-target-dir")" ]] \
  && pass "디렉터리 symlink 대상 → write-failed, symlink·대상 디렉터리 보존, 보조 링크 무잔존" || fail "디렉터리 symlink — rc=$rc $out $(ls -A "$T/r6-target-dir")"
( cd "$R" && rm -f "$ITEMS/$D-ps.md" && : > .git/info/exclude )
# no-clobber: ignored(git 이 보지 않는) 기존 상세 파일은 덮어쓰지 않고 실패, rollback 도 지우지 않는다
( cd "$R" && printf '%s\n' "$ITEMS/$D-ig.md" > .gitignore && printf 'sentinel bytes\n' > "$ITEMS/$D-ig.md" && git add .gitignore && git commit -q -m ignore )
before_idx="$(cat "$R/$IDX")"; before_ls="$(cd "$R" && git ls-files -s)"; old="$(cd "$R" && git rev-parse main)"
add_fr "$W" ig
out="$(reg "$W" ig)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=write-failed"* ]] && pass "ignored 기존 상세 → no-clobber 실패 → skipped write-failed" || fail "noclobber — rc=$rc $out"
[[ "$(cat "$R/$ITEMS/$D-ig.md")" == "sentinel bytes" && "$(cat "$R/$IDX")" == "$before_idx" && "$(cd "$R" && git ls-files -s)" == "$before_ls" && "$(cd "$R" && git rev-parse main)" == "$old" ]] \
  && pass "기존 ignored 파일 바이트·인덱스·index·ref 보존 (rollback 이 지우지 않음)" || fail "ignored 파일 훼손 또는 ref 이동"
( cd "$R" && rm -f "$ITEMS/$D-ig.md" .gitignore && git add -A && git commit -q -m unignore )
# 대상 worktree 의 조상(items) 이 저장소 밖 디렉터리 symlink — 등록 경로 pathspec 의 status 는 비어 보이지만 밖에 쓰면 안 된다 → skipped path-symlink, 외부 파일 없음, ref 불변
( cd "$R" && mkdir -p "$T/r6-ext-items" && mv "$ITEMS" "$T/r6-items-real" && ln -s "$T/r6-ext-items" "$ITEMS" )
before_idx="$(cat "$R/$IDX")"; old="$(cd "$R" && git rev-parse main)"
add_fr "$W" xs
out="$(reg "$W" xs)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=path-symlink"* && -z "$(ls -A "$T/r6-ext-items")" && "$(cat "$R/$IDX")" == "$before_idx" && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "대상 worktree 조상 symlink → skipped path-symlink, 외부 디렉터리에 쓰지 않음, 인덱스·ref 불변" || fail "대상 조상 symlink — rc=$rc $out / $(ls -A "$T/r6-ext-items")"
( cd "$R" && rm -f "$ITEMS" && mv "$T/r6-items-real" "$ITEMS" )
tmp_clean "다른 worktree 실패"
# dirty 한 다른 worktree → skipped
( cd "$R" && echo dirty >> "$IDX" ); add_fr "$W" q
out="$(reg "$W" q)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=other-worktree-dirty"* ]] && pass "다른 worktree 의 등록 경로 dirty → skipped" || fail "rc=$rc — $out"
( cd "$R" && git checkout -q -- "$IDX" )
# 사전 git 명령 실패(index 읽기 불가) 는 ref 이동 전 git-error 로 중단
if [[ "$(id -u)" != 0 ]]; then
  old="$(cd "$R" && git rev-parse main)"; chmod 000 "$R/.git/index"
  out="$(reg "$W" q)"; rc=$?
  chmod 644 "$R/.git/index"
  [[ "$rc" == 3 && "$out" == *"reason=git-error"* && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "기본 브랜치 worktree status 실패 → skipped git-error, ref 불변" || fail "사전 git 오류 — rc=$rc $out"
else
  echo "  (skip: root 로 실행 중 — 권한 fixture 불가)"
fi

# 훅에서 신호할 대상: process-under-test 가 자기 PID 를 파일에 적고 훅이 그 PID 를 읽는다 — ps·부모 깊이에 의존하지 않아 ps 가 금지된 환경에서도 같다.
#   reg_sig 는 PID 를 적은 뒤 exec 로 rd 를 실행해 PID 가 그대로 helper 셸이 되게 하고, 인라인 bash -c 는 첫 명령으로 $$ 를 적는다.
PIDF="$T/target.pid"
reg_sig() { ( cd "$1" && TMPDIR="$TMPD" bash -c 'echo $$ > "$1"; exec bash rd-workflow/scripts/rd task fr-register --slug "$2"' _ "$PIDF" "$2" 2>&1 ); }
mk_hook() { # mk_hook <stage> <signal> <exit-rc> — reference-transaction 훅: 해당 stage 에서 PID 파일의 프로세스에 신호를 보내고 exit-rc 로 끝난다
  printf '#!/bin/sh\nif [ "$1" = %s ] && grep -q "refs/heads/main"; then kill -%s "$(cat %s)"; exit %s; fi\nexit 0\n' "$1" "$2" "$PIDF" "$3" > "$HK"; chmod +x "$HK"
}
echo "== AC 9: CAS 거부 / 신호 중단 (reference-transaction 훅) =="
_gv="$(git --version | sed 's/[^0-9.]//g')"; _gmaj="${_gv%%.*}"; _gmin="${_gv#*.}"; _gmin="${_gmin%%.*}"
if [[ "$_gmaj" -gt 2 || ( "$_gmaj" -eq 2 && "$_gmin" -ge 28 ) ]]; then
  HK="$R/.git/hooks/reference-transaction"
  # (a) prepared 에서 exit 1 → update-ref 거부 → 준비분 rollback → ref-moved
  printf '#!/bin/sh\n[ "$1" = prepared ] && grep -q "refs/heads/main" && exit 1\nexit 0\n' > "$HK"; chmod +x "$HK"
  before_idx="$(cat "$R/$IDX")"; before_ls="$(cd "$R" && git ls-files -s)"; old="$(cd "$R" && git rev-parse main)"
  out="$(reg "$W" q)"; rc=$?
  [[ "$rc" == 3 && "$out" == *"reason=ref-moved"* ]] && pass "update-ref 거부 → skipped ref-moved" || fail "rc=$rc — $out"
  [[ "$(cd "$R" && git rev-parse main)" == "$old" && "$(cat "$R/$IDX")" == "$before_idx" && "$(cd "$R" && git ls-files -s)" == "$before_ls" && ! -e "$R/$ITEMS/$D-q.md" ]] \
    && pass "ref 불변 + 다른 worktree 준비분(파일·index) rollback" || fail "rollback 실패"
  tmp_clean "CAS 거부"
  # (b) prepared 에서 부모(rd 를 실행하는 bash) 에 TERM + exit 1 → bash 는 자식 종료 후 trap 실행 → prepared rollback + exit 143
  mk_hook prepared TERM 1
  before_idx="$(cat "$R/$IDX")"; before_ls="$(cd "$R" && git ls-files -s)"; old="$(cd "$R" && git rev-parse main)"
  out="$(reg_sig "$W" q)"; rc=$?
  [[ "$rc" == 143 && "$out" == *"result=skipped"*"reason=interrupted"* ]] && pass "CAS 전 SIGTERM → exit 143 + skipped interrupted" || fail "신호(전) — rc=$rc $out"
  [[ "$(cd "$R" && git rev-parse main)" == "$old" && "$(cat "$R/$IDX")" == "$before_idx" && "$(cd "$R" && git ls-files -s)" == "$before_ls" && ! -e "$R/$ITEMS/$D-q.md" ]] \
    && pass "신호(전) 후 ref·인덱스·index·상세 원상" || fail "신호(전) rollback 실패"
  tmp_clean "신호(전)"
  # (c) committed 단계에서 부모에 TERM + exit 0 → ref 는 이동 → committing 재확인으로 committed 로 취급, rollback 하지 않음, SHA 포함 보고
  mk_hook committed TERM 0
  old="$(cd "$R" && git rev-parse main)"
  out="$(reg_sig "$W" q)"; rc=$?
  newq="$(cd "$R" && git rev-parse main)"
  [[ "$rc" == 143 && "$(line1 "$out")" == "result=committed branch=main commit=${newq:0:7} reason=wt-sync-incomplete" && "$newq" != "$old" ]] && pass "CAS 후 SIGTERM → committed + 실제 SHA + wt-sync-incomplete, exit 143" || fail "신호(후) — rc=$rc $out"
  [[ -f "$R/$ITEMS/$D-q.md" && "$out" == *"복구: git -C"* ]] && pass "신호(후) 는 rollback 하지 않고 worktree 복구 명령 안내" || fail "신호(후) 상태 — $(ls "$R/$ITEMS")"
  tmp_clean "신호(후)"
  rm -f "$HK"
else
  echo "  (skip: git < 2.28 — reference-transaction 훅 없음)"
fi

echo "== trap 보존: 실제 INT/TERM 전달 시 기존 핸들러·EXIT 체인·종료 코드 =="
if [[ "$_gmaj" -gt 2 || ( "$_gmaj" -eq 2 && "$_gmin" -ge 28 ) ]]; then
  R="$T/r10"; mk_repo "$R"; W="$T/r10-wt"; ( cd "$R" && git worktree add -q -b fr/s "$W" main ); HK="$R/.git/hooks/reference-transaction"
  # TERM: 기존 TERM 핸들러가 exit 77 → 우리 핸들러(rollback·보고) → 재송신 → 기존 핸들러 → EXIT sentinel(인용 문자 포함) 체인
  mk_hook prepared TERM 1
  add_fr "$W" st1; before_idx="$(cat "$R/$IDX")"; old="$(cd "$R" && git rev-parse main)"
  out="$(cd "$W" && TMPDIR="$TMPD" bash -c "echo \$\$ > $PIDF; trap \"echo 'SENTINEL-EXIT quoted'\" EXIT; trap 'echo SENTINEL-TERM; exit 77' TERM; source rd-workflow/scripts/_fr_register_common.sh; fr_register_run st1" 2>&1)"; rc=$?
  [[ "$rc" == 77 && "$out" == *"result=skipped"*"reason=interrupted"*"SENTINEL-TERM"*"SENTINEL-EXIT quoted"* ]] && pass "TERM: 우리 보고 → 기존 TERM 핸들러(exit 77) → 기존 EXIT(인용 포함) 체인, rc 77" || fail "TERM 체인 — rc=$rc $out"
  [[ "$(cat "$R/$IDX")" == "$before_idx" && ! -e "$R/$ITEMS/$D-st1.md" && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "TERM 체인 뒤 준비분 rollback·ref 불변" || fail "TERM rollback"
  # INT: 기존 INT 핸들러 없음 → 재송신으로 기본 동작(종료) 또는 우리 fallback 130; EXIT sentinel 은 실행
  mk_hook prepared INT 1
  add_fr "$W" st2; before_idx="$(cat "$R/$IDX")"
  out="$(cd "$W" && TMPDIR="$TMPD" bash -c "echo \$\$ > $PIDF; trap 'echo SENTINEL-EXIT' EXIT; source rd-workflow/scripts/_fr_register_common.sh; fr_register_run st2" 2>&1)"; rc=$?
  [[ "$rc" == 130 && "$out" == *"reason=interrupted"*"SENTINEL-EXIT"* && "$(cat "$R/$IDX")" == "$before_idx" && ! -e "$R/$ITEMS/$D-st2.md" ]] && pass "INT: 우리 보고 → 기존 EXIT 실행, rollback, rc 정확히 130" || fail "INT 체인 — rc=$rc $out"
  # INT 에 기존 핸들러가 return 만 하는 경우 → 본문 실행 뒤 우리 코드 130
  add_fr "$W" st3; before_idx="$(cat "$R/$IDX")"
  out="$(cd "$W" && TMPDIR="$TMPD" bash -c "echo \$\$ > $PIDF; trap 'echo SENTINEL-INT-RETURN' INT; source rd-workflow/scripts/_fr_register_common.sh; fr_register_run st3" 2>&1)"; rc=$?
  [[ "$rc" == 130 && "$out" == *"reason=interrupted"*"SENTINEL-INT-RETURN"* && ! -e "$R/$ITEMS/$D-st3.md" ]] && pass "INT: return 하는 기존 핸들러 → 본문 1회 실행 뒤 rc 130" || fail "INT return 체인 — rc=$rc $out"
  tmp_clean "신호 체인"
  rm -f "$HK"
else
  echo "  (skip: git < 2.28)"
fi

echo "== CAS 뒤 finish 경계 신호 → result= 줄 정확히 1개, committed + 실제 SHA (skipped 오보고 없음) =="
R="$T/r11"; mk_repo "$R"; in_fr "$R" fr/f; sha="$(cd "$R" && git rev-parse main)"
# (a) cleanup 중 TERM — 핸들러가 유일한 result 줄(committed+SHA+wt-sync-incomplete) 을 내고 143 으로 종료
out="$(cd "$R" && bash -c 'source rd-workflow/scripts/_fr_register_common.sh; _frr_cleanup() { kill -TERM $$; }; _frr_install_traps; _frr_branch=main; _frr_ref=refs/heads/main; _frr_new='"$sha"'; _frr_paths=(a b); _frr_state=committed; _frr_finish_committed '"${sha:0:7}"' - "FR 등록 커밋: main '"${sha:0:7}"'"' 2>&1)"; rc=$?
nres="$(printf '%s\n' "$out" | grep -c '^result=')"
[[ "$rc" == 143 && "$nres" == 1 && "$(printf '%s\n' "$out" | grep '^result=')" == "result=committed branch=main commit=${sha:0:7} reason=wt-sync-incomplete" && "$out" == *"복구: "* && "$out" != *"skipped"* ]] && pass "cleanup 중 TERM → result 줄 1개 = committed+실제 SHA+wt-sync-incomplete, 복구 안내, rc 143" || fail "finish cleanup 경계 — rc=$rc nres=$nres $out"
# (b) emit 중 TERM — INT/TERM 무시 구간이라 신호는 버려지고 정상 result 줄 1개(reason=-), rc 0
out="$(cd "$R" && bash -c 'source rd-workflow/scripts/_fr_register_common.sh; _frr_emit_orig="$(declare -f _frr_emit)"; eval "${_frr_emit_orig/_frr_emit/_frr_emit_o}"; _frr_emit() { kill -TERM $$; _frr_emit_o "$@"; }; _frr_install_traps; _frr_branch=main; _frr_ref=refs/heads/main; _frr_new='"$sha"'; _frr_paths=(a b); _frr_state=committed; _frr_finish_committed '"${sha:0:7}"' - "FR 등록 커밋: main '"${sha:0:7}"'"; echo "after-finish rc=$? state=$_frr_state"' 2>&1)"; rc=$?
nres="$(printf '%s\n' "$out" | grep -c '^result=')"
[[ "$rc" == 0 && "$nres" == 1 && "$(printf '%s\n' "$out" | grep '^result=')" == "result=committed branch=main commit=${sha:0:7} reason=-" && "$out" == *"after-finish rc=0 state=none"* ]] && pass "emit 중 TERM → 신호 무시, result 줄 1개(reason=-), 정상 return, trap 복원 후 state=none" || fail "finish emit 경계 — rc=$rc nres=$nres $out"

echo "== 디렉터리 생성 경쟁 뒤 신호 rollback: 보조 링크(dst/basename(tmp)) 도 소유권 확인 후 제거 =="
R="$T/r12"; mk_repo "$R"
out="$(cd "$R" && bash -c 'source rd-workflow/scripts/_fr_register_common.sh; _frr_wt="$PWD"; _frr_paths=(); _frr_orig_ls=""; _frr_bak="-"; dst="'"$ITEMS/$D-race.md"'"; mkdir -p "$dst"; tmp="$(mktemp "'"$ITEMS"'/.frr-XXXXXX")" || exit 1; [ -n "$tmp" ] || exit 1; echo x > "$tmp"; _frr_tmp+=("$tmp"); _frr_created+=("$dst"$'"'"'\t'"'"'"$tmp" "$dst/$(basename "$tmp")"$'"'"'\t'"'"'"$tmp"); ln "$tmp" "$dst" ; echo other > "$dst/foreign.txt"; _frr_wt_rollback; _frr_cleanup; ls -A "$dst"' 2>&1)"
[[ "$out" == "foreign.txt" && -d "$R/$ITEMS/$D-race.md" && -z "$(ls "$R/$ITEMS"/.frr-* 2>/dev/null)" ]] && pass "경쟁 보조 링크는 제거, 남의 파일·디렉터리는 보존, 임시 파일 정리" || fail "경쟁 rollback — $out $(ls -A "$R/$ITEMS")"
( cd "$R" && rm -rf "$ITEMS/$D-race.md" )

echo "== trap 보존 / 비정상 종료 시 EXIT rollback =="
R="$T/r8"; mk_repo "$R"; in_fr "$R" fr/e; add_fr "$R" e1
out="$(cd "$R" && bash -c 'trap "echo SENTINEL-EXIT" EXIT; trap "echo SENTINEL-INT" INT; source rd-workflow/scripts/_fr_register_common.sh; fr_register_run e1 >/dev/null; trap -p EXIT; trap -p INT' 2>/dev/null)"
[[ "$out" == *"trap -- 'echo SENTINEL-EXIT' EXIT"* && "$out" == *"'echo SENTINEL-INT'"* && "$out" == *"SENTINEL-EXIT" ]] && pass "정상 return 뒤 기존 EXIT/INT trap 원문 복원 + 기존 EXIT 본문 실행" || fail "trap 보존 — $out"
# prepared 상태에서 set -e 로 비정상 종료 → EXIT 핸들러가 rollback
R="$T/r9"; mk_repo "$R"; W="$T/r9-wt"; ( cd "$R" && git worktree add -q -b fr/e "$W" main ); add_fr "$W" e2
before_idx="$(cat "$R/$IDX")"; before_ls="$(cd "$R" && git ls-files -s)"; old="$(cd "$R" && git rev-parse main)"
out="$(cd "$W" && TMPDIR="$TMPD" bash -c 'set -e; trap "prc=\$?; echo PREV-RC=\$prc; exit \$prc" EXIT; source rd-workflow/scripts/_fr_register_common.sh; _frr_install_traps; _frr_slug=e2; _frr_branch=main; _frr_ref=refs/heads/main; _frr_wt="'"$R"'"; _frr_paths=("'"$IDX"'" "'"$ITEMS/$D-e2.md"'"); _frr_orig_ls="$(git -C "$_frr_wt" ls-files -s -- "${_frr_paths[@]}")"; _frr_mktemp_into _frr_bak; cp "$_frr_wt/'"$IDX"'" "$_frr_bak"; _frr_state=prepared; _frr_mktemp_into nf; { cat "$_frr_bak"; echo prepared-extra; } > "$nf"; _frr_swap_file "$nf" "$_frr_wt/'"$IDX"'" "$_frr_bak"; _frr_create_noclobber "'"$ITEMS/$D-e2.md"'" "$_frr_wt/'"$ITEMS/$D-e2.md"'"; false' 2>&1)"; rc=$?
[[ "$rc" == 1 && "$out" == *"reason=interrupted"*"PREV-RC=1"* && "$(cat "$R/$IDX")" == "$before_idx" && ! -e "$R/$ITEMS/$D-e2.md" && "$(cd "$R" && git rev-parse main)" == "$old" ]] && pass "prepared 중 set -e 종료 → EXIT 핸들러 rollback(인덱스 바이트·생성 파일·ref 원상) + 기존 EXIT 본문이 원 rc(1) 를 관찰·보존" || fail "EXIT rollback — rc=$rc $out"
tmp_clean "EXIT 비정상 종료"

echo "== 캡처 선택(충돌 번호)·symlink 거부·무손실 교체 가드 =="
RC1="$T/r-cap"; mk_repo "$RC1"; in_fr "$RC1" fr/cp; add_fr "$RC1" cp
( cd "$RC1" && printf 'stale\n' > "$CAPS/$D-fr-cp.md" && printf 'latest\n' > "$CAPS/$D-fr-cp-2.md" && printf 'older day\n' > "$CAPS/2026-01-31-fr-cp-9.md" )
out="$(reg "$RC1" cp)"; rc=$?
[[ "$rc" == 0 && "$(cd "$RC1" && git cat-file -p "main:$CAPS/$D-fr-cp-2.md" 2>/dev/null)" == "latest" ]] && pass "같은 날 충돌 번호가 큰 캡처(-2)를 선택(문자열 최대값 아님)" || fail "캡처 선택 — rc=$rc $out $(cd "$RC1" && git ls-tree -r --name-only main -- "$CAPS")"
( cd "$RC1" && ! git cat-file -e "main:$CAPS/$D-fr-cp.md" 2>/dev/null && ! git cat-file -e "main:$CAPS/2026-01-31-fr-cp-9.md" 2>/dev/null ) && pass "무-suffix 원문·이전 날짜 캡처는 커밋되지 않음" || fail "stale 캡처 커밋됨"
RC2="$T/r-sym"; mk_repo "$RC2"; in_fr "$RC2" fr/sy; add_fr "$RC2" sy
( cd "$RC2" && rm -f "$CAPS/$D-fr-sy.md" && printf 'secret\n' > "$T/outside-secret" && ln -s "$T/outside-secret" "$CAPS/$D-fr-sy.md" )
old="$(cd "$RC2" && git rev-parse main)"
out="$(reg "$RC2" sy)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=path-symlink"* && "$(cd "$RC2" && git rev-parse main)" == "$old" ]] && pass "외부 파일을 가리키는 symlink 캡처 → skipped path-symlink, ref 불변" || fail "symlink 캡처 — rc=$rc $out"
# 무손실 교체 가드(단위): 검사~교체 사이 사용자 편집(기대 옛 내용과 다름) → 실패, 사용자 바이트 보존, 잔존 파일 없음
RC3="$T/r-swap"; mkdir -p "$RC3/d"; ( cd "$RC3" && git init -q ); printf 'user edit\n' > "$RC3/d/idx"; printf 'expected old\n' > "$RC3/exp"; printf 'new\n' > "$RC3/new"
out="$(cd "$RC3" && bash -c 'source "'"$SCRIPT_DIR"'/_fr_register_common.sh"; _frr_swap_file new d/idx exp; echo rc=$?; _frr_cleanup' 2>&1)"
[[ "$out" == *"rc=1"* && "$(cat "$RC3/d/idx")" == "user edit" && "$(ls -A "$RC3/d")" == "idx" ]] && pass "교체 가드: 기대 옛 내용과 다르면 실패·사용자 바이트 보존·잔존 없음" || fail "교체 가드 — $out / $(ls -A "$RC3/d")"
# rollback 가드: 교체 성공 뒤 사용자가 내용을 바꾸면 되돌리지 않고 원본 위치를 알린다
printf 'same\n' > "$RC3/d/idx"; printf 'same\n' > "$RC3/exp"
out="$(cd "$RC3" && bash -c 'source "'"$SCRIPT_DIR"'/_fr_register_common.sh"; _frr_wt="'"$RC3"'"; FR_IDX_PATH=d/idx; _frr_paths=(); _frr_orig_ls=""; _frr_swap_file new d/idx exp || echo SWAP-FAIL; printf "user after\n" > d/idx; _frr_wt_rollback; cat d/idx; _frr_cleanup' 2>&1)"
[[ "$out" != *SWAP-FAIL* && "$out" == *"원본을 덮지 않았습니다"*"user after"* && "$(cat "$RC3"/d/.frr-old-*)" == "same" ]] && pass "rollback 가드: helper 가 놓은 뒤 바뀐 파일은 덮지 않고 원본(.frr-old-*) 보존" || fail "rollback 가드 — $out / $(ls -A "$RC3/d")"
# 인덱스 leaf symlink(외부 파일에 일치 행) → 거부, ref 불변
RC4="$T/r-idxsym"; mk_repo "$RC4"; in_fr "$RC4" fr/is; add_fr "$RC4" is
( cd "$RC4" && mv "$IDX" "$T/outside-idx" && ln -s "$T/outside-idx" "$IDX" )
old="$(cd "$RC4" && git rev-parse main)"
out="$(reg "$RC4" is)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=path-symlink"* && "$(cd "$RC4" && git rev-parse main)" == "$old" ]] && pass "인덱스 파일 symlink → skipped path-symlink, ref 불변" || fail "인덱스 symlink — rc=$rc $out"
# no-clobber 복원(단위): "치우기 전 편집 1회 + 링크 뒤 편집 1회" — 두 번째 편집도 덮지 않고 두 버전을 모두 보존한다
RC5="$T/r-restore"; mkdir -p "$RC5/d"; ( cd "$RC5" && git init -q ); printf 'edit-2\n' > "$RC5/d/idx"; printf 'edit-1\n' > "$RC5/old"; printf 'ours\n' > "$RC5/ourstmp"; printf 'ours\n' > "$RC5/want"
out="$(cd "$RC5" && bash -c 'source "'"$SCRIPT_DIR"'/_fr_register_common.sh"; _frr_unclobber_restore old d/idx ourstmp want; echo rc=$?' 2>&1)"
[[ "$out" == *"rc=1"* && "$(cat "$RC5/d/idx")" == "edit-2" && -f "$RC5/old" && "$(cat "$RC5/old")" == "edit-1" && "$(ls -A "$RC5/d")" == "idx" ]] && pass "no-clobber 복원: 링크 뒤 편집(edit-2) 제자리 보존 + 첫 편집(edit-1) 원본 보존, 덮어쓰기 없음" || fail "no-clobber 복원 — $out / $(ls -A "$RC5/d")"
# no-clobber 복원(단위): 대상이 helper 링크 그대로면 원본을 되돌리고 링크·원본 임시명은 남지 않는다
printf 'edit-1\n' > "$RC5/old"; ln -f "$RC5/ourstmp" "$RC5/d/idx"
out="$(cd "$RC5" && bash -c 'source "'"$SCRIPT_DIR"'/_fr_register_common.sh"; _frr_unclobber_restore old d/idx ourstmp want; echo rc=$?' 2>&1)"
[[ "$out" == "rc=0" && "$(cat "$RC5/d/idx")" == "edit-1" && ! -e "$RC5/old" && "$(ls -A "$RC5/d")" == "idx" && "$(cat "$RC5/.git/fr-register"/*-idx-helper)" == "ours" ]] && pass "no-clobber 복원: helper 링크면 원본 복원·worktree 잔존 없음, 치운 helper inode 는 .git/fr-register/ 에 보관" || fail "복원 정상 경로 — $out / $(ls -A "$RC5/d") / $(ls -A "$RC5/.git/fr-register" 2>/dev/null)"
# 열린 FD 늦은 쓰기(e2e, 결정적): 다른 worktree 의 인덱스를 미리 열어 둔 FD 로, 등록이 완전히 끝난(보관까지 끝난) 뒤에 쓴다 → 바이트는 출력에 병기된 보관 경로에 남고 worktree 인덱스는 새 내용 그대로
RC7="$T/r-fd2"; mk_repo "$RC7"; W7="$T/r-fd2-wt"; ( cd "$RC7" && git worktree add -q -b fr/fd "$W7" main ); add_fr "$W7" fd
out="$(cd "$W7" && TMPDIR="$TMPD" bash -c 'exec 9>>"'"$RC7/$IDX"'"; source rd-workflow/scripts/_fr_register_common.sh; fr_register_run fd; rc=$?; printf "late-user-edit\n" >&9; exec 9>&-; echo "run-rc=$rc"' 2>&1)"
pk7="$(printf '%s\n' "$out" | sed -n 's/.*| 보관: \([^ ]*\) (.*/\1/p' | head -1)"
[[ "$out" == *"result=committed"*"reason=-"*"run-rc=0"* && -n "$pk7" && "$(tail -n1 "$pk7")" == "late-user-edit" && "$(cd "$RC7" && git status --porcelain -- "$IDX")" == "" && "$(grep -c "| fd |" "$RC7/$IDX")" == 1 ]] && pass "e2e 늦은 FD 쓰기: 출력에 병기된 보관 경로에 바이트가 남고 worktree 인덱스는 clean·새 내용" || fail "e2e 늦은 FD — $out / pk=$pk7"
# 열린 FD 늦은 쓰기(단위): 교체 전에 열어 둔 FD 로 cmp 뒤에 쓴 바이트는 보관 뒤에도 남는다
RC6="$T/r-fd"; mkdir -p "$RC6/d"; ( cd "$RC6" && git init -q ); printf 'orig\n' > "$RC6/d/idx"; cp "$RC6/d/idx" "$RC6/bak"; printf 'new\n' > "$RC6/new"
out="$(cd "$RC6" && bash -c 'source "'"$SCRIPT_DIR"'/_fr_register_common.sh"; exec 9>>d/idx; _frr_swap_file new d/idx bak || echo SWAP-FAIL; printf "late-user-edit\n" >&9; exec 9>&-; if ! cmp -s "$_frr_idx_old" bak; then p="$(_frr_park "$_frr_idx_old" x-index.md)"; echo "parked=$p"; else echo SAME; fi; _frr_cleanup; cat d/idx' 2>&1)"
pk="$(printf '%s\n' "$out" | sed -n 's/^parked=//p')"
[[ "$out" != *SWAP-FAIL* && "$out" == *"new"* && -n "$pk" && "$(cat "$pk")" == "$(printf 'orig\nlate-user-edit\n')" && "$(ls -A "$RC6/d")" == "idx" ]] && pass "열린 FD 늦은 쓰기: 바이트가 보관 파일에 남고(삭제 없음) 내용 변화가 감지되어 경로 병기" || fail "열린 FD — $out / $(ls -A "$RC6/d")"
# 정상 rollback: 바뀌지 않았으면 원본을 되돌리고 .frr-old 는 남지 않는다
rm -f "$RC3"/d/.frr-old-*; printf 'same\n' > "$RC3/d/idx"
out="$(cd "$RC3" && bash -c 'source "'"$SCRIPT_DIR"'/_fr_register_common.sh"; _frr_wt="'"$RC3"'"; FR_IDX_PATH=d/idx; _frr_paths=(); _frr_orig_ls=""; _frr_swap_file new d/idx exp || echo SWAP-FAIL; _frr_wt_rollback; cat d/idx; _frr_cleanup' 2>&1)"
[[ "$out" == "same" && "$(ls -A "$RC3/d")" == "idx" ]] && pass "정상 rollback: 원본 복원·잔존 없음" || fail "정상 rollback — $out / $(ls -A "$RC3/d")"

echo "== AC 7: 기본 브랜치 ref 부재 =="
R="$T/r7"; mk_repo "$R"; ( cd "$R" && mkdir -p rd-workflow/config && printf '{"default_branch":"trunk"}\n' > rd-workflow/config/workflow.json )
add_fr "$R" n1
out="$(reg "$R" n1)"; rc=$?
[[ "$rc" == 3 && "$out" == *"reason=no-default-ref"* && -f "$R/$ITEMS/$D-n1.md" ]] && pass "ref 부재 → skipped, 등록 파일 유지" || fail "rc=$rc — $out"

echo "fr_register: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
