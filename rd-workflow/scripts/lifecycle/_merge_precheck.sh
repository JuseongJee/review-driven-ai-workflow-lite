#!/usr/bin/env bash
# _merge_precheck.sh — 병합 충돌 사전 판정 공용 함수 (source 전용).
#   archive.sh 와 publish_queue.sh 가 같이 쓴다. 시간 상한 실행기 _rd_run_limited 가 정의돼 있지 않을 때만
#   ../_submodule_common.sh(함수 정의만 있는 파일)를 source 한다. 그 밖의 파일은 source 하지 않는다.
#   인덱스 충돌 판정에서 같은 디렉터리의 merge_fr_index.sh 를 하위 프로세스로 실행한다(source 아님).
#   set -euo pipefail 아래에서 source 돼도 안전하다(실패 가능한 대입은 `|| rc=$?`).
#   gitlink 객체 찾기(rd_gl_*)는 _state_common.sh 의 _rd_is_repo_root·_rd_git_common_dir·_rd_submodule_object_pool 을
#   실행 시점에 부른다. 호출부(archive.sh·publish_queue.sh·fr_do/grant_check.sh)는 모두 _lifecycle_common.sh 를 먼저
#   source 한다. 함수가 정의되지 않았으면 그 단계를 건너뛰고, 객체를 찾지 못한 판정은 rc 3(충돌로 다룸)이 된다.
#   Spec: rd-workflow-workspace/specs/changes/2026-11-04-2100-lifecycle-pipe-merge-check-change-spec.md (D3)
#         rd-workflow-workspace/specs/changes/2026-11-18-0900-archive-merge-publish-targets-change-spec.md (D1-1~D1-3)

# 병합 자동 해소 대상 다섯 파일(줄바꿈 구분). archive.sh 병합 단계의 자동 해소 분기가 이 순서로 꺼내 쓴다(sed -n Np).
#   순서를 바꾸지 않는다. 새 경로는 끝에 더한다.
RD_MERGE_AUTO_RESOLVE_PATHS="CURRENT_TASK.md
rd-workflow-workspace/.lifecycle/stage_metrics.tsv
rd-workflow-workspace/backlog/FUTURE_REQUESTS.md
rd-workflow-workspace/.lifecycle/review-seals/verify-evidence
rd-workflow-workspace/.lifecycle/task-state"

# 인덱스 병합기 위치: 이 파일과 같은 디렉터리 (spec 2026-11-17-1710-archive-publish-fixes D3-3).
#   source 시점에 잡아 둔다. 디렉터리를 정하지 못하면 빈 값이 되고, 인덱스 충돌 판정에서 판정 불가(rc 3)가 된다.
_RD_MERGE_PRECHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _RD_MERGE_PRECHECK_DIR=""
_RD_MERGE_FR_INDEX="rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"

