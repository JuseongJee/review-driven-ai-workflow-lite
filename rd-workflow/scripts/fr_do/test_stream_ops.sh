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
    pn="p$3"; [ -f "$d/pane.$3" ] && pn="$(cat "$d/pane.$3")"
    printf '{"result":{"agent":{"agent_status":"%s","pane_id":"%s","tab_id":"t-%s"}}}\n' "$(cat "$d/status.$3")" "$pn" "$3"
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
unset HERDR_ENV HERDR_PANE_ID HC_TERMINAL_ID ORCA_AGENT_SESSION_ID ORCA_TERMINAL_HANDLE

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
  # watch 는 로컬 브랜치 fr/<slug> 가 있는 줄기만 감시합니다. 케이스가 쓰는 줄기 이름의 브랜치를 만듭니다.
  git -C "$WR" branch fr/s1; git -C "$WR" branch fr/s2; git -C "$WR" branch "fr/$LONG"
  export FAKE_DIR="$WD" RD_FR_DO_WATCH_INTERVAL=1 RD_FR_DO_QUEUE_CMD=true
}
watch_run() { # <출력 파일> — 백그라운드로 띄우고 WPID 에 PID
  bash "$WR/rd-workflow/scripts/fr_do/watch.sh" > "$1" 2>&1 &
  WPID=$!; PIDS="$PIDS $WPID"
}
watch_stop() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }

# 대기 상한은 결함 판정 기준이 아니라 멈춤 방지 장치입니다. 기다리는 신호는 정상이면 반드시 오므로 상한은 결함일 때만 닿습니다.
# 병렬 self_test 부하에서 watch 기동이 10초를 넘겨 대기가 먼저 끝나고 뒤 단언이 FAIL 했으므로 60초로 둡니다.
# 상한에 닿으면 그 사실을 PASS 가 아닌 줄로 남기고 watch 를 멈춘 뒤 그 케이스를 끝냅니다(케이스는 서브셸에서 돕니다).
# 뒤 대기를 이어 가면 대기마다 상한을 다 써서 실패 보고가 몇 분씩 늦어집니다.
WAIT_CAP=60
# wait_for <파일> <문자열> [횟수=1] — 문자열이 횟수만큼 나올 때까지 0.2초마다 봅니다(부하가 큰 병렬 실행에서 고정 sleep 을 피함).
# watch_run 의 출력 파일은 백그라운드 자식이 열므로 첫 대기 때 아직 없을 수 있습니다. 그때 grep -c 는 아무것도 내지 않으므로 0 으로 셉니다.
wait_for() {
  local i=0 max=$(( WAIT_CAP * 5 )) c
  while [ "$i" -lt "$max" ]; do
    c="$(grep -cF -- "$2" "$1" 2>/dev/null)"; [ "${c:-0}" -ge "${3:-1}" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  echo "WAIT-TIMEOUT wait_for '$2' x${3:-1} (${WAIT_CAP}초)"; watch_stop; exit 1
}
# settle <N> — watch 가 감시 반복을 N번 더 돌 때까지 기다립니다(가짜 herdr 의 agent get 호출 수 기준. 부하와 무관한 「그 사이 반복이 있었다」 보장).
settle() {
  local c0 c i=0; c0="$(wc -l 2>/dev/null < "$WD/calls" | tr -d ' ')"; c0="${c0:-0}"
  while [ "$i" -lt $(( WAIT_CAP * 5 )) ]; do
    c="$(wc -l 2>/dev/null < "$WD/calls" | tr -d ' ')"; [ "${c:-0}" -ge $(( c0 + $1 )) ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  echo "WAIT-TIMEOUT settle $1 (${WAIT_CAP}초)"; watch_stop; exit 1
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
  watch_run "$o"; wait_for "$o" "STREAM s2"; watch_stop
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
# ctx_screen <상태줄> — 입력줄(❯) 아래에 상태줄이 있는 화면을 씁니다(감시는 입력줄 아래에서만 비율을 읽음).
ctx_screen() { printf '❯ \n  %s\n' "$1" > "$WD/screen.ps1"; }
# ctx_lines <출력 파일> — CTX 줄을 순서대로 "|" 로 잇고 숫자 구간 ID 는 " @ID" 로 바꿉니다(ID 가 없는 줄은 그대로 남아 비교에서 걸림).
ctx_lines() { grep '^CTX ' "$1" | sed 's/ @[0-9][0-9]*$/ @ID/' | tr '\n' '|'; }
# ctx_ids <출력 파일> — CTX 줄의 구간 ID 를 중복 없이 셉니다.
ctx_ids() { grep '^CTX ' "$1" | grep -o '@[0-9]*$' | sort -u | wc -l | tr -d ' '; }
same() { [ "$3" = "$4" ] && P "$1 ($2)" || F "$1" "$2: '$3' (기대 '$4')"; }
watch_ctx_threshold() {
  local n=watch_ctx_threshold; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"; ctx_screen "87% 120k/200k"
  watch_run "$o"; wait_for "$o" "CTX s1 87%"; settle 2
  ctx_screen "40% 80k/200k"; settle 2
  ctx_screen "90% 180k/200k"; wait_for "$o" "CTX s1 90%"; settle 2; watch_stop
  count_is "$n" "$o" "CTX s1 87%" 1; count_is "$n" "$o" "CTX s1 90%" 1; count_is "$n" "$o" "CTX s1" 2
}
# working 중에도 문턱(85)에서 한 번, 긴급 문턱(100)에서 한 번 알립니다(경계값 정확히 85%·100% 로 확인). 긴급 뒤 100% 이상이 이어지거나 idle 로 바뀌어도,
# 감시를 다시 걸어도 다시 알리지 않습니다. 입력줄(❯) 위 작업 출력의 수치와 입력줄이 없는 화면은 읽지 않습니다.
# 같은 구간의 두 줄은 같은 구간 ID 를 씁니다. 문턱 아래에서 바로 긴급 문턱을 넘으면 문턱 줄·긴급 줄 순서로 함께 냅니다.
# 같은 slug 로 새 줄기(다른 pane)를 띄우면 이전 줄기의 알림 기록을 이어받지 않습니다.
watch_ctx_working() {
  local n=watch_ctx_working; local o="$T/$n.out" o2="$T/$n.2.out" o3="$T/$n.3.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo working > "$WD/status.s1"
  # 대화 기록의 지난 입력도 ❯ 로 시작합니다. 마지막 ❯(입력줄) 아래만 상태줄 영역입니다.
  printf '❯ 지난 입력\n본문 예시 103%% 412k/400k\n❯ \n' > "$WD/screen.ps1"
  : > "$WD/calls"; watch_run "$o"; settle 3
  printf '본문 예시 103%% 412k/400k\n' > "$WD/screen.ps1"; settle 3
  printf '본문 예시 103%% 412k/400k\n❯ \n  85%% 340k/400k\n' > "$WD/screen.ps1"; wait_for "$o" "CTX s1 85% working"; settle 2
  ctx_screen "100% 400k/400k"; wait_for "$o" "CTX s1 100% working 긴급"; settle 2
  ctx_screen "105% 420k/400k"; settle 2
  echo idle > "$WD/status.s1"; wait_for "$o" "STREAM s1 idle"; settle 2; watch_stop
  watch_run "$o2"; wait_for "$o2" "STREAM s1 idle"; settle 2
  ctx_screen "40% 160k/400k"; settle 2
  ctx_screen "104% 416k/400k"; wait_for "$o2" "CTX s1 104% idle 긴급"; settle 2; watch_stop
  echo ps1-new > "$WD/pane.s1"; printf '❯ \n  100%% 400k/400k\n' > "$WD/screen.ps1-new"
  watch_run "$o3"; wait_for "$o3" "CTX s1 100% idle 긴급"; settle 2; watch_stop
  same "$n" "1차 CTX 순서" "$(ctx_lines "$o")" "CTX s1 85% working @ID|CTX s1 100% working 긴급 @ID|"
  same "$n" "1차 구간 ID 수" "$(ctx_ids "$o")" 1
  same "$n" "재등록 CTX 순서" "$(ctx_lines "$o2")" "CTX s1 104% idle @ID|CTX s1 104% idle 긴급 @ID|"
  same "$n" "재등록 구간 ID 수" "$(ctx_ids "$o2")" 1
  same "$n" "새 줄기 CTX 순서" "$(ctx_lines "$o3")" "CTX s1 100% idle @ID|CTX s1 100% idle 긴급 @ID|"
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
# 상태 단어는 「→」 앞에서만 찾습니다 — 다음 행동에 든 worktree 경로의 단어로 허가됨·부분 완료 줄이 걸리지 않습니다.
watch_queue_ignores_action_path() {
  local n=watch_queue_ignores_action_path; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"
  printf '#!/bin/bash\ncat "%s"\n' "$T/$n.q" > "$T/$n.q.sh"
  printf 'g1  허가됨  -  → 작업 worktree(/x/승인-w)에서 rd publish run\np1  부분 완료  -  → 작업 worktree(/x/진행중/w)에서 rd publish run 으로 복구\n' > "$T/$n.q"
  export RD_FR_DO_QUEUE_CMD="bash $T/$n.q.sh"
  watch_run "$o"; wait_for "$o" "STREAM s1 idle"; settle 2
  printf 'g1  허가됨  -  → 작업 worktree(/x/승인-w)에서 rd publish run\ns1  요청됨  -  → 호출 세션이 rd publish next 로 허가\n' > "$T/$n.q"
  wait_for "$o" "QUEUE"; settle 2; watch_stop
  count_is "$n" "$o" "QUEUE" 1; count_is "$n" "$o" "QUEUE s1  요청됨  -  → 호출 세션이 rd publish next 로 허가" 1
}

# 감시가 도는 동안 발행 큐에 생존 표시(who=fr-do)를 남깁니다(작업 세션의 감시 없음 경고 근거).
watch_beats_queue() {
  local n=watch_beats_queue; local o="$T/$n.out" w i=0; watch_start $n
  w="$WR/.git/rd-workflow/publish-queue/WATCH"
  watch_run "$o"
  while [ "$i" -lt $(( WAIT_CAP * 5 )) ] && ! grep -q '^who=fr-do$' "$w" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
  watch_stop
  [ "$i" -lt $(( WAIT_CAP * 5 )) ] || { echo "WAIT-TIMEOUT 생존 표시 who=fr-do (${WAIT_CAP}초)"; return; }
  grep -q '^who=fr-do$' "$w" 2>/dev/null && grep -q '^at=[0-9]*$' "$w" && P "$n (생존 표시 who=fr-do)" || F "$n" "생존 표시 없음 — $(cat "$w" 2>&1 | tr '\n' '|')"
}

# 큐를 읽지 못하면 조회 실패를 한 번 알리고 생존 표시를 남기지 않습니다(감시가 정상인 것처럼 보이지 않게).
watch_queue_fail_no_beat() {
  local n=watch_queue_fail_no_beat; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"
  export RD_FR_DO_QUEUE_CMD='echo "큐 깨짐" >&2; exit 3'
  watch_run "$o"; wait_for "$o" "QUEUE 조회 실패"; settle 2; watch_stop
  count_is "$n" "$o" "QUEUE 조회 실패 (rc=3): 큐 깨짐" 1
  [ ! -e "$WR/.git/rd-workflow/publish-queue/WATCH" ] && P "$n (생존 표시 없음)" || F "$n" "조회 실패인데 생존 표시가 있음"
}

# 조회 실패 뒤 회복하면 실패 전과 같은 큐 줄이어도 다시 알립니다(호출 세션이 허가 점검을 이어 가는 신호).
watch_queue_recover_reemits() {
  local n=watch_queue_recover_reemits; local o="$T/$n.out"; watch_start $n
  printf 's1\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"
  printf 's1  요청됨\n' > "$T/$n.q"
  printf '#!/bin/bash\n[ -e "%s" ] && { echo 깨짐 >&2; exit 3; }\ncat "%s"\n' "$T/$n.fail" "$T/$n.q" > "$T/$n.q.sh"
  export RD_FR_DO_QUEUE_CMD="bash $T/$n.q.sh"
  watch_run "$o"; wait_for "$o" "QUEUE s1"
  touch "$T/$n.fail"; wait_for "$o" "QUEUE 조회 실패"
  rm -f "$T/$n.fail"; wait_for "$o" "QUEUE s1" 2; settle 2; watch_stop
  count_is "$n" "$o" "QUEUE s1  요청됨" 2; count_is "$n" "$o" "QUEUE 조회 실패" 1
}

# 33자 이상 slug: promote 는 herdr 에이전트 이름을 앞 32자로 자릅니다. 가짜 herdr 는 잘린 이름에만 응답합니다.
LONG=promote-handoff-loses-caller-decisions LONG_AGENT=promote-handoff-loses-caller-dec
watch_long_slug_agent_name() {
  local n=watch_long_slug_agent_name; local o="$T/$n.out"; watch_start $n
  printf '%s\t\n' "$LONG" > "$WS/active.tsv"; echo blocked > "$WD/status.$LONG_AGENT"
  watch_run "$o"; wait_for "$o" "STREAM $LONG"; settle 1; watch_stop
  has "$n" "$o" "STREAM $LONG blocked"; count_is "$n" "$o" "STREAM $LONG gone" 0
}
# 로컬 브랜치 fr/<slug> 가 없는 줄(끝난 줄기의 낡은 줄)은 세션을 읽지 않고 STREAM 도 내지 않습니다.
watch_stale_row_skipped() {
  local n=watch_stale_row_skipped; local o="$T/$n.out"; watch_start $n
  printf 's1\t\ngone\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"; echo idle > "$WD/status.gone"
  watch_run "$o"; wait_for "$o" "STREAM s1 idle"; settle 2; watch_stop
  count_is "$n" "$o" "STREAM gone" 0
}
# 낡은 줄로 건너뛴 뒤 같은 slug 가 다시 뜨면 첫 상태를 다시 알립니다(이전 상태 기억을 지움).
#   s1 이 건너뛰어지는 동안 반복 수는 s2 조회로 셉니다.
watch_stale_then_relaunch_reports() {
  local n=watch_stale_then_relaunch_reports; local o="$T/$n.out"; watch_start $n
  printf 's1\t\ns2\t\n' > "$WS/active.tsv"; echo idle > "$WD/status.s1"; echo working > "$WD/status.s2"
  watch_run "$o"; wait_for "$o" "STREAM s1 idle"
  git -C "$WR" branch -D -q fr/s1; settle 3
  git -C "$WR" branch fr/s1; wait_for "$o" "STREAM s1 idle" 2; watch_stop
  count_is "$n" "$o" "STREAM s1 idle" 2
}

# --- close ----------------------------------------------------------------
# 줄 삭제는 문자열 비교입니다. awk 숫자 비교면 slug 1 을 닫을 때 01 줄도 지웁니다.
close_numeric_slug_string_compare() {
  local n=close_numeric_slug_string_compare; local r="$T/$n" o="$T/$n.out" a; mkrepo "$r"
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR
  a="$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"; mkdir -p "${a%/*}"; printf '01\ta\n1\tb\n' > "$a"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" 1 > "$o" 2>&1
  has "$n" "$o" "CLOSED 1"
  [ "$(cat "$a")" = "$(printf '01\ta')" ] && P "$n 01 줄만 남음" || F "$n" "active.tsv: $(tr '\t\n' '^|' < "$a")"
}
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
# --stale 정리는 로컬 브랜치 fr/<slug> 가 다시 있으면(같은 slug 로 다시 띄움) 탭·목록을 건드리지 않습니다.
close_stale_branch_back_keeps_tab() {
  local n=close_stale_branch_back_keeps_tab; local r="$T/$n" o="$T/$n.out" rc a; mkrepo "$r"; git -C "$r" branch fr/s1
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR; echo idle > "$FAKE_DIR/status.s1"
  a="$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"; mkdir -p "${a%/*}"; printf 's1\ta\n' > "$a"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" s1 --stale > "$o" 2>&1; rc=$?
  has "$n" "$o" "NOT-CLOSED s1 (로컬 브랜치 fr/s1 가 다시 있음"; [ "$rc" = 1 ] && P "$n rc=1" || F "$n" "rc=$rc"
  [ ! -e "$FAKE_DIR/tab.log" ] && P "$n 탭 닫지 않음" || F "$n" "tab.log: $(cat "$FAKE_DIR/tab.log")"
  has "$n" "$a" "s1"
}
# --stale 확인은 git pull 뒤에 합니다. pull 이 시작될 때 브랜치가 없고 pull 중(post-merge)에 생기면 탭을 닫지 않습니다.
close_stale_branch_back_during_pull() {
  local n=close_stale_branch_back_during_pull; local r="$T/$n" o="$T/$n.out" a; mkrepo "$r"
  git clone -q --bare "$r" "$r.git"; git -C "$r" remote add origin "$r.git"; git -C "$r" fetch -q origin; git -C "$r" branch -q -u origin/main main
  git clone -q "$r.git" "$r.up"; git -C "$r.up" -c user.name=t -c user.email=t@t commit -q --allow-empty -m up; git -C "$r.up" push -q origin HEAD:main
  printf '#!/bin/sh\ngit branch fr/s1\n' > "$r/.git/hooks/post-merge"; chmod +x "$r/.git/hooks/post-merge"
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR; echo idle > "$FAKE_DIR/status.s1"
  a="$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"; mkdir -p "${a%/*}"; printf 's1\ta\n' > "$a"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" s1 --stale > "$o" 2>&1
  has "$n" "$o" "NOT-CLOSED s1 (로컬 브랜치 fr/s1 가 다시 있음"
  [ ! -e "$FAKE_DIR/tab.log" ] && P "$n 탭 닫지 않음" || F "$n" "tab.log: $(cat "$FAKE_DIR/tab.log")"
  has "$n" "$a" "s1"
}
# --stale 은 탭을 닫지 않습니다. 에이전트 이름으로 찾은 탭이 다른 줄기(다른 체크아웃 포함)의 것일 수 있습니다.
close_stale_never_closes_tab() {
  local n=close_stale_never_closes_tab; local r="$T/$n" o="$T/$n.out" a; mkrepo "$r"
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR; echo working > "$FAKE_DIR/status.s1"
  a="$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"; mkdir -p "${a%/*}"; printf 's1\ta\n' > "$a"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" s1 --stale > "$o" 2>&1
  has "$n" "$o" "탭 건드리지 않음: s1"; has "$n" "$o" "CLOSED s1"
  [ ! -e "$FAKE_DIR/tab.log" ] && P "$n 탭 닫지 않음" || F "$n" "tab.log: $(cat "$FAKE_DIR/tab.log")"
}
# rd task list 가 다른 작업의 탭을 닫은 줄(「탭 닫음: <그 작업>」)은 close.sh 출력으로 넘어갑니다. rd 는 대역입니다.
close_passes_task_list_tab_note() {
  local n=close_passes_task_list_tab_note; local r="$T/$n" o="$T/$n.out"; mkrepo "$r"
  FAKE_DIR="$T/$n.fake"; mkdir -p "$FAKE_DIR"; export FAKE_DIR
  printf '#!/bin/bash\necho "탭 닫음: other"\necho "무관한 줄"\n' > "$r/rd-workflow/scripts/rd"
  mkdir -p "$r/rd-workflow-workspace/.lifecycle/fr-do"; printf 's1\ta\n' > "$r/rd-workflow-workspace/.lifecycle/fr-do/active.tsv"
  bash "$r/rd-workflow/scripts/fr_do/close.sh" s1 --stale > "$o" 2>&1
  has "$n" "$o" "탭 닫음: other"; grep -qF "무관한 줄" "$o" && F "$n" "무관한 줄이 넘어옴" || P "$n 무관한 줄 거름"
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

handoff_design_qa() {
  # 설계 문답을 고른 회차만 인계 파일에 그 절이 붙어야 합니다. 빠지면 줄기가 설계 질문을 스스로 정합니다.
  local n=handoff_design_qa; local r="$T/$n" o="$T/$n.out" st
  mkrepo "$r"; : > "$r/rd-workflow-workspace/backlog/items/2026-11-08-s1-fr.md"
  for q in on off; do
    if [ "$q" = on ]; then dq=',"design_qa":true'; else dq=''; fi
    printf '{"wave":"%s","why":"x","streams":[{"slug":"s1","title":"t","frs":["2026-11-08-s1-fr"],"owns":"a","notes":"- n"}]%s}\n' "w-$q" "$dq" > "$T/$n.$q.json"
    python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.$q.json" > "$o" 2>&1 || { F "$n" "handoff.py 실패($q): $(cat "$o")"; return; }
  done
  st="$(bash -c "source '$r/rd-workflow/scripts/fr_do/_state.sh'; fr_do_state_dir")"
  has "$n" "$st/waves/w-on/handoff-s1.md" "## 설계 문답"
  has "$n" "$st/waves/w-on/handoff-s1.md" "$st/reports/s1-question.md"
  has "$n" "$st/waves/w-on/handoff-s1.md" "사용자 직접 답변 — 호출 세션은 답하지 않음"
  has "$n" "$st/waves/w-on/handoff-s1.md" "「설계·스펙 승인 대기 생략」 보다 이 절이 우선합니다"
  has "$n" "$st/waves/w-on/handoff-s1.md" "첫 줄을 「사용자 직접 답변 — 답변 완료」 으로 바꾸고"
  grep -qF "## 설계 문답" "$st/waves/w-off/handoff-s1.md" && F "$n" "design_qa 없는 회차에 설계 문답 절이 붙음" || P "$n 미선택 회차에는 절 없음"
}

handoff_bad_slug_rejected() {
  local n=handoff_bad_slug_rejected; local r="$T/$n" o="$T/$n.out" rc
  mkrepo "$r"
  echo '{"wave":"w1","why":"x","streams":[{"slug":"../x","title":"t","frs":[],"owns":"a","notes":"-"}]}' > "$T/$n.json"
  python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" > "$o" 2>&1; rc=$?
  [ "$rc" = 2 ] && P "$n rc=2" || F "$n" "rc=$rc (기대 2) — $(cat "$o")"
  [ -e "$r/rd-workflow-workspace/.lifecycle/x" ] && F "$n" "경로 이탈 산출물 생성" || P "$n 이탈 산출물 없음"
}

fake_promote() { # $1 저장소 — 받은 RD_SESSION_* 를 promote 의 적용 줄 형식으로 냅니다
  cat > "$1/rd-workflow/scripts/lifecycle/promote.sh" <<'FAKE'
#!/bin/bash
echo "promote: 다음 기동에 사용할 모델 — ${RD_SESSION_MODEL-없음} · effort — ${RD_SESSION_EFFORT-없음}"
echo "promote: 세션 기동 결과 — ok (가짜)"
FAKE
}

handoff_launch_session_env() {
  # 줄기 항목의 model·effort 가 그 줄기 promote 에만 가야 합니다. 새면 칸이 빈 줄기도 남의 값으로 뜹니다.
  local n=handoff_launch_session_env; local r="$T/$n" o="$T/$n.out"
  mkrepo "$r"; fake_promote "$r"
  : > "$r/rd-workflow-workspace/backlog/items/2026-11-08-s1-fr.md"; : > "$r/rd-workflow-workspace/backlog/items/2026-11-08-s2-fr.md"
  cat > "$T/$n.json" <<JSON
{"wave":"w1","why":"x","streams":[
 {"slug":"s1","title":"t","frs":["2026-11-08-s1-fr"],"owns":"a","notes":"- n","model":"opus","effort":"xhigh"},
 {"slug":"s2","title":"t","frs":["2026-11-08-s2-fr"],"owns":"b","notes":"- n"}]}
JSON
  (unset RD_SESSION_MODEL RD_SESSION_EFFORT; python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" --launch) > "$o" 2>&1 \
    || { F "$n" "handoff.py 실패: $(cat "$o")"; return; }
  has "$n" "$o" "s1: 다음 기동에 사용할 모델 — opus · effort — xhigh"
  has "$n" "$o" "s2: 다음 기동에 사용할 모델 — 없음 · effort — 없음"
}

handoff_bad_session_value_rejected() {
  # 값 하나가 틀리면 어느 줄기도 띄우지 않아야 합니다. 일부만 뜨면 회차가 반쯤 시작된 채 남습니다.
  local n=handoff_bad_session_value_rejected; local r="$T/$n" o="$T/$n.out" rc st
  mkrepo "$r"; fake_promote "$r"
  : > "$r/rd-workflow-workspace/backlog/items/2026-11-08-s1-fr.md"
  cat > "$T/$n.json" <<JSON
{"wave":"w1","why":"x","streams":[
 {"slug":"s1","title":"t","frs":["2026-11-08-s1-fr"],"owns":"a","notes":"- n","model":"opuz","effort":"high"},
 {"slug":"s2","title":"t","frs":["2026-11-08-s1-fr"],"owns":"b","notes":"- n","model":"opus","effort":"huge"}]}
JSON
  python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" --launch > "$o" 2>&1; rc=$?
  [ "$rc" = 2 ] && P "$n rc=2" || F "$n" "rc=$rc (기대 2) — $(cat "$o")"
  has "$n" "$o" "s1: model 'opuz'"
  has "$n" "$o" "s2: effort 'huge'"
  grep -qF "s1: effort" "$o" && F "$n" "올바른 effort 를 거부함" || P "$n 올바른 값은 거부하지 않음"
  st="$(bash -c "source '$r/rd-workflow/scripts/fr_do/_state.sh'; fr_do_state_dir")"
  [ -e "$st/waves/w1/promote.log" ] && F "$n" "promote 를 불렀음" || P "$n promote 부르지 않음"
}

handoff_wave_reserved() {
  # 이미 있는 wave 는 거부해야 합니다. 겹치면 두 /fr do 호출의 회차 값이 한 회차로 섞입니다.
  local n=handoff_wave_reserved; local r="$T/$n" o="$T/$n.out" rc
  mkrepo "$r"; : > "$r/rd-workflow-workspace/backlog/items/2026-11-08-s1-fr.md"
  echo '{"wave":"w1","why":"x","streams":[{"slug":"s1","title":"t","frs":["2026-11-08-s1-fr"],"owns":"a","notes":"- n"}]}' > "$T/$n.json"
  python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" > "$o" 2>&1 || { F "$n" "첫 실행 실패: $(cat "$o")"; return; }
  python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" > "$o" 2>&1; rc=$?
  [ "$rc" = 2 ] && P "$n 두 번째 rc=2" || F "$n" "rc=$rc (기대 2) — $(cat "$o")"
  has "$n" "$o" "wave 가 이미 있습니다"
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

handoff_launch_dup_lines() {
  # promote 가 내는 멈춤·경고·착수 표시 줄이 줄기 줄 뒤에 그대로 보여야 합니다. 사용자는 이 출력으로 원격 표시 상태를 봅니다.
  local n=handoff_launch_dup_lines; local r="$T/$n" o="$T/$n.out" i
  mkrepo "$r"
  cat > "$r/rd-workflow/scripts/lifecycle/promote.sh" <<'FAKE'
#!/bin/bash
case "$2" in
s1) echo "promote: 중복 착수 — 's1' 를 시작하지 않았습니다 (상태 변경 없음)."; echo "  - 다른 clone 이 착수했습니다: 원격 fr/s1"; echo "  되돌리기: x"; exit 1 ;;
s2) echo "promote: 중복 확인 경고 — 착수 표시를 원격에 올리지 못했습니다(net)."; echo "promote: 세션 기동 결과 — ok (가짜)" ;;
s3) echo "promote: 착수 표시 — origin 의 fr/s3 에 착수 커밋(abc1234)을 올렸습니다."; echo "promote: 세션 기동 결과 — ok (가짜)" ;;
s4) echo "promote: 착수 표시 — origin 의 fr/s4 에 이미 이 작업의 착수 표시가 있습니다(abc1234)."; echo "promote: 세션 기동 결과 — ok (가짜)" ;;
s5) echo "promote: 다른 작업이 색인을 쓰는 중입니다 — 잠시 후 다시 시도하세요." >&2; exit 1 ;;
s6) echo "promote: 착수 표시 — origin 의 fr/s6 에 착수 커밋(abc1234)을 올렸습니다."; exit 4 ;;
s7) echo "promote: 중복 확인 경고 — 같은 작업의 다른 흔적이 있습니다(이어 가기라 계속합니다):"; echo "  - 다른 clone 이 착수했습니다: 원격 fr/s7-other"; echo "promote: 중복 착수 — 다른 clone 이 같은 이름(fr/s7)으로 먼저 착수 표시를 올렸습니다. 세션을 띄우지 않았습니다."; echo "  되돌리기: y"; exit 1 ;;
esac
FAKE
  for i in 1 2 3 4 5 6 7; do : > "$r/rd-workflow-workspace/backlog/items/2026-11-08-s$i-fr.md"; done
  cat > "$T/$n.json" <<JSON
{"wave":"w1","why":"x","streams":[
 {"slug":"s1","title":"t","frs":["2026-11-08-s1-fr"],"owns":"a","notes":"- n"},
 {"slug":"s2","title":"t","frs":["2026-11-08-s2-fr"],"owns":"b","notes":"- n"},
 {"slug":"s3","title":"t","frs":["2026-11-08-s3-fr"],"owns":"c","notes":"- n"},
 {"slug":"s4","title":"t","frs":["2026-11-08-s4-fr"],"owns":"d","notes":"- n"},
 {"slug":"s5","title":"t","frs":["2026-11-08-s5-fr"],"owns":"e","notes":"- n"},
 {"slug":"s6","title":"t","frs":["2026-11-08-s6-fr"],"owns":"f","notes":"- n"},
 {"slug":"s7","title":"t","frs":["2026-11-08-s7-fr"],"owns":"g","notes":"- n"}]}
JSON
  python3 "$r/rd-workflow/scripts/fr_do/handoff.py" "$T/$n.json" --launch > "$o" 2>&1 || { F "$n" "handoff.py 실패: $(cat "$o")"; return; }
  has "$n" "$o" "s1: promote rc=1 promote: 중복 착수"
  has "$n" "$o" "s1:   - 다른 clone 이 착수했습니다: 원격 fr/s1"
  has "$n" "$o" "s1:   되돌리기: x"
  grep -F "s1:" "$o" | grep -qF "기동 결과 줄 없음" && F "$n" "s1 은 머리 줄이 있는데 「기동 결과 줄 없음」 이 나옴" || P "$n s1 에 기동 결과 줄 없음 문구 없음"
  has "$n" "$o" "s2: promote rc=0 promote: 세션 기동 결과 — ok"
  has "$n" "$o" "s2: promote: 중복 확인 경고 — 착수 표시를 원격에 올리지 못했습니다(net)."
  has "$n" "$o" "s3: promote: 착수 표시 — origin 의 fr/s3"
  has "$n" "$o" "s4: promote: 착수 표시 — origin 의 fr/s4 에 이미"
  has "$n" "$o" "s5: 착수 표시 상태 — 착수 실패(promote rc=1"
  has "$n" "$o" "s1: 착수 표시 상태 — 멈춤"
  has "$n" "$o" "s3: 착수 표시 상태 — 올림"
  has "$n" "$o" "s4: 착수 표시 상태 — 이미 있음"
  # rc≠0 이고 기동 줄이 없을 때 착수 표시 성공 줄은 요약 자리에 오르지 않고 「log 확인」 힌트가 남는다.
  has "$n" "$o" "s6: promote rc=4 (기동 결과 줄 없음 —"
  has "$n" "$o" "s6: promote: 착수 표시 — origin 의 fr/s6"
  # 확인 경고가 멈춤 머리 줄보다 먼저 나와도 멈춤 줄이 요약에 오르고, 경고·되돌리기 안내가 함께 보여야 합니다.
  has "$n" "$o" "s7: promote rc=1 promote: 중복 착수 — 다른 clone 이 같은 이름(fr/s7)"
  has "$n" "$o" "s7:   되돌리기: y"
  has "$n" "$o" "s7: promote: 중복 확인 경고 — 같은 작업의 다른 흔적"
  grep -F "s7:" "$o" | grep -qF "기동 결과 줄 없음" && F "$n" "s7 은 경고 뒤에 멈춤 머리 줄이 있는데 「기동 결과 줄 없음」 이 나옴" || P "$n s7 에 기동 결과 줄 없음 문구 없음"
}

