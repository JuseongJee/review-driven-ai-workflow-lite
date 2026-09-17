#!/bin/bash
# test_guard_state.sh — _guard_common.sh 판정 소스 전환 fixture 테스트
# task-state 존재/부재 × 판정 함수 3종 × 손상 시나리오
# macOS /bin/bash 3.2 호환 (globstar/extglob/연관배열 불사용)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
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
trap 'cleanup_fixture' EXIT INT TERM

# ---------------------------------------------------------------------------
# Fixture 공통 생성 헬퍼
#   fixture 구조: fixture/rd-workflow/scripts/hooks/ (project_root = fixture)
# ---------------------------------------------------------------------------
make_base_fixture() {
  local fixture
  fixture="$(mktemp -d)" || { echo "test_guard_state.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$fixture" && -d "$fixture" ]] || { echo "test_guard_state.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON"  "$fixture/rd-workflow/scripts/_state_common.sh"
  printf '%s' "$fixture"
}

# task-state 파일 쓰기 헬퍼
write_task_state() {
  local fixture="$1" status="$2" short_title="$3"
  local state_path="$fixture/rd-workflow-workspace/.lifecycle/task-state"
  cat > "$state_path" <<EOF
schema=1
short-title=${short_title}
status=${status}
fr-branch=null
worktree-path=null
source-fr=-
EOF
}

# CURRENT_TASK.md 작성 헬퍼
write_current_task() {
  local fixture="$1" status="$2" short_title="$3"
  cat > "$fixture/CURRENT_TASK.md" <<EOF
# Current Task

## Status
${status}

## Short Title
${short_title}
EOF
}

# active-fr 작성 헬퍼
write_active_fr() {
  local fixture="$1" short_title="$2"
  mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
  cat > "$fixture/rd-workflow-workspace/.lifecycle/active-fr" <<EOF
short-title=${short_title}
fr-branch=fr/${short_title}
worktree-path=/tmp/worktree-${short_title}
EOF
}