# _rd_merge_index_sim <repo-dir> <ours> <theirs>
#   인덱스의 base·ours·theirs blob 으로 merge_fr_index.sh 를 미리 돌린다 (D3-1·D3-2).
#   rc 0 병합 가능 / 1 병합 불가(stderr 사유 한 줄) / 3 판정 불가(병합기 없음·임시 디렉터리 실패)
_rd_merge_index_sim() {
  local dir="$1" ours="$2" theirs="$3" merger bases n d why="" rc=0
  merger="${_RD_MERGE_PRECHECK_DIR:+$_RD_MERGE_PRECHECK_DIR/merge_fr_index.sh}"
  [[ -n "$merger" && -f "$merger" ]] || { echo "rd_merge_conflicts: 인덱스 병합기를 찾지 못했습니다 (${merger:-<경로 없음>})" >&2; return 3; }
  bases="$(git -C "$dir" merge-base --all "$ours" "$theirs" 2>/dev/null)" || bases=""
  n="$(printf '%s' "$bases" | grep -c .)" || n=0
  if [[ "$n" -ne 1 ]]; then
    why="merge-base 가 하나가 아닙니다 (${n}개)"
  else
    d="$(mktemp -d)" || { echo "rd_merge_conflicts: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 3; }
    if ! git -C "$dir" show "$bases:$_RD_MERGE_FR_INDEX" >"$d/base" 2>/dev/null; then why="base 판의 인덱스를 꺼낼 수 없습니다"
    elif ! git -C "$dir" show "$ours:$_RD_MERGE_FR_INDEX" >"$d/ours" 2>/dev/null; then why="ours 판의 인덱스를 꺼낼 수 없습니다"
    elif ! git -C "$dir" show "$theirs:$_RD_MERGE_FR_INDEX" >"$d/theirs" 2>/dev/null; then why="theirs 판의 인덱스를 꺼낼 수 없습니다"
    else
      bash "$merger" "$d/base" "$d/ours" "$d/theirs" >/dev/null 2>"$d/err" || rc=$?
      if [[ "$rc" -ne 0 ]]; then
        why="$(head -n 1 "$d/err")"
        [[ -n "$why" ]] || why="병합기 rc $rc"
      fi
    fi
    rm -rf "$d"
  fi
  [[ -z "$why" ]] && return 0
  echo "rd_merge_conflicts: FUTURE_REQUESTS.md 는 자동 병합할 수 없습니다 — $why" >&2
  return 1
}

# ---------------------------------------------------------------- 제한 실행기 (spec D1-2)

# 시간 상한 실행기는 _submodule_common.sh 의 _rd_run_limited 하나만 쓴다(정의를 두 벌로 두지 않는다).
#   archive.sh 는 이미 싣고, publish_queue.sh·fr_do/grant_check.sh 는 싣지 않으므로 여기서 실어 둔다.
if ! declare -F _rd_run_limited >/dev/null 2>&1; then
  source "$(dirname "${BASH_SOURCE[0]}")/../_submodule_common.sh"
fi

# ---------------------------------------------------------------- gitlink 객체 찾기 (spec D1-2, archive 와 공용)

# 경로마다 한 셸 문맥에서 fetch 를 한 번만 하도록 시도한 경로를 줄 단위로 기록한다. 다시 source 해도 지우지 않는다.
RD_GL_FETCHED="${RD_GL_FETCHED:-}"
RD_GL_PICKED=""
RD_GL_SRC=""
_RD_GL_MODE=""; _RD_GL_DIR=""; _RD_GL_CDIR=""; _RD_GL_POOL=""

# _rd_gl_sub_dir <repo-dir> <path> — 상위 저장소 최상위 기준 submodule 경로를 낸다.
_rd_gl_sub_dir() {
  local root
  root="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$root" ]] || return 1
  printf '%s/%s\n' "$root" "$2"
}

# _rd_gl_is_sub <dir> — dir 가 초기화된 submodule 저장소의 최상위인가(_state_common.sh 의 _rd_is_repo_root, 없으면 아님).
_rd_gl_is_sub() {
  declare -F _rd_is_repo_root >/dev/null 2>&1 || return 1
  _rd_is_repo_root "$1"
}

# rd_gl_select <repo-dir> <path> <oid>... — 모든 oid 커밋을 읽을 수 있는 저장소를 고른다(rc 0). 없으면 rc 1.
#   1) <repo-dir>/<path> 의 submodule 저장소 2) 공통 git dir + 모든 submodule 객체 디렉터리(_rd_submodule_object_pool,
#   함수가 없으면 건너뜀). 고른 저장소는 rd_gl_git 이 쓴다. archive.sh 의 _archive_gitlink_is_ancestor 도 이 함수를 쓴다.
rd_gl_select() {
  local d="${1:-}" p="${2:-}" o cdir pool ok
  _RD_GL_MODE=""; _RD_GL_DIR=""; _RD_GL_CDIR=""; _RD_GL_POOL=""
  [[ -n "$d" && -n "$p" ]] || return 1
  shift 2
  [[ "$#" -gt 0 ]] || return 1
  _RD_GL_DIR="$(_rd_gl_sub_dir "$d" "$p")" || return 1
  if _rd_gl_is_sub "$_RD_GL_DIR"; then
    ok=1; for o in "$@"; do git -C "$_RD_GL_DIR" cat-file -e "${o}^{commit}" 2>/dev/null || ok=0; done
    if [[ "$ok" == 1 ]]; then _RD_GL_MODE=repo; return 0; fi
  fi
  declare -F _rd_git_common_dir >/dev/null 2>&1 && declare -F _rd_submodule_object_pool >/dev/null 2>&1 || return 1
  cdir="$(_rd_git_common_dir "$d" 2>/dev/null)" || return 1
  pool="$(_rd_submodule_object_pool "$cdir")" || return 1
  ok=1
  for o in "$@"; do
    GIT_ALTERNATE_OBJECT_DIRECTORIES="${GIT_ALTERNATE_OBJECT_DIRECTORIES:+$GIT_ALTERNATE_OBJECT_DIRECTORIES:}$pool" \
      git --git-dir="$cdir" cat-file -e "${o}^{commit}" 2>/dev/null || ok=0
  done
  [[ "$ok" == 1 ]] || return 1
  _RD_GL_MODE=pool; _RD_GL_CDIR="$cdir"; _RD_GL_POOL="$pool"
  return 0
}

