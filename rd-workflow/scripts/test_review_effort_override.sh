#!/usr/bin/env bash
# test_review_effort_override.sh — reasoning effort override 판정·전달·즉시 실패·환경 격리 검증
# AC 1~9·13(개정: 자동 재시도 없음)·14b·23 (review-turn-latency-reduction)
# codex 실행 없이 판정 로직과 stub 어댑터만 검사한다.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
chk()  { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }
eq()   { # eq <실제> <기대> <라벨>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대=[$2] 실제=[$1])"; fi
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ============================================================
# 1) 해석 우선순위 (AC 1~8) — run_review_turn.sh 를 source 해 함수만 쓴다
# ============================================================
echo "=== 해석 우선순위 ==="

cfg() { printf '%s' "$2" > "$TMP/$1.json"; }
cfg full '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high","small_task_reasoning_effort":"medium"}},
 "overrides":{"request-review":{"tools":{"codex":{"reasoning_effort":"xhigh"}}}}}'
cfg lowfloor '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high","small_task_reasoning_effort":"low"}}}'
cfg minfloor '{"default_priority":["codex","claude"],
 "tools":{"codex":{"small_task_reasoning_effort":"minimal"}}}'
cfg nostkey '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high"}}}'
cfg same '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high"}},
 "overrides":{"request-review":{"tools":{"codex":{"reasoning_effort":"high"}}}}}'
cfg empty '{"default_priority":["codex","claude"],"tools":{"codex":{"bin":null}}}'

mk_session() { # $1=이름 $2=execution-path (빈 값이면 `## Review Scope` 자체 없음 = legacy)
  mkdir -p "$TMP/$1"
  { printf '# Review Session\n\n## Status\nawaiting-reviewer\n\n## Branch Context\n- fr-branch: null\n'; } > "$TMP/$1/SESSION.md"
  [ -n "$2" ] && printf '\n## Review Scope\n- execution-path: %s\n' "$2" >> "$TMP/$1/SESSION.md"
  printf '%s' "$TMP/$1/SESSION.md"
}
S_SMALL="$(mk_session s_small small-task)"
S_OTHER="$(mk_session s_other other)"
S_LEGACY="$(mk_session s_legacy '')"

# 서브셸에서 판정만 수행하고 `값|source|rejected|경고유무` 를 출력한다.
# 주의: resolve_effort_override 를 command substitution 으로 감싸면 서브셸이 되어
# EFFORT_* 할당이 소실된다. 직접 호출하고 경고만 파일로 캡처한다.
resolve() { # resolve <config> <session-file> <kill: unset|값> <review_type>
  (
    export REVIEW_TOOLS_CONFIG="$TMP/$1.json"
    if [ "$3" = "unset" ]; then unset RD_REVIEW_EFFORT_OVERRIDE; else export RD_REVIEW_EFFORT_OVERRIDE="$3"; fi
    source "${script_dir}/run_review_turn.sh" 2>/dev/null
    set +e   # source 대상이 set -e 를 켜므로 다시 해제한다
    review_type="$4"
    load_review_config_once 2>/dev/null
    resolve_effort_override "$(read_execution_path "$2")" 2>"$TMP/warn.txt"
    w=none; [ -s "$TMP/warn.txt" ] && w=warn
    printf '%s|%s|%s|%s' "$EFFORT_VALUE" "$EFFORT_SOURCE" "$EFFORT_REJECTED" "$w"
  )
}

eq "$(resolve empty    "$S_OTHER"  unset request-review)" "|global||none"          "AC2 설정 전무 → 미전달 (후퇴 없음)"
eq "$(resolve full     "$S_OTHER"  0     request-review)" "|kill-switch||none"     "AC3 kill switch 0 → 미전달, 경고 없음"
eq "$(resolve full     "$S_OTHER"  yes   request-review)" "|kill-switch||warn"     "AC4 kill switch 인식 불가 값 → 경고 + 미전달"
eq "$(resolve full     "$S_SMALL"  unset request-review)" "medium|small-task||none" "AC5 small-task 가 review type override 를 이김"
eq "$(resolve nostkey  "$S_SMALL"  unset request-review)" "high|tool-default||none" "AC6 small-task + 키 부재 → 자동 medium 없이 다음 단계"
eq "$(resolve lowfloor "$S_SMALL"  unset request-review)" "|below-floor|low|warn"   "AC7 small-task low → 경고 후 미전달 (보정 금지)"
eq "$(resolve minfloor "$S_SMALL"  unset request-review)" "|below-floor|minimal|warn" "AC7 small-task minimal 도 하한 거부"
eq "$(resolve full     "$S_LEGACY" unset request-review)" "xhigh|review-type||none" "AC8 legacy 세션 → small-task 미적용"
eq "$(resolve full     "$S_OTHER"  unset request-review)" "xhigh|review-type||none" "AC1 review type override"
eq "$(resolve full     "$S_OTHER"  unset diff-review)"    "high|tool-default||none" "AC1 매칭 override 없으면 tool 기본"
eq "$(resolve same     "$S_OTHER"  unset request-review)" "high|review-type||none"  "override 와 default 가 동일 값이어도 source 는 키 존재로 판정"

