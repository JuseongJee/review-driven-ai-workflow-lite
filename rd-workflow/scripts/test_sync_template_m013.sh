#!/usr/bin/env bash
# test_sync_template_m013.sh — migrate M013 시험 (C6b: template 절 걷어내기·목차 보충·modified 질문·결정 반영·기준본 변경·fence)
# fixture 는 mktemp -d 아래에만 만든다. 네트워크·실제 프로젝트 접근 없음.
# 호출 경로: _tpl_migrate.py 가 소스 디렉터리에 있으면 `migrate M013` 하위 명령, 없으면 _tpl_m013.run 직접 호출 보조(M013<TAB>상태 + 세부 줄).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
WORK="$(mktemp -d)" || { echo "test_sync_template_m013.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "test_sync_template_m013.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
WORK="$(cd -P "$WORK" && pwd)"   # /var → /private/var 정규화(경로 문자열 비교용)
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=_tpl_test_common.sh
source "$SCRIPT_DIR/_tpl_test_common.sh"

TAB=$'\t'
# m013 <프로젝트> <clone> [제목=값 ...] — 결정은 --decide 인자로 넘긴다. TPL_OUT·TPL_RC 에 저장
m013() {
  local proj="$1" clone="$2"; shift 2
  if [[ -e "$TPL_SRC/_tpl_migrate.py" ]]; then
    local args=() d
    for d in "$@"; do args+=(--decide "$d"); done
    tpl_run "$proj" "$clone" migrate M013 ${args[@]+"${args[@]}"}
    # 상태 줄은 앞 두 칸(M013<TAB>상태)만, 세부 줄은 앞 두 칸 들여쓰기를 뗀다
    TPL_OUT="$(printf '%s\n' "$TPL_OUT" | awk -F'\t' 'NR==1 { print $1 "\t" $2; next } { sub(/^  /, ""); print }')"
  else
    TPL_OUT="$(cd "$proj" && python3 -B - "$clone" "$@" <<PY 2>"$WORK/.tpl_err"
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, "$TPL_SRC")
import os
from _tpl_m013 import run
from _tpl_common import TplError
dec = dict(a.split("=", 1) for a in sys.argv[2:])
try:
    st, lines = run(sys.argv[1], os.getcwd(), dec)
except TplError as e:
    sys.stderr.write(e.msg + "\n")
    sys.exit(e.code)
print("M013\t" + st)
for l in lines:
    print(l)
PY
)"; TPL_RC=$?
    TPL_ERR="$(cat "$WORK/.tpl_err")"
  fi
}

mk() { # mk <clone> <project> — C6b fixture
  local clone="$1" proj="$2"
  tpl_make_clone "$clone"
  tpl_put "$clone" CLAUDE.md "# P

## 언어

한국어

## rd-workflow 규칙

- core.md"
  tpl_put "$clone" .claude/rules/rd-workflow/core.md "## Intake 규칙

본문 A

## Review 규칙

본문 B"
  git -C "$clone" init -q
  tpl_commit "$clone"
  tpl_make_project "$proj" "$clone"
  tpl_put "$proj" CLAUDE.md "# P

## 언어

한국어

## Intake 규칙

본문 A

## Review 규칙

본문 B 수정"
  tpl_commit "$proj"
}

has() { grep -qxF -- "$2" "$1" && echo yes || echo no; }

