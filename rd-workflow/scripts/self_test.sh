#!/usr/bin/env bash
# 워크플로 인프라(rd-workflow) self-test entrypoint.
# 본 프로젝트와 generated project 공통으로 rd-workflow 인프라가 정상인지 검증한다.
# 제품 코드 테스트(test.sh/lint.sh/typecheck.sh)와는 책임이 다르다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 실행 모드 (spec §5.1) -------------------------------------------------
# 인자 없음 또는 smoke → smoke(기본), full → 전수 실행, 그 외 → 사용법 후 exit 1.
#
# **인자는 정확히 하나까지만 받습니다.** dry-run 이 환경변수 전용이라
# `self_test.sh smoke --dry-run` 은 치기 쉬운 형태인데, 남는 인자를 무시하면 그것이 경고
# 없이 전수 실행으로 떨어집니다 (이 저장소에서 사람이 실제로 겪었습니다 — 목록만 볼
# 생각으로 친 명령이 수 분을 돌았습니다). 조용한 오작동보다 즉시 실패가 낫습니다.
SELFTEST_MODE="smoke"
selftest_usage_exit() {
  echo "  사용법: bash rd-workflow/scripts/self_test.sh [smoke|full|consumer]" >&2
  echo "    smoke (기본) — 변경 파일과 관련된 스텝만 실행합니다 (증명을 남기지 않습니다)" >&2
  echo "    full         — 전체 스텝을 실행합니다 (두 청중 모두). full 증명을 남깁니다" >&2
  echo "    consumer     — 소비 프로젝트에서 뜻이 있는 스텝만 실행합니다 (아카이브 게이트가 쓰는 모드)" >&2
  echo "  dry-run 은 인자가 아니라 환경변수입니다: RD_SELFTEST_SMOKE_DRYRUN=1" >&2
  exit 1
}
if [[ $# -gt 1 ]]; then
  echo "[self_test] 인자는 하나만 받습니다: $*" >&2
  selftest_usage_exit
fi
case "${1:-}" in
  ""|smoke) SELFTEST_MODE="smoke" ;;
  full)     SELFTEST_MODE="full" ;;
  consumer) SELFTEST_MODE="consumer" ;;
  *)
    echo "[self_test] 알 수 없는 인자입니다: $1" >&2
    selftest_usage_exit
    ;;
esac

SELFTEST_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SMOKE_FALLBACK_FULL=0
SMOKE_FALLBACK_REASON=""
SKIPPED_STEPS=()
SMOKE_SKIP_DESCS=()
SMOKE_STEP_DESCS=()
# 순번↔설명 대조가 한 번이라도 어긋나면 그 이후 순번은 전부 남의 판정을 물려받은 상태이므로
# 스킵 판정을 조회할 근거가 사라집니다 (= 정렬 불명). 그 시점 이후는 전부 실행합니다.
SMOKE_ALIGN_LOST=0
SMOKE_ALIGN_LOST_IDX=0
SMOKE_ALIGN_FORCED=0
# 헬퍼가 없으면(예상치 못한 배포 형태) 조용히 약해지지 않도록 전수 실행으로 되돌립니다.
#
# **`consumer` 는 예외로 즉시 실패합니다.** 증명 기록 함수가 이 헬퍼에 있어 `consumer` 의
# 목적(아카이브 증명 생성) 자체가 불가능하기 때문입니다. 같은 full 폴백을 적용하면 실행
# 범위는 조용히 넓어지는데 증명은 남지 않아, 게이트가 사유 없이 실패하는 상태가 됩니다.
if [[ -f "${SCRIPT_DIR}/_smoke_common.sh" ]]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/_smoke_common.sh"
elif [[ "$SELFTEST_MODE" == "consumer" ]]; then
  echo "[self_test] consumer 모드를 실행할 수 없습니다 — _smoke_common.sh 가 없습니다" >&2
  echo "  이 헬퍼에 증명 기록 함수가 있어 consumer 증명을 남길 수 없습니다." >&2
  echo "  대안: bash rd-workflow/scripts/self_test.sh full (전수 실행)" >&2
  exit 1
else
  SELFTEST_MODE="full"
fi

FAIL=0
STEP_NAMES=()
STEP_DURATIONS=()
AUDIENCE_EXCLUDED=()

