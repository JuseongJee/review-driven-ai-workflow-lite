#!/usr/bin/env bash
# test_team_publish_common.sh — _team_publish_common.sh 의 설정·대상·기록·판정·light-check·승인·gh 해석 시험.
# 임시 저장소(+로컬 bare 원격)와 PATH 앞의 가짜 gh 만 쓴다. 실제 GitHub 에 접근하지 않는다.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (기대 [$3] / 실제 [$2])"; fi; }

TMP="$(mktemp -d)" || exit 1
[[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# 쓰는 순서: _lifecycle_common.sh → ../_state_common.sh → ../_submodule_common.sh → _tasks_index.sh → 공용 파일
project_root="$TMP/root"
export project_root
source "$SCRIPT_DIR/_lifecycle_common.sh"
source "$SCRIPT_DIR/../_state_common.sh"
source "$SCRIPT_DIR/../_submodule_common.sh"
source "$SCRIPT_DIR/_tasks_index.sh"
source "$SCRIPT_DIR/_team_publish_common.sh"

G() { git -C "$1" -c user.name=t -c user.email=t@example.invalid "${@:2}"; }

# 세계: team.git(bare) + 상위 저장소 root(submodule `sub` 포함).
mk_world() {
  rm -rf "${TMP:?}/root" "${TMP:?}/team.git" "${TMP:?}/teamwc"
  git init -q --bare -b main "$TMP/team.git"
  git clone -q "$TMP/team.git" "$TMP/teamwc" 2>/dev/null
  printf 'a\n' >"$TMP/teamwc/f"; G "$TMP/teamwc" add -A; G "$TMP/teamwc" commit -q -m a
  G "$TMP/teamwc" branch -M main; G "$TMP/teamwc" push -q origin main 2>/dev/null
  git init -q -b main "$TMP/root"
  mkdir -p "$TMP/root/rd-workflow/config" "$TMP/root/rd-workflow-workspace/.lifecycle"
  printf 'x\n' >"$TMP/root/README"
  G "$TMP/root" add -A; G "$TMP/root" commit -q -m init
  G "$TMP/root" submodule add -q "$TMP/team.git" sub 2>/dev/null
  G "$TMP/root" commit -q -m "add sub"
  BASE="$(git -C "$TMP/root" rev-parse HEAD)"
  printf 'b\n' >"$TMP/teamwc/f"; G "$TMP/teamwc" commit -q -am b
  NEWOID="$(git -C "$TMP/teamwc" rev-parse HEAD)"
  G "$TMP/teamwc" push -q origin main 2>/dev/null
  git -C "$TMP/root/sub" fetch -q origin 2>/dev/null
}
cfg() { printf '%s\n' "$1" >"$TMP/root/rd-workflow/config/workflow.json"; }

echo "== 설정 =="

t_config_defaults() {
  mk_world; cfg '{"x": 1}'
  tp_config_present "$TMP/root"; eq "team_publish 키 없음 → rc 1" "$?" "1"
  eq "기본 mode" "$(tp_config "$TMP/root" "" mode)" "pr"
  eq "기본 light" "$(tp_config "$TMP/root" "" light)" "pr"
  eq "기본 base 는 빈 값" "$(tp_config "$TMP/root" "" base)" ""
  eq "기본 branch_prefix 는 빈 값" "$(tp_config "$TMP/root" "" branch_prefix)" ""
  _TP_NOTICED=""
  tp_notice_default "$TMP/root" 2>"$TMP/n1"; tp_notice_default "$TMP/root" 2>"$TMP/n2"
  eq "안내는 첫 호출에만 한 줄" "$(wc -l <"$TMP/n1" | tr -d ' ')/$(wc -l <"$TMP/n2" | tr -d ' ')" "1/0"
  eq "안내 문구" "$(cat "$TMP/n1")" "이번부터 마감 때 팀 저장소에 PR 을 올립니다(기본 반영 방식 pr). 이전 방식은 rd-workflow/config/workflow.json 의 team_publish.mode 를 manual 로 설정하십시오."
  cfg '{"team_publish": {}}'; _TP_NOTICED=""
  tp_config_present "$TMP/root"; eq "team_publish 키 있음 → rc 0" "$?" "0"
  tp_notice_default "$TMP/root" 2>"$TMP/n3"; eq "키가 있으면 안내 없음" "$(wc -c <"$TMP/n3" | tr -d ' ')" "0"
  cfg '{not json'; _TP_NOTICED=""
  tp_notice_default "$TMP/root" 2>"$TMP/n4"; eq "파싱 실패면 안내 없음" "$(wc -c <"$TMP/n4" | tr -d ' ')" "0"
  rm -f "$TMP/root/rd-workflow/config/workflow.json"
  tp_config_present "$TMP/root"; eq "설정 파일 없음 → rc 1" "$?" "1"
  eq "설정 파일 없어도 기본 mode" "$(tp_config "$TMP/root" "" mode)" "pr"
}
t_config_defaults

t_config_override() {
  mk_world
  cfg '{"team_publish": {"mode":"push","base":"develop","branch_prefix":"feat/","light":"merge","submodules":{"sub":{"mode":"manual","base":"rel"}}}}'
  eq "전역 mode" "$(tp_config "$TMP/root" "" mode)" "push"
  eq "submodule mode 덮어씀" "$(tp_config "$TMP/root" sub mode)" "manual"
  eq "submodule base 덮어씀" "$(tp_config "$TMP/root" sub base)" "rel"
  eq "덮어쓰지 않은 키는 전역" "$(tp_config "$TMP/root" sub branch_prefix)" "feat/"
  eq "다른 경로는 전역" "$(tp_config "$TMP/root" other mode)" "push"
  eq "light 전역" "$(tp_config "$TMP/root" "" light)" "merge"
}
t_config_override

t_config_invalid() {
  mk_world
  local rc
  cfg '{"team_publish": {"mode":"bogus"}}'
  tp_config "$TMP/root" "" mode >/dev/null 2>&1; rc=$?; eq "알 수 없는 mode → rc 2" "$rc" "2"
  cfg '{"team_publish": {"light":"x"}}'
  tp_config "$TMP/root" "" light >/dev/null 2>&1; rc=$?; eq "알 수 없는 light → rc 2" "$rc" "2"
  cfg '{"team_publish": {"submodules":{"sub":{"mode":"nope"}}}}'
  tp_config "$TMP/root" sub mode >/dev/null 2>&1; rc=$?; eq "submodule 의 잘못된 mode → rc 2" "$rc" "2"
  cfg '{not json'
  tp_config "$TMP/root" "" mode >/dev/null 2>&1; rc=$?; eq "파싱 실패 → rc 2" "$rc" "2"
  cfg '{"team_publish": {}}'
  tp_config "$TMP/root" "" nokey >/dev/null 2>&1; rc=$?; eq "알 수 없는 key → rc 2" "$rc" "2"
}
t_config_invalid

echo "== 대상 · 기록 =="

t_targets_changed_only() {
  mk_world
  printf 'm\n' >"$TMP/root/other"; G "$TMP/root" add -A; G "$TMP/root" commit -q -m other
  git -C "$TMP/root/sub" checkout -q "$NEWOID" 2>/dev/null
  G "$TMP/root" add sub; G "$TMP/root" commit -q -m "bump sub"
  local tip out old
  tip="$(git -C "$TMP/root" rev-parse HEAD)"; old="$(git -C "$TMP/root" rev-parse "$BASE:sub")"
  out="$(tp_targets "$TMP/root" "$BASE" "$tip")"
  eq "gitlink 만 path<TAB>old<TAB>new" "$out" "$(printf 'sub\t%s\t%s' "$old" "$NEWOID")"
  eq "바뀌지 않으면 출력 없음" "$(tp_targets "$TMP/root" "$tip" "$tip")" ""
  tp_targets "$TMP/root" "0000000000000000000000000000000000000001" "$tip" >/dev/null 2>&1
  eq "판정 불가 rc 2" "$?" "2"
}
t_targets_changed_only

# submodule ↔ 일반 파일·심볼릭 링크 형식 변경은 gitlink 가 아닌 쪽 OID(blob)를 0 으로 냅니다.
# 0 이 아니면 소비처(archive 게이트·rd pr open)가 blob 을 반영할 포인터로 보고 발행을 막습니다.
t_targets_type_change() {
  mk_world
  local old z f l
  old="$(git -C "$TMP/root" rev-parse "$BASE:sub")"; z="${old//?/0}"
  G "$TMP/root" rm -q --cached sub; mv "$TMP/root/sub" "$TMP/sub.away"
  printf 'replacement\n' >"$TMP/root/sub"; G "$TMP/root" add sub; G "$TMP/root" commit -q -m "sub to file"
  f="$(git -C "$TMP/root" rev-parse HEAD)"
  eq "submodule → 일반 파일: new 는 0" "$(tp_targets "$TMP/root" "$BASE" "$f")" "$(printf 'sub\t%s\t%s' "$old" "$z")"
  eq "일반 파일 → submodule: old 는 0" "$(tp_targets "$TMP/root" "$f" "$BASE")" "$(printf 'sub\t%s\t%s' "$z" "$old")"
  G "$TMP/root" rm -q sub; ln -s elsewhere "$TMP/root/sub"; G "$TMP/root" add sub; G "$TMP/root" commit -q -m "sub to link"
  l="$(git -C "$TMP/root" rev-parse HEAD)"
  eq "submodule → 심볼릭 링크: new 는 0" "$(tp_targets "$TMP/root" "$BASE" "$l")" "$(printf 'sub\t%s\t%s' "$old" "$z")"
  rm -rf "${TMP:?}/sub.away"
}
t_targets_type_change

# 일반 파일 경로의 개행과 .gitmodules 의 ignore=all 이 gitlink 변경을 가리지 않습니다. 가리면 no-fr 게시 게이트가
# 원격 검사를 건너뛰어 다른 체크아웃이 초기화할 수 없는 포인터를 발행합니다.
t_targets_newline_path_and_ignore_all() {
  mk_world
  local old tip b0
  old="$(git -C "$TMP/root" rev-parse "$BASE:sub")"
  printf 'n\n' >"$TMP/root/aaa"$'\n'"extra"
  git -C "$TMP/root/sub" checkout -q "$NEWOID" 2>/dev/null
  G "$TMP/root" add -A; G "$TMP/root" commit -q -m "newline path + bump sub"
  tip="$(git -C "$TMP/root" rev-parse HEAD)"
  eq "개행 경로와 함께 바뀐 gitlink 가 대상에 나옴" "$(tp_targets "$TMP/root" "$BASE" "$tip")" "$(printf 'sub\t%s\t%s' "$old" "$NEWOID")"
  git -C "$TMP/root" config -f .gitmodules submodule.sub.ignore all
  G "$TMP/root" add .gitmodules; G "$TMP/root" commit -q -m "ignore=all"
  b0="$(git -C "$TMP/root" rev-parse HEAD)"
  git -C "$TMP/root/sub" checkout -q "$old" 2>/dev/null
  G "$TMP/root" add -f sub; G "$TMP/root" commit -q -m "sub back (ignore=all)"
  tip="$(git -C "$TMP/root" rev-parse HEAD)"
  eq ".gitmodules ignore=all 인 gitlink 변경이 대상에 나옴" "$(tp_targets "$TMP/root" "$b0" "$tip")" "$(printf 'sub\t%s\t%s' "$NEWOID" "$old")"
}
t_targets_newline_path_and_ignore_all

echo "== 반영 대상 기준점 =="

# 세계 + submodule `other`(같은 팀 저장소). main 이 other 를, fr/x 가 sub 를 NEWOID 로 바꾸고 fr/x 가 main 을 병합합니다.
# M0 = 분기점, M1 = main 의 other 변경, TIP = fr/x 의 main 병합 커밋. 작업 트리의 workflow.json 은 커밋하지 않습니다.
LC=rd-workflow-workspace/.lifecycle
put() { mkdir -p "$(dirname "$TMP/root/$1")"; printf '%s\n' "$2" >"$TMP/root/$1"; G "$TMP/root" add -f "$1"; }
mk_world_other() {
  mk_world
  G "$TMP/root" submodule add -q "$TMP/team.git" other 2>/dev/null
  git -C "$TMP/root/other" checkout -q "$(git -C "$TMP/root" rev-parse "$BASE:sub")" 2>/dev/null
  G "$TMP/root" add other; G "$TMP/root" commit -q -m "add other"
  M0="$(git -C "$TMP/root" rev-parse HEAD)"
  G "$TMP/root" checkout -q -b fr/x
  git -C "$TMP/root/sub" checkout -q "$NEWOID" 2>/dev/null
  put "$LC/task-state" "$(printf 'fr-branch=fr/x\nbase-commit=%s' "$M0")"
  G "$TMP/root" add sub; G "$TMP/root" commit -q -m "bump sub"
  G "$TMP/root" checkout -q main 2>/dev/null
  git -C "$TMP/root/other" checkout -q "$NEWOID" 2>/dev/null
  G "$TMP/root" add other; G "$TMP/root" commit -q -m "bump other"
  M1="$(git -C "$TMP/root" rev-parse HEAD)"
  G "$TMP/root" checkout -q fr/x 2>/dev/null
  G "$TMP/root" merge -q --no-edit main >/dev/null 2>&1
  TIP="$(git -C "$TMP/root" rev-parse HEAD)"
}
# mk_world_other 는 한 번만 만들고(약 2초) 케이스마다 사본으로 복원합니다. submodule 의 gitdir 은 상대 경로라 사본에서도 유지됩니다.
# 이 사본은 다음 mk_world 전(team.git 을 다시 만들기 전)까지만 씁니다.
mk_world_other
rm -rf "${TMP:?}/root.tpl"; cp -R "$TMP/root" "$TMP/root.tpl"
use_tpl() { rm -rf "${TMP:?}/root"; cp -R "$TMP/root.tpl" "$TMP/root"; }
# tb <tip> <fr-branch> — OUT(stdout)·ERR(stderr 파일 본문)·RC
tb() { OUT="$(tp_target_base "$TMP/root" "$1" "$2" 2>"$TMP/tb.err")"; RC=$?; ERR="$(cat "$TMP/tb.err")"; }
seal() { put "$LC/review-seals/$1.seal" "$(printf 'schema=1\nsession-id=%s\n%shead=%s' "$1" "${2:+review-base=$2
}" "$(git -C "$TMP/root" rev-parse HEAD)")"; }

t_target_base_fr_merge() {
  use_tpl
  tb "$TIP" fr/x
  eq "fr main 병합 뒤 기준점은 merge-base(M1)" "$RC/$OUT" "0/$M1"
  eq "AC3 main 병합 뒤 대상은 sub 만" "$(tp_targets "$TMP/root" "$OUT" "$TIP" | cut -f1)" "sub"
  # AC9: tip 에는 default_branch 가 없고 작업 트리 설정에만 nosuch 가 있어도 결과가 같습니다.
  cfg '{"default_branch": "nosuch"}'
  tb "$TIP" fr/x
  eq "AC9 작업 트리 default_branch 를 읽지 않음" "$RC/$OUT" "0/$M1"
  rm -f "$TMP/root/rd-workflow/config/workflow.json"
}
t_target_base_fr_merge

t_target_base_marker() {
  use_tpl
  local tip2
  put "$LC/task-state" "$(printf 'fr-branch=fr/x\nbase-commit=%s\nreview-session=S1' "$M0")"
  seal S1 "$M0"; G "$TMP/root" commit -q -m "seal S1"
  tip2="$(git -C "$TMP/root" rev-parse HEAD)"
  tb "$tip2" fr/x
  eq "AC3 마커 review-base 가 merge-base 보다 앞섬" "$RC/$OUT" "0/$M0"
  G "$TMP/root" checkout -q main 2>/dev/null; G "$TMP/root" merge -q --no-ff --no-edit fr/x >/dev/null 2>&1
  tb "$(git -C "$TMP/root" rev-parse HEAD)" fr/x
  eq "AC3 기본 브랜치 병합 뒤에도 마커 기준점" "$RC/$OUT" "0/$M0"
}
t_target_base_marker

# seal 뒤 다른 submodule(other) 포인터를 바꾼 main 을 병합해도 대상 경로는 리뷰한 범위(기준점..마커 head)의 sub 만입니다.
# 포인터 값(new)은 tip 에서 읽습니다.
t_targets_reviewed_range() {
  use_tpl
  local tip rh
  G "$TMP/root" checkout -q -B fr/y "${TIP}^1" 2>/dev/null
  put "$LC/task-state" "$(printf 'fr-branch=fr/y\nbase-commit=%s\nreview-session=S6' "$M0")"
  seal S6 "$M0"; G "$TMP/root" commit -q -m "seal S6"
  G "$TMP/root" merge -q --no-edit main >/dev/null 2>&1
  tip="$(git -C "$TMP/root" rev-parse HEAD)"
  [[ "$(git -C "$TMP/root" rev-parse "$tip:other")" == "$NEWOID" ]] || { fail "준비 실패: F1 병합 뒤 other 가 바뀌지 않음"; return; }
  tb "$tip" fr/y
  rh="$(tp_reviewed_head "$TMP/root" "$tip")"
  eq "seal 뒤 main 병합 — 대상은 리뷰한 sub 만, new 는 tip 포인터" "$(tp_targets "$TMP/root" "$OUT" "$tip" "$rh" | cut -f1,3)" "$(printf 'sub\t%s' "$NEWOID")"
}
t_targets_reviewed_range

# 리뷰한 끝 뒤에 표준 git submodule add 로 탭이 든 경로를 더해도 리뷰한 범위의 sub 는 대상으로 남습니다.
# 없으면 새는 실수: 범위 밖 경로의 표현 검사가 정상 대상까지 rc 2 로 막아 rd pr open·check·archive 가 판정 불가가 됩니다.
t_targets_out_of_range_tab_path() {
  use_tpl
  local tip rh out rc p
  G "$TMP/root" checkout -q -B fr/z "${TIP}^1" 2>/dev/null
  put "$LC/task-state" "$(printf 'fr-branch=fr/z\nbase-commit=%s\nreview-session=S7' "$M0")"
  seal S7 "$M0"; G "$TMP/root" commit -q -m "seal S7"
  p="$(printf 'z\tother')"
  G "$TMP/root" submodule add -q "$TMP/team.git" "$p" >/dev/null 2>&1
  G "$TMP/root" commit -q -m "add tab path"
  tip="$(git -C "$TMP/root" rev-parse HEAD)"
  [[ "$(git -C "$TMP/root" ls-tree -z "$tip" -- "$p" | cut -c1-6)" == 160000 ]] || { fail "준비 실패: 탭 경로 gitlink 가 없음"; return; }
  rh="$(tp_reviewed_head "$TMP/root" "$tip")"
  out="$(tp_targets "$TMP/root" "$M0" "$tip" "$rh" 2>"$TMP/tt.err")"; rc=$?
  eq "리뷰한 끝 뒤 탭 경로 추가 — rc 0, 대상은 sub, 원인 줄 없음" "$rc|$(printf '%s' "$out" | cut -f1)|$(cat "$TMP/tt.err")" "0|sub|"
}
t_targets_out_of_range_tab_path

t_target_base_old_marker() {
  use_tpl
  put "$LC/task-state" "$(printf 'fr-branch=fr/x\nbase-commit=%s\nreview-session=S2' "$M0")"
  seal S2 ""; G "$TMP/root" commit -q -m "old seal"
  tb "$(git -C "$TMP/root" rev-parse HEAD)" fr/x
  eq "AC3 옛 마커(fr) → merge-base" "$RC/$OUT" "0/$M1"
  eq "AC3 옛 마커(fr) 경고 한 줄" "$ERR" "tp_target_base: seal 마커 S2 에 리뷰 기준점이 없어 종전 기준(merge-base)으로 판정합니다"
  G "$TMP/root" checkout -q main 2>/dev/null
  put "$LC/task-state" "$(printf 'fr-branch=null\nbase-commit=%s\nreview-session=S3' "$M0")"
  seal S3 ""; G "$TMP/root" commit -q -m "old seal no-fr"
  tb "$(git -C "$TMP/root" rev-parse HEAD)" null
  eq "AC3 옛 마커(no-fr) → base-commit" "$RC/$OUT" "0/$M0"
  eq "AC3 옛 마커(no-fr) 경고 한 줄" "$ERR" "tp_target_base: seal 마커 S3 에 리뷰 기준점이 없어 종전 기준(base-commit)으로 판정합니다"
}
t_target_base_old_marker

# 아래 두 케이스는 other·병합이 필요 없어 mk_world 만 씁니다(기준 커밋은 BASE).
t_target_base_bad_recorded() {
  mk_world
  local side
  side="$(G "$TMP/root" commit-tree -p "$BASE" -m side "$BASE^{tree}")"
  put "$LC/task-state" "$(printf 'fr-branch=fr/x\nbase-commit=%s\nreview-session=S4' "$BASE")"
  seal S4 "$side"; G "$TMP/root" commit -q -m "seal side"
  tb "$(git -C "$TMP/root" rev-parse HEAD)" fr/x
  eq "AC3 조상 아닌 기록 기준점 → rc 2, stdout 비어 있음" "$RC/$OUT" "2/"
  local k
  for k in "쓸 수 없습니다" "prepare_review_pipeline.sh diff --base" "rd review seal <새 세션 경로>" "커밋한 뒤 다시 실행"; do
    eq "AC3 기록 기준점 안내: $k" "$(printf '%s' "$ERR" | grep -cF -- "$k")" "1"
  done
}
t_target_base_bad_recorded

t_target_base_nofr_session() {
  mk_world
  put "$LC/task-state" "$(printf 'fr-branch=null\nbase-commit=null\nreview-session=S5')"
  seal S5 ""
  put "rd-workflow-workspace/handoffs/review_pipeline/S5/SESSION.md" "$(printf '# S\n\n## Branch Context\n\n- review-base-oid: %s' "$BASE")"
  G "$TMP/root" commit -q -m "seal S5"
  tb "$(git -C "$TMP/root" rev-parse HEAD)" null
  eq "AC4 no-fr 기준점은 SESSION.md review-base-oid" "$RC/$OUT" "0/$BASE"
  G "$TMP/root" rm -q -r "$LC/review-seals" rd-workflow-workspace/handoffs; G "$TMP/root" commit -q -m "drop"
  tb "$(git -C "$TMP/root" rev-parse HEAD)" null
  eq "AC4 기준점 없음(no-fr, base-commit=null) → rc 2" "$RC/$OUT" "2/"
}
t_target_base_nofr_session

t_record_upsert_replaces() {
  mk_world
  local f="$TMP/root/$RD_TEAM_PR_RECORD" o1 o2="2222222222222222222222222222222222222222"
  o1="1111111111111111111111111111111111111111"
  tp_record_upsert "$TMP/root" sub R br "" https://x/pr/1 "$o1" open "" ""
  tp_record_upsert "$TMP/root" lib R2 br2 main https://x/pr/2 "$o1" open "" ""
  tp_record_upsert "$TMP/root" sub R br main https://x/pr/1 "$o1" merged "$o2" 3
  eq "헤더 한 줄" "$(head -1 "$f")" "$(printf 'path\trepo\tbranch\tbase\turl\thead-oid\tstate\tmerged-oid\tcommits')"
  eq "한 path 에 한 줄" "$(grep -c '^sub	' "$f")" "1"
  eq "총 줄 수(헤더+2)" "$(wc -l <"$f" | tr -d ' ')" "3"
  eq "state 가 바뀜" "$(tp_record_get "$TMP/root" sub state)" "merged"
  eq "merged-oid" "$(tp_record_get "$TMP/root" sub merged-oid)" "$o2"
  eq "commits" "$(tp_record_get "$TMP/root" sub commits)" "3"
  eq "다른 path 는 그대로" "$(tp_record_get "$TMP/root" lib state)" "open"
  eq "빈 칸은 빈 값" "$(tp_record_get "$TMP/root" lib merged-oid)" ""
  tp_record_get "$TMP/root" none state >/dev/null 2>&1; eq "없는 path → rc 1" "$?" "1"
  tp_record_get "$TMP/root" sub bogus >/dev/null 2>&1; eq "없는 field → rc 2" "$?" "2"
  tp_record_upsert "$TMP/root" sub R br main "u	x" "$o1" open "" "" 2>/dev/null; eq "탭이 든 값 거부 rc 2" "$?" "2"
  rm -f "$f"; tp_record_get "$TMP/root" sub state >/dev/null 2>&1; eq "파일 없음 → rc 1" "$?" "1"
}
t_record_upsert_replaces

t_preserved_head_mismatch() {
  local a="1111111111111111111111111111111111111111" b="2222222222222222222222222222222222222222" out rc
  out="$(tp_preserved "$TMP" "$b" "$a" "$b" 1)"; rc=$?
  eq "head 가 다르면 rc 1" "$rc" "1"
  eq "head 가 다르면 head-mismatch" "$out" "head-mismatch"
  out="$(tp_preserved "$TMP/nonexistent" "$b" "$a" "$a" 1)"; rc=$?
  eq "head 가 같으면 rd_team_pr_preserved 로 넘김(판정 불가 rc 2)" "$rc/$out" "2/objects-missing"
}
t_preserved_head_mismatch

echo "== light-check =="

lc() { OUT="$(tp_light_check "$TMP/root" "$BASE" 2>&1)"; RC=$?; }

t_light_check_gitlink() {
  mk_world; cfg '{"team_publish": {"mode":"pr","light":"pr"}}'
  git -C "$TMP/root/sub" checkout -q "$NEWOID" 2>/dev/null; G "$TMP/root" add sub
  lc; eq "gitlink 변경 → rc 3" "$RC" "3"
  eq "상향 문구" "$OUT" "standard 로 상향 — sub (반영 방식 pr, team_publish.light=pr)"
}
t_light_check_gitlink
t_light_check_inner_commit() {
  mk_world; cfg '{"team_publish": {"mode":"pr","light":"pr"}}'
  printf 'z\n' >"$TMP/root/sub/g"; G "$TMP/root/sub" add -A; G "$TMP/root/sub" commit -q -m inner
  lc; eq "안쪽 커밋(상위 미반영) → rc 3" "$RC" "3"
}
t_light_check_inner_commit
t_light_check_inner_dirty() {
  mk_world; cfg '{"team_publish": {"mode":"pr","light":"pr"}}'
  printf 'z\n' >"$TMP/root/sub/untracked"
  lc; eq "안쪽 untracked 만 → rc 3" "$RC" "3"
}
t_light_check_inner_dirty
t_light_check_merge() {
  mk_world; cfg '{"team_publish": {"mode":"pr","light":"merge"}}'
  printf 'z\n' >"$TMP/root/sub/untracked"
  lc; eq "light=merge → rc 0" "$RC" "0"
  eq "light 유지 문구" "$OUT" "light 유지 — team_publish.light=merge"
}
t_light_check_merge
t_light_check_manual_only() {
  mk_world; cfg '{"team_publish": {"mode":"pr","light":"pr","submodules":{"sub":{"mode":"manual"}}}}'
  printf 'z\n' >"$TMP/root/sub/untracked"
  lc; eq "manual submodule 안쪽 변경만 → rc 0" "$RC" "0"
  eq "반영 대상 없음" "$OUT" "반영 대상 없음"
  mk_world; cfg '{"team_publish": {}}'
  lc; eq "바뀐 것 없음 → 반영 대상 없음" "$OUT/$RC" "반영 대상 없음/0"
}
t_light_check_manual_only

echo "== 승인 =="

t_approval_required() {
  mk_world
  cfg '{"publish_approval":"user"}'
  tasks_index_upsert s1 launch=ok caller-id=wX:p1 >/dev/null
  tp_approval_required "$TMP/root" s1 2>/dev/null; eq "user → 승인 필요(rc 0)" "$?" "0"
  cfg '{"publish_approval":"caller"}'
  tp_approval_required "$TMP/root" s1 2>/dev/null; eq "caller + caller-id + launch=ok → 불필요(rc 1)" "$?" "1"
  tasks_index_upsert s2 launch=ok >/dev/null
  tp_approval_required "$TMP/root" s2 2>/dev/null; eq "caller-id 없음 → 승인 필요(rc 0)" "$?" "0"
  tasks_index_upsert s3 caller-id=wX:p2 launch=launching >/dev/null
  tp_approval_required "$TMP/root" s3 2>/dev/null; eq "launch != ok → 승인 필요(rc 0)" "$?" "0"
  rm -f "$TMP/root/rd-workflow/config/workflow.json"
  tp_approval_required "$TMP/root" s1 2>/dev/null; eq "설정 파일 없음은 caller → 불필요(rc 1)" "$?" "1"
  cfg '{"publish_approval":"weird"}'
  tp_approval_required "$TMP/root" s1 2>/dev/null; eq "허용 밖 값은 user → 필요(rc 0)" "$?" "0"
}
t_approval_required

# publish_queue.sh 의 pq_approval_mode 와 같은 입력에서 같은 판정(승인 필요 여부)인지 대조한다.
t_approval_parity() {
  mk_world
  tasks_index_upsert pp launch=ok caller-id=wX:p1 >/dev/null
  local c mode want got
  for c in '{"publish_approval":"user"}' '{"publish_approval":"caller"}' '{"x":1}' '{"publish_approval":"weird"}' '{"publish_approval":null}' '{not json' '[1]'; do
    cfg "$c"
    mode="$( ( source "$SCRIPT_DIR/publish_queue.sh"; project_root="$TMP/root" pq_approval_mode ) 2>/dev/null )"
    [[ "$mode" == user ]] && want=0 || want=1
    tp_approval_required "$TMP/root" pp 2>/dev/null; got=$?
    eq "pq_approval_mode($mode) 와 판정 일치: $c" "$got" "$want"
  done
  rm -f "$TMP/root/rd-workflow/config/workflow.json"
  mode="$( ( source "$SCRIPT_DIR/publish_queue.sh"; project_root="$TMP/root" pq_approval_mode ) 2>/dev/null )"
  tp_approval_required "$TMP/root" pp 2>/dev/null; got=$?
  [[ "$mode" == user ]] && want=0 || want=1
  eq "설정 파일 없음도 일치($mode)" "$got" "$want"
}
t_approval_parity

echo "== gh =="

setup_fake_gh() {
  mkdir -p "$TMP/fakebin"
  cat >"$TMP/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
case "${FAKE_GH_MODE:-ok}" in
  hang) sleep 30 ;;
  fail) printf '%s\n' "${FAKE_GH_ERR:-boom}" "second line" >&2; exit 1 ;;
  *)    cat "$FAKE_GH_JSON" ;;
