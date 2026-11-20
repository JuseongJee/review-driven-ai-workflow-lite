#!/usr/bin/env bash
set -uo pipefail
# issue_queue.sh 테스트 — 가짜 gh(RD_GH) + 임시 git 저장소. 원격 GitHub 는 쓰지 않는다.
unset project_root RD_GH RD_ISSUE_LEDGER RD_ISSUE_LOCK_WAIT GH_HOST

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/issue_queue.sh"
TAB=$'\t'
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); }
nok()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [[ "$2" == "$3" ]]; then ok; else nok "$1 (기대='$3' 실제='$2')"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok; else nok "$1 (없음: '$3' / 실제='$2')"; fi; }
lacks(){ if [[ "$2" != *"$3"* ]]; then ok; else nok "$1 (있으면 안 됨: '$3' / 실제='$2')"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/iq-test.XXXXXX")" || { echo "test_issue_queue.sh: 임시 디렉터리 생성 실패" >&2; exit 2; }
[[ -n "$T" && -d "$T" ]] || { echo "test_issue_queue.sh: 임시 디렉터리 검증 실패" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

# ---- 가짜 gh ----
cat > "$T/fakegh" <<'FAKE'
#!/usr/bin/env bash
D="$FAKE_DIR"
ALL="$*"; CMD="$1"; SUB="${2:-}"
host=""; path=""; repo=""; num=""; bodyfile=""; remove=0; keys=""
case "$1" in
  api)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --paginate) shift ;;
        --hostname) host="$2"; shift 2 ;;
        --jq) shift 2 ;;
        -*) shift ;;
        *) [ -z "$path" ] && path="$1"; shift ;;
      esac
    done
    p="${path%%\?*}"
    k="api_${p//[^A-Za-z0-9.]/_}"
    [ -n "$host" ] && k="${k}_${host}"
    keys="$k"
    ;;
  issue)
    sub="$2"; num="$3"
    a=("$@")
    i=0
    while [ $i -lt ${#a[@]} ]; do
      case "${a[$i]}" in
        --repo) repo="${a[$((i+1))]}" ;;
        --body-file) bodyfile="${a[$((i+1))]}" ;;
        --remove-assignee) remove=1 ;;
      esac
      i=$((i+1))
    done
    keys="issue_$sub"
    [ "$sub" = edit ] && [ "$remove" = 1 ] && keys="issue_edit_remove issue_edit"
    ;;
  label) keys="label_$2" ;;
  *) keys="other" ;;
esac
suffix=""
if [ "$CMD" = issue ] && [ "$SUB" = edit ]; then
  suffix=" ledger=no"
  if [ -f "$RD_ISSUE_LEDGER" ]; then
    while IFS= read -r l; do case "$l" in "${repo}	${num}	"*) suffix=" ledger=yes" ;; esac; done < "$RD_ISSUE_LEDGER"
  fi
fi
echo "$ALL$suffix" >> "$D/gh.log"
if [ "$CMD" = api ] && [ -f "$D/delay" ]; then case "$k" in api_repos_*) sleep "$(<"$D/delay")" ;; esac; fi
for k in $keys; do [ -f "$D/fail/$k" ] && { echo "fake gh: $k 실패" >&2; exit 1; }; done
if [ "$CMD" = issue ] && [ -n "$bodyfile" ]; then cp "$bodyfile" "$D/body.$SUB"; fi
first="${keys%% *}"
n=0; [ -f "$D/cnt/$first" ] && n=$(<"$D/cnt/$first"); n=$((n + 1))
echo "$n" > "$D/cnt/$first"
if [ -f "$D/resp/$first.$n" ]; then printf '%s\n' "$(<"$D/resp/$first.$n")"
elif [ -f "$D/resp/$first" ]; then printf '%s\n' "$(<"$D/resp/$first")"
elif [ "$CMD" = api ]; then echo "fake gh: 응답 없음 $first" >&2; exit 1
elif [ "$CMD" = issue ] && [ "$SUB" = create ]; then echo "https://github.com/${repo}/issues/99"
fi
for k in $keys; do [ -f "$D/mklock_on/$k" ] && mkdir "$RD_ISSUE_LEDGER.lock" 2>/dev/null; done
exit 0
FAKE
chmod +x "$T/fakegh"

# 템플릿 저장소 (기본 브랜치 main) — 케이스마다 복사
mkdir "$T/tmpl" && git -C "$T/tmpl" init -q -b main \
  && git -C "$T/tmpl" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
  || { echo "test_issue_queue.sh: 템플릿 저장소 생성 실패" >&2; exit 2; }
rm -rf "$T/tmpl/.git/hooks"

CASE=""; C=""; R=""; OUT=""; ERR=""; RC=0
newcase() {
  CASE="$1"; C="$T/c_$1"; R="$C/repo"
  mkdir -p "$C/g/resp" "$C/g/fail" "$C/g/mklock_on" "$C/g/cnt" || exit 2
  mkdir -p "$R" || exit 2
  NO_PR=0
  export FAKE_DIR="$C/g" RD_GH="$T/fakegh" RD_ISSUE_LEDGER="$C/ledger.tsv" RD_ISSUE_LOCK_WAIT=0.2
  : > "$C/g/gh.log"
}
needgit() { rm -rf "$R" && cp -R "$T/tmpl" "$R" || exit 2; }
setcfg() { mkdir -p "$R/rd-workflow/config"; printf '%s\n' "$1" > "$R/rd-workflow/config/workflow.json"; }
resp()   { printf '%s\n' "$2" > "$C/g/resp/$1"; }
flag()   { mkdir -p "$C/g/$1"; : > "$C/g/$1/$2"; }
ij()     { # ij <state> [login...]
  local st="$1" a="" l; shift
  for l in "$@"; do a="${a:+$a,}{\"login\":\"$l\"}"; done
  printf '{"state":"%s","assignees":[%s]}' "$st" "$a"
}
iju()    { # iju <state> <html_url> — gh 가 고른 호스트의 Issue URL 을 담은 응답
  printf '{"state":"%s","html_url":"%s","assignees":[]}' "$1" "$2"
}
rowu()   { printf '%s\t%s\t%s\t-\t2026-11-16T00:00:00Z\n' "$1" "$2" "$3"; } # rowu <key> <n> <저장된 URL>
runin()  { # 기본은 project_root 를 주입해 git rev-parse 호출을 줄인다(NO_PR=1 이면 폴백 경로를 쓴다)
  local d="$1"; shift
  if [ "$NO_PR" = 1 ]; then OUT="$(cd "$d" && bash "$TARGET" "$@" 2>"$C/err")"; else OUT="$(cd "$d" && project_root="$d" bash "$TARGET" "$@" 2>"$C/err")"; fi
  RC=$?; ERR="$(<"$C/err")"; }
