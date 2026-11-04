#!/usr/bin/env bash
# test_submodule_review.sh — submodule 을 내용으로 세는 보호 트리 해시(spec 2.1 D1~D4)를 검증한다.
# 임시 저장소 안에서만 git 을 쓴다. 이 저장소 자체는 읽지도 고치지도 않는다.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset project_root TASK_STATE_PATH
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_ALLOW_PROTOCOL=file

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP="$(mktemp -d)" || { echo "test_submodule_review.sh: mktemp 실패" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
trap '[[ -z "$TMP" ]] || rm -rf "$TMP"' EXIT
# 작업 디렉터리를 임시 디렉터리로 옮긴다 — 경로 변수가 비어 `git -C ""` 가 되어도 이 저장소가 아니라 임시 디렉터리를 건드린다.
cd "$TMP"
# 빈 경로로 git 이 호출돼도 TMP 의 상위(이 저장소 포함)로 올라가지 않게 한다.
export GIT_CEILING_DIRECTORIES="$(dirname "$TMP")"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/_state_common.sh"
source "$SCRIPT_DIR/_submodule_common.sh"

G() { git -c protocol.file.allow=always "$@"; }

# mk_nested_repo <dir> — inner ⊂ `my mid`(공백 포함) ⊂ top 3단 저장소를 만들고 top 경로를 출력한다.
mk_nested_repo() {
  local d="$1" inner mid top
  inner="$d/inner.git-src"; mid="$d/mid.git-src"; top="$d/top"
  mkdir -p "$inner" "$mid" "$top"
  ( cd "$inner" && git init -q -b main && echo "line1" > f.txt && git add f.txt && git commit -q -m inner1 )
  ( cd "$mid" && git init -q -b main && echo m > m.txt && git add m.txt && git commit -q -m mid0 \
      && G submodule add -q "$inner" inner && git commit -q -m mid1 )
  ( cd "$top" && git init -q -b main && echo t > t.txt && git add t.txt && git commit -q -m top0 \
      && G submodule add -q "$mid" "my mid" \
      && G -C "my mid" submodule update --init -q \
      && git commit -q -m top1 )
  printf '%s\n' "$top"
}

# hash_at <repo> <ref> — repo 를 project_root 로 두고 rd_protected_tree_hash 를 부른다.
hash_at() { ( project_root="$1"; cd "$1" && rd_protected_tree_hash "$2" ); }

# clone_of <commit> <repo> — repo 안에서 같은 트리·다른 커밋(자식 커밋) OID 를 만든다.
sibling_commit() { git -C "$1" commit-tree "$2^{tree}" -p "$2" -m "sibling"; }

# repoint <repo> <path> <oid> <msg> — repo 의 gitlink 를 oid 로 옮겨 커밋하고 새 커밋 OID 를 출력한다.
repoint() {
  git -C "$1" update-index --cacheinfo "160000,$3,$2"
  git -C "$1" commit -q -m "$4"
  git -C "$1" rev-parse HEAD
}

echo "[S1a] gitlink 없는 트리의 해시는 종전 식과 같다"
P="$TMP/plain"; mkdir -p "$P/sub dir" "$P/rd-workflow-workspace/specs"
( cd "$P" && git init -q -b main && echo a > a.txt && echo b > "sub dir/b c.txt" \
    && echo r > rd-workflow-workspace/specs/r.md && echo c > CURRENT_TASK.md && git add -A && git commit -q -m c )
exp_tmp="$TMP/exp"; : > "$exp_tmp"
while IFS= read -r -d '' rec; do
  rd_path_is_record "${rec#*$'\t'}" && continue
  printf '%s\0' "$rec" >> "$exp_tmp"
done < <(git -C "$P" ls-tree -r -z --full-tree HEAD)
exp="$(git -C "$P" hash-object --stdin < "$exp_tmp")"
got="$(hash_at "$P" HEAD)"
[[ "$exp" == "$got" ]] && pass "S1a" || fail "S1a 기대=$exp 실제=$got"

N="$(mk_nested_repo "$TMP/n")"
MID="$N/my mid"; INNER="$MID/inner"
base="$(git -C "$N" rev-parse HEAD)"
M0="$(git -C "$N" rev-parse "HEAD:my mid")"
h_base="$(hash_at "$N" "$base")"

echo "[S2a] 바깥 gitlink 를 같은 트리의 다른 커밋으로 옮겨도 해시 같음"
M1="$(sibling_commit "$MID" "$M0")"
c_a="$(repoint "$N" "my mid" "$M1" "move-outer")"
h_a="$(hash_at "$N" "$c_a")"
[[ "$h_base" == "$h_a" ]] && pass "S2a" || fail "S2a base=$h_base moved=$h_a"

echo "[S2b] 안쪽 저장소만 같은 트리의 다른 커밋으로 옮기고 위로 따라 올려도 해시 같음"
I0="$(git -C "$MID" rev-parse "HEAD:inner")"
I1="$(sibling_commit "$INNER" "$I0")"
M2="$(repoint "$MID" inner "$I1" "mid-follow")"
c_b="$(repoint "$N" "my mid" "$M2" "top-follow")"
h_b="$(hash_at "$N" "$c_b")"
[[ "$h_base" == "$h_b" ]] && pass "S2b" || fail "S2b base=$h_base moved=$h_b"

echo "[S2c] 안쪽 파일 내용을 바꾼 커밋으로 옮기면 해시 다름"
tree_c="$(cd "$INNER" && echo line2 > "$TMP/f2" && blob="$(git hash-object -w "$TMP/f2")" \
  && printf '100644 blob %s\tf.txt\n' "$blob" | git mktree)"
I2="$(git -C "$INNER" commit-tree "$tree_c" -p "$I0" -m change)"
M3="$(repoint "$MID" inner "$I2" "mid-change")"
c_c="$(repoint "$N" "my mid" "$M3" "top-change")"
h_c="$(hash_at "$N" "$c_c")"
[[ "$h_base" != "$h_c" ]] && pass "S2c" || fail "S2c 내용이 달라도 해시가 같음 ($h_c)"

echo "[S2d] 초기화 해제된 submodule 은 commit: 로 센다"
D1="$(repoint "$N" "my mid" "$M1" "d1")"
D1b="$(git -C "$N" commit-tree "HEAD^{tree}" -p HEAD -m d1b)"
D2="$(repoint "$N" "my mid" "$M3" "d2")"
git -C "$N" submodule deinit -f "my mid" >/dev/null 2>&1
if hd1="$(hash_at "$N" "$D1")" && hd1b="$(hash_at "$N" "$D1b")" && hd2="$(hash_at "$N" "$D2")"; then
  [[ "$hd1" == "$hd1b" && "$hd1" != "$hd2" ]] && pass "S2d" || fail "S2d d1=$hd1 d1b=$hd1b d2=$hd2"
else
  fail "S2d rd_protected_tree_hash 가 실패했습니다"
fi

echo "[Sx] 같은 superproject 의 두 worktree 에서 계산한 보호 트리 해시가 같다 (기본 worktree 의 submodule 이 초기화·부분 초기화·미초기화여도)"
X="$TMP/modules/sx"; mkdir -p "$X"   # 상위 경로에 /modules/ 가 있어도 같아야 한다
git init -q --bare -b main "$X/vendor.git"; git init -q --bare -b main "$X/prod.git"
git init -q -b main "$X/vsrc"; ( cd "$X/vsrc" && echo v > v.txt && git add -A && git commit -q -m v && git push -q "$X/vendor.git" main )
git init -q -b main "$X/psrc"; ( cd "$X/psrc" && echo p > p.txt && git add -A && git commit -q -m p && G submodule add -q "$X/vendor.git" vendor \
  && git commit -q -m pv && git push -q "$X/prod.git" main )
git init -q -b main "$X/top"; ( cd "$X/top" && echo t > t.txt && G submodule add -q "$X/prod.git" libs/prod && git add -A && git commit -q -m top \
  && G submodule update -q --init --recursive && git worktree add -q -b work "$X/wt" )
G -C "$X/wt" submodule update -q --init --recursive
# 작업 worktree 에서만 중첩 submodule 과 바깥 submodule 에 커밋을 만들고 상위에 기록한다(push 하지 않음).
echo v2 >> "$X/wt/libs/prod/vendor/v.txt"; git -C "$X/wt/libs/prod/vendor" commit -q -am v2
git -C "$X/wt/libs/prod" add vendor; git -C "$X/wt/libs/prod" commit -q -m pv2
git -C "$X/wt" add libs/prod; git -C "$X/wt" commit -q -m "record"
sx_wt="$( cd "$X/wt" && rd_protected_tree_hash HEAD )"
sx_chk() {  # <라벨> — 기본 worktree 의 현재 초기화 상태에서 같은 커밋의 해시를 비교한다
  local m; m="$( cd "$X/top" && rd_protected_tree_hash work )" || m="실패"
  [[ -n "$sx_wt" && "$sx_wt" == "$m" ]] && pass "Sx $1" || fail "Sx $1: 작업 worktree=$sx_wt 기본 worktree=$m"
}
sx_chk "재귀 초기화"
G -C "$X/top" submodule deinit -q -f libs/prod; sx_chk "미초기화"
G -C "$X/top" submodule update -q --init libs/prod; sx_chk "바깥만 초기화"

# ===========================================================================
# 리뷰 입력 (spec 2.2 D5~D8) — S3 단위, S4 호출 지점
# ===========================================================================

RD_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

# nested_copy <dir> — 한 번 만든 3단 저장소 틀(tpl)을 복사해 시간을 아낀다. top 경로를 출력한다.
# submodule 의 .git 파일·core.worktree 가 상대 경로라 복사해도 동작하고, url 은 틀 안의 원본을 가리킨다.
nested_copy() {
  local d="$1"
  [[ -d "$TMP/tpl/top" ]] || mk_nested_repo "$TMP/tpl" >/dev/null
  cp -R "$TMP/tpl" "$d" && printf '%s\n' "$d/top"
}

has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
head_of() { git -C "$1" rev-parse HEAD; }
# bump <top> <내용> — inner 에 커밋을 더하고 mid·top 이 따라 올라가게 한다.
bump() {
  ( cd "$1/my mid/inner" && echo "$2" >> f.txt && git commit -q -am "i-$2" ) \
    && ( cd "$1/my mid" && git add -f inner && git commit -q -m "m-$2" ) \
    && git -C "$1" add -f "my mid" && git -C "$1" commit -q -m "t-$2"
}
# erase_inner_head <inner> — inner 의 HEAD 커밋 객체를 저장소에서 지운다.
erase_inner_head() {
  git -C "$1" reset -q --hard HEAD~1
  git -C "$1" reflog expire --expire=now --all
  git -C "$1" gc -q --prune=now
}
# chk <repo> <base> <head> — rd_review_input_check 를 repo 에서 실행. rc 는 CK_RC, stderr 는 CK_ERR.
chk() {
  CK_RC=0
  CK_ERR="$( cd "$1" && rd_review_input_check "$2" "$3" 2>&1 >/dev/null )" || CK_RC=$?
}
# tgt_out <repo> <base> <head> — 대상 명령을 repo 에서 실행한 출력.
tgt_out() { ( cd "$1" && eval "$(rd_review_diff_target "$2" "$3")" ); }

# --- S4 fixture: rd-workflow 를 임시 저장소에 설치한다 (test_review_base_resolution.sh 와 같은 구성).
# 산출물은 저장소 밖 OUT 에 남긴다 (저장소 안에 남기면 보호 트리 해시가 바뀐다).
OUT="$TMP/out"; mkdir -p "$OUT"
TOOLS_JSON="$OUT/review-tools.json"
printf '{"default_priority":["codex"],"tools":{"codex":{"bin":"bash"}}}' > "$TOOLS_JSON"
SESS_REL="rd-workflow-workspace/handoffs/review_pipeline"
mk_rd_fixture() {
  local d="$1"
  mkdir -p "$d/rd-workflow/scripts/hooks" "$d/rd-workflow/scripts/lifecycle" "$d/rd-workflow-workspace/.lifecycle" "$d/$SESS_REL"
  if [[ -f "$RD_SRC/VERSION" ]]; then cp "$RD_SRC/VERSION" "$d/rd-workflow/VERSION"; else echo "0000-00-00-000000" > "$d/rd-workflow/VERSION"; fi
  cp "$RD_SRC/scripts/prepare_review_pipeline.sh" "$RD_SRC/scripts/init_review_pipeline.sh" \
     "$RD_SRC/scripts/run_review_turn.sh" "$RD_SRC/scripts/review_common.sh" \
     "$RD_SRC/scripts/_state_common.sh" "$RD_SRC/scripts/_submodule_common.sh" "$RD_SRC/scripts/_task_common.sh" \
     "$RD_SRC/scripts/rd" "$RD_SRC/scripts/verify_record.sh" "$d/rd-workflow/scripts/"
  cp "$RD_SRC/scripts/hooks/_guard_common.sh" "$RD_SRC/scripts/hooks/_open_issues.awk" "$d/rd-workflow/scripts/hooks/"
  cp "$RD_SRC/scripts/lifecycle/_lifecycle_common.sh" "$RD_SRC/scripts/lifecycle/slug.sh" "$RD_SRC/scripts/lifecycle/_tasks_index.sh" "$RD_SRC/scripts/lifecycle/session_launch.sh" "$d/rd-workflow/scripts/lifecycle/"
  cat > "$d/rd-workflow/scripts/adapter_codex.sh" <<'ADAPTER'
#!/usr/bin/env bash
: > "${RD_TEST_OUT}/adapter-called"
printf '# Turn — Reviewer\n이의 없음\n' > "$EXPECTED_TURN_FILE"
sed -i.bak -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"
exit 0
ADAPTER
  : > "$d/rd-workflow-workspace/.gitkeep"
  printf '# Current Task\n\n## Short Title\ndemo\n\n## Status\n구현 중\n' > "$d/CURRENT_TASK.md"
  printf '# Change Request\n\n## Source FR\n-\n' > "$d/REQUEST.md"
  printf 'schema=1\nshort-title=demo\nstatus=구현 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$d/rd-workflow-workspace/.lifecycle/task-state"
  git -C "$d" add -A && git -C "$d" commit -q -m "rd fixture"
}
# prep_diff <repo> <base> — prepare_review_pipeline.sh diff --base. 출력은 OUT/prep.{out,err}, rc 는 PREP_RC.
prep_diff() {
  PREP_RC=0
  ( cd "$1" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff --base "$2" ) >"$OUT/prep.out" 2>"$OUT/prep.err" || PREP_RC=$?
}
sess_of() { printf '%s/%s/%s\n' "$1" "$SESS_REL" "$(ls "$1/$SESS_REL" | head -1)"; }
session_target() { awk '$0=="## Review Target"{f=1;next} f&&/^## /{exit} f&&NF{print;exit}' "$1/SESSION.md"; }
# run_turn <repo> <session> — run_review_turn.sh. 출력은 OUT/turn.{out,err}, rc 는 TURN_RC.
run_turn() {
  TURN_RC=0
  rm -f "$OUT/adapter-called"
  ( cd "$1" && RD_TEST_OUT="$OUT" REVIEW_TOOLS_CONFIG="$TOOLS_JSON" bash rd-workflow/scripts/run_review_turn.sh "${2#$1/}" ) \
    >"$OUT/turn.out" 2>"$OUT/turn.err" || TURN_RC=$?
}
# set_session_state <session> <status> <owner>
set_session_state() {
  awk -v st="$2" -v ow="$3" '{ if (sec=="s"&&NF){print st;sec="";next} if (sec=="o"&&NF){print ow;sec="";next}
         if($0=="## Status")sec="s"; else if($0=="## Current Owner")sec="o"; print }' "$1/SESSION.md" > "$1/.t" \
    && cat "$1/.t" > "$1/SESSION.md" && rm -f "$1/.t"
}
# set_awaiting_reviewer <session> — author 턴을 하나 두고 reviewer 차례로 만든다.
set_awaiting_reviewer() {
  local sess="$1" idx
  mkdir -p "$sess/turns"
  idx="$(printf '%03d' $(( $(ls "$sess/turns" | wc -l | tr -d ' ') + 1 )))"
  printf '# Turn %s — Author\n반영했습니다.\n' "$idx" > "$sess/turns/${idx}_author.md"
  set_session_state "$sess" awaiting-reviewer Reviewer
}
# close_session <session> — 종결 상태 (Status=closed, Open Issues 없음)
close_session() {
  set_session_state "$1" closed Author
  printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "$1/CHECKPOINT.md"
}
# seal_with_evidence <repo> <session> — verify_record 증거를 직접 깔고 rd review seal. rc 는 SEAL_RC, 출력은 OUT/seal.{out,err}.
seal_with_evidence() {
  local repo="$1" sess="$2" h oid
  h="$( ( project_root="$repo"; export project_root; source "$repo/rd-workflow/scripts/_state_common.sh"; rd_protected_tree_hash HEAD ) )"
  oid="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "$repo/rd-workflow-workspace/.lifecycle/review-seals"
  printf 'schema=1\ncommand=true\nexit-code=0\ntree-hash=%s\nhead=%s\nrecorded-at=2026-10-29-0000\n' "$h" "$oid" \
    > "$repo/rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"
  SEAL_RC=0
  ( cd "$repo" && bash rd-workflow/scripts/rd review seal "${sess#$repo/}" ) >"$OUT/seal.out" 2>"$OUT/seal.err" || SEAL_RC=$?
}

