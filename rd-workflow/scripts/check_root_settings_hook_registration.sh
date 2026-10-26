#!/usr/bin/env bash
# check_root_settings_hook_registration.sh — 배포된 hook 스크립트가 루트 .claude/settings.json 에
# 등록됐는지 역방향으로 대조한다. JSON 파서 의존 없이 "command" 키 값만 추출해 판정한다
# (Claude Code settings.json 스키마에서 "command" 키는 hooks 항목에만 등장하고, 값은 한 줄
# 안에 "command": "..." 형태로 온다는 전제 — 이 전제가 깨지는 임의 JSON은 지원 범위 밖이다.
# 범용 JSON 파서 도입은 무의존성 제약과 상충하므로 채택하지 않는다).
#
# 사용: bash check_root_settings_hook_registration.sh [--root <repo-root>] [--exceptions-file <path>]
#
# 종료 코드: 0 = 정상 실행(미등록 발견 유무 무관 — 신호일 뿐 hard fail 아님)
#            2 = 검사 자체가 성립하지 않음(입력 디렉터리/파일 부재·읽기 불가, settings.json
#                구조 손상 의심(중괄호/대괄호 불균형), 예외 목록 형식 오류, 명시적
#                --exceptions-file 경로 부재·읽기 불가, 인자 오류)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
EXCEPTIONS_FILE="${SCRIPT_DIR}/root_settings_hook_registration_exceptions.txt"
EXCEPTIONS_FILE_EXPLICIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ -n "${2:-}" && "${2}" != -* ]] || { echo "check_root_settings_hook_registration.sh: --root 값 누락" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    --exceptions-file)
      [[ -n "${2:-}" && "${2}" != -* ]] || { echo "check_root_settings_hook_registration.sh: --exceptions-file 값 누락" >&2; exit 2; }
      EXCEPTIONS_FILE="$2"; EXCEPTIONS_FILE_EXPLICIT=1; shift 2 ;;
    *)
      echo "check_root_settings_hook_registration.sh: 알 수 없는 인자 ($1)" >&2; exit 2 ;;
  esac
done

HOOKS_DIR="${ROOT}/rd-workflow/scripts/hooks"
SETTINGS_FILE="${ROOT}/.claude/settings.json"

[[ -d "$HOOKS_DIR" && -r "$HOOKS_DIR" ]] || { echo "check_root_settings_hook_registration.sh: hooks 디렉터리 부재·읽기 불가 (${HOOKS_DIR})" >&2; exit 2; }
[[ -f "$SETTINGS_FILE" && -r "$SETTINGS_FILE" ]] || { echo "check_root_settings_hook_registration.sh: 루트 settings.json 부재·읽기 불가 (${SETTINGS_FILE})" >&2; exit 2; }

# --- 실 hook 목록 수집 (`_` 접두=라이브러리, `test_` 접두=테스트 파일 제외) ---
find_out="$(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' ! -name '_*' ! -name 'test_*' 2>&1)"
find_rc=$?
[[ "$find_rc" -eq 0 ]] || { echo "check_root_settings_hook_registration.sh: hooks 디렉터리 탐색 실패 (find rc=${find_rc})" >&2; exit 2; }

real_hooks=()
while IFS= read -r f; do
  [[ -n "$f" ]] && real_hooks+=("$(basename "$f")")
done <<< "$find_out"

# --- settings.json 구조 손상 의심 검사 (문자열 리터럴 제거 후 중괄호/대괄호 균형 — 전체 JSON 파싱 대체 휴리스틱) ---
structural_only="$(awk '{ line = $0; gsub(/"([^"\\]|\\.)*"/, "", line); print line }' "$SETTINGS_FILE")"
ob=$(grep -o '{' <<< "$structural_only" | wc -l | tr -d '[:space:]')
cb=$(grep -o '}' <<< "$structural_only" | wc -l | tr -d '[:space:]')
osq=$(grep -o '\[' <<< "$structural_only" | wc -l | tr -d '[:space:]')
csq=$(grep -o '\]' <<< "$structural_only" | wc -l | tr -d '[:space:]')
if [[ "$ob" != "$cb" || "$osq" != "$csq" ]]; then
  echo "check_root_settings_hook_registration.sh: 루트 settings.json 구조 손상 의심 (중괄호 ${ob}/${cb}, 대괄호 ${osq}/${csq} 불균형)" >&2
  exit 2
fi

# --- "command" 키 값 추출 (hooks 항목 전용 — 위 스키마 전제) ---
commands="$(grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' "$SETTINGS_FILE")"
extract_rc=$?
if [[ "$extract_rc" -ge 2 ]]; then
  echo "check_root_settings_hook_registration.sh: settings.json 읽기 실패 (grep rc=${extract_rc})" >&2
  exit 2
fi

# --- 예외 목록 로드 + 형식 검증 (declare -A 미사용 — bash 3.2 호환) ---
exceptions_text=""
if [[ "$EXCEPTIONS_FILE_EXPLICIT" -eq 1 || -f "$EXCEPTIONS_FILE" ]]; then
  [[ -f "$EXCEPTIONS_FILE" && -r "$EXCEPTIONS_FILE" ]] || { echo "check_root_settings_hook_registration.sh: 예외 목록 파일 부재·읽기 불가 (${EXCEPTIONS_FILE})" >&2; exit 2; }
  line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      *"|"*) : ;;
      *) echo "${EXCEPTIONS_FILE}:${line_no}: 형식 오류 — '|' 구분자 없음" >&2; exit 2 ;;
    esac
    name="${line%%|*}"
    reason="${line#*|}"
    name="$(printf '%s' "$name" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    reason="$(printf '%s' "$reason" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [[ -z "$name" || -z "$reason" ]]; then
      echo "${EXCEPTIONS_FILE}:${line_no}: 형식 오류 — basename 또는 사유가 비어 있음" >&2
      exit 2
    fi
    exceptions_text="${exceptions_text}${name}|${reason}"$'\n'
  done < "$EXCEPTIONS_FILE"
fi
# 기본 경로 부재는 예외 없음으로 처리(오류 아님). 명시적 --exceptions-file 부재는 위에서 이미 exit 2.

# --- 등록 판정 + 예외 조회(awk) + 요약 출력 ---
unregistered=()
excepted_count=0
for hook in "${real_hooks[@]+"${real_hooks[@]}"}"; do
  if grep -qF "rd-workflow/scripts/hooks/${hook}" <<< "$commands"; then
    continue
  fi
  reason=""
  if [[ -n "$exceptions_text" ]]; then
    reason="$(awk -F'|' -v want="$hook" '$1==want{print $2; exit}' <<< "$exceptions_text")"
  fi
  if [[ -n "$reason" ]]; then
    excepted_count=$((excepted_count + 1))
    continue
  fi
  unregistered+=("$hook")
done

for hook in "${unregistered[@]+"${unregistered[@]}"}"; do
  echo "rd-workflow/scripts/hooks/${hook}: 루트 .claude/settings.json 에 미등록 (${EXCEPTIONS_FILE##*/} 에 예외로 추가하거나 루트에 등록하십시오)"
done
echo "검사 완료 — 실 hook ${#real_hooks[@]}건, 미등록 ${#unregistered[@]}건(예외 ${excepted_count}건 제외)"
exit 0
