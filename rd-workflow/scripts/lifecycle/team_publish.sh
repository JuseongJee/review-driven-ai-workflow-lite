#!/usr/bin/env bash
# team_publish.sh — overlay 마감 때 submodule 의 팀 저장소 반영 명령 (`rd pr <sub>` 가 그대로 넘깁니다).
#   open [--dry-run] [--approved] [--approve-push]   seal 을 마친 작업의 submodule 커밋을 팀 저장소에 PR(또는 push)로 올립니다.
#   light-check [<base-ref>]                         light 작업이 반영 대상 submodule 을 바꿨는지 판정합니다(상향이면 rc 3).
#   check [--task <slug>] [--apply]                  PR 판정을 보이고, --apply 는 merge 결과로 포인터를 옮겨 Status 를 아카이브 보류 로 되돌립니다.
#   Spec: rd-workflow-workspace/specs/changes/2026-11-16-1330-publish-via-pull-request-change-spec.md (D5·D6·D7·D9·D14)
#
# 종료 코드: 성공 0, 실패 1, 사용법·판정 불가 2, light-check 상향 3, 사용자 승인 필요 10.
# 출력: 진행·결과·원인·재시도 명령은 stdout 입니다. 첫 실행 안내(D8)만 stderr 입니다.
# 하위 명령 분기는 맨 아래 tp_main 의 case 한 곳에 둡니다.
#
# bash 3.2 호환: 연관 배열·${var,,} 를 쓰지 않는다.
set -uo pipefail

_TP_LC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TP_SD="$(cd "${_TP_LC_DIR}/.." && pwd)"
if [[ -z "${project_root:-}" ]]; then
  project_root="$(cd "${_TP_SD}/../.." && pwd)"
fi
if [[ ! -d "${project_root}/rd-workflow-workspace" ]]; then
  echo "rd pr: 프로젝트 루트를 확정할 수 없습니다: '${project_root}' 에 rd-workflow-workspace/ 가 없습니다." >&2
  exit 2
fi
export project_root

# source 순서는 _team_publish_common.sh 머리 주석(1~5)을 따릅니다. seal 검증(rd_seal_verify)은 그 뒤에 싣습니다.
source "${_TP_LC_DIR}/_lifecycle_common.sh" || exit 2
source "${_TP_SD}/_state_common.sh" || exit 2
source "${_TP_SD}/_submodule_common.sh" || exit 2
source "${_TP_LC_DIR}/_tasks_index.sh" || exit 2
source "${_TP_LC_DIR}/_team_publish_common.sh" || exit 2
source "${_TP_SD}/hooks/_guard_common.sh" || exit 2

# gh 를 부를 때의 시간 상한(초). 생성·갱신·조회 모두 같은 값을 씁니다.
_TP_GH_LIMIT=60
_TP_ITEMS_RE='^rd-workflow-workspace/backlog/items/'

_tp_usage() {
  cat <<'EOF'
사용법: bash rd-workflow/scripts/rd pr <subcommand> [args...]
  open [--dry-run] [--approved] [--approve-push]
                       seal 을 마친 작업의 submodule 커밋을 팀 저장소에 PR(반영 방식 pr) 또는 push(반영 방식 push)로 올립니다.
                       --dry-run 은 대상 표·PR 제목·본문 첫 줄만 보이고 원격을 바꾸지 않습니다.
                       --approved 는 사용자 승인을 받은 뒤에만, --approve-push 는 push 대상을 사용자가 승인한 뒤에만 붙입니다.
  light-check [<base-ref>]
                       light 작업이 반영 방식 pr·push 인 submodule 을 바꿨는지 판정합니다 (기본 HEAD, 상향이면 종료 코드 3).
  check [--task <slug>] [--apply]
                       PR 기록의 PR 마다 판정(merge 됨·수정 요청·닫힘·검토 중·조회 실패)과 남은 행동을 보입니다. Status 는 바꾸지 않습니다.
                       --apply 는 모든 PR 이 merge 되고 리뷰한 변경이 그대로 들어갔을 때 submodule 포인터를 merge 결과로 옮겨
                       커밋하고 Status 를 아카이브 보류 로 되돌립니다. 중간에 멈췄으면 다시 실행해 이어 갑니다.
  reopen [--task <slug>]
                       직접 설치 PR 방식(archive_publish=pr) 작업 전용입니다. 수정 요청·충돌을 반영하려고 작업을 구현 중으로 되돌립니다.
                       직접 설치 작업이면 open·check 도 direct_pr.sh 가 맡습니다(--task <slug> 지원).
  sync [--task <slug>]  기록 파일만 충돌한 PR 에 기본 브랜치를 병합합니다(직접 설치 PR, archive_publish=pr 작업 전용)
  종료 코드: 0 성공 / 1 실패 / 2 사용법·판정 불가 / 3 light-check 상향 / 10 사용자 승인 필요
EOF
}

# ---------------------------------------------------------------------------
# Source FR · PR 제목 · PR 본문 (D5·D6)
# ---------------------------------------------------------------------------

# _tp_source_frs <root> [--all] — task-state 의 Source FR 경로를 줄마다(없으면 출력 없음).
# 기본은 파일이 있는 경로만, --all 은 파일이 없는 경로도 냅니다(Issue 참조 검사가 누락을 알리게).
_tp_source_frs() {
  local root="${1:?root}" all="${2:-}" raw p
  raw="$(state_read_field "source-fr" 2>/dev/null)" || raw=""
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "-" ]] || continue
    [[ "$all" == --all || -f "$root/$p" ]] && printf '%s\n' "$p"
  done <<EOF_SF
$(source_fr_split "$raw" "$root")
EOF_SF
}

# _tp_fr_field <file> <field> — FR 항목의 첫 `- <field>:` 값(앞뒤 공백 제거).
_tp_fr_field() {
  awk -v k="- $2:" 'index($0, k) == 1 { v = substr($0, length(k) + 1); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit }' "$1" 2>/dev/null
}

# tp_pr_title <root> <slug> — Source FR 의 `- summary:` 값, 없으면 slug.
tp_pr_title() {
  local root="${1:?root}" slug="${2:?slug}" p v
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    v="$(_tp_fr_field "$root/$p" summary)"
    if [[ -n "$v" && "$v" != "-" ]]; then printf '%s\n' "$v"; return 0; fi
  done <<EOF_T
$(_tp_source_frs "$root")
EOF_T
  printf '%s\n' "$slug"
}

# _tp_issue_refs <root> [--closes] — Source FR 마다 `- github-issue:` 값을 issue_queue.sh issue-refs(close-fr 와 같은 형식 검사)로
# 읽어 `[host/]owner/repo#N` 을 줄마다 냅니다. `--closes` 면 PR 본문 Closes 줄에 쓸 참조(적힌 URL 그대로 등)를 냅니다. 한 FR 이라도 형식이 어긋나거나 상세를 읽지 못하면(파일 없음 포함)
# 아무것도 내지 않고 rc 2 이며,
# 어느 FR 의 어느 조각이 틀렸는지 stderr 에 한 줄로 알립니다(Issue 를 잘못 참조하는 줄을 내지 않습니다).
_tp_issue_refs() {
  local root="${1:?root}" mode="${2:-}" p out refs="" bad=0 err
  err="$(mktemp "${TMPDIR:-/tmp}/rd-tp-iref.XXXXXX")" || return 2
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if out="$(bash "$_TP_SD/issue_queue.sh" issue-refs "$root/$p" $mode 2>"$err" </dev/null)"; then
      [[ -n "$out" ]] && refs="${refs:+$refs$'\n'}$out"
    else
      bad=1
      printf 'rd pr: WARNING — %s 의 %s\n' "$p" "$(awk 'NF{l=$0} END{print l}' "$err")" >&2
    fi
  done <<EOF_I
$(_tp_source_frs "$root" --all)
EOF_I
  rm -f "$err"
  [[ "$bad" == 0 ]] || return 2
  [[ -n "$refs" ]] && printf '%s\n' "$refs"
  return 0
}

# _TP_PR_HEADS_DEFAULT — PR 템플릿 파일을 읽지 못할 때 쓰는 배포 템플릿의 `## ` 제목(줄마다 하나).
_TP_PR_HEADS_DEFAULT='Summary
User-visible Changes
Technical Changes
되돌리기와 영향 범위
Risks
Verification
Notes'

# _tp_pr_template_heads <root> — <root>/rd-workflow/docs/PR_TEMPLATE.md 의 `## ` 제목(앞뒤 공백 제거)을 줄마다 냅니다.
# 파일이 없거나 `## ` 줄이 없으면 _TP_PR_HEADS_DEFAULT 를 냅니다.
_tp_pr_template_heads() {
  local t="$1/rd-workflow/docs/PR_TEMPLATE.md" h=""
  [[ -f "$t" ]] && h="$(awk '/^## / { s = substr($0, 4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); if (s != "") print s }' "$t")"
  if [[ -n "$h" ]]; then printf '%s\n' "$h"; else printf '%s\n' "$_TP_PR_HEADS_DEFAULT"; fi
}

