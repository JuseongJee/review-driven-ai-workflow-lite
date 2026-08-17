#!/bin/bash
# test_implementation_gate.sh — implementation_gate.sh 통과/차단 로직 격리 검증
# macOS /bin/bash 3.2 호환 (globstar/extglob 불사용)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
HOOK_SOURCE="$HOOK_DIR/implementation_gate.sh"
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
NOJQ_DIR=""
cleanup_all() {
  cleanup_fixture
  if [[ -n "$NOJQ_DIR" && -d "$NOJQ_DIR" ]]; then
    rm -rf "$NOJQ_DIR"
    NOJQ_DIR=""
  fi
}
trap 'cleanup_all' EXIT INT TERM

# ---------------------------------------------------------------------------
# Fixture 생성
#   $1: Status 값 ("__NONE__" 이면 CURRENT_TASK.md 생성 안 함 = 빈 status)
#   $2: autopilot ("yes" 이면 .autopilot_active 생성)
#   hook 은 script_dir/../../.. 를 project_root 로 계산하므로
#   fixture/rd-workflow/scripts/hooks 에 두면 project_root = fixture 가 된다.
# ---------------------------------------------------------------------------
make_fixture() {
  local status="$1" autopilot="$2" with_state="${3:-}"
  local fixture
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/rd-workflow/scripts/hooks"
  cp "$HOOK_SOURCE" "$fixture/rd-workflow/scripts/hooks/implementation_gate.sh"
  cp "$GUARD_COMMON" "$fixture/rd-workflow/scripts/hooks/_guard_common.sh"
  cp "$STATE_COMMON"  "$fixture/rd-workflow/scripts/_state_common.sh"
  if [[ "$status" != "__NONE__" ]]; then
    printf '%s\n' "# Current Task" "" "## Status" "$status" > "$fixture/CURRENT_TASK.md"
  fi
  if [[ "$autopilot" == "yes" ]]; then
    touch "$fixture/.autopilot_active"
  fi
  # REQUEST.md 는 항상 만든다 — 실제 프로젝트에 늘 존재하고, -ef 보조 판정의 대상이다.
  # 이 파일을 읽는 hook 로직은 없으므로 기존 시나리오 동작에 영향이 없다.
  printf '%s\n' "# Request" > "$fixture/REQUEST.md"
  if [[ "$with_state" == "link" ]]; then
    ln -s CURRENT_TASK.md "$fixture/ct_link.md"
  fi
  if [[ "$with_state" == "hardlink" ]]; then
    ln "$fixture/CURRENT_TASK.md" "$fixture/ct_hardlink.md"
  fi
  # task-state 는 요청 시에만 만든다. 이 파일이 있으면 get_task_status 가 CURRENT_TASK.md
  # 대신 task-state 를 읽으므로(_state_common.sh 의 단일 소스 규칙), 기존 Status 시나리오
  # 전부의 판정 소스가 바뀐다. 따라서 기본은 미생성이다.
  if [[ "$with_state" == "yes" ]]; then
    mkdir -p "$fixture/rd-workflow-workspace/.lifecycle"
    printf '%s\n' "schema=1" "short-title=-" "status=구현 중" \
      "fr-branch=null" "worktree-path=null" "source-fr=-" \
      > "$fixture/rd-workflow-workspace/.lifecycle/task-state"
  fi
  printf '%s' "$fixture"
}

