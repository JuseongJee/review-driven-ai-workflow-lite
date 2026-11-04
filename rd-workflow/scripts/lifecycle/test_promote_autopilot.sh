#!/usr/bin/env bash
# promote.sh --autopilot — 표식이 세션 기동 전에 놓이고, 플래그가 없거나 dry-run 이면 놓이지 않는다.
# 실제 herdr 는 부르지 않는다(RD_LAUNCH_STUB 대역, HERDR_ENV 비움).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
# 실제 세션 기동 차단: herdr·herdr app(HC_TERMINAL_ID) 판정을 모두 끈다.
export HERDR_ENV=
export HC_TERMINAL_ID=
export RD_CHILD_SESSION=1
source "$SCRIPT_DIR/_lifecycle_common.sh"

RLREPO="$(mktemp -d)" || { echo "test_promote_autopilot.sh: 임시 디렉터리 생성 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$RLREPO" && -d "$RLREPO" ]] || { echo "test_promote_autopilot.sh: 임시 디렉터리 경로 검증 실패" >&2; exit 1; }
RLREPO="$(cd "$RLREPO" && pwd -P)"
trap 'rm -rf "$RLREPO"' EXIT
mkdir -p "$RLREPO/rd-workflow"
cp -R "$SCRIPT_DIR/.." "$RLREPO/rd-workflow/scripts"
git -C "$RLREPO" init -q -b main
git -C "$RLREPO" config user.email t@t && git -C "$RLREPO" config user.name t
mkdir -p "$RLREPO/rd-workflow-workspace/.lifecycle" "$RLREPO/rd-workflow-workspace/backlog/items"
printf '.worktrees/\n' > "$RLREPO/.gitignore"
emit_current_task_baseline > "$RLREPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$RLREPO/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$RLREPO/REQUEST.md"
git -C "$RLREPO" add -A && git -C "$RLREPO" commit -q -m seed

# 기동 대역 — 불리는 시점(기동 직전)에 자식 worktree 의 driver check rc 를 기록한다.
RC_FILE="$RLREPO/check-rc"
STUB="$RLREPO/stub-launch.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
rc=0
bash "\$1/rd-workflow/scripts/autopilot_driver.sh" check >/dev/null 2>&1 || rc=\$?
printf '%s' "\$rc" > "$RC_FILE"
printf 'ok\n'
STUBEOF
chmod +x "$STUB"
PROMOTE="$RLREPO/rd-workflow/scripts/lifecycle/promote.sh"

# 1) --autopilot: 기동 시점에 표식이 이미 있고, 결과 줄이 ok
out="$(RD_LAUNCH_STUB="$STUB" bash "$PROMOTE" --short-title ap1 --size large --source-fr - --autopilot 2>&1)" || true
[[ "$(cat "$RC_FILE" 2>/dev/null)" == "0" && "$out" == *"promote: autopilot 표식 — ok"* ]] \
  && pass "--autopilot 은 기동 전에 표식을 둔다(check rc 0 + ok 줄)" || fail "--autopilot 표식: rc=$(cat "$RC_FILE" 2>/dev/null) out=$out"

# 2) 플래그 없음: 표식 없음
rm -f "$RC_FILE"
out="$(RD_LAUNCH_STUB="$STUB" bash "$PROMOTE" --short-title ap2 --size large --source-fr - 2>&1)" || true
[[ "$(cat "$RC_FILE" 2>/dev/null)" == "1" && "$out" != *"autopilot 표식"* ]] \
  && pass "플래그가 없으면 표식을 두지 않는다(check rc 1)" || fail "플래그 없음: rc=$(cat "$RC_FILE" 2>/dev/null) out=$out"

# 3) --autopilot --dry-run: 표식 없음 + 예정 문구
gcd="$(git -C "$RLREPO" rev-parse --path-format=absolute --git-common-dir)"
out="$(RD_LAUNCH_STUB="$STUB" bash "$PROMOTE" --short-title ap3 --size large --source-fr - --autopilot --dry-run 2>&1)" || true
[[ ! -e "$gcd/rd-workflow/autopilot-driver.ap3" && "$out" == *"(dry-run) autopilot 표식을 기동 전에 둘 예정입니다."* ]] \
  && pass "--dry-run 은 표식을 두지 않고 예정만 출력한다" || fail "dry-run: out=$out"

# T10) 기동 백엔드 기록 (change spec D2) — 예약 시점에 색인의 launch-backend 가 기록되고, 생존 조회가
#      그 값을 따라가는지. 기록 누락은 중단된 기동을 올바른 대상으로 복구하지 못하게 만든다.
#      hc 대역은 `hc get` 응답만 흉내낸다(시나리오는 $HCDIR/scn, live-same 의 cwd 는 HC_STUB_CWD).
HCDIR="$RLREPO/hcstub"; mkdir -p "$HCDIR"
cat > "$HCDIR/hc" <<'STUBEOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(cat "$dir/scn")" in
  live-same) printf '{"state":"live","cwd":"%s","turn":1,"status":{"state":"done"}}' "${HC_STUB_CWD:-}" ;;
  finished)  printf '{"state":"finished","cwd":"%s","turn":1,"exit_code":0}' "${HC_STUB_CWD:-}" ;;
