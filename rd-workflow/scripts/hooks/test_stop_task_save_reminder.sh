#!/bin/bash
# test_stop_task_save_reminder.sh — stop_task_save_reminder.sh 로직 격리 검증
# macOS /bin/bash 3.2 호환 (globstar/extglob/연관배열 불사용)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
HOOK_SOURCE="$HOOK_DIR/stop_task_save_reminder.sh"
GUARD_COMMON="$HOOK_DIR/_guard_common.sh"
STATE_COMMON="$SCRIPTS_DIR/_state_common.sh"
EP_COMMON="$SCRIPTS_DIR/_edit_provenance_common.sh"
# fixture 의 현재 short-title. 세대 유효성(.short-title 일치) 판정 기준입니다.
EP_TITLE="demo-task"
PASS=0
FAIL=0

# 기준 출력 보관용 (fixture 정리와 수명이 달라 별도 디렉토리를 씁니다)
REASON_TMP="$(mktemp -d)"

_current_fixture=""
cleanup_fixture() {
  if [[ -n "$_current_fixture" && -d "$_current_fixture" ]]; then
    rm -rf "$_current_fixture"
    _current_fixture=""
  fi
}
cleanup_all() {
  cleanup_fixture
  [[ -n "${REASON_TMP:-}" && -d "$REASON_TMP" ]] && rm -rf "$REASON_TMP"
  return 0
}
trap 'cleanup_all' EXIT INT TERM

# ---------------------------------------------------------------------------
# Fixture 생성
#   hook은 script_dir/../../.. 를 project_root로 계산하므로
#   fixture/rd-workflow/scripts/hooks 에 두면 project_root = fixture가 된다.
#
#   인자:
#     $1: Status 값 ("__NONE__"이면 CURRENT_TASK.md 미생성)
#     $2: autopilot ("yes"이면 .autopilot_active 생성)
#     $3: 공용 헬퍼 설치 변종 (부분 install 내성 — AC5(f) · F1)
#         ""           정상 복사
#         "no-ep"      미설치
#         "broken-ep"  구문 오류 파일 (source 하면 파서가 셸을 종료시킴)
#         "partial-ep" 앞부분만 — ep_current_gen 은 정의되고 ep_gen_has_sentinel 부터 없음.
#                      줄 번호가 아니라 **함수명**을 기준으로 잘라 잘라내기가 취약해지지
#                      않게 합니다. 전제(있음/없음)는 F1(b) 케이스가 직접 확인합니다.
# ---------------------------------------------------------------------------
make_fixture() {
  local status="$1" autopilot="$2" no_ep="${3:-}"
  local fixture
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  cp "$HOOK_SOURCE" "$fixture/rd-workflow/scripts/hooks/stop_task_save_reminder.sh"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON"  "$fixture/rd-workflow/scripts/_state_common.sh"
  case "$no_ep" in
    no-ep)      : ;;
    broken-ep)  printf '%s\n' 'broken_fn() {' \
                  > "$fixture/rd-workflow/scripts/_edit_provenance_common.sh" ;;
    partial-ep) awk '/^ep_gen_valid\(\) \{/ { exit } { print }' "$EP_COMMON" \
                  > "$fixture/rd-workflow/scripts/_edit_provenance_common.sh" ;;
    *)          cp "$EP_COMMON" "$fixture/rd-workflow/scripts/_edit_provenance_common.sh" ;;
  esac

  if [[ "$status" != "__NONE__" ]]; then
    # Short Title 섹션도 함께 씁니다 — get_current_short_title() 이 세대 유효성 비교에
    # 쓰는 값이며, 값이 없으면 '.short-title 일치' 케이스를 구성할 수 없습니다.
    printf '%s\n' "# Current Task" "" "## Status" "$status" "" "## Short Title" "$EP_TITLE" \
      > "$fixture/CURRENT_TASK.md"
  fi
  if [[ "$autopilot" == "yes" ]]; then
    touch "$fixture/.autopilot_active"
  fi

  # git repo 초기화 (git ls-files를 위해 필수)
  git -C "$fixture" init -q
  git -C "$fixture" config user.email "test@test.com"
  git -C "$fixture" config user.name "Test"

  printf '%s' "$fixture"
}

# ---------------------------------------------------------------------------
# hook 실행: stdin JSON 주입 → stdout / exit code 캡처
# ---------------------------------------------------------------------------
_hook_last_exit=0
_hook_last_stdout=""
run_hook() {
  local fixture="$1" stdin_json="$2"
  _hook_last_exit=0
  _hook_last_stdout=""
  _hook_last_stdout="$(printf '%s' "$stdin_json" | \
    bash "$fixture/rd-workflow/scripts/hooks/stop_task_save_reminder.sh" 2>/dev/null)" \
    || _hook_last_exit=$?
}

