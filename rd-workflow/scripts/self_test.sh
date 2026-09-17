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

# 차단 가드의 테스트는 **실제 hook** 을 부르고 hook 은 자기 위치에서 project_root 를 도출하므로,
# 그냥 두면 검증이 저장소의 차단 감사 로그에 쓴다 (실측: hooks 한 번에 28줄). 그러면 로그가
# 테스트 잡음으로 채워져 「이 가드가 무엇을 막았나」를 볼 수 없다. 실행 동안 임시 경로로 돌린다.
if [ -z "${RD_GUARD_BLOCK_LOG:-}" ]; then
  RD_GUARD_BLOCK_LOG="$(mktemp -t rd-guard-block-log.XXXXXX 2>/dev/null)" \
    || RD_GUARD_BLOCK_LOG="/dev/null"
  export RD_GUARD_BLOCK_LOG
fi
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

SCAN_AWK="${SCRIPT_DIR}/_mktemp_scan.awk"
# 2026-09-10 task-guard-source-fr-contract: guard·reset·fr-done·미러 회귀 픽스처가
# 임시 트리를 9개 더 만듭니다 (120 → 129, final diff review F1~F6 회귀 픽스처 3개 포함).
# 위반은 0 이고 증가분은 전부 테스트 픽스처입니다.
# 2026-09-15 submodule-overlay-install-structure: overlay_branch_sync 3종 스크립트
# 폐기로 test_overlay_branch_sync.sh 의 mktemp 지점 2개가 함께 사라졌습니다 (129 → 127).
# 2026-09-16 worktree-parallel-agent-launch: worktree 병렬 착수 스위트가 임시 저장소를
# 더 만듭니다 (127 → 134). 증가분은 신규 스위트 4종(test_tasks_index·test_session_launch·
# test_tasks_list·test_archive_worktree)과 test_lifecycle.sh 의 추가 시나리오이고,
# promote.sh 는 재설계로 1 줄었습니다. 위반은 0 입니다.
# 2026-09-16 final diff review 턴 004: 색인 격리 회귀(test_tasks_index.sh 의 `OTHER`)를
# 추가해 배포 트리의 mktemp -d 지점이 1개 늘었습니다 (134 → 135). 위반은 0 입니다.
MKTEMP_SCAN_EXPECT_SHELL=135
# 2026-09-14 publish-clone-failure-init-fallback: scripts/test_publish_remote_state.sh
# 신설로 개발 트리의 mktemp -d 지점이 1개 늘었습니다 (49 → 50). 위반은 0 이고
# 증가분은 테스트 픽스처입니다.
MKTEMP_SCAN_EXPECT_DEV_SHELL=50
MKTEMP_SCAN_EXPECT_SNIPPET=2
# spec §3.5 예측은 47(baseline 42 + archive.sh:196 1→4줄 +3 + test_integration.sh:314·359
# 각 1→2줄 +2)이었지만 실측은 48입니다. 어긋난 쪽은 spec 의 baseline 42 입니다 —
# 그 수동 집계가 defect_reports.sh:80(`_tmp_beside`)의 bare 호출 `mktemp "${dir}/..."`
# (반환값을 함수 stdout 으로 흘리는 형태)을 빠뜨렸습니다. baseline 트리(de050196)를 실제로
# 스캔하면 43 이고, 43 + 5 = 48 로 산식이 정확히 맞습니다(위반은 baseline 19 → 현재 0).
# 위와 같은 픽스처 증가분 5 (48 → 53).
# 2026-09-16 worktree-parallel-agent-launch: session_launch.sh 가 herdr 응답을 받는
# 임시 파일 5개를 쓰고 test_integration.sh 가 1개 늘었습니다 (53 → 60). 위반은 0 입니다 —
# 네 지점 모두 mktemp 실패를 함수의 상태 계약(failed / unknown) 안에서 끝냅니다.
MKTEMP_SCAN_EXPECT_FILE=60
MKTEMP_SCAN_EXPECT_DEV_FILE=1

# `set -u` 하에서 참조가 중단되지 않도록 파일 스코프에서 먼저 정의합니다.
_SCAN_SITES=""
_SCAN_VIOLATIONS=""
_SCAN_DETAIL=""

