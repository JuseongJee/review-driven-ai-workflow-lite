#!/usr/bin/env bash
# model_select.sh — 리뷰 턴의 모델·effort 선택 함수와 설정 조회·저장 CLI.
#
# source 용 함수(접두 ms_)와 CLI 진입점을 함께 둔다. CLI 는 이 파일을 직접 실행할 때만 돈다.
#   bash model_select.sh show review [<리뷰 종류>]
#   bash model_select.sh set <칸> <값|null>
#   bash model_select.sh set-legacy <경로> <JSON 값>
#   bash model_select.sh apply <저장 목록 파일>
#
# 값은 stdout, 경고는 stderr 로 낸다. bash 3.2 호환이며 외부 의존은 jq 뿐이다.
# 함수는 호출자의 `set -euo pipefail` 아래에서도 돌도록 실패할 수 있는 명령을 모두 감싼다.
# 정본: rd-workflow-workspace/specs/changes/2026-11-19-1500-call-site-model-effort-selection-change-spec.md (D2~D6·D11)

_MS_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MS_SELF="${_MS_SELF_DIR}/$(basename "${BASH_SOURCE[0]}")"
_MS_PROJECT_ROOT="$(cd "${_MS_SELF_DIR}/../.." && pwd)"

# effort 단계의 고정 순서와 Claude 고정 단계표 (spec D4)
_MS_EFFORT_ORDER="low medium high xhigh max ultra"
_MS_CLAUDE_LEVELS="low medium high xhigh max"

# 공유 상태 (set -u 방어용 초기화)
MS_MODELS_KV="${MS_MODELS_KV:-}"
MS_MODELS_PATH="${MS_MODELS_PATH:-}"
MS_MODELS_LOADED="${MS_MODELS_LOADED:-0}"
MS_LEGACY_KV="${MS_LEGACY_KV:-}"
MS_LEGACY_PATH="${MS_LEGACY_PATH:-}"
MS_REVIEW_TYPE="${MS_REVIEW_TYPE:-}"
MS_NOTICES=""
MS_PICK_VALUE=""; MS_PICK_ORIGIN=""; MS_PICK_KIND=""
MS_MODEL_VALUE=""; MS_MODEL_RAW=""; MS_MODEL_SOURCE=""; MS_MODEL_ORIGIN=""
MS_EFFORT_VALUE=""; MS_EFFORT_RAW=""; MS_EFFORT_SOURCE=""; MS_EFFORT_ORIGIN=""; MS_EFFORT_REJECTED=""

# ------------------------------------------------------------
# 경로
# ------------------------------------------------------------
ms_codex_home() { printf '%s' "${CODEX_HOME:-$HOME/.codex}"; }

ms_models_path() { printf '%s' "${RD_MODELS_CONFIG:-${_MS_PROJECT_ROOT}/rd-workflow/config/models.json}"; }

ms_legacy_path() { printf '%s' "${REVIEW_TOOLS_CONFIG:-${_MS_PROJECT_ROOT}/rd-workflow/config/review-tools.json}"; }

# 저장 경로는 명령 치환 없이 받는다. 명령 치환은 끝의 개행을 모두 지워, 개행으로 끝나는 경로가
# 이웃 파일을 가리키게 된다. _ms_path_into <변수 이름> <ms_models_path|ms_legacy_path>
_ms_path_into() { local _p; _p="$("$2"; printf x)"; printf -v "$1" '%s' "${_p%x}"; }

# 상위 폴더도 `dirname` 의 명령 치환 대신 매개변수 확장으로 구한다. 결과는 _MS_PARENT 에 둔다.
_ms_parent_of() {
  case "$1" in
    */*) _MS_PARENT="${1%/*}"; [[ -n "$_MS_PARENT" ]] || _MS_PARENT="/" ;;
    *)   _MS_PARENT="." ;;
  esac
}

ms_jq_available() { command -v jq >/dev/null 2>&1; }

# ------------------------------------------------------------
# 값 판정 (spec D2)
# ms_classify <claude|codex> <model|effort> <값> → alias|family|pinned|default|step|relative|invalid
# ------------------------------------------------------------
ms_classify() {
  local tool="$1" kind="$2" v="${3:-}"
  local re_claude_pin='^(claude|fable)-[a-z0-9]+(-[a-z0-9]+)*$'
  local re_codex_pin='^gpt-[0-9]+(\.[0-9]+)*-[a-z]+$'
  local re_family='^[a-z]+$'
  if [[ "$v" == "default" ]]; then printf 'default'; return 0; fi
  if [[ "$kind" == "effort" ]]; then
    case "$v" in
      low|medium|high|xhigh|max|ultra) printf 'step' ;;
      lowest|highest)                  printf 'relative' ;;
      *)                               printf 'invalid' ;;
    esac
    return 0
  fi
  if [[ "$tool" == "claude" ]]; then
    case "$v" in
      opus|sonnet|haiku|fable) printf 'alias'; return 0 ;;
    esac
    if [[ "$v" =~ $re_claude_pin ]]; then printf 'pinned'; else printf 'invalid'; fi
    return 0
  fi
  if [[ "$v" =~ $re_codex_pin ]]; then printf 'pinned'; return 0; fi
  if [[ "$v" =~ $re_family ]]; then printf 'family'; return 0; fi
  printf 'invalid'
}

# set 실패 안내에 쓰는 허용 형식
_ms_allowed_text() {
  local tool="$1" kind="$2"
  if [[ "$kind" == "effort" ]]; then
    printf 'low·medium·high·xhigh·max·ultra, lowest·highest, default, null(칸 비우기)'
  elif [[ "$tool" == "claude" ]]; then
    printf 'opus·sonnet·haiku·fable, claude-<이름>·fable-<이름> 고정 이름, default, null(칸 비우기)'
  else
    printf '계열 이름(소문자, 예: sol), gpt-<버전>-<계열> 고정 이름, default, null(칸 비우기)'
  fi
}

# ------------------------------------------------------------
# Codex 계열 해석·config.toml·지원 단계 (spec D3·D4)
# ------------------------------------------------------------
# ms_codex_resolve_family <계열> → slug (rc 0) 또는 빈 값 (rc 1, 경고)
ms_codex_resolve_family() {
  local fam="$1" home cache slug=""
  home="$(ms_codex_home)"
  cache="${home}/models_cache.json"
  if [[ -f "$cache" ]] && ms_jq_available; then
    slug="$(jq -r --arg fam "$fam" '
      [ .models[]?
        | select(type == "object" and .visibility == "list")
        | (.slug // "") as $s
        | ($s | strings | capture("^gpt-(?<v>[0-9]+(\\.[0-9]+)*)-(?<f>[a-z]+)$")?) as $c
        | select($c.f == $fam)
        | { s: $s, v: ($c.v | split(".") | map(tonumber)), p: (.priority // 1e9) } ]
      | max_by([.v, -.p]) | .s // empty
    ' "$cache" 2>/dev/null)" || slug=""
  fi
  if [[ -n "$slug" ]]; then
    printf '%s' "$slug"
    return 0
  fi
  echo "⚠️  Codex 계열 '${fam}' 을 모델 목록(${cache})에서 찾지 못해 모델을 지정하지 않고 실행합니다 (${home}/config.toml 의 모델을 씁니다)." >&2
  return 1
}

# ms_codex_config_model → <Codex 홈>/config.toml 의 첫 `[` 절 앞 `model = "…"` / `model = '…'` 값 또는 빈 값.
# 전체 TOML 파서가 아니다. 기본·리터럴 문자열 한 줄만 읽는다.
ms_codex_config_model() {
  local f
  f="$(ms_codex_home)/config.toml"
  [[ -f "$f" ]] || return 0
  awk -v sq="'" '
    /^[ \t]*\[/ { exit }
    /^[ \t]*model[ \t]*=/ {
      line = $0
      sub(/^[ \t]*model[ \t]*=[ \t]*/, "", line)
      q = substr(line, 1, 1)
      if (q == "\"" || q == sq) {
        rest = substr(line, 2); i = index(rest, q)
        if (i > 0) { print substr(rest, 1, i - 1); exit }
      }
    }' "$f" 2>/dev/null || true
}

