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

# --- 아카이브 전 검증 강제 (change spec §5.5 / 청중 경계: consumer 집합) -----------
#
# 축소 실행(smoke)이 구문 검사를 변경 파일로 좁히면서 **미변경 스크립트의 구문 오류를 놓치게**
# 됐고, 그 대가를 통합 직전에 상환하는 것이 이 검증입니다 (강제 범위는 consumer 청중). 커밋 전 게이트에는 사용자 승인
# 우회 밸브가 있고 이 저장소는 인프라 커밋이 대부분이라 그 밸브가 상시 쓰입니다 —
# **여기에는 우회 밸브를 두지 않습니다.** 편의를 위한 예외를 하나라도 만드는 순간 축소 실행의
# 검출력 손실이 상환되지 않고 순손실로 남습니다.
#
# **신뢰 모델**: 이 장치는 정직한 실수를 막습니다. 증명 파일은 서명 없는 로컬 평문이라 직접
# 조작하면 통과시킬 수 있고, 그것은 범위 밖입니다(사용자 결정, change spec §5.5).
# "우회가 없다" 는 **사유 한 줄로 여는 밸브를 제공하지 않는다**는 뜻입니다.

# 증명 헬퍼 로더 — 부재·손상·부분 정의를 "확인 불가" 한 갈래로 수렴시킵니다. return 0 = 사용 가능.
# 사용: _archive_selftest_helper_load <root> [quiet]. quiet 이면 사유를 내지 않습니다
# (한 흐름에서 두 번 읽을 때 같은 사유가 두 번 찍히는 것을 막습니다).
#
# 대상 root 에서 **매번 다시 읽습니다.** 이미 정의돼 있으면 넘어가는 방식은 다른 root 에서
# 들어온 정의를 그대로 쓰게 되어, 이 게이트가 막으려는 "두 판정이 갈리는" 상황을 스스로 만듭니다.
# 구문 오류가 있는 파일을 source 하면 파서가 셸 자체를 종료시킵니다(호출자는 set -euo pipefail).
# 그 지점은 merge 직후라 여기서 죽으면 사용자는 아무 안내 없이 반쯤 진행된 상태를 받습니다.
# 아카이브는 작업당 1회라 fork 한 번으로 막습니다 (같은 판단의 선례가 아카이브 스크립트 안에 있습니다).
_archive_selftest_helper_load() {
  local root="$1" quiet="${2:-}" fn
  local helper="$root/rd-workflow/scripts/_smoke_common.sh"
  if [[ ! -f "$helper" ]]; then
    [[ -n "$quiet" ]] || printf 'archive: 검증 증명 헬퍼가 없습니다: %s\n' "$helper" >&2
    return 1
  fi
  if ! bash -n "$helper" 2>/dev/null; then
    [[ -n "$quiet" ]] || printf 'archive: 검증 증명 헬퍼에 구문 오류가 있습니다: %s\n' "$helper" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$helper"
  for fn in smoke_cache_valid smoke_untracked_state smoke_proof_exclude; do
    if ! declare -f "$fn" >/dev/null 2>&1; then
      [[ -n "$quiet" ]] || printf 'archive: 증명 판정 함수(%s)가 정의되지 않았습니다 — 헬퍼 손상 의심\n' "$fn" >&2
      return 1
    fi
  done
  return 0
}

