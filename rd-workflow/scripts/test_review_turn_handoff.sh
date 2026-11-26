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

run_with_mock_adapter() { # $1=session $2=mock body [추가 인자…] — rc 를 echo, 출력은 $TMP/last_{out,err}.txt
  local sess="$1" body="$2" fake_dir rc=0
  shift 2
  # MOCK_SCRIPT_DIR 를 주면 그 위치(임시 git 저장소의 rd-workflow/scripts)에 실행기를 둡니다 — project_root 가 그 저장소가 됩니다.
  if [[ -n "${MOCK_SCRIPT_DIR:-}" ]]; then
    fake_dir="$MOCK_SCRIPT_DIR"; mkdir -p "$fake_dir" || return 1
  else
    fake_dir="$(mktemp -d)" || { echo "run_with_mock_adapter: 임시 디렉터리 생성 실패" >&2; return 1; }
  fi
  cp "${SRC_DIR}/run_review_turn.sh" "${SRC_DIR}/review_common.sh" "${SRC_DIR}/model_select.sh" "$fake_dir/"
  for f in _state_common.sh _submodule_common.sh; do
    [[ -f "${SRC_DIR}/$f" ]] && cp "${SRC_DIR}/$f" "$fake_dir/"
  done
  mkdir -p "$fake_dir/hooks" && cp "${SRC_DIR}/hooks/_open_issues.awk" "$fake_dir/hooks/"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$fake_dir/adapter_codex.sh"
  chmod +x "$fake_dir/adapter_codex.sh"
  # MOCK_PRIORITY_TOOL=claude 이면 self-review 게이트까지 가도록 claude 어댑터도 둔다.
  cp "$fake_dir/adapter_codex.sh" "$fake_dir/adapter_claude.sh"
  printf '{"default_priority":["%s"],"tools":{"codex":{"bin":"bash","effort_default":"high"},"claude":{"bin":"bash"}},"_comment":"handoff test"}' "${MOCK_PRIORITY_TOOL:-codex}" > "$fake_dir/tools.json"
  REVIEW_TOOLS_CONFIG="$fake_dir/tools.json" bash "$fake_dir/run_review_turn.sh" "$sess" ${1+"$@"} \
    >"$TMP/last_out.txt" 2>"$TMP/last_err.txt" || rc=$?
  [[ -n "${MOCK_SCRIPT_DIR:-}" ]] || rm -rf "$fake_dir"
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
run_reject "$S"; reject H4 "$S"; has x "USER_ACTION.md" "H4 안내"; has x "--reopen" "H4 재개 안내"
has x "--decision" "H4 결정 재개 안내"; has x "--override" "H4 종결 안내"

# 재개 케이스: 001 Author → 002 Reviewer(이의 없음) → awaiting-user 로 수렴한 세션
mk_converged() { # $1=세션 — CHECKPOINT Open Issues 는 mk_session 기본값 "- 없음"
  mk_session "$1" awaiting-user User; author_turn "$1"; printf '# 002 Reviewer\n이의 없음\n' > "$1/turns/002_reviewer.md"
}
run_reopen_reject() { cp "$1/SESSION.md" "$1/SESSION.orig"; RC="$(run_with_mock_adapter "$1" "$OK_BODY" --reopen "$2")"; }

echo "=== R1 수렴 세션 --reopen + 새 Author 턴 ==="
S="$TMP/r1"; mk_converged "$S"; author_turn "$S" 003_author.md
# 사유의 역슬래시(`\n`)는 실제 개행이 아니므로 원문 그대로 기록돼야 한다.
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --reopen 'printf \n 출력 수정')"
eq "$rc" "0" "R1 rc 0"
eq "$(sec_line "$S/seen_session.md" Status)" "awaiting-reviewer" "R1 실행 시점 Status"
eq "$(sec_line "$S/seen_session.md" "Current Owner")" "Reviewer" "R1 실행 시점 Owner"
if sec_line "$S/SESSION.md" "Reopen History" | grep -qF '003_author.md 뒤 재개: printf \n 출력 수정'; then pass "R1 재개 사유 기록"; else fail "R1 재개 사유 기록 ($(sec_line "$S/SESSION.md" "Reopen History"))"; fi

echo "=== R2 미해결 이의가 남은 awaiting-user ==="
S="$TMP/r2"; mk_converged "$S"; author_turn "$S" 003_author.md
printf '# Review Checkpoint\n\n## Open Issues\n- F1 (턴 002) — 사람 결정 필요 | 해소 조건: 선택 | 상태: 대기\n' > "$S/CHECKPOINT.md"
run_reopen_reject "$S" "재확인"; reject R2 "$S"; has x "수렴한 세션이 아닙니다" "R2 안내"

echo "=== R3 새 Author 턴 없이 --reopen ==="
S="$TMP/r3"; mk_converged "$S"
run_reopen_reject "$S" "재확인"; reject R3 "$S"; has x "turns/003_author.md" "R3 안내 경로"

echo "=== R4 빈 사유 ==="
S="$TMP/r4"; mk_converged "$S"; author_turn "$S" 003_author.md
run_reopen_reject "$S" "  "; reject R4 "$S"; has x "사유가 필요합니다" "R4 안내"

# 결정 대기 세션: 001 Author → 002 Reviewer(이의 유지) → awaiting-user, CHECKPOINT 에 미해결 이의
mk_pending() { # $1=세션 [$2=Turn Limit 줄] [$3=Review Type] [$4=Branch Context 추가 줄]
  mk_session "$1" awaiting-user User "${2:-20 total turns in \`turns/*.md\`}" "${3:-spec-plan-review}" "${4:-}"; author_turn "$1"
  printf '# 002 Reviewer\nF1 유지\n' > "$1/turns/002_reviewer.md"
  printf '# Review Checkpoint\n\n## Open Issues\n- F1 (턴 002) — 사람 결정 필요 | 해소 조건: 선택 | 상태: 대기\n' > "$1/CHECKPOINT.md"
  printf '# User Action\n\n## Question For User\nF1 을 어떻게 할지\n' > "$1/USER_ACTION.md"
}
run_opt_reject() { local s="$1"; shift; cp "$s/SESSION.md" "$s/SESSION.orig"; RC="$(run_with_mock_adapter "$s" "$OK_BODY" "$@")"; }

