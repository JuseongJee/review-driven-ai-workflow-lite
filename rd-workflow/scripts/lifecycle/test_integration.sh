#!/usr/bin/env bash
# Temp repo 기반 통합 테스트 — promote / archive / rollback / hook의 git state transition 자동 검증
set -euo pipefail

# herdr pane 안에서 돌면 HERDR_ENV=1 이 하위 프로세스로 그대로 상속되어, 임시 저장소의
# promote 가 **사용자의 실제 herdr 에 pane 을 만든다**. 이 스위트는 임시 저장소만 건드린다는
# 전제로 돌므로, 기동 경로는 환경에서 원천 차단한다(2026-09 사고: 테스트가 실제 pane 을 생성).
#   - HERDR_ENV= : session_launch 의 herdr 환경 판정 자체를 끈다.
#   - RD_CHILD_SESSION=1 : 이미 자식 세션이라는 깊이-1 제한 경로로 보내 기동을 거부한다.
# 둘 다 두는 이유는 어느 한쪽 판정이 바뀌어도 차단이 남게 하기 위해서다.
export HERDR_ENV=
export RD_CHILD_SESSION=1

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


# Common setup helper — temp git repo with lifecycle scripts copied in
#
# CURRENT_TASK.md 와 REQUEST.md 는 배포 템플릿을 그대로 복사한다. 둘 다 배포본에 포함되는
# 파일이고 promote 가 부재를 hard error 로 보므로(change spec D8), 없는 fixture 는 정상
# 흐름이 아니라 손상된 작업공간을 시험하게 된다. REQUEST 템플릿의 Source FR 은 '-' 라서
# "FR 없음" 으로 해석된다 — 개별 시나리오가 값을 덮어써 자기 조건을 만든다.
#
# `.gitignore` 의 `.worktrees/` 는 실배포 `_ROOT_FILES/.gitignore` 와 같은 항목이다. 재설계된
# promote 는 기본값으로 `<main worktree>/.worktrees/<slug>` 에 worktree 를 만들므로, 이 항목이
# 없으면 착수하자마자 기본 worktree 가 untracked 로 더러워져 archive 의 clean 검증을 막는다.
#
# rd-workflow-workspace/.gitkeep 도 같은 이유로 커밋한다. 배포본은 이 디렉터리 아래에
# 추적 파일(backlog/FUTURE_REQUESTS.md 등)을 가지므로 git worktree add 로 만든 체크아웃에
# 항상 이 디렉터리가 생긴다. git 은 빈 디렉터리를 추적하지 않아, 추적 파일이 하나도 없으면
# fixture 의 worktree 에만 이 디렉터리가 없는 배포본과 다른 상태가 만들어진다. 스크립트가
# 읽지 않는 빈 파일을 써서 어느 시나리오의 판정에도 끼어들지 않게 한다.
setup_repo() {
  local branch="${1:-main}"
  local d
  d="$(mktemp -d)" || { echo "test_integration.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$d" && -d "$d" ]] || { echo "test_integration.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
    if [[ -f "$PROJECT_ROOT/_ROOT_FILES/REQUEST.md" ]]; then \
      cp "$PROJECT_ROOT/_ROOT_FILES/REQUEST.md" REQUEST.md; \
    else \
      printf '# Change Request\n\n## Source FR\n-\n' > REQUEST.md; \
    fi; \
    mkdir -p rd-workflow/scripts/lifecycle rd-workflow/scripts/hooks rd-workflow-workspace/.lifecycle; \
    : > rd-workflow-workspace/.gitkeep; \
    printf '.worktrees/\nrd-workflow-workspace/.lifecycle/loop-state\nrd-workflow-workspace/.lifecycle/.loop-state.*\n' > .gitignore; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/lifecycle/*.sh rd-workflow/scripts/lifecycle/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/hooks/*.sh rd-workflow/scripts/hooks/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_state_common.sh rd-workflow/scripts/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_task_common.sh rd-workflow/scripts/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/rd rd-workflow/scripts/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_fr_register_common.sh rd-workflow/scripts/; \
    cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/fr_backlog_scan.sh rd-workflow/scripts/; \
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
  local b _bm
  _bm="$(mktemp -d)" || { echo "test_integration.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$_bm" && -d "$_bm" ]] || { echo "test_integration.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  b="$(dirname "$_bm")/bare-mirror-$1-$$"
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
# 때문이다: 한 번의 lifecycle 실행이 fr 브랜치 커밋(우회 대상 아님 — 언제나 hook 을 실행)과
# 기본 브랜치 커밋(우회 대상)을 모두 만들 수 있다. 어느 브랜치에서 hook 이 돌았는지를
# 기록해야 우회 여부를 정확히 읽을 수 있다.
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
# === Scenario 1: promote → archive lifecycle ===
echo "== scenario 1: promote → archive lifecycle =="
REPO="$(setup_repo)"
MAIN_TIP_BEFORE="$( cd "$REPO" && git rev-parse main )"
# --status "구현 중": archive 후 baseline reset 검증을 위해 실제 stale 상황(비-baseline status) 재현
run_promote "$REPO" --short-title test-foo --no-worktree --status "구현 중" >/dev/null
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "promote: branch fr/test-foo 존재" || fail "promote: branch 부재"
( cd "$REPO" && [[ "$(git rev-parse --abbrev-ref HEAD)" == "fr/test-foo" ]] ) && pass "promote: HEAD == fr/test-foo" || fail "promote: HEAD 불일치"
# 「promote 가 기본 브랜치에 metadata 를 커밋했는가」 단언은 새 계약에서 개념 자체가 사라져
# 제거했습니다 — promote.sh 는 이제 기본 브랜치에 아무것도 커밋하지 않고, 작업 상태는 fr
# 브랜치 위 task-state 에만 있습니다. 같은 자리에 새 계약이 보장하는 것을 세웁니다:
# 기본 브랜치 tip 이 promote 로 전혀 움직이지 않아야 합니다.
# (fr 브랜치 task-state 의 필드 정합 자체는 scenario 9 가 봅니다 — 여기서 겹쳐 보지 않습니다.)
( cd "$REPO" && [[ "$(git rev-parse main)" == "$MAIN_TIP_BEFORE" ]] ) && pass "promote: 기본 브랜치 tip 불변 (커밋 없음)" || fail "promote: 기본 브랜치에 커밋이 생김"

# Idempotent rerun
( cd "$REPO" && git switch main -q )
run_promote "$REPO" --short-title test-foo --size small --no-worktree >/dev/null
( cd "$REPO" && ! git rev-parse --verify fr/test-foo-2 >/dev/null 2>&1 ) && pass "promote rerun: suffix 안 만듦" || fail "promote rerun: 새 suffix 생성됨"

# fr branch에서 archive content commit
( cd "$REPO" && git switch fr/test-foo -q && \
  echo "# archived" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )

# Archive 호출 (--no-remote 모드)
# review precheck 는 test_lifecycle.sh 가 단위 검증하므로, 여기서는 force-skip 으로 관문만 통과하고
# git state 전이(merge/tag/branch 정리)에 집중한다.
# 새 계약: 기본 브랜치로 되돌아온 시점의 기본 worktree 는 baseline 이므로(task-state 가
# 어느 작업도 대표하지 않는다) 대상을 `--task` 로 명시해야 한다 (spec D13).
( cd "$REPO" && git switch main -q && \
  bash rd-workflow/scripts/lifecycle/archive.sh --task test-foo --no-remote --force-skip-review-check "통합 테스트 fixture" ) >/dev/null

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
out="$(cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-foo --fr-branch fr/test-foo --no-remote 2>&1 || true)"
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
     bash rd-workflow/scripts/lifecycle/archive.sh --task test-pre --no-remote --force-skip-review-check "통합 테스트 fixture" 2>&1 )"; then
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
( cd "$REPO" && git show fr/sfr-ok:rd-workflow-workspace/.lifecycle/task-state \
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
# repo 밖에 snapshot 을 둔다
SFR_SNAP="$(mktemp -d)" || { echo "test_integration.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$SFR_SNAP" && -d "$SFR_SNAP" ]] || { echo "test_integration.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
before_head="$( cd "$REPO" && git rev-parse HEAD )"
before_status="$( cd "$REPO" && git status --porcelain )"
cp "$REPO/CURRENT_TASK.md" "$SFR_SNAP/CURRENT_TASK.md"
before_state_exists=0
if [[ -f "$SFR_STATE" ]]; then
  before_state_exists=1
  cp "$SFR_STATE" "$SFR_SNAP/task-state"
fi

# stdout 과 stderr 를 분리 캡처한다 — 교정 안내가 stderr 로 나가는지 검증해야 한다.
sfr_out="$(mktemp)" || { echo "test_integration.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$sfr_out" && -f "$sfr_out" ]] || { echo "test_integration.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
sfr_err="$(mktemp)" || { echo "test_integration.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$sfr_err" && -f "$sfr_err" ]] || { echo "test_integration.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
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
DRY_SNAP="$(mktemp -d)" || { echo "test_integration.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$DRY_SNAP" && -d "$DRY_SNAP" ]] || { echo "test_integration.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
cp "$REPO/CURRENT_TASK.md" "$DRY_SNAP/CURRENT_TASK.md"
dry_before_status="$( cd "$REPO" && git status --porcelain )"
dry_out="$(mktemp)" || { echo "test_integration.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$dry_out" && -f "$dry_out" ]] || { echo "test_integration.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
dry_err="$(mktemp)" || { echo "test_integration.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$dry_err" && -f "$dry_err" ]] || { echo "test_integration.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
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
( cd "$REPO" && git show fr/sfr-pri:rd-workflow-workspace/.lifecycle/task-state \
    | grep -q "source-fr=rd-workflow-workspace/backlog/items/2026-08-12-gamma.md" ) \
  && pass "promote sfr: 명시 인자 우선" || fail "promote sfr: 우선순위 역전"

# === Scenario 2: promote → rollback ===
echo "== scenario 2: promote → rollback =="
REPO="$(setup_repo)"
# 새 계약에서는 worktree 격리가 기본이고, rollback 은 **그 작업의 worktree·branch·색인 행만**
# 되돌립니다. `--no-worktree` 작업은 기본 체크아웃 자체가 그 작업의 worktree 라
# promote_rollback.sh 의 「실행 중인 worktree 는 지우지 않는다」 가드에 걸려 이 전이를 볼 수
# 없으므로, 기본 경로(worktree) 착수로 시험합니다.
run_promote "$REPO" --short-title test-bar --size small >/dev/null
WT_BAR="$REPO/.worktrees/test-bar"
[[ -d "$WT_BAR" ]] && pass "rollback: 착수 worktree 생성" || fail "rollback: 착수 worktree 부재"
MAIN_TIP_BEFORE="$( cd "$REPO" && git rev-parse main )"
# `--fr-branch` 별칭은 제거되었습니다 — 대상 지정은 작업 단위(`--task <slug>`)로 통일했습니다.
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task test-bar ) >/dev/null
( cd "$REPO" && ! git rev-parse --verify fr/test-bar >/dev/null 2>&1 ) && pass "rollback: branch 삭제" || fail "rollback: branch 잔존"
[[ ! -d "$WT_BAR" ]] && pass "rollback: worktree 제거" || fail "rollback: worktree 잔존"
( cd "$REPO" && [[ -z "$(bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get test-bar fr-branch' 2>/dev/null)" ]] ) \
  && pass "rollback: 색인 행 제거" || fail "rollback: 색인 행 잔존"
# 「rollback 이 기본 worktree 의 task-state 를 baseline 으로 되돌렸는가」(구 LC-14) 는 새
# 계약에서 개념 자체가 사라져 제거했습니다 — 되돌릴 작업 상태는 지워질 fr 브랜치·worktree
# 안에만 있고, 기본 worktree 는 처음부터 baseline 입니다. 같은 자리에 새 계약이 보장하는
# 것을 세웁니다: rollback 은 기본 worktree 를 전혀 건드리지 않습니다.
( cd "$REPO" && [[ "$(git rev-parse main)" == "$MAIN_TIP_BEFORE" && -z "$(git status --porcelain)" ]] ) \
  && pass "rollback: 기본 worktree 불변 (tip·working tree)" || fail "rollback: 기본 worktree 오염"
rm -rf "$REPO"

# === Scenario 3: archive partial publish rerun (deterministic via direct git state setup) ===
echo "== scenario 3: archive partial publish rerun =="
REPO="$(setup_repo)"
REPO_PARENT="$(dirname "$REPO")"
BARE="$REPO_PARENT/bare-mirror-3-$$"
git init --bare "$BARE" -q 2>/dev/null || true
( cd "$REPO" && git remote add origin "$BARE" )

run_promote "$REPO" --short-title test-baz --size small --no-worktree >/dev/null
( cd "$REPO" && git switch fr/test-baz -q && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "ar content" )

# Partial state: manually merge + cleanup commit + lightweight tag (publish 직전 상태)
# NOTE: lightweight tag is used here so git rev-parse returns the commit SHA directly,
# matching what archive.sh's collision check compares against git rev-parse HEAD.
# v2 2b: active-fr 제거 대신 task-state의 fr-branch=null reset
#
# L2(archive_publish_content_check) 가 CURRENT_TASK.md 를 byte-exact 로 검사하므로, 이
# 위조 metadata commit 도 **실제 archive.sh Step 4 가 만드는 것과 같은 내용** 이어야
# 한다 — 위조 당시 CURRENT_TASK.md 를 그대로 두면 baseline 이 아니어서 rerun 이 L2 에서
# 차단된다 (Task 5 가 발견한 것이 정확히 이 상태다). emit_current_task_baseline 산출물로
# 덮어써 "정상적으로 Step 4 까지 마친 뒤 tag·push 만 실패한" 상태를 재현한다.
( cd "$REPO" && git switch main -q && \
  git merge --no-ff fr/test-baz -m "merge: test-baz" -q && \
  grep -q "^fr-branch=" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null && \
    awk -F'=' '$1=="fr-branch"{print "fr-branch=null"; next} $1=="worktree-path"{print "worktree-path=null"; next} $1!="created-at"{print}' \
      rd-workflow-workspace/.lifecycle/task-state > rd-workflow-workspace/.lifecycle/task-state.tmp && \
    mv rd-workflow-workspace/.lifecycle/task-state.tmp rd-workflow-workspace/.lifecycle/task-state || true; \
  . rd-workflow/scripts/lifecycle/_lifecycle_common.sh && \
  emit_current_task_baseline > CURRENT_TASK.md; \
  git add -A rd-workflow-workspace/.lifecycle CURRENT_TASK.md 2>/dev/null && \
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

run_promote "$REPO" --short-title test-quux --size small --worktree-path "$WT_PATH" >/dev/null
[[ -d "$WT_PATH" ]] && pass "worktree-promote: worktree 생성" || fail "worktree-promote: worktree 부재"
# 작업 상태의 권위는 fr 브랜치 위 task-state 다(기본 브랜치에는 커밋되지 않는다).
( cd "$REPO" && git show fr/test-quux:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null \
  | grep -qF "worktree-path=$WT_PATH" ) && pass "worktree-promote: metadata 기록 (task-state)" || fail "worktree-promote: metadata 부재"

# 인자 없는 재실행 — 살아 있는 worktree 가 있으면 「이미 진행 중」으로 거부한다.
# (구 계약의 "동일 worktree 재사용" 은 거부로 바뀌었다. 검사 의도는 그대로다 —
#  재실행이 조용히 **다른 worktree 를 만들지 않는다**.)
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-quux --size small 2>&1 ) || true )"
[[ "$out" == *"이미 진행 중"* ]] && pass "worktree-rerun: 인자 없는 재실행은 거부" || fail "worktree-rerun: 거부되지 않음 ($out)"
EXISTING_WT="$(cd "$REPO" && git worktree list --porcelain | awk '
  /^worktree /{p=$0; sub(/^worktree /,"",p); next}
  /^branch refs\/heads\/fr\/test-quux/{print p; exit}')"
[[ "$EXISTING_WT" == "$WT_PATH" ]] && pass "worktree-rerun: 등록된 worktree 불변" || fail "worktree-rerun: 다른 worktree ($EXISTING_WT)"

# 다른 경로를 명시한 재실행 → 거부 + 원래 worktree 보존 (조용한 "이사" 금지)
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-quux --size small --worktree-path "$REPO_PARENT/wt-other-$$" 2>&1 ) || true )"
[[ "$out" == *"이미 진행 중"* || "$out" == *"인자로 준 경로"* ]] && pass "worktree-rerun: 인자 mismatch hard error" || fail "worktree-rerun: 충돌 감지 실패 ($out)"
[[ -d "$WT_PATH" && ! -d "$REPO_PARENT/wt-other-$$" ]] && pass "worktree-rerun: 다른 경로로 이사하지 않음" || fail "worktree-rerun: worktree 가 이동됨"

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
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-rel --size small --worktree-path "$RELATIVE_WT" ) >/dev/null
EXPECTED_ABS="$PARENT_DIR/wt foo"
# 권위는 fr 브랜치 위 task-state 다 (기본 브랜치에는 아무것도 커밋되지 않는다).
( cd "$REPO" && git show fr/test-rel:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null \
  | grep -qF "worktree-path=$EXPECTED_ABS" ) \
  && pass "rel-space: metadata canonical absolute path 기록 (task-state)" || fail "rel-space: canonicalize 실패"
[[ -d "$EXPECTED_ABS" ]] && pass "rel-space: worktree 디렉토리 생성 (공백 포함)" || fail "rel-space: worktree 부재"

# parent 미존재 hard error (relative path — absolute paths skip parent check in promote.sh)
REPO2="$(setup_repo)"
out="$( ( cd "$REPO2" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title test-noparent --size small --worktree-path "../non-existent-parent-$$/wt" 2>&1 ) || true )"
[[ "$out" == *"parent 미존재"* ]] && pass "rel-noparent: hard error" || fail "rel-noparent: 통과되었음 ($out)"

rm -rf "$REPO" "$REPO2" "$PARENT_DIR"

# === Scenario 7: fetch failure preflight hard-stop ===
echo "== scenario 7: archive fetch failure preflight =="
REPO="$(setup_repo)"
( cd "$REPO" && git remote add origin "/non/existent/bare-mirror-$$.git" )
run_promote "$REPO" --short-title test-fetchfail --size small --no-worktree >/dev/null
( cd "$REPO" && git switch fr/test-fetchfail -q && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "ar content" )
( cd "$REPO" && git switch main -q )

# 기본 브랜치로 되돌아온 기본 worktree 는 baseline 이므로 대상을 `--task` 로 명시한다 (spec D13).
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-fetchfail 2>&1 ) || true )"
[[ "$out" == *"fetch --tags origin 실패"* ]] \
  && pass "fetch-fail: preflight hard error" || fail "fetch-fail: 메시지 부재 ($out)"

# Side effect 부재 검증
( cd "$REPO" && git rev-parse --verify fr/test-fetchfail >/dev/null 2>&1 ) && pass "fetch-fail: fr branch 보존" || fail "fetch-fail: fr branch 삭제됨"
# 작업 상태의 권위는 fr 브랜치 위 task-state 다 — 그 값이 그대로면 metadata 가 보존된 것이다.
( cd "$REPO" && git show fr/test-fetchfail:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null \
  | grep -q "^fr-branch=fr/test-fetchfail$" ) && pass "fetch-fail: metadata 보존 (task-state fr-branch 유효)" || fail "fetch-fail: metadata 삭제됨"
( cd "$REPO" && [[ -z "$(git tag --list 'fr/*/test-fetchfail')" ]] ) && pass "fetch-fail: tag 미생성" || fail "fetch-fail: tag 생성됨"

rm -rf "$REPO"

# === Scenario 8: --fr-branch override mismatch guard ===
# active metadata 와 다른 --fr-branch override 가 들어오면 hard error 로 막아야 한다.
# unrelated active FR (branch + metadata) 가 보존되어야 한다.
echo "== scenario 8: override mismatch guard =="
REPO="$(setup_repo)"
# `--no-worktree` 착수라 기본 체크아웃이 그대로 그 작업의 worktree 다 — **기본 브랜치로
# 되돌리지 않는다.** archive 의 override mismatch 가드는 호출 worktree 의 task-state 가
# 실제 작업을 가리킬 때(= metadata_exists) 동작하고, 기본 브랜치 worktree 는 새 계약에서
# 항상 baseline 이라 그 가드를 볼 수 없다.
run_promote "$REPO" --short-title test-foo --size small --no-worktree >/dev/null
( cd "$REPO" && git branch fr/test-bar main )

# archive override mismatch
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/test-bar --no-remote 2>&1 ) || true )"
[[ "$out" == *"불일치"* ]] && pass "archive override-mismatch: hard error" || fail "archive override-mismatch: 통과 ($out)"
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "archive override-mismatch: active branch 보존" || fail "archive override-mismatch: active branch 삭제됨"
( cd "$REPO" && grep -q "^fr-branch=fr/test-foo$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "archive override-mismatch: active metadata 보존 (task-state)" || fail "archive override-mismatch: metadata 삭제됨"

# rollback 쪽 「override 가 active metadata 와 불일치하면 hard error」 단언은 새 계약에서
# 개념 자체가 사라져 제거했습니다 — rollback 은 `--fr-branch` 를 받지 않고 대상을
# `--task <slug>` 로만 고르므로, "active 하나와 override 가 어긋난다" 는 상태가 없습니다.
# 그 단언이 지키려던 것(무관한 진행 중 작업의 branch·metadata 보존)은 그대로 세웁니다:
# 다른 작업을 대상으로 지정해도 진행 중인 test-foo 는 건드려지지 않아야 합니다.
out="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task test-bar 2>&1 ) || true )"
[[ "$out" == *"완료"* ]] && pass "rollback 다른 작업 지정: 그 대상만 되돌림" || fail "rollback 다른 작업 지정: 실패 ($out)"
( cd "$REPO" && git rev-parse --verify fr/test-foo >/dev/null 2>&1 ) && pass "rollback 다른 작업 지정: 진행 중 branch 보존" || fail "rollback 다른 작업 지정: 진행 중 branch 삭제됨"
( cd "$REPO" && grep -q "^fr-branch=fr/test-foo$" rd-workflow-workspace/.lifecycle/task-state 2>/dev/null ) && pass "rollback 다른 작업 지정: 진행 중 metadata 보존 (task-state)" || fail "rollback 다른 작업 지정: metadata 삭제됨"

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
# 「기본 브랜치 쪽 metadata 가 유지되는가」 는 새 계약에서 개념이 사라졌습니다 — promote 는
# 기본 브랜치에 아무것도 커밋하지 않습니다. 같은 자리에 권위 쪽 보장을 세웁니다:
# 워킹트리 값이 fr 브랜치 tip 에 **커밋까지** 되어 있어야 합니다 (커밋 누락이면 다음 promote 가
# divergent 로 판정해 재개가 막힙니다).
( cd "$REPO" && git show fr/test-sync:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null | grep -q "^fr-branch=fr/test-sync$" ) && pass "checkout-sync: fr tip 에 커밋됨" || fail "checkout-sync: fr tip 미커밋"
rm -rf "$REPO"

# 모드 2 — worktree promote (--worktree-path). worktree 내부 task-state가 정합해야 한다
REPO="$(setup_repo)"
REPO_PARENT="$(dirname "$REPO")"
WT_SYNC="$REPO_PARENT/wt-sync-$$"
run_promote "$REPO" --short-title test-wtsync --size small --worktree-path "$WT_SYNC" >/dev/null
WTS="$WT_SYNC/rd-workflow-workspace/.lifecycle/task-state"
( grep -q "^short-title=test-wtsync$" "$WTS" 2>/dev/null ) && pass "wt-sync: short-title 정합" || fail "wt-sync: short-title 회귀"
( grep -q "^status=구현 중$" "$WTS" 2>/dev/null ) && pass "wt-sync: status 정합" || fail "wt-sync: status 회귀"
( grep -q "^fr-branch=fr/test-wtsync$" "$WTS" 2>/dev/null ) && pass "wt-sync: fr-branch 정합" || fail "wt-sync: fr-branch 회귀"
( grep -qF "worktree-path=$WT_SYNC" "$WTS" 2>/dev/null ) && pass "wt-sync: worktree-path 정합" || fail "wt-sync: worktree-path 회귀"
( cd "$REPO" && git worktree remove --force "$WT_SYNC" ) >/dev/null 2>&1 || true
rm -rf "$REPO" "$WT_SYNC"

# === Scenario 10: fr 브랜치 외부 삭제 후 재착수 복구 ===
# 구 계약의 「stale fr-branch 진단」 중 case 1·2(기본 브랜치 metadata 가 실재하지 않는 브랜치를
# 가리키면 promote 가 진단과 함께 조기 실패)는 새 설계에서 개념 자체가 사라져 제거했습니다 —
# 기본 브랜치에 작업 metadata 가 커밋되지 않으므로 그 상태가 만들어지지 않고, promote 는 ref
# 부재를 그냥 fresh 로 판정합니다. 그 케이스들이 지키려던 실질(사람이 fr 브랜치를 손으로 지운
# 뒤에도 재착수로 복구된다)을 남깁니다.
#
# case 3(동명 tag)은 **판정의 관측 결과만 뒤집혔을 뿐 불변식은 그대로**라 형태를 바꿔
# 살렸습니다. promote 의 ref 조회는 여전히 `refs/heads/` 로 한정되어야 합니다 — 접두사를
# 잃으면 동명 tag 가 resolve 되어 ref 가 있는 것으로 오판하고, fresh 여야 할 착수가
# duplicate·ambiguous 로 막힙니다. 구 계약에서는 그 오판이 "stale 진단 누락" 으로,
# 새 계약에서는 "착수 불가" 로 나타납니다.
echo "== scenario 10: fr 브랜치 외부 삭제 후 재착수 =="
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-stale --size small --no-worktree >/dev/null
( cd "$REPO" && git switch main -q && git branch -D fr/test-stale -q )

run_promote "$REPO" --short-title test-stale --size small --no-worktree >/dev/null 2>&1 \
  && pass "외부 삭제 복구: promote 재실행 성공" || fail "외부 삭제 복구: promote 재실행 실패"
( cd "$REPO" && git rev-parse --verify fr/test-stale >/dev/null 2>&1 ) \
  && pass "외부 삭제 복구: fr 브랜치 재생성" || fail "외부 삭제 복구: fr 브랜치 부재"
( cd "$REPO" && git show fr/test-stale:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null \
  | grep -q "^fr-branch=fr/test-stale$" ) \
  && pass "외부 삭제 복구: 작업 상태 재초기화" || fail "외부 삭제 복구: 작업 상태 미초기화"

rm -rf "$REPO"

# 동명 tag 만 있고 브랜치는 없는 상태 — refs/heads 전용 판정이면 fresh 로 보고 착수해야 한다.
REPO="$(setup_repo)"
( cd "$REPO" && git tag fr/test-tagonly )
run_promote "$REPO" --short-title test-tagonly --size small --no-worktree >/dev/null 2>&1 \
  && pass "tag-only: 동명 tag 는 ref 존재로 오판하지 않는다 (착수 성공)" \
  || fail "tag-only: 동명 tag 를 resolve 해 착수가 막혔다"
( cd "$REPO" && git rev-parse --verify refs/heads/fr/test-tagonly >/dev/null 2>&1 ) \
  && pass "tag-only: fr 브랜치 생성" || fail "tag-only: fr 브랜치 부재"

rm -rf "$REPO"

echo "== scenario 11: master 기본 브랜치 lifecycle =="
REPO="$(setup_repo master)"
REPO_PARENT="$(dirname "$REPO")"
BARE11="$REPO_PARENT/bare-mirror-11-$$"
git init --bare "$BARE11" -q 2>/dev/null || true
( cd "$REPO" && git remote add origin "$BARE11" )

run_promote "$REPO" --short-title test-master --size small --no-worktree >/dev/null 2>&1 \
  && pass "master-promote: exit 0" || fail "master-promote: 실패"
( cd "$REPO" && git show fr/test-master:rd-workflow-workspace/.lifecycle/task-state 2>/dev/null | grep -q "fr-branch=fr/test-master" ) \
  && pass "master-promote: metadata 기록" || fail "master-promote: metadata 부재"
# fr branch 위 작업 commit 후 master로 돌아가 archive (review-check는 fixture라 force-skip)
( cd "$REPO" && git commit -q --allow-empty -m "work" )
( cd "$REPO" && git switch master -q && bash rd-workflow/scripts/lifecycle/archive.sh --task test-master --force-skip-review-check "통합 테스트 fixture" >/dev/null 2>&1 ) \
  && pass "master-archive: exit 0" || fail "master-archive: 실패"
_tag11="$(cd "$REPO" && git tag --list "fr/*/test-master" | head -1)"
( [[ -n "$_tag11" ]] && cd "$REPO" && git merge-base --is-ancestor "$_tag11" master 2>/dev/null ) \
  && pass "master-archive: merge 완료" || fail "master-archive: merge 안 됨"
( cd "$REPO" && git ls-remote origin refs/heads/master 2>/dev/null | grep -q . ) \
  && pass "master-archive: master pushed" || fail "master-archive: master 미push"
( cd "$REPO" && git tag --list "fr/*/test-master" | grep -q . ) \
  && pass "master-archive: tag 생성" || fail "master-archive: tag 부재"

# diff review base 판정 (prepare_review_pipeline.sh, change spec §5.2)
# 전제: setup_repo()가 이미 lifecycle/*.sh(_lifecycle_common.sh 포함)와 _state_common.sh를
# fixture의 rd-workflow/scripts/ 아래에 복사해 두므로, prepare가 source할 의존성은 충족되어 있다.
# 여기서는 prepare_review_pipeline.sh 한 파일만 추가 복사하면 된다.
#
# 이 fixture 는 archive 직후라 `fr-branch=null`·`base-commit` 미설정입니다. 종전 단언은
# `git diff master...HEAD` **문자열**을 기대했으나, 새 설계에서 Review Target 은 고정 OID
# 두 점이고 입력이 없으면 **세션을 만들지 않고 exit 1** 입니다 (AC 4 — 빈 diff 가 조용히
# 통과하던 원 결함을 막는 의도된 동작). 두 상태를 모두 단언합니다.
( cd "$REPO" && mkdir -p rd-workflow/scripts \
  && cp "$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/prepare_review_pipeline.sh" rd-workflow/scripts/ \
  && cp "$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/init_review_pipeline.sh" rd-workflow/scripts/ )
# 세션 디렉터리 개수 — 없으면 0. `ls` 실패가 set -e 로 스위트를 죽이지 않게 감쌉니다.
_ses_count() {
  local n=0
  n="$(ls -d "$1"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | wc -l | tr -d ' ')" || n=0
  printf '%s' "${n:-0}"
}
( cd "$REPO" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff >/dev/null 2>&1 ) \
  && fail "master-diff: base 입력 없는데 exit 0" || pass "master-diff: base 입력 없음 → exit 1"
[[ "$(_ses_count "$REPO")" == "0" ]] \
  && pass "master-diff: base 입력 없음 → 세션 미생성" || fail "master-diff: 세션이 만들어짐"

# base-commit 을 설정하면 두 끝이 고정 OID 인 target 으로 세션이 만들어집니다.
_base11="$(cd "$REPO" && git rev-parse HEAD~1)"
( cd "$REPO" && bash rd-workflow/scripts/rd task set-base "$_base11" >/dev/null 2>&1 ) \
  && pass "master-diff: set-base 성공" || fail "master-diff: set-base 실패"
( cd "$REPO" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff >/dev/null 2>&1 ) \
  && pass "master-diff: base-commit → 세션 생성" || fail "master-diff: 세션 생성 실패"
DIFF_SES="$(ls -d "$REPO"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | head -1)" || DIFF_SES=""
_head11="$(cd "$REPO" && git rev-parse HEAD)"
( [[ -n "$DIFF_SES" ]] && grep -qF "git diff ${_base11}..${_head11}" "$DIFF_SES/SESSION.md" ) \
  && pass "master-diff: Review Target 이 OID 두 점" || fail "master-diff: target 오검출 (SESSION=$DIFF_SES)"
( [[ -n "$DIFF_SES" ]] && grep -qF -e "- review-head-oid: ${_head11}" "$DIFF_SES/SESSION.md" ) \
  && pass "master-diff: review-head-oid 기록" || fail "master-diff: review-head-oid 미기록"

rm -rf "$REPO" "$BARE11"

# === Scenario 12: cleanup 정상 경로 — origin/<fr> 이 로컬 fr 보다 뒤처짐 (AC12) ===
# 이 워크플로는 fr 을 매 커밋마다 push 하지 않으므로 local fr tip > origin/fr tip 이 정상 상태다.
# git branch -d 는 upstream 기준으로 판정하므로 이 정상 상태를 "미머지" 로 오판정한다.
echo "== scenario 12: cleanup 정상 경로 (origin/fr 뒤처짐) =="
REPO="$(setup_repo)"
BARE12="$(mk_bare 12)"
( cd "$REPO" && git remote add origin "$BARE12" && git push -q origin main )
run_promote "$REPO" --short-title test-behind --size small --no-worktree >/dev/null
# fr 을 한 번 push 해 upstream 을 설정 → 이후 로컬에만 커밋을 쌓아 origin/fr 을 뒤처지게 만든다
( cd "$REPO" && git commit -q --allow-empty -m "w1" && git push -q -u origin fr/test-behind )
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )

