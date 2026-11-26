#!/usr/bin/env bash
# _dup_guard.sh — 같은 FR·slug 의 다른 착수·발행을 찾는 공용 헬퍼 (source 전용).
#   promote.sh 가 새 착수 앞에서, publish_queue.sh 의 request 와 archive.sh 의 직접 실행이 발행 앞에서 부른다. 원격 조사(dup_scan)는 공유 ref 를 바꾸지 않는다 —
#   원격 추적 ref·FETCH_HEAD·태그 ref 를 만들거나 바꾸는 fetch 를 쓰지 않고, 판정은 ls-remote 의 OID 로 한다.
#   로컬 진행 확인(dup_local_inprogress)은 원격 모드와 상관없이 쓴다.
#   _rd_run_limited·rd_git_noprompt_env 가 정의돼 있지 않을 때만 각 정의 파일을 source 한다.
#   set -euo pipefail 아래에서 source 돼도 안전하다(실패 가능한 대입은 `|| rc=$?`).
#   bash 3.2: 연관 배열·mapfile 을 쓰지 않는다. 전역 이름은 dup_ / _dup_ / DUP_ 접두만 쓴다.
#   Spec: rd-workflow-workspace/specs/changes/2026-11-25-1218-fr-do-duplicate-start-guard-change-spec.md (D1·D2·D4)

_DUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -F _rd_run_limited >/dev/null 2>&1 || source "$_DUP_DIR/../_submodule_common.sh"
declare -F rd_git_noprompt_env >/dev/null 2>&1 || source "$_DUP_DIR/_merge_precheck.sh"
source "$_DUP_DIR/../_fr_status.sh"
declare -F normalize_slug >/dev/null 2>&1 || source "$_DUP_DIR/slug.sh"

_DUP_ITEMS_DIR="rd-workflow-workspace/backlog/items"
_DUP_TASK_STATE="rd-workflow-workspace/.lifecycle/task-state"

DUP_REMOTE_SLUG_OID=""
DUP_REMOTE_SLUG_LEFTOVER=""
DUP_DEF_OID=""
DUP_FOUND_OIDS=""
DUP_REMOTE_SLUG_OWN=""
DUP_DELETE_REMOTE_OID=""
DUP_SCAN_ROOT=""
# 발견 문장의 고정 머리 — dup_scan 의 printf 와 dup_stop_report 의 이름 파싱이 같은 값을 쓴다.
_DUP_CLAIM_HEAD="다른 clone 이 착수했습니다: 원격 fr/"

# dup_timeout — 원격 명령의 상한(초). RD_DUP_CHECK_TIMEOUT 이 양의 정수가 아니면 30.
dup_timeout() {
  local t="${RD_DUP_CHECK_TIMEOUT:-30}"
  case "$t" in ''|*[!0-9]*) t=30 ;; esac
  [[ "$t" -gt 0 ]] 2>/dev/null || t=30
  printf '%s\n' "$t"
}

# dup_timeout_hint <사유> — 사유가 시간 상한 초과(`…초 안에 끝나지 않았습니다`)일 때만 조정 방법을 한 줄(두 칸 들여쓰기)로 낸다.
dup_timeout_hint() {
  case "${1:-}" in
    *"초 안에 끝나지 않았습니다"*) printf '  시간 상한을 늘리려면 RD_DUP_CHECK_TIMEOUT=<초> 를 지정합니다(기본 30).\n' ;;
  esac
  return 0
}

# dup_stems_from_source_fr <source-fr 값> [<root> <커밋>] — `|` 구분 경로 목록(`-` 허용)에서 FR stem 을 줄마다 하나씩 낸다.
#   fr_relations.sh 의 ip_emit_state 와 같은 규칙이다(`${one##*/}` 에서 `.md` 제거).
#   <root>·<커밋> 을 주면 source_fr_split(_state_common.sh)과 같은 계약을 따른다: 값 전체가 그 커밋 트리에 있는 파일이면
#   원소 1개로 본다(파일 이름에 `|` 가 든 단일 경로를 찢지 않는다). 나누기는 read 로 한다 — 펼친 단어 분할은 `[`·`*` 를 glob 으로 펼친다.
dup_stems_from_source_fr() {
  local src="${1:--}" root="${2:-}" commit="${3:-}" one stem
  local -a parts=()
  if [[ -n "$root" && -n "$commit" && "$src" != "-" && "$src" != /* ]] \
    && git -C "$root" cat-file -e "${commit}:${src}" 2>/dev/null; then
    parts=("$src")
  else
    IFS='|' read -r -a parts <<<"$src" || true
  fi
  for one in ${parts[@]+"${parts[@]}"}; do
    stem="${one##*/}"; stem="${stem%.md}"
    case "$stem" in ''|-) continue ;; esac
    printf '%s\n' "$stem"
  done
}

