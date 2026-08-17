#!/bin/bash
# test_edit_provenance_record.sh — edit_provenance_record.sh(PostToolUse producer) 격리 검증
#
# 케이스 번호·값·문구는 plan 의 task-2-brief.md 를 그대로 따릅니다 (케이스 1~27).
# payload 는 선행 실증 report(2026-08-13-2105-posttooluse-payload-probe.md)의 **실제 구조**를
# 따릅니다 — orchestrator 는 agent_type·agent_id 키가 **아예 없고**, subagent 는 두 필드가 실립니다.
#
# 격리: 모든 fixture 는 mktemp -d 이고 provenance 루트는 RD_EDIT_PROVENANCE_DIR 로 fixture 안을
# 가리킵니다. 실제 워크스페이스를 건드리지 않습니다.
#
# 실패 주입 원칙: 권한(chmod) 조작을 쓰지 않습니다. 헬퍼를 직접 호출하는 케이스는 셸 함수
# override(mkdir/mv/rm), hook 을 통째로 실행하는 케이스는 권한 비의존 수단(ENOTDIR·이름 충돌·
# 구문 오류 파일·파일 삭제)이나 결과 상태 fixture 를 씁니다.
#
# macOS /bin/bash 3.2 호환 (연관배열·globstar·extglob·mapfile 불사용)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
PRODUCER_SRC="$HOOK_DIR/edit_provenance_record.sh"
CONSUMER_SRC="$HOOK_DIR/stop_task_save_reminder.sh"
GUARD_COMMON="$HOOK_DIR/_guard_common.sh"
STATE_COMMON="$SCRIPTS_DIR/_state_common.sh"
EP_COMMON="$SCRIPTS_DIR/_edit_provenance_common.sh"

# fixture 의 현재 short-title. 세대 유효성(.short-title 일치) 판정 기준입니다.
EP_TITLE="demo-task"

# 판정용 mtime 상수 (형식·의미는 test_stop_task_save_reminder.sh 와 같습니다)
BASE_TS="202501010000.00"    # baseline — CURRENT_TASK.md 와 같은 초
NEWER_TS="202501010001.00"   # baseline 보다 늦음 (무조건 후보)
# "writer 가 유예 기간보다 오래 멈춘 상태" 모사용 (케이스 26(b)). 1일 전보다 강한 고정값이라
# sleep 없이 결정적입니다.
OLD_TS="202412300000.00"

PASS=0
FAIL=0

# payload·출력 보관용 (fixture 와 수명이 달라 별도 디렉토리를 씁니다)
WORK="$(mktemp -d)"

_current_fixture=""
_EP_ROOT=""       # provenance 루트 override (케이스 15(a) 처럼 비정상 루트를 둘 때만 설정)

cleanup_fixture() {
  if [[ -n "$_current_fixture" && -d "$_current_fixture" ]]; then
    rm -rf "$_current_fixture"
    _current_fixture=""
  fi
  _EP_ROOT=""
}
cleanup_all() {
  cleanup_fixture
  [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"
  return 0
}
trap 'cleanup_all' EXIT INT TERM

# jq 게이트 — 이 스위트는 **payload 를 바이트 정확히 구성**하는 데 jq(--rawfile)를 씁니다.
# 훅 경로 자체는 jq 없이도 동작하며 그 갈래는 케이스 14 가 따로 검증합니다.
if ! command -v jq >/dev/null 2>&1; then
  echo "[SKIP] jq 부재 — 이 스위트는 payload 구성에 jq 를 요구합니다 (훅 자체는 jq 없이도 동작)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 결과 기록
# ---------------------------------------------------------------------------
ok()  { echo "[PASS] $1"; PASS=$((PASS + 1)); }
no()  { echo "[FAIL] $1${2:+ — $2}" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# 상태 식별자·pathkey 독립 구현 (헬퍼와 대조 — 헬퍼 버그를 테스트가 함께 따라가지 않게 합니다)
# ---------------------------------------------------------------------------
_ck_pair() {
  local out; out="$(cksum)"
  # shellcheck disable=SC2086
  set -- $out
  printf '%s-%s' "$1" "$2"
}
state_id_of() { _ck_pair < "$1"; }
pathkey_of()  { printf '%s' "$1" | _ck_pair; }

ep_root_of() {
  if [[ -n "$_EP_ROOT" ]]; then
    printf '%s' "$_EP_ROOT"
  else
    printf '%s' "$1/rd-workflow-workspace/.lifecycle/edit-provenance.d"
  fi
}

# ---------------------------------------------------------------------------
# Fixture
#   hook 은 script_dir/../../.. 를 project_root 로 계산하므로
#   fixture/rd-workflow/scripts/hooks 에 두면 project_root = fixture 가 됩니다.
# ---------------------------------------------------------------------------

# mk_prod — producer 전용 fixture (git 없음 — producer 는 git 을 쓰지 않습니다)
mk_prod() {
  local fx
  fx="$(mktemp -d)"
  mkdir -p "$fx/rd-workflow/scripts/hooks" "$fx/rd-workflow-workspace/plans"
  cp "$PRODUCER_SRC" "$fx/rd-workflow/scripts/hooks/edit_provenance_record.sh"
  cp "$CONSUMER_SRC" "$fx/rd-workflow/scripts/hooks/stop_task_save_reminder.sh"
  cp "$GUARD_COMMON" "$fx/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON" "$fx/rd-workflow/scripts/_state_common.sh"
  cp "$EP_COMMON"    "$fx/rd-workflow/scripts/_edit_provenance_common.sh"
  printf '%s\n' "# Current Task" "" "## Status" "구현 중" "" "## Short Title" "$EP_TITLE" \
    > "$fx/CURRENT_TASK.md"
  printf '%s\n' "#!/bin/bash" "echo hello" > "$fx/src.sh"
  printf '%s\n' "second file"              > "$fx/other.sh"
  printf '%s\n' "third file"               > "$fx/third.sh"
  printf '%s\n' "fourth file"              > "$fx/fourth.sh"
  printf '%s\n' "plan content"             > "$fx/rd-workflow-workspace/plans/p.md"
  printf '%s' "$fx"
}

# mk_full — mk_prod + git 인덱스 + 전 추적 파일 baseline 고정 (consumer 판정 케이스용).
# fixture 의 hook 스크립트 자체도 추적되므로 함께 고정해야 "후보 0건" 에서 출발합니다.
# 커밋은 하지 않습니다 — git ls-files 는 인덱스를 읽으므로 add 만으로 충분합니다.
mk_full() {
  local fx f
  fx="$(mk_prod)"
  git -C "$fx" init -q >/dev/null 2>&1
  git -C "$fx" config user.email "test@test.com" >/dev/null 2>&1
  git -C "$fx" config user.name "Test" >/dev/null 2>&1
  git -C "$fx" add -A >/dev/null 2>&1
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    touch -t "$BASE_TS" "$fx/$f" 2>/dev/null || true
  done < <(git -C "$fx" ls-files)
  touch -t "$BASE_TS" "$fx/CURRENT_TASK.md" 2>/dev/null || true
  printf '%s' "$fx"
}

touch_newer() { touch -t "$NEWER_TS" "$1/$2"; }

# ---------------------------------------------------------------------------
# 기록 구조 seed (test_stop_task_save_reminder.sh 와 같은 규약)
# ---------------------------------------------------------------------------
seed_gen() {
  local d; d="$(ep_root_of "$1")/$2"
  mkdir -p "$d"
  printf '%s\n' "$3" > "$d/.short-title"
}
seed_gen_bare() { mkdir -p "$(ep_root_of "$1")/$2"; }
seed_current() {
  local r; r="$(ep_root_of "$1")"
  mkdir -p "$r"
  printf '%s\n' "$2" > "$r/.current"
}
seed_overflow() { : > "$(ep_root_of "$1")/$2/.overflow"; }
# seed_record <fixture> <gen> <actor> <relpath> [state_id]
seed_record() {
  local fx="$1" gen="$2" actor="$3" rel="$4" sid="${5:-}"
  [[ -z "$sid" ]] && sid="$(state_id_of "$fx/$rel")"
  printf '%s\t%s\n' "$sid" "$rel" > "$(ep_root_of "$fx")/$gen/$(pathkey_of "$rel").$actor"
}
# seed_raw_record <fixture> <gen> <actor> <relpath> <원시 내용>
seed_raw_record() {
  printf '%s' "$5" > "$(ep_root_of "$1")/$2/$(pathkey_of "$4").$3"
}
# seed_dummy_records <fixture> <gen> <n> — 상한 케이스용 더미 레코드.
# 이름을 'dummyN.orc' 로 두어 실제 pathkey('<숫자>-<숫자>') 와 절대 겹치지 않게 합니다.
seed_dummy_records() {
  local d i
  d="$(ep_root_of "$1")/$2"
  i=1
  while [[ $i -le $3 ]]; do
    : > "$d/dummy${i}.orc"
    i=$((i + 1))
  done
}
count_records() { /bin/ls -1 "$(ep_root_of "$1")/$2" 2>/dev/null | wc -l | tr -d '[:space:]'; }
count_gens() { /bin/ls -1d "$(ep_root_of "$1")"/gen-* 2>/dev/null | wc -l | tr -d '[:space:]'; }

# ---------------------------------------------------------------------------
# payload 구성
#   resp_* 가 tool_response 객체를 파일로 만들고, payload 가 최상위 객체를 조립합니다.
#   --rawfile / --slurpfile 만 씁니다 — 셸 변수를 거치면 종단 개행이 사라져 바이트 경계
#   케이스(13)가 무의미해집니다.
#   키 순서를 실측 payload 와 같게(tool_input → tool_name → tool_response) 두어 jq 부재
#   갈래(케이스 14)의 bash 폴백이 tool_input.file_path 를 먼저 만나게 합니다.
# ---------------------------------------------------------------------------

# resp_write <out> <content-file> <original-file>
resp_write() {
  jq -nc --rawfile c "$2" --rawfile o "$3" \
    '{type:"update", content:$c, originalFile:$o, structuredPatch:[], userModified:false}' > "$1"
}
# resp_edit <out> <original-file> <oldString> <new-file> <replaceAll true|false>
resp_edit() {
  jq -nc --rawfile o "$2" --arg old "$3" --rawfile n "$4" --argjson ra "$5" \
    '{oldString:$old, newString:$n, originalFile:$o, structuredPatch:[], replaceAll:$ra,
      userModified:false}' > "$1"
}
resp_null() { printf 'null\n' > "$1"; }

# payload <out> <file_path|-> <tool_name> <orc|sub|subid> <resp-file>
#   '-' file_path → tool_input 에 file_path 키를 넣지 않습니다 (케이스 6)
#   orc   → agent_type·agent_id 키 **부재** (실증 report 1항)
#   sub   → agent_type='general-purpose' + agent_id
#   subid → agent_type='' + agent_id 만 값 (폴백 계약 — 케이스 3)
payload() {
  local out="$1" fp="$2" tn="$3" actor="$4" resp="$5" actorobj='{}' ti
  case "$actor" in
    sub)   actorobj='{"agent_type":"general-purpose","agent_id":"a7853342a73331d91"}' ;;
    subid) actorobj='{"agent_type":"","agent_id":"a7853342a73331d91"}' ;;
  esac
  if [[ "$fp" == "-" ]]; then ti='{}'; else ti="$(jq -nc --arg fp "$fp" '{file_path:$fp}')"; fi
  jq -nc --arg tn "$tn" --argjson actor "$actorobj" --argjson ti "$ti" \
     --slurpfile resp "$resp" '
    {cwd:"/tmp/cwd", duration_ms:12, effort:"medium", hook_event_name:"PostToolUse",
     permission_mode:"auto", session_id:"sess-1"}
    + $actor
    + {tool_input:$ti, tool_name:$tn, tool_response:$resp[0],
       tool_use_id:"toolu_1", transcript_path:"/tmp/t.jsonl"}' > "$out"
}

