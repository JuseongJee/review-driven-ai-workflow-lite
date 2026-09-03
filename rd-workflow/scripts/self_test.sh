#!/usr/bin/env bash
# 워크플로 인프라(rd-workflow) self-test entrypoint.
# 본 프로젝트와 generated project 공통으로 rd-workflow 인프라가 정상인지 검증한다.
# 제품 코드 테스트(test.sh/lint.sh/typecheck.sh)와는 책임이 다르다.
#
# 사용법: bash rd-workflow/scripts/self_test.sh [그룹...|all|consumer]
#   인자 없음 / all — 모든 스텝 (약 12분. 통합 테스트가 가장 길다)
#   <그룹>...       — 그 그룹의 스텝만. 그룹: hooks review lifecycle skills build
#                     (예: 리뷰 어댑터를 고쳤으면 `self_test.sh review`, 두 영역이면 나열)
#   consumer        — 소비 프로젝트에서 뜻이 있는 스텝만 (dev-only 정본 위생 검사 제외)
#   RD_SELFTEST_DRYRUN=1 — 실행하지 않고 실행 예정 스텝만 출력
#
# 2026-09-03: 변경 파일과 스텝의 참조 관계를 추적해 자동 감축하던 smoke 엔진과, 아카이브
# 시점에 검증 통과 증명을 대조·강제하던 게이트를 걷어냈다. 엔진은 판정이 틀려 매번 전수로
# 떨어졌고, 엔진 자신을 검사하는 테스트가 4분을 더 먹었다. 어느 스텝을 돌릴지는 사람이 그룹으로
# 고른다 — 판정 로직이 없으니 틀릴 것도 없다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFTEST_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SELFTEST_GROUPS_ALL="hooks review lifecycle skills build"
SELFTEST_MODE="all"          # all | consumer
SELFTEST_GROUPS=""           # 빈 값 = 모든 그룹
selftest_usage_exit() {
  echo "  사용법: bash rd-workflow/scripts/self_test.sh [그룹...|all|consumer]" >&2
  echo "    그룹: ${SELFTEST_GROUPS_ALL}" >&2
  echo "    consumer — 소비 프로젝트에서 뜻이 있는 스텝만 (dev-only 제외)" >&2
  echo "  dry-run: RD_SELFTEST_DRYRUN=1" >&2
  exit 1
}
for _arg in "$@"; do
  case "$_arg" in
    all|full) ;;
    consumer) SELFTEST_MODE="consumer" ;;
    hooks|review|lifecycle|skills|build) SELFTEST_GROUPS="${SELFTEST_GROUPS} ${_arg}" ;;
    *) echo "[self_test] 알 수 없는 인자입니다: $_arg" >&2; selftest_usage_exit ;;
  esac
done

FAIL=0
STEP_INDEX=0
STEP_NAMES=()
STEP_DURATIONS=()
AUDIENCE_EXCLUDED=()
GROUP_EXCLUDED=()

