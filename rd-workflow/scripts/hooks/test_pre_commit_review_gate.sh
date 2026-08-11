#!/bin/bash
# test_pre_commit_review_gate.sh — 커밋 판정 스코프 회귀 (R0-base·R1~R5)
# macOS /bin/bash 3.2 호환. fixture 패턴: test_pre_commit_archive_gate.sh 준용.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
PASS=0; FAIL=0
G=git; C=commit          # 이 파일 자신이 guard 에 걸리지 않도록 조립

FIX=""
cleanup() { [[ -n "$FIX" && -d "$FIX" ]] && rm -rf "$FIX"; FIX=""; }
# EXIT 는 정리만, INT/TERM 은 정리 후 **중단 의미를 보존**한다.
# 신호 handler 가 반환하면 사용자 Ctrl-C 후에도 다음 R 케이스가 계속 실행된다.
trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# 미해결(awaiting-reviewer) final-diff-review 세션 + 아카이브 신호 재료를 갖춘 fixture.
make_fixture() { # make_fixture <new|base>
  #   new  = 계약 함수 + 스캐너 + 교체된 gate (변경 후)
  #   base = **커밋 판정 단계를 제거한 파생 gate** (R0-base 용 — fixture 검증력 증명 전용).
  #          git 히스토리의 "변경 전 코드" 를 쓰지 않는다: 구현 후에는 HEAD 에도 개정판이
  #          있고 CI·조립 환경에는 히스토리가 없어 환경·시점 의존적이기 때문이다.
  local mode="${1:-new}" fx sess
  fx="$(mktemp -d)"
  mkdir -p "$fx/rd-workflow/scripts/hooks"
  cp "$HOOK_DIR/_guard_common.sh"          "$fx/rd-workflow/scripts/hooks/"
  cp "$SCRIPTS_DIR/_state_common.sh"       "$fx/rd-workflow/scripts/"
  if [[ "$mode" == base ]]; then
    # R0-base 는 **fixture 의 검증력**을 증명한다: 이 fixture 가 archive signal 을 만들어
    # gate 의 차단 경로에 실제로 도달하는가. 그래서 커밋 판정 단계를 제거한 gate 를 쓴다
    # (커밋으로 간주하고 바로 아래 로직으로 간다). git 히스토리에 의존하지 않으므로
    # 구현 전·후·CI 어디서나 같은 결과를 낸다.
    awk '/^# git commit 패턴이 아니면 통과$/,/^fi$/ { next }
         /^# 실행 위치의 커밋이 아니면 통과/ { next }
         /^# 1단 필터는 command_targets_our_commit/ { next }
         /^command_targets_our_commit /  { next }
         { print }' "$HOOK_DIR/pre_commit_review_gate.sh" \
      > "$fx/rd-workflow/scripts/hooks/pre_commit_review_gate.sh"
    if grep -qE 'command_targets_our_commit|git\\ \*commit' "$fx/rd-workflow/scripts/hooks/pre_commit_review_gate.sh"; then
      printf 'FATAL: baseline gate 에서 커밋 판정 단계를 제거하지 못했습니다 — R0-base 를 신뢰할 수 없습니다.\n' >&2
      exit 1
    fi
  else
    cp "$HOOK_DIR/pre_commit_review_gate.sh" "$fx/rd-workflow/scripts/hooks/"
  fi
  # 스캐너 누락 시 폴백 경로로 테스트되어 거짓 통과한다 — 반드시 함께 복사한다.
  [[ -f "$HOOK_DIR/_commit_scan.awk" ]] && cp "$HOOK_DIR/_commit_scan.awk" "$fx/rd-workflow/scripts/hooks/"
  mkdir -p "$fx/rd-workflow-workspace/.lifecycle"
  # AS2 archive signal: status=대기 중 + short-title=- 가 hook 이 인식하는 신호다.
  # AS1(staged request-archive/ 추가)은 git index 조작이 필요해 fixture 가 무거워진다.
  cat > "$fx/rd-workflow-workspace/.lifecycle/task-state" <<'TSEOF'
schema=1
short-title=-
status=대기 중
fr-branch=null
worktree-path=null
source-fr=-
TSEOF
  sess="$fx/rd-workflow-workspace/handoffs/review_pipeline/20260101_000000_final-diff-review"
  mkdir -p "$sess"
  printf '%s\n' "# Review Session" "" "## Status" "awaiting-reviewer" "" \
                "## Branch Context" "- short-title: t1" > "$sess/SESSION.md"
  printf '%s\n' "# Review Checkpoint" "" "## Open Issues" "- F1 미해소" > "$sess/CHECKPOINT.md"
  printf '%s\n' "$fx"
}

