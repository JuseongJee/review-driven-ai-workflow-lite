#!/usr/bin/env bash
# stop_task_save_reminder.sh — Claude Code Stop hook
# mid-work 상태에서 CURRENT_TASK.md를 갱신하지 않고 세션을 종료하려 할 때
# LLM이 한 턴 더 실행해 메모를 저장하도록 유도합니다.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

# _bump_failed_stage
# .bump-failed 흔적에서 **허용 <stage> 토큰**만 출력합니다. 그 밖에는 빈 문자열입니다.
# change spec §2.12 ② — reason 은 JSON 문자열 한 줄이므로 흔적 내용을 그대로 끼워 넣지 않고
# **고정 4토큰 allowlist** 로만 통과시킵니다. 이스케이프 구현은 셸에서 실수하기 쉽고,
# 이 용도에 필요한 값의 집합이 애초에 유한합니다.
#
# 허용 조건은 **파일 전체 대조**입니다 — 내용이 정확히 <token> 이거나 <token> + 종단 LF
# 1개일 때만 허용합니다. **첫 줄만 읽어 판정하면 안 됩니다**: 'pointer-swap\n<임의 내용>'
# 같은 다중행 값이 첫 줄 검사만으로 통과하면 allowlist 가 무의미해집니다.
# 바이트 길이(stat)와 내용을 함께 보므로 NUL 을 끼운 우회도 길이에서 걸립니다.
# 부재·읽기 실패(경로가 디렉토리 등)·빈 파일·LF 하나·CR·앞뒤 공백·2개 이상의 LF 는 모두 비허용입니다.
#
# **이 함수는 판정에 참여하지 않습니다** — 호출 지점은 block 이 확정된 뒤 한 곳뿐입니다.
_bump_failed_stage() {
  # 헬퍼 미설치(부분 install)면 흔적 경로를 알 수 없으므로 사유를 생략합니다.
  declare -f ep_root >/dev/null 2>&1 || return 0
  local trace size content="" tok
  trace="$(ep_root)/.bump-failed"
  # -f 검사가 디렉토리·특수 파일을 먼저 걸러 읽기 실패 갈래를 흡수합니다.
  [[ -f "$trace" ]] || return 0
  size="$(stat -f %z "$trace" 2>/dev/null || stat -c %s "$trace" 2>/dev/null || true)"
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  IFS= read -r -d '' content < "$trace" 2>/dev/null || true
  for tok in mkdir short-title recheck pointer-swap; do
    if [[ "$size" -eq "${#tok}" && "$content" == "$tok" ]]; then
      printf '%s' "$tok"; return 0
    fi
    if [[ "$size" -eq $(( ${#tok} + 1 )) && "$content" == "${tok}"$'\n' ]]; then
      printf '%s' "$tok"; return 0
    fi
  done
  return 0
}

# 1. stdin 읽기 + stop_hook_active=true면 무한루프 방지를 위해 즉시 통과
read_hook_input
[[ "$(read_stop_hook_active)" == "true" ]] && exit 0

# 2. autopilot 활성 시 통과
is_autopilot_active && exit 0

# 3. 비차단 Status(빈값 / '대기 중' / '완료')면 통과
status="$(get_task_status)"
is_nonblocking_status "$status" && exit 0

# 4. CURRENT_TASK.md가 stale하지 않으면 통과
#    판정은 _guard_common.sh:current_task_is_stale() 이 단독으로 정합니다 — 이 앞에 어떤
#    조건도 추가하지 않습니다(통과 경로는 무출력 그대로여야 합니다, change spec §2.12 ②).
current_task_is_stale || exit 0

# 5. stale 감지 — block 신호 출력 후 exit 0 (Claude Code가 reason을 LLM에 전달)
#    block 이 **확정된 뒤**에만 .bump-failed 를 읽어 사유 한 문장을 덧붙입니다.
#    CURRENT_TASK.md 를 Edit/Write 로 직접 저장하는 경로는 bump 주체가 producer hook 이고
#    그 hook 은 출력이 버려지므로, 저장 직후의 false positive 를 사용자가 관찰할 수 있는
#    채널이 이 문구뿐입니다. 판정 결과(block/통과)는 바뀌지 않습니다.
reason='CURRENT_TASK.md가 mid-work인데 갱신되지 않았습니다. 진행 상태(Status / Next Step / Notes)를 저장한 뒤 종료하세요.'
stage="$(_bump_failed_stage)"
if [[ -n "$stage" ]]; then
  reason="${reason} (참고: 직전 저장에서 편집 기록 갱신이 실패해(지점: ${stage}) 이 알림이 실제 미저장이 아닐 수 있습니다. 다음 저장에서 복구됩니다.)"
fi
printf '{"decision":"block","reason":"%s"}\n' "$reason"
exit 0