# 사용법: run_step <그룹> <consumer|dev-only> "<설명>" <명령...>
#
# 그룹은 사람이 실행 범위를 고르는 단위다 (hooks review lifecycle skills build).
# 청중은 필수 인자다. 기본값을 두지 않는 이유 — `consumer` 기본값은 현상 유지라
# 다음에 추가되는 정본 위생 검사가 또 소비처의 아카이브를 막고, `dev-only` 기본값은 새
# 검사가 조용히 소비처 검증에서 빠진다. 필수 인자는 두 실패를 동시에 피한다.
run_step() {
  local group="${1-}" audience="${2-}" desc
  case " ${SELFTEST_GROUPS_ALL} " in
    *" ${group} "*) shift ;;
    *)
      STEP_INDEX=$((STEP_INDEX + 1))
      echo ""
      echo "== 스텝 ${STEP_INDEX}: 그룹 선언 오류 =="
      echo "  -> FAIL: 그룹이 없거나 허용값이 아닙니다: '${group}' (${SELFTEST_GROUPS_ALL} 중 하나여야 합니다)" >&2
      FAIL=1
      return 0
      ;;
  esac
  case "$audience" in
    consumer|dev-only) shift ;;
    *)
      # 조용한 skip 이 아니라 FAIL 이다. skip 하면 청중을 빠뜨린 스텝이 검증에서
      # 사라지면서 rc 는 0 이 되어, 필수화 자체가 무력해진다.
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
  # 청중 필터 — `consumer` 모드는 정본 위생 검사(dev-only)를 실행하지 않는다.
  if [[ "$SELFTEST_MODE" == "consumer" && "$audience" == "dev-only" ]]; then
    AUDIENCE_EXCLUDED+=("${STEP_INDEX}. ${desc}")
    return 0
  fi
  # 그룹 필터 — 지정된 그룹이 있으면 그 밖의 스텝은 건너뛰고 기록한다.
  if [[ -n "$SELFTEST_GROUPS" ]]; then
    case " ${SELFTEST_GROUPS} " in
      *" ${group} "*) ;;
      *) GROUP_EXCLUDED+=("${STEP_INDEX}. [${group}] ${desc}"); return 0 ;;
    esac
  fi
  # dry-run 은 실행하지 않고 실행 예정으로만 기록합니다.
  if [[ -n "${RD_SELFTEST_DRYRUN:-}" ]]; then
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
  root_dir="$(_hook_repo_root)"

  # 루트 CLAUDE.md 는 필수, _ROOT_FILES 정본은 설치본에 없는 것이 정상이라 선택이다.
  # 둘 다 선택으로 두면 루트 CLAUDE.md 가 통째로 사라져도 0건 검사로 통과한다.
  local targets=() root_cm="${root_dir}/CLAUDE.md"
  [[ -f "$root_cm" ]] || { echo "  $root_cm: 필수 파일 부재" >&2; rc=1; }
  targets+=("$root_cm")
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
  root_dir="$(_hook_repo_root)"

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

  # CLAUDE.md 허용 상태값 목록 확인 (모든 대상 CLAUDE.md에서).
  # 루트 CLAUDE.md 는 필수, _ROOT_FILES 정본은 설치본에 없는 것이 정상이라 선택이다.
  # 둘 다 선택으로 두면 루트 CLAUDE.md 가 통째로 사라져도 0건 검사로 통과한다.
  local targets=() root_cm="${root_dir}/CLAUDE.md"
  [[ -f "$root_cm" ]] || { echo "  $root_cm: 필수 파일 부재" >&2; rc=1; }
  targets+=("$root_cm")
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


