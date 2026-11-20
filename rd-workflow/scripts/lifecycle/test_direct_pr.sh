#!/usr/bin/env bash
# test_direct_pr.sh — 직접 설치 PR 발행(archive_publish=pr)의 공용 함수·명령 시험 (_direct_pr_common.sh).
# 저장소는 모두 mktemp -d 아래에 만듭니다: 로컬 bare 원격 하나(origin) + 그 원격에 연결한 작업 저장소.
# origin URL 은 https://github.com/acme/demo.git 로 두고 insteadOf 로 로컬 bare 에 연결합니다.
# 가짜 gh 를 PATH 앞에 둡니다. 실제 GitHub 에 접근하지 않습니다.
#
# 시간: seal 까지 마친 틀은 실제 promote → 리뷰 세션 → seal 경로로 설정마다 한 번만 만들고(약 15~20초),
# 케이스마다 같은 절대 경로에 복사해 씁니다(케이스당 1초 안팎). 절대 경로가 그대로 맞으므로 복사본이 원본과 같이 동작합니다.
# 케이스 고르기: DPR_TEST_CASES="t_a t_b" (공백 구분, 비면 전부). DPR_SKIP_CASES 에 든 케이스는 건너뜁니다.
# 기본은 케이스 묶음 병렬 실행입니다(아래 「병렬 실행」). 직렬로 보려면 DPR_SERIAL=1.
# bash 3.2 호환.
set -uo pipefail

export HERDR_ENV= HC_TERMINAL_ID= RD_CHILD_SESSION=1
unset project_root TASK_STATE_PATH
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RDW_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$RDW_SRC/scripts/fixtures/review_run_fixture.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (기대 [$3] / 실제 [$2])"; fi; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
ok() { if has "$2" "$3"; then pass "$1"; else fail "$1 (없음: [$2]) — 출력: $3"; fi; }
no() { if has "$2" "$3"; then fail "$1 (있으면 안 됨: [$2]) — 출력: $3"; else pass "$1"; fi; }

T0=$SECONDS
TMP="$(mktemp -d)" || exit 1
[[ -n "$TMP" && -d "$TMP" ]] || exit 1
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "${TMP:?}"' EXIT
cd "$TMP"
export GIT_CEILING_DIRECTORIES="$(dirname "$TMP")"

# 공용 함수를 source 합니다. team_publish.sh 는 project_root 에 rd-workflow-workspace/ 가 있어야 source 됩니다.
mkdir -p "$TMP/pr0/rd-workflow-workspace"
project_root="$TMP/pr0"
_LC="$RDW_SRC/scripts/lifecycle"
source "$_LC/_lifecycle_common.sh"
source "$RDW_SRC/scripts/_submodule_common.sh"
source "$_LC/_tasks_index.sh"
source "$_LC/_team_publish_common.sh"
source "$_LC/team_publish.sh"
source "$_LC/_direct_pr_common.sh"
unset project_root TASK_STATE_PATH

W="$TMP/w"; SLUG=demo
R="$W/repo"; WT="$R/.worktrees/$SLUG"; ORIGIN="$W/origin.git"
FR_ITEM="rd-workflow-workspace/backlog/items/2026-11-16-demo.md"
ISSUE_URL="https://github.com/acme/demo/issues/7"
ORIGIN_URL="https://github.com/acme/demo.git"
FRB=""; SES=""

# dpr_mode_at <root> <commit> — dpr_archive_mode 를 부르는 한 줄 도우미.
dpr_mode_at() { dpr_archive_mode "$1" "$2"; }

# seal_and_hold <wt> <session> — 세션을 종결(리뷰어 이의 없음 턴)하고 검증 증거·seal 을 만든 뒤
# Status 를 아카이브 보류 로 옮겨 커밋합니다. 실패 rc 1. (test_team_publish.sh 의 같은 이름 함수와 같은 절차)
seal_and_hold() {
  local wt="$1" ses="$2" x
  x="$(mktemp "$TMP/x.XXXXXX")" || return 1
  awk '/^## Status$/{print; getline; print "closed"; next} {print}' "$ses/SESSION.md" >"$x" && cat "$x" >"$ses/SESSION.md"
  awk '/^## Open Issues$/{s=1; print; next} s && /^## /{s=0} s && $0=="-"{print "- 없음"; next} {print}' "$ses/CHECKPOINT.md" >"$x" && cat "$x" >"$ses/CHECKPOINT.md"
  rm -f "$x"
  fixture_reviewer_turn "$ses" "$wt/rd-workflow/scripts" || return 1
  ( cd "$wt" && bash rd-workflow/scripts/verify_record.sh -- true ) >"$TMP/vr.log" 2>&1 || { cat "$TMP/vr.log" >&2; return 1; }
  ( cd "$wt" && bash rd-workflow/scripts/rd review seal "$ses" ) >"$TMP/seal.log" 2>&1 || { cat "$TMP/seal.log" >&2; return 1; }
  ( cd "$wt" && bash rd-workflow/scripts/rd task set-status "아카이브 보류" --force ) >/dev/null 2>&1 \
    || { echo "set-status 아카이브 보류 실패" >&2; return 1; }
  git -C "$wt" add -A && git -C "$wt" commit -q -m "seal + 아카이브 보류"
}

# 틀 설정 — 설정마다 틀을 따로 만듭니다(workflow.json 이 seal 이 보호하는 트리에 들기 때문).
cfg_json() {
  case "$1" in
    pr)   echo '{"publish_approval":"caller","archive_publish":"pr"}' ;;
    push) echo '{"publish_approval":"caller"}' ;;
    bad)  echo '{"archive_publish":"maybe"}' ;;
    *) return 1 ;;
  esac
}

# _build_template <설정 이름> — $W 에 seal 까지 마친 저장소를 만들고 $TMP/tpl-<이름> 으로 복사해 둡니다.
_build_template() {
  local name="$1" ses
  rm -rf "${W:?}"
  mkdir -p "$W" "$R/rd-workflow"
  git init -q --bare -b main "$ORIGIN"
  cp -R "$RDW_SRC/." "$R/rd-workflow/"
  if [[ -f "$RDW_SRC/../.gitignore" ]]; then cp "$RDW_SRC/../.gitignore" "$R/.gitignore"; else printf '.worktrees/\n' >"$R/.gitignore"; fi
  cfg_json "$name" >"$R/rd-workflow/config/workflow.json" || return 1
  git init -q -b main "$R"
  mkdir -p "$R/rd-workflow-workspace/.lifecycle" "$R/rd-workflow-workspace/backlog/items"
  bash -c "source '$R/rd-workflow/scripts/lifecycle/_lifecycle_common.sh'; emit_current_task_baseline" >"$R/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
    >"$R/rd-workflow-workspace/.lifecycle/task-state"
  printf '# Change Request\n\n## Source FR\n-\n' >"$R/REQUEST.md"
  printf '# 2026-11-16 demo\n- status: validated\n- summary: 데모 작업 요약\n- github-issue: %s\n' "$ISSUE_URL" >"$R/$FR_ITEM"
  echo "base" >"$R/app.txt"
  git -C "$R" remote add origin "$ORIGIN_URL"
  git -C "$R" config "url.$ORIGIN.insteadOf" "$ORIGIN_URL"
  git -C "$R" add -A; git -C "$R" commit -q -m seed
  git -C "$R" push -q origin main || return 1
  ( cd "$R" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title "$SLUG" --size large --source-fr "$FR_ITEM" ) \
    >"$TMP/promote.log" 2>&1 || { cat "$TMP/promote.log" >&2; return 1; }
  echo "changed" >"$WT/app.txt"
  git -C "$WT" add -A; git -C "$WT" commit -q -m 구현
  ( cd "$WT" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff ) >"$TMP/prep.log" 2>&1 || true
  ses="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | tail -1)"
  [[ -n "$ses" ]] || { cat "$TMP/prep.log" >&2; return 1; }
  mkdir -p "$ses/turns"
  printf '# 001 Author\n\n## Summary\n요약\n\n## PR 본문\n\n### Summary\n- 무엇을: 데모 변경\n\n### User-visible Changes\n- 없음\n\n## Questions For Reviewer\n- 없음\n' \
    >"$ses/turns/001_author.md"
  seal_and_hold "$WT" "$ses" || return 1
  cp -R "$W" "$TMP/tpl-$name"
}

# mk_direct <설정 이름> — 그 설정의 틀을 $W 에 새로 복사합니다(처음 부를 때 틀을 만듭니다).
#   전역: R WT ORIGIN SES SLUG FRB
mk_direct() {
  local name="${1:?설정 이름}"
  if [[ ! -d "$TMP/tpl-$name" ]]; then
    _build_template "$name" || { echo "fixture 생성 실패: $name" >&2; exit 1; }
  fi
  rm -rf "${W:?}"
  cp -cR "$TMP/tpl-$name" "$W" 2>/dev/null || cp -R "$TMP/tpl-$name" "$W"
  SES="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review | tail -1)"
  FRB="$(awk -F= '$1=="fr-branch"{print $2}' "$WT/rd-workflow-workspace/.lifecycle/task-state")"
}

# setup_fake_gh — 가짜 gh 를 PATH 앞에 두고 상태 디렉터리 $FAKE 를 비웁니다.
#   $FAKE/log        호출마다 인자 한 줄
#   $FAKE/prs.tsv    `url<TAB>state<TAB>base<TAB>head-oid<TAB>merge-oid<TAB>mergeable<TAB>review<TAB>headref`
#                    (pr create 가 행을 더하고 head-oid 는 $FAKE_GH_ORIGIN 의 그 브랜치 OID. 테스트가 칸을 바꿈 — fake_merge 등)
#   $FAKE/title · body   마지막 pr create·edit 의 --title · --body-file 내용
#   FAKE_GH_FAIL=<하위 명령>   그 하위 명령(list|view|create|edit|reopen)을 rc 1 로 실패시킴
FAKE="$TMP/fakegh"; FAKEBIN="$TMP/fakebin"
setup_fake_gh() {
  rm -rf "$FAKE"; mkdir -p "$FAKE" "$FAKEBIN"
  : >"$FAKE/log"; : >"$FAKE/prs.tsv"; echo 0 >"$FAKE/n"
  export FAKE_GH_DIR="$FAKE" FAKE_GH_ORIGIN="$ORIGIN"
  unset FAKE_GH_FAIL
  [[ -x "$FAKEBIN/gh" ]] && return 0
  cat >"$FAKEBIN/gh" <<'FAKE_EOF'
#!/usr/bin/env bash
F="$FAKE_GH_DIR"
printf '%s\n' "$*" >>"$F/log"
[[ "${FAKE_GH_FAIL:-}" == "${2:-}" ]] && { echo "fake gh: $1 $2 실패 주입" >&2; exit 1; }
repo=""; head=""; state=""; base=""; title=""; bf=""; prev=""
for a in "$@"; do
  case "$prev" in
    --repo|-R) repo="$a" ;;
    --base) base="$a" ;;
    --head) head="$a" ;;
    --state) state="$a" ;;
    --title) title="$a"; printf '%s' "$a" >"$F/title" ;;
    --body-file) cat "$a" >"$F/body"; bf=1 ;;
  esac
  prev="$a"
done
T="$F/prs.tsv"
# linked_issues <PR 번호> — 가짜 GitHub 의 closingIssuesReferences 응답. 본문($F/body-<번호>, pr create·pr edit 의 --body-file)의
# `Closes <Issue URL>` 줄이 연결한 Issue 와, 사람이 직접 연결한 Issue($F/linked-<번호>, 줄마다 URL)를 냅니다. 직접 연결은 앞에 오고,
# 질의에 excludeUserLinked:true 가 있으면 뺍니다(GitHub 과 같은 의미).
linked_issues() {
  python3 -I -c '
import json, os, re, sys
f, n, q = sys.argv[1:4]
def read(p):
    return open(p).read() if os.path.isfile(p) else ""
urls = [] if "excludeUserLinked:true" in q else read(os.path.join(f, "linked-" + n)).split()
urls += re.findall(r"(?m)^Closes (https?://\S+/issues/[0-9]+)\s*$", read(os.path.join(f, "body-" + n)))
print(json.dumps({"data": {"repository": {"pullRequest": {"closingIssuesReferences": {"nodes": [{"url": u} for u in urls]}}}}}))
' "$F" "$1" "$2"
}
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list")
    awk -F'\t' -v h="$head" -v s="$state" '
      BEGIN { printf "[" }
      (h == "" || $8 == h) && (s == "all" || s == "" || tolower($2) == tolower(s)) {
        printf "%s{\"state\":\"%s\",\"url\":\"%s\",\"baseRefName\":\"%s\"}", (k++ ? "," : ""), $2, $1, $3 }
      END { print "]" }' "$T" ;;
  "api graphql")
    num=""; q=""
    for a in "$@"; do case "$a" in number=*) num="${a#number=}" ;; query=*) q="${a#query=}" ;; esac; done
    linked_issues "$num" "$q" ;;
  "pr create")
    n=$(( $(cat "$F/n") + 1 )); echo "$n" >"$F/n"
    url="https://github.com/${repo:-acme/demo}/pull/$n"
    oid="$(git --git-dir="${FAKE_GH_ORIGIN:-/nonexistent}" rev-parse -q --verify "refs/heads/$head" 2>/dev/null || true)"
    printf '%s\tOPEN\t%s\t%s\t\tMERGEABLE\t\t%s\n' "$url" "${base:-main}" "$oid" "$head" >>"$T"
    [[ -z "$bf" ]] || cp "$F/body" "$F/body-$n"
    printf '%s\n' "$url" ;;
  "pr view")
    awk -F'\t' -v u="$3" '
      $1 == u { f = 1
        mc = ($5 == "" ? "null" : "{\"oid\":\"" $5 "\"}")
        printf "{\"url\":\"%s\",\"state\":\"%s\",\"baseRefName\":\"%s\",\"headRefOid\":\"%s\",\"mergeCommit\":%s,\"mergeable\":\"%s\",\"reviewDecision\":\"%s\",\"commits\":[],\"latestReviews\":[]}\n", $1, $2, $3, $4, mc, $6, $7 }
      END { exit f ? 0 : 1 }' "$T" || { echo "no pull requests found" >&2; exit 1; } ;;
  "pr edit")
    awk -F'\t' -v u="$3" '$1 == u { f = 1 } END { exit f ? 0 : 1 }' "$T" || { echo "no pull requests found" >&2; exit 1; }
    if [[ -n "$base" ]]; then
      awk -F'\t' -v OFS='\t' -v u="$3" -v b="$base" '$1 == u { $3 = b } { print }' "$T" >"$T.t" && mv "$T.t" "$T"
    fi
    [[ -z "$bf" ]] || cp "$F/body" "$F/body-${3##*/}" ;;
  "pr reopen")
    awk -F'\t' -v u="$3" '$1 == u { f = 1 } END { exit f ? 0 : 1 }' "$T" || { echo "no pull requests found" >&2; exit 1; }
    awk -F'\t' -v OFS='\t' -v u="$3" '$1 == u { $2 = "OPEN" } { print }' "$T" >"$T.t" && mv "$T.t" "$T" ;;
  *) echo "fake gh: 지원하지 않는 명령: $*" >&2; exit 1 ;;
esac
FAKE_EOF
  chmod +x "$FAKEBIN/gh"
}
export PATH="$FAKEBIN:$PATH"

# want <케이스> — DPR_TEST_CASES(공백 구분)가 비었거나 그 케이스를 담으면 실행합니다(변이 확인 때 골라 돌리기용).
# DPR_SKIP_CASES 에 든 케이스는 실행하지 않습니다(병렬 실행의 나머지 묶음용).
want() {
  [[ " ${DPR_SKIP_CASES:-} " == *" $1 "* ]] && return 1
  [[ -z "${DPR_TEST_CASES:-}" || " $DPR_TEST_CASES " == *" $1 "* ]]
}

# 병렬 실행. 케이스 고르기(DPR_TEST_CASES·DPR_SKIP_CASES)도 DPR_SERIAL=1 도 없으면, 이 파일을 묶음마다 자식 프로세스로
# 동시에 돌리고 결과를 모읍니다(test_team_publish.sh 와 같은 구조). 틀은 프로세스마다 따로 만듭니다(설정마다 약 8초).
# 마지막 묶음은 앞 묶음에 없는 케이스를 모두 돌립니다 — 새 케이스는 묶음에 넣지 않아도 빠지지 않습니다.
# 묶음은 케이스별 실측(2026-11-18)으로 나눴습니다. 각 묶음은 부하가 낮을 때 약 60초입니다.
if [[ -z "${DPR_TEST_CASES:-}${DPR_SKIP_CASES:-}${DPR_SERIAL:-}" ]]; then
  DPR_GROUPS=(
    "t_mode_default_push t_push_mode_unchanged t_overlay_untouched t_mode_bad_rc2 t_mode_pr t_cleanup_commit t_published_cleanup t_cleanup_fail_restores t_pr_text_from_parent t_pr_publish t_open_pr_edited t_reject_nofr t_reject_no_remote t_reject_no_gh t_dry_run"
    "t_untracked_blocks t_remote_ahead_stops t_closed_pr_stops t_conflict_stops t_push_reject_rolls_back t_pr_create_fail_keeps t_open_retries_pr t_open_edit_fail_retry"
    "t_open_on_hold_rc2 t_check_states t_apply_merge t_apply_squash t_apply_rebase t_apply_not_merged t_apply_base_mismatch"
    "t_apply_head_mismatch t_apply_repo_mismatch t_apply_not_in_remote t_apply_tag_push_fail_retry t_queue_pr_done t_queue_pr_p9_fail t_queue_pr_republish_edit_fail"
    "t_index_set_lock t_resume_after_push t_cleanup_interrupt_hint t_rerun_after_apply t_rerun_after_push_hint t_reopen t_reopen_no_tmpdir t_reopen_merged_rc1"
    "t_sync_tree_records_only t_sync_tree_other_conflict t_sync_tree_unsupported t_published_head_chain t_published_head_rejects"
    "t_open_external_merge t_apply_empty_index_external t_apply_verified_list t_sync_reopen t_sync_tree_stage_sides t_rerun_hint_sync_head"
    "t_sync_records_only t_sync_task_state_only t_sync_no_worktree t_sync_other_conflict t_sync_unsupported_config t_sync_dirty t_sync_not_waiting"
    "t_sync_gitlink_conflict t_sync_remote_ahead t_sync_record_fail t_sync_push_rejected t_sync_resume_after_push t_sync_resume_index"
    "t_sync_resume_local t_sync_merged_midway t_sync_p9_pending t_head_lag"
    "t_sync_finish_ff_only t_sync_finish_preserve t_sync_finish_other_branch t_sync_push_lease t_published_head_long_chain t_sync_noop t_base_mismatch"
  )
  dpr_all="${DPR_GROUPS[*]}"; dpr_pids=(); dpr_n=${#DPR_GROUPS[@]}
  # 자식의 stdout·stderr 를 따로 받아 그대로 돌려줍니다 — self_test 는 stderr 에서 `command not found` 를 찾습니다.
  for ((dpr_i = 0; dpr_i <= dpr_n; dpr_i++)); do
    if [[ "$dpr_i" -lt "$dpr_n" ]]; then
      DPR_TEST_CASES="${DPR_GROUPS[$dpr_i]}" bash "$SCRIPT_DIR/test_direct_pr.sh" >"$TMP/group-$dpr_i.out" 2>"$TMP/group-$dpr_i.err" &
    else
      DPR_SKIP_CASES="$dpr_all" bash "$SCRIPT_DIR/test_direct_pr.sh" >"$TMP/group-$dpr_i.out" 2>"$TMP/group-$dpr_i.err" &
    fi
    dpr_pids+=("$!")
  done
  echo "병렬 $((dpr_n + 1))묶음 시작 — 묶음 출력은 모두 끝난 뒤 차례로 보입니다. 실행 중 로그: $TMP/group-<번호>.out·.err"
  # 진행 표시: 묶음이 끝날 때마다 한 줄. 실패 판정은 아래 출력 단계에서 합니다.
  dpr_seen=" "; dpr_k=0
  while [[ "$dpr_k" -le "$dpr_n" ]]; do
    for ((dpr_i = 0; dpr_i <= dpr_n; dpr_i++)); do
      [[ "$dpr_seen" == *" $dpr_i "* ]] && continue
      kill -0 "${dpr_pids[$dpr_i]}" 2>/dev/null && continue
      dpr_seen="$dpr_seen$dpr_i "; dpr_k=$((dpr_k + 1))
      echo "  묶음 $((dpr_i + 1)) 끝남 ($dpr_k/$((dpr_n + 1)), 경과 $((SECONDS - T0))초)"
    done
    [[ "$dpr_k" -le "$dpr_n" ]] && sleep 2
  done
  dpr_rc=0
  for ((dpr_i = 0; dpr_i <= dpr_n; dpr_i++)); do
    wait "${dpr_pids[$dpr_i]}" || dpr_rc=1
    echo "== 묶음 $((dpr_i + 1))/$((dpr_n + 1)) =="
    cat "$TMP/group-$dpr_i.out"
    cat "$TMP/group-$dpr_i.err" >&2
    dpr_line="$(grep '^결과: PASS=' "$TMP/group-$dpr_i.out" | tail -1)"
    [[ -n "$dpr_line" ]] || { echo "  FAIL: 묶음 $((dpr_i + 1)) 이 결과 줄 없이 끝났습니다" >&2; FAIL=$((FAIL + 1)); continue; }
    dpr_p="${dpr_line#*PASS=}"; dpr_p="${dpr_p%% *}"; dpr_f="${dpr_line#*FAIL=}"; dpr_f="${dpr_f%% *}"
    PASS=$((PASS + dpr_p)); FAIL=$((FAIL + dpr_f))
  done
  echo
  echo "결과: PASS=$PASS FAIL=$FAIL (병렬 $((dpr_n + 1))묶음, 소요 $((SECONDS - T0))초)"
  [[ "$FAIL" -eq 0 && "$dpr_rc" -eq 0 ]]
  exit
fi

# gh_count <패턴> — 가짜 gh 호출 로그에서 패턴이 든 줄 수.
gh_count() { grep -c -- "$1" "$FAKE/log" 2>/dev/null | tr -d ' '; }

# fake_merge <merge|squash|rebase> — bare $ORIGIN 에서 fr 브랜치를 main 으로 합치고(rebase 는 main 을 전진시킨 뒤 새 OID 로 다시 쌓음),
# 가짜 gh 의 마지막 PR 행을 MERGED·mergeCommit·headRefOid 로 씁니다.
fake_merge() {
  local method="${1:?merge|squash|rebase}" c="$TMP/mg" frtip mo
  rm -rf "$c"
  git clone -q "$ORIGIN" "$c" 2>/dev/null || return 1
  git -C "$c" checkout -q main
  git -C "$c" fetch -q origin "$FRB:refs/remotes/origin/$FRB" || return 1
  frtip="$(git -C "$c" rev-parse "refs/remotes/origin/$FRB")"
  case "$method" in
    merge)  git -C "$c" merge -q --no-ff -m "Merge $FRB" "$frtip" >/dev/null || return 1 ;;
    squash) git -C "$c" merge -q --squash "$frtip" >/dev/null && git -C "$c" commit -q -m "squash $FRB" || return 1 ;;
    rebase)
      # main 을 먼저 전진시켜 fr 커밋을 새 OID 로 다시 쌓게 합니다(fast-forward 만으로는 mergeCommit 이 fr tip 과 같아 rebase 방식이 아닙니다).
      echo "main side" >"$c/main-side.txt"
      git -C "$c" add main-side.txt && git -C "$c" commit -q -m "main 쪽 변경" || return 1
      git -C "$c" checkout -q -b rb "$frtip" || return 1
      git -C "$c" rebase -q main >/dev/null 2>&1 || return 1
      git -C "$c" checkout -q main && git -C "$c" merge -q --ff-only rb >/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  git -C "$c" push -q origin main || return 1
  mo="$(git -C "$c" rev-parse HEAD)"
  [[ -s "$FAKE/prs.tsv" ]] || return 0
  awk -F'\t' -v OFS='\t' -v m="$mo" -v h="$frtip" '{ L[NR] = $0 } END {
    for (i = 1; i <= NR; i++) {
      if (i == NR) { split(L[i], a, "\t"); a[2] = "MERGED"; a[4] = h; a[5] = m; L[i] = a[1] OFS a[2] OFS a[3] OFS a[4] OFS a[5] OFS a[6] OFS a[7] OFS a[8] }
      print L[i] } }' "$FAKE/prs.tsv" >"$FAKE/prs.tsv.t" && mv "$FAKE/prs.tsv.t" "$FAKE/prs.tsv"
}

