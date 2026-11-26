#!/usr/bin/env bash
# _direct_pr_common.sh — 직접 설치 PR 발행(archive_publish=pr)의 공용 판정·커밋 함수.
#   archive.sh · rd pr (open·check·reopen) · rd task list·status 가 이 이름 그대로 부릅니다.
#   Spec: rd-workflow-workspace/specs/changes/2026-11-17-1710-direct-install-publish-via-pull-request-change-spec.md (D1·D3a·D4·D5·D6)
#
# 이 파일은 source 되기만 합니다. 부르는 쪽이 먼저 아래 순서로 source 해야 합니다.
#   1~5. _team_publish_common.sh 머리 주석의 순서(_lifecycle_common.sh … _team_publish_common.sh)
#   6.   team_publish.sh   (tp_pr_title·tp_extract_pr_body — BASH_SOURCE 가드가 있어 source 해도 실행되지 않음)
#   7.   이 파일
#
# 종료 코드: 성공 0, 실패 1, 판정 불가·설정 오류 2.
# 저장소는 `project_root`(없으면 cwd)가 정합니다(dpr_origin_repo·dpr_is_published_cleanup·dpr_pr_waiting).
#
# bash 3.2 호환: 연관 배열·${var,,} 를 쓰지 않고, 같은 local 문 안에서 앞 변수를 참조하지 않는다.

_DPR_LC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 기록 파일 해소 규칙(rd_merge_resolve_record)·자동 해소 대상 경로는 _merge_precheck.sh 에 있습니다. archive.sh 는 이미 싣고,
# direct_pr.sh·team_publish.sh·rd 는 싣지 않으므로 여기서 실어 둡니다(이미 실려 있으면 다시 싣지 않음).
if ! declare -F rd_merge_resolve_record >/dev/null 2>&1; then
  source "$_DPR_LC_DIR/_merge_precheck.sh"
fi

_dpr_root() { printf '%s\n' "${project_root:-$PWD}"; }

# dpr_archive_mode <root> <commit> — stdout `push`|`pr`.
# <commit> 의 rd-workflow/config/workflow.json 에 archive_publish 키가 없거나 파일이 없으면 push.
# 허용 값 밖·JSON 오류·최상위가 객체가 아님·커밋을 읽을 수 없음은 rc 2 (조용히 push 로 흡수하지 않음).
dpr_archive_mode() {
  local root="${1:?root}" commit="${2:?commit}" json rc
  if ! git -C "$root" rev-parse --verify -q "${commit}^{commit}" >/dev/null 2>&1; then
    printf 'archive_publish 설정 오류: 커밋을 읽을 수 없습니다: %s\n' "$commit" >&2
    return 2
  fi
  if ! git -C "$root" cat-file -e "${commit}:rd-workflow/config/workflow.json" 2>/dev/null; then
    printf 'push\n'; return 0
  fi
  json="$(git -C "$root" show "${commit}:rd-workflow/config/workflow.json" 2>/dev/null)" || {
    printf 'archive_publish 설정 오류: workflow.json 을 읽을 수 없습니다\n' >&2; return 2; }
  printf '%s' "$json" | python3 -I -c '
import json, sys
def bad(msg):
    sys.stderr.write("archive_publish 설정 오류: %s\n" % msg); sys.exit(2)
try:
    d = json.load(sys.stdin)
except Exception:
    bad("workflow.json 을 읽을 수 없습니다")
if not isinstance(d, dict):
    bad("workflow.json 최상위가 객체가 아닙니다")
if "archive_publish" not in d:
    print("push"); sys.exit(0)
v = d["archive_publish"]
if v not in ("push", "pr"):
    bad("archive_publish 값 %r 은 허용 값 push|pr 이 아닙니다" % (v,))
print(v)
'
  rc=$?
  [[ "$rc" == 0 ]] || return 2
  return 0
}

