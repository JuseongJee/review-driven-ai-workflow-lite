#!/usr/bin/env bash
# _fr_register_common.sh — /fr add 등록 결과(인덱스 행·items 상세·fr 캡처)를 기본 브랜치에 커밋하는 helper. source 전용 (rd 가 사용).
#   왜: 등록 결과가 fr 브랜치에만 실리면 브랜치 방치와 함께 사라진다 (FR fr-record-loss-on-unmerged-branch).
#   계약 (spec §3.1): 내용 단위 합성 — 인덱스는 기본 브랜치 최신 내용 + 이번 slug 행 1개, 상세·캡처는 이번 파일 1개씩 신규.
#   plumbing 커밋 + update-ref CAS. 임시 worktree·브랜치를 만들지 않는다. 실패는 전부 fail-open(skipped, exit 3).
#   불변식: helper 는 자기가 만들지 않은 파일을 덮어쓰거나 지우지 않는다 — 새 파일은 같은 디렉터리의 임시 파일에 쓰고 hard link(EEXIST 면 실패,
#   원자적 no-clobber) 로 놓으며, rollback 은 대상이 그 임시 파일과 같은 inode(-ef) 일 때만 지운다(소유권 판별이 journal 등록 시점과 무관).
#   상태 머신 _frr_state: none → prepared(다른 worktree 준비 완료) → committing(update-ref 진행) → committed. EXIT/INT/TERM 은 상태로 판단해
#   prepared 면 rollback, committing 이면 ref 를 재확인해 이동했으면 committed 로 취급한다. committed 는 자기 trap 을 복원할 때까지 유지한다.
#   기존 EXIT/INT/TERM trap 은 보존·복원한다(EXIT 는 체인, INT/TERM 은 정리 뒤 재송신).
_FRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_FRC_DIR}/lifecycle/_lifecycle_common.sh"

FR_IDX_PATH="rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
FR_ITEMS_DIR="rd-workflow-workspace/backlog/items"
FR_CAP_DIR="rd-workflow-workspace/raw-captures"

# --- 프로세스 상태 (trap 이 읽음) ---
_frr_tmp=()                 # 임시 파일 (항상 삭제)
_frr_state="none"           # none | prepared(다른 worktree 준비 완료, CAS 전) | committed(ref 갱신 완료)
_frr_wt=""; _frr_bak="-"; _frr_orig_ls=""; _frr_paths=(); _frr_created=(); _frr_slug=""; _frr_branch="-"; _frr_idx_old=""; _frr_idx_new=""; _frr_idx_want=""; _frr_parked=()
_frr_ref=""; _frr_new=""; _frr_prev_exit=""; _frr_prev_int=""; _frr_prev_term=""

_frr_cleanup() { local f; for f in ${_frr_tmp[@]+"${_frr_tmp[@]}"}; do rm -f "$f"; done; _frr_tmp=(); }
# _frr_mktemp_into <varname> — 임시 파일을 만들고 경로를 변수에 대입한다. command substitution 으로 부르면
# 서브셸에서 배열이 늘어나 부모의 _frr_tmp 에 남지 않으므로(정리 누수), 반드시 이 형태로만 부른다.
_frr_mktemp_into() { local f; f="$(mktemp)" || return 1; _frr_tmp+=("$f"); printf -v "$1" '%s' "$f"; }
# _frr_mktemp_in_dir <varname> <dir> — 대상 디렉터리 안의 임시 파일(hard link 원본용). 같은 파일시스템이어야 ln 이 된다.
_frr_mktemp_in_dir() { local f; f="$(mktemp "$2/.frr-XXXXXX")" || return 1; chmod 644 "$f" 2>/dev/null; _frr_tmp+=("$f"); printf -v "$1" '%s' "$f"; }  # mktemp 의 0600 을 일반 파일 권한으로 (hard link 로 놓이는 상세·캡처가 소유자 전용이 되지 않게)