echo "=== D1 미해결 이의 세션 --decision + 새 Author 턴 ==="
S="$TMP/d1"; mk_pending "$S"; author_turn "$S" 003_author.md
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --decision 'F1 은 값 복구 후 재확인')"
eq "$rc" "0" "D1 rc 0"
eq "$(sec_line "$S/seen_session.md" Status)" "awaiting-reviewer" "D1 실행 시점 Status"
eq "$(sec_line "$S/seen_session.md" "Current Owner")" "Reviewer" "D1 실행 시점 Owner"
if sec_line "$S/SESSION.md" "Reopen History" | grep -qF '003_author.md 뒤 사용자 결정으로 재개: F1 은 값 복구 후 재확인'; then pass "D1 SESSION 결정 기록"; else fail "D1 SESSION 결정 기록"; fi
if sec_line "$S/USER_ACTION.md" "User Decision" | grep -qF '결정: F1 은 값 복구 후 재확인'; then pass "D1 USER_ACTION 결정 기록"; else fail "D1 USER_ACTION 결정 기록"; fi
grep -qF 'F1 을 어떻게 할지' "$S/USER_ACTION.md" && pass "D1 USER_ACTION 기존 질문 보존" || fail "D1 USER_ACTION 기존 질문 보존"

echo "=== D2 수렴 세션 --decision ==="
S="$TMP/d2"; mk_converged "$S"; author_turn "$S" 003_author.md
run_opt_reject "$S" --decision "x"; reject D2 "$S"; has x "--reopen" "D2 재개 안내"

echo "=== D3 새 Author 턴 없이 --decision ==="
S="$TMP/d3"; mk_pending "$S"
run_opt_reject "$S" --decision "x"; reject D3 "$S"; has x "turns/003_author.md" "D3 안내 경로"
grep -qF '## User Decision' "$S/USER_ACTION.md" && fail "D3 USER_ACTION 불변" || pass "D3 USER_ACTION 불변"

echo "=== D4 Open Issues 판정 불가(빈 절) --decision ==="
S="$TMP/d4"; mk_pending "$S"; author_turn "$S" 003_author.md
printf '# Review Checkpoint\n\n## Open Issues\n\n## Suggested Next Owner\nUser\n' > "$S/CHECKPOINT.md"
run_opt_reject "$S" --decision "x"; reject D4 "$S"; has x "open-issues-empty" "D4 판정 사유"

echo "=== D5 self-review 차단 뒤 결정 보존 ==="
S="$TMP/d5"; mk_pending "$S"; author_turn "$S" 003_author.md
rc="$(MOCK_PRIORITY_TOOL=claude run_with_mock_adapter "$S" "$OK_BODY" --decision "F1 복구")"
eq "$rc" "3" "D5 self-review 차단 rc 3"
if sec_line "$S/USER_ACTION.md" "User Decision" | grep -qF '결정: F1 복구'; then pass "D5 차단 안내 뒤 결정 보존"; else fail "D5 차단 안내 뒤 결정 보존"; fi
# 안내대로 옵션 없이 재시도해 다시 차단돼도 결정이 남아야 한다.
rc="$(MOCK_PRIORITY_TOOL=claude run_with_mock_adapter "$S" "$OK_BODY")"
eq "$rc" "3" "D5 재시도 차단 rc 3"
if sec_line "$S/USER_ACTION.md" "User Decision" | grep -qF '결정: F1 복구'; then pass "D5 재시도 차단 뒤 결정 보존"; else fail "D5 재시도 차단 뒤 결정 보존"; fi

echo "=== D6 내용 없는 리스트 항목 --decision ==="
S="$TMP/d6"; mk_pending "$S"; author_turn "$S" 003_author.md
printf '# Review Checkpoint\n\n## Open Issues\n- \n' > "$S/CHECKPOINT.md"
run_opt_reject "$S" --decision "x"; reject D6 "$S"; has x "내용 없는 리스트 항목" "D6 판정 사유"

echo "=== D7 결정 표시가 빠진 세션 옵션 없는 재시도 ==="
# 전환은 됐는데 USER_ACTION 기록이 남지 않은 상태(첫 기록 실패 뒤)에서 옵션 없이 다시 실행하면 SESSION 기록으로 복구한다.
S="$TMP/d7"; mk_session "$S" awaiting-reviewer Reviewer; author_turn "$S"
printf '\n## Reopen History\n- 2026-11-20 10:00 001_author.md 뒤 사용자 결정으로 재개: F1 은 값 복구\n- 2026-11-20 10:00 001_author.md 뒤 턴 한도 연장: 2 → 6\n' >> "$S/SESSION.md"
printf '# User Action\n\n## Question For User\nF1\n' > "$S/USER_ACTION.md"
rc="$(run_with_mock_adapter "$S" "$OK_BODY")"
eq "$rc" "0" "D7 rc 0"
eq "$(sec_line "$S/USER_ACTION.md" "User Decision")" "- 2026-11-20 10:00 결정: F1 은 값 복구 (적용: 001_author.md 뒤 Reviewer 재확인)" "D7 결정 표시 복구"