# 케이스 공용 도구
status_in() { awk -F= '$1=="status"{sub(/^[^=]+=/,""); print}' "$1/rd-workflow-workspace/.lifecycle/task-state"; }
# in_repo <명령...> — $R 에서, project_root=$R 로 부릅니다(저장소를 cwd·project_root 로 정하는 함수용).
in_repo() { ( cd "$R" && project_root="$R" && "$@" ); }

echo "== 설정 판정 =="

t_mode_default_push() { mk_direct push; eq "t_mode_default_push: 설정 없음 → push" "$(dpr_mode_at "$WT" HEAD)" "push"; }
want t_mode_default_push && t_mode_default_push

t_mode_pr() { mk_direct pr; eq "t_mode_pr: pr" "$(dpr_mode_at "$WT" HEAD)" "pr"; }
want t_mode_pr && t_mode_pr

t_mode_bad_rc2() {
  local rc=0
  mk_direct bad
  dpr_mode_at "$WT" HEAD >/dev/null 2>"$TMP/e" || rc=$?
  eq "t_mode_bad_rc2: 잘못된 값 rc" "$rc" "2"
  ok "t_mode_bad_rc2: 오류 문구" "archive_publish 설정 오류" "$(cat "$TMP/e")"
}
want t_mode_bad_rc2 && t_mode_bad_rc2

echo "== 작업 상태 되돌리기 커밋 =="

# clean_commit — pr 틀에서 정리 커밋을 만들어 CLEAN_OID 에 둡니다.
clean_commit() { CLEAN_OID="$(dpr_cleanup_commit "$WT" "$SLUG" 2>"$TMP/cc.err")"; CLEAN_RC=$?; }

t_cleanup_commit() {
  local changed p bad=""
  mk_direct pr; clean_commit
  eq "t_cleanup_commit: rc 0" "$CLEAN_RC" "0"
  eq "t_cleanup_commit: stdout 이 fr tip OID" "$CLEAN_OID" "$(git -C "$WT" rev-parse HEAD)"
  eq "t_cleanup_commit: status=대기 중" "$(status_in "$WT")" "대기 중"
  eq "t_cleanup_commit: short-title=-" "$(awk -F= '$1=="short-title"{print $2}' "$WT/rd-workflow-workspace/.lifecycle/task-state")" "-"
  ok "t_cleanup_commit: CURRENT_TASK.md 대기 중" "대기 중" "$(cat "$WT/CURRENT_TASK.md")"
  eq "t_cleanup_commit: 커밋 메시지" "$(git -C "$WT" log -1 --format=%s)" "chore(lifecycle): archive demo metadata 정리"
  changed="$(git -C "$WT" diff-tree --no-commit-id --name-only -r HEAD)"
  for p in $changed; do
    case "$p" in
      rd-workflow-workspace/.lifecycle/task-state|CURRENT_TASK.md|rd-workflow-workspace/.lifecycle/active-fr|rd-workflow-workspace/.lifecycle/stage_metrics.tsv|rd-workflow-workspace/.lifecycle/team-prs.tsv) ;;
      *) bad="$bad $p" ;;
    esac
  done
  eq "t_cleanup_commit: 바뀐 경로가 lifecycle 경로만" "$bad" ""
  eq "t_cleanup_commit: worktree clean" "$(git -C "$WT" status --porcelain --untracked-files=all)" ""
}
want t_cleanup_commit && t_cleanup_commit

t_published_cleanup() {
  local rc
  mk_direct pr; clean_commit
  eq "t_published_cleanup: 준비 — 정리 커밋 rc 0" "$CLEAN_RC" "0"
  rc=0; in_repo dpr_is_published_cleanup "$FRB" "$SLUG" 2>/dev/null || rc=$?
  eq "t_published_cleanup: push 전 rc 1" "$rc" "1"
  git -C "$WT" push -q origin "HEAD:refs/heads/$FRB" || { fail "t_published_cleanup: 준비 — push 실패"; return; }
  rc=0; in_repo dpr_is_published_cleanup "$FRB" "$SLUG" 2>/dev/null || rc=$?
  eq "t_published_cleanup: push 뒤 rc 0" "$rc" "0"
  echo "more" >>"$WT/app.txt"; git -C "$WT" commit -q -am "일반 커밋"
  git -C "$WT" push -q origin "HEAD:refs/heads/$FRB" || { fail "t_published_cleanup: 준비 — 일반 커밋 push 실패"; return; }
  rc=0; in_repo dpr_is_published_cleanup "$FRB" "$SLUG" 2>/dev/null || rc=$?
  eq "t_published_cleanup: 일반 커밋 tip rc 1" "$rc" "1"
}
want t_published_cleanup && t_published_cleanup

t_cleanup_fail_restores() {
  local head0 hooks="$TMP/hooks-fail"
  mk_direct pr
  mkdir -p "$hooks"; printf '#!/bin/sh\nexit 1\n' >"$hooks/pre-commit"; chmod +x "$hooks/pre-commit"
  git -C "$WT" config core.hooksPath "$hooks"
  head0="$(git -C "$WT" rev-parse HEAD)"
  clean_commit
  eq "t_cleanup_fail_restores: rc 1" "$CLEAN_RC" "1"
  eq "t_cleanup_fail_restores: HEAD 불변" "$(git -C "$WT" rev-parse HEAD)" "$head0"
  eq "t_cleanup_fail_restores: porcelain 비어 있음" "$(git -C "$WT" status --porcelain --untracked-files=all)" ""
  eq "t_cleanup_fail_restores: status=아카이브 보류" "$(status_in "$WT")" "아카이브 보류"
}
want t_cleanup_fail_restores && t_cleanup_fail_restores

t_pr_text_from_parent() {
  local title body rc
  mk_direct pr; clean_commit
  eq "t_pr_text_from_parent: 준비 — 정리 커밋 rc 0" "$CLEAN_RC" "0"
  rc=0; title="$(dpr_pr_text "$WT" HEAD^ "$TMP/body.md" 2>/dev/null)" || rc=$?
  eq "t_pr_text_from_parent: 부모 입력 rc 0" "$rc" "0"
  [[ -n "$title" ]] && pass "t_pr_text_from_parent: 제목 비어 있지 않음" || fail "t_pr_text_from_parent: 제목이 비어 있음"
  body="$(cat "$TMP/body.md" 2>/dev/null)"
  ok "t_pr_text_from_parent: 본문 무엇을" "무엇을: 데모 변경" "$body"
  ok "t_pr_text_from_parent: 본문 Closes" "Closes $ISSUE_URL" "$body"
  rc=0; dpr_pr_text "$WT" HEAD "$TMP/body2.md" >/dev/null 2>&1 || rc=$?
  eq "t_pr_text_from_parent: 정리 커밋 입력 rc 1" "$rc" "1"
}
want t_pr_text_from_parent && t_pr_text_from_parent

echo "== archive.sh — pr 방식 발행 =="

# run_ar <archive.sh 인자...> — 작업 worktree 에서 archive.sh 를 실행해 출력은 $AR_OUT, rc 는 AR_RC 에 둡니다.
AR_OUT="$TMP/ar.out"
run_ar() { ( cd "$WT" && bash rd-workflow/scripts/lifecycle/archive.sh "$@" ) >"$AR_OUT" 2>&1; AR_RC=$?; }
ar_out() { cat "$AR_OUT"; }
# closed_issue_no [ar] — 닫힌 PR 선택지 3) 줄이 가리키는 Issue 번호 전부(…/issues/N 또는 gh issue edit N --repo …, 공백 구분). 일반 안내 줄이면 빈 값.
#   인자 ar 이면 archive 출력(발행 P2)에서 찾습니다. pr_out 은 아래 rd pr 구획에서 정의됩니다(호출할 때 찾습니다).
closed_issue_no() { if [[ "${1:-}" == ar ]]; then ar_out; else pr_out; fi | sed -n 's/^    3) 연결된 Issue 선점 풀기: gh issue edit \(.*\) --remove-assignee.*/\1/p' | sed -n 's|.*/issues/\([0-9][0-9]*\)$|\1|p; s|^\([0-9][0-9]*\) --repo .*|\1|p' | paste -sd ' ' -; }
og() { git --git-dir="$ORIGIN" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
fr_tip() { git -C "$R" rev-parse -q --verify "refs/heads/$FRB" 2>/dev/null; }
tag_count() { git -C "$R" tag --list 'fr/*' | wc -l | tr -d ' '; }
commit_count() { git -C "$R" rev-list --all --count; }
# origin_push_other <브랜치> <파일> <내용> — 다른 작업자가 origin 의 그 브랜치에 커밋을 올린 상황을 만듭니다(브랜치가 없으면 main 에서 갈라짐).
origin_push_other() {
  local br="$1" f="$2" body="$3" c="$TMP/other"
  rm -rf "$c"; git clone -q "$ORIGIN" "$c" 2>/dev/null || return 1
  git -C "$c" checkout -q -B "$br" "$(git -C "$c" rev-parse origin/main)" || return 1
  printf '%s\n' "$body" >"$c/$f"; git -C "$c" add -A && git -C "$c" commit -q -m "다른 작업자 $br" || return 1
  git -C "$c" push -q origin "HEAD:refs/heads/$br"
}

t_push_mode_unchanged() {
  local main0
  mk_direct push; setup_fake_gh
  main0="$(og main)"
  run_ar
  eq "t_push_mode_unchanged: rc 0" "$AR_RC" "0"
  [[ "$(og main)" != "$main0" ]] && pass "t_push_mode_unchanged: origin main 전진" || fail "t_push_mode_unchanged: origin main 이 그대로"
  eq "t_push_mode_unchanged: origin main == 로컬 main" "$(og main)" "$(git -C "$R" rev-parse main)"
  eq "t_push_mode_unchanged: 태그 1개" "$(tag_count)" "1"
  eq "t_push_mode_unchanged: gh 호출 0" "$(gh_count .)" "0"
}
want t_push_mode_unchanged && t_push_mode_unchanged

t_pr_publish() {
  local main0 lmain0 tip0 out cleanup
  mk_direct pr; setup_fake_gh
  main0="$(og main)"; lmain0="$(git -C "$R" rev-parse main)"; tip0="$(fr_tip)"
  run_ar; out="$(ar_out)"
  eq "t_pr_publish: rc 0" "$AR_RC" "0"
  eq "t_pr_publish: origin main 불변" "$(og main)" "$main0"
  eq "t_pr_publish: 로컬 main 불변" "$(git -C "$R" rev-parse main)" "$lmain0"
  cleanup="$(fr_tip)"
  [[ -n "$cleanup" && "$cleanup" != "$tip0" ]] && pass "t_pr_publish: fr tip 이 정리 커밋으로 전진" || fail "t_pr_publish: fr tip 불변 ($cleanup)"
  eq "t_pr_publish: 정리 커밋 메시지" "$(git -C "$R" log -1 --format=%s "$cleanup")" "chore(lifecycle): archive demo metadata 정리"
  eq "t_pr_publish: origin fr/demo == 로컬 fr/demo" "$(og "$FRB")" "$cleanup"
  eq "t_pr_publish: gh pr create 1회" "$(gh_count 'pr create')" "1"
  eq "t_pr_publish: 태그 0개" "$(tag_count)" "0"
  [[ -d "$WT" ]] && pass "t_pr_publish: WT 존재" || fail "t_pr_publish: 작업 worktree 가 사라짐"
  eq "t_pr_publish: 색인 pr-mode" "$(in_repo dpr_index_get "$SLUG" pr-mode)" "direct"
  eq "t_pr_publish: 색인 pr-head == 정리 커밋" "$(in_repo dpr_index_get "$SLUG" pr-head)" "$cleanup"
  ok "t_pr_publish: 색인 pr-url" "https://github.com/acme/demo/pull/1" "$(in_repo dpr_index_get "$SLUG" pr-url)"
  ok "t_pr_publish: 다음 행동 안내" "rd pr check --task demo --apply" "$out"
  ok "t_pr_publish: PR 제목(FR 요약)" "데모 작업 요약" "$(cat "$FAKE/title" 2>/dev/null)"
}
want t_pr_publish && t_pr_publish

t_open_pr_edited() {
  local out
  mk_direct pr; setup_fake_gh
  printf 'https://github.com/acme/demo/pull/9\tOPEN\tmain\t\t\tMERGEABLE\t\t%s\n' "$FRB" >>"$FAKE/prs.tsv"
  run_ar; out="$(ar_out)"
  eq "t_open_pr_edited: rc 0" "$AR_RC" "0"
  eq "t_open_pr_edited: pr create 0" "$(gh_count 'pr create')" "0"
  eq "t_open_pr_edited: pr edit 1" "$(gh_count 'pr edit')" "1"
  eq "t_open_pr_edited: 색인 pr-url 은 기존 PR" "$(in_repo dpr_index_get "$SLUG" pr-url)" "https://github.com/acme/demo/pull/9"
}
want t_open_pr_edited && t_open_pr_edited

t_reject_nofr() {
  local n="$TMP/nofr" o="$TMP/nofr-origin.git" main0 tags0 out rc
  rm -rf "$n" "$o"; mkdir -p "$n/rd-workflow"
  git init -q --bare -b main "$o"
  cp -R "$RDW_SRC/." "$n/rd-workflow/"
  printf '.worktrees/\nrd-workflow-workspace/.lifecycle/review-skip-audit.log\n' >"$n/.gitignore"
  cfg_json pr >"$n/rd-workflow/config/workflow.json"
  git init -q -b main "$n"
  mkdir -p "$n/rd-workflow-workspace/.lifecycle"
  bash -c "source '$n/rd-workflow/scripts/lifecycle/_lifecycle_common.sh'; emit_current_task_baseline" >"$n/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=nofr\nstatus=아카이브 보류\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
    >"$n/rd-workflow-workspace/.lifecycle/task-state"
  echo base >"$n/app.txt"
  git -C "$n" remote add origin "$o"
  git -C "$n" add -A; git -C "$n" commit -q -m seed
  git -C "$n" push -q origin main
  main0="$(git -C "$n" rev-parse main)"; tags0="$(git -C "$n" tag --list | wc -l | tr -d ' ')"
  setup_fake_gh
  # 뒤쪽 안전망(종결 마커·Status 검사)이 먼저 거부하면 「불변」 단언이 D2 거부와 무관하게 통과하므로 두 게이트를 우회해 D2 만 막게 합니다.
  rc=0; out="$( cd "$n" && bash rd-workflow/scripts/lifecycle/archive.sh --force-skip-review-check "시험" --allow-status-mismatch "시험" 2>&1 )" || rc=$?
  eq "t_reject_nofr: rc 1" "$rc" "1"
  ok "t_reject_nofr: promote.sh 안내" "promote.sh" "$out"
  eq "t_reject_nofr: origin main 불변" "$(git --git-dir="$o" rev-parse main)" "$main0"
  eq "t_reject_nofr: 로컬 main 불변" "$(git -C "$n" rev-parse main)" "$main0"
  eq "t_reject_nofr: 태그 불변" "$(git -C "$n" tag --list | wc -l | tr -d ' ')" "$tags0"
}
want t_reject_nofr && t_reject_nofr

t_reject_no_remote() {
  mk_direct pr; setup_fake_gh
  run_ar --no-remote
  eq "t_reject_no_remote: rc 1" "$AR_RC" "1"
  ok "t_reject_no_remote: 안내" "PR 을 올릴 원격이 없습니다" "$(ar_out)"
}
want t_reject_no_remote && t_reject_no_remote

t_reject_no_gh() {
  local nb="$TMP/nogh-bin" d f newpath="" opath="$PATH"
  mk_direct pr; setup_fake_gh
  if [[ ! -d "$nb" ]]; then
    mkdir -p "$nb"
    local IFS_O="$IFS"; IFS=:
    for d in $PATH; do
      [[ -x "$d/gh" ]] || continue
      for f in "$d"/*; do [[ -x "$f" && ! -d "$f" && "${f##*/}" != gh && ! -e "$nb/${f##*/}" ]] && ln -s "$f" "$nb/${f##*/}"; done
    done
    IFS="$IFS_O"
  fi
  local IFS_O="$IFS"; IFS=:
  for d in $PATH; do [[ -x "$d/gh" ]] || newpath="${newpath:+$newpath:}$d"; done
  IFS="$IFS_O"
  PATH="$newpath:$nb"
  run_ar
  PATH="$opath"
  eq "t_reject_no_gh: rc 1" "$AR_RC" "1"
  ok "t_reject_no_gh: 안내" "gh auth login" "$(ar_out)"
}
want t_reject_no_gh && t_reject_no_gh

t_dry_run() {
  local c0 tip0 main0
  mk_direct pr; setup_fake_gh
  c0="$(commit_count)"; tip0="$(fr_tip)"; main0="$(og main)"
  run_ar --dry-run
  eq "t_dry_run: rc 0" "$AR_RC" "0"
  ok "t_dry_run: would open PR" "would open PR: branch=$FRB base=main" "$(ar_out)"
  eq "t_dry_run: 커밋 수 불변" "$(commit_count)" "$c0"
  eq "t_dry_run: fr tip 불변" "$(fr_tip)" "$tip0"
  eq "t_dry_run: gh 호출 0" "$(gh_count .)" "0"
}
want t_dry_run && t_dry_run

t_untracked_blocks() {
  local tip0
  mk_direct pr; setup_fake_gh
  git -C "$WT" config status.showUntrackedFiles no
  echo x >"$WT/untracked.txt"
  tip0="$(fr_tip)"
  run_ar
  eq "t_untracked_blocks: rc 1" "$AR_RC" "1"
  ok "t_untracked_blocks: P1 안내" "작업 worktree 에서 커밋하거나 정리한 뒤 다시 발행 요청" "$(ar_out)"
  eq "t_untracked_blocks: fr tip 불변" "$(fr_tip)" "$tip0"
}
want t_untracked_blocks && t_untracked_blocks

t_remote_ahead_stops() {
  local tip0 r0
  mk_direct pr; setup_fake_gh
  origin_push_other "$FRB" other.txt "다른 작업" || { fail "t_remote_ahead_stops: 준비 실패"; return; }
  tip0="$(fr_tip)"; r0="$(git -C "$R" reflog show "$FRB" | wc -l | tr -d ' ')"
  run_ar
  eq "t_remote_ahead_stops: rc 1" "$AR_RC" "1"
  ok "t_remote_ahead_stops: force push 안 함 안내" "force push 하지 않습니다" "$(ar_out)"
  eq "t_remote_ahead_stops: fr tip 불변" "$(fr_tip)" "$tip0"
  eq "t_remote_ahead_stops: reflog 항목 수 불변" "$(git -C "$R" reflog show "$FRB" | wc -l | tr -d ' ')" "$r0"
}
want t_remote_ahead_stops && t_remote_ahead_stops

t_closed_pr_stops() {
  local tip0
  mk_direct pr; setup_fake_gh
  tip0="$(fr_tip)"
  # Issue 줄은 닫힌 PR 이 본문 Closes 줄로 연결한 Issue 로 만듭니다. 사람이 직접 연결한 Issue 99 는 빼야 합니다.
  printf 'https://github.com/acme/demo/pull/9\tCLOSED\tmain\t\t\tMERGEABLE\t\t%s\n' "$FRB" >>"$FAKE/prs.tsv"
  printf '본문\n\nCloses https://github.com/acme/demo/issues/7\n' >"$FAKE/body-9"
  printf 'https://github.com/acme/demo/issues/99\n' >"$FAKE/linked-9"
  run_ar
  eq "t_closed_pr_stops: rc 1" "$AR_RC" "1"
  ok "t_closed_pr_stops: 안내" "gh pr reopen" "$(ar_out)"
  eq "t_closed_pr_stops: pr create 0" "$(gh_count 'pr create')" "0"
  eq "t_closed_pr_stops: fr tip 불변" "$(fr_tip)" "$tip0"
  eq "t_closed_pr_stops: 닫힌 PR 이 연결한 Issue" "$(closed_issue_no ar)" "7"
}
want t_closed_pr_stops && t_closed_pr_stops

t_conflict_stops() {
  local tip0 out ses2 x
  mk_direct pr; setup_fake_gh
  origin_push_other main app.txt "다른 변경" || { fail "t_conflict_stops: 준비 실패"; return; }
  tip0="$(fr_tip)"
  run_ar; out="$(ar_out)"
  eq "t_conflict_stops: rc 1" "$AR_RC" "1"
  eq "t_conflict_stops: fr tip 불변" "$(fr_tip)" "$tip0"
  ok "t_conflict_stops: set-status 구현 중 안내" 'rd task set-status "구현 중"' "$out"
  ok "t_conflict_stops: merge 안내" "git merge origin/main" "$out"
  no "t_conflict_stops: rd pr reopen 없음" "rd pr reopen" "$out"
  # 안내대로 복구: 구현 중 → merge·해소·커밋 → 새 리뷰 종결·seal·아카이브 보류 → archive
  ( cd "$WT" && bash rd-workflow/scripts/rd task set-status "구현 중" ) >"$TMP/cs1.log" 2>&1 || { fail "t_conflict_stops: set-status 구현 중 실패: $(cat "$TMP/cs1.log")"; return; }
  git -C "$WT" fetch -q origin main
  git -C "$WT" merge -q origin/main >/dev/null 2>&1 || true
  printf '합친 결과\n' >"$WT/app.txt"
  git -C "$WT" add -A && git -C "$WT" commit -q -m "main 병합" || { fail "t_conflict_stops: 병합 커밋 실패"; return; }
  ( cd "$WT" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff ) >"$TMP/prep2.log" 2>&1 || true
  ses2="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | tail -1)"
  [[ -n "$ses2" && "$ses2" != "$SES" ]] || { fail "t_conflict_stops: 새 리뷰 세션 생성 실패: $(cat "$TMP/prep2.log")"; return; }
  mkdir -p "$ses2/turns"
  printf '# 001 Author\n\n## Summary\n요약\n\n## PR 본문\n\n### Summary\n- 무엇을: 데모 변경\n\n### User-visible Changes\n- 없음\n\n## Questions For Reviewer\n- 없음\n' >"$ses2/turns/001_author.md"
  seal_and_hold "$WT" "$ses2" || { fail "t_conflict_stops: 새 seal 실패"; return; }
  run_ar
  eq "t_conflict_stops: 복구 뒤 rc 0" "$AR_RC" "0"
  eq "t_conflict_stops: 복구 뒤 pr create 1" "$(gh_count 'pr create')" "1"
}
want t_conflict_stops && t_conflict_stops

t_push_reject_rolls_back() {
  local tip0
  mk_direct pr; setup_fake_gh
  printf '#!/bin/sh\nwhile read old new ref; do case "$ref" in refs/heads/fr/*) echo "fr 거부" >&2; exit 1;; esac; done\nexit 0\n' >"$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  tip0="$(fr_tip)"
  run_ar
  eq "t_push_reject_rolls_back: rc 1" "$AR_RC" "1"
  eq "t_push_reject_rolls_back: fr tip == 실행 전" "$(fr_tip)" "$tip0"
  eq "t_push_reject_rolls_back: status=아카이브 보류" "$(status_in "$WT")" "아카이브 보류"
  eq "t_push_reject_rolls_back: 색인 pr-head 없음" "$(in_repo dpr_index_get "$SLUG" pr-head)" ""
  ok "t_push_reject_rolls_back: 재시도 안내" "rd publish request" "$(ar_out)"
  eq "t_push_reject_rolls_back: pr create 0" "$(gh_count 'pr create')" "0"
}
want t_push_reject_rolls_back && t_push_reject_rolls_back

t_pr_create_fail_keeps() {
  local tip0 cl
  mk_direct pr; setup_fake_gh
  export FAKE_GH_FAIL=create
  tip0="$(fr_tip)"
  run_ar
  unset FAKE_GH_FAIL
  cl="$(fr_tip)"
  eq "t_pr_create_fail_keeps: rc 1" "$AR_RC" "1"
  eq "t_pr_create_fail_keeps: origin fr/demo == 로컬 fr/demo" "$(og "$FRB")" "$cl"
  eq "t_pr_create_fail_keeps: 정리 커밋 보존" "$(git -C "$R" log -1 --format=%s "$(og "$FRB")")" "chore(lifecycle): archive demo metadata 정리"
  [[ "$cl" != "$tip0" ]] && pass "t_pr_create_fail_keeps: 로컬 fr tip 이 정리 커밋" || fail "t_pr_create_fail_keeps: 로컬 fr tip 이 실행 전과 같음"
  ok "t_pr_create_fail_keeps: 재시도 안내" "rd pr open --task demo" "$(ar_out)"
}
want t_pr_create_fail_keeps && t_pr_create_fail_keeps

echo "== rd pr open·check·reopen (직접 설치) =="

# run_list — R(기본 체크아웃)에서 rd task list 를 실행해 출력은 $LST_OUT, rc 는 LST_RC 에 둡니다.
LST_OUT="$TMP/lst.out"
run_list() { ( cd "$R" && bash rd-workflow/scripts/rd task list ) >"$LST_OUT" 2>&1; LST_RC=$?; }
lst() { cat "$LST_OUT"; }
# demo_row — rd task list 출력에서 demo 작업의 본 행(첫 칸이 demo)
demo_row() { awk '$1=="demo"{print; exit}' "$LST_OUT"; }

# run_pr <rd pr 인자...> — $PR_CWD(기본 $R)에서 rd pr 를 실행해 출력은 $DPR_OUT, rc 는 DPR_RC 에 둡니다.
DPR_OUT="$TMP/dpr.out"
run_pr() { ( cd "${PR_CWD:-$R}" && bash rd-workflow/scripts/rd pr "$@" ) >"$DPR_OUT" 2>&1; DPR_RC=$?; }
pr_out() { cat "$DPR_OUT"; }
# set_pr_col <칸 번호> <값> — 가짜 gh 의 마지막 PR 행의 한 칸을 바꿉니다(1 url 2 state 3 base 4 head-oid 5 merge-oid 6 mergeable 7 review).
set_pr_col() {
  awk -F'\t' -v OFS='\t' -v c="$1" -v v="$2" '{ r[NR] = $0 } END {
    for (i = 1; i <= NR; i++) {
      if (i == NR) { split(r[i], a, "\t"); a[c] = v; s = a[1]; for (j = 2; j <= 8; j++) s = s OFS a[j]; print s } else print r[i] } }' \
    "$FAKE/prs.tsv" >"$FAKE/prs.tsv.t" && mv "$FAKE/prs.tsv.t" "$FAKE/prs.tsv"
}
# publish_pr — pr 틀을 만들고 archive.sh 로 PR 을 올린 상태(t_pr_publish 와 같은 상태)까지 만듭니다.
publish_pr() { mk_direct pr; setup_fake_gh; run_ar; }
origin_tag_count() { git --git-dir="$ORIGIN" tag --list 'fr/*' | wc -l | tr -d ' '; }
# review_and_hold — 작업 worktree 에서 새 final diff review 세션을 종결·seal 하고 아카이브 보류 로 옮깁니다(t_conflict_stops 의 복구 절차).
review_and_hold() {
  local ses2
  ( cd "$WT" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff ) >"$TMP/prep3.log" 2>&1 || true
  ses2="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | tail -1)"
  [[ -n "$ses2" && "$ses2" != "$SES" ]] || { echo "새 리뷰 세션 생성 실패: $(cat "$TMP/prep3.log")" >&2; return 1; }
  mkdir -p "$ses2/turns"
  printf '# 001 Author\n\n## Summary\n요약\n\n## PR 본문\n\n### Summary\n- 무엇을: 데모 변경\n\n### User-visible Changes\n- 없음\n\n## Questions For Reviewer\n- 없음\n' >"$ses2/turns/001_author.md"
  seal_and_hold "$WT" "$ses2"
}