# 지금 워킹트리 내용으로 검증을 통과한 기록이 있는지 확인합니다 (full 또는 consumer 증명).
# 사용: archive_selftest_precheck <project_root>. return 0=진행, 1=차단.
#
# 판정은 커밋 전 게이트와 **같은 함수**에 위임합니다. 지문 대조와 untracked 검사를 여기서
# 다시 짜면 두 판정이 갈리는 순간 한쪽만 막는 구멍이 생기고, 안전망이 거짓말을 하게 됩니다.
# mode 는 리터럴 `worktree` 입니다 — 아카이브 대상은 index 가 아니라 워킹트리 자체이므로
# 지문과 untracked 를 함께 봐야 합니다.
archive_selftest_precheck() {
  local root="$1"
  if ! _archive_selftest_helper_load "$root"; then
    printf 'archive: 검증 통과 기록을 확인할 수 없어 차단합니다\n' >&2
    return 1
  fi
  # **`archive-gate 판정`** — full 증명 **또는** consumer 증명 중 현재 지문과 일치하는 것을
  # 인정합니다. `full` 은 `consumer` 의 상위 집합이므로 인정하고, 반대는 인정하지 않습니다.
  # 전수 통과를 요구하는 코드는 `smoke_cache_valid`(= `full-only 판정`)를 직접 호출해야 합니다.
  #
  # 헬퍼가 옛 버전이면 이 함수가 없을 수 있으므로 `full-only 판정` 으로 되돌립니다 —
  # 더 좁은 쪽(= 더 엄격한 쪽)이므로 폴백이 게이트를 약화시키지 않습니다.
  if declare -F smoke_archive_gate_valid >/dev/null 2>&1; then
    if ! smoke_archive_gate_valid "$root" worktree; then
      printf 'archive: 검증 증명이 유효하지 않습니다 (위 사유 참조)\n' >&2
      return 1
    fi
  elif ! smoke_cache_valid "$root" worktree; then
    printf 'archive: 검증 증명이 유효하지 않습니다 (위 사유 참조)\n' >&2
    return 1
  fi
  return 0
}

# 검증을 돌리기 전에 환경에서 떨어뜨릴 변수 이름을 한 줄씩 냅니다.
#
# **이름 목록이 아니라 계열로 산출합니다.** 하나씩 적어 두면 같은 성질의 변수를 새로
# 만들 때마다 구멍이 하나씩 조용히 늘어나고, 그 구멍은 "통과 기록이 정상으로 남는"
# 형태라 사람 눈에 띄지 않습니다 (이 저장소에서 이미 3개 중 2개를 놓쳤습니다).
#   - `RD_SELFTEST_*`        실행 범위·모드 제어 (dry-run, checker-only, 우회 사유 …)
#   - `RD_EDIT_PROVENANCE_*` 검출력 제어 (스트레스 회차, 기록 위치 …)
#   - `CLAUDEMD_LINE_LIMIT`  계열이 없는 단독 변수. 제한을 올리면 크기 검사 스텝이
#                            아무것도 검사하지 않고 통과합니다.
# 실제로 없는 이름을 `env -u` 에 넘겨도 무해하므로, 과다 산출은 위험이 아닙니다
# (반대로 과소 산출은 그대로 구멍입니다). 계열은 이름만 보고 판단하므로 대상 스크립트를
# 읽지 않아도 새 변수가 자동으로 닫힙니다.
archive_selftest_env_denylist() {
  { env 2>/dev/null | grep -oE '^(RD_SELFTEST|RD_EDIT_PROVENANCE)_[A-Za-z0-9_]+' || true
    printf 'CLAUDEMD_LINE_LIMIT\n'
  } | sort -u
}

