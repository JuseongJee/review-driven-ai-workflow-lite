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
# 손으로 종결한 세션은 seal 이 거부하므로, 리뷰어 턴 실행 기록을 제품 함수로 남기는 fixture.
. "${SCRIPT_DIR}/fixtures/review_run_fixture.sh"

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
     "${RD_SRC}/scripts/_submodule_common.sh" \
     "${RD_SRC}/scripts/_task_common.sh" \
     "${RD_SRC}/scripts/rd" \
     "${RD_SRC}/scripts/verify_record.sh" \
     "${d}/rd-workflow/scripts/" || return 1
  cp "${RD_SRC}/scripts/hooks/_guard_common.sh" "${d}/rd-workflow/scripts/hooks/" || return 1
  # 판정 규칙이 담긴 awk 를 함께 복사한다. 누락하면 fixture 안에서 판정이 항상 실패해
  # 정상 종결 세션의 seal 성공 케이스가 깨진다.
  cp "${RD_SRC}/scripts/hooks/_open_issues.awk" "${d}/rd-workflow/scripts/hooks/" || return 1
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

close_session() { # close_session <session-dir> — 종결(Status=closed + Open Issues 없음 + 리뷰어 턴 실행 기록)
  local repo="${1%/${SESS_REL}/*}"
  printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' \
    > "${1}/CHECKPOINT.md"
  fixture_reviewer_turn "$1" "${repo}/rd-workflow/scripts" || return 1
  set_session_state "$1" "closed" "Author"
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

# put_evidence <repo> [exit-code] — 현재 HEAD 트리에 대한 증거 파일을 직접 깝니다 (래퍼 우회).
# 기존 seal 케이스는 증거 검사가 대상이 아니므로 seal() 이 기본으로 이것을 먼저 깝니다.
put_evidence() {
  local repo="$1" ec="${2:-0}" h oid
  h="$( ( project_root="$repo"; export project_root; source "${repo}/rd-workflow/scripts/_state_common.sh"; rd_protected_tree_hash HEAD ) )"
  oid="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "${repo}/rd-workflow-workspace/.lifecycle/review-seals"
  printf 'schema=1\ncommand=true\nexit-code=%s\ntree-hash=%s\nhead=%s\nrecorded-at=2026-10-29-0000\n' \
    "$ec" "$h" "$oid" > "${repo}/rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"
}

seal() { # seal <repo> [args...] — rd review seal 실행. 출력은 $OUT/seal.{out,err}
  local repo="$1"; shift
  [ -n "${SEAL_NO_EVIDENCE:-}" ] || put_evidence "$repo"
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

# --- 위치 인자로 지정한 head 가 현재 HEAD 가 아닐 때 ---
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

# --- 동일 tree · 다른 OID ---
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

echo "=== 10b. ref·접두 없는 위치 인자 (change-spec 2.2~2.4) ==="
# fixture: main 에 base, fr/x 에 커밋 1개, 그 뒤 main 전진. 태그 v1.0 = 분기 지점.
RR="$(mk_repo)" || { echo "  FAIL  10b: fixture 생성 실패"; exit 1; }
RRFORK="$(git -C "$RR" rev-parse HEAD)"
git -C "$RR" tag v1.0
git -C "$RR" checkout -q -b fr/x
commit_code "$RR" x1
RRTIP="$(git -C "$RR" rev-parse HEAD)"
git -C "$RR" checkout -q main
commit_code "$RR" main-adv
git -C "$RR" checkout -q fr/x

prep "$RR" "main"; rc=$?
eq "$rc" "0" "10b A1: ref 하나 — 성공"
SRR="$(session_dir "$RR")"
eq "$(bc_field "$SRR" review-base-oid)" "$RRFORK" "10b A1: base-oid = 분기 지점"
eq "$(bc_field "$SRR" review-head-oid)" "$RRTIP" "10b A1: head-oid = 현재 HEAD"
eq "$(bc_field "$SRR" review-head-policy)" "auto" "10b A1: policy auto"
has "'main' 를 비교 기준으로 해석했습니다" "$(cat "${OUT}/prep.err")" "10b A2: 해석 안내 문구"
has "${RRFORK:0:12}" "$(cat "${OUT}/prep.err")" "10b A2: 안내에 base 축약 OID"
rm -rf "${RR}/${SESS_REL:?}"/*

prep "$RR" "git diff main"; rc=$?
eq "$rc" "0" "10b A3: 접두 있는 ref 하나 — 성공"
SRR="$(session_dir "$RR")"
eq "$(bc_field "$SRR" review-base-oid)" "$RRFORK" "10b A3: base-oid 동일"
eq "$(bc_field "$SRR" review-head-oid)" "$RRTIP" "10b A3: head-oid 동일"
eq "$(bc_field "$SRR" review-head-policy)" "auto" "10b A3: policy auto"
rm -rf "${RR}/${SESS_REL:?}"/*

prep "$RR" "main...fr/x"; rc=$?
eq "$rc" "0" "10b A4: 접두 없는 세 점 — 성공"
SRR="$(session_dir "$RR")"
eq "$(bc_field "$SRR" review-base-oid)" "$RRFORK" "10b A4: base-oid = merge-base"
eq "$(bc_field "$SRR" review-head-oid)" "$RRTIP" "10b A4: head-oid = fr/x tip"
eq "$(bc_field "$SRR" review-head-policy)" "pinned" "10b A4: policy pinned"
rm -rf "${RR}/${SESS_REL:?}"/*

prep "$RR" "v1.0"; rc=$?
eq "$rc" "0" "10b A6: 점이 든 태그 — 성공"
SRR="$(session_dir "$RR")"
eq "$(bc_field "$SRR" review-base-oid)" "$RRFORK" "10b A6: base-oid = 태그 지점"

# A9: A1 과 같은 형태의 세션을 종결해 플래그 없이 seal
close_session "$SRR"
seal "$RR" "${SRR#${RR}/}"; rc=$?
eq "$rc" "0" "10b A9: ref 하나 세션이 플래그 없이 seal 성공"
SIDR="$(basename "$SRR")"
eq "$(seal_field "$(marker_path "$RR" "$SIDR")" verified)" "yes" "10b A9: 마커 verified=yes"
rm -rf "${RR}/${SESS_REL:?}"/*

N0="$(session_count "$RR")"
prep "$RR" "no-such-ref"; rc=$?
eq "$rc" "1" "10b A7: 해석 불가 ref — exit 1"
eq "$(session_count "$RR")" "$N0" "10b A7: 세션 미생성"
has "커밋으로 해석할 수 없습니다" "$(cat "${OUT}/prep.err")" "10b A7: 사유 안내"

prep "$RR" "fr/x"; rc=$?
eq "$rc" "1" "10b A8: 현재 브랜치 이름 — exit 1"
has "리뷰할 변경이 없습니다" "$(cat "${OUT}/prep.err")" "10b A8: 기존 사유"
has "비교 기준 브랜치를 주십시오" "$(cat "${OUT}/prep.err")" "10b A8: 추가 안내"

# A5: 접두 없는 두 점은 왼쪽(전진한 main tip)을 그대로 base 로 쓰므로 조상 검사에 걸립니다.
R5="$(mk_repo)" || { echo "  FAIL  10b A5: fixture 생성 실패"; exit 1; }
git -C "$R5" checkout -q -b fr/y
commit_code "$R5" y1
git -C "$R5" checkout -q main
commit_code "$R5" main-adv5
git -C "$R5" checkout -q fr/y
prep "$R5" "main..fr/y"; rc=$?
eq "$rc" "1" "10b A5: 접두 없는 두 점 — 조상 검사 실패"
has "조상이 아닙니다" "$(cat "${OUT}/prep.err")" "10b A5: 사유 안내"

# A10: `-` 로 시작하는 한 토큰(`git diff --cached` 등)은 ref 로 해석하지 않고 legacy 로 남습니다.
R10="$(mk_repo)" || { echo "  FAIL  10b A10: fixture 생성 실패"; exit 1; }
prep "$R10" "git diff --cached"; rc=$?
eq "$rc" "0" "10b A10: 'git diff --cached' — legacy 세션 생성"
eq "$(bc_field "$(session_dir "$R10")" review-base-oid)" "" "10b A10: legacy 라 base-oid 미기록"

# A11: 오른쪽이 빈 세 점(`main...`)은 양끝 중 빈 쪽이 있어 파싱 불가 — 두 점으로 오해하지 않고 legacy 로 남습니다.
R11="$(mk_repo)" || { echo "  FAIL  10b A11: fixture 생성 실패"; exit 1; }
prep "$R11" "main..."; rc=$?
eq "$rc" "0" "10b A11: 'main...' — legacy 세션 생성"
eq "$(bc_field "$(session_dir "$R11")" review-base-oid)" "" "10b A11: 'main...' legacy 라 base-oid 미기록"
R11B="$(mk_repo)" || { echo "  FAIL  10b A11: fixture 생성 실패"; exit 1; }
prep "$R11B" "git diff main..."; rc=$?
eq "$rc" "0" "10b A11: 'git diff main...' — legacy 세션 생성"
eq "$(bc_field "$(session_dir "$R11B")" review-base-oid)" "" "10b A11: 'git diff main...' legacy 라 base-oid 미기록"

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
has "status:awaiting-author" "$(cat "${OUT}/seal.err")" "검사 1: 사유에 판정 유발 지점이 담긴다"

# 검사 1 안내 (AC4) — 거부 사유 종류별로 복구 안내가 달라야 합니다. 상태·CHECKPOINT 를 잠시 바꿔 확인하고 원복합니다.
cp "${SS}/CHECKPOINT.md" "${OUT}/checkpoint-keep.md"
seal_hint_case() { # seal_hint_case <Open Issues 본문> — closed 세션으로 만들고 seal 을 시도
  set_session_state "$SS" "closed" "Author"
  printf '# Review Checkpoint\n\n## Open Issues\n%s\n\n## Suggested Next Owner\nAuthor\n' "$1" > "${SS}/CHECKPOINT.md"
  seal "$RS" "${SS#${RS}/}"
}
seal_hint_case '없음. 이의 없음.'; rc=$?
HINT="$(cat "${OUT}/seal.err")"
eq "$rc" "1" "검사 1 안내: 형식 위반 거부"
has "읽힌 값: 없음. 이의 없음." "$HINT" "검사 1 안내(형식): 실제로 읽힌 값을 보인다"
has "기대 형식: CHECKPOINT.md 의 'Open Issues' 첫 줄이 정확히 '- 없음'" "$HINT" "검사 1 안내(형식): 기대 형식을 보인다"
has "이의가 모두 해소된 경우에만" "$HINT" "검사 1 안내(형식): 복구는 이의 해소를 전제로 한다"
has "빈 줄 아래 문단" "$HINT" "검사 1 안내(형식): 설명 배치(빈 줄 아래 문단)를 안내한다"
seal_hint_case '- [ ] 잔여 한계 3건 미반영'; rc=$?
HINT="$(cat "${OUT}/seal.err")"
eq "$rc" "1" "검사 1 안내: 실제 미해결 이의 거부"
has "리뷰를 재개해 해소" "$HINT" "검사 1 안내(미해결): 리뷰 재개를 안내한다"
case "$HINT" in *"이의를 지우"*|*"지우고"*) fail "검사 1 안내(미해결): 이의 삭제를 권하면 안 된다" ;; *) pass "검사 1 안내(미해결): 이의 삭제를 권하지 않는다" ;; esac
cp "${OUT}/checkpoint-keep.md" "${SS}/CHECKPOINT.md"
set_session_state "$SS" "awaiting-author" "Author"

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

# ⑤-b seal 쪽 묶음 검증. 턴 경로만 막으면, 손상된 세션을 그대로
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
eq "$(ls "${RP3}/rd-workflow-workspace/.lifecycle/review-seals" 2>/dev/null | grep -vc '^verify-evidence$')" "0" \
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

# --- ⑧ iteration 중 트리가 base 로 되돌아간 경우 (resnapshot 쪽) ---
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

# --- ⑨ pinned 세션도 대상 무결성 검증을 받는다 ---
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

# --- ⑨-b OID 묶음과 실제 dispatch target 의 결속 ---
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
  # cwd 가 저장소 밖이어도 turn-blob 을 저장소 object format(sha256)으로 대조해야 합니다.
  rm -f "$(marker_path "$R7" "$(basename "$S7")")"
  ( cd / && bash "${R7}/rd-workflow/scripts/rd" review seal "$S7" ) >"${OUT}/seal.out" 2>"${OUT}/seal.err"; rc=$?
  eq "$rc" "0" "⑦ SHA-256: 저장소 밖 cwd 에서 seal 성공 (turn-blob 대조가 cwd 비의존)"
  # 저장소의 부모 디렉터리에서 상대 세션 경로로 부르는 경우 — 경로를 저장소 루트 기준으로 다시 해석하면 안 됩니다.
  rm -f "$(marker_path "$R7" "$(basename "$S7")")"
  ( cd "$(dirname "$R7")" && bash "$(basename "$R7")/rd-workflow/scripts/rd" review seal "$(basename "$R7")/${S7#${R7}/}" ) >"${OUT}/seal.out" 2>"${OUT}/seal.err"; rc=$?
  eq "$rc" "0" "⑦ SHA-256: 저장소 부모 cwd 에서 상대 세션 경로로 seal 성공"
fi

# --- 11b. seal 인자 해석 (change-spec 3) ---
echo "=== 11b. seal 인자 해석 (change-spec 3) ==="
RN="$(mk_repo)" || { echo "  FAIL  11b: fixture 생성 실패"; exit 1; }
RNBASE="$(git -C "$RN" rev-parse HEAD)"
commit_code "$RN" n1
state_set "$RN" base-commit "$RNBASE"
prep "$RN"; rc=$?
eq "$rc" "0" "11b: 세션 생성"
SN="$(session_dir "$RN")"
SNID="$(basename "$SN")"
close_session "$SN"

seal "$RN" "$SNID"; rc=$?
eq "$rc" "0" "11b B1: 세션 이름만 주면 seal 성공"
has "세션 이름 '${SNID}' 을 ${SESS_REL}/${SNID} 로 해석했습니다" "$(cat "${OUT}/seal.err")" "11b B1: 해석 안내 문구"

# B2: 저장소 루트에 같은 이름의 디렉터리가 있으면 기존 경로가 우선합니다.
mkdir "${RN}/${SNID}"
seal "$RN" "$SNID"; rc=$?
ne "$rc" "0" "11b B2: 루트의 동명 디렉터리가 우선 — 세션이 아니므로 실패"
case "$(cat "${OUT}/seal.err")" in
  *해석했습니다*) fail "11b B2: 기존 경로 우선인데 해석 안내가 나옴" ;;
  *) pass "11b B2: 해석 안내 없음" ;;
esac
rmdir "${RN}/${SNID}"

seal "$RN" "no-such-session"; rc=$?
eq "$rc" "1" "11b B3: 없는 이름 — exit 1"
has "기대 형식: ${SESS_REL}/<세션>" "$(cat "${OUT}/seal.err")" "11b B3: 기대 형식 안내"
has "현재 작업의 세션: ${SESS_REL}/$(awk -F= '$1=="review-session"{print $2}' "${RN}/rd-workflow-workspace/.lifecycle/task-state")" "$(cat "${OUT}/seal.err")" "11b B4: 현재 작업 세션 안내"

seal "$RN" "./${SNID}"; rc=$?
eq "$rc" "1" "11b B5: ./ 접두 이름은 해석하지 않음 — exit 1"
has "기대 형식: ${SESS_REL}/<세션>" "$(cat "${OUT}/seal.err")" "11b B5: 기대 형식 안내"
case "$(cat "${OUT}/seal.err")" in
  *해석했습니다*) fail "11b B5: 해석 안내가 나오면 안 됨" ;;
  *) pass "11b B5: 해석 안내 없음" ;;
esac

# B6: 하위 디렉터리에서도 세션 이름으로 seal 됩니다 (이름 해석 후 내부 경로는 절대 경로).
rm -f "$(marker_path "$RN" "$SNID")"
put_evidence "$RN"
( cd "${RN}/rd-workflow" && bash scripts/rd review seal "$SNID" ) >"${OUT}/seal.out" 2>"${OUT}/seal.err"; rc=$?
eq "$rc" "0" "11b B6: 하위 디렉터리 cwd 에서 세션 이름 seal 성공"
eq "$([ -f "$(marker_path "$RN" "$SNID")" ] && echo yes || echo no)" "yes" "11b B6: 마커 생성"

# --- seal evidence ---
# seal 은 이 트리의 새 검증 증거(verify_record.sh)를 요구합니다. seal() 헬퍼의 자동 증거를 끄고
# (SEAL_NO_EVIDENCE) 증거 파일을 직접 조작해 거부 경로를 봅니다.
echo "=== 12. seal 새 검증 증거 요구 ==="
RV="$(mk_repo)" || { echo "  FAIL  seal evidence: fixture 생성 실패"; exit 1; }
BV="$(git -C "$RV" rev-parse HEAD)"
commit_code "$RV" ev1
state_set "$RV" base-commit "$BV"
prep "$RV"; rc=$?
eq "$rc" "0" "seal evidence: 세션 생성"
SV="$(session_dir "$RV")"
reviewer_turn "$RV" "$SV"; rc=$?
eq "$rc" "0" "seal evidence: reviewer 턴 성공"
close_session "$SV"
EVF="${RV}/rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"
MKV="$(marker_path "$RV" "$(basename "$SV")")"
export SEAL_NO_EVIDENCE=1

# (a) 증거 없음
rm -f "$EVF"
seal "$RV" "${SV#${RV}/}"; rc=$?
eq "$rc" "1" "(a) 증거 없음: seal 거부"
has "verify_record.sh --" "$(cat "${OUT}/seal.err")" "(a) 증거 없음: 증거 만드는 명령을 안내"
[ -f "$MKV" ] && fail "(a) 거부 시 마커 미생성" || pass "(a) 거부 시 마커 미생성"

# (b) 증거 exit-code=1
put_evidence "$RV" 1
seal "$RV" "${SV#${RV}/}"; rc=$?
eq "$rc" "1" "(b) 증거 exit-code=1: seal 거부"

# (c) 증거 tree-hash 불일치
put_evidence "$RV" 0
CUR8="$(kv_get() { awk -F'=' -v k="$2" '$1==k{sub(/^[^=]+=/,"");print;exit}' "$1"; }; kv_get "$EVF" tree-hash | cut -c1-8)"
sed -i 's/^tree-hash=.*/tree-hash=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/; s/^command=.*/command=bash x.sh --y/' "$EVF"
seal "$RV" "${SV#${RV}/}"; rc=$?
eq "$rc" "1" "(c) 증거 트리 불일치: seal 거부"
has "증거 deadbeef ≠ 현재 ${CUR8}" "$(cat "${OUT}/seal.err")" "(c) 증거 앞 8자 ≠ 현재 앞 8자 표기"
has "verify_record.sh -- bash x.sh --y" "$(cat "${OUT}/seal.err")" "(c) 증거의 command 로 재실행 안내"

# (d) schema 키만 빠진 증거 — 나머지는 유효해도 거부
put_evidence "$RV" 0
sed -i '/^schema=/d' "$EVF"
seal "$RV" "${SV#${RV}/}"; rc=$?
eq "$rc" "1" "(d) schema 키 누락: seal 거부"
has "손상" "$(cat "${OUT}/seal.err")" "(d) malformed 안내"

# (e) 래퍼로 만든 증거 → seal 성공, 마커 tree-hash == 증거 tree-hash
rm -f "$EVF"
( cd "$RV" && bash rd-workflow/scripts/verify_record.sh -- true ) >"${OUT}/vr.out" 2>&1; rc=$?
eq "$rc" "0" "(e) 래퍼로 증거 생성"
seal "$RV" "${SV#${RV}/}"; rc=$?
eq "$rc" "0" "(e) 래퍼 증거로 seal 성공"
eq "$(seal_field "$MKV" tree-hash)" "$(seal_field "$EVF" tree-hash)" "(e) 마커 tree-hash == 증거 tree-hash"

# (f) --legacy-unverified 는 증거 없이 통과 (회귀)
RL="$(mk_repo)" || { echo "  FAIL  seal evidence legacy: fixture 생성 실패"; exit 1; }
commit_code "$RL" lg
prep "$RL" "git -C sub diff main...HEAD"; rc=$?
SL="$(session_dir "$RL")"
close_session "$SL"
rm -f "${RL}/rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"
seal "$RL" --legacy-unverified "증거 면제 회귀" "${SL#${RL}/}"; rc=$?
eq "$rc" "0" "(f) legacy 세션: 증거 없이 seal 성공"
unset SEAL_NO_EVIDENCE

# --- 12. 리뷰 입력 규모 경고 (change-spec 5) ---
# 막는 실수: 거대한 diff 가 경고 없이 리뷰에 들어가 제한 시간 초과로 끝나는 것.
# 설정 파일을 쓰면 보호 트리가 바뀌므로 seal 용 저장소와 분리한 별도 저장소를 씁니다.
mk_size_repo() { # mk_size_repo — base 뒤 커밋 1개(yarn.lock 30 + a.txt 10 + b.txt 5 = 45행)
  local r
  r="$(mk_repo)" || return 1
  seq 30 > "${r}/yarn.lock"; seq 10 > "${r}/a.txt"; seq 5 > "${r}/b.txt"
  git -C "$r" add -A && git -C "$r" commit -q -m "size fixture" || return 1
  printf '%s\n' "$r"
}
set_warn_cfg() { # set_warn_cfg <repo> <JSON 값 원문>
  mkdir -p "${1}/rd-workflow/config"
  printf '{\n  "review_input_warn_lines": %s\n}\n' "$2" > "${1}/rd-workflow/config/workflow.json"
}
WARN_ERR=""
RS1="$(mk_size_repo)" || { echo "  FAIL  12: fixture 생성 실패"; exit 1; }
set_warn_cfg "$RS1" 20
prep "$RS1" --base main~1; rc=$?
WARN_ERR="$(cat "${OUT}/prep.err")"
eq "$rc" "0" "12 C1: 임계 초과여도 세션 생성(rc 0)"
eq "$(session_count "$RS1")" "1" "12 C1: 세션 생성됨"
has "변경 45행이 경고 기준 20행을 넘습니다" "$WARN_ERR" "12 C1: 규모 경고 문구"
case "$WARN_ERR" in *"yarn.lock  [분리 후보]"*) pass "12 C2: yarn.lock 에 분리 후보 표시" ;; *) fail "12 C2: yarn.lock 에 분리 후보 표시 (문구 없음)" ;; esac
has "분리 후보(락파일" "$WARN_ERR" "12 C2: 분리 후보 안내 줄"
A_LINE="$(printf '%s\n' "$WARN_ERR" | grep 'a\.txt' || true)"
has "a.txt" "$A_LINE" "12 C3: a.txt 줄 존재"
case "$A_LINE" in *"[분리 후보]"*) fail "12 C3: a.txt 는 분리 후보가 아님 (표시됨)" ;; *) pass "12 C3: a.txt 는 분리 후보가 아님" ;; esac