# rd_gl_git <git 인자...> — rd_gl_select 가 고른 저장소에서 git 을 실행한다.
rd_gl_git() {
  if [[ "$_RD_GL_MODE" == repo ]]; then
    git -C "$_RD_GL_DIR" "$@"
  elif [[ "$_RD_GL_MODE" == pool ]]; then
    GIT_ALTERNATE_OBJECT_DIRECTORIES="${GIT_ALTERNATE_OBJECT_DIRECTORIES:+$GIT_ALTERNATE_OBJECT_DIRECTORIES:}$_RD_GL_POOL" git --git-dir="$_RD_GL_CDIR" "$@"
  else
    return 128
  fi
}

# rd_git_noprompt_env <git 작업 디렉터리> — 원격 조회가 사용자 입력을 기다리지 않게 하는 env 인자를 RD_GIT_NOPROMPT_ENV 배열에 둔다.
#   _rd_run_limited 는 명령을 별도 프로세스 그룹(배경)에 띄우므로, 입력을 묻는 ssh(passphrase·호스트 키 확인)는 SIGTTIN 으로 멈춰
#   상한까지 기다린다. 그래서 GIT_TERMINAL_PROMPT=0 을 늘 넣고, GIT_SSH_COMMAND·GIT_SSH·core.sshCommand(<디렉터리> 기준)가
#   모두 비었을 때만 `ssh -o BatchMode=yes` 를 넣는다(사용자 전송 설정은 덮어쓰지 않는다).
#   쓰는 법: rd_git_noprompt_env "$dir"; _rd_run_limited … "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$dir" fetch …
#   호출 위치: rd_gl_fetch_once, archive.sh 의 _archive_tpg_remote(팀 저장소 반영 게이트).
RD_GIT_NOPROMPT_ENV=()
rd_git_noprompt_env() {
  local dir="${1:-.}" ssh=""
  RD_GIT_NOPROMPT_ENV=(env GIT_TERMINAL_PROMPT=0)
  if [[ -z "${GIT_SSH_COMMAND:-}" && -z "${GIT_SSH:-}" ]]; then
    ssh="$(git -C "$dir" config --get core.sshCommand 2>/dev/null)" || ssh=""
    [[ -n "$ssh" ]] || RD_GIT_NOPROMPT_ENV+=("GIT_SSH_COMMAND=ssh -o BatchMode=yes")
  fi
}

# rd_gl_fetch_once <repo-dir> <path> <miss oid> <접두> — submodule 저장소에서 제한 fetch 를 경로마다 한 번 한다.
#   rc 0: fetch 뒤 <miss oid> 커밋이 있음 / rc 1: 이미 시도한 경로, submodule 저장소 아님, fetch 실패·시간 초과, 받은 뒤에도 없음.
#   안내는 stderr 로 낸다(<접두> 는 호출부가 준다: `archive:` 또는 `rd_merge_conflicts:`).
#   입력 대기 방지 env 는 rd_git_noprompt_env 가 정한다(GIT_TERMINAL_PROMPT=0, 전송 설정이 없을 때만 BatchMode ssh).
#   상한은 RD_MERGE_FETCH_TIMEOUT(초, 기본 60)이고 _rd_run_limited 가 건다.
#   호출 위치: rd_merge_gitlink_pick, archive.sh 의 _archive_gitlink_is_ancestor.
rd_gl_fetch_once() {
  local d="${1:-}" p="${2:-}" miss="${3:-}" pre="${4:-}" dir lim errf frc=0
  local -a cmd
  [[ -n "$d" && -n "$p" ]] || return 1
  printf '%s\n' "$RD_GL_FETCHED" | grep -qxF -- "$p" && return 1
  dir="$(_rd_gl_sub_dir "$d" "$p")" || return 1
  _rd_gl_is_sub "$dir" || return 1
  RD_GL_FETCHED="${RD_GL_FETCHED}${p}"$'\n'
  lim="${RD_MERGE_FETCH_TIMEOUT:-60}"
  [[ "$lim" =~ ^[0-9]+$ && "$lim" -gt 0 ]] || lim=60
  printf '%s submodule %s 에 판정할 커밋(%s)이 없어 원격에서 받습니다\n' "$pre" "$p" "$(printf '%s' "$miss" | cut -c1-7)" >&2
  rd_git_noprompt_env "$dir"
  cmd=("${RD_GIT_NOPROMPT_ENV[@]}" git -C "$dir" fetch --quiet --no-recurse-submodules)
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-gl-fetch.XXXXXX")" || errf=/dev/null
  _rd_run_limited "$lim" "$errf" "${cmd[@]}" >/dev/null || frc=$?
  if [[ "$frc" -eq 0 ]]; then
    printf '%s submodule %s fetch 완료\n' "$pre" "$p" >&2
  elif [[ "$frc" -eq 124 ]]; then
    printf '%s submodule %s fetch 가 %s초 안에 끝나지 않아 중단했습니다\n' "$pre" "$p" "$lim" >&2
  else
    printf '%s submodule %s fetch 실패 — %s\n' "$pre" "$p" "$(sed -n 1p "$errf" 2>/dev/null)" >&2
  fi
  [[ "$errf" == /dev/null ]] || rm -f "$errf"
  [[ "$frc" -eq 0 ]] || return 1
  [[ -z "$miss" ]] && return 0
  git -C "$dir" cat-file -e "${miss}^{commit}" 2>/dev/null
}

