#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
cd "${project_root}"

source "${script_dir}/review_common.sh"
# rd_resolve_commit_oid (저장소 native full OID resolve) 를 쓰기 위해 로드합니다 (§3.2.1).
# **조건부 로드**입니다 — 이 스크립트만 복사해 쓰는 격리 fixture 가 있어서(예:
# test_review_effort_override.sh 의 iso fixture) 무조건 source 하면 그 경로가 죽습니다.
# 대신 실제로 필요할 때(reviewed OID 가 있는 diff-review 세션) 함수 부재를 fail-closed 로
# 판정합니다 — resnapshot_review_head 참조.
if [[ -f "${script_dir}/_state_common.sh" ]]; then
  source "${script_dir}/_state_common.sh"
fi
# 리뷰 대상 문자열·완전성 검사. 같은 이유로 조건부 로드이며, 함수가 없으면 호출 자리가 fail-closed 로 막습니다.
if [[ -f "${script_dir}/_submodule_common.sh" ]]; then
  source "${script_dir}/_submodule_common.sh"
fi
# 리뷰어 모델·effort 선택 함수(ms_*) — 무조건 로드합니다. 실행기를 복제하는 fixture 는 이 파일도 함께 복사합니다.
source "${script_dir}/model_select.sh"
PROJECT_ROOT="$project_root"

# turn_limit은 session 검증 후 SESSION.md에서 읽음 (source-of-truth).
# 변수는 read_session_turn_limit 호출 시점에 설정.

usage() {
  cat <<'EOF' >&2
사용법:
  bash rd-workflow/scripts/run_review_turn.sh <session-path>
  bash rd-workflow/scripts/run_review_turn.sh <session-path> --reopen "<사유>"
  bash rd-workflow/scripts/run_review_turn.sh <session-path> --decision "<사용자 결정>"
  bash rd-workflow/scripts/run_review_turn.sh <session-path> --override "<결정한 사람> — <그 사람이 한 말>"
  (턴 한도에 도달한 세션은 --decision·--reopen 실행이나 옵션 없는 Author 턴 전환 실행에 --extend-turns <N> 을 붙입니다. --override 와는 함께 쓰지 않습니다)

--reopen: 이의 없음으로 수렴해 awaiting-user 로 끝난 세션을 다시 열어 재확인 Reviewer 턴을 돌립니다.
  먼저 바뀐 내용을 적은 Author 턴(turns/NNN_author.md)을 씁니다. 사유는 SESSION 의 Reopen History 에 남습니다.
  미해결 이의가 남은 세션(사람 답을 기다리는 세션)과 closed 세션은 다시 열지 않습니다.
--decision: 미해결 이의가 남아 awaiting-user 로 멈춘 세션에 사람이 결정한 뒤 이어 갑니다.
  먼저 결정을 반영한 Author 턴을 씁니다. 결정은 SESSION 의 Reopen History 와 USER_ACTION.md 의
  ## User Decision 에 남고, 이어서 Reviewer 턴을 돌립니다.
--override: 사람이 남은 이의를 덮고 종결하기로 정했을 때 씁니다. Closure Reason 을 user-override 와
  '근거: <오늘 날짜> <입력>' 줄로 쓰고 Status 를 closed 로 바꿉니다. Reviewer 턴은 돌리지 않습니다.
--extend-turns <N>: 턴 한도에 도달한 세션의 한도를 N 턴 늘리고 Reviewer 턴을 이어 돌립니다. 한도에 도달하지 않은 세션과
  --override(종결) 에는 쓰지 않습니다.

예:
  bash rd-workflow/scripts/run_review_turn.sh rd-workflow-workspace/handoffs/review_pipeline/20260313_120000_request-review
  bash rd-workflow/scripts/run_review_turn.sh rd-workflow-workspace/handoffs/review_pipeline/20260313_120000_final-diff-review --reopen "기록 커밋에서 gitlink 가 바뀜"
  bash rd-workflow/scripts/run_review_turn.sh rd-workflow-workspace/handoffs/review_pipeline/20260313_120000_final-diff-review --decision "F5 는 값 복구 후 재확인"
  bash rd-workflow/scripts/run_review_turn.sh rd-workflow-workspace/handoffs/review_pipeline/20260313_120000_final-diff-review --decision "F2 는 범위 밖으로 둠" --extend-turns 6
EOF
}

# --- 설정 경로 (단일 변수, 모든 config 조회에 공유) ---
CONFIG_FILE="${REVIEW_TOOLS_CONFIG:-${project_root}/rd-workflow/config/review-tools.json}"
review_type=""   # load_review_config가 설정 — set -u 방어용 전역 초기화

# --- 설정 로드 (통합 파싱 — spec §2 결정 3) ---
# review-tools.json 을 프로세스당 jq 정확히 최대 1회 호출로 파싱한다 (model_select.sh 의 ms_load_legacy).
# 출력 형식: TSV(key<TAB>value) — 값 내 '='·공백이 있어도 경계가 보존된다 (jq @tsv).
# null 필드는 문자열 "null" 로, missing 필드는 행 자체 부재로 구분된다 (현행 has($f) 계약 보존).
# jq 부재 또는 JSON 손상 시 기본값으로 fallback — 별도 유효성 검사 호출 없음.
# 같은 결과(MS_LEGACY_KV)를 선택 함수가 옛 모델·effort 칸으로 읽으므로 옛 설정을 다시 파싱하지 않는다.
REVIEW_CFG_KV=""
# jq 가 없으면 1. 이 실행은 models.json·review-tools.json·RD_REVIEW_* 를 모두 쓰지 않는다 (spec D6).
REVIEW_JQ_MISSING=0

load_review_config_once() {
  PRIORITY="codex claude"
  REVIEW_CFG_KV=""
  MS_LEGACY_KV=""
  MS_MODELS_LOADED=0

  # jq 판정은 설정 파일 존재와 상관없이 턴 시작 때 한 번 한다 (spec D6).
  if ! ms_jq_available; then
    REVIEW_JQ_MISSING=1
    echo "⚠️  jq가 설치되지 않아 기본 설정을 사용합니다." >&2
    echo "    설정 파일을 적용하려면: brew install jq" >&2
    return 0
  fi

  if ! [[ -f "$CONFIG_FILE" ]]; then
    return 0
  fi

  # 파싱 실패 경고는 ms_load_legacy 가 지금 문구 그대로 내고 MS_LEGACY_KV 를 비운다.
  ms_load_legacy "$CONFIG_FILE" "$review_type"
  REVIEW_CFG_KV="$MS_LEGACY_KV"
  [[ -n "$REVIEW_CFG_KV" ]] || return 0
  local p
  p="$(printf '%s\n' "$REVIEW_CFG_KV" | awk -F'\t' '$1=="priority"{print $2; exit}')"
  [[ -n "$p" ]] && PRIORITY="$p"
  return 0
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

# === A: 리뷰어 모델·effort 선택 (call-site-model-effort-selection, spec D4·D5) ===
# 모델은 models.json 또는 RD_REVIEW_<도구>_MODEL 로 고른 경우에만 넘기고, 없으면 도구 자체 설정
# (Codex: ~/.codex/config.toml, Claude: CLI 기본값 또는 옛 tools.claude.model)을 따른다.
# 해석은 도구 루프 안에서 도구마다 ms_resolve_review 로 한다. 아래 전역은 현재 도구의 결과다.
MODEL_VALUE=""       # 빈 값이면 미전달
MODEL_RAW=""         # 찾은 원래 값 (계열 이름·default 등). 못 찾았으면 빈 값
MODEL_SOURCE="cli-default"
MODEL_ORIGIN="cli-default"
EFFORT_VALUE=""      # 빈 값이면 미전달 = 도구 자체 설정을 따름
EFFORT_RAW=""
EFFORT_SOURCE="global"
EFFORT_ORIGIN="cli-default"
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

# resolve_review_selection <tool> <execution-path> <리뷰 종류>
# ms_resolve_review 결과를 실행기 전역(MODEL_*·EFFORT_*)으로 옮기고, 옛 키 안내 줄을 stderr 로 낸다.
# 경고(하향·고정·해석 실패·무효 값)는 ms_resolve_review 가 stderr 로 직접 낸다 — 모두 실행 줄 앞에 온다.
resolve_review_selection() {
  local tool="$1" exec_path="$2" rt="$3"
  ms_resolve_review "$tool" "$exec_path" "$rt"
  MODEL_VALUE="$MS_MODEL_VALUE"; MODEL_RAW="$MS_MODEL_RAW"; MODEL_SOURCE="$MS_MODEL_SOURCE"; MODEL_ORIGIN="$MS_MODEL_ORIGIN"
  EFFORT_VALUE="$MS_EFFORT_VALUE"; EFFORT_RAW="$MS_EFFORT_RAW"; EFFORT_SOURCE="$MS_EFFORT_SOURCE"; EFFORT_ORIGIN="$MS_EFFORT_ORIGIN"
  EFFORT_REJECTED="$MS_EFFORT_REJECTED"
  if [[ -n "$MS_NOTICES" ]]; then
    printf '%s\n' "$MS_NOTICES" >&2
  fi
  return 0
}

# _selection_source <단계> <위치> <원래 값> <넘긴 값> → 실행 줄의 source 칸 (spec D7)
# 「단계 · 위치」. 값을 찾았지만 넘기지 않았으면(default·해석 실패·하한) ` = <원래 값>` 을 붙인다.
_selection_source() {
  local stage="$1" origin="$2" raw="$3" val="$4" out
  if [[ -z "$origin" || "$origin" == "$stage" ]]; then out="$stage"; else out="${stage} · ${origin}"; fi
  if [[ -z "$val" && -n "$raw" ]]; then out="${out} = ${raw}"; fi
  printf '%s' "$out"
}

# format_selection_line <tool> → `리뷰 도구: … / 모델 요청: … / effort 시도: …` (spec D7)
format_selection_line() {
  local tool="$1" mshow eshow tail=""
  if [[ -z "$MODEL_VALUE" ]]; then mshow="none"
  elif [[ -n "$MODEL_RAW" && "$MODEL_RAW" != "$MODEL_VALUE" ]]; then mshow="${MODEL_RAW}→${MODEL_VALUE}"
  else mshow="$MODEL_VALUE"; fi
  [[ "$MODEL_SOURCE" == "unresolved" ]] && tail=" — CLI 기본값으로 실행"
  eshow="${EFFORT_VALUE:-none}"
  printf '리뷰 도구: %s / 모델 요청: %s (source: %s)%s / effort 시도: %s (source: %s)' \
    "$tool" "$mshow" "$(_selection_source "$MODEL_SOURCE" "$MODEL_ORIGIN" "$MODEL_RAW" "$MODEL_VALUE")" "$tail" \
    "$eshow" "$(_selection_source "$EFFORT_SOURCE" "$EFFORT_ORIGIN" "$EFFORT_RAW" "$EFFORT_VALUE")"
}

# _origin_text <위치> → 안내에 쓰는 위치 표기. env:<변수> → 「환경 변수 <변수>」, file:<경로>#<칸> → 「<경로> 의 <칸>」
_origin_text() {
  case "$1" in
    env:*)  printf '환경 변수 %s' "${1#env:}" ;;
    file:*) local r="${1#file:}"; printf '%s 의 %s' "${r%#*}" "${r##*#}" ;;
    *)      printf '%s' "$1" ;;
  esac
}

# _selection_recovery_field <tool> <모델|effort> → 그 칸의 복구 안내 (stderr, spec D10 표)
# 이번 호출에 인자를 넘겼는지로 먼저 나눈다. 넘겼으면 그 값의 출처를 고치는 방법과 「이번만 =default」,
# 넘기지 않았으면 도구 자체 설정 확인과 유효한 값으로 이번만 덮어쓰기를 안내한다(`default` 는 권하지 않는다).
_selection_recovery_field() {
  local tool="$1" label="$2" T F val raw origin p shown
  if [[ "$tool" == "codex" ]]; then T=CODEX; else T=CLAUDE; fi
  if [[ "$label" == "모델" ]]; then
    F=MODEL; val="$MODEL_VALUE"; raw="$MODEL_RAW"; origin="$MODEL_ORIGIN"
  else
    F=EFFORT; val="$EFFORT_VALUE"; raw="$EFFORT_RAW"; origin="$EFFORT_ORIGIN"
  fi
  p="    [${label}] "
  local var="RD_REVIEW_${T}_${F}"
  if [[ -n "$val" ]]; then
    shown="$val"
    [[ -n "$raw" && "$raw" != "$val" ]] && shown="${raw}→${val}"
    echo "${p}이번 호출에 넘긴 값: ${shown} (출처: $(_origin_text "$origin"))" >&2
    case "$origin" in
      env:*)
        echo "${p}${origin#env:} 에 유효한 값을 주거나, ${origin#env:}=default 로 이번 호출만 인자를 빼거나, 그 변수를 지우고 다시 실행하십시오." >&2 ;;
      *)
        echo "${p}$(_origin_text "$origin") 를 고치거나, 이번 호출만 ${var}=<유효 값> 으로 덮어쓰거나 ${var}=default 로 인자를 빼고 다시 실행하십시오." >&2 ;;
    esac
    if [[ "$label" == "effort" && "$tool" == "codex" ]]; then
      echo "${p}이번 호출만 effort 를 넘기지 않으려면 RD_REVIEW_EFFORT_OVERRIDE=0 을 설정하고 다시 실행하십시오." >&2
    fi
    return 0
  fi
  case "$origin" in
    env:*|file:*) echo "${p}$(_origin_text "$origin") 의 값 때문에 넘기지 않았습니다." >&2 ;;
  esac
  if [[ "$tool" == "codex" && "$label" == "모델" ]]; then
    echo "${p}프로젝트는 모델을 넘기지 않았습니다. Codex 는 $(ms_codex_home)/config.toml 의 model 을 씁니다 — 그 값을 확인하십시오." >&2
    echo "${p}이번 호출만 덮어쓰려면 ${var}=<계열> (예: sol) 로 다시 실행하십시오." >&2
  elif [[ "$tool" == "codex" ]]; then
    echo "${p}프로젝트는 effort 를 넘기지 않았습니다. Codex 는 $(ms_codex_home)/config.toml 의 model_reasoning_effort 를 씁니다 — 그 값을 확인하십시오." >&2
    if [[ "$EFFORT_SOURCE" == "kill-switch" ]]; then
      echo "${p}이번 호출만 덮어쓰려면 RD_REVIEW_EFFORT_OVERRIDE 를 해제(unset RD_REVIEW_EFFORT_OVERRIDE)하고 ${var}=<유효 값> (low·medium·high·xhigh·max·ultra) 으로 다시 실행하십시오." >&2
    else
      echo "${p}이번 호출만 덮어쓰려면 ${var}=<유효 값> (low·medium·high·xhigh·max·ultra) 으로 다시 실행하십시오." >&2
    fi
  elif [[ "$label" == "모델" ]]; then
    echo "${p}프로젝트는 모델을 넘기지 않았습니다 (CLI 기본값)." >&2
    echo "${p}이번 호출만 덮어쓰려면 ${var}=<별칭> (opus·sonnet·haiku·fable) 으로 다시 실행하십시오." >&2
  else
    echo "${p}프로젝트는 effort 를 넘기지 않았습니다 (CLI 기본값)." >&2
    echo "${p}이번 호출만 덮어쓰려면 ${var}=<유효 값> (low·medium·high·xhigh·max) 으로 다시 실행하십시오." >&2
  fi
  return 0
}

