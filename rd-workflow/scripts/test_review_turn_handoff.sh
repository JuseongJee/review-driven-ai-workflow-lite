#!/usr/bin/env bash
# test_review_turn_handoff.sh — run_review_turn.sh 의 Author→Reviewer 자동 상태 전환 검증
# (review-author-handoff change spec 3.1 판정 표 · 3.2 쓰기). mock adapter 로 통합 실행한다.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${RD_HANDOFF_TEST_SRC_DIR:-$script_dir}"

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
eq()   { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대=[$2] 실제=[$1])"; fi; }
has()  { if grep -qF -- "$2" "$TMP/last_err.txt"; then pass "$3"; else fail "$3 (stderr 에 [$2] 없음)"; fi; }
hasnt(){ if grep -qF -- "$2" "$TMP/last_err.txt"; then fail "$3 (stderr 에 [$2] 있음)"; else pass "$3"; fi; }
same() { if cmp -s "$1" "$2"; then pass "$3"; else fail "$3 (바이트 불일치)"; fi; }

TMP="$(mktemp -d)" || { echo "test_review_turn_handoff.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_review_turn_handoff.sh: 임시 디렉터리 검증 실패" >&2; exit 1; }
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# mk_session <dir> <status> <owner> [limit] [branch-context-extra]
# Review Goal 본문에 `awaiting-author`·`Author` 가 한 줄씩 있어 절 밖 치환을 잡는다.
mk_session() {
  local d="$1" st="$2" ow="$3" limit="${4:-20 total turns in \`turns/*.md\`}" rtype="${5:-spec-plan-review}" bc_extra="${6:-}"
  mkdir -p "$d/turns"
  {
    printf '# Review Session\n\n## Session ID\nhandoff-test\n\n## Review Type\n%s\n\n' "$rtype"
    printf '## Review Target\nREQUEST.md\n\n## Review Goal\n전환 테스트\nawaiting-author\nAuthor\n\n'
    printf '## Status\n%s\n\n## Current Owner\n%s\n\n## Turn Limit\n%s\n\n' "$st" "$ow" "$limit"
    printf '## Branch Context\n- fr-branch: null\n- worktree-path: null\n- short-title: handoff-test\n- lifecycle-stage: request-review\n- remote-mode: local-only\n'
    [[ -n "$bc_extra" ]] && printf '%s\n' "$bc_extra"
    printf '\n## Review Scope\n- execution-path: other\n'
  } > "$d/SESSION.md"
  printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nReviewer\n' > "$d/CHECKPOINT.md"
  : > "$d/USER_ACTION.md"
}

run_with_mock_adapter() { # $1=session $2=mock body — rc 를 echo, 출력은 $TMP/last_{out,err}.txt
  local sess="$1" body="$2" fake_dir rc=0
  fake_dir="$(mktemp -d)" || return 1
  cp "${SRC_DIR}/run_review_turn.sh" "${SRC_DIR}/review_common.sh" "$fake_dir/"
  for f in _state_common.sh _submodule_common.sh; do
    [[ -f "${SRC_DIR}/$f" ]] && cp "${SRC_DIR}/$f" "$fake_dir/"
  done
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$fake_dir/adapter_codex.sh"
  chmod +x "$fake_dir/adapter_codex.sh"
  printf '{"default_priority":["%s"],"tools":{"codex":{"effort_default":"high"}},"_comment":"handoff test"}' "${MOCK_PRIORITY_TOOL:-codex}" > "$fake_dir/tools.json"
  REVIEW_TOOLS_CONFIG="$fake_dir/tools.json" bash "$fake_dir/run_review_turn.sh" "$sess" \
    >"$TMP/last_out.txt" 2>"$TMP/last_err.txt" || rc=$?
  rm -rf "$fake_dir"
  printf '%s' "$rc"
}

# 실행 시점의 SESSION 을 seen_session.md 로 복사한 뒤 Reviewer 턴을 쓰고 SESSION 을 Author 로 되돌린다.
OK_BODY='
cp "${SESSION_PATH}/SESSION.md" "${SESSION_PATH}/seen_session.md"
printf "# Turn Reviewer\n이의 없음\n" > "${EXPECTED_TURN_FILE}"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-author/" -e "s/^Reviewer$/Author/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"'
FAIL_BODY='exit 1'

