#!/usr/bin/env bash
# _guard_common.sh — source 전용, 직접 실행 불가
# 워크플로 guard hook 공통 함수

[[ -z "${project_root:-}" ]] && { echo "[guard] project_root가 설정되지 않았습니다" >&2; exit 1; }

# --- task-state I/O (v2 2b) ---
# _state_common.sh는 project_root 검증 직후 source — $PWD fallback 불사용, project_root 보장 후 진입
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_state_common.sh"

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

# 판정 소스 단일화 (v2 2b): task-state 존재 시 task-state만 읽는다.
# 부재(마이그레이션 전)에만 legacy 산문 파싱 fallback — 어느 시점에도 소스는 정확히 하나.
get_task_status() {
  if state_file_exists; then state_read_field "status"; return 0; fi
  _extract_task_section "Status"
}

# --- diff-review 세션 (fr-scope 인식 + 종결성) ---

# 현재 작업 short-title.
# task-state 존재 시 task-state만 읽는다 (v2 2b).
# 부재 시 legacy 체인(CURRENT_TASK.md → active-fr fallback)을 기존 구현 그대로 보존
# — pre-migration 세계에서 "CURRENT_TASK.md + active-fr 조합"이 하나의 단위이며,
#   task-state 생성 이후에는 이 체인 전체가 도달 불가가 됨.
get_current_short_title() {
  if state_file_exists; then state_read_field "short-title"; return 0; fi
  local st
  st="$(_extract_task_section "Short Title")"
  if [[ -z "$st" || "$st" == "-" ]]; then
    local meta="${project_root}/rd-workflow-workspace/.lifecycle/active-fr"
    [[ -f "$meta" ]] && st="$(awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,"");print;exit}' "$meta")"
  fi
  printf '%s' "$st"
}

# 세션 SESSION.md의 Branch Context short-title 파싱
_session_short_title() {
  local sf="${1}/SESSION.md"
  [[ -f "$sf" ]] || return 0
  awk '/^## Branch Context/{f=1} f&&/^- short-title:/{sub(/^- short-title:[ \t]*/,"");sub(/[ \t]+$/,"");print;exit}' "$sf"
}

# 세션 SESSION.md의 Branch Context fr-branch 파싱
_session_fr_branch() {
  local sf="${1}/SESSION.md"
  [[ -f "$sf" ]] || return 0
  awk '/^## Branch Context/{f=1} f&&/^- fr-branch:/{sub(/^- fr-branch:[ \t]*/,"");sub(/[ \t]+$/,"");print;exit}' "$sf"
}

# 현재 fr 범위의 최신 final-diff-review 세션. 없으면 빈 값.
# short-title 미상(매칭 불가) 세션은 fr-scope 판정 불가로 후보에서 제외(unscoped 통과).
get_latest_diff_review_dir() {
  local base="${1:-${project_root}/rd-workflow-workspace/handoffs/review_pipeline}"
  [[ ! -d "$base" ]] && return
  local want; want="$(get_current_short_title)"
  [[ -z "$want" || "$want" == "-" ]] && return
  local latest="" dir
  for dir in "${base}/"*_final-diff-review; do
    [[ -d "$dir" ]] || continue
    [[ "$(_session_short_title "$dir")" == "$want" ]] || continue
    latest="$dir"
  done
  # 빈 값이어도 return 0 (호출부 review_dir="$(...)" 가 set -e 하에서 죽지 않도록)
  printf '%s' "$latest"
}