echo "[S3a] gitlink 없는 구간의 대상 문자열은 종전과 글자 그대로 같다"
N3="$(nested_copy "$TMP/s3a")"
A="$(head_of "$N3")"; echo more >> "$N3/t.txt"; git -C "$N3" commit -q -am plain; B="$(head_of "$N3")"
got="$(cd "$N3" && rd_review_diff_target "$A" "$B")"
[[ "$got" == "git diff $A..$B" ]] && pass "S3a" || fail "S3a 실제=[$got]"

echo "[S3c] 바깥 diff.ignoreSubmodules=all 이어도 안쪽 코드를 펼친다"
N3="$(nested_copy "$TMP/s3c")"
git -C "$N3" config diff.ignoreSubmodules all
A="$(head_of "$N3")"; bump "$N3" two; B="$(head_of "$N3")"
got="$(cd "$N3" && rd_review_diff_target "$A" "$B")"; chk "$N3" "$A" "$B"; o="$(tgt_out "$N3" "$A" "$B")"
[[ "$got" == *"--submodule=diff"* && "$CK_RC" == 0 ]] && has "diff --git a/my mid/inner/f.txt b/my mid/inner/f.txt" "$o" \
  && pass "S3c" || fail "S3c target=[$got] rc=$CK_RC err=$CK_ERR"

