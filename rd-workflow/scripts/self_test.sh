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
  # - 마이그레이션 설명 포함: task-state-guide.md, sync_template.md
  # - legacy 마이그레이션 코드: _state_common.sh, test_state_common.sh
  # - legacy fallback: _guard_common.sh, test_guard_state.sh
  # - lifecycle helpers (변경 이력 주석 등): _lifecycle_common.sh, promote.sh, archive.sh,
  #   promote_rollback.sh, README.md, _task_common.sh
  # - legacy fixture: test_lifecycle.sh, test_integration.sh, test_task_cli.sh
  # - 이 검사 자체(grep 패턴 문자열): self_test.sh
  local allowlist=(
    "task-state-guide.md"
    "sync_template.md"
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

# 무인 진입 계약 정합: SKILL.md 무인 섹션 마커 + wrapper 존재.
autopilot_headless_entry_check() {
  # 배포 사본은 필수, _ROOT_FILES 정본은 설치본에 없는 것이 정상이라 선택이다 (batch 루프도 동일).
  local rc=0 skill skill_root="${SCRIPT_DIR}/../claude_skills/autopilot/SKILL.md"
  [[ -f "$skill_root" ]] || { echo "  $skill_root: 필수 파일 부재" >&2; rc=1; }
  for skill in \
    "$skill_root" \
    "${SCRIPT_DIR}/../../_ROOT_FILES/rd-workflow/claude_skills/autopilot/SKILL.md"; do
    [[ -f "$skill" ]] || continue
    grep -q 'RD_AUTOPILOT_FR' "$skill"           || { echo "  $skill: RD_AUTOPILOT_FR 미참조" >&2; rc=1; }
    grep -q 'RD_AUTOPILOT_OUTCOME_FILE' "$skill"  || { echo "  $skill: RD_AUTOPILOT_OUTCOME_FILE 미참조" >&2; rc=1; }
    grep -q 'queue-empty' "$skill"                || { echo "  $skill: queue-empty 미참조" >&2; rc=1; }
    grep -q 'blocked:' "$skill"                   || { echo "  $skill: blocked:<reason> 미참조" >&2; rc=1; }
    grep -q '결과 대기 규율' "$skill"             || { echo "  $skill: 결과 대기 규율 절 미존재" >&2; rc=1; }
    grep -q 'run_in_background' "$skill"          || { echo "  $skill: run_in_background 금지 규율 미참조" >&2; rc=1; }
    grep -q 'resume' "$skill"                     || { echo "  $skill: resume 토큰 미참조" >&2; rc=1; }
    grep -q '600000' "$skill"                     || { echo "  $skill: timeout 최대치(600000ms) 미참조" >&2; rc=1; }
    grep -q 'WAIT_TIMEOUT' "$skill"                || { echo "  $skill: 어댑터 watchdog(WAIT_TIMEOUT) 중첩 타이머 규율 미참조" >&2; rc=1; }
    grep -q '진행 신호' "$skill"                   || { echo "  $skill: 긴 대기 진행 신호 규율 미참조" >&2; rc=1; }
  done
  # batch 국면 2 의 exit 40 복구 경로 — 진행 상태·사용자 안내 보존의 핵심이라 앵커로 고정한다.
  # 배포 사본은 필수, _ROOT_FILES 정본은 설치본에 없는 것이 정상이라 선택이다.
  # 둘 다 선택으로 두면 배포 사본이 통째로 사라져도 0건 검사로 통과한다.
  local batch batch_root="${SCRIPT_DIR}/../claude_skills/fr/batch.md"
  [[ -f "$batch_root" ]] || { echo "  $batch_root: 필수 파일 부재" >&2; rc=1; }
  for batch in \
    "$batch_root" \
    "${SCRIPT_DIR}/../../_ROOT_FILES/rd-workflow/claude_skills/fr/batch.md"; do
    [[ -f "$batch" ]] || continue
    grep -q '재개 지점을 정리' "$batch" || { echo "  $batch: exit 40 재개 지점 정리 절차 미존재" >&2; rc=1; }
    grep -q 'USER_ACTION' "$batch"      || { echo "  $batch: 사용자 인계(USER_ACTION) 갱신 지시 미존재" >&2; rc=1; }
  done
  local wrapper="${SCRIPT_DIR}/autopilot_headless.sh"
  [[ -f "$wrapper" ]] || { echo "  autopilot_headless.sh 부재" >&2; rc=1; }
  return $rc
}

plan_parallel_phase_check() {
  local root guide skill
  root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  guide="$root/rd-workflow/docs/guides/plan-parallel-phases.md"
  skill="$root/rd-workflow/claude_skills/autopilot/SKILL.md"
  [[ -f "$guide" ]] || { echo "  누락: plan-parallel-phases.md"; return 1; }
  grep -q "phase 비중첩" "$guide" || { echo "  가이드에 phase 비중첩 게이트 누락"; return 1; }
  grep -q "mechanical" "$guide" || { echo "  가이드에 mechanical 규약 누락"; return 1; }
  grep -q "phase 병렬 실행" "$skill" || { echo "  autopilot SKILL에 phase 병렬 실행 규칙 누락"; return 1; }
  grep -q "mechanical" "$skill" || { echo "  autopilot SKILL에 mechanical 리뷰 생략 누락"; return 1; }
  echo "  OK: phase 병렬 규약 문서 정합"
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

# ---- hook 경로 표기 검사 3종 ----
# 파싱 규약: rd-workflow-workspace/specs/changes/2026-08-07-0825-guard-hook-path-resolution-change-spec.md §2.4
# 같은 규약의 다른 구현: scripts/build_template.sh extract_hook_paths() — 규약 변경 시 양쪽을 함께 고친다.

# 설치본과 정본 양쪽에서 같은 저장소 root 를 얻는다.
#   설치본: <repo>/rd-workflow/scripts   → ../.. = <repo>
#   정본:   <repo>/_ROOT_FILES/rd-workflow/scripts → ../.. = <repo>/_ROOT_FILES → 한 단계 더
# 정본(`<repo>/_ROOT_FILES/rd-workflow/scripts`)과 설치본(`<repo>/rd-workflow/scripts`)에서
# 같은 저장소 root 를 반환한다.
#
# 이름만 보고 판정하면 저장소 디렉터리 자체가 `_ROOT_FILES` 인 설치본을 정본으로 오인한다
# (두 경우의 경로 모양이 완전히 같아 경로만으로는 구분되지 않는다). 부모가 실제 dev repo 인지를
# 빌더 존재로 확인한다 — `scripts/build_template.sh` 는 dev repo 전용이라 배포본에 없다.
_hook_repo_root() {
  local two_up; two_up="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  if [[ "$(basename "$two_up")" == "_ROOT_FILES" ]] \
     && [[ -f "$(dirname "$two_up")/scripts/build_template.sh" ]]; then
    dirname "$two_up"
  else
    printf '%s\n' "$two_up"
  fi
}

# settings.json → repo 상대 경로 (규약 P2). registry 계약 밖 값은 제외한다.
_hook_extract_paths() {  # $1=settings.json
  sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"bash \(.*\)".*/\1/p' "$1" \
    | sed -e 's|^\\"\${CLAUDE_PROJECT_DIR:-\.}\\"/||' \
    | grep -E '^rd-workflow/scripts/hooks/[A-Za-z0-9_.-]+\.sh$'
}

# settings.json → 실행 가능한 command 원문 (JSON 이스케이프 해제)
_hook_extract_commands() {  # $1=settings.json
  sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"bash \(.*\)".*/bash \1/p' "$1" \
    | sed 's/\\"/"/g'
}

# bash hook command 항목 수 (규약 P4 — 행 수가 아니라 항목 수).
# no-match(0건)는 정상이다. grep status 1 이 set -o pipefail 하에서 대입문을 실패시키므로 흡수한다.
_hook_count_commands() {  # $1=settings.json
  { grep -o '"command"[[:space:]]*:[[:space:]]*"bash ' "$1" || true; } | wc -l | tr -d '[:space:]'
}

# 규약 P6 — 값이 키와 같은 행에서 시작해야 한다. 다음 행으로 넘어간 항목은 계수·추출 양쪽에서
# 함께 누락되어 P4 대조를 통과하므로, `"command"` 키 총수와 대조해 별도로 잡는다.
# 키 총수는 개행을 공백으로 정규화한 뒤 센다 — 키와 콜론 사이 개행도 command 1건이므로,
# 행 단위로 세면 그 변형이 키 계수에서도 함께 사라져 대조를 통과한다.
_hook_count_command_keys() {  # $1=settings.json
  { tr '\n' ' ' < "$1" | grep -o '"command"[[:space:]]*:' || true; } | wc -l | tr -d '[:space:]'
}
_hook_count_inline_values() {  # $1=settings.json
  { grep -o '"command"[[:space:]]*:[[:space:]]*"' "$1" || true; } | wc -l | tr -d '[:space:]'
}

# 검사 대상 목록. 배포본에는 _ROOT_FILES/ 와 scripts/ 가 없다.
# 루트 설정만 필수로 두고 나머지는 선택으로 둔다 — 전부 선택이면 대상이 모두 사라져도 0건 검사로 거짓 통과한다.
_hook_settings_targets() {  # 출력: "<REQUIRED|OPTIONAL> <path>"
  local root; root="$(_hook_repo_root)"
  echo "REQUIRED ${root}/.claude/settings.json"
  echo "OPTIONAL ${root}/_ROOT_FILES/.claude/settings.json"
  echo "OPTIONAL ${root}/scripts/build-rules/lite-overrides/.claude/settings.json"
}

# hook command 를 원문 그대로 실행해 대상 도달을 양성 증명한다 (§2.5.2).
# 검증 대상은 "경로 해석"이며 hook 판정 로직이 아니다 (후자는 hooks/test_*.sh 담당).
# 명령을 수정하지 않고 파일시스템을 대역으로 세우므로 prefix·따옴표를 우회할 수 없다.
hook_path_reachability_check() {
  local rc=0 kind settings probe_base
  probe_base="$(mktemp -d)"
  while read -r kind settings; do
    if [[ ! -f "$settings" ]]; then
      [[ "$kind" == "REQUIRED" ]] && { echo "  $settings: 필수 파일 부재" >&2; rc=1; }
      continue
    fi
    _hook_probe_settings "$settings" "$probe_base" || rc=1
  done < <(_hook_settings_targets)
  rm -rf "$probe_base"
  return $rc
}

# $1=settings.json $2=probe base dir
_hook_probe_settings() {
  local settings="$1" probe_base="$2"
  local rc=0 idx=0 n_paths=0 n_cmds=0 rel cmd
  local probe_root="${probe_base}/rd probe root"   # 공백 포함 — 따옴표 처리까지 증명한다
  local marker_dir="${probe_base}/markers"
  mkdir -p "$probe_root" "$marker_dir"

  # bash 3.2 — mapfile 없음. 임시 파일로 인덱스 접근을 만든다.
  local paths_f="${probe_base}/p.$$" cmds_f="${probe_base}/c.$$"
  _hook_extract_paths "$settings" > "$paths_f"
  _hook_extract_commands "$settings" > "$cmds_f"
  n_paths="$(wc -l < "$paths_f" | tr -d '[:space:]')"
  n_cmds="$(wc -l < "$cmds_f" | tr -d '[:space:]')"

  if [[ "$n_paths" -eq 0 ]]; then
    echo "  $settings: hook 경로 추출 0건 (파싱 규약 확인 필요)" >&2
    return 1
  fi
  # 규약 P4 — 항목 수와 추출 수가 다르면 규약 밖 command 가 있다.
  local n_items; n_items="$(_hook_count_commands "$settings")"
  if [[ "$n_items" -ne "$n_paths" ]]; then
    echo "  $settings: bash command 항목 ${n_items}건 / 추출 ${n_paths}건 — 규약 밖 command 존재" >&2
    rc=1
  fi
  # 규약 P6 — 값이 다음 행으로 넘어간 항목은 계수·추출 양쪽에서 함께 누락되어 위 대조를 통과한다.
  # `"command"` 키 총수와 같은 행에서 값이 시작하는 수를 대조해 별도로 잡는다.
  local n_keys n_inline
  n_keys="$(_hook_count_command_keys "$settings")"
  n_inline="$(_hook_count_inline_values "$settings")"
  if [[ "$n_keys" -ne "$n_inline" ]]; then
    echo "  $settings: \"command\" 키 ${n_keys}건 / 같은 행에서 값 시작 ${n_inline}건 — 줄바꿈된 command 존재 (규약 P6)" >&2
    rc=1
  fi
  if [[ "$n_cmds" -ne "$n_paths" ]]; then
    echo "  $settings: command ${n_cmds}건 / 경로 ${n_paths}건 불일치" >&2
    return 1
  fi

  while [[ "$idx" -lt "$n_paths" ]]; do
    rel="$(sed -n "$((idx+1))p" "$paths_f")"
    cmd="$(sed -n "$((idx+1))p" "$cmds_f")"
    mkdir -p "${probe_root}/$(dirname "$rel")"
    printf '%s\n' '#!/usr/bin/env bash' \
      ': > "${RD_HOOK_PROBE_MARKER:?marker path required}"' 'exit 0' \
      > "${probe_root}/${rel}"

    _hook_probe_run "$settings" "$idx" inject   "$probe_root" "$marker_dir" "$cmd" || rc=1
    _hook_probe_run "$settings" "$idx" fallback "$probe_root" "$marker_dir" "$cmd" || rc=1
    idx=$((idx+1))
  done
  rm -f "$paths_f" "$cmds_f"
  return $rc
}

# 실행 전 marker 부재 확인 → 실행 → 그 실행이 marker 를 새로 만들었는지 확인.
# (설정 파일 × command × 케이스)마다 고유 marker 를 쓰므로 앞선 실행의 흔적을 성공으로 오판하지 않는다.
# $1=settings $2=idx $3=case $4=probe_root $5=marker_dir $6=cmd
_hook_probe_run() {
  local settings="$1" idx="$2" case_name="$3" probe_root="$4" marker_dir="$5" cmd="$6"
  local tag marker
  tag="$(printf '%s' "${settings}|${idx}|${case_name}" | tr -c 'A-Za-z0-9' '_')"
  marker="${marker_dir}/${tag}"

  if [[ -e "$marker" ]]; then
    echo "  $settings [#$idx/$case_name]: marker 사전 존재 — 검사 오염" >&2
    return 1
  fi

  # 중첩 전달 없이 subshell 에서 직접 실행한다 (§2.5.2-6).
  if [[ "$case_name" == "inject" ]]; then
    # 주입 케이스 — cwd 는 저장소 밖, CLAUDE_PROJECT_DIR 은 공백 포함 probe root
    ( cd / && CLAUDE_PROJECT_DIR="$probe_root" RD_HOOK_PROBE_MARKER="$marker" \
        sh -c "$cmd" ) </dev/null >/dev/null 2>&1
  else
    # 미주입 케이스 — 변수를 실제로 unset, cwd 는 probe root (현행 fallback 동등성)
    ( cd "$probe_root" && env -u CLAUDE_PROJECT_DIR RD_HOOK_PROBE_MARKER="$marker" \
        sh -c "$cmd" ) </dev/null >/dev/null 2>&1
  fi

  if [[ ! -f "$marker" ]]; then
    echo "  $settings [#$idx/$case_name]: 대상 미도달 — $cmd" >&2
    return 1
  fi
  return 0
}

# 추출한 상대 경로가 기준 root 아래 실재하는지 확인한다 (§2.5.3).
# lite override 는 대상이 아니다 — 설치 트리가 없어 기준 root 를 정할 수 없고,
# lite 산출물 기준 dangling 검사는 build_template.sh check_hook_registry 가 이미 수행한다.
hook_target_existence_check() {
  local rc=0 root settings base rel found
  root="$(_hook_repo_root)"
  for pair in "REQUIRED|${root}/.claude/settings.json|${root}" \
              "OPTIONAL|${root}/_ROOT_FILES/.claude/settings.json|${root}/_ROOT_FILES"; do
    local kind; kind="${pair%%|*}"
    settings="$(printf '%s' "$pair" | cut -d'|' -f2)"
    base="$(printf '%s' "$pair" | cut -d'|' -f3)"
    if [[ ! -f "$settings" ]]; then
      [[ "$kind" == "REQUIRED" ]] && { echo "  $settings: 필수 파일 부재" >&2; rc=1; }
      continue
    fi
    found=0
    while IFS= read -r rel; do
      found=$((found+1))
      [[ -f "${base}/${rel}" ]] || { echo "  $settings: 대상 부재 — ${base}/${rel}" >&2; rc=1; }
    done < <(_hook_extract_paths "$settings")
    [[ "$found" -gt 0 ]] || { echo "  $settings: 추출 0건" >&2; rc=1; }
  done
  return $rc
}

# 옛 상대 경로 표기가 되돌아오면 실패한다 (§2.5.4).
# .claude/settings.local.json 은 gitignore 대상 개인 override 라 존재할 때만 스캔한다.
hook_path_notation_regression_check() {
  local rc=0 kind settings hits root
  root="$(_hook_repo_root)"
  { _hook_settings_targets; echo "OPTIONAL ${root}/.claude/settings.local.json"; } \
  | while read -r kind settings; do
      if [[ ! -f "$settings" ]]; then
        [[ "$kind" == "REQUIRED" ]] && { echo "  $settings: 필수 파일 부재" >&2; exit 1; }
        continue
      fi
      hits="$(grep -c '"command"[[:space:]]*:[[:space:]]*"bash rd-workflow/' "$settings" || true)"
      if [[ "$hits" -ne 0 ]]; then
        echo "  $settings: 옛 상대 경로 표기 ${hits}건 잔존 — cwd 의존이라 hook 이 조용히 실패한다" >&2
        exit 1
      fi
    done
  rc=$?
  return $rc
}

# self_test 자신의 계약 검사 — checker 진입점 whitelist 와 root resolver 판정을 고정한다.
# (diff review Turn 002 Finding 3·4)
hook_selftest_contract_check() {
  local rc=0 self="${SCRIPT_DIR}/self_test.sh" fx out code

  # ① checker 진입점은 whitelist 밖 값을 거부해야 한다.
  #    허용하면 `RD_SELFTEST_CHECKER_ONLY=true` 로 전체 self-test 를 무출력 exit 0 으로 건너뛸 수 있다.
  RD_SELFTEST_CHECKER_ONLY=true bash "$self" >/dev/null 2>&1
  code=$?
  [[ "$code" -eq 2 ]] || { echo "  checker 진입점이 whitelist 밖 값을 거부하지 않음 (rc=$code, 기대 2)" >&2; rc=1; }

  # ② 허용값은 정상 동작해야 한다 (whitelist 가 과하게 좁지 않은지 확인).
  RD_SELFTEST_CHECKER_ONLY=_hook_repo_root bash "$self" >/dev/null 2>&1
  code=$?
  [[ "$code" -eq 0 ]] || { echo "  checker 진입점이 허용값(_hook_repo_root)을 거부함 (rc=$code)" >&2; rc=1; }

  # ③ 저장소 이름이 `_ROOT_FILES` 인 설치본을 정본으로 오인하지 않아야 한다.
  #    빌더(`scripts/build_template.sh`)가 없으므로 두 단계 위가 곧 저장소 root 다.
  fx="$(mktemp -d)"
  mkdir -p "${fx}/_ROOT_FILES/rd-workflow/scripts"
  cp "$self" "${fx}/_ROOT_FILES/rd-workflow/scripts/self_test.sh"
  out="$(RD_SELFTEST_CHECKER_ONLY=_hook_repo_root bash "${fx}/_ROOT_FILES/rd-workflow/scripts/self_test.sh" 2>/dev/null)"
  if [[ "$out" != "${fx}/_ROOT_FILES" ]]; then
    echo "  이름이 _ROOT_FILES 인 설치본 root 오판: got=[$out] want=[${fx}/_ROOT_FILES]" >&2
    rc=1
  fi
  rm -rf "$fx"

  # ④ 규약 P6 회귀 — 키와 콜론 사이가 줄바꿈된 command 를 배포본 checker 가 잡아야 한다.
  #    빌더 회귀(`scripts/test_build_template.sh` notation-h)는 배포본에 없으므로,
  #    같은 규약을 중복 구현하는 이쪽 사본의 판별력을 독립적으로 고정한다.
  #    (diff review Turn 006 Finding 1)
  _hook_p6_regression_fixture || rc=1

  # ⑤ 생성 트리 검사의 임시 root 가드 — `mktemp -d` 실패 시 빈 치환으로 `/full` 을 만들어
  #    저장소 밖에 빌드를 시도하면 안 된다 (diff review Turn 006 Finding 2).
  _generated_tree_mktemp_guard_fixture || rc=1

  # ⑥ ⑤ 의 fixture 자신도 같은 가드를 지켜야 한다 — 가드 없이 쓰면 `/scripts` 같은 루트
  #    절대 경로를 만든다 (Turn 008 Finding 2). 쓰기 0회를 fake `mkdir` 로 관찰한다.
  _fixture_own_mktemp_guard_probe || rc=1

  # ⑦ 정리 실패를 성공으로 감추지 않아야 한다 (Turn 008 Finding 3).
  _generated_tree_cleanup_failure_probe || rc=1

  # ⑧ 전용 테스트 스위트 자신의 임시 root 생성 실패도 fail-closed 여야 한다 — 가드가 없으면
  #    `/rd-workflow-workspace/...` 를 만든다 (Turn 010 Finding 1).
  _defect_test_workspace_guard_probe || rc=1

  return $rc
}

# ⑧ — `test_defect_reports.sh` 를 fake `mktemp`(-d 실패) + fake `mkdir`(로그 후 실패) 로 실행한다.
# 스위트 root 생성이 첫 `setup_workspace` 에서 일어나므로, 여기서 막히면 mkdir 로그가 빈다.
_defect_test_workspace_guard_probe() {
  local rc=0 t="${SCRIPT_DIR}/test_defect_reports.sh" fx code out real_mktemp
  [[ -f "$t" ]] || { echo "  test_defect_reports.sh 부재" >&2; return 1; }
  real_mktemp="$(command -v mktemp)"
  if ! fx="$(_mktemp_dir_or_empty)"; then
    echo "  probe 임시 디렉터리 생성 실패" >&2; return 1
  fi
  mkdir -p "${fx}/fakebin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "-d" ]]; then echo "mktemp: 주입된 실패" >&2; exit 1; fi' \
    "exec ${real_mktemp} \"\$@\"" > "${fx}/fakebin/mktemp"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$MKDIR_LOG"' 'exit 1' > "${fx}/fakebin/mkdir"
  chmod +x "${fx}/fakebin/mktemp" "${fx}/fakebin/mkdir"
  : > "${fx}/mkdir.log"

  out="$(MKDIR_LOG="${fx}/mkdir.log" PATH="${fx}/fakebin:$PATH" bash "$t" 2>&1)"
  code=$?
  [[ "$code" -ne 0 ]] || { echo "  전용 테스트가 임시 root 실패에도 통과함 (rc=0)" >&2; rc=1; }
  if [[ -s "${fx}/mkdir.log" ]]; then
    echo "  임시 root 실패에도 디렉터리를 만들려 함: $(head -3 "${fx}/mkdir.log" | tr '\n' ' ')" >&2; rc=1
  fi
  printf '%s' "$out" | grep -q '임시 디렉터리를 만들 수 없습니다' \
    || { echo "  임시 root 실패 진단 문구가 없음: [$out]" >&2; rc=1; }
  rm -rf "$fx"
  return $rc
}

# ⑥ — `_generated_tree_mktemp_guard_fixture` 를 추출해 자기 자신의 `mktemp -d` 실패를 주입한다.
# fake `mkdir` 는 호출되면 로그를 남기고 실패하므로 "루트 절대 경로 생성 0회" 가 파일로 관찰된다.
_fixture_own_mktemp_guard_probe() {
  local rc=0 self="${SCRIPT_DIR}/self_test.sh" fx code out real_mktemp
  real_mktemp="$(command -v mktemp)"
  if ! fx="$(_mktemp_dir_or_empty)"; then
    echo "  probe 임시 디렉터리 생성 실패" >&2; return 1
  fi
  mkdir -p "${fx}/fakebin"
  sed -n '/^_generated_tree_mktemp_guard_fixture() {/,/^}/p' "$self" >  "${fx}/fn.sh"
  sed -n '/^_mktemp_dir_or_empty() {/,/^}/p'                 "$self" >> "${fx}/fn.sh"
  if ! grep -q '^_generated_tree_mktemp_guard_fixture() {' "${fx}/fn.sh" \
     || ! grep -q '^_mktemp_dir_or_empty() {' "${fx}/fn.sh"; then
    echo "  fixture 함수 추출 실패 (이름이 바뀌었는지 확인)" >&2
    rm -rf "$fx"; return 1
  fi
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "-d" ]]; then echo "mktemp: 주입된 실패" >&2; exit 1; fi' \
    "exec ${real_mktemp} \"\$@\"" > "${fx}/fakebin/mktemp"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$MKDIR_LOG"' 'exit 1' > "${fx}/fakebin/mkdir"
  chmod +x "${fx}/fakebin/mktemp" "${fx}/fakebin/mkdir"
  : > "${fx}/mkdir.log"

  out="$(MKDIR_LOG="${fx}/mkdir.log" PATH="${fx}/fakebin:$PATH" \
        SCRIPT_DIR="${fx}/rd-workflow/scripts" \
        bash -c "source '${fx}/fn.sh'; _generated_tree_mktemp_guard_fixture" 2>&1)"
  code=$?
  [[ "$code" -ne 0 ]] || { echo "  fixture 가 자신의 mktemp 실패에도 통과함 (rc=0)" >&2; rc=1; }
  if [[ -s "${fx}/mkdir.log" ]]; then
    echo "  fixture 가 mktemp 실패에도 디렉터리를 만들려 함: $(cat "${fx}/mkdir.log")" >&2; rc=1
  fi
  printf '%s' "$out" | grep -q '임시 디렉터리 생성 실패' \
    || { echo "  fixture 실패 진단 문구가 없음: [$out]" >&2; rc=1; }
  rm -rf "$fx"
  return $rc
}

