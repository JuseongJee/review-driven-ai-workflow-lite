#!/usr/bin/env bash
# test_sync_template_classify.sh — sync_template.sh classify 시험 (C1 분류 표, C2 A1, C3 A3, C5 구조 마이그레이션, 로컬 스크립트 거부)
# fixture 는 mktemp -d 아래에만 만든다. 네트워크·실제 프로젝트 접근 없음.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
WORK="$(mktemp -d)" || { echo "test_sync_template_classify.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "test_sync_template_classify.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=_tpl_test_common.sh
source "$SCRIPT_DIR/_tpl_test_common.sh"

TAB=$'\t'
body() { printf '%s\n' "$TPL_OUT" | grep -v '^# '; }                       # 머리·요약 줄 제외
lines_of() { body | awk -F'\t' -v a="$1" -v b="${2:-$1}" '$2==a || $2==b'; }  # 경로 한두 개의 줄

# ---------------------------------------------------------------- C1 분류 표
c1_fixture() { # c1_fixture <clone> <project> <full|lite>
  local clone="$1" proj="$2" kind="$3"
  tpl_make_clone "$clone" "$kind"
  tpl_put "$clone" rd-workflow/scripts/a.sh 'echo new'
  tpl_put "$clone" rd-workflow/docs/x.md 'x'
  tpl_put "$clone" rd-workflow/claude_skills/s/SKILL.md 's'
  [[ "$kind" == "full" ]] && tpl_put "$clone" rd-workflow/extensions/verify/SKILL.md 'v'
  tpl_put "$clone" CLAUDE.md 'clone claude'
  tpl_put "$clone" README.md 'readme'
  tpl_put "$clone" rd-workflow/config/workflow.json '{}'
  tpl_put "$clone" .claude/settings.json '{}'
  tpl_put "$clone" weird/unknown.txt 'u'
  tpl_put "$clone" rd-workflow/docs/linked.md 'linked'
  tpl_put "$clone" rd-workflow/docs/sub/y.md 'y'

  tpl_make_project "$proj" "$clone"
  printf '%s\n' "2026-11-01-000000" > "$proj/rd-workflow/VERSION"
  tpl_put "$proj" rd-workflow/scripts/a.sh 'echo old'
  tpl_put "$proj" rd-workflow/scripts/old.sh 'old'
  tpl_put "$proj" rd-workflow/scripts/build.sh 'build'
  tpl_put "$proj" rd-workflow/claude_skills/verify/SKILL.md 'installed ext'
  tpl_put "$proj" CLAUDE.md 'project claude'
  mkdir -p "$proj/rd-workflow/config" "$WORK/outside"
  ln -s "$WORK/없는 대상" "$proj/rd-workflow/config/workflow.json"           # dangling symlink
  tpl_put "$WORK" outside_file 'o'
  mkdir -p "$proj/rd-workflow/docs"
  ln -s "$WORK/outside_file" "$proj/rd-workflow/docs/linked.md"              # 파일 symlink
  ln -s "$WORK/outside" "$proj/rd-workflow/docs/sub"                         # 디렉터리 symlink
}

echo "== C1: 분류 표 (full clone) =="
c1_fixture "$WORK/c1/clone" "$WORK/프로젝트 dir" full
tpl_run "$WORK/프로젝트 dir" "$WORK/c1/clone" classify --no-save
tpl_check "C1 종료 코드" "$TPL_RC" "0"
tpl_check "C1 stderr 비어 있음" "$TPL_ERR" ""
tpl_check "C1 머리 줄" "$(printf '%s\n' "$TPL_OUT" | head -1)" "# rd-tpl-plan v1${TAB}clone-version=2026-11-13-000000"
tpl_check "C1 요약 줄(same 제외)" "$(printf '%s\n' "$TPL_OUT" | grep '^# 요약' | cut -f1-6)" "# 요약${TAB}update=2${TAB}add=4${TAB}delete=1${TAB}keep=5${TAB}ask=3"
tpl_check "C1 본문" "$(body)" "keep	.claude/settings.json	M003 이 만듦
keep	CLAUDE.md	부재 시 생성: 경로 있음
add	README.md	미전파: 경로 없음
update	rd-workflow/VERSION	내용 다름
add	rd-workflow/claude_skills/s/SKILL.md	템플릿에만 있음
keep	rd-workflow/claude_skills/verify/SKILL.md	extension 스킬
keep	rd-workflow/config/workflow.json	부재 시 생성: 경로 있음
ask	rd-workflow/docs/linked.md	symlink — 판단 필요
ask	rd-workflow/docs/sub/y.md	상위 경로 symlink: rd-workflow/docs/sub
add	rd-workflow/docs/x.md	템플릿에만 있음
add	rd-workflow/extensions/verify/SKILL.md	템플릿에만 있음
update	rd-workflow/scripts/a.sh	내용 다름
keep	rd-workflow/scripts/build.sh	미전파
delete	rd-workflow/scripts/old.sh	템플릿에 없음
ask	weird/unknown.txt	전파 정책 표에 없음"

echo "== C1: lite clone 실행 확인 =="
c1_fixture "$WORK/c1l/clone" "$WORK/c1l/proj" lite
tpl_run "$WORK/c1l/proj" "$WORK/c1l/clone" classify --no-save
tpl_check "C1 lite 종료 코드" "$TPL_RC" "0"

echo "== C1: models.json 보존·models.json.example 갱신 =="
d="$WORK/c1m"
MJ=rd-workflow/config/models.json
tpl_make_clone "$d/clone"
tpl_put "$d/clone" "$MJ.example" '{"version":1,"review":{"codex":{"small_task_effort":"medium"}}}'
tpl_make_project "$d/proj" "$d/clone"
tpl_put "$d/proj" "$MJ.example" '{"version":1}'
tpl_put "$d/proj" "$MJ" '{"version":1,"review":{"codex":{"effort":"high"}}}'
cp -p "$d/proj/$MJ" "$d/user_models.json"
tpl_check "C1 models 정책표 (models.json 미전파, 예시 덮어쓰기)" "$(python3 - "$TPL_SRC" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from _tpl_classify import POLICY
d = {p: pol for p, pol, _ in POLICY}
print(d.get("rd-workflow/config/models.json"), d.get("rd-workflow/config/models.json.example"))
PY
)" "미전파 덮어쓰기"
tpl_run "$d/proj" "$d/clone" classify --no-save
tpl_check "C1 models 예시 행" "$(lines_of "$MJ.example")" "update	$MJ.example	내용 다름"
tpl_check "C1 models.json delete 행 없음" "$(body | awk -F'\t' -v p="$MJ" '$1=="delete" && $2==p' | wc -l | tr -d ' ')" "0"
tpl_run "$d/proj" "$d/clone" classify
tpl_run "$d/proj" "$d/clone" apply --delete
tpl_check "C1 models apply --delete 종료 코드" "$TPL_RC" "0"
tpl_check "C1 models 예시는 clone 내용" "$(cmp -s "$d/clone/$MJ.example" "$d/proj/$MJ.example" && echo same || echo diff)" "same"
tpl_check "C1 models.json 사용자 원문 보존" "$(cmp -s "$d/user_models.json" "$d/proj/$MJ" 2>/dev/null && echo same || echo diff)" "same"

