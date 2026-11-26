#!/usr/bin/env bash
# direct_pr.sh — 직접 설치 PR 발행(archive_publish=pr)의 `rd pr` 명령. team_publish.sh 의 open·check 앞머리가
#   직접 설치 작업이면 이 파일로 넘기고(exec), reopen 은 이 파일로만 옵니다.
#   open   [--task <slug>]                PR 단계(P2·P5·P9·P10)만 다시 합니다. 커밋·push 는 하지 않습니다.
#   check  [--task <slug>] [--apply]      PR 상태와 다음 행동을 보입니다. --apply 는 merge 를 확인한 뒤 태그·정리 대기 기록·원격 fr 브랜치 삭제를 합니다.
#   reopen [--task <slug>]                수정 요청·충돌 때 작업을 구현 중으로 되돌립니다(PR 은 그대로 둡니다).
#   sync   [--task <slug>]                기록 파일만 충돌한 PR 에 기본 브랜치를 병합해 push 합니다(change spec 2026-11-19-1430 D5).
#   Spec: rd-workflow-workspace/specs/changes/2026-11-17-1710-direct-install-publish-via-pull-request-change-spec.md (D6·D7·D8·D9·D11)
#
# 종료 코드: 성공 0, 실패 1, 대상 아님·전제 불충족·판정 불가 2. 안내·원인·재시도 명령은 stdout(오류 원인은 stderr 도 씀).
# 승인: 이 명령들은 이미 승인받은 발행의 이어 하기·사후 기록이라 publish_approval 을 묻지 않습니다(spec D6·D12).
#
# bash 3.2 호환: 연관 배열·${var,,} 를 쓰지 않고, 같은 local 문 안에서 앞 변수를 참조하지 않는다.
set -uo pipefail

_DP_LC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DP_SD="$(cd "${_DP_LC_DIR}/.." && pwd)"
if [[ -z "${project_root:-}" ]]; then
  project_root="$(cd "${_DP_SD}/../.." && pwd)"
fi
export project_root

# team_publish.sh 는 BASH_SOURCE 가드가 있어 source 해도 명령을 실행하지 않습니다(공용 함수·상수를 싣습니다).
source "${_DP_LC_DIR}/team_publish.sh" || exit 2
source "${_DP_LC_DIR}/_direct_pr_common.sh" || exit 2

_dp_usage() {
  cat <<'EOF'
사용법: bash rd-workflow/scripts/rd pr <subcommand> [--task <slug>]   (직접 설치 PR 방식 archive_publish=pr 작업)
  open   [--task <slug>]            PR 생성에 실패했거나 본문 갱신이 필요할 때 PR 단계만 다시 합니다. 정리 커밋·push 는 하지 않습니다.
  check  [--task <slug>] [--apply]  PR 상태(검토 중·수정 요청·충돌·닫힘·merge 됨)와 다음 행동을 보입니다.
                                    --apply 는 merge 를 확인한 뒤 merge 커밋에 태그를 달고 정리 대기로 넘깁니다.
  reopen [--task <slug>]            수정 요청·충돌을 반영하려고 작업을 구현 중으로 되돌립니다.
  sync [--task <slug>]  기록 파일만 충돌한 PR 에 기본 브랜치를 병합합니다(직접 설치 PR, archive_publish=pr 작업 전용)
  종료 코드: 0 성공 / 1 실패 / 2 대상 아님·전제 불충족·판정 불가
EOF
}

_DP_RETRY_CHECK=""

# _dp_fail <rc> <첫 줄> [추가 줄...] — 첫 줄과 추가 줄을 stdout 에 내고 rc 를 돌려줍니다.
_dp_fail() {
  local rc="$1" l
  shift
  for l in "$@"; do printf '%s\n' "$l"; done
  return "$rc"
}

# _dp_parse <sub> <허용 플래그: apply|-> [인자...] — 전역 _DP_TASK·_DP_APPLY 를 채웁니다. 사용법 오류 rc 2.
_DP_TASK=""; _DP_APPLY=0
_dp_parse() {
  local sub="$1" allow="$2" a
  shift 2
  _DP_TASK=""; _DP_APPLY=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task) [[ $# -ge 2 && -n "$2" ]] || { _dp_usage >&2; return 2; }; _DP_TASK="$2"; shift ;;
      --apply) if [[ "$allow" == apply ]]; then _DP_APPLY=1; else printf 'rd pr %s: 알 수 없는 인자: %s\n' "$sub" "$1" >&2; _dp_usage >&2; return 2; fi ;;
      -h|--help) _dp_usage; return 3 ;;
      *) printf 'rd pr %s: 알 수 없는 인자: %s\n' "$sub" "$1" >&2; _dp_usage >&2; return 2 ;;
    esac
    shift
  done
  return 0
}

# _dp_target — 대상 작업을 확정합니다. 전역 SLUG·FR·WT·ROOT 를 채웁니다. 직접 설치 대상이 아니면 rc 2.
SLUG=""; FR=""; WT=""; ROOT=""
_dp_target() {
  ROOT="$project_root"
  SLUG="$(dpr_is_direct_task "$_DP_TASK")" || {
    printf 'rd pr: 직접 설치 PR 방식(archive_publish=pr) 작업이 아닙니다%s\n' "${_DP_TASK:+ (작업: $_DP_TASK)}"
    printf '  작업 폴더의 브랜치가 fr/<slug> 이거나 --task <slug> 를 붙여야 합니다.\n'
    return 2; }
  FR="$(dpr_fr_branch "$SLUG")"
  WT="$(_dpr_fr_worktree "$FR")" && WT="${WT%/}" || WT=""
  _DP_RETRY_CHECK="bash rd-workflow/scripts/rd pr check --task $SLUG --apply"
  return 0
}

# _dp_pr_view <url> — gh pr view 결과를 `state|merge-oid|head-oid|base|mergeable|review|url` 한 줄로.
# 조회 실패는 rc 1 이고 stdout 에 gh 오류 첫 줄.
_dp_pr_view() {
  local url="$1" lim="${RD_PR_CHECK_TIMEOUT:-15}" out errf rc=0 msg
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dpv.XXXXXX")" || { printf '임시 파일을 만들 수 없습니다\n'; return 1; }
  out="$(tp_gh "$lim" pr view "$url" --json state,mergeCommit,headRefOid,baseRefName,mergeable,reviewDecision,url 2>"$errf")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    case "$rc" in
      124) msg="gh 조회가 ${lim}초 안에 끝나지 않았습니다 (시간 초과)" ;;
      127) msg="gh 를 찾을 수 없습니다" ;;
      *)   msg="$(head -1 "$errf" | tr '\t\r' '  ')"; [[ -n "$msg" ]] || msg="gh 가 종료 코드 ${rc} 로 실패했습니다" ;;
    esac
    rm -f "$errf"
    printf '%s\n' "$msg"
    return 1
  fi
  rm -f "$errf"
  printf '%s' "$out" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
    assert isinstance(d, dict)
except Exception:
    print("gh 응답을 해석할 수 없습니다"); sys.exit(1)
mc = d.get("mergeCommit") or {}
mo = mc.get("oid", "") if isinstance(mc, dict) else ""
def c(v):
    return str(v or "").replace("\t", " ").replace("\n", " ")
print("|".join([c(d.get("state")), c(mo), c(d.get("headRefOid")), c(d.get("baseRefName")),
                 c(d.get("mergeable")), c(d.get("reviewDecision")), c(d.get("url"))]))
'
}

# _dp_class <state> <mergeable> <review> — MERGED|CLOSED|CHANGES_REQUESTED|CONFLICTING|OPEN
_dp_class() {
  case "$1" in
    MERGED) printf 'MERGED\n' ;;
    CLOSED) printf 'CLOSED\n' ;;
    *)
      if [[ "$3" == CHANGES_REQUESTED ]]; then printf 'CHANGES_REQUESTED\n'
      elif [[ "$2" == CONFLICTING ]]; then printf 'CONFLICTING\n'
      else printf 'OPEN\n'; fi ;;
  esac
}

_dp_conflict_guide() { dpr_conflict_guide "$@"; }

# _dp_conflict_hint <slug> <fr> <기본 브랜치> <PR headRefOid> <PR baseRefName> — 충돌 PR 이 기록 파일만 충돌하는지 판정합니다
# (change spec 2026-11-19-1430 D6). 커밋·push 하지 않고, 원격 추적 ref 만 갱신합니다.
#   rc 0 기록 파일만 충돌(rd pr sync 안내를 냄) / rc 1 종전 순서를 낼 것(사유 줄을 냈을 수 있음) / rc 2 PR head 반영 지연(안내만 냄).
_dp_conflict_hint() {
  local slug="$1" fr="$2" def="$3" head="$4" base="$5" h err rt out rc errf
  if [[ "$base" != "$def" ]]; then
    printf '  PR 의 대상 브랜치가 %s 입니다 (기본 브랜치: %s)\n' "$base" "$def"; return 1
  fi
  h="$(dpr_index_get "$slug" pr-head 2>/dev/null)" || h=""
  if [[ -z "$head" ]] || { [[ "$head" != "$h" ]] && ! dpr_verified_has "$slug" "$head"; }; then
    printf '  PR head 가 rd 가 발행한 head 가 아닙니다 (%s)\n' "${head:-알 수 없음}"; return 1
  fi
  printf '  origin 에서 %s 와 %s 를 가져와 기록 파일만 충돌하는지 확인합니다\n' "$def" "$fr"
  err="$(_dp_fetch_branches "$fr" "$def")" || {
    printf '  원격 브랜치를 가져오지 못해 자동 병합을 판정하지 못했습니다: %s\n' "$err"; return 1; }
  rt="$(git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/${fr}^{commit}" 2>/dev/null)" || rt=""
  if [[ "$rt" != "$head" ]]; then
    printf '  PR head 가 원격 fr 브랜치와 다릅니다 — GitHub 이 push 를 아직 반영하지 않았을 수 있습니다. 잠시 뒤 bash rd-workflow/scripts/rd pr check --task %s 를 다시 실행하십시오\n' "$slug"
    return 2
  fi
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dpch.XXXXXX")" || return 1
  rc=0; out="$(dpr_sync_tree "$ROOT" "$head" "refs/remotes/origin/${def}" 2>"$errf")" || rc=$?
  case "$rc" in
    0) rm -f "$errf"
       printf '  기록 파일만 충돌합니다 — bash rd-workflow/scripts/rd pr sync --task %s\n' "$slug"; return 0 ;;
    1) rm -f "$errf"; return 1 ;;
    *) printf '  자동 병합을 대조할 수 없습니다: %s\n' "$(head -1 "$errf")"; rm -f "$errf"; return 1 ;;
  esac
}