# 증명이 **성립할 수 있는 상태**인지 확인합니다. 사용: archive_selftest_preconditions <root>.
# return 0 = 성립, 1 = 불성립(사유는 stderr).
#
# 두 항목 모두 묻는 것은 하나입니다 — **증명 대상과 발행 대상이 같은가.**
#   - untracked 가 있으면 검증이 통과해도 증명이 기록되지 않습니다(기록 조건은
#     시작·종료 양쪽 0건). 돌려 봐야 같은 자리에서 그 시간을 다시 쓰게 됩니다.
#   - 워킹트리가 HEAD 와 다르면, 게이트가 증명하는 것은 **워킹트리**인데 tag·push 로
#     발행되는 것은 **HEAD** 입니다. 갈라진 채 통과하면 게이트는 "검증됐다" 고 말하는데
#     실제 발행물은 검증 대상이 아니었습니다. 강제 플래그의 주 용도가 바로 이 tracked
#     dirty 이므로, untracked 만 보면 더 흔한 절반을 그대로 놓칩니다.
#
# **이 확인은 증명 대조보다 앞이어야 합니다.** 뒤에 두면 유효한 증명이 있는 빠른 경로가
# 통째로 건너뛰어, 가장 흔한 경우(증명이 유효한 상태로 아카이브)에서 그대로 새어 나갑니다.
# 정상 경로는 아카이브 시작 시점의 clean 검사가 두 상태를 모두 먼저 막으므로, 여기에
# 도달하는 것은 그 검사를 강제로 넘긴 경우입니다.
#
# **판정 근거는 플래그가 아니라 실제 상태입니다** — 강제 플래그를 줬지만 실제로는 clean 인
# 정당한 아카이브까지 막으면 사용자는 우회 밸브가 없는 이 게이트를 아예 들어냅니다.
# 대조 범위는 증명 집합과 **같은 pathspec** 입니다. 넓게 잡으면 증명 대상도 아닌 감사 로그
# 한 줄에 정당한 아카이브가 막힙니다. git 오류는 "모름" 이므로 차단 쪽입니다.
# 헬퍼는 서브셸 안에서 읽어 함수 정의가 호출 셸에 남지 않게 합니다.
archive_selftest_preconditions() {
  local root="$1"
  (
    _archive_selftest_helper_load "$root" || exit 1

    local ustate=0 ulist=""
    ulist="$(smoke_untracked_state "$root")" || ustate=$?
    if [[ "$ustate" -eq 2 ]]; then
      printf 'archive: untracked 목록 조회에 실패해(git 오류) 검증을 실행하지 않았습니다\n' >&2
      printf 'archive:   지금 실행해도 증명이 기록되지 않아 같은 자리에서 반복됩니다\n' >&2
      exit 1
    fi
    if [[ "$ustate" -eq 1 ]]; then
      printf 'archive: 증명에 담기지 않는 untracked 파일이 있어 검증을 실행하지 않았습니다\n' >&2
      printf '%s\n' "$ulist" | sed 's/^/  /' >&2
      printf 'archive:   지금 실행하면 통과해도 증명이 남지 않아 재실행마다 같은 시간을 다시 씁니다\n' >&2
      printf 'archive:   무관한 파일이면 git add 또는 정리 후 다시 실행하십시오 (--force-dirty 로 clean 검사를 넘긴 경우입니다)\n' >&2
      printf 'archive:   **이것이 검증 실패를 고치는 내용이라면 main 이 아니라 fr 브랜치에서 고치고 diff review 를 거치십시오**\n' >&2
      printf 'archive:   (main 에서 커밋하면 그 수정은 리뷰를 거치지 않은 채 발행됩니다)\n' >&2
      exit 1
    fi

    local pspec=(".") sp dstate=0
    while IFS= read -r sp; do [[ -n "$sp" ]] && pspec+=("$sp"); done < <(smoke_proof_exclude)
    git -C "$root" diff --quiet HEAD -- ${pspec[@]+"${pspec[@]}"} 2>/dev/null || dstate=$?
    if [[ "$dstate" -ge 2 ]]; then
      printf 'archive: 워킹트리와 HEAD 의 대조에 실패해(git 오류) 검증을 실행하지 않았습니다\n' >&2
      printf 'archive:   무엇이 발행될지 알 수 없는 상태라 진행할 수 없습니다\n' >&2
      exit 1
    fi
    if [[ "$dstate" -ne 0 ]]; then
      printf 'archive: 커밋되지 않은 변경이 있어 검증을 실행하지 않았습니다\n' >&2
      printf 'archive:   증명 대상(워킹트리)과 발행 대상(HEAD)이 달라 검증이 성립하지 않습니다\n' >&2
      git -C "$root" diff --name-only HEAD -- ${pspec[@]+"${pspec[@]}"} 2>/dev/null | sed 's/^/  /' >&2
      printf 'archive:   무관한 변경이면 commit 또는 stash 후 다시 실행하십시오 (--force-dirty 로 clean 검사를 넘긴 경우입니다)\n' >&2
      printf 'archive:   **이것이 검증 실패를 고치는 내용이라면 main 이 아니라 fr 브랜치에서 고치고 diff review 를 거치십시오**\n' >&2
      printf 'archive:   (main 에서 커밋하면 그 수정은 리뷰를 거치지 않은 채 발행됩니다)\n' >&2
      exit 1
    fi
    exit 0
  )
}