# ⑦ — 정리(`rm -rf`)만 실패시켜, 검사가 잔존 경로를 알리고 비영으로 끝나는지 본다.
# 추출한 함수 안의 `rm` 은 정리 지점 한 곳뿐이므로 fake `rm` 을 항상 실패로 두어도 안전하다.
_generated_tree_cleanup_failure_probe() {
  local rc=0 self="${SCRIPT_DIR}/self_test.sh" fx code out leaked
  if ! fx="$(_mktemp_dir_or_empty)"; then
    echo "  probe 임시 디렉터리 생성 실패" >&2; return 1
  fi
  # `rd-workflow/scripts` 도 실제로 만든다 — 빌더 경로가 `..` 를 거쳐 해석되므로
  # 이 디렉터리가 없으면 `[[ -f "$builder" ]]` 가 거짓이 되어 검사가 skip 으로 빠진다.
  mkdir -p "${fx}/fakebin" "${fx}/scripts" "${fx}/rd-workflow/scripts"
  sed -n '/^generated_tree_defect_reports_check() {/,/^}/p' "$self" >  "${fx}/fn.sh"
  sed -n '/^_generated_tree_probe() {/,/^}/p'               "$self" >> "${fx}/fn.sh"
  sed -n '/^_mktemp_dir_or_empty() {/,/^}/p'                "$self" >> "${fx}/fn.sh"
  # 빌드는 즉시 실패시킨다 — 여기서 관찰하려는 것은 정리 실패 보고이므로 빌드 성공이 필요 없다.
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "${fx}/scripts/build_template.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "rm: 주입된 실패" >&2' 'exit 1' > "${fx}/fakebin/rm"
  chmod +x "${fx}/scripts/build_template.sh" "${fx}/fakebin/rm"

  out="$(PATH="${fx}/fakebin:$PATH" SCRIPT_DIR="${fx}/rd-workflow/scripts" \
        bash -c "source '${fx}/fn.sh'; generated_tree_defect_reports_check" 2>&1)"
  code=$?
  [[ "$code" -ne 0 ]] || { echo "  정리 실패인데 검사가 통과함 (rc=0)" >&2; rc=1; }
  printf '%s' "$out" | grep -q '임시 트리 정리 실패' \
    || { echo "  정리 실패 진단 문구가 없음: [$out]" >&2; rc=1; }
  # 잔존 경로를 진단에 실어야 사람이 지울 수 있다 — 경로가 출력에 있는지 확인하고 정리한다.
  leaked="$(printf '%s' "$out" | sed -n 's/.*정리 실패 — 수동으로 지워야 합니다: //p' | head -1)"
  if [[ -n "$leaked" && -d "$leaked" ]]; then
    rm -rf "$leaked"
  else
    echo "  잔존 경로 진단이 없거나 경로가 아님: [$leaked]" >&2; rc=1
  fi
  rm -rf "$fx"
  return $rc
}

