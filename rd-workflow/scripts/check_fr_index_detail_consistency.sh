#!/usr/bin/env bash
# check_fr_index_detail_consistency.sh — FUTURE_REQUESTS.md 인덱스와 items/ 상세 파일의
# 양방향 정합성을 검사한다. 진실 원천은 items/ 상세 파일이다(상세 파일의 status가
# done/dropped/parked가 아니면 활성, 필드 자체가 없으면 fail-safe로 활성 취급).
#
# 검사 4종(전부 신호 전용, exit 0):
#   ① 활성 상세 파일 중 인덱스에 대응 행이 없음
#   ② 인덱스 행의 대응 상세 파일이 없거나, 있지만 비활성인데 인덱스에 남아 있음
#   ③ 활성 상세 파일에 - status: / - kind: 필드 자체가 없음
#   ④ 활성 + 인덱스 행 존재 양쪽 다 있는 경우, 인덱스 종류 컬럼과 상세 kind 값이 다름
#
# 인덱스 파싱은 컬럼 "값"이 아니라 "위치"로 구조를 판단한다 — 종류·상태 컬럼 값이 enum
# 밖(오타, status=done 잔존)이어도 그대로 추출해야 ②·④ 판정 대상에서 빠지지 않는다
# (spec/plan review Turn 002/004 R1b, 실측 재현). 위치는 헤더를 기준으로 해석한다. `## 인덱스`
# 아래 첫 `|` 행을 헤더로 삼아 컬럼 이름과 전체 개수 N 을 읽고, 데이터 행은 앞에서 2개(날짜·제목)와
# 뒤에서 N-3 개를 고정으로 센 뒤 남은 가운데 전부를 요약으로 본다. 관계 컬럼처럼 컬럼이 늘거나
# GitHub 컬럼처럼 상세 뒤에 붙어도 이름으로 위치를 찾으므로 밀리지 않는다. 헤더 부재·필드 수
# 부족은 PARSEFAIL 로 보낸다.
#
# 셀 분해는 `\|`(마크다운 이스케이프 파이프)를 구분자로 세지 않는다. 세면 셀 하나가 비어도
# 개수 검사를 통과해 컬럼이 통째로 밀리고, 검사기가 요약 조각을 종류 값으로 읽어 엉뚱한 불일치를
# 보고한다(final diff review 지적, 실측 재현). 분해 전에 `\|`를 `\001`로 치환하고 값 출력 시
# 되돌린다. 이스케이프하지 않은 리터럴 `|`가 요약에 섞인 행은 가운데 흡수 규칙이 계속 받아낸다.
#
# awk→셸 필드 구분자는 `\034`(ASCII FS)를 쓴다. 탭이나 `\x01`(SOH)은 macOS Bash 3.2.57의
# `read`에서 IFS 공백류 축약 규칙에 걸리거나 필드 자체가 분리되지 않는 결함이 실측됐다
# (spec/plan review Turn 006·008, 실측 재현) — 종류 컬럼이 빈 문자열인 행에서 뒤 컬럼이
# 밀리거나 전체 레코드가 한 필드로 들어가 ROW/PARSEFAIL 분기가 전부 스킵된다.
#
# 종료 코드: 0 = 정상 실행(4종 불일치·PARSEFAIL 신호 몇 건이든 무관)
#            2 = 검사 자체가 성립하지 않음(입력 부재, --root 오류, 읽기 실행 실패)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      case "${2-}" in
        ""|-?*)
          echo "check_fr_index_detail_consistency.sh: --root 에 값이 없습니다." >&2
          exit 2 ;;
      esac
      ROOT="$2"; shift 2 ;;
    *)
      echo "check_fr_index_detail_consistency.sh: 알 수 없는 인자: $1" >&2
      exit 2 ;;
  esac
done
[[ -n "$ROOT" ]] || ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ ! -d "${ROOT}/rd-workflow-workspace" ]]; then
  echo "check_fr_index_detail_consistency.sh: 기준 루트에 rd-workflow-workspace/ 가 없습니다: '${ROOT}'" >&2
  exit 2
fi

INDEX_FILE="${ROOT}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
ITEMS_DIR="${ROOT}/rd-workflow-workspace/backlog/items"

if [[ ! -f "$INDEX_FILE" ]]; then
  echo "check_fr_index_detail_consistency.sh: 인덱스 파일이 없습니다: '${INDEX_FILE}'" >&2
  exit 2
