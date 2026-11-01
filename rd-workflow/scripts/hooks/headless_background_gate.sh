#!/usr/bin/env bash
# headless_background_gate.sh — 무인(headless) autopilot 세션의 background dispatch 차단.
#
# 왜 필요한가: 무인 세션이 결과가 필요한 명령을 run_in_background 로 던지면, 응답을
# 내는 순간 claude -p 프로세스가 종료된다. 헤드리스에는 완료 알림으로 재진입할 주체가
# 없어 결과 수령자가 사라지고, outcome 이 빈 채 남아 wrapper 가 exit 40 으로 매핑한다.
# autopilot SKILL.md 「무인 진입 § 결과 대기 규율」이 이미 금지하지만 산문뿐이어서
# 한 배치 FR 5건에서 5/5 재발했다. 이 hook 은 의미를 바꾸지 않고 강제만 더한다.
#
# 판정: (RD_AUTOPILOT_FR 비어 있지 않음) AND (tool_input.run_in_background 이 literal true)
#   - RD_AUTOPILOT_FR 은 autopilot_headless.sh 가 미설정 시 exit 40 으로 거부하므로
#     wrapper 경유 무인 진입에는 반드시 있고, 대화형 세션에는 없다. hook 이 이 변수를
#     상속함은 실측으로 확인했다 (reports/probes/2026-09-09-hook-contract-probe.md).
#   - 빈 문자열은 unset 과 같이 다룬다 — 빈 값으로 기동한 세션은 wrapper 가 이미 거부한다.
#   - 대화형 autopilot(.autopilot_active)은 트리거에 넣지 않는다. 재진입 주체(사람)가
#     있어 자멸하지 않으며, 묶으면 정당한 백그라운드 사용까지 막는다.
# 판정 불가는 전부 통과(exit 0) — positive 감지 한정 fail-open.
# 한계: PreToolUse 는 명령 실행 전에만 돌아 timeout 도달 뒤의 harness 자동 이관을 볼 수 없다.
#   PostToolUse 로 이관 결과 문구를 볼 수 있는지는 미확인이라 코드를 바꾸지 않았고, 별도 FR 로 다룬다.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

[[ -n "${RD_AUTOPILOT_FR:-}" ]] || exit 0

read_hook_input
hook_input_bool_true "run_in_background" || exit 0

cat >&2 <<'MSG'
[guard] 무인 autopilot 세션에서는 결과가 필요한 명령을 백그라운드로 실행할 수 없습니다.
        응답을 내는 순간 세션이 종료되어 결과를 수령할 주체가 사라집니다
        (outcome 이 빈 채 남아 wrapper 가 harness-error / exit 40 으로 매핑).

        대안 1 — foreground 로 실행하십시오. timeout 인자는 생략합니다
                 (wrapper 가 올린 기본값이 적용됩니다). 스스로 백그라운드를
                 고르지 않습니다.

        대안 2 — 리뷰 턴은 안쪽 WAIT_TIMEOUT 을 바깥 Bash 대기(기본 7500초)보다 작게 둡니다.
                 WAIT_TIMEOUT=3600 bash rd-workflow/scripts/run_review_turn.sh <session-path>

        규약: autopilot SKILL.md 「무인 진입 § 결과 대기 규율」
MSG
# reason: 무인 autopilot 세션이 결과가 필요한 명령을 run_in_background로 던지려 한 분기.
guard_deny "headless_background_gate.background-dispatch"
