#!/usr/bin/env bash
# 격리 워크스페이스로 에이전트 세션을 인계한다.
#   공통 계약은 "worktree 생성 + 기동 명령 제시" 이고, herdr 에서만 실제 기동까지 한다.
#   자식 세션이 또 세션을 띄우지 않도록 RD_CHILD_SESSION 으로 깊이를 1 로 제한한다.

session_launch_command() {  # <worktree-path> <slug> [<model>]
  local model="${3-}"
  if [[ $# -lt 3 ]]; then
    IFS=$'\t' read -r _ model < <(session_launch_model "$1")
  fi
  if [[ -n "$model" ]]; then
    printf 'cd %q && claude --model %q\n' "$1" "$model"
  else
    printf 'cd %q && claude\n' "$1"
  fi
}

session_launch_status_hint() {  # <launch> [<slug>]
  case "$1" in
    ok)      printf '이 세션은 여기서 멈춥니다 — 이후 단계는 기동된 작업 세션(%s)이 진행합니다.\n' "${2:-<slug>}" ;;
    failed)  printf '자식 세션이 없습니다 — 이 세션이 이어서 진행하거나 위 명령으로 세션을 여십시오.\n' ;;
    unknown) printf '호출 세션도 이어받지 않습니다 — 확인: bash rd-workflow/scripts/rd task resolve-launch %s\n' "${2:-<slug>}" ;;
    *)       printf '자식 세션이 없습니다 — 이 세션이 이어서 진행하거나 위 명령으로 세션을 여십시오.\n' ;;
  esac
}

# 색인의 `launch` 값을 사람이 읽는 한 줄로 바꿉니다 — **표시 계약의 단일 출처**입니다
# (final diff review F8). `rd task list` 와 세션 시작 요약이 각자 같은 case 문을 들고
# 있었고, 그 복제 때문에 `unknown` 을 한쪽은 「확인 필요」, 다른 쪽은 「자동 기동 미수행」
# 으로 표시했습니다. 두 화면이 같은 색인 값을 두고 서로 다른 말을 하면 사용자는 살아
# 있을 수 있는 세션을 없다고 믿습니다. 문구를 고칠 일이 생기면 여기만 고칩니다.
#   unknown·빈 값은 **모두 「확인 필요」** 입니다 — "확인되지 않았다" 는 "없다" 가
#   아닙니다(spec D7).
task_launch_label() {  # <launch-raw>
  case "${1-}" in
    ok)        printf '기동 성공\n' ;;
    failed)    printf '기동 실패\n' ;;
    none)      printf '자동 기동 미수행\n' ;;
    launching) printf '확인 필요\n' ;;
    *)         printf '확인 필요\n' ;;
  esac
}


# 세션을 기동·조회할 백엔드를 정합니다 (stdout: herdr | hc | none).
#   터미널 herdr 가 먼저입니다 — `HERDR_ENV` 와 `HC_TERMINAL_ID` 가 함께 있으면 herdr app 터미널
#   안에서 터미널 herdr 를 띄운 경우이고, 사용자가 보는 화면은 안쪽 herdr 이기 때문입니다.
#   환경 변수만으로 정하지 않고 명령 존재도 함께 봅니다(없는 명령을 권하지 않기 위함, F1).
session_launch_backend() {
  if session_backend_usable herdr; then printf 'herdr\n'
  elif session_backend_usable hc; then printf 'hc\n'
  else printf 'none\n'
  fi
}

# 그 백엔드를 이 셸에서 실제로 호출할 수 있는지 (rc 0/1). herdr·hc 외의 값은 쓸 수 없음입니다.
session_backend_usable() {  # <backend>
  case "${1-}" in
    herdr) [[ -n "${HERDR_ENV:-}" ]] && command -v herdr >/dev/null 2>&1 ;;
    hc)    [[ -n "${HC_TERMINAL_ID:-}" ]] && command -v hc >/dev/null 2>&1 ;;
    *)     return 1 ;;
  esac
}

# 내부 헬퍼: 이 머신에 `timeout` 명령이 없으므로 백그라운드 + 폴링으로 유한 시간을
# 강제한다. stdout 은 $2 파일에 남기고, 리턴 값은 명령의 종료 코드(타임아웃이면 124).
#   stderr 는 기본으로 버린다. herdr 는 오류 JSON(`{"error":{"code":..}}`)을 **stderr** 로
#   내므로(2026-10-29 실측), 코드가 필요한 호출부는 `RD_SL_ERRFILE=<파일>` 을 앞에 붙여 받는다.
_session_launch_run_with_timeout() {  # <timeout-secs> <outfile> <cmd...>
  local timeout_secs="$1" outfile="$2"; shift 2
  : > "$outfile"
  ( "$@" >"$outfile" 2>"${RD_SL_ERRFILE:-/dev/null}" ) &
  local pid=$!
  # 혼합 폴링: 처음 20회(약 1초)는 0.05초 간격, 이후는 0.2초 간격. 짧은 명령은 빨리 끝나고
  #   긴 대기는 sleep 프로세스를 초당 5개만 띄운다. 상한(초) 의미는 그대로다.
  #   부하가 높으면 sleep 을 띄우는 비용이 쌓여 횟수만으로는 상한이 몇 배로 늘어난다. 그래서
  #   벽시계(SECONDS, 1초 단위)가 상한을 넘으면 횟수와 무관하게 끝낸다 — 최대 상한+1초 남짓.
  local max_checks start="$SECONDS"
  if (( timeout_secs <= 1 )); then max_checks=$(( timeout_secs * 20 ))
  else max_checks=$(( 20 + (timeout_secs - 1) * 5 )); fi
  [[ "$max_checks" -lt 1 ]] && max_checks=1
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( i >= max_checks || SECONDS - start > timeout_secs )); then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    if (( i < 20 )); then sleep 0.05; else sleep 0.2; fi
    i=$((i+1))
  done
  wait "$pid"
}

