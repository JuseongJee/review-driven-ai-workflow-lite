#!/usr/bin/env bash
# test_sync_template.sh — sync_template.sh 타입 가드·버전 가드 단위 테스트 (self_test.sh가 실행)
# fixture: mktemp에 원격 대역 git repo와 프로젝트 구조를 구성 — 네트워크 불필요
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FULL_OLD="2026-07-01-120000"
FULL_NEW="2026-07-08-120000"
LITE_OLD="lite-2026-07-01-120000"
LITE_NEW="lite-2026-07-08-120000"

make_remote() { # make_remote <dir> <version값|-> ; '-'는 VERSION 파일 없음
  local dir="$1" ver="$2"
  mkdir -p "$dir/rd-workflow"
  [[ "$ver" != "-" ]] && printf '%s\n' "$ver" > "$dir/rd-workflow/VERSION"
  git -C "$dir" init --quiet
  git -C "$dir" -c user.email=t@t.t -c user.name=t add -A
  git -C "$dir" -c user.email=t@t.t -c user.name=t commit --quiet --allow-empty -m fixture
}

make_project() { # make_project <dir> <version값|->
  local dir="$1" ver="$2"
  mkdir -p "$dir/rd-workflow/scripts"
  cp "$SCRIPT_DIR/sync_template.sh" "$dir/rd-workflow/scripts/"
  [[ "$ver" != "-" ]] && printf '%s\n' "$ver" > "$dir/rd-workflow/VERSION"
}

run_sync() { # run_sync <proj> <remote> [flags...] — 결과를 $OUT/$RC에 저장
  local proj="$1" remote="$2"; shift 2
  OUT="$(bash "$proj/rd-workflow/scripts/sync_template.sh" "$remote" "$@" 2>&1)"; RC=$?
  if [[ "$RC" == "0" ]]; then
    # 통과 시 마지막 줄이 임시 clone 경로 — 테스트에서는 즉시 정리
    local clone_path
    clone_path="$(printf '%s\n' "$OUT" | tail -1)"
    [[ -d "$clone_path" ]] && rm -rf "$(dirname "$clone_path")"
  fi
}

expect() { # expect <설명> <기대RC> <포함문자열|-> [비포함문자열]
  local desc="$1" want_rc="$2" want_sub="$3" not_sub="${4:-}"
  local ok=1
  [[ "$RC" != "$want_rc" ]] && { echo "FAIL: $desc (exit $RC != $want_rc)"; ok=0; }
  if [[ "$want_sub" != "-" && "$OUT" != *"$want_sub"* ]]; then
    echo "FAIL: $desc (출력에 '$want_sub' 없음)"; ok=0
  fi
  if [[ -n "$not_sub" && "$OUT" == *"$not_sub"* ]]; then
    echo "FAIL: $desc (출력에 '$not_sub' 있음)"; ok=0
  fi
  if [[ "$ok" == "1" ]]; then echo "ok: $desc"; else FAIL=1; fi
}

# fixture 준비 -------------------------------------------------------------
make_remote "$WORK/r_lite" "$LITE_NEW"
make_remote "$WORK/r_lite_old" "$LITE_OLD"
make_remote "$WORK/r_full_new" "$FULL_NEW"
make_remote "$WORK/r_full_old" "$FULL_OLD"
make_remote "$WORK/r_bad" "v1.2.3"
make_project "$WORK/p_full_old" "$FULL_OLD"
make_project "$WORK/p_full_new" "$FULL_NEW"
make_project "$WORK/p_lite" "$LITE_NEW"
make_project "$WORK/p_novers" "-"

# 1. full 프로젝트 + lite 원격 → 타입 불일치 차단 (AC 1)
run_sync "$WORK/p_full_old" "$WORK/r_lite"
expect "full+lite 교차 차단" 1 "템플릿 타입 불일치"

# 2. lite 프로젝트 + full 원격 → 타입 불일치 차단, 다운그레이드 오진 없음 (AC 2)
run_sync "$WORK/p_lite" "$WORK/r_full_new"
expect "lite+full 교차 차단 (오진 메시지 없음)" 1 "템플릿 타입 불일치" "오래되었습니다"

# 3. full↔full 업그레이드 → 통과 (AC 3)
run_sync "$WORK/p_full_old" "$WORK/r_full_new"
expect "같은 타입 업그레이드 통과" 0 "버전 확인 통과"

# 4. full↔full 다운그레이드 → 차단 후 --force 통과 (AC 3)
run_sync "$WORK/p_full_new" "$WORK/r_full_old"
expect "같은 타입 다운그레이드 차단" 1 "오래되었습니다"
run_sync "$WORK/p_full_new" "$WORK/r_full_old" --force
expect "같은 타입 다운그레이드 --force 통과" 0 "-"

