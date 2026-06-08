#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"

PASS=0; FAIL=0
assert_eq() {
  local got="$1" want="$2" desc="$3"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "  PASS: $desc";
  else FAIL=$((FAIL+1)); echo "  FAIL: $desc — got=[$got] want=[$want]" >&2; fi
}
assert_err() {
  local input="$1" desc="$2"
  if normalize_slug "$input" >/dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "  FAIL: $desc — expected error but got success" >&2
  else PASS=$((PASS+1)); echo "  PASS: $desc"; fi
}

echo "== slug normalization =="
assert_eq "$(normalize_slug 'Foo Bar')" "foo-bar" "공백 + 대문자"
assert_eq "$(normalize_slug 'foo  bar')" "foo-bar" "다중 공백 압축"
assert_eq "$(normalize_slug 'foo_bar')" "foo-bar" "underscore 치환"
assert_eq "$(normalize_slug 'foo.bar')" "foo-bar" "dot 치환"
assert_eq "$(normalize_slug '--foo--')" "foo" "양끝 trim"
assert_eq "$(normalize_slug 'foo--bar')" "foo-bar" "연속 dash 압축"
assert_err "한글" "비-ASCII 거부"
assert_err "foo!bar" "특수문자 거부"
assert_err "" "빈 문자열 거부"
assert_err "   " "공백만 거부"
assert_err "$(printf 'x%.0s' {1..61})" "61자 거부"


# === Task 2: _lifecycle_common.sh fixtures ===
source "$SCRIPT_DIR/_lifecycle_common.sh"

echo "== git state helpers =="
assert_in_set() {
  local got="$1" set="$2" desc="$3"
  if [[ ",$set," == *",$got,"* ]]; then PASS=$((PASS+1)); echo "  PASS: $desc";
  else FAIL=$((FAIL+1)); echo "  FAIL: $desc — got=[$got]" >&2; fi
}

assert_in_set "$(detect_remote_mode)" "remote,local-only" "detect_remote_mode 반환값"
ensure_worktree_clean >/dev/null 2>&1 && rc=0 || rc=$?
assert_in_set "$rc" "0,1" "ensure_worktree_clean exit code"

echo "== metadata I/O =="
TMPDIR_TEST="$(mktemp -d)"
trap "rm -rf '$TMPDIR_TEST'" EXIT
LIFECYCLE_METADATA_PATH="$TMPDIR_TEST/active-fr"
if metadata_exists; then FAIL=$((FAIL+1)); echo "  FAIL: empty metadata 인데 exists 반환" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: metadata 부재"; fi
metadata_write "fr/foo" "foo" "/path"
if metadata_exists; then PASS=$((PASS+1)); echo "  PASS: write 후 exists"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: metadata write 실패" >&2; fi
assert_eq "$(metadata_read_field fr-branch)" "fr/foo" "metadata_read fr-branch"
assert_eq "$(metadata_read_field short-title)" "foo" "metadata_read short-title"
metadata_clear
if metadata_exists; then FAIL=$((FAIL+1)); echo "  FAIL: clear 후에도 exists" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: metadata clear"; fi

echo "== Task 2 누적: PASS=$PASS FAIL=$FAIL =="

echo "== review-gate 헬퍼 (safeguard-review-completion-checks) =="
LITE_HOOKS_DIR="$SCRIPT_DIR/../hooks"
GUARD_ROOT="$(mktemp -d)"
mkdir -p "$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline"
mkdir -p "$GUARD_ROOT/rd-workflow-workspace/.lifecycle"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"

# mk_session <dirname> <status> <open_issues_line> <short_title>
mk_session() {
  local d="$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline/$1"
  mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}

project_root="$GUARD_ROOT"
source "$LITE_HOOKS_DIR/_guard_common.sh"

assert_eq "$(get_current_short_title)" "mytask" "get_current_short_title — CURRENT_TASK"

