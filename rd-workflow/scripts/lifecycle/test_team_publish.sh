#!/usr/bin/env bash
# test_team_publish.sh — `rd pr open`·`rd pr light-check`·`rd pr check [--apply]`(team_publish.sh) 시험 (spec D5·D6·D7·D9·D14).
# 저장소는 모두 mktemp -d 아래에 만듭니다: 팀 bare 원격 3개(team-a·b·c) + submodule libs/a·b·c 를 품은 overlay.
# 가짜 gh 를 PATH 앞에 둡니다. 실제 GitHub 에 접근하지 않습니다.
#
# 시간: seal 까지 마친 overlay 틀은 실제 promote → 리뷰 세션 → seal 경로로 한 번만 만들고(약 20초 — seal 과
# set-status 가 submodule 내용 해시를 계산), 케이스마다 같은 절대 경로에 복사해 씁니다(케이스당 1초 안팎).
# worktree·submodule 의 절대 경로가 그대로 맞으므로 복사본이 원본과 같이 동작합니다.
# 케이스를 고르지 않고 실행하면 틀 단위 묶음을 병렬로 돌립니다(아래 「병렬 실행」).
# 다른 테스트(T6 의 check)가 이 파일의 공용 함수(mk_overlay_with_team·setup_fake_gh·seal_and_hold)를 씁니다.
# bash 3.2 호환.
set -uo pipefail

export HERDR_ENV= HC_TERMINAL_ID= ORCA_AGENT_SESSION_ID= ORCA_TERMINAL_HANDLE= RD_CHILD_SESSION=1
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

W="$TMP/w"; SLUG=demo
R="$W/repo"; WT="$R/.worktrees/$SLUG"
FR_ITEM="rd-workflow-workspace/backlog/items/2026-11-16-demo.md"

# seal_and_hold <wt> <session> — 세션을 종결(리뷰어 이의 없음 턴)하고 검증 증거·seal 을 만든 뒤
# Status 를 아카이브 보류 로 옮겨 커밋합니다. 실패 rc 1.
seal_and_hold() {
  local wt="$1" ses="$2" st x
  x="$(mktemp "$TMP/x.XXXXXX")" || return 1
  awk '/^## Status$/{print; getline; print "closed"; next} {print}' "$ses/SESSION.md" >"$x" && cat "$x" >"$ses/SESSION.md"
  awk '/^## Open Issues$/{s=1; print; next} s && /^## /{s=0} s && $0=="-"{print "- 없음"; next} {print}' "$ses/CHECKPOINT.md" >"$x" && cat "$x" >"$ses/CHECKPOINT.md"
  rm -f "$x"
  fixture_reviewer_turn "$ses" "$wt/rd-workflow/scripts" || return 1
  ( cd "$wt" && bash rd-workflow/scripts/verify_record.sh -- true ) >"$TMP/vr.log" 2>&1 || { cat "$TMP/vr.log" >&2; return 1; }
  ( cd "$wt" && bash rd-workflow/scripts/rd review seal "$ses" ) >"$TMP/seal.log" 2>&1 || { cat "$TMP/seal.log" >&2; return 1; }
  # 전이를 하나씩 밟으면 set-status 한 번에 2~3초라 --force 한 번으로 옮깁니다(전이표는 이 시험의 대상이 아님).
  ( cd "$wt" && bash rd-workflow/scripts/rd task set-status "아카이브 보류" --force ) >/dev/null 2>&1 \
    || { echo "set-status 아카이브 보류 실패" >&2; return 1; }
  git -C "$wt" add -A && git -C "$wt" commit -q -m "seal + 아카이브 보류"
}

# 틀 설정. `rd pr open` 과 archive 게이트는 작업 브랜치에 커밋된 workflow.json 을 읽고, 그 파일은 seal 이 보호하는
# 트리에 듭니다. 그래서 설정마다 틀을 따로 만듭니다(처음 쓸 때 한 번, 약 20초).
cfg_json() {
  case "$1" in
    a_pr)   echo '{"publish_approval":"caller","team_publish":{"base":"main","submodules":{"libs/b":{"mode":"manual"},"libs/c":{"mode":"manual"}}}}' ;;
    ab_pr)  echo '{"publish_approval":"caller","team_publish":{"base":"main","submodules":{"libs/c":{"mode":"manual"}}}}' ;;
    a_push) echo '{"publish_approval":"caller","team_publish":{"base":"main","submodules":{"libs/a":{"mode":"push"},"libs/b":{"mode":"manual"},"libs/c":{"mode":"manual"}}}}' ;;
    mixed)  echo '{"publish_approval":"caller","team_publish":{"base":"main","submodules":{"libs/b":{"mode":"push"},"libs/c":{"mode":"manual"}}}}' ;;
    manual) echo '{"publish_approval":"user","team_publish":{"mode":"manual"}}' ;;
    same_br) echo '{"publish_approval":"caller","team_publish":{"base":"demo","submodules":{"libs/b":{"mode":"manual"},"libs/c":{"mode":"manual"}}}}' ;;
    other_push) echo '{"publish_approval":"caller","team_publish":{"base":"main","submodules":{"libs/b":{"mode":"manual"},"libs/c":{"mode":"manual"},"other":{"mode":"push"}}}}' ;;
    other_late) cfg_json other_push ;;
    nofr)   cfg_json a_pr ;;
    *) return 1 ;;
  esac
}

# _seed_overlay <설정 이름> — $W 에 팀 bare 원격과 submodule 을 품은 overlay 를 seed 커밋까지 만듭니다.
#   other_push 는 submodule other(팀 원격 team-other)를 더 둡니다.
_seed_overlay() {
  local name="$1" n s subs="a b c"
  [[ "$name" == other_push || "$name" == other_late ]] && subs="a b c other"
  rm -rf "${W:?}" "$TMP"/src-?
  mkdir -p "$W"
  for n in $subs; do
    git init -q --bare -b main "$W/team-$n.git"
    s="$TMP/src-$n"; git init -q -b main "$s"
    echo "$n" >"$s/f.txt"; git -C "$s" add -A; git -C "$s" commit -q -m init; git -C "$s" push -q "$W/team-$n.git" main
  done
  mkdir -p "$R/rd-workflow"
  cp -R "$RDW_SRC/." "$R/rd-workflow/"
  if [[ -f "$RDW_SRC/../.gitignore" ]]; then cp "$RDW_SRC/../.gitignore" "$R/.gitignore"; else printf '.worktrees/\n' >"$R/.gitignore"; fi
  cfg_json "$name" >"$R/rd-workflow/config/workflow.json" || return 1
  git init -q -b main "$R"
  mkdir -p "$R/rd-workflow-workspace/.lifecycle" "$R/rd-workflow-workspace/backlog/items"
  bash -c "source '$R/rd-workflow/scripts/lifecycle/_lifecycle_common.sh'; emit_current_task_baseline" >"$R/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
    >"$R/rd-workflow-workspace/.lifecycle/task-state"
  printf '# Change Request\n\n## Source FR\n-\n' >"$R/REQUEST.md"
  printf '# 2026-11-16 demo\n- status: validated\n- summary: 데모 작업 요약\n- github-issue: -\n' >"$R/$FR_ITEM"
  for n in a b c; do git -C "$R" submodule add -q "$W/team-$n.git" "libs/$n" || return 1; done
  if [[ "$name" == other_push || "$name" == other_late ]]; then git -C "$R" submodule add -q "$W/team-other.git" other || return 1; fi
  git -C "$R" add -A; git -C "$R" commit -q -m seed
}

# _author_turn <session> — PR 본문 절을 담은 Author 턴을 둡니다.
_author_turn() {
  mkdir -p "$1/turns"
  printf '# 001 Author\n\n## Summary\n요약\n\n## PR 본문\n\n### Summary\n- 무엇을: 데모 변경\n\n### User-visible Changes\n- 없음\n\n## Questions For Reviewer\n- 없음\n' \
    >"$1/turns/001_author.md"
}

# _build_template <설정 이름> — $W 에 seal 까지 마친 overlay 를 만들고 $TMP/tpl-<이름> 으로 복사해 둡니다.
#   틀 하나에 약 20초입니다: open·apply 가 seal 을 검증하므로 실제 리뷰 세션 → seal 경로를 거쳐야 하고, seal·set-status 가
#   submodule 내용 해시를 계산합니다. other_push·nofr 도 같은 이유로 각자 틀 하나를 처음 쓸 때 한 번 만듭니다.
#   other_push: promote 뒤 기본 브랜치가 submodule other 를 바꾸고(팀 원격에도 push) 작업 브랜치가 그 커밋을 병합한 뒤 구현합니다.
#   other_late: other_push 와 같은 변경이지만, 기본 브랜치 병합을 리뷰 세션을 만든 뒤·seal 앞에 합니다(리뷰한 끝 ≠ seal 시점 HEAD).
#   nofr: promote 없이 기본 브랜치에서 fr-branch=null 작업으로 구현·리뷰·seal 합니다(spec D3-1).
_build_template() {
  local name="$1" n ses base
  [[ "$name" == nofr ]] && { _build_nofr_template; return; }
  _seed_overlay "$name" || return 1
  ( cd "$R" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title "$SLUG" --size large --source-fr "$FR_ITEM" ) \
    >"$TMP/promote.log" 2>&1 || { cat "$TMP/promote.log" >&2; return 1; }
  git -C "$WT" submodule update -q --init || return 1
  if [[ "$name" == other_push ]]; then
    echo main-other >>"$R/other/f.txt"; git -C "$R/other" commit -q -am "main other"; git -C "$R/other" push -q origin HEAD:main
    git -C "$R" add other; git -C "$R" commit -q -m "main: other 변경"
    git -C "$WT" merge -q --no-edit main >/dev/null || return 1
    git -C "$WT" submodule update -q other || return 1
  fi
  for n in a b c; do
    echo "change-$n" >>"$WT/libs/$n/f.txt"; git -C "$WT/libs/$n" commit -q -am "change $n"
  done
  git -C "$WT" add -A; git -C "$WT" commit -q -m 구현
  ( cd "$WT" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff ) >"$TMP/prep.log" 2>&1 || true
  ses="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | tail -1)"
  [[ -n "$ses" ]] || { cat "$TMP/prep.log" >&2; return 1; }
  _author_turn "$ses"
  if [[ "$name" == other_late ]]; then
    echo main-other >>"$R/other/f.txt"; git -C "$R/other" commit -q -am "main other"; git -C "$R/other" push -q origin HEAD:main
    git -C "$R" add other; git -C "$R" commit -q -m "main: other 변경"
    git -C "$WT" merge -q --no-edit main >/dev/null || return 1
    git -C "$WT" submodule update -q other || return 1
  fi
  seal_and_hold "$WT" "$ses" || return 1
  cp -R "$W" "$TMP/tpl-$name"
}

# _build_nofr_template — 기본 브랜치(main)에서 fr-branch=null 작업으로 libs/a·b·c 를 바꾸고 리뷰·seal 해 아카이브 보류로 둡니다.
_build_nofr_template() {
  local n ses base
  _seed_overlay nofr || return 1
  base="$(git -C "$R" rev-parse HEAD)"
  printf 'schema=1\nshort-title=%s\nstatus=구현 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=%s\nreview-session=null\n' "$SLUG" "$base" \
    >"$R/rd-workflow-workspace/.lifecycle/task-state"
  for n in a b c; do
    echo "change-$n" >>"$R/libs/$n/f.txt"; git -C "$R/libs/$n" commit -q -am "change $n"
  done
  git -C "$R" add -A; git -C "$R" commit -q -m 구현
  ( cd "$R" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff ) >"$TMP/prep.log" 2>&1 || true
  ses="$(ls -d "$R"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review 2>/dev/null | tail -1)"
  [[ -n "$ses" ]] || { cat "$TMP/prep.log" >&2; return 1; }
  _author_turn "$ses"
  seal_and_hold "$R" "$ses" || return 1
  cp -R "$W" "$TMP/tpl-nofr"
}

# mk_overlay_with_team <설정 이름> — 그 설정의 틀을 $W 에 새로 복사합니다(처음 부를 때 틀을 만듭니다).
#   전역: R WT SES HEAD_A HEAD_B HEAD_C (리뷰한 gitlink) BASE_COMMIT CUR_TPL
mk_overlay_with_team() {
  local name="${1:?설정 이름}"
  if [[ ! -d "$TMP/tpl-$name" ]]; then
    _build_template "$name" || { echo "fixture 생성 실패: $name" >&2; exit 1; }
  fi
  rm -rf "${W:?}"
  cp -cR "$TMP/tpl-$name" "$W" 2>/dev/null || cp -R "$TMP/tpl-$name" "$W"
  CUR_TPL="$name"
  SES="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review | tail -1)"
  HEAD_A="$(git -C "$WT" rev-parse HEAD:libs/a)"
  HEAD_B="$(git -C "$WT" rev-parse HEAD:libs/b)"
  HEAD_C="$(git -C "$WT" rev-parse HEAD:libs/c)"
  BASE_COMMIT="$(awk -F= '$1=="base-commit"{print $2}' "$WT/rd-workflow-workspace/.lifecycle/task-state")"
  [[ -f "$TMP/sig-$name" ]] || _fixture_sig >"$TMP/sig-$name"
}

# _fixture_sig — 케이스가 바꿀 수 있는 상태(작업 브랜치 커밋·워킹트리·팀 원격 ref)의 요약.
_fixture_sig() {
  { git -C "$WT" rev-parse HEAD; git -C "$WT" status --porcelain
    for n in a b c; do git --git-dir="$W/team-$n.git" for-each-ref; git -C "$WT/libs/$n" rev-parse HEAD; done
  } 2>&1 | cksum
}
# reuse_overlay <설정 이름> — 지금 $W 가 같은 틀이고 앞 케이스가 상태를 바꾸지 않았으면 그대로 쓰고(복사 비용 절약),
# 아니면 새로 복사합니다. 요약에 없는 흔적(FETCH_HEAD)은 보지 않으므로, fetch 하는 케이스 뒤에서 그 흔적에 기대지 않습니다
# (t_open_no_gh 는 앞의 재사용 케이스가 모두 fetch 전에 멈추고, 준비 단언으로 FETCH_HEAD 부재를 먼저 확인합니다).
reuse_overlay() {
  local name="${1:?설정 이름}"
  if [[ "${CUR_TPL:-}" == "$name" && -d "$WT" && -f "$TMP/sig-$name" && "$(_fixture_sig)" == "$(cat "$TMP/sig-$name")" ]]; then return 0; fi
  mk_overlay_with_team "$name"
}

# setup_fake_gh — 가짜 gh 를 PATH 앞에 두고 상태 디렉터리 $FAKE 를 비웁니다.
#   $FAKE/log      호출마다 인자 한 줄
#   $FAKE/prs      `repo<TAB>head<TAB>state<TAB>url[<TAB>headRefOid<TAB>merge-oid<TAB>커밋 수<TAB>reviewDecision<TAB>작성자:의견]`
#                  (pr create 가 앞 네 칸을 더함, 테스트가 나머지를 바꿈 — pr_set)
#   $FAKE/body     마지막 --body-file 내용
#   $FAKE/bases    `url<TAB>baseRefName` (pr create 가 --base 를 더함, 없는 URL 은 main — set_pr_base)
#   $FAKE/auth_fail · repo_fail      있으면 그 하위 명령 rc 1
#   $FAKE/create_<owner_repo>        내용 fail(출력 없이 실패) | lost(PR 은 만들고 출력 없이 실패)
FAKE="$TMP/fakegh"; FAKEBIN="$TMP/fakebin"
setup_fake_gh() {
  rm -rf "$FAKE"; mkdir -p "$FAKE" "$FAKEBIN"
  : >"$FAKE/log"; : >"$FAKE/prs"; echo 0 >"$FAKE/n"
  export FAKE_GH_DIR="$FAKE"
  [[ -x "$FAKEBIN/gh" ]] && return 0
  cat >"$FAKEBIN/gh" <<'FAKE_EOF'
#!/usr/bin/env bash
F="$FAKE_GH_DIR"
printf '%s\n' "$*" >>"$F/log"
repo=""; head=""; state=""; base=""; prev=""
touch "$F/bases"
for a in "$@"; do
  case "$prev" in
    --repo|-R) repo="$a" ;;
    --base) base="$a" ;;
    --head) head="$a" ;;
    --state) state="$a" ;;
    --body-file) cat "$a" >"$F/body" ;;
  esac
  prev="$a"