# print_selection_recovery <tool> <분류 출력> → 모델·effort 거부 시 복구 안내 (stderr, spec D10)
# 분류 출력은 일반 실패 경로에서 한 번 구한 classify_adapter_failure_cause 결과다(다시 분류하지 않는다).
# 키 목록에 model 이 있으면 모델 칸, effort 가 있으면 effort 칸, 원인 불명이면 두 칸 모두 안내한다.
# jq 가 없어 설정·환경 변수를 쓰지 않은 실행은 표 대신 한 줄을 낸다(환경 변수 덮어쓰기를 권하지 않는다).
print_selection_recovery() {
  local tool="$1" cause="$2" kind keys want_model=0 want_effort=0
  kind="${cause%% *}"
  keys=",${cause#* },"
  case "$keys" in *,model,*) want_model=1 ;; esac
  case "$keys" in *,effort,*) want_effort=1 ;; esac
  if [[ "$kind" == "unknown" ]]; then want_model=1; want_effort=1; fi
  [[ "$want_model" -eq 1 || "$want_effort" -eq 1 ]] || return 0
  case "$tool" in
    codex|claude) ;;
    *)
      # 다른 도구는 RD_REVIEW_* 덮어쓰기가 없고 effort 도 넘기지 않는다. 넘긴 모델이 있을 때만 그 출처를 알린다.
      if [[ "$want_model" -eq 1 && -n "$MODEL_VALUE" ]]; then
        echo "    모델 복구 안내 (${tool}): 이번 호출에 넘긴 값 ${MODEL_VALUE} (출처: $(_origin_text "$MODEL_ORIGIN")) — 그 칸을 고치거나 null 로 비우면 CLI 기본값으로 실행합니다." >&2
      fi
      return 0 ;;
  esac
  if [[ "$REVIEW_JQ_MISSING" -eq 1 ]]; then
    echo "    jq 가 없어 models.json·review-tools.json·RD_REVIEW_* 를 적용하지 않았습니다 — jq 를 설치한 뒤 다시 실행하거나(brew install jq), 도구 자체 설정(Codex: $(ms_codex_home)/config.toml, Claude: CLI 기본값)을 고치십시오." >&2
    return 0
  fi
  echo "    모델·effort 복구 안내 (${tool}):" >&2
  [[ "$want_model" -eq 1 ]] && _selection_recovery_field "$tool" 모델
  [[ "$want_effort" -eq 1 ]] && _selection_recovery_field "$tool" effort
  return 0
}

