#!/usr/bin/env bash
# test_review_adapter_parity.sh — codex·claude 두 어댑터의 공통 프롬프트 소비 검증
# AC 32 (review-turn-latency-reduction)
# build_review_prompt 출력 검사만으로는 "양쪽이 동일 프롬프트를 정상 소비"를 확인할 수 없으므로
# 실제 CLI 를 stub 으로 대체하고 stdin 바이트 스트림을 비교한다.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
chk()  { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }
eq()   { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대=[$2] 실제=[$1])"; fi; }

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- 실 CLI 차단 (FR parity-test-stall) ---
# 이 스위트는 전부 stub 기반이므로 실제 codex·claude CLI 에 **절대 닿으면 안 됩니다.**
# 그런데 도구 경로 해석에 이름 폴백이 두 겹 있습니다.
#   run_review_turn.sh — config 의 bin 이 비면 `check_bin="${tool_bin:-$tool}"` 로 도구 이름 폴백
#   adapter_codex.sh   — 그 뒤 다시 `codex_bin="${TOOL_BIN:-codex}"` 로 이름 폴백
# 그래서 fixture 가 쓴 config 가 무시되는 조건이 하나라도 성립하면 PATH 의 **실물** CLI 가 뜹니다.
# 실측으로 두 조건을 재현했습니다.
#   ① 환경에 REVIEW_TOOLS_CONFIG 가 상속돼 있으면 fixture config 파일 자체가 읽히지 않습니다
#      (run_review_turn.sh 의 CONFIG_FILE 이 그 환경변수를 우선합니다).
#   ② jq 부재·파싱 실패로 설정 파싱이 무너지면 모든 bin 조회가 빈 값이 됩니다.
# 실물 CLI 가 뜨면 워치독(WAIT_TIMEOUT, production 기본 600초) 이 만료될 때까지 **조용히 대기**해
# 호출 1회당 10분이 얹힙니다. codex 가 설치된 머신에서만 발생해 오래 원인 불명이었습니다.
#
# 처방은 타임아웃 단축이 아니라 **경로를 끊는 것**입니다.
#   (1) fixture 를 우회시키는 환경변수를 제거합니다.
#   (2) PATH 최상단에 즉시 실패하는 tripwire 를 놓아 이름 폴백이 실물에 닿지 못하게 합니다.
#       tripwire 는 대기 없이 죽고 호출 사실을 로그로 남기므로, "stub 이 걷혔다" 가
#       조용한 10분이 아니라 명시적 실패로 드러납니다 (케이스 5·6 이 이를 단언합니다).
unset REVIEW_TOOLS_CONFIG RD_REVIEW_EFFORT_OVERRIDE RD_AUTOPILOT RD_SELF_REVIEW_APPROVE \
      REVIEW_PROMPT_INLINE_MAX_BYTES TOOL_EFFORT EFFORT_SOURCE TOOL_BIN TOOL_MODEL \
      POLL_TIMEOUT SESSION_PATH PROMPT_FILE EXPECTED_TURN_FILE PROJECT_ROOT

TRIPWIRE_LOG="$TMP/real_cli_calls.log"
: > "$TRIPWIRE_LOG"
mkdir -p "$TMP/pathguard"
for _real in codex claude; do
  cat > "$TMP/pathguard/$_real" <<TRIPEOF
#!/usr/bin/env bash
printf '%s\n' "$_real" >> "$TRIPWIRE_LOG"
echo "test_review_adapter_parity: 실제 $_real CLI 호출을 차단했습니다 (stub 이 걷혔습니다)" >&2
exit 97
TRIPEOF
  chmod +x "$TMP/pathguard/$_real"
done
export PATH="$TMP/pathguard:$PATH"

# 워치독 상한도 테스트 안에서만 좁힙니다. 이것은 처방이 아니라 위생입니다 — stub 은 즉시
# 끝나므로 정상 경로 동작은 그대로이고, tripwire 를 우회한 미지의 경로가 생기더라도 10분이
# 아니라 수십 초 안에 드러납니다. production 기본값(600초)은 건드리지 않습니다.
export WAIT_TIMEOUT=30

# tripwire 발동 여부 단언. 로그가 비어 있어야 "stub 만 사용됐다" 가 성립합니다.
assert_no_real_cli() { # assert_no_real_cli <라벨>
  if [ -s "$TRIPWIRE_LOG" ]; then
    fail "$1 (호출된 실 CLI: $(tr '\n' ' ' < "$TRIPWIRE_LOG"))"
  else
    pass "$1"
  fi
}