# review 종결성.
# 루프 진행 중(awaiting-author/reviewer/claude)=미종결. 루프 종료(awaiting-user/closed)+Open Issues 없음=종결.
# "이슈 없음"은 canonical 마커(- 없음 | - None, 후행 마침표 1개·공백 허용, 라인 전체 매칭)가 최소 1개
# 존재하고 그 외 내용 라인이 없을 때만 인정 (빈 줄·<!-- 시작 단일 라인 주석은 무시).
# 그 외 산문·마커 뒤 후행 텍스트·empty/comment-only 섹션=이슈로 판정(fail-closed).
# 표기 규약: FILE_BASED_REVIEW_PIPELINE.md.
# SESSION/CHECKPOINT/Open Issues 섹션 부재=malformed=미종결(fail-closed, scope 확정 세션 한정).
# return 0 = 종결, 1 = 미종결.
is_review_session_resolved() {
  local sf="${1}/SESSION.md" cp="${1}/CHECKPOINT.md" status=""
  [[ -f "$sf" ]] || return 1
  status="$(awk '$0=="## Status"{f=1;next} f&&/^## /{exit} f&&NF{sub(/^[ \t]+/,"");sub(/[ \t]+$/,"");print;exit}' "$sf")"
  case "$status" in
    awaiting-user|closed) ;;
    *) return 1 ;;
  esac
  [[ -f "$cp" ]] || return 1
  awk '/^## Open Issues/{print "y";exit}' "$cp" | grep -q y || return 1
  local has_issues
  # bad=비허용 내용 라인, m=canonical 마커. 빈 줄·<!-- 시작 주석은 무시.
  # bad 발견 즉시 exit해도 END는 실행되므로 출력은 END 한 곳에서만 한다 (중복 "yes" 방지).
  has_issues="$(awk '/^## Open Issues/{s=1;next} s&&/^## /{exit} !s{next} /^[ \t]*$/{next} /^<!--/{next} /^- (없음|None)\.?[ \t]*$/{m=1;next} {bad=1;exit} END{if(bad||!m)print "yes"}' "$cp")"
  [[ "$has_issues" == "yes" ]] && return 1
  return 0
}

# archive review precheck (3c) — 종결이거나 force-skip이면 진행, 아니면 차단. force-skip 시 audit append.
# fr_branch_ref 가 주어지면 그 ref tip 의 세션을 검증 (merge 전, main 워킹트리 비의존).
# 사용: archive_review_precheck <force_skip 0|1> <reason> <slug> <audit_log> [fr_branch_ref]. return 0=진행, 1=차단.
archive_review_precheck() {
  local force_skip="$1" reason="$2" slug="$3" audit_log="$4" fr_ref="${5:-}"
  local review_dir="" audit_ref="" resolved=1
  if [[ -n "$fr_ref" ]]; then
    local tmp; tmp="$(mktemp -d)"
    # fr tip 의 review_pipeline 서브트리만 temp 로 추출. 추출 실패(경로 부재/corrupt ref/tar 실패)는
    # 전부 "세션 없음"으로 귀결 → fail-closed 차단. 진단보다 안전(미검증 archive 차단)을 우선한다.
    git -C "$project_root" archive "$fr_ref" -- rd-workflow-workspace/handoffs/review_pipeline 2>/dev/null \
      | tar -x -C "$tmp" 2>/dev/null || true
    local fr_base="$tmp/rd-workflow-workspace/handoffs/review_pipeline" _d
    # fr_ref identity 로 후보 고정: SESSION.md Branch Context fr-branch == fr_ref 인 최신 final-diff-review.
    # main 워킹트리(get_current_short_title) 비의존 + stale/unrelated closed 세션 false-positive 방지
    # + suffix(fr/foo-2) 정확 매칭. Branch Context fr-branch 부재(legacy/malformed)는 매칭 실패 → fail-closed.
    for _d in "$fr_base/"*_final-diff-review; do
      [[ -d "$_d" ]] || continue
      [[ "$(_session_fr_branch "$_d")" == "$fr_ref" ]] || continue
      review_dir="$_d"
    done
    if [[ -n "$review_dir" ]] && is_review_session_resolved "$review_dir"; then
      resolved=0
    fi
    # temp 경로는 정리 후 무의미 → audit 은 repo-상대 경로로 정규화.
    [[ -n "$review_dir" ]] && audit_ref="rd-workflow-workspace/handoffs/review_pipeline/$(basename "$review_dir")"
    rm -rf "$tmp"
  else
    review_dir="$(get_latest_diff_review_dir)"
    if [[ -n "$review_dir" ]] && is_review_session_resolved "$review_dir"; then
      resolved=0
    fi
    audit_ref="$review_dir"
  fi
  if [[ "$resolved" -eq 0 ]]; then
    return 0
  fi
  if [[ "$force_skip" != "1" ]]; then
    printf 'archive: review 미종결 (세션 없음 또는 미종결). --force-skip-review-check "<사유>"로만 우회 가능.\n' >&2
    return 1
  fi
  if [[ -z "$reason" ]]; then
    printf 'archive: --force-skip-review-check 사유 필수\n' >&2
    return 1
  fi
  mkdir -p "$(dirname "$audit_log")"
  printf '%s | %s | %s | %s\n' "$(date '+%Y-%m-%d %H:%M')" "$slug" "$reason" "${audit_ref:-<세션없음>}" >> "$audit_log"
  printf 'archive: WARNING — review 검증 우회 (사유: %s). audit log 기록.\n' "$reason" >&2
  return 0
}

