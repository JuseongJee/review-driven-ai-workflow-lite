#!/bin/bash
# test_headless_background_gate.sh — 무인 background dispatch 차단 hook 의 판정 테이블.
# macOS /bin/bash 3.2 호환 (globstar/extglob 불사용).
#
# fixture 를 만들지 않는다: 이 hook 은 환경변수와 stdin 만 읽는다.
# (기존 test_implementation_gate.sh 는 케이스마다 mktemp -d + 파일 복사를 해 단독 59초다.)
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/headless_background_gate.sh"
# macOS Bash 3.2 경로를 실제로 검증한다 — PATH 의 bash 는 3.2 가 아닐 수 있다.
BASH_BIN="/bin/bash"
[[ -x "$BASH_BIN" ]] || BASH_BIN="$(command -v bash)"
PASS=0
FAIL=0
ISO_DIR=""
LAST_OUT=""


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
cleanup() { if [[ -n "$ISO_DIR" && -d "$ISO_DIR" ]]; then rm -rf "$ISO_DIR"; ISO_DIR=""; fi; _rd_gbl_cleanup; }
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }

# --- 테스트 환경 자체의 전제 ---
# 판독기가 원래 없는 환경이면 "있음" 이라는 이름으로 다른 경로를 도는 셈이므로 드러낸다.
command -v jq      >/dev/null 2>&1 && ok || bad "환경: jq 미설치 — jq 경로를 검증할 수 없습니다"
command -v python3 >/dev/null 2>&1 && ok || bad "환경: python3 미설치 — python3 경로를 검증할 수 없습니다"

# 격리 PATH: 지정한 도구를 뺀 실행 환경을 만든다.
# hook 본체와 _guard_common.sh source 가 dirname 을 호출하므로 실행 의존성을 빠짐없이
# 넣어야 한다. 하나라도 없으면 판정 이전에 경로 해석에서 죽고, 그것을 "통과" 로 오독한다.
ISO_BASE_DEPS="bash dirname cat sed grep env mktemp rm ln head tr"
# make_iso <추가로 넣을 도구들…>
make_iso() {
  local extra="$*" b src missing=""
  cleanup
  # 템플릿을 쓸 수 없다: 실패를 `bad` 로 집계해야 FAIL 카운터에 반영된다. 마커는 집계 보존을
  # 위한 것이라 경로 안전성을 대신하지 않으므로 경로 검증을 같은 규약으로 따로 둔다 — 없으면
  # `rc=0 + 빈 출력`에서 아래 `ln -s "$src" "$ISO_DIR/$b"` 가 `/bash` 를 만든다 (Turn 002 F2).
  ISO_DIR="$(mktemp -d)" || { bad "환경: mktemp 실패 — 격리 PATH 를 만들 수 없습니다"; return 1; }   # mktemp-scan: custom-handler
  [[ -n "$ISO_DIR" && -d "$ISO_DIR" ]] || { bad "환경: mktemp 경로 검증 실패 (TMPDIR='${TMPDIR:-}')"; return 1; }   # mktemp-scan: custom-handler
  for b in $ISO_BASE_DEPS $extra; do
    src="$(command -v "$b" 2>/dev/null)"
    if [[ -z "$src" || ! -x "$src" ]]; then missing="${missing} ${b}"; continue; fi
    ln -s "$src" "$ISO_DIR/$b" 2>/dev/null || missing="${missing} ${b}"
  done
  if [[ -n "$missing" ]]; then bad "환경: 격리 PATH 에 실행 의존성 누락 —${missing}"; return 1; fi
  # 빼기로 한 도구가 정말 안 보이는지 확인한다.
  for b in jq python3; do
    case " $extra " in *" $b "*) continue ;; esac
    if PATH="$ISO_DIR" command -v "$b" >/dev/null 2>&1; then
      bad "환경: 격리 PATH 에서 $b 가 여전히 보입니다 — 해당 경로가 검증되지 않습니다"
      return 1
    fi
  done
  return 0
}

# run_case <이름> <FR 값|__UNSET__> <기대 exit> <입력> <라벨>
# env 옵션(-u)은 반드시 대입 인자(PATH=…)보다 앞에 온다.
#   `env PATH=… -u VAR bash …` 는 -u 를 실행 파일 이름으로 해석해 rc 127 이 되고
#   hook 이 아예 실행되지 않는다 (실측 확인).
run_case() {
  local name="$1" frval="$2" want="$3" input="$4" label="$5"
  local rc
  local -a cmd
  cmd=(env)
  [[ "$frval" == "__UNSET__" ]] && cmd+=(-u RD_AUTOPILOT_FR)
  [[ -n "$ISO_DIR" ]] && cmd+=("PATH=$ISO_DIR")
  [[ "$frval" != "__UNSET__" ]] && cmd+=("RD_AUTOPILOT_FR=$frval")
  LAST_OUT="$(printf '%s' "$input" | "${cmd[@]}" "$BASH_BIN" "$HOOK" 2>&1)"; rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    ok
  else
    bad "[$label] $name — 기대 exit $want, 실제 $rc${LAST_OUT:+ / 출력: $LAST_OUT}"
  fi
}