echo "=== D8 결정 본문에 턴 한도 낱말 ==="
S="$TMP/d8"; mk_pending "$S"; author_turn "$S" 003_author.md
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --decision "F1 판단; 턴 한도 20 → 24")"
eq "$rc" "0" "D8 rc 0"
if sec_line "$S/USER_ACTION.md" "User Decision" | grep -qF '결정: F1 판단; 턴 한도 20 → 24 (적용: 003_author.md'; then pass "D8 결정 전문 표시"; else fail "D8 결정 전문 표시"; fi

echo "=== L2 잠금이 재snapshot 보다 먼저 (diff-review) ==="
S="$TMP/l2"; mk_session "$S" awaiting-author Author '20 total turns in `turns/*.md`' diff-review "- review-head-oid: 0123456789abcdef0123456789abcdef01234567"; author_turn "$S"; mkdir "$S/.state.lock"
run_reject "$S"; reject L2 "$S"; has x "상태를 바꾸는 중입니다" "L2 잠금 안내(재snapshot 전)"

echo "=== L1 상태 잠금이 잡혀 있는 세션 --decision ==="
S="$TMP/l1"; mk_pending "$S"; author_turn "$S" 003_author.md; mkdir "$S/.state.lock"
run_opt_reject "$S" --decision "x"; reject L1 "$S"; has x "상태를 바꾸는 중입니다" "L1 안내"
grep -qF '## User Decision' "$S/USER_ACTION.md" && fail "L1 USER_ACTION 불변" || pass "L1 USER_ACTION 불변"

echo "=== T1 턴 한도 도달 + --decision --extend-turns ==="
S="$TMP/t1"; mk_pending "$S" '2 total turns in `turns/*.md`'; author_turn "$S" 003_author.md
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --decision "더 이어 감" --extend-turns 4)"
eq "$rc" "0" "T1 rc 0"
eq "$(sec_line "$S/SESSION.md" "Turn Limit")" '6 total turns in `turns/*.md`' "T1 Turn Limit 갱신"
if awk '$0=="## Reopen History"{f=1;next} f&&/^## /{exit} f' "$S/SESSION.md" | grep -qE '003_author\.md 뒤 턴 한도 연장: 2 → 6$'; then pass "T1 연장 기록(별도 줄)"; else fail "T1 연장 기록(별도 줄)"; fi
if sec_line "$S/USER_ACTION.md" "User Decision" | grep -qF '결정: 더 이어 감 (적용: 003_author.md'; then pass "T1 결정 표시(연장 꼬리 제외)"; else fail "T1 결정 표시(연장 꼬리 제외)"; fi

echo "=== T2 턴 한도 도달 + --extend-turns 없음 ==="
S="$TMP/t2"; mk_pending "$S" '2 total turns in `turns/*.md`'; author_turn "$S" 003_author.md
run_opt_reject "$S" --decision "더 이어 감"; reject T2 "$S"; has x "--extend-turns" "T2 연장 안내"
grep -qF '## User Decision' "$S/USER_ACTION.md" && fail "T2 USER_ACTION 불변" || pass "T2 USER_ACTION 불변"

echo "=== T4 턴 한도 거부에 지적 추세 표 ==="
S="$TMP/t4"; mk_pending "$S" '4 total turns in `turns/*.md`'
printf '# 002 Reviewer\n\n## Findings\n- F1 첫 지적\n- F2 둘째 지적\n\n## Agreement\n- 없음\n' > "$S/turns/002_reviewer.md"
author_turn "$S" 003_author.md
printf '# 004 Reviewer\n\n## Findings\n- F2 둘째 지적 유지\n- F3 새 지적\n\n## Summary\n범위 밖: a.sh — 드문 형태 — 사유\n' > "$S/turns/004_reviewer.md"
author_turn "$S" 005_author.md
run_opt_reject "$S" --decision "더 이어 감"; reject T4 "$S"; has x "지적 추세" "T4 추세 표 머리"
grep -qE '^  002 +2 +2 +0 +F1 F2$' "$TMP/last_err.txt" && pass "T4 첫 턴 행" || fail "T4 첫 턴 행"
grep -qE '^  004 +2 +1 +1 +F3$' "$TMP/last_err.txt" && pass "T4 새 지적·범위 밖 행" || fail "T4 새 지적·범위 밖 행"

echo "=== T4b 옛 이름(codex)과 새 이름이 섞인 세션의 추세 순서 ==="
S="$TMP/t4b"; mk_pending "$S" '4 total turns in `turns/*.md`'; rm -f "$S/turns/002_reviewer.md"
printf '# 002 Reviewer\n\n## Findings\n- F1 같은 지적\n' > "$S/turns/002_codex.md"
author_turn "$S" 003_author.md
printf '# 004 Reviewer\n\n## Findings\n- F1 같은 지적\n' > "$S/turns/004_reviewer.md"
author_turn "$S" 005_author.md
run_opt_reject "$S" --decision "더 이어 감"; eq "$RC" "1" "T4b rc 1"
grep -qE '^  002 +1 +1 +0 +F1$' "$TMP/last_err.txt" && pass "T4b 옛 이름 턴이 첫 등장" || fail "T4b 옛 이름 턴이 첫 등장"
grep -qE '^  004 +1 +0 +0 +-$' "$TMP/last_err.txt" && pass "T4b 뒤 턴은 새 지적 0" || fail "T4b 뒤 턴은 새 지적 0"

echo "=== T5 Reviewer 턴이 한도에 닿으면 지적 추세 표 ==="
S="$TMP/t5"; mk_session "$S" awaiting-author Author '2 total turns in `turns/*.md`'; author_turn "$S"
LIMIT_BODY='
printf "# 002 Reviewer\n\n## Findings\n- F1 남은 지적\n" > "${EXPECTED_TURN_FILE}"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-user/" -e "s/^Reviewer$/User/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"'
rc="$(run_with_mock_adapter "$S" "$LIMIT_BODY")"
eq "$rc" "0" "T5 rc 0"
grep -qE '^  002 +1 +1 +0 +F1$' "$TMP/last_err.txt" && pass "T5 추세 표 행" || fail "T5 추세 표 행"

