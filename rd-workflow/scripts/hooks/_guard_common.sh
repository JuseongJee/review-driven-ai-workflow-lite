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

# --- diff-review 세션 (fr-scope 인식 + 종결성) ---

# 현재 작업 short-title (CURRENT_TASK.md ## Short Title 우선, 없으면 lifecycle metadata)
get_current_short_title() {
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
  has_issues="$(awk '/^## Open Issues/{s=1;next} s&&/^## /{exit} s&&/^- /&&!/^- 없음/{print "yes";exit}' "$cp")"
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
  # AS2: CURRENT_TASK.md baseline reset (Status 대기 중 + Short Title -).
  #   표준 atomic archive 는 commit 직전 disk 에서 CURRENT_TASK 를 reset 하므로
  #   commit 호출 방식(commit / commit -a / 단일 Bash add && commit)과 무관하게 잡힌다.
  local _status _short
  _status="$(get_task_status)"
  _short="$(_extract_task_section "Short Title")"
  if [[ "$_status" == "대기 중" && "$_short" == "-" ]]; then
    return 0
  fi
  return 1
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