echo "[S3c3] 사용자 diff.noprefix·color.ui=always 설정이어도 입력 검사는 거짓 차단하지 않는다"
mkdir -p "$TMP/s3c3" && ( cd "$TMP/s3c3" && git init -q lib && cd lib && echo a > f && git add f && git commit -q -m l1 )
git init -q "$TMP/s3c3/sup" && git -C "$TMP/s3c3/sup" commit -q --allow-empty -m s0
N3="$TMP/s3c3/sup"; A="$(head_of "$N3")"
G -C "$N3" submodule -q add "$TMP/s3c3/lib" libs/lib && git -C "$N3" commit -q -m add
( cd "$N3/libs/lib" && echo b >> f && git commit -q -am l2 ) && git -C "$N3" add libs/lib && git -C "$N3" commit -q -m bump; B="$(head_of "$N3")"
git -C "$N3" config diff.noprefix true; git -C "$N3" config color.ui always
chk "$N3" "$A" "$B"
[[ "$CK_RC" == 0 ]] && pass "S3c3" || fail "S3c3 rc=$CK_RC err=$CK_ERR"
# 같은 fixture 에 diff.external 을 켠다: 검사가 통과하면 리뷰어가 실행할 대상 명령의 출력에도 안쪽 파일 머리줄이 있어야 한다 (검사 명령 = 리뷰 명령).
git -C "$N3" config diff.external true
chk "$N3" "$A" "$B"; o="$(tgt_out "$N3" "$A" "$B")"
[[ "$CK_RC" == 0 ]] && has "diff --git a/libs/lib/f b/libs/lib/f" "$o" \
  && pass "S3c3 diff.external 이어도 대상 출력에 안쪽 코드" || fail "S3c3 diff.external rc=$CK_RC bytes=${#o} err=$CK_ERR"

