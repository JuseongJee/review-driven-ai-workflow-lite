#!/usr/bin/env bash
# 워크플로 인프라(rd-workflow) self-test entrypoint.
# 본 프로젝트와 generated project 공통으로 rd-workflow 인프라가 정상인지 검증한다.
# 제품 코드 테스트(test.sh/lint.sh/typecheck.sh)와는 책임이 다르다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
run_step() {
  local desc="$1"; shift
  echo ""
  echo "== ${desc} =="
  if "$@"; then
    echo "  -> PASS: ${desc}"
  else
    echo "  -> FAIL: ${desc}" >&2
    FAIL=1
  fi
}

syntax_check() {
  local rc=0 f
  while IFS= read -r f; do
    if ! bash -n "$f" 2>/dev/null; then
      echo "  구문 오류: $f" >&2
      rc=1
    fi
  done < <(find "${SCRIPT_DIR}" -type f -name "*.sh")
  return $rc
}

# is_nonblocking_status의 비차단 집합과 CLAUDE.md 허용 상태값 동기화 검증.
# 루트 CLAUDE.md에 '대기 중'과 '완료'가 모두 존재해야 함.
# _ROOT_FILES/CLAUDE.md는 존재하면 함께 확인, 없으면 skip.
nonblocking_status_drift_check() {
  local rc=0
  local root_dir
  root_dir="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

  local targets=()
  targets+=("${root_dir}/CLAUDE.md")
  local full_cm="${root_dir}/_ROOT_FILES/rd-workflow/../CLAUDE.md"
  # _ROOT_FILES/CLAUDE.md
  [[ -f "${root_dir}/_ROOT_FILES/CLAUDE.md" ]] && targets+=("${root_dir}/_ROOT_FILES/CLAUDE.md")

  local cm
  for cm in "${targets[@]}"; do
    [[ -f "$cm" ]] || continue
    if ! grep -q '대기 중' "$cm"; then
      echo "  $cm: '대기 중' 미발견 (비차단 집합 drift 의심)" >&2
      rc=1
    fi
    if ! grep -q '완료' "$cm"; then
      echo "  $cm: '완료' 미발견 (비차단 집합 drift 의심)" >&2
      rc=1
    fi
  done
  return $rc
}

# LC-19 3자 일치 검증:
#   TASK_CANONICAL_STATUSES (_task_common.sh 배열)
#   STATE_CANONICAL_STATUSES (_state_common.sh 파이프 문자열)
#   CLAUDE.md 허용 상태값 목록 (8종 각 항목이 존재해야 함)
canonical_status_triple_drift_check() {
  local rc=0
  local root_dir
  root_dir="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

  # TASK_CANONICAL_STATUSES 추출 (_task_common.sh에서 배열 선언 파싱 — 따옴표 구분 항목)
  # 형식: TASK_CANONICAL_STATUSES=("항목1" "항목2" ...)
  # awk로 "..." 따옴표 그룹을 순서대로 추출 (BSD awk/Bash 3.2 호환)
  local task_statuses
  task_statuses="$(grep '^TASK_CANONICAL_STATUSES=' "${SCRIPT_DIR}/_task_common.sh" \
    | awk '{
        while (match($0, /"[^"]*"/)) {
          s = substr($0, RSTART+1, RLENGTH-2)
          print s
          $0 = substr($0, RSTART + RLENGTH)
        }
      }')"

  # STATE_CANONICAL_STATUSES 추출 (_state_common.sh에서 파이프 문자열 파싱)
  local state_statuses
  state_statuses="$(grep '^STATE_CANONICAL_STATUSES=' "${SCRIPT_DIR}/_state_common.sh" \
    | sed 's/STATE_CANONICAL_STATUSES="//' | sed 's/"$//' \
    | tr '|' '\n' | grep -v '^$')"

  # 집합 비교: TASK vs STATE
  local s
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if ! printf '%s\n' "$state_statuses" | grep -qxF "$s"; then
      echo "  LC-19 drift: '${s}' 가 STATE_CANONICAL_STATUSES 에 없음" >&2
      rc=1
    fi
  done <<EOF
$task_statuses
EOF

  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if ! printf '%s\n' "$task_statuses" | grep -qxF "$s"; then
      echo "  LC-19 drift: '${s}' 가 TASK_CANONICAL_STATUSES 에 없음" >&2
      rc=1
    fi
  done <<EOF
$state_statuses
EOF

  # CLAUDE.md 허용 상태값 목록 확인 (모든 대상 CLAUDE.md에서)
  local targets=()
  targets+=("${root_dir}/CLAUDE.md")
  [[ -f "${root_dir}/_ROOT_FILES/CLAUDE.md" ]] && targets+=("${root_dir}/_ROOT_FILES/CLAUDE.md")

  local cm
  for cm in "${targets[@]}"; do
    [[ -f "$cm" ]] || continue
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      if ! grep -qF "$s" "$cm"; then
        echo "  LC-19 drift: '${s}' 가 ${cm} 에 없음" >&2
        rc=1
      fi
    done <<EOF