# 5. 로컬 VERSION 부재 → 타입 미확정 차단 (AC 4)
run_sync "$WORK/p_novers" "$WORK/r_full_new"
expect "로컬 VERSION 부재 차단" 1 "템플릿 타입을 확정할 수 없습니다"

# 6. 원격 VERSION 형식 불일치 → 타입 미확정 차단 (AC 4)
run_sync "$WORK/p_full_old" "$WORK/r_bad"
expect "형식 불일치 VERSION 차단" 1 "템플릿 타입을 확정할 수 없습니다"

# 7. 교차 + --allow-type-mismatch → 경고와 함께 통과 (AC 5 복구 경로)
run_sync "$WORK/p_full_old" "$WORK/r_lite" --allow-type-mismatch
expect "--allow-type-mismatch 우회 통과" 0 "경고: --allow-type-mismatch"

# 8. 교차 + --force만 → 여전히 차단 (--force 비우회, AC 5)
run_sync "$WORK/p_full_old" "$WORK/r_lite" --force
expect "--force는 타입 불일치 비우회" 1 "템플릿 타입 불일치"

# 9. same-type 다운그레이드 + --allow-type-mismatch → 여전히 차단 (플래그가 same-type 버전 가드 비우회)
run_sync "$WORK/p_full_new" "$WORK/r_full_old" --allow-type-mismatch
expect "same-type 다운그레이드는 --allow-type-mismatch 비우회" 1 "오래되었습니다"

# 10. lite↔lite 다운그레이드 → 차단 (같은 타입 내 lite 사전순 비교 정상 동작)
run_sync "$WORK/p_lite" "$WORK/r_lite_old"
expect "lite 같은 타입 다운그레이드 차단" 1 "오래되었습니다"

# --print-upstream ----------------------------------------------------------
# 순수 변환 경로 — 기존 run_sync/expect 픽스처와 무관하게 SCRIPT_UNDER_TEST 를 직접 호출한다.
SCRIPT_UNDER_TEST="$SCRIPT_DIR/sync_template.sh"
ok()    { printf '  ok   %s\n' "$1"; }
nok()   { FAIL=1; printf '  FAIL %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1 (기대='$3' 실제='$2')"; fi; }

echo "== --print-upstream: URL 유도 행렬 =="
PU() { bash "$SCRIPT_UNDER_TEST" --print-upstream "$1" 2>/dev/null; }

check "https 기본"        "$(PU 'https://github.com/JuseongJee/review-driven-ai-workflow')"      "JuseongJee/review-driven-ai-workflow"
check "https .git"        "$(PU 'https://github.com/JuseongJee/review-driven-ai-workflow.git')"  "JuseongJee/review-driven-ai-workflow"
check "https trailing /"  "$(PU 'https://github.com/JuseongJee/review-driven-ai-workflow/')"     "JuseongJee/review-driven-ai-workflow"
check "https .git 및 /"   "$(PU 'https://github.com/JuseongJee/review-driven-ai-workflow.git/')" "JuseongJee/review-driven-ai-workflow"
check "ssh scp .git"      "$(PU 'git@github.com:JuseongJee/review-driven-ai-workflow.git')"      "JuseongJee/review-driven-ai-workflow"
check "ssh scp bare"      "$(PU 'git@github.com:JuseongJee/review-driven-ai-workflow')"          "JuseongJee/review-driven-ai-workflow"
check "lite https"        "$(PU 'https://github.com/JuseongJee/review-driven-ai-workflow-lite.git')" "JuseongJee/review-driven-ai-workflow-lite"
check "GHE https"         "$(PU 'https://oss.navercorp.com/jay-jee/review-driven-ai-workflow.git')"  "oss.navercorp.com/jay-jee/review-driven-ai-workflow"
check "GHE ssh"           "$(PU 'git@oss.navercorp.com:jay-jee/review-driven-ai-workflow.git')"      "oss.navercorp.com/jay-jee/review-driven-ai-workflow"
check "GHE lite ssh"      "$(PU 'git@oss.navercorp.com:jay-jee/review-driven-ai-workflow-lite.git')" "oss.navercorp.com/jay-jee/review-driven-ai-workflow-lite"

echo "== --print-upstream: credential 제거 =="
out="$(PU 'https://someuser:ghp_secrettoken@github.com/O/R.git')"
check "credential 제거"   "$out" "O/R"
case "$out" in *ghp_secret*) nok "토큰 유출";; *) ok "토큰 미유출";; esac