run()    { runin "$R" "$@"; }
glog()   { [ -f "$C/g/gh.log" ] && printf '%s' "$(<"$C/g/gh.log")"; }
ledger() { [ -f "$RD_ISSUE_LEDGER" ] && printf '%s' "$(<"$RD_ISSUE_LEDGER")"; }
row()    { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "https://github.com/$1/issues/$2" "${3:--}" "2026-11-16T00:00:00Z"; }
lastline() { printf '%s\n' "$1" | tail -1; }

# ---- repos ----
newcase repos_config
setcfg '{"issue_queue_repos":["a/b","ghe.example/c/d"]}'
run repos
check repos_config "$OUT" $'a/b\nghe.example/c/d'

# ---- has-team-queue ----
newcase htq_config
setcfg '{"issue_queue_repos":["a/b"]}'
run has-team-queue
check htq_config.rc "$RC" 0

newcase htq_empty_string
setcfg '{"issue_queue_repos":[""]}'
run has-team-queue
check htq_empty_string.rc "$RC" 1

newcase htq_submodule
printf '[submodule "one"]\n\tpath = one\n\turl = https://github.com/t/one.git\n' > "$R/.gitmodules"
run has-team-queue
check htq_submodule.rc "$RC" 0

newcase htq_relative_submodule
printf '[submodule "team"]\n\tpath = team\n\turl = ../team.git\n' > "$R/.gitmodules"
run has-team-queue
check htq_relative_submodule.rc "$RC" 1

GM_BASE=$'[submodule "one"]\n\tpath = one\n\turl = https://github.com/t/one.git\n[submodule "two"]\n\tpath = two\n\turl = git@github.com:t/two\n'
newcase repos_gitmodules
printf '%s' "$GM_BASE" > "$R/.gitmodules"
run repos --with-path
check repos_gitmodules "$OUT" $'t/one\tone\nt/two\ttwo'

newcase repos_config_overlay_path
printf '%s' "$GM_BASE" > "$R/.gitmodules"
setcfg '{"issue_queue_repos":["t/two"]}'
run repos --with-path
check repos_config_overlay_path "$OUT" $'t/two\ttwo'

newcase repos_relative_url_skipped
printf '%s[submodule "three"]\n\tpath = three\n\turl = ../three.git\n' "$GM_BASE" > "$R/.gitmodules"
run repos --with-path
check repos_relative_url_skipped.stdout "$OUT" $'t/one\tone\nt/two\ttwo'
has   repos_relative_url_skipped.warn "$ERR" three
check repos_relative_url_skipped.lines "$(printf '%s\n' "$ERR" | grep -c .)" 1
check repos_relative_url_skipped.rc "$RC" 0

# overlay 인데 submodule URL 을 하나도 해석하지 못하면 origin(overlay 자신)으로 대체하지 않고 rc 3
newcase repos_relative_only_no_origin_fallback
needgit; NO_PR=1
git -C "$R" remote add origin git@github.com:personal/overlay.git
printf '[submodule "team"]\n\tpath = team\n\turl = ../team.git\n' > "$R/.gitmodules"
run repos --with-path
check repos_relative_only_no_origin_fallback.rc "$RC" 3
check repos_relative_only_no_origin_fallback.stdout "$OUT" ""

newcase repos_origin
needgit; NO_PR=1
git -C "$R" remote add origin ssh://git@github.com/me/proj.git
run repos
check repos_origin "$OUT" me/proj

# ---- list ----
newcase list_filters
setcfg '{"issue_queue_repos":["a/b"],"issue_queue_labels":["bug"]}'
printf '%s\n%s\n' \
  '[{"number":1,"title":"pr","html_url":"https://github.com/a/b/pull/1","pull_request":{},"labels":[{"name":"bug"}]}]' \
  '[{"number":2,"title":"t2","html_url":"https://github.com/a/b/issues/2","labels":[{"name":"bug"}]},{"number":3,"title":"t3","html_url":"https://github.com/a/b/issues/3","labels":[]}]' \
  > "$C/g/resp/api_repos_a_b_issues"
run list
check list_filters.rc "$RC" 0
check list_filters.lines "$(printf '%s\n' "$OUT" | grep -c .)" 1
check list_filters.num "$(printf '%s' "$OUT" | cut -f2)" 2
has   list_filters.paginate "$(glog)" "--paginate"
has   list_filters.assignee "$(glog)" "assignee=none"
setcfg '{"issue_queue_repos":["a/b"],"issue_queue_labels":["bug"],"issue_claim_label":"claimed"}'
printf '%s\n' '[{"number":2,"title":"t2","html_url":"https://github.com/a/b/issues/2","labels":[{"name":"bug"},{"name":"claimed"}]}]' > "$C/g/resp/api_repos_a_b_issues"
run list
check list_filters.claimed "$OUT" ""

# ---- claim ----
claim_setup() { # claim_setup <view1> <view2> [label]
  [ -n "${3:-}" ] && setcfg '{"issue_claim_label":"claimed"}'
  resp api_repos_a_b_issues_7.1 "$1"
  resp api_repos_a_b_issues_7.2 "$2"
  resp api_user me
}

newcase claim_ok
claim_setup "$(ij open)" "$(ij open me)" label
run claim a/b 7
check claim_ok.rc "$RC" 0
check claim_ok.url "$OUT" https://github.com/a/b/issues/7
has   claim_ok.edit "$(glog)" "issue edit 7 --repo a/b --add-assignee @me --add-label claimed"
has   claim_ok.ledger_before_edit "$(glog | grep -F 'issue edit 7 --repo a/b --add-assignee')" "ledger=yes"
if ledger | grep -q "^a/b${TAB}7${TAB}https://github.com/a/b/issues/7${TAB}-${TAB}"; then ok; else nok "claim_ok.row ($(ledger))"; fi