# _dp_report <class> <url> <slug> <fr> <def> [<PR head> <PR base>] — 상태 한 줄과 다음 행동(spec D5 표·D7·D8, change spec 2026-11-19-1430 D6).
_dp_report() {
  local cls="$1" url="$2" slug="$3" fr="$4" def="$5" head="${6:-}" base="${7:-}" hrc
  case "$cls" in
    OPEN) printf 'PR 검토 중: %s\n' "$url" ;;
    CHANGES_REQUESTED)
      printf '수정 요청: %s\n' "$url"
      printf '  → bash rd-workflow/scripts/rd pr reopen --task %s\n' "$slug"
      _dp_conflict_guide "$slug" "$def" ;;
    CONFLICTING)
      printf '충돌: %s\n' "$url"
      hrc=0; _dp_conflict_hint "$slug" "$fr" "$def" "$head" "$base" || hrc=$?
      if [[ "$hrc" == 1 ]]; then
        printf '  GitHub 에서 기본 브랜치와 충돌합니다. 아래 순서로 복구합니다.\n'
        _dp_conflict_guide "$slug" "$def"
      fi ;;
    CLOSED)
      printf '닫힘: %s (merge 없이 닫혔습니다 — 완료가 아닙니다)\n' "$url"
      dpr_closed_choices "$slug" "$url" "$fr" ;;
    MERGED)
      printf 'merge 됨: %s\n' "$url"
      printf '  → bash rd-workflow/scripts/rd pr check --task %s --apply\n' "$slug" ;;
  esac
}

# ---------------------------------------------------------------------------
# open (D6)
# ---------------------------------------------------------------------------
dp_open() {
  local rc=0 tip parent def repo body errf title out
  _dp_parse open - "$@" || { rc=$?; [[ "$rc" == 3 ]] && return 0; return "$rc"; }
  _dp_target || return $?
  if [[ -z "$WT" ]]; then
    _dp_fail 2 "rd pr open: $FR 브랜치를 체크아웃한 worktree 를 찾을 수 없습니다 — 작업 worktree 를 복구한 뒤 다시 실행하십시오"; return $?
  fi
  rc=0; dpr_is_published_cleanup "$FR" "$SLUG" 2>/dev/null || rc=$?
  if [[ "$rc" != 0 ]]; then
    if [[ "$rc" == 1 ]]; then
      _dp_fail 2 "rd pr open: $FR 의 끝이 발행된 작업 상태 되돌리기 커밋이 아닙니다 — PR 을 처음 올리는 일은 발행 요청으로 합니다:" \
        "  bash rd-workflow/scripts/rd publish request"
    elif [[ -n "$_DPR_PUBLISHED_WHY" ]]; then
      _dp_fail 2 "rd pr open: $FR 의 끝이 rd 가 발행한 head 인지 판정할 수 없습니다 — 아무것도 바꾸지 않았습니다." \
        "  사유: $_DPR_PUBLISHED_WHY"
    else
      _dp_fail 2 "rd pr open: 발행 상태를 판정할 수 없습니다 ($FR 브랜치 또는 원격 조회 실패) — 원격 연결을 확인한 뒤 다시 실행하십시오"
    fi
    return $?
  fi
  command -v gh >/dev/null 2>&1 || { _dp_fail 2 "rd pr open: gh(GitHub CLI)를 찾을 수 없습니다 — 설치하고 gh auth login 을 마친 뒤 다시 실행하십시오"; return $?; }
  def="$(get_default_branch 2>/dev/null)" || { _dp_fail 2 "rd pr open: 기본 브랜치를 정할 수 없습니다 — rd-workflow/config/workflow.json 에 default_branch 를 설정하십시오"; return $?; }
  repo="$(dpr_origin_repo)" || { _dp_fail 2 "rd pr open: origin 저장소 이름을 알 수 없습니다"; return $?; }
  tip="$(git -C "$ROOT" rev-parse --verify -q "refs/heads/${FR}^{commit}")" || { _dp_fail 2 "rd pr open: $FR 브랜치를 읽을 수 없습니다"; return $?; }
  # fr 끝이 rd pr sync 의 병합이면 그 끝이 이미 색인 pr-head 일 때만 PR 단계를 다시 합니다. 색인 pr-head 에 sync head 를 쓰는
  # 명령은 rd pr sync 하나입니다(change spec 2026-11-19-1430 D4) — 검증되지 않은 병합을 여기서 pr-head 로 올리지 않습니다.
  if ! _dpr_cleanup_shape "$ROOT" "$tip" "$SLUG" && [[ "$tip" != "$(dpr_index_get "$SLUG" pr-head 2>/dev/null)" ]]; then
    _dp_fail 2 "rd pr open: $FR 의 끝이 rd pr sync 로 검증되지 않은 병합입니다 — bash rd-workflow/scripts/rd pr sync --task $SLUG"; return $?
  fi
  parent="$(git -C "$ROOT" rev-parse --verify -q "${_DPR_CLEANUP_OID}^")" || { _dp_fail 2 "rd pr open: 되돌리기 커밋의 부모를 읽을 수 없습니다"; return $?; }

  body="$(mktemp "${TMPDIR:-/tmp}/rd-dpob.XXXXXX")" || return 1
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dpoe.XXXXXX")" || { rm -f "$body"; return 1; }
  rc=0
  # P2 — 기존 PR 조회 (merge 됨·닫힘·대상 브랜치 다름이면 멈춤)
  if ! _dpr_p2_lookup "$SLUG" "$FR" "$def" "$repo" "$errf"; then
    rc=1
  # P5 — 제목·본문. 입력 커밋은 정리 커밋의 부모입니다(정리 커밋은 review-session·source-fr 를 비웁니다).
  elif ! out="$(dpr_pr_text "$WT" "$parent" "$body" 2>"$errf")"; then
    _dpr_fail "P5 PR 제목·본문 준비" "PR 본문을 만들 수 없습니다 — final diff review 세션의 Author 턴에 '## PR 본문' 절이 있어야 합니다" \
      "bash rd-workflow/scripts/rd pr open --task $SLUG" "$(grep -v '^rd pr: WARNING' "$errf" | head -2 | tr '\n' ' ')" || true
    rc=1
  else
    grep '^rd pr: WARNING' "$errf" >&2 || true
    title="$out"
    dpr_index_set "$SLUG" "pr-mode=direct" "pr-head=${tip}" "pr-base=${def}" \
      || printf 'archive: WARNING — 작업 색인에 PR 발행 정보를 쓰지 못했습니다(pr-head)\n' >&2
    # P9·P10
    _dpr_pr_submit "$SLUG" "$FR" "$def" "$repo" "$title" "$body" "$errf" "$_DPR_OPEN_URL" "$tip" || rc=1
  fi
  rm -f "$body" "$errf"
  return "$rc"
}

# ---------------------------------------------------------------------------
# check (D7)
# ---------------------------------------------------------------------------
dp_check() {
  local rc=0 url line state mo head base mergeable review vurl cls def apply
  _dp_parse check apply "$@" || { rc=$?; [[ "$rc" == 3 ]] && return 0; return "$rc"; }
  apply="$_DP_APPLY"
  _dp_target || return $?
  url="$(dpr_index_get "$SLUG" pr-url 2>/dev/null)" || url=""
  if [[ -z "$url" ]]; then
    _dp_fail 2 "PR 이 기록되지 않았습니다 — 먼저 PR 을 올립니다:" "  bash rd-workflow/scripts/rd pr open --task $SLUG"; return $?
  fi
  command -v gh >/dev/null 2>&1 || { _dp_fail 1 "rd pr check: gh(GitHub CLI)를 찾을 수 없습니다"; return $?; }
  def="$(get_default_branch 2>/dev/null)" || { _dp_fail 2 "rd pr check: 기본 브랜치를 정할 수 없습니다 — rd-workflow/config/workflow.json 에 default_branch 를 설정하십시오"; return $?; }
  rc=0; line="$(_dp_pr_view "$url")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    _dp_fail 1 "PR 상태 조회 실패: $line" "  다시 실행: bash rd-workflow/scripts/rd pr check --task $SLUG"; return $?
  fi
  IFS='|' read -r state mo head base mergeable review vurl <<EOF_DPC
$line
EOF_DPC
  cls="$(_dp_class "$state" "$mergeable" "$review")"
  _dp_report "$cls" "$url" "$SLUG" "$FR" "$def" "$head" "$base"
  [[ "$apply" == 1 ]] || return 0
  if [[ "$cls" != MERGED ]]; then
    printf 'PR 이 merge 되지 않았습니다 (상태: %s) — 완료로 처리하지 않습니다.\n' "${state:-알 수 없음}"
    return 1
  fi
  _dp_apply "$url" "$mo" "$head" "$base" "$vurl" "$def"
}

