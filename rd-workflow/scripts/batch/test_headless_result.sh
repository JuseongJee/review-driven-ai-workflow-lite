#!/bin/bash
# test_headless_result.sh — headless_result.sh (route·tokens·cost-item·cost-total) 단위 테스트.
# 임시 디렉터리만 쓰며 네트워크·git 이 필요 없다. macOS /bin/bash 3.2 호환.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HR="$DIR/headless_result.sh"
BATCH_MD="$DIR/../../claude_skills/fr/batch.md"
PASS=0
FAIL=0
WORK="$(mktemp -d)" || { echo "test_headless_result.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }

# eq <이름> <기대> <실제>
eq() { if [[ "$3" == "$2" ]]; then ok; else bad "$1: 기대 [$2] 실제 [$3]"; fi; }

# route_case <이름> <기대 토큰> <exit code> <outcome 내용(printf 형식, '-' 면 파일 없음)>
route_case() {
  local name="$1" want="$2" rc="$3" content="$4" f="$WORK/out-$1" got
  if [[ "$content" != "-" ]]; then printf "$content" > "$f"; else f="$WORK/absent-$1"; fi
  got="$(bash "$HR" route "$f" "$rc" 2>/dev/null)"
  eq "$name" "$want" "$got"
}

route_case R1   verify-done               0  'completed\n'
route_case R2   pause-unreaped            20 'blocked:time-cap-unreaped\n'
route_case R3   pause-resume-undetermined 20 'blocked:resume-undetermined\n'
route_case R4   pause-publish-timeout     20 'blocked:publish-incomplete\n사유: 발행 시간 상한(30분) 초과 — archive 를 중단했습니다\n'
route_case R5   archive-continue          20 'blocked:publish-incomplete\n사유: archive: push 실패\n'
route_case R6   pause-publish-unsafe      20 'blocked:publish-unsafe\n'
route_case R7   pause-resume              10 'resume\n'
route_case R8a  blocked                   20 'blocked:publish-failed\n'
route_case R8b  blocked                   20 'blocked:time-cap\n'
route_case R8c  blocked                   30 'queue-empty\n'
route_case R9   harness-error             40 'garbage\n'
route_case R9b  harness-error             40 '-'
route_case R9c  harness-error             40 ''
route_case R10  blocked                   31 'queue-blocked\n'
# 발행 중 신호(병합 전 중단)는 blocked 행으로 가면 다음 FR 로 넘어가므로 unknown(멈춤)이어야 한다
route_case R10a unknown                   143 'blocked:publish-failed\n사유: 신호 TERM 수신 — archive 를 중단했습니다\n'
route_case R10b unknown                   x  'garbage\n'
route_case R-ws pause-publish-unsafe      20 'blocked:publish-unsafe \r\n'

bash "$HR" route "$WORK/only-one" >/dev/null 2>&1; eq R-arg 2 "$?"

# 비용 tsv 만들기: mk <파일명> <printf 내용>
mk() { printf "$2" > "$WORK/$1"; }
T=$'\t'

mk c1 "cost${T}ok${T}0.5\ncost${T}ok${T}0.25\ncost${T}unknown${T}x\n"
eq C1 '· 비용 $0.7500 (확인 불가 1회)' "$(bash "$HR" cost-item "$WORK/c1" 2>/dev/null)"
mk c2 "cost${T}unknown${T}a\ncost${T}unknown${T}a\n"
eq C2 '· 비용 확인 불가 (2회)' "$(bash "$HR" cost-item "$WORK/c2" 2>/dev/null)"
eq C3 '· 비용 기록 없음' "$(bash "$HR" cost-item "$WORK/absent" 2>/dev/null)"
mk c3b "# 주석\n\nother${T}ok${T}9\n"
eq C3b '· 비용 기록 없음' "$(bash "$HR" cost-item "$WORK/c3b" 2>/dev/null)"
mkdir "$WORK/adir"
eq C4 '· 비용 집계 불가' "$(bash "$HR" cost-item "$WORK/adir" 2>/dev/null)"
mk cm "# c\n\nother${T}ok${T}9\ncost${T}ok${T}1\n"
eq C-mixed '· 비용 $1.0000 (확인 불가 0회)' "$(bash "$HR" cost-item "$WORK/cm" 2>/dev/null)"

mk t1a "cost${T}ok${T}1\n"
mk t1b "cost${T}ok${T}0.5\n"
eq T1 '실행 비용 합계: $1.5000 (정가 환산, 리뷰 도구 비용 제외) · 확인 불가 0회' \
  "$(bash "$HR" cost-total "$WORK/t1a" "$WORK/t1b" 2>/dev/null)"
mk t2 "cost${T}ok${T}1\ncost${T}unknown${T}x\n"
eq T2 '실행 비용 합계: $1.0000 (정가 환산, 리뷰 도구 비용 제외) · 확인 불가 1회 — 실제 비용은 더 큼' \
  "$(bash "$HR" cost-total "$WORK/t2" 2>/dev/null)"
eq T3 '실행 비용 합계: $1.0000 (정가 환산, 리뷰 도구 비용 제외) · 확인 불가 0회 — 실제 비용은 더 큼' \
  "$(bash "$HR" cost-total "$WORK/t1a" "$WORK/absent" 2>/dev/null)"
mk t4 "cost${T}unknown${T}x\n"
eq T4 '실행 비용 합계: 확인 불가 — 확인 불가 1회 · 비용 기록 없음 1항목' \
  "$(bash "$HR" cost-total "$WORK/t4" "$WORK/absent" 2>/dev/null)"
eq T5 "실행 비용 합계: 집계 불가 — 비용 기록 파일을 읽을 수 없음: $WORK/adir" \
  "$(bash "$HR" cost-total "$WORK/t1a" "$WORK/adir" 2>/dev/null)"
out="$(bash "$HR" cost-total 2>/dev/null)"; rc=$?
eq T6 "" "$out"; eq T6-rc 0 "$rc"

# 표 대조: tokens 의 각 토큰이 batch.md 표 행(`| \`토큰\` `)으로 있어야 한다.
tokens="$(bash "$HR" tokens 2>/dev/null)"
eq TBL-count 10 "$(printf '%s\n' "$tokens" | grep -c .)"
for tk in $tokens; do
  if [[ -f "$BATCH_MD" ]] && grep -q "^| \`$tk\` " "$BATCH_MD"; then ok; else bad "TBL: batch.md 표에 \`$tk\` 행이 없음"; fi
done

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
