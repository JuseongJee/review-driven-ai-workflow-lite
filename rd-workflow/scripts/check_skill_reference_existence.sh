#!/usr/bin/env bash
# check_skill_reference_existence.sh — skill 문서가 참조하는 저장소 상대 경로가
# 같은 배포 트리에 실재하는지 확인한다.
# 사용: bash check_skill_reference_existence.sh <markdown-file> [--root <repo-root>]
#
# 추출 대상: 백틱 인라인 코드·fenced 코드블록(```) 안에서 공백 기준 "단어"를 만들고,
# 그 단어 **전체**가 `rd-workflow/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*` 에 완전히 일치할
# 때만 후보로 삼는다. 변수($X)·플레이스홀더(<x>)·glob(*)이 섞인 단어는 전체 불일치로
# **통째로 제외**된다 — 잘린 접두사만 뽑는 부분 추출은 하지 않는다(spec D2, F1).
# 코드블록 밖 순수 설명문은 스캔하지 않는다(오탐 방지 우선).
#
# 존재 확인 기준: 정본(_ROOT_FILES/)이 아니라 빌드된 rd-workflow/ 트리(--root 의
# 자식) — skill 본문의 명령이 소비 프로젝트 루트 기준 상대 경로이기 때문이다(spec D3).
# 기본값(--root 생략 시)은 이 스크립트가 빌드된 rd-workflow/scripts/ 에 있을 때만
# 저장소 루트를 정확히 가리킨다 — 정본(_ROOT_FILES/)에서 직접 실행하면 다른 트리를
# 가리키므로, 정본 단계의 통합 스캔에는 이 스크립트를 기본값으로 쓰지 않는다.
#
# 선택 파일(.example) 규칙: 참조 경로 X 가 없어도 X.example 이 있으면 경고하지 않고
# "선택 파일"로 따로 센다(요약 줄 끝 `(선택 파일 N건)`, 0건이면 생략). 사용자가 복사해
# 만들 때만 생기는 설정 파일(config/*.json.example 관례)은 배포 트리에 원본이 없는 것이
# 정상이다. 하드코딩 allowlist 는 선택 파일이 늘 때마다 사람이 목록을 고쳐야 해서 두지
# 않고, 이 저장소의 기존 .example 관례를 그대로 판정 기준으로 삼는다(spec D9).
#
# 종료 코드: 0 = 정상 실행(경고 유무 무관 — 경고는 신호일 뿐 hard fail 아님)
#            2 = 검사 자체가 성립하지 않음(입력 파일 부재·읽기 불가, 인자 오류,
#                --root 트리에 `rd-workflow/` 없음)
set -uo pipefail
# noglob — 아래 _skref_extract_paths 의 `for word in $scan` 은 따옴표 없는 단어
# 분리라 set -f 가 없으면 Bash pathname expansion까지 함께 일어난다. 예를 들어
# 저장소 루트에서 실행하면 `rd-workflow/claude_skills/**/*.md` 같은 제외 대상
# glob이 실제 파일 목록으로 치환되어 대량 오판정을 만든다(spec/plan review Turn
# 004 F1 재현, 실측: 25건). 이 스크립트는 파일 glob을 다른 용도로 쓰지 않으므로
# 전역에 꺼도 부작용이 없다.
set -f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# skref_match_path_token <word> — 단어 하나를 트리밍한 뒤 저장소 상대 경로 패턴과
# 완전히 일치하면 트리밍된 토큰을 stdout에 echo하고 return 0, 아니면 아무 출력
# 없이 return 1. 이 파일을 source하는 다른 스크립트가 재사용하는 공개 함수다 —
# 같은 파싱을 다시 구현하지 않는다(spec D1).
skref_match_path_token() {
  local word="$1" trimmed
  trimmed="${word%[.,;:)]}"
  trimmed="${trimmed#(}"
  if [[ "$trimmed" =~ ^rd-workflow/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]]; then
    printf '%s\n' "$trimmed"
    return 0
  fi
  return 1
}