esac
FAKE
  chmod +x "$TMP/fakebin/gh"
}
setup_fake_gh

st() { OUT="$(PATH="$TMP/fakebin:$PATH" RD_PR_CHECK_TIMEOUT="${TO:-15}" tp_pr_state https://example.invalid/o/r/pull/1)"; RC=$?; }
mkjson() { printf '%s\n' "$1" >"$TMP/pr.json"; export FAKE_GH_JSON="$TMP/pr.json"; }

t_pr_state_parse() {
  local o="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" h="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  export FAKE_GH_MODE=ok
  mkjson '{"state":"MERGED","mergeCommit":{"oid":"'$o'"},"reviewDecision":"APPROVED","headRefOid":"'$h'","commits":[{"oid":"1"},{"oid":"2"}],"latestReviews":[]}'
  st; eq "MERGED" "$OUT" "$(printf 'MERGED\t%s\t%s\t2\t' "$o" "$h")"
  mkjson '{"state":"OPEN","mergeCommit":null,"reviewDecision":"CHANGES_REQUESTED","headRefOid":"'$h'","commits":[{"oid":"1"}],"latestReviews":[{"author":{"login":"ann"},"body":"고쳐 주세요\n둘째 줄","state":"CHANGES_REQUESTED","submittedAt":"2026-11-01T00:00:00Z"},{"author":{"login":"bob"},"body":"nit","state":"COMMENTED","submittedAt":"2026-11-02T00:00:00Z"},{"author":{"login":"cy"},"body":"","state":"COMMENTED","submittedAt":"2026-11-03T00:00:00Z"},{"author":{"login":"di"},"body":"old","state":"COMMENTED","submittedAt":"2026-10-01T00:00:00Z"}]}'
  st
  eq "CHANGES_REQUESTED 판정·빈 merge" "$(printf '%s' "$OUT" | cut -f1,2,3,4)" "$(printf 'CHANGES_REQUESTED\t\t%s\t1' "$h")"
  eq "요약 최근 3건, 첫 줄만" "$(printf '%s' "$OUT" | cut -f5)" "cy: (본문 없음) / bob: nit / ann: 고쳐 주세요"
  mkjson '{"state":"CLOSED","mergeCommit":null,"reviewDecision":"","headRefOid":"'$h'","commits":[],"latestReviews":[]}'
  st; eq "CLOSED" "$(printf '%s' "$OUT" | cut -f1,3,4)" "$(printf 'CLOSED\t%s\t0' "$h")"
  mkjson '{"state":"OPEN","mergeCommit":null,"reviewDecision":"REVIEW_REQUIRED","headRefOid":"'$h'","commits":[{"oid":"1"}],"latestReviews":[]}'
  st; eq "OPEN" "$(printf '%s' "$OUT" | cut -f1)" "OPEN"
  export FAKE_GH_MODE=fail FAKE_GH_ERR="HTTP 502 bad gateway"
  st; eq "gh 실패 → ERROR + 오류 첫 줄" "$(printf '%s' "$OUT" | cut -f1,5)" "$(printf 'ERROR\tHTTP 502 bad gateway')"
  mkjson 'not json'; export FAKE_GH_MODE=ok
  st; eq "해석 불가 → ERROR" "$(printf '%s' "$OUT" | cut -f1)" "ERROR"
  export FAKE_GH_MODE=hang
  TO=1 st; eq "시간 초과 → ERROR" "$(printf '%s' "$OUT" | cut -f1)" "ERROR"
  eq "시간 초과 요약에 시간 초과" "$(printf '%s' "$OUT" | cut -f5 | grep -c '시간 초과')" "1"
  unset FAKE_GH_MODE
  PATH="/usr/bin:/bin" tp_gh 5 pr view x >/dev/null 2>&1; eq "gh 없음 rc 127" "$?" "127"
}
t_pr_state_parse

