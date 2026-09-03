#!/usr/bin/env bash
# check_promote_call_args.sh — 활성 자료의 promote.sh 실행 예시가 시작 상태 인자를
# 갖는지 정적으로 점검한다. 사용: bash check_promote_call_args.sh [root]
#
# 활성 자료의 정의 (change spec D2-3): _ROOT_FILES/ · rd-workflow/ · scripts/ · CLAUDE.md
# 제외: rd-workflow-workspace/ — 과거 plan·report·handoffs 는 그 시점의 사실을 적은
#       불변 이력이다. 지금 계약에 맞춰 고치면 이력이 아니게 된다.
# 이 경계를 바꾸려면 change spec D2-3 을 함께 고친다.
# 지속 게이트이므로 fail-closed 다 — 점검 자체가 실패하면 통과가 아니라 실패로 끝난다.
# set -e 없이 두면 임시 파일 쓰기 실패나 잘못된 root 가 "위반 0건" 으로 보인다.
#
# 종료 코드: 0 위반 0건 / 1 위반 있음(목록을 stderr) / 2 점검 자체가 성립하지 않음.
# 2 를 따로 두는 이유는 소비처가 "검사했고 깨끗했다" 와 "검사하지 못했다" 를 구분해야
# 하기 때문이다. 2 를 0 으로 뭉개면 게이트가 조용히 죽는다.
set -uo pipefail
ROOT="${1:-.}"
TARGETS="_ROOT_FILES rd-workflow scripts CLAUDE.md"
FIND_MARKER="__FIND_FAILED__"

if [[ ! -d "$ROOT" ]]; then
  echo "check_promote_call_args: 점검 루트가 디렉터리가 아닙니다: '$ROOT'" >&2
  exit 2
fi

# 점검 대상이 하나도 없으면 "위반 0건" 이 아니라 "아무것도 검사하지 못함" 이다.
# 경로 오타나 트리 구조 변경이 조용히 게이트를 무력화하는 것을 막는다.
found_targets=0
for tgt in $TARGETS; do
  [[ -e "$ROOT/$tgt" ]] && found_targets=$((found_targets+1))
done
if [[ "$found_targets" -eq 0 ]]; then
  echo "check_promote_call_args: 점검 대상이 없습니다 — '$ROOT' 아래에 다음이 하나도 없습니다: $TARGETS" >&2
  exit 2
fi

TMP="$(mktemp)" || { echo "check_promote_call_args: 임시 파일을 만들 수 없습니다." >&2; exit 2; }
trap 'rm -f "$TMP"' EXIT INT TERM

rc=0
# 점검 대상은 "사람이 읽고 그대로 실행하는 안내 예시" 다 (change spec D2-3 의 활성 자료).
# 아래 셋은 그 성격이 아니므로 제외한다 — 제외하지 않으면 게이트가 자기 자신과
# 테스트를 위반으로 보고, 그것을 없애려면 회귀 fixture 에 --size 를 넣어야 해서
# "위반을 실제로 잡는가" 를 검증하는 케이스가 검증력을 잃는다.
#   ① 이 스크립트 자신 — 패턴 문자열(`*bash*promote.sh*`)이 자기 검사에 걸리는 순환.
#   ② `test_*.sh` — 의도적 위반 fixture 를 만드는 것이 그 파일의 일이다.
#   ③ `promote.sh "$@"` 형태 — 인자를 그대로 넘기는 래퍼는 시작 상태를 호칭할 수 없다.
# ①②는 파일 단위, ③은 줄 단위 제외다.
SELF_BASE="$(basename "${BASH_SOURCE[0]}")"
for tgt in $TARGETS; do
  [[ -e "$ROOT/$tgt" ]] || continue
  # 파일별로: 백슬래시 개행을 이어붙여 논리 줄을 만든 뒤 promote.sh 실행 형태를 찾는다.
  # 이어붙이기가 없으면 README 의 멀티라인 용법 블록을 위반으로 오탐한다.
  while IFS= read -r f; do
    # find 실패 마커는 파일이 아니므로 awk 로 넘기면 그대로 사라진다 — 그러면 아래
    # 마커 검사가 영원히 통과해 점검 실패가 "위반 0건" 으로 보인다. 여기서 TMP 로
    # 흘려보내 exit 2 판정에 도달하게 한다.
    if [[ "$f" == "$FIND_MARKER" ]]; then
      printf '%s\n' "$FIND_MARKER"
      continue
    fi
    base="$(basename "$f")"
    [[ "$base" == "$SELF_BASE" ]] && continue
    case "$base" in
      test_*.sh) continue ;;
    esac
    # awk 의 종료 상태를 검사한다. `set -e` 가 없고 아래 pipeline 이 0 으로 끝나므로,
    # 검사하지 않으면 권한·I/O 오류로 읽지 못한 파일이 "위반 0건" 으로 소실된다 —
    # "점검 자체 실패는 exit 2" 계약과 어긋난다 (final diff review Finding 5).
    if ! joined="$(awk '{
      line = $0
      while (line ~ /\\[ \t]*$/) {
        sub(/\\[ \t]*$/, "", line)
        if ((getline nxt) <= 0) break
        line = line " " nxt
      }
      print line
    }' "$f")"; then
      printf '%s\n' "$FIND_MARKER"
      continue
    fi
    printf '%s\n' "$joined" | while IFS= read -r logical; do
      # 실행 형태만 본다 — `bash <경로>promote.sh` 형태
      case "$logical" in
        *bash*promote.sh*) ;;
        *) continue ;;
      esac
      # usage 문자열은 대상이 아니다
      case "$logical" in
        *usage:*) continue ;;
      esac
      # 인자를 그대로 넘기는 래퍼는 시작 상태를 호칭할 수 없다 — 호출자가 준다
      case "$logical" in
        *promote.sh\ \"\$@\"*) continue ;;
      esac
      # 시작 상태 인자가 있으면 통과
      case "$logical" in
        *--size*|*--status*) continue ;;
      esac
      printf '%s: %s\n' "${f#$ROOT/}" "$logical"
    done
    # find 실패는 조용히 넘기지 않는다 — 권한 문제나 경로 오류가 위반 0건으로 보인다
  done < <(find "$ROOT/$tgt" -type f \( -name '*.md' -o -name '*.sh' \) || echo "$FIND_MARKER")
done >> "$TMP" || { echo "check_promote_call_args: 점검 실행이 실패했습니다." >&2; exit 2; }

if grep -q "$FIND_MARKER" "$TMP" 2>/dev/null; then
  echo "check_promote_call_args: 파일 목록 또는 파일 내용을 읽지 못했습니다 — 점검 결과를 신뢰할 수 없습니다." >&2
  exit 2
fi

if [[ -s "$TMP" ]]; then
  echo "시작 상태 인자(--size|--status)가 없는 promote.sh 실행 예시:" >&2
  sed 's/^/  /' "$TMP" >&2
  echo "  → --size large (큰 작업) 또는 --size small (작은 작업) 을 추가하세요." >&2
  rc=1
fi
exit "$rc"