newcase claim_taken
claim_setup "$(ij open x)" "$(ij open x)"
row c/d 1 > "$RD_ISSUE_LEDGER"; BEFORE="$(ledger)"
run claim a/b 7
check claim_taken.rc "$RC" 4
lacks claim_taken.noedit "$(glog)" "issue edit"
check claim_taken.ledger "$(ledger)" "$BEFORE"

newcase claim_race_backoff
claim_setup "$(ij open)" "$(ij open me x)" label
run claim a/b 7
check claim_race_backoff.rc "$RC" 5
has   claim_race_backoff.remove "$(glog)" "--remove-assignee @me --remove-label claimed"
lacks claim_race_backoff.row "$(ledger)" "a/b${TAB}7${TAB}"

newcase claim_not_me
claim_setup "$(ij open)" "$(ij open)"
run claim a/b 7
check claim_not_me.rc "$RC" 6
lacks claim_not_me.row "$(ledger)" "a/b${TAB}7${TAB}"

newcase claim_closed_before
claim_setup "$(ij closed)" "$(ij closed)"
run claim a/b 7
check claim_closed_before.rc "$RC" 11
lacks claim_closed_before.noedit "$(glog)" "issue edit"
lacks claim_closed_before.row "$(ledger)" "a/b${TAB}7${TAB}"

newcase claim_closed_after
claim_setup "$(ij open)" "$(ij closed me)"
run claim a/b 7
check claim_closed_after.rc "$RC" 11
has   claim_closed_after.remove "$(glog)" "--remove-assignee @me"
lacks claim_closed_after.row "$(ledger)" "a/b${TAB}7${TAB}"

newcase claim_cleanup_lock_fail
claim_setup "$(ij open)" "$(ij open me x)" label
flag mklock_on issue_edit_remove
run claim a/b 7
check claim_cleanup_lock_fail.rc "$RC" 10
has   claim_cleanup_lock_fail.stderr "$(lastline "$ERR")" "장부 행: 남음"
has   claim_cleanup_lock_fail.row "$(ledger)" "a/b${TAB}7${TAB}"

newcase claim_first_lookup_fail_reports
claim_setup "$(ij open)" "$(ij open me)"
flag fail api_repos_a_b_issues_7
run claim a/b 7
check claim_first_lookup_fail_reports.rc "$RC" 9
has   claim_first_lookup_fail_reports.last "$(lastline "$ERR")" "장부 행: 없음"
has   claim_first_lookup_fail_reports.cmd "$(lastline "$ERR")" "issue_queue.sh claim a/b 7"

newcase claim_remote_unknown_keeps_ledger
claim_setup "$(ij open)" "$(ij open me)"
flag fail issue_edit
run claim a/b 7
check claim_remote_unknown_keeps_ledger.rc "$RC" 7
has   claim_remote_unknown_keeps_ledger.row "$(ledger)" "a/b${TAB}7${TAB}"
has   claim_remote_unknown_keeps_ledger.url "$ERR" "https://github.com/a/b/issues/7"
has   claim_remote_unknown_keeps_ledger.last "$(lastline "$ERR")" "장부 행: 남음 — 재실행: "
has   claim_remote_unknown_keeps_ledger.cmd "$(lastline "$ERR")" "issue_queue.sh release a/b 7"

newcase claim_existing_ledger
claim_setup "$(ij open)" "$(ij open me)"
row a/b 7 > "$RD_ISSUE_LEDGER"
run claim a/b 7
check claim_existing_ledger.rc "$RC" 8
check claim_existing_ledger.nogh "$(glog)" ""

newcase claim_same_number_two_repos
claim_setup "$(ij open)" "$(ij open me)"
resp api_repos_c_d_issues_7.1 "$(ij open)"
resp api_repos_c_d_issues_7.2 "$(ij open me)"
run claim a/b 7; RC1=$RC
run claim c/d 7
check claim_same_number_two_repos.rc "$RC1/$RC" "0/0"
check claim_same_number_two_repos.rows "$(ledger | grep -c .)" 2

newcase claim_ghe_login
resp api_repos_c_d_issues_7_ghe.example.1 "$(ij open)"
resp api_repos_c_d_issues_7_ghe.example.2 "$(ij open corp-me)"
resp api_user octo
resp api_user_ghe.example corp-me
run claim ghe.example/c/d 7
check claim_ghe_login.rc "$RC" 0
has   claim_ghe_login.host "$(glog | grep -F ' user')" "--hostname ghe.example"

newcase claim_concurrent_ledger
export RD_ISSUE_LOCK_WAIT=5
echo 0.1 > "$C/g/delay"
for n in 1 2 3; do
  resp api_repos_a_b_issues_$n.1 "$(ij open)"
  resp api_repos_a_b_issues_$n.2 "$(ij open me)"
done
resp api_user me
for id in w1:1 w2:2 w3:3 w4:3; do
  ( cd "$R" && bash "$TARGET" claim a/b "${id#*:}" >/dev/null 2>&1; echo $? > "$C/rc.${id%%:*}" ) &
done
wait
check claim_concurrent_ledger.rc12 "$(<"$C/rc.w1") $(<"$C/rc.w2")" "0 0"
check claim_concurrent_ledger.rc3 "$(printf '%s\n%s\n' "$(<"$C/rc.w3")" "$(<"$C/rc.w4")" | sort | tr '\n' ' ')" "0 8 "
check claim_concurrent_ledger.rows "$(ledger | grep -c .)" 3
check claim_concurrent_ledger.row3 "$(ledger | grep -c "^a/b${TAB}3${TAB}")" 1

# ---- lock / link / release ----
newcase lock_timeout
mkdir "$RD_ISSUE_LEDGER.lock"
run link a/b 7 2026-11-16-x
check lock_timeout.rc "$RC" 9
has   lock_timeout.stderr "$ERR" ".lock"
check lock_timeout.ledger "$(ledger)" ""
[ ! -e "$RD_ISSUE_LEDGER" ] && ok || nok "lock_timeout.nofile"

newcase link_upsert
run link a/b 7 2026-11-16-x
check link_upsert.rc "$RC" 0
if ledger | grep -q "^a/b${TAB}7${TAB}https://github.com/a/b/issues/7${TAB}2026-11-16-x${TAB}"; then ok; else nok "link_upsert.row ($(ledger))"; fi

newcase link_lock_fail_row_exists
row a/b 7 > "$RD_ISSUE_LEDGER"
mkdir "$RD_ISSUE_LEDGER.lock"
run link a/b 7 2026-11-16-x
check link_lock_fail_row_exists.rc "$RC" 9
has   link_lock_fail_row_exists.last "$(lastline "$ERR")" "장부 행: 남음"

