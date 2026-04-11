#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
cd "${project_root}"

source "${script_dir}/review_common.sh"
PROJECT_ROOT="$project_root"

turn_limit="${REVIEW_TURN_LIMIT:-20}"

usage() {
  cat <<'EOF' >&2
사용법:
  bash ai/scripts/run_review_turn.sh <session-path>

예:
  bash ai/scripts/run_review_turn.sh ai/workspace/handoffs/review_pipeline/20260313_120000_request-review
EOF
}

# --- 설정 경로 (단일 변수, 모든 config 조회에 공유) ---
CONFIG_FILE="${REVIEW_TOOLS_CONFIG:-${project_root}/ai/config/review-tools.json}"

# --- 설정 로드 ---
load_review_config() {
  local review_type="${1:-}"

  PRIORITY="codex claude"

  if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
    # config 파일 파싱 실패 시 기본값으로 fallback (hard error 방지)
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
      echo "⚠️  설정 파일 파싱 실패: $CONFIG_FILE" >&2
      echo "    기본 설정으로 진행합니다: codex → claude" >&2
      PRIORITY="codex claude"
      return
    fi

    PRIORITY="$(jq -r '.default_priority | join(" ")' "$CONFIG_FILE")"

    # 리뷰 타입별 오버라이드
    if [[ -n "$review_type" ]]; then
      local override
      override="$(jq -r --arg rt "$review_type" '.overrides[$rt].priority // empty | join(" ")' "$CONFIG_FILE")"
      if [[ -n "$override" ]]; then
        PRIORITY="$override"
      fi
    fi
  elif [[ -f "$CONFIG_FILE" ]]; then
    echo "⚠️  jq가 설치되지 않아 기본 설정을 사용합니다." >&2
    echo "    설정 파일을 적용하려면: brew install jq" >&2
  fi
}

# --- 도구별 설정 조회 ---
get_tool_config() {
  local tool_name="$1"
  local field="$2"
  local default_val="$3"

  if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
    # config 유효성은 load_review_config에서 이미 검증됨
    local val
    val="$(jq -r --arg t "$tool_name" --arg f "$field" 'if .tools[$t] | has($f) then .tools[$t][$f] else null end' "$CONFIG_FILE")"
    if [[ "$val" != "null" && -n "$val" ]]; then
      printf '%s' "$val"
      return
    fi
  fi
  printf '%s' "$default_val"
}

# --- 메인 ---
case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

session_dir="$(resolve_path "$1")"

if [[ ! -d "$session_dir" ]]; then
  echo "session directory not found: $session_dir" >&2
  exit 1
fi

validate_session_dir "$session_dir"
load_session_state "$SESSION_FILE"

if [[ "$STATUS" != "awaiting-reviewer" ]]; then
  echo "session is not awaiting reviewer: status=$STATUS" >&2
  exit 1
fi

if [[ "$CURRENT_OWNER" != "Reviewer" ]]; then
  echo "current owner is not Reviewer: owner=$CURRENT_OWNER" >&2
  exit 1
fi

load_review_config "$REVIEW_TYPE"
compute_next_turn "$TURNS_DIR" "reviewer"

relative_session_dir="${session_dir#${project_root}/}"
relative_session_file="${SESSION_FILE#${project_root}/}"
relative_checkpoint_file="${CHECKPOINT_FILE#${project_root}/}"
relative_user_action_file="${USER_ACTION_FILE#${project_root}/}"
relative_expected_turn_file="${EXPECTED_TURN_FILE#${project_root}/}"
relative_latest_turn_file="${LATEST_TURN_FILE#${project_root}/}"

if [[ "$EXISTING_TURN_COUNT" -ge "$turn_limit" || "$NEXT_TURN_INDEX" -gt "$turn_limit" ]]; then
  echo "session already reached the turn limit (${turn_limit}): $relative_session_dir" >&2
  exit 1
fi

# 프롬프트 생성
prompt_file="$(mktemp)"
chmod 600 "$prompt_file"
cleanup() { rm -f "$prompt_file"; }
trap cleanup EXIT

build_review_prompt "$prompt_file" \
  "$relative_session_dir" "$relative_session_file" \
  "$relative_checkpoint_file" "$relative_user_action_file" \
  "$relative_latest_turn_file" "$relative_expected_turn_file" \
  "$REVIEW_TYPE" "$REVIEW_TARGET" "$REVIEW_GOAL" \
  "$turn_limit" "$NEXT_TURN_NUMBER"

# --- Fallback 루프 ---
succeeded=false
used_tool=""

for tool in $PRIORITY; do
  adapter="${script_dir}/adapter_${tool}.sh"

  if [[ ! -f "$adapter" ]]; then
    echo "어댑터 없음, 건너뜀: $tool" >&2
    continue
  fi

  tool_bin="$(get_tool_config "$tool" "bin" "")"
  tool_model="$(get_tool_config "$tool" "model" "")"
  self_review_warning="$(get_tool_config "$tool" "self_review_warning" "true")"

  # 바이너리 존재 확인 (없으면 다음 도구로 — fallback 허용)
  check_bin="${tool_bin:-$tool}"
  if ! command -v "$check_bin" &>/dev/null; then
    echo "바이너리 없음, 건너뜀: ${tool} (${check_bin})" >&2
    continue
  fi

  echo "--- 리뷰 도구 실행: ${tool} ---" >&2

  export SESSION_PATH="$session_dir"
  export PROMPT_FILE="$prompt_file"
  export EXPECTED_TURN_FILE="$EXPECTED_TURN_FILE"
  export TOOL_BIN="$tool_bin"
  export TOOL_MODEL="$tool_model"
  export PROJECT_ROOT="$project_root"
  export SELF_REVIEW_WARNING="$self_review_warning"

  # 어댑터 실행 — 실행 후 실패하면 즉시 중단 (세션 오염 가능)
  if bash "$adapter"; then
    succeeded=true
    used_tool="$tool"
    break
  else
    echo "어댑터 실행 실패: ${tool}. 세션이 오염되었을 수 있으므로 즉시 중단합니다." >&2
    exit 1
  fi
done

if [[ "$succeeded" != "true" ]]; then
  echo "모든 리뷰 도구가 실패했습니다: $PRIORITY" >&2
  exit 1
fi

# --- 출력 검증 ---
updated_status="$(validate_turn_output "$SESSION_FILE" "$EXPECTED_TURN_FILE" "$NEXT_TURN_INDEX" "$turn_limit" "$used_tool")"

# --- Tool History 기록 ---
if [[ "$used_tool" == "claude" ]]; then
  mode="self-review"
else
  mode="reviewer"
fi
append_tool_history "$SESSION_FILE" "$NEXT_TURN_NUMBER" "$used_tool" "$mode"

# --- 결과 출력 ---
updated_owner="$(extract_section "$SESSION_FILE" "Current Owner" | trim_blank_lines)"

echo "review turn completed (tool: ${used_tool})"
echo "session: ${relative_session_dir}"
echo "turn: ${relative_expected_turn_file}"
echo "status: ${updated_status}"
echo "owner: ${updated_owner}"
