#!/bin/bash
# test_pre_commit_archive_gate.sh — pre_commit_archive_gate.sh Source FR 해석·enforcement 격리 검증
# macOS /bin/bash 3.2 호환. fixture 패턴: test_implementation_gate.sh 준용.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
HOOK_SOURCE="$HOOK_DIR/pre_commit_archive_gate.sh"
GUARD_COMMON="$HOOK_DIR/_guard_common.sh"
STATE_COMMON="$SCRIPTS_DIR/_state_common.sh"
PASS=0
FAIL=0

_current_fixture=""
cleanup_fixture() {
  if [[ -n "$_current_fixture" && -d "$_current_fixture" ]]; then
    rm -rf "$_current_fixture"
    _current_fixture=""
  fi
}

# 이 테스트는 **실제 차단 hook** 을 부르고, hook 은 자기 위치에서 project_root 를 도출해
# 운영 감사 로그(`rd-workflow-workspace/.lifecycle/guard-block-audit.log`)에 쓴다. 그대로
# 두면 검증 차단이 실사용 차단과 섞여 가드 은퇴 심사 데이터가 오염된다 — `self_test.sh`
# 경유만 격리하면 이 파일을 직접 실행하는 정상적인 개발 경로가 여전히 오염시킨다.
RD_GUARD_BLOCK_LOG="$(mktemp -t rd-guard-block-test.XXXXXX 2>/dev/null)" \
  || RD_GUARD_BLOCK_LOG="/dev/null"
export RD_GUARD_BLOCK_LOG
_rd_gbl_cleanup() {
  [ "$RD_GUARD_BLOCK_LOG" = "/dev/null" ] || rm -f "$RD_GUARD_BLOCK_LOG"
}
trap 'cleanup_fixture; _rd_gbl_cleanup' EXIT INT TERM

# make_fixture <source-fr-값(__NONE__=섹션 없음)> <fr상세파일 상대경로(__NONE__=생성 안 함)> <fr-status> [세션모드]
# hook 은 script_dir/../../.. 를 project_root 로 계산 → fixture/rd-workflow/scripts/hooks 에 배치.
# 세션모드 (기본 resolved): resolved=종결 세션 / open=미종결 세션 / none=세션 없음.
#   종결 세션이 기본인 이유는 대부분의 시나리오가 enforcement 경로 도달을 전제하기 때문이다.
#   open·none 은 "이 커밋이 archive 단계인가" 를 가르는 경계를 고정하는 데 쓴다.
make_fixture() {
  local src_val="$1" fr_rel="$2" fr_status="$3" sess_mode="${4:-resolved}"
  local fixture
  fixture="$(mktemp -d)" || { echo "test_pre_commit_archive_gate.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$fixture" && -d "$fixture" ]] || { echo "test_pre_commit_archive_gate.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  cp "$HOOK_SOURCE" "$fixture/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON" "$fixture/rd-workflow/scripts/_state_common.sh"
  # 스캐너를 함께 복사한다. 누락하면 폴백 경로로 테스트되어 새 판정을 검사하지 못한다.
  [[ -f "$HOOK_DIR/_commit_scan.awk" ]] && cp "$HOOK_DIR/_commit_scan.awk" "$fixture/rd-workflow/scripts/hooks/"
  mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
  cat > "$fixture/rd-workflow-workspace/.lifecycle/task-state" <<'TSEOF'
schema=1
short-title=t1
status=diff review 대기
fr-branch=null
worktree-path=null
source-fr=-
TSEOF
  local sess="$fixture/rd-workflow-workspace/handoffs/review_pipeline/20260101_000000_final-diff-review"
  if [[ "$sess_mode" != "none" ]]; then
    mkdir -p "$sess"
    if [[ "$sess_mode" == "open" ]]; then
      # 미종결 — Status 가 awaiting-user/closed 가 아니면 is_review_session_resolved 가 거부한다.
      printf '%s\n' "# Review Session" "" "## Status" "awaiting-reviewer" "" "## Branch Context" "- short-title: t1" > "$sess/SESSION.md"
      printf '%s\n' "# Review Checkpoint" "" "## Open Issues" "- 미해결 이슈가 있습니다" > "$sess/CHECKPOINT.md"
    else
      printf '%s\n' "# Review Session" "" "## Status" "awaiting-user" "" "## Branch Context" "- short-title: t1" > "$sess/SESSION.md"
      printf '%s\n' "# Review Checkpoint" "" "## Open Issues" "- 없음" > "$sess/CHECKPOINT.md"
    fi
  fi
  if [[ "$src_val" == "__NONE__" ]]; then
    printf '%s\n' "# Change Request" "" "## Task Type" "change" > "$fixture/REQUEST.md"
  else
    printf '%s\n' "# Change Request" "" "## Source FR" "$src_val" > "$fixture/REQUEST.md"
  fi
  if [[ "$fr_rel" != "__NONE__" ]]; then
    mkdir -p "$fixture/$(dirname "$fr_rel")"
    printf '%s\n' "# fr item" "- status: $fr_status" > "$fixture/$fr_rel"
  fi
  printf '%s' "$fixture"
}

