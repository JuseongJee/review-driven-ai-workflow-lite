#!/usr/bin/env bash
# tasks_list.sh — 진행 중인 모든 작업의 현황(단계·worktree·세션·뒤처짐) 출력.
#   herdr 를 호출하지 않는다 — herdr 유무와 무관하게 같은 출력을 낸다(rd task list).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_tasks_index.sh"
source "$SCRIPT_DIR/session_launch.sh"

# project_root — 주입값 우선(rd 가 이미 export). 없으면 git 저장소 루트(cwd 기준) —
# SCRIPT_DIR 기반 추정은 쓰지 않는다: 독립 실행(테스트) 시 SCRIPT_DIR 는 실제 dev repo
# 경로이고 cwd 는 fixture 저장소일 수 있어, SCRIPT_DIR 기반 추정은 엉뚱한 루트를 가리킨다.
if [[ -z "${project_root:-}" ]]; then
  project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || project_root="$PWD"
fi
cd "$project_root"

source "$SCRIPT_DIR/_lifecycle_common.sh"
source "$SCRIPT_DIR/../_submodule_common.sh"

REBUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=1; shift ;;
    *) echo "tasks_list: 알 수 없는 옵션: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------------
_tl_stale_threshold() {
  local cfg="${project_root}/rd-workflow/config/workflow.json"
  local v=""
  if [[ -f "$cfg" ]]; then
    v="$(sed -n 's/.*"stale_behind_threshold"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg" | head -1)"
  fi
  [[ -n "$v" ]] && printf '%s\n' "$v" || printf '20\n'
}

DEFAULT_BRANCH="$(get_default_branch 2>/dev/null)" || DEFAULT_BRANCH=""
REMOTE_MODE="$(detect_remote_mode 2>/dev/null)" || REMOTE_MODE="local-only"
THRESHOLD="$(_tl_stale_threshold)"