newcase release_ok
setcfg '{"issue_claim_label":"claimed"}'
row a/b 7 > "$RD_ISSUE_LEDGER"
run release a/b 7
check release_ok.rc "$RC" 0
has   release_ok.remove "$(glog)" "--remove-assignee @me --remove-label claimed"
check release_ok.row "$(ledger)" ""

newcase release_fail_keeps_ledger
row a/b 7 > "$RD_ISSUE_LEDGER"
flag fail issue_edit
run release a/b 7
check release_fail_keeps_ledger.rc "$RC" 7
has   release_fail_keeps_ledger.row "$(ledger)" "a/b${TAB}7${TAB}"

newcase release_remote_ok_lock_fail
row a/b 7 > "$RD_ISSUE_LEDGER"
flag mklock_on issue_edit
run release a/b 7
check release_remote_ok_lock_fail.rc "$RC" 10
has   release_remote_ok_lock_fail.stderr "$ERR" "장부 행: 남음"
has   release_remote_ok_lock_fail.cmd "$ERR" "issue_queue.sh release a/b 7"
has   release_remote_ok_lock_fail.row "$(ledger)" "a/b${TAB}7${TAB}"

# ---- stale ----
commit_fr() { # commit_fr <stem> <status>  (기본 체크아웃 main 에 커밋)
  mkdir -p "$R/rd-workflow-workspace/backlog/items"
  printf '# %s\n- status: %s\n' "$1" "$2" > "$R/rd-workflow-workspace/backlog/items/$1.md"
  git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -q -m "fr $1"
}
SK="bash rd-workflow/scripts/issue_queue.sh"

newcase stale_reasons
needgit
commit_fr drop-fr dropped; commit_fr done-fr done; commit_fr live-fr idea
{ row a/b 1 -; row a/b 2 missing-fr; row a/b 3 drop-fr; row a/b 4 done-fr; row a/b 5 live-fr; } > "$RD_ISSUE_LEDGER"
run stale
check stale_reasons.rc "$RC" 0
check stale_reasons.out "$OUT" "$(printf 'https://github.com/a/b/issues/1\t연결 FR 없음\t%s release a/b 1\nhttps://github.com/a/b/issues/2\tFR 파일 없음\t%s release a/b 2\nhttps://github.com/a/b/issues/3\tFR dropped\t%s release a/b 3' "$SK" "$SK" "$SK")"
lacks stale_reasons.done_removed "$(ledger)" "a/b${TAB}4${TAB}"
has   stale_reasons.live_kept "$(ledger)" "a/b${TAB}5${TAB}"
check stale_reasons.nogh "$(glog)" ""

newcase stale_other_worktree
needgit
commit_fr live-fr idea
row a/b 5 live-fr > "$RD_ISSUE_LEDGER"
git -C "$R" worktree add -q -b other "$C/wt2" || nok "stale_other_worktree.setup"
git -C "$C/wt2" rm -q rd-workflow-workspace/backlog/items/live-fr.md && git -C "$C/wt2" -c user.name=t -c user.email=t@t commit -q -m rm
runin "$C/wt2" stale
check stale_other_worktree.out "$OUT" ""

newcase stale_uncommitted_registration
needgit
git -C "$R" worktree add -q -b other "$C/wt2" || nok "stale_uncommitted_registration.setup"
mkdir -p "$R/rd-workflow-workspace/backlog/items"
printf '# x\n- status: idea\n' > "$R/rd-workflow-workspace/backlog/items/live-fr.md"
row a/b 5 live-fr > "$RD_ISSUE_LEDGER"
runin "$C/wt2" stale
check stale_uncommitted_registration.out "$OUT" ""

newcase stale_dropped_in_worktree
needgit
commit_fr live-fr idea
row a/b 5 live-fr > "$RD_ISSUE_LEDGER"
git -C "$R" worktree add -q -b other "$C/wt2" || nok "stale_dropped_in_worktree.setup"
printf '# x\n- status: dropped\n' > "$C/wt2/rd-workflow-workspace/backlog/items/live-fr.md"
run stale
has stale_dropped_in_worktree.out "$OUT" "FR dropped"

newcase stale_unknown_branch
rm -rf "$R"; mkdir "$R" && git -C "$R" init -q -b trunk && git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
row a/b 5 some-fr > "$RD_ISSUE_LEDGER"; BEFORE="$(ledger)"
run stale
check stale_unknown_branch.out "$OUT" "$(printf 'https://github.com/a/b/issues/5\t판정 불가\t-')"
check stale_unknown_branch.ledger "$(ledger)" "$BEFORE"

# ---- close-fr / commit-url ----
detail() { printf '# t\n- status: done\n- github-issue: %s\n' "$1" > "$R/detail.md"; }
CURL="https://github.com/o/r/commit/abc123"

newcase close_fr_remote_ok_lock_fail
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij open me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
flag mklock_on issue_close
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_remote_ok_lock_fail.rc "$RC" 10
has   close_fr_remote_ok_lock_fail.stderr "$ERR" "장부 행: 남음"
has   close_fr_remote_ok_lock_fail.cmd "$ERR" "issue_queue.sh forget a/b 7"
has   close_fr_remote_ok_lock_fail.row "$(ledger)" "a/b${TAB}7${TAB}"

newcase close_fr_already_closed
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij closed me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_already_closed.rc "$RC" 0
has   close_fr_already_closed.comment "$(glog)" "issue comment 7 --repo a/b"
lacks close_fr_already_closed.noclose "$(glog)" "issue close"
check close_fr_already_closed.row "$(ledger)" ""

newcase close_fr_noop
detail '-'
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_noop.rc "$RC" 0
check close_fr_noop.nogh "$(glog)" ""

newcase close_fr_empty_url
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij open me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md"
check close_fr_empty_url.rc "$RC" 2
check close_fr_empty_url.nogh "$(glog)" ""

newcase close_fr_ok
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij open me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_ok.rc "$RC" 0
has   close_fr_ok.comment "$(glog)" "issue comment 7 --repo a/b"
has   close_fr_ok.close "$(glog)" "issue close 7 --repo a/b"
check close_fr_ok.row "$(ledger)" ""

