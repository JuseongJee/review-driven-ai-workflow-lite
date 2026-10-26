#!/usr/bin/env bash
# ralph_drain.sh — 무인 큐 드레인 supervisor (front-end A / Ralph loop).
# autopilot_headless.sh 를 RD_AUTOPILOT_FR=auto 로 반복 호출해 준비된 큐(validated/ready-for-request)를
# 사람 개입 없이 자율 소진한다. 오케스트레이션 지능은 넣지 않는다 — exit code 만 보고 계속/중단한다.
#
# 환경변수:
#   RD_FINISH_POLICY           push|merge|none  미설정 시 merge 주입 (무인 드레인 안전 기본값)
#   RD_RALPH_MAX_ITER          절대 iteration 상한 (기본 50)
#   RD_RALPH_NONPROGRESS_LIMIT 연속 non-terminal(완료/blocked 미도달) 한도 (기본 5)
#   RD_RALPH_WRAPPER_CMD       wrapper 호출 명령 오버라이드 (테스트 훅; 기본 "bash rd-workflow/scripts/autopilot_headless.sh")
#
# exit code: 0 정상 종료(queue-empty·queue-blocked) / 1 중단(backstop·harness-error 재발·관계 판정 불가·미지 코드)
set -uo pipefail

FINISH_POLICY="${RD_FINISH_POLICY:-merge}"
MAX_ITER="${RD_RALPH_MAX_ITER:-50}"
NONPROGRESS_LIMIT="${RD_RALPH_NONPROGRESS_LIMIT:-5}"
WRAPPER_CMD="${RD_RALPH_WRAPPER_CMD:-bash rd-workflow/scripts/autopilot_headless.sh}"
OUTCOME_FILE="${RD_AUTOPILOT_OUTCOME_FILE:-rd-workflow-workspace/.autopilot-outcome}"

# backstop env 검증 — 무인 안전장치가 설정 실수(비숫자·0·음수·오탈자)로 무력화되지 않도록 조기 거부한다.
_die() { echo "ralph_drain: $1" >&2; exit 1; }
case "$MAX_ITER" in *[!0-9]*|'') _die "RD_RALPH_MAX_ITER 는 양수 정수여야 합니다: '${MAX_ITER}'" ;; esac
[ "$MAX_ITER" -ge 1 ] || _die "RD_RALPH_MAX_ITER 는 1 이상이어야 합니다: '${MAX_ITER}'"
case "$NONPROGRESS_LIMIT" in *[!0-9]*|'') _die "RD_RALPH_NONPROGRESS_LIMIT 는 양수 정수여야 합니다: '${NONPROGRESS_LIMIT}'" ;; esac
[ "$NONPROGRESS_LIMIT" -ge 1 ] || _die "RD_RALPH_NONPROGRESS_LIMIT 는 1 이상이어야 합니다: '${NONPROGRESS_LIMIT}'"
case "$FINISH_POLICY" in push|merge|none) ;; *) _die "RD_FINISH_POLICY 는 push|merge|none 중 하나여야 합니다: '${FINISH_POLICY}'" ;; esac

iter=0
nonprogress=0
completed=0
blocked=0
blocked_reasons=""
blocked_detail=""
stop_reason=""

# wrapper 1회 호출 — auto-pick·모드 A·finish policy·outcome 파일 경로를 주입한다.
invoke_once() {
  RD_AUTOPILOT_FR=auto \
  RD_AUTOPILOT_MODE=A \
  RD_FINISH_POLICY="$FINISH_POLICY" \
  RD_AUTOPILOT_OUTCOME_FILE="$OUTCOME_FILE" \
  $WRAPPER_CMD
}

# harness-error(40) 1회 재시도 — 최종 exit code 를 반환한다.
invoke_with_retry() {
  invoke_once
  local c=$?
  if [ "$c" -eq 40 ]; then
    echo "ralph_drain: iter ${iter} → harness-error(40), 1회 재시도" >&2
    invoke_once
    c=$?
  fi
  return "$c"
}

summarize() {
  echo "---- ralph_drain 요약 ----"
  echo "완료(completed): ${completed}"
  echo "blocked: ${blocked}${blocked_reasons}"
  echo "iteration: ${iter}"
  echo "종료 사유: ${stop_reason}"
  [ -n "${blocked_detail:-}" ] && { echo "---- 대기 상세 ----"; printf '%s\n' "$blocked_detail"; }
}

while : ; do
  iter=$((iter + 1))
  if [ "$iter" -gt "$MAX_ITER" ]; then
    stop_reason="iteration 상한(${MAX_ITER}) 도달"
    summarize
    exit 1
  fi

  invoke_with_retry
  code=$?

  case "$code" in
    0)
      completed=$((completed + 1)); nonprogress=0
      echo "ralph_drain: iter ${iter} → completed (누적 ${completed})" ;;
    10)
      nonprogress=$((nonprogress + 1))
      echo "ralph_drain: iter ${iter} → resume (non-progress ${nonprogress}/${NONPROGRESS_LIMIT})" ;;
    20)
      reason="$(head -n1 "$OUTCOME_FILE" 2>/dev/null)"; reason="${reason#blocked:}"
      [ -n "$reason" ] || reason="(사유 미상)"
      # relations-unavailable 은 일반 blocked 와 다르다. 일반 blocked 는 그 FR 하나를
      # set-aside 하고 다음 FR 로 넘어가는 계약이지만, 관계 판정 실패는 FR 을 고르기
      # **전의 전역 실패**라 다음 iteration 도 똑같이 실패한다. 카운터를 올리지 않고
      # 즉시 중단한다 (그러지 않으면 같은 실패를 상한까지 되풀이한다).
      # 이 경로에는 FR status 변경·CURRENT_TASK 초기화 같은 일반 blocked 절차도
      # 적용되지 않는다 — 대상 FR 이 없기 때문이다.
      if [ "$reason" = "relations-unavailable" ]; then
        stop_reason="관계 판정 불가 (relations-unavailable) — 전역 실패이므로 즉시 중단"
        blocked_detail="$(awk 'NR>1' "$OUTCOME_FILE" 2>/dev/null)"
        summarize; exit 1
      fi
      blocked=$((blocked + 1)); nonprogress=0
      blocked_reasons="${blocked_reasons}
  - ${reason}"
      echo "ralph_drain: iter ${iter} → blocked: ${reason} (누적 ${blocked})" ;;
    30)
      stop_reason="queue-empty (드레인 완료)"; summarize; exit 0 ;;
    31)
      stop_reason="queue-blocked (의존 대기 — 착수 가능 FR 없음)"
      blocked_detail="$(awk 'NR>1' "$OUTCOME_FILE" 2>/dev/null)"
      summarize; exit 0 ;;
    40)
      stop_reason="harness-error 재발 — 중단"; summarize; exit 1 ;;
    *)
      stop_reason="미지 exit code(${code}) — 중단"; summarize; exit 1 ;;
  esac

  if [ "$nonprogress" -ge "$NONPROGRESS_LIMIT" ]; then
    stop_reason="연속 non-terminal ${NONPROGRESS_LIMIT}회 — non-progress 가드"
    summarize
    exit 1
  fi
done
