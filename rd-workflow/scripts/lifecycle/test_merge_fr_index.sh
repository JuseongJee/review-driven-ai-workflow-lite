#!/usr/bin/env bash
# test_merge_fr_index.sh — FUTURE_REQUESTS.md 행 집합 3-way 병합 단위 테스트 (self_test lifecycle 그룹)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$SCRIPT_DIR/merge_fr_index.sh"
T="$(mktemp -d)" || { echo "test_merge_fr_index.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$T" && -d "$T" ]] || { echo "test_merge_fr_index.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
hdr='# FUTURE_REQUESTS

설명 문단.

## 인덱스

| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |
|------|------|------|------|------|----------|------|'
rowA='| 2026-01-01 | a | 요약a | tooling | idea | - | [상세](items/2026-01-01-a.md) |'
rowB='| 2026-01-02 | b | 요약b | tooling | idea | - | [상세](items/2026-01-02-b.md) |'
rowX='| 2026-01-03 | x | 요약x | tooling | idea | - | [상세](items/2026-01-03-x.md) |'
rowY='| 2026-01-04 | y | 요약y | tooling | idea | - | [상세](items/2026-01-04-y.md) |'
rowA2='| 2026-01-01 | a | 요약a | tooling | validated | P1 | [상세](items/2026-01-01-a.md) |'
rowA3='| 2026-01-01 | a | 요약a | tooling | dropped | - | [상세](items/2026-01-01-a.md) |'
mk() { printf '%s\n' "$hdr" "${@}" > "$T/$F"; }  # mk 는 F 변수의 파일명에 쓴다
run() { bash "$M" "$T/base" "$T/ours" "$T/theirs" > "$T/out" 2> "$T/err"; echo $?; }

# 1) 동일 행을 양쪽이 추가 + ours 가 하나 더 추가 (AC 13 변형: 기본 브랜치에 다른 행 직접 추가)
F=base mk "$rowA"; F=ours mk "$rowA" "$rowX" "$rowY"; F=theirs mk "$rowA" "$rowX"
[[ "$(run)" == 0 ]] && [[ "$(cat "$T/out")" == "$(printf '%s\n' "$hdr" "$rowA" "$rowX" "$rowY")" ]] \
  && pass "동일 추가 X 는 한 번, ours 추가 Y 유지" || fail "동일 추가 — $(cat "$T/out" "$T/err")"
# 2) 서로 다른 행 추가 (ours 먼저, theirs 다음)
F=base mk "$rowA"; F=ours mk "$rowA" "$rowX"; F=theirs mk "$rowA" "$rowY"
[[ "$(run)" == 0 ]] && [[ "$(cat "$T/out")" == "$(printf '%s\n' "$hdr" "$rowA" "$rowX" "$rowY")" ]] \
  && pass "서로 다른 추가 → ours 순서 뒤 theirs" || fail "서로 다른 추가 — $(cat "$T/out" "$T/err")"
# 3) theirs 가 행 삭제(FR done), ours 는 행 추가
F=base mk "$rowA" "$rowB"; F=ours mk "$rowA" "$rowB" "$rowX"; F=theirs mk "$rowB"
[[ "$(run)" == 0 ]] && [[ "$(cat "$T/out")" == "$(printf '%s\n' "$hdr" "$rowB" "$rowX")" ]] \
  && pass "theirs 삭제 + ours 추가" || fail "삭제+추가 — $(cat "$T/out" "$T/err")"
# 4) 한쪽만 행 수정 → 수정 반영
F=base mk "$rowA"; F=ours mk "$rowA2"; F=theirs mk "$rowA"
[[ "$(run)" == 0 ]] && [[ "$(cat "$T/out")" == "$(printf '%s\n' "$hdr" "$rowA2")" ]] \
  && pass "ours 만 수정 → 반영" || fail "한쪽 수정 — $(cat "$T/out" "$T/err")"
# 5) 같은 행을 양쪽이 다르게 수정 → 충돌
F=base mk "$rowA"; F=ours mk "$rowA2"; F=theirs mk "$rowA3"
[[ "$(run)" == 1 && ! -s "$T/out" ]] && pass "양쪽 상이 수정 → rc 1, stdout 없음" || fail "충돌 미감지 — $(cat "$T/out")"
# 6) 서문을 양쪽이 다르게 수정 → 충돌
F=base mk "$rowA"; F=ours mk "$rowA"; F=theirs mk "$rowA"
printf '%s\n' "${hdr/설명 문단./ours 문단.}" "$rowA" > "$T/ours"; printf '%s\n' "${hdr/설명 문단./theirs 문단.}" "$rowA" > "$T/theirs"
[[ "$(run)" == 1 ]] && pass "서문 상이 수정 → rc 1" || fail "서문 충돌 미감지"
# 7) 한 파일 안 제목 중복 → 충돌
F=base mk "$rowA"; F=ours mk "$rowA" "$rowA2"; F=theirs mk "$rowA"
[[ "$(run)" == 1 ]] && pass "제목 중복 → rc 1" || fail "중복 미감지"
# 8~11) malformed 입력은 fail-closed (archive 가 손상된 인덱스를 merge 커밋으로 확정하지 못하게)
F=base mk "$rowA"; F=ours mk "$rowA"; printf '# 표 없음\n' > "$T/theirs"
[[ "$(run)" == 1 && ! -s "$T/out" ]] && pass "표 없는 입력 → rc 1, stdout 없음" || fail "표 없음 미감지"
F=base mk "$rowA"; F=ours mk "$rowA" '| 2026-01-05 |  | 빈 제목 | tooling | idea | - | x |'; F=theirs mk "$rowA"
[[ "$(run)" == 1 ]] && pass "빈 제목 행 → rc 1" || fail "빈 제목 미감지"
F=base mk "$rowA"; F=ours mk "$rowA" '| 2026-01-05 | short | 컬럼 부족 |'; F=theirs mk "$rowA"
[[ "$(run)" == 1 ]] && pass "컬럼 수 불일치 → rc 1" || fail "컬럼 수 미감지"
F=base mk "$rowA"; F=ours mk "$rowA" '' '## 다른 절' '| 날짜 | 제목 |' '|---|---|'; F=theirs mk "$rowA"
[[ "$(run)" == 1 ]] && pass "표 뒤 본문·둘째 표 → rc 1" || fail "둘째 표 미감지"
F=base mk "$rowA"; F=ours mk "$rowA"; printf '%s\n' '# FUTURE_REQUESTS' '' '| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |' '|---|---|---|' "$rowA" > "$T/theirs"
[[ "$(run)" == 1 ]] && pass "구분선 컬럼 수 불일치 → rc 1" || fail "구분선 컬럼 수 미감지"
# 스키마 변경(theirs 헤더·기존 행 8열) + 반대편 행 추가(ours 7열): 입력 셋은 각각 유효하지만 결과는 malformed → 충돌로 처리(rc 1, stdout 없음)
hdr8="${hdr%|------|------|------|------|------|----------|------|}"; hdr8="${hdr8/| 상세 |/| 상세 | GitHub |}|------|------|------|------|------|----------|------|--------|"
rowA8='| 2026-01-01 | a | 요약a | tooling | idea | - | [상세](items/2026-01-01-a.md) | - |'
F=base mk "$rowA"; F=ours mk "$rowA" "$rowX"; printf '%s\n' "$hdr8" "$rowA8" > "$T/theirs"
[[ "$(run)" == 1 && ! -s "$T/out" ]] && pass "스키마 변경 + 반대편 행 추가 → rc 1(결과 컬럼 불일치)" || fail "스키마 변경 병합 통과 — $(cat "$T/out" "$T/err")"

# 14~16) 셀 본문의 파이프 — 컬럼 분해는 GFM 과 같게 이스케이프되지 않은 `|` 로만 나눈다
#   (fr-index-merge-escaped-pipe: `split($0,t,"|")` 가 `\|` 를 구분자로 오인해 정상 행을 거부했다)
rowEsc='| 2026-01-05 | e | `foo `\|`\| true` 를 붙임 | bug | idea | P2 | [상세](items/2026-01-05-e.md) |'
F=base mk "$rowA"; F=ours mk "$rowA" "$rowEsc"; F=theirs mk "$rowA"
[[ "$(run)" == 0 ]] && [[ "$(cat "$T/out")" == "$(printf '%s\n' "$hdr" "$rowA" "$rowEsc")" ]] \
  && pass "이스케이프된 \\| 는 구분자가 아니고 원본 바이트가 보존된다" || fail "이스케이프 파이프 — rc=$(run) $(cat "$T/err")"

rowRaw='| 2026-01-06 | r | `grep -c x | wc -l` 로 셈 | bug | idea | P2 | [상세](items/2026-01-06-r.md) |'
F=base mk "$rowA"; F=ours mk "$rowA" "$rowRaw"; F=theirs mk "$rowA"
[[ "$(run)" == 1 && ! -s "$T/out" ]] && grep -q "ours 10행" "$T/err" \
  && grep -qF '`\|` 로 이스케이프' "$T/err" \
  && grep -qF '구분자로 센 위치: >|< 2026-01-06 >|< r >|< `grep -c x >|< wc -l` 로 셈 >|<' "$T/err" \
  && pass "이스케이프 안 된 생 | 는 거부되고 메시지에 행 번호·이스케이프 안내가 담긴다" || fail "생 파이프 — rc=$(run) err=$(cat "$T/err")"

# `\\|` = 본문 역슬래시 + 구분자. 아래 행은 그래서 8열로 세어져 헤더(7열)와 어긋난다 (분해기의 역슬래시 처리 검증)
rowBs='| 2026-01-07 | s | 경로는 `C:\\| 뒤 | bug | idea | P2 | [상세](items/2026-01-07-s.md) |'
F=base mk "$rowA"; F=ours mk "$rowA" "$rowBs"; F=theirs mk "$rowA"
[[ "$(run)" == 1 && ! -s "$T/out" ]] && pass "\\\\| 는 본문 역슬래시 + 구분자로 세어진다" || fail "\\\\| 처리 — rc=$(run) $(cat "$T/out" "$T/err")"

# 17) 이중 백틱 스팬 안의 생 | — 진단은 백틱 문법을 해석하지 않으므로 스팬 길이에 무관하게 같다
rowRaw2='| 2026-01-08 | t | ``code | span`` 안 | bug | idea | P2 | [상세](items/2026-01-08-t.md) |'
F=base mk "$rowA"; F=ours mk "$rowA" "$rowRaw2"; F=theirs mk "$rowA"
[[ "$(run)" == 1 && ! -s "$T/out" ]] && grep -qF '구분자로 센 위치: >|< 2026-01-08 >|< t >|< ``code >|< span`` 안 >|<' "$T/err" \
  && pass "이중 백틱 스팬도 같은 진단(구분자 표시)을 받는다" || fail "이중 백틱 — rc=$(run) err=$(cat "$T/err")"

echo "merge_fr_index: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
