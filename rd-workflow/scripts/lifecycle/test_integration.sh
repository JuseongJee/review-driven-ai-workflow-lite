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

# 전역·시스템 git 설정 간섭 차단. fixture 의 .git/hooks 가 전역 core.hooksPath 로
# 무력화되면 hook 기반 테스트가 조용히 거짓 통과한다.
# git 2.32+ 에서 유효하고 그 이하 버전에서는 무시되므로 부작용이 없다.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }

# pipefail 하에서 `cmd | grep -q needle` 은 매치 성공 시 오히려 실패한다 —
# grep 이 첫 매치에서 종료하면 상류 cmd 가 SIGPIPE(141) 로 죽고 pipefail 이 이를
# 파이프라인 실패로 전파하기 때문이다. stdin 을 끝까지 읽어 substring 으로 판정한다.
out_has() {  # out_has <needle> — stdin 을 읽어 needle 포함 여부 반환
  local needle="$1" out
  out="$(cat)"
  [[ "$out" == *"$needle"* ]]
}

# fixture 전용 전수 검증 대역을 씁니다.
#
# 아카이브는 merge 직후 "이 내용으로 전수 검증을 통과한 기록" 을 요구하고, 기록이 없으면
# 그 자리에서 전수 검증을 직접 돌립니다. fixture 에는 진짜 검증 대상이 없으므로 대역을 두어
# 증명만 남기게 합니다 — 대역이 없으면 모든 lifecycle 시나리오가 게이트에서 막힙니다.
# 게이트 자체의 판정(차단·통과·untracked 분기)은 lifecycle 단위 테스트가 검증합니다.
# 성공 경로에서 stderr 를 쓰지 않습니다 — 무출력 계약을 검사하는 시나리오가 있습니다.
write_selftest_proof_stub() {  # write_selftest_proof_stub <경로>
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
_r="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$_r/rd-workflow/scripts/_smoke_common.sh" 2>/dev/null || exit 1
_fp="$(smoke_proof_fingerprint "$_r" worktree)" || exit 1
_us=0; smoke_untracked_state "$_r" >/dev/null 2>&1 || _us=$?
smoke_record_full_pass "$_r" "$_fp" "$_us" 2>/dev/null || exit 1
exit 0
STUB
}

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
    git config core.hooksPath "$d/.git/hooks"; \
    if [[ -f "$PROJECT_ROOT/_ROOT_FILES/CURRENT_TASK.md" ]]; then \
      cp "$PROJECT_ROOT/_ROOT_FILES/CURRENT_TASK.md" CURRENT_TASK.md; \
    else \
      printf '# Current Task\n\n## Short Title\n-\n\n## Branch / Worktree\nmain\n\n## Status\n대기 중\n' > CURRENT_TASK.md; \
    fi; \
    mkdir -p rd-workflow/scripts/lifecycle rd-workflow/scripts/hooks rd-workflow-workspace/.lifecycle; \
    printf 'rd-workflow-workspace/.lifecycle/loop-state\nrd-workflow-workspace/.lifecycle/.loop-state.*\nrd-workflow-workspace/.lifecycle/selftest-full-cache\n' > .gitignore; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/lifecycle/*.sh rd-workflow/scripts/lifecycle/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/hooks/*.sh rd-workflow/scripts/hooks/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_state_common.sh rd-workflow/scripts/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_smoke_common.sh rd-workflow/scripts/; \
    write_selftest_proof_stub rd-workflow/scripts/self_test.sh; \
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

# 실제 Claude Code 설치 pre-commit hook 과 같은 판정 — main|master 직접 커밋 차단.
# --no-verify 로만 우회 가능하며 RD_LIFECYCLE_BYPASS_REASON 은 참조하지 않는다.
#
# marker 파일과 고유 문구를 남기는 이유: 통제군에서 rc != 0 만 보면 "커밋할 내용 없음"
# 같은 다른 git 오류도 통과해 hook 이 실행되지 않는데도 활성으로 오판할 수 있다.
# 실행 흔적을 남겨야 hook 이 실제로 돌았다는 것을 직접 증명할 수 있다.
install_blocking_pre_commit() {  # install_blocking_pre_commit <repo>
  cat > "$1/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
gd="$(git rev-parse --git-dir)"
: > "$gd/.pre-commit-ran"
branch=$(git symbolic-ref --short HEAD 2>/dev/null)
case "$branch" in
  main|master)
    echo "RD-TEST-HOOK-BLOCKED: $branch" >&2
    exit 1
    ;;
esac
exit 0
HOOK
  chmod +x "$1/.git/hooks/pre-commit"
  rm -f "$1/.git/.pre-commit-ran"
}

# marker 만 남기고 통과시키는(exit 0) pre-commit hook.
# install_blocking_pre_commit 과 별도로 두는 이유: 그 hook 은 main|master 커밋을 실패시키므로
# "우회하지 않아도 lifecycle 이 완주한다" 는 시나리오(커스텀 기본 브랜치)를 만들 수 없다.
#
# 실행 브랜치명을 marker 에 한 줄씩 append 한다. 파일 존재 여부만으로는 판정할 수 없기
# 때문이다: promote 는 기본 브랜치의 metadata 커밋 다음에 fr 브랜치 승격 커밋을 한 번 더
# 만들고, 그 커밋은 우회 대상이 아니라 언제나 hook 을 실행한다. 어느 브랜치에서 hook 이
# 돌았는지를 기록해야 우회 여부를 정확히 읽을 수 있다.
install_marker_pre_commit() {  # install_marker_pre_commit <repo>
  cat > "$1/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
gd="$(git rev-parse --git-dir)"
branch=$(git symbolic-ref --short HEAD 2>/dev/null)
echo "ran:$branch" >> "$gd/.pre-commit-ran"
exit 0
HOOK
  chmod +x "$1/.git/hooks/pre-commit"
  rm -f "$1/.git/.pre-commit-ran"
}

marker_has() {  # marker_has <repo> <needle> — marker 파일에 needle 이 있으면 0
  [[ -f "$1/.git/.pre-commit-ran" ]] || return 1
  out_has "$2" < "$1/.git/.pre-commit-ran"
}

# 특정 경로에 대한 `git add` 만 실패시키는 wrapper. PATH 앞에 두고 쓴다.
# 실제 git 경로를 생성 시점에 박아 넣어 재귀 호출을 막는다.
mk_failing_git_wrapper() {  # mk_failing_git_wrapper <bindir> <실패시킬 경로 조각>
  local bindir="$1" needle="$2" real
  real="$(command -v git)"
  mkdir -p "$bindir"
  cat > "$bindir/git" <<WRAP
#!/bin/sh
if [ "\$1" = "add" ]; then
  for a in "\$@"; do
    case "\$a" in
      *${needle}*) echo "fake-git: add failed for \$a" >&2; exit 1 ;;
    esac
  done
fi
exec "${real}" "\$@"
WRAP
  chmod +x "$bindir/git"
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
# 미러 정합 (AC1·AC2): archive 후 CURRENT_TASK.md 가 baseline 전문과 바이트 단위로 일치해야 한다.
#   권위(task-state)만 reset 하고 미러를 두면 완료된 작업 내용이 진입점 문서에 남는다.
if ( cd "$REPO" && source rd-workflow/scripts/lifecycle/_lifecycle_common.sh >/dev/null 2>&1; \
     emit_current_task_baseline | diff -q - CURRENT_TASK.md >/dev/null 2>&1 ); then
  pass "archive: CURRENT_TASK.md 미러 baseline reset (전문 일치)"
else
  fail "archive: CURRENT_TASK.md 미러 stale 잔존"
fi
# 커밋 포함 (AC3 staging 보장): 워킹트리만 고치고 커밋을 빠뜨리면 다음 세션이 stale 을 다시 본다.
if ( cd "$REPO" && git status --porcelain CURRENT_TASK.md | grep -q . ); then
  fail "archive: CURRENT_TASK.md 변경이 커밋되지 않음"
else
  pass "archive: CURRENT_TASK.md 변경이 커밋에 포함됨"
fi
# 임시 파일 잔존 금지: 원자적 교체에 쓴 임시 파일이 남으면 다음 커밋에 섞여 들어간다.
if ( cd "$REPO" && ls CURRENT_TASK.md.baseline.* >/dev/null 2>&1 ); then
  fail "archive: baseline 임시 파일 잔존"
else
  pass "archive: baseline 임시 파일 정리됨"
fi

# archive 재실행 — fr branch 부재 + tag 존재 → success exit
# review-skip-audit.log가 untracked으로 생성될 수 있으므로 clean 트리를 보장하여 LC-20(멱등) 커버리지 복원
( cd "$REPO" && git clean -f rd-workflow-workspace/.lifecycle/review-skip-audit.log 2>/dev/null || true )
out="$(cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/test-foo --no-remote 2>&1 || true)"
[[ "$out" == *"이미 archive 완료"* ]] && pass "archive rerun: success exit (이미 완료)" || fail "archive rerun: $out"
# rerun(이미 완료)은 task-state를 건드리지 않는다 — baseline 유지 확인
( cd "$REPO" && grep -q "^short-title=-$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null && grep -q "^status=대기 중$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "archive rerun: task-state 불변 (baseline 유지)" || fail "archive rerun: task-state 변경됨"
# 재실행 시 미러도 baseline 을 유지해야 한다 (metadata_exists 거짓이라 블록을 건너뛰지만
# 첫 실행에서 이미 baseline 이 커밋됐으므로 결과가 달라지지 않는다).
if ( cd "$REPO" && source rd-workflow/scripts/lifecycle/_lifecycle_common.sh >/dev/null 2>&1; \
     emit_current_task_baseline | diff -q - CURRENT_TASK.md >/dev/null 2>&1 ); then
  pass "archive rerun: CURRENT_TASK.md baseline 유지"
else
  fail "archive rerun: CURRENT_TASK.md 변경됨"
fi

rm -rf "$REPO"

# === Scenario 1b: fr branch 가 이미 미러 baseline 을 커밋한 경우에도 archive 가 완료된다 ===
# 변경 전 절차는 archive content commit 에서 수동 reset 을 요구했으므로, 그 절차를 따른 FR·
# 재실행·복구 흐름에서는 merge 시점에 미러가 이미 baseline 이다. archive 가 다시 baseline 을
# 써도 HEAD 와 동일해 staged 변경이 없는데, 이를 실패로 판정하면 정상 경로가 막히고
# merge 가 끝난 뒤라 사용자가 수동 복구를 해야 한다 (final diff review turn 002 Finding 1).
echo "== scenario 1b: 이미 baseline 인 미러로 archive =="
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-pre --no-worktree --status "구현 중" >/dev/null
( cd "$REPO" && git switch fr/test-pre -q )
( cd "$REPO" && echo "# archived" > REQUEST.md )
( cd "$REPO" && source rd-workflow/scripts/lifecycle/_lifecycle_common.sh >/dev/null 2>&1; \
  emit_current_task_baseline > CURRENT_TASK.md )
( cd "$REPO" && git add REQUEST.md CURRENT_TASK.md && git commit -q -m "archive content (미러 baseline 포함)" )
if out="$( cd "$REPO" && git switch main -q && \
     bash rd-workflow/scripts/lifecycle/archive.sh --no-remote --force-skip-review-check "통합 테스트 fixture" 2>&1 )"; then
  pass "scenario 1b: 이미 baseline 인 미러에서 archive 성공"
else
  fail "scenario 1b: archive 실패 — $out"
fi
( cd "$REPO" && ! git rev-parse --verify fr/test-pre >/dev/null 2>&1 ) && pass "scenario 1b: branch 삭제" || fail "scenario 1b: branch 잔존"
if ( cd "$REPO" && source rd-workflow/scripts/lifecycle/_lifecycle_common.sh >/dev/null 2>&1; \
     emit_current_task_baseline | diff -q - CURRENT_TASK.md >/dev/null 2>&1 ); then
  pass "scenario 1b: 미러가 baseline 유지"
else
  fail "scenario 1b: 미러 baseline 아님"
fi

rm -rf "$REPO"

# === Scenario 1c: promote source-fr 해석 계약 ===
echo "== scenario 1c: promote source-fr 해석 계약 =="

# (1) 링크 표기 → canonical path 로 기록된다
REPO="$(setup_repo)"
mkdir -p "$REPO/rd-workflow-workspace/backlog/items"
: > "$REPO/rd-workflow-workspace/backlog/items/2026-08-12-alpha.md"
cat > "$REPO/REQUEST.md" <<'REQEOF'
# Change Request

## Source FR
[alpha](rd-workflow-workspace/backlog/items/2026-08-12-alpha.md)
REQEOF
( cd "$REPO" && git add -A && git commit -qm "test: sfr fixture" )
run_promote "$REPO" --short-title sfr-ok --no-worktree --status "구현 중" >/dev/null
( cd "$REPO" && git show main:rd-workflow-workspace/.lifecycle/task-state \
    | grep -q "source-fr=rd-workflow-workspace/backlog/items/2026-08-12-alpha.md" ) \
  && pass "promote sfr: 링크 표기 → canonical 기록" \
  || fail "promote sfr: 링크 표기 정규화 실패"

# (2) 해석 실패 → non-zero + 상태 완전 무변경
#     HEAD 만 비교하면 working tree 오염을 놓치므로 네 대상을 모두 비교한다.
#     파일 비교는 cmp -s 로 한다 — "$(cat f)" 문자열 비교는 명령 치환이
#     trailing newline 을 지워 줄바꿈만 달라진 변조를 놓친다.
REPO="$(setup_repo)"
mkdir -p "$REPO/rd-workflow-workspace/backlog/items"
cat > "$REPO/REQUEST.md" <<'REQEOF'
# Change Request

## Source FR
없는-항목-입니다
REQEOF
# CURRENT_TASK.md 를 실제 내용으로 둔다 — 부재 상태의 absent→absent 비교는
# "생성되지 않았다" 만 보이고 "기존 파일이 보존됐다" 는 못 본다.
cat > "$REPO/CURRENT_TASK.md" <<'CTEOF'
# Current Task

## Short Title
-

## Status
대기 중
CTEOF
( cd "$REPO" && git add -A && git commit -qm "test: sfr bad fixture" )

SFR_STATE="$REPO/rd-workflow-workspace/.lifecycle/task-state"
SFR_SNAP="$(mktemp -d)"    # repo 밖에 snapshot 을 둔다
before_head="$( cd "$REPO" && git rev-parse HEAD )"
before_status="$( cd "$REPO" && git status --porcelain )"
cp "$REPO/CURRENT_TASK.md" "$SFR_SNAP/CURRENT_TASK.md"
before_state_exists=0
if [[ -f "$SFR_STATE" ]]; then
  before_state_exists=1
  cp "$SFR_STATE" "$SFR_SNAP/task-state"
fi

# stdout 과 stderr 를 분리 캡처한다 — 교정 안내가 stderr 로 나가는지 검증해야 한다.
sfr_out="$(mktemp)"; sfr_err="$(mktemp)"
set +e
run_promote "$REPO" --short-title sfr-bad --no-worktree --status "구현 중" \
  >"$sfr_out" 2>"$sfr_err"
sfr_rc=$?
set -e

[[ "$sfr_rc" -ne 0 ]] && pass "promote sfr: 해석 실패 → non-zero" \
  || fail "promote sfr: 해석 실패인데 exit 0"
grep -q "없는-항목-입니다" "$sfr_err" \
  && pass "promote sfr: stderr 에 원문 값 포함" \
  || fail "promote sfr: stderr 에 원문 값 없음"
grep -q "rd-workflow-workspace/backlog/items/" "$sfr_err" \
  && pass "promote sfr: stderr 에 canonical 예시 포함" \
  || fail "promote sfr: stderr 에 canonical 예시 없음"
[[ ! -s "$sfr_out" ]] \
  && pass "promote sfr: 실패 시 stdout 비어 있음" \
  || fail "promote sfr: 실패인데 stdout 출력 있음"

( cd "$REPO" && [[ "$(git rev-parse HEAD)" == "$before_head" ]] ) \
  && pass "promote sfr: 실패 시 HEAD 불변" || fail "promote sfr: HEAD 이동함"
( cd "$REPO" && [[ "$(git status --porcelain)" == "$before_status" ]] ) \
  && pass "promote sfr: 실패 시 working tree 불변" || fail "promote sfr: working tree 오염"
cmp -s "$SFR_SNAP/CURRENT_TASK.md" "$REPO/CURRENT_TASK.md" \
  && pass "promote sfr: 실패 시 CURRENT_TASK.md byte 불변" \
  || fail "promote sfr: CURRENT_TASK.md 변경됨"
if [[ "$before_state_exists" -eq 1 ]]; then
  cmp -s "$SFR_SNAP/task-state" "$SFR_STATE" \
    && pass "promote sfr: 실패 시 task-state byte 불변" \
    || fail "promote sfr: task-state 변경됨"
else
  [[ ! -e "$SFR_STATE" ]] \
    && pass "promote sfr: 실패 시 task-state 미생성" \
    || fail "promote sfr: task-state 새로 생김"
fi
( cd "$REPO" && ! git rev-parse --verify fr/sfr-bad >/dev/null 2>&1 ) \
  && pass "promote sfr: 실패 시 브랜치 미생성" || fail "promote sfr: 브랜치 생김"
rm -rf "$sfr_out" "$sfr_err" "$SFR_SNAP"

# (2b) --dry-run 도 같은 판정을 낸다.
#      사전 점검이 성공을 알리고 실제 실행이 실패하면 신호가 반대가 되어 쓸모가 없다.
#      해석은 read-only 이므로 dry-run 조기 종료보다 먼저 수행할 수 있다.
DRY_SNAP="$(mktemp -d)"
cp "$REPO/CURRENT_TASK.md" "$DRY_SNAP/CURRENT_TASK.md"
dry_before_status="$( cd "$REPO" && git status --porcelain )"
dry_out="$(mktemp)"; dry_err="$(mktemp)"
set +e
run_promote "$REPO" --short-title sfr-dry --no-worktree --status "구현 중" --dry-run \
  >"$dry_out" 2>"$dry_err"
dry_rc=$?
set -e

[[ "$dry_rc" -ne 0 ]] && pass "promote sfr: dry-run 도 해석 실패 → non-zero" \
  || fail "promote sfr: dry-run 이 해석 실패를 통과시킴 (실제 실행과 반대 신호)"
grep -q "없는-항목-입니다" "$dry_err" \
  && pass "promote sfr: dry-run stderr 에 원문 값 포함" \
  || fail "promote sfr: dry-run stderr 에 원문 값 없음"
( cd "$REPO" && [[ "$(git status --porcelain)" == "$dry_before_status" ]] ) \
  && pass "promote sfr: dry-run 실패 시 working tree 불변" \
  || fail "promote sfr: dry-run 이 working tree 오염"
cmp -s "$DRY_SNAP/CURRENT_TASK.md" "$REPO/CURRENT_TASK.md" \
  && pass "promote sfr: dry-run 실패 시 CURRENT_TASK.md byte 불변" \
  || fail "promote sfr: dry-run 이 CURRENT_TASK.md 변경"
[[ ! -e "$SFR_STATE" ]] \
  && pass "promote sfr: dry-run 실패 시 task-state 미생성" \
  || fail "promote sfr: dry-run 이 task-state 생성"
( cd "$REPO" && ! git rev-parse --verify fr/sfr-dry >/dev/null 2>&1 ) \
  && pass "promote sfr: dry-run 실패 시 브랜치 미생성" \
  || fail "promote sfr: dry-run 이 브랜치 생성"
rm -rf "$dry_out" "$dry_err" "$DRY_SNAP"

# (3) REQUEST 를 고치면 재실행으로 정상 진행한다
: > "$REPO/rd-workflow-workspace/backlog/items/2026-08-12-beta.md"
cat > "$REPO/REQUEST.md" <<'REQEOF'
# Change Request

## Source FR
rd-workflow-workspace/backlog/items/2026-08-12-beta.md
REQEOF
( cd "$REPO" && git add -A && git commit -qm "test: sfr 교정" )
# 해석을 dry-run 앞으로 옮긴 뒤에도 정상 값의 dry-run 은 그대로 통과해야 한다.
run_promote "$REPO" --short-title sfr-bad --no-worktree --status "구현 중" --dry-run >/dev/null \
  && pass "promote sfr: 정상 값 dry-run 통과" || fail "promote sfr: 정상 값인데 dry-run 실패"
( cd "$REPO" && ! git rev-parse --verify fr/sfr-bad >/dev/null 2>&1 ) \
  && pass "promote sfr: 정상 값 dry-run 은 브랜치를 만들지 않음" \
  || fail "promote sfr: dry-run 이 브랜치 생성"
run_promote "$REPO" --short-title sfr-bad --no-worktree --status "구현 중" >/dev/null \
  && pass "promote sfr: 교정 후 재실행 성공" || fail "promote sfr: 교정 후에도 실패"

# (4) 명시 인자가 REQUEST 추론보다 우선한다
REPO="$(setup_repo)"
mkdir -p "$REPO/rd-workflow-workspace/backlog/items"
: > "$REPO/rd-workflow-workspace/backlog/items/2026-08-12-alpha.md"
: > "$REPO/rd-workflow-workspace/backlog/items/2026-08-12-gamma.md"
cat > "$REPO/REQUEST.md" <<'REQEOF'
# Change Request

## Source FR
[alpha](rd-workflow-workspace/backlog/items/2026-08-12-alpha.md)
REQEOF
( cd "$REPO" && git add -A && git commit -qm "test: sfr 우선순위 fixture" )
run_promote "$REPO" --short-title sfr-pri --no-worktree --status "구현 중" \
  --source-fr "rd-workflow-workspace/backlog/items/2026-08-12-gamma.md" >/dev/null
( cd "$REPO" && git show main:rd-workflow-workspace/.lifecycle/task-state \
    | grep -q "source-fr=rd-workflow-workspace/backlog/items/2026-08-12-gamma.md" ) \
  && pass "promote sfr: 명시 인자 우선" || fail "promote sfr: 우선순위 역전"

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

# ---- 차단 pre-commit hook 하에서 lifecycle 이 커밋까지 완료하는가 ----
# 통제군(--no-verify 없는 커밋이 실제로 차단되는지)을 먼저 증명한다.
# 이 단계가 없으면 hook 이 실행되지 않는 환경에서도 본 검증이 통과해 회귀 고정 능력을 잃는다.
for _br in main master; do
  # (a) 브랜치별 통제군 1회 — fixture 의 hook 이 실제로 실행되는지 직접 증명한다.
  #     rc != 0 만 보면 다른 git 오류와 구분되지 않으므로 marker 파일과 고유 문구를 함께 본다.
  REPO="$(setup_repo "$_br")"
  install_blocking_pre_commit "$REPO"
  ctl_rc=0
  ctl_err="$( cd "$REPO" && echo ctl > ctl.txt && git add ctl.txt \
      && git commit -q -m "control" 2>&1 )" || ctl_rc=$?
  [[ "$ctl_rc" -ne 0 ]] \
    && pass "hook-block/$_br 통제군: 커밋 차단 (rc=$ctl_rc)" \
    || fail "hook-block/$_br 통제군: 차단되지 않음 — hook 미실행 의심"
  [[ -f "$REPO/.git/.pre-commit-ran" ]] \
    && pass "hook-block/$_br 통제군: hook 실행 marker 확인" \
    || fail "hook-block/$_br 통제군: hook 이 실행되지 않음 (marker 부재)"
  printf '%s' "$ctl_err" | out_has "RD-TEST-HOOK-BLOCKED" \
    && pass "hook-block/$_br 통제군: 차단 사유가 hook 임을 확인" \
    || fail "hook-block/$_br 통제군: 실패 원인이 hook 이 아님 — $ctl_err"
  ( cd "$REPO" && git reset -q )

  # (b) promote
  prc=0
  run_promote "$REPO" --short-title test-hb --no-worktree >/dev/null 2>&1 || prc=$?
  [[ "$prc" -eq 0 ]] \
    && pass "hook-block/$_br promote: exit 0" || fail "hook-block/$_br promote: exit=$prc"
  ( cd "$REPO" && git log "$_br" --oneline -20 | out_has "promote test-hb metadata 기록" ) \
    && pass "hook-block/$_br promote: metadata 커밋이 HEAD 이력에 반영" \
    || fail "hook-block/$_br promote: metadata 커밋 부재"
  rm -rf "$REPO"

  # (c) promote_rollback
  REPO="$(setup_repo "$_br")"
  run_promote "$REPO" --short-title test-hbr --no-worktree >/dev/null 2>&1
  install_blocking_pre_commit "$REPO"
  ( cd "$REPO" && git switch "$_br" -q )
  rrc=0
  ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh ) >/dev/null 2>&1 || rrc=$?
  [[ "$rrc" -eq 0 ]] \
    && pass "hook-block/$_br rollback: exit 0" || fail "hook-block/$_br rollback: exit=$rrc"
  ( cd "$REPO" && git log "$_br" --oneline -20 | out_has "rollback 완료" ) \
    && pass "hook-block/$_br rollback: 커밋이 HEAD 이력에 반영" \
    || fail "hook-block/$_br rollback: 커밋 부재"
  rm -rf "$REPO"

  # (d) archive
  REPO="$(setup_repo "$_br")"
  BAREHB="$(mk_bare "hb-$_br")"
  ( cd "$REPO" && git remote add origin "$BAREHB" && git push -q origin "$_br" )
  run_promote "$REPO" --short-title test-hba --no-worktree >/dev/null 2>&1
  ( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
  ( cd "$REPO" && git switch "$_br" -q )
  install_blocking_pre_commit "$REPO"
  arc=0
  ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
      --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || arc=$?
  [[ "$arc" -eq 0 ]] \
    && pass "hook-block/$_br archive: exit 0" || fail "hook-block/$_br archive: exit=$arc"
  # AC5 직접 oracle — 기대 커밋이 기본 브랜치 이력에 실제로 존재하는지 본다.
  # tag 생성은 커밋 이후 단계 도달을 보는 간접 신호일 뿐이라 이것을 대체하지 못한다.
  ( cd "$REPO" && git log "$_br" --oneline -20 | out_has "archive test-hba metadata 정리" ) \
    && pass "hook-block/$_br archive: metadata 정리 커밋이 기본 브랜치 이력에 반영" \
    || fail "hook-block/$_br archive: metadata 정리 커밋 부재"
  [[ -n "$( cd "$REPO" && git tag --list "fr/*/test-hba" )" ]] \
    && pass "hook-block/$_br archive: tag 생성 (후속 단계 oracle)" \
    || fail "hook-block/$_br archive: tag 부재 — 커밋 이후 단계 미도달"
  rm -rf "$REPO" "$BAREHB"
