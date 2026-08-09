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
    printf 'rd-workflow-workspace/.lifecycle/loop-state\nrd-workflow-workspace/.lifecycle/.loop-state.*\n' > .gitignore; \
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

# bare remote fixture — 신규 archive cleanup 시나리오 공용
mk_bare() {  # mk_bare <tag> → bare repo 절대경로
  local b
  b="$(dirname "$(mktemp -d)")/bare-mirror-$1-$$"
  git init --bare "$b" -q
  echo "$b"
}

# git shim — PATH 앞단에서 특정 호출만 가로채고 나머지는 실제 git 에 위임한다.
# production 코드에 테스트 훅을 심지 않기 위한 fixture 자산.
# mode: local-drift | remote-drift | remote-missing-obj | ref-fail | ref-malformed | old-git | wt-list-fail | rev-parse-fail
mk_git_shim() {  # mk_git_shim <shim-dir> <mode>
  local dir="$1" mode="$2" real
  real="$(command -v git)"
  mkdir -p "$dir"
  cat > "$dir/git" <<SHIM
#!/bin/sh
REAL="$real"
MODE="$mode"
MARK="$dir/.fired"
SHIM
  cat >> "$dir/git" <<'SHIM'
case "$MODE" in
  old-git)
    # --version 만 위조하고 나머지는 그대로 위임 (lease 미지원 환경 재현)
    if [ "$1" = "--version" ]; then echo "git version 1.8.4"; exit 0; fi
    exec "$REAL" "$@"
    ;;
  rev-parse-fail)
    # merge 직후(HEAD 가 merge 커밋)의 rev-parse HEAD 만 고유 코드 42 로 실패시킨다.
    # Step 5 의 tag 충돌 검사도 rev-parse HEAD 를 쓰지만 그 시점 HEAD 는 cleanup commit 이라 매칭되지 않는다.
    case "$*" in
      "rev-parse HEAD")
        if "$REAL" log -1 --format=%s 2>/dev/null | grep -q '^merge: '; then
          echo "shim: simulated rev-parse failure" >&2; exit 42
        fi
        ;;
    esac
    exec "$REAL" "$@"
    ;;
  ref-malformed)
    # 정확 refname 행을 내되 OID 필드를 누락한 exit 0 출력 (판정 불능 경계)
    case "$*" in
      for-each-ref*refs/heads/fr/*)
        for arg in "$@"; do
          case "$arg" in refs/heads/fr/*) printf '%s\n' "$arg" ;; esac
        done
        exit 0
        ;;
    esac
    exec "$REAL" "$@"
    ;;
  ref-fail)
    # 로컬 ref 조회를 non-zero 로 실패시킨다 (판정 불능 재현)
    case "$*" in
      for-each-ref*refs/heads/fr/*) echo "shim: simulated ref lookup failure" >&2; exit 128 ;;
    esac
    exec "$REAL" "$@"
    ;;
  wt-list-fail)
    # worktree 목록 조회를 non-zero 로 실패시킨다.
    # 이 실패가 "대상 0건" 으로 오인되면 update-ref -d 로 진행해 broken worktree 를 만들 수 있다.
    # 단 Step 0 precheck(get_main_worktree_path)도 같은 명령을 쓰므로 무조건 실패시키면 core 에서 중단된다.
    # tag 부착(Step 5) 이후 = Step 7 시점부터만 개입한다.
    case "$*" in
      "worktree list --porcelain")
        if "$REAL" tag --list 'fr/*' | grep -q .; then
          echo "shim: simulated worktree list failure" >&2; exit 128
        fi
        ;;
    esac
    exec "$REAL" "$@"
    ;;
  local-drift)
    # for-each-ref 로 tip 을 읽은 "직후" 로컬 tip 을 이동시켜 expected-old 삭제를 거부시킨다.
    case "$*" in
      for-each-ref*refs/heads/fr/*)
        o="$(mktemp)"; e="$(mktemp)"
        "$REAL" "$@" >"$o" 2>"$e"; rc=$?
        if [ ! -f "$MARK" ]; then
          : > "$MARK"
          br="$("$REAL" for-each-ref --format='%(refname:short)' 'refs/heads/fr/*' | head -1)"
          if [ -n "$br" ]; then
            t="$("$REAL" rev-parse "$br^{tree}")"
            n="$("$REAL" commit-tree "$t" -p "$br" -m "shim drift")"
            "$REAL" branch -f "$br" "$n" >/dev/null 2>&1
          fi
        fi
        cat "$o"; cat "$e" >&2; rm -f "$o" "$e"; exit $rc
        ;;
    esac
    exec "$REAL" "$@"
    ;;
  remote-missing-obj)
    # ls-remote 가 "형식은 유효하지만 로컬에 객체가 없는" OID 를 반환하게 만든다.
    # ref 이름은 실제 ls-remote 에서 가져와 대상 브랜치를 정확히 맞춘다.
    case "$*" in
      ls-remote*refs/heads/fr/*)
        real_out="$("$REAL" "$@" 2>/dev/null)"
        ref="$(printf '%s' "$real_out" | awk '{print $2}' | head -1)"
        [ -n "$ref" ] && printf '0123456789abcdef0123456789abcdef01234567\t%s\n' "$ref"
        exit 0
        ;;
    esac
    exec "$REAL" "$@"
    ;;
  remote-drift)
    # ls-remote 로 원격 tip 을 읽은 "직후" 원격을 이동시켜 lease 를 거부시킨다.
    case "$*" in
      ls-remote*refs/heads/fr/*)
        o="$(mktemp)"; e="$(mktemp)"
        "$REAL" "$@" >"$o" 2>"$e"; rc=$?
        if [ ! -f "$MARK" ]; then
          : > "$MARK"
          ref="$(awk '{print $2}' "$o" | head -1)"
          if [ -n "$ref" ]; then
            t="$("$REAL" rev-parse HEAD^{tree})"
            n="$("$REAL" commit-tree "$t" -p HEAD -m "shim remote drift")"
            "$REAL" push --force origin "$n:$ref" >/dev/null 2>&1
          fi
        fi
        cat "$o"; cat "$e" >&2; rm -f "$o" "$e"; exit $rc
        ;;
    esac
    exec "$REAL" "$@"
    ;;
  *) exec "$REAL" "$@" ;;
esac
SHIM
  chmod +x "$dir/git"
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

# === Scenario 12: cleanup 정상 경로 — origin/<fr> 이 로컬 fr 보다 뒤처짐 (AC12) ===
# 이 워크플로는 fr 을 매 커밋마다 push 하지 않으므로 local fr tip > origin/fr tip 이 정상 상태다.
# git branch -d 는 upstream 기준으로 판정하므로 이 정상 상태를 "미머지" 로 오판정한다.
echo "== scenario 12: cleanup 정상 경로 (origin/fr 뒤처짐) =="
REPO="$(setup_repo)"
BARE12="$(mk_bare 12)"
( cd "$REPO" && git remote add origin "$BARE12" && git push -q origin main )
run_promote "$REPO" --short-title test-behind --no-worktree >/dev/null
# fr 을 한 번 push 해 upstream 을 설정 → 이후 로컬에만 커밋을 쌓아 origin/fr 을 뒤처지게 만든다
( cd "$REPO" && git commit -q --allow-empty -m "w1" && git push -q -u origin fr/test-behind )
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )

rc12=0
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || rc12=$?
[[ "$rc12" -eq 0 ]] && pass "behind-upstream: exit 0" || fail "behind-upstream: exit=$rc12"
( cd "$REPO" && ! git rev-parse --verify fr/test-behind >/dev/null 2>&1 ) \
  && pass "behind-upstream: 로컬 브랜치 삭제" || fail "behind-upstream: 로컬 브랜치 잔존"
( cd "$REPO" && [[ -z "$(git ls-remote origin refs/heads/fr/test-behind 2>/dev/null)" ]] ) \
  && pass "behind-upstream: 원격 브랜치 삭제" || fail "behind-upstream: 원격 브랜치 잔존"
( cd "$REPO" && git tag --list "fr/*/test-behind" | grep -q . ) \
  && pass "behind-upstream: tag 생성" || fail "behind-upstream: tag 부재"