_hook_last_exit=0
_hook_last_err=""
run_hook() {
  local fixture="$1" cmd="${2:-git commit -m test}"   # 인자 없으면 현행 동작
  _hook_last_exit=0
  _hook_last_err="$(printf '{"tool_input":{"command":"%s"}}' "$cmd" | \
    bash "$fixture/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh" 2>&1 >/dev/null)" \
    || _hook_last_exit=$?
}

# run_scenario <num> <name> <source-fr값> <fr상세상대경로> <fr-status> <expected_exit> <expected_err_substr(-=검사안함)> [cmd] [세션모드]
run_scenario() {
  local num="$1" name="$2" src="$3" fr_rel="$4" fr_status="$5" expected="$6" err_sub="$7" cmd="${8:-}" sess_mode="${9:-resolved}"
  local fixture
  fixture="$(make_fixture "$src" "$fr_rel" "$fr_status" "$sess_mode")" || {
    echo "[FAIL] scenario ${num}: ${name} — fixture 생성 실패 (make_fixture rc=$?)" >&2
    FAIL=$((FAIL + 1))
    return 1
  }
  _current_fixture="$fixture"
  if [[ -n "$cmd" ]]; then run_hook "$fixture" "$cmd"; else run_hook "$fixture"; fi
  local ok=1
  [[ "$_hook_last_exit" == "$expected" ]] || ok=0
  if [[ "$err_sub" != "-" ]]; then
    case "$_hook_last_err" in *"$err_sub"*) ;; *) ok=0 ;; esac
  fi
  if [[ "$ok" == 1 ]]; then
    echo "[PASS] scenario ${num}: ${name} (exit=$_hook_last_exit)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] scenario ${num}: ${name} — expected exit=$expected actual=$_hook_last_exit err=[${_hook_last_err}]" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

ITEM="rd-workflow-workspace/backlog/items/2026-01-01-t1.md"

run_scenario 1 "백틱 path + status idea → 차단" \
  '`'"$ITEM"'`' "$ITEM" "idea" 2 "done/dropped 필요"
# guard-block-reason-identifier: 이 분기(Source FR done/dropped 미완료)가 실제로 유발됐을 때
# 기대한 reason 값이 감사 로그에 기록되는지 값 대응 검증.
if tail -n1 "$RD_GUARD_BLOCK_LOG" 2>/dev/null | grep -qE 'reason=pre_commit_archive_gate\.incomplete-source-fr$'; then
  echo "[PASS] scenario 1 reason 검증"
  PASS=$((PASS + 1))
else
  echo "[FAIL] scenario 1 reason 검증 — 감사 로그에 reason=pre_commit_archive_gate.incomplete-source-fr 가 없습니다" >&2
  FAIL=$((FAIL + 1))
fi
run_scenario 2 "백틱 path + status done → 통과" \
  '`'"$ITEM"'`' "$ITEM" "done" 0 "-"
run_scenario 3 "legacy slug + status idea → 차단" \
  "2026-01-01-t1" "$ITEM" "idea" 2 "done/dropped 필요"
run_scenario 4 "legacy slug + status dropped → 통과" \
  "2026-01-01-t1" "$ITEM" "dropped" 0 "-"
run_scenario 5 "Source FR '-' → 통과" \
  "-" "__NONE__" "-" 0 "-"
run_scenario 6 "Source FR 섹션 없음 → 통과" \
  "__NONE__" "__NONE__" "-" 0 "-"
run_scenario 7 "path + FR 파일 미존재 → 차단" \
  '`rd-workflow-workspace/backlog/items/2026-01-01-none.md`' "__NONE__" "-" 2 "2026-01-01-none.md"
# guard-block-reason-identifier: 이 분기(Source FR 해석 실패)가 실제로 유발됐을 때 기대한
# reason 값이 감사 로그에 기록되는지 값 대응 검증.
if tail -n1 "$RD_GUARD_BLOCK_LOG" 2>/dev/null | grep -qE 'reason=pre_commit_archive_gate\.unresolved-source-fr$'; then
  echo "[PASS] scenario 7 reason 검증"
  PASS=$((PASS + 1))
else
  echo "[FAIL] scenario 7 reason 검증 — 감사 로그에 reason=pre_commit_archive_gate.unresolved-source-fr 가 없습니다" >&2
  FAIL=$((FAIL + 1))
fi
run_scenario 8 "절대경로 → 차단" \
  "/etc/passwd" "__NONE__" "-" 2 "/etc/passwd"
run_scenario 9 ".. 세그먼트 → 차단" \
  "rd-workflow-workspace/backlog/items/../../evil.md" "__NONE__" "-" 2 "evil.md"

