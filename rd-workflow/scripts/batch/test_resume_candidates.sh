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
new_repo() { fakes_reset; N=$((N+1)); R="$TMP/r$N"; mkdir -p "$R" && git -C "$R" init -q; mkdir -p "$R/.git/rd-workflow"; echo "schema=1" > "$R/.git/rd-workflow/tasks.local"; }
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
# 대역: PATH 앞의 가짜 herdr·ps·lsof. 실행마다 $TMP/calls 에 "<명령> <첫 인자>" 한 줄을 덧붙인다.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/herdr" <<'FAKE'
#!/usr/bin/env bash
echo "herdr $1 $2" >> "$FAKE_CALLS"
case "$1 $2" in
  "agent list") [ -n "${FAKE_LIST_SLEEP:-}" ] && sleep "$FAKE_LIST_SLEEP"; cat "$FAKE_LIST" ;;
  "agent get")
    if [ -n "${FAKE_GET_OUT:-}" ]; then cat "$FAKE_GET_OUT"; exit 0; fi
    echo '{"error":{"code":"agent_not_found"}}' >&2; exit 1 ;;
esac
FAKE
cat > "$BIN/ps" <<'FAKE'
#!/usr/bin/env bash
echo "ps $1" >> "$FAKE_CALLS"
[ -n "${FAKE_PS_SLEEP:-}" ] && sleep "$FAKE_PS_SLEEP"
cat "$FAKE_PS"; exit 0
FAKE
cat > "$BIN/lsof" <<'FAKE'
#!/usr/bin/env bash
echo "lsof $1" >> "$FAKE_CALLS"
[ -n "${FAKE_LSOF_SLEEP:-}" ] && sleep "$FAKE_LSOF_SLEEP"
cat "$FAKE_LSOF"; exit 1
FAKE
# 대역 hc: `hc get <이름> --json` 만 흉내낸다. FAKE_HC 가 notfound|rc124|fail 이면 그 응답, 그 밖이면 그 파일을 낸다.
cat > "$BIN/hc" <<'FAKE'
#!/usr/bin/env bash
echo "hc $1 $2" >> "$FAKE_CALLS"
case "${FAKE_HC:-notfound}" in
  notfound) echo '{"error":{"kind":"not_found"}}' >&2; exit 3 ;;
  rc124) exit 124 ;;
  fail) echo 'boom' >&2; exit 1 ;;
  *) cat "$FAKE_HC"; exit 0 ;;
esac
FAKE
chmod +x "$BIN/herdr" "$BIN/ps" "$BIN/lsof" "$BIN/hc"
# fakes_reset: 케이스마다 대역 상태를 기본값(에이전트 없음·claude 프로세스 없음·이름 조회 부재)으로 되돌린다.
fakes_reset() {
  export FAKE_CALLS="$TMP/calls" FAKE_LIST="$TMP/fake.list" FAKE_PS="$TMP/fake.ps" FAKE_LSOF="$TMP/fake.lsof"
  : > "$FAKE_CALLS"; : > "$FAKE_PS"; : > "$FAKE_LSOF"
  echo '{"result":{"agents":[]}}' > "$FAKE_LIST"
  unset FAKE_LIST_SLEEP FAKE_PS_SLEEP FAKE_LSOF_SLEEP FAKE_GET_OUT FAKE_HC T_HERDR_ENV T_TIMEOUT T_HC
}
fakes_reset
# 조회 상한 기본값은 30초다. 대역은 즉시 답하므로 정상 경로는 기다리지 않는다. 5초였을 때 동시 실행 부하에서
# 대역 herdr 기동만으로 상한을 넘겨 「agent list 시간 초과」 로 판정이 바뀐 적이 있다(R8, 2026-11-07).
# 시간 초과 자체를 보는 사례(R7·R17)는 T_TIMEOUT 을 짧게 따로 준다.
run() { OUT="$(cd "$R" && PATH="$TMP/bin:$PATH" HERDR_ENV="${T_HERDR_ENV-1}" HC_TERMINAL_ID="${T_HC-}" RD_LAUNCH_TIMEOUT="${T_TIMEOUT:-30}" bash "$H" 2>&1)"; RC=$?; FIRST="${OUT%%$'\n'*}"; }
check() { # name expected-first expected-rc
  if [ "$FIRST" = "$2" ] && [ "$RC" -eq "$3" ]; then pass "$1"; else fail "$1 (first='$FIRST' rc=$RC, expected '$2' rc=$3)"; fi
}
has() { case "$OUT" in *"$2"*) pass "$1" ;; *) fail "$1 (출력에 '$2' 없음: $OUT)" ;; esac; }
hasnt() { case "$OUT" in *"$2"*) fail "$1 (출력에 '$2' 존재: $OUT)" ;; *) pass "$1" ;; esac; }

