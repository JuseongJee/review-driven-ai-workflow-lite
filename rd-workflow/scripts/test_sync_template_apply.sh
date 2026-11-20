#!/usr/bin/env bash
# test_sync_template_apply.sh — sync_template.sh apply 시험 (C4: 재분류 비교, 쓰기 순서, exclude·delete)
# fixture 는 mktemp -d 아래에만 만든다. 네트워크·실제 프로젝트 접근 없음.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
WORK="$(mktemp -d)" || { echo "test_sync_template_apply.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "test_sync_template_apply.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
# shellcheck source=_tpl_test_common.sh
source "$SCRIPT_DIR/_tpl_test_common.sh"

TAB=$'\t'
FR=rd-workflow-workspace/backlog/FUTURE_REQUESTS.md

fixture() { # fixture <clone> <project> — classify 시험 C1 의 입력에 FUTURE_REQUESTS.md(구분선만 → update)를 더한다
  local clone="$1" proj="$2"
  tpl_make_clone "$clone" full
  tpl_put "$clone" rd-workflow/scripts/a.sh 'echo new'
  tpl_put "$clone" rd-workflow/docs/x.md 'x'
  tpl_put "$clone" rd-workflow/docs/linked.md 'linked'
  tpl_put "$clone" rd-workflow/docs/sub/y.md 'y'
  tpl_put "$clone" "$FR" $'# FR\n\n| 제목 |\n| --- |'
  tpl_make_project "$proj" "$clone"
  printf '%s\n' "2026-11-01-000000" > "$proj/rd-workflow/VERSION"
  tpl_put "$proj" rd-workflow/scripts/a.sh 'echo old'
  tpl_put "$proj" rd-workflow/scripts/old.sh 'old'
  tpl_put "$proj" "$FR" '| --- |'
  mkdir -p "$proj/rd-workflow/docs" "$WORK/outside"
  rm -f "$WORK/outside_file"; printf 'o\n' > "$WORK/outside_file"
  ln -s "$WORK/outside_file" "$proj/rd-workflow/docs/linked.md"
  ln -s "$WORK/outside" "$proj/rd-workflow/docs/sub"
}

tree_fp() { # tree_fp <디렉터리> — 파일 목록 + 내용 cksum
  (cd "$1" && find . -path ./.git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while read -r f; do
    if [[ -L "$f" ]]; then echo "L $f $(readlink "$f")"; else echo "F $f $(cksum < "$f")"; fi
  done)
}

stop_case() { # stop_case <이름> <분류 뒤 프로젝트 변경 명령(함수)>
  local name="$1" mutate="$2" d="$WORK/stop_$1"
  fixture "$d/clone" "$d/proj"
  tpl_run "$d/proj" "$d/clone" classify
  "$mutate" "$d/proj"
  local before after
  before="$(tree_fp "$d/proj")"
  tpl_run "$d/proj" "$d/clone" apply
  after="$(tree_fp "$d/proj")"
  tpl_check "C4 $name 종료 코드" "$TPL_RC" "1"
  tpl_check "C4 $name 안내 문구" "$(printf '%s\n%s\n' "$TPL_OUT" "$TPL_ERR" | grep -c 'classify 부터 다시' | sed 's/^[1-9].*/found/')" "found"
  tpl_check "C4 $name 트리 무변경" "$after" "$before"
}

m_add()    { tpl_put "$1" rd-workflow/scripts/new.sh 'n'; }
m_edit()   { tpl_put "$1" rd-workflow/scripts/a.sh 'echo other'; }

echo "== C4: 분류 뒤 프로젝트가 바뀌면 멈춤 =="
stop_case path_added m_add
stop_case content_changed m_edit
tpl_check "C4 content_changed 멈춤 줄에 바뀐 쪽" "$(printf '%s\n' "$TPL_OUT" | grep -F 'scripts/a.sh')" "changed${TAB}rd-workflow/scripts/a.sh${TAB}계획: update${TAB}지금: update (프로젝트 내용 바뀜)"

echo "== C4: M009 흉내 (계획 갱신 뒤 통과) =="
d="$WORK/m009"
fixture "$d/clone" "$d/proj"
tpl_run "$d/proj" "$d/clone" classify
bfp="$(python3 -c '
import sys; sys.dont_write_bytecode=True; sys.path.insert(0, sys.argv[1])
import _tpl_classify as c; print(c.fingerprint(sys.argv[2]))' "$d/clone/rd-workflow/scripts" "$d/proj/$FR")"
printf '추가 설명\n' >> "$d/proj/$FR"
python3 -c '
import sys; sys.dont_write_bytecode=True; sys.path.insert(0, sys.argv[1])
import _tpl_classify as c; c.plan_refresh(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])' \
  "$d/clone/rd-workflow/scripts" "$d/clone" "$d/proj" "$FR" "$bfp"
tpl_run "$d/proj" "$d/clone" apply
tpl_check "C4 M009 흉내 뒤 apply 종료 코드" "$TPL_RC" "0"