rc12=0
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-behind \
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
#   archive.sh:74-82)에 걸려 Step 8/9 판정에 도달하지 못한다. 그래서 hook 으로 merge
#   이후(= 안전망 통과 후) 로컬 ref 를 제거하고, 원격은 처음부터 push 하지 않는다.
#
#   **post-merge 가 아니라 post-commit 을 쓴다.** L1(Step 3.6) 이 merge 직후 곧바로
#   fr tip 을 읽어 기준선을 정하므로, post-merge 시점에 ref 를 지우면 L1 이 "판정 불능"
#   으로 조기 차단해 Step 8/9 에 아예 도달하지 못한다 (Task 5 가 뒤집은 부분). Step 4 의
#   metadata cleanup commit 은 L1 계산이 이미 끝난 뒤 발생하고 L2 는 BASELINE_OID·
#   PUBLISH_OID 만 보고 fr ref 를 다시 읽지 않으므로, 그 commit 의 post-commit 시점에
#   개입하면 L1/L2 는 원래 fr tip 으로 그대로 통과하고 Step 8/9 만 정상 부재를 본다.
REPO="$(setup_repo)"
BARE13="$(mk_bare 13)"
( cd "$REPO" && git remote add origin "$BARE13" && git push -q origin main )
run_promote "$REPO" --short-title test-absent --size small --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
cat > "$REPO/.git/hooks/post-commit" <<'HOOK'
#!/bin/sh
# post-commit hook 은 GIT_DIR 을 환경으로 받지 못하므로 직접 구한다
gd="$(git rev-parse --git-dir)"
[ -f "$gd/.absent-done" ] && exit 0
: > "$gd/.absent-done"
git update-ref -d refs/heads/fr/test-absent
HOOK
chmod +x "$REPO/.git/hooks/post-commit"