newcase close_fr_skip_closed_closed
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij closed me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_skip_closed_closed.rc "$RC" 0
lacks close_fr_skip_closed_closed.nocomment "$(glog)" "issue comment"
lacks close_fr_skip_closed_closed.noclose "$(glog)" "issue close"
check close_fr_skip_closed_closed.out "$OUT" "skipped-closed https://github.com/a/b/issues/7"
check close_fr_skip_closed_closed.row "$(ledger)" ""

newcase close_fr_skip_closed_open
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij open me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_skip_closed_open.rc "$RC" 0
has   close_fr_skip_closed_open.comment "$(glog)" "issue comment 7 --repo a/b"
has   close_fr_skip_closed_open.close "$(glog)" "issue close 7 --repo a/b"
check close_fr_skip_closed_open.out "$OUT" "closed https://github.com/a/b/issues/7"

newcase close_fr_skip_closed_nolink
detail '-'
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_skip_closed_nolink.rc "$RC" 0
check close_fr_skip_closed_nolink.nogh "$(glog)" ""
check close_fr_skip_closed_nolink.out "$OUT" ""

# 중복 보고처럼 여러 Issue 를 쉼표로 이으면 모두 닫는다.
newcase close_fr_multi
detail 'a/b#7, a/b#9'; resp api_repos_a_b_issues_7 "$(ij open me)"; resp api_repos_a_b_issues_9 "$(ij open)"
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_multi.rc "$RC" 0
has   close_fr_multi.comment7 "$(glog)" "issue comment 7 --repo a/b"
has   close_fr_multi.close7 "$(glog)" "issue close 7 --repo a/b"
has   close_fr_multi.comment9 "$(glog)" "issue comment 9 --repo a/b"
has   close_fr_multi.close9 "$(glog)" "issue close 9 --repo a/b"

newcase close_fr_multi_skip
detail 'a/b#7,a/b#9'; resp api_repos_a_b_issues_7 "$(ij open me)"; resp api_repos_a_b_issues_9 "$(ij closed)"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_multi_skip.rc "$RC" 0
check close_fr_multi_skip.out "$OUT" $'closed https://github.com/a/b/issues/7\nskipped-closed https://github.com/a/b/issues/9'

# 값에 설명을 붙이면 앞의 올바른 조각도 건드리지 않고 무엇이 틀렸는지 알린다.
newcase close_fr_malformed
detail 'a/b#7, a/b#8 (중복 보고: a/b#9)'; resp api_repos_a_b_issues_7 "$(ij open me)"; resp api_repos_a_b_issues_8 "$(ij open me)"
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_malformed.rc "$RC" 2
check close_fr_malformed.nogh "$(glog)" ""
has   close_fr_malformed.reason "$(lastline "$ERR")" "'a/b#8 (중복 보고: a/b#9)'"

# 끝에 남은 쉼표의 빈 조각도 형식 오류다.
newcase close_fr_trailing_comma
detail 'a/b#7,'; resp api_repos_a_b_issues_7 "$(ij open me)"
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_trailing_comma.rc "$RC" 2
check close_fr_trailing_comma.nogh "$(glog)" ""

# 브라우저에서 복사한 Issue URL 도 받아 닫는다. 원격 명령은 URL 의 호스트를 그대로 쓰고(gh 기본 호스트가
# 달라도 다른 서버로 가지 않게), 장부는 같은 호스트 키의 행만 지운다(호스트 대소문자 무시).
# 호스트 없는 행은 어느 호스트인지 확정할 수 없어 남기고 푸는 방법을 알린다.
newcase close_fr_url
detail 'https://github.com/a/b/issues/7'; resp api_repos_a_b_issues_7_github.com "$(ij open me)"
{ row a/b 7 x; row GITHUB.COM/a/b 7 x; row ghe.example.com/a/b 7 x; } > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_url.rc "$RC" 0
has   close_fr_url.view "$(glog)" "api --hostname github.com repos/a/b/issues/7"
has   close_fr_url.close "$(glog)" "issue close 7 --repo github.com/a/b"
check close_fr_url.rows "$(ledger | cut -f1 | tr '\n' ' ')" "a/b ghe.example.com/a/b "
has   close_fr_url.keep_notice "$ERR" "호스트 없는 선점 행 a/b#7 이 남았습니다"

