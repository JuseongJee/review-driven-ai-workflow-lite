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
# 이 hook 에 남은 판정은 이것 하나다 — 단계 게이트(리뷰 대기 중 소스 수정 차단)는
# 오탐만 남기고 실제로 막은 이력이 없어 2026-08-20 게이트 정리에서 제거했다.
# 여기서 autopilot·워크플로 파일 예외를 두지 않는 이유: 유실 사고가 autopilot 실행 중에
# 발생했으므로, autopilot 일 때 꺼지는 차단은 그 사고를 막지 못한다 (시나리오 13 이 고정).
# is_shared_state_file 은 프로젝트 밖 절대 경로에 스스로 return 1 을 반환하므로
# 프로젝트 밖 편집은 그대로 통과한다 (시나리오 27 이 고정).
if [[ -n "$(read_hook_agent_id)" ]] && is_shared_state_file "$file_path"; then
  rel_path="$(normalize_lexical_path "$file_path")"
  root_norm_path="$(normalize_lexical_path "$project_root")"
  rel_path="${rel_path#"${root_norm_path}/"}"
  echo "[guard] 이 파일은 orchestrator(메인 세션) 전용입니다: ${rel_path}" >&2
  echo "        병렬 구현자는 공유 진행 상태를 수정하지 않습니다." >&2
  echo "        진행 상황·완료 보고는 결과 텍스트로 반환하면 orchestrator 가 반영합니다." >&2
  exit 2
fi

exit 0