nowarn() { # nowarn <설명> — 직전 prep 의 stderr 에 규모 경고가 없음
  case "$(cat "${OUT}/prep.err")" in *"행을 넘습니다"*) fail "$1 (문구 있음)" ;; *) pass "$1" ;; esac
}
RS4="$(mk_size_repo)" || exit 1; set_warn_cfg "$RS4" 45
prep "$RS4" --base main~1; nowarn "12 C4: 합계 == 임계면 경고 없음(초과일 때만)"
RS5="$(mk_size_repo)" || exit 1; set_warn_cfg "$RS5" 0
prep "$RS5" --base main~1; nowarn "12 C5: 0 은 경고 끔"
RS6="$(mk_size_repo)" || exit 1; set_warn_cfg "$RS6" '"abc"'
prep "$RS6" --base main~1; rc=$?
E6="$(cat "${OUT}/prep.err")"
eq "$rc" "0" "12 C6: 무효 값이어도 세션 생성"
has "값('\"abc\"')이 0 이상의 정수가 아니어서 기본값 8000 을 씁니다" "$E6" "12 C6: 무효 값 안내"
nowarn "12 C6: 무효 값이면 기본값 8000 으로 비교(경고 없음)"
RS7="$(mk_repo)" || exit 1
seq 8001 > "${RS7}/big.txt"; git -C "$RS7" add -A && git -C "$RS7" commit -q -m big
prep "$RS7" --base main~1
has "경고 기준 8000행" "$(cat "${OUT}/prep.err")" "12 C7: workflow.json 없으면 기본값 8000"
RS8="$(mk_size_repo)" || exit 1; set_warn_cfg "$RS8" 1
prep "$RS8" "git -C sub diff x..y"; rc=$?
eq "$rc" "0" "12 C8: 파싱 불가 표현 세션 생성"
nowarn "12 C8: reviewed OID 가 없으면 규모 경고 없음"