# 호스트 없는 값은 같은 키(호스트 없는 행)만 지운다. 결과 URL 은 gh 가 돌려준 html_url 이다.
newcase close_fr_ledger_gh_host
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(iju closed https://ghe.example.com/a/b/issues/7)"
{ rowu a/b 7 https://github.com/a/b/issues/7; rowu github.com/a/b 7 https://github.com/a/b/issues/7; } > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_ledger_gh_host.rc "$RC" 0
check close_fr_ledger_gh_host.url "$OUT" "skipped-closed https://ghe.example.com/a/b/issues/7"
check close_fr_ledger_gh_host.rows "$(ledger | cut -f1 | tr '\n' ' ')" "github.com/a/b "

# --skip-closed(archive) 출력에는 남긴 호스트 없는 행을 `kept-row` 줄로 더한다.
newcase close_fr_kept_row_line
detail 'https://github.com/a/b/issues/7'; resp api_repos_a_b_issues_7_github.com "$(ij closed me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_kept_row_line.rc "$RC" 0
check close_fr_kept_row_line.out "$OUT" "skipped-closed https://github.com/a/b/issues/7
kept-row a/b 7"

# 닫은 뒤 장부 잠금이 실패하면 원격을 건드리지 않는 forget 을 적힌 저장소로 안내한다.
# 그대로 실행하면 처음 고른 행(키 대소문자 무시)만 지우고 gh 는 부르지 않는다.
newcase close_fr_ledger_lock_rerun
detail 'https://github.com/a/b/issues/7'; resp api_repos_a_b_issues_7_github.com "$(ij open me)"
{ row GITHUB.COM/a/b 7 x; row a/b 7 x; } > "$RD_ISSUE_LEDGER"
flag mklock_on issue_close
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_ledger_lock_rerun.rc "$RC" 10
has   close_fr_ledger_lock_rerun.cmd "$(lastline "$ERR")" "issue_queue.sh forget github.com/a/b 7"
rmdir "$RD_ISSUE_LEDGER.lock"; : > "$C/g/gh.log"
run forget github.com/a/b 7
check close_fr_ledger_lock_rerun.rerun_rc "$RC" 0
check close_fr_ledger_lock_rerun.rerun_rows "$(ledger | cut -f1 | tr '\n' ' ')" "a/b "
check close_fr_ledger_lock_rerun.no_remote "$(glog)" ""

# 장부를 읽지 못하면 "행 없음" 으로 넘기지 않는다 — rc 10, 행 보존, forget 안내.
newcase close_fr_ledger_unreadable
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij closed me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"; chmod 000 "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
chmod 644 "$RD_ISSUE_LEDGER"
check close_fr_ledger_unreadable.rc "$RC" 10
has   close_fr_ledger_unreadable.cmd "$(lastline "$ERR")" "issue_queue.sh forget a/b 7"
has   close_fr_ledger_unreadable.row "$(ledger)" "a/b${TAB}7${TAB}"

# 장부 경로가 파일이 아니면(디렉터리) 읽기 실패로 본다.
newcase close_fr_ledger_not_file
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij closed me)"
mkdir "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
rmdir "$RD_ISSUE_LEDGER"
check close_fr_ledger_not_file.rc "$RC" 10
has   close_fr_ledger_not_file.reason "$ERR" "장부를 읽을 수 없습니다"

# 상세를 읽지 못하면 연결 없음(rc 0)으로 넘기지 않고 rc 2 와 사유를 낸다.
newcase issue_refs_unreadable
detail 'a/b#7'; chmod 000 "$R/detail.md"
run issue-refs "$R/detail.md"
chmod 644 "$R/detail.md"
check issue_refs_unreadable.rc "$RC" 2
has   issue_refs_unreadable.reason "$ERR" "FR 상세를 읽을 수 없습니다"

# --closes 는 PR 본문 Closes 줄에 쓸 참조다 — 적힌 URL 은 그대로(스킴·대소문자·끝 / 포함), 호스트 붙은 축약은
# https Issue URL, 나머지는 그대로. 같은 Issue 의 중복은 첫 표기만 남는다.
newcase issue_refs_closes
detail 'http://ghe.example.com/a/b/issues/7, ghe.example.com/a/b#8, a/b#9, https://GITHUB.com/a/b/issues/10/, github.com/a/b#10'
run issue-refs "$R/detail.md" --closes
check issue_refs_closes.rc "$RC" 0
check issue_refs_closes.out "$OUT" "http://ghe.example.com/a/b/issues/7
https://ghe.example.com/a/b/issues/8
a/b#9
https://GITHUB.com/a/b/issues/10/"

# 장부 잠금 실패와 원격 실패가 섞여도 Issue 마다 원격 결과 줄, 남은 호스트 없는 행, 장부 정리 실패 줄이 모두 나온다.
newcase close_fr_lock_result_lines
detail 'https://github.com/a/b/issues/7, https://github.com/a/b/issues/8, a/b#9'
resp api_repos_a_b_issues_7_github.com "$(ij open me)"; resp api_repos_a_b_issues_8_github.com "$(ij closed me)"
{ row github.com/a/b 7 x; row github.com/a/b 8 x; row a/b 7 x; } > "$RD_ISSUE_LEDGER"
mkdir "$RD_ISSUE_LEDGER.lock"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
rmdir "$RD_ISSUE_LEDGER.lock"
check close_fr_lock_result_lines.rc "$RC" 7
check close_fr_lock_result_lines.out "$OUT" "closed https://github.com/a/b/issues/7
kept-row a/b 7
ledger-left github.com/a/b 7
skipped-closed https://github.com/a/b/issues/8
ledger-left github.com/a/b 8"

# 장부가 링크면 forget 은 링크를 유지한 채 대상 파일의 행을 지운다(링크를 일반 파일로 바꾸지 않는다).
newcase forget_symlink_ledger
row a/b 7 x > "$C/actual.tsv"; row a/b 8 y >> "$C/actual.tsv"; ln -s "$C/actual.tsv" "$RD_ISSUE_LEDGER"
run forget a/b 7
check forget_symlink_ledger.rc "$RC" 0
check forget_symlink_ledger.link "$([ -L "$RD_ISSUE_LEDGER" ] && echo link)" "link"
check forget_symlink_ledger.rows "$(cut -f1,2 "$C/actual.tsv" | tr '\t\n' ': ')" "a/b:8 "

# 링크로 장부를 고쳐도 실제 파일의 접근 권한(0600·0660·0444)은 그대로다 — 임시 파일을 umask 로 새로 만들어 바꿔 끼우지 않고,
#   읽기 전용 장부도 종전처럼 바꿔 끼운다(권한은 내용을 쓴 뒤에 입힌다).
for m in 600 660 444; do
  newcase "forget_symlink_mode_$m"
  row a/b 7 x > "$C/actual.tsv"; row a/b 8 y >> "$C/actual.tsv"; chmod "$m" "$C/actual.tsv"; ln -s "$C/actual.tsv" "$RD_ISSUE_LEDGER"
  ( umask 022; run forget a/b 7; echo "$RC" > "$C/rc" )
  check "forget_symlink_mode_$m.rc" "$(cat "$C/rc")" 0
  case "$m" in 600) want='-rw-------' ;; 660) want='-rw-rw----' ;; *) want='-r--r--r--' ;; esac
  check "forget_symlink_mode_$m.mode" "$(ls -l "$C/actual.tsv" | cut -c1-10)" "$want"
  check "forget_symlink_mode_$m.rows" "$(cut -f1,2 "$C/actual.tsv" | tr '\t\n' ': ')" "a/b:8 "
  check "forget_symlink_mode_$m.link" "$([ -L "$RD_ISSUE_LEDGER" ] && echo link)" "link"
done

# 읽기 전용(0444) 장부의 기존 행에도 link 가 FR 을 적는다 — 권한은 그대로다.
newcase link_readonly_ledger
row a/b 7 x > "$RD_ISSUE_LEDGER"; chmod 444 "$RD_ISSUE_LEDGER"
run link a/b 7 my-fr
check link_readonly_ledger.rc "$RC" 0
check link_readonly_ledger.stem "$(cut -f4 "$RD_ISSUE_LEDGER")" "my-fr"
check link_readonly_ledger.mode "$(ls -l "$RD_ISSUE_LEDGER" | cut -c1-10)" "-r--r--r--"

