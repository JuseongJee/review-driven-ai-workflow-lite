#!/usr/bin/env bash
# session_start.sh — 세션 시작 시 환경 확인
set -euo pipefail

# SessionStart 훅 입력(JSON)을 읽는다. 닫히지 않는 stdin 에서도 1초 뒤 진행한다.
hook_input=""
[[ -t 0 ]] || IFS= read -r -t 1 -d '' hook_input || true

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"
source "${script_dir}/_compact_hint.sh"

PROJECT_CONTEXT="${project_root}/PROJECT_CONTEXT.md"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " AI Workflow (Lite) 세션 시작"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ! -f "$PROJECT_CONTEXT" ]]; then
  echo ""
  echo "WARNING: PROJECT_CONTEXT.md가 없습니다."
  echo "  프로젝트 설정을 먼저 완료하세요."
fi

# CURRENT_TASK.md 상태 출력
task_file="${project_root}/CURRENT_TASK.md"
if [[ -f "$task_file" ]]; then
  task="$(_extract_task_section "Task")"
  status="$(get_task_status)"

  [[ "$task" == "-" || -z "$task" ]] && task="(설정되지 않음)"
  [[ "$status" == "-" || -z "$status" ]] && status="(설정되지 않음)"

  echo ""
  echo "[hooks] 현재 작업: ${task} (${status})"

  compact_hint_emit "$hook_input" "$status" "$(state_read_field short-title)" "$project_root"
fi

# --- diff-review 누락 경고 (Layer 2) ---

if ! is_autopilot_active; then
  review_dir="$(get_latest_diff_review_dir)"

  if [[ -n "$review_dir" ]]; then
    checkpoint="${review_dir}/CHECKPOINT.md"
    if [[ -f "$checkpoint" ]]; then
      has_real_issues="$(awk '
        /^## Open Issues/ { in_section = 1; next }
        in_section && /^## / { exit }
        in_section && /^- / && !/^- 없음/ { found = 1; exit }
        END { print (found ? "yes" : "no") }
      ' "$checkpoint")"

      if [[ "$has_real_issues" == "yes" ]]; then
        echo "[guard] 최신 diff-review에 미해결 이슈가 있습니다." >&2
      fi
    fi
  else
    head_epoch="$(git -C "$project_root" log -1 --format=%ct 2>/dev/null || echo 0)"
    if [[ "$head_epoch" -gt 0 ]]; then
      echo "[guard] diff-review 세션이 없습니다. 새 프로젝트라면 무시해도 됩니다." >&2
    fi
  fi
fi