fi
if [[ ! -d "$ITEMS_DIR" ]]; then
  echo "check_fr_index_detail_consistency.sh: items 디렉터리가 없습니다: '${ITEMS_DIR}'" >&2
  exit 2
fi

EXEC_ERROR=0
M=0
P=0
K=0

# 인덱스 행 → basename(items/<파일>.md) 매핑 (bash 3.2 호환, 연관배열 미사용)
INDEX_BASENAMES=()
INDEX_KINDS=()
INDEX_LINES=()

_awk_out=""
_awk_out="$(awk '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  # 이스케이프 파이프를 뺀 셀 분해 — 결과는 C[](1-base, 앞뒤 빈 칸 포함)와 NC 에 담는다.
  function cells(line,   tmp) {
    tmp = line
    gsub(/\\[|]/, ESC, tmp)
    NC = split(tmp, C, "|")
    return NC
  }
  function unesc(s) { gsub(ESC, "\\\\|", s); return s }
  # 컬럼 번호 j(1-base) → 현재 레코드의 셀 번호. 앞 2개는 앞에서, 나머지는 뒤에서 센다.
  function colfield(j) { return (j <= 2) ? j + 1 : NC - 1 - (N - j) }
  BEGIN { in_index = 0; have_header = 0; N = 0; ESC = sprintf("%c", 1) }
  /^##/ { in_index = ($0 ~ /^##[ \t]*인덱스[ \t]*$/) ? 1 : 0 }
  in_index == 1 && have_header == 0 && /^\|/ {
    cells($0)
    N = NC - 2
    if (N >= 4) {
      for (j = 1; j <= N; j++) col[trim(C[j + 1])] = j
      i_date = (("날짜" in col) ? col["날짜"] : 0)
      i_title = (("제목" in col) ? col["제목"] : 0)
      i_summary = (("요약" in col) ? col["요약"] : 0)
      i_kind = (("종류" in col) ? col["종류"] : 0)
      i_status = (("상태" in col) ? col["상태"] : 0)
      i_priority = (("우선순위" in col) ? col["우선순위"] : 0)
      i_relation = (("관계" in col) ? col["관계"] : 0)
      i_detail = (("상세" in col) ? col["상세"] : 0)
      have_header = 1
    }
    next
  }
  /^\| [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \|/ {
    cells($0)
    if (have_header == 0 || i_kind == 0 || i_detail == 0 || NC - 2 < N) {
      printf "PARSEFAIL\034%d\034%s\n", NR, $0
      next
    }
    kind = unesc(trim(C[colfield(i_kind)]))
    detail_col = C[colfield(i_detail)]
    if (match(detail_col, /items\/[A-Za-z0-9_.-]+\.md/)) {
      detail = substr(detail_col, RSTART, RLENGTH)
      printf "ROW\034%d\034%s\034%s\n", NR, kind, detail
    } else {
      printf "PARSEFAIL\034%d\034%s\n", NR, $0
    }
  }
' "$INDEX_FILE" 2>&1)"
_awk_rc=$?
if [[ "$_awk_rc" -ne 0 ]]; then
  echo "check_fr_index_detail_consistency.sh: 인덱스 파싱 실행 오류 (awk rc=${_awk_rc}): ${_awk_out}" >&2
  EXEC_ERROR=1
fi

if [[ -n "$_awk_out" ]]; then
  while IFS=$'\034' read -r rtype rline rest1 rest2; do
    [[ -z "$rtype" ]] && continue
    case "$rtype" in
      ROW)
        M=$((M + 1))
        INDEX_BASENAMES+=("${rest2#items/}")
        INDEX_KINDS+=("$rest1")
        INDEX_LINES+=("$rline")
        ;;
      PARSEFAIL)
        P=$((P + 1))
        _snippet="${rest1:0:80}"
        echo "${INDEX_FILE##*/}:${rline}: 인덱스 행 파싱 실패 — ${_snippet}" >&2
        ;;
    esac
  done <<< "$_awk_out"
fi

# items/*.md 순회 — 활성 판정 + status/kind 필드 추출
_find_out=""
_find_out="$(find "$ITEMS_DIR" -maxdepth 1 -name '*.md' 2>&1)"
_find_rc=$?
if [[ "$_find_rc" -ne 0 ]]; then
  echo "check_fr_index_detail_consistency.sh: items 디렉터리 순회 실패 (find rc=${_find_rc}): ${_find_out}" >&2
  EXEC_ERROR=1
  _find_out=""