# 사용법: run_step <consumer|dev-only> "<설명>" <명령...>
#
# **청중은 필수 인자입니다.** 기본값을 두지 않는 이유 — `consumer` 기본값은 현상 유지라
# 다음에 추가되는 정본 위생 검사가 또 소비처의 아카이브를 막고, `dev-only` 기본값은 새
# 검사가 조용히 소비처 검증에서 빠집니다. 필수 인자는 두 실패를 동시에 피합니다.
run_step() {
  local audience="${1-}" desc
  case "$audience" in
    consumer|dev-only) shift ;;
    *)
      # 조용한 skip 이 아니라 FAIL 입니다. skip 하면 청중을 빠뜨린 스텝이 검증에서
      # 사라지면서 rc 는 0 이 되어, 필수화 자체가 무력해집니다.
      STEP_INDEX=$((STEP_INDEX + 1))
      echo ""
      echo "== 스텝 ${STEP_INDEX}: 청중 선언 오류 =="
      echo "  -> FAIL: 청중이 없거나 허용값이 아닙니다: '${audience}' (consumer|dev-only 중 하나여야 합니다)" >&2
      FAIL=1
      return 0
      ;;
  esac
  desc="${1-}"; shift
  STEP_INDEX=$((STEP_INDEX + 1))
  # 청중 필터 — `consumer` 모드는 정본 위생 검사(dev-only)를 실행하지 않습니다.
  # 이것이 "정본 규칙 하나가 소비 프로젝트의 아카이브를 막는" 경로를 닫는 지점입니다.
  if [[ "$SELFTEST_MODE" == "consumer" && "$audience" == "dev-only" ]]; then
    AUDIENCE_EXCLUDED+=("${STEP_INDEX}. ${desc}")
    return 0
  fi
  # smoke 이고 폴백이 아니면 preflight 판정 결과를 **호출 순번**으로 조회합니다 (spec §5.3).
  # 폐포를 여기서 다시 계산하지 않는 이유: preflight 가 이미 전량 판정했고,
  # 실행 중 재계산하면 시작 시 보여준 목록과 실제 실행이 어긋날 수 있습니다.
  # 설명 문자열이 아니라 순번으로 조회하는 이유: 설명이 같은 두 스텝 중 하나만 무관해도
  # 관련 있는 쪽까지 함께 스킵되기 때문입니다.
  #
  # `SMOKE_FALLBACK_FULL -eq 0` 가드는 **현재 코드에서는 이중 방어**입니다 — 모든 폴백 경로가
  # preflight 호출 **전에** 반환하거나(수집 실패·변경 0건·자기 변경·추출 불일치), 무매핑은
  # preflight 가 스킵 산출을 비워서 내므로 `SMOKE_SKIP_IDX` 가 항상 빈 문자열입니다.
  # **그래도 지우지 마십시오**: preflight **이후에** 새 폴백 사유를 추가하면서 산출을 비우지
  # 않으면 그 순간부터 폴백 상태에서 스킵이 조용히 새어 나갑니다.
  if [[ "$SELFTEST_MODE" == "smoke" && "$SMOKE_FALLBACK_FULL" -eq 0 ]]; then
    # 순번 조회 **전에** preflight 의 순번→설명 대응표와 대조합니다 (spec §5.3 역할 3).
    #
    # 정적 추출은 **최상위** run_step 만 봅니다. 그래서 함수 안에서 부른 run_step 은
    # 추출 수를 바꾸지 않아 추출 fail-safe 를 통과하면서 런타임 순번만 밀어냅니다.
    # 그러면 밀려난 순번이 남의 판정을 물려받아, **preflight 가 알지도 못하는 스텝이
    # 오히려 스킵**됩니다 — spec 이 요구한 "스킵하지 않고 실행" 의 정반대입니다.
    # 건수 대조로는 잡히지 않습니다(스킵 1건이 다른 1건으로 바뀔 뿐입니다).
    #
    # 어긋나면 **그 스텝과 이후 모든 스텝을** 스킵하지 않고 실행하고 경고를 남깁니다
    # (= 정렬 불명). 어긋남은 순번을 밀어내는 사건이라 밀린 뒤의 순번은 전부 남의 판정을
    # 물려받은 상태이고, 그 중 하나가 우연히 자기 자리 설명과 맞아떨어지면 대조가 통과해
    # **변경된 파일 자신의 스텝이 rc=0 · 요약 완전 일치 · 무경고로 조용히 스킵**됩니다
    # (실측: 그 조합에서 관련 스텝이 실제로 사라졌습니다). "그 스텝만 살린다" 로는
    # 이 경로를 막지 못하므로 어긋남 이후에는 조회 자체를 하지 않습니다.
    #
    # 되돌릴 수 없는 것은 되돌린 척하지 않습니다 — 어긋남 **이전에** 이미 스킵한 스텝은
    # 그대로 남으므로 이것을 "full 폴백" 으로 표기하지 않고 정렬 불명으로 신고합니다.
    # rc 는 바꾸지 않습니다 (경고는 신고이지 판정이 아닙니다).
    if (( SMOKE_ALIGN_LOST )); then
      # 손실 규모를 요약에서 1줄로 보고하기 위한 계수입니다. 이 보고가 유일한 완화
      # 장치이므로(rc 가 0 이라 감축 손실은 보고 없이는 보이지 않습니다) 빼지 마십시오.
      SMOKE_ALIGN_FORCED=$((SMOKE_ALIGN_FORCED + 1))
    else
      local _expected_desc="${SMOKE_STEP_DESCS[$((STEP_INDEX - 1))]+${SMOKE_STEP_DESCS[$((STEP_INDEX - 1))]}}"
      if [[ "$_expected_desc" != "$desc" ]]; then
        # 경고는 **첫 어긋남에서 1회만** 냅니다. 스텝마다 반복하면 남은 스텝 수만큼 같은
        # 4줄이 쌓여 소음이 진짜 신호를 덮습니다 (실측: 4스텝 fixture 에서 16줄).
        SMOKE_ALIGN_LOST=1
        SMOKE_ALIGN_LOST_IDX="$STEP_INDEX"
        SMOKE_ALIGN_FORCED=1
        echo "== 경고: 스텝 순번 ${STEP_INDEX} 의 preflight 대응이 어긋났습니다 ==" >&2
        echo "   preflight: '${_expected_desc:-(없음)}' / 실제: '${desc}'" >&2
        echo "   preflight 가 알지 못하는 스텝이 끼어들어 순번이 밀렸을 수 있습니다. 이 스텝은 스킵하지 않고 실행합니다." >&2
        echo "   순번 정렬을 신뢰할 수 없으므로 이후 스텝도 스킵 판정을 조회하지 않고 전부 실행합니다." >&2
        echo "   이 결과를 검증 통과로 쓰지 말고 bash rd-workflow/scripts/self_test.sh full 로 전수 실행하십시오." >&2
      else
        case "$SMOKE_SKIP_IDX" in
          *"|${STEP_INDEX}|"*)
            # 스킵은 반드시 기록과 함께 합니다. 기록 없이 return 하면 사용자에게는
            # "스킵 0건" 으로 보이면서 실제로는 검증이 축소됩니다.
            SKIPPED_STEPS+=("${STEP_INDEX}. ${desc}")
            return 0
            ;;
        esac
      fi
    fi
  fi
  # dry-run 은 실행하지 않고 실행 예정으로만 기록합니다.
  if [[ -n "${RD_SELFTEST_SMOKE_DRYRUN:-}" ]]; then
    STEP_NAMES+=("$desc")
    STEP_DURATIONS+=(0)
    return 0
  fi
  local _t0=$SECONDS elapsed
  echo ""
  echo "== ${desc} =="
  if "$@"; then
    elapsed=$((SECONDS - _t0))
    echo "  -> PASS: ${desc} (${elapsed}s)"
  else
    elapsed=$((SECONDS - _t0))
    echo "  -> FAIL: ${desc} (${elapsed}s)" >&2
    FAIL=1
  fi
  STEP_NAMES+=("$desc")
  STEP_DURATIONS+=("$elapsed")
}