# dpr_origin_repo — origin 의 `owner/repo`. https://host/owner/repo(.git)·ssh://…/owner/repo·git@host:owner/repo(.git) 는
# 앞의 호스트를 떼고, 로컬 경로는 경로 그대로 냅니다. origin 이 없으면 rc 1.
# insteadOf 를 풀지 않도록 `git config --get remote.origin.url` 을 읽습니다.
dpr_origin_repo() {
  local u
  u="$(git -C "$(_dpr_root)" config --get remote.origin.url 2>/dev/null)" || return 1
  [[ -n "$u" ]] || return 1
  u="${u%/}"; u="${u%.git}"
  case "$u" in
    http://*|https://*|ssh://*|git://*)
      u="${u#*://}"; u="${u#*/}" ;;
    /*|./*|../*|file://*) ;;
    *@*:*) u="${u#*:}" ;;
  esac
  [[ -n "$u" ]] || return 1
  printf '%s\n' "$u"
}

# dpr_index_get <slug> <key> / dpr_index_set <slug> key=val... — 작업 색인의 얇은 래퍼
# (키: pr-mode pr-head pr-base pr-url pr-sent pr-verified). pr-sent 는 P9 가 성공한 발행의 head 입니다.
# pr-verified 는 dpr_verified_add 로만 더합니다(목록이 줄지 않게 락 안에서 합집합).
dpr_index_get() { tasks_index_get "$1" "$2"; }
# 색인은 공유 파일 전체를 다시 쓰므로(tasks_index_upsert) 다른 lifecycle 명령과 같은 tasks 락 안에서 씁니다.
# archive.sh 는 이미 락을 쥐고 이 함수를 부릅니다(ARCHIVE_LOCK_HELD=1, 락은 재진입하지 않음).
# 그 밖의 호출(rd pr open·check --apply)은 점유 중이면 RD_DPR_LOCK_WAIT 초(기본 30)까지 1초 간격으로 기다립니다.
dpr_index_set() {
  if [[ "${ARCHIVE_LOCK_HELD:-0}" == 1 ]]; then tasks_index_upsert "$@"; return; fi
  local rc
  _dpr_index_lock "$1" "${*:2}" || return 1
  rc=0; tasks_index_upsert "$@" || rc=$?
  tasks_lock_release >/dev/null 2>&1 || true
  return "$rc"
}

# _dpr_index_lock <slug> <안내용 기록 내용> — dpr_index_set 의 락 대기 규칙(RD_DPR_LOCK_WAIT 초, 1초 간격)으로 tasks 락을 잡습니다.
# 잡지 못하면 점유자 정보와 WARNING 을 stderr 에 내고 rc 1. 잡으면 부르는 쪽이 tasks_lock_release 로 놓습니다.
_dpr_index_lock() {
  local i rc=1 max="${RD_DPR_LOCK_WAIT:-30}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=30
  for ((i = 0; i < max; i++)); do
    rc=0; tasks_lock_acquire direct-pr "$1" >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 1 ]] || break
    sleep 1
  done
  if [[ "$rc" != 0 ]]; then
    # 마지막 시도는 점유자 정보를 stderr 로 보입니다.
    rc=0; tasks_lock_acquire direct-pr "$1" >/dev/null || rc=$?
    if [[ "$rc" != 0 ]]; then
      printf 'WARNING — 다른 lifecycle 명령이 작업 색인을 쓰고 있어 기록하지 못했습니다(%s)\n' "$2" >&2
      return 1
    fi
  fi
  return 0
}

# dpr_verified_has <slug> <oid> — rc 0 이면 색인 pr-verified(rd pr sync 가 검증한 head 목록, 공백 구분 OID)에 그 OID 가 있음.
dpr_verified_has() {
  local oid="${2:-}" l w
  [[ -n "$oid" ]] || return 1
  l="$(dpr_index_get "$1" pr-verified 2>/dev/null)" || l=""
  for w in $l; do [[ "$w" == "$oid" ]] && return 0; done
  return 1
}

# dpr_verified_add <slug> <oid>... — pr-verified 에 OID 를 더합니다(합집합, 지우지 않음 — spec D4).
# 읽기 → 합집합 → 쓰기를 한 tasks 락 안에서 합니다(다른 명령의 색인 쓰기와 섞여 목록이 줄지 않게). ARCHIVE_LOCK_HELD=1 이면 락을 다시 잡지 않습니다.
# 실패 rc 1 (OID 형식 오류·락 점유·쓰기 실패).
dpr_verified_add() {
  local slug="${1:?slug}" o w cur new found rc=0 held=0
  shift
  for o in "$@"; do [[ "$o" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || { printf 'dpr_verified_add: OID 형식이 아닙니다: %s\n' "$o" >&2; return 1; }; done
  if [[ "${ARCHIVE_LOCK_HELD:-0}" != 1 ]]; then
    _dpr_index_lock "$slug" "pr-verified" || return 1
    held=1
  fi
  cur="$(tasks_index_get "$slug" pr-verified 2>/dev/null)" || cur=""
  new="$cur"
  for o in "$@"; do
    found=0
    for w in $new; do [[ "$w" == "$o" ]] && { found=1; break; }; done
    [[ "$found" == 1 ]] || new="${new:+$new }$o"
  done
  tasks_index_upsert "$slug" "pr-verified=$new" || rc=1
  [[ "$held" == 1 ]] && { tasks_lock_release >/dev/null 2>&1 || true; }
  return "$rc"
}

# _dpr_cleanup_subject <slug> — D4 의 되돌리기 커밋 메시지.
_dpr_cleanup_subject() { printf 'chore(lifecycle): archive %s metadata 정리\n' "$1"; }

# dpr_is_published_cleanup <fr-branch> <slug> — fr tip 이 「rd 가 발행한 head」인지(spec D6 (라), change spec 2026-11-19-1430 D4).
# (가)~(다)는 dpr_published_head 가 봅니다 — 되돌리기 커밋 하나이거나, 그 위에 rd pr sync 가 만든 동기화 병합이 이어진 사슬.
# (라) origin 의 fr 브랜치가 tip 과 같음.
# rc 0 맞음(전역 _DPR_CLEANUP_OID 에 사슬 끝 되돌리기 커밋 OID) / 1 아님 / 2 판정 불가(fr 브랜치 없음·원격 조회 실패·병합 대조 불가,
# 동기화 병합을 따라갈 때 기본 브랜치 미정). 기본 브랜치는 dpr_published_head 가 동기화 병합을 볼 때만 구합니다 — 단일 되돌리기 커밋은 기본 브랜치 없이 판정합니다.
# 사슬 판정을 통과하면 (라)의 결과와 상관없이 전역 _DPR_CHAIN_OID 에 사슬 끝 되돌리기 커밋을 둡니다(재실행 안내용).
# 사슬 판정이 판정 불가이면 그 사유 한 줄을 전역 _DPR_PUBLISHED_WHY 에 두고 stderr 에도 냅니다(예: 병합 설정 때문에 대조 불가).
_DPR_CLEANUP_OID=""; _DPR_CHAIN_OID=""; _DPR_PUBLISHED_WHY=""
dpr_is_published_cleanup() {
  local fr="${1:?fr-branch}" slug="${2:?slug}" root tip remote cl errf rc=0
  _DPR_CLEANUP_OID=""; _DPR_CHAIN_OID=""; _DPR_PUBLISHED_WHY=""
  root="$(_dpr_root)"
  tip="$(git -C "$root" rev-parse --verify -q "refs/heads/${fr}^{commit}" 2>/dev/null)" || return 2
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dprph.XXXXXX" 2>/dev/null)" || errf=""
  cl="$(dpr_published_head "$root" "$tip" "$slug" "" 2>"${errf:-/dev/null}")" || rc=$?
  if [[ -n "$errf" ]]; then
    [[ "$rc" == 2 ]] && _DPR_PUBLISHED_WHY="$(head -1 "$errf")"
    rm -f "$errf"
  fi
  if [[ "$rc" != 0 ]]; then
    [[ -n "$_DPR_PUBLISHED_WHY" ]] && printf '%s\n' "$_DPR_PUBLISHED_WHY" >&2
    return "$rc"
  fi
  _DPR_CHAIN_OID="$cl"
  # (라)
  remote="$(git -C "$root" ls-remote origin "refs/heads/${fr}" 2>/dev/null)" || rc=$?
  [[ "$rc" == 0 ]] || return 2
  remote="${remote%%[[:space:]]*}"
  [[ -n "$remote" && "$remote" == "$tip" ]] || return 1
  _DPR_CLEANUP_OID="$cl"
  return 0
}

# _dpr_cleanup_shape <root> <commit> <slug> — dpr_is_published_cleanup 의 (가)~(다). rc 0 맞음 / 1 아님 / 2 판정 불가.
_dpr_cleanup_shape() {
  local root="$1" tip="$2" slug="$3" parents subj pst changed p allowed
  # (가)
  subj="$(git -C "$root" log -1 --format=%s "$tip" 2>/dev/null)" || return 2
  [[ "$subj" == "$(_dpr_cleanup_subject "$slug")" ]] || return 1
  # (나)
  parents="$(git -C "$root" rev-list --parents -n 1 "$tip" 2>/dev/null)" || return 2
  set -- $parents
  [[ "$#" -eq 2 ]] || return 1
  pst="$(git -C "$root" show "$2:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null \
    | awk -F= '$1=="status"{sub(/^[^=]+=/,""); print; exit}')"
  [[ "$pst" == "아카이브 보류" ]] || return 1
  # (다)
  changed="$(git -C "$root" diff-tree --no-commit-id --name-only -r --no-renames --ignore-submodules=none "$tip" 2>/dev/null)" || return 2
  allowed="$(lifecycle_metadata_paths)
$RD_TEAM_PR_RECORD"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "
$allowed
" in *"
$p
"*) ;; *) return 1 ;; esac
  done <<EOF_DPR
$changed
EOF_DPR
  return 0
}

# ---------------------------------------------------------------------------
# rd pr sync 의 병합 트리 계산과 검증 사슬 (change spec 2026-11-19-1430 D3·D4)
# ---------------------------------------------------------------------------

# _dpr_sync_subject <기본 브랜치> <fr 브랜치> — 동기화 병합 커밋의 제목 한 줄.
_dpr_sync_subject() { printf 'merge: %s into %s (rd pr sync)\n' "$1" "$2"; }

# 트리 결과에 영향을 주지 않는 merge.* 설정 키(소문자). 이 밖의 키가 있으면 dpr_sync_tree 는 판정 불가(rc 3)입니다.
_DPR_SYNC_MERGE_KEYS_OK=" merge.conflictstyle merge.ff merge.log merge.stat merge.tool merge.guitool merge.autostash merge.verbosity merge.verifysignatures merge.branchdesc merge.suppressdest "

# dpr_sync_tree <root> <작업 커밋> <기본 커밋> — 두 커밋을 git 내장 3-way 병합으로 합친 트리를 계산하고,
# 자동 해소 대상 다섯 경로(RD_MERGE_AUTO_RESOLVE_PATHS)의 충돌만 rd_merge_resolve_record 로 풉니다.
#   rc 0 stdout 트리 OID / rc 1 자동 해소 대상 밖 충돌(stdout 경로 목록, 한 줄에 하나) / rc 3 판정 불가(stderr 사유 한 줄).
#   0단계(지원 조건): 병합 동작을 바꾸는 merge.* 설정이나, 어느 한쪽이라도 바꾼 경로의 merge 속성이 있으면 rc 3 —
#   git 내장 병합 밖의 규칙이 충돌을 조용히 풀어 리뷰하지 않은 내용이 트리에 들어가는 일을 막습니다.
#   저장소의 index·작업 트리는 건드리지 않습니다(임시 index 만 씀).
dpr_sync_tree() {
  local root="${1:?root}" work="${2:?작업 커밋}" base_c="${3:?기본 커밋}" td rc
  td="$(mktemp -d "${TMPDIR:-/tmp}/rd-dpst.XXXXXX")" || { printf '임시 디렉터리를 만들 수 없어 자동 병합을 계산할 수 없습니다\n' >&2; return 3; }
  rc=0; _dpr_sync_tree_in "$root" "$work" "$base_c" "$td" || rc=$?
  rm -rf "$td"
  return "$rc"
}

_dpr_sync_tree_in() {
  local root="$1" work="$2" base_c="$3" td="$4"
  local k lk mb item p a v mrc tree n i j path out="" s1 s2 s3 blob
  local -a ps=() ms=() ss=() os=() uniq=()
  # 0-1. 병합 설정
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    lk="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
    case "$_DPR_SYNC_MERGE_KEYS_OK" in
      *" $lk "*) ;;
      *) printf '병합 동작을 바꾸는 설정(%s)이 있어 자동 병합을 대조할 수 없습니다\n' "$k" >&2; return 3 ;;
    esac
  done < <(git -C "$root" config --name-only --get-regexp '^merge\.' 2>/dev/null)
  # 0-2. 병합 속성 — 어느 한쪽이라도 바꾼 경로(이름 변경은 옛·새 이름 모두)의 합집합. base 가 여럿이면 모두 씁니다.
  # base 를 구하지 못하면(잘못된 ref·무관한 이력) 이 검사를 건너뛰고 1단계 판정(rc 3)에 맡깁니다.
  : >"$td/paths"
  while IFS= read -r mb; do
    [[ -n "$mb" ]] || continue
    git -C "$root" diff -z --name-only --no-renames "$mb" "$work" -- >>"$td/paths" 2>/dev/null \
      && git -C "$root" diff -z --name-only --no-renames "$mb" "$base_c" -- >>"$td/paths" 2>/dev/null \
      || { printf '바뀐 경로를 구하지 못해 자동 병합을 대조할 수 없습니다\n' >&2; return 3; }
  done < <(git -C "$root" merge-base --all "$work" "$base_c" 2>/dev/null)
  if [[ -s "$td/paths" ]]; then
    git -C "$root" check-attr -z --stdin merge <"$td/paths" >"$td/attrs" 2>/dev/null \
      || { printf 'merge 속성을 읽지 못해 자동 병합을 대조할 수 없습니다\n' >&2; return 3; }
    # 출력: <경로> NUL merge NUL <값> NUL 의 반복
    while IFS= read -r -d '' p && IFS= read -r -d '' a && IFS= read -r -d '' v; do
      if [[ "$v" != unspecified ]]; then
        printf '%s 에 merge 속성이 있어 자동 병합을 대조할 수 없습니다\n' "$p" >&2; return 3
      fi
    done <"$td/attrs"
  fi
  # 1. git 내장 3-way 병합. 첫 항목이 트리 객체가 아니면(잘못된 ref 도 rc 1) 판정 불가.
  mrc=0; git -C "$root" merge-tree --write-tree -z --no-messages "$work" "$base_c" >"$td/mt" 2>"$td/mterr" || mrc=$?
  tree=""; IFS= read -r -d '' tree <"$td/mt" || true
  if [[ -z "$tree" || "$(git -C "$root" cat-file -t "$tree" 2>/dev/null)" != tree ]]; then
    printf '병합 결과 트리를 얻지 못했습니다: %s\n' "$(head -1 "$td/mterr" 2>/dev/null)" >&2; return 3
  fi
  if [[ "$mrc" == 0 ]]; then printf '%s\n' "$tree"; return 0; fi
  if [[ "$mrc" != 1 ]]; then printf 'merge-tree 가 rc %s 로 끝났습니다: %s\n' "$mrc" "$(head -1 "$td/mterr" 2>/dev/null)" >&2; return 3; fi
  # 2. 충돌 항목 `<mode> <oid> <stage>\t<path>` 을 모읍니다(첫 항목 뒤 빈 항목까지).
  n=0
  { IFS= read -r -d '' item
    while IFS= read -r -d '' item && [[ -n "$item" ]]; do
      ms[n]="${item%% *}"; item="${item#* }"
      os[n]="${item%% *}"; item="${item#* }"
      ss[n]="${item%%$'\t'*}"; ps[n]="${item#*$'\t'}"
      n=$((n + 1))
    done; } <"$td/mt"
  for ((i = 0; i < n; i++)); do
    for ((j = 0; j < ${#uniq[@]}; j++)); do [[ "${uniq[j]}" == "${ps[i]}" ]] && break; done
    [[ "$j" -lt "${#uniq[@]}" ]] || uniq+=( "${ps[i]}" )
  done
  # 충돌이라는데 경로를 하나도 모으지 못했으면 자동 해소할 수 없는 충돌로 봅니다.
  [[ "${#uniq[@]}" -gt 0 ]] || return 1
  for path in "${uniq[@]}"; do
    if ! printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | grep -qxF -- "$path"; then out="${out}${path}"$'\n'; continue; fi
    # 다섯 경로라도 일반 파일(100644)이 아닌 stage(실행 비트·심볼릭 링크·gitlink 160000)가 있으면 자동 해소하지 않습니다.
    for ((i = 0; i < n; i++)); do
      [[ "${ps[i]}" == "$path" && "${ms[i]}" != 100644 ]] && { out="${out}${path}"$'\n'; break; }
    done
  done
  if [[ -n "$out" ]]; then printf '%s' "$out"; return 1; fi
  # 3·4. 다섯 경로를 stage blob 으로 풀어 임시 index 에 넣고 트리를 씁니다. merge-tree 의 첫 인자가 작업 커밋이므로 stage 2 = 작업 쪽, 3 = 기본 쪽.
  GIT_INDEX_FILE="$td/index" git -C "$root" read-tree "$tree" 2>/dev/null \
    || { printf '임시 index 에 병합 트리를 읽지 못했습니다\n' >&2; return 3; }
  for path in "${uniq[@]}"; do
    s1=""; s2=""; s3=""
    for ((i = 0; i < n; i++)); do
      [[ "${ps[i]}" == "$path" ]] || continue
      git -C "$root" cat-file blob "${os[i]}" >"$td/s${ss[i]}" 2>/dev/null || { printf 'stage blob 을 꺼내지 못했습니다: %s\n' "$path" >&2; return 3; }
      case "${ss[i]}" in 1) s1="$td/s1" ;; 2) s2="$td/s2" ;; 3) s3="$td/s3" ;; esac
    done
    rd_merge_resolve_record "$path" "$s1" "$s3" "$s2" "$td/out" || { printf '%s\n' "$path"; return 1; }
    blob="$(git -C "$root" hash-object -w -- "$td/out" 2>/dev/null)" \
      && GIT_INDEX_FILE="$td/index" git -C "$root" update-index --cacheinfo "100644,${blob},${path}" 2>/dev/null \
      || { printf '해소한 내용을 임시 index 에 넣지 못했습니다: %s\n' "$path" >&2; return 3; }
    rm -f "$td/s1" "$td/s2" "$td/s3" "$td/out"
  done
  GIT_INDEX_FILE="$td/index" git -C "$root" write-tree 2>/dev/null || { printf '병합 트리를 쓰지 못했습니다\n' >&2; return 3; }
}

# dpr_published_head <root> <커밋> <slug> <기본 ref> — 그 커밋이 「rd 가 발행한 head」인지(spec D4).
#   (가) _dpr_cleanup_shape 를 만족하는 되돌리기 커밋이면 0.
#   (나) 부모 둘·동기화 제목·둘째 부모가 <기본 ref> 의 조상(같음 포함)·트리가 dpr_sync_tree <첫 부모> <둘째 부모> 와 같으면 첫 부모로 이어 감.
#   (다) 부모 둘·동기화 제목이고 그 작업의 색인 pr-head 이거나 pr-verified 에 있으면 트리를 다시 계산하지 않고 첫 부모로 이어 감
#        (push 전에 (나)를 통과해 기록된 head — 그 뒤 병합 설정·속성·git 판이 바뀌어도 막히지 않음).
#   그 밖은 1. (나) 단계(기록되지 않은 sync 병합)가 20개를 넘으면 1. (다) 단계는 세지 않습니다.
#   rc 0 stdout 사슬 끝 되돌리기 커밋 OID / rc 1 아님 / rc 2 판정 불가(커밋·<기본 ref> 를 읽지 못함, 병합 대조 불가).
#   <기본 ref> 가 비면 refs/remotes/origin/<기본 브랜치> 를 씁니다. 기본 브랜치는 부모 둘인 커밋을 처음 볼 때만 구합니다 —
#   그래서 단일 되돌리기 커밋은 기본 브랜치를 구하지 못해도 종전처럼 판정합니다.
dpr_published_head() {
  local root="${1:?root}" cur="${2:?커밋}" slug="${3:?slug}" bref="${4-}"
  local def="" fr want="" prhead parents p1 p2 subj tree calc rc steps=0 max=20
  fr="$(dpr_fr_branch "$slug")"
  prhead="$(dpr_index_get "$slug" pr-head 2>/dev/null)" || prhead=""
  cur="$(git -C "$root" rev-parse --verify -q "${cur}^{commit}" 2>/dev/null)" || return 2
  while :; do
    rc=0; _dpr_cleanup_shape "$root" "$cur" "$slug" || rc=$?
    case "$rc" in
      0) printf '%s\n' "$cur"; return 0 ;;
      1) ;;
      *) return 2 ;;
    esac
    parents="$(git -C "$root" rev-list --parents -n 1 "$cur" 2>/dev/null)" || return 2
    set -- $parents
    [[ "$#" -eq 3 ]] || return 1
    p1="$2"; p2="$3"
    if [[ -z "$want" ]]; then
      def="${bref#refs/remotes/origin/}"
      if [[ -z "$bref" || "$def" == "$bref" ]]; then def="$(cd "$root" && get_default_branch 2>/dev/null)" || return 2; fi
      [[ -n "$bref" ]] || bref="refs/remotes/origin/${def}"
      want="$(_dpr_sync_subject "$def" "$fr")"
    fi
    subj="$(git -C "$root" log -1 --format=%s "$cur" 2>/dev/null)" || return 2
    [[ "$subj" == "$want" ]] || return 1
    # (다) 기록된 head
    if [[ "$cur" == "$prhead" ]] || dpr_verified_has "$slug" "$cur"; then
      cur="$p1"; continue
    fi
    # (나) 기록되지 않은 sync 병합 — 출처와 트리를 대조합니다.
    steps=$((steps + 1))
    [[ "$steps" -le "$max" ]] || return 1
    rc=0; git -C "$root" merge-base --is-ancestor "$p2" "$bref" 2>/dev/null || rc=$?
    case "$rc" in
      0) ;; 1) return 1 ;;
      *) printf '%s 를 읽을 수 없어 동기화 병합의 출처를 판정할 수 없습니다\n' "$bref" >&2; return 2 ;;
    esac
    tree="$(git -C "$root" rev-parse --verify -q "${cur}^{tree}" 2>/dev/null)" || return 2
    # rc 3 의 사유(병합 설정·속성 등)는 stderr 로 그대로 흘려 보냅니다. rc 1 의 기록 파일 사유는 판정에 쓰지 않아 끕니다.
    rc=0; calc="$(RD_MERGE_RESOLVE_QUIET=1 dpr_sync_tree "$root" "$p1" "$p2")" || rc=$?
    case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
    [[ "$calc" == "$tree" ]] || return 1
    cur="$p1"
  done
}

# dpr_rerun_hint <slug> <fr-branch> — 이미 끝난 발행을 다시 실행했을 때 알맞은 다음 행동을 알립니다(archive.sh D2, 읽기만 함).
# fr tip 이 되돌리기 커밋 모양((가)~(다))이면 Status 가 대기 중이라 아래 Status 게이트가 거부합니다. 그 전에 경우별로
# 안내하고 rc 1: 마감됨(색인 state=cleanup-pending) / PR 단계만 남음(원격 fr 이 같은 커밋) / 원격 조회 실패(판정 불가 — 연결 확인)
# / 브랜치만 앞섬(P6 직후 끊김).
# 되돌리기 커밋이 아니면 rc 0 — 평소 발행으로 갑니다. 저장소·색인을 바꾸지 않습니다.
dpr_rerun_hint() {
  local slug="${1:?slug}" fr="${2:?fr-branch}" root tip rc=0 _w
  root="$(_dpr_root)"
  tip="$(git -C "$root" rev-parse --verify -q "refs/heads/${fr}^{commit}" 2>/dev/null)" || return 0
  # 관문: fr 끝이 단일 되돌리기 커밋이거나 rd pr sync 모양(부모 둘·동기화 제목)이면 이미 발행한 작업입니다.
  _dpr_cleanup_shape "$root" "$tip" "$slug" || _dpr_sync_shape "$root" "$tip" "$slug" || return 0
  if [[ "$(dpr_index_get "$slug" state 2>/dev/null)" == cleanup-pending ]]; then
    local ptag mhead mdef
    ptag="$(dpr_index_get "$slug" publish-tag 2>/dev/null)" || ptag=""
    mhead=""; [[ -z "$ptag" ]] || mhead="$(git -C "$root" tag -l --format='%(contents)' "$ptag" 2>/dev/null | sed -n 's/^pr-head: //p' | head -1)"
    mdef="$(cd "$root" && get_default_branch 2>/dev/null)" || mdef="<기본 브랜치>"
    printf 'archive: %s 는 이미 마감됐습니다.\n' "$slug" >&2
    dpr_closed_cleanup_guide "$root" "$fr" "$mhead" "$mdef" 'archive:   ' >&2
    return 1
  fi
  dpr_is_published_cleanup "$fr" "$slug" 2>/dev/null || rc=$?
  if [[ "$rc" == 0 ]]; then
    printf 'archive: %s 의 작업 상태 되돌리기 커밋은 이미 push 됐습니다 — PR 단계만 다시 하십시오:\n' "$fr" >&2
    printf 'archive:   bash rd-workflow/scripts/rd pr open --task %s\n' "$slug" >&2
  elif [[ "$rc" == 2 && -n "$_DPR_PUBLISHED_WHY" ]]; then
    printf 'archive: %s 끝이 rd 가 발행한 head 인지 판정할 수 없습니다 — 아무것도 바꾸지 않았습니다.\n' "$fr" >&2
    printf 'archive:   사유: %s\n' "$_DPR_PUBLISHED_WHY" >&2
  elif [[ "$rc" == 2 ]]; then
    printf 'archive: %s 끝의 작업 상태 되돌리기 커밋이 push 됐는지 원격을 조회하지 못해 판정할 수 없습니다 — 아무것도 바꾸지 않았습니다.\n' "$fr" >&2
    printf 'archive:   git ls-remote origin 이 되는지 연결을 확인한 뒤 같은 명령을 다시 실행하십시오.\n' >&2
  elif [[ -z "$_DPR_CHAIN_OID" ]] || ! _dpr_cleanup_shape "$root" "$tip" "$slug"; then
    # fr 끝이 sync 병합입니다 — 검증되지 않았거나(손 병합 등) 원격과 다릅니다. 기록된 sync head 는 push 가 확인된 것이라
    # 「push 되지 않은 되돌리기 커밋」 안내(reset --keep)는 사실과 다릅니다. 이어 가는 길은 rd pr sync 입니다.
    printf 'archive: %s 의 끝이 rd pr sync 의 병합인데 검증되지 않았거나 원격 fr 브랜치와 다릅니다 — 아무것도 바꾸지 않았습니다:\n' "$fr" >&2
    printf 'archive:   bash rd-workflow/scripts/rd pr sync --task %s\n' "$slug" >&2
  else
    # 되돌릴 기준은 사슬 끝 되돌리기 커밋의 부모입니다(단일 되돌리기 커밋이면 fr 끝의 부모와 같음).
    printf 'archive: %s 끝에 push 되지 않은 작업 상태 되돌리기 커밋이 있습니다(이전 발행이 커밋 직후 끊김). 되돌린 뒤 다시 발행 요청하십시오:\n' "$fr" >&2
    _w="$(_dpr_fr_worktree "$fr" 2>/dev/null)" && _w="$(dpr_shq "${_w%/}")" || _w='<작업 worktree>'
    printf 'archive:   git -C %s reset --keep %s && %s\n' "$_w" "$(git -C "$root" rev-parse --short "${_DPR_CHAIN_OID}^")" "$_DPR_PUBLISH_CMD" >&2
  fi
  return 1
}

# _dpr_sync_shape <root> <커밋> <slug> — rc 0 이면 부모가 둘이고 제목이 그 작업의 동기화 제목(검증은 하지 않음).
_dpr_sync_shape() {
  local root="$1" c="$2" slug="$3" def parents subj
  parents="$(git -C "$root" rev-list --parents -n 1 "$c" 2>/dev/null)" || return 1
  set -- $parents
  [[ "$#" -eq 3 ]] || return 1
  def="$(cd "$root" && get_default_branch 2>/dev/null)" || return 1
  subj="$(git -C "$root" log -1 --format=%s "$c" 2>/dev/null)" || return 1
  [[ "$subj" == "$(_dpr_sync_subject "$def" "$(dpr_fr_branch "$slug")")" ]]
}

# dpr_cleanup_commit <worktree> <slug> — 작업 worktree 의 fr 브랜치에 D4 되돌리기 커밋을 만듭니다.
# archive.sh Step 4 와 같은 순서·검증을 하위 셸에서 합니다(그 블록은 옮기거나 고치지 않습니다).
# 성공 rc 0 + stdout 새 커밋 OID. 커밋 전 실패는 바꾼 경로를 HEAD 로 복원하고 rc 1.
dpr_cleanup_commit() {
  local wt="${1:?worktree}" slug="${2:?slug}"
  [[ -d "$wt" ]] || { printf 'dpr_cleanup_commit: worktree 가 없습니다: %s\n' "$wt" >&2; return 1; }
  (
    cd "$wt" || exit 1
    project_root="$wt"; export project_root
    unset TASK_STATE_PATH STATE_MIGRATION_BACKUP_DIR
    source "$_DPR_LC_DIR/_lifecycle_common.sh" || exit 1

    # 동기화 의무: 아래 baseline 생성·metadata_clear·state_write_fields·staging 목록 분기·커밋 블록은 archive.sh Step 4
    # ("metadata cleanup commit on main", `if metadata_exists || no-fr` 블록) 의 복제입니다(spec D4 — archive.sh 를 함께 고치는 줄기와
    # 겹치지 않으려고 옮기지 않았습니다). archive.sh Step 4 에서 아래를 바꾸면 이 블록도 같은 분기로 바꾸십시오. 그러지 않으면 두 경로의
    # 되돌리기 결과가 조용히 갈라집니다.
    #   - `*/active-fr` 는 추적 중일 때만, `*/stage_metrics.tsv` 는 존재할 때만 staging 목록에 넣는 분기
    #   - 팀 PR 기록(RD_TEAM_PR_RECORD) 삭제와 추적 중일 때만 staging 하는 분기
    #   - emit_current_task_baseline 검증(`^대기 중$`)과 index 의 CURRENT_TASK.md 내용 대조
    #   - 커밋 메시지, `--no-verify` 판정(lifecycle_needs_hook_bypass)
    #   - lifecycle_metadata_paths() 를 단일 출처로 쓰는 것
    # 두 블록을 하나로 합치는 일은 이 작업 뒤의 정리 후보입니다.
    _ct="CURRENT_TASK.md"; _ct_tmp="${_ct}.baseline.tmp"
    _ts_dir="rd-workflow-workspace/.lifecycle"
    # 이 함수가 바꿀 수 있는 경로 전부(복원 대상). P1 이 clean 을 확인했으므로 모두 HEAD 와 같은 상태에서 출발합니다.
    _touched=( "$_ct" "$_ct_tmp" "$_ts_dir/task-state" "$_ts_dir/active-fr" "$_ts_dir/stage_metrics.tsv" "$RD_TEAM_PR_RECORD" )

    # 커밋 전 실패 복원: index 를 HEAD 로, HEAD 에 있는 경로는 checkout, 없는 경로는 삭제. 이어 task-state 임시 파일을 지웁니다.
    _restore() {
      local p left
      for p in "${_touched[@]}"; do
        git reset -q HEAD -- "$p" 2>/dev/null
        if git cat-file -e "HEAD:$p" 2>/dev/null; then
          git checkout -q HEAD -- "$p" 2>/dev/null
        else
          rm -f "$p"
        fi
      done
      rm -f "$_ts_dir"/.task-state.* 2>/dev/null
      left="$(git status --porcelain --untracked-files=all 2>/dev/null)"
      if [[ -n "$left" ]]; then
        printf 'dpr_cleanup_commit: 복원 뒤에도 worktree 에 변경이 남았습니다:\n%s\n' "$left" >&2
        printf '  복구 명령: git -C %s checkout HEAD -- <경로들>\n' "$wt" >&2
        return 1
      fi
      return 0
    }
    _fail() { printf 'dpr_cleanup_commit: %s — 중단\n' "$1" >&2; _restore; exit 1; }

    emit_current_task_baseline >"$_ct_tmp" 2>/dev/null || _fail "CURRENT_TASK.md baseline 생성 실패"
    grep -q '^대기 중$' "$_ct_tmp" || _fail "CURRENT_TASK.md baseline 검증 실패"
    mv "$_ct_tmp" "$_ct" || _fail "CURRENT_TASK.md 교체 실패"

    _from="$(state_read_field status)"
    metadata_clear || _fail "metadata_clear 실패"
    state_write_fields "short-title=-" "status=대기 중" || _fail "task-state 쓰기 실패"
    state_log_stage_transition "$slug" "$_from" "대기 중"

    _paths_out="$(lifecycle_metadata_paths)" || _fail "허용 경로 목록 생성 실패"
    _paths=()
    while IFS= read -r _rel; do
      [[ -n "$_rel" ]] || continue
      case "$_rel" in
        */active-fr) git ls-files --error-unmatch "$_rel" >/dev/null 2>&1 || continue ;;
        */stage_metrics.tsv) [[ -f "$_rel" ]] || continue ;;
      esac
      _paths+=( "$_rel" )
    done <<EOF_DPR_P
$_paths_out
EOF_DPR_P
    # 팀 저장소 PR 기록은 이 작업의 것이므로 task-state 와 함께 지웁니다(추적 중일 때만 staging 목록에 둡니다).
    if [[ -e "$RD_TEAM_PR_RECORD" ]] || git ls-files --error-unmatch "$RD_TEAM_PR_RECORD" >/dev/null 2>&1; then
      git ls-files --error-unmatch "$RD_TEAM_PR_RECORD" >/dev/null 2>&1 && _paths+=( "$RD_TEAM_PR_RECORD" )
      rm -f "$RD_TEAM_PR_RECORD" || _fail "PR 기록 파일 삭제 실패"
    fi
    git add -- "${_paths[@]}" || _fail "lifecycle metadata staging 실패"
    git show ":$_ct" 2>/dev/null | diff -q - "$_ct" >/dev/null 2>&1 || _fail "index 의 CURRENT_TASK.md 가 baseline 과 불일치"
    git diff --cached --quiet -- "${_paths[@]}" 2>/dev/null && _fail "되돌릴 변경이 없습니다"

    _nv=""
    if lifecycle_needs_hook_bypass; then _nv="--no-verify"; fi
    RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit -q ${_nv:+"$_nv"} \
      -m "$(_dpr_cleanup_subject "$slug")" -- "${_paths[@]}" >&2 || _fail "되돌리기 커밋 실패"
    git rev-parse HEAD
  )
}

# dpr_pr_text <worktree> <입력 커밋> <본문 파일> — spec D3a. stdout 제목 한 줄, 본문을 <본문 파일> 에 씁니다.
# 제목·본문·Issue 정보는 작업 폴더가 아니라 <입력 커밋> 의 task-state 에서 읽습니다(정리 커밋은 review-session·source-fr 를 비움).
# 본문 없음·입력 커밋을 읽을 수 없음 rc 1 (본문 파일은 건드리지 않음). team_publish.sh 를 source 한 셸에서만 부릅니다.
dpr_pr_text() {
  local wt="${1:?worktree}" commit="${2:?입력 커밋}" out="${3:?본문 파일}" tmp part rc
  declare -F tp_extract_pr_body >/dev/null 2>&1 || { printf 'dpr_pr_text: team_publish.sh 를 먼저 source 해야 합니다\n' >&2; return 2; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/rd-dprts.XXXXXX")" || return 1
  part="$(mktemp "${TMPDIR:-/tmp}/rd-dprtb.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if ! git -C "$wt" show "${commit}:rd-workflow-workspace/.lifecycle/task-state" >"$tmp" 2>/dev/null; then
    rm -f "$tmp" "$part"
    printf 'dpr_pr_text: 입력 커밋의 task-state 를 읽을 수 없습니다: %s\n' "$commit" >&2
    return 1
  fi
  (
    TASK_STATE_PATH="$tmp"; project_root="$wt"
    tp_extract_pr_body "$wt" >"$part" || exit 1
    tp_pr_title "$wt" "$(state_read_field short-title)"
  )
  rc=$?
  rm -f "$tmp"
  if [[ "$rc" != 0 ]]; then
    rm -f "$part"
    printf 'dpr_pr_text: PR 본문을 만들 수 없습니다 — final diff review Author 턴에 `## PR 본문` 절이 있어야 합니다\n' >&2
    return 1
  fi
  cat "$part" >"$out" || { rm -f "$part"; return 1; }
  rm -f "$part"
}

