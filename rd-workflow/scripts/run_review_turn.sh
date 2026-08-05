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
  # codex reasoning effort 3행 — 단계별 별도 키로 낸다 (spec §4.3).
  # `//` 체인으로 effective value 만 뽑으면 source 근거가 소실되고,
  # override 와 tool 기본값이 같은 값일 때 구분이 불가능하다. 우선순위 해석은 bash 가 한다.
  if ! kv="$(jq -r --arg rt "$review_type" '
    ( [ "priority",
        (((.overrides // {})[$rt].priority // .default_priority) | join(" ")) ]
      | @tsv ),
    ( (.tools // {}) | to_entries[] | .key as $t | .value | to_entries[]
      | [ "tool.\($t).\(.key)", (.value | tostring) ]
      | @tsv ),
    ( [ "tool.codex.effort_override",
        ( ((.overrides // {})[$rt].tools.codex.reasoning_effort) // "" ) ] | @tsv ),
    ( [ "tool.codex.effort_default",
        ( (.tools.codex.reasoning_effort) // "" ) ] | @tsv ),
    ( [ "tool.codex.small_task_effort",
        ( (.tools.codex.small_task_reasoning_effort) // "" ) ] | @tsv )
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

# === A: codex reasoning effort override (review-turn-latency-reduction) ===
# 모델은 override 하지 않는다 — 전역 ~/.codex/config.toml 이 단일 진실 원천이다.
# 허용 하한(medium) 미만으로 거부할 값. 하한 검증은 small-task 자동 판정 경로에만 적용한다.
# review type override 와 tool 기본값은 사용자가 리뷰 타입을 명시 지정한 것이므로
# 하한을 강제하지 않는다 (spec §4.2).
EFFORT_FLOOR_REJECT="low minimal"

# effort 해석 결과 (set -u 방어용 전역 초기화)
EFFORT_VALUE=""      # 빈 값이면 미전달 = 전역 config 를 따름
EFFORT_SOURCE="global"
EFFORT_REJECTED=""

# SESSION.md 의 `## Review Scope` 에서 execution-path 를 읽는다.
# 섹션·필드 부재(init_review_pipeline.sh 직접 호출로 만든 legacy 세션)나
# 인식 불가 값은 unknown 으로 흡수되어 effort 가 적용되지 않는다 (AC 8).
read_execution_path() {
  local session_file="$1" v=""
  if [[ -f "$session_file" ]]; then
    v="$(awk '
      /^## Review Scope/ { f=1; next }
      f && /^## / { exit }
      f && /^- execution-path:/ {
        sub(/^- execution-path:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit
      }' "$session_file")"
  fi
  case "$v" in
    small-task|other) printf '%s' "$v" ;;
    *)                printf 'unknown' ;;
  esac
}

# 우선순위: kill switch → small-task → review type override → tool 기본 → 미전달 (spec §4.2).
# 미전달일 때도 EFFORT_SOURCE 에 근거를 남긴다 (global | kill-switch | below-floor) —
# 가시성 상태 5종이 서로 구분되어야 하기 때문이다 (§4.7).
resolve_effort_override() {
  local exec_path="$1"
  EFFORT_VALUE=""
  EFFORT_SOURCE="global"
  EFFORT_REJECTED=""

  # 1) kill switch. override 는 최적화이고 kill 은 안전장치이므로 불확실하면 최적화를 포기한다.
  if [[ -n "${RD_REVIEW_EFFORT_OVERRIDE+x}" ]]; then
    if [[ "${RD_REVIEW_EFFORT_OVERRIDE}" != "0" ]]; then
      echo "⚠️  RD_REVIEW_EFFORT_OVERRIDE 값을 인식할 수 없습니다: ${RD_REVIEW_EFFORT_OVERRIDE} (허용: 미설정 또는 0)" >&2
      echo "    effort override 를 적용하지 않고 전역 설정을 따릅니다." >&2
    fi
    EFFORT_SOURCE="kill-switch"
    return 0
  fi

  # 2) small-task. 키가 있을 때만 적용한다 — 키 부재는 자동 medium 이 아니라 다음 단계다 (AC 6).
  local st
  st="$(get_tool_config codex small_task_effort "")"
  if [[ "$exec_path" == "small-task" && -n "$st" ]]; then
    case " $EFFORT_FLOOR_REJECT " in
      *" $st "*)
        echo "⚠️  small_task_reasoning_effort=${st} 은 허용 하한(medium) 미만입니다." >&2
        echo "    조용한 값 보정을 하지 않고 effort 를 전달하지 않습니다." >&2
        EFFORT_SOURCE="below-floor"
        EFFORT_REJECTED="$st"
        return 0
        ;;
    esac
    EFFORT_VALUE="$st"
    EFFORT_SOURCE="small-task"
    return 0
  fi

  # 3) review type override
  local ov
  ov="$(get_tool_config codex effort_override "")"
  if [[ -n "$ov" ]]; then
    EFFORT_VALUE="$ov"
    EFFORT_SOURCE="review-type"
    return 0
  fi

  # 4) tool 기본
  local df
  df="$(get_tool_config codex effort_default "")"
  if [[ -n "$df" ]]; then
    EFFORT_VALUE="$df"
    EFFORT_SOURCE="tool-default"
    return 0
  fi

  # 5) 미전달 — 전역 config 를 따른다 (현행 동작 = 후퇴 없음, AC 2)
  return 0
}

# 턴 완료 후 실제 적용 상태 (spec §4.7 상태 5종).
# 어댑터는 effort 를 받으면 그대로 전달하고, 값이 거부되면 즉시 실패한다(자동 재시도 없음).
# 따라서 "턴이 성공했고 effort 를 전달했다" = "codex 가 그 값을 수락했다" 이며,
# 부모가 아는 정보만으로 상태를 결정할 수 있다. 별도 결과 채널이 필요하지 않다.
# 도구가 codex 가 아니면 effort 개념 자체가 없으므로 그 값을 보고하지 않는다.
compute_effort_status() {
  local tool="$1"

  if [[ "$tool" != "codex" ]]; then
    printf 'not-applicable (tool=%s)' "$tool"
    return 0
  fi

  if [[ -z "$EFFORT_VALUE" ]]; then
    case "$EFFORT_SOURCE" in
      kill-switch) printf 'disabled-by-kill-switch' ;;
      below-floor) printf 'rejected-below-floor:%s' "$EFFORT_REJECTED" ;;
      *)           printf 'none/global' ;;
    esac
    return 0
  fi

  printf 'applied:%s (source: %s)' "$EFFORT_VALUE" "$EFFORT_SOURCE"
}

# --- 메인 ---
# 테스트 seam: `source run_review_turn.sh` 로 호출되면 함수 정의만 로드하고 반환한다.
# production 경로는 항상 `bash run_review_turn.sh <session>` 이므로 동작이 바뀌지 않는다.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

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

# --- A: effort override 해석 (spec §4.2) ---
# 판정 원본은 세션 생성 시 SESSION.md 에 고정 기록된 execution-path 다.
# 턴마다 REQUEST.md 를 재파싱하지 않으므로 REQUEST 아카이브 후에도 안전하다.
EXECUTION_PATH="$(read_execution_path "$SESSION_FILE")"
resolve_effort_override "$EXECUTION_PATH"

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

  # effort 는 codex 고유 개념이므로 codex invocation 에만 주입한다 (spec §4.5).
  # `env -u` 로 먼저 **제거**하는 것이 핵심이다. 호출자 환경에 이 변수들이 남아 있으면
  # ① kill switch 를 켜도 어댑터가 상속값을 읽어 실제로 effort 를 전달하고
  # ② claude 어댑터도 상속받아 "codex 전용" 계약이 입력 환경에 따라 깨지며
  # ③ 부모 표시는 계산값을 보고하므로 표시와 실제가 어긋난다.
  adapter_env=(env -u TOOL_EFFORT -u EFFORT_SOURCE)
  if [[ "$tool" == "codex" ]]; then
    if [[ -n "$EFFORT_VALUE" ]]; then
      adapter_env+=("TOOL_EFFORT=${EFFORT_VALUE}" "EFFORT_SOURCE=${EFFORT_SOURCE}")
    fi
    printf '리뷰 도구: %s / effort 시도: %s (source: %s)\n' \
      "$tool" "${EFFORT_VALUE:-none}" "$EFFORT_SOURCE" >&2
  else
    printf '리뷰 도구: %s / effort 시도: none (source: not-applicable)\n' "$tool" >&2
  fi

  # 어댑터 실행 — 실행 후 실패하면 즉시 중단 (세션 오염 가능)
  if "${adapter_env[@]}" bash "$adapter"; then
    succeeded=true
    used_tool="$tool"
    break
  else
    echo "어댑터 실행 실패: ${tool}. 세션이 오염되었을 수 있으므로 즉시 중단합니다." >&2
    # effort 를 전달했다면 무효값 가능성을 알리고 복구 경로를 제시한다.
    # 자동 재시도는 하지 않는다 — 어느 지점에서 실패했는지 증명할 수 없으면
    # 두 번째 agent 가 부분 수정된 세션을 이어서 고칠 위험이 더 크다.
    if [[ "$tool" == "codex" && -n "$EFFORT_VALUE" ]]; then
      echo "    reasoning effort '${EFFORT_VALUE}' (source: ${EFFORT_SOURCE}) 를 전달했습니다." >&2
      echo "    이 값이 현재 모델에서 지원되지 않으면 codex 가 설정을 거부합니다. 복구 방법:" >&2
      echo "      - 즉시 무력화: RD_REVIEW_EFFORT_OVERRIDE=0 을 설정하고 다시 실행" >&2
      echo "      - 영구 해제: rd-workflow/config/review-tools.json 에서 해당 effort 키 제거" >&2
    fi
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
echo "effort override: $(compute_effort_status "$used_tool")"