done
case "$1 $2" in
  "auth status") [[ -f "$F/auth_fail" ]] && { echo "You are not logged into any GitHub hosts." >&2; exit 1; }; exit 0 ;;
  "repo view")
    [[ -f "$F/repo_fail" ]] && { echo "none of the git remotes configured for this repository point to a known GitHub host" >&2; exit 1; }
    n="$(basename "$3" .git)"
    printf '{"nameWithOwner":"o/%s","defaultBranchRef":{"name":"main"}}\n' "$n" ;;
  "pr list")
    awk -F'\t' -v r="$repo" -v h="$head" -v s="$state" '
      FILENAME == ARGV[1] { B[$1] = $2; next }
      $1 == r && $2 == h && (s == "all" || s == "" || tolower($3) == tolower(s)) {
        b = ($4 in B) ? B[$4] : "main"
        printf "%s{\"state\":\"%s\",\"url\":\"%s\",\"baseRefName\":\"%s\"}", (k++ ? "," : ""), $3, $4, b }
      BEGIN { printf "[" }
      END { print "]" }' "$F/bases" "$F/prs" ;;
  "pr create")
    n=$(( $(cat "$F/n") + 1 )); echo "$n" >"$F/n"
    url="https://github.com/$repo/pull/$n"
    key="create_$(printf '%s' "$repo" | tr '/' '_')"
    mode=""; [[ -f "$F/$key" ]] && mode="$(cat "$F/$key")"
    [[ "$mode" == fail ]] && { echo "pull request create failed: GraphQL: internal error" >&2; exit 1; }
    printf '%s\t%s\tOPEN\t%s\n' "$repo" "$head" "$url" >>"$F/prs"
    if [[ -f "$F/stage_on_create" && -n "${FAKE_GH_WT:-}" ]]; then
      echo x >"$FAKE_GH_WT/app.txt"; git -C "$FAKE_GH_WT" add app.txt
    fi
    printf '%s\t%s\n' "$url" "${base:-main}" >>"$F/bases"
    [[ "$mode" == lost ]] && exit 1
    printf '%s\n' "$url" ;;
  "pr view")
    line="$(awk -F'\t' -v u="$3" '$4 == u { print; exit }' "$F/prs")"
    [[ -n "$line" ]] || { echo "no pull requests found" >&2; exit 1; }
    # 빈 칸을 보존하려고 탭을 비공백 구분자로 바꿔 읽습니다.
    IFS=$'\037' read -r _r _h st _u ho mo k rdc rv <<<"$(printf '%s' "$line" | tr '\t' '\037')"
    mc=null; [[ -n "$mo" ]] && mc="{\"oid\":\"$mo\"}"
    cm=""; j=0; while [[ "$j" -lt "${k:-0}" ]]; do cm="${cm:+$cm,}{}"; j=$((j + 1)); done
    pb="$(awk -F'\t' -v u="$3" '$1 == u { b = $2 } END { print (b == "" ? "main" : b) }' "$F/bases")"
    revs=""; [[ -n "$rv" ]] && revs="{\"author\":{\"login\":\"${rv%%:*}\"},\"body\":\"${rv#*:}\",\"submittedAt\":\"2026-11-16T00:00:00Z\"}"
    printf '{"state":"%s","mergeCommit":%s,"reviewDecision":"%s","headRefOid":"%s","baseRefName":"%s","commits":[%s],"latestReviews":[%s]}\n' \
      "$st" "$mc" "$rdc" "$ho" "$pb" "$cm" "$revs" ;;
  "pr edit")
    [[ -n "$base" ]] && printf '%s\t%s\n' "$3" "$base" >>"$F/bases"
    awk -F'\t' -v u="$3" '$4 == u { f = 1 } END { exit f ? 0 : 1 }' "$F/prs" || { echo "no pull requests found" >&2; exit 1; } ;;
  *) echo "fake gh: 지원하지 않는 명령: $*" >&2; exit 1 ;;
esac
FAKE_EOF
  chmod +x "$FAKEBIN/gh"
}
export PATH="$FAKEBIN:$PATH"

# want <케이스> — TP_TEST_CASES(공백 구분)가 비었거나 그 케이스를 담으면 실행합니다(변이 확인 때 골라 돌리기용).
# TP_SKIP_CASES 에 든 케이스는 실행하지 않습니다(병렬 실행의 나머지 묶음용).
want() {
  [[ " ${TP_SKIP_CASES:-} " == *" $1 "* ]] && return 1
  [[ -z "${TP_TEST_CASES:-}" || " $TP_TEST_CASES " == *" $1 "* ]]
}