echo "=== T6 한도 전 Reviewer 턴에는 추세 표 없음 ==="
S="$TMP/t6"; mk_session "$S" awaiting-author Author; author_turn "$S"
rc="$(run_with_mock_adapter "$S" "$LIMIT_BODY")"
eq "$rc" "0" "T6 rc 0"; hasnt x "지적 추세" "T6 추세 표 없음"

echo "=== T3 Turn Limit 절 없는 세션(환경값 한도) --extend-turns ==="
S="$TMP/t3"; mk_pending "$S"; author_turn "$S" 003_author.md
awk '$0=="## Turn Limit"{skip=1;next} skip&&/^## /{skip=0} !skip' "$S/SESSION.md" > "$S/SESSION.tmp" && mv "$S/SESSION.tmp" "$S/SESSION.md"
export REVIEW_TURN_LIMIT=2
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --decision "더 이어 감" --extend-turns 4)"
unset REVIEW_TURN_LIMIT
eq "$rc" "0" "T3 rc 0"
eq "$(sec_line "$S/SESSION.md" "Turn Limit")" '6 total turns in `turns/*.md`' "T3 Turn Limit 절 생성"

echo "=== O1 미해결 이의 세션 --override ==="
S="$TMP/o1"; mk_pending "$S"; printf '\n## Closure Reason\n<!-- 허용 값: reviewer-no-objection | user-override -->\n-\n' >> "$S/SESSION.md"
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --override '주성 — "F1 은 수용하고 종결"')"
eq "$rc" "0" "O1 rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "closed" "O1 Status"
eq "$(awk '$0=="## Closure Reason"{s=1;next} s&&/^## /{exit} s&&NF&&!/^<!--/{print}' "$S/SESSION.md" | head -1)" "user-override" "O1 Closure Reason 값"
grep -qE "^근거: [0-9]{4}-[0-9]{2}-[0-9]{2} 주성 — \"F1 은 수용하고 종결\"$" "$S/SESSION.md" && pass "O1 근거 줄" || fail "O1 근거 줄"
grep -qF '<!-- 허용 값' "$S/SESSION.md" && pass "O1 주석 보존" || fail "O1 주석 보존"
if sec_line "$S/USER_ACTION.md" "User Decision" | grep -qF 'user-override'; then pass "O1 USER_ACTION 결정 기록"; else fail "O1 USER_ACTION 결정 기록"; fi
# seal 은 Open Issues 가 '- 없음' 으로 종결된 세션만 받는다. 남은 이의 원문은 종결 문단에 남아야 한다.
eq "$(awk -f "$SRC_DIR/hooks/_open_issues.awk" "$S/CHECKPOINT.md")" "ok" "O1 CHECKPOINT 종결 판정(seal 전제)"
grep -qF '원문: F1 (턴 002) — 사람 결정 필요' "$S/CHECKPOINT.md" && pass "O1 남은 이의 원문 보존" || fail "O1 남은 이의 원문 보존"

echo "=== O2 수렴 세션 --override ==="
S="$TMP/o2"; mk_converged "$S"
run_opt_reject "$S" --override "x — y"; reject O2 "$S"; has x "미해결 이의가 없습니다" "O2 안내"

echo "=== O3 --override 값 자리에 도움말 옵션 ==="
S="$TMP/o3"; mk_pending "$S"; cp "$S/USER_ACTION.md" "$S/USER_ACTION.orig"
run_opt_reject "$S" --override --help; reject O3 "$S"; has x "값 자리에 옵션" "O3 안내"
same "$S/USER_ACTION.md" "$S/USER_ACTION.orig" "O3 USER_ACTION 불변"

echo "=== O4 Open Issues 판정 불가(절 없음) --override ==="
S="$TMP/o4"; mk_pending "$S"; printf '# Review Checkpoint\n\n## Suggested Next Owner\nUser\n' > "$S/CHECKPOINT.md"
run_opt_reject "$S" --override "x — y"; reject O4 "$S"; has x "open-issues-missing" "O4 판정 사유"

echo "=== O5 CHECKPOINT 정리 뒤 멈춘 --override 이어 하기 ==="
# 이전 실행이 CHECKPOINT 를 정리하고 SESSION 교체 전에 멈춘 상태(Status 는 awaiting-user)
S="$TMP/o5"; mk_pending "$S"
# 이의 원문에 구분 문구(". 원문: ")가 들어 있어도 근거 줄은 따로 읽혀야 한다.
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n사용자 종결(2026-11-19, SESSION.md Closure Reason user-override): 남은 아래 이의는 사람이 덮고 종결했습니다.\n근거: 2026-11-19 주성 — 수용\n원문: F1 (턴 002) — 문구가 중복됩니다. 원문: 추가 설명\n' > "$S/CHECKPOINT.md"
# 첫 실행은 결정 표시를 먼저 쓰고 멈췄다 — 이어 하기는 표시를 다시 더하지 않아야 한다.
printf '\n## User Decision\n- 2026-11-19 09:00 결정: 남은 이의를 덮고 종결하기로 정함(user-override). 근거: 2026-11-19 주성 — 수용 — 적용 여부는 SESSION.md 의 Status·Closure Reason 에서 확인\n' >> "$S/USER_ACTION.md"
cp "$S/CHECKPOINT.md" "$TMP/o5_pending_checkpoint.md"
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --override "주성 — 수용")"
eq "$rc" "0" "O5 rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "closed" "O5 Status"
has x "종결 이어 하기" "O5 이어 하기 안내"
grep -qxF '근거: 2026-11-19 주성 — 수용' "$S/SESSION.md" && pass "O5 저장된 근거 사용" || fail "O5 저장된 근거 사용"
eq "$(grep -c 'user-override' "$S/USER_ACTION.md")" "1" "O5 결정 표시 한 번"