# 턴 완료 후 실제 적용 상태 (spec §4.7 상태 5종).
# 어댑터는 effort 를 받으면 그대로 전달하고, 값이 거부되면 즉시 실패한다(자동 재시도 없음).
# 따라서 "턴이 성공했고 effort 를 전달했다" = "도구가 그 값을 수락했다" 이며,
# 부모가 아는 정보만으로 상태를 결정할 수 있다. 별도 결과 채널이 필요하지 않다.
# Claude 도 effort 를 받으므로 도구와 상관없이 같은 규칙으로 보고한다 (spec D7).
compute_effort_status() {
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

# === 턴 계측 (review-speedup-2-effort-policy-tuning) ===
# 세션 디렉토리 turn_metrics.tsv 에 턴당 소요를 append 한다.
# fail-open 계약: 계측 실패가 리뷰 턴 실행·종료 코드에 영향을 주지 않는다 (부가 기능).
# 시간 원천은 date +%s 만 사용한다 — macOS bash 3.2 / Linux 공통 (GNU 전용 옵션 금지).
compute_target_bytes() {
  # REVIEW_TARGET 은 SESSION 의 Review Target 섹션(줄당 경로 1개)에서 온다.
  # 줄 단위로 처리해야 공백 포함 경로가 깨지지 않는다 (word splitting 금지).
  local total=0 found=0 line sz
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" && -f "$line" ]] || continue
    sz="$(wc -c < "$line" 2>/dev/null | tr -d ' ')" || continue
    total=$(( total + sz ))
    found=1
  done <<< "$REVIEW_TARGET"
  if [[ "$found" -eq 1 ]]; then printf '%s' "$total"; else printf '%s' "-"; fi
}

# 쓰기 성공 여부는 전역 METRIC_WRITE_OK 에 남긴다 (1=기록됨) — 호출부가 실패를
# stderr 경고로 표시하기 위한 것으로, 함수 자체는 항상 return 0 (fail-open 계약 불변).
METRIC_WRITE_OK=0
# 열 수 (spec D9): 새 파일은 12열(관측 model, 리뷰 도구 tokens). 기존 파일은 헤더 끝을 보고
# `\ttokens` 면 12열, `\tmodel` 이면 11열, 그 밖은 10열 행을 쓰고 헤더는 바꾸지 않는다 —
# 진행 중 세션의 옛 파일을 섞인 열로 만들지 않는다.
append_turn_metric() {
  local turn="$1" rt="$2" tool="$3" effort="$4" pbytes="$5" tbytes="$6" s="$7" e="$8" status="$9" model="${10:-}" tokens="${11:--}"
  METRIC_WRITE_OK=0
  {
    local f="${session_dir}/turn_metrics.tsv" hdr="" with_model=0 with_tokens=0
    if [[ ! -f "$f" ]]; then
      printf '# turn\treview_type\ttool\teffort\tprompt_bytes\ttarget_bytes\tstart_epoch\tend_epoch\twall_seconds\tstatus\tmodel\ttokens\n' > "$f"
      with_model=1; with_tokens=1
    else
      IFS= read -r hdr < "$f" || true
      [[ "$hdr" == *$'\t'model ]] && with_model=1
      [[ "$hdr" == *$'\t'model$'\t'tokens ]] && { with_model=1; with_tokens=1; }
    fi
    if [[ "$with_tokens" -eq 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$turn" "$rt" "$tool" "${effort:-none}" "$pbytes" "$tbytes" "$s" "$e" "$(( e - s ))" "$status" "${model:-unknown}" "$tokens" >> "$f" \
        && METRIC_WRITE_OK=1
    elif [[ "$with_model" -eq 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$turn" "$rt" "$tool" "${effort:-none}" "$pbytes" "$tbytes" "$s" "$e" "$(( e - s ))" "$status" "${model:-unknown}" >> "$f" \
        && METRIC_WRITE_OK=1
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$turn" "$rt" "$tool" "${effort:-none}" "$pbytes" "$tbytes" "$s" "$e" "$(( e - s ))" "$status" >> "$f" \
        && METRIC_WRITE_OK=1
    fi
  } 2>/dev/null || true
  return 0
}

# === reviewer 턴 head 재snapshot (change-spec §3.2.1) ===
# 이 파이프라인의 표준 흐름은 reviewer 지적 → author 의 iteration commit → 다음 reviewer 턴입니다.
# 세션 생성 시의 head 에 target 을 묶어두면 정상적인 다회차 리뷰가 봉인 불가능해지므로,
# reviewer 턴을 시작하기 직전에 head 를 다시 snapshot 합니다.
#
# **base 는 갱신하지 않습니다 (불변).** 기본 브랜치가 리뷰 도중 전진하면 base 가 따라 움직여
# 이미 리뷰된 변경분이 조용히 diff 에서 빠집니다. 리뷰 대상은 작업 전체이지 마지막 턴의 증분이 아닙니다.

# session_branch_field <session-file> <key> — `## Branch Context` 의 `- key: value` 값
# Review Target 문자열을 파싱하지 않습니다 — 파싱 계약을 두면 표현이 바뀔 때마다 깨집니다.
session_branch_field() {
  local session_file="$1" key="$2"
  [[ -f "$session_file" ]] || return 0
  awk -v k="- ${key}:" '
    $0 == "## Branch Context" { f = 1; next }
    f && /^## / { exit }
    f && index($0, k) == 1 {
      sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit
    }' "$session_file"
}

# turn_change_state <base> <head> — 두 커밋 사이에 실제 변경이 있는지 판정합니다.
#   0 = 변경 있음 / 1 = 빈 diff / 2 = 판정 오류
# `git diff --quiet` 의 종료 코드는 일반 명령과 의미가 반대입니다 (0 = 차이 없음). 세 값을
# 구분하지 않으면 git 오류를 통과로 오독하므로 2 도 fail-closed 로 막습니다. OID 가 다르다는
# 조건만으로는 부족합니다 — 완전 revert 로 트리가 base 와 같아지면 diff 가 비어 있습니다.
turn_change_state() {
  local rc=0
  git diff --quiet "${1}..${2}" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

# resnapshot_review_head <session-dir> <session-file> <review-type>
#   return 0 — 갱신 완료 또는 대상 아님(no-op) / return 1 — 실패, SESSION 은 그대로
#
# 원자성 계약 (spec §3.2.1 — 순서 자체가 계약입니다):
#   ① OID resolve·계보 검증을 먼저 전부 끝냅니다
#   ② SESSION 전체를 같은 디렉터리의 임시 파일에 렌더링합니다
#   ③ mv 로 원자적으로 교체하고 **그 종료 상태를 확인해 전파합니다**
#   ④ 교체가 성공한 뒤에야 호출부가 어댑터 호출·턴 파일 생성으로 넘어갑니다
# 1~3 중 어디서 실패해도 기존 SESSION 을 그대로 두고 턴을 시작하지 않습니다. `review-head-oid` 와
# `Review Target` 이 한쪽만 바뀐 SESSION 으로 reviewer 가 dispatch 되면 이 절이 막으려던 상태
# ("기록된 OID 와 reviewer 가 읽은 diff 가 다름") 가 그대로 생깁니다.
resnapshot_review_head() {
  local session_dir="$1" session_file="$2" rtype="$3"
  local base_oid old_head new_head policy tmp rc cs render_target

  # diff-review 가 아니면 대상이 아닙니다 (author 턴은 호출부에서 이미 걸러집니다).
  [[ "$rtype" == "diff-review" ]] || return 0

  base_oid="$(session_branch_field "$session_file" "review-base-oid")"
  old_head="$(session_branch_field "$session_file" "review-head-oid")"
  # 둘 다 없으면 §5.2.1 의 파싱 불가 세션이거나 이 계약 이전의 legacy 세션이므로
  # 건드리지 않습니다 (legacy 경로 유지).
  if [[ -z "$base_oid" && -z "$old_head" ]]; then
    return 0
  fi
  # **한쪽만 있는 세션은 legacy 가 아니라 손상입니다**.
  # 종전에는 이것도 조용한 no-op 이었는데, `rd review seal` 은 head 가 있다는 이유만으로
  # 일반 `verified=yes` 경로를 허용하므로 base 없는 세션이 검증된 것처럼 봉인됩니다.
  if [[ -z "$base_oid" || -z "$old_head" ]]; then
    echo "review turn: SESSION 의 reviewed OID 가 한쪽만 있습니다 (base='${base_oid}', head='${old_head}')." >&2
    echo "  두 줄은 한 묶음이라 한쪽만 있는 상태는 손상입니다. 판정 불가이므로 턴을 시작하지 않습니다." >&2
    echo "  세션을 다시 만드십시오: bash rd-workflow/scripts/prepare_review_pipeline.sh diff" >&2
    return 1
  fi

  # head 갱신 정책 (§3.2.1). 사용자가 위치 인자로 현재 HEAD 가 아닌 head 를 명시한 세션은
  # `pinned` 이며, 재snapshot 하면 그 대상이 조용히 현재 HEAD 로 바뀝니다 — 사용자가 지정한
  # 검토 대상과 reviewer 가 실제로 보는 대상이 갈리고, 내부 OID 와 프롬프트는 서로 일치하므로
  # 오검토가 눈에 띄지 않습니다. 필드가 없는 기존 세션은 `auto`(현재 동작)로 봅니다.
  policy="$(session_branch_field "$session_file" "review-head-policy")"
  [[ -n "$policy" ]] || policy="auto"
  if [[ "$policy" != "auto" && "$policy" != "pinned" ]]; then
    echo "review turn: review-head-policy 값이 유효하지 않습니다: '${policy}' (허용: auto|pinned) — 판정 불가로 중단합니다." >&2
    return 1
  fi

  # ① resolve · 계보 검증
  #
  # **정책은 갱신 여부만 가릅니다 — 대상 무결성 검증은 두 정책 모두 받습니다**
  # `pinned` 을 검증 앞에서 조기 반환시키면,
  # 명시 ref 삭제 후 객체 정리·저장소 교체·SESSION 의 부분 수정으로 기록 OID 가 더 이상
  # resolve 되지 않는 세션이 그대로 reviewer dispatch 까지 가고, 사용자는 `git diff
  # <invalid>..<invalid>` 로 돈 결과를 **성공한 리뷰 턴처럼** 받게 됩니다.
  # 검증 대상 head 만 다릅니다 — `auto` 는 현재 `HEAD`, `pinned` 은 세션에 기록된 head.
  if ! declare -f rd_resolve_commit_oid >/dev/null 2>&1; then
    echo "review turn: rd_resolve_commit_oid 를 쓸 수 없습니다 (_state_common.sh 미로드) — 판정 불가로 중단합니다." >&2
    return 1
  fi
  local resolved_base head_input head_label
  resolved_base="$(rd_resolve_commit_oid "$base_oid")" || {
    echo "review turn: 세션의 review-base-oid '${base_oid}' 를 커밋으로 해석할 수 없습니다 — 판정 불가로 중단합니다." >&2
    return 1
  }
  if [[ "$policy" == "pinned" ]]; then
    head_input="$old_head"
    head_label="세션에 고정된 head"
  else
    head_input="HEAD"
    head_label="현재 HEAD"
  fi
  new_head="$(rd_resolve_commit_oid "$head_input")" || {
    echo "review turn: ${head_label} ('${head_input}') 를 커밋으로 해석할 수 없습니다 — 판정 불가로 중단합니다." >&2
    return 1
  }
  if ! git merge-base --is-ancestor "$resolved_base" "$new_head" >/dev/null 2>&1; then
    echo "review turn: ${head_label} (${new_head}) 가 review-base-oid (${resolved_base}) 의 후손이 아닙니다." >&2
    echo "  amend·reset 등으로 계보가 끊긴 상태입니다. 판정 불가이므로 SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  fi
  # 조상 관계만으로는 빈 target 을 막지 못합니다 — iteration 중 변경이 완전히 revert 되면
  # base 와 head 의 OID 는 달라도 트리가 같아 diff 가 비어 있습니다 (AC 4).
  cs=0
  turn_change_state "$resolved_base" "$new_head" || cs=$?
  if [[ "$cs" == "1" ]]; then
    echo "review turn: base (${resolved_base}) 와 ${head_label} (${new_head}) 사이에 변경이 없습니다 (커밋은 다르지만 트리가 같습니다)." >&2
    echo "  빈 diff 를 리뷰 대상으로 기록하지 않기 위해 SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  elif [[ "$cs" != "0" ]]; then
    echo "review turn: base (${resolved_base}) 와 ${head_label} (${new_head}) 의 diff 판정에 실패했습니다 (git 오류)." >&2
    echo "  판정 불가이므로 SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  fi

  # **raw 필드는 저장소 native full OID 여야 합니다**.
  # `rd_resolve_commit_oid` 는 `branch-B` 같은 이동 ref 와 축약 OID 도 해석하므로, 필드에
  # 그런 값이 들어 있으면 reviewer 시점과 seal 시점 사이에 대상이 다시 움직일 수 있습니다.
  # resolve 결과와 원본이 같은지 확인해 그 창을 닫습니다.
  if [[ "$base_oid" != "$resolved_base" ]]; then
    echo "review turn: review-base-oid('${base_oid}') 가 full OID 가 아닙니다 (resolve 결과: ${resolved_base})." >&2
    echo "  이동 ref·축약 OID 는 리뷰 도중 대상이 바뀔 수 있어 받지 않습니다. 세션을 다시 만드십시오:" >&2
    echo "  bash rd-workflow/scripts/prepare_review_pipeline.sh diff" >&2
    return 1
  fi
  if [[ "$policy" == "pinned" && "$old_head" != "$new_head" ]]; then
    echo "review turn: review-head-oid('${old_head}') 가 full OID 가 아닙니다 (resolve 결과: ${new_head})." >&2
    echo "  pinned 세션의 head 는 고정 대상이므로 이동 ref·축약 OID 를 받지 않습니다. 세션을 다시 만드십시오:" >&2
    echo "  bash rd-workflow/scripts/prepare_review_pipeline.sh diff" >&2
    return 1
  fi

  # 검증을 통과한 `pinned` 세션은 여기서 끝냅니다 — SESSION 을 바꾸지 않습니다.
  #
  # **다만 반환 전에 `Review Target` 까지 같은 묶음으로 확인합니다** (같은 Finding).
  # reviewer 에게 실제로 전달되는 것은 OID 두 줄이 아니라 `## Review Target` 섹션이고,
  # `auto` 는 이 섹션을 재렌더링하면서 결속하지만 `pinned` 은 아무것도 다시 쓰지 않습니다.
  # 그래서 OID 는 유효한데 target 만 stale·부분 수정된 세션이 검증을 통과한 채 **OID 가
  # 가리키지 않는 diff** 를 reviewer 에게 보냈습니다. seal 은 `review-head-oid` 만 보므로
  # 그렇게 잘못 리뷰된 결과도 `verified=yes` 로 봉인될 수 있습니다.
  if [[ "$policy" == "pinned" ]]; then
    local cur_target want_target
    cur_target="$(extract_section "$session_file" "Review Target" | trim_blank_lines)"
    rd_review_input_check "$resolved_base" "$new_head" || return 1
    want_target="$(rd_review_diff_target "$resolved_base" "$new_head")"
    if [[ "$cur_target" != "$want_target" ]]; then
      echo "review turn: SESSION 의 Review Target 이 기록된 OID 와 어긋납니다." >&2
      echo "  기록된 OID 기준: ${want_target}" >&2
      echo "  SESSION 의 값  : ${cur_target}" >&2
      echo "  reviewer 가 읽을 diff 와 봉인 대상이 갈리므로 턴을 시작하지 않습니다. 세션을 다시 만드십시오:" >&2
      echo "  bash rd-workflow/scripts/prepare_review_pipeline.sh diff" >&2
      return 1
    fi
  fi

  if [[ "$policy" == "pinned" ]]; then
    echo "review head 정책: pinned — 지정된 head (${new_head}) 를 유지하고 재snapshot 하지 않습니다." >&2
    echo "  이 세션에는 리뷰 도중의 iteration commit 이 반영되지 않습니다." >&2
    return 0
  fi

  # 대상 문자열 계산과 완전성 검사는 임시 파일을 만들기 전에 합니다 — 차단돼도 SESSION 디렉터리에 찌꺼기가 남지 않습니다.
  rd_review_input_check "$resolved_base" "$new_head" || return 1
  render_target="$(rd_review_diff_target "$resolved_base" "$new_head")"

  # ② 같은 디렉터리 임시 파일에 SESSION 전체를 렌더링
  tmp="$(mktemp "${session_dir}/.SESSION.md.XXXXXX")" || {
    echo "review turn: 임시 파일 생성 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  }
  awk -v newhead="$new_head" -v target="$render_target" '
    {
      if (skip) {
        if ($0 ~ /^## /) { skip = 0; print "" } else { next }
      }
      if ($0 == "## Review Target") { print; print target; skip = 1; next }
      if ($0 == "## Branch Context") { inbc = 1; print; next }
      if (inbc && /^## /) { inbc = 0 }
      if (inbc && index($0, "- review-head-oid:") == 1) {
        print "- review-head-oid: " newhead; next
      }
      print
    }' "$session_file" > "$tmp"
  rc=$?
  if [[ "$rc" != "0" || ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "review turn: SESSION 렌더링 실패 (awk exit ${rc}) — 기존 SESSION 을 그대로 두고 중단합니다." >&2
    return 1
  fi

  # ③ 원자적 교체. mv 의 종료 상태를 확인하지 않고 어댑터를 계속 부르면
  #    reviewer 가 stale target 으로 시작합니다 — 이 계약이 막으려는 실수가 그것입니다.
  if ! mv "$tmp" "$session_file"; then
    rm -f "$tmp"
    echo "review turn: SESSION 교체(mv) 실패 — 기존 SESSION 을 그대로 두고 턴을 시작하지 않습니다." >&2
    return 1
  fi

  # ④ 여기부터가 어댑터 호출이 허용되는 지점입니다.
  echo "review head 재snapshot: ${old_head} → ${new_head} (base ${resolved_base} 는 불변)" >&2
  return 0
}

# reopen_session_converged <session-dir> — CHECKPOINT Open Issues 가 seal 과 같은 판정으로 종결(ok)인가.
#   rc 0 = 수렴 / rc 1 = 미수렴·판정 불가 (사유는 REOPEN_UNRESOLVED_REASON)
# awaiting-user 는 「이의 없음 수렴」 과 「사람 질문 대기」 가 같은 상태값이라 Open Issues 로 가릅니다.
# 판정 규칙을 다시 쓰지 않고 hooks/_open_issues.awk 를 그대로 씁니다. 파일이 없으면 열지 않습니다(fail-closed).
REOPEN_UNRESOLVED_REASON=""
reopen_session_converged() {
  local cp="${1}/CHECKPOINT.md" awk_file="${script_dir}/hooks/_open_issues.awk" verdict
  REOPEN_UNRESOLVED_REASON=""
  [[ -f "$awk_file" ]] || { REOPEN_UNRESOLVED_REASON="판정 파일 없음: ${awk_file#${project_root}/}"; return 1; }
  [[ -f "$cp" ]] || { REOPEN_UNRESOLVED_REASON="CHECKPOINT.md 없음"; return 1; }
  verdict="$(awk -f "$awk_file" "$cp" 2>/dev/null)" || verdict=""
  [[ "$verdict" == "ok" ]] && return 0
  REOPEN_UNRESOLVED_REASON="Open Issues: ${verdict:-판정 실패}"
  return 1
}

# session_unresolved_confirmed <session-dir> — Open Issues 에 미해결 리스트 항목이 확인되는가 (--decision·--override).
#   rc 0 = 확인됨 / rc 1 = 수렴·판정 불가 (사유와 복구 안내를 stderr 에 냄)
# 판정 실패(파일 없음·절 없음·빈 절·형식 오류)를 미해결로 보지 않습니다 — 사람 결정 경로가 상태를 바꾸려면 근거가 있어야 합니다.
session_unresolved_confirmed() {
  local cp="${1}/CHECKPOINT.md" awk_file="${script_dir}/hooks/_open_issues.awk" verdict rel item
  rel="${1#${project_root}/}"
  if [[ ! -f "$awk_file" || ! -f "$cp" ]]; then
    echo "리뷰 세션의 미해결 이의를 판정할 수 없습니다 ($([[ -f "$cp" ]] && echo "판정 파일 없음: ${awk_file#${project_root}/}" || echo "${rel}/CHECKPOINT.md 없음")). 파일을 복구한 뒤 다시 실행하십시오." >&2
    return 1
  fi
  verdict="$(awk -f "$awk_file" "$cp" 2>/dev/null)" || verdict=""
  case "$verdict" in
    open-issues-unresolved:*)
      # 판정기는 마커가 아닌 첫 리스트 항목을 돌려줍니다. 기호만 있고 내용이 없는 항목(`- `)은 이의로 보지 않습니다.
      item="$(printf '%s' "${verdict#open-issues-unresolved:}" | sed -E 's/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]*//; s/[[:space:]]+$//')"
      [[ -n "$item" ]] && return 0
      echo "리뷰 세션의 미해결 이의를 판정할 수 없습니다 (Open Issues: 내용 없는 리스트 항목)." >&2
      echo "  ${rel}/CHECKPOINT.md 의 ## Open Issues 에 미해결 이의를 리스트 항목(- F1 (턴 NNN) — …)으로 적거나, 없으면 '- 없음' 한 줄로 고친 뒤 다시 실행하십시오." >&2
      return 1 ;;
    ok)
      if override_checkpoint_done "$1"; then pending_override_notice "$1"; return 1; fi
      echo "리뷰 세션에 미해결 이의가 없습니다 (Open Issues: ok). 수렴한 세션의 재확인은 --reopen \"<사유>\" 를 쓰고, 종결은 user-override 없이 rd review seal 로 합니다." >&2
      return 1 ;;
    *)
      echo "리뷰 세션의 미해결 이의를 판정할 수 없습니다 (Open Issues: ${verdict:-판정 실패})." >&2
      echo "  ${rel}/CHECKPOINT.md 의 ## Open Issues 에 미해결 이의를 리스트 항목(- F1 (턴 NNN) — …)으로 적거나, 없으면 '- 없음' 한 줄로 고친 뒤 다시 실행하십시오." >&2
      return 1 ;;
  esac
}

# classify_session_for_reviewer <session-dir> — Reviewer 턴 시작 전 세션 상태를 판정합니다.
#   rc 0  = 이미 awaiting-reviewer·Reviewer (기존 경로 그대로 진행)
#   rc 10 = awaiting-author 이고 형식을 갖춘 최신 Author 턴이 있음 → 전환 예약 (HANDOFF_TURN_FILE 에 그 경로)
#   rc 1  = 거부 (다음 행동 안내를 stderr 에 냄)
# 이 함수는 SESSION 을 쓰지 않습니다 (전환은 apply_author_handoff, 모든 검사 통과 뒤).
# 전역 STATUS·CURRENT_OWNER·TURNS_DIR 를 읽습니다. 서브셸로 부르면 HANDOFF_TURN_FILE 이 사라집니다.
classify_session_for_reviewer() {
  local session_dir="$1" rel latest base num role next
  HANDOFF_TURN_FILE=""
  rel="${session_dir#${project_root}/}"

  if [[ -n "$REOPEN_REASON" && "$STATUS" != "awaiting-user" ]]; then
    echo "--reopen 은 awaiting-user 로 수렴한 세션에만 씁니다 (status=${STATUS}). --reopen 없이 다시 실행하십시오." >&2
    return 1
  fi
  if [[ -n "$DECISION_TEXT" && "$STATUS" != "awaiting-user" ]]; then
    echo "--decision 은 사람 결정을 기다리는 awaiting-user 세션에만 씁니다 (status=${STATUS}). --decision 없이 다시 실행하십시오." >&2
    return 1
  fi

  if [[ "$STATUS" == "awaiting-reviewer" && "$CURRENT_OWNER" == "Reviewer" ]]; then
    return 0
  fi

  case "$STATUS" in
    awaiting-user)
      if [[ -n "$DECISION_TEXT" ]]; then
        session_unresolved_confirmed "$session_dir" || return 1
      elif [[ -z "$REOPEN_REASON" ]]; then
        echo "리뷰 세션이 사람 결정을 기다립니다 (status=awaiting-user). ${rel}/USER_ACTION.md 의 질문에 사람이 답한 뒤 진행하십시오. 자동으로 넘기지 않습니다." >&2
        echo "  사람의 결정대로 이어 가려면 결정을 반영한 Author 턴을 쓴 뒤 --decision \"<사용자 결정>\" 을 붙여 다시 실행하십시오. 턴 한도에 도달한 세션이면 --extend-turns <N> 도 함께 붙입니다." >&2
        echo "  사람이 남은 이의를 덮고 종결하기로 정했으면 --override \"<결정한 사람> — <그 사람이 한 말>\" 로 종결하십시오." >&2
        echo "  이의 없음으로 수렴한 세션에 재확인 턴을 이으려면 바뀐 내용을 Author 턴으로 쓴 뒤 --reopen \"<사유>\" 를 붙여 다시 실행하십시오." >&2
        return 1
      elif override_checkpoint_done "$session_dir"; then
        pending_override_notice "$session_dir"
        return 1
      elif ! reopen_session_converged "$session_dir"; then
        echo "리뷰 세션을 다시 열 수 없습니다 — 수렴한 세션이 아닙니다 (${REOPEN_UNRESOLVED_REASON}). 미해결 이의가 남은 세션은 사람이 결정한 뒤 --decision \"<사용자 결정>\" 으로 이어 가십시오." >&2
        return 1
      fi
      ;;
    closed)
      echo "리뷰 세션이 종결됐습니다 (status=closed). 다시 리뷰하려면 bash rd-workflow/scripts/prepare_review_pipeline.sh 로 새 세션을 만드십시오." >&2
      return 1
      ;;
    awaiting-author)
      if [[ "$CURRENT_OWNER" != "Author" && "$CURRENT_OWNER" != "Claude" ]]; then
        echo "리뷰 세션 상태가 맞지 않습니다 (status=${STATUS}, owner=${CURRENT_OWNER}). SESSION.md 의 Status·Current Owner 를 확인하십시오." >&2
        return 1
      fi
      ;;
    *)
      echo "리뷰 세션 상태가 맞지 않습니다 (status=${STATUS}, owner=${CURRENT_OWNER}). SESSION.md 의 Status·Current Owner 를 확인하십시오." >&2
      return 1
      ;;
  esac

  # awaiting-author + Author·Claude: 최신 턴(compute_next_turn 과 같은 정렬 기준)이 형식을 갖춘 Author 턴이어야 합니다.
  latest="$(find "$TURNS_DIR" -maxdepth 1 -name '*.md' | sort | tail -n 1)"
  if [[ -n "$latest" ]]; then
    base="$(basename "$latest")"
    if [[ "$base" =~ ^[0-9]{3}_(author|claude)\.md$ ]]; then
      if [[ -f "$latest" && ! -L "$latest" ]] && grep -q '[^[:space:]]' "$latest"; then
        HANDOFF_TURN_FILE="$latest"
        return 10
      fi
      echo "리뷰 세션이 Author 턴을 기다립니다 (status=awaiting-author). ${rel}/turns/${base} 가 비었거나 일반 파일이 아닙니다. 내용을 채운 일반 파일로 고친 뒤 같은 명령을 다시 실행하십시오." >&2
      return 1
    fi
    num="${base%%_*}"
    if [[ "$num" =~ ^[0-9]{3}$ ]]; then
      next="$(printf '%03d' "$((10#${num} + 1))")"
    else
      next="001"
    fi
  else
    next="001"
  fi
  echo "리뷰 세션이 Author 턴을 기다립니다 (status=awaiting-author). Author 턴을 ${rel}/turns/${next}_author.md 에 쓴 뒤 같은 명령을 다시 실행하십시오." >&2
  return 1
}

# --- 상태 전환 잠금 (같은 세션에 겹친 실행이 서로의 전환을 덮지 않게 합니다) ---
# with_state_guard <session-file> <함수> [인자…] — 세션 디렉터리에 잠금 디렉터리를 만들고(mkdir 원자성),
# 실행 시작 때 읽은 Status(전역 STATUS)가 지금도 같은지 확인한 뒤 함수를 부릅니다. 끝나면 잠금을 풉니다.
#   rc = 함수의 rc / rc 1 = 잠금 실패 또는 다른 실행이 먼저 상태를 바꿈 (SESSION 은 그대로)
# 잠금은 상태를 읽어 쓰는 짧은 구간만 감쌉니다. Reviewer 실행은 감싸지 않습니다 — 전환 뒤 겹친 실행은 바뀐 Status 로 거부됩니다.
with_state_guard() {
  local session_file="$1" fn="$2" lock cur i rc=0
  shift 2
  lock="$(dirname "$session_file")/.state.lock"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    mkdir "$lock" 2>/dev/null && break
    if [[ "$i" == "10" ]]; then
      echo "review turn: 다른 실행이 이 세션의 상태를 바꾸는 중입니다 (${lock#${project_root}/}). 그 실행이 끝난 뒤 다시 실행하십시오." >&2
      echo "  돌고 있는 실행이 없는데도 이 안내가 반복되면 중단된 실행이 남긴 잠금입니다. 그 디렉터리를 지운 뒤 다시 실행하십시오." >&2
      return 1
    fi
    sleep 0.2
  done
  cur="$(extract_section "$session_file" "Status" | trim_blank_lines)"
  if [[ "$cur" != "$STATUS" ]]; then
    rmdir "$lock" 2>/dev/null || true
    echo "review turn: 다른 실행이 먼저 세션 상태를 바꿨습니다 (시작 때 ${STATUS}, 지금 ${cur}). SESSION 을 바꾸지 않았습니다. 지금 상태에 맞게 다시 실행하십시오." >&2
    return 1
  fi
  "$fn" "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# apply_author_handoff <session-file> <turn-file> — SESSION 의 Status·Current Owner 만 바꿉니다.
#   rc 0 = 교체 성공 + 알림 한 줄 / rc 1 = SESSION 원본 그대로 + 사유 한 줄
# 같은 디렉터리 임시 파일에 전체를 렌더링하고, 두 값을 다시 읽어 확인한 뒤 mv 로 교체합니다.
apply_author_handoff() {
  local session_file="$1" turn_file="$2" reopen_line="${3:-}" new_limit="${4:-}" tmp rc st ow lim
  tmp="$(mktemp "$(dirname "$session_file")/.SESSION.md.XXXXXX")" || {
    echo "review turn: 임시 파일 생성 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  }
  # 마지막 줄의 개행 유무도 원본 그대로 둡니다 (두 값 밖의 바이트를 바꾸지 않는 계약).
  # awk 의 print 는 마지막 줄에도 개행을 붙이므로, 줄 사이에만 개행을 넣고 끝 개행은 원본을 따릅니다.
  local trail_nl=1
  [[ -s "$session_file" && -n "$(tail -c 1 "$session_file")" ]] && trail_nl=0
  # reopen_line 이 있으면 `## Reopen History` 절 끝에 한 줄을 더합니다(절이 없으면 파일 끝에 만듭니다).
  # new_limit 이 있으면 `## Turn Limit` 절의 첫 비공백 줄을 정본 형식으로 바꿉니다(--extend-turns).
  # 사유는 ENVIRON 으로 넘깁니다 — awk -v 는 `\n`·`\\` 같은 이스케이프를 해석해 사유 원문을 바꿉니다.
  RD_REOPEN_LINE="$reopen_line" awk -v trail_nl="$trail_nl" -v new_limit="$new_limit" '
    BEGIN { rl = ENVIRON["RD_REOPEN_LINE"] }
    function emit(line) { if (started) printf "\n"; printf "%s", line; started = 1 }
    function flush_reopen() { if (rl != "" && sec == "## Reopen History" && !added) { emit(rl); added = 1 } }
    function limit_line() { return new_limit " total turns in `turns/*.md`" }
    function flush_limit() { if (new_limit != "" && sec == "## Turn Limit" && !seen) { emit(limit_line()); emit(""); seen = 1 } }
    /^## / { flush_reopen(); flush_limit(); if ($0 == "## Turn Limit") had_limit = 1; sec = $0; seen = 0; emit($0); next }
    sec == "## Status" && !seen && NF { emit("awaiting-reviewer"); seen = 1; next }
    sec == "## Current Owner" && !seen && NF { emit("Reviewer"); seen = 1; next }
    sec == "## Turn Limit" && new_limit != "" && !seen && NF { emit(limit_line()); seen = 1; next }
    { emit($0) }
    END {
      flush_reopen()
      if (new_limit != "" && sec == "## Turn Limit" && !seen) { emit(limit_line()); seen = 1 }
      if (new_limit != "" && !had_limit) { emit(""); emit("## Turn Limit"); emit(limit_line()) }
      if (rl != "" && !added) { emit(""); emit("## Reopen History"); emit(rl) }
      if (started && trail_nl) printf "\n"
    }' "$session_file" > "$tmp"
  rc=$?
  if [[ "$rc" != "0" || ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "review turn: SESSION 렌더링 실패 (awk exit ${rc}) — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  fi
  st="$(extract_section "$tmp" "Status" | trim_blank_lines)"
  ow="$(extract_section "$tmp" "Current Owner" | trim_blank_lines)"
  if [[ -n "$reopen_line" ]]; then
    local rl_one
    while IFS= read -r rl_one; do
      if ! grep -qxF -- "$rl_one" "$tmp"; then
        rm -f "$tmp"
        echo "review turn: 재개 사유 기록 검증 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2
        return 1
      fi
    done <<<"$reopen_line"
  fi
  if [[ -n "$new_limit" ]]; then
    lim="$(parse_turn_limit_line "$(extract_section "$tmp" "Turn Limit" | trim_blank_lines | awk 'NR==1')")" || lim=""
    if [[ "$lim" != "$new_limit" ]]; then
      rm -f "$tmp"
      echo "review turn: 턴 한도 갱신 검증 실패 (기대 ${new_limit}, 결과 '${lim}') — SESSION 을 바꾸지 않고 중단합니다." >&2
      return 1
    fi
  fi
  if [[ "$st" != "awaiting-reviewer" || "$ow" != "Reviewer" ]]; then
    rm -f "$tmp"
    echo "review turn: 전환 결과 검증 실패 (status='${st}', owner='${ow}') — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  fi
  if ! mv "$tmp" "$session_file"; then
    rm -f "$tmp"
    echo "review turn: SESSION 교체(mv) 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  fi
  # 완료 안내는 바로 내지 않고 HANDOFF_NOTICES 에 모읍니다. 호출부가 SESSION 교체에 성공한 뒤 출력합니다.
  HANDOFF_NOTICES=()
  if [[ -n "$DECISION_TEXT" ]]; then
    HANDOFF_NOTICES+=("리뷰 세션 재개: 사람의 결정으로 이어 갑니다. 결정을 SESSION 의 Reopen History 에 남겼습니다.")
  elif [[ -n "$REOPEN_REASON" ]]; then
    HANDOFF_NOTICES+=("리뷰 세션 재개: 수렴한 세션을 다시 열었습니다. 사유를 SESSION 의 Reopen History 에 남겼습니다.")
  fi
  if [[ -n "$new_limit" ]]; then
    HANDOFF_NOTICES+=("리뷰 세션 턴 한도: ${new_limit} 턴으로 늘렸습니다.")
  fi
  HANDOFF_NOTICES+=("리뷰 세션 상태: Author 턴($(basename "$turn_file"))을 확인해 Status 를 awaiting-reviewer, Current Owner 를 Reviewer 로 넘겼습니다.")
  return 0
}

# append_user_decision <user-action-file> <line> — `## User Decision` 절 끝에 한 줄을 더합니다(절이 없으면 파일 끝에 만듭니다).
#   rc 0 = 교체 성공 / rc 1 = 원본 그대로
# 사람이 읽는 기록입니다. Reviewer 가 다음 awaiting-user 때 이 파일을 다시 쓸 수 있으므로 SESSION 의 Reopen History 가 정본입니다.
append_user_decision() {
  local ua="$1" line="$2" tmp rc
  tmp="$(mktemp "$(dirname "$ua")/.USER_ACTION.md.XXXXXX")" || return 1
  RD_DECISION_LINE="$line" awk '
    BEGIN { dl = ENVIRON["RD_DECISION_LINE"] }
    function flush() { if (sec == "## User Decision" && !added) { while (nblank > 0) { print ""; nblank-- } print dl; added = 1 } }
    /^## / { flush(); while (nblank > 0) { print ""; nblank-- } sec = $0; print; next }
    /^[[:space:]]*$/ { nblank++; next }
    { while (nblank > 0) { print ""; nblank-- } print }
    END {
      flush()
      if (!added) { if (NR > 0) print ""; print "## User Decision"; print dl }
      else while (nblank > 0) { print ""; nblank-- }
    }' "$ua" > "$tmp"
  rc=$?
  if [[ "$rc" != "0" ]] || ! grep -qxF -- "$line" "$tmp" || ! mv "$tmp" "$ua"; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# sync_user_decisions — SESSION `## Reopen History` 의 「사용자 결정으로 재개」 줄마다 USER_ACTION.md 의
# `## User Decision` 에 같은 결정 표시가 있는지 보고, 없으면 더합니다(정본은 SESSION, USER_ACTION 은 사람용 표시).
#   rc 0 = 맞춤 / rc 1 = 기록 실패(경고를 냄)
sync_user_decisions() {
  local line ts turn text re='^- ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}) ([^ ]+) 뒤 사용자 결정으로 재개: (.*)$'
  [[ -f "$USER_ACTION_FILE" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    ts="${BASH_REMATCH[1]}"; turn="${BASH_REMATCH[2]}"; text="${BASH_REMATCH[3]}"
    grep -qF -- "결정: ${text} (적용: ${turn} 뒤" "$USER_ACTION_FILE" && continue
    if ! append_user_decision "$USER_ACTION_FILE" "- ${ts} 결정: ${text} (적용: ${turn} 뒤 Reviewer 재확인)"; then
      echo "경고: ${USER_ACTION_FILE#${project_root}/} 에 결정을 기록하지 못했습니다. 결정은 SESSION 의 Reopen History 에 있고, 다음 실행이 다시 기록합니다." >&2
      return 1
    fi
  done < <(extract_section "$SESSION_FILE" "Reopen History")
  return 0
}

# OVERRIDE_NOTE_MARK — --override 가 CHECKPOINT 에 남기는 종결 문단의 고정 문구. 이어 하기 판정에 씁니다.
OVERRIDE_NOTE_MARK="SESSION.md Closure Reason user-override): 남은 아래 이의는 사람이 덮고 종결했습니다."

# override_checkpoint_done <session-dir> — 이전 --override 실행이 CHECKPOINT 정리까지 하고 SESSION 교체 전에
# 멈춘 세션인가(Open Issues 판정 ok + 종결 문단 있음). rc 0 = 이어 하기 대상.
override_checkpoint_done() {
  local cp="${1}/CHECKPOINT.md"
  [[ -f "$cp" ]] || return 1
  grep -qF -- "$OVERRIDE_NOTE_MARK" "$cp" || return 1
  [[ "$(awk -f "${script_dir}/hooks/_open_issues.awk" "$cp" 2>/dev/null)" == "ok" ]]
}

# pending_override_notice <session-dir> — 끝나지 않은 --override(CHECKPOINT 만 정리됨)를 알리고 두 길을 안내합니다.
pending_override_notice() {
  local sd="$1" bak
  bak="$(ls -1 "$sd"/.CHECKPOINT.bak.* 2>/dev/null | head -1)"
  echo "리뷰 세션에 끝나지 않은 --override 종결이 있습니다 — CHECKPOINT 는 「사용자 종결」 문단으로 정리됐지만 SESSION 은 아직 ${STATUS} 입니다." >&2
  echo "  종결을 마치려면 CHECKPOINT 의 「근거:」 줄과 같은 근거로 --override 를 다시 실행하십시오." >&2
  if [[ -n "$bak" ]]; then
    echo "  종결하지 않기로 했으면 정리 전 CHECKPOINT(${bak#${project_root}/})를 CHECKPOINT.md 로 되돌린 뒤 다시 실행하십시오." >&2
  else
    echo "  종결하지 않기로 했으면 「원문:」 줄의 이의를 CHECKPOINT 의 ## Open Issues 리스트로 되돌린 뒤 다시 실행하십시오." >&2
  fi
}

# override_seal_precheck <session-dir> — 종결해도 rd review seal 이 거부할 세션을 종결 전에 거릅니다.
#   새 검증으로 고칠 수 없는 두 조건만 봅니다: 실제로 실행된 리뷰어 턴 기록, 마지막 리뷰 뒤 보호 경로 변경.
#   reviewed OID 가 있는 diff-review 세션만 대상입니다(seal 이 이 두 검사를 하는 세션과 같습니다).
#   보호 경로 비교는 seal 과 같습니다: fr 세션은 fr 이 바꾼 경로의 한정 해시(rd_fr_changes_hash)로 비교하고,
#   계산할 수 없으면 전체 보호 트리로 비교합니다. fr 여부는 seal 과 같이 task-state 의 fr-branch(rd_branch_mode)로 정합니다.
#   rc 0 = 진행 / rc 1 = 사유와 다음 행동 안내
override_seal_precheck() {
  local sd="$1" rtype head runs nvalid=0 turn blob tf cur rh="" ch="" fr_val policy guard="${script_dir}/hooks/_guard_common.sh"
  local next="  결정을 반영한 Author 턴을 쓰고 --decision \"<사용자 결정>\" 으로 리뷰어 턴을 받으십시오. 그 뒤에도 사람이 덮기로 하면 --override 를 다시 실행합니다."
  rtype="$(extract_section "$SESSION_FILE" "Review Type" | trim_blank_lines | awk 'NR==1')"
  [[ "$rtype" == "diff-review" ]] || return 0
  head="$(session_branch_field "$SESSION_FILE" "review-head-oid")"
  [[ -n "$head" ]] || return 0
  runs="${sd}/reviewer_runs.tsv"
  if [[ -f "$runs" ]]; then
    while IFS=$'\t' read -r turn blob; do
      tf="${sd}/turns/${turn}_reviewer.md"
      [[ -f "$tf" ]] || continue
      cur="$(git -C "$project_root" hash-object "$tf" 2>/dev/null)" || continue
      [[ -n "$cur" && "$cur" == "$blob" ]] && nvalid=$((nvalid + 1))
    done < <(awk -F'\t' '/^#/ || NF == 0 { next } { last[$1] = $0 }
      END { for (k in last) { n = split(last[k], c, "\t"); if (n == 7 && k ~ /^[0-9][0-9][0-9]$/) print k "\t" c[5] } }' "$runs" 2>/dev/null)
  fi
  if [[ "$nvalid" -eq 0 ]]; then
    echo "--override 를 받을 수 없습니다 — 실제로 실행된 리뷰어 턴 기록이 없어 종결해도 rd review seal 이 거부합니다 (${runs#${project_root}/})." >&2
    echo "$next" >&2
    return 1
  fi
  if ! declare -f rd_protected_tree_hash >/dev/null 2>&1; then
    echo "--override 를 받을 수 없습니다 — 보호 경로 대조 함수(_state_common.sh)를 불러올 수 없어 판정할 수 없습니다." >&2
    return 1
  fi
  local mode
  if ! declare -f state_read_field >/dev/null 2>&1 || ! declare -f rd_branch_mode >/dev/null 2>&1; then
    echo "--override 를 받을 수 없습니다 — task-state 판정 함수(_state_common.sh)를 불러올 수 없어 판정할 수 없습니다." >&2
    return 1
  fi
  fr_val="$(state_read_field "fr-branch")"
  if ! mode="$(rd_branch_mode "$fr_val" 2>/dev/null)"; then
    echo "--override 를 받을 수 없습니다 — task-state 의 fr-branch 값('${fr_val}')으로 branch mode 를 정할 수 없어 rd review seal 도 거부합니다." >&2
    return 1
  fi
  if [[ "$mode" == "fr" && -f "$guard" ]]; then
    # rd_fr_changes_hash 는 hooks/_guard_common.sh 에 있습니다. 전역을 덮지 않도록 서브셸에서 불러 계산합니다.
    if ! rh="$( source "$guard" >/dev/null 2>&1 && rd_fr_changes_hash "$head" 2>/dev/null )" \
       || ! ch="$( source "$guard" >/dev/null 2>&1 && rd_fr_changes_hash HEAD 2>/dev/null )" \
       || [[ -z "$rh" || -z "$ch" ]]; then
      rh=""; ch=""
    fi
  fi
  if [[ -z "$rh" ]]; then
    if ! rh="$(rd_protected_tree_hash "$head" 2>/dev/null)" || ! ch="$(rd_protected_tree_hash HEAD 2>/dev/null)"; then
      echo "--override 를 받을 수 없습니다 — 보호 경로 해시를 계산할 수 없어 판정할 수 없습니다 (review-head-oid ${head})." >&2
      return 1
    fi
  fi
  if [[ "$rh" != "$ch" ]]; then
    echo "--override 를 받을 수 없습니다 — 마지막 리뷰(review-head-oid ${head}) 뒤 보호 경로가 바뀌어, 종결해도 rd review seal 이 재리뷰를 요구합니다." >&2
    policy="$(session_branch_field "$SESSION_FILE" "review-head-policy")"
    if [[ "$policy" == "pinned" ]]; then
      echo "  이 세션은 리뷰 head 가 고정(pinned)돼 --decision 으로도 같은 head 를 다시 봅니다. bash rd-workflow/scripts/prepare_review_pipeline.sh diff 로 새 세션을 만들어 바뀐 내용을 리뷰하십시오." >&2
    else
      echo "$next" >&2
    fi
    return 1
  fi
  return 0
}

# apply_user_override <session-dir> — 사람이 남은 이의를 덮고 종결합니다 (--override).
#   rc 0 = 종결 / rc 1 = SESSION 원본 그대로 + 사유
# SESSION 은 Status 를 closed, Closure Reason 값을 user-override, 그 아래에 근거 줄을 씁니다.
# Closure Reason 절의 주석 줄은 그대로 두고, 절이 없으면 파일 끝에 만듭니다. Reviewer 턴은 돌리지 않습니다.
# CHECKPOINT 의 Open Issues 는 seal 이 `- 없음` 만 종결로 받으므로, 첫 줄을 `- 없음` 으로 바꾸고 남은 이의 원문을
# 「사용자 종결(…)」 문단에 옮깁니다(빈 줄 뒤 문단은 판정기가 보지 않습니다). 이 형식은 손으로 종결하던 세션과 같습니다.
apply_user_override() {
  local session_dir="$1" rel tmp rc st cr basis_line trail_nl=1 cp_file cp_tmp cp_bak note resume=0
  rel="${session_dir#${project_root}/}"
  if [[ "$STATUS" != "awaiting-user" ]]; then
    echo "--override 는 사람 결정을 기다리는 awaiting-user 세션에만 씁니다 (status=${STATUS})." >&2
    return 1
  fi
  # 이전 --override 가 CHECKPOINT 를 정리한 뒤 SESSION 교체 전에 멈췄으면 SESSION 기록만 이어 씁니다.
  if override_checkpoint_done "$session_dir"; then
    resume=1
  else
    session_unresolved_confirmed "$session_dir" || return 1
  fi
  override_seal_precheck "$session_dir" || return 1
  basis_line="근거: $(date '+%Y-%m-%d') ${OVERRIDE_TEXT}"
  if [[ "$resume" == "1" ]]; then
    # 이어 하기는 CHECKPOINT 종결 문단에 남은 근거(날짜 포함)를 그대로 씁니다. 다른 근거면 기록이 갈리므로 거부합니다.
    # 근거는 종결 문단의 표시 줄 바로 다음 줄에 한 줄로 있습니다(이의 원문과 섞이지 않습니다).
    local stored re_basis='^(근거: [0-9]{4}-[0-9]{2}-[0-9]{2} (.*))$'
    stored="$(awk -v m="$OVERRIDE_NOTE_MARK" 'f { print; exit } index($0, m) { f = 1 }' "${session_dir}/CHECKPOINT.md")"
    if ! [[ "$stored" =~ $re_basis ]]; then
      echo "--override 를 이어 할 수 없습니다 — CHECKPOINT 의 「사용자 종결」 문단에서 이전 근거를 읽을 수 없습니다." >&2
      return 1
    fi
    if [[ "${BASH_REMATCH[2]}" != "$OVERRIDE_TEXT" ]]; then
      echo "--override 를 이어 할 수 없습니다 — 이전 --override 실행이 CHECKPOINT 에 남긴 근거와 다릅니다." >&2
      echo "  남은 근거: ${BASH_REMATCH[1]}" >&2
      echo "  같은 근거로 다시 실행하면 종결을 이어 합니다: --override \"${BASH_REMATCH[2]}\"" >&2
      return 1
    fi
    basis_line="${BASH_REMATCH[1]}"
  fi
  [[ -s "$SESSION_FILE" && -n "$(tail -c 1 "$SESSION_FILE")" ]] && trail_nl=0
  tmp="$(mktemp "${session_dir}/.SESSION.md.XXXXXX")" || {
    echo "review turn: 임시 파일 생성 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  }
  # 값 줄: Closure Reason 절에서 주석(<!-- … -->)·빈 줄이 아닌 첫 줄. 그 뒤 같은 절의 기존 `근거:` 줄은 지웁니다.
  RD_BASIS_LINE="$basis_line" awk -v trail_nl="$trail_nl" '
    BEGIN { bl = ENVIRON["RD_BASIS_LINE"] }
    function emit(line) { if (started) printf "\n"; printf "%s", line; started = 1 }
    function flush_cr() { if (sec == "## Closure Reason" && !done) { emit("user-override"); emit(bl); done = 1 } }
    /^## / { flush_cr(); sec = $0; seen = 0; incomment = 0; if ($0 == "## Closure Reason") had = 1; emit($0); next }
    sec == "## Status" && !seen && NF { emit("closed"); seen = 1; next }
    sec == "## Closure Reason" {
      if (incomment || $0 ~ /^[[:space:]]*<!--/) { incomment = ($0 !~ /-->/); emit($0); next }
      if ($0 ~ /^[[:space:]]*(- )?근거:/) next
      if (!done && NF) { emit("user-override"); emit(bl); done = 1; next }
    }
    { emit($0) }
    END {
      flush_cr()
      if (!had) { emit(""); emit("## Closure Reason"); emit("user-override"); emit(bl) }
      if (started && trail_nl) printf "\n"
    }' "$SESSION_FILE" > "$tmp"
  rc=$?
  st="$(extract_section "$tmp" "Status" | trim_blank_lines)"
  cr="$(extract_section "$tmp" "Closure Reason" | grep -v '^[[:space:]]*<!--' | trim_blank_lines | awk 'NR==1')"
  if [[ "$rc" != "0" || "$st" != "closed" || "$cr" != "user-override" ]] || ! grep -qxF -- "$basis_line" "$tmp"; then
    rm -f "$tmp"
    echo "review turn: user-override 기록 검증 실패 (status='${st}', closure='${cr}') — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  fi
  # 사람용 결정 표시를 먼저 씁니다. 실패하면 SESSION·CHECKPOINT 를 바꾸지 않으므로 같은 명령을 다시 실행해 이어 갈 수 있습니다.
  # 같은 근거의 표시가 이미 있으면(이어 하기·재실행) 다시 더하지 않습니다.
  # 표시는 사람이 내린 결정이고 적용 완료를 뜻하지 않습니다. 적용 여부는 SESSION 의 Status·Closure Reason 이 정본입니다.
  # 비교 값은 환경 변수로 넘겨 awk -v 의 백슬래시 해석을 피합니다.
  local ua_body="결정: 남은 이의를 덮고 종결하기로 정함(user-override). ${basis_line} — 적용 여부는 SESSION.md 의 Status·Closure Reason 에서 확인"
  if ! RD_UA_WANT="$ua_body" awk '
      BEGIN { want = ENVIRON["RD_UA_WANT"] }
      $0 == "## User Decision" { f = 1; next } f && /^## / { exit }
      f { n = length($0) - length(want); if (n >= 0 && substr($0, n + 1) == want && (n == 0 || substr($0, n, 1) == " ")) { found = 1; exit } }
      END { exit !found }' "$USER_ACTION_FILE" 2>/dev/null; then
    if ! append_user_decision "$USER_ACTION_FILE" "- $(date '+%Y-%m-%d %H:%M') ${ua_body}"; then
      rm -f "$tmp"
      echo "review turn: ${rel}/USER_ACTION.md 에 결정을 기록하지 못했습니다 — SESSION·CHECKPOINT 를 바꾸지 않고 중단합니다. 원인을 고친 뒤 같은 --override 를 다시 실행하십시오." >&2
      return 1
    fi
  fi
  if [[ "$resume" == "1" ]]; then
    if ! mv "$tmp" "$SESSION_FILE"; then
      rm -f "$tmp"
      echo "review turn: SESSION 교체(mv) 실패 — 바꾸지 않고 중단합니다. 원인을 고친 뒤 같은 --override 를 다시 실행하십시오." >&2
      return 1
    fi
    echo "리뷰 세션 종결 이어 하기: CHECKPOINT 는 이전 --override 실행이 이미 정리했습니다. SESSION 의 종결 기록을 썼습니다." >&2
  else
    cp_file="${session_dir}/CHECKPOINT.md"
    note="사용자 종결($(date '+%Y-%m-%d'), ${OVERRIDE_NOTE_MARK}"
    cp_tmp="$(mktemp "${session_dir}/.CHECKPOINT.md.XXXXXX")" || { rm -f "$tmp"; echo "review turn: 임시 파일 생성 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2; return 1; }
    RD_OVERRIDE_NOTE="$note" RD_BASIS_LINE="$basis_line" awk '
      BEGIN { note = ENVIRON["RD_OVERRIDE_NOTE"]; basis = ENVIRON["RD_BASIS_LINE"] }
      function flush() {
        if (sec && !done) { print "- 없음"; print ""; print note; print basis; print "원문: " orig; print ""; done = 1 }
      }
      /^## / { if (sec) flush(); sec = ($0 == "## Open Issues"); print; next }
      sec && /^[ \t]*<!--/ { next }
      sec && NF { l = $0; sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", l); sub(/[ \t]+$/, "", l); orig = orig (orig == "" ? "" : " / ") l; next }
      sec { next }
      { print }
      END { if (sec) flush() }' "$cp_file" > "$cp_tmp"
    rc=$?
    if [[ "$rc" != "0" ]] || [[ "$(awk -f "${script_dir}/hooks/_open_issues.awk" "$cp_tmp" 2>/dev/null)" != "ok" ]] || ! grep -qxF -- "$note" "$cp_tmp" || ! grep -qxF -- "$basis_line" "$cp_tmp"; then
      rm -f "$tmp" "$cp_tmp"
      echo "review turn: CHECKPOINT 의 Open Issues 정리 검증 실패 — SESSION·CHECKPOINT 를 바꾸지 않고 중단합니다." >&2
      return 1
    fi
    cp_bak="$(mktemp "${session_dir}/.CHECKPOINT.bak.XXXXXX")" && cp "$cp_file" "$cp_bak" || { rm -f "$tmp" "$cp_tmp" "${cp_bak:-}"; echo "review turn: CHECKPOINT 백업 실패 — 바꾸지 않고 중단합니다." >&2; return 1; }
    if ! mv "$cp_tmp" "$cp_file"; then
      rm -f "$tmp" "$cp_tmp" "$cp_bak"
      echo "review turn: CHECKPOINT 교체(mv) 실패 — SESSION·CHECKPOINT 를 바꾸지 않고 중단합니다." >&2
      return 1
    fi
    if ! mv "$tmp" "$SESSION_FILE"; then
      rm -f "$tmp"
      if mv "$cp_bak" "$cp_file" 2>/dev/null; then
        echo "review turn: SESSION 교체(mv) 실패 — CHECKPOINT 를 되돌리고 중단합니다. 원인을 고친 뒤 같은 --override 를 다시 실행하십시오." >&2
      else
        echo "review turn: SESSION 교체(mv) 실패 — CHECKPOINT 도 되돌리지 못했습니다. 정리 전 CHECKPOINT 는 ${cp_bak#${project_root}/} 에 남깁니다." >&2
        echo "  원인을 고친 뒤 같은 --override 를 다시 실행하면 종결을 이어 합니다. 종결하지 않기로 했으면 그 백업을 CHECKPOINT.md 로 되돌리십시오." >&2
      fi
      return 1
    fi
    rm -f "$cp_bak"
  fi
  echo "리뷰 세션 종결: 사람의 결정으로 남은 이의를 덮고 종결했습니다 (Status closed, Closure Reason user-override)." >&2
  echo "  ${basis_line}" >&2
  echo "  CHECKPOINT 의 Open Issues 를 '- 없음' 으로 바꾸고 남은 이의 원문을 「사용자 종결」 문단에 옮겼습니다." >&2
  echo "  다음 단계: 검증 증거를 확인한 뒤 bash rd-workflow/scripts/rd review seal ${rel} 로 종결 마커를 만드십시오." >&2
  return 0
}

# --- 어댑터 신호 전달과 유한 정리 (change spec codex-adapter-turn-loss-and-reap §2.2) ---
# 어댑터를 백그라운드로 띄우고 wait 한다. 포그라운드 자식이 실행 중이면 bash 는 신호 trap 을
# 자식 종료까지 미루므로 포그라운드로는 신호를 가로챌 수 없다.
# 수명: A(rr_init ~ spawn 직전) B(spawn ~ rr_pid 대입 전) C(rr_adopt 직후) D(wait 중) E(수거 후).
# **trap '' (신호 잠금)은 어댑터 spawn 뒤 rr_begin_terminate 에서만 쓴다.** 무시(ignore) 상태는
# 자식이 상속하고 자식이 그 신호의 trap 을 설치할 수 없게 만든다. spawn 전에는 기록 전용 trap 이다.
# 대상은 이번 실행의 rr_pid 하나다 (pkill·이름 매칭·프로세스 그룹 전체 kill 을 쓰지 않는다).
rr_sig=""
rr_sig_rc=""
rr_pid=""
rr_spawned=""
rr_grace_expired=0
rr_terminating=0
rr_int_checked=0

# bash 는 비대화형 셸이 시작 때 무시(ignore)된 신호를 trap 으로 되돌릴 수 없다. 부모가 `cmd &` 로
# 이 스크립트를 띄우면 SIGINT 가 무시된 채 시작되어 INT 로는 어댑터 정리가 일어나지 않는다
# (HUP·TERM 은 영향 없음). trap 재설정이 불가능하므로 한계를 실행당 한 번 알린다.
# 감지: 상속된 무시 상태는 `trap -p` 에 나타나지 않으므로, INT trap 을 건 직후에도 `trap -p INT`
# 가 비어 있으면 trap 이 적용되지 않은 것(= 무시 상태로 시작)이다.
rr_warn_int_ignored() {
  [[ "$rr_int_checked" -eq 1 ]] && return 0
  rr_int_checked=1
  if [[ -z "$(trap -p INT)" ]]; then
    echo "주의: 이 실행은 SIGINT 가 무시된 채 시작되었습니다(부모가 \`cmd &\` 로 띄웠을 수 있습니다). INT 로는 어댑터 정리가 되지 않습니다. 중단은 TERM 또는 HUP 을 쓰십시오." >&2
  fi
}

rr_init() {
  rr_sig=""
  rr_sig_rc=""
  rr_pid=""
  rr_spawned=""
  rr_grace_expired=0
  rr_terminating=0
  trap 'rr_on_signal HUP 129' HUP
  trap 'rr_on_signal INT 130' INT
  trap 'rr_on_signal TERM 143' TERM
  rr_warn_int_ignored
}

# 구간 A·B(rr_pid 없음)는 최초 신호만 기록하고 돌아온다. 구간 D 는 정리 진입점으로 넘긴다.
rr_on_signal() {
  if [[ -z "$rr_sig" ]]; then
    rr_sig="$1"
    rr_sig_rc="$2"
  fi
  if [[ -z "$rr_pid" ]]; then
    return 0
  fi
  rr_begin_terminate
}

# 유일한 정리 진입점 (일회성). 신호 경로(구간 D)와 보류 확인 경로(구간 C)가 겹쳐도 한 번만 실행한다.
rr_begin_terminate() {
  if [[ "$rr_terminating" -eq 1 ]]; then
    return 0
  fi
  rr_terminating=1
  trap '' HUP INT TERM
  echo "중단 신호 ${rr_sig} 수신 — 어댑터 정리 중 (최대 $(rr_term_grace)초)" >&2
  rr_terminate_adapter
}

# 대기 상한(초). 숫자가 아니면 기본값 15.
rr_term_grace() {
  local g="${RD_REVIEW_TERM_GRACE:-15}"
  case "$g" in
    ''|*[!0-9]*) g=15 ;;
  esac
  # 선행 0 은 bash 산술식에서 8진수로 해석된다(08 은 오류, 010 은 8초). 10진수로 고정한다.
  printf '%s' "$((10#$g))"
}

# 어댑터에 항상 SIGTERM 을 보낸다 (백그라운드 자식은 SIGINT 무시 상태일 수 있어 INT·HUP 을 그대로 전달하지 않는다).
# 종료되면 즉시 반환하고, 상한을 넘기면 KILL 한다.
rr_terminate_adapter() {
  local max_ticks i=0
  max_ticks=$(( $(rr_term_grace) * 2 ))
  kill -TERM "$rr_pid" 2>/dev/null || true
  while kill -0 "$rr_pid" 2>/dev/null; do
    if [[ "$i" -ge "$max_ticks" ]]; then
      kill -KILL "$rr_pid" 2>/dev/null || true
      rr_grace_expired=1
      break
    fi
    sleep 0.5
    i=$(( i + 1 ))
  done
  if [[ "$rr_grace_expired" -eq 1 ]]; then
    echo "    어댑터 정리 결과: 대기 초과 후 강제 종료" >&2
  else
    echo "    어댑터 정리 결과: 정상 종료" >&2
  fi
}

# 구간 E: PID 무효화와 기본 동작 복원. 모든 반환 경로가 거친다.
rr_finish() {
  rr_pid=""
  trap - HUP INT TERM
}

rr_spawn() {
  "$@" &
  rr_spawned=$!
}

rr_set_pid() {
  rr_pid="$rr_spawned"
}

rr_check_pending() {
  if [[ -n "$rr_sig" ]]; then
    rr_begin_terminate
  fi
}

rr_adopt() {
  rr_set_pid
  rr_check_pending
}

# 초기화는 하지 않는다 (호출자가 rr_init 을 먼저 부른다). 신호가 있었으면 반환값을 128+n 으로 덮어쓴다.
rr_spawn_and_wait() {
  local rc=0 pid
  if [[ -n "$rr_sig" ]]; then
    rr_finish
    return "$rr_sig_rc"
  fi
  rr_spawn "$@"
  rr_adopt
  pid="$rr_pid"
  wait "$pid" || rc=$?
  # 신호가 wait 을 끊었으면 정리(trap)가 끝난 뒤 실제 수거를 마친다.
  while [[ -n "$rr_sig" ]] && kill -0 "$pid" 2>/dev/null; do
    wait "$pid" || rc=$?
  done
  rr_finish
  if [[ -n "$rr_sig" ]]; then
    rc="$rr_sig_rc"
  fi
  return "$rc"
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

REOPEN_REASON=""
DECISION_TEXT=""
OVERRIDE_TEXT=""
EXTEND_TURNS=""
session_arg=""
# require_line_arg <옵션> <남은 인자 수> <값> <예시> — 비지 않은 한 줄 값인지 검사합니다.
require_line_arg() {
  if [[ "$2" -lt 2 || -z "${3//[[:space:]]/}" ]]; then
    echo "$1 은 값이 필요합니다. 예: $1 \"$4\"" >&2
    exit 1
  fi
  case "$3" in
    *$'\n'*) echo "$1 값은 한 줄이어야 합니다." >&2; exit 1 ;;
    -*)
      # 지원 옵션·도움말(-h·--help)·오타 옵션이 값으로 소비돼 기록되는 것을 막습니다.
      echo "$1 의 값 자리에 옵션처럼 보이는 값($3)이 왔습니다. 값을 따옴표로 감싸 옵션 바로 뒤에 적고, '-' 로 시작하지 않게 쓰십시오. 예: $1 \"$4\"" >&2; exit 1 ;;
  esac
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reopen)
      if [[ $# -lt 2 || -z "${2//[[:space:]]/}" ]]; then
        echo "--reopen 은 사유가 필요합니다. 예: --reopen \"기록 커밋에서 gitlink 가 바뀜\"" >&2
        exit 1
      fi
      case "$2" in
        *$'\n'*) echo "--reopen 사유는 한 줄이어야 합니다." >&2; exit 1 ;;
        -*)
          echo "--reopen 의 사유 자리에 옵션처럼 보이는 값($2)이 왔습니다. 사유를 따옴표로 감싸 --reopen 바로 뒤에 적고, '-' 로 시작하지 않게 쓰십시오." >&2; exit 1 ;;
      esac
      REOPEN_REASON="$2"
      shift 2
      ;;
    --decision)
      require_line_arg --decision "$#" "${2:-}" "F5 는 값 복구 후 재확인"
      DECISION_TEXT="$2"
      shift 2
      ;;
    --override)
      require_line_arg --override "$#" "${2:-}" "주성 — 남은 F2 는 수용하고 종결"
      OVERRIDE_TEXT="$2"
      shift 2
      ;;
    --extend-turns)
      if [[ $# -lt 2 || ! "${2:-}" =~ ^[1-9][0-9]?$ ]]; then
        echo "--extend-turns 는 늘릴 턴 수(1~99)가 필요합니다. 예: --extend-turns 6" >&2
        exit 1
      fi
      EXTEND_TURNS="$2"
      shift 2
      ;;
    -*)
      usage
      exit 1
      ;;
    *)
      if [[ -n "$session_arg" ]]; then
        usage
        exit 1
      fi
      session_arg="$1"
      shift
      ;;
  esac
done
if [[ -z "$session_arg" ]]; then
  usage
  exit 1
fi
if [[ -n "$REOPEN_REASON" && -n "$DECISION_TEXT" ]]; then
  echo "--reopen 과 --decision 은 함께 쓰지 않습니다. 수렴한 세션은 --reopen, 미해결 이의가 남은 세션은 --decision 을 씁니다." >&2
  exit 1
fi
if [[ -n "$OVERRIDE_TEXT" && ( -n "$REOPEN_REASON" || -n "$DECISION_TEXT" || -n "$EXTEND_TURNS" ) ]]; then
  echo "--override 는 세션을 종결하므로 --reopen·--decision·--extend-turns 와 함께 쓰지 않습니다." >&2
  exit 1
fi

session_dir="$(resolve_path "$session_arg")"

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

# --override: 사람이 남은 이의를 덮고 종결합니다. 어댑터·턴 한도와 무관하므로 여기서 끝냅니다.
if [[ -n "$OVERRIDE_TEXT" ]]; then
  with_state_guard "$SESSION_FILE" apply_user_override "$session_dir" || exit 1
  exit 0
fi

handoff_pending=0
classify_rc=0
classify_session_for_reviewer "$session_dir" || classify_rc=$?
case "$classify_rc" in
  0) ;;
  10) handoff_pending=1 ;;
  *) exit 1 ;;
esac

load_review_config "$REVIEW_TYPE"
compute_next_turn "$TURNS_DIR" "reviewer"

# --- A: 모델·effort 해석의 입력 (spec D4) ---
# 판정 원본은 세션 생성 시 SESSION.md 에 고정 기록된 execution-path 다.
# 턴마다 REQUEST.md 를 재파싱하지 않으므로 REQUEST 아카이브 후에도 안전하다.
# 해석 자체는 도구 루프 안에서 도구마다 한다(resolve_review_selection).
EXECUTION_PATH="$(read_execution_path "$SESSION_FILE")"

relative_session_dir="${session_dir#${project_root}/}"
relative_session_file="${SESSION_FILE#${project_root}/}"
relative_checkpoint_file="${CHECKPOINT_FILE#${project_root}/}"
relative_user_action_file="${USER_ACTION_FILE#${project_root}/}"
relative_expected_turn_file="${EXPECTED_TURN_FILE#${project_root}/}"
relative_latest_turn_file="${LATEST_TURN_FILE#${project_root}/}"

# --extend-turns: 한도에 도달한 세션만 늘립니다. SESSION 쓰기는 아래 전환(apply_author_handoff)에서 한 번에 합니다.
old_turn_limit="$turn_limit"
new_turn_limit=""
limit_reached=0
if [[ "$EXISTING_TURN_COUNT" -ge "$turn_limit" || "$NEXT_TURN_INDEX" -gt "$turn_limit" ]]; then
  limit_reached=1
fi
if [[ -n "$EXTEND_TURNS" ]]; then
  if [[ "$limit_reached" != "1" ]]; then
    echo "--extend-turns 는 턴 한도에 도달한 세션에만 씁니다 (한도 ${turn_limit}, 다음 턴 ${NEXT_TURN_NUMBER}). --extend-turns 없이 다시 실행하십시오." >&2
    exit 1
  fi
  if [[ "$handoff_pending" != "1" ]]; then
    echo "--extend-turns 는 Author 턴을 Reviewer 에게 넘기는 실행에서만 씁니다. 먼저 Author 턴을 쓰십시오." >&2
    exit 1
  fi
  new_turn_limit=$((turn_limit + EXTEND_TURNS))
  if [[ "$NEXT_TURN_INDEX" -gt "$new_turn_limit" ]]; then
    echo "--extend-turns ${EXTEND_TURNS} 로는 다음 턴(${NEXT_TURN_NUMBER})이 한도(${new_turn_limit}) 안에 들지 않습니다. 더 큰 값을 주십시오." >&2
    exit 1
  fi
  turn_limit="$new_turn_limit"
  limit_reached=0
fi
if [[ "$limit_reached" == "1" ]]; then
  echo "session already reached the turn limit (${turn_limit}): $relative_session_dir" >&2
  if [[ "$handoff_pending" == "1" ]]; then
    echo "  사람이 더 이어 가기로 정했으면 늘릴 턴 수를 --extend-turns <N> 으로 붙여 다시 실행하십시오." >&2
  fi
  # --override 는 미해결 이의가 확인된 awaiting-user 세션에서만 실행됩니다(--decision 이 그 확인을 통과한 경우).
  if [[ "$STATUS" == "awaiting-user" && -n "$DECISION_TEXT" ]]; then
    echo "  사람이 남은 이의를 덮고 종결하기로 정했으면 --override \"<결정한 사람> — <그 사람이 한 말>\" 로 종결하십시오." >&2
  fi
  exit 1
fi

# --- reviewer 턴 dispatch 직전 head 재snapshot (§3.2.1) ---
# 턴 한도 검사 뒤에 둡니다 — 턴을 시작하지 않는 경로에서 SESSION 을 건드리지 않기 위함입니다.
# Author 턴 전환이 있는 실행은 재snapshot 과 전환을 같은 상태 잠금 안에서 합니다. 잠금 밖에서 재snapshot 하면
# 거부될 실행이 SESSION 을 먼저 바꾸거나, 겹친 종결이 쓴 상태를 낡은 내용으로 덮을 수 있습니다.
resnapshot_then_handoff() {
  # 재snapshot 과 전환을 같은 디렉터리의 작업 사본에 차례로 적용하고, 둘 다 검증을 통과한 뒤 SESSION 을 한 번만
  # 교체합니다. 중간에 거부되거나 실행이 끊겨도 SESSION 은 실행 전 그대로이고 작업 사본만 남습니다.
  # 완료 안내(재snapshot·재개·연장·인계)는 SESSION 교체에 성공한 뒤에만 냅니다.
  local work rs_file rs_log rs_rc=0 line
  # 잠금 밖에서 본 Open Issues 조건을 잠금 안에서 다시 확인합니다(겹친 --override 가 CHECKPOINT 를 바꿨을 수 있음).
  if [[ -n "$REOPEN_REASON" || -n "$DECISION_TEXT" ]] && override_checkpoint_done "$session_dir"; then
    pending_override_notice "$session_dir"
    return 1
  fi
  if [[ -n "$DECISION_TEXT" ]] && ! session_unresolved_confirmed "$session_dir"; then
    return 1
  fi
  if [[ -n "$REOPEN_REASON" ]] && ! reopen_session_converged "$session_dir"; then
    echo "리뷰 세션을 다시 열 수 없습니다 — 수렴한 세션이 아닙니다 (${REOPEN_UNRESOLVED_REASON})." >&2
    return 1
  fi
  work="$(mktemp "${session_dir}/.SESSION.work.XXXXXX")" && cp -p "$SESSION_FILE" "$work" || {
    rm -f "${work:-}"
    echo "review turn: SESSION 작업 사본을 만들지 못했습니다 — 바꾸지 않고 중단합니다." >&2
    return 1
  }
  # 재snapshot 은 현재 셸에서 실행하고(전역 유지) 안내만 임시 파일로 받습니다.
  rs_file="$(mktemp "${session_dir}/.resnapshot.log.XXXXXX")" || { rm -f "$work"; echo "review turn: 임시 파일 생성 실패 — 바꾸지 않고 중단합니다." >&2; return 1; }
  resnapshot_review_head "$session_dir" "$work" "$REVIEW_TYPE" 2>"$rs_file" || rs_rc=$?
  rs_log="$(cat "$rs_file")"; rm -f "$rs_file"
  if [[ "$rs_rc" != "0" ]]; then
    rm -f "$work"
    [[ -n "$rs_log" ]] && printf '%s\n' "$rs_log" >&2
    echo "review turn: head 재snapshot 실패로 턴을 시작하지 않습니다." >&2
    return 1
  fi
  # 재snapshot 의 완료 안내 외 줄(경고)은 결과와 상관없이 보여 줍니다.
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "review head 재snapshot: "* ]] || printf '%s\n' "$line" >&2
  done <<<"$rs_log"
  if ! apply_author_handoff "$work" "${@:2}"; then
    rm -f "$work"
    return 1
  fi
  if ! mv "$work" "$SESSION_FILE"; then
    rm -f "$work"
    echo "review turn: SESSION 교체(mv) 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  fi
  while IFS= read -r line; do
    [[ "$line" == "review head 재snapshot: "* ]] && printf '%s\n' "$line" >&2
  done <<<"$rs_log"
  for line in "${HANDOFF_NOTICES[@]}"; do printf '%s\n' "$line" >&2; done
}
# 모든 거부 검사를 통과한 뒤에만 Author→Reviewer 상태 전환을 씁니다 (spec 3.2).
if [[ "$handoff_pending" != "1" ]]; then
  if ! resnapshot_review_head "$session_dir" "$SESSION_FILE" "$REVIEW_TYPE"; then
    echo "review turn: head 재snapshot 실패로 턴을 시작하지 않습니다." >&2
    exit 1
  fi
else
  reopen_line=""
  reopen_head="- $(date '+%Y-%m-%d %H:%M') $(basename "$HANDOFF_TURN_FILE") 뒤"
  if [[ -n "$REOPEN_REASON" ]]; then
    reopen_line="${reopen_head} 재개: ${REOPEN_REASON}"
  elif [[ -n "$DECISION_TEXT" ]]; then
    reopen_line="${reopen_head} 사용자 결정으로 재개: ${DECISION_TEXT}"
  fi
  # 턴 한도 연장은 결정·사유 줄과 섞지 않고 별도 줄로 남깁니다(결정 본문을 그대로 보존하기 위해).
  if [[ -n "$new_turn_limit" ]]; then
    ext_line="${reopen_head} 턴 한도 연장: ${old_turn_limit} → ${new_turn_limit}"
    if [[ -n "$reopen_line" ]]; then reopen_line+=$'\n'"$ext_line"; else reopen_line="$ext_line"; fi
  fi
  if ! with_state_guard "$SESSION_FILE" resnapshot_then_handoff "$SESSION_FILE" "$HANDOFF_TURN_FILE" "$reopen_line" "$new_turn_limit"; then
    exit 1
  fi
fi
# 어댑터 실행 직전 head — 실행 기록(reviewer_runs.tsv)의 head 열. 값이 없는 세션은 `-`.
RUN_HEAD="$(session_branch_field "$SESSION_FILE" review-head-oid 2>/dev/null || true)"
[[ -n "$RUN_HEAD" ]] || RUN_HEAD="-"
# USER_ACTION.md 의 결정 표시는 SESSION 의 Reopen History 에서 만듭니다. 매 실행 맞추므로
# 첫 기록이 실패했어도 옵션 없는 재시도가 복구합니다.
sync_user_decisions || true
# 이 작업의 REQUEST 경로 — 기록 커밋 뒤에는 루트 REQUEST.md 가 비어 있어 구간의 보관본을 씁니다 (review_request_file).
REVIEW_REQUEST_FILE="REQUEST.md"
if [[ "$REVIEW_TYPE" == "diff-review" ]] && declare -f review_request_file >/dev/null 2>&1; then
  REVIEW_REQUEST_FILE="$(review_request_file \
    "$(session_branch_field "$SESSION_FILE" review-base-oid 2>/dev/null || true)" \
    "$(session_branch_field "$SESSION_FILE" review-head-oid 2>/dev/null || true)")"
fi
export REVIEW_REQUEST_FILE
# 갱신된 Review Target 을 프롬프트에 반영합니다 — 기록된 OID 와 reviewer 가 읽는 diff 를 같게 유지합니다.
load_session_state "$SESSION_FILE"

# 프롬프트 생성
prompt_file="$(mktemp)" || { echo "run_review_turn: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$prompt_file" && -f "$prompt_file" ]] || { echo "run_review_turn: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
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
        # 차단 안내는 USER_ACTION.md 를 통째로 다시 씁니다. SESSION 의 Reopen History 에서 결정 표시를 다시 만듭니다
        # (옵션 없이 재시도해 다시 차단될 때도 같습니다).
        sync_user_decisions || true
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
  export PROJECT_ROOT="$project_root"
  export SELF_REVIEW_WARNING="$self_review_warning"

  # 모델·effort 는 도구마다 해석해 해석값만 어댑터에 넘긴다 (spec D4·D5).
  # `env -u` 로 먼저 **제거**하는 것이 핵심이다. 호출자 환경에 이 변수들이 남아 있으면
  # ① kill switch 를 켜도 어댑터가 상속값을 읽어 실제로 effort 를 전달하고
  # ② 설정하지 않은 도구도 상속값을 받아 입력 환경에 따라 계약이 깨지며
  # ③ 부모 표시는 계산값을 보고하므로 표시와 실제가 어긋난다.
  resolve_review_selection "$tool" "$EXECUTION_PATH" "$REVIEW_TYPE"
  adapter_env=(env -u TOOL_MODEL -u TOOL_EFFORT -u EFFORT_SOURCE)
  if [[ -n "$MODEL_VALUE" ]]; then
    adapter_env+=("TOOL_MODEL=${MODEL_VALUE}")
  fi
  if [[ -n "$EFFORT_VALUE" ]]; then
    adapter_env+=("TOOL_EFFORT=${EFFORT_VALUE}" "EFFORT_SOURCE=${EFFORT_SOURCE}")
  fi
  printf '%s\n' "$(format_selection_line "$tool")" >&2

  # 어댑터 실행 — 실행 후 실패하면 즉시 중단 (세션 오염 가능)
  # 계측: 시작/종료 경계는 어댑터 프로세스 전후 (spec §4.2). 후처리(validate)는 비포함.
  # effort 열은 요청 effort 다 — 두 도구 모두 해석값을 넘기므로 도구와 상관없이 기록한다 (spec D9).
  metric_effort="$EFFORT_VALUE"
  metric_prompt_bytes="$(wc -c < "$prompt_file" 2>/dev/null | tr -d ' ' || printf '-')"
  metric_target_bytes="$(compute_target_bytes)"
  # 시간 원천도 fail-open — date 실패가 어댑터 실행·턴 진행·종료 코드에 영향을 주지 않는다.
  metric_start="$(date +%s 2>/dev/null)" || metric_start=""
  # 사전 정리(spec §2.1): 이전 턴의 상태 파일·안정 로그를 이번 실행의 것으로 읽지 않도록
  # 어댑터 실행 직전에 부모가 지운다. 지운 뒤에도 경로가 남으면(디렉터리 형태·권한 문제)
  # STALE_UNCLEARED=1 — 실패 진단이 세 파일을 모두 없는 것으로 취급한다. 어댑터는 그대로 실행한다.
  rm -f "${session_dir}/.review_wait_status" "${session_dir}/.codex_output.log" "${session_dir}/.claude_output.log" 2>/dev/null || true
  STALE_UNCLEARED=0
  if [[ -e "${session_dir}/.review_wait_status" || -L "${session_dir}/.review_wait_status" \
        || -e "${session_dir}/.codex_output.log" || -L "${session_dir}/.codex_output.log" \
        || -e "${session_dir}/.claude_output.log" || -L "${session_dir}/.claude_output.log" ]]; then
    STALE_UNCLEARED=1
  fi
  # HUP·INT·TERM 을 받으면 어댑터에 SIGTERM 을 전달하고 RD_REVIEW_TERM_GRACE 초(기본 15)까지 기다린다.
  # 어댑터 실행 직전 CHECKPOINT.md 내용 지문 (파일 없으면 빈 값). 중단 시 보존 안내가 변경 여부를 관측하는 기준이다.
  checkpoint_sum_before="$(cksum < "$CHECKPOINT_FILE" 2>/dev/null || true)"
  rr_init
  adapter_rc=0
  rr_spawn_and_wait "${adapter_env[@]}" bash "$adapter" || adapter_rc=$?
  metric_end="$(date +%s 2>/dev/null)" || metric_end=""

  metric_status="ok"
  if [[ "$adapter_rc" -ne 0 ]]; then
    metric_status="fail"
    [[ "$adapter_rc" -eq 124 ]] && metric_status="timeout"
  fi
  # 일반 실패(시간 초과 124·신호 종료 128+n 이 아님)만 원인을 분류한다. 분류는 여기서 한 번만 하고
  # 그 출력을 관측(모델 거부 판정)과 아래 일반 실패 분기가 함께 쓴다. 시간 초과·신호 종료는 `-` (spec D8).
  cause_out=""
  obs_cause="-"
  fail_log=""
  fail_status=""
  if [[ "$adapter_rc" -ne 0 && "$adapter_rc" -ne 124 && "$adapter_rc" -le 128 ]]; then
    fail_log="${session_dir}/.${tool}_output.log"
    fail_status="${session_dir}/.review_wait_status"
    if [[ "$STALE_UNCLEARED" -eq 1 ]]; then
      fail_log=""
      fail_status=""
    fi
    cause_out="$(classify_adapter_failure_cause "$fail_log" "$tool")"
    obs_cause="$cause_out"
  fi
  # 실제 값 관측 (spec D8): 표시·계측 전용이며 턴의 종료 코드·상태를 바꾸지 않는다.
  # 사전 정리에 실패했으면 남은 로그가 이번 실행의 것인지 알 수 없으므로 세션 대신 `-` 를 넘긴다.
  obs_dir="$session_dir"
  [[ "$STALE_UNCLEARED" -eq 1 ]] && obs_dir="-"
  obs_out="$(observe_actual "$tool" "$obs_dir" "$obs_cause" 2>/dev/null)" || obs_out=""
  [[ "$obs_out" == *$'\t'* ]] || obs_out=$'unknown\tunknown'
  actual_model="${obs_out%%$'\t'*}"
  actual_effort="${obs_out#*$'\t'}"
  metric_tokens="$(observe_turn_tokens "$tool" "$obs_dir" 2>/dev/null)" || metric_tokens="-"
  metric_wall="unavailable"
  if [[ "$metric_start" =~ ^[0-9]+$ && "$metric_end" =~ ^[0-9]+$ ]]; then
    metric_wall="$(( metric_end - metric_start ))s"
    append_turn_metric "$NEXT_TURN_NUMBER" "$REVIEW_TYPE" "$tool" "$metric_effort" \
      "$metric_prompt_bytes" "$metric_target_bytes" "$metric_start" "$metric_end" "$metric_status" "$actual_model" "$metric_tokens" || true
    if [[ "$METRIC_WRITE_OK" -ne 1 ]]; then
      echo "⚠️  turn metric 기록 실패 — 이 턴은 turn_metrics.tsv 에 남지 않습니다 (턴 진행에는 영향 없음)" >&2
    fi
  else
    echo "⚠️  turn metric 시간 원천 실패 — 이 턴은 계측되지 않습니다 (턴 진행에는 영향 없음)" >&2
  fi
  # 가시성(spec §4.4): 모든 경로에서 stderr 한 줄 — validate 실패로 부모가 죽는 경로도 표시가 남는다.
  echo "turn time: ${metric_wall} (status: ${metric_status}) / 실제 모델: ${actual_model} / 실제 effort: ${actual_effort}" >&2

  if [[ "$adapter_rc" -eq 0 ]]; then
    succeeded=true
    used_tool="$tool"
    break
  else
    case "$adapter_rc" in
      124)
        # 대기 초과. 어댑터가 이미 사유·세션 상태·재개 방법을 출력했다.
        # **여기서 "오염" 을 단정하지 않는다** — 어댑터가 판별한 사실이 권위다.
        # **"재실행하십시오" 를 덧붙이지 않는다** — 부모는 재개 가능 여부(resumable)를
        # 모른다. 어댑터가 재개 불가로 판정했으면(adapter_codex.sh) 재개 명령을 일부러
        # 침묵했는데, 부모가 그 뒤에 "재실행하십시오" 를 붙이면 그 침묵이 무효화되어
        # 사용자가 확인 없이 재실행해 부분 산출물을 덮어쓸 위험이 생긴다.
        echo "리뷰 턴 대기가 종료되었습니다: ${tool}. 위의 세션 상태 안내를 확인하십시오." >&2
        report_preserved_turn "$EXPECTED_TURN_FILE" "$CHECKPOINT_FILE" "$checkpoint_sum_before" "$SESSION_FILE" "$relative_expected_turn_file"
        exit 124
        ;;
      *)
        # 신호 종료(128+n, POSIX 셸 관례): 129=HUP 130=INT 143=TERM 137=KILL 131=QUIT 등
        # 번호를 열거하지 않고 부등식으로 판정한다 — OOM killer·`timeout -k` 의 SIGKILL(137)
        # 처럼 열거에 없는 신호도 외부 중단이며, 열거식이면 그런 신호가 아래 "오염" 분기로
        # 떨어져 거짓 문장과 함께 코드까지 1 로 뭉개진다. 124(대기 초과)는 128 미만이라
        # 이 판정과 충돌하지 않고, 어댑터 자신의 실패 코드(주로 1)도 안전하다.
        if [[ "$adapter_rc" -gt 128 ]]; then
          # 외부 중단(Ctrl-C, HUP, TERM, KILL 등). 도구 결함이 아니다.
          # **재개 가능을 단정하지 않는다.** 신호는 리뷰 도구가 턴 파일이나 SESSION 을 쓰기
          # 전·도중·직후 어느 때나 도착한다. 아무 파일도 다시 읽지 않은 채 "재실행하면
          # 이어집니다" 를 출력하면 ① 이미 Owner 가 Author 로 넘어간 완성 턴에서는 같은
          # 명령이 즉시 거부되고 ② 부분 산출물이 있으면 안전한 재개가 증명되지 않았는데
          # 사용자가 확인 없이 재실행해 덮어쓴다. 타임아웃 경로에서 걷어낸 거짓 재개
          # 안내가 신호 경로에 그대로 남아 있던 셈이다(final diff review Important 4).
          # 판별 범위는 어댑터의 report_session_state 와 같다 — 턴 파일 부재 + SESSION.md 의
          # Current Owner / Status 두 필드뿐이며, 그 범위를 함께 밝힌다.
          echo "리뷰 턴이 외부에서 중단되었습니다: ${tool} (signal exit ${adapter_rc})." >&2
          echo "    도구 결함이 아닙니다." >&2
          # extract_section 은 awk 기반이라 파일을 열 수 없으면 rc=2 를 낸다. pipefail +
          # errexit 아래에서 가드 없이 대입하면 여기서 부모가 죽어 신호 종료 코드조차
          # 보존하지 못한다 — 흡수하면 빈 문자열이 되어 아래 조건을 자연히 불만족시킨다.
          sig_owner="$( { extract_section "$SESSION_FILE" "Current Owner" 2>/dev/null || true; } | trim_blank_lines )"
          sig_status="$( { extract_section "$SESSION_FILE" "Status" 2>/dev/null || true; } | trim_blank_lines )"
          # **cleanup 완료를 보장하는 신호에서만** 조건부 재실행 안내를 허용한다.
          # 어댑터가 cleanup(= codex process group 종료)을 보장하는 것은 명시적으로 트랩한
          # HUP(129)·INT(130)·TERM(143) 뿐이다. SIGKILL(137)·SIGQUIT(131) 등은 트랩 불가이거나
          # 트랩되지 않으므로, **어댑터만 죽고 별도 process group 의 codex 와 자손은 계속
          # 실행·수정할 수 있다.** 그 상태에서도 "턴 파일 부재 + Owner=Reviewer/awaiting-reviewer"
          # 는 그대로 참이므로, 세션 상태만 보고 재실행을 권하면 두 agent 가 같은 세션과
          # 워크스페이스를 동시에 건드린다.
          case "$adapter_rc" in
            129|130|143) sig_cleanup_guaranteed=1 ;;
            *)           sig_cleanup_guaranteed=0 ;;
          esac
          # 부모가 대기 상한 안에 어댑터를 정리하지 못해 KILL 했다면 어댑터 cleanup 보장이 깨졌다.
          # 신호 번호가 보장 범위 안(143 등)이어도 이 사유는 따로 말한다 — 「이 신호는 보장하지
          # 못한다」 는 문장은 신호 번호가 실제로 범위 밖일 때만 쓴다(143 에서 자기모순이 된다).
          if [[ "$rr_grace_expired" -eq 1 ]]; then
            sig_cleanup_guaranteed=0
            echo "    (어댑터가 대기 상한 안에 종료하지 않아 부모가 어댑터만 강제 종료했습니다.)" >&2
          fi
          if [[ "$sig_cleanup_guaranteed" -eq 1 && ! -f "$EXPECTED_TURN_FILE" \
                && "$sig_owner" == "Reviewer" && "$sig_status" == "awaiting-reviewer" ]]; then
            echo "    세션 상태: 턴 파일이 생성되지 않았고 SESSION.md 의 Current Owner=Reviewer / Status=awaiting-reviewer 가" >&2
            echo "               보존되어 있습니다 → 같은 명령으로 재실행하면 그대로 이어집니다." >&2
          elif [[ "$sig_cleanup_guaranteed" -ne 1 ]]; then
            if [[ "$rr_grace_expired" -eq 1 ]]; then
              echo "    잔존 프로세스 경고: 어댑터의 정리가 대기 상한 안에 끝나지 않아 정리 완료를 확인하지 못했습니다(exit ${adapter_rc})." >&2
            else
              echo "    잔존 프로세스 경고: 이 신호(exit ${adapter_rc})는 어댑터가 cleanup 을 보장하지 못하는 신호입니다" >&2
              echo "               (보장 범위는 HUP=129 / INT=130 / TERM=143 뿐이며 SIGKILL 은 트랩할 수 없습니다)." >&2
            fi
            echo "               어댑터만 죽고 **별도 process group 의 리뷰 도구와 그 자손이 계속 실행·수정 중일 수 있습니다.**" >&2
            echo "               세션 상태(턴 파일: $( [[ -f "$EXPECTED_TURN_FILE" ]] && echo 존재 || echo 부재 ), Current Owner='${sig_owner}', Status='${sig_status}')만으로는" >&2
            echo "               재개 안전성을 말할 수 없습니다 — **프로세스가 모두 종료된 것을 확인하기 전에 재실행하지 마십시오.**" >&2
            echo "               확인 없이 재실행하면 두 agent 가 같은 세션·워크스페이스를 동시에 건드립니다." >&2
          else
            echo "    세션 상태: 재개 가능 조건을 만족하지 않습니다 (턴 파일: $( [[ -f "$EXPECTED_TURN_FILE" ]] && echo 존재 || echo 부재 ), Current Owner='${sig_owner}', Status='${sig_status}')." >&2
            echo "               세션을 직접 확인한 뒤 이어가십시오 — 확인 없이 재실행하면 거부되거나 부분 산출물을 덮어쓸 수 있습니다." >&2
          fi
          echo "    (부모가 확인한 것은 이 두 필드와 턴 파일뿐입니다. CHECKPOINT.md 등 다른 파일은 검사하지 않았습니다.)" >&2
          report_preserved_turn "$EXPECTED_TURN_FILE" "$CHECKPOINT_FILE" "$checkpoint_sum_before" "$SESSION_FILE" "$relative_expected_turn_file"
          exit "$adapter_rc"
        fi
        # 일반 실패 진단: 원인(로그)과 세션 안전성(상태 파일 + 세션 상태)을 독립 판정한다 (spec §2).
        # 의존: writer 종료 확인은 어댑터가 .review_wait_status 에 남기는 `writer_group: verified` 줄에만 의존한다.
        # 발행 자체는 종료 증명이 아니다(pgid·ps 조회 실패 시 `unverified` 로 발행) — 줄이 없거나 unverified 면 (나).
        # cause_out·fail_status 는 종료 줄 앞에서 한 번 구했다(STALE_UNCLEARED=1 이면 빈 경로로 분류).
        cause_kind="${cause_out%% *}"
        cause_keys="${cause_out#* }"
        safety_out="$(assess_session_safety "$SESSION_FILE" "$EXPECTED_TURN_FILE" "$fail_status")"
        safety_verdict="$(printf '%s\n' "$safety_out" | sed -n '1p')"
        safety_obs="$(printf '%s\n' "$safety_out" | sed -n '2p')"

        echo "어댑터 실행 실패: ${tool}." >&2
        cause_labels=""
        cause_hints=()
        IFS=',' read -r -a cause_arr <<< "$cause_keys"
        for ck in "${cause_arr[@]+"${cause_arr[@]}"}"; do
          case "$ck" in
            effort)    cause_labels="${cause_labels:+$cause_labels, }effort 거부" ;;
            capacity)  cause_labels="${cause_labels:+$cause_labels, }모델 용량 부족"
                       cause_hints+=("모델 용량 부족은 일시적입니다. 잠시 뒤 같은 명령을 재시도하십시오. 설정을 바꾸지 마십시오.") ;;
            ratelimit) cause_labels="${cause_labels:+$cause_labels, }rate limit"
                       cause_hints+=("rate limit 입니다. 잠시 뒤 재시도하십시오.") ;;
            auth)      cause_labels="${cause_labels:+$cause_labels, }인증 실패"
                       cause_hints+=("도구 로그인 상태와 API 키를 확인하십시오 (로그인 후 재실행).") ;;
            model)     cause_labels="${cause_labels:+$cause_labels, }모델 없음" ;;
            spendcap)  cause_labels="${cause_labels:+$cause_labels, }지출 한도·크레딧 소진"
                       cause_hints+=("지출 상한 도달 또는 크레딧 소진입니다. 시간이 지나도 풀리지 않습니다. 워크스페이스 소유자(관리자)가 상한을 올리거나 크레딧을 채운 뒤, 아래 「세션」 안내에 따라 재개하십시오.") ;;
            usagelimit) cause_labels="${cause_labels:+$cause_labels, }사용량 한도"
                       cause_hints+=("요금제 사용량 한도입니다. 바로 재시도해도 풀리지 않습니다. 한도가 재설정된 뒤(오류 문구에 시각이 있으면 그 시각) 아래 「세션」 안내에 따라 재개하십시오.") ;;
          esac
        done
        case "$cause_kind" in
          confirmed)  echo "원인(로그 끝 오류 줄 기준): ${cause_labels}" >&2 ;;
          candidates) echo "원인 후보: ${cause_labels}" >&2 ;;
          *)          echo "원인 불명 (로그 끝 확인: $( [[ -n "$fail_log" && -f "$fail_log" ]] && printf '%s' "$fail_log" || printf '없음' ))" >&2 ;;
        esac
        for hint in "${cause_hints[@]+"${cause_hints[@]}"}"; do
          echo "    처방: ${hint}" >&2
        done
        # 모델·effort 복구 안내 (spec D10): 위에서 구한 분류 출력을 그대로 넘긴다.
        print_selection_recovery "$tool" "$cause_out"
        case "$safety_verdict" in
          ok)      echo "세션: (가) 재실행 가능 — 같은 명령으로 재실행하면 이어집니다." >&2 ;;
          anomaly) echo "세션: (다) 세션 상태 이상 — 아래 관측 사실을 근거로 세션을 직접 확인하십시오." >&2 ;;
          *)       echo "세션: (나) 수동 확인 필요 — 잔존 프로세스를 확인하기 전에 재실행하지 마십시오." >&2 ;;
        esac
        echo "    관측: ${safety_obs}" >&2
        report_preserved_turn "$EXPECTED_TURN_FILE" "$CHECKPOINT_FILE" "$checkpoint_sum_before" "$SESSION_FILE" "$relative_expected_turn_file"
        exit 1
        ;;
    esac
  fi
