#!/usr/bin/env bash
# subagent_dispatch_display.sh — 구현 중 Agent 호출마다 넘긴 모델·effort 와 models.json 설정을 한 줄로 보인다.
#
# 왜 필요한가: skill 문구로 「응답 텍스트로 표시」 를 지시했으나 무인 실행 12회에서 한 번도 표시되지 않았다.
# LLM 행동에 기대지 않고 PreToolUse(matcher: Agent) hook 의 systemMessage 로 옮긴다.
# 정본: rd-workflow-workspace/specs/changes/2026-11-23-1910-subagent-dispatch-model-display-hook-change-spec.md
#
# 판정: Status 가 `구현 중` 일 때만 표시한다. 그 밖에는 선택기를 부르기 전에 출력 없이 끝낸다.
# 작업 루트: hook 입력 cwd 의 git 최상위(무인 세션이 작업 worktree 로 이동한 뒤의 호출을 따른다), 없으면 hook 파일 기준.
# 실행하는 선택기는 hook 쪽 model_select.sh 뿐이다(작업 루트의 스크립트는 실행하지 않는다).
# 항상 exit 0 — 판정 실패·도구 부재·설정 해석 실패 모두 통과(fail-open). set -e 를 쓰지 않는다.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0

_hook_input="$(cat 2>/dev/null)" || _hook_input=""
_hook_input_read=1

# 작업 루트 — source 전에 정한다.
_cwd=""
if command -v jq >/dev/null 2>&1; then
  _cwd="$(printf '%s' "$_hook_input" | jq -r '(.cwd // "") | tostring' 2>/dev/null)" || _cwd=""
elif command -v python3 >/dev/null 2>&1; then
  _cwd="$(printf '%s' "$_hook_input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get("cwd") if isinstance(d, dict) else None
    sys.stdout.write(v if isinstance(v, str) else "")
except Exception:
    pass' 2>/dev/null)" || _cwd=""
fi
project_root=""
if [[ -n "$_cwd" && -d "$_cwd" ]]; then
  project_root="$(git -C "$_cwd" rev-parse --show-toplevel 2>/dev/null)" || project_root=""
fi
[[ -n "$project_root" && -d "$project_root" ]] || project_root="$(cd "${script_dir}/../../.." && pwd)" || exit 0

source "${script_dir}/_guard_common.sh" 2>/dev/null || exit 0

status="$(get_task_status 2>/dev/null)" || status=""
[[ "$status" == "구현 중" ]] || exit 0

# 넘긴 값 — 최상위 effort(세션 effort 객체)는 읽지 않는다.
if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  given_model="$(_rd_guard_json_get '.tool_input.model' 'tool_input.model')"
  given_effort="$(_rd_guard_json_get '.tool_input.effort' 'tool_input.effort')"
  given_known=1
else
  given_model="확인 불가 (jq·python3 없음)"
  given_effort="확인 불가 (jq·python3 없음)"
  given_known=0
fi

name="$(get_current_short_title 2>/dev/null)" || name=""
if [[ -z "$name" || "$name" == "-" ]]; then name_label="작업 이름 없음"; else name_label="$name"; fi

# 설정 — hook 쪽 선택기만 실행한다. 설정 파일은 작업 루트의 models.json(환경에 없을 때만).
sel="${script_dir}/../model_select.sh"
sel_out=""; sel_rc="파일 없음"; warn=""
if [[ -f "$sel" ]]; then
  ef="$(mktemp 2>/dev/null)" || ef=""
  if [[ -n "${RD_MODELS_CONFIG:-}" ]]; then
    if [[ -n "$ef" ]]; then sel_out="$(bash "$sel" subagent 2>"$ef")"; sel_rc=$?
    else sel_out="$(bash "$sel" subagent 2>/dev/null)"; sel_rc=$?; fi
  else
    if [[ -n "$ef" ]]; then sel_out="$(RD_MODELS_CONFIG="${project_root}/rd-workflow/config/models.json" bash "$sel" subagent 2>"$ef")"; sel_rc=$?
    else sel_out="$(RD_MODELS_CONFIG="${project_root}/rd-workflow/config/models.json" bash "$sel" subagent 2>/dev/null)"; sel_rc=$?; fi
  fi
  if [[ -n "$ef" ]]; then
    while IFS= read -r _l || [[ -n "$_l" ]]; do
      [[ -n "$_l" ]] || continue
      if [[ -n "$warn" ]]; then warn="${warn} / ${_l}"; else warn="$_l"; fi
    done < "$ef"
    rm -f "$ef"
  fi
fi

cfg_model=""; cfg_effort=""; cfg_line=""
while IFS= read -r _l || [[ -n "$_l" ]]; do
  case "$_l" in
    model=*) cfg_model="${_l#model=}" ;;
    effort=*) cfg_effort="${_l#effort=}" ;;
    "subagent 모델:"*) cfg_line="$_l" ;;
  esac
done <<EOF_SEL
${sel_out}
EOF_SEL

msg="[rd-workflow] subagent 넘긴 값 (${name_label}) — 모델: ${given_model:-넘기지 않음} · effort: ${given_effort:-넘기지 않음}"
if [[ "$sel_rc" == "0" && -n "$cfg_line" ]]; then
  msg="${msg} | 설정: ${cfg_line}"
  if [[ "$given_known" == 1 ]]; then
    if [[ "$given_model" != "$cfg_model" || "$given_effort" != "$cfg_effort" ]]; then
      msg="${msg} | 설정과 다름"
    fi
  fi
else
  msg="${msg} | 설정 확인 실패 (model_select.sh subagent 종료 코드 ${sel_rc})"
fi
[[ -z "$warn" ]] || msg="${msg} | 경고: ${warn}"
msg="$(printf '%s' "$msg" | tr '\r\n' '  ')"

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg m "$msg" '{systemMessage:$m}' 2>/dev/null && exit 0
fi
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$msg" | python3 -c 'import json,sys; sys.stdout.write(json.dumps({"systemMessage": sys.stdin.read()}, ensure_ascii=False) + "\n")' 2>/dev/null && exit 0
fi
esc="$(printf '%s' "$msg" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"systemMessage":"%s"}\n' "$esc"
exit 0