# ---------------------------------------------------------------------------
# --rebuild — git 에서 직접 fr ref 를 열거해 색인을 재구성한다.
#   기존 행을 지우지 않는다(키 단위 upsert 만) — cleanup-pending·launch·launch-token 은
#   그 자체로 보존된다(Task 1 계약: upsert 는 넘긴 키만 갱신한다).
# ---------------------------------------------------------------------------
_tl_rebuild() {
  tasks_lock_acquire "tasks-list-rebuild" "-" || {
    echo "tasks_list: --rebuild 락을 얻지 못했습니다 — 다른 작업이 색인을 쓰는 중일 수 있습니다." >&2
    return 1
  }

  # 1) fr ref 를 먼저 열거한다 — 체크아웃된 것만 보면 --no-worktree 작업을 놓친다.
  #
  #    **복구할 수 없는 `launch` 는 `unknown` 으로 둔다** (change spec 159행·D11 판정 4).
  #    rebuild 는 git 에서 ref 만 볼 수 있을 뿐 그 작업에 세션이 떠 있었는지는 모른다 —
  #    그런데 예전에는 이 값을 **아예 쓰지 않아** 새로 복원된 행이 빈 값으로 남았다.
  #    빈 값은 표시상 「확인 필요」지만 promote 의 재착수 판정에서는 「예약 후 기동 시도」
  #    로 떨어지므로, 색인을 잃은 뒤 rebuild 한 사용자가 **살아 있는 세션 위에 두 번째
  #    세션을 띄우게** 된다(review R5 가 막으려던 바로 그 경로가 rebuild 로 열려 있었다).
  #    이미 값이 있는 행은 덮지 않는다 — 그것은 복구할 수 있었던 사실이다.
  local ref slug cur_launch
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    slug="${ref#refs/heads/fr/}"
    [[ -z "$slug" || "$slug" == "$ref" ]] && continue
    tasks_index_upsert "$slug" fr-branch="fr/${slug}" >/dev/null 2>&1 || true
    cur_launch="$(tasks_index_get "$slug" launch 2>/dev/null)" || cur_launch=""
    [[ -z "$cur_launch" ]] && { tasks_index_upsert "$slug" launch=unknown >/dev/null 2>&1 || true; }
  done < <(git for-each-ref --format='%(refname)' 'refs/heads/fr/*' 2>/dev/null)

  # 2) 체크아웃 대조 — git worktree list --porcelain 로 실제 checkout 경로를 찾는다.
  #    여기서 찾은 slug 를 줄 단위로 모아 둔다(bash 3.2 에는 연관배열이 없다). 3) 이
  #    "git 이 체크아웃이라고 말한 작업" 과 그 밖을 가르는 근거다.
  local line wt_path wt_branch
  local found_slugs=""
  wt_path=""; wt_branch=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt_path="${line#worktree }" ;;
      branch\ refs/heads/fr/*)
        wt_branch="${line#branch refs/heads/}"
        slug="${wt_branch#fr/}"
        if [[ -n "$slug" && -n "$wt_path" ]]; then
          tasks_index_upsert "$slug" worktree-path="$wt_path" checkout=yes >/dev/null 2>&1 || true
          found_slugs="${found_slugs}${slug}
"
        fi
        ;;
      "")
        wt_path=""; wt_branch=""
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)

  # 3) fr ref 는 있는데 checkout 대조에서 못 찾은 작업은 checkout=none 으로 **덮어쓴다.**
  #    이전 값(`checkout=yes`)을 조건으로 삼지 않는다 (final diff review F2) — 조건으로
  #    삼으면 한 번 yes 였던 행은 그 경로가 다른 브랜치로 넘어가거나 worktree 가 사라져도
  #    영원히 yes 로 남아, rebuild 가 stale 을 복구하지 못한다. rebuild 의 권위는 git 이다.
  #    (worktree-path 는 손대지 않는다 — 이전에 알던 경로가 있으면 "worktree 없음" 판정에
  #     쓰고, checkout=none 인 행의 경로는 대상 판정에서 어차피 git 대조로 걸러진다.)
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    slug="${ref#refs/heads/fr/}"
    [[ -z "$slug" || "$slug" == "$ref" ]] && continue
    case "
${found_slugs}" in
      *"
${slug}
"*) continue ;;
    esac
    tasks_index_upsert "$slug" checkout=none >/dev/null 2>&1 || true
  done < <(git for-each-ref --format='%(refname)' 'refs/heads/fr/*' 2>/dev/null)

  tasks_lock_release
  return 0
}

if [[ "$REBUILD" -eq 1 ]]; then
  _tl_rebuild || echo "tasks_list: --rebuild 락을 얻지 못해 재구성을 건너뜁니다." >&2
fi

# ---------------------------------------------------------------------------
# 정리 대기 행 지연 정리 — state=cleanup-pending 행마다 남은 것(worktree 등록·로컬 브랜치)을
# 안전할 때만 지우고 색인 행을 지운다. 발행이 끝났는데 호출자 worktree 때문에 archive.sh 가
# 지우지 못한 잔여(skipped-self)가 주 대상이다. 아무것도 안 남은 낡은 행은 예전처럼 행만 지운다.
# 행이 있을 때만 락을 잡고, 못 잡으면 색인을 바꾸지 않고 목록만 보여준다(rc 0). 판정은 락을
# 얻은 뒤 행마다 한다. 결과는 PRUNED_NOTE(낡은 행) 와 SWEEP_NOTES(정리됨·보류·부분 실패)로 모아
# 출력 끝에 낸다. 보류·부분 실패는 실제로 남은 것이 있는 행에서만 낸다.
# ---------------------------------------------------------------------------
PRUNED_NOTE=""
# 파괴적 정리(worktree·브랜치 삭제)는 기본 체크아웃에서 부른 `rd task list` 에서만 한다 — 다른 작업
# worktree 에서 목록만 보려던 호출이 발행 끝난 다른 작업의 worktree 를 지우지 않게 한다. 기본 체크아웃은
# 공유 .git 의 부모 디렉터리다(`archive.sh` Step -1 과 같은 기준). 판정 실패는 기본 체크아웃이 아닌 것으로 본다.
_tl_is_default_checkout() {
  local common main here
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$common" == /* ]] || return 1
  main="$(cd "$(dirname "$common")" 2>/dev/null && pwd -P)" || return 1
  here="$(pwd -P)" || return 1
  [[ "$main" == "$here" ]]
}
if _tl_is_default_checkout; then _TL_DEFAULT_CHECKOUT=1; else _TL_DEFAULT_CHECKOUT=0; fi

SWEEP_NOTES=""
_SWEEP_REMOVED=0
_SWEEP_NAMES=""

_tl_note() { SWEEP_NOTES="${SWEEP_NOTES}${1}"$'\n'; }
_tl_hold() { _tl_note "정리 보류: ${1} — ${2}. 재시도: ${3}"; }  # <slug> <사유> <재시도 안내>
_tl_fail() { _tl_note "정리 부분 실패: ${1} — ${2}. 복구: ${3}"; }  # <slug> <사유> <복구 명령>

# <fr> 브랜치를 체크아웃한 worktree 등록을 "<경로><TAB><locked 0|1>" 줄로 낸다. rc 1: 조회 실패.
_tl_branch_regs() {
  local out
  out="$(git worktree list --porcelain 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk -v ref="branch refs/heads/$1" '
    BEGIN { RS = ""; FS = "\n" }
    { p = ""; l = 0; m = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^worktree /) p = substr($i, 10)
        else if ($i == ref) m = 1
        else if ($i == "locked" || $i ~ /^locked /) l = 1
      }
      if (m) print p "\t" l }'
}

# 색인 행을 한 번 읽어 전역 TL_* 를 채운다(서브셸 없이). 행이 없으면 모두 빈 값, rc 1.
#   파싱 규칙은 tasks_index_get 과 같다 — 첫 번째로 일치하는 slug 행, 탭 분리 k=v, 같은 키는 첫 값.
#   작업당 tasks_index_get 을 필드 수만큼 부르면 색인을 그 횟수만큼 다시 읽고 서브셸을 띄운다.
#   색인을 쓴 뒤 같은 slug 의 값을 다시 읽어야 하면 이 함수를 다시 부른다.
_tl_load_row() {  # <slug>
  TL_FR_BRANCH=""; TL_STATE=""; TL_CHECKOUT=""; TL_WORKTREE=""; TL_LAUNCH=""; TL_LAUNCH_BACKEND=""
  local slug="$1" path line fields f k v
  _tasks_shared_dir_fill || :; path="$_TASKS_SD_VAL/tasks.local"
  [[ -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "slug=${slug}" || "$line" == "slug=${slug}"$'\t'* ]]; then
      IFS=$'\t' read -r -a fields <<<"$line"
      local seen=" "
      for f in "${fields[@]}"; do
        k="${f%%=*}"; v="${f#*=}"
        case "$seen" in *" $k "*) continue ;; esac
        seen="${seen}${k} "
        case "$k" in
          fr-branch) TL_FR_BRANCH="$v" ;;
          state) TL_STATE="$v" ;;
          checkout) TL_CHECKOUT="$v" ;;
          worktree-path) TL_WORKTREE="$v" ;;
          launch) TL_LAUNCH="$v" ;;
          launch-backend) TL_LAUNCH_BACKEND="$v" ;;
        esac
      done
      return 0
    fi
  done <"$path"
  return 1
}

# 발행 증거가 cleanup-pending 인지. 아니면 rc 1 이고 판정값을 _TL_EV 에 둔다.
_tl_evidence_ok() {  # <slug> <oid>
  _TL_EV="$(tasks_publish_evidence "$1" "$2" "$DEFAULT_BRANCH" "$REMOTE_MODE")"
  [[ "$_TL_EV" == "cleanup-pending" ]]
}

_tl_cp_resolve() {  # <slug> — 지연 정리가 worktree·로컬 브랜치를 풀었으므로 그 정리 잔여 기록을 푼다
  bash "$SCRIPT_DIR/cleanup_pending.sh" resolve "$1" worktree local-branch >/dev/null 2>&1 \
    || echo "tasks_list: 경고 — 정리 잔여 기록 해제 실패: $1" >&2
}

_tl_sweep_one() {  # <slug>
  local slug="$1" fr wt oid regs nregs rp lk rn wn st orc oid2 err
  local again="원인을 해소한 뒤 rd task list 를 다시 실행"
  _tl_load_row "$slug" || :
  fr="$TL_FR_BRANCH"
  [[ -z "$fr" ]] && fr="fr/${slug}"
  wt="$TL_WORKTREE"

  # 1) 상태 수집
  oid="$(git rev-parse --verify --quiet "refs/heads/${fr}^{commit}" 2>/dev/null)" || oid=""
  if ! regs="$(_tl_branch_regs "$fr")"; then
    _tl_hold "$slug" "worktree 목록을 조회하지 못함" "$again"; return 0
  fi
  nregs=0
  [[ -n "$regs" ]] && nregs="$(printf '%s\n' "$regs" | grep -c '')"

  # 2) 아무것도 안 남음 — 행만 지운다
  if [[ -z "$oid" && "$nregs" -eq 0 && ( -z "$wt" || ! -d "$wt" ) ]]; then
    if tasks_index_remove "$slug" >/dev/null 2>&1; then
      _tl_cp_resolve "$slug"
      _SWEEP_REMOVED=$((_SWEEP_REMOVED + 1))
      if [[ -n "$_SWEEP_NAMES" ]]; then _SWEEP_NAMES="${_SWEEP_NAMES}, ${slug}"; else _SWEEP_NAMES="$slug"; fi
    else
      echo "tasks_list: 낡은 정리 대기 기록 삭제 실패: ${slug}" >&2
    fi
    return 0
  fi

  # 2b) 남은 것이 있는데 기본 체크아웃이 아니면 삭제하지 않는다
  if [[ "$_TL_DEFAULT_CHECKOUT" -ne 1 ]]; then
    _tl_hold "$slug" "기본 체크아웃이 아닌 worktree 에서 실행되어 삭제하지 않음" "기본 체크아웃에서 rd task list 를 실행"
    return 0
  fi

  # 3) 발행 증거
  if [[ -z "$oid" ]]; then
    _tl_hold "$slug" "브랜치 ${fr} 는 없는데 worktree 흔적이 남아 발행 증거를 판정할 수 없음" "남은 흔적을 직접 확인(git worktree list, ${wt:--})한 뒤 정리"
    return 0
  fi
  if ! _tl_evidence_ok "$slug" "$oid"; then
    _tl_hold "$slug" "발행 증거가 ${_TL_EV} 라 지우지 않음" "발행을 마치거나 원인을 해소한 뒤 rd task list 를 다시 실행"
    return 0
  fi

  # 4) worktree 등록 — 정확히 1건이어야 하고 모든 검사를 통과해야 지운다
  if [[ "$nregs" -gt 1 ]]; then
    _tl_hold "$slug" "같은 브랜치를 체크아웃한 worktree 가 ${nregs}건" "git worktree list 로 확인해 직접 정리"
    return 0
  fi
  if [[ "$nregs" -eq 1 ]]; then
    rp="${regs%%$'\t'*}"; lk="${regs##*$'\t'}"
    rn="$(cd "$rp" 2>/dev/null && pwd -P)" || rn=""
    wn=""
    if [[ -n "$wt" ]]; then wn="$(cd "$wt" 2>/dev/null && pwd -P)" || wn=""; fi
    if [[ -z "$rn" || -z "$wn" || "$rn" != "$wn" ]]; then
      _tl_hold "$slug" "worktree 경로 불일치 (등록: ${rp}, 기록: ${wt:--})" "git worktree list 로 확인해 직접 정리"
      return 0
    fi
    if [[ "$lk" == "1" ]]; then
      _tl_hold "$slug" "worktree 가 locked 상태" "git worktree unlock ${rp} 뒤 rd task list 를 다시 실행"
      return 0
    fi
    if ! st="$(git -C "$rn" -c status.showUntrackedFiles=normal status --porcelain 2>/dev/null)"; then
      _tl_hold "$slug" "worktree 상태를 조회하지 못함" "$again"
      return 0
    fi
    if [[ -n "$st" ]]; then
      _tl_hold "$slug" "미커밋 변경이 있음 ($(printf '%s\n' "$st" | grep -c '')건)" "${rp} 의 변경을 커밋하거나 버린 뒤 rd task list 를 다시 실행"
      return 0
    fi
    orc=0; tasks_path_occupied "$rn" || orc=$?
    tab_why=""
    if [[ "$orc" -eq 0 ]]; then
      # 점유 중이면 끝난 작업 탭인지 보고 닫는다 (change spec D14). 닫았으면 탭 셸이 끝나길 기다려 다시 본다.
      trc=0; tab_why="$(session_tab_close_if_ended "$slug")" || trc=$?
      if [[ "$trc" -eq 0 ]]; then
        _tl_note "탭 닫음: ${slug}"
        tab_why=""
        for _i in 1 2 3 4; do
          sleep 0.5
          orc=0; tasks_path_occupied "$rn" || orc=$?
          [[ "$orc" -eq 0 ]] || break
        done
      elif [[ "$trc" -eq 2 ]]; then
        tab_why=""
      fi
    fi
    if [[ "$orc" -eq 0 ]]; then
      _tl_hold "$slug" "점유 — 세션이 ${rp} 안에 있음${tab_why:+ (탭: ${tab_why%% — *})}" "그 세션을 닫거나 worktree 를 나온 뒤 rd task list 를 다시 실행"
      return 0
    elif [[ "$orc" -ne 1 ]]; then
      _tl_hold "$slug" "점유 판정불가(${TASKS_OCCUPIED_REASON:-알 수 없음})" "lsof 를 확인한 뒤 rd task list 를 다시 실행"
      return 0
    fi
    local _rrc=0 _hi; err="$(rd_worktree_remove_safe "$rn")" || _rrc=$?
    if [[ "$_rrc" -eq 1 ]]; then
      _hi="$(rd_worktree_hold_info "${err%%$'\t'*}" "${err#*$'\t'}" "$rn")"
      _tl_hold "$slug" "${_hi%%$'\t'*}" "${_hi#*$'\t'} 로 확인한 뒤 rd task list 를 다시 실행"
      return 0
    elif [[ "$_rrc" -ne 0 ]]; then
      _tl_fail "$slug" "worktree 제거 실패 (${err//$'\n'/ })" "git worktree remove ${rp}"
      return 0
    fi
  fi

  # 5) 로컬 브랜치 — 등록 0건과 증거를 다시 확인하고, 읽은 oid 일 때만 지운다(expected-old)
  if ! regs="$(_tl_branch_regs "$fr")" || [[ -n "$regs" ]]; then
    _tl_hold "$slug" "worktree 등록이 남아 있거나 조회하지 못함" "$again"
    return 0
  fi
  oid2="$(git rev-parse --verify --quiet "refs/heads/${fr}^{commit}" 2>/dev/null)" || oid2=""
  if [[ "$oid2" != "$oid" ]] || ! _tl_evidence_ok "$slug" "$oid"; then
    _tl_hold "$slug" "판정 뒤 브랜치 ${fr} 가 바뀌었거나 발행 증거가 ${_TL_EV:-바뀜}" "$again"
    return 0
  fi
  if ! err="$(git update-ref -d "refs/heads/${fr}" "$oid" 2>&1)"; then
    _tl_fail "$slug" "로컬 브랜치 ${fr} 삭제 거부 (${err//$'\n'/ })" "브랜치 tip 을 확인한 뒤 rd task list 를 다시 실행하거나 git branch -D ${fr}"
    return 0
  fi

  # 6) 둘 다 없음을 확인한 뒤에만 색인 행을 지운다
  if git rev-parse --verify --quiet "refs/heads/${fr}" >/dev/null 2>&1 \
     || ! regs="$(_tl_branch_regs "$fr")" || [[ -n "$regs" ]]; then
    _tl_fail "$slug" "삭제 뒤 브랜치 또는 worktree 등록이 남아 있음" "git worktree list·git branch 로 확인"
    return 0
  fi
  if ! tasks_index_remove "$slug" >/dev/null 2>&1; then
    _tl_fail "$slug" "색인 행 삭제 실패" "rd task list --rebuild 뒤 다시 실행"
    return 0
  fi
  _tl_cp_resolve "$slug"
  if [[ "$nregs" -eq 1 ]]; then
    _tl_note "정리됨: ${slug} — worktree·로컬 브랜치 제거, 색인 행 삭제"
  else
    _tl_note "정리됨: ${slug} — 로컬 브랜치 제거, 색인 행 삭제"
  fi
}

_tl_sweep_pending() {
  local slug st candidates="" total=0 remaining marker mpid
  while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    st="$(tasks_index_get "$slug" state 2>/dev/null)" || st=""
    if [[ "$st" == "cleanup-pending" ]]; then
      candidates="${candidates}${slug}
"
      total=$((total + 1))
    fi
  done < <(tasks_index_all_slugs 2>/dev/null)
  [[ -z "$candidates" ]] && return 0

  # 락은 행 하나의 판정~삭제 구간에만 잡는다. 발행(archive.sh)이 락을 기다리는 중이면
  # (archive-waiting 표지의 pid 가 살아 있음) 행 사이에서 양보한다 — 연속 재획득 기아 방지.
  marker="$(tasks_shared_dir 2>/dev/null)/archive-waiting"
  remaining="$total"
  while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    mpid="$(cat "$marker" 2>/dev/null || true)"
    case "$mpid" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$mpid" 2>/dev/null; then
          echo "tasks_list: 낡은 정리 대기 기록 정리를 양보함 — 발행 대기 중 (남은 ${remaining}건)" >&2
          break
        fi
        ;;
    esac
    if ! tasks_lock_acquire "tasks-list-prune" "-"; then
      echo "tasks_list: 낡은 정리 대기 기록 정리를 건너뜀 — 락을 얻지 못했습니다 (남은 ${remaining}건)" >&2
      break
    fi
    # 락을 얻은 뒤 행을 다시 판정한다 — 그 사이 다른 실행이 행을 바꿨을 수 있다.
    st="$(tasks_index_get "$slug" state 2>/dev/null)" || st=""
    if [[ "$st" == "cleanup-pending" ]]; then
      _tl_sweep_one "$slug"
    fi
    tasks_lock_release || true
    remaining=$((remaining - 1))
  done <<< "$candidates"

  if [[ "$_SWEEP_REMOVED" -ge 1 ]]; then
    PRUNED_NOTE="정리: 낡은 정리 대기 기록 ${_SWEEP_REMOVED}건 삭제 (${_SWEEP_NAMES})"
  fi
  return 0
}

_tl_sweep_pending

# ---------------------------------------------------------------------------
# 발행 증거 판정 (spec D8) — merge 여부는 발행 완료의 증거가 아니다.
#   stdout: in-progress | needs-verify | cleanup-pending
#
# 단일 출처는 `_tasks_index.sh` 의 `tasks_publish_evidence` 다 (2026-09 final diff
# review I2) — promote.sh 의 재착수 판정(D8)도 같은 함수를 쓴다. 이 wrapper 는
# 이 파일 안에서 이미 계산해 둔 DEFAULT_BRANCH·REMOTE_MODE 를 넘기기만 한다.
# ---------------------------------------------------------------------------
_tl_publish_evidence() {
  tasks_publish_evidence "$1" "$2" "$DEFAULT_BRANCH" "$REMOTE_MODE"
}

# ---------------------------------------------------------------------------
# 단계(status) 읽기 — 체크아웃된 작업은 worktree 의 task-state, 비체크아웃(spec D13)은
# fr tip 의 blob 을 읽는다. 지금 checkout 된 baseline task-state 파일을 그대로 읽으면
# 엉뚱한 상태를 보여준다.
# ---------------------------------------------------------------------------
_tl_read_status() {
  local checked_out="$1" wt="$2" fr_ref="$3"
  local raw=""
  if [[ "$checked_out" == "yes" && -n "$wt" && -d "$wt" ]]; then
    raw="$(awk -F'=' '$1=="status"{sub(/^[^=]+=/,""); print; exit}' \
      "${wt}/rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null)" || raw=""
  else
    raw="$(git show "${fr_ref}:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null \
      | awk -F'=' '$1=="status"{sub(/^[^=]+=/,""); print; exit}')" || raw=""
  fi
  [[ -n "$raw" ]] && printf '%s\n' "$raw" || printf '(알 수 없음)\n'
}

# ---------------------------------------------------------------------------
# 세션 열 — launch 값을 한국어로 표시하고, ok 가 아니면 다음 행동 줄을 붙인다.
# ---------------------------------------------------------------------------
# 표시 문구는 `session_launch.sh` 의 `task_launch_label` **한 곳**에서만 만듭니다 (F8).
# 여기에 case 문을 다시 두면 세션 시작 요약과 다시 갈라집니다 — 실제로 갈라졌던 자리입니다.
_tl_launch_label() {  # <launch-raw>
  task_launch_label "${1-}"
}

# **`unknown` 에 기동 명령을 권하지 않는다** (final diff review F1). unknown 은 "세션이
# 없다" 가 아니라 "확인되지 않았다" 이므로, 곧바로 `cd ... && claude` 를 권하면 살아 있는
# 세션 위에 두 번째 세션을 띄우게 된다. 확인·해소·인계 전달을 함께 하는 같은 복구 경로
# (`rd task resolve-launch`)로 연결한다 — 그 명령이 살아 있으면 ok 로 확정하고 인계를
# 전달하며, 죽었으면 failed 로 확정하고 그때 수동 기동 명령을 제시한다.
_tl_launch_action() {  # <slug> <launch-raw> <wt>
  local slug="$1" launch="$2" wt="$3"
  case "$launch" in
    ok) printf '' ;;
    launching|unknown|"")
      printf '→ 확인: rd task resolve-launch %s\n' "$slug" ;;
    failed|none|*)
      if [[ -n "$wt" ]]; then
        printf '→ %s\n' "$(session_launch_command "$wt" "$slug")"
      else
        printf '→ 확인: rd task resolve-launch %s\n' "$slug"
      fi
      ;;
  esac
}

# 발행 큐 요약 (change spec D9) — 큐 디렉터리가 없거나 대기 요청이 없으면 줄을 내지 않는다.
# publish_queue.sh 는 하위 셸에서만 source 한다 (이 스크립트의 셸 옵션·함수를 건드리지 않기 위함).
_tl_queue_summary() {
  local shared
  shared="$(git -C "$project_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [[ -d "${shared}/rd-workflow/publish-queue" ]] || return 0
  (
    set +e +u
    source "$SCRIPT_DIR/publish_queue.sh" >/dev/null 2>&1 || exit 0
    n=0
    for f in "$(pq_dir)"/*.req; do
      [[ -f "$f" ]] || continue
      st="$(_pq_state_of "$(basename "$f" .req)" 2>/dev/null)" || continue
      case "$st" in requested|user-approval) n=$((n+1)) ;; esac
    done
    (( n > 0 )) || exit 0
    active="$(pq_slot_get)"
    printf '\n발행 큐: 요청 %d · 허가 %s\n' "$n" "${active:-없음}"
  ) || true
}

# ---------------------------------------------------------------------------
# 본문 출력
# ---------------------------------------------------------------------------
SLUGS="$(tasks_index_all_slugs 2>/dev/null)" || SLUGS=""

MAIN_ROWS=""
PUBLISH_ROWS=""
ANY=0

while IFS= read -r slug; do
  [[ -z "$slug" ]] && continue
  _tl_load_row "$slug" || :
  fr_ref="$TL_FR_BRANCH"
  [[ -z "$fr_ref" ]] && fr_ref="fr/${slug}"

  # 색인에 남아 있지만 fr ref 가 실제로 없는(예: fabricated cleanup-pending fixture) 행은
  # "정리 대기" 로 남겨둔 채 별도 구역에 그대로 보여준다 — 삭제하지 않는다.
  state_field="$TL_STATE"
  if [[ "$state_field" == "cleanup-pending" ]]; then
    ANY=1
    PUBLISH_ROWS="${PUBLISH_ROWS}${slug}	정리 대기 (기록)	-	-\n"
    continue
  fi

  if ! fr_tip="$(git rev-parse --verify --quiet "refs/heads/${fr_ref}" 2>/dev/null)"; then
    continue
  fi
  ANY=1

  checkout="$TL_CHECKOUT"
  wt="$TL_WORKTREE"
  if [[ "$checkout" == "yes" && -n "$wt" && -d "$wt" ]]; then
    checked_out="yes"
  else
    checked_out="no"
  fi

  evidence="$(_tl_publish_evidence "$slug" "$fr_tip")"

  if [[ "$evidence" == "needs-verify" ]]; then
    PUBLISH_ROWS="${PUBLISH_ROWS}${slug}	⚠ 발행 확인 필요	확인: bash rd-workflow/scripts/lifecycle/archive.sh --dry-run	-\n"
    continue
  elif [[ "$evidence" == "cleanup-pending" ]]; then
    PUBLISH_ROWS="${PUBLISH_ROWS}${slug}	정리 대기	git worktree remove ${wt:-<worktree>}	-\n"
    continue
  fi

  # in-progress — 메인 표
  stage="$(_tl_read_status "$checked_out" "$wt" "$fr_ref")"

  if [[ "$checked_out" == "yes" ]]; then
    wt_col="$wt"
  else
    wt_col="(worktree 없음)"
  fi

  launch_raw="$TL_LAUNCH"

  behind="-"
  if [[ -n "$DEFAULT_BRANCH" ]]; then
    cnt="$(git rev-list --count "${fr_ref}..${DEFAULT_BRANCH}" 2>/dev/null)" || cnt=""
    if [[ -n "$cnt" && "$cnt" =~ ^[0-9]+$ && "$cnt" -ge "$THRESHOLD" ]]; then
      behind="⚠ ${cnt}커밋"
    fi
  fi

  launch_label="$(_tl_launch_label "$launch_raw")"
  action_wt=""
  [[ "$checked_out" == "yes" ]] && action_wt="$wt"
  # 빈 값을 `none` 으로 바꾸지 않는다 — 표시(label)가 이미 빈 값을 "확인 필요"(unknown)로
  # 다루므로, 행동만 `none`(수동 기동 권유)으로 갈리면 같은 행이 서로 다른 말을 한다.
  action="$(_tl_launch_action "$slug" "$launch_raw" "$action_wt")"

  # 세션 이름은 32자에서 잘린다. 잘린 slug 의 행에만 실제 이름을 보여 호출 세션이 그 이름으로
  # 세션을 부르게 한다. 이름은 slug 에서 계산한 값이다(herdr·hc 를 호출하지 않는다). 문구는 색인에
  # 기록된 기동 백엔드의 명령을 짚는다 — hc 는 `hc get·attach`, 그 밖(빈 값 포함)은 herdr.
  name_action=""
  agent_name="$(session_agent_name "$slug")"
  if [[ "$agent_name" != "$slug" ]]; then
    case "$launch_raw" in
      ok|unknown|launching|"")
        if [[ "$TL_LAUNCH_BACKEND" == "hc" ]]; then
          name_action="→ hc 세션 이름: ${agent_name}"
        else
          name_action="→ herdr 이름: ${agent_name}"
        fi ;;
    esac
  fi

  cleanup_action=""
  if [[ "$checked_out" != "yes" ]]; then
    cleanup_action="→ 정리: git worktree prune"
  fi

  MAIN_ROWS="${MAIN_ROWS}${slug}	${stage}	${wt_col}	${launch_label}	${behind}\n"
  if [[ -n "$action" ]]; then
    MAIN_ROWS="${MAIN_ROWS}	 	 	${action}	\n"
  fi
  if [[ -n "$name_action" ]]; then
    MAIN_ROWS="${MAIN_ROWS}	 	 	${name_action}	\n"
  fi
  if [[ -n "$cleanup_action" ]]; then
    MAIN_ROWS="${MAIN_ROWS}	 	 	${cleanup_action}	\n"
  fi
done <<< "$SLUGS"

if [[ "$ANY" -eq 0 ]]; then
  printf '진행 중인 작업이 없습니다.\n'
  [[ -n "$PRUNED_NOTE" ]] && printf '%s\n' "$PRUNED_NOTE"
  [[ -n "$SWEEP_NOTES" ]] && printf '%s' "$SWEEP_NOTES"
  _tl_queue_summary
  exit 0
fi

if [[ -n "$MAIN_ROWS" ]]; then
  printf '작업\t단계\tworktree\t세션\t뒤처짐\n'
  printf '%b' "$MAIN_ROWS" | column -t -s $'\t' 2>/dev/null || printf '%b' "$MAIN_ROWS"
fi

if [[ -n "$PUBLISH_ROWS" ]]; then
  printf '\n정리 대기 / 발행 확인 필요 (재기동 대상이 아닙니다)\n'
  printf '작업\t상태\t다음 행동\t-\n'
  printf '%b' "$PUBLISH_ROWS" | column -t -s $'\t' 2>/dev/null || printf '%b' "$PUBLISH_ROWS"
fi

if [[ -n "$PRUNED_NOTE" ]]; then
  printf '\n%s\n' "$PRUNED_NOTE"
fi

if [[ -n "$SWEEP_NOTES" ]]; then
  printf '\n%s' "$SWEEP_NOTES"
fi

_tl_queue_summary