done

if [[ "$succeeded" != "true" ]]; then
  echo "모든 리뷰 도구가 실패했습니다: $PRIORITY" >&2
  exit 1
fi

# --- 출력 검증 ---
updated_status="$(validate_turn_output "$SESSION_FILE" "$EXPECTED_TURN_FILE" "$NEXT_TURN_INDEX" "$turn_limit" "$used_tool")"
report_nested_git "$session_dir" "$relative_session_dir"

# --- 실행 기록 (reviewer_runs.tsv) — Tool History 보다 먼저, 쓰기 실패면 턴을 실패로 끝냅니다 ---
if [[ "$used_tool" == "claude" ]]; then
  mode="self-review"
else
  mode="reviewer"
fi
if ! append_reviewer_run "$session_dir" "$NEXT_TURN_NUMBER" "$used_tool" "$mode" "$RUN_HEAD" "$EXPECTED_TURN_FILE"; then
  cat >&2 <<EOM
오류: 리뷰어 턴 실행 기록(reviewer_runs.tsv)을 쓰지 못했습니다 — ${relative_session_dir}
    이 턴은 seal 대조에 쓰이지 않습니다. 이대로는 rd review seal 이 이 턴을 실행된 턴으로 인정하지 않습니다.
조치: 쓰기 권한·디스크 공간을 확인한 뒤 같은 턴을 다시 실행하십시오.
    1. 턴 파일을 세션 밖으로 옮깁니다: ${relative_expected_turn_file}
    2. SESSION.md 의 Status 를 awaiting-reviewer, Current Owner 를 Reviewer 로 되돌립니다.
    3. 같은 명령으로 다시 실행합니다: bash rd-workflow/scripts/run_review_turn.sh ${relative_session_dir}
EOM
  exit 1
fi

# --- Tool History 기록 ---
append_tool_history "$SESSION_FILE" "$NEXT_TURN_NUMBER" "$used_tool" "$mode"

# --- 결과 출력 ---
updated_owner="$(extract_section "$SESSION_FILE" "Current Owner" | trim_blank_lines)"

echo "review turn completed (tool: ${used_tool})"
echo "session: ${relative_session_dir}"
echo "turn: ${relative_expected_turn_file}"
echo "status: ${updated_status}"
echo "owner: ${updated_owner}"
echo "turn time: ${metric_wall}"
echo "effort override: $(compute_effort_status)"

# --- 리뷰 비용·범위 밖 (review-loop-formal-closure) — 표시 전용, fail-open ---
review_cost_line "$session_dir" "${metric_tokens:--}" >&2 2>/dev/null || true
oos_out="$(session_out_of_scope "$session_dir" 2>/dev/null)" || oos_out=""
if [[ -n "$oos_out" ]]; then
  {
    echo "범위 밖으로 돌린 항목 (이 세션의 Reviewer 턴):"
    printf '%s\n' "$oos_out" | sed 's/^/  /'
  } >&2
fi