# dpr_pr_waiting <slug> <fr-branch> — rc 0 이면 PR 대기(spec D5): 색인 pr-head 가 있고 fr tip 과 같고 state 가 cleanup-pending 이 아님.
# gh·원격을 조회하지 않고 로컬 ref 만 봅니다.
dpr_pr_waiting() {
  local slug="${1:?slug}" fr="${2:?fr-branch}" head tip st
  head="$(dpr_index_get "$slug" pr-head 2>/dev/null)" || head=""
  [[ -n "$head" ]] || return 1
  tip="$(git -C "$(_dpr_root)" rev-parse --verify -q "refs/heads/${fr}^{commit}" 2>/dev/null)" || return 1
  [[ "$head" == "$tip" ]] || return 1
  st="$(dpr_index_get "$slug" state 2>/dev/null)" || st=""
  [[ "$st" != "cleanup-pending" ]]
}

# ---------------------------------------------------------------------------
# archive.sh 의 PR 발행 분기 (spec D2·D3)
# ---------------------------------------------------------------------------

_DPR_PUBLISH_CMD='bash rd-workflow/scripts/rd publish request'

# _dpr_load_tp — team_publish.sh 의 tp_pr_title·tp_extract_pr_body·tp_closed_choices·_tp_pr_list_parse 를 싣습니다.
# BASH_SOURCE 가드가 있어 source 해도 명령은 실행되지 않습니다. 이미 실려 있으면 아무것도 하지 않습니다.
_dpr_load_tp() {
  declare -F tp_pr_title >/dev/null 2>&1 && declare -F _tp_pr_list_parse >/dev/null 2>&1 && return 0
  project_root="$(_dpr_root)"; export project_root
  source "$_DPR_LC_DIR/team_publish.sh"
}