# --- Source FR 표기 해석 (promote-source-fr-format-contract) ---
run_scenario 10 "markdown 링크 + status idea → 차단" \
  "[t1](${ITEM})" "$ITEM" "idea" 2 "done/dropped 필요"
run_scenario 11 "markdown 링크 + status done → 통과" \
  "[t1](${ITEM})" "$ITEM" "done" 0 "-"
run_scenario 12 "종결 세션 + 해석 불가 값 → 차단(fail-closed)" \
  "없는-항목-입니다" "__NONE__" "-" 2 "없는-항목-입니다"

# --- fail-closed 적용 범위 (final diff review Finding 1) ---
# 해석 실패 차단은 archive 커밋에만 적용되어야 한다. review 세션이 없거나 미종결이면
# 그 커밋은 아직 archive 단계가 아니므로(구현 중 iteration commit 등) 통과시킨다.
# 이 경계가 없으면 Source FR 표기가 어긋난 REQUEST 에서 모든 git commit 이 막힌다.
run_scenario 13 "세션 없음 + 해석 불가 값 → 통과(iteration commit 보호)" \
  "없는-항목-입니다" "__NONE__" "-" 0 "-" "" "none"
run_scenario 14 "미종결 세션 + 해석 불가 값 → 통과(iteration commit 보호)" \
  "없는-항목-입니다" "__NONE__" "-" 0 "-" "" "open"

# A1: 아카이브 신호 재료 충족 + 데이터 구간(홑따옴표)의 커밋 문자열 → 오탐 해소
run_scenario A1 "데이터 구간 커밋 문자열 → 통과(오탐 해소)" \
  '`'"$ITEM"'`' "$ITEM" "idea" 0 "-" \
  "echo '"'"'git commit -m x'"'"'"

# A2: 같은 fixture + 실제 커밋(-C 형태) → 기존 차단 동작 유지
#     현행 글롭은 git -C … commit 을 미탐으로 통과시켰다. 새 판정은 차단한다.
run_scenario A2 "git -C . 실제 커밋 → 차단 유지" \
  '`'"$ITEM"'`' "$ITEM" "idea" 2 "done/dropped 필요" \
  "git -C . commit -m x"

# --- FR 등록 helper 정규 예외 (fr-record-loss-on-unmerged-branch AC 12) ---
# helper 호출 문자열에는 git commit 이 없으므로 스캐너가 gate=0 을 낸다 — 이것이 계약이다.
# 같은 차단 상태의 일반 커밋은 계속 차단된다 (양방향 고정). helper 의 형태 제한은 test_fr_register.sh 가 고정한다.
run_scenario 15 "FR 등록 helper 호출 → 통과(정규 예외)" \
  '`'"$ITEM"'`' "$ITEM" "idea" 0 "-" \
  "bash rd-workflow/scripts/rd task fr-register --slug t1"
run_scenario 16 "같은 차단 상태의 일반 커밋 → 차단 유지" \
  '`'"$ITEM"'`' "$ITEM" "idea" 2 "done/dropped 필요" \
  "git commit -m x"

# --- 복수 Source FR — 부분 미완료 전부 열거 (task-guard-source-fr-contract T4) ---
# 없으면 새는 실수: 게이트 범위 안에서도 여러 건 중 1건만 보고 나머지 미완료 FR을
# 놓친다(구 구현은 첫 유효행만 읽어 검사했다).
# 주의: 이 테스트는 게이트가 실제로 검사하는 범위(=Source FR이 남아 있는 아카이브
# 커밋 시도) **안에서의** 전수 열거만 증명한다. 마감 누락 자체를 막는다는 증명은
# 아니다 — 게이트는 REQUEST 부재·Source FR 공백·`아카이브 보류` 기록 커밋을
# 통과시키므로 최종 보장이 아니다 (spec §2.5.3).
ITEM_A="rd-workflow-workspace/backlog/items/2026-01-01-a.md"
ITEM_B="rd-workflow-workspace/backlog/items/2026-01-01-b.md"
ITEM_C="rd-workflow-workspace/backlog/items/2026-01-01-c.md"
ITEM_D="rd-workflow-workspace/backlog/items/2026-01-01-d.md"