# 임시 디렉터리를 fail-closed 로 만든다. 성공하면 경로를 stdout 에, 실패하면 무출력 + 1.
#
# `d="$(mktemp -d)"` 를 검사 없이 쓰면 실패 시 빈 문자열이 남아 뒤따르는 `"${d}/x"` 가
# `/x` — **저장소 밖 절대 경로** — 가 된다. 임시 경로를 쓰는 모든 자리가 같은 함정을 가지므로
# 가드를 한 곳에 모아 호출부가 실수할 여지를 없앤다 (Turn 006 F2 · Turn 008 F2).
_mktemp_dir_or_empty() {
  local d
  d="$(mktemp -d)" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  printf '%s\n' "$d"
}

# ⑤ 전용 헬퍼 — `mktemp -d` 만 실패시키고, 검사가 **빌더를 호출하지 않고** FAIL 하는지 본다.
#
# **self_test 를 다시 실행하지 않는다.** `RD_SELFTEST_CHECKER_ONLY` 로 자기 자신을 띄우면
# 이 검사가 self_test 안에서 self_test 를 부르는 구조가 되어 재귀가 열린다 (실측: 프로세스
# 테이블 고갈). 그래서 함수 정의만 추출해 단일 bash 에서 격리 실행한다.
_generated_tree_mktemp_guard_fixture() {
  local rc=0 self="${SCRIPT_DIR}/self_test.sh" fx code out real_mktemp
  real_mktemp="$(command -v mktemp)"
  # fixture 자신도 fail-closed 다 — 가드 없이 쓰면 `mkdir -p "${fx}/scripts"` 가
  # `/scripts` 를 만들어, 이 fixture 가 검증하려는 결함을 스스로 재현한다
  # (Turn 008 Finding 2). `run_step` 의 `if "$@"` 문맥에서는 errexit 도 이를 막지 못한다.
  if ! fx="$(_mktemp_dir_or_empty)"; then
    echo "  fixture 임시 디렉터리 생성 실패 — 아무것도 만들지 않았습니다" >&2
    return 1
  fi
  mkdir -p "${fx}/rd-workflow/scripts" "${fx}/scripts" "${fx}/fakebin"

  # 검사 대상 함수 2개를 원본 텍스트에서 그대로 추출한다 (사본이 아니라 실물을 검증).
  sed -n '/^generated_tree_defect_reports_check() {/,/^}/p'  "$self" >  "${fx}/fn.sh"
  sed -n '/^_generated_tree_probe() {/,/^}/p'                "$self" >> "${fx}/fn.sh"
  if ! grep -q '^generated_tree_defect_reports_check() {' "${fx}/fn.sh" \
     || ! grep -q '^_generated_tree_probe() {' "${fx}/fn.sh"; then
    echo "  생성 트리 검사 함수 추출 실패 (이름이 바뀌었는지 확인)" >&2
    rm -rf "$fx"; return 1
  fi

  # 호출되면 로그를 남기는 fake 빌더 — "호출 0회" 가 파일로 관찰된다.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$BUILDER_LOG"' \
    > "${fx}/scripts/build_template.sh"
  chmod +x "${fx}/scripts/build_template.sh"
  # `mktemp -d` 만 실패시킨다. 다른 형태는 real 로 넘겨 부수효과를 만들지 않는다.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "-d" ]]; then echo "mktemp: 주입된 실패" >&2; exit 1; fi' \
    "exec ${real_mktemp} \"\$@\"" > "${fx}/fakebin/mktemp"
  chmod +x "${fx}/fakebin/mktemp"
  : > "${fx}/builder.log"

  out="$(BUILDER_LOG="${fx}/builder.log" PATH="${fx}/fakebin:$PATH" \
        SCRIPT_DIR="${fx}/rd-workflow/scripts" \
        bash -c "source '${fx}/fn.sh'; generated_tree_defect_reports_check" 2>&1)"
  code=$?

  [[ "$code" -ne 0 ]] || { echo "  mktemp -d 실패인데 생성 트리 검사가 통과함 (rc=0)" >&2; rc=1; }
  if [[ -s "${fx}/builder.log" ]]; then
    echo "  mktemp -d 실패에도 빌더를 호출함: $(cat "${fx}/builder.log")" >&2; rc=1
  fi
  printf '%s' "$out" | grep -q '임시 디렉터리 생성 실패' \
    || { echo "  mktemp -d 실패 진단 문구가 없음: [$out]" >&2; rc=1; }
  rm -rf "$fx"
  return $rc
}

# ④ 전용 헬퍼 — 임시 설치본을 세우고 현재 구현과 변형(행 단위 계수) 구현의 판정을 대조한다.
_hook_p6_regression_fixture() {
  local rc=0 self="${SCRIPT_DIR}/self_test.sh" fx code out ln
  fx="$(mktemp -d)"
  mkdir -p "${fx}/.claude" "${fx}/rd-workflow/scripts/hooks"
  cp "$self" "${fx}/rd-workflow/scripts/self_test.sh"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/hooks/keep.sh"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/hooks/other.sh"

  # 정상 한 줄 항목 1개 + `"command"` 와 콜론이 분리된 항목 1개 (유효 JSON).
  cat > "${fx}/.claude/settings.json" <<'P6EOF'
{
  "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/keep.sh" },
    { "type": "command",
      "command"
        : "bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/other.sh" }
  ] } ] }
}
P6EOF

  # 현재 구현: 검출해야 한다 (비영 종료 + 규약 P6 진단).
  out="$(RD_SELFTEST_CHECKER_ONLY=hook_path_reachability_check \
        bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if [[ "$code" -eq 0 ]]; then
    echo "  P6 회귀: 키/콜론 줄바꿈을 검출하지 못함 (rc=0)" >&2; rc=1
  elif ! printf '%s' "$out" | grep -q '규약 P6'; then
    echo "  P6 회귀: 비영 종료했으나 규약 P6 진단이 없음" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    rc=1
  fi

  # 변형(행 단위 계수)으로 되돌린 사본: 통과해 버려야 한다 — 위 검출의 판별력 증명.
  ln="$(grep -n '^_hook_count_command_keys() {' "${fx}/rd-workflow/scripts/self_test.sh" | cut -d: -f1)"
  if [[ -z "$ln" ]]; then
    echo "  P6 회귀: 변형 대상 함수를 찾지 못함 (_hook_count_command_keys)" >&2; rc=1
  else
    # 대체 줄은 quoted heredoc 으로 둔다 — awk -v / sed 는 백슬래시를 재해석해 패턴을 망가뜨린다.
    cat > "${fx}/repl.txt" <<'P6RPL'
  { grep -o '"command"[[:space:]]*:' "$1" || true; } | wc -l | tr -d '[:space:]'
P6RPL
    {
      head -n "$ln" "${fx}/rd-workflow/scripts/self_test.sh"
      cat "${fx}/repl.txt"
      tail -n "+$((ln + 2))" "${fx}/rd-workflow/scripts/self_test.sh"
    } > "${fx}/mutated.sh"
    cp "${fx}/mutated.sh" "${fx}/rd-workflow/scripts/self_test.sh"
    RD_SELFTEST_CHECKER_ONLY=hook_path_reachability_check \
      bash "${fx}/rd-workflow/scripts/self_test.sh" >/dev/null 2>&1
    code=$?
    if [[ "$code" -ne 0 ]]; then
      echo "  P6 회귀: 변형 사본도 실패해 판별력을 증명하지 못함 (rc=$code)" >&2
      echo "  (행 단위 계수에서는 통과해야 이 fixture 가 P6 대조를 겨냥한다는 뜻이다)" >&2
      rc=1
    fi
  fi

  rm -rf "$fx"
  return $rc
}