new_repo; mk a none "구현 중"; run
check "활성 후보 select" "select${TAB}a${TAB}$R/wt/a" 0

# R6 herdr 없음 — launch=ok 는 종료 판정 불가로 제외하고 수동 확정을 안내한다 (HERDR_ENV 명시 지정)
new_repo; mk a ok "구현 중"; T_HERDR_ENV="" run
check "R6 herdr 없음: launch=ok 제외" "none" 0
has "R6 판정 불가 사유" "종료 판정 불가: herdr 사용 불가"
has "R6 다음 조치" "resolve-launch a --assume-ended"

# R1 종료 — get 부재, list 는 다른 cwd, claude 프로세스 1개도 다른 cwd → 후보, info 줄, 색인 불변
new_repo; mk a ok "구현 중"
echo '{"result":{"agents":[{"cwd":"/elsewhere/x"}]}}' > "$FAKE_LIST"
echo "99999 claude" > "$FAKE_PS"; printf 'p99999\nn/elsewhere/y\n' > "$FAKE_LSOF"
h1="$(git hash-object "$R/.git/rd-workflow/tasks.local")"; run
check "R1 종료 확인 → select" "select${TAB}a${TAB}$R/wt/a" 0
has "R1 info 줄" "info${TAB}a${TAB}대화형 세션 종료 확인(launch=ok, herdr·프로세스 어디에도 세션 없음)${TAB}색인의 launch 값은 바꾸지 않았습니다"
h2="$(git hash-object "$R/.git/rd-workflow/tasks.local")"
[ "$h1" = "$h2" ] && grep -q 'launch=ok' "$R/.git/rd-workflow/tasks.local" && pass "R1 색인 launch=ok 불변" || fail "R1 색인 launch=ok 불변"
hasnt "R1 --assume-ended 안내 없음" "--assume-ended"

# R2 이름 없는 에이전트 생존
new_repo; mk a ok "구현 중"; echo '{"result":{"agents":[{"cwd":"'"$R"'/wt/a/sub"}]}}' > "$FAKE_LIST"; run
check "R2 첫 줄" "none" 0
has "R2 skip 살아 있음" "대화형 세션 살아 있음(herdr 에이전트 cwd 일치)"
has "R2 다음 조치" "세션이 끝나면 다음 회차에 자동으로 재개 후보가 됩니다"

# R3 foreground_cwd 만 일치 (AC2a)
new_repo; mk a ok "구현 중"; echo '{"result":{"agents":[{"cwd":"/elsewhere","foreground_cwd":"'"$R"'/wt/a"}]}}' > "$FAKE_LIST"; run
check "R3 첫 줄" "none" 0
has "R3 skip 살아 있음" "대화형 세션 살아 있음(herdr 에이전트 cwd 일치)"

# R4 herdr 밖 claude 프로세스
new_repo; mk a ok "구현 중"; echo "99999 claude" > "$FAKE_PS"; printf 'p99999\nn%s/wt/a\n' "$R" > "$FAKE_LSOF"; run
check "R4 첫 줄" "none" 0
has "R4 skip 살아 있음" "대화형 세션 살아 있음(claude 프로세스 cwd 일치)"

# R5 이름 조회 생존
new_repo; mk a ok "구현 중"; echo '{"result":{"agent":{"name":"a","cwd":"'"$R"'/wt/a"}}}' > "$TMP/get.out"; export FAKE_GET_OUT="$TMP/get.out"; run
check "R5 첫 줄" "none" 0
has "R5 skip 살아 있음" "대화형 세션 살아 있음(herdr 에이전트 a 생존)"

# R7 list 시간 초과 (AC3a)
new_repo; mk a ok "구현 중"; export FAKE_LIST_SLEEP=3; T_TIMEOUT=1 run
check "R7 첫 줄" "none" 0
has "R7 판정 불가" "종료 판정 불가: agent list 시간 초과"
unset FAKE_LIST_SLEEP

# R8 cwd 미관측 — 살아 있는 pid($$) 에 lsof n 줄 없음
new_repo; mk a ok "구현 중"; echo "$$ claude" > "$FAKE_PS"; echo "p$$" > "$FAKE_LSOF"; run
check "R8 첫 줄" "none" 0
has "R8 판정 불가" "종료 판정 불가: cwd 미관측"