# pl_write <out> <fx> <relpath> <orc|sub|subid> — 파일 내용과 payload content 가 **일치**하는 Write
pl_write() {
  resp_write "$WORK/resp.json" "$2/$3" "$WORK/empty.txt"
  payload "$1" "$2/$3" Write "$4" "$WORK/resp.json"
}

# ---------------------------------------------------------------------------
# 실행
# ---------------------------------------------------------------------------
_prod_exit=0
_prod_out=""
_prod_err=""

# run_producer <fixture> <payload-file> [PATH override]
# /bin/bash(3.2.57)로 직접 실행해 bash 3.2 호환도 함께 검증합니다.
run_producer() {
  local fx="$1" pl="$2" pathov="${3:-}"
  _prod_exit=0
  : > "$WORK/prod.out"; : > "$WORK/prod.err"
  if [[ -n "$pathov" ]]; then
    PATH="$pathov" RD_EDIT_PROVENANCE_DIR="$(ep_root_of "$fx")" \
      /bin/bash "$fx/rd-workflow/scripts/hooks/edit_provenance_record.sh" \
      < "$pl" > "$WORK/prod.out" 2> "$WORK/prod.err" || _prod_exit=$?
  else
    RD_EDIT_PROVENANCE_DIR="$(ep_root_of "$fx")" \
      /bin/bash "$fx/rd-workflow/scripts/hooks/edit_provenance_record.sh" \
      < "$pl" > "$WORK/prod.out" 2> "$WORK/prod.err" || _prod_exit=$?
  fi
  _prod_out="$(cat "$WORK/prod.out")"
  _prod_err="$(cat "$WORK/prod.err")"
}

# run_producer_bg <fixture> <payload-file> — 동시 경합 케이스용 (백그라운드)
run_producer_bg() {
  RD_EDIT_PROVENANCE_DIR="$(ep_root_of "$1")" \
    /bin/bash "$1/rd-workflow/scripts/hooks/edit_provenance_record.sh" \
    < "$2" >/dev/null 2>&1 &
}

_cons_out=""
_cons_verdict=""
run_consumer() {
  local fx="$1"
  _cons_out=""
  _cons_out="$(printf '%s' '{"stop_hook_active":false}' | \
    RD_EDIT_PROVENANCE_DIR="$(ep_root_of "$fx")" \
    /bin/bash "$fx/rd-workflow/scripts/hooks/stop_task_save_reminder.sh" 2>/dev/null)" || true
  if printf '%s' "$_cons_out" | grep -q '"decision":"block"'; then
    _cons_verdict="block"
  else
    _cons_verdict="pass"
  fi
}

# ep_invoke <fixture> <함수> [인자...] — fixture 사본을 source 해 헬퍼를 직접 호출
ep_invoke() {
  local fx="$1"; shift
  ( set -uo pipefail
    project_root="$fx"
    export RD_EDIT_PROVENANCE_DIR="$(ep_root_of "$fx")"
    # shellcheck source=/dev/null
    source "$fx/rd-workflow/scripts/_edit_provenance_common.sh"
    "$@" )
}

# ep_invoke_with <fixture> <override 코드> <함수> [인자...]
# 셸 함수 override 로 rm·mv·mkdir 실패를 주입합니다 (헬퍼가 `command` 접두 없이 평문 호출하는 계약).
ep_invoke_with() {
  local fx="$1" ov="$2"; shift 2
  ( set -uo pipefail
    project_root="$fx"
    export RD_EDIT_PROVENANCE_DIR="$(ep_root_of "$fx")"
    # shellcheck source=/dev/null
    source "$fx/rd-workflow/scripts/_edit_provenance_common.sh"
    eval "$ov"
    "$@" )
}

# ---------------------------------------------------------------------------
# assert
# ---------------------------------------------------------------------------
assert_prod_ok() {   # exit 0 + stdout·stderr 무출력 (producer 는 절대 차단하지 않습니다)
  if [[ "$_prod_exit" -ne 0 ]]; then
    no "$1" "exit=$_prod_exit"
  elif [[ -n "$_prod_out" || -n "$_prod_err" ]]; then
    no "$1" "출력 있음 (stdout='$_prod_out' stderr='$_prod_err')"
  else
    ok "$1"
  fi
}

# assert_actor <label> <fx> <gen> <relpath> <orc|sub>
# 기대 actor 레코드가 '<실제 cksum>\t<relpath>' 로 있고 반대 actor 레코드는 없음을 확인합니다.
assert_actor() {
  local label="$1" fx="$2" gen="$3" rel="$4" want="$5" other="sub" root pk f g exp got
  [[ "$want" == "sub" ]] && other="orc"
  root="$(ep_root_of "$fx")"; pk="$(pathkey_of "$rel")"
  f="$root/$gen/$pk.$want"; g="$root/$gen/$pk.$other"
  if [[ ! -f "$f" ]]; then no "$label" ".$want 레코드 없음"; return; fi
  if [[ -e "$g" ]]; then no "$label" "반대 행위자 레코드(.$other)가 존재"; return; fi
  exp="$(state_id_of "$fx/$rel")"$'\t'"$rel"
  got="$(cat "$f")"
  if [[ "$got" == "$exp" ]]; then ok "$label"; else no "$label" "내용 불일치 '$got' != '$exp'"; fi
}

assert_no_records() {  # <label> <fx> <gen>
  local n; n="$(count_records "$2" "$3")"
  if [[ "$n" == "0" ]]; then ok "$1"; else no "$1" "레코드 ${n}건 존재"; fi
}
assert_exists()  { if [[ -e "$2" ]]; then ok "$1"; else no "$1" "경로 없음: $2"; fi; }
assert_absent()  { if [[ ! -e "$2" ]]; then ok "$1"; else no "$1" "경로가 존재: $2"; fi; }
assert_file_is() {  # <label> <path> <기대 내용(종단 개행 무시)>
  local got
  if [[ ! -f "$2" ]]; then no "$1" "파일 없음: $2"; return; fi
  got="$(cat "$2")"
  if [[ "$got" == "$3" ]]; then ok "$1"; else no "$1" "'$got' != '$3'"; fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "'$2' != '$3'"; fi; }