# fr-scope: mytask 세션만 반환, 다른 fr 세션 제외
mk_session "20260101_000000_final-diff-review" "closed" "- 없음" "otherfr"
mk_session "20260102_000000_final-diff-review" "closed" "- 없음" "mytask"
assert_eq "$(basename "$(get_latest_diff_review_dir)")" "20260102_000000_final-diff-review" "fr-scope — mytask 세션만"

RP="$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline"
# (a) closed + 없음 → 종결(0)
mk_session "20260103_000000_final-diff-review" "closed" "- 없음" "mytask"
is_review_session_resolved "$RP/20260103_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + 없음"
# (b) awaiting-user + 없음 → 종결(0)  ※ 운영상 정상 종료 패턴(75%)
mk_session "20260104_000000_final-diff-review" "awaiting-user" "- 없음" "mytask"
is_review_session_resolved "$RP/20260104_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — awaiting-user + 없음 (정상 종료)"
# (c) awaiting-reviewer (루프 진행 중) → 미종결(1)
mk_session "20260105_000000_final-diff-review" "awaiting-reviewer" "- 없음" "mytask"
is_review_session_resolved "$RP/20260105_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — awaiting-reviewer (루프 진행 중)"
# (d) awaiting-user + 실제 이슈 → 미종결(1)
mk_session "20260106_000000_final-diff-review" "awaiting-user" "- 미해결 쟁점" "mytask"
is_review_session_resolved "$RP/20260106_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — awaiting-user + 실제 이슈"
# (e) closed (후행 공백) → trim 후 종결(0)
mk_session "20260107_000000_final-diff-review" "closed " "- 없음" "mytask"
is_review_session_resolved "$RP/20260107_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — 'closed ' trim"
# (f) malformed: CHECKPOINT.md 없음 → fail-closed(1)
mkdir -p "$RP/20260108_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: mytask\n' > "$RP/20260108_000000_final-diff-review/SESSION.md"
is_review_session_resolved "$RP/20260108_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — CHECKPOINT.md 부재"
# (g) malformed: Open Issues 섹션 없음 → fail-closed(1)
mkdir -p "$RP/20260109_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: mytask\n' > "$RP/20260109_000000_final-diff-review/SESSION.md"
printf '# Review Checkpoint\n\n## Current Summary\n-\n' > "$RP/20260109_000000_final-diff-review/CHECKPOINT.md"
is_review_session_resolved "$RP/20260109_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — Open Issues 섹션 부재"

# fr 세션 부재 시 빈 값 (다른 fr만 존재)
printf '# Current Task\n\n## Short Title\nlonelytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
assert_eq "$(get_latest_diff_review_dir)" "" "fr-scope — 현재 fr 세션 없으면 빈 값"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"

# malformed 세션은 short-title 미상 → fr-scope 후보 제외 (legacy/unscoped 통과, 3d 오발화 방지)
mkdir -p "$RP/20260110_000000_final-diff-review"
mkdir -p "$RP/20260111_000000_final-diff-review"
printf '## Status\nclosed\n' > "$RP/20260111_000000_final-diff-review/SESSION.md"
assert_eq "$(basename "$(get_latest_diff_review_dir)")" "20260109_000000_final-diff-review" "malformed 제외 — short-title 매칭 세션만 반환"
printf '# Current Task\n\n## Short Title\nzzz\n' > "$GUARD_ROOT/CURRENT_TASK.md"
assert_eq "$(get_latest_diff_review_dir)" "" "malformed-only → 빈 값 (unscoped 통과, 오발화 방지)"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"

# archive_review_precheck (3c)
PRECHECK_AUDIT="$GUARD_ROOT/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
rm -f "$PRECHECK_AUDIT"
printf '# Current Task\n\n## Short Title\nlonelytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
archive_review_precheck "0" "" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — 미종결 + force-skip 아님 → 차단"
archive_review_precheck "1" "" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — force-skip + 사유 누락 → 차단"
archive_review_precheck "1" "긴급 핫픽스" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — force-skip + 사유 → 통과"
assert_eq "$(awk -F' \\| ' 'END{print $2}' "$PRECHECK_AUDIT")" "lonelytask" "precheck — audit slug 기록"
assert_eq "$(awk -F' \\| ' 'END{print $3}' "$PRECHECK_AUDIT")" "긴급 핫픽스" "precheck — audit 사유 기록"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
mk_session "20260120_000000_final-diff-review" "closed" "- 없음" "mytask"   # 최신 종결 mytask 세션
archive_review_precheck "0" "" "mytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — 종결 세션 존재 → 통과"