# skref_inline_segments <line> — 그 줄 안의 백틱 쌍(여러 쌍 가능) 내부 문자열만
# 공백으로 이어 붙여 stdout에 echo한다. 백틱 쌍이 없으면 빈 문자열. FR 상세 파일의
# `- related files:` 한 줄처럼 fenced 코드블록이 없는 텍스트에서 인라인 코드만
# 뽑아낼 때 재사용한다(spec D1 — check_fr_related_files_existence.sh가 source해서
# 쓰는 두 번째 공개 함수. spec/plan review Turn 002 F1 — 이 경계 처리 없이 토큰
# 판정만 하면 백틱이 붙은 채로 패턴 불일치가 나 정상 경로가 전부 제외된다).
skref_inline_segments() {
  local line="$1"
  local rest="$line" seg out=""
  while [[ "$rest" == *'`'* ]]; do
    rest="${rest#*\`}"
    [[ "$rest" == *'`'* ]] || break
    seg="${rest%%\`*}"
    out="${out} ${seg}"
    rest="${rest#*\`}"
  done
  printf '%s' "$out"
}

# _skref_extract_paths <file> — 추출된 경로를 <line>\t<path> 형식으로 한 줄씩 stdout 에 낸다.
# fenced 코드블록(```) 안은 줄 전체를, 그 밖은 인라인 코드(백틱 쌍, 한 줄에 여러 쌍
# 가능) 내부만 스캔 대상으로 모은다. 그 문자열을 공백 기준 단어로 나눠 단어 전체
# 판정을 한다(F1 — 부분 추출 금지).
_skref_extract_paths() {
  local file="$1" in_fence=0 line lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$line" =~ ^[[:space:]]*'```' ]]; then
      in_fence=$((1 - in_fence))
      continue
    fi
    local scan=""
    if [[ "$in_fence" -eq 1 ]]; then
      scan="$line"
    else
      scan="$(skref_inline_segments "$line")"
    fi
    [[ -n "$scan" ]] || continue
    local word matched
    for word in $scan; do
      matched="$(skref_match_path_token "$word")" && printf '%s\t%s\n' "$lineno" "$matched"
    done
  done < "$file"
}

_skref_main() {
  MD_FILE="${1:-}"
  [[ $# -gt 0 ]] && shift
  ROOT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        # 값 누락 가드(F2) — 다음 토큰이 없거나 옵션처럼 보이면 값 누락으로 취급하고
        # 즉시 종료한다. 그러지 않으면 `shift 2`가 실패해도 `set -e`가 없어 while이
        # 같은 인자를 영원히 재검사하는 무한 반복이 된다(Reviewer Turn 002 F2 실측).
        case "${2-}" in
          ""|-?*)
            echo "check_skill_reference_existence.sh: --root 에 값이 없습니다." >&2
            exit 2 ;;
        esac
        ROOT="$2"; shift 2 ;;
      *)
        echo "check_skill_reference_existence.sh: 알 수 없는 인자: $1" >&2
        exit 2 ;;
    esac
  done
  [[ -n "$ROOT" ]] || ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

  if [[ -z "$MD_FILE" || ! -f "$MD_FILE" ]]; then
    echo "check_skill_reference_existence.sh: 입력 markdown 파일이 없습니다: '${MD_FILE}'" >&2
    exit 2
  fi
  if [[ ! -r "$MD_FILE" ]]; then
    echo "check_skill_reference_existence.sh: 입력 markdown 파일을 읽을 수 없습니다: '${MD_FILE}'" >&2
    exit 2
  fi
  if [[ ! -d "${ROOT}/rd-workflow" ]]; then
    echo "check_skill_reference_existence.sh: 기준 루트에 rd-workflow/ 가 없습니다: '${ROOT}'" >&2
    exit 2
  fi

  TOTAL=0
  WARN=0
  OPTIONAL=0
  while IFS=$'\t' read -r lineno tok; do
    [[ -z "$tok" ]] && continue
    TOTAL=$((TOTAL + 1))
    if [[ -e "${ROOT}/${tok}" ]]; then
      :
    elif [[ -e "${ROOT}/${tok}.example" ]]; then
      OPTIONAL=$((OPTIONAL + 1))
    else
      WARN=$((WARN + 1))
      echo "${MD_FILE}:${lineno}: 참조 경로 없음 — ${tok}" >&2
    fi
  done < <(_skref_extract_paths "$MD_FILE")

  if [[ "$OPTIONAL" -gt 0 ]]; then
    echo "${MD_FILE}: 참조 ${TOTAL}건 중 경고 ${WARN}건 (선택 파일 ${OPTIONAL}건)"
  else
    echo "${MD_FILE}: 참조 ${TOTAL}건 중 경고 ${WARN}건"
  fi
  exit 0
}

# 직접 실행될 때만 main을 호출한다 — source될 때(check_fr_related_files_existence.sh
# 가 skref_match_path_token()·skref_inline_segments()만 가져다 쓸 때)는 이 아래가
# 실행되지 않는다(spec D1).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _skref_main "$@"
fi
