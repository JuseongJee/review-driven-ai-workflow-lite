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
    ok)      printf '이 세션은 여기서 멈춥니다 — 이후 단계는 탭 %s 의 세션이 진행합니다.\n' "${2:-<slug>}" ;;
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

# 이 셸에서 herdr 를 실제로 호출할 수 있는지 — 안내 문구를 가르는 데 씁니다 (F1).
# herdr 가 없는 환경에서 `herdr agent get ...` 을 권하면 사용자는 실행할 수 없는 명령만
# 받고 막다른 길에 섭니다.
session_herdr_available() {
  [[ -n "${HERDR_ENV:-}" ]] && command -v herdr >/dev/null 2>&1
}

# 내부 헬퍼: 이 머신에 `timeout` 명령이 없으므로 백그라운드 + 폴링으로 유한 시간을
# 강제한다. stdout 은 $2 파일에 남기고, 리턴 값은 명령의 종료 코드(타임아웃이면 124).
_session_launch_run_with_timeout() {  # <timeout-secs> <outfile> <cmd...>
  local timeout_secs="$1" outfile="$2"; shift 2
  : > "$outfile"
  ( "$@" >"$outfile" 2>/dev/null ) &
  local pid=$!
  local max_checks=$(( timeout_secs * 5 ))
  [[ "$max_checks" -lt 1 ]] && max_checks=1
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( i >= max_checks )); then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    i=$((i+1))
  done
  wait "$pid"
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

# 인계 문구 (F4) — 세션에 넘길 작업 지시입니다. **기동 시점과 승인 이후 재개 시점이
# 같은 문구를 쓰도록** 별도 함수로 둡니다. 여기서만 문구를 만들고, 두 경로가 이 함수를
# 부릅니다 (문구가 갈리면 "같은 작업을 이어받는다" 는 계약이 경로마다 달라집니다).
session_handoff_text() {  # <slug> <req> <worktree-path>
  printf '작업(FR): %s\nREQUEST: %s\nWorktree: %s\n이 작업을 이어서 진행해 주십시오.' "$1" "$2" "$3"
}