# execution-path 판정 원본 (AC 8)
ep() { ( source "${script_dir}/run_review_turn.sh" 2>/dev/null; set +e; read_execution_path "$1" ); }
eq "$(ep "$S_SMALL")"  "small-task" "AC8 execution-path: small-task"
eq "$(ep "$S_OTHER")"  "other"      "AC8 execution-path: other"
eq "$(ep "$S_LEGACY")" "unknown"    'AC8 "## Review Scope" 섹션 부재 → unknown'
printf '\n## Review Scope\n- execution-path: bogus\n' >> "$TMP/s_other/SESSION.md"
eq "$(ep "$TMP/s_other/SESSION.md")" "other" "AC8 첫 항목만 읽고 인식 불가 값에 영향받지 않음"

# AC 9 — 새 섹션이 Branch Context strict 검증을 깨뜨리지 않아야 한다.
# `## Review Scope` 를 Branch Context 안에 6번째 필드로 넣으면 5필드 strict 검증이
# 진행 중인 legacy 세션을 죽이므로 별도 섹션으로 뒀다. 그 경계가 실제로 유지되는지 고정한다.
mkdir -p "$TMP/bc"
cat > "$TMP/bc/SESSION.md" <<EOF
# Review Session

## Status
awaiting-reviewer

## Branch Context
- fr-branch: null
- worktree-path: null
- short-title: parity-fixture
- lifecycle-stage: request-review
- remote-mode: remote

## Review Scope
- execution-path: small-task
EOF
bc_out="$( ( source "${script_dir}/review_common.sh" 2>/dev/null; set +e
             parse_branch_context "$TMP/bc" | grep -c . ) )"
eq "$bc_out" "5" "AC9 Review Scope 가 뒤따라도 Branch Context 는 5필드로 파싱됨"
( source "${script_dir}/review_common.sh" 2>/dev/null; set +e
  validate_branch_context "$TMP/bc" >/dev/null 2>&1 )
chk $? "AC9 Branch Context strict 검증이 새 섹션과 공존해도 통과"
eq "$(ep "$TMP/bc/SESSION.md")" "small-task" "AC8 두 섹션 공존 시 execution-path 정상 판정"

# ============================================================
# 2) 가시성 상태 5종 (AC 23) — compute_effort_status
# ============================================================
# 어댑터가 effort 거부 시 즉시 실패하므로(자동 재시도 없음) "턴 성공 + effort 전달" =
# "codex 가 그 값을 수락" 이고, 부모가 아는 정보만으로 상태가 결정된다.
echo "=== 가시성 상태 5종 ==="
status() { # status <EFFORT_VALUE> <EFFORT_SOURCE> <EFFORT_REJECTED> <tool>
  (
    source "${script_dir}/run_review_turn.sh" 2>/dev/null
    set +e
    EFFORT_VALUE="$1"; EFFORT_SOURCE="$2"; EFFORT_REJECTED="$3"
    compute_effort_status "$4"
  )
}
eq "$(status xhigh review-type '' codex)" \
   "applied:xhigh (source: review-type)"      "상태1 applied (source 동반)"
eq "$(status medium small-task '' codex)" \
   "applied:medium (source: small-task)"      "상태1 source 가 실제 판정 단계를 반영"
eq "$(status '' global '' codex)"  "none/global"                 "상태2 none/global (설정 부재)"
eq "$(status '' kill-switch '' codex)" "disabled-by-kill-switch" "상태3 disabled-by-kill-switch"
eq "$(status '' below-floor low codex)" "rejected-below-floor:low" \
   "상태4 rejected-below-floor (설정 존재 — none/global 과 구분)"
eq "$(status xhigh review-type '' claude)" \
   "not-applicable (tool=claude)"             "상태5 claude fallback 시 codex 값을 보고하지 않음"
