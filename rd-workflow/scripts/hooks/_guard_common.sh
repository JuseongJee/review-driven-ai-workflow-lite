#!/usr/bin/env bash
# _guard_common.sh — source 전용, 직접 실행 불가
# 워크플로 guard hook 공통 함수

[[ -z "${project_root:-}" ]] && { echo "[guard] project_root가 설정되지 않았습니다" >&2; exit 1; }

# --- autopilot ---

is_autopilot_active() {
  [[ -f "${project_root}/.autopilot_active" ]]
}

# --- CURRENT_TASK.md 파싱 ---

_extract_task_section() {
  local file="${project_root}/CURRENT_TASK.md"
  local section="$1"
  [[ ! -f "$file" ]] && return
  awk -v target="## ${section}" '
    $0 == target { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) { print; exit } }
  ' "$file"
}

get_task_status() {
  _extract_task_section "Status"
}

# --- diff-review 세션 ---

get_latest_diff_review_dir() {
  local base="${project_root}/rd-workflow-workspace/handoffs/review_pipeline"
  [[ ! -d "$base" ]] && return
  local latest=""
  for dir in "${base}/"*_final-diff-review; do
    [[ -d "$dir" ]] && latest="$dir"
  done
  [[ -n "$latest" ]] && printf '%s' "$latest"
}

# --- 워크플로 파일 판정 ---

is_workflow_file() {
  local filepath="$1"
  local rel="${filepath#"${project_root}/"}"

  case "$rel" in
    CURRENT_TASK.md|REQUEST.md|PROJECT_CONTEXT.md|SESSION.md|CHECKPOINT.md) return 0 ;;
    */turns/*.md) return 0 ;;
    rd-workflow-workspace/*) return 0 ;;
  esac
  return 1
}

# --- JSON 파싱 ---

_hook_input=""

read_hook_input() {
  _hook_input="$(cat)"
}

extract_json_field() {
  local field="$1"
  local value=""

  if command -v jq &>/dev/null; then
    value="$(printf '%s' "$_hook_input" | jq -r ".tool_input.${field} // empty" 2>/dev/null || true)"
  fi

  if [[ -z "$value" ]]; then
    # bash 폴백: "field" 뒤의 : 과 " 사이 공백을 허용
    local tmp="${_hook_input#*\"${field}\"}"
    if [[ "$tmp" != "$_hook_input" ]]; then
      tmp="${tmp#*:}"     # : 이후
      tmp="${tmp#*\"}"    # 첫 번째 " 이후
      value="${tmp%%\"*}" # 다음 " 까지
    fi
  fi

  printf '%s' "$value"
}