assert_verdict() { # <label> <fx> <block|pass>
  run_consumer "$2"
  if [[ "$_cons_verdict" == "$3" ]]; then ok "$1"; else no "$1" "판정=$_cons_verdict (기대 $3)"; fi
}
# record_is_parsable <file> <relpath> — 2필드 + relpath 일치
record_is_parsable() {
  [[ -f "$1" ]] || return 1
  awk -F'\t' -v want="$2" 'NR==1{ if (NF != 2) exit 1; if ($2 != want) exit 1; ok=1 }
                           END{ if (!ok) exit 1 }' "$1"
}

: > "$WORK/empty.txt"

# ===========================================================================
# 케이스 1~3 — 행위자 판별
# ===========================================================================
echo "--- 케이스 1~3: 행위자 판별 ---"
{
  # 1. orchestrator payload(행위자 키 없음) → <pathkey>.orc, 내용 '<실제 cksum>\t<relpath>'
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p1.json" "$fixture" src.sh orc
  run_producer "$fixture" "$WORK/p1.json"
  assert_prod_ok "케이스 1: orchestrator payload → exit 0 무출력"
  assert_actor "케이스 1: orchestrator → .orc + 내용 '<cksum>\\t<relpath>'" "$fixture" gen-1 src.sh orc
  cleanup_fixture

  # 2. subagent payload(agent_type=general-purpose) → .sub
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p2.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p2.json"
  assert_prod_ok "케이스 2: subagent payload → exit 0 무출력"
  assert_actor "케이스 2: agent_type=general-purpose → .sub" "$fixture" gen-1 src.sh sub
  cleanup_fixture

  # 3. agent_type='' + agent_id 만 값 → .sub (폴백 계약)
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p3.json" "$fixture" src.sh subid
  run_producer "$fixture" "$WORK/p3.json"
  assert_actor "케이스 3: agent_type='' + agent_id → .sub" "$fixture" gen-1 src.sh sub
  cleanup_fixture
}

# ===========================================================================
# 케이스 4~7 — 대상 분기
# ===========================================================================
echo "--- 케이스 4~7: 대상 분기 ---"
{
  # 4. CURRENT_TASK.md 편집 → 레코드 0건 + 세대 +1
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p4.json" "$fixture" CURRENT_TASK.md orc
  run_producer "$fixture" "$WORK/p4.json"
  assert_prod_ok "케이스 4: CURRENT_TASK.md 편집 → exit 0 무출력"
  assert_exists "케이스 4: 세대 +1 (gen-2 생성)" "$(ep_root_of "$fixture")/gen-2"
  assert_file_is "케이스 4: 새 세대 .short-title 기록" \
    "$(ep_root_of "$fixture")/gen-2/.short-title" "$EP_TITLE"
  assert_file_is "케이스 4: 포인터가 새 세대로 교체" "$(ep_root_of "$fixture")/.current" "gen-2"
  assert_no_records "케이스 4: 레코드 0건 (gen-2)" "$fixture" gen-2
  assert_no_records "케이스 4: 레코드 0건 (gen-1)" "$fixture" gen-1
  cleanup_fixture

  # 5. rd-workflow-workspace/ 하위 → 레코드 0건
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p5.json" "$fixture" rd-workflow-workspace/plans/p.md sub
  run_producer "$fixture" "$WORK/p5.json"
  assert_prod_ok "케이스 5: 워크스페이스 하위 → exit 0 무출력"
  assert_no_records "케이스 5: rd-workflow-workspace/ 하위 → 레코드 0건" "$fixture" gen-1
  cleanup_fixture

  # 추가-A(범위 밖 경로) — 브리프 번호 밖의 보강 케이스. 프로젝트 밖 절대 경로는 기록하지 않습니다.
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  printf 'outside\n' > "$WORK/outside.txt"
  resp_write "$WORK/resp.json" "$WORK/outside.txt" "$WORK/empty.txt"
  payload "$WORK/pA.json" "$WORK/outside.txt" Write sub "$WORK/resp.json"
  run_producer "$fixture" "$WORK/pA.json"
  assert_prod_ok "추가-A: 프로젝트 밖 경로 → exit 0 무출력"
  assert_no_records "추가-A: 프로젝트 밖 경로 → 레코드 0건" "$fixture" gen-1
  cleanup_fixture

  # 6. file_path 없음 → 레코드 0건, exit 0
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  resp_null "$WORK/resp.json"
  payload "$WORK/p6.json" "-" Write sub "$WORK/resp.json"
  run_producer "$fixture" "$WORK/p6.json"
  assert_prod_ok "케이스 6: file_path 없음 → exit 0 무출력"
  assert_no_records "케이스 6: file_path 없음 → 레코드 0건" "$fixture" gen-1
  cleanup_fixture

  # 7. 세대 디렉토리 부재 상태에서 일반 편집 → 세대 생성·기록 없음 (부트스트랩 금지)
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  pl_write "$WORK/p7.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p7.json"
  assert_prod_ok "케이스 7: 세대 부재 + 일반 편집 → exit 0 무출력"
  assert_eq "케이스 7: 세대가 생기지 않음 (부트스트랩 금지)" "$(count_gens "$fixture")" "0"
  assert_absent "케이스 7: 포인터도 생기지 않음" "$(ep_root_of "$fixture")/.current"
  cleanup_fixture
}

# ===========================================================================
# 케이스 8~12 — T23 교차 검증 (§2.6)
# ===========================================================================
echo "--- 케이스 8~12: T23 교차 검증 ---"
{
  # 8. T23-Write 불일치 → .orc 강등
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  printf 'payload 쪽 내용이 다릅니다\n' > "$WORK/other_content.txt"
  resp_write "$WORK/resp.json" "$WORK/other_content.txt" "$WORK/empty.txt"
  payload "$WORK/p8.json" "$fixture/src.sh" Write sub "$WORK/resp.json"
  run_producer "$fixture" "$WORK/p8.json"
  assert_actor "케이스 8: T23-Write 불일치 → .orc 강등" "$fixture" gen-1 src.sh orc
  cleanup_fixture

  # 9. T23-Write 일치 → .sub
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p9.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p9.json"
  assert_actor "케이스 9: T23-Write 일치 → .sub" "$fixture" gen-1 src.sh sub
  cleanup_fixture

  # 10. T23-Edit(replaceAll=false) 크기 불일치 → .orc
  #     파일은 'PRE<변형>SUF' 인데 payload 기대 크기에서 1바이트 어긋나게 만듭니다.
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  printf 'hello\n'            > "$WORK/v.txt"
  printf 'PREhello\nSUFX'     > "$fixture/src.sh"     # 기대보다 1바이트 큼
  printf 'PREPLACEHOLDERSUF'  > "$WORK/orig.txt"
  resp_edit "$WORK/resp.json" "$WORK/orig.txt" "PLACEHOLDER" "$WORK/v.txt" false
  payload "$WORK/p10.json" "$fixture/src.sh" Edit sub "$WORK/resp.json"
  run_producer "$fixture" "$WORK/p10.json"
  assert_actor "케이스 10: T23-Edit 크기 불일치 → .orc" "$fixture" gen-1 src.sh orc
  cleanup_fixture

  # 11. T23-Edit(replaceAll=false) 크기 일치 → .sub
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  printf 'hello\n'           > "$WORK/v.txt"
  printf 'PREhello\nSUF'     > "$fixture/src.sh"
  printf 'PREPLACEHOLDERSUF' > "$WORK/orig.txt"
  resp_edit "$WORK/resp.json" "$WORK/orig.txt" "PLACEHOLDER" "$WORK/v.txt" false
  payload "$WORK/p11.json" "$fixture/src.sh" Edit sub "$WORK/resp.json"
  run_producer "$fixture" "$WORK/p11.json"
  assert_actor "케이스 11: T23-Edit 크기 일치 → .sub" "$fixture" gen-1 src.sh sub
  cleanup_fixture

  # 12. T23-Edit(replaceAll=true) → 검증 생략, .sub (크기를 어긋나게 두어도 강등되지 않음)
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  printf 'hello\n'           > "$WORK/v.txt"
  printf 'PREhello\nSUFXXX'  > "$fixture/src.sh"     # 기대와 어긋남
  printf 'PREPLACEHOLDERSUF' > "$WORK/orig.txt"
  resp_edit "$WORK/resp.json" "$WORK/orig.txt" "PLACEHOLDER" "$WORK/v.txt" true
  payload "$WORK/p12.json" "$fixture/src.sh" Edit sub "$WORK/resp.json"
  run_producer "$fixture" "$WORK/p12.json"
  assert_actor "케이스 12: T23-Edit replaceAll=true → 검증 생략 .sub" "$fixture" gen-1 src.sh sub
  cleanup_fixture
}