# 증명이 없거나 stale 하면 **그 자리에서 consumer 검증을 실행**하고 다시 대조합니다.
# 사용: archive_selftest_gate <project_root>. return 0=진행, 1=중단.
#
# 아카이브는 hook 이 아니라 사용자가 직접 실행하는 스크립트라 시간 제약이 없어, 막고 끝내는
# 대신 여기서 돌려 줍니다 (막기만 하면 사용자가 같은 명령을 두 번 치게 됩니다).
archive_selftest_gate() {
  local root="$1" why=""
  # 전제 확인이 **증명 대조보다 먼저**입니다 (근거는 위 함수 주석).
  archive_selftest_preconditions "$root" || return 1

  # 첫 대조의 사유는 아직 "문제" 가 아닙니다 — 바로 아래에서 검증을 돌려 해소하기
  # 때문입니다. 그래서 붙잡아 두었다가 **실제로 막을 때만** stderr 로 내고, 정상 진행
  # 경로에서는 "왜 지금 도는가" 의 설명으로 stdout 에 붙입니다.
  # 정상 진행이 stderr 를 쓰면 무출력 계약을 검사하는 소비처가 정상 상태를 결함으로 봅니다.
  # 명령 치환 안에서 돌아 함수 정의가 이 셸에 남지 않습니다.
  if why="$(archive_selftest_precheck "$root" 2>&1 1>/dev/null)"; then
    return 0
  fi

  # 진행 안내는 stdout 입니다 — 이 스크립트의 관례가 "진행은 stdout · 문제는 stderr" 이고,
  # 정상 진행 경로가 stderr 를 쓰면 무출력 계약을 검사하는 소비처가 정상 상태를 결함으로 봅니다.
  printf 'archive: 이 내용으로 검증을 통과한 기록이 없어 지금 실행합니다\n'
  [[ -z "$why" ]] || printf '%s\n' "$why" | sed 's/^/archive:   /'
  # **범위를 정직하게 말합니다.** 예전 문구는 "전수 검증" 이었는데, 게이트가 실제로 강제하는
  # 것은 `consumer` 청중 집합입니다. 전수라고 말하면 사용자는 정본 위생 검사까지 끝났다고
  # 오인하고, 그 오인이 곧 "발행 전에 확인했다" 는 잘못된 안심이 됩니다.
  printf 'archive:   범위: consumer 청중 (이 프로젝트에서 뜻이 있는 검사). 전수 검증이 아닙니다\n'
  printf 'archive:   정본 위생 검사까지 보려면 따로 bash rd-workflow/scripts/self_test.sh full 을 실행하십시오\n'
  printf 'archive:   실행 예정 스텝 수와 제외 내역은 아래 시작 배너에 표시됩니다\n'
  printf 'archive:   중단해도 merge 는 이미 반영돼 있어, 다시 실행하면 이 지점부터 이어집니다\n'
  # 검증은 **위생적인 환경**에서 돌려야 합니다. 셸에 export 된 채 남은 변수 하나가
  # 검사를 통째로 건너뛰게 하거나(dry-run 은 0.1초에 rc 0, checker-only 는 아무것도 실행
  # 않고 rc 0) 검출력을 조용히 낮추면(스트레스 회차·크기 제한은 허용 범위 안이라 경고조차
  # 나지 않습니다), 통과 기록만 정상으로 남아 안전망이 거짓말을 합니다.
  # **계열 정규식이 산출하는 이름에 한해** 떨어뜨리는 것은 기본값 복원이라 과잉 차단이
  # 되지 않습니다 — 그 이름들은 모두 부재 시 기본 동작으로 돌아가도록 읽히기 때문입니다.
  # 이것은 임의의 환경변수에 대한 진술이 아닙니다. 예컨대 `HOME` 을 떨어뜨리면 git 의
  # global config 해석이 달라져 "기본값 복원" 이 아닙니다. 계열 정규식은 그런 이름을
  # 산출하지 않으므로 현행 코드에서 도달 불가이나, 계열을 넓힐 때 이 구분이 필요합니다.
  local _envu=() _dv
  while IFS= read -r _dv; do [[ -n "$_dv" ]] && _envu+=( -u "$_dv" ); done < <(archive_selftest_env_denylist)
  if ! env ${_envu[@]+"${_envu[@]}"} bash "$root/rd-workflow/scripts/self_test.sh" consumer; then
    printf 'archive: 검증 실패 — 원인을 해결한 뒤 다시 실행하십시오\n' >&2
    return 1
  fi
  if ! archive_selftest_precheck "$root"; then
    printf 'archive: 검증은 통과했으나 증명 대조가 여전히 불일치합니다\n' >&2
    printf 'archive:   실행 중 파일이 바뀌었거나 증명이 기록되지 않았습니다 (위 사유 참조)\n' >&2
    return 1
  fi
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
