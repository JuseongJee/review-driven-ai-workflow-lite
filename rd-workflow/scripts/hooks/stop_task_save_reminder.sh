#!/usr/bin/env bash
# stop_task_save_reminder.sh — Claude Code Stop hook
# mid-work 상태에서 CURRENT_TASK.md를 갱신하지 않고 세션을 종료하려 할 때
# LLM이 한 턴 더 실행해 메모를 저장하도록 유도합니다.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

# 1. stdin 읽기 + stop_hook_active=true면 무한루프 방지를 위해 즉시 통과
read_hook_input
[[ "$(read_stop_hook_active)" == "true" ]] && exit 0

# 2. autopilot 활성 시 통과
is_autopilot_active && exit 0

# 3. 비차단 Status(빈값 / '대기 중' / '완료')면 통과
status="$(get_task_status)"
is_nonblocking_status "$status" && exit 0

# 4. CURRENT_TASK.md가 stale하지 않으면 통과
current_task_is_stale || exit 0

# 5. stale 감지 — block 신호 출력 후 exit 0 (Claude Code가 reason을 LLM에 전달)
printf '{"decision":"block","reason":"CURRENT_TASK.md가 mid-work인데 갱신되지 않았습니다. 진행 상태(Status / Next Step / Notes)를 저장한 뒤 종료하세요."}\n'
exit 0
