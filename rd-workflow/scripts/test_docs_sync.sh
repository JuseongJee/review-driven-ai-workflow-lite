#!/usr/bin/env bash
# test_docs_sync.sh — 루트 rd-workflow/docs/ ↔ 정본 _ROOT_FILES/rd-workflow/docs/ 동기화 audit.
# 정본(source of truth) = _ROOT_FILES/rd-workflow/docs/ (sync_root_ai.md 참조).
# 제외 allowlist(EXCLUDE)는 루트/dev 전용 파일 — sync_root_ai.md "sync 제외" 섹션과 cross-reference.
# macOS Bash 3.2 / BSD 호환.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${RD_DOCS_SYNC_PROJECT_ROOT:-$(cd "${script_dir}/../.." && pwd)}"

# docs/ 검증 제외 — 루트/dev 전용 (배포 제외). sync_root_ai.md와 일관 유지.
# 상대경로는 docs/ 기준 (예: guides/sync_root_ai.md).
EXCLUDE_LIST="guides/sync_root_ai.md"

FAIL=0
fail() { echo "  [drift] $*" >&2; FAIL=1; }

is_excluded() {
  local rel="$1" e
  for e in $EXCLUDE_LIST; do
    [[ "$rel" == "$e" ]] && return 0
  done
  return 1
}