echo "== C6b M013 =="
CL="$WORK/clone"; PJ="$WORK/proj"
mk "$CL" "$PJ"
m013 "$PJ" "$CL"
DIFF="$(git -C "$PJ" rev-parse --git-path rd-tpl-m013)/1.diff"
[[ "$DIFF" == /* ]] || DIFF="$PJ/$DIFF"
tpl_check "1 종료 코드" "$TPL_RC" "0"
tpl_check "1 상태 줄" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}ASK"
tpl_check "1 modified 세부 줄" "$(printf '%s\n' "$TPL_OUT" | grep '^modified')" "modified${TAB}Review 규칙${TAB}$DIFF"
tpl_check "1 Intake 절 없음" "$(has "$PJ/CLAUDE.md" '## Intake 규칙')" "no"
tpl_check "1 Review 절 남아 있음" "$(has "$PJ/CLAUDE.md" '## Review 규칙')" "yes"
tpl_check "1 목차 절 있음" "$(has "$PJ/CLAUDE.md" '## rd-workflow 규칙')" "yes"
tpl_check "1 목차 절이 끝에" "$(tail -1 "$PJ/CLAUDE.md")" "- core.md"
tpl_check "1 diff 파일 존재" "$([[ -f "$DIFF" ]] && echo yes || echo no)" "yes"
tpl_check "1 diff 에 양쪽 본문" "$(grep -c -e '^-본문 B 수정' -e '^+본문 B$' "$DIFF")" "2"
cp -p "$PJ/CLAUDE.md" "$WORK/after1.md"

m013 "$PJ" "$CL" 'Review 규칙=adopt'
tpl_check "2 상태 줄" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}APPLIED"
tpl_check "2 Review 절 없음" "$(has "$PJ/CLAUDE.md" '## Review 규칙')" "no"
tpl_check "2 언어 절 보존" "$(has "$PJ/CLAUDE.md" '## 언어')" "yes"
cp -p "$PJ/CLAUDE.md" "$WORK/after2.md"
m013 "$PJ" "$CL"
tpl_check "2 재실행 NOOP" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}NOOP"
tpl_check "2 재실행 바이트 무변경" "$(cmp -s "$PJ/CLAUDE.md" "$WORK/after2.md" && echo same || echo diff)" "same"

# 3: 기준본이 바뀐 뒤 결정
cp -p "$WORK/after1.md" "$PJ/CLAUDE.md"
m013 "$PJ" "$CL"                       # 새 기준본(1 상태와 같은 파일)
printf '%s\n' "- 사용자가 추가한 줄" >> "$PJ/CLAUDE.md"
m013 "$PJ" "$CL" 'Review 규칙=adopt'
tpl_check "3 다시 묻습니다 출력" "$(printf '%s\n' "$TPL_OUT" | grep -c '다시 묻습니다')" "1"
tpl_check "3 상태 ASK" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}ASK"
tpl_check "3 Review 절 남아 있음" "$(has "$PJ/CLAUDE.md" '## Review 규칙')" "yes"

# 4: keep 은 표식 삽입
cp -p "$WORK/after1.md" "$PJ/CLAUDE.md"
m013 "$PJ" "$CL"
m013 "$PJ" "$CL" 'Review 규칙=keep'
tpl_check "4 표식 줄" "$(grep -A1 -x '## Review 규칙' "$PJ/CLAUDE.md" | tail -1)" "<!-- rd-workflow:project-override -->"
tpl_check "4 상태 줄" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}APPLIED"
m013 "$PJ" "$CL"
tpl_check "4 표식 뒤 NOOP" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}NOOP"

# 4b: defer 는 손대지 않고 NOTICE
cp -p "$WORK/after1.md" "$PJ/CLAUDE.md"
m013 "$PJ" "$CL"
m013 "$PJ" "$CL" 'Review 규칙=defer'
tpl_check "4b defer 상태 NOTICE" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}NOTICE"
tpl_check "4b defer 파일 무변경" "$(cmp -s "$PJ/CLAUDE.md" "$WORK/after1.md" && echo same || echo diff)" "same"

# 4c: 기준본 없이 결정
trash_base="$(git -C "$PJ" rev-parse --git-path rd-tpl-m013-base.md)"; [[ "$trash_base" == /* ]] || trash_base="$PJ/$trash_base"
rm -f "$trash_base"
m013 "$PJ" "$CL" 'Review 규칙=adopt'
tpl_check "4c 기준본 없이 결정 → exit 2 와 문구" "$TPL_RC:$(printf '%s' "$TPL_ERR" | grep -c '결정 없이 먼저 실행하십시오')" "2:1"

# 5: fence 줄 → ASK (분류기가 abort 한 줄만 내므로 편집 대상이 없다)
tpl_put "$PJ" CLAUDE.md "# P

## Intake 규칙

본문 A

\`\`\`
코드
\`\`\`"
m013 "$PJ" "$CL"
tpl_check "5 상태 ASK" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}ASK"
tpl_check "5 abort 세부 줄" "$(printf '%s\n' "$TPL_OUT" | grep -c '^abort	fence-present')" "1"

# 6: .gitignore 가 .claude/ 를 가리면 gitignore 세부 줄과 ASK
tpl_put "$PJ" CLAUDE.md "# P

## 언어

한국어"
printf '%s\n' '.claude/' > "$PJ/.gitignore"
m013 "$PJ" "$CL"
tpl_check "6 상태 ASK" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}ASK"
tpl_check "6 gitignore 세부 줄" "$(printf '%s\n' "$TPL_OUT" | grep -c '^gitignore	.gitignore:1:.claude/')" "1"

# 7: 절을 걷어낸 뒤 목차 보충이 실패(clone 에 목차 절 없음) → FAIL 과 함께 걷어낸 절을 보고
tpl_put "$CL" CLAUDE.md "# P

## 언어

한국어"
tpl_put "$PJ" CLAUDE.md "# P

## Intake 규칙

본문 A"
m013 "$PJ" "$CL"
tpl_check "7 상태 FAIL" "$(printf '%s\n' "$TPL_OUT" | head -1)" "M013${TAB}FAIL"
tpl_check "7 걷어낸 절 보고" "$(printf '%s\n' "$TPL_OUT" | grep -c '^removed	Intake 규칙')" "1"
tpl_check "7 파일에서도 절이 없음" "$(has "$PJ/CLAUDE.md" '## Intake 규칙')" "no"

[[ "$FAIL" -eq 0 ]] && echo "== M013 시험 통과 ==" || echo "== M013 시험 실패 =="
exit "$FAIL"