done

# ---- hook 우회는 hook 이 실제로 차단하는 브랜치에서만 일어나는가 ----
# Claude Code 설치 hook 은 브랜치명이 main|master 일 때만 커밋을 막는다. workflow.json 의
# default_branch 로 trunk 같은 커스텀 기본 브랜치를 쓰는 프로젝트에서는 막히지 않으므로
# --no-verify 를 붙일 이유가 없고, 붙이면 소비 프로젝트의 pre-commit·commit-msg 검증만
# 불필요하게 줄어든다.
#
# promote 한 경로로만 검증한다 — 세 지점(promote·promote_rollback·archive)이 모두 같은
# lifecycle_needs_hook_bypass 판정을 쓰므로 브랜치 조건은 공통이고, promote 가 fixture
# 준비(bare remote·archive content 불필요)가 가장 단순해 조건 자체를 가장 좁게 고정한다.
#
# trunk 와 main 을 짝으로 둔다. 한쪽만 보면 "우회 안내가 없다" 가 우회를 안 해서인지
# 안내 지점에 도달하지 못해서인지 구분되지 않아 판정이 성립하지 않는다.

# (a) trunk — 우회하지 않는다
REPO="$(setup_repo trunk)"
( cd "$REPO" && mkdir -p rd-workflow/config \
  && printf '{"default_branch": "trunk"}\n' > rd-workflow/config/workflow.json \
  && git add -A && git commit -q -m "config" )