# ===========================================================================
# 케이스 13 — T23 바이트 경계 (Finding 4). 정상 편집이 오강등되지 않아야 합니다.
# ===========================================================================
echo "--- 케이스 13: T23 바이트 경계 (Write·Edit × 5종) ---"
mk_variant() {
  case "$2" in
    a) printf 'hello\n' > "$1" ;;                       # 개행으로 끝남
    b) printf 'hello'   > "$1" ;;                       # 개행으로 끝나지 않음
    c) printf 'a\tb\n\n\nc\n' > "$1" ;;                  # 탭·연속 개행
    d) printf '한글 이모지 🎉\n' > "$1" ;;               # UTF-8 다중바이트
    e) : > "$1" ;;                                      # 빈 내용
  esac
}
{
  for _v in a b c d e; do
    # Write — 파일 내용 = payload content (바이트 동일)
    fixture="$(mk_prod)"; _current_fixture="$fixture"
    seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
    mk_variant "$WORK/v.txt" "$_v"
    cp "$WORK/v.txt" "$fixture/src.sh"
    resp_write "$WORK/resp.json" "$WORK/v.txt" "$WORK/empty.txt"
    payload "$WORK/p13w.json" "$fixture/src.sh" Write sub "$WORK/resp.json"
    run_producer "$fixture" "$WORK/p13w.json"
    assert_actor "케이스 13($_v)-Write: 정상 편집 → .sub 유지 (오강등 없음)" "$fixture" gen-1 src.sh sub
    cleanup_fixture

    # Edit — 파일 = 'PRE' + 변형 + 'SUF', originalFile = 'PREPLACEHOLDERSUF'
    fixture="$(mk_prod)"; _current_fixture="$fixture"
    seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
    mk_variant "$WORK/v.txt" "$_v"
    { printf 'PRE'; cat "$WORK/v.txt"; printf 'SUF'; } > "$fixture/src.sh"
    printf 'PREPLACEHOLDERSUF' > "$WORK/orig.txt"
    resp_edit "$WORK/resp.json" "$WORK/orig.txt" "PLACEHOLDER" "$WORK/v.txt" false
    payload "$WORK/p13e.json" "$fixture/src.sh" Edit sub "$WORK/resp.json"
    run_producer "$fixture" "$WORK/p13e.json"
    assert_actor "케이스 13($_v)-Edit: 정상 편집 → .sub 유지 (오강등 없음)" "$fixture" gen-1 src.sh sub
    cleanup_fixture
  done
}

# ===========================================================================
# 케이스 14 — jq 부재. 검증을 생략하되 **강등하지 않습니다**.
# ===========================================================================
echo "--- 케이스 14: jq 부재 ---"
# make_nojq_bin — jq 를 제외한 필요 도구만 심링크한 PATH 디렉토리를 만듭니다.
# (권한 조작 없이 'jq 부재' 를 결정적으로 재현하는 수단입니다. /bin/ls 는 헬퍼가 절대 경로로
#  부르므로 PATH 와 무관합니다.)
# (같은 local 문 안에서 앞 변수를 참조하면 set -u 하에서 unbound 로 죽습니다 — 선언을 나눕니다)
make_nojq_bin() {
  local fx="$1"
  local d="$fx/nojq-bin"
  local t p
  mkdir -p "$d"
  for t in cat awk cksum mktemp mv rm ls wc stat dirname tr grep sed bash; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [[ -n "$p" && -x "$p" ]] && ln -sf "$p" "$d/$t"
  done
  printf '%s' "$d"
}
# assert_nojq — PATH 조작이 실제로 'jq 부재' 를 만들었는지 확인합니다.
# 이 확인이 없으면 (a)는 jq 가 살아 있어도 통과해(정상 편집이므로 .sub) 케이스가 무력해집니다.
assert_nojq() {
  local label="$1" d="$2"
  if [[ -z "$d" || ! -d "$d" ]]; then no "$label" "PATH shim 디렉토리 구성 실패"; return; fi
  if ( PATH="$d"; command -v jq >/dev/null 2>&1 ); then no "$label" "jq 가 여전히 보임"; return; fi
  if ! ( PATH="$d"; command -v cksum >/dev/null 2>&1 && command -v awk >/dev/null 2>&1 ); then
    no "$label" "필수 도구(cksum·awk)가 shim 에 없음"; return
  fi
  ok "$label"
}
{
  # (a) 정상 편집 → .sub 유지
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  nojq="$(make_nojq_bin "$fixture")"
  assert_nojq "케이스 14: PATH shim 이 jq 만 감춤 (필수 도구는 유지)" "$nojq"
  pl_write "$WORK/p14a.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p14a.json" "$nojq"
  assert_prod_ok "케이스 14(a): jq 부재 + 정상 편집 → exit 0 무출력"
  assert_actor "케이스 14(a): jq 부재 + 정상 편집 → .sub 유지" "$fixture" gen-1 src.sh sub
  cleanup_fixture

  # (b) payload 와 파일이 불일치해도 검증 생략 → .sub
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  nojq="$(make_nojq_bin "$fixture")"
  printf '전혀 다른 내용\n' > "$WORK/other_content.txt"
  resp_write "$WORK/resp.json" "$WORK/other_content.txt" "$WORK/empty.txt"
  payload "$WORK/p14b.json" "$fixture/src.sh" Write sub "$WORK/resp.json"
  run_producer "$fixture" "$WORK/p14b.json" "$nojq"
  assert_prod_ok "케이스 14(b): jq 부재 + 불일치 → exit 0 무출력"
  assert_actor "케이스 14(b): jq 부재 + 불일치 → .sub (검증 생략, 강등 없음)" "$fixture" gen-1 src.sh sub
  cleanup_fixture
}

# ===========================================================================
# 케이스 15 — AC5(g) fault injection. 네 경우 모두 exit 0 + 무출력.
#   hook 을 통째로 실행하므로 셸 함수 override 가 전파되지 않습니다 → 권한 비의존 수단을 씁니다.
# ===========================================================================
echo "--- 케이스 15: fault injection ---"
{
  # (a) provenance 루트 경로에 **일반 파일** → 하위 생성이 ENOTDIR 로 실패
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  : > "$fixture/ep-not-a-dir"
  _EP_ROOT="$fixture/ep-not-a-dir"
  pl_write "$WORK/p15a.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p15a.json"
  assert_prod_ok "케이스 15(a): 루트가 일반 파일(ENOTDIR) → exit 0 무출력"
  pl_write "$WORK/p15a2.json" "$fixture" CURRENT_TASK.md orc
  run_producer "$fixture" "$WORK/p15a2.json"
  assert_prod_ok "케이스 15(a): 루트가 일반 파일 + bump 경로 → exit 0 무출력"
  cleanup_fixture

  # (b) _edit_provenance_common.sh 를 구문 오류 파일로 교체
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p15b.json" "$fixture" src.sh sub
  printf '%s\n' 'broken_fn() {' > "$fixture/rd-workflow/scripts/_edit_provenance_common.sh"
  run_producer "$fixture" "$WORK/p15b.json"
  assert_prod_ok "케이스 15(b): 헬퍼 구문 오류 → exit 0 무출력"
  assert_no_records "케이스 15(b): 헬퍼 구문 오류 → 레코드 0건" "$fixture" gen-1
  cleanup_fixture

  # (c) _guard_common.sh 삭제
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p15c.json" "$fixture" src.sh sub
  rm -f "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  run_producer "$fixture" "$WORK/p15c.json"
  assert_prod_ok "케이스 15(c): _guard_common.sh 부재 → exit 0 무출력"
  assert_no_records "케이스 15(c): _guard_common.sh 부재 → 레코드 0건" "$fixture" gen-1
  cleanup_fixture

  # (d) payload 가 빈 문자열 / 비-JSON
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  : > "$WORK/p15d1.json"
  printf 'this is not json at all\n' > "$WORK/p15d2.json"
  run_producer "$fixture" "$WORK/p15d1.json"
  assert_prod_ok "케이스 15(d): payload 빈 문자열 → exit 0 무출력"
  run_producer "$fixture" "$WORK/p15d2.json"
  assert_prod_ok "케이스 15(d): payload 비-JSON → exit 0 무출력"
  assert_no_records "케이스 15(d): 비정상 payload → 레코드 0건" "$fixture" gen-1
  cleanup_fixture
}

# ===========================================================================
# 케이스 16 — 동시 writer stress. 서로 다른 4개 경로 × 20회.
#   매 회 전에 4개 레코드를 지우고 동시 실행 → 4건 전부 재생성 + 각 파일 2필드.
# ===========================================================================
echo "--- 케이스 16: 동시 writer stress (4경로 × 20회) ---"
{
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  _paths="src.sh other.sh third.sh fourth.sh"
  for _p in $_paths; do pl_write "$WORK/p16_$_p.json" "$fixture" "$_p" sub; done
  _bad=0; _rep=1
  while [[ $_rep -le 20 ]]; do
    for _p in $_paths; do
      rm -f "$(ep_root_of "$fixture")/gen-1/$(pathkey_of "$_p").sub"
    done
    for _p in $_paths; do run_producer_bg "$fixture" "$WORK/p16_$_p.json"; done
    wait
    for _p in $_paths; do
      if ! record_is_parsable "$(ep_root_of "$fixture")/gen-1/$(pathkey_of "$_p").sub" "$_p"; then
        _bad=$((_bad + 1))
        echo "  (rep $_rep, $_p 레코드 결손·malformed)" >&2
      fi
    done
    _rep=$((_rep + 1))
  done
  if [[ $_bad -eq 0 ]]; then
    ok "케이스 16: 동시 writer 20회 × 4경로 → 매 회 4건 전부 2필드"
  else
    no "케이스 16: 동시 writer stress" "결손·malformed ${_bad}건"
  fi
  cleanup_fixture
}