sec_line() { # $1=file $2=section — 절의 첫 비공백 줄
  awk -v t="## $2" '$0==t{s=1;next} s&&/^## /{exit} s&&NF{print;exit}' "$1"
}

author_turn() { printf '# 001 Author\n본문\n' > "$1/turns/${2:-001_author.md}"; }

echo "=== H1 awaiting-author·Author + 정상 Author 턴 ==="
S="$TMP/h1"; mk_session "$S" awaiting-author Author; author_turn "$S"
mk_session "$TMP/h1_expect" awaiting-reviewer Reviewer
rc="$(run_with_mock_adapter "$S" "$OK_BODY")"
eq "$rc" "0" "H1 rc 0"
eq "$(sec_line "$S/seen_session.md" Status)" "awaiting-reviewer" "H1 실행 시점 Status"
eq "$(sec_line "$S/seen_session.md" "Current Owner")" "Reviewer" "H1 실행 시점 Owner"
has x "Status 를 awaiting-reviewer, Current Owner 를 Reviewer 로 넘겼습니다" "H1 알림 문구"
same "$S/seen_session.md" "$TMP/h1_expect/SESSION.md" "H1 SESSION 전체 바이트(두 값 외 불변)"

echo "=== H1c 마지막 개행 없는 SESSION ==="
# 마지막 줄 개행이 없는 SESSION 도 두 값 밖의 바이트(끝 개행 없음 포함)를 보존해야 한다.
strip_last_nl() { local c; c="$(cat "$1")"; printf '%s' "$c" > "$1"; }
S="$TMP/h1c"; mk_session "$S" awaiting-author Author; strip_last_nl "$S/SESSION.md"; author_turn "$S" 001_author.md
mk_session "$TMP/h1c_expect" awaiting-reviewer Reviewer; strip_last_nl "$TMP/h1c_expect/SESSION.md"
rc="$(run_with_mock_adapter "$S" "$OK_BODY")"
eq "$rc" "0" "H1c rc 0"
same "$S/seen_session.md" "$TMP/h1c_expect/SESSION.md" "H1c SESSION 전체 바이트(끝 개행 없음 보존)"

echo "=== H1b legacy claude 이름 ==="
S="$TMP/h1b"; mk_session "$S" awaiting-author Claude; author_turn "$S" 001_claude.md
rc="$(run_with_mock_adapter "$S" "$OK_BODY")"
eq "$rc" "0" "H1b rc 0"
eq "$(sec_line "$S/seen_session.md" Status)" "awaiting-reviewer" "H1b Status"
eq "$(sec_line "$S/seen_session.md" "Current Owner")" "Reviewer" "H1b Owner"

# 거부 케이스 공통 검증: rc 1, SESSION 불변, mock 미실행
reject() { # $1=이름 $2=세션
  eq "$RC" "1" "$1 rc 1"
  same "$2/SESSION.md" "$2/SESSION.orig" "$1 SESSION 바이트 불변"
  [[ ! -e "$2/seen_session.md" ]] && pass "$1 mock 미실행" || fail "$1 mock 미실행"
}
run_reject() { cp "$1/SESSION.md" "$1/SESSION.orig"; RC="$(run_with_mock_adapter "$1" "$OK_BODY")"; }

echo "=== H2 최신 턴이 Reviewer ==="
S="$TMP/h2"; mk_session "$S" awaiting-author Author; author_turn "$S"; printf '# 002 Reviewer\nx\n' > "$S/turns/002_reviewer.md"
run_reject "$S"; reject H2 "$S"; has x "turns/003_author.md" "H2 안내 경로"

echo "=== H2b 턴 없음 ==="
S="$TMP/h2b"; mk_session "$S" awaiting-author Author
run_reject "$S"; eq "$RC" "1" "H2b rc 1"; same "$S/SESSION.md" "$S/SESSION.orig" "H2b SESSION 불변"; has x "turns/001_author.md" "H2b 안내 경로"