# ---------------------------------------------------------------- C2 A1
echo "== C2: A1 (표에 행이 있음) =="
FR=rd-workflow-workspace/backlog/FUTURE_REQUESTS.md
tpl_make_clone "$WORK/c2/clone"
tpl_put "$WORK/c2/clone" "$FR" $'# FR\n\n| 제목 |\n| --- |'
c2_case() { # c2_case <이름> <프로젝트 파일 내용> <기대 줄>
  local d="$WORK/c2"
  tpl_make_project "$d/proj_$1" "$d/clone"
  tpl_put "$d/proj_$1" "$FR" "$2"
  tpl_run "$d/proj_$1" "$d/clone" classify --no-save
  tpl_check "C2 $1" "$(lines_of "$FR")" "$3"
}
c2_case rows $'# FR\n\n| 제목 |\n| --- |\n| x |'  "keep	$FR	A1 행 1개"
c2_case sep_only '| --- |'                          "update	$FR	내용 다름"
c2_case no_sep   $'# FR\n\n자유 서술'               "keep	$FR	A1 구분선 없음(판정 불가)"

# ---------------------------------------------------------------- C3 A3
echo "== C3: A3 (REQUEST·CURRENT_TASK 묶음) =="
tpl_make_clone "$WORK/c3/clone"
tpl_put "$WORK/c3/clone" REQUEST.md $'## User Goal\n\n-'
tpl_put "$WORK/c3/clone" CURRENT_TASK.md $'## User Goal\n\n-'
c3_case() { # c3_case <이름> <CURRENT_TASK 에 덧붙일 내용|-> <기대 줄>
  local d="$WORK/c3"
  tpl_make_project "$d/proj_$1" "$d/clone"
  cp -p "$d/clone/REQUEST.md" "$d/clone/CURRENT_TASK.md" "$d/proj_$1/"
  [[ "$2" == "-" ]] || printf '%s\n' "$2" >> "$d/proj_$1/CURRENT_TASK.md"
  tpl_run "$d/proj_$1" "$d/clone" classify --no-save
  tpl_check "C3 $1" "$(lines_of CURRENT_TASK.md REQUEST.md)" "$3"
}
c3_case blank   '-'                          ""
c3_case slug    'foo-slug'                   "keep	CURRENT_TASK.md	A3 남은 줄 1개: foo-slug
keep	REQUEST.md	A3 남은 줄 1개: foo-slug"
c3_case mixed   '<!-- 참고 --> 요구사항'      "keep	CURRENT_TASK.md	A3 남은 줄 1개: <!-- 참고 --> 요구사항
keep	REQUEST.md	A3 남은 줄 1개: <!-- 참고 --> 요구사항"
c3_case comment $'<!--\n메모\n-->'            "update	CURRENT_TASK.md	내용 다름"
c3_case tailtxt $'<!--\n메모\n-->x'           "keep	CURRENT_TASK.md	A3 남은 줄 3개: <!--
keep	REQUEST.md	A3 남은 줄 3개: <!--"
c3_case unclosed $'<!--\n본문'                "keep	CURRENT_TASK.md	A3 남은 줄 2개: <!--
keep	REQUEST.md	A3 남은 줄 2개: <!--"