# ---------------------------------------------------------------------------
# assert: stdout에 "decision":"block" 포함 여부 확인
# ---------------------------------------------------------------------------
assert_blocked() {
  local label="$1"
  if printf '%s' "$_hook_last_stdout" | grep -q '"decision":"block"'; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — block 신호 없음 (stdout='$_hook_last_stdout', exit=$_hook_last_exit)" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not_blocked() {
  local label="$1"
  if printf '%s' "$_hook_last_stdout" | grep -q '"decision":"block"'; then
    echo "[FAIL] $label — 예상치 못한 block (stdout='$_hook_last_stdout')" >&2
    FAIL=$((FAIL + 1))
  else
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
# 케이스 1: 진행 중 Status(구현 중) + stale → block
#   CURRENT_TASK.md를 오래된 시간으로, 코드 파일을 최신으로 설정
# ---------------------------------------------------------------------------
echo "--- 케이스 1: 진행 중 + stale → block ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  # CURRENT_TASK.md를 과거 시간으로 설정 (2025-01-01 00:00:00)
  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"

  # git에 추적 파일 추가 (src.sh = 코드 파일)
  printf '%s\n' "#!/bin/bash" "echo hello" > "$fixture/src.sh"
  git -C "$fixture" add "$fixture/CURRENT_TASK.md" "$fixture/src.sh"
  git -C "$fixture" commit -q -m "init"

  # src.sh를 현재 시간으로 갱신 (CURRENT_TASK.md보다 최신)
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_blocked "케이스 1: 진행 중 + stale → block"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 2: 대기 중 / 완료 / 빈 Status → block 없음
# ---------------------------------------------------------------------------
echo "--- 케이스 2: 비차단 Status → block 없음 ---"
for st in "대기 중" "완료" "__NONE__"; do
  fixture="$(make_fixture "$st" "no")"
  _current_fixture="$fixture"

  if [[ "$st" != "__NONE__" ]]; then
    touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"
  fi

  # 코드 파일 추가 (stale 조건 갖춤)
  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add . 2>/dev/null || true
  git -C "$fixture" commit -q -m "init" 2>/dev/null || true
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 2: Status='$st' → block 없음"
  cleanup_fixture
done

# ---------------------------------------------------------------------------
# 케이스 3: autopilot 활성 → block 없음
# ---------------------------------------------------------------------------
echo "--- 케이스 3: autopilot 활성 → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "yes")"
  _current_fixture="$fixture"

  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"
  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 3: autopilot 활성 → block 없음"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 4: stop_hook_active=true → block 없음 (무한루프 방지)
# ---------------------------------------------------------------------------
echo "--- 케이스 4: stop_hook_active=true → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md"
  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":true}'
  assert_not_blocked "케이스 4: stop_hook_active=true → block 없음"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 5: 진행 중 + CURRENT_TASK.md가 추적 파일보다 최신 → block 없음
# ---------------------------------------------------------------------------
echo "--- 케이스 5: 진행 중 + not stale → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  # src.sh를 먼저 오래된 시간으로, CURRENT_TASK.md를 최신으로
  printf '%s\n' "code" > "$fixture/src.sh"
  touch -t 202501010000.00 "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"

  # CURRENT_TASK.md를 현재 시간으로 갱신 (src.sh보다 최신)
  sleep 2
  touch "$fixture/CURRENT_TASK.md"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 5: CURRENT_TASK.md가 더 최신 → block 없음"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 6: 진행 중 + rd-workflow-workspace/ 하위 파일만 최신 → block 없음
#   (산출물 파일은 stale 판정에서 제외되어야 함)
#   픽스처의 hook 파일(rd-workflow/scripts/hooks/)도 추적되므로
#   모든 파일을 과거 시간으로 설정한 뒤 rd-workflow-workspace/ 파일만 최신으로 만듦.
# ---------------------------------------------------------------------------
echo "--- 케이스 6: rd-workflow-workspace/ 만 최신 → block 없음 ---"
{
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"

  mkdir -p "$fixture/rd-workflow-workspace/plans"

  # rd-workflow-workspace/ 하위 파일 (제외 대상)
  printf '%s\n' "plan content" > "$fixture/rd-workflow-workspace/plans/plan.md"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"

  # 추적 파일 전부 + CURRENT_TASK.md를 과거 시간으로 고정
  # (hook 파일 자체도 rd-workflow/ 하위로 추적되므로 함께 과거로 설정)
  _f6=""
  while IFS= read -r _f6; do
    [[ -z "$_f6" ]] && continue
    touch -t 202501010000.00 "$fixture/$_f6" 2>/dev/null || true
  done < <(git -C "$fixture" ls-files)
  touch -t 202501010000.00 "$fixture/CURRENT_TASK.md" 2>/dev/null || true

  # rd-workflow-workspace/ 파일만 현재 시간으로 갱신
  sleep 2
  touch "$fixture/rd-workflow-workspace/plans/plan.md"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 6: rd-workflow-workspace/ 만 최신 → block 없음 (false positive 방지)"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 케이스 7: CURRENT_TASK.md 부재 → block 없음 (fail-open)
# ---------------------------------------------------------------------------
echo "--- 케이스 7: CURRENT_TASK.md 부재 → block 없음 ---"
{
  fixture="$(make_fixture "__NONE__" "no")"
  _current_fixture="$fixture"

  printf '%s\n' "code" > "$fixture/src.sh"
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m "init"
  sleep 2
  touch "$fixture/src.sh"

  run_hook "$fixture" '{"stop_hook_active":false}'
  assert_not_blocked "케이스 7: CURRENT_TASK.md 부재 → block 없음 (fail-open)"
  cleanup_fixture
}

# ===========================================================================
# 편집 출처(edit provenance) 기반 판정 회귀
#   계약: change spec §2.3 / §2.4 / §2.4.2 / §2.4.3 / §2.5 / §2.12
#   fixture 로 기록 구조를 직접 구성해 producer 없이 판정만 검증합니다.
#
#   T24("선행 미기록 쓰기 은폐 순서")는 케이스로 만들지 않습니다 — REQUEST 가 사용자
#   결정으로 수용한 한계이며 검증 대상이 아닙니다 (change spec §4 비목표).
# ===========================================================================

BASE_TS="202501010000.00"      # baseline — CURRENT_TASK.md 와 같은 초
NEWER_TS="202501010001.00"     # baseline 보다 늦음 (무조건 후보)
OLDER_TS="202412310000.00"     # baseline 보다 이름 (후보 아님)
# "writer 가 유예 기간보다 오래 멈춘 상태" 모사용. 어떤 유예 기간보다도 오래된 값이라
# 1일 전보다 강한 조건이며 sleep 없이 결정적입니다 (plan 무삭제4 · Task 2 케이스 26(b)).
STALE_GEN_TS="202412300000.00"

ep_root_of() { printf '%s' "$1/rd-workflow-workspace/.lifecycle/edit-provenance.d"; }

# stdin 의 cksum 을 '<checksum>-<length>' 로 출력 (헬퍼와 같은 형식 — 독립 구현으로 대조)
_ck_pair() {
  local out; out="$(cksum)"
  # shellcheck disable=SC2086
  set -- $out
  printf '%s-%s' "$1" "$2"
}
state_id_of() { _ck_pair < "$1"; }
pathkey_of()  { printf '%s' "$1" | _ck_pair; }

# seed_gen <fixture> <gen> <short-title> — 세대 디렉토리 + .short-title (포인터는 건드리지 않음)
seed_gen() {
  local d; d="$(ep_root_of "$1")/$2"
  mkdir -p "$d"
  printf '%s\n' "$3" > "$d/.short-title"
}
# seed_gen_bare <fixture> <gen> — .short-title 없는 세대 (메타 손상)
seed_gen_bare() { mkdir -p "$(ep_root_of "$1")/$2"; }
# seed_current <fixture> <gen> — .current 포인터. 존재하지 않는 이름도 허용(dangling 케이스)
seed_current() {
  local r; r="$(ep_root_of "$1")"
  mkdir -p "$r"
  printf '%s\n' "$2" > "$r/.current"
}
seed_overflow() { : > "$(ep_root_of "$1")/$2/.overflow"; }
# seed_record <fixture> <gen> <actor> <relpath> [state_id] — state_id 생략 시 실제 cksum
seed_record() {
  local fx="$1" gen="$2" actor="$3" rel="$4" sid="${5:-}"
  [[ -z "$sid" ]] && sid="$(state_id_of "$fx/$rel")"
  printf '%s\t%s\n' "$sid" "$rel" > "$(ep_root_of "$fx")/$gen/$(pathkey_of "$rel").$actor"
}
# seed_raw_record <fixture> <gen> <actor> <relpath> <원시 내용> — malformed 레코드 구성용
seed_raw_record() {
  printf '%s' "$5" > "$(ep_root_of "$1")/$2/$(pathkey_of "$4").$3"
}
# seed_trace <fixture> <내용> — .bump-failed 흔적 (내용을 그대로 씀 — 개행도 인자로 넘김)
seed_trace() {
  local r; r="$(ep_root_of "$1")"
  mkdir -p "$r"
  printf '%s' "$2" > "$r/.bump-failed"
}

# freeze_all <fixture> — 전 추적 파일과 CURRENT_TASK.md 를 baseline 으로 고정.
# fixture 의 hook 스크립트 자체도 추적되므로 함께 고정해야 "후보 0건" 에서 출발합니다.
freeze_all() {
  local fx="$1" f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    touch -t "$BASE_TS" "$fx/$f" 2>/dev/null || true
  done < <(git -C "$fx" ls-files)
  touch -t "$BASE_TS" "$fx/CURRENT_TASK.md" 2>/dev/null || true
}

# new_case [no-ep] — Status='구현 중' + 추적 파일 src.sh·other.sh, 전부 baseline 고정
new_case() {
  local fx
  fx="$(make_fixture "구현 중" "no" "${1:-}")"
  printf '%s\n' "#!/bin/bash" "echo hello" > "$fx/src.sh"
  printf '%s\n' "second file" > "$fx/other.sh"
  # git ls-files 는 인덱스를 읽으므로 add 만으로 충분합니다 (커밋 생략 — 케이스 수가 많아
  # 커밋 비용이 그대로 스위트 실행 시간이 됩니다).
  git -C "$fx" add -A >/dev/null 2>&1
  freeze_all "$fx"
  printf '%s' "$fx"
}
touch_newer() { touch -t "$NEWER_TS" "$1/$2"; }
touch_older() { touch -t "$OLDER_TS" "$1/$2"; }

# ep_invoke <fixture> <함수> [인자...] — fixture 사본을 source 해 헬퍼를 직접 호출
ep_invoke() {
  local fx="$1"; shift
  ( set -uo pipefail
    project_root="$fx"
    # shellcheck source=/dev/null
    source "$fx/rd-workflow/scripts/_edit_provenance_common.sh"
    "$@" )
}

# ep_case <label> <block|pass> <fixture>
ep_case() {
  run_hook "$3" '{"stop_hook_active":false}'
  if [[ "$2" == "block" ]]; then assert_blocked "$1"; else assert_not_blocked "$1"; fi
}

assert_dir_exists() {
  if [[ -d "$2" ]]; then
    echo "[PASS] $1"; PASS=$((PASS + 1))
  else
    echo "[FAIL] $1 — 디렉토리 없음: $2" >&2; FAIL=$((FAIL + 1))
  fi
}
assert_path_absent() {
  if [[ ! -e "$2" ]]; then
    echo "[PASS] $1"; PASS=$((PASS + 1))
  else
    echo "[FAIL] $1 — 경로가 남아 있음: $2" >&2; FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# AC1 — subagent 정규 편집은 억제 (T2·T7·T19)
# ---------------------------------------------------------------------------
echo "--- T2/T7/T19: .sub 일치 → 통과 ---"
{
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "T2: 후보 1개 + .sub state_id 일치 → 통과" pass "$fixture"
  # T7 — 같은 상태로 hook 2회. 판정이 상태를 바꾸지 않으므로 결과가 같아야 합니다.
  ep_case "T7: 같은 상태 2회차 → 통과" pass "$fixture"
  # T19 — 실패 편집은 PostToolUse 미발동이라 레코드가 없고 파일도 안 바뀝니다(mtime 불변).
  ep_case "T19: 실패 편집(레코드·mtime 불변)은 후보 아님 → 통과" pass "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# AC2 — 그 밖의 미저장 변경은 종전대로 block
# ---------------------------------------------------------------------------
echo "--- T1/T3/T9/T10/T12/T13/T15/T21/T20/T22/T23: 미설명 → block ---"
{
  # T1 — 후보 1개가 .orc (다른 파일에는 유효한 .sub 가 있어도 block)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 orc src.sh
  seed_record "$fixture" gen-1 sub other.sh
  ep_case "T1: 후보 1개 + .orc → block" block "$fixture"
  # T13 — 상태를 유지한 채 2회차도 block
  ep_case "T13: .orc 상태 유지 2회차 → block" block "$fixture"
  cleanup_fixture

  # T3 — 후보 2개 (하나는 .sub 일치, 하나는 .orc)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh; touch_newer "$fixture" other.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  seed_record "$fixture" gen-1 orc other.sh
  ep_case "T3: 후보 2개(.sub/.orc) → block" block "$fixture"
  cleanup_fixture

  # T9·T10 — 동일 경로에 .orc 와 .sub 공존 (편집 순서·최종 writer 무관)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  seed_record "$fixture" gen-1 orc src.sh
  ep_case "T9·T10: 동일 경로 .orc+.sub 공존 → block" block "$fixture"
  cleanup_fixture

  # T12 — .orc 만 존재 (.sub 자체가 없음)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 orc src.sh
  ep_case "T12: .orc 만 → block" block "$fixture"
  cleanup_fixture

  # T15·T21 — 후보는 있는데 레코드가 없음 (Bash·외부 프로세스 쓰기)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  ep_case "T15·T21: 후보 있고 레코드 없음 → block" block "$fixture"
  cleanup_fixture

  # T20·T22 — .sub 는 있으나 state_id 불일치 (기록 후 외부 덮어쓰기)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh "0-0"
  ep_case "T20·T22: .sub state_id 불일치 → block" block "$fixture"
  cleanup_fixture

  # T23 — 귀속 교차 검증 실패분은 producer 가 .orc 로 강등해 기록합니다
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 orc src.sh
  ep_case "T23: 검증 실패분(.orc 강등) → block" block "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 같은 초 (mtime == baseline) — 조건부 후보화
# ---------------------------------------------------------------------------
echo "--- T16/T17/T18: 같은 초 조건부 후보화 ---"
{
  # T16 — '편집 → 저장' 순서. 레코드는 이전 세대에만 있으므로 후보가 아닙니다.
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_record "$fixture" gen-1 sub src.sh
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  ep_case "T16: mtime == baseline + 레코드가 이전 세대 → 통과" pass "$fixture"
  cleanup_fixture

  # T17 — '저장 → orchestrator 편집' 순서
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 orc src.sh
  ep_case "T17: mtime == baseline + 현재 세대 .orc → block" block "$fixture"
  cleanup_fixture

  # T18 — '저장 → subagent 편집' 순서
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "T18: mtime == baseline + 현재 세대 .sub 일치 → 통과" pass "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# AC5 — 실패 방향 (세대 부재·레코드 손상·부분 install)
# ---------------------------------------------------------------------------
echo "--- AC5(d)/(e)/(e2)/(f): 실패 방향 ---"
{
  # AC5(d) — 세대 디렉토리 자체가 없음
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  ep_case "AC5(d): 세대 없음 → block (종전 동작)" block "$fixture"
  cleanup_fixture

  # AC5(e) — 레코드 필드 수 3 (extra TAB)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	src.sh	extra
"
  ep_case "AC5(e): 레코드 3필드 → block" block "$fixture"
  cleanup_fixture

  # AC5(e3) — **첫 줄은 정상**이고 뒤에 다른 줄이 붙은 레코드 (final diff review 턴 004 P1).
  # 종전 구현은 첫 물리 줄만 읽어 이 레코드를 유효한 설명으로 받았고, 그 결과 손상 레코드가
  # 넛지를 **없앴습니다**. malformed 는 block 방향이어야 하므로 이 케이스가 그 방향을 고정합니다.
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	src.sh
군더더기 줄
"
  ep_case "AC5(e3): 정상 첫 줄 뒤 추가 줄 → block" block "$fixture"
  cleanup_fixture

  # AC5(e4) — 같은 손상의 최소 형태: 내용은 정상이고 LF 만 하나 더 붙은 레코드.
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	src.sh

"
  ep_case "AC5(e4): 레코드에 추가 LF → block" block "$fixture"
  cleanup_fixture

  # AC5(e5) — 정상 형식의 경계. 종단 LF 가 없는 레코드는 손상이 아니므로 **통과**해야 합니다.
  # 이 케이스가 없으면 위 두 케이스를 "개행이 보이면 거부" 로 과하게 구현해도 초록이 됩니다.
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	src.sh"
  ep_case "AC5(e5): 종단 LF 없는 정상 레코드 → 통과" pass "$fixture"
  cleanup_fixture

  # AC5(e6)/(e7)/(e8) — **필드 구조가 어긋난** 손상 (final diff review 턴 006 P1).
  # 종전 파서는 `IFS=$'\t' read -r sid rp extra` 로 나눴는데, TAB 이 IFS whitespace 라
  # 빈 추가 필드를 세지 못했고(`sid\trp\t` → extra 가 빈 문자열) `read` 가 NUL 을 버려
  # 바이너리 오염까지 정상 2필드로 축약했습니다. 셋 다 넛지를 없애던 경로입니다.
  # TAB·NUL 은 셸 변수를 거치면 경계가 흐려지거나(IFS) 잘리므로(NUL) 파일에 직접 씁니다.
  # seed_raw_record 는 인자를 변수로 받으므로 이 세 케이스에서는 쓰지 않습니다.
  ep_seed_bytes() { # ep_seed_bytes <fixture> <relpath> <printf 형식> — actor=sub 고정
    printf "$3" "$(state_id_of "$1/$2")" "$2" \
      > "$(ep_root_of "$1")/gen-1/$(pathkey_of "$2").sub"
  }

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  ep_seed_bytes "$fixture" src.sh '%s\t%s\t\n'
  ep_case "AC5(e6): 레코드 trailing TAB(빈 3번째 필드) → block" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  ep_seed_bytes "$fixture" src.sh '%s\t%s\t\t\n'
  ep_case "AC5(e7): 레코드 TAB 2개(빈 필드 2개) → block" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  ep_seed_bytes "$fixture" src.sh '%s\t%s\0\n'
  ep_case "AC5(e8): 레코드에 NUL → block" block "$fixture"
  cleanup_fixture

  # AC5(e9) — `.current` 의 추가 LF (턴 006 P1). `_ep_read_whole` 이 LF 를 하나만 지워도
  # 호출자의 command substitution 이 남은 LF 를 전부 지워 'gen-1\n\n' 이 유효 포인터가 됐고,
  # 손상 포인터가 유효 세대를 지시해 넛지가 사라졌습니다. 기존 포인터3b 는 'gen-1\nextra' 만
  # 봤기 때문에 이 경계를 잡지 못했습니다.
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  printf 'gen-1\n\n' > "$(ep_root_of "$fixture")/.current"
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "AC5(e9): .current 추가 LF + 유효 .sub → block" block "$fixture"
  cleanup_fixture

  # AC5(e10) — 포인터 정상 형식의 경계: 종단 LF 가 없어도 유효해야 합니다.
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  printf 'gen-1' > "$(ep_root_of "$fixture")/.current"
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "AC5(e10): .current 종단 LF 없음 + 유효 .sub → 통과" pass "$fixture"
  cleanup_fixture

  # AC5(e2) — pathkey 충돌 모사: 레코드의 relpath 가 다른 경로
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	other.sh
"
  ep_case "AC5(e2): .sub relpath 불일치(pathkey 충돌) → block" block "$fixture"
  cleanup_fixture

  # AC5(f)-1 — 레코드가 하나도 없고 mtime == baseline 파일만 존재 → 종전과 동일하게 통과
  fixture="$(new_case)"; _current_fixture="$fixture"
  ep_case "AC5(f)-1: 레코드 없음 + mtime == baseline → 통과 (종전 동작)" pass "$fixture"
  cleanup_fixture

  # AC5(f)-2 — 공용 헬퍼 미설치 fixture. 레코드가 있어도 무시되고 종전 판정만 남습니다.
  fixture="$(new_case "no-ep")"; _current_fixture="$fixture"
  ep_case "AC5(f)-2: 헬퍼 미설치 + 후보 0건 → 통과" pass "$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "AC5(f)-2: 헬퍼 미설치 + mtime > baseline → block (레코드 무시)" block "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# F1 — 헬퍼 손상·부분 정의·부재는 모두 종전 mtime 판정으로 수렴합니다
#
# final diff review 턴 002 의 P1. 종전 구현은 `source "$_ep_common"` 을 보호 없이 실행했는데,
# 헬퍼에 **구문 오류**가 있으면 파서가 셸 자체를 종료시켜(호출 hook 이 set -euo pipefail)
# Stop hook 이 current_task_is_stale() 에 닿지 못하고 block JSON 을 내지 못했습니다 —
# 세션 한계 대응 넛지가 통째로 사라지는 경로입니다.
# **부분 정의**는 block 은 유지했지만 command-not-found 를 stderr 로 흘렸습니다(무출력 위반).
# 세 갈래 모두 "stale 파일은 여전히 block + stderr 무출력 + exit 0" 이어야 합니다.
#
# 세 케이스 모두 **유효한 .sub 레코드를 심어 둡니다** — 헬퍼가 정상이면 통과했을 조건이므로,
# block 이 나온다는 것은 레코드가 판정에 전혀 쓰이지 않았다는 뜻입니다(종전 동작 수렴 확인).
# ---------------------------------------------------------------------------

# run_hook_err <fixture> <stdin> <stderr 파일> — stderr 를 파일로 받습니다.
# 기존 run_hook 은 stderr 를 버려서 무출력 계약을 잴 수 없습니다.
run_hook_err() {
  local fixture="$1" stdin_json="$2" errfile="$3"
  _hook_last_exit=0
  _hook_last_stdout=""
  _hook_last_stdout="$(printf '%s' "$stdin_json" | \
    bash "$fixture/rd-workflow/scripts/hooks/stop_task_save_reminder.sh" 2>"$errfile")" \
    || _hook_last_exit=$?
}
assert_stderr_empty() {
  if [[ ! -s "$2" ]]; then
    echo "[PASS] $1"; PASS=$((PASS + 1))
  else
    echo "[FAIL] $1 — stderr 누출:" >&2; sed 's/^/    /' "$2" >&2; FAIL=$((FAIL + 1))
  fi
}
assert_exit_zero() {
  if [[ "$_hook_last_exit" -eq 0 ]]; then
    echo "[PASS] $1"; PASS=$((PASS + 1))
  else
    echo "[FAIL] $1 — exit=$_hook_last_exit" >&2; FAIL=$((FAIL + 1))
  fi
}
# ep_case_clean <label> <fixture> — block + stderr 무출력 + exit 0 을 한 번에 봅니다.
ep_case_clean() {
  local label="$1" fx="$2" ef="$REASON_TMP/f1.err"
  run_hook_err "$fx" '{"stop_hook_active":false}' "$ef"
  assert_blocked      "$label — block 유지"
  assert_stderr_empty "$label — stderr 무출력" "$ef"
  assert_exit_zero    "$label — exit 0"
}

echo "--- F1(a)/(b)/(c): 헬퍼 손상·부분 정의·부재 → 종전 판정 수렴 ---"
{
  # (a) 구문 오류 헬퍼. 종전 구현은 여기서 hook 이 exit 2 로 죽어 block 이 사라졌습니다.
  fixture="$(new_case "broken-ep")"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case_clean "F1(a): 헬퍼 구문 오류 + mtime > baseline" "$fixture"
  cleanup_fixture

  # (b) 일부 함수만 정의. **현재 세대가 존재해야** 판정이 후속 함수 호출 지점까지 갑니다 —
  #     ep_current_gen 이 빈 값이면 그 뒤 호출이 아예 실행되지 않아 결함이 드러나지 않습니다.
  fixture="$(new_case "partial-ep")"; _current_fixture="$fixture"
  # fixture 전제 확인 — 잘라내기 기준(함수명)이 바뀌면 이 케이스가 조용히 무의미해집니다.
  _f1_pep="$fixture/rd-workflow/scripts/_edit_provenance_common.sh"
  if grep -q '^ep_current_gen() {' "$_f1_pep" && ! grep -q '^ep_gen_has_sentinel() {' "$_f1_pep"; then
    echo "[PASS] F1(b): fixture 전제 — ep_current_gen 있음 / ep_gen_has_sentinel 없음"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] F1(b): fixture 전제 불성립 — partial-ep 잘라내기 기준을 확인하세요" >&2
    FAIL=$((FAIL + 1))
  fi
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case_clean "F1(b): 헬퍼 일부 함수만 정의 + 현재 세대 존재" "$fixture"
  cleanup_fixture

  # (c) 헬퍼 부재. 판정 결과는 기존 AC5(f)-2 와 같고, 여기서는 stderr·exit 까지 함께 봅니다.
  fixture="$(new_case "no-ep")"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case_clean "F1(c): 헬퍼 부재 + mtime > baseline" "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 세대 수명 — .short-title 불일치·부재
# ---------------------------------------------------------------------------
echo "--- 수명②/②b: 세대 메타 손상 ---"
{
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "other-task"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "수명②: .short-title 불일치 → block" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen_bare "$fixture" gen-1; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "수명②b: .short-title 파일 부재 → block" block "$fixture"
  cleanup_fixture

  # 수명②c~②e (final diff review 턴 008 P1) — **값은 맞고 바이트만 손상된** 메타.
  # 종전에는 첫 줄만 읽어 셋 다 "일치" 로 판정됐고, 그 세대의 유효한 `.sub` 가 편집을 설명해
  # 넛지가 사라졌습니다. 다른 손상은 전부 block 방향인데 여기만 반대였습니다.
  # ②f 는 정상 경계 — 종단 LF 가 없는 메타는 손상이 아니므로 통과해야 합니다.
  _st_seed_meta() { # _st_seed_meta <fixture> <printf 형식>
    seed_gen_bare "$1" gen-1
    printf "$2" "$EP_TITLE" > "$(ep_root_of "$1")/gen-1/.short-title"
    seed_current "$1" gen-1
    seed_record "$1" gen-1 sub src.sh
  }

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  _st_seed_meta "$fixture" '%s\n\n'
  ep_case "수명②c: .short-title 추가 LF → block" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  _st_seed_meta "$fixture" '%s\n군더더기 줄\n'
  ep_case "수명②d: .short-title 추가 줄 → block" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  _st_seed_meta "$fixture" '%s\0\n'
  ep_case "수명②e: .short-title 에 NUL → block" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  _st_seed_meta "$fixture" '%s'
  ep_case "수명②f: .short-title 종단 LF 없음 → 통과" pass "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 포인터 권위 (§2.4.2) — 최대 번호를 고르지 않습니다
# ---------------------------------------------------------------------------
echo "--- 포인터1~5: .current 가 유일한 권위 ---"
{
  # 포인터1 — 유효한 gen-1 잔존 + 포인터가 없는 gen-2 를 가리킴 (dangling)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_record "$fixture" gen-1 sub src.sh
  seed_current "$fixture" gen-2
  ep_case "포인터1: dangling 포인터 → block (잔존 세대 미선택)" block "$fixture"
  cleanup_fixture

  # 포인터2 — .current 파일 자체 부재
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_record "$fixture" gen-1 sub src.sh
  ep_case "포인터2: .current 부재 → block" block "$fixture"
  cleanup_fixture

  # 포인터3 — 내용 malformed
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_record "$fixture" gen-1 sub src.sh
  seed_current "$fixture" "gen-abc"
  ep_case "포인터3: .current malformed → block" block "$fixture"
  cleanup_fixture

  # 포인터3b — 다중행 포인터도 형식 불일치로 거부 (첫 줄만 읽지 않음)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_record "$fixture" gen-1 sub src.sh
  printf 'gen-1\nextra\n' > "$(ep_root_of "$fixture")/.current"
  ep_case "포인터3b: .current 다중행 → block" block "$fixture"
  cleanup_fixture

  # 포인터4 — 두 세대 공존, 유효 레코드는 가리키지 않는 세대에만
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_record "$fixture" gen-1 sub src.sh
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  ep_case "포인터4: 가리키는 세대에 레코드 없음 → block" block "$fixture"
  cleanup_fixture

  # 포인터5 — 정상 선택
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  seed_record "$fixture" gen-2 sub src.sh
  ep_case "포인터5: 가리키는 세대의 유효 레코드 → 통과" pass "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# Finding 1 — 후보화는 '원시 존재' (손상이 후보에서 빠져 통과하는 것을 막음)
# ---------------------------------------------------------------------------
echo "--- F1-a~d: 원시 존재 후보화 ---"
{
  # F1-a — mtime == baseline + malformed .sub (3필드)
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	src.sh	extra
"
  ep_case "F1-a: 같은 초 + malformed .sub → block" block "$fixture"
  cleanup_fixture

  # F1-b — mtime == baseline + .sub relpath 불일치
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	other.sh
"
  ep_case "F1-b: 같은 초 + .sub relpath 불일치 → block" block "$fixture"
  cleanup_fixture

  # F1-c — malformed .orc + 유효한 .sub 공존 (.orc 는 내용 불문 미설명)
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  seed_raw_record "$fixture" gen-1 orc src.sh "쓰레기"
  ep_case "F1-c: malformed .orc + 유효 .sub 공존 → block" block "$fixture"
  cleanup_fixture

  # F1-d — mtime == baseline + malformed .orc 만
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 orc src.sh ""
  ep_case "F1-d: 같은 초 + malformed .orc 만 → block" block "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 센티널 (.overflow) — 세대 무효 + mtime == baseline 무조건 후보화
# ---------------------------------------------------------------------------
echo "--- 센티널1~3: .overflow ---"
{
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_overflow "$fixture" gen-1
  ep_case "센티널1: .overflow + 같은 초 파일(레코드 없음) → block" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  seed_overflow "$fixture" gen-1
  ep_case "센티널2: .overflow + 유효 .sub → block (세대 무효)" block "$fixture"
  cleanup_fixture

  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  seed_overflow "$fixture" gen-1
  ep_case "센티널3: .overflow + mtime > baseline → block" block "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 런타임 무삭제 (§2.9) — 판정은 세대를 하나도 지우지 않습니다
# ---------------------------------------------------------------------------
echo "--- 무삭제1~4: 런타임 삭제 없음 ---"
{
  # 무삭제1 — 포인터=gen-3, 오래된 gen-1·gen-2 잔존. hook 3회.
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_gen "$fixture" gen-2 "$EP_TITLE"
  seed_gen "$fixture" gen-3 "$EP_TITLE"; seed_current "$fixture" gen-3
  seed_record "$fixture" gen-3 sub src.sh
  touch -t "$STALE_GEN_TS" "$(ep_root_of "$fixture")/gen-1" "$(ep_root_of "$fixture")/gen-2"
  ep_case "무삭제1: 1회차 판정 정상 → 통과" pass "$fixture"
  ep_case "무삭제1: 2회차 판정 정상 → 통과" pass "$fixture"
  ep_case "무삭제1: 3회차 판정 정상 → 통과" pass "$fixture"
  assert_dir_exists "무삭제1: gen-1 보존" "$(ep_root_of "$fixture")/gen-1"
  assert_dir_exists "무삭제1: gen-2 보존" "$(ep_root_of "$fixture")/gen-2"
  assert_dir_exists "무삭제1: gen-3 보존" "$(ep_root_of "$fixture")/gen-3"
  cleanup_fixture

  # 무삭제2 — 후보 0건 + 오래된 세대 다수
  fixture="$(new_case)"; _current_fixture="$fixture"
  for _g in gen-1 gen-2 gen-3 gen-4; do seed_gen "$fixture" "$_g" "$EP_TITLE"; done
  seed_current "$fixture" gen-4
  touch -t "$STALE_GEN_TS" "$(ep_root_of "$fixture")"/gen-1 "$(ep_root_of "$fixture")"/gen-2
  ep_case "무삭제2: 후보 0건 → 통과" pass "$fixture"
  for _g in gen-1 gen-2 gen-3 gen-4; do
    assert_dir_exists "무삭제2: $_g 보존" "$(ep_root_of "$fixture")/$_g"
  done
  cleanup_fixture

  # 무삭제3 — 포인터 후진 순서 (turn 016 F1 반례).
  #   gen-5 구성 → ep_bump(gen-6 + 포인터) → 판정 → 포인터를 gen-5 로 되돌림 → 판정
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-5 "$EP_TITLE"
  seed_record "$fixture" gen-5 sub src.sh
  seed_current "$fixture" gen-5
  if ep_invoke "$fixture" ep_bump "$EP_TITLE"; then
    echo "[PASS] 무삭제3: ep_bump 성공"; PASS=$((PASS + 1))
  else
    echo "[FAIL] 무삭제3: ep_bump 실패" >&2; FAIL=$((FAIL + 1))
  fi
  assert_dir_exists "무삭제3: bump 후에도 gen-5 보존" "$(ep_root_of "$fixture")/gen-5"
  ep_case "무삭제3: 포인터=gen-6(레코드 없음) → block" block "$fixture"
  ep_invoke "$fixture" ep_set_current "$(ep_root_of "$fixture")/gen-5"
  ep_case "무삭제3: 포인터 후진(gen-5) → 통과 (dangling 아님)" pass "$fixture"
  assert_dir_exists "무삭제3: 판정 반복 후에도 gen-5 보존" "$(ep_root_of "$fixture")/gen-5"
  assert_dir_exists "무삭제3: gen-6 보존" "$(ep_root_of "$fixture")/gen-6"
  cleanup_fixture

  # 무삭제4 — 위 순서에서 gen-5 를 '오래 멈춘 writer' 로 만든 경우 (turn 018 F1 반례)
  fixture="$(new_case)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-5 "$EP_TITLE"
  seed_record "$fixture" gen-5 sub src.sh
  seed_current "$fixture" gen-5
  ep_invoke "$fixture" ep_bump "$EP_TITLE" >/dev/null 2>&1
  touch -t "$STALE_GEN_TS" "$(ep_root_of "$fixture")/gen-5"
  ep_case "무삭제4: 오래된 gen-5 + 포인터=gen-6 → block" block "$fixture"
  assert_dir_exists "무삭제4: 오래된 gen-5 보존" "$(ep_root_of "$fixture")/gen-5"
  ep_invoke "$fixture" ep_set_current "$(ep_root_of "$fixture")/gen-5"
  ep_case "무삭제4: 포인터=오래된 gen-5 → 통과 (나이 무관)" pass "$fixture"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# §2.12 가시성 — .bump-failed 는 판정에 참여하지 않습니다
# ---------------------------------------------------------------------------
echo "--- 가시성1~2: .bump-failed 판정 비참여 ---"
{
  # 가시성1 — 통과 상태·block 상태 각각에서 흔적 유무가 판정을 바꾸지 않음
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  ep_case "가시성1: 통과 상태 + 흔적 없음 → 통과" pass "$fixture"
  seed_trace "$fixture" "pointer-swap"
  ep_case "가시성1: 통과 상태 + 흔적 있음 → 통과 (동일)" pass "$fixture"
  touch_newer "$fixture" src.sh
  ep_case "가시성1: block 상태 + 흔적 있음 → block" block "$fixture"
  rm -f "$(ep_root_of "$fixture")/.bump-failed"
  ep_case "가시성1: block 상태 + 흔적 없음 → block (동일)" block "$fixture"
  cleanup_fixture

  # 가시성2 — 같은 초 'orchestrator 편집 → 저장 → bump 실패'.
  #   포인터가 이전 세대에 남아 .orc 원시 존재가 파일을 다시 후보화합니다.
  #   안전한 false positive 이며, 사용자는 reason 의 사유 문구로 원인을 알 수 있습니다.
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 orc src.sh
  seed_trace "$fixture" "pointer-swap"
  ep_case "가시성2: 같은 초 편집→저장→bump 실패 → block" block "$fixture"
  if printf '%s' "$_hook_last_stdout" | grep -q '지점: pointer-swap'; then
    echo "[PASS] 가시성2: reason 에 실패 지점 표시"; PASS=$((PASS + 1))
  else
    echo "[FAIL] 가시성2: reason 에 실패 지점 없음 (stdout='$_hook_last_stdout')" >&2
    FAIL=$((FAIL + 1))
  fi
  if [[ -f "$(ep_root_of "$fixture")/.bump-failed" ]]; then
    echo "[PASS] 가시성2: 흔적 보존"; PASS=$((PASS + 1))
  else
    echo "[FAIL] 가시성2: 흔적 소실" >&2; FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# AC7 / §2.12 ② — block reason 의 <stage> allowlist (파일 전체 대조)
#   비허용 갈래는 기준 출력과 **바이트 동일**해야 합니다.
# ---------------------------------------------------------------------------
echo "--- reason (a)~(j): <stage> allowlist ---"

BASE_OUT="$REASON_TMP/base.json"
G_OUT="$REASON_TMP/g.json"

# run_hook_to <fixture> <stdin> <outfile> — stdout 을 파일로 받아 바이트 비교에 씁니다
run_hook_to() {
  local fixture="$1" stdin_json="$2" outfile="$3"
  _hook_last_exit=0
  printf '%s' "$stdin_json" | \
    bash "$fixture/rd-workflow/scripts/hooks/stop_task_save_reminder.sh" > "$outfile" 2>/dev/null \
    || _hook_last_exit=$?
  _hook_last_stdout="$(cat "$outfile")"
}
assert_bytes_equal() {
  if cmp -s "$2" "$3"; then
    echo "[PASS] $1"; PASS=$((PASS + 1))
  else
    echo "[FAIL] $1 — 기준 출력과 바이트 불일치" >&2
    FAIL=$((FAIL + 1))
  fi
}
# new_block_case — 판정이 반드시 block 인 fixture (src.sh 만 baseline 보다 늦음, 레코드 없음).
# reason 문구 대조는 판정 결과와 무관하게 같은 조건에서 이뤄져야 하므로 한 곳에서 만듭니다.
new_block_case() {
  local fx
  fx="$(new_case)"
  touch_newer "$fx" src.sh
  printf '%s' "$fx"
}

# (a) 흔적 부재 → 기준 출력
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$BASE_OUT"
  assert_blocked "(a) 흔적 부재 → block"
  if printf '%s' "$_hook_last_stdout" | grep -q '참고: 직전 저장'; then
    echo "[FAIL] (a) 흔적 부재인데 사유 문구가 있음" >&2; FAIL=$((FAIL + 1))
  else
    echo "[PASS] (a) 흔적 부재 → 사유 문구 없음"; PASS=$((PASS + 1))
  fi
  cleanup_fixture
}

# (b) 빈 파일 (0바이트)
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" ""
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/b.json"
  assert_bytes_equal "(b) 빈 파일 → 기준과 바이트 동일" "$BASE_OUT" "$REASON_TMP/b.json"
  cleanup_fixture
}

# (c) LF 하나만
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" "
"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/c.json"
  assert_bytes_equal "(c) LF 하나 → 기준과 바이트 동일" "$BASE_OUT" "$REASON_TMP/c.json"
  cleanup_fixture
}

# (d) 읽기 실패 — 흔적 경로를 디렉토리로 만듦 (chmod 없이 결정적)
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  mkdir -p "$(ep_root_of "$fixture")/.bump-failed"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/d.json"
  assert_bytes_equal "(d) 읽기 실패(디렉토리) → 기준과 바이트 동일" "$BASE_OUT" "$REASON_TMP/d.json"
  cleanup_fixture
}

# (e) 임의 비허용 한 줄 — 인젝션 시도
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" '"; rm -r /'
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/e.json"
  assert_bytes_equal "(e) 임의 내용 → 기준과 바이트 동일" "$BASE_OUT" "$REASON_TMP/e.json"
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.loads(open(sys.argv[1]).read())' "$REASON_TMP/e.json" \
         >/dev/null 2>&1; then
      echo "[PASS] (e) 출력이 유효한 JSON"; PASS=$((PASS + 1))
    else
      echo "[FAIL] (e) 출력이 유효한 JSON 이 아님" >&2; FAIL=$((FAIL + 1))
    fi
  else
    echo "[PASS] (e) JSON 파싱 검증 skip (python3 부재)"; PASS=$((PASS + 1))
  fi
  cleanup_fixture
}

# (f) 허용 토큰 + 추가 줄 — 첫 줄만 읽는 구현을 잡는 케이스
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" "pointer-swap
추가 줄
"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/f.json"
  assert_bytes_equal "(f) 다중행 → 기준과 바이트 동일" "$BASE_OUT" "$REASON_TMP/f.json"
  cleanup_fixture
}

# (g) 허용 토큰 (종단 LF 없음) → 사유 포함 + decision=block
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" "pointer-swap"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$G_OUT"
  assert_blocked "(g) 허용 토큰 → decision=block"
  if printf '%s' "$_hook_last_stdout" | grep -q '지점: pointer-swap'; then
    echo "[PASS] (g) 허용 토큰 → 사유 포함"; PASS=$((PASS + 1))
  else
    echo "[FAIL] (g) 허용 토큰인데 사유 없음 (stdout='$_hook_last_stdout')" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# (h) 허용 토큰 + 종단 LF 1개 → (g)와 동일 결과
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" "pointer-swap
"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/h.json"
  assert_bytes_equal "(h) 종단 LF 1개 → (g)와 바이트 동일" "$G_OUT" "$REASON_TMP/h.json"
  cleanup_fixture
}

# (h2) 나머지 허용 토큰 3종도 사유가 붙는지 확인
{
  for _tok in mkdir short-title recheck; do
    fixture="$(new_block_case)"; _current_fixture="$fixture"
    seed_trace "$fixture" "$_tok"
    run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/tok.json"
    if printf '%s' "$_hook_last_stdout" | grep -q "지점: $_tok"; then
      echo "[PASS] (h2) 허용 토큰 '$_tok' → 사유 포함"; PASS=$((PASS + 1))
    else
      echo "[FAIL] (h2) 허용 토큰 '$_tok' → 사유 없음" >&2; FAIL=$((FAIL + 1))
    fi
    cleanup_fixture
  done
}

# (i) 허용 토큰 + 판정이 통과 → 무출력
{
  fixture="$(new_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" "pointer-swap"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/i.json"
  if [[ -z "$_hook_last_stdout" && ! -s "$REASON_TMP/i.json" ]]; then
    echo "[PASS] (i) 판정 통과 + 흔적 있음 → 무출력"; PASS=$((PASS + 1))
  else
    echo "[FAIL] (i) 판정 통과인데 출력이 있음 (stdout='$_hook_last_stdout')" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# (j) 허용 토큰 → 이후 bump 성공 → 사유 소멸
{
  fixture="$(new_block_case)"; _current_fixture="$fixture"
  seed_trace "$fixture" "pointer-swap"
  ep_invoke "$fixture" ep_bump "$EP_TITLE" >/dev/null 2>&1
  assert_path_absent "(j) bump 성공 → 흔적 삭제" "$(ep_root_of "$fixture")/.bump-failed"
  run_hook_to "$fixture" '{"stop_hook_active":false}' "$REASON_TMP/j.json"
  assert_bytes_equal "(j) bump 성공 후 → 기준과 바이트 동일 (사유 소멸)" "$BASE_OUT" "$REASON_TMP/j.json"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 결과 출력
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