# dpr_preflight <branch-mode> <remote-mode> — spec D2 사전 거부. rc 0 통과, rc 1 거부(사유와 다음 행동은 stderr).
# archive.sh 가 어떤 커밋·태그·push 보다 먼저, `archive_publish` 가 pr 일 때만 부릅니다.
dpr_preflight() {
  local bm="${1:?branch-mode}" rmode="${2:?remote-mode}"
  if [[ "$bm" == "no-fr" ]]; then
    printf 'archive: archive_publish=pr 는 fr 브랜치 작업만 지원합니다 — 발행하지 않습니다 (상태 변경 없음).\n' >&2
    printf 'archive:   기본 브랜치의 변경을 fr 작업으로 옮기려면 promote.sh 로 작업을 시작하십시오.\n' >&2
    return 1
  fi
  if [[ "$rmode" != "remote" ]]; then
    printf 'archive: PR 을 올릴 원격이 없습니다 — 발행하지 않습니다 (상태 변경 없음).\n' >&2
    printf 'archive:   origin 을 설정하거나 rd-workflow/config/workflow.json 의 archive_publish 를 push 로 두십시오.\n' >&2
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'archive: gh(GitHub CLI)를 찾을 수 없어 PR 을 올릴 수 없습니다 — 발행하지 않습니다 (상태 변경 없음).\n' >&2
    printf 'archive:   GitHub CLI 를 설치하고 gh auth login 을 마친 뒤 다시 실행하십시오.\n' >&2
    return 1
  fi
  if ! get_default_branch >/dev/null 2>&1; then
    printf 'archive: 기본 브랜치 결정 실패 — PR 의 대상 브랜치를 정할 수 없어 발행하지 않습니다 (상태 변경 없음).\n' >&2
    printf 'archive:   rd-workflow/config/workflow.json 에 "default_branch" 를 설정하십시오.\n' >&2
    return 1
  fi
  return 0
}

# _dpr_fail <단계> <원인> <재시도> [추가 안내 줄...] — D3 의 실패 출력. 첫 줄 「PR 발행 실패」, 마지막 줄 「재시도」. 항상 rc 1.
_dpr_fail() {
  local step="$1" cause="$2" retry="$3" l
  shift 3
  printf 'archive: PR 발행 실패 — %s: %s\n' "$step" "$cause" >&2
  for l in "$@"; do
    [[ -n "$l" ]] && printf '%s\n' "$l" | sed 's/^/archive:   /' >&2
  done
  printf 'archive:   재시도: %s\n' "$retry" >&2
  return 1
}

# _dpr_closed_links <pr-url> — 닫힌 PR 이 본문의 Closes 줄로 GitHub 에 연결한 Issue URL 을 공백으로 이어 냅니다.
# GitHub 이 본문을 자기 규칙(코드 블록·주석 제외 등)으로 해석한 closingIssuesReferences 를 excludeUserLinked 로 받아,
# 사람이 PR 화면에서 직접 연결한 Issue 는 빼고 발행 본문이 연결한 것만 씁니다. PR 이 닫혔을 때만 부르는 따로 된 조회라
# PR 상태 조회는 이 필드를 지원하지 않는 gh·GitHub 에서도 그대로 동작합니다. 조회·해석하지 못하면 `?` 를 냅니다.
_dpr_closed_links() {
  local url="$1" lim="${RD_PR_CHECK_TIMEOUT:-15}" host owner name num out
  if [[ ! "$url" =~ ^https?://([A-Za-z0-9.-]+(:[0-9]+)?)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)/?$ ]]; then
    printf '?\n'; return 0
  fi
  host="${BASH_REMATCH[1]}"; owner="${BASH_REMATCH[3]}"; name="${BASH_REMATCH[4]}"; num="${BASH_REMATCH[5]}"
  out="$(tp_gh "$lim" api graphql --hostname "$host" -F owner="$owner" -F name="$name" -F number="$num" \
    -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){closingIssuesReferences(first:50,excludeUserLinked:true){nodes{url}}}}}' \
    2>/dev/null)" || { printf '?\n'; return 0; }
  printf '%s' "$out" | _dpr_links_parse
}

# _dpr_links_parse — stdin 의 GraphQL 응답에서 closingIssuesReferences 의 Issue URL 을 공백으로 이어 냅니다.
# 형식 밖 URL 은 버리고, 응답에 그 필드가 없으면(오류 응답 등) `?` 를 냅니다.
_dpr_links_parse() {
  python3 -I -c '
import json, re, sys
iurl = re.compile(r"^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+$")
try:
    nodes = json.load(sys.stdin)["data"]["repository"]["pullRequest"]["closingIssuesReferences"]["nodes"]
    assert isinstance(nodes, list)
except Exception:
    print("?"); sys.exit(0)
out = []
for n in nodes:
    u = n.get("url") if isinstance(n, dict) else None
    if isinstance(u, str) and iurl.match(u) and u not in out:
        out.append(u)
print(" ".join(out))
'
}

# _dpr_p2_lookup <slug> <fr-branch> <기본 브랜치> <repo> <errf> — spec D3 P2 (기존 PR 조회). dpr_publish 와 rd pr open 이 함께 씁니다.
# 성공 rc 0 이면 전역 _DPR_OPEN_URL 에 열린 PR 의 URL(없으면 빈 값)을 둡니다. 멈출 일(merge 됨·닫힘·대상 브랜치 다름·조회 실패)은 rc 1 이고 안내는 stderr.
_DPR_OPEN_URL=""
_dpr_p2_lookup() {
  local slug="$1" fr="$2" def="$3" repo="$4" errf="$5" out st u b rcode=0
  local open_url="" open_base="" merged_url="" closed_url="" lim="${_TP_GH_LIMIT:-60}"
  _DPR_OPEN_URL=""
  rcode=0; out="$(tp_gh "$lim" pr list --repo "$repo" --head "$fr" --state all --json url,state,baseRefName 2>"$errf")" || rcode=$?
  if [[ "$rcode" != 0 ]]; then
    _dpr_fail "P2 기존 PR 조회" "gh pr list 실패: $(head -1 "$errf")" "$_DPR_PUBLISH_CMD"; return 1
  fi
  out="$(printf '%s' "$out" | _tp_pr_list_parse)" || {
    _dpr_fail "P2 기존 PR 조회" "gh pr list 응답을 해석할 수 없습니다" "$_DPR_PUBLISH_CMD"; return 1; }
  while IFS=$'\t' read -r st u b; do
    [[ -n "$st" ]] || continue
    case "$st" in
      MERGED) [[ -n "$merged_url" ]] || merged_url="$u" ;;
      CLOSED) [[ -n "$closed_url" ]] || closed_url="$u" ;;
      OPEN) [[ -n "$open_url" ]] || { open_url="$u"; open_base="$b"; } ;;
    esac
  done <<EOF_DPR_L
$out
EOF_DPR_L
  if [[ -n "$merged_url" ]]; then
    _dpr_fail "P2 기존 PR 조회" "이미 merge 된 PR 이 있습니다 ($merged_url)" "bash rd-workflow/scripts/rd pr check --task $slug --apply"
    return 1
  fi
  if [[ -z "$open_url" && -n "$closed_url" ]]; then
    printf 'archive: PR 발행 실패 — P2 기존 PR 조회: PR 이 닫혀 있습니다 (%s)\n' "$closed_url" >&2
    dpr_closed_choices "$slug" "$closed_url" "$fr" >&2
    printf 'archive:   재시도: 선택지를 실행한 뒤 %s\n' "$_DPR_PUBLISH_CMD" >&2
    return 1
  fi
  if [[ -n "$open_url" && "$open_base" != "$def" ]]; then
    _dpr_fail "P2 기존 PR 조회" "열린 PR($open_url)의 대상 브랜치가 $open_base 입니다 (기본 브랜치: $def)" \
      "gh pr edit $open_url --base $def 로 바꾼 뒤 $_DPR_PUBLISH_CMD"
    return 1
  fi
  _DPR_OPEN_URL="$open_url"
  return 0
}