# --- 13. 서브모듈 알림 (change-spec 6) ---
# 막는 실수: outer diff 가 서브모듈 내부 변경을 담지 않는데 리뷰어·사용자가 그걸 모른 채 리뷰가 끝나는 것.
# fixture 는 seal 용 저장소와 분리합니다 (.gitmodules·gitlink 가 보호 트리를 바꾸므로).
GITSM() { git -c protocol.file.allow=always "$@"; }
SUBSRC="$(mktemp -d "${WORK}/subsrc.XXXXXX")" || exit 1
git init -q -b main "$SUBSRC" && git -C "$SUBSRC" config user.email t@e.com && git -C "$SUBSRC" config user.name t
echo 1 > "${SUBSRC}/f"; git -C "$SUBSRC" add -A; git -C "$SUBSRC" commit -q -m s1; S1="$(git -C "$SUBSRC" rev-parse HEAD)"
echo 2 > "${SUBSRC}/f"; git -C "$SUBSRC" commit -q -am s2; S2="$(git -C "$SUBSRC" rev-parse HEAD)"
SM_NOTICE="서브모듈 변경이 있습니다"

# D1 (가) 체크아웃 불일치: sub 를 S2 로 옮겨 gitlink 만 stage(커밋 안 함)
RD1="$(mk_repo)" || { echo "  FAIL  13: fixture 생성 실패"; exit 1; }
GITSM -C "$RD1" submodule add -q "$SUBSRC" sub >/dev/null 2>&1
git -C "${RD1}/sub" checkout -q "$S1"; git -C "$RD1" add -A
git -C "$RD1" commit -q -m "add sub"; O1="$(git -C "$RD1" rev-parse HEAD)"
echo d1 >> "${RD1}/code.txt"; git -C "$RD1" commit -q -am "code d1"
# outer HEAD 의 gitlink 는 S1 로 두고, 체크아웃만 S2 로 옮긴 뒤 gitlink 를 stage 합니다 (커밋 안 함).
git -C "${RD1}/sub" checkout -q "$S2"
git -C "$RD1" add sub
prep "$RD1" --base "$O1"; E="$(cat "${OUT}/prep.err")"
has "[체크아웃] sub:" "$E" "13 D1: 체크아웃 불일치 알림 (stage 만 된 gitlink 도 감지)"
has "git -C sub diff ${S1}..HEAD" "$E" "13 D1: 지정 예에 outer HEAD gitlink 전체 OID"

