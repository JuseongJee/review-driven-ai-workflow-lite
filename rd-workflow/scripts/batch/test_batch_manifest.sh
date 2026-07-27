#!/usr/bin/env bash
# batch_manifest.sh 단위 테스트. $(dirname) 상대참조로 정본에서 self-contained 실행.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="${DIR}/batch_manifest.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq 미설치 — batch_manifest 테스트 건너뜀"; exit 0
fi

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }
expect_code() { if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1 (expected exit $2, got $3)"; fi; }
expect_out()  { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

# 유효 manifest
cat > "$TMP/ok.json" <<'JSON'
{"batch_id":"t","created_at":"t","finish_policy":"merge","status":"preparing",
 "items":[
   {"slug":"a","order":1,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""},
   {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
bash "$H" validate "$TMP/ok.json"; expect_code "유효 manifest → 0" 0 $?

echo '{"status":"preparing","items":[]}' > "$TMP/nofp.json"
bash "$H" validate "$TMP/nofp.json"; expect_code "finish_policy 누락 → 1" 1 $?

echo '{"finish_policy":"none","status":"preparing","items":[]}' > "$TMP/none.json"
bash "$H" validate "$TMP/none.json"; expect_code "finish_policy=none 거부 → 1" 1 $?

echo '{"finish_policy":"weird","status":"preparing","items":[]}' > "$TMP/badfp.json"
bash "$H" validate "$TMP/badfp.json"; expect_code "finish_policy 오값 → 1" 1 $?

cat > "$TMP/dangle.json" <<'JSON'
{"finish_policy":"merge","status":"preparing",
 "items":[{"slug":"a","order":1,"depends_on":["c"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}]}
JSON
bash "$H" validate "$TMP/dangle.json"; expect_code "dangling 의존 → 1" 1 $?
err=$(bash "$H" validate "$TMP/dangle.json" 2>&1 >/dev/null)
case "$err" in *"존재하지 않는 slug 의존"*) pass "dangling stderr 사유" ;; *) fail "dangling stderr 사유 (got: $err)" ;; esac

cat > "$TMP/cycle.json" <<'JSON'
{"finish_policy":"merge","status":"preparing",
 "items":[
  {"slug":"a","order":1,"depends_on":["b"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""},
  {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
bash "$H" validate "$TMP/cycle.json"; expect_code "순환 의존 → 1" 1 $?

cat > "$TMP/exclbad.json" <<'JSON'
{"finish_policy":"merge","status":"preparing",
 "items":[
  {"slug":"a","order":1,"depends_on":[],"feasibility":"excluded","exclude_reason":"불가","state":"skipped","outcome":"","block_reason":""},
  {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
bash "$H" validate "$TMP/exclbad.json"; expect_code "validate: eligible이 excluded 의존(dead-end) → 1" 1 $?

echo '{"finish_policy":"merge","status":"weird","items":[]}' > "$TMP/badstatus.json"
bash "$H" validate "$TMP/badstatus.json"; expect_code "status enum 위반 → 1" 1 $?

echo '{"finish_policy":"merge","status":"preparing","items":[{"slug":"a","order":1,"depends_on":[],"feasibility":"eligible","state":"pendng"}]}' > "$TMP/badstate.json"
bash "$H" validate "$TMP/badstate.json"; expect_code "state enum 오타 → 1" 1 $?

echo '{"finish_policy":"merge","status":"preparing","items":[{"slug":"a","order":1,"depends_on":[],"feasibility":"eligble","state":"pending"}]}' > "$TMP/badfeas.json"
bash "$H" validate "$TMP/badfeas.json"; expect_code "feasibility enum 오타 → 1" 1 $?

cat > "$TMP/dupslug.json" <<'JSON'
{"finish_policy":"merge","status":"preparing",
 "items":[
  {"slug":"a","order":1,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""},
  {"slug":"a","order":2,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
bash "$H" validate "$TMP/dupslug.json"; expect_code "중복 slug → 1" 1 $?

echo '{"finish_policy":"merge","status":"preparing","items":[{"slug":"a","order":1.5,"depends_on":[],"feasibility":"eligible","state":"pending"}]}' > "$TMP/badorder.json"
bash "$H" validate "$TMP/badorder.json"; expect_code "order 비정수(1.5) → 1" 1 $?

echo '{"finish_policy":"merge","status":"preparing","items":[{"slug":"a","order":1,"depends_on":[],"feasibility":"excluded","exclude_reason":"불가","state":"pending","outcome":"","block_reason":""}]}' > "$TMP/exclstate.json"
bash "$H" validate "$TMP/exclstate.json"; expect_code "excluded인데 state≠skipped → 1" 1 $?

echo 'not json' > "$TMP/bad.json"
bash "$H" validate "$TMP/bad.json"; expect_code "JSON 파싱 실패 → 1" 1 $?

# --- next: 기본 pending 선정 ---
out=$(bash "$H" next "$TMP/ok.json"); expect_out "next: 의존없는 첫 대상 a" "a" "$out"

# --- set-state: a completed → next=b ---
cp "$TMP/ok.json" "$TMP/work.json"
bash "$H" set-state "$TMP/work.json" a completed completed; expect_code "set-state a completed → 0" 0 $?
out=$(bash "$H" next "$TMP/work.json"); expect_out "next: a완료 후 b" "b" "$out"
# manifest에 반영됐는지(flush)
st=$(jq -r '.items[]|select(.slug=="a")|.state' "$TMP/work.json"); expect_out "set-state flush 확인" "completed" "$st"

# --- set-state: 없는 slug → 1 ---
bash "$H" set-state "$TMP/work.json" zzz completed 2>/dev/null; expect_code "set-state 없는 slug → 1" 1 $?

# --- set-state: 잘못된 state → 2 ---
bash "$H" set-state "$TMP/work.json" a bogus 2>/dev/null; expect_code "set-state 잘못된 state → 2" 2 $?

# --- set-state sentinel: '-' 클리어, 빈 인자 유지 ---
cp "$TMP/ok.json" "$TMP/sent.json"
bash "$H" set-state "$TMP/sent.json" a blocked failed "원인 X" >/dev/null
br=$(jq -r '.items[]|select(.slug=="a")|.block_reason' "$TMP/sent.json")
expect_out "set-state: block_reason 기록" "원인 X" "$br"
bash "$H" set-state "$TMP/sent.json" a pending >/dev/null
br=$(jq -r '.items[]|select(.slug=="a")|.block_reason' "$TMP/sent.json")
oc=$(jq -r '.items[]|select(.slug=="a")|.outcome' "$TMP/sent.json")
expect_out "set-state: 빈 인자 = block_reason 유지" "원인 X" "$br"
expect_out "set-state: 빈 인자 = outcome 유지" "failed" "$oc"
bash "$H" set-state "$TMP/sent.json" a pending - - >/dev/null
br=$(jq -r '.items[]|select(.slug=="a")|.block_reason' "$TMP/sent.json")
oc=$(jq -r '.items[]|select(.slug=="a")|.outcome' "$TMP/sent.json")
expect_out "set-state: sentinel '-' = block_reason 클리어" "" "$br"
expect_out "set-state: sentinel '-' = outcome 클리어" "" "$oc"

# --- next: running 재개 우선 (exit 10 재개) ---
cp "$TMP/ok.json" "$TMP/resume.json"
bash "$H" set-state "$TMP/resume.json" a running >/dev/null
out=$(bash "$H" next "$TMP/resume.json"); expect_out "next: running 재개 우선(a)" "a" "$out"
# a running + b도 pending이지만 running이 우선
bash "$H" set-state "$TMP/resume.json" b pending >/dev/null
out=$(bash "$H" next "$TMP/resume.json"); expect_out "next: running(a)이 pending(b)보다 우선" "a" "$out"

# --- next: 모두 완료 → 빈값 ---
cp "$TMP/ok.json" "$TMP/done.json"
bash "$H" set-state "$TMP/done.json" a completed completed >/dev/null
bash "$H" set-state "$TMP/done.json" b completed completed >/dev/null
out=$(bash "$H" next "$TMP/done.json"); expect_out "next: 모두 완료 → 빈값" "" "$out"

# --- next: 의존 미충족이면 미선정 ---
cat > "$TMP/dep.json" <<'JSON'
{"finish_policy":"merge","status":"running",
 "items":[
  {"slug":"a","order":1,"depends_on":[],"feasibility":"excluded","exclude_reason":"불가","state":"skipped","outcome":"","block_reason":""},
  {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
out=$(bash "$H" next "$TMP/dep.json"); expect_out "next: 의존(a) 미완료면 b 미선정" "" "$out"

# --- next: dead-end (excluded a에 의존하는 eligible pending b) → 빈 stdout + exit 3 ---
cat > "$TMP/deadend.json" <<'JSON'
{"finish_policy":"merge","status":"running",
 "items":[
  {"slug":"a","order":1,"depends_on":[],"feasibility":"excluded","exclude_reason":"불가","state":"skipped","outcome":"","block_reason":""},
  {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
out=$(bash "$H" next "$TMP/deadend.json" 2>/dev/null); rc=$?
expect_out "next: dead-end stdout 빈값" "" "$out"
expect_code "next: dead-end → exit 3" 3 "$rc"
# 진짜 terminal(모두 completed) → exit 0
out=$(bash "$H" next "$TMP/done.json" 2>/dev/null); expect_code "next: 진짜 terminal → exit 0" 0 $?

# --- skip-dependents ---
cat > "$TMP/chain.json" <<'JSON'
{"finish_policy":"merge","status":"running",
 "items":[
  {"slug":"a","order":1,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"blocked","outcome":"","block_reason":"x"},
  {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""},
  {"slug":"c","order":3,"depends_on":["b"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""},
  {"slug":"d","order":4,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
out=$(bash "$H" skip-dependents "$TMP/chain.json" a | sort | tr '\n' ',')
expect_out "skip-dependents: a blocked → b,c (d 독립 제외)" "b,c," "$out"

out=$(bash "$H" skip-dependents "$TMP/chain.json" d | tr '\n' ',')
expect_out "skip-dependents: d blocked → 의존자 없음 빈값" "" "$out"

# --- summary ---
cat > "$TMP/mixed.json" <<'JSON'
{"finish_policy":"merge","status":"done",
 "items":[
  {"slug":"a","order":1,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"completed","outcome":"completed","block_reason":""},
  {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"blocked","outcome":"","block_reason":"x"},
  {"slug":"c","order":3,"depends_on":["b"],"feasibility":"eligible","exclude_reason":"","state":"skipped","outcome":"","block_reason":""},
  {"slug":"e","order":4,"depends_on":[],"feasibility":"excluded","exclude_reason":"불가","state":"skipped","outcome":"","block_reason":""}
 ]}
JSON
out=$(bash "$H" summary "$TMP/mixed.json")
# skipped 는 eligible 만(c). e 는 feasibility=excluded 라 excluded 로만 집계(중복 방지).
expect_out "summary 집계(excluded/skipped 배타)" "completed=1 skipped=1 blocked=1 excluded=1 pending=0 running=0" "$out"

cat > "$TMP/strand.json" <<'JSON'
{"finish_policy":"merge","status":"paused",
 "items":[
  {"slug":"a","order":1,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"running","outcome":"","block_reason":""},
  {"slug":"b","order":2,"depends_on":["a"],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""},
  {"slug":"c","order":3,"depends_on":[],"feasibility":"eligible","exclude_reason":"","state":"pending","outcome":"","block_reason":""}
 ]}
JSON
out=$(bash "$H" summary "$TMP/strand.json")
expect_out "summary: pending/running 카운터(stranded 집계)" "completed=0 skipped=0 blocked=0 excluded=0 pending=2 running=1" "$out"

# --- verify-done ---
ITEMS="$TMP/items"; ARCH="$TMP/arch"; mkdir -p "$ITEMS" "$ARCH"
printf '# 2026-07-01 foo\n- status: done\n' > "$ITEMS/2026-07-01-foo.md"
printf '# 2026-07-02 bar\n- status: validated\n' > "$ITEMS/2026-07-02-bar.md"
: > "$ARCH/2026-07-01-1200-foo.md"
RD_BATCH_ITEMS_DIR="$ITEMS" RD_BATCH_ARCHIVE_DIR="$ARCH" bash "$H" verify-done foo
expect_code "verify-done: done+archive → 0" 0 $?
RD_BATCH_ITEMS_DIR="$ITEMS" RD_BATCH_ARCHIVE_DIR="$ARCH" bash "$H" verify-done bar
expect_code "verify-done: status≠done → 1" 1 $?
rm "$ARCH/2026-07-01-1200-foo.md"
RD_BATCH_ITEMS_DIR="$ITEMS" RD_BATCH_ARCHIVE_DIR="$ARCH" bash "$H" verify-done foo
expect_code "verify-done: archive 없음 → 1" 1 $?

# --- resolve-slug ---
RD_BATCH_ITEMS_DIR="$ITEMS" bash "$H" resolve-slug foo >/dev/null
expect_code "resolve-slug: 정확히 1개 → 0" 0 $?
RD_BATCH_ITEMS_DIR="$ITEMS" bash "$H" resolve-slug nope 2>/dev/null
expect_code "resolve-slug: 미존재 → 1" 1 $?
printf '# 2026-07-03 foo\n- status: idea\n' > "$ITEMS/2026-07-03-foo.md"   # foo 중복 생성
RD_BATCH_ITEMS_DIR="$ITEMS" bash "$H" resolve-slug foo 2>/dev/null
expect_code "resolve-slug: 복수 매칭 → 1" 1 $?
rm "$ITEMS/2026-07-03-foo.md"

# --- slug charset 가드: 인자 위반 → 2, manifest 내용 위반 → 1 ---
RD_BATCH_ITEMS_DIR="$ITEMS" bash "$H" resolve-slug 'Foo_bar' 2>/dev/null
expect_code "resolve-slug: 비정규 slug(Foo_bar) → 2" 2 $?
RD_BATCH_ITEMS_DIR="$ITEMS" RD_BATCH_ARCHIVE_DIR="$ARCH" bash "$H" verify-done 'a b' 2>/dev/null
expect_code "verify-done: 비정규 slug(공백 포함) → 2" 2 $?
echo '{"finish_policy":"merge","status":"preparing","items":[{"slug":"A_b","order":1,"depends_on":[],"feasibility":"eligible","state":"pending"}]}' > "$TMP/badslugchar.json"
bash "$H" validate "$TMP/badslugchar.json" 2>/dev/null
expect_code "validate: slug charset 위반 → 1" 1 $?

# --- 손상 manifest 가드: next/skip-dependents/summary 는 exit 2 로 명확히 실패 ---
bash "$H" next "$TMP/bad.json" 2>/dev/null; expect_code "next: 손상 manifest → 2" 2 $?
bash "$H" skip-dependents "$TMP/bad.json" a 2>/dev/null; expect_code "skip-dependents: 손상 manifest → 2" 2 $?
bash "$H" summary "$TMP/bad.json" 2>/dev/null; expect_code "summary: 손상 manifest → 2" 2 $?

# --- exit 2 경로: 인자 누락·미존재 파일·미지 서브커맨드 ---
bash "$H" validate 2>/dev/null; expect_code "validate: 인자 누락 → 2" 2 $?
bash "$H" next "$TMP/no-such-file.json" 2>/dev/null; expect_code "next: 미존재 파일 → 2" 2 $?
bash "$H" frobnicate 2>/dev/null; expect_code "미지 서브커맨드 → 2" 2 $?
# --- validate 내용: 빈 slug·비문자열 depends_on → 1 ---
echo '{"finish_policy":"merge","status":"preparing","items":[{"slug":"","order":1,"depends_on":[],"feasibility":"eligible","state":"pending"}]}' > "$TMP/emptyslug.json"
bash "$H" validate "$TMP/emptyslug.json" 2>/dev/null; expect_code "validate: 빈 slug → 1" 1 $?
echo '{"finish_policy":"merge","status":"preparing","items":[{"slug":"a","order":1,"depends_on":[1],"feasibility":"eligible","state":"pending"}]}' > "$TMP/numdep.json"
bash "$H" validate "$TMP/numdep.json" 2>/dev/null; expect_code "validate: 비문자열 depends_on → 1" 1 $?

[ "$FAIL" -eq 0 ] && echo "test_batch_manifest: PASS" || echo "test_batch_manifest: FAIL"
exit "$FAIL"
