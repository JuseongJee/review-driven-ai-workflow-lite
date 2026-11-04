#!/usr/bin/env bash
# fr_related_history.sh — FR 상세 파일이 처음 커밋된 뒤, 그 `- related files:` 경로를
# 바꾼 커밋이 있는지 git 이력으로 알려준다. "이미 해결된 FR 일 수 있다" 는 착수 전 신호다.
# 사용: bash fr_related_history.sh <fr-item-file> [--root <repo-root>] [--limit <n>]
#
# 출력 (stdout 첫 줄이 판독 줄, exit 0):
#   <파일>: 변경 N건 (기준 <short>..HEAD, 경로 M개)   — N>0 이면 다음 줄에 `  <short> <제목>` 최대 limit 줄
#   <파일>: 검사 대상 없음 (related files 파싱 결과 0건)
#   <파일>: 판정 불가 (<사유>)
# 판정 불가 사유: 기준점 없음 / 이력 불완전(얕은 clone) / git 실행 실패 / git 저장소가 아닙니다.
# exit 2 는 인자 오류와 입력 파일 부재·읽기 불가에만 쓴다
# (check_fr_related_files_existence.sh 와 같은 계약).
#
# 이 출력은 참고 신호다. 신호만으로 FR 을 종결하거나 선별에서 제외하지 않는다.
# 판정은 사람이 한다.
#
# 경로 추출은 check_fr_related_files_existence.sh 의 규칙을 쓰지 않고 여기서 직접 한다.
# 그 규칙은 백틱 안의 `rd-workflow/` 아래 경로만 받는다. 이력 조회는 백틱 없이 적은 FR 과
# `scripts/…`·`CLAUDE.md`·`_ROOT_FILES/…` 같은 저장소 경로도 필요하다.
# 실재 확인(빌드 트리 기준)과 이력 조회(저장소 기준)는 목적이 다르다.
# 규칙: `- related files:` 첫 줄에서 백틱 구간이 있으면 그 안만, 없으면 줄 전체를
# 공백·쉼표로 나눈다. 각 단어의 앞 `(`, 뒤 `,;).` 와 `:<숫자>` 꼬리를 떼고,
# ^[A-Za-z0-9_.@/-]+$ 에 맞고 `/` 를 포함하거나 `.<영문 확장자>` 로 끝나면 경로다.
# 중복은 한 번만 센다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME="fr_related_history.sh"

FR_FILE="${1:-}"
[[ $# -gt 0 ]] && shift
ROOT=""
LIMIT=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      case "${2-}" in
        ""|-?*) echo "${ME}: --root 에 값이 없습니다." >&2; exit 2 ;;
      esac
      ROOT="$2"; shift 2 ;;
    --limit)
      case "${2-}" in
        ""|*[!0-9]*|0) echo "${ME}: --limit 은 1 이상의 정수여야 합니다." >&2; exit 2 ;;
      esac
      LIMIT="$2"; shift 2 ;;
    *)
      echo "${ME}: 알 수 없는 인자: $1" >&2
      exit 2 ;;
  esac
done
[[ -n "$ROOT" ]] || ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -z "$FR_FILE" || ! -f "$FR_FILE" ]]; then
  echo "${ME}: 입력 FR 파일이 없습니다: '${FR_FILE}'" >&2
  exit 2
fi
if [[ ! -r "$FR_FILE" ]]; then
  echo "${ME}: 입력 FR 파일을 읽을 수 없습니다: '${FR_FILE}'" >&2
  exit 2
fi

report() { printf '%s: %s\n' "$FR_FILE" "$1"; }

# 1) git 저장소·얕은 clone 검사 (한 번의 호출로 둘 다 읽는다)
if ! gitinfo="$(git -C "$ROOT" rev-parse --git-dir --is-shallow-repository 2>/dev/null)"; then
  report "판정 불가 (git 저장소가 아닙니다)"; exit 0
fi
if [[ "${gitinfo##*$'\n'}" == "true" ]]; then
  report "판정 불가 (이력 불완전 — 얕은 clone 입니다)"; exit 0
fi

# 2) related files 경로 추출
line="$(grep -m1 '^- related files:' "$FR_FILE" 2>/dev/null || true)"
line="${line#- related files:}"
if [[ "$line" == *'`'* ]]; then
  words="$(printf '%s\n' "$line" | awk -F'`' '{ for (i = 2; i <= NF; i += 2) print $i }')"
else
  words="$line"
fi
PATHS=()
for w in $(printf '%s\n' "$words" | tr ',' ' '); do
  w="${w#(}"
  while [[ "$w" =~ [,\;\).]$ ]]; do w="${w%?}"; done
  if [[ "$w" =~ :[0-9]+$ ]]; then w="${w%:*}"; fi
  [[ "$w" =~ ^[A-Za-z0-9_.@/-]+$ ]] || continue
  if [[ "$w" != */* && ! "$w" =~ \.[A-Za-z]+$ ]]; then continue; fi
  dup=0
  for p in ${PATHS[@]+"${PATHS[@]}"}; do [[ "$p" == "$w" ]] && dup=1; done
  [[ "$dup" -eq 0 ]] && PATHS+=("$w")
done
if [[ ${#PATHS[@]} -eq 0 ]]; then
  report "검사 대상 없음 (related files 파싱 결과 0건)"; exit 0
fi

# 3) 기준점: 상세 파일이 처음 추가된 커밋 (rename 을 따라간다)
root_abs="$(cd "$ROOT" && pwd -P)"
fr_dir="."
[[ "$FR_FILE" == */* ]] && fr_dir="${FR_FILE%/*}"
fr_dir="$(cd "$fr_dir" && pwd -P)"
fr_rel="${fr_dir#"${root_abs}"/}/${FR_FILE##*/}"
adds="$(git -C "$ROOT" log --follow --diff-filter=A --format=%H -- "$fr_rel" 2>/dev/null)" || {
  report "판정 불가 (git 실행 실패 — git log --follow)"; exit 0; }
adds="${adds%$'\n'}"
base_commit="${adds##*$'\n'}"
if [[ -z "$base_commit" ]]; then
  report "판정 불가 (기준점 없음 — 상세 파일이 HEAD 이력에 커밋되지 않았습니다)"; exit 0
fi

# 4) 집계
count="$(git -C "$ROOT" rev-list --count "${base_commit}..HEAD" -- "${PATHS[@]}" 2>/dev/null)" || {
  report "판정 불가 (git 실행 실패 — git rev-list)"; exit 0; }
short="${base_commit:0:8}"
report "변경 ${count}건 (기준 ${short}..HEAD, 경로 ${#PATHS[@]}개)"
if [[ "$count" -gt 0 ]]; then
  git -C "$ROOT" log --format='  %h %s' -n "$LIMIT" "${base_commit}..HEAD" -- "${PATHS[@]}" 2>/dev/null || {
    report "판정 불가 (git 실행 실패 — git log)"; exit 0; }
fi
exit 0