print_step_summary() {
  local i
  # self_test.sh 최상단 `set -euo pipefail`을 상속하지만, sort 등 중간 단계 실패가
  # 마지막 명령(while read)의 종료 코드에 가려지지 않도록 이 함수 안에서 명시적으로
  # 재확인한다. 전역에 이미 켜진 옵션을 다시 켜는 것이라 부작용은 없다.
  set -o pipefail
  for ((i = 0; i < ${#STEP_NAMES[@]}; i++)); do
    printf '%s\t%s\n' "${STEP_DURATIONS[i]}" "${STEP_NAMES[i]}"
  done | sort -t$'\t' -k1 -rn | while IFS=$'\t' read -r dur name; do
    printf '  %ss  %s\n' "$dur" "$name"
  done
}

syntax_check() {
  local rc=0 f
  # smoke(폴백 아님) 에서는 변경된 *.sh 만 검사합니다 (spec §5.4 (c)).
  # 속도가 목적이 아니라 "smoke 가 무엇을 검사하지 않는지" 원칙을 일관 적용하는 것이
  # 목적입니다. 대가는 명확합니다 — **변경되지 않은 스크립트의 구문 오류를 smoke 는
  # 놓칩니다.** 그것을 잡는 것은 full 이고, 그래서 폴백 상태에서는 반드시 전수로
  # 돌아가야 합니다 (폴백이 "전수 실행" 을 뜻하는데 이 스텝만 축소된 채면 폴백 계약이
  # 반쯤 거짓이 됩니다).
  if [[ "$SELFTEST_MODE" == "smoke" && "$SMOKE_FALLBACK_FULL" -eq 0 ]]; then
    smoke_changed_shell_files "$SELFTEST_ROOT"
    for f in ${SMOKE_SYNTAX_TARGETS[@]+"${SMOKE_SYNTAX_TARGETS[@]}"}; do
      if ! bash -n "$f" 2>/dev/null; then
        echo "  구문 오류: $f" >&2
        rc=1
      fi
    done
    return $rc
  fi
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

# --- smoke 초기화 + preflight (spec §5.2·§5.3·§5.6) ------------------------
#
# preflight 는 첫 스텝을 돌리기 전에 **모든 스텝을 미리 판정**합니다. 세 가지를 함께 해결합니다.
#   (1) 무매핑 fail-safe — 어떤 폐포에도 없는 인프라 코드 변경이 있으면 full 폴백
#   (2) 시작 시 가시성 — 실행/스킵 목록을 첫 스텝 전에 출력
#   (3) 추출 fail-safe — run_step 정적 추출이 실패하거나 실제 호출 수와 어긋나면 full 폴백
# 스텝 식별은 **호출 순번**입니다. 설명 문자열을 키로 쓰면 설명이 같은 두 스텝 중 하나만
# 무관해도 관련 있는 쪽까지 스킵되고, 설명에 구분자가 들어가면 집합 표현 자체가 깨집니다.
#
# `SMOKE_SKIP_IDX`(`|N|` 집합) · `SMOKE_SKIP_DESCS`(`"<순번>. <설명>"`) · `SMOKE_UNMAPPED` 는
# `_smoke_common.sh` 의 `smoke_preflight` 가 채웁니다 — 여기서 다시 초기화하지 마십시오.
STEP_INDEX=0

smoke_init() {
  # **smoke 에서만 본체를 실행합니다.** `full`·`consumer` 는 실행 집합이 변경 파일과 무관하게
  # 정해지므로 preflight 가 필요 없고, 들어가면 변경 파일 수집·git 오류 폴백·자기변경 감지·
  # 무매핑 폴백까지 전부 타면서 "full 폴백" 문구가 나와 사용자가 범위를 오인합니다.
  if [[ "$SELFTEST_MODE" != "smoke" ]]; then
    return 0
  fi
  if ! smoke_collect_changed_files "$SELFTEST_ROOT"; then
    SMOKE_FALLBACK_FULL=1
    SMOKE_FALLBACK_REASON="변경 파일 수집에 실패했습니다 (git 실패 또는 인식할 수 없는 상태)"
    return 0
  fi
  if (( ${#SMOKE_CHANGED_FILES[@]} == 0 )); then
    SMOKE_FALLBACK_FULL=1
    SMOKE_FALLBACK_REASON="변경 파일이 없습니다 (워킹트리 clean)"
    return 0
  fi
  # 판정 엔진 자신이 바뀐 실행은 무조건 전수로 돕니다. self_test.sh 는 폐포에서 잘려 나가
  # 어떤 스텝과도 연결되지 않고, _smoke_common.sh 는 반대로 거의 모든 스텝의 폐포에 들어가
  # 스킵을 줄이기는 하지만 **감축 결정 자체를 자기가 내립니다** — 깨졌을지 모르는 엔진이
  # 자기 실행의 축소 범위를 정하는 구조라, 실측상 스킵 24 / 실행 26 으로 축소된 채 통과합니다.
  # 두 파일은 같은 특례로 묶습니다.
  local m b
  for m in ${SMOKE_CHANGED_FILES[@]+"${SMOKE_CHANGED_FILES[@]}"}; do
    b="$(basename "$(smoke_normalize_path "$m")")"
    if [[ "$b" == "self_test.sh" || "$b" == "_smoke_common.sh" ]]; then
      SMOKE_FALLBACK_FULL=1
      SMOKE_FALLBACK_REASON="${b} 자신이 변경되었습니다"
      return 0
    fi
  done

  local self="${SCRIPT_DIR}/self_test.sh" extracted actual
  extracted="$(smoke_extract_steps "$self" | wc -l | tr -d ' ')" || extracted=0
  actual="$(grep -c '^run_step ' "$self" 2>/dev/null || echo 0)"
  if [[ "$extracted" -eq 0 || "$extracted" != "$actual" ]]; then
    SMOKE_FALLBACK_FULL=1
    SMOKE_FALLBACK_REASON="run_step 정적 추출 결과(${extracted})가 실제 호출 수(${actual})와 다릅니다"
    return 0
  fi

  # preflight 를 **1회** 호출해 모든 스텝을 미리 판정합니다. 스텝마다 폐포를 한 번만
  # 계산해 관련성 판정과 커버 기록을 함께 끝내며, run_step 은 그 산출(순번 집합)만
  # 조회합니다 — 폐포를 두 번 계산하지 않고, 시작 시 보여준 목록과 실제 실행이 어긋나지
  # 않습니다. **실행 중에 smoke_step_relevant 를 재호출하지 마십시오** — preflight 안의
  # 캐시(스크립트 인덱스·참조 memo)가 "실행 초반 1회 호출" 을 전제로 하고 있습니다.
  if ! smoke_preflight "$SCRIPT_DIR" "$self"; then
    SMOKE_FALLBACK_FULL=1
    SMOKE_FALLBACK_REASON="스텝 정적 추출에 실패했습니다 (preflight)"
    return 0
  fi
  # 어떤 스텝의 폐포에도 걸리지 않는 인프라 변경은 full 폴백입니다. 이때 preflight 는
  # 스킵 산출을 이미 비워 두므로(Task 2c C1), 이 검사를 빠뜨려도 "전부 스킵" 으로는
  # 새지 않습니다 — 그래도 사유를 사용자에게 보여야 하므로 여기서 명시적으로 다룹니다.
  if [[ -n "$SMOKE_UNMAPPED" ]]; then
    SMOKE_FALLBACK_FULL=1
    SMOKE_FALLBACK_REASON="어떤 스텝과도 연결되지 않는 인프라 변경이 있습니다: $(printf '%s' "$SMOKE_UNMAPPED" | tr '\n' ' ')"
    return 0
  fi
  return 0
}
smoke_init

# 등록부를 **실행하지 않고** 청중 분포를 셉니다. 배너와 정적 검사(청중 미선언 0건)가 함께
# 씁니다. 미선언 스텝은 추출식(`^run_step <청중> "설명"`)에 매치되지 않으므로,
# `grep -c '^run_step '` 과 추출 행수의 차이가 곧 미선언 건수입니다.
SELFTEST_AUD_TOTAL=0
SELFTEST_AUD_CONSUMER=0
SELFTEST_AUD_DEVONLY=0
SELFTEST_AUD_UNDECLARED=0
selftest_count_audiences() {
  local self="$1" steps aud rest declared=0 raw
  declare -F smoke_extract_steps >/dev/null 2>&1 || return 1
  raw="$(grep -c '^run_step ' "$self" 2>/dev/null || true)"
  [[ -n "$raw" ]] || raw=0
  steps="$(smoke_extract_steps "$self" 2>/dev/null)" || steps=""
  if [[ -n "$steps" ]]; then
    while IFS=$'\t' read -r aud rest; do
      [[ -n "$aud" ]] || continue
      declared=$((declared + 1))
      case "$aud" in
        consumer) SELFTEST_AUD_CONSUMER=$((SELFTEST_AUD_CONSUMER + 1)) ;;
        dev-only) SELFTEST_AUD_DEVONLY=$((SELFTEST_AUD_DEVONLY + 1)) ;;
      esac
    done <<< "$steps"
  fi
  SELFTEST_AUD_TOTAL="$raw"
  SELFTEST_AUD_UNDECLARED=$((raw - declared))
  (( SELFTEST_AUD_UNDECLARED < 0 )) && SELFTEST_AUD_UNDECLARED=0
  return 0
}
selftest_count_audiences "${BASH_SOURCE[0]}" || true

# 시작 배너 — **강제 범위가 좁아진 사실이 사용자에게 보여야 합니다.** 게이트가 예전처럼
# "전수 검증" 이라고만 말하면 사용자는 dev 검증까지 끝났다고 오인합니다.
echo "== self_test 실행 범위 =="
case "$SELFTEST_MODE" in
  full)
    echo "  모드: full — 청중 두 종류 모두 (consumer + dev-only)"
    echo "  실행 예정: ${SELFTEST_AUD_TOTAL}스텝 / 청중 제외: 0"
    ;;
  consumer)
    echo "  모드: consumer — 소비 프로젝트에서 뜻이 있는 스텝만"
    echo "  실행 예정: ${SELFTEST_AUD_CONSUMER}스텝 / 청중 제외: ${SELFTEST_AUD_DEVONLY}스텝"
    echo "  제외 이유: dev-only (rd-workflow 정본 저작 규칙 — 소비 프로젝트에서 판정할 대상이 아닙니다)"
    echo "  주의: 이것은 전수 검증이 아닙니다. 정본 위생 검사까지 보려면 full 로 실행하십시오"
    ;;
  smoke)
    echo "  모드: smoke — 변경 파일과 연결된 스텝만 (청중 무관, 증명을 남기지 않습니다)"
    ;;
esac
if (( SELFTEST_AUD_UNDECLARED > 0 )); then
  echo "  경고: 청중을 선언하지 않은 스텝이 ${SELFTEST_AUD_UNDECLARED}건 있습니다 — 해당 스텝은 FAIL 로 보고됩니다" >&2
fi

# dry-run 은 스텝을 하나도 실행하지 않고 "실행 예정" 목록만 내고 exit 0 합니다. 환경변수가
# 셸에 export 된 채 남거나 외부에서 잘못 주입되면 `full` 조차 즉시 rc 0 으로 끝나므로,
# 사용자가 전체 검증이 통과한 것으로 오인할 수 있습니다. `RD_SELFTEST_CHECKER_ONLY` 와 같은
# 취지로 **stderr 에** 경고를 냅니다 (stdout 을 파싱하는 테스트에는 영향이 없습니다).
if [[ -n "${RD_SELFTEST_SMOKE_DRYRUN:-}" ]]; then
  echo "== self_test: dry-run 모드 — 스텝을 하나도 실행하지 않습니다 (검증 결과 아님) ==" >&2
fi

# --- 시작 시 가시성 (첫 스텝 실행 전) --------------------------------------
echo "mode: ${SELFTEST_MODE}"
if [[ "$SELFTEST_MODE" == "smoke" ]]; then
  if [[ "$SMOKE_FALLBACK_FULL" -eq 1 ]]; then
    echo "  full 폴백 — 사유: ${SMOKE_FALLBACK_REASON}"
    echo "  전체 스텝을 실행합니다."
  else
    echo "  변경 파일 (${#SMOKE_CHANGED_FILES[@]}개):"
    printf '    %s\n' ${SMOKE_CHANGED_FILES[@]+"${SMOKE_CHANGED_FILES[@]}"}
    echo "  스킵 예정 스텝 (${#SMOKE_SKIP_DESCS[@]}개) — 사유: 변경 파일이 이 스텝의 참조 폐포에 없습니다"
    # 빈 배열에 그대로 printf 를 걸면 인자 없이 포맷이 한 번 적용되어 `    - ` 만 있는
    # 빈 항목이 찍힙니다 — 스킵 0건이 1건처럼 보이므로 건수가 있을 때만 출력합니다.
    if (( ${#SMOKE_SKIP_DESCS[@]} > 0 )); then
      printf '    - %s\n' "${SMOKE_SKIP_DESCS[@]}"
    fi
  fi
  echo "  전체 검증: bash rd-workflow/scripts/self_test.sh full"
fi

# full 시작 시점의 proof 지문입니다. 최종 PASS 에서 같은 지문이 다시 나올 때만 기록합니다 —
# 실행 도중 내용이 바뀌었다면 검증하지 않은 내용을 통과로 증명하게 되기 때문입니다.
# smoke 에서는 계산하지 않습니다. 기록도 smoke 에서는 하지 않으므로 "smoke 만 통과한 상태"
# 와 "full 통과 상태" 가 캐시로 구별됩니다.
SELFTEST_START_FP=""
# 시작 시점의 untracked 상태입니다. **기록 판정에 함께 넘깁니다** — 종료 시점만 보면 실행
# 중에 생겼다 사라진 파일이 흔적을 남기지 않고, 그 상태를 가린 채 PASS 가 기록됩니다.
# 빈 값은 "확인하지 못함" 이며 기록 쪽에서 거부합니다 (지문의 빈 값과 같은 취급입니다).
SELFTEST_START_USTATE=""
# **증명을 남기는 두 모드(`full`·`consumer`) 모두**에서 시작 지문을 잡습니다.
# `full` 만 보면 `consumer` 가 기록 조건(시작·종료 지문 일치)을 갖추지 못해 증명이 남지 않고,
# 게이트의 사후 대조가 영구히 실패합니다.
if [[ "$SELFTEST_MODE" == "full" || "$SELFTEST_MODE" == "consumer" ]]; then
  SELFTEST_START_FP="$(smoke_proof_fingerprint "$SELFTEST_ROOT" worktree 2>/dev/null || true)"
  # 기록 거부 사유(untracked 존재)는 **지금 이미 확정**입니다. 종료 시점에만 알리면
  # 사용자는 수 분을 쓰고 나서야 증명이 남지 않는다는 것을 알고, git add 후 같은 시간을
  # 다시 써야 합니다. 시작 직후에 알리면 그 손실이 사라집니다.
  # stdout 형식을 오염시키지 않도록 stderr 로만 냅니다.
  if declare -F smoke_untracked_state >/dev/null 2>&1; then
    SELFTEST_START_USTATE=0
    SELFTEST_START_UNTRACKED="$(smoke_untracked_state "$SELFTEST_ROOT")" || SELFTEST_START_USTATE=$?
    if [[ "$SELFTEST_START_USTATE" -eq 1 ]]; then
      echo "  경고: untracked 파일이 있어 이대로는 ${SELFTEST_MODE} PASS 기록이 남지 않습니다 — 지금 git add 하지 않으면 실행이 끝난 뒤 다시 돌려야 합니다." >&2
      printf '%s\n' "$SELFTEST_START_UNTRACKED" | sed 's/^/    /' >&2
    elif [[ "$SELFTEST_START_USTATE" -eq 2 ]]; then
      # 조회 실패도 기록 거부 사유입니다. 여기서 침묵하면 사용자는 수 분을 쓰고 나서야
      # 증명이 남지 않는다는 것을 압니다 — 이 경고가 없애려던 손실이 이 경로에만 남습니다.
      echo "  경고: untracked 조회에 실패해(git 오류) 이대로는 ${SELFTEST_MODE} PASS 기록이 남지 않습니다." >&2
    fi
  fi
fi

run_step consumer "implementation_gate hook (test_implementation_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_implementation_gate.sh"
run_step consumer "리뷰 프롬프트 인라인 계약 (test_review_prompt_inline.sh)" bash "${SCRIPT_DIR}/test_review_prompt_inline.sh"
run_step consumer "reasoning effort override (test_review_effort_override.sh)" bash "${SCRIPT_DIR}/test_review_effort_override.sh"
run_step consumer "리뷰 턴 계측 계약 (test_review_metrics.sh)" bash "${SCRIPT_DIR}/test_review_metrics.sh"
run_step consumer "어댑터 프롬프트 parity (test_review_adapter_parity.sh)" bash "${SCRIPT_DIR}/test_review_adapter_parity.sh"
run_step consumer "state 단위 테스트 (test_state_common.sh)" bash "${SCRIPT_DIR}/test_state_common.sh"
run_step dev-only "smoke 판정 단위 테스트 (test_smoke_common.sh)" bash "${SCRIPT_DIR}/test_smoke_common.sh"
run_step consumer "smoke 진입점 계약 (test_self_test_smoke.sh)" bash "${SCRIPT_DIR}/test_self_test_smoke.sh"
run_step dev-only "smoke fixture 이름 규약 (check_fixture_name_convention.sh)" bash "${SCRIPT_DIR}/check_fixture_name_convention.sh"
run_step consumer "guard state fixture (test_guard_state.sh)" bash "${SCRIPT_DIR}/hooks/test_guard_state.sh"
run_step consumer "archive gate 테스트 (test_pre_commit_archive_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_pre_commit_archive_gate.sh"
run_step consumer "비차단 Status drift 검증 (nonblocking_status_drift_check)" nonblocking_status_drift_check
run_step consumer "LC-19 3자 일치 검증 (TASK/STATE/CLAUDE.md)" canonical_status_triple_drift_check
run_step dev-only "판정 소스 회귀 grep (_extract_task_section Status 직접 호출)" judgment_source_regression_check
run_step dev-only "stale active-fr/LIFECYCLE_METADATA_PATH 참조 회귀" stale_metadata_reference_check
run_step consumer "task CLI 단위 테스트" bash "${SCRIPT_DIR}/test_task_cli.sh"
run_step consumer "install_claude_skills 단위 테스트" bash "${SCRIPT_DIR}/test_install_claude_skills.sh"
run_step consumer "lifecycle 단위 테스트 (test_lifecycle.sh)" bash "${SCRIPT_DIR}/lifecycle/test_lifecycle.sh"
run_step consumer "lifecycle 통합 테스트 (test_integration.sh)" bash "${SCRIPT_DIR}/lifecycle/test_integration.sh"
run_step consumer "review 대기 계약 테스트 (test_review_wait.sh)" bash "${SCRIPT_DIR}/test_review_wait.sh"
run_step consumer "watchdog 계약·이식성 probe (test_watchdog_portability.sh)" bash "${SCRIPT_DIR}/test_watchdog_portability.sh"
run_step consumer "ralph_drain supervisor 테스트 (test_ralph_drain.sh)" bash "${SCRIPT_DIR}/test_ralph_drain.sh"
run_step consumer "batch_manifest 헬퍼 테스트 (batch/test_batch_manifest.sh)" bash "${SCRIPT_DIR}/batch/test_batch_manifest.sh"
run_step consumer "blocked status 어휘 일관성 (test_fr_blocked_status.sh)" bash "${SCRIPT_DIR}/test_fr_blocked_status.sh"
run_step consumer "autopilot blocked 계약 회귀 (test_autopilot_blocked_contract.sh)" bash "${SCRIPT_DIR}/test_autopilot_blocked_contract.sh"
run_step consumer "sync_template 타입 가드 테스트 (test_sync_template.sh)" bash "${SCRIPT_DIR}/test_sync_template.sh"
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
run_step consumer "결함 보고 로컬 조작부 테스트 (test_defect_reports.sh)" defect_reports_test_check
run_step dev-only "adapter 폴링 잔존 회귀 (POLL_INTERVAL 없음)" adapter_poll_regression_check
run_step consumer "스크립트 구문 검사 (bash -n)" syntax_check
run_step dev-only "autopilot SKILL lifecycle 정합 (promote/rollback 일원화)" autopilot_skill_lifecycle_check
run_step dev-only "무인 진입 계약 정합 (autopilot_headless_entry_check)" autopilot_headless_entry_check
run_step consumer "무인 wrapper 매핑 테스트 (test_autopilot_headless.sh)" bash "${SCRIPT_DIR}/test_autopilot_headless.sh"
run_step dev-only "phase 병렬 규약 문서 정합 (plan_parallel_phase_check)" plan_parallel_phase_check

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
run_step consumer "self_test 계약 (checker whitelist·root resolver)" hook_selftest_contract_check
run_step consumer "hook 경로 도달 증명 (hook_path_reachability_check)" hook_path_reachability_check
run_step consumer "hook 대상 실재 (hook_target_existence_check)" hook_target_existence_check
run_step dev-only "hook 표기 회귀 방지 (hook_path_notation_regression_check)" hook_path_notation_regression_check
run_step dev-only "템플릿 build 검증 (build_template.sh verify)" build_verify_check
run_step dev-only "템플릿 빌더 단위 테스트 (test_build_template.sh)" test_build_template_check
run_step dev-only "배포 미러 계약 (test_publish_mirror.sh)" test_publish_mirror_check
run_step dev-only "생성 full 트리 결함 보고 회귀 (generated_tree_defect_reports_check)" generated_tree_defect_reports_check
claudemd_size_check() {
  local checker="${SCRIPT_DIR}/check_claudemd_size.sh"
  if [[ -f "$checker" ]]; then bash "$checker"; else echo "  (skip: check_claudemd_size.sh 없음 — lite 산출물)"; fi
}
run_step consumer "CLAUDE.md 크기 제한 (check_claudemd_size.sh)" claudemd_size_check

print_skip_summary() {
  echo ""
  echo "== smoke 스킵 요약 =="
  echo "실제 스킵된 스텝 (${#SKIPPED_STEPS[@]}개) — 사유: 변경 파일이 이 스텝의 참조 폐포에 없습니다"
  # 빈 배열에 printf 를 그대로 걸면 빈 항목 한 줄이 찍히므로 건수가 있을 때만 출력합니다.
  if (( ${#SKIPPED_STEPS[@]} > 0 )); then
    printf '  - %s\n' "${SKIPPED_STEPS[@]}"
  fi
  echo "전체 검증: bash rd-workflow/scripts/self_test.sh full"
  # spec §5.3 preflight 역할 3 의 "경고를 남긴다" 절반입니다 — preflight 결과에 없는 스텝이
  # 실행되면(예: 최종 판정 exit 뒤에 붙은 run_step) 예정과 실제가 어긋나는데, 사용자가 두
  # 숫자를 직접 대조하지 않으면 알 수 없습니다.
  #
  # 이 대조는 **스킵 기록 누락도 런타임에 자기 신고**하게 만드는 이중 효과가 있습니다 —
  # 실제로 건너뛰면서 `SKIPPED_STEPS+=` 만 빠지면 `0 ≠ 25` 로 즉시 드러납니다.
  #
  # **stdout 이 아니라 stderr** 로 냅니다. 기존 케이스들이 stdout 의 `  - ` 줄과 건수 표기를
  # 파싱하므로 stdout 을 오염시키면 다른 단언이 깨집니다.
  # **rc 는 바꾸지 않습니다.** 이것은 fail-safe 신고이지 판정이 아니며, 판정까지 바꾸면
  # 커밋 전·아카이브 전 full 강제 설계와 얽힙니다.
  #
  # 대조는 **건수가 아니라 내용**으로 합니다. 건수만 보면 예정한 스텝 대신 다른 스텝이
  # 스킵된 상태(`1 == 1`)에서 침묵하고, "예정보다 더 많이 건너뛰는" 더 위험한 방향도
  # 조건을 `<` 로 바꾸는 것만으로 조용해집니다. 목록을 정렬해 비교하면 건수 불일치는
  # 자동으로 포함되고, 양쪽 방향과 내용 어긋남이 한 번에 잡힙니다.
  # 순서 비의존 비교인 이유: 두 목록 모두 `"<순번>. <설명>"` 이라 순번이 내용에 들어 있고,
  # 기록 순서 자체는 계약이 아니기 때문입니다.
  local _plan_n=${#SMOKE_SKIP_DESCS[@]} _done_n=${#SKIPPED_STEPS[@]} _plan_s _done_s
  _plan_s="$(printf '%s\n' ${SMOKE_SKIP_DESCS[@]+"${SMOKE_SKIP_DESCS[@]}"} | sort)"
  _done_s="$(printf '%s\n' ${SKIPPED_STEPS[@]+"${SKIPPED_STEPS[@]}"} | sort)"
  #
  # 정렬 불명이면 원인이 하나(순번 밀림)이므로 신고도 하나로 합칩니다 — 같은 사건을 두 문구로
  # 신고하면 사용자가 원인을 오판합니다. 침묵시키지도 않습니다: 정렬 불명은 rc 를 바꾸지 않아
  # **감축 효과만 조용히 사라지는** 상태이고, 이 1줄이 그것을 사용자에게 알리는 유일한
  # 장치입니다. 예정과 실제가 우연히 같은 경우에도(어긋남이 꼬리에서만 났을 때) 반드시 냅니다.
  if (( SMOKE_ALIGN_LOST )); then
    echo "== 경고: smoke 순번 정렬 불명 — 그 시점부터 스텝 감축이 사라졌습니다 ==" >&2
    echo "   순번 ${SMOKE_ALIGN_LOST_IDX} 이후 ${SMOKE_ALIGN_FORCED}개 스텝을 스킵 판정 없이 전부 실행했습니다 (스킵 예정 ${_plan_n}개 중 실제 ${_done_n}개만 스킵)." >&2
    echo "   이 결과를 검증 통과로 쓰지 말고 bash rd-workflow/scripts/self_test.sh full 로 전수 실행하십시오." >&2
  elif [[ "$_plan_s" != "$_done_s" ]]; then
    if (( _done_n != _plan_n )); then
      echo "== 경고: smoke 스킵 예정(${_plan_n}개)과 실제 스킵(${_done_n}개)이 다릅니다 ==" >&2
    else
      echo "== 경고: smoke 스킵 예정과 실제 스킵의 내용이 다릅니다 (건수는 ${_plan_n}개로 같습니다) ==" >&2
    fi
    echo "   preflight 가 알지 못하는 스텝이 실행됐거나 스킵 기록이 누락됐습니다." >&2
    echo "   이 결과를 검증 통과로 쓰지 말고 bash rd-workflow/scripts/self_test.sh full 로 전수 실행하십시오." >&2
  fi
}

# 청중 제외 요약 — `consumer` 모드에서 무엇이 빠졌는지 사용자에게 보입니다.
# 스킵 요약(smoke)과 **다른 축**이라 별 함수로 둡니다: smoke 는 "변경과 무관해서" 건너뛰고,
# 이쪽은 "이 프로젝트에서 판정할 대상이 아니라서" 제외합니다. 한 문구로 합치면 사용자가
# 감축 사유를 오해합니다.
print_audience_summary() {
  echo ""
  echo "== 청중 제외 요약 (consumer 모드) =="
  echo "청중 제외된 스텝 (${#AUDIENCE_EXCLUDED[@]}개) — 사유: dev-only (rd-workflow 정본 저작 규칙)"
  if (( ${#AUDIENCE_EXCLUDED[@]} > 0 )); then
    printf '  - %s\n' "${AUDIENCE_EXCLUDED[@]}"
  fi
  echo "이 실행은 전수 검증이 아닙니다. 정본 위생 검사까지: bash rd-workflow/scripts/self_test.sh full"
  # 예정(정적 집계)과 실제 제외가 어긋나면 배너가 사용자에게 거짓을 말한 것이므로 신고합니다.
  # rc 는 바꾸지 않습니다 — 신고이지 판정이 아닙니다.
  if [[ "${#AUDIENCE_EXCLUDED[@]}" -ne "$SELFTEST_AUD_DEVONLY" ]]; then
    echo "== 경고: 청중 제외 예정(${SELFTEST_AUD_DEVONLY}개)과 실제 제외(${#AUDIENCE_EXCLUDED[@]}개)가 다릅니다 ==" >&2
    echo "   배너가 표시한 범위와 실제 실행 범위가 어긋났습니다. full 로 전수 실행해 확인하십시오." >&2
  fi
}

# dry-run: 스텝을 실행하지 않고 실행/스킵 예정만 보고합니다 (무엇이 빠지는지 미리 확인하는 용도).
if [[ -n "${RD_SELFTEST_SMOKE_DRYRUN:-}" ]]; then
  # 스킵 요약은 smoke 모드에서만 의미가 있습니다. 모드 가드가 없으면 full 실행인데도
  # "smoke 스킵 요약" 이 나와 사용자가 축소 실행으로 오인합니다.
  # `[[ ... ]] && print_skip_summary` 로 쓰면 조건 거짓일 때 종료 상태 1이 되어
  # `set -e` 하에서 스크립트가 죽으므로 반드시 if 문으로 씁니다.
  if [[ "$SELFTEST_MODE" == "smoke" ]]; then
    print_skip_summary
  fi
  if [[ "$SELFTEST_MODE" == "consumer" ]]; then
    print_audience_summary
  fi
  echo ""
  echo "== 실행 예정 스텝 (${#STEP_NAMES[@]}개) =="
  if (( ${#STEP_NAMES[@]} > 0 )); then
    printf '  - %s\n' "${STEP_NAMES[@]}"
  fi
  exit 0
fi

# 실제 실행 경로의 스킵 요약입니다. 위 dry-run 블록은 `exit 0` 으로 끝나므로 두 번
# 출력되지 않습니다. 가드 형태를 dry-run 쪽과 같게 유지합니다 —
# `[[ ... ]] && print_skip_summary` 로 쓰면 full 모드에서 조건이 거짓일 때 그 문장이
# 블록의 마지막 명령이 되어 rc 1 이 되고, `set -e` 에 걸려 스크립트가 그 자리에서 죽습니다.
if [[ "$SELFTEST_MODE" == "smoke" ]]; then
  print_skip_summary
fi
if [[ "$SELFTEST_MODE" == "consumer" ]]; then
  print_audience_summary
fi

echo ""
echo "== 스텝별 소요 시간 (느린 순) =="
if ! print_step_summary; then
  echo "  (요약 출력 실패 — 최종 판정과 무관하게 계속 진행합니다)" >&2
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "== self_test 결과: PASS =="
  # full 통과 지문을 남깁니다 — **소비처는 아카이브 게이트 하나뿐입니다.**
  # (커밋 전 대조 게이트는 2026-08-20 에 제거됐습니다. 그때 이 안내를 함께 고치지 않아
  #  "다음 커밋이 막힌다" 는 있지도 않은 일을 예고했습니다 — 증명의 사용 시점을 잘못
  #  보여 주면 사용자가 대비할 지점을 놓칩니다.)
  # 기록 실패를 조용히 성공으로 표시하지 않습니다. 그러면 사용자는 아카이브가 막힐 때까지
  # 자기 상태가 증명되지 않았다는 사실을 모릅니다.
  if [[ "$SELFTEST_MODE" == "full" ]] && declare -F smoke_record_full_pass >/dev/null 2>&1; then
    if smoke_record_full_pass "$SELFTEST_ROOT" "$SELFTEST_START_FP" "$SELFTEST_START_USTATE"; then
      echo "  full PASS 지문을 기록했습니다 (아카이브 시점 대조에 사용됩니다)"
    else
      echo "  full PASS 지문을 기록하지 못했습니다 — 아카이브 시 full 재실행을 요구받습니다" >&2
    fi
  fi
  # consumer 증명은 **별 파일**에 남깁니다 (spec §7). full 증명 자리에 쓰면 부분 실행이
  # 전수 통과로 위장되고, 아무것도 남기지 않으면 게이트의 사후 대조가 항상 실패합니다.
  if [[ "$SELFTEST_MODE" == "consumer" ]] && declare -F smoke_record_consumer_pass >/dev/null 2>&1; then
    if smoke_record_consumer_pass "$SELFTEST_ROOT" "$SELFTEST_START_FP" "$SELFTEST_START_USTATE"; then
      echo "  consumer PASS 지문을 기록했습니다 (아카이브 시점 대조에 사용됩니다)"
    else
      echo "  consumer PASS 지문을 기록하지 못했습니다 — 아카이브 시 재실행을 요구받습니다" >&2
    fi
  fi
  exit 0
else
  echo "== self_test 결과: FAIL ==" >&2
  exit 1
fi