# 병렬 실행. 케이스 고르기(TP_TEST_CASES·TP_SKIP_CASES)도 TP_SERIAL=1 도 없으면, 이 파일을 묶음마다 자식 프로세스로
# 동시에 돌리고 결과를 모읍니다. 틀은 프로세스마다 따로 만들므로 같은 틀을 쓰는 케이스를 한 묶음에 둡니다.
# 마지막 묶음은 앞 묶음에 없는 케이스를 모두 돌립니다 — 새 케이스는 묶음에 넣지 않아도 빠지지 않습니다.
# 실측(2026-11-17, load 평균 10~21 인 10코어 머신): 직렬 852초 → 7묶음 241초(4묶음은 274초). 직렬로 보려면 TP_SERIAL=1.
if [[ -z "${TP_TEST_CASES:-}${TP_SKIP_CASES:-}${TP_SERIAL:-}" ]]; then
  TP_GROUPS=(
    "t_open_closed_pr_stops t_open_lost_url_rerun t_open_two_open_prs t_open_existing_base_mismatch_recorded t_open_existing_base_mismatch_listed t_open_record_commit_scoped t_open_pr_push_non_ff"
    "t_open_partial_then_merged_retry t_check_states t_apply_partial t_apply_interrupted_waits_for_checks t_apply_interrupted_foreign_change_kept t_apply_resume_interrupted t_apply_rollback_on_second_checkout t_check_task_other_root t_check_rows_cd"
    "t_open_push_mode t_open_push_non_ff t_open_branch_equals_base"
    "t_open_mixed_modes_table t_apply_mixed_modes t_open_manual_skip"
    "t_apply_dirty_index_refused t_apply_rollback_on_commit_failure t_apply_rollback_keeps_foreign_edit t_apply_rollback_keeps_foreign_head t_apply_gitlink_not_head_refused t_apply_merge_commit t_apply_pointer_moved_by_hand"
    "t_apply_resume_after_status_commit_failure t_apply_resume_mirror_only t_apply_conflict_resolution_blocks t_apply_head_mismatch t_apply_squash_team_ahead_publish"
    "t_open_nofr_accepted t_open_nofr_refusals t_apply_nofr_refused t_nofr_full_publish t_closed_choice_rollback t_nofr_with_index"
    "t_target_base_main_merged"
    "t_target_merge_before_seal"
    "t_apply_record_outside_scope"
  )
  tp_all="${TP_GROUPS[*]}"; tp_pids=(); tp_n=${#TP_GROUPS[@]}
  # 자식의 stdout·stderr 를 따로 받아 그대로 돌려줍니다 — self_test 는 stderr 에서 `command not found` 를 찾습니다.
  for ((tp_i = 0; tp_i <= tp_n; tp_i++)); do
    if [[ "$tp_i" -lt "$tp_n" ]]; then
      TP_TEST_CASES="${TP_GROUPS[$tp_i]}" bash "$SCRIPT_DIR/test_team_publish.sh" >"$TMP/group-$tp_i.out" 2>"$TMP/group-$tp_i.err" &
    else
      TP_SKIP_CASES="$tp_all" bash "$SCRIPT_DIR/test_team_publish.sh" >"$TMP/group-$tp_i.out" 2>"$TMP/group-$tp_i.err" &
    fi
    tp_pids+=("$!")
  done
  echo "병렬 $((tp_n + 1))묶음 시작 — 묶음 출력은 모두 끝난 뒤 차례로 보입니다. 실행 중 로그: $TMP/group-<번호>.out·.err"
  # 진행 표시: 묶음이 끝날 때마다 한 줄. 실패 판정은 아래 출력 단계에서 합니다.
  tp_seen=" "; tp_k=0
  while [[ "$tp_k" -le "$tp_n" ]]; do
    for ((tp_i = 0; tp_i <= tp_n; tp_i++)); do
      [[ "$tp_seen" == *" $tp_i "* ]] && continue
      kill -0 "${tp_pids[$tp_i]}" 2>/dev/null && continue
      tp_seen="$tp_seen$tp_i "; tp_k=$((tp_k + 1))
      echo "  묶음 $((tp_i + 1)) 끝남 ($tp_k/$((tp_n + 1)), 경과 $((SECONDS - T0))초)"
    done
    [[ "$tp_k" -le "$tp_n" ]] && sleep 2
  done
  tp_rc=0
  for ((tp_i = 0; tp_i <= tp_n; tp_i++)); do
    wait "${tp_pids[$tp_i]}" || tp_rc=1
    echo "== 묶음 $((tp_i + 1))/$((tp_n + 1)) =="
    cat "$TMP/group-$tp_i.out"
    cat "$TMP/group-$tp_i.err" >&2
    tp_line="$(grep '^결과: PASS=' "$TMP/group-$tp_i.out" | tail -1)"
    [[ -n "$tp_line" ]] || { echo "  FAIL: 묶음 $((tp_i + 1)) 이 결과 줄 없이 끝났습니다" >&2; FAIL=$((FAIL + 1)); continue; }
    tp_p="${tp_line#*PASS=}"; tp_p="${tp_p%% *}"; tp_f="${tp_line#*FAIL=}"; tp_f="${tp_f%% *}"
    PASS=$((PASS + tp_p)); FAIL=$((FAIL + tp_f))
  done
  echo
  echo "결과: PASS=$PASS FAIL=$FAIL (병렬 $((tp_n + 1))묶음, 소요 $((SECONDS - T0))초)"
  [[ "$FAIL" -eq 0 && "$tp_rc" -eq 0 ]]
  exit
fi

# 케이스 공용 도구
status_of() { awk -F= '$1=="status"{sub(/^[^=]+=/,""); print}' "$WT/rd-workflow-workspace/.lifecycle/task-state"; }
rec() { awk -F'\t' -v p="$1" -v n="$2" '$1==p{print $n}' "$WT/rd-workflow-workspace/.lifecycle/team-prs.tsv" 2>/dev/null; }
team_ref() { git --git-dir="$W/team-$1.git" rev-parse -q --verify "refs/heads/$2" 2>/dev/null; }
ghn() { grep -c -- "$1" "$FAKE/log" 2>/dev/null | tr -d ' '; }
set_pr_state() {  # <repo> <state> — 그 저장소의 PR 상태를 바꿉니다
  awk -F'\t' -v OFS='\t' -v r="$1" -v s="$2" '$1==r{$3=s} {print}' "$FAKE/prs" >"$FAKE/prs.t" && mv "$FAKE/prs.t" "$FAKE/prs"
}
# run_open [args...] — 작업 worktree 에서 rd pr open. stdout 은 OUT, stderr 는 ERR, rc 는 RC.
run_open() {
  RC=0
  ( cd "$WT" && bash rd-workflow/scripts/rd pr open "$@" ) >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
# team_advance <n> <ref> — 팀 저장소 n 의 main 위에 다른 커밋을 하나 만들어 <ref> 로 push 합니다.
team_advance() {
  local c="$TMP/adv-$1"; rm -rf "$c"
  git clone -q "$W/team-$1.git" "$c" 2>/dev/null
  echo other >>"$c/other.txt"; git -C "$c" add -A; git -C "$c" commit -q -m other
  git -C "$c" push -q origin "HEAD:refs/heads/$2"
}
# commit_record <msg> — 작업 worktree 의 기록 경로 변경을 커밋합니다(seal 은 그대로 유효).
RD_REC="rd-workflow-workspace/.lifecycle/team-prs.tsv"
commit_record() { git -C "$WT" add -A && git -C "$WT" commit -q -m "$1"; }

echo "== open: PR 생성·재실행 =="

t_open_creates_pr() {
  mk_overlay_with_team a_pr; setup_fake_gh
  run_open --approved
  eq "t_open_creates_pr: rc 0" "$RC" "0"
  eq "t_open_creates_pr: Status PR 검토 중" "$(status_of)" "PR 검토 중"
  eq "t_open_creates_pr: 팀 브랜치가 리뷰한 커밋" "$(team_ref a demo)" "$HEAD_A"
  eq "t_open_creates_pr: pr create --base main 1회" "$(ghn 'pr create --repo o/team-a --base main --head demo')" "1"
  eq "t_open_creates_pr: 기록 state=open" "$(rec libs/a 7)" "open"
  eq "t_open_creates_pr: 기록 URL" "$(rec libs/a 5)" "https://github.com/o/team-a/pull/1"
  eq "t_open_creates_pr: 기록 커밋" "$(git -C "$WT" log -1 --format=%s)" "chore(lifecycle): demo 팀 저장소 반영 기록"
  eq "t_open_creates_pr: worktree 깨끗" "$(git -C "$WT" status --porcelain)" ""
  ok "t_open_creates_pr: 결과 줄" "libs/a: PR 생성 https://github.com/o/team-a/pull/1" "$OUT"
  eq "t_open_creates_pr: 설정 있으면 첫 실행 안내 없음" "$ERR" ""

  # t_open_rerun_from_pr_review — Status 를 건드리지 않고 바로 재실행 → 본문 갱신만
  run_open --approved
  eq "t_open_rerun_from_pr_review: rc 0" "$RC" "0"
  eq "t_open_rerun_from_pr_review: pr edit 1회" "$(ghn 'pr edit')" "1"
  eq "t_open_rerun_from_pr_review: pr create 총 1회" "$(ghn 'pr create')" "1"
  ok "t_open_rerun_from_pr_review: 결과 줄" "libs/a: PR 갱신 https://github.com/o/team-a/pull/1" "$OUT"
  eq "t_open_rerun_from_pr_review: Status 그대로" "$(status_of)" "PR 검토 중"
}
want t_open_creates_pr && t_open_creates_pr

t_open_partial_then_merged_retry() {
  mk_overlay_with_team ab_pr; setup_fake_gh
  echo fail >"$FAKE/create_o_team-b"
  run_open --approved
  eq "t_open_partial: 첫 실행 rc 1" "$RC" "1"
  eq "t_open_partial: Status 아카이브 보류" "$(status_of)" "아카이브 보류"
  eq "t_open_partial: 기록에 A" "$(rec libs/a 7)" "open"
  eq "t_open_partial: 기록에 B 없음" "$(rec libs/b 1)" ""
  eq "t_open_partial: 성공 기록은 커밋됨" "$(git -C "$WT" status --porcelain)" ""
  # A 의 PR 이 merge 되고 팀이 브랜치를 지웠습니다.
  set_pr_state o/team-a MERGED
  git --git-dir="$W/team-a.git" update-ref -d refs/heads/demo
  rm -f "$FAKE/create_o_team-b"
  run_open --approved
  eq "t_open_partial: 재실행 rc 0" "$RC" "0"
  eq "t_open_partial: A 는 create 없음(총 1회)" "$(ghn 'pr create --repo o/team-a')" "1"
  eq "t_open_partial: A 는 push 없음(팀 브랜치 부재 유지)" "$(team_ref a demo)" ""
  ok "t_open_partial: A 이미 merge 됨" "libs/a: 이미 merge 됨 — rd pr check --apply" "$OUT"
  eq "t_open_partial: B 는 create 2회(실패 1 + 성공 1)" "$(ghn 'pr create --repo o/team-b')" "2"
  eq "t_open_partial: B 기록 open" "$(rec libs/b 7)" "open"
  eq "t_open_partial: A 기록 state=open 유지" "$(rec libs/a 7)" "open"
  eq "t_open_partial: Status PR 검토 중" "$(status_of)" "PR 검토 중"
}
want t_open_partial_then_merged_retry && t_open_partial_then_merged_retry

echo "== open: 기존 PR 상태별 =="

t_open_closed_pr_stops() {
  mk_overlay_with_team a_pr; setup_fake_gh
  run_open --approved
  set_pr_state o/team-a CLOSED
  run_open --approved
  eq "t_open_closed_pr_stops: rc 1" "$RC" "1"
  eq "t_open_closed_pr_stops: create 총 1회" "$(ghn 'pr create')" "1"
  ok "t_open_closed_pr_stops: 다시 올리기 선택지" "gh pr reopen https://github.com/o/team-a/pull/1" "$OUT"
  ok "t_open_closed_pr_stops: dropped 선택지" "/fr status demo dropped" "$OUT"
  # t_closed_choice_rollback(fr) — 없으면 새는 실수: 지우려는 worktree 안에서 실행해 멈추는 취소 명령, 또는 호출한 셸의
  # 다른 작업을 취소하는 명령을 안내합니다. 기본 체크아웃(R)으로 옮겨 --task 로 부르는 한 줄 전체를 봅니다.
  eq "t_closed_choice_rollback(fr): 1) 줄" "$(printf '%s\n' "$OUT" | grep '1) dropped 로 닫기')" \
    "    1) dropped 로 닫기: /fr status demo dropped 뒤 cd '$R' && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task 'demo'"
}
want t_open_closed_pr_stops && t_open_closed_pr_stops

t_open_lost_url_rerun() {
  mk_overlay_with_team a_pr; setup_fake_gh
  echo lost >"$FAKE/create_o_team-a"
  run_open --approved
  eq "t_open_lost_url_rerun: 첫 실행 rc 1" "$RC" "1"
  eq "t_open_lost_url_rerun: 기록 없음" "$(rec libs/a 1)" ""
  rm -f "$FAKE/create_o_team-a"
  run_open --approved
  eq "t_open_lost_url_rerun: 재실행 rc 0" "$RC" "0"
  eq "t_open_lost_url_rerun: create 총 1회" "$(ghn 'pr create')" "1"
  eq "t_open_lost_url_rerun: pr list --state all 로 찾음" "$(ghn 'pr list --repo o/team-a --head demo --state all')" "2"
  eq "t_open_lost_url_rerun: 찾은 URL 기록" "$(rec libs/a 5)" "https://github.com/o/team-a/pull/1"
}
want t_open_lost_url_rerun && t_open_lost_url_rerun

t_open_two_open_prs() {
  mk_overlay_with_team a_pr; setup_fake_gh
  printf 'o/team-a\tdemo\tOPEN\thttps://github.com/o/team-a/pull/11\no/team-a\tdemo\tOPEN\thttps://github.com/o/team-a/pull/12\n' >"$FAKE/prs"
  run_open --approved
  eq "t_open_two_open_prs: rc 1" "$RC" "1"
  ok "t_open_two_open_prs: 첫 URL" "https://github.com/o/team-a/pull/11" "$OUT"
  ok "t_open_two_open_prs: 둘째 URL" "https://github.com/o/team-a/pull/12" "$OUT"
  eq "t_open_two_open_prs: 기록 없음" "$(rec libs/a 1)" ""
}
want t_open_two_open_prs && t_open_two_open_prs

# 열린 PR 의 실제 대상 브랜치(release)가 설정(main)과 다르면 push·본문 갱신 전에 멈춥니다.
# 없으면 새는 실수: 설정과 다른 브랜치로 열린 PR 을 그대로 갱신하고 기록에는 설정 base 를 적습니다.
set_pr_base() { printf '%s\t%s\n' "$1" "$2" >>"$FAKE/bases"; }  # <url> <base>
base_mismatch_common() {  # <케이스 이름> <url> <기대 Status>
  local c="$1" u="$2"
  eq "$c: rc 1" "$RC" "1"
  eq "$c: pr edit 0" "$(ghn 'pr edit')" "0"
  ok "$c: 실제·설정 base" "실제 대상 브랜치: release / 설정한 대상 브랜치: main" "$OUT"
  ok "$c: 복구(대상 맞추기)" "gh pr edit $u --base main" "$OUT"
  ok "$c: 복구(설정 바꾸기)" "team_publish.base" "$OUT"
  ok "$c: 복구(설정 바꾸기) 대상 브랜치" "release 로 고침" "$OUT"
  ok "$c: 복구(seal 과 설정 절 안내)" "「seal 과 설정」" "$OUT"
  no "$c: 닫고 새로 만들기 안내 없음" "gh pr close" "$OUT"
  ok "$c: 결과 줄" "멈춤 — 열린 PR 의 대상 브랜치(release)가 설정(main)과 다릅니다" "$OUT"
  eq "$c: Status 그대로" "$(status_of)" "$3"
}

t_open_existing_base_mismatch_recorded() {
  local c=t_open_existing_base_mismatch_recorded u=https://github.com/o/team-a/pull/1 pre
  mk_overlay_with_team a_pr; setup_fake_gh
  run_open --approved
  eq "$c: 준비 — 첫 실행 rc 0" "$RC" "0"
  # 기록 URL 경로로 재실행합니다. push 를 감지하려고 팀 브랜치를 main 으로 되돌리고, PR 의 base 를 release 로 바꿉니다.
  git --git-dir="$W/team-a.git" update-ref refs/heads/demo "$(git --git-dir="$W/team-a.git" rev-parse main)"
  pre="$(team_ref a demo)"
  set_pr_base "$u" release
  : >"$FAKE/log"
  run_open --approved
  base_mismatch_common "$c" "$u" "PR 검토 중"
  eq "$c: 팀 브랜치 불변(push 없음)" "$(team_ref a demo)" "$pre"
  eq "$c: 기록 base 칸 불변" "$(rec libs/a 4)" "main"
  eq "$c: 기록 URL 그대로" "$(rec libs/a 5)" "$u"
  # 안내 가) 를 따라갑니다: gh pr edit --base main 뒤 재실행하면 본문만 갱신하고 새 PR 은 만들지 않습니다.
  gh pr edit "$u" --base main >/dev/null
  : >"$FAKE/log"
  run_open --approved
  eq "$c: 가) 뒤 재실행 rc 0" "$RC" "0"
  eq "$c: 가) 뒤 pr edit(본문 갱신) 1회" "$(ghn 'pr edit')" "1"
  eq "$c: 가) 뒤 pr create 0" "$(ghn 'pr create')" "0"
}
want t_open_existing_base_mismatch_recorded && t_open_existing_base_mismatch_recorded

t_open_existing_base_mismatch_listed() {
  local c=t_open_existing_base_mismatch_listed u=https://github.com/o/team-a/pull/21
  mk_overlay_with_team a_pr; setup_fake_gh
  printf 'o/team-a\tdemo\tOPEN\t%s\n' "$u" >"$FAKE/prs"
  set_pr_base "$u" release
  run_open --approved
  base_mismatch_common "$c" "$u" "아카이브 보류"
  eq "$c: pr create 0" "$(ghn 'pr create')" "0"
  eq "$c: 팀 브랜치 없음(push 없음)" "$(team_ref a demo)" ""
  eq "$c: 기록 없음" "$(rec libs/a 1)" ""
}
want t_open_existing_base_mismatch_listed && t_open_existing_base_mismatch_listed

# 기록 커밋은 기록 경로만 커밋합니다. 원격 처리 중 stage 된 무관한 파일은 staged 로 남습니다.
# 없으면 새는 실수: 원격 응답을 기다리는 동안 stage 된 사용자 코드가 lifecycle 기록 커밋에 조용히 섞입니다.
t_open_record_commit_scoped() {
  local c=t_open_record_commit_scoped
  mk_overlay_with_team a_pr; setup_fake_gh
  export FAKE_GH_WT="$WT"
  : >"$FAKE/stage_on_create"
  run_open --approved
  unset FAKE_GH_WT
  eq "$c: rc 0" "$RC" "0"
  eq "$c: 가짜 gh 훅 실행됨" "$([[ -f "$WT/app.txt" ]] && echo 있음)" "있음"
  no "$c: 기록 커밋 경로에 app.txt 없음" "app.txt" "$(git -C "$WT" show --format= --name-only HEAD)"
  ok "$c: 기록 파일은 HEAD 에 들어감" "team-prs.tsv" "$(git -C "$WT" show --format= --name-only HEAD)"
  ok "$c: app.txt 는 여전히 staged" "app.txt" "$(git -C "$WT" diff --cached --name-only)"
  ok "$c: 알림 한 줄" "app.txt: 기록 커밋에 넣지 않았습니다(staged 상태 그대로)" "$OUT"
}
want t_open_record_commit_scoped && t_open_record_commit_scoped

echo "== open: merge 뒤 재실행 · 이전 PR · 미커밋 설정 =="

t_open_after_apply_keeps_status() {
  mk_overlay_with_team a_pr; setup_fake_gh
  run_open --approved
  # check --apply 뒤 상태를 만듭니다: PR merge, 기록 state=merged(merged-oid=리뷰한 커밋 — fast-forward merge), Status 아카이브 보류.
  set_pr_state o/team-a MERGED
  awk -F'\t' -v OFS='\t' -v h="$HEAD_A" '$1=="libs/a"{$7="merged"; $8=h; $9="1"} {print}' \
    "$WT/$RD_REC" >"$WT/$RD_REC.t" && mv "$WT/$RD_REC.t" "$WT/$RD_REC"
  ( cd "$WT" && bash rd-workflow/scripts/rd task set-status "아카이브 보류" ) >/dev/null 2>&1
  commit_record "check --apply 흉내"
  eq "t_open_after_apply_keeps_status: 준비 — Status 아카이브 보류" "$(status_of)" "아카이브 보류"
  run_open --approved
  eq "t_open_after_apply_keeps_status: rc 0" "$RC" "0"
  eq "t_open_after_apply_keeps_status: Status 불변(아카이브 보류)" "$(status_of)" "아카이브 보류"
  ok "t_open_after_apply_keeps_status: 반영 완료 줄" "libs/a: 반영 완료" "$OUT"
  eq "t_open_after_apply_keeps_status: create·edit 없음" "$(ghn 'pr create')/$(ghn 'pr edit')" "1/0"
  eq "t_open_after_apply_keeps_status: 기록 state=merged 유지" "$(rec libs/a 7)" "merged"
}
want t_open_after_apply_keeps_status && t_open_after_apply_keeps_status

t_open_merged_other_pr() {
  mk_overlay_with_team a_pr; setup_fake_gh
  printf 'o/team-a\tdemo\tMERGED\thttps://github.com/o/team-a/pull/5\t1111111111111111111111111111111111111111\n' >"$FAKE/prs"
  run_open --approved
  eq "t_open_merged_other_pr: rc 1" "$RC" "1"
  ok "t_open_merged_other_pr: 원인" "이전에 merge 된 다른 PR 이 있습니다" "$OUT"
  ok "t_open_merged_other_pr: URL" "https://github.com/o/team-a/pull/5" "$OUT"
  eq "t_open_merged_other_pr: create 0" "$(ghn 'pr create')" "0"
  eq "t_open_merged_other_pr: 기록 없음" "$(rec libs/a 1)" ""
  eq "t_open_merged_other_pr: Status 불변" "$(status_of)" "아카이브 보류"
}
want t_open_merged_other_pr && t_open_merged_other_pr

t_open_uncommitted_config() {
  mk_overlay_with_team a_pr; setup_fake_gh
  # 작업 worktree 에만 manual 설정을 둡니다. skip-worktree 라 미커밋 변경 검사에는 걸리지 않습니다.
  git -C "$WT" update-index --skip-worktree rd-workflow/config/workflow.json
  printf '%s\n' "$(cfg_json manual)" >"$WT/rd-workflow/config/workflow.json"
  eq "t_open_uncommitted_config: 준비 — status 깨끗" "$(git -C "$WT" status --porcelain)" ""
  run_open --approved
  eq "t_open_uncommitted_config: rc 1" "$RC" "1"
  ok "t_open_uncommitted_config: 원인" "설정을 커밋한 뒤 다시 실행하십시오" "$OUT"
  eq "t_open_uncommitted_config: gh 호출 0" "$(wc -l <"$FAKE/log" | tr -d ' ')" "0"
  eq "t_open_uncommitted_config: 원격 불변" "$(team_ref a demo)" ""
}
want t_open_uncommitted_config && t_open_uncommitted_config

echo "== open: 본문 =="

t_open_body_closes() {
  mk_overlay_with_team a_pr; setup_fake_gh
  # 호스트가 붙은 값은 GitHub 가 읽는 Issue URL 로 바꿉니다(그대로 두면 merge 해도 닫히지 않습니다).
  # 적힌 Issue URL 은 스킴(http)까지 그대로 씁니다.
  sed -i.bak 's|^- github-issue: -$|- github-issue: ghe.example.com/o/r#7, o/r#9, http://ghe.example.com/o/r/issues/8|' "$WT/$FR_ITEM" && rm -f "$WT/$FR_ITEM.bak"
  commit_record "FR 에 Issue 연결"
  run_open --approved
  eq "t_open_body_closes: rc 0" "$RC" "0"
  ok "t_open_body_closes: 본문에 Summary" "### Summary" "$(cat "$FAKE/body")"
  eq "t_open_body_closes: 끝 네 줄(빈 줄 + Closes 3)" "$(tail -4 "$FAKE/body")" "$(printf '\nCloses https://ghe.example.com/o/r/issues/7\nCloses o/r#9\nCloses http://ghe.example.com/o/r/issues/8')"
  no "t_open_body_closes: 다른 절은 넣지 않음" "Questions For Reviewer" "$(cat "$FAKE/body")"
  ok "t_open_body_closes: 제목은 FR summary" "--title 데모 작업 요약 --body-file" "$(cat "$FAKE/log")"
}
want t_open_body_closes && t_open_body_closes

# github-issue 에 설명이 붙으면 Closes 줄을 하나도 넣지 않고 틀린 조각을 알립니다. PR 은 그대로 올립니다.
# 없으면 새는 실수: 「Closes (중복」 같은 줄이 팀 저장소 PR 에 오르고 Issue 는 경고 없이 열린 채 남습니다.
t_open_body_bad_issue() {
  mk_overlay_with_team a_pr; setup_fake_gh
  sed -i.bak 's|^- github-issue: -$|- github-issue: o/r#7 (중복 보고: o/r#3)|' "$WT/$FR_ITEM" && rm -f "$WT/$FR_ITEM.bak"
  commit_record "FR 에 설명 붙은 Issue 연결"
  run_open --approved
  eq "t_open_body_bad_issue: rc 0" "$RC" "0"
  no "t_open_body_bad_issue: Closes 없음" "Closes" "$(cat "$FAKE/body")"
  ok "t_open_body_bad_issue: 틀린 조각" "'o/r#7 (중복 보고: o/r#3)'" "$OUT"
  ok "t_open_body_bad_issue: Closes 생략 안내" "Closes 줄을 넣지 않았습니다" "$OUT"
}
want t_open_body_bad_issue && t_open_body_bad_issue

t_open_no_pr_body() {
  mk_overlay_with_team a_pr; setup_fake_gh
  printf '# 001 Author\n\n## Summary\n요약\n' >"$SES/turns/001_author.md"
  commit_record "PR 본문 절 없음"
  run_open --approved
  eq "t_open_no_pr_body: rc 1" "$RC" "1"
  eq "t_open_no_pr_body: gh 호출 0" "$(wc -l <"$FAKE/log" | tr -d ' ')" "0"
  eq "t_open_no_pr_body: 원격 불변" "$(team_ref a demo)" ""
  ok "t_open_no_pr_body: 원인" "PR 본문을 찾지 못했습니다" "$OUT"
}
want t_open_no_pr_body && t_open_no_pr_body

# 실제 배포 PR_TEMPLATE.md 를 그대로 옮긴 Author 턴에서 템플릿의 `## ` 제목 7개와 각 절 내용을 모두 추출하고,
# 템플릿 밖 `## ` 절·HTML 주석·템플릿 파일 제목은 넣지 않습니다. rd pr open 전체 대신 함수를 직접 부릅니다(1초 안).
# 없으면 새는 실수: 템플릿 제목 수준(`##`)과 추출 경계가 어긋나 본문이 비거나 파일 제목·주석만 PR 에 실립니다.
t_extract_body_real_template() {
  local c=t_extract_body_real_template x="$TMP/xb" tpl="$RDW_SRC/docs/PR_TEMPLATE.md" body rc=0 h n=0
  rm -rf "$x"; mkdir -p "$x/rd-workflow/docs" "$x/rd-workflow-workspace/.lifecycle" "$x/rd-workflow-workspace/handoffs/review_pipeline/S/turns"
  cp "$tpl" "$x/rd-workflow/docs/PR_TEMPLATE.md"
  printf 'schema=1\nreview-session=S\nsource-fr=-\n' >"$x/rd-workflow-workspace/.lifecycle/task-state"
  { printf '# 001 Author\n\n## Summary\n턴 요약\n\n## PR 본문\n\n'
    awk '{ print } /^## / { k++; print "내용-" k " 채움" }' "$tpl"
    printf '\n## 변이 결과표\n| 행 |\n\n## Questions For Reviewer\n- 없음\n'
  } >"$x/rd-workflow-workspace/handoffs/review_pipeline/S/turns/001_author.md"
  body="$(project_root="$x" TASK_STATE_PATH="$x/rd-workflow-workspace/.lifecycle/task-state" bash -c \
    'source "$1/scripts/lifecycle/team_publish.sh" && tp_extract_pr_body "$2"' _ "$RDW_SRC" "$x")" || rc=$?
  eq "$c: rc 0" "$rc" "0"
  while IFS= read -r h; do
    n=$((n + 1))
    ok "$c: 제목 $h" "$h" "$body"
    ok "$c: 절 내용 $n" "내용-$n 채움" "$body"
  done <<EOF_H
$(grep '^## ' "$tpl")
EOF_H
  eq "$c: 템플릿 제목 7개" "$n" "7"
  no "$c: 템플릿 밖 절(변이 결과표) 없음" "변이 결과표" "$body"
  no "$c: 템플릿 밖 절(Questions For Reviewer) 없음" "Questions For Reviewer" "$body"
  no "$c: HTML 주석 없음" "<!--" "$body"
  no "$c: 템플릿 파일 제목 없음" "# PR Template" "$body"
  rm -rf "$x"
}
want t_extract_body_real_template && t_extract_body_real_template

# Source FR 상세 하나가 사라지면 남은 FR 의 Issue 만 Closes 로 붙이지 않고, Closes 를 모두 빼고 사유를 알립니다.
# 함수를 직접 부릅니다(1초 안). 없으면 새는 실수: 등록한 FR 일부의 Issue 연결이 말없이 빠집니다.
t_extract_body_missing_fr() {
  local c=t_extract_body_missing_fr x="$TMP/mf" body err rc=0
  rm -rf "$x"; mkdir -p "$x/rd-workflow-workspace/.lifecycle" "$x/rd-workflow-workspace/handoffs/review_pipeline/S/turns" "$x/rd-workflow-workspace/backlog/items"
  printf 'schema=1\nreview-session=S\nsource-fr=rd-workflow-workspace/backlog/items/gone.md|rd-workflow-workspace/backlog/items/a.md\n' >"$x/rd-workflow-workspace/.lifecycle/task-state"
  printf -- '- summary: s\n- github-issue: o/r#9\n' >"$x/rd-workflow-workspace/backlog/items/a.md"
  printf '# 001 Author\n\n## PR 본문\n\n## Summary\n요약\n' >"$x/rd-workflow-workspace/handoffs/review_pipeline/S/turns/001_author.md"
  body="$(project_root="$x" TASK_STATE_PATH="$x/rd-workflow-workspace/.lifecycle/task-state" bash -c \
    'source "$1/scripts/lifecycle/team_publish.sh" && tp_extract_pr_body "$2"' _ "$RDW_SRC" "$x" 2>"$x.err")" || rc=$?
  err="$(cat "$x.err")"
  eq "$c: rc 0" "$rc" "0"
  ok "$c: 본문은 그대로" "## Summary" "$body"
  no "$c: Closes 없음" "Closes" "$body"
  ok "$c: 사라진 상세" "gone.md 의 FR 상세를 읽을 수 없습니다" "$err"
  rm -rf "$x" "$x.err"
}
want t_extract_body_missing_fr && t_extract_body_missing_fr

# 닫힌 PR 선택지의 Issue 선점 풀기 명령은 gh 가 받는 `<번호> --repo <저장소>` 로 씁니다. 함수를 직접 부릅니다(1초 안).
# 없으면 새는 실수: `gh issue edit o/r#7` 처럼 gh 가 거부하는 인자로 안내해, 사람이 그대로 실행하면 실패합니다.
t_closed_choices_issue_cmd() {
  local c=t_closed_choices_issue_cmd x="$TMP/cc" out rc=0
  rm -rf "$x"; mkdir -p "$x/rd-workflow-workspace/.lifecycle" "$x/rd-workflow-workspace/backlog/items"
  printf 'schema=1\nsource-fr=rd-workflow-workspace/backlog/items/a.md\n' >"$x/rd-workflow-workspace/.lifecycle/task-state"
  printf -- '- summary: s\n- github-issue: ghe.example.com/o/r#7, https://github.com/o/r/issues/9\n' >"$x/rd-workflow-workspace/backlog/items/a.md"
  out="$(project_root="$x" TASK_STATE_PATH="$x/rd-workflow-workspace/.lifecycle/task-state" bash -c \
    'source "$1/scripts/lifecycle/team_publish.sh" && tp_closed_choices demo https://example.invalid/pr/1 "$2"' _ "$RDW_SRC" "$x")" || rc=$?
  eq "$c: rc 0" "$rc" "0"
  ok "$c: 호스트 있는 값" "gh issue edit 7 --repo ghe.example.com/o/r --remove-assignee @me" "$out"
  ok "$c: URL 값" "gh issue edit 9 --repo github.com/o/r --remove-assignee @me" "$out"
  # 호스트 없는 참조는 PR 저장소의 호스트를 가리킨다 — GHE PR 이면 그 호스트를 붙인다.
  printf -- '- summary: s\n- github-issue: o/r#5\n' >"$x/rd-workflow-workspace/backlog/items/a.md"
  out="$(project_root="$x" TASK_STATE_PATH="$x/rd-workflow-workspace/.lifecycle/task-state" bash -c \
    'source "$1/scripts/lifecycle/team_publish.sh" && tp_closed_choices demo https://ghe.example.com/o/r/pull/1 "$2"' _ "$RDW_SRC" "$x")" || rc=$?
  ok "$c: 호스트 없는 값은 PR 호스트" "gh issue edit 5 --repo ghe.example.com/o/r --remove-assignee @me" "$out"
  # PR 호스트를 알 수 없으면 --repo o/r 을 내지 않고 Issue URL 로 지정하라고 안내한다.
  out="$(project_root="$x" TASK_STATE_PATH="$x/rd-workflow-workspace/.lifecycle/task-state" bash -c \
    'source "$1/scripts/lifecycle/team_publish.sh" && tp_closed_choices demo PR-1 "$2"' _ "$RDW_SRC" "$x")" || rc=$?
  ok "$c: PR 호스트 모름" "gh issue edit <Issue URL> --remove-assignee @me (o/r#5 — PR 호스트를 알 수 없어 Issue URL 로 지정하십시오)" "$out"
  eq "$c: PR 호스트 모름 — 실행 명령 없음" "$(printf '%s\n' "$out" | grep -c -- '--repo')" "0"
  # 값을 읽지 못하면 어느 상세의 무엇이 틀렸는지 3) 줄에 보인다(직접 설치 경로는 3) 줄만 옮긴다).
  printf -- '- summary: s\n- github-issue: o/r#5 (설명)\n' >"$x/rd-workflow-workspace/backlog/items/a.md"
  out="$(project_root="$x" TASK_STATE_PATH="$x/rd-workflow-workspace/.lifecycle/task-state" bash -c \
    'source "$1/scripts/lifecycle/team_publish.sh" && tp_closed_choices demo https://ghe.example.com/o/r/pull/1 "$2"' _ "$RDW_SRC" "$x" 2>/dev/null)" || rc=$?
  ok "$c: 값 오류 진단" "    3) 연결된 Issue 선점 풀기: Issue 참조를 읽지 못했습니다 — rd-workflow-workspace/backlog/items/a.md 의 " "$out"
  ok "$c: 값 오류 조각" "(설명)" "$out"
  rm -rf "$x"
}
want t_closed_choices_issue_cmd && t_closed_choices_issue_cmd

echo "== open: dry-run · 승인 =="

t_open_dry_run() {
  reuse_overlay a_pr; setup_fake_gh
  run_open --dry-run
  eq "t_open_dry_run: rc 0" "$RC" "0"
  eq "t_open_dry_run: gh 호출 0" "$(wc -l <"$FAKE/log" | tr -d ' ')" "0"
  eq "t_open_dry_run: 원격 불변" "$(team_ref a demo)" ""
  ok "t_open_dry_run: 제목" "PR 제목: 데모 작업 요약" "$OUT"
  ok "t_open_dry_run: 본문 첫 줄" "PR 본문 첫 줄: ### Summary" "$OUT"
  ok "t_open_dry_run: 대상 표" "$(printf 'libs/a\t%s\tpr\tmain\tdemo' "$W/team-a.git")" "$OUT"
}

t_open_requires_approval() {
  # publish_approval=caller 여도 색인에 호출 세션(caller-id)이 없으면 사용자 승인 대상입니다(발행 큐 request 와 같은 규칙).
  reuse_overlay a_pr; setup_fake_gh
  run_open
  eq "t_open_requires_approval: rc 10" "$RC" "10"
  ok "t_open_requires_approval: 안내" "사용자 승인 대상 — 승인을 받은 뒤 --approved 를 붙여 다시 실행하십시오" "$OUT"
  ok "t_open_requires_approval: 대상 표 머리" "$(printf '경로\t저장소\t반영 방식\t대상 브랜치\t팀 브랜치')" "$OUT"
  eq "t_open_requires_approval: 원격 불변" "$(team_ref a demo)" ""
  eq "t_open_requires_approval: gh 호출 0" "$(wc -l <"$FAKE/log" | tr -d ' ')" "0"
}

echo "== open: push 방식 =="

t_open_push_mode() {
  local m0
  mk_overlay_with_team a_push; setup_fake_gh
  m0="$(team_ref a main)"
  run_open --approved
  eq "t_open_push_mode: --approve-push 없으면 rc 10" "$RC" "10"
  eq "t_open_push_mode: 팀 main 불변" "$(team_ref a main)" "$m0"
  ok "t_open_push_mode: 안내" "사용자 승인 대상 — 승인을 받은 뒤 --approve-push 를 붙여 다시 실행하십시오" "$OUT"
  run_open --approved --approve-push
  eq "t_open_push_mode: rc 0" "$RC" "0"
  eq "t_open_push_mode: 팀 main 전진" "$(team_ref a main)" "$HEAD_A"
  eq "t_open_push_mode: Status 아카이브 보류" "$(status_of)" "아카이브 보류"
  eq "t_open_push_mode: 기록 pushed" "$(rec libs/a 7)" "pushed"
  eq "t_open_push_mode: merged-oid" "$(rec libs/a 8)" "$HEAD_A"
  eq "t_open_push_mode: 기록 커밋" "$(git -C "$WT" status --porcelain)" ""
}
want t_open_push_mode && t_open_push_mode

# push.followTags=true 와 로컬 주석 태그가 있어도 팀 저장소에는 지정한 브랜치 하나만 바뀝니다 (_tp_do_pr·_tp_do_push 의 push).
t_open_no_follow_tags() {
  local mode br extra
  for mode in pr push; do
    if [[ "$mode" == pr ]]; then br=demo; extra=""; else br=main; extra="--approve-push"; fi
    mk_overlay_with_team "a_${mode}"; setup_fake_gh
    git -C "$WT/libs/a" config push.followTags true
    git -C "$WT/libs/a" tag -a ft-old -m ft-old "$HEAD_A" || { fail "t_open_no_follow_tags(${mode}): 준비 — ft-old 태그 생성 실패"; return; }
    run_open --approved $extra
    eq "t_open_no_follow_tags(${mode}): rc 0" "$RC" "0"
    eq "t_open_no_follow_tags(${mode}): 팀 ${br} 가 리뷰한 커밋 (push 가 돌았음)" "$(team_ref a "$br")" "$HEAD_A"
    eq "t_open_no_follow_tags(${mode}): 팀 저장소에 로컬 태그 없음" "$(git --git-dir="$W/team-a.git" rev-parse -q --verify refs/tags/ft-old)" ""
  done
}
want t_open_no_follow_tags && t_open_no_follow_tags

t_open_push_non_ff() {
  local m1
  mk_overlay_with_team a_push; setup_fake_gh
  team_advance a main; m1="$(team_ref a main)"
  run_open --approved --approve-push
  eq "t_open_push_non_ff: rc 1" "$RC" "1"
  eq "t_open_push_non_ff: 팀 main 불변" "$(team_ref a main)" "$m1"
  ok "t_open_push_non_ff: 원인" "팀 브랜치 main 가 리뷰한 커밋보다 앞서 있습니다" "$OUT"
}
want t_open_push_non_ff && t_open_push_non_ff

t_open_pr_push_non_ff() {
  local b1
  mk_overlay_with_team a_pr; setup_fake_gh
  team_advance a demo; b1="$(team_ref a demo)"
  run_open --approved
  eq "t_open_pr_push_non_ff: rc 1" "$RC" "1"
  eq "t_open_pr_push_non_ff: pr create 0" "$(ghn 'pr create')" "0"
  eq "t_open_pr_push_non_ff: 팀 브랜치 불변" "$(team_ref a demo)" "$b1"
  ok "t_open_pr_push_non_ff: 원인" "팀 브랜치 demo 에 리뷰하지 않은 커밋이 있습니다" "$OUT"
  ok "t_open_pr_push_non_ff: 복구 안내" "복구:" "$OUT"
  eq "t_open_pr_push_non_ff: Status 불변" "$(status_of)" "아카이브 보류"
}
want t_open_pr_push_non_ff && t_open_pr_push_non_ff

echo "== open: manual · 사전 거부 =="

t_open_manual_skip() {
  reuse_overlay manual; setup_fake_gh
  # --approved 를 붙여 승인 검사를 통과시킵니다 — manual 제외가 없으면 gh 호출까지 가야 단언이 의미를 가집니다.
  run_open --approved
  eq "t_open_manual_skip: rc 0" "$RC" "0"
  eq "t_open_manual_skip: gh 호출 0" "$(wc -l <"$FAKE/log" | tr -d ' ')" "0"
  ok "t_open_manual_skip: 건너뜀" "libs/a: 건너뜀 (manual)" "$OUT"
  eq "t_open_manual_skip: Status 불변" "$(status_of)" "아카이브 보류"
}

# PATH 에서 gh 만 뺀 PATH 를 만듭니다. gh 가 있는 디렉터리는 gh 를 뺀 링크 디렉터리로 바꿉니다.
nogh_path() {
  local d out="" k=0 e IFS=:
  for d in $PATH; do
    [[ "$d" == "$FAKEBIN" || -z "$d" ]] && continue
    if [[ -e "$d/gh" ]]; then
      k=$((k + 1)); mkdir -p "$TMP/nogh-$k"
      for e in "$d"/*; do [[ "$(basename "$e")" == gh ]] || ln -sf "$e" "$TMP/nogh-$k/" 2>/dev/null; done
      d="$TMP/nogh-$k"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}
NOGH_PATH="$(nogh_path)"

pre_reject_common() {  # <케이스 이름> <원인 조각>
  eq "$1: rc 1" "$RC" "1"
  eq "$1: Status 불변" "$(status_of)" "아카이브 보류"
  eq "$1: 팀 브랜치 ref 없음" "$(team_ref a demo)" ""
  ok "$1: 원인" "$2" "$OUT"
  ok "$1: 재시도 명령" "재시도: bash rd-workflow/scripts/rd pr open --approved" "$OUT"
}

t_open_no_gh() {
  local fh
  reuse_overlay a_pr; setup_fake_gh
  fh="$(git -C "$WT/libs/a" rev-parse --path-format=absolute --git-path FETCH_HEAD)"
  [[ ! -e "$fh" ]] || fail "t_open_no_gh: 준비 — FETCH_HEAD 가 이미 있음"
  RC=0
  ( cd "$WT" && PATH="$NOGH_PATH" bash rd-workflow/scripts/rd pr open --approved ) >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"
  pre_reject_common t_open_no_gh "gh 를 찾을 수 없습니다"
  eq "t_open_no_gh: fetch 하지 않음(FETCH_HEAD 없음)" "$([[ -e "$fh" ]] && echo 있음 || echo 없음)" "없음"
}

t_open_unauth() {
  reuse_overlay a_pr; setup_fake_gh
  : >"$FAKE/auth_fail"
  run_open --approved
  pre_reject_common t_open_unauth "gh auth login"
}

t_open_unsupported_remote() {
  reuse_overlay a_pr; setup_fake_gh
  : >"$FAKE/repo_fail"
  run_open --approved
  pre_reject_common t_open_unsupported_remote "지원하지 않는 원격입니다"
}

echo "== open: 혼합 대상 표 =="

t_open_mixed_modes_table() {
  mk_overlay_with_team mixed; setup_fake_gh
  run_open --approved --approve-push
  eq "t_open_mixed_modes_table: rc 0" "$RC" "0"
  ok "t_open_mixed: 표 a" "$(printf 'libs/a\t%s\tpr\tmain\tdemo' "$W/team-a.git")" "$OUT"
  ok "t_open_mixed: 표 b" "$(printf 'libs/b\t%s\tpush\tmain\t-' "$W/team-b.git")" "$OUT"
  ok "t_open_mixed: 표 c" "$(printf 'libs/c\t%s\tmanual\t-\t-' "$W/team-c.git")" "$OUT"
  ok "t_open_mixed: 결과 a" "libs/a: PR 생성 https://github.com/o/team-a/pull/1" "$OUT"
  ok "t_open_mixed: 결과 b" "libs/b: push 완료 main" "$OUT"
  ok "t_open_mixed: 결과 c" "libs/c: 건너뜀 (manual)" "$OUT"
  eq "t_open_mixed: 팀 b main 전진" "$(team_ref b main)" "$HEAD_B"
  eq "t_open_mixed: Status PR 검토 중" "$(status_of)" "PR 검토 중"
}
want t_open_mixed_modes_table && t_open_mixed_modes_table

echo "== light-check =="

t_light_check_cli() {
  local exp exprc out rc
  reuse_overlay a_pr
  rc=0; out="$( cd "$WT" && bash rd-workflow/scripts/rd pr light-check "$BASE_COMMIT" 2>&1 )" || rc=$?
  exprc=0; exp="$( cd "$WT" && project_root="$WT" bash -c '
    source rd-workflow/scripts/lifecycle/_lifecycle_common.sh; source rd-workflow/scripts/_state_common.sh
    source rd-workflow/scripts/_submodule_common.sh; source rd-workflow/scripts/lifecycle/_tasks_index.sh
    source rd-workflow/scripts/lifecycle/_team_publish_common.sh; tp_light_check "$PWD" "$1"' _ "$BASE_COMMIT" 2>&1 )" || exprc=$?
  eq "t_light_check_cli: 출력이 tp_light_check 와 같음" "$out" "$exp"
  eq "t_light_check_cli: rc 가 tp_light_check 와 같음(3)" "$rc/$exprc" "3/3"
  eq "t_light_check_cli: 상향 문구" "$out" "standard 로 상향 — libs/a (반영 방식 pr, team_publish.light=pr)"
  rc=0; out="$( cd "$WT" && bash rd-workflow/scripts/rd pr light-check 2>&1 )" || rc=$?
  eq "t_light_check_cli: 기본 HEAD → 반영 대상 없음 rc 0" "$out/$rc" "반영 대상 없음/0"
}

echo "== 원격·기록을 바꾸지 않는 케이스 (틀 하나를 이어 씀) =="
want t_open_dry_run && t_open_dry_run
want t_open_requires_approval && t_open_requires_approval
want t_open_no_gh && t_open_no_gh
want t_open_unauth && t_open_unauth
want t_open_unsupported_remote && t_open_unsupported_remote

# PR 모드의 팀 브랜치(branch_prefix 없음 + slug demo)가 대상 브랜치(base demo)와 같으면 push 전에 멈춥니다.
# 설정이 seal 보호 트리에 들어 있어 틀을 따로 만듭니다(약 20초). 이 검사가 없으면 push 가 PR 없이 대상 브랜치를 바꿉니다.
t_open_branch_equals_base() {
  mk_overlay_with_team same_br; setup_fake_gh
  run_open --approved
  pre_reject_common t_open_branch_equals_base "libs/a: 팀 브랜치 demo 가 PR 대상 브랜치와 같습니다"
  ok "t_open_branch_equals_base: 설정 안내" "team_publish.branch_prefix" "$OUT"
  eq "t_open_branch_equals_base: pr create 없음" "$(ghn 'pr create')" "0"
}
want t_open_branch_equals_base && t_open_branch_equals_base
want t_light_check_cli && t_light_check_cli
want t_open_manual_skip && t_open_manual_skip

echo "== check · check --apply =="

# 시간: open 까지 마친 틀(설정마다 한 번)을 복사해 쓰고, 상태를 되돌릴 수 있는 케이스는 한 fixture 에서 이어 씁니다.
# mk_opened <설정 이름> [open 인자...] — seal 틀을 복사해 rd pr open 까지 마친 overlay 를 $W 에, 가짜 gh 상태를 $FAKE 에 둡니다.
mk_opened() {
  local name="$1"; shift
  if [[ ! -d "$TMP/opened-$name" ]]; then
    mk_overlay_with_team "$name"; setup_fake_gh
    run_open --approved "$@"
    [[ "$RC" == 0 ]] || { echo "fixture 생성 실패(open): $name — $OUT" >&2; exit 1; }
    cp -R "$W" "$TMP/opened-$name"; cp "$FAKE/prs" "$TMP/opened-$name.prs"; cp "$FAKE/n" "$TMP/opened-$name.n"
  fi
  rm -rf "${W:?}"
  cp -cR "$TMP/opened-$name" "$W" 2>/dev/null || cp -R "$TMP/opened-$name" "$W"
  setup_fake_gh
  cp "$TMP/opened-$name.prs" "$FAKE/prs"; cp "$TMP/opened-$name.n" "$FAKE/n"
  CUR_TPL="opened-$name"
  SES="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review | tail -1)"
  HEAD_A="$(git -C "$WT" rev-parse HEAD:libs/a)"; HEAD_B="$(git -C "$WT" rev-parse HEAD:libs/b)"; HEAD_C="$(git -C "$WT" rev-parse HEAD:libs/c)"
}

# team_merge <n> <kind> — 팀 저장소 n 에서 팀 브랜치 demo 를 main 에 merge 해 push 하고 merge 결과 OID 를 냅니다.
#   merge    --no-ff merge commit (둘째 부모가 리뷰한 커밋)
#   squash   squash 커밋 하나
#   conflict 팀 main 에 같은 줄을 고친 커밋을 먼저 두고, 충돌을 팀 쪽 값으로 해소한 merge commit
team_merge() {
  local n="$1" kind="$2" c="$TMP/tm-$1"
  rm -rf "$c"; git clone -q "$W/team-$n.git" "$c" 2>/dev/null
  case "$kind" in
    merge)  git -C "$c" merge -q --no-ff -m "Merge pull request" origin/demo >/dev/null 2>&1 ;;
    squash) git -C "$c" merge -q --squash origin/demo >/dev/null 2>&1; git -C "$c" commit -q -m "데모 (#1)" ;;
    conflict)
      printf '%s\nteam\n' "$n" >"$c/f.txt"; git -C "$c" commit -q -am "팀 변경"
      if ! git -C "$c" merge -q --no-ff -m "Merge pull request" origin/demo >/dev/null 2>&1; then
        git -C "$c" checkout -q --ours f.txt; git -C "$c" add f.txt; git -C "$c" commit -q -m "Merge pull request (팀 값으로 해소)"
      fi ;;
  esac
  git -C "$c" push -q origin HEAD:refs/heads/main
  git -C "$c" rev-parse HEAD
}
# pr_set <repo> <state> <headRefOid> <merge-oid> <commits> [<reviewDecision>] [<작성자:의견>] — 가짜 gh 의 그 PR 응답을 정합니다.
pr_set() {
  awk -F'\t' -v OFS='\t' -v r="$1" -v s="$2" -v h="$3" -v m="$4" -v k="$5" -v d="${6:-}" -v v="${7:-}" \
    '$1==r{$3=s; $5=h; $6=m; $7=k; $8=d; $9=v} {print}' "$FAKE/prs" >"$FAKE/prs.t" && mv "$FAKE/prs.t" "$FAKE/prs"
}
# run_check [args...] — 작업 worktree 에서 rd pr check. stdout 은 OUT, stderr 는 ERR, rc 는 RC.
run_check() {
  RC=0
  ( cd "$WT" && bash rd-workflow/scripts/rd pr check "$@" ) >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
gl() { git -C "$WT" rev-parse "HEAD:$1"; }
subhead() { git -C "$WT/$1" rev-parse HEAD; }
ptr_commits() { git -C "$WT" log --format=%s "$1..HEAD" | grep -c '포인터 이동' | tr -d ' '; }
mirror_status() { awk '/^## Status$/{getline; print; exit}' "$WT/CURRENT_TASK.md"; }
# seal_ok — 작업 브랜치 끝 커밋에서 rd_seal_verify (seal 이 만든 한정 해시 마커 기준)
seal_ok() {
  ( cd "$WT" && project_root="$WT" bash -c '
      source rd-workflow/scripts/lifecycle/_lifecycle_common.sh; source rd-workflow/scripts/_state_common.sh
      source rd-workflow/scripts/_submodule_common.sh; source rd-workflow/scripts/hooks/_guard_common.sh
      rd_seal_verify commit HEAD fr/demo' ) >/dev/null 2>&1 && echo ok || echo fail
}
# back_to <commit> — 작업 worktree 를 그 커밋으로 되돌리고 submodule 을 리뷰한 커밋으로 돌립니다(케이스 사이 정리용).
back_to() {
  git -C "$WT" reset -q --hard "$1"
  git -C "$WT/libs/a" checkout -q -f --detach "$HEAD_A"; git -C "$WT/libs/b" checkout -q -f --detach "$HEAD_B"
}
# rec_merged_line <path> <M> — 1단계가 쓰는 기록 줄(state=merged, merged-oid, commits=1)로 워킹트리 기록을 바꿉니다.
rec_merged_line() {
  awk -F'\t' -v OFS='\t' -v p="$1" -v m="$2" '$1==p{$7="merged"; $8=m; $9="1"} {print}' "$WT/$RD_REC" >"$WT/$RD_REC.t" && mv "$WT/$RD_REC.t" "$WT/$RD_REC"
}

# 두 pr 대상(libs/a·b)으로 이어 쓰는 fixture:
#   t_check_states → t_apply_partial → t_apply_interrupted_waits_for_checks → (b merge) →
#   t_apply_interrupted_foreign_change_kept → t_apply_resume_interrupted → t_apply_rollback_on_second_checkout
t_apply_two_targets() {
  local MA MB pre rc0 st0 x
  mk_opened ab_pr
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1
  git -C "$WT/libs/a" fetch -q origin   # 중단 상태를 손으로 만들 때 merge 결과 객체가 필요합니다

  if want t_check_states; then
    pr_set o/team-b OPEN "$HEAD_B" "" 1 CHANGES_REQUESTED "kim:이름을 바꿔 주세요"
    printf 'o/x\tdemo\tOPEN\thttps://github.com/o/x/pull/90\t\no/y\tdemo\tCLOSED\thttps://github.com/o/y/pull/91\t\n' >>"$FAKE/prs"
    printf 'libs/x\to/x\tdemo\tmain\thttps://github.com/o/x/pull/90\t%s\topen\t\t\nlibs/y\to/y\tdemo\tmain\thttps://github.com/o/y/pull/91\t%s\topen\t\t\nlibs/z\to/z\tdemo\tmain\thttps://github.com/o/z/pull/99\t%s\topen\t\t\n' \
      "$HEAD_A" "$HEAD_A" "$HEAD_A" >>"$WT/$RD_REC"
    st0="$(status_of)"
    run_check
    eq "t_check_states: rc 0" "$RC" "0"
    ok "t_check_states: merge 됨" "$(printf 'libs/a\thttps://github.com/o/team-a/pull/1\tmerge 됨\t다른 PR 의 merge 를 기다립니다')" "$OUT"
    ok "t_check_states: 수정 요청" "$(printf 'libs/b\thttps://github.com/o/team-b/pull/2\t수정 요청\tkim: 이름을 바꿔 주세요 / 고치려면 cd '\''%s'\'' && bash rd-workflow/scripts/rd task set-status "구현 중"' "$WT")" "$OUT"
    cmd7="$(printf '%s\n' "$OUT" | grep -o 'bash rd-workflow/scripts/rd task set-status .*' | head -1)"
    eval "set -- ${cmd7#bash }"
    eq "t_check_states: 안내 명령의 set-status 인자 1개" "$# ${4:-}" "4 구현 중"
    ok "t_check_states: 검토 중" "$(printf 'libs/x\thttps://github.com/o/x/pull/90\t검토 중\t-')" "$OUT"
    ok "t_check_states: 닫힘" "$(printf 'libs/y\thttps://github.com/o/y/pull/91\t닫힘\t')" "$OUT"
    ok "t_check_states: 닫힘 선택지" "gh pr reopen https://github.com/o/y/pull/91" "$OUT"
    ok "t_check_states: 조회 실패" "$(printf 'libs/z\thttps://github.com/o/z/pull/99\t조회 실패\tno pull requests found')" "$OUT"
    ok "t_check_states: 반영하지 않음(manual)" "$(printf 'libs/c\t-\t반영하지 않음\t')" "$OUT"
    eq "t_check_states: Status 불변" "$(status_of)" "$st0"
    git -C "$WT" checkout -q HEAD -- "$RD_REC"
    pr_set o/team-b OPEN "$HEAD_B" "" 1
  fi

  pre="$(git -C "$WT" rev-parse HEAD)"
  if want t_apply_partial; then
    run_check --apply
    eq "t_apply_partial: rc 1" "$RC" "1"
    eq "t_apply_partial: 포인터 a 불변" "$(gl libs/a)" "$HEAD_A"
    eq "t_apply_partial: 포인터 b 불변" "$(gl libs/b)" "$HEAD_B"
    eq "t_apply_partial: submodule a HEAD 불변" "$(subhead libs/a)" "$HEAD_A"
    eq "t_apply_partial: Status PR 검토 중" "$(status_of)" "PR 검토 중"
    ok "t_apply_partial: a 줄" "$(printf 'libs/a\thttps://github.com/o/team-a/pull/1\tmerge 됨')" "$OUT"
    ok "t_apply_partial: b 줄" "$(printf 'libs/b\thttps://github.com/o/team-b/pull/2\t검토 중')" "$OUT"
    eq "t_apply_partial: 커밋 없음" "$(git -C "$WT" rev-parse HEAD)" "$pre"
  fi

  # (a) 상태: A 만 merge 결과로 checkout (B 는 리뷰한 커밋, 기록 그대로)
  git -C "$WT/libs/a" checkout -q --detach "$MA"
  if want t_apply_interrupted_waits_for_checks; then
    run_check --apply
    eq "t_apply_interrupted_waits_for_checks: rc 1" "$RC" "1"
    eq "t_apply_interrupted_waits_for_checks: A HEAD 는 merge 결과 그대로(되돌리지 않음)" "$(subhead libs/a)" "$MA"
    no "t_apply_interrupted_waits_for_checks: 되돌림 없음" "흔적을 되돌립니다" "$OUT"
  fi

  team_advance b main
  MB="$(team_merge b merge)"
  pr_set o/team-b MERGED "$HEAD_B" "$MB" 1
  git -C "$WT/libs/b" fetch -q origin

  if want t_apply_interrupted_foreign_change_kept; then
    # (1) 기록 파일의 B 줄 head-oid 를 손으로 바꿈
    awk -F'\t' -v OFS='\t' '$1=="libs/b"{$6="2222222222222222222222222222222222222222"} {print}' "$WT/$RD_REC" >"$WT/$RD_REC.t" && mv "$WT/$RD_REC.t" "$WT/$RD_REC"
    x="$(cat "$WT/$RD_REC")"
    run_check --apply
    eq "t_apply_interrupted_foreign_change_kept(1): rc 1" "$RC" "1"
    eq "t_apply_interrupted_foreign_change_kept(1): 기록 편집 그대로" "$(cat "$WT/$RD_REC")" "$x"
    eq "t_apply_interrupted_foreign_change_kept(1): A HEAD 그대로" "$(subhead libs/a)" "$MA"
    ok "t_apply_interrupted_foreign_change_kept(1): 안내" "이 변경을 정리한 뒤 다시 실행하십시오" "$OUT"
    git -C "$WT" checkout -q HEAD -- "$RD_REC"
    # (2) 무관한 파일을 staged
    echo x >"$WT/extra.txt"; git -C "$WT" add extra.txt
    run_check --apply
    eq "t_apply_interrupted_foreign_change_kept(2): rc 1" "$RC" "1"
    eq "t_apply_interrupted_foreign_change_kept(2): staged 파일 그대로" "$(git -C "$WT" diff --cached --name-only)" "extra.txt"
    eq "t_apply_interrupted_foreign_change_kept(2): A HEAD 그대로" "$(subhead libs/a)" "$MA"
    git -C "$WT" rm -q --cached extra.txt; rm -f "$WT/extra.txt"
  fi

  if want t_apply_resume_interrupted; then
    for x in a b c; do
      git -C "$WT/libs/a" checkout -q --detach "$MA"
      if [[ "$x" != a ]]; then git -C "$WT/libs/b" checkout -q --detach "$MB"; fi
      if [[ "$x" == c ]]; then
        rec_merged_line libs/a "$MA"; rec_merged_line libs/b "$MB"
        git -C "$WT" add libs/a libs/b "$RD_REC"
      fi
      run_check --apply
      eq "t_apply_resume_interrupted($x): rc 0" "$RC" "0"
      ok "t_apply_resume_interrupted($x): 되돌림 안내" "이전 --apply 가 중간에 멈춘 흔적을 되돌립니다" "$OUT"
      eq "t_apply_resume_interrupted($x): 포인터 커밋 1개" "$(ptr_commits "$pre")" "1"
      eq "t_apply_resume_interrupted($x): 포인터 a·b" "$(gl libs/a) $(gl libs/b)" "$MA $MB"
      eq "t_apply_resume_interrupted($x): Status 아카이브 보류" "$(status_of)" "아카이브 보류"
      back_to "$pre"
    done
  fi
  back_to "$pre"

  if want t_apply_rollback_on_second_checkout; then
    # 둘째 submodule(b)의 merge 결과는 새 파일(other.txt)을 더합니다. 그 디렉터리를 쓰기 금지로 막습니다.
    chmod a-w "$WT/libs/b"
    eq "t_apply_rollback_on_second_checkout: 준비 — status 깨끗" "$(git -C "$WT" status --porcelain)" ""
    run_check --apply; rc0="$RC"
    chmod u+w "$WT/libs/b"
    eq "t_apply_rollback_on_second_checkout: rc 1" "$rc0" "1"
    ok "t_apply_rollback_on_second_checkout: 첫째 되돌림 줄" "되돌림: libs/a → $HEAD_A" "$OUT"
    ok "t_apply_rollback_on_second_checkout: 둘째 checkout 실패" "Permission denied" "$OUT"
    eq "t_apply_rollback_on_second_checkout: 첫째 HEAD" "$(subhead libs/a)" "$HEAD_A"
    eq "t_apply_rollback_on_second_checkout: 둘째 HEAD" "$(subhead libs/b)" "$HEAD_B"
    eq "t_apply_rollback_on_second_checkout: 상위 status 비어 있음" "$(git -C "$WT" status --porcelain)" ""
    eq "t_apply_rollback_on_second_checkout: 기록 = HEAD" "$(cat "$WT/$RD_REC")" "$(git -C "$WT" show "HEAD:$RD_REC")"
    run_check --apply
    eq "t_apply_rollback_on_second_checkout: 권한 복구 뒤 rc 0" "$RC" "0"
  fi
}
if want t_check_states || want t_apply_partial || want t_apply_interrupted_waits_for_checks \
   || want t_apply_interrupted_foreign_change_kept || want t_apply_resume_interrupted || want t_apply_rollback_on_second_checkout; then
  t_apply_two_targets
fi

# libs/a 하나(merge commit)로 이어 쓰는 fixture:
#   t_apply_dirty_index_refused → t_apply_rollback_on_commit_failure → t_apply_gitlink_not_head_refused →
#   t_apply_merge_commit(재실행) → t_apply_pointer_moved_by_hand
t_apply_one_target() {
  local MA pre x hp sub0 rec0
  mk_opened a_pr
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1
  pre="$(git -C "$WT" rev-parse HEAD)"

  if want t_apply_dirty_index_refused; then
    echo x >"$WT/extra.txt"; git -C "$WT" add extra.txt
    rec0="$(cat "$WT/$RD_REC")"
    run_check --apply
    eq "t_apply_dirty_index_refused: rc 1" "$RC" "1"
    eq "t_apply_dirty_index_refused: 상위 HEAD 불변" "$(git -C "$WT" rev-parse HEAD)" "$pre"
    eq "t_apply_dirty_index_refused: gitlink 불변" "$(gl libs/a)" "$HEAD_A"
    eq "t_apply_dirty_index_refused: submodule HEAD 불변" "$(subhead libs/a)" "$HEAD_A"
    eq "t_apply_dirty_index_refused: 기록 불변" "$(cat "$WT/$RD_REC")" "$rec0"
    eq "t_apply_dirty_index_refused: staged 파일 그대로" "$(git -C "$WT" diff --cached --name-only)" "extra.txt"
    git -C "$WT" rm -q --cached extra.txt; rm -f "$WT/extra.txt"
  fi

  if want t_apply_rollback_on_commit_failure || want t_apply_merge_commit; then
    hp="$(git -C "$WT" config core.hooksPath || true)"
    mkdir -p "$TMP/hooks-fail"; printf '#!/bin/sh\necho "pre-commit: 거부" >&2\nexit 1\n' >"$TMP/hooks-fail/pre-commit"; chmod +x "$TMP/hooks-fail/pre-commit"
    git -C "$WT" config core.hooksPath "$TMP/hooks-fail"
    run_check --apply
    if [[ -n "$hp" ]]; then git -C "$WT" config core.hooksPath "$hp"; else git -C "$WT" config --unset core.hooksPath; fi
    eq "t_apply_rollback_on_commit_failure: rc 1" "$RC" "1"
    eq "t_apply_rollback_on_commit_failure: 상위 status 비어 있음" "$(git -C "$WT" status --porcelain)" ""
    eq "t_apply_rollback_on_commit_failure: submodule HEAD" "$(subhead libs/a)" "$HEAD_A"
    eq "t_apply_rollback_on_commit_failure: 상위 HEAD 불변" "$(git -C "$WT" rev-parse HEAD)" "$pre"
  fi

  if want t_apply_rollback_keeps_foreign_edit; then
    # 포인터 커밋 직전 hook 이 submodule 안쪽을 편집(tracked 수정 + staged 새 파일)하고 커밋을 거부합니다.
    # 이 편집은 --apply 가 만든 것이 아니므로 되돌림이 지우면 안 됩니다.
    hp="$(git -C "$WT" config core.hooksPath || true)"
    mkdir -p "$TMP/hooks-edit"
    printf '#!/bin/sh\nprintf "USER_EDIT\\n" >> libs/a/f.txt\nprintf "new\\n" > libs/a/user-new.txt\nenv -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE git -C libs/a add user-new.txt\necho "pre-commit: 거부" >&2\nexit 1\n' >"$TMP/hooks-edit/pre-commit"
    chmod +x "$TMP/hooks-edit/pre-commit"
    git -C "$WT" config core.hooksPath "$TMP/hooks-edit"
    run_check --apply
    if [[ -n "$hp" ]]; then git -C "$WT" config core.hooksPath "$hp"; else git -C "$WT" config --unset core.hooksPath; fi
    eq "t_apply_rollback_keeps_foreign_edit: rc 1" "$RC" "1"
    ok "t_apply_rollback_keeps_foreign_edit: tracked 편집 보존" "USER_EDIT" "$(cat "$WT/libs/a/f.txt")"
    eq "t_apply_rollback_keeps_foreign_edit: staged 새 파일 보존" "$(git -C "$WT/libs/a" diff --cached --name-only)" "user-new.txt"
    ok "t_apply_rollback_keeps_foreign_edit: 남은 상태 안내" "안쪽 변경은 이 명령이 만들지 않았을 수 있어 지우지 않았습니다" "$OUT"
    eq "t_apply_rollback_keeps_foreign_edit: 상위 HEAD 불변" "$(git -C "$WT" rev-parse HEAD)" "$pre"
    # 다음 케이스를 위해 정리합니다.
    git -C "$WT/libs/a" reset -q; rm -f "$WT/libs/a/user-new.txt"
    git -C "$WT/libs/a" checkout -q -f --detach "$HEAD_A"
    git -C "$WT" reset -q; git -C "$WT" checkout -q HEAD -- "$RD_REC"
  fi

  if want t_apply_rollback_keeps_foreign_head; then
    # 포인터 커밋 직전 hook 이 submodule 에 새 커밋 U 를 만들고(작업 폴더는 깨끗) 커밋을 거부합니다.
    # U 는 --apply 가 옮긴 커밋(H·M)이 아니므로 되돌림이 HEAD 를 H 로 옮기면 안 됩니다.
    hp="$(git -C "$WT" config core.hooksPath || true)"
    mkdir -p "$TMP/hooks-head"
    printf '#!/bin/sh\nunset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE\nprintf "u\\n" > libs/a/user-commit.txt\ngit -C libs/a add user-commit.txt\ngit -C libs/a -c user.name=t -c user.email=t@t commit -q -m U\ngit -C libs/a rev-parse HEAD > "%s"\necho "pre-commit: 거부" >&2\nexit 1\n' "$TMP/u-oid" >"$TMP/hooks-head/pre-commit"
    chmod +x "$TMP/hooks-head/pre-commit"
    git -C "$WT" config core.hooksPath "$TMP/hooks-head"
    run_check --apply
    if [[ -n "$hp" ]]; then git -C "$WT" config core.hooksPath "$hp"; else git -C "$WT" config --unset core.hooksPath; fi
    eq "t_apply_rollback_keeps_foreign_head: rc 1" "$RC" "1"
    eq "t_apply_rollback_keeps_foreign_head: submodule HEAD 는 U 그대로" "$(subhead libs/a)" "$(cat "$TMP/u-oid" 2>/dev/null)"
    ok "t_apply_rollback_keeps_foreign_head: U 의 파일 보존" "u" "$(cat "$WT/libs/a/user-commit.txt" 2>/dev/null)"
    ok "t_apply_rollback_keeps_foreign_head: 안내" "도 merge 결과" "$OUT"
    no "t_apply_rollback_keeps_foreign_head: 되돌렸다고 하지 않음" "되돌렸습니다 —" "$OUT"
    eq "t_apply_rollback_keeps_foreign_head: 상위 HEAD 불변" "$(git -C "$WT" rev-parse HEAD)" "$pre"
    git -C "$WT/libs/a" checkout -q -f --detach "$HEAD_A"
    git -C "$WT" reset -q; git -C "$WT" checkout -q HEAD -- "$RD_REC"
  fi

  if want t_apply_gitlink_not_head_refused; then
    # 리뷰한 커밋과 트리가 같은 다른 커밋 X 로 gitlink 를 옮겨 커밋합니다(seal 은 내용 기준이라 그대로 유효).
    git -C "$WT/libs/a" commit -q --amend -m "다른 메시지"
    git -C "$WT" add libs/a; git -C "$WT" commit -q -m "gitlink 를 X 로"
    x="$(git -C "$WT" rev-parse HEAD)"
    run_check --apply
    eq "t_apply_gitlink_not_head_refused: rc 1" "$RC" "1"
    eq "t_apply_gitlink_not_head_refused: 상위 HEAD 불변" "$(git -C "$WT" rev-parse HEAD)" "$x"
    eq "t_apply_gitlink_not_head_refused: gitlink 불변" "$(gl libs/a)" "$(subhead libs/a)"
    ok "t_apply_gitlink_not_head_refused: 원인" "진행 상태를 판정할 수 없어 아무것도 바꾸지 않았습니다" "$OUT"
    back_to "$pre"
  fi

  if want t_apply_merge_commit || want t_apply_pointer_moved_by_hand; then
    run_check --apply
    eq "t_apply_merge_commit: rc 0" "$RC" "0"
    eq "t_apply_merge_commit: 포인터가 merge commit" "$(gl libs/a)" "$MA"
    eq "t_apply_merge_commit: Status 아카이브 보류" "$(status_of)" "아카이브 보류"
    eq "t_apply_merge_commit: 기록 merged" "$(rec libs/a 7)/$(rec libs/a 8)" "merged/$MA"
    eq "t_apply_merge_commit: worktree 깨끗" "$(git -C "$WT" status --porcelain)" ""
    eq "t_apply_merge_commit: rd_seal_verify 통과" "$(seal_ok)" "ok"
    ok "t_apply_merge_commit: 발행 안내" "발행 준비 완료 — bash rd-workflow/scripts/rd publish request" "$OUT"

    # t_apply_pointer_moved_by_hand — 사람이 gitlink 를 다른 커밋으로 옮겨 커밋하면 seal 이 깨집니다.
    echo hand >>"$WT/libs/a/f.txt"; git -C "$WT/libs/a" commit -q -am "손 편집"
    git -C "$WT" add libs/a; git -C "$WT" commit -q -m "포인터를 손으로 옮김"
    eq "t_apply_pointer_moved_by_hand: rd_seal_verify 실패" "$(seal_ok)" "fail"
  fi
}
if want t_apply_dirty_index_refused || want t_apply_rollback_on_commit_failure || want t_apply_rollback_keeps_foreign_edit || want t_apply_rollback_keeps_foreign_head \
   || want t_apply_gitlink_not_head_refused \
   || want t_apply_merge_commit || want t_apply_pointer_moved_by_hand; then
  t_apply_one_target
fi

# 앞선 리뷰 범위에서 올린 PR 기록(libs/a, merge 됨)을 둔 채, 일반 파일만 바꾼 새 범위로 다시 리뷰·seal 한 경우.
# 없으면 새는 실수: --apply 가 새 범위에 없는 libs/a 를 남은 기록으로 옮기고 포인터 커밋까지 만듭니다.
t_apply_record_outside_scope() {
  local c=t_apply_record_outside_scope MA base ses pre
  mk_opened a_pr
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1
  base="$(git -C "$WT" rev-parse HEAD)"
  ( cd "$WT" && bash rd-workflow/scripts/rd task set-status "구현 중" --force ) >/dev/null 2>&1
  echo followup >"$WT/followup.txt"; git -C "$WT" add -A; git -C "$WT" commit -q -m "후속 변경"
  ( cd "$WT" && bash rd-workflow/scripts/prepare_review_pipeline.sh diff --base "$base" ) >"$TMP/prep.log" 2>&1 || true
  ses="$(ls -d "$WT"/rd-workflow-workspace/handoffs/review_pipeline/*final-diff-review | tail -1)"
  eq "$c: 준비 — 새 리뷰 세션" "$([[ "$ses" != "$SES" ]] && echo 새 || echo 같음)" "새"
  _author_turn "$ses"
  seal_and_hold "$WT" "$ses" || { fail "$c: 준비 — seal 실패"; return; }
  ( cd "$WT" && bash rd-workflow/scripts/rd task set-status "PR 검토 중" --force ) >/dev/null 2>&1
  git -C "$WT" add -A; git -C "$WT" commit -q -m "PR 검토 중"
  eq "$c: 준비 — libs/a PR 기록이 남아 있음" "$(rec libs/a 5)" "https://github.com/o/team-a/pull/1"
  pre="$(git -C "$WT" rev-parse HEAD)"
  run_check --apply
  eq "$c: rc 1" "$RC" "1"
  ok "$c: 범위 밖 기록 안내" "PR 기록의 경로가 이번 반영 대상(리뷰한 범위)에 없습니다" "$OUT"
  ok "$c: 경로·PR URL" "libs/a (https://github.com/o/team-a/pull/1)" "$OUT"
  eq "$c: gitlink 불변" "$(gl libs/a)" "$HEAD_A"
  eq "$c: 상위 HEAD 불변" "$(git -C "$WT" rev-parse HEAD)" "$pre"
  # 안내한 첫 행동(기록 줄을 지우고 커밋)을 따르면 --apply 가 그 경로를 옮기지 않고 끝납니다.
  awk -F'\t' '$1 != "libs/a"' "$WT/$RD_REC" >"$TMP/rec.t" && cat "$TMP/rec.t" >"$WT/$RD_REC"
  git -C "$WT" add -A; git -C "$WT" commit -q -m "libs/a PR 기록 정리"
  run_check --apply
  eq "$c: 기록 정리 뒤 rc 0·gitlink 불변" "$RC/$(gl libs/a)" "0/$HEAD_A"
  rm -rf "${W:?}"; CUR_TPL=""
}
want t_apply_record_outside_scope && t_apply_record_outside_scope

# Status 커밋 실패 뒤 재개 → 미러만 어긋난 상태의 재개
t_apply_status_resume() {
  local MA pre hp
  mk_opened a_pr
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1
  pre="$(git -C "$WT" rev-parse HEAD)"
  hp="$(git -C "$WT" config core.hooksPath || true)"
  mkdir -p "$TMP/hooks-ts"
  printf '#!/bin/sh\ngit diff --cached --name-only | grep -q "rd-workflow-workspace/.lifecycle/task-state" && { echo "pre-commit: task-state 커밋 거부" >&2; exit 1; }\nexit 0\n' >"$TMP/hooks-ts/pre-commit"
  chmod +x "$TMP/hooks-ts/pre-commit"
  git -C "$WT" config core.hooksPath "$TMP/hooks-ts"
  run_check --apply
  if [[ -n "$hp" ]]; then git -C "$WT" config core.hooksPath "$hp"; else git -C "$WT" config --unset core.hooksPath; fi
  eq "t_apply_resume_after_status_commit_failure: rc 1" "$RC" "1"
  ok "t_apply_resume_after_status_commit_failure: 안내" "포인터 이동 완료 — 다시 rd pr check --apply 를 실행하면 Status 정리부터 이어 갑니다" "$OUT"
  eq "t_apply_resume_after_status_commit_failure: Status 아카이브 보류" "$(status_of)" "아카이브 보류"
  eq "t_apply_resume_after_status_commit_failure: task-state 미커밋" \
    "$(git -C "$WT" status --porcelain -- rd-workflow-workspace/.lifecycle/task-state | cut -c4-)" "rd-workflow-workspace/.lifecycle/task-state"
  eq "t_apply_resume_after_status_commit_failure: 포인터 커밋 1" "$(ptr_commits "$pre")" "1"
  run_check --apply
  eq "t_apply_resume_after_status_commit_failure: 재실행 rc 0" "$RC" "0"
  eq "t_apply_resume_after_status_commit_failure: 포인터 커밋 수 그대로" "$(ptr_commits "$pre")" "1"
  eq "t_apply_resume_after_status_commit_failure: Status 커밋 1" "$(git -C "$WT" log --format=%s "$pre..HEAD" | grep -c 'Status 아카이브 보류' | tr -d ' ')" "1"
  eq "t_apply_resume_after_status_commit_failure: worktree 깨끗" "$(git -C "$WT" status --porcelain)" ""
  pre="$(git -C "$WT" rev-parse HEAD)"
  run_check --apply
  eq "t_apply_resume_after_status_commit_failure: 셋째 실행 rc 0" "$RC" "0"
  eq "t_apply_resume_after_status_commit_failure: 셋째 실행 새 커밋 0" "$(git -C "$WT" rev-parse HEAD)" "$pre"

  if want t_apply_resume_mirror_only; then
    # 권위(task-state)는 아카이브 보류, 미러(CURRENT_TASK.md)만 PR 검토 중 — 미러 쓰기 실패와 같은 결과
    awk '/^## Status$/{print; getline; print "PR 검토 중"; next} {print}' "$WT/CURRENT_TASK.md" >"$WT/CT.t" && mv "$WT/CT.t" "$WT/CURRENT_TASK.md"
    eq "t_apply_resume_mirror_only: 준비 — 미러 PR 검토 중" "$(mirror_status)" "PR 검토 중"
    run_check --apply
    eq "t_apply_resume_mirror_only: rc 0" "$RC" "0"
    eq "t_apply_resume_mirror_only: 미러 아카이브 보류" "$(mirror_status)" "아카이브 보류"
    eq "t_apply_resume_mirror_only: worktree 깨끗" "$(git -C "$WT" status --porcelain)" ""
  fi
}
if want t_apply_resume_after_status_commit_failure || want t_apply_resume_mirror_only; then t_apply_status_resume; fi

# 충돌 해소 merge → head 불일치 (같은 fixture, 바꾸는 것 없음)
t_apply_preserve_refused() {
  local MA pre rec0
  mk_opened a_pr
  MA="$(team_merge a conflict)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1
  pre="$(git -C "$WT" rev-parse HEAD)"; rec0="$(cat "$WT/$RD_REC")"
  if want t_apply_conflict_resolution_blocks; then
    run_check --apply
    eq "t_apply_conflict_resolution_blocks: rc 1" "$RC" "1"
    ok "t_apply_conflict_resolution_blocks: 원인" "merge 결과가 리뷰한 변경과 다릅니다" "$OUT"
    eq "t_apply_conflict_resolution_blocks: 포인터 불변" "$(gl libs/a)/$(subhead libs/a)" "$HEAD_A/$HEAD_A"
    eq "t_apply_conflict_resolution_blocks: 기록 불변" "$(cat "$WT/$RD_REC")" "$rec0"
    eq "t_apply_conflict_resolution_blocks: Status 불변" "$(status_of)" "PR 검토 중"
    eq "t_apply_conflict_resolution_blocks: 커밋 없음" "$(git -C "$WT" rev-parse HEAD)" "$pre"
  fi
  if want t_apply_head_mismatch; then
    pr_set o/team-a MERGED 3333333333333333333333333333333333333333 "$MA" 1
    run_check --apply
    eq "t_apply_head_mismatch: rc 1" "$RC" "1"
    ok "t_apply_head_mismatch: 원인" "merge 된 PR 에 리뷰 뒤 더해진 커밋이 있습니다" "$OUT"
    eq "t_apply_head_mismatch: 포인터 불변" "$(gl libs/a)" "$HEAD_A"
    eq "t_apply_head_mismatch: Status 불변" "$(status_of)" "PR 검토 중"
  fi
}
if want t_apply_conflict_resolution_blocks || want t_apply_head_mismatch; then t_apply_preserve_refused; fi

t_apply_squash_team_ahead_publish() {
  local MA
  mk_opened a_pr
  team_advance a main
  MA="$(team_merge a squash)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1
  eq "t_apply_squash_team_ahead_publish: 준비 — squash 는 부모 하나" "$(git --git-dir="$W/team-a.git" rev-list --parents -n1 "$MA" | wc -w | tr -d ' ')" "2"
  run_check --apply
  eq "t_apply_squash_team_ahead_publish: apply rc 0" "$RC" "0"
  eq "t_apply_squash_team_ahead_publish: 포인터 squash 커밋" "$(gl libs/a)" "$MA"
  # 발행 큐: 호출 세션을 색인에 등록(생존 확인은 판정 불가로 경고만)하고 request → next → run.
  ( cd "$WT" && project_root="$WT" bash -c 'source rd-workflow/scripts/lifecycle/publish_queue.sh; tasks_index_upsert demo launch=ok caller-backend=none caller-id=t:1' ) >/dev/null 2>&1
  RC=0; OUT="$( cd "$WT" && bash rd-workflow/scripts/rd publish request 2>&1 )" || RC=$?
  eq "t_apply_squash_team_ahead_publish: publish request rc 0" "$RC" "0"
  RC=0; OUT="$( cd "$WT" && bash rd-workflow/scripts/rd publish next 2>&1 )" || RC=$?
  eq "t_apply_squash_team_ahead_publish: publish next rc 0" "$RC" "0"
  # run 은 발행 진입 때 ps 로 프로세스 그룹을 기록하고, ps 가 실패하면 진입을 거부합니다(제품의 안전한 쪽 동작).
  # ps 를 쓸 수 없는 환경(샌드박스 등)에서는 run 과 발행 결과 단언을 건너뛰고 표식을 냅니다(test_publish_queue 의 PQ_PS_OK 와 같은 시험).
  if ! ps -o pgid= -p $$ >/dev/null 2>&1; then
    printf 'env-skip: test_team_publish t_apply_squash_team_ahead_publish(publish run·발행 결과) — ps 를 쓸 수 없는 환경(프로세스 그룹 확인 불가)\n' >&2
    return 0
  fi
  RC=0; OUT="$( cd "$WT" && bash rd-workflow/scripts/rd publish run 2>&1 )" || RC=$?
  eq "t_apply_squash_team_ahead_publish: publish run rc 0" "$RC" "0"
  [[ "$RC" == 0 ]] || printf '%s\n' "$OUT" | tail -15 >&2
  eq "t_apply_squash_team_ahead_publish: 발행된 main 의 gitlink" "$(git -C "$R" rev-parse main:libs/a 2>/dev/null)" "$MA"
  eq "t_apply_squash_team_ahead_publish: 발행된 main 에 기록 파일 없음" \
    "$(git -C "$R" cat-file -e "main:$RD_REC" 2>/dev/null && echo 있음 || echo 없음)" "없음"
}
want t_apply_squash_team_ahead_publish && t_apply_squash_team_ahead_publish

t_apply_mixed_modes() {
  local MA pre gb gc rb
  mk_opened mixed --approve-push
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1
  pre="$(git -C "$WT" rev-parse HEAD)"; gb="$(gl libs/b)"; gc="$(gl libs/c)"; rb="$(awk -F'\t' '$1=="libs/b"' "$WT/$RD_REC")"
  eq "t_apply_mixed_modes: 준비 — push 기록 state=pushed" "$(rec libs/b 7)" "pushed"
  run_check --apply
  eq "t_apply_mixed_modes: rc 0" "$RC" "0"
  eq "t_apply_mixed_modes: pr 포인터만 merge 결과" "$(gl libs/a)" "$MA"
  eq "t_apply_mixed_modes: push gitlink 불변" "$(gl libs/b)" "$gb"
  eq "t_apply_mixed_modes: manual gitlink 불변" "$(gl libs/c)" "$gc"
  eq "t_apply_mixed_modes: push 기록 줄 불변" "$(awk -F'\t' '$1=="libs/b"' "$WT/$RD_REC")" "$rb"
  pre="$(git -C "$WT" rev-parse HEAD)"
  run_check --apply
  eq "t_apply_mixed_modes: 재실행 rc 0" "$RC" "0"
  eq "t_apply_mixed_modes: 재실행 새 커밋 0" "$(git -C "$WT" rev-parse HEAD)" "$pre"
}
want t_apply_mixed_modes && t_apply_mixed_modes

echo "== check --task · no-fr 수용 =="

# 다른 작업 root(기본 체크아웃 R)에서 --task demo 로 부르면 demo worktree 의 기록을 판정합니다.
# 없으면 새는 실수: rd 가 export 한 project_root 를 위임받은 자식이 물려받아 호출한 쪽(R) 작업을 판정합니다.
t_check_task_other_root() {
  mk_opened ab_pr
  RC=0
  ( cd "$R" && bash rd-workflow/scripts/rd pr check --task demo ) >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"
  eq "t_check_task_other_root: rc 0" "$RC" "0"
  ok "t_check_task_other_root: demo 의 기록 줄(libs/a)" "$(printf 'libs/a\thttps://github.com/o/team-a/pull/1')" "$OUT"
  no "t_check_task_other_root: 호출한 쪽의 빈 기록이 아님" "PR 기록 없음" "$OUT"
}
want t_check_task_other_root && t_check_task_other_root

# 기본 체크아웃(R)에서 --task demo 로 조회한 표의 명령이 `cd '<demo worktree>' &&` 로 시작하고, 그 명령을 R 의 셸에서
# 그대로 실행하면 demo 만 바뀝니다. R 은 fr 브랜치 없는 진행 중 작업(PR 검토 중)으로 두어, 접두가 빠진 명령이면
# R 의 작업이 대신 바뀌도록 합니다(R 이 작업 없는 위치면 자동 선택 거부로 멈춰 차이가 보이지 않습니다).
# 없으면 새는 실수: 다른 worktree 에서 조회한 표의 명령을 복사하면 호출한 쪽 작업이 바뀜.
t_check_rows_cd() {
  local c=t_check_rows_cd rts="$R/rd-workflow-workspace/.lifecycle/task-state" sv="$TMP/rows-cd-save" line cmd r_before MA MB
  mk_opened ab_pr
  mkdir -p "$sv"; cp "$rts" "$sv/task-state"; cp "$R/CURRENT_TASK.md" "$sv/CURRENT_TASK.md"
  awk -F= 'BEGIN{OFS="="} $1=="fr-branch"{print "fr-branch=null"; next} $1=="status"{print "status=PR 검토 중"; next} {print}' \
    "$sv/task-state" >"$rts"
  r_before="$(cksum <"$rts")/$(cksum <"$R/CURRENT_TASK.md")"
  pr_set o/team-b OPEN "$HEAD_B" "" 1 CHANGES_REQUESTED "kim:이름을 바꿔 주세요"
  RC=0; ( cd "$R" && bash rd-workflow/scripts/rd pr check --task demo ) >"$TMP/out" 2>"$TMP/err" || RC=$?; OUT="$(cat "$TMP/out")"
  eq "$c: 수정 요청 조회 rc 0" "$RC" "0"
  line="$(printf '%s\n' "$OUT" | grep "$(printf '\t수정 요청\t')")"
  ok "$c: 수정 요청 줄의 명령" "/ 고치려면 cd '$WT' && bash rd-workflow/scripts/rd task set-status \"구현 중\"" "$line"
  cmd="${line#*/ 고치려면 }"
  RC=0; ( cd "$R" && eval "$cmd" ) >"$TMP/out" 2>&1 || RC=$?
  eq "$c: 표의 명령 rc 0" "$RC" "0"
  eq "$c: 조회한 작업(demo) Status 구현 중" "$(status_of)" "구현 중"
  eq "$c: 호출한 쪽(R) task-state·CURRENT_TASK.md 불변" "$(cksum <"$rts")/$(cksum <"$R/CURRENT_TASK.md")" "$r_before"
  # merge 됨 줄 — 실행은 기존 apply 테스트가 맡으므로 문자열만 봅니다.
  MA="$(team_merge a merge)"; MB="$(team_merge b merge)"
  pr_set o/team-a MERGED "$HEAD_A" "$MA" 1; pr_set o/team-b MERGED "$HEAD_B" "$MB" 1
  RC=0; ( cd "$R" && bash rd-workflow/scripts/rd pr check --task demo ) >"$TMP/out" 2>"$TMP/err" || RC=$?; OUT="$(cat "$TMP/out")"
  ok "$c: merge 됨 줄의 명령" "$(printf 'merge 됨\tcd '\''%s'\'' && bash rd-workflow/scripts/rd pr check --apply' "$WT")" "$OUT"
  cp "$sv/task-state" "$rts"; cp "$sv/CURRENT_TASK.md" "$R/CURRENT_TASK.md"
  rm -rf "${W:?}" "$sv"; CUR_TPL=""
}
want t_check_rows_cd && t_check_rows_cd

# ---------------------------------------------------------------------------
# no-fr 작업(fr-branch=null, 기본 브랜치에서 작업)의 open·--apply (spec D3-1, AC4·AC10)
# ---------------------------------------------------------------------------
# mk_nofr — no-fr 틀(기본 브랜치 main 에서 seal·아카이브 보류)을 $W 에 새로 복사합니다(처음 부를 때 틀을 만듭니다).
#   전역: R NF_HEAD(기본 브랜치 끝) NF_A(리뷰한 libs/a gitlink)
mk_nofr() {
  if [[ ! -d "$TMP/tpl-nofr" ]]; then
    _build_template nofr || { echo "fixture 생성 실패: nofr" >&2; exit 1; }
  fi
  rm -rf "${W:?}"
  cp -cR "$TMP/tpl-nofr" "$W" 2>/dev/null || cp -R "$TMP/tpl-nofr" "$W"
  CUR_TPL="nofr"
  NF_HEAD="$(git -C "$R" rev-parse HEAD)"; NF_A="$(git -C "$R" rev-parse HEAD:libs/a)"
}
# run_open_r / run_check_r [args...] — 기본 체크아웃(R)에서 rd pr open·check. stdout OUT, stderr ERR, rc RC.
run_open_r() {
  RC=0
  ( cd "$R" && bash rd-workflow/scripts/rd pr open "$@" ) >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
run_check_r() {
  RC=0
  ( cd "$R" && bash rd-workflow/scripts/rd pr check "$@" ) >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
nf_drop_line() { awk -v re="$1" '$0 !~ re' "$2" >"$2.t" && mv "$2.t" "$2"; }  # <정규식> <파일>
nf_status() { awk -F= '$1=="status"{sub(/^[^=]+=/,""); print}' "$R/rd-workflow-workspace/.lifecycle/task-state"; }
# nf_cfg_commit <archive_publish 값> — R 의 workflow.json 에 archive_publish 를 넣어 커밋합니다(seal 판정 전에 멈추는지 보려는 것).
nf_cfg_commit() {
  python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["archive_publish"]=sys.argv[2]; open(p,"w").write(json.dumps(d)+"\n")' \
    "$R/rd-workflow/config/workflow.json" "$1"
  git -C "$R" commit -q -am "archive_publish=$1"
}
# nf_open_unchanged <케이스> <기대 HEAD> — open 거부 공통 단언: 기록 파일·팀 브랜치·gh 호출이 없고 HEAD·Status 가 그대로.
nf_open_unchanged() {
  eq "$1: 기록 파일 없음" "$([[ -e "$R/$RD_REC" ]] && echo 있음 || echo 없음)" "없음"
  eq "$1: 팀 브랜치 없음" "$(team_ref a demo)" ""
  eq "$1: gh 호출 없음" "$(wc -l <"$FAKE/log" | tr -d ' ')" "0"
  eq "$1: 기본 브랜치 커밋 불변" "$(git -C "$R" rev-parse HEAD)" "$2"
  eq "$1: Status 불변" "$(nf_status)" "아카이브 보류"
}

# no-fr 에서 rd pr open 이 PR 을 만들고 기록 커밋을 기본 브랜치에 남기고, merge 뒤 --apply 가 포인터·Status 커밋을 남깁니다.
# main·master 커밋을 막는 pre-commit hook(lifecycle/README.md 「pre-commit·commit-msg hook 우회」)을 둔 채 돌립니다.
# 없으면 새는 실수: no-fr 거부가 남거나, 기본 브랜치의 lifecycle 커밋이 그 hook 에 막혀 반영이 중간에 멈춥니다.
t_open_nofr_accepted() {
  local MA
  mk_nofr; setup_fake_gh
  printf '#!/bin/sh\ncase "$(git rev-parse --abbrev-ref HEAD)" in main|master) echo "main 직접 커밋 금지" >&2; exit 1 ;; esac\n' >"$R/.git/hooks/pre-commit"
  chmod +x "$R/.git/hooks/pre-commit"
  run_open_r --approved
  eq "t_open_nofr_accepted: rc 0" "$RC" "0"
  eq "t_open_nofr_accepted: pr create 1회" "$(ghn 'pr create --repo o/team-a --base main --head demo')" "1"
  eq "t_open_nofr_accepted: 팀 브랜치가 리뷰한 커밋" "$(team_ref a demo)" "$NF_A"
  eq "t_open_nofr_accepted: 기록 커밋이 기본 브랜치에" "$(git -C "$R" log -1 --format=%s main)" "chore(lifecycle): demo 팀 저장소 반영 기록"
  eq "t_open_nofr_accepted: 기록 커밋의 부모가 이전 HEAD" "$(git -C "$R" rev-parse main~1)" "$NF_HEAD"
  eq "t_open_nofr_accepted: Status PR 검토 중" "$(nf_status)" "PR 검토 중"
  ok "t_open_nofr_accepted: 다음 행동 줄" "다음: PR merge 를 기다립니다 — bash rd-workflow/scripts/rd pr check" "$OUT"
  ok "t_open_nofr_accepted: hook 우회 안내" "pre-commit·commit-msg hook 을 건너뛰고 커밋했습니다" "$OUT"
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$NF_A" "$MA" 1
  run_check_r --apply
  eq "t_open_nofr_accepted: apply rc 0" "$RC" "0"
  eq "t_open_nofr_accepted: apply 포인터가 기본 브랜치에" "$(git -C "$R" rev-parse main:libs/a)" "$MA"
  eq "t_open_nofr_accepted: apply 뒤 Status 아카이브 보류(커밋됨)" \
    "$(git -C "$R" show main:rd-workflow-workspace/.lifecycle/task-state | awk -F= '$1=="status"{print $2}')" "아카이브 보류"
  rm -f "$R/.git/hooks/pre-commit"
}

# no-fr open 거부 4건. 각 거부는 기록 파일·팀 원격·HEAD·Status 를 바꾸지 않습니다.
# 없으면 새는 실수: 기본 브랜치가 아닌 체크아웃·archive_publish=pr·설정 오타·기준점 없음 상태에서 팀 PR·기록 커밋을 만든 뒤에야
# archive 가 발행을 거부합니다.
t_open_nofr_refusals() {
  local c pre
  # (1) 다른 브랜치 체크아웃 → rc 1, git switch 안내
  c=t_open_nofr_other_branch
  mk_nofr; setup_fake_gh
  git -C "$R" switch -q -c side
  run_open_r --approved
  eq "$c: rc 1" "$RC" "1"
  ok "$c: git switch 안내" "git switch main 뒤 다시 실행하십시오" "$OUT"
  nf_open_unchanged "$c" "$NF_HEAD"
  eq "$c: 브랜치 그대로" "$(git -C "$R" symbolic-ref --short HEAD)" "side"
  git -C "$R" switch -q main

  # (2) archive_publish=pr → rc 2, promote 안내
  c=t_open_nofr_archive_pr
  setup_fake_gh
  nf_cfg_commit pr; pre="$(git -C "$R" rev-parse HEAD)"
  run_open_r --approved
  eq "$c: rc 2" "$RC" "2"
  ok "$c: promote 안내" "archive_publish=pr 는 fr 브랜치 작업만 지원합니다 — promote.sh 로 작업을 시작하십시오" "$OUT"
  nf_open_unchanged "$c" "$pre"

  # (3) AC10: archive_publish 오타 → rc 2, dpr_archive_mode 원인 줄
  c=t_open_nofr_archive_typo
  git -C "$R" reset -q --hard "$NF_HEAD"; setup_fake_gh
  nf_cfg_commit pul; pre="$(git -C "$R" rev-parse HEAD)"
  run_open_r --approved
  eq "$c: rc 2" "$RC" "2"
  ok "$c: 원인 줄(stderr)" "archive_publish 설정 오류: archive_publish 값 'pul' 은 허용 값 push|pr 이 아닙니다" "$ERR"
  nf_open_unchanged "$c" "$pre"

  # (4) 기준점 없음 → rc 2, rd task set-base 안내. 마커·세션의 리뷰 기준점과 base-commit 을 지운 커밋(보호 트리 밖 경로).
  c=t_open_nofr_no_base
  git -C "$R" reset -q --hard "$NF_HEAD"; setup_fake_gh
  local ts="$R/rd-workflow-workspace/.lifecycle/task-state" sid
  sid="$(awk -F= '$1=="review-session"{print $2}' "$ts")"
  nf_drop_line '^review-base=' "$R/rd-workflow-workspace/.lifecycle/review-seals/$sid.seal"
  nf_drop_line '^- review-base-oid:' "$R/rd-workflow-workspace/handoffs/review_pipeline/$sid/SESSION.md"
  nf_drop_line '^base-commit=' "$ts"; echo "base-commit=null" >>"$ts"
  git -C "$R" commit -q -am "기준점 지움"; pre="$(git -C "$R" rev-parse HEAD)"
  run_open_r --approved
  eq "$c: rc 2" "$RC" "2"
  ok "$c: 원인(stderr)" "tp_target_base: 반영 대상 기준점을 정할 수 없습니다" "$ERR"
  ok "$c: set-base 안내" "bash rd-workflow/scripts/rd task set-base <ref>" "$OUT"
  nf_open_unchanged "$c" "$pre"
  rm -rf "${W:?}"; CUR_TPL=""
}

# no-fr 에서 PR 기록이 이미 있는 상태로 archive_publish 를 pr·오타로 바꾼 뒤 --apply → rc 2, 실행 전 값 그대로.
# workflow.json 은 seal 보호 트리라 설정 커밋 뒤에는 기존 seal 검사도 apply 를 막습니다. 그래서 새 검사를 빼거나 포인터 커밋
# 뒤로 옮기는 변이는 「불변」 단언이 아니라 rc 2·안내 단언으로 잡힙니다(포인터 커밋까지 가지 않음).
# 없으면 새는 실수: Status·포인터 커밋을 기본 브랜치에 쌓은 뒤 archive 가 발행을 거부합니다.
t_apply_nofr_refused() {
  local c v MA b_rec b_ref b_head b_st b_ix
  mk_nofr; setup_fake_gh
  run_open_r --approved
  eq "t_apply_nofr_refused: 준비 — open rc 0" "$RC" "0"
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$NF_A" "$MA" 1
  for v in pr pul; do
    c="t_apply_nofr_refused($v)"
    nf_cfg_commit "$v"
    b_rec="$(cat "$R/$RD_REC")"; b_ref="$(team_ref a demo)"; b_head="$(git -C "$R" rev-parse HEAD)"; b_st="$(nf_status)"
    b_ix="$(git -C "$R" ls-files -s -- libs/a)"
    run_check_r --apply
    eq "$c: rc 2" "$RC" "2"
    if [[ "$v" == pr ]]; then
      ok "$c: promote 안내" "archive_publish=pr 는 fr 브랜치 작업만 지원합니다 — promote.sh 로 작업을 시작하십시오" "$OUT"
    else
      ok "$c: 원인 줄(stderr)" "archive_publish 설정 오류: archive_publish 값 'pul' 은 허용 값 push|pr 이 아닙니다" "$ERR"
    fi
    eq "$c: 기록 불변" "$(cat "$R/$RD_REC")" "$b_rec"
    eq "$c: 팀 ref 불변" "$(team_ref a demo)" "$b_ref"
    eq "$c: HEAD 불변" "$(git -C "$R" rev-parse HEAD)" "$b_head"
    eq "$c: Status 불변" "$(nf_status)" "$b_st"
    eq "$c: 인덱스 gitlink 불변" "$(git -C "$R" ls-files -s -- libs/a)" "$b_ix"
    git -C "$R" reset -q --hard HEAD~1
  done
  rm -rf "${W:?}"; CUR_TPL=""
}

# AC5: no-fr 전체 흐름 — 기본 브랜치에서 open → 팀 main 이 앞선 상태로 squash merge → check → --apply → archive 발행.
# open·--apply 자체의 단언(기록 커밋 위치, hook 우회, 포인터)은 t_open_nofr_accepted 가 봅니다. 여기서는 merge 전후의
# check 표, --apply 뒤 Status·포인터 커밋, archive rc 와 태그 커밋의 gitlink 를 봅니다.
# 없으면 새는 실수: archive 의 no-fr rebind 가 기록 커밋(정리 전 HEAD)을 넘기지 않아 PR merge 로 옮긴 포인터를
# merged 커밋 내용으로 세고 tag 전에 멈춥니다 — no-fr 지원의 목표(발행까지 이어짐)를 확인할 곳이 없습니다.
t_nofr_full_publish() {
  local c=t_nofr_full_publish MA URL pre tag
  mk_nofr; setup_fake_gh
  run_open_r --approved
  eq "$c: open rc 0" "$RC" "0"
  ok "$c: open 다음 행동 줄" "다음: PR merge 를 기다립니다 — bash rd-workflow/scripts/rd pr check" "$OUT"
  URL="https://github.com/o/team-a/pull/1"
  eq "$c: open 의 PR URL 이 기록에" "$(awk -F'\t' '$1=="libs/a"{print $5}' "$R/$RD_REC")" "$URL"
  # 팀 merge 전 — 기본 체크아웃의 check 는 검토 중 행(다음 행동 -)을 냅니다.
  run_check_r
  eq "$c: merge 전 check rc 0" "$RC" "0"
  ok "$c: merge 전 check 검토 중 행" "$(printf 'libs/a\t%s\t검토 중\t-' "$URL")" "$OUT"
  # 팀 main 이 앞선 뒤 squash — merged 커밋 내용이 리뷰한 head 와 다릅니다.
  team_advance a main
  MA="$(team_merge a squash)"
  pr_set o/team-a MERGED "$NF_A" "$MA" 1
  eq "$c: 준비 — merged 트리가 리뷰한 head 트리와 다름" \
    "$([[ "$(git --git-dir="$W/team-a.git" rev-parse "$MA^{tree}")" != "$(git -C "$R/libs/a" rev-parse "$NF_A^{tree}")" ]] && echo 다름 || echo 같음)" "다름"
  run_check_r
  eq "$c: merge 뒤 check rc 0" "$RC" "0"
  ok "$c: merge 뒤 check merge 됨 행·--apply 안내" "$(printf 'libs/a\t%s\tmerge 됨\tcd '\''%s'\'' && bash rd-workflow/scripts/rd pr check --apply' "$URL" "$R")" "$OUT"
  pre="$(git -C "$R" rev-parse HEAD)"
  run_check_r --apply
  eq "$c: apply rc 0" "$RC" "0"
  eq "$c: apply 뒤 Status 아카이브 보류(커밋됨)" \
    "$(git -C "$R" show HEAD:rd-workflow-workspace/.lifecycle/task-state | awk -F= '$1=="status"{print $2}')" "아카이브 보류"
  eq "$c: apply 포인터 커밋 1개" "$(git -C "$R" log --format=%s "$pre..HEAD" | grep -c '포인터 이동' | tr -d ' ')" "1"
  RC=0; OUT="$( cd "$R" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote 2>&1 )" || RC=$?
  eq "$c: archive rc 0" "$RC" "0"
  [[ "$RC" == 0 ]] || printf '%s\n' "$OUT" | tail -15 >&2
  tag="$(git -C "$R" tag --list "fr/*/$SLUG" | tail -1)"
  eq "$c: 태그 커밋의 libs/a gitlink = merged 커밋" "$(git -C "$R" rev-parse "${tag:-없음}^{commit}:libs/a" 2>/dev/null)" "$MA"
  rm -rf "${W:?}"; CUR_TPL=""
}
# 기본 체크아웃 작업(no-fr)의 닫힌 PR 표에서 1) 줄은 promote_rollback.sh(fr/* 가 아니면 멈춤) 대신 기본 체크아웃에서의 정리와
# 대기 중 전이를 안내합니다. fr 작업 쪽 1) 줄은 t_open_closed_pr_stops 가 봅니다.
# 없으면 새는 실수: 기본 체크아웃 작업에 실행하면 멈추는 취소 명령, 또는 호출한 셸의 다른 작업을 바꾸는 명령을 안내.
t_closed_choice_rollback() {
  local c="t_closed_choice_rollback(no-fr)" line
  mk_nofr; setup_fake_gh
  run_open_r --approved
  eq "$c: 준비 — open rc 0" "$RC" "0"
  set_pr_state o/team-a CLOSED
  run_check_r
  line="$(printf '%s\n' "$OUT" | grep '1) dropped 로 닫기')"
  eq "$c: 1) 줄" "$line" \
    "    1) dropped 로 닫기: /fr status demo dropped 뒤 기본 체크아웃($R)에서 이 작업의 변경을 정리하고 cd '$R' && bash rd-workflow/scripts/rd task set-status \"대기 중\""
  no "$c: promote_rollback.sh 를 안내하지 않음" "promote_rollback.sh" "$line"
  rm -rf "${W:?}"; CUR_TPL=""
}

# nf_add_index_task <status> — 기본 체크아웃(R) 밖에 진행 중 색인 작업 other(실제 worktree, task-state·CURRENT_TASK.md)를
# 더합니다. 전역 NF_OT(그 worktree)·NF_OT_SUM(두 파일의 요약).
nf_add_index_task() {
  NF_OT="$W/wt-other"
  git -C "$R" worktree add -q -b fr/other "$NF_OT" HEAD
  mkdir -p "$NF_OT/rd-workflow-workspace/.lifecycle"
  printf 'schema=1\nshort-title=other\nstatus=%s\nfr-branch=fr/other\nworktree-path=%s\nsource-fr=-\nbase-commit=null\nreview-session=null\n' "$1" "$NF_OT" \
    >"$NF_OT/rd-workflow-workspace/.lifecycle/task-state"
  printf '# Current Task\n\n## Short Title\nother\n\n## Status\n%s\n' "$1" >"$NF_OT/CURRENT_TASK.md"
  ( cd "$R" && project_root="$R" bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh
      tasks_index_upsert other fr-branch=fr/other worktree-path="$1"' _ "$NF_OT" )
  NF_OT_SUM="$(cksum <"$NF_OT/rd-workflow-workspace/.lifecycle/task-state")/$(cksum <"$NF_OT/CURRENT_TASK.md")"
}
nf_ot_sum() { printf '%s/%s' "$(cksum <"$NF_OT/rd-workflow-workspace/.lifecycle/task-state")" "$(cksum <"$NF_OT/CURRENT_TASK.md")"; }

# AC6: 색인에 다른 진행 중 작업이 1건인 저장소에서 기본 체크아웃 작업의 rd pr open·--apply 가 R 의 Status 만 옮깁니다.
# 두 명령을 따로 준비합니다(open 결과에 기대지 않음): open 은 색인 작업을 아카이브 보류(→ PR 검토 중 허용)로,
# --apply 는 색인 작업 없이 open·merge 를 마친 뒤 색인 작업을 PR 검토 중(→ 아카이브 보류 허용)으로 더해 실행합니다.
# 실행 시간: no-fr open 두 번과 apply 한 번(수 초). 사유: 내부 set-status 가 다른 작업을 바꾸고도 명령은 성공하므로,
# 두 PR 명령을 실제로 돌려 양쪽 파일을 보지 않으면 원래 결함이 샙니다.
# 없으면 새는 실수: rd pr open·--apply 의 내부 Status 전이가 색인의 다른 작업을 바꿈.
t_nofr_with_index() {
  local c=t_nofr_with_index MA
  mk_nofr; setup_fake_gh
  nf_add_index_task "아카이브 보류"
  run_open_r --approved
  eq "$c: open rc 0" "$RC" "0"
  eq "$c: open 뒤 R Status PR 검토 중" "$(nf_status)" "PR 검토 중"
  eq "$c: open 뒤 색인 작업 task-state·CURRENT_TASK.md 불변" "$(nf_ot_sum)" "$NF_OT_SUM"

  mk_nofr; setup_fake_gh
  run_open_r --approved
  eq "$c: 준비 — apply 용 open rc 0" "$RC" "0"
  MA="$(team_merge a merge)"
  pr_set o/team-a MERGED "$NF_A" "$MA" 1
  nf_add_index_task "PR 검토 중"
  run_check_r --apply
  eq "$c: apply rc 0" "$RC" "0"
  eq "$c: apply 뒤 R Status 아카이브 보류" "$(nf_status)" "아카이브 보류"
  eq "$c: apply 뒤 색인 작업 task-state·CURRENT_TASK.md 불변" "$(nf_ot_sum)" "$NF_OT_SUM"
  rm -rf "${W:?}"; CUR_TPL=""
}
# 호출부 회귀(fr, spec D2-2): 기본 브랜치가 submodule other 를 바꾼 커밋을 작업 브랜치가 병합한 뒤에도
# rd pr open(--dry-run 대상 표)·rd pr check(manual 줄)가 이 작업이 바꾼 submodule 만 대상으로 봅니다.
# 없으면 새는 실수: 호출부가 task-state base-commit 기준으로 남아 main 에서 들어온 other 를 이 작업의 반영 대상으로 냅니다.
t_target_base_main_merged() {
  local c=t_target_base_main_merged nl=$'\n'
  mk_overlay_with_team other_push; setup_fake_gh
  eq "$c: 준비 — other 가 base-commit 이후 바뀜" "$(git -C "$WT" diff --quiet "$BASE_COMMIT" HEAD -- other && echo 같음 || echo 다름)" "다름"
  # (1) other 는 push — dry-run 대상 표에 나오지 않아야 합니다.
  run_open --dry-run
  eq "$c(open --dry-run): rc 0" "$RC" "0"
  ok "$c(open --dry-run): libs/a 대상" "$(printf 'libs/a\t%s\tpr' "$W/team-a.git")" "$OUT"
  no "$c(open --dry-run): other 없음" "${nl}other$(printf '\t')" "$OUT"
  # (2) other 를 manual 로 바꾼 설정 커밋(check 는 seal 을 보지 않음) — manual 줄에 other 가 없고 libs/b 는 있습니다.
  python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["team_publish"]["submodules"]["other"]={"mode":"manual"}; open(p,"w").write(json.dumps(d)+"\n")' \
    "$WT/rd-workflow/config/workflow.json"
  git -C "$WT" commit -q -am "other manual"
  run_check
  eq "$c(check): rc 0" "$RC" "0"
  ok "$c(check): 이 작업의 manual 줄(libs/b)" "$(printf 'libs/b\t-\t반영하지 않음')" "$OUT"
  no "$c(check): other manual 줄 없음" "$(printf 'other\t-\t반영하지 않음')" "$OUT"
  rm -rf "${W:?}"; CUR_TPL=""
}
want t_target_base_main_merged && t_target_base_main_merged
# 리뷰 세션을 만든 뒤·seal 앞에 기본 브랜치를 병합한 경우(other_late): seal 은 한정 해시가 같아 통과하고 마커 head= 는
# 병합한 HEAD 입니다. 대상 경로는 마커 review-head=(리뷰한 끝)까지로 한정해야 합니다.
# 없으면 새는 실수: 리뷰한 끝을 head= 로 읽어 리뷰에 없던 other 를 push 대상으로 냅니다.
t_target_merge_before_seal() {
  local c=t_target_merge_before_seal nl=$'\n' mk
  mk_overlay_with_team other_late; setup_fake_gh
  mk="$WT/rd-workflow-workspace/.lifecycle/review-seals/$(basename "$SES").seal"
  eq "$c: 준비 — 마커 head= 가 review-head= 와 다름(seal 앞 병합)" \
    "$([[ "$(awk -F= '$1=="head"{print $2}' "$mk")" != "$(awk -F= '$1=="review-head"{print $2}' "$mk")" ]] && echo 다름 || echo 같음)" "다름"
  run_open --dry-run
  eq "$c(open --dry-run): rc 0" "$RC" "0"
  ok "$c(open --dry-run): libs/a 대상" "$(printf 'libs/a\t%s\tpr' "$W/team-a.git")" "$OUT"
  no "$c(open --dry-run): other 없음" "${nl}other$(printf '\t')" "$OUT"
  rm -rf "${W:?}"; CUR_TPL=""
}
want t_target_merge_before_seal && t_target_merge_before_seal
want t_open_nofr_accepted && t_open_nofr_accepted
want t_open_nofr_refusals && t_open_nofr_refusals
want t_apply_nofr_refused && t_apply_nofr_refused
want t_nofr_full_publish && t_nofr_full_publish
want t_closed_choice_rollback && t_closed_choice_rollback
want t_nofr_with_index && t_nofr_with_index

echo
echo "결과: PASS=$PASS FAIL=$FAIL (소요 $((SECONDS - T0))초)"
[[ "$FAIL" -eq 0 ]]
