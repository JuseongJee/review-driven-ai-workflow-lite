#!/usr/bin/env bash
# fr_do 대화형 지휘 스크립트(grant_check·watch·close·handoff·self_compact) 계약 시험.
# 실행: /bin/bash rd-workflow/scripts/fr_do/test_stream_ops.sh
# 모든 케이스는 mktemp 임시 저장소에서 병렬로 돌고, 실제 herdr 대신 PATH 앞의 가짜 herdr 를 씁니다.
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/fr-do-ops.XXXXXX")" || exit 1
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- 가짜 herdr ----------------------------------------------------------
FB="$T/bin"; mkdir -p "$FB"
cat > "$FB/herdr" <<'FAKE'
#!/bin/bash
# FAKE_DIR 의 파일로 응답합니다. 표준 입력을 끝까지 읽어 소비를 흉내 냅니다(2026-11-07 결함 조건).
cat > /dev/null
d="${FAKE_DIR:?}"
case "$1 $2" in
  "agent get")
    echo . >> "$d/calls"
    [ -f "$d/status.$3" ] || exit 1
    printf '{"result":{"agent":{"agent_status":"%s","pane_id":"%s","tab_id":"t-%s"}}}\n' "$(cat "$d/status.$3")" "p$3" "$3"
    ;;
  "pane read")
    n=$(( $(cat "$d/n.$3" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/n.$3"
    [ -e "$d/fail.$3.$n" ] && exit 1
    f="$d/screen.$3.$n"; [ -f "$f" ] || f="$d/screen.$3"
    [ -f "$f" ] && cat "$f"; exit 0 ;;
  "agent prompt") echo "$*" >> "$d/prompt.log" ;;
  "tab close") echo "$*" >> "$d/tab.log" ;;
esac
exit 0
FAKE
chmod +x "$FB/herdr"
export PATH="$FB:$PATH"
[ "$(command -v herdr)" = "$FB/herdr" ] || { echo "가짜 herdr 가 PATH 맨 앞이 아님"; exit 1; }
unset HERDR_ENV HERDR_PANE_ID HC_TERMINAL_ID

# --- 단언 ----------------------------------------------------------------
P() { echo "PASS $1"; }
F() { echo "FAIL $1: $2"; }
has() { grep -qF -- "$3" "$2" && P "$1 ($3)" || F "$1" "'$3' 없음 — $(tr '\n' '|' < "$2" | cut -c1-300)"; }
count_is() { local c; c="$(grep -cF -- "$3" "$2")"; [ "$c" = "$4" ] && P "$1 ($3 x$4)" || F "$1" "'$3' ${c}회 (기대 $4) — $(tr '\n' '|' < "$2" | cut -c1-300)"; }

# --- 임시 저장소 fixture ---------------------------------------------------
mkrepo() { # $1 디렉터리
  local d="$1"
  mkdir -p "$d/rd-workflow" "$d/rd-workflow-workspace/backlog/items"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t; git -C "$d" config commit.gpgsign false
  cp -R "$SRC" "$d/rd-workflow/scripts"
  touch "$d/rd-workflow-workspace/backlog/items/.gitkeep"
  echo base > "$d/a.txt"; echo base > "$d/CURRENT_TASK.md"
  echo 'rd-workflow-workspace/.lifecycle/fr-do/' > "$d/.gitignore"
  git -C "$d" add -A; git -C "$d" commit -qm init
}
mkwt() { # $1 저장소 $2 slug $3 status — 저장소 밖에 worktree 를 둡니다
  local d="$1" s="$2" st="$3" wt="$1-wt-$2"
  git -C "$d" worktree add -q -b "fr/$s" "$wt"
  mkdir -p "$wt/rd-workflow-workspace/.lifecycle"
  printf 'schema=1\nshort-title=%s\nstatus=%s\nfr-branch=fr/%s\nworktree-path=%s\nsource-fr=-\nreview-session=null\nbase-commit=0\ncreated-at=2026-11-08-0000\n' \
    "$s" "$st" "$s" "$wt" > "$wt/rd-workflow-workspace/.lifecycle/task-state"
  git -C "$wt" add -A; git -C "$wt" commit -qm "task-state"
}
conflict_edit() { # $1 저장소 $2 slug $3 파일 — main 과 fr/<slug> 가 같은 파일을 다르게 고침
  local d="$1" wt="$1-wt-$2"
  echo main-side > "$d/$3"; git -C "$d" commit -qam "main $3"
  echo branch-side > "$wt/$3"; git -C "$wt" commit -qam "branch $3"
}
GC() { bash "$1/rd-workflow/scripts/fr_do/grant_check.sh" "$2"; }

# --- grant_check ----------------------------------------------------------
grant_not_archive_hold() {
  local n=grant_not_archive_hold; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"; mkwt "$r" s1 "구현 중"
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" "HOLD s1"; has "$n" "$o" "아카이브 보류"
}
grant_dirty_main_hold() {
  local n=grant_dirty_main_hold; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"; mkwt "$r" s1 "아카이브 보류"
  echo x > "$r/untracked.txt"
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" "HOLD s1"; has "$n" "$o" "미커밋 변경"
}
grant_dirty_state_dir_hint() {
  local n=grant_dirty_state_dir_hint; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"; mkwt "$r" s1 "아카이브 보류"
  : > "$r/.gitignore"; git -C "$r" commit -qam "무시 줄 제거"
  mkdir -p "$r/rd-workflow-workspace/.lifecycle/fr-do"; echo x > "$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" ".gitignore 에 rd-workflow-workspace/.lifecycle/fr-do/ 를 더하십시오"
}
grant_merging_main_hold() {
  local n=grant_merging_main_hold; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"; mkwt "$r" s1 "아카이브 보류"
  conflict_edit "$r" s1 a.txt
  git -C "$r" merge -q "fr/s1" > /dev/null 2>&1
  [ -e "$r/.git/MERGE_HEAD" ] || { F "$n" "fixture: MERGE_HEAD 안 생김"; return; }
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" "HOLD s1"; has "$n" "$o" "병합 진행 중"
}
grant_conflict_hold() {
  local n=grant_conflict_hold; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"; mkwt "$r" s1 "아카이브 보류"
  conflict_edit "$r" s1 a.txt
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" "HOLD s1"; has "$n" "$o" "자동 해소 대상이 아닌 충돌"
}
grant_mergetree_error_holds() {
  local n=grant_mergetree_error_holds; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"; mkwt "$r" s1 "아카이브 보류"
  git -C "$r" branch -m main trunk   # 기본 브랜치가 main·master 가 아니면 merge-tree 가 ref 를 못 찾습니다
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" "HOLD s1"; has "$n" "$o" "충돌 판정 실패"
}
grant_no_branch_skips_merge() {
  local n=grant_no_branch_skips_merge; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" "HOLD s1"; has "$n" "$o" "충돌 판정 생략 — 로컬 브랜치 fr/s1 가 없습니다"
}
grant_auto_only_ok() {
  local n=grant_auto_only_ok; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"; mkwt "$r" s1 "아카이브 보류"
  conflict_edit "$r" s1 CURRENT_TASK.md
  GC "$r" s1 > "$o" 2>&1; has "$n" "$o" "GRANT-OK s1"
}

# --- watch ----------------------------------------------------------------
# watch_start <이름> — 저장소·가짜 herdr 상태 폴더를 만들고 WR(저장소)·WD(가짜 폴더)·WS(상태 폴더)를 정합니다.
watch_start() {
  WR="$T/$1"; WD="$T/$1.fake"; mkdir -p "$WD"; mkrepo "$WR"
  WR="$(cd "$WR" && pwd -P)"; WS="$WR/rd-workflow-workspace/.lifecycle/fr-do"; mkdir -p "$WS/reports"
  export FAKE_DIR="$WD" RD_FR_DO_WATCH_INTERVAL=1 RD_FR_DO_QUEUE_CMD=true
}
watch_run() { # <출력 파일> — 백그라운드로 띄우고 WPID 에 PID
  bash "$WR/rd-workflow/scripts/fr_do/watch.sh" > "$1" 2>&1 &
  WPID=$!; PIDS="$PIDS $WPID"
}
watch_stop() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# wait_for <파일> <문자열> [횟수=1] [상한초=10] — 문자열이 횟수만큼 나올 때까지 0.2초마다 봅니다(부하가 큰 병렬 실행에서 고정 sleep 을 피함).
wait_for() {
  local i=0 max=$(( ${4:-10} * 5 ))
  while [ "$i" -lt "$max" ]; do
    [ "$(grep -cF -- "$2" "$1" 2>/dev/null)" -ge "${3:-1}" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
# settle <N> — watch 가 감시 반복을 N번 더 돌 때까지 기다립니다(가짜 herdr 의 agent get 호출 수 기준. 부하와 무관한 「그 사이 반복이 있었다」 보장).
settle() {
  local c0 i=0; c0="$(wc -l < "$WD/calls" 2>/dev/null | tr -d ' ')"; c0="${c0:-0}"
  while [ "$i" -lt 100 ]; do
    [ "$(wc -l < "$WD/calls" | tr -d ' ')" -ge $(( c0 + $1 )) ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}
watch_blocked_once() {
  local n=watch_blocked_once; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"
  watch_run "$o"; wait_for "$o" "STREAM s1 idle"; settle 1
  echo blocked > "$WD/status.s1"; wait_for "$o" "STREAM s1 blocked"; settle 2; watch_stop
  count_is "$n" "$o" "STREAM s1 idle" 1; count_is "$n" "$o" "STREAM s1 blocked" 1
}
watch_two_streams_both_seen() {
  local n=watch_two_streams_both_seen; local o="$T/$n.out"; watch_start $n
  printf 's1\t\ns2\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"; echo idle > "$WD/status.s2"
  watch_run "$o"; wait_for "$o" "STREAM s2" 1 6; watch_stop
  has "$n" "$o" "STREAM s1"; has "$n" "$o" "STREAM s2"
}
watch_report_once() {
  local n=watch_report_once; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"
  watch_run "$o"; wait_for "$o" "STREAM s1 idle"
  echo q1 > "$WS/reports/s1-question.md"; wait_for "$o" "REPORT $WS/reports/s1-question.md"
  settle 2; count_is "$n" "$o" "REPORT $WS/reports/s1-question.md" 1
  echo q2 > "$WS/q2.tmp"; touch -t 202601010000 "$WS/q2.tmp"; mv "$WS/q2.tmp" "$WS/reports/s1-question.md"
  wait_for "$o" "REPORT $WS/reports/s1-question.md" 2; settle 2; watch_stop
  count_is "$n" "$o" "REPORT $WS/reports/s1-question.md" 2
}
# 감시 전·감시를 다시 걸기 전 사이에 쓴 보고는 알리고, 이미 알린 보고는 다시 걸어도 알리지 않습니다.
watch_report_across_restart() {
  local n=watch_report_across_restart; local o="$T/$n.out" o2="$T/$n.2.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo working > "$WD/status.s1"
  echo q1 > "$WS/reports/s1-question.md"
  watch_run "$o"; wait_for "$o" "REPORT $WS/reports/s1-question.md"; settle 1; watch_stop
  echo c1 > "$WS/reports/s1-closing.md"
  watch_run "$o2"; wait_for "$o2" "REPORT $WS/reports/s1-closing.md"; settle 2; watch_stop
  count_is "$n" "$o" "REPORT $WS/reports/s1-question.md" 1
  count_is "$n" "$o2" "REPORT $WS/reports/s1-question.md" 0; count_is "$n" "$o2" "REPORT $WS/reports/s1-closing.md" 1
}
# idle → working → idle 이면 두 번째 멈춤도 알립니다. idle → done 전환은 알리지 않습니다.
watch_idle_again_after_working() {
  local n=watch_idle_again_after_working; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"
  watch_run "$o"; wait_for "$o" "STREAM s1 idle"; settle 1
  echo working > "$WD/status.s1"; settle 2
  echo idle > "$WD/status.s1"; wait_for "$o" "STREAM s1 idle" 2; settle 1
  echo done > "$WD/status.s1"; settle 2; watch_stop
  count_is "$n" "$o" "STREAM s1 idle" 2; count_is "$n" "$o" "STREAM s1 done" 0
}
watch_ctx_threshold() {
  local n=watch_ctx_threshold; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"; echo "87% 120k/200k" > "$WD/screen.ps1"
  watch_run "$o"; wait_for "$o" "CTX s1 87%"; settle 2
  echo "40% 80k/200k" > "$WD/screen.ps1"; settle 2
  echo "90% 180k/200k" > "$WD/screen.ps1"; wait_for "$o" "CTX s1 90%"; settle 2; watch_stop
  count_is "$n" "$o" "CTX s1 87%" 1; count_is "$n" "$o" "CTX s1 90%" 1; count_is "$n" "$o" "CTX s1" 2
}
watch_queue_change() {
  local n=watch_queue_change; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"
  printf '#!/bin/bash\ncat "%s"\n' "$T/$n.q" > "$T/$n.q.sh"; : > "$T/$n.q"
  export RD_FR_DO_QUEUE_CMD="bash $T/$n.q.sh"
  watch_run "$o"; wait_for "$o" "STREAM s1 idle"; settle 1
  printf 's1  요청됨\n' > "$T/$n.q"; wait_for "$o" "QUEUE"; settle 2; watch_stop
  count_is "$n" "$o" "QUEUE" 1; has "$n" "$o" "요청됨"
}

# 33자 이상 slug: promote 는 herdr 에이전트 이름을 앞 32자로 자릅니다. 가짜 herdr 는 잘린 이름에만 응답합니다.
LONG=promote-handoff-loses-caller-decisions LONG_AGENT=promote-handoff-loses-caller-dec
watch_long_slug_agent_name() {
  local n=watch_long_slug_agent_name; local o="$T/$n.out"; watch_start $n
  printf '%s\t\n' "$LONG" > "$WS/active.tsv"; echo blocked > "$WD/status.$LONG_AGENT"
  watch_run "$o"; wait_for "$o" "STREAM $LONG"; settle 1; watch_stop
  has "$n" "$o" "STREAM $LONG blocked"; count_is "$n" "$o" "STREAM $LONG gone" 0
}

# --- close ----------------------------------------------------------------
close_not_closed_keeps_row() {
  local n=close_not_closed_keeps_row; local r="$T/$n" o="$T/$n.out" rc; mkrepo "$r"; mkwt "$r" s1 "구현 중"
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR
  mkdir -p "$r/rd-workflow-workspace/.lifecycle/fr-do"; printf 's1\ta;b\ns2\tc\n' > "$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" s1 > "$o" 2>&1; rc=$?
  case "$(tail -1 "$o")" in "NOT-CLOSED s1 ("*) P "$n 마지막 줄";; *) F "$n" "마지막 줄: $(tail -1 "$o")";; esac
  [ "$rc" = 1 ] && P "$n rc=1" || F "$n" "rc=$rc"
  has "$n" "$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv" "s1"
}
close_closed_removes_row() {
  local n=close_closed_removes_row; local r="$T/$n" o="$T/$n.out" rc a; mkrepo "$r"
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR
  a="$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"
  mkdir -p "${a%/*}/reports"; printf 's1\ta;b\ts1-fr\ns2\tc\n' > "$a"
  echo q > "${a%/*}/reports/s1-question.md"; echo c > "${a%/*}/reports/s1-closing.md"; echo o > "${a%/*}/reports/s2-closing.md"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" s1 > "$o" 2>&1; rc=$?
  [ "$(tail -1 "$o")" = "CLOSED s1" ] && P "$n 마지막 줄" || F "$n" "마지막 줄: $(tail -1 "$o")"
  [ "$rc" = 0 ] && P "$n rc=0" || F "$n" "rc=$rc"
  [ "$(cat "$a")" = "$(printf 's2\tc')" ] && P "$n s2 줄만 남음" || F "$n" "active.tsv: $(tr '\t\n' '^|' < "$a")"
  # 보고 파일은 waves/closed/ 로 옮겨지고 다른 줄기 보고는 남습니다.
  [ ! -e "${a%/*}/reports/s1-question.md" ] && [ ! -e "${a%/*}/reports/s1-closing.md" ] && [ -f "${a%/*}/reports/s2-closing.md" ] \
    && P "$n s1 보고만 reports/ 에서 빠짐" || F "$n" "reports: $(ls "${a%/*}/reports" | tr '\n' ' ')"
  [ "$(cat "${a%/*}"/waves/closed/s1-*-closing.md 2>/dev/null)" = c ] && [ "$(cat "${a%/*}"/waves/closed/s1-*-question.md 2>/dev/null)" = q ] \
    && P "$n 보고 보관" || F "$n" "waves/closed: $(ls "${a%/*}/waves/closed" 2>&1 | tr '\n' ' ')"
}

close_long_slug_closes_tab() {
  local n=close_long_slug_closes_tab; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR; echo idle > "$FAKE_DIR/status.$LONG_AGENT"
  mkdir -p "$r/rd-workflow-workspace/.lifecycle/fr-do"; printf '%s\ta\n' "$LONG" > "$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" "$LONG" > "$o" 2>&1
  has "$n" "$o" "탭 닫음: $LONG"; has "$n" "$FAKE_DIR/tab.log" "tab close t-$LONG_AGENT"
}

# --- handoff --------------------------------------------------------------
handoff_generate_paths() {
  local n=handoff_generate_paths; local r="$T/$n" o="$T/$n.out" st h
  mkrepo "$r"; : > "$r/rd-workflow-workspace/backlog/items/2026-11-08-s1-fr.md"
  cat > "$T/$n.json" <<JSON
{"wave":"w1","why":"시험입니다.","streams":[{"slug":"s1","title":"t","frs":["2026-11-08-s1-fr"],
 "owns":"a, b","owns_paths":["a.txt","b/"],"notes":"- n"}]}
JSON
  python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" > "$o" 2>&1 || { F "$n" "handoff.py 실패: $(cat "$o")"; return; }
  st="$(bash -c "source '$r/rd-workflow/scripts/fr_do/_state.sh'; fr_do_state_dir")"
  h="$st/waves/w1/handoff-s1.md"
  [ -f "$h" ] || { F "$n" "인계 파일 없음: $h"; return; }
  has "$n" "$h" "## 발행 방법"; has "$n" "$h" "## 실행 규칙"
  has "$n" "$h" "$st/reports/<slug>-question.md"; has "$n" "$h" "$st/reports/<slug>-closing.md"
  grep -qF '{REPORTS}' "$h" && F "$n" "{REPORTS} 치환자가 남음" || P "$n 치환자 없음"
}

handoff_bad_slug_rejected() {
  local n=handoff_bad_slug_rejected; local r="$T/$n" o="$T/$n.out" rc
  mkrepo "$r"
  echo '{"wave":"w1","why":"x","streams":[{"slug":"../x","title":"t","frs":[],"owns":"a","notes":"-"}]}' > "$T/$n.json"
  python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" > "$o" 2>&1; rc=$?
  [ "$rc" = 2 ] && P "$n rc=2" || F "$n" "rc=$rc (기대 2) — $(cat "$o")"
  [ -e "$r/rd-workflow-workspace/.lifecycle/x" ] && F "$n" "경로 이탈 산출물 생성" || P "$n 이탈 산출물 없음"
}

handoff_launch_verdict() {
  local n=handoff_launch_verdict r
  r="$(cd "$SRC/fr_do" && python3 -I -B -c '
import importlib.util,sys
sp=importlib.util.spec_from_file_location("h","handoff.py"); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
v=m.launch_verdict
print(v(0,["promote: 세션 기동 결과 — failed (x)"])[1], v(0,["promote: 세션 기동 결과 — ok (x)"])[1],
      v(0,["promote: 기동 결과를 기록할 락을 얻지 못했습니다 — launching 상태로 남습니다.","promote: 세션 기동 성공 / 상태 기록 미완료 — x"]),
      v(1,["promote: 세션 기동 결과 — ok (x)"])[1])
' 2>&1)"
  case "$r" in
    "False True ('promote: 세션 기동 성공 / 상태 기록 미완료 — x', True) False") P "$n failed 미등록·ok 등록·기록 미완료 요약·rc≠0 미등록" ;;
    *) F "$n" "$r" ;;
  esac
}

handoff_active_row() {
  local n=handoff_active_row r
  r="$(cd "$SRC/fr_do" && python3 -I -B -c '
import importlib.util
sp=importlib.util.spec_from_file_location("h","handoff.py"); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(repr(m.active_row({"slug":"s1","owns_paths":["a.txt","b/"],"frs":["2026-11-08-x","2026-11-08-y"]})))
' 2>&1)"
  [ "$r" = "'s1\\ta.txt;b/\\t2026-11-08-x;2026-11-08-y\\n'" ] && P "$n slug·경로·FR stem 3칸" || F "$n" "$r"
}

# --- self_compact ---------------------------------------------------------
SCR_OK=$'❯ \n87% 174k/200k'
# sc_run <이름> <대기초> — SC_OUT(마지막 줄) 과 prompt 횟수 SC_N 을 정합니다. 호출 전에 $T/$name.fake 에 상태·화면을 둡니다.
sc_run() {
  local d="$T/$1.fake"
  FAKE_DIR="$d" HERDR_PANE_ID=p1 RD_FR_DO_COMPACT_POLL=1 bash "$SRC/fr_do/self_compact.sh" 80 "$2" > "$T/$1.out" 2>&1
  SC_OUT="$(tail -1 "$T/$1.out")"; SC_N="$(grep -c . "$d/prompt.log" 2>/dev/null || true)"; SC_N="${SC_N:-0}"
}
sc_case() { mkdir -p "$T/$1.fake"; echo "$2" > "$T/$1.fake/status.p1"; }
sc_expect() { # <이름> <마지막 줄 접두> <prompt 횟수>
  case "$SC_OUT" in "$2"*) P "$1 ($2)";; *) F "$1" "마지막 줄 '$SC_OUT' (기대 '$2')";; esac
  [ "$SC_N" = "$3" ] && P "$1 prompt ${3}회" || F "$1" "prompt ${SC_N}회 (기대 $3)"
}
compact_sent() {
  local n=compact_sent d="$T/compact_sent.fake"; sc_case $n idle; printf '%s\n' "$SCR_OK" > "$d/screen.p1"
  sc_run $n 5; sc_expect $n "SENT 87%" 1; has $n "$d/prompt.log" "/compact"
}
compact_below_limit() {
  local n=compact_below_limit d="$T/compact_below_limit.fake"; sc_case $n idle; printf '❯ \n40%% 80k/200k\n' > "$d/screen.p1"
  sc_run $n 5; sc_expect $n "SKIP 컨텍스트 40% < 80%" 0
}
compact_typing_waits() {
  local n=compact_typing_waits d="$T/compact_typing_waits.fake"; sc_case $n idle; printf '❯ 안녕\n87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한" 0
}
compact_working() {
  local n=compact_working d="$T/compact_working.fake"; sc_case $n working; printf '%s\n' "$SCR_OK" > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP" 0
}
compact_unreadable() {
  local n=compact_unreadable d="$T/compact_unreadable.fake"; sc_case $n idle; printf '❯ \n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP" 0
}
compact_recheck_typing() {
  local n=compact_recheck_typing d="$T/compact_recheck_typing.fake"; sc_case $n idle
  printf '%s\n' "$SCR_OK" > "$d/screen.p1.1"; printf '❯ a\n87%% 174k/200k\n' > "$d/screen.p1.2"; printf '❯ a\n87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP" 0
}
compact_missing_input_line() {
  # 첫 판독: 입력줄 없음. 둘째 판독: 빈 입력(다음 회차의 첫 판독). 셋째 이후(재확인): 글자 있음.
  local n=compact_missing_input_line d="$T/compact_missing_input_line.fake"; sc_case $n idle
  printf '87%% 174k/200k\n' > "$d/screen.p1.1"; printf '%s\n' "$SCR_OK" > "$d/screen.p1.2"; printf '❯ x\n87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP" 0
}
compact_recheck_read_fail() {
  local n=compact_recheck_read_fail d="$T/compact_recheck_read_fail.fake"; sc_case $n idle
  printf '%s\n' "$SCR_OK" > "$d/screen.p1.1"; : > "$d/fail.p1.2"; printf '❯ x\n87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP" 0
}
compact_recheck_line_gone() {
  local n=compact_recheck_line_gone d="$T/compact_recheck_line_gone.fake"; sc_case $n idle
  printf '%s\n' "$SCR_OK" > "$d/screen.p1.1"; printf '87%% 174k/200k\n' > "$d/screen.p1.2"; printf '87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP" 0
}

CASES="grant_not_archive_hold grant_dirty_main_hold grant_dirty_state_dir_hint grant_merging_main_hold grant_conflict_hold grant_mergetree_error_holds grant_no_branch_skips_merge grant_auto_only_ok
watch_blocked_once watch_two_streams_both_seen watch_report_once watch_report_across_restart watch_idle_again_after_working watch_ctx_threshold watch_queue_change watch_long_slug_agent_name
close_not_closed_keeps_row close_closed_removes_row close_long_slug_closes_tab handoff_generate_paths handoff_bad_slug_rejected handoff_launch_verdict handoff_active_row
compact_sent compact_below_limit compact_typing_waits compact_working compact_unreadable compact_recheck_typing compact_missing_input_line compact_recheck_read_fail compact_recheck_line_gone"
# 환경변수(FAKE_DIR 등)가 섞이지 않게 케이스마다 서브셸로 병렬 실행합니다.
for c in $CASES; do ( "$c" ) > "$T/log.$c" 2>&1 & PIDS="$PIDS $!"; done
wait
fail=0
# PASS 로 시작하지 않는 줄(FAIL·셸 오류)이 하나라도 있거나 PASS 가 없는 케이스는 실패입니다.
for c in $CASES; do
  cat "$T/log.$c"
  grep -qv '^PASS' "$T/log.$c" && { echo "FAIL $c: PASS 가 아닌 출력이 있음"; fail=1; }
  grep -q '^PASS' "$T/log.$c" || { echo "FAIL $c: PASS 없음"; fail=1; }
done > "$T/all"
cat "$T/all"
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