# D2 (나) 커밋된 포인터 변경
RD2="$(mk_repo)" || exit 1
GITSM -C "$RD2" submodule add -q "$SUBSRC" sub >/dev/null 2>&1
git -C "${RD2}/sub" checkout -q "$S1"; git -C "$RD2" add -A
git -C "$RD2" commit -q -m "add sub at s1"; P1="$(git -C "$RD2" rev-parse HEAD)"
git -C "${RD2}/sub" checkout -q "$S2"; git -C "$RD2" commit -q -am "bump sub"; P3="$(git -C "$RD2" rev-parse HEAD)"
prep "$RD2" --base "$P1"; E="$(cat "${OUT}/prep.err")"
has "[커밋된 포인터] sub: ${S1:0:12}→${S2:0:12} (리뷰 입력에 내부 코드를 펼쳤습니다)" "$E" "13 D2: 커밋된 포인터 변경 알림"
case "$E" in *"내부 변경을 리뷰하려면"*) fail "13 D2: 펼친 구간에는 우회 안내 없음 (안내가 있음)" ;; *) pass "13 D2: 펼친 구간에는 우회 안내 없음" ;; esac

# D3 (나) 삭제: 마지막 서브모듈과 .gitmodules 를 함께 지운 커밋
git -C "$RD2" rm -q sub; git -C "$RD2" rm -qf .gitmodules
git -C "$RD2" commit -q -m "drop sub"
if [ ! -e "${RD2}/.gitmodules" ]; then
  prep "$RD2" --base "$P3"; E="$(cat "${OUT}/prep.err")"
  has "[커밋된 포인터] sub:" "$E" "13 D3: .gitmodules 없이도 삭제 알림"
  case "$E" in *"git -C sub diff"*) fail "13 D3: 추가·삭제는 diff 예 없음 (예가 있음)" ;; *) pass "13 D3: 추가·삭제는 diff 예 없음" ;; esac
