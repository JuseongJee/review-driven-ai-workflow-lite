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
# exit code: 0 completed / 10 resume / 20 blocked / 30 queue-empty / 31 queue-blocked / 40 harness-error
set -uo pipefail

# 이 wrapper 는 정의상 무인 진입점이다 — 사람이 보는 화면이 없다. 그러므로 이 아래에서
# 도는 모든 것은 자식 세션이며, 또 다른 대화형 세션을 기동해서는 안 된다.
# `session_launch` 는 이 변수가 있으면 기동을 건너뛰고 none 을 반환한다.
# export 자리가 여기인 이유: 호출자(batch 국면 2 등)마다 변수를 기억하게 두면 한 곳만
# 빠져도 같은 결함이 재발한다. 무인이라는 사실을 아는 것은 이 스크립트 자신이다.
# (2026-09-24 /fr batch 회귀 — promote 가 FR 마다 herdr 탭을 띄워 batch 가 exit 10 으로 멈췄다)
export RD_CHILD_SESSION=1

OUTCOME_FILE="${RD_AUTOPILOT_OUTCOME_FILE:-rd-workflow-workspace/.autopilot-outcome}"

# outcome 경로를 **호출자 기준 절대경로로 고정**한다. 이 wrapper 는 자신의 CWD 에서 파일을
# 비우고 같은 자리에서 읽는데, 자식 세션은 promote 가 만든 작업 worktree 로 이동해 이어간다
# (WORKFLOW.md 「이어서 진행할 때는 대상 worktree 로 먼저 이동합니다」). 상대경로를 그대로
# 넘기면 자식은 worktree 안의 다른 파일에 쓰고, wrapper 는 빈 파일을 읽어 완주를 exit 40
# (harness-error) 으로 오판한다. resume·blocked 의 중단 이유도 부모에 닿지 않는다.
case "$OUTCOME_FILE" in
  /*) ;;
  *)  OUTCOME_FILE="${PWD}/${OUTCOME_FILE}" ;;
esac

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
  claude -p "autopilot skill 을 무인(headless) 모드로 실행하라. 환경변수 RD_AUTOPILOT_FR / RD_AUTOPILOT_MODE / RD_FINISH_POLICY 를 읽어 §1 작업선택·모드선택 게이트를 AskUserQuestion 없이 건너뛰고 자율 완주하라. 종료 시 outcome 토큰(completed|resume|blocked:<reason>|queue-empty|queue-blocked)을 \$RD_AUTOPILOT_OUTCOME_FILE 에 기록하라." \
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
    queue-blocked) echo "의존 대기로 착수 가능 FR 없음 (queue-blocked)"; return 31 ;;
    *)           echo "outcome 판독 불가 ('${raw}') — 세션 크래시 의심 (harness-error)"; return 40 ;;
  esac
}

SUMMARY="$(map_outcome)"; CODE=$?
echo "autopilot_headless: ${SUMMARY} [exit ${CODE}]"

# 4. 대기 상세 출력 — outcome 둘째 줄 이후를 그대로 낸다.
# blocked(20) 과 queue-blocked(31) 양쪽에 적용한다: 전역 실패(relations-unavailable)도
# 원인 진단이 사용자 요약까지 닿아야 한다.
# 이 출력을 map_outcome 안에 넣지 않는다 — 그 함수의 stdout 은 SUMMARY 로 캡처돼
# 한 줄 요약이 되므로, 상세를 섞으면 요약이 깨진다.
case "$CODE" in
  20|31) awk 'NR>1' "$OUTCOME_FILE" 2>/dev/null ;;
esac
exit "$CODE"