install_marker_pre_commit "$REPO"
nbt_rc=0
nbt_out="$( run_promote "$REPO" --short-title test-nbt --no-worktree 2>&1 )" || nbt_rc=$?
[[ "$nbt_rc" -eq 0 ]] \
  && pass "hook-cond/trunk: promote rc=0" || fail "hook-cond/trunk: rc=$nbt_rc — $nbt_out"
marker_has "$REPO" "ran:trunk" \
  && pass "hook-cond/trunk: 기본 브랜치 커밋에서 hook 실행됨 (우회 안 함)" \
  || fail "hook-cond/trunk: hook 미실행 — 차단 대상이 아닌 브랜치를 우회함"
printf '%s' "$nbt_out" | out_has "hook 을 건너뛰고 커밋했습니다" \
  && fail "hook-cond/trunk: 우회하지 않았는데 우회 안내가 출력됨" \
  || pass "hook-cond/trunk: 우회 안내 없음"
rm -rf "$REPO"

# (b) main — 우회한다 (대조군)
REPO="$(setup_repo main)"
install_marker_pre_commit "$REPO"
nbm_rc=0
nbm_out="$( run_promote "$REPO" --short-title test-nbm --no-worktree 2>&1 )" || nbm_rc=$?
[[ "$nbm_rc" -eq 0 ]] \
  && pass "hook-cond/main: promote rc=0" || fail "hook-cond/main: rc=$nbm_rc — $nbm_out"