# ===========================================================================
# 케이스 17 — bump ↔ record 경합. CURRENT_TASK.md 편집(bump)과 일반 편집을 동시 20회.
#   레코드가 어느 세대에 있든 판정 가능한 상태(2필드·relpath 일치)여야 합니다.
# ===========================================================================
echo "--- 케이스 17: bump ↔ record 경합 (20회) ---"
{
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/p17ct.json" "$fixture" CURRENT_TASK.md orc
  pl_write "$WORK/p17src.json" "$fixture" src.sh sub
  _pk="$(pathkey_of src.sh)"
  _bad=0; _rep=1
  while [[ $_rep -le 20 ]]; do
    run_producer_bg "$fixture" "$WORK/p17ct.json"
    run_producer_bg "$fixture" "$WORK/p17src.json"
    wait
    _found=0
    for _f in "$(ep_root_of "$fixture")"/gen-*/"$_pk".sub; do
      [[ -f "$_f" ]] || continue
      _found=$((_found + 1))
      record_is_parsable "$_f" src.sh || { _bad=$((_bad + 1)); echo "  (rep $_rep malformed: $_f)" >&2; }
      rm -f "$_f"
    done
    if [[ $_found -lt 1 ]]; then
      _bad=$((_bad + 1)); echo "  (rep $_rep 레코드 결손)" >&2
    fi
    _rep=$((_rep + 1))
  done
  if [[ $_bad -eq 0 ]]; then
    ok "케이스 17: bump ↔ record 동시 20회 → 레코드가 항상 판정 가능한 상태"
  else
    no "케이스 17: bump ↔ record 경합" "이상 ${_bad}건"
  fi
  # bump 가 세대를 삭제하지 않으므로 세대 수는 단조 증가합니다 (20회 + 최초 1개).
  assert_eq "케이스 17: 세대가 삭제되지 않음 (21개)" "$(count_gens "$fixture")" "21"
  cleanup_fixture
}

# ===========================================================================
# 케이스 18 — cap ↔ record 경합. 레코드 999개 상태에서 4경로 동시 실행 20회.
#   기존 레코드 삭제 0건 + .overflow 이후 기록 중단.
# ===========================================================================
echo "--- 케이스 18: cap ↔ record 경합 (20회) ---"
{
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_dummy_records "$fixture" gen-1 999
  _paths="src.sh other.sh third.sh fourth.sh"
  for _p in $_paths; do pl_write "$WORK/p18_$_p.json" "$fixture" "$_p" sub; done
  _bad=0; _frozen=""; _rep=1
  while [[ $_rep -le 20 ]]; do
    for _p in $_paths; do run_producer_bg "$fixture" "$WORK/p18_$_p.json"; done
    wait
    _n="$(count_records "$fixture" gen-1)"
    if [[ "$_n" -lt 999 ]]; then
      _bad=$((_bad + 1)); echo "  (rep $_rep 레코드 감소: $_n)" >&2
    fi
    if [[ -n "$_frozen" && "$_n" != "$_frozen" ]]; then
      _bad=$((_bad + 1)); echo "  (rep $_rep .overflow 이후 레코드 증가: $_frozen → $_n)" >&2
    fi
    if [[ -z "$_frozen" && -e "$(ep_root_of "$fixture")/gen-1/.overflow" ]]; then
      _frozen="$_n"
    fi
    _rep=$((_rep + 1))
  done
  if [[ $_bad -eq 0 ]]; then
    ok "케이스 18: cap ↔ record 동시 20회 → 삭제 0건 + .overflow 이후 기록 중단"
  else
    no "케이스 18: cap ↔ record 경합" "이상 ${_bad}건"
  fi
  assert_exists "케이스 18: 상한 초과 → .overflow 생성" "$(ep_root_of "$fixture")/gen-1/.overflow"
  cleanup_fixture
}

# ===========================================================================
# 케이스 19 — 상한 = 중단·표시 (Finding 3). 삭제하지 않습니다.
# ===========================================================================
echo "--- 케이스 19: 상한 중단·표시 ---"
{
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_dummy_records "$fixture" gen-1 1000
  pl_write "$WORK/p19a.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p19a.json"
  assert_exists "케이스 19: 1000개 + 새 경로 → .overflow 생성" \
    "$(ep_root_of "$fixture")/gen-1/.overflow"
  assert_eq "케이스 19: 기존 1000개 + 신규 1건 전부 보존 (삭제 0건)" \
    "$(count_records "$fixture" gen-1)" "1001"
  assert_exists "케이스 19: 첫 더미 레코드 보존" "$(ep_root_of "$fixture")/gen-1/dummy1.orc"
  assert_exists "케이스 19: 마지막 더미 레코드 보존" "$(ep_root_of "$fixture")/gen-1/dummy1000.orc"
  # 이후 편집은 센티널 때문에 기록이 늘지 않습니다.
  pl_write "$WORK/p19b.json" "$fixture" other.sh sub
  run_producer "$fixture" "$WORK/p19b.json"
  assert_prod_ok "케이스 19: 센티널 이후 편집 → exit 0 무출력"
  assert_eq "케이스 19: 센티널 이후 레코드가 늘지 않음" \
    "$(count_records "$fixture" gen-1)" "1001"
  cleanup_fixture

  # 추가-B (brief 본체 11항) — ep_cap 은 **새 레코드 파일을 만들 때만** 호출합니다.
  #   같은 경로·같은 행위자의 재편집은 덮어쓰기라 디렉토리 항목이 늘지 않으므로 카운트가
  #   불필요합니다 (spec §2.8 성능).
  #   판별 조건: **레코드 1001건 + 이미 기록된 경로의 재편집**. 게이트가 있으면 ep_cap 이
  #   호출되지 않아 .overflow 가 생기지 않고, 게이트를 없애면 1001 > 1000 이라 생깁니다.
  #   (1000건에서는 양쪽 모두 미생성이라 판별되지 않습니다 — 리뷰 M-1)
  #   재편집이 실제로 **기록됐는지**도 함께 봅니다: 파일 내용을 바꿔 상태 식별자가 갱신되면
  #   조기 종료가 아니라 덮어쓰기가 일어났다는 뜻입니다.
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  pl_write "$WORK/pB1.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/pB1.json"
  assert_actor "추가-B: 1회차 편집 → .sub 기록" "$fixture" gen-1 src.sh sub
  seed_dummy_records "$fixture" gen-1 1000
  assert_eq "추가-B: 재편집 직전 레코드 1001건" "$(count_records "$fixture" gen-1)" "1001"
  printf '%s\n' "#!/bin/bash" "echo changed" > "$fixture/src.sh"
  pl_write "$WORK/pB2.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/pB2.json"
  assert_prod_ok "추가-B: 기존 경로 재편집 → exit 0 무출력"
  assert_actor "추가-B: 재편집이 같은 파일에 덮어써짐 (상태 식별자 갱신)" "$fixture" gen-1 src.sh sub
  assert_absent "추가-B: 새 레코드가 아니므로 ep_cap 미호출 → .overflow 없음" \
    "$(ep_root_of "$fixture")/gen-1/.overflow"
  assert_eq "추가-B: 레코드 수 불변" "$(count_records "$fixture" gen-1)" "1001"
  cleanup_fixture
}

# ===========================================================================
# 케이스 20 — 번호 재사용 방지
# ===========================================================================
echo "--- 케이스 20: 번호 재사용 방지 ---"
{
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-3 "$EP_TITLE"
  if ep_invoke "$fixture" ep_bump "$EP_TITLE"; then
    ok "케이스 20: ep_bump 성공"
  else
    no "케이스 20: ep_bump 실패"
  fi
  assert_exists "케이스 20: gen-3 만 있는 상태 → gen-4 생성 (1 아님)" "$(ep_root_of "$fixture")/gen-4"
  assert_absent "케이스 20: gen-1 을 만들지 않음" "$(ep_root_of "$fixture")/gen-1"
  assert_file_is "케이스 20: 포인터 = gen-4" "$(ep_root_of "$fixture")/.current" "gen-4"
  cleanup_fixture
}