# _dp_apply <index pr-url> <merge-oid> <headRefOid> <baseRefName> <gh url> <기본 브랜치> — 조건 2~4 검사 뒤 태그·색인·원격 fr 삭제(spec D7).
_dp_apply() {
  local url="$1" mo="$2" head="$3" base="$4" vurl="$5" def="$6"
  local prhead tip orepo prepo tag tag_oid tag_commit ts msg out rc rl peeled err

  # 최신 원격 기본 브랜치 — sync·check 와 같이 --no-tags 명시 refspec 으로만 가져옵니다(change spec 2026-11-19-1430 D5 3단계).
  if ! err="$(_dp_fetch_branches "$def")"; then
    _dp_fail 1 "origin/$def 를 가져오지 못했습니다: $err" "  재시도: $_DP_RETRY_CHECK"; return $?
  fi

  # 조건 2 — merge 대상과 저장소
  if [[ "$base" != "$def" ]]; then
    _dp_fail 1 "PR 이 $base 로 merge 됐습니다. 기본 브랜치($def)에 들어가지 않아 완료로 보지 않습니다." \
      "  기본 브랜치로 옮기는 새 PR 은 사람이 만듭니다. 이 작업은 태그 없이 남습니다."; return $?
  fi
  orepo="$(dpr_origin_repo)" || orepo=""
  prepo="${vurl#*://}"; prepo="${prepo#*/}"; prepo="${prepo%%/pull/*}"
  if [[ -z "$orepo" || "$(printf '%s' "$prepo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$orepo" | tr '[:upper:]' '[:lower:]')" ]]; then
    _dp_fail 1 "PR 저장소 ${prepo:-알 수 없음} 가 origin ${orepo:-알 수 없음} 와 다릅니다. 완료로 보지 않습니다." \
      "  이 작업은 태그 없이 남습니다."; return $?
  fi

  # 조건 3 — merge 시점 head 가 rd 가 push 한 커밋과 같은가
  prhead="$(dpr_index_get "$SLUG" pr-head 2>/dev/null)" || prhead=""
  # 빈 색인 채움은 fr 끝이 단일 되돌리기 커밋일 때만 합니다. sync 병합 끝은 rd pr sync 가 기록한 pr-head·pr-verified 로만 받아들입니다.
  if [[ -z "$prhead" ]]; then
    tip="$(git -C "$ROOT" rev-parse --verify -q "refs/heads/${FR}^{commit}" 2>/dev/null)" || tip=""
    if [[ -n "$tip" ]] && _dpr_cleanup_shape "$ROOT" "$tip" "$SLUG" && dpr_is_published_cleanup "$FR" "$SLUG" 2>/dev/null; then
      prhead="$tip"
    fi
  fi
  if [[ -z "$prhead" ]]; then
    _dp_fail 1 "rd 가 push 한 커밋(pr-head)을 알 수 없어 리뷰한 커밋인지 확인할 수 없습니다. 완료로 보지 않습니다." \
      "  이 작업은 태그 없이 남습니다. 폐기하려면 닫힘 선택지의 작업 폐기 순서를 따르십시오."; return $?
  fi
  # merge 시점 PR head 가 pr-head 이거나 rd pr sync 가 검증한 head(pr-verified)여야 합니다. 마감 시점에는 사슬을 다시 판정하지 않습니다 —
  # merge 뒤에는 PR head 의 부모가 모두 기본 브랜치 이력에 들어와 조상 판정이 출처를 증명하지 못합니다(spec D4).
  # 통과한 뒤의 태그 메시지·원격 fr 삭제 lease·수동 안내는 실제 merge 시점 PR head 를 씁니다.
  if [[ "$head" != "$prhead" ]] && ! dpr_verified_has "$SLUG" "$head"; then
    _dp_fail 1 "리뷰한 커밋 뒤에 커밋이 더해진 채 merge 됐습니다 (${prhead} → ${head:-알 수 없음})." \
      "  더해진 커밋은 새 작업으로 리뷰합니다. 이 작업은 태그 없이 남고 정리되지 않습니다." \
      "  폐기하려면: Claude 세션에서 /fr status $SLUG dropped 로 닫은 뒤 터미널에서 아래 줄을 실행합니다" \
      "    $(dpr_rollback_cmd "$SLUG" "$ROOT")"; return $?
  fi

  # 조건 4 — 태그를 달 커밋이 origin/<기본 브랜치> 에 들어 있는가
  if [[ -z "$mo" ]] || ! git -C "$ROOT" merge-base --is-ancestor "$mo" "refs/remotes/origin/${def}" 2>/dev/null; then
    _dp_fail 1 "merge 커밋(${mo:-없음})이 아직 원격 기본 브랜치(origin/$def)에 없습니다. 잠시 뒤 다시 실행하십시오." \
      "  재시도: $_DP_RETRY_CHECK"; return $?
  fi

  # 태그 — 이미 이 merge 커밋을 가리키는 slug 태그가 있으면 재사용
  tag="$(git -C "$ROOT" tag --list "fr/*/$SLUG" --points-at "$mo" 2>/dev/null | head -1)"
  if [[ -z "$tag" ]]; then
    ts="$(date +%Y-%m-%d-%H%M)"
    tag="$(cd "$ROOT" && resolve_unique_ref tag "fr/$ts/$SLUG")" || {
      _dp_fail 1 "태그 이름을 정하지 못했습니다 (fr/$ts/$SLUG)"; return $?; }
    msg="$(printf 'archive: %s @ %s\npr: %s\npr-head: %s' "$SLUG" "$(date +"%Y-%m-%d %H:%M")" "$url" "$head")"
    if ! out="$(git -C "$ROOT" tag -a "$tag" "$mo" -m "$msg" 2>&1)"; then
      _dp_fail 1 "태그 $tag 를 만들지 못했습니다: $(printf '%s' "$out" | head -1)" "  재시도: $_DP_RETRY_CHECK"; return $?
    fi
    printf '태그 %s 부착 (merge 커밋 %s)\n' "$tag" "$mo"
  else
    printf '태그 %s 이미 merge 커밋을 가리킵니다 — 재사용\n' "$tag"
  fi
  tag_oid="$(git -C "$ROOT" rev-parse --verify -q "refs/tags/$tag")" || { _dp_fail 1 "태그 $tag 의 OID 를 읽지 못했습니다"; return $?; }
  tag_commit="$(git -C "$ROOT" rev-parse --verify -q "${tag_oid}^{commit}")" || tag_commit=""
  if [[ "$tag_commit" != "$mo" ]]; then
    _dp_fail 1 "태그 $tag 가 merge 커밋이 아닌 커밋을 가리킵니다 — 확인한 뒤 다시 실행하십시오" "  재시도: $_DP_RETRY_CHECK"; return $?
  fi

  # 태그 OID 를 push 하고 원격에서 확인 — 확인되기 전에는 색인을 바꾸지 않습니다
  # push.followTags 설정이 있어도 다른 로컬 태그를 함께 보내지 않습니다(발행 태그 하나만).
  rc=0; out="$(git -C "$ROOT" push --no-follow-tags origin "${tag_oid}:refs/tags/${tag}" 2>&1)" || rc=$?
  if [[ "$rc" != 0 ]]; then
    _dp_fail 1 "태그 push 실패 — 색인은 바꾸지 않았습니다." "$(printf '%s\n' "$out" | head -6 | sed 's/^/  git: /')" "  재시도: $_DP_RETRY_CHECK (로컬 태그를 재사용합니다)"; return $?
  fi
  rl="$(git -C "$ROOT" ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)" || rl=""
  peeled="$(printf '%s\n' "$rl" | awk -v t="refs/tags/${tag}^{}" '$2==t{print $1; exit}')"
  [[ -n "$peeled" ]] || peeled="$(printf '%s\n' "$rl" | awk -v t="refs/tags/${tag}" '$2==t{print $1; exit}')"
  if [[ "$peeled" != "$mo" ]]; then
    _dp_fail 1 "원격 태그 $tag 가 merge 커밋을 가리키는지 확인하지 못했습니다 (원격: ${peeled:-없음}) — 색인은 바꾸지 않았습니다." "  재시도: $_DP_RETRY_CHECK"; return $?
  fi

  # 확인된 뒤에만 정리 대기로 기록
  if ! dpr_index_set "$SLUG" "state=cleanup-pending" "published-at=$(date -u '+%Y-%m-%d-%H%M')" "publish-tag=${tag}"; then
    _dp_fail 1 "작업 색인에 정리 대기(state=cleanup-pending)를 기록하지 못해 마감하지 않았습니다. 태그 ${tag} 는 원격에 올라가 있습니다." \
      "  원격 fr 브랜치는 지우지 않았습니다." "  재시도: $_DP_RETRY_CHECK (태그를 재사용합니다)"; return $?
  fi

  # 원격 fr 브랜치 삭제 — merge 된 head 일 때만(lease). 이미 없으면 건너뜁니다. 다른 값이면 지우지 않습니다. 실패해도 완료에는 영향 없습니다.
  rl="$(git -C "$ROOT" ls-remote origin "refs/heads/${FR}" 2>/dev/null)" || rl=""
  rl="${rl%%[[:space:]]*}"
  if [[ -n "$rl" && "$rl" != "$head" ]]; then
    printf '원격 fr 브랜치가 merge 된 head 와 달라 지우지 않았습니다 (원격: %s, merge 된 head: %s). 확인:\n' "$rl" "$head"
    printf '  git fetch --no-tags origin +refs/heads/%s:refs/remotes/origin/%s && git log %s..origin/%s\n' "$FR" "$FR" "$head" "$FR"
  elif [[ -n "$rl" ]]; then
    # 삭제 push 에도 설정이 태그를 얹으므로 같은 옵션을 씁니다(위 태그 push 주석).
    rc=0; out="$(git -C "$ROOT" push --no-follow-tags "--force-with-lease=refs/heads/${FR}:${head}" origin ":refs/heads/${FR}" 2>&1)" || rc=$?
    if [[ "$rc" != 0 ]]; then
      printf 'WARNING — 원격 fr 브랜치 %s 를 지우지 못했습니다(완료에는 영향 없음). 직접 지우려면:\n' "$FR"
      printf '  git push --no-follow-tags --force-with-lease=refs/heads/%s:%s origin :refs/heads/%s\n' "$FR" "$head" "$FR"
    else
      printf '원격 fr 브랜치 %s 삭제\n' "$FR"
    fi
  else
    printf '원격 fr 브랜치 %s 는 이미 없습니다 — 건너뜁니다\n' "$FR"
  fi
  printf '기본 체크아웃의 로컬 %s 는 갱신하지 않았습니다 — 필요하면 그 체크아웃에서 git pull --ff-only\n' "$def"
  dpr_closed_cleanup_guide "$ROOT" "$FR" "$head" "$def" '마감됨 — '
  return 0
}

# ---------------------------------------------------------------------------
# reopen (D9)
# ---------------------------------------------------------------------------
dp_reopen() {
  local rc=0 tip parent url line state mo head base mergeable review vurl def paths p n0 sha ssf cmf
  _dp_parse reopen - "$@" || { rc=$?; [[ "$rc" == 3 ]] && return 0; return "$rc"; }
  _dp_target || {
    printf '  overlay 작업은 rd task set-status "구현 중" 으로 수정합니다.\n'; return 2; }
  if [[ -z "$WT" ]]; then
    _dp_fail 2 "rd pr reopen: $FR 브랜치를 체크아웃한 worktree 를 찾을 수 없습니다"; return $?
  fi
  rc=0; dpr_is_published_cleanup "$FR" "$SLUG" 2>/dev/null || rc=$?
  if [[ "$rc" == 2 && -n "$_DPR_PUBLISHED_WHY" ]]; then
    _dp_fail 2 "rd pr reopen: $FR 의 끝이 rd 가 발행한 head 인지 판정할 수 없습니다 — 아무것도 바꾸지 않았습니다." \
      "  사유: $_DPR_PUBLISHED_WHY"; return $?
  elif [[ "$rc" != 0 ]]; then
    _dp_fail 2 "rd pr reopen: $FR 의 끝이 발행된 작업 상태 되돌리기 커밋이 아닙니다 — PR 을 기다리는 상태에서만 수정을 재개합니다." \
      "  이미 구현 중이면 그대로 작업하십시오. 아직 발행 전이면 rd publish request 로 발행하십시오."; return $?
  fi
  tip="$(git -C "$ROOT" rev-parse --verify -q "refs/heads/${FR}^{commit}")" || { _dp_fail 2 "rd pr reopen: $FR 브랜치를 읽을 수 없습니다"; return $?; }
  if [[ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" != "$tip" || -n "$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
    _dp_fail 1 "rd pr reopen: 작업 worktree($WT)에 미커밋 변경이 있거나 HEAD 가 $FR 의 끝과 다릅니다 — 정리한 뒤 다시 실행하십시오"; return $?
  fi
  url="$(dpr_index_get "$SLUG" pr-url 2>/dev/null)" || url=""
  if [[ -z "$url" ]]; then
    _dp_fail 2 "PR 이 기록되지 않았습니다 — 먼저 PR 을 올립니다:" "  bash rd-workflow/scripts/rd pr open --task $SLUG"; return $?
  fi
  command -v gh >/dev/null 2>&1 || { _dp_fail 1 "rd pr reopen: gh(GitHub CLI)를 찾을 수 없습니다"; return $?; }
  rc=0; line="$(_dp_pr_view "$url")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    _dp_fail 1 "rd pr reopen: PR 상태 조회 실패로 멈춥니다: $line" "  다시 실행: bash rd-workflow/scripts/rd pr reopen --task $SLUG"; return $?
  fi
  IFS='|' read -r state mo head base mergeable review vurl <<EOF_DPR
$line
EOF_DPR
  if [[ "$state" == MERGED ]]; then
    _dp_fail 1 "rd pr reopen: PR 이 이미 merge 됐습니다 ($url) — 수정을 재개하지 않습니다." "  마감하려면: bash rd-workflow/scripts/rd pr check --task $SLUG --apply"; return $?
  fi
  def="$(get_default_branch 2>/dev/null)" || { _dp_fail 2 "rd pr reopen: 기본 브랜치를 정할 수 없습니다 — rd-workflow/config/workflow.json 에 default_branch 를 설정하십시오"; return $?; }
  # 되돌리기 커밋은 fr 끝이 아니라 사슬 끝일 수 있습니다(rd pr sync 의 병합 아래). 상태 복원 커밋은 지금 fr 끝 위에 만듭니다.
  parent="$(git -C "$WT" rev-parse --verify -q "${_DPR_CLEANUP_OID}^")" || { _dp_fail 2 "rd pr reopen: 되돌리기 커밋의 부모를 읽을 수 없습니다"; return $?; }

  paths=( "CURRENT_TASK.md" "rd-workflow-workspace/.lifecycle/task-state" )
  # 되돌리기 커밋의 부모에서 작업 상태를 복원 → 구현 중 → 한 커밋
  n0="$(git -C "$WT" rev-list --count HEAD 2>/dev/null)"
  # 임시 파일은 작업 트리를 바꾸기 전에 만듭니다(TMPDIR 미설정이어도 /tmp 로 동작).
  ssf="$(mktemp "${TMPDIR:-/tmp}/rd-dpr-ss.XXXXXX")" || { _dp_fail 1 "rd pr reopen: 임시 파일을 만들 수 없습니다 (작업 worktree 는 그대로입니다)"; return $?; }
  cmf="$(mktemp "${TMPDIR:-/tmp}/rd-dpr-cm.XXXXXX")" || { rm -f "$ssf"; _dp_fail 1 "rd pr reopen: 임시 파일을 만들 수 없습니다 (작업 worktree 는 그대로입니다)"; return $?; }
  _dp_restore() {
    local q
    for q in "${paths[@]}" "rd-workflow-workspace/.lifecycle/stage_metrics.tsv"; do
      git -C "$WT" reset -q HEAD -- "$q" 2>/dev/null
      git -C "$WT" checkout -q HEAD -- "$q" 2>/dev/null
    done
  }
  if ! git -C "$WT" checkout -q "$parent" -- "${paths[@]}" 2>/dev/null; then
    _dp_restore; rm -f "$ssf" "$cmf"; _dp_fail 1 "rd pr reopen: 부모 커밋에서 작업 상태를 복원하지 못했습니다 (작업 worktree 는 이전 상태입니다)"; return $?
  fi
  if ! ( cd "$WT" && unset project_root TASK_STATE_PATH && bash rd-workflow/scripts/rd task set-status "구현 중" ) >"$ssf" 2>&1; then
    _dp_restore
    _dp_fail 1 "rd pr reopen: Status 를 구현 중으로 바꾸지 못했습니다 (작업 worktree 는 이전 상태입니다):" "$(head -5 "$ssf" | sed 's/^/  /')"
    rc=$?; rm -f "$ssf" "$cmf"; return "$rc"
  fi
  rm -f "$ssf"
  [[ -e "$WT/rd-workflow-workspace/.lifecycle/stage_metrics.tsv" ]] && paths+=( "rd-workflow-workspace/.lifecycle/stage_metrics.tsv" )
  if ! ( cd "$WT" && git add -- "${paths[@]}" && git commit -q -m "chore(lifecycle): ${SLUG} PR 수정 재개 — 작업 상태 복원" -- "${paths[@]}" ) >"$cmf" 2>&1; then
    _dp_restore
    _dp_fail 1 "rd pr reopen: 수정 재개 커밋을 만들지 못했습니다 (작업 worktree 는 이전 상태입니다):" "$(head -5 "$cmf" | sed 's/^/  /')"
    rc=$?; rm -f "$cmf"; return "$rc"
  fi
  rm -f "$cmf"
  sha="$(git -C "$WT" rev-parse --short HEAD)"
  printf 'rd pr reopen: %s 를 구현 중으로 되돌렸습니다 (커밋 %s, PR %s 는 그대로 둡니다)\n' "$SLUG" "$sha" "$url"
  printf '이어 갈 순서:\n'
  printf '  1) 작업 worktree(%s)에서 수정·검증 — 충돌이면 git merge --no-squash %s 후 해소·커밋\n' "$(dpr_shq "$WT")" "$(dpr_shq "origin/$def")"
  printf '  2) 새 final diff review 종결 → bash rd-workflow/scripts/rd review seal → 아카이브 보류 → 기록 커밋\n'
  printf '  3) bash rd-workflow/scripts/rd publish request   (열린 PR 의 본문을 갱신하고 fast-forward 로 push 합니다)\n'
  return 0
}

# ---------------------------------------------------------------------------
# sync (change spec 2026-11-19-1430 D5)
# ---------------------------------------------------------------------------
# 기호: L 로컬 fr 끝, O 원격 fr 끝, H 색인 pr-head, S 색인 pr-sent, V 색인 pr-verified.

# _dp_fetch_branches <브랜치>... — 브랜치마다 `--no-tags` 와 명시 refspec 으로 원격 추적 ref 하나만 갱신합니다(태그를 만들지 않음).
# `--refmap=` 은 remote.origin.fetch 설정의 추가 매핑을 끕니다 — 설정이 로컬 브랜치로 매핑해도 그 ref 는 바뀌지 않습니다.
# `--no-recurse-submodules` 는 fetch.recurseSubmodules 설정이 있어도 submodule 의 ref 를 건드리지 않게 합니다.
# 실패 rc 1, git 오류 첫 줄을 stdout 에 냅니다. sync·check·외부 push 진단의 fetch 는 모두 이 함수를 지납니다.
_dp_fetch_branches() {
  local b errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dpfb.XXXXXX")" || { printf '임시 파일을 만들 수 없습니다\n'; return 1; }
  for b in "$@"; do
    if ! git -C "$ROOT" fetch -q --no-tags --refmap= --no-recurse-submodules origin "+refs/heads/${b}:refs/remotes/origin/${b}" 2>"$errf"; then
      printf '%s\n' "$(head -1 "$errf")"; rc=1; break
    fi
  done
  rm -f "$errf"
  return "$rc"
}

# _dp_wt_state <worktree> <기대 HEAD> — 작업 worktree 가 기대 HEAD 에 있고 깨끗하면 rc 0, 아니면 rc 1,
# HEAD·상태를 읽지 못하면 rc 2(git 오류 첫 줄을 stdout 에 냅니다). 읽기 실패를 깨끗한 상태로 보지 않습니다.
_dp_wt_state() {
  local wt="$1" want="$2" cur st errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-dpws.XXXXXX")" || { printf '임시 파일을 만들 수 없습니다\n'; return 2; }
  cur="$(git -C "$wt" rev-parse HEAD 2>"$errf")" || rc=2
  if [[ "$rc" == 0 ]]; then st="$(git -C "$wt" status --porcelain --untracked-files=all 2>"$errf")" || rc=2; fi
  if [[ "$rc" == 2 ]]; then printf '%s\n' "$(head -1 "$errf")"; rm -f "$errf"; return 2; fi
  rm -f "$errf"
  [[ "$cur" == "$want" && -z "$st" ]] || return 1
  return 0
}

_dp_sync_ignored_clash() { dpr_ignored_clash "$ROOT" "$WT" "$@"; }

# _dp_sync_ctx — sync 가 쓰는 전역을 채웁니다: _DPS_DEF(기본 브랜치)·_DPS_URL(색인 pr-url)·_DPS_RETRY(재시도 명령).
_DPS_DEF=""; _DPS_URL=""; _DPS_RETRY=""
_dp_sync_ctx() {
  _DPS_RETRY="bash rd-workflow/scripts/rd pr sync --task $SLUG"
  _DPS_URL="$(dpr_index_get "$SLUG" pr-url 2>/dev/null)" || _DPS_URL=""
  _DPS_DEF="$(get_default_branch 2>/dev/null)" || { _DPS_DEF=""; return 2; }
  return 0
}

# _dp_sync_remote_head — 원격 fr 끝(O)을 ls-remote 한 번으로 읽습니다. 없으면 빈 값. 조회 실패 rc 2. 4·7·8단계가 함께 씁니다.
_dp_sync_remote_head() {
  local out
  out="$(git -C "$ROOT" ls-remote origin "refs/heads/${FR}" 2>/dev/null)" || return 2
  printf '%s\n' "${out%%[[:space:]]*}"
}

# _dp_sync_on_chain <커밋> <head> — <커밋> 이 <head> 의 사슬 위(첫 부모 사슬, 같음 포함)인지. 사슬 끝 되돌리기 커밋은 dpr_published_head 로 구합니다.
_dp_sync_on_chain() {
  local c="$1" head="$2" cl
  [[ -n "$c" && -n "$head" ]] || return 1
  cl="$(dpr_published_head "$ROOT" "$head" "$SLUG" "refs/remotes/origin/${_DPS_DEF}" 2>/dev/null)" || return 1
  # 출력을 끝까지 읽는 grep 으로 판정합니다 — grep -q 가 일찍 끝나면 pipefail 아래에서 SIGPIPE 가 양성 판정을 뒤집습니다.
  git -C "$ROOT" rev-list --first-parent "$head" "^${cl}^" 2>/dev/null | grep -x -- "$c" >/dev/null
}

# _dp_sync_ahead <H> <O> — 원격 fr 이 rd 가 발행하지 않은 커밋으로 앞섰다고 알립니다(4단계 표·7단계). 원격 fr 객체를 가져온 뒤 확인 명령을 냅니다.
_dp_sync_ahead() {
  local h="$1" o="$2" err
  printf 'rd pr sync: 원격 fr 브랜치가 rd 가 발행하지 않은 커밋으로 앞서 있습니다 — 아무것도 바꾸지 않았습니다.\n'
  if err="$(_dp_fetch_branches "$FR")"; then
    printf '  확인: git log --oneline %s..%s\n' "$h" "$o"
  else
    printf '  원격 fr 을 가져오지 못했습니다: %s\n' "$err"
    printf '  확인: git fetch --no-tags origin +refs/heads/%s:refs/remotes/origin/%s && git log --oneline %s..%s\n' "$FR" "$FR" "$h" "$o"
  fi
  return 1
}

# _dp_sync_reconcile <O> <PR head> — 4단계 시작점 판정. 위 행부터 처음 맞는 행을 씁니다.
#   rc 0 정상(5단계로) / rc 4 이어 가기(8단계만) / rc 1 멈춤(안내를 냄). 전역 _DPS_L·_DPS_H·_DPS_S 를 씁니다.
_DPS_L=""; _DPS_H=""; _DPS_S=""
_dp_sync_reconcile() {
  local o="$1" prh="$2" l="$_DPS_L" h="$_DPS_H" s="$_DPS_S" err
  if [[ -z "$o" ]]; then
    printf 'rd pr sync: 원격 fr 브랜치가 없습니다 — 아무것도 바꾸지 않았습니다.\n'
    printf '  확인: bash rd-workflow/scripts/rd pr check --task %s\n' "$SLUG"
    return 1
  fi
  if [[ "$l" == "$o" && "$o" == "$h" && "$s" != "$h" ]]; then
    printf 'rd pr sync: PR 갱신이 끝나지 않았습니다 — 먼저 PR 단계를 마치십시오(색인은 바꾸지 않았습니다).\n'
    printf '  bash rd-workflow/scripts/rd pr open --task %s\n' "$SLUG"
    return 1
  fi
  if [[ "$o" != "$h" ]] && ! dpr_verified_has "$SLUG" "$o"; then
    _dp_sync_ahead "$h" "$o"; return 1
  fi
  if [[ "$l" != "$o" || "$h" != "$o" ]]; then
    # 이어 가기 후보: O ∈ V ∪ {H}. 원격 fr 객체가 없으면 가져옵니다.
    if { [[ "$o" == "$h" ]] || dpr_verified_has "$SLUG" "$o"; } && ! git -C "$ROOT" cat-file -e "${o}^{commit}" 2>/dev/null; then
      err="$(_dp_fetch_branches "$FR")" || { _dp_fail 1 "rd pr sync: 원격 fr 브랜치를 가져오지 못했습니다: $err" "  재시도: $_DPS_RETRY"; return 1; }
    fi
    if { [[ "$o" == "$h" ]] || dpr_verified_has "$SLUG" "$o"; } \
       && dpr_published_head "$ROOT" "$o" "$SLUG" "refs/remotes/origin/${_DPS_DEF}" >/dev/null 2>&1 \
       && _dp_sync_on_chain "$h" "$o" && _dp_sync_on_chain "$l" "$o"; then
      printf 'rd pr sync: 이전 sync 의 마무리가 끊겼습니다 — 이어 갑니다 (원격 fr: %s)\n' "$(git -C "$ROOT" rev-parse --short "$o")"
      return 4
    fi
  fi
  if [[ "$l" == "$o" && "$h" == "$o" && "$s" == "$o" ]]; then
    if [[ "$prh" != "$o" ]]; then
      printf 'rd pr sync: PR head(%s)가 원격 fr 브랜치(%s)와 다릅니다 — GitHub 이 push 를 아직 반영하지 않았을 수 있습니다. 잠시 뒤 bash rd-workflow/scripts/rd pr sync --task %s 를 다시 실행하십시오\n' \
        "$(git -C "$ROOT" rev-parse --short "$prh" 2>/dev/null || printf '%s' "${prh:-없음}")" "$(git -C "$ROOT" rev-parse --short "$o")" "$SLUG"
      return 1
    fi
    return 0
  fi
  printf 'rd pr sync: 로컬 fr 브랜치와 색인이 PR head 와 맞지 않습니다 — 아무것도 바꾸지 않았습니다.\n'
  printf '  로컬 fr: %s  원격 fr: %s  색인 pr-head: %s\n' "$(git -C "$ROOT" rev-parse --short "$l")" \
    "$(git -C "$ROOT" rev-parse --short "$o" 2>/dev/null || printf '%s' "$o")" "$(git -C "$ROOT" rev-parse --short "$h" 2>/dev/null || printf '%s' "$h")"
  printf '  확인: git log --oneline -3 %s origin/%s\n' "$FR" "$FR"
  return 1
}

# _dp_sync_push <후보> <H> — 원격 fr 을 후보로 옮깁니다. lease 의 예상 이전 값은 H — 원격이 지워졌거나 다른 값이면 거부됩니다.
# `--no-follow-tags` 는 push.followTags 설정이 있어도 로컬 태그를 함께 보내지 않게 합니다(원격에서 바뀌는 ref 는 fr 브랜치 하나).
# `--recurse-submodules=no` 는 push.recurseSubmodules 설정이 있어도 submodule 을 검사·push 하지 않게 합니다.
# 실패하면 git 출력 첫 줄을 전역 _DPS_PUSH_ERR 에 둡니다.
_DPS_PUSH_ERR=""
_dp_sync_push() {
  local cand="$1" h="$2" out rc=0
  out="$(git -C "$ROOT" push --no-follow-tags --recurse-submodules=no "--force-with-lease=refs/heads/${FR}:${h}" origin "${cand}:refs/heads/${FR}" 2>&1)" || rc=$?
  _DPS_PUSH_ERR="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | grep -v '^To ' | head -1)"
  return "$rc"
}

# _dp_sync_after_push_fail <후보> <H> — 7단계 push 실패 처리. 원격만 다시 조회하고(PR head 는 보지 않음) 갈래를 나눕니다.
#   rc 0 원격이 후보(8단계로) / rc 1 멈춤.
_dp_sync_after_push_fail() {
  local cand="$1" h="$2" o rc=0 line state rest
  o="$(_dp_sync_remote_head)" || rc=$?
  if [[ "$rc" != 0 ]]; then
    _dp_fail 1 "rd pr sync: push 결과를 확인하지 못했습니다 — 같은 명령을 다시 실행하면 원격과 대조합니다" "  재시도: $_DPS_RETRY"; return $?
  fi
  if [[ "$o" == "$cand" ]]; then
    printf 'rd pr sync: push 응답을 받지 못했지만 원격에 반영됐습니다\n'
    return 0
  fi
  if [[ "$o" == "$h" ]]; then
    _dp_fail 1 "rd pr sync: 병합 커밋을 만들었으나 push 하지 못했습니다 — 원격 fr 브랜치·pr-head 는 바꾸지 않았습니다." \
      "  git: ${_DPS_PUSH_ERR:-알 수 없음}" "  재시도: $_DPS_RETRY"; return $?
  fi
  if [[ -z "$o" ]]; then
    rc=0; line="$(_dp_pr_view "$_DPS_URL")" || rc=$?
    state="${line%%|*}"
    if [[ "$rc" == 0 && "$state" == MERGED ]]; then
      _dp_fail 1 "rd pr sync: PR 이 이미 merge 됐습니다 ($_DPS_URL) — 마감하려면:" "  bash rd-workflow/scripts/rd pr check --task $SLUG --apply"; return $?
    fi
    _dp_fail 1 "rd pr sync: 원격 fr 브랜치가 없습니다 — 원격·로컬 fr 브랜치와 pr-head 는 바꾸지 않았습니다(만든 병합 커밋은 검증된 head 목록에 남습니다)." "  확인: bash rd-workflow/scripts/rd pr check --task $SLUG"; return $?
  fi
  if dpr_verified_has "$SLUG" "$o"; then
    _dp_fail 1 "rd pr sync: 다른 sync 가 먼저 push 했습니다 — 같은 명령을 다시 실행하면 이어 갑니다" "  재시도: $_DPS_RETRY"; return $?
  fi
  _dp_sync_ahead "$h" "$o"
}

# _dp_sync_keep_name <후보> — 보존 브랜치 이름 rd-sync-keep/<slug>-<후보 짧은 OID>(이미 있으면 -2, -3 …).
_dp_sync_keep_name() {
  local base n=1 name
  base="rd-sync-keep/${SLUG}-$(git -C "$ROOT" rev-parse --short "$1")"
  name="$base"
  while git -C "$ROOT" rev-parse -q --verify "refs/heads/$name" >/dev/null 2>&1; do
    n=$((n + 1)); name="${base}-${n}"
  done
  printf '%s\n' "$name"
}

# _dp_sync_finish <후보> — 8단계 마무리. tasks 락 안에서 다시 확인 → 색인 pr-head·pr-sent 기록 → 작업 worktree 를 fast-forward 로 옮김.
#   rc 0 끝 / rc 1 멈춤(끝난 단계와 다음 행동을 냄). reset 을 쓰지 않습니다.
_dp_sync_finish() {
  local cand="$1" o st h l cur cn out rc=0 sc keep qw qk
  sc="$(git -C "$ROOT" rev-parse --short "$cand")"
  _dpr_index_lock "$SLUG" "pr-head·pr-sent" || {
    _dp_fail 1 "rd pr sync: 다른 lifecycle 명령이 작업 색인을 쓰고 있어 마무리하지 못했습니다 (원격 fr = $sc)" "  재시도: $_DPS_RETRY"; return $?; }
  # 다시 확인
  st="$(tasks_index_get "$SLUG" state 2>/dev/null)" || st=""
  h="$(tasks_index_get "$SLUG" pr-head 2>/dev/null)" || h=""
  rc=0; o="$(_dp_sync_remote_head)" || rc=$?
  if [[ "$rc" != 0 ]]; then
    tasks_lock_release >/dev/null 2>&1 || true
    _dp_fail 1 "rd pr sync: 마무리 전 원격 fr 브랜치를 다시 조회하지 못했습니다 (git ls-remote origin 실패) — 색인·작업 worktree 는 바꾸지 않았습니다" \
      "  재시도: $_DPS_RETRY (원격과 다시 대조합니다)"; return $?
  fi
  if [[ "$st" == cleanup-pending || "$o" != "$cand" ]] || ! _dp_sync_on_chain "$h" "$cand"; then
    tasks_lock_release >/dev/null 2>&1 || true
    _dp_fail 1 "rd pr sync: sync 도중 다른 명령이 작업 상태를 바꿨습니다 — bash rd-workflow/scripts/rd pr sync --task $SLUG 로 다시 대조하십시오"; return $?
  fi
  if ! tasks_index_upsert "$SLUG" "pr-head=$cand" "pr-sent=$cand"; then
    tasks_lock_release >/dev/null 2>&1 || true
    _dp_fail 1 "rd pr sync: 원격 fr 은 $sc 로 옮겼지만 작업 색인(pr-head·pr-sent)에 기록하지 못했습니다" "  재시도: $_DPS_RETRY (이어 갑니다)"; return $?
  fi
  l="$(git -C "$ROOT" rev-parse -q --verify "refs/heads/${FR}^{commit}" 2>/dev/null)" || l=""
  if [[ "$l" == "$cand" ]]; then
    tasks_lock_release >/dev/null 2>&1 || true
    return 0
  fi
  cur="$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null)" || cur=""
  if [[ "$cur" != "refs/heads/${FR}" ]]; then
    tasks_lock_release >/dev/null 2>&1 || true
    cn="${cur#refs/heads/}"; [[ -n "$cn" ]] || cn="분리된 HEAD"
    printf 'rd pr sync: push 와 색인 기록은 끝났습니다 (원격 fr·pr-head = %s)\n' "$sc"
    printf '  작업 worktree 가 %s 에 있어 옮기지 않았습니다. 작업 worktree 의 커밋·파일은 그대로입니다.\n' "$cn"
    printf '  git -C %s switch --no-overwrite-ignore %s 뒤 같은 명령을 다시 실행하십시오: %s\n' "$(dpr_shq "$WT")" "$(dpr_shq "$FR")" "$_DPS_RETRY"
    printf '  무시 파일이 %s 의 경로에 있으면 switch 는 덮지 않고 멈춥니다 — git 이 보인 파일을 작업 worktree 밖으로 옮긴 뒤 switch 부터 다시 실행합니다\n' "$FR"
    return 1
  fi
  # dpr_ff_move — --no-squash 와 HEAD 대조로 사용자 mergeOptions 에 속지 않고, 기본 브랜치가 추적하기 시작한 경로의 무시 파일을 덮지 않습니다.
  # 미추적·무시 파일 충돌은 파일을 옮기라고 안내하고, 추적 파일의 로컬 수정은 아래 보존 브랜치 절차로 보냅니다(git 메시지 판별에 LC_ALL=C).
  rc=0; dpr_ff_move "$WT" "$cand" || rc=$?
  out="$_DPR_FF_OUT"
  tasks_lock_release >/dev/null 2>&1 || true
  [[ "$rc" == 0 ]] && return 0
  # 서명 확인 설정(7단계 사전 판정 뒤에 켠 이어 가기 경로)은 보존 브랜치 절차로 풀리지 않습니다.
  if dpr_sig_refused "$out"; then
    printf 'rd pr sync: push 와 색인 기록은 끝났습니다 (원격 fr·pr-head = %s)\n' "$sc"
    printf '  서명 확인 설정이 켜져 있어 서명 없는 병합 커밋으로 작업 worktree 를 옮기지 못했습니다. 작업 worktree 의 커밋·파일은 그대로입니다.\n'
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -3 | sed 's/^/  git: /'
    printf '  merge.verifySignatures 또는 branch.%s.mergeOptions 의 --verify-signatures 를 끈 뒤 같은 명령을 다시 실행하십시오: %s\n' "$FR" "$_DPS_RETRY"
    return 1
  fi
  # 추적 파일의 로컬 수정이 함께 있으면(git 이 두 오류를 함께 냄) 보존 브랜치 절차로 보냅니다 — 4) 의 이동도 무시 파일을 덮지 않습니다.
  if [[ "$out" != *"Your local changes to the following files would be overwritten"* ]] \
    && [[ "$out" == *"untracked working tree files would be overwritten"* || "$out" == *"would lose untracked files"* ]]; then
    printf 'rd pr sync: push 와 색인 기록은 끝났습니다 (원격 fr·pr-head = %s)\n' "$sc"
    printf '  작업 worktree 의 추적하지 않는 파일(무시 파일 포함)이 새 head 가 추적하는 경로에 있어 옮기지 않았습니다. 파일은 그대로입니다:\n'
    printf '%s\n' "$out" | grep '^[[:space:]]' | head -10 | sed 's/^[[:space:]]*/    /'
    printf '  이 파일들을 작업 worktree 밖으로 옮긴 뒤 같은 명령을 다시 실행하십시오: %s\n' "$_DPS_RETRY"
    return 1
  fi
  keep="$(_dp_sync_keep_name "$cand")"
  # 출력하는 명령의 경로·ref 는 dpr_shq 로 인용합니다 — 공백·따옴표가 있는 경로에서도 복사해 그대로 실행할 수 있게.
  qw="$(dpr_shq "$WT")"; qk="$(dpr_shq "$keep")"
  printf 'rd pr sync: push 와 색인 기록은 끝났습니다 (원격 fr·pr-head = %s)\n' "$sc"
  printf '  작업 worktree 를 옮기지 못했습니다. 작업 worktree 의 커밋·파일은 그대로입니다.\n'
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -20 | sed 's/^/  git: /'
  printf '  작업 worktree 의 로컬 변경을 보존 브랜치에 모은 뒤 맞춥니다:\n'
  printf '    1) git -C %s switch -c %s\n' "$qw" "$qk"
  printf '    2) git -C %s commit --no-verify --allow-empty -m "rd pr sync 보존 — 스테이징"\n' "$qw"
  printf '    3) git -C %s add -A && git -C %s commit --no-verify --allow-empty -m "rd pr sync 보존 — 작업 트리"\n' "$qw" "$qw"
  printf '    4) git -C %s switch --no-overwrite-ignore -C %s %s\n' "$qw" "$(dpr_shq "$FR")" "$cand"
  printf '       무시 파일(add -A 가 담지 않음)이 새 head 의 경로에 있으면 4) 는 덮지 않고 멈춥니다 — git 이 보인 파일을 작업 worktree 밖으로 옮긴 뒤 4) 를 다시 실행합니다\n'
  printf '    5) 확인: git -C %s rev-parse HEAD 가 %s 이고, 작업 worktree 에서 bash rd-workflow/scripts/rd task status 의 안내 줄에 PR 검토 중(직접 설치 PR) 이 나오면 복구가 끝났습니다\n' "$qw" "$cand"
  printf '    6) 보존한 변경은 리뷰를 거치지 않은 변경입니다. PR 에 넣으려면 bash rd-workflow/scripts/rd pr reopen --task %s 뒤 아래 두 diff 로 확인하며 옮기고 종전 순서(검증·final diff review·seal·발행 요청)를 따릅니다. 넣지 않을 변경이면 보존 브랜치를 두거나 지웁니다.\n' "$SLUG"
  # 각 보존 커밋을 그 부모와 비교합니다 — 후보와 비교하면 기본 브랜치 쪽 차이가 섞입니다.
  printf '       스테이징했던 내용: git -C %s diff %s %s\n' "$qw" "$(dpr_shq "${keep}^^")" "$(dpr_shq "${keep}^")"
  printf '       그 뒤 작업 트리 변경: git -C %s diff %s %s\n' "$qw" "$(dpr_shq "${keep}^")" "$qk"
  # sync 도중 만든 로컬 커밋은 두 diff 에 나오지 않습니다 — 보존 브랜치의 그 아래 이력에 있습니다.
  # <보존>^^ 는 sync 가 멈춘 때의 로컬 fr 끝이고 후보와의 갈래점은 후보가 담은 옛 head 라, merge 하면 로컬 커밋만 옵니다(병합 커밋·충돌 해소 결과 포함).
  # merge 는 무시 파일을 덮으므로(--no-overwrite-ignore 도 ff 가 아닌 병합은 막지 못함) 겹치는 경로를 먼저 확인하게 합니다.
  # --no-renames 는 이름 변경을 지움·추가로 나눠 새 이름을 드러내고, ls-files 는 status.showUntrackedFiles 설정과 무관하게 무시 파일을 냅니다.
  # 겹침은 사용자가 6) 을 실행할 때의 디스크 상태로 정해지므로(4) 뒤 생긴 무시 파일 포함) 여기서 계산하지 않고 대조를 안내합니다.
  # --no-ff 는 merge.ff=only 설정을 덮어씁니다.
  printf '       sync 도중 만든 로컬 커밋: git -C %s log --oneline --graph %s\n' "$qw" "$(dpr_shq "${cand}..${keep}^^")"
  printf '       있으면 옮기기 전에 두 목록을 대조합니다 — 그 이력이 더하는 경로(이름 변경의 새 이름 포함): git -C %s diff --name-only --no-renames --diff-filter=A %s\n' \
    "$qw" "$(dpr_shq "${cand}...${keep}^^")"
  printf '       무시 파일: git -C %s ls-files --others --ignored --exclude-standard\n' "$qw"
  printf '       같은 경로이거나 한쪽이 다른 쪽의 상위 디렉터리인 무시 파일은 작업 worktree 밖으로 옮깁니다 — merge 는 무시 파일을 덮습니다. 대소문자를 구분하지 않는 볼륨(macOS 기본)에서는 대소문자만 다른 이름(data.cache 와 DATA.CACHE)도 같은 경로입니다\n'
  printf '       옮기기: git -C %s merge --no-ff --no-edit %s  (병합 커밋과 그 충돌 해소 결과도 옵니다. 충돌하면 해소한 뒤 git -C %s commit, 그만두려면 git -C %s merge --abort)\n' \
    "$qw" "$(dpr_shq "${keep}^^")" "$qw" "$qw"
  printf '  어느 명령이든 실패하면 그 자리에서 멈추고 오류를 확인하십시오. 1~3 이 끝난 뒤에는 모든 로컬 변경이 보존 브랜치에 있습니다.\n'
  return 1
}