# ms_codex_levels <slug> → 지원 단계(고정 순서, 공백 구분) 또는 빈 값
ms_codex_levels() {
  local slug="$1" cache
  cache="$(ms_codex_home)/models_cache.json"
  [[ -n "$slug" && -f "$cache" ]] || return 0
  ms_jq_available || return 0
  jq -r --arg s "$slug" --arg order "$_MS_EFFORT_ORDER" '
    (first(.models[]? | select(type == "object" and .slug == $s))
      | [ .supported_reasoning_levels[]? | (if type == "object" then .effort else . end) | strings ]) as $l
    | [ ($order | split(" "))[] as $x | select(any($l[]; . == $x)) | $x ]
    | join(" ")
  ' "$cache" 2>/dev/null || true
}

# ------------------------------------------------------------
# effort 변환 (spec D4)
# ms_convert_effort <claude|codex> <값> <지원 단계|빈 값> → <결과값>
#   결과값이 비면 미전달. 낮추거나 해석하지 못하면 경고를 여기서 낸다.
# ------------------------------------------------------------
ms_convert_effort() {
  local tool="$1" v="$2" levels="${3:-}" cls
  if [[ "$tool" == "claude" ]]; then levels="$_MS_CLAUDE_LEVELS"; fi
  cls="$(ms_classify "$tool" effort "$v")"
  case "$cls" in
    step) ;;
    relative)
      if [[ -z "$levels" ]]; then
        echo "⚠️  Codex 모델의 지원 단계를 알 수 없어 effort '${v}' 를 해석하지 못했습니다 — effort 를 넘기지 않습니다." >&2
        return 0
      fi
      # shellcheck disable=SC2086
      set -- $levels
      if [[ "$v" == "lowest" ]]; then
        printf '%s' "$1"
      else
        local last=""
        for last in "$@"; do :; done
        printf '%s' "$last"
      fi
      return 0
      ;;
    *) return 0 ;;
  esac

  # 단계 이름: 모델 정보가 없으면 그대로 넘긴다.
  if [[ -z "$levels" ]]; then printf '%s' "$v"; return 0; fi
  case " $levels " in
    *" $v "*) printf '%s' "$v"; return 0 ;;
  esac
  # 고정 순서에서 바로 아래의 지원 단계, 없으면 지원 단계 중 가장 낮은 것.
  local s below="" lowest=""
  for s in $_MS_EFFORT_ORDER; do
    [[ "$s" == "$v" ]] && break
    case " $levels " in *" $s "*) below="$s" ;; esac
  done
  if [[ -z "$below" ]]; then
    for s in $_MS_EFFORT_ORDER; do
      case " $levels " in *" $s "*) lowest="$s"; break ;; esac
    done
    below="$lowest"
  fi
  local who="Codex 모델"
  if [[ "$tool" == "claude" ]]; then who="Claude"; fi
  echo "⚠️  ${who}에서 지원하지 않는 effort '${v}' 를 '${below}' 로 바꿉니다 (지원 단계: ${levels})." >&2
  printf '%s' "$below"
}

