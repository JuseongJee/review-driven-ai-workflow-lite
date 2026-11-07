#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
TMP="$(mktemp -d)" || { echo "test_session_launch.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_session_launch.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# 실제 herdr app tab 기동 차단: 케이스마다 HERDR_ENV= 를 주는 것과 같은 이유로 비운다.
export HC_TERMINAL_ID=
source "$SCRIPT_DIR/session_launch.sh"

# 1) herdr 밖이면 기동하지 않고 none 을 낸다
out="$(HERDR_ENV= RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "none" ]] && pass "herdr 밖에서는 none" || fail "herdr 밖 판정: $out"

# 2) 자식 세션이면 herdr 환경이어도 기동하지 않고 none + 거부 사유
err="$(HERDR_ENV=1 RD_CHILD_SESSION=1 session_launch /tmp/wt alpha REQUEST.md 2>&1 >/dev/null)"
[[ "$err" == *"자식 세션"* ]] && pass "자식 세션은 기동을 거부한다" || fail "깊이 1 거부"

# 3) 수동 기동 명령에 worktree 경로가 들어간다
cmd="$(session_launch_command /tmp/wt alpha)"
[[ "$cmd" == *"/tmp/wt"* ]] && pass "수동 명령에 worktree 경로 포함" || fail "수동 명령"

# 3-1) 인계 문구 — 인계 파일 인자가 없으면 현행 바이트와 같고, 있으면 확정 결정 줄이 끝 줄 앞에 붙는다
[[ "$(session_handoff_text a /r /w)" == "$(printf '작업(FR): %s\nREQUEST: %s\nWorktree: %s\n이 작업을 이어서 진행해 주십시오.' a /r /w)" ]] \
  && pass "3인자 출력이 현행과 같다" || fail "3인자 출력이 현행과 같다: $(session_handoff_text a /r /w)"
_ht="$(session_handoff_text a /r /w /w/h.md)"
[[ "$_ht" == *"확정 결정: /w/h.md — 먼저 읽고 시작하십시오."* && "${_ht##*$'\n'}" == "이 작업을 이어서 진행해 주십시오." ]] \
  && pass "4인자는 경로 줄을 더한다" || fail "4인자는 경로 줄을 더한다: $_ht"

# 4) 상태별 문구가 호출 세션의 거취를 담는다 (AC1). unknown 은 failed/none 과 다른
#    분기임을 명시적으로 검증한다(F1 재발 방지).
[[ "$(session_launch_status_hint ok tab7)" == *"멈춥니다"* && "$(session_launch_status_hint ok tab7)" == *"tab7"* ]] \
  && pass "ok — 호출 세션은 멈춘다는 문구 + slug" || fail "ok 문구: $(session_launch_status_hint ok tab7)"
[[ "$(session_launch_status_hint unknown alpha)" == *"이어받지 않습니다"* && "$(session_launch_status_hint unknown alpha)" == *"resolve-launch alpha"* ]] \
  && pass "unknown — 이어받지 않는다는 문구 + resolve-launch 명령" || fail "unknown 문구: $(session_launch_status_hint unknown alpha)"
[[ "$(session_launch_status_hint unknown alpha)" != *"이어서 진행"* ]] \
  && pass "unknown 문구에는 '이어서 진행' 이 없다(failed/none 과 구분)" || fail "unknown 이 failed/none 문구와 섞였다"
[[ "$(session_launch_status_hint failed tab7)" == *"이어서 진행"* && "$(session_launch_status_hint failed tab7)" == *"resolve-launch tab7"* ]] \
  && pass "failed — 이어서 진행한다는 문구 + 손으로 띄운 경우의 resolve-launch 명령" || fail "failed 문구: $(session_launch_status_hint failed tab7)"
[[ "$(session_launch_status_hint none)" == *"이어서 진행"* && "$(session_launch_status_hint none)" != *"resolve-launch"* ]] \
  && pass "none — 이어서 진행한다는 문구, resolve-launch 없음" || fail "none 문구: $(session_launch_status_hint none)"

# 5) CLI 대역(stub)으로 상태 분기를 검사한다 — PATH 앞에 가짜 herdr 를 둔다.
#    실제 herdr 화면 동작은 수동 확인이지만, 상태 분기까지 수동에 맡기지 않는다.
#    stub 은 받은 인자를 calls.log 에 남겨, cwd·env 전달 같은 호출 형태도 검사한다.
#    (실제 응답 스키마 — 이 머신에서 실측: `tab create` 는 `.result.root_pane.pane_id` 와
#     `.result.tab.tab_id` 를 함께 돌려준다.)
STUB="$TMP/bin"; mkdir -p "$STUB"
make_stub() {  # make_stub <tab-create-rc> <start-rc> <prompt-rc> [start-body] [prompt-out] [prompt-err] [sleep-secs]
  : > "$STUB/calls.log"
  local _tab_rc="$1" _start_rc="$2" _prompt_rc="$3"
  local _start_body="${4:-}" _prompt_out="${5:-}" _prompt_err="${6:-}" _sleep="${7:-0}"
  cat > "$STUB/herdr" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB/calls.log"
case "\$1 \$2" in
  "tab create")
    [[ "${_tab_rc}" -ne 0 ]] && exit ${_tab_rc}
    echo '{"result":{"root_pane":{"pane_id":"wX:p9","tab_id":"wX:t9"},"tab":{"tab_id":"wX:t9"}}}' ;;
  "agent start") sleep ${_sleep}; printf '%s' '${_start_body}'; exit ${_start_rc} ;;
  "agent prompt") sleep ${_sleep}; printf '%s' '${_prompt_out}'; printf '%s' '${_prompt_err}' >&2; exit ${_prompt_rc} ;;
  "agent get") echo '{"error":{"code":"agent_not_found","message":"x"}}' >&2; exit 1 ;;
  "tab close") exit 0 ;;
esac
STUBEOF
  chmod +x "$STUB/herdr"
}

make_stub 0 0 0
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "ok" ]] && pass "start·prompt 모두 성공이면 ok" || fail "ok 판정: $out"

make_stub 0 0 1
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "unknown" ]] \
  && pass "start 성공 + prompt 실패는 unknown (세션이 살아 있을 수 있다)" || fail "부분 성공: $out"

make_stub 0 1 0
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "failed" ]] && pass "start 실패는 failed" || fail "failed 판정: $out"
grep -q '^tab close' "$STUB/calls.log" \
  && pass "agent start 실패 시 만들어진 tab 을 닫으려 시도한다" || fail "agent start 실패 후 tab close 미시도"

# 5-1) **`agent_not_ready` 는 failed 가 아니다.** 새 worktree 는 늘 처음 여는 경로라
#      claude 가 기동 직후 신뢰 확인 다이얼로그를 띄우고 blocked 로 들어가는데, 그때
#      agent start 가 이 코드로 rc≠0 을 낸다 — **에이전트는 떠 있다**(2026-09-16 실측).
#      failed 로 보고 tab 을 닫으면 사람이 승인하기 전에 방금 뜬 세션을 죽인다.
make_stub 0 1 0 '{"error":{"code":"agent_not_ready","message":"blocked during startup"}}'
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "unknown" ]] \
  && pass "agent_not_ready(blocked)는 unknown 이다" || fail "agent_not_ready 판정: $out"
grep -q '^tab close' "$STUB/calls.log" \
  && fail "blocked 세션의 tab 을 닫았다(승인 전 세션 소실)" \
  || pass "blocked 세션의 tab 은 닫지 않는다"

# 5-2) **타임아웃(rc=124)도 failed 가 아니다** (F3). 시작 요청은 이미 보냈으므로 "만들어지지
#      않았다" 는 증거가 없다. tab 을 닫으면 응답만 늦은 살아 있는 세션을 죽인다.
make_stub 0 124 0
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "unknown" ]] \
  && pass "agent start 타임아웃(124)은 unknown 이다" || fail "start 타임아웃 판정: $out"
grep -q '^tab close' "$STUB/calls.log" \
  && fail "타임아웃 뒤 tab 을 닫았다(살아 있을 수 있는 세션 소실)" \
  || pass "start 타임아웃에서는 tab 을 닫지 않는다"

# 5-3) 기동·전달 대기 상한 (change spec D1~D3) — 대역 성공 stdout 은 herdr 0.9.4 내장 스키마
#      (`result.agent.agent_status`)를 쓴다. 대기 변수는 이 구획에서 비운 상태로 시작한다.
unset RD_LAUNCH_START_TIMEOUT RD_LAUNCH_PROMPT_TIMEOUT RD_LAUNCH_TIMEOUT
_pj() { printf '{"id":"cli:agent:prompt","result":{"type":"agent_prompted","agent":{"agent_status":"%s"}}}' "$1"; }
_calls() { cat "$STUB/calls.log"; }
_nclose() { grep -c '^tab close' "$STUB/calls.log" || true; }
_nprompt() { grep -c '^agent prompt' "$STUB/calls.log" || true; }

# A1) agent start 에 herdr --timeout 이 `--` 앞에 실린다
make_stub 0 0 0
: "$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md opus 2>/dev/null)"
[[ "$(grep '^agent start' "$STUB/calls.log")" == *"--timeout 60000 -- --model opus"* ]] \
  && pass "agent start 에 --timeout 60000 이 -- 앞에 실린다" || fail "A1 agent start 인자: $(grep '^agent start' "$STUB/calls.log")"

# A2) 짧은 호출 상한(RD_LAUNCH_TIMEOUT=1)에 기동·전달이 묶이지 않는다 — 이번 결함의 본체
make_stub 0 0 0 '' '' '' 2
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_LAUNCH_TIMEOUT=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md "" 2>/dev/null)"
[[ "$out" == "ok" ]] \
  && pass "짧은 호출 상한(RD_LAUNCH_TIMEOUT=1)에 기동·전달이 묶이지 않는다" || fail "A2 기동·전달이 짧은 상한에 묶임: $out"

# A3) agent prompt 에 --wait --until working --until blocked --timeout 15000
make_stub 0 0 0 '' "$(_pj working)"
: "$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md "" 2>/dev/null)"
[[ "$(_calls)" == *"--wait --until working --until blocked --timeout 15000"* ]] \
  && pass "agent prompt 에 --wait --until working --until blocked --timeout 15000" || fail "A3 agent prompt 인자: $(_calls)"

# A4) 전달 결과 판정 (D3 표) — 각 행: 결과값, stderr 핵심 문구, tab close 없음, agent prompt 1회
_deliver_row() {  # <이름> <기대 결과> <prompt-rc> <prompt-out> <prompt-err> → $TMP/dc.err, $_dc_out
  make_stub 0 0 "$3" '' "$4" "$5"
  _dc_out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md "" 2>"$TMP/dc.err")"
  [[ "$_dc_out" == "$2" ]] && pass "A4 $1 → 결과 $2" || fail "A4 $1 결과: $_dc_out"
  [[ "$(_nclose)" == "0" ]] && pass "A4 $1 → tab 을 닫지 않는다" || fail "A4 $1 tab close 호출됨"
  [[ "$(_nprompt)" == "1" ]] && pass "A4 $1 → agent prompt 1회" || fail "A4 $1 agent prompt 횟수: $(_nprompt)"
}
_err_has() { grep -qF -- "$1" "$TMP/dc.err"; }

_deliver_row "working" ok 0 "$(_pj working)" ""
{ ! _err_has '확인을 기다립니다' && ! _err_has '처리 상태를 읽지 못했습니다'; } \
  && pass "A4 working → 안내 줄 없음" || fail "A4 working 에 안내가 나옴: $(cat "$TMP/dc.err")"

_deliver_row "blocked 관측" ok 0 "$(_pj blocked)" ""
_err_has '제출됐고 세션이 확인을 기다립니다' \
  && pass "A4 blocked 관측 → 승인 안내" || fail "A4 blocked 안내 없음: $(cat "$TMP/dc.err")"

_deliver_row "형식 이상" ok 0 "" ""
_err_has '처리 상태를 읽지 못했습니다' \
  && pass "A4 형식 이상 → 상태 확인 안내" || fail "A4 형식 이상 안내 없음: $(cat "$TMP/dc.err")"

_deliver_row "agent_blocked" unknown 1 "" '{"error":{"code":"agent_blocked","message":"x"}}'
{ _err_has '시작 프롬프트를 보내지 않았습니다' && _err_has 'resolve-launch alpha'; } \
  && pass "A4 agent_blocked → 승인 뒤 전달 안내" || fail "A4 agent_blocked 안내: $(cat "$TMP/dc.err")"