echo "[S3c2] 바깥 .gitmodules 의 이름별 ignore=all 도 이긴다"
N3="$(nested_copy "$TMP/s3c2")"
git -C "$N3" config -f .gitmodules "submodule.my mid.ignore" all; git -C "$N3" commit -q -am ign
A="$(head_of "$N3")"; bump "$N3" two; B="$(head_of "$N3")"
got="$(cd "$N3" && rd_review_diff_target "$A" "$B")"; chk "$N3" "$A" "$B"; o="$(tgt_out "$N3" "$A" "$B")"
[[ "$got" == *"--submodule=diff"* && "$CK_RC" == 0 ]] && has "diff --git a/my mid/inner/f.txt b/my mid/inner/f.txt" "$o" \
  && pass "S3c2" || fail "S3c2 target=[$got] rc=$CK_RC err=$CK_ERR"

echo "[S3d] 안쪽 .gitmodules 의 ignore=all 은 출력 누락으로 차단한다"
N3="$(nested_copy "$TMP/s3d")"
A="$(head_of "$N3")"
git -C "$N3/my mid" config -f .gitmodules "submodule.inner.ignore" all; git -C "$N3/my mid" add .gitmodules; git -C "$N3/my mid" commit -q -m ign-inner
bump "$N3" two; B="$(head_of "$N3")"
chk "$N3" "$A" "$B"
[[ "$CK_RC" == 1 ]] && has "출력 누락" "$CK_ERR" && has "my mid/inner/" "$CK_ERR" \
  && pass "S3d" || fail "S3d rc=$CK_RC err=$CK_ERR"