echo "== --print-upstream: 미지원 입력은 보류 =="
for bad in \
  'http://github.com/O/R' \
  'ftp://github.com/O/R' \
  'git://github.com/O/R' \
  'not-a-url' \
  '' \
  'https://github.com/OnlyOne' \
  'https://github.com/a/b/c' \
  'https://github.com/O/R?tab=readme' \
  'https://github.com/O/R#frag' \
  'https://github.com/O /R'
do
  out="$(PU "$bad")"; rc=$?
  if [[ -z "$out" && "$rc" -ne 0 ]]; then ok "미지원 보류: '${bad:-<빈값>}'"
  else nok "미지원 보류: '${bad:-<빈값>}' (출력='$out' rc=$rc)"; fi
done

echo "== --print-upstream: 부작용 없음 (격리 디렉토리 내용 fingerprint 비교) =="
ISO="$(mktemp -d)"; ( cd "$ISO" && mkdir -p sub && echo seed > sub/seed.txt )
# 크기만 비교하면 같은 길이로 내용이 바뀌는 부작용을 놓친다 (Turn 006 Finding 3).
# cksum 은 macOS/Linux 공통이며 파일명 없이 "체크섬 크기" 를 낸다.
snap() { (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do
           printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
before="$(snap "$ISO")"
( cd "$ISO" && PU 'https://github.com/O/R.git' >/dev/null )
after="$(snap "$ISO")"
check "작업 디렉토리 불변 (목록+내용)" "$after" "$before"

# 검사 자체가 변화를 잡는지 확인한다 — 같은 크기로 내용만 바꿔 본다.
printf 'SEED\n' > "$ISO/sub/seed.txt"
[[ "$(snap "$ISO")" != "$before" ]] && ok "fingerprint 가 동일 크기 변경을 잡음" \
                                    || nok "fingerprint 가 동일 크기 변경을 놓침"
rm -rf "$ISO"

# =============================================================================
# M008 hook 경로 표기 정규화 (AC 7 / spec §8)
# =============================================================================
# `MIGRATIONS.md` 의 스니펫을 **문서에서 추출해** 그대로 실행합니다. 스니펫을 테스트에
# 복사해 두면 문서와 테스트가 갈라져도 초록이 나오므로, 문서가 유일한 진실이어야 합니다.
#
# 이 파일에 두는 이유: 새 테스트 파일을 만들면 `self_test.sh` 의 `run_step` 등록이 하나 늘어
# self_test 스텝 집계와 청중 exact 집합 단언을 흔듭니다. 이 스텝은 이미 sync·마이그레이션 도구를
# 담당하는 `consumer` 스텝입니다.
echo "-- M008 hook 표기 정규화 --"
M8_DIR="$WORK/m008"; mkdir -p "$M8_DIR"
M8_MD="${SCRIPT_DIR}/../MIGRATIONS.md"
M8_SNIP="$M8_DIR/m008_snippet_zzfx.py"
if [[ ! -f "$M8_MD" ]]; then
  ok "MIGRATIONS.md 없음 — M008 검증 건너뜀 (lite 산출물)"
else
  python3 - "$M8_MD" "$M8_SNIP" <<'M8EXTRACT'
import sys
md, out = sys.argv[1], sys.argv[2]
# 줄 기반으로 추출합니다 — 정규식에 백슬래시 이스케이프를 쓰면 이 파일을 생성·편집하는
# 경로마다 해석이 한 겹씩 달라져 조용히 깨집니다 (구현 중 실제로 겪었습니다).
lines = open(md).read().split(chr(10))
begin = None
for i, l in enumerate(lines):
    if l.strip() == "python3 - <<'PY'":
        begin = i + 1
        break
if begin is None:
    sys.stderr.write('M008 스니펫 시작 줄을 찾지 못했습니다' + chr(10)); sys.exit(1)
buf = []
for l in lines[begin:]:
    if l.strip() == 'PY':
        break
    buf.append(l[3:] if l.startswith('   ') else l)
else:
    sys.stderr.write('M008 스니펫 종료 줄을 찾지 못했습니다' + chr(10)); sys.exit(1)
code = chr(10).join(buf)
compile(code, 'm008', 'exec')          # 문서에 든 코드가 컴파일되는지부터 확인
open(out, 'w').write(code)
M8EXTRACT
  if [[ -s "$M8_SNIP" ]]; then ok "MIGRATIONS.md 에서 M008 스니펫 추출·컴파일"; else nok "M008 스니펫 추출 실패"; fi
fi

if [[ -s "${M8_SNIP:-}" ]]; then
  OLDP='bash rd-workflow/scripts/hooks/'
  NEWP='bash "${CLAUDE_PROJECT_DIR:-.}"/rd-workflow/scripts/hooks/'
  m8_mk() { mkdir -p "$M8_DIR/$1/.claude"; cat > "$M8_DIR/$1/.claude/settings.json"; }
  m8_run() { ( cd "$M8_DIR/$1" && python3 "$M8_SNIP" ) ; }
  m8_count() { grep -c -- "$2" "$M8_DIR/$1/.claude/settings.json" 2>/dev/null || true; }
  m8_items() { python3 -c "
import json,sys
h=json.load(open(sys.argv[1]))['hooks']
print(sum(len(g.get('hooks',[])) for gs in h.values() for g in gs))" "$M8_DIR/$1/.claude/settings.json"; }

  # F1 — 구 표기만 → 신 표기로, 건수 불변
  m8_mk F1 <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/session_start.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]},{"matcher":"Write","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]}]}}
J
  m8_run F1 >/dev/null 2>&1 && rc=0 || rc=1
  check "F1 rc" "$rc" "0"
  check "F1 구 표기 잔존 0" "$(m8_count F1 '"command": "bash rd-workflow/')" "0"
  check "F1 항목 수 불변 (4)" "$(m8_items F1)" "4"
  # 정상 템플릿 구성(Edit·Write 에 같은 스크립트)은 중복이 아니므로 알림이 나오면 안 됩니다.
  if m8_run F1 2>&1 | grep -qF "알림"; then nok "F1 재실행에서 오탐 알림"; else ok "F1 정상 구성에 오탐 알림 없음"; fi

  # F2 — 신 표기만 → 무변경, **파일 재작성 없음**(mtime 불변)
  m8_mk F2 <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/session_start.sh"}]}]}}
J
  m8_before="$(shasum -a 256 < "$M8_DIR/F2/.claude/settings.json")"
  m8_run F2 >/dev/null 2>&1 && rc=0 || rc=1
  check "F2 rc" "$rc" "0"
  check "F2 내용 무변경 (멱등)" "$(shasum -a 256 < "$M8_DIR/F2/.claude/settings.json")" "$m8_before"

  # F3 — 구+신 동시(이미 중복) → 하나로 접힘
  m8_mk F3 <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"},{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/implementation_gate.sh"}]}]}}