# rd_gl_src <repo-dir> <path> <oid> — <oid> 커밋을 직접(alternates 없이) 가진 git dir 를 RD_GL_SRC 에 둔다(spec D1-4 (1)).
#   1) submodule 저장소 2) _rd_submodule_object_pool 의 objects 각각의 부모 git dir. rc 0 찾음 / 1 없음(RD_GL_SRC 빈 값).
#   판정용 rd_gl_select 의 객체 풀(공통 git dir + alternates 주입)은 fetch 출처가 될 수 없어 따로 둔다.
#   호출 위치: archive.sh 의 archive_gitlink_auto_resolve(객체 확보).
rd_gl_src() {
  local d="${1:-}" p="${2:-}" oid="${3:-}" dir gd cdir pool o rest
  RD_GL_SRC=""
  [[ -n "$d" && -n "$p" && -n "$oid" ]] || return 1
  dir="$(_rd_gl_sub_dir "$d" "$p")" || return 1
  if _rd_gl_is_sub "$dir" && GIT_ALTERNATE_OBJECT_DIRECTORIES= git -C "$dir" cat-file -e "${oid}^{commit}" 2>/dev/null; then
    gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
    if [[ -n "$gd" ]]; then RD_GL_SRC="$gd"; return 0; fi
  fi
  declare -F _rd_git_common_dir >/dev/null 2>&1 && declare -F _rd_submodule_object_pool >/dev/null 2>&1 || return 1
  cdir="$(_rd_git_common_dir "$d" 2>/dev/null)" || return 1
  pool="$(_rd_submodule_object_pool "$cdir")" || return 1
  rest="$pool"
  while [[ -n "$rest" ]]; do
    o="${rest%%:*}"
    if [[ "$rest" == *:* ]]; then rest="${rest#*:}"; else rest=""; fi
    [[ -n "$o" ]] || continue
    if GIT_ALTERNATE_OBJECT_DIRECTORIES= git --git-dir="${o%/objects}" cat-file -e "${oid}^{commit}" 2>/dev/null; then
      RD_GL_SRC="${o%/objects}"; return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------- gitlink 판정 (spec D1-1·「병합 기준」)

# rd_merge_single_base <dir> <a> <b> — merge-base --all 이 정확히 하나면 그 OID 를 stdout 에 내고 rc 0, 아니면 rc 1.
rd_merge_single_base() {
  local bases n
  [[ -n "${1:-}" && -n "${2:-}" && -n "${3:-}" ]] || return 1
  bases="$(git -C "$1" merge-base --all "$2" "$3" 2>/dev/null)" || return 1
  n="$(printf '%s' "$bases" | grep -c .)" || n=0
  [[ "$n" -eq 1 ]] || return 1
  printf '%s\n' "$bases"
}

# rd_merge_gitlink_pick <repo-dir> <path> <a> <b> [<base>] — gitlink 두 쪽 중 자손을 고른다. 결과는 RD_GL_PICKED(stdout 없음).
#   <base> 는 병합 기준 커밋의 그 경로 gitlink 이며 모드 160000 일 때만 넘긴다(롤백 판정 전용).
#   rc 0 한쪽이 다른 쪽의 조상(같은 커밋 포함) — RD_GL_PICKED = 자손
#   rc 1 갈라짐, 또는 롤백 충돌(a 나 b 가 <base> 의 엄격한 조상)
#   rc 3 판정 불가(인자 오류, 객체 없음, git 오류)
#   객체가 없으면 rd_gl_fetch_once 로 경로마다 한 번 받는다. 명령 치환 안에서 부르면 fetch 기록이 호출자에게 남지
#   않으므로 직접 부르고 RD_GL_PICKED 를 읽는다.
rd_merge_gitlink_pick() {
  local d="${1:-}" p="${2:-}" a="${3:-}" b="${4:-}" base="${5:-}" dir o x miss="" rc=0
  local -a objs
  RD_GL_PICKED=""
  [[ -n "$d" && -n "$p" && -n "$a" && -n "$b" ]] || return 3
  if [[ "$a" == "$b" ]]; then RD_GL_PICKED="$a"; return 0; fi
  objs=("$a" "$b"); [[ -z "$base" ]] || objs+=("$base")
  if ! rd_gl_select "$d" "$p" "${objs[@]}"; then
    dir="$(_rd_gl_sub_dir "$d" "$p")" || return 3
    for o in "${objs[@]}"; do
      if ! git -C "$dir" cat-file -e "${o}^{commit}" 2>/dev/null; then miss="$o"; break; fi
    done
    rd_gl_fetch_once "$d" "$p" "${miss:-$a}" "rd_merge_conflicts:" || return 3
    rd_gl_select "$d" "$p" "${objs[@]}" || return 3
  fi
  if [[ -n "$base" ]]; then
    for x in "$a" "$b"; do
      [[ "$x" != "$base" ]] || continue
      rc=0; rd_gl_git merge-base --is-ancestor "$x" "$base" 2>/dev/null || rc=$?
      case "$rc" in 0) return 1 ;; 1) ;; *) return 3 ;; esac
    done
  fi
  rc=0; rd_gl_git merge-base --is-ancestor "$a" "$b" 2>/dev/null || rc=$?
  case "$rc" in 0) RD_GL_PICKED="$b"; return 0 ;; 1) ;; *) return 3 ;; esac
  rc=0; rd_gl_git merge-base --is-ancestor "$b" "$a" 2>/dev/null || rc=$?
  case "$rc" in 0) RD_GL_PICKED="$a"; return 0 ;; 1) return 1 ;; *) return 3 ;; esac
}