# ------------------------------------------------------------
# 설정 읽기 (spec D6)
# ------------------------------------------------------------
# ms_load_models <파일> <리뷰 종류|*> → TSV 칸\t상태\t값 (상태 ok|invalid)
ms_load_models() {
  local file="$1" rt="${2:-}" out rc=0 line
  [[ -f "$file" ]] || return 0
  ms_jq_available || return 0
  out="$(jq -rs --arg rt "$rt" '
    def fld($name; $v):
      if $v == null then empty
      elif ($v | type) == "string" and $v != "" then [$name, "ok", $v]
      else [$name, "invalid", ($v | if type == "string" then . else tojson end)] end;
    def bad($v): $v != null and ($v | type) != "object";
    if length != 1 or (.[0] | type) != "object" then ["!corrupt"]
    else .[0].review as $r
    | if $r == null then empty
      elif bad($r) then ["!section", "review"]
      else
        ( $r.codex as $c
          | if $c == null then empty
            elif bad($c) then ["!section", "review.codex"]
            else
              fld("review.codex.model"; $c.model),
              fld("review.codex.effort"; $c.effort),
              fld("review.codex.small_task_effort"; $c.small_task_effort),
              ( $c.review_types as $t
                | if $t == null then empty
                  elif bad($t) then ["!section", "review.codex.review_types"]
                  elif $rt == "*" then
                    ( $t | to_entries[] | .key as $k | .value as $e
                      | if $e == null then empty
                        elif bad($e) then ["!section", "review.codex.review_types.\($k)"]
                        else fld("review.codex.review_type_effort.\($k)"; $e.effort) end )
                  else
                    ( $t[$rt] as $e
                      | if $e == null then empty
                        elif bad($e) then ["!section", "review.codex.review_types.\($rt)"]
                        else fld("review.codex.review_type_effort"; $e.effort) end )
                  end )
            end ),
        ( $r.claude as $c
          | if $c == null then empty
            elif bad($c) then ["!section", "review.claude"]
            else
              fld("review.claude.model"; $c.model),
              fld("review.claude.effort"; $c.effort)
            end )
      end
    end
    | @tsv
  ' "$file" 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 || "$out" == "!corrupt" ]]; then
    echo "⚠️  models.json 을 읽지 못했습니다(${file}) — 이 파일을 무시하고 옛 설정으로 진행합니다." >&2
    return 0
  fi
  [[ -n "$out" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      "!section"$'\t'*)
        echo "⚠️  models.json 의 ${line#*$'\t'} 이 객체가 아닙니다(${file}) — 그 아래 칸을 비어 있는 것으로 봅니다." >&2
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<<"$out"
}

# ms_load_legacy <파일> <리뷰 종류|*> → 전역 MS_LEGACY_KV (stdout 없음)
# run_review_turn.sh 의 load_review_config_once jq 추출을 그대로 옮겼다.
# TSV(key<TAB>value), null 필드는 "null" 문자열, missing 필드는 행 부재. 파싱 실패는 경고 후 빈 값, rc 0.
# jq 유무 경고는 호출자가 ms_jq_available 로 한 번 낸다.
# 리뷰 종류가 * 이면 effort_override 대신 종류마다 tool.codex.effort_override.<종류> 행을 낸다(show 전용).
ms_load_legacy() {
  local file="$1" rt="${2:-}" kv
  MS_LEGACY_KV=""
  MS_LEGACY_PATH="$file"
  [[ -f "$file" ]] || return 0
  ms_jq_available || return 0
  if ! kv="$(jq -r --arg rt "$rt" '
    ( [ "priority",
        (((.overrides // {})[$rt].priority // .default_priority) | join(" ")) ]
      | @tsv ),
    ( (.tools // {}) | to_entries[] | .key as $t | .value | to_entries[]
      | [ "tool.\($t).\(.key)", (.value | tostring) ]
      | @tsv ),
    ( if $rt == "*" then
        ( (.overrides // {}) | to_entries[] | select(.value | type == "object")
          | .key as $k | ((.value.tools.codex.reasoning_effort?) // "") as $e
          | select($e != "")
          | [ "tool.codex.effort_override.\($k)", $e ] | @tsv )
      else
        ( [ "tool.codex.effort_override",
            ( ((.overrides // {})[$rt].tools.codex.reasoning_effort) // "" ) ] | @tsv )
      end ),
    ( [ "tool.codex.effort_default",
        ( (.tools.codex.reasoning_effort) // "" ) ] | @tsv ),
    ( [ "tool.codex.small_task_effort",
        ( (.tools.codex.small_task_reasoning_effort) // "" ) ] | @tsv )
  ' "$file" 2>/dev/null)"; then
    echo "⚠️  설정 파일 파싱 실패: $file" >&2
    echo "    기본 설정으로 진행합니다: codex → claude" >&2
    return 0
  fi
  MS_LEGACY_KV="$kv"
}

# MS_MODELS_KV 를 한 번만 채운다 (실행기·show 가 먼저 불러 두면 다시 읽지 않는다).
ms_load_models_once() {
  local rt="${1:-}"
  [[ "$MS_MODELS_LOADED" == "1" ]] && return 0
  _ms_path_into MS_MODELS_PATH ms_models_path
  MS_MODELS_KV="$(ms_load_models "$MS_MODELS_PATH" "$rt")" || MS_MODELS_KV=""
  MS_MODELS_LOADED=1
}

# 옛 KV 키 → 사용자가 보는 review-tools.json 경로
_ms_legacy_json_key() {
  local k="$1"
  case "$k" in
    tool.codex.effort_default)    printf 'tools.codex.reasoning_effort' ;;
    tool.codex.small_task_effort) printf 'tools.codex.small_task_reasoning_effort' ;;
    tool.codex.effort_override)   printf 'overrides.%s.tools.codex.reasoning_effort' "$MS_REVIEW_TYPE" ;;
    tool.codex.effort_override.*) printf 'overrides.%s.tools.codex.reasoning_effort' "${k#tool.codex.effort_override.}" ;;
    tool.*)                       printf 'tools.%s' "${k#tool.}" ;;
    *)                            printf '%s' "$k" ;;
  esac
}

# 새 칸 → 사용자가 보는 models.json 경로 (리뷰 종류별 칸만 다르다)
_ms_new_json_key() {
  local k="$1"
  case "$k" in
    review.codex.review_type_effort)   printf 'review.codex.review_types.%s.effort' "$MS_REVIEW_TYPE" ;;
    review.codex.review_type_effort.*) printf 'review.codex.review_types.%s.effort' "${k#review.codex.review_type_effort.}" ;;
    *)                                 printf '%s' "$k" ;;
  esac
}

# ms_pick_field <새 칸> <옛 KV 키|-> → MS_PICK_VALUE·MS_PICK_ORIGIN·MS_PICK_KIND
# 새 칸이 ok 이고 판정이 invalid 가 아니면 그 값, 아니면 MS_LEGACY_KV 의 옛 행, 둘 다 없으면 빈 값.
# 환경 변수는 보지 않는다. 옛 키를 쓰면 안내 줄을 MS_NOTICES 에 더한다.
ms_pick_field() {
  local key="$1" old="${2:--}" row state val tool kind nk
  nk="$(_ms_new_json_key "$key")"
  MS_PICK_VALUE=""; MS_PICK_ORIGIN=""; MS_PICK_KIND=""
  case "$key" in review.claude.*) tool=claude ;; *) tool=codex ;; esac
  case "$key" in *.model) kind=model ;; *) kind=effort ;; esac

  row="$(printf '%s\n' "$MS_MODELS_KV" | awk -F'\t' -v k="$key" '$1==k{print $2 "\t" $3; exit}')"
  if [[ -n "$row" ]]; then
    state="${row%%$'\t'*}"; val="${row#*$'\t'}"
    if [[ "$state" == "ok" && "$(ms_classify "$tool" "$kind" "$val")" != "invalid" ]]; then
      MS_PICK_VALUE="$val"
      MS_PICK_ORIGIN="file:${MS_MODELS_PATH}#${nk}"
      MS_PICK_KIND="models.json"
      return 0
    fi
    echo "⚠️  ${MS_MODELS_PATH} 의 ${nk} 값이 올바르지 않습니다: ${val} — $(_ms_allowed_text "$tool" "$kind" | sed 's/, null(칸 비우기)$//'). 이 칸을 비어 있는 것으로 봅니다." >&2
  fi

  [[ "$old" == "-" ]] && return 0
  val="$(printf '%s\n' "$MS_LEGACY_KV" | awk -F'\t' -v k="$old" '$1==k{print $2; exit}')"
  if [[ -n "$val" && "$val" != "null" ]]; then
    local jk
    jk="$(_ms_legacy_json_key "$old")"
    MS_PICK_VALUE="$val"
    MS_PICK_ORIGIN="file:${MS_LEGACY_PATH}#${jk}"
    MS_PICK_KIND="review-tools.json"
    local note="ℹ️  옛 설정 ${MS_LEGACY_PATH} 의 ${jk} 를 썼습니다 — ${MS_MODELS_PATH} 의 ${nk} 으로 옮기십시오."
    if [[ -z "$MS_NOTICES" ]]; then MS_NOTICES="$note"; else MS_NOTICES="${MS_NOTICES}"$'\n'"${note}"; fi
  fi
  return 0
}

# ------------------------------------------------------------
# 리뷰 턴의 모델·effort 해석 (spec D4·D5)
# ms_resolve_review <tool> <execution-path> <리뷰 종류>
#   → MS_MODEL_{VALUE,RAW,SOURCE,ORIGIN}·MS_EFFORT_{VALUE,RAW,SOURCE,ORIGIN,REJECTED}·MS_NOTICES
# 호출 전에 실행기가 ms_load_legacy 를 한 번 불러 둔다(MS_LEGACY_KV). models.json 은 처음 한 번 읽는다.
# ------------------------------------------------------------
_ms_env_pick() { # _ms_env_pick <변수> <tool> <kind> → 유효하면 MS_PICK_* 를 채우고 rc 0
  local var="$1" tool="$2" kind="$3" v
  v="${!var:-}"
  MS_PICK_VALUE=""; MS_PICK_ORIGIN=""; MS_PICK_KIND=""
  [[ -n "$v" ]] || return 1
  if [[ "$(ms_classify "$tool" "$kind" "$v")" == "invalid" ]]; then
    echo "⚠️  환경 변수 ${var} 값이 올바르지 않습니다: ${v} — $(_ms_allowed_text "$tool" "$kind" | sed 's/, null(칸 비우기)$//'). 이 값을 무시합니다." >&2
    return 1
  fi
  MS_PICK_VALUE="$v"; MS_PICK_ORIGIN="env:${var}"; MS_PICK_KIND="env"
  return 0
}

ms_resolve_review() {
  local tool="$1" exec_path="${2:-unknown}" rt="${3:-}"
  local T kind_src cls
  MS_REVIEW_TYPE="$rt"
  MS_NOTICES=""
  MS_MODEL_VALUE=""; MS_MODEL_RAW=""; MS_MODEL_SOURCE="cli-default"; MS_MODEL_ORIGIN="cli-default"
  MS_EFFORT_VALUE=""; MS_EFFORT_RAW=""; MS_EFFORT_SOURCE="global"; MS_EFFORT_ORIGIN="cli-default"; MS_EFFORT_REJECTED=""

  # 선택 대상은 Codex·Claude 뿐이다. 다른 도구(gemini 등)는 models.json·RD_REVIEW_* 를 쓰지 않고,
  # 어댑터 계약(TOOL_MODEL)대로 review-tools.json 의 tools.<도구>.model 만 그대로 넘긴다. effort 는 넘기지 않는다.
  case "$tool" in
    codex|claude) ;;
    *)
      local other
      other="$(printf '%s\n' "$MS_LEGACY_KV" | awk -F'\t' -v k="tool.${tool}.model" '$1==k{print $2; exit}')"
      if [[ -n "$other" && "$other" != "null" ]]; then
        MS_MODEL_VALUE="$other"; MS_MODEL_RAW="$other"; MS_MODEL_SOURCE="review-tools.json"
        MS_MODEL_ORIGIN="file:${MS_LEGACY_PATH}#tools.${tool}.model"
      fi
      return 0 ;;
  esac

  # jq 가 없으면 모든 설정(새 표·옛 키·환경 변수)을 쓰지 않는다 (spec D6).
  ms_jq_available || return 0
  ms_load_models_once "$rt"
  if [[ "$tool" == "codex" ]]; then T=CODEX; else T=CLAUDE; fi

  # --- 모델 (spec D5) ---
  kind_src=""
  if _ms_env_pick "RD_REVIEW_${T}_MODEL" "$tool" model; then
    kind_src="env"
  elif [[ "$tool" == "codex" ]]; then
    ms_pick_field review.codex.model - && [[ -n "$MS_PICK_VALUE" ]] && kind_src="$MS_PICK_KIND"
  else
    ms_pick_field review.claude.model tool.claude.model && [[ -n "$MS_PICK_VALUE" ]] && kind_src="$MS_PICK_KIND"
  fi
  if [[ -n "$kind_src" ]]; then
    MS_MODEL_RAW="$MS_PICK_VALUE"; MS_MODEL_SOURCE="$kind_src"; MS_MODEL_ORIGIN="$MS_PICK_ORIGIN"
    if [[ "$kind_src" == "review-tools.json" ]]; then
      MS_MODEL_VALUE="$MS_MODEL_RAW"   # 옛 키는 판정 없이 그대로 넘긴다
    else
      cls="$(ms_classify "$tool" model "$MS_MODEL_RAW")"
      case "$cls" in
        default) MS_MODEL_VALUE="" ;;
        family)
          if MS_MODEL_VALUE="$(ms_codex_resolve_family "$MS_MODEL_RAW")"; then :; else
            MS_MODEL_VALUE=""; MS_MODEL_SOURCE="unresolved"
          fi ;;
        pinned)
          echo "⚠️  ${MS_MODEL_ORIGIN} 의 모델 '${MS_MODEL_RAW}' 은 고정 이름입니다 — 고정됨, 낡을 수 있음." >&2
          MS_MODEL_VALUE="$MS_MODEL_RAW" ;;
        *) MS_MODEL_VALUE="$MS_MODEL_RAW" ;;
      esac
    fi
  fi

  # --- effort (spec D4) ---
  kind_src=""
  local stage=""
  if [[ "$tool" == "codex" && -n "${RD_REVIEW_EFFORT_OVERRIDE+x}" ]]; then
    if [[ "${RD_REVIEW_EFFORT_OVERRIDE}" != "0" ]]; then
      echo "⚠️  RD_REVIEW_EFFORT_OVERRIDE 값을 인식할 수 없습니다: ${RD_REVIEW_EFFORT_OVERRIDE} (허용: 미설정 또는 0)" >&2
      echo "    effort override 를 적용하지 않고 전역 설정을 따릅니다." >&2
    fi
    MS_EFFORT_SOURCE="kill-switch"; MS_EFFORT_ORIGIN="env:RD_REVIEW_EFFORT_OVERRIDE"
    return 0
  fi
  if _ms_env_pick "RD_REVIEW_${T}_EFFORT" "$tool" effort; then
    stage="env"
  elif [[ "$tool" == "codex" ]]; then
    if [[ "$exec_path" == "small-task" ]]; then
      ms_pick_field review.codex.small_task_effort tool.codex.small_task_effort
      [[ -n "$MS_PICK_VALUE" ]] && stage="small-task"
    fi
    if [[ -z "$stage" ]]; then
      ms_pick_field review.codex.review_type_effort tool.codex.effort_override
      [[ -n "$MS_PICK_VALUE" ]] && stage="review-type"
    fi
    if [[ -z "$stage" ]]; then
      ms_pick_field review.codex.effort tool.codex.effort_default
      [[ -n "$MS_PICK_VALUE" ]] && stage="tool-default"
    fi
  else
    ms_pick_field review.claude.effort -
    [[ -n "$MS_PICK_VALUE" ]] && stage="tool-default"
  fi
  [[ -n "$stage" ]] || return 0

  MS_EFFORT_RAW="$MS_PICK_VALUE"; MS_EFFORT_SOURCE="$stage"; MS_EFFORT_ORIGIN="$MS_PICK_ORIGIN"
  if [[ "$MS_PICK_KIND" == "review-tools.json" ]]; then
    MS_EFFORT_VALUE="$MS_EFFORT_RAW"   # 옛 키 값은 변환하지 않는다
  elif [[ "$MS_EFFORT_RAW" == "default" ]]; then
    MS_EFFORT_VALUE=""                 # 의도적 미전달 — 아래 단계로 가지 않는다
  else
    local levels="" target=""
    if [[ "$tool" == "codex" ]]; then
      target="$MS_MODEL_VALUE"
      [[ -n "$target" ]] || target="$(ms_codex_config_model)"
      [[ -n "$target" ]] && levels="$(ms_codex_levels "$target")"
    fi
    MS_EFFORT_VALUE="$(ms_convert_effort "$tool" "$MS_EFFORT_RAW" "$levels")"
  fi

  # 하한: small-task 단계에서 고른 값이 low·minimal 이면 미전달한다.
  if [[ "$stage" == "small-task" ]]; then
    case "$MS_EFFORT_VALUE" in
      low|minimal)
        echo "⚠️  small-task effort ${MS_EFFORT_VALUE} (${MS_EFFORT_ORIGIN}) 은 허용 하한(medium) 미만입니다." >&2
        echo "    조용한 값 보정을 하지 않고 effort 를 전달하지 않습니다." >&2
        MS_EFFORT_SOURCE="below-floor"
        MS_EFFORT_REJECTED="$MS_EFFORT_VALUE"
        MS_EFFORT_VALUE=""
        ;;
    esac
  fi
  return 0
}

