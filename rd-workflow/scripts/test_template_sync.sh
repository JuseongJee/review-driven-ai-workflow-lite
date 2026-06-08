#!/usr/bin/env bash
# test_template_sync.sh — 루트 ↔ 배포 원본(_ROOT_FILES/_ROOT_FILES_LITE) hook 동기화 audit.
# macOS Bash 3.2 / BSD 호환 (associative array, readlink -f 불사용).
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${RD_SYNC_PROJECT_ROOT:-$(cd "${script_dir}/../.." && pwd)}"
BASELINE_DIR="${RD_SYNC_BASELINE_DIR:-${script_dir}/template-sync-baselines}"
MANIFEST="${BASELINE_DIR}/MANIFEST.txt"

FAIL=0
fail() { echo "  [drift] $*" >&2; FAIL=1; }

# $1=절대 디렉토리, $2=상대 prefix → 상대경로 목록
list_files() {
  [[ -d "$1" ]] || return 0
  ( cd "$1" && find . -type f ! -name '.DS_Store' -not -path './.git/*' | sed "s|^\./|$2/|" )
}

# $1=루트 절대, $2=배포 절대, $3=라벨
compare_byte() {
  if [[ ! -f "$1" ]]; then fail "$3: 루트에 없음 (배포본만 존재)"; return; fi
  if [[ ! -f "$2" ]]; then fail "$3: 배포본에 없음"; return; fi
  cmp -s "$1" "$2" || fail "$3: 내용 불일치 (byte)"
}

# diff helper — baseline 생성과 audit이 반드시 공유 (헤더 경로 일관성).
# 항상 PROJECT_ROOT에서 동일 상대경로 인자로 실행.
# $1=상대경로(rd-workflow/scripts/hooks/foo.sh), $2=배포 prefix(_ROOT_FILES_LITE)
emit_diff() {
  ( cd "$PROJECT_ROOT" && diff "$1" "$2/$1" 2>/dev/null )
}

# MANIFEST 선형 탐색 → lite-absent|lite-content-diff|lite-pending|"" (Bash 3.2 호환)
# $1=상대 hooks 경로 (hooks/foo.sh 형식)
manifest_section() {
  local target="$1"
  local section=""
  [[ -f "$MANIFEST" ]] || { printf ""; return; }
  while IFS= read -r line; do
    # 빈 줄·주석 무시
    case "$line" in
      "" | \#*) continue ;;
    esac
    # 섹션 헤더 감지
    case "$line" in
      \[lite-absent\]*)     section="lite-absent";      continue ;;
      \[lite-content-diff\]*) section="lite-content-diff"; continue ;;
      \[lite-pending\]*)    section="lite-pending";     continue ;;
      \[*\]*)               section="";                 continue ;;
    esac
    # 엔트리 매칭 (pending은 "hooks/x.sh fr=..." 형식이므로 첫 토큰만 비교)
    local entry_file
    entry_file="${line%% *}"
    if [[ "$entry_file" == "$target" ]]; then
      printf "%s" "$section"
      return
    fi
  done < "$MANIFEST"
  printf ""
}

# audit 자기검증 대상 (hooks/ 밖, 양 배포본과 byte-identical이어야 함). PROJECT_ROOT 기준 상대경로.
self_rel_list() {
  echo "rd-workflow/scripts/test_template_sync.sh"
  list_files "${PROJECT_ROOT}/rd-workflow/scripts/template-sync-baselines" "rd-workflow/scripts/template-sync-baselines"
}

# 루트 ↔ _ROOT_FILES, 전부 byte-identical (hooks/ + self 파일)
audit_full() {
  local root="${PROJECT_ROOT}" rf="${PROJECT_ROOT}/_ROOT_FILES" rel
  for rel in $( { list_files "${root}/rd-workflow/scripts/hooks" "rd-workflow/scripts/hooks";
                  list_files "${rf}/rd-workflow/scripts/hooks" "rd-workflow/scripts/hooks";
                  self_rel_list; } | sort -u ); do
    compare_byte "${root}/${rel}" "${rf}/${rel}" "full:${rel}"
  done
}