echo "=== O5c 앞선 실패가 남긴 다른 근거 표시가 있어도 이번 근거를 표시 ==="
# 같은 날 앞선 근거가 이번 근거를 앞부분으로 포함한다(부분 문자열 비교로는 같은 결정처럼 보임).
S="$TMP/o5c"; mk_pending "$S"
# 둘째 줄은 이번 결정 문구 전체를 담고 뒤에 사람의 메모가 붙은 줄이다(줄 끝 비교라야 이번 결정과 구별됨).
printf '\n## User Decision\n- %s 09:00 결정: 남은 이의를 덮고 종결하기로 정함(user-override). 근거: %s 주성 — 수용 및 재검토 — 적용 여부는 SESSION.md 의 Status·Closure Reason 에서 확인\n- %s 09:10 결정: 남은 이의를 덮고 종결하기로 정함(user-override). 근거: %s 주성 — 수용 — 적용 여부는 SESSION.md 의 Status·Closure Reason 에서 확인 (철회)\n' "$(date '+%Y-%m-%d')" "$(date '+%Y-%m-%d')" "$(date '+%Y-%m-%d')" "$(date '+%Y-%m-%d')" >> "$S/USER_ACTION.md"
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --override "주성 — 수용")"
eq "$rc" "0" "O5c rc 0"
grep -qE "결정: 남은 이의를 덮고 종결하기로 정함\(user-override\)\. 근거: [0-9-]+ 주성 — 수용 — 적용 여부는 SESSION.md 의 Status·Closure Reason 에서 확인$" "$S/USER_ACTION.md" && pass "O5c 이번 근거 표시" || fail "O5c 이번 근거 표시"

echo "=== O5d 백슬래시가 든 근거로 이어 하기 ==="
S="$TMP/o5d"; mk_pending "$S"
{ printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n사용자 종결(2026-11-19, SESSION.md Closure Reason user-override): 남은 아래 이의는 사람이 덮고 종결했습니다.\n'
  printf '%s\n' '근거: 2026-11-19 주성 — 수용\t경로' '원문: F1'; } > "$S/CHECKPOINT.md"
{ printf '\n## User Decision\n'
  printf '%s\n' '- 2026-11-19 09:00 결정: 남은 이의를 덮고 종결하기로 정함(user-override). 근거: 2026-11-19 주성 — 수용\t경로 — 적용 여부는 SESSION.md 의 Status·Closure Reason 에서 확인'; } >> "$S/USER_ACTION.md"
rc="$(run_with_mock_adapter "$S" "$OK_BODY" --override '주성 — 수용\t경로')"
eq "$rc" "0" "O5d rc 0"
eq "$(grep -c 'user-override' "$S/USER_ACTION.md")" "1" "O5d 결정 표시 한 번"

echo "=== R5 끝나지 않은 --override 상태에서 --reopen ==="
S="$TMP/r5"; mk_pending "$S"; author_turn "$S" 003_author.md; cp "$TMP/o5_pending_checkpoint.md" "$S/CHECKPOINT.md"
run_reopen_reject "$S" "재검토"; reject R5 "$S"; has x "끝나지 않은 --override" "R5 안내"; has x "같은 근거로 --override" "R5 종결 마치기 안내"

echo "=== O5b 이어 하기에 다른 근거 ==="
S="$TMP/o5b"; mk_pending "$S"
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n사용자 종결(2026-11-20, SESSION.md Closure Reason user-override): 남은 아래 이의는 사람이 덮고 종결했습니다.\n근거: 2026-11-20 주성 — 수용\n원문: F1\n' > "$S/CHECKPOINT.md"
cp "$S/USER_ACTION.md" "$S/USER_ACTION.orig"
run_opt_reject "$S" --override "주성 — 다른 근거"; reject O5b "$S"; has x "남긴 근거와 다릅니다" "O5b 안내"
same "$S/USER_ACTION.md" "$S/USER_ACTION.orig" "O5b USER_ACTION 불변"

echo "=== O6 실행 기록 없는 diff-review 세션 --override ==="
S="$TMP/o6"; mk_pending "$S" "" diff-review "- review-base-oid: 0123456789abcdef0123456789abcdef01234567
- review-head-oid: 0123456789abcdef0123456789abcdef01234567"; cp "$S/CHECKPOINT.md" "$S/CHECKPOINT.orig"
run_opt_reject "$S" --override "x — y"; reject O6 "$S"; has x "실행된 리뷰어 턴 기록이 없어" "O6 안내"
same "$S/CHECKPOINT.md" "$S/CHECKPOINT.orig" "O6 CHECKPOINT 불변"