J
  m8_run F3 >/dev/null 2>&1
  check "F3 중복이 하나로 접힘" "$(m8_items F3)" "1"

  # F4 — 부가 필드가 다른 동일 triple → first-wins (처음 항목 전체가 살아남음)
  m8_mk F4 <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh","timeout":11},{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/implementation_gate.sh","timeout":22}]}]}}
J
  m8_run F4 >/dev/null 2>&1
  check "F4 first-wins: 처음 항목의 timeout 생존" \
    "$(python3 -c "import json;print(json.load(open('$M8_DIR/F4/.claude/settings.json'))['hooks']['PreToolUse'][0]['hooks'][0].get('timeout'))")" "11"

  # F5 — 프로젝트 고유 hook 은 내용·순서 모두 보존
  m8_mk F5 <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash scripts/my_own_zzfx.sh"},{"type":"command","command":"bash rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"}]}]}}
J
  m8_run F5 >/dev/null 2>&1
  check "F5 고유 hook 이 첫 자리에 그대로" \
    "$(python3 -c "import json;print(json.load(open('$M8_DIR/F5/.claude/settings.json'))['hooks']['PreToolUse'][0]['hooks'][0]['command'])")" \
    "bash scripts/my_own_zzfx.sh"
  check "F5 항목 수 불변 (2)" "$(m8_items F5)" "2"

  # F5b — **`command` 가 없는 프로젝트 고유 item 이 보존돼야 합니다.**
  # 이 item 들은 모두 key=null 로 접혀 같은 group 의 두 번째부터 조용히 삭제됐습니다
  # (final diff review Turn 002 Finding 1 — 사용자 hook 이 사라지는 데이터 손실).
  m8_mk F5b <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"},{"type":"prompt","prompt":"A"},{"type":"agent","prompt":"B"}]}]}}
J
  m8_run F5b >/dev/null 2>&1 && rc=0 || rc=1
  check "F5b rc" "$rc" "0"
  check "F5b 항목 수 보존 (3)" "$(m8_items F5b)" "3"
  check "F5b 비-command item 이 순서·내용 그대로" \
    "$(python3 -c "
import json
h=json.load(open('$M8_DIR/F5b/.claude/settings.json'))['hooks']['PreToolUse'][0]['hooks']
print('|'.join('%s:%s' % (i.get('type'), i.get('prompt','-')) for i in h[1:]))")" \
    "prompt:A|agent:B"
  check "F5b command item 은 정규화됨" \
    "$(python3 -c "