# _dp_sync_done <head> — 9단계 출력.
_dp_sync_done() {
  local head="$1" p1 p2 files
  printf 'rd pr sync: %s 를 병합해 push 했습니다 (%s)\n' "$_DPS_DEF" "$(git -C "$ROOT" rev-parse --short "$head")"
  printf '  PR: %s\n' "$_DPS_URL"
  files=""
  if p1="$(git -C "$ROOT" rev-parse -q --verify "${head}^1" 2>/dev/null)" && p2="$(git -C "$ROOT" rev-parse -q --verify "${head}^2" 2>/dev/null)"; then
    files="$(git -C "$ROOT" merge-tree --write-tree --name-only --no-messages "$p1" "$p2" 2>/dev/null | sed '1d' | grep -v '^$' | sort -u | tr '\n' ' ')"
  fi
  printf '  해소한 기록 파일: %s\n' "${files:-없음}"
  printf '다음: bash rd-workflow/scripts/rd pr check --task %s\n' "$SLUG"
}

dp_sync() {
  local rc=0 ef
  _dp_parse sync - "$@" || { rc=$?; [[ "$rc" == 3 ]] && return 0; return "$rc"; }
  _dp_target || return $?
  if [[ -z "$WT" ]]; then
    _dp_fail 2 "rd pr sync: $FR 브랜치를 체크아웃한 worktree 를 찾을 수 없습니다 — 작업 worktree 를 복구한 뒤 다시 실행하십시오"; return $?
  fi
  _dp_sync_ctx || { _dp_fail 2 "rd pr sync: 기본 브랜치를 정할 수 없습니다 — rd-workflow/config/workflow.json 에 default_branch 를 설정하십시오"; return $?; }
  ef="$(mktemp "${TMPDIR:-/tmp}/rd-dpse.XXXXXX")" || { _dp_fail 1 "rd pr sync: 임시 파일을 만들 수 없습니다"; return $?; }
  rc=0; _dp_sync_run "$ef" || rc=$?
  rm -f "$ef"
  return "$rc"
}