eq "$(status '' kill-switch '' claude)" \
   "not-applicable (tool=claude)"             "상태5 가 다른 상태보다 우선 (도구 판정이 먼저)"

# ============================================================
# 3) 어댑터 전달 계약 (AC 10) — stub codex
# ============================================================
# 자동 재시도는 없다. effort 를 전달하고, 거부되면 즉시 실패하며 부모가 복구 경로를 안내한다.
echo "=== 어댑터 전달 계약 ==="

STUB="$TMP/bin/codex"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# stub codex. STUB_MODE 로 시나리오를 제어한다.
has_effort=0
effort_val=""
for a in "$@"; do
  case "$a" in
    model_reasoning_effort=*) has_effort=1; effort_val="${a#model_reasoning_effort=}" ;;
  esac
done
cat > /dev/null   # 프롬프트 stdin 소비
{ printf 'has_effort=%s\n' "$has_effort"; printf 'effort_val=%s\n' "$effort_val"; } > "$ARGS_CAP"

write_turn() {
  printf '# Turn\n\n리뷰 본문\n' > "$EXPECTED_TURN_FILE"
  sed -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' \
    "$SESSION_PATH/SESSION.md" > "$SESSION_PATH/SESSION.md.tmp"
  mv "$SESSION_PATH/SESSION.md.tmp" "$SESSION_PATH/SESSION.md"
}

case "${STUB_MODE:-normal}" in
  normal) write_turn; exit 0 ;;
  reject-effort)
    # codex 가 지원하지 않는 effort 값을 거부하는 상황
    if [ "$has_effort" -eq 1 ]; then
      echo "error: invalid value for '-c model_reasoning_effort': unknown variant \`ultra\`" >&2
      exit 2
    fi
    write_turn; exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

prep_session() { # prep_session <이름> → 세션 디렉토리 출력
  local d="$TMP/adp_$1"
  rm -rf "$d"; mkdir -p "$d/turns"
  printf '# Review Session\n\n## Status\nawaiting-reviewer\n\n## Current Owner\nReviewer\n' > "$d/SESSION.md"
  printf '# Checkpoint\n\n## Open Issues\n- 없음\n' > "$d/CHECKPOINT.md"
  printf '# User Action\n\n## Question For User\n-\n' > "$d/USER_ACTION.md"
  printf '# Turn 001\n' > "$d/turns/001_claude.md"
  printf '%s' "$d"
}
printf 'prompt\n' > "$TMP/prompt.txt"

run_adapter() { # run_adapter <mode> <effort> <이름>
  local mode="$1" effort="$2" name="$3"
  local d; d="$(prep_session "$name")"
  : > "$TMP/args_$name"
  (
    set +e
    export STUB_MODE="$mode" TOOL_BIN="$STUB" \
      SESSION_PATH="$d" PROMPT_FILE="$TMP/prompt.txt" \
      EXPECTED_TURN_FILE="$d/turns/002_reviewer.md" \
      PROJECT_ROOT="$TMP" WAIT_TIMEOUT=20 ARGS_CAP="$TMP/args_$name"
    [ -n "$effort" ] && export TOOL_EFFORT="$effort"
    bash "${script_dir}/adapter_codex.sh" >"$TMP/out_$name" 2>"$TMP/err_$name"
    echo "rc=$?"
  )
}

r="$(run_adapter normal xhigh pass_effort)"
eq "$r" "rc=0" "effort 전달 시 정상 완료"
eq "$(grep '^effort_val=' "$TMP/args_pass_effort")" 'effort_val="xhigh"' \
   "AC10 -c model_reasoning_effort 값이 TOML 문자열로 전달됨"

r="$(run_adapter normal '' no_effort)"
eq "$r" "rc=0" "AC2 effort 미전달 시에도 정상 완료 (bash 3.2 빈 배열 전개 안전)"
eq "$(grep '^has_effort=' "$TMP/args_no_effort")" "has_effort=0" \
   "AC2 effort 미전달이면 -c 인자가 붙지 않음 (전역 설정을 따름)"

r="$(run_adapter reject-effort xhigh rejected)"
eq "$r" "rc=1" "effort 거부 시 즉시 실패한다 (자동 재시도 없음)"
grep -q 'unknown variant' "$TMP/err_rejected"
chk $? "거부 사유가 caller stderr 로 그대로 전달됨 (진단 가능)"
grep -q '재시도' "$TMP/err_rejected"; [ $? -ne 0 ]
chk $? "어댑터가 재시도를 시도하지 않음"