else
  fail "13 D3: fixture 전제 깨짐 (.gitmodules 가 남아 있음)"
fi

# D4 미초기화·구간 무변경: 서브모듈을 초기화하지 않은 clone
RC4="${WORK}/clone4"; git clone -q "$RD1" "$RC4" 2>/dev/null
git -C "$RC4" config user.email t@e.com; git -C "$RC4" config user.name t
git -C "$RC4" checkout -q "$O1" 2>/dev/null
echo d4 >> "${RC4}/code.txt"; git -C "$RC4" commit -q -m "code d4" code.txt
prep "$RC4" --base HEAD~1; E="$(cat "${OUT}/prep.err")"
case "$E" in *"$SM_NOTICE"*) fail "13 D4: 미초기화·구간 무변경이면 서브모듈 알림 없음 (알림 있음)" ;; *) pass "13 D4: 미초기화·구간 무변경이면 서브모듈 알림 없음" ;; esac

# D5 미초기화·구간 변경: (나)는 나오고 (가)는 없음
RC5="${WORK}/clone5"; git clone -q "$RD2" "$RC5" 2>/dev/null
git -C "$RC5" config user.email t@e.com; git -C "$RC5" config user.name t
git -C "$RC5" checkout -q "$P3" 2>/dev/null
prep "$RC5" --base "$P1"; E="$(cat "${OUT}/prep.err")"
# 미초기화 submodule 의 포인터가 바뀐 구간은 안쪽 코드를 펼칠 수 없으므로 세션 생성 전에 차단된다(spec D6).
has "객체 부재" "$E" "13 D5: 미초기화 submodule 의 구간 포인터 변경은 객체 부재로 차단"
case "$E" in *"[체크아웃]"*) fail "13 D5: 미초기화면 [체크아웃] 없음 (있음)" ;; *) pass "13 D5: 미초기화면 [체크아웃] 없음" ;; esac

