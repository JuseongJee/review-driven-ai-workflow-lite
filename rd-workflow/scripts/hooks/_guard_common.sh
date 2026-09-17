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

# ---------------------------------------------------------------------------
# 종결 마커 strict 검증 (change-spec §3.1·§3.3) — canonical 단일 출처
# ---------------------------------------------------------------------------
# 검증 규칙을 여기 한 곳에만 둡니다. `rd` 는 `_task_common.sh` 를 통해 이 파일을 source 해
# 같은 함수를 부르고, 자체 구현을 두지 않습니다 — 규칙이 두 곳에 있으면 「`rd task status`
# 는 발행 가능이라는데 `archive.sh` 가 막는」 어긋난 상태가 생깁니다 (spec §4.4).
#
# 판정 헬퍼는 `_state_common.sh` 의 T1 함수(`rd_repo_root`·`rd_resolve_commit_oid`·
# `rd_protected_tree_hash`·`rd_branch_mode`·`state_read_review_session`) 를 재사용하며
# 같은 판정을 다시 구현하지 않습니다.

RD_SEAL_SCHEMA="1"
# 마커 필수 필드 (§3.1). 공백 구분 — bash 3.2 라 연관배열을 쓰지 않습니다.
RD_SEAL_REQUIRED_FIELDS="schema session-id review-type tree-hash head branch-mode fr-branch rd-version verified sealed-at"
RD_SEAL_REL_DIR="rd-workflow-workspace/.lifecycle/review-seals"
RD_SEAL_REL_STATE="rd-workflow-workspace/.lifecycle/task-state"
RD_SEAL_AUDIT_REL="rd-workflow-workspace/.lifecycle/review-skip-audit.log"

_rd_seal_dir() { printf '%s\n' "${project_root}/${RD_SEAL_REL_DIR}"; }

# _rd_kv_get <file> <key> — key=value 파일에서 첫 값 출력 (부재 시 빈 출력)
_rd_kv_get() {
  [[ -f "$1" ]] || return 0
  awk -F'=' -v k="$2" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$1"
}

# _rd_version — rd-workflow VERSION (§8 self-modification 경고용). 부재 시 unknown.
_rd_version() {
  local f="${project_root}/rd-workflow/VERSION" v=""
  [[ -f "$f" ]] && v="$(head -n 1 "$f" | tr -d '[:space:]')"
  printf '%s\n' "${v:-unknown}"
}

# 검증 결과 전역 (§4.4 의 복구 안내가 사유마다 다르므로 kind 를 합치지 않습니다)
#   RD_SEAL_FAIL_KIND — missing | hash-mismatch | pointer-missing | malformed | hash-error
#   RD_SEAL_FAIL_MSG  — §3.3 표의 문구 그대로
#   RD_SEAL_VERIFIED  — 성공 시 yes | legacy-unverified
#   RD_SEAL_SESSION_ID — 포인터가 해석된 경우의 session-id (audit 기록용)
RD_SEAL_FAIL_KIND=""
RD_SEAL_FAIL_MSG=""
RD_SEAL_VERIFIED=""
RD_SEAL_SESSION_ID=""
# 검증이 통과한 **보호 트리 해시**입니다. 발행 직전 재결속(archive.sh Step 4.6) 이 이 값을
# 소비하므로, 성공했을 때만 채우고 실패·미실행 시에는 빈 값으로 남깁니다.
RD_SEAL_TREE_HASH=""

_rd_seal_fail() {
  RD_SEAL_FAIL_KIND="$1"
  RD_SEAL_FAIL_MSG="$2"
  return 1
}

