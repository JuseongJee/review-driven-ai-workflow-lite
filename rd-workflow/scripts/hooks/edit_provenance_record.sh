#!/usr/bin/env bash
# edit_provenance_record.sh — Claude Code PostToolUse(matcher: Edit|Write) hook.
# 편집 출처(orchestrator / subagent)와 편집 직후 상태 식별자를 기록하는 producer 입니다.
# 기록을 읽어 판정하는 consumer 는 stop_task_save_reminder.sh 이며,
# 두 쪽 모두 rd-workflow/scripts/_edit_provenance_common.sh 의 헬퍼만 씁니다.
#
# 계약 문서:
#   rd-workflow-workspace/specs/changes/2026-08-13-2110-stop-hook-stale-nudge-during-parallel-phase-change-spec.md
#   §2.4 세대 규칙 / §2.4.1 bump 권한 / §2.6 T23 교차 검증 / §2.7 항상-0 종료 / §2.8 상한
#
# **이 hook 은 절대 차단하지 않습니다** — 어떤 실패에서도 exit 0 이고 stdout·stderr 가 비어 있습니다.
# 외곽에 set -e / set -u 를 켜지 않습니다 (§2.7): 본체를 함수로 묶어 subshell 에서 실행하면
# nounset 치명 오류·source 실패가 subshell 만 종료시키고, 출력을 버려 hook 오류가 사용자에게
# 노출되지 않습니다. 마지막 줄의 exit 0 만으로는 조기 종료를 흡수할 수 없습니다.
#
# hook 경로에 python3·flock 을 쓰지 않습니다 — 기동 비용(실측 19.4~30ms)만으로 증분 상한(20ms)을
# 넘기고, 쓰기가 전부 단일 원자 연산(mkdir / mktemp→mv)이라 잠금이 필요 없습니다.
#
# bash 3.2 호환: 연관배열·globstar·extglob·mapfile 을 쓰지 않습니다.

# --- 내부 유틸 -------------------------------------------------------------