# _dpr_pr_submit <slug> <fr> <기본 브랜치> <repo> <제목> <본문 파일> <errf> <열린 PR URL|빈 값> <발행 head> — spec D3 P9·P10.
# 열린 PR 이 있으면 제목·본문만 갱신하고(pr edit) 없으면 만듭니다(pr create). 실패해도 정리 커밋과 push 는 보존하고 색인 pr-url·pr-sent 는 건드리지 않습니다.
# 성공하면 pr-sent=<발행 head> 를 남깁니다 — 발행 큐는 pr-sent 가 지금 fr tip 과 같을 때만 이 발행을 끝난 것으로 봅니다.
_dpr_pr_submit() {
  local slug="$1" fr="$2" def="$3" repo="$4" title="$5" body="$6" errf="$7" open_url="${8:-}" sent="${9:-}" url out rcode=0
  local lim="${_TP_GH_LIMIT:-60}"
  if [[ -n "$open_url" ]]; then
    rcode=0; tp_gh "$lim" pr edit "$open_url" --title "$title" --body-file "$body" >/dev/null 2>"$errf" || rcode=$?
    url="$open_url"
  else
    rcode=0; out="$(tp_gh "$lim" pr create --repo "$repo" --base "$def" --head "$fr" --title "$title" --body-file "$body" 2>"$errf")" || rcode=$?
    url="$(printf '%s\n' "$out" | grep -Eo 'https?://[^[:space:]]+' | tail -1)"
    [[ "$rcode" != 0 || -n "$url" ]] || { rcode=1; printf 'PR 생성 결과(URL)를 받지 못했습니다\n' >"$errf"; }
  fi
  if [[ "$rcode" != 0 ]]; then
    _dpr_fail "P9 PR 생성·갱신" "gh 실패: $(head -1 "$errf") (정리 커밋과 push 는 보존했습니다)" "bash rd-workflow/scripts/rd pr open --task $slug"
    return 1
  fi
  dpr_index_set "$slug" "pr-url=${url}" "pr-sent=${sent}" || printf 'archive: WARNING — 작업 색인에 pr-url 을 쓰지 못했습니다\n' >&2

  # P10 — 결과
  printf 'archive: PR 발행 완료 — %s\n' "$url"
  printf 'archive:   PR 검토 중 — merge 뒤 bash rd-workflow/scripts/rd pr check --task %s --apply\n' "$slug"
  return 0
}

# dpr_fr_branch <slug> — 작업의 fr 브랜치 이름. 색인 fr-branch, 없으면 fr/<slug>.
dpr_fr_branch() {
  local b
  b="$(dpr_index_get "$1" fr-branch 2>/dev/null)" || b=""
  [[ -n "$b" && "$b" != null ]] || b="fr/$1"
  printf '%s\n' "$b"
}

# dpr_closed_choices <slug> <pr-url> <fr-branch> — 닫힌 PR 의 선택지(spec D8).
#   Issue 선점 풀기 줄은 그 PR 이 본문의 Closes 줄로 GitHub 에 연결한 Issue(_dpr_closed_links)로 만듭니다 — 발행 때 대상 작업의
#   Source FR 로 만든 본문입니다. 호출한 체크아웃의 상태도, 발행 뒤 로컬에서 바꾼 Source FR·github-issue 값도, PR 화면에서 직접
#   연결한 Issue 도 쓰지 않습니다. 조회하지 못하면 그 이유를, 연결이 없으면 본문 Closes 줄이 연결되지 않았다는 안내를 PR URL 과 함께 냅니다.
# dpr_shq <문자열> — 안내 명령에 넣을 경로·ref 를 셸 인자 하나로 인용합니다. [A-Za-z0-9_./-] 만 있으면 그대로,
# 아니면 작은따옴표로 감쌉니다(안의 ' 는 '\'' 로). UTF-8 은 그대로 둡니다(bash 3.2 의 printf %q 는 한글을 바이트로 깹니다).
dpr_shq() {
  local q="$1" sq="'"
  if [[ "$q" =~ ^[A-Za-z0-9_./-]+$ ]]; then printf '%s' "$q"; else printf "'%s'" "${q//$sq/$sq\\$sq$sq}"; fi
}

# dpr_closed_cleanup_guide <저장소> <fr> <merge 된 head> <기본 브랜치> <머리말> — 마감 뒤 로컬 정리 안내를 stdout 에 냅니다.
# rd task list 는 로컬 fr 끝이 발행 태그의 pr-head(merge 된 head)와 같을 때만 지웁니다. 다르면(merge 뒤 rd pr sync 가 fr 을 옮김)
# 그렇다고 알리고, 지우기 전에 로컬에만 있는 커밋·파일(무시 파일 포함)을 확인하게 한 뒤 fr 이 체크아웃된 곳에 맞는 정리 명령을 냅니다.
dpr_closed_cleanup_guide() {
  local root="$1" fr="$2" head="$3" def="$4" p="$5" lfr wt main qr qf qw
  lfr="$(git -C "$root" rev-parse -q --verify "refs/heads/${fr}^{commit}" 2>/dev/null)" || lfr=""
  if [[ -z "$lfr" || -z "$head" || "$lfr" == "$head" ]]; then
    printf '%s작업 worktree·로컬 브랜치는 기본 체크아웃의 rd task list 가 정리합니다\n' "$p"
    return 0
  fi
  printf '%s로컬 %s(%s)가 merge 된 head(%s)와 달라 rd task list 는 작업 worktree·로컬 브랜치를 정리하지 않습니다. 지우기 전에 남길 것을 확인하십시오:\n' \
    "$p" "$fr" "$(git -C "$root" rev-parse --short "$lfr")" "$(git -C "$root" rev-parse --short "$head" 2>/dev/null || printf '%s' "$head")"
  qr="$(dpr_shq "$root")"; qf="$(dpr_shq "$fr")"
  printf '%s  1) 로컬에만 있는 커밋: git -C %s log --oneline %s  (rd pr sync 병합 커밋만 있으면 버려도 됩니다)\n' "$p" "$qr" "$(dpr_shq "${head}..${fr}")"
  wt="$(_dpr_fr_worktree "$fr" "$root")" && wt="${wt%/}" || wt=""
  if [[ -z "$wt" ]] && git -C "$root" worktree list --porcelain 2>/dev/null | grep -qxF "branch refs/heads/${fr}"; then
    # 체크아웃된 곳은 있는데 경로를 확인하지 못했습니다(줄 단위 목록에서 잘린 경로 등) — 다른 폴더의 명령을 내지 않습니다.
    printf '%s  2) %s 가 체크아웃된 worktree 의 경로를 확인하지 못했습니다 — git -C %s worktree list 로 찾아 커밋하지 않은 파일·무시 파일을 확인한 뒤 정리하십시오\n' "$p" "$fr" "$qr"
    return 0
  fi
  if [[ -z "$wt" ]]; then
    printf '%s  2) 정리: git -C %s branch -D %s\n' "$p" "$qr" "$qf"
    return 0
  fi
  qw="$(dpr_shq "$wt")"
  printf '%s  2) 커밋하지 않은 파일과 무시 파일: git -C %s status --short --ignored --untracked-files=all  (남길 파일은 작업 worktree 밖으로 옮깁니다)\n' "$p" "$qw"
  # 기본 체크아웃은 git-dir 이 공용 git-dir 과 같습니다.
  main=""
  [[ "$(git -C "$wt" rev-parse --path-format=absolute --git-dir 2>/dev/null)" == "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]] && main="$wt"
  if [[ "$wt" == "$main" ]]; then
    printf '%s  3) 정리: git -C %s switch --no-overwrite-ignore %s && git -C %s branch -D %s  (무시 파일이 %s 의 경로에 있으면 덮지 않고 멈춥니다)\n' "$p" "$qw" "$(dpr_shq "$def")" "$qw" "$qf" "$def"
  else
    printf '%s  3) 정리: git -C %s worktree remove %s && git -C %s branch -D %s  (worktree remove 는 무시 파일을 확인 없이 지웁니다 — 2) 를 먼저 하십시오)\n' "$p" "$qr" "$qw" "$qr" "$qf"
  fi
}

# dpr_rollback_cmd <slug> [<저장소>] — 작업 폐기 명령을 stdout 에 냅니다. promote_rollback.sh 는 지우려는 worktree 안에서 부르면 멈추므로
#   기본 체크아웃(git common dir 의 부모)으로 cd 한 뒤 --task 로 부릅니다. 기본 체크아웃을 구하지 못하면 이동 없이 「기본 체크아웃에서」 를 붙입니다.
dpr_rollback_cmd() {
  local slug="$1" root="${2:-$(_dpr_root)}" common base=""
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
  [[ -n "$common" ]] && base="$(cd "${common}/.." 2>/dev/null && pwd -P)" || base=""
  # --separate-git-dir 등으로 common dir 의 부모가 다른 저장소일 수 있습니다 — 그 위치가 같은 common dir 을 쓰는 체크아웃일 때만 cd 를 안내합니다.
  if [[ -n "$base" ]]; then
    [[ "$(git -C "$base" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == "$common" \
      && "$(git -C "$base" rev-parse --show-toplevel 2>/dev/null)" -ef "$base" ]] || base=""
  fi
  if [[ -n "$base" ]]; then
    printf 'cd %s && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s' "$(dpr_shq "$base")" "$(dpr_shq "$slug")"
  else
    printf '기본 체크아웃에서 bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task %s' "$(dpr_shq "$slug")"
  fi
}

dpr_closed_choices() {
  local slug="$1" url="$2" fr="$3" refs r n=0
  printf '  선택지 (사람이 정합니다):\n'
  printf '    1) 다시 열고 이어 가기: gh pr reopen %s\n' "$url"
  # 터미널 명령은 설명 없이 한 줄에 하나씩 둡니다 — 그 줄을 그대로 복사해 어느 폴더에서나 실행할 수 있습니다.
  printf '    2) 작업 폐기: 아래 순서로 진행합니다\n'
  printf '       a. Claude 세션에서 /fr status %s dropped 로 닫습니다\n' "$slug"
  # 원격 fr 브랜치는 rollback 이 직접 지웁니다(이 작업의 커밋일 때). 아니면 rollback 이 삭제 명령을 출력합니다.
  printf '       b. 터미널에서 아래 줄을 실행합니다(작업을 정리하고, 원격 fr 브랜치가 이 작업의 커밋이면 함께 지웁니다. 로컬 브랜치에 없는 커밋이 있으면 지우지 않고 지우는 명령을 출력합니다):\n'
  printf '          %s\n' "$(dpr_rollback_cmd "$slug")"
  refs="$(_dpr_closed_links "$url")"
  if [[ "$refs" == "?" ]]; then
    printf '    3) 연결된 Issue 선점 풀기: gh issue edit <Issue URL> --remove-assignee @me (이 PR 에 연결된 Issue 를 조회하지 못했습니다 — %s 에서 확인하십시오)\n' "$url"
    return 0
  fi
  for r in $refs; do
    case "$r" in
      http://*|https://*) printf '    3) 연결된 Issue 선점 풀기: gh issue edit %s --remove-assignee @me\n' "$r"; n=$((n + 1)) ;;
    esac
  done
  # 본문에 대상 작업이 붙인 줄 말고도 Closes 줄이 있으면 그 Issue 도 나옵니다(merge 때 실제로 닫힐 Issue). 출처를 늘 밝힙니다.
  [[ "$n" -eq 0 ]] || printf '    3) 위 Issue 는 이 PR 본문의 Closes 줄이 연결한 것입니다 — 이 작업의 Issue 가 아니면 선점을 풀지 마십시오(%s)\n' "$url"
  [[ "$n" -gt 0 ]] || printf '    3) 연결된 Issue 선점 풀기: gh issue edit <Issue URL> --remove-assignee @me (연결된 Issue 가 있을 때 — 이 PR 본문의 Closes 줄로 연결된 Issue 가 없습니다. %s 에서 확인하십시오)\n' "$url"
  return 0
}

# dpr_is_direct_task [<slug>] — rc 0 이면 직접 설치 PR 대상(stdout slug). spec D6 첫 항목.
# slug 는 인자 또는 현재 브랜치 fr/<slug>. 색인 pr-mode=direct 이거나 저장소 설정(archive_publish)이 pr 이면 참입니다.
dpr_is_direct_task() {
  local slug="${1:-}" root br pm mode
  root="$(_dpr_root)"
  if [[ -z "$slug" ]]; then
    br="$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)" || return 1
    case "$br" in fr/?*) slug="${br#fr/}" ;; *) return 1 ;; esac
  fi
  pm="$(dpr_index_get "$slug" pr-mode 2>/dev/null)" || pm=""
  if [[ "$pm" != direct ]]; then
    mode="$(dpr_archive_mode "$root" HEAD 2>/dev/null)" || return 1
    [[ "$mode" == pr ]] || return 1
  fi
  printf '%s\n' "$slug"
}

# _dpr_fr_worktree <fr-branch> [<저장소>] — 그 브랜치를 체크아웃한 worktree 경로. 없거나 확인하지 못하면 rc 1.
# 목록은 -z 로 읽어 줄바꿈이 든 경로를 자르지 않습니다(-z 를 모르는 git 은 줄 단위). 어느 쪽이든 찾은 경로가 실제로
# 그 브랜치를 체크아웃했는지 다시 확인해, 잘린 경로가 다른 worktree 를 가리키면 쓰지 않습니다.
_dpr_fr_worktree() {
  local want="refs/heads/$1" root="${2:-$(_dpr_root)}" rec cur="" wt=""
  if git -C "$root" worktree list --porcelain -z >/dev/null 2>&1; then
    while IFS= read -r -d '' rec; do
      case "$rec" in
        "worktree "*) cur="${rec#worktree }" ;;
        "branch $want") wt="$cur"; break ;;
      esac
    done < <(git -C "$root" worktree list --porcelain -z 2>/dev/null)
  else
    while IFS= read -r rec; do
      case "$rec" in
        "worktree "*) cur="${rec#worktree }" ;;
        "branch $want") wt="$cur"; break ;;
      esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
  fi
  [[ -n "$wt" ]] || return 1
  [[ "$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null)" == "$want" ]] || return 1
  # 끝에 / 를 붙입니다 — 호출부의 명령 치환이 경로 끝의 줄바꿈을 지우지 않게. 호출부가 ${wt%/} 로 뗍니다.
  printf '%s/' "$wt"
}