rm -rf "$REPO" "$BARE12"

# === Scenario 13: 정상 부재 no-op(AC19) · local-only 원격 미시도(AC22) ===
echo "== scenario 13: 정상 부재 no-op / local-only =="

# 13-a (AC19): 로컬·원격 ref 가 "모두" 정상 부재인 상태로 Step 8/9 에 도달시킨다.
#   ref 를 미리 지워두면 archive.sh 의 rerun 안전망(fr 부재 + 동일 slug tag 존재 → 조기 exit 0,
#   archive.sh:74-82)에 걸려 Step 8/9 판정에 도달하지 못한다. 그래서 post-merge hook 으로
#   merge 직후(= 안전망 통과 후) 로컬 ref 를 제거하고, 원격은 처음부터 push 하지 않는다.
REPO="$(setup_repo)"
BARE13="$(mk_bare 13)"
( cd "$REPO" && git remote add origin "$BARE13" && git push -q origin main )
run_promote "$REPO" --short-title test-absent --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
cat > "$REPO/.git/hooks/post-merge" <<'HOOK'
#!/bin/sh
# post-merge hook 은 GIT_DIR 을 환경으로 받지 못하므로 직접 구한다
gd="$(git rev-parse --git-dir)"
[ -f "$gd/.absent-done" ] && exit 0
: > "$gd/.absent-done"
git update-ref -d refs/heads/fr/test-absent
HOOK
chmod +x "$REPO/.git/hooks/post-merge"

out13="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc13=0 || rc13=$?
[[ "$rc13" -eq 0 ]] && pass "no-op: exit 0" || fail "no-op: exit=$rc13"
[[ "$out13" != *"CLEANUP-PENDING"* ]] \
  && pass "no-op: 요약 블록 없음 (로컬·원격 정상 부재)" || fail "no-op: 정상 부재가 잔여로 기록됨"
[[ "$out13" == *"로컬 브랜치"*"없음"* ]] \
  && pass "no-op: 로컬 정상 부재 분기 도달" || fail "no-op: 로컬 부재 분기 미도달 (조기 종료 의심)"
[[ "$out13" == *"원격 브랜치"*"없음"* ]] \
  && pass "no-op: 원격 정상 부재 분기 도달" || fail "no-op: 원격 부재 분기 미도달"
( cd "$REPO" && git tag --list "fr/*/test-absent" | grep -q . ) \
  && pass "no-op: tag 생성 (core 정상 수행)" || fail "no-op: tag 부재"
rm -rf "$REPO" "$BARE13"