# 내부 헬퍼: herdr 자체 대기(`--timeout`)에 쓰는 초 값을 환경 변수에서 읽는다 (stdout: 정수).
#   허용 범위는 정수 6~300 이다. 하한 6: herdr 는 `--timeout` 이 5초 이하이면
#   `agent_prompt_stalled` 대신 `timeout` 을 낸다. 상한 300: herdr 의 최대값이다.
#   범위 밖·정수 아님이면 stderr 에 한 줄 경고를 내고 기본값을 쓴다. 변수 미설정은 경고 없이 기본값이다.
#   <min> <max> 를 주면 그 범위로 판정한다(예: busy 재시도 창은 0~120 — 0 은 재시도 안 함).
_session_launch_timeout_secs() {  # <env-name> <default> [<min> <max>]
  local name="$1" def="$2" lo="${3:-6}" hi="${4:-300}" val
  val="${!name-}"
  if [[ -z "${!name+x}" ]]; then
    printf '%s\n' "$def"; return 0
  fi
  if [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val >= lo && 10#$val <= hi )); then
    printf '%s\n' "$((10#$val))"; return 0
  fi
  printf '대기 설정(%s=%s)이 허용 범위(%s~%s초)를 벗어나 기본값 %s초를 씁니다.\n' "$name" "$val" "$lo" "$hi" "$def" >&2
  printf '%s\n' "$def"
}

# 내부 헬퍼: `agent prompt` 성공 응답에서 `result.agent.agent_status` 문자열을 읽는다 (stdout).
#   읽지 못하면(빈 출력·잘린 JSON·다른 위치·타입 이상·python3 부재) 빈 값이다.
_session_launch_agent_status() {  # <json-file>
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I - "$1" <<'PYEOF2'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    s = d["result"]["agent"]["agent_status"]
    if isinstance(s, str):
        print(s)
except Exception:
    pass
PYEOF2
}

# 내부 헬퍼: hc 명령을 상한 안에서 부르고 응답 JSON 을 $2 파일에 둡니다.
#   hc 는 성공 응답을 stdout, 구조화 오류(`{"error":{"kind":..}}`)를 stderr 로 냅니다(2026-11-03 실측).
#   stdout 이 비었으면 stderr 를 응답으로 옮겨, 호출부가 한 파일에서 `error.kind` 를 읽게 합니다.
_session_launch_hc_call() {  # <timeout-secs> <outfile> <hc args...>
  local timeout_secs="$1" outfile="$2" errfile rc; shift 2
  errfile="$(mktemp)" || errfile=""
  RD_SL_ERRFILE="${errfile:-/dev/null}" _session_launch_run_with_timeout "$timeout_secs" "$outfile" hc "$@"
  rc=$?
  if [[ -n "$errfile" ]]; then
    [[ -s "$outfile" ]] || cat "$errfile" > "$outfile"
    rm -f "$errfile"
  fi
  return "$rc"
}

# 내부 헬퍼: `hc get <name> --json` 을 RD_LAUNCH_TIMEOUT 상한으로 부릅니다 (응답 → $2 파일).
#   rc 는 `hc get` 의 종료 코드이고 시간 초과는 124 입니다. 없는 이름은 rc=3 에 `error.kind=not_found` 입니다.
_session_launch_hc_get() {  # <name> <outfile>
  _session_launch_hc_call "${RD_LAUNCH_TIMEOUT:-5}" "$2" get "$1" --json
}

# 내부 헬퍼: hc 응답 JSON 에서 점 경로 값 여러 개를 python3 한 번으로 읽습니다 (stdout, 경로마다 한 줄).
#   예: `state`, `status.state`, `turn`, `error.kind`. python3 기동이 부하 시 1회 0.7초라 응답 하나에 한 번만 띄웁니다.
#   `labels.<키>` 는 키에 점이 있으므로(`herdr.space`) `labels` 아래 나머지 전체를 한 키로 읽습니다.
#   null·객체·읽기 실패(빈 출력·깨진 JSON)·줄바꿈이 든 값은 빈 줄입니다. 줄 위치는 경로 순서 그대로입니다.
#   python3 가 없으면 아무것도 내지 않습니다. 호출부는 `_session_launch_hc_read` 로 받아 모든 변수를 빈 값으로 둡니다.
_session_launch_hc_fields() {  # <json-file> <path>...
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I - "$@" <<'PYEOF3'
import json, sys
paths = sys.argv[2:]
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        root = json.load(f)
except Exception:
    root = None
for p in paths:
    v = ""
    try:
        d = root
        keys = ["labels", p[len("labels."):]] if p.startswith("labels.") else p.split(".")
        for k in keys:
            d = d[k]
        if isinstance(d, bool):
            v = "true" if d else "false"
        elif isinstance(d, (str, int)):
            v = str(d)
    except Exception:
        pass
    if "\n" in v or "\r" in v:
        v = ""
    print(v)
PYEOF3
}

# 내부 헬퍼: 경로 하나만 읽습니다 (stdout). 이 파일의 호출부는 쓰지 않습니다 — 동시에 진행하는 다른 작업이
#   옛 이름으로 부르는 코드를 병합해도 깨지지 않게 남깁니다. 값을 둘 이상 읽으면 `_session_launch_hc_read` 를 씁니다.
_session_launch_hc_field() {  # <json-file> <path>
  _session_launch_hc_fields "$1" "$2"
}

# 내부 헬퍼: `_session_launch_hc_fields` 결과를 변수들에 차례로 담습니다. 못 읽은 변수는 빈 값입니다.
#   사용: `_session_launch_hc_read <json-file> state turn status.state -- st tu ss`
_session_launch_hc_read() {  # <json-file> <path>... -- <var>...
  local _f="$1"; shift
  local -a _paths=() _vals=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do _paths+=("$1"); shift; done
  shift || true
  local _line
  while IFS= read -r _line; do _vals+=("$_line"); done < <(_session_launch_hc_fields "$_f" "${_paths[@]}")
  local _i=0 _v
  for _v in "$@"; do
    printf -v "$_v" '%s' "${_vals[$_i]-}"
    _i=$((_i + 1))
  done
}

# 내부 헬퍼: herdr JSON 응답에서 pane id 를 파싱한다(추측하지 않는다).
#   실측 스키마(orchestrator 가 이 머신에서 확인): `.result.pane.pane_id`.
_session_launch_parse_pane_id() {  # <json-file>
  grep -o '"pane_id":"[^"]*"' "$1" 2>/dev/null | head -1 | sed -E 's/.*"pane_id":"([^"]*)".*/\1/'
}

# 내부 헬퍼: herdr JSON 응답에서 tab id 를 파싱한다(추측하지 않는다).
#   실측 스키마: `.result.tab.tab_id`. root_pane 쪽에도 같은 값이 실리지만, tab 의
#   정체는 tab 객체에서 읽는다.
_session_launch_parse_tab_id() {  # <json-file>
  grep -o '"tab_id":"[^"]*"' "$1" 2>/dev/null | head -1 | sed -E 's/.*"tab_id":"([^"]*)".*/\1/'
}

# 내부 헬퍼: herdr JSON 응답 파일을 **완전한 JSON 파싱**으로 분류한다 (stdout 한 줄).
#   error<TAB><code>   최상위 `error` 객체의 비어 있지 않은 문자열 `code`
#   agent<TAB><cwd>    `result.agent` 객체와 문자열 `cwd` (`cwd` 키가 없으면 cwd 는 빈 값)
#   invalid            그 밖 전부 — 빈 파일·잘린 JSON·잘못된 위치/타입·error 와 result 동시 존재
#                      그리고 python3 부재. 호출부는 invalid 를 **확정 근거로 쓰지 않는다**.
#   문자열 패턴 검사는 잘린 JSON 이나 다른 위치의 키를 정상으로 읽는다(spec D2).
_session_launch_json_classify() {  # <file>
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'invalid\n'; return 0
  fi
  python3 -I - "$1" <<'PYEOF'
import json, sys
def out(s):
    print(s)
    sys.exit(0)
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    out("invalid")
if not isinstance(d, dict) or ("error" in d and "result" in d):
    out("invalid")
e = d.get("error")
if isinstance(e, dict):
    c = e.get("code")
    out("error\t" + c if isinstance(c, str) and c else "invalid")
r = d.get("result")
if isinstance(r, dict) and isinstance(r.get("agent"), dict):
    a = r["agent"]
    if "cwd" not in a:
        out("agent\t")
    c = a["cwd"]
    out("agent\t" + c if isinstance(c, str) and c else "invalid")
out("invalid")
PYEOF
}

# 내부 헬퍼: agent start 시도 전에 만들어진 tab 을 최선을 다해 정리한다(결과는 보지 않는다).
#   agent 가 아직 붙지 않은 tab 이므로 남겨두면 빈 셸 tab 하나가 목록에 남는다.
_session_launch_close_tab_best_effort() {  # <tab-id>
  local of; of="$(mktemp)" || return 0
  _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$of" herdr tab close "$1" || true
  rm -f "$of"
}

# 내부 헬퍼: herdr 에이전트 이름으로 쓸 수 있게 slug 를 줄인다.
#   herdr 제약(실측): 소문자로 시작, `[a-z0-9-_]`, **1~32자**. 그런데 `normalize_slug`
#   는 최대 **60자**를 허용하므로 33자 이상 slug 는 `agent start` 가 거부한다 — 그대로
#   두면 정상 착수가 기동 실패로 떨어진다. 이름만 줄이고 **tab label 에는 전체 slug 를
#   싣는다**(label 에는 길이·문자 제약이 없다) — 목록에서의 식별성은 label 이 지킨다.
_session_launch_agent_name() {  # <slug>
  local s="$1"
  if [[ "${#s}" -le 32 ]]; then printf '%s\n' "$s"; return 0; fi
  s="${s:0:32}"
  printf '%s\n' "${s%-}"   # 절단면이 `-` 로 끝나면 떼어 낸다(보기 좋게)
}

# 공개 이름 함수: 다른 스크립트(재개 후보·promote 출력)가 herdr 에이전트 이름을 같은 규칙으로 계산한다.
#   이름은 저장하지 않고 slug 에서 결정적으로 계산한다.
session_agent_name() {  # <slug> → stdout: herdr 에이전트 이름
  _session_launch_agent_name "$1"
}

# 인계 문구 (F4) — 세션에 넘길 작업 지시입니다. **기동 시점과 승인 이후 재개 시점이
# 같은 문구를 쓰도록** 별도 함수로 둡니다. 여기서만 문구를 만들고, 두 경로가 이 함수를
# 부릅니다 (문구가 갈리면 "같은 작업을 이어받는다" 는 계약이 경로마다 달라집니다).
#   4번째 인자(인계 파일 경로)가 있으면 끝 줄 앞에 확정 결정 줄을 더합니다. 없으면 현행 출력입니다.
session_handoff_text() {  # <slug> <req> <worktree-path> [<handoff-file>] [<autopilot>]
  local _decision="" _autopilot=""
  if [[ -n "${4:-}" ]]; then
    printf -v _decision '확정 결정: %s — 먼저 읽고 시작하십시오. 그 파일의 %s 밖의 행동은 하지 않습니다.\n' "$4" "'해도 되는 행동'"
  fi
  if [[ "${5:-}" == "autopilot" ]]; then
    _autopilot="autopilot: 이 작업은 autopilot 으로 진행합니다. 작업 선택(§1)은 호출 세션이 마쳤습니다. rd-workflow/claude_skills/autopilot/SKILL.md 의 '## Autonomy Override' 와 '## Execution Rules' §2 이후를 읽고 따르십시오. 멈출 때(blocked·awaiting-user·사용자 인계)와 archive.sh 호출 직전에 bash rd-workflow/scripts/autopilot_driver.sh end 를 실행하십시오."$'\n'
  fi
  printf '작업(FR): %s\nREQUEST: %s\nWorktree: %s\n%s%s이 작업을 이어서 진행해 주십시오.' "$1" "$2" "$3" "$_decision" "$_autopilot"
}

# autopilot 표식 확인 — autopilot_driver.sh check 가 0 이면 `autopilot`, 아니면 빈 값.
#   promote --autopilot 이 기동 전에 둔 표식을 근거로 하므로 resolve-launch 재전달도 같은 결과를 얻는다.
session_handoff_autopilot() {  # <worktree-path>
  local drv="${1:-}/rd-workflow/scripts/autopilot_driver.sh"
  [[ -f "$drv" ]] || return 0
  if bash "$drv" check >/dev/null 2>&1; then printf 'autopilot\n'; fi
  return 0
}

# 인계 파일(확정 결정 기록)의 경로 — 유도 로직은 여기 한 곳에만 둡니다.
session_handoff_file_path() {  # <worktree-path>
  [[ -n "${1:-}" ]] || return 1
  printf '%s/rd-workflow-workspace/.lifecycle/handoff.md\n' "$1"
}

# 인계 전달 (F4) — `herdr agent prompt` 로 위 문구를 세션에 밀어 넣고 **처리 시작을 판정**합니다.
#   `--wait --until working --until blocked` 로 입력 뒤 작업 시작(또는 확인 대기)을 herdr 가
#   관측하게 합니다. `--until` 을 빼면 턴이 끝날 때까지 기다리므로 두 상태를 적습니다.
#   return 0 전달 성공(작업 시작 또는 확인 대기 관측)
#          1 보내지 않았음이 확실함(herdr 사용 불가·임시 파일 실패·`agent_blocked`)
#          2 제출 여부를 모름(stalled·timeout·그 밖의 오류) — 문구가 이미 입력됐을 수 있다.
#   호출부는 1 과 2 를 구분해 안내한다. 2 에서 「직접 지시하라」고 하면 같은 지시가 두 번 들어간다.
#   **생존 확인과 전달 성공은 다른 사실입니다** — 호출부가 둘을 구분해 보고하도록
#   이 함수는 launch 상태를 만들지 않고 전달 여부만 돌려줍니다. 결과별 안내(stderr)는
#   이 함수가 냅니다(기동 경로와 resolve-launch 경로가 같은 안내를 얻도록).
#   탭을 닫지 않고, `agent prompt` 는 한 번만 부릅니다(재제출은 문구를 두 번 넣을 수 있다).
session_handoff_deliver() {  # <slug> <worktree-path> <request-path> [<backend>]
  local slug="$1" wt="$2" req="$3" backend="${4:-herdr}"
  if ! session_backend_usable "$backend"; then
    return 1
  fi
  if [[ "$backend" == hc ]]; then
    _session_handoff_deliver_hc "$slug"
    return $?
  fi
  local agent_name handoff outfile errfile rc psecs
  agent_name="$(_session_launch_agent_name "$slug")"
  local hfile=""
  hfile="$(session_handoff_file_path "$wt")" || hfile=""
  [[ -n "$hfile" && -f "$hfile" ]] || hfile=""
  handoff="$(session_handoff_text "$slug" "$req" "$wt" "$hfile" "$(session_handoff_autopilot "$wt")")"
  outfile="$(mktemp)" || return 1
  errfile="$(mktemp)" || { rm -f "$outfile"; return 1; }
  psecs="$(_session_launch_timeout_secs RD_LAUNCH_PROMPT_TIMEOUT 15)"
  printf '시작 프롬프트 처리 확인: %s — 작업 시작을 최대 %s초 기다립니다.\n' "$slug" "$((psecs + 5))" >&2
  RD_SL_ERRFILE="$errfile" _session_launch_run_with_timeout "$((psecs + 5))" "$outfile" \
    herdr agent prompt "$agent_name" "$handoff" \
      --wait --until working --until blocked --timeout "$((psecs * 1000))"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    local status
    status="$(_session_launch_agent_status "$outfile")"
    rm -f "$outfile" "$errfile"
    case "$status" in
      working) ;;
      blocked)
        printf '시작 프롬프트는 제출됐고 세션이 확인을 기다립니다 — herdr 화면에서 승인해 주십시오.\n' >&2 ;;
      *)
        printf '시작 프롬프트는 제출됐지만 처리 상태를 읽지 못했습니다 — 세션 화면에서 승인 대기 여부를 확인해 주십시오.\n' >&2 ;;
    esac
    return 0
  fi
  local cls code="" reason
  cls="$(_session_launch_json_classify "$errfile")"
  rm -f "$outfile" "$errfile"
  [[ "$cls" == error$'\t'* ]] && code="${cls#error$'\t'}"
  if [[ "$code" == "agent_blocked" ]]; then
    printf '세션이 확인을 기다리고 있어 시작 프롬프트를 보내지 않았습니다 — 승인한 뒤 전달: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$slug" >&2
    return 1
  fi
  if [[ "$rc" -eq 124 ]]; then reason="응답 시간 초과"
  elif [[ -n "$code" ]]; then reason="$code"
  else reason="응답 형식 이상"
  fi
  printf '시작 프롬프트가 처리됐는지 확인하지 못했습니다(%s) — herdr 화면을 먼저 확인하십시오.\n' "$reason" >&2
  printf '입력창에 문구가 남아 있으면 Enter 를 누르고, 비어 있고 작업도 없으면 전달: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$slug" >&2
  return 2
}