# archive/종결 신호 검출 (review-gate-iteration-commit).
# review 미종결 분기에서 사용 — 신호 있으면 차단(B1), 없으면 iteration commit 허용(A1).
# return 0 = archive 신호 있음(차단), 1 = 없음(허용).
commit_has_archive_signal() {
  # AS1: 이번 commit 에 staged 된 request-archive/ 파일 '추가'(--diff-filter=A).
  #   untracked stale 파일·삭제·rename 은 제외 → A1(iteration 허용) 보존.
  if git -C "$project_root" diff --cached --name-only --diff-filter=A 2>/dev/null \
       | grep -qE 'rd-workflow-workspace/backlog/request-archive/'; then
    return 0
  fi
  # AS2: task-state baseline reset (status=대기 중, short-title=-).
  #   표준 atomic archive 는 commit 직전 disk 에서 task-state 를 reset 하므로
  #   commit 호출 방식(commit / commit -a / 단일 Bash add && commit)과 무관하게 잡힌다.
  #   task-state 부재 시 legacy fallback(get_task_status·get_current_short_title)으로 동작.
  local _status _short
  _status="$(get_task_status)"
  _short="$(get_current_short_title)"
  if [[ "$_status" == "대기 중" && "$_short" == "-" ]]; then
    return 0
  fi
  return 1
}

# normalize_lexical_path <path>
# 경로를 lexical 규칙으로 정규화해 출력한다. 이 함수 자체는 파일시스템에 접근하지 않으므로
# symlink 를 해석하지 않는다. 실파일 동일성 판정은 호출측 is_shared_state_file 이 -ef 로
# 별도 수행한다 (change spec §4.2).
#
# 왜 세그먼트 스택인가: 단계별 문자열 처리(중복 '/' 압축 → 선두 './' 제거 → 'x/..' 축약)는
# 단계 간 순서에 의존하고, 한 단계가 만든 새 별칭을 앞 단계로 되돌리지 못한다. 실제로
# 'docs/./..' 는 '.' 제거와 '..' 축약이 서로를 만들어 내서 한 방향 주행으로는 잡히지 않고,
# 연속 선두 '../..' 는 일반 세그먼트처럼 지워져 프로젝트 밖 경로를 오탐 차단한다.
# '/'·'.'·'..' 를 한 번의 주행에서 함께 처리하면 이 계열의 누락이 구조적으로 생기지 않는다.
#
# 절대/상대 처리가 다르다:
#   절대 경로 — 루트 위로 올라갈 수 없다 ('/..' == '/'). 남는 '..' 는 버린다.
#   상대 경로 — 소진할 수 없는 선두 '..' 는 보존한다. 지우면 프로젝트 밖을 가리키는 표현이
#              프로젝트 안 경로로 바뀌어 오탐이 된다.
#
# bash 3.2 제약: 배열 push/pop 대신 '/' 로 join 한 문자열을 스택으로 쓴다.
normalize_lexical_path() {
  local path="$1"
  local abs=0
  case "$path" in /*) abs=1 ;; esac
  local stack="" lead="" seg rest="$path"
  while [[ -n "$rest" ]]; do
    seg="${rest%%/*}"
    if [[ "$seg" == "$rest" ]]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      ''|.)
        # 빈 세그먼트(중복 '/')와 '.' 는 버린다
        ;;
      ..)
        if [[ -n "$stack" ]]; then
          if [[ "$stack" == */* ]]; then stack="${stack%/*}"; else stack=""; fi
        elif [[ $abs -eq 1 ]]; then
          : # 루트 위로는 올라갈 수 없다
        else
          if [[ -n "$lead" ]]; then lead="${lead}/.."; else lead=".."; fi
        fi
        ;;
      *)
        if [[ -n "$stack" ]]; then stack="${stack}/${seg}"; else stack="$seg"; fi
        ;;
    esac
  done
  if [[ $abs -eq 1 ]]; then
    printf '/%s' "$stack"
  elif [[ -n "$lead" && -n "$stack" ]]; then
    printf '%s/%s' "$lead" "$stack"
  elif [[ -n "$lead" ]]; then
    printf '%s' "$lead"
  else
    printf '%s' "$stack"
  fi
}