# 링크와 실제 파일은 같은 잠금을 쓴다 — 실제 파일 경로로 잠가 두면 링크 경로의 forget 도 기다리다 실패하고 장부는 그대로다.
newcase forget_symlink_shared_lock
row a/b 7 x > "$C/actual.tsv"; row a/b 8 y >> "$C/actual.tsv"; ln -s "$C/actual.tsv" "$RD_ISSUE_LEDGER"
mkdir "$C/actual.tsv.lock"
run forget a/b 7
rmdir "$C/actual.tsv.lock"
check forget_symlink_shared_lock.rc "$RC" 10
check forget_symlink_shared_lock.rows "$(cut -f1,2 "$C/actual.tsv" | tr '\t\n' ': ')" "a/b:7 a/b:8 "

# 상세 경로가 일반 파일이 아니면(디렉터리) 읽기 실패다 — BSD awk 는 디렉터리를 빈 입력으로 읽는다.
newcase issue_refs_directory
mkdir "$R/detail.md"
run issue-refs "$R/detail.md"
check issue_refs_directory.rc "$RC" 2
has   issue_refs_directory.reason "$ERR" "FR 상세를 읽을 수 없습니다"

# 장부의 상위 디렉터리에 들어갈 수 없으면 「장부 없음」 이 아니라 읽기 실패다.
newcase close_fr_ledger_parent_unreadable
export RD_ISSUE_LEDGER="$C/ld/ledger.tsv"; mkdir "$C/ld"
detail 'a/b#7'; resp api_repos_a_b_issues_7 "$(ij closed me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"; chmod 000 "$C/ld"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
chmod 755 "$C/ld"
check close_fr_ledger_parent_unreadable.rc "$RC" 10
has   close_fr_ledger_parent_unreadable.row "$(ledger)" "a/b${TAB}7${TAB}"

# 끊어진 링크인 장부도 읽기 실패다.
newcase forget_broken_link
ln -s "$C/nowhere.tsv" "$RD_ISSUE_LEDGER"
run forget a/b 7
check forget_broken_link.rc "$RC" 10
has   forget_broken_link.reason "$ERR" "장부를 읽을 수 없습니다"

# 한 상세의 다른 Issue 가 실패해도 닫은 Issue 의 결과 줄과 남긴 호스트 없는 행(kept-row)은 나온다.
newcase close_fr_multi_partial_kept_row
detail 'https://github.com/a/b/issues/7, a/b#9'; resp api_repos_a_b_issues_7_github.com "$(ij open me)"
row a/b 7 x > "$RD_ISSUE_LEDGER"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_multi_partial_kept_row.rc "$RC" 7
check close_fr_multi_partial_kept_row.out "$OUT" "closed https://github.com/a/b/issues/7
kept-row a/b 7"

# 여러 Issue 의 원격 처리가 끝나고 장부 정리만 실패하면 rc 10, Issue 마다 ledger-left 줄, 요약은 forget 안내다.
newcase close_fr_multi_ledger_only
detail 'https://github.com/a/b/issues/7, https://ghe.example.com/a/b/issues/7'
resp api_repos_a_b_issues_7_github.com "$(ij closed me)"; resp api_repos_a_b_issues_7_ghe.example.com "$(ij closed me)"
{ row github.com/a/b 7 x; row ghe.example.com/a/b 7 x; } > "$RD_ISSUE_LEDGER"
mkdir "$RD_ISSUE_LEDGER.lock"
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
rmdir "$RD_ISSUE_LEDGER.lock"
check close_fr_multi_ledger_only.rc "$RC" 10
has   close_fr_multi_ledger_only.left1 "$OUT" "ledger-left github.com/a/b 7"
has   close_fr_multi_ledger_only.left2 "$OUT" "ledger-left ghe.example.com/a/b 7"
has   close_fr_multi_ledger_only.summary "$(lastline "$ERR")" "장부는 위 forget 명령으로 정리하십시오"

# issue-refs 는 PR 발행의 Closes 줄이 쓰는 같은 검사다 — URL 은 호스트를 남겨 host/owner/repo#N 으로 낸다.
newcase issue_refs_forms
detail 'https://ghe.example.com/a/b/issues/7/, https://github.com/a/b/issues/8, a/b#9, a/b#9'
run issue-refs "$R/detail.md"
check issue_refs_forms.rc "$RC" 0
check issue_refs_forms.out "$OUT" $'ghe.example.com/a/b#7\ngithub.com/a/b#8\na/b#9'

# 한 Issue 가 실패해도 나머지를 닫고, 마지막 줄에 실패와 처리됨을 함께 요약한다.
newcase close_fr_multi_partial
detail 'a/b#9, a/b#7'; resp api_repos_a_b_issues_7 "$(ij open me)"; flag fail api_repos_a_b_issues_9
run close-fr "$R/detail.md" --commit-url "$CURL"
check close_fr_multi_partial.rc "$RC" 7
has   close_fr_multi_partial.close7 "$(glog)" "issue close 7 --repo a/b"
has   close_fr_multi_partial.summary "$(lastline "$ERR")" "Issue 2건 중 실패: Issue 를 조회하지 못했습니다: a/b#9 / 닫음: a/b#7 / 이미 닫혀 건너뜀: 없음"

# 닫음·건너뜀·실패가 섞이면 요약 줄이 셋을 나눠 보인다.
newcase close_fr_multi_mixed
detail 'a/b#7, a/b#9, a/b#10'; resp api_repos_a_b_issues_7 "$(ij open me)"; resp api_repos_a_b_issues_9 "$(ij closed)"; flag fail api_repos_a_b_issues_10
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_multi_mixed.rc "$RC" 7
has   close_fr_multi_mixed.summary "$(lastline "$ERR")" "Issue 3건 중 실패: Issue 를 조회하지 못했습니다: a/b#10 / 닫음: a/b#7 / 이미 닫혀 건너뜀: a/b#9"

# 원격으로 닫은 뒤 장부 정리만 실패해도 요약의 닫음 목록에 남는다. 원격 실패(#9)가 섞이면 rc 는 원격 실패의 rc 다
# (close-fr 재실행이 필요하다). 장부 정리가 실패한 #7 은 ledger-left 줄로 따로 나온다.
newcase close_fr_mixed_lock
detail 'a/b#7, a/b#9'; resp api_repos_a_b_issues_7 "$(ij open me)"; flag fail api_repos_a_b_issues_9
row a/b 7 x > "$RD_ISSUE_LEDGER"
flag mklock_on issue_close
run close-fr "$R/detail.md" --skip-closed --commit-url "$CURL"
check close_fr_mixed_lock.rc "$RC" 7
has   close_fr_mixed_lock.left "$OUT" "ledger-left a/b 7"
has   close_fr_mixed_lock.closed "$(lastline "$ERR")" "/ 닫음: a/b#7 /"
has   close_fr_mixed_lock.ledger "$(lastline "$ERR")" "a/b#7: 장부 행: 남음"