# hc 갈래의 인계 판정 — 인계문은 기동 인자로 이미 들어갔으므로(M2) **보내지 않고** 처리 여부만
#   `hc get` 으로 확인합니다. `hc send` 는 쓰지 않습니다(같은 지시가 두 번 들어가는 것을 막기 위함).
#   return 0 처리 시작(`turn` ≥ 1 또는 `status.state` 가 working·blocked)
#          2 처리되지 않았거나 확인하지 못함 — 호출부가 `unknown` 으로 두고 resolve-launch 로 다시 확인합니다.
_session_handoff_deliver_hc() {  # <slug>
  local slug="$1" outfile rc state turn status name
  name="$(_session_launch_agent_name "$slug")"
  outfile="$(mktemp)" || return 2
  _session_launch_hc_get "$name" "$outfile"
  rc=$?
  _session_launch_hc_read "$outfile" state turn status.state -- state turn status
  rm -f "$outfile"
  if [[ "$rc" -ne 0 || -z "$state" ]]; then
    printf '처리 여부를 확인하지 못했습니다 — 확인: hc get %s / 화면: hc attach %s\n' "$name" "$name" >&2
    return 2
  fi
  if [[ "$status" == blocked ]]; then
    # tab 이름 붙이기가 실패했을 수 있으므로 tab 이름과 함께 언제나 찾을 수 있는 hc attach 를 안내합니다.
    printf '세션이 확인을 기다립니다 — 앱 화면의 %s tab(보이지 않으면 hc attach %s)에서 승인해 주십시오.\n' "$slug" "$name" >&2
    return 0
  fi
  if [[ "$status" == working ]] || { [[ "$turn" =~ ^[0-9]+$ ]] && (( 10#$turn >= 1 )); }; then
    return 0
  fi
  printf '첫 메시지가 아직 처리되지 않았습니다. 앱 화면의 %s tab(보이지 않으면 hc attach %s)에서 신뢰 확인 등을 승인하면 claude 가 인계문을 스스로 처리합니다. 문구를 붙여 넣지 마십시오. 승인 뒤 다시 resolve-launch 를 실행하십시오.\n' "$slug" "$name" >&2
  return 2
}

# 인계에 쓸 REQUEST 경로를 정한다 (F4). 색인에는 `req` 를 따로 두지 않으므로,
# worktree 경로에서 규칙적으로 유도합니다: `<worktree-path>/REQUEST.md`.
#   근거 — promote.sh 가 기동 시 넘기는 값이 정확히 이 경로이고(`REQUEST_HANDOFF_PATH`),
#   worktree 안의 REQUEST.md 는 baseline 이든 작성된 것이든 항상 그 자리에 있습니다.
#   worktree 경로를 모르면 인계 문구를 만들 수 없으므로 빈 값을 돌려줍니다.
session_handoff_request_path() {  # <worktree-path>
  [[ -n "${1:-}" ]] || return 1
  printf '%s/REQUEST.md\n' "$1"
}

session_launch() {  # <worktree-path> <slug> <request-path> [<model>] [<backend>] → stdout: launch 상태
  local wt="$1" slug="$2" req="$3"
  local timeout="${RD_LAUNCH_TIMEOUT:-5}"
  local model="${4-}"
  if [[ $# -lt 4 ]]; then
    IFS=$'\t' read -r _ model < <(session_launch_model "$wt")
  fi

  # 테스트 seam — 예약(launch-token)·완료-기록 로직을 실제 herdr 없이 태우기 위함이다.
  # 프로덕션 경로에는 영향이 없다(변수가 없으면 이 블록은 그냥 지나간다). 실행 파일
  # 하나만 받고, 그 stdout 을 그대로 이 함수의 반환값으로 쓴다 — 호출 계약(<wt> <slug>
  # <req> 인자, stdout 한 줄)은 실제 경로와 동일하다.
  #
  # **무신호로 대역을 타지 않는다** (2026-09 final diff review D1). 이 변수가 상속된
  # 환경(한 번 export 하고 같은 셸에서 계속 작업·CI·자식 세션 env 전파)에서는 기동이
  # 조용히 대역으로 바뀌는데, promote 는 그 사실을 모른 채 "세션 기동 결과 — ok" 까지
  # 낸다 — 사용자에게 실제 피해가 갔던 herdr 사고와 같은 종류(조용히 다른 일이
  # 일어남)다. stderr 에 한 줄 낸다.
  #
  # **스텁의 종료 코드도 버리지 않는다.** `"$RD_LAUNCH_STUB" ...; return 0` 형태로
  # 곧장 반환하면 스텁이 실패해 stdout 이 비어도 `LAUNCH_RESULT=""` 가 되어
  # 4상태(ok/failed/none/unknown) 계약 밖의 빈 값이 색인에 그대로 기록된다. 스텁
  # 실패·빈 출력은 `failed` 로 귀결시킨다.
  if [[ -n "${RD_LAUNCH_STUB:-}" ]]; then
    printf '기동 대역(RD_LAUNCH_STUB)을 사용합니다: %s\n' "$RD_LAUNCH_STUB" >&2
    local _stub_out="" _stub_rc=0
    if _stub_out="$("$RD_LAUNCH_STUB" "$wt" "$slug" "$req")"; then
      _stub_rc=0
    else
      _stub_rc=$?
    fi
    if [[ "$_stub_rc" -ne 0 || -z "$_stub_out" ]]; then
      printf '기동 대역이 실패했거나 빈 값을 반환했습니다(rc=%s) — failed 로 처리합니다.\n' "$_stub_rc" >&2
      printf 'failed\n'; return 0
    fi
    printf '%s\n' "$_stub_out"
    return 0
  fi

  if [[ -n "${RD_CHILD_SESSION:-}" ]]; then
    printf '세션 기동을 건너뜁니다 — 이미 자식 세션입니다(깊이 1 제한).\n' >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'none\n'; return 0
  fi
  # 5번째 인자가 있으면 판정을 다시 하지 않고 그 백엔드를 씁니다(spec D2) — promote 가 색인에
  # 기록한 값과 실제 기동 대상이 어긋나지 않게 하기 위함입니다.
  local backend="${5-}"
  [[ -n "$backend" ]] || backend="$(session_launch_backend)"
  if ! session_backend_usable "$backend"; then
    printf '자동 기동을 하지 않았습니다. 아래 명령으로 시작하십시오.\n' >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'none\n'; return 0
  fi
  if [[ "$backend" == hc ]]; then
    _session_launch_hc "$wt" "$slug" "$req" "$model"
    return 0
  fi
  # herdr 경로: tab create(cwd·env·label 을 인자로 직접 전달) → agent start → agent prompt.
  #   id 는 반드시 JSON 응답에서 파싱한다(추측 금지). --no-focus 로 사용자 focus 를 뺏지 않는다.
  #   어느 단계든 실패하면 failed, 판정 불가하면 unknown 을 낸다. worktree 는 지우지 않는다.
  #
  # **pane 분할이 아니라 tab 을 만든다** (2026-09-16 사용자 확인). 두 가지 이유다.
  #   ① 화면: pane 분할은 동시 진행 작업이 늘수록 한 화면을 N 등분한다. FR 작업은 각자
  #      길게 독립적으로 도는 것이라 나란히 볼 이유가 적다.
  #   ② **식별**: herdr 의 agents 패널은 행마다 그 에이전트가 있는 **tab 의 label** 을
  #      보여준다(실측). pane 분할은 새 tab 을 만들지 않으므로 여러 작업이 전부 같은
  #      label 한 줄에 겹쳐 어느 행이 어느 작업인지 읽을 수 없다. tab 을 만들면 작업마다
  #      별도 행이 생기고 `--label` 에 실은 slug 가 그 자리에 그대로 보인다.
  # workspace 는 현재 세션의 것을 명시한다(`HERDR_WORKSPACE_ID`) — 같은 프로젝트의 작업을
  # 그 프로젝트 workspace 안에 모아 두기 위해서다(workspace 는 프로젝트 단위로 쓰인다).
  #
  # cwd·환경 전달: 새 셸에 `send-text` 로 타이핑해 넣는 방식은 그 셸이 입력을 받을 준비가
  # 됐다는 보장이 없어 경합이 생긴다(agent start 가 곧바로 이어지면 cd·export 가 씹힐 수
  # 있다). `tab create` 가 `--cwd`·`--env` 를 직접 받으므로 인자로 넘겨 경합을 없앤다.
  local outfile rc pane_id tab_id agent_name
  agent_name="$(_session_launch_agent_name "$slug")"
  # mktemp 실패는 4상태 계약(ok/failed/none/unknown) 안에서 끝낸다 — 함수 계약이
  # stdout 한 줄이므로 exit 로 프로세스를 죽이면 호출부가 빈 값을 색인에 기록한다.
  outfile="$(mktemp)" || {
    printf '자동 기동에 실패했습니다(%s). 아래 명령으로 시작하십시오.\n' "임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  }
  _session_launch_run_with_timeout "$timeout" "$outfile" \
    herdr tab create --workspace "${HERDR_WORKSPACE_ID:-}" --no-focus \
      --cwd "$wt" --label "$slug" --env "RD_CHILD_SESSION=1"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$outfile"
    printf '자동 기동에 실패했습니다(tab create, rc=%s). 아래 명령으로 시작하십시오.\n' "$rc" >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  fi
  pane_id="$(_session_launch_parse_pane_id "$outfile")"
  tab_id="$(_session_launch_parse_tab_id "$outfile")"
  rm -f "$outfile"
  # 호출부(promote)가 탭 id 를 색인에 남기도록 메타 파일에 쓴다. stdout 계약은 그대로다.
  if [[ -n "${RD_LAUNCH_META_FILE:-}" && -n "$tab_id" ]]; then
    printf 'launch-tab=%s\n' "$tab_id" > "$RD_LAUNCH_META_FILE" 2>/dev/null || true
  fi
  if [[ -z "$pane_id" ]]; then
    # tab create 는 성공(rc=0)했지만 pane_id 를 응답에서 찾지 못한 경우다. agent 를 붙일
    # 대상을 알 수 없다. tab_id 를 건졌으면 그 tab 은 닫아 빈 tab 을 남기지 않는다.
    [[ -n "$tab_id" ]] && _session_launch_close_tab_best_effort "$tab_id"
    printf '자동 기동에 실패했습니다(pane id 를 응답에서 찾지 못했습니다). 아래 명령으로 시작하십시오.\n' >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  fi

  # agent start 는 에이전트가 입력을 받을 준비가 될 때까지 herdr 가 막았다가 응답한다. 그 대기를
  # herdr `--timeout` 에 맡기고 스크립트 상한은 5초 더 길게 둔다(짧은 호출 상한 RD_LAUNCH_TIMEOUT
  # 에 묶으면 claude 준비가 늦을 때 클라이언트를 응답 전에 죽인다). `--timeout` 은 `--` 앞이다.
  local ssecs
  ssecs="$(_session_launch_timeout_secs RD_LAUNCH_START_TIMEOUT 60)"
  printf '세션 기동 대기: %s — 세션이 입력을 받을 준비가 될 때까지 최대 %s초 기다립니다.\n' "$slug" "$((ssecs + 5))" >&2
  # **`agent_pane_busy` 는 짧게 다시 부른다** (2026-11-06 실측). 새 tab 의 셸이 시작 스크립트의
  # 자식 프로세스(path_helper·fnm·ls 등)를 포그라운드로 돌리는 순간에 부르면 herdr 가 이 코드로
  # 거부한다. 거부는 아무것도 입력하지 않고 이름도 점유하지 않으므로 같은 pane·이름으로 다시 부른다.
  #   창(bsecs)은 「새 시도를 시작해도 되는 시간」 이다. 0.5초 쉬기 전과 뒤에 검사한다. 이미 시작한
  #   시도는 창과 관계없이 기존 상한까지 기다리고, 그 결과는 아래 기존 분기가 처리한다(결과 우선).
  #   rc=124 는 busy 본문이 있어도 「결과를 모름」 이라 재시도하지 않는다.
  local bsecs bstart bdeadline nretry=0 bnotice=""
  bsecs="$(_session_launch_timeout_secs RD_LAUNCH_BUSY_RETRY_SECS 30 0 120)"
  bstart=$SECONDS; bdeadline=$((SECONDS + bsecs))
  local errfile="" start_body="" _cls_out="" _cls_err=""
  while :; do
    outfile="$(mktemp)" || {
      # tab 은 이미 만들어졌고 agent 는 아직 안 붙었다 — 위 갈래와 같은 정리를 한다.
      _session_launch_close_tab_best_effort "$tab_id"
      printf '자동 기동에 실패했습니다(%s). 아래 명령으로 시작하십시오.\n' "임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2
      printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
      printf 'failed\n'; return 0
    }
    errfile="$(mktemp)" || errfile=""
    if [[ -n "$model" ]]; then
      RD_SL_ERRFILE="${errfile:-/dev/null}" _session_launch_run_with_timeout "$((ssecs + 5))" "$outfile" \
        herdr agent start "$agent_name" --kind claude --pane "$pane_id" --timeout "$((ssecs * 1000))" -- --model "$model"
    else
      RD_SL_ERRFILE="${errfile:-/dev/null}" _session_launch_run_with_timeout "$((ssecs + 5))" "$outfile" \
        herdr agent start "$agent_name" --kind claude --pane "$pane_id" --timeout "$((ssecs * 1000))"
    fi
    rc=$?
    # 오류 JSON 은 stderr 로 나온다(2026-10-29 실측) — stdout 파일만 읽으면 start_body 가 늘 비어
    # `agent_not_ready` 분기가 타지 않는다. 판정은 두 파일을 각각 분류해 하고, start_body 는
    # 진단 출력용으로 둘을 이어 붙인다.
    _cls_out="$(_session_launch_json_classify "$outfile")"
    _cls_err=""
    [[ -n "$errfile" ]] && _cls_err="$(_session_launch_json_classify "$errfile")"
    start_body="$(cat "$outfile" ${errfile:+"$errfile"} 2>/dev/null)"
    rm -f "$outfile" ${errfile:+"$errfile"}
    [[ $rc -ne 0 && $rc -ne 124 ]] || break
    [[ "$_cls_out" == $'error\tagent_pane_busy' || "$_cls_err" == $'error\tagent_pane_busy' ]] || break
    (( SECONDS < bdeadline )) || break
    if [[ -z "$bnotice" ]]; then
      printf 'agent start: 새 탭의 셸이 아직 준비 중입니다(agent_pane_busy) — 최대 %s초 동안 다시 시도합니다.\n' "$bsecs" >&2
      bnotice=1
    fi
    sleep 0.5
    (( SECONDS < bdeadline )) || break
    nretry=$((nretry + 1))
  done
  if [[ -n "$bnotice" ]]; then
    printf 'agent start: 셸이 아직 준비 중이라(agent_pane_busy) %s회 다시 시도했습니다(%s초).\n' "$nretry" "$((SECONDS - bstart))" >&2
  fi
  if [[ $rc -ne 0 ]]; then
    # 원인 확인용 계측 — 연속 기동 때 관측된 rc=1 은 응답이 버려져 원인을 알 수 없었다.
    printf 'agent start 응답(rc=%s): %s\n' "$rc" "$(printf '%s' "$start_body" | tr '\n' ' ' | cut -c1-500)" >&2
    # **`agent_not_ready` 는 실패가 아니다** (2026-09-16 실측). 새 worktree 는 늘 처음 여는
    # 경로라 claude 가 기동 직후 신뢰 확인 같은 다이얼로그를 띄우고 `blocked` 로 들어가는데,
    # 그때 `agent start` 가 이 코드로 rc≠0 을 낸다. **에이전트는 멀쩡히 떠 있다.** 이것을
    # failed 로 보고 tab 을 닫으면 사람이 승인하기도 전에 방금 뜬 세션을 죽인다 — 그리고
    # 이 다이얼로그는 예외가 아니라 정상 착수의 거의 매번이다. 승인은 사람이 하는 것이므로
    # 여기서는 손대지 않고 unknown 으로 넘겨 확인 방법만 알린다.
    if [[ "$_cls_out" == $'error\tagent_not_ready' || "$_cls_err" == $'error\tagent_not_ready' ]]; then
      printf '세션이 떴지만 시작 단계에서 확인을 기다리고 있습니다(blocked) — herdr 화면에서 승인해 주십시오.\n' >&2
      printf '승인 뒤 인계 전달: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$slug" >&2
      printf 'unknown\n'; return 0
    fi
    # **타임아웃(rc=124)은 실패의 증거가 아니다** (F3). 시작 요청은 이미 보냈고, 서버가
    # 에이전트를 만든 뒤 응답만 늦어도 같은 값이 나옵니다. 여기서 tab 을 닫으면 방금 뜬
    # 세션을 죽입니다 — 정리는 **시작되지 않았음이 확인된 오류**에만 합니다.
    if [[ $rc -eq 124 ]]; then
      printf '시작 요청 뒤 응답이 시간 안에 오지 않았습니다(agent start 타임아웃) — 세션이 살아 있을 수 있어 tab 을 닫지 않습니다.\n' >&2
      printf '확인·인계: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$slug" >&2
      printf 'unknown\n'; return 0
    fi
    # agent 가 붙지 못한 tab 은 빈 셸만 남으므로 최선을 다해 닫는다(worktree 는 건드리지 않는다).
    _session_launch_close_tab_best_effort "$tab_id"
    printf '자동 기동에 실패했습니다(agent start, rc=%s). 아래 명령으로 시작하십시오.\n' "$rc" >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  fi

  # 인계 전달 — 문구·호출 모두 재사용 헬퍼가 담당합니다(F4). 승인 뒤 재개 경로
  # (`task_resolve_launch`)가 같은 헬퍼를 씁니다.
  if ! session_handoff_deliver "$slug" "$wt" "$req"; then
    # agent start 는 이미 성공했다 — 세션이 살아 있을 수 있으므로 tab 을 닫지 않는다.
    printf '세션은 시작됐지만 인계 전달에 실패했습니다(agent prompt) — 세션이 살아 있을 수 있습니다.\n' >&2
    printf 'unknown\n'; return 0
  fi

  printf 'ok\n'; return 0
}

# 내부 헬퍼: `herdr-app ls`(인자 없이 JSON 출력) 에서 터미널 주소가 <address> 인 tab id 를 읽습니다 (stdout, 없으면 빈 값).
_session_launch_hc_tab_of() {  # <json-file> <address>
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I - "$1" "$2" <<'PYEOF4'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    for sp in d.get("spaces", []):
        for tab in sp.get("tabs", []):
            for t in tab.get("terminals", []):
                if t.get("terminal") == sys.argv[2]:
                    print(tab["id"])
                    sys.exit(0)
except Exception:
    pass
PYEOF4
}

# 내부 헬퍼: 기동한 터미널의 앱 tab 에 slug 이름을 붙입니다 (spec D3-5). 실패해도 기동 결과는 바꾸지 않습니다.
#   return 0 이름을 붙임 / 1 못 붙임 — 사유는 stdout 한 줄입니다.
_session_launch_hc_expose() {  # <address> <space> <slug>
  local address="$1" space="$2" slug="$3" lsout tab_id="" i rc
  [[ -n "$space" ]] || { printf 'space 를 읽지 못함\n'; return 1; }
  command -v herdr-app >/dev/null 2>&1 || { printf 'herdr-app 없음\n'; return 1; }
  lsout="$(mktemp)" || { printf '임시 파일 생성 실패\n'; return 1; }
  for i in 1 2; do
    _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$lsout" herdr-app ls
    tab_id="$(_session_launch_hc_tab_of "$lsout" "$address")"
    [[ -n "$tab_id" ]] && break
    [[ "$i" -eq 1 ]] && sleep 1
  done
  rm -f "$lsout"
  [[ -n "$tab_id" ]] || { printf 'tab 을 찾지 못함\n'; return 1; }
  lsout="$(mktemp)" || { printf '임시 파일 생성 실패\n'; return 1; }
  _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$lsout" \
    herdr-app do tab.rename --id "$tab_id" --name "$slug"
  rc=$?
  rm -f "$lsout"
  [[ "$rc" -eq 0 ]] || { printf 'tab.rename 실패(rc=%s)\n' "$rc"; return 1; }
  return 0
}

# hc 갈래의 기동 (spec D3) — 결과는 stdout 한 줄(ok|failed|unknown)입니다.
_session_launch_hc() {  # <worktree-path> <slug> <request-path> <model>
  local wt="$1" slug="$2" req="$3" model="${4-}"
  local agent_name outfile rc space address kind reason hfile handoff
  agent_name="$(_session_launch_agent_name "$slug")"
  outfile="$(mktemp)" || {
    printf '자동 기동에 실패했습니다(%s). 아래 명령으로 시작하십시오.\n' "임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  }
  # 1) tab 을 만들 space — 현재 세션의 라벨(M11). 못 읽으면 라벨 없이 기동합니다.
  _session_launch_hc_get "$HC_TERMINAL_ID" "$outfile"
  _session_launch_hc_read "$outfile" labels.herdr.space -- space
  # 2) 기동 — 인계문은 claude 의 첫 인자로 넣습니다(M2). env 접두로 깊이 제한 변수를 넘깁니다(M10).
  hfile="$(session_handoff_file_path "$wt")" || hfile=""
  [[ -n "$hfile" && -f "$hfile" ]] || hfile=""
  handoff="$(session_handoff_text "$slug" "$req" "$wt" "$hfile" "$(session_handoff_autopilot "$wt")")"
  local -a run_args=(run --bg --json --no-notify --name "$agent_name" --cwd "$wt" --outlive-parent)
  [[ -n "$space" ]] && run_args+=(--label "herdr.space=$space")
  run_args+=(env RD_CHILD_SESSION=1 claude)
  [[ -n "$model" ]] && run_args+=(--model "$model")
  run_args+=("$handoff")
  _session_launch_hc_call "${RD_LAUNCH_TIMEOUT:-5}" "$outfile" "${run_args[@]}"
  rc=$?
  _session_launch_hc_read "$outfile" address error.kind -- address kind
  rm -f "$outfile"
  if [[ -z "$kind" && ( "$rc" -ne 0 || -z "$address" ) ]]; then
    # 터미널이 만들어졌을 수 있습니다(시간 초과·rc≠0 인데 address 가 있음·해석 불가) — 실패로 단정하지 않습니다.
    printf '세션 기동 응답을 확인하지 못했습니다(hc run, rc=%s) — 세션이 떠 있을 수 있습니다. 확인: hc attach %s\n' "$rc" "$agent_name" >&2
    printf '확인·인계: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$slug" >&2
    printf 'unknown\n'; return 0
  fi
  if [[ "$kind" == name_taken ]]; then
    # 같은 이름의 live 터미널이 이미 있습니다 — 이 작업의 세션일 수 있으므로 실패로 단정하지 않습니다.
    printf "같은 이름의 세션이 이미 떠 있습니다 — hc attach %s 로 확인하십시오. 새 세션을 열기 전에 확인이 필요합니다.\n" "$agent_name" >&2
    printf '확인·인계: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$slug" >&2
    printf 'unknown\n'; return 0
  fi
  if [[ -n "$kind" ]]; then
    # 터미널이 만들어지지 않았음이 확실한 구조화된 오류뿐입니다.
    printf '자동 기동에 실패했습니다(hc run: %s). 아래 명령으로 시작하십시오.\n' "$kind" >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  fi
  # 3) tab 이름 — 신뢰 다이얼로그처럼 사람이 승인해야 하는 경우에도 slug tab 을 바로 찾게 대기보다 먼저 합니다.
  local tab_ref="$slug tab"
  if reason="$(_session_launch_hc_expose "$address" "$space" "$slug")"; then :; else
    tab_ref="hc attach $agent_name"
    printf "세션은 떴지만 앱 tab 이름을 붙이지 못했습니다(%s) — hc ls 의 '%s' 로 찾거나 hc attach %s 으로 여십시오.\n" "$reason" "$agent_name" "$agent_name" >&2
  fi
  # 4) 처리 확인 대기 — 1초 간격, 상한 RD_LAUNCH_START_TIMEOUT.
  #    안내한 상한을 지키도록 마감 시각을 두고, 조회 한 번의 상한과 sleep 도 남은 시간으로 자릅니다.
  local ssecs state turn status deadline left per
  ssecs="$(_session_launch_timeout_secs RD_LAUNCH_START_TIMEOUT 60)"
  deadline=$(( SECONDS + ssecs ))
  printf '세션 기동 대기: %s — 첫 메시지 처리를 최대 %s초 기다립니다.\n' "$slug" "$ssecs" >&2
  while :; do
    left=$(( deadline - SECONDS ))
    (( left > 0 )) || break
    per="${RD_LAUNCH_TIMEOUT:-5}"
    [[ "$per" =~ ^[0-9]+$ ]] || per=5
    (( per > left )) && per="$left"
    outfile="$(mktemp)" || break
    _session_launch_hc_call "$per" "$outfile" get "$agent_name" --json
    rc=$?
    _session_launch_hc_read "$outfile" state turn status.state -- state turn status
    rm -f "$outfile"
    if [[ "$rc" -eq 0 && "$state" == finished ]]; then
      printf '세션이 바로 종료됐습니다 — 마지막 출력: hc read %s. 아래 명령으로 시작하십시오.\n' "$agent_name" >&2
      printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
      printf 'failed\n'; return 0
    fi
    if [[ "$rc" -eq 0 && "$state" == live ]]; then
      if [[ "$status" == blocked ]]; then
        printf '세션이 확인을 기다립니다 — 앱 화면의 %s 에서 승인해 주십시오.\n' "$tab_ref" >&2
        printf 'ok\n'; return 0
      fi
      if [[ "$status" == working ]] || { [[ "$turn" =~ ^[0-9]+$ ]] && (( 10#$turn >= 1 )); }; then
        printf 'ok\n'; return 0
      fi
    fi
    (( deadline - SECONDS > 1 )) || break
    sleep 1
  done
  printf '첫 메시지 처리를 %s초 안에 확인하지 못했습니다 — 신뢰 확인 다이얼로그가 떠 있을 수 있습니다.\n' "$ssecs" >&2
  printf '앱 화면의 %s 에서 승인하면 claude 가 인계문을 스스로 처리합니다. 승인 뒤: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$tab_ref" "$slug" >&2
  printf 'unknown\n'; return 0
}

# hc 갈래의 생존 조회 (spec D4). 생존·종료는 `state` 로만 가르고 `status.state` 는 쓰지 않습니다.
_session_probe_hc() {  # <slug> <worktree-path>
  local slug="$1" wt="${2:-}" outfile rc state kind cwd
  outfile="$(mktemp)" || { printf 'unknown\n'; return 0; }
  _session_launch_hc_get "$(_session_launch_agent_name "$slug")" "$outfile"
  rc=$?
  _session_launch_hc_read "$outfile" state error.kind cwd -- state kind cwd
  rm -f "$outfile"
  # dead 는 구조화된 not_found 이거나 끝난·다른 작업의 터미널일 때뿐입니다. 시간 초과·해석 실패는 unknown 입니다.
  if [[ "$kind" == not_found ]]; then printf 'dead\n'; return 0; fi
  if [[ "$rc" -ne 0 || -z "$state" ]]; then printf 'unknown\n'; return 0; fi
  if [[ -n "$wt" ]]; then
    [[ -n "$cwd" ]] || { printf 'unknown\n'; return 0; }
    [[ "$cwd" == "$wt" ]] || { printf 'dead\n'; return 0; }
  fi
  case "$state" in
    live)     printf 'alive\n' ;;
    finished) printf 'dead\n' ;;
    *)        printf 'unknown\n' ;;
  esac
  return 0
}

session_probe() {  # <slug> [worktree-path] [backend] → stdout: alive|dead|unknown
  local slug="$1" wt="${2:-}" backend="${3:-herdr}"
  local timeout="${RD_LAUNCH_TIMEOUT:-5}"

  if ! session_backend_usable "$backend"; then
    printf 'unknown\n'; return 0
  fi
  if [[ "$backend" == hc ]]; then
    _session_probe_hc "$slug" "$wt"
    return 0
  fi

  local outfile errfile rc cls cwd
  # 조회 자체를 시도하지 못했으므로 dead 가 아니라 unknown 이다 — dead 로 오판하면
  # 호출부(resolve-launch)가 살아 있는 세션을 failed 로 확정해 버린다.
  outfile="$(mktemp)" || { printf 'unknown\n'; return 0; }
  errfile="$(mktemp)" || { rm -f "$outfile"; printf 'unknown\n'; return 0; }
  RD_SL_ERRFILE="$errfile" _session_launch_run_with_timeout "$timeout" "$outfile" \
    herdr agent get "$(_session_launch_agent_name "$slug")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    # dead 는 herdr 가 구조화된 `agent_not_found` 를 낸 경우뿐이다. 그 밖의 실패(다른 코드·
    # 타임아웃·응답 이상)는 세션이 없다는 증거가 아니다.
    cls="$(_session_launch_json_classify "$errfile")"
    rm -f "$outfile" "$errfile"
    [[ "$cls" == $'error\tagent_not_found' ]] && printf 'dead\n' || printf 'unknown\n'
    return 0
  fi
  cls="$(_session_launch_json_classify "$outfile")"
  rm -f "$outfile" "$errfile"

  # 실제 응답은 단수 `result.agent` 객체다(배열 `agents` 는 `agent list` 의 스키마).
  case "$cls" in
    agent$'\t'*) cwd="${cls#agent$'\t'}" ;;
    *) printf 'unknown\n'; return 0 ;;
  esac

  if [[ -n "$wt" ]]; then
    [[ -n "$cwd" ]] || { printf 'unknown\n'; return 0; }
    # 다른 작업을 맡은(cwd 가 다른) 세션을 alive 로 보지 않는다.
    [[ "$cwd" == "$wt" ]] && printf 'alive\n' || printf 'dead\n'
    return 0
  fi

  printf 'alive\n'; return 0
}

# ---- 세션 종료 판정 (읽기 전용) -------------------------------------------------
#   herdr 에 입력을 보내지 않는다. 관측 함수는 완전성 상태(stdout)와 읽은 경로(outfile)를
#   따로 낸다 — 상태가 unknown 이어도 읽은 경로는 outfile 에 남고, 판정은 경로를 먼저 본다.

# 내부 헬퍼: <path> 가 <wt>·<wt-physical> 중 하나와 같거나 그 하위이면 0, 아니면 1. 빈 path 는 1.
_session_path_in_worktree() {  # <path> <wt> <wt-physical>
  local p="$1" b
  [[ -n "$p" ]] || return 1
  for b in "${2-}" "${3-}"; do
    b="${b%/}"
    [[ -n "$b" ]] || continue
    if [[ "$p" == "$b" || "$p" == "$b"/* ]]; then return 0; fi
  done
  return 1
}

# 내부 헬퍼: <file> 의 어느 줄이든 worktree 안 경로이면 0.
_session_file_has_path_in_worktree() {  # <file> <wt> <wt-physical>
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    _session_path_in_worktree "$line" "$2" "$3" && return 0
  done < "$1"
  return 1
}

# herdr agent list 관측. stdout: `ok` | `unknown<TAB><원인>`. outfile: 비어 있지 않은 cwd·foreground_cwd 한 줄씩.
session_observe_agents() {  # <outfile>
  local out="$1" tmp rc=0 st
  : > "$out"
  if ! session_backend_usable herdr; then
    printf 'unknown\therdr 사용 불가\n'; return 0
  fi
  tmp="$(mktemp)" || { printf 'unknown\tagent list 실패\n'; return 0; }
  _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$tmp" herdr agent list || rc=$?
  if [[ $rc -eq 124 ]]; then rm -f "$tmp"; printf 'unknown\tagent list 시간 초과\n'; return 0; fi
  if [[ $rc -ne 0 ]]; then rm -f "$tmp"; printf 'unknown\tagent list 실패\n'; return 0; fi
  if ! command -v python3 >/dev/null 2>&1; then
    rm -f "$tmp"; printf 'unknown\tagent list 응답 형식 이상\n'; return 0
  fi
  # 첫 줄: ok | invalid | nocwd, 이후 줄: 경로
  python3 -I - "$tmp" > "$tmp.parsed" <<'PYEOF3' || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    agents = d["result"]["agents"]
    if not isinstance(agents, list):
        raise ValueError
except Exception:
    print("invalid")
    sys.exit(0)
paths = []
nocwd = False
for a in agents:
    got = False
    if isinstance(a, dict):
        for k in ("cwd", "foreground_cwd"):
            v = a.get(k)
            if isinstance(v, str) and v and "\n" not in v:
                paths.append(v)
                got = True
    if not got:
        nocwd = True
print("nocwd" if nocwd else "ok")
for p in paths:
    print(p)
PYEOF3
  st="$(head -1 "$tmp.parsed" 2>/dev/null)"
  tail -n +2 "$tmp.parsed" > "$out" 2>/dev/null || true
  rm -f "$tmp" "$tmp.parsed"
  case "$st" in
    ok)     printf 'ok\n' ;;
    nocwd)  printf 'unknown\tagent list 항목의 cwd 부재\n' ;;
    *)      : > "$out"; printf 'unknown\tagent list 응답 형식 이상\n' ;;
  esac
  return 0
}

# 내부 헬퍼: 서브셸(타임아웃 래퍼) 안에서 ps·lsof 를 돌려 결과를 <dir> 파일로 남긴다.
#   ps.rc / ps.out / pids / lsof.out / lsof.missing. 파싱·kill -0 검사는 바깥이 한다.
_session_observe_procs_raw() {  # <dir>
  local d="$1" rc=0 pid comm pids=""
  ps -U "$(id -u)" -o pid=,comm= > "$d/ps.out" 2>/dev/null || rc=$?
  printf '%s\n' "$rc" > "$d/ps.rc"
  [[ $rc -eq 0 ]] || return 0
  while read -r pid comm; do
    [[ "$pid" =~ ^[0-9]+$ && "${comm##*/}" == "claude" ]] || continue
    pids="${pids:+$pids,}$pid"
  done < "$d/ps.out"
  printf '%s\n' "$pids" > "$d/pids"
  [[ -n "$pids" ]] || return 0
  if ! command -v lsof >/dev/null 2>&1; then
    : > "$d/lsof.missing"; return 0
  fi
  # lsof rc 는 쓰지 않는다 — 고른 pid 중 끝난 것이 있으면 rc 1 이다.
  lsof -a -d cwd -p "$pids" -Fpn > "$d/lsof.out" 2>/dev/null || true
  return 0
}

# claude 프로세스 cwd 관측. stdout: `ok` | `unknown<TAB><원인>`. outfile: 읽은 cwd 한 줄씩(상태 무관).
session_observe_procs() {  # <outfile>
  local out="$1" d rc=0 line cur="" seen=" " pid cause="" pids
  : > "$out"
  d="$(mktemp -d)" || { printf 'unknown\tps 실행 실패\n'; return 0; }  # mktemp-scan: custom-handler
  _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$d/raw.out" _session_observe_procs_raw "$d" || rc=$?
  # lsof 가 읽은 cwd 는 시간 초과여도 남긴다.
  if [[ -f "$d/lsof.out" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        p*) cur="${line#p}" ;;
        n*) if [[ -n "$cur" ]]; then
              printf '%s\n' "${line#n}" >> "$out"
              seen="$seen$cur "
            fi ;;
      esac
    done < "$d/lsof.out"
  fi
  if [[ $rc -eq 124 ]]; then
    cause='프로세스 관측 시간 초과'
  elif [[ "$(cat "$d/ps.rc" 2>/dev/null)" != "0" ]]; then
    cause='ps 실행 실패'
  elif [[ -f "$d/lsof.missing" ]]; then
    cause='lsof 없음'
  else
    pids="$(cat "$d/pids" 2>/dev/null)"
    local IFS=','
    for pid in $pids; do
      [[ "$seen" == *" $pid "* ]] && continue
      if kill -0 "$pid" 2>/dev/null; then cause="cwd 미관측(pid=$pid)"; break; fi
    done
  fi
  rm -rf "$d"
  if [[ -n "$cause" ]]; then printf 'unknown\t%s\n' "$cause"; else printf 'ok\n'; fi
  return 0
}

# 이름 조회 관측. stdout: `absent` | `alive<TAB>herdr 에이전트 <이름> 생존` | `unknown<TAB><원인>`.
session_observe_name() {  # <slug> <wt> <wt-physical>
  local slug="$1" wt="$2" wtp="$3" name tmp errf rc=0 cls
  if ! session_backend_usable herdr; then printf 'unknown\therdr 사용 불가\n'; return 0; fi
  name="$(session_agent_name "$slug")"
  tmp="$(mktemp)" || { printf 'unknown\tagent get 실패\n'; return 0; }
  errf="$(mktemp)" || { rm -f "$tmp"; printf 'unknown\tagent get 실패\n'; return 0; }
  RD_SL_ERRFILE="$errf" _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$tmp" herdr agent get "$name" || rc=$?
  if [[ $rc -eq 124 ]]; then rm -f "$tmp" "$errf"; printf 'unknown\tagent get 시간 초과\n'; return 0; fi
  if [[ $rc -ne 0 ]]; then
    cls="$(_session_launch_json_classify "$errf")"
    rm -f "$tmp" "$errf"
    if [[ "$cls" == $'error\tagent_not_found' ]]; then printf 'absent\n'; else printf 'unknown\tagent get 실패\n'; fi
    return 0
  fi
  rm -f "$errf"
  if ! command -v python3 >/dev/null 2>&1; then
    rm -f "$tmp"; printf 'unknown\tagent get 응답 형식 이상\n'; return 0
  fi
  python3 -I - "$tmp" > "$tmp.parsed" <<'PYEOF4' || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        a = json.load(f)["result"]["agent"]
    if not isinstance(a, dict):
        raise ValueError
except Exception:
    print("invalid")
    sys.exit(0)
paths = [a.get(k) for k in ("cwd", "foreground_cwd")]
paths = [p for p in paths if isinstance(p, str) and p and "\n" not in p]
if not paths:
    print("invalid")
    sys.exit(0)
print("ok")
for p in paths:
    print(p)
PYEOF4
  if [[ "$(head -1 "$tmp.parsed" 2>/dev/null)" != "ok" ]]; then
    rm -f "$tmp" "$tmp.parsed"; printf 'unknown\tagent get 응답 형식 이상\n'; return 0
  fi
  tail -n +2 "$tmp.parsed" > "$tmp.paths"
  if _session_file_has_path_in_worktree "$tmp.paths" "$wt" "$wtp"; then
    rm -f "$tmp" "$tmp.parsed" "$tmp.paths"; printf 'alive\therdr 에이전트 %s 생존\n' "$name"; return 0
  fi
  rm -f "$tmp" "$tmp.parsed" "$tmp.paths"
  printf 'unknown\t이름 조회 성공 — worktree 밖 cwd\n'
}

# hc(herdr app) 갈래의 이름 조회 관측 (spec C6-4). stdout 계약은 session_observe_name 과 같습니다.
#   부재는 구조화된 not_found 와 끝난 터미널(state=finished)뿐입니다. live 인데 cwd 가 worktree 밖이거나
#   비어 있으면 성공한 이름 조회이므로 부재로 약화하지 않고 판정 불가로 둡니다(F1).
session_observe_name_hc() {  # <slug> <wt> <wt-physical>
  local slug="$1" wt="$2" wtp="$3" name tmp rc=0 state kind cwd
  if ! session_backend_usable hc; then printf 'unknown\thc 사용 불가\n'; return 0; fi
  name="$(session_agent_name "$slug")"
  tmp="$(mktemp)" || { printf 'unknown\thc get 실패\n'; return 0; }
  _session_launch_hc_get "$name" "$tmp" || rc=$?
  _session_launch_hc_read "$tmp" error.kind state cwd -- kind state cwd
  rm -f "$tmp"
  if [[ $rc -eq 124 ]]; then printf 'unknown\thc get 시간 초과\n'; return 0; fi
  if [[ $rc -ne 0 ]]; then
    if [[ "$kind" == not_found ]]; then printf 'absent\n'; else printf 'unknown\thc get 실패\n'; fi
    return 0
  fi
  case "$state" in
    finished) printf 'absent\n' ;;
    live)
      if [[ -n "$cwd" ]] && _session_path_in_worktree "$cwd" "$wt" "$wtp"; then
        printf 'alive\thc 세션 %s 생존\n' "$name"
      else
        printf 'unknown\t이름 조회 성공 — worktree 밖 cwd\n'
      fi ;;
    *) printf 'unknown\thc get 응답 형식 이상\n' ;;
  esac
  return 0
}

# 종료 판정. stdout: `alive<TAB><근거>` | `ended` | `unknown<TAB><원인>`. 생존 근거가 하나라도 있으면 생존.
#   7번째 인자는 색인의 launch-backend 입니다(빈 값 = herdr, spec C6-2·3). hc 작업은 이름 조회를 hc 로 하고,
#   hc 세션은 herdr 에이전트 목록에 나타나지 않으므로 목록 관측의 불완전을 판정 불가 근거로 쓰지 않습니다.
session_ended_judge() {  # <slug> <wt> <agents-status> <agents-file> <procs-status> <procs-file> [<backend>]
  local slug="$1" wt="$2" ast="$3" af="$4" pst="$5" pf="$6" backend="${7:-herdr}" wtp obs
  wtp="$(cd "$wt" 2>/dev/null && pwd -P)" || wtp=""
  if _session_file_has_path_in_worktree "$af" "$wt" "$wtp"; then
    printf 'alive\therdr 에이전트 cwd 일치\n'; return 0
  fi
  if _session_file_has_path_in_worktree "$pf" "$wt" "$wtp"; then
    printf 'alive\tclaude 프로세스 cwd 일치\n'; return 0
  fi
  case "$backend" in
    herdr) obs="$(session_observe_name "$slug" "$wt" "$wtp")" ;;
    hc)    obs="$(session_observe_name_hc "$slug" "$wt" "$wtp")"; ast="ok" ;;
    *)     printf 'unknown\t기동 백엔드 기록 이상(%s)\n' "$backend"; return 0 ;;
  esac
  case "$obs" in
    absent) ;;
    alive$'\t'*|unknown$'\t'*) printf '%s\n' "$obs"; return 0 ;;
    *) printf 'unknown\t관측 상태 이상\n'; return 0 ;;
  esac
  case "$ast" in
    ok) ;;
    unknown$'\t'*) printf '%s\n' "$ast"; return 0 ;;
    *) printf 'unknown\t관측 상태 이상\n'; return 0 ;;
  esac
  case "$pst" in
    ok) ;;
    unknown$'\t'*) printf '%s\n' "$pst"; return 0 ;;
    *) printf 'unknown\t관측 상태 이상\n'; return 0 ;;
  esac
  printf 'ended\n'
}

