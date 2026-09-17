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
append_turn_metric() {
  local turn="$1" rt="$2" tool="$3" effort="$4" pbytes="$5" tbytes="$6" s="$7" e="$8" status="$9"
  METRIC_WRITE_OK=0
  {
    local f="${session_dir}/turn_metrics.tsv"
    if [[ ! -f "$f" ]]; then
      printf '# turn\treview_type\ttool\teffort\tprompt_bytes\ttarget_bytes\tstart_epoch\tend_epoch\twall_seconds\tstatus\n' > "$f"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$turn" "$rt" "$tool" "${effort:-none}" "$pbytes" "$tbytes" "$s" "$e" "$(( e - s ))" "$status" >> "$f" \
      && METRIC_WRITE_OK=1
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
  local base_oid old_head new_head policy tmp rc cs

  # diff-review 가 아니면 대상이 아닙니다 (author 턴은 호출부에서 이미 걸러집니다).
  [[ "$rtype" == "diff-review" ]] || return 0

  base_oid="$(session_branch_field "$session_file" "review-base-oid")"
  old_head="$(session_branch_field "$session_file" "review-head-oid")"
  # 둘 다 없으면 §5.2.1 의 파싱 불가 세션이거나 이 계약 이전의 legacy 세션이므로
  # 건드리지 않습니다 (legacy 경로 유지).
  if [[ -z "$base_oid" && -z "$old_head" ]]; then
    return 0
  fi
  # **한쪽만 있는 세션은 legacy 가 아니라 손상입니다** (final diff review turn 006 Finding 1).
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
  # (final diff review turn 004 Finding 2). `pinned` 을 검증 앞에서 조기 반환시키면,
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

  # **raw 필드는 저장소 native full OID 여야 합니다** (final diff review turn 006 Finding 1).
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
    want_target="git diff ${resolved_base}..${new_head}"
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

  # ② 같은 디렉터리 임시 파일에 SESSION 전체를 렌더링
  tmp="$(mktemp "${session_dir}/.SESSION.md.XXXXXX")" || {
    echo "review turn: 임시 파일 생성 실패 — SESSION 을 바꾸지 않고 중단합니다." >&2
    return 1
  }
  awk -v newhead="$new_head" -v target="git diff ${resolved_base}..${new_head}" '
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

# --- reviewer 턴 dispatch 직전 head 재snapshot (§3.2.1) ---
# 턴 한도 검사 뒤에 둡니다 — 턴을 시작하지 않는 경로에서 SESSION 을 건드리지 않기 위함입니다.
if ! resnapshot_review_head "$session_dir" "$SESSION_FILE" "$REVIEW_TYPE"; then
  echo "review turn: head 재snapshot 실패로 턴을 시작하지 않습니다." >&2
  exit 1
fi
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
  # 계측: 시작/종료 경계는 어댑터 프로세스 전후 (spec §4.2). 후처리(validate)는 비포함.
  metric_effort=""
  [[ "$tool" == "codex" ]] && metric_effort="$EFFORT_VALUE"
  metric_prompt_bytes="$(wc -c < "$prompt_file" 2>/dev/null | tr -d ' ' || printf '-')"
  metric_target_bytes="$(compute_target_bytes)"
  # 시간 원천도 fail-open — date 실패가 어댑터 실행·턴 진행·종료 코드에 영향을 주지 않는다.
  metric_start="$(date +%s 2>/dev/null)" || metric_start=""
  adapter_rc=0
  "${adapter_env[@]}" bash "$adapter" || adapter_rc=$?
  metric_end="$(date +%s 2>/dev/null)" || metric_end=""

  metric_status="ok"
  if [[ "$adapter_rc" -ne 0 ]]; then
    metric_status="fail"
    [[ "$adapter_rc" -eq 124 ]] && metric_status="timeout"
  fi
  metric_wall="unavailable"
  if [[ "$metric_start" =~ ^[0-9]+$ && "$metric_end" =~ ^[0-9]+$ ]]; then
    metric_wall="$(( metric_end - metric_start ))s"
    append_turn_metric "$NEXT_TURN_NUMBER" "$REVIEW_TYPE" "$tool" "$metric_effort" \
      "$metric_prompt_bytes" "$metric_target_bytes" "$metric_start" "$metric_end" "$metric_status" || true
    if [[ "$METRIC_WRITE_OK" -ne 1 ]]; then
      echo "⚠️  turn metric 기록 실패 — 이 턴은 turn_metrics.tsv 에 남지 않습니다 (턴 진행에는 영향 없음)" >&2
    fi
  else
    echo "⚠️  turn metric 시간 원천 실패 — 이 턴은 계측되지 않습니다 (턴 진행에는 영향 없음)" >&2
  fi
  # 가시성(spec §4.4): 모든 경로에서 stderr 한 줄 — validate 실패로 부모가 죽는 경로도 표시가 남는다.
  echo "turn time: ${metric_wall} (status: ${metric_status})" >&2

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
          # 워크스페이스를 동시에 건드린다(final diff review 턴 004 Important 2).
          case "$adapter_rc" in
            129|130|143) sig_cleanup_guaranteed=1 ;;
            *)           sig_cleanup_guaranteed=0 ;;
          esac
          if [[ "$sig_cleanup_guaranteed" -eq 1 && ! -f "$EXPECTED_TURN_FILE" \
                && "$sig_owner" == "Reviewer" && "$sig_status" == "awaiting-reviewer" ]]; then
            echo "    세션 상태: 턴 파일이 생성되지 않았고 SESSION.md 의 Current Owner=Reviewer / Status=awaiting-reviewer 가" >&2
            echo "               보존되어 있습니다 → 같은 명령으로 재실행하면 그대로 이어집니다." >&2
          elif [[ "$sig_cleanup_guaranteed" -ne 1 ]]; then
            echo "    잔존 프로세스 경고: 이 신호(exit ${adapter_rc})는 어댑터가 cleanup 을 보장하지 못하는 신호입니다" >&2
            echo "               (보장 범위는 HUP=129 / INT=130 / TERM=143 뿐이며 SIGKILL 은 트랩할 수 없습니다)." >&2
            echo "               어댑터만 죽고 **별도 process group 의 리뷰 도구와 그 자손이 계속 실행·수정 중일 수 있습니다.**" >&2
            echo "               세션 상태(턴 파일: $( [[ -f "$EXPECTED_TURN_FILE" ]] && echo 존재 || echo 부재 ), Current Owner='${sig_owner}', Status='${sig_status}')만으로는" >&2
            echo "               재개 안전성을 말할 수 없습니다 — **프로세스가 모두 종료된 것을 확인하기 전에 재실행하지 마십시오.**" >&2
            echo "               확인 없이 재실행하면 두 agent 가 같은 세션·워크스페이스를 동시에 건드립니다." >&2
          else
            echo "    세션 상태: 재개 가능 조건을 만족하지 않습니다 (턴 파일: $( [[ -f "$EXPECTED_TURN_FILE" ]] && echo 존재 || echo 부재 ), Current Owner='${sig_owner}', Status='${sig_status}')." >&2
            echo "               세션을 직접 확인한 뒤 이어가십시오 — 확인 없이 재실행하면 거부되거나 부분 산출물을 덮어쓸 수 있습니다." >&2
          fi
          echo "    (부모가 확인한 것은 이 두 필드와 턴 파일뿐입니다. CHECKPOINT.md 등 다른 파일은 검사하지 않았습니다.)" >&2
          exit "$adapter_rc"
        fi
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
echo "turn time: ${metric_wall}"
echo "effort override: $(compute_effort_status "$used_tool")"