# dup_local_inprogress <main-root> <stems> — 이 clone 에서 같은 FR 이 진행 중인지 본다(fr_relations.sh in-progress).
#   rc 0 없음 / 1 있음(stdout `local\t…` 줄) / 3 판정 불가(사유 stderr)
dup_local_inprogress() {
  local root="$1" stems="${2:-}" out="" rc=0 errf st stage hit=0 s
  [[ -n "$stems" ]] || return 0
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dup-ip.XXXXXX")" || { echo "임시 파일 생성 실패" >&2; return 3; }
  out="$(bash "$_DUP_DIR/../fr_relations.sh" in-progress --root "$root" 2>"$errf")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "로컬 진행 확인 실패: $(head -1 "$errf" 2>/dev/null)" >&2
    rm -f "$errf"
    return 3
  fi
  rm -f "$errf"
  while IFS=$'\t' read -r st stage; do
    [[ -n "$st" ]] || continue
    while IFS= read -r s; do
      [[ -n "$s" ]] || continue
      if [[ "$s" == "$st" ]]; then
        # 로컬 fr/<x> 가 없는 낡은 감시 목록 줄(`/fr do 줄기 <x>`)은 fr_relations.sh in-progress 가 이미 뺀다.
        printf 'local\t이 clone 에서 같은 FR 이 진행 중입니다: %s (단계: %s)\n' "$st" "$stage"
        hit=1
      fi
    done <<EOF
$stems
EOF
  done <<EOF
$out
EOF
  [[ "$hit" -eq 1 ]] && return 1
  return 0
}

# _dup_is_ancestor <조상 후보> <자손 후보> — 둘 다 로컬에 있고 조상(같음 포함)일 때만 0.
#   객체가 로컬에 없으면 git 이 실패하므로 조상이 아닌 것으로 본다.
_dup_is_ancestor() {
  local root="$1" a="$2" b="$3"
  [[ -n "$a" && -n "$b" ]] || return 1
  git -C "$root" merge-base --is-ancestor "$a" "$b" >/dev/null 2>&1
}

# _dup_fr_status <root> <oid> <stem> — 그 커밋의 FR 상세 status 첫 토큰. 파일이 없으면 빈 값.
_dup_fr_status() {
  local root="$1" oid="$2" stem="$3" body
  body="$(git -C "$root" show "${oid}:${_DUP_ITEMS_DIR}/${stem}.md" 2>/dev/null)" || return 0
  fr_status_awk_vars
  printf '%s\n' "$body" | awk "${FR_STATUS_AWK_ARGS[@]}" "$FR_STATUS_AWK"'
    BEGIN { frs_init(); frs_reset() }
    { frs_feed($0, NR) }
    END { print frs_value() }'
}

# _dup_task_source_fr <root> <커밋> — 그 커밋 task-state 의 source-fr 값. 없으면 빈 값.
_dup_task_source_fr() {
  git -C "$1" show "${2}:${_DUP_TASK_STATE}" 2>/dev/null \
    | awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,""); print; exit}'
}

# _dup_branch_stems <root> <R> <기준> — 원격 fr 브랜치의 Source FR stem 들(줄바꿈 구분).
#   끝 R 과, R 의 first-parent 이력 가운데 기준에 없고 task-state 를 바꾼 커밋들의 source-fr 를 모두 합친다.
#   착수 커밋이 그 목록에 들어 있으므로 PR 정리 커밋이 끝의 source-fr 를 비워도 착수 기록에서 읽는다.
_dup_branch_stems() {
  local root="$1" r="$2" base="$3" c all="" v
  v="$(_dup_task_source_fr "$root" "$r")"
  all="$(dup_stems_from_source_fr "${v:--}" "$root" "$r")"
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    v="$(_dup_task_source_fr "$root" "$c")"
    [[ -n "$v" ]] || continue
    all="${all}
$(dup_stems_from_source_fr "$v" "$root" "$c")"
  done <<EOF
$(git -C "$root" log --first-parent --format=%H "$r" ${base:+"^$base"} -- "$_DUP_TASK_STATE" 2>/dev/null)
EOF
  printf '%s\n' "$all" | awk 'NF && !seen[$0]++'
}

# _dup_tag_pr_head <root> <태그 객체 OID> — 태그 메시지의 `pr-head:` 값. 객체가 없거나 줄이 없으면 빈 값.
_dup_tag_pr_head() {
  git -C "$1" cat-file -p "$2" 2>/dev/null | sed -n 's/^pr-head:[[:space:]]*//p' | head -1
}

# _dup_tags_match_head <root> <끝 OID> <태그 줄> — `<태그 ref> <태그 객체 OID>` 줄 가운데 메시지의 pr-head 가
#   <끝 OID> 와 같은 것이 있으면 0. squash 발행 뒤 남은 브랜치를 가르는 증거다.
_dup_tags_match_head() {
  local root="$1" oid="$2" lines="$3" tg ov pr
  while IFS=' ' read -r tg ov; do
    [[ -n "$tg" ]] || continue
    pr="$(_dup_tag_pr_head "$root" "$ov")"
    if [[ -n "$pr" && "$pr" == "$oid" ]]; then return 0; fi
  done <<DUP_EOF
$lines
DUP_EOF
  return 1
}