echo "=== H3 공백뿐인 Author 턴 ==="
S="$TMP/h3"; mk_session "$S" awaiting-author Author; printf '  \n\n' > "$S/turns/001_author.md"
run_reject "$S"; reject H3 "$S"; has x "turns/001_author.md" "H3 안내 경로"

echo "=== H3b 심볼릭 링크 Author 턴 ==="
S="$TMP/h3b"; mk_session "$S" awaiting-author Author; printf '# 001 Author\n본문\n' > "$TMP/h3b_target.md"; ln -s "$TMP/h3b_target.md" "$S/turns/001_author.md"
run_reject "$S"; reject H3b "$S"; has x "turns/001_author.md" "H3b 안내 경로"

echo "=== H4 awaiting-user ==="
S="$TMP/h4"; mk_session "$S" awaiting-user User; author_turn "$S"
run_reject "$S"; reject H4 "$S"; has x "USER_ACTION.md" "H4 안내"

echo "=== H5 closed ==="
S="$TMP/h5"; mk_session "$S" closed User; author_turn "$S"
run_reject "$S"; reject H5 "$S"; has x "prepare_review_pipeline.sh" "H5 안내"

echo "=== H6 awaiting-author·Reviewer ==="
S="$TMP/h6"; mk_session "$S" awaiting-author Reviewer; author_turn "$S"
run_reject "$S"; reject H6 "$S"; has x "status=awaiting-author" "H6 status 값"; has x "owner=Reviewer" "H6 owner 값"

echo "=== H7 턴 한도 ==="
S="$TMP/h7"; mk_session "$S" awaiting-author Author '1 total turns in `turns/*.md`'; author_turn "$S"
run_reject "$S"; reject H7 "$S"; has x "turn limit" "H7 안내"

echo "=== H8 어댑터 실패 뒤 상태 유지 ==="
S="$TMP/h8"; mk_session "$S" awaiting-author Author; author_turn "$S"
rc="$(run_with_mock_adapter "$S" "$FAIL_BODY")"
eq "$rc" "1" "H8 실패 실행 rc 1"
eq "$(sec_line "$S/SESSION.md" Status)" "awaiting-reviewer" "H8 실패 뒤 Status"
eq "$(sec_line "$S/SESSION.md" "Current Owner")" "Reviewer" "H8 실패 뒤 Owner"
rc="$(run_with_mock_adapter "$S" "$OK_BODY")"
eq "$rc" "0" "H8 재실행 rc 0"
hasnt x "넘겼습니다" "H8 재실행에는 전환 알림 없음"

echo "=== H10 도구 선택 실패(어댑터 없음) 뒤 상태 유지 ==="
S="$TMP/h10"; mk_session "$S" awaiting-author Author; author_turn "$S"
rc="$(MOCK_PRIORITY_TOOL=nosuchtool run_with_mock_adapter "$S" "$OK_BODY")"
[[ "$rc" != "0" ]] && pass "H10 rc≠0" || fail "H10 rc≠0 (rc=0)"
eq "$(sec_line "$S/SESSION.md" Status)" "awaiting-reviewer" "H10 도구 선택 실패 뒤 Status"
eq "$(sec_line "$S/SESSION.md" "Current Owner")" "Reviewer" "H10 도구 선택 실패 뒤 Owner"
has x "넘겼습니다" "H10 전환 알림"
has x "어댑터 없음" "H10 도구 선택 실패 경로 도달"

echo "=== H9 diff-review 재snapshot 거부 ==="
S="$TMP/h9"; mk_session "$S" awaiting-author Author '20 total turns in `turns/*.md`' diff-review "- review-head-oid: 0123456789abcdef0123456789abcdef01234567"; author_turn "$S"
run_reject "$S"; reject H9 "$S"; has x "한쪽만" "H9 안내"

echo
if [[ "$FAIL" == "0" ]]; then echo "ALL PASS"; else echo "FAILED"; fi
exit "$FAIL"