fi

ACTIVE_BASENAMES=()
N=0

_read_field() {
  # _read_field <file> <pattern> -> stdout: 값(트리밍) 또는 빈 문자열. 반환: 0=매치,
  # 1=매치 없음(정상), 2=읽기 실행 실패
  local file="$1" pattern="$2" line rc
  line="$(grep -m1 "$pattern" "$file" 2>/dev/null)"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    line="${line#*:}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "$line"
    return 0
  elif [[ "$rc" -eq 1 ]]; then
    return 1
  else
    return 2
  fi
}

if [[ -n "$_find_out" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    base="${f##*/}"

    status_val="$(_read_field "$f" '^- status:')"; status_rc=$?
    if [[ "$status_rc" -eq 2 ]]; then
      echo "items/${base}: 필드 읽기 실패 (status, grep rc=2)" >&2
      EXEC_ERROR=1
    fi

    kind_val="$(_read_field "$f" '^- kind:')"; kind_rc=$?
    if [[ "$kind_rc" -eq 2 ]]; then
      echo "items/${base}: 필드 읽기 실패 (kind, grep rc=2)" >&2
      EXEC_ERROR=1
    fi

    active=1
    case "$status_val" in
      done|dropped|parked) active=0 ;;
    esac

    if [[ "$active" -eq 1 ]]; then
      N=$((N + 1))
      ACTIVE_BASENAMES+=("$base")

      if [[ "$status_rc" -eq 1 ]]; then
        echo "items/${base}: 활성인데 - status: 필드 없음" >&2
        K=$((K + 1))
      fi
      if [[ "$kind_rc" -eq 1 ]]; then
        echo "items/${base}: 활성인데 - kind: 필드 없음" >&2
        K=$((K + 1))
      fi

      found_in_index=0
      idx=0
      for ib in "${INDEX_BASENAMES[@]+"${INDEX_BASENAMES[@]}"}"; do
        if [[ "$ib" == "$base" ]]; then
          found_in_index=1
          idx_kind="${INDEX_KINDS[$idx]}"
          idx_line="${INDEX_LINES[$idx]}"
          if [[ "$kind_rc" -eq 0 && "$idx_kind" != "$kind_val" ]]; then
            disp_idx_kind="$idx_kind"
            [[ -z "$disp_idx_kind" ]] && disp_idx_kind="<비어있음>"
            echo "items/${base}: 종류 불일치 (인덱스(${INDEX_FILE##*/}:${idx_line})=${disp_idx_kind}, 상세=${kind_val})" >&2
            K=$((K + 1))
          fi
          break
        fi
        idx=$((idx + 1))
      done
      if [[ "$found_in_index" -eq 0 ]]; then
        echo "items/${base}: 활성인데 인덱스에 행 없음" >&2
        K=$((K + 1))
      fi
    fi
  done <<< "$_find_out"
fi

# 인덱스 행 → 상세 파일 존재/활성 여부 역방향 확인
idx=0
for ib in "${INDEX_BASENAMES[@]+"${INDEX_BASENAMES[@]}"}"; do
  idx_line="${INDEX_LINES[$idx]}"
  detail_file="${ITEMS_DIR}/${ib}"
  if [[ ! -f "$detail_file" ]]; then
    echo "${INDEX_FILE##*/}:${idx_line}: 인덱스에 있으나 상세 파일 부재 (items/${ib})" >&2
    K=$((K + 1))
  else
    is_active=0
    for ab in "${ACTIVE_BASENAMES[@]+"${ACTIVE_BASENAMES[@]}"}"; do
      [[ "$ab" == "$ib" ]] && { is_active=1; break; }
    done
    if [[ "$is_active" -eq 0 ]]; then
      det_status="$(_read_field "$detail_file" '^- status:' 2>/dev/null)"
      [[ -z "$det_status" ]] && det_status="(필드 없음)"
      echo "items/${ib}: 인덱스(${INDEX_FILE##*/}:${idx_line})에 남아 있으나 상세 status=${det_status} (비활성)" >&2
      K=$((K + 1))
    fi
  fi
  idx=$((idx + 1))
done

echo "검사 완료 — 활성 상세 ${N}건, 인덱스 행 ${M}건(파싱 실패 ${P}건 제외), 불일치 ${K}건"

if [[ "$EXEC_ERROR" -eq 1 ]]; then
  exit 2
fi
exit 0