# _dup_other_slug_leftover <root> <x> <끝 OID> — 다른 slug 의 원격 브랜치 x 가 squash 발행 뒤 남은 것인지 좁게 확인한다.
#   x 의 발행 태그만 ls-remote 로 묻고, 로컬에 없는 태그 객체만 받는다(태그 ref·원격 추적 ref·FETCH_HEAD 는 바꾸지 않는다).
#   남은 브랜치로 확인되면 0. 조회·받기가 실패하거나 증거가 없으면 1(판정을 바꾸지 않는다). RD_GIT_NOPROMPT_ENV 가 설정돼 있어야 한다.
_dup_other_slug_leftover() {
  local root="$1" x="$2" oid="$3" lim errf out rc=0 ref toid tags=""
  local -a want=()
  lim="$(dup_timeout)"
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dup-tag.XXXXXX")" || return 1
  out="$(_rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" ls-remote origin \
    "refs/tags/fr/*/${x}" "refs/tags/fr/*/${x}^{}")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then rm -f "$errf"; return 1; fi
  while IFS=$'\t' read -r toid ref; do
    [[ -n "$toid" && -n "$ref" ]] || continue
    case "$ref" in
      refs/tags/fr/*'^{}') ;;
      refs/tags/fr/*)
        tags="${tags}${ref} ${toid}
"
        git -C "$root" cat-file -e "$toid" 2>/dev/null || want+=("$ref") ;;
    esac
  done <<DUP_EOF
$out
DUP_EOF
  if [[ "${#want[@]}" -gt 0 ]]; then
    rc=0
    _rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" \
      fetch -q --no-tags --refmap= --no-write-fetch-head --recurse-submodules=no origin "${want[@]}" >/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then rm -f "$errf"; return 1; fi
  fi
  rm -f "$errf"
  _dup_tags_match_head "$root" "$oid" "$tags"
}

# dup_scan <root> <slug> <stems> <phase> [<기준 커밋>] — 원격 조사. phase = start | publish
#   기준 커밋은 publish 에서만 쓴다(비면 HEAD). archive.sh 는 기본 체크아웃에서 돌아 HEAD 가 기본 브랜치이므로 fr 끝을 넘긴다.
#   stdout: 발견마다 `<kind>\t<문장>` (kind = published | claimed | claimed-fr)
#   rc 0 발견 없음 / 1 발견 있음 / 3 조사 실패(사유 한 줄 stderr)
#   전역: DUP_REMOTE_SLUG_OID · DUP_REMOTE_SLUG_LEFTOVER · DUP_REMOTE_SLUG_OWN(원격 fr/<slug> 가 자기 것이면 1) ·
#         DUP_DEF_OID · DUP_FOUND_OIDS (`<x> <R>` 줄)
dup_scan() {
  local root="$1" slug="$2" stems="${3:-}" phase="${4:-start}" pub_base="${5:-}"
  local def lim errf out rc=0 oid ref x
  DUP_REMOTE_SLUG_OID=""; DUP_REMOTE_SLUG_LEFTOVER=""; DUP_DEF_OID=""; DUP_FOUND_OIDS=""; DUP_REMOTE_SLUG_OWN=""
  DUP_SCAN_ROOT="$root"

  def="$( project_root="$root"; get_default_branch 2>/dev/null )" || def=""
  [[ -n "$def" ]] || def="main"
  lim="$(dup_timeout)"
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dup-scan.XXXXXX")" || { echo "임시 파일 생성 실패" >&2; return 3; }

  # 1. ls-remote — 이 출력의 OID 로 판정한다.
  rd_git_noprompt_env "$root"
  out="$(_rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" ls-remote origin \
    "refs/heads/${def}" "refs/heads/fr/*" "refs/tags/fr/*/${slug}" "refs/tags/fr/*/${slug}^{}")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 124 ]]; then
      echo "원격 조회가 ${lim}초 안에 끝나지 않았습니다(ls-remote)" >&2
    else
      echo "원격 조회 실패(ls-remote): $(head -1 "$errf" 2>/dev/null)" >&2
    fi
    rm -f "$errf"
    return 3
  fi

  local def_oid="" branches="" tags="" peeled=""
  while IFS=$'\t' read -r oid ref; do
    [[ -n "$oid" && -n "$ref" ]] || continue
    case "$ref" in
      "refs/heads/${def}") def_oid="$oid" ;;
      refs/heads/fr/*) branches="${branches}${ref#refs/heads/fr/} ${oid}
" ;;
      refs/tags/fr/*'^{}') peeled="${peeled}${ref%'^{}'} ${oid}
" ;;
      refs/tags/fr/*) tags="${tags}${ref} ${oid}
" ;;
    esac
  done <<EOF
$out
EOF
  DUP_DEF_OID="$def_oid"
  local slug_oid=""
  slug_oid="$(printf '%s' "$branches" | awk -v s="$slug" '($1"")==(s""){print $2; exit}')"
  DUP_REMOTE_SLUG_OID="$slug_oid"

  # 2. 로컬에 없는 끝 객체만 한 번에 받는다(객체만 — 원격 추적 ref·FETCH_HEAD·태그 ref 는 바꾸지 않는다).
  local -a want=()
  if [[ -n "$def_oid" ]] && ! git -C "$root" cat-file -e "${def_oid}^{commit}" 2>/dev/null; then
    want+=("refs/heads/${def}")
  fi
  while IFS=' ' read -r x oid; do
    [[ -n "$x" ]] || continue
    git -C "$root" cat-file -e "${oid}^{commit}" 2>/dev/null || want+=("refs/heads/fr/${x}")
  done <<EOF
$branches
EOF
  # 같은 slug 의 태그 ref 는 pr-head 판정에 태그 메시지가 필요할 때만 받는다 — 원격 fr/<slug> 가 있고
  # 그 끝이 원격 기본 브랜치의 조상이 아닐 때다(둘 중 하나라도 로컬에 없으면 받은 뒤에야 알 수 있어 함께 받는다).
  if [[ -n "$slug_oid" ]] && ! _dup_is_ancestor "$root" "$slug_oid" "$def_oid"; then
    while IFS=' ' read -r ref oid; do
      [[ -n "$ref" ]] || continue
      git -C "$root" cat-file -e "$oid" 2>/dev/null || want+=("$ref")
    done <<EOF
$tags
EOF
  fi
  if [[ "${#want[@]}" -gt 0 ]]; then
    rc=0
    _rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" \
      fetch -q --no-tags --refmap= --no-write-fetch-head --recurse-submodules=no origin "${want[@]}" >/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      if [[ "$rc" -eq 124 ]]; then
        echo "원격 객체 받기가 ${lim}초 안에 끝나지 않았습니다(fetch)" >&2
      else
        echo "원격 객체 받기 실패(fetch): $(head -1 "$errf" 2>/dev/null)" >&2
      fi
      rm -f "$errf"
      return 3
    fi
  fi
  rm -f "$errf"

  # 기준 커밋: start 는 로컬 기본 브랜치 끝, publish 는 넘겨받은 기준 커밋(없으면 HEAD).
  local base="" local_tip=""
  if [[ "$phase" == "publish" ]]; then
    base="$(git -C "$root" rev-parse --verify -q "${pub_base:-HEAD}^{commit}" 2>/dev/null)" || base=""
  else
    base="$(git -C "$root" rev-parse --verify -q "refs/heads/${def}" 2>/dev/null)" || base=""
  fi
  local def_known=0
  [[ -n "$def_oid" ]] && git -C "$root" cat-file -e "${def_oid}^{commit}" 2>/dev/null && def_known=1

  # publish 에서 HEAD 가 원격 기본 브랜치의 조상이면 이미 이 작업이 발행된 것이다(부분 발행 뒤 재실행).
  if [[ "$phase" == "publish" && "$def_known" -eq 1 ]] && _dup_is_ancestor "$root" "$base" "$def_oid"; then
    return 0
  fi

  local found=0 stem st line tg tgt
  # (가) 원격 기본 브랜치에서 FR 이 done 이다.
  if [[ "$def_known" -eq 1 ]]; then
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      st="$(_dup_fr_status "$root" "$def_oid" "$stem")"
      if [[ "$st" == "done" ]]; then
        printf 'published\t다른 곳에서 발행했습니다: 원격 %s 에서 FR %s 이 done 입니다\n' "$def" "$stem"
        found=1
      fi
    done <<EOF
$stems
EOF
  fi
  # (나) 같은 slug 의 원격 태그 대상 커밋이 기준 커밋의 조상이 아니다. 태그 객체가 아니라 ^{} 값만 쓴다.
  while IFS=' ' read -r tg oid; do
    [[ -n "$tg" ]] || continue
    tgt="$(printf '%s' "$peeled" | awk -v t="$tg" '($1"")==(t""){print $2; exit}')"
    [[ -n "$tgt" ]] || tgt="$oid"
    if ! _dup_is_ancestor "$root" "$tgt" "$base"; then
      printf 'published\t같은 이름의 발행 태그가 원격에 있습니다: %s (이 작업에 없는 커밋)\n' "${tg#refs/tags/}"
      found=1
    fi
  done <<EOF
$tags
EOF

  # claimed / claimed-fr
  local own_start="" own_start_done="" own_tip="" leftover pr rstems kind ref_base author when fr_list ov
  if [[ "$phase" == "publish" ]]; then
    own_tip="$base"
  else
    own_tip="$(git -C "$root" rev-parse --verify -q "refs/heads/fr/${slug}" 2>/dev/null)" || own_tip=""
  fi
  if [[ "$def_known" -eq 1 ]]; then ref_base="$def_oid"; else ref_base="$(git -C "$root" rev-parse --verify -q "refs/heads/${def}" 2>/dev/null)" || ref_base=""; fi
  while IFS=' ' read -r x oid; do
    [[ -n "$x" ]] || continue
    # ① 발행 뒤 남은 브랜치가 아니다.
    leftover=0
    if [[ "$def_known" -eq 1 ]] && _dup_is_ancestor "$root" "$oid" "$def_oid"; then leftover=1; fi
    if [[ "$leftover" -eq 0 && "$x" == "$slug" ]]; then
      _dup_tags_match_head "$root" "$oid" "$tags" && leftover=1
    fi
    if [[ "$leftover" -eq 1 ]]; then
      [[ "$x" == "$slug" ]] && DUP_REMOTE_SLUG_LEFTOVER=1
      continue
    fi
    # ② 자기 것이 아니다.
    #    원격 끝 R 이 로컬 끝의 조상이거나, 이 작업의 착수 커밋 S 가 R 의 조상이면 자기 것이다
    #    (발행이 R 을 앞서 올린 뒤 로컬이 되돌아간 경우). S 를 못 구하면 앞의 규칙만 쓴다.
    if [[ "$x" == "$slug" ]]; then
      if _dup_is_ancestor "$root" "$oid" "$own_tip"; then
        DUP_REMOTE_SLUG_OWN=1
        continue
      fi
      if [[ -z "$own_start_done" ]]; then
        own_start="$(dup_start_commit "$root" "$slug" 2>/dev/null)" || own_start=""
        own_start_done=1
      fi
      if _dup_is_ancestor "$root" "$own_start" "$oid"; then
        DUP_REMOTE_SLUG_OWN=1
        continue
      fi
    fi
    # ③ 겹친다.
    rstems=""
    if [[ "$x" == "$slug" ]]; then
      kind="claimed"
      rstems="$(_dup_branch_stems "$root" "$oid" "$ref_base")"
    else
      kind="claimed-fr"
      [[ -n "$stems" ]] || continue
      rstems="$(_dup_branch_stems "$root" "$oid" "$ref_base")"
      printf '%s\n' "$rstems" | grep -qxFf <(printf '%s\n' "$stems") || continue
      # 다른 slug 의 브랜치가 squash 발행 뒤 남은 것이면(그 slug 태그의 pr-head 가 끝과 같음) 건너뛴다.
      #   후보가 있을 때만 원격을 한 번 더 묻고, 확인이 실패하면 판정을 바꾸지 않는다.
      _dup_other_slug_leftover "$root" "$x" "$oid" && continue
    fi
    author="$(git -C "$root" log -1 --format='%an' "$oid" 2>/dev/null)" || author="?"
    when="$(git -C "$root" log -1 --date=format:'%Y-%m-%d %H:%M' --format='%ad' "$oid" 2>/dev/null)" || when="?"
    fr_list="$(printf '%s\n' "$rstems" | awk 'NF' | paste -sd, - )"
    [[ -n "$fr_list" ]] || fr_list="-"
    printf '%s\t%s%s (끝 %s, 마지막 커밋 %s %s, FR %s)\n' \
      "$kind" "$_DUP_CLAIM_HEAD" "$x" "${oid:0:7}" "$author" "$when" "$fr_list"
    DUP_FOUND_OIDS="${DUP_FOUND_OIDS}${x} ${oid}
"
    found=1
  done <<EOF
$branches
EOF
  [[ "$found" -eq 1 ]] && return 1
  return 0
}

# _dup_main_checkout <root> — 기본 체크아웃(첫 worktree) 경로를 stdout 으로. 못 얻으면 빈 값.
#   rollback 은 작업 worktree 안에서 자기 자신을 지울 수 없으므로 안내 명령을 그 경로로 옮겨 실행하게 한다.
_dup_main_checkout() {
  git -C "${1:-.}" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1
}

# dup_stop_report <slug> <발견 줄...> — 멈춤 출력(머리 줄·발견 줄·종류별 다음 행동)을 stderr 로 낸다.
#   발견 줄은 `<kind>\t<문장>`. claimed·claimed-fr 의 원격 이름 x 는 문장의 `원격 fr/<x> (` 에서 읽고,
#   원격 끝 R 은 DUP_FOUND_OIDS 에서 찾는다.
dup_stop_report() {
  local slug="$1" line kind text x r acts="" act findings stage qlease qdel qfetch okslug mainwt qmain cmdr
  shift
  # 인자 하나에 여러 줄이 들어 와도(dup_scan stdout 통째) 줄마다 발견 한 건으로 처리한다.
  findings="$(printf '%s\n' "$@")"
  {
    printf "promote: 중복 착수 — '%s' 를 시작하지 않았습니다 (상태 변경 없음).\n" "$slug"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '  - %s\n' "${line#*$'\t'}"
    done <<DUP_EOF
$findings
DUP_EOF
    printf '  다음 행동:\n'
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      kind="${line%%$'\t'*}"; text="${line#*$'\t'}"
      case "$kind" in
        claimed|claimed-fr)
          # 이름은 문장 맨 앞의 고정 머리 바로 뒤에서 읽는다. 작성자명처럼 뒤쪽 칸의 글자는 읽지 않는다.
          case "$text" in
            "$_DUP_CLAIM_HEAD"*) x="${text#"$_DUP_CLAIM_HEAD"}"; x="${x%% *}" ;;
            *) x="" ;;
          esac
          [[ -n "$x" ]] || continue
          r="$(printf '%s' "$DUP_FOUND_OIDS" | awk -v x="$x" '($1"")==(x""){print $2; exit}')"
          # 원격에서 온 이름·OID 는 복사 명령에 넣기 전에 셸 인용한다(slug 형식이면 출력이 그대로다).
          qlease="$(printf '%q' "refs/heads/fr/${x}:${r}")"
          qdel="$(printf '%q' ":refs/heads/fr/${x}")"
          qfetch="$(printf '%q' "fr/${x}:fr/${x}")"
          if [[ "$(normalize_slug "$x" 2>/dev/null)" == "$x" ]]; then okslug=1; else okslug=0; fi
          if git -C "${DUP_SCAN_ROOT:-.}" rev-parse --verify -q "refs/heads/fr/${x}" >/dev/null 2>&1; then
            # 이 clone 에 같은 이름의 로컬 작업이 있으면 fetch 가 실패하므로 그 작업을 먼저 정리하게 안내한다.
            act="  이 clone 에도 같은 이름의 작업 fr/${x} 가 있습니다. 같은 이름의 두 작업은 하나만 발행할 수 있습니다."
            if [[ "$okslug" -eq 1 ]]; then
              # rollback 은 작업 worktree 안에서 자기 자신을 지울 수 없으므로 기본 체크아웃으로 옮겨 실행하는 한 줄로 낸다.
              mainwt="$(_dup_main_checkout "${DUP_SCAN_ROOT:-.}")"
              if [[ -n "$mainwt" ]]; then
                qmain="$(printf '%q' "$mainwt")"
                act="${act}
  이 clone 의 작업을 버리고 그 작업을 이어 가려면(기본 체크아웃에서 실행합니다): cd ${qmain} && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ${x} && git fetch origin ${qfetch} && bash rd-workflow/scripts/lifecycle/promote.sh --short-title ${x} --size small"
              else
                act="${act}
  이 clone 의 작업을 버리고 그 작업을 이어 가려면(기본 체크아웃에서 실행합니다): bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ${x} && git fetch origin ${qfetch} && bash rd-workflow/scripts/lifecycle/promote.sh --short-title ${x} --size small"
              fi
            else
              act="${act}
  원격 브랜치 이름 fr/${x} 는 이 도구가 만든 작업 이름이 아니라 이어 가기 명령을 내지 않습니다."
            fi
            act="${act}
  이 clone 의 작업을 남기려면(그 착수를 버린 것이 확실할 때): git push --no-follow-tags --force-with-lease=${qlease} origin ${qdel} 뒤 같은 명령을 다시 실행"
          elif [[ "$okslug" -eq 1 ]]; then
            act="  그 작업을 이 clone 에서 이어 가려면: git fetch origin ${qfetch} 뒤 bash rd-workflow/scripts/lifecycle/promote.sh --short-title ${x} --size small
  그 착수를 버린 것이 확실하면: git push --no-follow-tags --force-with-lease=${qlease} origin ${qdel} 뒤 같은 명령을 다시 실행"
          else
            act="  원격 브랜치 이름 fr/${x} 는 이 도구가 만든 작업 이름이 아니라 이어 가기 명령을 내지 않습니다.
  그 착수를 버린 것이 확실하면: git push --no-follow-tags --force-with-lease=${qlease} origin ${qdel} 뒤 같은 명령을 다시 실행"
          fi ;;
        published)
          act="  기본 브랜치를 원격에 맞춘 뒤(git pull) FR 상태를 확인하십시오. 이미 발행된 작업입니다.
  로컬에서 FR 을 다시 열었다면 기본 브랜치를 원격에 올린 뒤 다시 실행합니다." ;;
        local)
          # 단계 칸이 `/fr do 줄기 <slug>` 면 작업 색인이 아니라 /fr do 의 active.tsv 에서 온 것이다.
          stage="$(printf '%s' "$text" | sed -n 's/.*(단계: \(.*\))$/\1/p')"
          case "$stage" in
            "/fr do 줄기 "*)
              x="${stage#/fr do 줄기 }"
              if [[ "$(normalize_slug "$x" 2>/dev/null)" == "$x" ]]; then
                mainwt="$(_dup_main_checkout "${DUP_SCAN_ROOT:-.}")"
                if [[ -n "$mainwt" ]]; then
                  cmdr="cd $(printf '%q' "$mainwt") && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ${x}"
                else
                  cmdr="bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task ${x}"
                fi
                # 감시 목록(active.tsv)을 고치는 명령(close.sh 포함)은 안내하지 않는다 — 다른 탭의 줄기 등록과 겹치면 기록이 사라진다.
                #   되돌려 로컬 fr/<x> 가 없어지면 그 줄은 위 판정이 건너뛴다.
                act="  /fr do 줄기 ${x} 가 이 clone 에서 진행 중입니다(로컬 브랜치 fr/${x} 가 있음). 그 줄기를 이어 가거나, 버리려면 기본 체크아웃에서 ${cmdr} 로 되돌린 뒤 같은 명령을 다시 실행합니다(되돌리면 이 중복 확인은 감시 목록의 그 줄을 건너뜁니다. /fr do 의 후보 선정도 그 줄을 낡은 줄(stale)로 보고 보류하지 않으며, 호출 세션이 정리합니다)."
              else
                act="  /fr do 줄기 $(printf '%q' "$x") 가 이 clone 에서 진행 중입니다(로컬 브랜치 fr/$(printf '%q' "$x") 가 있음). 이 도구가 만든 줄기 이름이 아니라 되돌리기 명령을 내지 않습니다."
              fi ;;
            *)
              act="  이 FR 을 진행 중인 작업의 slug 는 bash rd-workflow/scripts/rd task list 에서 확인합니다(FR 열이 같은 작업).
  그 작업을 이어 가거나, 버리려면 bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task <그 slug> 로 되돌린 뒤 같은 명령을 다시 실행" ;;
          esac ;;
        *) continue ;;
      esac
      case "
$acts
" in *"
$act
"*) ;; *) acts="${acts}${act}
"; printf '%s\n' "$act" ;; esac
    done <<DUP_EOF
$findings
DUP_EOF
  } >&2
  return 0
}

# dup_start_commit <root> <slug> — 착수 커밋 OID 를 stdout 으로 낸다(spec D3).
#   refs/heads/fr/<slug> 의 first-parent 이력에서 <base> 에 없는 첫 커밋. <base> 는 그 브랜치 task-state 의
#   base-commit, 없거나 null 이면 로컬 기본 브랜치와의 merge-base. 못 구하면 rc 1.
dup_start_commit() {
  local root="$1" slug="$2" ref base def list first
  ref="refs/heads/fr/${slug}"
  git -C "$root" rev-parse --verify -q "$ref" >/dev/null 2>&1 || return 1
  base="$(git -C "$root" show "${ref}:${_DUP_TASK_STATE}" 2>/dev/null \
    | awk -F'=' '$1=="base-commit"{sub(/^[^=]+=/,""); print; exit}')" || base=""
  case "$base" in ''|null|-) base="" ;; esac
  if [[ -n "$base" ]] && ! git -C "$root" cat-file -e "${base}^{commit}" 2>/dev/null; then base=""; fi
  if [[ -z "$base" ]]; then
    def="$( project_root="$root"; get_default_branch 2>/dev/null )" || def=""
    [[ -n "$def" ]] || def="main"
    base="$(git -C "$root" merge-base "refs/heads/${def}" "$ref" 2>/dev/null)" || base=""
  fi
  [[ -n "$base" ]] || return 1
  list="$(git -C "$root" rev-list --first-parent --reverse "$ref" "^${base}" 2>/dev/null)" || return 1
  first="${list%%$'\n'*}"
  [[ -n "$first" ]] || return 1
  printf '%s\n' "$first"
}

# dup_claim_push <root> <slug> <oid> [<replace-oid>] — 착수 표시: 원격 fr/<slug> 에 <oid> 를 올린다(spec D3).
#   rc 0 올림 / 1 거부(원격에 <oid> 의 조상이 아닌 끝이 있음 — 다른 이력이 먼저 올라감, 또는 lease 거부) /
#   3 그 밖의 실패(사유 한 줄 stderr). 항상 --no-follow-tags. <replace-oid> 를 주면 그 OID 의 lease 로만 교체한다.
dup_claim_push() {
  local root="$1" slug="$2" oid="$3" repl="${4:-}"
  local lim errf rc=0 ref="refs/heads/fr/${slug}" cur out why
  lim="$(dup_timeout)"
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dup-push.XXXXXX")" || { echo "임시 파일 생성 실패" >&2; return 3; }
  rd_git_noprompt_env "$root"
  if [[ -n "$repl" ]]; then
    _rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" push -q --no-follow-tags --recurse-submodules=no \
      "--force-with-lease=${ref}:${repl}" origin "${oid}:${ref}" >/dev/null || rc=$?
  else
    _rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" push -q --no-follow-tags --recurse-submodules=no \
      origin "${oid}:${ref}" >/dev/null || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then rm -f "$errf"; return 0; fi
  if [[ "$rc" -eq 124 ]]; then
    echo "원격 push 가 ${lim}초 안에 끝나지 않았습니다" >&2
    rm -f "$errf"; return 3
  fi
  why="$(head -1 "$errf" 2>/dev/null)"
  # 실패 사유를 가린다 — 원격 끝을 다시 읽어, 다른 이력이 있으면 거부(1), 그 밖은 3.
  rc=0
  out="$(_rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" ls-remote origin "$ref")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "원격 push 실패: ${why}" >&2
    rm -f "$errf"; return 3
  fi
  rm -f "$errf"
  cur="${out%%$'\t'*}"
  if [[ -n "$cur" ]]; then
    if [[ -n "$repl" && "$cur" != "$repl" ]]; then return 1; fi
    if [[ -z "$repl" ]] && ! _dup_is_ancestor "$root" "$cur" "$oid"; then return 1; fi
  fi
  echo "원격 push 실패: ${why}" >&2
  return 3
}

# dup_claim_report <rc> <slug> <oid> <사유> [<replaced-oid>] [<ahead-n>] — push 결과를 사람용 줄로 낸다.
#   반환 0 계속 / 1 멈춤(호출부는 exit 1). ahead-n: 숫자(원격 기본 브랜치에 없는 커밋 수) 또는 all.
dup_claim_report() {
  local rc="$1" slug="$2" oid="$3" why="${4:-}" repl="${5:-}" ahead="${6:-}" msg mainwt
  case "$rc" in
    0)
      msg="promote: 착수 표시 — origin 의 fr/${slug} 에 착수 커밋(${oid:0:7})을 올렸습니다. 다른 clone 이 같은 작업을 착수하면 멈춥니다."
      [[ -n "$repl" ]] && msg="${msg} 발행 뒤 남은 원격 fr/${slug}(${repl:0:7})를 바꿨습니다."
      case "$ahead" in
        all) msg="${msg} 원격에 기본 브랜치가 없어 이 브랜치의 이력 전체가 올라갔습니다." ;;
        ''|*[!0-9]*) ;;
        *) [[ "$ahead" -ge 1 ]] && msg="${msg} 원격 기본 브랜치에 없는 커밋 ${ahead}개가 함께 올라갔습니다(발행 때 기본 브랜치에도 올라갈 커밋)." ;;
      esac
      printf '%s\n' "$msg"
      return 0 ;;
    1)
      {
        printf "promote: 중복 착수 — 다른 clone 이 같은 이름(fr/%s)으로 먼저 착수 표시를 올렸습니다. 세션을 띄우지 않았습니다.\n" "$slug"
        mainwt="$(_dup_main_checkout "${DUP_SCAN_ROOT:-.}")"
        if [[ -n "$mainwt" ]]; then
          printf '  되돌리기(기본 체크아웃에서 실행합니다): cd %q && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s\n' "$mainwt" "$slug"
        else
          printf '  되돌리기(기본 체크아웃에서 실행합니다): bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s\n' "$slug"
        fi
      } >&2
      return 1 ;;
    *)
      printf 'promote: 중복 확인 경고 — 착수 표시를 원격에 올리지 못했습니다(%s). 다른 clone 은 이 착수를 모릅니다. 같은 promote 명령을 다시 실행하면 다시 시도합니다.\n' "$why" >&2
      dup_timeout_hint "$why" >&2
      return 0 ;;
  esac
}

# dup_claim_delete <root> <slug> <local-tip-oid> — 원격 fr/<slug> 가 이 작업의 커밋(local-tip 의 조상, 같음 포함)일 때만 지운다.
#   rc 0 지움 또는 원격에 없음 / 1 다른 이력이라 남김 / 3 실패(사유는 stderr 한 줄).
#   DUP_DELETE_REMOTE_OID: 읽은 원격 끝(못 읽었으면 빈 값). 안내 명령에 쓴다. lease 로만 지운다(spec D6).
dup_claim_delete() {
  local root="$1" slug="$2" tip="$3"
  local lim errf rc=0 ref="refs/heads/fr/${slug}" out r why
  DUP_DELETE_REMOTE_OID=""
  lim="$(dup_timeout)"
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dup-del.XXXXXX")" || { echo "임시 파일 생성 실패" >&2; return 3; }
  rd_git_noprompt_env "$root"
  out="$(_rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" ls-remote origin "$ref")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 124 ]]; then echo "원격 조회가 ${lim}초 안에 끝나지 않았습니다" >&2
    else echo "원격 조회 실패: $(head -1 "$errf" 2>/dev/null)" >&2; fi
    rm -f "$errf"; return 3
  fi
  r="${out%%$'\t'*}"
  [[ -n "$r" ]] || { rm -f "$errf"; return 0; }
  DUP_DELETE_REMOTE_OID="$r"
  if ! git -C "$root" cat-file -e "${r}^{commit}" 2>/dev/null || ! _dup_is_ancestor "$root" "$r" "$tip"; then
    rm -f "$errf"; return 1
  fi
  rc=0
  _rd_run_limited "$lim" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$root" push -q --no-follow-tags --recurse-submodules=no \
    "--force-with-lease=${ref}:${r}" origin ":${ref}" >/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then rm -f "$errf"; return 0; fi
  if [[ "$rc" -eq 124 ]]; then echo "원격 삭제가 ${lim}초 안에 끝나지 않았습니다" >&2
  else why="$(head -1 "$errf" 2>/dev/null)"; echo "원격 삭제 실패: ${why}" >&2; fi
  rm -f "$errf"; return 3
}