session_launch_model_valid() {
  case "$1" in
    opus|sonnet|haiku|fable) return 0 ;;
  esac
  [[ "$1" =~ ^claude-[a-z0-9]+(-[a-z0-9]+)*$ ]] && return 0
  [[ "$1" =~ ^fable-[a-z0-9]+(-[a-z0-9]+)*$ ]] && return 0
  return 1
}

_session_launch_json_get() {  # <file> <key>
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -e -s 'length == 1 and (.[0] | type) == "object"' "$file" >/dev/null 2>&1 || return 1
    local val
    val="$(jq -r -s --arg k "$key" \
      'if (.[0][$k] | type) == "string" then .[0][$k] else "" end' "$file" 2>/dev/null)" \
      || return 1
    printf '%s\n' "$val"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
val = data.get(sys.argv[2])
print(val if isinstance(val, str) else "")
PYEOF
    return $?
  fi
  return 1
}

# transcript 에서 현재 세션이 **실제로 응답한** 모델을 읽는다 (stdout: 모델 문자열).
#
# 왜 이 경로가 필요한가: `model-strategy.json` 은 사람이 만들어야 하는 파일인데 그
# 사실이 SKILL.md 안에만 적혀 있어 실제로는 만들어지지 않는다(이 저장소에도 존재한 적이
# 없다). 설정에만 의존하면 소비 프로젝트마다 같은 누락이 반복되고, 작업 탭이 부모와
# 다른 모델로 조용히 뜬다.
#
# 2026-09-17 에는 "셸에서 현재 세션의 실제 모델을 알 수 없다"는 이유로 상속을 배제했으나,
# 2026-09-21 실측으로 그 전제가 반증되었다 — transcript 의 `message.model` 은 전역 설정
# 같은 **기본값이 아니라 실제 응답 모델의 기록**이고, subagent 응답은 부모 transcript 에
# 기록되지 않아(조사한 세션 60건 모두 단일 모델, `isSidechain` 0건) 모델 오염이 없다.
#
# 파싱 백엔드 순서가 `_session_launch_json_get` 과 반대(python3 우선)인 것은 의도적이다.
# 대상이 JSONL 이라 마지막 줄이 쓰이는 중이면 잘려 있을 수 있는데, python3 은 줄 단위로
# 건너뛰고 jq 는 스트림 전체를 중단한다.
_session_launch_transcript_models() {  # <transcript> → stdout: 파일 순서의 model 값들
  local file="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PYEOF'
import json, sys
try:
    f = open(sys.argv[1], encoding="utf-8", errors="replace")
except OSError:
    sys.exit(1)
with f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue  # 쓰이는 중인 마지막 줄 등 — 건너뛴다
        if not isinstance(rec, dict) or rec.get("isSidechain"):
            continue
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        model = msg.get("model")
        if isinstance(model, str) and model:
            print(model)
PYEOF
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -r 'select(.isSidechain | not) | (.message? | objects | .model?) | strings' \
      "$file" 2>/dev/null || true
    return 0
  fi
  return 1
}