# --- 격리 트리 구성 ---
# run_review_turn.sh 는 자기 위치에서 project_root 를 계산하므로, 스크립트를 임시 트리로
# 복사해 정본 트리를 건드리지 않고 실행한다.
mkdir -p "$TMP/rd-workflow/scripts" "$TMP/rd-workflow/config" \
         "$TMP/rd-workflow/docs/flows" "$TMP/rd-workflow/docs/prompts/review" \
         "$TMP/sess/turns" "$TMP/cap"
for f in run_review_turn.sh review_common.sh adapter_codex.sh adapter_claude.sh; do
  cp "${script_dir}/$f" "$TMP/rd-workflow/scripts/$f"
done

printf '리뷰 기준 본문\n' > "$TMP/rd-workflow/docs/prompts/review/request_review.md"
{ i=0; while [ $i -lt 200 ]; do printf 'pipeline filler %s ------------------------------------\n' "$i"; i=$((i+1)); done; } \
  > "$TMP/rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md"
printf '# 리뷰 대상\n\n본문\n' > "$TMP/TARGET.md"

# --- stub CLI ---
# stdin 을 파일로 capture 하고 정상 턴 파일을 만든 뒤 세션을 완료 상태로 전환한다.
# 환경변수 존재 여부도 함께 기록해 effort 가 codex 에만 전달되는지 확인한다.
mk_stub() { # mk_stub <경로> <capture 파일>
  cat > "$1" <<STUBEOF
#!/usr/bin/env bash
cat > "$2"
{
  printf 'TOOL_EFFORT=%s\n' "\${TOOL_EFFORT+SET}"
  printf 'EFFORT_SOURCE=%s\n' "\${EFFORT_SOURCE+SET}"
  printf 'EFFORT_RESULT_FILE=%s\n' "\${EFFORT_RESULT_FILE+SET}"
} > "$2.env"
printf '# Turn 002 · Reviewer\n\n이의 없음\n' > "\$EXPECTED_TURN_FILE"
sed -e 's/^awaiting-reviewer\$/awaiting-author/' -e 's/^Reviewer\$/Author/' \
  "\$SESSION_PATH/SESSION.md" > "\$SESSION_PATH/SESSION.md.tmp"
mv "\$SESSION_PATH/SESSION.md.tmp" "\$SESSION_PATH/SESSION.md"
exit 0
STUBEOF
  chmod +x "$1"
}
mk_stub "$TMP/stub_codex"  "$TMP/cap/codex"
mk_stub "$TMP/stub_claude" "$TMP/cap/claude"

# --- 세션 fixture ---
# `## Branch Context` 는 두지 않는다 (legacy 취급 → strict 검증 skip).
reset_session() {
  rm -rf "$TMP/sess"; mkdir -p "$TMP/sess/turns"
  cat > "$TMP/sess/SESSION.md" <<'EOF'
# Review Session

## Status
awaiting-reviewer

## Current Owner
Reviewer

## Review Type
request-review

## Review Target
TARGET.md

## Review Goal
parity 검증

## Turn Limit
20

## Review Scope
- execution-path: other
EOF
  printf '# Checkpoint\n\n## Open Issues\n- 없음\n' > "$TMP/sess/CHECKPOINT.md"
  printf '# User Action\n\n## Question For User\n-\n'  > "$TMP/sess/USER_ACTION.md"
  printf '# Turn 001 · Author\n\n본문\n'               > "$TMP/sess/turns/001_claude.md"
}

# --- config fixture ---
# self_review_policy=warn 으로 두어 claude 경로가 게이트에 막히지 않게 한다.
write_cfg() { # write_cfg <priority tool> <codex effort 값|"">
  local tool="$1" effort="$2" effort_field=""
  [ -n "$effort" ] && effort_field=", \"reasoning_effort\": \"$effort\""
  cat > "$TMP/rd-workflow/config/review-tools.json" <<EOF
{
  "default_priority": ["$tool"],
  "tools": {
    "codex": { "bin": "$TMP/stub_codex"$effort_field },
    "claude": { "bin": "$TMP/stub_claude", "self_review_policy": "warn", "self_review_warning": false }
  }
}
EOF
}