out13="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-absent \
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
run_promote "$REPO" --short-title test-localonly --size small --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
rc13b=0
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-localonly --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || rc13b=$?
[[ "$rc13b" -eq 0 ]] && pass "local-only: exit 0 (원격 미시도)" || fail "local-only: exit=$rc13b"
( cd "$REPO" && ! git rev-parse --verify fr/test-localonly >/dev/null 2>&1 ) \
  && pass "local-only: 로컬 브랜치 삭제" || fail "local-only: 로컬 브랜치 잔존"
rm -rf "$REPO"

# 13-c: 대상 ref 는 없고 "하위 ref" 만 하나 있는 상태 → 정상 부재로 판정되어야 한다.
#   for-each-ref 의 패턴은 slash 경계의 하위 ref 도 매치하므로, %(objectname) 만 읽으면
#   child 의 유효 OID 한 줄이 나와 "대상 존재" 로 오인된다 (실측). 정확 refname 필터가 이를 막는다.
#   13-a 와 같은 이유로 post-merge 대신 post-commit 을 쓴다 — L1 이 merge 직후 fr tip 을
#   읽으므로, 그보다 뒤인 Step 4 metadata commit 이후에 ref 형태를 바꿔야 L1/L2 는
#   원래 fr tip 으로 통과하고 Step 8/9 만 하위 ref 오인 여부를 검사한다.
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-childref --size small --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
cat > "$REPO/.git/hooks/post-commit" <<'HOOK'
#!/bin/sh
gd="$(git rev-parse --git-dir)"
[ -f "$gd/.child-done" ] && exit 0
: > "$gd/.child-done"
# 대상 ref 를 지우고, 그 아래 경로에 하위 ref 를 하나 만든다
oid=$(git rev-parse refs/heads/fr/test-childref)
git update-ref -d refs/heads/fr/test-childref
git update-ref refs/heads/fr/test-childref/child "$oid"
HOOK
chmod +x "$REPO/.git/hooks/post-commit"

out13c="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-childref --no-remote \
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

# 14-a (AC13): 진짜 미머지 — hook 이 fr tip 을 전진시켜 Step 8 의 ancestor 판정을 뒤집는다.
#
#   **post-merge 가 아니라 post-commit 을 쓴다.** L1(Step 3.6)은 merge 직후 fr tip 으로
#   기준선을 정한다 — post-merge 시점에 drift 시키면 L1 이 "기대하지 않은 커밋 그래프"
#   로 조기 차단해(Task 5 가 뒤집은 부분) Step 8 의 CLEANUP-PENDING 요약·복구 문구를
#   내지 못한다. Step 4 metadata commit 이후(=L1 계산이 끝난 뒤)에 drift 시키면 L1/L2 는
#   원래 fr tip 으로 통과해 tag·push 까지 마치고, Step 8 이 그 시점의 fr tip 으로 다시
#   ancestor 를 판정해 "실제 미머지" 를 검출한다 — 이 시나리오가 지키려는 것 그대로다.
REPO="$(setup_repo)"
BARE14="$(mk_bare 14)"
( cd "$REPO" && git remote add origin "$BARE14" && git push -q origin main )
run_promote "$REPO" --short-title test-unmerged --size small --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
  && git push -q -u origin fr/test-unmerged )
( cd "$REPO" && git switch main -q )
cat > "$REPO/.git/hooks/post-commit" <<'HOOK'
#!/bin/sh
# 한 번만 개입 — Step 4 metadata commit 직후 fr tip 을 새 커밋으로 전진시켜 미머지 상태를 만든다.
gd="$(git rev-parse --git-dir)"
[ -f "$gd/.drift-done" ] && exit 0
: > "$gd/.drift-done"
tree=$(git rev-parse refs/heads/fr/test-unmerged^{tree}) || exit 0
new=$(git commit-tree "$tree" -p refs/heads/fr/test-unmerged -m "drift") || exit 0
git branch -f fr/test-unmerged "$new"
HOOK
chmod +x "$REPO/.git/hooks/post-commit"

out14="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-unmerged \
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
run_promote "$REPO" --short-title test-wtfail --size small --worktree-path "$WT14" >/dev/null
( cd "$WT14" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git push -q origin fr/test-wtfail )
echo "dirty" > "$WT14/junk-untracked.txt"
mkdir -p "$REPO/rd-workflow-workspace/.lifecycle"
printf 'verify-fail::test-wtfail::test=2\n' > "$REPO/rd-workflow-workspace/.lifecycle/loop-state"

out14b="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-wtfail \
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
run_promote "$REPO" --short-title test-conflict --size small --no-worktree >/dev/null
( cd "$REPO" && echo "fr-side" > conflict.txt && git add conflict.txt && git commit -q -m "fr edit" )
( cd "$REPO" && git switch main -q && echo "main-side" > conflict.txt \
  && RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit -q -am "main edit" )
rc14c=0
( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-conflict --no-remote \
    --force-skip-review-check "통합 테스트 fixture" ) >/dev/null 2>&1 || rc14c=$?
[[ "$rc14c" -ne 0 ]] && pass "core-fail: merge conflict non-zero" || fail "core-fail: exit 0"
( cd "$REPO" && git rev-parse --verify fr/test-conflict >/dev/null 2>&1 ) \
  && pass "core-fail: fr branch 보존" || fail "core-fail: fr branch 삭제됨"
( cd "$REPO" && git merge --abort ) >/dev/null 2>&1 || true
rm -rf "$REPO"

# === Scenario 15: 원격 tip 이 base 의 ancestor 아님 (AC15) ===
# 로컬에서 만든 무관한 커밋을 원격 fr ref 로 강제 push 한다.
# 객체는 로컬에 있으므로 판정은 가능하지만 ancestor 가 아니므로 원격 삭제를 수행하면 안 된다.
echo "== scenario 15: 원격 tip ancestor 아님 =="
REPO="$(setup_repo)"
BARE15="$(mk_bare 15)"
( cd "$REPO" && git remote add origin "$BARE15" && git push -q origin main )
run_promote "$REPO" --short-title test-rdrift --size small --no-worktree >/dev/null
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" \
  && git push -q -u origin fr/test-rdrift )
# 로컬 fr 과 무관한 커밋을 만들어 원격 ref 만 그쪽으로 옮긴다 (worktree/index 불변)
ALIEN15="$( cd "$REPO" && git commit-tree "$(git rev-parse HEAD^{tree})" \
  -p "$(git rev-parse HEAD)" -m "alien" )"
( cd "$REPO" && git push -q --force origin "$ALIEN15:refs/heads/fr/test-rdrift" )
( cd "$REPO" && git switch main -q )

out15="$( ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-rdrift \
    --force-skip-review-check "통합 테스트 fixture" ) 2>&1 )" && rc15=0 || rc15=$?
[[ "$rc15" -ne 0 ]] && pass "remote-drift: non-zero 종료" || fail "remote-drift: exit 0"
( cd "$REPO" && git ls-remote origin refs/heads/fr/test-rdrift 2>/dev/null | grep -q . ) \
  && pass "remote-drift: 원격 ref 보존" || fail "remote-drift: 원격 ref 삭제됨"
[[ "$out15" == *"CLEANUP-PENDING"* ]] \
  && pass "remote-drift: 요약 블록 출력" || fail "remote-drift: 요약 블록 부재"
[[ "$out15" == *"[remote-branch]"* ]] \
  && pass "remote-drift: remote-branch 항목 기록" || fail "remote-drift: 항목 누락"
rm -rf "$REPO" "$BARE15"

# === Scenario: 기본 브랜치 worktree 밖 호출 거부 — resolved 브랜치명 안내 문구 검증 ===
echo "== scenario: 비-기본-브랜치 worktree 호출 거부 (trunk fixture) =="
REPO="$(setup_repo trunk)"
( cd "$REPO" && mkdir -p rd-workflow/config \
  && printf '{"default_branch": "trunk"}\n' > rd-workflow/config/workflow.json \
  && git add -A && git commit -q -m "config" )
WT="${REPO}-side-wt"
( cd "$REPO" && git worktree add -q "$WT" -b side )
# promote — `--no-worktree` 는 기본 브랜치 체크아웃에서만 허용한다. 다른 worktree 에서 부르면
# 그 worktree 의 체크아웃이 통째로 넘어가므로 거부하고, 안내에 resolved 기본 브랜치명을 담는다.
RC=0; ERR="$( (cd "$WT" && bash rd-workflow/scripts/lifecycle/promote.sh \
  --short-title test-mm --size small --no-worktree) 2>&1 )" || RC=$?
[[ "$RC" -eq 1 ]] && pass "promote mismatch: exit 1" || fail "promote mismatch: exit=$RC"
printf '%s' "$ERR" | grep -q "기본 브랜치(trunk)" \
  && pass "promote mismatch: resolved 브랜치명 안내" || fail "promote mismatch: 브랜치명 문구 누락 — $ERR"
( cd "$REPO" && ! git rev-parse --verify fr/test-mm >/dev/null 2>&1 ) \
  && pass "promote mismatch: 브랜치 미생성 (상태 변경 없음)" || fail "promote mismatch: 브랜치가 생성됨"

# rollback — fr 브랜치가 아닌 worktree 는 되돌릴 대상이 아니므로 무변경으로 거부한다.
RC=0; ERR="$( (cd "$WT" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh) 2>&1 )" || RC=$?
[[ "$RC" -eq 1 ]] && pass "rollback mismatch: exit 1" || fail "rollback mismatch: exit=$RC"
printf '%s' "$ERR" | grep -q "상태 변경 없음" \
  && pass "rollback mismatch: 무변경 안내" || fail "rollback mismatch: 무변경 문구 누락 — $ERR"