# _rd_seal_pointer_check <값> — review-session 값 계약 (경로 이탈 거부, §3.3)
#   0 = 유효 / 1 = 미설정 / 2 = 경로 이탈
_rd_seal_pointer_check() {
  local v="${1-}"
  case "$v" in
    ""|null|-) return 1 ;;
    */*|*\\*|.|..) return 2 ;;
  esac
  return 0
}

# rd_seal_verify <worktree|commit> [판정 대상 commit] [fr-branch 값]
#
#   return 0 — 유효. `RD_SEAL_VERIFIED` 에 verified 값(yes|legacy-unverified) 을,
#              `RD_SEAL_TREE_HASH` 에 검증이 통과한 보호 트리 해시를 담습니다.
#   return 1 — 무효. `RD_SEAL_FAIL_KIND`·`RD_SEAL_FAIL_MSG` 를 채웁니다.
#
# **source 인자 분리가 계약입니다 (§4.4).** 게이트(`archive_review_precheck`)는 언제나
# `commit` 으로 §3.3.1 의 판정 대상 commit 을 읽고, `rd task status` 만 워킹트리를 추가로
# 봅니다. 워킹트리를 게이트 판정에 넣으면 「fr 브랜치에 커밋 → 기본 브랜치로 switch →
# archive.sh」 표준 흐름이 깨집니다.
#
# fr-branch 값은 **판정 입력이 아니라 판정 대상을 찾는 값**이므로(§3.3.1 의 유일한 예외)
# 호출자가 넘깁니다. 생략하면 워킹트리 task-state 에서 읽습니다.
rd_seal_verify() {
  local src="${1-}" target="${2-}" fr_in="${3-}"
  RD_SEAL_FAIL_KIND=""; RD_SEAL_FAIL_MSG=""; RD_SEAL_VERIFIED=""; RD_SEAL_SESSION_ID=""
  RD_SEAL_TREE_HASH=""
  local root sid tmp rc content_ok=0
  root="$(rd_repo_root)" || { _rd_seal_fail "hash-error" "repo root 를 찾을 수 없습니다 — 판정 불가"; return 1; }

  # --- 1) review-session 포인터 (§3.3 — 디렉터리 탐색 금지, 이 값 하나만 씁니다) ---
  if [[ "$src" == "commit" ]]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/rd-seal-state.XXXXXX")" \
      || { _rd_seal_fail "hash-error" "mktemp 실패 — 판정 불가"; return 1; }
    if ! git -C "$root" show "${target}:${RD_SEAL_REL_STATE}" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      { _rd_seal_fail "pointer-missing" \
        "final diff review 세션이 지정되지 않았습니다 — prepare_review_pipeline.sh diff 로 세션을 만드십시오"; return 1; }
    fi
    sid="$(_rd_kv_get "$tmp" "review-session")"
    rm -f "$tmp"
    _rd_seal_pointer_check "$sid"; rc=$?
  else
    sid="$(state_read_review_session 2>/dev/null)"; rc=$?
  fi
  if [[ "$rc" == "2" ]]; then
    { _rd_seal_fail "malformed" "review-session 값에 경로 구분자나 '..' 가 있습니다: '${sid}'"; return 1; }
  fi
  if [[ "$rc" != "0" || -z "$sid" ]]; then
    { _rd_seal_fail "pointer-missing" \
      "final diff review 세션이 지정되지 않았습니다 — prepare_review_pipeline.sh diff 로 세션을 만드십시오"; return 1; }
  fi
  RD_SEAL_SESSION_ID="$sid"

  # --- 2) 마커 파일 존재 (handoffs/ 를 보지 않습니다 — 마커 하나만 읽습니다) ---
  tmp="$(mktemp "${TMPDIR:-/tmp}/rd-seal-marker.XXXXXX")" \
    || { _rd_seal_fail "hash-error" "mktemp 실패 — 판정 불가"; return 1; }
  if [[ "$src" == "commit" ]]; then
    git -C "$root" show "${target}:${RD_SEAL_REL_DIR}/${sid}.seal" > "$tmp" 2>/dev/null && content_ok=1
  else
    [[ -f "$(_rd_seal_dir)/${sid}.seal" ]] && cat "$(_rd_seal_dir)/${sid}.seal" > "$tmp" 2>/dev/null && content_ok=1
  fi
  if [[ "$content_ok" != "1" ]]; then
    rm -f "$tmp"
    { _rd_seal_fail "missing" "마커 없음 — rd review seal <세션> 을 먼저 실행하세요"; return 1; }
  fi

  # --- 3) schema / 필수 필드 / session-id / review-type / branch / verified ---
  local schema missing="" f v m_sid m_type m_mode m_fr m_hash m_verified m_version
  schema="$(_rd_kv_get "$tmp" "schema")"
  if [[ "$schema" != "$RD_SEAL_SCHEMA" ]]; then
    rm -f "$tmp"
    { _rd_seal_fail "malformed" "마커 schema 미지원 (파일=${schema:-<없음>}, 지원=${RD_SEAL_SCHEMA})"; return 1; }
  fi
  for f in $RD_SEAL_REQUIRED_FIELDS; do
    v="$(_rd_kv_get "$tmp" "$f")"
    [[ -z "$v" ]] && missing="${missing:+${missing}, }${f}"
  done
  if [[ -n "$missing" ]]; then
    rm -f "$tmp"
    { _rd_seal_fail "malformed" "마커 형식 오류 — 누락 필드: ${missing}"; return 1; }
  fi
  m_sid="$(_rd_kv_get "$tmp" "session-id")"
  m_type="$(_rd_kv_get "$tmp" "review-type")"
  m_mode="$(_rd_kv_get "$tmp" "branch-mode")"
  m_fr="$(_rd_kv_get "$tmp" "fr-branch")"
  m_hash="$(_rd_kv_get "$tmp" "tree-hash")"
  m_verified="$(_rd_kv_get "$tmp" "verified")"
  m_version="$(_rd_kv_get "$tmp" "rd-version")"
  rm -f "$tmp"

  # 파일명(<session-id>.seal) 과 내부 session-id 일치 — 복사·개명 탐지.
  if [[ "$m_sid" != "$sid" ]]; then
    { _rd_seal_fail "malformed" "마커 세션 불일치 — 복사되었거나 이름이 잘못되었습니다"; return 1; }
  fi
  # 내부 session-id 와 task-state `review-session` 포인터 일치 (§3.3 의 별도 항목).
  # 마커 경로를 포인터로 조립하므로 위 검사가 통과하면 이 검사도 통과합니다 — 두 사유가
  # 실제로는 겹칩니다. 포인터를 쓰지 않는 경로가 생겼을 때 조용히 통과하지 않도록
  # 검사와 문구를 그대로 남겨 둡니다 (§3.3 표의 10종 중 한 줄).
  if [[ "$m_sid" != "$RD_SEAL_SESSION_ID" ]]; then
    { _rd_seal_fail "malformed" "마커가 현재 작업의 세션이 아닙니다"; return 1; }
  fi
  if [[ "$m_type" != "diff-review" ]]; then
    { _rd_seal_fail "malformed" "마커가 final diff review 의 것이 아닙니다 (review-type=${m_type})"; return 1; }
  fi
  # branch-mode·fr-branch 는 현재 task 와 일치해야 합니다 (§3.2.2 표기).
  local cur_fr cur_mode cur_fr_field
  cur_fr="$fr_in"
  [[ -z "$cur_fr" ]] && cur_fr="$(state_read_field "fr-branch")"
  cur_mode="$(rd_branch_mode "$cur_fr" 2>/dev/null)" \
    || { _rd_seal_fail "malformed" "task-state fr-branch 값이 canonical 이 아닙니다: '${cur_fr}'"; return 1; }
  if [[ "$cur_mode" == "no-fr" ]]; then cur_fr_field="null"; else cur_fr_field="$cur_fr"; fi
  if [[ "$m_mode" != "$cur_mode" || "$m_fr" != "$cur_fr_field" ]]; then
    { _rd_seal_fail "malformed" "마커 branch 모드 불일치"; return 1; }
  fi
  # verified 는 2값만 허용합니다 (§3.3).
  case "$m_verified" in
    yes|legacy-unverified) ;;
    *) { _rd_seal_fail "malformed" "마커 verified 값이 올바르지 않습니다: ${m_verified}"; return 1; } ;;
  esac

  # --- 4) 보호 트리 해시 일치 (§2.2 fail-closed — 계산 실패는 통과가 아닙니다) ---
  local cur_hash ref
  if [[ "$src" == "commit" ]]; then ref="$target"; else ref="HEAD"; fi
  cur_hash="$(rd_protected_tree_hash "$ref" 2>/dev/null)" \
    || { _rd_seal_fail "hash-error" "보호 트리 해시를 계산할 수 없습니다 — 판정 불가로 차단합니다"; return 1; }
  if [[ "$m_hash" != "$cur_hash" ]]; then
    { _rd_seal_fail "hash-mismatch" \
      "리뷰 대상 불일치 — 종결 후 코드가 변경되었습니다. 재리뷰 후 seal 을 다시 실행하세요"; return 1; }
  fi

  # rd-version 불일치는 경고만 합니다 (§8) — 버전이 오른 것 자체는 정상이며, 차단하면
  # 업그레이드가 곧 발행 불가가 됩니다.
  if [[ "$m_version" != "$(_rd_version)" ]]; then
    echo "경고: 마커의 rd-version(${m_version}) 이 현재 VERSION($(_rd_version)) 과 다릅니다." >&2
  fi
  RD_SEAL_VERIFIED="$m_verified"
  # 통과한 해시를 남깁니다 — 이 시점에 `m_hash` 와 `cur_hash` 는 같습니다. 발행 직전
  # 재결속은 "마커가 승인한 트리" 를 기준으로 해야 하므로 마커 값을 그대로 씁니다.
  RD_SEAL_TREE_HASH="$m_hash"
  return 0
}

# _rd_seal_legacy_warning — legacy 마커 지속 고지 (§3.3 Finding 5).
# 통과할 때마다 냅니다 — 생성 시점 1회 고지로는 나중에 실행하는 사람이 알 수 없습니다.
_rd_seal_legacy_warning() {
  echo "경고: 이 마커는 검증되지 않은 legacy 전환입니다 (verified=legacy-unverified)." >&2
  echo "      리뷰 당시 트리를 증명하지 않습니다. 사유: ${RD_SEAL_AUDIT_REL}" >&2
}

# archive review precheck — 발행 직전 종결 마커 strict 검증 (change-spec §3.3·§3.3.1).
#
# **`handoffs/` 를 읽지 않습니다.** 종전에는 fr tip 의 `review_pipeline` 서브트리를 통째로
# 추출해 세션 종결성을 다시 판정했으나, 이제는 §3.1 의 마커 한 파일만 읽습니다 (AC 11).
# 세션 본문을 커밋하지 않는 프로젝트도 마커만 커밋하면 통과합니다.
#
# 판정 입력은 전부 **하나의 판정 대상 commit** 에서 읽습니다 (§3.3.1).
#   fr    — `<fr-branch>^{commit}` (fr tip). 기존 main-worktree 비의존 계약을 보존합니다.
#   no-fr — 현재 `HEAD^{commit}` (Step 0 clean 검사 통과 후).
# 워킹트리 파일을 읽으면 「fr 브랜치에 커밋 → 기본 브랜치로 switch → archive.sh」 표준
# 흐름에서 마커를 못 보거나 기본 브랜치의 stale 한 상태를 읽습니다.
#
# fr 브랜치 **이름만** 예외입니다 — 판정 입력이 아니라 판정 대상을 찾는 값이므로 인자
# (`archive.sh` 의 `FR_BRANCH`) 또는 워킹트리 task-state 에서 옵니다. 모드 판정은
# `rd_branch_mode` 한 곳에서만 합니다.
#
# **승인한 보호 트리 해시를 밖으로 남깁니다 (`RD_ARCHIVE_REVIEWED_TREE_HASH`).** 이 검증은
# 발행 대상이 확정되기 **전**의 commit 을 보므로, 그 뒤 HEAD 가 전진하면 검증한 트리와
# 발행하는 트리가 갈라질 수 있습니다. 그 창을 닫으려면 호출자가 발행 직전에 같은 해시로
# 다시 대조해야 하고, cleanup 이 `review-session` 을 baseline 으로 되돌리므로 그 시점에
# `rd_seal_verify` 를 다시 부르는 방식은 성립하지 않습니다 — 그래서 해시를 값으로 넘깁니다.
# 우회(`--force-skip-review-check`) 로 통과한 경우에는 승인한 해시가 없으므로 빈 값입니다.
#
# 사용: archive_review_precheck <force_skip 0|1> <reason> <slug> <audit_log> [fr_branch]
#       return 0=진행, 1=차단. 인자 형태는 종전과 같습니다.
RD_ARCHIVE_REVIEWED_TREE_HASH=""
archive_review_precheck() {
  local force_skip="$1" reason="$2" slug="$3" audit_log="$4" fr_ref="${5:-}"
  local mode="" target="" audit_ref="" ok=1 fail_msg=""
  RD_ARCHIVE_REVIEWED_TREE_HASH=""

  if [[ -z "$fr_ref" ]]; then
    fr_ref="$(state_read_field "fr-branch")"
  fi
  if ! mode="$(rd_branch_mode "$fr_ref" 2>/dev/null)"; then
    fail_msg="fr-branch 값이 canonical 이 아닙니다 ('${fr_ref}') — 'fr/<slug>' 또는 'null' 이어야 합니다"
  elif [[ "$mode" == "fr" ]]; then
    if ! target="$(rd_resolve_commit_oid "$fr_ref" 2>/dev/null)"; then
      target=""
      fail_msg="fr 브랜치 '${fr_ref}' 의 commit 을 찾을 수 없습니다 — 판정 대상이 없습니다"
    fi
  else
    if ! target="$(rd_resolve_commit_oid "HEAD" 2>/dev/null)"; then
      target=""
      fail_msg="HEAD 를 commit 으로 해석할 수 없습니다 — 판정 불가"
    fi
  fi

  if [[ -z "$fail_msg" ]]; then
    if rd_seal_verify "commit" "$target" "$fr_ref"; then
      ok=0
    else
      fail_msg="$RD_SEAL_FAIL_MSG"
    fi
  fi
  # audit 은 temp 경로가 아니라 repo-상대 마커 경로로 남깁니다.
  [[ -n "$RD_SEAL_SESSION_ID" ]] && audit_ref="${RD_SEAL_REL_DIR}/${RD_SEAL_SESSION_ID}.seal"

  if [[ "$ok" -eq 0 ]]; then
    RD_ARCHIVE_REVIEWED_TREE_HASH="$RD_SEAL_TREE_HASH"
    [[ "$RD_SEAL_VERIFIED" == "legacy-unverified" ]] && _rd_seal_legacy_warning
    return 0
  fi

  printf 'archive: 종결 마커 검증 실패 — %s\n' "$fail_msg" >&2
  if [[ "$force_skip" != "1" ]]; then
    printf 'archive: review 미종결 (마커 없음 또는 무효). --force-skip-review-check "<사유>"로만 우회 가능.\n' >&2
    return 1
  fi
  if [[ -z "$reason" ]]; then
    printf 'archive: --force-skip-review-check 사유 필수\n' >&2
    return 1
  fi
  # audit 기록은 이 우회 경로의 **유일한 흔적**입니다. `mkdir -p` 와 append 의 종료 상태를
  # 확인하지 않으면 기록이 통째로 사라진 채 "audit log 기록" 이라고 잘못 알리고 발행이
  # 계속됩니다 (final diff review turn 004 Finding 1). 실패는 차단으로 전파합니다 —
  # 리뷰 검증을 명시적으로 우회하면서 사유조차 남지 않는 발행은 허용하지 않습니다.
  local audit_dir
  audit_dir="$(dirname "$audit_log")"
  if ! mkdir -p "$audit_dir" 2>/dev/null; then
    printf 'archive: audit 디렉터리를 만들 수 없습니다 (%s) — 우회 사유를 남길 수 없어 차단합니다.\n' "$audit_dir" >&2
    return 1
  fi
  if ! printf '%s | %s | %s | %s\n' "$(date '+%Y-%m-%d %H:%M')" "$slug" "$reason" "${audit_ref:-<세션없음>}" >> "$audit_log" 2>/dev/null; then
    printf 'archive: audit log 기록에 실패했습니다 (%s) — 우회 사유를 남길 수 없어 차단합니다.\n' "$audit_log" >&2
    return 1
  fi
  printf 'archive: WARNING — review 검증 우회 (사유: %s). audit log 기록.\n' "$reason" >&2
  return 0
}

# archive_publish_rebind_check <승인된 보호 트리 해시> <발행 대상 commit>
#
# precheck 가 승인한 트리와 **실제로 발행할 commit** 의 트리를 다시 결속합니다 (§2.2·§3.3.1).
#
# precheck 는 metadata cleanup commit 이전의 commit 을 봅니다. 그 뒤 cleanup commit 이 붙고
# 발행 대상 OID 가 확정되는데, 그 사이에 보호 경로를 바꾼 커밋이 HEAD 를 전진시키면 검증한
# 트리와 발행하는 트리가 갈라집니다. cleanup 이 `review-session` 포인터를 baseline 으로
# 되돌리므로 이 시점에 `rd_seal_verify` 를 다시 부를 수는 없습니다 — 그래서 승인 시점의
# 해시를 값으로 받아 대조합니다.
#
#   return 0 — 일치. 발행해도 됩니다.
#   return 1 — 불일치. 미검토 코드가 섞였습니다.
#   return 2 — 판정 불가 (인자 누락 또는 해시 계산 실패). fail-closed 라 통과가 아닙니다.
archive_publish_rebind_check() {
  local reviewed="${1-}" publish_oid="${2-}" cur=""
  if [[ -z "$reviewed" || -z "$publish_oid" ]]; then
    echo "archive: 발행 재대조에 필요한 값이 없습니다 (승인 해시 또는 발행 대상) — 판정 불가로 차단합니다." >&2
    return 2
  fi
  cur="$(rd_protected_tree_hash "$publish_oid" 2>/dev/null)" || {
    echo "archive: 발행 대상의 보호 트리 해시를 계산할 수 없습니다 — 판정 불가로 차단합니다." >&2
    return 2
  }
  if [[ "$cur" != "$reviewed" ]]; then
    echo "archive: 발행 대상이 리뷰된 트리와 다릅니다 — 종결 마커 검증 이후 보호 경로가 바뀌었습니다." >&2
    echo "archive:   리뷰된 해시=${reviewed}" >&2
    echo "archive:   발행 대상(${publish_oid}) 해시=${cur}" >&2
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

# --- 차단 계측 (guard-block-instrumentation) ---
#
# 가드가 실제로 무엇을 막았는지 한 줄씩 남긴다. 목적은 나중에 사람이 「이 가드가 실수를
# 잡았나, 정당한 작업만 막았나」를 판정하는 것이다 — 가드는 늘기만 하고 은퇴하지 않는데
# 은퇴를 판정할 데이터가 없었다.
#
# **왜 EXIT trap 이 아닌가.** 처음엔 이 파일에 EXIT trap 을 하나 달아 모든 가드를 자동으로
# 덮으려 했다. 폐기했다 — 이 파일을 source 하는 곳은 hooks 만이 아니고
# `lifecycle/archive.sh`·`lifecycle/test_lifecycle.sh` 도 포함되며, `test_lifecycle.sh` 는
# **조용한 중단 센티넬 EXIT trap** 을 먼저 걸고 나중에 이 파일을 source 한다. bash 는 EXIT
# trap 을 하나만 가지므로 나중에 건 쪽이 앞의 것을 말없이 지운다 — 계측이 그 센티넬을
# 무력화했다(`self_test.sh lifecycle` 이 검출). 반대로 소비자가 나중에 trap 을 걸면 계측이
# 조용히 꺼진다. **동작하는 것처럼 보이면서 꺼지는 것이 잊을 수 있는 것보다 나쁘다.**
#
# 그래서 차단 지점마다 `guard_deny` 를 부른다. 「새 가드가 계측을 빠뜨릴 수 있다」는 약점은
# `self_test.sh` 의 구조 검사(`guard_deny_convention_check`)가 대신 막는다. 그 검사는 텍스트
# 기반이므로 모든 셸 표현을 증명하지는 못한다 — 규약 위반을 흔한 형태에서 잡는 장치다.
#
# **통과는 기록하지 않는다.** 모든 Bash·Edit·Write 호출마다 한 줄씩 쌓이면 로그가 무의미해
# 지고 저장소가 부풀어 오른다. 알고 싶은 것은 "무엇을 막았나" 다.
#
# **로그가 자라는 것을 회전으로 감추지 않는다.** 차단은 드물어야 정상이므로, 로그가 빠르게
# 자란다면 그 자체가 「이 가드가 정당한 작업을 막고 있다」는 신호다. 조용히 버리지 않는다.
#
# **경로는 env 로 override 할 수 있다.** 편의가 아니라 오염 방지다 — 차단 가드의 테스트는
# **실제 hook** 을 부르고 hook 은 자기 위치에서 project_root 를 도출하므로, 그냥 두면 검증이
# 운영 감사 로그에 쓴다(실측: `self_test.sh hooks` 한 번에 28줄). 그러면 로그가 테스트
# 잡음으로 채워져 「이 가드가 무엇을 막았나」를 볼 수 없다. `self_test.sh` 와 **실제 hook 을
# 부르는 개별 테스트가 각각** 이 변수를 임시 경로로 돌린다(둘 다 필요하다 — self_test 만
# 격리하면 테스트를 직접 실행하는 정상적인 개발 경로가 여전히 오염시킨다).
RD_GUARD_BLOCK_LOG="${RD_GUARD_BLOCK_LOG:-${project_root}/rd-workflow-workspace/.lifecycle/guard-block-audit.log}"

# _rd_guard_sanitize <문자열> — 한 차단 = 한 줄을 보장한다.
#
# **외부 바이너리를 쓰지 않는다.** 초판은 `tr`·`cut` 을 썼는데, 그것들이 없는 제한된 PATH
# (테스트의 격리 환경, 최소 컨테이너)에서 127 로 죽어 **차단(2)이 127 로 나갔다.** 차단이
# 차단으로 보이지 않게 되는 실제 버그였다. 제어문자 치환과 길이 제한을 bash 3.2 의 패턴
# 치환·부분문자열로만 한다. 필드 구분자(`|`)도 공백으로 바꿔 열이 밀리지 않게 한다.
_rd_guard_sanitize() {
  local v="${1-}"
  v="${v//[[:cntrl:]]/ }"
  v="${v//|/ }"
  printf '%s' "${v:0:200}"
}

# _rd_guard_cmd_summary <명령 원문> — **인자를 버리고 프로그램 이름만 남긴다.**
#
# **원문 명령을 기록하면 안 된다.** headless 차단은 임의의 Bash 명령에 걸리므로 토큰이 담긴
# `curl -H "Authorization: Bearer …"` 나 환경변수 대입이 그대로 들어온다. 감사 목적에는
# 「어떤 종류의 명령을 막았나」가 충분하고, 인자는 필요 없다. 로그를 추적 제외로 두는 것과
# 별개로 내용 자체를 줄인다 — 두 방어를 함께 둔다.
#
# **첫 토큰을 그대로 믿으면 안 된다.** 초판은 공백까지 잘라 프로그램 이름으로 봤는데, bash
# 의 리다이렉션·here-string 연산자는 **공백 없이 붙을 수 있다** — `cat<<<SECRET` 이나
# `printf>/secret/path` 는 첫 토큰 자체에 비밀을 담는다(리뷰에서 실측). 선행 환경변수 대입
# (`TOKEN=abc curl …`)도 같은 부류다.
#
# 그래서 **화이트리스트로 판정한다.** 첫 토큰이 프로그램 이름으로 안전하다고 확신할 수 있는
# 문자만으로 되어 있을 때에만 그 값을 남기고, 그 밖에는 고정 표식으로 축약한다. 셸 연산자·
# 인용·확장이 섞이면 안전한 이름을 확신할 수 없으므로 보수적으로 버린다. 입력을 실행하거나
# 셸에 평가시키지 않는다.
_rd_guard_cmd_summary() {
  local c="${1-}" first
  c="${c#"${c%%[![:space:]]*}"}"          # 앞 공백 제거
  first="${c%%[[:space:]]*}"
  [[ -n "$first" ]] || { printf '%s' '-'; return 0; }
  case "$first" in
    *=*) printf '%s' '<env-assign>'; return 0 ;;   # 값이 비밀일 수 있다
  esac
  # 허용: 영숫자 · _ . - + / (경로 포함 실행 파일 이름). 그 밖의 문자가 하나라도 있으면 버린다.
  case "$first" in
    *[!A-Za-z0-9_.+/-]*) printf '%s' '<unparsed>'; return 0 ;;
  esac
  printf '%s' "${first##*/}"                        # 경로가 붙어 있으면 이름만
}