# 13-b: --no-remote(local-only) — origin 이 실존하지 않는 경로여도 원격 명령을 시도하지 않으므로 exit 0.
#       원격 명령을 시도했다면 반드시 실패했을 fixture 이므로 "미시도" 의 증거가 된다.
REPO="$(setup_repo)"
( cd "$REPO" && git remote add origin "/non/existent/bare-local-only-$$.git" )
run_promote "$REPO" --short-title test-localonly --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
rc13b=0
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || rc13b=$?
[[ "$rc13b" -eq 0 ]] && pass "local-only: exit 0 (원격 미시도)" || fail "local-only: exit=$rc13b"
( cd "$REPO" && ! git rev-parse --verify fr/test-localonly >/dev/null 2>&1 ) \
  && pass "local-only: 로컬 브랜치 삭제" || fail "local-only: 로컬 브랜치 잔존"
rm -rf "$REPO"

# 13-c: 대상 ref 는 없고 "하위 ref" 만 하나 있는 상태 → 정상 부재로 판정되어야 한다.
#   for-each-ref 의 패턴은 slash 경계의 하위 ref 도 매치하므로, %(objectname) 만 읽으면
#   child 의 유효 OID 한 줄이 나와 "대상 존재" 로 오인된다 (실측). 정확 refname 필터가 이를 막는다.
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-childref --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
cat > "$REPO/.git/hooks/post-merge" <<'HOOK'
#!/bin/sh
gd="$(git rev-parse --git-dir)"
[ -f "$gd/.child-done" ] && exit 0
: > "$gd/.child-done"
# 대상 ref 를 지우고, 그 아래 경로에 하위 ref 를 하나 만든다
oid=$(git rev-parse refs/heads/fr/test-childref)
git update-ref -d refs/heads/fr/test-childref
git update-ref refs/heads/fr/test-childref/child "$oid"
HOOK
chmod +x "$REPO/.git/hooks/post-merge"

out13c="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc13c=0 || rc13c=$?
[[ "$rc13c" -eq 0 ]] && pass "child-ref: exit 0" || fail "child-ref: exit=$rc13c"
[[ "$out13c" == *"로컬 브랜치"*"없음"* ]] \
  && pass "child-ref: 정상 부재로 판정 (하위 ref 를 대상으로 오인하지 않음)" || fail "child-ref: 부재 분기 미도달"
[[ "$out13c" != *"CLEANUP-PENDING"* ]] \
  && pass "child-ref: 요약 블록 없음" || fail "child-ref: 잔여로 잘못 기록됨"
( cd "$REPO" && git rev-parse --verify refs/heads/fr/test-childref/child >/dev/null 2>&1 ) \
  && pass "child-ref: 하위 ref 보존 (건드리지 않음)" || fail "child-ref: 하위 ref 가 삭제됨"
rm -rf "$REPO"

# === Scenario 14: 안전 불변식·일반 실패·core 실패 (AC13/20/21) ===
echo "== scenario 14: 안전 불변식 / 일반 cleanup 실패 / core 실패 =="

# 14-a (AC13): 진짜 미머지 — post-merge hook 이 Step 3 직후 fr tip 을 전진시킨다.
REPO="$(setup_repo)"
BARE14="$(mk_bare 14)"
( cd "$REPO" && git remote add origin "$BARE14" && git push -q origin main )
run_promote "$REPO" --short-title test-unmerged --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
  && git push -q -u origin fr/test-unmerged )
( cd "$REPO" && git switch main -q )
cat > "$REPO/.git/hooks/post-merge" <<'HOOK'
#!/bin/sh
# 한 번만 개입 — merge 직후 fr tip 을 새 커밋으로 전진시켜 미머지 상태를 만든다.
gd="$(git rev-parse --git-dir)"
[ -f "$gd/.drift-done" ] && exit 0
: > "$gd/.drift-done"
tree=$(git rev-parse refs/heads/fr/test-unmerged^{tree}) || exit 0
new=$(git commit-tree "$tree" -p refs/heads/fr/test-unmerged -m "drift") || exit 0
git branch -f fr/test-unmerged "$new"
HOOK
chmod +x "$REPO/.git/hooks/post-merge"

out14="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc14=0 || rc14=$?
[[ "$rc14" -ne 0 ]] && pass "unmerged: non-zero 종료" || fail "unmerged: exit 0 (위반 미검출)"
( cd "$REPO" && git rev-parse --verify fr/test-unmerged >/dev/null 2>&1 ) \
  && pass "unmerged: 로컬 ref 보존" || fail "unmerged: 로컬 ref 삭제됨"
( cd "$REPO" && git ls-remote origin refs/heads/fr/test-unmerged 2>/dev/null | grep -q . ) \
  && pass "unmerged: 원격 ref 보존 (삭제 건너뜀)" || fail "unmerged: 원격 ref 삭제됨"
[[ "$out14" == *"CLEANUP-PENDING"* ]] \
  && pass "unmerged: 요약 블록 출력" || fail "unmerged: 요약 블록 부재"
# 복구 명령 계약 — 위반→원격 skip 경로의 `복구:` 도 비파괴 확인 명령이어야 한다
_rec14="$(printf '%s\n' "$out14" | grep '복구:' || true)"
[[ -n "$_rec14" && "$_rec14" != *"archive.sh"* ]] \
  && pass "unmerged: 복구 명령에 archive.sh 재실행 없음" || fail "unmerged: 복구 명령이 변이 명령"
[[ "$_rec14" != *"--force"* && "$_rec14" != *"branch -D"* && "$_rec14" != *"push origin --delete"* ]] \
  && pass "unmerged: 복구 명령에 파괴적 명령 없음" || fail "unmerged: 복구 명령에 파괴적 명령 포함"
rm -rf "$REPO" "$BARE14"