run_turn() { # run_turn <tool> <cap 파일 접미사> <효과 effort> <cap bytes>
  reset_session
  rm -f "$TMP/cap/codex" "$TMP/cap/claude" "$TMP/cap/codex.env" "$TMP/cap/claude.env"
  write_cfg "$1" "$3"
  (
    cd "$TMP"
    REVIEW_PROMPT_INLINE_MAX_BYTES="$4" \
      bash "$TMP/rd-workflow/scripts/run_review_turn.sh" sess >"$TMP/out_$2" 2>"$TMP/err_$2"
    echo "rc=$?"
  )
}

echo "=== 케이스 1: full-inline — 양쪽 어댑터가 동일 바이트를 받는가 ==="
r="$(run_turn codex c1_codex '' 200000)"
eq "$r" "rc=0" "codex 경로 정상 완료"
cp "$TMP/cap/codex" "$TMP/cap/c1_codex"
cp "$TMP/cap/codex.env" "$TMP/cap/c1_codex.env"

r="$(run_turn claude c1_claude '' 200000)"
eq "$r" "rc=0" "claude self-review 경로 정상 완료"
cp "$TMP/cap/claude" "$TMP/cap/c1_claude"
cp "$TMP/cap/claude.env" "$TMP/cap/c1_claude.env"

cmp -s "$TMP/cap/c1_codex" "$TMP/cap/c1_claude"
chk $? "AC32 full-inline: 두 어댑터가 받은 stdin 이 바이트 단위로 동일"
grep -q 'ALREADY INLINED BELOW' "$TMP/cap/c1_codex"; chk $? "full-inline 프롬프트에 인라인 목록 존재"
grep -q 'NOT inlined — read these from disk' "$TMP/cap/c1_codex"; [ $? -ne 0 ]
chk $? "full-inline 이면 disk-read 줄이 생략됨"

echo "=== 케이스 2: 크기 fallback — 양쪽에서 동일하게 동작하는가 ==="
r="$(run_turn codex c2_codex '' 3000)"
eq "$r" "rc=0" "codex 경로 정상 완료 (fallback)"
cp "$TMP/cap/codex" "$TMP/cap/c2_codex"

r="$(run_turn claude c2_claude '' 3000)"
eq "$r" "rc=0" "claude 경로 정상 완료 (fallback)"
cp "$TMP/cap/claude" "$TMP/cap/c2_claude"

cmp -s "$TMP/cap/c2_codex" "$TMP/cap/c2_claude"
chk $? "AC32 fallback: 두 어댑터가 받은 stdin 이 바이트 단위로 동일"
grep -q 'FILE_BASED_REVIEW_PIPELINE.md (size)' "$TMP/cap/c2_codex"
chk $? "fallback 항목이 두 경로 공통으로 disk-read 목록에 표시"
cmp -s "$TMP/cap/c1_codex" "$TMP/cap/c2_codex"; [ $? -ne 0 ]
chk $? "cap 이 다르면 프롬프트도 실제로 달라짐 (fixture 유효성)"

echo "=== 케이스 3: effort scope — codex 전용인가 ==="
run_turn codex c3_codex xhigh 200000 >/dev/null
eq "$(grep '^TOOL_EFFORT=' "$TMP/cap/codex.env")"        "TOOL_EFFORT=SET"        "codex stub 에 TOOL_EFFORT 전달"
eq "$(grep '^EFFORT_SOURCE=' "$TMP/cap/codex.env")"      "EFFORT_SOURCE=SET"      "codex stub 에 EFFORT_SOURCE 전달"
eq "$(grep '^EFFORT_RESULT_FILE=' "$TMP/cap/codex.env")" "EFFORT_RESULT_FILE=" \
   "결과 채널은 제거됨 — 자동 재시도가 없으므로 부모가 상태를 전부 계산한다"
grep -q 'effort override: applied:xhigh' "$TMP/out_c3_codex"
chk $? "AC23 완료 출력에 applied 상태 표시"

run_turn claude c3_claude xhigh 200000 >/dev/null
eq "$(grep '^TOOL_EFFORT=' "$TMP/cap/claude.env")"        "TOOL_EFFORT="        "claude stub 환경에 TOOL_EFFORT 부재"
eq "$(grep '^EFFORT_SOURCE=' "$TMP/cap/claude.env")"      "EFFORT_SOURCE="      "claude stub 환경에 EFFORT_SOURCE 부재"
grep -q 'effort override: not-applicable (tool=claude)' "$TMP/out_c3_claude"
chk $? "AC23 claude 선택 시 codex 값을 보고하지 않음"