# _rd_guard_json_get <jq 표현> — jq → python3 순으로 읽는다.
#
# **jq 만 있는 경로로 만들면 안 된다.** 판정(`hook_input_bool_true`)은 python3 폴백을 갖는데
# 계측만 jq 를 요구하면, jq 가 없는 지원 환경에서 차단은 정상 동작하면서 로그는 `tool=-
# target=- session=-` 만 남는다 — 「언제 무엇을 막았나」라는 목적 자체가 무너진다.
# 둘 다 없으면 필드를 비우고 진행한다(기능 축소이며, 차단 판정에는 영향이 없다).
_rd_guard_json_get() {
  local expr="${1-}" out=""
  if command -v jq >/dev/null 2>&1; then
    out="$(printf '%s' "$_hook_input" | jq -r "$expr // \"\"" 2>/dev/null)" || out=""
    printf '%s' "$out"; return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    # jq 표현을 그대로 쓸 수 없으므로 키 이름만 넘긴다 — 호출측이 단순 경로만 쓴다.
    out="$(printf '%s' "$_hook_input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
cur = d
for k in sys.argv[1].split("."):
    if not k:
        continue
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(0)
if isinstance(cur, (str, int, float)) and not isinstance(cur, bool):
    sys.stdout.write(str(cur))
' "${2-}" 2>/dev/null)" || out=""
    printf '%s' "$out"; return 0
  fi
  printf '%s' ""
}