_deliver_row "stalled" unknown 1 "" '{"error":{"code":"agent_prompt_stalled","message":"x"}}'
{ _err_has '확인하지 못했습니다(agent_prompt_stalled)' && _err_has '입력창에 문구가 남아 있으면 Enter'; } \
  && pass "A4 stalled → 화면 먼저 확인 안내" || fail "A4 stalled 안내: $(cat "$TMP/dc.err")"
! _err_has '재시도: ' \
  && pass "A4 stalled → 무조건 재시도 줄 없음" || fail "A4 stalled 에 재시도 줄이 있음: $(cat "$TMP/dc.err")"

_deliver_row "timeout 코드" unknown 1 "" '{"error":{"code":"timeout","message":"x"}}'
_err_has '확인하지 못했습니다(timeout)' \
  && pass "A4 timeout 코드 → 사유에 timeout" || fail "A4 timeout 안내: $(cat "$TMP/dc.err")"

# A6) 대기 안내 줄에 slug 와 상한이 나온다
make_stub 0 0 0 '' "$(_pj working)"
err="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md "" 2>&1 >/dev/null)"
[[ "$err" == *"세션 기동 대기: alpha"*"최대 65초"* && "$err" == *"시작 프롬프트 처리 확인: alpha"*"최대 20초"* ]] \
  && pass "대기 안내 줄에 slug 와 상한이 나온다" || fail "A6 대기 안내: $err"

# A7) 범위 밖 대기 값은 경고 후 기본값
make_stub 0 0 0 '' "$(_pj working)"
err="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_LAUNCH_START_TIMEOUT=abc RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md "" 2>&1 >/dev/null)"
[[ "$(grep '^agent start' "$STUB/calls.log")" == *"--timeout 60000"* && "$err" == *"RD_LAUNCH_START_TIMEOUT=abc"*"기본값 60초"* ]] \
  && pass "범위 밖 RD_LAUNCH_START_TIMEOUT 은 경고 후 기본값 60초" || fail "A7 start 값: $err / $(grep '^agent start' "$STUB/calls.log")"
make_stub 0 0 0 '' "$(_pj working)"
err="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_LAUNCH_PROMPT_TIMEOUT=5 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md "" 2>&1 >/dev/null)"
[[ "$(_calls)" == *"--timeout 15000"* && "$err" == *"RD_LAUNCH_PROMPT_TIMEOUT=5"*"기본값 15초"* ]] \
  && pass "하한 아래 RD_LAUNCH_PROMPT_TIMEOUT=5 는 경고 후 기본값 15초" || fail "A7 prompt 값: $err / $(_calls)"

# 5a) tab create 자체가 실패하면 ok 가 아니다 (agent start·prompt 는 아예 호출되지 않아야 한다)
make_stub 1 0 0
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "failed" ]] && pass "tab create 실패는 failed(ok 아님)" || fail "tab create 실패 판정: $out"
if grep -q '^tab create' "$STUB/calls.log" && ! grep -q '^agent start' "$STUB/calls.log"; then
  pass "tab create 실패 시 agent start 를 호출하지 않는다"
else
  fail "tab create 실패 후에도 agent start 가 호출됨"
fi

# 5b) 기동 경로가 cwd·env·label 을 tab create 인자로 직접 전달한다 (send-text 로 타이핑해
#     넣지 않는다 — 그 방식은 셸 준비 시점과 경합한다). **label 에 slug 를 싣는 것이
#     식별의 근거다** — herdr agents 패널이 행마다 그 tab 의 label 을 보여준다(실측).
make_stub 0 0 0
: "$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
create_call="$(grep '^tab create' "$STUB/calls.log" || true)"
[[ "$create_call" == *"--cwd /tmp/wt"* && "$create_call" == *"--env RD_CHILD_SESSION=1"* ]] \
  && pass "tab create 인자에 --cwd·--env 가 담긴다" || fail "cwd·env 전달: $create_call"
[[ "$create_call" == *"--label alpha"* ]] \
  && pass "tab label 에 작업 slug 가 담긴다(목록 식별)" || fail "label 전달: $create_call"
grep -q 'send-text' "$STUB/calls.log" \
  && fail "send-text 경로가 남아 있다(경합 원인)" \
  || pass "send-text 를 호출하지 않는다"

# 5c) herdr 에이전트 이름은 1~32자다(실측). normalize_slug 는 60자까지 허용하므로 그 사이
#     구간을 줄이지 않으면 정상 착수가 기동 실패로 떨어진다. 전체 slug 는 label 이 지킨다.
make_stub 0 0 0
long_slug="aaaaaaaaaa-bbbbbbbbbb-cccccccccc-dddddddddd"   # 43자
: "$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt "$long_slug" REQUEST.md 2>/dev/null)"
start_call="$(grep '^agent start' "$STUB/calls.log" || true)"
started_name="$(printf '%s' "$start_call" | awk '{print $3}')"
[[ -n "$started_name" && "${#started_name}" -le 32 ]] \
  && pass "긴 slug 의 에이전트 이름을 32자 이하로 줄인다" || fail "이름 길이: [${started_name}] ${#started_name}자"
create_call="$(grep '^tab create' "$STUB/calls.log" || true)"
[[ "$create_call" == *"--label $long_slug"* ]] \
  && pass "이름을 줄여도 tab label 에는 전체 slug 가 남는다" || fail "긴 slug label: $create_call"

# 5d) 인계 전달 — 인계 파일이 있을 때만 문구에 확정 결정 줄이 실린다 (여러 줄 문구라
#     calls.log 전체를 본다)
mkdir -p "$TMP/wt/rd-workflow-workspace/.lifecycle"
_hf="$TMP/wt/rd-workflow-workspace/.lifecycle/handoff.md"
make_stub 0 0 0
PATH="$STUB:$PATH" HERDR_ENV=1 session_handoff_deliver alpha "$TMP/wt" "$TMP/wt/REQUEST.md" || true
grep -q '확정 결정' "$STUB/calls.log" \
  && fail "인계 파일 없으면 확정 결정 줄 없음" || pass "인계 파일 없으면 확정 결정 줄 없음"
make_stub 0 0 0
: > "$_hf"
PATH="$STUB:$PATH" HERDR_ENV=1 session_handoff_deliver alpha "$TMP/wt" "$TMP/wt/REQUEST.md" || true
grep -qF "확정 결정: $_hf" "$STUB/calls.log" \
  && pass "deliver 문구에 인계 경로" || fail "deliver 문구에 인계 경로: $(cat "$STUB/calls.log")"
rm -f "$_hf"

# 5e) autopilot 줄 — 5번째 인자가 autopilot 일 때만 끝 줄 바로 앞에 실린다. deliver 는
#     driver check 가 0 일 때만 그 인자를 채운다
_at="$(session_handoff_text a /r /w "" autopilot)"
_last="${_at##*$'\n'}"; _rest="${_at%$'\n'*}"; _prev="${_rest##*$'\n'}"
[[ "$_prev" == "autopilot: 이 작업은 autopilot 으로 진행합니다."* && "$_last" == "이 작업을 이어서 진행해 주십시오." ]] \
  && pass "5인자 autopilot 은 끝 줄 앞에 autopilot 줄을 더한다" || fail "5인자 autopilot 줄 위치: $_at"
mkdir -p "$TMP/wt5/rd-workflow/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/wt5/rd-workflow/scripts/autopilot_driver.sh"
make_stub 0 0 0
PATH="$STUB:$PATH" HERDR_ENV=1 session_handoff_deliver alpha "$TMP/wt5" "$TMP/wt5/REQUEST.md" 2>/dev/null || true
grep -qF 'autopilot: 이 작업은' "$STUB/calls.log" \
  && pass "driver check 0 이면 deliver 문구에 autopilot 줄" || fail "deliver autopilot 줄 없음: $(cat "$STUB/calls.log")"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/wt5/rd-workflow/scripts/autopilot_driver.sh"
make_stub 0 0 0
PATH="$STUB:$PATH" HERDR_ENV=1 session_handoff_deliver alpha "$TMP/wt5" "$TMP/wt5/REQUEST.md" 2>/dev/null || true
grep -qF 'autopilot: 이 작업은' "$STUB/calls.log" \
  && fail "driver check 1 인데 autopilot 줄이 있음" || pass "driver check 1 이면 deliver 문구에 autopilot 줄 없음"

# 6) 조회 실패는 unknown 이다 (세션 부재로 단정하지 않는다)
cat > "$STUB/herdr" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$1 $2" == "agent get" ]] && exit 3
echo '{"result":{"pane":{"id":"wX:p9"}}}'
STUBEOF
chmod +x "$STUB/herdr"
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 session_probe alpha 2>/dev/null)"
[[ "$out" == "unknown" ]] && pass "조회 실패는 unknown" || fail "조회 실패 판정: $out"

# 7) 무응답은 유한 시간 안에 unknown 으로 끝난다 (이 머신에 timeout 명령이 없다)
cat > "$STUB/herdr" <<'STUBEOF'
#!/usr/bin/env bash
exec sleep 30
STUBEOF
chmod +x "$STUB/herdr"
# 판정 기준은 「대역의 30초를 다 기다리지 않았다」 이다. 상한 2초에 10초 기준을 두면 부하에서 간헐 FAIL 했다.
# 대역 대기보다 넉넉히 짧은 25초로 본다(정상 경로는 약 2초라 시간 비용은 늘지 않는다).
start=$SECONDS
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_LAUNCH_TIMEOUT=2 session_probe alpha 2>/dev/null)"
elapsed=$((SECONDS-start))
[[ "$out" == "unknown" && "$elapsed" -lt 25 ]] \
  && pass "무응답이 유한 시간 안에 unknown 으로 끝난다" || fail "타임아웃: $out/${elapsed}s"

# 8) 살아 있는 세션이 다른 작업을 맡고 있으면 대상 불일치로 본다
cat > "$STUB/herdr" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$1 $2" == "agent get" ]] && { echo '{"result":{"agent":{"cwd":"/other/wt"},"type":"agent_info"}}'; exit 0; }
STUBEOF
chmod +x "$STUB/herdr"
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 session_probe alpha /tmp/wt 2>/dev/null)"
[[ "$out" == "dead" ]] && pass "대상 불일치 세션은 dead 다(다른 작업의 세션)" || fail "대상 불일치: $out"

# 13) resolve-launch 의 alive 확정도 호출 세션 거취(멈춤) 문구를 낸다.
TMP_RL="$(mktemp -d)" || { echo "test_session_launch.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP_RL" && -d "$TMP_RL" ]] || { echo "test_session_launch.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
TMP_RL2="$(mktemp -d)" || { echo "test_session_launch.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP_RL2" && -d "$TMP_RL2" ]] || { echo "test_session_launch.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
TMP_RL="$(cd -P "$TMP_RL" && pwd -P)"
TMP_RL2="$(cd -P "$TMP_RL2" && pwd -P)"
git -C "$TMP_RL" init -q
git -C "$TMP_RL2" init -q
mkdir -p "$TMP_RL/rd-workflow-workspace/.lifecycle" "$TMP_RL2/rd-workflow-workspace/.lifecycle"

if (
  cd "$TMP_RL" || exit 1
  export project_root="$TMP_RL"
  source "$SCRIPT_DIR/../_task_common.sh" || exit 1
  _common="$(git -C "$project_root" rev-parse --path-format=absolute --git-common-dir)"
  [[ "$_common" == "$TMP_RL/.git" ]] || { echo "project_root 격리 실패: $_common" >&2; exit 1; }
  tasks_index_upsert rl-alpha launch=unknown worktree-path="$TMP_RL"
); then
  pass "alive 테스트가 쓰기 직전 격리를 같은 실행 안에서 검증하고 임시 repo1 에만 쓴다"
else
  fail "project_root 주입/격리 검증 실패 — repo1 쓰기 서브셸이 비정상 종료"
fi

if (
  cd "$TMP_RL2" || exit 1
  export project_root="$TMP_RL2"
  source "$SCRIPT_DIR/../_task_common.sh" || exit 1
  tasks_index_upsert rl-beta launch=unknown worktree-path="$TMP_RL2"
); then
  :
else
  fail "repo2 fixture 준비 서브셸이 비정상 종료(rl-beta 심기 실패)"
fi
_pos="$(
  cd "$TMP_RL2" || exit 1
  export project_root="$TMP_RL2"
  source "$SCRIPT_DIR/../_task_common.sh" || exit 1
  tasks_index_get rl-beta launch 2>/dev/null
)"
[[ "$_pos" == "unknown" ]] \
  && pass "repo2 fixture 가 정상 기록됐다(rl-beta=unknown)" \
  || fail "repo2 fixture 준비 실패 — rl-beta 를 못 읽음: $_pos"