# is_shared_state_file <filepath>
# orchestrator(메인 세션) 전용 공유 진행 상태 파일인지 판정합니다. return 0 = 그렇습니다.
# 이 hook 에 남은 유일한 판정 집합입니다 — "주체 게이트에서 막을 파일".
# 집합을 진행 상태 3종으로 좁게 유지합니다. spec/plan/report 는 단일 작성자 산출물이라
# 경합 대상이 아니고, SESSION.md/CHECKPOINT.md/turns 는 외부 CLI 프로세스가 작성해
# 최상위 판별 필드(agent_type, 없으면 agent_id)가 없으므로 넣어도 무효입니다.
#
# 왜 정규화가 필요한가: 원시 문자열 매칭은 '<root>/../<basename>/x' 처럼 벗어난 뒤
# 되돌아오는 경로를 놓친다(2026-08-17). 이 판정은 블랙리스트라 미매칭이 "통과" 이므로,
# 아래 ② 의 -ef 보조 판정으로 lexical 정규화가 놓치는 별칭까지 함께 막는다.
# 대상 경로와 project_root 를 **둘 다** 정규화한다 — project_root 쪽만 원시 문자열로 두면
# '<root>/../<basename>/x' 처럼 벗어난 뒤 되돌아오는 경로를 놓친다.
# 판정 대상은 이름이 아니라 파일이다 — 정규화 문자열 일치(①)와 실파일 동일성(②) 둘 다
# return 0 이다. 비지원으로 남는 것은 ② 의 대상이 아직 존재하지 않는 경우다.
is_shared_state_file() {
  local rel norm root_norm cand
  norm="$(normalize_lexical_path "$1")"
  case "$norm" in
    /*)
      root_norm="$(normalize_lexical_path "$project_root")"
      if [[ "$norm" == "${root_norm}/"* ]]; then
        rel="${norm#"${root_norm}/"}"
      else
        # 프로젝트 밖 절대 경로 — 이 게이트의 대상이 아니다
        return 1
      fi
      ;;
    *)
      # 상대 경로. 선두 '..' 가 보존되어 있으면 아래 case 에 매칭되지 않아 통과한다.
      rel="$norm"
      ;;
  esac

  # ① lexical 정확 일치. 파일이 아직 없어도(생성 전) 판정된다.
  case "$rel" in
    CURRENT_TASK.md|REQUEST.md) return 0 ;;
    rd-workflow-workspace/.lifecycle/task-state) return 0 ;;
  esac

  # ② 실파일 동일성 보조 판정.
  # macOS 기본 볼륨은 대소문자를 구분하지 않으므로 'current_task.md' 가 정본과 **같은 실파일**
  # 을 가리킨다(실측 확인). ① 의 정확 문자열 비교로는 통과하므로 여기서 잡는다.
  # -ef 는 device+inode 비교이며 bash builtin 이라 외부 명령이 늘지 않는다.
  # "그 볼륨에서 실제로 같은 파일일 때만" 차단하므로 case-sensitive 볼륨에서는
  # 소문자 파일이 별개이거나 부재여서 오탐이 생기지 않는다 — 모든 플랫폼에서 세 이름을
  # case-insensitive 예약하는 방식보다 오탐이 없다(change spec §4.2).
  # 부수 효과: 차단 집합 3종을 가리키는 symlink·hardlink 도 함께 잡힌다.
  # 한계: 양쪽 경로가 실제로 존재할 때만 참이다. task-state 가 아직 없는 마이그레이션 전
  #       상태에서는 그 파일의 case alias 를 잡지 못한다(정본 이름은 ① 이 계속 잡는다).
  #       또 절대 경로가 project_root 접두와 불일치하면 ② 에 도달하기 전에 return 1 이므로,
  #       루트를 심링크 경유 절대 경로로 지칭하면(예: /tmp/proj-link/CURRENT_TASK.md)
  #       같은 실파일이어도 차단되지 않는다. 기존 :33 의 밖 경로 통과와 같은 경계다.
  for cand in CURRENT_TASK.md REQUEST.md rd-workflow-workspace/.lifecycle/task-state; do
    if [[ "${project_root}/${rel}" -ef "${project_root}/${cand}" ]]; then
      return 0
    fi
  done
  return 1
}

# --- Stop hook 전용 헬퍼 ---

# is_nonblocking_status <status>
# 비차단 집합 단일 출처. CLAUDE.md 'CURRENT_TASK.md 허용 상태값' 참조.
# 인자가 빈값 / '대기 중' / '완료'면 return 0 (비차단=통과 대상), 아니면 return 1 (진행 중=차단 대상).
is_nonblocking_status() {
  local s="$1"
  case "$s" in
    ""|"대기 중"|"완료") return 0 ;;
    *) return 1 ;;
  esac
}

# read_hook_agent_id
# _hook_input(read_hook_input이 채운 전역)에서 subagent 판별 마커를 읽어 출력합니다.
# 값이 비어 있지 않으면 subagent 안에서 발동한 hook 입니다.
#
# 두 필드 중 **먼저 비어 있지 않은 값**을 씁니다 (agent_type 우선, agent_id 폴백).
#   agent_type — 이 버전(Claude Code 2.1.228)이 실제로 보내는 필드입니다. subagent 입력에만
#                존재하고(예: "general-purpose") 메인 세션 입력에는 없음을 hook 입력 덤프로
#                실측했습니다. 메인 세션에는 대신 prompt_id·effort 가 옵니다.
#   agent_id   — 공식 문서가 기술하는 필드입니다. 실측한 버전의 입력에는 없었으나 upstream 이
#                추가하거나 다른 배포 형태에서 보낼 수 있으므로 함께 봅니다.
# "먼저 비어 있지 않은 값" 이 계약인 이유: agent_type 이 빈 문자열이고 agent_id 만 값을 가진
# 입력에서 한쪽 경로만 빈 값을 반환하면 같은 입력이 모드에 따라 다르게 판정된다.
# jq 필터와 awk 폴백이 이 규칙을 똑같이 구현해야 한다.
#
# **반드시 최상위만 봅니다.** tool_input 하위에 같은 이름의 필드가 있어도 판별에 쓰면
# 메인 세션이 subagent 로 오인되어 자기 진행 상태를 쓸 수 없게 됩니다(과잉 차단).
# 부재 시 빈 문자열 — 호출측은 메인 스레드로 간주합니다 (fail-open).
# extract_json_field 는 .tool_input. 하위만 보므로 이 필드들에 쓸 수 없습니다.
read_hook_agent_id() {
  local val=""
  if command -v jq &>/dev/null; then
    # jq 실행이 성공하면 그 결과가 곧 답이다. 최상위에 없으면 빈 값이 정답이므로
    # 여기서 폴백으로 넘어가면 안 된다 — 넘어가면 중첩 필드를 최상위로 오인한다.
    if val="$(printf '%s' "$_hook_input" | jq -r \
        '[.agent_type?, .agent_id?] | map(select(type == "string" and . != "")) | (.[0] // "")' \
        2>/dev/null)"; then
      printf '%s' "$val"
      return 0
    fi
    val=""
  fi
  # awk 폴백 — jq 부재 또는 jq 실행 실패 시에만 온다.
  #
  # 왜 awk 인가: 앞선 구현은 bash 로 문자 하나씩 훑었는데, bash 3.2 의 ${s:i:1} 은 호출마다
  # 문자열 전체를 다시 훑으므로 사실상 제곱 시간이다. 판별 필드가 없는 메인 세션 입력은
  # 끝까지 순회하므로 tool_input.content 가 큰 평범한 Write 마다 지연이 사용자에게 보였다
  # (실측: 10KB 1.2초, 20KB 4.8초). awk 는 같은 입력을 선형으로 처리한다 (1MB 0.09초).
  #
  # 파싱 전략: RS 를 큰따옴표로 두어 입력을 "문자열 밖 / 문자열 안" 레코드로 번갈아 자른다.
  # 큰 content 는 통째로 한 레코드가 되어 문자 단위 검사를 아예 받지 않는다. 문자열 밖
  # 레코드만 짧게 검사해 중괄호/대괄호 개수로 깊이를 세고(gsub 반환값 = 치환 횟수),
  # 첫 비공백 문자가 ':' 인지로 직전 문자열이 키였는지 값이었는지를 가른다 —
  # 이 판정이 space·tab·CR·LF 를 모두 공백으로 처리하므로 pretty-printed 입력도 같다.
  # 닫는 따옴표가 escape 된 것인지는 레코드 끝 역슬래시 개수의 홀짝으로 판정한다.
  printf '%s\n' "$_hook_input" | awk '
    BEGIN { RS = "\""; depth = 0; instr = 0; cur = ""; have = 0; last = ""; key = ""; vt = ""; vi = "" }
    {
      r = $0
      if (instr) {
        if (depth == 1) cur = cur r
        esc = 0
        i = length(r)
        while (i > 0 && substr(r, i, 1) == "\\") { esc = 1 - esc; i-- }
        if (esc) {
          if (depth == 1) cur = cur "\""
        } else {
          instr = 0
          if (depth == 1) { last = cur; have = 1 }
        }
        next
      }
      s = r
      sub(/^[ \t\r\n]+/, "", s)
      first = substr(s, 1, 1)
      if (have) {
        if (first == ":") key = last
        else {
          if (last != "") {
            if (key == "agent_type" && vt == "") vt = last
            else if (key == "agent_id" && vi == "") vi = last
          }
          key = ""
        }
        have = 0
      } else if (first != ":") key = ""
      depth += gsub(/[{[]/, "", s)
      depth -= gsub(/[}\]]/, "", s)
      instr = 1
      cur = ""
    }
    END { printf "%s", (vt != "" ? vt : vi) }
  '
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

# --- commit scan 계약 (guard-hook-commit-target-scope) ---
# 이 아래는 커밋 판정 스캐너의 bash 계약이다. 위쪽 기존 함수와 독립적이며,
# 성능 테스트가 이 마커를 경계로 변경 전 상태를 재구성한다. 마커를 지우지 말 것.

_commit_scan_awk() { printf '%s/_commit_scan.awk' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; }

# 실행 위치의 git commit 호출을 **모두** 집계한다.
# 인자 : $1=명령 문자열, $2=시작 디렉토리(생략 시 project_root)
# stdout: 1행  gate=<0|1> uncertain=<0|1> ncand=<N>
#         2..N+1행  차단 후보 커밋의 실행 위치 절대경로
# 반환  : 0 판정 성공 / 2 판정 불가(호출측이 현행 문자열 판정으로 폴백)
#
# 명령 하나에 커밋이 여러 개일 수 있다. 첫 커밋만 보면
# `git -C <밖> commit; git commit` 의 두 번째 커밋이 통과해버리므로 끝까지 집계한다.
scan_command_commit() {
  local cmd="$1" start="${2:-${project_root}}" awkf out rc head
  awkf="$(_commit_scan_awk)"
  [[ -f "$awkf" ]] || return 2
  command -v awk >/dev/null 2>&1 || return 2
  out="$(printf '%s' "$cmd" | awk -v start_dir="$start" -f "$awkf" 2>/dev/null)"; rc=$?
  [[ $rc -eq 0 ]] || return 2
  # 계약 형식 검증 — malformed 출력은 판정 불가로 취급
  head="${out%%$'\n'*}"
  [[ "$head" =~ ^gate=[01][[:space:]]uncertain=[01][[:space:]]ncand=[0-9]+$ ]] || return 2
  printf '%s\n' "$out"
}

# 현행(폴백) 문자열 판정 — 스캐너를 쓸 수 없을 때만 사용한다.
# 제거된 fr_branch_gate 가 자기 경계 정규식을 폴백으로 쓰던 자리라 이 함수는 쓰지 않습니다.
_legacy_commit_glob() {
  local cmd="$1"
  [[ "$cmd" == *git\ *commit* || "$cmd" == *git$'\t'*commit* || "$cmd" == git\ commit* ]]
}

# target 이 세션 프로젝트 밖임이 **보장**되는가 (0 = 밖 확정 → 그 커밋은 판정 생략 가능)
# 조건: 리터럴 확정 + 실재하는 디렉토리 + 물리 경로 해석 후에도 프로젝트 밖
commit_target_is_outside() {
  local t="$1" phys pr
  [[ -n "$t" && "$t" != "?" && "$t" != "-" ]] || return 1
  [[ -d "$t" ]] || return 1
  phys="$(cd -P "$t" 2>/dev/null && pwd -P)" || return 1
  pr="$(cd -P "${project_root}" 2>/dev/null && pwd -P)" || return 1
  [[ "${phys}/" == "${pr}/"* ]] && return 1
  return 0
}

# 스캔 결과를 보수적으로 해석한다. 0 = 이 프로젝트의 gate 로 판정해야 함.
# 인자 : $1=스캐너 출력(여러 줄), $2=hook 이름(진단용)
# 정책 : ① 차단 후보가 없으면(커밋 없음 또는 전부 유효 bypass) 판정 불필요
#        ② 후보 중 위치 불확실이 있으면 무조건 판정 (fail-closed)
#        ③ 위치가 확정된 후보는 **전부 밖일 때만** 생략. 하나라도 안이면 판정
_gate_from_scan() {
  local out="$1" hook="$2" head gate unc ncand t inside=0 seen=0
  head="${out%%$'\n'*}"
  gate="${head#gate=}";      gate="${gate%% *}"
  unc="${head#*uncertain=}"; unc="${unc%% *}"
  ncand="${head##*ncand=}"
  [[ "$gate" == 1 ]] || return 1
  if [[ "$unc" == 1 ]]; then
    printf '[%s] 대상 디렉토리를 확정할 수 없어 세션 프로젝트 기준으로 판정합니다.\n' "$hook" >&2
    return 0
  fi
  [[ "$ncand" -gt 0 ]] || return 0     # gate=1 인데 후보 목록이 비면 fail-closed
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    seen=$((seen + 1))
    commit_target_is_outside "$t" || { inside=1; break; }
  done <<< "${out#*$'\n'}"
  if [[ $inside -eq 0 && $seen -eq "$ncand" ]]; then
    printf '[%s] 판정 생략 — 커밋 %d건 모두 세션 프로젝트 밖입니다. 이 커밋들은 이 프로젝트의 gate 로 검사되지 않습니다.\n' \
      "$hook" "$ncand" >&2
    return 1
  fi
  return 0
}

# 이 명령이 "우리 프로젝트를 대상으로" 실제 커밋을 하는가 (0 = 그렇다)
# 두 gate(review·archive)가 소비한다. 집계·대상 판정을 흡수하므로 호출측은 참·거짓만 본다.
command_targets_our_commit() {
  local cmd="$1" hook="${2:-guard}" out probe
  # 1단 필터 — 인용·백슬래시를 걷어낸 뒤 검사한다. `git com'mit'` 처럼 쪼개면
  # `commit` 연속 부분 문자열이 사라지므로 그냥 검사하면 차단 대상을 놓친다.
  # 과탐은 무해하다 (최종 판정은 스캐너가 한다).
  # `\<개행>`(line continuation)을 먼저 제거한다 — 백슬래시만 지우면 개행이 남아
  # `com<개행>mit` 이 되고 `commit` 부분 문자열이 만들어지지 않는다(F12 실측).
  # `$'…'`(ANSI-C 인용)는 escape 로 문자를 만들 수 있어(`$'com\x6dit'`) 문자열 제거만으로는
  # `commit` 을 복원하지 못한다. 있으면 무조건 스캐너로 보낸다 — 여기서의 과탐은 무해하다.
  probe="${cmd//\\$'\n'/}"; probe="${probe//\'/}"; probe="${probe//\"/}"; probe="${probe//\\/}"
  [[ "$probe" == *commit* || "$cmd" == *\$\'* ]] || return 1
  if ! out="$(scan_command_commit "$cmd")"; then
    printf '[%s] 스캐너 폴백(scan-unavailable) — 문자열 판정으로 처리합니다.\n' "$hook" >&2
    _legacy_commit_glob "$cmd" && return 0
    return 1
  fi
  _gate_from_scan "$out" "$hook"
}