# tp_extract_pr_body <root> — final diff review 세션(task-state review-session)에서 `## PR 본문` 절을 담은
# 가장 최근 Author 턴의 그 절을 stdout 으로 냅니다.
#   끝 경계: `## PR 본문` 뒤에서 PR 템플릿(_tp_pr_template_heads)에 없는 제목의 첫 `## ` 줄, 또는 첫 `# ` 줄.
#            템플릿 제목(`## Summary` 등)은 본문의 일부로 남깁니다. 제목 비교는 앞뒤 공백을 무시한 전체 일치입니다.
#            코드 블록(``` · ~~~ 로 여는 줄부터 닫는 줄까지) 안의 `#` 줄은 경계로 보지 않습니다.
#   정리: HTML 주석(`<!-- … -->`, 여러 줄 포함, 코드 블록 밖)을 지웁니다. 주석만 있던 줄은 줄째 지웁니다.
#         본문 첫 비어 있지 않은 줄이 `# ` H1 이면(템플릿 파일 제목을 같이 옮긴 경우) 그 줄을 지웁니다.
#         끝으로 앞뒤 빈 줄을 지웁니다. 그 밖의 내용은 고치지 않습니다.
# Source FR 의 github-issue 가 있으면 빈 줄 뒤에 줄마다 `Closes <참조>` 를 붙입니다(_tp_issue_refs --closes).
# 형식이 어긋난 값이 있으면 Closes 줄을 하나도 붙이지 않고 stderr 에 경고만 냅니다(본문은 그대로 rc 0).
# 절이 없거나 정리 뒤 비어 있으면 rc 1 (빈 본문으로 PR 을 만들지 않습니다).
tp_extract_pr_body() {
  local root="${1:?root}" sid dir f body="" urls u heads
  sid="$(state_read_field "review-session" 2>/dev/null)" || sid=""
  [[ -n "$sid" && "$sid" != "null" && "$sid" != */* && "$sid" != *..* ]] || return 1
  dir="$root/rd-workflow-workspace/handoffs/review_pipeline/$sid/turns"
  [[ -d "$dir" ]] || return 1
  heads="$(_tp_pr_template_heads "$root")"
  for f in $(ls "$dir" 2>/dev/null | grep -E '^[0-9]+_author\.md$' | sort -r); do
    grep -Eq '^## PR 본문[[:space:]]*$' "$dir/$f" || continue
    body="$(TP_HEADS="$heads" awk '
      BEGIN {
        k = split(ENVIRON["TP_HEADS"], hl, "\n")
        for (j = 1; j <= k; j++) if (hl[j] != "") H[hl[j]] = 1
      }
      !on && /^## PR 본문[[:space:]]*$/ { on = 1; next }
      !on { next }
      {
        ln = $0
        if (!fence && !incom && ln ~ /^[[:space:]]*(```|~~~)/) { fence = 1; fmark = substr(ln, match(ln, /(```|~~~)/), 3); keep(ln); next }
        if (fence) { if (index(ln, fmark) && ln ~ /^[[:space:]]*(```|~~~)/) fence = 0; keep(ln); next }
        had = 0; out = ""
        while (ln != "") {
          if (incom) {
            p = index(ln, "-->"); had = 1
            if (p == 0) { ln = ""; break }
            ln = substr(ln, p + 3); incom = 0
          } else {
            p = index(ln, "<!--")
            if (p == 0) { out = out ln; ln = ""; break }
            out = out substr(ln, 1, p - 1); ln = substr(ln, p + 4); incom = 1; had = 1
          }
        }
        if (had && out ~ /^[[:space:]]*$/) next
        if (out ~ /^## /) {
          t = substr(out, 4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
          if (!(t in H)) exit
        } else if (out ~ /^# /) {
          if (started) exit
          next
        }
        keep(out)
      }
      function keep(x) { line[++n] = x; if (x !~ /^[[:space:]]*$/) started = 1 }
      END {
        s = 1; while (s <= n && line[s] ~ /^[[:space:]]*$/) s++
        e = n; while (e >= s && line[e] ~ /^[[:space:]]*$/) e--
        for (i = s; i <= e; i++) print line[i]
      }' "$dir/$f")"
    break
  done
  [[ -n "$body" ]] || return 1
  printf '%s\n' "$body"
  if urls="$(_tp_issue_refs "$root" --closes)"; then
    if [[ -n "$urls" ]]; then
      printf '\n'
      while IFS= read -r u; do [[ -n "$u" ]] && printf 'Closes %s\n' "$u"; done <<<"$urls"
    fi
  else
    printf 'rd pr: WARNING — PR 본문에 Closes 줄을 넣지 않았습니다. merge 해도 연결된 Issue 는 닫히지 않습니다 — 상세의 github-issue 를 고친 뒤 PR 본문에 Closes 줄을 직접 더하십시오\n' >&2
  fi
  return 0
}

# tp_closed_choices <slug> <pr-url> <root> — 닫힌 PR 의 선택지 세 가지(D7). check 도 같은 문구를 씁니다.
#   호스트 없는 참조(o/r#N)는 PR 저장소의 호스트를 가리키므로 PR URL 의 호스트를 붙여 --repo 에 적습니다.
#   PR 호스트를 알 수 없으면 명령 대신 Issue URL 로 지정하라고 안내합니다(gh 가 다른 호스트를 고르지 않게).
tp_closed_choices() {
  local slug="$1" url="$2" root="${3:-}" urls u r ph="" rc=0 err="" w
  case "$url" in http://?*/*|https://?*/*) ph="${url#*://}"; ph="${ph%%/*}" ;; esac
  printf '  선택지 (사람이 정합니다):\n'
  printf '    1) dropped 로 닫기: /fr status %s dropped 뒤 bash rd-workflow/scripts/lifecycle/promote_rollback.sh\n' "$slug"
  printf '    2) 다시 올리기: gh pr reopen %s\n' "$url"
  urls=""
  if [[ -n "$root" ]]; then
    err="$(mktemp "${TMPDIR:-/tmp}/rd-tp-cc.XXXXXX")" || err=/dev/null
    urls="$(_tp_issue_refs "$root" 2>"$err")" || rc=$?
  fi
  if [[ "$rc" != 0 ]]; then
    # Issue 참조를 읽지 못했다 — 어느 상세의 무엇을 고칠지 3) 줄에 싣는다(직접 설치 경로는 3) 줄만 옮겨 보인다).
    while IFS= read -r w; do
      [[ -n "$w" ]] && printf '    3) 연결된 Issue 선점 풀기: Issue 참조를 읽지 못했습니다 — %s. 상세의 github-issue 를 고치거나 gh issue edit <Issue URL> --remove-assignee @me 로 직접 지정하십시오\n' "${w#rd pr: WARNING — }"
    done <"$err"
    [[ -s "$err" ]] || printf '    3) 연결된 Issue 선점 풀기: Issue 참조를 읽지 못했습니다. 상세의 github-issue 를 고치거나 gh issue edit <Issue URL> --remove-assignee @me 로 직접 지정하십시오\n'
  elif [[ -n "$urls" ]]; then
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      r="${u%#*}"
      if [[ "$r" != */*/* ]]; then
        if [[ -z "$ph" ]]; then
          printf '    3) 연결된 Issue 선점 풀기: gh issue edit <Issue URL> --remove-assignee @me (%s — PR 호스트를 알 수 없어 Issue URL 로 지정하십시오)\n' "$u"
          continue
        fi
        r="$ph/$r"
      fi
      printf '    3) 연결된 Issue 선점 풀기: gh issue edit %s --repo %s --remove-assignee @me\n' "${u##*#}" "$r"
    done <<<"$urls"
  else
    printf '    3) 연결된 Issue 선점 풀기: gh issue edit <Issue URL> --remove-assignee @me (연결된 Issue 가 있을 때)\n'
  fi
  [[ -n "$err" && "$err" != /dev/null ]] && rm -f "$err"
  return 0
}

# ---------------------------------------------------------------------------
# 원격 · gh 보조
# ---------------------------------------------------------------------------

# _tp_url_host <origin-url> — https://host/…, ssh://[user@]host[:port]/…, user@host:… 에서 호스트. 모르면 빈 값.
_tp_url_host() {
  local u="$1" h=""
  case "$u" in
    http://*|https://*|ssh://*|git://*)
      h="${u#*://}"; h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}" ;;
    /*|./*|../*|file://*) h="" ;;
    *@*:*) h="${u#*@}"; h="${h%%:*}" ;;
  esac
  printf '%s\n' "$h"
}

# _tp_json_get <json> <python-expr over d> — gh JSON 응답에서 값 하나를 꺼냅니다. 실패 rc 1.
_tp_json_get() {
  printf '%s' "$1" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
    v = eval(sys.argv[1], {"d": d})
except Exception:
    sys.exit(1)
print("" if v is None else v)
' "$2"
}

# _tp_pr_list_parse — stdin 의 `gh pr list --json url,state,baseRefName` 배열을 `STATE<TAB>URL<TAB>BASE` 줄로. 해석 실패 rc 1.
_tp_pr_list_parse() {
  python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
    assert isinstance(d, list)
except Exception:
    sys.exit(1)
for p in d:
    if isinstance(p, dict):
        print("%s\t%s\t%s" % (p.get("state") or "", p.get("url") or "", p.get("baseRefName") or ""))
'
}

# ---------------------------------------------------------------------------
# open (D5)
# ---------------------------------------------------------------------------

# 대상 배열(인덱스 같은 줄이 한 대상). bash 3.2 라 연관 배열 대신 평행 배열을 씁니다.
T_PATH=(); T_HEAD=(); T_MODE=(); T_BASE=(); T_BRANCH=(); T_ORIGIN=(); T_REPO=(); T_RESULT=()
_TP_RETRY=""
# no-fr 작업(fr 브랜치 없이 기본 브랜치에서 작업)도 open·check --apply 가 받습니다(spec D3-1). tip 은 HEAD 이고,
# PR 기록 커밋과 포인터 커밋은 기본 브랜치의 HEAD 위에 쌓입니다. 기록·팀 원격·Status·포인터를 바꾸기 전에
# _tp_nofr_precheck 가 두 조건(HEAD 가 기본 브랜치, tip 의 archive_publish 가 pr 가 아님)을 봅니다.
# 반영 방식을 manual 로 바꾸라는 안내. seal 뒤(아카이브 보류·PR 검토 중)에는 커밋 게이트가 기록 경로 밖 커밋을 막고
# workflow.json 이 seal 보호 트리에 들어 있어, "작업 브랜치에서 바꿔 커밋" 만으로는 진행할 수 없습니다.
_TP_CFG_HINT=(
  '이번 작업만 반영하지 않으려면: archive.sh 에 --allow-unpublished-submodule "<사유>" 를 붙여 발행하십시오(audit 기록)'
  '다음 작업부터 반영하지 않으려면: 기본 브랜치에서 rd-workflow/config/workflow.json 의 team_publish.mode(submodule 별은 team_publish.submodules.<경로>.mode) 를 manual 로 바꿔 커밋하십시오'
  '이번 작업에서 바꾸려면: bash rd-workflow/scripts/rd task set-status "구현 중" → 설정 커밋 → final diff review 재종결 → rd review seal 순서로 하십시오'
)

_tp_fail_pre() {  # <원인> [추가 줄...] — 전제 실패. 원인 첫 줄과 재시도 명령을 내고 rc 1.
  printf 'rd pr open: %s\n' "$1"
  shift
  local l; for l in "$@"; do printf '  %s\n' "$l"; done
  printf '  재시도: %s\n' "$_TP_RETRY"
  return 1
}

# _tp_do_pr <i> <title> <bodyfile> <root> <slug> — 반영 방식 pr 대상 하나. 결과는 T_RESULT[i].
# rc 0 PR 을 만들거나 갱신함(또는 merge 를 처음 알아챔) / 2 이미 반영 완료(기록 state=merged, 바꾼 것 없음) / 1 실패.
_tp_do_pr() {
  local i="$1" title="$2" bodyf="$3" root="$4" slug="$5"
  local p="${T_PATH[$i]}" head="${T_HEAD[$i]}" br="${T_BRANCH[$i]}" base="${T_BASE[$i]}" repo="${T_REPO[$i]}"
  local sub="$root/${T_PATH[$i]}" url="" verdict="" found="" out rc errf line st u n_open=0 open_urls="" merged_url="" closed_url="" remote_oid
  local rec_state rec_merged mhead open_base=""

  # 0) check --apply 가 merge 를 반영한 대상(기록 state=merged)은 다시 올리지 않습니다. Status 도 되돌리지 않습니다(spec D3).
  rec_state="$(tp_record_get "$root" "$p" state 2>/dev/null)" || rec_state=""
  if [[ "$rec_state" == merged ]]; then
    rec_merged="$(tp_record_get "$root" "$p" merged-oid 2>/dev/null)" || rec_merged=""
    url="$(tp_record_get "$root" "$p" url 2>/dev/null)" || url=""
    if [[ "$rec_merged" == "$head" ]]; then
      T_RESULT[$i]="반영 완료 — PR 이 merge 되어 포인터를 옮겼습니다 (${url})"
      return 2
    fi
    T_RESULT[$i]="실패 — 기록은 merge 됨(merged-oid=${rec_merged})인데 포인터가 ${head} 입니다. 기록을 확인하십시오: ${RD_TEAM_PR_RECORD}"
    return 1
  fi

  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpo.XXXXXX")" || { T_RESULT[$i]="실패 — 임시 파일을 만들 수 없습니다"; return 1; }
  if ! git -C "$sub" fetch -q origin 2>"$errf"; then
    T_RESULT[$i]="실패 — git fetch origin 실패: $(head -1 "$errf")"; rm -f "$errf"; return 1
  fi

  # 1) 기존 PR 찾기 — 기록 URL 이 있으면 그 PR, 없으면 브랜치의 PR 전체(--state all).
  url="$(tp_record_get "$root" "$p" url 2>/dev/null)" || url=""
  if [[ -n "$url" && "$url" != "-" ]]; then
    st="$(tp_pr_state "$url")"
    verdict="${st%%$'\t'*}"
    case "$verdict" in
      MERGED) found=MERGED ;;
      CLOSED) found=CLOSED ;;
      OPEN|CHANGES_REQUESTED) found=OPEN ;;
      *) T_RESULT[$i]="실패 — PR 조회 실패 (${url}): ${st##*$'\t'}"; rm -f "$errf"; return 1 ;;
    esac
    if [[ "$found" == OPEN ]]; then
      # 실제 대상 브랜치는 tp_pr_state 가 내지 않으므로(출력 형식 고정) 따로 조회합니다.
      rc=0; out="$(tp_gh "$_TP_GH_LIMIT" pr view "$url" --json baseRefName 2>"$errf")" || rc=$?
      if [[ "$rc" != 0 ]] || ! open_base="$(_tp_json_get "$out" 'd["baseRefName"]')" || [[ -z "$open_base" ]]; then
        line="$(head -1 "$errf")"
        T_RESULT[$i]="실패 — PR 의 대상 브랜치를 조회하지 못했습니다 (${url})${line:+: $line}"; rm -f "$errf"; return 1
      fi
    fi
  else
    url=""
    rc=0; out="$(tp_gh "$_TP_GH_LIMIT" pr list --repo "$repo" --head "$br" --state all --json url,state,baseRefName 2>"$errf")" || rc=$?
    if [[ "$rc" != 0 ]]; then
      T_RESULT[$i]="실패 — gh pr list 실패: $(head -1 "$errf")"; rm -f "$errf"; return 1
    fi
    if ! out="$(printf '%s' "$out" | _tp_pr_list_parse)"; then
      T_RESULT[$i]="실패 — gh pr list 응답을 해석할 수 없습니다"; rm -f "$errf"; return 1
    fi
    while IFS=$'\t' read -r st u b; do
      [[ -n "$st" ]] || continue
      case "$st" in
        OPEN) n_open=$((n_open + 1)); open_urls="${open_urls:+$open_urls }$u"; [[ -n "$url" ]] || { url="$u"; open_base="$b"; } ;;
        MERGED) [[ -n "$merged_url" ]] || merged_url="$u" ;;
        CLOSED) [[ -n "$closed_url" ]] || closed_url="$u" ;;
      esac
    done <<<"$out"
    if [[ "$n_open" -ge 2 ]]; then
      T_RESULT[$i]="멈춤 — 브랜치 ${br} 에 열린 PR 이 둘 이상입니다: ${open_urls} (하나만 남기고 닫은 뒤 다시 실행하십시오)"
      rm -f "$errf"; return 1
    elif [[ "$n_open" == 1 ]]; then
      found=OPEN
      if [[ -z "$open_base" ]]; then
        T_RESULT[$i]="실패 — gh pr list 응답에 PR 의 대상 브랜치가 없습니다 (${url})"; rm -f "$errf"; return 1
      fi
    elif [[ -n "$merged_url" ]]; then
      # 같은 이름의 팀 브랜치로 전에 merge 된 다른 PR 일 수 있습니다 — 리뷰한 커밋을 head 로 가진 PR 만 이어 받습니다.
      st="$(tp_pr_state "$merged_url")"
      mhead="$(printf '%s\n' "$st" | cut -f3)"
      if [[ "${st%%$'\t'*}" != MERGED || "$mhead" != "$head" ]]; then
        T_RESULT[$i]="멈춤 — 브랜치 ${br} 에 이전에 merge 된 다른 PR 이 있습니다 (${merged_url}, head=${mhead:-알 수 없음}, 리뷰한 커밋=${head}). team_publish.branch_prefix 를 바꿔 커밋하거나 그 PR 을 확인한 뒤 다시 실행하십시오"
        rm -f "$errf"; return 1
      fi
      found=MERGED; url="$merged_url"
    elif [[ -n "$closed_url" ]]; then
      found=CLOSED; url="$closed_url"
    else
      found=NONE
    fi
  fi

  case "$found" in
    MERGED)
      # push·생성하지 않습니다. 기록은 그대로 둡니다(state=open 유지 — merge 처리는 check --apply).
      if ! tp_record_get "$root" "$p" url >/dev/null 2>&1; then
        tp_record_upsert "$root" "$p" "$repo" "$br" "$base" "$url" "$head" open "" "" \
          || { T_RESULT[$i]="실패 — 기록 파일을 쓰지 못했습니다"; rm -f "$errf"; return 1; }
      fi
      T_RESULT[$i]="이미 merge 됨 — rd pr check --apply (${url})"
      rm -f "$errf"; return 0 ;;
    CLOSED)
      T_RESULT[$i]="멈춤 — PR 이 merge 없이 닫혔습니다 (${url}). 새 PR 을 만들지 않습니다"
      printf '%s: PR 이 merge 없이 닫혔습니다 — %s\n' "$p" "$url"
      tp_closed_choices "$slug" "$url" "$root"
      rm -f "$errf"; return 1 ;;
  esac

  # 열린 PR 의 실제 대상 브랜치가 설정과 다르면 push·본문 갱신 전에 멈춥니다(원격을 바꾸지 않음).
  if [[ "$found" == OPEN && "$open_base" != "$base" ]]; then
    printf '%s: 열린 PR 의 대상 브랜치가 설정과 다릅니다 — %s\n' "$p" "$url"
    printf '  실제 대상 브랜치: %s / 설정한 대상 브랜치: %s\n' "$open_base" "$base"
    printf '  복구 (둘 중 하나, 사람이 정합니다):\n'
    printf '    가) PR 의 대상을 설정에 맞추기: gh pr edit %s --base %s 뒤 rd pr open 을 다시 실행\n' "$url" "$base"
    printf '    나) 실제 대상 브랜치가 맞다면 설정을 그쪽으로 바꾸기: rd-workflow/config/workflow.json 의 team_publish.base (또는 submodules.%s.base) 를 %s 로 고침\n' "$p" "$open_base"
    printf '       seal 뒤 설정을 바꾸는 절차는 rd-workflow/docs/flows/WORKFLOW.md 「PR 검토 중 — 팀 저장소 반영」 절의 「seal 과 설정」 항목을 따릅니다.\n'
    T_RESULT[$i]="멈춤 — 열린 PR 의 대상 브랜치(${open_base})가 설정(${base})과 다릅니다 (${url})"
    rm -f "$errf"; return 1
  fi

  # 2) push — 팀 브랜치가 이미 있으면 리뷰한 커밋이 그 자손이어야 합니다(force push 하지 않음).
  remote_oid="$(git -C "$sub" rev-parse -q --verify "refs/remotes/origin/${br}^{commit}" 2>/dev/null)" || remote_oid=""
  if [[ -n "$remote_oid" && "$remote_oid" != "$head" ]]; then
    if ! git -C "$sub" merge-base --is-ancestor "$remote_oid" "$head" 2>/dev/null; then
      printf '%s: 팀 브랜치 %s 에 리뷰하지 않은 커밋이 있습니다 (origin/%s=%s, 리뷰한 커밋=%s)\n' "$p" "$br" "$br" "$remote_oid" "$head"
      printf '  확인: git -C %s log --oneline %s..origin/%s\n' "$p" "$head" "$br"
      printf '  복구: 그 커밋이 필요하면 submodule 에 합쳐 다시 리뷰·seal 한 뒤 rd pr open 을 다시 실행합니다.\n'
      printf '        버려도 되면 force push 여부는 사람이 정합니다: git -C %s push --force-with-lease origin %s:refs/heads/%s\n' "$p" "$head" "$br"
      T_RESULT[$i]="실패 — 팀 브랜치 ${br} 에 리뷰하지 않은 커밋이 있습니다 (non-fast-forward)"
      rm -f "$errf"; return 1
    fi
  fi
  if [[ "$remote_oid" != "$head" ]]; then
    if ! git -C "$sub" push -q origin "${head}:refs/heads/${br}" 2>"$errf"; then
      T_RESULT[$i]="실패 — push 실패: $(head -1 "$errf") (재시도: 같은 명령을 다시 실행)"
      rm -f "$errf"; return 1
    fi
  fi

  # 3) 생성 또는 본문 갱신
  if [[ "$found" == OPEN ]]; then
    rc=0; tp_gh "$_TP_GH_LIMIT" pr edit "$url" --body-file "$bodyf" >/dev/null 2>"$errf" || rc=$?
    if [[ "$rc" != 0 ]]; then
      T_RESULT[$i]="실패 — gh pr edit 실패 (${url}): $(head -1 "$errf")"; rm -f "$errf"; return 1
    fi
    T_RESULT[$i]="PR 갱신 ${url}"
  else
    rc=0
    out="$(tp_gh "$_TP_GH_LIMIT" pr create --repo "$repo" --base "$base" --head "$br" --title "$title" --body-file "$bodyf" 2>"$errf")" || rc=$?
    if [[ "$rc" != 0 ]]; then
      line="$(head -1 "$errf")"; [[ -n "$line" ]] || line="gh 가 종료 코드 ${rc} 로 끝났습니다(출력 없음)"
      T_RESULT[$i]="실패 — gh pr create 실패: ${line} (다시 실행하면 gh pr list 로 찾아 없을 때만 생성합니다)"
      rm -f "$errf"; return 1
    fi
    url="$(printf '%s\n' "$out" | grep -Eo 'https?://[^[:space:]]+' | tail -1)"
    if [[ -z "$url" ]]; then
      T_RESULT[$i]="실패 — PR 생성 결과(URL)를 받지 못했습니다 (다시 실행하면 gh pr list 로 찾아 기록합니다)"
      rm -f "$errf"; return 1
    fi
    T_RESULT[$i]="PR 생성 ${url}"
  fi
  rm -f "$errf"
  tp_record_upsert "$root" "$p" "$repo" "$br" "$base" "$url" "$head" open "" "" \
    || { T_RESULT[$i]="실패 — 원격 반영은 끝났으나 기록 파일을 쓰지 못했습니다 (${url})"; return 1; }
  return 0
}

# _tp_do_push <i> <root> — 반영 방식 push 대상 하나(fast-forward 만). 결과는 T_RESULT[i]. 실패 rc 1.
_tp_do_push() {
  local i="$1" root="$2"
  local p="${T_PATH[$i]}" head="${T_HEAD[$i]}" base="${T_BASE[$i]}" sub="$root/${T_PATH[$i]}" r errf
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpp.XXXXXX")" || { T_RESULT[$i]="실패 — 임시 파일을 만들 수 없습니다"; return 1; }
  if ! git -C "$sub" fetch -q origin 2>"$errf"; then
    T_RESULT[$i]="실패 — git fetch origin 실패: $(head -1 "$errf")"; rm -f "$errf"; return 1
  fi
  if [[ -z "$base" ]]; then
    base="$(git -C "$sub" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || base=""
    if [[ -z "$base" ]]; then
      git -C "$sub" remote set-head origin --auto >/dev/null 2>&1 || true
      base="$(git -C "$sub" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || base=""
    fi
    base="${base#origin/}"
    if [[ -z "$base" ]]; then
      T_RESULT[$i]="실패 — 대상 브랜치를 정하지 못했습니다 (origin/HEAD 없음). team_publish.submodules.${p}.base 를 설정하십시오"
      rm -f "$errf"; return 1
    fi
    T_BASE[$i]="$base"
  fi
  r="$(git -C "$sub" rev-parse -q --verify "refs/remotes/origin/${base}^{commit}" 2>/dev/null)" || r=""
  if [[ -z "$r" ]]; then
    T_RESULT[$i]="실패 — origin 에 대상 브랜치 ${base} 가 없습니다"; rm -f "$errf"; return 1
  fi
  if [[ "$r" != "$head" ]]; then
    if ! git -C "$sub" merge-base --is-ancestor "$r" "$head" 2>/dev/null; then
      printf '%s: 팀 브랜치 %s 가 리뷰한 커밋보다 앞서 있습니다 — 팀 브랜치를 되돌리는 push 는 하지 않습니다 (origin/%s=%s, 리뷰한 커밋=%s)\n' "$p" "$base" "$base" "$r" "$head"
      printf '  확인: git -C %s log --oneline %s..origin/%s\n' "$p" "$head" "$base"
      printf '  복구: submodule 을 origin/%s 위로 다시 맞추고 final diff review·seal 을 다시 거친 뒤 rd pr open 을 다시 실행합니다.\n' "$base"
      T_RESULT[$i]="실패 — 팀 브랜치 ${base} 가 리뷰한 커밋보다 앞서 있습니다 (non-fast-forward)"
      rm -f "$errf"; return 1
    fi
    if ! git -C "$sub" push -q origin "${head}:refs/heads/${base}" 2>"$errf"; then
      T_RESULT[$i]="실패 — push 실패: $(head -1 "$errf") (재시도: 같은 명령을 다시 실행)"; rm -f "$errf"; return 1
    fi
  fi
  rm -f "$errf"
  tp_record_upsert "$root" "$p" "${T_ORIGIN[$i]}" "$base" "$base" "" "$head" pushed "$head" "" \
    || { T_RESULT[$i]="실패 — push 는 끝났으나 기록 파일을 쓰지 못했습니다"; return 1; }
  T_RESULT[$i]="push 완료 ${base}"
  return 0
}

# _tp_commit <root> <git commit 인자...> — 이 명령의 lifecycle 커밋(기록·Status·포인터) 한 곳.
# archive 의 lifecycle 커밋과 같은 규약입니다(lifecycle/README.md 「pre-commit·commit-msg hook 우회」): <root> 의 현재
# 브랜치가 main·master 면 --no-verify(no-fr 작업은 기본 브랜치에 커밋합니다), RD_LIFECYCLE_BYPASS_REASON=lifecycle 은 항상.
# git commit 의 stdout 은 버리고, 우회했을 때만 우회 안내를 stdout 에 냅니다. rc 는 git commit 의 rc 입니다.
_tp_commit() {
  local root="$1" nv="" rc=0
  shift
  if ( cd "$root" && lifecycle_needs_hook_bypass ); then nv="--no-verify"; fi
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git -C "$root" commit ${nv:+"$nv"} "$@" >/dev/null || rc=$?
  [[ "$rc" == 0 ]] || return "$rc"
  if [[ -n "$nv" ]]; then ( cd "$root" && lifecycle_notify_hook_bypass "rd pr" ); fi
  return 0
}

# _tp_record_commit <root> <slug> — 기록 파일과 Status 파일을 기록 커밋으로 남깁니다(바뀐 것이 있을 때만).
_tp_record_commit() {
  local root="$1" slug="$2" f
  for f in "$RD_TEAM_PR_RECORD" "CURRENT_TASK.md" "rd-workflow-workspace/.lifecycle/task-state" "rd-workflow-workspace/.lifecycle/stage_metrics.tsv"; do
    [[ -e "$root/$f" ]] || continue
    git -C "$root" add -- "$f" 2>/dev/null || { [[ "$f" == "$RD_TEAM_PR_RECORD" ]] && return 1; }
  done
  local -a paths=() other=()
  local o
  for f in "$RD_TEAM_PR_RECORD" "CURRENT_TASK.md" "rd-workflow-workspace/.lifecycle/task-state" "rd-workflow-workspace/.lifecycle/stage_metrics.tsv"; do
    [[ -e "$root/$f" ]] && git -C "$root" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && paths+=("$f")
  done
  [[ "${#paths[@]}" -gt 0 ]] || return 0
  # 기록 경로 밖의 staged 변경은 커밋하지 않고 staged 그대로 둡니다(커밋 전에 목록만 기억).
  while IFS= read -r o; do
    [[ -n "$o" ]] || continue
    for f in "${paths[@]}"; do [[ "$o" == "$f" ]] && continue 2; done
    other+=("$o")
  done < <(git -C "$root" diff --cached --name-only 2>/dev/null)
  # 지정한 경로 중 바뀐 것이 없으면 커밋할 것이 없습니다.
  git -C "$root" diff --quiet HEAD -- "${paths[@]}" 2>/dev/null && return 0
  _tp_commit "$root" -q -m "chore(lifecycle): ${slug} 팀 저장소 반영 기록" -- "${paths[@]}" || return 1
  if [[ "${#other[@]}" -gt 0 ]]; then
    printf '%s: 기록 커밋에 넣지 않았습니다(staged 상태 그대로)\n' "$(IFS=,; printf '%s' "${other[*]}")"
  fi
  return 0
}

# _tp_tip_config <root> <tip> — 설정은 archive 게이트(D10)와 같게 작업 브랜치 끝 커밋의 workflow.json 에서 읽습니다.
# 그 파일을 임시 root(_TP_CFGROOT)에 풀어 tp_config 에 넘깁니다. 작업 worktree 의 파일이 그 커밋과 다르면
# (ignore·skip-worktree 로 미커밋 판정에 안 걸려도) rc 3 — 두 판정이 다른 설정을 보지 않게 부르는 쪽이 거부합니다.
# rc 0 성공 / 1 읽기 실패(원인 _TP_CFG_ERR) / 3 worktree 설정이 tip 과 다름(_TP_CFGROOT 는 tip 설정으로 채워 둠).
_TP_CFGROOT=""; _TP_CFG_ERR=""
_tp_tip_config() {
  local root="$1" tip="$2" wcfg same
  _TP_CFG_ERR=""
  if [[ -z "$_TP_CFGROOT" ]]; then
    _TP_CFGROOT="$(mktemp -d "${TMPDIR:-/tmp}/rd-tpcfg.XXXXXX")" || { _TP_CFGROOT=""; _TP_CFG_ERR="임시 디렉터리를 만들 수 없습니다"; return 1; }
    trap 'rm -rf "${_TP_CFGROOT:-/nonexistent}"' EXIT
  fi
  wcfg="$root/rd-workflow/config/workflow.json"
  tp_tip_config_root "$root" "$tip" "$_TP_CFGROOT" \
    || { _TP_CFG_ERR="작업 브랜치의 rd-workflow/config/workflow.json 을 읽을 수 없습니다"; return 1; }
  if [[ -e "$_TP_CFGROOT/rd-workflow/config/workflow.json" ]]; then
    cmp -s "$_TP_CFGROOT/rd-workflow/config/workflow.json" "$wcfg" && same=1 || same=0
  else
    [[ -e "$wcfg" ]] && same=0 || same=1
  fi
  [[ "$same" == 1 ]] || return 3
  return 0
}

# _tp_nofr_precheck <root> <tip> — no-fr 작업의 전제(spec D3-1). 기록·팀 원격·Status·포인터를 바꾸기 전에 부릅니다.
# 원인 줄은 stdout(dpr_archive_mode 의 판정 실패 원인은 stderr 그대로)이고 부르는 쪽이 머리말·재시도 줄을 붙입니다.
# rc 0 통과 / 1 HEAD 가 기본 브랜치가 아님(_TP_PRE_HINT 에 안내) / 2 archive_publish=pr 이거나 판정 실패.
_TP_PRE_MSG=""; _TP_PRE_HINT=""
_tp_nofr_precheck() {
  local root="$1" tip="$2" cur def mode rc
  _TP_PRE_MSG=""; _TP_PRE_HINT=""
  def="$(cd "$root" && get_default_branch 2>/dev/null)" || def=""
  cur="$(git -C "$root" symbolic-ref -q --short HEAD 2>/dev/null)" || cur=""
  if [[ -z "$def" || "$cur" != "$def" ]]; then
    _TP_PRE_MSG="fr 브랜치 없이 하는 작업은 기본 브랜치${def:+(${def})}에서 실행해야 합니다 (현재: ${cur:-detached HEAD})"
    _TP_PRE_HINT="git switch ${def:-<기본 브랜치>} 뒤 다시 실행하십시오"
    return 1
  fi
  if ! declare -F dpr_archive_mode >/dev/null; then
    source "${_TP_LC_DIR}/_direct_pr_common.sh" || { _TP_PRE_MSG="_direct_pr_common.sh 를 읽을 수 없습니다 (판정 불가)"; return 2; }
  fi
  rc=0; mode="$(dpr_archive_mode "$root" "$tip")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    _TP_PRE_MSG="archive_publish 설정을 판정할 수 없습니다 — rd-workflow/config/workflow.json 을 고쳐 커밋한 뒤 다시 실행하십시오"
    return 2
  fi
  if [[ "$mode" == pr ]]; then
    _TP_PRE_MSG="archive_publish=pr 는 fr 브랜치 작업만 지원합니다 — promote.sh 로 작업을 시작하십시오"
    return 2
  fi
  return 0
}

# _tp_target_base_or_fail <머리말> <root> <tip> <fr-branch 값> — 반영 대상 기준점(spec D2-1)을 _TP_TBASE 에, 리뷰한 끝 커밋
# (tp_reviewed_head, 대상 경로 한정용 — 비어 있을 수 있음)을 _TP_RHEAD 에 담습니다.
# tp_target_base 의 stderr(옛 마커 경고·원인·새 세션 안내)는 그대로 stderr 로 냅니다. 기준점이 전혀 없으면 spec D2-3 의
# set-base 안내를 붙입니다. rc 0 성공 / 2 정하지 못함.
_TP_TBASE=""; _TP_RHEAD=""
_tp_target_base_or_fail() {
  local pfx="$1" root="$2" tip="$3" frv="$4" errf rc=0
  _TP_TBASE=""; _TP_RHEAD=""
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tptb.XXXXXX")" || { printf '%s: 임시 파일을 만들 수 없습니다\n' "$pfx"; return 2; }
  _TP_TBASE="$(tp_target_base "$root" "$tip" "$frv" 2>"$errf")" || rc=$?
  cat "$errf" >&2
  if [[ "$rc" == 0 && -n "$_TP_TBASE" ]]; then
    rm -f "$errf"
    # 대상 경로는 리뷰한 범위로 한정합니다(tp_reviewed_head, 1순위가 아니면 빈 값). tp_target_base 가 같은 마커를 이미 검증했습니다.
    if _TP_RHEAD="$(tp_reviewed_head "$root" "$tip" 2>/dev/null)"; then return 0; fi
    printf '%s: seal 마커의 리뷰한 끝 커밋을 읽을 수 없어 반영 대상을 판정할 수 없습니다 (판정 불가)\n' "$pfx"
    _TP_TBASE=""; _TP_RHEAD=""
    return 2
  fi
  _TP_TBASE=""; _TP_RHEAD=""
  printf '%s: 반영 대상 기준점을 정할 수 없어 반영 대상을 판정할 수 없습니다 (판정 불가)\n' "$pfx"
  if grep -q '^tp_target_base: 반영 대상 기준점을 정할 수 없습니다' "$errf"; then
    printf '  기준점을 정하려면: bash rd-workflow/scripts/rd task set-base <ref> 로 리뷰한 diff 의 기준 커밋을 정하고, task-state(rd-workflow-workspace/.lifecycle/task-state)를 커밋한 뒤 다시 실행하십시오 (이 명령은 작업 브랜치 끝 커밋만 읽습니다)\n'
  fi
  rm -f "$errf"
  return 2
}

# _tp_direct_delegate <하위 명령> [인자...] — 직접 설치 PR 방식(archive_publish=pr) 작업이면 direct_pr.sh 로 넘깁니다(exec, 돌아오지 않음).
# 대상이 아니면 rc 1 로 돌아와 overlay 동작이 그대로 이어집니다.
_tp_direct_delegate() {
  local sub="$1" task="" a prev=""
  shift
  for a in "$@"; do [[ "$prev" == --task ]] && task="$a"; prev="$a"; done
  source "${_TP_LC_DIR}/_direct_pr_common.sh" || return 1
  dpr_is_direct_task "$task" >/dev/null 2>&1 || return 1
  exec bash "${_TP_LC_DIR}/direct_pr.sh" "$sub" "$@"
}

tp_cmd_open() {
  _tp_direct_delegate open "$@"
  local dry=0 approved=0 approve_push=0 a
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --approved) approved=1 ;;
      --approve-push) approve_push=1 ;;
      -h|--help) _tp_usage; return 0 ;;
      *) printf 'rd pr open: 알 수 없는 인자: %s\n' "$1" >&2; _tp_usage >&2; return 2 ;;
    esac
    shift
  done
  _TP_RETRY="bash rd-workflow/scripts/rd pr open"
  [[ "$approved" == 1 ]] && _TP_RETRY="$_TP_RETRY --approved"
  [[ "$approve_push" == 1 ]] && _TP_RETRY="$_TP_RETRY --approve-push"

  local root="$project_root" status slug fr_val bmode tip base_commit targets line p old new mode i n
  local has_pr=0 has_push=0 bodyf="" title="" first host hosts="" out rc errf def fails=0 pr_ok=0 rec_before rec_after
  local cfgroot cfg_same prc committed

  # --- 전제 (하나라도 어기면 아무것도 하지 않고 멈춤) ---
  status="$(state_read_field "status" 2>/dev/null)" || status=""
  slug="$(state_read_field "short-title" 2>/dev/null)" || slug=""
  case "$status" in
    "아카이브 보류"|"PR 검토 중") ;;
    *) _tp_fail_pre "Status 가 '아카이브 보류' 또는 'PR 검토 중' 이 아닙니다 (현재: ${status:-없음})" \
         "final diff review 를 종결하고 rd review seal 뒤 Status 를 '아카이브 보류' 로 옮기십시오"; return 1 ;;
  esac
  if [[ -z "$slug" || "$slug" == "-" ]]; then
    _tp_fail_pre "task-state 에 short-title 이 없습니다"; return 1
  fi
  fr_val="$(state_read_field "fr-branch" 2>/dev/null)" || fr_val=""
  if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
    _tp_fail_pre "작업 worktree 에 미커밋 변경이 있습니다 — 커밋하거나 정리한 뒤 다시 실행하십시오" \
      "$(git -C "$root" status --porcelain 2>/dev/null | head -5 | tr '\n' ' ')"
    return 1
  fi
  if ! bmode="$(rd_branch_mode "$fr_val" 2>/dev/null)"; then
    _tp_fail_pre "task-state fr-branch 값이 canonical 이 아닙니다: '${fr_val}'"; return 1
  fi
  if [[ "$bmode" == fr ]]; then
    tip="$(rd_resolve_commit_oid "$fr_val" 2>/dev/null)" || tip=""
  else
    tip="$(rd_resolve_commit_oid HEAD 2>/dev/null)" || tip=""
  fi
  [[ -n "$tip" ]] || { _tp_fail_pre "작업 브랜치의 커밋을 찾을 수 없습니다 (${fr_val})"; return 1; }
  if [[ "$(git -C "$root" rev-parse HEAD 2>/dev/null)" != "$tip" ]]; then
    _tp_fail_pre "작업 worktree 의 HEAD 가 작업 브랜치(${fr_val}) 끝이 아닙니다 — 그 브랜치를 체크아웃한 작업 worktree 에서 실행하십시오"; return 1
  fi
  if [[ "$bmode" == no-fr ]]; then
    prc=0; _tp_nofr_precheck "$root" "$tip" || prc=$?
    if [[ "$prc" == 1 ]]; then _tp_fail_pre "$_TP_PRE_MSG" "$_TP_PRE_HINT"; return 1; fi
    if [[ "$prc" != 0 ]]; then printf 'rd pr open: %s\n' "$_TP_PRE_MSG"; return 2; fi
  fi
  if ! rd_seal_verify "commit" "$tip" "$fr_val" 2>/dev/null; then
    _tp_fail_pre "seal 이 유효하지 않습니다 — ${RD_SEAL_FAIL_MSG:-판정 불가}"; return 1
  fi
  cfg_same=0; _tp_tip_config "$root" "$tip" || cfg_same=$?
  case "$cfg_same" in
    0) ;;
    3) _tp_fail_pre "작업 worktree 의 rd-workflow/config/workflow.json 이 작업 브랜치에 커밋된 설정과 다릅니다 — 설정을 커밋한 뒤 다시 실행하십시오" \
         "차이 확인: git diff ${tip} -- rd-workflow/config/workflow.json (skip-worktree·ignore 상태도 확인하십시오)"
       return 1 ;;
    *) _tp_fail_pre "${_TP_CFG_ERR:-작업 브랜치의 설정을 읽을 수 없습니다}"; return 1 ;;
  esac
  cfgroot="$_TP_CFGROOT"
  _tp_target_base_or_fail "rd pr open" "$root" "$tip" "$fr_val" || return 2
  base_commit="$_TP_TBASE"
  if ! targets="$(tp_targets "$root" "$base_commit" "$tip" "$_TP_RHEAD")"; then
    printf 'rd pr open: 반영 대상을 판정할 수 없습니다 (기준점=%s, tip=%s)\n' "$base_commit" "$tip"; return 2
  fi

  n=0
  while IFS=$'\t' read -r p old new; do
    [[ -n "$p" ]] || continue
    case "$new" in *[!0]*) ;; *) printf '%s: 건너뜀 (submodule 삭제)\n' "$p"; continue ;; esac
    mode="$(tp_config "$cfgroot" "$p" mode)" || { printf 'rd pr open: team_publish 설정 오류 — rd-workflow/config/workflow.json 을 고쳐 커밋한 뒤 다시 실행하십시오\n'; return 2; }
    T_PATH[$n]="$p"; T_HEAD[$n]="$new"; T_MODE[$n]="$mode"; T_REPO[$n]=""; T_RESULT[$n]=""
    T_BASE[$n]="$(tp_config "$cfgroot" "$p" base)" || return 2
    T_ORIGIN[$n]="$(git -C "$root/$p" remote get-url origin 2>/dev/null)" || T_ORIGIN[$n]=""
    case "$mode" in
      pr)   has_pr=1; a="$(tp_config "$cfgroot" "$p" branch_prefix)" || return 2; T_BRANCH[$n]="${a}${slug}" ;;
      push) has_push=1; T_BRANCH[$n]="-" ;;
      *)    T_BRANCH[$n]="-" ;;
    esac
    n=$((n + 1))
  done <<<"$targets"

  if [[ "$n" == 0 ]]; then
    printf '반영 대상 없음 — 이 작업에서 gitlink 가 바뀐 submodule 이 없습니다\n'; return 0
  fi
  tp_notice_default "$cfgroot"

  printf '경로\t저장소\t반영 방식\t대상 브랜치\t팀 브랜치\n'
  for ((i = 0; i < n; i++)); do
    a="${T_BASE[$i]}"; [[ -n "$a" ]] || a="(기본 브랜치)"
    [[ "${T_MODE[$i]}" == manual ]] && a="-"
    printf '%s\t%s\t%s\t%s\t%s\n' "${T_PATH[$i]}" "${T_ORIGIN[$i]:--}" "${T_MODE[$i]}" "$a" "${T_BRANCH[$i]}"
  done

  if [[ "$has_pr" == 0 && "$has_push" == 0 ]]; then
    for ((i = 0; i < n; i++)); do printf '%s: 건너뜀 (manual)\n' "${T_PATH[$i]}"; done
    return 0
  fi

  if [[ "$has_pr" == 1 ]]; then
    bodyf="$(mktemp "${TMPDIR:-/tmp}/rd-tp-body.XXXXXX")" || { printf 'rd pr open: 임시 파일을 만들 수 없습니다\n'; return 1; }
    # Closes 줄 경고(github-issue 형식)도 결과 출력이므로 stdout 으로 옮깁니다.
    if ! tp_extract_pr_body "$root" 2>&1 >"$bodyf"; then
      rm -f "$bodyf"
      _tp_fail_pre "PR 본문을 찾지 못했습니다 — final diff review 세션($(state_read_field review-session 2>/dev/null))의 Author 턴에 '## PR 본문' 절이 없거나 비어 있습니다" \
        "그 세션의 다음 Author 턴에 '## PR 본문' 절 전체를 싣고 커밋한 뒤 다시 실행하십시오"
      return 1
    fi
    title="$(tp_pr_title "$root" "$slug")"
  fi

  if [[ "$dry" == 1 ]]; then
    if [[ "$has_pr" == 1 ]]; then
      first="$(grep -m1 -v '^[[:space:]]*$' "$bodyf")"
      printf 'PR 제목: %s\n' "$title"
      printf 'PR 본문 첫 줄: %s\n' "$first"
      rm -f "$bodyf"
    fi
    printf '(--dry-run — 원격에 아무것도 하지 않았습니다)\n'
    return 0
  fi

  # --- 승인 (D14) ---
  rc=0
  # tp_approval_required 는 색인(git 공용 디렉터리)도 읽어 저장소 경로가 필요합니다. 설정 내용은 위에서 tip 과 같음을 확인했습니다.
  if [[ "$has_pr" == 1 && "$approved" != 1 ]] && tp_approval_required "$root" "$slug"; then
    printf '사용자 승인 대상 — 승인을 받은 뒤 --approved 를 붙여 다시 실행하십시오\n'; rc=10
  fi
  if [[ "$has_push" == 1 && "$approve_push" != 1 ]]; then
    printf '사용자 승인 대상 — 승인을 받은 뒤 --approve-push 를 붙여 다시 실행하십시오\n'; rc=10
  fi
  if [[ "$rc" == 10 ]]; then
    [[ -n "$bodyf" ]] && rm -f "$bodyf"
    return 10
  fi

  # --- 원격 전제: submodule·origin, gh 존재·인증·저장소 (fetch·push 전에 모두 확인) ---
  for ((i = 0; i < n; i++)); do
    [[ "${T_MODE[$i]}" == manual ]] && continue
    if [[ -z "${T_ORIGIN[$i]}" ]]; then
      [[ -n "$bodyf" ]] && rm -f "$bodyf"
      _tp_fail_pre "${T_PATH[$i]}: submodule 에 origin 이 없거나 초기화되지 않았습니다 (지원하지 않는 구성)" \
        "초기화: bash rd-workflow/scripts/rd submodule init ${T_PATH[$i]}"
      return 1
    fi
  done
  if [[ "$has_pr" == 1 ]]; then
    if ! command -v gh >/dev/null 2>&1; then
      rm -f "$bodyf"
      _tp_fail_pre "gh 를 찾을 수 없습니다 — GitHub CLI(gh)를 설치하고 gh auth login 으로 인증한 뒤 다시 실행하십시오"
      return 1
    fi
    errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpa.XXXXXX")" || { rm -f "$bodyf"; printf 'rd pr open: 임시 파일을 만들 수 없습니다\n'; return 1; }
    for ((i = 0; i < n; i++)); do
      [[ "${T_MODE[$i]}" == pr ]] || continue
      host="$(_tp_url_host "${T_ORIGIN[$i]}")"
      case " $hosts " in *" ${host:-<기본>} "*) continue ;; esac
      hosts="$hosts ${host:-<기본>}"
      rc=0
      if [[ -n "$host" ]]; then tp_gh "$_TP_GH_LIMIT" auth status --hostname "$host" >/dev/null 2>"$errf" || rc=$?
      else tp_gh "$_TP_GH_LIMIT" auth status >/dev/null 2>"$errf" || rc=$?; fi
      if [[ "$rc" != 0 ]]; then
        rm -f "$bodyf" "$errf"
        _tp_fail_pre "gh 인증이 되어 있지 않습니다 (호스트: ${host:-기본}) — gh auth login${host:+ --hostname $host} 뒤 다시 실행하십시오"
        return 1
      fi
    done
    for ((i = 0; i < n; i++)); do
      [[ "${T_MODE[$i]}" == pr ]] || continue
      rc=0; out="$(tp_gh "$_TP_GH_LIMIT" repo view "${T_ORIGIN[$i]}" --json nameWithOwner,defaultBranchRef 2>"$errf")" || rc=$?
      a=""; [[ "$rc" == 0 ]] && a="$(_tp_json_get "$out" 'd["nameWithOwner"]')"
      if [[ "$rc" != 0 || -z "$a" ]]; then
        first="$(head -1 "$errf")"
        rm -f "$bodyf" "$errf"
        _tp_fail_pre "지원하지 않는 원격입니다 — ${T_PATH[$i]} 의 origin(${T_ORIGIN[$i]}) 을 gh 가 GitHub 저장소로 찾지 못했습니다${first:+ ($first)}" \
          "origin 이 GitHub 저장소가 아니거나 fork 구성이면 이 submodule 은 rd pr 로 반영할 수 없습니다" \
          "${_TP_CFG_HINT[@]}"
        return 1
      fi
      host="$(_tp_url_host "${T_ORIGIN[$i]}")"
      if [[ -n "$host" && "$host" != "github.com" ]]; then T_REPO[$i]="${host}/${a}"; else T_REPO[$i]="$a"; fi
      if [[ -z "${T_BASE[$i]}" ]]; then
        def="$(_tp_json_get "$out" 'd["defaultBranchRef"]["name"]')" || def=""
        if [[ -z "$def" ]]; then
          rm -f "$bodyf" "$errf"
          _tp_fail_pre "${T_PATH[$i]}: 팀 저장소의 기본 브랜치를 알 수 없습니다 — team_publish.submodules.${T_PATH[$i]}.base 를 설정해야 합니다" \
            "설정 커밋은 이번 작업에서 bash rd-workflow/scripts/rd task set-status \"구현 중\" → 설정 커밋 → final diff review 재종결 → rd review seal 순서로 하십시오(seal 이 설정을 보호합니다)"
          return 1
        fi
        T_BASE[$i]="$def"
      fi
    done
    rm -f "$errf"
    # PR 모드의 팀 브랜치가 대상 브랜치와 같으면 push 가 PR 없이 대상 브랜치를 바로 바꿉니다. 원격을 바꾸기 전에 멈춥니다.
    for ((i = 0; i < n; i++)); do
      [[ "${T_MODE[$i]}" == pr && "${T_BRANCH[$i]}" == "${T_BASE[$i]}" ]] || continue
      rm -f "$bodyf"
      _tp_fail_pre "${T_PATH[$i]}: 팀 브랜치 ${T_BRANCH[$i]} 가 PR 대상 브랜치와 같습니다 — push 하면 PR 없이 대상 브랜치가 바뀌므로 원격을 바꾸지 않고 멈춥니다" \
        "rd-workflow/config/workflow.json 의 team_publish.branch_prefix(또는 team_publish.submodules.${T_PATH[$i]}.branch_prefix)를 대상 브랜치와 겹치지 않는 값(예: rd/)으로 설정하십시오" \
        "설정 커밋은 이번 작업에서 bash rd-workflow/scripts/rd task set-status \"구현 중\" → 설정 커밋 → final diff review 재종결 → rd review seal 순서로 하십시오(seal 이 설정을 보호합니다)"
      return 1
    done
  fi

  # --- 대상마다 반영 ---
  rec_before="absent"; [[ -f "$root/$RD_TEAM_PR_RECORD" ]] && rec_before="$(cksum <"$root/$RD_TEAM_PR_RECORD")"
  for ((i = 0; i < n; i++)); do
    case "${T_MODE[$i]}" in
      pr)
        prc=0; _tp_do_pr "$i" "$title" "$bodyf" "$root" "$slug" || prc=$?
        case "$prc" in 0) pr_ok=1 ;; 2) ;; *) fails=$((fails + 1)) ;; esac ;;
      push)
        _tp_do_push "$i" "$root" || fails=$((fails + 1)) ;;
      *) T_RESULT[$i]="건너뜀 (manual)" ;;
    esac
  done
  [[ -n "$bodyf" ]] && rm -f "$bodyf"

  printf '결과:\n'
  for ((i = 0; i < n; i++)); do printf '%s: %s\n' "${T_PATH[$i]}" "${T_RESULT[$i]}"; done

  # --- 마무리: Status · 기록 커밋 ---
  rc=0
  if [[ "$fails" == 0 && "$pr_ok" == 1 && "$status" != "PR 검토 중" ]]; then
    if ! ( cd "$root" && bash "${_TP_SD}/rd" task set-status "PR 검토 중" ) >/dev/null 2>"${TMPDIR:-/tmp}/rd-tp-ss.$$"; then
      printf 'rd pr open: Status 를 PR 검토 중 으로 옮기지 못했습니다 — %s\n' "$(head -1 "${TMPDIR:-/tmp}/rd-tp-ss.$$")"
      printf '  직접 실행: bash rd-workflow/scripts/rd task set-status "PR 검토 중"\n'
      rc=1
    fi
    rm -f "${TMPDIR:-/tmp}/rd-tp-ss.$$"
  fi
  rec_after="absent"; [[ -f "$root/$RD_TEAM_PR_RECORD" ]] && rec_after="$(cksum <"$root/$RD_TEAM_PR_RECORD")"
  committed=1
  if ! _tp_record_commit "$root" "$slug"; then
    printf 'rd pr open: 기록 커밋을 남기지 못했습니다 — %s 와 Status 파일을 직접 커밋하십시오\n' "$RD_TEAM_PR_RECORD"
    rc=1; committed=0
  fi
  [[ "$committed" == 1 && "$rec_before" != "$rec_after" ]] && printf '기록: %s 를 커밋했습니다\n' "$RD_TEAM_PR_RECORD"

  if [[ "$fails" -gt 0 ]]; then
    printf '실패 %s건 — Status 를 바꾸지 않았습니다. 원인을 해결한 뒤 다시 실행하십시오 (원격을 다시 조회해 이어 갑니다).\n' "$fails"
    printf '  재시도: %s\n' "$_TP_RETRY"
    return 1
  fi
  if [[ "$pr_ok" == 1 ]]; then
    printf '다음: PR merge 를 기다립니다 — bash rd-workflow/scripts/rd pr check\n'
  else
    printf '다음: 발행 — bash rd-workflow/scripts/rd publish request (또는 archive.sh)\n'
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# light-check (D9)
# ---------------------------------------------------------------------------
tp_cmd_light_check() {
  local base="${1:-HEAD}"
  if [[ $# -gt 1 ]]; then _tp_usage >&2; return 2; fi
  if ! git -C "$project_root" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1; then
    printf 'rd pr light-check: 커밋으로 해석할 수 없습니다: %s\n' "$base" >&2; return 2
  fi
  tp_light_check "$project_root" "$base"
}

# ---------------------------------------------------------------------------
# check (D7)
# ---------------------------------------------------------------------------

# 기록 줄 한 개를 탭마다 잘라 _RF 배열에 둡니다. 빈 칸(base="" 등)을 보존하려고 IFS 분리를 쓰지 않습니다.
_RF=()
_tp_rec_fields() {
  local rest="$1" f
  _RF=()
  while [[ "$rest" == *$'\t'* ]]; do f="${rest%%$'\t'*}"; _RF+=("$f"); rest="${rest#*$'\t'}"; done
  _RF+=("$rest")
}

# 판정 대상 평행 배열 (인덱스 같은 칸이 한 줄)
#   C_LINE 기록 줄 원문 · C_PATH·C_REPO·C_BRANCH·C_BASE·C_URL·C_H(head-oid)·C_STATE·C_MO(merged-oid)·C_K 기록 칸
#   C_VERDICT gh 판정(MERGED|CHANGES_REQUESTED|CLOSED|OPEN|ERROR, 기록 state 가 open 이 아니면 REC_<state>)
#   C_M merge 결과 · C_GHHEAD gh headRefOid · C_GHK PR 커밋 수 · C_SUMMARY 요약(오류 첫 줄·검토 의견)
#   C_HL 상위 HEAD gitlink · C_IDX 상위 index gitlink · C_SUB submodule HEAD · C_SUBDIRTY 안쪽 status
C_LINE=(); C_PATH=(); C_REPO=(); C_BRANCH=(); C_BASE=(); C_URL=(); C_H=(); C_STATE=(); C_MO=(); C_K=()
C_VERDICT=(); C_M=(); C_GHHEAD=(); C_GHK=(); C_SUMMARY=(); C_HL=(); C_IDX=(); C_SUB=(); C_SUBDIRTY=()
_TP_N=0
_TP_HEAD_REC=""

_tp_c_add() {  # <기록 줄> — _RF 를 읽어 다음 칸에 넣습니다
  local n="$_TP_N"
  C_LINE[$n]="$1"; C_PATH[$n]="${_RF[0]}"; C_REPO[$n]="${_RF[1]}"; C_BRANCH[$n]="${_RF[2]}"; C_BASE[$n]="${_RF[3]}"
  C_URL[$n]="${_RF[4]}"; C_H[$n]="${_RF[5]}"; C_STATE[$n]="${_RF[6]}"; C_MO[$n]="${_RF[7]}"; C_K[$n]="${_RF[8]}"
  C_VERDICT[$n]=""; C_M[$n]=""; C_GHHEAD[$n]=""; C_GHK[$n]=""; C_SUMMARY[$n]=""
  C_HL[$n]=""; C_IDX[$n]=""; C_SUB[$n]=""; C_SUBDIRTY[$n]=""
  _TP_N=$((n + 1))
}

# _tp_c_query <i> — 기록 state=open 이면 gh 로 판정을 받습니다. 그 밖은 기록 state 를 판정으로 씁니다.
_tp_c_query() {
  local i="$1" st
  if [[ "${C_STATE[$i]}" != open ]]; then
    C_VERDICT[$i]="REC_${C_STATE[$i]}"; return 0
  fi
  st="$(tp_pr_state "${C_URL[$i]}")"
  # 빈 칸이 이어지므로 read 가 아니라 cut 으로 자릅니다(탭은 IFS 공백이라 빈 칸이 합쳐집니다).
  C_VERDICT[$i]="$(printf '%s\n' "$st" | cut -f1)"
  C_M[$i]="$(printf '%s\n' "$st" | cut -f2)"
  C_GHHEAD[$i]="$(printf '%s\n' "$st" | cut -f3)"
  C_GHK[$i]="$(printf '%s\n' "$st" | cut -f4)"
  C_SUMMARY[$i]="$(printf '%s\n' "$st" | cut -f5-)"
  [[ "${C_VERDICT[$i]}" == MERGED ]] || C_M[$i]=""
}

# _tp_c_row <i> <all-merged 0|1|2> <slug> <root> — 2 는 모두 merge 됐지만 대상 판정에 실패해 --apply 를 안내하지 않습니다.
# 출력 줄 `<경로>\t<PR URL>\t<판정>\t<남은 행동>` (닫힘은 선택지 줄이 뒤따름)
_tp_c_row() {
  local i="$1" allm="$2" slug="$3" root="$4" v act url="${C_URL[$i]:--}"
  case "${C_VERDICT[$i]}" in
    MERGED)
      v="merge 됨"
      case "$allm" in
        1) act="bash rd-workflow/scripts/rd pr check --apply" ;;
        2) act="아래 대상 판정 실패를 먼저 해결해야 rd pr check --apply 가 진행됩니다" ;;
        *) act="다른 PR 의 merge 를 기다립니다" ;;
      esac ;;
    REC_merged) v="merge 됨"; act="반영 완료 — 포인터를 옮겼습니다" ;;
    CHANGES_REQUESTED) v="수정 요청"; act="${C_SUMMARY[$i]:-(의견 없음)} / 고치려면 bash rd-workflow/scripts/rd task set-status \"구현 중\"" ;;
    CLOSED|REC_closed) v="닫힘"; act="PR 이 merge 없이 닫혔습니다 — 아래 선택지에서 사람이 정합니다" ;;
    OPEN) v="검토 중"; act="-" ;;
    REC_pushed) v="push 완료"; act="-" ;;
    ERROR) v="조회 실패"; act="${C_SUMMARY[$i]:-gh 조회에 실패했습니다}" ;;
    *) v="조회 실패"; act="기록 state 를 알 수 없습니다: ${C_STATE[$i]}" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "${C_PATH[$i]}" "$url" "$v" "$act"
  case "${C_VERDICT[$i]}" in CLOSED|REC_closed) tp_closed_choices "$slug" "$url" "$root" ;; esac
}

# _tp_check_report — `rd pr check` (조회만). 작업 worktree 의 기록 파일을 읽습니다. Status 를 바꾸지 않습니다.
_tp_check_report() {
  local root="$project_root" slug f line i allm=1 tip base_commit targets p old new seen=" " cfgok=0 frv rhead terr cause tail_out=""
  slug="$(state_read_field "short-title" 2>/dev/null)" || slug=""
  f="$root/$RD_TEAM_PR_RECORD"
  _TP_N=0
  if [[ -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ -n "$line" ]] || continue
      _tp_rec_fields "$line"
      [[ "${_RF[0]}" == path && "${_RF[1]-}" == repo ]] && continue
      [[ "${#_RF[@]}" -ge 9 ]] || continue
      _tp_c_add "$line"
    done <"$f"
  fi
  for ((i = 0; i < _TP_N; i++)); do
    _tp_c_query "$i"
    seen="${seen}${C_PATH[$i]} "
    [[ "${C_STATE[$i]}" == open && "${C_VERDICT[$i]}" != MERGED ]] && allm=0
  done
  # 기록이 없고 gitlink 가 바뀐 submodule 중 반영 방식 manual 인 것은 반영하지 않는 대상입니다(설정은 작업 브랜치 끝 커밋 기준).
  tip="$(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null)" || tip=""
  if [[ -n "$tip" ]]; then
    _tp_tip_config "$root" "$tip" && cfgok=1
    [[ "$?" == 3 ]] && cfgok=1
    # 기준점은 open·apply 와 같은 반영 대상 기준점(spec D2-1)입니다.
    frv="$(state_read_field "fr-branch" 2>/dev/null)" || frv=""
    # 기준점·리뷰한 끝을 정하지 못하면 --apply 가 rc 2 로 멈추므로 대상 판정 실패와 같이 원인·복구를 보입니다.
    terr="$(mktemp "${TMPDIR:-/tmp}/rd-tpck.XXXXXX")" || terr=/dev/null
    rhead=""
    if ! base_commit="$(tp_target_base "$root" "$tip" "$frv" 2>"$terr")" || [[ -z "$base_commit" ]]; then
      base_commit=""; cause="$(tp_base_fail_line "$terr")"
    elif ! rhead="$(tp_reviewed_head "$root" "$tip" 2>/dev/null)"; then
      base_commit=""; cause="seal 마커의 리뷰한 끝 커밋을 읽을 수 없습니다 / 복구: ${_TP_NEW_SESSION_HINT}"
    fi
    if [[ -z "$base_commit" ]]; then
      tail_out="${tail_out}$(printf -- '-\t-\t대상 판정 실패\t%s' "$cause")"$'\n'
      if [[ "$allm" == 1 ]]; then allm=2; fi
    fi
    if [[ "$cfgok" == 1 && -n "$base_commit" ]]; then
      # 대상 판정 실패를 빈 대상처럼 숨기지 않습니다 — 원인과 함께 한 줄로 보입니다(PR 기록 행은 위에 그대로).
      if targets="$(tp_targets "$root" "$base_commit" "$tip" "$rhead" 2>"$terr")"; then
        while IFS=$'\t' read -r p old new; do
          [[ -n "$p" ]] || continue
          case "$seen" in *" ${p} "*) continue ;; esac
          [[ "$(tp_config "$_TP_CFGROOT" "$p" mode 2>/dev/null)" == manual ]] || continue
          tail_out="${tail_out}$(printf '%s\t-\t반영하지 않음\tteam_publish.mode 가 manual 입니다' "$p")"$'\n'
        done <<<"$targets"
      else
        cause="$(sed -n 1p "$terr" 2>/dev/null)"; cause="${cause#tp_targets: }"
        tail_out="${tail_out}$(printf -- '-\t-\t대상 판정 실패\t%s' "${cause:-gitlink 비교에 실패했습니다}")"$'\n'
        # 판정에 실패하면 --apply 가 rc 2 로 멈추므로 merge 된 PR 행도 --apply 를 안내하지 않습니다.
        if [[ "$allm" == 1 ]]; then allm=2; fi
      fi
    fi
    [[ "$terr" == /dev/null ]] || rm -f "$terr"
  fi
  printf '경로\tPR URL\t판정\t남은 행동\n'
  for ((i = 0; i < _TP_N; i++)); do _tp_c_row "$i" "$allm" "$slug" "$root"; done
  printf '%s' "$tail_out"
  [[ "$_TP_N" -gt 0 ]] || printf '(PR 기록 없음 — %s 이 없습니다. 반영은 bash rd-workflow/scripts/rd pr open)\n' "$RD_TEAM_PR_RECORD"
  return 0
}

_tp_apply_fail() {  # <원인> [추가 줄...] — 바꾸기 전 멈춤. rc 1 은 부르는 쪽이 냅니다.
  printf 'rd pr check --apply: %s\n' "$1"
  shift
  local l; for l in "$@"; do printf '  %s\n' "$l"; done
}

# _tp_result_line <i> — 1단계가 쓰는 기록 줄(state=merged, merged-oid=M, commits=k)
_tp_result_line() {
  local i="$1"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "${C_PATH[$i]}" "${C_REPO[$i]}" "${C_BRANCH[$i]}" "${C_BASE[$i]}" \
    "${C_URL[$i]}" "${C_H[$i]}" merged "${C_M[$i]}" "${C_GHK[$i]}"
}

# _tp_rec_ok <내용> — HEAD 기록과 줄마다 같거나, apply 대상 줄만 1단계 결과 줄로 바뀐 내용이면 rc 0.
# 줄이 더해지거나 빠지거나 다른 값이면 rc 1 (손으로 고친 기록을 apply 의 흔적으로 보지 않습니다).
_tp_rec_ok() {
  local content="$1" a j i hit
  local -a hl cl
  while IFS= read -r a; do hl+=("$a"); done <<<"$_TP_HEAD_REC"
  while IFS= read -r a; do cl+=("$a"); done <<<"$content"
  [[ "${#hl[@]}" == "${#cl[@]}" ]] || return 1
  for ((j = 0; j < ${#hl[@]}; j++)); do
    [[ "${hl[$j]}" == "${cl[$j]}" ]] && continue
    hit=0
    for ((i = 0; i < _TP_N; i++)); do
      if [[ "${hl[$j]}" == "${C_LINE[$i]}" && -n "${C_M[$i]}" && "${cl[$j]}" == "$(_tp_result_line "$i")" ]]; then hit=1; break; fi
    done
    [[ "$hit" == 1 ]] || return 1
  done
  return 0
}

# _tp_other_changes <root> — apply 대상 gitlink·기록 파일 밖의 상위 index·워킹트리 변경(porcelain 줄)
_tp_other_changes() {
  local root="$1" l p i skip
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    p="${l:3}"
    skip=0
    [[ "$p" == "$RD_TEAM_PR_RECORD" ]] && skip=1
    for ((i = 0; i < _TP_N; i++)); do [[ "$p" == "${C_PATH[$i]}" ]] && skip=1; done
    [[ "$skip" == 1 ]] || printf '%s\n' "$l"
  done <<EOF_OC
$(git -C "$root" -c core.quotepath=false status --porcelain --untracked-files=all 2>/dev/null)
EOF_OC
}

# _tp_apply_rollback <root> — 1~2 단계(또는 이전 실행이 남긴 흔적)를 되돌립니다 (spec D7 3단계).
# (1) 상위 index 를 HEAD 로 (2) HEAD 가 head-oid 가 아니거나 안쪽이 바뀐 submodule 을 head-oid 로 (3) 기록 파일을 HEAD 로.
# 되돌린 뒤 상위 status 가 비어 있어야 합니다(실행 전에 비어 있었음). 아니면 남은 상태와 세 명령을 보이고 rc 1.
_tp_apply_rollback() {
  local root="$1" i p sub cur bad=0 errf after u
  local -a paths=() unexp=()
  for ((i = 0; i < _TP_N; i++)); do paths+=("${C_PATH[$i]}"); done
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tprb.XXXXXX")" || errf=/dev/null
  printf '되돌립니다 — 상위 index·submodule·기록 파일을 HEAD 상태로 돌립니다\n'
  git -C "$root" reset -q HEAD -- "${paths[@]}" "$RD_TEAM_PR_RECORD" >/dev/null 2>"$errf" \
    || { bad=1; printf '  실패: git reset — %s\n' "$(head -1 "$errf")"; }
  for ((i = 0; i < _TP_N; i++)); do
    p="${C_PATH[$i]}"; sub="$root/$p"
    cur="$(git -C "$sub" rev-parse -q --verify HEAD 2>/dev/null)" || cur=""
    if [[ -n "$cur" && "$cur" != "${C_H[$i]}" && "$cur" != "${C_M[$i]}" ]]; then
      # HEAD 가 리뷰한 커밋(H)도 merge 결과(M)도 아니면 실행 도중 다른 쪽이 만든 커밋입니다.
      # 옮기면 그 커밋의 파일이 작업 폴더에서 사라지므로 HEAD 를 그대로 두고 아래 안내로 넘깁니다.
      bad=1; unexp+=("$i:$cur")
      printf '  그대로 둠: %s 의 HEAD %s 는 이 명령이 옮긴 커밋이 아닙니다\n' "$p" "$cur"
    elif [[ "$cur" != "${C_H[$i]}" || -n "$(git -C "$sub" status --porcelain 2>/dev/null)" ]]; then
      # -f 를 쓰지 않습니다. 실행 도중 사용자·hook·다른 프로세스가 만든 편집은 이 명령의 것이 아니므로,
      # git 이 덮어쓰기를 거부하면 지우지 않고 남겨 둔 채 아래 「남은 상태」 안내로 넘깁니다 (spec D7 3단계).
      if git -C "$sub" checkout -q --detach "${C_H[$i]}" >/dev/null 2>"$errf"; then
        printf '  되돌림: %s → %s\n' "$p" "${C_H[$i]}"
      else
        bad=1; printf '  실패: %s 를 %s 로 되돌리지 못했습니다 — %s\n' "$p" "${C_H[$i]}" "$(head -1 "$errf")"
      fi
    fi
  done
  git -C "$root" checkout HEAD -- "$RD_TEAM_PR_RECORD" >/dev/null 2>"$errf" \
    || { bad=1; printf '  실패: 기록 파일 되돌림 — %s\n' "$(head -1 "$errf")"; }
  [[ "$errf" != /dev/null ]] && rm -f "$errf"
  after="$(git -C "$root" status --porcelain 2>/dev/null)"
  if [[ "$bad" == 0 && -z "$after" ]]; then
    printf '되돌렸습니다 — 원인을 해결한 뒤 같은 명령을 다시 실행할 수 있습니다: %s\n' "$_TP_RETRY"
    return 0
  fi
  printf '되돌리기를 끝내지 못했습니다. 남은 상태:\n'
  printf '%s\n' "$after" | sed 's/^/    /'
  for u in ${unexp[@]+"${unexp[@]}"}; do
    i="${u%%:*}"
    printf '  %s 의 HEAD %s 는 리뷰한 커밋(%s)도 merge 결과(%s)도 아니어서 옮기지 않았습니다. 그 커밋이 필요하면 먼저 브랜치로 남기십시오: git -C %s branch <이름> %s\n' \
      "${C_PATH[$i]}" "${u#*:}" "${C_H[$i]}" "${C_M[$i]}" "${C_PATH[$i]}" "${u#*:}"
  done
  for ((i = 0; i < _TP_N; i++)); do
    [[ -n "$(git -C "$root/${C_PATH[$i]}" status --porcelain 2>/dev/null)" ]] || continue
    printf '  %s 안쪽 변경은 이 명령이 만들지 않았을 수 있어 지우지 않았습니다. 필요한 변경이면 다른 곳에 옮기거나 커밋한 뒤 아래를 실행하십시오:\n' "${C_PATH[$i]}"
    git -C "$root/${C_PATH[$i]}" status --porcelain 2>/dev/null | head -5 | sed 's/^/      /'
  done
  printf '  직접 되돌리십시오 (순서대로):\n'
  printf '    git reset -q HEAD --'; for p in "${paths[@]}"; do printf ' %s' "$p"; done; printf ' %s\n' "$RD_TEAM_PR_RECORD"
  for ((i = 0; i < _TP_N; i++)); do printf '    git -C %s checkout --detach %s\n' "${C_PATH[$i]}" "${C_H[$i]}"; done
  printf '    git checkout HEAD -- %s\n' "$RD_TEAM_PR_RECORD"
  return 1
}

# set-status 가 쓰는 파일 (포인터 커밋 완료 상태의 clean 예외·4b 커밋 대상)
_TP_STATUS_FILES=("rd-workflow-workspace/.lifecycle/task-state" "CURRENT_TASK.md" "rd-workflow-workspace/.lifecycle/stage_metrics.tsv")

# _tp_apply_finish <root> <slug> <fr> — 4~6 단계. 각 단계는 다시 실행해도 결과가 같습니다.
_tp_apply_finish() {
  local root="$1" slug="$2" fr_val="$3" errf f
  local -a files=()
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpst4.XXXXXX")" || { printf 'rd pr check --apply: 임시 파일을 만들 수 없습니다\n'; return 1; }
  # 4a — 이미 아카이브 보류여도 같은 값으로 다시 불러 미러(CURRENT_TASK.md)를 다시 씁니다.
  if ! ( cd "$root" && bash "${_TP_SD}/rd" task set-status "아카이브 보류" ) >/dev/null 2>"$errf"; then
    printf '포인터 이동 완료 — 다시 rd pr check --apply 를 실행하면 Status 정리부터 이어 갑니다\n'
    printf '  Status 를 아카이브 보류 로 옮기지 못했습니다: %s\n' "$(head -1 "$errf")"
    rm -f "$errf"; return 1
  fi
  # 4b — HEAD 와 다를 때만 커밋합니다(재실행이 빈 커밋·중복 커밋을 만들지 않음).
  for f in "${_TP_STATUS_FILES[@]}"; do
    [[ -e "$root/$f" ]] || git -C "$root" cat-file -e "HEAD:$f" 2>/dev/null || continue
    files+=("$f")
  done
  if [[ "${#files[@]}" -gt 0 && -n "$(git -C "$root" status --porcelain -- "${files[@]}" 2>/dev/null)" ]]; then
    if ! { git -C "$root" add -A -- "${files[@]}" 2>"$errf" \
           && _tp_commit "$root" -q -m "chore(lifecycle): ${slug} 팀 PR merge 반영 뒤 Status 아카이브 보류" -- "${files[@]}" 2>"$errf"; }; then
      printf '포인터 이동 완료 — 다시 rd pr check --apply 를 실행하면 Status 정리부터 이어 갑니다\n'
      printf '  Status 커밋 실패: %s\n' "$(grep -v '^[[:space:]]*$' "$errf" | head -1)"
      rm -f "$errf"; return 1
    fi
  fi
  rm -f "$errf"
  # 5 — seal 이 치환 규칙(spec 3.1)으로 유효해야 합니다.
  if ! rd_seal_verify "commit" "HEAD" "$fr_val" 2>/dev/null; then
    printf 'rd pr check --apply: 포인터를 옮긴 뒤 seal 이 유효하지 않습니다 — %s\n' "${RD_SEAL_FAIL_MSG:-판정 불가}"
    return 1
  fi
  printf '발행 준비 완료 — bash rd-workflow/scripts/rd publish request 로 발행을 요청하십시오\n'
  return 0
}

_tp_rereview_hint() {
  printf '  다시 리뷰하려면: bash rd-workflow/scripts/rd task set-status "구현 중" → submodule 포인터를 merge 된 커밋으로 옮김 → final diff review 이어 종결 → rd review seal → 아카이브 보류 → 발행\n'
}

# _tp_apply — `rd pr check --apply` (spec D7). 진행 상태 판정 → 선행 조건 → 0~6 단계.
_tp_apply() {
  local root="$project_root" status slug fr_val bmode tip cfgrc base_commit targets line i p old new mode found
  local done_all intr trace first wtc ixc others notready errf why pre l k f h m
  local -a paths=()
  _TP_RETRY="bash rd-workflow/scripts/rd pr check --apply"

  status="$(state_read_field "status" 2>/dev/null)" || status=""
  slug="$(state_read_field "short-title" 2>/dev/null)" || slug=""
  [[ -n "$slug" && "$slug" != "-" ]] || { _tp_apply_fail "task-state 에 short-title 이 없습니다"; return 1; }
  fr_val="$(state_read_field "fr-branch" 2>/dev/null)" || fr_val=""
  if ! bmode="$(rd_branch_mode "$fr_val" 2>/dev/null)"; then
    _tp_apply_fail "task-state fr-branch 값이 canonical 이 아닙니다: '${fr_val}'"; return 1
  fi
  if [[ "$bmode" == fr ]]; then tip="$(rd_resolve_commit_oid "$fr_val" 2>/dev/null)" || tip=""
  else tip="$(rd_resolve_commit_oid HEAD 2>/dev/null)" || tip=""; fi
  [[ -n "$tip" ]] || { _tp_apply_fail "작업 브랜치의 커밋을 찾을 수 없습니다 (${fr_val})"; return 1; }
  if [[ "$(git -C "$root" rev-parse HEAD 2>/dev/null)" != "$tip" ]]; then
    _tp_apply_fail "작업 worktree 의 HEAD 가 작업 브랜치(${fr_val}) 끝이 아닙니다 — 그 브랜치를 체크아웃한 작업 worktree 에서 실행하십시오"; return 1
  fi
  if [[ "$bmode" == no-fr ]]; then
    k=0; _tp_nofr_precheck "$root" "$tip" || k=$?
    if [[ "$k" == 1 ]]; then _tp_apply_fail "$_TP_PRE_MSG" "$_TP_PRE_HINT"; return 1; fi
    if [[ "$k" != 0 ]]; then _tp_apply_fail "$_TP_PRE_MSG"; return 2; fi
  fi
  cfgrc=0; _tp_tip_config "$root" "$tip" || cfgrc=$?
  case "$cfgrc" in
    0) ;;
    3) _tp_apply_fail "작업 worktree 의 rd-workflow/config/workflow.json 이 작업 브랜치에 커밋된 설정과 다릅니다 — 설정을 커밋한 뒤 다시 실행하십시오"; return 1 ;;
    *) _tp_apply_fail "${_TP_CFG_ERR:-작업 브랜치의 설정을 읽을 수 없습니다}"; return 1 ;;
  esac
  _tp_target_base_or_fail "rd pr check --apply" "$root" "$tip" "$fr_val" || return 2
  base_commit="$_TP_TBASE"
  if ! targets="$(tp_targets "$root" "$base_commit" "$tip" "$_TP_RHEAD")"; then
    _tp_apply_fail "반영 대상을 판정할 수 없습니다 (기준점=${base_commit})"; return 2
  fi

  # 분류의 기준 기록은 상위 HEAD 커밋의 기록 파일입니다. apply 대상은 그중 반영 방식 pr 인 줄입니다(push·manual 은 손대지 않음).
  _TP_HEAD_REC="$(git -C "$root" show "HEAD:${RD_TEAM_PR_RECORD}" 2>/dev/null)" || {
    _tp_apply_fail "PR 기록이 없습니다 (${RD_TEAM_PR_RECORD}) — 먼저 bash rd-workflow/scripts/rd pr open"; return 1; }
  _TP_N=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    _tp_rec_fields "$line"
    [[ "${_RF[0]}" == path && "${_RF[1]-}" == repo ]] && continue
    [[ "${#_RF[@]}" -ge 9 ]] || { _tp_apply_fail "기록 줄 형식이 아닙니다: ${line}"; return 2; }
    mode="$(tp_config "$_TP_CFGROOT" "${_RF[0]}" mode)" || { _tp_apply_fail "team_publish 설정 오류 — rd-workflow/config/workflow.json 을 고쳐 커밋하십시오"; return 2; }
    [[ "$mode" == pr ]] || continue
    _tp_c_add "$line"
  done <<<"$_TP_HEAD_REC"
  while IFS=$'\t' read -r p old new; do
    [[ -n "$p" ]] || continue
    case "$new" in *[!0]*) ;; *) continue ;; esac
    mode="$(tp_config "$_TP_CFGROOT" "$p" mode)" || return 2
    [[ "$mode" == pr ]] || continue
    found=0; for ((i = 0; i < _TP_N; i++)); do [[ "${C_PATH[$i]}" == "$p" ]] && found=1; done
    [[ "$found" == 1 ]] || { _tp_apply_fail "${p}: 반영 방식 pr 인데 PR 기록이 없습니다 — 먼저 bash rd-workflow/scripts/rd pr open"; return 1; }
  done <<<"$targets"
  # 반대 방향 — PR 기록이 있는데 그 경로가 이번 반영 대상(리뷰한 범위)에 없으면 아무것도 바꾸기 전에 멈춥니다.
  #   앞선 리뷰 범위에서 올린 PR 기록이 남은 채 새 범위로 seal 하면, 리뷰하지 않은 포인터 이동이 이 기록으로 커밋됩니다.
  #   포인터를 옮긴 뒤 다시 실행해도 그 경로는 대상에 남으므로(tip 값 ≠ 기준점 값) 이어 가기는 막지 않습니다.
  why=""
  for ((i = 0; i < _TP_N; i++)); do
    found=0
    while IFS=$'\t' read -r p old new; do [[ -n "$p" && "$p" == "${C_PATH[$i]}" ]] && found=1; done <<<"$targets"
    [[ "$found" == 1 ]] || why="${why}${C_PATH[$i]} (${C_URL[$i]:--})"$'\n'
  done
  if [[ -n "$why" ]]; then
    _tp_apply_fail "PR 기록의 경로가 이번 반영 대상(리뷰한 범위)에 없습니다 — 포인터를 옮기지 않습니다"
    while IFS= read -r l; do [[ -n "$l" ]] && printf '  - %s\n' "$l"; done <<<"$why"
    printf '  그 PR 을 이 작업에서 반영하지 않으려면: %s 에서 그 경로의 줄을 지우고 커밋한 뒤 bash rd-workflow/scripts/rd pr check --apply 를 다시 실행하십시오(남은 pr 기록이 없으면 bash rd-workflow/scripts/rd task set-status "아카이브 보류")\n' "$RD_TEAM_PR_RECORD"
    printf '  그 경로를 반영하려면 그 경로의 변경을 포함한 범위로 다시 리뷰하십시오 — bash rd-workflow/scripts/rd task set-status "구현 중" 뒤 %s\n' "$_TP_NEW_SESSION_HINT"
    return 1
  fi
  if [[ "$_TP_N" == 0 ]]; then
    printf 'apply 대상 없음 — 반영 방식 pr 인 PR 기록이 없습니다\n'; return 0
  fi
  for ((i = 0; i < _TP_N; i++)); do
    p="${C_PATH[$i]}"; paths+=("$p")
    C_HL[$i]="$(git -C "$root" rev-parse -q --verify "HEAD:${p}" 2>/dev/null)" || C_HL[$i]=""
    C_IDX[$i]="$(git -C "$root" ls-files -s -- "$p" 2>/dev/null | awk '$1 == "160000" && $3 == "0" {print $2; exit}')"
    C_SUB[$i]="$(git -C "$root/$p" rev-parse -q --verify HEAD 2>/dev/null)" || C_SUB[$i]=""
    C_SUBDIRTY[$i]="$(git -C "$root/$p" status --porcelain 2>/dev/null)"
  done

  # --- 진행 상태 판정 1: 포인터 커밋 완료 (gh 없이 HEAD 기록만 봅니다) ---
  done_all=1
  for ((i = 0; i < _TP_N; i++)); do
    [[ "${C_STATE[$i]}" == merged && -n "${C_MO[$i]}" && "${C_HL[$i]}" == "${C_MO[$i]}" ]] || done_all=0
  done
  if [[ "$done_all" == 1 ]]; then
    case "$status" in
      "PR 검토 중"|"아카이브 보류") ;;
      *) _tp_apply_fail "Status 가 'PR 검토 중' 또는 '아카이브 보류' 가 아닙니다 (현재: ${status:-없음})"; return 1 ;;
    esac
    if ! rd_seal_verify "commit" "$tip" "$fr_val" 2>/dev/null; then
      _tp_apply_fail "seal 이 유효하지 않습니다 — ${RD_SEAL_FAIL_MSG:-판정 불가}"; return 1
    fi
    others=""
    while IFS= read -r l; do
      [[ -n "$l" ]] || continue
      p="${l:3}"; k=0
      for f in "${_TP_STATUS_FILES[@]}"; do [[ "$p" == "$f" ]] && k=1; done
      [[ "$k" == 1 ]] || others="${others}${l}"$'\n'
    done <<EOF_PD
$(git -C "$root" -c core.quotepath=false status --porcelain --untracked-files=all 2>/dev/null)
EOF_PD
    if [[ -n "$others" ]]; then
      _tp_apply_fail "작업 worktree 에 미커밋 변경이 있습니다 — 커밋하거나 정리한 뒤 다시 실행하십시오" \
        "$(printf '%s' "$others" | head -5 | tr '\n' ' ')"
      return 1
    fi
    printf '포인터 커밋은 이미 끝났습니다 — Status 정리부터 이어 갑니다\n'
    _tp_apply_finish "$root" "$slug" "$fr_val"
    return $?
  fi

  # --- 선행 조건: Status · seal ---
  if [[ "$status" != "PR 검토 중" ]]; then
    _tp_apply_fail "Status 가 'PR 검토 중' 이 아닙니다 (현재: ${status:-없음})"; return 1
  fi
  if ! rd_seal_verify "commit" "$tip" "$fr_val" 2>/dev/null; then
    _tp_apply_fail "seal 이 유효하지 않습니다 — ${RD_SEAL_FAIL_MSG:-판정 불가}"; return 1
  fi
  for ((i = 0; i < _TP_N; i++)); do _tp_c_query "$i"; done

  # --- 진행 상태 판정 2: 중단 흔적 / 3: 처음 / 4: 그 밖 ---
  wtc="$(cat "$root/$RD_TEAM_PR_RECORD" 2>/dev/null)" || wtc=""
  ixc="$(git -C "$root" show ":${RD_TEAM_PR_RECORD}" 2>/dev/null)" || ixc=""
  others="$(_tp_other_changes "$root")"
  intr=1; trace=0; first=1
  for ((i = 0; i < _TP_N; i++)); do
    h="${C_H[$i]}"; m="${C_M[$i]}"
    [[ "${C_STATE[$i]}" == open && "${C_HL[$i]}" == "$h" ]] || { intr=0; first=0; }
    [[ "${C_IDX[$i]}" == "$h" && "${C_SUB[$i]}" == "$h" ]] || first=0
    if [[ "${C_SUB[$i]}" == "$h" ]]; then :
    elif [[ -n "$m" && "${C_SUB[$i]}" == "$m" ]]; then trace=1
    else intr=0; fi
    [[ -z "${C_SUBDIRTY[$i]}" ]] || intr=0
    if [[ "${C_IDX[$i]}" == "$h" ]]; then :
    elif [[ -n "$m" && "${C_IDX[$i]}" == "$m" ]]; then trace=1; [[ "${C_SUB[$i]}" == "$m" ]] || intr=0
    else intr=0; fi
  done
  [[ "$wtc" == "$_TP_HEAD_REC" && "$ixc" == "$_TP_HEAD_REC" ]] || { first=0; trace=1; }
  _tp_rec_ok "$wtc" && _tp_rec_ok "$ixc" || intr=0
  [[ -z "$others" ]] || intr=0
  [[ "$trace" == 1 ]] || intr=0
  if [[ "$intr" != 1 && "$first" != 1 ]]; then
    _tp_apply_fail "진행 상태를 판정할 수 없어 아무것도 바꾸지 않았습니다 (처음 상태도, 이전 --apply 가 남긴 흔적도 아닙니다)"
    for ((i = 0; i < _TP_N; i++)); do
      printf '  %s: 기록 state=%s head-oid=%s · 상위 HEAD gitlink=%s · index gitlink=%s · submodule HEAD=%s · merge 결과=%s%s\n' \
        "${C_PATH[$i]}" "${C_STATE[$i]}" "${C_H[$i]}" "${C_HL[$i]:-없음}" "${C_IDX[$i]:-없음}" "${C_SUB[$i]:-없음}" \
        "${C_M[$i]:-모름}" "${C_SUBDIRTY[$i]:+ · 안쪽 변경 있음}"
    done
    [[ "$wtc" == "$_TP_HEAD_REC" ]] || printf '  기록 파일(워킹트리)이 HEAD 와 다릅니다: %s\n' "$RD_TEAM_PR_RECORD"
    [[ "$ixc" == "$_TP_HEAD_REC" ]] || printf '  기록 파일(index)이 HEAD 와 다릅니다: %s\n' "$RD_TEAM_PR_RECORD"
    [[ -z "$others" ]] || printf '  그 밖 경로의 변경:\n%s\n' "$(printf '%s\n' "$others" | sed 's/^/    /')"
    printf '  이 변경을 정리한 뒤 다시 실행하십시오\n'
    return 1
  fi

  # --- 선행 조건: 모든 pr 줄 merge 됨 ---
  notready=0
  for ((i = 0; i < _TP_N; i++)); do [[ "${C_VERDICT[$i]}" == MERGED && -n "${C_M[$i]}" ]] || notready=1; done
  if [[ "$notready" == 1 ]]; then
    printf '경로\tPR URL\t판정\t남은 행동\n'
    for ((i = 0; i < _TP_N; i++)); do _tp_c_row "$i" 0 "$slug" "$root"; done
    printf '모든 PR 이 merge 되지 않아 포인터를 옮기지 않았습니다 — Status 는 PR 검토 중 그대로입니다\n'
    return 1
  fi

  # --- 선행 조건: merge 결과 객체 · 보존 판정 (0단계) ---
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpck.XXXXXX")" || { _tp_apply_fail "임시 파일을 만들 수 없습니다"; return 1; }
  for ((i = 0; i < _TP_N; i++)); do
    [[ -n "${C_M[$i]}" ]] || continue
    p="${C_PATH[$i]}"
    if ! git -C "$root/$p" cat-file -e "${C_M[$i]}^{commit}" 2>/dev/null; then
      git -C "$root/$p" fetch -q origin 2>"$errf" || true
      if ! git -C "$root/$p" cat-file -e "${C_M[$i]}^{commit}" 2>/dev/null; then
        why="$(head -1 "$errf" 2>/dev/null)"; rm -f "$errf"
        _tp_apply_fail "${p}: merge 결과 ${C_M[$i]} 를 받지 못했습니다 (판정 불가)${why:+ — $why}" \
          "확인: git -C ${p} fetch origin 뒤 다시 실행하십시오"
        return 1
      fi
    fi
    why="$(tp_preserved "$root/$p" "${C_M[$i]}" "${C_H[$i]}" "${C_GHHEAD[$i]}" "${C_GHK[$i]}")" && continue
    rm -f "$errf"
    case "$why" in
      head-mismatch)   why="merge 된 PR 에 리뷰 뒤 더해진 커밋이 있습니다 (gh head=${C_GHHEAD[$i]:-없음}, 리뷰한 커밋=${C_H[$i]})" ;;
      base-unknown)    why="merge 직전 대상 브랜치를 특정하지 못했습니다" ;;
      content-differs) why="merge 결과가 리뷰한 변경과 다릅니다 — 충돌 해소나 merge 중 수정이 있었습니다" ;;
      *)               why="판정 불가 — merge 판정에 필요한 객체를 읽지 못했습니다 (${why:-원인 모름})" ;;
    esac
    _tp_apply_fail "${p}: ${why} (${C_URL[$i]})" "포인터를 옮기지 않았습니다. Status 는 PR 검토 중 그대로입니다."
    _tp_rereview_hint
    return 1
  done
  rm -f "$errf"

  # --- 중단 흔적의 자동 되돌림 (위 확인을 모두 통과한 뒤) ---
  if [[ "$intr" == 1 ]]; then
    printf '이전 --apply 가 중간에 멈춘 흔적을 되돌립니다\n'
    _tp_apply_rollback "$root" || return 1
    for ((i = 0; i < _TP_N; i++)); do C_SUBDIRTY[$i]="$(git -C "$root/${C_PATH[$i]}" status --porcelain 2>/dev/null)"; done
  fi

  # --- 선행 조건: 상위·대상 submodule 이 깨끗함 ---
  pre="$(git -C "$root" -c core.quotepath=false status --porcelain --untracked-files=all 2>/dev/null)"
  for ((i = 0; i < _TP_N; i++)); do
    [[ -z "${C_SUBDIRTY[$i]}" ]] || pre="${pre:+$pre$'\n'}${C_PATH[$i]} 안쪽: $(printf '%s' "${C_SUBDIRTY[$i]}" | head -1)"
  done
  if [[ -n "$pre" ]]; then
    _tp_apply_fail "작업 worktree 에 미커밋 변경이 있습니다 — 포인터 커밋에 섞이지 않도록 커밋하거나 정리한 뒤 다시 실행하십시오" \
      "$(printf '%s\n' "$pre" | head -5 | tr '\n' ' ')"
    return 1
  fi

  # --- 1단계: checkout · 기록 / 2단계: pathspec 커밋. 실패하면 3단계(되돌림) ---
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpck.XXXXXX")" || { _tp_apply_fail "임시 파일을 만들 수 없습니다"; return 1; }
  for ((i = 0; i < _TP_N; i++)); do
    p="${C_PATH[$i]}"
    # 파일을 만들지 못해도 git checkout 이 0 으로 끝나는 경우가 있습니다(2026-11-16 실측: 쓰기 금지 디렉터리).
    # 그래서 종료 코드와 함께 HEAD 가 merge 결과이고 안쪽이 깨끗한지 확인합니다.
    if ! git -C "$root/$p" checkout -q --detach "${C_M[$i]}" >/dev/null 2>"$errf" \
       || [[ "$(git -C "$root/$p" rev-parse -q --verify HEAD 2>/dev/null)" != "${C_M[$i]}" ]] \
       || [[ -n "$(git -C "$root/$p" status --porcelain 2>/dev/null)" ]]; then
      printf '%s: merge 결과 %s 로 checkout 하지 못했습니다:\n' "$p" "${C_M[$i]}"
      grep -v '^[[:space:]]*$' "$errf" | head -3 | sed 's/^/    /'
      rm -f "$errf"; _tp_apply_rollback "$root"; return 1
    fi
    printf '%s: %s → %s (%s)\n' "$p" "${C_H[$i]}" "${C_M[$i]}" "${C_URL[$i]}"
  done
  for ((i = 0; i < _TP_N; i++)); do
    if ! tp_record_upsert "$root" "${C_PATH[$i]}" "${C_REPO[$i]}" "${C_BRANCH[$i]}" "${C_BASE[$i]}" "${C_URL[$i]}" \
         "${C_H[$i]}" merged "${C_M[$i]}" "${C_GHK[$i]}" 2>"$errf"; then
      printf '기록 파일을 쓰지 못했습니다: %s\n' "$(head -1 "$errf")"
      rm -f "$errf"; _tp_apply_rollback "$root"; return 1
    fi
  done
  if ! { git -C "$root" add -- "${paths[@]}" "$RD_TEAM_PR_RECORD" 2>"$errf" \
         && _tp_commit "$root" -q -m "chore(lifecycle): ${slug} 팀 PR merge 반영 — submodule 포인터 이동" \
              -- "${paths[@]}" "$RD_TEAM_PR_RECORD" 2>"$errf"; }; then
    printf '포인터 커밋을 만들지 못했습니다: %s\n' "$(grep -v '^[[:space:]]*$' "$errf" | head -1)"
    rm -f "$errf"; _tp_apply_rollback "$root"; return 1
  fi
  rm -f "$errf"
  printf '포인터 커밋: %s\n' "$(git -C "$root" rev-parse --short HEAD)"

  _tp_apply_finish "$root" "$slug" "$fr_val"
}

tp_cmd_check() {
  _tp_direct_delegate check "$@"
  local apply=0 task="" wt
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1 ;;
      --task) [[ $# -ge 2 && -n "$2" ]] || { _tp_usage >&2; return 2; }; task="$2"; shift ;;
      -h|--help) _tp_usage; return 0 ;;
      *) printf 'rd pr check: 알 수 없는 인자: %s\n' "$1" >&2; _tp_usage >&2; return 2 ;;
    esac
    shift
  done
  if [[ -n "$task" ]]; then
    # 다른 작업의 worktree 에서 그 worktree 의 스크립트로 실행합니다(색인 worktree-path 기준).
    wt="$(project_root="$project_root" tasks_index_get "$task" worktree-path 2>/dev/null)" || wt=""
    if [[ -z "$wt" || ! -f "$wt/rd-workflow/scripts/rd" ]]; then
      printf 'rd pr check: 작업 %s 의 worktree 를 찾을 수 없습니다 (rd task list 로 확인하십시오)\n' "$task" >&2
      return 2
    fi
    if [[ "$(cd "$wt" && pwd -P)" != "$(cd "$project_root" && pwd -P)" ]]; then
      # 이 프로세스가 export 한 project_root(·TASK_STATE_PATH)를 자식이 물려받으면 호출한 쪽 작업을 판정합니다 — 지우고 넘깁니다.
      if [[ "$apply" == 1 ]]; then ( cd "$wt" && unset project_root TASK_STATE_PATH && exec bash rd-workflow/scripts/rd pr check --apply )
      else ( cd "$wt" && unset project_root TASK_STATE_PATH && exec bash rd-workflow/scripts/rd pr check ); fi
      return $?
    fi
  fi
  if [[ "$apply" == 1 ]]; then _tp_apply; else _tp_check_report; fi
}

tp_main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    open) tp_cmd_open ${1+"$@"} ;;
    light-check) tp_cmd_light_check ${1+"$@"} ;;
    check) tp_cmd_check ${1+"$@"} ;;
    reopen)
      _tp_direct_delegate reopen ${1+"$@"}
      printf 'rd pr reopen: 직접 설치 PR 방식(archive_publish=pr) 작업이 아닙니다. overlay 작업은 rd task set-status "구현 중" 으로 수정합니다.\n'
      return 2 ;;
    sync)
      _tp_direct_delegate sync ${1+"$@"}
      printf 'rd pr sync: 직접 설치 PR 방식(archive_publish=pr) 작업 전용입니다. overlay 작업의 PR 충돌은 bash rd-workflow/scripts/rd pr check 의 안내를 따르십시오.\n'
      return 2 ;;
    -h|--help|help) _tp_usage; return 0 ;;
    *) _tp_usage >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  tp_main ${1+"$@"}
  exit $?
fi