make_multi_fixture() {
  local fixture
  fixture="$(mktemp -d)" || { echo "test_pre_commit_archive_gate.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$fixture" && -d "$fixture" ]] || { echo "test_pre_commit_archive_gate.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  cp "$HOOK_SOURCE" "$fixture/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON" "$fixture/rd-workflow/scripts/_state_common.sh"
  [[ -f "$HOOK_DIR/_commit_scan.awk" ]] && cp "$HOOK_DIR/_commit_scan.awk" "$fixture/rd-workflow/scripts/hooks/"
  mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
  cat > "$fixture/rd-workflow-workspace/.lifecycle/task-state" <<'TSEOF'
schema=1
short-title=t1
status=diff review 대기
fr-branch=null
worktree-path=null
source-fr=-
TSEOF
  local sess="$fixture/rd-workflow-workspace/handoffs/review_pipeline/20260101_000000_final-diff-review"
  mkdir -p "$sess"
  printf '%s\n' "# Review Session" "" "## Status" "awaiting-user" "" "## Branch Context" "- short-title: t1" > "$sess/SESSION.md"
  printf '%s\n' "# Review Checkpoint" "" "## Open Issues" "- 없음" > "$sess/CHECKPOINT.md"
  printf '%s\n' "# Change Request" "" "## Source FR" \
    "- ${ITEM_A}" "- ${ITEM_B}" "- ${ITEM_C}" "- ${ITEM_D}" > "$fixture/REQUEST.md"
  mkdir -p "$fixture/$(dirname "$ITEM_A")"
  printf '%s\n' "# fr item" "- status: done" > "$fixture/$ITEM_A"
  printf '%s\n' "# fr item" "- status: idea" > "$fixture/$ITEM_B"
  printf '%s\n' "# fr item" "- status: dropped" > "$fixture/$ITEM_C"
  printf '%s\n' "# fr item" "- status: 구현 중" > "$fixture/$ITEM_D"
  printf '%s' "$fixture"
}

FX_MULTI="$(make_multi_fixture)" && { _current_fixture="$FX_MULTI"; multi_fixture_ok=1; } || multi_fixture_ok=0
if [[ "$multi_fixture_ok" == "1" ]]; then
  run_hook "$FX_MULTI"
  _ok=1
  [[ "$_hook_last_exit" == "2" ]] || _ok=0
  case "$_hook_last_err" in *"$ITEM_B"*) ;; *) _ok=0 ;; esac
  case "$_hook_last_err" in *"$ITEM_D"*) ;; *) _ok=0 ;; esac
  case "$_hook_last_err" in *"$ITEM_A"*) _ok=0 ;; esac
  case "$_hook_last_err" in *"$ITEM_C"*) _ok=0 ;; esac
  if [[ "$_ok" == 1 ]]; then
    echo "[PASS] scenario 17: 복수 Source FR 4건 중 2건만 done/dropped → 차단 + 미완료 2건 전부 열거 (exit=$_hook_last_exit)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] scenario 17: 복수 Source FR 부분 미완료 열거 — exit=$_hook_last_exit err=[${_hook_last_err}]" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
else
  echo "[FAIL] scenario 17: multi fixture 생성 실패" >&2
  FAIL=$((FAIL + 1))
fi


# ===========================================================================
# 보호 트리 해시·기록 경로 판정 (change spec §2.1~§2.3, §6 의 1~4)
# ---------------------------------------------------------------------------
# 위 시나리오들은 git 저장소 없이 Source FR 해석 경로만 다룹니다. 아래 케이스는
# `rd_protected_tree_hash`·`rd_commit_scope_all_records` 를 대상으로 하므로 fixture 를
# 실제 git 저장소로 만들어 씁니다.
#
# **실행 시간**: 이 절은 git 저장소 fixture 2개 + 커밋 여러 번이라 수 초가 듭니다
# (spec §6 의 1~4 예상 합계 ~16초). 비용을 정당화하는 근거는 여기서 고정하는 것이
# 이번 설계의 핵심 불변식이기 때문입니다 — 판정이 틀리면 정상 아카이브가 자기 자신을
# 차단하거나(AC 10) 리뷰 종결 후의 코드 변경이 통과합니다(AC 16). 대신 fixture 를 케이스
# 그룹당 하나로 묶고 `git config` 를 파일 한 번 쓰기로 대신해 프로세스 기동을 줄였습니다.
# ===========================================================================