marker_has "$REPO" "ran:main" \
  && fail "hook-cond/main: 차단 대상 브랜치인데 hook 이 실행됨 (우회 실패)" \
  || pass "hook-cond/main: 기본 브랜치 커밋에서 hook 미실행 (우회함)"
# hook 이 애초에 설치·동작하지 않아서 marker 가 비었을 가능성을 같은 실행 안에서 배제한다.
# fr 브랜치 승격 커밋은 우회 대상이 아니므로 반드시 hook 을 실행한다.
marker_has "$REPO" "ran:fr/test-nbm" \
  && pass "hook-cond/main: 비우회 커밋에서는 hook 실행됨 (hook 동작 확인)" \
  || fail "hook-cond/main: hook 자체가 동작하지 않음 — 위 판정이 무의미"
printf '%s' "$nbm_out" | out_has "hook 을 건너뛰고 커밋했습니다" \
  && pass "hook-cond/main: 우회 안내 출력" || fail "hook-cond/main: 우회 안내 누락 — $nbm_out"
rm -rf "$REPO"

# ---- 사용자의 무관한 staged 변경이 lifecycle 우회 커밋에 딸려가지 않는가 ----
# 각 케이스는 rc·기대 커밋 생성·사용자 파일 제외·index 보존·안내를 동일 실행에서 확인한다.