_leak="$(
  cd "$TMP_RL" || exit 1
  export project_root="$TMP_RL"
  source "$SCRIPT_DIR/../_task_common.sh" || exit 1
  tasks_index_get rl-beta launch 2>/dev/null || true
)"
[[ -z "$_leak" ]] \
  && pass "repo2 에 심은 행이 repo1 색인으로 새지 않는다(대상 격리 확인)" \
  || fail "repo 간 색인이 섞였다 — repo1 에서 rl-beta 조회됨: $_leak"

cat > "$STUB/herdr" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get") echo '{"result":{"agent":{"cwd":"'"$PWD"'"},"type":"agent_info"}}' ;;
  "agent prompt") exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/herdr"
rl_out="$(cd "$TMP_RL" && PATH="$STUB:$PATH" HERDR_ENV=1 project_root="$TMP_RL" bash -c '
  source "'"$SCRIPT_DIR"'/../_task_common.sh" || exit 1
  _common="$(git -C "$project_root" rev-parse --path-format=absolute --git-common-dir)"
  [[ "$_common" == "'"$TMP_RL"'/.git" ]] || { echo "project_root 격리 실패: $_common" >&2; exit 1; }
  task_resolve_launch rl-alpha
' 2>&1)" || true
[[ "$rl_out" == *"멈춥니다"* ]] \
  && pass "resolve-launch(alive 확정)가 호출 세션 거취(멈춤) 문구를 출력한다" \
  || fail "resolve-launch alive 출력에 거취 문구 없음: $rl_out"
# 13-1) agent prompt 가 실패하면 수동 안내 문구에도 인계 파일 경로가 실린다
cat > "$STUB/herdr" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get") echo '{"result":{"agent":{"cwd":"'"$PWD"'"},"type":"agent_info"}}' ;;
  "agent prompt") exit 1 ;;
esac
STUBEOF
chmod +x "$STUB/herdr"
: > "$TMP_RL/rd-workflow-workspace/.lifecycle/handoff.md"
# 앞 확정으로 launch=ok 가 됐으므로 다시 unknown 으로 되돌린다
(cd "$TMP_RL" && project_root="$TMP_RL" bash -c 'source "'"$SCRIPT_DIR"'/../_task_common.sh" && tasks_index_upsert rl-alpha launch=unknown') \
  || fail "13-1 fixture 되돌리기 실패"
rl_out="$(cd "$TMP_RL" && PATH="$STUB:$PATH" HERDR_ENV=1 project_root="$TMP_RL" bash -c '
  source "'"$SCRIPT_DIR"'/../_task_common.sh" || exit 1
  task_resolve_launch rl-alpha
' 2>&1)" || true
[[ "$rl_out" == *"$TMP_RL/rd-workflow-workspace/.lifecycle/handoff.md"* ]] \
  && pass "resolve-launch 수동 문구에 인계 경로" || fail "resolve-launch 수동 문구에 인계 경로: $rl_out"
# 13-2) stalled 판정도 resolve-launch 경로가 그대로 공유한다 (agent get 은 alive)
cat > "$STUB/herdr" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get") echo '{"result":{"agent":{"cwd":"'"$PWD"'"},"type":"agent_info"}}' ;;
  "agent prompt") echo '{"error":{"code":"agent_prompt_stalled","message":"x"}}' >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUB/herdr"
(cd "$TMP_RL" && project_root="$TMP_RL" bash -c 'source "'"$SCRIPT_DIR"'/../_task_common.sh" && tasks_index_upsert rl-alpha launch=unknown') \
  || fail "13-2 fixture 되돌리기 실패"
rl_out="$(cd "$TMP_RL" && PATH="$STUB:$PATH" HERDR_ENV=1 project_root="$TMP_RL" bash -c '
  source "'"$SCRIPT_DIR"'/../_task_common.sh" || exit 1
  task_resolve_launch rl-alpha
  tasks_index_get rl-alpha launch
' 2>&1)" || true
[[ "$rl_out" == *"입력창에 문구가 남아 있으면 Enter"* && "${rl_out##*$'\n'}" == "ok" ]] \
  && pass "resolve-launch: stalled → launch=ok 유지 + 화면 먼저 확인 안내" || fail "13-2 stalled 공유: $rl_out"
[[ "$rl_out" == *"입력창이 비어 있고 작업도 없을 때만 아래 문구를 붙여 넣으십시오"* && "$rl_out" != *"직접 지시해 주십시오"* ]] \
  && pass "resolve-launch: 제출 여부를 모르면 직접 지시를 권하지 않고 조건부 붙여 넣기만 안내한다" || fail "13-2 무조건 직접 지시 안내: $rl_out"
# 13-3) 보내지 않았음이 확실하면(agent_blocked) 직접 지시 안내 + 수동 문구에 autopilot 줄(표식 check 0)
cat > "$STUB/herdr" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "agent get") echo '{"result":{"agent":{"cwd":"'"$PWD"'"},"type":"agent_info"}}' ;;
  "agent prompt") echo '{"error":{"code":"agent_blocked","message":"x"}}' >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUB/herdr"
mkdir -p "$TMP_RL/rd-workflow/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_RL/rd-workflow/scripts/autopilot_driver.sh"
(cd "$TMP_RL" && project_root="$TMP_RL" bash -c 'source "'"$SCRIPT_DIR"'/../_task_common.sh" && tasks_index_upsert rl-alpha launch=unknown') \
  || fail "13-3 fixture 되돌리기 실패"
rl_out="$(cd "$TMP_RL" && PATH="$STUB:$PATH" HERDR_ENV=1 project_root="$TMP_RL" bash -c '
  source "'"$SCRIPT_DIR"'/../_task_common.sh" || exit 1
  task_resolve_launch rl-alpha
' 2>&1)" || true
[[ "$rl_out" == *"직접 지시해 주십시오"* && "$rl_out" != *"이미 입력됐을 수 있습니다"* ]] \
  && pass "resolve-launch: 보내지 않았음이 확실하면 직접 지시를 안내한다" || fail "13-3 agent_blocked 안내: $rl_out"
[[ "$rl_out" == *"autopilot: 이 작업은 autopilot 으로 진행합니다."* ]] \
  && pass "resolve-launch 수동 문구에 autopilot 줄(표식 check 0)" || fail "13-3 수동 문구 autopilot 줄 없음: $rl_out"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_RL/rd-workflow/scripts/autopilot_driver.sh"
(cd "$TMP_RL" && project_root="$TMP_RL" bash -c 'source "'"$SCRIPT_DIR"'/../_task_common.sh" && tasks_index_upsert rl-alpha launch=unknown') \
  || fail "13-3 fixture 되돌리기 실패(2)"
rl_out="$(cd "$TMP_RL" && PATH="$STUB:$PATH" HERDR_ENV=1 project_root="$TMP_RL" bash -c '
  source "'"$SCRIPT_DIR"'/../_task_common.sh" || exit 1
  task_resolve_launch rl-alpha
' 2>&1)" || true
[[ "$rl_out" != *"autopilot: 이 작업은"* ]] \
  && pass "resolve-launch 수동 문구에 autopilot 줄 없음(표식 check 1)" || fail "13-3 check 1 인데 autopilot 줄: $rl_out"
rm -rf "$TMP_RL" "$TMP_RL2"

# 13-4) resolve-launch 의 failed 갈래 — 손으로 띄운 세션(이름이 slug 가 아님)을 cwd 관측으로 확정한다.
#   관측 경계(herdr·ps·lsof)를 stub 으로 고정해 이 맥의 실제 herdr·claude 프로세스를 보지 않는다.
RF="$TMP/rf-repo"; mkdir -p "$RF"; RF="$(cd -P "$RF" && pwd -P)"
git -C "$RF" init -q
mkdir -p "$RF/rd-workflow-workspace/.lifecycle"
RF_BIN="$TMP/rf-bin"; mkdir -p "$RF_BIN"
cat > "$RF_BIN/herdr" <<STUBEOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent get") echo '{"error":{"code":"agent_not_found","message":"x"}}' >&2; exit 1 ;;
  "agent list") cat "$RF_BIN/list.data" ;;
  "agent prompt") printf '%s\n' "\$*" >> "$RF_BIN/prompt.log"; exit 0 ;;