# 제거된 경로가 코드에 남아 있지 않은지 (재발 방지)
for pat in 'mkfifo' 'session_manifest' 'can_retry_without_effort' 'EFFORT_RESULT_FILE' 'join_timeout'; do
  grep -q "$pat" "${script_dir}/adapter_codex.sh"; [ $? -ne 0 ]
  chk $? "어댑터에 제거된 재시도 기계장치가 남지 않음: ${pat}"
done

# ============================================================
# 4) 호출자 환경 격리 (AC 32) — 사전 export 된 내부 변수가 새지 않아야 한다
# ============================================================
# env -u 로 제거하지 않으면 ① kill switch 를 켜도 어댑터가 상속값을 읽어 실제로 effort 를
# 전달하고 ② claude 어댑터도 상속받아 codex 전용 계약이 깨지며 ③ 표시와 실제가 어긋난다.
echo "=== 호출자 환경 격리 ==="

ISO="$TMP/iso"
mkdir -p "$ISO/rd-workflow/scripts" "$ISO/rd-workflow/config" \
         "$ISO/rd-workflow/docs/flows" "$ISO/rd-workflow/docs/prompts/review" "$ISO/cap"
for f in run_review_turn.sh review_common.sh adapter_codex.sh adapter_claude.sh; do
  cp "${script_dir}/$f" "$ISO/rd-workflow/scripts/$f"
done
printf '기준\n' > "$ISO/rd-workflow/docs/prompts/review/request_review.md"
printf '규칙\n' > "$ISO/rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md"
printf 'target\n' > "$ISO/TARGET.md"

cat > "$ISO/envstub" <<'ESEOF'
#!/usr/bin/env bash
{ printf 'ARGS=%s\n' "$*"
  printf 'TOOL_EFFORT=%s\n' "${TOOL_EFFORT+SET}"
  printf 'EFFORT_SOURCE=%s\n' "${EFFORT_SOURCE+SET}"
  printf 'VAL=%s\n' "${TOOL_EFFORT:-}"; } > "$CAPFILE"
cat > /dev/null
printf '# T\n' > "$EXPECTED_TURN_FILE"
sed -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' \
  "$SESSION_PATH/SESSION.md" > "$SESSION_PATH/S.tmp"
mv "$SESSION_PATH/S.tmp" "$SESSION_PATH/SESSION.md"
ESEOF
chmod +x "$ISO/envstub"

iso_session() {
  rm -rf "$ISO/sess"; mkdir -p "$ISO/sess/turns"
  cat > "$ISO/sess/SESSION.md" <<'EOF'
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
goal

## Turn Limit
20

## Review Scope
- execution-path: other
EOF
  printf '# C\n\n## Open Issues\n- 없음\n' > "$ISO/sess/CHECKPOINT.md"
  printf '# U\n\n## Question For User\n-\n' > "$ISO/sess/USER_ACTION.md"
  printf '# T1\n' > "$ISO/sess/turns/001_claude.md"
}
iso_cfg() { # iso_cfg <priority tool> <codex effort|"">
  local ef=""
  [ -n "$2" ] && ef=", \"reasoning_effort\": \"$2\""
  cat > "$ISO/rd-workflow/config/review-tools.json" <<EOF
{ "default_priority": ["$1"],
  "tools": { "codex": { "bin": "$ISO/envstub"$ef },
             "claude": { "bin": "$ISO/envstub", "self_review_policy": "warn", "self_review_warning": false } } }
EOF
}

# 케이스 A: kill switch 가 켜졌는데 호출자 환경에 TOOL_EFFORT 가 남아 있음
iso_session; iso_cfg codex high
( cd "$ISO" && RD_REVIEW_EFFORT_OVERRIDE=0 TOOL_EFFORT=xhigh EFFORT_SOURCE=bogus \
    CAPFILE="$ISO/cap/a" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_a" 2>"$ISO/err_a" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/a")" "TOOL_EFFORT=" \
   "kill switch 시 상속된 TOOL_EFFORT 가 어댑터에 도달하지 않음"
grep -q 'model_reasoning_effort' "$ISO/cap/a"; [ $? -ne 0 ]
chk $? "kill switch 시 -c model_reasoning_effort 가 실제로 전달되지 않음"
grep -q 'effort override: disabled-by-kill-switch' "$ISO/out_a"
chk $? "표시와 실제가 일치 (거짓 보고 없음)"