# 루트 ↔ _ROOT_FILES_LITE
audit_lite() {
  [[ -d "${PROJECT_ROOT}/_ROOT_FILES_LITE" ]] || return 0
  local root="${PROJECT_ROOT}" lf="${PROJECT_ROOT}/_ROOT_FILES_LITE" rel sec base
  # 1) hooks/ 합집합 — MANIFEST 분류
  for rel in $( { list_files "${root}/rd-workflow/scripts/hooks" "hooks";
                  list_files "${lf}/rd-workflow/scripts/hooks" "hooks"; } | sort -u ); do
    sec="$(manifest_section "$rel")"
    case "$sec" in
      lite-absent)
        [[ -f "${lf}/rd-workflow/scripts/${rel}" ]] && fail "lite:${rel}: absent 등록인데 lite에 존재" ;;
      lite-content-diff|lite-pending)
        base="${BASELINE_DIR}/lite/${rel#hooks/}.diff"
        if [[ ! -f "$base" ]]; then
          # MANIFEST엔 등록됐으나 baseline .diff 파일이 누락 — "내용 변화"와 구분해 별도 진단.
          fail "lite:${rel}: baseline 파일 없음 (${sec}) — ${base}"
        else
          local _tmp_diff
          _tmp_diff="$(mktemp)"
          emit_diff "rd-workflow/scripts/${rel}" "_ROOT_FILES_LITE" > "$_tmp_diff" || true
          if ! cmp -s "$_tmp_diff" "$base"; then
            fail "lite:${rel}: baseline 불일치 (${sec}) — baseline 갱신/엔트리 검토"
          fi
          rm -f "$_tmp_diff"
        fi ;;
      *)
        compare_byte "${root}/rd-workflow/scripts/${rel}" "${lf}/rd-workflow/scripts/${rel}" "lite:${rel}" ;;
    esac
  done
  # 2) self 파일 — lite 배포본도 byte-identical (Finding 2)
  for rel in $(self_rel_list); do
    compare_byte "${root}/${rel}" "${lf}/${rel}" "lite-self:${rel}"
  done
}

run_real_audit() {
  if [[ ! -d "${PROJECT_ROOT}/_ROOT_FILES" ]]; then
    echo "  [skip] _ROOT_FILES 없음 — dev 전용 동기화 검증 skip (generated 프로젝트)"
    return 0
  fi
  audit_full
  audit_lite
  # 종료 코드는 호출자(main)가 전역 $FAIL로 결정한다 — 여기선 흐름만 반환.
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
    rm -rf "$_current_fixture"
    _current_fixture=""
  fi
}
trap '_cleanup_fixture' EXIT INT TERM

# selfcheck 결과 보고
_sc_result() {
  local num="$1" name="$2" expected_exit="$3" actual_exit="$4"
  if [[ "$actual_exit" == "$expected_exit" ]]; then
    echo "[PASS] scenario ${num}: ${name} (exit=${actual_exit})"
    _SC_PASS=$((_SC_PASS + 1))
  else
    echo "[FAIL] scenario ${num}: ${name} — expected exit=${expected_exit}, actual exit=${actual_exit}" >&2
    _SC_FAIL=$((_SC_FAIL + 1))
  fi
}