# (a) promote
REPO="$(setup_repo)"
install_blocking_pre_commit "$REPO"
( cd "$REPO" && mkdir -p src && echo "user work" > src/app.js && git add src/app.js )
sp_rc=0
sp_out="$( run_promote "$REPO" --short-title test-stgp --no-worktree 2>&1 )" || sp_rc=$?
[[ "$sp_rc" -eq 0 ]] \
  && pass "staged/promote: rc=0" || fail "staged/promote: rc=$sp_rc — $sp_out"
( cd "$REPO" && git log main --oneline -10 | out_has "promote test-stgp metadata 기록" ) \
  && pass "staged/promote: lifecycle 커밋 생성" || fail "staged/promote: lifecycle 커밋 부재"
( cd "$REPO" && git log main -1 --name-only --format= | out_has "src/app.js" ) \
  && fail "staged/promote: 사용자 파일이 lifecycle 커밋에 포함됨" \
  || pass "staged/promote: 사용자 파일이 커밋에서 제외됨"
# index 보존은 promote 실행 "전체" 기준이다 — metadata 우회 커밋만이 아니라 그 뒤에 이어지는
# fr 브랜치 승격 커밋(CURRENT_TASK.md 갱신)까지 경로 한정이라야 참이 된다. 둘 중 하나라도
# pathspec 을 잃으면 남아 있던 staged src/app.js 가 흡수되어 이 assertion 이 실패한다.
( cd "$REPO" && git diff --cached --name-only | out_has "src/app.js" ) \
  && pass "staged/promote: 사용자 staged 상태 보존" || fail "staged/promote: 사용자 staged 소실"
printf '%s' "$sp_out" | out_has "commit-msg" \
  && pass "staged/promote: 우회 범위 특정 안내" || fail "staged/promote: 안내 누락 — $sp_out"
rm -rf "$REPO"

# (b) promote_rollback
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-stgr --no-worktree >/dev/null 2>&1
( cd "$REPO" && git switch main -q )
install_blocking_pre_commit "$REPO"
( cd "$REPO" && mkdir -p src && echo "user work" > src/app.js && git add src/app.js )
sr_rc=0
sr_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh 2>&1 )" || sr_rc=$?
[[ "$sr_rc" -eq 0 ]] \
  && pass "staged/rollback: rc=0" || fail "staged/rollback: rc=$sr_rc — $sr_out"
( cd "$REPO" && git log main --oneline -10 | out_has "rollback 완료" ) \
  && pass "staged/rollback: lifecycle 커밋 생성" || fail "staged/rollback: lifecycle 커밋 부재"
( cd "$REPO" && git log main -1 --name-only --format= | out_has "src/app.js" ) \
  && fail "staged/rollback: 사용자 파일이 lifecycle 커밋에 포함됨" \
  || pass "staged/rollback: 사용자 파일이 커밋에서 제외됨"
( cd "$REPO" && git diff --cached --name-only | out_has "src/app.js" ) \
  && pass "staged/rollback: 사용자 staged 상태 보존" || fail "staged/rollback: 사용자 staged 소실"
printf '%s' "$sr_out" | out_has "commit-msg" \
  && pass "staged/rollback: 우회 범위 특정 안내" || fail "staged/rollback: 안내 누락 — $sr_out"
rm -rf "$REPO"

# (c) archive
REPO="$(setup_repo)"
BARESA="$(mk_bare stga)"
( cd "$REPO" && git remote add origin "$BARESA" && git push -q origin main )
run_promote "$REPO" --short-title test-stga --no-worktree >/dev/null 2>&1
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
install_blocking_pre_commit "$REPO"
( cd "$REPO" && mkdir -p src && echo "user work" > src/app.js && git add src/app.js )
sa_rc=0
# archive.sh Step 0 의 ensure_worktree_clean 은 무관 staged 만 있어도 기본 경로에서
# rc=1 로 막는다(REQUEST.md 41행이 지목하는 위험 경로). --force-dirty 로 그 gate 는
# 우회할 수 있지만, archive 는 세 경로(promote/promote_rollback/archive) 중 유일하게
# metadata cleanup 커밋보다 먼저 `git merge --no-ff "$FR_BRANCH"`(archive.sh:105)를
# 실행한다. git merge 는 index 가 dirty 하면 거부하므로(실측 오류: "Your local changes
# to the following files would be overwritten by merge"), --force-dirty 를 줘도
# archive 는 metadata cleanup 커밋에 도달하지 못하고 merge 단계에서 중단된다.
#
# **2026-08-20 갱신**: 중단 지점이 앞당겨졌다. 이제 merge 보다 먼저 Step 2.5 의 증명 전제
# 확인이 막는다(final diff review turn 004 Finding 1) — dirty 상태에서 merge 를 만들어 두면
# 그 merge 가 main 에 남아, 사용자가 main 에서 고쳐 재실행할 때 예전 fr tip 리뷰만으로
# 발행되는 경로가 열리기 때문이다. 보호는 약해지지 않고 **더 앞에서** 작동한다.
# 아래 oracle 도 그에 맞춰 새 중단 사유를 확인한다 — rc!=0 만 보면 archive 가 다른 이유로
# 실패해도 통과해 통제군보다 약한 oracle 이 된다.
# ensure_worktree_clean·merge 순서 둘 다 사용자를 보호하는 기존 동작이므로 완화하지 않는다.
# LC_ALL=C 고정: 아래 oracle 이 git 의 영문 오류 메시지를 판정에 쓰므로,
# 번역 locale 환경에서 거짓 실패하지 않도록 실행 locale 을 못박는다.
sa_out="$( cd "$REPO" && LC_ALL=C bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-dirty --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || sa_rc=$?
# 중단 사유까지 확인한다 — rc != 0 만 보면 archive 가 다른 이유로 실패해도 통과해
# 통제군보다 약한 oracle 이 된다.
[[ "$sa_rc" -ne 0 ]] && printf '%s' "$sa_out" | out_has "merge 전에 중단했습니다" \
  && printf '%s' "$sa_out" | out_has "커밋되지 않은 변경이 있어" \
  && pass "staged/archive: 무관 staged 상태에서 merge **이전** 중단 (rc=$sa_rc)" \
  || fail "staged/archive: merge 이전 중단이 아님 (rc=$sa_rc) — $sa_out"