# dpr_resume_head <root> <slug> <fr> <tip> <원격 끝 OID> — 원격 fr 끝이 「이전 발행이 push 뒤에 끊긴 head」인지(spec D2).
#   첫째: 원격 끝의 부모가 tip 이고 되돌리기 커밋 모양(_dpr_cleanup_shape).
#   둘째: 원격 끝이 동기화 병합 모양(_dpr_sync_shape)이고 pr-verified 에 있으며, 첫 부모가 되돌리기 커밋 모양이고 그 부모가 tip.
#   rc 0 재개 상태 / rc 1 아님(객체를 읽지 못해도 1). 저장소·색인을 바꾸지 않고 원격을 조회하지 않습니다(조회·fetch 는 부르는 쪽).
#   <fr> 은 부르는 쪽 계약을 맞추려고 받습니다 — 동기화 제목은 _dpr_sync_shape 가 색인의 fr 브랜치로 만듭니다.
dpr_resume_head() {
  local root="${1:?root}" slug="${2:?slug}" tip="${4-}" r="${5-}" p1
  [[ -n "$tip" && -n "$r" ]] || return 1
  if [[ "$(git -C "$root" rev-parse -q --verify "${r}^" 2>/dev/null)" == "$tip" ]] \
     && _dpr_cleanup_shape "$root" "$r" "$slug"; then
    return 0
  fi
  _dpr_sync_shape "$root" "$r" "$slug" || return 1
  dpr_verified_has "$slug" "$r" || return 1
  p1="$(git -C "$root" rev-parse -q --verify "${r}^1" 2>/dev/null)" || return 1
  _dpr_cleanup_shape "$root" "$p1" "$slug" || return 1
  [[ "$(git -C "$root" rev-parse -q --verify "${p1}^" 2>/dev/null)" == "$tip" ]]
}

# _dpr_as_fallback <종류> <사유> <slug> <기본 브랜치> <충돌 경로(줄 구분)> [<추가 값>] — 자동 병합 fallback 경고(spec D5, stderr).
#   종류: undecidable(판정 불가) / other(대상 밖 충돌) / commit(병합 커밋 생성·검증 실패) / verifysig(서명 설정)
#         / ignored(무시 파일 겹침 — 추가 값은 파일 목록) / index(색인 기록 실패 — 추가 값은 색인 경로)
_dpr_as_fallback() {
  local kind="$1" why="$2" slug="$3" def="$4" paths="$5" extra="${6-}" p='archive:   '
  {
    printf 'archive: WARNING — origin/%s 과 합치면 기록 파일이 충돌하지만 자동 병합을 하지 못했습니다: %s\n' "$def" "$why"
    printf '%sPR 이 GitHub 에서 충돌로 보입니다. 충돌 파일:\n' "$p"
    printf '%s\n' "$paths" | grep -v '^$' | sed "s/^/${p}  /"
    case "$kind" in
      undecidable)
        printf '%s확인: bash rd-workflow/scripts/rd pr check --task %s\n' "$p" "$slug"
        printf '%s사유를 풀 수 있으면(설정·속성 제거) 그 뒤 bash rd-workflow/scripts/rd pr sync --task %s\n' "$p" "$slug" ;;
      verifysig)
        printf '%s이 설정에서는 rd pr sync 의 마무리 이동도 막힙니다.\n' "$p"
        dpr_verifysig_guide "$slug" "$def" | sed "s/^/${p}/"
        printf '%s설정을 끌 수 있으면 끈 뒤 bash rd-workflow/scripts/rd pr sync --task %s\n' "$p" "$slug" ;;
      ignored)
        printf '%s작업 worktree 의 무시 파일이 origin/%s 가 추적하는 경로에 있습니다:\n' "$p" "$def"
        printf '%s\n' "$extra" | grep -v '^$' | sed "s/^/${p}  /"
        printf '%s이 파일들을 작업 worktree 밖으로 옮긴 뒤, PR 이 올라가면 bash rd-workflow/scripts/rd pr sync --task %s\n' "$p" "$slug" ;;
      index)
        printf '%s색인: %s\n' "$p" "$extra"
        printf '%s순서: 1) 작업 색인을 쓸 수 있게 고칩니다\n' "$p"
        printf '%s      2) bash rd-workflow/scripts/rd pr open --task %s\n' "$p" "$slug"
        printf '%s      3) bash rd-workflow/scripts/rd pr check --task %s\n' "$p" "$slug" ;;
      *)
        printf '%s확인: bash rd-workflow/scripts/rd pr check --task %s\n' "$p" "$slug" ;;
    esac
  } >&2
}

# _dpr_publish_autosync <root> <wt> <slug> <fr> <기본 브랜치> <tip> <되돌리기 커밋> — 발행 P6 뒤 자동 병합(spec D4).
#   되돌리기 커밋과 origin/<기본> 이 기록 파일만 충돌하면 rd pr sync 와 같은 트리 계산·검증으로 병합 커밋을 만들고 pr-verified 에 기록합니다.
#   결과는 전역 _DPR_AS_HEAD(병합 커밋 OID, 병합하지 않으면 빈 값). 늘 rc 0 — fallback 은 실패가 아닙니다(되돌리기 커밋을 올림).
#   성공 줄·fallback 경고는 stderr. 저장소의 ref·index·작업 트리는 바꾸지 않습니다(객체와 색인 pr-verified 만 씀).
_DPR_AS_HEAD=""
_dpr_publish_autosync() {
  local root="$1" wt="$2" slug="$3" fr="$4" def="$5" tip="$6" cl="$7"
  local b mt mrc paths tree rc ef err m clash vs
  _DPR_AS_HEAD=""
  # 1. 충돌 판정 — 충돌이 없으면 아무것도 하지 않습니다(비목표: 충돌 없는 앞섬의 병합).
  #   기본 커밋 OID 를 먼저 한 번 읽고 판정·트리 계산·둘째 부모에 모두 씁니다(그사이 추적 ref 가 전진해도 어긋나지 않게).
  b="$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/${def}^{commit}" 2>/dev/null)" || {
    _dpr_as_fallback undecidable "origin/$def 를 읽을 수 없습니다" "$slug" "$def" ""; return 0; }
  mrc=0; mt="$(git -C "$root" merge-tree --write-tree --name-only --no-messages "$cl" "$b" 2>/dev/null)" || mrc=$?
  [[ "$mrc" != 0 ]] || return 0
  if [[ "$mrc" != 1 ]]; then
    _dpr_as_fallback undecidable "merge-tree 판정 실패 (rc $mrc)" "$slug" "$def" ""
    return 0
  fi
  paths="$(printf '%s\n' "$mt" | sed '1d')"
  # 2. 서명 확인 설정 — 작업 브랜치를 병합 커밋으로 옮기는 fast-forward 가 서명 없는 커밋에서 막힙니다.
  vs=0; dpr_verifysig_on "$wt" "$fr" || vs=$?
  if [[ "$vs" == 2 ]]; then
    _dpr_as_fallback undecidable "작업 worktree 에서 git merge 를 시험할 수 없습니다 ($_DPR_VS_OUT)" "$slug" "$def" "$paths"
    return 0
  fi
  if [[ "$vs" == 0 ]]; then
    _dpr_as_fallback verifysig "서명 확인 설정(merge.verifySignatures)이 켜져 있어 서명 없는 병합 커밋으로 작업 브랜치를 옮길 수 없습니다" "$slug" "$def" "$paths"
    return 0
  fi
  # 3. 트리 계산 (rd pr sync 와 같은 함수)
  ef="$(mktemp "${TMPDIR:-/tmp}/rd-dpras.XXXXXX" 2>/dev/null)" || ef=""
  rc=0; tree="$(RD_MERGE_RESOLVE_QUIET=1 dpr_sync_tree "$root" "$cl" "$b" 2>"${ef:-/dev/null}")" || rc=$?
  err=""; [[ -z "$ef" ]] || { err="$(head -1 "$ef")"; rm -f "$ef"; }
  case "$rc" in
    0) ;;
    1) _dpr_as_fallback other "자동 해소 대상 밖 충돌 ($(printf '%s\n' "$tree" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'))" "$slug" "$def" "$paths"; return 0 ;;
    *) _dpr_as_fallback undecidable "${err:-자동 병합을 대조할 수 없습니다}" "$slug" "$def" "$paths"; return 0 ;;
  esac
  # 4. 병합 커밋 — 첫 부모 되돌리기 커밋, 둘째 부모 origin/<기본> (dpr_published_head 의 (나) 가 인정하는 모양)
  m="$(git -C "$root" commit-tree "$tree" -p "$cl" -p "$b" -m "$(_dpr_sync_subject "$def" "$fr")" 2>/dev/null)" && [[ -n "$m" ]] || {
    _dpr_as_fallback commit "병합 커밋을 만들지 못했습니다" "$slug" "$def" "$paths"; return 0; }
  # 5. 무시 파일 겹침 — 작업 브랜치를 병합 커밋으로 옮길 때 덮이거나 멈출 파일
  clash="$(dpr_ignored_clash "$root" "$wt" "$tip" "$m")" || {
    _dpr_as_fallback ignored "작업 worktree 의 무시 파일이 병합 결과의 경로와 겹칩니다" "$slug" "$def" "$paths" "$clash"; return 0; }
  # 6. 검증 — rd 가 발행한 head 로 인정되는지
  dpr_published_head "$root" "$m" "$slug" "refs/remotes/origin/${def}" >/dev/null 2>&1 || {
    _dpr_as_fallback commit "만든 병합 커밋이 검증을 통과하지 못했습니다" "$slug" "$def" "$paths"; return 0; }
  # 7. 검증된 head 목록에 기록 (P7·P8 보다 앞)
  if ! err="$(dpr_verified_add "$slug" "$cl" "$m" 2>&1)"; then
    _dpr_as_fallback index "검증된 head 목록에 기록하지 못했습니다 — $(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -1)" \
      "$slug" "$def" "$paths" "$(tasks_index_path 2>/dev/null)"
    return 0
  fi
  _DPR_AS_HEAD="$m"
  printf 'archive: origin/%s 과 기록 파일 충돌을 자동 병합했습니다 (병합 커밋 %s)\n' "$def" "$(git -C "$root" rev-parse --short "$m")" >&2
  printf 'archive:   해소한 기록 파일: %s\n' "$(printf '%s\n' "$paths" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')" >&2
  return 0
}