autopilot_skill_lifecycle_check() {
  # 배포 사본은 필수, _ROOT_FILES 정본은 설치본에 없는 것이 정상이라 선택이다.
  # 둘 다 선택으로 두면 배포 사본이 통째로 사라져도 0건 검사로 통과한다
  # (autopilot_headless_entry_check 의 skill_root 패턴과 동일).
  local rc=0 skill skill_root="${SCRIPT_DIR}/../claude_skills/autopilot/SKILL.md"
  [[ -f "$skill_root" ]] || { echo "  $skill_root: 필수 파일 부재" >&2; rc=1; }
  for skill in \
    "$skill_root" \
    "${SCRIPT_DIR}/../../_ROOT_FILES/rd-workflow/claude_skills/autopilot/SKILL.md"; do
    [[ -f "$skill" ]] || continue
    grep -q 'promote.sh --short-title' "$skill" || { echo "  $skill: promote.sh --short-title 미참조" >&2; rc=1; }
    grep -q 'promote_rollback.sh' "$skill" || { echo "  $skill: promote_rollback.sh 미참조" >&2; rc=1; }
    if grep -q 'checkout -b autopilot' "$skill"; then echo "  $skill: autopilot/* 직접 생성 잔존" >&2; rc=1; fi
    if grep -q 'autopilot/<' "$skill"; then echo "  $skill: autopilot/<...> 표기 잔존" >&2; rc=1; fi
    if grep -q 'checkout master' "$skill"; then echo "  $skill: master 표기 잔존" >&2; rc=1; fi
    if grep -q 'branch -D autopilot' "$skill"; then echo "  $skill: branch -D autopilot 잔존" >&2; rc=1; fi

    # 승격 명령 계약은 별도 스크립트가 판정한다 — 인라인이면 테스트가 그 로직을
    # 재사용할 수 없어 "검사가 실제로 오용을 잡는가" 를 자동으로 확인할 수 없다
    # (final diff review 4라운드 Finding 3). fixture 회귀는 test_task_cli.sh 에 있다.
    if ! bash "${SCRIPT_DIR}/check_autopilot_promote_contract.sh" "$skill"; then
      echo "  $skill: 승격 명령 계약 위반 (위 사유 참조)" >&2
      rc=1
    fi
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

# `_hook_repo_root()` 가 정본·설치본 양쪽 레이아웃에서 프로젝트 루트를 맞히는지 검사한다.
# 세 검사 함수(nonblocking/canonical/stale)를 직접 부르지 않는 이유: 각자 다른 대상을
# 읽어 실패 원인이 섞인다. 경로 계산의 정확성만 고립해 본다.
root_dir_layout_check() {
  local rc=0 tmp got want
  tmp="$(mktemp -d)" || { echo "  임시 디렉터리 생성 실패" >&2; return 1; }

  # (a) 정본 레이아웃: <repo>/_ROOT_FILES/rd-workflow/scripts + <repo>/scripts/build_template.sh
  mkdir -p "${tmp}/repo/_ROOT_FILES/rd-workflow/scripts" "${tmp}/repo/scripts"
  : > "${tmp}/repo/scripts/build_template.sh"
  # (b) 설치본 레이아웃: <proj>/rd-workflow/scripts
  mkdir -p "${tmp}/proj/rd-workflow/scripts"
  # (c) 함정: 저장소 디렉터리 이름 자체가 _ROOT_FILES (build_template.sh 없음)
  mkdir -p "${tmp}/_ROOT_FILES/rd-workflow/scripts"

  got="$( SCRIPT_DIR="${tmp}/repo/_ROOT_FILES/rd-workflow/scripts"; _hook_repo_root )"
  want="$(cd "${tmp}/repo" && pwd)"
  if [[ "$got" != "$want" ]]; then
    echo "  정본 레이아웃 불일치: got='${got}' want='${want}'" >&2; rc=1
  fi

  got="$( SCRIPT_DIR="${tmp}/proj/rd-workflow/scripts"; _hook_repo_root )"
  want="$(cd "${tmp}/proj" && pwd)"
  if [[ "$got" != "$want" ]]; then
    echo "  설치본 레이아웃 불일치: got='${got}' want='${want}'" >&2; rc=1
  fi

  got="$( SCRIPT_DIR="${tmp}/_ROOT_FILES/rd-workflow/scripts"; _hook_repo_root )"
  want="$(cd "${tmp}/_ROOT_FILES" && pwd)"
  if [[ "$got" != "$want" ]]; then
    echo "  이름만 _ROOT_FILES 인 경우 불일치: got='${got}' want='${want}'" >&2; rc=1
  fi

  rm -rf "$tmp"
  return "$rc"
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
    # 필수 대상 결손 회귀는 변형을 주입해 판별력을 확인해야 하므로 단독 실행 경로가 필요하다.
    required_target_regression_check) ;;
    *)
      echo "[self_test] RD_SELFTEST_CHECKER_ONLY 허용값이 아닙니다: ${RD_SELFTEST_CHECKER_ONLY}" >&2
      echo "  허용: hook_path_reachability_check | hook_target_existence_check | hook_path_notation_regression_check | hook_selftest_contract_check | required_target_regression_check | _hook_repo_root" >&2
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