# _rd_merge_gl_entry <dir> <commit> <path> — commit 의 path 가 gitlink 면 OID 를 낸다(rc 0). 아니면 rc 1.
_rd_merge_gl_entry() {
  local rec meta
  rec="$(git -C "$1" ls-tree -z "$2" -- ":(literal)$3" 2>/dev/null | tr '\0' '\n' | sed -n 1p)" || return 1
  meta="${rec%%$'\t'*}"
  [[ "$meta" == "160000 commit "* && "${rec#*$'\t'}" == "$3" ]] || return 1
  printf '%s\n' "${meta##* }"
}

# rd_merge_conflicts <repo-dir> <ours> <theirs> [--gitlink-auto]
#   --gitlink-auto (spec D1-3): 충돌 경로가 양쪽 모두 gitlink 이고 rd_merge_gitlink_pick 이 rc 0 이면 충돌 목록에서 뺀다.
#     병합 기준이 하나가 아니면(rd_merge_single_base rc 1) 이번 호출은 gitlink 자동 해소를 하지 않는다. 그 밖의 넷째 인자는 rc 3.
#     켜는 호출부: archive.sh 의 archive_conflict_precheck, publish_queue.sh 의 pq_merge_check, fr_do/grant_check.sh
#       — 셋 모두 실제 병합을 archive.sh 가 하고 archive 가 그 경로를 자손 커밋으로 푼다.
#     켜지 않는 호출부: _direct_pr_common.sh(직접 설치 PR) — 병합을 GitHub 이 하고 GitHub 은 gitlink 충돌을 풀지 않는다.
#   stdout: 자동 해소 대상이 아닌 충돌 경로(정렬, 중복 없음, 한 줄에 하나, 인용 없음)
#   rc 0 충돌 없음(또는 자동 해소 대상만 충돌) / 1 그 밖의 충돌 / 3 판정 불가(인자 빔 포함)
#   merge-tree 는 -z 로 받아 경로 인용(core.quotePath)을 피하고, NUL 경계를 지킨 채 경로 하나씩 읽는다.
#   줄바꿈을 품은 경로는 자동 해소 대상과 비교하지 않고 충돌로 잡는다. 표시는 줄바꿈을 `\n` 두 글자로 바꾼다
#   (줄바꿈으로 바꾸면 조각이 자동 해소 대상과 맞아 실제 충돌을 빼 버린다 — final diff review F1).
#   잘못된 ref 에도 merge-tree 가 rc 1 을 내므로, 충돌 판정은 첫 항목(트리 OID)이 있을 때만 인정한다.
#   인덱스(FUTURE_REQUESTS.md)가 충돌 목록에 있으면 경로 루프 뒤에 병합기를 미리 돌린다. 병합 불가면 인덱스를
#   충돌 경로로 내고(rc 1, stderr 사유 한 줄), 병합기가 없으면 판정 불가(rc 3)다 (spec 2026-11-17-1710 D3).
rd_merge_conflicts() {
  local dir="${1:-}" ours="${2:-}" theirs="${3:-}" tmp rc=0 p a auto keep="" first=1 tree="" idx=0 src=0
  local gl=0 glbase="" go gt gb
  [[ -n "$dir" && -n "$ours" && -n "$theirs" ]] || return 3
  case "${4:-}" in
    "") ;;
    --gitlink-auto) gl=1 ;;
    *) return 3 ;;
  esac
  tmp="$(mktemp)" || { echo "rd_merge_conflicts: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 3; }
  [[ -n "$tmp" && -f "$tmp" ]] || { echo "rd_merge_conflicts: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 3; }
  git -C "$dir" merge-tree --write-tree --name-only --no-messages -z "$ours" "$theirs" >"$tmp" 2>/dev/null || rc=$?
  case "$rc" in
    0) rm -f "$tmp"; return 0 ;;
    1) ;;
    *) rm -f "$tmp"; return 3 ;;
  esac
  if [[ "$gl" -eq 1 ]]; then
    glbase="$(rd_merge_single_base "$dir" "$ours" "$theirs")" || gl=0
  fi
  while IFS= read -r -d '' p; do
    if [[ "$first" -eq 1 ]]; then first=0; tree="$p"; continue; fi
    [[ -n "$p" ]] || continue
    if [[ "$p" == *$'\n'* ]]; then keep="${keep}${p//$'\n'/\\n}"$'\n'; continue; fi
    [[ "$p" == "$_RD_MERGE_FR_INDEX" ]] && idx=1
    auto=0
    while IFS= read -r a; do [[ "$p" == "$a" ]] && auto=1; done <<EOF2