esac
STUBEOF
printf '#!/usr/bin/env bash\ncat "%s/ps.data"\n' "$RF_BIN" > "$RF_BIN/ps"
printf '#!/usr/bin/env bash\ncat "%s/lsof.data"\n' "$RF_BIN" > "$RF_BIN/lsof"
chmod +x "$RF_BIN/herdr" "$RF_BIN/ps" "$RF_BIN/lsof"
# rf_case <agent-list-json> <ps 출력> <lsof 출력> — 관측 데이터와 색인(launch=failed)을 초기화한다
rf_case() {
  printf '%s\n' "$1" > "$RF_BIN/list.data"
  printf '%s' "$2" > "$RF_BIN/ps.data"
  printf '%s' "$3" > "$RF_BIN/lsof.data"
  : > "$RF_BIN/prompt.log"
  (cd "$RF" && project_root="$RF" bash -c 'source "'"$SCRIPT_DIR"'/../_task_common.sh" && tasks_index_upsert rf-x launch=failed launch-backend=herdr worktree-path="'"$RF"'"') \
    || fail "13-4 fixture 준비 실패"
}
# rf_run <env 인자...> -- <resolve-launch 추가 인자...> — 출력 끝 두 줄은 rc=<n> 과 색인 launch 값
rf_run() {
  local envs=() args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  args=("$@")
  (cd "$RF" && env ${envs[@]+"${envs[@]}"} PATH="$RF_BIN:$PATH" project_root="$RF" bash -c '
    source "'"$SCRIPT_DIR"'/../_task_common.sh" || exit 9
    task_resolve_launch rf-x "$@"; echo "rc=$?"
    tasks_index_get rf-x launch
  ' _ ${args[@]+"${args[@]}"} 2>&1) || true
}
rf_case '{"result":{"agents":[{"cwd":"'"$RF"'"}]}}' '' ''
rf_out="$(rf_run -u HC_TERMINAL_ID HERDR_ENV=1 --)"
[[ "$rf_out" == *$'\nrc=0\nok' && "$rf_out" == *"launch=ok 로 확정"* && ! -s "$RF_BIN/prompt.log" ]] \
  && pass "resolve-launch failed: herdr 에이전트 cwd 로 살아 있으면 ok" \
  || fail "resolve-launch failed: herdr 에이전트 cwd 로 살아 있으면 ok: $rf_out / prompt=$(cat "$RF_BIN/prompt.log")"
rf_case '{"result":{"agents":[]}}' $'4242 claude\n' "p4242"$'\n'"n$RF"$'\n'
rf_out="$(rf_run -u HERDR_ENV -u HC_TERMINAL_ID --)"
[[ "$rf_out" == *$'\nrc=0\nok' && "$rf_out" == *"claude 프로세스 cwd 일치"* ]] \
  && pass "resolve-launch failed: herdr 밖에서 claude 프로세스 cwd 로 살아 있으면 ok" \
  || fail "resolve-launch failed: herdr 밖에서 claude 프로세스 cwd 로 살아 있으면 ok: $rf_out"
rf_case '{"result":{"agents":[]}}' '' ''
rf_out="$(rf_run -u HC_TERMINAL_ID HERDR_ENV=1 --)"
[[ "$rf_out" == *$'\nrc=1\nfailed' && "$rf_out" == *"failed 를 유지"* && "$rf_out" == *"수동 기동: cd "* ]] \
  && pass "resolve-launch failed: 확인 못하면 failed 유지" \
  || fail "resolve-launch failed: 확인 못하면 failed 유지: $rf_out"
rf_case '{"result":{"agents":[{"cwd":"'"$RF"'"}]}}' '' ''
rf_out="$(rf_run -u HC_TERMINAL_ID HERDR_ENV=1 -- --assume-ended)"
[[ "$rf_out" == *$'\nrc=1\nfailed' && "$rf_out" == *"이미 기동 실패(failed)"* ]] \
  && pass "resolve-launch failed --assume-ended 거부" \
  || fail "resolve-launch failed --assume-ended 거부: $rf_out"

# 14) session_launch_model_valid — 별칭·구체 id 는 허용, 형식 밖 값은 anchored 검증으로 거부한다
session_launch_model_valid opus && pass "별칭 opus 허용" || fail "별칭 opus 거부됨"
session_launch_model_valid claude-sonnet-5 && pass "구체 id 허용" || fail "구체 id 거부됨"
session_launch_model_valid not-a-model && fail "허용 범위 밖 값이 통과함" || pass "허용 범위 밖 값 거부"
session_launch_model_valid 'claude-x invalid value' && fail "공백 섞인 값이 통과함(F5 재발)" || pass "공백 섞인 값 거부"
session_launch_model_valid 'claude-x/garbage' && fail "슬래시 섞인 값이 통과함(F5 재발)" || pass "슬래시 섞인 값 거부"
session_launch_model_valid 'fable-' && fail "빈 접미부(fable-)가 통과함(F5 재발)" || pass "빈 접미부 거부"

# 15) session_launch_model — 우선순위: env > config > 세션 상속 > default, 필드 순서는 source가 먼저다(F2)
# 이 스위트를 Claude 세션 안에서 돌리면 상속 경로가 실제 transcript 를 타 결과가 환경에
# 따라 갈린다. 상속을 직접 검사하는 구간 외에는 세션 식별자를 비워 hermetic 하게 만든다.
export CLAUDE_CODE_SESSION_ID=""
mkdir -p "$TMP/wt/rd-workflow/config"
cat > "$TMP/wt/rd-workflow/config/model-strategy.json" <<'JSON'
{"version": 1, "subagent": "sonnet", "session_model": "haiku"}
JSON
out="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'config\thaiku' ]] && pass "config 값 채택(env 없음), source가 먼저" || fail "config 채택: $out"
out="$(RD_SESSION_MODEL=opus session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'env\topus' ]] && pass "env 가 config 보다 우선" || fail "env 우선: $out"
out="$(RD_SESSION_MODEL=bogus session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' ]] && pass "env 값이 허용 범위 밖이면 default(config 는 보지 않음), 빈 model 필드가 보존된다" || fail "env 무효 처리: $out"

rm -rf "$TMP/wt/rd-workflow/config"
out="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' ]] && pass "설정 파일 없으면 default(경고 없음)" || fail "파일 없음 처리: $out"

mkdir -p "$TMP/wt/rd-workflow/config"
printf '{not valid json' > "$TMP/wt/rd-workflow/config/model-strategy.json"
err="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>&1 >/dev/null)"
out="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' && -n "$err" ]] && pass "손상된 설정은 경고 후 default" || fail "손상 처리: out=$out err=$err"

printf '{"nested":{"session_model":"haiku"}}' > "$TMP/wt/rd-workflow/config/model-strategy.json"
out="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' ]] && pass "중첩된 키는 최상위 키로 오인하지 않는다(F4 재발 방지)" || fail "중첩 키 오인: $out"

printf '{"session_model": 5}' > "$TMP/wt/rd-workflow/config/model-strategy.json"
out="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' ]] && pass "문자열이 아닌 값은 키 없음과 동일 처리(F4)" || fail "타입 오류 처리: $out"

printf '[1,2,3]' > "$TMP/wt/rd-workflow/config/model-strategy.json"
err="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>&1 >/dev/null)"
out="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' && -n "$err" ]] && pass "최상위가 object 가 아니면 손상과 동일하게 경고한다(F4)" || fail "비-object 최상위 처리: out=$out err=$err"

printf '{"session_model":"opus"} {}' > "$TMP/wt/rd-workflow/config/model-strategy.json"
err="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>&1 >/dev/null)"
out="$(RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' && -n "$err" ]] \
  && pass "파일 하나에 JSON 문서가 두 개면 손상으로 취급한다(F4 turn 004 재발 방지)" \
  || fail "복수 JSON 문서를 정상 채택함(F4 재발): out=$out err=$err"
rm -rf "$TMP/wt/rd-workflow"

# 15b) 세션 상속 — 명시 설정이 없을 때만, transcript 의 마지막 유효 모델을 집는다
_mk_transcript() {  # <session-id> <줄...> — $TMP/home 아래 가짜 transcript 를 만든다
  local sid="$1"; shift
  local dir="$TMP/home/.claude/projects/-fake-project"
  mkdir -p "$dir"
  : > "$dir/$sid.jsonl"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$dir/$sid.jsonl"; done
}
_inherit_model() {  # <session-id> → session_launch_model 출력
  HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" \
    CLAUDE_CODE_SESSION_ID="$1" RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null
}

rm -rf "$TMP/home"
_mk_transcript sid-a \
  '{"type":"assistant","message":{"model":"claude-sonnet-5"}}' \
  '{"type":"user","message":{"role":"user"}}' \
  '{"type":"assistant","message":{"model":"claude-opus-5"}}'
out="$(_inherit_model sid-a)"
[[ "$out" == $'inherit\tclaude-opus-5' ]] \
  && pass "설정이 없으면 transcript 의 마지막 모델을 상속한다" || fail "상속 실패: $out"

out="$(HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" \
  CLAUDE_CODE_SESSION_ID=sid-a RD_SESSION_MODEL=haiku session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'env\thaiku' ]] && pass "env 가 상속보다 우선" || fail "env 우선(상속): $out"

mkdir -p "$TMP/wt/rd-workflow/config"
printf '{"session_model":"fable"}' > "$TMP/wt/rd-workflow/config/model-strategy.json"
out="$(_inherit_model sid-a)"
[[ "$out" == $'config\tfable' ]] && pass "config 가 상속보다 우선" || fail "config 우선(상속): $out"
rm -rf "$TMP/wt/rd-workflow"

# `<synthetic>` 은 모든 세션에 1건씩 섞여 있다 — 유효성 검사에서 탈락해야 한다
_mk_transcript sid-b '{"type":"assistant","message":{"model":"<synthetic>"}}'
out="$(_inherit_model sid-b)"
[[ "$out" == $'default\t' ]] && pass "<synthetic> 만 있으면 상속하지 않는다" || fail "<synthetic> 채택됨: $out"

# subagent 행이 섞여 들어와도(방어적) 부모 모델을 덮지 않는다
_mk_transcript sid-c \
  '{"type":"assistant","message":{"model":"claude-opus-5"}}' \
  '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001"}}'
out="$(_inherit_model sid-c)"
[[ "$out" == $'inherit\tclaude-opus-5' ]] \
  && pass "sidechain 행은 상속 대상에서 제외한다" || fail "sidechain 채택됨: $out"

# 쓰이는 중이라 잘린 마지막 줄은 건너뛰고 그 앞의 유효 값을 쓴다
_mk_transcript sid-d \
  '{"type":"assistant","message":{"model":"claude-opus-5"}}' \
  '{"type":"assistant","message":{"mod'
out="$(_inherit_model sid-d)"
[[ "$out" == $'inherit\tclaude-opus-5' ]] \
  && pass "잘린 마지막 줄은 건너뛴다" || fail "잘린 줄 처리: $out"

out="$(HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" \
  CLAUDE_CODE_SESSION_ID= RD_SESSION_MODEL= session_launch_model "$TMP/wt" 2>/dev/null)"
[[ "$out" == $'default\t' ]] && pass "세션 식별자가 없으면 상속하지 않는다" || fail "식별자 없음: $out"

out="$(_inherit_model sid-none)"
[[ "$out" == $'default\t' ]] && pass "transcript 가 없으면 상속하지 않는다" || fail "글롭 0건: $out"

# 같은 세션 ID 가 두 프로젝트에 있으면 어느 쪽인지 정할 수 없다 — 판정을 포기한다
mkdir -p "$TMP/home/.claude/projects/-other-project"
cp "$TMP/home/.claude/projects/-fake-project/sid-a.jsonl" \
   "$TMP/home/.claude/projects/-other-project/sid-a.jsonl"
out="$(_inherit_model sid-a)"
[[ "$out" == $'default\t' ]] && pass "transcript 가 2건이면 상속하지 않는다" || fail "글롭 2건: $out"
rm -rf "$TMP/home"

# 16) 수동 기동 명령에 모델이 반영된다(인자 없이 호출 — 자체 계산 경로)
mkdir -p "$TMP/wt/rd-workflow/config"
cat > "$TMP/wt/rd-workflow/config/model-strategy.json" <<'JSON'
{"version": 1, "session_model": "opus"}
JSON
cmd="$(session_launch_command "$TMP/wt" alpha)"
[[ "$cmd" == *"--model opus"* ]] && pass "수동 명령에 --model 반영(자체 계산)" || fail "수동 명령 모델: $cmd"
rm -rf "$TMP/wt/rd-workflow"
cmd="$(session_launch_command "$TMP/wt" alpha)"
[[ "$cmd" != *"--model"* ]] && pass "미지정이면 --model 을 붙이지 않는다" || fail "미지정인데 --model 붙음: $cmd"

# 17) 3번째 인자로 모델을 직접 넘기면 재계산하지 않는다(F3 — 호출자 우선)
cmd="$(session_launch_command "$TMP/wt" alpha haiku)"
[[ "$cmd" == *"--model haiku"* ]] && pass "3번째 인자로 넘긴 모델을 그대로 쓴다" || fail "인자 전달: $cmd"

# 18) 자동 기동(herdr)도 같은 모델을 agent start 인자에 싣는다
mkdir -p "$TMP/wt/rd-workflow/config"
cat > "$TMP/wt/rd-workflow/config/model-strategy.json" <<'JSON'
{"version": 1, "session_model": "haiku"}
JSON
make_stub 0 0 0
: "$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch "$TMP/wt" alpha REQUEST.md 2>/dev/null)"
start_call="$(grep '^agent start' "$STUB/calls.log" || true)"
[[ "$start_call" == *"-- --model haiku"* ]] \
  && pass "자동 기동 agent start 에 -- --model 반영(자체 계산)" || fail "자동 기동 모델: $start_call"

# 19) session_launch 에 모델을 4번째 인자로 직접 넘기면 재계산하지 않는다(F3)
make_stub 0 0 0
rm -rf "$TMP/wt/rd-workflow"
: "$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch "$TMP/wt" alpha REQUEST.md opus 2>/dev/null)"
start_call="$(grep '^agent start' "$STUB/calls.log" || true)"
[[ "$start_call" == *"-- --model opus"* ]] \
  && pass "session_launch 4번째 인자로 넘긴 모델을 그대로 쓴다(설정 파일 없어도)" || fail "인자 전달: $start_call"

# 20) 경고가 stderr 로 그대로 나온다(2>/dev/null 로 버리지 않는다 — F3)
mkdir -p "$TMP/wt/rd-workflow/config"
printf '{"session_model": "bad value"}' > "$TMP/wt/rd-workflow/config/model-strategy.json"
err="$(session_launch_command "$TMP/wt" alpha 2>&1 >/dev/null)"
[[ -n "$err" ]] && pass "session_launch_command 가 잘못된 설정 경고를 stderr 로 낸다" || fail "경고가 사라짐"
rm -rf "$TMP/wt/rd-workflow"

# 8-1) session_probe 판정표 (spec D3) — 실제 herdr 응답 스키마(2026-10-29 실측)로 검사한다.
#      성공은 stdout 의 단수 `result.agent`, 실패는 stderr 의 `{"error":{"code":..}}` + rc=1 이다.
probe_case() {  # <이름> <기대> <rc> <stdout> <stderr> [<worktree>]
  local _name="$1" _want="$2" _rc="$3" _so="$4" _se="$5" _wt="${6-}"
  printf '%s' "$_so" > "$STUB/get.out"; printf '%s' "$_se" > "$STUB/get.err"
  cat > "$STUB/herdr" <<STUBEOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "agent get" ]] || exit 0
