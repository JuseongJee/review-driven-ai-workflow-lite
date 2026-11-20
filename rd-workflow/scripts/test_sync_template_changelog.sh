#!/usr/bin/env bash
# test_sync_template_changelog.sh — sync_template.sh changelog 시험 (C9: A1 이전 절 제외, A2 빈 뒤 항목 안내, A3 이전=받은 때 다음 발행 제외, A4 VERSION 값 비실행)
# fixture 는 mktemp -d 아래에만 만든다. 네트워크·실제 프로젝트 접근 없음.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
WORK="$(mktemp -d)" || { echo "test_sync_template_changelog.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "test_sync_template_changelog.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=_tpl_test_common.sh
source "$SCRIPT_DIR/_tpl_test_common.sh"

has() { [[ "$TPL_OUT" == *"$1"* ]] && echo yes || echo no; }

cl_case() { # cl_case <이름> <이전 VERSION 원문> <받은 VERSION> <CHANGELOG 내용> — TPL_OUT 에 changelog 출력
  local clone="$WORK/$1/clone" proj="$WORK/$1/proj"
  tpl_make_clone "$clone" full
  tpl_make_project "$proj" "$clone"
  printf '%s\n' "$3" > "$proj/rd-workflow/VERSION"
  printf '%s\n' "$4" > "$proj/rd-workflow/CHANGELOG.md"
  printf '%s\n' "$2" > "$proj/$(git -C "$proj" rev-parse --git-path rd-tpl-prev-version)"
  tpl_run "$proj" "$clone" changelog
}

echo "== A1: 이전 VERSION 과 같은 절은 고르지 않는다 =="
cl_case a1 "2026-11-01-202303" "2026-11-07-000000" '# 변경 이력

## 2026-11-07-000000
- 새 변화

## 2026-11-01-202303
- 이미 받은 옛 변화'
tpl_check "A1 rc" "$TPL_RC" "0"
tpl_check "A1 이전 절 없음" "$(has '## 2026-11-01-202303')" "no"
tpl_check "A1 받은 절 있음" "$(has '## 2026-11-07-000000')" "yes"
tpl_check "A1 머리 줄" "$(printf '%s\n' "$TPL_OUT" | head -1)" "템플릿 변경 이력 (이전 VERSION 2026-11-01-202303 뒤의 절):"

echo "== A2: 뒤 절의 항목이 모두 없으면 안내 한 줄 =="
cl_case a2 "2026-11-04-203832" "2026-11-07-120000" '# 변경 이력

## 2026-11-07-120000

## 2026-11-04-203832
- 이미 받은 변화'
tpl_check "A2 안내" "$(has '뒤로 기록된 변화가 없습니다')" "yes"
tpl_check "A2 한 줄" "$TPL_OUT" "템플릿 변경 이력: 이전 VERSION(2026-11-04-203832) 뒤로 기록된 변화가 없습니다."

echo "== A3: 이전 = 받은 이면 다음 발행 절도 내지 않는다 =="
cl_case a3 "2026-11-07-120000" "2026-11-07-120000" '# 변경 이력

## 다음 발행
- 이미 받은 변화'
tpl_check "A3 항목 없음" "$(has '이미 받은 변화')" "no"
tpl_check "A3 안내" "$(has '뒤가 아니어서')" "yes"

echo "== A4: VERSION 값이 셸 명령으로 실행되지 않는다 =="
rm -f "$WORK/marker"
cl_case a4 "bad'\$(printf EXECUTED > $WORK/marker)'" "2026-11-07-120000" '## 다음 발행
- x'
tpl_check "A4 marker 없음" "$([[ -e "$WORK/marker" ]] && echo yes || echo no)" "no"
tpl_check "A4 안내" "$(has '알 수 없어')" "yes"

echo "== 보조: 다음 발행 포함·lite 접두·40개 상한·CHANGELOG 없음 =="
cl_case b1 "lite-2026-11-01-000000" "lite-2026-11-07-000000" '## 다음 발행
- 아직 제목 안 바뀜

## 2026-11-07-000000
- 새 변화

## 그 이전
- 2026-10-01-000000 기록 시작'
tpl_check "b1 다음 발행 포함" "$(has '## 다음 발행')" "yes"
tpl_check "b1 기록 시작 안내" "$(has '이전 VERSION 이 기록 시작(2026-10-01-000000)보다')" "no"
tpl_check "b1 lite 안내" "$(printf '%s\n' "$TPL_OUT" | tail -1)" "「(full)」 표시 항목은 lite 배포본에 없습니다."
cl_case b2 "2026-09-01-000000" "2026-11-07-000000" '## 2026-11-07-000000
- a

## 그 이전
- 2026-10-01-000000 기록 시작'
tpl_check "b2 기록 시작 안내" "$(printf '%s\n' "$TPL_OUT" | tail -1)" "이전 VERSION 이 기록 시작(2026-10-01-000000)보다 오래되어 그 사이 변화 일부는 기록에 없습니다. 구조 전환은 rd-workflow/MIGRATIONS.md 를 봅니다."
big="## 2026-11-07-000000"; for i in $(seq 1 25); do big+=$'\n'"- n$i"; done
big+=$'\n\n'"## 2026-11-05-000000"; for i in $(seq 1 20); do big+=$'\n'"- m$i"; done
cl_case b3 "2026-11-01-000000" "2026-11-07-000000" "$big"
tpl_check "b3 상한" "$(printf '%s\n' "$TPL_OUT" | tail -2)" "## 2026-11-05-000000 — 항목 20개
항목이 45개라 가장 최근 절만 전문으로 보였습니다. 전체는 rd-workflow/CHANGELOG.md 에 있습니다."
tpl_check "b3 둘째 절 전문 없음" "$(has '- m1')" "no"
cl_case b4 "2026-11-01-000000" "2026-11-07-000000" 'x'
rm -f "$WORK/b4/proj/rd-workflow/CHANGELOG.md"; tpl_run "$WORK/b4/proj" "$WORK/b4/clone" changelog
tpl_check "b4 CHANGELOG 없음" "$TPL_OUT" "템플릿 변경 이력: 받은 템플릿에 rd-workflow/CHANGELOG.md 가 없어 보여 줄 변화가 없습니다."

if [[ "$FAIL" == "0" ]]; then
  echo "test_sync_template_changelog: 전체 통과"
else
  echo "test_sync_template_changelog: 실패 있음" >&2
  exit 1
fi