import json
h=json.load(open('$M8_DIR/F5b/.claude/settings.json'))['hooks']['PreToolUse'][0]['hooks']
print('yes' if 'CLAUDE_PROJECT_DIR' in h[0]['command'] else 'no')")" "yes"
  # 비-command item 이 **여럿이어도** 하나도 사라지지 않아야 합니다 (key 충돌 회귀).
  m8_mk F5c <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"prompt","prompt":"A"},{"type":"prompt","prompt":"B"},{"type":"prompt","prompt":"C"}]}]}}
J
  m8_before="$(shasum -a 256 < "$M8_DIR/F5c/.claude/settings.json")"
  m8_run F5c >/dev/null 2>&1 && rc=0 || rc=1
  check "F5c rc" "$rc" "0"
  check "F5c 비-command item 3개 전부 보존" "$(m8_items F5c)" "3"
  check "F5c 무변경이므로 재작성 없음" "$(shasum -a 256 < "$M8_DIR/F5c/.claude/settings.json")" "$m8_before"

  # F6 — 빈 hooks / hooks 키 부재 → 무변경, rc=0
  m8_mk F6a <<'J'
{"hooks":{}}
J
  m8_run F6a >/dev/null 2>&1 && rc=0 || rc=1; check "F6a 빈 hooks rc" "$rc" "0"
  m8_mk F6b <<'J'
{"permissions":{"allow":[]}}
J
  m8_run F6b >/dev/null 2>&1 && rc=0 || rc=1; check "F6b hooks 키 부재 rc" "$rc" "0"

  # F7 — 유효 JSON 이지만 hooks 타입 이상 → **원본 불변 + 실패** (write-before-validate 방지)
  m8_mk F7 <<'J'
{"hooks":"oops"}
J
  m8_before="$(shasum -a 256 < "$M8_DIR/F7/.claude/settings.json")"
  m8_run F7 >/dev/null 2>&1 && rc=0 || rc=1
  check "F7 타입 이상 → 실패" "$rc" "1"
  check "F7 원본 byte 불변" "$(shasum -a 256 < "$M8_DIR/F7/.claude/settings.json")" "$m8_before"

  # F8 — 정상 변환 후 **쓰기·교체 실패 주입** → rc≠0 + 원본 불변 + 임시 파일 잔존 없음.
  # F7 과 다른 것을 봅니다: F7 은 "검증 전에 쓰지 않는가", F8 은 "쓰다 실패해도 원본이 남는가".
  m8_mk F8 <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/session_start.sh"}]}]}}
J
  m8_before="$(shasum -a 256 < "$M8_DIR/F8/.claude/settings.json")"
  chmod 500 "$M8_DIR/F8/.claude"
  m8_run F8 >/dev/null 2>&1 && rc=0 || rc=1
  check "F8 교체 실패 → rc≠0" "$rc" "1"
  check "F8 원본 byte 불변" "$(shasum -a 256 < "$M8_DIR/F8/.claude/settings.json")" "$m8_before"
  check "F8 임시 파일 잔존 없음" "$(ls -A "$M8_DIR/F8/.claude" | grep -c 'm008' || true)" "0"
  chmod 700 "$M8_DIR/F8/.claude"

  # 같은 matcher 에 group 이 여럿이면 접지 않고 **알림만** 냅니다 (group 경계 보존).
  m8_mk FG <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/implementation_gate.sh"}]}]}}
J
  if m8_run FG 2>&1 | grep -qF "알림"; then ok "같은 matcher 다중 group → 알림"; else nok "같은 matcher 다중 group 인데 알림이 없습니다"; fi
  check "같은 matcher 다중 group 은 접지 않음 (2건 유지)" "$(m8_items FG)" "2"

  # --- 종단: 정규화 → M003 --------------------------------------------------
  # 정규화 단독 결과만 보면 M003 이 뒤에서 다시 중복을 만드는지 알 수 없습니다.
  # 유일성 축은 command 가 아니라 **(event, matcher, command) triple** 입니다 — 템플릿은
  # `implementation_gate.sh` 를 Edit·Write 두 matcher 에 등록하므로 command 축으로 보면
  # 정상 구성이 중복으로 잡힙니다.
  M8_TPL="${SCRIPT_DIR}/../../.claude/settings.json"
  if [[ ! -f "$M8_TPL" ]]; then
    ok "템플릿 settings.json 없음 — 종단 검증 건너뜀 (설치본)"
  else
    cat > "$M8_DIR/m003_sim_zzfx.py" <<'M3SIM'