cat "$STUB/get.out"; cat "$STUB/get.err" >&2; exit $_rc
STUBEOF
  chmod +x "$STUB/herdr"
  local _got; _got="$(PATH="$STUB:$PATH" HERDR_ENV=1 session_probe alpha $_wt 2>/dev/null)"
  [[ "$_got" == "$_want" ]] && pass "probe: $_name → $_want" || fail "probe: $_name — 기대 $_want, 실제 $_got"
}
OKJ='{"id":"x","result":{"agent":{"agent":"claude","cwd":"/w/a","foreground_cwd":"/zz"},"type":"agent_info"}}'
probe_case "A1 cwd 일치" alive 0 "$OKJ" "" /w/a
probe_case "A2 worktree 생략(유효 응답)" alive 0 "$OKJ" ""
probe_case "A3 cwd 불일치" dead 0 "$OKJ" "" /w/other
probe_case "A4 구조화 agent_not_found" dead 1 "" '{"error":{"code":"agent_not_found","message":"m"},"id":"x"}'
probe_case "A5 다른 오류 코드" unknown 1 "" '{"error":{"code":"internal_error","message":"agent_not_found?"}}'
probe_case "(a) 잘린 JSON(정상 패턴 잔존)" unknown 0 '{"result":{"agent":{"cwd":"/w/a"}' "" /w/a
probe_case "(b) 다른 위치의 agent" unknown 0 '{"result":{"agent":null},"metadata":{"agent":{"cwd":"/w/a"}}}' "" /w/a
probe_case "(c) cwd 가 숫자" unknown 0 '{"result":{"agent":{"cwd":7}}}' "" /w/a
probe_case "(d) worktree 있는데 cwd 누락" unknown 0 '{"result":{"agent":{"name":"x"}}}' "" /w/a
probe_case "(e) 잘린 오류 JSON" unknown 1 "" '{"error":{"code":"agent_not_found"'
probe_case "(f) error.code 가 객체" unknown 1 "" '{"error":{"code":{"agent_not_found":1}}}'
probe_case "agents 배열(옛 스키마)은 알 수 없는 응답" unknown 0 '{"result":{"agents":[{"cwd":"/w/a"}]}}' "" /w/a
# P) python3 가 없으면 유효 응답도 확정하지 않는다
(
  command() { if [[ "${1-}" == "-v" && "${2-}" == "python3" ]]; then return 1; fi; builtin command "$@"; }
  printf '%s' "$OKJ" > "$STUB/get.out"; : > "$STUB/get.err"
  got="$(PATH="$STUB:$PATH" HERDR_ENV=1 session_probe alpha /w/a 2>/dev/null)"
  [[ "$got" == "unknown" ]] && exit 0 || { echo "python3 부재 판정: $got" >&2; exit 1; }
) && pass "probe: P python3 부재 → unknown" || fail "probe: P python3 부재는 unknown 이어야 한다"

# 8-2) agent start 의 오류 JSON 은 stderr 로 나온다(실측). stderr-only 여도 판정이 같아야 한다.
mk_start_stub() {  # <stderr-json> <rc>
  printf '%s' "$1" > "$STUB/start.err"
  : > "$STUB/calls.log"
  cat > "$STUB/herdr" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB/calls.log"
case "\$1 \$2" in
  "tab create") echo '{"result":{"root_pane":{"pane_id":"wX:p9","tab_id":"wX:t9"},"tab":{"tab_id":"wX:t9"}}}' ;;
  "agent start") cat "$STUB/start.err" >&2; exit $2 ;;
  "agent prompt") exit 0 ;;
  "tab close") exit 0 ;;
esac
STUBEOF
  chmod +x "$STUB/herdr"
}
mk_start_stub '{"error":{"code":"agent_not_ready","message":"blocked"}}' 1
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == "unknown" ]] && pass "start: S1 stderr 로만 낸 agent_not_ready 는 unknown" || fail "start: S1 판정: $out"
grep -q '^tab close' "$STUB/calls.log" && fail "start: S1 blocked 세션의 tab 을 닫았다" || pass "start: S1 blocked 세션의 tab 은 닫지 않는다"
mk_start_stub '{"error":{"code":"agent_pane_not_found","message":"pane gone"}}' 1
err="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>&1 >"$TMP/launch.out")"
out="$(cat "$TMP/launch.out")"
[[ "$out" == "failed" ]] && pass "start: S2 다른 오류 코드(rc=1)는 failed" || fail "start: S2 판정: $out"
[[ "$err" == *"agent start 응답(rc=1)"*"agent_pane_not_found"* ]] \
  && pass "start: S3 실패 응답 본문을 stderr 로 남긴다" || fail "start: S3 진단 출력 없음: $err"
[[ "$(grep -c '^agent start' "$STUB/calls.log")" -eq 1 ]] \
  && pass "start: S2 busy 가 아닌 오류는 다시 부르지 않는다" || fail "start: S2 agent start 호출 수: $(grep -c '^agent start' "$STUB/calls.log")"

# 8-3) `agent_pane_busy` 재시도 (promote-launch-race). 새 tab 셸이 시작 스크립트의 자식 프로세스를
#      포그라운드로 돌리는 순간 herdr 가 이 코드로 거부한다(2026-11-06 실측). 같은 pane 으로 다시 부른다.
#   mk_seq_stub <spec>... — agent start 를 부를 때마다 다음 spec 을 쓴다(마지막 spec 은 반복).
#   busy=stderr busy+rc1, busyout=stdout busy+rc1, ok=rc0, notready=stderr agent_not_ready+rc1,
#   timeout=rc124, busy124=stderr busy+rc124, slowok=4초 뒤 rc0
mk_seq_stub() {
  : > "$STUB/calls.log"; printf '0' > "$STUB/seq.n"; printf '%s\n' "$@" > "$STUB/seq.list"
  cat > "$STUB/herdr" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB/calls.log"
busy='{"error":{"code":"agent_pane_busy","message":"agent target pane wX:p9 is not an available shell"}}'
case "\$1 \$2" in
  "tab create") echo '{"result":{"root_pane":{"pane_id":"wX:p9","tab_id":"wX:t9"},"tab":{"tab_id":"wX:t9"}}}' ;;
  "agent start")
    n=\$(cat "$STUB/seq.n"); printf '%s' "\$((n + 1))" > "$STUB/seq.n"
    total=\$(wc -l < "$STUB/seq.list"); idx=\$((n + 1)); (( idx > total )) && idx=\$total
    case "\$(sed -n "\${idx}p" "$STUB/seq.list")" in
      busy) printf '%s' "\$busy" >&2; exit 1 ;;
      busyout) printf '%s' "\$busy"; exit 1 ;;
      ok) exit 0 ;;
      notready) echo '{"error":{"code":"agent_not_ready","message":"blocked"}}' >&2; exit 1 ;;
      timeout) exit 124 ;;
      busy124) printf '%s' "\$busy" >&2; exit 124 ;;
      slowok) sleep 4; exit 0 ;;
    esac ;;
  "agent prompt") exit 0 ;;
  "tab close") exit 0 ;;
esac
STUBEOF
  chmod +x "$STUB/herdr"
}
_bl() { PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= session_launch /tmp/wt alpha REQUEST.md 2>"$TMP/b.err"; }
_nstart() { grep -c '^agent start' "$STUB/calls.log" || true; }
unset RD_LAUNCH_BUSY_RETRY_SECS

mk_seq_stub busy busy ok
out="$(_bl)"; err="$(cat "$TMP/b.err")"
[[ "$out" == "ok" ]] && pass "busy: B1 busy 2회 뒤 성공이면 ok" || fail "busy: B1 판정: $out"
[[ "$(_nstart)" -eq 3 && "$(grep '^agent start' "$STUB/calls.log" | sort -u | wc -l | tr -d ' ')" -eq 1 ]] \
  && pass "busy: B1 같은 인자로 3회 부른다" || fail "busy: B1 호출: $(grep '^agent start' "$STUB/calls.log")"
[[ "$(_nclose)" -eq 0 ]] && pass "busy: B1 tab 을 닫지 않는다" || fail "busy: B1 tab close $(_nclose)회"
[[ "$err" == *"최대 30초 동안 다시 시도합니다"* ]] && pass "busy: B1 재시도 시작 줄" || fail "busy: B1 시작 줄 없음: $err"
[[ "$err" == *"2회 다시 시도했습니다"* ]] && pass "busy: B1 재시도 요약 줄" || fail "busy: B1 요약 줄 없음: $err"

# B2 상한 도달 — 무한 재시도는 테스트 안의 10초 제한으로 FAIL 시킨다.
mk_seq_stub busy
# 백그라운드 서브셸은 이 파일의 set -e 를 이어받아 첫 rc≠0 에서 끝나므로 끈다(명령 치환은 이어받지 않는다).
( set +e; RD_LAUNCH_BUSY_RETRY_SECS=1 _bl > "$TMP/b2.out" ) &
_b2pid=$!; _b2i=0
while kill -0 "$_b2pid" 2>/dev/null && (( _b2i < 50 )); do sleep 0.2; _b2i=$((_b2i + 1)); done
if kill -0 "$_b2pid" 2>/dev/null; then
  kill -9 "$_b2pid" 2>/dev/null || true; wait "$_b2pid" 2>/dev/null || true
  fail "busy: B2 상한 안에 끝나지 않음(10초)"
else
  wait "$_b2pid" 2>/dev/null || true
  pass "busy: B2 상한(1초) 뒤 끝난다"
fi
out="$(cat "$TMP/b2.out")"; err="$(cat "$TMP/b.err")"
[[ "$out" == "failed" && "$(_nclose)" -eq 1 && "$err" == *"agent_pane_busy"* ]] \
  && pass "busy: B2 상한 도달은 failed·tab 닫기·마지막 응답 기록" || fail "busy: B2 out=$out close=$(_nclose) err=$err"

mk_seq_stub busy notready
out="$(_bl)"; err="$(cat "$TMP/b.err")"
[[ "$out" == "unknown" && "$(_nstart)" -eq 2 && "$(_nclose)" -eq 0 && "$err" == *"1회 다시 시도했습니다"* ]] \
  && pass "busy: B3 busy 뒤 agent_not_ready 는 unknown·tab 보존" || fail "busy: B3 out=$out start=$(_nstart) close=$(_nclose) err=$err"

mk_seq_stub busy ok
out="$(RD_LAUNCH_BUSY_RETRY_SECS=0 _bl)"; err="$(cat "$TMP/b.err")"
[[ "$out" == "failed" && "$(_nstart)" -eq 1 && "$err" != *"다시 시도합니다"* ]] \
  && pass "busy: B4 RD_LAUNCH_BUSY_RETRY_SECS=0 이면 재시도하지 않는다" || fail "busy: B4 out=$out start=$(_nstart) err=$err"

mk_seq_stub busy timeout
out="$(_bl)"; err="$(cat "$TMP/b.err")"
[[ "$out" == "unknown" && "$(_nstart)" -eq 2 && "$(_nclose)" -eq 0 && "$err" == *"1회 다시 시도했습니다"* ]] \
  && pass "busy: B5 busy 뒤 타임아웃은 unknown·tab 보존" || fail "busy: B5 out=$out start=$(_nstart) close=$(_nclose) err=$err"

mk_seq_stub busyout ok
out="$(_bl)"
[[ "$out" == "ok" && "$(_nstart)" -eq 2 ]] \
  && pass "busy: B6 stdout 으로 온 busy 도 재시도한다" || fail "busy: B6 out=$out start=$(_nstart)"

_b7() { _session_launch_timeout_secs RD_LAUNCH_BUSY_RETRY_SECS 30 0 120; }
_v="$(RD_LAUNCH_BUSY_RETRY_SECS=abc _b7 2>"$TMP/b7.err")"
[[ "$_v" == 30 && "$(cat "$TMP/b7.err")" == *"허용 범위(0~120초)"* ]] \
  && pass "busy: B7 정수 아닌 값은 경고 후 30" || fail "busy: B7 abc → $_v / $(cat "$TMP/b7.err")"
_v="$(RD_LAUNCH_BUSY_RETRY_SECS=121 _b7 2>"$TMP/b7.err")"
[[ "$_v" == 30 && "$(cat "$TMP/b7.err")" == *"허용 범위(0~120초)"* ]] \
  && pass "busy: B7 121 은 경고 후 30" || fail "busy: B7 121 → $_v / $(cat "$TMP/b7.err")"
_v="$(RD_LAUNCH_BUSY_RETRY_SECS=0 _b7 2>"$TMP/b7.err")"
[[ "$_v" == 0 && ! -s "$TMP/b7.err" ]] \
  && pass "busy: B7 0 은 경고 없이 0" || fail "busy: B7 0 → $_v / $(cat "$TMP/b7.err")"

mk_seq_stub busy slowok
out="$(RD_LAUNCH_BUSY_RETRY_SECS=3 _bl)"
[[ "$out" == "ok" && "$(_nstart)" -eq 2 && "$(_nclose)" -eq 0 ]] \
  && pass "busy: B8 창이 지난 뒤 끝난 시도의 결과(ok)를 따른다" || fail "busy: B8 out=$out start=$(_nstart) close=$(_nclose)"

mk_seq_stub busy124
out="$(_bl)"
[[ "$out" == "unknown" && "$(_nstart)" -eq 1 && "$(_nclose)" -eq 0 ]] \
  && pass "busy: B9 busy 본문이 있어도 rc=124 는 재시도 없이 unknown" || fail "busy: B9 out=$out start=$(_nstart) close=$(_nclose)"

# 9) 종료 판정용 이름·경로 경계 (resume-name Task 1)
_sl_long="abcdefghij-abcdefghij-abcdefghij-abcdefg"
[[ "$(session_agent_name "$_sl_long")" == "$(_session_launch_agent_name "$_sl_long")" && "$(session_agent_name "$_sl_long")" == "abcdefghij-abcdefghij-abcdefghij" ]] \
  && pass "session_agent_name: 40자 slug 는 기존 규칙으로 줄인다" || fail "session_agent_name: 기대 이름 불일치: $(session_agent_name "$_sl_long" 2>&1)"