# 시한 안에 끝난 _rd_run_limited 는 감시 sleep 을 남기지 않습니다. 남으면 호출부 프로세스 그룹이 시한(여기 30초)까지
# 비지 않아, 큐 발행이 archive 출력 기다리기 상한(30초)까지 멈춥니다. 호출을 자기 그룹으로 띄워 반환 뒤 그룹이 비는지 봅니다.
# TERM 을 무시하는 호출 셸(`trap '' TERM`)에서도 정상 종료가 시한까지 지연되지 않아야 합니다.
t_run_limited_no_leftover() {
  local mode p i alive t0 el
  for mode in normal ignore-term; do
    alive=1; t0=$SECONDS
    set -m
    bash -c '[[ "$2" == ignore-term ]] && trap "" TERM; source "$1"; _rd_run_limited 30 /dev/null true >/dev/null' \
      _ "$SCRIPT_DIR/../_submodule_common.sh" "$mode" &
    p=$!
    set +m
    wait "$p"
    el=$((SECONDS - t0))
    for ((i = 0; i < 20; i++)); do
      kill -0 -- "-$p" 2>/dev/null || { alive=0; break; }
      sleep 0.1
    done
    eq "_rd_run_limited 정상 종료 뒤 프로세스 그룹이 빔 ($mode)" "$alive" "0"
    eq "_rd_run_limited 정상 종료가 시한을 기다리지 않음 ($mode)" "$([[ "$el" -lt 10 ]] && echo yes || echo "no ${el}초")" "yes"
    kill -KILL -- "-$p" 2>/dev/null || true
  done
}
t_run_limited_no_leftover

