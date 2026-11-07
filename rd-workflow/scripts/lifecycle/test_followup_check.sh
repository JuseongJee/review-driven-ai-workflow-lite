#!/usr/bin/env bash
# test_followup_check.sh — followup_check.sh 단위 테스트 (임시 저장소, 약 1초).
# 후속 FR 의 등록 대조(작업 ref·기본 브랜치 ref), 주석 예시 무시, 흡수 후보의 상호 언급·접두 slug 배제를 본다.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC="$SCRIPT_DIR/followup_check.sh"
unset project_root TASK_STATE_PATH

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
check() { if [[ "$1" -eq 0 ]]; then pass "$2"; else fail "$2 — 출력: ${OUT}"; fi; }
has() { grep -qF -- "$1" <<<"$OUT"; }

TMP="$(mktemp -d)" || { echo "test_followup_check.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; I="rd-workflow-workspace/backlog/items"
mkdir -p "$R/$I"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
item() {  # item <slug> <status> [본문]
  printf '# 2026-11-01 %s\n- status: %s\n%s\n' "$1" "$2" "${3:-}" > "$R/$I/2026-11-01-$1.md"
}
item foo idea "- 하위: [상세](2026-11-01-sub-listed.md), [[2026-11-01 sub-wiki]] 를 이 작업에 묶습니다"
item sub-listed dropped "- drop reason: 흡수"
item sub-wiki dropped "- drop reason: 흡수"
item absorbed-x dropped "- drop reason: rd-workflow-workspace/backlog/items/2026-11-01-foo.md 로 흡수"
item absorbed-w dropped "- drop reason: [[2026-11-01 foo]] 로 흡수"
item prefix-only dropped "- relates: foo-bar, rd-workflow-workspace/backlog/items/2026-11-01-foo-bar.md, bar-foo"
item sub dropped "- drop reason: 중복"
item active-mention idea "- relates: foo"
git -C "$R" add -A && git -C "$R" commit -q -m seed
git -C "$R" switch -q -c fr/t
item fr-only idea
git -C "$R" add -A && git -C "$R" commit -q -m fr
# 분기 뒤 기본 브랜치에만 등록된 후속(호출 세션이 먼저 등록한 경우)
git -C "$R" switch -q main
item main-only idea
git -C "$R" add -A && git -C "$R" commit -q -m main-later
git -C "$R" switch -q fr/t

REQ="$TMP/REQUEST.md"
cat > "$REQ" <<'EOF'
# Change Request

## Constraints
<!-- 형식 예시: 「- 후속 FR: in-comment-example — 설명」
     - 후속 FR: in-comment-second -->
- 후속 FR: missing-one — 아직 등록 안 함
- 후속 FR: `fr-only`
- 후속 FR: main-only
- 후속 FR: Bad_Slug

## Source FR
rd-workflow-workspace/backlog/items/2026-11-01-foo.md
EOF

echo "== 후속 FR 대조"
OUT="$(cd "$R" && bash "$FC" "$REQ" fr/t main 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]]; check $? "미등록이 있어도 exit 0"
has "missing-one (미등록)"; check $? "미등록 slug 를 나열함"
! has "fr-only"; check $? "작업 ref 에만 있는 slug 는 등록으로 봄"
! has "main-only"; check $? "기본 브랜치 ref 에만 있는 slug 는 등록으로 봄"
has "Bad_Slug (slug 형식이 아님"; check $? "slug 형식이 아닌 값을 알림"
! has "in-comment"; check $? "주석 안의 예시는 읽지 않음"

echo "== 흡수 후보"
has "흡수 확인 — Source FR foo"; check $? "흡수 확인 머리줄"
has "  - absorbed-x ("; check $? "Source FR 을 파일 경로로 언급하는 dropped item 이 나옴"
has "  - absorbed-w ("; check $? "Source FR 을 [[날짜 slug]] 로 언급하는 dropped item 이 나옴"
has "  - sub-listed ("; check $? "Source FR 상세가 파일명 링크로 언급하는 dropped item 이 나옴"
has "  - sub-wiki ("; check $? "Source FR 상세가 [[날짜 slug]] 로 언급하는 dropped item 이 나옴"
! has "prefix-only"; check $? "slug 를 일부로 품은 언급(foo-bar·파일명 foo-bar·bar-foo)은 나오지 않음"
! has "  - sub ("; check $? "Source FR 상세의 sub-listed 가 dropped item sub 로 잡히지 않음"
! has "active-mention"; check $? "dropped 가 아닌 item 은 나오지 않음"

echo "== 모두 등록 / 빈 템플릿"
printf '# Change Request\n\n## Constraints\n- 후속 FR: fr-only\n\n## Source FR\n-\n' > "$REQ"
OUT="$(cd "$R" && bash "$FC" "$REQ" fr/t main 2>&1)"
has "1건이 모두 백로그에 있습니다"; check $? "모두 등록이면 한 줄로 알림"
printf '# Change Request\n\n## Constraints\n<!-- - 후속 FR: x -->\n-\n\n## Source FR\n-\n' > "$REQ"
OUT="$(cd "$R" && bash "$FC" "$REQ" fr/t main 2>&1)"
[[ -z "$OUT" ]]; check $? "후속·흡수 후보가 없으면 출력 없음"

echo "test_followup_check.sh: PASS=${PASS} FAIL=${FAIL}"
[[ "$FAIL" -eq 0 ]]