# _dp_sync_run <오류 임시 파일> — dp_sync 의 1~9단계(대상 확정 뒤).
_dp_sync_run() {
  local ef="$1" rc=0 url h st l b o line state mo prh base mergeable review vurl tree cand err out vs
  # 1단계 — PR 대기 판정(색인과 fr 브랜치). L 이 H 와 같을 필요는 없습니다(복구 상태는 4단계가 판정).
  url="$_DPS_URL"
  h="$(dpr_index_get "$SLUG" pr-head 2>/dev/null)" || h=""
  st="$(dpr_index_get "$SLUG" state 2>/dev/null)" || st=""
  l="$(git -C "$ROOT" rev-parse -q --verify "refs/heads/${FR}^{commit}" 2>/dev/null)" || l=""
  rc=0
  if [[ -n "$url" && -n "$h" && -n "$l" && "$st" != cleanup-pending ]]; then
    dpr_published_head "$ROOT" "$l" "$SLUG" "refs/remotes/origin/${_DPS_DEF}" >/dev/null 2>"$ef" || rc=$?
  else
    rc=1
  fi
  if [[ "$rc" != 0 ]]; then
    printf 'rd pr sync: PR 을 기다리는 작업에서만 sync 합니다 — 아무것도 바꾸지 않았습니다.\n'
    printf '  pr-head: %s  state: %s  로컬 fr: %s\n' "${h:-없음}" "${st:-없음}" "${l:-없음}"
    [[ "$rc" == 2 && -s "$ef" ]] && printf '  사유: %s\n' "$(head -1 "$ef")"
    printf '  확인: bash rd-workflow/scripts/rd pr check --task %s\n' "$SLUG"
    return 2
  fi
  rc=0; err="$(_dp_wt_state "$WT" "$l")" || rc=$?
  if [[ "$rc" == 2 ]]; then
    _dp_fail 1 "rd pr sync: 작업 worktree($WT)의 상태를 읽지 못했습니다 — 아무것도 바꾸지 않았습니다: $err" \
      "  확인: git -C $(dpr_shq "$WT") status --untracked-files=all"; return $?
  elif [[ "$rc" != 0 ]]; then
    _dp_fail 1 "rd pr sync: 작업 worktree($WT)에 미커밋 변경(추적되지 않은 파일 포함)이 있거나 HEAD 가 $FR 의 끝과 다릅니다 — 정리한 뒤 다시 실행하십시오" \
      "  확인: git -C $(dpr_shq "$WT") status --untracked-files=all"; return $?
  fi
  # 2단계 — PR 조회(원격 fr 이 없어도 먼저 합니다)
  printf 'rd pr sync: PR 상태를 조회합니다 (%s)\n' "$url"
  command -v gh >/dev/null 2>&1 || { _dp_fail 1 "rd pr sync: gh(GitHub CLI)를 찾을 수 없습니다"; return $?; }
  rc=0; line="$(_dp_pr_view "$url")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    _dp_fail 1 "rd pr sync: PR 상태 조회 실패: $line" "  다시 실행: $_DPS_RETRY"; return $?
  fi
  IFS='|' read -r state mo prh base mergeable review vurl <<EOF_DPS
$line
EOF_DPS
  if [[ "$base" != "$_DPS_DEF" ]]; then
    _dp_fail 1 "rd pr sync: PR 의 대상 브랜치가 $base 입니다 (기본 브랜치: $_DPS_DEF) — sync 는 기본 브랜치를 대상으로 하는 PR 만 다룹니다" \
      "  확인: bash rd-workflow/scripts/rd pr check --task $SLUG"; return $?
  fi
  case "$state" in
    MERGED)
      _dp_fail 1 "rd pr sync: PR 이 이미 merge 됐습니다 ($url) — 병합하지 않습니다. 마감하려면:" \
        "  bash rd-workflow/scripts/rd pr check --task $SLUG --apply"; return $? ;;
    CLOSED)
      printf 'rd pr sync: PR 이 merge 없이 닫혔습니다 (%s) — 병합하지 않습니다.\n' "$url"
      dpr_closed_choices "$SLUG" "$url" "$FR"
      return 1 ;;
  esac
  # 3단계 — 기본 브랜치를 가져오고 원격 fr 끝을 읽습니다
  printf 'rd pr sync: origin 에서 %s 를 가져오고 원격 %s 를 확인합니다\n' "$_DPS_DEF" "$FR"
  err="$(_dp_fetch_branches "$_DPS_DEF")" || { _dp_fail 1 "rd pr sync: origin/$_DPS_DEF 를 가져오지 못했습니다: $err" "  재시도: $_DPS_RETRY"; return $?; }
  rc=0; o="$(_dp_sync_remote_head)" || rc=$?
  [[ "$rc" == 0 ]] || { _dp_fail 1 "rd pr sync: 원격 fr 브랜치를 조회하지 못했습니다 (git ls-remote origin 실패)" "  재시도: $_DPS_RETRY"; return $?; }
  # 4단계 — 시작점 판정
  _DPS_L="$l"; _DPS_H="$h"; _DPS_S="$(dpr_index_get "$SLUG" pr-sent 2>/dev/null)" || _DPS_S=""
  rc=0; _dp_sync_reconcile "$o" "$prh" || rc=$?
  case "$rc" in
    0) ;;
    4) _dp_sync_finish "$o" || return $?
       _dp_sync_done "$o"; return 0 ;;
    *) return 1 ;;
  esac
  # 6단계 — 트리 계산 (정상 경로: L = H = O)
  b="$(git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/${_DPS_DEF}^{commit}" 2>/dev/null)" || {
    _dp_fail 1 "rd pr sync: origin/$_DPS_DEF 를 읽을 수 없습니다" "  재시도: $_DPS_RETRY"; return $?; }
  if git -C "$ROOT" merge-base --is-ancestor "$b" "$l" 2>/dev/null; then
    printf 'rd pr sync: 동기화할 변경 없음 — %s 가 이미 origin/%s 를 포함합니다\n' "$FR" "$_DPS_DEF"
    return 0
  fi
  rc=0; out="$(dpr_sync_tree "$ROOT" "$l" "$b" 2>"$ef")" || rc=$?
  err="$(head -1 "$ef" 2>/dev/null)"
  case "$rc" in
    0) tree="$out" ;;
    1)
      printf 'rd pr sync: origin/%s 와 합치면 자동 해소 대상 밖에서 충돌합니다 — 아무것도 바꾸지 않았습니다:\n' "$_DPS_DEF"
      printf '%s\n' "$out" | grep -v '^$' | sed 's/^/    /'
      _dp_conflict_guide "$SLUG" "$_DPS_DEF"
      return 1 ;;
    *)
      printf 'rd pr sync: 자동 병합을 대조할 수 없습니다 — 아무것도 바꾸지 않았습니다.\n'
      printf '  사유: %s\n' "${err:-알 수 없음}"
      _dp_conflict_guide "$SLUG" "$_DPS_DEF"
      return 1 ;;
  esac
  # 작업 worktree 에 끝나지 않은 병합이 있으면 8단계의 fast-forward 가 막히고(작업 트리가 깨끗해도 MERGE_HEAD 가 남음), 서명 판정도 가려집니다 — push 전에 멈춥니다.
  if git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    printf 'rd pr sync: 작업 worktree(%s)에 끝나지 않은 병합(MERGE_HEAD)이 있습니다 — 아무것도 바꾸지 않았습니다.\n' "$(dpr_shq "$WT")"
    printf '  작업 worktree 에서 병합을 커밋하거나 git merge --abort 로 취소한 뒤 다시 실행하십시오: %s\n' "$_DPS_RETRY"
    return 1
  fi
  # 서명 확인 설정이면 8단계의 fast-forward 가 서명 없는 병합 커밋에서 막힙니다 — push 전에 멈춥니다(발행 쪽 자동 병합 fallback 과 같은 복구 순서).
  vs=0; dpr_verifysig_on "$WT" "$FR" || vs=$?
  if [[ "$vs" == 2 ]]; then
    printf 'rd pr sync: 작업 worktree(%s)에서 git merge 를 시험할 수 없어 마무리 이동이 될지 알 수 없습니다 — 아무것도 바꾸지 않았습니다.\n' "$(dpr_shq "$WT")"
    printf '  git: %s\n' "$_DPR_VS_OUT"
    printf '  진행 중인 cherry-pick·revert 가 있으면 작업 worktree 에서 마무리하거나 취소(git cherry-pick --abort, git revert --abort)한 뒤 다시 실행하십시오: %s\n' "$_DPS_RETRY"
    return 1
  fi
  if [[ "$vs" == 0 ]]; then
    printf 'rd pr sync: 서명 확인 설정(merge.verifySignatures 또는 branch.%s.mergeOptions 의 --verify-signatures)이 켜져 있어 서명 없는 병합 커밋으로 작업 브랜치를 옮길 수 없습니다 — 아무것도 바꾸지 않았습니다.\n' "$FR"
    dpr_verifysig_guide "$SLUG" "$_DPS_DEF"
    printf '  설정을 끌 수 있으면 끈 뒤 다시 실행하십시오: %s\n' "$_DPS_RETRY"
    return 1
  fi
  # 7단계 — 병합 커밋 → 검증 → 목록 기록 → push
  cand="$(git -C "$ROOT" commit-tree "$tree" -p "$l" -p "$b" -m "$(_dpr_sync_subject "$_DPS_DEF" "$FR")" 2>/dev/null)" || {
    _dp_fail 1 "rd pr sync: 병합 커밋을 만들지 못했습니다 — 아무것도 바꾸지 않았습니다" "  재시도: $_DPS_RETRY"; return $?; }
  # 새 head 가 추적하기 시작하는 경로(또는 그 경로의 상·하위)에 작업 worktree 의 무시 파일이 있으면 마무리 이동이 멈추거나 덮습니다 — push 전에 멈춥니다.
  out="$(_dp_sync_ignored_clash "$l" "$cand")" || {
    _dp_fail 1 "rd pr sync: 작업 worktree 의 무시 파일이 $_DPS_DEF 가 추적하는 경로에 있습니다 — 덮어쓰지 않도록 아무것도 바꾸지 않았습니다:" \
      "$(printf '%s\n' "$out" | head -10 | sed 's/^/    /')" "  이 파일들을 작업 worktree 밖으로 옮긴 뒤 다시 실행하십시오: $_DPS_RETRY"; return $?; }
  if ! dpr_published_head "$ROOT" "$cand" "$SLUG" "refs/remotes/origin/${_DPS_DEF}" >/dev/null 2>&1; then
    _dp_fail 1 "rd pr sync: 만든 병합 커밋이 검증을 통과하지 못해 push 하지 않았습니다" "  재시도: $_DPS_RETRY"; return $?
  fi
  if ! err="$(dpr_verified_add "$SLUG" "$h" "$cand" 2>&1)"; then
    _dp_fail 1 "rd pr sync: 검증된 head 목록에 기록하지 못해 push 하지 않았습니다" \
      "  진단: $(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -1)" "  재시도: $_DPS_RETRY"; return $?
  fi
  printf 'rd pr sync: 병합 커밋 %s 를 origin/%s 에 push 합니다\n' "$(git -C "$ROOT" rev-parse --short "$cand")" "$FR"
  if ! _dp_sync_push "$cand" "$h"; then
    _dp_sync_after_push_fail "$cand" "$h" || return $?
  fi
  # 8단계 — 마무리
  _dp_sync_finish "$cand" || return $?
  # 9단계
  _dp_sync_done "$cand"
}

dp_main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    open) dp_open ${1+"$@"} ;;
    check) dp_check ${1+"$@"} ;;
    reopen) dp_reopen ${1+"$@"} ;;
    sync) dp_sync ${1+"$@"} ;;
    -h|--help|help) _dp_usage; return 0 ;;
    *) _dp_usage >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dp_main ${1+"$@"}
  exit $?
fi