run_selfcheck() {
  echo "=== selfcheck: template sync audit ==="

  # ------------------------------------------------------------------
  # 공통 fixture 생성 헬퍼
  # ------------------------------------------------------------------
  _make_base_fixture() {
    local f
    f="$(mktemp -d)"
    mkdir -p "$f/rd-workflow/scripts/hooks"
    mkdir -p "$f/_ROOT_FILES/rd-workflow/scripts/hooks"
    mkdir -p "$f/_ROOT_FILES_LITE/rd-workflow/scripts/hooks"
    mkdir -p "$f/baselines/lite"
    # 기본 hook 파일 (루트 + full + lite 모두 동일)
    printf "#!/bin/bash\n# hook A\n" > "$f/rd-workflow/scripts/hooks/hook_a.sh"
    cp "$f/rd-workflow/scripts/hooks/hook_a.sh" "$f/_ROOT_FILES/rd-workflow/scripts/hooks/hook_a.sh"
    cp "$f/rd-workflow/scripts/hooks/hook_a.sh" "$f/_ROOT_FILES_LITE/rd-workflow/scripts/hooks/hook_a.sh"
    # self 파일 (test_template_sync.sh) — 3곳 동일
    mkdir -p "$f/rd-workflow/scripts"
    cp "${BASH_SOURCE[0]}" "$f/rd-workflow/scripts/test_template_sync.sh"
    cp "${BASH_SOURCE[0]}" "$f/_ROOT_FILES/rd-workflow/scripts/test_template_sync.sh"
    cp "${BASH_SOURCE[0]}" "$f/_ROOT_FILES_LITE/rd-workflow/scripts/test_template_sync.sh"
    # self 파일 (template-sync-baselines/) — audit 자기검증 대상.
    # self_rel_list()는 RD_SYNC_BASELINE_DIR과 무관하게 PROJECT_ROOT/rd-workflow/scripts/
    # template-sync-baselines/ 트리를 검사하므로, 3곳에 byte-identical 사본을 둔다.
    for dest in "$f/rd-workflow/scripts" "$f/_ROOT_FILES/rd-workflow/scripts" "$f/_ROOT_FILES_LITE/rd-workflow/scripts"; do
      mkdir -p "$dest/template-sync-baselines/lite"
      printf "[lite-content-diff]\n# self baseline\n" > "$dest/template-sync-baselines/MANIFEST.txt"
      printf "# self diff baseline\n" > "$dest/template-sync-baselines/lite/self_sample.sh.diff"
    done
    # 빈 MANIFEST (audit 분류용 — RD_SYNC_BASELINE_DIR로 주입되는 격리 manifest)
    printf "" > "$f/baselines/MANIFEST.txt"
    printf "%s" "$f"
  }

  # fixture 안에서 실제 audit 실행 (run_real_audit 경로)
  _exec_audit() {
    local fixture="$1" baseline_dir="$2"
    local out exit_code
    out=$(RD_SYNC_PROJECT_ROOT="$fixture" RD_SYNC_BASELINE_DIR="$baseline_dir" \
          bash "${BASH_SOURCE[0]}" --_run_audit_only 2>&1)
    exit_code=$?
    printf "%s" "$out"
    return $exit_code
  }

  # ------------------------------------------------------------------
  # 시나리오 1: full clean (루트=_ROOT_FILES hooks byte-identical) → pass
  # ------------------------------------------------------------------
  local f exit_code
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 1 "full clean → pass" 0 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 2: full drift (한 파일 1바이트 차이) → fail
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  printf "#!/bin/bash\n# hook A DRIFTED\n" > "$f/_ROOT_FILES/rd-workflow/scripts/hooks/hook_a.sh"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 2 "full drift → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 3: full 누락 (_ROOT_FILES에만 존재) → fail
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  # _ROOT_FILES에만 있는 파일 추가 (루트에 없음)
  printf "#!/bin/bash\n# only in rf\n" > "$f/_ROOT_FILES/rd-workflow/scripts/hooks/only_rf.sh"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 3 "full 누락 (_ROOT_FILES에만 존재) → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 4: lite absent 정상 (MANIFEST absent 등록 파일이 lite에 없음) → pass
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  # 루트에만 있는 파일 추가 (_ROOT_FILES에도 동일, lite에는 없음)
  printf "#!/bin/bash\n# absent hook\n" > "$f/rd-workflow/scripts/hooks/absent_hook.sh"
  cp "$f/rd-workflow/scripts/hooks/absent_hook.sh" "$f/_ROOT_FILES/rd-workflow/scripts/hooks/absent_hook.sh"
  # MANIFEST에 lite-absent 등록
  printf "[lite-absent]\nhooks/absent_hook.sh\n" > "$f/baselines/MANIFEST.txt"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 4 "lite absent 정상 → pass" 0 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 5: lite absent 위반 (absent 등록인데 lite에 존재) → fail
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  printf "#!/bin/bash\n# absent hook\n" > "$f/rd-workflow/scripts/hooks/absent_hook.sh"
  cp "$f/rd-workflow/scripts/hooks/absent_hook.sh" "$f/_ROOT_FILES/rd-workflow/scripts/hooks/absent_hook.sh"
  # lite에도 파일 존재 (위반)
  cp "$f/rd-workflow/scripts/hooks/absent_hook.sh" "$f/_ROOT_FILES_LITE/rd-workflow/scripts/hooks/absent_hook.sh"
  printf "[lite-absent]\nhooks/absent_hook.sh\n" > "$f/baselines/MANIFEST.txt"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 5 "lite absent 위반 → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 6: lite content-diff 일치 (baseline과 실제 diff 동일) → pass
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  printf "#!/bin/bash\n# diff hook (root)\n" > "$f/rd-workflow/scripts/hooks/diff_hook.sh"
  cp "$f/rd-workflow/scripts/hooks/diff_hook.sh" "$f/_ROOT_FILES/rd-workflow/scripts/hooks/diff_hook.sh"
  printf "#!/bin/bash\n# diff hook (lite version)\n" > "$f/_ROOT_FILES_LITE/rd-workflow/scripts/hooks/diff_hook.sh"
  # baseline을 emit_diff와 동일 방식으로 생성 (cd PROJECT_ROOT + 상대경로 인자)
  ( cd "$f" && diff "rd-workflow/scripts/hooks/diff_hook.sh" "_ROOT_FILES_LITE/rd-workflow/scripts/hooks/diff_hook.sh" \
    > "$f/baselines/lite/diff_hook.sh.diff" ) || true
  printf "[lite-content-diff]\nhooks/diff_hook.sh\n" > "$f/baselines/MANIFEST.txt"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 6 "lite content-diff 일치 → pass" 0 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 7: lite content-diff 불일치 (실제 diff가 baseline과 다름) → fail
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  printf "#!/bin/bash\n# diff hook (root)\n" > "$f/rd-workflow/scripts/hooks/diff_hook.sh"
  cp "$f/rd-workflow/scripts/hooks/diff_hook.sh" "$f/_ROOT_FILES/rd-workflow/scripts/hooks/diff_hook.sh"
  printf "#!/bin/bash\n# diff hook (lite version)\n" > "$f/_ROOT_FILES_LITE/rd-workflow/scripts/hooks/diff_hook.sh"
  # baseline을 다른 내용으로 생성 (불일치 유도)
  printf "# stale baseline\n" > "$f/baselines/lite/diff_hook.sh.diff"
  printf "[lite-content-diff]\nhooks/diff_hook.sh\n" > "$f/baselines/MANIFEST.txt"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 7 "lite content-diff 불일치 → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 8: lite 미등록 drift (MANIFEST에 없는데 차이) → fail
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  # hook_a.sh가 루트와 lite에서 다름, MANIFEST엔 등록 없음
  printf "#!/bin/bash\n# hook A LITE DIFFERENT\n" > "$f/_ROOT_FILES_LITE/rd-workflow/scripts/hooks/hook_a.sh"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 8 "lite 미등록 drift → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 9: graceful skip (_ROOT_FILES 없음) → pass + skip 메시지
  # ------------------------------------------------------------------
  f="$(mktemp -d)"
  _current_fixture="$f"
  mkdir -p "$f/rd-workflow/scripts"
  mkdir -p "$f/baselines"
  # _ROOT_FILES 없음 (graceful skip 조건)
  local skip_out
  skip_out=$(RD_SYNC_PROJECT_ROOT="$f" RD_SYNC_BASELINE_DIR="$f/baselines" \
             bash "${BASH_SOURCE[0]}" --_run_audit_only 2>&1)
  exit_code=$?
  local skip_ok=0
  printf "%s" "$skip_out" | grep -q "skip" && skip_ok=1
  if [[ "$exit_code" == "0" && "$skip_ok" == "1" ]]; then
    echo "[PASS] scenario 9: graceful skip (_ROOT_FILES 없음) → pass + skip 메시지 (exit=0)"
    _SC_PASS=$((_SC_PASS + 1))
  else
    echo "[FAIL] scenario 9: graceful skip — exit=${exit_code}, skip_msg=${skip_ok}" >&2
    _SC_FAIL=$((_SC_FAIL + 1))
  fi
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 10: lite self 파일 drift (lite 배포본의 test_template_sync.sh가 루트와 다름) → fail
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  # lite의 test_template_sync.sh를 변조
  printf "# DRIFTED\n" >> "$f/_ROOT_FILES_LITE/rd-workflow/scripts/test_template_sync.sh"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 10 "lite self 파일 (test_template_sync.sh) drift → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 11: lite baselines 파일 drift (lite 배포본의 template-sync-baselines/* 가 루트와 다름) → fail
  #   Finding 2 회귀 방지의 나머지 절반: self_rel_list가 baselines/ 트리도 자기검증함을 실증.
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  # lite 배포본의 baselines diff 파일을 변조 (test_template_sync.sh는 그대로)
  printf "# BASELINE DRIFTED\n" >> "$f/_ROOT_FILES_LITE/rd-workflow/scripts/template-sync-baselines/lite/self_sample.sh.diff"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 11 "lite self 파일 (template-sync-baselines/*) drift → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 12: full 루트-only 미동기화 (루트 hooks/에 새 파일, _ROOT_FILES에 없음) → fail
  #   가장 흔한 drift: 루트 신규 hook을 배포본에 동기화 안 함. "배포본에 없음" 검출.
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  # 루트에만 신규 hook 추가 (_ROOT_FILES/_ROOT_FILES_LITE 모두 없음)
  printf "#!/bin/bash\n# new root-only hook\n" > "$f/rd-workflow/scripts/hooks/new_hook.sh"
  _exec_audit "$f" "$f/baselines" >/dev/null 2>&1; exit_code=$?
  _sc_result 12 "full 루트-only 미동기화 (배포본에 없음) → fail" 1 "$exit_code"
  _cleanup_fixture

  # ------------------------------------------------------------------
  # 시나리오 13: MANIFEST 등록인데 baseline .diff 파일 부재 → fail (내용 변화와 구분)
  # ------------------------------------------------------------------
  f="$(_make_base_fixture)"
  _current_fixture="$f"
  printf "#!/bin/bash\n# diff hook (root)\n" > "$f/rd-workflow/scripts/hooks/diff_hook.sh"
  cp "$f/rd-workflow/scripts/hooks/diff_hook.sh" "$f/_ROOT_FILES/rd-workflow/scripts/hooks/diff_hook.sh"
  printf "#!/bin/bash\n# diff hook (lite version)\n" > "$f/_ROOT_FILES_LITE/rd-workflow/scripts/hooks/diff_hook.sh"
  # MANIFEST엔 등록하되 baseline .diff는 생성하지 않음 (부재)
  printf "[lite-content-diff]\nhooks/diff_hook.sh\n" > "$f/baselines/MANIFEST.txt"
  local _drift_out
  _drift_out=$(RD_SYNC_PROJECT_ROOT="$f" RD_SYNC_BASELINE_DIR="$f/baselines" \
               bash "${BASH_SOURCE[0]}" --_run_audit_only 2>&1)
  exit_code=$?
  local _msg_ok=0
  printf "%s" "$_drift_out" | grep -q "baseline 파일 없음" && _msg_ok=1
  if [[ "$exit_code" == "1" && "$_msg_ok" == "1" ]]; then
    echo "[PASS] scenario 13: baseline .diff 부재 → fail + 별도 진단 메시지 (exit=1)"
    _SC_PASS=$((_SC_PASS + 1))
  else
    echo "[FAIL] scenario 13: baseline .diff 부재 — exit=${exit_code}, msg_ok=${_msg_ok}" >&2
    _SC_FAIL=$((_SC_FAIL + 1))
  fi
  _cleanup_fixture

  # ------------------------------------------------------------------
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

  # 내부 플래그: audit만 실행 (selfcheck fixture에서 서브프로세스로 호출)
  if [[ "$arg" == "--_run_audit_only" ]]; then
    run_real_audit
    exit $FAIL
  fi

  if [[ "$arg" == "--selfcheck" ]]; then
    run_selfcheck
    exit $?
  fi

  # 기본 모드: selfcheck 먼저, 통과 시 실제 audit
  run_selfcheck || { echo "selfcheck 실패 — audit 로직 점검 필요" >&2; exit 1; }
  run_real_audit
  exit $FAIL
}
main "$@"
