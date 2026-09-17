#!/usr/bin/env bash
# test_review_base_resolution.sh — diff review base 판정(§5.2·§5.2.1)과 종결 마커 seal
# 계약(§3.2·§3.2.1·§3.4)을 임시 저장소 fixture 로 검증합니다 (change-spec §6 의 10·11번).
#
# 이 파일이 막는 실수:
#   - base 판정이 무너져 **빈 diff 가 리뷰 대상으로 조용히 기록**되는 것 (원 결함)
#   - 위치 인자가 §5.2 의 안전 규칙을 우회하는 것
#   - **리뷰 종결 후 변경분이 `verified=yes` 로 봉인**되는 것
#   - **정상 다회차 리뷰가 최초 OID 에 묶여 봉인 불가능**해지는 것
#   - 재리뷰 후 stale seal 이 길을 막거나, 실패한 seal 이 기존 마커를 지우는 것
#   - head 재snapshot 이 SESSION 을 반쯤 고친 채 reviewer 를 dispatch 하는 것
#
# 제약: bash 3.2 호환 (연관배열·mapfile·globstar·extglob 금지).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fixture 에 통째로 복사할 rd-workflow 원본. canonical(_ROOT_FILES/rd-workflow/) 과
# mirror(rd-workflow/) 어느 쪽에서 실행해도 자기 옆의 배포 트리를 씁니다.
RD_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 전역·시스템 git 설정 간섭 차단 (test_integration.sh 와 같은 이유).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
eq()   { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대=[$2] 실제=[$1])"; fi; }
ne()   { if [ "$1" != "$2" ]; then pass "$3"; else fail "$3 (달라야 하는데 같음=[$1])"; fi; }
has()  { case "$2" in *"$1"*) pass "$3" ;; *) fail "$3 (문구 없음: ${1})" ;; esac; }