import json, sys
proj_p, tpl_p = ".claude/settings.json", sys.argv[1]
proj = json.load(open(proj_p)); tpl = json.load(open(tpl_p))
def triples(cfg):
    out = set()
    for ev, gs in (cfg.get("hooks") or {}).items():
        for g in gs:
            for it in g.get("hooks", []):
                out.add((ev, json.dumps(g.get("matcher")), it.get("command")))
    return out
have = triples(proj); added = 0
for ev, gs in (tpl.get("hooks") or {}).items():
    for g in gs:
        for it in g.get("hooks", []):
            key = (ev, json.dumps(g.get("matcher")), it.get("command"))
            if key in have: continue
            ph = proj.setdefault("hooks", {}).setdefault(ev, [])
            tgt = None
            for pg in ph:
                if json.dumps(pg.get("matcher")) == json.dumps(g.get("matcher")): tgt = pg; break
            if tgt is None:
                tgt = {k: v for k, v in g.items() if k != "hooks"}; tgt["hooks"] = []; ph.append(tgt)
            tgt.setdefault("hooks", []).append(dict(it)); added += 1
json.dump(proj, open(proj_p, "w"), ensure_ascii=False, indent=2)
print("added=%d" % added)
M3SIM
    m8_end() { # m8_end <케이스> — stdout: "<M003 추가건수> <템플릿hook수> <triple유일> <고유hook수>"
      local c="$1" added
      added="$( ( cd "$M8_DIR/$c" && python3 "$M8_DIR/m003_sim_zzfx.py" "$M8_TPL" ) | sed -n 's/^added=//p' )"
      python3 -c "
import json,collections,sys
h=json.load(open('$M8_DIR/$c/.claude/settings.json'))['hooks']
tri=[(ev,json.dumps(g.get('matcher')),it['command']) for ev,gs in h.items() for g in gs for it in g.get('hooks',[])]
tpl=[t for t in tri if 'rd-workflow/scripts/hooks/' in t[2]]
own=[t for t in tri if 'rd-workflow/scripts/hooks/' not in t[2]]
old=[t for t in tpl if t[2].startswith('bash rd-workflow/')]
uniq=all(v==1 for v in collections.Counter(tpl).values()) and not old
print('$added', len(tpl), 'yes' if uniq else 'no', len(own))"
    }
    m8_mk E1 <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/session_start.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]},{"matcher":"Write","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]}]}}
J
    m8_run E1 >/dev/null 2>&1
    check "종단 E1 (구 표기 4건): M003 추가 0 / hook 4 / triple 유일 / 고유 0" "$(m8_end E1)" "0 4 yes 0"

    m8_mk E2 <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/session_start.sh"},{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/session_start.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash scripts/my_own_zzfx.sh"},{"type":"command","command":"bash rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"},{"type":"command","command":"bash \"${CLAUDE_PROJECT_DIR:-.}\"/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]},{"matcher":"Write","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]}]}}
J
    m8_run E2 >/dev/null 2>&1
    check "종단 E2 (이미 중복 8건 + 고유 hook): M003 추가 0 / hook 4 / triple 유일 / 고유 1" "$(m8_end E2)" "0 4 yes 1"

    # **대조군 — 정규화를 건너뛰면 M003 이 실제로 중복을 만듭니다.** 이 케이스가 없으면
    # 위 두 단언이 "M003 은 원래 아무것도 안 한다" 와 구분되지 않습니다.
    m8_mk E3 <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/session_start.sh"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]},{"matcher":"Write","hooks":[{"type":"command","command":"bash rd-workflow/scripts/hooks/implementation_gate.sh"}]}]}}
J
    check "대조군 E3 (정규화 없이 M003): 추가 4 / hook 8 / triple 유일 아님" "$(m8_end E3)" "4 8 no 0"
  fi
fi

# --- M009: 보존 파일 정의 문구 마이그레이션 --------------------------------
# snippet 을 MIGRATIONS.md 에서 추출해 fixture 에 실제로 실행한다.
# 정적 문구 검사로 대체하지 않는다 (spec D1).
M9_DIR="$(mktemp -d)"
M9_MD="$SCRIPT_DIR/../MIGRATIONS.md"
M9_SNIP="$M9_DIR/m9_snippet_zzfx.py"

python3 - "$M9_MD" "$M9_SNIP" <<'M9EXTRACT'
import sys
md, out = sys.argv[1], sys.argv[2]
lines = open(md, encoding="utf-8").read().split("\n")
start = None
for i, l in enumerate(lines):
    if l.startswith("## M009"):
        start = i
        break
if start is None:
    sys.exit("M009 절을 찾지 못했습니다")
body, grab = [], False
for l in lines[start:]:
    s = l.strip()
    if s == "python3 - <<'PY'":
        grab = True
        continue
    if grab and s == "PY":
        break
    if grab:
        body.append(l[3:] if l.startswith("   ") else l)