$RD_MERGE_AUTO_RESOLVE_PATHS
EOF2
    [[ "$auto" -eq 1 ]] && continue
    if [[ "$gl" -eq 1 ]] && go="$(_rd_merge_gl_entry "$dir" "$ours" "$p")" && gt="$(_rd_merge_gl_entry "$dir" "$theirs" "$p")"; then
      gb="$(_rd_merge_gl_entry "$dir" "$glbase" "$p")" || gb=""
      # 직접 부른다(명령 치환 아님): fetch 기록 RD_GL_FETCHED 를 이 셸에 남긴다.
      if [[ -n "$gb" ]]; then
        rd_merge_gitlink_pick "$dir" "$p" "$go" "$gt" "$gb" </dev/null && continue
      else
        rd_merge_gitlink_pick "$dir" "$p" "$go" "$gt" </dev/null && continue
      fi
    fi
    keep="${keep}${p}"$'\n'
  done <"$tmp"
  rm -f "$tmp"
  [[ -n "$tree" ]] || return 3
  if [[ "$idx" -eq 1 ]]; then
    _rd_merge_index_sim "$dir" "$ours" "$theirs" || src=$?
    case "$src" in
      0) ;;
      1) keep="${keep}${_RD_MERGE_FR_INDEX}"$'\n' ;;
      *) return 3 ;;
    esac
  fi
  [[ -z "$keep" ]] && return 0
  # LC_ALL=C: UTF-8 이 아닌 바이트 경로에서 sort 가 「Illegal byte sequence」 로 실패해 목록이 비지 않게 한다.
  printf '%s' "$keep" | LC_ALL=C sort -u
  return 1
}