WORK="$(mktemp -d)" || { echo "test_review_base_resolution.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "test_review_base_resolution.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
WORK="$(cd "$WORK" && pwd -P)"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# mock 산출물은 **저장소 밖**에 남깁니다. 저장소 안에 남기면 그 파일이 보호 경로가 되어
# 다음 커밋마다 보호 트리 해시가 바뀌고, seal 검사가 테스트 자신의 부산물 때문에 실패합니다.
OUT="${WORK}/out"
mkdir -p "$OUT"

TOOLS_JSON="${OUT}/review-tools.json"
printf '{"default_priority":["codex"],"tools":{"codex":{"bin":"bash"}}}' > "$TOOLS_JSON"

SESS_REL="rd-workflow-workspace/handoffs/review_pipeline"

# ---------------------------------------------------------------------------
# fixture 헬퍼
# ---------------------------------------------------------------------------

# mk_repo [--sha256] [branch] — 임시 git 저장소를 만들고 경로를 출력합니다.
# 실패(sha256 미지원 등)하면 nonzero 이고 아무것도 출력하지 않습니다.
mk_repo() {
  local fmt="" br="main" d
  if [ "${1:-}" = "--sha256" ]; then fmt="--object-format=sha256"; shift; fi
  [ -n "${1:-}" ] && br="$1"
  d="$(mktemp -d "${WORK}/repo.XXXXXX")" || { echo "test_review_base_resolution.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$d" && -d "$d" ]] || { echo "test_review_base_resolution.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  d="$(cd "$d" && pwd -P)"
  if ! git init -q $fmt -b "$br" "$d" 2>/dev/null; then
    # git 2.28 미만은 `-b` 를 모릅니다. object-format 자체가 미지원이면 여기서도 실패합니다.
    git init -q $fmt "$d" 2>/dev/null || return 1
    git -C "$d" checkout -q -b "$br" 2>/dev/null || return 1
  fi
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name test
  # 실행에 필요한 스크립트만 복사합니다 (test_integration.sh 와 같은 관례). 배포 트리를
  # 통째로 복사하면 커밋·`ls-tree` 대상이 160여 파일로 불어나 보호 트리 해시 계산이
  # 케이스마다 수 초씩 늘어납니다 — 판정에 쓰이지 않는 문서를 fixture 에 넣지 않습니다.
  mkdir -p "${d}/rd-workflow/scripts/hooks" "${d}/rd-workflow/scripts/lifecycle" || return 1
  # VERSION 은 배포 시점에 찍히는 값이라 dev repo 의 루트 미러(`rd-workflow/`)에는 없습니다
  # (`build_template.sh` 가 `--version` 을 받을 때만 생성합니다). self_test 는 그 미러를
  # 실행하므로 부재를 실패로 다루면 안 됩니다. `rd-version` 은 §8 에서 경고 전용 필드라
  # 판정에 쓰이지 않으므로, 없으면 placeholder 를 넣어 fixture 를 성립시킵니다.
  if [[ -f "${RD_SRC}/VERSION" ]]; then
    cp "${RD_SRC}/VERSION" "${d}/rd-workflow/VERSION" || return 1
  else
    printf '%s\n' "0000-00-00-000000" > "${d}/rd-workflow/VERSION" || return 1
  fi
  cp "${RD_SRC}/scripts/prepare_review_pipeline.sh" \
     "${RD_SRC}/scripts/init_review_pipeline.sh" \
     "${RD_SRC}/scripts/run_review_turn.sh" \
     "${RD_SRC}/scripts/review_common.sh" \
     "${RD_SRC}/scripts/_state_common.sh" \
     "${RD_SRC}/scripts/_task_common.sh" \
     "${RD_SRC}/scripts/rd" \
     "${d}/rd-workflow/scripts/" || return 1
  cp "${RD_SRC}/scripts/hooks/_guard_common.sh" "${d}/rd-workflow/scripts/hooks/" || return 1
  cp "${RD_SRC}/scripts/lifecycle/_lifecycle_common.sh" \
     "${RD_SRC}/scripts/lifecycle/slug.sh" \
     "${d}/rd-workflow/scripts/lifecycle/" || return 1
  # 어댑터를 mock 으로 교체합니다. 실제 리뷰 도구를 부르지 않으면서 「어댑터가 호출됐는가」
  # 를 관찰할 수 있어야 원자성 케이스(⑥c)의 "어댑터 미호출" 을 확인할 수 있습니다.
  cat > "${d}/rd-workflow/scripts/adapter_codex.sh" <<'ADAPTER'
#!/usr/bin/env bash
# 테스트용 mock reviewer. 산출물은 전부 저장소 밖(RD_TEST_OUT)에 남깁니다.
: > "${RD_TEST_OUT}/adapter-called"
cp "$PROMPT_FILE" "${RD_TEST_OUT}/last-prompt.txt" 2>/dev/null || true
printf '# Turn — Reviewer\n이의 없음\n' > "$EXPECTED_TURN_FILE"
sed -i.bak -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' \
  "${SESSION_PATH}/SESSION.md" && rm -f "${SESSION_PATH}/SESSION.md.bak"
exit 0
ADAPTER
  mkdir -p "${d}/rd-workflow-workspace/.lifecycle" "${d}/${SESS_REL}"
  : > "${d}/rd-workflow-workspace/.gitkeep"
  printf '# Current Task\n\n## Short Title\ndemo\n\n## Status\n구현 중\n' > "${d}/CURRENT_TASK.md"
  printf '# Change Request\n\n## Source FR\n-\n' > "${d}/REQUEST.md"
  cat > "${d}/rd-workflow-workspace/.lifecycle/task-state" <<'STATE'
schema=1
short-title=demo
status=구현 중
fr-branch=null
worktree-path=null
source-fr=-
STATE
  printf 'seed\n' > "${d}/code.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m "base"
  printf '%s\n' "$d"
}

# commit_code <repo> <내용> — 보호 경로(code.txt)를 바꾸는 커밋 1개
commit_code() {
  printf '%s\n' "$2" >> "${1}/code.txt"
  git -C "$1" commit -q -am "code: $2"
}

state_set() { # state_set <repo> <key> <value>
  local f="${1}/rd-workflow-workspace/.lifecycle/task-state"
  awk -F'=' -v k="$2" -v v="$3" '
    $1 == k { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$f" > "${f}.tmp"
  cat "${f}.tmp" > "$f"
  rm -f "${f}.tmp"
}

prep() { # prep <repo> [args...] — prepare diff 실행. 출력은 $OUT/prep.{out,err}
  ( cd "$1" && shift && bash rd-workflow/scripts/prepare_review_pipeline.sh diff "$@" ) \
    >"${OUT}/prep.out" 2>"${OUT}/prep.err"
}

session_count() { ls "${1}/${SESS_REL}" 2>/dev/null | wc -l | tr -d ' '; }
session_dir()   { printf '%s/%s/%s\n' "$1" "$SESS_REL" "$(ls "${1}/${SESS_REL}" | head -1)"; }

bc_field() { # bc_field <session-dir> <key> — SESSION.md '## Branch Context' 의 `- key: value`
  awk -v k="- ${2}:" '
    $0 == "## Branch Context" { f = 1; next }
    f && /^## / { exit }
    f && index($0, k) == 1 { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' "${1}/SESSION.md"
}

set_bc_field() { # set_bc_field <session-dir> <key> <value> — Branch Context 의 한 필드만 고쳐 씁니다.
  # 「명시 ref 삭제 후 객체 정리·저장소 교체·SESSION 의 부분 수정」으로 기록 OID 가 현실과
  # 어긋난 세션을 만드는 데 씁니다 (⑨).
  awk -v k="- ${2}:" -v v="$3" '
    $0 == "## Branch Context" { bc = 1; print; next }
    bc && /^## / { bc = 0 }
    bc && index($0, k) == 1 { print k " " v; next }
    { print }' "${1}/SESSION.md" > "${1}/.session.tmp"
  cat "${1}/.session.tmp" > "${1}/SESSION.md"
  rm -f "${1}/.session.tmp"
}

del_bc_field() { # del_bc_field <session-dir> <key> — Branch Context 의 한 줄을 지웁니다 (⑨).
  awk -v k="- ${2}:" '
    $0 == "## Branch Context" { bc = 1; print; next }
    bc && /^## / { bc = 0 }
    bc && index($0, k) == 1 { next }
    { print }' "${1}/SESSION.md" > "${1}/.session.tmp"
  cat "${1}/.session.tmp" > "${1}/SESSION.md"
  rm -f "${1}/.session.tmp"
}

set_target() { # set_target <session-dir> <값> — Review Target 섹션 본문만 바꿉니다 (⑨).
  awk -v v="$2" '
    $0 == "## Review Target" { print; print ""; print v; skip = 1; next }
    skip && /^## / { skip = 0 }
    skip { next }
    { print }' "${1}/SESSION.md" > "${1}/.session.tmp"
  cat "${1}/.session.tmp" > "${1}/SESSION.md"
  rm -f "${1}/.session.tmp"
}

session_section() { # session_section <session-dir> <헤더>
  awk -v t="## ${2}" '
    $0 == t { f = 1; next }
    f && /^## / { exit }
    f && NF { print; exit }' "${1}/SESSION.md"
}

set_session_state() { # set_session_state <session-dir> <status> <owner>
  awk -v st="$2" -v ow="$3" '
    sec == "s" && NF { print st; sec = ""; next }
    sec == "o" && NF { print ow; sec = ""; next }
    { if ($0 == "## Status") sec = "s"; else if ($0 == "## Current Owner") sec = "o"; print }
  ' "${1}/SESSION.md" > "${1}/.session.tmp"
  cat "${1}/.session.tmp" > "${1}/SESSION.md"
  rm -f "${1}/.session.tmp"
}

close_session() { # close_session <session-dir> — 종결(Status=closed + Open Issues 없음)
  set_session_state "$1" "closed" "Author"
  printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' \
    > "${1}/CHECKPOINT.md"
}

next_turn_index() { # next_turn_index <session-dir> — 다음 턴 번호를 3자리로
  local n
  n="$(ls "${1}/turns" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%03d\n' "$(( n + 1 ))"
}

reviewer_turn() { # reviewer_turn <repo> <session-dir> [PATH prepend] — author 턴 + reviewer 턴
  local repo="$1" sess="$2" prepend="${3:-}" idx
  idx="$(next_turn_index "$sess")"
  printf '# Turn %s — Author\n반영했습니다.\n' "$idx" > "${sess}/turns/${idx}_author.md"
  set_session_state "$sess" "awaiting-reviewer" "Reviewer"
  # 실행 직전 SESSION 사본 — 실패 경로의 "SESSION 무변화" 를 byte 단위로 확인하는 기준입니다.
  cp "${sess}/SESSION.md" "${OUT}/session-prerun.md"
  rm -f "${OUT}/adapter-called"
  ( cd "$repo" && RD_TEST_OUT="$OUT" REVIEW_TOOLS_CONFIG="$TOOLS_JSON" \
      PATH="${prepend:+${prepend}:}${PATH}" \
      bash rd-workflow/scripts/run_review_turn.sh "${sess#${repo}/}" ) \
    >"${OUT}/turn.out" 2>"${OUT}/turn.err"
}

seal() { # seal <repo> [args...] — rd review seal 실행. 출력은 $OUT/seal.{out,err}
  local repo="$1"; shift
  ( cd "$repo" && bash rd-workflow/scripts/rd review seal "$@" ) \
    >"${OUT}/seal.out" 2>"${OUT}/seal.err"
}

precheck() { # precheck <repo> — archive.sh 가 발행 직전에 부르는 그 함수를 그대로 호출
  bash -c '
    project_root="$1"; export project_root
    source "${project_root}/rd-workflow/scripts/hooks/_guard_common.sh"
    archive_review_precheck 0 "" demo "$2/audit-precheck.log"
  ' _ "$1" "$OUT" >"${OUT}/precheck.out" 2>"${OUT}/precheck.err"
}

marker_path() { printf '%s/rd-workflow-workspace/.lifecycle/review-seals/%s.seal\n' "$1" "$2"; }
seal_field()  { awk -F'=' -v k="$2" '$1==k{sub(/^[^=]+=/,"");print;exit}' "$1"; }
file_inode()  { ls -i "$1" 2>/dev/null | awk '{print $1}'; }

echo "=== 10. diff review base 판정 (§5.2 / §5.2.1) ==="

# --- 우선순위 1: --base <ref> ---
R1="$(mk_repo)" || { echo "  FAIL  fixture 생성 실패"; exit 1; }
commit_code "$R1" one
C0="$(git -C "$R1" rev-parse HEAD~1)"
C1="$(git -C "$R1" rev-parse HEAD)"
# ref 로 넘겨도 **저장 시점에 OID 로 resolve** 되어야 합니다 — 이동 ref 를 문자열로 남기면
# 세션 생성과 실제 리뷰 사이에 기준이 바뀝니다 (§5.2).
prep "$R1" --base main~1; rc=$?
eq "$rc" "0" "우선순위 1(--base): 성공"
eq "$(session_count "$R1")" "1" "우선순위 1: 세션 1개 생성"
S1="$(session_dir "$R1")"
eq "$(bc_field "$S1" review-base-oid)" "$C0" "우선순위 1: ref 입력이 full OID 로 resolve 되어 기록됨"
eq "$(bc_field "$S1" review-head-oid)" "$C1" "우선순위 1: head 가 현재 HEAD OID"
eq "$(session_section "$S1" "Review Target")" "git diff ${C0}..${C1}" \
  "우선순위 1: Review Target 양끝이 고정 OID"
eq "$(awk -F'=' '$1=="review-session"{print $2}' "${R1}/rd-workflow-workspace/.lifecycle/task-state")" \
  "$(basename "$S1")" "우선순위 1: task-state review-session 포인터 기록"

# --- 우선순위 2: task-state fr-branch → merge-base ---
# main 을 fr 분기점보다 앞으로 전진시켜, base 가 **merge-base 이지 fr-branch·main tip 이 아님**을
# 구분할 수 있게 만듭니다. 두 점 오해석(main tip)은 조상 검사에 걸려 실패로 드러납니다.
R2="$(mk_repo)" || { echo "  FAIL  우선순위 2: fixture 생성 실패"; exit 1; }
FORK="$(git -C "$R2" rev-parse HEAD)"
git -C "$R2" checkout -q -b fr/demo
commit_code "$R2" fr-work
FRTIP="$(git -C "$R2" rev-parse HEAD)"
git -C "$R2" checkout -q main
commit_code "$R2" main-advance
MAINTIP="$(git -C "$R2" rev-parse HEAD)"
git -C "$R2" checkout -q fr/demo
state_set "$R2" fr-branch "fr/demo"
prep "$R2"; rc=$?
eq "$rc" "0" "우선순위 2(fr-branch): 성공"
S2="$(session_dir "$R2")"
eq "$(bc_field "$S2" review-base-oid)" "$FORK" "우선순위 2: base 는 merge-base(기본 브랜치, fr tip)"
ne "$(bc_field "$S2" review-base-oid)" "$MAINTIP" "우선순위 2: base 가 기본 브랜치 tip 이 아님"
eq "$(bc_field "$S2" review-head-oid)" "$FRTIP" "우선순위 2: head 는 현재 HEAD"

# --- 우선순위 3: task-state base-commit (set-base 는 ref 를 OID 로 저장) ---
R3="$(mk_repo)" || { echo "  FAIL  우선순위 3: fixture 생성 실패"; exit 1; }
commit_code "$R3" one
commit_code "$R3" two
( cd "$R3" && bash rd-workflow/scripts/rd task set-base HEAD~1 ) >/dev/null 2>&1
eq "$(awk -F'=' '$1=="base-commit"{print $2}' "${R3}/rd-workflow-workspace/.lifecycle/task-state")" \
  "$(git -C "$R3" rev-parse HEAD~1)" "우선순위 3: set-base 가 ref 를 OID 로 저장 (§5.3)"
prep "$R3"; rc=$?
eq "$rc" "0" "우선순위 3(base-commit): 성공"
S3="$(session_dir "$R3")"
eq "$(bc_field "$S3" review-base-oid)" "$(git -C "$R3" rev-parse HEAD~1)" "우선순위 3: 저장된 OID 를 base 로 사용"
eq "$(bc_field "$S3" review-head-oid)" "$(git -C "$R3" rev-parse HEAD)" "우선순위 3: head 는 현재 HEAD"

# --- 우선순위 4 + 실패 5종: 전부 exit 1 이고 세션이 만들어지지 않습니다 ---
# 하나의 저장소에서 연달아 시험합니다 — 어느 경로도 세션을 남기지 않는 것이 계약이므로
# 세션 개수 0 이 그대로 유지되는지가 곧 "세션 미생성" 의 증거입니다.
RF="$(mk_repo)" || { echo "  FAIL  우선순위 4 + 실패 5종: fixture 생성 실패"; exit 1; }
commit_code "$RF" one
FBLOB="$(git -C "$RF" rev-parse HEAD:code.txt)"
git -C "$RF" branch -q other main~1
( cd "$RF" && git checkout -q other && printf 'side\n' >> code.txt && git commit -q -am side && git checkout -q main ) >/dev/null 2>&1
OTHER="$(git -C "$RF" rev-parse other)"

fail_case() { # fail_case <설명> <기대 문구> [prepare 인자...]
  local desc="$1" needle="$2"; shift 2
  prep "$RF" "$@"; local frc=$?
  eq "$frc" "1" "실패: ${desc} — exit 1"
  eq "$(session_count "$RF")" "0" "실패: ${desc} — 세션 미생성"
  has "$needle" "$(cat "${OUT}/prep.err")" "실패: ${desc} — 사유 안내"
}

fail_case "입력 없음(우선순위 4)" "base 판정 입력이 없습니다"
fail_case "--base ref 부재" "존재하지 않거나 커밋이 아닙니다" --base no-such-ref
fail_case "--base 가 커밋이 아님(blob)" "존재하지 않거나 커밋이 아닙니다" --base "$FBLOB"
fail_case "base 가 HEAD 의 조상이 아님(모순)" "조상이 아닙니다" --base "$OTHER"
# 구현이 추가한 검사입니다 (T3) — AC 4 의 "빈 diff 가 기록되는 경로 없음" 을 문자 그대로
# 지키기 위해 base == head 를 실패로 둡니다. 빈 diff 를 리뷰 대상으로 남기지 않는 것이 요지입니다.
fail_case "base 와 HEAD 가 같은 커밋(빈 diff)" "리뷰할 변경이 없습니다" --base HEAD
state_set "$RF" fr-branch "fr/gone"
fail_case "fr-branch 가 stale·삭제됨" "삭제되었거나 stale"
state_set "$RF" fr-branch "null"
# --base 와 위치 인자 동시 입력 (§5.2.1)
fail_case "--base 와 위치 인자 동시 입력" "동시에 지정할 수 없습니다" --base main "git diff a..b"

# merge-base 계산 실패 — 공통 조상이 없는 계보(orphan branch)를 fr-branch 로 둡니다.
RF2="$(mk_repo)" || { echo "  FAIL  merge-base 계산 실패: fixture 생성 실패"; exit 1; }
( cd "$RF2" && git checkout -q --orphan fr/orphan && printf 'orphan\n' > code.txt \
    && git add -A && git commit -q -m orphan ) >/dev/null 2>&1
state_set "$RF2" fr-branch "fr/orphan"
prep "$RF2"; rc=$?
eq "$rc" "1" "실패: merge-base 계산 실패 — exit 1"
eq "$(session_count "$RF2")" "0" "실패: merge-base 계산 실패 — 세션 미생성"
has "merge-base 계산 실패" "$(cat "${OUT}/prep.err")" "실패: merge-base 계산 실패 — 사유 안내"

# --- 위치 인자 (§5.2.1) ---
# 두 점
RP1="$(mk_repo)" || { echo "  FAIL  위치 인자(두 점): fixture 생성 실패"; exit 1; }
commit_code "$RP1" one
P1B="$(git -C "$RP1" rev-parse HEAD~1)"
P1H="$(git -C "$RP1" rev-parse HEAD)"
prep "$RP1" "git diff ${P1B}..${P1H}"; rc=$?
eq "$rc" "0" "위치 인자(두 점): 성공"
SP1="$(session_dir "$RP1")"
eq "$(bc_field "$SP1" review-base-oid)" "$P1B" "위치 인자(두 점): 왼쪽이 base"
eq "$(bc_field "$SP1" review-head-oid)" "$P1H" "위치 인자(두 점): 오른쪽이 head"

# 세 점 — git 의 의미 그대로 merge-base 를 base 로 씁니다. 두 점으로 오해석하면
# base 가 전진한 main tip 이 되어 조상 검사에 걸리므로 이 케이스가 두 해석을 가릅니다.
RP2="$(mk_repo)" || { echo "  FAIL  위치 인자(세 점): fixture 생성 실패"; exit 1; }
P2FORK="$(git -C "$RP2" rev-parse HEAD)"
git -C "$RP2" checkout -q -b fr/pos
commit_code "$RP2" pos-work
P2HEAD="$(git -C "$RP2" rev-parse HEAD)"
git -C "$RP2" checkout -q main
commit_code "$RP2" main-advance
git -C "$RP2" checkout -q fr/pos
prep "$RP2" "git diff main...HEAD"; rc=$?
eq "$rc" "0" "위치 인자(세 점): 성공"
SP2="$(session_dir "$RP2")"
eq "$(bc_field "$SP2" review-base-oid)" "$P2FORK" "위치 인자(세 점): merge-base 로 해석"
eq "$(bc_field "$SP2" review-head-oid)" "$P2HEAD" "위치 인자(세 점): head 는 오른쪽 ref"

# 파싱 불가 — 세션은 만들되 두 OID 를 기록하지 않고, 봉인 경로를 미리 고지합니다.
RP3="$(mk_repo)" || { echo "  FAIL  위치 인자(파싱 불가): fixture 생성 실패"; exit 1; }
commit_code "$RP3" one
prep "$RP3" "git -C sub diff main...HEAD"; rc=$?
eq "$rc" "0" "위치 인자(파싱 불가): 세션은 생성됨 (하위호환)"
SP3="$(session_dir "$RP3")"
eq "$(bc_field "$SP3" review-base-oid)" "" "위치 인자(파싱 불가): review-base-oid 미기록"
eq "$(bc_field "$SP3" review-head-oid)" "" "위치 인자(파싱 불가): review-head-oid 미기록"
eq "$(session_section "$SP3" "Review Target")" "git -C sub diff main...HEAD" \
  "위치 인자(파싱 불가): 원문을 그대로 Review Target 으로 보존"
has "--legacy-unverified 가 필요합니다" "$(cat "${OUT}/prep.err")" \
  "위치 인자(파싱 불가): 봉인 경로를 고지"

# --- 위치 인자로 지정한 head 가 현재 HEAD 가 아닐 때 (Finding 2) ---
# 브랜치 A 를 checkout 한 채 `git diff <base>..branch-B` 를 넘기면, 세션의 target 은 branch-B
# 인데 첫 reviewer dispatch 직전에 A 의 HEAD 로 바뀌는 결함이 있었습니다. 사용자가 명시한
# 검토 대상과 reviewer 가 실제로 보는 대상이 갈리고, 내부 OID 와 프롬프트끼리는 일치하므로
# 오검토가 눈에 띄지 않습니다. 이 케이스가 그 표류를 잡습니다.
RB="$(mk_repo)" || { echo "  FAIL  target 표류 케이스: fixture 생성 실패"; exit 1; }
RBBASE="$(git -C "$RB" rev-parse HEAD)"
git -C "$RB" checkout -q -b branch-B
commit_code "$RB" b-work
BTIP="$(git -C "$RB" rev-parse HEAD)"
git -C "$RB" checkout -q main
commit_code "$RB" main-work
MTIP="$(git -C "$RB" rev-parse HEAD)"
state_set "$RB" base-commit "$RBBASE"
prep "$RB" "git diff ${RBBASE}..branch-B"; rc=$?
eq "$rc" "0" "pinned: 위치 인자 head(branch-B) 세션 생성 성공"
SB="$(session_dir "$RB")"
eq "$(bc_field "$SB" review-head-oid)" "$BTIP" "pinned: 생성 시 head 가 branch-B tip"
eq "$(bc_field "$SB" review-head-policy)" "pinned" "pinned: 정책 필드가 pinned 으로 기록"
has "iteration commit 은 리뷰 대상에 반영되지 않습니다" "$(cat "${OUT}/prep.err")" \
  "pinned: 성질을 사용자에게 고지"
reviewer_turn "$RB" "$SB"; rc=$?
eq "$rc" "0" "pinned: 첫 reviewer 턴 성공"
eq "$(bc_field "$SB" review-head-oid)" "$BTIP" "pinned: dispatch 후에도 head 가 branch-B (현재 HEAD 로 표류하지 않음)"
ne "$(bc_field "$SB" review-head-oid)" "$MTIP" "pinned: head 가 checkout 중인 브랜치 tip 이 아님"
eq "$(session_section "$SB" "Review Target")" "git diff ${RBBASE}..${BTIP}" \
  "pinned: Review Target 도 branch-B 로 유지"
has "git diff ${RBBASE}..${BTIP}" "$(cat "${OUT}/last-prompt.txt")" \
  "pinned: reviewer 에게 전달된 target 도 branch-B"
# 통제군의 나머지 절반 — 유효한 pinned 은 **턴이 실제로 진행**됩니다 (head·Review Target 이
# 그대로인 것은 위에서 확인했습니다). 이 줄이 없으면 "pinned 이면 무조건 실패" 로 구현해도
# 아래 ⑨ 의 실패 케이스가 전부 통과합니다.
if [ -f "${OUT}/adapter-called" ]; then pass "pinned 통제군: 유효한 pinned 은 어댑터가 호출됨"; else fail "pinned 통제군: 유효한 pinned 은 어댑터가 호출됨"; fi

# 통제군 — 오른쪽이 문자 그대로 `HEAD` 인 위치 인자는 "지금 작업 중인 것을 보라" 는 뜻이므로
# 기존 auto 동작을 유지합니다 (서브모듈 워크스페이스 프로젝트의 기존 사용). 이 케이스가 없으면
# "위치 인자를 전부 pinned 로 고정" 하는 과잉 구현이 위 케이스만으로 통과합니다.
RA="$(mk_repo)" || { echo "  FAIL  통제군(HEAD 위치 인자): fixture 생성 실패"; exit 1; }
RABASE="$(git -C "$RA" rev-parse HEAD)"
commit_code "$RA" a1
state_set "$RA" base-commit "$RABASE"
prep "$RA" "git diff ${RABASE}..HEAD"; rc=$?
eq "$rc" "0" "auto 통제군: 오른쪽이 HEAD 인 위치 인자 세션 생성"
SA="$(session_dir "$RA")"
eq "$(bc_field "$SA" review-head-policy)" "auto" "auto 통제군: 정책이 auto"
commit_code "$RA" a2
A2="$(git -C "$RA" rev-parse HEAD)"
reviewer_turn "$RA" "$SA"; rc=$?
eq "$rc" "0" "auto 통제군: reviewer 턴 성공"
eq "$(bc_field "$SA" review-head-oid)" "$A2" "auto 통제군: head 가 새 커밋으로 재snapshot"

# --- 동일 tree · 다른 OID (Finding 4) ---
# base 뒤에 변경 커밋과 완전 revert 커밋을 두면 OID 는 다르지만 트리가 같아 diff 가 비어
# 있습니다. "OID 가 서로 다름" 만 보는 구현은 이 빈 diff 를 리뷰 대상으로 기록합니다 (AC 4 위반).
RE="$(mk_repo)" || { echo "  FAIL  동일 tree·다른 OID: fixture 생성 실패"; exit 1; }
REBASE="$(git -C "$RE" rev-parse HEAD)"
commit_code "$RE" e1
git -C "$RE" revert --no-edit HEAD >/dev/null 2>&1
RETIP="$(git -C "$RE" rev-parse HEAD)"
ne "$RETIP" "$REBASE" "동일 tree: fixture 의 두 커밋 OID 가 실제로 다름"
eq "$(git -C "$RE" rev-parse "${RETIP}^{tree}")" "$(git -C "$RE" rev-parse "${REBASE}^{tree}")" \
  "동일 tree: fixture 의 두 커밋 tree 가 같음"
prep "$RE" --base "$REBASE"; rc=$?
eq "$rc" "1" "동일 tree: 세션 생성 차단 — exit 1"
eq "$(session_count "$RE")" "0" "동일 tree: 세션 미생성"
has "리뷰할 변경이 없습니다" "$(cat "${OUT}/prep.err")" "동일 tree: 사유 안내"

echo "=== 11. seal 4검사 · iteration · reseal · 원자성 · legacy (§3.2 / §3.2.1 / §3.4) ==="

# --- 본 시나리오 저장소: H1 에서 세션을 만들고 다회차 리뷰를 실제로 돕니다 ---
RS="$(mk_repo)" || { echo "  FAIL  seal 시나리오: fixture 생성 실패"; exit 1; }
BASE0="$(git -C "$RS" rev-parse HEAD)"
commit_code "$RS" h1
H1="$(git -C "$RS" rev-parse HEAD)"
state_set "$RS" base-commit "$BASE0"
prep "$RS"; rc=$?
eq "$rc" "0" "seal 시나리오: 세션 생성"
SS="$(session_dir "$RS")"
SID="$(basename "$SS")"
MARK="$(marker_path "$RS" "$SID")"

# 검사 1 — 미종결 세션은 봉인할 수 없습니다.
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "1" "검사 1: 미종결 세션 seal 실패"
has "종결되지 않았습니다" "$(cat "${OUT}/seal.err")" "검사 1: 사유 안내"

# ⑥(b) 성공 경로의 재snapshot 은 **rename** 이어야 합니다 — 검증 뒤 두 필드를 순차적으로
# in-place 수정하는 구현이라면 inode 가 그대로 남습니다.
INODE_BEFORE="$(file_inode "${SS}/SESSION.md")"
reviewer_turn "$RS" "$SS"; rc=$?
eq "$rc" "0" "reviewer 턴 1회차: 성공"
ne "$(file_inode "${SS}/SESSION.md")" "$INODE_BEFORE" \
  "⑥(b) 원자성: 성공 경로에서 SESSION 이 임시 파일 교체(inode 변경)로 갱신됨"

# ④ iteration — reviewer 지적 → author 의 H2 커밋 → 다음 reviewer 턴에서 head 만 갱신
commit_code "$RS" h2
H2="$(git -C "$RS" rev-parse HEAD)"
reviewer_turn "$RS" "$SS"; rc=$?
eq "$rc" "0" "④ iteration: H2 이후 reviewer 턴 성공"
eq "$(bc_field "$SS" review-head-oid)" "$H2" "④ iteration: review-head-oid 가 H2 로 갱신"
eq "$(bc_field "$SS" review-base-oid)" "$BASE0" "④ iteration: base 는 최초 값 그대로 (불변)"
has "git diff ${BASE0}..${H2}" "$(cat "${OUT}/last-prompt.txt")" \
  "④ iteration: 그 턴에 전달된 target 도 H2 (기록 OID 와 reviewer 가 읽는 diff 가 같음)"

# ④ iteration — 무이의 종결 후 seal 이 성공하고 verified=yes 가 됩니다.
close_session "$SS"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "0" "④ iteration: 다회차 리뷰 종결 후 seal 성공"
eq "$(seal_field "$MARK" verified)" "yes" "④ iteration: verified=yes"
eq "$(seal_field "$MARK" head)" "$H2" "④ iteration: 마커 head 가 H2"
eq "$(seal_field "$MARK" "branch-mode")" "no-fr" "④ iteration: branch-mode=no-fr (§3.2.2)"

# 재실행 no-op — 내용이 같으면 마커를 건드리지 않습니다 (별도 idempotency 케이스 대신 여기서 확인).
MARK_INODE="$(file_inode "$MARK")"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "0" "seal 재실행: 성공"
has "변경 없음" "$(cat "${OUT}/seal.out")" "seal 재실행: 내용이 같으면 no-op"
eq "$(file_inode "$MARK")" "$MARK_INODE" "seal 재실행: 마커 파일을 교체하지 않음"

# ③ review-head-oid 가 있는 세션은 무검증으로 낮출 수 없습니다.
seal "$RS" --legacy-unverified "그냥" "${SS#${RS}/}"; rc=$?
eq "$rc" "1" "③ 검증 가능한 세션에 --legacy-unverified → 실패"
has "검증이 가능합니다" "$(cat "${OUT}/seal.err")" "③ 사유 안내"

# 정상 경로: 마커와 task-state 를 커밋하면(둘 다 제외 경로) 보호 트리는 그대로이고 발행이 통과합니다.
git -C "$RS" add -A && git -C "$RS" commit -q -m "seal + 기록"
precheck "$RS"; rc=$?
eq "$rc" "0" "정상 경로: seal 커밋 후 archive precheck 통과"

# ① 리뷰 종결 → 보호 경로 코드 커밋(H3) → 일반 seal → 실패, 그리고 발행도 막힙니다.
cp "$MARK" "${OUT}/marker-before.seal"
commit_code "$RS" h3
H3="$(git -C "$RS" rev-parse HEAD)"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "1" "① 종결 후 보호 경로 변경 → seal 실패"
has "재리뷰가 필요합니다" "$(cat "${OUT}/seal.err")" "① 사유 안내"
cmp -s "$MARK" "${OUT}/marker-before.seal"; rc=$?
eq "$rc" "0" "⑤ 4검사 실패 시 기존 마커 보존 (실패가 마커를 지우지 않음)"
precheck "$RS"; rc=$?
eq "$rc" "1" "① 종결 후 보호 경로 변경 → precheck 실패"
has "리뷰 대상 불일치" "$(cat "${OUT}/precheck.err")" "① precheck 사유 안내"

# ⑤ reseal 복구 — H3 를 재리뷰해 종결하면 기존 마커를 교체하고 발행이 다시 열립니다.
set_session_state "$SS" "awaiting-author" "Author"
reviewer_turn "$RS" "$SS"; rc=$?
eq "$rc" "0" "⑤ reseal: H3 재리뷰 턴 성공"
eq "$(bc_field "$SS" review-head-oid)" "$H3" "⑤ reseal: head 가 H3 로 갱신"
close_session "$SS"
MARK_INODE="$(file_inode "$MARK")"
OLD_HASH="$(seal_field "$MARK" tree-hash)"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "0" "⑤ reseal: 재리뷰 종결 후 seal 성공"
ne "$(seal_field "$MARK" tree-hash)" "$OLD_HASH" "⑤ reseal: tree-hash 가 새 값으로 교체됨"
ne "$(file_inode "$MARK")" "$MARK_INODE" "⑤ reseal: 임시 파일 + mv 로 원자적 교체 (inode 변경)"
eq "$(seal_field "$MARK" head)" "$H3" "⑤ reseal: 마커 head 가 H3"
git -C "$RS" add -A && git -C "$RS" commit -q -m "reseal 기록"
precheck "$RS"; rc=$?
eq "$rc" "0" "⑤ reseal: 커밋 후 precheck 통과 (복구 완료)"

# ⑤-b seal 쪽 묶음 검증 (turn 006 Finding 1). 턴 경로만 막으면, 손상된 세션을 그대로
# 봉인하는 경로가 남습니다 — seal 은 종전에 `review-head-oid` 하나만 봤습니다.
cp "${SS}/SESSION.md" "${OUT}/seal-session-base.md"
# 저장소에 없는 OID — 각 16진 숫자를 뒤집어 길이·형식은 유지한 채 실재하지 않게 만듭니다.
PNGONE_SEAL="$(printf '%s' "$(bc_field "$SS" review-base-oid)" | tr '0123456789abcdef' 'fedcba9876543210')"
if git -C "$RS" cat-file -e "${PNGONE_SEAL}^{commit}" 2>/dev/null; then
  fail "⑤-b fixture: 존재하지 않는 base OID 가 실제로 저장소에 없음"
else
  pass "⑤-b fixture: 존재하지 않는 base OID 가 실제로 저장소에 없음"
fi
del_bc_field "$SS" review-base-oid
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "1" "⑤-b seal: reviewed OID 가 한쪽만 있으면 차단"
has "한쪽만 있습니다" "$(cat "${OUT}/seal.err")" "⑤-b seal: 한쪽만 있음 사유 안내"

cat "${OUT}/seal-session-base.md" > "${SS}/SESSION.md"
set_bc_field "$SS" review-head-oid "HEAD"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "1" "⑤-b seal: head 가 이동 ref 면 차단 (full OID 아님)"
has "review-head-oid" "$(cat "${OUT}/seal.err")" "⑤-b seal: head full OID 아님 사유 안내"

# base 도 head 와 대칭입니다 (turn 008). resolve 불가와 「resolve 는 되지만 full OID 가
# 아님」은 사용자가 할 일이 다르므로 나눠서 봅니다.
SEAL_MARK="$(marker_path "$RS" "$(basename "$SS")")"
cat "${OUT}/seal-session-base.md" > "${SS}/SESSION.md"
set_bc_field "$SS" review-base-oid "$PNGONE_SEAL"
rm -f "$SEAL_MARK"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "1" "⑤-b seal: base 를 해석할 수 없으면 차단"
has "를 commit 으로 해석할 수 없습니다" "$(cat "${OUT}/seal.err")" "⑤-b seal: base 해석 불가 사유 안내"
eq "$([[ -f "$SEAL_MARK" ]] && echo yes || echo no)" "no" "⑤-b seal: base 해석 불가면 마커 미생성"

cat "${OUT}/seal-session-base.md" > "${SS}/SESSION.md"
set_bc_field "$SS" review-base-oid "HEAD~1"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "1" "⑤-b seal: base 가 이동 표현이면 차단 (full OID 아님)"
has "review-base-oid" "$(cat "${OUT}/seal.err")" "⑤-b seal: base full OID 아님 사유 안내"
eq "$([[ -f "$SEAL_MARK" ]] && echo yes || echo no)" "no" "⑤-b seal: base 가 full OID 아니면 마커 미생성"

# 통제군 — 원본을 되돌리면 다시 봉인됩니다 (위 두 건이 "seal 이 그냥 다 막힌다" 가 아님).
cat "${OUT}/seal-session-base.md" > "${SS}/SESSION.md"
seal "$RS" "${SS#${RS}/}"; rc=$?
eq "$rc" "0" "⑤-b seal 통제군: 원본 세션은 다시 봉인 성공"

# ② review-head-oid 없는 세션(§5.2.1 파싱 불가) 은 일반 seal 로 봉인되지 않습니다.
SP3ID="$(basename "$SP3")"
close_session "$SP3"
seal "$RP3" "${SP3#${RP3}/}"; rc=$?
eq "$rc" "1" "② reviewed OID 없는 세션에 일반 seal → 실패"
has "--legacy-unverified 를 쓰십시오" "$(cat "${OUT}/seal.err")" "② 사유 안내 (legacy 경로 제시)"
eq "$(ls "${RP3}/rd-workflow-workspace/.lifecycle/review-seals" 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "② 실패한 seal 은 마커를 만들지 않음"

# legacy 전환 — 사유를 audit 에 남기고 verified=legacy-unverified 로 기록합니다.
seal "$RP3" --legacy-unverified "OID 없는 서브모듈 세션" "${SP3#${RP3}/}"; rc=$?
eq "$rc" "0" "legacy: --legacy-unverified 로 봉인 성공"
eq "$(seal_field "$(marker_path "$RP3" "$SP3ID")" verified)" "legacy-unverified" \
  "legacy: verified=legacy-unverified 기록"
has "OID 없는 서브모듈 세션" \
  "$(cat "${RP3}/rd-workflow-workspace/.lifecycle/review-skip-audit.log" 2>/dev/null)" \
  "legacy: 사유가 review-skip-audit.log 에 남음"

# legacy audit 은 이 우회 경로의 유일한 흔적이므로, 기록 실패가 성공으로 보고되면 안 됩니다.
# 권한(chmod)에 의존하지 않고 audit 파일 경로를 **디렉터리로 만들어** append 를 실패시킵니다 —
# root 로 돌리는 환경에서도 결과가 같습니다.
LEGACY_AUDIT="${RP3}/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
LEGACY_MARK="$(marker_path "$RP3" "$SP3ID")"
rm -f "$LEGACY_MARK" "$LEGACY_AUDIT"
mkdir -p "$LEGACY_AUDIT"
seal "$RP3" --legacy-unverified "audit 실패 확인" "${SP3#${RP3}/}"; rc=$?
eq "$rc" "1" "legacy audit: 기록 실패 시 seal 이 실패"
eq "$([[ -f "$LEGACY_MARK" ]] && echo yes || echo no)" "no" \
  "legacy audit: 기록 실패 시 마커를 만들지 않음 (교체 전에 audit 을 씀)"
rmdir "$LEGACY_AUDIT"

# 마커는 있는데 audit 만 빠진 상태(기록 실패로 끝난 과거 실행)를 재실행으로 메웁니다.
seal "$RP3" --legacy-unverified "audit 복구 확인" "${SP3#${RP3}/}"; rc=$?
eq "$rc" "0" "legacy audit: 복구된 경로에서 seal 성공"
rm -f "$LEGACY_AUDIT"
seal "$RP3" --legacy-unverified "audit 복구 확인" "${SP3#${RP3}/}"; rc=$?
eq "$rc" "0" "legacy audit: 마커가 이미 있어도 재실행이 성공"
has "audit 복구 확인" "$(cat "$LEGACY_AUDIT" 2>/dev/null)" \
  "legacy audit: 누락된 audit 이 재실행으로 복구됨"

# --- ⑥ head 재snapshot 원자성 ---
# 두 실패 경로를 같은 저장소·같은 세션에서 이어 시험합니다 — (c) 는 SESSION 을 바꾸지 않는
# 것이 계약이므로, (c) 를 통과한 세션이 (a) 의 정상적인 출발점이 됩니다.
#
# **mv shim 은 이 테스트 한 곳으로 범위를 제한합니다.** 가짜 도구 주입을 일반 관행으로
# 넓히지 않기 위해 SESSION.md 를 대상으로 하는 mv 에서만 실패하고 나머지는 실제 mv 에
# 위임합니다. 이 케이스가 없으면 **`mv` 의 종료 상태를 확인하지 않는 구현**이 (a)·(b) 를
# 모두 통과합니다 — 정상 실행에서는 inode 도 바뀌기 때문입니다. 그 구현은 실제 mv 실패가
# 나는 순간 reviewer 를 stale target 으로 dispatch 합니다.
SHIM="${WORK}/shim"
mkdir -p "$SHIM"
cat > "${SHIM}/mv" <<'SHIMEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    */SESSION.md) echo "mv shim: 의도적 실패" >&2; exit 1 ;;
  esac
done
exec /bin/mv "$@"
SHIMEOF
chmod +x "${SHIM}/mv"

R6="$(mk_repo)" || { echo "  FAIL  원자성(mv shim) 케이스: fixture 생성 실패"; exit 1; }
R6ROOT="$(git -C "$R6" rev-parse HEAD)"
commit_code "$R6" a1
R6BASE="$(git -C "$R6" rev-parse HEAD)"
commit_code "$R6" a2
prep "$R6" --base "$R6BASE" >/dev/null 2>&1
S6="$(session_dir "$R6")"
printf '# Turn 001 — Author\n초안\n' > "${S6}/turns/001_author.md"
set_session_state "$S6" "awaiting-reviewer" "Reviewer"
cp "${S6}/SESSION.md" "${OUT}/session-before.md"

# (c) 최종 교체만 실패 — 렌더까지 끝난 뒤 `mv` 만 결정적으로 실패시킵니다.
rm -f "${OUT}/adapter-called"
( cd "$R6" && RD_TEST_OUT="$OUT" REVIEW_TOOLS_CONFIG="$TOOLS_JSON" PATH="${SHIM}:${PATH}" \
    bash rd-workflow/scripts/run_review_turn.sh "${S6#${R6}/}" ) >"${OUT}/turn.out" 2>"${OUT}/turn.err"
rc=$?
ne "$rc" "0" "⑥(c) mv 실패: nonzero 반환"
cmp -s "${S6}/SESSION.md" "${OUT}/session-before.md"; rc=$?
eq "$rc" "0" "⑥(c) mv 실패: 기존 SESSION byte equality"
if [ -f "${OUT}/adapter-called" ]; then fail "⑥(c) mv 실패: 어댑터 미호출"; else pass "⑥(c) mv 실패: 어댑터 미호출"; fi
eq "$(ls "${S6}/turns" | wc -l | tr -d ' ')" "1" "⑥(c) mv 실패: 턴 파일 미생성"

# (a) 사전 검증 실패 — reset --hard 로 계보가 끊기면 SESSION 을 한 글자도 바꾸지 않습니다.
# (c) 가 SESSION 을 건드리지 않는 것이 계약이지만, 계약이 깨졌을 때 (a) 까지 덩달아 실패해
# 사유가 흐려지지 않도록 출발 상태를 명시적으로 되돌립니다.
cat "${OUT}/session-before.md" > "${S6}/SESSION.md"
ls "${S6}/turns" | grep -v '^001_author.md$' | while IFS= read -r _extra; do
  [ -n "$_extra" ] && rm -f "${S6}/turns/${_extra}"
done
git -C "$R6" reset --hard -q "$R6ROOT"
rm -f "${OUT}/adapter-called"
( cd "$R6" && RD_TEST_OUT="$OUT" REVIEW_TOOLS_CONFIG="$TOOLS_JSON" \
    bash rd-workflow/scripts/run_review_turn.sh "${S6#${R6}/}" ) >"${OUT}/turn.out" 2>"${OUT}/turn.err"
rc=$?
ne "$rc" "0" "⑥(a) 계보 단절: 턴을 시작하지 않고 nonzero"
cmp -s "${S6}/SESSION.md" "${OUT}/session-before.md"; rc=$?
eq "$rc" "0" "⑥(a) 계보 단절: SESSION 무변화"
eq "$(ls "${S6}/turns" | wc -l | tr -d ' ')" "1" "⑥(a) 계보 단절: 턴 파일 미생성"
if [ -f "${OUT}/adapter-called" ]; then fail "⑥(a) 계보 단절: 어댑터 미호출"; else pass "⑥(a) 계보 단절: 어댑터 미호출"; fi

# --- ⑧ iteration 중 트리가 base 로 되돌아간 경우 (Finding 4, resnapshot 쪽) ---
# 생성 시점만 막으면 부족합니다 — reviewer iteration 중 변경이 완전히 revert 되면 조상 관계는
# 유지된 채 diff 만 비어, 빈 target 으로 재snapshot 됩니다. 정상 턴(통제군) → 빈 diff 턴(차단)
# 순서로 확인해 "무조건 막는" 구현과 구분합니다.
RV="$(mk_repo)" || { echo "  FAIL  iteration 중 tree 원복 케이스: fixture 생성 실패"; exit 1; }
RVBASE="$(git -C "$RV" rev-parse HEAD)"
commit_code "$RV" v1
V1="$(git -C "$RV" rev-parse HEAD)"
state_set "$RV" base-commit "$RVBASE"
prep "$RV" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "⑧ 통제군: 세션 생성"
SV="$(session_dir "$RV")"
reviewer_turn "$RV" "$SV"; rc=$?
eq "$rc" "0" "⑧ 통제군: 변경이 있는 상태의 reviewer 턴은 정상 진행"
git -C "$RV" revert --no-edit "$V1" >/dev/null 2>&1
VREV="$(git -C "$RV" rev-parse HEAD)"
ne "$VREV" "$RVBASE" "⑧ revert 후 HEAD OID 는 base 와 다름"
reviewer_turn "$RV" "$SV"; rc=$?
ne "$rc" "0" "⑧ 빈 diff 재snapshot: 턴을 시작하지 않고 nonzero"
eq "$(bc_field "$SV" review-head-oid)" "$V1" "⑧ 빈 diff 재snapshot: head 가 갱신되지 않음"
has "변경이 없습니다" "$(cat "${OUT}/turn.err")" "⑧ 빈 diff 재snapshot: 사유 안내"
if [ -f "${OUT}/adapter-called" ]; then fail "⑧ 빈 diff 재snapshot: 어댑터 미호출"; else pass "⑧ 빈 diff 재snapshot: 어댑터 미호출"; fi

# --- ⑨ pinned 세션도 대상 무결성 검증을 받는다 (Finding 2) ---
# 정책은 **갱신 여부만** 가릅니다. `pinned` 을 검증 앞에서 조기 반환시키면, 기록 OID 가
# resolve 되지 않거나(ref 삭제 후 객체 정리·저장소 교체·SESSION 의 부분 수정) 계보가 끊기거나
# 트리가 base 와 같아진 세션이 그대로 reviewer dispatch 까지 가고, 사용자는 빈·엉뚱한 diff 로
# 돈 결과를 **성공한 리뷰 턴처럼** 받습니다. 세 실패 경로를 한 fixture 에서 이어 시험합니다
# (저장소·세션 생성이 케이스당 수 초라 공유합니다). 통제군은 위 "pinned 통제군" 블록입니다.
RPN="$(mk_repo)" || { echo "  FAIL  legacy 실패 경로: fixture 생성 실패"; exit 1; }
commit_code "$RPN" pn-base
PNBASE="$(git -C "$RPN" rev-parse HEAD)"          # 세션 base
git -C "$RPN" checkout -q -b pn/head
commit_code "$RPN" pn-head
PNHEAD="$(git -C "$RPN" rev-parse HEAD)"          # 유효한 pinned head
# base 의 후손이 아닌 계보 (amend·reset 으로 계보가 끊긴 상태와 같은 모양)
git -C "$RPN" checkout -q -b pn/other "${PNBASE}~1"
commit_code "$RPN" pn-other
PNOTHER="$(git -C "$RPN" rev-parse HEAD)"
# base 의 후손이면서 트리는 base 와 같은 커밋 (변경 + 완전 revert)
git -C "$RPN" checkout -q -b pn/rev "$PNBASE"
commit_code "$RPN" pn-rev
git -C "$RPN" revert --no-edit HEAD >/dev/null 2>&1
PNREV="$(git -C "$RPN" rev-parse HEAD)"
git -C "$RPN" checkout -q main
# 저장소에 없는 OID — 각 16진 숫자를 뒤집어 길이·형식은 유지한 채 실재하지 않게 만듭니다.
PNGONE="$(printf '%s' "$PNHEAD" | tr '0123456789abcdef' 'fedcba9876543210')"

if git -C "$RPN" cat-file -e "${PNGONE}^{commit}" 2>/dev/null; then
  fail "⑨ fixture: 존재하지 않는 OID 가 실제로 저장소에 없음"
else
  pass "⑨ fixture: 존재하지 않는 OID 가 실제로 저장소에 없음"
fi
eq "$(git -C "$RPN" rev-parse "${PNREV}^{tree}")" "$(git -C "$RPN" rev-parse "${PNBASE}^{tree}")" \
  "⑨ fixture: revert 커밋의 tree 가 base 와 같음"

state_set "$RPN" base-commit "$PNBASE"
prep "$RPN" "git diff ${PNBASE}..pn/head"; rc=$?
eq "$rc" "0" "⑨ fixture: pinned 세션 생성"
SPN="$(session_dir "$RPN")"
eq "$(bc_field "$SPN" review-head-policy)" "pinned" "⑨ fixture: 정책이 pinned"
cp "${SPN}/SESSION.md" "${OUT}/pinned-session-base.md"

pinned_fail_case() { # pinned_fail_case <설명> <기록할 head-oid> <기대 문구>
  local desc="$1" bad="$2" needle="$3" prc
  cat "${OUT}/pinned-session-base.md" > "${SPN}/SESSION.md"
  set_bc_field "$SPN" review-head-oid "$bad"
  reviewer_turn "$RPN" "$SPN"; prc=$?
  ne "$prc" "0" "⑨ ${desc}: 턴을 시작하지 않고 nonzero"
  cmp -s "${SPN}/SESSION.md" "${OUT}/session-prerun.md"; prc=$?
  eq "$prc" "0" "⑨ ${desc}: SESSION byte equality"
  if [ -f "${OUT}/adapter-called" ]; then fail "⑨ ${desc}: 어댑터 미호출"; else pass "⑨ ${desc}: 어댑터 미호출"; fi
  has "$needle" "$(cat "${OUT}/turn.err")" "⑨ ${desc}: 사유 안내"
}

pinned_fail_case "resolve 불가 pinned" "$PNGONE" \
  "세션에 고정된 head ('${PNGONE}') 를 커밋으로 해석할 수 없습니다"
pinned_fail_case "계보 끊긴 pinned" "$PNOTHER" \
  "세션에 고정된 head (${PNOTHER}) 가 review-base-oid (${PNBASE}) 의 후손이 아닙니다"
pinned_fail_case "빈 diff pinned" "$PNREV" \
  "세션에 고정된 head (${PNREV}) 사이에 변경이 없습니다"

# --- ⑨-b OID 묶음과 실제 dispatch target 의 결속 (turn 006 Finding 1) ---
# reviewer 에게 전달되는 것은 OID 두 줄이 아니라 `## Review Target` 섹션입니다. `auto` 는
# 이 섹션을 재렌더링하며 결속하지만 `pinned` 은 아무것도 다시 쓰지 않으므로, 이 세 상태가
# 막히지 않으면 **OID 가 가리키지 않는 diff** 가 리뷰되고도 `verified=yes` 로 봉인됩니다.
tuple_fail_case() { # tuple_fail_case <설명> <SESSION 변형 함수> <기대 문구>
  local desc="$1" mutate="$2" needle="$3" prc
  cat "${OUT}/pinned-session-base.md" > "${SPN}/SESSION.md"
  "$mutate"
  reviewer_turn "$RPN" "$SPN"; prc=$?
  ne "$prc" "0" "⑨-b ${desc}: 턴을 시작하지 않고 nonzero"
  cmp -s "${SPN}/SESSION.md" "${OUT}/session-prerun.md"; prc=$?
  eq "$prc" "0" "⑨-b ${desc}: SESSION byte equality"
  if [ -f "${OUT}/adapter-called" ]; then fail "⑨-b ${desc}: 어댑터 미호출"; else pass "⑨-b ${desc}: 어댑터 미호출"; fi
  has "$needle" "$(cat "${OUT}/turn.err")" "⑨-b ${desc}: 사유 안내"
}

_mut_stale_target() { set_target "$SPN" "git diff ${PNBASE}..${PNOTHER}"; }
_mut_one_sided()    { del_bc_field "$SPN" review-base-oid; }
_mut_moving_ref()   { set_bc_field "$SPN" review-head-oid "pn/head"; }

tuple_fail_case "Review Target 이 OID 와 어긋남" _mut_stale_target \
  "SESSION 의 Review Target 이 기록된 OID 와 어긋납니다"
tuple_fail_case "reviewed OID 가 한쪽만 있음" _mut_one_sided \
  "reviewed OID 가 한쪽만 있습니다"
tuple_fail_case "pinned head 가 이동 ref" _mut_moving_ref \
  "가 full OID 가 아닙니다"

# 통제군 — 원본 그대로면 턴이 정상으로 돌아 어댑터가 호출됩니다. 이것이 없으면 위 3건이
# 「pinned 은 전부 실패」하는 구현으로도 통과합니다.
cat "${OUT}/pinned-session-base.md" > "${SPN}/SESSION.md"
reviewer_turn "$RPN" "$SPN"; rc=$?
eq "$rc" "0" "⑨-b 통제군: 손대지 않은 pinned 세션은 턴이 성공"
if [ -f "${OUT}/adapter-called" ]; then pass "⑨-b 통제군: 어댑터 호출됨"; else fail "⑨-b 통제군: 어댑터 호출됨"; fi

# --- ⑦ SHA-256 저장소 ---
# OID 길이를 하드코딩한 구현(`{40}`)은 SHA-1 저장소에서는 절대 드러나지 않으므로
# 이 형식에서 prepare → 재snapshot → seal 을 한 번은 통과시켜야 합니다.
R7="$(mk_repo --sha256)"; rc7=$?
if [ "$rc7" -ne 0 ] || [ -z "$R7" ]; then
  echo "  SKIP  ⑦ SHA-256: 이 환경의 git 이 --object-format=sha256 을 지원하지 않습니다"
else
  B7="$(git -C "$R7" rev-parse HEAD)"
  commit_code "$R7" s1
  state_set "$R7" base-commit "$B7"
  prep "$R7"; rc=$?
  eq "$rc" "0" "⑦ SHA-256: prepare 성공"
  S7="$(session_dir "$R7")"
  eq "$(printf '%s' "$(bc_field "$S7" review-base-oid)" | wc -c | tr -d ' ')" "64" \
    "⑦ SHA-256: base 가 64자 native OID 로 기록 (길이 하드코딩 회귀 방지)"
  reviewer_turn "$R7" "$S7"; rc=$?
  eq "$rc" "0" "⑦ SHA-256: head 재snapshot 을 포함한 reviewer 턴 성공"
  close_session "$S7"
  seal "$R7" "${S7#${R7}/}"; rc=$?
  eq "$rc" "0" "⑦ SHA-256: seal 성공"
  eq "$(seal_field "$(marker_path "$R7" "$(basename "$S7")")" verified)" "yes" \
    "⑦ SHA-256: verified=yes"
fi

if [ "$FAIL" = 0 ]; then
  echo "test_review_base_resolution: ALL PASS"
else
  echo "test_review_base_resolution: FAIL"
fi
exit "$FAIL"