esac
STUBEOF
chmod +x "$HCDIR/hc"
BKFILE="$RLREPO/backend-at-launch"
STUB_HC="$RLREPO/stub-launch-hc.sh"
cat > "$STUB_HC" <<STUBEOF
#!/usr/bin/env bash
cd "\$1" && source "\$1/rd-workflow/scripts/lifecycle/_tasks_index.sh" \
  && tasks_index_get "\$2" launch-backend > "$BKFILE" 2>/dev/null
printf 'ok\n'
STUBEOF
chmod +x "$STUB_HC"
t10_promote() {  # <slug> [env...]
  local slug="$1"; shift
  : > "$BKFILE"
  ( cd "$RLREPO" && env HERDR_ENV= RD_CHILD_SESSION= HC_TERMINAL_ID=t6 "$@" PATH="$HCDIR:$PATH" RD_LAUNCH_STUB="$STUB_HC" \
      bash "$PROMOTE" --short-title "$slug" --size large --source-fr - >/dev/null 2>&1 ) || true
}
idx_get() { ( cd "$RLREPO" && source "$RLREPO/rd-workflow/scripts/lifecycle/_tasks_index.sh" && tasks_index_get "$1" "$2" 2>/dev/null ); }

# a) 기동 시점(예약 뒤·결과 기록 전)에 이미 hc 가 기록돼 있고, promote 뒤에도 남는다
printf 'finished' > "$HCDIR/scn"
t10_promote hcb1
[[ "$(cat "$BKFILE")" == "hc" ]] && pass "T10-a: 기동 시점 색인 launch-backend=hc" || fail "예약 시점 백엔드 없음: [$(cat "$BKFILE")]"
[[ "$(idx_get hcb1 launch-backend)" == "hc" ]] && pass "T10-a: promote 뒤에도 launch-backend=hc" || fail "promote 뒤 백엔드 기록 없음: [$(idx_get hcb1 launch-backend)]"
# a2) 33자 이상 slug 를 hc 로 기동하면 잘린 이름 문구가 hc 명령을 짚는다 (resume-name spec C6-6)
printf 'finished' > "$HCDIR/scn"
hc_long_out="$( cd "$RLREPO" && env HERDR_ENV= RD_CHILD_SESSION= HC_TERMINAL_ID=t6 PATH="$HCDIR:$PATH" RD_LAUNCH_STUB="$STUB_HC" \
    bash "$PROMOTE" --short-title hclong-abcdefghij-abcdefghij-abcdefghij --size large --source-fr - 2>&1 )" || true
[[ "$hc_long_out" == *"promote: slug 가 32자를 넘어 hc 세션 이름은 hclong-"*"hc get·attach 에는 이 이름을 씁니다."* ]] \
  && pass "T10-a2: hc 시작 경고" || fail "hc 시작 경고 없음: $hc_long_out"
[[ "$hc_long_out" == *"promote: hc 세션 이름 — hclong-"* ]] \
  && pass "T10-a2: hc 기동 결과 뒤 이름 줄" || fail "hc 이름 줄 없음: $hc_long_out"
[[ "$hc_long_out" != *"herdr 에이전트 이름"* ]] \
  && pass "T10-a2: hc 기동에는 herdr 이름 문구가 없다" || fail "hc 기동에 herdr 문구: $hc_long_out"
# b) hc 종료 세션은 rollback 의 생존 가드가 dead 로 보고 통과시킨다 (probe 가 기록된 백엔드로 조회)
rc=0
out="$( cd "$RLREPO" && env HERDR_ENV= HC_TERMINAL_ID=t6 HC_STUB_CWD="$RLREPO/.worktrees/hcb1" PATH="$HCDIR:$PATH" bash "$RLREPO/rd-workflow/scripts/lifecycle/promote_rollback.sh" --task hcb1 2>&1 )" || rc=$?
[[ "$rc" -eq 0 && "$out" == *"이미 종료된 것으로 확인됐습니다"* ]] && pass "T10-b: hc 종료 세션 rollback 통과" || fail "rollback hc 종료 판정: rc=$rc out=$out"
# c) hc 살아 있는 세션은 rollback 이 거부한다
printf 'live-same' > "$HCDIR/scn"
t10_promote hcb2
rc=0
out="$( cd "$RLREPO" && env HERDR_ENV= HC_TERMINAL_ID=t6 HC_STUB_CWD="$RLREPO/.worktrees/hcb2" PATH="$HCDIR:$PATH" bash "$RLREPO/rd-workflow/scripts/lifecycle/promote_rollback.sh" --task hcb2 2>&1 )" || rc=$?
[[ "$rc" -ne 0 && "$out" == *"probe=alive"* ]] && pass "T10-c: hc 살아 있는 세션 rollback 거부" || fail "살아 있는 세션 rollback: rc=$rc out=$out"
# d) 자식 세션(RD_CHILD_SESSION)은 none 으로 기록한다 — 이전 기동의 값을 덮어쓰기 위해서다
t10_promote hcb3 RD_CHILD_SESSION=1
[[ "$(idx_get hcb3 launch-backend)" == "none" ]] && pass "T10-d: 자식 세션은 launch-backend=none" || fail "자식 세션 기록: [$(idx_get hcb3 launch-backend)]"

printf 'promote_autopilot: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