# === archive precheck fr-branch tip 가시성 (archive-precheck-premerge-session-visibility) ===
echo "== archive precheck fr-branch tip 가시성 =="
FT_REPO="$(mktemp -d)"
git -C "$FT_REPO" init -q -b main
git -C "$FT_REPO" config user.email t@t && git -C "$FT_REPO" config user.name t
mkdir -p "$FT_REPO/rd-workflow-workspace/handoffs/review_pipeline" "$FT_REPO/rd-workflow-workspace/.lifecycle"
# 실제 archive 시점 재현: main 의 CURRENT_TASK ## Short Title 은 baseline(-),
# short-title 은 .lifecycle/active-fr metadata fallback 으로 해소된다(get_current_short_title).
printf '# Current Task\n\n## Short Title\n-\n' > "$FT_REPO/CURRENT_TASK.md"
printf 'fr-branch=fr/fttask\nshort-title=fttask\nworktree-path=null\nstatus=active\n' > "$FT_REPO/rd-workflow-workspace/.lifecycle/active-fr"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m seed
# fr branch 에 종결 diff-review 세션 commit
git -C "$FT_REPO" branch fr/fttask
git -C "$FT_REPO" switch -q fr/fttask
FTS="$FT_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260301_000000_final-diff-review"
mkdir -p "$FTS"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/fttask\n- short-title: fttask\n' > "$FTS/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$FTS/CHECKPOINT.md"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "diff-review session on fr"
git -C "$FT_REPO" switch -q main
FT_AUDIT="$FT_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
# sanity 1: short-title 은 metadata fallback 으로 해소 (CURRENT_TASK Short Title=-)
assert_eq "$( ( project_root="$FT_REPO"; get_current_short_title ) )" "fttask" "fr-tip — metadata fallback 으로 short-title 해소(Short Title=-)"
# sanity 2: 세션은 fr branch tip 에만 있고 main 워킹트리엔 없음
assert_eq "$( ( project_root="$FT_REPO"; get_latest_diff_review_dir ) )" "" "fr-tip — main 워킹트리에 세션 없음(sanity)"
# Case A (핵심 회귀): main Short Title=- + metadata fallback + fr_ref 지정 → fr tip 종결 세션 인식 → 통과(0)
( project_root="$FT_REPO"; archive_review_precheck "0" "" "fttask" "$FT_AUDIT" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "fr-tip — 종결 세션을 fr branch tip 에서 검증 → 통과 (metadata fallback 결합)"
# Case B (안전 회귀): fr tip 세션을 미종결로 변경 → 차단(1)
git -C "$FT_REPO" switch -q fr/fttask
printf '## Status\nawaiting-reviewer\n\n## Branch Context\n- fr-branch: fr/fttask\n- short-title: fttask\n' > "$FTS/SESSION.md"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "session unterminated"
git -C "$FT_REPO" switch -q main
( project_root="$FT_REPO"; archive_review_precheck "0" "" "fttask" "$FT_AUDIT" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "fr-tip — 미종결(awaiting-reviewer) 세션 → 차단 (안전 속성 보존)"
# Case C (audit 정규화): 미종결 fr 세션(위 Case B 상태) + force-skip + 사유 → 통과(0)
#   + audit 의 세션참조 필드가 temp 절대경로가 아닌 repo-상대 경로여야 한다.
FT_AUDIT2="$FT_REPO/rd-workflow-workspace/.lifecycle/audit2.log"
( project_root="$FT_REPO"; archive_review_precheck "1" "긴급 사유" "fttask" "$FT_AUDIT2" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "fr-tip — force-skip + 사유 → 통과"
assert_eq "$(awk -F' \\| ' 'END{print $4}' "$FT_AUDIT2")" "rd-workflow-workspace/handoffs/review_pipeline/20260301_000000_final-diff-review" "fr-tip — audit 세션참조 repo-상대 경로(temp 절대경로 금지)"
rm -rf "$FT_REPO"

# === Case D~G (archive-precheck-fr-ref-short-title-fallback): fr-branch identity 매칭 ===
# active metadata 없이 archive.sh --fr-branch 호출 시, fr tip SESSION.md 의 Branch Context
# fr-branch == fr_ref 로 후보를 고정해 종결 세션을 인식한다(main 워킹트리 의존 제거).
echo "== archive precheck fr_ref — fr-branch identity 매칭 =="
FT2="$(mktemp -d)"
git -C "$FT2" init -q -b main
git -C "$FT2" config user.email t@t && git -C "$FT2" config user.name t
mkdir -p "$FT2/rd-workflow-workspace/handoffs/review_pipeline" "$FT2/rd-workflow-workspace/.lifecycle"
# main: baseline Short Title=- + active-fr metadata 부재 → get_current_short_title "-" 반환(fr-scope 미해소)
printf '# Current Task\n\n## Short Title\n-\n' > "$FT2/CURRENT_TASK.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m seed
FT2_AUDIT="$FT2/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
assert_eq "$( ( project_root="$FT2"; get_current_short_title ) )" "-" "metadata 부재 — short-title 빈 값(회귀 전제)"

# Case D (AC1 — metadata 부재 핵심 회귀): fr/d1 tip 종결 세션(fr-branch=fr/d1) → 통과(0)
git -C "$FT2" branch fr/d1
git -C "$FT2" switch -q fr/d1
D1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260401_000000_final-diff-review"
mkdir -p "$D1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/d1\n- short-title: d1\n' > "$D1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$D1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "diff-review on fr/d1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "d1" "$FT2_AUDIT" "fr/d1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "AC1 — metadata 부재 + fr tip 종결 세션 → 통과 (fr-branch identity)"

# Case E (AC2 — suffix slug): fr/e1-2 tip, 세션 fr-branch=fr/e1-2, slug 인자=e1-2 → 통과(0)
git -C "$FT2" branch fr/e1-2
git -C "$FT2" switch -q fr/e1-2
E1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260402_000000_final-diff-review"
mkdir -p "$E1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/e1-2\n- short-title: e1\n' > "$E1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$E1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "diff-review on fr/e1-2"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "e1-2" "$FT2_AUDIT" "fr/e1-2" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "AC2 — suffix branch fr/e1-2 (fr-branch identity) → 통과 (slug≠short-title)"

# Case F (fail-closed — legacy): fr/f1 tip 세션에 Branch Context 부재 → 매칭 실패 → 차단(1)
git -C "$FT2" branch fr/f1
git -C "$FT2" switch -q fr/f1
F1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260403_000000_final-diff-review"
mkdir -p "$F1S"
printf '## Status\nclosed\n' > "$F1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$F1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "legacy diff-review on fr/f1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "f1" "$FT2_AUDIT" "fr/f1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — fr tip 세션 Branch Context 부재 → 차단"

# Case G (AC8 — stale/unrelated false-positive 차단): fr/g1 tip 최신 세션이 fr-branch=fr/other(종결)
#   이고 fr/g1 매칭 세션 없음 → 차단(1). short-title 역산 설계였다면 통과했을 false-positive 를 차단.
git -C "$FT2" branch fr/g1
git -C "$FT2" switch -q fr/g1
G1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260404_000000_final-diff-review"
mkdir -p "$G1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/other\n- short-title: other\n' > "$G1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$G1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "unrelated closed session on fr/g1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "g1" "$FT2_AUDIT" "fr/g1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "AC8 — stale/unrelated(fr/other) closed 세션만 최신 → 차단 (false-positive 방지)"
rm -rf "$FT2"

# commit_has_archive_signal (review-gate-iteration-commit)
echo "== commit_has_archive_signal =="
SIG_REPO="$(mktemp -d)"
git -C "$SIG_REPO" init -q
git -C "$SIG_REPO" config user.email t@t && git -C "$SIG_REPO" config user.name t
mkdir -p "$SIG_REPO/rd-workflow-workspace/backlog/request-archive"
printf '# Current Task\n\n## Status\n구현 중\n\n## Short Title\nsigtask\n' > "$SIG_REPO/CURRENT_TASK.md"
ARCH="rd-workflow-workspace/backlog/request-archive/2026-05-24-0000-sigtask.md"
# 신호 없음: 비-baseline + staged archive 없음 → 1(허용)
( project_root="$SIG_REPO"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — 신호 없음 → 1(허용)"
# AS1 경계: untracked stale archive 파일(add 안 함) → 1(허용, false-positive 방지)
printf 'x\n' > "$SIG_REPO/$ARCH"
( project_root="$SIG_REPO"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — AS1 untracked stale archive → 1(허용)"
# AS1: staged 추가 → 0(차단)
git -C "$SIG_REPO" add "$ARCH"
( project_root="$SIG_REPO"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "0" "archive_signal — AS1 staged request-archive 추가 → 0(차단)"
# AS1 경계: 기존 archive 파일 삭제(staged D) → 1(허용, 추가 아님)
git -C "$SIG_REPO" commit -q -m seed
git -C "$SIG_REPO" rm -q "$ARCH"
( project_root="$SIG_REPO"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — request-archive 삭제(staged D) → 1(허용)"
# AS2: CURRENT_TASK baseline → 0(차단)  (staged archive 추가 없이도)
printf '# Current Task\n\n## Status\n대기 중\n\n## Short Title\n-\n' > "$SIG_REPO/CURRENT_TASK.md"
( project_root="$SIG_REPO"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "0" "archive_signal — AS2 CURRENT_TASK baseline → 0(차단)"
rm -rf "$SIG_REPO"

echo "== review_gate hook exit code (iteration-commit 허용) =="
HOOK_REPO="$(mktemp -d)"
mkdir -p "$HOOK_REPO/rd-workflow/scripts/hooks"
mkdir -p "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline"
mkdir -p "$HOOK_REPO/rd-workflow-workspace/backlog/request-archive"
mkdir -p "$HOOK_REPO/rd-workflow-workspace/.lifecycle"
cp "$LITE_HOOKS_DIR/_guard_common.sh" "$HOOK_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/pre_commit_review_gate.sh" "$HOOK_REPO/rd-workflow/scripts/hooks/"
git -C "$HOOK_REPO" init -q
git -C "$HOOK_REPO" config user.email t@t && git -C "$HOOK_REPO" config user.name t
printf '# Current Task\n\n## Status\ndiff review 대기\n\n## Short Title\nhooktask\n' > "$HOOK_REPO/CURRENT_TASK.md"
hook_mk_session() {
  local d="$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/$1"
  mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}
run_review_gate() {
  printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
    | bash "$HOOK_REPO/rd-workflow/scripts/hooks/pre_commit_review_gate.sh" >/dev/null 2>&1; echo $?
}
HARCH="rd-workflow-workspace/backlog/request-archive/2026-05-24-0000-hooktask.md"
# 세션 없음 → 통과
assert_eq "$(run_review_gate)" "0" "review_gate — 세션 없음 → 통과 (exit 0)"
# 종결(awaiting-user+없음) → 통과
hook_mk_session "20260201_000000_final-diff-review" "awaiting-user" "- 없음" "hooktask"
assert_eq "$(run_review_gate)" "0" "review_gate — awaiting-user+없음(종결) → 통과"
# A1: 미종결 + iteration(staged archive 없음) → 허용 (신 동작)
hook_mk_session "20260202_000000_final-diff-review" "awaiting-reviewer" "- 없음" "hooktask"
assert_eq "$(run_review_gate)" "0" "review_gate — A1 미종결 + iteration commit → 허용 (exit 0)"
# A1-edge: 미종결 + untracked stale archive(add 안 함) → 허용 (false-positive 방지)
printf 'x\n' > "$HOOK_REPO/$HARCH"
assert_eq "$(run_review_gate)" "0" "review_gate — A1 미종결 + untracked stale archive → 허용"
# B1-AS1: 미종결 + staged request-archive 추가 → 차단
git -C "$HOOK_REPO" add "$HARCH"
assert_eq "$(run_review_gate)" "2" "review_gate — B1(AS1) 미종결 + staged archive 추가 → 차단 (exit 2)"
git -C "$HOOK_REPO" reset -q; rm -f "$HOOK_REPO/$HARCH"
# B1-AS2: 미종결 + CURRENT_TASK baseline (metadata fallback 로 세션 매칭) → 차단
printf 'short-title=hooktask\n' > "$HOOK_REPO/rd-workflow-workspace/.lifecycle/active-fr"
printf '# Current Task\n\n## Status\n대기 중\n\n## Short Title\n-\n' > "$HOOK_REPO/CURRENT_TASK.md"
assert_eq "$(run_review_gate)" "2" "review_gate — B1(AS2) 미종결 + CURRENT_TASK baseline → 차단 (exit 2)"
printf '# Current Task\n\n## Status\ndiff review 대기\n\n## Short Title\nhooktask\n' > "$HOOK_REPO/CURRENT_TASK.md"
rm -f "$HOOK_REPO/rd-workflow-workspace/.lifecycle/active-fr"
# autopilot 활성 + 미종결 + iteration → 허용 (3a 우회 제거 후에도 iteration 은 신호 아님)
touch "$HOOK_REPO/.autopilot_active"
assert_eq "$(run_review_gate)" "0" "review_gate — autopilot + 미종결 + iteration → 허용"
rm -f "$HOOK_REPO/.autopilot_active"
# malformed(Open Issues 섹션 부재) = 미종결 + iteration → 허용 (archive 신호일 때만 fail-closed)
mkdir -p "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260203_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: hooktask\n' > "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260203_000000_final-diff-review/SESSION.md"
printf '# Review Checkpoint\n\n## Current Summary\n-\n' > "$HOOK_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260203_000000_final-diff-review/CHECKPOINT.md"
assert_eq "$(run_review_gate)" "0" "review_gate — malformed + iteration → 허용"
# malformed + staged archive 추가 → 차단 (archive 경로 fail-closed 유지)
printf 'x\n' > "$HOOK_REPO/$HARCH"
git -C "$HOOK_REPO" add "$HARCH"
assert_eq "$(run_review_gate)" "2" "review_gate — malformed + staged archive → 차단 (fail-closed)"
git -C "$HOOK_REPO" reset -q
rm -rf "$HOOK_REPO"

echo "== archive_gate hook exit code =="
AG_REPO="$(mktemp -d)"
mkdir -p "$AG_REPO/rd-workflow/scripts/hooks" "$AG_REPO/rd-workflow-workspace/handoffs/review_pipeline" "$AG_REPO/rd-workflow-workspace/backlog/items"
cp "$LITE_HOOKS_DIR/_guard_common.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/pre_commit_archive_gate.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
printf '# Current Task\n\n## Short Title\nagtask\n' > "$AG_REPO/CURRENT_TASK.md"
printf '# Change Request\n\n## Source FR\n2026-05-15-agtask\n' > "$AG_REPO/REQUEST.md"
printf '# agtask\n- status: idea\n' > "$AG_REPO/rd-workflow-workspace/backlog/items/2026-05-15-agtask.md"
ag_mk_session() {
  local d="$AG_REPO/rd-workflow-workspace/handoffs/review_pipeline/$1"; mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}
run_ag() {
  printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
    | bash "$AG_REPO/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh" >/dev/null 2>&1; echo $?
}
ag_mk_session "20260301_000000_final-diff-review" "closed" "- 없음" "agtask"
touch "$AG_REPO/.autopilot_active"
assert_eq "$(run_ag)" "2" "archive_gate — autopilot active + 종결 + FR not done → 차단"
rm -f "$AG_REPO/.autopilot_active"
printf '# agtask\n- status: done\n' > "$AG_REPO/rd-workflow-workspace/backlog/items/2026-05-15-agtask.md"
assert_eq "$(run_ag)" "0" "archive_gate — FR done → 통과"
rm -rf "$AG_REPO"

echo "== archive.sh dry-run 비파괴성 (precheck 배치) =="
# review precheck(audit write 가능)는 dry-run exit 뒤에 있어야 dry-run --force-skip-review-check 가 audit log를 오염시키지 않는다.
ARCHIVE_SH="$SCRIPT_DIR/archive.sh"
dry_ln="$(grep -n 'DRY_RUN.*-eq 1' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
pc_ln="$(grep -n 'archive_review_precheck "' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$dry_ln" && -n "$pc_ln" && "$pc_ln" -gt "$dry_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: archive_review_precheck($pc_ln) 가 dry-run exit($dry_ln) 뒤 — dry-run 비파괴"
else
  FAIL=$((FAIL+1)); echo "  FAIL: precheck($pc_ln) 가 dry-run($dry_ln) 앞 — dry-run audit 오염 위험" >&2
fi
# fr_ref 배선 회귀 (archive-precheck-premerge-session-visibility): precheck 호출이 $FR_BRANCH 를 5번째 인자로 전달하는지
pc_wire="$(grep -E 'archive_review_precheck "' "$ARCHIVE_SH" | head -1)"
if printf '%s' "$pc_wire" | grep -q '"\$AUDIT_LOG" "\$FR_BRANCH"'; then
  PASS=$((PASS+1)); echo "  PASS: archive.sh precheck 호출이 \$FR_BRANCH 를 5번째 인자로 전달"
else
  FAIL=$((FAIL+1)); echo "  FAIL: archive.sh precheck 호출에 \$FR_BRANCH(5번째 인자) 누락 — [$pc_wire]" >&2
fi

rm -rf "$GUARD_ROOT"

# === safeguard-self-review-block: self-review 게이트 ===
source "$SCRIPT_DIR/../review_common.sh"

echo "== resolve_self_review_policy =="
assert_eq "$(resolve_self_review_policy block "")" "block" "policy=block 그대로"
assert_eq "$(resolve_self_review_policy warn "")"  "warn"  "policy=warn 그대로"
assert_eq "$(resolve_self_review_policy off "")"   "off"   "policy=off 그대로"
assert_eq "$(resolve_self_review_policy "" false)" "off"   "미설정(빈값)+warning=false → off"
assert_eq "$(resolve_self_review_policy "" true)"  "block" "미설정(빈값)+warning=true → block"
assert_eq "$(resolve_self_review_policy "" "")"    "block" "미설정(빈값)+warning 미설정 → block"
assert_eq "$(resolve_self_review_policy bogus "")" "block" "미인식 policy + warning 빈값 → block (fail-safe)"
assert_eq "$(resolve_self_review_policy bogus false)" "block" "미인식 policy + warning=false → block (finding1 회귀방지)"

echo "== evaluate_self_review_gate =="
assert_eq "$(evaluate_self_review_gate off "" "")"   "proceed-silent"    "off → silent"
assert_eq "$(evaluate_self_review_gate warn "" "")"  "proceed-warn"      "warn → warn"
assert_eq "$(evaluate_self_review_gate block 1 "")"  "proceed-autopilot" "block+autopilot → autopilot"
assert_eq "$(evaluate_self_review_gate block "" 1)"  "proceed-warn"      "block+approve → warn"
assert_eq "$(evaluate_self_review_gate block "" "")" "block"             "block+일반 → block"
assert_eq "$(evaluate_self_review_gate block 1 1)"   "proceed-autopilot" "block+autopilot이 approve보다 우선"

echo "== record_self_review_block =="
SR_UA="$(mktemp)"
# 기본 USER_ACTION 템플릿(차단 안내가 지워져야 하는 문구 포함)
printf '# User Action\n\n## Current Recommendation\n-\n\n## Why\n- \n\n## Question For User\n아직 사용자 확인이 필요한 단계가 아닙니다.\n' > "$SR_UA"
record_self_review_block "$SR_UA"
if grep -q "RD_SELF_REVIEW_APPROVE=1" "$SR_UA"; then PASS=$((PASS+1)); echo "  PASS: 승인 재실행 안내 포함"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: 승인 안내 누락" >&2; fi
if grep -q "아직 사용자 확인이 필요한 단계가 아닙니다" "$SR_UA"; then \
  FAIL=$((FAIL+1)); echo "  FAIL: 기본 no-action 문구가 남아 모순(finding3)" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: no-action 문구 제거됨"; fi
sr_snap1="$(cat "$SR_UA")"
record_self_review_block "$SR_UA"
sr_snap2="$(cat "$SR_UA")"
assert_eq "$sr_snap1" "$sr_snap2" "멱등 — 재호출 시 내용 동일"
rm -f "$SR_UA"

echo "== run_review_turn.sh self-review 차단 (script-level 통합) =="
SR_INT="$(mktemp -d)"
mkdir -p "$SR_INT/bin" "$SR_INT/session/turns"
# fake claude: 게이트가 block이면 호출되지 않아야 함 (호출되면 흔적 파일 생성)
cat > "$SR_INT/bin/claude" <<FAKE
#!/bin/sh
touch "$SR_INT/CLAUDE_WAS_CALLED"
exit 99
FAKE
chmod +x "$SR_INT/bin/claude"
# 임시 config: claude만 우선, policy=block
cat > "$SR_INT/review-tools.json" <<'CFG'
{ "default_priority": ["claude"], "tools": { "claude": { "self_review_policy": "block" } } }
CFG
# 최소 세션 fixture (Branch Context 생략 → validate_branch_context가 legacy로 skip)
cat > "$SR_INT/session/SESSION.md" <<'SES'
# Review Session
## Status
awaiting-reviewer
## Current Owner
Reviewer
## Review Type
spec-plan-review
## Review Target
target
## Review Goal
goal
## Turn Limit
20 total turns in `turns/*.md`
SES
printf '# Checkpoint\n## Current Summary\n-\n' > "$SR_INT/session/CHECKPOINT.md"
printf '# User Action\n\n## Current Recommendation\n-\n\n## Why\n- \n\n## Question For User\n아직 사용자 확인이 필요한 단계가 아닙니다.\n' > "$SR_INT/session/USER_ACTION.md"
printf '# Turn 001 Author\n' > "$SR_INT/session/turns/001_author.md"
# 일반 모드 실행 (RD_AUTOPILOT / RD_SELF_REVIEW_APPROVE 미설정)
sr_rc=0
PATH="$SR_INT/bin:$PATH" REVIEW_TOOLS_CONFIG="$SR_INT/review-tools.json" \
  RD_AUTOPILOT="" RD_SELF_REVIEW_APPROVE="" \
  bash "$SCRIPT_DIR/../run_review_turn.sh" "$SR_INT/session" >/dev/null 2>&1 || sr_rc=$?
assert_eq "$sr_rc" "3" "차단 exit code 3"
if [ ! -f "$SR_INT/session/turns/002_reviewer.md" ]; then PASS=$((PASS+1)); echo "  PASS: reviewer turn 미생성"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: reviewer turn 생성됨" >&2; fi
if grep -q "RD_SELF_REVIEW_APPROVE=1" "$SR_INT/session/USER_ACTION.md"; then PASS=$((PASS+1)); echo "  PASS: USER_ACTION 차단 안내 기록"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: USER_ACTION 차단 안내 누락" >&2; fi
assert_eq "$(awk '/^## Status/{getline; gsub(/[ \t]/,"",$0); print; exit}' "$SR_INT/session/SESSION.md")" "awaiting-reviewer" "SESSION Status awaiting-reviewer 유지"
if [ ! -f "$SR_INT/CLAUDE_WAS_CALLED" ]; then PASS=$((PASS+1)); echo "  PASS: fake claude 미호출(게이트가 adapter 전 차단)"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: claude adapter 실행됨" >&2; fi
rm -rf "$SR_INT"

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[[ $FAIL -eq 0 ]]