json_str() {
  # awk -v 는 값에 개행이 있으면 "newline in string" 으로 실패한다(실측). heredoc 케이스가
  # 전부 무효가 되므로 stdin 으로 넘겨 줄 단위로 조립한다.
  printf '"%s"' "$(printf '%s' "$1" | awk 'BEGIN{ORS=""} {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); if (NR>1) printf "\\n"; printf "%s", $0 }')"
}

check() { # check <id> <기대 exit> <cmd> [mode] [기대메시지]
  local id="$1" want="$2" cmd="$3" mode="${4:-new}" msg="${5:-}" out rc
  cleanup; FIX="$(make_fixture "$mode")"
  out=$( cd "$FIX" && printf '{"tool_input":{"command":%s}}' "$(json_str "$cmd")" \
         | bash "$FIX/rd-workflow/scripts/hooks/pre_commit_review_gate.sh" 2>&1 ); rc=$?
  if [[ "$rc" != "$want" ]]; then
    FAIL=$((FAIL+1)); printf 'FAIL %s exit=%s (기대 %s)\n  cmd: %s\n  out: %s\n' \
      "$id" "$rc" "$want" "$cmd" "$out" >&2; return
  fi
  # 차단 이유는 사용자에게 보이는 계약이므로 메시지도 단언한다.
  if [[ -n "$msg" && "$out" != *"$msg"* ]]; then
    FAIL=$((FAIL+1)); printf 'FAIL %s 메시지에 [%s] 없음\n  out: %s\n' "$id" "$msg" "$out" >&2; return
  fi
  PASS=$((PASS+1))
}

OUT_DIR="$(mktemp -d)"   # 프로젝트 밖 실재 경로

# R0-base: **fixture 의 검증력**을 먼저 증명한다 — 커밋 판정 단계를 제거한 gate 로
#          archive signal 차단 경로에 실제로 도달하는지 확인한다. 통과하지 않으면
#          fixture 가 신호를 만들지 못한 것이므로 R1 의 exit 2 는 아무것도 증명하지 않는다.
check R0-base 2 "$G $C -m 'chore: REQUEST 아카이브'" base "diff review가 종결되지 않았습니다"
# R1: 미해결 세션 + 실제 아카이브 신호 커밋 → 기존 차단 유지
check R1 2 "$G $C -m 'chore: REQUEST 아카이브'" new "diff review가 종결되지 않았습니다"
# R2: 미해결 세션 + 데이터 구간의 커밋 문자열 → 오탐 해소
check R2 0 "cat > f.md <<'EOF'
$G $C -m 'chore: REQUEST 아카이브' 로 차단됨
EOF"
# R3: 미해결 세션 + 프로젝트 밖 대상 → 판정 생략
check R3 0 "$G -C $OUT_DIR $C -m 'chore: REQUEST 아카이브'"
# R4: 인용 분할 커밋도 차단 — 1단 필터의 단일 소유자가 래퍼임을 확인 (AC17)
check R4 2 "$G com${C:3} -m x"
# R5: 다중 커밋 집계 — 첫 커밋이 밖이어도 두 번째가 안이면 차단 (AC14)
check R5 2 "$G -C $OUT_DIR $C -m a; $G $C -m b"

rm -rf "$OUT_DIR"
printf 'test_pre_commit_review_gate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