# warn_wrap <저장소 루트> — 그 저장소의 team_publish.sh 끝에 tp_extract_pr_body 를 감싸 `rd pr: WARNING — 테스트` 를 stderr 로 내는 정의를
# 덧붙입니다(github-issue 형식 경고를 내는 실제 검사는 이 브랜치에 아직 없습니다). 직접 실행 갈래 뒤라 source 한 셸에서만 적용됩니다.
warn_wrap() {
  cat >>"$1/rd-workflow/scripts/lifecycle/team_publish.sh" <<'WRAP_EOF'
eval "_tp_extract_pr_body_orig() $(declare -f tp_extract_pr_body | sed 1d)"
tp_extract_pr_body() { printf 'rd pr: WARNING — 테스트\n' >&2; _tp_extract_pr_body_orig "$@"; }
WRAP_EOF
  git -C "$1" commit -q -am "테스트: 경고 감싸기" || return 1
}

t_pr_issue_warning_shown() {
  mk_direct pr; setup_fake_gh
  warn_wrap "$WT" && warn_wrap "$R" && review_and_hold || { fail "t_pr_issue_warning_shown: 준비 실패"; return; }
  run_ar
  eq "t_pr_issue_warning_shown: 발행 rc 0" "$AR_RC" "0"
  ok "t_pr_issue_warning_shown: 발행 경고 표시" "rd pr: WARNING — 테스트" "$(ar_out)"
  run_pr open --task "$SLUG"
  eq "t_pr_issue_warning_shown: open rc 0" "$DPR_RC" "0"
  ok "t_pr_issue_warning_shown: open 경고 표시" "rd pr: WARNING — 테스트" "$(pr_out)"
}
want t_pr_issue_warning_shown && t_pr_issue_warning_shown

t_open_retries_pr() {
  local body tip
  mk_direct pr; setup_fake_gh
  export FAKE_GH_FAIL=create
  run_ar
  unset FAKE_GH_FAIL
  tip="$(fr_tip)"
  run_pr open --task "$SLUG"
  eq "t_open_retries_pr: rc 0" "$DPR_RC" "0"
  eq "t_open_retries_pr: pr create 2(실패 1 + 성공 1)" "$(gh_count 'pr create')" "2"
  ok "t_open_retries_pr: 색인 pr-url" "https://github.com/acme/demo/pull/1" "$(in_repo dpr_index_get "$SLUG" pr-url)"
  eq "t_open_retries_pr: origin fr 불변" "$(og "$FRB")" "$tip"
  body="$(cat "$FAKE/body" 2>/dev/null)"
  ok "t_open_retries_pr: 본문 무엇을" "무엇을: 데모 변경" "$body"
  ok "t_open_retries_pr: 본문 Closes" "Closes $ISSUE_URL" "$body"
  ok "t_open_retries_pr: 결과 안내" "PR 검토 중" "$(pr_out)"
}
want t_open_retries_pr && t_open_retries_pr

t_open_edit_fail_retry() {
  local url0 tip c0 e0
  publish_pr
  url0="$(in_repo dpr_index_get "$SLUG" pr-url)"; tip="$(fr_tip)"
  export FAKE_GH_FAIL=edit
  run_pr open --task "$SLUG"
  unset FAKE_GH_FAIL
  eq "t_open_edit_fail_retry: 실패 rc 1" "$DPR_RC" "1"
  eq "t_open_edit_fail_retry: 색인 pr-url 불변" "$(in_repo dpr_index_get "$SLUG" pr-url)" "$url0"
  eq "t_open_edit_fail_retry: origin fr 보존(로컬 fr 와 같음)" "$(og "$FRB")" "$(fr_tip)"
  eq "t_open_edit_fail_retry: 로컬 fr tip 불변" "$(fr_tip)" "$tip"
  ok "t_open_edit_fail_retry: 재시도 안내" "rd pr open --task demo" "$(pr_out)"
  c0="$(gh_count 'pr create')"; e0="$(gh_count 'pr edit')"
  run_pr open --task "$SLUG"
  eq "t_open_edit_fail_retry: 재시도 rc 0" "$DPR_RC" "0"
  eq "t_open_edit_fail_retry: pr create 0 추가" "$(( $(gh_count 'pr create') - c0 ))" "0"
  eq "t_open_edit_fail_retry: pr edit 성공 1" "$(( $(gh_count 'pr edit') - e0 ))" "1"
}
want t_open_edit_fail_retry && t_open_edit_fail_retry

t_open_on_hold_rc2() {
  mk_direct pr; setup_fake_gh
  run_pr open --task "$SLUG"
  eq "t_open_on_hold_rc2: rc 2" "$DPR_RC" "2"
  ok "t_open_on_hold_rc2: 발행 요청 안내" "rd publish request" "$(pr_out)"
  eq "t_open_on_hold_rc2: gh 호출 0" "$(gh_count .)" "0"
}
want t_open_on_hold_rc2 && t_open_on_hold_rc2

t_check_states() {
  local st
  publish_pr
  for st in OPEN CHANGES_REQUESTED CONFLICTING CLOSED MERGED; do
    set_pr_col 2 OPEN; set_pr_col 6 MERGEABLE; set_pr_col 7 ""
    case "$st" in
      CHANGES_REQUESTED) set_pr_col 7 CHANGES_REQUESTED ;;
      CONFLICTING) set_pr_col 6 CONFLICTING ;;
      CLOSED) set_pr_col 2 CLOSED ;;
      MERGED) set_pr_col 2 MERGED ;;
    esac
    run_pr check --task "$SLUG"
    eq "t_check_states: $st rc 0" "$DPR_RC" "0"
    case "$st" in
      OPEN) ok "t_check_states: OPEN 안내" "PR 검토 중" "$(pr_out)" ;;
      CHANGES_REQUESTED) ok "t_check_states: 수정 요청 안내" "수정 요청" "$(pr_out)"; ok "t_check_states: 수정 요청 reopen" "rd pr reopen --task demo" "$(pr_out)" ;;
      # 기본 쪽이 앞서지 않아 로컬 계산은 충돌이 없습니다(dpr_sync_tree rc 0) — change spec 2026-11-19-1430 D6 대로 sync 를 안내합니다.
      # 코드 충돌의 종전 순서는 t_check_suggests_sync 가 봅니다.
      CONFLICTING) ok "t_check_states: 충돌 안내" "충돌" "$(pr_out)"; ok "t_check_states: 충돌 sync 안내" "rd pr sync --task demo" "$(pr_out)" ;;
      CLOSED) ok "t_check_states: 닫힘 안내" "닫힘" "$(pr_out)"; ok "t_check_states: 닫힘 gh pr reopen" "gh pr reopen" "$(pr_out)" ;;
      MERGED) ok "t_check_states: merge 됨 안내" "merge 됨" "$(pr_out)"; ok "t_check_states: merge 됨 --apply" "--apply" "$(pr_out)" ;;
    esac
  done
}
want t_check_states && t_check_states

# apply_merged <merge|squash|rebase> — 그 방식으로 merge 한 PR 을 --apply 로 마감하고 결과를 단언합니다.
apply_merged() {
  local m="$1" pr_head tag mo
  publish_pr; pr_head="$(fr_tip)"
  fake_merge "$m" || { fail "t_apply_$m: 준비 — fake_merge 실패"; return; }
  mo="$(og main)"
  run_pr check --task "$SLUG" --apply
  eq "t_apply_$m: rc 0" "$DPR_RC" "0"
  eq "t_apply_$m: 태그 1개" "$(tag_count)" "1"
  tag="$(git -C "$R" tag --list 'fr/*' | head -1)"
  eq "t_apply_$m: 태그 → merge 커밋" "$(git -C "$R" rev-parse "refs/tags/$tag^{commit}" 2>/dev/null)" "$mo"
  ok "t_apply_$m: 주석 pr-head" "pr-head: $pr_head" "$(git -C "$R" tag -l --format='%(contents)' "$tag")"
  ok "t_apply_$m: 주석 pr" "pr: https://github.com/acme/demo/pull/1" "$(git -C "$R" tag -l --format='%(contents)' "$tag")"
  eq "t_apply_$m: origin 태그 1개" "$(origin_tag_count)" "1"
  eq "t_apply_$m: 색인 state" "$(in_repo dpr_index_get "$SLUG" state)" "cleanup-pending"
  eq "t_apply_$m: origin fr 삭제" "$(og "$FRB")" ""
  ok "t_apply_$m: 마감됨" "마감됨" "$(pr_out)"
}
t_apply_merge() { apply_merged merge; }
want t_apply_merge && t_apply_merge
t_apply_squash() { apply_merged squash; }
want t_apply_squash && t_apply_squash
t_apply_rebase() { apply_merged rebase; }
want t_apply_rebase && t_apply_rebase

t_apply_not_merged() {
  publish_pr
  fake_merge merge || { fail "t_apply_not_merged: 준비 실패"; return; }
  set_pr_col 2 OPEN
  run_pr check --task "$SLUG" --apply
  eq "t_apply_not_merged: rc 1" "$DPR_RC" "1"
  eq "t_apply_not_merged: 태그 0" "$(tag_count)" "0"
  ok "t_apply_not_merged: 안내" "merge 되지 않았습니다" "$(pr_out)"
}
want t_apply_not_merged && t_apply_not_merged

t_apply_base_mismatch() {
  publish_pr
  fake_merge merge || { fail "t_apply_base_mismatch: 준비 실패"; return; }
  set_pr_col 3 develop
  run_pr check --task "$SLUG" --apply
  eq "t_apply_base_mismatch: rc 1" "$DPR_RC" "1"
  eq "t_apply_base_mismatch: 태그 0" "$(tag_count)" "0"
  eq "t_apply_base_mismatch: 색인 state 없음" "$(in_repo dpr_index_get "$SLUG" state)" ""
}
want t_apply_base_mismatch && t_apply_base_mismatch

t_apply_head_mismatch() {
  publish_pr
  fake_merge merge || { fail "t_apply_head_mismatch: 준비 실패"; return; }
  set_pr_col 4 "$(og main)"
  run_pr check --task "$SLUG" --apply
  eq "t_apply_head_mismatch: rc 1" "$DPR_RC" "1"
  eq "t_apply_head_mismatch: 태그 0" "$(tag_count)" "0"
  eq "t_apply_head_mismatch: 색인 state 없음" "$(in_repo dpr_index_get "$SLUG" state)" ""
  ok "t_apply_head_mismatch: 안내" "리뷰한 커밋 뒤에 커밋이 더해진" "$(pr_out)"
}
want t_apply_head_mismatch && t_apply_head_mismatch

t_apply_repo_mismatch() {
  local other="https://github.com/other/demo/pull/1"
  publish_pr
  fake_merge merge || { fail "t_apply_repo_mismatch: 준비 실패"; return; }
  # 가짜 gh 는 URL 로 PR 을 찾으므로 색인과 가짜 gh 의 URL 을 함께 바꿉니다(조회는 성공하고 저장소만 다른 상황).
  set_pr_col 1 "$other"
  in_repo dpr_index_set "$SLUG" "pr-url=$other"
  run_pr check --task "$SLUG" --apply
  eq "t_apply_repo_mismatch: rc 1" "$DPR_RC" "1"
  eq "t_apply_repo_mismatch: 태그 0" "$(tag_count)" "0"
  ok "t_apply_repo_mismatch: origin 저장소 이름" "acme/demo" "$(pr_out)"
}
want t_apply_repo_mismatch && t_apply_repo_mismatch

t_apply_not_in_remote() {
  publish_pr
  set_pr_col 2 MERGED
  set_pr_col 5 "$(fr_tip)"
  run_pr check --task "$SLUG" --apply
  eq "t_apply_not_in_remote: rc 1" "$DPR_RC" "1"
  eq "t_apply_not_in_remote: 태그 0" "$(tag_count)" "0"
}
want t_apply_not_in_remote && t_apply_not_in_remote

t_apply_tag_push_fail_retry() {
  publish_pr
  fake_merge merge || { fail "t_apply_tag_push_fail_retry: 준비 실패"; return; }
  printf '#!/bin/sh\nwhile read old new ref; do case "$ref" in refs/tags/*) echo "tag 거부" >&2; exit 1;; esac; done\nexit 0\n' >"$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  run_pr check --task "$SLUG" --apply
  eq "t_apply_tag_push_fail_retry: rc 1" "$DPR_RC" "1"
  eq "t_apply_tag_push_fail_retry: 색인 state 없음" "$(in_repo dpr_index_get "$SLUG" state)" ""
  run_list
  ok "t_apply_tag_push_fail_retry: list 가 rd pr check --apply 를 안내" "확인: bash rd-workflow/scripts/rd pr check --task $SLUG --apply" "$(lst)"
  printf '#!/bin/sh\nexit 0\n' >"$ORIGIN/hooks/pre-receive"
  run_pr check --task "$SLUG" --apply
  eq "t_apply_tag_push_fail_retry: 재실행 rc 0" "$DPR_RC" "0"
  eq "t_apply_tag_push_fail_retry: 태그 수 1" "$(tag_count)" "1"
  eq "t_apply_tag_push_fail_retry: 색인 state" "$(in_repo dpr_index_get "$SLUG" state)" "cleanup-pending"
}
want t_apply_tag_push_fail_retry && t_apply_tag_push_fail_retry