# C3 이전 초기본 — archive 가 2026-11-13 까지 쓰던 CURRENT_TASK 초기본은 템플릿에 없는 줄
# (`[REQUEST.md](REQUEST.md)`·`main`·`## Output Files`)을 담았다. 그 상태만 남은 프로젝트는
# 동기화하고, 사용자가 쓴 줄이 더 있으면 보존한다. 기대값은 lifecycle 의 두 heredoc 에서 만든다.
echo "== C3: A3 이전 초기본 =="
LC="$SCRIPT_DIR/lifecycle/_lifecycle_common.sh"
tpl_make_clone "$WORK/c3l/clone"
bash -c 'source "$1"; emit_current_task_baseline' _ "$LC" > "$WORK/c3l/clone/CURRENT_TASK.md"
tpl_put "$WORK/c3l/clone" REQUEST.md $'## User Goal\n\n-'
c3l_case() { # c3l_case <이름> <덧붙일 내용|-> <기대 줄>
  local d="$WORK/c3l"
  tpl_make_project "$d/proj_$1" "$d/clone"
  cp -p "$d/clone/REQUEST.md" "$d/proj_$1/"
  bash -c 'source "$1"; emit_current_task_baseline_legacy' _ "$LC" > "$d/proj_$1/CURRENT_TASK.md"
  [[ "$2" == "-" ]] || printf '%s\n' "$2" >> "$d/proj_$1/CURRENT_TASK.md"
  tpl_run "$d/proj_$1" "$d/clone" classify --no-save
  tpl_check "C3 legacy $1" "$(lines_of CURRENT_TASK.md REQUEST.md)" "$3"
}
c3l_case blank '-'        "update	CURRENT_TASK.md	내용 다름"
c3l_case slug  'foo-slug' "keep	CURRENT_TASK.md	A3 남은 줄 1개: foo-slug
keep	REQUEST.md	A3 남은 줄 1개: foo-slug"

# ---------------------------------------------------------------- C5 구조 마이그레이션
echo "== C5: 구조 마이그레이션 먼저 =="
tpl_make_clone "$WORK/c5/clone"
mkdir -p "$WORK/c5/proj/ai"; git -C "$WORK/c5/proj" init -q
tpl_run "$WORK/c5/proj" "$WORK/c5/clone" classify --no-save
tpl_check "C5 종료 코드" "$TPL_RC" "3"
tpl_check "C5 출력" "$TPL_OUT" "ask${TAB}M001${TAB}구조 마이그레이션 먼저"

# ---------------------------------------------------------------- 로컬 스크립트로 실행
echo "== 로컬 스크립트로 실행 (clone=프로젝트) =="
tpl_make_clone "$WORK/loc/clone"
tpl_make_project "$WORK/loc/proj" "$WORK/loc/clone"
TPL_OUT="$(cd "$WORK/loc/proj" && bash "$WORK/loc/proj/rd-workflow/scripts/sync_template.sh" classify --no-save 2>"$WORK/.tpl_err")"; TPL_RC=$?
tpl_check "로컬 스크립트 종료 코드" "$TPL_RC" "2"
tpl_check "로컬 스크립트 메시지" "$(cat "$WORK/.tpl_err")" "오류: clone 의 스크립트로 실행하십시오"

# ---------------------------------------------------------------- atomic_write (symlink·권한)
echo "== atomic_write: symlink 는 실경로에서 교체, 원본 권한 유지 =="
mkdir -p "$WORK/aw"
printf 'old\n' > "$WORK/aw/real"; chmod 755 "$WORK/aw/real"; ln -s real "$WORK/aw/lnk"
aw_out="$(python3 - "$TPL_SRC" "$WORK/aw" <<'PY'
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from _tpl_common import atomic_write
d = sys.argv[2]
atomic_write(d + "/lnk", b"new\n")
print("link=%s real=%s mode=%o" % (os.path.islink(d + "/lnk"), open(d + "/real").read().strip(), os.stat(d + "/real").st_mode & 0o777))
PY
)"
tpl_check "atomic_write 링크 유지·실경로 갱신·권한 유지" "$aw_out" "link=True real=new mode=755"

if [[ "$FAIL" == "0" ]]; then
  echo "test_sync_template_classify: 전체 통과"
else
  echo "test_sync_template_classify: 실패 있음" >&2
  exit 1
fi