# 정상 종료 뒤 실제 감시 sleep 이 남지 않습니다. 감시는 자기 프로세스 그룹에 있어 위 사례(호출 셸 그룹 확인)로는 보이지 않습니다.
#   명령이 감시의 `sleep 4271` 을 pgrep 으로 찾아 PID 를 남기고, 반환 뒤 그 PID 가 죽었는지 봅니다(옛 test_publish_queue.sh G4b(1)).
#   같은 머신의 다른 검증이 띄운 `sleep 4271` 을 잡지 않게, 실행기 셸($PPID)의 자식(감시 서브셸) 아래 sleep 만 찾고
#   정확히 1개일 때만 기록합니다. 그 밖이면 명령이 rc 1 로 끝나 첫 단언이 FAIL 합니다.
#   pgrep 이 프로세스 목록을 얻지 못하는 환경(macOS 기본 PATH 의 「Cannot get process list」)에서는 건너뛰고 표식을 냅니다.
t_run_limited_watchdog_reaped() {
  local wf="$TMP/rlwd.pid" res
  if ! pgrep -f . >/dev/null 2>&1; then
    printf 'env-skip: test_team_publish_common t_run_limited_watchdog_reaped — pgrep 으로 프로세스 목록을 얻을 수 없는 환경(감시 sleep 관측 불가)\n' >&2
    return 0
  fi
  res="$(bash -c 'source "$1"; s=$SECONDS; rc=0
    _rd_run_limited 4271 /dev/null bash -c '"'"'f="$1"; t0=$SECONDS
      while :; do
        p=""; for w in $(pgrep -P "$PPID"); do [[ "$w" == "$$" ]] || p="$p $(pgrep -P "$w" -x sleep)"; done
        set -- $p; [[ $# -eq 0 ]] || break
        [[ $((SECONDS - t0)) -lt 10 ]] || exit 1; sleep 0.05
      done
      [[ $# -eq 1 ]] || exit 1; echo "$1" > "$f"'"'"' _ "$2" >/dev/null || rc=$?
    printf "rc=%s el=%s\n" "$rc" "$((SECONDS - s))"' _ "$SCRIPT_DIR/../_submodule_common.sh" "$wf" 2>/dev/null)"
  eq "_rd_run_limited 감시 sleep 관측 뒤 정상 종료 → rc 0, 2초 안" "$([[ "$res" == "rc=0 el="[0-2] ]] && echo yes || echo "no $res")" "yes"
  eq "_rd_run_limited 정상 종료 뒤 감시 sleep 이 남지 않음" \
    "$([[ -s "$wf" ]] && ! kill -0 "$(cat "$wf")" 2>/dev/null && echo yes || echo "no pid=$(cat "$wf" 2>/dev/null)")" "yes"
}
t_run_limited_watchdog_reaped

# 시간 초과: 부모는 TERM 으로 끝나고 자식만 TERM 을 무시해도 그룹 KILL 로 상한 + 4초 안에 rc 124 로 돌아오고 둘 다 남지 않습니다.
#   호출부 stderr 는 비어 있어야 합니다(옛 rd_run_limited 의 `wait 2>/dev/null` 을 합치며 들였습니다).
#   (옛 test_publish_queue.sh G4b(2). _merge_precheck.sh 의 실행기를 _rd_run_limited 로 합치며 옮겼습니다.)
t_run_limited_timeout() {
  local pp="$TMP/rlto.ppid" cp="$TMP/rlto.cpid" ef="$TMP/rlto.err" res
  res="$(bash -c 'source "$1"; s=$SECONDS; rc=0
    _rd_run_limited 1 /dev/null bash -c '"'"'echo $$ > "$1"; (trap "" TERM; exec sleep 30) & echo $! > "$2"; wait'"'"' _ "$2" "$3" >/dev/null || rc=$?
    printf "rc=%s el=%s\n" "$rc" "$((SECONDS - s))"' _ "$SCRIPT_DIR/../_submodule_common.sh" "$pp" "$cp" 2>"$ef")"
  eq "_rd_run_limited TERM 무시 자식 → rc 124, 5초 안" "$([[ "$res" == "rc=124 el="[0-5] ]] && echo yes || echo "no $res")" "yes"
  eq "_rd_run_limited 시간 초과 뒤 부모·자식 모두 종료" \
    "$([[ -s "$pp" && -s "$cp" ]] && ! kill -0 "$(cat "$pp")" 2>/dev/null && ! kill -0 "$(cat "$cp")" 2>/dev/null && echo yes || echo "no parent=$(cat "$pp" 2>/dev/null) child=$(cat "$cp" 2>/dev/null)")" "yes"
  # 시간 초과 안내는 호출부가 냅니다. 셸의 작업 알림(「Terminated」·「Killed」)이 호출부 stderr 에 섞이지 않아야 합니다.
  eq "_rd_run_limited 시간 초과가 호출부 stderr 에 셸 작업 알림을 남기지 않음" "$(cat "$ef")" ""
}
t_run_limited_timeout

echo "== manual gitlink 와 팀 기본 브랜치 비교 (tp_manual_lag) =="

# 세계: sub 의 gitlink(BASE 시점 = 팀 main 의 첫 커밋 a)와 팀 main 끝(b), 팀 dev 브랜치에만 있는 커밋.
t_manual_lag() {
  local a res rc dev
  mk_world
  a="$(git -C "$TMP/root" ls-tree HEAD sub | awk '{print $3}')"
  eq "끝과 같음 → same" "$(tp_manual_lag "$TMP/root/sub" "$NEWOID")" "same	main	$NEWOID	0"
  eq "기본 브랜치 이력 안 → behind 1" "$(tp_manual_lag "$TMP/root/sub" "$a")" "behind	main	$NEWOID	1"
  G "$TMP/teamwc" switch -q -c dev; printf 'd\n' >"$TMP/teamwc/f"; G "$TMP/teamwc" commit -q -am d
  dev="$(git -C "$TMP/teamwc" rev-parse HEAD)"; G "$TMP/teamwc" push -q origin dev 2>/dev/null
  git -C "$TMP/root/sub" fetch -q origin 2>/dev/null
  res="$(tp_manual_lag "$TMP/root/sub" "$dev")"
  eq "기본 브랜치 밖 커밋 → outside" "${res%%	*}" "outside"
  eq "대상 브랜치를 주면 그 브랜치와 견줌" "$(tp_manual_lag "$TMP/root/sub" "$dev" dev)" "same	dev	$dev	0"
  # 끝 커밋 객체가 로컬에 없으면 그 브랜치를 받아 셉니다.
  G "$TMP/teamwc" switch -q main; printf 'c\n' >"$TMP/teamwc/f"; G "$TMP/teamwc" commit -q -am c
  G "$TMP/teamwc" tag t-c; G "$TMP/teamwc" push -q origin main t-c 2>/dev/null
  # 받기의 쓰기 범위: 다른 fetch 매핑(backup)과 FETCH_HEAD 는 건드리지 않습니다.
  git -C "$TMP/root/sub" config --add remote.origin.fetch '+refs/heads/main:refs/remotes/backup/main'
  local fh0; fh0="$(cat "$(git -C "$TMP/root/sub" rev-parse --git-path FETCH_HEAD)" 2>/dev/null)"
  # 명령 치환 없이 불러 결과를 _TP_LAG_RESULT 로 받습니다(호출부와 같은 방식).
  tp_manual_lag "$TMP/root/sub" "$a" >/dev/null
  eq "끝 객체가 없으면 받아서 판정 → behind 2" "$(cut -f1,4 <<<"$_TP_LAG_RESULT")" "behind	2"
  eq "받기는 태그를 따라 받지 않음" "$(git -C "$TMP/root/sub" tag -l)" ""
  eq "받기는 다른 fetch 매핑을 갱신하지 않음" "$(git -C "$TMP/root/sub" for-each-ref refs/remotes/backup)" ""
  eq "받기는 FETCH_HEAD 를 덮지 않음" "$(cat "$(git -C "$TMP/root/sub" rev-parse --git-path FETCH_HEAD)" 2>/dev/null)" "$fh0"
  # 얕은 복제: 지난 커밋과 main 끝을 모두 가졌어도 사이 이력이 잘려 있으면 기본 브랜치 밖이라고 단정하지 않습니다.
  G "$TMP/teamwc" push -q origin "$a:refs/heads/picked" 2>/dev/null
  git clone -q --depth=1 --no-single-branch "file://$TMP/team.git" "$TMP/shallow" 2>/dev/null
  rc=0; tp_manual_lag "$TMP/shallow" "$a" >/dev/null 2>&1 || rc=$?
  eq "얕은 복제에서 조상 아님 → 판정 불가 rc 1" "$rc" "1"
  eq "얕은 복제 원인 안내" "$([[ "$_TP_LAG_CAUSE" == *"얕은 복제라"*"fetch --unshallow origin"* ]] && echo yes || echo "no [$_TP_LAG_CAUSE]")" "yes"
  # 원격 조회 실패 → rc 1, 원인 있음, 출력 없음.
  git -C "$TMP/root/sub" remote set-url origin "$TMP/missing.git"
  rc=0; res="$(tp_manual_lag "$TMP/root/sub" "$a" 2>/dev/null)" || rc=$?
  eq "원격 조회 실패 → rc 1, 출력 없음" "$rc/$res" "1/"
  tp_manual_lag "$TMP/root/sub" "$a" >/dev/null 2>&1 || true
  eq "원격 조회 실패 원인이 남음" "$([[ -n "$_TP_LAG_CAUSE" ]] && echo yes || echo no)" "yes"
}
t_manual_lag

# 안내가 가리킬 설정 키: 경로별 mode 가 있으면 그 키, 없으면 전역 키.
t_config_key() {
  mk_world
  cfg '{"team_publish": {"mode": "pr", "submodules": {"sub": {"mode": "manual"}}}}'
  eq "경로별 mode 가 있으면 경로별 키" "$(tp_config_key "$TMP/root" sub mode)" "team_publish.submodules.sub.mode"
  cfg '{"team_publish": {"mode": "manual", "submodules": {"sub": {"base": "dev"}}}}'
  eq "경로별 mode 가 없으면 전역 키" "$(tp_config_key "$TMP/root" sub mode)" "team_publish.mode"
}
t_config_key

# 부른 쪽 프로세스 그룹이 회수되면 비교 fetch 도 함께 끝나 반환 뒤 원격 추적 ref 를 쓰지 않습니다(무인 발행의 시간 상한·신호).
#   팀 원격의 upload-pack 을 두 번째 호출(fetch)에서만 4초 늦추고, fetch 가 시작되면 비교를 돌리는 그룹에 TERM 을 보냅니다.
#   TERM 은 무인 발행의 그룹 회수, INT 는 터미널 Ctrl-C 입니다. 각각 약 7초 걸립니다 — 회수 뒤 늦은 ref 쓰기가 없는지는 지연이
#   끝난 뒤에야 볼 수 있습니다.
t_manual_lag_reaped() {
  local sig="$1" a before bp i n
  mk_world
  a="$(git -C "$TMP/root" ls-tree HEAD sub | awk '{print $3}')"
  printf 'c\n' >"$TMP/teamwc/f"; G "$TMP/teamwc" commit -q -am c; G "$TMP/teamwc" push -q origin main 2>/dev/null
  cat >"$TMP/slow-up.sh" <<EOF_UP
#!/bin/sh
n=\$(cat "$TMP/up.count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"$TMP/up.count"
if [ "\$n" -ge 2 ]; then echo \$\$ >"$TMP/up.pid"; sleep 4 & echo \$! >"$TMP/up.child"; wait; fi
exec git upload-pack "\$@"
EOF_UP
  chmod +x "$TMP/slow-up.sh"; rm -f "$TMP/up.count" "$TMP/up.pid" "$TMP/up.child"
  git -C "$TMP/root/sub" config remote.origin.uploadpack "$TMP/slow-up.sh"
  before="$(git -C "$TMP/root/sub" rev-parse refs/remotes/origin/main)"
  # archive·promote 와 같은 조건(job control 없는 새 bash)에서 부르고, 그 프로세스를 자기 그룹으로 띄워 그룹째 신호를 보냅니다.
  set -m
  bash -c 'project_root="$1"; source "$2/_lifecycle_common.sh"; source "$2/../_state_common.sh"; source "$2/../_submodule_common.sh"
    source "$2/_tasks_index.sh"; source "$2/_team_publish_common.sh"; tp_manual_lag "$3" "$4" >/dev/null 2>&1' \
    _ "$TMP/root" "$SCRIPT_DIR" "$TMP/root/sub" "$a" &
  bp=$!
  set +m
  # 전송 하위 프로세스가 생기자마자 신호를 보냅니다(fetch 시작 직후의 Ctrl-C 도 덮습니다).
  for ((i = 0; i < 100; i++)); do [[ -s "$TMP/up.child" ]] && break; sleep 0.05; done
  kill "-$sig" -- "-$bp" 2>/dev/null; wait "$bp" 2>/dev/null
  # 회수 뒤 1초 안에 전송 하위 프로세스(SIGINT 를 무시하는 sleep)까지 끝났는지 봅니다.
  for ((i = 0; i < 10; i++)); do ! kill -0 "$(cat "$TMP/up.child" 2>/dev/null)" 2>/dev/null && break; sleep 0.1; done
  eq "$sig: 전송 하위 프로세스가 남지 않음" "$([[ -s "$TMP/up.child" ]] && ! kill -0 "$(cat "$TMP/up.child")" 2>/dev/null && echo yes || echo no)" "yes"
  eq "$sig: 회수 시점의 원격 추적 ref 는 그대로" "$(git -C "$TMP/root/sub" rev-parse refs/remotes/origin/main)" "$before"
  sleep 5
  eq "$sig: 회수 뒤 늦은 ref 쓰기 없음" "$(git -C "$TMP/root/sub" rev-parse refs/remotes/origin/main)" "$before"
  eq "$sig: 늦춘 upload-pack 이 남지 않음" "$([[ -s "$TMP/up.pid" ]] && ! kill -0 "$(cat "$TMP/up.pid")" 2>/dev/null && echo yes || echo no)" "yes"
}
t_manual_lag_reaped TERM
t_manual_lag_reaped INT

# 비교 자체가 상한에 걸리면 git 이 띄운 전송 하위 프로세스까지 끝냅니다 — 남으면 발행 큐가 archive 그룹이 빌 때까지 기다립니다.
#   upload-pack 대역이 TERM 을 무시하는 8초짜리 하위 프로세스를 띄우고 기다립니다. 상한 1초로 비교한 뒤 4초 안에 그 하위
#   프로세스가 끝났는지, 비교를 돌린 그룹이 반환 직후 비는지 봅니다(TERM 뒤 KILL 까지 가야 끝납니다).
#   약 4초 걸립니다.
t_manual_lag_timeout_reaped() {
  local a i bp el
  mk_world
  a="$(git -C "$TMP/root" ls-tree HEAD sub | awk '{print $3}')"
  cat >"$TMP/hang-up.sh" <<EOF_UP
#!/bin/sh
( trap "" TERM; exec sleep 8 ) &
echo \$! >"$TMP/hang-child.pid"
wait
EOF_UP
  chmod +x "$TMP/hang-up.sh"; rm -f "$TMP/hang-child.pid" "$TMP/hang.rc"
  git -C "$TMP/root/sub" config remote.origin.uploadpack "$TMP/hang-up.sh"
  # 발행 실행과 같이 비교를 돌리는 bash 를 자기 그룹으로 띄우고, 반환한 뒤 그 그룹이 바로 비는지 봅니다(발행 큐가 기다리는 조건).
  set -m
  bash -c 'project_root="$1"; source "$2/_lifecycle_common.sh"; source "$2/../_state_common.sh"; source "$2/../_submodule_common.sh"
    source "$2/_tasks_index.sh"; source "$2/_team_publish_common.sh"
    rc=0; RD_TP_LAG_TIMEOUT=1 tp_manual_lag "$3" "$4" >/dev/null 2>&1 || rc=$?; printf "%s/%s\n" "$rc" "$_TP_LAG_CAUSE" >"$5"' \
    _ "$TMP/root" "$SCRIPT_DIR" "$TMP/root/sub" "$a" "$TMP/hang.rc" &
  bp=$!
  set +m
  wait "$bp" 2>/dev/null
  # 반환 직후 0.3초 안에 그룹이 비어야 합니다(유예 타이머·감시·전송 하위 프로세스가 남지 않음).
  for ((i = 0; i < 6; i++)); do kill -0 -- "-$bp" 2>/dev/null || break; sleep 0.05; done
  el="$(kill -0 -- "-$bp" 2>/dev/null && echo 남음 || echo 빔)"
  eq "비교 상한 → rc 1, 원인 시간 초과" "$(cat "$TMP/hang.rc" 2>/dev/null)" "1/1초 안에 끝나지 않았습니다"
  eq "비교 상한 뒤 부른 쪽 그룹이 바로 빔" "$el" "빔"
  eq "비교 상한 뒤 전송 하위 프로세스가 남지 않음" "$([[ -s "$TMP/hang-child.pid" ]] && ! kill -0 "$(cat "$TMP/hang-child.pid")" 2>/dev/null && echo yes || echo no)" "yes"
  [[ ! -s "$TMP/hang-child.pid" ]] || kill -KILL "$(cat "$TMP/hang-child.pid")" 2>/dev/null
  kill -KILL -- "-$bp" 2>/dev/null
}
t_manual_lag_timeout_reaped

printf '\n== 합계 ==\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