# 케이스 B: claude 선택 + 호출자가 내부 변수를 export
iso_session; iso_cfg claude high
( cd "$ISO" && TOOL_EFFORT=xhigh EFFORT_SOURCE=review-type \
    CAPFILE="$ISO/cap/b" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_b" 2>"$ISO/err_b" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/b")"   "TOOL_EFFORT="   "AC32 claude 환경에 TOOL_EFFORT 부재"
eq "$(grep '^EFFORT_SOURCE=' "$ISO/cap/b")" "EFFORT_SOURCE=" "AC32 claude 환경에 EFFORT_SOURCE 부재"
grep -q 'effort override: not-applicable (tool=claude)' "$ISO/out_b"
chk $? "AC23 claude 선택 시 codex 값을 보고하지 않음"

# 케이스 C: 설정 부재 + 호출자가 TOOL_EFFORT export (후퇴 없음 보증)
iso_session; iso_cfg codex ""
( cd "$ISO" && TOOL_EFFORT=xhigh CAPFILE="$ISO/cap/c" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_c" 2>"$ISO/err_c" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/c")" "TOOL_EFFORT=" \
   "AC2 설정 부재 시 상속값이 전역 설정을 덮어쓰지 못함"
grep -q 'effort override: none/global' "$ISO/out_c"
chk $? "AC2 설정 부재 시 none/global 로 보고"

# 케이스 D: 정상 주입 경로가 여전히 동작 (격리가 기능을 죽이지 않았는지)
iso_session; iso_cfg codex high
( cd "$ISO" && CAPFILE="$ISO/cap/d" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_d" 2>"$ISO/err_d" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/d")" "TOOL_EFFORT=SET" "설정된 effort 는 정상 주입됨"
eq "$(grep '^VAL=' "$ISO/cap/d")"         "VAL=high"        "주입값이 계산 결과와 일치"
grep -q 'effort override: applied:high (source: tool-default)' "$ISO/out_d"
chk $? "AC23 applied 상태와 source 표시"

# 케이스 E: 어댑터 실패 시 복구 안내 (자동 재시도의 대체 경로)
iso_session
cat > "$ISO/failstub" <<'FSEOF'
#!/usr/bin/env bash
cat > /dev/null
echo "error: invalid value for '-c model_reasoning_effort': unknown variant" >&2
exit 2
FSEOF
chmod +x "$ISO/failstub"
cat > "$ISO/rd-workflow/config/review-tools.json" <<EOF
{ "default_priority": ["codex"],
  "tools": { "codex": { "bin": "$ISO/failstub", "reasoning_effort": "ultra" } } }