# 발행 큐 경로 — 허가된 요청을 rd publish run 으로 실행해 PR 만 올라가면 done 으로 기록합니다 (spec D3a).
# 요청·허가 단계는 test_publish_queue.sh 의 mkstate 와 같이 큐 함수(pq_set·pq_slot_set)로 만듭니다.
pq_in_wt() { ( cd "$WT" && project_root="$WT" bash "$WT/rd-workflow/scripts/lifecycle/publish_queue.sh" "$@" ) 2>&1; }
t_queue_pr_done() {
  local out rc main0 head
  mk_direct pr; setup_fake_gh
  main0="$(og main)"; head="$(git -C "$WT" rev-parse HEAD)"
  ( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_set "$2" state=granted head="$3" seq=1 worktree="$4" fr-branch="$5"; pq_slot_set "$2"' \
      _ "$WT/rd-workflow/scripts/lifecycle/publish_queue.sh" "$SLUG" "$head" "$WT" "$FRB" ) || { fail "t_queue_pr_done: 준비 실패"; return; }
  out="$(pq_in_wt run)"; rc=$?
  eq "t_queue_pr_done: rc 0" "$rc" "0"
  eq "t_queue_pr_done: 큐 상태 done" "$( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_get "$2" state' _ "$WT/rd-workflow/scripts/lifecycle/publish_queue.sh" "$SLUG")" "done"
  ok "t_queue_pr_done: PR 발행 완료 문구" "PR 발행 완료: $SLUG" "$out"
  no "t_queue_pr_done: 발행 실패 문구 없음" "발행 실패" "$out"
  eq "t_queue_pr_done: pr create 1회" "$(gh_count 'pr create')" "1"
  eq "t_queue_pr_done: origin main 불변" "$(og main)" "$main0"
}
want t_queue_pr_done && t_queue_pr_done

t_queue_pr_p9_fail() {
  local out rc head pqs="$WT/rd-workflow/scripts/lifecycle/publish_queue.sh"
  mk_direct pr; setup_fake_gh
  head="$(git -C "$WT" rev-parse HEAD)"
  ( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_set "$2" state=granted head="$3" seq=1 worktree="$4" fr-branch="$5"; pq_slot_set "$2"' \
      _ "$pqs" "$SLUG" "$head" "$WT" "$FRB" ) || { fail "t_queue_pr_p9_fail: 준비 실패"; return; }
  export FAKE_GH_FAIL=create
  out="$(pq_in_wt run)"; rc=$?
  unset FAKE_GH_FAIL
  eq "t_queue_pr_p9_fail: rc 1" "$rc" "1"
  eq "t_queue_pr_p9_fail: 큐 상태 failed" "$( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_get "$2" state' _ "$pqs" "$SLUG")" "failed"
  ok "t_queue_pr_p9_fail: 발행 실패 문구" "발행 실패" "$out"
  ok "t_queue_pr_p9_fail: 재시도 안내" "rd pr open --task $SLUG" "$out"
  no "t_queue_pr_p9_fail: PR 발행 완료 없음" "PR 발행 완료" "$out"
  # recover 판정: running 으로 되돌린 상태에서도 pr-url 이 없으면 done 으로 보지 않는다.
  ( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_set "$2" state=running run-pid=999999 archive-pgid= run-token=x' _ "$pqs" "$SLUG" )
  out="$(pq_in_wt recover "$SLUG")"
  no "t_queue_pr_p9_fail: recover 가 done 으로 보지 않음" "PR 발행이 이미 끝났습니다" "$out"
}
want t_queue_pr_p9_fail && t_queue_pr_p9_fail

# 재발행(열린 PR 의 본문 갱신)에서 P9 edit 가 실패하면 이전 발행의 pr-url 이 남아 있어도 끝난 요청으로 보지 않는다.
t_queue_pr_republish_edit_fail() {
  local out rc head pqs="$WT/rd-workflow/scripts/lifecycle/publish_queue.sh"
  publish_pr
  run_pr reopen --task "$SLUG"
  review_and_hold || { fail "t_queue_pr_republish_edit_fail: 준비 실패(재리뷰)"; return; }
  pqs="$WT/rd-workflow/scripts/lifecycle/publish_queue.sh"; head="$(git -C "$WT" rev-parse HEAD)"
  ( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_set "$2" state=granted head="$3" seq=1 worktree="$4" fr-branch="$5"; pq_slot_set "$2"' \
      _ "$pqs" "$SLUG" "$head" "$WT" "$FRB" ) || { fail "t_queue_pr_republish_edit_fail: 준비 실패(큐)"; return; }
  export FAKE_GH_FAIL=edit
  out="$(pq_in_wt run)"; rc=$?
  unset FAKE_GH_FAIL
  eq "t_queue_pr_republish_edit_fail: rc 1" "$rc" "1"
  eq "t_queue_pr_republish_edit_fail: 큐 상태 failed" "$( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_get "$2" state' _ "$pqs" "$SLUG")" "failed"
  no "t_queue_pr_republish_edit_fail: PR 발행 완료 없음" "PR 발행 완료" "$out"
  ok "t_queue_pr_republish_edit_fail: 재시도 안내" "rd pr open --task $SLUG" "$out"
  ( cd "$WT" && project_root="$WT" bash -c 'source "$1"; pq_set "$2" state=running run-pid=999999 archive-pgid= run-token=x' _ "$pqs" "$SLUG" )
  out="$(pq_in_wt recover "$SLUG")"
  no "t_queue_pr_republish_edit_fail: recover 가 done 으로 보지 않음" "PR 발행이 이미 끝났습니다" "$out"
}
want t_queue_pr_republish_edit_fail && t_queue_pr_republish_edit_fail

# 색인 쓰기는 다른 lifecycle 명령이 tasks 락을 쥐고 있으면 기다리다 쓰지 않고 실패한다(공유 색인 갱신 손실 방지).
t_index_set_lock() {
  local sd spid rc
  mk_direct pr
  sd="$( cd "$R" && project_root="$R" && _tasks_shared_dir_fill && printf '%s' "$_TASKS_SD_VAL" )"
  sleep 30 & spid=$!
  mkdir "$sd/tasks.lock" && printf 'pid=%s\ncmd=tasks-list-rebuild\nslug=-\nstarted-at=x\n' "$spid" >"$sd/tasks.lock/owner"
  rc=0; ( cd "$R" && project_root="$R" && RD_DPR_LOCK_WAIT=1 dpr_index_set "$SLUG" "pr-url=https://x/pull/9" ) 2>"$TMP/lock.err" || rc=$?
  eq "t_index_set_lock: 점유 중이면 rc 1" "$rc" "1"
  eq "t_index_set_lock: 색인 불변" "$(in_repo dpr_index_get "$SLUG" pr-url)" ""
  ok "t_index_set_lock: 점유 안내" "기록하지 못했습니다" "$(cat "$TMP/lock.err")"
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  rm -rf "${sd:?}/tasks.lock"
  rc=0; ( cd "$R" && project_root="$R" && dpr_index_set "$SLUG" "pr-url=https://x/pull/9" ) || rc=$?
  eq "t_index_set_lock: 락이 풀리면 기록" "$(in_repo dpr_index_get "$SLUG" pr-url)" "https://x/pull/9"
  eq "t_index_set_lock: 기록 뒤 락 해제" "$([[ -d "$sd/tasks.lock" ]] && echo held || echo free)" "free"
}
want t_index_set_lock && t_index_set_lock

# 이전 발행이 push 뒤·브랜치 이동 전에 끊긴 상태 — 다시 발행하면 원격의 되돌리기 커밋으로 이어 가 PR 만 만든다.
t_resume_after_push() {
  local tip0 n0
  mk_direct pr; setup_fake_gh
  tip0="$(fr_tip)"
  clean_commit; [[ "$CLEAN_RC" == 0 ]] || { fail "t_resume_after_push: 준비 실패 — $(cat "$TMP/cc.err")"; return; }
  git -C "$R" push -q origin "$CLEAN_OID:refs/heads/$FRB" 2>/dev/null || { fail "t_resume_after_push: 준비 실패(push)"; return; }
  git -C "$WT" reset -q --keep "$tip0"
  n0="$(git --git-dir="$ORIGIN" rev-list --all --count)"
  run_ar
  eq "t_resume_after_push: rc 0" "$AR_RC" "0"
  ok "t_resume_after_push: 이어 가기 안내" "원격의 되돌리기 커밋" "$(ar_out)"
  eq "t_resume_after_push: 로컬 fr == 원격의 되돌리기 커밋" "$(fr_tip)" "$CLEAN_OID"
  eq "t_resume_after_push: 원격에 새 커밋 없음" "$(git --git-dir="$ORIGIN" rev-list --all --count)" "$n0"
  eq "t_resume_after_push: pr create 1" "$(gh_count 'pr create')" "1"
}
want t_resume_after_push && t_resume_after_push

# 되돌리기 커밋만 남고(커밋 직후 끊김) push 되지 않은 상태 — Status 거부 대신 되돌릴 명령을 알리고 아무것도 바꾸지 않는다.
t_cleanup_interrupt_hint() {
  local tip0
  mk_direct pr; setup_fake_gh
  tip0="$(fr_tip)"
  clean_commit; [[ "$CLEAN_RC" == 0 ]] || { fail "t_cleanup_interrupt_hint: 준비 실패 — $(cat "$TMP/cc.err")"; return; }
  run_ar --task "$SLUG"
  eq "t_cleanup_interrupt_hint: rc 1" "$AR_RC" "1"
  ok "t_cleanup_interrupt_hint: 되돌릴 명령" "reset --keep $(git -C "$R" rev-parse --short "$tip0")" "$(ar_out)"
  no "t_cleanup_interrupt_hint: Status 거부 아님" "Status 검사 실패" "$(ar_out)"
  eq "t_cleanup_interrupt_hint: fr tip 불변" "$(fr_tip)" "$CLEAN_OID"
}
want t_cleanup_interrupt_hint && t_cleanup_interrupt_hint

# 마감(--apply, 원격 fr 삭제) 뒤 같은 발행을 다시 실행해도 완료 기록을 바꾸지 않고 마감됐다고 알린다.
t_rerun_after_apply() {
  local tip0 head0
  publish_pr; fake_merge squash
  run_pr check --task "$SLUG" --apply
  [[ "$DPR_RC" == 0 ]] || { fail "t_rerun_after_apply: 준비 실패(apply) — $(pr_out)"; return; }
  tip0="$(fr_tip)"; head0="$(in_repo dpr_index_get "$SLUG" pr-head)"
  run_ar --task "$SLUG"
  eq "t_rerun_after_apply: rc 1" "$AR_RC" "1"
  ok "t_rerun_after_apply: 마감 안내" "이미 마감됐습니다" "$(ar_out)"
  eq "t_rerun_after_apply: fr tip 불변" "$(fr_tip)" "$tip0"
  eq "t_rerun_after_apply: 색인 pr-head 불변" "$(in_repo dpr_index_get "$SLUG" pr-head)" "$head0"
  eq "t_rerun_after_apply: 색인 state 불변" "$(in_repo dpr_index_get "$SLUG" state)" "cleanup-pending"
}
want t_rerun_after_apply && t_rerun_after_apply

# push 까지 끝난 뒤 P9 전에 중단된 상태에서 다시 발행하면 Status 거부 대신 rd pr open 을 안내한다.
t_rerun_after_push_hint() {
  local tip0
  publish_pr; tip0="$(fr_tip)"
  run_ar --task "$SLUG"
  eq "t_rerun_after_push_hint: rc 1" "$AR_RC" "1"
  ok "t_rerun_after_push_hint: rd pr open 안내" "rd pr open --task $SLUG" "$(ar_out)"
  no "t_rerun_after_push_hint: Status 거부 아님" "Status 검사 실패" "$(ar_out)"
  eq "t_rerun_after_push_hint: fr tip 불변" "$(fr_tip)" "$tip0"
  # 원격을 조회하지 못하면 push 여부를 단정하지 않고(되돌릴 명령 없음) 연결 확인을 안내한다.
  mv "$ORIGIN" "$ORIGIN.offline"
  run_ar --task "$SLUG"
  mv "$ORIGIN.offline" "$ORIGIN"
  eq "t_rerun_after_push_hint: 원격 불가 rc 1" "$AR_RC" "1"
  ok "t_rerun_after_push_hint: 원격 불가 판정 불가 안내" "원격을 조회하지 못해 판정할 수 없습니다" "$(ar_out)"
  no "t_rerun_after_push_hint: 원격 불가 되돌릴 명령 없음" "reset --keep" "$(ar_out)"
  eq "t_rerun_after_push_hint: 원격 불가 fr tip 불변" "$(fr_tip)" "$tip0"
}
want t_rerun_after_push_hint && t_rerun_after_push_hint

t_reopen() {
  local n0 out
  publish_pr; n0="$(git -C "$R" rev-list --count "$FRB")"
  run_pr reopen --task "$SLUG"; out="$(pr_out)"
  eq "t_reopen: rc 0" "$DPR_RC" "0"
  eq "t_reopen: status=구현 중" "$(status_in "$WT")" "구현 중"
  eq "t_reopen: short-title=demo" "$(awk -F= '$1=="short-title"{print $2}' "$WT/rd-workflow-workspace/.lifecycle/task-state")" "demo"
  eq "t_reopen: 새 커밋 1개" "$(( $(git -C "$R" rev-list --count "$FRB") - n0 ))" "1"
  eq "t_reopen: worktree clean" "$(git -C "$WT" status --porcelain --untracked-files=all)" ""
  ok "t_reopen: 발행 요청 안내" "rd publish request" "$out"
  n0="$(gh_count .)"
  run_list
  ok "t_reopen: list 단계 구현 중" "구현 중" "$(demo_row)"
  ok "t_reopen: list 연결된 PR 줄" "→ 연결된 PR: https://github.com/acme/demo/pull/1" "$(lst)"
  no "t_reopen: list PR 검토 중 없음" "PR 검토 중" "$(lst)"
  eq "t_reopen: list 가 gh 를 부르지 않음" "$(( $(gh_count .) - n0 ))" "0"
}
want t_reopen && t_reopen

t_reopen_no_tmpdir() {
  publish_pr
  ( cd "$R" && env -u TMPDIR bash rd-workflow/scripts/rd pr reopen --task "$SLUG" ) >"$DPR_OUT" 2>&1; DPR_RC=$?
  eq "t_reopen_no_tmpdir: rc 0" "$DPR_RC" "0"
  eq "t_reopen_no_tmpdir: status=구현 중" "$(status_in "$WT")" "구현 중"
  eq "t_reopen_no_tmpdir: worktree clean" "$(git -C "$WT" status --porcelain --untracked-files=all)" ""
}
want t_reopen_no_tmpdir && t_reopen_no_tmpdir

t_reopen_merged_rc1() {
  publish_pr
  fake_merge merge || { fail "t_reopen_merged_rc1: 준비 실패"; return; }
  run_pr reopen --task "$SLUG"
  eq "t_reopen_merged_rc1: rc 1" "$DPR_RC" "1"
  eq "t_reopen_merged_rc1: status 그대로" "$(status_in "$WT")" "대기 중"
}
want t_reopen_merged_rc1 && t_reopen_merged_rc1

t_closed_rollback() {
  local rc=0
  publish_pr
  set_pr_col 2 CLOSED
  run_pr check --task "$SLUG"
  eq "t_closed_rollback: rc 0" "$DPR_RC" "0"
  ok "t_closed_rollback: gh pr reopen" "gh pr reopen" "$(pr_out)"
  ok "t_closed_rollback: promote_rollback" "promote_rollback.sh --task demo" "$(pr_out)"
  ok "t_closed_rollback: 원격 fr 삭제 명령 전문" "git push origin --delete $FRB" "$(pr_out)"
  # 기본 체크아웃에서 조회해도 Issue 줄은 그 PR 이 연결한 Issue 로 만듭니다.
  eq "t_closed_rollback: 대상 작업의 Issue 선점 풀기" "$(closed_issue_no)" "7"
  ( cd "$R" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task "$SLUG" ) >"$TMP/rb.out" 2>&1 || rc=$?
  eq "t_closed_rollback: promote_rollback rc 0" "$rc" "0"
}
want t_closed_rollback && t_closed_rollback

# 닫힌 PR 의 Issue 줄은 그 PR 이 연결한 Issue 로 만듭니다 — 발행 뒤 로컬에서만 바꾼 Source FR·github-issue 를 따르지 않습니다.
t_closed_pinned_head() {
  local other="rd-workflow-workspace/backlog/items/2026-11-20-other.md"
  publish_pr
  run_pr reopen --task "$SLUG"
  printf '# 2026-11-20 other\n- status: validated\n- summary: 다른 작업\n- github-issue: https://github.com/acme/demo/issues/99\n' >"$WT/$other"
  ( cd "$WT" && bash rd-workflow/scripts/rd task set-source-fr "$other" ) >"$TMP/ssf.out" 2>&1 || { fail "t_closed_pinned_head: set-source-fr 실패"; return; }
  # 원래 FR 파일의 github-issue 도 로컬에서만 바꿉니다.
  sed 's|issues/7$|issues/99|' "$WT/$FR_ITEM" >"$TMP/fr.t" && cp "$TMP/fr.t" "$WT/$FR_ITEM"
  git -C "$WT" add -A; git -C "$WT" commit -q -m "로컬만 Source FR·Issue 변경"
  set_pr_col 2 CLOSED
  run_pr check --task "$SLUG"
  eq "t_closed_pinned_head: 닫힌 PR 의 Issue" "$(closed_issue_no)" "7"
}
want t_closed_pinned_head && t_closed_pinned_head

# 닫힌 PR 이 연결한 Issue 의 응답 해석(함수 직접 호출 — 1초 안쪽). 형식 밖 URL 은 버리고, 필드가 없는 응답(오류 등)과
# 조회 실패는 PR 화면에서 확인하라고 알립니다.
t_closed_linked_refs() {
  local u=https://github.com/acme/demo/pull/9 refs
  refs="$(printf '%s' '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[{"url":"https://github.com/acme/demo/issues/7"},{"url":"https://ghe.example.com/a/b/issues/9"},{"url":"$(id)"}]}}}}}' | _dpr_links_parse)"
  eq "t_closed_linked_refs: 연결된 Issue" "$refs" "https://github.com/acme/demo/issues/7 https://ghe.example.com/a/b/issues/9"
  refs="$(printf '%s' '{"errors":[{"message":"x"}]}' | _dpr_links_parse)"
  eq "t_closed_linked_refs: 필드 없는 응답" "$refs" "?"
  setup_fake_gh
  FAKE_GH_FAIL=graphql dpr_closed_choices demo "$u" fr/demo >"$DPR_OUT" 2>&1
  ok "t_closed_linked_refs: 조회하지 못함" "이 PR 에 연결된 Issue 를 조회하지 못했습니다 — $u 에서 확인하십시오" "$(grep '^    3) ' "$DPR_OUT")"
  # 연결이 없으면 PR 에서 확인할 위치를 보이고, 있으면 Issue 줄들 뒤에 출처 안내를 붙입니다.
  dpr_closed_choices demo "$u" fr/demo >"$DPR_OUT" 2>&1
  eq "t_closed_linked_refs: 연결 없음" "$(grep '^    3) ' "$DPR_OUT")" \
    "    3) 연결된 Issue 선점 풀기: gh issue edit <Issue URL> --remove-assignee @me (연결된 Issue 가 있을 때 — 이 PR 본문의 Closes 줄로 연결된 Issue 가 없습니다. $u 에서 확인하십시오)"
  printf '본문\n\nCloses https://github.com/acme/demo/issues/99\n\nCloses https://github.com/acme/demo/issues/7\n' >"$FAKE/body-9"
  dpr_closed_choices demo "$u" fr/demo >"$DPR_OUT" 2>&1
  eq "t_closed_linked_refs: 본문의 다른 Closes 줄" "$(grep '^    3) ' "$DPR_OUT")" "$(printf '%s\n' \
    '    3) 연결된 Issue 선점 풀기: gh issue edit https://github.com/acme/demo/issues/99 --remove-assignee @me' \
    '    3) 연결된 Issue 선점 풀기: gh issue edit https://github.com/acme/demo/issues/7 --remove-assignee @me' \
    "    3) 위 Issue 는 이 PR 본문의 Closes 줄이 연결한 것입니다 — 이 작업의 Issue 가 아니면 선점을 풀지 마십시오($u)")"
  printf '본문\n\nCloses https://github.com/acme/demo/issues/99\n' >"$FAKE/body-9"
  dpr_closed_choices demo "$u" fr/demo >"$DPR_OUT" 2>&1
  eq "t_closed_linked_refs: 한 건일 때의 출처" "$(grep '^    3) ' "$DPR_OUT")" "$(printf '%s\n' \
    '    3) 연결된 Issue 선점 풀기: gh issue edit https://github.com/acme/demo/issues/99 --remove-assignee @me' \
    "    3) 위 Issue 는 이 PR 본문의 Closes 줄이 연결한 것입니다 — 이 작업의 Issue 가 아니면 선점을 풀지 마십시오($u)")"
}
want t_closed_linked_refs && t_closed_linked_refs

t_overlay_untouched() {
  mk_direct push; setup_fake_gh
  PR_CWD="$WT" run_pr check
  ok "t_overlay_untouched: overlay 출력(PR 기록 표)" "PR 기록 없음 — rd-workflow-workspace/.lifecycle/team-prs.tsv" "$(pr_out)"
}
want t_overlay_untouched && t_overlay_untouched

t_conflict_recover_republish() {
  local o1
  publish_pr
  o1="$(og "$FRB")"
  origin_push_other main app.txt "다른 변경" || { fail "t_conflict_recover_republish: 준비 실패"; return; }
  run_pr reopen --task "$SLUG"
  eq "t_conflict_recover_republish: reopen rc 0" "$DPR_RC" "0"
  git -C "$WT" fetch -q origin main
  git -C "$WT" merge -q origin/main >/dev/null 2>&1 || true
  printf '합친 결과\n' >"$WT/app.txt"
  git -C "$WT" add -A && git -C "$WT" commit -q -m "main 병합" || { fail "t_conflict_recover_republish: 병합 커밋 실패"; return; }
  review_and_hold || { fail "t_conflict_recover_republish: 새 seal 실패"; return; }
  run_ar
  eq "t_conflict_recover_republish: 재발행 rc 0" "$AR_RC" "0"
  eq "t_conflict_recover_republish: pr create 1" "$(gh_count 'pr create')" "1"
  eq "t_conflict_recover_republish: pr edit 1" "$(gh_count 'pr edit')" "1"
  eq "t_conflict_recover_republish: origin fr == 로컬 fr" "$(og "$FRB")" "$(fr_tip)"
  git -C "$R" merge-base --is-ancestor "$o1" "$(og "$FRB")" && pass "t_conflict_recover_republish: fast-forward push" || fail "t_conflict_recover_republish: 이전 origin fr 가 조상이 아님"
}
want t_conflict_recover_republish && t_conflict_recover_republish

echo "== rd task list·status — PR 대기 표시와 완료 판정 =="

t_list_pr_waiting() {
  local url="https://github.com/acme/demo/pull/1" st
  publish_pr
  run_list
  eq "t_list_pr_waiting: rc 0" "$LST_RC" "0"
  ok "t_list_pr_waiting: 단계 칸 PR 검토 중" "PR 검토 중" "$(demo_row)"
  ok "t_list_pr_waiting: 열림 행동 줄" "→ PR 검토 중: $url" "$(lst)"
  for st in CHANGES_REQUESTED CONFLICTING CLOSED MERGED; do
    set_pr_col 2 OPEN; set_pr_col 6 MERGEABLE; set_pr_col 7 ""
    case "$st" in
      CHANGES_REQUESTED) set_pr_col 7 CHANGES_REQUESTED ;;
      CONFLICTING) set_pr_col 6 CONFLICTING ;;
      CLOSED) set_pr_col 2 CLOSED ;;
      MERGED) set_pr_col 2 MERGED ;;
    esac
    run_list
    case "$st" in
      CHANGES_REQUESTED) ok "t_list_pr_waiting: 수정 요청 줄" "→ 수정 요청: bash rd-workflow/scripts/rd pr reopen --task demo" "$(lst)" ;;
      CONFLICTING) ok "t_list_pr_waiting: 충돌 줄" "→ 충돌: bash rd-workflow/scripts/rd pr check --task demo 로 복구 순서 확인" "$(lst)" ;;
      CLOSED) ok "t_list_pr_waiting: 닫힘 줄" "→ 닫힘: bash rd-workflow/scripts/rd pr check --task demo 로 선택지 확인" "$(lst)" ;;
      MERGED) ok "t_list_pr_waiting: merge 됨 줄" "→ merge 됨: bash rd-workflow/scripts/rd pr check --task demo --apply" "$(lst)" ;;
    esac
  done
}
want t_list_pr_waiting && t_list_pr_waiting

