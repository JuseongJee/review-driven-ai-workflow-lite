#!/usr/bin/env bash
# check_autopilot_promote_contract.sh — autopilot SKILL.md 의 승격 명령 계약을 정적 점검한다.
# 사용: bash check_autopilot_promote_contract.sh <skill-file>
#
# 왜 인라인이 아니라 스크립트인가 — `self_test.sh` 안에 두면 판정 로직을 테스트가 재사용할 수
# 없어 "검사가 실제로 오용을 잡는가" 를 자동으로 확인할 방법이 없다. 실제 SKILL.md 를 일부러
# 오염시켜 확인하는 방식은 같은 작업의 다른 변경과 로컬 변경을 함께 날릴 위험이 있다.
# (`check_promote_call_args.sh` 와 같은 근거다.)
#
# 점검 항목 — 전부 이 저장소에서 실제로 발생한 오용이다 (final diff review Findings):
#   1. 승격 명령이 모드별로 분리되어 있다 (한 블록이면 모드 B 도 large 로 시작한다)
#   2. `모드 A` 라벨 뒤의 명령은 `--size large`, `모드 B` 는 `--size small` (값 교차 차단)
#   3. 모든 승격 명령에 `--source-fr` 가 있다 (promote 가 REQUEST 작성보다 앞서므로)
#   4. §1 이 Source FR producer 이고 §3 승격이 REQUEST 작성보다 앞이라는 **순서 관계**
#
# 판정은 **백슬래시 개행을 이어붙인 논리 줄**에서 한다. 한 줄 단위로 보면 `\` 로 끝나는 줄을
# 건너뛰게 되어, `--source-fr` 를 지워도 continuation 이 남아 있으면 통과한다.
#
# 종료 코드: 0 위반 없음 / 1 위반 있음(사유를 stderr) / 2 점검이 성립하지 않음(파일 없음 등).
# 2 를 따로 두는 이유는 소비처가 "검사했고 깨끗했다" 와 "검사하지 못했다" 를 구분해야 하기 때문이다.
#
# **한계 (의도된 것)**: 이 검사는 문자열 구조만 본다. 문장의 의미까지는 판정하지 못한다 —
# anchor 를 정확한 문장에 걸수록 표현을 조금 바꿔도 깨지므로, 문서 개선을 막는 게이트가 된다.
# 그래서 4번은 "관계를 나타내는 anchor 구절이 §1 본문에 있는가" 까지만 본다. 의미 반전은
# 사람 리뷰의 몫이고, 이 검사는 **삭제·이동·값 교차** 를 잡는 것이 책임이다.
set -uo pipefail

SKILL="${1:-}"
if [[ -z "$SKILL" ]]; then
  echo "usage: check_autopilot_promote_contract.sh <skill-file>" >&2
  exit 2
fi
if [[ ! -f "$SKILL" ]]; then
  echo "check_autopilot_promote_contract: 대상 파일이 없습니다: '$SKILL'" >&2
  exit 2
fi

if [[ ! -r "$SKILL" ]]; then
  echo "check_autopilot_promote_contract: 대상 파일을 읽을 수 없습니다: '$SKILL'" >&2
  exit 2
fi

rc=0

# (1) 승격 명령 개수 — 모드별 분리
# `grep -c` 는 0건일 때 rc 1, **오류일 때 rc 2 이상**이다. `|| true` 로 뭉개면 읽기 오류가
# "0건" 이 되어 뒤의 검사들이 실패하고, 결과가 exit 1(계약 위반)로 오분류된다
# (final diff review 5라운드 Finding 3). 읽기 오류는 exit 2 다.
promote_lines="$(grep -c 'promote\.sh --short-title' "$SKILL")" || {
  _grc=$?
  if [[ "$_grc" -ge 2 ]]; then
    echo "check_autopilot_promote_contract: 파일을 읽지 못했습니다 (grep rc=$_grc) — 점검 결과를 신뢰할 수 없습니다." >&2
    exit 2
  fi
  promote_lines=0
}
if [[ "$promote_lines" -lt 2 ]]; then
  echo "  승격 명령이 모드별로 분리되지 않았습니다 (블록 ${promote_lines}개, 2개 이상 필요)" >&2
  echo "    한 블록이면 그대로 복사하는 실행자가 작은 작업도 large 로 시작합니다." >&2
  rc=1
fi