_sl_in() { _session_path_in_worktree "$1" /x/wt/a /x/wt/a; }
_sl_in /x/wt/a && pass "path_in_worktree: 같은 경로는 안" || fail "path_in_worktree: 같은 경로"
_sl_in /x/wt/a/sub && pass "path_in_worktree: 하위 경로는 안" || fail "path_in_worktree: 하위 경로"
_sl_in /x/wt/ab && fail "path_in_worktree: /x/wt/ab 가 안으로 판정됨" || pass "path_in_worktree: 접두만 같은 /x/wt/ab 는 밖"
_sl_in "" && fail "path_in_worktree: 빈 경로가 안으로 판정됨" || pass "path_in_worktree: 빈 경로는 밖"

# 10) 종료 판정: 관측 상태 인자가 ok·unknown<TAB>… 가 아니면 ended 로 보지 않는다 (fail-closed)
make_stub 0 0 0
_sl_out="$(PATH="$STUB:$PATH" HERDR_ENV=1 session_ended_judge alpha "$TMP" "" "$TMP/none-a" ok "$TMP/none-p" 2>/dev/null)"
[[ "$_sl_out" == $'unknown\t관측 상태 이상' ]] \
  && pass "ended_judge: 빈 에이전트 상태는 판정 불가(관측 상태 이상)" || fail "ended_judge: 빈 에이전트 상태: $_sl_out"
_sl_out="$(PATH="$STUB:$PATH" HERDR_ENV=1 session_ended_judge alpha "$TMP" ok "$TMP/none-a" "" "$TMP/none-p" 2>/dev/null)"
[[ "$_sl_out" == $'unknown\t관측 상태 이상' ]] \
  && pass "ended_judge: 빈 프로세스 상태는 판정 불가(관측 상태 이상)" || fail "ended_judge: 빈 프로세스 상태: $_sl_out"

_sl_out="$(session_observe_name() { :; }; session_ended_judge alpha "$TMP" ok "$TMP/none-a" ok "$TMP/none-p" 2>/dev/null)"
[[ "$_sl_out" == $'unknown\t관측 상태 이상' ]] \
  && pass "ended_judge: 이름 조회 결과가 비면 판정 불가(관측 상태 이상)" || fail "ended_judge: 빈 이름 조회 결과: $_sl_out"
# 9) herdr app(hc) 백엔드 — 판정·생존 조회·인계 판정. 실제 hc 는 부르지 않고 PATH 대역만 쓴다.
#    HC_TERMINAL_ID 는 케이스마다 인라인으로 준다(이 테스트가 herdr app 안에서 돌아도 격리되게).
make_hc_stub() {  # <scenario> — `hc get` 응답은 시나리오표(spec M1~M6 실측 스키마)
  local out rc=0
  case "$1" in
    live-same)    out='{"state":"live","cwd":"/tmp/wt","turn":1,"status":{"state":"done"}}' ;;
    live-turn0)   out='{"state":"live","cwd":"/tmp/wt","turn":0,"status":null}' ;;
    live-blocked) out='{"state":"live","cwd":"/tmp/wt","turn":0,"status":{"state":"blocked"}}' ;;
    finished)     out='{"state":"finished","cwd":"/tmp/wt","turn":1,"exit_code":0}' ;;
    notfound)     out='{"error":{"kind":"not_found","message":"x"}}'; rc=3 ;;  # 실제 hc 는 오류 JSON 을 stderr 로 냄(2026-11-03 실측)
    other-cwd)    out='{"state":"live","cwd":"/tmp/other","turn":1}' ;;
    broken)       out='not json'; rc=1 ;;
  esac
  : > "$STUB/hc.log"
  printf '%s' "$out" > "$STUB/hc.out"
  cat > "$STUB/hc" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB/hc.log"
if [[ $rc -eq 0 ]]; then cat "$STUB/hc.out"; else cat "$STUB/hc.out" >&2; fi
exit $rc
STUBEOF
  chmod +x "$STUB/hc"
}

# T1) 백엔드 판정 — herdr 가 먼저, hc 는 명령이 있을 때만
make_hc_stub live-same; make_stub 0 0 0
[[ "$(HERDR_ENV= HC_TERMINAL_ID=t6 PATH="$STUB:$PATH" session_launch_backend)" == "hc" ]] \
  && pass "T1: hc 변수만 있으면 hc" || fail "backend 판정: hc 변수만"
b="$(HERDR_ENV=1 HC_TERMINAL_ID=t6 PATH="$STUB:$PATH" session_launch_backend)"
[[ "$b" == "herdr" ]] && pass "T1: 둘 다 설정 → herdr" || fail "backend 판정: $b"
b="$(HERDR_ENV= HC_TERMINAL_ID= PATH="$STUB:$PATH" session_launch_backend)"
[[ "$b" == "none" ]] && pass "T1: 둘 다 없음 → none" || fail "backend 판정: $b"
b="$(HERDR_ENV= HC_TERMINAL_ID=t6 PATH=/usr/bin:/bin session_launch_backend)"
[[ "$b" == "none" ]] && pass "T1: hc 명령 없음 → none" || fail "backend 판정: $b"

# T7) hc 생존 조회 매핑 (spec D4)
hc_probe_case() {  # <scenario> <expected>
  make_hc_stub "$1"
  local got; got="$(HERDR_ENV= HC_TERMINAL_ID=t6 PATH="$STUB:$PATH" session_probe alpha /tmp/wt hc 2>/dev/null)"
  [[ "$got" == "$2" ]] && pass "T7: hc probe $1 → $2" || fail "hc probe $1: $got"
}
hc_probe_case live-same alive
hc_probe_case finished dead
hc_probe_case notfound dead
hc_probe_case other-cwd dead
hc_probe_case broken unknown

# T8) 기록된 백엔드를 쓸 수 없으면 다른 백엔드로 조회하지 않고 unknown
make_hc_stub live-same; make_stub 0 0 0
got="$(HC_TERMINAL_ID= HERDR_ENV=1 PATH="$STUB:$PATH" session_probe alpha /tmp/wt hc 2>/dev/null)"
[[ "$got" == "unknown" && ! -s "$STUB/calls.log" && ! -s "$STUB/hc.log" ]] \
  && pass "T8: hc 를 쓸 수 없으면 unknown 이고 아무것도 부르지 않는다" || fail "다른 백엔드 조회: $got / $(cat "$STUB/calls.log" "$STUB/hc.log")"
# 백엔드 인자를 생략하면 herdr 를 부른다
make_stub 0 0 0
PATH="$STUB:$PATH" HERDR_ENV=1 HC_TERMINAL_ID=t6 session_probe alpha /tmp/wt >/dev/null 2>&1 || true
grep -q '^agent get' "$STUB/calls.log" && pass "T8: 백엔드 생략은 herdr" || fail "백엔드 생략 시 herdr 미호출"

# T9) hc 인계 판정 — 보내지 않고 처리 여부만 본다 (spec D5)
hc_deliver_case() {  # <scenario> <expected-rc> <fail-label>
  make_hc_stub "$1"
  local rc=0
  HERDR_ENV= HC_TERMINAL_ID=t6 PATH="$STUB:$PATH" session_handoff_deliver alpha /tmp/wt /tmp/wt/REQUEST.md hc >/dev/null 2>"$STUB/deliver.err" || rc=$?
  [[ "$rc" == "$2" ]] && pass "T9: hc deliver $1 → rc $2" || fail "$3 (rc=$rc)"
  # 승인·확인 안내는 tab 이름 붙이기 성패와 무관하게 찾을 수 있는 hc attach 를 담는다(final diff review F2).
  if [[ "$1" != live-same ]]; then
    grep -q 'hc attach alpha' "$STUB/deliver.err" && pass "T9: hc deliver $1 안내에 hc attach" || fail "hc attach 안내 없음 ($1): $(cat "$STUB/deliver.err")"
  fi
  grep -q 'send' "$STUB/hc.log" && fail "hc send 호출됨 ($1)" || pass "T9: hc send 미호출 ($1)"
}
hc_deliver_case live-same 0 "처리된 인계를 미전달로 판정"
hc_deliver_case live-blocked 0 "확인 대기를 미전달로 판정"
hc_deliver_case live-turn0 2 "미처리 인계를 전달됨으로 판정"
hc_deliver_case broken 2 "조회 실패를 전달됨으로 판정"

# T2~T6) hc 기동 (spec D3). 대역은 시나리오 이름 하나로 `hc run`·`hc get`·`herdr-app` 응답을 정한다.
#   hc.log = hc 호출 인자, app.log = herdr-app 호출 인자, order.log = `hc get <이름>`·`tab.rename` 호출 순서.
make_hc_launch_stub() {  # <scenario: ok|wait|exit|run-error|run-hang|rename-fail|nospace>
  : > "$STUB/hc.log"; : > "$STUB/app.log"; : > "$STUB/order.log"
  printf '%s' "$1" > "$STUB/scn"
  cat > "$STUB/hc" <<STUBEOF
#!/usr/bin/env bash
scn="\$(cat "$STUB/scn")"
printf '%s\n' "\$*" >> "$STUB/hc.log"
case "\$1" in
  get)
    printf 'hc get %s\n' "\$2" >> "$STUB/order.log"
    if [[ "\$2" == t6 ]]; then
      if [[ "\$scn" == nospace ]]; then printf '{"labels":{}}'; else printf '{"labels":{"herdr.space":"spX"}}'; fi
      exit 0
    fi
    case "\$scn" in
      wait)  printf '{"state":"live","cwd":"/tmp/wt","turn":0,"status":null}' ;;
      exit)  printf '{"state":"finished","cwd":"/tmp/wt","turn":0,"exit_code":1}' ;;
      *)     printf '{"state":"live","cwd":"/tmp/wt","turn":1,"status":{"state":"done"}}' ;;
    esac ;;
  run)
    case "\$scn" in
      run-error) printf '{"error":{"kind":"spawn_failed","message":"x"}}' >&2; exit 3 ;;
      run-name-taken) printf '{"error":{"kind":"name_taken","message":"x"}}' >&2; exit 1 ;;
      run-hang)  sleep 3 ;;
      run-addr-rc1) printf '{"address":"t9","name":"alpha","state":"live","turn":0}'; exit 1 ;;
    esac
    printf '{"address":"t9","name":"x","state":"live","turn":0}' ;;
esac
STUBEOF
  cat > "$STUB/herdr-app" <<STUBEOF
#!/usr/bin/env bash
scn="\$(cat "$STUB/scn")"
printf '%s\n' "\$*" >> "$STUB/app.log"
case "\$1" in
  ls) # 실제 herdr-app ls 는 인자를 받지 않음 — 붙이면 사용법 오류 rc=2 (2026-11-03 실측)
    [[ \$# -eq 1 ]] || { echo 'herdr-app: usage: herdr-app ls' >&2; exit 2; }
    printf '{"spaces":[{"id":"spX","tabs":[{"id":"tbZ","terminals":[{"terminal":"t9"}]}]}]}' ;;
  do)
    printf 'tab.rename\n' >> "$STUB/order.log"
    if [[ "\$scn" == rename-fail ]]; then printf '{"error":"x"}'; exit 1; fi
    printf '{"ok":true}' ;;
esac
STUBEOF
  chmod +x "$STUB/hc" "$STUB/herdr-app"
}
hc_launch() {  # <slug> [<extra env assignments...>] → stdout=결과, stderr→$STUB/err.log
  local slug="$1"; shift
  env HERDR_ENV= HC_TERMINAL_ID=t6 RD_CHILD_SESSION= PATH="$STUB:$PATH" "$@" \
    bash -c 'source "$1"; session_launch /tmp/wt "$2" /tmp/wt/REQUEST.md claude-test' _ "$SCRIPT_DIR/session_launch.sh" "$slug" 2>"$STUB/err.log"
}

make_hc_launch_stub ok
got="$(hc_launch alpha)"; runline="$(grep '^run' "$STUB/hc.log" || true)"
[[ "$got" == ok ]] && pass "T2: hc 기동 ok" || fail "hc 기동: $got"
[[ "$runline" == *"--outlive-parent"* && "$runline" == *"--cwd /tmp/wt"* && "$runline" == *"--name alpha"* \
  && "$runline" == *"--label herdr.space=spX"* && "$runline" == *"env RD_CHILD_SESSION=1 claude --model claude-test"* \
  && "$runline" == *"작업(FR): alpha"* ]] \
  && pass "T2: run 인자" || fail "hc run 인자: $runline"