echo "[S3e] 새 커밋 객체가 없으면 객체 부재로 차단한다"
N3="$(nested_copy "$TMP/s3e")"
A="$(head_of "$N3")"; bump "$N3" two; B="$(head_of "$N3")"
erase_inner_head "$N3/my mid/inner"
chk "$N3" "$A" "$B"
[[ "$CK_RC" == 1 ]] && has "객체 부재" "$CK_ERR" && pass "S3e" || fail "S3e rc=$CK_RC err=$CK_ERR"

echo "[S3f] 새로 추가된 submodule 은 기대 목록에 들어간다"
N3="$(nested_copy "$TMP/s3f")"
mkdir -p "$TMP/s3f/ext" && ( cd "$TMP/s3f/ext" && git init -q -b main && echo e > e.txt && git add e.txt && git commit -q -m e )
A="$(head_of "$N3")"
G -C "$N3" submodule add -q "$TMP/s3f/ext" "new sub" && git -C "$N3" commit -q -m add-new; B="$(head_of "$N3")"
chk "$N3" "$A" "$B"; o="$(tgt_out "$N3" "$A" "$B")"
[[ "$CK_RC" == 0 ]] && has "diff --git a/new sub/e.txt b/new sub/e.txt" "$o" && pass "S3f 최상위 추가 rc=0" || fail "S3f 최상위 추가 rc=$CK_RC err=$CK_ERR"
# 중간 단계(my mid)에 새 submodule 을 더하고 그 .gitmodules 가 ignore=all 로 숨기는 구간
N3="$(nested_copy "$TMP/s3f2")"
mkdir -p "$TMP/s3f2/ext" && ( cd "$TMP/s3f2/ext" && git init -q -b main && echo e > e.txt && git add e.txt && git commit -q -m e )
A="$(head_of "$N3")"
( cd "$N3/my mid" && G submodule add -q "$TMP/s3f2/ext" "new in" && git config -f .gitmodules "submodule.new in.ignore" all && git add -A && git commit -q -m add-in-ignored )
git -C "$N3" add -f "my mid" && git -C "$N3" commit -q -m t-add-in; B="$(head_of "$N3")"
chk "$N3" "$A" "$B"
[[ "$CK_RC" == 1 ]] && has "my mid/new in/e.txt" "$CK_ERR" && pass "S3f 숨겨진 새 submodule rc=1" || fail "S3f 숨겨진 새 submodule rc=$CK_RC err=$CK_ERR"