# 14-b (AC20 + AC4): worktree teardown 실패 → "나머지 단계가 모두 시도" 됨을 직접 확인한다.
#   AC4 의 요구는 단계 간 계속이므로 --no-remote 를 쓰지 않는다. bare remote 를 붙이고
#   loop-state 를 미리 기록해, worktree 만 실패했을 때 원격 삭제와 loop-state 정리가
#   모두 수행되는지 각각 assert 한다. worktree 안 untracked 파일이 remove 를 거부시킨다.
REPO="$(setup_repo)"
BARE14B="$(mk_bare 14b)"
( cd "$REPO" && git remote add origin "$BARE14B" && git push -q origin main )
WT14="$(dirname "$REPO")/wt-fail-$$"
run_promote "$REPO" --short-title test-wtfail --worktree-path "$WT14" >/dev/null
( cd "$WT14" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git push -q origin fr/test-wtfail )
echo "dirty" > "$WT14/junk-untracked.txt"
mkdir -p "$REPO/rd-workflow-workspace/.lifecycle"
printf 'verify-fail::test-wtfail::test=2\n' > "$REPO/rd-workflow-workspace/.lifecycle/loop-state"

out14b="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc14b=0 || rc14b=$?
[[ "$rc14b" -eq 0 ]] && pass "wt-fail: exit 0 유지 (일반 cleanup 실패)" || fail "wt-fail: exit=$rc14b"
[[ "$out14b" == *"CLEANUP-PENDING"* ]] && pass "wt-fail: 요약 블록 출력" || fail "wt-fail: 요약 블록 부재"
[[ "$out14b" == *"[worktree]"* ]] && pass "wt-fail: worktree 항목 기록" || fail "wt-fail: worktree 항목 누락"
[[ "$out14b" == *"[local-branch]"* ]] \
  && pass "wt-fail: local-branch 미시도 기록" || fail "wt-fail: local-branch 항목 누락"
# AC4 핵심 — worktree 가 실패해도 뒤 단계가 모두 시도된다
( cd "$REPO" && [[ -z "$(git ls-remote origin refs/heads/fr/test-wtfail 2>/dev/null)" ]] ) \
  && pass "wt-fail: 원격 브랜치 삭제 수행 (단계 계속)" || fail "wt-fail: 원격 삭제 미수행"
[[ ! -s "$REPO/rd-workflow-workspace/.lifecycle/loop-state" ]] \
  && pass "wt-fail: loop-state 정리 수행 (단계 계속)" || fail "wt-fail: loop-state 미정리"
( cd "$REPO" && git rev-parse --verify fr/test-wtfail >/dev/null 2>&1 ) \
  && pass "wt-fail: 로컬 ref 보존 (update-ref 미시도)" || fail "wt-fail: 로컬 ref 삭제됨 (broken worktree 위험)"
( cd "$REPO" && git tag --list "fr/*/test-wtfail" | grep -q . ) \
  && pass "wt-fail: core 산출물(tag) 보존" || fail "wt-fail: tag 부재"
# 복구 명령 계약 — `복구:` 줄은 비파괴 확인 명령이어야 한다 (변이 명령·강제 삭제 금지)
_rec14b="$(printf '%s\n' "$out14b" | grep '복구:' || true)"
[[ -n "$_rec14b" && "$_rec14b" != *"archive.sh"* ]] \
  && pass "wt-fail: 복구 명령에 archive.sh 재실행 없음" || fail "wt-fail: 복구 명령이 변이 명령 (archive.sh 재실행)"
[[ "$_rec14b" != *"--force"* && "$_rec14b" != *"branch -D"* ]] \
  && pass "wt-fail: 복구 명령에 강제 삭제 없음" || fail "wt-fail: 복구 명령에 파괴적 옵션 포함"
( cd "$REPO" && git worktree remove --force "$WT14" ) >/dev/null 2>&1 || true
rm -rf "$REPO" "$WT14" "$BARE14B"

# 14-c (AC21): core 실패 유지 — merge conflict 는 종전대로 non-zero.
REPO="$(setup_repo)"
( cd "$REPO" && echo "base" > conflict.txt && git add conflict.txt && git commit -q -m "base file" )
run_promote "$REPO" --short-title test-conflict --no-worktree >/dev/null
( cd "$REPO" && echo "fr-side" > conflict.txt && git add conflict.txt && git commit -q -m "fr edit" )
( cd "$REPO" && git switch main -q && echo "main-side" > conflict.txt \
  && RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit -q -am "main edit" )
rc14c=0
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || rc14c=$?
[[ "$rc14c" -ne 0 ]] && pass "core-fail: merge conflict non-zero" || fail "core-fail: exit 0"
( cd "$REPO" && git rev-parse --verify fr/test-conflict >/dev/null 2>&1 ) \
  && pass "core-fail: fr branch 보존" || fail "core-fail: fr branch 삭제됨"
( cd "$REPO" && git merge --abort ) >/dev/null 2>&1 || true
rm -rf "$REPO"

