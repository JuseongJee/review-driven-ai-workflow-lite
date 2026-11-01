#!/usr/bin/env bash
# resume_candidates.sh 단위 테스트. 임시 git 저장소 + tasks.local + 가짜 worktree 로 판정 규칙을 확인한다.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="${DIR}/resume_candidates.sh"
TMP="$(mktemp -d)" || { echo "test_resume_candidates.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_resume_candidates.sh: 임시 디렉터리 경로 검증 실패" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
FAIL=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }

TAB=$'\t'
N=0
# new_repo: 새 저장소를 만들고 R 에 경로를 둔다.
new_repo() { N=$((N+1)); R="$TMP/r$N"; mkdir -p "$R" && git -C "$R" init -q; mkdir -p "$R/.git/rd-workflow"; echo "schema=1" > "$R/.git/rd-workflow/tasks.local"; }
# mk <slug> <launch> <status> [dir=no|title=<x>|nostatus] : 색인 행 + 가짜 worktree
mk() {
  local slug="$1" launch="$2" status="$3" opt="${4:-}" wt="$R/wt/$1" title="$1"
  printf 'slug=%s\tfr-branch=fr/%s\tworktree-path=%s\tlaunch=%s\n' "$slug" "$slug" "$wt" "$launch" >> "$R/.git/rd-workflow/tasks.local"
  case "$opt" in dir=no) return ;; title=*) title="${opt#title=}" ;; esac
  mkdir -p "$wt/rd-workflow-workspace/.lifecycle"
  { echo "schema=1"; echo "short-title=$title"; [ "$opt" = nostatus ] || echo "status=$status"; } > "$wt/rd-workflow-workspace/.lifecycle/task-state"
}
# add_src <slug> <fr-slug> <worktree 사본 status|nofile> [cwd 사본 status] : task-state 에 source-fr 경로를 덧붙이고 items 사본을 만든다.
add_src() {
  local slug="$1" fr="$2" wst="$3" cst="${4:-}" rel ts wt="$R/wt/$1"
  rel="rd-workflow-workspace/backlog/items/2026-01-01-${fr}.md"
  ts="$wt/rd-workflow-workspace/.lifecycle/task-state"
  if grep -q '^source-fr=' "$ts"; then sed "s#^source-fr=.*#&|${rel}#" "$ts" > "$ts.new" && mv "$ts.new" "$ts"; else echo "source-fr=${rel}" >> "$ts"; fi
  if [ "$wst" != nofile ]; then mkdir -p "$wt/${rel%/*}"; printf '# %s\n- status: %s\n' "$fr" "$wst" > "$wt/$rel"; fi
  if [ -n "$cst" ]; then mkdir -p "$R/${rel%/*}"; printf '# %s\n- status: %s\n' "$fr" "$cst" > "$R/$rel"; fi
}
run() { OUT="$(cd "$R" && bash "$H" 2>&1)"; RC=$?; FIRST="${OUT%%$'\n'*}"; }
check() { # name expected-first expected-rc
  if [ "$FIRST" = "$2" ] && [ "$RC" -eq "$3" ]; then pass "$1"; else fail "$1 (first='$FIRST' rc=$RC, expected '$2' rc=$3)"; fi
}
has() { case "$OUT" in *"$2"*) pass "$1" ;; *) fail "$1 (출력에 '$2' 없음: $OUT)" ;; esac; }
hasnt() { case "$OUT" in *"$2"*) fail "$1 (출력에 '$2' 존재: $OUT)" ;; *) pass "$1" ;; esac; }

new_repo; mk a none "구현 중"; run
check "활성 후보 select" "select${TAB}a${TAB}$R/wt/a" 0

new_repo; mk a ok "구현 중"; run
check "launch=ok 제외" "none" 0
has "launch=ok 제외 다음 조치" "resolve-launch a --assume-ended"

new_repo; mk a none "완료"; run
check "완료 제외" "none" 0

new_repo; mk a none "구현 중" dir=no; run
check "worktree 부재 제외" "none" 0
has "worktree 부재 제외 사유" "worktree 부재"

new_repo; mk a unknown "구현 중"; run
check "launch 불확실" "undetermined" 3

new_repo; mk a none "구현 중" title=zzz; run
check "title 불일치" "undetermined" 3

new_repo; mk a none "구현 중" nostatus; run
check "status 정상 집합 (줄 없음)" "undetermined" 3
new_repo; mk a none "zzz"; run
check "status 정상 집합 (미지 값)" "undetermined" 3

new_repo; mk a none "구현 중"; mk b unknown "구현 중"; run
check "후보+불확실 공존" "select${TAB}a${TAB}$R/wt/a" 0
has "후보+불확실 공존 skip" "skip${TAB}b${TAB}불확실:"