$task_statuses
EOF
  done

  return $rc
}

# 판정 소스 회귀 grep: hooks·lifecycle·CLI에서 _extract_task_section "Status" 직접 호출이
# _guard_common.sh(legacy fallback) 와 _state_common.sh(마이그레이션 보조) 외에 존재하면 FAIL.
judgment_source_regression_check() {
  local rc=0
  local search_dirs=(
    "${SCRIPT_DIR}/hooks"
    "${SCRIPT_DIR}/lifecycle"
  )
  local rd_script="${SCRIPT_DIR}/rd"
  local allowed_files=(
    "${SCRIPT_DIR}/hooks/_guard_common.sh"
    "${SCRIPT_DIR}/_state_common.sh"
  )

  local found
  found="$(grep -rn '_extract_task_section.*Status' \
    "${search_dirs[@]}" "$rd_script" 2>/dev/null || true)"

  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local filepath; filepath="$(printf '%s' "$line" | cut -d: -f1)"
    local allowed=0
    local af
    for af in "${allowed_files[@]}"; do
      [[ "$filepath" == "$af" ]] && allowed=1 && break
    done
    if [[ "$allowed" -eq 0 ]]; then
      echo "  판정 소스 회귀: $line" >&2
      rc=1
    fi
  done <<EOF
$found
EOF

  return $rc
}

# stale active-fr / LIFECYCLE_METADATA_PATH 참조 회귀 grep.
# claude_skills/ · docs/ · scripts/ 에서 검출되면 FAIL.
# 허용 목록(주석/설명 포함 파일): 별도 처리 — 주석 제외 후 grep.
stale_metadata_reference_check() {
  local rc=0
  local root_dir
  root_dir="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

  # 정본 기준 경로 (_ROOT_FILES 하위 — 루트 rd-workflow는 Task 6 install-root 소관으로 제외)
  local rf="${root_dir}/_ROOT_FILES/rd-workflow"

  local search_dirs=()
  [[ -d "${rf}/claude_skills" ]] && search_dirs+=("${rf}/claude_skills")
  [[ -d "${rf}/docs" ]]          && search_dirs+=("${rf}/docs")
  [[ -d "${rf}/scripts" ]]       && search_dirs+=("${rf}/scripts")

  [[ "${#search_dirs[@]}" -eq 0 ]] && { echo "  (skip: 검색 경로 없음)"; return 0; }

  # 허용 목록 파일 (basename → 경로 매칭)
  # - 마이그레이션 설명 포함: task-state-guide.md
  # - legacy 마이그레이션 코드: _state_common.sh, test_state_common.sh
  # - legacy fallback: _guard_common.sh, test_guard_state.sh
  # - lifecycle helpers (변경 이력 주석 등): _lifecycle_common.sh, promote.sh, archive.sh,
  #   promote_rollback.sh, README.md, _task_common.sh
  # - legacy fixture: test_lifecycle.sh, test_integration.sh, test_task_cli.sh
  # - 이 검사 자체(grep 패턴 문자열): self_test.sh
  local allowlist=(
    "task-state-guide.md"
    "_state_common.sh"
    "test_state_common.sh"
    "_guard_common.sh"
    "test_guard_state.sh"
    "_lifecycle_common.sh"
    "promote.sh"
    "archive.sh"
    "promote_rollback.sh"
    "README.md"
    "_task_common.sh"
    "test_lifecycle.sh"
    "test_integration.sh"
    "test_task_cli.sh"
    "self_test.sh"
  )

  # grep: filepath:linenum:content 형식에서 content 파싱 후 주석 줄 제외
  local raw
  raw="$(grep -rn 'active-fr\|LIFECYCLE_METADATA_PATH' "${search_dirs[@]}" 2>/dev/null || true)"

  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local filepath; filepath="$(printf '%s' "$line" | cut -d: -f1)"
    # content 는 "path:linenum:content" 에서 세 번째 필드 이후
    local content; content="$(printf '%s' "$line" | cut -d: -f3-)"
    # 주석 줄 제외 (content의 leading whitespace 후 '#')
    case "$content" in '#'*|' '#*|'	'*) continue ;; esac
    local basename_f; basename_f="$(basename "$filepath")"
    local allowed=0
    local af
    for af in "${allowlist[@]}"; do
      [[ "$basename_f" == "$af" ]] && allowed=1 && break
    done
    if [[ "$allowed" -eq 0 ]]; then
      echo "  stale 참조: $line" >&2
      rc=1
    fi
  done <<EOF
$raw
EOF

  return $rc
}