# 등록부를 **실행하지 않고** 청중 분포를 셉니다. 배너와 정적 검사(청중 미선언 0건)가 함께
# 씁니다. 미선언 스텝은 추출식(`^run_step <청중> "설명"`)에 매치되지 않으므로,
# `grep -c '^run_step '` 과 추출 행수의 차이가 곧 미선언 건수입니다.
SELFTEST_AUD_TOTAL=0
SELFTEST_AUD_CONSUMER=0
SELFTEST_AUD_DEVONLY=0
SELFTEST_AUD_UNDECLARED=0
selftest_count_audiences() {
  local self="$1" raw declared
  raw="$(grep -c '^run_step ' "$self" 2>/dev/null || true)"; [[ -n "$raw" ]] || raw=0
  SELFTEST_AUD_CONSUMER="$(grep -cE '^run_step [a-z]+ consumer ' "$self" 2>/dev/null || true)"; [[ -n "$SELFTEST_AUD_CONSUMER" ]] || SELFTEST_AUD_CONSUMER=0
  SELFTEST_AUD_DEVONLY="$(grep -cE '^run_step [a-z]+ dev-only ' "$self" 2>/dev/null || true)"; [[ -n "$SELFTEST_AUD_DEVONLY" ]] || SELFTEST_AUD_DEVONLY=0
  declared=$((SELFTEST_AUD_CONSUMER + SELFTEST_AUD_DEVONLY))
  SELFTEST_AUD_TOTAL="$raw"
  SELFTEST_AUD_UNDECLARED=$((raw - declared))
  (( SELFTEST_AUD_UNDECLARED < 0 )) && SELFTEST_AUD_UNDECLARED=0
  return 0
}
selftest_count_audiences "${BASH_SOURCE[0]}" || true

echo "== self_test 실행 범위 =="
if [[ "$SELFTEST_MODE" == "consumer" ]]; then
  echo "  모드: consumer — dev-only 정본 위생 검사 제외 (${SELFTEST_AUD_DEVONLY}스텝)"
else
  echo "  모드: all — 전체 ${SELFTEST_AUD_TOTAL}스텝"
fi
if [[ -n "$SELFTEST_GROUPS" ]]; then
  echo "  그룹:${SELFTEST_GROUPS} (그 밖의 스텝은 건너뜁니다)"
fi
if (( SELFTEST_AUD_UNDECLARED > 0 )); then
  echo "  경고: 청중을 선언하지 않은 스텝이 ${SELFTEST_AUD_UNDECLARED}건 있습니다 — 해당 스텝은 FAIL 로 보고됩니다" >&2
fi
if [[ -n "${RD_SELFTEST_DRYRUN:-}" ]]; then
  echo "== self_test: dry-run 모드 — 스텝을 하나도 실행하지 않습니다 (검증 결과 아님) ==" >&2
fi

