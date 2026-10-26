#!/usr/bin/env bash
# test_fr_relations.sh — fr_relations.sh 판정 규칙 단위 테스트.
# 케이스마다 fixture 를 리셋한다. 오류를 누적하면 어느 검사가 걸렸는지 가려진다.
# 실제 backlog 는 보지 않는다 (그쪽은 self_test 의 validate 스텝이 본다).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/fr_relations.sh"
FAIL=0
fx=""
cleanup() { [ -n "$fx" ] && rm -rf "$fx"; return 0; }
trap cleanup EXIT

reset_fx() {
  # 케이스마다 mktemp 를 부르면 fork 비용이 쌓인다. 디렉터리는 한 번만 만들고
  # 내용(주입 마커 포함)을 전부 지워 같은 격리를 유지한다.
  if [ -z "$fx" ]; then
    fx="$(mktemp -d)" || { echo "test_fr_relations.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
  else
    rm -rf "${fx:?}"/* "${fx:?}"/.rows
  fi
  ITEMS="${fx}/rd-workflow-workspace/backlog/items"
  INDEX="${fx}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
  mkdir -p "$ITEMS"
  : > "${fx}/.rows"
  printf '## 인덱스\n\n' > "$INDEX"
  printf '| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 관계 | 상세 |\n' >> "$INDEX"
  printf '|------|------|------|------|------|----------|------|------|\n' >> "$INDEX"
}

item() { # item <날짜> <short-title> <status> [필드 줄...]
  local d="$1" t="$2" st="$3"; shift 3
  { printf '# %s %s\n- status: %s\n- kind: feature\n- summary: fixture\n' "$d" "$t" "$st"
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
  } > "${ITEMS}/${d}-${t}.md"
}

row() { # row <날짜> <short-title> <상태> <우선순위> <관계> [요약]
  local sm="${6:-요약}"
  printf '| %s | %s | %s | feature | %s | %s | %s | [상세](items/%s-%s.md) |\n' \
    "$1" "$2" "$sm" "$3" "$4" "$5" "$1" "$2" >> "$INDEX"
}

check() { # check <설명> <기대> <실제>
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "  FAIL: $1" >&2; echo "    기대: [$2]" >&2; echo "    실제: [$3]" >&2; FAIL=1; fi
}

check_contains() { # check_contains <설명> <부분문자열> <실제>
  case "$3" in *"$2"*) echo "  ok: $1" ;;
    *) echo "  FAIL: $1" >&2; echo "    [$2] 가 없음: [$3]" >&2; FAIL=1 ;; esac
}

readiness_of() { bash "$TARGET" readiness --root "$fx" 2>/dev/null | awk -v s="$1" -F'\t' '$1==s {print $2}'; }
validate_out() { bash "$TARGET" validate --root "$fx" 2>&1; echo "rc=$?"; }

echo "== 케이스 1: 정상 관계 fixture 는 validate rc=0 =="
reset_fx
item 2026-01-01 lead done
item 2026-01-01 follow validated "- depends-on: 2026-01-01-lead"
item 2026-01-01 s1 validated "- series: demo #1/2"
item 2026-01-01 s2 validated "- series: demo #2/2"
row 2026-01-01 follow validated P2 'dep:2026-01-01-lead' '**[선행: lead]** 요약'
row 2026-01-01 s1 validated P2 'series:demo#1/2' '**[demo 1/2]** 요약'
row 2026-01-01 s2 validated P2 'series:demo#2/2' '**[demo 2/2]** 요약'
check "정상 fixture 는 위반 없음" "rc=0" "$(validate_out)"
# lead 는 done 이라 인덱스 행이 없다. 상세 파일로 찾아 충족으로 봐야 한다.
check "done 선행은 인덱스에 없어도 충족" "ready" "$(readiness_of 2026-01-01-follow)"

echo "== 케이스 2: 관계 필드 없음 → ready =="
reset_fx
item 2026-01-02 plain validated
row 2026-01-02 plain validated P2 -
check "필드 없는 FR 은 ready" "ready" "$(readiness_of 2026-01-02-plain)"
check "필드 없는 fixture 는 위반 없음" "rc=0" "$(validate_out)"

echo "== 케이스 3: depends-on 미충족 → waiting =="
reset_fx
item 2026-01-03 lead validated
item 2026-01-03 follow validated "- depends-on: 2026-01-03-lead"
row 2026-01-03 lead validated P1 -
row 2026-01-03 follow validated P1 'dep:2026-01-03-lead' '**[선행: lead]** 요약'
check "미완 선행은 waiting" "waiting:2026-01-03-lead" "$(readiness_of 2026-01-03-follow)"

echo "== 케이스 4: series 앞 순번이 done 이고 인덱스에 없음 → ready =="
reset_fx
item 2026-01-04 s1 done "- series: demo #1/2"
item 2026-01-04 s2 validated "- series: demo #2/2"
row 2026-01-04 s2 validated P2 'series:demo#2/2' '**[demo 2/2]** 요약'
check "done 인 앞 순번은 충족" "ready" "$(readiness_of 2026-01-04-s2)"
check "done 구성원이 인덱스에 없어도 위반 아님" "rc=0" "$(validate_out)"

echo "== 케이스 5: dropped 선행 → check =="
reset_fx
item 2026-01-05 lead dropped
item 2026-01-05 follow validated "- depends-on: 2026-01-05-lead"
row 2026-01-05 follow validated P2 'dep:2026-01-05-lead' '**[선행: lead]** 요약'
check "dropped 선행은 확인 필요" "check:2026-01-05-lead" "$(readiness_of 2026-01-05-follow)"

echo "== 케이스 6: parked·blocked 선행 → waiting =="
reset_fx
item 2026-01-06 pk parked
item 2026-01-06 bl blocked
item 2026-01-06 f1 validated "- depends-on: 2026-01-06-pk"
item 2026-01-06 f2 validated "- depends-on: 2026-01-06-bl"
row 2026-01-06 bl blocked P3 -
row 2026-01-06 f1 validated P2 'dep:2026-01-06-pk' '**[선행: pk]** 요약'
row 2026-01-06 f2 validated P2 'dep:2026-01-06-bl' '**[선행: bl]** 요약'
check "parked 선행은 waiting" "waiting:2026-01-06-pk" "$(readiness_of 2026-01-06-f1)"
check "blocked 선행은 waiting" "waiting:2026-01-06-bl" "$(readiness_of 2026-01-06-f2)"

echo "== 케이스 7: dangling → error + validate 비-0 =="
reset_fx
item 2026-01-07 bad validated "- depends-on: 2026-01-07-nope"
row 2026-01-07 bad validated P3 'dep:2026-01-07-nope' '**[선행: nope]** 요약'
check "없는 stem 참조는 error" "error:dangling:2026-01-07-nope" "$(readiness_of 2026-01-07-bad)"
out="$(validate_out)"; check_contains "validate 가 dangling 검출" "dangling" "$out"
check_contains "dangling 은 비-0" "rc=1" "$out"

echo "== 케이스 8: series 빠진 번호 → 전원 error =="
reset_fx
item 2026-01-08 only validated "- series: demo #2/2"
row 2026-01-08 only validated P2 'series:demo#2/2' '**[demo 2/2]** 요약'
check "1번이 없는 시리즈는 error" "error:series:demo" "$(readiness_of 2026-01-08-only)"
out="$(validate_out)"; check_contains "validate 가 series 결함 검출" "series" "$out"
check_contains "series 결함은 비-0" "rc=1" "$out"

echo "== 케이스 9: series M 불일치 → 전원 error =="
reset_fx
item 2026-01-09 x validated "- series: bad #1/3"
item 2026-01-09 y validated "- series: bad #2/2"
row 2026-01-09 x validated P3 'series:bad#1/3' '**[bad 1/3]** 요약'
row 2026-01-09 y validated P3 'series:bad#2/2' '**[bad 2/2]** 요약'
check "M 불일치는 x 도 error" "error:series:bad" "$(readiness_of 2026-01-09-x)"
check "M 불일치는 y 도 error" "error:series:bad" "$(readiness_of 2026-01-09-y)"
check_contains "M 불일치는 비-0" "rc=1" "$(validate_out)"

echo "== 케이스 10: 순환은 실제 구성원만 error, 순환 밖 후속은 waiting =="
reset_fx
item 2026-01-10 a validated "- series: mix #1/2" "- depends-on: 2026-01-10-b"
item 2026-01-10 b validated "- series: mix #2/2"
item 2026-01-10 c validated "- depends-on: 2026-01-10-b"
item 2026-01-10 d validated
row 2026-01-10 a validated P3 'series:mix#1/2; dep:2026-01-10-b' '**[mix 1/2 · 선행: b]** 요약'
row 2026-01-10 b validated P3 'series:mix#2/2' '**[mix 2/2]** 요약'
row 2026-01-10 c validated P3 'dep:2026-01-10-b' '**[선행: b]** 요약'
row 2026-01-10 d validated P3 -
check "a 는 순환 구성원이라 error" "error:cycle" "$(readiness_of 2026-01-10-a)"
check "b 는 순환 구성원이라 error" "error:cycle" "$(readiness_of 2026-01-10-b)"
check "c 는 순환 밖이라 waiting" "waiting:2026-01-10-b" "$(readiness_of 2026-01-10-c)"
check "d 는 무관해서 ready" "ready" "$(readiness_of 2026-01-10-d)"
out="$(validate_out)"; check_contains "validate 가 순환 검출" "cycle" "$out"
check_contains "순환은 비-0" "rc=1" "$out"
case "$out" in *"cycle"*"2026-01-10-c"*) echo "  FAIL: c 를 cycle 로 보고함" >&2; FAIL=1 ;;
  *) echo "  ok: c 는 cycle 보고 대상이 아님" ;; esac

echo "== 케이스 11: 인덱스 관계 컬럼 불일치 → validate 비-0, 판정은 상세 기준 =="
reset_fx
item 2026-01-11 lead validated
item 2026-01-11 follow validated "- depends-on: 2026-01-11-lead"
row 2026-01-11 lead validated P3 -
row 2026-01-11 follow validated P3 - '**[선행: lead]** 요약'
out="$(validate_out)"; check_contains "컬럼 누락 검출" "index-column" "$out"
check_contains "컬럼 불일치는 비-0" "rc=1" "$out"
check "판정은 상세 필드를 따른다" "waiting:2026-01-11-lead" "$(readiness_of 2026-01-11-follow)"

echo "== 케이스 12: 요약 앞머리 누락 → validate 비-0 =="
reset_fx
item 2026-01-12 lead validated
item 2026-01-12 follow validated "- depends-on: 2026-01-12-lead"
row 2026-01-12 lead validated P3 -
row 2026-01-12 follow validated P3 'dep:2026-01-12-lead' '앞머리 없는 요약'
out="$(validate_out)"; check_contains "앞머리 누락 검출" "summary-prefix" "$out"
check_contains "앞머리 누락은 비-0" "rc=1" "$out"

echo "== 케이스 13: priority-drift 만 있으면 rc=0 =="
reset_fx
item 2026-01-13 solo validated "- priority: P1"
row 2026-01-13 solo validated P3 -
out="$(validate_out)"
check_contains "priority-drift 를 보고한다" "priority-drift" "$out"
check_contains "priority-drift 만이면 rc=0" "rc=0" "$out"

echo "== 케이스 14: batch-draft 3분기와 short-title↔stem 변환 =="
reset_fx
item 2026-01-14 fin done
item 2026-01-14 outside validated
item 2026-01-14 inside validated
item 2026-01-14 target validated "- depends-on: 2026-01-14-inside, 2026-01-14-fin, 2026-01-14-outside"
row 2026-01-14 outside validated P3 -
row 2026-01-14 inside validated P3 -
row 2026-01-14 target validated P3 'dep:2026-01-14-inside,2026-01-14-fin,2026-01-14-outside' '**[선행: inside]** 요약'
draft="$(bash "$TARGET" batch-draft --root "$fx" --slugs "inside target")"
check "집합 안 선행은 short-title 로 낸다" "inside" \
  "$(printf '%s\n' "$draft" | awk -F'\t' '$1=="target" && $2=="depends_on" {print $3}')"
check "집합 밖 충족 선행은 stem 으로 낸다" "2026-01-14-fin" \
  "$(printf '%s\n' "$draft" | awk -F'\t' '$1=="target" && $2=="external-satisfied" {print $3}')"
check "집합 밖 미충족 선행은 stem 으로 낸다" "2026-01-14-outside" \
  "$(printf '%s\n' "$draft" | awk -F'\t' '$1=="target" && $2=="external-unmet" {print $3}')"

echo "== 케이스 15: batch-draft 초안이 실제 manifest validate 를 통과한다 =="
if command -v jq >/dev/null 2>&1; then
  mf="${fx}/manifest.json"
  deps="$(printf '%s\n' "$draft" | awk -F'\t' '$1=="target" && $2=="depends_on" {print $3}')"
  jq -n --arg d "$deps" '{
    finish_policy: "merge", status: "preparing",
    items: [
      {slug:"inside", order:1, depends_on:[], state:"pending", feasibility:"eligible"},
      {slug:"target", order:2, depends_on:($d|split(" ")), state:"pending", feasibility:"eligible"}
    ]}' > "$mf"
  if bash "${SCRIPT_DIR}/batch/batch_manifest.sh" validate "$mf" >/dev/null 2>&1; then
    echo "  ok: 초안으로 만든 manifest 가 validate 를 통과"
  else
    echo "  FAIL: 초안 manifest 가 batch_manifest.sh validate 에서 거부됨" >&2; FAIL=1
  fi
else
  echo "  skip: jq 없음 — manifest 연결 검사 생략"
fi

echo "== 케이스 16: batch-draft 의 관계 오류는 rc=1 =="
reset_fx
item 2026-01-16 broken validated "- depends-on: 2026-01-16-nope"
row 2026-01-16 broken validated P3 'dep:2026-01-16-nope' '**[선행: nope]** 요약'
out="$(bash "$TARGET" batch-draft --root "$fx" --slugs "broken" 2>&1; echo "rc=$?")"
check_contains "관계 오류를 error 로 낸다" "error" "$out"
check_contains "관계 오류는 rc=1" "rc=1" "$out"

echo "== 케이스 17: slug 미존재·복수 매칭은 rc=2 =="
reset_fx
item 2026-01-17 only validated
row 2026-01-17 only validated P3 -
out="$(bash "$TARGET" batch-draft --root "$fx" --slugs "nosuch" 2>&1; echo "rc=$?")"
check_contains "미존재 slug 는 rc=2" "rc=2" "$out"
item 2026-01-18 only validated
row 2026-01-18 only validated P3 -
out="$(bash "$TARGET" batch-draft --root "$fx" --slugs "only" 2>&1; echo "rc=$?")"
check_contains "복수 매칭은 rc=2" "rc=2" "$out"

echo "== 케이스 18: auto-pick 의 네 갈래 =="
reset_fx
item 2026-01-19 ideaonly idea
row 2026-01-19 ideaonly idea P1 -
check "idea 만 있으면 queue-empty" "queue-empty" "$(bash "$TARGET" auto-pick --root "$fx" | head -n1)"

reset_fx
item 2026-01-20 blk blocked
row 2026-01-20 blk blocked P1 -
check "blocked 만 있으면 queue-empty" "queue-empty" "$(bash "$TARGET" auto-pick --root "$fx" | head -n1)"

reset_fx
# lead 는 idea 라 eligible 이 아니고, follow 는 validated 지만 lead 를 기다린다.
# 즉 eligible 은 1건(follow) 인데 selectable 은 0건이다.
item 2026-01-21 lead idea
item 2026-01-21 follow validated "- depends-on: 2026-01-21-lead"
row 2026-01-21 lead idea P1 -
row 2026-01-21 follow validated P1 'dep:2026-01-21-lead' '**[선행: lead]** 요약'
ap="$(bash "$TARGET" auto-pick --root "$fx")"
check "eligible 은 있는데 전부 대기면 queue-blocked" "queue-blocked" "$(printf '%s\n' "$ap" | head -n1)"
check_contains "대기 상세에 FR 이름" "follow" "$ap"
check_contains "대기 상세에 다음 조치" "완료 필요" "$ap"

reset_fx
item 2026-01-22 win validated
item 2026-01-22 lose validated
row 2026-01-22 lose validated P3 -
row 2026-01-22 win validated P1 -
check "선택은 priority 순 첫 건" "$(printf 'select\t2026-01-22-win')" "$(bash "$TARGET" auto-pick --root "$fx" | head -n1)"

echo "== 케이스 19: status 권위는 상세 파일 =="
reset_fx
# 상세는 blocked 인데 인덱스가 오래된 validated 다. set-aside 한 FR 을 되살리면 안 된다.
item 2026-01-23 stale blocked
row 2026-01-23 stale validated P1 -
check "상세 blocked 는 고르지 않는다" "queue-empty" "$(bash "$TARGET" auto-pick --root "$fx" | head -n1)"

reset_fx
# 반대 방향. 상세가 validated 인데 인덱스가 idea 다. 실제 후보가 있으므로 골라야 한다.
item 2026-01-24 fresh validated
row 2026-01-24 fresh idea P2 -
check "상세 validated 는 고른다" "$(printf 'select\t2026-01-24-fresh')" "$(bash "$TARGET" auto-pick --root "$fx" | head -n1)"

echo "== 케이스 20: 내부 실패는 진단을 남기고 선택을 내지 않는다 =="
reset_fx
# items 는 읽히지만 인덱스가 없다 — 계산이 일부 진행된 뒤 실패하는 경로다.
item 2026-01-25 solo validated
rm -f "$INDEX"
# stdout·stderr·rc 를 한 번의 실행에서 받는다. 따로 부르면 서로 다른 실행을 검사한다.
ap_out="$(bash "$TARGET" auto-pick --root "$fx" 2>"${fx}/.err")"; ap_rc=$?
ap_err="$(cat "${fx}/.err")"
check "첫 줄은 unavailable" "unavailable" "$(printf '%s\n' "$ap_out" | head -n1)"
check "rc 는 2" "2" "$ap_rc"
detail="$(printf '%s\n' "$ap_out" | awk 'NR>1')"
if [ -n "$detail" ]; then echo "  ok: 둘째 줄에 진단이 있다"
else echo "  FAIL: 진단 행이 없다 (stderr: $ap_err)" >&2; FAIL=1; fi
check_contains "진단에 원인이 담긴다" "FUTURE_REQUESTS" "$detail"
case "$ap_out" in *select*) echo "  FAIL: 부분 결과로 select 를 냈다" >&2; FAIL=1 ;;
  *) echo "  ok: select 를 내지 않는다" ;; esac

# 실패 출력 계약을 검사한다 — 첫 줄·rc·진단 내용·판정 누출 부재.
# 이 fixture 가 "판정 생성 이후" 실패 경로를 실제로 지났는지는 이 자동 검사로 증명되지 않는다
# (인덱스를 먼저 보고 즉시 반환하는 구현도 같은 출력을 낸다). 그 도달 확인은 Task 1 Step 9 의
# 실행 추적 검수가 맡는다 — 둘을 합쳐야 R1 이 닫힌다 (spec/plan review turn 014).
reset_fx
item 2026-01-26 a validated
item 2026-01-26 b validated "- depends-on: 2026-01-26-a"
printf '## 인덱스\n\n표가 없는 본문\n' > "$INDEX"   # 헤더 행 부재 → 인덱스 파싱 실패
# stdout 과 rc 를 같은 호출에서 받는다. 따로 두 번 부르면 서로 다른 실행을 검사하게 된다.
ap_out="$(bash "$TARGET" auto-pick --root "$fx" 2>/dev/null)"; ap_rc=$?
check "판정 이후 실패도 첫 줄은 unavailable" "unavailable" "$(printf '%s\n' "$ap_out" | head -n1)"
check "판정 이후 실패도 rc 는 2" "2" "$ap_rc"
ap_detail="$(printf '%s\n' "$ap_out" | awk 'NR>1')"
if [ -n "$ap_detail" ]; then echo "  ok: 진단 행이 있다"
else echo "  FAIL: 진단 행이 없다" >&2; FAIL=1; fi
# 비어 있지 않음만 보면 원인을 빠뜨린 고정 문구도 통과한다. 실제 원인과 다음 조치를 확인한다.
check_contains "진단에 실제 원인" "인덱스" "$ap_detail"
check_contains "진단에 다음 조치" "validate" "$ap_detail"
# 토큰 부재만 보지 않는다. 진단 행을 뺀 나머지에 판정 흔적(stem·판정 토큰)이 하나라도
# 있으면 누출이다 — 원시 판정 행이 진단처럼 섞여 나오는 경우까지 잡는다.
leak="$(printf '%s\n' "$ap_out" | awk 'NR>1' | grep -E '2026-01-26-(a|b)|(^|[[:space:]])(ready|waiting|check)([[:space:]]|:|$)' || true)"
first="$(printf '%s\n' "$ap_out" | head -n1)"
case "$first" in
  unavailable) ;;
  *) echo "  FAIL: 첫 줄에 판정 결과가 나왔다: $first" >&2; FAIL=1 ;;
esac
if [ -z "$leak" ]; then echo "  ok: 판정 결과가 새지 않는다"
else echo "  FAIL: 판정 결과가 새어 나왔다: $leak" >&2; FAIL=1; fi

# 같은 입력에서 readiness 는 인덱스를 읽지 않으므로 정상 동작해야 한다.
# 이것이 깨지면 인덱스 손상 하나가 목록 전체를 막는다.
check "readiness 는 인덱스 없이도 동작" "ready" "$(readiness_of 2026-01-26-a)"
check "readiness 는 인덱스 없이도 판정" "waiting:2026-01-26-a" "$(readiness_of 2026-01-26-b)"
bash "$TARGET" readiness --root "$fx" >/dev/null 2>&1; r_rc=$?
check "readiness rc 는 0" "0" "$r_rc"

# ---------------------------------------------------------------- 주입 회귀
# mput/mget 은 키를 변수명으로 바꿔 eval 한다. 키에 셸 메타문자가 섞이면 임의 코드가
# 돈다. 세 입력 경로(파일명·관계 필드·인덱스 제목) 각각에서 마커 파일이 생기지 않는지
# 본다 — rc 나 출력만 보면 "실행은 됐지만 메시지는 그럴듯한" 경우를 놓친다.
export FX_MARK=""
no_marker() { # no_marker <설명>
  if [ -e "$FX_MARK" ]; then
    echo "  FAIL: $1 — 주입 코드가 실행되어 마커가 생성됨 ($FX_MARK)" >&2; FAIL=1
  else echo "  ok: $1"; fi
}

echo "== 케이스 21: items/ 파일명의 셸 메타문자 주입 =="
reset_fx
FX_MARK="${fx}/PWNED"
item 2026-01-27 good validated
row 2026-01-27 good validated P2 -
# 파일명 안에 `;>$FX_MARK;` 를 넣는다. eval 로 새면 리다이렉션이 마커를 만든다.
printf '# bad\n- status: validated\n- kind: feature\n- summary: fixture\n' \
  > "${ITEMS}/2026-01-27-a;>\$FX_MARK;x.md"
out="$(validate_out)"
no_marker "파일명 주입이 실행되지 않는다"
check "정상 FR 은 계속 판정된다" "ready" "$(readiness_of 2026-01-27-good)"
check "주입 파일명은 판정 대상이 아니다" "" "$(readiness_of '2026-01-27-a;>$FX_MARK;x')"
check_contains "validate 가 파일명 위반을 보고" "item-filename" "$out"
check_contains "파일명 위반은 비-0" "rc=1" "$out"

echo "== 케이스 22: depends-on 값의 셸 메타문자 주입 =="
reset_fx
FX_MARK="${fx}/PWNED"
# 토큰은 mget 의 `${...}` 안으로 들어간다. `:-}` 로 치환을 닫고 명령 치환을 이어 붙이면
# 그 자리에서 실행된다 — `;` 만 넣으면 bad substitution, `-}` 만 넣으면 set -u 의
# unbound variable 로 끝나 재현되지 않는다 (실측).
item 2026-01-28 target validated '- depends-on: 2026-01-28-x:-}$(>$FX_MARK)${z'
row 2026-01-28 target validated P2 'dep:2026-01-28-x' '**[선행: x]** 요약'
v="$(readiness_of 2026-01-28-target)"
out="$(validate_out)"
no_marker "depends-on 주입이 실행되지 않는다"
check "주입 토큰은 error:parse:depends-on" "error:parse:depends-on" "$v"
check_contains "validate 가 관계 필드 위반을 보고" "parse" "$out"
check_contains "관계 필드 위반은 비-0" "rc=1" "$out"

echo "== 케이스 23: 인덱스 제목 컬럼의 셸 메타문자 주입 =="
reset_fx
FX_MARK="${fx}/PWNED"
item 2026-01-29 solo validated
row 2026-01-29 solo validated P2 -
# 상세 링크가 없으면 stem 을 `날짜-제목` 으로 만든다. 그 제목에 주입을 넣는다.
printf '| 2026-01-29 | a;>$FX_MARK;x | 요약 | feature | validated | P2 | - | - |\n' >> "$INDEX"
out="$(validate_out)"
no_marker "인덱스 제목 주입이 실행되지 않는다"
check "readiness 는 인덱스와 무관하게 판정" "ready" "$(readiness_of 2026-01-29-solo)"
check_contains "깨진 인덱스는 실행 불가(rc=2)" "rc=2" "$out"
check_contains "진단에 stem 형식 오류 원인" "형식 오류" "$out"
ap="$(bash "$TARGET" auto-pick --root "$fx" 2>/dev/null)"
check "auto-pick 도 선택을 내지 않는다" "unavailable" "$(printf '%s\n' "$ap" | head -n1)"
no_marker "auto-pick 경로에서도 실행되지 않는다"

# ---------------------------------------------------------------- 인덱스 구조 손상
# 손상된 인덱스 행을 조용히 건너뛰면 그 FR 의 priority 가 사라져 auto-pick 이 다른 FR 을
# 고른다. 사용자가 지정한 우선순위가 경고 없이 뒤집히므로 진단 + rc=2 로 끝내야 한다.

echo "== 케이스 24: 셀 수 부족·오른쪽 컬럼 정렬 어긋남은 진단 + rc=2 =="
reset_fx
item 2026-01-30 high validated
item 2026-01-30 low validated
# high 행에서 관계 셀 하나를 뺀다 (헤더 8칸, 행 7칸).
printf '| 2026-01-30 | high | 요약 | feature | validated | P1 | [상세](items/2026-01-30-high.md) |\n' >> "$INDEX"
row 2026-01-30 low validated P3 -
ap="$(bash "$TARGET" auto-pick --root "$fx" 2>/dev/null)"; ap_rc=$?
check "짧은 행이 있으면 unavailable" "unavailable" "$(printf '%s\n' "$ap" | head -n1)"
check "짧은 행은 rc=2" "2" "$ap_rc"
check_contains "진단에 셀 수 부족 원인" "셀 수 부족" "$ap"
case "$ap" in *select*) echo "  FAIL: 짧은 행인데 select 를 냈다" >&2; FAIL=1 ;;
  *) echo "  ok: select 를 내지 않는다" ;; esac
check_contains "validate 도 rc=2" "rc=2" "$(validate_out)"

# 셀 수를 부풀려 부족을 가리는 두 조합. 둘 다 P1 행의 우선순위가 다른 컬럼 값으로 읽혀
# auto-pick 이 P3 를 먼저 고르는 결과로 이어진다. 진단 없이 순서만 뒤집히면 안 된다.
# 한 번의 호출에서 rc·첫 줄·select 부재를 함께 본다 — 따로 부르면 다른 실행을 검사한다.
bad_row_is_unavailable() { # bad_row_is_unavailable <설명> <high 행>
  local desc="$1" high="$2" ap ap_rc
  reset_fx
  item 2026-01-30 high validated
  item 2026-01-30 low validated
  printf '%s\n' "$high" >> "$INDEX"
  row 2026-01-30 low validated P3 -
  ap="$(bash "$TARGET" auto-pick --root "$fx" 2>/dev/null)"; ap_rc=$?
  check "${desc}: 첫 줄은 unavailable" "unavailable" "$(printf '%s\n' "$ap" | head -n1)"
  check "${desc}: rc 는 2" "2" "$ap_rc"
  if [ -n "$(printf '%s\n' "$ap" | awk 'NR>1')" ]; then echo "  ok: ${desc}: 진단 행이 있다"
  else echo "  FAIL: ${desc}: 진단 행이 없다" >&2; FAIL=1; fi
  case "$ap" in *select*) echo "  FAIL: ${desc}: select 를 냈다" >&2; FAIL=1 ;;
    *) echo "  ok: ${desc}: select 를 내지 않는다" ;; esac
}

# ① 관계 셀 누락 + 요약의 이스케이프된 `\|`. `\|` 를 셀 구분자로 세면 셀 수가 헤더와
#    같아져 부족 검사를 그대로 통과한다.
bad_row_is_unavailable "관계 셀 누락 + 요약 \\|" \
  '| 2026-01-30 | high | 요약 \| 둘 | feature | validated | P1 | [상세](items/2026-01-30-high.md) |'

# ② 관계 셀 누락 + 요약의 이스케이프하지 않은 `|`. 셀 수로는 구분되지 않으므로
#    오른쪽 고정 컬럼의 구조(우선순위 셀 형식)로 정렬 어긋남을 잡아야 한다.
bad_row_is_unavailable "관계 셀 누락 + 요약 미이스케이프 |" \
  '| 2026-01-30 | high | 요약 | 둘 | feature | validated | P1 | [상세](items/2026-01-30-high.md) |'

echo "== 케이스 25: 필수 헤더 손상은 진단 + rc=2 =="
reset_fx
item 2026-01-31 solo validated
# 헤더의 `우선순위` 를 오타로 바꾼다. 위치 해석이 통째로 틀어지므로 성공시키면 안 된다.
printf '## 인덱스\n\n' > "$INDEX"
printf '| 날짜 | 제목 | 요약 | 종류 | 상태 | priority-typo | 관계 | 상세 |\n' >> "$INDEX"
printf '|---|---|---|---|---|---|---|---|\n' >> "$INDEX"
row 2026-01-31 solo validated P1 -
ap="$(bash "$TARGET" auto-pick --root "$fx" 2>/dev/null)"; ap_rc=$?
check "필수 헤더 오타는 unavailable" "unavailable" "$(printf '%s\n' "$ap" | head -n1)"
check "필수 헤더 오타는 rc=2" "2" "$ap_rc"
check_contains "진단에 필수 헤더 원인" "필수 헤더" "$ap"
case "$ap" in *select*) echo "  FAIL: 헤더가 깨졌는데 select 를 냈다" >&2; FAIL=1 ;;
  *) echo "  ok: select 를 내지 않는다" ;; esac
check "readiness 는 헤더 손상과 무관" "ready" "$(readiness_of 2026-01-31-solo)"

echo "== 케이스 26: 정상 legacy(7컬럼)·GitHub 변형은 그대로 동작 =="
reset_fx
item 2026-02-01 win validated
item 2026-02-01 lose validated
idx_head() { printf '## 인덱스\n\n%s\n%s\n' "$1" "$2" > "$INDEX"; }
# legacy 7컬럼 — 관계 컬럼이 없어도 우선순위·상세 위치를 찾아야 한다.
idx_head '| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |' '|---|---|---|---|---|---|---|'
printf '| 2026-02-01 | lose | 요약 | feature | validated | P3 | [상세](items/2026-02-01-lose.md) |\n' >> "$INDEX"
printf '| 2026-02-01 | win | 요약 | feature | validated | P1 | [상세](items/2026-02-01-win.md) |\n' >> "$INDEX"
check "legacy 7컬럼에서 우선순위대로 선택" "$(printf 'select\t2026-02-01-win')" \
  "$(bash "$TARGET" auto-pick --root "$fx" | head -n1)"

# GitHub 컬럼 변형 — 요약 셀의 이스케이프된 `|` 까지 함께 본다.
idx_head '| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 관계 | 상세 | GitHub |' '|---|---|---|---|---|---|---|---|---|'
printf '| 2026-02-01 | lose | 요약 \\| 둘 | feature | validated | P3 | - | [상세](items/2026-02-01-lose.md) | #11 |\n' >> "$INDEX"
printf '| 2026-02-01 | win | 요약 | feature | validated | P1 | - | [상세](items/2026-02-01-win.md) | #12 |\n' >> "$INDEX"
check "GitHub 변형에서 우선순위대로 선택" "$(printf 'select\t2026-02-01-win')" \
  "$(bash "$TARGET" auto-pick --root "$fx" | head -n1)"
check_contains "GitHub 변형은 위반 없음" "rc=0" "$(validate_out)"

# ---------------------------------------------------------------- 비활성 FR 관계 검증
# 이관한 FR 이 전부 done 이면 활성만 도는 validate 는 번호·참조 오류를 못 본다.

echo "== 케이스 27: 비활성 FR 만 있어도 관계 결함을 검출 =="
reset_fx
item 2026-02-03 ser done "- series: demo #2/2"
item 2026-02-03 dang dropped "- depends-on: 2026-02-03-absent"
out="$(validate_out)"
check_contains "비활성 시리즈 결함 검출" "series	2026-02-03-ser" "$out"
check_contains "비활성 dangling 검출" "dangling	2026-02-03-dang" "$out"
check_contains "비활성 관계 결함은 비-0" "rc=1" "$out"
check "readiness 는 비활성을 내지 않는다" "" "$(bash "$TARGET" readiness --root "$fx" 2>/dev/null)"

reset_fx
# 정상 비활성 시리즈는 위반이 아니다 — 범위를 넓혀도 오탐이 나면 안 된다.
item 2026-02-05 s1 done "- series: ok #1/2"
item 2026-02-05 s2 parked "- series: ok #2/2"
check_contains "정상 비활성 시리즈는 위반 없음" "rc=0" "$(validate_out)"

if [ "$FAIL" -eq 0 ]; then echo "test_fr_relations.sh: PASS"; else echo "test_fr_relations.sh: FAIL" >&2; fi
exit "$FAIL"