# dpr_verifysig_on <wt> <fr> — 작업 브랜치의 fast-forward 가 서명 확인에 막히는 설정이면 rc 0, 아니면 rc 1, 판정할 수 없으면 rc 2.
#   rc 2 는 git 이 서명 검사 전에 병합을 거부한 경우(진행 중인 cherry-pick·revert 등)이며, 그 출력 첫 줄을 _DPR_VS_OUT 에 둡니다.
#   설정을 셸로 해석하지 않고 git 에게 직접 묻습니다: 작업 worktree 에서 서명 없는 고아 커밋을 --ff-only --no-squash 로 병합해 봅니다.
#   git 은 merge.verifySignatures 와 branch.<현재 브랜치>.mergeOptions(따옴표·이스케이프·약칭·옵션 인자·뒤 옵션 우선)를 실제 이동과
#   같은 방식으로 적용하고, 서명 확인이 켜져 있으면 다른 검사보다 먼저 서명 거부로 끝납니다. 꺼져 있으면 무관한 이력이라 거부합니다.
#   어느 쪽이든 HEAD·색인·작업 트리는 바뀌지 않습니다. 이 두 결과가 아니면(고아 커밋을 만들지 못한 경우 포함) 꺼짐으로 치지 않고 rc 2 입니다.
#   <fr> 인자는 호출 호환용이며, 판정은 작업 worktree 의 현재 브랜치 설정을 따릅니다(실제 이동도 그 브랜치에서 일어납니다).
#   rd 가 만드는 병합 커밋은 서명이 없으므로 이 설정에서는 옮길 수 없습니다. 설정을 덮어쓰지 않고(--no-verify-signatures 를 쓰지 않음) 사람에게 넘깁니다.
_DPR_VS_OUT=""
dpr_verifysig_on() {
  local wt="$1" tree probe out rc=0 orig
  _DPR_VS_OUT="시험 커밋을 만들 수 없습니다"
  tree="$(git -C "$wt" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" || return 2
  probe="$(git -C "$wt" commit-tree --no-gpg-sign "$tree" -m rd-verifysig-probe </dev/null 2>/dev/null)" || return 2
  # git merge 는 실패해도 ORIG_HEAD 를 현재 HEAD 로 바꿉니다. 사용자의 복구 지점이므로 판정 뒤 원래 값으로 되돌립니다.
  orig="$(git -C "$wt" rev-parse -q --verify ORIG_HEAD 2>/dev/null)"
  out="$(LC_ALL=C git -C "$wt" merge -q --ff-only --no-squash --no-autostash --no-overwrite-ignore "$probe" 2>&1)" || rc=$?
  if [[ -n "$orig" ]]; then git -C "$wt" update-ref --no-deref ORIG_HEAD "$orig" 2>/dev/null
  else git -C "$wt" update-ref -d ORIG_HEAD 2>/dev/null; fi
  [[ "$rc" -eq 0 ]] && return 0
  dpr_sig_refused "$out" && return 0
  printf '%s\n' "$out" | grep -q '^fatal: refusing to merge unrelated histories' && return 1
  _DPR_VS_OUT="$(printf '%s\n' "$out" | grep -v '^$' | head -1)"
  return 2
}

# dpr_sig_refused <git 출력> — git merge 가 서명 확인으로 거부한 출력이면 rc 0. 진단 줄(fatal: Commit <oid> … GPG signature)에만 맞춥니다 —
#   덮어쓸 파일 목록에 같은 문자열이 든 경로가 있어도 서명 거부로 보지 않게.
dpr_sig_refused() {
  printf '%s\n' "$1" | grep -qE '^fatal: Commit [0-9a-f]+ (does not have a GPG signature|has an untrusted GPG signature|has a bad GPG signature)'
}

# dpr_verifysig_guide <slug> <기본 브랜치> — 서명 확인 설정을 유지한 채 복구하는 조건과 순서를 stdout 에 냅니다(sync 사전 멈춤·발행 fallback 공용).
#   작업 브랜치에 기본 브랜치를 병합하는 git merge 도 같은 서명 확인을 거치므로, 기본 브랜치 끝 커밋에 신뢰할 수 있는 서명이 있어야 합니다.
dpr_verifysig_guide() {
  local slug="$1" def="$2"
  printf '  설정을 유지한 채 복구하려면 origin/%s 끝 커밋에 신뢰할 수 있는 서명이 있어야 합니다(작업 브랜치에 병합하는 git merge 도 같은 확인을 거칩니다).\n' "$def"
  printf '  작업 상태를 바꾸기 전에 작업 worktree 에서 확인하십시오: git verify-commit %s\n' "$(dpr_shq "origin/$def")"
  printf '  서명이 확인되면 아래 순서로 복구합니다:\n'
  dpr_conflict_guide "$slug" "$def"
  printf '  서명이 확인되지 않으면 이 설정으로는 기본 브랜치를 병합할 수 없습니다 — 서명된 커밋이 origin/%s 에 올라온 뒤 다시 확인하거나 설정을 끕니다.\n' "$def"
}

# dpr_ff_move <wt> <head> — 작업 worktree 의 현재 브랜치를 head 로 fast-forward 합니다. rc 0 이동 / rc 1 멈춤(git 출력은 전역 _DPR_FF_OUT).
#   --no-squash: branch.<fr>.mergeOptions=--squash 가 있으면 --ff-only 와 함께 HEAD 를 그대로 두고 rc 0 을 냅니다.
#   그래서 옵션을 끄고, rc 0 이어도 HEAD 가 head 인지 확인합니다. 무시 파일은 덮지 않습니다(git 메시지 판별에 LC_ALL=C).
_DPR_FF_OUT=""
dpr_ff_move() {
  local wt="$1" head="$2"
  _DPR_FF_OUT="$(LC_ALL=C git -C "$wt" merge -q --ff-only --no-squash --no-autostash --no-overwrite-ignore "$head" 2>&1)" || return 1
  [[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" == "$(git -C "$wt" rev-parse "$head^{commit}" 2>/dev/null)" ]] && return 0
  _DPR_FF_OUT="git merge 가 rc 0 으로 끝났지만 작업 브랜치 HEAD 가 $(git -C "$wt" rev-parse --short "$head" 2>/dev/null || printf '%s' "$head") 이 아닙니다(git status 로 확인하십시오)"
  return 1
}

# _dpr_move_branch <wt> <head> — 발행 P8 에서 작업 브랜치를 push 한 head 로 옮깁니다(spec D7). rc 0 이동 / rc 1 멈춤(안내는 stderr).
#   병합 커밋(부모 둘)은 fast-forward 로만 옮기고 무시 파일을 덮지 않습니다. 실패해도 원격·색인·파일은 그대로 두며 같은 발행 요청으로 이어 갑니다.
#   되돌리기 커밋(부모 하나)은 종전대로 reset --keep 입니다.
_dpr_move_branch() {
  local wt="$1" head="$2" parents out short ef
  parents="$(git -C "$wt" rev-list --parents -n 1 "$head" 2>/dev/null)" || parents=""
  set -- $parents
  if [[ "$#" -eq 3 ]]; then
    dpr_ff_move "$wt" "$head" && return 0
    out="$_DPR_FF_OUT"
    short="$(git -C "$wt" rev-parse --short "$head" 2>/dev/null || printf '%s' "$head")"
    {
      printf 'archive: PR 발행 멈춤 — P8 작업 브랜치 이동: push 는 끝났지만 작업 브랜치를 병합 커밋(%s)으로 옮기지 못했습니다.\n' "$short"
      if printf '%s\n' "$out" | grep -qE 'untracked working tree files would be overwritten|would lose untracked files' \
         && ! printf '%s\n' "$out" | grep -q 'Your local changes to the following files would be overwritten'; then
        printf '%s\n' "$out" | sed -n 's/^[[:space:]][[:space:]]*\([^[:space:]].*\)$/archive:     \1/p'
        printf 'archive:   이 파일들을 작업 worktree 밖으로 옮긴 뒤 같은 발행 요청을 다시 하십시오: %s\n' "$_DPR_PUBLISH_CMD"
      else
        printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -8 | sed 's/^/archive:     /'
        printf 'archive:   원인을 푼 뒤 같은 발행 요청을 다시 하십시오: %s\n' "$_DPR_PUBLISH_CMD"
        printf 'archive:   직접 옮기려면: git -C %s merge --ff-only --no-squash --no-overwrite-ignore %s\n' "$(dpr_shq "$wt")" "$head"
      fi
    } >&2
    return 1
  fi
  ef="$(mktemp "${TMPDIR:-/tmp}/rd-dprmb.XXXXXX" 2>/dev/null)" || ef=/dev/null
  if ! git -C "$wt" reset -q --keep "$head" 2>"$ef"; then
    _dpr_fail "P8 push" "push 는 끝났지만 작업 브랜치를 되돌리기 커밋으로 옮기지 못했습니다: $(head -1 "$ef" 2>/dev/null)" \
      "같은 발행 요청을 다시 하면 이어 갑니다: $_DPR_PUBLISH_CMD"
    [[ "$ef" == /dev/null ]] || rm -f "$ef"
    return 1
  fi
  [[ "$ef" == /dev/null ]] || rm -f "$ef"
  return 0
}

# dpr_publish <slug> <fr-branch> <default-branch> — spec D3 P1~P10. 락을 쥔 archive.sh 가 부릅니다.
# 기본 브랜치·기본 worktree 를 바꾸지 않고, force push 하지 않고, 태그를 달지 않고, worktree·fr 브랜치를 지우지 않습니다.
# rc 0 성공 / 1 실패(원인·재시도 명령은 stderr).
dpr_publish() {
  local slug="${1:?slug}" fr="${2:?fr-branch}" def="${3:?default-branch}" body errf rc=0
  _dpr_load_tp || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/rd-dprpb.XXXXXX")" || return 1
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dprpe.XXXXXX")" || { rm -f "$body"; return 1; }
  _dpr_publish_run "$slug" "$fr" "$def" "$body" "$errf" || rc=$?
  rm -f "$body" "$errf"
  return "$rc"
}

_dpr_publish_run() {
  local slug="$1" fr="$2" def="$3" body="$4" errf="$5"
  local root wt tip repo out open_url=""
  local rline remote_oid p_rc mrc new head pushed="" resume_conflict="" rcode=0
  root="$(_dpr_root)"

  # P1 — 작업 worktree 확인
  wt="$(_dpr_fr_worktree "$fr")" && wt="${wt%/}" || {
    _dpr_fail "P1 작업 worktree 확인" "$fr 브랜치를 체크아웃한 worktree 를 찾을 수 없습니다" "$_DPR_PUBLISH_CMD (작업 worktree 를 복구한 뒤 다시 발행 요청)"
    return 1; }
  tip="$(git -C "$root" rev-parse --verify -q "refs/heads/${fr}^{commit}" 2>/dev/null)" || {
    _dpr_fail "P1 작업 worktree 확인" "$fr 브랜치를 읽을 수 없습니다" "$_DPR_PUBLISH_CMD"; return 1; }
  out="$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" || out="status 조회 실패"
  if [[ -n "$out" || "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$tip" ]]; then
    _dpr_fail "P1 작업 worktree 확인" "작업 worktree($wt)에 미커밋 변경이 있거나 HEAD 가 $fr 의 끝과 다릅니다" \
      "작업 worktree 에서 커밋하거나 정리한 뒤 다시 발행 요청: $_DPR_PUBLISH_CMD" \
      "$(printf '%s' "$out" | head -5 | tr '\n' ' ')"
    return 1
  fi

  # P2 — 기존 PR 조회
  repo="$(dpr_origin_repo)" || { _dpr_fail "P2 기존 PR 조회" "origin 저장소 이름을 알 수 없습니다" "$_DPR_PUBLISH_CMD"; return 1; }
  _dpr_p2_lookup "$slug" "$fr" "$def" "$repo" "$errf" || return 1
  open_url="$_DPR_OPEN_URL"

  # P3 — 원격 fr 브랜치 확인 (force push 하지 않으므로 원격이 앞서 있으면 멈춥니다)
  rcode=0; rline="$(git -C "$root" ls-remote origin "refs/heads/${fr}" 2>"$errf")" || rcode=$?
  if [[ "$rcode" != 0 ]]; then
    _dpr_fail "P3 원격 fr 브랜치 확인" "git ls-remote origin 실패: $(head -1 "$errf")" "$_DPR_PUBLISH_CMD"; return 1
  fi
  remote_oid="${rline%%[[:space:]]*}"
  if [[ -n "$remote_oid" ]]; then
    if ! git -C "$root" fetch -q origin "+refs/heads/${fr}:refs/remotes/origin/${fr}" 2>"$errf"; then
      _dpr_fail "P3 원격 fr 브랜치 확인" "원격 $fr 를 가져오지 못했습니다: $(head -1 "$errf")" "$_DPR_PUBLISH_CMD"; return 1
    fi
    # ls-remote 와 fetch 사이에 원격이 전진했을 수 있으므로, 판정은 fetch 가 가져온 끝으로 합니다.
    remote_oid="$(git -C "$root" rev-parse -q --verify "refs/remotes/origin/${fr}^{commit}" 2>/dev/null)" || remote_oid=""
    if [[ -z "$remote_oid" ]]; then
      _dpr_fail "P3 원격 fr 브랜치 확인" "가져온 origin/$fr 를 읽지 못했습니다" "$_DPR_PUBLISH_CMD"; return 1
    fi
    if ! git -C "$root" merge-base --is-ancestor "$remote_oid" "$tip" 2>/dev/null; then
      # 이전 발행이 push 뒤·브랜치 이동 전에 끊겼으면 원격 끝은 이 tip 위의 되돌리기 커밋이거나 그 위의 검증된 자동 병합 커밋입니다
      # — 그 커밋으로 이어 갑니다(P8, spec D2).
      if dpr_resume_head "$root" "$slug" "$fr" "$tip" "$remote_oid"; then
        pushed="$remote_oid"
      else
        _dpr_fail "P3 원격 fr 브랜치 확인" "원격 fr 브랜치가 앞서 있습니다. force push 하지 않습니다." \
          "$_DPR_PUBLISH_CMD (git log ${fr}..origin/${fr} 로 확인하고 합치거나 정리한 뒤 다시 발행 요청)" \
          "확인: git log ${fr}..origin/${fr}"
        return 1
      fi
    fi
  fi

  # P4 — 충돌 사전 감지 (기본 브랜치와 합칠 때 자동 해소 대상 다섯 경로 밖에서 충돌하면 멈춥니다)
  if ! git -C "$root" fetch -q origin "+refs/heads/${def}:refs/remotes/origin/${def}" 2>"$errf"; then
    _dpr_fail "P4 충돌 사전 감지" "origin/$def 를 가져오지 못했습니다: $(head -1 "$errf")" "$_DPR_PUBLISH_CMD"; return 1
  fi
  if [[ -z "$pushed" ]]; then
    p_rc=0; out="$(rd_merge_conflicts "$root" "refs/remotes/origin/${def}" "$tip")" || p_rc=$?
    case "$p_rc" in
      0) ;;
      1)
        printf 'archive: PR 발행 실패 — P4 충돌 사전 감지: origin/%s 와 합치면 충돌합니다 (자동 해소 대상 밖):\n' "$def" >&2
        printf '%s\n' "$out" | sed 's/^/archive:     /' >&2
        rd_merge_conflict_guide "archive:   " "$fr" "origin/${def}" "$wt" >&2
        printf 'archive:   재시도: 위 순서를 마친 뒤 %s\n' "$_DPR_PUBLISH_CMD" >&2
        return 1 ;;
      *)
        _dpr_fail "P4 충돌 사전 감지" "충돌 여부를 판정할 수 없습니다 (merge-tree 실패)" "$_DPR_PUBLISH_CMD"; return 1 ;;
    esac
    # 기록 파일만 충돌하면 P6 뒤 자동 병합 단계(_dpr_publish_autosync)가 풉니다(spec D3·D4).
  else
    # 재개: 이미 push 한 head 로 이어 가므로 충돌로 멈추지 않습니다. 충돌이면 PR 생성·갱신이 끝난 뒤에만 알립니다(spec D3).
    mrc=0; git -C "$root" merge-tree --write-tree "refs/remotes/origin/${def}" "$pushed" >/dev/null 2>&1 || mrc=$?
    [[ "$mrc" != 1 ]] || resume_conflict=1
  fi

  # P5 — PR 제목·본문 (입력 커밋은 정리 전 fr tip)
  rcode=0; out="$(dpr_pr_text "$wt" "$tip" "$body" 2>"$errf")" || rcode=$?
  if [[ "$rcode" != 0 ]]; then
    _dpr_fail "P5 PR 제목·본문 준비" "PR 본문을 만들 수 없습니다 — final diff review 세션의 Author 턴에 '## PR 본문' 절이 있어야 합니다" \
      "그 세션의 다음 Author 턴에 '## PR 본문' 절 전체를 싣고 커밋한 뒤 $_DPR_PUBLISH_CMD" "$(grep -v '^rd pr: WARNING' "$errf" | head -2 | tr '\n' ' ')"
    return 1
  fi
  grep '^rd pr: WARNING' "$errf" >&2 || true
  local title="$out"

  # P6 — 작업 상태 되돌리기 커밋. 커밋을 만든 즉시 브랜치는 원래 끝(tip)으로 돌려 두고, push 가 성공한 뒤에만
  # 그 커밋으로 옮깁니다(P8). 그래서 push 전에 끊기거나 push 가 실패해도 작업은 아카이브 보류 그대로 남고,
  # 같은 발행 요청으로 처음부터 다시 진행합니다.
  if [[ -n "$pushed" ]]; then
    new="$pushed"
    if _dpr_sync_shape "$root" "$new" "$slug"; then
      printf 'archive: 이전 발행이 push 뒤에 끊겼습니다 — 원격의 자동 병합 커밋(%s)으로 이어 갑니다\n' "$(git -C "$root" rev-parse --short "$new")" >&2
    else
      printf 'archive: 이전 발행이 push 뒤에 끊겼습니다 — 원격의 되돌리기 커밋(%s)으로 이어 갑니다\n' "$(git -C "$root" rev-parse --short "$new")" >&2
    fi
  else
    rcode=0; new="$(dpr_cleanup_commit "$wt" "$slug" 2>"$errf")" || rcode=$?
    if [[ "$rcode" != 0 || -z "$new" ]]; then
      _dpr_fail "P6 작업 상태 되돌리기 커밋" "커밋을 만들지 못했습니다 (작업 worktree 는 이전 상태로 복원했습니다)" \
        "원인을 해소한 뒤 $_DPR_PUBLISH_CMD" "$(cat "$errf" | head -6 | tr '\n' ' ')"
      return 1
    fi
    if ! git -C "$wt" reset -q --keep "$tip" 2>"$errf"; then
      _dpr_fail "P6 작업 상태 되돌리기 커밋" "커밋을 만든 뒤 브랜치를 원래 끝으로 돌려 두지 못했습니다: $(head -1 "$errf")" \
        "git -C $wt reset --keep $tip 뒤 $_DPR_PUBLISH_CMD"
      return 1
    fi
  fi

  # P6 뒤 자동 병합 (spec D4·D6) — 기록 파일만 충돌하면 검증된 병합 커밋을 head 로 올립니다. 못 하면 되돌리기 커밋을 그대로 올립니다.
  _DPR_AS_HEAD=""
  [[ -n "$pushed" ]] || _dpr_publish_autosync "$root" "$wt" "$slug" "$fr" "$def" "$tip" "$new"
  head="${_DPR_AS_HEAD:-$new}"

  # P7 — 색인 기록 (실패는 경고만)
  dpr_index_set "$slug" "pr-mode=direct" "pr-head=${head}" "pr-base=${def}" \
    || printf 'archive: WARNING — 작업 색인에 PR 발행 정보를 쓰지 못했습니다(pr-head)\n' >&2

  # P8 — push (force 없음) 뒤 작업 브랜치를 발행 head 로 옮김
  if [[ -z "$pushed" ]]; then
    # push.followTags 설정이 있어도 로컬 태그를 함께 보내지 않습니다(원격에서 바뀌는 ref 는 fr 브랜치 하나).
    rcode=0; out="$(git -C "$wt" push --no-follow-tags origin "${head}:refs/heads/${fr}" 2>&1)" || rcode=$?
    if [[ "$rcode" != 0 ]]; then
      dpr_index_set "$slug" "pr-head=" || true
      _dpr_fail "P8 push" "git push 실패 (작업 브랜치는 바꾸지 않았습니다)" "원인을 해소한 뒤 $_DPR_PUBLISH_CMD" \
        "git 진단:" "$(printf '%s\n' "$out" | head -8 | sed 's/^/  /')"
      return 1
    fi
  fi
  _dpr_move_branch "$wt" "$head" || return 1

  # P9·P10 — PR 생성·갱신과 결과 (rd pr open 도 같은 함수를 부릅니다)
  rcode=0; _dpr_pr_submit "$slug" "$fr" "$def" "$repo" "$title" "$body" "$errf" "$open_url" "$head" || rcode=$?
  if [[ "$rcode" == 0 && -n "$resume_conflict" ]]; then
    printf 'archive: WARNING — 이어 간 head 가 origin/%s 과 충돌합니다. PR 이 GitHub 에서 충돌로 보입니다.\n' "$def" >&2
    printf 'archive:   확인: bash rd-workflow/scripts/rd pr check --task %s\n' "$slug" >&2
  fi
  return "$rcode"
}