grep -q -- '--id tbZ --name alpha' "$STUB/app.log" && pass "T2: tab.rename 인자" || fail "rename 인자: $(cat "$STUB/app.log")"

long="$(printf 'a%.0s' $(seq 1 33))"
make_hc_launch_stub ok; hc_launch "$long" >/dev/null
runline="$(grep '^run' "$STUB/hc.log" || true)"; ren="$(grep 'tab.rename' "$STUB/app.log" || true)"
[[ "$runline" == *"--name $(printf 'a%.0s' $(seq 1 32)) "* && "$runline" != *"--name $long"* && "$ren" == *"--name $long" ]] \
  && pass "RF3: 에이전트 이름 32자, tab 이름 slug 전체" || fail "긴 slug 이름: $runline / $ren"

make_hc_launch_stub run-error; got="$(hc_launch alpha)"
[[ "$got" == failed && "$(cat "$STUB/err.log")" == *spawn_failed* ]] \
  && pass "T3: 구조화된 run 오류는 failed" || fail "run-error: $got"
make_hc_launch_stub run-name-taken; got="$(hc_launch alpha)"
[[ "$got" == unknown && "$(cat "$STUB/err.log")" == *"hc attach"* ]] \
  && pass "T3b: 같은 이름의 live 세션(name_taken)은 unknown 과 확인 안내" || fail "name_taken: $got / $(cat "$STUB/err.log")"

make_hc_launch_stub run-hang; got="$(hc_launch alpha RD_LAUNCH_TIMEOUT=1)"
[[ "$got" == unknown ]] && pass "RF4: run 무응답은 unknown" || fail "run-hang: $got"

make_hc_launch_stub run-addr-rc1; got="$(hc_launch alpha)"
[[ "$got" == unknown && "$(cat "$STUB/err.log")" == *"resolve-launch alpha"* ]] \
  && pass "run rc≠0 이고 address 만 있으면 unknown" || fail "run-addr-rc1: $got"

make_hc_launch_stub wait; got="$(hc_launch alpha RD_LAUNCH_START_TIMEOUT=6)"; err="$(cat "$STUB/err.log")"
[[ "$got" == unknown && "$err" == *"최대 6초"* && "$err" == *"resolve-launch alpha"* ]] \
  && pass "T4: 대기 상한은 unknown 과 안내" || fail "대기 상한: $got / $err"
[[ "$(grep -n 'tab.rename' "$STUB/order.log" | head -1 | cut -d: -f1)" -lt "$(grep -n '^hc get alpha' "$STUB/order.log" | head -1 | cut -d: -f1)" ]] \
  && pass "T4: rename 이 대기보다 앞선다" || fail "rename 순서: $(cat "$STUB/order.log")"

# T4b) 조회가 느려도(40초) 안내한 상한(60초)을 넘겨 기다리지 않는다. 고치기 전에는 조회마다 상한
#      전체(RD_LAUNCH_TIMEOUT)를 써서 대기 구간이 상한을 넘었다. 실제로 기다리지 않도록 처리 조회와
#      1초 sleep 을 가짜 시계(SECONDS 증가)로 바꾼다 — 조회는 min(40초, 그 조회의 상한)만큼 흐르고,
#      상한보다 짧으면 시간 초과(124)다. 실행 약 5초(대부분 JSON 해석) — 안내와 실제 대기가 어긋나는
#      회귀를 잡는 유일한 케이스.
#      대기 길이는 가짜 시계가 더한 초(F)만 센다. SECONDS 차이로 재면 실제 경과(부하에서 JSON 해석이
#      몇 초씩 늘어남)가 섞여 간헐 FAIL 했다(FR selftest-load-sensitive-asserts-residual). 실제 경과는
#      제품의 마감 계산에도 들어가 대기를 줄이기만 하므로 F 를 늘리지 않는다. 가짜 시계 폭을 수십 초로
#      잡는 것은 실제 경과 몇 초가 회귀(두 번째 조회가 상한 전체를 씀)를 가리지 않게 하려는 것이다.
make_hc_launch_stub wait
got="$(env HERDR_ENV= HC_TERMINAL_ID=t6 RD_CHILD_SESSION= PATH="$STUB:$PATH" RD_LAUNCH_START_TIMEOUT=60 RD_LAUNCH_TIMEOUT=50 \
  bash -c 'source "$1"
    eval "_t4b_orig$(declare -f _session_launch_hc_call)"
    F=0
    sleep() { if [[ "$1" == 1 ]]; then SECONDS=$(( SECONDS + 1 )); [[ -n "${W0:-}" ]] && F=$(( F + 1 )); else command sleep "$@"; fi; }
    _session_launch_hc_call() {
      if [[ "$3" == get && "$4" == alpha ]]; then
        [[ -n "${W0:-}" ]] || W0=$SECONDS
        local d=40; (( $1 < d )) && d=$1; SECONDS=$(( SECONDS + d )); F=$(( F + d ))
        if (( $1 < 40 )); then : > "$2"; return 124; fi
        printf "{\"state\":\"live\",\"cwd\":\"/tmp/wt\",\"turn\":0,\"status\":null}" > "$2"; return 0
      fi
      _t4b_orig_session_launch_hc_call "$@"
    }
    session_launch /tmp/wt alpha /tmp/wt/REQUEST.md claude-test >"$2/t4b.out" 2>/dev/null
    printf "%s %s\n" "$(cat "$2/t4b.out")" "$F"' _ "$SCRIPT_DIR/session_launch.sh" "$STUB")"
[[ "${got% *}" == unknown && "${got#* }" -le 61 ]] \
  && pass "T4b: 느린 조회에서도 대기 상한(60초)을 지킨다" || fail "느린 조회 대기: $got"

make_hc_launch_stub exit; got="$(hc_launch alpha)"
[[ "$got" == failed ]] && pass "T5: 즉시 종료는 failed" || fail "exit: $got"

make_hc_launch_stub rename-fail; got="$(hc_launch alpha)"
[[ "$got" == ok && "$(cat "$STUB/err.log")" == *"hc attach alpha"* ]] \
  && pass "T6: rename 실패는 ok 와 경고" || fail "rename-fail: $got / $(cat "$STUB/err.log")"

make_hc_launch_stub nospace; got="$(hc_launch alpha)"
[[ "$got" == ok && "$(grep '^run' "$STUB/hc.log" || true)" != *"--label"* && "$(cat "$STUB/err.log")" == *"hc attach"* ]] \
  && pass "RF2: space 없으면 라벨 없이 ok 와 경고" || fail "nospace: $got / $(grep '^run' "$STUB/hc.log")"

make_hc_launch_stub ok
got="$(HERDR_ENV= HC_TERMINAL_ID=t6 RD_CHILD_SESSION=1 PATH="$STUB:$PATH" session_launch /tmp/wt alpha /tmp/wt/REQUEST.md claude-test 2>/dev/null)"
[[ "$got" == none && ! -s "$STUB/hc.log" ]] && pass "깊이 1: hc 를 부르지 않는다" || fail "자식 세션 hc 호출: $got"
got="$(HERDR_ENV= HC_TERMINAL_ID=t6 RD_CHILD_SESSION= PATH="$STUB:$PATH" session_launch /tmp/wt alpha /tmp/wt/REQUEST.md "" none 2>/dev/null)"
[[ "$got" == none && ! -s "$STUB/hc.log" ]] && pass "5번째 인자가 판정을 대신한다" || fail "넘긴 백엔드 무시: $got"