EOF
( cd "$ISO" && WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_e" 2>"$ISO/err_e" )
grep -q "reasoning effort 'ultra'" "$ISO/err_e"
chk $? "실패 시 전달한 effort 값을 알려줌"
grep -q 'RD_REVIEW_EFFORT_OVERRIDE=0' "$ISO/err_e"
chk $? "실패 시 kill switch 복구 경로를 안내함"
grep -q 'review-tools.json' "$ISO/err_e"
chk $? "실패 시 키 제거 복구 경로를 안내함"

# ============================================================
# 5) B·C 인라인 상태 표시 (AC 23) — 부모 표시와 프롬프트 식별자가 정확히 일치해야 한다
# ============================================================
echo "=== 인라인 상태 표시 5 케이스 ==="
IR="$TMP/inline"; mkdir -p "$IR/sess/turns" "$IR/rd-workflow/docs/prompts/review" "$IR/rd-workflow/docs/flows"
printf '# S\n\n## Status\nawaiting-reviewer\n' > "$IR/sess/SESSION.md"
printf '# C\n\n## Open Issues\n- 없음\n'       > "$IR/sess/CHECKPOINT.md"
printf '# U\n\n## Question For User\n-\n'      > "$IR/sess/USER_ACTION.md"
printf '# T\n\n본문\n'                          > "$IR/sess/turns/001_claude.md"
printf '리뷰 기준 본문\n'                       > "$IR/rd-workflow/docs/prompts/review/request_review.md"
{ i=0; while [ $i -lt 300 ]; do printf 'filler %s ------------------------------------------------\n' "$i"; i=$((i+1)); done; } \
  > "$IR/rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md"

PIPE_REL='rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md'
CRIT_REL='rd-workflow/docs/prompts/review/request_review.md'

gen_inline_raw() { # gen_inline_raw <출력> <review_type> <cap> → 부모 표시 줄 원문
  (
    source "${script_dir}/review_common.sh" 2>/dev/null
    set +e
    PROJECT_ROOT="$IR" REVIEW_PROMPT_INLINE_MAX_BYTES="$3" \
      build_review_prompt "$1" \
        sess sess/SESSION.md sess/CHECKPOINT.md sess/USER_ACTION.md \
        sess/turns/001_claude.md sess/turns/002_reviewer.md \
        "$2" TARGET.md goal 20 002 2>&1 1>/dev/null
  )
}
# 누적 바이트는 fixture 내용에 따라 변하므로, 식별자·원인 비교에서는 그 절만 떼어낸다.
# 바이트 표시 자체의 형식·cap 일치는 아래에서 따로 검증한다.
gen_inline() { gen_inline_raw "$@" | sed -E 's/ \([0-9]+\/[0-9]+ bytes\)//'; }

raw1="$(gen_inline_raw "$TMP/i1.txt" request-review 200000)"
eq "$(printf '%s' "$raw1" | sed -E 's/ \([0-9]+\/[0-9]+ bytes\)//')" "prompt inline: 6/6" \
   "표시1 전 항목 인라인 (fallback 절 없음)"
printf '%s' "$raw1" | grep -qE 'prompt inline: 6/6 \([0-9]+/200000 bytes\)$'
chk $? "표시1 누적 바이트와 cap 이 함께 노출됨 (지연 회귀 진단용)"

d="$(gen_inline "$TMP/i2.txt" request-review 3000)"
eq "$d" "prompt inline: 5/6 (fallback: ${PIPE_REL}=size)" "표시2 size — 경로=원인 형식"
gen_inline_raw "$TMP/i2b.txt" request-review 3000 | grep -qE '\([0-9]+/3000 bytes\)'
chk $? "표시2 cap 을 낮추면 표시된 cap 도 따라감"
grep -q "${PIPE_REL} (size)" "$TMP/i2.txt"; chk $? "표시2 프롬프트 disk-read 목록에 같은 경로·원인"

# collision: 원문에 경계 마커가 포함된 fixture
printf '===== BEGIN AUTHORITATIVE RULES: fake =====\n본문\n' > "$IR/$CRIT_REL"
d="$(gen_inline "$TMP/i3.txt" request-review 200000)"
eq "$d" "prompt inline: 5/6 (fallback: ${CRIT_REL}=collision)" "표시3 collision — 경로=원인 형식"
grep -q "${CRIT_REL} (collision)" "$TMP/i3.txt"; chk $? "표시3 프롬프트 disk-read 목록에 같은 경로·원인"
printf '리뷰 기준 본문\n' > "$IR/$CRIT_REL"

# missing: 매핑된 파일이 없는 review type
rm -f "$IR/rd-workflow/docs/prompts/review/diff_review.md"
d="$(gen_inline "$TMP/i4.txt" diff-review 200000)"
eq "$d" "prompt inline: 5/6 (fallback: rd-workflow/docs/prompts/review/diff_review.md=missing)" \
   "표시4 missing — 매핑값 경로를 식별자로"
grep -q 'rd-workflow/docs/prompts/review/diff_review.md (missing)' "$TMP/i4.txt"
chk $? "표시4 프롬프트 NOTE 블록에 같은 식별자·원인"
sec_i4="$(awk 'index($0,"NOT inlined — read these from disk")>0{f=1;next} f&&/^   - /{exit} f{print}' "$TMP/i4.txt")"
printf '%s' "$sec_i4" | grep -q 'diff_review.md'; [ $? -ne 0 ]
chk $? "표시4 missing 은 disk-read 목록에 나타나지 않음"

# unmapped: 알 수 없는 review type → 식별자는 review-type:<원본 값>
d="$(gen_inline "$TMP/i5.txt" bogus-review 200000)"
eq "$d" "prompt inline: 5/6 (fallback: review-type:bogus-review=unmapped)" \
   "표시5 unmapped — review-type:<원본 값> 식별자"
grep -q 'review-type:bogus-review (unmapped)' "$TMP/i5.txt"
chk $? "표시5 프롬프트 NOTE 블록에 같은 식별자·원인"
sec_i5="$(awk 'index($0,"NOT inlined — read these from disk")>0{f=1;next} f&&/^   - /{exit} f{print}' "$TMP/i5.txt")"
printf '%s' "$sec_i5" | grep -q 'review-type:bogus-review'; [ $? -ne 0 ]
chk $? "표시5 unmapped 는 disk-read 목록에 나타나지 않음"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_review_effort_override: ALL PASS"
  exit 0
else
  echo "test_review_effort_override: FAILED"
  exit 1
fi