echo "=== O7·O8 마지막 리뷰 뒤 보호 경로 변경 (임시 git 저장소) ==="
R="$TMP/repo"; G=(git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
mkdir -p "$R" && git -C "$R" init -q && echo a > "$R/app.txt" && "${G[@]}" add app.txt && "${G[@]}" commit -qm a
A="$(git -C "$R" rev-parse HEAD)"
echo b > "$R/app.txt" && "${G[@]}" commit -qam b
B="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$R/rd-workflow-workspace/.lifecycle" && printf 'fr-branch=null\n' > "$R/rd-workflow-workspace/.lifecycle/task-state"
mk_repo_pending() { # $1=세션 $2=review-head-oid
  mk_pending "$1" "" diff-review "- review-base-oid: $A
- review-head-oid: $2"
  printf '002\tcodex\treviewer\t%s\t%s\tunresolved\t1\n' "$2" "$(git hash-object "$1/turns/002_reviewer.md")" > "$1/reviewer_runs.tsv"
}
S="$R/rd-workflow-workspace/handoffs/review_pipeline/o7"; mk_repo_pending "$S" "$A"; cp "$S/CHECKPOINT.md" "$S/CHECKPOINT.orig"
MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; reject O7 "$S"; has x "보호 경로가 바뀌어" "O7 안내"
has x "--decision" "O7 다음 행동 안내"
has x "run_review_turn.sh 'rd-workflow-workspace/handoffs/review_pipeline/o7' --decision 'x — y (종결 결정 — 리뷰 뒤 변경 확인)'" "O7 확인 턴 명령(인용한 세션 경로·근거)"
has x "verify_record.sh -- <이 저장소의 검증 명령>" "O7 seal 전 검증 증거 단계"
has x "rd review seal 'rd-workflow-workspace/handoffs/review_pipeline/o7'" "O7 seal 명령(인용한 세션 경로)"
has x "--override 'x — y' 로 종결" "O7 확인 뒤 같은 근거 종결 명령"
hasnt x "--extend-turns" "O7 한도 안이면 연장 없음"
has x "turns/003_author.md" "O7 Author 턴 경로"
same "$S/CHECKPOINT.md" "$S/CHECKPOINT.orig" "O7 CHECKPOINT 불변"
S="$R/rd-workflow-workspace/handoffs/review_pipeline/o7b"; mk_repo_pending "$S" "$A"
sed -i.bak 's/^20 total turns/2 total turns/' "$S/SESSION.md" && rm -f "$S/SESSION.md.bak"
MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; reject O7b "$S"
has x "(종결 결정 — 리뷰 뒤 변경 확인)' --extend-turns 2" "O7b 한도 넘는 확인 턴에 연장 폭"
MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_opt_reject "$S" --override "검토자 — close!review it's \$HOME"
has x "--override '검토자 — close!review it'\\''s \$HOME' 로 종결" "O7b 느낌표·작은따옴표·\$ 근거를 작은따옴표 인자로"

echo "=== O7c 대기 중인 Author 턴이 있으면 그 턴을 쓰고 연장 폭을 실행기 기준으로 ==="
S="$R/rd-workflow-workspace/handoffs/review_pipeline/o7c"; mk_repo_pending "$S" "$A"; author_turn "$S" 003_author.md
sed -i.bak 's/^20 total turns/2 total turns/' "$S/SESSION.md" && rm -f "$S/SESSION.md.bak"
MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; reject O7c "$S"
has x "대기 중인 Author 턴 rd-workflow-workspace/handoffs/review_pipeline/o7c/turns/003_author.md" "O7c 대기 Author 턴 재사용"
has x "(종결 결정 — 리뷰 뒤 변경 확인)' --extend-turns 2" "O7c 연장 폭 2"
hasnt x "004_author.md" "O7c 새 Author 턴 안내 없음"

echo "=== O11 안내대로: 거부 → 확인 턴(이의 남아 awaiting-author) → 다시 물어 받은 근거로 --override 종결 ==="
S="$R/rd-workflow-workspace/handoffs/review_pipeline/o11"; mk_repo_pending "$S" "$A"
MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; eq "$RC" "1" "O11 첫 --override 거부"
author_turn "$S" 003_author.md
rc="$(MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --decision "x — y (종결 결정 — 리뷰 뒤 변경 확인)")"
eq "$rc" "0" "O11 확인 턴 rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "awaiting-author" "O11 확인 턴 뒤 awaiting-author"
# 확인 턴의 이의를 사람에게 다시 물어 받은 새 근거로 종결합니다(근거는 대조하지 않음).
rc="$(MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --override "주성 — 재확인 이의까지 포함해 종결")"
eq "$rc" "0" "O11 확인 턴 뒤 --override rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "closed" "O11 Status closed"
grep -qE "^근거: [0-9-]+ 주성 — 재확인 이의까지 포함해 종결$" "$S/SESSION.md" && pass "O11 새 근거 기록" || fail "O11 새 근거 기록"

echo "=== O11b 확인 턴 표식 없는 결정 뒤 awaiting-author 는 --override 거부 ==="
S="$R/rd-workflow-workspace/handoffs/review_pipeline/o11b"; mk_repo_pending "$S" "$A"; author_turn "$S" 003_author.md
rc="$(MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --decision "x — y 재검토")"
eq "$rc" "0" "O11b 결정 턴 rc 0"
rm -f "$S/seen_session.md"
MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; reject O11b "$S"
has x "확인 턴을 마친 세션에만" "O11b 거부 안내"
S="$R/rd-workflow-workspace/handoffs/review_pipeline/o8"; mk_repo_pending "$S" "$B"
rc="$(MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --override "x — y")"
eq "$rc" "0" "O8 리뷰한 HEAD 그대로면 종결 rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "closed" "O8 Status"

echo "=== O12 확인 턴 뒤 보호 경로가 다시 바뀌면 옵션 없는 인계로 다시 확인하고 같은 근거로 종결 (별도 저장소) ==="
R3="$TMP/repo3"; G3=(git -C "$R3" -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
mkdir -p "$R3" && git -C "$R3" init -q && echo a > "$R3/app.txt" && "${G3[@]}" add app.txt && "${G3[@]}" commit -qm a
A3="$(git -C "$R3" rev-parse HEAD)"; echo b > "$R3/app.txt" && "${G3[@]}" commit -qam b
mkdir -p "$R3/rd-workflow-workspace/.lifecycle" && printf 'fr-branch=null\n' > "$R3/rd-workflow-workspace/.lifecycle/task-state"
S="$R3/rd-workflow-workspace/handoffs/review_pipeline/o12"
mk_pending "$S" "" diff-review "- review-base-oid: $A3
- review-head-oid: $A3"
printf '002\tcodex\treviewer\t%s\t%s\tunresolved\t1\n' "$A3" "$(git hash-object "$S/turns/002_reviewer.md")" > "$S/reviewer_runs.tsv"
author_turn "$S" 003_author.md
rc="$(MOCK_SCRIPT_DIR="$R3/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --decision "x — y (종결 결정 — 리뷰 뒤 변경 확인)")"
eq "$rc" "0" "O12 첫 확인 턴 rc 0"
echo c > "$R3/app.txt" && "${G3[@]}" commit -qam c
MOCK_SCRIPT_DIR="$R3/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; eq "$RC" "1" "O12 재변경 뒤 --override 거부"
grep -qxF "    2. bash rd-workflow/scripts/run_review_turn.sh 'rd-workflow-workspace/handoffs/review_pipeline/o12'" "$TMP/last_err.txt" && pass "O12 옵션 없는 인계 명령" || fail "O12 옵션 없는 인계 명령"
hasnt x "--decision \"x — y (종결 결정" "O12 --decision 안내 없음"
author_turn "$S" 005_author.md; rm -f "$S/seen_session.md"
rc="$(MOCK_SCRIPT_DIR="$R3/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY")"
eq "$rc" "0" "O12 둘째 확인 턴 rc 0"
rc="$(MOCK_SCRIPT_DIR="$R3/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --override "x — y")"
eq "$rc" "0" "O12 같은 근거 --override rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "closed" "O12 Status closed"