# _state_common.sh 의 함수를 fixture 컨텍스트에서 실행하는 러너입니다.
# fixture 안에 두면 tracked/untracked 상태가 트리 해시 케이스와 얽히므로 밖에 둡니다.
_SC_RUNNER="$(mktemp "${TMPDIR:-/tmp}/rd-sc-runner.XXXXXX")" || { echo "test_pre_commit_archive_gate.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_SC_RUNNER" && -f "$_SC_RUNNER" ]] || { echo "test_pre_commit_archive_gate.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
cat > "$_SC_RUNNER" <<'RUNEOF'
#!/bin/bash
# <fixture(스크립트 사본 위치)> <project_root> <실행할 셸 코드>
set -uo pipefail
project_root="$2"
source "$1/rd-workflow/scripts/_state_common.sh"
eval "$3"
RUNEOF

cleanup_runner() { [[ -n "${_SC_RUNNER:-}" ]] && rm -f "$_SC_RUNNER"; }
trap 'cleanup_fixture; cleanup_runner; _rd_gbl_cleanup' EXIT INT TERM

# sc_run <fixture> <project_root> <cwd> <코드> — stdout 만 돌려줍니다.
# project_root 를 fixture 와 따로 받는 것이 이식성 케이스(§6 의 2)의 핵심입니다 — 하위
# 디렉터리에서 호출한 상황을 그대로 재현합니다.
sc_run() {
  local fx="$1" pr="$2" cwd="$3" code="$4"
  ( cd "$cwd" && bash "$_SC_RUNNER" "$fx" "$pr" "$code" 2>/dev/null )
}

assert_eq() {
  local name="$1" exp="$2" act="$3"
  if [[ "$exp" == "$act" ]]; then
    echo "[PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${name} — expected=[${exp}] actual=[${act}]" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_ne() {
  local name="$1" a="$2" b="$3"
  if [[ -n "$a" && "$a" != "$b" ]]; then
    echo "[PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${name} — 두 값이 같거나 비어 있습니다: a=[${a}] b=[${b}]" >&2
    FAIL=$((FAIL + 1))
  fi
}

# set_state_status <fixture> <status> — task-state 의 status 를 바꿉니다 (sed -i 비의존).
set_state_status() {
  local f="$1/rd-workflow-workspace/.lifecycle/task-state" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rd-ts.XXXXXX")" || { echo "test_pre_commit_archive_gate.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$tmp" && -f "$tmp" ]] || { echo "test_pre_commit_archive_gate.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  awk -v s="$2" '/^status=/{print "status=" s; next} {print}' "$f" > "$tmp" && mv "$tmp" "$f"
}

# make_git_fixture — 아카이브 보류 상태 + git 저장소인 fixture.
# 기록 경로(reports/completions)·보호 경로(src, 제외 목록 밖의 `.lifecycle/` 파일)를 함께
# 심어 경계 케이스가 같은 fixture 에서 재현되게 합니다.
make_git_fixture() {
  local fixture
  fixture="$(make_fixture '`'"$ITEM"'`' "$ITEM" "idea" "resolved")" || {
    echo "test_pre_commit_archive_gate.sh:248: make_fixture 실패 (rc=$?)" >&2
    return 1
  }
  set_state_status "$fixture" "아카이브 보류"
  printf '%s\n' "# Current Task" > "$fixture/CURRENT_TASK.md"
  mkdir -p "$fixture/src" "$fixture/rd-workflow-workspace/reports/completions"
  printf 'code v1\n' > "$fixture/src/app.sh"
  printf 'note v1\n' > "$fixture/rd-workflow-workspace/reports/completions/note.md"
  # 제외 목록 밖의 `.lifecycle/` 파일 — 설정·source 되는 조각을 대표합니다.
  printf 'hook input v1\n' > "$fixture/rd-workflow-workspace/.lifecycle/hook-input.sh"
  git -C "$fixture" init -q >/dev/null 2>&1
  # git config 를 4번 부르는 대신 설정 파일에 한 번에 씁니다 (프로세스 기동 절약).
  # diff.renames 를 켜는 이유: rename 이 R 레코드로 나와야 old path 검사 자체를 시험할 수
  # 있습니다 (D+A 로 갈라져도 결론은 같지만 검사 경로가 달라집니다).
  cat >> "$fixture/.git/config" <<'CFGEOF'
[user]
	name = rd test
	email = rd-test@example.com
[commit]
	gpgsign = false
[diff]
	renames = true
CFGEOF
  git -C "$fixture" add -A >/dev/null 2>&1
  git -C "$fixture" commit -qm base >/dev/null 2>&1
  printf '%s' "$fixture"
}

hash_of() { sc_run "$1" "$1" "$1" "rd_protected_tree_hash \"$2\""; }

# ---------------------------------------------------------------------------
# 그룹 A — §6 의 1: 트리 해시 핵심 불변식 + 보류 상태의 기록 커밋 예외
# 없으면 새는 실수: 정상 archive content commit 이 자기 자신을 차단하거나(AC 10),
# 리뷰 종결 후의 코드 변경이 통과합니다(AC 16). 게이트와 해시가 같은 목록을 쓰는지도
# 여기서 함께 고정합니다 — 두 소비처가 어긋나면 "커밋은 되는데 발행에서 막히는" 상태가
# 생깁니다.
# ---------------------------------------------------------------------------
FX="$(make_git_fixture)" || { echo "test_pre_commit_archive_gate.sh:290: make_git_fixture 실패 (rc=$?)" >&2; exit 1; }
_current_fixture="$FX"

# 게이트: 보류 상태 + 기록 경로만 staged → 통과
printf '%s\n' "# Change Request" > "$FX/REQUEST.md"
printf 'done\n' > "$FX/rd-workflow-workspace/reports/completions/2026-01-01-t1.md"
git -C "$FX" add -A >/dev/null 2>&1
run_hook "$FX"
assert_eq "gate 1a: 보류 상태 + 기록 경로만 staged → 통과" "0" "$_hook_last_exit"

# 게이트: 보류 상태 + 보호 경로 변경 staged → 차단
# T7 의 완화 분기는 차단 시 기존 세 줄 앞에 사유 한 줄을 덧붙이므로 부분 문자열로 봅니다.
git -C "$FX" reset --hard -q HEAD >/dev/null 2>&1
printf 'code v2\n' > "$FX/src/app.sh"
git -C "$FX" add -A >/dev/null 2>&1
run_hook "$FX"
_ok=1
[[ "$_hook_last_exit" == "2" ]] || _ok=0
case "$_hook_last_err" in *"기록 경로 밖의 파일"*) ;; *) _ok=0 ;; esac
assert_eq "gate 1b: 보류 상태 + 보호 경로 변경 staged → 차단" "1" "$_ok"
# 주의: gate 1b 의 fixture 는 FR status 가 "idea"(미완료)라서 실제로 유발되는 분기는
# incomplete-source-fr 이다(아래 gate 1d 가 FR→done 으로 만들어 pending-out-of-scope 를
# 유발한다) — reason 값 대응 검증은 실제로 그 분기를 유발하는 gate 1d 뒤에서 한다.