# D6 공백이 있는 서브모듈 이름·경로: (가) 알림이 사라지지 않고 안내 명령 경로가 인용됩니다.
RD6="$(mk_repo)" || exit 1
mkdir -p "${RD6}/libs"
GITSM -C "$RD6" submodule add -q "$SUBSRC" "libs/my sub" >/dev/null 2>&1
git -C "${RD6}/libs/my sub" checkout -q "$S1"; git -C "$RD6" add -A
git -C "$RD6" commit -q -m "add spaced sub"; Q1="$(git -C "$RD6" rev-parse HEAD)"
echo d6 >> "${RD6}/code.txt"; git -C "$RD6" commit -q -am "code d6"
git -C "${RD6}/libs/my sub" checkout -q "$S2"
prep "$RD6" --base "$Q1"; E="$(cat "${OUT}/prep.err")"
has "[체크아웃] libs/my sub:" "$E" "13 D6a: 공백이 있는 서브모듈 경로도 체크아웃 불일치 알림"
# 안내 줄을 복사해 실행한 것처럼 평가합니다. stub 만 정의한 서브셸에서, 임시 디렉터리를 cwd 로 하므로
# 실제 git·prepare 스크립트는 돌지 않습니다. target = diff 대상 원문, cpath = 그 안 `git -C <경로>` 의 경로.
run_notice_line() { # run_notice_line <stderr 텍스트> <작업 디렉터리>
  local line cmdline
  line="$(printf '%s\n' "$1" | grep -F '내부 변경을 리뷰하려면: ' | head -1)"
  cmdline="${line#*내부 변경을 리뷰하려면: }"
  rm -f "${2}/target" "${2}/cpath"
  (
    cd "$2" || exit 1
    prepare_review_pipeline.sh() { printf '%s' "$2" > "${NOTICE_DIR}/target"; }
    git() { printf '%s' "$2" > "${NOTICE_DIR}/cpath"; }
    NOTICE_DIR="$2"
    eval "$cmdline"
    [ -f "${NOTICE_DIR}/target" ] && eval "$(cat "${NOTICE_DIR}/target")"
  ) >/dev/null 2>&1
}
eq() { [ "$1" = "$2" ] && pass "$3" || fail "$3 (기대=[${2}] 실제=[${1}])"; }

NT="$(mktemp -d "${WORK}/notice.XXXXXX")" || exit 1
run_notice_line "$E" "$NT"
eq "$(cat "${NT}/cpath" 2>/dev/null)" "libs/my sub" "13 D6b: 안내 줄을 실행하면 공백 경로가 한 단어로 전달됨"

# D7(경로 특수 문자가 든 [커밋된 포인터] 안내 줄의 셸 인용)은 그 안내 줄이 사라져(spec D10) 대상이 없어 지웁니다.
# [체크아웃] 안내 줄의 인용은 D6b 가 본다.

# --- 14. 리뷰어 턴 실행 기록 대조 (review-integrity change-spec 4.3·4.6) ---
# 이 절이 막는 실수: 리뷰어 턴을 실제로 돌리지 않고 손으로 종결한 세션이 seal 을 통과하는 것.
echo "=== 14. seal 의 리뷰어 턴 실행 기록 대조 (R1~R10) ==="
RRR="$(mk_repo)" || { echo "  FAIL  14: fixture 생성 실패"; exit 1; }
RRRB="$(git -C "$RRR" rev-parse HEAD)"
commit_code "$RRR" rr1
state_set "$RRR" base-commit "$RRRB"
prep "$RRR"; rc=$?
eq "$rc" "0" "14: 세션 생성"
SRR14="$(session_dir "$RRR")"
SRR14ID="$(basename "$SRR14")"
RRR_SCRIPTS="${RRR}/rd-workflow/scripts"