# ===========================================================================
# 케이스 21 — bump 실패 비파괴 (turn 016 F2)
# ===========================================================================
echo "--- 케이스 21: bump 실패 비파괴 ---"
{
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  _rec="$(ep_root_of "$fixture")/gen-1/$(pathkey_of src.sh).sub"
  _rec_before="$(cat "$_rec")"
  if ep_invoke_with "$fixture" 'mkdir() { return 1; }' ep_bump "$EP_TITLE"; then
    no "케이스 21: mkdir 실패인데 ep_bump 가 0 을 반환"
  else
    ok "케이스 21: mkdir 실패 → ep_bump non-zero"
  fi
  assert_file_is "케이스 21: 포인터 불변" "$(ep_root_of "$fixture")/.current" "gen-1"
  assert_absent "케이스 21: .invalid 센티널 없음 (폐기)" "$(ep_root_of "$fixture")/gen-1/.invalid"
  assert_absent "케이스 21: .overflow 센티널 없음" "$(ep_root_of "$fixture")/gen-1/.overflow"
  assert_file_is "케이스 21: 기존 세대 .short-title 불변" \
    "$(ep_root_of "$fixture")/gen-1/.short-title" "$EP_TITLE"
  assert_eq "케이스 21: 기존 레코드 불변" "$(cat "$_rec")" "$_rec_before"
  assert_eq "케이스 21: 새 세대가 생기지 않음" "$(count_gens "$fixture")" "1"
  cleanup_fixture

  # 동시 성공 오염 확인 — 포인터가 **다른 bump 의 새 세대**를 가리키는 상태에서 실패한 bump 를 실행
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  seed_record "$fixture" gen-2 sub src.sh
  _rec="$(ep_root_of "$fixture")/gen-2/$(pathkey_of src.sh).sub"
  _rec_before="$(cat "$_rec")"
  ep_invoke_with "$fixture" 'mkdir() { return 1; }' ep_bump "$EP_TITLE" && \
    no "케이스 21: 실패한 bump 가 0 을 반환" || ok "케이스 21: 동시 상황에서도 non-zero"
  assert_file_is "케이스 21: 동시 성공 세대의 포인터 불변" \
    "$(ep_root_of "$fixture")/.current" "gen-2"
  assert_file_is "케이스 21: 동시 성공 세대 .short-title 불변" \
    "$(ep_root_of "$fixture")/gen-2/.short-title" "$EP_TITLE"
  assert_eq "케이스 21: 동시 성공 세대 레코드 불변" "$(cat "$_rec")" "$_rec_before"
  assert_absent "케이스 21: 동시 성공 세대에 센티널 없음" "$(ep_root_of "$fixture")/gen-2/.overflow"
  cleanup_fixture

  # producer 경유 시 exit 0 — 권한 비의존 실패로 bump 를 실패시킵니다.
  #   'gen-1' 이라는 **일반 파일**을 두면 ep_next_gen_name 이 gen-1 을 고르고 mkdir 이 5회 모두
  #   EEXIST 로 실패합니다 (chmod 불필요).
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  mkdir -p "$(ep_root_of "$fixture")"
  : > "$(ep_root_of "$fixture")/gen-1"
  pl_write "$WORK/p21.json" "$fixture" CURRENT_TASK.md orc
  run_producer "$fixture" "$WORK/p21.json"
  assert_prod_ok "케이스 21: bump 실패를 producer 로 경유 → exit 0 무출력"
  assert_absent "케이스 21: producer 경유 실패 후에도 포인터 없음" "$(ep_root_of "$fixture")/.current"
  assert_file_is "케이스 21: producer 경유 실패 → .bump-failed=mkdir" \
    "$(ep_root_of "$fixture")/.bump-failed" "mkdir"
  cleanup_fixture
}

# ===========================================================================
# 케이스 22 — pathkey 충돌 모사
# ===========================================================================
echo "--- 케이스 22: pathkey 충돌 ---"
{
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_raw_record "$fixture" gen-1 sub src.sh "$(state_id_of "$fixture/src.sh")	other.sh
"
  if ep_invoke "$fixture" ep_read_record "$(ep_root_of "$fixture")/gen-1" sub src.sh >/dev/null 2>&1; then
    no "케이스 22: relpath 불일치인데 ep_read_record 가 0 을 반환"
  else
    ok "케이스 22: .sub relpath 조작 → ep_read_record return 1"
  fi
  cleanup_fixture
}

# ===========================================================================
# 케이스 23 — 센티널 수명 (turn 006 F1). 복구는 **저장으로만**.
# ===========================================================================
echo "--- 케이스 23: 센티널 수명 ---"
{
  # (a) .overflow 가 있는 gen-2 + 일반 subagent 편집
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  seed_overflow "$fixture" gen-2
  pl_write "$WORK/p23.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p23.json"
  assert_prod_ok "케이스 23(a): 센티널 세대 + 일반 편집 → exit 0 무출력"
  assert_absent "케이스 23(a): 새 세대가 생기지 않음 (gen-3 부재)" "$(ep_root_of "$fixture")/gen-3"
  assert_no_records "케이스 23(a): 레코드가 늘지 않음" "$fixture" gen-2
  assert_exists "케이스 23(a): .overflow 가 그대로 남음" "$(ep_root_of "$fixture")/gen-2/.overflow"

  # (c) (a) 직후 CURRENT_TASK.md 편집(기준선 저장) → gen-3 + .short-title, 이후 일반 편집이 정상 기록
  pl_write "$WORK/p23ct.json" "$fixture" CURRENT_TASK.md orc
  run_producer "$fixture" "$WORK/p23ct.json"
  assert_exists "케이스 23(c): 기준선 저장 → gen-3 생성" "$(ep_root_of "$fixture")/gen-3"
  assert_file_is "케이스 23(c): gen-3 .short-title 기록" \
    "$(ep_root_of "$fixture")/gen-3/.short-title" "$EP_TITLE"
  run_producer "$fixture" "$WORK/p23.json"
  assert_actor "케이스 23(c): 복구 후 일반 편집 → gen-3 에 정상 기록" "$fixture" gen-3 src.sh sub
  cleanup_fixture

  # (b) .overflow 를 '다른 경로' 편집이 만든 상태(레코드 1000 초과 모사)에서 같은 확인
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  seed_dummy_records "$fixture" gen-2 1001
  seed_record "$fixture" gen-2 sub other.sh
  seed_overflow "$fixture" gen-2
  _n_before="$(count_records "$fixture" gen-2)"
  pl_write "$WORK/p23b.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p23b.json"
  assert_prod_ok "케이스 23(b): 다른 경로가 만든 센티널 + 일반 편집 → exit 0 무출력"
  assert_absent "케이스 23(b): 새 세대가 생기지 않음" "$(ep_root_of "$fixture")/gen-3"
  assert_eq "케이스 23(b): 레코드가 늘지 않음" "$(count_records "$fixture" gen-2)" "$_n_before"
  assert_exists "케이스 23(b): .overflow 가 그대로 남음" "$(ep_root_of "$fixture")/gen-2/.overflow"
  cleanup_fixture

  # (d) .short-title 부재 (메타 손상)
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen_bare "$fixture" gen-1; seed_current "$fixture" gen-1
  pl_write "$WORK/p23d.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p23d.json"
  assert_prod_ok "케이스 23(d): .short-title 부재 → exit 0 무출력"
  assert_absent "케이스 23(d): 새 세대 없음" "$(ep_root_of "$fixture")/gen-2"
  assert_no_records "케이스 23(d): 기록 없음" "$fixture" gen-1
  cleanup_fixture

  # (e) .short-title 이 다른 task 값
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "other-task"; seed_current "$fixture" gen-1
  pl_write "$WORK/p23e.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p23e.json"
  assert_prod_ok "케이스 23(e): .short-title 불일치 → exit 0 무출력"
  assert_absent "케이스 23(e): 새 세대 없음" "$(ep_root_of "$fixture")/gen-2"
  assert_no_records "케이스 23(e): 기록 없음" "$fixture" gen-1
  cleanup_fixture

  # (f) 세대 부재 (케이스 7 과 같은 계약 — 부트스트랩 금지)
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  pl_write "$WORK/p23f.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p23f.json"
  assert_prod_ok "케이스 23(f): 세대 부재 → exit 0 무출력"
  assert_eq "케이스 23(f): 세대가 생기지 않고 기록도 없음" "$(count_gens "$fixture")" "0"
  cleanup_fixture
}