# checker 단독 실행 진입점 — 역검증이 개별 checker 의 반환값을 격리 확인할 때 쓴다.
# 예: RD_SELFTEST_CHECKER_ONLY=hook_path_reachability_check bash rd-workflow/scripts/self_test.sh
#
# **whitelist 필수**: 임의 명령을 허용하면 `RD_SELFTEST_CHECKER_ONLY=true` 같은 값으로 전체 self-test 를
# 무출력 exit 0 으로 건너뛸 수 있다. 환경변수가 남아 있거나 외부에서 잘못 주입되면 사용자는 전체 검사가
# 통과한 것으로 오인한다. 안전장치 스크립트에서 이 우회 경로는 허용하지 않는다.
if [[ -n "${RD_SELFTEST_CHECKER_ONLY:-}" ]]; then
  case "$RD_SELFTEST_CHECKER_ONLY" in
    hook_path_reachability_check|hook_target_existence_check|hook_path_notation_regression_check) ;;
    hook_selftest_contract_check|_hook_repo_root) ;;
    *)
      echo "[self_test] RD_SELFTEST_CHECKER_ONLY 허용값이 아닙니다: ${RD_SELFTEST_CHECKER_ONLY}" >&2
      echo "  허용: hook_path_reachability_check | hook_target_existence_check | hook_path_notation_regression_check | hook_selftest_contract_check | _hook_repo_root" >&2
      exit 2
      ;;
  esac
  # 모드 표시는 stderr 로 보낸다 — `_hook_repo_root` 처럼 stdout 을 값으로 쓰는 대상의 출력을 오염시키지 않기 위해서다.
  echo "== self_test: checker-only 모드 — ${RD_SELFTEST_CHECKER_ONLY} (전체 검사는 실행하지 않습니다) ==" >&2
  # errexit 를 끄고 호출한다. checker 는 내부 실패를 rc 로 모아 반환하는 구조인데, `set -e` 하에서
  # 바로 호출하면 첫 실패 하위 명령에서 그 종료 코드로 스크립트가 즉시 죽어 checker 의 반환값과
  # 진단 출력이 사라진다. 전체 실행 경로(`run_step` 의 `if "$@"`)는 이미 errexit 가 유예된 문맥이므로,
  # 이 진입점도 같은 문맥으로 맞춘다.
  set +e
  "$RD_SELFTEST_CHECKER_ONLY"
  exit $?
fi

run_step "stop_task_save_reminder hook" bash "${SCRIPT_DIR}/hooks/test_stop_task_save_reminder.sh"
run_step "implementation_gate hook (test_implementation_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_implementation_gate.sh"
run_step "edit_provenance producer hook" bash "${SCRIPT_DIR}/hooks/test_edit_provenance_record.sh"
run_step "리뷰 프롬프트 인라인 계약 (test_review_prompt_inline.sh)" bash "${SCRIPT_DIR}/test_review_prompt_inline.sh"
run_step "reasoning effort override (test_review_effort_override.sh)" bash "${SCRIPT_DIR}/test_review_effort_override.sh"
run_step "리뷰 턴 계측 계약 (test_review_metrics.sh)" bash "${SCRIPT_DIR}/test_review_metrics.sh"
run_step "어댑터 프롬프트 parity (test_review_adapter_parity.sh)" bash "${SCRIPT_DIR}/test_review_adapter_parity.sh"
run_step "state 단위 테스트 (test_state_common.sh)" bash "${SCRIPT_DIR}/test_state_common.sh"
run_step "guard state fixture (test_guard_state.sh)" bash "${SCRIPT_DIR}/hooks/test_guard_state.sh"
run_step "archive gate 테스트 (test_pre_commit_archive_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_pre_commit_archive_gate.sh"
run_step "fr_branch_gate 테스트 (test_fr_branch_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_fr_branch_gate.sh"
run_step "review gate 테스트 (test_pre_commit_review_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_pre_commit_review_gate.sh"
run_step "비차단 Status drift 검증 (nonblocking_status_drift_check)" nonblocking_status_drift_check
run_step "LC-19 3자 일치 검증 (TASK/STATE/CLAUDE.md)" canonical_status_triple_drift_check
run_step "판정 소스 회귀 grep (_extract_task_section Status 직접 호출)" judgment_source_regression_check
run_step "stale active-fr/LIFECYCLE_METADATA_PATH 참조 회귀" stale_metadata_reference_check
run_step "task CLI 단위 테스트" bash "${SCRIPT_DIR}/test_task_cli.sh"
run_step "install_claude_skills 단위 테스트" bash "${SCRIPT_DIR}/test_install_claude_skills.sh"
run_step "lifecycle 단위 테스트 (test_lifecycle.sh)" bash "${SCRIPT_DIR}/lifecycle/test_lifecycle.sh"
run_step "lifecycle 통합 테스트 (test_integration.sh)" bash "${SCRIPT_DIR}/lifecycle/test_integration.sh"
run_step "review 대기 계약 테스트 (test_review_wait.sh)" bash "${SCRIPT_DIR}/test_review_wait.sh"
run_step "watchdog 계약·이식성 probe (test_watchdog_portability.sh)" bash "${SCRIPT_DIR}/test_watchdog_portability.sh"
run_step "ralph_drain supervisor 테스트 (test_ralph_drain.sh)" bash "${SCRIPT_DIR}/test_ralph_drain.sh"
run_step "batch_manifest 헬퍼 테스트 (batch/test_batch_manifest.sh)" bash "${SCRIPT_DIR}/batch/test_batch_manifest.sh"
run_step "blocked status 어휘 일관성 (test_fr_blocked_status.sh)" bash "${SCRIPT_DIR}/test_fr_blocked_status.sh"
run_step "autopilot blocked 계약 회귀 (test_autopilot_blocked_contract.sh)" bash "${SCRIPT_DIR}/test_autopilot_blocked_contract.sh"
run_step "sync_template 타입 가드 테스트 (test_sync_template.sh)" bash "${SCRIPT_DIR}/test_sync_template.sh"
# 결함 보고 로컬 조작부. 다른 배포 테스트와 같은 관례로 **배포 사본**을 실행한다 —
# 테스트가 형제 `defect_reports.sh` 를 대상으로 잡으므로 이 한 줄이 곧 설치본 구현 검증이다.
# 정본/배포본 drift 는 dev repo 전용 `build_verify_check`(build_template.sh verify)가 이미
# 트리 전체에 대해 잡는다 — 여기서 `_ROOT_FILES` 를 다시 참조하면 설치본에서 항상 실패한다
# (final diff review Turn 004 Finding 1).
#
# 격리 `TMPDIR` 에서 돌려 **임시 디렉터리 증분 0** 까지 함께 판정한다. 이 스위트는 케이스가
# 많아(48개 workspace) 누수가 쌓이면 self-test 를 돌릴수록 디스크를 먹는다 (Turn 010 Finding 2).
defect_reports_test_check() {
  local t="${SCRIPT_DIR}/test_defect_reports.sh" tmproot rc=0 left
  if ! tmproot="$(_mktemp_dir_or_empty)"; then
    printf '  FAIL 임시 디렉터리 생성 실패 — 테스트를 실행하지 않았습니다\n'; return 1
  fi
  TMPDIR="$tmproot" bash "$t" || rc=1
  left="$(ls -A "$tmproot" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$left" != "0" ]]; then
    printf '  FAIL 전용 테스트가 임시 디렉터리를 %s건 남겼습니다: %s\n' "$left" "$tmproot"; rc=1
  else
    printf '  ok   임시 디렉터리 증분 0\n'
  fi
  if ! rm -rf "$tmproot" || [[ -e "$tmproot" ]]; then
    printf '  FAIL 격리 TMPDIR 정리 실패 — 수동으로 지워야 합니다: %s\n' "$tmproot"; rc=1
  fi
  return $rc
}
run_step "결함 보고 로컬 조작부 테스트 (test_defect_reports.sh)" defect_reports_test_check
pre_commit_verify_test_check() {
  local t="${SCRIPT_DIR}/hooks/test_pre_commit_verify.sh"
  if [[ -f "$t" ]]; then bash "$t"; else echo "  (skip: test_pre_commit_verify.sh 없음 — lite 산출물)"; fi
}
run_step "pre_commit_verify 테스트 (test_pre_commit_verify.sh)" pre_commit_verify_test_check
run_step "adapter 폴링 잔존 회귀 (POLL_INTERVAL 없음)" adapter_poll_regression_check
run_step "스크립트 구문 검사 (bash -n)" syntax_check
run_step "autopilot SKILL lifecycle 정합 (promote/rollback 일원화)" autopilot_skill_lifecycle_check
run_step "무인 진입 계약 정합 (autopilot_headless_entry_check)" autopilot_headless_entry_check
run_step "무인 wrapper 매핑 테스트 (test_autopilot_headless.sh)" bash "${SCRIPT_DIR}/test_autopilot_headless.sh"
run_step "phase 병렬 규약 문서 정합 (plan_parallel_phase_check)" plan_parallel_phase_check

# =============================================================================
# 편집 출처(edit provenance) 진단 — change spec §2.10 의 D1~D7
#
# producer hook 은 "항상 exit 0 · 무출력" 계약이라, 배경 동작이 조용히 종전 넛지로
# 강등돼도 사용자가 알 방법이 없습니다. 그 이유를 확인할 수 있는 유일한 창구가 이 진단입니다.
#
# 심각도 규약 (spec §2.10 과 번호·명칭·문구·skip 규칙이 정확히 일치해야 합니다):
#   D1        → **실패(FAIL)**. 검사 항목 수가 0이어도 실패입니다
#                (활성 FR self-test-required-copy-check-consistency 의 거짓 통과 패턴 금지).
#   D2~D5·D7  → 경고(warn). self-test 를 실패시키지 않습니다.
#   D6        → **경고하지 않습니다.** 런타임 무삭제가 계약이므로 세대 누적은 정상 상태이고
#               개수는 정리 실패 신호가 아닙니다. 개수만 정보로 표시합니다.
#   provenance 디렉토리 부재는 정상 상태이므로 D3·D4·D6·D7 은 skip 입니다 (경고 아님).
# =============================================================================

_ep_diag_ok()   { printf '  ok   %s\n' "$1"; }
_ep_diag_warn() { printf '  warn %s\n' "$1"; }
_ep_diag_skip() { printf '  skip %s\n' "$1"; }
_ep_diag_fail() { printf '  FAIL %s\n' "$1" >&2; }

# 공용 헬퍼 적재. ep_* 함수와 short-title 조회(state_read_field)를 이 셸에 들입니다.
# project_root 는 ep_root 가 기본 루트를 조립할 때 씁니다 (RD_EDIT_PROVENANCE_DIR 이 우선).
_ep_diag_load() {
  [[ -f "${SCRIPT_DIR}/_edit_provenance_common.sh" ]] || return 1
  project_root="$(_hook_repo_root)"
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/_edit_provenance_common.sh"
  if [[ -f "${SCRIPT_DIR}/_state_common.sh" ]]; then
    # shellcheck source=/dev/null
    . "${SCRIPT_DIR}/_state_common.sh"
  fi
  return 0
}

_ep_diag_short_title() {
  if declare -f state_read_field >/dev/null 2>&1; then
    state_read_field "short-title"
  fi
}

# --- D1: 공용 헬퍼·producer hook 이 정본·배포 사본 양쪽에 존재 ------------------
# 배포 사본은 무조건 필수입니다. 정본(_ROOT_FILES/)은 설치본에 없는 것이 정상이므로
# 정본 트리가 있을 때만 목록에 넣되, 넣었으면 그때는 필수로 다룹니다.
# `[[ -f ]] || continue` 로 대상을 흘려보내면 대상이 통째로 사라져도 0건 검사로 통과합니다.
_ep_d1_targets() {
  local root; root="$(_hook_repo_root)"
  printf '%s\n' "${root}/rd-workflow/scripts/_edit_provenance_common.sh"
  printf '%s\n' "${root}/rd-workflow/scripts/hooks/edit_provenance_record.sh"
  if [[ -d "${root}/_ROOT_FILES/rd-workflow/scripts" ]]; then
    printf '%s\n' "${root}/_ROOT_FILES/rd-workflow/scripts/_edit_provenance_common.sh"
    printf '%s\n' "${root}/_ROOT_FILES/rd-workflow/scripts/hooks/edit_provenance_record.sh"
  fi
}

_ep_diag_d1() {  # $1=대상 목록 함수 이름 (기본 _ep_d1_targets — 분기 테스트가 교체한다)
  local fn="${1:-_ep_d1_targets}" rc=0 n=0 p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    n=$((n + 1))
    [[ -f "$p" ]] || { _ep_diag_fail "D1 파일 부재: $p"; rc=1; }
  done < <("$fn")
  if [[ "$n" -eq 0 ]]; then
    _ep_diag_fail "D1 검사 항목 0건 — 대상 목록이 비었습니다 (0건 검사는 거짓 통과입니다)"
    return 1
  fi
  [[ "$rc" -eq 0 ]] && _ep_diag_ok "D1 공용 헬퍼·producer hook 정본·배포 사본 존재 (${n}건)"
  return $rc
}

