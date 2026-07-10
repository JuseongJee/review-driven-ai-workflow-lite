#!/usr/bin/env bash
# Temp repo 기반 통합 테스트 — promote / archive / rollback / hook의 git state transition 자동 검증
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# canonical(_ROOT_FILES/rd-workflow/scripts/lifecycle/) 와 mirror(rd-workflow/scripts/lifecycle/) 양쪽에서 동작.
# _ROOT_FILES 디렉토리를 가진 부모를 SCRIPT_DIR 에서 위로 거슬러 검출한다.
# 배포본(설치 후 단독 환경)에서는 _ROOT_FILES가 존재하지 않으므로 탐지 실패 → skip.
# dev fixture(lifecycle 스크립트 소스 복사 등)가 필요하기 때문에 설치본에서는 실행 불가.
PROJECT_ROOT=""
_search_dir="$SCRIPT_DIR"
while [[ "$_search_dir" != "/" ]]; do
  if [[ -d "$_search_dir/_ROOT_FILES" ]]; then
    PROJECT_ROOT="$_search_dir"
    break
  fi
  _search_dir="$(dirname "$_search_dir")"
done
if [[ -z "$PROJECT_ROOT" ]]; then
  printf '  (skip: _ROOT_FILES 없음 — 설치본 단독 환경. 통합 테스트는 dev repo 전용 dev fixture 필요)\n'
  exit 0
fi

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }

# Common setup helper — temp git repo with lifecycle scripts copied in
setup_repo() {
  local branch="${1:-main}"
  local d
  d="$(mktemp -d)"
  # macOS: /var is a symlink to /private/var; resolve to canonical path so git worktree paths match
  d="$(cd "$d" && pwd -P)"
  ( cd "$d" && \
    git init -q -b "$branch" 2>/dev/null || git init -q && git checkout -q -b "$branch"; \
    git config user.email test@example.com; \
    git config user.name test; \
    if [[ -f "$PROJECT_ROOT/_ROOT_FILES/CURRENT_TASK.md" ]]; then \
      cp "$PROJECT_ROOT/_ROOT_FILES/CURRENT_TASK.md" CURRENT_TASK.md; \
    else \
      printf '# Current Task\n\n## Short Title\n-\n\n## Branch / Worktree\nmain\n\n## Status\n대기 중\n' > CURRENT_TASK.md; \
    fi; \
    mkdir -p rd-workflow/scripts/lifecycle rd-workflow/scripts/hooks rd-workflow-workspace/.lifecycle; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/lifecycle/*.sh rd-workflow/scripts/lifecycle/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/hooks/*.sh rd-workflow/scripts/hooks/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_state_common.sh rd-workflow/scripts/; \
    git add -A; \
    git commit -q -m "init"
  )
  echo "$d"
}

run_promote() {
  local repo="$1"; shift
  ( cd "$repo" && bash rd-workflow/scripts/lifecycle/promote.sh "$@" )
}

# === Scenario 1: promote → archive lifecycle ===
echo "== scenario 1: promote → archive lifecycle =="
REPO="$(setup_repo)"
# --status "구현 중": archive 후 baseline reset 검증을 위해 실제 stale 상황(비-baseline status) 재현
run_promote "$REPO" --short-title test-foo --no-worktree --status "구현 중" >/dev/null
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "promote: branch fr/test-foo 존재" || fail "promote: branch 부재"
( cd "$REPO" && [[ "$(git rev-parse --abbrev-ref HEAD)" == "fr/test-foo" ]] ) && pass "promote: HEAD == fr/test-foo" || fail "promote: HEAD 불일치"
# metadata is committed on main — check from main's tree (HEAD is fr/test-foo after promote)
# v2 2b: active-fr → task-state 전환, fr-branch 필드 확인
( cd "$REPO" && git show main:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null | grep -q "fr-branch=fr/test-foo" ) && pass "promote: metadata 기록 (task-state)" || fail "promote: metadata 부재"

# Idempotent rerun
( cd "$REPO" && git switch main -q )
run_promote "$REPO" --short-title test-foo --no-worktree >/dev/null
( cd "$REPO" && ! git rev-parse --verify fr/test-foo-2 >/dev/null 2>&1 ) && pass "promote rerun: suffix 안 만듦" || fail "promote rerun: 새 suffix 생성됨"

# fr branch에서 archive content commit
( cd "$REPO" && git switch fr/test-foo -q && \
  echo "# archived" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )

# Archive 호출 (--no-remote 모드)
# review precheck 는 test_lifecycle.sh 가 단위 검증하므로, 여기서는 force-skip 으로 관문만 통과하고
# git state 전이(merge/tag/branch 정리)에 집중한다.
( cd "$REPO" && git switch main -q && \
  bash rd-workflow/scripts/lifecycle/archive.sh --no-remote --force-skip-review-check "통합 테스트 fixture" ) >/dev/null

( cd "$REPO" && ! git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "archive: branch 삭제" || fail "archive: branch 잔존"
( cd "$REPO" && git tag --list "fr/*/test-foo" | grep -q . ) && pass "archive: tag 존재" || fail "archive: tag 부재"
# v2 2b: active-fr 폐지 → task-state의 fr-branch=null 확인
( cd "$REPO" && grep -q "^fr-branch=null$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "archive: metadata 정리 (fr-branch=null)" || fail "archive: fr-branch still active"
# LC-14 대칭: archive 후 short-title/status baseline reset (stale 방지)
( cd "$REPO" && grep -q "^short-title=-$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "archive: short-title=- baseline reset" || fail "archive: short-title stale 잔존"
( cd "$REPO" && grep -q "^status=대기 중$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "archive: status=대기 중 baseline reset" || fail "archive: status stale 잔존"

# archive 재실행 — fr branch 부재 + tag 존재 → success exit
# review-skip-audit.log가 untracked으로 생성될 수 있으므로 clean 트리를 보장하여 LC-20(멱등) 커버리지 복원
( cd "$REPO" && git clean -f rd-workflow-workspace/.lifecycle/review-skip-audit.log 2>/dev/null || true )
out="$(cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/test-foo --no-remote 2>&1 || true)"
[[ "$out" == *"이미 archive 완료"* ]] && pass "archive rerun: success exit (이미 완료)" || fail "archive rerun: $out"
# rerun(이미 완료)은 task-state를 건드리지 않는다 — baseline 유지 확인
( cd "$REPO" && grep -q "^short-title=-$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null && grep -q "^status=대기 중$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "archive rerun: task-state 불변 (baseline 유지)" || fail "archive rerun: task-state 변경됨"

rm -rf "$REPO"

# === Scenario 2: promote → rollback ===
echo "== scenario 2: promote → rollback =="
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-bar --no-worktree >/dev/null
( cd "$REPO" && git switch main -q && \
  bash rd-workflow/scripts/lifecycle/promote_rollback.sh --fr-branch fr/test-bar ) >/dev/null
( cd "$REPO" && ! git rev-parse --verify fr/test-bar >/dev/null 2>&1 ) && pass "rollback: branch 삭제" || fail "rollback: branch 잔존"
# v2 2b: active-fr 폐지 → task-state에서 fr-branch=null, short-title=-, status=대기 중 (LC-14)
( cd "$REPO" && grep -q "^fr-branch=null$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "rollback: fr-branch=null (LC-14)" || fail "rollback: fr-branch still active"
( cd "$REPO" && grep -q "^short-title=-$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "rollback: short-title=- (LC-14)" || fail "rollback: short-title not reset"
( cd "$REPO" && grep -q "^status=대기 중$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "rollback: status=대기 중 (LC-14)" || fail "rollback: status not reset"
rm -rf "$REPO"

# === Scenario 3: archive partial publish rerun (deterministic via direct git state setup) ===
echo "== scenario 3: archive partial publish rerun =="
REPO="$(setup_repo)"
REPO_PARENT="$(dirname "$REPO")"
BARE="$REPO_PARENT/bare-mirror-3-$$"
git init --bare "$BARE" -q 2>/dev/null || true
( cd "$REPO" && git remote add origin "$BARE" )

run_promote "$REPO" --short-title test-baz --no-worktree >/dev/null
( cd "$REPO" && git switch fr/test-baz -q && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "ar content" )

# Partial state: manually merge + cleanup commit + lightweight tag (publish 직전 상태)
# NOTE: lightweight tag is used here so git rev-parse returns the commit SHA directly,
# matching what archive.sh's collision check compares against git rev-parse HEAD.
# v2 2b: active-fr 제거 대신 task-state의 fr-branch=null reset
( cd "$REPO" && git switch main -q && \
  git merge --no-ff fr/test-baz -m "merge: test-baz" -q && \
  grep -q "^fr-branch=" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null && \
    awk -F'=' '$1=="fr-branch"{print "fr-branch=null"; next} $1=="worktree-path"{print "worktree-path=null"; next} $1!="created-at"{print}' \
      rd-workflow-workspace/.lifecycle/task-state > rd-workflow-workspace/.lifecycle/task-state.tmp && \
    mv rd-workflow-workspace/.lifecycle/task-state.tmp rd-workflow-workspace/.lifecycle/task-state || true; \
  git add -A rd-workflow-workspace/.lifecycle 2>/dev/null && \
  git commit -q -m "chore(lifecycle): archive test-baz metadata 정리" 2>/dev/null || true; \
  git tag "fr/2026-04-29-9999/test-baz" )

# 미push 상태에서 archive 재호출 (publish 실패 후 rerun 시뮬레이션)
# metadata 가 위에서 제거되어 short-title 매칭 불가 → precheck 는 force-skip 으로 통과시키고 push 멱등성만 검증.
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/test-baz --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || true

# 검증: bare mirror에 push 됐는가
( cd "$REPO" && git ls-remote origin refs/heads/main 2>/dev/null | grep -q . ) && pass "rerun: main pushed" || fail "rerun: main 미push"
( cd "$REPO" && git ls-remote origin "refs/tags/fr/2026-04-29-9999/test-baz" 2>/dev/null | grep -q . ) && pass "rerun: tag pushed" || fail "rerun: tag 미push"
( cd "$REPO" && ! git rev-parse --verify fr/test-baz >/dev/null 2>&1 ) && pass "rerun: fr branch 삭제" || fail "rerun: fr branch 잔존"

rm -rf "$REPO" "$BARE"

# === Scenario 4: fr_branch_gate hook smoke ===
echo "== scenario 4: fr_branch_gate hook smoke =="
HOOK="$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/hooks/fr_branch_gate.sh"
if [[ -x "$HOOK" ]]; then
  # temp repo (main branch) 안에서 호출해 호출자 git state 의존성을 제거한다
  REPO="$(setup_repo)"
  pushd "$REPO" >/dev/null
  # bypass marker 가 git commit invocation prefix → 통과
  out_rc=0
  echo '{"tool_input":{"command":"RD_LIFECYCLE_BYPASS_REASON=bootstrap git commit -m test"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 0 ]] && pass "hook: bypass marker prefix 통과" || fail "hook: bypass marker prefix 차단됨 (rc=$out_rc)"
  # env prefix 형태도 정상 통과
  out_rc=0
  echo '{"tool_input":{"command":"env RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit -m test"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 0 ]] && pass "hook: env bypass prefix 통과" || fail "hook: env bypass prefix 차단됨 (rc=$out_rc)"
  # spoof 차단 — marker 가 git commit 의 env prefix 가 아니면 통과해서는 안 된다
  out_rc=0
  echo '{"tool_input":{"command":"echo RD_LIFECYCLE_BYPASS_REASON=lifecycle && git commit -m x"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 2 ]] && pass "hook: spoof 차단 (echo && commit)" || fail "hook: spoof 통과됨 (rc=$out_rc)"
  # non-commit 명령 → 통과
  out_rc=0
  echo '{"tool_input":{"command":"ls -la"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 0 ]] && pass "hook: non-commit 통과" || fail "hook: non-commit 차단됨 (rc=$out_rc)"
  # false positive 차단 — echo / cat 안에 'git commit' 텍스트가 substring 으로 포함되어도 통과해야 한다
  out_rc=0
  echo '{"tool_input":{"command":"echo git commit"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 0 ]] && pass "hook: false positive (echo git commit) 통과" || fail "hook: false positive (echo git commit) 차단 (rc=$out_rc)"
  out_rc=0
  echo '{"tool_input":{"command":"cat git commit log"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 0 ]] && pass "hook: false positive (cat ... git commit ...) 통과" || fail "hook: false positive (cat ... git commit ...) 차단 (rc=$out_rc)"
  out_rc=0
  echo '{"tool_input":{"command":"git commitments"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 0 ]] && pass "hook: false positive (git commitments) 통과" || fail "hook: false positive (git commitments) 차단 (rc=$out_rc)"
  # main 에서 prefix 없는 git commit → 차단
  out_rc=0
  echo '{"tool_input":{"command":"git commit -m x"}}' | bash "$HOOK" 2>/dev/null || out_rc=$?
  [[ "$out_rc" -eq 2 ]] && pass "hook: main 직접 commit 차단" || fail "hook: main 직접 commit 통과됨 (rc=$out_rc)"
  popd >/dev/null
  rm -rf "$REPO"
fi

# === Scenario 5: worktree promote rerun ===
echo "== scenario 5: worktree promote rerun =="
REPO="$(setup_repo)"
# Use canonical (realpath) parent to avoid /var→/private/var symlink mismatch on macOS
REPO_PARENT="$(dirname "$REPO")"
WT_PATH="$REPO_PARENT/wt-test-quux-$$"

run_promote "$REPO" --short-title test-quux --worktree-path "$WT_PATH" >/dev/null
[[ -d "$WT_PATH" ]] && pass "worktree-promote: worktree 생성" || fail "worktree-promote: worktree 부재"
# v2 2b: active-fr → task-state 전환
( cd "$REPO" && git switch main -q && grep -q "worktree-path=$WT_PATH" rd-workflow-workspace/.lifecycle/task-state ) && pass "worktree-promote: metadata 기록 (task-state)" || fail "worktree-promote: metadata 부재"

# Rerun without --worktree-path
( cd "$REPO" && git switch main -q )
run_promote "$REPO" --short-title test-quux >/dev/null
EXISTING_WT="$(cd "$REPO" && git worktree list --porcelain | awk '
  /^worktree /{p=$0; sub(/^worktree /,"",p); next}
  /^branch refs\/heads\/fr\/test-quux/{print p; exit}')"
[[ "$EXISTING_WT" == "$WT_PATH" ]] && pass "worktree-rerun: 동일 worktree 재사용" || fail "worktree-rerun: 다른 worktree ($EXISTING_WT)"

# Rerun with different path → hard error
( cd "$REPO" && git switch main -q )
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-quux --worktree-path "$REPO_PARENT/wt-other-$$" 2>&1 ) || true )"
[[ "$out" == *"기존 worktree path 와 다름"* ]] && pass "worktree-rerun: 인자 mismatch hard error" || fail "worktree-rerun: 충돌 감지 실패 ($out)"

rm -rf "$REPO" "$WT_PATH" "$REPO_PARENT/wt-other-$$"

# === Scenario 6: relative + space path canonicalize ===
echo "== scenario 6: relative + space path canonicalize =="
REPO="$(setup_repo)"
REPO_PARENT="$(dirname "$REPO")"
# Parent with space in name (canonical via already-resolved REPO_PARENT)
SPACE_PARENT_NAME="wt parent-$$"
PARENT_DIR="$REPO_PARENT/$SPACE_PARENT_NAME"
mkdir -p "$PARENT_DIR"
# Pass relative path from REPO: ../wt parent-PID/wt foo
RELATIVE_WT="../$SPACE_PARENT_NAME/wt foo"
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-rel --worktree-path "$RELATIVE_WT" ) >/dev/null
EXPECTED_ABS="$PARENT_DIR/wt foo"
# v2 2b: active-fr → task-state 전환
( cd "$REPO" && git switch main -q && grep -qF "worktree-path=$EXPECTED_ABS" rd-workflow-workspace/.lifecycle/task-state ) \
  && pass "rel-space: metadata canonical absolute path 기록 (task-state)" || fail "rel-space: canonicalize 실패"
[[ -d "$EXPECTED_ABS" ]] && pass "rel-space: worktree 디렉토리 생성 (공백 포함)" || fail "rel-space: worktree 부재"

# parent 미존재 hard error (relative path — absolute paths skip parent check in promote.sh)
REPO2="$(setup_repo)"
out="$( ( cd "$REPO2" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-noparent --worktree-path "../non-existent-parent-$$/wt" 2>&1 ) || true )"
[[ "$out" == *"parent 미존재"* ]] && pass "rel-noparent: hard error" || fail "rel-noparent: 통과되었음 ($out)"

rm -rf "$REPO" "$REPO2" "$PARENT_DIR"

# === Scenario 7: fetch failure preflight hard-stop ===
echo "== scenario 7: archive fetch failure preflight =="
REPO="$(setup_repo)"
( cd "$REPO" && git remote add origin "/non/existent/bare-mirror-$$.git" )
run_promote "$REPO" --short-title test-fetchfail --no-worktree >/dev/null
( cd "$REPO" && git switch fr/test-fetchfail -q && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "ar content" )
( cd "$REPO" && git switch main -q )

out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh 2>&1 ) || true )"
[[ "$out" == *"fetch --tags origin 실패"* ]] \
  && pass "fetch-fail: preflight hard error" || fail "fetch-fail: 메시지 부재 ($out)"

# Side effect 부재 검증
( cd "$REPO" && git rev-parse --verify fr/test-fetchfail >/dev/null 2>&1 ) && pass "fetch-fail: fr branch 보존" || fail "fetch-fail: fr branch 삭제됨"
# v2 2b: active-fr 폐지 → task-state에 fr-branch 값이 유효하면 metadata 보존 상태
( cd "$REPO" && grep -q "^fr-branch=fr/" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "fetch-fail: metadata 보존 (task-state fr-branch 유효)" || fail "fetch-fail: metadata 삭제됨"
( cd "$REPO" && [[ -z "$(git tag --list 'fr/*/test-fetchfail')" ]] ) && pass "fetch-fail: tag 미생성" || fail "fetch-fail: tag 생성됨"

rm -rf "$REPO"

# === Scenario 8: --fr-branch override mismatch guard ===
# active metadata 와 다른 --fr-branch override 가 들어오면 hard error 로 막아야 한다.
# unrelated active FR (branch + metadata) 가 보존되어야 한다.
echo "== scenario 8: override mismatch guard =="
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-foo --no-worktree >/dev/null
( cd "$REPO" && git switch main -q )
( cd "$REPO" && git branch fr/test-bar main )

# archive override mismatch
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/test-bar --no-remote 2>&1 ) || true )"
[[ "$out" == *"불일치"* ]] && pass "archive override-mismatch: hard error" || fail "archive override-mismatch: 통과 ($out)"
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "archive override-mismatch: active branch 보존" || fail "archive override-mismatch: active branch 삭제됨"
# v2 2b: active-fr → task-state 전환 (fr-branch 필드로 확인)
( cd "$REPO" && grep -q "^fr-branch=fr/test-foo$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "archive override-mismatch: active metadata 보존 (task-state)" || fail "archive override-mismatch: metadata 삭제됨"

# rollback override mismatch
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --fr-branch fr/test-bar 2>&1 ) || true )"
[[ "$out" == *"불일치"* ]] && pass "rollback override-mismatch: hard error" || fail "rollback override-mismatch: 통과 ($out)"
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "rollback override-mismatch: active branch 보존" || fail "rollback override-mismatch: active branch 삭제됨"
# v2 2b: active-fr → task-state 전환
( cd "$REPO" && grep -q "^fr-branch=fr/test-foo$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "rollback override-mismatch: active metadata 보존 (task-state)" || fail "rollback override-mismatch: metadata 삭제됨"

rm -rf "$REPO"

# === Scenario 9: promote 후 fr 브랜치 task-state 정합 (baseline 회귀 방지) ===
echo "== scenario 9: promote 후 fr 브랜치 task-state 정합 =="

# 모드 1 — 일반 checkout promote (git switch). promote 직후 HEAD == fr 브랜치이므로
# 워킹트리 task-state가 metadata 커밋 값을 유지해야 한다 (회귀/부재 모두 실패)
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-sync --no-worktree --status "구현 중" >/dev/null
TS="$REPO/rd-workflow-workspace/.lifecycle/task-state"
( grep -q "^short-title=test-sync$" "$TS" 2>/dev/null ) && pass "checkout-sync: short-title 정합" || fail "checkout-sync: short-title 회귀"
( grep -q "^status=구현 중$" "$TS" 2>/dev/null ) && pass "checkout-sync: status 정합" || fail "checkout-sync: status 회귀"
( grep -q "^fr-branch=fr/test-sync$" "$TS" 2>/dev/null ) && pass "checkout-sync: fr-branch 정합" || fail "checkout-sync: fr-branch 회귀"
( cd "$REPO" && git show main:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null | grep -q "^fr-branch=fr/test-sync$" ) && pass "checkout-sync: main측 metadata 유지" || fail "checkout-sync: main측 metadata 부재"
rm -rf "$REPO"

# 모드 2 — worktree promote (--worktree-path). worktree 내부 task-state가 정합해야 한다
REPO="$(setup_repo)"
REPO_PARENT="$(dirname "$REPO")"
WT_SYNC="$REPO_PARENT/wt-sync-$$"
run_promote "$REPO" --short-title test-wtsync --worktree-path "$WT_SYNC" >/dev/null
WTS="$WT_SYNC/rd-workflow-workspace/.lifecycle/task-state"
( grep -q "^short-title=test-wtsync$" "$WTS" 2>/dev/null ) && pass "wt-sync: short-title 정합" || fail "wt-sync: short-title 회귀"
( grep -q "^status=구현 중$" "$WTS" 2>/dev/null ) && pass "wt-sync: status 정합" || fail "wt-sync: status 회귀"
( grep -q "^fr-branch=fr/test-wtsync$" "$WTS" 2>/dev/null ) && pass "wt-sync: fr-branch 정합" || fail "wt-sync: fr-branch 회귀"
( grep -qF "worktree-path=$WT_SYNC" "$WTS" 2>/dev/null ) && pass "wt-sync: worktree-path 정합" || fail "wt-sync: worktree-path 회귀"
( cd "$REPO" && git worktree remove --force "$WT_SYNC" ) >/dev/null 2>&1 || true
rm -rf "$REPO" "$WT_SYNC"

# === Scenario 10: stale fr-branch 진단 (promote 조기 실패 + rollback 복구) ===
# metadata의 fr-branch가 실재하지 않는 로컬 브랜치를 가리키면 promote는 진입 시점에
# stale 진단 + promote_rollback.sh 안내로 실패해야 한다 (refs/heads 전용 판정).
echo "== scenario 10: stale fr-branch 진단 =="
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-stale --no-worktree >/dev/null
( cd "$REPO" && git switch main -q && git branch -D fr/test-stale -q )

# case 1 — short-title 불일치 경로: stale 진단으로 실패
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title other-slug --no-worktree 2>&1 ) || true )"
[[ "$out" == *"실재하지 않는 stale 상태"* ]] && pass "stale-mismatch: 진단 메시지" || fail "stale-mismatch: 진단 부재 ($out)"
[[ "$out" == *"promote_rollback.sh"* ]] && pass "stale-mismatch: rollback 안내" || fail "stale-mismatch: rollback 안내 부재 ($out)"
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title other-slug --no-worktree >/dev/null 2>&1 ) && fail "stale-mismatch: exit 0" || pass "stale-mismatch: exit 1"