_frr_emit() { # <result> <branch> <commit> <reason> <human> — 보관한 파일이 있으면 결과와 무관하게 사람용 줄에 경로를 항상 병기한다(늦은 쓰기가 그 뒤에 도착해도 사용자가 찾을 수 있게).
  local note=""
  [[ ${#_frr_parked[@]} -eq 0 ]] || note=" | 보관: ${_frr_parked[*]} (helper 가 지우지 않습니다 — 확인 뒤 지워도 됩니다)"
  printf 'result=%s branch=%s commit=%s reason=%s\n' "$1" "$2" "$3" "$4"
  printf '%s\n' "$5$note"
}
_frr_skip() { # <slug> <branch> <reason> <사유문> — exit 3 계약 (호출측이 return 3)
  # emit 동안 INT/TERM 을 잠시 무시해 result= 줄이 정확히 하나만 나오게 한다 (committed 경로의 _frr_finish_committed 와 같은 계약). 직전 정의는 그대로 되돌린다.
  local pi pt; pi="$(trap -p INT)"; pt="$(trap -p TERM)"
  trap '' INT TERM
  _frr_emit skipped "$2" - "$3" "경고: 기본 브랜치 등록 커밋을 생략했습니다 — $4. 등록 파일은 현재 워킹트리에 있습니다. 복구: bash rd-workflow/scripts/rd task fr-register --slug $1"
  if [[ -n "$pi" ]]; then eval "$pi"; else trap - INT; fi
  if [[ -n "$pt" ]]; then eval "$pt"; else trap - TERM; fi
  _frr_cleanup
  return 3
}

# 인덱스 파일에서 제목 == slug 인 행만 출력 (파일 인자가 - 면 stdin)
_frr_rows_for() { awk -F'|' -v s="$2" '/^\|/ { t = $3; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == s) print }' "$1"; }
# base 인덱스(파일) 의 마지막 표 행 뒤에 행 1개 삽입 → stdout (출력은 줄 끝 개행으로 정규화된다)
_frr_insert_row() { # <base-file> <row>
  awk -v row="$2" '{ l[NR] = $0; if ($0 ~ /^\|/) last = NR } END { for (i = 1; i <= NR; i++) { print l[i]; if (i == last) print row } }' "$1"
}

# 무손실 교체 — 대상을 같은 디렉터리의 임시 이름으로 옮긴 뒤(원자적 rename) 새 내용을 hard link 로 놓고, 옮긴 원본이 기대한 옛 내용과 같을 때만 성공한다.
# 검사~교체 사이에 사용자가 편집했으면 그 바이트를 그대로 되돌리고 실패한다 — helper 가 만들지 않은 내용은 어느 순서에서도 덮어쓰지 않는다.
# 옮긴 원본(.frr-old-*) 은 사용자 바이트가 들어갈 수 있어 _frr_tmp 자동 정리 대상이 아니다: 성공 확정(CAS 뒤) 또는 정상 rollback 때만 지운다.
# 보관 — 사용자 경로에 한 번이라도 놓여 있던 inode 는 지우지 않는다. 검사 뒤에도 이미 열린 FD 로 늦게 쓰일 수 있으므로, 이름만 그 worktree 의
# git-dir 아래 `fr-register/` 로 옮겨(hard link + unlink — inode 그대로, 다른 파일시스템이면 제자리에 둠) 늦은 쓰기가 살아남는 곳을 남긴다.
# 옮긴 경로를 stdout 으로 낸다. helper 는 이 디렉터리를 비우지 않는다(사용자가 확인 뒤 지운다).
_frr_park() { # <file> <label>
  local gd dst
  gd="$(git -C "$(dirname "$1")" rev-parse --git-dir 2>/dev/null)" || { echo "경고: 보관 위치를 찾지 못해 $1 에 남겼습니다." >&2; _frr_parked+=("$1"); printf '%s\n' "$1"; return 1; }
  [[ "$gd" == /* ]] || gd="$(cd "$(dirname "$1")" && cd "$gd" && pwd -P)"
  mkdir -p "$gd/fr-register" 2>/dev/null || { echo "경고: $gd/fr-register 를 만들 수 없어 $1 에 남겼습니다." >&2; _frr_parked+=("$1"); printf '%s\n' "$1"; return 1; }
  dst="$gd/fr-register/$(date +%Y%m%d-%H%M%S)-$$-$2"
  if ln "$1" "$dst" 2>/dev/null; then rm -f "$1"; _frr_parked+=("$dst"); printf '%s\n' "$dst"; return 0; fi
  echo "경고: $1 을 $gd/fr-register/ 로 옮길 수 없어 제자리에 남겼습니다." >&2; _frr_parked+=("$1"); printf '%s\n' "$1"; return 1
}

# no-clobber 복원 — <dst> 에 있는 것을 먼저 옆으로 치우고(rename, 무손실), 치운 것이 helper 가 놓은 내용(같은 inode + 합성본과 같은 바이트) 일 때만
# <old> 를 hard link(no-clobber) 로 되돌린다. 아니면(사용자가 helper 링크 뒤에 또 썼다) 사용자 내용을 no-clobber 로 제자리에 두고 <old> 도 남겨 두 버전을 모두 보존한다.
# 어느 단계도 기존 파일을 덮어쓰는 rename/cp 를 쓰지 않고, 사용자 경로에 있었던 inode 는 rm 하지 않는다(_frr_park) — 놓기는 전부 ln(EEXIST 실패), 치우기는 임시 이름으로의 rename.
_frr_unclobber_restore() { # <old> <dst> <ours-tmp> <want-content>
  local dir cur
  dir="$(dirname "$2")"
  cur="$(mktemp "$dir/.frr-cur-XXXXXX")" || { echo "경고: $2 복원용 임시 파일을 만들 수 없습니다 — 원본 바이트는 $1 에 있습니다." >&2; return 1; }
  if [[ -e "$2" || -L "$2" ]]; then mv -f "$2" "$cur" 2>/dev/null || { rm -f "$cur"; echo "경고: $2 를 치울 수 없습니다 — 원본 바이트는 $1 에 있습니다." >&2; return 1; }
  else rm -f "$cur"; cur=""; fi
  if [[ -n "$cur" && "$cur" -ef "$3" ]] && cmp -s "$cur" "$4"; then
    _frr_park "$cur" idx-helper >/dev/null || true   # helper 링크지만 사용자 경로에 있었으므로 지우지 않고 보관
    if ln "$1" "$2" 2>/dev/null; then rm -f "$1"; return 0; fi
    echo "경고: $2 가 복원 도중 다시 생겼습니다 — 원본 바이트는 $1 에 있습니다." >&2; return 1
  fi
  if [[ -n "$cur" ]]; then
    if ln "$cur" "$2" 2>/dev/null; then rm -f "$cur"; else echo "경고: $2 를 되돌릴 수 없어 현재 내용은 $cur 에 있습니다." >&2; fi
  fi
  echo "경고: $2 가 helper 가 놓은 뒤 바뀌어 원본을 덮지 않았습니다 — 원본 바이트는 $1 에, 현재 내용은 $2 에 있습니다." >&2
  return 1
}
_frr_swap_file() { # <new-content> <dst> <expected-old>
  local dir tmp old
  dir="$(dirname "$2")"
  _frr_mktemp_in_dir tmp "$dir" || return 1
  cat "$1" > "$tmp" 2>/dev/null || return 1
  old="$(mktemp "$dir/.frr-old-XXXXXX")" || return 1
  mv -f "$2" "$old" 2>/dev/null || { rm -f "$old"; return 1; }
  _frr_idx_old="$old"; _frr_idx_new="$tmp"; _frr_idx_want="$1"
  if ! ln "$tmp" "$2" 2>/dev/null || [[ ! "$2" -ef "$tmp" ]]; then
    # 옮긴 직후 누가 대상 경로를 다시 만들었다 — 그 파일을 덮지 않는다(no-clobber 로만 되돌린다).
    if ln "$old" "$2" 2>/dev/null; then rm -f "$old"; else echo "경고: $2 가 교체 도중 다시 생겼습니다 — 원본 바이트는 $old 에 있습니다." >&2; fi
    _frr_idx_old=""; _frr_idx_new=""; _frr_idx_want=""; return 1
  fi
  # 검사~치우기 사이에 편집이 있었다(옮긴 원본 ≠ 보관본) → 되돌린다. 그 사이 누가 또 썼으면 no-clobber 복원이 두 버전을 모두 남긴다.
  if ! cmp -s "$old" "$3"; then _frr_unclobber_restore "$old" "$2" "$tmp" "$1"; _frr_idx_old=""; _frr_idx_new=""; _frr_idx_want=""; return 1; fi
  return 0
}

# 다른 worktree 준비분 rollback (역순): index 항목 복원 → helper 가 만든 파일만 삭제 → 인덱스 원본 되돌리기(helper 가 놓은 내용 그대로일 때만). 일부 실패는 경고.
_frr_wt_rollback() {
  local wt="$_frr_wt" p entry mode blob bad=0
  [[ -n "$wt" ]] || return 0
  for p in ${_frr_paths[@]+"${_frr_paths[@]}"}; do
    entry="$(printf '%s\n' "$_frr_orig_ls" | awk -F'\t' -v p="$p" '$2 == p { print $1 }')"
    if [[ -n "$entry" ]]; then
      mode="${entry%% *}"; blob="${entry#* }"; blob="${blob%% *}"
      git -C "$wt" update-index --add --cacheinfo "$mode,$blob,$p" >/dev/null 2>&1 || bad=1
    else
      git -C "$wt" update-index --force-remove -- "$p" >/dev/null 2>&1 || true
    fi
  done
  local pair dst src
  for pair in ${_frr_created[@]+"${_frr_created[@]}"}; do   # "dst<TAB>tmp" — dst 가 tmp 와 같은 inode 일 때만 helper 소유
    dst="${pair%%$'\t'*}"; src="${pair#*$'\t'}"
    if [[ -f "$src" && "$dst" -ef "$src" ]]; then rm -f "$dst" || bad=1; fi
  done
  if [[ -n "$_frr_idx_old" ]]; then
    _frr_unclobber_restore "$_frr_idx_old" "$wt/$FR_IDX_PATH" "$_frr_idx_new" "$_frr_idx_want" || bad=1
    _frr_idx_old=""; _frr_idx_new=""; _frr_idx_want=""
  fi
  _frr_created=()
  [[ $bad -eq 0 ]] || echo "경고: 기본 브랜치 worktree($wt) 준비분 rollback 이 일부 실패했습니다 — git -C \"$wt\" status 로 등록 경로 상태를 확인하세요." >&2
}

# 상태 판정 — committing 이면 ref 를 재확인해 실제로 이동했는지 본다(update-ref 성공과 상태 갱신 사이의 창을 닫는다).
_frr_effective_state() {
  if [[ "$_frr_state" == "committing" ]]; then
    if [[ -n "$_frr_ref" && "$(git rev-parse -q --verify "$_frr_ref" 2>/dev/null)" == "$_frr_new" ]]; then echo committed; else echo prepared; fi
  else echo "$_frr_state"; fi
}
# 비정상 종료·신호 공통 처리. <sig> 는 SIGINT|SIGTERM|"EXIT rc=N"(비정상 종료).
_frr_abort() {
  local sig="$1" st rec
  st="$(_frr_effective_state)"
  if [[ "$st" == "committed" ]]; then
    if [[ -n "$_frr_wt" ]]; then rec="git -C \"$_frr_wt\" status -- ${_frr_paths[*]} 로 확인하고, 보존할 편집이 없으면 git -C \"$_frr_wt\" checkout -- ${_frr_paths[*]}"; else rec="git reset -q -- ${_frr_paths[*]}"; fi
    [[ -z "$_frr_idx_old" ]] || { _frr_park "$_frr_idx_old" "$_frr_slug-index.md" >/dev/null || true; _frr_idx_old=""; }
    _frr_emit committed "$_frr_branch" "${_frr_new:0:7}" wt-sync-incomplete "FR 등록 커밋: $_frr_branch ${_frr_new:0:7} — 단, 사후 동기화 중 중단됐습니다($sig). 복구: $rec"
  else
    [[ "$st" == "prepared" ]] && _frr_wt_rollback
    _frr_emit skipped "$_frr_branch" - interrupted "경고: 기본 브랜치 등록 커밋이 중단됐습니다($sig) — 준비분은 되돌렸습니다. 등록 파일은 현재 워킹트리에 있습니다. 복구: bash rd-workflow/scripts/rd task fr-register --slug $_frr_slug"
  fi
  _frr_state="none"
  _frr_cleanup
}
# trap -p 원문(`trap -- 'BODY' SIG`) 에서 BODY 를 인용 그대로 꺼내 실행한다. eval "set -- $line" 이 셸 인용을 정확히 풀어 준다.
_frr_run_trap_body() { eval "set -- $1"; eval "$3"; }
# 신호: 정리 뒤 기존 핸들러를 복원하고, 기존 핸들러 본문이 있으면 **직접 한 번 실행**한다(같은 신호를 자신에게 다시 보내면 bash 가 trap 반환
# 뒤로 배달을 미루어 exit 이 먼저 실행되므로 재송신은 쓰지 않는다). 본문이 exit 하면 그 코드가 보존되고, 돌아오면 130/143 으로 끝난다.
_frr_on_signal() {
  local sig="$1" code=130 prev="$_frr_prev_int"
  [[ "$sig" == "TERM" ]] && { code=143; prev="$_frr_prev_term"; }
  _frr_abort "SIG$sig"
  _frr_restore_traps
  [[ -z "$prev" ]] || _frr_run_trap_body "$prev"
  exit "$code"
}
# EXIT: 정상 return 은 state=none 이므로 비정상 종료(set -e 등) 만 여기서 정리한다. 기존 EXIT 본문은 설치 시 체인으로 붙어 이어서 실행된다. exit 를 부르지 않아 원래 종료 코드가 보존된다.
_frr_on_exit() { local rc=$?; [[ "$_frr_state" == "none" ]] || _frr_abort "EXIT rc=$rc"; _frr_cleanup; return "$rc"; }
_frr_install_traps() {
  # source 한 셸의 기존 EXIT/INT/TERM 정의를 trap -p 원문으로 보존한다(인용 그대로). EXIT 는 기존 본문 앞에 우리 핸들러를 체인한다.
  _frr_prev_exit="$(trap -p EXIT)"; _frr_prev_int="$(trap -p INT)"; _frr_prev_term="$(trap -p TERM)"
  local q="'"
  # 체인은 `_frr_on_exit && :; <기존 본문>` — _frr_on_exit 가 원래 종료 코드를 return 하므로 기존 본문의 $? 가 원값으로 유지되고(set -e 에서도 && 리스트라 중단되지 않음), rc 0 이면 : 이 0 을 이어 준다.
  # (치환 문자열에 & 를 두지 않는다 — bash 5.2 의 patsub_replacement 와 3.2 의 리터럴 처리가 달라 접두 제거 + 연결로 만든다)
  if [[ -n "$_frr_prev_exit" ]]; then eval "trap -- ${q}_frr_on_exit && :; ${_frr_prev_exit#trap -- $q}"; else trap '_frr_on_exit || :' EXIT; fi
  trap '_frr_on_signal INT' INT
  trap '_frr_on_signal TERM' TERM
}
_frr_restore_traps() {
  if [[ -n "$_frr_prev_exit" ]]; then eval "$_frr_prev_exit"; else trap - EXIT; fi
  if [[ -n "$_frr_prev_int" ]]; then eval "$_frr_prev_int"; else trap - INT; fi
  if [[ -n "$_frr_prev_term" ]]; then eval "$_frr_prev_term"; else trap - TERM; fi
}

# committed 계열 정상 종료 — 어느 시점에 신호가 와도 기계 판독 줄(result=) 이 정확히 하나만 나오게 순서를 고정한다:
#   ① cleanup (핸들러 활성, state=committed → 이때 신호면 핸들러가 committed+SHA+wt-sync-incomplete 를 유일한 result 줄로 내고 종료)
#   ② INT/TERM 을 잠시 무시(trap '')한 채 emit (emit 도중 신호는 버려져 줄이 잘리거나 두 번 나오지 않음)
#   ③ 기존 trap 복원(무시 상태 해제) → state=none. 이후 신호는 기존/기본 핸들러로 간다.
_frr_finish_committed() { # <commit> <reason> <human>
  _frr_cleanup
  trap '' INT TERM
  _frr_emit committed "$_frr_branch" "$1" "$2" "$3"
  _frr_restore_traps; _frr_state="none"
}

# 원자적 no-clobber 생성 — 같은 디렉터리의 임시 파일에 쓴 뒤 hard link 로 놓는다(대상이 파일·symlink·디렉터리로 이미 있으면 EEXIST 실패,
# 기존 것은 그대로). journal 은 "dst<TAB>tmp" 쌍이며 rollback 은 inode 동일성(-ef) 으로 소유권을 판별하므로 등록 시점과 무관하게 안전하다.
_frr_create_noclobber() { # <src> <dst>
  local tmp stray
  # 대상이 이미 있으면(파일·symlink·디렉터리·dangling symlink) 거부 — plain ln 은 디렉터리 대상 안에 링크를 만들며 성공하므로 먼저 막는다.
  [[ -e "$2" || -L "$2" ]] && return 1
  mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
  _frr_mktemp_in_dir tmp "$(dirname "$2")" || return 1
  cat "$1" > "$tmp" 2>/dev/null || return 1
  # journal 에 대상과, 검사~ln 사이에 디렉터리가 생기는 경쟁에서 plain ln 이 만들 수 있는 보조 링크 후보(dst/basename(tmp)) 를 둘 다 ln 전에 넣는다.
  # rollback 은 inode(-ef) 로 소유권을 확인하므로 후보가 실제로 생기지 않았거나 남의 파일이면 지우지 않는다.
  _frr_created+=("$2"$'\t'"$tmp" "$2/$(basename "$tmp")"$'\t'"$tmp")
  ln "$tmp" "$2" 2>/dev/null || return 1
  # 검사와 ln 사이에 디렉터리가 생긴 경쟁 — ln 이 그 안에 보조 링크를 만들었을 수 있다. 정확히 $2 가 tmp 와 같은 inode 여야만 성공.
  if [[ ! "$2" -ef "$tmp" ]]; then
    stray="$2/$(basename "$tmp")"
    [[ -f "$stray" && "$stray" -ef "$tmp" ]] && rm -f "$stray"
    return 1
  fi
}

fr_register_run() { # <slug> → exit 0 (committed|already) / 3 (skipped)
  local slug="$1" root default ref old row n detail cap="" base_f="" new_f="" idx_blob det_blob cap_blob="" tmpidx="" tree new wt_real="" rd_idx="" rd_det="" rd_cap=""
  local mode="none" p rc base_row sync_ok cap_on_default=0 wt_list st_out cur wt
  _frr_slug="$slug"; _frr_state="none"; _frr_wt=""; _frr_bak="-"; _frr_orig_ls=""; _frr_paths=(); _frr_created=(); _frr_ref=""; _frr_new=""; _frr_idx_old=""; _frr_idx_new=""; _frr_idx_want=""; _frr_parked=()
  _frr_install_traps
  case "$slug" in ""|-*|*-|*[!a-z0-9-]*) _frr_skip "${slug:--}" - bad-slug "slug 가 kebab-case(영숫자 시작·끝, 사이 '-') 가 아닙니다: '$slug'"; _frr_restore_traps; return 3 ;; esac
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _frr_skip "$slug" - git-error "git 저장소가 아닙니다"; _frr_restore_traps; return 3; }
  cd "$root" || { _frr_skip "$slug" - git-error "저장소 루트로 이동할 수 없습니다"; _frr_restore_traps; return 3; }
  default="$(get_default_branch 2>/dev/null)" || { _frr_skip "$slug" - no-default-ref "기본 브랜치를 판정할 수 없습니다"; _frr_restore_traps; return 3; }
  _frr_branch="$default"
  ref="refs/heads/$default"; _frr_ref="$ref"
  old="$(git rev-parse -q --verify "${ref}^{commit}" 2>/dev/null)" || { _frr_skip "$slug" "$default" no-default-ref "기본 브랜치 ref 가 없습니다: $default"; _frr_restore_traps; return 3; }

  # 1) 입력 추출 — 현재 워킹트리
  [[ -L "$FR_IDX_PATH" ]] && { _frr_skip "$slug" "$default" path-symlink "인덱스 파일이 symlink 입니다: $FR_IDX_PATH"; _frr_restore_traps; return 3; }
  [[ -f "$FR_IDX_PATH" ]] || { _frr_skip "$slug" "$default" row-not-found "현재 워킹트리에 $FR_IDX_PATH 가 없습니다"; _frr_restore_traps; return 3; }
  row="$(_frr_rows_for "$FR_IDX_PATH" "$slug")"
  n="$(printf '%s' "$row" | grep -c . || true)"
  [[ "$n" -ne 0 ]] || { _frr_skip "$slug" "$default" row-not-found "인덱스에 '$slug' 행이 없습니다"; _frr_restore_traps; return 3; }
  [[ "$n" -eq 1 ]] || { _frr_skip "$slug" "$default" row-ambiguous "인덱스에 '$slug' 행이 $n 개입니다"; _frr_restore_traps; return 3; }
  detail="$(printf '%s\n' "$row" | sed -n 's/.*\[상세\](items\/\([^)]*\.md\)).*/\1/p')"
  [[ -n "$detail" ]] || { _frr_skip "$slug" "$default" detail-missing "행에 [상세](items/…) 링크가 없습니다"; _frr_restore_traps; return 3; }
  case "$detail" in */*|.*) _frr_skip "$slug" "$default" detail-missing "상세 링크가 items/ 의 직접 자식 파일이 아닙니다: $detail"; _frr_restore_traps; return 3 ;; esac
  detail="$FR_ITEMS_DIR/$detail"
  [[ -f "$detail" && ! -L "$detail" ]] || { _frr_skip "$slug" "$default" detail-missing "상세 파일이 없습니다: $detail"; _frr_restore_traps; return 3; }
  # 등록 경로의 조상 디렉터리가 symlink 면 거부 — 저장소 밖 내용을 blob 으로 넣지 않는다.
  for p in rd-workflow-workspace rd-workflow-workspace/backlog "$FR_ITEMS_DIR" "$FR_CAP_DIR"; do
    [[ -L "$p" ]] && { _frr_skip "$slug" "$default" path-symlink "등록 경로의 상위 디렉터리가 symlink 입니다: $p"; _frr_restore_traps; return 3; }
  done
  # 캡처 후보: 같은 slug 의 fr 캡처 중 날짜가 가장 늦고, 같은 날짜면 충돌 번호(-N, 없으면 1) 가 가장 큰 것.
  #   capture writer 는 같은 날 충돌 시 -2, -3… 을 붙이므로(_task_common.sh) 문자열 최대값이 아니라 번호로 골라야 재시도 때 최신 원문이 실린다.
  #   캡처 자체가 symlink 면 거부한다(파일을 가리키는 symlink 도 -f 를 통과하므로 -L 을 따로 본다).
  local cap_date="" cap_n=0 bn d nn
  for p in "$FR_CAP_DIR"/*-fr-"$slug".md "$FR_CAP_DIR"/*-fr-"$slug"-[0-9]*.md; do
    [[ -e "$p" || -L "$p" ]] || continue
    [[ -L "$p" ]] && { _frr_skip "$slug" "$default" path-symlink "캡처 경로가 symlink 입니다: $p"; _frr_restore_traps; return 3; }
    [[ -f "$p" ]] || continue
    bn="$(basename "$p")"; d="${bn:0:10}"
    case "$bn" in *-fr-"$slug"-[0-9]*.md) nn="${bn##*-fr-$slug-}"; nn="${nn%.md}"; [[ "$nn" =~ ^[0-9]+$ ]] || continue ;; *) nn=1 ;; esac
    if [[ -z "$cap" || "$d" > "$cap_date" || ( "$d" == "$cap_date" && "$nn" -gt "$cap_n" ) ]]; then cap="$p"; cap_date="$d"; cap_n="$nn"; fi
  done

  # 2) 중복·충돌 — 보존 대상 tuple(행 전문·상세 blob·선택 캡처) 전부가 같을 때만 already. 부분 일치는 명시 reason 으로 skipped.
  base_row="$(git cat-file -p "${ref}:${FR_IDX_PATH}" 2>/dev/null | _frr_rows_for - "$slug")"
  if [[ -n "$cap" ]] && git cat-file -e "${ref}:${cap}" 2>/dev/null; then
    if [[ "$(git rev-parse "${ref}:${cap}")" != "$(git hash-object "$cap")" ]]; then
      _frr_skip "$slug" "$default" capture-conflict "기본 브랜치에 같은 경로의 캡처가 다른 내용으로 있습니다: $cap"; _frr_restore_traps; return 3
    fi
    cap_on_default=1
  fi
  if git cat-file -e "${ref}:${detail}" 2>/dev/null; then
    [[ "$(git rev-parse "${ref}:${detail}")" == "$(git hash-object "$detail")" ]] \
      || { _frr_skip "$slug" "$default" detail-conflict "기본 브랜치에 같은 경로의 상세가 다른 내용으로 있습니다: $detail"; _frr_restore_traps; return 3; }
    [[ -n "$base_row" ]] || { _frr_skip "$slug" "$default" row-missing-on-default "기본 브랜치에 상세는 있으나 인덱스 행이 없습니다 — 기본 브랜치에서 행을 직접 추가하세요"; _frr_restore_traps; return 3; }
    [[ "$base_row" == "$row" ]] || { _frr_skip "$slug" "$default" row-conflict "기본 브랜치의 '$slug' 행이 현재 행과 다릅니다"; _frr_restore_traps; return 3; }
    if [[ -n "$cap" && "$cap_on_default" -eq 0 ]]; then
      _frr_skip "$slug" "$default" capture-missing-on-default "기본 브랜치에 행·상세는 있으나 캡처($cap)가 없습니다 — 기본 브랜치에서 직접 추가하세요"; _frr_restore_traps; return 3
    fi
    _frr_emit already "$default" - - "FR 등록 커밋: 이미 기본 브랜치에 있습니다 ($default)"; _frr_cleanup; _frr_restore_traps; return 0
  fi
  [[ -z "$base_row" ]] || { _frr_skip "$slug" "$default" row-exists "기본 브랜치 인덱스에 '$slug' 행만 있고 상세가 없습니다"; _frr_restore_traps; return 3; }
  [[ "$cap_on_default" -eq 0 ]] || cap=""   # 같은 내용의 캡처가 이미 있으면 커밋 대상에서 제외

  # 3) 인덱스 합성 (base = 기본 브랜치 최신 내용)
  _frr_mktemp_into base_f || { _frr_skip "$slug" "$default" git-error "임시 파일 생성 실패"; _frr_restore_traps; return 3; }
  git cat-file -p "${ref}:${FR_IDX_PATH}" > "$base_f" 2>/dev/null || { _frr_skip "$slug" "$default" git-error "기본 브랜치의 인덱스를 읽을 수 없습니다"; _frr_restore_traps; return 3; }
  # base 가 개행으로 끝나지 않으면 합성 출력(개행 정규화)이 마지막 행을 수정으로 만들어 자기 검증(shape-mismatch) 에 영구히 걸린다 — 재실행으로 풀리지 않으므로 실행 가능한 사유로 낸다.
  [[ -z "$(tail -c1 "$base_f")" ]] || { _frr_skip "$slug" "$default" index-no-newline "기본 브랜치($default)의 인덱스 파일이 개행으로 끝나지 않습니다. 기본 브랜치에서 파일 끝 개행을 추가해 커밋한 뒤 재실행하십시오"; _frr_restore_traps; return 3; }
  _frr_mktemp_into new_f || { _frr_skip "$slug" "$default" git-error "임시 파일 생성 실패"; _frr_restore_traps; return 3; }
  _frr_insert_row "$base_f" "$row" > "$new_f" || { _frr_skip "$slug" "$default" git-error "인덱스 합성 실패"; _frr_restore_traps; return 3; }

  # 4) blob·tree·commit (임시 index)
  idx_blob="$(git hash-object -w "$new_f")" && det_blob="$(git hash-object -w "$detail")" || { _frr_skip "$slug" "$default" git-error "blob 기록 실패"; _frr_restore_traps; return 3; }
  if [[ -n "$cap" ]]; then cap_blob="$(git hash-object -w "$cap")" || { _frr_skip "$slug" "$default" git-error "캡처 blob 기록 실패"; _frr_restore_traps; return 3; }; fi
  _frr_mktemp_into tmpidx || { _frr_skip "$slug" "$default" git-error "임시 index 생성 실패"; _frr_restore_traps; return 3; }
  rm -f "$tmpidx"
  tree="$(
    export GIT_INDEX_FILE="$tmpidx"
    git read-tree "$ref" >/dev/null 2>&1 || exit 1
    git update-index --add --cacheinfo "100644,$idx_blob,$FR_IDX_PATH" >/dev/null 2>&1 || exit 1
    git update-index --add --cacheinfo "100644,$det_blob,$detail" >/dev/null 2>&1 || exit 1
    if [[ -n "$cap" ]]; then git update-index --add --cacheinfo "100644,$cap_blob,$cap" >/dev/null 2>&1 || exit 1; fi
    git write-tree
  )" || { _frr_skip "$slug" "$default" git-error "트리 구성 실패"; _frr_restore_traps; return 3; }
  new="$(git commit-tree "$tree" -p "$old" -m "docs: FR 등록 — $slug" 2>/dev/null)" || { _frr_skip "$slug" "$default" git-error "commit-tree 실패"; _frr_restore_traps; return 3; }
  [[ "$(registration_commit_shape "$new" 2>/dev/null)" == "$slug" ]] || { _frr_skip "$slug" "$default" shape-mismatch "생성한 커밋이 등록 커밋 형태 검증을 통과하지 못했습니다"; _frr_restore_traps; return 3; }

  # 5) 체크아웃 상태 판정 — 명령 rc 를 stdout 과 분리해 본다. 탐색·status 실패는 ref 이동 전 git-error 로 중단한다.
  #    dirty 는 git 의 관점(status --porcelain --untracked-files=all) 으로 본다. git 이 보지 못하는 것(ignored 파일·빈 디렉터리)은
  #    noclobber 생성이 거부해 write-failed 로 드러나며, 기존 것은 그대로 남는다.
  _frr_paths=("$FR_IDX_PATH" "$detail"); [[ -z "$cap" ]] || _frr_paths+=("$cap")
  wt_list="$(git worktree list --porcelain 2>/dev/null)" || { _frr_skip "$slug" "$default" git-error "git worktree list 실패"; _frr_restore_traps; return 3; }
  wt="$(printf '%s\n' "$wt_list" | awk -v ref="branch $ref" '/^worktree /{ p = substr($0, 10); next } $0 == ref { print p; exit }')"
  cur="$(pwd -P)"
  if [[ -n "$wt" ]]; then
    if [[ "$(cd "$wt" 2>/dev/null && pwd -P)" == "$cur" ]]; then
      mode="current"
      st_out="$(git diff --cached --name-only -- "${_frr_paths[@]}" 2>/dev/null)" || { _frr_skip "$slug" "$default" git-error "git diff --cached 실패"; _frr_restore_traps; return 3; }
      [[ -z "$st_out" ]] || { _frr_skip "$slug" "$default" staged "등록 경로가 이미 staged 상태입니다 (사용자의 staged 상태를 바꾸지 않습니다)"; _frr_restore_traps; return 3; }
    else
      mode="other"; _frr_wt="$wt"
      st_out="$(git -C "$wt" status --porcelain --untracked-files=all -- "${_frr_paths[@]}" 2>/dev/null)" || { _frr_skip "$slug" "$default" git-error "기본 브랜치 worktree($wt) 의 git status 실패"; _frr_restore_traps; return 3; }
      [[ -z "$st_out" ]] || { _frr_skip "$slug" "$default" other-worktree-dirty "기본 브랜치 worktree($wt) 의 등록 경로가 dirty 입니다"; _frr_restore_traps; return 3; }
      # 대상 worktree 의 등록 경로 조상이 symlink 면 거부(저장소 밖에 쓰지 않는다). 보장 범위: 호출 시 이미 존재하거나 각 _frr_real_dst 해석 시점까지 드러난 조상 symlink 다. 해석 뒤 같은 사용자가 디렉터리를 동시에 교체하는 경우는 막지 않는다(git 자신의 worktree 쓰기와 같은 노출 — 경로 문자열을 다시 탐색한다).
      wt_real="$(cd "$wt" && pwd -P)" || { _frr_skip "$slug" "$default" git-error "기본 브랜치 worktree($wt) 경로 해석 실패"; _frr_restore_traps; return 3; }
      for p in rd-workflow-workspace rd-workflow-workspace/backlog "$FR_ITEMS_DIR" "$FR_CAP_DIR"; do
        [[ -L "$wt/$p" ]] && { _frr_skip "$slug" "$default" path-symlink "기본 브랜치 worktree($wt) 의 등록 경로 상위 디렉터리가 symlink 입니다: $p"; _frr_restore_traps; return 3; }
      done
      _frr_real_dst() { # <rel> → stdout 물리 경로. 조상 디렉터리를 만들고(mkdir -p) 해석한 물리 디렉터리가 wt_real 아래 같은 상대 경로여야 한다.
        local d; d="$(dirname "$1")"
        mkdir -p "$wt/$d" 2>/dev/null || return 1
        [[ "$(cd "$wt/$d" 2>/dev/null && pwd -P)" == "$wt_real/$d" ]] || return 1
        printf '%s/%s\n' "$wt_real/$d" "$(basename "$1")"
      }
      # 준비 (순서 고정: 인덱스 → 상세 → 캡처 → index). 실패 시 역순 rollback. 상세·캡처는 noclobber 생성.
      _frr_orig_ls="$(git -C "$wt" ls-files -s -- "${_frr_paths[@]}" 2>/dev/null)" || { _frr_skip "$slug" "$default" git-error "기본 브랜치 worktree($wt) 의 ls-files 실패"; _frr_restore_traps; return 3; }
      if [[ -f "$wt/$FR_IDX_PATH" ]]; then
        _frr_mktemp_into _frr_bak && cp "$wt/$FR_IDX_PATH" "$_frr_bak" || { _frr_bak="-"; _frr_skip "$slug" "$default" write-failed "인덱스 백업 실패"; _frr_restore_traps; return 3; }
        # status 검사~백업 사이의 편집: 백업 바이트는 그 worktree index 의 blob 과 같아야 한다(다르면 dirty 로 본다).
        local exp_blob; exp_blob="$(printf '%s\n' "$_frr_orig_ls" | awk -F'\t' -v p="$FR_IDX_PATH" '$2 == p { split($1, a, " "); print a[2] }')"
        [[ -n "$exp_blob" && "$(git hash-object "$_frr_bak")" == "$exp_blob" ]] || { _frr_skip "$slug" "$default" other-worktree-dirty "기본 브랜치 worktree($wt) 의 인덱스가 검사 직후 바뀌었습니다"; _frr_restore_traps; return 3; }
      fi
      rc=0
      _frr_state="prepared"
      rd_idx="$(_frr_real_dst "$FR_IDX_PATH")" && rd_det="$(_frr_real_dst "$detail")" || rc=1
      [[ $rc -eq 0 && -n "$cap" ]] && { rd_cap="$(_frr_real_dst "$cap")" || rc=1; }
      if [[ $rc -ne 0 ]]; then _frr_state="none"; _frr_skip "$slug" "$default" path-symlink "기본 브랜치 worktree($wt) 의 등록 경로가 worktree 밖으로 해석됩니다"; _frr_restore_traps; return 3; fi
      if [[ "$_frr_bak" != "-" ]]; then _frr_swap_file "$new_f" "$rd_idx" "$_frr_bak" || rc=1
      else _frr_create_noclobber "$new_f" "$rd_idx" || rc=1; fi
      [[ $rc -eq 0 ]] && { _frr_create_noclobber "$detail" "$rd_det" || rc=1; }
      [[ $rc -eq 0 && -n "$cap" ]] && { _frr_create_noclobber "$cap" "$rd_cap" || rc=1; }
      # 놓은 뒤 논리 경로가 물리 경로와 같은 inode 인지 — 어긋나면 rollback(write-failed). 해석 뒤의 동시 디렉터리 교체까지 잡는 검사는 아니다(위 보장 범위 참조).
      [[ $rc -eq 0 && "$wt/$FR_IDX_PATH" -ef "$rd_idx" && "$wt/$detail" -ef "$rd_det" ]] || rc=1
      [[ $rc -eq 0 && -n "$cap" ]] && { [[ "$wt/$cap" -ef "$rd_cap" ]] || rc=1; }
      if [[ $rc -eq 0 ]]; then
        git -C "$wt" update-index --add --cacheinfo "100644,$idx_blob,$FR_IDX_PATH" >/dev/null 2>&1 \
          && git -C "$wt" update-index --add --cacheinfo "100644,$det_blob,$detail" >/dev/null 2>&1 || rc=1
        [[ $rc -eq 0 && -n "$cap" ]] && { git -C "$wt" update-index --add --cacheinfo "100644,$cap_blob,$cap" >/dev/null 2>&1 || rc=1; }
      fi
      if [[ $rc -ne 0 ]]; then
        _frr_wt_rollback; _frr_state="none"
        _frr_skip "$slug" "$default" write-failed "기본 브랜치 worktree($wt) 에 등록 파일을 쓸 수 없습니다(대상 경로가 이미 존재하거나 쓰기 실패)"; _frr_restore_traps; return 3
      fi
    fi
  fi

  # 6) CAS — committing 상태에서 실행한다. 신호가 update-ref 직후·상태 갱신 전에 오면 핸들러가 ref 를 재확인한다.
  _frr_new="$new"; _frr_state="committing"
  if ! git update-ref -m "fr-register $slug" "$ref" "$new" "$old" >/dev/null 2>&1; then
    _frr_state="prepared"; [[ -n "$_frr_wt" ]] && _frr_wt_rollback
    _frr_state="none"
    _frr_skip "$slug" "$default" ref-moved "기본 브랜치 ref 갱신이 거부됐습니다 (다른 커밋이 먼저 들어갔거나 훅이 막았습니다)"; _frr_restore_traps; return 3
  fi
  _frr_state="committed"
  # 옮겨 둔 원본 인덱스 inode 는 지우지 않고 보관한다(열린 FD 의 늦은 쓰기 보존). 보관 시점에 내용이 백업과 다르면 사람용 메시지에 경로를 병기한다.
  if [[ -n "$_frr_idx_old" ]]; then _frr_park "$_frr_idx_old" "$slug-index.md" >/dev/null || true; _frr_idx_old=""; _frr_idx_new=""; _frr_idx_want=""; fi

  # 7) 사후 동기화 — 커밋은 이미 성공했으므로 실패해도 exit 0 이되 reason 과 복구 명령을 숨기지 않는다.
  sync_ok=1
  if [[ "$mode" == "current" ]]; then
    git update-index --add --cacheinfo "100644,$idx_blob,$FR_IDX_PATH" >/dev/null 2>&1 || sync_ok=0
    git update-index --add --cacheinfo "100644,$det_blob,$detail" >/dev/null 2>&1 || sync_ok=0
    if [[ -n "$cap" ]]; then git update-index --add --cacheinfo "100644,$cap_blob,$cap" >/dev/null 2>&1 || sync_ok=0; fi
    if [[ $sync_ok -eq 0 ]]; then
      _frr_finish_committed "${new:0:7}" wt-sync-incomplete "FR 등록 커밋: $default ${new:0:7} — 단, 현재 worktree 의 index 동기화가 미완입니다(등록 경로가 staged 삭제처럼 보일 수 있음). 복구: git reset -q -- ${_frr_paths[*]}"; return 0
    fi
  elif [[ "$mode" == "other" ]]; then
    st_out="$(git -C "$wt" status --porcelain -- "${_frr_paths[@]}" 2>/dev/null)" || sync_ok=0
    [[ -z "$st_out" ]] || sync_ok=0
    if [[ $sync_ok -eq 0 ]]; then
      _frr_finish_committed "${new:0:7}" wt-sync-incomplete "FR 등록 커밋: $default ${new:0:7} — 단, 기본 브랜치 worktree($wt) 동기화 확인이 실패했거나 미완입니다. 복구: git -C \"$wt\" status -- ${_frr_paths[*]} 로 확인하고, 보존할 편집이 없으면 git -C \"$wt\" checkout -- ${_frr_paths[*]}"; return 0
    fi
  fi
  _frr_finish_committed "${new:0:7}" - "FR 등록 커밋: $default ${new:0:7}"; return 0
}
