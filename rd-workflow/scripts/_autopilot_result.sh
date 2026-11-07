#!/usr/bin/env bash
# _autopilot_result.sh — autopilot_headless.sh 가 source 하는 claude 결과 해석·outcome 매핑 lib. 단독 실행 대상이 아니다.
# 함수: emit_claude_result · append_cost_record · describe_claude_exit · map_outcome (본문은 wrapper 에서 옮겨 온 그대로).
# 읽는 wrapper 전역: OUTCOME_FILE(outcome 파일 경로) · CLAUDE_RC(claude 종료 코드) · COST_LINE·COST_REC(emit_claude_result 가 정함)
#                   · RD_AUTOPILOT_COST_FILE(환경변수, append_cost_record 가 읽음)

# emit_claude_result <결과 파일> <비용 줄 파일> — claude 결과 JSON 에서 본문(result)을 stdout 에 내고 COST_LINE 을 정한다.
# 세션 추적 경로(python3 실행 검사 통과)에서만 부른다. JSON 이 아니거나 형식이 다르면 원문을 그대로 내고 사유를 적는다.
emit_claude_result() {
  local rf="$1" cf="$2" p="autopilot_headless: 실행 비용 확인 불가 — "
  : > "$cf"
  if ! python3 - "$rf" "$cf" <<'PYEOF'
import json, math, sys
rf, cf = sys.argv[1], sys.argv[2]
P = "autopilot_headless: 실행 비용 "
U = P + "확인 불가 — "
raw = open(rf, encoding="utf-8", errors="replace").read()
def body(t):
    if t:
        sys.stdout.write(t if t.endswith("\n") else t + "\n")
def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)
def tok(v):
    return format(v, ",") if num(v) else "?"
rec = None
if not raw.strip():
    line = U + "claude 결과 출력 없음"
else:
    try:
        d = json.loads(raw)
        parsed = True
    except ValueError:
        parsed = False
    # json.loads("null") 도 None 이므로 None 으로 파싱 실패를 표시하지 않는다.
    if not parsed:
        body(raw); line = U + "결과가 JSON 이 아님"
    elif not isinstance(d, dict):
        body(raw); line = U + "결과가 JSON 객체가 아님"
    else:
        if isinstance(d.get("result"), str):
            body(d["result"])
        cost = d.get("total_cost_usd")
        try:
            cost_ok = num(cost) and math.isfinite(cost) and cost >= 0
        except OverflowError:
            cost_ok = False
        if not num(cost):
            line = U + "결과에 비용 필드 없음"
        elif not cost_ok:
            line = U + "비용 값이 유한한 0 이상의 수가 아님"
        else:
            u = d.get("usage") if isinstance(d.get("usage"), dict) else {}
            dur = d.get("duration_ms")
            rec = "cost\tok\t%.6f" % cost
            line = (P + "$%.4f (정가 환산) · 토큰 입력 %s · 출력 %s · 캐시 쓰기 %s · 캐시 읽기 %s · 소요 %s분 · 턴 %s" % (
                cost, tok(u.get("input_tokens")), tok(u.get("output_tokens")),
                tok(u.get("cache_creation_input_tokens")), tok(u.get("cache_read_input_tokens")),
                ("%.1f" % (dur / 60000.0)) if num(dur) else "?",
                d.get("num_turns") if num(d.get("num_turns")) else "?"))
            if d.get("is_error") is True:
                line += " · 결과 오류(%s)" % d.get("subtype", "?")
if rec is None:
    rec = "cost\tunknown\t" + line[len(U):]
# 첫 줄은 사람용 비용 줄, 둘째 줄은 기계 판독 비용 기록(COST_REC)이다.
with open(cf, "w", encoding="utf-8") as f:
    f.write(line + "\n" + rec)
PYEOF
  then
    cat "$rf" 2>/dev/null
    [[ -s "$rf" && -n "$(tail -c1 "$rf")" ]] && echo
    COST_LINE="${p}결과 해석 실패"
    COST_REC="$(printf 'cost\tunknown\t결과 해석 실패')"
    return
  fi
  COST_LINE="$(sed -n 1p "$cf" 2>/dev/null)"
  COST_REC="$(sed -n 2p "$cf" 2>/dev/null)"
  if [[ -z "$COST_LINE" ]]; then
    COST_LINE="${p}결과 해석 실패"
    COST_REC="$(printf 'cost\tunknown\t결과 해석 실패')"
  fi
}

# 3-2. 비용 기록 — RD_AUTOPILOT_COST_FILE 이 있으면 레코드 한 줄을 덧붙인다. wrapper 가 발행 뒤에 부른다
# (비용 파일이 worktree 안이면 발행 전에 쓸 때 archive.sh 의 clean 검사가 거부한다). 실패해도 결과·종료 코드는 그대로다.
append_cost_record() {
  [[ -n "${RD_AUTOPILOT_COST_FILE:-}" && -n "$COST_REC" ]] || return 0
  printf '%s\n' "$COST_REC" >> "$RD_AUTOPILOT_COST_FILE" 2>/dev/null \
    || echo "autopilot_headless: 경고 — 비용 기록 실패: $RD_AUTOPILOT_COST_FILE" >&2
  return 0
}

# describe_claude_exit — outcome 미기록 시 claude 종료 코드의 원인 문구를 stdout 으로 낸다.
# 129~255 는 128+신호 라는 셸 관례로 신호 종료로 본다 (claude 가 그 값으로 직접 종료한 경우와는 구별되지 않는다).
describe_claude_exit() {
  local rc="${CLAUDE_RC:-}" sig name
  if [[ -z "$rc" ]]; then echo "claude 종료 코드 확인 불가"
  elif (( rc == 0 )); then echo "claude 정상 종료(0) 인데 outcome 미기록"
  elif (( rc >= 129 && rc <= 255 )); then
    sig=$((rc - 128)); name="$(kill -l "$sig" 2>/dev/null)"
    echo "claude 신호 종료(${name:-$sig}) [128+${sig}]"
  else echo "claude 비정상 종료(코드 ${rc})"
  fi
}

# 3. outcome → exit code 매핑
map_outcome() {
  local raw
  raw="$(head -n1 "$OUTCOME_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$raw" in
    completed)   echo "완료 (completed)"; return 0 ;;
    resume)      echo "세션 한계 — 재개 필요 (resume)"; return 10 ;;
    blocked:*)   echo "중단 — ${raw#blocked:} (blocked)"; return 20 ;;
    queue-empty) echo "큐 빔 (queue-empty)"; return 30 ;;
    queue-blocked) echo "의존 대기로 착수 가능 FR 없음 (queue-blocked)"; return 31 ;;
    *)           echo "outcome 판독 불가 ('${raw}') — 세션 크래시 의심 (harness-error) — $(describe_claude_exit)"; return 40 ;;
  esac
}