# --- final diff review Finding 3: 보류 분기가 `done` 조기 통과보다 먼저 적용되는가 ---
# 없으면 새는 실수: 정상 archive content commit 은 **같은 커밋에서** FR 을 done 으로 바꾸므로,
# `done` 조기 통과가 앞에 있으면 「기록 경로만 커밋」 제한이 통째로 우회됩니다. 또 hook 은
# 커밋 전에 돌기 때문에 index 만 보면 `git commit -a`·`git commit <경로>` 가 그냥 통과합니다.
# 아래 네 케이스는 전부 FR status 를 done 으로 두어 **차단이 오직 보류 분기에서만** 나오게
# 통제합니다 — 첫 케이스(통과)가 없으면 나머지는 "다 막힌다" 로도 통과해 버립니다.
# 비용: hook 실행 4회 + reset 4회로 1초 미만입니다(커밋을 만들지 않습니다).
set_fr_status() { printf '%s\n' "# fr item" "- status: $1" > "$FX/$ITEM"; }

pending_case() { # <이름> <기대 exit> <커밋 명령> <상태를 만드는 코드> [err 부분문자열]
  git -C "$FX" reset --hard -q HEAD >/dev/null 2>&1
  set_fr_status done
  ( cd "$FX" && eval "$4" ) >/dev/null 2>&1
  run_hook "$FX" "$3"
  local ok=1
  [[ "$_hook_last_exit" == "$2" ]] || ok=0
  if [[ -n "${5:-}" ]]; then
    case "$_hook_last_err" in *"${5}"*) ;; *) ok=0 ;; esac
  fi
  if [[ "$ok" == 1 ]]; then
    echo "[PASS] $1"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $1 — expected exit=$2 actual=$_hook_last_exit err=[${_hook_last_err}]" >&2
    FAIL=$((FAIL + 1))
  fi
}

pending_case "gate 1c(통제군): 정상 archive content commit(FR→done + 기록 경로만) → 통과" \
  0 "git commit -m archive" \
  'printf "%s\n" "# Change Request" > REQUEST.md && printf "done\n" > rd-workflow-workspace/reports/completions/2026-01-01-t1.md && git add -A'
pending_case "gate 1d: 같은 커밋에서 FR→done + 보호 경로 staged → 차단" \
  2 "git commit -m archive" \
  'printf "code v2\n" > src/app.sh && git add -A' \
  "기록 경로 밖의 파일"
# guard-block-reason-identifier: 이 분기(아카이브 보류 + FR 전부 done/dropped 인데 기록
# 경로 밖 변경이 있는 경우)가 실제로 유발됐을 때 기대한 reason 값이 감사 로그에 기록되는지
# 값 대응 검증. (gate 1b 는 FR 미완료라 incomplete-source-fr 이 대신 유발되므로 여기서 본다.)
if tail -n1 "$RD_GUARD_BLOCK_LOG" 2>/dev/null | grep -qE 'reason=pre_commit_archive_gate\.pending-out-of-scope$'; then
  echo "[PASS] gate 1d reason 검증"
  PASS=$((PASS + 1))
else
  echo "[FAIL] gate 1d reason 검증 — 감사 로그에 reason=pre_commit_archive_gate.pending-out-of-scope 가 없습니다" >&2
  FAIL=$((FAIL + 1))
fi
pending_case "gate 1e: 빈 index + 보호 경로 워킹트리 수정 + git commit -a → 차단" \
  2 "git commit -a -m x" \
  'printf "code v2\n" > src/app.sh' \
  "기록 경로 밖의 파일"
pending_case "gate 1f: 빈 index + git commit <보호파일> → 차단" \
  2 "git commit src/app.sh -m x" \
  'printf "code v2\n" > src/app.sh' \
  "기록 경로 밖의 파일"
git -C "$FX" reset --hard -q HEAD >/dev/null 2>&1

