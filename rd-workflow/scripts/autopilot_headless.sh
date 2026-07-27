#!/usr/bin/env bash
# autopilot_headless.sh — autopilot 무인(headless) 진입 wrapper.
# 환경변수로 FR/모드/종료정책을 받아 claude -p 헤드리스 세션을 기동하고,
# skill 이 남긴 outcome 파일을 의미적 exit code 로 매핑한다.
# 오케스트레이션 지능은 넣지 않는다 (front-end 소관).
#
# 환경변수:
#   RD_AUTOPILOT_FR      <slug>|auto      (필수 — 무인 분기 활성화 신호)
#   RD_AUTOPILOT_MODE    A|B              (기본 A — skill 이 해석)
#   RD_FINISH_POLICY     push|merge|none  (기본 push — skill 이 해석)
#   RD_AUTOPILOT_OUTCOME_FILE  outcome 파일 경로 (기본 rd-workflow-workspace/.autopilot-outcome)
#   RD_AUTOPILOT_HEADLESS_NO_INVOKE=1     claude -p 호출 생략 (테스트용 — 매핑만)
#
# exit code: 0 completed / 10 resume / 20 blocked / 30 queue-empty / 40 harness-error
set -uo pipefail

OUTCOME_FILE="${RD_AUTOPILOT_OUTCOME_FILE:-rd-workflow-workspace/.autopilot-outcome}"

# 1. 실제 실행 시에만 outcome 파일 초기화 (테스트 모드는 심어둔 outcome 보존)
if [[ "${RD_AUTOPILOT_HEADLESS_NO_INVOKE:-0}" != "1" ]]; then
  if [[ -z "${RD_AUTOPILOT_FR:-}" ]]; then
    echo "autopilot_headless: RD_AUTOPILOT_FR 미설정 — 무인 진입 불가" >&2
    exit 40
  fi
  : > "$OUTCOME_FILE" 2>/dev/null || {
    echo "autopilot_headless: outcome 파일 초기화 실패: $OUTCOME_FILE" >&2
    exit 40
  }
  # 2. claude -p 헤드리스 기동 (max-turns 미설정 — 실연 truncation 방지)
  RD_AUTOPILOT_OUTCOME_FILE="$OUTCOME_FILE" \
  claude -p "autopilot skill 을 무인(headless) 모드로 실행하라. 환경변수 RD_AUTOPILOT_FR / RD_AUTOPILOT_MODE / RD_FINISH_POLICY 를 읽어 §1 작업선택·모드선택 게이트를 AskUserQuestion 없이 건너뛰고 자율 완주하라. 종료 시 outcome 토큰(completed|resume|blocked:<reason>|queue-empty)을 \$RD_AUTOPILOT_OUTCOME_FILE 에 기록하라." \
    --permission-mode bypassPermissions \
    --output-format text || true
fi

# 3. outcome → exit code 매핑
map_outcome() {
  local raw
  raw="$(head -n1 "$OUTCOME_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$raw" in
    completed)   echo "완료 (completed)"; return 0 ;;
    resume)      echo "세션 한계 — 재개 필요 (resume)"; return 10 ;;
    blocked:*)   echo "중단 — ${raw#blocked:} (blocked)"; return 20 ;;
    queue-empty) echo "큐 빔 (queue-empty)"; return 30 ;;
    *)           echo "outcome 판독 불가 ('${raw}') — 세션 크래시 의심 (harness-error)"; return 40 ;;
  esac
}

SUMMARY="$(map_outcome)"; CODE=$?
echo "autopilot_headless: ${SUMMARY} [exit ${CODE}]"
exit "$CODE"
