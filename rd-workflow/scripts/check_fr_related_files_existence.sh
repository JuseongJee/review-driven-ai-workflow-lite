#!/usr/bin/env bash
# check_fr_related_files_existence.sh — 활성 FR 상세 파일의 `- related files:` 줄이
# 가리키는 저장소 상대 경로가 빌드된 rd-workflow/ 트리에 실재하는지 확인한다.
# 사용: bash check_fr_related_files_existence.sh <fr-item-file> [--root <repo-root>]
#
# 경로 토큰 추출은 check_skill_reference_existence.sh 의 skref_match_path_token()·
# skref_inline_segments() 를 source 해서 재사용한다 — 같은 파싱을 다시 구현하지
# 않는다(spec D1). related files 한 줄에서 백틱 내부 문자열만 먼저 뽑아낸 뒤 단어
# 판정을 해야 한다 — 그러지 않으면 실제 FR 형식(백틱으로 감싼 경로)이 전부 패턴
# 불일치로 제외된다(spec/plan review Turn 002 F1, 실측 재현).
#
# 파서 로딩 검증(spec D7): source 실패, 두 함수 중 하나라도 없음, 또는 함수 정의
# 전에 파서가 top-level에서 exit해 조기 종료됨 — 이 세 경우 모두 실행 오류(exit 2)
# 로 취급한다. 별도 서브프로세스에서 "성공 마커 출력"을 성공 조건으로 검증(probe)
# 하는 이유는, 파서가 조기 exit하면 그 자리에서 프로세스가 즉시 끝나 뒤이은
# declare -f 확인 자체가 실행되지 못한 채 무출력·exit 0(정상 신호)으로 위장되기
# 때문이다(Turn 002 F2 최초 발견, Turn 004 재개 — probe 방식 이전의 단순
# `if ! source ...` 로는 이 조기 종료 경로를 놓쳤다, 실측 재현). SCRIPT_DIR 는
# `bash -c` 코드 문자열에 이어붙이지 않고 위치 인자(`$1`)로 전달한다 — 문자열
# 이어붙이기는 설치 경로에 `$`·따옴표가 있으면 그 문자가 셸 코드로 재해석돼 정상
# 파서도 로딩 실패로 오판된다(Turn 006 F5, 실측 재현). 이 검증을 통과한 뒤에는
# skref_match_path_token 의 return 1 만 "비매칭"으로 본다.
#
# 대상은 skill 문서 전체가 아니라 FR 상세 파일 1개의 `- related files:` 딱 한 줄이다.
# 그 줄이 없거나 있어도 유효 토큰이 0개면(빈 값·전부 제외 토큰) "검사 대상 없음"으로
# 표시해 "전부 실재"(대상 N개 중 0개 부재)와 구분한다(spec D2, F2).
#
# 종료 코드: 0 = 정상 실행(부재·대상없음 포함 신호는 hard fail 아님)
#            2 = 검사 자체가 성립하지 않음(입력 파일 부재·읽기 불가, 인자 오류,
#                --root 트리에 rd-workflow/ 부재, 파서 로딩 실패)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 파서 로딩을 별도 서브프로세스에서 먼저 검증한다(probe). source 대상이 함수 정의
# 전에 top-level에서 exit를 호출하면(파서 손상 등) 그 exit가 현재 프로세스를 그
# 자리에서 즉시 종료시켜, 뒤이은 declare -f 확인이 아예 실행되지 못한 채 무출력
# exit 0(정상 신호로 위장)이 된다(spec/plan review Turn 004 F2 재개, 실측 재현).
# "종료 코드가 0이 아니면 실패"가 아니라 "성공 마커가 찍혀야 성공"을 기준으로 삼아
# 이 조기 종료를 구조적으로 잡는다.
_probe_out="$(bash -c '
  source "$1/check_skill_reference_existence.sh" || exit 2
  declare -f skref_match_path_token >/dev/null 2>&1 || exit 2
  declare -f skref_inline_segments >/dev/null 2>&1 || exit 2
  echo __SKREF_LOADED_OK__
' _ "$SCRIPT_DIR" 2>&1)"
_probe_rc=$?
if [[ "$_probe_rc" -ne 0 || "$_probe_out" != *"__SKREF_LOADED_OK__"* ]]; then
  echo "check_fr_related_files_existence.sh: 공용 파서 로딩 실패: ${SCRIPT_DIR}/check_skill_reference_existence.sh" >&2
  exit 2
fi
# probe를 통과했으므로 같은 파일에 대한 이 source는 결정적으로 성공한다.
source "${SCRIPT_DIR}/check_skill_reference_existence.sh"

FR_FILE="${1:-}"
[[ $# -gt 0 ]] && shift
ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      case "${2-}" in
        ""|-?*)
          echo "check_fr_related_files_existence.sh: --root 에 값이 없습니다." >&2
          exit 2 ;;
      esac
      ROOT="$2"; shift 2 ;;
    *)
      echo "check_fr_related_files_existence.sh: 알 수 없는 인자: $1" >&2
      exit 2 ;;
  esac
done
[[ -n "$ROOT" ]] || ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -z "$FR_FILE" || ! -f "$FR_FILE" ]]; then
  echo "check_fr_related_files_existence.sh: 입력 FR 파일이 없습니다: '${FR_FILE}'" >&2
  exit 2
fi
if [[ ! -r "$FR_FILE" ]]; then
  echo "check_fr_related_files_existence.sh: 입력 FR 파일을 읽을 수 없습니다: '${FR_FILE}'" >&2
  exit 2
fi
if [[ ! -d "${ROOT}/rd-workflow" ]]; then
  echo "check_fr_related_files_existence.sh: 기준 루트에 rd-workflow/ 가 없습니다: '${ROOT}'" >&2
  exit 2
fi

REL_LINE=""
REL_LINENO=0
_cur_lineno=0
while IFS= read -r _line || [[ -n "$_line" ]]; do
  _cur_lineno=$((_cur_lineno + 1))
  if [[ "$_line" =~ ^-\ related\ files: ]]; then
    REL_LINE="$_line"
    REL_LINENO="$_cur_lineno"
    break
  fi
done < "$FR_FILE"

if [[ -z "$REL_LINE" ]]; then
  echo "${FR_FILE}: 검사 대상 없음 (related files 파싱 결과 0건)"
  exit 0
fi

REST="${REL_LINE#*related files:}"
SCAN="$(skref_inline_segments "$REST")"

TOKENS=()
if [[ -n "$SCAN" ]]; then
  for word in $SCAN; do
    tok="$(skref_match_path_token "$word")" && TOKENS+=("$tok")
  done
fi

if [[ "${#TOKENS[@]}" -eq 0 ]]; then
  echo "${FR_FILE}: 검사 대상 없음 (related files 파싱 결과 0건)"
  exit 0
fi

TOTAL=0
WARN=0
for tok in "${TOKENS[@]}"; do
  TOTAL=$((TOTAL + 1))
  if [[ ! -e "${ROOT}/${tok}" ]]; then
    WARN=$((WARN + 1))
    echo "${FR_FILE}:${REL_LINENO}: 참조 경로 없음 — ${tok}" >&2
  fi
done

echo "${FR_FILE}: 대상 ${TOTAL}개 중 ${WARN}개 부재"
exit 0
