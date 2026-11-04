#!/usr/bin/env bash
# test_archive_submodule.sh — submodule 을 품은 작업 worktree 의 정리(spec 2.4 D15~D18)를 검증한다.
# git 은 전부 mktemp -d 안의 임시 저장소에서만 실행한다.
set -euo pipefail
trap 'ec=$?; echo "  FAIL: 스위트가 line ${LINENO} 에서 rc=${ec} 로 중단됐습니다 (조용한 중단)" >&2' ERR
DONE=0
_cleanup=()
_on_exit() {
  local _ec=$? _d
  for _d in ${_cleanup[@]+"${_cleanup[@]}"}; do [[ -z "$_d" ]] || rm -rf "$_d"; done
  [[ "$DONE" == 1 ]] || echo "  FAIL: 스위트가 결과줄 없이 rc=${_ec} 로 중단됐습니다" >&2
}
trap _on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HERDR_ENV=
export RD_CHILD_SESSION=1
unset project_root TASK_STATE_PATH
# 로컬 file 프로토콜 submodule 을 하위 프로세스(promote·archive 포함)까지 허용한다.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

TMP="$(mktemp -d)" || { echo "test_archive_submodule.sh: mktemp 실패" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_archive_submodule.sh: 임시 경로 검증 실패" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
_cleanup+=("$TMP")
cd "$TMP"
# 빈 경로 `git -C ""` 같은 실수가 작업 worktree 에 닿지 않도록 TMP 위로 git 탐색을 막는다.
export GIT_CEILING_DIRECTORIES="$(dirname "$TMP")"

# mk_sub_consumer <dir> — 로컬 bare 원격 overlay.git·prod.git·vendor.git 을 만들고, overlay 에
# `libs/prod` submodule(그 안에 중첩 submodule `vendor`)과 rd-workflow 설치를 담은 저장소 경로를 출력한다.
mk_sub_consumer() {
  local d="$1" r="$1/repo" s
  mkdir -p "$d"
  git init -q --bare -b main "$d/vendor.git"
  git init -q --bare -b main "$d/prod.git"
  git init -q --bare -b main "$d/overlay.git"
  s="$d/vendor-src"; git init -q -b main "$s"
  ( cd "$s" && echo v > v.txt && git add -A && git commit -q -m vendor && git push -q "$d/vendor.git" main )
  s="$d/prod-src"; git init -q -b main "$s"
  ( cd "$s" && echo p > p.txt && git add -A && git commit -q -m prod \
    && git submodule add -q "$d/vendor.git" vendor && git commit -q -m "prod: vendor" \
    && git push -q "$d/prod.git" main )
  mkdir -p "$r/rd-workflow"
  cp -R "$SCRIPT_DIR/.." "$r/rd-workflow/scripts"
  git init -q -b main "$r"
  mkdir -p "$r/rd-workflow-workspace/.lifecycle" "$r/rd-workflow-workspace/backlog/items"
  cp "$SCRIPT_DIR/../../../.gitignore" "$r/.gitignore"
  bash -c "source '$SCRIPT_DIR/_lifecycle_common.sh'; emit_current_task_baseline" > "$r/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
    > "$r/rd-workflow-workspace/.lifecycle/task-state"
  printf '# Change Request\n\n## Source FR\n-\n' > "$r/REQUEST.md"
  ( cd "$r" && git submodule add -q "$d/prod.git" libs/prod \
    && git -C libs/prod submodule update -q --init \
    && git add -A && git commit -q -m seed \
    && git remote add origin "$d/overlay.git" && git push -q origin main )
  printf '%s\n' "$r"
}

# 템플릿 consumer 는 한 번만 만든다(느린 부분). 케이스마다 repo 와 overlay.git 을 복사해 쓰고,
# prod.git·vendor.git 은 공유한다 — 케이스의 submodule push 는 케이스 이름의 브랜치로만 해 서로 간섭하지 않는다.
TEMPLATE_DIR="$TMP/_template"
mk_sub_consumer "$TEMPLATE_DIR" >/dev/null

# prep_case <name> — 템플릿을 복사하고 promote 한 뒤 작업 worktree 의 submodule 을 초기화한다(재귀).
#   전역: CASE_NAME CASE_REPO CASE_WT
prep_case() {
  CASE_NAME="$1"
  mkdir -p "$TMP/$1"
  cp -R "$TEMPLATE_DIR/repo" "$TMP/$1/repo"
  cp -R "$TEMPLATE_DIR/overlay.git" "$TMP/$1/overlay.git"
  CASE_REPO="$TMP/$1/repo"
  git -C "$CASE_REPO" remote set-url origin "$TMP/$1/overlay.git"
  bash "$CASE_REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title "$1" --size large --source-fr - >/dev/null 2>&1 \
    || { echo "promote 실패: $1" >&2; exit 1; }
  CASE_WT="$CASE_REPO/.worktrees/$1"
  git -C "$CASE_WT" submodule update -q --init --recursive
  git -C "$CASE_WT/libs/prod" config user.email t@t
  git -C "$CASE_WT/libs/prod" config user.name t
}
# sub_push <wt> — submodule libs/prod 의 HEAD 를 원격 prod.git 의 케이스 브랜치로 push 한다.
sub_push() { git -C "$1/libs/prod" push -q origin "HEAD:refs/heads/$CASE_NAME"; }

# sub_commit <wt> — submodule libs/prod 에 커밋 하나를 만든다. (push 는 호출자가 결정)
sub_commit() { echo "c-$RANDOM" >> "$1/libs/prod/p.txt"; git -C "$1/libs/prod" commit -q -am "sub change"; }
# record_gitlink <wt> — gitlink 를 올리는 작업 커밋(실제 변경 하나 포함).
record_gitlink() { echo work > "$1/work.txt"; git -C "$1" add -A; git -C "$1" commit -q -m "구현: gitlink"; }

run_archive() {  # <repo> <slug> [--force-dirty] — 기본 worktree 에서 --task 로 호출한다. 출력은 ARCH_OUT, rc 는 ARCH_RC.
  ARCH_RC=0
  ARCH_OUT="$( cd "$1" && bash rd-workflow/scripts/lifecycle/archive.sh --task "$2" --no-remote ${3:+"$3"} \
    --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || ARCH_RC=$?
}

echo "== W1: 푸시·gitlink 반영 완료 — submodule worktree 제거 =="
prep_case w1
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
run_archive "$CASE_REPO" w1
if [[ "$ARCH_RC" == 0 && ! -d "$CASE_WT" ]] && ! git -C "$CASE_REPO" rev-parse --verify --quiet refs/heads/fr/w1 >/dev/null; then
  pass "W1: archive rc=0, worktree 디렉터리와 fr/w1 브랜치가 없다"
else
  fail "W1: rc=$ARCH_RC worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

echo "== W1c: 발행 뒤 기본 worktree 의 prod 체크아웃이 발행 gitlink 와 같고 merge 메시지에 autopilot 이 없다 =="
w1_gl="$(git -C "$CASE_REPO" ls-tree -r HEAD libs/prod | awk '{print $3}')"
w1_co="$(git -C "$CASE_REPO/libs/prod" rev-parse HEAD)"
w1_st="$(git -C "$CASE_REPO" status --porcelain)"
w1_msgs="$(git -C "$CASE_REPO" log --first-parent --format=%s -6)"
if [[ -n "$w1_gl" && "$w1_gl" == "$w1_co" && -z "$w1_st" && "$ARCH_OUT" == *"체크아웃을 발행된 커밋으로 맞췄습니다"* ]] \
   && grep -qxF "merge: w1 (archive)" <<<"$w1_msgs" && ! grep -q autopilot <<<"$w1_msgs"; then
  pass "W1c: 체크아웃=gitlink, status 깨끗, merge 메시지 'merge: w1 (archive)'"
else
  fail "W1c: gitlink=$w1_gl checkout=$w1_co status=[$w1_st] msgs=[$w1_msgs] — $ARCH_OUT"
fi
echo "== W1b: 작업 worktree 안에서 archive → 기본 체크아웃 rd task list 가 정리 =="
prep_case w1b
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
rc=0; out="$( cd "$CASE_WT" && bash rd-workflow/scripts/lifecycle/archive.sh \
  --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || rc=$?
if [[ "$rc" != 0 || ! -d "$CASE_WT" ]]; then
  fail "W1b: 호출 worktree archive rc=$rc (rc=0 이고 worktree 는 남아야 함) — $out"
else
  tl="$( cd "$CASE_REPO" && bash rd-workflow/scripts/rd task list 2>&1 )" || true
  if [[ ! -d "$CASE_WT" ]] && ! git -C "$CASE_REPO" rev-parse --verify --quiet refs/heads/fr/w1b >/dev/null; then
    pass "W1b: rd task list 가 submodule worktree 와 브랜치를 지연 정리했다"
  else
    fail "W1b: 지연 정리 안 됨 — $tl"
  fi
fi

echo "== W3b: submodule 커밋을 push 하지 않음 =="
prep_case w3b
sub_commit "$CASE_WT"; record_gitlink "$CASE_WT"
run_archive "$CASE_REPO" w3b
if [[ -d "$CASE_WT" && "$ARCH_OUT" == *"원격에 없는 커밋"* && "$ARCH_OUT" == *"log --oneline --all --not --remotes"* ]]; then
  pass "W3b: worktree 보존, 사유·복구 명령 출력"
else
  fail "W3b: worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

if [[ "$ARCH_RC" == 0 && "$ARCH_OUT" == *"[submodule]"* && "$ARCH_OUT" == *"체크아웃 갱신 실패"* && "$ARCH_OUT" == *"archive: core 완료 (정리 잔여 있음)"* ]]; then
  pass "W3: gitlink 커밋을 가져올 수 없으면 rc=0, [submodule] 갱신 실패 잔여, core 완료"
else
  fail "W3: rc=$ARCH_RC — $ARCH_OUT"
fi

echo "== W3c: submodule 커밋을 push 했지만 gitlink 는 올리지 않음 =="
prep_case w3c
echo work > "$CASE_WT/work.txt"; git -C "$CASE_WT" add work.txt; git -C "$CASE_WT" commit -q -m "구현: work"
sub_commit "$CASE_WT"; sub_push "$CASE_WT"
run_archive "$CASE_REPO" w3c
if [[ -d "$CASE_WT" && "$ARCH_OUT" == *"gitlink 로 올리지 않은 커밋"* ]]; then
  pass "W3c: worktree 보존, gitlink 미반영 사유 출력"
else
  fail "W3c: worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

echo "== W3d: 중첩 submodule(libs/prod/vendor) 안 미추적 파일 — 모든 깊이 검사 =="
prep_case w3d
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
echo scratch > "$CASE_WT/libs/prod/vendor/untracked.txt"
run_archive "$CASE_REPO" w3d
if [[ -d "$CASE_WT" && "$ARCH_OUT" == *"미커밋 변경"* ]]; then
  pass "W3d: worktree 보존, 미커밋 변경 사유 출력"
else
  fail "W3d: worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

echo "== W3e: submodule 커밋·push 후 상위에서 gitlink 를 스테이징만 하고 커밋하지 않음 =="
prep_case w3e
echo work > "$CASE_WT/work.txt"; git -C "$CASE_WT" add work.txt; git -C "$CASE_WT" commit -q -m "구현: work"
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; git -C "$CASE_WT" add libs/prod
run_archive "$CASE_REPO" w3e
if [[ -d "$CASE_WT" && "$ARCH_OUT" == *"미커밋 변경"* ]]; then
  pass "W3e: worktree 보존, 스테이징만 된 gitlink 를 미커밋 변경으로 안내"
else
  fail "W3e: worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

# ---- 결정표 단위 시험: rd_submodule_checkout_sync 를 직접 부른다(promote·archive 없음) ----
# 이 상태들은 `--force-dirty` 없이는 archive Step 0 이 먼저 막는 상태라 통합 경로가 아니다.
source "$SCRIPT_DIR/../_state_common.sh"
source "$SCRIPT_DIR/../_submodule_common.sh"

# mk_direct_case <name> [vendor] — 템플릿 repo 를 복사하고 prod(와 선택적으로 중첩 vendor)에 새 커밋을 만들어 prod.git 에 올린 뒤
# 상위에 gitlink 로 기록한다(= 발행 커밋 DPUB). 그 다음 libs/prod 체크아웃을 옛 커밋으로 되돌려 「불일치」 상태를 만든다.
#   전역: DREPO DPUB DNEW DOLD (prod 의 새·옛 커밋) DVOLD (vendor 옛 커밋)
mk_direct_case() {
  local n="$1" r
  mkdir -p "$TMP/$n"; cp -R "$TEMPLATE_DIR/repo" "$TMP/$n/repo"; r="$TMP/$n/repo"; DREPO="$r"
  git -C "$r/libs/prod" config user.email t@t; git -C "$r/libs/prod" config user.name t
  DOLD="$(git -C "$r/libs/prod" rev-parse HEAD)"; DVOLD="$(git -C "$r/libs/prod/vendor" rev-parse HEAD)"
  if [[ "${2:-}" == vendor ]]; then
    git -C "$r/libs/prod/vendor" config user.email t@t; git -C "$r/libs/prod/vendor" config user.name t
    echo v2 >> "$r/libs/prod/vendor/v.txt"; git -C "$r/libs/prod/vendor" commit -q -am "vendor change"
    git -C "$r/libs/prod/vendor" push -q origin "HEAD:refs/heads/$n"
    git -C "$r/libs/prod" add vendor; git -C "$r/libs/prod" commit -q -m "prod: vendor 갱신"
  else
    echo "c-$RANDOM" >> "$r/libs/prod/p.txt"; git -C "$r/libs/prod" commit -q -am "prod change"
  fi
  git -C "$r/libs/prod" push -q origin "HEAD:refs/heads/$n"
  DNEW="$(git -C "$r/libs/prod" rev-parse HEAD)"
  git -C "$r" add libs/prod; git -C "$r" commit -q -m "gitlink 이동"; DPUB="$(git -C "$r" rev-parse HEAD)"
  git -C "$r/libs/prod" checkout -q --detach "$DOLD"
  [[ "${2:-}" == vendor ]] && git -C "$r/libs/prod/vendor" checkout -q --detach "$DVOLD"
  return 0
}
# sync_out <repo> — 새 단계 함수를 부르고 레코드를 줄로 풀어 SYNC_OUT 에 둔다(필드 구분은 줄바꿈).
sync_out() { SYNC_OUT="$(rd_submodule_checkout_sync "$1" "$DPUB" | tr '\0' '\n')"; }

echo "== W2: 기본 worktree 의 prod 에 미추적 파일 — 갱신하지 않고 잔여로 남긴다 =="
mk_direct_case w2
echo scratch > "$DREPO/libs/prod/untracked.txt"
sync_out "$DREPO"
if [[ "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$DOLD" && "$SYNC_OUT" == *submodule* && "$SYNC_OUT" == *"변경이 있어 갱신하지 않았습니다"* \
      && "$SYNC_OUT" == *"status --short"* && "$SYNC_OUT" == *"git -C $DREPO submodule update --init --recursive -- libs/prod"* ]]; then
  pass "W2: 체크아웃 미갱신, 사유와 status --short 복구 명령"
else
  fail "W2: $SYNC_OUT"
fi

echo "== W5: 기본 worktree 의 prod 가 이미 발행 gitlink 와 같으면 건너뛴다 =="
mk_direct_case w5
git -C "$DREPO/libs/prod" checkout -q --detach "$DNEW"
sync_out "$DREPO"
if [[ -z "$SYNC_OUT" && "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$DNEW" ]]; then
  pass "W5: 불일치 없는 항목은 건너뜀(출력 없음)"
else
  fail "W5: $SYNC_OUT"
fi

echo "== W6: 기본 worktree 에서 libs/prod 가 초기화되지 않음 — 건너뜀 =="
mk_direct_case w6
git -C "$DREPO" submodule deinit -q -f libs/prod
sync_out "$DREPO"
[[ -z "$SYNC_OUT" ]] && pass "W6: 미초기화 submodule 은 건너뛰고 출력 없음" || fail "W6: $SYNC_OUT"

echo "== W7: prod 는 발행 gitlink 에 맞고 중첩 vendor 만 옛 커밋 — vendor 가 맞춰진다 =="
mk_direct_case w7 vendor
git -C "$DREPO/libs/prod" checkout -q --detach "$DNEW"
git -C "$DREPO/libs/prod/vendor" checkout -q --detach "$DVOLD"
sync_out "$DREPO"
w7_want="$(git -C "$DREPO/libs/prod" ls-files -s vendor | awk '{print $2}')"
w7_got="$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)"
if [[ "$SYNC_OUT" == ok* && -n "$w7_want" && "$w7_want" == "$w7_got" && "$w7_got" != "$DVOLD" ]]; then
  pass "W7: 중첩 vendor 체크아웃이 prod 인덱스의 gitlink 로 맞춰졌다"
else
  fail "W7: want=$w7_want got=$w7_got old=$DVOLD out=$SYNC_OUT"
fi

echo "== W8: 기본 worktree 의 prod 가 어떤 ref 에도 없는 커밋을 가리킴 — 갱신하지 않는다 =="
mk_direct_case w8
git -C "$DREPO/libs/prod" commit -q --allow-empty -m "분리 HEAD 커밋"
w8_head="$(git -C "$DREPO/libs/prod" rev-parse HEAD)"
sync_out "$DREPO"
if [[ "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$w8_head" && "$SYNC_OUT" == *"어떤 브랜치·태그에도 없어"* && "$SYNC_OUT" == *"branch <이름>"* ]]; then
  pass "W8: 체크아웃 미갱신, 닿지 않는 HEAD 사유 출력"
else
  fail "W8: $SYNC_OUT"
fi

echo "== W9: 옛 prod 에 기록된 vendor 의 분리 HEAD 커밋 U — prod 이동이 vendor 를 옮기므로 갱신하지 않는다 =="
# vendor 는 `+` 가 아니다(옛 prod 인덱스와 일치). prod 만 `+` 이고 prod HEAD 는 ref 에서 닿는다.
mkdir -p "$TMP/w9"; cp -R "$TEMPLATE_DIR/repo" "$TMP/w9/repo"; DREPO="$TMP/w9/repo"
for w9_d in libs/prod libs/prod/vendor; do git -C "$DREPO/$w9_d" config user.email t@t; git -C "$DREPO/$w9_d" config user.name t; done
DVOLD="$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)"
git -C "$DREPO/libs/prod/vendor" checkout -q --detach; echo u >> "$DREPO/libs/prod/vendor/v.txt"
git -C "$DREPO/libs/prod/vendor" commit -q -am "분리 HEAD 커밋 U"; w9_u="$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)"
git -C "$DREPO/libs/prod" add vendor; git -C "$DREPO/libs/prod" commit -q -m "옛 prod: vendor=U"
w9_oldmid="$(git -C "$DREPO/libs/prod" rev-parse HEAD)"; git -C "$DREPO/libs/prod" push -q origin "HEAD:refs/heads/w9-old"
git -C "$DREPO/libs/prod/vendor" checkout -q --detach "$DVOLD"
git -C "$DREPO/libs/prod" add vendor; git -C "$DREPO/libs/prod" commit -q -m "발행 prod: vendor=옛 커밋"
git -C "$DREPO/libs/prod" push -q origin "HEAD:refs/heads/w9"
git -C "$DREPO" add libs/prod; git -C "$DREPO" commit -q -m "gitlink 이동"; DPUB="$(git -C "$DREPO" rev-parse HEAD)"
git -C "$DREPO/libs/prod" checkout -q --detach "$w9_oldmid"; git -C "$DREPO/libs/prod/vendor" checkout -q --detach "$w9_u"
sync_out "$DREPO"
if [[ "$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)" == "$w9_u" && "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$w9_oldmid" \
      && "$SYNC_OUT" == submodule* && "$SYNC_OUT" == *"submodule libs/prod/vendor 의 체크아웃 커밋이 어떤 브랜치·태그에도 없어"* ]]; then
  pass "W9: 중첩 vendor 의 닿지 않는 HEAD 를 보고 prod 를 갱신하지 않았다"
else
  fail "W9: vendor=$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD) U=$w9_u out=$SYNC_OUT"
fi

seal_work() {
  local sid="$1-review-001" h hd
  prep_case "$1"
  sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
  h="$( cd "$CASE_WT" && bash -c 'source rd-workflow/scripts/_state_common.sh; rd_protected_tree_hash HEAD' )"
  hd="$(git -C "$CASE_WT" rev-parse HEAD)"
  mkdir -p "$CASE_WT/rd-workflow-workspace/.lifecycle/review-seals"
  printf 'schema=1\nsession-id=%s\nreview-type=diff-review\ntree-hash=%s\nhead=%s\nbranch-mode=fr\nfr-branch=fr/%s\nrd-version=unknown\nverified=yes\nsealed-at=2026-11-03-0000\n' \
    "$sid" "$h" "$hd" "$1" > "$CASE_WT/rd-workflow-workspace/.lifecycle/review-seals/$sid.seal"
  sed -i.bak -e "s/^review-session=.*/review-session=$sid/" -e 's/^status=.*/status=아카이브 보류/' "$CASE_WT/rd-workflow-workspace/.lifecycle/task-state"; rm -f "$CASE_WT/rd-workflow-workspace/.lifecycle/task-state.bak"
  git -C "$CASE_WT" add -A; git -C "$CASE_WT" commit -q -m "review: seal"
  git -C "$CASE_WT/libs/prod" commit -q --allow-empty -m "merge-like: 같은 트리"
  sub_push "$CASE_WT"
  git -C "$CASE_WT" add libs/prod; git -C "$CASE_WT" commit -q -m "기록: gitlink 이동"
}
run_archive_sealed() {  # <repo> <slug> — 우회 플래그 없이 진짜 seal 검증 경로를 탄다.
  ARCH_RC=0
  ARCH_OUT="$( cd "$1" && bash rd-workflow/scripts/lifecycle/archive.sh --task "$2" --no-remote 2>&1 )" || ARCH_RC=$?
}

echo "== W4a: seal 뒤 prod gitlink 를 같은 트리의 커밋으로 옮겨도 발행된다 (기본 worktree 의 prod 에는 그 커밋 객체가 없다 — 작업 worktree 저장소에서 대체 조회) =="
seal_work w4a
run_archive_sealed "$CASE_REPO" w4a
if [[ "$ARCH_RC" == 0 && "$ARCH_OUT" != *"리뷰 대상 불일치"* ]]; then
  pass "W4a: 같은 트리로 gitlink 이동 — 발행 통과"
else
  fail "W4a: rc=$ARCH_RC — $ARCH_OUT"
fi

DONE=1
echo "test_archive_submodule: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