# ---------------------------------------------------------------------------
# 함수 실행 헬퍼: project_root 주입 후 함수 호출, stdout 반환
# ---------------------------------------------------------------------------
call_guard_fn() {
  local fixture="$1" fn_name="$2"
  # subshell에서 _guard_common.sh source 후 함수 호출
  # project_root를 주입하고, TASK_STATE_PATH도 fixture 경로로 고정
  (
    project_root="$fixture"
    export project_root
    export TASK_STATE_PATH="$fixture/rd-workflow-workspace/.lifecycle/task-state"
    # shellcheck source=/dev/null
    source "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
    "$fn_name"
  ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# assert 헬퍼
# ---------------------------------------------------------------------------
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected='$expected' actual='$actual'" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_fn_return() {
  local label="$1" fn_name="$2" fixture="$3" expected_rc="$4"
  local actual_rc=0
  (
    project_root="$fixture"
    export project_root
    export TASK_STATE_PATH="$fixture/rd-workflow-workspace/.lifecycle/task-state"
    source "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
    "$fn_name"
  ) 2>/dev/null || actual_rc=$?
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo "[PASS] $label (rc=$actual_rc)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected rc=$expected_rc actual rc=$actual_rc" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Fixture 1: task-state(status=구현 중) + CURRENT_TASK.md(Status=완료)
#   get_task_status = "구현 중" — task-state 우선, 뷰 무시 증명
# ---------------------------------------------------------------------------
echo "--- fixture 1: task-state 우선 (뷰 drift 무시) ---"
{
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:133: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  write_task_state "$f" "구현 중" "my-task"
  write_current_task "$f" "완료" "my-task"

  result="$(call_guard_fn "$f" "get_task_status")"
  assert_eq "fixture 1: task-state(구현 중) + 뷰(완료) → get_task_status='구현 중'" "구현 중" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 2: task-state 부재 + CURRENT_TASK.md(Status=구현 중)
#   get_task_status = "구현 중" — legacy fallback
# ---------------------------------------------------------------------------
echo "--- fixture 2: task-state 부재, legacy fallback ---"
{
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:149: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  # task-state 미생성
  write_current_task "$f" "구현 중" "legacy-task"

  result="$(call_guard_fn "$f" "get_task_status")"
  assert_eq "fixture 2: task-state 없음 + 뷰(구현 중) → get_task_status='구현 중'" "구현 중" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 3: task-state(short-title=foo) + active-fr(short-title=bar 잔존)
#   get_current_short_title = "foo" — task-state 우선
# ---------------------------------------------------------------------------
echo "--- fixture 3: short-title task-state 우선 (active-fr 비정상 잔존 무시) ---"
{
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:165: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  write_task_state "$f" "구현 중" "foo"
  write_current_task "$f" "구현 중" "foo"
  write_active_fr "$f" "bar"   # 비정상 잔존

  result="$(call_guard_fn "$f" "get_current_short_title")"
  assert_eq "fixture 3: task-state(short-title=foo) + active-fr(bar) → 'foo'" "foo" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 4: task-state 부재 + CURRENT_TASK.md Short Title '-' + active-fr(short-title=baz)
#   get_current_short_title = "baz" — legacy 체인 유지
# ---------------------------------------------------------------------------
echo "--- fixture 4: legacy 체인 (CURRENT_TASK '-' → active-fr fallback) ---"
{
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:182: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  write_current_task "$f" "구현 중" "-"
  write_active_fr "$f" "baz"

  result="$(call_guard_fn "$f" "get_current_short_title")"
  assert_eq "fixture 4: task-state 없음 + 뷰 '-' + active-fr(baz) → 'baz'" "baz" "$result"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 5: commit_has_archive_signal AS2 검증
#   5a: task-state(status=대기 중, short-title=-) → return 0 (archive 신호)
#   5b: task-state(status=구현 중) → return 1 (archive 신호 없음)
# ---------------------------------------------------------------------------
echo "--- fixture 5: commit_has_archive_signal AS2 ---"
{
  # 5a: 대기 중 + short-title=- → archive 신호 있음 (return 0)
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:200: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  write_task_state "$f" "대기 중" "-"
  write_current_task "$f" "대기 중" "-"
  # git repo 초기화 (commit_has_archive_signal이 git diff --cached 호출)
  git -C "$f" init -q 2>/dev/null
  git -C "$f" config user.email "test@test.com" 2>/dev/null
  git -C "$f" config user.name "Test" 2>/dev/null

  assert_fn_return "fixture 5a: task-state(대기 중, -) → archive 신호(return 0)" \
    "commit_has_archive_signal" "$f" "0"
  cleanup_fixture
}
{
  # 5b: 구현 중 → archive 신호 없음 (return 1)
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:215: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  write_task_state "$f" "구현 중" "some-task"
  write_current_task "$f" "구현 중" "some-task"
  git -C "$f" init -q 2>/dev/null
  git -C "$f" config user.email "test@test.com" 2>/dev/null
  git -C "$f" config user.name "Test" 2>/dev/null

  assert_fn_return "fixture 5b: task-state(구현 중) → archive 신호 없음(return 1)" \
    "commit_has_archive_signal" "$f" "1"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 6: 손상 task-state(status=이상한값)
#   get_task_status → 값 그대로 반환("이상한값")
#   is_nonblocking_status "이상한값" → return 1 (차단 대상)
# ---------------------------------------------------------------------------
echo "--- fixture 6: 손상 task-state — 값 반환 + 비차단 판정 ---"
{
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:235: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  write_task_state "$f" "이상한값" "some-task"
  write_current_task "$f" "구현 중" "some-task"  # 뷰와 달라도 task-state 우선

  # get_task_status는 "이상한값" 그대로 반환해야 함
  result="$(call_guard_fn "$f" "get_task_status")"
  assert_eq "fixture 6a: 손상 task-state(이상한값) → get_task_status='이상한값' 그대로 반환" "이상한값" "$result"

  # is_nonblocking_status "이상한값" → return 1 (차단 대상 = block)
  (
    project_root="$f"
    export project_root
    export TASK_STATE_PATH="$f/rd-workflow-workspace/.lifecycle/task-state"
    source "$f/rd-workflow/scripts/hooks/_guard_common.sh"
    is_nonblocking_status "이상한값"
  ) 2>/dev/null
  rc_nonblocking=$?
  if [[ "$rc_nonblocking" -eq 1 ]]; then
    echo "[PASS] fixture 6b: is_nonblocking_status('이상한값') = return 1(차단 대상)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] fixture 6b: is_nonblocking_status('이상한값') expected rc=1 actual rc=$rc_nonblocking" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# T9 — 종결 마커 strict 검증 (change-spec §3.3) / AC 25 회귀 / seal 선택 규칙
#
# 판정 대상 commit 계약(§3.3.1)에 유의합니다 — 마커·포인터는 워킹트리가 아니라 판정 대상
# commit 에서 읽히므로, fixture 는 마커를 **커밋해야** 검증이 봅니다. 마커·task-state·
# handoffs 는 전부 기록 경로(RD_RECORD_PATHS)라 커밋해도 보호 트리 해시가 변하지 않습니다.
# 그래서 하나의 fixture 에서 마커만 바꿔 커밋하며 10종을 순회할 수 있습니다.
# ---------------------------------------------------------------------------

SEAL_SID="20260906_101500_final-diff-review"

# git 저장소 fixture — 보호 경로(src/, rd-workflow/) 를 1회 커밋해 둡니다.
make_seal_fixture() {
  local f
  f="$(mktemp -d)" || { echo "test_guard_state.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$f" && -d "$f" ]] || { echo "test_guard_state.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  mkdir -p "$f/rd-workflow/scripts/hooks" \
           "$f/rd-workflow-workspace/.lifecycle/review-seals" \
           "$f/rd-workflow-workspace/handoffs/review_pipeline" \
           "$f/src"
  cp "$GUARD_COMMON" "$f/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON"  "$f/rd-workflow/scripts/_state_common.sh"
  echo "9.9.9" > "$f/rd-workflow/VERSION"
  echo "code" > "$f/src/code.txt"
  git -C "$f" init -q >/dev/null 2>&1
  git -C "$f" config user.email "test@test.com" >/dev/null 2>&1
  git -C "$f" config user.name "Test" >/dev/null 2>&1
  git -C "$f" add -A >/dev/null 2>&1
  git -C "$f" commit -qm "init" >/dev/null 2>&1
  printf '%s' "$f"
}

seal_commit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm "record" >/dev/null 2>&1; }

# 보호 트리 해시 (§2.2) — 마커의 tree-hash 기대값
protected_hash() {
  (
    project_root="$1"; export project_root
    source "$1/rd-workflow/scripts/_state_common.sh"
    rd_protected_tree_hash "${2:-HEAD}"
  ) 2>/dev/null
}

# task-state — review-session 포인터를 포함한 형태
write_seal_state() {
  local f="$1" review_session="$2"
  cat > "$f/rd-workflow-workspace/.lifecycle/task-state" <<EOF
schema=1
short-title=t9task
status=아카이브 보류
fr-branch=null
worktree-path=null
source-fr=-
base-commit=null
review-session=${review_session}
EOF
}

# 마커 작성 — 기본값은 유효한 마커이고, 인자로 필드를 덮거나(`key=value`) 지웁니다(`drop=key`).
write_seal() {
  local f="$1" fname="$2"; shift 2
  local schema=1 sid="$fname" rtype="diff-review" hash="$SEAL_HASH" head="$SEAL_HEAD"
  local mode="no-fr" frb="null" ver="9.9.9" verified="yes" sealed="2026-09-06-1200" drop="" kv
  for kv in "$@"; do
    case "$kv" in
      schema=*)      schema="${kv#*=}" ;;
      session-id=*)  sid="${kv#*=}" ;;
      review-type=*) rtype="${kv#*=}" ;;
      tree-hash=*)   hash="${kv#*=}" ;;
      branch-mode=*) mode="${kv#*=}" ;;
      fr-branch=*)   frb="${kv#*=}" ;;
      verified=*)    verified="${kv#*=}" ;;
      drop=*)        drop="${kv#*=}" ;;
    esac
  done
  local out="$f/rd-workflow-workspace/.lifecycle/review-seals/${fname}.seal"
  : > "$out"
  [[ "$drop" != "schema" ]]      && echo "schema=${schema}" >> "$out"
  [[ "$drop" != "session-id" ]]  && echo "session-id=${sid}" >> "$out"
  [[ "$drop" != "review-type" ]] && echo "review-type=${rtype}" >> "$out"
  [[ "$drop" != "tree-hash" ]]   && echo "tree-hash=${hash}" >> "$out"
  [[ "$drop" != "head" ]]        && echo "head=${head}" >> "$out"
  [[ "$drop" != "branch-mode" ]] && echo "branch-mode=${mode}" >> "$out"
  [[ "$drop" != "fr-branch" ]]   && echo "fr-branch=${frb}" >> "$out"
  [[ "$drop" != "rd-version" ]]  && echo "rd-version=${ver}" >> "$out"
  [[ "$drop" != "verified" ]]    && echo "verified=${verified}" >> "$out"
  [[ "$drop" != "sealed-at" ]]   && echo "sealed-at=${sealed}" >> "$out"
  return 0
}