# $1=절대 docs 디렉토리 → docs/ 기준 상대경로 목록
list_docs() {
  [[ -d "$1" ]] || return 0
  ( cd "$1" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' )
}

compare_byte() {
  local rootf="$1" canonf="$2" label="$3"
  if [[ ! -f "$rootf" ]]; then fail "$label: 루트에 없음 (정본에만 존재)"; return; fi
  if [[ ! -f "$canonf" ]]; then fail "$label: 정본에 없음 (루트에만 존재)"; return; fi
  cmp -s "$rootf" "$canonf" || fail "$label: 내용 불일치 (byte)"
}

run_real_audit() {
  local root_docs="${PROJECT_ROOT}/rd-workflow/docs"
  local canon_docs="${PROJECT_ROOT}/_ROOT_FILES/rd-workflow/docs"
  if [[ ! -d "$canon_docs" ]]; then
    echo "  [skip] _ROOT_FILES/rd-workflow/docs 없음 — dev 전용 docs 동기화 검증 skip (generated 프로젝트)"
    return 0
  fi
  local rel
  for rel in $( { list_docs "$root_docs"; list_docs "$canon_docs"; } | sort -u ); do
    if is_excluded "$rel"; then continue; fi
    compare_byte "${root_docs}/${rel}" "${canon_docs}/${rel}" "docs:${rel}"
  done
  return 0
}

# ===========================================================================
# selfcheck — fixture 격리 시나리오 (TDD)
# ===========================================================================
_SC_PASS=0
_SC_FAIL=0
_current_fixture=""

_cleanup_fixture() {
  if [[ -n "$_current_fixture" && -d "$_current_fixture" ]]; then
    rm -rf "$_current_fixture"; _current_fixture=""
  fi
}
trap '_cleanup_fixture' EXIT INT TERM

_sc_result() {
  local num="$1" name="$2" expected="$3" actual="$4"
  if [[ "$actual" == "$expected" ]]; then
    echo "[PASS] scenario ${num}: ${name} (exit=${actual})"
    _SC_PASS=$((_SC_PASS + 1))
  else
    echo "[FAIL] scenario ${num}: ${name} — expected=${expected}, actual=${actual}" >&2
    _SC_FAIL=$((_SC_FAIL + 1))
  fi
}

_make_fixture() {
  local f; f="$(mktemp -d)"
  mkdir -p "$f/rd-workflow/docs/guides"
  mkdir -p "$f/_ROOT_FILES/rd-workflow/docs/guides"
  # 공통 파일 (양쪽 동일)
  printf "# doc A\n" > "$f/rd-workflow/docs/AI_DOC_MAP.md"
  cp "$f/rd-workflow/docs/AI_DOC_MAP.md" "$f/_ROOT_FILES/rd-workflow/docs/AI_DOC_MAP.md"
  printf "# guide G\n" > "$f/rd-workflow/docs/guides/g.md"
  cp "$f/rd-workflow/docs/guides/g.md" "$f/_ROOT_FILES/rd-workflow/docs/guides/g.md"
  printf "%s" "$f"
}

_exec_audit() {
  local fixture="$1" out exit_code
  out=$(RD_DOCS_SYNC_PROJECT_ROOT="$fixture" bash "${BASH_SOURCE[0]}" --_run_audit_only 2>&1)
  exit_code=$?
  printf "%s" "$out"
  return $exit_code
}

run_selfcheck() {
  echo "=== selfcheck: docs sync audit ==="
  local f exit_code

  # 시나리오 1: clean → pass
  f="$(_make_fixture)"; _current_fixture="$f"
  _exec_audit "$f" >/dev/null 2>&1; exit_code=$?
  _sc_result 1 "clean → pass" 0 "$exit_code"; _cleanup_fixture

  # 시나리오 2: 내용 drift → fail
  f="$(_make_fixture)"; _current_fixture="$f"
  printf "# doc A DRIFTED\n" > "$f/_ROOT_FILES/rd-workflow/docs/AI_DOC_MAP.md"
  _exec_audit "$f" >/dev/null 2>&1; exit_code=$?
  _sc_result 2 "내용 drift → fail" 1 "$exit_code"; _cleanup_fixture

  # 시나리오 3: 정본에만 존재 (루트 누락) → fail
  f="$(_make_fixture)"; _current_fixture="$f"
  printf "# only canon\n" > "$f/_ROOT_FILES/rd-workflow/docs/USER_MANUAL.md"
  _exec_audit "$f" >/dev/null 2>&1; exit_code=$?
  _sc_result 3 "정본에만 존재 → fail" 1 "$exit_code"; _cleanup_fixture

  # 시나리오 4: 루트에만 존재 (정본 누락) → fail
  f="$(_make_fixture)"; _current_fixture="$f"
  printf "# only root\n" > "$f/rd-workflow/docs/EXTRA.md"
  _exec_audit "$f" >/dev/null 2>&1; exit_code=$?
  _sc_result 4 "루트에만 존재 → fail" 1 "$exit_code"; _cleanup_fixture

  # 시나리오 5: 제외 파일만 차이 → pass (오탐 없음)
  f="$(_make_fixture)"; _current_fixture="$f"
  printf "# root-only sync doc\n" > "$f/rd-workflow/docs/guides/sync_root_ai.md"
  _exec_audit "$f" >/dev/null 2>&1; exit_code=$?
  _sc_result 5 "제외 파일만 차이 → pass" 0 "$exit_code"; _cleanup_fixture

  # 시나리오 6: graceful skip (_ROOT_FILES 없음) → pass + skip 메시지
  f="$(mktemp -d)"; _current_fixture="$f"
  mkdir -p "$f/rd-workflow/docs"
  local skip_out; skip_out=$(RD_DOCS_SYNC_PROJECT_ROOT="$f" bash "${BASH_SOURCE[0]}" --_run_audit_only 2>&1)
  exit_code=$?
  local skip_ok=0; printf "%s" "$skip_out" | grep -q "skip" && skip_ok=1
  if [[ "$exit_code" == "0" && "$skip_ok" == "1" ]]; then
    echo "[PASS] scenario 6: graceful skip (_ROOT_FILES 없음) → pass + skip 메시지 (exit=0)"
    _SC_PASS=$((_SC_PASS + 1))
  else
    echo "[FAIL] scenario 6: graceful skip — exit=${exit_code}, skip_msg=${skip_ok}" >&2
    _SC_FAIL=$((_SC_FAIL + 1))
  fi
  _cleanup_fixture

  echo ""
  echo "Results: ${_SC_PASS} passed, ${_SC_FAIL} failed"
  [[ "$_SC_FAIL" -gt 0 ]] && return 1
  return 0
}

# ===========================================================================
# 진입점
# ===========================================================================
main() {
  local arg="${1:-}"
  if [[ "$arg" == "--_run_audit_only" ]]; then
    run_real_audit; exit $FAIL
  fi
  if [[ "$arg" == "--selfcheck" ]]; then
    run_selfcheck; exit $?
  fi
  run_selfcheck || { echo "selfcheck 실패 — audit 로직 점검 필요" >&2; exit 1; }
  run_real_audit
  exit $FAIL
}
main "$@"