t_list_after_push_fail() {
  mk_direct pr; setup_fake_gh
  printf '#!/bin/sh\nwhile read old new ref; do case "$ref" in refs/heads/fr/*) echo "fr 거부" >&2; exit 1;; esac; done\nexit 0\n' >"$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  run_ar
  eq "t_list_after_push_fail: 준비 — archive rc 1" "$AR_RC" "1"
  run_list
  ok "t_list_after_push_fail: 단계 아카이브 보류" "아카이브 보류" "$(demo_row)"
  no "t_list_after_push_fail: PR 검토 중 없음" "PR 검토 중" "$(lst)"
}
want t_list_after_push_fail && t_list_after_push_fail

t_list_gh_fail() {
  publish_pr
  export FAKE_GH_FAIL=view
  run_list
  unset FAKE_GH_FAIL
  ok "t_list_gh_fail: 조회 실패 줄" "PR 상태 조회 실패" "$(lst)"
  ok "t_list_gh_fail: 확인 명령" "rd pr check --task demo" "$(lst)"
  ok "t_list_gh_fail: 단계는 PR 검토 중 유지" "PR 검토 중" "$(demo_row)"
}
want t_list_gh_fail && t_list_gh_fail

t_status_stdout_one_line() {
  local so se
  publish_pr
  ( cd "$WT" && bash rd-workflow/scripts/rd task status ) >"$TMP/st.out" 2>"$TMP/st.err"
  so="$(cat "$TMP/st.out")"; se="$(cat "$TMP/st.err")"
  eq "t_status_stdout_one_line: stdout 한 줄" "$so" "대기 중"
  ok "t_status_stdout_one_line: stderr 안내" "PR 검토 중(직접 설치 PR)" "$se"
  ok "t_status_stdout_one_line: stderr URL" "https://github.com/acme/demo/pull/1" "$se"
}
want t_status_stdout_one_line && t_status_stdout_one_line

# evidence_cleanup <merge 방식> — merge 방식별로 --apply 까지 마친 뒤 rd task list 가 WT·로컬 fr 브랜치를 정리하는지 봅니다.
evidence_cleanup() {
  local m="$1" rc=0 pout
  publish_pr
  fake_merge "$m" || { fail "t_evidence_${m}_cleanup: 준비 — fake_merge 실패"; return; }
  run_pr check --task "$SLUG" --apply
  eq "t_evidence_${m}_cleanup: 준비 — apply rc 0" "$DPR_RC" "0"
  [[ -d "$WT" ]] && pass "t_evidence_${m}_cleanup: 정리 전 WT 존재" || fail "t_evidence_${m}_cleanup: 정리 전 WT 가 이미 없음"
  run_list
  [[ ! -e "$WT" ]] && pass "t_evidence_${m}_cleanup: WT 정리됨" || fail "t_evidence_${m}_cleanup: WT 가 남음 — $(lst)"
  eq "t_evidence_${m}_cleanup: 로컬 fr 브랜치 정리됨" "$(fr_tip)" ""
  pout="$( cd "$R" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task "$SLUG" 2>&1 )" || rc=$?
  [[ "$rc" != 0 ]] && pass "t_evidence_${m}_cleanup: promote_rollback rc≠0" || fail "t_evidence_${m}_cleanup: promote_rollback 가 성공함"
  ok "t_evidence_${m}_cleanup: 이미 archive 안내" "이미 archive" "$pout"
}
t_evidence_squash_cleanup() { evidence_cleanup squash; }
want t_evidence_squash_cleanup && t_evidence_squash_cleanup
t_evidence_rebase_cleanup() { evidence_cleanup rebase; }
want t_evidence_rebase_cleanup && t_evidence_rebase_cleanup

t_evidence_no_tag_inprogress() {
  local ev tipc other
  publish_pr
  fake_merge merge || { fail "t_evidence_no_tag_inprogress: 준비 — fake_merge 실패"; return; }
  # --apply 를 하지 않은 채 색인에 state=cleanup-pending 만 있는(태그 없는) 훼손 상태: 증거가 정리를 막아야 합니다.
  in_repo dpr_index_set "$SLUG" "state=cleanup-pending"
  ev="$(in_repo tasks_publish_evidence "$SLUG" "$(fr_tip)" main remote)"
  eq "t_evidence_no_tag_inprogress: 태그 없음 → in-progress" "$ev" "in-progress"
  run_list
  [[ -d "$WT" ]] && pass "t_evidence_no_tag_inprogress: WT 존재" || fail "t_evidence_no_tag_inprogress: WT 가 정리됨 — $(lst)"
  eq "t_evidence_no_tag_inprogress: 로컬 fr 브랜치 존재" "$([[ -n "$(fr_tip)" ]] && echo yes || echo no)" "yes"
  # 다른 커밋을 가리키는 pr-head 주석의 slug 태그(원격에도 있음)는 증거가 아닙니다.
  git -C "$R" fetch -q origin main || { fail "t_evidence_no_tag_inprogress: 준비 — fetch 실패"; return; }
  other="$(git -C "$R" rev-parse origin/main)"
  git -C "$R" tag -a "fr/2026-11-17-0000/$SLUG" -m "$(printf 'archive: demo\npr-head: %s' "$other")" origin/main || { fail "t_evidence_no_tag_inprogress: 준비 — 태그 실패"; return; }
  git -C "$R" push -q origin "refs/tags/fr/2026-11-17-0000/$SLUG" || { fail "t_evidence_no_tag_inprogress: 준비 — 태그 push 실패"; return; }
  ev="$(in_repo tasks_publish_evidence "$SLUG" "$(fr_tip)" main remote)"
  eq "t_evidence_no_tag_inprogress: 다른 pr-head 태그 → in-progress" "$ev" "in-progress"
  run_list
  [[ -d "$WT" ]] && pass "t_evidence_no_tag_inprogress: 다른 pr-head 태그여도 WT 존재" || fail "t_evidence_no_tag_inprogress: 다른 pr-head 태그로 WT 가 정리됨 — $(lst)"
}
want t_evidence_no_tag_inprogress && t_evidence_no_tag_inprogress

echo "== sync 트리 계산과 검증 사슬 (change spec 2026-11-19-1430 D3·D4) =="

FRQ="rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
SYNC_SUBJ="merge: main into fr/demo (rd pr sync)"
# frq_table <행 제목...> — merge_fr_index.sh 가 받는 인덱스 표(제목 칸이 키).
frq_table() { printf '# Future Requests\n\n| 우선 | 제목 | 상태 |\n| --- | --- | --- |\n'; local r; for r in "$@"; do printf '| P2 | %s | open |\n' "$r"; done; }
# sync_fixture — PR 대기 작업을 만들고 기본 쪽이 기록 파일만 바꿔 앞서 나간 상태를 만듭니다.
#   되돌리기 커밋은 task-state 를 seed 와 같게 두고 FUTURE_REQUESTS.md 를 건드리지 않으므로, 발행 전에 기본 쪽에 인덱스를 두고
#   작업 쪽이 그것을 병합한 뒤 행 하나를 더하는 기록 커밋을 합니다(실제 흐름의 FR 정리 기록 커밋). 발행 뒤 기본 쪽이 다른 행과
#   task-state 한 줄을 바꿔 push 합니다 — merge-tree 충돌은 FUTURE_REQUESTS.md 하나입니다.
#   전역: CLEAN(되돌리기 커밋) OMAIN(origin/main OID)
sync_fixture() {
  mk_direct pr; setup_fake_gh
  frq_table base-row >"$R/$FRQ"; git -C "$R" add "$FRQ" && git -C "$R" commit -q -m "FR 등록" && git -C "$R" push -q origin main || return 1
  git -C "$WT" fetch -q origin main && git -C "$WT" merge -q --no-edit origin/main >/dev/null || return 1
  frq_table base-row fr-row >"$WT/$FRQ"; git -C "$WT" commit -q -am "기록: FR 행" || return 1
  run_ar; [[ "$AR_RC" == 0 ]] || { echo "sync_fixture: 발행 실패 — $(ar_out)" >&2; return 1; }
  CLEAN="$(fr_tip)"
  frq_table base-row main-row >"$R/$FRQ"
  awk '/^base-commit=/{print "base-commit=main-side"; next} {print}' "$R/rd-workflow-workspace/.lifecycle/task-state" >"$TMP/ts.t" \
    && cat "$TMP/ts.t" >"$R/rd-workflow-workspace/.lifecycle/task-state"
  git -C "$R" commit -q -am "기본 쪽 기록" && git -C "$R" push -q origin main || return 1
  OMAIN="$(git -C "$R" rev-parse refs/remotes/origin/main)"
}
# code_conflict — 기본 쪽이 fr 이 바꾼 app.txt 의 같은 줄을 바꿔 push 합니다.
code_conflict() { echo "main side" >"$R/app.txt"; git -C "$R" commit -q -am "기본 쪽 코드" && git -C "$R" push -q origin main && OMAIN="$(git -C "$R" rev-parse refs/remotes/origin/main)"; }
# commit_on <부모...> -- <트리> <제목> — commit-tree 한 줄 도우미.
commit_on() { local ps=() t s; while [[ "$1" != -- ]]; do ps+=( -p "$1" ); shift; done; shift; t="$1"; s="$2"; git -C "$R" commit-tree "$t" "${ps[@]}" -m "$s"; }
# mk_sync <첫 부모> <둘째 부모> — dpr_sync_tree 로 트리를 계산해 정상 sync 병합 커밋을 만듭니다(stdout OID).
mk_sync() { local t; t="$(in_repo dpr_sync_tree "$R" "$1" "$2")" || return 1; commit_on "$1" "$2" -- "$t" "$SYNC_SUBJ"; }
# add_file_commit <부모> <경로> <내용> <제목> — 부모 트리에 파일 하나를 더한 커밋(임시 인덱스, 작업 트리 불변).
add_file_commit() {
  local idx="$TMP/addidx.$$" b t
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$R" read-tree "$1" || return 1
  b="$(printf '%s\n' "$3" | git -C "$R" hash-object -w --stdin)" || return 1
  GIT_INDEX_FILE="$idx" git -C "$R" update-index --add --cacheinfo "100644,$b,$2" || return 1
  t="$(GIT_INDEX_FILE="$idx" git -C "$R" write-tree)" || return 1
  rm -f "$idx"
  commit_on "$1" -- "$t" "$4"
}
# ph <커밋> — dpr_published_head 를 부릅니다. stdout PH_OUT, rc PH_RC.
ph() { PH_OUT="$(in_repo dpr_published_head "$R" "$1" "$SLUG" refs/remotes/origin/main 2>"$TMP/ph.err")"; PH_RC=$?; }
# st <작업> <기본> — dpr_sync_tree 를 부릅니다. stdout ST_OUT, stderr ST_ERR, rc ST_RC.
st() { ST_OUT="$(in_repo dpr_sync_tree "$R" "$1" "$2" 2>"$TMP/st.err")"; ST_RC=$?; ST_ERR="$(cat "$TMP/st.err")"; }
# fr_to <커밋> — 로컬 fr(작업 worktree)과 원격 fr 을 그 커밋으로 옮깁니다(fast-forward).
fr_to() { git -C "$WT" merge -q --ff-only "$1" >/dev/null && git -C "$R" push -q origin "$1:refs/heads/$FRB"; }

t_sync_tree_records_only() {
  local t frq
  sync_fixture || { fail "t_sync_tree_records_only: 준비 실패"; return; }
  st "$CLEAN" refs/remotes/origin/main
  eq "t_sync_tree_records_only: rc 0" "$ST_RC" "0"
  eq "t_sync_tree_records_only: stdout 은 트리" "$(git -C "$R" cat-file -t "$ST_OUT" 2>/dev/null)" "tree"
  frq=""; [[ -n "$ST_OUT" ]] && frq="$(git -C "$R" cat-file -p "$ST_OUT:$FRQ" 2>/dev/null)"
  ok "t_sync_tree_records_only: 작업 쪽 행" "| fr-row |" "$frq"
  ok "t_sync_tree_records_only: 기본 쪽 행" "| main-row |" "$frq"
  eq "t_sync_tree_records_only: 코드 파일은 작업 쪽" "$([[ -n "$ST_OUT" ]] && git -C "$R" cat-file -p "$ST_OUT:app.txt")" "changed"
  eq "t_sync_tree_records_only: 저장소 index·작업 트리 불변" "$(git -C "$R" status --porcelain --untracked-files=no)" ""
}
want t_sync_tree_records_only && t_sync_tree_records_only

t_sync_tree_other_conflict() {
  sync_fixture && code_conflict || { fail "t_sync_tree_other_conflict: 준비 실패"; return; }
  st "$CLEAN" refs/remotes/origin/main
  eq "t_sync_tree_other_conflict: rc 1" "$ST_RC" "1"
  eq "t_sync_tree_other_conflict: stdout 은 그 경로만" "$ST_OUT" "app.txt"
}
want t_sync_tree_other_conflict && t_sync_tree_other_conflict

t_sync_tree_unsupported() {
  local m="$TMP/mv" b
  sync_fixture && code_conflict || { fail "t_sync_tree_unsupported: 준비 실패"; return; }
  # (가) 병합 동작을 바꾸는 설정
  git -C "$R" config merge.default union
  st "$CLEAN" refs/remotes/origin/main
  eq "t_sync_tree_unsupported (가): merge.default rc" "$ST_RC" "3"
  ok "t_sync_tree_unsupported (가): 사유" "merge.default" "$ST_ERR"
  git -C "$R" config --unset merge.default
  # (라) 바뀐 경로의 merge 속성(커밋하지 않은 .gitattributes)
  printf 'app.txt merge=union\n' >"$R/.gitattributes"
  st "$CLEAN" refs/remotes/origin/main
  eq "t_sync_tree_unsupported (라): merge 속성 rc" "$ST_RC" "3"
  ok "t_sync_tree_unsupported (라): 사유에 경로" "app.txt" "$ST_ERR"
  rm -f "$R/.gitattributes"
  # (다) 없는 ref
  st "$CLEAN" refs/remotes/origin/no-such-branch
  eq "t_sync_tree_unsupported (다): 없는 ref rc" "$ST_RC" "3"
  # (나) 기본 쪽이 기록 파일을 100755 로 바꿈 — 기록 파일이라도 자동 해소하지 않음
  git -C "$R" reset -q --hard HEAD~1 && git -C "$R" push -q -f origin main || { fail "t_sync_tree_unsupported (나): 준비 실패"; return; }
  frq_table base-row main-row2 >"$R/$FRQ"; chmod +x "$R/$FRQ"
  git -C "$R" commit -q -am "기본 쪽 실행 비트" && git -C "$R" push -q origin main || { fail "t_sync_tree_unsupported (나): 준비 실패"; return; }
  st "$CLEAN" refs/remotes/origin/main
  eq "t_sync_tree_unsupported (나): 100755 rc" "$ST_RC" "1"
  eq "t_sync_tree_unsupported (나): stdout 에 그 경로" "$ST_OUT" "$FRQ"
  # (마) 작업 쪽 이름 변경 + 내용 변경, 기본 쪽은 옛 이름의 같은 줄 변경. 새 이름에만 merge 속성.
  rm -rf "$m"; git init -q -b main "$m"
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' >"$m/old"; git -C "$m" add old && git -C "$m" commit -q -m base
  b="$(git -C "$m" rev-parse HEAD)"
  git -C "$m" checkout -q -b work
  git -C "$m" mv old new && sed 's/^l2$/work/' "$m/new" >"$m/new.t" && mv "$m/new.t" "$m/new" && git -C "$m" commit -q -am "rename+edit"
  git -C "$m" checkout -q main
  sed 's/^l2$/main/' "$m/old" >"$m/old.t" && mv "$m/old.t" "$m/old" && git -C "$m" commit -q -am "edit old"
  printf 'new merge=union\n' >"$m/.gitattributes"
  ST_OUT="$( (cd "$m" && project_root="$m" dpr_sync_tree "$m" work main) 2>"$TMP/st.err")"; ST_RC=$?; ST_ERR="$(cat "$TMP/st.err")"
  eq "t_sync_tree_unsupported (마): 새 이름의 속성 rc" "$ST_RC" "3"
  ok "t_sync_tree_unsupported (마): 사유에 새 이름" "new" "$ST_ERR"
}
want t_sync_tree_unsupported && t_sync_tree_unsupported