# 14-d (AC4 루프): 동일 브랜치 worktree 2개 — 앞은 dirty(제거 실패), 뒤는 clean(제거 성공).
#   git worktree add 의 기본 동작은 동일 브랜치 중복 체크아웃을 거부하지만 --force 가 그 보호를 무효화한다.
#   따라서 "여러 대상 중 하나가 실패해도 나머지를 시도" 를 직접 재현할 수 있다 (break 제거의 실효 검증).
REPO="$(setup_repo)"
WT_A="$(dirname "$REPO")/wt-multi-a-$$"
WT_B="$(dirname "$REPO")/wt-multi-b-$$"
run_promote "$REPO" --short-title test-multi --worktree-path "$WT_A" >/dev/null
( cd "$WT_A" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git worktree add -q --force "$WT_B" fr/test-multi )
echo "dirty" > "$WT_A/junk-untracked.txt"   # 앞 대상만 제거 실패하게 만든다
out14d="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc14d=0 || rc14d=$?
[[ "$rc14d" -eq 0 ]] && pass "wt-multi: exit 0 유지" || fail "wt-multi: exit=$rc14d"
[[ ! -d "$WT_B" ]] && pass "wt-multi: 뒤 worktree 제거 성공 (루프 계속)" || fail "wt-multi: 뒤 worktree 미제거 (break 잔존 의심)"
[[ -d "$WT_A" ]] && pass "wt-multi: 앞 worktree 는 실패로 잔존" || fail "wt-multi: 앞 worktree 가 제거됨"
( cd "$REPO" && git rev-parse --verify fr/test-multi >/dev/null 2>&1 ) \
  && pass "wt-multi: 로컬 ref 보존 (등록 잔존)" || fail "wt-multi: 로컬 ref 삭제됨 (broken worktree 위험)"
[[ "$out14d" == *"[worktree]"* ]] && pass "wt-multi: worktree 잔여 기록" || fail "wt-multi: 항목 누락"
( cd "$REPO" && git worktree remove --force "$WT_A" ) >/dev/null 2>&1 || true
rm -rf "$REPO" "$WT_A" "$WT_B"

# 14-e (worktree 안전): locked + 경로 소실 → prune 이 exit 0 인데 등록이 남는다.
#   제거 명령의 성공만 믿으면 ref 를 지워 broken worktree 를 만든다. 재조회 판정이 이를 막아야 한다.
REPO="$(setup_repo)"
WT_L="$(dirname "$REPO")/wt-locked-$$"
run_promote "$REPO" --short-title test-locked --worktree-path "$WT_L" >/dev/null
( cd "$WT_L" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git worktree lock "$WT_L" )
mv "$WT_L" "${WT_L}-moved"   # 경로만 사라지게 한다 (등록은 locked 로 남음)
out14e="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc14e=0 || rc14e=$?
[[ "$rc14e" -eq 0 ]] && pass "wt-locked: exit 0 유지 (일반 cleanup 실패)" || fail "wt-locked: exit=$rc14e"
( cd "$REPO" && git rev-parse --verify fr/test-locked >/dev/null 2>&1 ) \
  && pass "wt-locked: 로컬 ref 보존 (prune exit 0 를 신뢰하지 않음)" || fail "wt-locked: 로컬 ref 삭제됨"
[[ "$out14e" == *"[worktree]"* ]] && pass "wt-locked: worktree 잔여 기록" || fail "wt-locked: 항목 누락"
( cd "$REPO" && git worktree unlock "$WT_L" ) >/dev/null 2>&1 || true
rm -rf "$REPO" "${WT_L}-moved"

# 14-f (worktree 안전 + 오대상 제거 방어): 경로에 개행이 있으면 --porcelain 출력이 쪼개져
#   경로 추출값이 잘린다. 추출 "줄 수" 는 정상과 같아 개수 비교로는 감지되지 않는다.
#   결정적으로, 잘린 접두사 위치에 "다른 브랜치의 clean worktree" 가 있으면
#   git worktree remove 가 실패하지 않고 범위 밖 worktree 를 지운다.
#   따라서 fixture 를 그 충돌 상황으로 구성해 소유권 검증이 오대상 제거를 막는지 직접 확인한다.
REPO="$(setup_repo)"
WT_PFX="$(dirname "$REPO")/wt-pfx-$$"                       # 잘린 접두사와 같은 경로
WT_NL="${WT_PFX}$(printf '\nsecond')"                        # 개행 포함 경로 (접두사가 WT_PFX 와 동일)
run_promote "$REPO" --short-title test-nlpath --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
( cd "$REPO" && git branch other-wt main && git worktree add -q --force "$WT_PFX" other-wt )
( cd "$REPO" && git worktree add -q --force "$WT_NL" fr/test-nlpath )

out14f="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc14f=0 || rc14f=$?
[[ "$rc14f" -eq 0 ]] && pass "wt-newline: exit 0 유지" || fail "wt-newline: exit=$rc14f"
# 핵심 — 잘린 접두사가 가리키는 다른 브랜치 worktree 를 건드리면 안 된다
[[ -d "$WT_PFX" ]] \
  && pass "wt-newline: 범위 밖 worktree 보존 (오대상 제거 차단)" || fail "wt-newline: 다른 브랜치 worktree 가 제거됨"
( cd "$REPO" && git worktree list --porcelain | grep -q -x -F "branch refs/heads/other-wt" ) \
  && pass "wt-newline: 범위 밖 worktree 등록 유지" || fail "wt-newline: 범위 밖 등록 소실"
( cd "$REPO" && git rev-parse --verify fr/test-nlpath >/dev/null 2>&1 ) \
  && pass "wt-newline: 로컬 ref 보존 (조용한 '대상 없음' 아님)" || fail "wt-newline: 로컬 ref 삭제됨"
[[ "$out14f" == *"[worktree]"* ]] && pass "wt-newline: worktree 잔여 기록" || fail "wt-newline: 항목 누락"
( cd "$REPO" && git worktree remove --force "$WT_NL" ) >/dev/null 2>&1 || true
( cd "$REPO" && git worktree remove --force "$WT_PFX" ) >/dev/null 2>&1 || true
rm -rf "$REPO" "$WT_NL" "$WT_PFX"