# R9 list 항목 cwd 부재
new_repo; mk a ok "구현 중"; echo '{"result":{"agents":[{"name":"x"}]}}' > "$FAKE_LIST"; run
check "R9 첫 줄" "none" 0
has "R9 판정 불가" "종료 판정 불가: agent list 항목의 cwd 부재"

# R10 관측 1회 — launch=ok 종료 작업 2건
new_repo; mk a ok "구현 중"; mk b ok "구현 중"; run
check "R10 select a" "select${TAB}a${TAB}$R/wt/a" 0
has "R10 b 는 미선택 후보" "skip${TAB}b${TAB}다른 후보(미선택)"
[ "$(grep -c '^herdr agent list' "$TMP/calls")" -eq 1 ] && pass "R10 agent list 1회" || fail "R10 agent list 1회 아님: $(cat "$TMP/calls")"
[ "$(grep -c '^ps' "$TMP/calls")" -eq 1 ] && pass "R10 ps 1회" || fail "R10 ps 1회 아님: $(cat "$TMP/calls")"

# R11 심링크 worktree 경로 — 색인은 링크, list 의 cwd 는 물리 경로
new_repo; mk a ok "구현 중"; ln -s "$R/wt/a" "$TMP/link$N"
sed "s#worktree-path=$R/wt/a#worktree-path=$TMP/link$N#" "$R/.git/rd-workflow/tasks.local" > "$TMP/idx.new" && cp "$TMP/idx.new" "$R/.git/rd-workflow/tasks.local"
phys="$(cd "$R/wt/a" && pwd -P)"; echo '{"result":{"agents":[{"cwd":"'"$phys"'"}]}}' > "$FAKE_LIST"; run
check "R11 첫 줄" "none" 0
has "R11 skip 살아 있음" "대화형 세션 살아 있음(herdr 에이전트 cwd 일치)"

# R12 접두만 같은 경로(wt/ab)는 다른 worktree
new_repo; mk a ok "구현 중"; echo '{"result":{"agents":[{"cwd":"'"$R"'/wt/ab"}]}}' > "$FAKE_LIST"; run
check "R12 select a" "select${TAB}a${TAB}$R/wt/a" 0

# R13 launch=ok 작업이 없으면 대역을 부르지 않는다
new_repo; mk a none "구현 중"; run
check "R13 첫 줄" "select${TAB}a${TAB}$R/wt/a" 0
[ ! -s "$TMP/calls" ] && pass "R13 호출 기록 없음" || fail "R13 호출 기록 있음: $(cat "$TMP/calls")"

# R14 이름 조회 성공이지만 cwd 가 worktree 밖 (F1)
new_repo; mk a ok "구현 중"; echo '{"result":{"agent":{"name":"a","cwd":"/elsewhere"}}}' > "$TMP/get.out"; export FAKE_GET_OUT="$TMP/get.out"; run
check "R14 select 하지 않음" "none" 0
has "R14 판정 불가" "종료 판정 불가: 이름 조회 성공 — worktree 밖 cwd"

# R15 list 혼합 (F2) — worktree cwd 항목 + cwd 없는 항목
new_repo; mk a ok "구현 중"; echo '{"result":{"agents":[{"cwd":"'"$R"'/wt/a"},{"name":"x"}]}}' > "$FAKE_LIST"; run
check "R15 첫 줄" "none" 0
has "R15 skip 살아 있음" "대화형 세션 살아 있음(herdr 에이전트 cwd 일치)"
hasnt "R15 --assume-ended 안내 없음" "--assume-ended"

# R16 프로세스 혼합 (F2) — $$ 는 cwd 미관측, 다른 pid 가 worktree cwd
new_repo; mk a ok "구현 중"; printf '%s claude\n99998 claude\n' "$$" > "$FAKE_PS"; printf 'p99998\nn%s/wt/a\n' "$R" > "$FAKE_LSOF"; run
check "R16 첫 줄" "none" 0
has "R16 skip 살아 있음" "대화형 세션 살아 있음(claude 프로세스 cwd 일치)"
hasnt "R16 --assume-ended 안내 없음" "--assume-ended"

# R17 프로세스 관측 공통 상한 (F3) — ps·lsof 각 0.6초, 상한 1초
new_repo; mk a ok "구현 중"; echo "99999 claude" > "$FAKE_PS"; printf 'p99999\nn/elsewhere\n' > "$FAKE_LSOF"
export FAKE_PS_SLEEP=1 FAKE_LSOF_SLEEP=1; T_TIMEOUT=1 run
check "R17 첫 줄" "none" 0
has "R17 판정 불가" "종료 판정 불가: 프로세스 관측 시간 초과"
unset FAKE_PS_SLEEP FAKE_LSOF_SLEEP

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

