#!/usr/bin/env bash
# test_ralph_drain.sh — ralph_drain.sh supervisor 루프 단위 테스트.
# RD_RALPH_WRAPPER_CMD 로 스크립트된 exit code 시퀀스를 주입해 결정적으로 검증한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAIN="${SCRIPT_DIR}/ralph_drain.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# exit code 시퀀스를 반환하는 stub wrapper. 호출마다 counter 파일로 다음 코드를 낸다.
STUB="${TMP}/stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
i=$(cat "$RD_STUB_COUNTER" 2>/dev/null || echo 0)
# shellcheck disable=SC2206
codes=($RD_STUB_CODES)
code="${codes[$i]:-30}"
echo $((i + 1)) > "$RD_STUB_COUNTER"
if [ -n "${RD_STUB_ENVLOG:-}" ]; then
  echo "FR=${RD_AUTOPILOT_FR:-} MODE=${RD_AUTOPILOT_MODE:-} FINISH=${RD_FINISH_POLICY:-}" >> "$RD_STUB_ENVLOG"
fi
# blocked(20) 시 outcome 파일에 사유 기록 (supervisor 사유 수집 검증용)
if [ "$code" = "20" ] && [ -n "${RD_AUTOPILOT_OUTCOME_FILE:-}" ]; then
  echo "blocked:${RD_STUB_REASON:-review-50turn}" > "$RD_AUTOPILOT_OUTCOME_FILE"
fi
exit "$code"
STUBEOF
chmod +x "$STUB"

fail=0
run_case() {
  # $1 이름  $2 기대 exit  $3 codes  나머지: 추가 env (KEY=VAL)
  local name="$1" expect="$2" codes="$3"; shift 3
  local counter="${TMP}/counter"; : > "$counter"
  local outcome="${TMP}/outcome"; : > "$outcome"
  local out ec
  out=$(env "$@" \
        RD_STUB_CODES="$codes" RD_STUB_COUNTER="$counter" \
        RD_AUTOPILOT_OUTCOME_FILE="$outcome" \
        RD_RALPH_WRAPPER_CMD="bash $STUB" \
        bash "$DRAIN" 2>&1); ec=$?
  if [ "$ec" -ne "$expect" ]; then
    echo "  FAIL [$name] exit 기대 $expect, 실제 $ec"; echo "$out" | sed 's/^/    /'; fail=1
  else
    echo "  ok [$name] exit $ec"
  fi
  LAST_OUT="$out"
}

assert_contains() {
  case "$LAST_OUT" in
    *"$1"*) echo "  ok [contains] $1" ;;
    *) echo "  FAIL [contains] '$1' 없음"; fail=1 ;;
  esac
}

echo "== ralph_drain 테스트 =="
run_case "queue-empty 즉시" 0 "30";                          assert_contains "queue-empty"
run_case "completed 후 종료" 0 "0 30";                       assert_contains "completed (누적 1)"
run_case "blocked 후 종료" 0 "20 30";                        assert_contains "blocked: 1"
run_case "blocked 사유 수집" 0 "20 30" RD_STUB_REASON=loop-guard; assert_contains "loop-guard"
run_case "harness-error 재시도 성공" 0 "40 30";              assert_contains "1회 재시도"
run_case "harness-error 재발 중단" 1 "40 40";                assert_contains "harness-error 재발"
run_case "non-progress 가드" 1 "10 10 10" RD_RALPH_NONPROGRESS_LIMIT=3; assert_contains "non-progress 가드"
run_case "iteration 상한" 1 "0 0 0" RD_RALPH_MAX_ITER=3;     assert_contains "iteration 상한"
run_case "MAX_ITER 비숫자 거부" 1 "30" RD_RALPH_MAX_ITER=abc; assert_contains "RD_RALPH_MAX_ITER 는 양수 정수"
run_case "MAX_ITER 0 거부" 1 "30" RD_RALPH_MAX_ITER=0;       assert_contains "1 이상"
run_case "NONPROGRESS 음수 거부" 1 "30" RD_RALPH_NONPROGRESS_LIMIT=-1; assert_contains "RD_RALPH_NONPROGRESS_LIMIT 는 양수 정수"
run_case "FINISH_POLICY 잘못된 값 거부" 1 "30" RD_FINISH_POLICY=bogus; assert_contains "push|merge|none"

# 기본 env 주입(merge/A/auto) 검증
ENVLOG="${TMP}/envlog"; : > "$ENVLOG"
run_case "기본 env 주입" 0 "30" RD_STUB_ENVLOG="$ENVLOG"
if grep -q "FR=auto MODE=A FINISH=merge" "$ENVLOG"; then
  echo "  ok [env] FR=auto MODE=A FINISH=merge 주입"
else
  echo "  FAIL [env] 기본 주입 불일치: $(cat "$ENVLOG")"; fail=1
fi

# finish policy override 검증
ENVLOG2="${TMP}/envlog2"; : > "$ENVLOG2"
run_case "finish policy override" 0 "30" RD_STUB_ENVLOG="$ENVLOG2" RD_FINISH_POLICY=push
if grep -q "FINISH=push" "$ENVLOG2"; then
  echo "  ok [env] FINISH=push 오버라이드"
else
  echo "  FAIL [env] override 불일치: $(cat "$ENVLOG2")"; fail=1
fi

if [ "$fail" -ne 0 ]; then echo "test_ralph_drain: FAIL"; exit 1; fi
echo "test_ralph_drain: PASS"