# === Scenario 15: 원격 tip 이 base 의 ancestor 아님 (AC15) ===
# 로컬에서 만든 무관한 커밋을 원격 fr ref 로 강제 push 한다.
# 객체는 로컬에 있으므로 판정은 가능하지만 ancestor 가 아니므로 원격 삭제를 수행하면 안 된다.
echo "== scenario 15: 원격 tip ancestor 아님 =="
REPO="$(setup_repo)"
BARE15="$(mk_bare 15)"
( cd "$REPO" && git remote add origin "$BARE15" && git push -q origin main )
run_promote "$REPO" --short-title test-rdrift --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
  && git push -q -u origin fr/test-rdrift )
# 로컬 fr 과 무관한 커밋을 만들어 원격 ref 만 그쪽으로 옮긴다 (worktree/index 불변)
ALIEN15="$( cd "$REPO" && git commit-tree "$(git rev-parse HEAD^{tree})" \
  -p "$(git rev-parse HEAD)" -m "alien" )"
( cd "$REPO" && git push -q --force origin "$ALIEN15:refs/heads/fr/test-rdrift" )
( cd "$REPO" && git switch main -q )

out15="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc15=0 || rc15=$?
[[ "$rc15" -ne 0 ]] && pass "remote-drift: non-zero 종료" || fail "remote-drift: exit 0"
( cd "$REPO" && git ls-remote origin refs/heads/fr/test-rdrift 2>/dev/null | grep -q . ) \
  && pass "remote-drift: 원격 ref 보존" || fail "remote-drift: 원격 ref 삭제됨"
[[ "$out15" == *"CLEANUP-PENDING"* ]] \
  && pass "remote-drift: 요약 블록 출력" || fail "remote-drift: 요약 블록 부재"
[[ "$out15" == *"[remote-branch]"* ]] \
  && pass "remote-drift: remote-branch 항목 기록" || fail "remote-drift: 항목 누락"
rm -rf "$REPO" "$BARE15"

# === Scenario 16: shim 기반 안전 불변식 (AC14/16/17/18) ===
echo "== scenario 16: TOCTOU / 조회 실패 / 구 git =="

# 공용 fixture 준비 — remote 모드 + fr push 완료 상태
mk_shim_repo() {  # mk_shim_repo <slug> → "repo|bare" 출력
  local slug="$1" r b
  r="$(setup_repo)"; b="$(mk_bare "sh-$slug")"
  ( cd "$r" && git remote add origin "$b" && git push -q origin main )
  ( cd "$r" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title "$slug" --no-worktree ) >/dev/null
  ( cd "$r" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
    && git push -q -u origin "fr/$slug" )
  ( cd "$r" && git switch main -q )
  echo "$r|$b"
}

# 16-a (AC14): 로컬 tip 이동 → expected-old 삭제 거부
_p="$(mk_shim_repo tt-localdrift)"; REPO="${_p%%|*}"; BARE16A="${_p##*|}"
SHIM16A="$(dirname "$REPO")/shim-a-$$"; mk_git_shim "$SHIM16A" local-drift
out16a="$( ( cd "$REPO" && PATH="$SHIM16A:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc16a=0 || rc16a=$?
[[ "$rc16a" -ne 0 ]] && pass "local-drift: non-zero 종료" || fail "local-drift: exit 0"
( cd "$REPO" && git rev-parse --verify fr/tt-localdrift >/dev/null 2>&1 ) \
  && pass "local-drift: 로컬 ref 보존" || fail "local-drift: 로컬 ref 삭제됨"
( cd "$REPO" && git ls-remote origin refs/heads/fr/tt-localdrift 2>/dev/null | grep -q . ) \
  && pass "local-drift: 원격 삭제 건너뜀" || fail "local-drift: 원격 ref 삭제됨"
rm -rf "$REPO" "$BARE16A" "$SHIM16A"

# 16-b (AC16): 원격 검증 후 push 직전 이동 → lease 거부. 로컬은 이미 삭제되었어도 복구하지 않는다(AC10).
_p="$(mk_shim_repo tt-remotedrift)"; REPO="${_p%%|*}"; BARE16B="${_p##*|}"
SHIM16B="$(dirname "$REPO")/shim-b-$$"; mk_git_shim "$SHIM16B" remote-drift
out16b="$( ( cd "$REPO" && PATH="$SHIM16B:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc16b=0 || rc16b=$?
[[ "$rc16b" -ne 0 ]] && pass "remote-lease: non-zero 종료" || fail "remote-lease: exit 0"
[[ "$out16b" == *"CLEANUP-PENDING"* ]] \
  && pass "remote-lease: 요약 블록 출력" || fail "remote-lease: 요약 블록 부재"
( cd "$REPO" && ! git rev-parse --verify fr/tt-remotedrift >/dev/null 2>&1 ) \
  && pass "remote-lease: 삭제된 로컬 ref 를 복구하지 않음 (AC10)" || fail "remote-lease: 로컬 ref 복구됨"
# lease 보호의 핵심 대상 — 거부된 뒤 이동된 원격 ref 가 실제로 남아 있어야 한다.
# 이 assert 가 없으면 구현이 무보호 삭제로 fallback 해도 non-zero·요약만으로 통과한다.
( cd "$REPO" && git ls-remote origin refs/heads/fr/tt-remotedrift 2>/dev/null | grep -q . ) \
  && pass "remote-lease: 이동된 원격 ref 보존 (lease 거부)" || fail "remote-lease: 원격 ref 가 삭제됨 (무보호 fallback 의심)"
rm -rf "$REPO" "$BARE16B" "$SHIM16B"

