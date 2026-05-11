#!/usr/bin/env bash
# Temp repo 기반 통합 테스트 — promote / archive / rollback / hook의 git state transition 자동 검증
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# canonical(_ROOT_FILES_LITE/rd-workflow/scripts/lifecycle/) 와 mirror(rd-workflow/scripts/lifecycle/) 양쪽에서 동작.
# _ROOT_FILES_LITE 디렉토리를 가진 부모를 SCRIPT_DIR 에서 위로 거슬러 검출한다.
PROJECT_ROOT=""
_search_dir="$SCRIPT_DIR"
while [[ "$_search_dir" != "/" ]]; do
  if [[ -d "$_search_dir/_ROOT_FILES_LITE" ]]; then
    PROJECT_ROOT="$_search_dir"
    break
  fi
  _search_dir="$(dirname "$_search_dir")"
done
[[ -n "$PROJECT_ROOT" ]] || { printf 'PROJECT_ROOT (containing _ROOT_FILES_LITE) 검출 실패\n' >&2; exit 1; }

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }

# Common setup helper — temp git repo with lifecycle scripts copied in
setup_repo() {
  local d
  d="$(mktemp -d)"
  # macOS: /var is a symlink to /private/var; resolve to canonical path so git worktree paths match
  d="$(cd "$d" && pwd -P)"
  ( cd "$d" && \
    git init -q -b main 2>/dev/null || git init -q && git checkout -q -b main; \
    git config user.email test@example.com; \
    git config user.name test; \
    if [[ -f "$PROJECT_ROOT/_ROOT_FILES_LITE/CURRENT_TASK.md" ]]; then \
      cp "$PROJECT_ROOT/_ROOT_FILES_LITE/CURRENT_TASK.md" CURRENT_TASK.md; \
    else \
      printf '# Current Task\n\n## Short Title\n-\n\n## Branch / Worktree\nmain\n\n## Status\n대기 중\n' > CURRENT_TASK.md; \
    fi; \
    mkdir -p rd-workflow/scripts/lifecycle rd-workflow-workspace/.lifecycle; \
    cp "$PROJECT_ROOT"/_ROOT_FILES_LITE/rd-workflow/scripts/lifecycle/*.sh rd-workflow/scripts/lifecycle/; \
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
run_promote "$REPO" --short-title test-foo --no-worktree >/dev/null
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "promote: branch fr/test-foo 존재" || fail "promote: branch 부재"
( cd "$REPO" && [[ "$(git rev-parse --abbrev-ref HEAD)" == "fr/test-foo" ]] ) && pass "promote: HEAD == fr/test-foo" || fail "promote: HEAD 불일치"
# metadata is committed on main — check from main's tree (HEAD is fr/test-foo after promote)
( cd "$REPO" && git show main:rd-workflow-workspace/.lifecycle/active-fr 2>/dev/null | grep -q "fr-branch=fr/test-foo" ) && pass "promote: metadata 기록" || fail "promote: metadata 부재"

# Idempotent rerun
( cd "$REPO" && git switch main -q )
run_promote "$REPO" --short-title test-foo --no-worktree >/dev/null
( cd "$REPO" && ! git rev-parse --verify fr/test-foo-2 >/dev/null 2>&1 ) && pass "promote rerun: suffix 안 만듦" || fail "promote rerun: 새 suffix 생성됨"

# fr branch에서 archive content commit
( cd "$REPO" && git switch fr/test-foo -q && \
  echo "# archived" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )

# Archive 호출 (--no-remote 모드)
( cd "$REPO" && git switch main -q && \
  bash rd-workflow/scripts/lifecycle/archive.sh --no-remote ) >/dev/null

( cd "$REPO" && ! git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "archive: branch 삭제" || fail "archive: branch 잔존"
( cd "$REPO" && git tag --list "fr/*/test-foo" | grep -q . ) && pass "archive: tag 존재" || fail "archive: tag 부재"
( cd "$REPO" && [[ ! -f rd-workflow-workspace/.lifecycle/active-fr ]] ) && pass "archive: metadata 정리" || fail "archive: metadata 잔존"

# archive 재실행 — fr branch 부재 + tag 존재 → success exit
out="$(cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/test-foo --no-remote 2>&1 || true)"
[[ "$out" == *"이미 archive 완료"* ]] && pass "archive rerun: success exit (이미 완료)" || fail "archive rerun: $out"

rm -rf "$REPO"

# === Scenario 2: promote → rollback ===
echo "== scenario 2: promote → rollback =="
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-bar --no-worktree >/dev/null
( cd "$REPO" && git switch main -q && \
  bash rd-workflow/scripts/lifecycle/promote_rollback.sh --fr-branch fr/test-bar ) >/dev/null
( cd "$REPO" && ! git rev-parse --verify fr/test-bar >/dev/null 2>&1 ) && pass "rollback: branch 삭제" || fail "rollback: branch 잔존"
( cd "$REPO" && [[ ! -f rd-workflow-workspace/.lifecycle/active-fr ]] ) && pass "rollback: metadata 정리" || fail "rollback: metadata 잔존"
# rollback 후 CURRENT_TASK.md schema 보존 — LITE template / docs 가 사용자 계약으로 명시한 섹션이 baseline 에서 누락되지 않아야 한다.
( cd "$REPO" && grep -q '^## Output Files' CURRENT_TASK.md ) && pass "rollback: CURRENT_TASK.md 의 Output Files 섹션 보존" || fail "rollback: Output Files 섹션 누락"
( cd "$REPO" && grep -q '^## Branch / Worktree' CURRENT_TASK.md ) && pass "rollback: CURRENT_TASK.md 의 Branch/Worktree 섹션 보존" || fail "rollback: Branch/Worktree 섹션 누락"
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
( cd "$REPO" && git switch main -q && \
  git merge --no-ff fr/test-baz -m "merge: test-baz" -q && \
  rm -f rd-workflow-workspace/.lifecycle/active-fr && \
  git add -A rd-workflow-workspace/.lifecycle 2>/dev/null && \
  git commit -q -m "chore(lifecycle): archive test-baz metadata 정리" 2>/dev/null || true; \
  git tag "fr/2026-04-29-9999/test-baz" )

# 미push 상태에서 archive 재호출 (publish 실패 후 rerun 시뮬레이션)
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/test-baz ) >/dev/null 2>&1 || true

# 검증: bare mirror에 push 됐는가
( cd "$REPO" && git ls-remote origin refs/heads/main 2>/dev/null | grep -q . ) && pass "rerun: main pushed" || fail "rerun: main 미push"
( cd "$REPO" && git ls-remote origin "refs/tags/fr/2026-04-29-9999/test-baz" 2>/dev/null | grep -q . ) && pass "rerun: tag pushed" || fail "rerun: tag 미push"
( cd "$REPO" && ! git rev-parse --verify fr/test-baz >/dev/null 2>&1 ) && pass "rerun: fr branch 삭제" || fail "rerun: fr branch 잔존"

rm -rf "$REPO" "$BARE"

# === Scenario 4: fr_branch_gate hook smoke ===
echo "== scenario 4: fr_branch_gate hook smoke =="
HOOK="$PROJECT_ROOT/_ROOT_FILES_LITE/rd-workflow/scripts/hooks/fr_branch_gate.sh"
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
( cd "$REPO" && git switch main -q && grep -q "worktree-path=$WT_PATH" rd-workflow-workspace/.lifecycle/active-fr ) && pass "worktree-promote: metadata 기록" || fail "worktree-promote: metadata 부재"

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
( cd "$REPO" && git switch main -q && grep -qF "worktree-path=$EXPECTED_ABS" rd-workflow-workspace/.lifecycle/active-fr ) \
  && pass "rel-space: metadata canonical absolute path 기록" || fail "rel-space: canonicalize 실패"
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
( cd "$REPO" && [[ -f rd-workflow-workspace/.lifecycle/active-fr ]] ) && pass "fetch-fail: metadata 보존" || fail "fetch-fail: metadata 삭제됨"
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
( cd "$REPO" && grep -q "fr-branch=fr/test-foo" rd-workflow-workspace/.lifecycle/active-fr 2>/dev/null ) && pass "archive override-mismatch: active metadata 보존" || fail "archive override-mismatch: metadata 삭제됨"

# rollback override mismatch
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --fr-branch fr/test-bar 2>&1 ) || true )"
[[ "$out" == *"불일치"* ]] && pass "rollback override-mismatch: hard error" || fail "rollback override-mismatch: 통과 ($out)"
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "rollback override-mismatch: active branch 보존" || fail "rollback override-mismatch: active branch 삭제됨"
( cd "$REPO" && grep -q "fr-branch=fr/test-foo" rd-workflow-workspace/.lifecycle/active-fr 2>/dev/null ) && pass "rollback override-mismatch: active metadata 보존" || fail "rollback override-mismatch: metadata 삭제됨"

rm -rf "$REPO"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