# 트리 해시: archive content commit 은 해시를 바꾸지 않습니다.
git -C "$FX" reset --hard -q HEAD >/dev/null 2>&1
h0="$(hash_of "$FX" HEAD)"
printf '%s\n' "# Change Request" > "$FX/REQUEST.md"
printf '%s\n' "# fr item" "- status: done" > "$FX/$ITEM"
printf 'done\n' > "$FX/rd-workflow-workspace/reports/completions/2026-01-01-t1.md"
printf '%s\n' "# Current Task" "Status: 완료" > "$FX/CURRENT_TASK.md"
set_state_status "$FX" "완료"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm archive >/dev/null 2>&1
h1="$(hash_of "$FX" HEAD)"
_ok=1
[[ -n "$h0" ]] || _ok=0
assert_eq "tree-hash 1c: 보호 트리 해시가 계산됨(fail-closed 아님)" "1" "$_ok"
assert_eq "tree-hash 1d: archive content commit 은 보호 트리 해시를 바꾸지 않음" "$h0" "$h1"

# 트리 해시: 보호 경로 코드 변경은 해시를 바꿉니다.
printf 'code v2\n' > "$FX/src/app.sh"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm code >/dev/null 2>&1
assert_ne "tree-hash 1e: 보호 경로 코드 변경은 해시를 바꿈" "$h1" "$(hash_of "$FX" HEAD)"
cleanup_fixture

# ---------------------------------------------------------------------------
# 그룹 B — §6 의 2·3·4: 이식성 / 경로 경계 / fail-closed·제외 목록
# fixture 하나를 `reset --hard` 로 되돌려 가며 재사용합니다.
# ---------------------------------------------------------------------------
FX="$(make_git_fixture)" || { echo "test_pre_commit_archive_gate.sh:383: make_git_fixture 실패 (rc=$?)" >&2; exit 1; }
_current_fixture="$FX"

# --- §6 의 3: 경로 경계 -----------------------------------------------------
# 없으면 새는 실수: rename 의 한쪽만 검사해 코드 변경이 기록 커밋으로 위장하거나,
# `rd-workflow-workspace-x/` 를 기록 경로로 오판해 신뢰 경계가 조용히 넓어집니다.
boundary_case() { # <이름> <기대 exit> <staged 를 만드는 코드>
  git -C "$FX" reset --hard -q HEAD >/dev/null 2>&1
  ( cd "$FX" && eval "$3" ) >/dev/null 2>&1
  run_hook "$FX"
  assert_eq "$1" "$2" "$_hook_last_exit"
}

boundary_case "path-boundary 3a: rename 안→밖 (기록 경로 → 보호 경로) 차단" 2 \
  'git mv rd-workflow-workspace/reports/completions/note.md src/note.md'
boundary_case "path-boundary 3b: rename 밖→안 (보호 경로 → 기록 경로) 차단" 2 \
  'git mv src/app.sh rd-workflow-workspace/reports/completions/app.sh'
boundary_case "path-boundary 3c: 보호 경로 파일 삭제 차단" 2 \
  'git rm -q src/app.sh'
boundary_case "path-boundary 3d: 기록 경로 파일 삭제만 → 통과" 0 \
  'git rm -q rd-workflow-workspace/reports/completions/note.md'
boundary_case "path-boundary 3e: 유사 접두사 rd-workflow-workspace-x/ 는 기록 경로 아님" 2 \
  'mkdir -p rd-workflow-workspace-x && printf "x\n" > rd-workflow-workspace-x/note.md && git add -A'
# 목록 항목 바로 옆의 유사 접두사도 봅니다. 위 3e 는 어느 목록 항목의 접두사도 아니라서
# `/` 를 떼고 접두 비교하는 구현에서도 통과합니다 — 경계를 실제로 시험하려면 목록 항목
# (`.../backlog/`) 에서 `/` 만 뺀 문자열로 시작하는 경로가 필요합니다.
boundary_case "path-boundary 3f: 유사 접두사 backlog-x/ 는 backlog/ 가 아님" 2 \
  'mkdir -p rd-workflow-workspace/backlog-x && printf "x\n" > rd-workflow-workspace/backlog-x/note.md && git add -A'
git -C "$FX" reset --hard -q HEAD >/dev/null 2>&1

# --- §6 의 2: 해시 이식성 ---------------------------------------------------
# 없으면 새는 실수: 하위 디렉터리에서 호출하거나 특수문자 파일명이 섞이면 같은 트리가 다른
# 해시로 계산되어, 정상 발행이 "리뷰 종결 후 변경" 으로 오판됩니다.
printf 'x\n' > "$FX/src/a b.txt"
printf 'x\n' > "$FX/src/$(printf 'ta\tb').txt"
printf 'x\n' > "$FX/src/$(printf 'new\nline').txt"
printf 'x\n' > "$FX/src/한글-비ASCII.txt"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm weird >/dev/null 2>&1
h_root="$(hash_of "$FX" HEAD)"
h_sub="$(sc_run "$FX" "$FX/src" "$FX/src" 'rd_protected_tree_hash HEAD')"
assert_eq "hash-portability 2a: repo root 와 하위 디렉터리 호출 결과가 동일" "$h_root" "$h_sub"
# 특수문자 파일명이 실제로 스트림에 들어갔는지 — 필터가 그런 레코드를 조용히 건너뛰면
# 여기서 걸립니다 (해시가 그대로면 그 파일은 판정 대상이 아니었다는 뜻입니다).
printf 'y\n' > "$FX/src/$(printf 'new\nline').txt"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm weird2 >/dev/null 2>&1
assert_ne "hash-portability 2b: 개행 포함 파일명의 변경도 해시에 반영" "$h_root" "$(hash_of "$FX" HEAD)"