# rd_seal_verify 결과 — 통과면 'OK', 실패면 RD_SEAL_FAIL_MSG 를 출력
seal_verify_msg() {
  local f="$1" src="$2" target="$3" fr="$4"
  (
    project_root="$f"; export project_root
    export TASK_STATE_PATH="$f/rd-workflow-workspace/.lifecycle/task-state"
    source "$f/rd-workflow/scripts/hooks/_guard_common.sh"
    if rd_seal_verify "$src" "$target" "$fr"; then printf 'OK'; else printf '%s' "$RD_SEAL_FAIL_MSG"; fi
  ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixture 7: strict 검증 10종 (§3.3) — 각각 다른 메시지
#   잡는 실수: 복사·오염된 마커나 잘못된 `verified` 값이 통과하는 것, 그리고 사유가 뭉개져
#   사용자가 무엇을 해야 할지 알 수 없게 되는 것 (§4.4 의 복구 안내가 kind 별로 다릅니다).
# ---------------------------------------------------------------------------
echo "--- fixture 7: 마커 strict 검증 10종 ---"
{
  f="$(make_seal_fixture)" || { echo "test_guard_state.sh:371: make_seal_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  SEAL_HASH="$(protected_hash "$f" "HEAD")"
  SEAL_HEAD="$(git -C "$f" rev-parse HEAD 2>/dev/null)"

  # 통제군 — 유효한 마커는 통과해야 합니다. 이것이 없으면 아래 실패 케이스들이 엉뚱한
  # 이유(fixture 파손)로 전부 '통과'해 버립니다.
  write_seal_state "$f" "$SEAL_SID"
  write_seal "$f" "$SEAL_SID"
  seal_commit "$f"
  assert_eq "fixture 7-0: 유효 마커 → 통과" "OK" "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (1) 마커 부재
  rm -f "$f/rd-workflow-workspace/.lifecycle/review-seals/${SEAL_SID}.seal"
  seal_commit "$f"
  assert_eq "fixture 7-1: 마커 부재" \
    "마커 없음 — rd review seal <세션> 을 먼저 실행하세요" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (2) schema 미지원
  write_seal "$f" "$SEAL_SID" "schema=2"; seal_commit "$f"
  assert_eq "fixture 7-2: schema 미지원" \
    "마커 schema 미지원 (파일=2, 지원=1)" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (3) 필수 필드 누락
  write_seal "$f" "$SEAL_SID" "drop=head"; seal_commit "$f"
  assert_eq "fixture 7-3: 필수 필드 누락" \
    "마커 형식 오류 — 누락 필드: head" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (4) 파일명 ↔ 내부 session-id 불일치 (다른 작업의 마커를 복사해 온 상황)
  write_seal "$f" "$SEAL_SID" "session-id=20260101_000000_other-task"; seal_commit "$f"
  assert_eq "fixture 7-4: 파일명↔내부 session-id 불일치(복사)" \
    "마커 세션 불일치 — 복사되었거나 이름이 잘못되었습니다" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (5) 내부 session-id ↔ `review-session` 포인터 불일치 — **독립 재현하지 않습니다.**
  #   마커 경로를 포인터로 조립하는 구조상 (4) 와 항상 같은 조건이라 (4) 가 먼저 발화하며,
  #   포인터를 쓰지 않는 경로가 생겼을 때를 위한 방어입니다 (T6 구현 보고). 도달할 수 없는
  #   경로를 위한 테스트는 만들지 않습니다.

  # (6) review-type 오류
  write_seal "$f" "$SEAL_SID" "review-type=request-review"; seal_commit "$f"
  assert_eq "fixture 7-6: review-type 오류" \
    "마커가 final diff review 의 것이 아닙니다 (review-type=request-review)" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (7) branch-mode 불일치 — 현재 task 는 no-fr 인데 마커는 fr
  write_seal "$f" "$SEAL_SID" "branch-mode=fr" "fr-branch=fr/other"; seal_commit "$f"
  assert_eq "fixture 7-7: branch-mode 불일치" \
    "마커 branch 모드 불일치" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (8) verified enum 위반
  write_seal "$f" "$SEAL_SID" "verified=maybe"; seal_commit "$f"
  assert_eq "fixture 7-8: verified enum 위반" \
    "마커 verified 값이 올바르지 않습니다: maybe" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (9) tree-hash 불일치 — 종결 후 보호 경로가 바뀐 상황을 실제로 만듭니다.
  write_seal "$f" "$SEAL_SID"; seal_commit "$f"
  echo "changed" >> "$f/src/code.txt"; seal_commit "$f"
  assert_eq "fixture 7-9: tree-hash 불일치(종결 후 코드 변경)" \
    "리뷰 대상 불일치 — 종결 후 코드가 변경되었습니다. 재리뷰 후 seal 을 다시 실행하세요" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"
  cleanup_fixture
}
{
  # (10) 해시 계산 실패 — fail-closed. 커밋이 없는 저장소에서 워킹트리 source(§4.4 의
  #   `rd task status` 경로) 로 검증하면 포인터·마커·필드 검사까지 통과한 뒤 `HEAD` 를
  #   commit 으로 해석하지 못해 해시 계산이 실패합니다. 계산 실패를 통과로 흘리는 구현
  #   (빈 해시끼리 일치)이 여기서만 걸립니다.
  f="$(make_base_fixture)" || { echo "test_guard_state.sh:444: make_base_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  mkdir -p "$f/rd-workflow-workspace/.lifecycle/review-seals"
  echo "9.9.9" > "$f/rd-workflow/VERSION"
  git -C "$f" init -q >/dev/null 2>&1
  git -C "$f" config user.email "test@test.com" >/dev/null 2>&1
  git -C "$f" config user.name "Test" >/dev/null 2>&1
  SEAL_HASH="deadbeef"; SEAL_HEAD="deadbeef"
  write_seal_state "$f" "$SEAL_SID"
  write_seal "$f" "$SEAL_SID"
  assert_eq "fixture 7-10: 해시 계산 실패 → 판정 불가로 차단" \
    "보호 트리 해시를 계산할 수 없습니다 — 판정 불가로 차단합니다" \
    "$(seal_verify_msg "$f" "worktree" "" "null")"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 8: AC 25 회귀 — 미종결 리뷰에서 여전히 차단
#   잡는 실수: consumer 를 마커 기반으로 전면 교체하면서, "세션이 있으면 통과" 같은
#   fail-open 이 들어오는 것. 세션 본문은 커밋되어 있고 종결되지 않았으며 마커는 없습니다.
# ---------------------------------------------------------------------------
echo "--- fixture 8: AC 25 회귀 (미종결 리뷰 차단 유지) ---"
{
  f="$(make_seal_fixture)" || { echo "test_guard_state.sh:467: make_seal_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  SEAL_HASH="$(protected_hash "$f" "HEAD")"
  SEAL_HEAD="$(git -C "$f" rev-parse HEAD 2>/dev/null)"
  mkdir -p "$f/rd-workflow-workspace/handoffs/review_pipeline/$SEAL_SID"
  cat > "$f/rd-workflow-workspace/handoffs/review_pipeline/$SEAL_SID/SESSION.md" <<'EOS'
# Review Session

## Status
open

## Open Issues
- 미해결 쟁점이 남아 있습니다.
EOS
  write_seal_state "$f" "$SEAL_SID"   # 포인터는 있으나 마커(seal) 는 없습니다
  seal_commit "$f"

  rc=0
  (
    project_root="$f"; export project_root
    export TASK_STATE_PATH="$f/rd-workflow-workspace/.lifecycle/task-state"
    source "$f/rd-workflow/scripts/hooks/_guard_common.sh"
    archive_review_precheck "0" "" "t9task" "$f/audit.log" "null"
  ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "1" ]]; then
    echo "[PASS] fixture 8: 미종결 리뷰(마커 없음) → archive_review_precheck 차단 (rc=1)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] fixture 8: 미종결 리뷰인데 통과 — expected rc=1 actual rc=$rc" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 9: seal 선택 규칙 (§3.3)
#   잡는 실수: 디렉터리를 뒤져 "최신 마커" 를 고르는 구현. 그러면 stale·타 task 의 마커가
#   섞였을 때 결과가 달라지고, 남아 있는 아무 마커나로 발행이 통과합니다.
# ---------------------------------------------------------------------------
echo "--- fixture 9: seal 선택 규칙 ---"
{
  f="$(make_seal_fixture)" || { echo "test_guard_state.sh:508: make_seal_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  SEAL_HASH="$(protected_hash "$f" "HEAD")"
  SEAL_HEAD="$(git -C "$f" rev-parse HEAD 2>/dev/null)"

  # (a) 포인터 부재
  write_seal_state "$f" "null"
  write_seal "$f" "$SEAL_SID"
  seal_commit "$f"
  assert_eq "fixture 9a: review-session 포인터 부재 → 마커가 있어도 차단" \
    "final diff review 세션이 지정되지 않았습니다 — prepare_review_pipeline.sh diff 로 세션을 만드십시오" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (b) stale — 포인터가 가리키는 마커만 없고 다른 마커는 남아 있음
  write_seal_state "$f" "20260906_120000_second-review"
  seal_commit "$f"
  assert_eq "fixture 9b: stale 포인터 → 남은 다른 마커를 대신 읽지 않음" \
    "마커 없음 — rd review seal <세션> 을 먼저 실행하세요" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (c) 경로 이탈
  write_seal_state "$f" "../../evil"
  seal_commit "$f"
  assert_eq "fixture 9c: 포인터 경로 이탈 → basename 으로 깎지 않고 거부" \
    "review-session 값에 경로 구분자나 '..' 가 있습니다: '../../evil'" \
    "$(seal_verify_msg "$f" "commit" "HEAD" "null")"

  # (d) 디렉터리에 다른 마커가 여럿이어도 지정된 것만 읽음.
  #   나머지는 전부 무효(하나는 tree-hash 불일치, 하나는 verified 위반)라, 디렉터리를
  #   훑는 구현이라면 어느 것을 고르든 통과하지 못합니다.
  write_seal_state "$f" "$SEAL_SID"
  write_seal "$f" "$SEAL_SID"
  write_seal "$f" "20260101_000000_stale-a" "tree-hash=0000000000000000000000000000000000000000"
  write_seal "$f" "20260101_000000_stale-b" "verified=maybe"
  seal_commit "$f"
  assert_eq "fixture 9d: 다른 마커 2개가 섞여 있어도 포인터가 지정한 것만 읽음" \
    "OK" "$(seal_verify_msg "$f" "commit" "HEAD" "null")"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Fixture 10: force-skip 우회의 audit 기록 실패 → 차단
#   잡는 실수: `mkdir -p` 와 append 의 종료 상태를 확인하지 않고 항상 `return 0` 하는 것.
#   그러면 우회의 **유일한 흔적**이 통째로 사라진 채 "audit log 기록" 이라고 잘못 알리고
#   발행이 계속됩니다 (final diff review turn 004 Finding 1).
#   실패는 권한이 아니라 경로 형태로 만듭니다 — root 실행에서도 결과가 같아야 합니다.
# ---------------------------------------------------------------------------
echo "--- fixture 10: force-skip audit 기록 실패 ---"

# force-skip 경로 실행 — rc 는 stdout, 안내는 stderr 로 각각 뽑습니다.
force_skip_rc() {
  local f="$1" audit="$2" rc=0
  (
    project_root="$f"; export project_root
    export TASK_STATE_PATH="$f/rd-workflow-workspace/.lifecycle/task-state"
    source "$f/rd-workflow/scripts/hooks/_guard_common.sh"
    archive_review_precheck "1" "긴급 발행" "t9task" "$audit" "null"
  ) >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}
force_skip_err() {
  local f="$1" audit="$2"
  (
    project_root="$f"; export project_root
    export TASK_STATE_PATH="$f/rd-workflow-workspace/.lifecycle/task-state"
    source "$f/rd-workflow/scripts/hooks/_guard_common.sh"
    archive_review_precheck "1" "긴급 발행" "t9task" "$audit" "null"
  ) 2>&1 >/dev/null
}
# 안내에 사유가 담겼는지 — 담겼으면 'yes', 아니면 실제 문구를 그대로 노출합니다.
err_has() {
  case "$2" in *"$1"*) printf 'yes' ;; *) printf 'no: %s' "$2" ;; esac
}

{
  # 마커는 만들지 않습니다 — 검증이 실패해야 force-skip 경로로 들어갑니다.
  f="$(make_seal_fixture)" || { echo "test_guard_state.sh:584: make_seal_fixture 실패 (rc=$?)" >&2; exit 1; }
  _current_fixture="$f"
  write_seal_state "$f" "$SEAL_SID"
  seal_commit "$f"

  # (a) 통제군 — 정상 audit 경로에서는 통과하고 사유가 실제로 한 줄 남습니다.
  #     이것이 없으면 아래 두 케이스가 "무조건 차단" 하는 구현에서도 통과합니다.
  ok_audit="$f/audit/skip.log"
  assert_eq "fixture 10a: 정상 audit 경로 → force-skip 통과" "0" "$(force_skip_rc "$f" "$ok_audit")"
  assert_eq "fixture 10a: audit 파일에 사유 기록" "긴급 발행" \
    "$(awk -F' \\| ' 'END{print $3}' "$ok_audit" 2>/dev/null)"

  # (b) audit 디렉터리를 만들 수 없음 — 일반 파일 아래 경로라 `mkdir -p` 가 실패합니다.
  printf 'x\n' > "$f/plainfile"
  assert_eq "fixture 10b: audit 디렉터리 생성 불가 → 차단" "1" \
    "$(force_skip_rc "$f" "$f/plainfile/sub/skip.log")"
  assert_eq "fixture 10b: 차단 사유 안내" "yes" \
    "$(err_has "audit 디렉터리를 만들 수 없습니다" "$(force_skip_err "$f" "$f/plainfile/sub/skip.log")")"

  # (c) append 실패 — audit 파일 자리에 디렉터리가 있어 `>>` 가 실패합니다.
  #     디렉터리 자체는 만들 수 있으므로 (b) 와 다른 분기입니다.
  mkdir -p "$f/skip-as-dir"
  assert_eq "fixture 10c: audit append 불가 → 차단" "1" \
    "$(force_skip_rc "$f" "$f/skip-as-dir")"
  assert_eq "fixture 10c: 차단 사유 안내" "yes" \
    "$(err_has "audit log 기록에 실패했습니다" "$(force_skip_err "$f" "$f/skip-as-dir")")"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 결과
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