# run_with_timeout <상한초> <stdin 파일> <명령...>
# 명령을 실행하고 상한을 넘기면 **프로세스 그룹째** 강제 종료한다. 결과 종료 코드는
# 전역 _timeout_last_exit 에 담는다 (강제 종료 시 137).
#
# 왜 그룹인가: hook 은 `$(read_hook_agent_id)` 로 파서(jq/awk)를 **자식**에 둔다.
# 직접 PID 만 kill 하면 그 자식이 고아로 남아 계산을 계속한다 — 테스트는 상한에 반환해도
# 회귀의 CPU 소모는 그대로 이어진다. 그래서 set -m 으로 대상을 자체 그룹 리더로 띄우고
# `kill -- -<pgid>` 로 그룹을 종료한다. 같은 방식과 같은 소유권 확인 절차를
# adapter_codex.sh 가 이미 쓰고 있다.
#
# pgid 는 spawn 직후 `ps -eo pid,pgid` 로 **구성원 존재**를 보고 확정한다. 리더 행만 찾으면
# spawn 레이스로 빈 값이 나올 수 있다. pgid == 리더 pid 이므로 오탐은 불가능하다.
# watchdog 서브셸도 자체 그룹으로 띄운다 — 그러지 않으면 그 안의 sleep 이 고아로 남아
# 호출자에게서 상속한 fd 를 상한 시간만큼 계속 붙잡는다.
# 외부 timeout(1) 에는 의존하지 않는다 (macOS 기본 설치에 없다).
_timeout_last_exit=0
run_with_timeout() {
  local limit="$1" stdin_file="$2"
  shift 2
  local cpid wpid pg="" n try
  set -m
  "$@" < "$stdin_file" >/dev/null 2>&1 &
  cpid=$!
  set +m
  for try in 1 2 3 4 5 6 7 8 9 10; do
    n="$( { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$cpid" '$2==g' | wc -l | tr -d ' ' )"
    if [[ "$n" -gt 0 ]]; then pg="$cpid"; break; fi
    sleep 0.05
  done
  set -m
  ( sleep "$limit"
    if [[ -n "$pg" ]]; then kill -9 -- -"$pg" 2>/dev/null
    else kill -9 "$cpid" 2>/dev/null; fi ) >/dev/null 2>&1 &
  wpid=$!
  set +m
  _timeout_last_exit=0
  wait "$cpid" 2>/dev/null || _timeout_last_exit=$?
  kill -9 -- -"$wpid" 2>/dev/null || kill -9 "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null || true
}