# --- §6 의 4: fail-closed + 제외 목록 exact-match ----------------------------
# 없으면 새는 실수: `ls-tree` 실패가 두 빈 해시의 일치로 둔갑해 게이트가 통째로 무력화되고
# (Git 버전·pathspec 지원 차이로 실제로 일어나는 경로입니다 — spec §2.2), 제외 목록이
# 조용히 넓어져 자동화의 입력이 되는 파일이 리뷰 없이 바뀔 수 있게 됩니다.

# ls-tree 실패 주입: PATH 앞단의 git shim 이 `ls-tree` 만 nonzero 로 만들고 나머지 인자는
# 그대로 실제 git 에 넘깁니다. 저장소를 훼손하지 않는 좁은 주입입니다.
SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rd-shim.XXXXXX")" || { echo "test_pre_commit_archive_gate.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$SHIM_DIR" && -d "$SHIM_DIR" ]] || { echo "test_pre_commit_archive_gate.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
REAL_GIT="$(command -v git)"
cat > "$SHIM_DIR/git" <<SHIMEOF
#!/bin/bash
for _a in "\$@"; do
  if [[ "\$_a" == "ls-tree" ]]; then exit 128; fi
done
exec "$REAL_GIT" "\$@"
SHIMEOF
chmod +x "$SHIM_DIR/git"
shim_out="$(cd "$FX" && PATH="$SHIM_DIR:$PATH" bash "$_SC_RUNNER" "$FX" "$FX" 'rd_protected_tree_hash HEAD' 2>/dev/null)"
shim_rc=$?
rm -rf "$SHIM_DIR"
_ok=1
[[ "$shim_rc" != "0" ]] || _ok=0
[[ -z "$shim_out" ]] || _ok=0
assert_eq "fail-closed 4a: ls-tree 실패 시 빈 해시를 내지 않고 nonzero 로 차단" "1" "$_ok"

# 제외 목록 exact-match — spec §2.1 의 9개 항목(디렉터리 5·파일 4).
# 목록을 넓히려면 이 기대값을 함께 고쳐야 합니다. 실행 비트 검사는 설정·source 되는 조각을
# 걸러내지 못해 신뢰 경계를 강제하지 못하므로 쓰지 않습니다 (spec §2.1 Finding 6).
expected_record_paths="$(printf '%s\n' \
  "CURRENT_TASK.md" \
  "REQUEST.md" \
  "rd-workflow-workspace/.lifecycle/review-seals/" \
  "rd-workflow-workspace/.lifecycle/review-skip-audit.log" \
  "rd-workflow-workspace/.lifecycle/task-state" \
  "rd-workflow-workspace/backlog/" \
  "rd-workflow-workspace/handoffs/review_pipeline/" \
  "rd-workflow-workspace/raw-captures/" \
  "rd-workflow-workspace/reports/autopilot/" \
  "rd-workflow-workspace/reports/completions/" \
  "rd-workflow-workspace/reports/reviews/")"
actual_record_paths="$(sc_run "$FX" "$FX" "$FX" 'printf "%s\n" "${RD_RECORD_PATHS[@]}"' | LC_ALL=C sort)"
# 이 검사는 값을 확인하는 것이 아니라 **tripwire** 입니다 (선행 change-spec §6-4).
# 목록에 항목을 더하려면 반드시 여기 기대값도 고쳐야 하므로, 제외 확대가 diff 에 두 번
# 나타나 리뷰어 눈에 띕니다. 「구현 상수를 그대로 베낀 기대값」 금지 규칙의 예외이며,
# 자동 생성으로 바꾸면 tripwire 로서의 목적이 사라집니다.
assert_eq "record-paths 4b: RD_RECORD_PATHS 가 change-spec §3.1 의 11개 항목과 정확히 일치" \
  "$expected_record_paths" "$actual_record_paths"

# 목록 밖 `.lifecycle/` 파일은 보호 대상이어야 합니다 — 바꾸면 해시가 바뀝니다.
h_before="$(hash_of "$FX" HEAD)"
printf 'hook input v2\n' > "$FX/rd-workflow-workspace/.lifecycle/hook-input.sh"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm lifecycle-other >/dev/null 2>&1
assert_ne "record-paths 4c: 목록 밖 .lifecycle/ 파일 변경은 해시를 바꿈" "$h_before" "$(hash_of "$FX" HEAD)"
cleanup_fixture

echo ""
echo "pre_commit_archive_gate: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]] && exit 0 || exit 1