run_step hooks consumer "implementation_gate hook (test_implementation_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_implementation_gate.sh"
run_step review consumer "리뷰 프롬프트 인라인 계약 (test_review_prompt_inline.sh)" bash "${SCRIPT_DIR}/test_review_prompt_inline.sh"
run_step review consumer "reasoning effort override (test_review_effort_override.sh)" bash "${SCRIPT_DIR}/test_review_effort_override.sh"
run_step review consumer "리뷰 턴 계측 계약 (test_review_metrics.sh)" bash "${SCRIPT_DIR}/test_review_metrics.sh"
run_step review consumer "어댑터 프롬프트 parity (test_review_adapter_parity.sh)" bash "${SCRIPT_DIR}/test_review_adapter_parity.sh"
run_step lifecycle consumer "state 단위 테스트 (test_state_common.sh)" bash "${SCRIPT_DIR}/test_state_common.sh"
run_step hooks consumer "guard state fixture (test_guard_state.sh)" bash "${SCRIPT_DIR}/hooks/test_guard_state.sh"
run_step hooks consumer "archive gate 테스트 (test_pre_commit_archive_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_pre_commit_archive_gate.sh"
run_step lifecycle consumer "비차단 Status drift 검증 (nonblocking_status_drift_check)" nonblocking_status_drift_check
run_step lifecycle consumer "LC-19 3자 일치 검증 (TASK/STATE/CLAUDE.md)" canonical_status_triple_drift_check
run_step lifecycle consumer "task CLI 단위 테스트" bash "${SCRIPT_DIR}/test_task_cli.sh"
run_step skills consumer "install_claude_skills 단위 테스트" bash "${SCRIPT_DIR}/test_install_claude_skills.sh"
run_step lifecycle consumer "lifecycle 단위 테스트 (test_lifecycle.sh)" bash "${SCRIPT_DIR}/lifecycle/test_lifecycle.sh"
run_step lifecycle consumer "lifecycle 통합 테스트 (test_integration.sh)" bash "${SCRIPT_DIR}/lifecycle/test_integration.sh"
run_step review consumer "review 대기 계약 테스트 (test_review_wait.sh)" bash "${SCRIPT_DIR}/test_review_wait.sh"
run_step review consumer "watchdog 계약·이식성 probe (test_watchdog_portability.sh)" bash "${SCRIPT_DIR}/test_watchdog_portability.sh"
run_step skills consumer "ralph_drain supervisor 테스트 (test_ralph_drain.sh)" bash "${SCRIPT_DIR}/test_ralph_drain.sh"
run_step skills consumer "batch_manifest 헬퍼 테스트 (batch/test_batch_manifest.sh)" bash "${SCRIPT_DIR}/batch/test_batch_manifest.sh"
run_step skills consumer "blocked status 어휘 일관성 (test_fr_blocked_status.sh)" bash "${SCRIPT_DIR}/test_fr_blocked_status.sh"
run_step skills consumer "autopilot blocked 계약 회귀 (test_autopilot_blocked_contract.sh)" bash "${SCRIPT_DIR}/test_autopilot_blocked_contract.sh"
run_step skills consumer "sync_template 타입 가드 테스트 (test_sync_template.sh)" bash "${SCRIPT_DIR}/test_sync_template.sh"
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
run_step skills consumer "결함 보고 로컬 조작부 테스트 (test_defect_reports.sh)" defect_reports_test_check
run_step build consumer "스크립트 구문 검사 (bash -n)" syntax_check
run_step skills dev-only "autopilot SKILL lifecycle 정합 (promote/rollback 일원화)" autopilot_skill_lifecycle_check
run_step skills dev-only "무인 진입 계약 정합 (autopilot_headless_entry_check)" autopilot_headless_entry_check
run_step skills consumer "무인 wrapper 매핑 테스트 (test_autopilot_headless.sh)" bash "${SCRIPT_DIR}/test_autopilot_headless.sh"
run_step skills dev-only "phase 병렬 규약 문서 정합 (plan_parallel_phase_check)" plan_parallel_phase_check
# dev-only 인 이유: 점검 대상에 `scripts/` 가 있고 배포본에는 그 디렉터리가 없다.
# 루트는 `_hook_repo_root` 로 구한다 — `SELFTEST_ROOT` 는 정본 레이아웃에서
# `_ROOT_FILES` 를 가리켜 점검 대상 판정이 어긋난다.
run_step lifecycle dev-only "promote 활성 호출처가 시작 상태 인자를 갖는지 (AC 7)" \
  bash "${SCRIPT_DIR}/check_promote_call_args.sh" "$(_hook_repo_root)"

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