new_repo; mk a none "구현 중"; mk b none "대기 중"; OUT="$(cd "$R" && RD_AUTOPILOT_FR=b bash "$H" 2>&1)"; RC=$?; FIRST="${OUT%%$'\n'*}"
check "명시 후보 우선" "select${TAB}b${TAB}$R/wt/b" 0
has "명시 후보 우선 skip" "skip${TAB}a${TAB}다른 후보(미선택)"
new_repo; mk a none "구현 중"; OUT="$(cd "$R" && RD_AUTOPILOT_FR=b bash "$H" 2>&1)"; RC=$?; FIRST="${OUT%%$'\n'*}"
check "명시 FR 지정 시 다른 작업 미재개" "none" 0
has "명시 FR 지정 시 다른 작업 미재개 skip" "skip${TAB}a${TAB}다른 후보(미선택, 명시 FR b 지정 중)"
new_repo; mk a none "구현 중"; OUT="$(cd "$R" && RD_AUTOPILOT_FR=auto bash "$H" 2>&1)"; RC=$?; FIRST="${OUT%%$'\n'*}"
check "auto 지정은 재개 유지" "select${TAB}a${TAB}$R/wt/a" 0
new_repo; mk b none "대기 중"; run
check "대기 중 후보 단독 select" "select${TAB}b${TAB}$R/wt/b" 0

new_repo; mk a none "구현 중"
printf 'slug=c\tfr-branch=fr/c\tworktree-path=%s\tlaunch=none\tstate=cleanup-pending\n' "$R/wt/c" >> "$R/.git/rd-workflow/tasks.local"; mkdir -p "$R/wt/c"; run
hasnt "cleanup-pending 미출력" "${TAB}c${TAB}"

# 3b: source-fr 의 FR 이 worktree 사본에서 blocked 이면 제외
new_repo; mk a none "대기 중"; add_src a fr-x blocked; run
check "blocked FR 제외" "none" 0
has "blocked FR 제외 사유" "FR blocked: fr-x ($R/wt/a/rd-workflow-workspace/backlog/items/2026-01-01-fr-x.md)"
has "blocked FR 제외 복구 문장" "그 worktree 에서 /fr status fr-x validated 로 복원하십시오. 이 작업의 blocked FR 을 모두 복원해야 다음 회차에 재개됩니다. 작업을 버리려면 promote_rollback.sh 를 쓰십시오."

new_repo; mk a none "대기 중"; add_src a fr-x idea; run
check "blocked 아님 재개" "select${TAB}a${TAB}$R/wt/a" 0

new_repo; mk a none "대기 중"; add_src a fr-x idea; add_src a fr-y blocked; run
check "복수 source-fr" "none" 0

new_repo; mk a none "대기 중"; add_src a fr-x nofile; run
check "읽기 불가 무시" "select${TAB}a${TAB}$R/wt/a" 0

new_repo; mk a none "대기 중"; add_src a fr-x blocked validated; run
check "worktree 권위 (worktree 만 blocked → 제외)" "none" 0
new_repo; mk a none "대기 중"; add_src a fr-x idea blocked; run
check "worktree 권위 (cwd 만 blocked → select)" "select${TAB}a${TAB}$R/wt/a" 0

new_repo; mk task-a none "대기 중"; add_src task-a fr-x blocked; run
has "복구 안내 대상" "/fr status fr-x validated"
hasnt "복구 안내 대상 (작업 slug 미사용)" "/fr status task-a"

new_repo; mk a none "대기 중"; add_src a fr-x blocked; add_src a fr-y blocked; run
n="$(printf '%s\n' "$OUT" | grep -c 'FR blocked')"
if [ "$n" -eq 2 ]; then pass "복수 blocked 안내 (skip 줄 2개)"; else fail "복수 blocked 안내 (skip 줄 $n 개: $OUT)"; fi
has "복수 blocked 안내 fr-x" "FR blocked: fr-x"
has "복수 blocked 안내 fr-y" "FR blocked: fr-y"
has "복수 blocked 안내 문구" "모두 복원"

N=$((N+1)); R="$TMP/r$N"; mkdir -p "$R"; git -C "$R" init -q; rm -rf "$R/.git/rd-workflow"; run
check "디렉터리 미생성 (none)" "none" 0
if [ ! -e "$R/.git/rd-workflow" ]; then pass "디렉터리 미생성"; else fail "디렉터리 미생성 (.git/rd-workflow 생성됨)"; fi

new_repo; mk a none "구현 중"; mk b ok "구현 중"
h1="$(git hash-object "$R/.git/rd-workflow/tasks.local")"; run
h2="$(git hash-object "$R/.git/rd-workflow/tasks.local")"
if [ "$h1" = "$h2" ]; then pass "색인 내용 불변"; else fail "색인 내용 불변 (해시 변경)"; fi

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$FAIL"
