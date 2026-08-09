#!/usr/bin/env bash
# test_review_metrics.sh — 리뷰 턴 계측 계약 검증 (review-speedup-2-effort-policy-tuning)
# ① 단위: append_turn_metric / compute_target_bytes ② 통합: mock adapter 로 ok/fail/timeout 3경로
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
eq()   { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대=[$2] 실제=[$1])"; fi; }
chk()  { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== 단위: append_turn_metric / compute_target_bytes ==="
(
  source "${script_dir}/run_review_turn.sh" 2>/dev/null
  set +e

  # compute_target_bytes: 줄 단위 분리 (Review Target 은 줄당 1개 — 공백 포함 경로 안전)
  printf 'aaaa' > "$TMP/a.md"          # 4 bytes
  printf 'bb'   > "$TMP/b.md"          # 2 bytes
  REVIEW_TARGET="$(printf '%s\n%s' "$TMP/a.md" "$TMP/b.md")"
  eq "$(compute_target_bytes)" "6" "target_bytes: spec+plan 2줄 합산"

  REVIEW_TARGET="git diff main...HEAD"
  eq "$(compute_target_bytes)" "-" "target_bytes: 파일 아님(diff 명령) → -"

  mkdir -p "$TMP/dir with space"
  printf 'ccc' > "$TMP/dir with space/spec.md"   # 3 bytes
  REVIEW_TARGET="$TMP/dir with space/spec.md"
  eq "$(compute_target_bytes)" "3" "target_bytes: 공백 포함 경로"

  REVIEW_TARGET="$(printf '%s\n%s' "$TMP/a.md" "$TMP/none.md")"
  eq "$(compute_target_bytes)" "4" "target_bytes: 실존 파일만 합산"

  # append_turn_metric: 헤더 + 레코드
  session_dir="$TMP/sess"; mkdir -p "$session_dir"
  append_turn_metric 2 spec-plan-review codex high 1000 6 100 160 ok
  eq "$(wc -l < "$session_dir/turn_metrics.tsv" | tr -d ' ')" "2" "첫 기록: 헤더 1 + 레코드 1"
  eq "$(head -1 "$session_dir/turn_metrics.tsv")" "$(printf '# turn\treview_type\ttool\teffort\tprompt_bytes\ttarget_bytes\tstart_epoch\tend_epoch\twall_seconds\tstatus')" "헤더 형식"
  eq "$(sed -n 2p "$session_dir/turn_metrics.tsv")" "$(printf '2\tspec-plan-review\tcodex\thigh\t1000\t6\t100\t160\t60\tok')" "레코드: wall=60 계산 포함 10필드"

  append_turn_metric 4 spec-plan-review codex "" 1000 - 200 230 timeout
  eq "$(wc -l < "$session_dir/turn_metrics.tsv" | tr -d ' ')" "3" "append-only: 헤더 재기록 없음"
  eq "$(sed -n 3p "$session_dir/turn_metrics.tsv" | cut -f4)" "none" "effort 빈 값 → none"
  eq "$(sed -n 3p "$session_dir/turn_metrics.tsv" | cut -f10)" "timeout" "status=timeout"

  # fail-open: 쓰기 불가 디렉토리에서도 return 0
  session_dir="$TMP/ro"; mkdir -p "$session_dir"; chmod 555 "$session_dir"
  append_turn_metric 2 spec-plan-review codex high 1 1 1 2 ok
  chk $? "fail-open: 쓰기 불가에도 return 0"
  chmod 755 "$session_dir"

  # 서브셸 내부 FAIL 을 부모로 전파 — 이 exit 이 없으면 assertion 실패가 false-green 이 된다
  exit "$FAIL"
) || fail "단위 파트 실패 (서브셸 rc 전파)"

echo "=== 통합: mock adapter 3경로 ==="
# 최소 세션 픽스처 (test_review_wait.sh 의 write_session 패턴 축약)
mk_full_session() { # $1=디렉토리
  mkdir -p "$1/turns"
  cat > "$1/SESSION.md" <<'EOF'
# Review Session

## Session ID
metrics-test

## Review Type
spec-plan-review

## Review Target
REQUEST.md

## Review Goal
계측 테스트

## Status
awaiting-reviewer

## Current Owner
Reviewer

## Turn Limit
20 total turns in `turns/*.md`

## Branch Context
- fr-branch: null
- worktree-path: null
- short-title: metrics-test
- lifecycle-stage: request-review
- remote-mode: local-only

## Review Scope
- execution-path: other
EOF
  cat > "$1/CHECKPOINT.md" <<'EOF'
# Review Checkpoint

## Open Issues
- 없음

## Suggested Next Owner
Reviewer
EOF
  : > "$1/USER_ACTION.md"
  printf '# Turn 001 — Author\n' > "$1/turns/001_author.md"
}

run_with_mock_adapter() { # $1=session $2=mock-adapter-body — rc 를 echo 하고 출력은 $TMP/last_{out,err}.txt 에 캡처
  local sess="$1" body="$2" fake_dir rc=0
  fake_dir="$(mktemp -d)"
  # run_review_turn.sh 는 script_dir 기준으로 adapter_<tool>.sh 를 찾으므로
  # 스크립트 사본 + mock adapter 를 한 디렉토리에 구성한다.
  cp "${script_dir}/run_review_turn.sh" "${script_dir}/review_common.sh" "$fake_dir/"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$fake_dir/adapter_codex.sh"
  chmod +x "$fake_dir/adapter_codex.sh"
  printf '{"default_priority":["codex"],"tools":{"codex":{}},"_comment":"metrics test"}' > "$fake_dir/tools.json"
  # MOCK_PATH_PREPEND: 시간 원천 실패 주입 등 명령 shim 디렉토리 (미설정이면 무영향)
  REVIEW_TOOLS_CONFIG="$fake_dir/tools.json" PATH="${MOCK_PATH_PREPEND:+$MOCK_PATH_PREPEND:}$PATH" \
    bash "$fake_dir/run_review_turn.sh" "$sess" \
    >"$TMP/last_out.txt" 2>"$TMP/last_err.txt" || rc=$?
  rm -rf "$fake_dir"
  printf '%s' "$rc"
}

# 경로 1: ok — mock 이 턴 파일 생성 + SESSION 을 완료 상태로 갱신 후 exit 0
S1="$TMP/it_ok"; mk_full_session "$S1"
OK_BODY='
tf="${SESSION_PATH}/turns/002_reviewer.md"
printf "# Turn 002 — Reviewer\n이의 없음\n" > "$tf"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-author/" -e "s/^Reviewer$/Author/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"
exit 0'
rc="$(run_with_mock_adapter "$S1" "$OK_BODY")"
eq "$rc" "0" "통합 ok: 턴 성공"
eq "$(sed -n 2p "$S1/turn_metrics.tsv" | cut -f10)" "ok" "통합 ok: status=ok 기록"
eq "$(sed -n 2p "$S1/turn_metrics.tsv" | cut -f2)" "spec-plan-review" "통합 ok: review_type 기록"
grep -q '^turn time: [0-9][0-9]*s$' "$TMP/last_out.txt"; chk $? "가시성 ok: stdout turn time"
grep -q 'turn time: [0-9][0-9]*s (status: ok)' "$TMP/last_err.txt"; chk $? "가시성 ok: stderr turn time (status: ok)"

# 경로 2: fail — mock exit 1
S2="$TMP/it_fail"; mk_full_session "$S2"
rc="$(run_with_mock_adapter "$S2" 'exit 1')"
eq "$rc" "1" "통합 fail: 부모 exit 1 유지"
eq "$(sed -n 2p "$S2/turn_metrics.tsv" | cut -f10)" "fail" "통합 fail: status=fail 기록"
grep -q 'turn time: [0-9][0-9]*s (status: fail)' "$TMP/last_err.txt"; chk $? "가시성 fail: stderr turn time"

# 경로 3: timeout — mock exit 124
S3="$TMP/it_timeout"; mk_full_session "$S3"
rc="$(run_with_mock_adapter "$S3" 'exit 124')"
eq "$rc" "1" "통합 timeout: 부모 exit 1 유지 (124 는 계측 전용)"
eq "$(sed -n 2p "$S3/turn_metrics.tsv" | cut -f10)" "timeout" "통합 timeout: status=timeout 기록"
grep -q 'turn time: [0-9][0-9]*s (status: timeout)' "$TMP/last_err.txt"; chk $? "가시성 timeout: stderr turn time"

# 경로 4: adapter 성공 + 출력 무효 — mock rc=0 인데 SESSION 미갱신 (턴 파일만 생성)
# → 부모는 완료 판정/validate 에서 비0 종료, metric 은 ok. 유효 표본 판정이 부모 rc 를
#   병용해야 하는 이유의 증거 케이스 (spec §4.1·§6.3).
S4="$TMP/it_invalid"; mk_full_session "$S4"
INVALID_BODY='
tf="${SESSION_PATH}/turns/002_reviewer.md"
printf "# Turn 002 — Reviewer\n" > "$tf"
exit 0'
rc="$(run_with_mock_adapter "$S4" "$INVALID_BODY")"
[ "$rc" -ne 0 ]; chk $? "통합 invalid-output: 부모 비0 종료"
eq "$(sed -n 2p "$S4/turn_metrics.tsv" | cut -f10)" "ok" "통합 invalid-output: metric 은 ok (어댑터 rc 의미)"
grep -q 'turn time: [0-9][0-9]*s (status: ok)' "$TMP/last_err.txt"; chk $? "가시성 invalid-output: validate 실패로 부모가 죽어도 stderr 표시는 남음 (spec §4.4)"

# 경로 5: fail-open E2E — turn_metrics.tsv 자리에 디렉토리를 만들어 쓰기를 확정 실패시켜도
# 유효 mock 턴은 부모 rc=0 (권한·실행 사용자와 무관한 확정적 실패 방식)
S5="$TMP/it_failopen"; mk_full_session "$S5"
mkdir "$S5/turn_metrics.tsv"
OK_BODY5='
tf="${SESSION_PATH}/turns/002_reviewer.md"
printf "# Turn 002 — Reviewer\n이의 없음\n" > "$tf"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-author/" -e "s/^Reviewer$/Author/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"
exit 0'
rc="$(run_with_mock_adapter "$S5" "$OK_BODY5")"
eq "$rc" "0" "fail-open E2E: 계측 쓰기 확정 실패에도 턴 성공"
grep -q '기록 실패' "$TMP/last_err.txt"; chk $? "fail-open E2E: 기록 실패가 stderr 경고로 표시됨 (무음 아님)"

# 경로 6: 시간 원천 실패 — date +%s 만 실패시키는 shim 을 PATH 에 주입해도
# 유효 mock 턴은 부모 rc=0 (fail-open 이 시간 수집 단계까지 확장 — diff review 턴 002 Finding 1)
S6="$TMP/it_datefail"; mk_full_session "$S6"
DATE_SHIM="$(mktemp -d)"
cat > "$DATE_SHIM/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s" ]; then exit 1; fi
exec /bin/date "$@"
EOF
chmod +x "$DATE_SHIM/date"
OK_BODY6='
tf="${SESSION_PATH}/turns/002_reviewer.md"
printf "# Turn 002 — Reviewer\n이의 없음\n" > "$tf"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-author/" -e "s/^Reviewer$/Author/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"
exit 0'
MOCK_PATH_PREPEND="$DATE_SHIM"
rc="$(MOCK_PATH_PREPEND="$DATE_SHIM" run_with_mock_adapter "$S6" "$OK_BODY6")"
eq "$rc" "0" "시간 원천 실패: 유효 턴은 부모 rc=0 (어댑터 실행·턴 진행 비차단)"
grep -q '시간 원천 실패' "$TMP/last_err.txt"; chk $? "시간 원천 실패: stderr 경고 표시"
grep -q '^turn time: unavailable$' "$TMP/last_out.txt"; chk $? "시간 원천 실패: stdout turn time unavailable"
[ ! -f "$S6/turn_metrics.tsv" ]; chk $? "시간 원천 실패: 잘못된 레코드를 남기지 않음"
rm -rf "$DATE_SHIM"; unset MOCK_PATH_PREPEND

# 비소비: turn_metrics.tsv 존재 세션에서 후속 턴 정상 (ok 세션 재사용 — Status 되돌림)
# 교대 계약(compute_next_turn — 같은 역할 연속 턴 거부) 준수를 위해 author 턴 003 을 끼운다.
printf '# Turn 003 — Author\n재검토 요청\n' > "$S1/turns/003_author.md"
sed -i.bak -e "s/^awaiting-author$/awaiting-reviewer/" -e "s/^Author$/Reviewer/" "$S1/SESSION.md" && rm -f "$S1/SESSION.md.bak"
OK_BODY2='
tf="${SESSION_PATH}/turns/004_reviewer.md"
printf "# Turn 004 — Reviewer\n이의 없음\n" > "$tf"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-author/" -e "s/^Reviewer$/Author/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"
exit 0'
rc="$(run_with_mock_adapter "$S1" "$OK_BODY2")"
eq "$rc" "0" "비소비: 계측 파일 존재 세션에서 다음 턴 정상"
eq "$(wc -l < "$S1/turn_metrics.tsv" | tr -d ' ')" "3" "append-only: 세션 2턴 = 헤더+레코드 2"

[ "$FAIL" -eq 0 ] && echo "OK" || { echo "FAILED"; exit 1; }