if not body:
    sys.exit("M009 의 python3 heredoc 본문이 비어 있습니다")
open(out, "w", encoding="utf-8").write("\n".join(body) + "\n")
M9EXTRACT

# 구형 FUTURE_REQUESTS.md (blocked 없음, 인덱스 항목 1건)
m9_fixture() { # $1=케이스명
  local d="$M9_DIR/$1/rd-workflow-workspace/backlog"
  mkdir -p "$d"
  cat > "$d/FUTURE_REQUESTS.md" <<'FR'
# FUTURE_REQUESTS

## 상태 값

- `idea`: 아직 검증 안 됨
- `validated`: 필요성 확인, 우선순위 아님
- `ready-for-request`: REQUEST.md로 바로 올릴 수 있음
- `parked`: 검토 완료, 지금은 안 함
- `done` / `dropped`: 인덱스에서 삭제

## 파일 분리

- **이 파일**: 활성 항목(idea, validated, ready-for-request)
- **`FUTURE_REQUESTS_PARKED.md`**: 보류 항목 (parked)
- **`items/`**: 상세 파일

## 인덱스

| 날짜 | 제목 |
|------|------|
| 2026-01-01 | sample-item |
FR
}

m9_run() { ( cd "$M9_DIR/$1" && python3 "$M9_SNIP" ) ; }
m9_fr() { echo "$M9_DIR/$1/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md" ; }

echo "== M009: 정상 변환 =="
m9_fixture N1
m9_run N1 > "$M9_DIR/n1.out" 2>&1
check "N1 1회차 종료코드 0" "$?" "0"
check "N1 상태 값에 blocked" \
  "$(grep -c '^- `blocked`:' "$(m9_fr N1)")" "1"
check "N1 blocked 가 done 앞" \
  "$(awk '/^- `blocked`:/{b=NR} /^- `done`/{d=NR} END{print (b<d)?"yes":"no"}' "$(m9_fr N1)")" "yes"
check "N1 파일 분리에 canonical 행" \
  "$(grep -c '^- \*\*`blocked` 항목\*\*:' "$(m9_fr N1)")" "1"
check "N1 파일 분리 grep -A4 판정 통과 (test_fr_blocked_status 기준)" \
  "$(grep -A4 '## 파일 분리' "$(m9_fr N1)" | grep -c 'blocked')" "1"
check "N1 인덱스 행 보존" \
  "$(grep -c '^| 2026-01-01 | sample-item |' "$(m9_fr N1)")" "1"
check "N1 임시 파일 잔여 없음" \
  "$(find "$M9_DIR/N1/rd-workflow-workspace/backlog" -name '.FUTURE_REQUESTS.md.m009.*' | wc -l | tr -d ' ')" "0"

# 섹션에 "blocked" 를 언급하는 **메모만** 있고 정식 항목이 없는 경우 — 삽입해야 한다.
# substring 판정이면 여기서 건너뛰어 거짓 성공이 된다 (final diff review Turn 002 Finding 1).
m9_fixture N2
python3 - "$(m9_fr N2)" <<'M9N2'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("- `parked`: 검토 완료, 지금은 안 함",
              "- `parked`: 검토 완료, 지금은 안 함\n- (메모) blocked 는 아직 미지원")
s = s.replace("- **`items/`**: 상세 파일",
              "- **`items/`**: 상세 파일\n- (메모) blocked 관련 정리 필요")
open(p, "w", encoding="utf-8").write(s)
M9N2
m9_run N2 > "$M9_DIR/n2.out" 2>&1
check "N2 메모만 있어도 종료코드 0" "$?" "0"
check "N2 상태 값에 canonical 행 삽입" \
  "$(grep -c '^- `blocked`:' "$(m9_fr N2)")" "1"
check "N2 파일 분리에 canonical 행 삽입" \
  "$(grep -c '^- \*\*`blocked` 항목\*\*:' "$(m9_fr N2)")" "1"
check "N2 기존 메모 보존" \
  "$(grep -c '(메모) blocked 는 아직 미지원' "$(m9_fr N2)")" "1"

echo "== M009: 멱등 (2회차 무변경) =="
cp "$(m9_fr N1)" "$M9_DIR/n1.after1"
m9_run N1 > "$M9_DIR/n1.out2" 2>&1
check "N1 2회차 종료코드 0" "$?" "0"
check "N1 2회차 전체 diff 공백" \
  "$(diff "$M9_DIR/n1.after1" "$(m9_fr N1)" | wc -l | tr -d ' ')" "0"