# rd_merge_conflict_guide <prefix> <fr-branch> <default-branch> <fr-worktree>
#   stdout: 해소 절차 안내 6줄(첫 줄은 prefix 바로 뒤, 단계 줄은 prefix 뒤 2칸 들여쓰기). 출력 위치는 호출부가 정한다.
#   <fr-branch> 는 호출부 문맥용이며 문구에는 쓰지 않는다(안내는 작업 worktree 안에서 실행하는 절차다).
rd_merge_conflict_guide() {
  local pre="${1:-}" def="${3:-}" wt="${4:-}"
  [[ -n "$def" ]] || def="<기본 브랜치>"
  [[ -n "$wt" ]] || wt="<작업 worktree>"
  printf '%s리뷰한 코드와 %s 의 변경을 합친 결과는 리뷰를 거쳐야 발행할 수 있습니다. 작업 worktree(%s)에서:\n' "$pre" "$def" "$wt"
  printf '%s  1. bash rd-workflow/scripts/rd task set-status "구현 중"\n' "$pre"
  printf '%s  2. git merge %s   — 충돌을 풀고 커밋합니다\n' "$pre" "$def"
  printf '%s  3. bash rd-workflow/scripts/rd task set-status "검증 중" 후 검증, bash rd-workflow/scripts/verify_record.sh -- <검증 명령>\n' "$pre"
  printf '%s  4. bash rd-workflow/scripts/rd task set-status "diff review 대기" 후 새 final diff review 세션을 종결합니다\n' "$pre"
  printf '%s  5. bash rd-workflow/scripts/rd review seal <새 세션> → set-status "아카이브 보류" → 기록 커밋 → 다시 발행\n' "$pre"
}