# ---- 탭 id 메타 출력·탭 닫기 판정·호출 세션 생존 (publish-queue-tab-close Task 2) ----
#   임시 저장소의 색인만 쓴다(project_root 로 고정). 가짜 herdr 는 $TQ 의 파일로 응답을 정하고 호출을 남긴다.
source "$SCRIPT_DIR/_tasks_index.sh"
QREPO="$TMP/qrepo"; mkdir -p "$QREPO"; git -C "$QREPO" init -q; QREPO="$(cd "$QREPO" && pwd -P)"
project_root="$QREPO"
[[ "$(tasks_index_path)" == "$QREPO"/.git/rd-workflow/tasks.local ]] || { fail "색인이 임시 저장소를 가리키지 않음: $(tasks_index_path)"; exit 1; }
TQ="$TMP/tq"; mkdir -p "$TQ/bin"
make_tq_stub() {  # 응답 파일을 비우고 가짜 herdr 를 만든다
  rm -f "${TQ:?}"/*.out "${TQ:?}"/*.err "${TQ:?}"/*.rc "$TQ"/*.cnt "$TQ"/calls.log; : > "$TQ/calls.log"
  cat > "$TQ/bin/herdr" <<TQEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TQ/calls.log"
case "\$1 \$2" in
  "tab get")
    if [[ -f "$TQ/tabget.err" ]]; then cat "$TQ/tabget.err" >&2; exit 1; fi
    cat "$TQ/tabget.out" ;;
  "agent list")
    n=\$(( \$(cat "$TQ/list.cnt" 2>/dev/null || echo 0) + 1 )); echo \$n > "$TQ/list.cnt"
    f="$TQ/list.\$n.out"; [[ -f "\$f" ]] || f="$TQ/list.out"
    cat "\$f"; exit \$(cat "$TQ/list.rc" 2>/dev/null || echo 0) ;;
  "tab close") exit \$(cat "$TQ/close.rc" 2>/dev/null || echo 0) ;;
esac
TQEOF
  chmod +x "$TQ/bin/herdr"
}
tq_label() { printf '{"id":"cli:tab:get","result":{"tab":{"label":"%s","tab_id":"wX:t9"},"type":"tab_info"}}' "$1" > "$TQ/tabget.out"; }
tq_agents() { printf '{"id":"cli:agent:list","result":{"agents":[%s]}}' "$1" > "${2:-$TQ/list.out}"; }
tq_agent() { printf '{"pane_id":"%s","tab_id":"%s","name":"n","agent_status":"working"}' "$1" "$2"; }
tq_index() { tasks_index_upsert publish-x launch-backend="${1:-herdr}" launch-tab="${2-wX:t9}"; }
tq_close() {  # → TQ_RC, TQ_OUT, 호출 기록은 calls.log
  TQ_RC=0; TQ_OUT="$(PATH="$TQ/bin:$PATH" session_tab_close_if_ended "${1:-publish-x}")" || TQ_RC=$?
}
tq_closed() { grep -q '^tab close' "$TQ/calls.log"; }

# test_meta_file_written: tab create 의 tab_id 가 메타 파일에 한 줄로 남고 stdout 계약은 그대로다
make_stub 0 0 0
MF="$TMP/meta"; rm -f "$MF"
out="$(PATH="$STUB:$PATH" HERDR_ENV=1 RD_CHILD_SESSION= RD_LAUNCH_META_FILE="$MF" session_launch /tmp/wt alpha REQUEST.md 2>/dev/null)"
[[ "$out" == ok && "$(cat "$MF" 2>/dev/null)" == "launch-tab=wX:t9" ]] \
  && pass "메타 파일에 launch-tab 한 줄을 쓴다(stdout 은 ok)" || fail "메타 파일: out=$out meta=$(cat "$MF" 2>/dev/null)"
rm -f "$MF"

# test_tab_close_agent_alive: 그 탭에 에이전트가 있으면 닫지 않는다
make_tq_stub; tq_index; tq_label publish-x; tq_agents "$(tq_agent wX:p1 wX:t9)"
tq_close
[[ "$TQ_RC" == 1 && "$TQ_OUT" == *"살아 있음"* ]] && ! tq_closed \
  && pass "에이전트가 있으면 rc 1, tab close 미호출" || fail "agent_alive: rc=$TQ_RC out=$TQ_OUT"
# 다른 탭의 에이전트는 영향이 없다
tq_agents "$(tq_agent wX:p2 wX:t7)"; rm -f "$TQ/list.cnt"; : > "$TQ/calls.log"
tq_close
[[ "$TQ_RC" == 0 ]] && tq_closed && pass "다른 탭의 에이전트만 있으면 닫는다" || fail "other_tab: rc=$TQ_RC out=$TQ_OUT"

# test_tab_close_label_variants: 번호 접두는 있어도 없어도 일치, 다른 slug 의 접두 일치는 불일치
for lb in "publish-x" "[12] publish-x"; do
  make_tq_stub; tq_index; tq_label "$lb"; tq_agents ""
  tq_close
  [[ "$TQ_RC" == 0 ]] && tq_closed && pass "라벨 '$lb' 는 일치로 보고 닫는다" || fail "label '$lb': rc=$TQ_RC out=$TQ_OUT"
done
make_tq_stub; tq_index; tq_label "[1] publish-x-2"; tq_agents ""
tq_close
[[ "$TQ_RC" == 1 ]] && ! tq_closed && pass "라벨 '[1] publish-x-2' 는 불일치(rc 1)" || fail "label mismatch: rc=$TQ_RC out=$TQ_OUT"

# test_tab_close_list_fail: agent list 가 rc 1 이면(정상 형식 빈 목록이어도) 닫지 않는다
make_tq_stub; tq_index; tq_label publish-x; tq_agents ""; echo 1 > "$TQ/list.rc"
tq_close
[[ "$TQ_RC" == 1 ]] && ! tq_closed && pass "agent list 실패는 rc 1, 닫지 않음" || fail "list_fail: rc=$TQ_RC out=$TQ_OUT"

# test_tab_close_bad_shape: result.agents 배열이 없으면 닫지 않는다
make_tq_stub; tq_index; tq_label publish-x; echo '{"result":{}}' > "$TQ/list.out"
tq_close
[[ "$TQ_RC" == 1 ]] && ! tq_closed && pass "agents 배열이 없으면 rc 1, 닫지 않음" || fail "bad_shape: rc=$TQ_RC out=$TQ_OUT"
# test_tab_close_bad_item: 항목 하나라도 판정할 수 없으면(tab_id 누락·빈 값·객체 아님) 닫지 않는다
for item in '{"pane_id":"wX:p1","agent_status":"working"}' '{"pane_id":"wX:p1","tab_id":""}' '{"pane_id":"wX:p1","tab_id":7}' '"wX:t9"'; do
  make_tq_stub; tq_index; tq_label publish-x; tq_agents "$item"
  tq_close
  [[ "$TQ_RC" == 1 ]] && ! tq_closed && pass "판정할 수 없는 항목($item)이면 rc 1, 닫지 않음" || fail "bad_item $item: rc=$TQ_RC out=$TQ_OUT"
done

# test_tab_close_recheck_new_agent: 첫 조회는 빈 목록, 닫기 직전 재조회에서 에이전트가 보이면 닫지 않는다
make_tq_stub; tq_index; tq_label publish-x; tq_agents "" "$TQ/list.1.out"; tq_agents "$(tq_agent wX:p1 wX:t9)" "$TQ/list.2.out"
tq_close
[[ "$TQ_RC" == 1 ]] && ! tq_closed && pass "재조회에서 에이전트가 생기면 rc 1" || fail "recheck: rc=$TQ_RC out=$TQ_OUT"

# test_tab_close_not_found: tab get 이 tab_not_found 면 2, 그 밖의 오류는 1
make_tq_stub; tq_index; echo '{"error":{"code":"tab_not_found","message":"x"},"id":"cli:tab:get"}' > "$TQ/tabget.err"
tq_close
[[ "$TQ_RC" == 2 ]] && ! tq_closed && pass "tab_not_found 는 rc 2" || fail "not_found: rc=$TQ_RC out=$TQ_OUT"
echo '{"error":{"code":"internal","message":"x"}}' > "$TQ/tabget.err"
tq_close
[[ "$TQ_RC" == 1 ]] && pass "그 밖의 tab get 실패는 rc 1" || fail "tab get 기타 실패: rc=$TQ_RC"

# test_tab_close_no_id: launch-tab 이 비면 1 과 안내
make_tq_stub; tq_index herdr ""
tq_close
[[ "$TQ_RC" == 1 && "$TQ_OUT" == *"탭 식별자 없음"* ]] && ! grep -q . "$TQ/calls.log" \
  && pass "launch-tab 이 비면 rc 1, herdr 를 부르지 않음" || fail "no_id: rc=$TQ_RC out=$TQ_OUT"

# 백엔드가 herdr 가 아니면 1, tab close 실패면 1
make_tq_stub; tq_index hc wX:t9; tq_label publish-x; tq_agents ""
tq_close
[[ "$TQ_RC" == 1 ]] && ! grep -q . "$TQ/calls.log" && pass "백엔드가 hc 면 rc 1" || fail "backend hc: rc=$TQ_RC"
make_tq_stub; tq_index; tq_label publish-x; tq_agents ""; echo 1 > "$TQ/close.rc"
tq_close
[[ "$TQ_RC" == 1 && "$TQ_OUT" == *"탭 닫기 실패"* ]] && pass "tab close 실패는 rc 1" || fail "close fail: rc=$TQ_RC out=$TQ_OUT"

# test_caller_alive_herdr: pane 있음 0 / 없음 1 / list 실패 2
make_tq_stub; tq_agents "$(tq_agent wX:p1 wX:t1),$(tq_agent wX:p2 wX:t2)"
rc=0; PATH="$TQ/bin:$PATH" session_caller_alive herdr wX:p2 || rc=$?
[[ "$rc" == 0 ]] && pass "caller_alive: pane 이 있으면 0" || fail "caller_alive 있음: $rc"
rc=0; PATH="$TQ/bin:$PATH" session_caller_alive herdr wX:p9 || rc=$?
[[ "$rc" == 1 ]] && pass "caller_alive: pane 이 없으면 1" || fail "caller_alive 없음: $rc"
echo 1 > "$TQ/list.rc"
rc=0; PATH="$TQ/bin:$PATH" session_caller_alive herdr wX:p2 || rc=$?
[[ "$rc" == 2 ]] && pass "caller_alive: list 실패는 2(소실로 보지 않음)" || fail "caller_alive 실패: $rc"
make_tq_stub; tq_agents "$(tq_agent wX:p1 wX:t1),{\"tab_id\":\"wX:t2\"}"
rc=0; PATH="$TQ/bin:$PATH" session_caller_alive herdr wX:p2 || rc=$?
[[ "$rc" == 2 ]] && pass "caller_alive: pane_id 없는 항목이 있으면 2(소실로 보지 않음)" || fail "caller_alive 불완전 항목: $rc"

# hc: live 0 / finished 1 / not_found 1 / 그 밖 2
cat > "$TQ/bin/hc" <<'HCEOF'
#!/usr/bin/env bash
case "$(cat "$(dirname "$0")/../hc.mode")" in
  live) echo '{"state":"live"}' ;;
  finished) echo '{"state":"finished"}' ;;
  notfound) echo '{"error":{"kind":"not_found"}}' >&2; exit 3 ;;
  *) exit 1 ;;
esac
HCEOF
chmod +x "$TQ/bin/hc"
for pair in live:0 finished:1 notfound:1 broken:2; do
  echo "${pair%%:*}" > "$TQ/hc.mode"
  rc=0; PATH="$TQ/bin:$PATH" session_caller_alive hc t6 || rc=$?
  [[ "$rc" == "${pair##*:}" ]] && pass "caller_alive hc ${pair%%:*} → ${pair##*:}" || fail "caller_alive hc ${pair%%:*}: $rc"
done

# F1) hc 응답 다중 필드 읽기 — 앞 경로가 null·없음·줄바꿈 값이어도 뒤 경로의 값이 제자리에 온다.
#     줄이 당겨지면 state 자리에 turn 이 들어가 생존·처리 판정이 틀어진다.
printf '%s' '{"state":"live","status":{"state":null},"turn":3,"labels":{"herdr.space":"s1"},"cwd":"a\nb","address":"x"}' > "$TMP/f1.json"
f1_a=; f1_b=; f1_c=; f1_d=; f1_e=; f1_f=; f1_g=
_session_launch_hc_read "$TMP/f1.json" state status.state nope turn labels.herdr.space cwd address \
  -- f1_a f1_b f1_c f1_d f1_e f1_f f1_g
[[ "$f1_a|$f1_b|$f1_c|$f1_d|$f1_e|$f1_f|$f1_g" == "live|||3|s1||x" ]] \
  && pass "hc 다중 필드: 빈 값 자리를 지키고 뒤 값을 제자리에 담는다" || fail "hc 다중 필드: [$f1_a|$f1_b|$f1_c|$f1_d|$f1_e|$f1_f|$f1_g]"
printf 'not json' > "$TMP/f1b.json"
f1_out="$(_session_launch_hc_fields "$TMP/f1b.json" state turn; printf 'end')"
[[ "$f1_out" == $'\n\nend' ]] && pass "hc 다중 필드: 깨진 JSON 도 경로마다 빈 줄을 낸다" || fail "hc 다중 필드 깨진 JSON: [$f1_out]"
# 대기 루프는 같은 변수를 바퀴마다 다시 읽는다. 읽지 못한 바퀴에 앞 바퀴 값이 남으면 처리 완료로 오판한다.
(
  command() { if [[ "${1-}" == "-v" && "${2-}" == "python3" ]]; then return 1; fi; builtin command "$@"; }
  f1_a=old; f1_b=old
  _session_launch_hc_read "$TMP/f1.json" state turn -- f1_a f1_b
  [[ -z "$f1_a$f1_b" ]] || { echo "[$f1_a|$f1_b]" >&2; exit 1; }
) && pass "hc 다중 필드: 읽지 못하면 앞 값을 지우고 빈 값으로 둔다" || fail "hc 다중 필드: 읽지 못한 변수에 앞 값이 남는다"

# F2) promote — 앞 32자가 같은 다른 작업이 색인에 있으면 착수 전에 거부한다(세션 이름 충돌).
#     같은 slug 재실행은 거부하지 않는다. promote 를 세 번 띄우므로 약 3~5초가 걸린다 — 거부가 브랜치·색인을
#     만들기 전인지는 실제 promote 로만 확인할 수 있다.
F2="$(mktemp -d)" || { echo "test_session_launch.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$F2" && -d "$F2" ]] || { echo "test_session_launch.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
F2="$(cd -P "$F2" && pwd -P)"
mkdir -p "$F2/rd-workflow"
cp -R "$SCRIPT_DIR/.." "$F2/rd-workflow/scripts"
git -C "$F2" init -q -b main
git -C "$F2" config user.email t@t && git -C "$F2" config user.name t
mkdir -p "$F2/rd-workflow-workspace/.lifecycle" "$F2/rd-workflow-workspace/backlog/items"
printf '.worktrees/\n' > "$F2/.gitignore"
( source "$SCRIPT_DIR/_lifecycle_common.sh" && emit_current_task_baseline ) > "$F2/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$F2/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$F2/REQUEST.md"
git -C "$F2" add -A && git -C "$F2" commit -q -m seed
F2_A="abcdefghij-abcdefghij-abcdefghij-first"
F2_B="abcdefghij-abcdefghij-abcdefghij-second"
f2_promote() { ( cd "$F2" && env HERDR_ENV= HC_TERMINAL_ID= RD_CHILD_SESSION=1 \
  bash "$F2/rd-workflow/scripts/lifecycle/promote.sh" --short-title "$1" --size large --source-fr - 2>&1 ); }
f2_rc=0; f2_out="$(f2_promote "$F2_A")" || f2_rc=$?
[[ "$f2_rc" -eq 0 ]] || fail "F2 준비: 첫 promote 실패(rc=$f2_rc): $f2_out"
f2_out="$(f2_promote "$F2_A")" || true
[[ "$f2_out" != *"세션 이름("* ]] && pass "F2 같은 slug 재실행은 이름 충돌로 거부하지 않는다" || fail "F2 같은 slug 재실행이 거부됨: $f2_out"
f2_rc=0; f2_out="$(f2_promote "$F2_B")" || f2_rc=$?
f2_idx="$(cd "$F2" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_all_slugs')"
if [[ "$f2_rc" -ne 0 && "$f2_out" == *"진행 중인 작업 '$F2_A'"* ]] \
   && ! git -C "$F2" rev-parse --verify --quiet "refs/heads/fr/$F2_B" >/dev/null \
   && [[ "$f2_idx" != *"$F2_B"* ]]; then
  pass "F2 앞 32자가 같은 다른 작업이 있으면 브랜치·색인 행 없이 거부한다"
else
  fail "F2 이름 충돌 거부: rc=$f2_rc idx=[$f2_idx] out=$f2_out"
fi
# 짧은 slug 를 나중에 착수해도 먼저 착수한 긴 slug 의 잘린 이름과 같으면 거부한다.
F2_C="abcdefghij-abcdefghij-abcdefghij"
f2_rc=0; f2_out="$(f2_promote "$F2_C")" || f2_rc=$?
if [[ "$f2_rc" -ne 0 && "$f2_out" == *"진행 중인 작업 '$F2_A'"* ]] \
   && ! git -C "$F2" rev-parse --verify --quiet "refs/heads/fr/$F2_C" >/dev/null; then
  pass "F2 32자 이하 slug 도 먼저 착수한 긴 slug 와 이름이 같으면 거부한다"
else
  fail "F2 짧은 slug 이름 충돌 거부: rc=$f2_rc out=$f2_out"
fi
rm -rf "$F2"

printf 'session_launch: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