# ------------------------------------------------------------
# 실제 값 관측 (spec D8) — 표시·계측 전용
# observe_actual <codex|claude> <세션 디렉터리|-> <분류 출력|-> → <model>\t<effort>, 항상 rc 0
#   세션 자리의 `-` 는 사전 정리 실패(STALE_UNCLEARED=1)다 — 이번 실행의 로그로 믿을 수 없어 읽지 않는다.
#   로그는 어댑터가 이번 실행에서 안정 이름으로 발행했을 때만 읽는다. 근거는 어댑터가 리뷰 도구의 process
#   group 종료를 확인한 뒤 남기는 상태 파일(`.review_wait_status`, 일반 파일)의 `log_preserved: yes` 와
#   `writer_group: verified` 두 줄이다. 없으면 살아 있는 도구가 쓴 파일일 수 있어 읽지 않는다(unknown).
#   분류 출력은 일반 실패 경로의 classify_adapter_failure_cause 한 줄이다. 시간 초과·신호 종료는 `-`.
#   로그 없음·해당 줄 없음·읽기/파싱 실패 → unknown. 요청값으로 채우지 않는다.
#   Claude init 행이 있을 때만: 빈 모델 → unknown, 빈 effort → 미확인.
# ------------------------------------------------------------
observe_actual() {
  local tool="${1:-}" sd="${2:--}" cause="${3:--}"
  local log out="" rc m="unknown" e="unknown" keys st
  st="${sd}/.review_wait_status"
  if [[ -n "$sd" && "$sd" != "-" && -f "$st" && ! -L "$st" ]] \
     && grep -q '^log_preserved: yes$' "$st" 2>/dev/null \
     && grep -q '^writer_group: verified$' "$st" 2>/dev/null; then
    case "$tool" in
      codex)
        log="${sd}/.codex_output.log"
        if [[ -f "$log" && ! -L "$log" ]]; then
          rc=0
          # 첫 `--------` 줄과 두 번째 `--------` 줄 사이의 머리말만 읽는다.
          out="$(awk '
            /^--------[[:space:]]*$/ { n++; if (n >= 2) exit; next }
            n == 1 && mv == "" && index($0, "model: ") == 1            { mv = substr($0, 8) }
            n == 1 && ev == "" && index($0, "reasoning effort: ") == 1 { ev = substr($0, 19) }
            END { printf "%s\t%s", mv, ev }' "$log" 2>/dev/null)" || rc=$?
          if [[ "$rc" -eq 0 ]]; then
            m="${out%%$'\t'*}"; e="${out#*$'\t'}"
            [[ -n "$m" ]] || m="unknown"
            [[ -n "$e" ]] || e="unknown"
          fi
        fi
        ;;
      claude)
        log="${sd}/.claude_output.log"
        if [[ -f "$log" && ! -L "$log" ]] && ms_jq_available; then
          rc=0
          # stderr 가 섞인 로그다 — JSON 아닌 줄·잘린 줄은 fromjson? 으로 건너뛰고, init 앞의 hook 줄도 지나친다.
          out="$(jq -nrR 'first(inputs | fromjson? | select(type=="object" and .type=="system" and .subtype=="init")) | [(.model // ""), (.effort // "")] | @tsv' "$log" 2>/dev/null)" || rc=$?
          # 실패하면 부분 출력을 버린다. 성공했지만 행이 없으면(init 없음) 두 값 모두 unknown 이다.
          if [[ "$rc" -eq 0 && -n "$out" ]]; then
            # IFS=$'\t' read 는 앞쪽 빈 칸을 지워 effort 를 모델 자리로 옮기므로 첫 탭 앞뒤로 나눈다.
            m="${out%%$'\t'*}"; e="${out#*$'\t'}"
            [[ -n "$m" ]] || m="unknown"
            [[ -n "$e" ]] || e="미확인"
          fi
        fi
        ;;
    esac
  fi
  # 모델 거부: 분류 키 목록에 model 이 있으면(confirmed·candidates 모두) 머리말·init 의 모델은 실제 사용 근거가 아니다.
  if [[ -n "$cause" && "$cause" != "-" ]]; then
    keys="${cause#* }"
    case ",${keys}," in
      *,model,*) m="unknown" ;;
    esac
  fi
  printf '%s\t%s\n' "$m" "$e"
  return 0
}