# ===========================================================================
# 케이스 24 — 세대 소실 (turn 008 F1). consumer 판정까지 확인합니다.
# ===========================================================================
echo "--- 케이스 24: 세대 소실 ---"
{
  # (a) 최신 센티널 세대만 외부 삭제 → 세대 0개 + dangling 포인터
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  seed_overflow "$fixture" gen-2
  rm -rf "$(ep_root_of "$fixture")/gen-2"
  pl_write "$WORK/p24.json" "$fixture" src.sh sub
  run_producer "$fixture" "$WORK/p24.json"
  assert_prod_ok "케이스 24(a): 세대 소실 + 일반 편집 → exit 0 무출력"
  assert_eq "케이스 24(a): 세대 생성 없음" "$(count_gens "$fixture")" "0"
  assert_verdict "케이스 24(a): 세대 소실 → consumer block" "$fixture" block

  # (c) 다음 기준선 저장으로 복구 — 전 세대 소실 후이므로 번호가 gen-1 로 돌아가는 것이 정상
  pl_write "$WORK/p24ct.json" "$fixture" CURRENT_TASK.md orc
  run_producer "$fixture" "$WORK/p24ct.json"
  assert_exists "케이스 24(c): 기준선 저장 → gen-1 생성" "$(ep_root_of "$fixture")/gen-1"
  assert_file_is "케이스 24(c): gen-1 .short-title 기록" \
    "$(ep_root_of "$fixture")/gen-1/.short-title" "$EP_TITLE"
  assert_file_is "케이스 24(c): 포인터 = gen-1 로 교체" "$(ep_root_of "$fixture")/.current" "gen-1"
  run_producer "$fixture" "$WORK/p24.json"
  assert_actor "케이스 24(c): 복구 후 일반 편집 정상 기록" "$fixture" gen-1 src.sh sub
  assert_verdict "케이스 24(c): 복구 후 consumer 통과" "$fixture" pass
  cleanup_fixture

  # (b) rollback 불가 — bump 성공 직후 낮은 세대는 삭제되지 않고, 포인터 대상 삭제는 block
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  assert_verdict "케이스 24(b): 기준 상태 → consumer 통과" "$fixture" pass
  ep_invoke "$fixture" ep_bump "$EP_TITLE" >/dev/null 2>&1
  assert_exists "케이스 24(b): bump 는 낮은 세대를 삭제하지 않음" "$(ep_root_of "$fixture")/gen-1"
  assert_exists "케이스 24(b): 새 세대 gen-2 생성" "$(ep_root_of "$fixture")/gen-2"
  rm -rf "$(ep_root_of "$fixture")/gen-2"
  assert_verdict "케이스 24(b): 포인터 대상 삭제(dangling) → block (낮은 세대 되살아나지 않음)" \
    "$fixture" block
  assert_exists "케이스 24(b): 판정 후에도 gen-1 보존" "$(ep_root_of "$fixture")/gen-1"
  cleanup_fixture
}

# ===========================================================================
# 케이스 25 — 정리 실패·세대 소실 내성 (turn 010 F2 · 012 F1·F3).
#   결과 상태를 fixture 로 직접 구성해 결정적으로 검증합니다.
# ===========================================================================
echo "--- 케이스 25: 정리 실패 잔존 상태 내성 ---"
{
  # (a) 정리 실패 잔존 상태 — gen-1(유효 .sub) + gen-2(유효), 포인터 = gen-2
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_record "$fixture" gen-1 sub src.sh
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  assert_verdict "케이스 25(a): gen-1 레코드가 판정에 섞이지 않음 → block" "$fixture" block

  # (c) 판정이 세대를 삭제하지 않음 — 5회 반복
  _bad=0; _rep=1
  while [[ $_rep -le 5 ]]; do
    run_consumer "$fixture"
    [[ "$_cons_verdict" == "block" ]] || _bad=$((_bad + 1))
    [[ -d "$(ep_root_of "$fixture")/gen-1" ]] || _bad=$((_bad + 1))
    [[ -d "$(ep_root_of "$fixture")/gen-2" ]] || _bad=$((_bad + 1))
    _rep=$((_rep + 1))
  done
  if [[ $_bad -eq 0 ]]; then
    ok "케이스 25(c): 판정 5회 반복 → 두 세대 보존 + 결과 동일"
  else
    no "케이스 25(c): 판정 반복" "이상 ${_bad}건"
  fi

  # (b) (a) 상태에서 최신 세대만 외부 삭제 → dangling → block, gen-1 되살아나지 않음
  rm -rf "$(ep_root_of "$fixture")/gen-2"
  assert_verdict "케이스 25(b): 최신 세대 삭제(dangling) → block" "$fixture" block
  assert_exists "케이스 25(b): gen-1 보존(되살아나지 않음)" "$(ep_root_of "$fixture")/gen-1"
  cleanup_fixture

  # (d) 동일 내용·동일 초 연속 저장 (turn 012 F1 반례) — 값이 아니라 포인터로 고릅니다.
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  ep_invoke "$fixture" ep_bump "$EP_TITLE" >/dev/null 2>&1   # gen-1
  ep_invoke "$fixture" ep_bump "$EP_TITLE" >/dev/null 2>&1   # gen-2 (같은 초·같은 내용)
  assert_file_is "케이스 25(d): 두 번째 저장이 포인터를 gen-2 로 교체" \
    "$(ep_root_of "$fixture")/.current" "gen-2"
  assert_eq "케이스 25(d): 두 세대의 .short-title 이 동일(동일 내용 저장)" \
    "$(cat "$(ep_root_of "$fixture")/gen-1/.short-title")" \
    "$(cat "$(ep_root_of "$fixture")/gen-2/.short-title")"
  seed_record "$fixture" gen-1 sub src.sh
  rm -rf "$(ep_root_of "$fixture")/gen-2"
  assert_verdict "케이스 25(d): 동일 내용·동일 초 + 최신 세대 삭제 → block (반례 재현 안 됨)" \
    "$fixture" block
  cleanup_fixture
}

# ===========================================================================
# 케이스 26 — 런타임 무삭제: 폐기한 두 기준(번호·나이)이 깨졌던 순서를 그대로 실행합니다.
#   A: gen-5 생성 + .short-title (fixture)
#   B: gen-6 생성 + .current=gen-6 (ep_bump)
#   C: 판정 경로 1회 실행 (hook)
#   A: ep_set_current gen-5 (포인터 교체 모사)
# ===========================================================================
echo "--- 케이스 26: 런타임 무삭제 두 반례 순서 ---"
{
  # (a) 포인터 후진
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-5 "$EP_TITLE"
  seed_record "$fixture" gen-5 sub src.sh
  seed_current "$fixture" gen-5
  ep_invoke "$fixture" ep_bump "$EP_TITLE" >/dev/null 2>&1
  assert_file_is "케이스 26(a): B → 포인터 = gen-6" "$(ep_root_of "$fixture")/.current" "gen-6"
  assert_verdict "케이스 26(a): C 판정 1회 (gen-6 에 레코드 없음) → block" "$fixture" block
  assert_exists "케이스 26(a): 판정 후에도 gen-5 보존 (번호 기준이면 삭제됐음)" \
    "$(ep_root_of "$fixture")/gen-5"
  ep_invoke "$fixture" ep_set_current "$(ep_root_of "$fixture")/gen-5" >/dev/null 2>&1
  assert_verdict "케이스 26(a): 포인터 후진(gen-5) → 통과 (포인터 유효)" "$fixture" pass
  cleanup_fixture

  # (b) writer 장시간 정지 — C 실행 전에 gen-5 의 mtime 을 아주 과거로 (touch -t, sleep 없음)
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-5 "$EP_TITLE"
  seed_record "$fixture" gen-5 sub src.sh
  seed_current "$fixture" gen-5
  ep_invoke "$fixture" ep_bump "$EP_TITLE" >/dev/null 2>&1
  touch -t "$OLD_TS" "$(ep_root_of "$fixture")/gen-5"
  assert_verdict "케이스 26(b): C 판정 1회 → block" "$fixture" block
  assert_exists "케이스 26(b): 오래된 gen-5 보존 (나이 기준이면 삭제됐음)" \
    "$(ep_root_of "$fixture")/gen-5"
  ep_invoke "$fixture" ep_set_current "$(ep_root_of "$fixture")/gen-5" >/dev/null 2>&1
  assert_verdict "케이스 26(b): 포인터 후진(오래된 gen-5) → 통과 (나이 무관)" "$fixture" pass
  cleanup_fixture

  # (c) 누적 무영향 — 세대 1개일 때의 결과와 50개일 때의 결과가 같아야 합니다.
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  run_consumer "$fixture"
  _one_verdict="$_cons_verdict"; _one_out="$_cons_out"
  cleanup_fixture

  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  _i=1
  while [[ $_i -le 50 ]]; do seed_gen "$fixture" "gen-$_i" "$EP_TITLE"; _i=$((_i + 1)); done
  seed_current "$fixture" gen-50
  seed_record "$fixture" gen-50 sub src.sh
  run_consumer "$fixture"
  assert_eq "케이스 26(c): 세대 50개 판정 결과 = 1개일 때와 동일" "$_cons_verdict" "$_one_verdict"
  assert_eq "케이스 26(c): 출력도 동일" "$_cons_out" "$_one_out"
  assert_eq "케이스 26(c): 어느 세대도 삭제되지 않음" "$(count_gens "$fixture")" "50"
  cleanup_fixture
}

