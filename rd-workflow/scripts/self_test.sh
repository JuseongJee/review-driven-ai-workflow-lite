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
run_step "self_test 계약 (checker whitelist·root resolver)" hook_selftest_contract_check
run_step "hook 경로 도달 증명 (hook_path_reachability_check)" hook_path_reachability_check
run_step "hook 대상 실재 (hook_target_existence_check)" hook_target_existence_check
run_step "hook 표기 회귀 방지 (hook_path_notation_regression_check)" hook_path_notation_regression_check
run_step "템플릿 build 검증 (build_template.sh verify)" build_verify_check
run_step "템플릿 빌더 단위 테스트 (test_build_template.sh)" test_build_template_check
run_step "배포 미러 계약 (test_publish_mirror.sh)" test_publish_mirror_check
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
