#!/usr/bin/env bash
# test_sync_template_reinstall.sh — sync_template.sh reinstall 시험 (C8: 7·8단계 skill·extension 재설치, preset 머지, 매니페스트 저장)
# fixture 는 mktemp -d 아래에만 만든다. install_claude_skills.sh project 는 프로젝트 안만 쓰지만 HOME 도 임시로 돌린다.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
WORK="$(mktemp -d)" || { echo "test_sync_template_reinstall.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "test_sync_template_reinstall.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=_tpl_test_common.sh
source "$SCRIPT_DIR/_tpl_test_common.sh"
export HOME="$WORK/home"; mkdir -p "$HOME"

TAB=$'\t'
has_line() { printf '%s\n' "$TPL_OUT" | grep -qxF -- "$1" && echo yes || echo no; }
has_prefix() { printf '%s\n' "$TPL_OUT" | grep -q -- "^$1" && echo yes || echo no; }
nl() { printf '%s\n' "$@"; }
# jq_ <파일> <python 식>... — 파일을 한 번 파싱해 식마다 JSON 한 줄로 출력 (d 가 파싱된 JSON, 실패는 ERR)
jq_() { python3 - "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in sys.argv[2:]:
    try:
        print(json.dumps(eval(e), ensure_ascii=False))
    except Exception as ex:
        print("ERR " + type(ex).__name__)
PY
}

PRESET_TPL='{"verifiers": {"a": {"run": "new", "adapter": "ad-new", "evaluate": "tpl-eval", "criteria": [{"name": "c1", "weight": "high"}, {"name": "c2"}], "requires_env": ["E1"]}, "b": {"run": "rb", "criteria": []}}}'
PROJ_VER='{"verifiers": {"a": {"run": "old", "evaluate": "mine", "criteria": [{"name": "c1", "weight": "low"}, {"name": "c3"}]}, "mine": {"run": "m"}}}'

# 기준 fixture 를 한 번 만들고 cp -R 로 복제한다 (clone·proj 모두 복제본 안에 있다)
mkbase() { # mkbase <이름> <full|lite>
  local base="$WORK/$1" kind="$2" p e
  tpl_make_clone "$base/clone" full
  tpl_make_project "$base/proj" "$base/clone"
  p="$base/proj"
  cp -p "$SCRIPT_DIR/install_claude_skills.sh" "$p/rd-workflow/scripts/"
  tpl_put "$p" rd-workflow/claude_skills/x/SKILL.md 'x'
  if [[ "$kind" == "full" ]]; then
    for e in verify design-review; do
      tpl_put "$p" "rd-workflow/extensions/$e/SKILL.md" "---
name: $e
description: d-$e
---
body-$e"
      tpl_put "$p" "rd-workflow/extensions/$e/rules.md" "rules-$e"
    done
    tpl_put "$p" rd-workflow/extensions/verify/presets/cli/verification.json "$PRESET_TPL"
    tpl_put "$p" rd-workflow/claude_skills/verify/SKILL.md 'old verify'
    tpl_put "$p" rd-workflow/config/verification.json "$PROJ_VER"
  fi
}
mkbase base full
mkbase baselite lite
mk() { # mk <이름> <full|lite> [매니페스트 JSON]
  local src=base; [[ "$2" == "lite" ]] && src=baselite
  cp -R "$WORK/$src" "$WORK/$1"
  [[ -n "${3:-}" ]] && tpl_put "$WORK/$1/proj" rd-workflow/config/extensions.json "$3"
  return 0
}
M_VERIFY='{"extensions": {"verify": {"installed_at": "t", "preset": "cli", "seen_verifiers": ["a"]}}, "seen_extensions": ["verify"]}'
run() { tpl_run "$WORK/$1/proj" "$WORK/$1/clone" reinstall "${@:2}"; }
MF() { echo "$WORK/$1/proj/rd-workflow/config/extensions.json"; }
VJ() { echo "$WORK/$1/proj/rd-workflow/config/verification.json"; }

echo "== C8-1: 자동 재설치·머지·묻기 =="
mk c1 full "$M_VERIFY"
run c1
tpl_check "1 종료 코드" "$TPL_RC" "0"
tpl_check "1 stderr 비어 있음" "$TPL_ERR" ""
tpl_check "1 skills 줄" "$(has_prefix "skills${TAB}")" "yes"
tpl_check "1 skill 갱신 note 없음(요약 줄 refreshed: 0 제외)" "$(has_prefix "note${TAB}skill 갱신")" "no"
tpl_check "1 auto verify" "$(has_line "auto${TAB}verify")" "yes"
tpl_check "1 ask-ext design-review" "$(has_line "ask-ext${TAB}design-review${TAB}d-design-review")" "yes"
tpl_check "1 ask-verifier 없음" "$(has_prefix "ask-verifier")" "no"
tpl_check "1 merge 줄" "$(has_prefix "merge${TAB}")" "yes"
tpl_check "1 verification.json" "$(jq_ "$(VJ c1)" 'd["verifiers"]["a"]["run"]' 'd["verifiers"]["a"]["adapter"]' 'd["verifiers"]["a"]["evaluate"]' \
  '[(c["name"], c.get("weight")) for c in d["verifiers"]["a"]["criteria"]]' 'd["verifiers"]["a"]["requires_env"]' 'd["verifiers"]["b"]["run"]' '"mine" in d["verifiers"]')" \
  "$(nl '"new"' '"ad-new"' '"mine"' '[["c1", "low"], ["c2", null]]' '["E1"]' '"rb"' 'true')"
tpl_check "1 매니페스트(seen_verifiers, 묻지 못한 design-review 는 seen_extensions 에서 제외)" "$(jq_ "$(MF c1)" 'd["extensions"]["verify"]["seen_verifiers"]' 'd["seen_extensions"]')" "$(nl '["a", "b"]' '["verify"]')"
tpl_check "1 자동 재설치로 SKILL.md·rules.md 복사" "$(sed -n 2p "$WORK/c1/proj/rd-workflow/claude_skills/verify/SKILL.md"; cat "$WORK/c1/proj/rd-workflow/claude_skills/verify/rules.md")" "$(nl 'name: verify' 'rules-verify')"

echo "== C8-2: --declined =="
mk c2 full "$M_VERIFY"
run c2 --declined design-review
tpl_check "2 종료 코드" "$TPL_RC" "0"
tpl_check "2 ask-ext 없음" "$(has_prefix "ask-ext")" "no"
tpl_check "2 seen_extensions 에 거절 포함" "$(jq_ "$(MF c2)" 'd["seen_extensions"]')" '["design-review", "verify"]'
run c2
tpl_check "2 재실행 ask-ext 없음" "$(has_prefix "ask-ext")" "no"
tpl_check "2 재실행 declined 줄" "$(has_line "declined${TAB}design-review")" "yes"

echo "== C8-3: --failed =="
mk c3 full "$M_VERIFY"
run c3 --failed design-review
tpl_check "3 failed 줄" "$(has_line "failed${TAB}design-review")" "yes"
tpl_check "3 seen_extensions 에 없음" "$(jq_ "$(MF c3)" 'd["seen_extensions"]')" '["verify"]'
tpl_check "3 ask-ext 없음(이미 답함)" "$(has_prefix "ask-ext")" "no"

echo "== C8-4: seen_verifiers 없음 =="
M4='{"extensions": {"verify": {"installed_at": "t", "preset": "cli"}}, "seen_extensions": ["verify", "design-review"]}'
mk c4 full "$M4"
tpl_put "$WORK/c4/proj" rd-workflow/config/verification.json '{"verifiers": {"a": {"run": "old", "evaluate": "mine"}}}'
cp -R "$WORK/c4" "$WORK/c4s"
run c4
tpl_check "4 ask-verifier b" "$(printf '%s\n' "$TPL_OUT" | grep '^ask-verifier')" "ask-verifier${TAB}b"
tpl_check "4 묻기만 한 상태: seen_verifiers 키 없음" "$(jq_ "$(MF c4)" '"seen_verifiers" in d["extensions"]["verify"]')" "false"
tpl_check "4 묻기만 한 상태: b 없음·a 머지됨" "$(jq_ "$(VJ c4)" '"b" in d["verifiers"]' 'd["verifiers"]["a"]["run"]')" "$(nl false '"new"')"
run c4 --verifier-add b
tpl_check "4 추가 후 ask-verifier 없음" "$(has_prefix "ask-verifier")" "no"
tpl_check "4 b 추가·seen_verifiers" "$(jq_ "$(VJ c4)" '"b" in d["verifiers"]'; jq_ "$(MF c4)" 'd["extensions"]["verify"]["seen_verifiers"]')" "$(nl true '["a", "b"]')"
run c4s --verifier-skip b
tpl_check "4 skip: b 추가 안 함·seen_verifiers 에 기록" "$(jq_ "$(VJ c4s)" '"b" in d["verifiers"]'; jq_ "$(MF c4s)" 'd["extensions"]["verify"]["seen_verifiers"]')" "$(nl false '["a", "b"]')"

echo "== C8-5: 허용 밖 preset =="
mk c5 full '{"extensions": {"verify": {"installed_at": "t", "preset": "bogus"}}, "seen_extensions": ["verify", "design-review"]}'
run c5
tpl_check "5 ask-preset" "$(has_line "ask-preset${TAB}bogus")" "yes"
tpl_check "5 preset 키 삭제" "$(jq_ "$(MF c5)" '"preset" in d["extensions"]["verify"]')" 'false'
run c5 --preset cli
tpl_check "5 --preset 로 설정" "$(jq_ "$(MF c5)" 'd["extensions"]["verify"]["preset"]')" '"cli"'

echo "== C8-6: lite (extensions 없음, 매니페스트 없음) =="
mk c6 lite
run c6
tpl_check "6 종료 코드" "$TPL_RC" "0"
tpl_check "6 skills 줄" "$(has_prefix "skills${TAB}")" "yes"
tpl_check "6 매니페스트 미생성" "$([[ -e "$(MF c6)" ]] && echo yes || echo no)" "no"

echo "== 보조: legacy presets·조정·매니페스트 없음 =="
mk c7 full '{"extensions": {"presets": {"preset": "cli"}, "design-review": {"installed_at": "t"}}}'
rm -rf "$WORK/c7/proj/rd-workflow/claude_skills/design-review"; mkdir -p "$WORK/c7/proj/rd-workflow/extensions/presets/old"
run c7
tpl_check "7 Case B(verify 설치됨): preset 이전·presets 키 삭제" "$(jq_ "$(MF c7)" 'd["extensions"]["verify"]["preset"]' '"presets" in d["extensions"]')" "$(nl '"cli"' false)"
tpl_check "7 removed design-review(설치 안 됨)" "$(has_line "removed${TAB}design-review")" "yes"
tpl_check "7 presets 잔재 삭제" "$([[ -d "$WORK/c7/proj/rd-workflow/extensions/presets" ]] && echo yes || echo no)" "no"
mk c7b full '{"extensions": {"presets": {"preset": "cli"}}}'
rm -rf "$WORK/c7b/proj/rd-workflow/claude_skills/verify"
run c7b
tpl_check "7 Case B 미설치: ask-preset 옛 값·ask-ext verify, verify 는 declined 아님" "$(printf '%s\n' "$TPL_OUT" | grep -E '^(declined|ask-)')" "$(nl "declined${TAB}design-review" "ask-preset${TAB}cli" "ask-ext${TAB}verify${TAB}d-verify")"
mk c7c full '{"extensions": {"presets": {"preset": "cli"}}, "seen_extensions": ["verify", "design-review"]}'
rm -rf "$WORK/c7c/proj/rd-workflow/claude_skills/verify"
run c7c
tpl_check "7 Case B 미설치 + seen_extensions 있음: verify 는 ask-ext, declined 아님" "$(printf '%s\n' "$TPL_OUT" | grep -E '^(declined|ask-ext)')" "$(nl "declined${TAB}design-review" "ask-ext${TAB}verify${TAB}d-verify")"
mk c8 full
run c8
tpl_check "8 매니페스트 없음 → verify 자동, design-review 질문" "$(printf '%s\n' "$TPL_OUT" | grep -E '^(auto|ask-ext)')" "auto${TAB}verify
ask-ext${TAB}design-review${TAB}d-design-review"
tpl_check "8 매니페스트 생성(설치분만)" "$(jq_ "$(MF c8)" 'sorted(d["extensions"])')" '["verify"]'
mk c9 full '{"extensions": {}}'
run c9
tpl_check "9 조정 added·seen_extensions 없으면 묻지 않고 새로 기록·declined 보고" "$(has_line "added${TAB}verify")$(has_prefix "ask-ext")$(has_line "declined${TAB}design-review")$(jq_ "$(MF c9)" 'd["seen_extensions"]')" 'yesnoyes["design-review", "verify"]'

if [[ "$FAIL" == "0" ]]; then
  echo "test_sync_template_reinstall: 전체 통과"
else
  echo "test_sync_template_reinstall: 실패 있음" >&2
  exit 1
fi