autopilot_skill_lifecycle_check() {
  local rc=0 skill
  for skill in \
    "${SCRIPT_DIR}/../claude_skills/autopilot/SKILL.md" \
    "${SCRIPT_DIR}/../../_ROOT_FILES/rd-workflow/claude_skills/autopilot/SKILL.md"; do
    [[ -f "$skill" ]] || continue
    grep -q 'promote.sh --short-title' "$skill" || { echo "  $skill: promote.sh --short-title 미참조" >&2; rc=1; }
    grep -q 'promote_rollback.sh' "$skill" || { echo "  $skill: promote_rollback.sh 미참조" >&2; rc=1; }
    if grep -q 'checkout -b autopilot' "$skill"; then echo "  $skill: autopilot/* 직접 생성 잔존" >&2; rc=1; fi
    if grep -q 'autopilot/<' "$skill"; then echo "  $skill: autopilot/<...> 표기 잔존" >&2; rc=1; fi
    if grep -q 'checkout master' "$skill"; then echo "  $skill: master 표기 잔존" >&2; rc=1; fi
    if grep -q 'branch -D autopilot' "$skill"; then echo "  $skill: branch -D autopilot 잔존" >&2; rc=1; fi
  done
  return $rc
}

# adapter 폴링 잔존 회귀 grep: POLL_INTERVAL이 adapter_codex.sh·adapter_claude.sh에 없으면 PASS
adapter_poll_regression_check() {
  local rc=0
  local codex="${SCRIPT_DIR}/adapter_codex.sh"
  local claude="${SCRIPT_DIR}/adapter_claude.sh"
  for f in "$codex" "$claude"; do
    [[ -f "$f" ]] || continue
    if grep -q 'POLL_INTERVAL' "$f"; then
      echo "  폴링 잔존: $f 에 POLL_INTERVAL 존재" >&2
      rc=1
    fi
  done
  return $rc
}

run_step "stop_task_save_reminder hook" bash "${SCRIPT_DIR}/hooks/test_stop_task_save_reminder.sh"
run_step "state 단위 테스트 (test_state_common.sh)" bash "${SCRIPT_DIR}/test_state_common.sh"
run_step "guard state fixture (test_guard_state.sh)" bash "${SCRIPT_DIR}/hooks/test_guard_state.sh"
run_step "비차단 Status drift 검증 (nonblocking_status_drift_check)" nonblocking_status_drift_check
run_step "LC-19 3자 일치 검증 (TASK/STATE/CLAUDE.md)" canonical_status_triple_drift_check
run_step "판정 소스 회귀 grep (_extract_task_section Status 직접 호출)" judgment_source_regression_check
run_step "stale active-fr/LIFECYCLE_METADATA_PATH 참조 회귀" stale_metadata_reference_check
run_step "task CLI 단위 테스트" bash "${SCRIPT_DIR}/test_task_cli.sh"
run_step "install_claude_skills 단위 테스트" bash "${SCRIPT_DIR}/test_install_claude_skills.sh"
run_step "lifecycle 단위 테스트 (test_lifecycle.sh)" bash "${SCRIPT_DIR}/lifecycle/test_lifecycle.sh"
run_step "lifecycle 통합 테스트 (test_integration.sh)" bash "${SCRIPT_DIR}/lifecycle/test_integration.sh"
run_step "review 대기 계약 테스트 (test_review_wait.sh)" bash "${SCRIPT_DIR}/test_review_wait.sh"
pre_commit_verify_test_check() {
  local t="${SCRIPT_DIR}/hooks/test_pre_commit_verify.sh"
  if [[ -f "$t" ]]; then bash "$t"; else echo "  (skip: test_pre_commit_verify.sh 없음 — lite 산출물)"; fi
}
run_step "pre_commit_verify 테스트 (test_pre_commit_verify.sh)" pre_commit_verify_test_check
run_step "adapter 폴링 잔존 회귀 (POLL_INTERVAL 없음)" adapter_poll_regression_check
run_step "스크립트 구문 검사 (bash -n)" syntax_check
run_step "autopilot SKILL lifecycle 정합 (promote/rollback 일원화)" autopilot_skill_lifecycle_check

# 템플릿 dev repo 한정: build 규칙 정합성·루트 drift 검증 (설치본에는 빌더 없음 → skip)
# self_test.sh 위치는 <root>/rd-workflow/scripts/ 이므로 dev 빌더는 두 단계 위 scripts/
build_verify_check() {
  local builder="${SCRIPT_DIR}/../../scripts/build_template.sh"
  if [[ -f "$builder" ]]; then bash "$builder" verify; else echo "  (skip: build_template.sh 없음 — 설치본)"; fi
}
test_build_template_check() {
  local t="${SCRIPT_DIR}/../../scripts/test_build_template.sh"
  if [[ -f "$t" ]]; then bash "$t"; else echo "  (skip: dev repo 아님)"; fi
}
run_step "템플릿 build 검증 (build_template.sh verify)" build_verify_check
run_step "템플릿 빌더 단위 테스트 (test_build_template.sh)" test_build_template_check
claudemd_size_check() {
  local checker="${SCRIPT_DIR}/check_claudemd_size.sh"
  if [[ -f "$checker" ]]; then bash "$checker"; else echo "  (skip: check_claudemd_size.sh 없음 — lite 산출물)"; fi
}
run_step "CLAUDE.md 크기 제한 (check_claudemd_size.sh)" claudemd_size_check

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "== self_test 결과: PASS =="
  exit 0
else
  echo "== self_test 결과: FAIL ==" >&2
  exit 1
fi