( cd "$REPO" && git log --all --oneline | out_has "archive test-stga metadata 정리" ) \
  && fail "staged/archive: 중단됐는데 metadata 정리 커밋이 생성됨" \
  || pass "staged/archive: lifecycle 커밋 미생성"
( cd "$REPO" && git log --all --name-only --format= | out_has "src/app.js" ) \
  && fail "staged/archive: 사용자 파일이 lifecycle 커밋에 포함됨" \
  || pass "staged/archive: 사용자 파일이 커밋에서 제외됨"
( cd "$REPO" && git diff --cached --name-only | out_has "src/app.js" ) \
  && pass "staged/archive: 사용자 staged 상태 보존" || fail "staged/archive: 사용자 staged 소실"
rm -rf "$REPO" "$BARESA"

# (d) archive — merge skip 경로 (archive.sh:102-104)
# (c) 는 merge 가 무관 staged 를 막는 경로를, 이 케이스는 merge 를 건너뛰어 metadata
# cleanup 커밋에 실제로 도달하는 경로를 고정한다. 두 케이스는 서로 다른 사실을 지킨다.
# 재현 조건: 사용자가 fr 을 먼저 수동 merge 했거나, 이전 archive 실행이 merge 직후
# 실패해 재실행하는 상황 — 그때 fr 은 이미 HEAD 의 ancestor 라 merge 가 skip 된다.
REPO="$(setup_repo)"
BAREMS="$(mk_bare mskip)"
( cd "$REPO" && git remote add origin "$BAREMS" && git push -q origin main )
run_promote "$REPO" --short-title test-mskip --no-worktree >/dev/null 2>&1
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
# 선행 수동 merge — 이것이 archive.sh 의 merge skip 분기를 트리거한다.
( cd "$REPO" && git merge --no-ff fr/test-mskip -m "manual merge" -q )
install_blocking_pre_commit "$REPO"
# 이 케이스가 지키려는 성질은 **`_lc_paths` 경로 한정**이다 — lifecycle 커밋에 무관한
# staged 파일이 섞이지 않는가. 어떤 파일을 staged 로 두는가는 그 성질을 관측하기 위한
# 수단이며, 수단은 증명 집합 **밖**(transient)이어야 한다.
#
# 원래는 `src/app.js` 였다. self-test-runtime-reduction Task 8b 에서 archive 전 전수 검증
# 게이트가 "워킹트리 = HEAD(증명 범위)" 를 요구하게 되어(change spec §5.5 · Task 8 리뷰 §4),
# 증명 집합 안의 파일이 커밋되지 않은 채 staged 이면 게이트가 정상적으로 차단한다
# (게이트가 증명하는 것은 워킹트리이고 tag·push 로 발행되는 것은 HEAD 이므로, 갈라진 채
# 통과하면 검증하지 않은 내용이 발행된다). 그 차단은 의도된 동작이므로 완화하지 않고,
# 대신 vehicle 을 `smoke_proof_exclude` 가 제외하는 transient 파일로 바꿨다.
# 이 파일은 `_lc_paths`(task-state · CURRENT_TASK.md)에 없으므로 경로 한정 관측력은 그대로다.
#
# 순서 주의: 반대 방향(증명 집합 안 staged → 게이트 차단)을 **먼저** 확인한다. 성공
# 아카이브가 끝나면 fr branch 와 metadata 가 정리되어 재실행은 게이트에 도달하지 못한다
# (rerun 안전망이 먼저 응답한다) — 뒤에 두면 rc 만 맞고 사유가 다른 거짓 통과가 된다.
( cd "$REPO" && mkdir -p src && echo "user work" > src/app.js && git add src/app.js )
ms_rc2=0
ms_out2="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-dirty --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || ms_rc2=$?
[[ "$ms_rc2" -ne 0 ]] && printf '%s' "$ms_out2" | out_has "발행 대상" \
  && pass "staged/archive-mergeskip: 증명 집합 안 staged 는 게이트가 차단 (rc=$ms_rc2)" \
  || fail "staged/archive-mergeskip: 증명 집합 안 staged 를 통과시켰다 (rc=$ms_rc2) — $ms_out2"
( cd "$REPO" && git rm -q --cached src/app.js >/dev/null 2>&1; rm -rf src )

MS_UNREL="rd-workflow-workspace/.lifecycle/unrelated_zzfx.log"
( cd "$REPO" && echo "user work" > "$MS_UNREL" && git add "$MS_UNREL" )
ms_rc=0
ms_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-dirty --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || ms_rc=$?
[[ "$ms_rc" -eq 0 ]] \
  && pass "staged/archive-mergeskip: rc=0" || fail "staged/archive-mergeskip: rc=$ms_rc — $ms_out"
( cd "$REPO" && git log main --oneline -10 | out_has "archive test-mskip metadata 정리" ) \
  && pass "staged/archive-mergeskip: lifecycle 커밋 생성" \
  || fail "staged/archive-mergeskip: lifecycle 커밋 부재 — $ms_out"
( cd "$REPO" && git log main -1 --name-only --format= | out_has "$MS_UNREL" ) \
  && fail "staged/archive-mergeskip: 무관 staged 파일이 lifecycle 커밋에 포함됨" \
  || pass "staged/archive-mergeskip: 무관 staged 파일이 커밋에서 제외됨"
( cd "$REPO" && git diff --cached --name-only | out_has "$MS_UNREL" ) \
  && pass "staged/archive-mergeskip: 무관 staged 상태 보존" \
  || fail "staged/archive-mergeskip: 무관 staged 소실"
printf '%s' "$ms_out" | out_has "commit-msg" \
  && pass "staged/archive-mergeskip: 우회 범위 특정 안내" \
  || fail "staged/archive-mergeskip: 안내 누락 — $ms_out"
rm -rf "$REPO" "$BAREMS"

# ---- lifecycle 대상 변경이 없고 무관 staged 만 있을 때 lifecycle 커밋이 생기지 않는가 ----
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-neg --no-worktree >/dev/null 2>&1
( cd "$REPO" && git switch main -q )
# 준비 실행 — rc 를 반드시 확인한다. 여기서 실패하면 이후 assertion 이 무의미하다.
prep_rc=0
prep_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh 2>&1 )" || prep_rc=$?
[[ "$prep_rc" -eq 0 ]] \
  && pass "negative: 준비 rollback rc=0" || fail "negative: 준비 rollback rc=$prep_rc — $prep_out"