new_repo; mk a none "대기 중"; add_src a fr-x "blocked (사유)"; run
check "blocked (사유) FR 제외" "none" 0

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

# --- H: herdr app(hc) 로 기동한 작업 (spec C6·T5). 색인 줄에 launch-backend 를 붙인다.
# sed -i 는 BSD sed 에서 다음 인자를 백업 접미사로 읽어 실패한다(PATH 에 GNU sed 가 없는 환경). 임시 파일로 고쳐 쓴다.
mk_hc() { mk "$1" ok "구현 중"; sed "\$s/\$/${TAB}launch-backend=${2:-hc}/" "$R/.git/rd-workflow/tasks.local" > "$TMP/idx.hc" && cp "$TMP/idx.hc" "$R/.git/rd-workflow/tasks.local"; }
hc_json() { printf '%s' "$1" > "$TMP/fake.hc"; export FAKE_HC="$TMP/fake.hc"; }

# H1 hc 종료 — herdr 없음(목록 관측 불완전)이어도 hc 이름 조회 부재 + 프로세스 부재면 후보
new_repo; mk_hc a; T_HERDR_ENV="" T_HC=t1 run
check "H1 hc 종료 → select" "select${TAB}a${TAB}$R/wt/a" 0
has "H1 hc info 줄" "info${TAB}a${TAB}대화형 세션 종료 확인(launch=ok, herdr app·프로세스 어디에도 세션 없음)"
# H2 hc 생존
new_repo; mk_hc a; hc_json "{\"state\":\"live\",\"cwd\":\"$R/wt/a\"}"; T_HC=t1 run
check "H2 hc 생존 → 제외" "none" 0
has "H2 생존 사유" "대화형 세션 살아 있음(hc 세션 a 생존)"
# H3 hc 끝난 터미널
new_repo; mk_hc a; hc_json '{"state":"finished","cwd":"/elsewhere"}'; T_HC=t1 run
check "H3 hc finished → select" "select${TAB}a${TAB}$R/wt/a" 0
# H4 hc 사용 불가 — 대역 hc 가 PATH 에 있어도 HC_TERMINAL_ID 가 없으면 판정 불가
new_repo; mk_hc a; T_HC="" run
check "H4 hc 사용 불가 → 제외" "none" 0
has "H4 사유" "종료 판정 불가: hc 사용 불가"
has "H4 다음 조치" "resolve-launch a --assume-ended"
# H5 기록 이상 백엔드
new_repo; mk_hc a none; T_HC=t1 run
check "H5 기록 이상 → 제외" "none" 0
has "H5 사유" "종료 판정 불가: 기동 백엔드 기록 이상(none)"
# H6 live 이지만 worktree 밖 cwd / H7 live 인데 cwd 없음 — 성공한 이름 조회는 부재가 아니다
new_repo; mk_hc a; hc_json '{"state":"live","cwd":"/elsewhere"}'; T_HC=t1 run
check "H6 live·밖 cwd → 제외" "none" 0
has "H6 사유" "종료 판정 불가: 이름 조회 성공 — worktree 밖 cwd"
has "H6 다음 조치" "resolve-launch a --assume-ended"
new_repo; mk_hc a; hc_json '{"state":"live"}'; T_HC=t1 run
check "H7 live·cwd 없음 → 제외" "none" 0
has "H7 사유" "종료 판정 불가: 이름 조회 성공 — worktree 밖 cwd"
# H8 시간 초과(대역이 즉시 rc 124) / H9 일반 실패 / H10 state 이상
new_repo; mk_hc a; export FAKE_HC=rc124; T_HC=t1 run
has "H8 사유" "종료 판정 불가: hc get 시간 초과"
new_repo; mk_hc a; export FAKE_HC=fail; T_HC=t1 run
has "H9 사유" "종료 판정 불가: hc get 실패"
new_repo; mk_hc a; hc_json '{"state":"starting","cwd":"/x"}'; T_HC=t1 run
has "H10a 사유" "종료 판정 불가: hc get 응답 형식 이상"
new_repo; mk_hc a; hc_json '{"cwd":"/x"}'; T_HC=t1 run
has "H10b 사유" "종료 판정 불가: hc get 응답 형식 이상"

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$FAIL"