# 표식 한 줄. 성공·실패·skip 모든 경로에서 반환 직전에 호출합니다.
# $1=step $2=result $3=reason $4=files $5=sites $6=violations $7=ex_files $8=ex_sites
_mktemp_scan_marker() {
  printf 'mktemp-guard-scan: step=%s result=%s reason=%s files=%s sites=%s violations=%s excluded_test_files=%s excluded_test_sites=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# 스캐너를 돌려 결과를 **전역 3개**에 담습니다. rc 0 = 성공, 1 = scanner-error.
# $1=mode(dir|file) — awk 의 mode 분기 그대로. "dir"이면 기존과 동일하게 -v mode 를
# 넘기지 않습니다(디렉터리 모드가 awk 의 기본 동작이라 그대로 두어야 변경이 없습니다).
#
# **명령 치환으로 호출하지 않습니다.** 명령 치환은 서브셸이라 전역 변경이 부모에 남지
# 않습니다 (실측: `s="$(raw)"` 뒤 부모 값이 그대로였음 — Turn 004 Finding 1).
# 호출부는 이 함수를 직접 부르고 `_SCAN_SITES`·`_SCAN_VIOLATIONS`·`_SCAN_DETAIL` 을 읽습니다.
_mktemp_scan_raw() {
  local mode="$1"; shift
  local out summary
  _SCAN_SITES=""; _SCAN_VIOLATIONS=""; _SCAN_DETAIL=""
  # 인자가 없으면 awk 가 stdin 을 읽으므로 실행 전에 막습니다 (Turn 004 Finding 2-D).
  (( $# > 0 )) || return 1
  # 빈 배열 `"${arr[@]}"` 는 bash 3.2(macOS 기본)의 `set -u` 하에서 "unbound variable"을
  # 냅니다 — 배열로 옵션을 만들지 않고 분기로 피합니다.
  if [[ "$mode" == "dir" ]]; then
    out="$(awk -f "$SCAN_AWK" "$@" 2>&1)" || return 1
  else
    out="$(awk -v "mode=$mode" -f "$SCAN_AWK" "$@" 2>&1)" || return 1
  fi
  # SUMMARY 는 정확히 한 줄이고 필드가 3개이며 두 값이 십진 숫자여야 합니다.
  # (Turn 004 Finding 2-C: 이전 case 검사는 `1`·`1 `·`1 2 3` 을 모두 통과시켰습니다.)
  summary="$(printf '%s\n' "$out" | awk -F'\t' '
    $1=="SUMMARY" { c++; if (NF==3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) { s=$2; v=$3; ok=1 } else ok=0 }
    END { if (c==1 && ok==1) print s"\t"v }')"
  [[ -n "$summary" ]] || return 1
  _SCAN_SITES="${summary%%$'\t'*}"
  _SCAN_VIOLATIONS="${summary##*$'\t'}"
  _SCAN_DETAIL="$(printf '%s\n' "$out" | awk -F'\t' '$1=="VIOLATION"{printf "  위반 %s:%s (%s) %s\n", $2, $3, $4, $5}')"
  return 0
}

# 공통 판정. $1=step $2=mode(dir|file) $3=기대 후보 수 $4=ex_files $5=ex_sites, 나머지는 검사할 파일들.
_mktemp_scan_run() {
  local step="$1" mode="$2" expect="$3" exf="$4" exs="$5"; shift 5
  local nfiles=$#
  if ! _mktemp_scan_raw "$mode" "$@"; then
    _mktemp_scan_marker "$step" fail scanner-error "$nfiles" 0 0 "$exf" "$exs"
    echo "  스캐너 실행 실패 또는 출력이 계약에 맞지 않습니다" >&2
    return 1
  fi

  # reason 우선순위: scanner-error > missing-dir > missing-file > template-violation > count-mismatch
  # (앞의 셋은 호출부가 먼저 처리합니다)
  if [[ "$_SCAN_VIOLATIONS" -gt 0 ]]; then
    [[ -n "$_SCAN_DETAIL" ]] && printf '%s\n' "$_SCAN_DETAIL" >&2
    printf '  기대 후보 수 %s / 실제 %s\n' "$expect" "$_SCAN_SITES" >&2
    _mktemp_scan_marker "$step" fail template-violation "$nfiles" "$_SCAN_SITES" "$_SCAN_VIOLATIONS" "$exf" "$exs"
    return 1
  fi
  if [[ "$_SCAN_SITES" != "$expect" ]]; then
    printf '  기대 후보 수 %s / 실제 %s — 의도적 변경이면 기대값을 갱신하십시오\n' "$expect" "$_SCAN_SITES" >&2
    _mktemp_scan_marker "$step" fail count-mismatch "$nfiles" "$_SCAN_SITES" "$_SCAN_VIOLATIONS" "$exf" "$exs"
    return 1
  fi
  _mktemp_scan_marker "$step" pass none "$nfiles" "$_SCAN_SITES" "$_SCAN_VIOLATIONS" "$exf" "$exs"
  return 0
}

# 스텝 1 — 배포 셸 스크립트. 스캐너 자신을 제외한 전체 *.sh 를 봅니다.
# (2026-09-10: basename 이 test_ 로 시작하는 파일을 빼던 제외 규칙을 걷어냈습니다 — 테스트
# 스크립트도 무방비 mktemp -d 를 낼 수 있어 감시 사각지대였습니다. exf·exs 필드는 형식
# 계약이라 남기되 항상 0 입니다 — 0 은 「제외 없음」을 적극적으로 보여 줍니다.)
mktemp_guard_scan_shell() {
  local f exf=0 exs=0 raw
  local -a keep=()
  # 열거 실패를 성공으로 보지 않습니다. 프로세스 치환(`done < <(find ...)`)의 rc 는 부모에
  # 전달되지 않으므로(pipefail 도 전달하지 않습니다), find 가 하위 디렉터리 권한 오류로 일부만
  # 출력한 뒤 실패해도 그 부분 목록만 검사하고 후보 총계가 우연히 맞으면 pass 가 납니다 —
  # 검사 범위가 불완전한데 검증 완료로 안내하는 것이 이 스텝이 막으려는 결함과 같은 부류입니다.
  # 선언과 대입을 분리합니다: `local raw="$(...)"` 의 rc 는 선언 builtin 의 것이라 항상 0 입니다.
  raw="$(find "${SCRIPT_DIR}" -type f -name "*.sh")" || {
    _mktemp_scan_marker shell fail scanner-error 0 0 0 0 0
    echo "  검사 대상 파일 열거 실패 (find rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  # 정렬 대입의 rc 도 같은 방식으로 확인합니다. 명령 치환 대입의 실패는 `if "$@"` 호출 문맥에서
  # errexit 가 유예되어 함수를 멈추지 않으므로, sort 가 부분 출력 후 실패하면 줄어든 목록을
  # 그대로 검사하고 후보 없는 파일만 빠진 경우 sites 가 유지되어 pass 가 납니다.
  # `pipefail` 에 의존하지 않고 단계마다 명시적으로 판정합니다 (옵션이 바뀌어도 조용히 깨지지 않게).
  raw="$(printf '%s\n' "$raw" | LC_ALL=C sort)" || {
    _mktemp_scan_marker shell fail scanner-error 0 0 0 0 0
    echo "  검사 대상 목록 정렬 실패 (sort rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == "$SCAN_AWK" ]] && continue
    keep+=("$f")
  done <<< "$raw"

  _mktemp_scan_run shell dir "$MKTEMP_SCAN_EXPECT_SHELL" "$exf" "$exs" "${keep[@]}"
}

# 스텝 — 개발 트리 저장소 루트의 `scripts/`. 배포 스캐너(`shell`)는 `${SCRIPT_DIR}` 하위만
# 보므로 저장소 루트 `scripts/` (계열 A·D)를 보지 못한다. 같은 강한 템플릿 판정을 그대로
# 재사용해 별도로 스캔한다 (`_mktemp_scan_run` 재사용 — 표식 형식·reason 어휘가 자동 일치).
# dev-only 스텝은 개발 트리에서만 도는 것이 보장되므로 정본 디렉터리 부재는 skip 이 아니라
# fail 이다 (`mktemp_guard_scan_canon_snippet` 과 같은 판단).
mktemp_guard_scan_dev_shell() {
  local root dir raw
  local -a keep=()
  root="$(_hook_repo_root)" || {
    _mktemp_scan_marker dev-shell fail missing-dir 0 0 0 0 0
    echo "  정본 저장소 루트를 찾지 못했습니다" >&2; return 1
  }
  dir="${root}/scripts"
  if [[ ! -d "$dir" ]]; then
    _mktemp_scan_marker dev-shell fail missing-dir 0 0 0 0 0
    echo "  개발 트리 scripts/ 가 없습니다: $dir" >&2; return 1
  fi
  raw="$(find "$dir" -type f -name "*.sh")" || {
    _mktemp_scan_marker dev-shell fail scanner-error 0 0 0 0 0
    echo "  검사 대상 파일 열거 실패 (find rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  raw="$(printf '%s\n' "$raw" | LC_ALL=C sort)" || {
    _mktemp_scan_marker dev-shell fail scanner-error 0 0 0 0 0
    echo "  검사 대상 목록 정렬 실패 (sort rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    keep+=("$f")
  done <<< "$raw"

  _mktemp_scan_run dev-shell dir "$MKTEMP_SCAN_EXPECT_DEV_SHELL" 0 0 "${keep[@]}"
}

# 스텝 — 파일 `mktemp` 약한 검사(배포 셸). 디렉터리 모드(`shell`)와 같은 범위를 보되
# 판정은 다릅니다 — 강한 템플릿 대조가 아니라 「인접 두 논리 줄에 || 가 있는가」만 봅니다.
# 이 검사는 인접한 두 논리 줄 어디에도 `||` 가 전혀 없는 후보만 탐지합니다. `||` 가
# 있으나 빈 값 검사가 빠진 경우, `|| true` 같은 무력한 핸들러, 그 `||` 가 `mktemp` 와
# 무관한 다른 명령에 붙은 경우, 주석·문자열 안의 `||`, 그리고 실행으로 인정하지 않는 위치
# (`if ... then mktemp ...` 한 줄 실행, 서브셸 `( mktemp ... )`) 는 잡지 못합니다.
mktemp_guard_scan_file() {
  local f exf=0 exs=0 raw
  local -a keep=()
  raw="$(find "${SCRIPT_DIR}" -type f -name "*.sh")" || {
    _mktemp_scan_marker file fail scanner-error 0 0 0 0 0
    echo "  검사 대상 파일 열거 실패 (find rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  raw="$(printf '%s\n' "$raw" | LC_ALL=C sort)" || {
    _mktemp_scan_marker file fail scanner-error 0 0 0 0 0
    echo "  검사 대상 목록 정렬 실패 (sort rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == "$SCAN_AWK" ]] && continue
    keep+=("$f")
  done <<< "$raw"

  _mktemp_scan_run file file "$MKTEMP_SCAN_EXPECT_FILE" "$exf" "$exs" "${keep[@]}"
}

# 스텝 — 파일 `mktemp` 약한 검사(개발 트리). 배포 스캐너(`file`)는 `${SCRIPT_DIR}` 하위만
# 보므로 저장소 루트 `scripts/` (계열 A·D)를 같은 판정으로 별도로 본다.
mktemp_guard_scan_dev_file() {
  local root dir raw
  local -a keep=()
  root="$(_hook_repo_root)" || {
    _mktemp_scan_marker dev-file fail missing-dir 0 0 0 0 0
    echo "  정본 저장소 루트를 찾지 못했습니다" >&2; return 1
  }
  dir="${root}/scripts"
  if [[ ! -d "$dir" ]]; then
    _mktemp_scan_marker dev-file fail missing-dir 0 0 0 0 0
    echo "  개발 트리 scripts/ 가 없습니다: $dir" >&2; return 1
  fi
  raw="$(find "$dir" -type f -name "*.sh")" || {
    _mktemp_scan_marker dev-file fail scanner-error 0 0 0 0 0
    echo "  검사 대상 파일 열거 실패 (find rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  raw="$(printf '%s\n' "$raw" | LC_ALL=C sort)" || {
    _mktemp_scan_marker dev-file fail scanner-error 0 0 0 0 0
    echo "  검사 대상 목록 정렬 실패 (sort rc≠0) — 부분 목록으로 판정하지 않습니다" >&2
    return 1
  }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    keep+=("$f")
  done <<< "$raw"

  _mktemp_scan_run dev-file file "$MKTEMP_SCAN_EXPECT_DEV_FILE" 0 0 "${keep[@]}"
}

# snippet 공통 — 부재 파일이 있어도 존재하는 파일은 실제로 스캔합니다.
# $1=step $2=디렉터리 $3=디렉터리 부재 시 result(skip|fail)
_mktemp_scan_snippet() {
  local step="$1" dir="$2" on_missing_dir="$3" f
  local -a present=() absent=()
  if [[ ! -d "$dir" ]]; then
    _mktemp_scan_marker "$step" "$on_missing_dir" missing-dir 0 0 0 0 0
    if [[ "$on_missing_dir" == "skip" ]]; then
      echo "  미배포 트리 — 건너뜁니다 (${dir} 부재)"; return 0
    fi
    echo "  snippet 디렉터리가 없습니다: $dir" >&2; return 1
  fi
  for f in status.md diff.md; do
    if [[ -f "${dir}/${f}" ]]; then present+=("${dir}/${f}"); else absent+=("$f"); fi
  done

  if (( ${#absent[@]} > 0 )); then
    local sites=0 violations=0
    if (( ${#present[@]} > 0 )); then
      # 존재 파일 스캔이 실패하면 scanner-error 가 missing-file 보다 우선입니다
      # (Turn 004 Finding 2-B: 이전 안은 오류를 버리고 missing-file 을 냈습니다).
      if ! _mktemp_scan_raw dir "${present[@]}"; then
        _mktemp_scan_marker "$step" fail scanner-error "${#present[@]}" 0 0 0 0
        printf '  없는 파일: %s\n' "${absent[*]}" >&2
        echo "  존재 파일 스캔 중 스캐너 실행 실패" >&2
        return 1
      fi
      sites="$_SCAN_SITES"; violations="$_SCAN_VIOLATIONS"
      [[ -n "$_SCAN_DETAIL" ]] && printf '%s\n' "$_SCAN_DETAIL" >&2
    fi
    _mktemp_scan_marker "$step" fail missing-file "${#present[@]}" "$sites" "$violations" 0 0
    printf '  없는 파일: %s\n' "${absent[*]}" >&2
    return 1
  fi
  _mktemp_scan_run "$step" dir "$MKTEMP_SCAN_EXPECT_SNIPPET" 0 0 "${present[@]}"
}

mktemp_guard_scan_installed_snippet() {
  _mktemp_scan_snippet installed-snippet "${SCRIPT_DIR}/../claude_skills/tpl" skip
}

mktemp_guard_scan_canon_snippet() {
  local root
  root="$(_hook_repo_root)" || {
    _mktemp_scan_marker canon-snippet fail missing-dir 0 0 0 0 0
    echo "  정본 저장소 루트를 찾지 못했습니다" >&2; return 1
  }
  _mktemp_scan_snippet canon-snippet "${root}/_ROOT_FILES/rd-workflow/claude_skills/tpl" fail
}

# 스캐너 판정 표본 — SUMMARY 계약 + 블록별 대조 + reason 우선순위.
#
# `_mktemp_scan_run` 에 넘기는 step 이름 `sample-priority` 는 REQUEST 의 세 step 값 밖이지만,
# 그 표식은 명령 치환 안에 캡처되어 외부 스텝 표식으로 노출되지 않습니다 (Turn 004 확인).
mktemp_scan_sample_check() {
  local fx="${SCRIPT_DIR}/fixtures/mktemp_scan_samples.txt" rc=0
  local exp got noviol both combined
  [[ -f "$fx" ]] || { echo "  표본 파일이 없습니다: $fx" >&2; return 1; }

  # (a) SUMMARY 계약 + 총계. 단일성·3필드·숫자 검증은 `_mktemp_scan_raw` 가 단일 권위로
  #     수행하므로 여기서 다시 세지 않습니다 (Turn 006 Finding 3). 대신 SUMMARY 가
  #     **마지막 줄**이라는 계약을 함께 확인합니다.
  if ! _mktemp_scan_raw dir "$fx"; then
    echo "  표본 스캔이 SUMMARY 계약(단일 · 3필드 · 숫자)에 맞지 않습니다" >&2; return 1
  fi
  if [[ "$(awk -f "$SCAN_AWK" "$fx" | tail -1 | cut -f1)" != "SUMMARY" ]]; then
    echo "  SUMMARY 가 마지막 줄이 아닙니다" >&2; rc=1
  fi
  if [[ "$_SCAN_SITES" != "12" || "$_SCAN_VIOLATIONS" != "11" ]]; then
    echo "  표본 총계 불일치 — 기대 sites=12 violations=11, 실제 sites=${_SCAN_SITES} violations=${_SCAN_VIOLATIONS}" >&2
    rc=1
  fi

  # (b) 기대 위반 줄번호 집합 = `#EXPECT: violation` 마커 바로 다음 줄
  # `comm` 은 **같은 로케일의 사전순** 입력을 요구합니다. `sort -n` 을 넘기면 두 자리 줄번호가
  # 한 자리 뒤에 와 전제가 깨지고, 공통 줄까지 차집합으로 보고하거나 교집합을 놓칩니다
  # (실측: `LC_ALL=C comm -23 <(printf '5\n8\n11\n14\n') <(printf '11\n14\n')` → `5 8 11 14`).
  # 집합 연산은 `LC_ALL=C sort` 로 통일하고, 사람이 읽는 진단만 마지막에 숫자순으로 되돌립니다.
  exp="$(awk '/^#EXPECT: violation/{print NR+1}' "$fx" | LC_ALL=C sort)"
  got="$(awk -f "$SCAN_AWK" "$fx" | awk -F'\t' '$1=="VIOLATION"{print $3}' | LC_ALL=C sort)"
  if [[ "$exp" != "$got" ]]; then
    echo "  블록별 판정 불일치 — 기대에만 있음:" >&2
    LC_ALL=C comm -23 <(printf '%s\n' "$exp") <(printf '%s\n' "$got") | sort -n >&2
    echo "  실제에만 있음:" >&2
    LC_ALL=C comm -13 <(printf '%s\n' "$exp") <(printf '%s\n' "$got") | sort -n >&2
    rc=1
  fi

  # (c) ok·non-candidate 블록의 줄번호는 위반 집합에 없어야 합니다
  noviol="$(awk '/^#EXPECT: (ok|non-candidate)/{print NR+1}' "$fx" | LC_ALL=C sort)"
  both="$(LC_ALL=C comm -12 <(printf '%s\n' "$noviol") <(printf '%s\n' "$got") | sort -n)"
  if [[ -n "$both" ]]; then
    echo "  위반이 아니어야 하는 줄이 위반으로 보고됐습니다:" >&2
    printf '%s\n' "$both" >&2
    rc=1
  fi

  # (d) reason 우선순위 — 일부러 틀린 기대 건수를 주면 count-mismatch 가 아니라
  #     template-violation 이 나와야 하고 두 상세가 모두 나와야 합니다.
  #     stdout·stderr 를 **변수 하나로 결합 캡처**합니다 — 고정 /tmp 파일을 쓰지 않아
  #     동시 실행 덮어쓰기·symlink truncate 위험이 없고, 새 mktemp 후보도 늘지 않습니다
  #     (Turn 004 Finding 5-B).
  combined="$(_mktemp_scan_run sample-priority dir 999 0 0 "$fx" 2>&1)"
  case "$combined" in
    *"reason=template-violation"*) ;;
    *) echo "  우선순위 확인 실패 — 기대 reason=template-violation" >&2
       printf '%s\n' "$combined" >&2; rc=1 ;;
  esac
  case "$combined" in
    *"위반 "*) ;;
    *) echo "  위반 상세가 출력되지 않았습니다" >&2; rc=1 ;;
  esac
  case "$combined" in
    *"기대 후보 수 999"*) ;;
    *) echo "  기대·실제 건수가 출력되지 않았습니다" >&2; rc=1 ;;
  esac

  # ── 파일 모드(mode=file) 표본 — 디렉터리 모드와 같은 구조를 별도 표본 파일로 확인합니다.
  # 기존 표본(`mktemp_scan_samples.txt`)의 총계 12/11 과 섞지 않습니다 — 그 계약은
  # 디렉터리 모드 전용이라 파일 모드 후보를 더하면 깨집니다.
  local ffx="${SCRIPT_DIR}/fixtures/mktemp_scan_file_samples.txt"
  local fexp fgot
  [[ -f "$ffx" ]] || { echo "  파일 모드 표본 파일이 없습니다: $ffx" >&2; return 1; }

  # (a') SUMMARY 계약 + 총계.
  if ! _mktemp_scan_raw file "$ffx"; then
    echo "  파일 모드 표본 스캔이 SUMMARY 계약에 맞지 않습니다" >&2; return 1
  fi
  if [[ "$(awk -v mode=file -f "$SCAN_AWK" "$ffx" | tail -1 | cut -f1)" != "SUMMARY" ]]; then
    echo "  파일 모드 SUMMARY 가 마지막 줄이 아닙니다" >&2; rc=1
  fi
  if [[ "$_SCAN_SITES" != "12" || "$_SCAN_VIOLATIONS" != "5" ]]; then
    echo "  파일 모드 표본 총계 불일치 — 기대 sites=12 violations=5, 실제 sites=${_SCAN_SITES} violations=${_SCAN_VIOLATIONS}" >&2
    rc=1
  fi

  # (b') 기대 위반 줄번호 집합 = `#EXPECT: violation` 마커 바로 다음 줄. 이 대조가 통과하면
  #      나머지 통과 표본(주석에만 「통과 N」이라고 적혀 있고 마커가 없는 줄)이 위반으로
  #      잘못 잡히지 않았다는 것도 함께 확인됩니다 (got 이 exp 와 정확히 같아야 하므로).
  fexp="$(awk '/^#EXPECT: violation/{print NR+1}' "$ffx" | LC_ALL=C sort)"
  fgot="$(awk -v mode=file -f "$SCAN_AWK" "$ffx" | awk -F'\t' '$1=="VIOLATION"{print $3}' | LC_ALL=C sort)"
  if [[ "$fexp" != "$fgot" ]]; then
    echo "  파일 모드 블록별 판정 불일치 — 기대에만 있음:" >&2
    LC_ALL=C comm -23 <(printf '%s\n' "$fexp") <(printf '%s\n' "$fgot") | sort -n >&2
    echo "  실제에만 있음:" >&2
    LC_ALL=C comm -13 <(printf '%s\n' "$fexp") <(printf '%s\n' "$fgot") | sort -n >&2
    rc=1
  fi

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

# SKILL.md frontmatter 무결성 — 의존성 없이 검사한다 (PyYAML 부재 환경).
# 규약: 1행이 `---`, 닫는 `---` 존재, 블록 내 각 행은 `키: 값` 또는 2칸 이상 들여쓴 연속행,
# `name`·`description` 키 필수.
_skill_frontmatter_ok() {  # $1=SKILL.md 경로
  awk '
    NR==1 { if ($0 != "---") { print "  1행이 --- 가 아님" > "/dev/stderr"; exit 1 } ; next }
    $0 == "---" { closed=1; exit 0 }
    /^[a-z][a-z0-9-]*:( |$)/ { key=$0; sub(/:.*/,"",key); seen[key]=1; next }
    /^  +[^ ]/ { next }
    /^[[:space:]]*$/ { next }
    { printf "  frontmatter 규약 밖 행: %s\n", $0 > "/dev/stderr"; exit 1 }
    END {
      if (!closed) { print "  닫는 --- 부재" > "/dev/stderr"; exit 1 }
      if (!seen["name"]) { print "  name 키 부재" > "/dev/stderr"; exit 1 }
      if (!seen["description"]) { print "  description 키 부재" > "/dev/stderr"; exit 1 }
    }
  ' "$1"
}

# 한 트리의 판정표 정합. 토폴로지 판정을 하지 않는다 — 불변 대상만 무조건 검사하고,
# 배치가 갈리는 tpl·ship·publish 는 "있으면 플래그가 있어야 한다" 로 조건부 검사한다.
# 미러 일치는 build_template.sh verify 소유이므로 여기서 비교하지 않는다.
_skill_flag_scan() {  # $1=SKILL.md → "<frontmatter 안 키 개수>\t<값들을 | 로 이은 문자열>" (frontmatter 없으면 -1)
  # 값 하나만 보면 "빈 키 + true 중복" 처럼 키가 여러 개인 위반을 통과시킨다. 개수도 함께 돌려준다.
  awk '
    NR==1 { if ($0 != "---") { bad=1; exit } ; next }
    !closed && $0 == "---" { closed=1; exit }
    !closed && /^disable-model-invocation:/ {
      n++
      v=$0; sub(/^disable-model-invocation:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
      acc = (n==1 ? v : acc "|" v)
    }
    END { if (bad) print "-1\t"; else printf "%d\t%s\n", n+0, acc }
  ' "$1"
}

_skill_manual_guard_tree() {  # $1=트리 경로 — 단계 전환 6개가 각각 정확히 1개, 그리고 6곳이 문자 단위로 동일한지
  local tree="$1" name f rc=0 c uniq
  local -a guarded=(request-to-reviewed-plan planning-design-intake implement-reviewed-plan \
                    final-diff-review small-task-implement gap-check)
  local -a files=()
  for name in "${guarded[@]}"; do
    f="$tree/$name/SKILL.md"
    [[ -f "$f" ]] || { echo "  $f: 필수 파일 부재" >&2; return 1; }
    files+=("$f")
    # 합계만 보면 "한 파일에 2개 + 다른 파일에 0개" 가 통과한다. 파일별로 센다.
    c=$(grep -c '^`manual` 모드에서는' "$f" || true)
    if [[ "$c" != "1" ]]; then
      echo "  $f: manual 자기 점검 문장이 ${c}개 — 정확히 1개여야 한다 (AUTONOMY.md 「실행 모드와 skill 호출 권한」)" >&2
      rc=1
    fi
  done
  uniq=$(grep -h '^`manual` 모드에서는' "${files[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  if [[ "$uniq" != "1" ]]; then
    echo "  manual 자기 점검 문장이 ${uniq}종 — 6곳이 문자 단위로 동일해야 한다" >&2
    rc=1
  fi
  return $rc
}

_skill_authority_tree() {  # $1=트리 경로
  local tree="$1" rc=0 name f scan cnt val
  # 호출 가능으로 고정할 11개 — 제거 8 + 판정표의 "변경 없음" 3 (플래그가 다시 붙는 회귀도 잡는다)
  local -a must_absent=(request-to-reviewed-plan planning-design-intake implement-reviewed-plan \
                        final-diff-review small-task-implement gap-check fr review-config \
                        autopilot model-strategy workflow-router)
  local -a keep_always=(comprehensive-audit)
  local -a keep_if_present=(tpl ship publish)
  [[ -d "$tree" ]] || { echo "  $tree: 필수 디렉터리 부재" >&2; return 1; }
  for name in "${must_absent[@]}"; do
    f="$tree/$name/SKILL.md"
    [[ -f "$f" ]] || { echo "  $f: 필수 파일 부재" >&2; rc=1; continue; }
    scan=$(_skill_flag_scan "$f"); cnt=${scan%%$'\t'*}
    if [[ "$cnt" != "0" && "$cnt" != "-1" ]]; then
      echo "  $f: 호출 가능이어야 하는데 frontmatter 에 disable-model-invocation 키 ${cnt}개 잔존 (AUTONOMY.md 「실행 모드와 skill 호출 권한」)" >&2
      rc=1
    fi
    _skill_frontmatter_ok "$f" || { echo "  $f: frontmatter 무결성 위반" >&2; rc=1; }
  done
  for name in "${keep_always[@]}"; do
    f="$tree/$name/SKILL.md"
    [[ -f "$f" ]] || { echo "  $f: 유지 대상 필수 파일 부재" >&2; rc=1; continue; }
    scan=$(_skill_flag_scan "$f"); cnt=${scan%%$'\t'*}; val=${scan#*$'\t'}
    if [[ "$cnt" != "1" || "$val" != "true" ]]; then
      echo "  $f: 유지 대상인데 frontmatter 의 disable-model-invocation 이 「키 1개 · 값 true」 가 아님 (키 ${cnt}개, 값 '${val}')" >&2
      rc=1
    fi
    _skill_frontmatter_ok "$f" || { echo "  $f: frontmatter 무결성 위반" >&2; rc=1; }
  done
  for name in "${keep_if_present[@]}"; do
    f="$tree/$name/SKILL.md"
    [[ -f "$f" ]] || continue   # ROOT_SKIP·ROOT_ONLY 로 토폴로지마다 유무가 갈린다 (부재는 정상)
    scan=$(_skill_flag_scan "$f"); cnt=${scan%%$'\t'*}; val=${scan#*$'\t'}
    if [[ "$cnt" != "1" || "$val" != "true" ]]; then
      echo "  $f: 유지 대상인데 frontmatter 의 disable-model-invocation 이 「키 1개 · 값 true」 가 아님 (키 ${cnt}개, 값 '${val}')" >&2
      rc=1
    fi
    _skill_frontmatter_ok "$f" || { echo "  $f: frontmatter 무결성 위반" >&2; rc=1; }
  done
  _skill_manual_guard_tree "$tree" || rc=1
  return $rc
}

# 설치본(루트) 판정 — 모든 설치본에서 실행된다 (청중 consumer).
skill_invocation_authority_check() {
  _skill_authority_tree "${SCRIPT_DIR}/../claude_skills"
}

# 정본 판정 — 개발 저장소 전용 (청중 dev-only). 청중은 사람이 넘기는 모드이므로
# `all` 모드의 소비 프로젝트에서도 실행된다 — 정본 부재는 실패가 아니라 통과로 넘긴다
# (autopilot_skill_lifecycle_check 의 "정본은 설치본에 없는 것이 정상" 처리와 같다).
skill_invocation_canon_check() {
  local canon="${SCRIPT_DIR}/../../_ROOT_FILES/rd-workflow/claude_skills"
  [[ -d "$canon" ]] || { echo "  정본 트리 없음 — 설치본이므로 건너뜁니다"; return 0; }
  _skill_authority_tree "$canon"
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
  tmp="$(mktemp -d)" || { echo "root_dir_layout_check: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$tmp" && -d "$tmp" ]] || { echo "root_dir_layout_check: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }

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

  [[ -n "$tmp" ]] && rm -rf "$tmp"
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
  probe_base="$(mktemp -d)" || { echo "hook_path_reachability_check: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$probe_base" && -d "$probe_base" ]] || { echo "hook_path_reachability_check: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  while read -r kind settings; do
    if [[ ! -f "$settings" ]]; then
      [[ "$kind" == "REQUIRED" ]] && { echo "  $settings: 필수 파일 부재" >&2; rc=1; }
      continue
    fi
    _hook_probe_settings "$settings" "$probe_base" || rc=1
  done < <(_hook_settings_targets)
  [[ -n "$probe_base" ]] && rm -rf "$probe_base"
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
# 차단은 반드시 `guard_deny` 를 거쳐야 합니다 — 계측이 새 가드에서 빠지지 않게 하는 장치.
#
# **왜 이 검사가 필요한가.** 원래는 `_guard_common.sh` 에 EXIT trap 을 달아 자동으로 덮으려
# 했으나 폐기했습니다 — 그 파일을 source 하는 `lifecycle/test_lifecycle.sh` 가 조용한 중단
# 센티넬 EXIT trap 을 쓰고, bash 는 EXIT trap 을 하나만 가지므로 서로 지웁니다. 자동 적용을
# 포기한 대가로 「빠뜨릴 수 있음」이 생겼고, 이 구조 검사가 그것을 막습니다.
#
# 과거 패턴의 잔존 grep 이 아니라 **현재 유효한 규약의 강제**입니다 — 새로 만드는 가드가
# 규약을 어기면 그 순간 실패해야 하고, 어긴 사실은 코드를 읽어서는 드러나지 않습니다.

# _gd_consume_shell_word <텍스트> — 선두의 "한 단어"를 삼키고 나머지를 stdout 으로
# 낸다. 셸의 인접 결합(따옴표 조각·맨 텍스트 조각이 공백 없이 붙으면 한 단어로
# 이어진다 — `"/dev/""null"` 은 `/dev/null` 한 단어)을 그대로 따라 한다. 공백·명령
# 구분자(`;`·`\|`·`&`·`)`)·리다이렉션 연산자(`>`·`<`)·따옴표 시작에서 멈춘다(turn 014
# 에서 두 사례로 재현 — 인접 따옴표 조각을 한 조각만 삼켜 나머지가 reason 으로
# 오인되거나, 리다이렉션 대상이 다음 리다이렉션 연산자까지 삼켜 그 뒤 정상 reason 을
# 놓쳤다).
_gd_consume_shell_word() {
  local s="$1"
  while true; do
    if [[ "$s" == \"* ]]; then
      if [[ "$s" =~ ^\"[^\"]*\" ]]; then s="${s:${#BASH_REMATCH[0]}}"; else s=""; break; fi
    elif [[ "$s" == \'* ]]; then
      if [[ "$s" =~ ^\'[^\']*\' ]]; then s="${s:${#BASH_REMATCH[0]}}"; else s=""; break; fi
    elif [[ "$s" =~ ^[^[:space:]\;\|\&\)\>\<\"\']+ ]]; then
      s="${s:${#BASH_REMATCH[0]}}"
    else
      break
    fi
  done
  printf '%s' "$s"
}

# _gd_segment_has_reason_arg <guard_deny 호출 하나의 직후 텍스트(다음 guard_deny 전까지)>
# — 선행 리다이렉션(선택 fd 숫자 + 연산자 + 대상 — 대상은 `_gd_consume_shell_word` 로
# 인접 조각까지 통째로 건너뜀)을 반복해서 건너뛴 뒤, 남는 **첫 토큰**이 비어있지 않은
# 따옴표(큰따옴표·작은따옴표) 문자열이면 0(인자 있음), 아니면 1(무인자)을 돌려준다.
# bash 3.2 의 `[[ =~ ]]`·`BASH_REMATCH` 로 위치 기반 파싱을 한다(간이 토크나이저 —
# 정규식 나열이 아니다).
#
# _gd_line_has_reason_arg_all <한 줄> — 그 줄에 있는 **모든** `guard_deny` 호출 각각을
# (다음 호출 전까지로 구간을 끊어) 독립적으로 판정한다. 전부 인자가 있으면 0, 하나라도
# 없으면 1.
#
# **왜 이런 형태인가 (guard-block-reason-identifier spec/plan review turn 002~014
# 이력).** 처음엔 "guard_deny 다음이 종결자·리다이렉션·빈 문자열이면 무인자"라는 부정
# 판정으로 시작했다. 리다이렉션 형태가 하나씩 발견될 때마다 종결자 목록에 예외를 끼워
# 넣었는데, 그때마다 위치·자릿수에 새로 의존하게 돼 turn 004·006 에서 계속 반례가
# 나왔다. turn 008 에서 판정을 긍정(따옴표 존재 여부)으로 뒤집었지만, "줄 전체에서
# 존재 여부만 보는" 것은 **위치**(어느 호출에 속하는가)를 버려 turn 010 에서 세 반례가
# 나왔다. 호출별 구간 분리 + 첫 토큰 판정으로 **순서**까지 반영했지만(turn 010), 대상
# 소비가 공백만 경계로 삼아 turn 012 에서 명령 구분자 누락이, turn 014 에서 인접
# 따옴표 조각·연속 리다이렉션 누락이 나왔다. 공통 원인은 "무엇이 한 단어의 끝인가"를
# 매번 다시 정의한 것이었다 — `_gd_consume_shell_word` 로 **단어 경계 판정을 한 곳에
# 모아** 리다이렉션 대상 소비와 첫 토큰 판정이 항상 같은 경계 규칙을 쓰게 했다.
# 27개 양성/음성 케이스(turn 002~014 에서 재현된 전부)로 재확인했고,
# `guard_deny_reason_detection_regression_check` 가 이 함수들을 회귀 검증한다.
_gd_segment_has_reason_arg() {
  local seg="$1"
  while true; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    if [[ "$seg" =~ ^[0-9]*(\>\>|\>\&|\>|\<\<\<|\<\<|\<) ]]; then
      seg="${seg:${#BASH_REMATCH[0]}}"
      seg="${seg#"${seg%%[![:space:]]*}"}"
      seg="$(_gd_consume_shell_word "$seg")"
      continue
    fi
    break
  done
  seg="${seg#"${seg%%[![:space:]]*}"}"
  if [[ "$seg" == \"* ]]; then
    [[ "$seg" =~ ^\"([^\"]+)\" ]] && return 0 || return 1
  elif [[ "$seg" == \'* ]]; then
    [[ "$seg" =~ ^\'([^\']+)\' ]] && return 0 || return 1
  else
    return 1
  fi
}

_gd_line_has_reason_arg_all() {
  local line="$1" remaining="$1" after seg violation=0
  while [[ "$remaining" == *guard_deny* ]]; do
    after="${remaining#*guard_deny}"
    seg="$after"
    case "$seg" in *guard_deny*) seg="${seg%%guard_deny*}" ;; esac
    _gd_segment_has_reason_arg "$seg" || violation=1
    remaining="$after"
  done
  [[ "$violation" == 0 ]]
}

guard_deny_convention_check() {
  local rc=0 root f base rel
  root="$(_hook_repo_root)"
  for base in "${root}" "${root}/_ROOT_FILES"; do
    [[ -d "${base}/rd-workflow/scripts/hooks" ]] || continue
    for f in "${base}"/rd-workflow/scripts/hooks/*.sh; do
      [[ -f "$f" ]] || continue
      rel="${f#${root}/}"
      case "${f##*/}" in
        test_*|_guard_common.sh) continue ;;   # 테스트와 헬퍼 정의 자신은 대상 아님
      esac
      # 주석을 뺀 실행 줄에서 맨 `exit 2` 를 찾습니다.
      if sed 's/#.*$//' "$f" | grep -qE '(^|[[:space:]);&|])exit[[:space:]]+2([[:space:]]|$)'; then
        echo "  ${rel}: 차단에 맨 'exit 2' 를 씁니다 — guard_deny 로 바꾸십시오 (차단 계측 누락)" >&2
        rc=1
      fi
      # 차단하는 가드라면 guard_deny 를 실제로 부르는지도 봅니다.
      if ! grep -q 'guard_deny' "$f"; then
        # 차단하지 않는 hook — 예외입니다. 새 hook 을 여기 넣을 때는 **차단하지 않음**이
        # 근거여야 합니다 (계측이 귀찮다는 것은 근거가 아닙니다).
        case "${f##*/}" in
          session_start.sh) : ;;               # 세션 시작 안내 — 차단 없음
          *) echo "  ${rel}: guard_deny 호출이 없습니다 — 차단 가드가 아니면 이 예외 목록에 추가하십시오" >&2; rc=1 ;;
        esac
      else
        # guard-block-reason-identifier: 이 저장소 스캔 범위(hooks/*.sh + _ROOT_FILES 사본,
        # test_*·_guard_common.sh 제외) 안의 모든 guard_deny 호출은 reason 식별자 인자를
        # 요구합니다. diff 기반 "신규"가 아니라 스캔에서 발견되는 전부에 적용하는 규약입니다
        # (외부 vendored 사본·소비 프로젝트의 extension 가드는 이 저장소 스캔 밖이라
        # 대상이 아니며, 그래서 `guard_deny` 시그니처 자체는 선택 인자로 남겨둡니다).
        # 판정은 `guard_deny` 를 포함하는 줄마다 `_gd_line_has_reason_arg_all` 로 한다
        # (위 정의 — 그 줄의 호출마다 구간을 끊어 각각 첫 토큰을 위치 기반으로 판정한다).
        _gd_violation=0
        while IFS= read -r _gd_line; do
          case "$_gd_line" in *guard_deny*) ;; *) continue ;; esac
          _gd_line_has_reason_arg_all "$_gd_line" || _gd_violation=1
        done <<EOF_GD
$(sed 's/#.*$//' "$f")
EOF_GD
        if [[ "$_gd_violation" == "1" ]]; then
          echo "  ${rel}: guard_deny 호출에 reason 식별자 인자가 없습니다 — guard_deny \"<가드 파일명>.<분기 토큰>\" 형식으로 넘기십시오" >&2
          rc=1
        fi
      fi
    done
  done
  return $rc
}

# guard_deny_reason_detection_regression_check — `_gd_line_has_reason_arg_all`(및 내부의
# `_gd_segment_has_reason_arg`) 자체의 회귀 검증 (guard-block-reason-identifier spec/plan
# review turn 008 요청: 수동 실행 기록이 아니라 실제 검사 로직에 연결된 Bash 3.2 회귀
# 테스트로 보존). 각 케이스는 turn 002~014 에서 실제로 재현된 오탐·누락 사례를 포함한다 —
# turn 010 의 4개(다른 분기 문자열 도용/서브셸+후속명령/따옴표 리다이렉션 대상/빈 첫 인자)가
# 판정을 "줄 전체 존재 여부"에서 "호출별 첫 토큰"으로 바꾼 계기이고, turn 012 의 3개(명령
# 구분자 도용)와 turn 014 의 2개(인접 따옴표 조각/연속 리다이렉션)가 단어 경계 판정을
# `_gd_consume_shell_word` 로 통합한 계기다.
guard_deny_reason_detection_regression_check() {
  # 배열로 케이스를 담는다 — bash 3.2 는 연관배열이 없지만 색인 배열은 된다. 단일
  # 문자열(단일따옴표)에 리터럴 `''`(빈 작은따옴표 케이스)를 안전하게 못 넣으므로
  # 각 원소를 "expect|label|line" 형태의 이중따옴표 문자열로 만든다(이중따옴표
  # 안에서는 작은따옴표가 그대로 리터럴이라 이스케이프가 필요 없다).
  local rc=0 line label expect got entry
  local -a _gd_cases=(
    "0|무인자|guard_deny"
    "0|세미콜론|guard_deny;"
    "0|세미콜론(공백)|guard_deny  ;"
    "0|서브셸|(guard_deny)"
    "0|리다이렉션(fd없음)|guard_deny >&2"
    "0|리다이렉션(fd 1자리)|guard_deny 2>/dev/null"
    "0|리다이렉션(fd>&2)|guard_deny 1>&2"
    "0|빈 큰따옴표|guard_deny \"\""
    "0|빈 작은따옴표|guard_deny ''"
    "0|if 문 안|if [ \"\$rc\" = \"2\" ]; then guard_deny; fi"
    "0|리다이렉션(fd 3자리)|guard_deny 100>/dev/null"
    "0|리다이렉션 대상 공백 분리|guard_deny > /dev/null"
    "0|명령 구분자 뒤 무인자|: >/dev/null;guard_deny"
    "1|정상 호출|guard_deny \"pre_commit_archive_gate.foo\""
    "1|변수 인자|guard_deny \"\$reason\""
    "1|들여쓰기 정상 호출|  guard_deny \"headless_background_gate.background-dispatch\""
    "1|정상 호출+리다이렉션 뒤|guard_deny \"pre_commit_archive_gate.foo\" 2>/dev/null"
    "1|리다이렉션 먼저+정상 호출|guard_deny 2>/dev/null \"pre_commit_archive_gate.foo\""
    "0|다른 분기 문자열 도용|if test -f flag; then guard_deny; else guard_deny \"gate.other\"; fi"
    "0|서브셸+후속명령 문자열 도용|(guard_deny); printf '%s\\n' \"finished\""
    "0|따옴표 리다이렉션 대상|guard_deny >\"/dev/null\""
    "0|빈 첫 인자+둘째 인자|guard_deny \"\" \"gate.unused\""
    "0|리다이렉션 대상+세미콜론 도용|guard_deny >/dev/null;printf \"finished\""
    "0|리다이렉션 대상+AND 도용|guard_deny >/dev/null&&printf \"finished\""
    "0|서브셸+리다이렉션+세미콜론 도용|(guard_deny >/dev/null);printf \"finished\""
    "0|인접 따옴표 조각 대상|guard_deny >\"/dev/\"\"null\""
    "1|연속 리다이렉션+정상 인자|guard_deny >/dev/null> /dev/null \"gate.reason\""
  )
  for entry in "${_gd_cases[@]}"; do
    expect="${entry%%|*}"
    label="${entry#*|}"; label="${label%%|*}"
    line="${entry#*|*|}"
    if _gd_line_has_reason_arg_all "$line"; then got=1; else got=0; fi
    if [[ "$got" != "$expect" ]]; then
      echo "  [$label] 기대 $([ "$expect" = 1 ] && echo '인자있음' || echo '무인자'), 실제 $([ "$got" = 1 ] && echo '인자있음' || echo '무인자') — 원문: $line" >&2
      rc=1
    fi
  done
  return $rc
}

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


# ④ 전용 헬퍼 — 임시 설치본을 세우고 현재 구현과 변형(행 단위 계수) 구현의 판정을 대조한다.
_hook_p6_regression_fixture() {
  local rc=0 self="${SCRIPT_DIR}/self_test.sh" fx code out ln
  fx="$(mktemp -d)" || { echo "_hook_p6_regression_fixture: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$fx" && -d "$fx" ]] || { echo "_hook_p6_regression_fixture: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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

  [[ -n "$fx" ]] && rm -rf "$fx"
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
run_step review consumer "diff review base 판정·seal 계약 (test_review_base_resolution.sh)" bash "${SCRIPT_DIR}/test_review_base_resolution.sh"
run_step lifecycle consumer "state 단위 테스트 (test_state_common.sh)" bash "${SCRIPT_DIR}/test_state_common.sh"
run_step hooks consumer "guard state fixture (test_guard_state.sh)" bash "${SCRIPT_DIR}/hooks/test_guard_state.sh"
run_step hooks consumer "archive gate 테스트 (test_pre_commit_archive_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_pre_commit_archive_gate.sh"
run_step hooks consumer "background dispatch 차단 hook (test_headless_background_gate.sh)" bash "${SCRIPT_DIR}/hooks/test_headless_background_gate.sh"
run_step hooks consumer "가드 차단 계측 (test_guard_block_log.sh)" bash "${SCRIPT_DIR}/hooks/test_guard_block_log.sh"
run_step lifecycle consumer "비차단 Status drift 검증 (nonblocking_status_drift_check)" nonblocking_status_drift_check
run_step lifecycle consumer "LC-19 3자 일치 검증 (TASK/STATE/CLAUDE.md)" canonical_status_triple_drift_check
run_step lifecycle consumer "task CLI 단위 테스트" bash "${SCRIPT_DIR}/test_task_cli.sh"
run_step skills consumer "install_claude_skills 단위 테스트" bash "${SCRIPT_DIR}/test_install_claude_skills.sh"
run_step lifecycle consumer "lifecycle 단위 테스트 (test_lifecycle.sh)" bash "${SCRIPT_DIR}/lifecycle/test_lifecycle.sh"
run_step lifecycle consumer "작업 색인 단위 테스트 (test_tasks_index.sh)" bash "${SCRIPT_DIR}/lifecycle/test_tasks_index.sh"
run_step lifecycle consumer "세션 기동 단위 테스트 (test_session_launch.sh)" bash "${SCRIPT_DIR}/lifecycle/test_session_launch.sh"
run_step lifecycle consumer "작업 목록 단위 테스트 (test_tasks_list.sh)" bash "${SCRIPT_DIR}/lifecycle/test_tasks_list.sh"
run_step lifecycle consumer "worktree archive 테스트 (test_archive_worktree.sh)" bash "${SCRIPT_DIR}/lifecycle/test_archive_worktree.sh"
run_step lifecycle consumer "FR 등록 helper 격리 테스트 (test_fr_register.sh)" bash "${SCRIPT_DIR}/test_fr_register.sh"
run_step lifecycle consumer "미병합 브랜치 backlog 대조 (test_fr_backlog_scan.sh)" bash "${SCRIPT_DIR}/test_fr_backlog_scan.sh"
run_step lifecycle consumer "인덱스 행 집합 병합 (test_merge_fr_index.sh)" bash "${SCRIPT_DIR}/lifecycle/test_merge_fr_index.sh"
run_step lifecycle consumer "시작 계약 preflight (test_start_preflight.sh)" bash "${SCRIPT_DIR}/lifecycle/test_start_preflight.sh"
run_step lifecycle consumer "archive 발행 상태 판정 (test_archive_state.sh)" bash "${SCRIPT_DIR}/batch/test_archive_state.sh"
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
  tmproot="$(mktemp -d)" || { echo "defect_reports_test_check: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$tmproot" && -d "$tmproot" ]] || { echo "defect_reports_test_check: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
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
run_step build consumer "mktemp 가드 대조 — 배포 셸" mktemp_guard_scan_shell
run_step build dev-only "mktemp 가드 대조 — 개발 셸" mktemp_guard_scan_dev_shell
run_step build consumer "mktemp 가드 대조 — 파일 mktemp (약한 검사)" mktemp_guard_scan_file
run_step build dev-only "mktemp 가드 대조 — 개발 파일 mktemp (약한 검사)" mktemp_guard_scan_dev_file
run_step build consumer "mktemp 가드 대조 — 설치본 snippet" mktemp_guard_scan_installed_snippet
run_step build dev-only "mktemp 가드 대조 — 정본 snippet" mktemp_guard_scan_canon_snippet
run_step build dev-only "mktemp 스캐너 판정 표본" mktemp_scan_sample_check
run_step skills dev-only "autopilot SKILL lifecycle 정합 (promote/rollback 일원화)" autopilot_skill_lifecycle_check
run_step skills dev-only "무인 진입 계약 정합 (autopilot_headless_entry_check)" autopilot_headless_entry_check
run_step skills consumer "skill 호출 권한 판정표 (설치본)" skill_invocation_authority_check
run_step skills dev-only "skill 호출 권한 판정표 (정본)" skill_invocation_canon_check
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
# publish.sh 원격 상태 판정 회귀(빈 원격 오판 → 새 root commit). 같은 이유로 dev repo 전용이다.
test_publish_remote_state_check() {
  local t="${SCRIPT_DIR}/../../scripts/test_publish_remote_state.sh"
  if [[ -f "$t" ]]; then bash "$t"; else echo "  (skip: dev repo 아님)"; fi
}


run_step hooks consumer "hook 경로 도달 증명 (hook_path_reachability_check)" hook_path_reachability_check
run_step hooks consumer "hook 대상 실재 (hook_target_existence_check)" hook_target_existence_check
run_step hooks consumer "차단 계측 규약 (guard_deny_convention_check)" guard_deny_convention_check
run_step hooks dev-only "reason 인자 판정 회귀 (guard_deny_reason_detection_regression_check)" guard_deny_reason_detection_regression_check
run_step build dev-only "프로젝트 루트 계산 양쪽 레이아웃 (root_dir_layout_check)" root_dir_layout_check
run_step build dev-only "템플릿 build 검증 (build_template.sh verify)" build_verify_check
run_step build dev-only "템플릿 빌더 단위 테스트 (test_build_template.sh)" test_build_template_check
run_step build dev-only "배포 미러 계약 (test_publish_mirror.sh)" test_publish_mirror_check
run_step build dev-only "publish 원격 상태 판정 회귀 (test_publish_remote_state.sh)" test_publish_remote_state_check
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