#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

read_hook_input
file_path="$(extract_json_field "file_path")"

# file_path가 비어있으면 통과
[[ -z "$file_path" ]] && exit 0

# autopilot 활성 시 통과
is_autopilot_active && exit 0

# 워크플로 파일이면 통과
is_workflow_file "$file_path" && exit 0

# Status 확인 — "구현 중" (full) 또는 "실행 중" (lite)
status="$(get_task_status)"
if [[ "$status" == "구현 중" || "$status" == "실행 중" ]]; then
  exit 0
fi

echo "[guard] 현재 단계에서는 구현 파일을 수정할 수 없습니다 (Status: ${status:-없음})" >&2
exit 2