echo "[S3g] 한쪽이 일반 파일이거나 사라지는 gitlink 의 mode 조합 (R4)"
# gitlink -> 일반 파일 (head 체크아웃에 저장소가 없음)
N3="$(nested_copy "$TMP/s3g1")"
A="$(head_of "$N3")"
git -C "$N3" rm -q "my mid" && echo x > "$N3/my mid" && git -C "$N3" add -A && git -C "$N3" commit -q -m tofile; B="$(head_of "$N3")"
chk "$N3" "$A" "$B"
[[ "$CK_RC" == 0 ]] && pass "S3g gitlink→파일 rc=0" || fail "S3g gitlink→파일 rc=$CK_RC err=$CK_ERR"
# gitlink 삭제
N3="$(nested_copy "$TMP/s3g2")"
A="$(head_of "$N3")"
git -C "$N3" rm -q "my mid" && git -C "$N3" commit -q -m del; B="$(head_of "$N3")"
chk "$N3" "$A" "$B"
[[ "$CK_RC" == 0 ]] && pass "S3g gitlink 삭제 rc=0" || fail "S3g gitlink 삭제 rc=$CK_RC err=$CK_ERR"
# 일반 파일 -> gitlink
N3="$(nested_copy "$TMP/s3g3")"
echo doc > "$N3/docs"; git -C "$N3" add docs; git -C "$N3" commit -q -m doc-file
A="$(head_of "$N3")"
git -C "$N3" rm -q -f docs
G -C "$N3" submodule add -q --force --name conv "$TMP/s3g3/inner.git-src" docs
( cd "$N3/docs" && echo more > g.txt && git add g.txt && git commit -q -m extra )
git -C "$N3" add docs && git -C "$N3" commit -q -m conv; B="$(head_of "$N3")"
chk "$N3" "$A" "$B"; o="$(tgt_out "$N3" "$A" "$B")"
[[ "$CK_RC" == 0 ]] && has "diff --git a/docs/g.txt b/docs/g.txt" "$o" && pass "S3g 파일→gitlink rc=0" || fail "S3g 파일→gitlink rc=$CK_RC err=$CK_ERR"
erase_inner_head "$N3/docs"
chk "$N3" "$A" "$B"
[[ "$CK_RC" == 1 ]] && has "객체 부재" "$CK_ERR" && pass "S3g 파일→gitlink 객체 부재" || fail "S3g 파일→gitlink 객체 부재 rc=$CK_RC err=$CK_ERR"