# guard_deny — 차단을 기록하고 exit 2 로 끝낸다. **가드의 마지막 줄에서 `exit 2` 대신 쓴다.**
#
# **기록 실패가 차단을 바꾸면 안 된다.** 로그를 못 써도 차단은 차단이다. 그래서 외부
# 바이너리에 의존하지 않고(`date` 만 예외이며 실패해도 `||` 로 흡수), 쓰기 실패를 흡수한 뒤
# 반드시 `exit 2` 한다.
#
# **다만 실패를 숨기지는 않는다.** 초판은 모든 실패를 무음으로 흡수했는데, 이 기능은 사람이
# 로그를 보고 가드를 평가하는 것이므로 누락을 모르면 「차단한 적 없음」이라는 반대 결론으로
# 이어진다. 셸의 원시 오류(차단 안내를 오염시킨다)는 막고, 대신 **우리가 만든 한 줄 경고와
# 로그 경로**를 보여준다. 원래 차단 안내와 exit 2 는 그대로다.
#
# **리다이렉션 실패는 명령이 아니라 셸이 보고한다.** `printf ... >> f 2>/dev/null` 은 `>>`
# 자체가 실패할 때 메시지를 막지 못하므로(실측), 블록으로 감싼다.
#
# **`reason` 인자(선택, guard-block-reason-identifier)** — 한 가드 안에 판정 분기가 여럿일 때
# 로그 한 줄만으로 어느 분기였는지 구별하기 위한 짧은 고정 식별자다. 형식은
# `<가드 파일명(접미사 제외)>.<분기 토큰>` (예: `pre_commit_archive_gate.incomplete-source-fr`).
# **자유 텍스트를 넣지 않는다** — 고정 토큰만 허용해야 원문 인자 미기록(F1) 방향과 양립한다.
# **필수 인자가 아니다.** 소비 프로젝트의 vendored 사본·extension 가드가 인자 없이
# `guard_deny`를 호출해도 깨지지 않아야 한다(하위호환) — 그래서 인자를 생략하면 `reason=`
# 필드 자체를 붙이지 않는다(빈 값 강제가 아니라 필드 누락으로 하위호환한다). 이 저장소 안의
# 호출부(스캔 범위: `rd-workflow/scripts/hooks/*.sh` + `_ROOT_FILES` 사본, `test_*` 제외)는
# `self_test.sh`의 `guard_deny_convention_check`가 식별자 누락을 강제한다.
guard_deny() {
  local reason="${1-}"
  local guard tool target sid ts line dir src cmd
  src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  guard="${src##*/}"
  [[ -n "$guard" ]] || guard="unknown"

  tool=""; target=""; sid=""
  if [[ -n "${_hook_input:-}" ]]; then
    tool="$(_rd_guard_json_get '.tool_name' 'tool_name')"
    sid="$(_rd_guard_json_get '.session_id' 'session_id')"
    cmd="$(_rd_guard_json_get '.tool_input.command' 'tool_input.command')"
    if [[ -n "$cmd" ]]; then
      target="$(_rd_guard_cmd_summary "$cmd")"
    else
      # Edit·Write 는 file_path 가 실질 대상이다. 인자가 아니라 경로이므로 그대로 남긴다.
      target="$(_rd_guard_json_get '.tool_input.file_path' 'tool_input.file_path')"
    fi
  fi

  ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" || ts=""
  [[ -n "$ts" ]] || ts="unknown-time"

  line="${ts} | $(_rd_guard_sanitize "$guard")"
  line="${line} | rc=2"
  line="${line} | tool=$(_rd_guard_sanitize "${tool:--}")"
  line="${line} | target=$(_rd_guard_sanitize "${target:--}")"
  line="${line} | session=$(_rd_guard_sanitize "${sid:--}")"
  # **필드는 항상 끝에 추가한다.** 기존 필드 순서를 바꾸지 않아야 기존 소비 도구(수동
  # grep·test_guard_block_log.sh)의 파싱 가정이 깨지지 않는다. 인자가 없으면 이 필드
  # 자체를 붙이지 않는다 — 무인자 호출 시 로그 줄이 이 변경 이전과 바이트 동일하다.
  if [[ -n "$reason" ]]; then
    line="${line} | reason=$(_rd_guard_sanitize "$reason")"
  fi

  # **슬래시가 없으면 부모는 현재 디렉터리다.** `${v%/*}` 는 슬래시 없는 값을 그대로
  # 돌려주므로, `RD_GUARD_BLOCK_LOG=audit.log` 같은 상대 파일명에서는 `mkdir -p audit.log` 가
  # **로그 파일 자리에 디렉터리를 만들고** 이후 모든 append 가 영구 실패한다(리뷰에서 실측 —
  # 경고는 권한 문제라고 안내하지만 권한을 고쳐도 기록되지 않는다).
  case "$RD_GUARD_BLOCK_LOG" in
    */*) dir="${RD_GUARD_BLOCK_LOG%/*}" ;;
    *)   dir="." ;;
  esac
  { mkdir -p "$dir"; } 2>/dev/null || true
  if ! { printf '%s\n' "$line" >> "$RD_GUARD_BLOCK_LOG"; } 2>/dev/null; then
    printf '[guard] 차단은 적용됐으나 감사 로그 기록에 실패했습니다 — %s\n' \
      "$RD_GUARD_BLOCK_LOG" >&2
    printf '[guard] 이 차단은 은퇴 심사 데이터에 남지 않습니다. 경로 쓰기 권한을 확인하십시오.\n' >&2
  fi
  exit 2
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

# hook_input_bool_true <key>
# _hook_input 의 .tool_input.<key> 가 JSON literal true 이면 0, 그 외·판정 불가면 1.
#
# **extract_json_field 를 이 용도에 쓰면 안 된다.** 그 헬퍼는 값이 문자열이라고
# 가정한다 — jq 경로의 `// empty` 는 boolean false 를 빈 값으로 만들고, bash 폴백은
# 따옴표를 찾으므로 boolean 값에는 뒤따르는 **다른 필드의 값**을 집어온다.
#
# **판독은 실제 JSON 파서로만 한다.** 문자열 안/밖만 가르는 조각 인식기는 문법
# 검증기가 아니어서 후행 쉼표·쉼표 누락·괄호 짝 불일치·잘못된 escape·중복 키에서
# 파서와 다른 답을 낸다(리뷰에서 실행으로 확인). boolean 하나를 위해 awk 로 JSON
# 파서를 새로 쓰는 것은 유지비가 맞지 않으므로 python3 을 2순위로 둔다.
#
# 둘 다 없으면 판정하지 않고 1(=통과)을 반환한다. 그 환경에서는 이 hook 의 강제가
# 없고 산문 규율만 남는다 — 계약의 축소이며 change spec 2.1 에 명시돼 있다.
#
# 판정 실패는 곧 "true 아님"(return 1)이며, 호출측 hook 은 이를 통과로 다룬다 —
# positive 감지 한정 fail-open. 이 fail-open 은 hook 전용이며 완료 판정에 쓰지 않는다.
hook_input_bool_true() {
  local key="$1"
  [[ -n "$_hook_input" ]] || return 1

  if command -v jq &>/dev/null; then
    # -e 는 결과를 exit code 에 싣는다 — `//` 함정을 원천 회피한다.
    # tool_input 부재는 empty 로 비0, 깨진 JSON 은 파싱 실패로 비0 이다.
    printf '%s' "$_hook_input" \
      | jq -e --arg k "$key" '(.tool_input // empty) | (.[$k]? == true)' >/dev/null 2>&1
    return $?
  fi

  if command -v python3 &>/dev/null; then
    printf '%s' "$_hook_input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") if isinstance(d, dict) else None
sys.exit(0 if isinstance(ti, dict) and ti.get(sys.argv[1]) is True else 1)
' "$key" >/dev/null 2>&1
    return $?
  fi

  return 1
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