neg_before="$( cd "$REPO" && git rev-parse main )"
install_blocking_pre_commit "$REPO"
( cd "$REPO" && mkdir -p src && echo "user work" > src/app.js && git add src/app.js )
# 2회차는 --fr-branch 명시가 필수다 (metadata 는 1회차에서 정리되었다).
neg_rc=0
neg_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh \
    --fr-branch fr/test-neg 2>&1 )" || neg_rc=$?
neg_after="$( cd "$REPO" && git rev-parse main )"
[[ "$neg_rc" -eq 0 ]] \
  && pass "negative: 2회차 rollback rc=0 (판정 지점 도달)" \
  || fail "negative: 2회차 rollback rc=$neg_rc — 판정 이전 종료 의심: $neg_out"
[[ "$neg_before" == "$neg_after" ]] \
  && pass "negative: 대상 변경 없음 → lifecycle 커밋 미생성" \
  || fail "negative: 무관 staged 만으로 lifecycle 커밋이 생김 (판정 범위 축소 누락)"
( cd "$REPO" && git diff --cached --name-only | out_has "src/app.js" ) \
  && pass "negative: 사용자 staged 보존" || fail "negative: 사용자 staged 소실"
rm -rf "$REPO"

# ---- tracked legacy active-fr 의 삭제가 경로 한정 커밋으로 기록되는가 ----
REPO="$(setup_repo)"
BARELG="$(mk_bare legacy)"
( cd "$REPO" && git remote add origin "$BARELG" && git push -q origin main )
run_promote "$REPO" --short-title test-legacy --no-worktree >/dev/null 2>&1
# promote 직후 현재 브랜치는 fr 이다 — 여기서 legacy 파일을 tracked 로 만든다
( cd "$REPO" && mkdir -p rd-workflow-workspace/.lifecycle \
    && echo "test-legacy" > rd-workflow-workspace/.lifecycle/active-fr \
    && git add rd-workflow-workspace/.lifecycle/active-fr \
    && git commit -q -m "legacy active-fr fixture" )
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
install_blocking_pre_commit "$REPO"
lg_rc=0
lg_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || lg_rc=$?
[[ "$lg_rc" -eq 0 ]] \
  && pass "legacy: archive rc=0" || fail "legacy: archive rc=$lg_rc — $lg_out"
( cd "$REPO" && git log main -1 --diff-filter=D --name-only --format= | out_has "active-fr" ) \
  && pass "legacy: active-fr 삭제가 lifecycle 커밋에 기록됨" \
  || fail "legacy: 삭제 미기록 — partial commit 의 삭제분 전제 위반"
rm -rf "$REPO" "$BARELG"

# ---- 필수 경로의 git add 실패 시 lifecycle 이 중단되는가 ----
# (a) rollback 필수 경로
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-addfail --no-worktree >/dev/null 2>&1
( cd "$REPO" && git switch main -q )
WRAPBIN="$(mktemp -d)"
mk_failing_git_wrapper "$WRAPBIN" "CURRENT_TASK.md"
af_rc=0
af_out="$( cd "$REPO" && PATH="$WRAPBIN:$PATH" \
    bash rd-workflow/scripts/lifecycle/promote_rollback.sh 2>&1 )" || af_rc=$?
[[ "$af_rc" -ne 0 ]] \
  && pass "add-fail/rollback: staging 실패 시 중단 (rc=$af_rc)" \
  || fail "add-fail/rollback: staging 실패를 무시하고 계속 진행함"
printf '%s' "$af_out" | out_has "staging 실패" \
  && pass "add-fail/rollback: 중단 사유 안내" || fail "add-fail/rollback: 사유 안내 누락 — $af_out"
( cd "$REPO" && git log main --oneline -5 | out_has "rollback 완료" ) \
  && fail "add-fail/rollback: 중단됐는데 lifecycle 커밋이 생성됨" \
  || pass "add-fail/rollback: lifecycle 커밋 미생성"
rm -rf "$REPO" "$WRAPBIN"

# (b) archive 의 tracked legacy 경로
REPO="$(setup_repo)"
BAREAF="$(mk_bare addfail)"
( cd "$REPO" && git remote add origin "$BAREAF" && git push -q origin main )
run_promote "$REPO" --short-title test-addfail2 --no-worktree >/dev/null 2>&1
( cd "$REPO" && mkdir -p rd-workflow-workspace/.lifecycle \
    && echo "test-addfail2" > rd-workflow-workspace/.lifecycle/active-fr \
    && git add rd-workflow-workspace/.lifecycle/active-fr \
    && git commit -q -m "legacy active-fr fixture" )
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
WRAPBIN2="$(mktemp -d)"
mk_failing_git_wrapper "$WRAPBIN2" "active-fr"
# archive 는 중단 전에 merge 를 수행할 수 있으므로 "local HEAD 불변" 으로 판정하면 안 된다.
# 금지 대상은 cleanup 커밋 생성과 remote 부수효과 두 가지다 — 각각 따로 본다.
remote_before="$( git --git-dir="$BAREAF" rev-parse main 2>/dev/null || echo none )"
af2_rc=0
af2_out="$( cd "$REPO" && PATH="$WRAPBIN2:$PATH" \
    bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || af2_rc=$?
[[ "$af2_rc" -ne 0 ]] \
  && pass "add-fail/archive: legacy staging 실패 시 중단 (rc=$af2_rc)" \
  || fail "add-fail/archive: legacy staging 실패를 무시하고 계속 진행함"
printf '%s' "$af2_out" | out_has "staging 실패" \
  && pass "add-fail/archive: 중단 사유 안내" || fail "add-fail/archive: 사유 안내 누락 — $af2_out"
( cd "$REPO" && git log --all --oneline | out_has "archive test-addfail2 metadata 정리" ) \
  && fail "add-fail/archive: 중단됐는데 metadata cleanup 커밋이 생성됨" \
  || pass "add-fail/archive: cleanup 커밋 미생성"