# 인계 전달 (F4) — `herdr agent prompt` 로 위 문구를 세션에 밀어 넣습니다.
#   return 0 전달 성공 / 1 전달하지 못함(호출 불가·실패·타임아웃).
#   **생존 확인과 전달 성공은 다른 사실입니다** — 호출부가 둘을 구분해 보고하도록
#   이 함수는 launch 상태를 만들지 않고 전달 여부만 돌려줍니다.
session_handoff_deliver() {  # <slug> <worktree-path> <request-path>
  local slug="$1" wt="$2" req="$3"
  local timeout="${RD_LAUNCH_TIMEOUT:-5}"
  if [[ -z "${HERDR_ENV:-}" ]] || ! command -v herdr >/dev/null 2>&1; then
    return 1
  fi
  local agent_name handoff outfile rc
  agent_name="$(_session_launch_agent_name "$slug")"
  handoff="$(session_handoff_text "$slug" "$req" "$wt")"
  outfile="$(mktemp)" || return 1
  _session_launch_run_with_timeout "$timeout" "$outfile" \
    herdr agent prompt "$agent_name" "$handoff"
  rc=$?
  rm -f "$outfile"
  [[ "$rc" -eq 0 ]]
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

session_launch() {  # <worktree-path> <slug> <request-path> [<model>] → stdout: launch 상태
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
  if [[ -z "${HERDR_ENV:-}" ]] || ! command -v herdr >/dev/null 2>&1; then
    printf '자동 기동을 하지 않았습니다. 아래 명령으로 시작하십시오.\n' >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'none\n'; return 0
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
  if [[ -z "$pane_id" ]]; then
    # tab create 는 성공(rc=0)했지만 pane_id 를 응답에서 찾지 못한 경우다. agent 를 붙일
    # 대상을 알 수 없다. tab_id 를 건졌으면 그 tab 은 닫아 빈 tab 을 남기지 않는다.
    [[ -n "$tab_id" ]] && _session_launch_close_tab_best_effort "$tab_id"
    printf '자동 기동에 실패했습니다(pane id 를 응답에서 찾지 못했습니다). 아래 명령으로 시작하십시오.\n' >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  fi

  outfile="$(mktemp)" || {
    # tab 은 이미 만들어졌고 agent 는 아직 안 붙었다 — 위 갈래와 같은 정리를 한다.
    _session_launch_close_tab_best_effort "$tab_id"
    printf '자동 기동에 실패했습니다(%s). 아래 명령으로 시작하십시오.\n' "임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2
    printf '%s\n' "$(session_launch_command "$wt" "$slug" "$model")" >&2
    printf 'failed\n'; return 0
  }
  if [[ -n "$model" ]]; then
    _session_launch_run_with_timeout "$timeout" "$outfile" \
      herdr agent start "$agent_name" --kind claude --pane "$pane_id" -- --model "$model"
  else
    _session_launch_run_with_timeout "$timeout" "$outfile" \
      herdr agent start "$agent_name" --kind claude --pane "$pane_id"
  fi
  rc=$?
  local start_body=""
  start_body="$(cat "$outfile" 2>/dev/null)"
  rm -f "$outfile"
  if [[ $rc -ne 0 ]]; then
    # **`agent_not_ready` 는 실패가 아니다** (2026-09-16 실측). 새 worktree 는 늘 처음 여는
    # 경로라 claude 가 기동 직후 신뢰 확인 같은 다이얼로그를 띄우고 `blocked` 로 들어가는데,
    # 그때 `agent start` 가 이 코드로 rc≠0 을 낸다. **에이전트는 멀쩡히 떠 있다.** 이것을
    # failed 로 보고 tab 을 닫으면 사람이 승인하기도 전에 방금 뜬 세션을 죽인다 — 그리고
    # 이 다이얼로그는 예외가 아니라 정상 착수의 거의 매번이다. 승인은 사람이 하는 것이므로
    # 여기서는 손대지 않고 unknown 으로 넘겨 확인 방법만 알린다.
    if printf '%s' "$start_body" | grep -q 'agent_not_ready'; then
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
    printf '재시도: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$slug" >&2
    printf 'unknown\n'; return 0
  fi

  printf 'ok\n'; return 0
}

session_probe() {  # <slug> [worktree-path] → stdout: alive|dead|unknown
  local slug="$1" wt="${2:-}"
  local timeout="${RD_LAUNCH_TIMEOUT:-5}"

  if [[ -z "${HERDR_ENV:-}" ]] || ! command -v herdr >/dev/null 2>&1; then
    printf 'unknown\n'; return 0
  fi

  local outfile rc body
  # 조회 자체를 시도하지 못했으므로 dead 가 아니라 unknown 이다 — dead 로 오판하면
  # 호출부(resolve-launch)가 살아 있는 세션을 failed 로 확정해 버린다.
  outfile="$(mktemp)" || { printf 'unknown\n'; return 0; }
  _session_launch_run_with_timeout "$timeout" "$outfile" herdr agent get "$(_session_launch_agent_name "$slug")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$outfile"
    printf 'unknown\n'; return 0
  fi
  body="$(cat "$outfile" 2>/dev/null)"
  rm -f "$outfile"

  # agents 배열이 비어 있으면 세션이 없다고 본다.
  case "$body" in
    *'"agents":['*'{'*) ;;
    *) printf 'dead\n'; return 0 ;;
  esac

  if [[ -n "$wt" ]]; then
    # 다른 작업을 맡은(cwd 가 다른) 세션을 alive 로 보지 않는다.
    case "$body" in
      *"\"cwd\":\"$wt\""*) printf 'alive\n'; return 0 ;;
      *) printf 'dead\n'; return 0 ;;
    esac
  fi

  printf 'alive\n'; return 0
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
  [[ -f "$cfg" ]] || { printf 'default\t\n'; return 0; }
  if ! raw="$(_session_launch_json_get "$cfg" session_model)"; then
    printf '세션 모델 설정 파일을 읽지 못했습니다(%s) — 미지정으로 둡니다.\n' "$cfg" >&2
    printf 'default\t\n'; return 0
  fi
  [[ -n "$raw" ]] || { printf 'default\t\n'; return 0; }
  if session_launch_model_valid "$raw"; then
    printf 'config\t%s\n' "$raw"; return 0
  fi
  printf '세션 모델 설정(%s=%s)이 허용 범위를 벗어나 미지정으로 둡니다.\n' "$cfg" "$raw" >&2
  printf 'default\t\n'; return 0
}