# ===========================================================================
# 케이스 27 — bump 중간 실패 4지점 (turn 014 F3 · 018 F2·F3).
#   네 경우 모두 권위 상태(포인터 · 기존 세대의 내용·유효성) 불변 + non-zero + .bump-failed <stage>.
# ===========================================================================
echo "--- 케이스 27: bump 중간 실패 ---"
{
  # (a) mkdir 실패 — 5회 재시도 후 새 세대 없음
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  : > "$WORK/mkdir_count"
  ep_invoke_with "$fixture" "mkdir() { printf 'x' >> '$WORK/mkdir_count'; return 1; }" \
    ep_bump "$EP_TITLE" && no "케이스 27(a): mkdir 실패인데 0 반환" \
                        || ok "케이스 27(a): mkdir 실패 → non-zero"
  assert_eq "케이스 27(a): mkdir 5회 재시도" "$(wc -c < "$WORK/mkdir_count" | tr -d '[:space:]')" "5"
  assert_eq "케이스 27(a): 새 세대 없음" "$(count_gens "$fixture")" "1"
  assert_file_is "케이스 27(a): 포인터 불변" "$(ep_root_of "$fixture")/.current" "gen-1"
  assert_absent "케이스 27(a): 센티널 없음" "$(ep_root_of "$fixture")/gen-1/.overflow"
  assert_file_is "케이스 27(a): .bump-failed=mkdir" "$(ep_root_of "$fixture")/.bump-failed" "mkdir"

  # (f) 판정 비참여 — .bump-failed 유무가 판정 결과를 바꾸지 않습니다
  #     (block reason 의 사유 문구는 §2.12 대로 달라지지만 판정 결과는 같아야 합니다)
  run_consumer "$fixture"; _v_with="$_cons_verdict"
  rm -f "$(ep_root_of "$fixture")/.bump-failed"
  run_consumer "$fixture"; _v_without="$_cons_verdict"
  assert_eq "케이스 27(f): .bump-failed 유무와 무관하게 판정 동일" "$_v_with" "$_v_without"

  # (g) 복구 — 이후 bump 성공 시 .bump-failed 삭제. rm 실패여도 bump 는 성공 처리.
  ep_invoke_with "$fixture" "ep_mark_bump_failed() { printf 'mkdir\n' > \"\$(ep_root)/.bump-failed\"; }" \
    ep_mark_bump_failed mkdir >/dev/null 2>&1
  if ep_invoke "$fixture" ep_bump "$EP_TITLE"; then
    ok "케이스 27(g): 이후 bump 성공"
  else
    no "케이스 27(g): 이후 bump 실패"
  fi
  assert_absent "케이스 27(g): bump 성공 → .bump-failed 삭제" "$(ep_root_of "$fixture")/.bump-failed"
  printf 'mkdir\n' > "$(ep_root_of "$fixture")/.bump-failed"
  if ep_invoke_with "$fixture" 'rm() { return 1; }' ep_bump "$EP_TITLE"; then
    ok "케이스 27(g): rm 실패여도 bump 는 성공 처리"
  else
    no "케이스 27(g): rm 실패가 bump 를 실패시킴"
  fi
  assert_exists "케이스 27(g): 삭제 실패 시 흔적은 남음" "$(ep_root_of "$fixture")/.bump-failed"
  # "흔적이 남아도 판정은 정상" 을 **뒤집힐 수 있는 형태**로 확인합니다.
  #   run_consumer 는 block|pass 둘 중 하나만 내므로 "block 이거나 pass" 는 항상 참이라
  #   아무것도 증명하지 못합니다(리뷰 I-1). 그래서 ① 통과해야 하는 상태를 만들어 기대값을
  #   리터럴로 고정하고 ② 흔적 유/무 두 판정을 비교합니다.
  #   consumer 가 .bump-failed 를 읽어 pass → block 으로 뒤집는 회귀(계약 ② · §2.12 위반)는
  #   ①에서 바로 잡힙니다.
  _cur_gen="$(cat "$(ep_root_of "$fixture")/.current")"
  seed_record "$fixture" "$_cur_gen" sub src.sh
  run_consumer "$fixture"; _v_with="$_cons_verdict"
  assert_eq "케이스 27(g): 흔적이 남아도 통과 상태는 통과" "$_v_with" "pass"
  rm -f "$(ep_root_of "$fixture")/.bump-failed"
  run_consumer "$fixture"; _v_without="$_cons_verdict"
  assert_eq "케이스 27(g): 흔적 유/무와 무관하게 판정 동일" "$_v_with" "$_v_without"
  cleanup_fixture

  # (b) .short-title 쓰기만 실패 — mv 를 **첫 호출에서만** 실패시킵니다
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_invoke_with "$fixture" \
    '_n=0; mv() { _n=$((_n+1)); if [[ $_n -eq 1 ]]; then return 1; fi; command mv "$@"; }' \
    ep_bump "$EP_TITLE" && no "케이스 27(b): .short-title 실패인데 0 반환" \
                        || ok "케이스 27(b): .short-title 쓰기 실패 → non-zero"
  assert_file_is "케이스 27(b): 포인터 불변" "$(ep_root_of "$fixture")/.current" "gen-1"
  assert_exists "케이스 27(b): 새 세대는 고아로 남음 (파일시스템 무변경이 아님)" \
    "$(ep_root_of "$fixture")/gen-2"
  assert_absent "케이스 27(b): 고아 세대에 .short-title 없음" \
    "$(ep_root_of "$fixture")/gen-2/.short-title"
  assert_file_is "케이스 27(b): .bump-failed=short-title" \
    "$(ep_root_of "$fixture")/.bump-failed" "short-title"
  assert_verdict "케이스 27(b): consumer 가 이전 세대를 계속 사용 → 통과" "$fixture" pass
  cleanup_fixture

  # (c) 포인터 교체 실패 — mv 의 **두 번째** 호출(포인터 교체)만 실패
  fixture="$(mk_full)"; _current_fixture="$fixture"
  touch_newer "$fixture" src.sh
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  seed_record "$fixture" gen-1 sub src.sh
  ep_invoke_with "$fixture" \
    '_n=0; mv() { _n=$((_n+1)); if [[ $_n -eq 2 ]]; then return 1; fi; command mv "$@"; }' \
    ep_bump "$EP_TITLE" && no "케이스 27(c): 포인터 교체 실패인데 0 반환" \
                        || ok "케이스 27(c): 포인터 교체 실패 → non-zero"
  assert_file_is "케이스 27(c): 포인터 불변" "$(ep_root_of "$fixture")/.current" "gen-1"
  assert_file_is "케이스 27(c): 새 세대는 .short-title 까지 갖춘 고아" \
    "$(ep_root_of "$fixture")/gen-2/.short-title" "$EP_TITLE"
  assert_file_is "케이스 27(c): .bump-failed=pointer-swap" \
    "$(ep_root_of "$fixture")/.bump-failed" "pointer-swap"
  assert_verdict "케이스 27(c): consumer 가 이전 세대를 계속 사용 → 통과" "$fixture" pass
  cleanup_fixture

  # (d) ② 재확인 — mkdir 성공 후 새 세대를 외부에서 지운 상태를 만들어 포인터가 옮겨지지 않는지 확인.
  #     .short-title 을 쓴 직후(첫 mv 성공 직후) 새 세대 디렉토리를 지웁니다.
  fixture="$(mk_full)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"; seed_current "$fixture" gen-1
  _gen2="$(ep_root_of "$fixture")/gen-2"
  ep_invoke_with "$fixture" \
    "_n=0; mv() { _n=\$((_n+1)); command mv \"\$@\"; _rc=\$?; if [[ \$_n -eq 1 ]]; then command rm -rf '$_gen2'; fi; return \$_rc; }" \
    ep_bump "$EP_TITLE" && no "케이스 27(d): 재확인 실패인데 0 반환" \
                        || ok "케이스 27(d): 새 세대 소실 → non-zero"
  assert_file_is "케이스 27(d): 포인터를 옮기지 않음 (dangling 방지)" \
    "$(ep_root_of "$fixture")/.current" "gen-1"
  assert_absent "케이스 27(d): 새 세대가 없음" "$_gen2"
  assert_file_is "케이스 27(d): .bump-failed=recheck" \
    "$(ep_root_of "$fixture")/.bump-failed" "recheck"
  cleanup_fixture

  # (e) 동시 성공 비오염 + .bump-failed 는 세대 디렉토리 **밖**
  fixture="$(mk_prod)"; _current_fixture="$fixture"
  seed_gen "$fixture" gen-1 "$EP_TITLE"
  seed_gen "$fixture" gen-2 "$EP_TITLE"; seed_current "$fixture" gen-2
  seed_record "$fixture" gen-2 sub src.sh
  _rec="$(ep_root_of "$fixture")/gen-2/$(pathkey_of src.sh).sub"
  _rec_before="$(cat "$_rec")"
  ep_invoke_with "$fixture" 'mkdir() { return 1; }' ep_bump "$EP_TITLE" >/dev/null 2>&1 \
    && no "케이스 27(e): 실패한 bump 가 0 반환" || ok "케이스 27(e): 실패한 bump → non-zero"
  assert_file_is "케이스 27(e): 동시 성공 세대 .short-title 불변" \
    "$(ep_root_of "$fixture")/gen-2/.short-title" "$EP_TITLE"
  assert_eq "케이스 27(e): 동시 성공 세대 레코드 불변" "$(cat "$_rec")" "$_rec_before"
  assert_exists "케이스 27(e): .bump-failed 는 루트에 있음" "$(ep_root_of "$fixture")/.bump-failed"
  assert_absent "케이스 27(e): 세대 디렉토리 안에는 없음 (어떤 세대도 무효화 못 함)" \
    "$(ep_root_of "$fixture")/gen-2/.bump-failed"
  assert_absent "케이스 27(e): 다른 세대에도 없음" "$(ep_root_of "$fixture")/gen-1/.bump-failed"
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 결과 출력
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