# rd_merge_resolve_record <경로> <base 파일|""> <기본 쪽 파일|""> <작업 쪽 파일|""> <결과 파일>
#   병합 자동 해소 대상 다섯 경로(RD_MERGE_AUTO_RESOLVE_PATHS)의 blob 단위 해소 규칙. 빈 문자열 인자는 「그 stage 없음」.
#   rc 0 해소(결과 파일에 내용) / 1 자동 해소하지 않음(사유 한 줄을 RD_MERGE_RESOLVE_WHY 에 담고, RD_MERGE_RESOLVE_QUIET=1 이
#   아니면 stderr 에도 낸다). 다섯 경로 밖이면 rc 1. 호출부가 stage 를 임시 파일로 꺼내 넘긴다
#   (archive.sh: 기본 쪽 = stage 2, 작업 쪽 = stage 3).
#   stage_metrics.tsv 를 공통 조상 없이(add/add) 해소했으면 RD_MERGE_RESOLVE_SM_ADDADD=1, 그 밖은 0 이다(해소 안내 문구용).
rd_merge_resolve_record() {
  local path="$1" base="${2:-}" ours="${3:-}" theirs="${4:-}" out="$5"
  local ct sm idx ve ts why="" bad stg="" aa=0
  RD_MERGE_RESOLVE_SM_ADDADD=0
  ct="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 1p)"
  sm="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 2p)"
  idx="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 3p)"
  ve="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 4p)"
  ts="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 5p)"
  RD_MERGE_RESOLVE_WHY=""
  if [[ "$path" == "$ct" ]]; then
    # 기본 쪽 버전이 있어야 하고 첫 줄이 `# Current Task` 여야 한다 (delete/modify 충돌은 기본 쪽이 없다).
    if [[ -z "$ours" ]]; then why="CURRENT_TASK.md main 쪽 버전이 없어 자동 해소하지 않습니다"
    elif [[ "$(head -n 1 "$ours")" != "# Current Task" ]]; then why="CURRENT_TASK.md 형식 오류"
    else cp "$ours" "$out" || why="stage 추출 실패: $path"; fi
  elif [[ "$path" == "$ve" ]]; then
    # 작업 쪽 버전이 있어야 한다. 기본 쪽이 없는 것은 막지 않는다 — 작업 쪽 내용만 쓰기 때문이다.
    if [[ -z "$theirs" ]]; then why="verify-evidence 발행 줄기 쪽 버전이 없어 자동 해소하지 않습니다"
    else cp "$theirs" "$out" || why="stage 추출 실패: $path"; fi
  elif [[ "$path" == "$ts" ]]; then
    # 작업 쪽 버전이 있어야 하고 `fr-branch=` 줄이 있어야 한다. 형식이 깨진 내용을 받아들이지 않는다.
    if [[ -z "$theirs" ]]; then why="task-state 발행 줄기 쪽 버전이 없어 자동 해소하지 않습니다"
    elif ! grep -q '^fr-branch=' "$theirs"; then why="task-state 형식 오류"
    else cp "$theirs" "$out" || why="stage 추출 실패: $path"; fi
  elif [[ "$path" == "$sm" ]]; then
    # 세 판이 모두 있으면 줄 합집합(merge-file --union)이다. 공통 조상에 파일이 없고 양쪽에만 있으면(add/add — 기본 브랜치에
    #   파일이 없을 때 띄운 줄기끼리) 두 판의 첫 줄이 정확한 헤더일 때만 헤더 한 번 + 기본 쪽 행 + 작업 쪽의 새 행으로 합친다
    #   (FR stage-metrics-add-add-auto-resolve). 같은 행은 어느 쪽에서 왔든 처음 나온 자리에 한 번만 남긴다(행 합집합 — 같은
    #   전이를 같은 초에 두 번 기록하는 일은 없으므로 같은 행은 복사된 중복이다).
    #   이 파일은 전이 행을 덧붙이기만 하는 기록이라 행 합집합이 곧 병합 결과다.
    #   한쪽만 있는 경우(delete/modify)는 멈춘다.
    local hdr=$'# short_title\tfrom_status\tto_status\tepoch'
    if [[ -z "$base" && -n "$ours" && -n "$theirs" ]]; then
      if [[ "$(head -n 1 "$ours")" != "$hdr" || "$(head -n 1 "$theirs")" != "$hdr" ]]; then
        why="stage_metrics.tsv 공통 조상에 파일이 없고 두 판의 헤더가 기준 헤더와 달라 자동 해소하지 않습니다"
      elif ! awk 'FNR == 1 { if (NR == 1) print; next } !($0 in seen) { seen[$0] = 1; print }' "$ours" "$theirs" > "$out"; then
        why="stage_metrics.tsv 행 합집합 병합 실패"
      else
        aa=1
      fi
    elif [[ -z "$base" || -z "$ours" || -z "$theirs" ]]; then
      [[ -n "$base" ]] && stg="${stg}1 "; [[ -n "$ours" ]] && stg="${stg}2 "; [[ -n "$theirs" ]] && stg="${stg}3 "
      why="stage_metrics.tsv 한쪽 버전이 없어(stage: ${stg:-없음}) 자동 해소하지 않습니다"
    elif ! git merge-file -p --union "$ours" "$base" "$theirs" > "$out"; then why="stage_metrics.tsv 줄 합집합 병합 실패"
    fi
    if [[ -z "$why" ]]; then
      # 형식: 첫 줄 정확한 헤더 1개, 이후 `#` 줄 없음, 모든 행 탭 4필드(빈 줄은 0필드라 함께 거부).
      bad="$(awk -F'\t' 'NR==1 { if ($0 != "# short_title\tfrom_status\tto_status\tepoch") { print NR ": " substr($0, 1, 40); exit } next }
        /^#/ || NF != 4 { print NR ": " substr($0, 1, 40); exit }
        END { if (NR == 0) print "0: (빈 파일)" }' "$out")"
      [[ -z "$bad" ]] || why="stage_metrics.tsv 형식 오류: $bad"
    fi
    [[ -n "$why" ]] || RD_MERGE_RESOLVE_SM_ADDADD="$aa"
  elif [[ "$path" == "$idx" ]]; then
    local merger="${_RD_MERGE_PRECHECK_DIR:+$_RD_MERGE_PRECHECK_DIR/merge_fr_index.sh}"
    if [[ -z "$base" || -z "$ours" || -z "$theirs" || -z "$merger" || ! -f "$merger" ]] \
       || ! bash "$merger" "$base" "$ours" "$theirs" > "$out"; then
      why="FUTURE_REQUESTS.md 행 집합 병합도 실패했습니다"
    fi
  else
    why="자동 해소 대상이 아닌 경로입니다: $path"
  fi
  if [[ -n "$why" ]]; then
    RD_MERGE_RESOLVE_WHY="$why"
    [[ "${RD_MERGE_RESOLVE_QUIET:-0}" == "1" ]] || printf '%s\n' "$why" >&2
    return 1
  fi
  return 0
}