rr_reset() { # rr_reset — 턴·기록·마커를 비우고 Author 턴 001 만 남긴 종결 상태로 되돌립니다.
  rm -f "${SRR14}"/turns/* "${SRR14}/reviewer_runs.tsv" "$(marker_path "$RRR" "$SRR14ID")"
  mkdir -p "${SRR14}/turns"
  printf '# Turn 001 — Author\n반영했습니다.\n' > "${SRR14}/turns/001_author.md"
  printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "${SRR14}/CHECKPOINT.md"
  set_session_state "$SRR14" "closed" "Author"
}
rr_seal() { seal "$RRR" "${SRR14#${RRR}/}"; RR_RC=$?; RR_ERR="$(cat "${OUT}/seal.err")"; }

rr_set_reason() { # rr_set_reason <값> — 템플릿의 주석 줄 아래 `-` 줄을 값으로 바꿉니다.
  awk -v v="$1" '$0=="## Closure Reason"{f=1; print; next} f&&/^## /{f=0} f&&NF&&!/^<!--/{print v; f=0; next} {print}' "${SRR14}/SESSION.md" > "${OUT}/sess.tmp" \
    && cat "${OUT}/sess.tmp" > "${SRR14}/SESSION.md"
}
rr_set_basis() { # rr_set_basis <줄> — Closure Reason 절의 값 줄 뒤를 비우고 인자 줄 하나를 넣습니다(빈 인자는 줄을 넣지 않음).
  awk -v b="$1" '$0=="## Closure Reason"{f=1; print; next} f&&/^## /{if(b!=""&&seen)print b; f=0; seen=0; print; next} f&&seen{next} f&&NF&&!/^<!--/{seen=1; print; next} {print}' "${SRR14}/SESSION.md" > "${OUT}/sess.tmp" \
    && cat "${OUT}/sess.tmp" > "${SRR14}/SESSION.md"
}

# R1: 기록 0건 + 손으로 쓴 리뷰어 턴 (S4c)
rr_reset
printf '# Turn 002 — Reviewer\n이의 없음\n' > "${SRR14}/turns/002_reviewer.md"
rr_seal
ne "$RR_RC" "0" "R1: 기록 0건 + 손 종결 — rc≠0"
has "실제로 실행된 리뷰어 턴 기록이 없습니다" "$RR_ERR" "R1: run-missing 문구"
has "archive.sh --force-skip-review-check" "$RR_ERR" "R1: 수동 fallback 줄"

# R1b: 머리줄만 있는 기록 파일
printf '# turn\ttool\tmode\thead\tturn-blob\topen-issues\tepoch\n' > "${SRR14}/reviewer_runs.tsv"
rr_seal
ne "$RR_RC" "0" "R1b: 머리줄만 있는 기록 — rc≠0"
has "실제로 실행된 리뷰어 턴 기록이 없습니다" "$RR_ERR" "R1b: run-missing 문구"

# R2: 리뷰어 턴 + 기록(ok), 비어 있는 Closure Reason
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
rr_seal
eq "$RR_RC" "0" "R2: 기록된 리뷰어 턴 + 이의 없음 — rc=0"
MK14="$(marker_path "$RRR" "$SRR14ID")"
eq "$(grep -cx 'closure-reason=reviewer-no-objection' "$MK14")" "1" "R2: 마커에 closure-reason 줄이 정확히 1줄"
eq "$(grep -cx 'verified=yes' "$MK14")" "1" "R2: 마커에 verified=yes 줄이 정확히 1줄 (줄바꿈 회귀)"

# R2b: 같은 turn 두 줄 — 앞 줄 무효, 마지막 줄 유효
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
{ head -1 "${SRR14}/reviewer_runs.tsv"; printf '002\tcodex\tbroken\n'; tail -1 "${SRR14}/reviewer_runs.tsv"; } > "${OUT}/runs.tmp"
cat "${OUT}/runs.tmp" > "${SRR14}/reviewer_runs.tsv"
rr_seal
eq "$RR_RC" "0" "R2b: 같은 turn 중 마지막 줄이 유효하면 rc=0"

# R2c: 지난 턴(002) 파일을 바꿨어도 마지막 턴(004)의 기록이 유효하면 봉인
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
printf '# Turn 003 — Author\n반영했습니다.\n' > "${SRR14}/turns/003_author.md"
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
printf 'edited\n' >> "${SRR14}/turns/002_reviewer.md"
rr_seal
eq "$RR_RC" "0" "R2c: 지난 턴 기록 손상은 거부 사유가 아님 — rc=0"
has "무효 실행 기록 1건" "$RR_ERR" "R2c: 무효 기록 경고"

# R3: 기록 시점 Open Issues 미해결 → 뒤늦게 CHECKPOINT 만 고침
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS" "- 이의가 남았습니다"
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "${SRR14}/CHECKPOINT.md"
rr_seal
ne "$RR_RC" "0" "R3: 기록 당시 미해결 — rc≠0"
has "마지막 리뷰어 턴이 이의 없이 끝났다는 실행 기록이 없습니다" "$RR_ERR" "R3: reason-unproven 문구"
has "종료 시 Open Issues 미해결" "$RR_ERR" "R3: 어긋난 항목"

# R6: 지난 턴 기록은 유효, 마지막 리뷰어 턴 파일을 기록 뒤에 수정
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
printf '# Turn 003 — Author\n반영했습니다.\n' > "${SRR14}/turns/003_author.md"
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
printf 'edited\n' >> "${SRR14}/turns/004_reviewer.md"
rr_seal
ne "$RR_RC" "0" "R6: 마지막 턴 파일 수정 — rc≠0"
has "파일이 실행 기록 뒤 바뀜" "$RR_ERR" "R6: 어긋난 항목"

# R8: 마지막 턴이 Author 턴
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
printf '# Turn 003 — Author\n반영했습니다.\n' > "${SRR14}/turns/003_author.md"
rr_seal
ne "$RR_RC" "0" "R8: 마지막 턴이 Author — rc≠0"
has "마지막 턴이 리뷰어 턴이 아님" "$RR_ERR" "R8: 어긋난 항목"

# R8b: R2 + 턴이 아닌 파일 (turns/notes.md)
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
printf 'memo\n' > "${SRR14}/turns/notes.md"
rr_seal
eq "$RR_RC" "0" "R8b: turns/ 의 비턴 파일은 마지막 턴 판정에서 제외 — rc=0"

# R9: 기록의 head 가 SESSION 의 review-head-oid 와 다름
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
awk -F'\t' -v OFS='\t' 'NR > 1 && !/^#/ { $4 = "0000000000000000000000000000000000000000" } { print }' \
  "${SRR14}/reviewer_runs.tsv" > "${OUT}/runs.tmp"
cat "${OUT}/runs.tmp" > "${SRR14}/reviewer_runs.tsv"
rr_seal
ne "$RR_RC" "0" "R9: head 불일치 — rc≠0"
has "head 가 review-head-oid 와 다름" "$RR_ERR" "R9: 어긋난 항목"

# R10: (R2 이후 SESSION 은 템플릿 그대로입니다) 새로 만든 세션의 SESSION.md 에 Closure Reason 절과 값 '-'
eq "$(grep -cx '## Closure Reason' "${SRR14}/SESSION.md")" "1" "R10: SESSION 템플릿에 Closure Reason 절"
eq "$(awk '$0=="## Closure Reason"{f=1;next} f&&/^## /{exit} f&&$0=="-"{print}' "${SRR14}/SESSION.md")" "-" "R10: 절의 값 줄은 -"

# R4: 기록 당시 이의 미해결 + user-override + 근거 줄 → 봉인, 마커에 사유, stderr 에 근거
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS" "- 이의가 남았습니다"
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "${SRR14}/CHECKPOINT.md"
rr_set_reason "user-override"; rr_set_basis '- 근거: 2026-11-06 사용자 — "덮고 종결"'
rr_seal
eq "$RR_RC" "0" "R4: user-override + 근거 — rc=0"
eq "$(grep -cx 'closure-reason=user-override' "$MK14")" "1" "R4: 마커에 closure-reason=user-override 가 정확히 1줄"
has 'user-override 근거 — 2026-11-06 사용자 — "덮고 종결"' "$RR_ERR" "R4: 근거 내용 출력"

# R4b: 절 안 근거 줄 없음 + 다음 절(## Current Owner) 아래에만 근거 줄 (절 경계)
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS" "- 이의가 남았습니다"
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "${SRR14}/CHECKPOINT.md"
rr_set_reason "user-override"; rr_set_basis ""
cp "${SRR14}/SESSION.md" "${OUT}/sess.bak"
awk '{print} $0=="## Current Owner"{print "근거: 다음 절의 메모"}' "${OUT}/sess.bak" > "${OUT}/sess.tmp" && cat "${OUT}/sess.tmp" > "${SRR14}/SESSION.md"
rr_seal
ne "$RR_RC" "0" "R4b: 절 밖 근거 줄 — rc≠0"
has "사람의 결정 근거 줄이 없습니다" "$RR_ERR" "R4b: override-basis-missing 문구"
cat "${OUT}/sess.bak" > "${SRR14}/SESSION.md"

# R4c: 근거 줄은 있으나 내용이 공백뿐
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS" "- 이의가 남았습니다"
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "${SRR14}/CHECKPOINT.md"
rr_set_reason "user-override"; rr_set_basis '- 근거:   '
rr_seal
ne "$RR_RC" "0" "R4c: 내용 빈 근거 줄 — rc≠0"
has "사람의 결정 근거 줄이 없습니다" "$RR_ERR" "R4c: override-basis-missing 문구"

# R4d: 근거 줄이 주석 안
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS" "- 이의가 남았습니다"
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "${SRR14}/CHECKPOINT.md"
rr_set_reason "user-override"; rr_set_basis '<!-- 근거: 덮고 종결 -->'
rr_seal
ne "$RR_RC" "0" "R4d: 주석 안 근거 줄 — rc≠0"
has "사람의 결정 근거 줄이 없습니다" "$RR_ERR" "R4d: override-basis-missing 문구"

# R4e: 근거 줄의 내용이 작성 안내 주석뿐
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS" "- 이의가 남았습니다"
printf '# Review Checkpoint\n\n## Open Issues\n- 없음\n\n## Suggested Next Owner\nAuthor\n' > "${SRR14}/CHECKPOINT.md"
rr_set_reason "user-override"; rr_set_basis '- 근거: <!-- 사람이 답하면 채우기 -->'
rr_seal
ne "$RR_RC" "0" "R4e: 내용이 주석뿐인 근거 줄 — rc≠0"
has "사람의 결정 근거 줄이 없습니다" "$RR_ERR" "R4e: override-basis-missing 문구"
rr_set_basis ""

# R5: 기록 0건 + user-override → 공통 run-missing 검사에 걸림
rr_reset
rr_set_reason "user-override"
rr_seal
ne "$RR_RC" "0" "R5: 기록 0건 + user-override — rc≠0"
has "실제로 실행된 리뷰어 턴 기록이 없습니다" "$RR_ERR" "R5: run-missing 문구"

# R7: 허용 값 밖
rr_reset
fixture_reviewer_turn "$SRR14" "$RRR_SCRIPTS"
rr_set_reason "foo"
rr_seal
ne "$RR_RC" "0" "R7: 허용 값 밖 — rc≠0"
has "Closure Reason 값이 올바르지 않습니다: 'foo'" "$RR_ERR" "R7: reason-invalid 문구"

if [ "$FAIL" = 0 ]; then
  echo "test_review_base_resolution: ALL PASS"
else
  echo "test_review_base_resolution: FAIL"
fi
exit "$FAIL"