# case 2 — short-title 일치(idempotent rerun) 경로: 후속 git 에러가 아닌 진입 시점 stale 진단
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-stale --no-worktree 2>&1 ) || true )"
[[ "$out" == *"실재하지 않는 stale 상태"* ]] && pass "stale-match: 진단 메시지" || fail "stale-match: 진단 부재 ($out)"

# case 3 — 동명 tag만 존재해도 stale 판정 (refs/heads 전용 검증)
( cd "$REPO" && git tag fr/test-stale )
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-stale --no-worktree 2>&1 ) || true )"
[[ "$out" == *"실재하지 않는 stale 상태"* ]] && pass "stale-tag: 동명 tag에도 stale 판정" || fail "stale-tag: tag resolve로 오판 ($out)"
( cd "$REPO" && git tag -d fr/test-stale >/dev/null )

# case 4 — 복구 회귀: stale 상태에서 rollback 정상 종료 + metadata clear + promote 재실행 성공
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh >/dev/null 2>&1 ) && pass "stale-rollback: exit 0" || fail "stale-rollback: 실패"
( cd "$REPO" && grep -q "^fr-branch=null$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "stale-rollback: fr-branch=null" || fail "stale-rollback: metadata 잔존"
run_promote "$REPO" --short-title test-stale --no-worktree >/dev/null 2>&1 && pass "stale-rollback: promote 재실행 성공" || fail "stale-rollback: promote 재실행 실패"

rm -rf "$REPO"

echo "== scenario 11: master 기본 브랜치 lifecycle =="
REPO="$(setup_repo master)"
REPO_PARENT="$(dirname "$REPO")"
BARE11="$REPO_PARENT/bare-mirror-11-$$"
git init --bare "$BARE11" -q 2>/dev/null || true
( cd "$REPO" && git remote add origin "$BARE11" )

# gate: master 직접 commit 차단 — fixture에 복사된 hook을 fixture cwd에서 실행 (scenario 4 패턴)
out_rc=0
( cd "$REPO" && echo '{"tool_input":{"command":"git commit -m x"}}' | bash rd-workflow/scripts/hooks/fr_branch_gate.sh >/dev/null 2>&1 ) || out_rc=$?
[[ "$out_rc" -eq 2 ]] && pass "master-gate: 직접 commit 차단" || fail "master-gate: 통과됨 (rc=$out_rc)"

run_promote "$REPO" --short-title test-master --no-worktree >/dev/null 2>&1 \
  && pass "master-promote: exit 0" || fail "master-promote: 실패"
( cd "$REPO" && git show master:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null | grep -q "fr-branch=fr/test-master" ) \
  && pass "master-promote: metadata 기록" || fail "master-promote: metadata 부재"
# fr branch 위 작업 commit 후 master로 돌아가 archive (review-check는 fixture라 force-skip)
( cd "$REPO" && git commit -q --allow-empty -m "work" )
( cd "$REPO" && git switch master -q && bash rd-workflow/scripts/lifecycle/archive.sh --force-skip-review-check "통합 테스트 fixture" >/dev/null 2>&1 ) \
  && pass "master-archive: exit 0" || fail "master-archive: 실패"
_tag11="$(cd "$REPO" && git tag --list "fr/*/test-master" | head -1)"
( [[ -n "$_tag11" ]] && cd "$REPO" && git merge-base --is-ancestor "$_tag11" master 2>/dev/null ) \
  && pass "master-archive: merge 완료" || fail "master-archive: merge 안 됨"
( cd "$REPO" && git ls-remote origin refs/heads/master 2>/dev/null | grep -q . ) \
  && pass "master-archive: master pushed" || fail "master-archive: master 미push"
( cd "$REPO" && git tag --list "fr/*/test-master" | grep -q . ) \
  && pass "master-archive: tag 생성" || fail "master-archive: tag 부재"

# diff review 기본 target 일반화 (prepare_review_pipeline.sh)
# 전제: setup_repo()가 이미 lifecycle/*.sh(_lifecycle_common.sh 포함)와 _state_common.sh를
# fixture의 rd-workflow/scripts/ 아래에 복사해 두므로, prepare가 source할 의존성은 충족되어 있다.
# 여기서는 prepare_review_pipeline.sh 한 파일만 추가 복사하면 된다.
( cd "$REPO" && mkdir -p rd-workflow/scripts \
  && cp "$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/prepare_review_pipeline.sh" rd-workflow/scripts/ \
  && cp "$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/init_review_pipeline.sh" rd-workflow/scripts/ \
  && bash rd-workflow/scripts/prepare_review_pipeline.sh diff >/dev/null 2>&1 ) || true
DIFF_SES="$(ls -d "$REPO"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | head -1)"
( [[ -n "$DIFF_SES" ]] && grep -q 'git diff master...HEAD' "$DIFF_SES/SESSION.md" ) \
  && pass "master-diff: 기본 target master...HEAD" || fail "master-diff: target 오검출 (SESSION=$DIFF_SES)"

rm -rf "$REPO" "$BARE11"

# === Scenario: 기본 브랜치 worktree 밖 호출 거부 — resolved 브랜치명 안내 문구 검증 ===
echo "== scenario: 비-기본-브랜치 worktree 호출 거부 (trunk fixture) =="
REPO="$(setup_repo trunk)"
( cd "$REPO" && mkdir -p rd-workflow/config \
  && printf '{"default_branch": "trunk"}\n' > rd-workflow/config/workflow.json \
  && git add -A && git commit -q -m "config" )
WT="${REPO}-side-wt"
( cd "$REPO" && git worktree add -q "$WT" -b side )
for _mm in "promote:promote.sh --short-title test-mm --no-worktree" \
           "rollback:promote_rollback.sh" \
           "archive:archive.sh"; do
  _name="${_mm%%:*}"; _cmd="${_mm#*:}"
  RC=0; ERR="$( (cd "$WT" && bash rd-workflow/scripts/lifecycle/${_cmd}) 2>&1 )" || RC=$?
  [[ "$RC" -eq 1 ]] && pass "$_name mismatch: exit 1" || fail "$_name mismatch: exit=$RC"
  printf '%s' "$ERR" | grep -q "기본 브랜치(trunk) worktree" \
    && pass "$_name mismatch: resolved 브랜치명 안내" || fail "$_name mismatch: 브랜치명 문구 누락 — $ERR"
  printf '%s' "$ERR" | grep -q "해당 worktree path:" \
    && pass "$_name mismatch: path 안내" || fail "$_name mismatch: path 문구 누락 — $ERR"
done
( cd "$REPO" && git worktree remove --force "$WT" ) || true
rm -rf "$REPO"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