# make_big_content
# 큰 tool_input.content 를 만든다(200KB 이상). 안에 판별 필드 이름과 구조 문자를 JSON escape
# 형태로 넣어, "content 안의 문자열을 최상위 필드로 오인하는가" 와 "입력 크기에 선형인가" 를
# 한 payload 로 함께 건다. 배가 방식이라 생성 자체는 십여 번의 연결로 끝난다.
make_big_content() {
  local unit='a,b{} \"agent_type\" \"agent_id\" '
  local s="$unit"
  while [[ ${#s} -lt 204800 ]]; do
    s="$s$s"
  done
  printf '%s' "$s"
}

_hook_last_exit=0
run_hook() {
  local fixture="$1" file_path="$2" agent_id="${3:-}"
  local payload
  # 세 입력을 구분한다:
  #   "__EMPTY__"      → agent_type 필드는 있고 값이 빈 문자열. 공식 계약이 규정하지 않은 경계다.
  #   "__PRETTY__"     → 최상위 agent_type 을 JSON 공백 4종(space·tab·CR·LF)으로 감싼 pretty 입력.
  #   "__MIXED__"      → agent_type 은 빈 문자열, agent_id 만 값이 있는 혼합 입력.
  #   "__BIG__"        → 판별 필드 없이 content 만 큰 입력. 안에 판별 필드 문자열이 들어 있다.
  #   "id:<값>"        → 최상위 agent_id 로 넣는다 (공식 문서가 기술하는 필드).
  #   그 밖의 비어있지 않은 값 → 최상위 agent_type 으로 넣는다 (이 버전이 실제로 보내는 필드).
  #   빈 인자          → 두 필드 모두 넣지 않아 메인 스레드 호출을 그대로 재현한다.
  if [[ "$agent_id" == "__EMPTY__" ]]; then
    payload="{\"agent_type\":\"\",\"tool_input\":{\"file_path\":\"$file_path\"}}"
  elif [[ "$agent_id" == "__PRETTY__" ]]; then
    # 키와 ':' 사이, ':' 와 값 사이에 각각 다른 공백 문자를 넣는다. space 만 건너뛰는
    # 구현이면 판별에 실패해 subagent 가 메인으로 통과한다(fail-open 구멍).
    payload="$(printf '{\n  "agent_type"\t:\r\n "general-purpose" ,\n  "tool_input" : { "file_path" : "%s" }\n}' "$file_path")"
  elif [[ "$agent_id" == "__MIXED__" ]]; then
    payload="{\"agent_type\":\"\",\"agent_id\":\"agent_abc123\",\"tool_input\":{\"file_path\":\"$file_path\"}}"
  elif [[ "$agent_id" == "__BIG__" ]]; then
    payload="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$file_path\",\"content\":\"$(make_big_content)\"}}"
  elif [[ "$agent_id" == "__NESTED__" ]]; then
    # 최상위에는 판별 필드가 없고 tool_input 하위에만 있는 payload.
    # 최상위만 본다는 계약이 지켜지면 메인 세션으로 판정되어 통과해야 한다.
    payload="{\"tool_input\":{\"file_path\":\"$file_path\",\"agent_type\":\"nested-only\",\"agent_id\":\"nested-only\"}}"
  elif [[ "$agent_id" == id:* ]]; then
    payload="{\"agent_id\":\"${agent_id#id:}\",\"tool_input\":{\"file_path\":\"$file_path\"}}"
  elif [[ -n "$agent_id" ]]; then
    payload="{\"agent_type\":\"$agent_id\",\"tool_input\":{\"file_path\":\"$file_path\"}}"
  else
    payload="{\"tool_input\":{\"file_path\":\"$file_path\"}}"
  fi
  _hook_last_exit=0
  if [[ -z "${HOOK_TIMEOUT_SEC:-}" ]]; then
    printf '%s' "$payload" | \
      bash "$fixture/rd-workflow/scripts/hooks/implementation_gate.sh" \
      >/dev/null 2>&1 || _hook_last_exit=$?
    return 0
  fi
  local pfile
  pfile="$(mktemp)"
  printf '%s' "$payload" > "$pfile"
  run_with_timeout "$HOOK_TIMEOUT_SEC" "$pfile" \
    bash "$fixture/rd-workflow/scripts/hooks/implementation_gate.sh"
  _hook_last_exit="$_timeout_last_exit"
  rm -f "$pfile"
}

# ---------------------------------------------------------------------------
# 시나리오 실행
#   $1 num, $2 name, $3 status, $4 autopilot, $5 file_path 템플릿({F}=fixture), $6 expected_exit
# ---------------------------------------------------------------------------
run_scenario() {
  local num="$1" name="$2" status="$3" autopilot="$4" path_tmpl="$5" expected="$6" agent_id="${7:-}" with_state="${8:-}"
  local fixture
  fixture="$(make_fixture "$status" "$autopilot" "$with_state")"
  if [[ "$expected" == "CASE" ]]; then
    # make_fixture 가 만든 CURRENT_TASK.md 가 소문자 이름으로도 보이면 비구분 볼륨이다.
    if [[ -e "$fixture/current_task.md" ]]; then expected=2; else expected=0; fi
  fi
  _current_fixture="$fixture"
  local fixture_base fixture_parent file_path
  fixture_base="$(basename "$fixture")"
  fixture_parent="$(dirname "$fixture")"
  file_path="$path_tmpl"
  file_path="${file_path//\{FB\}/$fixture_base}"
  file_path="${file_path//\{FP\}/$fixture_parent}"
  file_path="${file_path//\{F\}/$fixture}"
  run_hook "$fixture" "$file_path" "$agent_id"
  local label="[${MODE:-jq}] scenario ${num}: ${name}"
  if [[ "$_hook_last_exit" == "$expected" ]]; then
    echo "[PASS] $label (exit=$_hook_last_exit)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected exit=$expected actual=$_hook_last_exit (fixture: $fixture)" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# 성능 회귀 시나리오
#   큰 payload 에서 판별 파서가 입력 크기에 선형인지 건다. 상한 10초는 정상 구현의 실측치
#   (200KB content, no-jq 0.08초) 대비 100배 이상 여유라 환경 편차로 흔들리지 않는다.
#   문자 단위 bash substring 루프처럼 제곱 시간인 구현이면 같은 입력에서 수백 초가 걸리므로
#   반드시 걸린다 (교체 전 실측: content 10KB 1.2초, 20KB 4.8초).
#   상한은 **watchdog 으로 강제**한다 (run_hook 의 HOOK_TIMEOUT_SEC 분기 주석 참조).
#   사후 비교만 하면 회귀 시 실패까지 수백 초가 걸려 self_test.sh 전체가 그만큼 멈춘다.
#   exit 기대값도 함께 본다 — content 안의 판별 필드 문자열을 최상위로 오인하면 안 된다.
# ---------------------------------------------------------------------------
PERF_LIMIT_SEC=10
run_perf_scenario() {
  local num="$1" name="$2"
  local fixture
  fixture="$(make_fixture "구현 중" "no")"
  _current_fixture="$fixture"
  local t0=$SECONDS
  HOOK_TIMEOUT_SEC="$PERF_LIMIT_SEC" run_hook "$fixture" "$fixture/CURRENT_TASK.md" "__BIG__"
  local dt=$((SECONDS - t0))
  local label="[${MODE:-jq}] scenario ${num}: ${name}"
  if [[ "$_hook_last_exit" == "0" && $dt -lt $PERF_LIMIT_SEC ]]; then
    echo "[PASS] $label (exit=$_hook_last_exit, ${dt}s < ${PERF_LIMIT_SEC}s)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — exit=$_hook_last_exit (기대 0; 137=상한 초과로 강제 종료), 소요 ${dt}s (상한 ${PERF_LIMIT_SEC}s)" >&2
    FAIL=$((FAIL + 1))
  fi
  cleanup_fixture
}

# ---------------------------------------------------------------------------
# watchdog 자체 검증 시나리오
#   시나리오 42 의 상한은 run_with_timeout 이 자손까지 회수해야 의미가 있다. hook 은
#   파서를 명령 치환 자식에 두므로, 직접 PID 만 죽이는 구현이면 테스트는 상한에 반환해도
#   제곱 시간 계산이 고아로 남아 CPU 를 계속 쓴다 (final diff review 가 실측 재현).
#   그 구조를 그대로 본뜬 probe 로 자손 종료를 결정적으로 고정한다 — 실제 hook 이 아니라
#   watchdog 기구 자체를 대상으로 삼아, 파서 성능과 무관하게 항상 같은 판정이 나온다.
# ---------------------------------------------------------------------------
# _pid_terminated <pid>
# return 0 = 그 PID 가 더 이상 실행 중이 아니다 (부재 또는 zombie).
# kill -0 만으로는 부족하다 — SIGKILL 을 받고 아직 reap 되지 않은 zombie 에도 성공한다.
# zombie 는 이미 종료된 프로세스이며 CPU 를 쓰지 않으므로 "종료"로 인정한다.
_pid_terminated() {
  local pid="$1" st
  kill -0 "$pid" 2>/dev/null || return 0
  st="$( { ps -o stat= -p "$pid" 2>/dev/null || true; } | tr -d ' ' )"
  [[ -z "$st" ]] && return 0
  case "$st" in Z*) return 0 ;; esac
  return 1
}

run_watchdog_scenario() {
  local num="$1" name="$2"
  local dir probe child rc_ok=0 desc_ok=0 child_pid=""
  dir="$(mktemp -d)"
  probe="$dir/probe.sh"
  child="$dir/child.pid"
  # hook 과 같은 형태: 명령 치환 자식이 오래 도는 작업을 맡는다.
  {
    printf '%s\n' '#!/bin/bash'
    printf 'v=$(bash -c '"'"'echo $$ > "%s"; sleep 60'"'"')\n' "$child"
    printf '%s\n' 'sleep 60'
  } > "$probe"
  run_with_timeout 2 /dev/null bash "$probe"
  [[ "$_timeout_last_exit" == "137" ]] && rc_ok=1
  child_pid="$(cat "$child" 2>/dev/null || true)"
  # 종료 판정은 유한한 grace 안에서 폴링한다. 그룹 kill 직후 한 번만 kill -0 을 보면
  # 아직 회수되지 않은(zombie) PID 를 실행 중으로 오인해 테스트가 환경 따라 흔들린다.
  # 판별력은 그대로다 — 직접 PID 만 죽이는 구현에서는 자손이 60초를 계속 살아 있으므로
  # 3초 grace 로는 절대 사라지지 않는다.
  if [[ -n "$child_pid" ]]; then
    local waited=0
    while [[ $waited -lt 60 ]]; do
      if _pid_terminated "$child_pid"; then desc_ok=1; break; fi
      sleep 0.05
      waited=$((waited + 1))
    done
  fi
  [[ -n "$child_pid" ]] && kill -9 "$child_pid" 2>/dev/null
  rm -rf "$dir"
  local label="[${MODE:-jq}] scenario ${num}: ${name}"
  if [[ $rc_ok -eq 1 && $desc_ok -eq 1 ]]; then
    echo "[PASS] $label (rc=137, 자손 pid=${child_pid} 종료 확인)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — rc=$_timeout_last_exit (기대 137), 자손 pid=${child_pid:-없음} 종료=$desc_ok" >&2
    FAIL=$((FAIL + 1))
  fi
}

run_all_scenarios() {
# project_root 밖 경로는 워크플로 단계와 무관하게 통과해야 한다 (FR 핵심)
run_scenario 1 "project_root 밖(plan) + 진행중 → 통과" \
  "검증 중" "no" "/outside/.claude/plans/x.md" 0
run_scenario 9 "project_root 밖(메모리) + 진행중 → 통과" \
  "diff review 대기" "no" "/Users/x/.claude/projects/p/memory/m.md" 0

# project_root 안 소스(화이트리스트 밖) + 진행중 → 차단 (회귀 방지)
run_scenario 2 "project_root 안 소스 + 진행중 → 차단" \
  "검증 중" "no" "{F}/rd-workflow/scripts/foo.sh" 2

# 대기 중 / 완료 / 빈 값 → 자유 수정 허용 (cfd356f drift fix)
run_scenario 3 "대기 중 + 소스 → 통과 (drift fix)" \
  "대기 중" "no" "{F}/rd-workflow/scripts/foo.sh" 0
run_scenario 4 "완료 + 소스 → 통과 (drift fix)" \
  "완료" "no" "{F}/rd-workflow/scripts/foo.sh" 0
run_scenario 10 "빈 Status + 소스 → 통과 (drift fix)" \
  "__NONE__" "no" "{F}/rd-workflow/scripts/foo.sh" 0

# 구현 중 / 실행 중 → 통과
run_scenario 5 "구현 중 + 소스 → 통과" \
  "구현 중" "no" "{F}/rd-workflow/scripts/foo.sh" 0

# 워크플로 화이트리스트 파일 + 진행중 → 통과
run_scenario 6 "워크플로 화이트리스트(CURRENT_TASK.md) + 진행중 → 통과" \
  "검증 중" "no" "{F}/CURRENT_TASK.md" 0

# autopilot 활성 → 진행중 + 소스라도 통과
run_scenario 7 "autopilot + 진행중 + 소스 → 통과" \
  "검증 중" "yes" "{F}/rd-workflow/scripts/foo.sh" 0

# 빈 file_path → 통과
run_scenario 8 "빈 file_path → 통과" \
  "검증 중" "no" "" 0

# --- subagent 공유 진행 상태 차단 (stop-hook-subagent-shared-state-overwrite) ---
# 판별 필드(agent_type, 없으면 agent_id)는 subagent 안에서만 오는 hook 입력 최상위 필드다.
run_scenario 11 "subagent + CURRENT_TASK.md → 차단" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 2 "agent_abc123"
run_scenario 12 "메인 세션(판별 필드 없음) + CURRENT_TASK.md → 통과 (회귀 방지)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 0
# autopilot 우회보다 앞에서 판정해야 한다 — 유실 사고가 autopilot 실행 중 발생했다.
run_scenario 13 "subagent + autopilot 활성 + CURRENT_TASK.md → 차단 (판정 순서 고정)" \
  "구현 중" "yes" "{F}/CURRENT_TASK.md" 2 "agent_abc123"
run_scenario 14 "subagent + REQUEST.md → 차단" \
  "구현 중" "no" "{F}/REQUEST.md" 2 "agent_abc123"
run_scenario 15 "subagent + task-state → 차단" \
  "구현 중" "no" "{F}/rd-workflow-workspace/.lifecycle/task-state" 2 "agent_abc123"
# 차단 집합은 진행 상태 3종으로 좁다 — spec/plan/report 는 단일 작성자 산출물이라 제외한다.
run_scenario 16 "subagent + spec 파일 → 통과 (좁은 집합 경계)" \
  "구현 중" "no" "{F}/rd-workflow-workspace/specs/changes/x.md" 0 "agent_abc123"
run_scenario 17 "subagent + 구현 소스 + 구현 중 → 통과 (기존 Status 판정 불변)" \
  "구현 중" "no" "{F}/rd-workflow/scripts/foo.sh" 0 "agent_abc123"
# --- 경로 매칭 계약 (change spec §4.2) ---
# 블랙리스트는 과소 매칭이 우회로 실패하므로 lexical alias 를 전부 정규화한다.
# 18·20·25 는 {F} 를 쓰지 않는다 — 상대 표기 자체가 검증 대상이다.
run_scenario 18 "subagent + ./CURRENT_TASK.md → 차단 (선두 .)" \
  "구현 중" "no" "./CURRENT_TASK.md" 2 "agent_abc123"
run_scenario 19 "subagent + docs/CURRENT_TASK.md → 통과 (같은 basename 다른 경로)" \
  "구현 중" "no" "{F}/docs/CURRENT_TASK.md" 0 "agent_abc123"
run_scenario 20 "subagent + ././CURRENT_TASK.md → 차단 (선두 . 반복)" \
  "구현 중" "no" "././CURRENT_TASK.md" 2 "agent_abc123"
run_scenario 21 "subagent + 중복 슬래시 → 차단 (빈 세그먼트)" \
  "구현 중" "no" "{F}//CURRENT_TASK.md" 2 "agent_abc123"
run_scenario 22 "subagent + docs/../CURRENT_TASK.md → 차단 (.. 축약)" \
  "구현 중" "no" "{F}/docs/../CURRENT_TASK.md" 2 "agent_abc123"
# 23·24 는 단계별 문자열 처리가 놓치는 혼합 별칭이다 — 세그먼트 스택 1회 주행이라야 잡힌다.
run_scenario 23 "subagent + docs/./../CURRENT_TASK.md → 차단 (내부 . 과 .. 혼합)" \
  "구현 중" "no" "{F}/docs/./../CURRENT_TASK.md" 2 "agent_abc123"
run_scenario 24 "subagent + docs/.././CURRENT_TASK.md → 차단 (.. 축약 뒤에 남는 .)" \
  "구현 중" "no" "{F}/docs/.././CURRENT_TASK.md" 2 "agent_abc123"
# 25 는 오탐 방지다. 소진 불가한 선두 '..' 를 일반 세그먼트처럼 지우면 프로젝트 밖 경로를
# 차단하게 되어 계약과 반대가 된다.
run_scenario 25 "subagent + ../../CURRENT_TASK.md → 통과 (연속 선두 .. 오탐 방지)" \
  "구현 중" "no" "../../CURRENT_TASK.md" 0 "agent_abc123"
# 26·27 은 프로젝트를 벗어난 뒤 되돌아오는 경로다. 27 은 원시 접두 비교가 불일치하므로
# 차단 판정이 ':15-17' 보다 앞에 있어야만 잡힌다 (change spec §4.1).
run_scenario 26 "subagent + <root>/../<basename>/CURRENT_TASK.md → 차단" \
  "구현 중" "no" "{F}/../{FB}/CURRENT_TASK.md" 2 "agent_abc123"
run_scenario 27 "subagent + 접두 불일치 절대 경로 별칭 → 차단 (판정 위치 고정)" \
  "구현 중" "no" "{FP}/other-proj/../{FB}/CURRENT_TASK.md" 2 "agent_abc123"
# 28 은 fail-open 경계다. 공식 문서가 빈 문자열 케이스를 규정하지 않으므로
# 필드 부재(12)와 같은 판정에 도달하는지 고정한다.
run_scenario 28 "subagent + agent_type 빈 문자열 + CURRENT_TASK.md → 통과 (fail-open 경계)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 0 "__EMPTY__"
# --- case alias (실파일 동일성 보조 판정) ---
# 29·31·32 는 기대값이 볼륨 성질에 따라 다르므로 CASE 센티널을 쓴다.
# 비구분 볼륨(macOS 기본) → 정본과 같은 실파일이므로 차단.
# 구분 볼륨 → 별개 파일이거나 부재이므로 통과(오탐 방지).
run_scenario 29 "subagent + current_task.md (case alias) → 볼륨 성질에 따라" \
  "구현 중" "no" "{F}/current_task.md" CASE "agent_abc123"
run_scenario 30 "subagent + docs/current_task.md → 통과 (case alias 오탐 방지)" \
  "구현 중" "no" "{F}/docs/current_task.md" 0 "agent_abc123"
run_scenario 31 "subagent + request.md (case alias) → 볼륨 성질에 따라" \
  "구현 중" "no" "{F}/request.md" CASE "agent_abc123"
# 32 는 task-state 픽스처가 필요하다 — -ef 는 대상이 존재할 때만 참이다.
run_scenario 32 "subagent + .lifecycle/TASK-STATE (case alias) → 볼륨 성질에 따라" \
  "구현 중" "no" "{F}/rd-workflow-workspace/.lifecycle/TASK-STATE" CASE "agent_abc123" "yes"
# 33·34 는 -ef 의 부수 효과다 — 링크는 볼륨 성질과 무관하게 같은 실파일을 가리킨다.
run_scenario 33 "subagent + CURRENT_TASK.md 를 가리키는 symlink → 차단 (양 볼륨 공통)" \
  "구현 중" "no" "{F}/ct_link.md" 2 "agent_abc123" "link"
run_scenario 34 "subagent + CURRENT_TASK.md 의 hardlink → 차단 (양 볼륨 공통)" \
  "구현 중" "no" "{F}/ct_hardlink.md" 2 "agent_abc123" "hardlink"
# 35 는 차단 판정을 기존 통과 분기 전부보다 앞으로 옮긴 데 대한 안전 확인이다.
# is_shared_state_file 이 프로젝트 밖 절대 경로에 스스로 return 1 을 반환하므로
# 밖 경로 동작이 바뀌지 않아야 한다.
# 판별 필드가 있는 상태로 새 블록을 프로젝트 밖 경로로 구동하는 유일한 시나리오다
# (기존 1·9 는 판별 필드를 넘기지 않아 새 블록에 진입하지 않는다). 게이트 조건에서
# is_shared_state_file 판정이 빠지는 종류의 변경을 검출한다 — 복사본 실측으로 확인했다.
# 한계: 프로젝트 밖에 둔 정본 hardlink 로 쓰는 경로는 이 시나리오가 잡지 못하며,
#       그 우회는 spec 이 확정한 비목표(경로의 물리적 해석)에 해당한다.
run_scenario 35 "subagent + project_root 밖 절대 경로 → 통과 (판정 위치 이동 부작용 없음)" \
  "구현 중" "no" "/outside/.claude/plans/x.md" 0 "agent_abc123"
# 36~38 은 subagent 판별 필드 계약을 고정한다. 실제 입력에 오는 것은 agent_type 이며
# (Claude Code 2.1.228 hook 입력 덤프로 실측), agent_id 는 공식 문서 기술 필드다.
# 어느 쪽이 와도 차단해야 하고, 실제 입력에 섞여 오는 빈 문자열은 fail-open 이다.
run_scenario 36 "subagent(agent_type) + CURRENT_TASK.md → 차단 (실측 계약)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 2 "general-purpose"
run_scenario 37 "subagent(agent_id) + CURRENT_TASK.md → 차단 (문서 계약 호환)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 2 "id:agent_abc123"
run_scenario 38 "메인 세션(prompt_id·effort 만) + CURRENT_TASK.md → 통과 (회귀 방지)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 0
# 39 는 판별 필드 탐색이 최상위에 한정되는지 고정한다. 전체 문자열에서 첫 "agent_type" 을
# 찾는 구현이면 tool_input 하위 필드를 최상위로 오인해 메인 세션을 차단한다 —
# fail-open 경계가 조용히 fail-closed 로 뒤집히는 회귀다 (final diff review 가 실측 재현).
run_scenario 39 "메인 세션 + tool_input 하위에만 판별 필드 → 통과 (최상위 한정 계약)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 0 "__NESTED__"
# 40 은 JSON 공백 처리를 건다. 키와 ':' 사이 공백으로 space 만 허용하는 구현이면
# pretty-printed 입력에서 판별에 실패하고, fail-open 이므로 subagent 가 그대로 통과한다.
run_scenario 40 "subagent + pretty-printed 최상위 agent_type → 차단 (JSON 공백 4종)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 2 "__PRETTY__"
# 41 은 두 판별 필드가 함께 올 때 jq 경로와 폴백 경로가 같은 답을 내는지 건다.
# "먼저 비어 있지 않은 값" 이 계약이므로 agent_type 이 빈 값이면 agent_id 를 쓴다.
run_scenario 41 "subagent + agent_type 빈 값 + agent_id 값 있음 → 차단 (두 모드 판정 일치)" \
  "구현 중" "no" "{F}/CURRENT_TASK.md" 2 "__MIXED__"
# --- SDD·brainstorm 워크스페이스 편입 + lexical 정규화 ---
# (implementation-gate-sdd-workspace-block)
# 두 경로는 superpowers 플러그인의 워크스페이스이며 정본·루트 .gitignore 양쪽에 등재된
# 상위 '.superpowers/' 아래 있다. 리뷰 대상 diff 를 오염시키지 않으므로 단계 게이트에서
# 통과시킨다. 부모 '.superpowers/' 를 통째로 열지 않는 이유는 change spec §2.1 참조.
run_scenario 44 "orchestrator + SDD progress 기록 + diff review 대기 → 통과" \
  "diff review 대기" "no" "{F}/.superpowers/sdd/p/progress.md" 0
run_scenario 45 "subagent + SDD task report + diff review 대기 → 통과" \
  "diff review 대기" "no" "{F}/.superpowers/sdd/p/task-1-report.md" 0 "agent_abc123"
run_scenario 46 "brainstorm 워크스페이스 + diff review 대기 → 통과" \
  "diff review 대기" "no" "{F}/.superpowers/brainstorm/s/content/m.html" 0
# 음성 짝 — 이 케이스 없이 44~46 만 고정하면 gate 무력화와 구별되지 않는다.
run_scenario 47 "구현 파일 직접 경로 + diff review 대기 → 차단" \
  "diff review 대기" "no" "{F}/rd-workflow/scripts/foo.sh" 2
# 허용 접두로 시작해 '..' 로 디렉토리 밖 구현 파일을 가리키는 경로.
# x → sdd → .superpowers → project_root 로 세 단계를 거슬러야 실제 구현 파일에 닿는다.
# 이 케이스는 패턴 추가 전에도 통과한다(매칭 대상이 없어 차단). 존재 이유는
# '정규화 없이 case 두 줄만 추가하는' 불완전 구현을 잡는 것이다 — 그 구현에서만 뒤집힌다.
run_scenario 48 "SDD 접두 + '..' 탈출 → 차단 (패턴만 추가한 구현을 잡는 안전 회귀)" \
  "diff review 대기" "no" "{F}/.superpowers/sdd/x/../../../rd-workflow/scripts/foo.sh" 2
# 기존 화이트리스트 패턴도 같은 탈출을 허용해 왔다 — 정규화로 함께 닫는다 (의도된 동작 변경).
run_scenario 49 "기존 패턴(rd-workflow-workspace) + '..' 탈출 → 차단 (동작 변경)" \
  "diff review 대기" "no" "{F}/rd-workflow-workspace/../rd-workflow/scripts/foo.sh" 2
# 허용 디렉토리 안에 머무는 '..' 별칭은 통과가 의도다 (과소 매칭 해소).
run_scenario 50 "SDD 안에 머무는 '..' 별칭 → 통과" \
  "diff review 대기" "no" "{F}/.superpowers/sdd/x/../progress.md" 0
# 기존 화이트리스트 두 갈래의 정상 경로가 '차단 상태' 에서 실제로 통과하는지 고정한다.
# 정확 일치 5종은 시나리오 6 이 이미 차단 상태로 검증하지만, 아래 두 패턴에는 그 짝이
# 없었다 — 기존 시나리오 16 의 workspace 경로는 Status 가 '구현 중' 이라 화이트리스트가
# 깨져도 Status 분기에서 통과해 이 회귀를 검출하지 못한다 (final diff review Finding 2).
# 51 의 경로는 rd-workflow-workspace/ 밖에 둔다 — 안에 두면 'rd-workflow-workspace/*'
# 패턴에 먼저 걸려 '*/turns/*.md' 가 죽어도 통과해, 그 패턴을 독립 검증하지 못한다.
run_scenario 51 "기존 패턴(*/turns/*.md) 정상 경로 + diff review 대기 → 통과" \
  "diff review 대기" "no" "{F}/handoffs/review_pipeline/s/turns/001_author.md" 0
run_scenario 52 "기존 패턴(rd-workflow-workspace) 정상 경로 + diff review 대기 → 통과" \
  "diff review 대기" "no" "{F}/rd-workflow-workspace/specs/changes/x.md" 0
# 42 는 성능 회귀와 오인 차단을 한 payload 로 건다 (run_perf_scenario 주석 참조).
run_perf_scenario 42 "메인 세션 + 200KB content(내부에 판별 필드 문자열) → 통과 + 선형 시간"
# 43 은 42 의 상한을 실효화하는 기구를 검증한다 (run_watchdog_scenario 주석 참조).
run_watchdog_scenario 43 "watchdog 상한 초과 → 명령 치환 자손까지 회수"
}

# --- jq 경로와 bash 폴백을 둘 다 결정적으로 실행한다 ---
# 실패하는 jq shim 을 PATH 앞에 두면 command -v jq 는 성공하고 jq 호출은 실패하므로
# 세 파서 함수(read_hook_agent_id / extract_json_field / read_stop_hook_active)의
# bash 폴백 분기가 환경과 무관하게 반드시 실행된다.
NOJQ_DIR="$(mktemp -d)"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$NOJQ_DIR/jq"
chmod +x "$NOJQ_DIR/jq"
_orig_path="$PATH"

# 픽스처가 놓이는 볼륨이 대소문자를 구분하는지 남긴다 — case alias 시나리오의 기대값 근거다.
_probe="$(mktemp -d)"
printf 'x\n' > "$_probe/CASEPROBE"
if [[ -e "$_probe/caseprobe" ]]; then
  echo "volume: case-insensitive — case alias 시나리오(29·31·32)는 차단을 기대한다"
else
  echo "volume: case-sensitive — case alias 시나리오(29·31·32)는 통과를 기대한다(오탐 방지)"
fi
rm -rf "$_probe"

if command -v jq >/dev/null 2>&1; then
  echo "jq: available — 'jq' 모드는 실제 jq 경로를 실행한다"
else
  echo "jq: absent — 'jq' 모드도 bash 폴백을 실행한다 (개수는 동일)"
fi

echo ""
echo "=== 모드: no-jq (실패하는 jq shim 강제) ==="
MODE="no-jq"
PATH="$NOJQ_DIR:$_orig_path"
run_all_scenarios

echo ""
echo "=== 모드: jq (환경 PATH 그대로) ==="
MODE="jq"
PATH="$_orig_path"
run_all_scenarios

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
