#!/bin/bash
# test_subagent_dispatch_display.sh — 구현 subagent 모델·effort 표시 hook 의 판정 테이블.
# macOS /bin/bash 3.2 호환 (globstar/extglob 불사용).
#
# fixture 하나(mktemp -d)에 hook 과 source 파일만 복사하고, task-state status 와 models.json 만
# 바꿔 가며 hook 을 부른다. 정본: rd-workflow-workspace/specs/changes/
# 2026-11-23-1910-subagent-dispatch-model-display-hook-change-spec.md D6.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
BASH_BIN="/bin/bash"
[[ -x "$BASH_BIN" ]] || BASH_BIN="$(command -v bash)"
PASS=0
FAIL=0
FX=""

# hook 이 차단하지 않아도 _guard_common.sh 의 감사 로그 경로가 운영 로그를 가리키지 않게 한다.
RD_GUARD_BLOCK_LOG="$(mktemp -t rd-guard-block-test.XXXXXX 2>/dev/null)" \
  || RD_GUARD_BLOCK_LOG="/dev/null"
export RD_GUARD_BLOCK_LOG
cleanup() {
  [[ -n "$FX" && -d "$FX" ]] && rm -rf "$FX"
  [[ "$RD_GUARD_BLOCK_LOG" = "/dev/null" ]] || rm -f "$RD_GUARD_BLOCK_LOG"
}
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }

command -v jq >/dev/null 2>&1 && ok || { bad "환경: jq 미설치 — 이 테스트는 jq 로 JSON 을 검증합니다"; exit 1; }

FX="$(mktemp -d)" || { echo "환경: mktemp 실패" >&2; exit 1; }
[[ -n "$FX" && -d "$FX" ]] || { echo "환경: mktemp 경로 검증 실패" >&2; exit 1; }

# --- fixture 구성 ---
mkdir -p "$FX/rd-workflow/scripts/hooks" "$FX/rd-workflow/config" "$FX/rd-workflow-workspace/.lifecycle" \
  || { echo "환경: fixture 폴더 생성 실패" >&2; exit 1; }
cp "$HOOK_DIR/subagent_dispatch_display.sh" "$HOOK_DIR/_guard_common.sh" "$FX/rd-workflow/scripts/hooks/" 2>/dev/null \
  || bad "fixture: hook·_guard_common.sh 복사 실패 (hook 파일 없음?)"