# 16-c (AC17): 로컬 ref 조회 실패 → 정상 부재로 오분류되지 않고 안전 불변식 위반
_p="$(mk_shim_repo tt-reffail)"; REPO="${_p%%|*}"; BARE16C="${_p##*|}"
SHIM16C="$(dirname "$REPO")/shim-c-$$"; mk_git_shim "$SHIM16C" ref-fail
out16c="$( ( cd "$REPO" && PATH="$SHIM16C:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc16c=0 || rc16c=$?
[[ "$rc16c" -ne 0 ]] && pass "ref-fail: non-zero 종료" || fail "ref-fail: exit 0 (부재로 오분류)"
[[ "$out16c" == *"[local-branch]"* ]] \
  && pass "ref-fail: local-branch 항목 기록" || fail "ref-fail: 항목 누락"
( cd "$REPO" && git ls-remote origin refs/heads/fr/tt-reffail 2>/dev/null | grep -q . ) \
  && pass "ref-fail: 원격 삭제 건너뜀" || fail "ref-fail: 원격 ref 삭제됨"
# fail-closed 의 핵심 결과 — 판정 불능이면 대상 로컬 ref 를 삭제하지 않아야 한다.
# 이 assert 가 없으면 구현이 잘못 삭제해도 non-zero·기록·원격 skip 만으로 통과한다.
( cd "$REPO" && git rev-parse --verify fr/tt-reffail >/dev/null 2>&1 ) \
  && pass "ref-fail: 대상 로컬 ref 보존" || fail "ref-fail: 로컬 ref 가 삭제됨 (fail-closed 붕괴)"
rm -rf "$REPO" "$BARE16C" "$SHIM16C"

# 16-g: 정확 refname 행은 있는데 OID 필드가 비어 있음 → 정상 부재로 합쳐지지 않고 판정 불능이어야 한다.
#   행 존재와 OID 값을 한 변수로 합쳐 처리하면 빈 문자열이 되어 "부재" 분기로 빠진다 (fail-closed 붕괴).
_p="$(mk_shim_repo tt-refmalformed)"; REPO="${_p%%|*}"; BARE16G="${_p##*|}"
SHIM16G="$(dirname "$REPO")/shim-g-$$"; mk_git_shim "$SHIM16G" ref-malformed
out16g="$( ( cd "$REPO" && PATH="$SHIM16G:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc16g=0 || rc16g=$?
[[ "$rc16g" -ne 0 ]] && pass "ref-malformed: non-zero 종료" || fail "ref-malformed: exit 0 (부재로 오분류)"
[[ "$out16g" == *"[local-branch]"* ]] \
  && pass "ref-malformed: local-branch 위반 기록" || fail "ref-malformed: 항목 누락"
[[ "$out16g" != *"로컬 브랜치"*"없음"* ]] \
  && pass "ref-malformed: 정상 부재 분기로 가지 않음" || fail "ref-malformed: 부재로 오분류됨"
( cd "$REPO" && git ls-remote origin refs/heads/fr/tt-refmalformed 2>/dev/null | grep -q . ) \
  && pass "ref-malformed: 원격 삭제 건너뜀" || fail "ref-malformed: 원격 ref 삭제됨"
( cd "$REPO" && git rev-parse --verify fr/tt-refmalformed >/dev/null 2>&1 ) \
  && pass "ref-malformed: 대상 로컬 ref 보존" || fail "ref-malformed: 로컬 ref 가 삭제됨 (fail-closed 붕괴)"
rm -rf "$REPO" "$BARE16G" "$SHIM16G"

# 16-d (AC18): 구 git(lease 미지원) → 무보호 삭제 미실행 + non-zero + 요약 블록 + 후속 비파괴 cleanup 수행
_p="$(mk_shim_repo tt-oldgit)"; REPO="${_p%%|*}"; BARE16D="${_p##*|}"
SHIM16D="$(dirname "$REPO")/shim-d-$$"; mk_git_shim "$SHIM16D" old-git
mkdir -p "$REPO/rd-workflow-workspace/.lifecycle"
printf 'verify-fail::tt-oldgit::test=2\n' > "$REPO/rd-workflow-workspace/.lifecycle/loop-state"
out16d="$( ( cd "$REPO" && PATH="$SHIM16D:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc16d=0 || rc16d=$?
[[ "$rc16d" -ne 0 ]] && pass "old-git: non-zero 종료" || fail "old-git: exit 0"
( cd "$REPO" && git ls-remote origin refs/heads/fr/tt-oldgit 2>/dev/null | grep -q . ) \
  && pass "old-git: 무보호 원격 삭제 미실행" || fail "old-git: 원격 ref 삭제됨"
[[ "$out16d" == *"CLEANUP-PENDING"* ]] \
  && pass "old-git: 요약 블록 출력" || fail "old-git: 요약 블록 부재"
[[ ! -s "$REPO/rd-workflow-workspace/.lifecycle/loop-state" ]] \
  && pass "old-git: 후속 비파괴 cleanup(loop-state) 수행" || fail "old-git: loop-state 미정리"
rm -rf "$REPO" "$BARE16D" "$SHIM16D"

# 16-f: 원격 tip 객체가 로컬에 없음 → ancestor 판정 불능 → 안전 불변식 위반.
#   ls-remote 가 "형식은 유효하지만 로컬에 없는" OID 를 반환하게 해 cat-file -e 게이트를 검증한다.
#   (실제 상황: 다른 머신에서 push 된 커밋을 이 저장소가 아직 받지 못한 경우)
_p="$(mk_shim_repo tt-missingobj)"; REPO="${_p%%|*}"; BARE16F="${_p##*|}"
SHIM16F="$(dirname "$REPO")/shim-f-$$"; mk_git_shim "$SHIM16F" remote-missing-obj
out16f="$( ( cd "$REPO" && PATH="$SHIM16F:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc16f=0 || rc16f=$?
[[ "$rc16f" -ne 0 ]] && pass "missing-obj: non-zero 종료" || fail "missing-obj: exit 0 (판정 불능 미검출)"
( cd "$REPO" && git ls-remote origin refs/heads/fr/tt-missingobj 2>/dev/null | grep -q . ) \
  && pass "missing-obj: 원격 ref 보존" || fail "missing-obj: 원격 ref 삭제됨"
