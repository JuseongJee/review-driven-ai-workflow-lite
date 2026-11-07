#!/usr/bin/env bash
# test_review_findings_check.sh — check_reviewer_findings 의 형식·인용 검사 결정적 검증
# 리뷰어 CLI 없이 턴 파일 fixture 만 검사한다.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/review_common.sh"
# review_common.sh 가 set -e 를 켜므로 해제한다 — 이 테스트는 grep 실패를 정상 신호로 쓴다.
set +e

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
chk()  { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }

TMP="$(mktemp -d)" || { echo "test_review_findings_check.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_review_findings_check.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export PROJECT_ROOT="$TMP"
mkdir -p "$TMP/src" "$TMP/sd"
{
  printf '#!/usr/bin/env bash\n'
  printf 'line two\nline three\nline four\n'
  printf 'echo "target line"\n'
  printf 'v=`pwd`\n'
  printf 'line seven\nline eight\nline nine\nline ten\n'
  printf 'col1\tcol2\n'
} > "$TMP/src/a.sh"

ERR="" ; TSV="$TMP/sd/finding_metrics.tsv"

# run_case <turn_body> [root] — 턴 파일을 쓰고 함수를 불러 stderr 를 ERR 에, tsv 를 TSV 에 남긴다.
run_case() {
  local body="$1" root="${2:-$TMP}"
  rm -f "$TSV"
  printf '# Turn 002 · Reviewer\n\n## Summary\ns\n\n## Findings\n%s\n\n## Agreement\n-\n' "$body" > "$TMP/sd/turn.md"
  ERR="$(PROJECT_ROOT="$root" check_reviewer_findings "$TMP/sd/turn.md" "$TMP/sd" 002 request_review 2>&1 >/dev/null)"
}
has()  { printf '%s\n' "$ERR" | grep -qF -- "$1"; }
warns() { printf '%s\n' "$ERR" | grep -c '⚠️'; }
head_of() { printf -- '- F1 [confidence 8/10] t\n  - 근거: %s\n' "$1"; }

# ok
run_case "$(head_of '`src/a.sh:5` — `echo "target line"`')"
[ "$(warns)" = "0" ]; chk $? "ok: 경고 없음"
has '인용 확인 1'; chk $? "ok: 요약에 인용 확인 1"
[ "$(wc -l < "$TSV" | tr -d ' ')" = "2" ]; chk $? "ok: tsv 2줄"
[ "$(sed -n 2p "$TSV" | cut -f7)" = "0" ]; chk $? "ok: tsv 위반 0"

# cite-mismatch
run_case "$(head_of '`src/a.sh:5` — `echo "other"`')"
has '(턴 002 F1): cite-mismatch'; chk $? "cite-mismatch: 경고"

# cite-path
run_case "$(head_of '`src/none.sh:5` — `x`')"
has 'cite-path'; chk $? "cite-path: 없는 파일"

# cite-path-normalize
run_case "$(head_of '`./src/a.sh:5` — `echo "target line"`')
$(printf '  - 근거: `%s/src/a.sh:5` — `echo "target line"`' "$TMP")"
[ "$(warns)" = "0" ]; chk $? "cite-path-normalize: ./ 접두와 루트 아래 절대 경로 허용"

# cite-first-line
run_case "$(head_of '`src/a.sh:1` — `#!/usr/bin/env bash`')"
[ "$(warns)" = "0" ]; chk $? "cite-first-line: 1번째 줄 인용 허용"

# cite-outside
mkdir -p "$TMP/proj/src"
printf 'outside\n' > "$TMP/outside.sh"
ln -s "$TMP/outside.sh" "$TMP/proj/src/link.sh"
run_case "$(head_of '`../outside.sh:1` — `outside`')
$(printf '  - 근거: `%s/proj/../outside.sh:1` — `outside`\n' "$TMP")
  - 근거: \`src/link.sh:1\` — \`outside\`" "$TMP/proj"
[ "$(printf '%s\n' "$ERR" | grep -c 'cite-path')" = "3" ]; chk $? "cite-outside: 근거 3건 모두 cite-path"

# cite-tab — 인용 원문의 탭 뒤까지 대조한다 (탭 앞만 맞는 인용은 mismatch)
run_case "$(head_of $'`src/a.sh:5` — `echo\tTHIS_DOES_NOT_EXIST`')"
has '(턴 002 F1): cite-mismatch'; chk $? "cite-tab-mismatch: 탭 뒤가 다른 인용은 경고"
run_case "$(head_of $'`src/a.sh:11` — `col1\tcol2`')"
[ "$(warns)" = "0" ]; chk $? "cite-tab-ok: 탭을 품은 원문 인용은 통과"

# cite-long-neighbor — 앞뒤 3줄에 긴 줄이 있어도 정확한 인용은 통과한다
{ printf 'const target = 1;\n'; head -c 100000 /dev/zero | tr '\0' x; printf '\n'; } > "$TMP/src/long.js"
run_case "$(head_of '`src/long.js:1` — `const target = 1;`')"
[ "$(warns)" = "0" ]; chk $? "cite-long-neighbor: 긴 주변 줄이 있어도 정확한 인용은 무경고"

# cite-backtick
run_case "$(head_of '`src/a.sh:6` — `v=`pwd``')"
[ "$(warns)" = "0" ]; chk $? "cite-backtick: 원문 안 백틱 허용"

# confidence-missing
run_case '- F1 t
  - 근거: `src/a.sh:5` — `echo "target line"`'
has 'confidence-missing'; chk $? "confidence-missing"

# cite-missing
run_case '- F1 [confidence 8/10] t'
has 'cite-missing'; chk $? "cite-missing"

# appendix-confidence
run_case '### 부록: 인용하지 못한 발견
- F2 [confidence 6/10] t
  - 인용하지 못한 이유: r'
has 'appendix-confidence'; chk $? "appendix-confidence"

# none
run_case '- 없음'
[ "$(warns)" = "0" ]; chk $? "none: 경고 없음"
has '발견 0'; chk $? "none: 요약 발견 0"

# not-a-finding
run_case '- F1 해소 — 설명'
has 'not-a-finding'; chk $? "not-a-finding"

# no-findings-section
printf '# Turn 002 · Reviewer\n\n## Summary\ns\n' > "$TMP/sd/turn.md"
ERR="$(check_reviewer_findings "$TMP/sd/turn.md" "$TMP/sd" 002 request_review 2>&1 >/dev/null)"
[ "$(warns)" = "0" ]; chk $? "no-findings-section: 경고 없음"
has '발견 0'; chk $? "no-findings-section: 요약 발견 0"

# unresolved-*: awaiting-user 의 CHECKPOINT Open Issues 형식 검사
uf_case() {
  printf '# Checkpoint\n\n## Summary\ns\n\n## Open Issues\n%s\n\n## Questions\n-\n' "$1" > "$TMP/sd/CHECKPOINT.md"
  ERR="$(check_unresolved_format "$TMP/sd/CHECKPOINT.md" 006 2>&1 >/dev/null)"
}
uf_case '- F2 (턴 004·006) — x | 해소 조건: y | 상태: z'
[ "$(warns)" = "0" ]; chk $? "unresolved-ok: 경고 없음"
uf_case '- 남은 쟁점 설명'
has '⚠️  미해결 형식 (턴 006): '; chk $? "unresolved-bad: 경고"
uf_case '- F2 — 설명 | 해소 조건: 수정'
has '미해결 형식 (턴 006)'; chk $? "unresolved-no-turn: 경고"
uf_case '- F2 (턴 004) — 설명'
has '미해결 형식 (턴 006)'; chk $? "unresolved-no-condition: 경고"
uf_case '- 없음'
[ "$(warns)" = "0" ]; chk $? "unresolved-none: 경고 없음"
uf_case '<!-- 안내 첫 줄 -->
<!-- 안내 둘째 줄 -->
- 없음'
[ "$(warns)" = "0" ]; chk $? "unresolved-comment-first: 안내 주석 뒤 마커"
uf_case '- None.'
[ "$(warns)" = "0" ]; chk $? "unresolved-none-dot: 경고 없음"

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