# (2)(3) 모드 라벨-size 대응 + --source-fr **값**. 논리 줄로 이어붙여 판정한다.
#
# **토큰 경계와 값을 함께 본다** (final diff review 5라운드 Finding 2).
#   - 부분 문자열로 보면 `--size largeish` 도 통과한다 → 값 뒤가 공백이나 줄끝이어야 한다.
#   - `--source-fr` 를 이름 존재만 보고 canonical 예시를 문서 전체에서 한 번만 확인하면,
#     한쪽 모드를 `--source-fr -` 나 값 누락으로 바꿔도 통과한다. 전자는 선택한 FR 연결을
#     **조용히** 잃고(CLI 가 `-` 를 허용하므로 성공한다), 후자는 실행에서 깨진다.
#     그래서 **명령마다** canonical 경로 형식을 요구한다.
if ! viol="$(awk '
  /^[[:space:]]*모드 A[ (]/ { mode="A"; next }
  /^[[:space:]]*모드 B[ (]/ { mode="B"; next }
  {
    line = $0
    start = NR
    while (line ~ /\\[ \t]*$/) {
      sub(/\\[ \t]*$/, "", line)
      if ((getline nxt) <= 0) break
      line = line " " nxt
    }
    if (line ~ /promote\.sh --short-title/) {
      # **옵션명의 양쪽 토큰 경계를 요구한다.** 오른쪽(값 뒤)만 보면 prefix 오타
      # `x--size large` 가 통과하는데, 실제 파서는 `x--size` 를 unknown arg 로 거부한다
      # (final diff review 7라운드 Finding 3). 왼쪽은 줄 시작 또는 공백이어야 한다.
      hasLarge = (line ~ /(^|[[:space:]])--size large([[:space:]]|$)/)
      hasSmall = (line ~ /(^|[[:space:]])--size small([[:space:]]|$)/)
      hasSfr   = (line ~ /(^|[[:space:]])--source-fr[[:space:]]+rd-workflow-workspace\/backlog\/items\/[^[:space:]]+\.md([[:space:]]|$)/)
      # **같은 옵션이 두 번 나오면 거부한다.** `promote.sh` 파서는 순서대로 대입하므로
      # 마지막 값이 이긴다. 기대값의 "존재" 만 보면 `--size small --size large` 가
      # hasSmall=1 로 통과하면서 실제로는 large 로 실행되고,
      # `--source-fr <canonical> --source-fr -` 는 Source FR 을 조용히 지운다.
      # 횟수 판정도 같은 양쪽 경계를 쓴다 — 한쪽만 보면 `x--size` 가 1회로 세어진다.
      tmp = line; nSize = gsub(/(^|[[:space:]])--size([[:space:]]|$)/, " ", tmp)
      tmp = line; nSfr  = gsub(/(^|[[:space:]])--source-fr([[:space:]]|$)/, " ", tmp)
      if (mode == "")                   print start ": 모드 라벨 없는 승격 명령"
      else if (mode == "A" && !hasLarge) print start ": 모드 A 는 --size large 여야 합니다 (값 경계 포함)"
      else if (mode == "B" && !hasSmall) print start ": 모드 B 는 --size small 여야 합니다 (값 경계 포함)"
      if (nSize != 1) print start ": --size 가 " nSize "회 나타납니다 — 정확히 1회여야 합니다 (파서는 마지막 값을 씁니다)"
      if (!hasSfr) print start ": --source-fr 에 canonical FR 경로(rd-workflow-workspace/backlog/items/<파일>.md)가 없습니다"
      if (nSfr != 1) print start ": --source-fr 가 " nSfr "회 나타납니다 — 정확히 1회여야 합니다 (파서는 마지막 값을 씁니다)"
      mode = ""
    }
  }
' "$SKILL")"; then
  echo "check_autopilot_promote_contract: 파일 판정 중 읽기 실패 — 점검 결과를 신뢰할 수 없습니다." >&2
  exit 2
fi
if [[ -n "$viol" ]]; then
  printf '%s\n' "$viol" | sed 's/^/  /' >&2
  rc=1
fi

# (4) §1 의 순서 관계 anchor. `### 1.` 부터 다음 `### ` 까지로 한정한다 —
#     문서 전체에서 토큰 존재만 보면 다른 절의 언급 하나로 통과한다.
if ! sec1="$(awk '/^### 1\./{s=1; next} s && /^### /{exit} s{print}' "$SKILL")"; then
  echo "check_autopilot_promote_contract: §1 추출 중 읽기 실패 — 점검 결과를 신뢰할 수 없습니다." >&2
  exit 2
fi
if [[ -z "$sec1" ]]; then
  echo "  §1(### 1.) 절을 찾지 못했습니다" >&2
  rc=1
else
  printf '%s' "$sec1" | grep -q 'producer' \
    || { echo "  §1 에 Source FR producer 서술이 없습니다" >&2; rc=1; }
  printf '%s' "$sec1" | grep -q -- '--source-fr' \
    || { echo "  §1 에 --source-fr 연결이 없습니다" >&2; rc=1; }
  # 순서 관계 anchor — "§3 ... 앞" 이 한 논리 줄 안에 함께 있어야 한다.
  # 토큰을 따로 세면 "§3" 과 "앞" 이 무관한 두 문장에 흩어져 있어도 통과한다.
  printf '%s\n' "$sec1" | grep -q '§3.*앞\|앞.*§3' \
    || { echo "  §1 에 '§3 승격이 REQUEST 작성보다 앞' 이라는 순서 관계 서술이 없습니다" >&2; rc=1; }
  printf '%s' "$sec1" | grep -q 'REQUEST' \
    || { echo "  §1 에 REQUEST 작성 순서 서술이 없습니다" >&2; rc=1; }
fi

exit "$rc"
