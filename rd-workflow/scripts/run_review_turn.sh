#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
cd "${project_root}"

source "${script_dir}/review_common.sh"
PROJECT_ROOT="$project_root"

# turn_limit은 session 검증 후 SESSION.md에서 읽음 (source-of-truth).
# 변수는 read_session_turn_limit 호출 시점에 설정.

usage() {
  cat <<'EOF' >&2
사용법:
  bash rd-workflow/scripts/run_review_turn.sh <session-path>

예:
  bash rd-workflow/scripts/run_review_turn.sh rd-workflow-workspace/handoffs/review_pipeline/20260313_120000_request-review
EOF
}

# --- 설정 경로 (단일 변수, 모든 config 조회에 공유) ---
CONFIG_FILE="${REVIEW_TOOLS_CONFIG:-${project_root}/rd-workflow/config/review-tools.json}"
review_type=""   # load_review_config가 설정 — set -u 방어용 전역 초기화

# --- 설정 로드 (통합 파싱 — spec §2 결정 3) ---
# review-tools.json 을 프로세스당 jq 정확히 최대 1회 호출로 파싱한다.
# 출력 형식: TSV(key<TAB>value) — 값 내 '='·공백이 있어도 경계가 보존된다 (jq @tsv).
# null 필드는 문자열 "null" 로, missing 필드는 행 자체 부재로 구분된다 (현행 has($f) 계약 보존).
# jq 부재 또는 JSON 손상 시 기본값으로 fallback — 별도 유효성 검사 호출 없음.
REVIEW_CFG_KV=""

load_review_config_once() {
  PRIORITY="codex claude"

  if ! [[ -f "$CONFIG_FILE" ]]; then
    return 0
  fi

  if ! command -v jq &>/dev/null; then
    echo "⚠️  jq가 설치되지 않아 기본 설정을 사용합니다." >&2
    echo "    설정 파일을 적용하려면: brew install jq" >&2
    return 0
  fi

  local kv
  # TSV 통합 추출 — jq 1회 호출 (별도 유효성 검사 없음, 파싱 실패 시 || fallback)
  # 추출 항목:
  #   priority<TAB><공백 구분 우선순위 문자열>
  #   tool.<이름>.<필드><TAB><값 또는 "null">
  # null 필드는 tostring → "null" 문자열, missing 필드는 행 부재 (has($f) 계약과 동일).
  if ! kv="$(jq -r --arg rt "$review_type" '
    ( [ "priority",
        (((.overrides // {})[$rt].priority // .default_priority) | join(" ")) ]
      | @tsv ),
    ( (.tools // {}) | to_entries[] | .key as $t | .value | to_entries[]
      | [ "tool.\($t).\(.key)", (.value | tostring) ]
      | @tsv )
  ' "$CONFIG_FILE" 2>/dev/null)"; then
    echo "⚠️  설정 파일 파싱 실패: $CONFIG_FILE" >&2
    echo "    기본 설정으로 진행합니다: codex → claude" >&2
    return 0
  fi

  REVIEW_CFG_KV="$kv"
  local p
  p="$(printf '%s\n' "$kv" | awk -F'\t' '$1=="priority"{print $2; exit}')"
  [[ -n "$p" ]] && PRIORITY="$p"
}

# load_review_config — 기존 호출자(L118)와의 인터페이스 유지.
# review_type 을 전역 변수로 노출 후 통합 파싱 함수를 위임한다.
load_review_config() {
  review_type="${1:-}"
  load_review_config_once
}

# --- 도구별 설정 조회 ---
# 시그니처·null/missing 계약 불변 — 내부만 REVIEW_CFG_KV 조회로 교체.
# jq 재호출 없음 (spec AC 3).
# null 필드: REVIEW_CFG_KV 에 "null" 문자열로 저장 → 기본값 반환.
# missing 필드: 행 부재 → awk 출력 없음 → 빈 값 → 기본값 반환.
get_tool_config() {
  local tool_name="$1"
  local field="$2"
  local default_val="$3"

  if [[ -n "${REVIEW_CFG_KV:-}" ]]; then
    local val
    val="$(printf '%s\n' "$REVIEW_CFG_KV" \
      | awk -F'\t' -v k="tool.${tool_name}.${field}" '$1==k{print $2; exit}')"
    if [[ "$val" != "null" && -n "$val" ]]; then
      printf '%s' "$val"
      return
    fi
    printf '%s' "$default_val"
    return
  fi

  # jq 부재 또는 파싱 실패 시 fallback (REVIEW_CFG_KV 가 비어있는 경우)
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
turn_limit="$(read_session_turn_limit "$SESSION_FILE")"

# Branch Context strict 검증 (Task 8 — fr-branch-tag-lifecycle)
if declare -f validate_branch_context >/dev/null 2>&1; then
  if ! validate_branch_context "$session_dir"; then
    echo "review turn: branch context 불일치로 중단" >&2
    exit 1
  fi
fi

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

  # self-review 게이트 (safeguard-self-review-block)
  # reviewer tool 이 claude 이면 generator==reviewer(self-review) — 정책에 따라 차단/승인/진행
  if [[ "$tool" == "claude" ]]; then
    sr_policy="$(resolve_self_review_policy \
      "$(get_tool_config claude self_review_policy "")" \
      "$self_review_warning")"
    sr_decision="$(evaluate_self_review_gate "$sr_policy" "${RD_AUTOPILOT:-}" "${RD_SELF_REVIEW_APPROVE:-}")"
    case "$sr_decision" in
      block)
        record_self_review_block "$USER_ACTION_FILE"
        echo "self-review 차단: 독립 reviewer 부재 + self_review_policy=block." >&2
        echo "재개 방법은 ${relative_user_action_file} 를 참조하세요." >&2
        exit 3
        ;;
      proceed-silent)
        self_review_warning="false"
        ;;
      proceed-warn)
        self_review_warning="true"
        ;;
      proceed-autopilot)
        self_review_warning="true"
        echo "autopilot: self-review 차단 정책이나 자율성 보존을 위해 자동 진행합니다 (mode=self-review 기록)." >&2
        ;;
    esac
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