newcase commit_url
needgit
git -C "$R" remote add origin git@github.com:o/r.git
run commit-url abc123
check commit_url "$OUT" "https://github.com/o/r/commit/abc123"

# ---- produce ----
FP='<!-- fingerprint: FP1 -->'
item() { # item <number> <state> <reason|null>
  local r="$3"; [ "$r" != null ] && r="\"$r\""
  printf '{"number":%s,"state":"%s","state_reason":%s,"html_url":"https://github.com/a/b/issues/%s","body":"x\\n%s","labels":[{"name":"rd-defect"}]}' "$1" "$2" "$r" "$1" "$FP"
}
produce() {
  printf 'body text\n' > "$C/body.md"
  run produce --repo a/b --label rd-defect --fingerprint FP1 --title "T" --body-file "$C/body.md"
}

newcase produce_new
resp api_repos_a_b_issues '[]'
produce
check produce_new.rc "$RC" 0
check produce_new.out "$OUT" "created https://github.com/a/b/issues/99"
check produce_new.fp "$(tail -1 "$C/g/body.create")" "$FP"
has   produce_new.query "$(glog)" "labels=rd-defect&state=all"
has   produce_new.paginate "$(glog)" "--paginate"

newcase produce_open
resp api_repos_a_b_issues "[$(item 5 open null)]"
produce
check produce_open "$OUT" "commented https://github.com/a/b/issues/5"

newcase produce_label_encoded
resp api_repos_a_b_issues '[]'
printf 'body text\n' > "$C/body.md"
run produce --repo a/b --label 'a b&c' --fingerprint FP1 --title "T" --body-file "$C/body.md"
has   produce_label_encoded.query "$(glog)" "labels=a%20b%26c&state=all"

newcase produce_completed
resp api_repos_a_b_issues "[$(item 5 closed completed)]"
produce
check produce_completed "$OUT" "created https://github.com/a/b/issues/99 (이전: https://github.com/a/b/issues/5)"

newcase produce_null_reason
resp api_repos_a_b_issues "[$(item 5 closed null)]"
produce
check produce_null_reason "$OUT" "created https://github.com/a/b/issues/99 (이전: https://github.com/a/b/issues/5)"

# 본문 중간에 인용한 fingerprint 는 식별자가 아니다 — 마지막 표식이 다른 Issue 는 같은 생산물로 보지 않는다
newcase produce_quoted_fingerprint_ignored
resp api_repos_a_b_issues '[{"number":5,"state":"closed","state_reason":"not_planned","html_url":"https://github.com/a/b/issues/5","body":"Quoted: <!-- fingerprint: FP1 -->\nOther\n<!-- fingerprint: OTHER -->","labels":[]}]'
produce
check produce_quoted_fingerprint_ignored "$OUT" "created https://github.com/a/b/issues/99"

# 인용 표식 뒤에 일반 본문만 있으면(본문 끝에 표식 없음) 같은 생산물이 아니다
newcase produce_quoted_fingerprint_not_at_end
resp api_repos_a_b_issues '[{"number":5,"state":"closed","state_reason":"not_planned","html_url":"https://github.com/a/b/issues/5","body":"Quoted example: <!-- fingerprint: FP1 -->\nThis is a different issue.","labels":[]}]'
produce
check produce_quoted_fingerprint_not_at_end "$OUT" "created https://github.com/a/b/issues/99"

# 본문 끝 표식 뒤의 공백·CRLF 는 허용한다
newcase produce_fingerprint_trailing_space
resp api_repos_a_b_issues '[{"number":5,"state":"closed","state_reason":"not_planned","html_url":"https://github.com/a/b/issues/5","body":"x\r\n<!-- fingerprint: FP1 -->\r\n  ","labels":[]}]'
produce
check produce_fingerprint_trailing_space "$OUT" "skipped https://github.com/a/b/issues/5"

# 값이 필요한 옵션 뒤에 값이 없으면 무한 반복하지 않고 rc 2 (perl alarm 은 회귀 때 테스트가 멈추지 않게 한다)
newcase option_missing_value
printf 'x\n' > "$C/body.md"
OUT="$(cd "$R" && project_root="$R" perl -e 'alarm 5; exec @ARGV' bash "$TARGET" produce --repo 2>/dev/null)"; RC=$?
check option_missing_value.produce "$RC" 2
detail_f="$C/d.md"; printf -- '- github-issue: a/b#7\n' > "$detail_f"
OUT="$(cd "$R" && project_root="$R" perl -e 'alarm 5; exec @ARGV' bash "$TARGET" close-fr "$detail_f" --commit-url 2>/dev/null)"; RC=$?
check option_missing_value.close_fr "$RC" 2
lacks option_missing_value.nogh "$(glog)" "issue"

newcase produce_not_planned
resp api_repos_a_b_issues "[$(item 5 closed not_planned)]"
produce
check produce_not_planned "$OUT" "skipped https://github.com/a/b/issues/5"
lacks produce_not_planned.nocreate "$(glog)" "issue create"
lacks produce_not_planned.nocomment "$(glog)" "issue comment"

newcase produce_match_on_second_page
printf '%s\n%s\n' '[{"number":3,"state":"open","state_reason":null,"html_url":"u3","body":"other","labels":[]}]' "[$(item 5 open null)]" > "$C/g/resp/api_repos_a_b_issues"
produce
check produce_match_on_second_page "$OUT" "commented https://github.com/a/b/issues/5"
lacks produce_match_on_second_page.nocreate "$(glog)" "issue create"

newcase produce_list_fail_no_create
flag fail api_repos_a_b_issues
produce
check produce_list_fail_no_create.rc "$RC" 7
lacks produce_list_fail_no_create.nocreate "$(glog)" "issue create"
lacks produce_list_fail_no_create.nocomment "$(glog)" "issue comment"

if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS ($PASS checks)"
  exit 0
fi
echo "FAIL ($FAIL failed, $PASS passed)"
exit 1