echo "=== 케이스 4: 호출자가 내부 변수를 미리 export 한 환경 ==="
# 깨끗한 환경만 검사하면 AC 32 의 "codex 전용" 보증이 입력 환경에 따라 깨지는 것을 놓친다.
run_turn_with_env() { # run_turn_with_env <tool> <라벨>
  reset_session
  rm -f "$TMP/cap/codex" "$TMP/cap/claude" "$TMP/cap/codex.env" "$TMP/cap/claude.env"
  write_cfg "$1" ""
  (
    cd "$TMP"
    TOOL_EFFORT=leaked EFFORT_SOURCE=leaked-source REVIEW_PROMPT_INLINE_MAX_BYTES=200000 \
      bash "$TMP/rd-workflow/scripts/run_review_turn.sh" sess >"$TMP/out_$2" 2>"$TMP/err_$2"
    echo "rc=$?"
  )
}
r="$(run_turn_with_env claude c4_claude)"
eq "$r" "rc=0" "사전 export 환경에서도 claude 경로 정상 완료"
eq "$(grep '^TOOL_EFFORT=' "$TMP/cap/claude.env")"   "TOOL_EFFORT="   "AC32 사전 export 된 TOOL_EFFORT 가 claude 로 새지 않음"
eq "$(grep '^EFFORT_SOURCE=' "$TMP/cap/claude.env")" "EFFORT_SOURCE=" "AC32 사전 export 된 EFFORT_SOURCE 가 claude 로 새지 않음"

r="$(run_turn_with_env codex c4_codex)"
eq "$r" "rc=0" "사전 export 환경에서도 codex 경로 정상 완료"
eq "$(grep '^TOOL_EFFORT=' "$TMP/cap/codex.env")" "TOOL_EFFORT=" \
   "AC2 설정 부재 시 사전 export 된 값이 codex 로 새지 않음 (후퇴 없음)"
grep -q 'effort override: none/global' "$TMP/out_c4_codex"
chk $? "AC23 설정 부재 시 none/global 로 보고 (상속값에 오염되지 않음)"

echo "=== 케이스 5: stub 고정 — 실 CLI 에 닿지 않았는가 ==="
# 위 네 케이스는 stub 이 걷히면 결국 실패하지만, 실패하기까지 호출당 워치독 만료(600초)를
# 기다립니다. 그 대기 자체가 결함이므로 "실 CLI 를 부르려 했다" 를 별도로 단언합니다.
assert_no_real_cli "케이스 1~4 전 구간에서 실제 codex·claude CLI 가 호출되지 않음 (stub 만 사용)"

echo "=== 케이스 6: 가드 자체가 살아 있는가 ==="
# 이 결함의 본질은 "stub 이 걷혔는데도 테스트가 조용히 기다린 것" 입니다. 그래서 가드가
# 실제로 발동하는지, 그리고 **대기 없이** 실패하는지를 고정합니다. bin 키가 없는 config 는
# production 의 실제 형태이자 fixture 가 우회당했을 때 만들어지는 상태와 같습니다.
cat > "$TMP/rd-workflow/config/review-tools.json" <<'EOF'
{
  "default_priority": ["codex"],
  "tools": { "codex": {} }
}
EOF
reset_session
: > "$TRIPWIRE_LOG"
guard_start="$(date +%s)"
(
  cd "$TMP"
  REVIEW_PROMPT_INLINE_MAX_BYTES=200000 \
    bash "$TMP/rd-workflow/scripts/run_review_turn.sh" sess >"$TMP/out_c6" 2>"$TMP/err_c6"
)
guard_rc=$?
guard_elapsed=$(( $(date +%s) - guard_start ))

[ "$guard_rc" -ne 0 ]
chk $? "bin 미지정이면 턴이 실패한다 (실 CLI 로 조용히 넘어가지 않음)"
grep -q '^codex$' "$TRIPWIRE_LOG"
chk $? "이름 폴백이 tripwire 에 걸린다 — 가드가 죽어 있지 않음"
# 상한은 WAIT_TIMEOUT(30초)보다 작아야 의미가 있습니다. 워치독을 한 번이라도 끝까지
# 기다렸다면 이 단언이 깨집니다. tripwire 경로의 실측은 수 초입니다.
[ "$guard_elapsed" -lt 20 ]
chk $? "대기 없이 즉시 실패한다 — 워치독 만료를 기다리지 않음 (실측 ${guard_elapsed}초)"
: > "$TRIPWIRE_LOG"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_review_adapter_parity: ALL PASS"
  exit 0
else
  echo "test_review_adapter_parity: FAILED"
  exit 1
fi
