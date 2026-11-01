#!/bin/bash
# test_session_start_compact.sh — 압축 뒤 안내(session_start.sh + _compact_hint.sh + autopilot_driver.sh) 검증
# 자기 위치 기준으로 rd-workflow/scripts 를 임시 디렉터리에 복사한 fixture 에서 실제 훅을 실행한다.
# macOS /bin/bash 3.2 호환. `timeout` 이 없는 머신을 가정해 run_bounded 를 쓴다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_BIN="${BASH_BIN:-bash}"
SKILL_MD="$SCRIPT_DIR/../../claude_skills/autopilot/SKILL.md"
LITE_HOOK="$SCRIPT_DIR/../../../scripts/build-rules/lite-overrides/rd-workflow/scripts/hooks/session_start.sh"

T="$(mktemp -d)" || { echo "test_session_start_compact.sh: mktemp 실패" >&2; exit 1; }
[[ -n "$T" && -d "$T" ]] || exit 1
WRITER_PID=""
cleanup() {
  if [[ -n "$WRITER_PID" ]]; then
    pkill -P "$WRITER_PID" 2>/dev/null
    kill "$WRITER_PID" 2>/dev/null
    wait "$WRITER_PID" 2>/dev/null
  fi
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

FAILS=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }

mkdir -p "$T/rd-workflow" "$T/rd-workflow-workspace/.lifecycle"
cp -R "$SCRIPTS_DIR" "$T/rd-workflow/scripts"
HOOK="$T/rd-workflow/scripts/hooks/session_start.sh"
DRIVER="$T/rd-workflow/scripts/autopilot_driver.sh"
STATE="$T/rd-workflow-workspace/.lifecycle/task-state"
SLUG="demo-task"
FRB="fr/demo-task"
CREATED="2026-10-29T10:00:00"

git -C "$T" init -q 2>/dev/null
git -C "$T" symbolic-ref HEAD "refs/heads/$FRB"
COMMON="$(git -C "$T" rev-parse --path-format=absolute --git-common-dir)"
MARKER="$COMMON/rd-workflow/autopilot-driver.$SLUG"

# set_state <status> [short-title]
set_state() {
  cat > "$STATE" <<EOS
schema=1
short-title=${2:-$SLUG}
status=$1
fr-branch=$FRB
worktree-path=$T
source-fr=-
created-at=$CREATED
EOS
  printf '# Current Task\n\n## Task\ndemo\n\n## Status\n%s\n\n## Next Step\nnext\n' "$1" > "$T/CURRENT_TASK.md"
}
clear_markers() { rm -f "$COMMON"/rd-workflow/autopilot-driver.* 2>/dev/null; }

# run_bounded <초> <명령...> — 출력은 $RB_OUT, stdin 은 $RB_IN(기본 /dev/null). 한도 초과 시 kill 후 124.
RB_OUT="$T/rb.out"
run_bounded() {
  local limit="$1" pid i=0 max
  shift
  max=$((limit * 5))
  "$@" > "$RB_OUT" 2>&1 < "${RB_IN:-/dev/null}" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$i" -ge "$max" ]]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
    i=$((i + 1))
  done
  wait "$pid"
}

# hook_run <hook-path> <json> — stdout+stderr 는 $OUT, exit code 는 $RC
OUT=""; RC=0
hook_run() {
  local hook="$1" json="$2"
  OUT="$(printf '%s' "$json" | "$BASH_BIN" "$hook" 2>&1)"
  RC=$?
}
HINT='[hooks] 압축 안내:'

# --- A1 compact + 일치 표식 + 구현 중 ---
set_state "구현 중"; clear_markers; "$BASH_BIN" "$DRIVER" begin
hook_run "$HOOK" '{"source":"compact"}'
if [[ "$OUT" == *"$HINT"* && "$OUT" == *'### 4. 자율 구현'* ]]; then ok "A1 compact+표식+구현 중 안내"; else fail "A1" "$OUT"; fi
A1_RC=$RC; A1_OUT="$OUT"