echo "[S3h] 중첩 단계에서 submodule 이 삭제되면 그 단계 기준 (submodule deleted) 머리줄을 대조한다"
N3="$(nested_copy "$TMP/s3h")"
A="$(head_of "$N3")"
git -C "$N3/my mid" rm -q inner && git -C "$N3/my mid" commit -q -m del-inner
git -C "$N3" add -f "my mid" && git -C "$N3" commit -q -m t-del-inner; B="$(head_of "$N3")"
chk "$N3" "$A" "$B"; o="$(tgt_out "$N3" "$A" "$B")"
[[ "$CK_RC" == 0 ]] && has "Submodule inner " "$o" && pass "S3h" || fail "S3h rc=$CK_RC err=$CK_ERR out=$(printf '%s' "$o" | grep -a '^Submodule' | head -3)"

echo "[S3i] 판정 불가(diff-tree 실패)는 명령 실패로 차단하고 대상 문자열은 submodule 형식이다"
N3="$(nested_copy "$TMP/s3i")"
A="$(head_of "$N3")"; bad="0000000000000000000000000000000000000001"
chk "$N3" "$A" "$bad"; got="$(cd "$N3" && rd_review_diff_target "$A" "$bad")"
[[ "$CK_RC" == 1 ]] && has "명령 실패" "$CK_ERR" && [[ "$got" == *"--submodule=diff"* ]] && pass "S3i" || fail "S3i rc=$CK_RC err=$CK_ERR target=$got"

echo "[S4a] prepare diff 가 base·head OID 와 submodule 형식 Review Target 을 기록한다"
N4="$(nested_copy "$TMP/s4")"
mk_rd_fixture "$N4"
A4="$(head_of "$N4")"; bump "$N4" two; B4="$(head_of "$N4")"
prep_diff "$N4" "$A4"
S4="$(sess_of "$N4")"
[[ "$PREP_RC" == 0 ]] && grep -q "^- review-base-oid: $A4" "$S4/SESSION.md" && grep -q "^- review-head-oid: $B4" "$S4/SESSION.md" \
  && [[ "$(session_target "$S4")" == "$(cd "$N4" && rd_review_diff_target "$A4" "$B4")" && "$(session_target "$S4")" == *"--submodule=diff"* ]] \
  && pass "S4a" || fail "S4a rc=$PREP_RC err=$(cat "$OUT/prep.err")"