[[ -n "$( cd "$REPO" && git tag --list "fr/*/test-addfail2" )" ]] \
  && fail "add-fail/archive: 중단됐는데 tag 가 생성됨 (후속 단계 실행)" \
  || pass "add-fail/archive: 후속 tag 단계 미실행"
remote_after="$( git --git-dir="$BAREAF" rev-parse main 2>/dev/null || echo none )"
[[ "$remote_before" == "$remote_after" ]] \
  && pass "add-fail/archive: remote ref 불변 (push 부수효과 없음)" \
  || fail "add-fail/archive: 중단됐는데 remote 가 갱신됨 ($remote_before → $remote_after)"
rm -rf "$REPO" "$BAREAF" "$WRAPBIN2"

# === Scenario: 전수 검증 전제/실패 시 main HEAD 전이 (final diff review 2026-08-20 turn 004) ===
#
# 닫으려는 경로: merge 는 됐는데 전수 검증이 막히고 main 이 merge 된 채 남으면, 사용자가
# 그 main 에서 고쳐 커밋하고 재실행할 때 **예전 fr tip 리뷰만으로 그 커밋이 발행**됩니다.
# 소스 토큰 검사(test_lifecycle.sh)로는 이 상태 전이를 못 봅니다 — 여기서 실제로 잽니다.
echo "== scenario: archive 전수 검증 실패 시 main HEAD 전이 =="

# --- (a) proof 대상 dirty + --force-dirty: merge 전에 막혀 main 이 움직이면 안 된다 ---
# `--force-dirty` 는 clean 검사를 넘기는 **지원되는 정상 호출**이라, 여기서 main 이 전진하면
# 위 우회 경로가 정상 사용 중에 열립니다.
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-dirtyarch --no-worktree --status "구현 중" >/dev/null
( cd "$REPO" && git switch fr/test-dirtyarch -q \
  && echo "# archived" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
  && git switch main -q )
main_before="$( cd "$REPO" && git rev-parse HEAD )"
( cd "$REPO" && printf '\n## dirty\n' >> CURRENT_TASK.md )
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote --force-dirty \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 \
  && fail "force-dirty/archive: 증명 전제가 깨졌는데 rc 0" \
  || pass "force-dirty/archive: 증명 전제 위반 차단"
main_after="$( cd "$REPO" && git rev-parse HEAD )"
[[ "$main_before" == "$main_after" ]] \
  && pass "force-dirty/archive: main HEAD 불변 (merge 전 차단)" \
  || fail "force-dirty/archive: main 이 전진함 ($main_before → $main_after) — 미리뷰 커밋 발행 경로가 열린다"
( cd "$REPO" && git rev-parse --verify fr/test-dirtyarch >/dev/null 2>&1 ) \
  && pass "force-dirty/archive: fr branch 보존 (고칠 곳이 남아 있다)" \
  || fail "force-dirty/archive: fr branch 소실"
rm -rf "$REPO"

# --- (b) clean 상태에서 전수 검증 자체가 실패: 이 실행이 만든 merge 를 되돌려야 한다 ---
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-failarch --no-worktree --status "구현 중" >/dev/null
( cd "$REPO" && git switch fr/test-failarch -q \
  && echo "# archived" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
  && git switch main -q )
# 전수 검증이 실패하는 대역으로 교체하고 **커밋**한다 (워킹트리를 clean 으로 유지해야
# 전제 확인을 통과해 merge 까지 간다 — 되돌림 경로를 타게 하는 것이 이 케이스의 목적).
( cd "$REPO" && printf '#!/usr/bin/env bash\nexit 1\n' > rd-workflow/scripts/self_test.sh \
  && git add rd-workflow/scripts/self_test.sh && git commit -q -m "failing selftest stub" )
main_before="$( cd "$REPO" && git rev-parse HEAD )"
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 \
  && fail "fail-selftest/archive: 전수 검증이 실패했는데 rc 0" \
  || pass "fail-selftest/archive: 전수 검증 실패 차단"
main_after="$( cd "$REPO" && git rev-parse HEAD )"
[[ "$main_before" == "$main_after" ]] \
  && pass "fail-selftest/archive: merge 되돌림으로 main HEAD 복귀" \
  || fail "fail-selftest/archive: merge 가 main 에 남음 ($main_before → $main_after) — main 직접 수정이 리뷰를 우회한다"
( cd "$REPO" && git rev-parse --verify fr/test-failarch >/dev/null 2>&1 ) \
  && pass "fail-selftest/archive: fr branch 보존" \
  || fail "fail-selftest/archive: fr branch 소실"
[[ -z "$( cd "$REPO" && git tag --list "fr/*/test-failarch" )" ]] \
  && pass "fail-selftest/archive: tag 미생성" \
  || fail "fail-selftest/archive: 중단됐는데 tag 생성됨"
# tracked 기준으로 봅니다 — 아카이브가 스스로 만드는 untracked 산출물(audit log 등)은
# 증명 대상이 아니고, 되돌림도 그것을 지우지 않습니다.
[[ -z "$( cd "$REPO" && git status --porcelain --untracked-files=no )" ]] \
  && pass "fail-selftest/archive: 되돌림 후 tracked 변경 없음" \
  || fail "fail-selftest/archive: 되돌림이 tracked 파일을 더럽혔다"
rm -rf "$REPO"

# --- (c) 하위 디렉터리 호출은 merge 이전에 거부된다 (실제 동작 고정) ---
# turn 006 이 "nested 호출에서 rollback clean 판정이 저장소 전체를 못 본다" 를 지적했다.
# 판정 범위 문제 자체는 사실이라 `git -C "$CURRENT_WT"` 로 고쳤지만, **그 경로는 현재
# 도달 불가**다 — `_state_common.sh` 의 TASK_STATE_PATH 가 `${project_root:-$PWD}` 로
# 해석되는데 archive.sh 는 그 파일을 source 한 **뒤에** project_root 를 채우므로, nested
# 호출은 metadata 를 못 찾고 `active fr 없음` 으로 merge 훨씬 전에 끝난다.
# 여기서는 그 **실제 동작**을 고정한다: nested 호출이 아무것도 건드리지 않고 거부되는 것.
# 이 단언이 깨지면(= nested 호출이 진행되면) rollback 판정 범위가 즉시 실제 위험이 되므로,
# 그때 FR `archive-cwd-dependent-state-path` 의 처방을 함께 넣어야 한다.
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-nested --no-worktree --status "구현 중" >/dev/null
( cd "$REPO" && git switch fr/test-nested -q \
  && echo "# archived" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
  && git switch main -q )
main_before="$( cd "$REPO" && git rev-parse HEAD )"
nst_out="$( cd "$REPO/rd-workflow/scripts/lifecycle" && bash ./archive.sh --no-remote \
    --force-skip-review-check "통합 테스트 fixture" 2>&1 )" \
  && fail "nested/archive: 하위 디렉터리 호출이 rc 0" \
  || pass "nested/archive: 하위 디렉터리 호출 거부"
printf '%s' "$nst_out" | out_has "active fr 없음" \
  && pass "nested/archive: metadata 미해석으로 조기 종료 (merge 이전)" \
  || fail "nested/archive: 다른 사유로 종료 — rollback 판정 범위가 실제 위험이 된다: $nst_out"
[[ "$main_before" == "$( cd "$REPO" && git rev-parse HEAD )" ]] \
  && pass "nested/archive: main HEAD 불변" || fail "nested/archive: main 이 전진함"
[[ -z "$( cd "$REPO" && git status --porcelain )" ]] \
  && pass "nested/archive: 워킹트리 무변경" || fail "nested/archive: 워킹트리가 변경됨"
rm -rf "$REPO"

# --- (d) rollback clean 판정은 저장소 루트 기준이어야 한다 (배선 고정) ---
# (c) 가 보여 주듯 행동으로는 아직 못 잡는다. 그렇다고 두면 `git -C` 가 조용히 지워져도
# 초록으로 남으므로, 최소한 배선을 고정한다. `.` pathspec 은 호출 위치 기준이라
# `git -C "$CURRENT_WT"` 가 없으면 prefix 밖 변경을 못 보고 사용자 변경을 reset 으로 지운다.
ARCH_SRC="$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/lifecycle/archive.sh"
grep -qE '^[^#]*_rb_dirty="\$\(git -C "\$CURRENT_WT" status --porcelain' "$ARCH_SRC" \
  && pass "rollback: clean 판정이 저장소 루트 기준(git -C)" \
  || fail "rollback: clean 판정이 호출 위치 기준 — prefix 밖 사용자 변경을 reset 으로 지운다"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