# --- A2 아카이브 보류 ---
set_state "아카이브 보류"
hook_run "$HOOK" '{"source":"compact"}'
if [[ "$OUT" == *"$HINT"* && "$OUT" == *'### 6. 마무리'* ]]; then ok "A2 아카이브 보류 안내"; else fail "A2" "$OUT"; fi
A2_RC=$RC; A2_OUT="$OUT"

# --- A3 startup + 일치 표식 ---
set_state "구현 중"
hook_run "$HOOK" '{"source":"startup"}'
if [[ "$OUT" != *"$HINT"* ]]; then ok "A3 startup 안내 없음"; else fail "A3" "$OUT"; fi
A3_RC=$RC; A3_OUT="$OUT"

# --- A4 compact + 표식 없음 ---
clear_markers
hook_run "$HOOK" '{"source":"compact"}'
if [[ "$OUT" != *"$HINT"* ]]; then ok "A4 표식 없음 안내 없음"; else fail "A4" "$OUT"; fi
A4_RC=$RC; A4_OUT="$OUT"

# --- A5 compact + created-at 불일치 표식 ---
mkdir -p "$COMMON/rd-workflow"
printf 'created-at=%s\n' "1999-01-01T00:00:00" > "$MARKER"
hook_run "$HOOK" '{"source":"compact"}'
if [[ "$OUT" != *"$HINT"* ]]; then ok "A5 created-at 불일치 안내 없음"; else fail "A5" "$OUT"; fi
A5_RC=$RC; A5_OUT="$OUT"

# --- A6 모든 케이스에서 상태 출력과 exit 0 ---
a6=1
for pair in "$A1_RC|$A1_OUT" "$A2_RC|$A2_OUT" "$A3_RC|$A3_OUT" "$A4_RC|$A4_OUT" "$A5_RC|$A5_OUT"; do
  [[ "${pair%%|*}" == "0" && "${pair#*|}" == *'[hooks] 현재 작업 상태:'* ]] || a6=0
done
if [[ "$a6" == 1 ]]; then ok "A6 상태 출력 유지·exit 0"; else fail "A6"; fi

# --- A7 begin: 브랜치 불일치 → exit 2, 표식 없음 ---
set_state "구현 중"; clear_markers
git -C "$T" symbolic-ref HEAD refs/heads/other-branch
"$BASH_BIN" "$DRIVER" begin >/dev/null 2>&1; rc=$?
if [[ "$rc" == 2 && ! -e "$MARKER" ]]; then ok "A7 begin 브랜치 불일치 거부"; else fail "A7" "rc=$rc"; fi

# --- A10 check: 표식이 있어도 브랜치 불일치면 exit 1 ---
printf 'created-at=%s\n' "$CREATED" > "$MARKER"
"$BASH_BIN" "$DRIVER" check >/dev/null 2>&1; rc=$?
if [[ "$rc" == 1 ]]; then ok "A10 check 브랜치 불일치 exit 1"; else fail "A10" "rc=$rc"; fi
git -C "$T" symbolic-ref HEAD "refs/heads/$FRB"
clear_markers

# --- A8 begin: slug 형식이 아닌 short-title 거부 ---
set_state "구현 중" "Bad Slug"
"$BASH_BIN" "$DRIVER" begin >/dev/null 2>&1; rc=$?
leftover="$(ls "$COMMON"/rd-workflow/autopilot-driver.* 2>/dev/null | head -n 1)"
if [[ "$rc" == 2 && -z "$leftover" ]]; then ok "A8 begin slug 형식 거부"; else fail "A8" "rc=$rc leftover=$leftover"; fi

# --- A9 begin 뒤 표식 있음, end 뒤 없음 ---
set_state "구현 중"; clear_markers
"$BASH_BIN" "$DRIVER" begin >/dev/null 2>&1
had=0; [[ -f "$MARKER" ]] && had=1
"$BASH_BIN" "$DRIVER" end >/dev/null 2>&1
if [[ "$had" == 1 && ! -e "$MARKER" ]]; then ok "A9 begin 표식 생성·end 삭제"; else fail "A9" "had=$had"; fi