# --- D2: provenance 루트 생성·쓰기 가능 (실제 probe 후 정리) -------------------
# 우리가 만든 것만 되돌립니다 — 이미 있던 루트는 지우지 않습니다.
_ep_diag_d2() {
  local root probe created=0
  root="$(ep_root)"
  if [[ ! -d "$root" ]]; then
    if ! mkdir -p "$root" 2>/dev/null; then
      _ep_diag_warn "D2 provenance 루트를 만들 수 없습니다: ${root} (사유: mkdir 실패 — 편집 기록이 남지 않아 넛지가 기존 동작으로 동작합니다)"
      return 0
    fi
    created=1
  fi
  probe="${root}/.d2-probe.$$"
  if ! printf 'probe\n' > "$probe" 2>/dev/null; then
    _ep_diag_warn "D2 provenance 루트에 쓸 수 없습니다: ${root} (사유: 쓰기 실패 — 편집 기록이 남지 않아 넛지가 기존 동작으로 동작합니다)"
    rm -f "$probe" 2>/dev/null || true
    [[ "$created" -eq 1 ]] && { rmdir "$root" 2>/dev/null || true; }
    return 0
  fi
  rm -f "$probe" 2>/dev/null || true
  [[ "$created" -eq 1 ]] && { rmdir "$root" 2>/dev/null || true; }
  _ep_diag_ok "D2 provenance 루트 생성·쓰기 가능 (${root})"
  return 0
}

# --- D3: .current 포인터 — 존재·형식·지정 디렉토리 존재 -----------------------
# 통과 판정의 권위는 ep_current_gen 이고, 아래 raw 조회는 사유 문구 조립에만 씁니다.
_ep_diag_d3() {
  local root ptr first reason
  root="$(ep_root)"
  [[ -d "$root" ]] || { _ep_diag_skip "D3 provenance 디렉토리 없음 — 정상 상태입니다"; return 0; }
  ptr="${root}/.current"
  if ep_current_gen >/dev/null 2>&1; then
    _ep_diag_ok "D3 현재 세대 포인터 유효 ($(ep_current_gen))"
    return 0
  fi
  if [[ ! -f "$ptr" ]]; then
    reason=".current 부재"
  else
    first=""
    IFS= read -r first < "$ptr" 2>/dev/null || true
    if [[ -z "$first" ]]; then
      reason=".current 가 비었습니다"
    elif [[ ! -d "${root}/${first}" ]]; then
      reason="지정 세대 디렉토리 부재 (${first})"
    else
      reason=".current 내용 형식 불일치"
    fi
  fi
  _ep_diag_warn "D3 현재 세대 포인터가 유효하지 않아 판정이 기존 동작으로 동작합니다. 다음 진행 상태 저장에서 복구됩니다 (사유: ${reason})"
  return 0
}