for f in "$HOOK_DIR"/*.awk; do [[ -f "$f" ]] && cp "$f" "$FX/rd-workflow/scripts/hooks/"; done
cp "$SCRIPTS_DIR/_state_common.sh" "$SCRIPTS_DIR/model_select.sh" "$FX/rd-workflow/scripts/" 2>/dev/null \
  || bad "fixture: _state_common.sh·model_select.sh 복사 실패"
cp "$FX/rd-workflow/scripts/model_select.sh" "$FX/model_select.orig"
HOOK_FX="$FX/rd-workflow/scripts/hooks/subagent_dispatch_display.sh"

set_status_in() { # <루트> <status> <short-title>
  mkdir -p "$1/rd-workflow-workspace/.lifecycle"
  printf 'schema=1\nshort-title=%s\nstatus=%s\n' "$3" "$2" > "$1/rd-workflow-workspace/.lifecycle/task-state"
}
set_status() { set_status_in "$FX" "$1" "${2:-fx-task}"; }
set_models() { mkdir -p "$FX/rd-workflow/config"; printf '%s\n' "$1" > "$FX/rd-workflow/config/models.json"; }

OUT=""; RC=0; MSG=""; PARSE=1; PASSED=""; REST=""
# run_hook <입력 JSON>
run_hook() {
  OUT="$(printf '%s' "$1" | env -u RD_MODELS_CONFIG "$BASH_BIN" "$HOOK_FX" 2>/dev/null)"; RC=$?
  MSG=""; PARSE=1
  if [[ -n "$OUT" ]]; then
    if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
      PARSE=0; MSG="$(printf '%s' "$OUT" | jq -r '.systemMessage // ""')"
    fi
  fi
  split_msg
}
split_msg() {
  case "$MSG" in
    *" | 설정"*) PASSED="${MSG%% | 설정*}"; REST="${MSG#*" | 설정"}" ;;
    *) PASSED="$MSG"; REST="" ;;
  esac
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
want_in()  { if has "$2" "$3"; then ok; else bad "$1: '$3' 없음 — [$2]"; fi; }
want_out() { if has "$2" "$3"; then bad "$1: '$3' 있음 — [$2]"; else ok; fi; }
want_eq()  { if [[ "$2" == "$3" ]]; then ok; else bad "$1: 기대 [$3] 실제 [$2]"; fi; }
common()   { # <이름> : exit 0 + JSON 파싱 성공
  want_eq "$1 exit" "$RC" "0"
  want_eq "$1 JSON 파싱" "$PARSE" "0"
}
input() { # <model|-> <effort|->
  local m="" e=""
  [[ "$1" != "-" ]] && m=",\"model\":\"$1\""
  [[ "$2" != "-" ]] && e=",\"effort\":\"$2\""
  printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Agent","effort":{"level":"medium"},"tool_input":{"description":"d","prompt":"p"%s%s}}' "$m" "$e"
}
input_cwd() { # <cwd> <model> <effort>
  local m="" e=""
  [[ "$2" != "-" ]] && m=",\"model\":\"$2\""
  [[ "$3" != "-" ]] && e=",\"effort\":\"$3\""
  printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Agent","cwd":"%s","effort":{"level":"medium"},"tool_input":{"description":"d","prompt":"p"%s%s}}' "$1" "$m" "$e"
}
sel_line() { env -u RD_MODELS_CONFIG "$BASH_BIN" "$FX/rd-workflow/scripts/model_select.sh" subagent 2>/dev/null | tail -1; }

OPUS_HIGH='{"subagent":{"claude":{"model":"opus","effort":"high"}}}'

# T1 일치 입력
set_status "구현 중"; set_models "$OPUS_HIGH"
run_hook "$(input opus high)"
common T1
want_in  "T1 넘긴 값 절" "$PASSED" "subagent 넘긴 값 (fx-task) — 모델: opus · effort: high"
want_in  "T1 설정 절"   "$REST"   "$(sel_line)"
want_out "T1 다름 미표시" "$MSG" "설정과 다름"

# T2a 모델만 다름
run_hook "$(input haiku high)"
common T2a
want_in "T2a 넘긴 값 절" "$PASSED" "모델: haiku"
want_in "T2a 다름 표시" "$MSG" "설정과 다름"

# T2b effort 만 다름
run_hook "$(input opus low)"
common T2b
want_in "T2b 넘긴 값 절" "$PASSED" "effort: low"
want_in "T2b 설정 절" "$REST" "effort: high (models.json subagent.claude.effort)"
want_in "T2b 다름 표시" "$MSG" "설정과 다름"

# T3 설정 비움 + 넘기지 않음 + 최상위 세션 effort 는 무시
set_models '{"subagent":{"claude":{"model":"default","effort":null}}}'
run_hook "$(input - -)"
common T3
want_in  "T3 넘기지 않음" "$MSG" "모델: 넘기지 않음 · effort: 넘기지 않음"
want_out "T3 다름 미표시" "$MSG" "설정과 다름"

# T4 선택기가 성공하면서 경고를 냄
set_models '{"subagent":{"claude":{"model":"claude-opus-4-1","effort":null}}}'
run_hook "$(input sonnet -)"
common T4
want_in "T4 경고" "$MSG" "경고:"
want_in "T4 경고 내용" "$MSG" "고정 이름"

# T5 선택기 실패
set_models "$OPUS_HIGH"
printf '#!/bin/bash\nexit 3\n' > "$FX/rd-workflow/scripts/model_select.sh"
run_hook "$(input opus high)"
common T5
want_in "T5 실패 문구" "$MSG" "설정 확인 실패"
want_in "T5 종료 코드" "$MSG" "종료 코드 3"
want_in "T5 넘긴 값 절" "$PASSED" "모델: opus · effort: high"
cp "$FX/model_select.orig" "$FX/rd-workflow/scripts/model_select.sh"

# T6 구현 중 밖
for s in "spec/plan 작성 중" "diff review 대기"; do
  set_status "$s"
  run_hook "$(input opus high)"
  want_eq "T6 exit ($s)" "$RC" "0"
  want_eq "T6 무출력 ($s)" "$OUT" ""
done
set_status "구현 중"

# T7 무인 세션이 작업 worktree 로 이동한 뒤의 호출
set_status "대기 중" "fx-main"; set_models "$OPUS_HIGH"
if git init -q "$FX" >/dev/null 2>&1 && mkdir -p "$FX/.worktrees/wt/sub" && git init -q "$FX/.worktrees/wt" >/dev/null 2>&1; then
  WT="$FX/.worktrees/wt"
  set_status_in "$WT" "구현 중" "fx-wt"
  mkdir -p "$WT/rd-workflow/config" "$WT/rd-workflow/scripts"
  printf '%s\n' '{"subagent":{"claude":{"model":"haiku","effort":"low"}}}' > "$WT/rd-workflow/config/models.json"
  cat > "$WT/rd-workflow/scripts/model_select.sh" <<'SEL'
#!/bin/bash
printf 'model=haiku\neffort=low\n설정 파일: x\nsubagent 모델: WT-SELECTOR\n'
exit 0
SEL
  run_hook "$(input_cwd "$WT/sub" haiku low)"
  common T7
  want_in  "T7 작업 이름" "$MSG" "(fx-wt)"
  want_in  "T7 작업 쪽 설정" "$MSG" "subagent 모델: haiku (models.json"
  want_out "T7 시작 쪽 설정 미사용" "$MSG" "subagent 모델: opus"
  want_out "T7 작업 쪽 선택기 미실행" "$MSG" "WT-SELECTOR"
  want_out "T7 다름 미표시" "$MSG" "설정과 다름"

  # T8 작업 쪽 설정 파일 없음
  mv "$WT/rd-workflow/config/models.json" "$FX/wt-models.bak"
  printf '{"subagent":"opus"}\n' > "$FX/rd-workflow/config/model-strategy.json"
  run_hook "$(input_cwd "$WT/sub" opus -)"
  common T8
  want_in  "T8 옛 키 출처" "$REST" "subagent 모델: opus (model-strategy.json subagent — 옛 키)"
  want_in  "T8 effort 없음" "$REST" "effort: 넘기지 않음"
  want_out "T8 시작 쪽 effort 미사용" "$MSG" "effort: high"
  want_out "T8 다름 미표시" "$MSG" "설정과 다름"
  mv "$FX/wt-models.bak" "$WT/rd-workflow/config/models.json"
  rm -f "$FX/rd-workflow/config/model-strategy.json"
else
  bad "T7·T8: fixture git init 실패"
fi

echo "test_subagent_dispatch_display: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