echo "=== O13 확인 턴 뒤 일반 --reopen 이 새 이의를 남기면 이전 종결 결정으로 덮지 않음 ==="
CONV_BODY='
printf "# Turn Reviewer\n이의 없음\n" > "${EXPECTED_TURN_FILE}"
printf "# Review Checkpoint\n\n## Open Issues\n- 없음\n" > "${SESSION_PATH}/CHECKPOINT.md"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-user/" -e "s/^Reviewer$/User/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"'
OPEN_BODY='
printf "# Turn Reviewer\nF9 새 이의\n" > "${EXPECTED_TURN_FILE}"
printf "# Review Checkpoint\n\n## Open Issues\n- F9 (턴 006) — 새 이의 | 해소 조건: 수정 | 상태: 미해결\n" > "${SESSION_PATH}/CHECKPOINT.md"
sed -i.bak -e "s/^awaiting-reviewer$/awaiting-author/" -e "s/^Reviewer$/Author/" "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"'
S="$R3/rd-workflow-workspace/handoffs/review_pipeline/o13"
mk_pending "$S" "" diff-review "- review-base-oid: $A3
- review-head-oid: $A3"
printf '002\tcodex\treviewer\t%s\t%s\tunresolved\t1\n' "$A3" "$(git hash-object "$S/turns/002_reviewer.md")" > "$S/reviewer_runs.tsv"
author_turn "$S" 003_author.md
rc="$(MOCK_SCRIPT_DIR="$R3/rd-workflow/scripts" run_with_mock_adapter "$S" "$CONV_BODY" --decision "x — y (종결 결정 — 리뷰 뒤 변경 확인)")"
eq "$rc" "0" "O13 확인 턴(이의 없음) rc 0"
author_turn "$S" 005_author.md
rc="$(MOCK_SCRIPT_DIR="$R3/rd-workflow/scripts" run_with_mock_adapter "$S" "$OPEN_BODY" --reopen "새 커밋 재확인 (이전 기록 인용): 사용자 결정으로 재개: x — y (종결 결정 — 리뷰 뒤 변경 확인)")"
eq "$rc" "0" "O13 일반 재개 rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "awaiting-author" "O13 재개 뒤 awaiting-author"
rm -f "$S/seen_session.md"
MOCK_SCRIPT_DIR="$R3/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; reject O13 "$S"

echo "=== L3 재snapshot 뒤 전환이 거부되면 SESSION 되돌림 (임시 git 저장소) ==="
# 리뷰한 커밋(A)과 현재 HEAD(B)가 달라 재snapshot 이 SESSION 을 바꾸는 세션. Current Owner 절이 없어 전환 검증이 거부한다.
S="$R/rd-workflow-workspace/handoffs/review_pipeline/l3"; mk_repo_pending "$S" "$A"; author_turn "$S" 003_author.md
awk '$0=="## Current Owner"{skip=1;next} skip&&/^## /{skip=0} !skip' "$S/SESSION.md" > "$S/SESSION.tmp" && mv "$S/SESSION.tmp" "$S/SESSION.md"
MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_opt_reject "$S" --decision "x"; reject L3 "$S"
has x "전환 결과 검증 실패" "L3 거부 사유"
hasnt x "review head 재snapshot:" "L3 거부 실행에 재snapshot 완료 안내 없음"
[[ -z "$(find "$S" -name '.SESSION.work.*')" ]] && pass "L3 작업 사본 정리" || fail "L3 작업 사본 정리"

echo "=== L4 재snapshot 과 전환을 한 번에 (임시 git 저장소) ==="
S="$R/rd-workflow-workspace/handoffs/review_pipeline/l4"; mk_repo_pending "$S" "$A"; author_turn "$S" 003_author.md
rc="$(MOCK_SCRIPT_DIR="$R/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --decision "재확인")"
eq "$rc" "0" "L4 rc 0"
eq "$(sec_line "$S/seen_session.md" Status)" "awaiting-reviewer" "L4 실행 시점 Status"
grep -qxF -- "- review-head-oid: $B" "$S/seen_session.md" && pass "L4 실행 시점 head 갱신" || fail "L4 실행 시점 head 갱신"
has x "review head 재snapshot:" "L4 재snapshot 완료 안내"; has x "넘겼습니다" "L4 인계 완료 안내"