# --- D4: 현재 세대 메타 — short-title 일치·센티널 부재·레코드 malformed 없음 ----
_ep_diag_d4() {
  local root gen title f n_rec=0 bad=0
  root="$(ep_root)"
  [[ -d "$root" ]] || { _ep_diag_skip "D4 provenance 디렉토리 없음 — 정상 상태입니다"; return 0; }
  if ! gen="$(ep_current_gen 2>/dev/null)"; then
    _ep_diag_skip "D4 현재 세대 없음 — D3 사유를 참조하십시오"
    return 0
  fi
  if ep_gen_has_sentinel "$gen"; then
    _ep_diag_warn "D4 이 세대는 기록을 중단했고 판정은 기존 동작으로 동작합니다. 다음 진행 상태 저장에서 복구됩니다"
    return 0
  fi
  title="$(_ep_diag_short_title)"
  if ! ep_gen_valid "$gen" "$title"; then
    _ep_diag_warn "D4 현재 세대의 short-title 이 진행 상태(${title:--})와 달라 세대가 무효입니다. 판정이 기존 동작으로 동작합니다. 다음 진행 상태 저장에서 복구됩니다"
    return 0
  fi
  # 형식 판정은 판정 경로(ep_read_record)와 **같은 함수**를 씁니다 — 규칙이 갈리면 진단이
  # "정상" 이라고 말하는 레코드를 판정은 malformed 로 보거나 그 반대가 됩니다 (턴 004 P1).
  for f in "${gen}"/*.orc "${gen}"/*.sub; do
    [[ -f "$f" ]] || continue
    n_rec=$((n_rec + 1))
    _ep_read_record_file "$f" || bad=$((bad + 1))
  done
  if [[ "$bad" -gt 0 ]]; then
    _ep_diag_warn "D4 현재 세대 레코드 ${n_rec}건 중 ${bad}건이 malformed 입니다 — 그 경로는 미설명으로 판정되어 넛지가 계속 뜹니다. 다음 진행 상태 저장에서 복구됩니다"
    return 0
  fi
  _ep_diag_ok "D4 현재 세대 메타 정상 (레코드 ${n_rec}건)"
  return 0
}

# --- D5: 검증 capability (jq 유무와 그때의 T23 범위) --------------------------
# jq 가 없어도 행위자 판별(read_hook_agent_id)과 상태 식별자(cksum)는 동작합니다.
# 즉 기록과 넛지 억제는 정상이고, 잃는 것은 T23 귀속 교차 검증뿐입니다.
_ep_diag_d5() {
  if command -v jq >/dev/null 2>&1; then
    _ep_diag_ok "D5 jq 가용 — T23 귀속 교차 검증 동작"
  else
    _ep_diag_warn "D5 jq 부재 — T23 귀속 교차 검증만 생략됩니다. 기록 기반 넛지 억제는 계속 동작합니다"
  fi
  return 0
}

# --- D6: 잔존 세대 수 (정보 표시 전용 — 경고하지 않습니다) --------------------
_ep_diag_d6() {
  local root d n=0 msg
  root="$(ep_root)"
  [[ -d "$root" ]] || { _ep_diag_skip "D6 provenance 디렉토리 없음 — 정상 상태입니다"; return 0; }
  for d in "${root}"/gen-*; do
    [[ -d "$d" ]] && n=$((n + 1))
  done
  msg="$(printf 'D6 세대 %s개 (작업 종료 시 `archive.sh` 가 일괄 회수합니다)' "$n")"
  _ep_diag_ok "$msg"
  return 0
}

# --- D7: 직전 bump 실패 흔적 (.bump-failed, spec §2.12 ③) ---------------------
_ep_diag_d7() {
  local root mark stage="" msg
  root="$(ep_root)"
  [[ -d "$root" ]] || { _ep_diag_skip "D7 provenance 디렉토리 없음 — 정상 상태입니다"; return 0; }
  mark="${root}/.bump-failed"
  if [[ ! -f "$mark" ]]; then
    _ep_diag_ok "D7 직전 bump 실패 흔적 없음"
    return 0
  fi
  IFS= read -r stage < "$mark" 2>/dev/null || true
  msg="$(printf 'D7 직전 진행 상태 저장에서 편집 기록 세대 갱신이 실패했습니다(지점: `%s`). 저장 자체는 반영됐지만 다음 저장까지 넛지가 계속 뜰 수 있습니다. 다음 진행 상태 저장에서 복구됩니다' "$stage")"
  _ep_diag_warn "$msg"
  return 0
}

edit_provenance_diagnostics_check() {
  local rc=0
  if ! _ep_diag_load; then
    _ep_diag_fail "편집 출처 공용 헬퍼를 불러올 수 없습니다: ${SCRIPT_DIR}/_edit_provenance_common.sh"
    return 1
  fi
  _ep_diag_d1 || rc=1
  _ep_diag_d2
  _ep_diag_d3
  _ep_diag_d4
  _ep_diag_d5
  _ep_diag_d6
  _ep_diag_d7
  return $rc
}

# ---- D1~D7 분기 테스트 ------------------------------------------------------
# 각 항목의 정상·이상 분기를 fixture 로 결정적으로 재현합니다.
# 격리는 RD_EDIT_PROVENANCE_DIR(헬퍼가 문서화한 테스트 훅) · TASK_STATE_PATH · PATH 로만 하고,
# 권한 조작(chmod)은 쓰지 않습니다 — root·elevated 환경에서 비결정적입니다.

_ep_t_pass() { printf '  ok   %s\n' "$1"; }
_ep_t_fail() { printf '  FAIL %s\n' "$1" >&2; }
_ep_t_has() {  # <label> <출력> <기대 문구>
  case "$2" in
    *"$3"*) _ep_t_pass "$1"; return 0 ;;
  esac
  _ep_t_fail "$1 — 기대 문구 없음: [$3]"
  printf '    실제: %s\n' "$2" >&2
  return 1
}
_ep_t_hasnt() {  # <label> <출력> <있으면 안 되는 문구>
  case "$2" in
    *"$3"*)
      _ep_t_fail "$1 — 있으면 안 되는 문구: [$3]"
      printf '    실제: %s\n' "$2" >&2
      return 1 ;;
  esac
  _ep_t_pass "$1"
  return 0
}

# D1 분기 테스트용 대상 목록입니다 (dynamic scope 로 _EP_T_BASE 를 봅니다).
_ep_d1_t_empty()   { :; }
_ep_d1_t_ok()      { printf '%s\n' "${_EP_T_BASE:-}/a.sh" "${_EP_T_BASE:-}/b.sh"; }
_ep_d1_t_missing() { printf '%s\n' "${_EP_T_BASE:-}/a.sh" "${_EP_T_BASE:-}/gone.sh"; }

# 정본 spec 이 있으면 D3·D4·D5·D6·D7 문구를 spec 원문과 대조합니다.
# spec·plan·테스트 세 곳이 같은 문구를 공유해야 하므로, 문구 drift 를 여기서 잡습니다.
# 배포본에는 spec 이 없으므로 그때는 skip 합니다 (필수로 두면 설치본에서 항상 실패합니다).
_ep_t_spec_phrases() {
  local rc=0 root spec p
  root="$(_hook_repo_root)"
  spec=""
  for p in "${root}/rd-workflow-workspace/specs/changes/"*stop-hook-stale-nudge-during-parallel-phase-change-spec.md; do
    [[ -f "$p" ]] && spec="$p"
  done
  if [[ -z "$spec" ]]; then
    printf '  skip spec 문구 대조 (change spec 없음 — 배포본)\n'
    return 0
  fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    grep -qF -- "$p" "$spec" || { _ep_t_fail "spec §2.10 문구 불일치: [$p]"; rc=1; }
  done <<'EOF'
현재 세대 포인터가 유효하지 않아 판정이 기존 동작으로 동작합니다. 다음 진행 상태 저장에서 복구됩니다
이 세대는 기록을 중단했고 판정은 기존 동작으로 동작합니다. 다음 진행 상태 저장에서 복구됩니다
T23 귀속 교차 검증만 생략됩니다. 기록 기반 넛지 억제는 계속 동작합니다
(작업 종료 시 `archive.sh` 가 일괄 회수합니다)
직전 진행 상태 저장에서 편집 기록 세대 갱신이 실패했습니다(지점:
저장 자체는 반영됐지만 다음 저장까지 넛지가 계속 뜰 수 있습니다. 다음 진행 상태 저장에서 복구됩니다
EOF
  [[ "$rc" -eq 0 ]] && _ep_t_pass "spec §2.10 문구 대조 (D3·D4·D5·D6·D7)"
  return $rc
}

edit_provenance_diagnostics_selftest() {
  local rc=0 base out r _EP_T_BASE
  if ! _ep_diag_load; then
    _ep_diag_fail "편집 출처 공용 헬퍼 부재 — 진단 분기 테스트를 실행할 수 없습니다"
    return 1
  fi
  if ! base="$(_mktemp_dir_or_empty)"; then
    _ep_diag_fail "진단 분기 테스트 임시 디렉터리 생성 실패 — 아무것도 만들지 않았습니다"
    return 1
  fi

  _ep_t_spec_phrases || rc=1

  # ---- D1 ----
  _EP_T_BASE="${base}/d1"
  mkdir -p "$_EP_T_BASE"
  : > "${_EP_T_BASE}/a.sh"; : > "${_EP_T_BASE}/b.sh"
  out="$(_ep_diag_d1 _ep_d1_t_ok 2>&1)" && : || rc=1
  _ep_t_has "D1 정상: 양쪽 존재 → 통과" "$out" "D1 공용 헬퍼·producer hook 정본·배포 사본 존재 (2건)" || rc=1
  if out="$(_ep_diag_d1 _ep_d1_t_missing 2>&1)"; then
    _ep_t_fail "D1 이상1: 배포 사본 삭제인데 통과함 (rc=0)"; rc=1
  else
    _ep_t_has "D1 이상1: 사본 부재 → 실패" "$out" "D1 파일 부재" || rc=1
  fi
  if out="$(_ep_diag_d1 _ep_d1_t_empty 2>&1)"; then
    _ep_t_fail "D1 이상2: 검사 0건인데 통과함 (rc=0) — 거짓 통과 패턴"; rc=1
  else
    _ep_t_has "D1 이상2: 검사 0건 → 실패" "$out" "D1 검사 항목 0건" || rc=1
  fi

  # ---- D2 ----
  r="${base}/d2-ok/edit-provenance.d"
  mkdir -p "${base}/d2-ok"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d2 2>&1)"
  _ep_t_has "D2 정상: 쓰기 가능 → 통과" "$out" "D2 provenance 루트 생성·쓰기 가능" || rc=1
  [[ ! -e "$r" ]] && _ep_t_pass "D2 정상: probe 후 정리 (만든 루트를 되돌림)" \
    || { _ep_t_fail "D2 정상: probe 흔적 잔존 — $r"; rc=1; }
  # 이상: 루트 경로 자리에 일반 파일을 놓아 mkdir 을 ENOTDIR 로 실패시킵니다 (권한 비의존).
  r="${base}/d2-bad/edit-provenance.d"
  mkdir -p "${base}/d2-bad"; : > "$r"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d2 2>&1)"
  _ep_t_has "D2 이상: ENOTDIR → 경고 + 사유" "$out" "D2 provenance 루트를 만들 수 없습니다" || rc=1
  _ep_t_has "D2 이상: 사유 표시" "$out" "사유: mkdir 실패" || rc=1

  # ---- D3 ----
  r="${base}/d3-ok"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d3 2>&1)"
  _ep_t_has "D3 정상: 실재 세대 지시 → 통과" "$out" "D3 현재 세대 포인터 유효" || rc=1
  r="${base}/d3-none"; mkdir -p "${r}/gen-1"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d3 2>&1)"
  _ep_t_has "D3 이상1: 포인터 부재 → 경고" "$out" "D3 현재 세대 포인터가 유효하지 않아 판정이 기존 동작으로 동작합니다. 다음 진행 상태 저장에서 복구됩니다" || rc=1
  _ep_t_has "D3 이상1: 사유 표시" "$out" "사유: .current 부재" || rc=1
  r="${base}/d3-dangling"; mkdir -p "$r"; printf 'gen-9\n' > "${r}/.current"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d3 2>&1)"
  _ep_t_has "D3 이상2: dangling → 경고" "$out" "사유: 지정 세대 디렉토리 부재 (gen-9)" || rc=1
  r="${base}/d3-malformed"; mkdir -p "${r}/gen-1"; printf 'gen-1\n추가 줄\n' > "${r}/.current"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d3 2>&1)"
  _ep_t_has "D3 이상3: malformed → 경고" "$out" "사유: .current 내용 형식 불일치" || rc=1
  # 이상4 (final diff review 턴 006 P1) — 추가 **빈 줄**. 종전에는 command substitution 이
  # 종단 LF 를 전부 지워 유효 포인터로 통과했고, D3 도 판정과 같이 "정상" 이라 보고했습니다.
  r="${base}/d3-extra-lf"; mkdir -p "${r}/gen-1"; printf 'gen-1\n\n' > "${r}/.current"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d3 2>&1)"
  _ep_t_has "D3 이상4: 추가 LF → 경고" "$out" "사유: .current 내용 형식 불일치" || rc=1
  # 정상 경계 — 종단 LF 가 없는 포인터는 손상이 아니므로 통과해야 합니다.
  r="${base}/d3-no-lf"; mkdir -p "${r}/gen-1"; printf 'gen-1' > "${r}/.current"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d3 2>&1)"
  _ep_t_has "D3 정상2: 종단 LF 없는 포인터 → 통과" "$out" "D3 현재 세대 포인터 유효" || rc=1
  # provenance 디렉토리 부재는 정상이므로 skip 이어야 합니다 (경고 아님).
  out="$(RD_EDIT_PROVENANCE_DIR="${base}/no-such-root"; _ep_diag_d3 2>&1)"
  _ep_t_has "D3 디렉토리 부재 → skip" "$out" "skip D3 provenance 디렉토리 없음" || rc=1

  # ---- D4 ----
  printf 'schema=1\nshort-title=demo\nstatus=구현 중\n' > "${base}/task-state"
  r="${base}/d4-ok"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 정상: 유효 세대 → 통과" "$out" "D4 현재 세대 메타 정상 (레코드 1건)" || rc=1
  r="${base}/d4-overflow"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"; : > "${r}/gen-1/.overflow"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상1: .overflow → 경고" "$out" "D4 이 세대는 기록을 중단했고 판정은 기존 동작으로 동작합니다. 다음 진행 상태 저장에서 복구됩니다" || rc=1
  r="${base}/d4-malformed"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\t군더더기\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상2: 3필드 레코드 → 경고" "$out" "D4 현재 세대 레코드 1건 중 1건이 malformed" || rc=1
  # 이상2b~2c (final diff review 턴 008 P1) — `.short-title` 자체가 손상된 세대.
  # 값은 맞고 바이트만 어긋나 종전에는 "일치" 로 판정됐고, 판정·진단 모두 정상으로 봤습니다.
  # 여기서는 short-title 불일치 경로로 수렴해야 합니다.
  r="${base}/d4-title-extra-lf"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상2b: .short-title 추가 LF → 경고" "$out" "D4 현재 세대의 short-title 이 진행 상태" || rc=1
  r="${base}/d4-title-nul"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\0\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상2c: .short-title 에 NUL → 경고" "$out" "D4 현재 세대의 short-title 이 진행 상태" || rc=1
  # 정상 경계 — 종단 LF 가 없는 short-title 은 손상이 아닙니다.
  r="${base}/d4-title-no-lf"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 정상3: .short-title 종단 LF 없음 → 통과" "$out" "D4 현재 세대 메타 정상 (레코드 1건)" || rc=1
  # 이상3~4 (final diff review 턴 004 P1) — **첫 줄이 정상인** 손상 레코드입니다. 종전에는
  # 진단도 판정도 첫 줄만 읽어 이 둘을 정상으로 보고했고, 판정 쪽에서는 넛지가 사라졌습니다.
  # 진단과 판정이 같은 함수를 쓰는지 확인하는 케이스이기도 합니다.
  r="${base}/d4-extra-line"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\n군더더기 줄\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상3: 정상 첫 줄 뒤 추가 줄 → 경고" "$out" "D4 현재 세대 레코드 1건 중 1건이 malformed" || rc=1
  r="${base}/d4-extra-lf"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\n\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상4: 추가 LF → 경고" "$out" "D4 현재 세대 레코드 1건 중 1건이 malformed" || rc=1
  # 이상5~6 (턴 006 P1) — 필드 구조가 어긋난 손상. 종전 파서는 빈 추가 TAB 필드를 세지
  # 못했고(TAB 이 IFS whitespace) `read` 가 NUL 을 버려 둘 다 정상 2필드로 축약했습니다.
  r="${base}/d4-trailing-tab"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\t\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상5: trailing TAB → 경고" "$out" "D4 현재 세대 레코드 1건 중 1건이 malformed" || rc=1
  r="${base}/d4-nul"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt\0\n' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 이상6: NUL → 경고" "$out" "D4 현재 세대 레코드 1건 중 1건이 malformed" || rc=1
  # 정상 형식의 경계 — 종단 LF 가 없는 레코드는 손상이 아니므로 통과해야 합니다.
  r="${base}/d4-no-trailing-lf"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  printf 'demo\n' > "${r}/gen-1/.short-title"
  printf '111-2\tsrc/a.txt' > "${r}/gen-1/9-9.sub"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; TASK_STATE_PATH="${base}/task-state"; _ep_diag_d4 2>&1)"
  _ep_t_has "D4 정상2: 종단 LF 없는 레코드 → 통과" "$out" "D4 현재 세대 메타 정상 (레코드 1건)" || rc=1

  # ---- D5 ----
  mkdir -p "${base}/jqbin" "${base}/nobin"
  printf '#!/bin/sh\nexit 0\n' > "${base}/jqbin/jq"; chmod +x "${base}/jqbin/jq"
  out="$(PATH="${base}/jqbin:$PATH"; _ep_diag_d5 2>&1)"
  _ep_t_has "D5 정상: jq 있음 → 통과" "$out" "D5 jq 가용 — T23 귀속 교차 검증 동작" || rc=1
  out="$(PATH="${base}/nobin"; _ep_diag_d5 2>&1)"
  _ep_t_has "D5 이상: jq 부재 → 정정 문구" "$out" "D5 jq 부재 — T23 귀속 교차 검증만 생략됩니다. 기록 기반 넛지 억제는 계속 동작합니다" || rc=1
  _ep_t_hasnt "D5 이상: 넛지 강등이라는 거짓 서술 없음" "$out" "넛지가 기존 동작으로" || rc=1

  # ---- D6 ---- 세대 누적은 정상입니다. 나이는 더 이상 판단 기준이 아닙니다.
  r="${base}/d6"; mkdir -p "${r}/gen-1" "${r}/gen-2" "${r}/gen-3"; printf 'gen-3\n' > "${r}/.current"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d6 2>&1)"
  _ep_t_has "D6 세대 3개 → 통과 + 개수 표시" "$out" '세대 3개 (작업 종료 시 `archive.sh` 가 일괄 회수합니다)' || rc=1
  _ep_t_hasnt "D6 경고하지 않음" "$out" "warn" || rc=1
  touch -t 202601010000 "${r}/gen-1" "${r}/gen-2"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d6 2>&1)"
  _ep_t_has "D6 오래된 세대 2개여도 여전히 통과" "$out" '세대 3개 (작업 종료 시 `archive.sh` 가 일괄 회수합니다)' || rc=1
  _ep_t_hasnt "D6 오래된 세대에도 경고 없음" "$out" "warn" || rc=1

  # ---- D7 ----
  r="${base}/d7"; mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d7 2>&1)"
  _ep_t_has "D7 정상: 흔적 없음 → 통과" "$out" "D7 직전 bump 실패 흔적 없음" || rc=1
  printf 'pointer-swap\n' > "${r}/.bump-failed"
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d7 2>&1)"
  _ep_t_has "D7 이상: 흔적 존재 → 경고" "$out" '직전 진행 상태 저장에서 편집 기록 세대 갱신이 실패했습니다(지점: `pointer-swap`)' || rc=1
  _ep_t_has "D7 이상: 복구 안내 문구" "$out" "저장 자체는 반영됐지만 다음 저장까지 넛지가 계속 뜰 수 있습니다. 다음 진행 상태 저장에서 복구됩니다" || rc=1
  # 복구: bump 성공이 흔적을 지우면 다시 통과여야 합니다 (헬퍼의 실제 정리 경로를 씁니다).
  ( RD_EDIT_PROVENANCE_DIR="$r"; ep_clear_bump_failed ) >/dev/null 2>&1 || true
  out="$(RD_EDIT_PROVENANCE_DIR="$r"; _ep_diag_d7 2>&1)"
  _ep_t_has "D7 복구: bump 성공 후 → 통과" "$out" "D7 직전 bump 실패 흔적 없음" || rc=1

  if ! rm -rf "$base" || [[ -e "$base" ]]; then
    _ep_t_fail "진단 분기 테스트 임시 트리 정리 실패 — 수동으로 지워야 합니다: $base"
    rc=1
  fi
  return $rc
}

# =============================================================================
# archive.sh provenance 루트 회수 (change spec §2.9) — (a)~(i) 9케이스
#
# 테스트를 프로세스 경계로 나눕니다. 셸 함수 override 는 `bash archive.sh` 로 실행되는
# 자식 프로세스에 전파되지 않으므로, 삭제 실패 주입은 **헬퍼 단위**로만 하고
# archive 의 경고 분기는 **stub 헬퍼 seam 하나**로 고정합니다.
# stub 은 fixture 경로를 리터럴로 박아 만듭니다 — 환경변수 참조를 남기면 자식 프로세스가
# 그 값을 보지 못하거나 harness 의 우연한 환경에 좌우됩니다.
# =============================================================================

_EP_GITIGNORE_ENTRY='rd-workflow-workspace/.lifecycle/edit-provenance.d/'

# archive fixture 저장소입니다. lifecycle/hooks 스크립트를 이 트리에서 복사해 세웁니다.
# 종결된 final-diff-review 세션을 fr tip 에 심어 review precheck 를 조용히 통과시킵니다
# (--force-skip-review-check 는 stderr 경고를 내므로 "무출력" 케이스를 잴 수 없습니다).
#
# 헬퍼 변종은 **초기 커밋 전에** 설치합니다 — 커밋 뒤에 파일을 놓으면 untracked 가 되어
# archive.sh Step 0 의 ensure_worktree_clean 이 dirty 로 차단합니다.
# stub 은 fixture 경로를 리터럴로 박아 만듭니다 (자식 프로세스는 우리 환경변수를 보지 못합니다).
_ep_arch_setup() {  # <repo> <slug> <헬퍼: none|real|stub|empty> [worktree-path]
  local d="$1" slug="$2" helper="$3" wt="${4:-}" src="${SCRIPT_DIR}" work eproot
  eproot="${d}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
  mkdir -p "$d" || return 1
  (
    set -e
    cd "$d"
    git init -q -b main >/dev/null 2>&1 || { git init -q; git checkout -q -b main; }
    git config user.email test@example.com
    git config user.name test
    printf '# Current Task\n\n## Short Title\n-\n\n## Branch / Worktree\nmain\n\n## Status\n대기 중\n' > CURRENT_TASK.md
    mkdir -p rd-workflow/scripts/lifecycle rd-workflow/scripts/hooks rd-workflow-workspace/.lifecycle
    printf '%s\n' \
      'rd-workflow-workspace/.lifecycle/loop-state' \
      'rd-workflow-workspace/.lifecycle/.loop-state.*' \
      'rd-workflow-workspace/.lifecycle/review-skip-audit.log' \
      "$_EP_GITIGNORE_ENTRY" > .gitignore
    cp "$src"/lifecycle/*.sh rd-workflow/scripts/lifecycle/
    cp "$src"/hooks/*.sh rd-workflow/scripts/hooks/
    cp "$src"/_state_common.sh rd-workflow/scripts/
    case "$helper" in
      real)  cp "$src/_edit_provenance_common.sh" rd-workflow/scripts/ ;;
      empty) : > rd-workflow/scripts/_edit_provenance_common.sh ;;
      stub)  printf 'ep_root() { printf "%%s\\n" %q; }\nep_purge_root() { return 1; }\n' "$eproot" \
               > rd-workflow/scripts/_edit_provenance_common.sh ;;
      none)  : ;;
      *)     exit 1 ;;
    esac
    git add -A
    git commit -q -m init
  ) || return 1
  if [[ -n "$wt" ]]; then
    ( cd "$d" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title "$slug" --worktree-path "$wt" ) >/dev/null 2>&1 || return 1
    work="$wt"
  else
    ( cd "$d" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title "$slug" --no-worktree ) >/dev/null 2>&1 || return 1
    work="$d"
  fi
  (
    set -e
    cd "$work"
    local sdir="rd-workflow-workspace/handoffs/review_pipeline/0001_final-diff-review"
    mkdir -p "$sdir"
    printf '# Session\n\n## Branch Context\n- fr-branch: fr/%s\n\n## Status\nclosed\n' "$slug" > "$sdir/SESSION.md"
    printf '# Checkpoint\n\n## Open Issues\n- 없음\n' > "$sdir/CHECKPOINT.md"
    printf '# archived\n' > REQUEST.md
    git add -A
    git commit -q -m "archive content"
  ) || return 1
  # 기본 브랜치 워킹트리를 main 으로 되돌립니다 (archive.sh 는 main 워킹트리에서만 동작합니다).
  ( cd "$d" && git switch main -q ) >/dev/null 2>&1 || true
  return 0
}

_ep_arch_run() {  # <repo> <stdout 파일> <stderr 파일> [archive 인자...]
  local repo="$1" o="$2" e="$3"; shift 3
  ( cd "$repo" && bash rd-workflow/scripts/lifecycle/archive.sh "$@" ) >"$o" 2>"$e"
}

# _ep_arch_run_env — RD_EDIT_PROVENANCE_DIR 을 **자식 프로세스 환경에** 실어 archive 를 돌립니다.
# "사용자가 테스트 변수를 export 한 채 잊었거나 외부 실행 환경이 주입한" 상황을 그대로 모사합니다.
_ep_arch_run_env() {  # <repo> <stdout 파일> <stderr 파일> <RD_EDIT_PROVENANCE_DIR> [archive 인자...]
  local repo="$1" o="$2" e="$3" epdir="$4"; shift 4
  ( cd "$repo" && RD_EDIT_PROVENANCE_DIR="$epdir" \
      bash rd-workflow/scripts/lifecycle/archive.sh "$@" ) >"$o" 2>"$e"
}

# CLEANUP-PENDING 잔여 레코드 목록만 잘라냅니다 (바이트 불변 대조용).
_ep_arch_cleanup_section() { sed -n '/^archive: CLEANUP-PENDING$/,$p' "$1"; }

edit_provenance_archive_check() {
  local rc=0 base repo r code out err gi base_pending stub_pending wt outside
  local src="${SCRIPT_DIR}"

  # (pre) .gitignore 항목 — 없으면 ensure_worktree_clean 이 provenance 루트를 dirty 로 보고
  #       archive 를 Step 0 에서 차단합니다. 이 트리의 .gitignore 를 대상으로 확인합니다.
  gi="$(cd "${src}/../.." && pwd)/.gitignore"
  if [[ ! -f "$gi" ]]; then
    printf '  skip .gitignore 없음 (%s)\n' "$gi"
  elif grep -qxF -- "$_EP_GITIGNORE_ENTRY" "$gi"; then
    _ep_t_pass ".gitignore 에 provenance 루트 ignore 항목 존재"
  else
    _ep_t_fail ".gitignore 에 ${_EP_GITIGNORE_ENTRY} 없음 — archive.sh Step 0 이 dirty 로 차단합니다: $gi"
    rc=1
  fi

  if ! base="$(_mktemp_dir_or_empty)"; then
    _ep_t_fail "archive 회수 테스트 임시 디렉터리 생성 실패 — 아무것도 만들지 않았습니다"
    return 1
  fi

  # ---- (a) 함수 단위: 삭제 실패 주입 ----
  r="${base}/a-root"; mkdir -p "${r}/gen-1"
  (
    RD_EDIT_PROVENANCE_DIR="$r"
    # shellcheck source=/dev/null
    . "${src}/_edit_provenance_common.sh"
    rm() { return 1; }
    ep_purge_root
  ) >/dev/null 2>&1
  code=$?
  [[ "$code" -ne 0 ]] && _ep_t_pass "(a) rm 실패 주입 → ep_purge_root non-zero" \
    || { _ep_t_fail "(a) rm 실패인데 ep_purge_root 가 0 을 반환"; rc=1; }
  [[ -d "$r" ]] && _ep_t_pass "(a) 루트 잔존" || { _ep_t_fail "(a) 루트가 사라짐"; rc=1; }

  # ---- (b) 함수 단위: 정상 삭제 ----
  r="${base}/b-root"; mkdir -p "${r}/gen-1"
  (
    RD_EDIT_PROVENANCE_DIR="$r"
    # shellcheck source=/dev/null
    . "${src}/_edit_provenance_common.sh"
    ep_purge_root
  ) >/dev/null 2>&1
  code=$?
  [[ "$code" -eq 0 ]] && _ep_t_pass "(b) 정상 상태 → ep_purge_root 0" \
    || { _ep_t_fail "(b) ep_purge_root 가 non-zero (rc=$code)"; rc=1; }
  [[ ! -e "$r" ]] && _ep_t_pass "(b) 루트 삭제" || { _ep_t_fail "(b) 루트 잔존"; rc=1; }

  # ---- (c) 프로세스 단위: 정상 회수 ----
  repo="${base}/c-repo"
  if _ep_arch_setup "$repo" "ep-c" real; then
    r="${repo}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
    mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
    _ep_arch_run "$repo" "${base}/c.out" "${base}/c.err" --no-remote
    code=$?
    [[ "$code" -eq 0 ]] && _ep_t_pass "(c) archive exit 0" \
      || { _ep_t_fail "(c) archive rc=$code"; sed 's/^/    /' "${base}/c.err" >&2; rc=1; }
    [[ ! -e "$r" ]] && _ep_t_pass "(c) provenance 루트 삭제" || { _ep_t_fail "(c) 루트 잔존: $r"; rc=1; }
    if [[ -s "${base}/c.err" ]]; then
      _ep_t_fail "(c) stderr 무출력 위반"; sed 's/^/    /' "${base}/c.err" >&2; rc=1
    else
      _ep_t_pass "(c) stderr 무출력"
    fi
  else
    _ep_t_fail "(c) fixture 준비 실패"; rc=1
  fi

  # ---- (d) 프로세스 단위: dry-run 비파괴 ----
  repo="${base}/d-repo"
  if _ep_arch_setup "$repo" "ep-d" real; then
    r="${repo}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
    mkdir -p "${r}/gen-1"
    _ep_arch_run "$repo" "${base}/d.out" "${base}/d.err" --no-remote --dry-run
    code=$?
    [[ "$code" -eq 0 ]] && _ep_t_pass "(d) dry-run exit 0" || { _ep_t_fail "(d) dry-run rc=$code"; rc=1; }
    [[ -d "${r}/gen-1" ]] && _ep_t_pass "(d) dry-run 루트 보존" || { _ep_t_fail "(d) dry-run 이 루트를 지움"; rc=1; }
    if [[ -s "${base}/d.err" ]]; then
      _ep_t_fail "(d) dry-run 경고 출력"; sed 's/^/    /' "${base}/d.err" >&2; rc=1
    else
      _ep_t_pass "(d) dry-run 경고 없음"
    fi
  else
    _ep_t_fail "(d) fixture 준비 실패"; rc=1
  fi

  # ---- (e) 프로세스 단위: worktree 경로 ----
  repo="${base}/e-repo"; wt="${base}/e-wt"
  if _ep_arch_setup "$repo" "ep-e" real "$wt"; then
    mkdir -p "${wt}/rd-workflow-workspace/.lifecycle/edit-provenance.d/gen-1"
    _ep_arch_run "$repo" "${base}/e.out" "${base}/e.err" --no-remote
    code=$?
    [[ "$code" -eq 0 ]] && _ep_t_pass "(e) worktree 경로 archive exit 0" \
      || { _ep_t_fail "(e) archive rc=$code"; sed 's/^/    /' "${base}/e.err" >&2; rc=1; }
    [[ ! -e "${wt}/rd-workflow-workspace/.lifecycle/edit-provenance.d" ]] \
      && _ep_t_pass "(e) worktree 제거로 그 안의 루트가 함께 사라짐 (잔존 0)" \
      || { _ep_t_fail "(e) worktree 안 루트 잔존: ${wt}"; rc=1; }
  else
    _ep_t_fail "(e) fixture 준비 실패"; rc=1
  fi

  # ---- (f) 프로세스 단위: 헬퍼 미설치 ----
  repo="${base}/f-repo"
  if _ep_arch_setup "$repo" "ep-f" none; then
    r="${repo}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
    mkdir -p "${r}/gen-1"
    _ep_arch_run "$repo" "${base}/f.out" "${base}/f.err" --no-remote
    code=$?
    [[ "$code" -eq 0 ]] && _ep_t_pass "(f) 헬퍼 미설치 archive exit 0" \
      || { _ep_t_fail "(f) archive rc=$code"; sed 's/^/    /' "${base}/f.err" >&2; rc=1; }
    [[ -d "${r}/gen-1" ]] && _ep_t_pass "(f) 정리 skip (루트 보존)" || { _ep_t_fail "(f) 헬퍼 없이 루트가 사라짐"; rc=1; }
    if [[ -s "${base}/f.err" ]]; then
      _ep_t_fail "(f) stderr 무출력 위반 (command-not-found 누출 의심)"; sed 's/^/    /' "${base}/f.err" >&2; rc=1
    else
      _ep_t_pass "(f) stderr 무출력 (command-not-found 없음)"
    fi
    base_pending="$(_ep_arch_cleanup_section "${base}/f.out")"
  else
    _ep_t_fail "(f) fixture 준비 실패"; rc=1; base_pending=""
  fi

  # ---- (g) 프로세스 단위: stub 헬퍼 (삭제 실패) ----
  repo="${base}/g-repo"
  if _ep_arch_setup "$repo" "ep-g" stub; then
    r="${repo}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
    mkdir -p "${r}/gen-1"
    _ep_arch_run "$repo" "${base}/g.out" "${base}/g.err" --no-remote
    code=$?
    [[ "$code" -eq 0 ]] && _ep_t_pass "(g) ③ archive exit 0" \
      || { _ep_t_fail "(g) archive rc=$code"; sed 's/^/    /' "${base}/g.err" >&2; rc=1; }
    out="$(wc -l < "${base}/g.err" | tr -d '[:space:]')"
    [[ "$out" == "1" ]] && _ep_t_pass "(g) ① stderr 정확히 1줄" \
      || { _ep_t_fail "(g) ① stderr ${out}줄"; sed 's/^/    /' "${base}/g.err" >&2; rc=1; }
    err="$(cat "${base}/g.err")"
    _ep_t_has "(g) 경고 문구" "$err" "provenance 기록 정리 실패" || rc=1
    # ② 경로를 정확히 대조합니다 — 문구만 보면 잘못된 대상을 지운 경우와 구별되지 않습니다.
    _ep_t_has "(g) ② 경고에 담긴 경로가 fixture 루트와 일치" "$err" "$r" || rc=1
    [[ -d "${r}/gen-1" ]] && _ep_t_pass "(g) ⑤ 루트 잔존" || { _ep_t_fail "(g) ⑤ 루트가 사라짐"; rc=1; }
    stub_pending="$(_ep_arch_cleanup_section "${base}/g.out")"
    if [[ "$stub_pending" == "$base_pending" ]]; then
      _ep_t_pass "(g) ④ cleanup_add 잔여 레코드 목록 바이트 불변"
    else
      _ep_t_fail "(g) ④ 잔여 레코드 목록이 달라짐 — 경고를 cleanup_add 로 승격했는지 확인"
      printf '    기대: [%s]\n    실제: [%s]\n' "$base_pending" "$stub_pending" >&2
      rc=1
    fi
    _ep_t_hasnt "(g) ④ CLEANUP-PENDING 미출력" "$(cat "${base}/g.out")" "CLEANUP-PENDING" || rc=1
  else
    _ep_t_fail "(g) fixture 준비 실패"; rc=1
  fi

  # ---- (h) 프로세스 단위: 헬퍼 파일은 있으나 함수 미정의 ----
  repo="${base}/h-repo"
  if _ep_arch_setup "$repo" "ep-h" empty; then
    r="${repo}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
    mkdir -p "${r}/gen-1"
    _ep_arch_run "$repo" "${base}/h.out" "${base}/h.err" --no-remote
    code=$?
    [[ "$code" -eq 0 ]] && _ep_t_pass "(h) 빈 헬퍼 archive exit 0" \
      || { _ep_t_fail "(h) archive rc=$code"; sed 's/^/    /' "${base}/h.err" >&2; rc=1; }
    [[ -d "${r}/gen-1" ]] && _ep_t_pass "(h) 함수 미정의 → 정리 skip" || { _ep_t_fail "(h) 루트가 사라짐"; rc=1; }
    if [[ -s "${base}/h.err" ]]; then
      _ep_t_fail "(h) stderr 무출력 위반"; sed 's/^/    /' "${base}/h.err" >&2; rc=1
    else
      _ep_t_pass "(h) stderr 무출력"
    fi
  else
    _ep_t_fail "(h) fixture 준비 실패"; rc=1
  fi

  # ---- (i) RD_EDIT_PROVENANCE_DIR 이 운영 삭제 대상을 바꾸지 못함 ----
  # final diff review 턴 002 P1. 종전에는 ep_root() 가 이 변수를 무조건 우선했고 archive 는
  # 인자 없이 ep_purge_root 를 불렀으므로, 변수가 환경에 남은 채 archive 를 돌리면
  # **정상 성공 경로의 마지막 단계에서 그 임의 경로가 통째로 재귀 삭제**됐습니다.
  # 프로젝트 **밖** 경로를 지목한 뒤 ① 그 경로와 그 안의 마커가 보존되고
  # ② 프로젝트 안 provenance 루트는 정상 삭제되며 ③ exit 0 + stderr 무출력인지 봅니다.
  repo="${base}/i-repo"
  if _ep_arch_setup "$repo" "ep-i" real; then
    r="${repo}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
    mkdir -p "${r}/gen-1"; printf 'gen-1\n' > "${r}/.current"
    outside="${base}/i-outside"
    mkdir -p "${outside}/precious"
    printf 'do not delete\n' > "${outside}/precious/keep.txt"
    _ep_arch_run_env "$repo" "${base}/i.out" "${base}/i.err" "$outside" --no-remote
    code=$?
    [[ "$code" -eq 0 ]] && _ep_t_pass "(i) 환경변수 override 상태에서 archive exit 0" \
      || { _ep_t_fail "(i) archive rc=$code"; sed 's/^/    /' "${base}/i.err" >&2; rc=1; }
    [[ -f "${outside}/precious/keep.txt" ]] \
      && _ep_t_pass "(i) 프로젝트 밖 override 경로 보존 (재귀 삭제 없음)" \
      || { _ep_t_fail "(i) override 경로가 삭제됨 — 운영 삭제 대상이 환경변수에 좌우됩니다: $outside"; rc=1; }
    [[ ! -e "$r" ]] && _ep_t_pass "(i) 프로젝트 안 provenance 루트만 삭제" \
      || { _ep_t_fail "(i) 프로젝트 루트가 남음: $r"; rc=1; }
    if [[ -s "${base}/i.err" ]]; then
      _ep_t_fail "(i) stderr 무출력 위반"; sed 's/^/    /' "${base}/i.err" >&2; rc=1
    else
      _ep_t_pass "(i) stderr 무출력"
    fi
  else
    _ep_t_fail "(i) fixture 준비 실패"; rc=1
  fi

  # worktree 등록이 남으면 이후 실행을 오염시키므로 fixture 저장소마다 prune 합니다.
  ( cd "${base}/e-repo" 2>/dev/null && git worktree prune ) >/dev/null 2>&1 || true
  if ! rm -rf "$base" || [[ -e "$base" ]]; then
    _ep_t_fail "archive 회수 테스트 임시 트리 정리 실패 — 수동으로 지워야 합니다: $base"
    rc=1
  fi
  return $rc
}

run_step "편집 출처 진단 분기 테스트 (D1~D7)" edit_provenance_diagnostics_selftest
run_step "편집 출처 archive 회수 (archive.sh §2.9)" edit_provenance_archive_check
run_step "편집 출처 진단 (edit provenance D1~D7)" edit_provenance_diagnostics_check

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
# 배포 미러 계약(체크섬 미러 + VERSION 검증). publish.sh 도 dev repo 전용이라 설치본에서는 skip.
test_publish_mirror_check() {
  local t="${SCRIPT_DIR}/../../scripts/test_publish_mirror.sh"
  if [[ -f "$t" ]]; then bash "$t"; else echo "  (skip: dev repo 아님)"; fi
}
# 생성 full 트리 회귀: `_ROOT_FILES` 가 없는 소비 프로젝트 형상에서도 결함 보고 조작부가
# 실제로 동작하는지 증명한다. dev repo 에서만 의미가 있으므로(빌더 필요) 설치본에서는 skip 한다.
# 이 검사가 있어야 "정본 경로에 의존하는 검사·스크립트" 회귀가 배포 전에 잡힌다
# (final diff review Turn 004 Finding 1 의 회귀 테스트).
generated_tree_defect_reports_check() {
  local builder="${SCRIPT_DIR}/../../scripts/build_template.sh"
  if [[ ! -f "$builder" ]]; then echo "  (skip: dev repo 아님)"; return 0; fi
  # 임시 root 생성 실패를 반드시 검사한다 — 빈 치환을 그대로 쓰면 대상이 `/full` 이 되어
  # **저장소 밖 절대 경로에 빌드를 시도**한다 (final diff review Turn 006 Finding 2).
  local tmproot rc=0
  if ! tmproot="$(_mktemp_dir_or_empty)"; then
    printf '  FAIL 임시 디렉터리 생성 실패 — 빌더를 호출하지 않았습니다\n'
    return 1
  fi
  # 산출물 트리는 크므로 성공·실패 모든 경로에서 정리한다. 정리 지점을 한곳으로 모으려고
  # 본체를 헬퍼로 분리했다 (반복 self-test 가 임시 트리를 누적하지 않게 한다).
  _generated_tree_probe "$builder" "${tmproot}/full"; rc=$?
  # **정리 실패를 성공으로 감추지 않는다** (Turn 008 Finding 3). 이 검사가 사용자에게 하는
  # 약속의 절반은 "임시 트리를 남기지 않는다" 이므로, 남았으면 경로를 보여주고 FAIL 한다.
  if ! rm -rf "$tmproot" || [[ -e "$tmproot" ]]; then
    printf '  FAIL 임시 트리 정리 실패 — 수동으로 지워야 합니다: %s\n' "$tmproot"
    rc=1
  fi
  return $rc
}

_generated_tree_probe() {  # $1=builder $2=산출물 경로
  local builder="$1" out="$2" rc=0 f
  if ! bash "$builder" full "$out" >/dev/null 2>&1; then
    printf '  FAIL full 빌드 실패: %s\n' "$out"; return 1
  fi
  # 전제: 산출물에는 정본 디렉터리가 없다 — 없어야 이 회귀 테스트가 의미를 가진다.
  if [[ -e "$out/_ROOT_FILES" ]]; then
    printf '  FAIL 생성 트리에 _ROOT_FILES 가 존재합니다 (빌드 규칙 회귀)\n'; return 1
  fi
  for f in defect_reports.sh test_defect_reports.sh; do
    [[ -f "$out/rd-workflow/scripts/$f" ]] || { printf '  FAIL 배포 누락: rd-workflow/scripts/%s\n' "$f"; rc=1; }
  done
  [[ "$rc" -eq 0 ]] || return 1
  # 생성 트리를 CWD 로 두고 배포 테스트를 실행한다 (배포 구현을 대상으로 잡는다).
  # `TMPDIR` 을 트리 안으로 격리해 **배포 사본에서도 임시 디렉터리 증분 0** 을 확인한다
  # (Turn 010 Finding 2 — self-test 는 이 스위트를 직접·생성 트리에서 두 번 돌린다).
  local tdir="${out}/.tmpcheck"
  mkdir -p "$tdir" || { printf '  FAIL 격리 TMPDIR 생성 실패: %s\n' "$tdir"; return 1; }
  if (cd "$out" && TMPDIR="$tdir" bash rd-workflow/scripts/test_defect_reports.sh >/dev/null 2>&1); then
    printf '  ok   생성 full 트리에서 결함 보고 테스트 통과 (_ROOT_FILES 없음)\n'
  else
    printf '  FAIL 생성 full 트리에서 결함 보고 테스트 실패 — 마지막 20행:\n'
    (cd "$out" && TMPDIR="$tdir" bash rd-workflow/scripts/test_defect_reports.sh 2>&1 | tail -20)
    rc=1
  fi
  local left; left="$(ls -A "$tdir" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$left" != "0" ]]; then
    printf '  FAIL 생성 트리 실행이 임시 디렉터리를 %s건 남겼습니다\n' "$left"; rc=1
  fi
  return $rc
}
run_step "self_test 계약 (checker whitelist·root resolver)" hook_selftest_contract_check
run_step "hook 경로 도달 증명 (hook_path_reachability_check)" hook_path_reachability_check
run_step "hook 대상 실재 (hook_target_existence_check)" hook_target_existence_check
run_step "hook 표기 회귀 방지 (hook_path_notation_regression_check)" hook_path_notation_regression_check
run_step "템플릿 build 검증 (build_template.sh verify)" build_verify_check
run_step "템플릿 빌더 단위 테스트 (test_build_template.sh)" test_build_template_check
run_step "배포 미러 계약 (test_publish_mirror.sh)" test_publish_mirror_check
run_step "생성 full 트리 결함 보고 회귀 (generated_tree_defect_reports_check)" generated_tree_defect_reports_check
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
