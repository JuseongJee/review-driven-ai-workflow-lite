#!/usr/bin/env bash
# test_verify_record.sh — verify_record.sh 의 증거 기록 계약을 임시 저장소 fixture 로 검증합니다.
#
# 이 파일이 막는 실수:
#   - 실패한 검증이 증거를 남기거나, 이전 통과 증거가 남아 재사용되는 것
#   - 검증 중·후에 보호 경로가 바뀌었는데 증거가 남는 것
#   - 증거 기록이 보호 트리 해시를 바꿔 seal 이 스스로 무효가 되는 것
#
# 제약: bash 3.2 호환 (연관배열·mapfile 금지).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
eq()   { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대=[$2] 실제=[$1])"; fi; }
has()  { case "$2" in *"$1"*) pass "$3" ;; *) fail "$3 (문구 없음: ${1})" ;; esac; }

WORK="$(mktemp -d)" || { echo "test_verify_record.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "test_verify_record.sh: 임시 디렉터리 경로 검증 실패" >&2; exit 1; }
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

EV_REL="rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"

mk_repo() {
  local d
  d="$(mktemp -d "${WORK}/repo.XXXXXX")" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  git init -q -b main "$d" 2>/dev/null || return 1
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  mkdir -p "${d}/rd-workflow/scripts" "${d}/rd-workflow-workspace/.lifecycle"
  cp "${SCRIPT_DIR}/verify_record.sh" "${SCRIPT_DIR}/_state_common.sh" "${d}/rd-workflow/scripts/" || return 1
  printf 'schema=1\n' > "${d}/rd-workflow-workspace/.lifecycle/task-state"
  printf 'seed\n' > "${d}/code.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m base
  printf '%s\n' "$d"
}

# vr <repo> <명령...> — verify_record 실행. 출력은 $WORK/vr.out (stdout+stderr), rc 는 반환값
vr() {
  local repo="$1"; shift
  ( cd "$repo" && bash rd-workflow/scripts/verify_record.sh -- "$@" ) >"${WORK}/vr.out" 2>&1
}

hash_head() { ( project_root="$1"; export project_root; source "${1}/rd-workflow/scripts/_state_common.sh"; rd_protected_tree_hash HEAD ); }
kv() { awk -F'=' -v k="$2" '$1==k{sub(/^[^=]+=/,"");print;exit}' "$1"; }

echo "=== verify_record.sh ==="

# 통과 명령
R="$(mk_repo)" || { echo "  FAIL  fixture 생성 실패"; exit 1; }
vr "$R" true; rc=$?
eq "$rc" "0" "통과 명령: exit 0"
eq "$(kv "${R}/${EV_REL}" exit-code)" "0" "통과 명령: exit-code=0"
eq "$(kv "${R}/${EV_REL}" command)" "true" "통과 명령: command 기록"
eq "$(kv "${R}/${EV_REL}" tree-hash)" "$(hash_head "$R")" "통과 명령: tree-hash == 보호 트리 해시"

# 증거를 커밋해도 보호 트리 해시가 변하지 않아야 seal 이 자기 증거 때문에 무효가 되지 않습니다.
H0="$(hash_head "$R")"
git -C "$R" add -A && git -C "$R" commit -q -m evidence
eq "$(hash_head "$R")" "$H0" "증거 커밋 전후 보호 트리 해시 동일"

# 실패 명령 + 기존 증거 → 증거 삭제
vr "$R" false; rc=$?
eq "$rc" "1" "실패 명령: 래퍼 exit 1"
[ -e "${R}/${EV_REL}" ] && fail "기존 증거 있음 + 실패 명령: 증거 삭제됨" || pass "기존 증거 있음 + 실패 명령: 증거 삭제됨"

# 처음부터 실패 → 증거 없음
R2="$(mk_repo)" || exit 1
vr "$R2" false; rc=$?
[ -e "${R2}/${EV_REL}" ] && fail "실패 명령: 증거 없음" || pass "실패 명령: 증거 없음"

# 래퍼의 내부 변수가 검증 명령의 환경으로 새지 않는다 — project_root 가 새면 검증 명령(테스트 fixture·rd)이
# 임시 repo 가 아니라 이 저장소를 대상으로 돌아 task-state·마커를 덮어씁니다 (실제 사고).
R6="$(mk_repo)" || exit 1
vr "$R6" bash -c '[ -z "${project_root+x}" ]'; rc=$?
eq "$rc" "0" "검증 명령 환경에 project_root 가 새지 않음"

# 기록된 command 를 그대로 다시 실행하면 같은 argv 가 전달된다 — 인자 경계(공백·따옴표)가 보존돼야
# 증거와 재실행 안내가 사용자가 실제로 칠 수 있는 명령이 됩니다.
R7="$(mk_repo)" || exit 1
vr "$R7" bash -c 'test -f code.txt'; rc=$?
eq "$rc" "0" "인자 경계: 공백·따옴표 인자 명령이 통과"
REC="$(kv "${R7}/${EV_REL}" command)"
( cd "$R7" && eval "bash rd-workflow/scripts/verify_record.sh -- ${REC}" ) >"${WORK}/vr2.out" 2>&1; rc=$?
eq "$rc" "0" "인자 경계: 기록된 command 재실행 성공 (기록: ${REC})"

# 보호 경로 미커밋 변경
R3="$(mk_repo)" || exit 1
printf 'dirty\n' >> "${R3}/code.txt"
vr "$R3" true; rc=$?
eq "$rc" "1" "미커밋 보호 변경: exit 1"
has "커밋한 뒤" "$(cat "${WORK}/vr.out")" "미커밋 보호 변경: 안내 문구"
[ -e "${R3}/${EV_REL}" ] && fail "미커밋 보호 변경: 증거 없음" || pass "미커밋 보호 변경: 증거 없음"

# 실행 중 보호 파일 커밋
R4="$(mk_repo)" || exit 1
vr "$R4" bash -c 'echo more >> code.txt && git add code.txt && git commit -q -m mid'; rc=$?
eq "$rc" "1" "실행 중 보호 파일 커밋: exit 1"
has "검증 중 보호 경로가 바뀌었습니다" "$(cat "${WORK}/vr.out")" "실행 중 보호 파일 커밋: 재실행 안내"
has "verify_record.sh -- bash -c" "$(cat "${WORK}/vr.out")" "실행 중 보호 파일 커밋: 재실행 명령 포함"
[ -e "${R4}/${EV_REL}" ] && fail "실행 중 보호 파일 커밋: 증거 없음" || pass "실행 중 보호 파일 커밋: 증거 없음"

# 명령이 보호 파일을 수정만 하고 커밋하지 않음
R5="$(mk_repo)" || exit 1
vr "$R5" bash -c 'echo more >> code.txt'; rc=$?
eq "$rc" "1" "미커밋 보호 변경을 남김: exit 1"
[ -e "${R5}/${EV_REL}" ] && fail "미커밋 보호 변경을 남김: 증거 없음" || pass "미커밋 보호 변경을 남김: 증거 없음"

# 개행 포함 인자
R6="$(mk_repo)" || exit 1
vr "$R6" echo $'a\nb'; rc=$?
eq "$rc" "1" "개행 포함 인자: exit 1"
[ -e "${R6}/${EV_REL}" ] && fail "개행 포함 인자: 증거 없음" || pass "개행 포함 인자: 증거 없음"

if [ "$FAIL" = 0 ]; then echo "test_verify_record: ALL PASS"; else echo "test_verify_record: FAIL"; fi
exit "$FAIL"