echo "=== O9 fr 세션: 리뷰 뒤 기본 브랜치의 무관한 파일만 병합 ==="
R2="$TMP/repo2"; G2=(git -C "$R2" -c user.name=t -c user.email=t@t -c commit.gpgsign=false)
mkdir -p "$R2" && git -C "$R2" init -q -b main && echo a > "$R2/app.txt" && "${G2[@]}" add app.txt && "${G2[@]}" commit -qm a
A2="$(git -C "$R2" rev-parse HEAD)"
"${G2[@]}" checkout -qb fr/x && echo b > "$R2/app.txt" && "${G2[@]}" commit -qam b
B2="$(git -C "$R2" rev-parse HEAD)"
"${G2[@]}" checkout -q main && echo o > "$R2/other.txt" && "${G2[@]}" add other.txt && "${G2[@]}" commit -qm other
"${G2[@]}" checkout -q fr/x && "${G2[@]}" merge -q --no-edit main
mkdir -p "$R2/rd-workflow-workspace/.lifecycle" && printf 'fr-branch=fr/x\n' > "$R2/rd-workflow-workspace/.lifecycle/task-state"
mkdir -p "$R2/rd-workflow/scripts" && cp -R "$SRC_DIR/." "$R2/rd-workflow/scripts/"
S="$R2/rd-workflow-workspace/handoffs/review_pipeline/o9"
mk_pending "$S" "" diff-review "- review-base-oid: $A2
- review-head-oid: $B2"
sed -i.bak 's/^- fr-branch: null$/- fr-branch: fr\/x/' "$S/SESSION.md" && rm -f "$S/SESSION.md.bak"
printf '002\tcodex\treviewer\t%s\t%s\tunresolved\t1\n' "$B2" "$(git hash-object "$S/turns/002_reviewer.md")" > "$S/reviewer_runs.tsv"
rc="$(MOCK_SCRIPT_DIR="$R2/rd-workflow/scripts" run_with_mock_adapter "$S" "$OK_BODY" --override "x — y")"
eq "$rc" "0" "O9 fr 한정 경로가 같으면 종결 rc 0"
eq "$(sec_line "$S/SESSION.md" Status)" "closed" "O9 Status"

echo "=== O10 SESSION 은 fr 인데 task-state 는 no-fr (seal 과 같은 판정) ==="
printf 'fr-branch=null\n' > "$R2/rd-workflow-workspace/.lifecycle/task-state"
S="$R2/rd-workflow-workspace/handoffs/review_pipeline/o10"
mk_pending "$S" "" diff-review "- review-base-oid: $A2
- review-head-oid: $B2"
sed -i.bak 's/^- fr-branch: null$/- fr-branch: fr\/x/' "$S/SESSION.md" && rm -f "$S/SESSION.md.bak"
printf '002\tcodex\treviewer\t%s\t%s\tunresolved\t1\n' "$B2" "$(git hash-object "$S/turns/002_reviewer.md")" > "$S/reviewer_runs.tsv"
MOCK_SCRIPT_DIR="$R2/rd-workflow/scripts" run_opt_reject "$S" --override "x — y"; reject O10 "$S"; has x "보호 경로가 바뀌어" "O10 전체 보호 트리로 판정"

echo "=== H5 closed ==="
S="$TMP/h5"; mk_session "$S" closed User; author_turn "$S"
run_reject "$S"; reject H5 "$S"; has x "prepare_review_pipeline.sh" "H5 안내"

# 없으면 새는 실수: closed 세션에 --reopen 을 붙이면 「--reopen 없이 다시 실행」 을 안내해,
# 따르면 다시 closed 로 거부되는 순환에 빠집니다. diff 리뷰는 마지막 리뷰 head 를 base 로 채운 새 세션 명령을 냅니다.
echo "=== H5b closed diff 세션 + --reopen ==="
S="$TMP/h5b"; mk_session "$S" closed User "" diff-review "- review-head-oid: 0123456789abcdef0123456789abcdef01234567"; author_turn "$S"
run_opt_reject "$S" --reopen "seal 직전 검증 실패"; reject H5b "$S"
hasnt x "--reopen 없이 다시 실행" "H5b 옵션 제거 안내 없음"
has x "prepare_review_pipeline.sh diff --base 0123456789abcdef0123456789abcdef01234567" "H5b 새 세션 명령(--base 마지막 리뷰 head)"
has x 'rd task set-status "구현 중"' "H5b 수정 커밋 순서 안내"

echo "=== H6 awaiting-author·Reviewer ==="
S="$TMP/h6"; mk_session "$S" awaiting-author Reviewer; author_turn "$S"
run_reject "$S"; reject H6 "$S"; has x "status=awaiting-author" "H6 status 값"; has x "owner=Reviewer" "H6 owner 값"

echo "=== H7 턴 한도 ==="
S="$TMP/h7"; mk_session "$S" awaiting-author Author '1 total turns in `turns/*.md`'; author_turn "$S"
run_reject "$S"; reject H7 "$S"; has x "turn limit" "H7 안내"
has x "--extend-turns" "H7 연장 안내"; hasnt x "--override" "H7 실행 불가 종결 안내 없음"

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
has x "어댑터 없음, 건너뜀: nosuchtool — 이 설치의 리뷰 도구는 claude·codex 입니다. review-tools.json 우선순위에서 빼려면 /review-config setup" "H10 건너뜀 안내에 리뷰 도구 목록과 고치는 법"

echo "=== H9 diff-review 재snapshot 거부 ==="
S="$TMP/h9"; mk_session "$S" awaiting-author Author '20 total turns in `turns/*.md`' diff-review "- review-head-oid: 0123456789abcdef0123456789abcdef01234567"; author_turn "$S"
run_reject "$S"; reject H9 "$S"; has x "한쪽만" "H9 안내"

echo
if [[ "$FAIL" == "0" ]]; then echo "ALL PASS"; else echo "FAILED"; fi
exit "$FAIL"