BG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sleep 2","run_in_background":true}}'
FALSE_V='{"tool_name":"Bash","tool_input":{"command":"echo hi","run_in_background":false}}'
OMIT='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
CMD_TEXT='{"tool_name":"Bash","tool_input":{"command":"echo {\"run_in_background\":true}"}}'
STR_TRUE='{"tool_name":"Bash","tool_input":{"command":"echo hi","run_in_background":"true"}}'
TOP_LEVEL='{"run_in_background":true,"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
BROKEN_PRE='{"tool_name":"Bash","tool_input":{"command":'
NO_TI='{"tool_name":"Bash"}'
TRUNC_AFTER='{"tool_input":{"run_in_background":true'
TRAILING='{"tool_input":{"run_in_background":true}}garbage'
# r = 'r'. 셸 인용에서 백슬래시가 유실되기 쉬우니 작성 후 반드시 grep 으로 확인한다.
ESC_KEY='{"tool_input":{"\u0072un_in_background":true}}'
TRAIL_COMMA='{"tool_input":{"run_in_background":true,}}'
NO_COMMA='{"tool_input":{"run_in_background":true "command":"x"}}'
BAD_BRACKET='{"tool_input":{"run_in_background":true]}'
BAD_ESCAPE='{"tool_input":{"command":"echo \q","run_in_background":true}}'
DUP_KEY='{"tool_input":{"run_in_background":true,"run_in_background":false}}'
PRETTY='{
  "tool_name": "Bash",
  "tool_input": {
    "command": "sleep 2",
    "run_in_background": true
  }
}'

# run_table <라벨> <판독기 있음 = 1 | 없음 = 0>
run_table() {
  local label="$1" parser="$2"
  local blk=2
  [[ "$parser" == "0" ]] && blk=0     # 판독기가 없으면 차단하지 않고 통과한다

  run_case "1 background"          "slug"      "$blk" "$BG"          "$label"
  if [[ "$parser" == "1" ]]; then
    case "$LAST_OUT" in
      *timeout*WAIT_TIMEOUT*|*WAIT_TIMEOUT*timeout*) ok ;;
      *) bad "[$label] 1 차단 메시지에 대안(timeout / WAIT_TIMEOUT)이 없습니다" ;;
    esac
  fi
  run_case "2 false"               "slug"      0      "$FALSE_V"     "$label"
  run_case "3 필드 생략"           "slug"      0      "$OMIT"        "$label"
  run_case "4 변수 unset"          "__UNSET__" 0      "$BG"          "$label"
  run_case "5 변수 빈값"           ""          0      "$BG"          "$label"
  run_case "6 command 안 텍스트"   "slug"      0      "$CMD_TEXT"    "$label"
  run_case "7 문자열 true"         "slug"      0      "$STR_TRUE"    "$label"
  run_case "8 최상위 동명키"       "slug"      0      "$TOP_LEVEL"   "$label"
  run_case "9 빈 stdin"            "slug"      0      ""             "$label"
  run_case "10 true 이전 절단"     "slug"      0      "$BROKEN_PRE"  "$label"
  run_case "11 tool_input 부재"    "slug"      0      "$NO_TI"       "$label"
  run_case "12 true 이후 절단"     "slug"      0      "$TRUNC_AFTER" "$label"
  run_case "13 후행 쓰레기"        "slug"      0      "$TRAILING"    "$label"
  run_case "14 escape 된 키"       "slug"      "$blk" "$ESC_KEY"     "$label"
  run_case "15 pretty-printed"     "slug"      "$blk" "$PRETTY"      "$label"
  run_case "16 후행 쉼표"          "slug"      0      "$TRAIL_COMMA" "$label"
  run_case "17 쉼표 누락"          "slug"      0      "$NO_COMMA"    "$label"
  run_case "18 괄호 짝 불일치"     "slug"      0      "$BAD_BRACKET" "$label"
  run_case "19 잘못된 escape"      "slug"      0      "$BAD_ESCAPE"  "$label"
  run_case "20 중복 키"            "slug"      0      "$DUP_KEY"     "$label"
}

echo "=== jq 경로 (기본 PATH) ==="
ISO_DIR=""
run_table "jq" 1

# guard-block-reason-identifier: 이 분기(headless_background_gate.sh 유일 차단 지점)가
# 실제로 유발됐을 때 기대한 reason 값이 감사 로그에 기록되는지 값 대응 검증.
if tail -n1 "$RD_GUARD_BLOCK_LOG" 2>/dev/null | grep -qE 'reason=headless_background_gate\.background-dispatch$'; then
  ok
else
  bad "감사 로그에 reason=headless_background_gate.background-dispatch 가 없습니다"
fi

echo "=== python3 경로 (jq 제거) ==="
if make_iso python3; then run_table "py" 1; fi

echo "=== 판독기 없음 (jq·python3 제거) ==="
if make_iso; then run_table "none" 0; fi

echo "test_headless_background_gate: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