echo "[S4c] seal 은 마커를 만들고, 객체가 사라지면 거부한다"
set_awaiting_reviewer "$S4"; close_session "$S4"
seal_with_evidence "$N4" "$S4"
M4="$(ls "$N4/rd-workflow-workspace/.lifecycle/review-seals/"*.seal 2>/dev/null | head -1 || true)"
[[ "$SEAL_RC" == 0 && -n "$M4" ]] && grep -q "verified=yes" "$M4" && pass "S4c 마커 생성" || fail "S4c 마커 rc=$SEAL_RC err=$(cat "$OUT/seal.err")"
rm -f "$N4/rd-workflow-workspace/.lifecycle/review-seals/"*.seal
erase_inner_head "$N4/my mid/inner"
seal_with_evidence "$N4" "$S4"
[[ "$SEAL_RC" != 0 && -z "$(ls "$N4/rd-workflow-workspace/.lifecycle/review-seals/"*.seal 2>/dev/null || true)" ]] \
  && has "리뷰 입력이 submodule 코드를 담지 못합니다" "$(cat "$OUT/seal.err")" \
  && pass "S4c 객체 삭제 뒤 거부" || fail "S4c 거부 rc=$SEAL_RC err=$(cat "$OUT/seal.err")"

echo "[S4b] 객체가 없으면 prepare 가 새 세션을 만들지 않는다 (S4c 끝의 객체 삭제 상태 재사용)"
n_before="$(ls "$N4/$SESS_REL" | wc -l | tr -d ' ')"
prep_diff "$N4" "$A4"
[[ "$PREP_RC" != 0 && "$(ls "$N4/$SESS_REL" | wc -l | tr -d ' ')" == "$n_before" ]] && has "객체 부재" "$(cat "$OUT/prep.err")" \
  && pass "S4b" || fail "S4b rc=$PREP_RC sessions=$(ls "$N4/$SESS_REL") err=$(cat "$OUT/prep.err")"

echo "[S4d] run_review_turn 의 재렌더링은 같은 대상 문자열을 쓰고, 차단되면 dispatch 하지 않는다"
N4d="$(nested_copy "$TMP/s4d")"
mk_rd_fixture "$N4d"
A4d="$(head_of "$N4d")"; bump "$N4d" two
prep_diff "$N4d" "$A4d"; S4d="$(sess_of "$N4d")"
bump "$N4d" three; B4d="$(head_of "$N4d")"
set_awaiting_reviewer "$S4d"
run_turn "$N4d" "$S4d"
[[ "$TURN_RC" == 0 && -f "$OUT/adapter-called" && "$(session_target "$S4d")" == "$(cd "$N4d" && rd_review_diff_target "$A4d" "$B4d")" ]] \
  && pass "S4d 재렌더링·dispatch" || fail "S4d rc=$TURN_RC target=$(session_target "$S4d") err=$(cat "$OUT/turn.err")"
# 같은 fixture 를 이어, 안쪽 ignore=all 로 출력이 누락되는 구간: 차단, dispatch 없음, SESSION 불변, 임시 파일 없음
git -C "$N4d/my mid" config -f .gitmodules "submodule.inner.ignore" all; git -C "$N4d/my mid" add .gitmodules; git -C "$N4d/my mid" commit -q -m ign-inner
git -C "$N4d" add -f "my mid" && git -C "$N4d" commit -q -m t-ign; bump "$N4d" four
set_awaiting_reviewer "$S4d"; cp "$S4d/SESSION.md" "$OUT/session-prerun.md"
run_turn "$N4d" "$S4d"
[[ "$TURN_RC" != 0 && ! -f "$OUT/adapter-called" ]] && cmp -s "$OUT/session-prerun.md" "$S4d/SESSION.md" && has "출력 누락" "$(cat "$OUT/turn.err")" \
  && pass "S4d 차단 시 dispatch 없음·SESSION 불변" || fail "S4d 차단 rc=$TURN_RC called=$([[ -f "$OUT/adapter-called" ]] && echo y || echo n) err=$(cat "$OUT/turn.err")"
[[ -z "$(ls -a "$S4d" | grep '^\.SESSION\.md\.' || true)" ]] && pass "S4d 차단 뒤 임시 파일 없음" || fail "S4d 임시 파일이 남음: $(ls -a "$S4d" | grep '^\.SESSION\.md\.')"

echo "  결과: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
