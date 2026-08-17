#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

read_hook_input
file_path="$(extract_json_field "file_path")"

# file_path가 비어있으면 통과
[[ -z "$file_path" ]] && exit 0

# subagent 는 공유 진행 상태 파일을 쓰지 않는다 (plan-parallel-phases 규약).
# 기존 통과 분기 전부보다 앞이다 — 두 가지 이유가 있다.
#   ① autopilot 통과(아래)보다 앞: 유실 사고가 autopilot 실행 중 발생했으므로,
#      autopilot 일 때 꺼지는 차단은 그 사고를 막지 못한다 (시나리오 13 이 고정).
#   ② project_root 밖 통과(아래)보다 앞: 그 분기는 원시 문자열 접두 비교라서,
#      정규화하면 프로젝트 안이 되는 경로를 차단 판정에 닿기 전에 통과시킨다
#      (시나리오 27 이 고정). is_shared_state_file 은 프로젝트 밖 절대 경로에
#      스스로 return 1 을 반환하므로 이 위치가 밖 경로 동작을 바꾸지 않는다.
if [[ -n "$(read_hook_agent_id)" ]] && is_shared_state_file "$file_path"; then
  rel_path="$(normalize_lexical_path "$file_path")"
  root_norm_path="$(normalize_lexical_path "$project_root")"
  rel_path="${rel_path#"${root_norm_path}/"}"
  echo "[guard] 이 파일은 orchestrator(메인 세션) 전용입니다: ${rel_path}" >&2
  echo "        병렬 구현자는 공유 진행 상태를 수정하지 않습니다." >&2
  echo "        진행 상황·완료 보고는 결과 텍스트로 반환하면 orchestrator 가 반영합니다." >&2
  exit 2
fi

# project_root 밖의 절대 경로는 워크플로 가드 대상이 아님 (예: ~/.claude/ plan·메모리)
if [[ "$file_path" == /* && "$file_path" != "${project_root}/"* ]]; then
  exit 0
fi

# autopilot 활성 시 통과
is_autopilot_active && exit 0

# 워크플로 파일이면 통과
is_workflow_file "$file_path" && exit 0

# Status 확인
status="$(get_task_status)"

# 활성 작업이 없으면("대기 중" 또는 빈 값) 자유 수정 허용
if [[ -z "$status" || "$status" == "대기 중" || "$status" == "완료" ]]; then
  exit 0
fi

# 활성 작업이 있을 때 — "구현 중" (full) 또는 "실행 중" (lite)만 허용
if [[ "$status" == "구현 중" || "$status" == "실행 중" ]]; then
  exit 0
fi

echo "[guard] 현재 단계에서는 구현 파일을 수정할 수 없습니다 (Status: ${status:-없음})" >&2
exit 2