handoff_claim_state() {
  local n=handoff_claim_state r
  r="$(cd "$SRC/fr_do" && python3 -I -B -c '
import importlib.util
sp=importlib.util.spec_from_file_location("h","handoff.py"); m=importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
c=m.claim_state
print(c(1,["promote: 다른 작업이 색인을 쓰는 중입니다 — 잠시 후 다시 시도하세요."]))
print(c(0,["promote: 중복 확인 경고 — 같은 작업의 다른 흔적이 있습니다(이어 가기라 계속합니다):","  - x","promote: 착수 표시 — origin 의 fr/a 에 착수 커밋(abc)을 올렸습니다."]))
print(c(1,["promote: 중복 착수 — …","promote: 중복 확인 경고 — 원격 중복 확인을 하지 못했습니다(net)."]))
print(c(0,["promote: 중복 확인 경고 — 착수 표시를 원격에 올리지 못했습니다(net)."]))
print(c(0,["promote: 착수 표시 — origin 의 fr/a 에 이미 이 작업의 착수 표시가 있습니다(abc)."]))
print(c(0,[]))
' 2>&1)"
  local want='착수 실패(promote rc=1 — promote.log 확인)
올림
멈춤(다른 착수·발행 있음)
못 올림(net)
이미 있음
원격 없음(로컬 전용)'
  [ "$r" = "$want" ] && P "$n 여섯 갈래 상태" || F "$n" "$r"
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
# sc_run <이름> <대기초> [회차] — SC_OUT(마지막 줄) 과 prompt 횟수 SC_N 을 정합니다. 호출 전에 $T/$name.fake 에 상태·화면을 둡니다.
sc_run() {
  local d="$T/$1.fake"
  FAKE_DIR="$d" HERDR_PANE_ID=p1 RD_FR_DO_COMPACT_POLL=1 bash "$SRC/fr_do/self_compact.sh" 80 "$2" ${3:+"$3"} > "$T/$1.out" 2>&1
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
compact_status_below_input() {
  # 지난 입력(❯)과 본문의 문턱 아래 수치가 입력줄 위에 있습니다. 마지막 ❯ 아래 상태줄(87%)만 비율입니다.
  local n=compact_status_below_input d="$T/compact_status_below_input.fake"; sc_case $n idle
  printf '❯ 지난 입력\n본문 예시 40%% 80k/200k\n❯ \n87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 5; sc_expect $n "SENT 87%" 1
}
compact_no_status_after_input() {
  # 문턱 이상 수치는 입력줄 위 본문에만 있고 마지막 ❯ 아래에는 상태줄이 없습니다. 비율을 모르므로 보내지 않습니다.
  local n=compact_no_status_after_input d="$T/compact_no_status_after_input.fake"; sc_case $n idle
  printf '❯ 지난 입력\n본문 예시 87%% 174k/200k\n❯ \n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 상태줄의 컨텍스트 표시를 읽지 못함" 0
}
compact_below_limit() {
  local n=compact_below_limit d="$T/compact_below_limit.fake"; sc_case $n idle; printf '❯ \n40%% 80k/200k\n' > "$d/screen.p1"
  sc_run $n 5; sc_expect $n "SKIP 컨텍스트 40% < 80%" 0
}
compact_typing_waits() {
  local n=compact_typing_waits d="$T/compact_typing_waits.fake"; sc_case $n idle; printf '❯ 안녕\n87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 입력창에 글이 남아 있음" 0
}
compact_working() {
  local n=compact_working d="$T/compact_working.fake"; sc_case $n working; printf '%s\n' "$SCR_OK" > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 세션이 계속 작업 중" 0
}
compact_unreadable() {
  # 회차를 주면 마지막 줄 끝에 붙습니다(완료 알림을 건 회차에 연결하는 값).
  local n=compact_unreadable d="$T/compact_unreadable.fake"; sc_case $n idle; printf '❯ \n' > "$d/screen.p1"
  sc_run $n 2 w7; sc_expect $n "SKIP 대기 상한 2초 — 상태줄의 컨텍스트 표시를 읽지 못함" 0
  case "$SC_OUT" in *" 회차=w7") P "$n 회차 표지";; *) F "$n" "회차 표지 없음: '$SC_OUT'";; esac
}
compact_typing_from_start() {
  # 처음부터 입력창에 글이 있고 상태줄이 없습니다. 비율을 못 읽었어도 입력 중(일시 사유)입니다.
  local n=compact_typing_from_start d="$T/compact_typing_from_start.fake"; sc_case $n idle; printf '❯ 아직 보내지 않은 입력\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 입력창에 글이 남아 있음" 0
}
compact_no_input_line_from_start() {
  # 처음부터 입력줄이 화면에 없습니다. 상태줄 설정 문제(고정 사유)가 아니라 화면 가림(일시 사유)입니다.
  local n=compact_no_input_line_from_start d="$T/compact_no_input_line_from_start.fake"; sc_case $n idle; printf '87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 상태줄·입력줄이 화면에서 가려짐" 0
}
compact_blocked_from_start() {
  # 승인 창이 처음부터 입력줄을 가려 비율을 한 번도 못 읽었습니다. 상태줄 설정 문제(고정 사유)가 아니라 일시 사유입니다.
  local n=compact_blocked_from_start d="$T/compact_blocked_from_start.fake"; sc_case $n blocked
  printf 'Do you want to proceed?\n  1. Yes\n  2. No\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 승인·선택 창이 떠 있음" 0
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
compact_recheck_status_gone() {
  # 첫 판독은 상태줄 87%, 재확인은 빈 입력줄만 있고 문턱 이상 수치가 입력줄 위 본문에만 남습니다(화면이 다시 그려진 경우).
  local n=compact_recheck_status_gone d="$T/compact_recheck_status_gone.fake"; sc_case $n idle
  printf '%s\n' "$SCR_OK" > "$d/screen.p1.1"; printf '본문 예시 87%% 174k/200k\n❯ \n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 상태줄·입력줄이 화면에서 가려짐" 0
}
compact_recheck_below_limit() {
  # 첫 판독은 상태줄 87%, 재확인 상태줄은 40%(그 사이 컨텍스트가 줄어든 경우)입니다. 재확인 비율이 기준 아래면 보내지 않습니다.
  # 대기 상한 0초로 재확인과 상한이 같은 반복에 겹치게 합니다. 이때도 사유는 기준 미만이어야 합니다(화면 가림으로 알리지 않음).
  local n=compact_recheck_below_limit d="$T/compact_recheck_below_limit.fake"; sc_case $n idle
  printf '%s\n' "$SCR_OK" > "$d/screen.p1.1"; printf '❯ \n40%% 80k/200k\n' > "$d/screen.p1"
  sc_run $n 0; sc_expect $n "SKIP 컨텍스트 40% < 80%" 0
}
compact_recheck_line_gone() {
  local n=compact_recheck_line_gone d="$T/compact_recheck_line_gone.fake"; sc_case $n idle
  printf '%s\n' "$SCR_OK" > "$d/screen.p1.1"; printf '87%% 174k/200k\n' > "$d/screen.p1.2"; printf '87%% 174k/200k\n' > "$d/screen.p1"
  sc_run $n 2; sc_expect $n "SKIP 대기 상한 2초 — 상태줄·입력줄이 화면에서 가려짐" 0
}

CASES="grant_not_archive_hold grant_dirty_main_hold grant_dirty_state_dir_hint grant_merging_main_hold grant_conflict_hold grant_mergetree_error_holds grant_no_branch_skips_merge grant_auto_only_ok
watch_blocked_once watch_two_streams_both_seen watch_report_once watch_report_across_restart watch_idle_again_after_working watch_ctx_threshold watch_ctx_working watch_queue_change watch_queue_ignores_action_path watch_long_slug_agent_name watch_beats_queue watch_queue_fail_no_beat watch_queue_recover_reemits watch_stale_row_skipped watch_stale_then_relaunch_reports
close_not_closed_keeps_row close_closed_removes_row close_numeric_slug_string_compare close_stale_branch_back_keeps_tab close_stale_branch_back_during_pull close_stale_never_closes_tab close_passes_task_list_tab_note close_long_slug_closes_tab handoff_generate_paths handoff_design_qa handoff_bad_slug_rejected handoff_launch_session_env handoff_bad_session_value_rejected handoff_wave_reserved handoff_launch_verdict handoff_launch_dup_lines handoff_claim_state handoff_active_row
compact_sent compact_status_below_input compact_no_status_after_input compact_below_limit compact_typing_waits compact_working compact_unreadable compact_typing_from_start compact_no_input_line_from_start compact_blocked_from_start compact_recheck_typing compact_missing_input_line compact_recheck_read_fail compact_recheck_status_gone compact_recheck_below_limit compact_recheck_line_gone"
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