[[ "$out16f" == *"CLEANUP-PENDING"* ]] \
  && pass "missing-obj: 요약 블록 출력" || fail "missing-obj: 요약 블록 부재"
_rec16f="$(printf '%s\n' "$out16f" | grep '복구:' || true)"
[[ -n "$_rec16f" && "$_rec16f" != *"archive.sh"* ]] \
  && pass "missing-obj: 복구 명령에 archive.sh 재실행 없음" || fail "missing-obj: 무효한 재실행 안내"
[[ "$_rec16f" != *"push origin --delete"* && "$_rec16f" != *"--force"* ]] \
  && pass "missing-obj: 복구 명령이 비파괴" || fail "missing-obj: 복구 명령에 파괴적 명령 포함"
# AC10 — 이 분기는 Step 8 에서 로컬 ref 가 안전 검증을 통과해 삭제된 뒤 Step 9 에서 실패하는 경로다.
# 이미 삭제된 ref 를 보상 복구하지 않으며, 종료 메시지가 그 제한된 보존 범위를 사용자에게 알려야 한다.
( cd "$REPO" && ! git rev-parse --verify fr/tt-missingobj >/dev/null 2>&1 ) \
  && pass "missing-obj: 삭제된 로컬 ref 를 복구하지 않음 (AC10)" || fail "missing-obj: 로컬 ref 가 복구됨"
[[ "$out16f" == *"아직 삭제하지 않은 ref"* && "$out16f" == *"복구하지 않습니다"* ]] \
  && pass "missing-obj: 제한된 보존 범위 종료 문구" || fail "missing-obj: 보존 범위 문구 부정확"
# 수동 확인 절차가 실제로 안내되는지 (사유 줄)
[[ "$out16f" == *"git fetch origin"* && "$out16f" == *"merge-base --is-ancestor"* ]] \
  && pass "missing-obj: fetch/compare 확인 절차 안내" || fail "missing-obj: 확인 절차 안내 누락"
rm -rf "$REPO" "$BARE16F" "$SHIM16F"

# 16-e: worktree 목록 조회 실패 → "대상 없음" 으로 오인하지 않고 ref 삭제를 금지한다.
#       process substitution 안에서 목록을 뽑던 구조의 회귀 방어 (조회 실패가 while 로 전달되지 않음).
_p="$(mk_shim_repo tt-wtlistfail)"; REPO="${_p%%|*}"; BARE16E="${_p##*|}"
SHIM16E="$(dirname "$REPO")/shim-e-$$"; mk_git_shim "$SHIM16E" wt-list-fail
out16e="$( ( cd "$REPO" && PATH="$SHIM16E:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc16e=0 || rc16e=$?
[[ "$rc16e" -ne 0 ]] && pass "wt-list-fail: non-zero 종료" || fail "wt-list-fail: exit 0"
( cd "$REPO" && git rev-parse --verify fr/tt-wtlistfail >/dev/null 2>&1 ) \
  && pass "wt-list-fail: 로컬 ref 보존 (삭제 금지)" || fail "wt-list-fail: 로컬 ref 삭제됨"
( cd "$REPO" && git ls-remote origin refs/heads/fr/tt-wtlistfail 2>/dev/null | grep -q . ) \
  && pass "wt-list-fail: 원격 삭제 건너뜀" || fail "wt-list-fail: 원격 ref 삭제됨"
[[ "$out16e" == *"[worktree]"* ]] \
  && pass "wt-list-fail: worktree 항목 기록" || fail "wt-list-fail: 항목 누락"
rm -rf "$REPO" "$BARE16E" "$SHIM16E"

# 16-h: core 실패는 원 명령의 종료 상태를 그대로 전달해야 한다 (특정 값으로 정규화 금지).
#   MERGE_BASE_COMMIT 캡처는 이번 변경이 추가한 core guard 이므로 이 계약을 새로 지켜야 한다.
_p="$(mk_shim_repo tt-revparsefail)"; REPO="${_p%%|*}"; BARE16H="${_p##*|}"
SHIM16H="$(dirname "$REPO")/shim-h-$$"; mk_git_shim "$SHIM16H" rev-parse-fail
rc16h=0
( cd "$REPO" && PATH="$SHIM16H:$PATH" bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || rc16h=$?
[[ "$rc16h" -eq 42 ]] \
  && pass "rev-parse-fail: core 실패의 원 종료 상태 전달 (42)" || fail "rev-parse-fail: 상태 정규화됨 (rc=$rc16h)"
( cd "$REPO" && git rev-parse --verify fr/tt-revparsefail >/dev/null 2>&1 ) \
  && pass "rev-parse-fail: fr branch 보존" || fail "rev-parse-fail: fr branch 삭제됨"
( cd "$REPO" && [[ -z "$(git tag --list 'fr/*/tt-revparsefail')" ]] ) \
  && pass "rev-parse-fail: tag 미생성 (core 중단)" || fail "rev-parse-fail: tag 생성됨"
rm -rf "$REPO" "$BARE16H" "$SHIM16H"

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