echo "== C4: 중간 쓰기 실패 — VERSION 은 마지막 =="
d="$WORK/fail"
if [[ "$(id -u)" == "0" ]]; then
  echo "skip: root 는 쓰기 권한 검사가 통하지 않아 중간 쓰기 실패 시험을 건너뜁니다"
else
  fixture "$d/clone" "$d/proj"
  tpl_run "$d/proj" "$d/clone" classify
  chmod 555 "$d/proj/rd-workflow/docs"
  tpl_run "$d/proj" "$d/clone" apply
  chmod 755 "$d/proj/rd-workflow/docs"
  tpl_check "C4 쓰기 실패 종료 코드" "$TPL_RC" "1"
  tpl_check "C4 쓰기 실패 뒤 VERSION 옛 값" "$(cat "$d/proj/rd-workflow/VERSION")" "2026-11-01-000000"
  tpl_check "C4 쓰기 실패 출력에 version 줄 없음" "$(printf '%s\n' "$TPL_OUT" | grep -c '^version	' | sed 's/^0$/none/')" "none"
fi

echo "== C4: 정상 (exclude, delete 미확인, ask 보존) =="
d="$WORK/ok"
fixture "$d/clone" "$d/proj"
tpl_run "$d/proj" "$d/clone" classify
tpl_run "$d/proj" "$d/clone" apply --exclude no/such
tpl_check "--exclude no/such 종료 코드" "$TPL_RC" "2"
tpl_run "$d/proj" "$d/clone" apply --exclude rd-workflow/docs/x.md
tpl_check "정상 종료 코드" "$TPL_RC" "0"
tpl_check "a.sh 가 clone 과 같음" "$(cmp -s "$d/proj/rd-workflow/scripts/a.sh" "$d/clone/rd-workflow/scripts/a.sh" && echo same || echo diff)" "same"
tpl_check "x.md 없음(exclude)" "$([[ -e "$d/proj/rd-workflow/docs/x.md" ]] && echo exists || echo none)" "none"
tpl_check "old.sh 남음" "$([[ -e "$d/proj/rd-workflow/scripts/old.sh" ]] && echo exists || echo none)" "exists"
tpl_check "exclude 줄" "$(printf '%s\n' "$TPL_OUT" | grep -F "rd-workflow/docs/x.md")" "skipped${TAB}rd-workflow/docs/x.md${TAB}exclude"
tpl_check "delete-not-confirmed 줄" "$(printf '%s\n' "$TPL_OUT" | grep -F "scripts/old.sh")" "skipped${TAB}rd-workflow/scripts/old.sh${TAB}delete-not-confirmed"
tpl_check "ask 줄" "$(printf '%s\n' "$TPL_OUT" | grep -F "docs/sub/y.md")" "skipped${TAB}rd-workflow/docs/sub/y.md${TAB}ask"
tpl_check "copied 줄" "$(printf '%s\n' "$TPL_OUT" | grep -F "scripts/a.sh")" "copied${TAB}rd-workflow/scripts/a.sh"
tpl_check "outside 비어 있음" "$(ls -A "$WORK/outside" | wc -l | tr -d ' ')" "0"
tpl_check "linked.md symlink 유지" "$([[ -L "$d/proj/rd-workflow/docs/linked.md" ]] && echo link || echo notlink)" "link"
tpl_check "마지막 줄 version" "$(printf '%s\n' "$TPL_OUT" | tail -1)" "version${TAB}2026-11-01-000000${TAB}2026-11-13-000000"
tpl_check "VERSION 갱신" "$(cat "$d/proj/rd-workflow/VERSION")" "2026-11-13-000000"

echo "== C4: --delete (clone 을 다른 경로에 다시 만들어도 통과, VERSION 이 ask 면 skipped 줄) =="
d="$WORK/del"
fixture "$d/clone" "$d/proj"
mv "$d/proj/rd-workflow/VERSION" "$WORK/version_target"
ln -s "$WORK/version_target" "$d/proj/rd-workflow/VERSION"
tpl_run "$d/proj" "$d/clone" classify
cp -pR "$d/clone" "$d/clone2"
tpl_run "$d/proj" "$d/clone2" apply --delete
tpl_check "--delete 종료 코드 (clone 이동 뒤)" "$TPL_RC" "0"
tpl_check "old.sh 없음" "$([[ -e "$d/proj/rd-workflow/scripts/old.sh" ]] && echo exists || echo none)" "none"
tpl_check "deleted 줄" "$(printf '%s\n' "$TPL_OUT" | grep -F "scripts/old.sh")" "deleted${TAB}rd-workflow/scripts/old.sh"
tpl_check "VERSION ask → skipped 줄" "$(printf '%s\n' "$TPL_OUT" | grep -F "rd-workflow/VERSION")" "skipped${TAB}rd-workflow/VERSION${TAB}ask"
tpl_check "VERSION ask → version 줄 없음" "$(printf '%s\n' "$TPL_OUT" | grep -c '^version	' | sed 's/^0$/none/')" "none"

if [[ "$FAIL" == "0" ]]; then
  echo "test_sync_template_apply: 전체 통과"
else
  echo "test_sync_template_apply: 실패 있음" >&2
  exit 1
fi