# ------------------------------------------------------------
# 저장 (spec D11) — 잠금·임시 파일·검사·실패 시 원본 보존
_MS_HELD_LOCK=""
_MS_HELD_TMP=""
_ms_release_lock() {
  # 중단(INT·TERM → exit)으로 들어와도 아직 옮기지 않은 임시 파일을 남기지 않는다.
  if [[ -n "$_MS_HELD_TMP" ]]; then rm -f "$_MS_HELD_TMP" 2>/dev/null || true; fi
  _MS_HELD_TMP=""
  if [[ -n "$_MS_HELD_LOCK" ]]; then rmdir "$_MS_HELD_LOCK" 2>/dev/null || true; fi
  _MS_HELD_LOCK=""
  trap - EXIT INT TERM
}

# _ms_write_json <대상 파일> <표시 이름> <빈 파일일 때 시작 JSON> <경로 JSON 배열> <값 JSON>
# ------------------------------------------------------------
_ms_write_json() {
  local file="$1" label="$2" seed="$3" pathjson="$4" valjson="$5"
  local lock dir base tmp bad check hops=0 target
  # 심볼릭 링크는 실제 파일까지 따라가 그 경로를 잠그고 교체한다. 링크 경로 자체를 교체하면
  # 링크가 일반 파일로 바뀌고 실제 설정 파일은 그대로 남는다.
  while [[ -L "$file" ]]; do
    hops=$((hops + 1))
    # 명령 치환은 끝의 개행을 모두 지운다. `-n` 으로 대상만 받고 표지 x 를 붙여 대상 끝의 개행을 지킨다.
    if target="$(readlink -n "$file" 2>/dev/null && printf x)"; then
      target="${target%x}"
    else
      target=""
    fi
    if [[ -z "$target" || $hops -gt 20 ]]; then
      echo "⚠️  ${label} 을 고치지 못했습니다(${1}) — 심볼릭 링크를 따라가지 못함. 실제 파일 경로를 지정한 뒤 다시 실행하십시오." >&2
      return 1
    fi
    case "$target" in
      /*) file="$target" ;;
      *)  _ms_parent_of "$file"; file="${_MS_PARENT}/${target}" ;;
    esac
  done
  lock="${file}.lock"
  _ms_parent_of "$file"; dir="$_MS_PARENT"

  # 대상이 폴더 같은 일반 파일이 아닌 것이면 `mv` 가 그 안으로 옮기고 성공해 버린다. 잠그기 전에 거부한다.
  if [[ -e "$file" && ! -f "$file" ]]; then
    echo "⚠️  ${label} 을 고치지 못했습니다(${file}) — 일반 파일이 아님. 이 경로의 폴더·특수 파일을 치우거나 다른 경로를 지정한 뒤 다시 실행하십시오." >&2
    return 1
  fi

  if ! mkdir "$lock" 2>/dev/null; then
    if [[ -e "$lock" ]]; then
      echo "⚠️  다른 저장이 진행 중입니다(${lock}). 잠시 뒤 다시 실행하십시오. 진행 중인 저장이 없는데 이 안내가 계속 나오면 ${lock} 폴더를 지우십시오." >&2
    else
      echo "⚠️  ${label} 잠금을 만들지 못했습니다(${lock}) — ${dir} 가 있는지, 쓰기 권한이 있는지 확인하십시오." >&2
    fi
    return 1
  fi
  # 자기가 만든 잠금만 지운다 (점유 안내 경로는 위에서 이미 끝났다).
  _MS_HELD_LOCK="$lock"
  trap '_ms_release_lock' EXIT
  trap 'exit 130' INT TERM

  _ms_write_fail() {
    echo "⚠️  ${label} 을 고치지 못했습니다(${file}) — $1. 파일을 직접 고친 뒤 다시 실행하십시오." >&2
    if [[ -n "${tmp:-}" ]]; then rm -f "$tmp"; fi
    _ms_release_lock
    return 1
  }

  if [[ -f "$file" ]]; then
    base="$(cat "$file")" || { _ms_write_fail "손상"; return 1; }
    check="$(printf '%s' "$base" | jq -s 'length == 1 and (.[0] | type) == "object"' 2>/dev/null)" || check=false
    [[ "$check" == "true" ]] || { _ms_write_fail "손상"; return 1; }
  else
    base="$seed"
  fi

  bad="$(printf '%s' "$base" | jq -r --argjson p "$pathjson" '
    first( range(1; $p | length) as $i | $p[:$i] as $q
           | (getpath($q) | type) as $t
           | select($t != "object" and $t != "null") | $q | join(".") ) // ""
  ' 2>/dev/null)" || bad="?"
  if [[ -n "$bad" ]]; then
    _ms_write_fail "${bad} 이 객체가 아님"; return 1
  fi

  tmp="$(mktemp "${dir}/.$(basename "$file").XXXXXX" 2>/dev/null)" || tmp=""
  [[ -n "$tmp" ]] || { _ms_write_fail "임시 파일을 만들지 못함"; return 1; }
  _MS_HELD_TMP="$tmp"
  # 권한: mktemp 의 0600 을 그대로 옮기지 않는다. 원본이 있으면 `cp -p` 로 원본 권한을 받고(뒤의 `>` 는
  # 내용만 바꾸고 권한은 그대로 둔다), 없으면 0644 로 만든다.
  if [[ -f "$file" ]]; then
    cp -p "$file" "$tmp" 2>/dev/null || { _ms_write_fail "임시 파일을 만들지 못함"; return 1; }
  else
    chmod 644 "$tmp" 2>/dev/null || { _ms_write_fail "임시 파일을 만들지 못함"; return 1; }
  fi
  if ! printf '%s' "$base" | jq --argjson p "$pathjson" --argjson v "$valjson" 'setpath($p; $v)' >"$tmp" 2>/dev/null; then
    _ms_write_fail "임시 파일을 만들지 못함"; return 1
  fi
  check="$(jq -s 'length == 1 and (.[0] | type) == "object"' "$tmp" 2>/dev/null)" || check=false
  [[ "$check" == "true" ]] || { _ms_write_fail "임시 파일을 만들지 못함"; return 1; }
  if ! mv -f "$tmp" "$file" 2>/dev/null; then
    _ms_write_fail "옮기지 못함"; return 1
  fi
  tmp=""; _MS_HELD_TMP=""
  _ms_release_lock
  return 0
}

# bash model_select.sh set <칸> <값|null>
_ms_cli_set() {
  local key="${1:-}" val="${2-}" file tool kind pathjson valjson rt
  _ms_path_into file ms_models_path
  if [[ $# -ne 2 ]]; then
    echo "사용법: bash model_select.sh set <칸> <값|null>" >&2; return 1
  fi
  case "$key" in
    review.codex.model)              tool=codex;  kind=model;  pathjson='["review","codex","model"]' ;;
    review.codex.effort)             tool=codex;  kind=effort; pathjson='["review","codex","effort"]' ;;
    review.codex.small_task_effort)  tool=codex;  kind=effort; pathjson='["review","codex","small_task_effort"]' ;;
    review.claude.model)             tool=claude; kind=model;  pathjson='["review","claude","model"]' ;;
    review.claude.effort)            tool=claude; kind=effort; pathjson='["review","claude","effort"]' ;;
    review.codex.review_types.*.effort)
      rt="${key#review.codex.review_types.}"; rt="${rt%.effort}"
      if ! [[ "$rt" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "⚠️  알 수 없는 칸입니다: ${key}. models.json 은 바꾸지 않았습니다." >&2; return 1
      fi
      tool=codex; kind=effort; pathjson="[\"review\",\"codex\",\"review_types\",\"${rt}\",\"effort\"]" ;;
    *)
      echo "⚠️  알 수 없는 칸입니다: ${key} (허용: review.codex.model·review.codex.effort·review.codex.small_task_effort·review.codex.review_types.<종류>.effort·review.claude.model·review.claude.effort). models.json 은 바꾸지 않았습니다." >&2
      return 1 ;;
  esac
  if [[ "$val" == "null" ]]; then
    valjson="null"
  else
    if [[ "$(ms_classify "$tool" "$kind" "$val")" == "invalid" ]]; then
      echo "⚠️  ${key} 에 쓸 수 없는 값입니다: ${val} — $(_ms_allowed_text "$tool" "$kind"). models.json 은 바꾸지 않았습니다." >&2
      return 1
    fi
    valjson="$(jq -n --arg v "$val" '$v')"
  fi
  _ms_write_json "$file" "models.json" '{"version":1}' "$pathjson" "$valjson"
}

# bash model_select.sh set-legacy <경로> <JSON 값> — review-tools.json 에서 setup 이 묻는 칸만 쓴다.
_ms_cli_set_legacy() {
  local key="${1:-}" val="${2-}" file pathjson ok=0
  _ms_path_into file ms_legacy_path
  if [[ $# -ne 2 ]]; then
    echo "사용법: bash model_select.sh set-legacy <경로> <JSON 값>" >&2; return 1
  fi
  case "$key" in
    default_priority|tools.codex.bin|tools.claude.bin|tools.gemini.bin|tools.claude.self_review_policy|tools.gemini.model)
      ok=1 ;;
    overrides.*.priority)
      local rt="${key#overrides.}"; rt="${rt%.priority}"
      [[ "$rt" =~ ^[A-Za-z0-9_-]+$ ]] && ok=1 ;;
  esac
  if [[ $ok -ne 1 ]]; then
    echo "⚠️  review-tools.json 의 ${key} 는 이 명령으로 쓸 수 없습니다 (허용: default_priority·tools.<codex|claude|gemini>.bin·tools.claude.self_review_policy·tools.gemini.model·overrides.<종류>.priority). 모델·effort 는 set 으로 models.json 에 쓰십시오. review-tools.json 은 바꾸지 않았습니다." >&2
    return 1
  fi
  if ! jq -n --argjson v "$val" '$v' >/dev/null 2>&1; then
    echo "⚠️  ${key} 에 쓸 값이 JSON 이 아닙니다: ${val}. review-tools.json 은 바꾸지 않았습니다." >&2
    return 1
  fi
  pathjson="$(jq -cn --arg k "$key" '$k | split(".")')"
  _ms_write_json "$file" "review-tools.json" '{"default_priority":["codex","claude"]}' "$pathjson" "$val"
}

# bash model_select.sh apply <저장 목록 파일>
# 줄마다 `models <칸> <값>` 또는 `legacy <경로> <JSON 값>`. 값은 둘째 칸 뒤의 나머지 전부다(JSON 공백 허용).
_ms_cli_apply() {
  local list="${1:-}" line kind key val sub var path cmd reason failed=0
  local -a pending=()
  if [[ ! -f "$list" ]]; then
    echo "⚠️  저장 목록 파일이 없습니다: ${list}" >&2; return 1
  fi
  if [[ ! -r "$list" ]]; then
    echo "⚠️  저장 목록 파일을 읽지 못했습니다: ${list} — 읽기 권한을 확인하십시오. 아무 칸도 바꾸지 않았습니다." >&2; return 1
  fi
  local mpath lpath
  _ms_path_into mpath ms_models_path; [[ "$mpath" == /* ]] || mpath="${PWD}/${mpath}"
  _ms_path_into lpath ms_legacy_path; [[ "$lpath" == /* ]] || lpath="${PWD}/${lpath}"
  # 목록은 한 번만 읽는다. 줄을 `<종류> <경로> <값>` 으로 나누되 구분은 공백 하나이고, 종류는 models·legacy,
  # 경로는 공백 없는 한 단어, 값은 공백이 아닌 글자로 시작하는 나머지 전부다. 한 줄이라도 이 규칙에
  # 맞지 않으면 아무 칸도 바꾸지 않는다. 쓰기는 검사한 항목을 그대로 쓴다.
  local n=0 i re='^(models|legacy) ([^[:space:]]+) ([^[:space:]].*)$'
  local -a kinds=() keys=() vals=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -n "${line//[[:space:]]/}" ]] || continue
    if [[ "$line" =~ $re ]]; then
      kinds+=("${BASH_REMATCH[1]}"); keys+=("${BASH_REMATCH[2]}"); vals+=("${BASH_REMATCH[3]}")
    else
      echo "⚠️  저장 목록 ${list} 의 ${n}번째 줄을 읽지 못했습니다: ${line} — 줄은 \`models <칸> <값>\` 또는 \`legacy <경로> <JSON 값>\` 을 공백 하나로 나눈 것이어야 합니다. 아무 칸도 바꾸지 않았습니다." >&2
      return 1
    fi
  done <"$list" || {
    echo "⚠️  저장 목록 파일을 읽지 못했습니다: ${list}. 아무 칸도 바꾸지 않았습니다." >&2; return 1
  }
  for ((i = 0; i < ${#kinds[@]}; i++)); do
    kind="${kinds[$i]}"; key="${keys[$i]}"; val="${vals[$i]}"
    if [[ "$kind" == models ]]; then
      sub="set";      var=RD_MODELS_CONFIG;   path="$mpath"
    else
      sub=set-legacy; var=REVIEW_TOOLS_CONFIG; path="$lpath"
    fi
    cmd="${var}=$(printf '%q' "$path") bash $(printf '%q' "$_MS_SELF") ${sub} $(printf '%q' "$key") $(printf '%q' "$val")"
    if [[ $failed -eq 1 ]]; then
      printf '미적용: %s\n' "$cmd"
      pending+=("$cmd")
      continue
    fi
    if reason="$(env "${var}=${path}" bash "$_MS_SELF" "$sub" "$key" "$val" 2>&1 >/dev/null)"; then
      printf '반영됨: %s\n' "$cmd"
    else
      reason="$(printf '%s\n' "$reason" | awk 'NF{sub(/^⚠️ +/, ""); print; exit}')"
      printf '실패: %s — %s\n' "$cmd" "${reason:-알 수 없는 오류}"
      pending+=("$cmd")
      failed=1
    fi
  done
  if [[ $failed -eq 1 ]]; then
    local joined="" c
    for c in "${pending[@]+"${pending[@]}"}"; do
      if [[ -z "$joined" ]]; then joined="$c"; else joined="${joined} && ${c}"; fi
    done
    printf '다시 실행: %s\n' "$joined"
    return 1
  fi
  return 0
}

# bash model_select.sh show review [<리뷰 종류>]
# 우선순위 해석을 쓰지 않고 칸마다 ms_pick_field 로 `값 — 출처` 를 낸다. 환경 변수는 kill switch 줄만 보인다.
_ms_show_row() { # _ms_show_row <라벨> <새 칸> <옛 키|->
  local origin
  ms_pick_field "$2" "$3"
  case "$MS_PICK_KIND" in
    models.json)       origin="models.json" ;;
    review-tools.json) origin="review-tools.json (옛 키)" ;;
    *)                 origin="미설정" ;;
  esac
  printf '%s: %s — %s\n' "$1" "${MS_PICK_VALUE:--}" "$origin"
}

_ms_cli_show() {
  local what="${1:-}" rt="${2:-}" mode types t
  if [[ "$what" != "review" ]]; then
    echo "사용법: bash model_select.sh show review [<리뷰 종류>]" >&2; return 1
  fi
  if ! ms_jq_available; then
    echo "⚠️  jq 가 없어 설정을 읽을 수 없습니다 (brew install jq)." >&2; return 1
  fi
  mode="${rt:-*}"
  MS_REVIEW_TYPE="$rt"
  local lpath; _ms_path_into lpath ms_legacy_path
  ms_load_legacy "$lpath" "$mode"
  MS_MODELS_LOADED=0
  ms_load_models_once "$mode"

  printf '설정: models.json=%s / review-tools.json=%s\n' "$MS_MODELS_PATH" "$MS_LEGACY_PATH"
  _ms_show_row "Codex 모델"              review.codex.model             -
  _ms_show_row "Codex effort"            review.codex.effort            tool.codex.effort_default
  _ms_show_row "Codex small-task effort" review.codex.small_task_effort tool.codex.small_task_effort
  if [[ -n "$rt" ]]; then
    _ms_show_row "Codex effort (${rt})" review.codex.review_type_effort tool.codex.effort_override
  else
    types="$( { printf '%s\n' "$MS_MODELS_KV" | awk -F'\t' 'index($1,"review.codex.review_type_effort.")==1{print substr($1,33)}'
                printf '%s\n' "$MS_LEGACY_KV" | awk -F'\t' 'index($1,"tool.codex.effort_override.")==1{print substr($1,28)}'
              } | awk 'NF && !seen[$0]++')"
    if [[ -n "$types" ]]; then
      while IFS= read -r t; do
        _ms_show_row "Codex effort (${t})" "review.codex.review_type_effort.${t}" "tool.codex.effort_override.${t}"
      done <<<"$types"
    fi
  fi
  _ms_show_row "Claude 모델"  review.claude.model  tool.claude.model
  _ms_show_row "Claude effort" review.claude.effort -

  if [[ -z "${RD_REVIEW_EFFORT_OVERRIDE+x}" ]]; then
    printf 'kill switch: RD_REVIEW_EFFORT_OVERRIDE=미설정 (적용 중)\n'
  elif [[ "$RD_REVIEW_EFFORT_OVERRIDE" == "0" ]]; then
    printf 'kill switch: RD_REVIEW_EFFORT_OVERRIDE=0 (무력화됨)\n'
  else
    printf 'kill switch: RD_REVIEW_EFFORT_OVERRIDE=%s (무력화됨 · 인식 불가 값)\n' "$RD_REVIEW_EFFORT_OVERRIDE"
  fi
}

_ms_main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  if ! ms_jq_available && [[ "$sub" != "" ]]; then
    echo "⚠️  jq 가 없어 실행할 수 없습니다 (brew install jq)." >&2
    return 1
  fi
  case "$sub" in
    show)       _ms_cli_show "$@" ;;
    set)        _ms_cli_set "$@" ;;
    set-legacy) _ms_cli_set_legacy "$@" ;;
    apply)      _ms_cli_apply "$@" ;;
    *)
      cat >&2 <<'EOF'
사용법:
  bash rd-workflow/scripts/model_select.sh show review [<리뷰 종류>]
  bash rd-workflow/scripts/model_select.sh set <칸> <값|null>
  bash rd-workflow/scripts/model_select.sh set-legacy <경로> <JSON 값>
  bash rd-workflow/scripts/model_select.sh apply <저장 목록 파일>
EOF
      return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  _ms_main "$@"
  exit $?
fi