t_published_head_chain() {
  local m
  sync_fixture || { fail "t_published_head_chain: 준비 실패"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" || { fail "t_published_head_chain: 준비 실패(M)"; return; }
  ph "$m"
  eq "t_published_head_chain: rc 0" "$PH_RC" "0"
  eq "t_published_head_chain: stdout 이 되돌리기 커밋" "$PH_OUT" "$CLEAN"
}
want t_published_head_chain && t_published_head_chain

t_published_head_rejects() {
  local m x t loc
  sync_fixture || { fail "t_published_head_rejects: 준비 실패"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" || { fail "t_published_head_rejects: 준비 실패(M)"; return; }
  # (가) M 위에 빈 커밋
  x="$(commit_on "$m" -- "$(git -C "$R" rev-parse "$m^{tree}")" "빈 커밋")"
  ph "$x"; eq "t_published_head_rejects (가): M 위 빈 커밋" "$PH_RC" "1"
  # (나) 같은 두 부모, 트리만 다름
  x="$(commit_on "$CLEAN" "$OMAIN" -- "$(git -C "$R" rev-parse "$OMAIN^{tree}")" "$SYNC_SUBJ")"
  ph "$x"; eq "t_published_head_rejects (나): 트리 다름" "$PH_RC" "1"
  # (다) 같은 트리, 둘째 부모가 origin/main 의 조상이 아님(push 하지 않은 로컬 커밋 — 트리는 origin/main 과 같음)
  loc="$(commit_on "$OMAIN" -- "$(git -C "$R" rev-parse "$OMAIN^{tree}")" "로컬 전용")"
  x="$(commit_on "$CLEAN" "$loc" -- "$(git -C "$R" rev-parse "$m^{tree}")" "$SYNC_SUBJ")"
  ph "$x"; eq "t_published_head_rejects (다): 범위 밖 둘째 부모" "$PH_RC" "1"
  # (라) 첫 부모가 되돌리기 커밋 위의 코드 커밋, 트리는 두 부모의 dpr_sync_tree 결과
  loc="$(add_file_commit "$CLEAN" code.txt "더한 코드" "코드 커밋")" || { fail "t_published_head_rejects (라): 준비 실패"; return; }
  x="$(mk_sync "$loc" "$OMAIN")" || { fail "t_published_head_rejects (라): 준비 실패(M)"; return; }
  ph "$x"; eq "t_published_head_rejects (라): 첫 부모가 되돌리기 커밋 아님" "$PH_RC" "1"
}
want t_published_head_rejects && t_published_head_rejects

t_open_external_merge() {
  local m
  sync_fixture || { fail "t_open_external_merge: 준비 실패"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" && fr_to "$m" || { fail "t_open_external_merge: 준비 실패(M)"; return; }
  run_pr open --task "$SLUG"
  eq "t_open_external_merge: rc 2" "$DPR_RC" "2"
  ok "t_open_external_merge: sync 안내" "rd pr sync --task demo" "$(pr_out)"
  eq "t_open_external_merge: 색인 pr-head 그대로" "$(in_repo dpr_index_get "$SLUG" pr-head)" "$CLEAN"
  # 병합 설정 때문에 대조할 수 없으면 판정 불가 안내에 그 사유가 붙습니다.
  git -C "$R" config merge.default union
  run_pr open --task "$SLUG"
  eq "t_open_external_merge: 대조 불가 rc 2" "$DPR_RC" "2"
  ok "t_open_external_merge: 대조 불가 사유" "사유: 병합 동작을 바꾸는 설정(merge.default)" "$(pr_out)"
}
want t_open_external_merge && t_open_external_merge

t_apply_empty_index_external() {
  local m
  sync_fixture || { fail "t_apply_empty_index_external: 준비 실패"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" && fr_to "$m" || { fail "t_apply_empty_index_external: 준비 실패(M)"; return; }
  in_repo dpr_index_set "$SLUG" "pr-head="
  fake_merge merge || { fail "t_apply_empty_index_external: 준비 — fake_merge 실패"; return; }
  run_pr check --task "$SLUG" --apply
  eq "t_apply_empty_index_external: rc 1" "$DPR_RC" "1"
  eq "t_apply_empty_index_external: 태그 0" "$(tag_count)" "0"
}
want t_apply_empty_index_external && t_apply_empty_index_external

t_apply_verified_list() {
  local m tag c
  # 원격 fr 이 merge 된 head 와 같으면 지움
  sync_fixture || { fail "t_apply_verified_list: 준비 실패"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" && fr_to "$m" || { fail "t_apply_verified_list: 준비 실패(M)"; return; }
  in_repo dpr_verified_add "$SLUG" "$CLEAN" "$m" || { fail "t_apply_verified_list: 준비 실패(pr-verified)"; return; }
  fake_merge merge || { fail "t_apply_verified_list: 준비 — fake_merge 실패"; return; }
  run_pr check --task "$SLUG" --apply
  eq "t_apply_verified_list: rc 0" "$DPR_RC" "0"
  tag="$(git -C "$R" tag --list 'fr/*' | head -1)"
  ok "t_apply_verified_list: 태그 pr-head 는 merge 된 head" "pr-head: $m" "$(git -C "$R" tag -l --format='%(contents)' "$tag")"
  eq "t_apply_verified_list: 원격 fr 삭제" "$(og "$FRB")" ""
  # 원격 fr 이 merge 뒤 다른 값으로 바뀌었으면 남김
  sync_fixture || { fail "t_apply_verified_list: 준비 실패(2)"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" && fr_to "$m" || { fail "t_apply_verified_list: 준비 실패(M2)"; return; }
  in_repo dpr_verified_add "$SLUG" "$CLEAN" "$m" || { fail "t_apply_verified_list: 준비 실패(pr-verified 2)"; return; }
  fake_merge merge || { fail "t_apply_verified_list: 준비 — fake_merge 실패(2)"; return; }
  c="$(add_file_commit "$m" late.txt "늦은 커밋" "merge 뒤 push")" && git -C "$R" push -q origin "$c:refs/heads/$FRB" \
    || { fail "t_apply_verified_list: 준비 실패(늦은 push)"; return; }
  run_pr check --task "$SLUG" --apply
  eq "t_apply_verified_list: 다른 원격 head rc 0" "$DPR_RC" "0"
  eq "t_apply_verified_list: 원격 fr 남음" "$(og "$FRB")" "$c"
  ok "t_apply_verified_list: 남긴 사유" "원격 fr 브랜치가 merge 된 head 와 달라 지우지 않았습니다" "$(pr_out)"
  ok "t_apply_verified_list: 확인 명령" "git log $m..origin/$FRB" "$(pr_out)"
}
want t_apply_verified_list && t_apply_verified_list

t_sync_reopen() {
  local m p rs
  sync_fixture || { fail "t_sync_reopen: 준비 실패"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" && fr_to "$m" || { fail "t_sync_reopen: 준비 실패(M)"; return; }
  in_repo dpr_index_set "$SLUG" "pr-head=$m" && in_repo dpr_verified_add "$SLUG" "$m" || { fail "t_sync_reopen: 준비 실패(색인)"; return; }
  # 기록 뒤 병합 환경이 바뀜 — 재계산하면 판정 불가지만 기록된 head 는 재계산하지 않습니다.
  git -C "$R" config merge.default union
  run_pr reopen --task "$SLUG"
  eq "t_sync_reopen: rc 0" "$DPR_RC" "0"
  eq "t_sync_reopen: status=구현 중" "$(status_in "$WT")" "구현 중"
  p="$CLEAN^"
  rs="$(git -C "$R" show "$p:rd-workflow-workspace/.lifecycle/task-state" | awk -F= '$1=="review-session"{print $2}')"
  [[ -n "$rs" && "$rs" != null ]] || fail "t_sync_reopen: 준비 — 부모의 review-session 이 비어 있음"
  eq "t_sync_reopen: review-session 은 되돌리기 커밋 부모의 것" "$(awk -F= '$1=="review-session"{print $2}' "$WT/rd-workflow-workspace/.lifecycle/task-state")" "$rs"
  # CURRENT_TASK.md 는 Status 칸(구현 중으로 바뀜)을 뺀 나머지가 부모의 것과 같아야 합니다.
  eq "t_sync_reopen: CURRENT_TASK.md 는 되돌리기 커밋 부모의 것" \
    "$(awk '/^## Status$/{print; getline; next} {print}' "$WT/CURRENT_TASK.md")" \
    "$(git -C "$R" show "$p:CURRENT_TASK.md" | awk '/^## Status$/{print; getline; next} {print}')"
  eq "t_sync_reopen: 복원 커밋은 sync head 위" "$(git -C "$R" rev-parse "$FRB^")" "$m"
}
want t_sync_reopen && t_sync_reopen

# 양쪽이 task-state(작업 쪽 규칙)와 CURRENT_TASK.md(기본 쪽 규칙)를 서로 다르게 바꾸면, 결과 트리는 task-state 를 작업 쪽,
# CURRENT_TASK.md 를 기본 쪽 blob 그대로 씁니다(merge-tree 의 stage 2 = 작업, 3 = 기본 대응).
t_sync_tree_stage_sides() {
  local m="$TMP/stg" ts="rd-workflow-workspace/.lifecycle/task-state" t
  rm -rf "$m"; git init -q -b main "$m"; mkdir -p "$m/rd-workflow-workspace/.lifecycle"
  printf 'schema=1\nstatus=base\nfr-branch=fr/demo\n' >"$m/$ts"; printf '# Current Task\n\nbase\n' >"$m/CURRENT_TASK.md"
  git -C "$m" add -A && git -C "$m" commit -q -m base
  git -C "$m" checkout -q -b work
  printf 'schema=1\nstatus=work\nfr-branch=fr/demo\n' >"$m/$ts"; printf '# Current Task\n\nwork\n' >"$m/CURRENT_TASK.md"
  git -C "$m" commit -q -am work
  git -C "$m" checkout -q main
  printf 'schema=1\nstatus=main\nfr-branch=fr/demo\n' >"$m/$ts"; printf '# Current Task\n\nmain\n' >"$m/CURRENT_TASK.md"
  git -C "$m" commit -q -am main
  t="$( (cd "$m" && project_root="$m" dpr_sync_tree "$m" work main) 2>"$TMP/st.err")"; ST_RC=$?
  eq "t_sync_tree_stage_sides: rc 0" "$ST_RC" "0"
  eq "t_sync_tree_stage_sides: task-state 는 작업 쪽 blob" "$(git -C "$m" rev-parse -q --verify "$t:$ts" 2>/dev/null)" "$(git -C "$m" rev-parse "work:$ts")"
  eq "t_sync_tree_stage_sides: CURRENT_TASK.md 는 기본 쪽 blob" "$(git -C "$m" rev-parse -q --verify "$t:CURRENT_TASK.md" 2>/dev/null)" "$(git -C "$m" rev-parse "main:CURRENT_TASK.md")"
}
want t_sync_tree_stage_sides && t_sync_tree_stage_sides

# fr 끝이 기록된 sync 병합(원격 일치)인 채 발행을 다시 실행하면 평소 발행(Status 거부)으로 넘어가지 않고 PR 단계만 남았다고 알립니다.
t_rerun_hint_sync_head() {
  local m c
  sync_fixture || { fail "t_rerun_hint_sync_head: 준비 실패"; return; }
  m="$(mk_sync "$CLEAN" "$OMAIN")" && fr_to "$m" || { fail "t_rerun_hint_sync_head: 준비 실패(M)"; return; }
  in_repo dpr_index_set "$SLUG" "pr-head=$m" && in_repo dpr_verified_add "$SLUG" "$m" || { fail "t_rerun_hint_sync_head: 준비 실패(색인)"; return; }
  run_ar --task "$SLUG"
  eq "t_rerun_hint_sync_head: rc 1" "$AR_RC" "1"
  ok "t_rerun_hint_sync_head: PR 단계만 남음 안내" "rd pr open --task $SLUG" "$(ar_out)"
  no "t_rerun_hint_sync_head: Status 거부 아님" "Status 검사 실패" "$(ar_out)"
  eq "t_rerun_hint_sync_head: fr tip 불변" "$(fr_tip)" "$m"
  # 검증된 sync 끝인데 원격 fr 이 다른 값이면 「push 되지 않은 되돌리기 커밋」(reset --keep)이 아니라 rd pr sync 로 보냅니다.
  c="$(add_file_commit "$m" late.txt "다른 작업자" "원격에만 있는 커밋")" && git -C "$R" push -q origin "$c:refs/heads/$FRB" \
    || { fail "t_rerun_hint_sync_head: 준비 실패(원격 전진)"; return; }
  run_ar --task "$SLUG"
  eq "t_rerun_hint_sync_head: 원격 다름 rc 1" "$AR_RC" "1"
  ok "t_rerun_hint_sync_head: 원격 다름 → rd pr sync 안내" "rd pr sync --task $SLUG" "$(ar_out)"
  no "t_rerun_hint_sync_head: 원격 다름 → reset --keep 없음" "reset --keep" "$(ar_out)"
  eq "t_rerun_hint_sync_head: 원격 다름 fr tip 불변" "$(fr_tip)" "$m"
}
want t_rerun_hint_sync_head && t_rerun_hint_sync_head

echo "== rd pr sync (change spec 2026-11-19-1430 D5·D6·D7) =="

# refs_snap — 로컬 저장소와 bare 원격의 모든 ref. 「ref·색인 불변」 단언의 관측 범위입니다(ref 에 닿지 않은 객체는 보지 않음).
refs_snap() { git -C "$R" for-each-ref --format='%(refname) %(objectname)'; echo ---; git --git-dir="$ORIGIN" for-each-ref --format='%(refname) %(objectname)'; }
# refs_snap_nort — refs_snap 에서 원격 추적 ref(진단·check 의 fetch 가 의도적으로 갱신)를 뺀 것.
refs_snap_nort() { refs_snap | grep -v '^refs/remotes/'; }
# idx_snap — 색인 pr-head·pr-sent·pr-verified.
idx_snap() { local k; for k in pr-head pr-sent pr-verified; do printf '%s=%s\n' "$k" "$(in_repo dpr_index_get "$SLUG" "$k")"; done; }
# origin_push_fr_child <파일> <제목> — 원격 fr 끝의 자식 커밋을 다른 clone 에서 만들어 원격 fr 에 fast-forward push 합니다(로컬 추적 ref 는 그대로).
origin_push_fr_child() {
  local c="$TMP/frchild"
  rm -rf "$c"; git clone -q "$ORIGIN" "$c" 2>/dev/null || return 1
  git -C "$c" checkout -q -B x "origin/$FRB" || return 1
  printf '외부\n' >"$c/$1"; git -C "$c" add -A && git -C "$c" commit -q -m "$2" || return 1
  git -C "$c" push -q origin "HEAD:refs/heads/$FRB"
}
# origin_only_tag — 기본 쪽 커밋 OMAIN 에 주석 태그 v-sync 를 달아 원격에만 둡니다(로컬 태그는 지움).
origin_only_tag() { git -C "$R" tag -a v-sync -m v-sync "$OMAIN" && git -C "$R" push -q origin refs/tags/v-sync && git -C "$R" tag -d v-sync >/dev/null; }
# dp_call <함수> [인자...] — direct_pr.sh 를 싣고 대상(_dp_target)·sync 문맥을 정한 하위 셸에서 내부 함수를 부릅니다.
#   direct_pr.sh 는 싣는 순간 전역 SLUG 를 비우므로 작업 이름을 먼저 받아 둡니다.
#   DPC_WT 가 있으면 작업 worktree 를 그 경로로 둡니다(sync 1단계가 정한 worktree — 그 뒤 브랜치를 바꾼 상태용).
dp_call() {
  local task="$SLUG"
  ( cd "$R" && project_root="$R" && export project_root && source "$R/rd-workflow/scripts/lifecycle/direct_pr.sh" \
      && _DP_TASK="$task" && _dp_target && WT="${DPC_WT:-$WT}" && { _dp_sync_ctx || { echo "dp_call: 기본 브랜치를 정하지 못했습니다" >&2; exit 2; }; } && "$@" )
}
# fake_merge_tree <head> — 그 head 와 origin main 을 dpr_sync_tree 로 합친 merge 커밋을 원격 main 에 fast-forward push 하고,
#   가짜 gh 의 PR 을 그 head 로 MERGED 로 씁니다. 기록 파일이 충돌해 fake_merge(실제 git merge)가 멈추는 상태용입니다.
fake_merge_tree() {
  local head="$1" om t mo
  om="$(og main)" || return 1
  t="$(in_repo dpr_sync_tree "$R" "$head" "$om")" || return 1
  mo="$(commit_on "$om" "$head" -- "$t" "Merge $FRB")" || return 1
  git -C "$R" push -q origin "$mo:refs/heads/main" || return 1
  set_pr_col 2 MERGED; set_pr_col 4 "$head"; set_pr_col 5 "$mo"
}
# tree_gitlink <tree-ish> <oid> — 그 트리에 gitlink vendor/x=<oid> 를 더한 트리(임시 index).
tree_gitlink() {
  local idx="$TMP/glidx.$$" t
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$R" read-tree "$1" && GIT_INDEX_FILE="$idx" git -C "$R" update-index --add --cacheinfo "160000,$2,vendor/x" \
    && t="$(GIT_INDEX_FILE="$idx" git -C "$R" write-tree)" || { rm -f "$idx"; return 1; }
  rm -f "$idx"; printf '%s\n' "$t"
}
# sync_ok — 정상 sync 를 한 번 실행합니다. 실패하면 rc 1 과 출력.
sync_ok() { run_pr sync --task "$SLUG"; [[ "$DPR_RC" == 0 ]] || { echo "sync 실패: $(pr_out)" >&2; return 1; }; }
short() { git -C "$R" rev-parse --short "$1"; }
# out_step <번호> — 출력의 「    N) 명령」 줄에서 명령을 꺼냅니다.
out_step() { sed -n "s/^    $1) //p" "$DPR_OUT" | head -1; }

t_sync_records_only() {
  local fp0 fp1 old new so se
  sync_fixture || { fail "t_sync_records_only: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  origin_only_tag || { fail "t_sync_records_only: 준비 실패(태그)"; return; }
  old="$(fr_tip)"
  # 사용자 설정이 있어도 바뀌는 ref 는 fr 브랜치뿐이어야 합니다 — fetch 추가 매핑(지문의 refs/heads 로 확인)과 push.followTags(로컬 주석 태그)
  git -C "$R" config --add remote.origin.fetch "+refs/heads/main:refs/heads/rd-alt-main" \
    && git -C "$R" config push.followTags true \
    && git -C "$R" tag -a -m local-only local-only "$old" || { fail "t_sync_records_only: 준비 실패(설정)"; return; }
  fp() {
    git -C "$R" for-each-ref --format='%(refname) %(objectname)' refs/tags refs/heads | awk '$1 != "refs/heads/fr/demo"'
    git -C "$R" rev-parse HEAD main; og main
    git -C "$R" ls-files -s | shasum; git -C "$R" diff HEAD | shasum
    git -C "$R" ls-files -z | (cd "$R" && xargs -0 shasum) | shasum
  }
  fp0="$(fp)"
  run_pr sync --task "$SLUG"
  eq "t_sync_records_only: rc 0" "$DPR_RC" "0"
  fp1="$(fp)"
  eq "t_sync_records_only: 기본 체크아웃·태그·기본 브랜치 지문 불변" "$fp1" "$fp0"
  new="$(fr_tip)"
  eq "t_sync_records_only: 원격 fr == 로컬 fr" "$(og "$FRB")" "$new"
  eq "t_sync_records_only: 로컬 주석 태그를 원격에 보내지 않음" "$(git --git-dir="$ORIGIN" rev-parse -q --verify refs/tags/local-only)" ""
  eq "t_sync_records_only: 색인 pr-head == fr 끝" "$(in_repo dpr_index_get "$SLUG" pr-head)" "$new"
  eq "t_sync_records_only: 색인 pr-sent == fr 끝" "$(in_repo dpr_index_get "$SLUG" pr-sent)" "$new"
  eq "t_sync_records_only: 부모 둘" "$(git -C "$R" rev-list --parents -n 1 "$new" | wc -w | tr -d ' ')" "3"
  eq "t_sync_records_only: 제목" "$(git -C "$R" log -1 --format=%s "$new")" "$SYNC_SUBJ"
  ok "t_sync_records_only: PR URL" "https://github.com/acme/demo/pull/1" "$(pr_out)"
  ok "t_sync_records_only: 새 짧은 OID" "$(short "$new")" "$(pr_out)"
  ok "t_sync_records_only: 다음 행동" "rd pr check --task demo" "$(pr_out)"
  ok "t_sync_records_only: pr-verified 에 옛 head" "$old" "$(in_repo dpr_index_get "$SLUG" pr-verified)"
  ok "t_sync_records_only: pr-verified 에 새 head" "$new" "$(in_repo dpr_index_get "$SLUG" pr-verified)"
  in_repo dpr_pr_waiting "$SLUG" "$FRB" && pass "t_sync_records_only: 큐 판정 PR 대기" || fail "t_sync_records_only: dpr_pr_waiting 이 PR 대기가 아님"
  run_list
  ok "t_sync_records_only: list PR 검토 중" "PR 검토 중" "$(demo_row)"
  ( cd "$WT" && bash rd-workflow/scripts/rd task status ) >"$TMP/st.out" 2>"$TMP/st.err"
  so="$(cat "$TMP/st.out")"; se="$(cat "$TMP/st.err")"
  eq "t_sync_records_only: status stdout" "$so" "대기 중"
  ok "t_sync_records_only: status stderr PR 검토 중" "PR 검토 중(직접 설치 PR)" "$se"
  ok "t_sync_records_only: status stderr URL" "https://github.com/acme/demo/pull/1" "$se"
}
want t_sync_records_only && t_sync_records_only

t_sync_task_state_only() {
  local old
  publish_pr; [[ "$AR_RC" == 0 ]] || { fail "t_sync_task_state_only: 준비 실패"; return; }
  old="$(fr_tip)"
  awk '/^base-commit=/{print "base-commit=main-side"; next} {print}' "$R/rd-workflow-workspace/.lifecycle/task-state" >"$TMP/ts.t" \
    && cat "$TMP/ts.t" >"$R/rd-workflow-workspace/.lifecycle/task-state"
  git -C "$R" commit -q -am "기본 쪽 task-state" && git -C "$R" push -q origin main || { fail "t_sync_task_state_only: 준비 실패(push)"; return; }
  run_pr sync --task "$SLUG"
  eq "t_sync_task_state_only: rc 0" "$DPR_RC" "0"
  [[ "$(fr_tip)" != "$old" ]] && pass "t_sync_task_state_only: fr 전진" || fail "t_sync_task_state_only: fr 그대로 — $(pr_out)"
  eq "t_sync_task_state_only: fr 끝 == pr-head" "$(fr_tip)" "$(in_repo dpr_index_get "$SLUG" pr-head)"
}
want t_sync_task_state_only && t_sync_task_state_only

t_sync_no_worktree() {
  sync_fixture || { fail "t_sync_no_worktree: 준비 실패"; return; }
  git -C "$R" worktree remove "$WT" && git -C "$R" switch -q "$FRB" || { fail "t_sync_no_worktree: 준비 실패(worktree)"; return; }
  eq "t_sync_no_worktree: 준비 — 기본 체크아웃 깨끗함" "$(git -C "$R" status --porcelain)" ""
  run_pr sync --task "$SLUG"
  eq "t_sync_no_worktree: rc 0" "$DPR_RC" "0"
  eq "t_sync_no_worktree: 기본 체크아웃 HEAD == 새 head" "$(git -C "$R" rev-parse HEAD)" "$(fr_tip)"
  eq "t_sync_no_worktree: HEAD == 색인 pr-head" "$(git -C "$R" rev-parse HEAD)" "$(in_repo dpr_index_get "$SLUG" pr-head)"
  [[ "$(fr_tip)" != "$CLEAN" ]] && pass "t_sync_no_worktree: fr 전진" || fail "t_sync_no_worktree: fr 그대로 — $(pr_out)"
  eq "t_sync_no_worktree: 깨끗함" "$(git -C "$R" status --porcelain)" ""
}
want t_sync_no_worktree && t_sync_no_worktree

t_sync_other_conflict() {
  local s0 i0
  sync_fixture && code_conflict || { fail "t_sync_other_conflict: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  s0="$(refs_snap)"; i0="$(idx_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_other_conflict: rc 1" "$DPR_RC" "1"
  ok "t_sync_other_conflict: 충돌 경로" "app.txt" "$(pr_out)"
  ok "t_sync_other_conflict: 종전 순서" "rd pr reopen" "$(pr_out)"
  eq "t_sync_other_conflict: ref 불변" "$(refs_snap)" "$s0"
  eq "t_sync_other_conflict: 색인 불변" "$(idx_snap)" "$i0"
}
want t_sync_other_conflict && t_sync_other_conflict

# 리뷰 파이프라인은 내용 없는 gitlink 를 펼치지 못하므로, 발행 상태를 commit-tree 로 만듭니다: 되돌리기 커밋의 부모 P(seal 커밋 + gitlink)와
# 그 위의 되돌리기 모양 커밋 C(되돌리기 커밋의 트리 + gitlink)를 로컬 fr·원격 fr·색인 pr-head·pr-sent·PR head 에 둡니다.
t_sync_gitlink_conflict() {
  local s0 clean p c g1 g2
  publish_pr; [[ "$AR_RC" == 0 ]] || { fail "t_sync_gitlink_conflict: 준비 실패(발행)"; return; }
  clean="$(fr_tip)"; g1="$(git -C "$R" rev-parse "$clean^")"; g2="$(git -C "$R" rev-parse main)"
  p="$(commit_on "$clean^" -- "$(tree_gitlink "$clean^" "$g1")" "gitlink 작업 쪽")" \
    && c="$(commit_on "$p" -- "$(tree_gitlink "$clean" "$g1")" "chore(lifecycle): archive demo metadata 정리")" \
    || { fail "t_sync_gitlink_conflict: 준비 실패(커밋)"; return; }
  # 원격 fr 은 fast-forward 가 아니므로 객체를 임시 ref 로 올린 뒤 bare 에서 ref 만 옮깁니다(강제 push 없이).
  git -C "$WT" reset -q --keep "$c" && git -C "$R" push -q origin "$c:refs/heads/tmp-gl" \
    && git --git-dir="$ORIGIN" update-ref "refs/heads/$FRB" "$c" && git --git-dir="$ORIGIN" update-ref -d refs/heads/tmp-gl \
    && in_repo dpr_index_set "$SLUG" "pr-head=$c" "pr-sent=$c" && set_pr_col 4 "$c" || { fail "t_sync_gitlink_conflict: 준비 실패(발행 상태)"; return; }
  git -C "$R" update-index --add --cacheinfo "160000,$g2,vendor/x" && git -C "$R" commit -q -m "gitlink 기본 쪽" \
    && git -C "$R" push -q origin main || { fail "t_sync_gitlink_conflict: 준비 실패(기본 gitlink)"; return; }
  set_pr_col 6 CONFLICTING
  s0="$(refs_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_gitlink_conflict: rc 1" "$DPR_RC" "1"
  ok "t_sync_gitlink_conflict: 경로" "vendor/x" "$(pr_out)"
  eq "t_sync_gitlink_conflict: ref 불변" "$(refs_snap)" "$s0"
}
want t_sync_gitlink_conflict && t_sync_gitlink_conflict

t_sync_unsupported_config() {
  local s0 i0
  sync_fixture && code_conflict || { fail "t_sync_unsupported_config: 준비 실패"; return; }
  git -C "$R" config merge.default union
  s0="$(refs_snap)"; i0="$(idx_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_unsupported_config: rc 1" "$DPR_RC" "1"
  ok "t_sync_unsupported_config: 사유" "merge.default" "$(pr_out)"
  ok "t_sync_unsupported_config: 종전 순서" "rd pr reopen" "$(pr_out)"
  eq "t_sync_unsupported_config: ref 불변" "$(refs_snap)" "$s0"
  eq "t_sync_unsupported_config: 색인 불변" "$(idx_snap)" "$i0"
}
want t_sync_unsupported_config && t_sync_unsupported_config

t_sync_dirty() {
  local s0
  sync_fixture || { fail "t_sync_dirty: 준비 실패"; return; }
  echo x >"$WT/untracked.txt"
  s0="$(refs_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_dirty: rc 1" "$DPR_RC" "1"
  eq "t_sync_dirty: ref 불변" "$(refs_snap)" "$s0"
}
want t_sync_dirty && t_sync_dirty

t_sync_not_waiting() {
  local s0
  sync_fixture || { fail "t_sync_not_waiting: 준비 실패"; return; }
  in_repo dpr_index_set "$SLUG" "state=cleanup-pending"
  s0="$(refs_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_not_waiting: rc 2" "$DPR_RC" "2"
  ok "t_sync_not_waiting: 안내" "PR 을 기다리는 작업에서만 sync 합니다" "$(pr_out)"
  eq "t_sync_not_waiting: ref 불변" "$(refs_snap)" "$s0"
}
want t_sync_not_waiting && t_sync_not_waiting

t_sync_remote_ahead() {
  local s0 i0 cmd log
  sync_fixture || { fail "t_sync_remote_ahead: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  origin_push_fr_child ext.txt "외부 커밋 제목" || { fail "t_sync_remote_ahead: 준비 실패(외부 push)"; return; }
  s0="$(refs_snap_nort)"; i0="$(idx_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_remote_ahead: rc 1" "$DPR_RC" "1"
  ok "t_sync_remote_ahead: 안내" "rd 가 발행하지 않은 커밋으로 앞서 있습니다" "$(pr_out)"
  eq "t_sync_remote_ahead: ref 불변(원격 추적 ref 제외)" "$(refs_snap_nort)" "$s0"
  eq "t_sync_remote_ahead: 색인 불변" "$(idx_snap)" "$i0"
  cmd="$(sed -n 's/^ *확인: //p' "$DPR_OUT" | tail -1)"
  log="$( cd "$R" && eval "$cmd" 2>&1 )"
  ok "t_sync_remote_ahead: 확인 명령이 외부 커밋을 보임" "외부 커밋 제목" "$log"
}
want t_sync_remote_ahead && t_sync_remote_ahead

t_sync_record_fail() {
  local sd spid tip0 o0 i0
  sync_fixture || { fail "t_sync_record_fail: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  tip0="$(fr_tip)"; o0="$(og "$FRB")"; i0="$(idx_snap)"
  sd="$( cd "$R" && project_root="$R" && _tasks_shared_dir_fill && printf '%s' "$_TASKS_SD_VAL" )"
  sleep 60 & spid=$!
  mkdir "$sd/tasks.lock" && printf 'pid=%s\ncmd=tasks-list-rebuild\nslug=-\nstarted-at=x\n' "$spid" >"$sd/tasks.lock/owner"
  export RD_DPR_LOCK_WAIT=1
  run_pr sync --task "$SLUG"
  unset RD_DPR_LOCK_WAIT
  kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
  rm -rf "${sd:?}/tasks.lock"
  eq "t_sync_record_fail: rc 1" "$DPR_RC" "1"
  ok "t_sync_record_fail: 안내" "검증된 head 목록에 기록하지 못해 push 하지 않았습니다" "$(pr_out)"
  ok "t_sync_record_fail: 재시도" "rd pr sync --task demo" "$(pr_out)"
  eq "t_sync_record_fail: 원격 fr 불변" "$(og "$FRB")" "$o0"
  eq "t_sync_record_fail: 로컬 fr 불변" "$(fr_tip)" "$tip0"
  eq "t_sync_record_fail: 색인 불변" "$(idx_snap)" "$i0"
}
want t_sync_record_fail && t_sync_record_fail

t_sync_push_rejected() {
  local tip0 o0 h0 v
  sync_fixture || { fail "t_sync_push_rejected: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  printf '#!/bin/sh\nwhile read old new ref; do case "$ref" in refs/heads/fr/*) echo "fr 거부" >&2; exit 1;; esac; done\nexit 0\n' >"$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  tip0="$(fr_tip)"; o0="$(og "$FRB")"; h0="$(in_repo dpr_index_get "$SLUG" pr-head)"
  run_pr sync --task "$SLUG"
  eq "t_sync_push_rejected: rc 1" "$DPR_RC" "1"
  ok "t_sync_push_rejected: 안내" "push 하지 못했습니다" "$(pr_out)"
  ok "t_sync_push_rejected: 재시도" "rd pr sync --task demo" "$(pr_out)"
  eq "t_sync_push_rejected: 원격 fr 불변" "$(og "$FRB")" "$o0"
  eq "t_sync_push_rejected: 로컬 fr 불변" "$(fr_tip)" "$tip0"
  eq "t_sync_push_rejected: pr-head 불변" "$(in_repo dpr_index_get "$SLUG" pr-head)" "$h0"
  v="$(in_repo dpr_index_get "$SLUG" pr-verified)"
  eq "t_sync_push_rejected: 후보가 pr-verified 에 있음(옛 head 밖 하나)" "$(printf '%s\n' $v | grep -vx "$h0" | wc -l | tr -d ' ')" "1"
  rm -f "$ORIGIN/hooks/pre-receive"
  run_pr sync --task "$SLUG"
  eq "t_sync_push_rejected: 훅 제거 뒤 rc 0" "$DPR_RC" "0"
  eq "t_sync_push_rejected: fr 끝 == pr-head" "$(fr_tip)" "$(in_repo dpr_index_get "$SLUG" pr-head)"
  eq "t_sync_push_rejected: fr 끝 == 원격" "$(fr_tip)" "$(og "$FRB")"
}
want t_sync_push_rejected && t_sync_push_rejected

t_sync_resume_after_push() {
  local old new n0
  sync_fixture || { fail "t_sync_resume_after_push: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  old="$(fr_tip)"; sync_ok || { fail "t_sync_resume_after_push: 준비 실패(sync)"; return; }
  new="$(fr_tip)"
  git -C "$WT" reset -q --keep "$old" && in_repo dpr_index_set "$SLUG" "pr-head=$old" "pr-sent=$old" || { fail "t_sync_resume_after_push: 준비 실패(되돌림)"; return; }
  n0="$(git --git-dir="$ORIGIN" rev-list --all --count)"
  run_pr sync --task "$SLUG"
  eq "t_sync_resume_after_push: rc 0" "$DPR_RC" "0"
  ok "t_sync_resume_after_push: 이어 가기" "이어 갑니다" "$(pr_out)"
  eq "t_sync_resume_after_push: 로컬 == 원격" "$(fr_tip)" "$new"
  eq "t_sync_resume_after_push: pr-head == 원격" "$(in_repo dpr_index_get "$SLUG" pr-head)" "$new"
  eq "t_sync_resume_after_push: pr-sent == 원격" "$(in_repo dpr_index_get "$SLUG" pr-sent)" "$new"
  eq "t_sync_resume_after_push: 원격 그대로" "$(og "$FRB")" "$new"
  eq "t_sync_resume_after_push: 원격에 새 커밋 없음" "$(git --git-dir="$ORIGIN" rev-list --all --count)" "$n0"
}
want t_sync_resume_after_push && t_sync_resume_after_push

t_sync_resume_index() {
  local old new
  sync_fixture || { fail "t_sync_resume_index: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  old="$(fr_tip)"; sync_ok || { fail "t_sync_resume_index: 준비 실패(sync)"; return; }
  new="$(fr_tip)"
  in_repo dpr_index_set "$SLUG" "pr-head=$old" "pr-sent=$old" || { fail "t_sync_resume_index: 준비 실패(색인)"; return; }
  run_pr sync --task "$SLUG"
  eq "t_sync_resume_index: rc 0" "$DPR_RC" "0"
  ok "t_sync_resume_index: 이어 가기" "이어 갑니다" "$(pr_out)"
  eq "t_sync_resume_index: pr-head == 새 head" "$(in_repo dpr_index_get "$SLUG" pr-head)" "$new"
  eq "t_sync_resume_index: pr-sent == 새 head" "$(in_repo dpr_index_get "$SLUG" pr-sent)" "$new"
  eq "t_sync_resume_index: 원격 그대로" "$(og "$FRB")" "$new"
  in_repo dpr_pr_waiting "$SLUG" "$FRB" && pass "t_sync_resume_index: 큐 판정 PR 대기" || fail "t_sync_resume_index: dpr_pr_waiting 이 PR 대기가 아님"
}
want t_sync_resume_index && t_sync_resume_index

t_sync_resume_local() {
  local old new
  sync_fixture || { fail "t_sync_resume_local: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  old="$(fr_tip)"; sync_ok || { fail "t_sync_resume_local: 준비 실패(sync)"; return; }
  new="$(fr_tip)"
  git -C "$WT" reset -q --keep "$old" || { fail "t_sync_resume_local: 준비 실패(되돌림)"; return; }
  run_pr sync --task "$SLUG"
  eq "t_sync_resume_local: rc 0" "$DPR_RC" "0"
  ok "t_sync_resume_local: 이어 가기" "이어 갑니다" "$(pr_out)"
  eq "t_sync_resume_local: 로컬 == 새 head" "$(fr_tip)" "$new"
  eq "t_sync_resume_local: 원격 그대로" "$(og "$FRB")" "$new"
  in_repo dpr_pr_waiting "$SLUG" "$FRB" && pass "t_sync_resume_local: 큐 판정 PR 대기" || fail "t_sync_resume_local: dpr_pr_waiting 이 PR 대기가 아님"
  run_list
  ok "t_sync_resume_local: list PR 검토 중" "PR 검토 중" "$(demo_row)"
}
want t_sync_resume_local && t_sync_resume_local

t_sync_merged_midway() {
  local old new cand s0
  # (가) push 는 원격에 반영됐지만 색인은 옛 값, 그 사이 새 head 로 merge 되고 원격 fr 이 지워짐
  sync_fixture || { fail "t_sync_merged_midway (가): 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  old="$(fr_tip)"; sync_ok || { fail "t_sync_merged_midway (가): 준비 실패(sync)"; return; }
  new="$(fr_tip)"
  fake_merge merge || { fail "t_sync_merged_midway (가): 준비 실패(merge)"; return; }
  in_repo dpr_index_set "$SLUG" "pr-head=$old" "pr-sent=$old" && git --git-dir="$ORIGIN" update-ref -d "refs/heads/$FRB" \
    || { fail "t_sync_merged_midway (가): 준비 실패(되돌림)"; return; }
  s0="$(refs_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_merged_midway (가): rc 1" "$DPR_RC" "1"
  ok "t_sync_merged_midway (가): --apply 안내" "rd pr check --task demo --apply" "$(pr_out)"
  eq "t_sync_merged_midway (가): ref 불변" "$(refs_snap)" "$s0"
  run_pr check --task "$SLUG" --apply
  eq "t_sync_merged_midway (가): --apply rc 0" "$DPR_RC" "0"
  ok "t_sync_merged_midway (가): 같은 head 면 rd task list 가 정리" "rd task list 가 정리합니다" "$(pr_out)"
  # (나) 후보를 목록에 기록한 직후 push 전에 중단, PR 은 옛 head 로 merge
  sync_fixture || { fail "t_sync_merged_midway (나): 준비 실패"; return; }
  cand="$(mk_sync "$CLEAN" "$OMAIN")" && in_repo dpr_verified_add "$SLUG" "$CLEAN" "$cand" || { fail "t_sync_merged_midway (나): 준비 실패(후보)"; return; }
  fake_merge_tree "$CLEAN" || { fail "t_sync_merged_midway (나): 준비 실패(merge)"; return; }
  run_pr sync --task "$SLUG"
  eq "t_sync_merged_midway (나): rc 1" "$DPR_RC" "1"
  ok "t_sync_merged_midway (나): --apply 안내" "rd pr check --task demo --apply" "$(pr_out)"
  run_pr check --task "$SLUG" --apply
  eq "t_sync_merged_midway (나): --apply rc 0" "$DPR_RC" "0"
  # (라) 정상 sync 뒤 목록·pr-head 어디에도 없는 head 로 merge → 마감하지 않음
  sync_fixture || { fail "t_sync_merged_midway (라): 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  old="$(fr_tip)"; sync_ok || { fail "t_sync_merged_midway (라): 준비 실패(sync)"; return; }
  fake_merge merge || { fail "t_sync_merged_midway (라): 준비 실패(merge)"; return; }
  set_pr_col 4 "$OMAIN"
  run_pr check --task "$SLUG" --apply
  eq "t_sync_merged_midway (라): --apply rc 1" "$DPR_RC" "1"
  eq "t_sync_merged_midway (라): 태그 0" "$(tag_count)" "0"
  # (다) 같은 상태(pr-head=새 head)에서 PR 이 옛 head 로 merge 됐다고 보고 → 옛 head 는 목록에 있어 마감
  set_pr_col 4 "$old"
  run_pr check --task "$SLUG" --apply
  eq "t_sync_merged_midway (다): --apply rc 0" "$DPR_RC" "0"
  # 로컬 fr 은 sync head 에 남아 rd task list 가 정리하지 않습니다 — 그렇다고 말하고 확인·정리 명령을 보여야 합니다.
  ok "t_sync_merged_midway (다): 자동 정리 안 됨 안내" "rd task list 는 작업 worktree·로컬 브랜치를 정리하지 않습니다" "$(pr_out)"
  ok "t_sync_merged_midway (다): 확인 명령" "log --oneline $old..$FRB" "$(pr_out)"
  ok "t_sync_merged_midway (다): 무시 파일 확인 명령" "git -C $WT status --short --ignored --untracked-files=all" "$(pr_out)"
  # 확인 줄이 정리(삭제) 줄보다 먼저 나와야 합니다.
  eq "t_sync_merged_midway (다): 확인이 정리보다 먼저" \
    "$(pr_out | awk 'index($0, "status --short --ignored") && !s { s = NR } index($0, "worktree remove") && !r { r = NR } END { print (s && r && s < r) ? "먼저" : "아님 s=" s " r=" r }')" "먼저"
  ok "t_sync_merged_midway (다): linked worktree 정리 명령" "worktree remove $WT && git -C $R branch -D $FRB" "$(pr_out)"
  no "t_sync_merged_midway (다): 자동 정리 문구 없음" "rd task list 가 정리합니다" "$(pr_out)"
  # 마감 뒤 archive 를 다시 실행해도 같은 안내를 냅니다.
  run_ar --task "$SLUG"
  ok "t_sync_merged_midway (다): archive 재실행도 같은 안내" "rd task list 는 작업 worktree·로컬 브랜치를 정리하지 않습니다" "$(ar_out)"
}
want t_sync_merged_midway && t_sync_merged_midway

# 기본 브랜치가 추적하기 시작한 경로에 작업 worktree 의 무시 파일이 있으면 push 전에 멈추고 파일을 덮지 않습니다.
# 없으면 새는 실수: 상태 검사는 무시 파일을 보지 않아 깨끗하다고 보고, 마무리의 fast-forward 가 로컬에만 있던 파일을 덮습니다.
t_sync_ignored_file() {
  local s0 ex
  sync_fixture || { fail "t_sync_ignored_file: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  # 같은 경로(rd-local.env), 접두 경로(기본 쪽 파일 slot ↔ 무시 디렉터리 안의 slot/한글), 상위 경로(기본 쪽 deep/x ↔ 무시 파일 deep) 세 가지를 함께 둡니다.
  # 한글 이름은 git 의 기본 경로 인용(core.quotePath)이 비교를 어긋나게 하지 않는지 봅니다.
  ex="$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)" && mkdir -p "$(dirname "$ex")" "$WT/slot" \
    && printf 'rd-local.env\nslot\ndeep\n' >>"$ex" && echo "kept only locally" >"$WT/rd-local.env" && echo "secret" >"$WT/slot/한글" && echo "deep keep" >"$WT/deep" \
    && echo incoming >"$R/rd-local.env" && echo slot-file >"$R/slot" && mkdir -p "$R/deep" && echo x >"$R/deep/x" \
    && git -C "$R" add -f rd-local.env slot deep/x && git -C "$R" commit -q -m "기본 쪽이 rd-local.env·slot·deep/x 추적" \
    && git -C "$R" push -q origin main || { fail "t_sync_ignored_file: 준비 실패(무시 파일)"; return; }
  s0="$(refs_snap_nort)"
  run_pr sync --task "$SLUG"
  eq "t_sync_ignored_file: rc 1" "$DPR_RC" "1"
  ok "t_sync_ignored_file: 경로 안내" "    rd-local.env" "$(pr_out)"
  ok "t_sync_ignored_file: 접두 경로 안내" "    slot/한글" "$(pr_out)"
  ok "t_sync_ignored_file: 상위 경로 안내" "    deep" "$(pr_out)"
  ok "t_sync_ignored_file: 옮긴 뒤 재실행 안내" "작업 worktree 밖으로 옮긴 뒤 다시 실행하십시오" "$(pr_out)"
  eq "t_sync_ignored_file: ref 불변(원격 추적 ref 제외)" "$(refs_snap_nort)" "$s0"
  eq "t_sync_ignored_file: 파일 내용 보존" "$(cat "$WT/rd-local.env")|$(cat "$WT/slot/한글")|$(cat "$WT/deep")" "kept only locally|secret|deep keep"
}
want t_sync_ignored_file && t_sync_ignored_file

t_sync_p9_pending() {
  local s0 sent0
  publish_pr
  run_pr reopen --task "$SLUG"; [[ "$DPR_RC" == 0 ]] || { fail "t_sync_p9_pending: 준비 실패(reopen)"; return; }
  review_and_hold || { fail "t_sync_p9_pending: 준비 실패(재리뷰)"; return; }
  export FAKE_GH_FAIL=edit; run_ar; unset FAKE_GH_FAIL
  eq "t_sync_p9_pending: 준비 — 재발행 P9 실패 rc 1" "$AR_RC" "1"
  sent0="$(in_repo dpr_index_get "$SLUG" pr-sent)"
  [[ "$sent0" != "$(fr_tip)" && "$(og "$FRB")" == "$(fr_tip)" ]] || { fail "t_sync_p9_pending: 준비 — L=O=H, S≠H 가 아님"; return; }
  s0="$(refs_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_p9_pending: rc 1" "$DPR_RC" "1"
  ok "t_sync_p9_pending: 안내" "PR 갱신이 끝나지 않았습니다" "$(pr_out)"
  ok "t_sync_p9_pending: rd pr open" "rd pr open --task demo" "$(pr_out)"
  eq "t_sync_p9_pending: pr-sent 불변" "$(in_repo dpr_index_get "$SLUG" pr-sent)" "$sent0"
  eq "t_sync_p9_pending: ref 불변" "$(refs_snap)" "$s0"
}
want t_sync_p9_pending && t_sync_p9_pending

t_head_lag() {
  local s0 i0
  sync_fixture || { fail "t_head_lag: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  sync_ok || { fail "t_head_lag: 준비 실패(sync)"; return; }
  set_pr_col 4 "$CLEAN"
  s0="$(refs_snap)"; i0="$(idx_snap)"
  run_pr sync --task "$SLUG"
  eq "t_head_lag: rc 1" "$DPR_RC" "1"
  ok "t_head_lag: PR head 안내" "PR head(" "$(pr_out)"
  ok "t_head_lag: 잠시 뒤" "잠시 뒤" "$(pr_out)"
  eq "t_head_lag: ref 불변" "$(refs_snap)" "$s0"
  eq "t_head_lag: 색인 불변" "$(idx_snap)" "$i0"
  run_pr check --task "$SLUG"
  ok "t_head_lag: check 지연 안내" "원격 fr 브랜치와 다릅니다" "$(pr_out)"
  no "t_head_lag: check 에 sync 안내 없음" "rd pr sync" "$(pr_out)"
}
want t_head_lag && t_head_lag

# finish_diverged — 정상 sync 의 후보 M 을 원격·색인에 둔 채, 작업 worktree 를 옛 head L 로 돌리고 그 위에 코드 커밋 U 를 만듭니다.
#   전역: SM(후보) SL(옛 head) SU(U)
finish_diverged() {
  sync_fixture || return 1
  set_pr_col 6 CONFLICTING
  # 기본 쪽이 local.env 를 추적하기 시작합니다 — t_sync_finish_preserve 가 이 경로의 무시 파일을 둡니다.
  echo incoming >"$R/local.env" && git -C "$R" add -f local.env && git -C "$R" commit -q -m "기본 쪽이 local.env 추적" && git -C "$R" push -q origin main || return 1
  SL="$(fr_tip)"; sync_ok || return 1
  SM="$(fr_tip)"
  git -C "$WT" reset -q --keep "$SL" || return 1
  # sync 도중 로컬 이력은 병합 커밋입니다 — 곁가지(app.txt)와 fr 쪽 직선 커밋(local2.txt)을 --no-ff 로 합칩니다.
  git -C "$WT" switch -q -c local-side && echo "local more" >>"$WT/app.txt" && git -C "$WT" commit -q -am "로컬 곁가지" \
    && git -C "$WT" switch -q "$FRB" && echo two >"$WT/local2.txt" && git -C "$WT" add local2.txt && git -C "$WT" commit -q -m "로컬 직선" \
    && git -C "$WT" merge -q --no-ff -m "sync 도중 로컬 커밋" local-side && git -C "$WT" branch -q -D local-side || return 1
  SU="$(git -C "$WT" rev-parse HEAD)"
}

t_sync_finish_ff_only() {
  local out rc
  finish_diverged || { fail "t_sync_finish_ff_only: 준비 실패"; return; }
  rc=0; out="$(dp_call _dp_sync_finish "$SM" 2>&1)" || rc=$?
  eq "t_sync_finish_ff_only: rc 1" "$rc" "1"
  eq "t_sync_finish_ff_only: HEAD == U" "$(git -C "$WT" rev-parse HEAD)" "$SU"
  ok "t_sync_finish_ff_only: 끝난 단계" "push 와 색인 기록은 끝났습니다" "$out"
  ok "t_sync_finish_ff_only: git 오류 줄" "git: " "$out"
  ok "t_sync_finish_ff_only: 보존 브랜치" "rd-sync-keep/demo" "$out"
}
want t_sync_finish_ff_only && t_sync_finish_ff_only

t_sync_finish_preserve() {
  local rc keep prev c se ex
  finish_diverged || { fail "t_sync_finish_preserve: 준비 실패"; return; }
  prev="rd-sync-keep/demo-$(short "$SM")"
  git -C "$R" branch "$prev" "$SL" || { fail "t_sync_finish_preserve: 준비 실패(이전 보존)"; return; }
  printf 'staged\n' >"$WT/$FRQ" && git -C "$WT" add "$FRQ" && printf 'unstaged\n' >"$WT/$FRQ" && echo n >"$WT/note.txt"
  # 무시 파일 local.env — 후보(SM)가 같은 경로를 추적합니다. add -A 가 담지 않으므로 4) 가 덮지 않아야 합니다.
  ex="$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)" && mkdir -p "$(dirname "$ex")" \
    && printf 'local.env\n' >>"$ex" && echo "local secret" >"$WT/local.env" || { fail "t_sync_finish_preserve: 준비 실패(무시 파일)"; return; }
  rc=0; dp_call _dp_sync_finish "$SM" >"$DPR_OUT" 2>&1 || rc=$?
  eq "t_sync_finish_preserve: rc 1" "$rc" "1"
  keep="$prev-2"
  ok "t_sync_finish_preserve: 보존 이름 -2" "switch -c $keep" "$(pr_out)"
  for c in 1 2 3; do
    ( cd "$R" && eval "$(out_step "$c")" ) >/dev/null 2>&1 || fail "t_sync_finish_preserve: $c 번 실패: $(out_step "$c")"
  done
  eq "t_sync_finish_preserve: <보존>^ 은 스테이징 내용" "$(git -C "$R" show "$keep^:$FRQ" 2>/dev/null)" "staged"
  eq "t_sync_finish_preserve: <보존> 은 작업 트리 내용" "$(git -C "$R" show "$keep:$FRQ" 2>/dev/null)" "unstaged"
  git -C "$R" cat-file -e "$keep:note.txt" 2>/dev/null && pass "t_sync_finish_preserve: 미추적 파일 보존" || fail "t_sync_finish_preserve: <보존>:note.txt 없음"
  git -C "$R" merge-base --is-ancestor "$SU" "$keep" 2>/dev/null && pass "t_sync_finish_preserve: U 보존" || fail "t_sync_finish_preserve: U 가 보존 브랜치의 조상이 아님"
  eq "t_sync_finish_preserve: 이전 보존 브랜치 그대로" "$(git -C "$R" rev-parse "$prev")" "$SL"
  # 6) 의 첫 diff 는 2) 가 담은 스테이징 변경만 보여야 합니다(후보와 비교하면 기본 브랜치 쪽 차이가 섞임).
  c="$(sed -n 's/^       스테이징했던 내용: //p' "$DPR_OUT")"
  eq "t_sync_finish_preserve: 6 번 스테이징 diff 는 스테이징 변경만" "$( (cd "$R" && eval "$c --name-only") 2>&1)" "$FRQ"
  c="$(sed -n 's/^       그 뒤 작업 트리 변경: //p' "$DPR_OUT")"
  eq "t_sync_finish_preserve: 6 번 작업 트리 diff" "$( (cd "$R" && eval "$c --name-only") 2>&1 | tr '\n' ' ')" "note.txt $FRQ "
  # sync 도중 만든 로컬 커밋(U)은 두 diff 에 나오지 않으므로 따로 보여야 합니다.
  c="$(sed -n 's/^       sync 도중 만든 로컬 커밋: //p' "$DPR_OUT" | sed 's/  (.*//')"
  ok "t_sync_finish_preserve: 6 번 로컬 커밋 목록에 U" "sync 도중 로컬 커밋" "$( (cd "$R" && eval "$c") 2>&1)"
  rc=0; ( cd "$R" && eval "$(out_step 4)" ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" != 0 ]] && pass "t_sync_finish_preserve: 4 번이 무시 파일 앞에서 멈춤" || fail "t_sync_finish_preserve: 4 번이 무시 파일 앞에서 멈추지 않음 (rc $rc)"
  eq "t_sync_finish_preserve: 무시 파일 내용 보존" "$(cat "$WT/local.env" 2>/dev/null)" "local secret"
  ok "t_sync_finish_preserve: 옮긴 뒤 4 번 재실행 안내" "git 이 보인 파일을 작업 worktree 밖으로 옮긴 뒤 4) 를 다시 실행합니다" "$(pr_out)"
  mv "$WT/local.env" "$TMP/local.env.kept" || { fail "t_sync_finish_preserve: 무시 파일 옮기기 실패"; return; }
  rc=0; ( cd "$R" && eval "$(out_step 4)" ) >/dev/null 2>&1 || rc=$?
  eq "t_sync_finish_preserve: 4 번 rc 0" "$rc" "0"
  eq "t_sync_finish_preserve: 5 번 HEAD == 후보" "$(git -C "$WT" rev-parse HEAD)" "$SM"
  eq "t_sync_finish_preserve: 로컬 fr == 후보" "$(fr_tip)" "$SM"
  eq "t_sync_finish_preserve: 원격 fr == 후보(새 push 없음)" "$(og "$FRB")" "$SM"
  ( cd "$WT" && bash rd-workflow/scripts/rd task status ) >/dev/null 2>"$TMP/st.err"; se="$(cat "$TMP/st.err")"
  ok "t_sync_finish_preserve: 5 번 status 안내" "PR 검토 중(직접 설치 PR)" "$se"
  # 6) 의 로컬 커밋 옮기기 명령(병합 이력 포함)을 그대로 실행하면 두 갈래의 변경이 모두 와야 합니다.
  c="$(sed -n 's/^       옮기기: \(git -C .*\)  (병합 커밋.*/\1/p' "$DPR_OUT")"
  rc=0; ( cd "$R" && eval "$c" ) >/dev/null 2>&1 || rc=$?
  eq "t_sync_finish_preserve: 6 번 옮기기 rc 와 두 갈래 변경 ($c)" "$rc|$(git -C "$WT" show HEAD:app.txt 2>/dev/null | grep -c 'local more')|$(git -C "$WT" show HEAD:local2.txt 2>/dev/null)" "0|1|two"
}
want t_sync_finish_preserve && t_sync_finish_preserve

t_sync_finish_other_branch() {
  local out rc ex c sd
  sync_fixture || { fail "t_sync_finish_other_branch: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  SL="$(fr_tip)"; sync_ok || { fail "t_sync_finish_other_branch: 준비 실패(sync)"; return; }
  SM="$(fr_tip)"
  git -C "$WT" reset -q --keep "$SL" && git -C "$WT" switch -q -c side || { fail "t_sync_finish_other_branch: 준비 실패(side)"; return; }
  # side 는 app.txt 를 추적하지 않고 무시합니다(fr 은 추적). 안내된 복귀 명령이 이 파일을 덮지 않아야 합니다.
  ex="$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)" && mkdir -p "$(dirname "$ex")" \
    && git -C "$WT" rm -q --cached app.txt && git -C "$WT" commit -q -m "side: app.txt 추적 안 함" \
    && printf 'app.txt\n' >>"$ex" && echo "side keep" >"$WT/app.txt" || { fail "t_sync_finish_other_branch: 준비 실패(무시 파일)"; return; }
  sd="$(git -C "$WT" rev-parse HEAD)"
  rc=0; out="$(DPC_WT="$WT" dp_call _dp_sync_finish "$SM" 2>&1)" || rc=$?
  eq "t_sync_finish_other_branch: rc 1" "$rc" "1"
  eq "t_sync_finish_other_branch: side 그대로" "$(git -C "$R" rev-parse side)" "$sd"
  eq "t_sync_finish_other_branch: 로컬 fr 그대로" "$(fr_tip)" "$SL"
  ok "t_sync_finish_other_branch: 안내" "작업 worktree 가 side 에 있어" "$out"
  ok "t_sync_finish_other_branch: 전환 명령" "switch --no-overwrite-ignore $FRB" "$out"
  # 안내된 전환 명령을 그대로 실행합니다 — 무시 파일 앞에서 멈추고, 옮긴 뒤 다시 실행하면 전환됩니다.
  c="$(printf '%s\n' "$out" | sed -n 's/^  \(git -C .* switch .*[^ ]\) 뒤 같은 명령.*/\1/p')"
  rc=0; ( cd "$R" && eval "$c" ) >/dev/null 2>&1 || rc=$?
  [[ "$rc" != 0 ]] && pass "t_sync_finish_other_branch: 전환이 무시 파일 앞에서 멈춤" || fail "t_sync_finish_other_branch: 전환이 멈추지 않음 ($c)"
  eq "t_sync_finish_other_branch: 무시 파일 내용 보존" "$(cat "$WT/app.txt")" "side keep"
  mv "$WT/app.txt" "$TMP/side-app.kept" || { fail "t_sync_finish_other_branch: 옮기기 실패"; return; }
  ( cd "$R" && eval "$c" ) >/dev/null 2>&1 || { fail "t_sync_finish_other_branch: 옮긴 뒤 전환 실패 ($c)"; return; }
  run_pr sync --task "$SLUG"
  eq "t_sync_finish_other_branch: 다시 실행 rc 0" "$DPR_RC" "0"
  eq "t_sync_finish_other_branch: 로컬 fr == 후보" "$(fr_tip)" "$SM"
}
want t_sync_finish_other_branch && t_sync_finish_other_branch

t_sync_push_lease() {
  local cand rc out
  sync_fixture || { fail "t_sync_push_lease: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  cand="$(mk_sync "$CLEAN" "$OMAIN")" || { fail "t_sync_push_lease: 준비 실패(후보)"; return; }
  git --git-dir="$ORIGIN" update-ref -d "refs/heads/$FRB" || { fail "t_sync_push_lease: 준비 실패(원격 삭제)"; return; }
  rc=0; dp_call _dp_sync_push "$cand" "$CLEAN" >/dev/null 2>&1 || rc=$?
  [[ "$rc" != 0 ]] && pass "t_sync_push_lease: push 거부" || fail "t_sync_push_lease: push 가 성공함"
  eq "t_sync_push_lease: 원격 fr 없음 그대로" "$(og "$FRB")" ""
  set_pr_col 2 MERGED
  rc=0; out="$(dp_call _dp_sync_after_push_fail "$cand" "$CLEAN" 2>&1)" || rc=$?
  eq "t_sync_push_lease: MERGED rc 1" "$rc" "1"
  ok "t_sync_push_lease: MERGED → --apply" "rd pr check --task demo --apply" "$out"
  set_pr_col 2 OPEN
  rc=0; out="$(dp_call _dp_sync_after_push_fail "$cand" "$CLEAN" 2>&1)" || rc=$?
  eq "t_sync_push_lease: OPEN rc 1" "$rc" "1"
  ok "t_sync_push_lease: OPEN → 원격 없음" "원격 fr 브랜치가 없습니다" "$out"
}
want t_sync_push_lease && t_sync_push_lease

t_published_head_long_chain() {
  local c i all=""
  publish_pr; CLEAN="$(fr_tip)"; OMAIN="$(og main)"
  c="$CLEAN"
  for ((i = 0; i < 21; i++)); do
    c="$(commit_on "$c" "$OMAIN" -- "$(git -C "$R" rev-parse "$c^{tree}")" "$SYNC_SUBJ")" || { fail "t_published_head_long_chain: 준비 실패"; return; }
    all="$all $c"
  done
  in_repo dpr_verified_add "$SLUG" $all || { fail "t_published_head_long_chain: 준비 실패(pr-verified)"; return; }
  ph "$c"
  eq "t_published_head_long_chain: rc 0" "$PH_RC" "0"
  eq "t_published_head_long_chain: stdout 이 되돌리기 커밋" "$PH_OUT" "$CLEAN"
}
want t_published_head_long_chain && t_published_head_long_chain

t_sync_noop() {
  local s0
  publish_pr
  s0="$(refs_snap)"
  run_pr sync --task "$SLUG"
  eq "t_sync_noop: rc 0" "$DPR_RC" "0"
  ok "t_sync_noop: 안내" "동기화할 변경 없음" "$(pr_out)"
  eq "t_sync_noop: ref 불변" "$(refs_snap)" "$s0"
}
want t_sync_noop && t_sync_noop

t_base_mismatch() {
  local s0
  sync_fixture || { fail "t_base_mismatch: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING; set_pr_col 3 release
  s0="$(refs_snap)"
  run_pr sync --task "$SLUG"
  eq "t_base_mismatch: rc 1" "$DPR_RC" "1"
  ok "t_base_mismatch: 안내" "PR 의 대상 브랜치가 release 입니다" "$(pr_out)"
  eq "t_base_mismatch: ref 불변" "$(refs_snap)" "$s0"
  run_pr check --task "$SLUG"
  ok "t_base_mismatch: check 같은 줄" "PR 의 대상 브랜치가 release 입니다" "$(pr_out)"
  no "t_base_mismatch: check 에 sync 없음" "rd pr sync" "$(pr_out)"
}
want t_base_mismatch && t_base_mismatch

t_check_suggests_sync() {
  local s0 t0 x
  sync_fixture || { fail "t_check_suggests_sync: 준비 실패"; return; }
  set_pr_col 6 CONFLICTING
  origin_only_tag || { fail "t_check_suggests_sync: 준비 실패(태그)"; return; }
  s0="$(refs_snap_nort)"; t0="$(git -C "$R" for-each-ref refs/tags)"
  run_pr check --task "$SLUG"
  ok "t_check_suggests_sync: sync 안내" "rd pr sync --task demo" "$(pr_out)"
  eq "t_check_suggests_sync: ref 불변(원격 추적 ref 제외)" "$(refs_snap_nort)" "$s0"
  eq "t_check_suggests_sync: 태그 불변" "$(git -C "$R" for-each-ref refs/tags)" "$t0"
  # 출처 확인: 되돌리기 커밋 위에 기록 파일을 더 바꾼 미검증 커밋 X(원격 fr·PR head 모두 X)
  x="$(add_file_commit "$CLEAN" "$FRQ" "$(frq_table base-row fr-row x-row)" "미검증 기록")" \
    && git -C "$R" push -q origin "$x:refs/heads/$FRB" || { fail "t_check_suggests_sync: 준비 실패(X)"; return; }
  set_pr_col 4 "$x"
  run_pr check --task "$SLUG"
  ok "t_check_suggests_sync: 미검증 head 안내" "PR head 가 rd 가 발행한 head 가 아닙니다" "$(pr_out)"
  ok "t_check_suggests_sync: 미검증 head 종전 순서" "rd pr reopen" "$(pr_out)"
  no "t_check_suggests_sync: 미검증 head 에 sync 없음" "rd pr sync" "$(pr_out)"
  # 트리 계산 인자: PR head(H=O)는 그대로, 로컬 fr 에만 기본 쪽과 겹치는 미발행 코드 커밋
  git --git-dir="$ORIGIN" update-ref "refs/heads/$FRB" "$CLEAN" && set_pr_col 4 "$CLEAN" || { fail "t_check_suggests_sync: 준비 실패(원복)"; return; }
  printf 'main side\n' >"$R/code.txt" && git -C "$R" add code.txt && git -C "$R" commit -q -m "기본 쪽 코드 파일" && git -C "$R" push -q origin main \
    || { fail "t_check_suggests_sync: 준비 실패(기본 코드)"; return; }
  printf 'local side\n' >"$WT/code.txt" && git -C "$WT" add code.txt && git -C "$WT" commit -q -m "미발행 로컬 커밋" || { fail "t_check_suggests_sync: 준비 실패(로컬)"; return; }
  run_pr check --task "$SLUG"
  ok "t_check_suggests_sync: PR head 로 계산" "rd pr sync --task demo" "$(pr_out)"
  # 코드 충돌이면 sync 없이 종전 순서
  sync_fixture && code_conflict || { fail "t_check_suggests_sync: 준비 실패(코드 충돌)"; return; }
  set_pr_col 6 CONFLICTING
  run_pr check --task "$SLUG"
  no "t_check_suggests_sync: 코드 충돌에 sync 없음" "rd pr sync" "$(pr_out)"
  ok "t_check_suggests_sync: 코드 충돌 종전 순서" "rd pr reopen" "$(pr_out)"
}
want t_check_suggests_sync && t_check_suggests_sync

t_help_sync() {
  local u
  publish_pr
  run_pr --help
  ok "t_help_sync: rd pr --help sync" "sync [--task <slug>]" "$(pr_out)"
  ok "t_help_sync: rd pr --help 전용" "archive_publish=pr" "$(pr_out)"
  u="$( cd "$R" && bash rd-workflow/scripts/rd 2>&1 )"
  ok "t_help_sync: rd 사용법 sync" "sync [--task <slug>]" "$u"
  ok "t_help_sync: rd 사용법 전용" "archive_publish=pr" "$u"
}
want t_help_sync && t_help_sync

t_sync_overlay_rc2() {
  mk_direct push; setup_fake_gh
  PR_CWD="$WT" run_pr sync --task "$SLUG"
  eq "t_sync_overlay_rc2: rc 2" "$DPR_RC" "2"
  ok "t_sync_overlay_rc2: 안내" "rd pr sync: 직접 설치 PR 방식(archive_publish=pr) 작업 전용입니다" "$(pr_out)"
}
want t_sync_overlay_rc2 && t_sync_overlay_rc2

t_p4_warning_wording() {
  local out
  mk_direct pr; setup_fake_gh
  frq_table base-row >"$R/$FRQ"; git -C "$R" add "$FRQ" && git -C "$R" commit -q -m "FR 등록" && git -C "$R" push -q origin main || { fail "t_p4_warning_wording: 준비 실패"; return; }
  git -C "$WT" fetch -q origin main && git -C "$WT" merge -q --no-edit origin/main >/dev/null || { fail "t_p4_warning_wording: 준비 실패(병합)"; return; }
  frq_table base-row fr-row >"$WT/$FRQ"; git -C "$WT" commit -q -am "기록: FR 행" || { fail "t_p4_warning_wording: 준비 실패(기록)"; return; }
  frq_table base-row main-row >"$R/$FRQ"; git -C "$R" commit -q -am "기본 쪽 기록" && git -C "$R" push -q origin main || { fail "t_p4_warning_wording: 준비 실패(기본 쪽)"; return; }
  run_ar; out="$(ar_out)"
  eq "t_p4_warning_wording: rc 0" "$AR_RC" "0"
  ok "t_p4_warning_wording: 경고" "기록 파일이 충돌합니다" "$out"
  ok "t_p4_warning_wording: sync 안내" "PR 이 올라간 뒤 bash rd-workflow/scripts/rd pr sync --task demo" "$out"
  no "t_p4_warning_wording: reopen 없음" "rd pr reopen" "$out"
}
want t_p4_warning_wording && t_p4_warning_wording

echo
echo "결과: PASS=$PASS FAIL=$FAIL (소요 $((SECONDS - T0))초)"
[[ "$FAIL" -eq 0 ]]