echo "== M009: fail-safe =="
# 헤딩 부재 — sed -i 를 쓰지 않는다 (spec D9: 신규 코드에 BSD 비호환 구문 금지)
m9_fixture F1
python3 - "$(m9_fr F1)" <<'M9F1'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read().replace("## 파일 분리", "## 파일 분리 (프로젝트 변형)")
open(p, "w", encoding="utf-8").write(s)
M9F1
cp "$(m9_fr F1)" "$M9_DIR/f1.before"
m9_run F1 > "$M9_DIR/f1.out" 2>&1
check "F1 헤딩 부재 → 종료코드 1" "$?" "1"
check "F1 파일 무변경" \
  "$(diff "$M9_DIR/f1.before" "$(m9_fr F1)" | wc -l | tr -d ' ')" "0"
check "F1 원인 출력" "$(grep -c '헤딩이 0개' "$M9_DIR/f1.out")" "1"
check "F1 조치 출력" "$(grep -c '조치:' "$M9_DIR/f1.out")" "1"

# 헤딩 중복
m9_fixture F2
printf '\n## 상태 값\n\n- 중복 섹션\n' >> "$(m9_fr F2)"
cp "$(m9_fr F2)" "$M9_DIR/f2.before"
m9_run F2 > "$M9_DIR/f2.out" 2>&1
check "F2 헤딩 중복 → 종료코드 1" "$?" "1"
check "F2 파일 무변경" \
  "$(diff "$M9_DIR/f2.before" "$(m9_fr F2)" | wc -l | tr -d ' ')" "0"

# 대상 파일 부재 — 해당 없음으로 성공 종료
mkdir -p "$M9_DIR/F3"
( cd "$M9_DIR/F3" && python3 "$M9_SNIP" ) > "$M9_DIR/f3.out" 2>&1
check "F3 대상 파일 부재 → 종료코드 0" "$?" "0"
check "F3 해당 없음 출력" "$(grep -c '해당 없음' "$M9_DIR/f3.out")" "1"

rm -rf "$M9_DIR"

echo "--- acceptance_sync_once.sh: 임시 clone 폐기 가능 판정 (재귀 삭제 방어) ---"
# 그 스크립트는 `set -e` 없이 진단을 모아 내는 방식이라, `mktemp` 가 실패해 경로가 비거나
# 예상 밖 값이 와도 스스로 멈추지 않는다. 그대로 가면 `/proj`·`/remote` 에 파일을 만들고
# `$(dirname "$CLONE")` 을 재귀 삭제한다. 그 판정을 `--check-clone` 으로 직접 고정한다.
# (`mktemp` 실패 자체를 유도해 시험하지는 않는다 — macOS `mktemp` 는 TMPDIR 이 없어도
#  `/var/folders/...` 로 폴백해 실패하지 않으므로 플랫폼마다 결과가 갈린다.)
ACC_SH="${SCRIPT_DIR}/acceptance_sync_once.sh"
if [[ -f "$ACC_SH" ]]; then
  acc_guard() { bash "$ACC_SH" --check-clone "$1" >/dev/null 2>&1 && echo ok || echo reject; }

  ACC_OK="$WORK/acc_ok"
  mkdir -p "$ACC_OK/tmp.zzfx/template"
  check "정상: tmp.*/template → 수용" "$(acc_guard "$ACC_OK/tmp.zzfx/template")" "ok"

  check "빈 경로 → 거부" "$(acc_guard "")" "reject"
  check "루트 → 거부" "$(acc_guard "/")" "reject"
  check "홈 디렉터리 → 거부" "$(acc_guard "$HOME")" "reject"

  mkdir -p "$WORK/acc_noname/tmp.zzfx/other"
  check "이름이 template 이 아님 → 거부" "$(acc_guard "$WORK/acc_noname/tmp.zzfx/other")" "reject"

  mkdir -p "$WORK/acc_noparent/notmp/template"
  check "부모가 mktemp 산출물이 아님 → 거부" \
    "$(acc_guard "$WORK/acc_noparent/notmp/template")" "reject"

  # 부모에 다른 항목이 있으면 남의 디렉터리일 수 있다 — 재귀 삭제 대상으로 삼지 않는다
  touch "$ACC_OK/tmp.zzfx/stranger"
  check "부모에 다른 항목 존재 → 거부" "$(acc_guard "$ACC_OK/tmp.zzfx/template")" "reject"

  check "존재하지 않는 경로 → 거부" "$(acc_guard "$WORK/acc_absent/tmp.zzfx/template")" "reject"
else
  echo "  skip  acceptance_sync_once.sh 없음"
fi

if [[ "$FAIL" == "0" ]]; then
  echo "test_sync_template: 전체 통과"
else
  echo "test_sync_template: 실패 있음" >&2
  exit 1
fi