# 현재 세션의 모델 (stdout). 찾지 못하면 비어 있는 상태로 1 을 반환한다.
_session_launch_inherited_model() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  [[ -n "$sid" ]] || return 1
  # 세션 ID 는 UUID 다. 경로 구분자·상위 참조가 섞였으면 글롭 밖을 가리키므로 거부한다.
  case "$sid" in
    */*|*'..'*) return 1 ;;
  esac

  # 프로젝트 슬러그를 cwd 에서 도출하지 않는다 — worktree 세션은 자체 프로젝트
  # 디렉터리(`…--worktrees-<slug>`)를 가져 cwd 기반 도출이 어긋난다. 세션 ID 가 UUID 라
  # 유일하므로 글롭으로 찾고, 유일하지 않으면(0건·2건 이상) 판정을 포기한다.
  local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  [[ -d "$base" ]] || return 1
  local f matches=()
  for f in "$base"/*/"$sid".jsonl; do
    [[ -f "$f" ]] && matches+=("$f")
  done
  [[ "${#matches[@]}" -eq 1 ]] || return 1

  local models=() line
  while IFS= read -r line; do
    [[ -n "$line" ]] && models+=("$line")
  done < <(_session_launch_transcript_models "${matches[0]}")
  [[ "${#models[@]}" -gt 0 ]] || return 1

  # 뒤에서부터 첫 번째 **유효한** 값. 유효성 판정은 기존 함수를 그대로 쓴다 —
  # 모든 세션에 1건씩 섞여 있는 `<synthetic>` 은 여기서 탈락한다.
  local i
  for (( i = ${#models[@]} - 1; i >= 0; i-- )); do
    if session_launch_model_valid "${models[$i]}"; then
      printf '%s\n' "${models[$i]}"
      return 0
    fi
  done
  return 1
}

session_launch_model() {
  local wt="$1" cfg raw
  if [[ -n "${RD_SESSION_MODEL:-}" ]]; then
    if session_launch_model_valid "$RD_SESSION_MODEL"; then
      printf 'env\t%s\n' "$RD_SESSION_MODEL"; return 0
    fi
    printf '세션 모델(RD_SESSION_MODEL=%s)이 허용 범위를 벗어나 미지정으로 둡니다.\n' \
      "$RD_SESSION_MODEL" >&2
    printf 'default\t\n'; return 0
  fi
  cfg="${wt}/rd-workflow/config/model-strategy.json"
  if [[ -f "$cfg" ]]; then
    if ! raw="$(_session_launch_json_get "$cfg" session_model)"; then
      printf '세션 모델 설정 파일을 읽지 못했습니다(%s) — 미지정으로 둡니다.\n' "$cfg" >&2
      printf 'default\t\n'; return 0
    fi
    if [[ -n "$raw" ]]; then
      if session_launch_model_valid "$raw"; then
        printf 'config\t%s\n' "$raw"; return 0
      fi
      printf '세션 모델 설정(%s=%s)이 허용 범위를 벗어나 미지정으로 둡니다.\n' "$cfg" "$raw" >&2
      printf 'default\t\n'; return 0
    fi
  fi

  # 최하위 fallback — 명시 설정이 없을 때만 현재 세션의 모델을 상속한다. 설정이 있으면
  # 위에서 이미 반환했으므로 기존 두 경로의 동작은 바뀌지 않는다. 상속에 실패하면
  # 종전과 같은 미지정으로 수렴한다(새 실패 모드를 만들지 않는다).
  local inherited
  if inherited="$(_session_launch_inherited_model)" && [[ -n "$inherited" ]]; then
    printf 'inherit\t%s\n' "$inherited"; return 0
  fi
  printf 'default\t\n'; return 0
}

# ---- 탭 닫기 판정·호출 세션 생존 (읽기 + 조건부 tab close) -----------------------

# 내부 헬퍼: `herdr agent list` 응답에서 각 에이전트의 <field> 값을 읽는다 (stdout).
#   첫 줄은 `ok` 또는 `bad`. `ok` 다음 줄부터 값이 한 줄씩 나온다.
#   result.agents 가 배열이 아니거나, 항목 하나라도 객체가 아니거나 <field> 가 빈 값·문자열이 아니면
#   `bad` 다 — 판정할 수 없는 항목을 빼고 「없음」 으로 읽으면 살아 있는 세션을 끝난 것으로 오판한다.
_session_launch_agents_values() {  # <json-file> <field>
  command -v python3 >/dev/null 2>&1 || { printf 'bad\n'; return 0; }
  python3 -I - "$1" "$2" <<'PYEOF4'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    a = d["result"]["agents"]
    if not isinstance(a, list):
        raise ValueError
    vals = []
    for x in a:
        v = x.get(sys.argv[2]) if isinstance(x, dict) else None
        if not isinstance(v, str) or not v or "\n" in v:
            raise ValueError
        vals.append(v)
except Exception:
    print("bad")
    sys.exit(0)
print("ok")
for v in vals:
    print(v)
PYEOF4
}

# 내부 헬퍼: `herdr agent list` 를 불러 필드 값을 outvar 파일에 둔다.
#   return 0 정상(첫 줄 ok) / 1 조회 실패·응답 형식 이상(판정 불가)
_session_launch_agents_query() {  # <field> <outfile>
  local field="$1" out="$2" raw rc head
  raw="$(mktemp)" || return 1
  _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$raw" herdr agent list
  rc=$?
  if [[ $rc -ne 0 ]]; then rm -f "$raw"; return 1; fi
  _session_launch_agents_values "$raw" "$field" > "$out"
  rm -f "$raw"
  head="$(head -1 "$out")"
  [[ "$head" == ok ]]
}

# 작업 탭을 닫아도 되는지 판정하고, 되면 닫는다 (change spec D7).
#   return 0 닫음 / 1 닫지 않음(사유 stdout 한 줄) / 2 이미 없음
#   색인의 `launch-backend`·`launch-tab` 을 읽는다. 호출부는 `tasks_index_get` 을 source 해 둔다.
session_tab_close_if_ended() {  # <slug>
  local slug="$1" backend tab tg errf rc cls label vals
  if ! declare -F tasks_index_get >/dev/null 2>&1; then
    printf '색인 함수(tasks_index_get)를 불러오지 않음 — 탭을 닫지 않음\n'; return 1
  fi
  backend="$(tasks_index_get "$slug" launch-backend 2>/dev/null || true)"
  tab="$(tasks_index_get "$slug" launch-tab 2>/dev/null || true)"
  if [[ "$backend" != herdr ]]; then
    printf '백엔드가 herdr 가 아님 — 탭을 닫지 않음\n'; return 1
  fi
  if [[ -z "$tab" ]]; then
    printf '탭 식별자 없음 — 직접 닫으십시오\n'; return 1
  fi
  command -v herdr >/dev/null 2>&1 || { printf 'herdr 명령 없음 — 탭을 닫지 않음\n'; return 1; }

  tg="$(mktemp)" || { printf '임시 파일 생성 실패 — 탭을 닫지 않음\n'; return 1; }
  errf="$(mktemp)" || { rm -f "$tg"; printf '임시 파일 생성 실패 — 탭을 닫지 않음\n'; return 1; }
  RD_SL_ERRFILE="$errf" _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$tg" herdr tab get "$tab"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    cls="$(_session_launch_json_classify "$errf")"
    rm -f "$tg" "$errf"
    [[ "$cls" == $'error\ttab_not_found' ]] && return 2
    printf '탭 조회 실패 — 탭을 닫지 않음\n'; return 1
  fi
  label="$(python3 -I - "$tg" <<'PYEOF5'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        l = json.load(f)["result"]["tab"]["label"]
    if isinstance(l, str):
        print(l)
except Exception:
    pass
PYEOF5
)"
  rm -f "$tg" "$errf"
  # 번호 접두(`[12] `)는 herdr 가 붙인다. 떼고 slug 와 정확히 같아야 한다 (접두 일치 금지).
  if [[ "$label" =~ ^\[[0-9]+\]\  ]]; then label="${label#*\] }"; fi
  if [[ "$label" != "$slug" ]]; then
    printf '탭 이름이 작업과 다름 — 탭을 닫지 않음\n'; return 1
  fi

  vals="$(mktemp)" || { printf '임시 파일 생성 실패 — 탭을 닫지 않음\n'; return 1; }
  if ! _session_launch_agents_query tab_id "$vals"; then
    rm -f "$vals"; printf '에이전트 목록을 확인하지 못함 — 탭을 닫지 않음\n'; return 1
  fi
  if grep -qxF -- "$tab" "$vals"; then
    rm -f "$vals"; printf '세션이 살아 있음 — 탭을 닫지 않음\n'; return 1
  fi
  # 닫기 직전 재조회: 그 사이 에이전트가 생겼을 수 있다.
  if ! _session_launch_agents_query tab_id "$vals"; then
    rm -f "$vals"; printf '에이전트 목록을 확인하지 못함 — 탭을 닫지 않음\n'; return 1
  fi
  if grep -qxF -- "$tab" "$vals"; then
    rm -f "$vals"; printf '세션이 살아 있음 — 탭을 닫지 않음\n'; return 1
  fi
  rm -f "$vals"

  tg="$(mktemp)" || { printf '임시 파일 생성 실패 — 탭을 닫지 않음\n'; return 1; }
  _session_launch_run_with_timeout "${RD_LAUNCH_TIMEOUT:-5}" "$tg" herdr tab close "$tab"
  rc=$?
  rm -f "$tg"
  if [[ $rc -ne 0 ]]; then printf '탭 닫기 실패\n'; return 1; fi
  return 0
}

# 호출 세션이 살아 있는지 판정한다 (change spec D13).
#   return 0 생존 / 1 소실 / 2 판정 불가 (판정 불가는 소실로 보지 않는다)
session_caller_alive() {  # <backend> <id>
  local backend="$1" id="$2" out rc state kind
  [[ -n "$id" ]] || return 2
  out="$(mktemp)" || return 2
  case "$backend" in
    herdr)
      command -v herdr >/dev/null 2>&1 || { rm -f "$out"; return 2; }
      if ! _session_launch_agents_query pane_id "$out"; then rm -f "$out"; return 2; fi
      if grep -qxF -- "$id" "$out"; then rm -f "$out"; return 0; fi
      rm -f "$out"; return 1 ;;
    hc)
      command -v hc >/dev/null 2>&1 || { rm -f "$out"; return 2; }
      _session_launch_hc_get "$id" "$out"
      rc=$?
      _session_launch_hc_read "$out" state error.kind -- state kind
      rm -f "$out"
      [[ "$kind" == not_found ]] && return 1
      if [[ "$rc" -ne 0 || -z "$state" ]]; then return 2; fi
      case "$state" in
        live)     return 0 ;;
        finished) return 1 ;;
        *)        return 2 ;;
      esac ;;
    *) rm -f "$out"; return 2 ;;
  esac
}