# _ep_is_uint <값> — 10진 음이 아닌 정수면 return 0. jq 가 -1 로 표시한 '필드 없음' 을 배제합니다.
_ep_is_uint() {
  case "${1-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# _ep_relpath <file_path> <project_root> — project_root 기준 상대 경로를 출력합니다.
# 프로젝트 밖(접두 불일치 · 소진되지 않은 선두 '..')이면 빈 출력 + return 1 입니다.
#
# 왜 정규화가 필요한가: consumer 는 `git ls-files` 출력 문자열로 pathkey 를 만들므로 producer 가
# **같은 문자열**을 만들어야 두 쪽 키가 일치합니다. 중복 '/'·'.'·'..' 가 섞인 표기를 그대로 쓰면
# 같은 파일이 다른 키로 기록되어 그 편집이 영원히 미설명으로 남습니다.
# _guard_common.sh 의 normalize_lexical_path 를 재사용합니다 (중복 구현 금지).
#
# 상대 경로 입력은 project_root 기준으로 해석합니다 — 실측 payload 의 file_path 는 항상 절대
# 경로이고(선행 실증 report 3항), Claude Code 의 cwd 는 project_root 이므로 이 해석이 안전합니다.
_ep_relpath() {
  local p="${1-}" root="${2-}" norm root_norm rel
  [[ -n "$p" ]] || return 1
  norm="$(normalize_lexical_path "$p")"
  case "$norm" in
    /*)
      root_norm="$(normalize_lexical_path "$root")"
      [[ "$norm" == "${root_norm}/"* ]] || return 1
      rel="${norm#"${root_norm}/"}"
      ;;
    *)
      rel="$norm"
      case "$rel" in ''|..|../*) return 1 ;; esac
      ;;
  esac
  [[ -n "$rel" ]] || return 1
  printf '%s' "$rel"
}

# _ep_t23_meta — T23 교차 검증에 필요한 payload 메타를 **jq 1회 호출**로 뽑습니다 (§2.6).
# 출력 형식(TAB 6필드): <tool_name> <replaceAll> <content> <originalFile> <oldString> <newString>
#   - tool_name  : 문자열이 아니거나 빈 값이면 '-' (Write·Edit 어디에도 걸리지 않아 검증 생략)
#   - replaceAll : 'true' 또는 'false'
#   - 나머지 4필드: 그 필드의 **바이트 길이**(utf8bytelength). 문자열이 아니면(null·부재) -1
#
# 왜 tool_name 을 같은 호출에 싣는가: 최상위 tool_name 은 extract_json_field(.tool_input. 하위
# 전용)로 읽을 수 없고, 편집 본문에 같은 이름의 문자열이 섞일 수 있어 bash 문자열 스캔으로
# 대체하면 오판정이 생깁니다. 한 호출에 묶으면 jq 기동이 Write 2회 / Edit 1회로 줄어
# 증분 상한(AC10 20ms) 여유가 커집니다.
#
# **빈 필드를 만들지 않는 이유**: IFS=TAB 의 read 는 TAB 이 IFS 공백 문자라 연속 구분자를
# 하나로 접습니다. 빈 필드가 생기면 뒤 필드가 앞으로 밀려 값이 어긋나므로 모든 필드를
# 항상 비어 있지 않게 냅니다.
# .tool_response 가 객체가 아니면(문자열 등) jq 가 non-zero 로 끝나고 호출측은 검증을 생략합니다.
_ep_t23_meta() {
  printf '%s' "$_hook_input" | jq -r '
    def blen: if type == "string" then utf8bytelength else -1 end;
    [ (if (.tool_name | type) == "string" and .tool_name != "" then .tool_name else "-" end),
      (if (.tool_response.replaceAll == true) then "true" else "false" end),
      (.tool_response.content      | blen),
      (.tool_response.originalFile | blen),
      (.tool_response.oldString    | blen),
      (.tool_response.newString    | blen)
    ] | @tsv' 2>/dev/null
}

# _ep_t23_keep <state_id> <abs> — 귀속 교차 검증 (§2.6).
# return 0 = actor 유지(검증 통과 **또는 검증 생략**) / 1 = 강등(payload 와 실파일 불일치 확정).
#
# **검증 생략 시 강등하지 않습니다.** 강등하면 subagent 의 정상 편집이 .orc 로 남아 block 되고,
# 그것은 이 작업의 본래 목표(T2·AC1 — 병렬 phase 에서 넛지가 매 턴 뜨는 문제 해소)를 깨뜨립니다.
# 생략 갈래: jq 부재 / jq non-zero / 대상 필드가 null·부재 / replaceAll=true / Write·Edit 이외 도구.
#
# **jq bash 폴백을 만들지 않습니다.** jq 없이 JSON 문자열을 바이트 정확히 디코드하는 폴백은
# 신뢰할 수 없고, 부정확한 폴백은 정상 편집을 강등해 같은 목표를 깨뜨립니다. jq 부재는
# 검증 생략 + self_test 진단으로 처리합니다.
_ep_t23_keep() {
  local sid="${1-}" abs="${2-}" meta tname rall clen olen slen nlen expect fsize got
  command -v jq >/dev/null 2>&1 || return 0
  meta="$(_ep_t23_meta)" || return 0
  [[ -n "$meta" ]] || return 0
  IFS=$'\t' read -r tname rall clen olen slen nlen <<< "$meta"
  case "$tname" in
    Write)
      _ep_is_uint "$clen" || return 0
      # **셸 변수 왕복 금지** (§2.6 Finding 4) — 디코딩된 내용을 변수에 담으면 command
      # substitution 이 종단 개행을 지우고 ${#var} 가 locale 에 따라 문자 수를 세어, 정상적인
      # 줄바꿈·비ASCII 파일이 .orc 로 강등됩니다. payload → jq → 파이프 → cksum 스트림만 씁니다.
      # 숫자만 담은 '<checksum>-<length>' 결과를 변수로 받는 것은 무해합니다.
      # pipefail 이 켜져 있어 jq 실패는 이 대입 자체를 non-zero 로 만들고 → 검증 생략입니다.
      got="$(printf '%s' "$_hook_input" | jq -j '.tool_response.content' 2>/dev/null | ep_state_id_stdin)" || return 0
      [[ -n "$got" ]] || return 0
      [[ "$got" == "$sid" ]] || return 1
      ;;
    Edit)
      # replaceAll=true 는 치환 횟수를 payload 로 확정할 수 없어 검증 대상이 아닙니다.
      [[ "$rall" == "false" ]] || return 0
      _ep_is_uint "$olen" && _ep_is_uint "$slen" && _ep_is_uint "$nlen" || return 0
      # 기대 크기 = originalFile − oldString + newString (바이트). 크기가 바뀌는 외부 쓰기를 잡습니다.
      expect=$((olen - slen + nlen))
      fsize="$(stat -f %z "$abs" 2>/dev/null || stat -c %s "$abs" 2>/dev/null || true)"
      _ep_is_uint "$fsize" || return 0
      [[ "$fsize" -eq "$expect" ]] || return 1
      ;;
  esac
  return 0
}

# --- 본체 -----------------------------------------------------------------

_ep_main() {
  set -uo pipefail
  local script_dir project_root guard ep_lib
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
  project_root="$(cd "${script_dir}/../../.." 2>/dev/null && pwd)" || return 1
  guard="${script_dir}/_guard_common.sh"
  ep_lib="${script_dir}/../_edit_provenance_common.sh"
  # 부분 install 내성 — 어느 한쪽이 없으면 아무것도 하지 않고 조용히 끝냅니다.
  [[ -f "$guard" && -f "$ep_lib" ]] || return 1
  # shellcheck source=/dev/null
  source "$guard" || return 1        # read_hook_input / read_hook_agent_id / extract_json_field
  # ep_* 헬퍼 (중복 구현 금지). **_guard_common.sh 가 같은 경로의 같은 파일을 이미 source 합니다**
  # (그쪽 부분 install 내성 블록). 무조건 다시 source 하면 366줄을 편집마다 두 번 파싱하는
  # 순수 낭비가 hot path 에 남으므로, **정의되지 않았을 때만** 직접 source 합니다.
  # 부분 install 내성(AC5(f))은 위 -f 검사와 아래 declare -f 검사가 그대로 담당합니다 —
  # 헬퍼가 구문 오류면 앞선 source 가 실패해 함수가 정의되지 않고, 여기서 다시 시도해도
  # 같은 이유로 실패하므로 아래 검사에서 걸려 기록 없이 종료합니다.
  # shellcheck source=/dev/null
  declare -f ep_current_gen >/dev/null 2>&1 || source "$ep_lib" || return 1
  declare -f ep_current_gen >/dev/null 2>&1 || return 1

  # 1. payload
  read_hook_input

  # 2·3. 대상 경로 — 비었거나 프로젝트 밖이면 종료
  local fp rel
  fp="$(extract_json_field file_path)" || fp=""
  [[ -n "$fp" ]] || return 0
  rel="$(_ep_relpath "$fp" "$project_root")" || return 0
  [[ -n "$rel" ]] || return 0

  # 4. 기준선 저장 — **CURRENT_TASK.md 편집만 세대를 올립니다** (§2.4.1). 레코드는 남기지 않습니다.
  #    bump 반환값으로 자신을 실패시키지 않습니다 (§2.4 반환 계약) — 실패해도 판정은 이전 세대를
  #    계속 쓰고 그 방향은 fail-closed 입니다.
  if [[ "$rel" == "CURRENT_TASK.md" ]]; then
    ep_bump "$(get_current_short_title)" || true
    return 0
  fi

  # 5. 판정 제외 대상 (consumer 가 후보에서 빼는 집합과 같아야 합니다)
  case "$rel" in
    rd-workflow-workspace/*) return 0 ;;
  esac

  # 6. 행위자 — 최상위 판별 필드가 비어 있지 않으면 subagent 입니다.
  #    read_hook_agent_id 가 'agent_type 우선 / agent_id 폴백' 계약을 단독으로 소유하므로
  #    여기서 필드를 다시 해석하지 않습니다 (선행 실증 report 1항).
  local actor="orc"
  [[ -n "$(read_hook_agent_id)" ]] && actor="sub"

  # 7. 현재 세대 확보 — **일반 편집은 절대 bump 하지 않습니다** (§2.4.1).
  #    판정 순서: ① 포인터 실패(부재) → ② 센티널 → ③ 메타 손상 → ④ 통과.
  #    ②를 ③보다 먼저 두어야 '센티널' 과 '메타 손상' 이 구분됩니다(진단 문구가 달라집니다).
  #
  #    ① 센티널(.overflow) 세대에서 bump 하면 "기록 중단 + 다음 저장까지 block 유지" 계약이
  #       깨집니다 — 깨끗한 새 세대가 생겨 그 편집이 .sub 로 남아 통과해버립니다.
  #    ② 세대 부재에서도 부트스트랩하지 않습니다: producer 는 "최초 설치" 와 "센티널 세대가
  #       외부 요인으로 사라진 상태" 를 구별할 수 없습니다. 첫 기준선 저장 전에는 기존 stale
  #       동작이 유지되며, 이 워크플로는 병렬 dispatch 전에 항상 저장을 거치므로 실질 손실이
  #       없습니다.
  local gen want_title
  gen="$(ep_current_gen 2>/dev/null)" || return 0
  [[ -n "$gen" ]] || return 0
  ep_gen_has_sentinel "$gen" && return 0
  want_title="$(get_current_short_title)"
  ep_gen_valid "$gen" "$want_title" || return 0

  # 8. 편집 직후 상태 식별자
  local abs sid
  abs="${project_root}/${rel}"
  sid="$(ep_state_id "$abs" 2>/dev/null)" || return 0
  [[ -n "$sid" ]] || return 0

  # 9. T23 — 귀속 교차 검증. 불일치가 확정되면 .orc 로 강등합니다(block 방향).
  if [[ "$actor" == "sub" ]]; then
    _ep_t23_keep "$sid" "$abs" || actor="orc"
  fi

  # 10·11. 기록 + 상한. 상한 카운트는 **새 레코드 파일을 만들 때만** 수행합니다 (§2.8 성능) —
  #        같은 경로·같은 행위자의 재편집은 덮어쓰기라 디렉토리 항목이 늘지 않습니다.
  #        pathkey 계산이 실패하면(사실상 불가) 카운트를 건너뜁니다 — 상한은 정확성 장치가
  #        아니라 누적 방지 장치이므로 기록을 막지 않습니다.
  local pk is_new=0
  pk="$(ep_pathkey "$rel" 2>/dev/null)" || pk=""
  [[ -n "$pk" && ! -e "${gen}/${pk}.${actor}" ]] && is_new=1
  ep_record "$gen" "$actor" "$rel" "$sid" || return 0
  [[ "$is_new" -eq 1 ]] && ep_cap "$gen"
  return 0
}

( _ep_main ) >/dev/null 2>&1
exit 0