# --- A11a 빈 stdin ---
set_state "구현 중"; clear_markers
RB_IN=/dev/null run_bounded 10 "$BASH_BIN" "$HOOK"; rc=$?
if [[ "$rc" == 0 && "$(cat "$RB_OUT")" == *'[hooks] 현재 작업 상태:'* ]]; then ok "A11a 빈 stdin 종료·exit 0"; else fail "A11a" "rc=$rc"; fi

# --- A11b writer 가 열린 named pipe ---
mkfifo "$T/in"
{ printf '{"source":"compact"}'; sleep 30; } > "$T/in" 2>/dev/null &
WRITER_PID=$!
"$BASH_BIN" "$HOOK" < "$T/in" > "$T/out11b" 2>&1 &
HOOK_PID=$!
i=0; hook_done=0
while [[ "$i" -lt 50 ]]; do
  if ! kill -0 "$HOOK_PID" 2>/dev/null; then hook_done=1; break; fi
  sleep 0.2
  i=$((i + 1))
done
writer_alive=0
kill -0 "$WRITER_PID" 2>/dev/null && writer_alive=1
if [[ "$hook_done" == 1 ]]; then
  wait "$HOOK_PID"; rc=$?
else
  kill "$HOOK_PID" 2>/dev/null; wait "$HOOK_PID" 2>/dev/null; rc=124
fi
if [[ "$hook_done" == 1 && "$rc" == 0 && "$writer_alive" == 1 && "$(cat "$T/out11b")" == *'[hooks] 현재 작업 상태:'* ]]; then
  ok "A11b 열린 파이프에서 10초 안에 종료·exit 0"
else
  fail "A11b" "done=$hook_done rc=$rc writer_alive=$writer_alive"
fi
{ pkill -P "$WRITER_PID"; kill "$WRITER_PID"; wait "$WRITER_PID"; } 2>/dev/null
WRITER_PID=""

# --- A12 lite 오버라이드 ---
if [[ -f "$LITE_HOOK" ]]; then
  cp "$LITE_HOOK" "$T/rd-workflow/scripts/hooks/session_start_lite.sh"
  LH="$T/rd-workflow/scripts/hooks/session_start_lite.sh"
  set_state "구현 중"; clear_markers; "$BASH_BIN" "$DRIVER" begin
  hook_run "$LH" '{"source":"compact"}'; c_out="$OUT"; c_rc=$RC
  hook_run "$LH" '{"source":"startup"}'; s_out="$OUT"; s_rc=$RC
  if [[ "$c_rc" == 0 && "$s_rc" == 0 && "$c_out" == *"$HINT"* && "$s_out" != *"$HINT"* ]]; then
    ok "A12 lite 오버라이드 안내"
  else
    fail "A12" "compact_rc=$c_rc startup_rc=$s_rc"
  fi
else
  echo "skip: lite 오버라이드 없음"
fi

# --- A13 대응표 절 제목 ↔ SKILL.md ---
if [[ -f "$SKILL_MD" ]]; then
  titles="$(grep 'section=' "$SCRIPTS_DIR/hooks/_compact_hint.sh" | grep -o '`##[#]* [^`]*`' | tr -d '`')"
  missing=""; n=0
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    n=$((n + 1))
    awk -v t="$t" 'index($0,t)==1{f=1} END{exit f?0:1}' "$SKILL_MD" || missing="$missing [$t]"
  done <<< "$titles"
  if [[ "$n" -gt 0 && -z "$missing" ]]; then ok "A13 절 제목 ${n}개 SKILL.md 에 실재"; else fail "A13" "n=$n missing=$missing"; fi
else
  fail "A13" "SKILL.md 없음: $SKILL_MD"
fi

[[ "$FAILS" -eq 0 ]] || exit 1
exit 0