# dpr_conflict_guide <slug> <기본 브랜치> — 충돌·수정 요청 뒤 이어 가는 순서(spec D9).
dpr_conflict_guide() {
  local slug="$1" def="$2"
  printf '  순서:\n'
  printf '    1) bash rd-workflow/scripts/rd pr reopen --task %s   (작업을 구현 중으로 되돌림)\n' "$slug"
  printf '    2) 작업 worktree 에서 git merge --no-squash %s → 충돌 해소·커밋 (충돌이 아니라 수정 요청이면 수정·커밋)\n' "$(dpr_shq "origin/$def")"
  printf '    3) 재검증 → 새 final diff review → bash rd-workflow/scripts/rd review seal → 아카이브 보류 → 기록 커밋\n'
  printf '    4) bash rd-workflow/scripts/rd publish request   (열린 PR 의 본문을 갱신하고 fast-forward 로 push 합니다)\n'
}

# dpr_ignored_clash <root> <wt> <옛 head> <새 head> — 옛 head 에 없고 새 head 가 추적하는 경로 A 가 작업 worktree 에서 이미 쓰이고 있으면
# (A 자리에 무엇이 있거나, A 의 상위 경로 자리에 디렉터리가 아닌 무엇이 있으면) 옮겨야 할 파일을 stdout 에 냅니다. 있으면 rc 1, 없으면 rc 0.
# 1단계가 작업 worktree 의 HEAD 가 옛 head 이고 무시되지 않은 미추적 파일이 없음을 확인했으므로, 그 자리에 있는 것은 무시 파일입니다.
# 문자열 비교 대신 파일시스템에 묻습니다 — 대소문자·유니코드 정규화를 같게 보는 볼륨에서도 git 이 실제로 부딪히는 경로를 그대로 찾습니다.
# 경로는 -z 원본 바이트로 다루고(줄바꿈·제어 문자 포함), 화면에는 줄바꿈을 \n 으로 보입니다. 비용은 추가 경로 수 × 경로 깊이의 파일 확인입니다.
dpr_ignored_clash() {
  local root="$1" wt="$2" old="$3" new="$4" af hf a d f n p wr
  af="$(mktemp)" && hf="$(mktemp)" || { printf '(임시 파일을 만들지 못했습니다)\n'; return 1; }
  if ! git -C "$root" diff -z --name-only --no-renames --diff-filter=A "$old" "$new" >"$af" 2>/dev/null; then
    rm -f "$af" "$hf"; printf '(새 head 의 추가 경로를 읽지 못했습니다)\n'; return 1
  fi
  while IFS= read -r -d '' a; do
    if [[ -e "$wt/$a" || -L "$wt/$a" ]]; then printf '%s\0' "$a" >>"$hf"; continue; fi
    d="$a"
    while [[ "$d" == */* ]]; do
      d="${d%/*}"
      if [[ -L "$wt/$d" || ( -e "$wt/$d" && ! -d "$wt/$d" ) ]]; then
        # 옛 head 가 추적하던 파일을 새 head 가 디렉터리로 바꾼 경우는 git 이 처리합니다.
        git -C "$wt" cat-file -e "${old}:${d}" 2>/dev/null || printf '%s\0' "$d" >>"$hf"
        break
      fi
    done
  done <"$af"
  if [[ ! -s "$hf" ]]; then rm -f "$af" "$hf"; return 0; fi
  # 겹친 경로마다 그 자리(또는 그 아래)의 무시 파일을 디스크의 실제 이름으로 보입니다.
  # 자리가 디렉터리인데 그 아래 무시 파일이 없으면(추적 파일만 있거나 빈 디렉터리) git 이 처리하므로 충돌이 아닙니다.
  # 자리가 파일·심링크인데 목록이 비면 경로 자체를 보입니다.
  : >"$af"
  wr="$(cd "$wt" && /bin/pwd -P && printf x)" && wr="${wr%$'\n'x}" || wr=""
  while IFS= read -r -d '' a; do
    n=0
    # 디렉터리 자리는 디스크의 실제 이름으로 찾습니다 — 대소문자를 같게 보는 볼륨에서 sLoT 이 새 경로 slot 의 자리를 차지할 수 있습니다.
    # bash 내장 pwd -P 는 입력한 대소문자를 그대로 돌려주므로 getcwd 를 쓰는 /bin/pwd 를 씁니다.
    p="$a"
    if [[ -d "$wt/$a" && ! -L "$wt/$a" && -n "$wr" ]]; then
      d="$(cd "$wt/$a" && /bin/pwd -P && printf x)" && d="${d%$'\n'x}" && [[ "$d" == "$wr"/* ]] && p="${d#"$wr"/}"
    fi
    while IFS= read -r -d '' f; do printf '%s\n' "${f//$'\n'/\\n}" >>"$af"; n=1; done \
      < <(git -C "$wt" ls-files -z --others --ignored --exclude-standard -- ":(literal)$p" 2>/dev/null)
    [[ "$n" == 1 ]] && continue
    [[ -d "$wt/$a" && ! -L "$wt/$a" ]] && continue
    printf '%s\n' "${a//$'\n'/\\n}" >>"$af"
  done <"$hf"
  if [[ ! -s "$af" ]]; then rm -f "$af" "$hf"; return 0; fi
  sort -u "$af"
  rm -f "$af" "$hf"
  return 1
}