# archive 의 「기본 브랜치 worktree 밖 호출 거부」 단언은 새 계약에서 개념 자체가 사라져
# 제거했습니다 — archive 는 이제 거부하지 않고 발행 worktree 로 `cd` 해 자기 자신을
# 재실행합니다(spec D5). 그 재실행 경로는 test_archive_worktree.sh 가 봅니다.
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

  # (b) promote — 「기본 브랜치 metadata 커밋이 hook 을 뚫고 기록되는가」 단언은 새 계약에서
  #     개념 자체가 사라져 제거했습니다(promote 는 기본 브랜치에 아무것도 커밋하지 않습니다).
  #     같은 자리에 새 계약이 보장하는 것을 세웁니다: 차단 hook 아래에서도 착수는 끝까지
  #     가고, 기본 브랜치 tip 은 움직이지 않습니다.
  hb_tip="$( cd "$REPO" && git rev-parse "$_br" )"
  prc=0
  run_promote "$REPO" --short-title test-hb --size small --no-worktree >/dev/null 2>&1 || prc=$?
  [[ "$prc" -eq 0 ]] \
    && pass "hook-block/$_br promote: exit 0" || fail "hook-block/$_br promote: exit=$prc"
  ( cd "$REPO" && [[ "$(git rev-parse "$_br")" == "$hb_tip" ]] ) \
    && pass "hook-block/$_br promote: 기본 브랜치 tip 불변 (커밋 없음)" \
    || fail "hook-block/$_br promote: 기본 브랜치에 커밋이 생김"
  rm -rf "$REPO"

  # (c) promote_rollback — rollback 도 더 이상 커밋을 만들지 않습니다(되돌릴 상태가 지워질
  #     worktree·branch 안에만 있습니다). 「커밋이 이력에 반영」 단언을 제거하고, 차단 hook
  #     아래에서도 되돌리기가 완주하고 기본 브랜치를 건드리지 않는다는 것을 세웁니다.
  REPO="$(setup_repo "$_br")"
  run_promote "$REPO" --short-title test-hbr --size small >/dev/null 2>&1
  install_blocking_pre_commit "$REPO"
  hbr_tip="$( cd "$REPO" && git rev-parse "$_br" )"
  rrc=0
  ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task test-hbr ) >/dev/null 2>&1 || rrc=$?
  [[ "$rrc" -eq 0 ]] \
    && pass "hook-block/$_br rollback: exit 0" || fail "hook-block/$_br rollback: exit=$rrc"
  ( cd "$REPO" && ! git rev-parse --verify fr/test-hbr >/dev/null 2>&1 ) \
    && pass "hook-block/$_br rollback: branch 삭제" || fail "hook-block/$_br rollback: branch 잔존"
  ( cd "$REPO" && [[ "$(git rev-parse "$_br")" == "$hbr_tip" ]] ) \
    && pass "hook-block/$_br rollback: 기본 브랜치 tip 불변 (커밋 없음)" \
    || fail "hook-block/$_br rollback: 기본 브랜치에 커밋이 생김"
  rm -rf "$REPO"

  # (d) archive
  REPO="$(setup_repo "$_br")"
  BAREHB="$(mk_bare "hb-$_br")"
  ( cd "$REPO" && git remote add origin "$BAREHB" && git push -q origin "$_br" )
  run_promote "$REPO" --short-title test-hba --size small --no-worktree >/dev/null 2>&1
  ( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
  ( cd "$REPO" && git switch "$_br" -q )
  install_blocking_pre_commit "$REPO"
  arc=0
  ( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-hba \
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
# **archive 한 경로로만 검증한다.** 재설계 이후 기본 브랜치에 커밋을 만드는 lifecycle 지점은
# archive 뿐이고(promote·promote_rollback 은 기본 브랜치에 커밋하지 않는다),
# lifecycle_needs_hook_bypass 를 쓰는 곳도 archive 뿐이다.
#
# trunk 와 main 을 짝으로 둔다. 한쪽만 보면 "우회 안내가 없다" 가 우회를 안 해서인지
# 안내 지점에 도달하지 못해서인지 구분되지 않아 판정이 성립하지 않는다.
#
# marker hook 은 **promote 보다 먼저** 설치한다 — promote 의 fr 브랜치 커밋이 언제나 hook 을
# 실행하므로(우회 대상이 아니다), 그 흔적이 "hook 자체가 동작한다" 는 통제군이 된다.
_hookcond_case() {  # _hookcond_case <기본 브랜치> <slug>
  local br="$1" slug="$2" repo out rc=0
  repo="$(setup_repo "$br")"
  if [[ "$br" != "main" && "$br" != "master" ]]; then
    ( cd "$repo" && mkdir -p rd-workflow/config \
      && printf '{"default_branch": "%s"}\n' "$br" > rd-workflow/config/workflow.json \
      && git add -A && git commit -q -m "config" )
  fi
  install_marker_pre_commit "$repo"
  run_promote "$repo" --short-title "$slug" --size small --no-worktree >/dev/null 2>&1
  ( cd "$repo" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
  ( cd "$repo" && git switch "$br" -q )
  out="$( cd "$repo" && bash rd-workflow/scripts/lifecycle/archive.sh --task "$slug" --no-remote \
      --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || rc=$?
  printf '%s\t%s\t%s\n' "$repo" "$rc" "${out//$'\n'/ }"
}

# (a) trunk — 우회하지 않는다
_hc="$(_hookcond_case trunk test-nbt)"
REPO="${_hc%%$'\t'*}"; _hc_rest="${_hc#*$'\t'}"
nbt_rc="${_hc_rest%%$'\t'*}"; nbt_out="${_hc_rest#*$'\t'}"
[[ "$nbt_rc" -eq 0 ]] \
  && pass "hook-cond/trunk: archive rc=0" || fail "hook-cond/trunk: rc=$nbt_rc — $nbt_out"
marker_has "$REPO" "ran:trunk" \
  && pass "hook-cond/trunk: 기본 브랜치 커밋에서 hook 실행됨 (우회 안 함)" \
  || fail "hook-cond/trunk: hook 미실행 — 차단 대상이 아닌 브랜치를 우회함"
printf '%s' "$nbt_out" | out_has "hook 을 건너뛰고 커밋했습니다" \
  && fail "hook-cond/trunk: 우회하지 않았는데 우회 안내가 출력됨" \
  || pass "hook-cond/trunk: 우회 안내 없음"
rm -rf "$REPO"

# (b) main — 우회한다 (대조군)
_hc="$(_hookcond_case main test-nbm)"
REPO="${_hc%%$'\t'*}"; _hc_rest="${_hc#*$'\t'}"
nbm_rc="${_hc_rest%%$'\t'*}"; nbm_out="${_hc_rest#*$'\t'}"
[[ "$nbm_rc" -eq 0 ]] \
  && pass "hook-cond/main: archive rc=0" || fail "hook-cond/main: rc=$nbm_rc — $nbm_out"
marker_has "$REPO" "ran:main" \
  && fail "hook-cond/main: 차단 대상 브랜치인데 hook 이 실행됨 (우회 실패)" \
  || pass "hook-cond/main: 기본 브랜치 커밋에서 hook 미실행 (우회함)"
# hook 이 애초에 설치·동작하지 않아서 marker 가 비었을 가능성을 같은 fixture 안에서 배제한다.
# promote 의 fr 브랜치 승격 커밋은 우회 대상이 아니므로 반드시 hook 을 실행했어야 한다.
marker_has "$REPO" "ran:fr/test-nbm" \
  && pass "hook-cond/main: 비우회 커밋에서는 hook 실행됨 (hook 동작 확인)" \
  || fail "hook-cond/main: hook 자체가 동작하지 않음 — 위 판정이 무의미"
printf '%s' "$nbm_out" | out_has "hook 을 건너뛰고 커밋했습니다" \
  && pass "hook-cond/main: 우회 안내 출력" || fail "hook-cond/main: 우회 안내 누락 — $nbm_out"
rm -rf "$REPO"

# ---- 사용자의 무관한 staged 변경이 lifecycle 우회 커밋에 딸려가지 않는가 ----
# 각 케이스는 rc·기대 커밋 생성·사용자 파일 제외·index 보존·안내를 동일 실행에서 확인한다.

# (a) promote
# 「기본 브랜치 metadata 커밋」·「우회 범위 안내」 단언은 제거했습니다 — promote 는 기본
# 브랜치에 커밋하지 않고, 그래서 hook 우회도 하지 않습니다(fr 브랜치 커밋은 원래 우회
# 대상이 아닙니다). 이 케이스가 지키려던 실질(무관한 staged 변경이 promote 의 커밋에
# 딸려가지 않고 index 에 그대로 남는가)은 그대로 둡니다.
REPO="$(setup_repo)"
install_blocking_pre_commit "$REPO"
( cd "$REPO" && mkdir -p src && echo "user work" > src/app.js && git add src/app.js )
sp_rc=0
sp_out="$( run_promote "$REPO" --short-title test-stgp --size small --no-worktree 2>&1 )" || sp_rc=$?
[[ "$sp_rc" -eq 0 ]] \
  && pass "staged/promote: rc=0" || fail "staged/promote: rc=$sp_rc — $sp_out"
( cd "$REPO" && git log fr/test-stgp --oneline -10 | out_has "test-stgp 작업 착수" ) \
  && pass "staged/promote: fr 브랜치 승격 커밋 생성" || fail "staged/promote: 승격 커밋 부재"
( cd "$REPO" && git log fr/test-stgp -1 --name-only --format= | out_has "src/app.js" ) \
  && fail "staged/promote: 사용자 파일이 lifecycle 커밋에 포함됨" \
  || pass "staged/promote: 사용자 파일이 커밋에서 제외됨"
# index 보존은 promote 실행 "전체" 기준이다 — 승격 커밋이 pathspec 을 잃으면 남아 있던
# staged src/app.js 가 흡수되어 이 assertion 이 실패한다.
( cd "$REPO" && git diff --cached --name-only | out_has "src/app.js" ) \
  && pass "staged/promote: 사용자 staged 상태 보존" || fail "staged/promote: 사용자 staged 소실"
rm -rf "$REPO"

# (b) promote_rollback
# rollback 은 이제 어떤 커밋도 만들지 않습니다(되돌릴 상태는 지워질 worktree·branch 안에만
# 있습니다). 「lifecycle 커밋 생성」·「우회 범위 안내」 단언은 개념이 사라져 제거하고, 남은
# 실질인 **사용자 index 무손상**과 **기본 브랜치 무변경**을 세웁니다.
REPO="$(setup_repo)"
run_promote "$REPO" --short-title test-stgr --size small >/dev/null 2>&1
install_blocking_pre_commit "$REPO"
( cd "$REPO" && mkdir -p src && echo "user work" > src/app.js && git add src/app.js )
sr_tip="$( cd "$REPO" && git rev-parse main )"
sr_rc=0
sr_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task test-stgr 2>&1 )" || sr_rc=$?
[[ "$sr_rc" -eq 0 ]] \
  && pass "staged/rollback: rc=0" || fail "staged/rollback: rc=$sr_rc — $sr_out"
( cd "$REPO" && [[ "$(git rev-parse main)" == "$sr_tip" ]] ) \
  && pass "staged/rollback: 기본 브랜치 tip 불변 (커밋 없음)" || fail "staged/rollback: 기본 브랜치에 커밋이 생김"
( cd "$REPO" && git diff --cached --name-only | out_has "src/app.js" ) \
  && pass "staged/rollback: 사용자 staged 상태 보존" || fail "staged/rollback: 사용자 staged 소실"
rm -rf "$REPO"

# (c) archive
REPO="$(setup_repo)"
BARESA="$(mk_bare stga)"
( cd "$REPO" && git remote add origin "$BARESA" && git push -q origin main )
run_promote "$REPO" --short-title test-stga --size small --no-worktree >/dev/null 2>&1
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
# (2026-08-20 에 Step 2.5 증명 전제 확인이 이보다 앞에서 막았으나, 2026-09-03 에 아카이브
# 전수 검증 게이트를 걷어내면서 그 선행 확인도 함께 제거했다. 다시 git merge 의 거부가 중단 지점이다.)
# LC_ALL=C 고정: 아래 oracle 이 git 의 영문 오류 메시지를 판정에 쓰므로,
# 번역 locale 환경에서 거짓 실패하지 않도록 실행 locale 을 못박는다.
sa_out="$( cd "$REPO" && LC_ALL=C bash rd-workflow/scripts/lifecycle/archive.sh --task test-stga \
    --force-dirty --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || sa_rc=$?
# 중단 사유까지 확인한다 — rc != 0 만 보면 archive 가 다른 이유로 실패해도 통과해
# 통제군보다 약한 oracle 이 된다.
[[ "$sa_rc" -ne 0 ]] && printf '%s' "$sa_out" | out_has "would be overwritten by merge" \
  && printf '%s' "$sa_out" | out_has "merge 실패" \
  && pass "staged/archive: 무관 staged 상태에서 git merge 거부로 중단 (rc=$sa_rc)" \
  || fail "staged/archive: merge 단계 중단이 아님 (rc=$sa_rc) — $sa_out"
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
run_promote "$REPO" --short-title test-mskip --size small --no-worktree >/dev/null 2>&1
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
# 선행 수동 merge — 이것이 archive.sh 의 merge skip 분기를 트리거한다.
( cd "$REPO" && git merge --no-ff fr/test-mskip -m "manual merge" -q )
install_blocking_pre_commit "$REPO"
# 이 케이스가 지키려는 성질은 **`_lc_paths` 경로 한정**이다 — lifecycle 커밋에 무관한
# staged 파일이 섞이지 않는가. 어떤 파일을 staged 로 두는가는 그 성질을 관측하기 위한
# 수단이며, 수단은 증명 집합 **밖**(transient)이어야 한다.
#
# vehicle 은 `_lc_paths` 밖의 transient 파일이면 충분하다 (2026-09-03 에 아카이브 전수 검증
# 게이트를 걷어내면서, 그 게이트의 차단을 확인하던 선행 assertion 도 함께 제거했다).
MS_UNREL="rd-workflow-workspace/.lifecycle/unrelated_zzfx.log"
( cd "$REPO" && echo "user work" > "$MS_UNREL" && git add "$MS_UNREL" )
ms_rc=0
ms_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-mskip \
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

# ---- (제거) 「lifecycle 대상 변경이 없고 무관 staged 만 있을 때 rollback 이 lifecycle 커밋을
#      만들지 않는가」 ----
# 새 계약에서 개념 자체가 사라져 제거했습니다. rollback 은 **어떤 경우에도** 커밋을 만들지
# 않으므로(경로 한정 우회 커밋 자체가 없어졌습니다) "대상 변경이 없을 때만 커밋이 없다" 는
# 조건부 성질이 성립하지 않고, 남은 실질(기본 브랜치 tip 불변 + 사용자 staged 보존)은 바로
# 위 staged/rollback 케이스가 이미 봅니다 — 같은 사실을 두 경로로 확인하지 않습니다.

# ---- tracked legacy active-fr 의 삭제가 경로 한정 커밋으로 기록되는가 ----
REPO="$(setup_repo)"
BARELG="$(mk_bare legacy)"
( cd "$REPO" && git remote add origin "$BARELG" && git push -q origin main )
run_promote "$REPO" --short-title test-legacy --size small --no-worktree >/dev/null 2>&1
# promote 직후 현재 브랜치는 fr 이다 — 여기서 legacy 파일을 tracked 로 만든다
( cd "$REPO" && mkdir -p rd-workflow-workspace/.lifecycle \
    && echo "test-legacy" > rd-workflow-workspace/.lifecycle/active-fr \
    && git add rd-workflow-workspace/.lifecycle/active-fr \
    && git commit -q -m "legacy active-fr fixture" )
( cd "$REPO" && echo "ar" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
( cd "$REPO" && git switch main -q )
install_blocking_pre_commit "$REPO"
lg_rc=0
lg_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task test-legacy \
    --force-skip-review-check "통합 테스트 fixture" 2>&1 )" || lg_rc=$?
[[ "$lg_rc" -eq 0 ]] \
  && pass "legacy: archive rc=0" || fail "legacy: archive rc=$lg_rc — $lg_out"
( cd "$REPO" && git log main -1 --diff-filter=D --name-only --format= | out_has "active-fr" ) \
  && pass "legacy: active-fr 삭제가 lifecycle 커밋에 기록됨" \
  || fail "legacy: 삭제 미기록 — partial commit 의 삭제분 전제 위반"
rm -rf "$REPO" "$BARELG"

# === Scenario: 하위 디렉터리 호출 거부 ===
echo "== scenario: 하위 디렉터리 archive 호출 거부 =="

# --- (c) 하위 디렉터리 호출은 merge 이전에 거부된다 (실제 동작 고정) ---
# turn 006 이 "nested 호출에서 rollback clean 판정이 저장소 전체를 못 본다" 를 지적했다.
# 판정 범위 문제 자체는 사실이라 `git -C "$CURRENT_WT"` 로 고쳤지만, **그 경로는 현재
# 도달 불가**다 — `_state_common.sh` 의 TASK_STATE_PATH 가 `${project_root:-$PWD}` 로
# 해석되는데 archive.sh 는 그 파일을 source 한 **뒤에** project_root 를 채우므로, nested
# 호출은 metadata 를 못 찾고 `active fr 없음` 으로 merge 훨씬 전에 끝난다.
# 여기서는 그 **실제 동작**을 고정한다: nested 호출이 아무것도 건드리지 않고 거부되는 것.
# 이 단언이 깨지면(= nested 호출이 진행되면) rollback 판정 범위가 즉시 실제 위험이 되므로,
# 그때 FR `archive-cwd-dependent-state-path` 의 처방을 함께 넣어야 한다.
#
# 2026-09-16 (final diff review F2): 대상 판정이 git 대조로 정확해지면서 nested 호출도
# fr tip 으로 대상을 찾아내게 됐다 — "metadata 를 못 읽어 우연히 멈춘다" 는 전제가
# 사라졌다. 그래서 archive.sh 가 **저장소 루트가 아닌 cwd 를 명시적으로 거부**하도록
# 바꿨고, 이 시나리오는 그 거부를 고정한다. 검사 대상(아무것도 건드리지 않고 거부)은
# 그대로이고 종료 사유 문구만 바뀐다.
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
printf '%s' "$nst_out" | out_has "저장소 루트에서 실행하십시오" \
  && pass "nested/archive: 저장소 루트 요구로 조기 종료 (merge 이전)" \
  || fail "nested/archive: 다른 사유로 종료 — rollback 판정 범위가 실제 위험이 된다: $nst_out"
[[ "$main_before" == "$( cd "$REPO" && git rev-parse HEAD )" ]] \
  && pass "nested/archive: main HEAD 불변" || fail "nested/archive: main 이 전진함"
[[ -z "$( cd "$REPO" && git status --porcelain )" ]] \
  && pass "nested/archive: 워킹트리 무변경" || fail "nested/archive: 워킹트리가 변경됨"
rm -rf "$REPO"

# --- promote --size (AC 1~6, 5-1) ---
# setup_repo() 는 fixture 안에 _ROOT_FILES/ 의 lifecycle·hooks 스크립트를 복사하고,
# run_promote() 는 그 사본을 상대 경로로 실행한다. 두 헬퍼를 그대로 재사용하면
# project_root 가 fixture 로 잡히므로 실제 작업공간이 안전하다.
echo "== scenario: promote --size 시작 상태 계약 =="

# 값 비교 단언 — 이 파일의 pass/fail 카운터에 얹는다. 기대·실측을 함께 남겨야
# 실패 시 어느 쪽이 어긋났는지 로그만으로 판정할 수 있다.
assert_eq() {  # assert_eq <actual> <expected> <desc>
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected=[$2] got=[$1])"; fi
}

sz_status() { awk -F= '$1=="status"{print $2}' "$1/rd-workflow-workspace/.lifecycle/task-state"; }
sz_prepare() { # sz_prepare <repo> — task-state 와 REQUEST 를 시작 상태로 맞춘다
  local d="$1"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' \
    > "$d/rd-workflow-workspace/.lifecycle/task-state"
  printf '# Change Request\n\n## Source FR\n-\n' > "$d/REQUEST.md"
  ( cd "$d" && git add -A && git commit -qm prep >/dev/null 2>&1 || true )
}

# 실제 작업공간 불변 확인용 기준선 (아래 케이스 전체가 끝난 뒤 대조한다)
SZ_GUARD_BEFORE="$(cd "$PROJECT_ROOT" && git status --porcelain | LC_ALL=C sort)"

# (1) --size large → 대기 중, 이후 첫 전이가 --force 없이 성공 (AC 1)
SZ1="$(setup_repo)"; sz_prepare "$SZ1"
run_promote "$SZ1" --short-title szt --no-worktree --size large >/dev/null 2>&1
assert_eq "$(sz_status "$SZ1")" "대기 중" "promote --size large → 대기 중"
# rd 와 그 의존을 fixture 에 넣고 사본으로 전이를 시험한다
cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/rd \
   "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_task_common.sh "$SZ1/rd-workflow/scripts/"
( cd "$SZ1" && bash rd-workflow/scripts/rd task set-status "REQUEST review 대기" ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "promote --size large 후 첫 전이가 --force 없이 성공"

# (2) --size small → 구현 중 (AC 2)
SZ2="$(setup_repo)"; sz_prepare "$SZ2"
run_promote "$SZ2" --short-title szt --no-worktree --size small >/dev/null 2>&1
assert_eq "$(sz_status "$SZ2")" "구현 중" "promote --size small → 구현 중"

# (3) 무인자 = 의도적 중단 + 두 값 안내 (AC 3·6b)
SZ3="$(setup_repo)"; sz_prepare "$SZ3"
sz3_out="$(run_promote "$SZ3" --short-title szt --no-worktree 2>&1)" && rc=0 || rc=1
assert_eq "$rc" "1" "promote: --size/--status 미지정은 멈춘다"
# 판정은 substring 으로 한다. `printf ... | grep -q` 는 grep 이 첫 매치에서 종료할 때
# 상류가 SIGPIPE(141) 로 죽고 pipefail 이 이를 파이프라인 실패로 전파해 역으로 실패한다
# (이 파일 상단이 out_has 를 둔 이유). 출력 길이·버퍼링이 바뀌면 flaky 해진다.
[[ "$sz3_out" == *large* && "$sz3_out" == *small* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: 미지정 메시지에 두 허용값"
assert_eq "$(sz_status "$SZ3")" "대기 중" "promote: 미지정 시 상태 미변경"

# (4) --size + --status 충돌 (AC 4)
SZ4="$(setup_repo)"; sz_prepare "$SZ4"
run_promote "$SZ4" --short-title szt --no-worktree --size large --status "구현 중" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "promote: --size 와 --status 동시 지정은 멈춘다"
assert_eq "$(sz_status "$SZ4")" "대기 중" "promote: 충돌 시 상태 미변경"

# (5) canonical 밖 --status 거부 (AC 5)
SZ5="$(setup_repo)"; sz_prepare "$SZ5"
run_promote "$SZ5" --short-title szt --no-worktree --status "구현중" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "promote: canonical 밖 --status 는 거부된다"
assert_eq "$(sz_status "$SZ5")" "대기 중" "promote: 잘못된 --status 시 상태 미변경"

# (6) 허용값 밖 --size 거부 (AC 5-1)
SZ6="$(setup_repo)"; sz_prepare "$SZ6"
sz6_out="$(run_promote "$SZ6" --short-title szt --no-worktree --size medium 2>&1)" && rc=0 || rc=1
assert_eq "$rc" "1" "promote: 허용값 밖 --size 는 거부된다"
[[ "$sz6_out" == *large* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: --size 오류에 허용값 안내"
assert_eq "$(sz_status "$SZ6")" "대기 중" "promote: 잘못된 --size 시 상태 미변경"

# (7) 기존 canonical --status 호출은 유지 (AC 6a)
SZ7="$(setup_repo)"; sz_prepare "$SZ7"
run_promote "$SZ7" --short-title szt --no-worktree --status "spec/plan 작성 중" >/dev/null 2>&1
assert_eq "$(sz_status "$SZ7")" "spec/plan 작성 중" "promote: 기존 canonical --status 호출은 그대로 동작"

# (8) 값 누락은 usage 계약으로 처리된다 — 내부 Bash 오류가 아니다
SZ8="$(setup_repo)"; sz_prepare "$SZ8"
sz8_out="$(run_promote "$SZ8" --short-title szt --no-worktree --size 2>&1)" && rc=0 || rc=1
assert_eq "$rc" "1" "promote: bare --size 는 멈춘다"
[[ "$sz8_out" != *"unbound variable"* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: bare --size 가 내부 Bash 오류를 노출하지 않는다"
[[ "$sz8_out" == *large* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: bare --size 메시지에 허용값"
assert_eq "$(sz_status "$SZ8")" "대기 중" "promote: bare --size 시 상태 미변경"

# (9) --status 도 대칭으로 처리한다 (같은 파서를 손대는 범위)
SZ9="$(setup_repo)"; sz_prepare "$SZ9"
sz9_out="$(run_promote "$SZ9" --short-title szt --no-worktree --status 2>&1)" && rc=0 || rc=1
assert_eq "$rc" "1" "promote: bare --status 는 멈춘다"
[[ "$sz9_out" != *"unbound variable"* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: bare --status 가 내부 Bash 오류를 노출하지 않는다"
assert_eq "$(sz_status "$SZ9")" "대기 중" "promote: bare --status 시 상태 미변경"

# (10) 실제 작업공간이 변하지 않았다 — fixture 오조준 회귀 방지
assert_eq "$(cd "$PROJECT_ROOT" && git status --porcelain | LC_ALL=C sort)" "$SZ_GUARD_BEFORE" \
  "promote --size 케이스가 실제 작업공간을 건드리지 않았다"

rm -rf "$SZ1" "$SZ2" "$SZ3" "$SZ4" "$SZ5" "$SZ6" "$SZ7" "$SZ8" "$SZ9"

# --- promote 루트 고정 + REQUEST 부재 (AC 19·20·21) ---
# --size 케이스와 같은 원칙이다 — setup_repo·run_promote 를 재사용해 fixture 안 사본을
# 실행한다. 이 절은 루트 판정 자체를 시험하므로 실제 저장소의 promote.sh 를 절대 경로로
# 부르면 그 호출이 작업공간의 task-state·CURRENT_TASK·git 을 바꾼다.
echo "== scenario: promote 기준 위치 고정과 REQUEST 부재 =="

pr_field() { awk -F= -v k="$2" '$1==k{print $2}' "$1/rd-workflow-workspace/.lifecycle/task-state"; }
pr_prepare() { # pr_prepare <repo> [--no-request]
  local d="$1" no_req="${2:-}"
  mkdir -p "$d/rd-workflow-workspace/backlog/items" "$d/sub/deeper"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' \
    > "$d/rd-workflow-workspace/.lifecycle/task-state"
  printf '# x\n- status: idea\n' > "$d/rd-workflow-workspace/backlog/items/2026-01-01-x.md"
  if [[ "$no_req" == "--no-request" ]]; then
    rm -f "$d/REQUEST.md"
  else
    printf '# Change Request\n\n## Source FR\nrd-workflow-workspace/backlog/items/2026-01-01-x.md\n' > "$d/REQUEST.md"
  fi
  ( cd "$d" && git add -A && git commit -qm prep >/dev/null 2>&1 || true )
}

PR_GUARD_BEFORE="$(cd "$PROJECT_ROOT" && git status --porcelain | LC_ALL=C sort)"

# (1) 하위 디렉터리 호출이 REQUEST·Source FR 을 루트 호출과 동일하게 해석 (AC 19)
PR1="$(setup_repo)"; pr_prepare "$PR1"
# 종료 코드를 삼키지 않고 단언한다. `set -e` 아래에서 무방비로 두면 실패가 FAIL 이 아니라
# 스위트 중단으로 나타나 이후 케이스가 아예 실행되지 않는다.
( cd "$PR1/sub/deeper" && bash ../../rd-workflow/scripts/lifecycle/promote.sh \
    --short-title prt --no-worktree --size large ) >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "0" "promote: 하위 디렉터리 호출이 성공한다"
assert_eq "$(pr_field "$PR1" source-fr)" "rd-workflow-workspace/backlog/items/2026-01-01-x.md" \
  "promote: 하위 디렉터리 호출도 Source FR 을 해석한다"
assert_eq "$(pr_field "$PR1" status)" "대기 중" "promote: 하위 디렉터리 호출이 정본에 기록한다"
if [[ -e "$PR1/sub/deeper/rd-workflow-workspace" ]]; then
  assert_eq "1" "0" "promote: 하위 cwd 아래에 상태 트리가 생기지 않는다"
else
  assert_eq "0" "0" "promote: 하위 cwd 아래에 상태 트리가 생기지 않는다"
fi

# (2) REQUEST 부재 + --source-fr 없음 = hard error, 무변경 (AC 20)
#
# 왜 fr-branch 하나로는 부족한가 — `fr-branch=null` 만 보면 status·source-fr·short-title·
# CURRENT_TASK·HEAD·branch 가 모두 바뀌어도 통과한다. fail-closed 계약은 "아무것도
# 쓰이지 않았다" 이므로 그 전부를 단언한다. 기존 Source FR 실패 회귀가 쓰는 패턴이다.
#
# --size small 을 쓰는 것도 의도적이다. 초기 status 가 `대기 중` 이므로 목표값이
# `구현 중` 이어야 조기 쓰기가 드러난다. --size large 는 목표와 초기값이 같아
# status 쓰기가 일어나도 단언에 걸리지 않는다.
PR2="$(setup_repo)"; pr_prepare "$PR2" --no-request
PR2_STATE_BEFORE="$(cat "$PR2/rd-workflow-workspace/.lifecycle/task-state")"
PR2_MIRROR_BEFORE="$(cat "$PR2/CURRENT_TASK.md")"
PR2_HEAD_BEFORE="$(cd "$PR2" && git rev-parse HEAD)"
PR2_BRANCH_BEFORE="$(cd "$PR2" && git branch --format='%(refname:short)' | LC_ALL=C sort)"

pr2_out="$(run_promote "$PR2" --short-title prt --no-worktree --size small 2>&1)" && rc=0 || rc=1
assert_eq "$rc" "1" "promote: REQUEST 부재는 hard error"
assert_eq "$(cat "$PR2/rd-workflow-workspace/.lifecycle/task-state")" "$PR2_STATE_BEFORE" \
  "promote: REQUEST 부재 시 task-state 가 바이트 단위로 불변"
assert_eq "$(cat "$PR2/CURRENT_TASK.md")" "$PR2_MIRROR_BEFORE" \
  "promote: REQUEST 부재 시 CURRENT_TASK 미러가 바이트 단위로 불변"
assert_eq "$(cd "$PR2" && git rev-parse HEAD)" "$PR2_HEAD_BEFORE" \
  "promote: REQUEST 부재 시 커밋이 생기지 않는다"
assert_eq "$(cd "$PR2" && git branch --format='%(refname:short)' | LC_ALL=C sort)" "$PR2_BRANCH_BEFORE" \
  "promote: REQUEST 부재 시 fr 브랜치가 생기지 않는다"

# (3) 부재 메시지가 값 해석 실패와 구분되고 복구 선택지를 보여준다 (AC 21)
# 판정은 substring 으로 한다 (pipefail + SIGPIPE 회피, 이 파일 상단 out_has 주석 참조)
[[ "$pr2_out" == *"REQUEST.md"* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: 부재 메시지에 누락 경로"
[[ "$pr2_out" == *"--source-fr -"* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: 부재 메시지에 'FR 없음' 선택지"
# 값 해석 실패 전용 문구가 섞이면 두 사유가 구분되지 않는다
[[ "$pr2_out" != *"해석할 수 없어"* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: 부재 메시지가 값 해석 실패 문구와 구분된다"

# (4) REQUEST 부재라도 --source-fr 명시하면 진행 (AC 20, task-state-guide.md:60 계약)
PR4="$(setup_repo)"; pr_prepare "$PR4" --no-request
run_promote "$PR4" --short-title prt --no-worktree --size large \
  --source-fr rd-workflow-workspace/backlog/items/2026-01-01-x.md >/dev/null 2>&1
assert_eq "$(pr_field "$PR4" source-fr)" "rd-workflow-workspace/backlog/items/2026-01-01-x.md" \
  "promote: --source-fr 명시 시 REQUEST 부재와 무관하게 진행"

# (5) REQUEST 존재 + 값 '-' = 정상 진행 (AC 20)
PR5="$(setup_repo)"; pr_prepare "$PR5"
printf '# Change Request\n\n## Source FR\n-\n' > "$PR5/REQUEST.md"
( cd "$PR5" && git add -A && git commit -qm dash >/dev/null 2>&1 || true )
run_promote "$PR5" --short-title prt --no-worktree --size large >/dev/null 2>&1
assert_eq "$(pr_field "$PR5" source-fr)" "-" "promote: REQUEST 의 '-' 는 FR 없음으로 정상 진행"

# (6) 마커 없는 배치에서 promote 도 멈춘다 (AC 19 — rd 와 동일 fail-closed 계약)
#
# 메시지만 확인하면 계약의 절반이다. AC 19 가 rd 와 동일한 fail-closed 라면
# "파일을 하나도 만들지 않는다" 와 의도한 exit code 도 함께 고정해야 한다.
PR6="$(mktemp -d)" || { echo "test_integration.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$PR6" && -d "$PR6" ]] || { echo "test_integration.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
PR6="$(cd "$PR6" && pwd -P)"
mkdir -p "$PR6/rd-workflow/scripts/lifecycle" "$PR6/rd-workflow/scripts/hooks"
cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/lifecycle/*.sh "$PR6/rd-workflow/scripts/lifecycle/"
cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/hooks/*.sh "$PR6/rd-workflow/scripts/hooks/"
cp "$PROJECT_ROOT"/_ROOT_FILES/rd-workflow/scripts/_state_common.sh "$PR6/rd-workflow/scripts/"
PR6_FILES_BEFORE="$(find "$PR6" -type f | LC_ALL=C sort)"

# 종료 코드를 보존하면서 set -e 를 피한다 — `cmd; rc=$?` 는 set -e 아래에서
# 첫 실패 즉시 스위트를 끝내므로 exit 3 을 관측할 기회가 없다.
pr6_out="$(bash "$PR6/rd-workflow/scripts/lifecycle/promote.sh" \
  --short-title x --no-worktree --size large 2>&1)" && pr6_rc=0 || pr6_rc=$?
assert_eq "$pr6_rc" "3" "promote: 마커 없는 배치는 exit 3 (rd 와 동일 코드)"
[[ "$pr6_out" == *"프로젝트 루트"* ]] && rc2=0 || rc2=1
assert_eq "$rc2" "0" "promote: 마커 없는 배치 메시지에 루트 미확정 사유"
assert_eq "$(find "$PR6" -type f | LC_ALL=C sort)" "$PR6_FILES_BEFORE" \
  "promote: 마커 없는 배치는 파일을 0개 만든다"
if [[ -e "$PR6/rd-workflow-workspace" ]]; then
  assert_eq "1" "0" "promote: 마커 없는 배치가 상태 트리를 만들지 않는다"
else
  assert_eq "0" "0" "promote: 마커 없는 배치가 상태 트리를 만들지 않는다"
fi
rm -rf "$PR6"

# (7) 진행 중 작업의 rerun 계약 — **무변경 거부**
#
# 구 계약에서 rerun 은 "권위(task-state)를 읽어 미러(CURRENT_TASK.md)를 되살리는" 복구
# 경로였고, (a)~(m) 13 케이스가 그 복구의 fail-closed 성질(실패 시 미러 byte 불변·worktree
# 미생성·복구 안내 문구·안내 명령의 대상 바인딩 등)을 고정했습니다. **재설계로 그 복구
# 경로 자체가 사라졌습니다** — 살아 있는 worktree 를 가진 작업의 rerun 은 D11 이
# `duplicate` 로 판정해 즉시 무변경 거부하므로, 권위를 읽어 미러를 고칠 자리가 없습니다
# (promote.sh 에 그 검증·안내 문구가 더 이상 존재하지 않습니다). 13 케이스가 공통으로
# 지키려던 실질만 새 계약의 형태로 옮깁니다:
#   ① 거부되고, 권위·미러·worktree 목록·HEAD 중 어느 것도 바뀌지 않는다
#   ② 미러가 어긋나 있어도 거부 경로가 미러를 덮어쓰지 않는다
#   ③ worktree 가 사라진 작업의 재부착(resume)은 성공하고 진행 단계를 되돌리지 않는다
#
# **worktree 경로로 시험한다.** `--no-worktree` 는 기본 브랜치 체크아웃에서만 허용되므로
# (첫 착수가 공유 트리를 fr 로 바꿔 놓는다) 그쪽으로는 이 계약에 도달하지 못한다.
PR7="$(setup_repo)"; pr_prepare "$PR7"
# `$PR7` 형제 경로로 잡는다 — setup_repo 가 `pwd -P` 로 canonical 화한 값이라
# macOS 의 /var → /private/var 심링크 때문에 metadata 저장값과 인자가 갈리지 않는다.
PR7_WT="${PR7}-wt"
run_promote "$PR7" --short-title prt --worktree-path "$PR7_WT" --size large >/dev/null 2>&1
assert_eq "$([[ -d "$PR7_WT" ]] && echo yes || echo no)" "yes" "promote rerun: 사전 조건(worktree 생성)"

# 진행을 직접 만든다 — fixture 에는 `rd` 가 없다(setup_repo 는 lifecycle·hooks·_state_common
# 만 복사). **권위는 대상 worktree 의 task-state** 이므로 케이스마다 그것을 조작한다.
pr7_wt_status() { awk '/^## Status/{f=1;next} f && /^[^#]/{print;exit}' "$PR7_WT/CURRENT_TASK.md"; }
pr7_wt_state() { awk -F= '$1=="status"{sub(/^[^=]+=/,"");print;exit}' \
  "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state"; }
pr7_set() { # pr7_set <권위값> <미러값> — 대상 worktree 의 두 파일을 각각 지정
  sed -i.bak "s/^status=.*/status=$1/" "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state"
  rm -f "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state.bak"
  awk -v v="$2" '/^## Status/{print; f=1; next} f && /^[^#]/{print v; f=0; next} {print}' \
    "$PR7_WT/CURRENT_TASK.md" > "$PR7_WT/.ct.tmp" && mv "$PR7_WT/.ct.tmp" "$PR7_WT/CURRENT_TASK.md"
  ( cd "$PR7_WT" && git add CURRENT_TASK.md rd-workflow-workspace/.lifecycle/task-state \
      && git commit -qm "case" >/dev/null 2>&1 || true )
}

# (a) 진행 중 작업의 rerun — 무변경 거부
pr7_set "검증 중" "검증 중"
PR7A_AUTH_BEFORE="$(cat "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state")"
PR7A_MIRROR_BEFORE="$(cat "$PR7_WT/CURRENT_TASK.md")"
PR7A_WTLIST_BEFORE="$(cd "$PR7" && git worktree list --porcelain | LC_ALL=C sort)"
PR7A_HEAD_BEFORE="$(cd "$PR7_WT" && git rev-parse HEAD)"
pr7a_out="$(run_promote "$PR7" --short-title prt --worktree-path "$PR7_WT" --size large 2>&1)" \
  && pr7a_rc=0 || pr7a_rc=$?
assert_eq "$pr7a_rc" "1" "promote rerun(a): 진행 중 작업의 rerun 은 거부된다"
[[ "$pr7a_out" == *"이미 진행 중"* ]] && rc7=0 || rc7=1
assert_eq "$rc7" "0" "promote rerun(a): 거부 사유가 '이미 진행 중' 임을 알린다"
assert_eq "$(cat "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state")" "$PR7A_AUTH_BEFORE" \
  "promote rerun(a): 권위 byte 불변"
assert_eq "$(cat "$PR7_WT/CURRENT_TASK.md")" "$PR7A_MIRROR_BEFORE" \
  "promote rerun(a): 미러 byte 불변"
assert_eq "$(cd "$PR7" && git worktree list --porcelain | LC_ALL=C sort)" "$PR7A_WTLIST_BEFORE" \
  "promote rerun(a): worktree 목록 불변"
assert_eq "$(cd "$PR7_WT" && git rev-parse HEAD)" "$PR7A_HEAD_BEFORE" "promote rerun(a): HEAD 불변"

# (b) 미러가 권위와 어긋난 상태여도 거부 경로가 미러를 덮어쓰지 않는다.
#     (구 (c)(e)(h) 의 "실패 시 미러 byte 불변" 이 새 계약에서 살아남는 자리)
pr7_set "검증 중" "대기 중"
PR7B_MIRROR_BEFORE="$(cat "$PR7_WT/CURRENT_TASK.md")"
pr7b_out="$(run_promote "$PR7" --short-title prt --worktree-path "$PR7_WT" --size large 2>&1)" \
  && pr7b_rc=0 || pr7b_rc=$?
assert_eq "$pr7b_rc" "1" "promote rerun(b): drift 상태의 rerun 도 거부된다"
assert_eq "$(pr7_wt_state)" "검증 중" "promote rerun(b): 권위 불변"
assert_eq "$(cat "$PR7_WT/CURRENT_TASK.md")" "$PR7B_MIRROR_BEFORE" \
  "promote rerun(b): 어긋난 미러도 덮어쓰지 않는다 (baseline 초기화 없음)"

# (c) worktree 가 사라진 작업의 rerun 은 재부착(resume)으로 성공하고, 진행 단계를
#     시작 상태(`--size large` = `대기 중`)로 되돌리지 않는다.
pr7_set "검증 중" "검증 중"
( cd "$PR7" && git worktree remove --force "$PR7_WT" >/dev/null 2>&1 || true )
assert_eq "$([[ -e "$PR7_WT" ]] && echo yes || echo no)" "no" "promote rerun(c): 사전 조건(worktree 제거)"
pr7c_out="$(run_promote "$PR7" --short-title prt --worktree-path "$PR7_WT" --size large 2>&1)" \
  && pr7c_rc=0 || pr7c_rc=$?
[[ "$pr7c_rc" == "0" ]] || printf '  rerun(c) out: %s\n' "$pr7c_out" >&2
assert_eq "$pr7c_rc" "0" "promote rerun(c): worktree 부재 작업의 재부착은 성공한다"
assert_eq "$([[ -d "$PR7_WT" ]] && echo yes || echo no)" "yes" "promote rerun(c): worktree 재생성"
assert_eq "$(pr7_wt_state)" "검증 중" "promote rerun(c): 권위 단계 보존"
assert_eq "$(pr7_wt_status)" "검증 중" "promote rerun(c): 미러 단계 보존 (회귀 없음)"
pr7_set "검증 중" "검증 중"

# --- D12: source-fr divergence (change spec D12-4, AC 29·30) ---
#
# 권위 파일이 사라진 뒤 index 에서 되살리면 `source-fr` 가 승격 시점 값으로 돌아간다.
# 실행은 성공하므로 유실이 드러나지 않고 archive 가 **다른 FR** 을 done 처리한다
# (final diff review Turn 016 Finding 1). 미러가 `## Source FR` 을 담게 되어 이제
# 대조가 가능하므로, promote 는 어느 쪽이 최신인지 고르지 않고 **멈춘다.**
PR7_SFR_OLD="rd-workflow-workspace/backlog/items/2026-01-01-old.md"
PR7_SFR_NEW="rd-workflow-workspace/backlog/items/2026-02-02-new.md"
pr7_auth_sfr() { awk -F= '$1=="source-fr"{sub(/^[^=]+=/,"");print;exit}' \
  "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state"; }
pr7_mirror_sfr() { awk '$0=="## Source FR"{f=1;next} f && /^[^#]/{print;exit}' \
  "$PR7_WT/CURRENT_TASK.md"; }
pr7_rd() { ( cd "$PR7_WT" && bash rd-workflow/scripts/rd "$@" ); }

# 씨앗: 양쪽을 OLD 로 맞춰 커밋한다 (= index 값)
# `set-source-fr` 는 change-spec AC C-13 에 따라 파일 실존을 요구하므로(오등록이 마감
# 시점에야 드러나는 것을 막기 위함) 픽스처 items 파일을 실제로 만든다.
mkdir -p "$PR7_WT/rd-workflow-workspace/backlog/items"
printf -- '# old\n- status: validated\n' > "$PR7_WT/$PR7_SFR_OLD"
printf -- '# new\n- status: validated\n' > "$PR7_WT/$PR7_SFR_NEW"
pr7_set "검증 중" "검증 중"
pr7_rd task set-source-fr "$PR7_SFR_OLD" >/dev/null 2>&1
( cd "$PR7_WT" && git add CURRENT_TASK.md rd-workflow-workspace/.lifecycle/task-state \
    && git commit -qm "d12-seed" >/dev/null 2>&1 || true )
assert_eq "$(pr7_mirror_sfr)" "$PR7_SFR_OLD" "promote D12: 씨앗 — 미러에 source-fr 가 보인다"

# (n)(o) 는 제거했습니다 — 새 계약에서 개념이 사라졌습니다.
# 두 케이스는 **살아 있는 worktree 를 둔 채** source-fr divergence 를 만들고, promote 가
# 권위·미러 두 값을 출력해 복구 절차(checkout → set-source-fr → 재시도)를 안내하는 것을
# 고정했습니다. 재설계 이후 살아 있는 worktree 의 rerun 은 D11 이 `duplicate`(또는 미커밋이면
# `divergent`)로 먼저 거부하므로 그 경로에 도달하지 않고, promote.sh 에 그 값 제시·복구 안내
# 문구도 더 이상 없습니다. divergence 를 실제로 판정하는 자리는 worktree 가 없는 재개(resume)
# 경로 하나이며, 그것은 아래 (p)(q) 가 그대로 봅니다.

# (p)(q) worktree 부재 경로 — **권위와 미러의 출처가 짝지어져야 한다**
#        (final diff review 9라운드 Finding 1)
#
# 권위를 브랜치 blob 에서 읽으면서 미러를 기본 worktree 파일에서 읽으면, 다른 git tree 의
# 두 파일을 비교하게 된다. 기본 worktree 미러는 보통 baseline `-` 이므로 **정상 rerun 이
# 거짓 divergence 로 막힌다.** 그래서 (p) 는 "정상인데 통과하는가", (q) 는 "브랜치 blob
# 안의 실제 divergence 를 잡는가" 를 각각 고정한다.

# 사전: 대상 브랜치의 권위·미러를 같은 non-'-' 값으로 커밋하고, 기본 worktree 미러는
#       baseline `-` 로 만들어 둔다 (짝짓지 않으면 이 조합에서 오판한다).
pr7_rd task set-source-fr "$PR7_SFR_NEW" >/dev/null 2>&1
( cd "$PR7_WT" && git add -A && git commit -qm "d12-pair-seed" >/dev/null 2>&1 || true )
if grep -qx -- '## Source FR' "$PR7/CURRENT_TASK.md"; then
  awk '$0=="## Source FR"{print; f=1; next} f && /^[^#]/{print "-"; f=0; next} {print}' \
    "$PR7/CURRENT_TASK.md" > "$PR7/.ct.tmp" && mv "$PR7/.ct.tmp" "$PR7/CURRENT_TASK.md"
else
  printf '\n## Source FR\n-\n' >> "$PR7/CURRENT_TASK.md"
fi
PR7P_BASE_SFR="$(awk '$0=="## Source FR"{f=1;next} f && /^[^#]/{print;exit}' "$PR7/CURRENT_TASK.md")"
assert_eq "$PR7P_BASE_SFR" "-" "promote D12(p): 사전 조건 — 기본 worktree 미러는 baseline '-'"
( cd "$PR7" && git worktree remove --force "$PR7_WT" >/dev/null 2>&1 || true )

# (p) 정상 rerun 은 통과해야 한다
pr7p_out="$(run_promote "$PR7" --short-title prt --worktree-path "$PR7_WT" --size large 2>&1)" \
  && pr7p_rc=0 || pr7p_rc=$?
assert_eq "$pr7p_rc" "0" "promote D12(p): worktree 부재 정상 rerun 은 성공한다 (거짓 divergence 없음)"
assert_eq "$(pr7_auth_sfr)" "$PR7_SFR_NEW" "promote D12(p): 대상 source-fr 가 보존된다"

# (q) 브랜치 blob 안의 실제 divergence 는 잡아야 한다 — 권위만 바꿔 커밋한 뒤 worktree 제거
sed -i.bak "s|^source-fr=.*|source-fr=$PR7_SFR_OLD|" \
  "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state"
rm -f "$PR7_WT/rd-workflow-workspace/.lifecycle/task-state.bak"
( cd "$PR7_WT" && git add rd-workflow-workspace/.lifecycle/task-state \
    && git commit -qm "d12-blob-divergence" >/dev/null 2>&1 || true )
( cd "$PR7" && git worktree remove --force "$PR7_WT" >/dev/null 2>&1 || true )
PR7Q_WTLIST="$(cd "$PR7" && git worktree list --porcelain | LC_ALL=C sort)"
PR7Q_HEAD="$(cd "$PR7" && git rev-parse --abbrev-ref HEAD)"
PR7Q_BRANCHES="$(cd "$PR7" && git branch --format='%(refname:short)' | LC_ALL=C sort)"
pr7q_out="$(run_promote "$PR7" --short-title prt --worktree-path "$PR7_WT" --size large 2>&1)" \
  && pr7q_rc=0 || pr7q_rc=$?
assert_eq "$pr7q_rc" "1" "promote D12(q): 브랜치 blob 안의 divergence 는 exit 1"
# 새 계약의 메시지는 두 값을 나열하는 대신 **대조할 두 출처**를 지목한다 — 어느 쪽이
# 최신인지 promote 가 고르지 않는다는 것이 이 판정의 핵심이기 때문이다.
[[ "$pr7q_out" == *"권위(task-state)와 미러(CURRENT_TASK.md)에서 다릅니다"* ]] && rc7q=0 || rc7q=1
assert_eq "$rc7q" "0" "promote D12(q): 사유가 권위·미러 divergence 임을 지목한다"
[[ "$pr7q_out" == *"git show fr/prt:"* ]] && rc7q2=0 || rc7q2=1
assert_eq "$rc7q2" "0" "promote D12(q): 대조할 두 blob 을 확인 명령으로 안내한다"
assert_eq "$([[ -e "$PR7_WT" ]] && echo yes || echo no)" "no" \
  "promote D12(q): 실패했으므로 worktree 를 만들지 않았다"
assert_eq "$(cd "$PR7" && git worktree list --porcelain | LC_ALL=C sort)" "$PR7Q_WTLIST" \
  "promote D12(q): worktree 목록 불변"
assert_eq "$(cd "$PR7" && git rev-parse --abbrev-ref HEAD)" "$PR7Q_HEAD" \
  "promote D12(q): HEAD 불변"
assert_eq "$(cd "$PR7" && git branch --format='%(refname:short)' | LC_ALL=C sort)" "$PR7Q_BRANCHES" \
  "promote D12(q): 브랜치 목록 불변"
# 이후 케이스를 위해 worktree 와 값을 복원한다
( cd "$PR7" && git worktree add "$PR7_WT" fr/prt >/dev/null 2>&1 || true )
pr7_rd task set-source-fr "$PR7_SFR_OLD" >/dev/null 2>&1
( cd "$PR7_WT" && git add -A && git commit -qm "d12-restore" >/dev/null 2>&1 || true )
pr7_set "검증 중" "검증 중"

# (r) 는 제거했습니다 — 새 계약에서 개념이 사라졌습니다.
# 이 케이스는 `worktree-path=null` 분기에서 promote 가 임시 트리 생성(mktemp)·정정 커밋·
# 임시 트리 제거로 이어지는 복구 **순서**를 안내하고, 그 순서를 출력에서 추출해 실행하면
# 재시도가 성공하는 것까지 고정했습니다. 재설계로 그 다단계 안내 자체가 promote.sh 에서
# 사라졌고(지금은 대조할 두 blob 만 지목합니다), `--no-worktree` 착수도 기본 브랜치
# 체크아웃에서만 허용되어 이 fixture 가 재현하던 배치가 성립하지 않습니다. divergence 를
# 무변경으로 막는다는 실질은 (q) 가 봅니다.

# (d) --status 경로도 같은 계약이다 — 임의 단계를 미러에 주입할 수 없어야 한다
pr7_set "검증 중" "검증 중"
pr7d_out="$(run_promote "$PR7" --short-title prt --worktree-path "$PR7_WT" --status "대기 중" 2>&1)" \
  && pr7d_rc=0 || pr7d_rc=$?
assert_eq "$pr7d_rc" "1" "promote rerun(d): --status 경로 rerun 도 거부된다"
assert_eq "$(pr7_wt_status)" "검증 중" "promote rerun(d): --status 로도 미러 불변 (임의 단계 주입 불가)"
( cd "$PR7" && git worktree remove --force "$PR7_WT" >/dev/null 2>&1 || true )

# (8) 실제 작업공간 불변
assert_eq "$(cd "$PROJECT_ROOT" && git status --porcelain | LC_ALL=C sort)" "$PR_GUARD_BEFORE" \
  "promote 루트·부재 케이스가 실제 작업공간을 건드리지 않았다"

rm -rf "$PR1" "$PR2" "$PR4" "$PR5" "$PR7"


echo "== scenario 20: 얹힌 커밋 검사 =="

# arc_setup — promote 를 마치고 fr 브랜치에 archive content 를 올린 repo 를 만든다.
# 반환: repo 경로. 호출측은 기본 브랜치로 돌아온 상태를 받는다.
#
# 재설계 이후 기본 착수는 worktree 격리다 — 기본 체크아웃($d)은 계속 기본 브랜치에 머물고
# fr 브랜치는 `$d/.worktrees/<slug>` 에 붙는다. 그래서 archive content 는 그 worktree 안에서
# 커밋한다(종전에는 `$d` 자체가 fr 로 넘어갔으므로 `$d` 에서 커밋하고 기본 브랜치로 되돌렸다).
arc_setup() {  # arc_setup <slug>
  local slug="$1" d out
  d="$(setup_repo main)"
  out="$(run_promote "$d" --short-title "$slug" --size large 2>&1)" \
    || { printf 'arc_setup(%s): run_promote 실패 — fixture 구성 중단: %s\n' "$slug" "$out" >&2; exit 1; }
  [[ -d "$d/.worktrees/$slug" ]] \
    || { printf 'arc_setup(%s): 착수 worktree 부재 — fixture 구성 중단\n' "$slug" >&2; exit 1; }
  (
    cd "$d/.worktrees/$slug"
    printf '# Change Request\n\n## Source FR\n-\n' > REQUEST.md
    mkdir -p rd-workflow-workspace/backlog/request-archive
    printf 'archived\n' > "rd-workflow-workspace/backlog/request-archive/x.md"
    bash rd-workflow/scripts/lifecycle/_emit_baseline_helper.sh 2>/dev/null \
      || ( . rd-workflow/scripts/lifecycle/_lifecycle_common.sh && emit_current_task_baseline > CURRENT_TASK.md )
    git add -A && git commit -q -m "docs: archive content"
  ) >/dev/null 2>&1 \
    || { printf 'arc_setup(%s): archive content 커밋 실패 — fixture 구성 중단\n' "$slug" >&2; exit 1; }
  echo "$d"
}

# arc_archive — archive 실행. stdout+stderr 를 합쳐 낸다. rc 는 별도로 잡는다.
arc_archive() {  # arc_archive <repo> [추가 인자...]
  local repo="$1"; shift
  ( cd "$repo" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
      --force-skip-review-check "통합 테스트 fixture" "$@" 2>&1 )
}

# arc_assert_block_notice — 사전 발행 차단의 사용자 안내 요건을 kind 별로 단언한다.
#
# 안전하게 막힌 경우에도 사용자는 발행 여부·변경 보존 여부·fr ref·다음 조치를 알아야
# 한다. git 오류로 막힌 갈래는 "위 커밋" 이 없으므로 보존 문구를 두 형태 중 하나로 본다
# (Turn 004 F5).
#
# **4번째 인자 kind** (기본값 commit). archive_block_notice 는 commit(기본)·unknown·
# content 세 갈래로 복구 절차 문구가 갈리고, "diff review" 는 commit·unknown 에서만,
# "baseline 상태" 는 content 에서만 나온다(상호 배타). 한쪽 문구의 유무만 보면 다른
# 쪽 문구가 나와도 통과해 버려 call-site 의 kind 를 고정하지 못한다(kind-permissive) —
# 실측: archive.sh:383 의 content 인자를 지워도(=Task 5 리뷰 조치 2 를 되돌려도)
# scenario 20 전체가 그대로 통과했다. 그래서 해당 갈래 문구가 있고 **반대 갈래 문구는
# 없어야** 함을 함께 확인한다.
#
# **commit 과 unknown 은 "diff review" 문구를 공유해 그것만으로는 서로 구분되지
# 않는다** — call-site 를 archive.sh 와 직접 대조해 실측한 결과, 회귀 8(baseline
# 커밋 미발견)·11(L1 rc 2)·23(L2 rc 2)·24(후행 L1 rc 2) 는 전부 archive.sh 가
# `archive_block_notice ... unknown` 으로 부르는 지점이다 — 실제로 "얹힌 커밋을
# 특정"하는 kind=commit(기본값) 호출부(`archive_extra_commits_check` 가 rc 1 을
# 낸 정상 차단, 회귀 3·4 가 유발하나 이 helper 로 단언하지 않는다)와는 다르다.
# 그래서 이 넷은 4번째 인자로 명시적으로 `unknown` 을 넘긴다(final review Minor M1
# 전에는 인자를 생략해 기본값 commit 으로 잘못 단언되고 있었다). content 는
# 회귀 22·25·26·26b·27·27b.
arc_assert_block_notice() {  # arc_assert_block_notice <label> <out> <fr_ref> [kind=commit]
  local label="$1" out="$2" fr="$3" kind="${4:-commit}"
  printf '%s' "$out" | out_has "tag 와 push 를 실행하지 않았습니다" \
    && pass "$label: tag·push 미실행 사실을 안내" || fail "$label: 발행 여부 안내 없음"
  printf '%s' "$out" | out_has "그대로 보존" \
    && pass "$label: 변경 보존 사실을 안내" || fail "$label: 보존 안내 없음"
  # 보존 문구가 "실행 전 상태" 라는 거짓 단정으로 읽히지 않아야 한다 (Turn 006 F2)
  printf '%s' "$out" | out_has "아무것도 바꾸지 않았습니다" \
    && fail "$label: 이력을 바꾸지 않았다는 거짓 단정" \
    || pass "$label: 실행 전 상태라고 단정하지 않음"
  printf '%s' "$out" | out_has "이력에 남아 있을 수 있습니다" \
    && pass "$label: 이번 실행이 만든 커밋의 잔존 가능성을 안내" \
    || fail "$label: 현재 이력 상태 안내 없음"
  printf '%s' "$out" | out_has "$fr" \
    && pass "$label: 정확한 fr ref 를 안내" || fail "$label: fr ref 없음"
  printf '%s' "$out" | out_has "복구 절차" \
    && pass "$label: 복구 절차를 안내" || fail "$label: 복구 절차 없음"
  if [[ "$kind" == "content" ]]; then
    printf '%s' "$out" | out_has "baseline 상태" \
      && pass "$label: (content 차단) baseline 로 되돌리는 절차를 안내" \
      || fail "$label: baseline 복구 절차 안내 없음"
    printf '%s' "$out" | out_has "diff review" \
      && fail "$label: content 차단인데 diff review(commit/unknown 전용 문구)가 나옴" \
      || pass "$label: diff review 문구가 섞이지 않음 (content 전용 절차)"
  else
    printf '%s' "$out" | out_has "diff review" \
      && pass "$label: diff review 를 거치라고 안내" \
      || fail "$label: diff review 안내 없음"
    printf '%s' "$out" | out_has "baseline 상태" \
      && fail "$label: commit/unknown 차단인데 baseline 상태(content 전용 문구)가 나옴" \
      || pass "$label: baseline 상태 문구가 섞이지 않음 (commit/unknown 전용 절차)"
  fi
  # commit·unknown 은 복구 절차(1~3) 문구가 같아 위 else 분기만으로는 call-site 의
  # kind 가 실제로 unknown 인지 commit 인지 구분하지 못한다 — archive.sh 에서 unknown
  # 인자를 지워도(=Task 2 리뷰 조치를 되돌려도) 회귀 8·11·23·24 가 그대로 통과하던
  # 결함(final review Minor M1)이 이 자리다. "판정할 수 없었습니다" 줄의 유무를
  # 양방향으로 단언해 kind 를 실제로 고정한다.
  if [[ "$kind" == "unknown" ]]; then
    printf '%s' "$out" | out_has "판정할 수 없었습니다" \
      && pass "$label: (unknown 차단) 판정 불능 고지" \
      || fail "$label: 판정 불능 고지 없음 (kind=unknown 배선 확인)"
  elif [[ "$kind" == "commit" ]]; then
    printf '%s' "$out" | out_has "판정할 수 없었습니다" \
      && fail "$label: commit 차단인데 판정 불능(unknown 전용) 문구가 나옴" \
      || pass "$label: 판정 불능 문구가 섞이지 않음 (commit 전용 절차, kind=commit 배선 확인)"
  fi
}

# 회귀 1 — merge 후 제품 코드 커밋이 얹힘 → 차단
_d="$(arc_setup test-block1)"
( cd "$_d" && git merge -q --no-ff fr/test-block1 -m "merge: test-block1" \
  && printf 'evil\n' > product.txt && git add product.txt && git commit -q -m "리뷰 안 된 수정" ) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 1: 제품 코드 커밋 얹힘 → 차단" || fail "회귀 1: 차단되지 않음 — $_out"
printf '%s' "$_out" | out_has "허용 경로 밖 변경" && pass "회귀 1: 사유 출력" || fail "회귀 1: 사유 미출력"
printf '%s' "$_out" | out_has "그대로 보존" && pass "회귀 1: 보존 사실 안내" || fail "회귀 1: 보존 안내 없음"
( cd "$_d" && [[ -z "$(git tag --list "fr/*/test-block1")" ]] ) && pass "회귀 1: tag 미생성" || fail "회귀 1: tag 생성됨"
rm -rf "$_d"

# 회귀 3 — 빈 커밋 → 차단
_d="$(arc_setup test-empty)"
( cd "$_d" && git merge -q --no-ff fr/test-empty -m "merge: test-empty" \
  && git commit -q --allow-empty -m "빈 커밋" ) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 3: 빈 커밋 → 차단" || fail "회귀 3: 차단되지 않음 — $_out"
rm -rf "$_d"

# 회귀 4 — 사람이 다른 브랜치를 merge → 차단
_d="$(arc_setup test-humanmerge)"
(
  cd "$_d"
  git merge -q --no-ff fr/test-humanmerge -m "merge: test-humanmerge"
  git checkout -q -b side && printf 'x\n' > side.txt && git add side.txt && git commit -q -m side
  git checkout -q main && git merge -q --no-ff side -m "사람이 merge"
) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 4: 사람 merge 커밋 → 차단" || fail "회귀 4: 차단되지 않음 — $_out"
rm -rf "$_d"

# 회귀 5 — 이번 실행이 merge 를 만든 정상 경로 → 통과
_d="$(arc_setup test-normal)"
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -eq 0 ]] && pass "회귀 5: 정상 경로 통과" || fail "회귀 5: 정상 경로가 실패 — $_out"
( cd "$_d" && [[ -n "$(git tag --list "fr/*/test-normal")" ]] ) && pass "회귀 5: tag 생성" || fail "회귀 5: tag 미생성"
rm -rf "$_d"

# 회귀 6 — fr 분기 이후 기본 브랜치가 전진한 이력 → 통과 (오탐 없음)
_d="$(arc_setup test-advance)"
( cd "$_d" && printf 'v2\n' > other.txt && git add other.txt && git commit -q -m "기본 브랜치 선행 작업" ) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -eq 0 ]] && pass "회귀 6: 분기 이후 선행 커밋은 오탐 없음" || fail "회귀 6: 오탐 발생 — $_out"
rm -rf "$_d"

# 회귀 2 — 허용 경로를 오염했다가 다음 커밋에서 baseline 으로 되돌림.
#   얹힌 커밋이 **실제로 존재**하되 최종 내용은 정상인 상태여야 한다.
#   baseline 을 baseline 으로 다시 쓰면 커밋이 생기지 않아 아무것도 검증하지 못한다.
_d="$(arc_setup test-metaonly)"
(
  cd "$_d"
  git merge -q --no-ff fr/test-metaonly -m "merge: test-metaonly"
  printf '# Current Task\n\n## Status\n오염된 상태\n' > CURRENT_TASK.md
  git add CURRENT_TASK.md && git commit -q -m "미러 오염"
  . rd-workflow/scripts/lifecycle/_lifecycle_common.sh
  emit_current_task_baseline > CURRENT_TASK.md
  git add CURRENT_TASK.md && git commit -q -m "미러 baseline 복구"
) >/dev/null 2>&1
# 얹힌 커밋이 실제로 2건 생겼는지 먼저 확인 — 그래야 이 회귀가 무언가를 검증한다
_extra="$( cd "$_d" && git rev-list --first-parent --count "fr/test-metaonly..HEAD" )" \
  || { printf '회귀 2: rev-list 실패 — fixture 구성 중단\n' >&2; exit 1; }
[[ "$_extra" -ge 2 ]] && pass "회귀 2: 얹힌 커밋이 실제로 존재 ($_extra 건)" || fail "회귀 2: 얹힌 커밋이 없어 무의미 ($_extra 건)"
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -eq 0 ]] && pass "회귀 2: 최종 내용이 baseline 이면 통과" || fail "회귀 2: 통과하지 못함 — $_out"
rm -rf "$_d"

# 회귀 12 — task-state 에 임의 키 주입 → 차단 (경로 판정은 통과, 내용 검증이 잡음)
_d="$(arc_setup test-inject)"
(
  cd "$_d"
  git merge -q --no-ff fr/test-inject -m "merge: test-inject"
  printf 'evil.key=주입\n' >> rd-workflow-workspace/.lifecycle/task-state
  git add rd-workflow-workspace/.lifecycle/task-state
  git commit -q -m "metadata-only 주입"
) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 12: task-state 임의 키 주입 → 차단" || fail "회귀 12: 차단되지 않음 — $_out"
printf '%s' "$_out" | out_has "소유 키 밖에서 달라졌습니다" && pass "회귀 12: 사유 출력" || fail "회귀 12: 사유 미출력"
rm -rf "$_d"

# 회귀 13 — --fr-branch 명시 + metadata 비활성으로 Step 4 skip → CURRENT_TASK.md 가
#            baseline 이 아니면 차단
_d="$(arc_setup test-skip4)"
(
  cd "$_d"
  git merge -q --no-ff fr/test-skip4 -m "merge: test-skip4"
  . rd-workflow/scripts/_state_common.sh
  state_write_fields "fr-branch=null"
  printf '# Current Task\n\n## Status\n구현 중\n' > CURRENT_TASK.md
  git add -A && git commit -q -m "metadata 비활성 + 미러 오염"
) >/dev/null 2>&1
_out="$(arc_archive "$_d" --fr-branch fr/test-skip4)" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 13: Step 4 skip + 미러 비baseline → 차단" || fail "회귀 13: 차단되지 않음 — $_out"
rm -rf "$_d"

# 회귀 7 — fast-forward 로 합쳐진 경우 fr tip 기준선
_d="$(arc_setup test-ff)"
( cd "$_d" && git merge -q --ff-only fr/test-ff ) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -eq 0 ]] && pass "회귀 7: fast-forward 는 fr tip 기준선으로 통과" || fail "회귀 7: 실패 — $_out"
rm -rf "$_d"

# 회귀 8 — 일치 merge 없고 fr tip 도 first-parent 체인에 없음 → 차단
#
# 단순히 main 에 무관한 커밋만 얹으면 이 상태를 만들 수 없다 — fr_branch 가 아직
# main 의 조상이 아니므로 archive.sh Step 3 의 자동 merge 가 그 자리에서 바로
# "p2==fr_tip" 조건을 만족하는 merge 를 새로 만들어 버려, 의도한 차단이 우회된다
# (실측 — 원래 fixture 는 정상 발행으로 끝났다). fr 을 **다른 브랜치(side)에서 먼저
# merge 하고, 그 side 를 main 에 merge** 하면 fr_branch 는 전체 그래프 기준으로는
# main 의 조상이라 Step 3 의 자동 merge 가 "이미 merge 됨 — skip" 으로 건너뛰지만,
# fr 을 데려온 실제 merge 커밋은 first-parent 체인 밖(side 의 두 번째 조상)에 있어
# archive_baseline_commit 의 두 판정 모두에 걸리지 않는다 — 이것이 진짜 "예상 밖
# 커밋 그래프" 다.
_d="$(arc_setup test-orphan)"
(
  cd "$_d"
  git checkout -q -b side
  git merge -q --no-ff fr/test-orphan -m "merge fr into side"
  git checkout -q main
  git merge -q --no-ff side -m "merge side into main (사람이 손으로)"
) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 8: merge 없고 체인에도 없으면 차단" || fail "회귀 8: 차단되지 않음 — $_out"
printf '%s' "$_out" | out_has "first-parent 이력에도 없습니다" && pass "회귀 8: 사유 출력" || fail "회귀 8: 사유 미출력"
arc_assert_block_notice "회귀 8" "$_out" "fr/test-orphan" unknown
( cd "$_d" && [[ -z "$(git tag --list "fr/*/test-orphan")" ]] ) && pass "회귀 8: tag 미생성" || fail "회귀 8: tag 생성됨"
rm -rf "$_d"

# 회귀 9 — fr tip 과 다른 브랜치를 함께 merge 한 octopus → **차단**
#
# octopus 를 기준선으로 인정하면 side 가 들여온 미리뷰 내용이 "기준선 이전" 으로
# 취급돼 검사 밖에 놓인다(실측: 얹힌 커밋 0건, side.txt 가 발행 트리에 존재).
_d="$(arc_setup test-octo)"
(
  cd "$_d"
  git checkout -q -b side && printf 'MIRIVIEW\n' > side.txt && git add side.txt && git commit -q -m "리뷰 안 된 side 작업"
  git checkout -q main
  git merge -q --no-ff side fr/test-octo -m "octopus"
) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 9: octopus 는 차단" || fail "회귀 9: 차단되지 않음 — $_out"
( cd "$_d" && [[ -z "$(git tag --list "fr/*/test-octo")" ]] ) \
  && pass "회귀 9: 미리뷰 side 내용이 tag 로 발행되지 않음" || fail "회귀 9: tag 생성됨 (미리뷰 내용 발행)"
rm -rf "$_d"

# 회귀 10 — 공백·따옴표 경로 커밋 → 정확 판정 (차단)
_d="$(arc_setup test-spacepath)"
( cd "$_d" && git merge -q --no-ff fr/test-spacepath -m "merge: test-spacepath" \
  && printf 'x\n' > "sp ace'q.txt" && git add -A && git commit -q -m "특수문자 경로" ) >/dev/null 2>&1
_out="$(arc_archive "$_d")" && _rc=0 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass "회귀 10: 공백·따옴표 경로도 정확 판정" || fail "회귀 10: 판정 실패 — $_out"
rm -rf "$_d"

echo "== scenario 21: fr 브랜치 등록 → 기본 브랜치 직접 행 추가 → archive 종착 (AC 13) =="
REPO="$(setup_repo)"
_IDX="rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
( cd "$REPO" && mkdir -p rd-workflow-workspace/backlog/items rd-workflow-workspace/raw-captures \
  && printf '# FR\n\n## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |\n|---|---|---|---|---|---|---|\n' > "$_IDX" \
  && : > rd-workflow-workspace/raw-captures/.gitkeep && git add -A && git commit -q -m "backlog 초기" )
run_promote "$REPO" --short-title test-reg --no-worktree --size small >/dev/null
# fr 브랜치에서 /fr add 쓰기 단계 모사 + helper
( cd "$REPO" && printf '| 2026-02-02 | reg-a | s | tooling | idea | - | [상세](items/2026-02-02-reg-a.md) |\n' >> "$_IDX" \
  && printf '# reg-a\n- status: idea\n' > rd-workflow-workspace/backlog/items/2026-02-02-reg-a.md \
  && printf -- '---\nstage: fr\n---\n' > rd-workflow-workspace/raw-captures/2026-02-02-fr-reg-a.md )
out="$(cd "$REPO" && bash rd-workflow/scripts/rd task fr-register --slug reg-a 2>&1)"
[[ "$out" == "result=committed branch=main"* ]] && pass "s21: fr 브랜치에서 등록 → main 커밋" || fail "s21: fr-register — $out"
# iteration commit (등록 파일이 fr 브랜치에도 실림 — 동일 내용)
( cd "$REPO" && echo impl > impl.txt && git add -A && git commit -q -m "구현" )
# 기본 브랜치에 다른 FR 행 직접 추가 (동시 등록 변형)
( cd "$REPO" && git switch -q main && printf '| 2026-02-03 | other-x | s | tooling | idea | - | [상세](items/2026-02-03-other-x.md) |\n' >> "$_IDX" \
  && printf '# other-x\n' > rd-workflow-workspace/backlog/items/2026-02-03-other-x.md && git add -A && git commit -q -m "docs: FR 등록 — other-x" && git switch -q fr/test-reg )
# archive content commit
( cd "$REPO" && echo "# archived" > REQUEST.md && git add REQUEST.md && git commit -q -m "archive content" )
arc_out="$( cd "$REPO" && git switch -q main && bash rd-workflow/scripts/lifecycle/archive.sh --task test-reg --no-remote --force-skip-review-check "통합 테스트 fixture" 2>&1 )" \
  && pass "s21: archive.sh 완료 (인덱스 충돌 자동 해결)" || fail "s21: archive 실패 — $arc_out"
[[ "$arc_out" == *"행 집합 병합으로 해결"* ]] && pass "s21: 행 집합 병합 안내 출력" || fail "s21: 병합 안내 없음"
( cd "$REPO" && [[ "$(grep -c '| reg-a |' "$_IDX")" == 1 && "$(grep -c '| other-x |' "$_IDX")" == 1 ]] ) && pass "s21: 인덱스 행 reg-a 1·other-x 1 (중복 없음)" || fail "s21: 행 수 — $(cd "$REPO" && cat "$_IDX")"
( cd "$REPO" && [[ -f rd-workflow-workspace/backlog/items/2026-02-02-reg-a.md && -f rd-workflow-workspace/raw-captures/2026-02-02-fr-reg-a.md ]] ) && pass "s21: 상세 1·캡처 1 존재" || fail "s21: 상세/캡처 부재"
( cd "$REPO" && [[ -z "$(git status --porcelain | grep -v review-skip-audit.log)" && "$(git worktree list | wc -l | tr -d ' ')" == 1 && ! "$(git for-each-ref --format='%(refname)')" == *"fr/test-reg"* ]] ) && pass "s21: clean + 임시 worktree·브랜치 없음" || fail "s21: 잔존 — $(cd "$REPO" && git status --porcelain; git for-each-ref)"
rm -rf "$REPO"

# === Scenario 22: 정상 경로 E2E (fr 모드) + 권위 tree (change spec §4.2·§3.3.1) ===
#
# **시간 예산 사유** (절대 규칙 ③): 이 케이스는 promote → 구현 커밋 → 리뷰 세션 생성 →
# 종결 → seal → 상태 전이 → 게이트 → 기록 커밋 → archive 까지를 한 저장소에서 이어 돌리므로
# 수 초를 넘습니다(실측 ~15초). 그 비용을 지불하는 이유는 **초안의 순환 의존**이 단위
# 테스트로는 잡히지 않기 때문입니다 — 「보류 상태여야 기록 커밋 허용 + 기록 커밋 후 보류
# 전이」는 각 단계를 따로 시험하면 전부 통과하고, 진입부터 발행까지 이어 붙였을 때만
# "들어갈 수 없는 상태" 가 드러납니다. 각 단계를 쪼갠 단위 테스트로는 대체되지 않습니다.
echo "== scenario 22: 정상 경로 E2E + 권위 tree =="

# add_review_scripts <repo> — prepare/init_review_pipeline 은 setup_repo 가 복사하지 않습니다.
add_review_scripts() {
  cp "$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/prepare_review_pipeline.sh" "$1/rd-workflow/scripts/"
  cp "$PROJECT_ROOT/_ROOT_FILES/rd-workflow/scripts/init_review_pipeline.sh" "$1/rd-workflow/scripts/"
}
# close_session <session-dir> — Status=closed + Open Issues=`- 없음` (정상 종결 형태)
close_session() {
  local t
  t="$(mktemp)" || { echo "test_integration.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$t" && -f "$t" ]] || { echo "test_integration.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  awk '/^## Status$/{print; getline; print "closed"; next} {print}' "$1/SESSION.md" > "$t" && mv "$t" "$1/SESSION.md"
  t="$(mktemp)" || { echo "test_integration.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$t" && -f "$t" ]] || { echo "test_integration.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  awk '/^## Open Issues$/{s=1; print; next} s && /^## /{s=0} s && $0=="-"{print "- 없음"; next} {print}' \
    "$1/CHECKPOINT.md" > "$t" && mv "$t" "$1/CHECKPOINT.md"
}
# latest_diff_session <repo> — 최신 final-diff-review 세션 경로 (없으면 빈 문자열)
latest_diff_session() {
  local p=""
  p="$(ls -d "$1"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | tail -1)" || p=""
  printf '%s' "$p"
}

REPO="$(setup_repo)"
add_review_scripts "$REPO"
run_promote "$REPO" --short-title e2e --size small --no-worktree >/dev/null
# fr 브랜치 위의 구현 커밋 — 이것이 리뷰 대상(보호 경로)입니다.
( cd "$REPO" && printf 'code\n' > src.txt && git add -A && git commit -q -m "구현" )
( cd "$REPO" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff >/dev/null 2>&1 ) \
  && pass "e2e: diff 세션 생성 (fr-branch → merge-base)" || fail "e2e: diff 세션 생성 실패"
E2E_SES="$(latest_diff_session "$REPO")"
[[ -n "$E2E_SES" ]] && pass "e2e: 세션 경로 확인" || fail "e2e: 세션 부재"
( cd "$REPO" && grep -q "^review-session=$(basename "$E2E_SES")$" rd-workflow-workspace/.lifecycle/task-state ) \
  && pass "e2e: task-state review-session 포인터 기록" || fail "e2e: 포인터 미기록"

close_session "$E2E_SES"
( cd "$REPO" && bash rd-workflow/scripts/rd review seal "$E2E_SES" >/dev/null 2>&1 ) \
  && pass "e2e: seal 성공 (리뷰된 head == 현재 트리)" || fail "e2e: seal 실패"
for _st in "검증 중" "diff review 대기" "아카이브 보류"; do
  ( cd "$REPO" && bash rd-workflow/scripts/rd task set-status "$_st" >/dev/null 2>&1 ) \
    || fail "e2e: set-status $_st 실패"
done
( cd "$REPO" && grep -q '^status=아카이브 보류$' rd-workflow-workspace/.lifecycle/task-state ) \
  && pass "e2e: 아카이브 보류 진입 (seal 뒤·기록 커밋 앞)" || fail "e2e: 보류 전이 실패"

# 권위 tree 음성 — 포인터·상태만 먼저 커밋해 **마커만 워킹트리에 남은** 상태를 만듭니다.
( cd "$REPO" && git add rd-workflow-workspace/.lifecycle/task-state CURRENT_TASK.md \
  && git commit -q -m "chore: 리뷰 포인터·상태" )
_e2e_err="$( cd "$REPO" && git switch -q main \
  && bash rd-workflow/scripts/lifecycle/archive.sh --task e2e --no-remote --force-dirty 2>&1 || true )"
[[ "$_e2e_err" == *"마커 없음"* ]] \
  && pass "e2e: 워킹트리에만 있는 마커로는 통과 못 함 (§3.3.1)" || fail "e2e: 마커 없음 차단 아님 — $_e2e_err"

# 기록 커밋 — FR 은 아직 idea 입니다. 이 시점에 게이트가 통과해야 §4.2 순서가 성립합니다
# (게이트가 보류 상태를 인정하지 않으면 「기록 커밋 → 보류 전이」 순환으로 되돌아갑니다).
( cd "$REPO" && git switch -q fr/e2e \
  && mkdir -p rd-workflow-workspace/backlog/items rd-workflow-workspace/backlog/request-archive \
  && printf '# e2e\n- status: idea\n' > rd-workflow-workspace/backlog/items/2026-09-06-e2e.md \
  && printf '# Change Request\n\n## Source FR\nrd-workflow-workspace/backlog/items/2026-09-06-e2e.md\n' > REQUEST.md \
  && git add -A && git commit -q -m "docs: FR 등록" )
#
# **게이트 판정 시점에 REQUEST.md 의 Source FR 이 살아 있어야 합니다.** 먼저 비우면 게이트가
# "아카이브 불필요" 로 조기 통과해, 정작 보고 싶은 §4.3 예외 분기를 지나지 않습니다.
( cd "$REPO" \
  && cp REQUEST.md rd-workflow-workspace/backlog/request-archive/2026-09-06-0000-e2e.md \
  && git add rd-workflow-workspace/backlog/request-archive rd-workflow-workspace/.lifecycle/review-seals )
_gate_rc=0
( cd "$REPO" && printf '{"tool_input":{"command":"git commit -m 기록"}}' \
  | bash rd-workflow/scripts/hooks/pre_commit_archive_gate.sh >/dev/null 2>&1 ) || _gate_rc=$?
[[ "$_gate_rc" -eq 0 ]] \
  && pass "e2e: 보류 상태 + 기록 경로만 staged → 게이트 통과 (순환 없음)" \
  || fail "e2e: 게이트가 기록 커밋을 차단 (exit=$_gate_rc)"
( cd "$REPO" && printf '# Change Request\n\n## Source FR\n-\n' > REQUEST.md \
  && sed 's/^- status: idea$/- status: done/' rd-workflow-workspace/backlog/items/2026-09-06-e2e.md > "$REPO/.fr.tmp" \
  && mv "$REPO/.fr.tmp" rd-workflow-workspace/backlog/items/2026-09-06-e2e.md \
  && git add -A && git commit -q -m "docs: REQUEST 아카이브" )

# 발행 — `--force-skip-review-check` 없이 통과해야 합니다. 기본 브랜치 워킹트리에는 마커가
# 없고 fr tip 에만 있으므로, 이것이 §3.3.1 권위 tree 의 양성 케이스입니다.
_e2e_out="$( cd "$REPO" && git switch -q main \
  && bash rd-workflow/scripts/lifecycle/archive.sh --task e2e --no-remote 2>&1 )" && _e2e_rc=0 || _e2e_rc=$?
[[ "$_e2e_rc" -eq 0 ]] \
  && pass "e2e: archive 발행 완료 (fr tip 마커로 검증, force-skip 없음)" \
  || fail "e2e: archive 실패 (exit=$_e2e_rc) — $_e2e_out"
( cd "$REPO" && git tag --list "fr/*/e2e" | grep -q . ) && pass "e2e: tag 생성" || fail "e2e: tag 부재"
( cd "$REPO" && ! git rev-parse --verify fr/e2e >/dev/null 2>&1 ) \
  && pass "e2e: fr 브랜치 정리" || fail "e2e: fr 브랜치 잔존"
( cd "$REPO" && grep -q '^status=대기 중$' rd-workflow-workspace/.lifecycle/task-state ) \
  && pass "e2e: task-state baseline 복귀" || fail "e2e: task-state 미복귀"
rm -rf "$REPO"

# === Scenario 23: no-fr archive + 실행 브랜치 안전 + sentinel (change spec §5.1·§3.2.2) ===
#
# **시간 예산 사유** (절대 규칙 ③): 위와 같은 이유로 수 초를 넘습니다(실측 ~10초).
# 목적은 **no-fr archive 완주**입니다 — 진입 조건만 단위로 시험하면 merge·branch 삭제·
# worktree 정리를 건너뛴 경로가 tag·push 까지 실제로 도달하는지 알 수 없습니다.
# fr 경로 무변화는 scenario 1·11·12·21 이 이미 매 실행마다 확인하므로 여기서 다시 만들지 않습니다.
echo "== scenario 23: no-fr archive / 브랜치 안전 / sentinel =="
REPO="$(setup_repo)"
add_review_scripts "$REPO"
BARE23="$(mk_bare 23)"
( cd "$REPO" && git remote add origin "$BARE23" && git push -q origin main )
( cd "$REPO" && bash rd-workflow/scripts/rd task set-title nofr >/dev/null 2>&1 \
  && bash rd-workflow/scripts/rd task set-base HEAD >/dev/null 2>&1 \
  && bash rd-workflow/scripts/rd task set-status "구현 중" >/dev/null 2>&1 ) \
  && pass "no-fr: task-state 준비 (base-commit 설정)" || fail "no-fr: task-state 준비 실패"
( cd "$REPO" && printf 'code\n' > src.txt && git add -A && git commit -q -m "구현" )
( cd "$REPO" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff >/dev/null 2>&1 ) \
  && pass "no-fr: base-commit 으로 diff 세션 생성" || fail "no-fr: 세션 생성 실패"
NOFR_SES="$(latest_diff_session "$REPO")"
close_session "$NOFR_SES"
( cd "$REPO" && bash rd-workflow/scripts/rd review seal "$NOFR_SES" >/dev/null 2>&1 ) \
  && pass "no-fr: seal 성공 (branch-mode=no-fr)" || fail "no-fr: seal 실패"
( grep -q '^branch-mode=no-fr$' "$REPO/rd-workflow-workspace/.lifecycle/review-seals/$(basename "$NOFR_SES").seal" \
  && grep -q '^fr-branch=null$' "$REPO/rd-workflow-workspace/.lifecycle/review-seals/$(basename "$NOFR_SES").seal" ) \
  && pass "no-fr: 마커에 no-fr 표기" || fail "no-fr: 마커 표기 오류"
for _st in "검증 중" "diff review 대기" "아카이브 보류"; do
  ( cd "$REPO" && bash rd-workflow/scripts/rd task set-status "$_st" >/dev/null 2>&1 ) || fail "no-fr: set-status $_st 실패"
done
( cd "$REPO" && git add -A && git commit -q -m "docs: 기록 커밋" )

# 실행 브랜치 안전 — 두 검사 모두 Step 0(worktree 검출) **앞**에 있어야 사용자가 무엇을
# 해야 하는지 알 수 있습니다. 뒤에 있으면 `기본 브랜치 worktree 검출 실패` 라는 무관한 안내만 나옵니다.
_det_err="$( cd "$REPO" && git checkout -q --detach \
  && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote 2>&1 || true )"
[[ "$_det_err" == *"detached HEAD 에서는 no-fr archive"* ]] \
  && pass "no-fr: detached HEAD 차단" || fail "no-fr: detached 안내 부재 — $_det_err"
_side_err="$( cd "$REPO" && git switch -q main && git switch -q -c side \
  && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote 2>&1 || true )"
[[ "$_side_err" == *"기본 브랜치(main)에서만 호출 가능"* ]] \
  && pass "no-fr: 기본 브랜치 아님 차단" || fail "no-fr: 브랜치 안내 부재 — $_side_err"
( cd "$REPO" && git switch -q main && git branch -D side -q )

# sentinel — canonical `null` 만 no-fr 이고 빈값·`main`·공백은 malformed 차단입니다 (§3.2.2).
# "비어 있으면 no-fr" 로 다루면 파손된 task-state 가 조용히 발행으로 흘러갑니다.
NOFR_TS="$REPO/rd-workflow-workspace/.lifecycle/task-state"
cp "$NOFR_TS" "$NOFR_TS.bak"
_sentinel_case() {  # _sentinel_case <값> <기대 문구> <설명>
  local out
  sed "s|^fr-branch=.*|fr-branch=$1|" "$NOFR_TS.bak" > "$NOFR_TS"
  out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote --force-dirty 2>&1 || true )"
  [[ "$out" == *"$2"* ]] && pass "no-fr sentinel: $3" || fail "no-fr sentinel: $3 — $out"
}
_sentinel_case "" "빈 값은 파손으로 봅니다" "빈값 → 파손 차단"
_sentinel_case "main" "canonical 이 아니라 진행할 수 없습니다" "'main' → malformed 차단"
_sentinel_case " " "canonical 이 아니라 진행할 수 없습니다" "공백 → malformed 차단"
cp "$NOFR_TS.bak" "$NOFR_TS"; rm -f "$NOFR_TS.bak"

# 정상 발행 — `--no-remote` 이므로 push 하지 않고 tag 만 로컬에 남습니다 (AC 24).
_nofr_out="$( cd "$REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote 2>&1 )" && _nofr_rc=0 || _nofr_rc=$?
[[ "$_nofr_rc" -eq 0 ]] && pass "no-fr: archive 완주 (merge 없이 발행)" || fail "no-fr: archive 실패 (exit=$_nofr_rc) — $_nofr_out"
[[ "$_nofr_out" == *"merge 대상 브랜치가 없어 merge 를 건너뜁니다"* ]] \
  && pass "no-fr: merge 건너뜀 안내" || fail "no-fr: merge 건너뜀 안내 부재"
( cd "$REPO" && git tag --list "fr/*/nofr" | grep -q . ) && pass "no-fr: tag 로컬 생성" || fail "no-fr: tag 부재"
( cd "$REPO" && [[ -z "$(git ls-remote origin 'refs/tags/*' 2>/dev/null)" ]] ) \
  && pass "no-fr: --no-remote → tag 미push" || fail "no-fr: tag 가 push 됨"
( cd "$REPO" && [[ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" != "$(git rev-parse main)" ]] ) \
  && pass "no-fr: --no-remote → main 미push" || fail "no-fr: main 이 push 됨"
( cd "$REPO" && grep -q '^status=대기 중$' rd-workflow-workspace/.lifecycle/task-state \
  && grep -q '^base-commit=null$' rd-workflow-workspace/.lifecycle/task-state ) \
  && pass "no-fr: task-state baseline 복귀 (base-commit 포함)" || fail "no-fr: task-state 미복귀"
rm -rf "$REPO" "$BARE23"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