run_step hooks consumer "hook 경로 도달 증명 (hook_path_reachability_check)" hook_path_reachability_check
run_step hooks consumer "hook 대상 실재 (hook_target_existence_check)" hook_target_existence_check
run_step build dev-only "프로젝트 루트 계산 양쪽 레이아웃 (root_dir_layout_check)" root_dir_layout_check
run_step build dev-only "템플릿 build 검증 (build_template.sh verify)" build_verify_check
run_step build dev-only "템플릿 빌더 단위 테스트 (test_build_template.sh)" test_build_template_check
run_step build dev-only "배포 미러 계약 (test_publish_mirror.sh)" test_publish_mirror_check
claudemd_size_check() {
  local checker="${SCRIPT_DIR}/check_claudemd_size.sh"
  if [[ -f "$checker" ]]; then bash "$checker"; else echo "  (skip: check_claudemd_size.sh 없음 — lite 산출물)"; fi
}
run_step build consumer "CLAUDE.md 크기 제한 (check_claudemd_size.sh)" claudemd_size_check


# 청중 제외 요약 — `consumer` 모드에서 무엇이 빠졌는지 사용자에게 보입니다.
print_audience_summary() {
  echo ""
  echo "== 청중 제외 요약 (consumer 모드) =="
  echo "청중 제외된 스텝 (${#AUDIENCE_EXCLUDED[@]}개) — 사유: dev-only (rd-workflow 정본 저작 규칙)"
  if (( ${#AUDIENCE_EXCLUDED[@]} > 0 )); then
    printf '  - %s\n' "${AUDIENCE_EXCLUDED[@]}"
  fi
  echo "이 실행은 전수 검증이 아닙니다. 정본 위생 검사까지: bash rd-workflow/scripts/self_test.sh"
  # 예정(정적 집계)과 실제 제외가 어긋나면 배너가 사용자에게 거짓을 말한 것이므로 신고합니다.
  # rc 는 바꾸지 않습니다 — 신고이지 판정이 아닙니다.
  if [[ "${#AUDIENCE_EXCLUDED[@]}" -ne "$SELFTEST_AUD_DEVONLY" ]]; then
    echo "== 경고: 청중 제외 예정(${SELFTEST_AUD_DEVONLY}개)과 실제 제외(${#AUDIENCE_EXCLUDED[@]}개)가 다릅니다 ==" >&2
    echo "   배너가 표시한 범위와 실제 실행 범위가 어긋났습니다. full 로 전수 실행해 확인하십시오." >&2
  fi
}

print_group_summary() {
  if (( ${#GROUP_EXCLUDED[@]} > 0 )); then
    echo ""
    echo "== 그룹 밖 스텝 (${#GROUP_EXCLUDED[@]}개, 실행하지 않음 — 지정 그룹:${SELFTEST_GROUPS}) =="
    printf '  - %s\n' "${GROUP_EXCLUDED[@]}"
    echo "전체 실행: bash rd-workflow/scripts/self_test.sh"
  fi
}

# dry-run: 스텝을 실행하지 않고 실행 예정만 보고한다.
if [[ -n "${RD_SELFTEST_DRYRUN:-}" ]]; then
  print_group_summary
  if [[ "$SELFTEST_MODE" == "consumer" ]]; then print_audience_summary; fi
  echo ""
  echo "== 실행 예정 스텝 (${#STEP_NAMES[@]}개) =="
  if (( ${#STEP_NAMES[@]} > 0 )); then printf '  - %s\n' "${STEP_NAMES[@]}"; fi
  exit 0
fi

print_group_summary
if [[ "$SELFTEST_MODE" == "consumer" ]]; then print_audience_summary; fi

echo ""
echo "== 스텝별 소요 시간 (느린 순) =="
if ! print_step_summary; then
  echo "  (요약 출력 실패 — 최종 판정과 무관하게 계속 진행합니다)" >&2
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "== self_test 결과: PASS =="
  exit 0
else
  echo "== self_test 결과: FAIL ==" >&2
  exit 1
fi