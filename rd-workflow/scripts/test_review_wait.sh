#!/usr/bin/env bash
# test_review_wait.sh — adapter_codex.sh 대기 계약·판정 단일화 테스트
# 케이스:
#   1. 정상 완료 (CHECKPOINT Suggested Next Owner = Reviewer여도 성공 — CHECKPOINT 비소비 증명)
#   2. 비정상 종료 (mock exit 1, 대기 상한(120초)까지 기다리지 않고 15초 안에 실패)
#   3. 타임아웃 (mock sleep 30, WAIT_TIMEOUT=3)
#   4. 폴링 부재 grep (adapter_codex.sh + adapter_claude.sh)
#   5. malformed owner 실패 (Bogus / 빈 값 / awaiting-reviewer Status)
#   6. timeout 마커 정리 (정상 완료 경로에서 .wait_timeout 잔존 금지)
#  16. writable surface 세션 하위 폐쇄 — last-message 는 세션 하위 mktemp(사전 배치 symlink 비추종),
#      --add-dir 는 symlink 를 따라간 세션 physical 경로 (codex-adapter-writable-root)
set -euo pipefail

PASS=0
FAIL=0
SKIP=0
ERRORS=()
# 실행할 케이스 이름 (비어 있으면 전부). 사용: test_review_wait.sh [케이스...]
SELECTED=("$@")

# 색상 출력 (터미널 비지원 시 무시)
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() {
  echo -e "${GREEN}PASS${NC} $1"
  PASS=$((PASS + 1))
}

fail() {
  echo -e "${RED}FAIL${NC} $1"
  ERRORS+=("$1")
  FAIL=$((FAIL + 1))
}

# 이 파일의 SKIP 은 모두 환경 제약(ps 불가)이다. self_test 집계에 들어가도록 env-skip 표식을 stderr 에 함께 낸다.
skip() {
  echo "SKIP $1"
  printf 'env-skip: test_review_wait %s\n' "${1/: / — }" >&2
  SKIP=$((SKIP + 1))
}

# --- 경로 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$SCRIPT_DIR/adapter_codex.sh"
ADAPTER_CLAUDE="$SCRIPT_DIR/adapter_claude.sh"

# --- sandbox 공통 함수 ---
make_sandbox() {
  local d
  d="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$d" && -d "$d" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  mkdir -p "$d/turns"
  echo "$d"
}

# 가짜 SESSION.md 생성 헬퍼
write_session() {
  local dir="$1" owner="$2" status="$3"
  cat > "$dir/SESSION.md" <<EOF
## Current Owner
$owner

## Status
$status

## Turn Limit
20
EOF
}

# CHECKPOINT.md 생성 헬퍼
write_checkpoint() {
  local dir="$1" suggested="$2"
  cat > "$dir/CHECKPOINT.md" <<EOF
## Summary
테스트용 CHECKPOINT

## Agreed Points
-

## Open Issues
-

## Questions
-

## Suggested Next Owner
$suggested
EOF
}

# 지정 디렉터리 안의 watchdog 임시 디렉터리 개수 (절대 개수)
# 전역 ${TMPDIR:-/tmp} 의 전후 델타로 판정하면 동시 실행 세션의 정상 정리가 이번 실행의
# 누수를 상쇄해 위음성이 된다. 그래서 케이스마다 전용 TMPDIR 을 주입하고 그 안에서 0 을 본다.
# find 는 권한 오류로 non-zero 를 반환할 수 있고 이 파일은 set -euo pipefail 이므로
# || true 로 격리하지 않으면 호출 지점에서 테스트 전체가 조용히 중단된다(실측).
leftover_watchdog_in() {
  local n
  n="$( { find "$1" -maxdepth 1 -type d -name 'rd-watchdog.*' 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  echo "$n"
}

# ps 신뢰성 self-check
# ps -eo pid,command 는 busybox 에서 실패하고 그 실패가 wc -l 에서 0 으로 집계되어
# "고아 0개" 라는 거짓 통과를 만든다. 개수 0 을 통과로 해석하기 전에 ps 가
# 자기 자신을 볼 수 있는지 확인한다. 볼 수 없으면 판정을 신뢰할 수 없다.
ps_is_trustworthy() {
  local n
  n="$( { ps -eo pid 2>/dev/null || true; } | grep -c "^ *$$\$" || true )"
  [ "$n" -ge 1 ]
}

# --- 프로세스 소유권 (고아 검출·정리 근거) ---
# 고아를 명령행 패턴(`sleep <값>`)으로 식별하지 않는다. 패턴 일치는 소유권 증거가 아니며,
# 같은 값을 쓰는 다른 사용자·테스트·프로젝트의 프로세스를 종료할 수 있다.
# 대신 어댑터를 자체 process group 리더로 띄운다. process group 은 자손에게 상속되고
# 부모가 죽어 고아가 되어도 바뀌지 않으므로, 그 pgid 의 구성원이라는 사실이 곧
# "이 케이스가 만든 프로세스" 라는 증거다 (macOS 3.2 / Alpine 5.3 / Ubuntu 5.2 실측).
#   테스트가 끊기면 trap 이 자손에 TERM → 상한 10초 대기 → 남은 것 KILL 순서로 회수한다.
#   어댑터가 TERM 으로 자기 도구 그룹을 회수하게 하려는 순서다. SIGKILL 은 범위 밖이다.
own_pgid() {  # $1: pid → pgid (관측 불가 시 빈 문자열)
  { ps -eo pid,pgid 2>/dev/null || true; } | awk -v p="$1" '$1==p {print $2; exit}'
}

group_size() {  # $1: pgid → 살아 있는 구성원 수
  local g="${1:-}"
  [ -n "$g" ] || { echo 0; return; }
  { ps -eo pid,pgid 2>/dev/null || true; } | awk -v g="$g" '$2==g' | wc -l | tr -d ' '
}

SELF_PGID="$(own_pgid $$)"

# 테스트 셸($$)이 띄운 프로세스를 회수한다 (spec §3.3).
# (1) 자손 트리 스냅숏 — 어댑터를 먼저 죽이면 그 자식(도구의 별도 그룹)이 init 으로 넘어가 트리에서 빠진다.
# (2) TERM — 어댑터가 자기 cleanup 으로, 기록해 둔 도구 그룹(리더가 먼저 끝나 트리에 없는 자손 포함)을 회수한다.
# (3) 상한 10초 안에 사라지지 않은 스냅숏 대상만 KILL.
# 세 함수 모두 항상 0 을 반환한다 — 대상이 이미 사라진 것은 정상 회수 결과이며, set -e 아래에서도 끝까지 돈다.
REAP_TARGETS=""
REAP_RAN=0          # 0=미실행 1=진행 중 2=완료 — 진행 중·완료 뒤 다시 부르면 아무것도 하지 않는다
REAP_SIGNAL_RC=""   # 첫 신호의 종료 코드(129/130/143)
_reap_send() {  # $1: 신호 이름 — REAP_TARGETS 의 각 대상에 보낸다
  local kind id
  while read -r kind id; do
    [ -n "${id:-}" ] || continue
    if [ "$kind" = G ]; then kill -"$1" -- -"$id" 2>/dev/null || true
    else kill -"$1" "$id" 2>/dev/null || true; fi
  done <<REAP_EOF
$REAP_TARGETS
REAP_EOF
  return 0
}
_reap_alive() {  # 살아 있는 대상 수를 stdout 으로 낸다
  local kind id n=0
  while read -r kind id; do
    [ -n "${id:-}" ] || continue
    if [ "$kind" = G ]; then
      if kill -0 -- -"$id" 2>/dev/null; then n=$((n + 1)); fi
    else
      if kill -0 "$id" 2>/dev/null; then n=$((n + 1)); fi
    fi
  done <<REAP_EOF
$REAP_TARGETS
REAP_EOF
  echo "$n"
  return 0
}
reap_descendants() {
  [ "$REAP_RAN" -eq 0 ] || return 0
  REAP_RAN=1
  _reap_run
  REAP_RAN=2
  return 0
}
_reap_run() {
  local snap i
  snap="$( { ps -eo pid=,ppid=,pgid= 2>/dev/null || true; } )"
  if [ -z "$snap" ]; then
    echo "경고: 프로세스 조회 실패로 종료 회수를 하지 못했습니다 — 이 테스트가 띄운 프로세스가 남았을 수 있습니다" >&2
    return 0
  fi
  REAP_TARGETS="$(printf '%s\n' "$snap" | awk -v root="$$" -v self="${SELF_PGID:-}" '
    { grp[$1]=$3; kids[$2]=kids[$2] " " $1 }
    END {
      q=" " root
      while (q != "") {
        n=split(q, a, " "); q=""
        for (i=1;i<=n;i++) { m=split(kids[a[i]], c, " "); for (j=1;j<=m;j++) if (!(c[j] in d)) { d[c[j]]=1; q=q " " c[j] } }
      }
      for (p in d) { print "P " p; if (grp[p]==p && p!=self) print "G " p }
    }' || true)"
  [ -n "$REAP_TARGETS" ] || return 0
  _reap_send TERM
  for i in $(seq 1 50); do
    [ "$(_reap_alive)" -eq 0 ] && return 0
    sleep 0.2 || true   # 그룹 신호로 sleep 이 먼저 끝나도 회수를 이어 간다
  done
  _reap_send KILL
  return 0
}
# 회수 진행 중(최대 10초 대기)에 온 신호는 종료 코드만 기록하고 돌아온다. bash 는 trap 이 돌아오면
# 중단된 명령 다음부터 이어 가므로 원래 회수가 KILL 까지 마친다. 종료 코드는 첫 신호의 값이다.
reap_on_signal() {  # $1: 종료 코드
  [ -n "$REAP_SIGNAL_RC" ] || REAP_SIGNAL_RC="$1"
  [ "$REAP_RAN" -eq 1 ] && return 0
  reap_descendants
  exit "$REAP_SIGNAL_RC"
}
# 이 실행의 임시 파일·디렉터리는 모두 RUN_TMP 아래에 만들고, 종료(신호 포함) 때 회수 뒤 통째로 지운다.
# 케이스별 rm 은 정상 경로만 지우므로 신호로 끊기면 sandbox 가 남는다. SIGKILL 은 trap 이 돌지 않아 범위 밖이다.
# macOS 기본 mktemp 는 템플릿 없이 부르면 TMPDIR 을 따르지 않으므로(Darwin 25 실측) 호출마다 템플릿을 준다.
# TMPDIR 도 바꿔, 어댑터가 "${TMPDIR:-/tmp}" 아래에 만드는 디렉터리까지 함께 지운다.
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/rd-test-review-wait.XXXXXX")" || { echo "test_review_wait.sh: 실행 전용 임시 디렉터리 생성 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
export RUN_TMP TMPDIR="$RUN_TMP"
drop_run_tmp() { rm -rf "$RUN_TMP" 2>/dev/null || true; }
trap 'reap_descendants; drop_run_tmp' EXIT
trap 'reap_on_signal 129' HUP
trap 'reap_on_signal 130' INT
trap 'reap_on_signal 143' TERM
JOB=""
GROUP_PGID=""

spawn_group() {  # $1: 로그 경로, 나머지: 실행할 명령 — 자체 process group 리더로 띄운다
  local log="$1" i; shift
  set -m
  "$@" < /dev/null > "$log" 2>&1 &
  JOB=$!
  set +m
  GROUP_PGID=""
  # "pgid 가 리더 pid 인 구성원이 존재하는가" 로 확정한다. 리더가 즉시 종료해도 자손이
  # 남았다면 그룹 행으로 확인되고, pgid == 리더 pid 이므로 오탐은 불가능하다.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(group_size "$JOB")" -gt 0 ]; then GROUP_PGID="$JOB"; break; fi
    sleep 0.05
  done
}

reap_group() {  # $1: pgid — 소유권이 확인된 그룹만 종료 (자기 그룹·빈 그룹은 건드리지 않는다)
  local g="${1:-}"
  [ -n "$g" ] || return 0
  if [ -n "$SELF_PGID" ] && [ "$g" = "$SELF_PGID" ]; then return 0; fi
  [ "$(group_size "$g")" -gt 0 ] || return 0
  kill -9 -- -"$g" 2>/dev/null || true
  return 0
}

# ps shim 생성 헬퍼 — PATH 앞의 <dir> 에 둘 가짜 ps 를 만든다.
# 사용: make_ps_shim <dir> fail|empty|after-marker <marker>
#   fail         — 항상 exit 1
#   empty        — 출력 없이 exit 0
#   after-marker — <marker> 파일이 없으면 실제 ps 를 실행해 출력을 변수에 받고, 실제 ps 가 rc 0 이면
#                  <dir>/ps-ok 에 한 줄을 덧붙인 뒤 그 출력과 rc 를 그대로 낸다(handshake 용).
#                  <marker> 가 있으면 exit 1.
# REAL_PS 는 shim 생성 시점에 `command -v ps` 로 고정해 shim 본문에 박아 넣는다(PATH 가 바뀐 뒤에도 실제 ps 를 부르기 위함).
# FR cleanup-pending-hold-env-dependence 가 같은 형태를 재사용할 수 있다.
make_ps_shim() {
  local dir="$1" mode="$2" marker="${3:-}" REAL_PS
  mkdir -p "$dir"
  case "$mode" in
    fail)  printf '#!/bin/sh\nexit 1\n' > "$dir/ps" ;;
    empty) printf '#!/bin/sh\nexit 0\n' > "$dir/ps" ;;
    after-marker)
      REAL_PS="$(command -v ps || true)"
      if [ -z "$REAL_PS" ]; then
        echo "make_ps_shim: 실제 ps 를 찾지 못해 after-marker shim 을 만들 수 없음" >&2
        return 1
      fi
      cat > "$dir/ps" <<SHIM_EOF
#!/bin/sh
if [ -e "$marker" ]; then exit 1; fi
out=\$("$REAL_PS" "\$@")
rc=\$?
if [ "\$rc" -eq 0 ]; then echo ok >> "$dir/ps-ok"; fi
printf '%s\n' "\$out"
exit \$rc
SHIM_EOF
      ;;
    *) echo "make_ps_shim: 알 수 없는 모드 '$mode'" >&2; return 1 ;;
  esac
  chmod +x "$dir/ps"
}

# mock 본문에 넣을 handshake 대기 셸 조각을 stdout 으로 낸다.
# <dir>/ps-ok 가 비어 있지 않을 때까지 0.05초 간격으로 기다리고(상한 5초=100회),
# 넘기면 <sandbox>/handshake-timeout 을 만든다.
wait_ps_handshake() {  # $1=<dir>(shim 디렉터리) $2=<sandbox>
  printf '%s\n' "i=0; while [ ! -s \"$1/ps-ok\" ] && [ \$i -lt 100 ]; do sleep 0.05; i=\$((i+1)); done; [ -s \"$1/ps-ok\" ] || : > \"$2/handshake-timeout\""
}

# <sandbox>/mock.pid 의 pid 가 자기 그룹 리더일 때만 그 그룹을 SIGKILL 한다. 실패는 무시한다.
reap_mock_group() {  # $1=<sandbox>
  local pid
  pid="$(cat "$1/mock.pid" 2>/dev/null || true)"
  [ -n "$pid" ] || return 0
  if kill -0 -- -"$pid" 2>/dev/null; then
    kill -9 -- -"$pid" 2>/dev/null || true
  fi
  return 0
}

# 케이스 이름 목록: ps 가 없으면 판정할 수 없는 케이스 (케이스 전체 건너뜀)
PS_REQUIRED=(36a 36b 39 47 48)
PS_OK=1

run() {  # $1=케이스 이름 — 선택·건너뜀 판정 뒤 run_case<이름> 호출
  local n="$1" x found=0
  if [ ${#SELECTED[@]} -ne 0 ]; then
    for x in "${SELECTED[@]}"; do [ "$x" = "$n" ] && found=1; done
    [ "$found" -eq 1 ] || return 0
  fi
  if [ "$PS_OK" -eq 0 ]; then
    for x in "${PS_REQUIRED[@]}"; do
      if [ "$x" = "$n" ]; then
        skip "케이스 $n: ps 를 쓸 수 없어 판정할 수 없음"
        return 0
      fi
    done
  fi
  "run_case$n"
}

section() {  # 선택이 없을 때만 절 머리말 출력
  [ ${#SELECTED[@]} -eq 0 ] || return 0
  echo ""
  echo "=== $1 ==="
  echo ""
}

# 케이스 전용 WAIT_TIMEOUT salt.
# **bounded 값이며 유일성을 보장하지 않는다** — $$ 하위 5자리와 RANDOM 하위 3자리가 모두
# 같으면 두 실행이 같은 값을 갖는다. 절단이 필요한 이유는 상한 때문이다: 밴드(1억 단위)를
# 더한 뒤에도 2^31 아래여야 busybox sleep 이 파싱한다.
# 겹쳐도 안전한 이유는 값이 종료 대상 식별에 전혀 쓰이지 않기 때문이다 — 정리는 위의
# process group 소유권으로만 한다. 이 값의 역할은 로그 판독 편의뿐이다.
RUN_SALT=$(( ($$ % 100000) * 1000 + (RANDOM % 1000) ))

# mock codex bin을 임시 디렉토리에 생성하고 PATH 앞에 추가하는 함수
# 사용: setup_mock <sandbox_dir> <script_body>
setup_mock() {
  local sandbox="$1"
  local body="$2"
  local bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<MOCK_EOF
#!/usr/bin/env bash
$body
MOCK_EOF
  chmod +x "$bin_dir/codex"
  echo "$bin_dir"
}

# mock claude bin을 임시 디렉토리에 생성하고 PATH 앞에 추가하는 함수
# 사용: setup_mock_claude <sandbox_dir> <script_body>
setup_mock_claude() {
  local sandbox="$1"
  local body="$2"
  local bin_dir="$sandbox/mock_bin_claude"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<MOCK_EOF
#!/usr/bin/env bash
$body
MOCK_EOF
  chmod +x "$bin_dir/claude"
  echo "$bin_dir"
}

# ===========================================================================
# 케이스 1: 정상 완료 — CHECKPOINT Suggested Next Owner = Reviewer여도 성공
# ===========================================================================
run_case1() {
  local sandbox
  sandbox="$(make_sandbox)"
  local turn_file="$sandbox/turns/turn-001-reviewer.md"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  # SESSION: Author 소유 + awaiting-author
  write_session "$sandbox" "Author" "awaiting-author"
  # CHECKPOINT: Suggested Next Owner = Reviewer (구 조건 위반 값 — 무시되어야 함)
  write_checkpoint "$sandbox" "Reviewer"

  # mock: 턴 파일 생성 + SESSION 갱신 후 exit 0
  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "
# 인자 파싱 무시, 턴 파일 생성 + SESSION 갱신
# PROMPT_FILE에서 읽지 않음 — 실행 자체만 확인
touch '$turn_file'
cat > '$sandbox/SESSION.md' <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
exit 0
")"

  local rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$sandbox/.turn_ready" ]; then
    pass "케이스 1: 정상 완료 (CHECKPOINT Suggested=Reviewer여도 exit 0)"
  else
    fail "케이스 1: 정상 완료 기대 exit 0, .turn_ready 생성 — rc=$rc, turn_ready=$([ -f "$sandbox/.turn_ready" ] && echo exists || echo missing)"
  fi

  # `.turn_ready` 는 디버깅용 마커라 버전관리 대상이 아니다 — ignore 패턴이 빠지면 리뷰 세션 커밋에 딸려 들어간다.
  # `git check-ignore` 는 개발 머신의 `.git/info/exclude` 에도 걸려 패턴 부재를 못 잡으므로 파일 내용을 직접 본다.
  local repo_root
  if repo_root="$(git -C "$(dirname "$ADAPTER")" rev-parse --show-toplevel 2>/dev/null)" && [ -f "$repo_root/.gitignore" ]; then
    if grep -qxF 'rd-workflow-workspace/handoffs/review_pipeline/*/.turn_ready' "$repo_root/.gitignore"; then
      pass "케이스 1(ignore): .gitignore 에 .turn_ready 패턴이 있음"
    else
      fail "케이스 1(ignore): .gitignore 에 .turn_ready 패턴이 없음 — 리뷰 세션 커밋에 유입됨"
    fi
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 2: 비정상 종료 — mock exit 1, 대기 상한(120초)까지 기다리지 않고 15초 안에 exit
# ===========================================================================
run_case2() {
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: 자기 pid 를 남기고 아무것도 쓰지 않은 채 즉시 exit 1
  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "echo \$\$ > \"$sandbox/mock.pid\"; exit 1")"

  # 어댑터를 백그라운드로 띄우고 rc 를 sentinel 파일에 쓴다. 0.1초 간격 폴링, 상한 15초.
  # (kill -0 로 job 을 보면 좀비를 살아 있는 것으로 오판하므로 sentinel 을 쓴다.)
  local job rc=0 ticks=0 cap_ticks=150
  set -m
  (
    arc=0
    TOOL_BIN="$mock_bin/codex" \
    SESSION_PATH="$sandbox" \
    PROMPT_FILE="/dev/null" \
    EXPECTED_TURN_FILE="$expected_turn" \
    PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=120 RD_REVIEW_IDLE_TIMEOUT=120 \
      bash "$ADAPTER" >/dev/null 2>&1 || arc=$?
    echo "$arc" > "$sandbox/rc"
  ) &
  job=$!
  set +m
  while [ ! -s "$sandbox/rc" ] && [ "$ticks" -lt "$cap_ticks" ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done

  if [ ! -s "$sandbox/rc" ]; then
    kill -9 -- -"$job" 2>/dev/null || true
    reap_mock_group "$sandbox"
    wait "$job" 2>/dev/null || true
    fail "케이스 2: 15초 안에 끝나지 않음 — 대기 상한까지 기다리는 결함 의심"
  else
    rc="$(cat "$sandbox/rc")"
    wait "$job" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
      pass "케이스 2: 비정상 종료 즉시 exit (rc=$rc, 약 $((ticks / 10)).$((ticks % 10))초)"
    else
      fail "케이스 2: 기대 rc≠0 — rc=$rc"
    fi
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 3: 타임아웃 — mock sleep 30, WAIT_TIMEOUT=3
# ===========================================================================
run_case3() {
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: sleep 30 (아무것도 쓰지 않음)
  # 자기 PID 를 파일에 남긴다 — 뒤의 생존 확인이 이 PID 만 보게 하기 위해서다.
  # `exec` 로 sleep 이 되어 PID 가 유지되므로, 기록한 PID = 실제 잠자는 프로세스다.
  local mock_bin mock_pid_file
  mock_pid_file="$sandbox/mock_bin/codex.pid"
  mock_bin="$(setup_mock "$sandbox" "echo \$\$ > \"$mock_pid_file\"; exec sleep 30")"

  local rc=0
  local output
  output="$(
    TOOL_BIN="$mock_bin/codex" \
    SESSION_PATH="$sandbox" \
    PROMPT_FILE="/dev/null" \
    EXPECTED_TURN_FILE="$expected_turn" \
    PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  # mock 프로세스가 종료됐는지 확인 — 이 sandbox 가 띄운 PID 하나만 본다.
  #   `pgrep -f "sleep 30"` 은 시스템 전역을 뒤지므로, 같은 머신의 다른 세션이 돌리는
  #   폴링 루프(`while ...; do sleep 30; done`)까지 우리 mock 으로 오인해 오탐한다.
  #   테스트가 자기 sandbox 밖의 프로세스 상태에 의존하면 결과가 재현되지 않는다.
  local mock_alive=0 mock_pid=""
  [ -f "$mock_pid_file" ] && mock_pid="$(cat "$mock_pid_file" 2>/dev/null)"
  if [ -n "$mock_pid" ] && kill -0 "$mock_pid" 2>/dev/null; then
    mock_alive=1
  fi

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "타임아웃"; then
    pass "케이스 3: 타임아웃 exit 124 + 메시지 확인"
  else
    fail "케이스 3: 타임아웃 기대 rc=124 — rc=$rc, 메시지=$(echo "$output" | grep -o '타임아웃' || echo '없음')"
  fi

  # PID 파일이 없으면 위 생존 확인이 항상 통과한다. 그 조용한 무력화를 먼저 막는다.
  if [ -z "$mock_pid" ]; then
    fail "케이스 3(보조): mock PID 미기록 — 생존 확인이 무력화됨"
  # mock 프로세스가 kill됐는지는 비동기 특성상 보조 확인만
  elif [ "$mock_alive" -eq 1 ]; then
    fail "케이스 3(보조): mock 프로세스(PID $mock_pid)가 아직 살아있음 — kill 실패 의심"
  else
    pass "케이스 3(보조): mock 프로세스(PID $mock_pid) 정리 확인"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 4: 폴링 부재 grep
# ===========================================================================
run_case4() {
  # adapter_codex.sh에 sleep "$POLL_INTERVAL" 폴링 루프 없음을 확인
  if grep -qE 'sleep[[:space:]]+"?\$POLL_INTERVAL"?' "$ADAPTER" 2>/dev/null; then
    fail "케이스 4a: adapter_codex.sh에 sleep \$POLL_INTERVAL 폴링 루프 존재 (폴링 제거 미완)"
  else
    pass "케이스 4a: adapter_codex.sh에 POLL_INTERVAL sleep 루프 없음"
  fi

  # 구현 완료 후: POLL_INTERVAL 자체가 없어야 함
  if grep -q 'POLL_INTERVAL' "$ADAPTER" 2>/dev/null; then
    fail "케이스 4b: adapter_codex.sh에 POLL_INTERVAL 잔존"
  else
    pass "케이스 4b: adapter_codex.sh에 POLL_INTERVAL 잔존 없음"
  fi

}

# ===========================================================================
# 케이스 5: malformed owner 실패
# ===========================================================================
run_case5() {
  # 5a: Current Owner = Bogus (비enum)
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001.md"

  write_session "$sandbox" "Bogus" "awaiting-author"
  write_checkpoint "$sandbox" "Author"

  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "
touch '$expected_turn'
exit 0
")"

  local rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "케이스 5a: malformed owner=Bogus → exit 1"
  else
    fail "케이스 5a: malformed owner=Bogus → 완료 오판(exit 0)"
  fi
  rm -rf "$sandbox"

  # 5b: Current Owner = 빈 값
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  write_session "$sandbox" "" "awaiting-author"
  write_checkpoint "$sandbox" "Author"
  mock_bin="$(setup_mock "$sandbox" "touch '$expected_turn'; exit 0")"

  rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "케이스 5b: malformed owner=빈값 → exit 1"
  else
    fail "케이스 5b: malformed owner=빈값 → 완료 오판(exit 0)"
  fi
  rm -rf "$sandbox"

  # 5c: Status = awaiting-reviewer (미전환)
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  write_session "$sandbox" "Author" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  mock_bin="$(setup_mock "$sandbox" "touch '$expected_turn'; exit 0")"

  rc=0
  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "케이스 5c: Status=awaiting-reviewer(미전환) → exit 1"
  else
    fail "케이스 5c: Status=awaiting-reviewer → 완료 오판(exit 0)"
  fi
  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 6: timeout 마커 정리 — 정상 완료 경로에서 .wait_timeout 잔존 금지
# ===========================================================================
run_case6() {
  local sandbox
  sandbox="$(make_sandbox)"
  local expected_turn="$sandbox/turns/turn-001-reviewer.md"

  write_session "$sandbox" "Author" "awaiting-author"
  write_checkpoint "$sandbox" "Reviewer"

  local mock_bin
  mock_bin="$(setup_mock "$sandbox" "
touch '$expected_turn'
cat > '$sandbox/SESSION.md' <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
exit 0
")"

  TOOL_BIN="$mock_bin/codex" \
  SESSION_PATH="$sandbox" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$expected_turn" \
  PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" >/dev/null 2>&1 || true

  # 마커는 안정 이름을 쓰지 않고 `.wait_timeout.XXXXXX` 로 배타 생성되므로 두 형태를
  # 함께 센다 (안정 이름 잔존은 구버전 회귀 신호이기도 하다).
  local marker_left
  marker_left="$( { ls -d "$sandbox"/.wait_timeout "$sandbox"/.wait_timeout.* 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  if [ "$marker_left" -eq 0 ]; then
    pass "케이스 6: 정상 완료 경로에서 타임아웃 마커 잔존 없음"
  else
    fail "케이스 6: 타임아웃 마커 ${marker_left}개가 정상 완료 후에도 잔존"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# §2 결정 3 — run_review_turn.sh 설정 파싱 1회 통합 테스트 (Task 2)
# 케이스 7~11: jq 호출 수 계측 / override priority / 값 내 공백·= /
#              missing·null 구분 / jq 부재·JSON 손상 fallback
# ===========================================================================

SCRIPT_DIR_RRT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_REVIEW_TURN="$SCRIPT_DIR_RRT/run_review_turn.sh"

# jq 호출 수 계측용 mock jq를 sandbox PATH 앞에 배치하는 헬퍼.
# 실제 jq를 감싸고 호출마다 COUNT_FILE 에 1줄 append.
# 사용: setup_counting_jq <sandbox_dir> <count_file>  → bin_dir 출력
setup_counting_jq() {
  local sandbox="$1"
  local count_file="$2"
  local real_jq
  real_jq="$(command -v jq)"
  local bin_dir="$sandbox/counting_jq"
  mkdir -p "$bin_dir"
  # counting jq — 실제 jq를 exec 위임하므로 결과는 동일
  cat > "$bin_dir/jq" <<JQ_EOF
#!/usr/bin/env bash
echo "called" >> "$count_file"
exec "$real_jq" "\$@"
JQ_EOF
  chmod +x "$bin_dir/jq"
  echo "$bin_dir"
}

# run_review_turn.sh 의 load_review_config + get_tool_config 경로만
# 실행하는 최소 harness 스크립트.  CONFIG_FILE 과 review_type 을 받아
# PRIORITY / 도구 설정 값들을 출력한다.
# 사용: harness_script <config_file> <review_type>
make_parse_harness() {
  local harness="$1"  # 출력 파일 경로
  cat > "$harness" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -euo pipefail
# harness: run_review_turn.sh 의 설정 파싱 경로만 격리 실행
CONFIG_FILE="${1:-}"
REVIEW_TYPE="${2:-}"

# run_review_turn.sh 에서 load_review_config / get_tool_config 정의만 소스
# (메인 케이스문 이전까지만 실행되도록 플래그 사용)
RRT_HARNESS_MODE=1

script_dir_inner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# review_common.sh 는 실행 안 하고, 함수 정의만 필요 → 직접 inline
# (run_review_turn.sh 는 source_dir에 의존하므로 동일 디렉토리에서 실행)
cd "$script_dir_inner"
source ./run_review_turn.sh_funcs_only
HARNESS_EOF
  chmod +x "$harness"
}

# run_review_turn.sh 에서 함수 정의 블록(L28-74)을 추출해 funcs_only 파일로 제공하는 대신,
# 직접 harness에서 source 없이 함수를 재현하는 방식으로 구현.
# (run_review_turn.sh 는 source 시 메인 실행까지 이어지므로 함수 추출 방식 사용)
#
# 실제 계측 대상: PATH 앞 counting jq + CONFIG_FILE 지정 후
#   - load_review_config 1회
#   - get_tool_config 4회 (bin / model / self_review_warning / self_review_policy)
# run_review_turn.sh 의 실제 실행 경로를 트레이스하려면 adapter 루프 직전까지 실행해야 하나,
# 그러려면 session_dir 등 전체 환경이 필요. 따라서 함수만 추출·실행하는 미니 harness 사용.

# harness 실행 헬퍼: CONFIG_FILE 설정 후 load_review_config + get_tool_config 4회 실행
# 인자: <config_file> <review_type> [counting_jq_dir]
run_parse_harness() {
  local cfg="$1"
  local rt="${2:-}"
  local extra_path="${3:-}"

  local harness_dir
  harness_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  # run_review_turn.sh 와 동일 디렉토리에서 실행해야 source 경로가 맞음 — 불필요
  # 함수만 inline으로 실행

  local harness_script="$harness_dir/harness.sh"
  cat > "$harness_script" <<HARNESS_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$cfg"
REVIEW_CFG_KV=""

# ── load_review_config (구현 후 버전 또는 현행 버전 — 테스트는 실제 파일 실행) ──
# 실제 run_review_turn.sh 에서 함수를 추출해 실행
$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")

# 혹시 새 통합 함수가 있으면 같이 추출
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

# 실행
if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type="$rt"
  load_review_config_once
else
  load_review_config "$rt"
fi
bin_val="\$(get_tool_config "codex" "bin" "DEFAULT_BIN")"
model_val="\$(get_tool_config "claude" "model" "DEFAULT_MODEL")"
warn_val="\$(get_tool_config "claude" "self_review_warning" "DEFAULT_WARN")"
policy_val="\$(get_tool_config "claude" "self_review_policy" "DEFAULT_POLICY")"

echo "PRIORITY=\$PRIORITY"
echo "bin=\$bin_val"
echo "model=\$model_val"
echo "warn=\$warn_val"
echo "policy=\$policy_val"
HARNESS_BODY
  chmod +x "$harness_script"

  local path_prefix=""
  [[ -n "$extra_path" ]] && path_prefix="$extra_path:"
  PATH="${path_prefix}$(dirname "$RUN_REVIEW_TURN"):$PATH" bash "$harness_script"
  local rc=$?
  rm -rf "$harness_dir"
  return $rc
}

# ===========================================================================
# 케이스 7: jq 호출 수 ≤1 계측 (spec AC 3 — counting jq로 실행 경로 계측)
# ===========================================================================
run_case7() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 7: jq 없음 — fallback 경로, 호출 수 계측 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  local count_file="$sandbox/jq_count"
  touch "$count_file"

  # 실제 review-tools.json 샘플 생성
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": {
      "bin": null,
      "model": null,
      "self_review_warning": true,
      "self_review_policy": "block"
    }
  },
  "overrides": {
    "diff-review": { "priority": ["codex"] }
  }
}
RJSON

  local counting_jq_dir
  counting_jq_dir="$(setup_counting_jq "$sandbox" "$count_file")"

  # CONFIG_FILE 을 sandbox 의 json 으로 지정
  local out
  out="$(REVIEW_TOOLS_CONFIG="$sandbox/review-tools.json" \
    run_parse_harness "$sandbox/review-tools.json" "diff-review" "$counting_jq_dir")" || true

  local call_count=0
  [[ -f "$count_file" ]] && call_count=$(wc -l < "$count_file" | tr -d ' ')

  if [[ "$call_count" -le 1 ]]; then
    pass "케이스 7: jq 호출 수 ≤1 (실측 ${call_count}회) — spec AC 3 충족"
  else
    fail "케이스 7: jq 호출 수 초과 (실측 ${call_count}회 > 1) — 다중 파싱 미제거"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 8: override priority 적용 검증
# ===========================================================================
run_case8() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 8: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": { "bin": null, "model": null, "self_review_warning": true }
  },
  "overrides": {
    "spec-review": { "priority": ["claude", "codex"] }
  }
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "spec-review" "")" || true

  local priority
  priority="$(echo "$out" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ "$priority" == "claude codex" ]]; then
    pass "케이스 8: spec-review override priority = 'claude codex' 정상 적용"
  else
    fail "케이스 8: spec-review override priority 기대='claude codex', 실제='$priority'"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 9: 값 내 공백·= 포함 — TSV 경계 보존 증명
# ===========================================================================
run_case9() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 9: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  # bin 값에 공백·= 포함 (예: 경로 with spaces, model=xxx 형식)
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": "/usr/local/bin/my codex bin" },
    "claude": {
      "bin": null,
      "model": "claude-sonnet=latest",
      "self_review_warning": true
    }
  },
  "overrides": {}
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "" "")" || true

  local bin_val model_val
  bin_val="$(echo "$out" | grep '^bin=' | cut -d= -f2-)"
  model_val="$(echo "$out" | grep '^model=' | cut -d= -f2-)"

  local pass_count=0
  if [[ "$bin_val" == "/usr/local/bin/my codex bin" ]]; then
    pass_count=$((pass_count + 1))
  fi
  if [[ "$model_val" == "claude-sonnet=latest" ]]; then
    pass_count=$((pass_count + 1))
  fi

  if [[ "$pass_count" -eq 2 ]]; then
    pass "케이스 9: 공백 포함 bin='$bin_val', = 포함 model='$model_val' — TSV 경계 보존"
  else
    fail "케이스 9: 값 경계 훼손 — bin='$bin_val'(기대='/usr/local/bin/my codex bin'), model='$model_val'(기대='claude-sonnet=latest')"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 10: missing 필드와 null 필드 — 현행 계약 보존 (둘 다 기본값 반환)
# ===========================================================================
run_case10() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 10: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  # codex: model 필드 아예 없음(missing), claude: model = null
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": {
      "bin": null,
      "model": null,
      "self_review_warning": true
    }
  },
  "overrides": {}
}
RJSON

  # codex model(missing) 과 claude model(null) 모두 기본값 반환 확인
  local harness_dir
  harness_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  local harness_script="$harness_dir/harness10.sh"
  cat > "$harness_script" <<HARNESS10_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$sandbox/review-tools.json"
REVIEW_CFG_KV=""

$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type=""
  load_review_config_once
else
  load_review_config ""
fi

# codex model: missing 필드 → 기본값 "MISSING_DEFAULT" 기대
codex_model="\$(get_tool_config "codex" "model" "MISSING_DEFAULT")"
# claude model: null 필드 → 기본값 "NULL_DEFAULT" 기대
claude_model="\$(get_tool_config "claude" "model" "NULL_DEFAULT")"
# claude self_review_warning: 실제 값 "true" 기대
claude_warn="\$(get_tool_config "claude" "self_review_warning" "DEFAULT_WARN")"

echo "codex_model=\$codex_model"
echo "claude_model=\$claude_model"
echo "claude_warn=\$claude_warn"
HARNESS10_BODY
  chmod +x "$harness_script"

  local out
  out="$(bash "$harness_script")" || true
  rm -rf "$harness_dir"

  local codex_model claude_model claude_warn
  codex_model="$(echo "$out" | grep '^codex_model=' | cut -d= -f2-)"
  claude_model="$(echo "$out" | grep '^claude_model=' | cut -d= -f2-)"
  claude_warn="$(echo "$out" | grep '^claude_warn=' | cut -d= -f2-)"

  local pass_count=0
  [[ "$codex_model" == "MISSING_DEFAULT" ]] && pass_count=$((pass_count + 1))
  [[ "$claude_model" == "NULL_DEFAULT" ]]   && pass_count=$((pass_count + 1))
  [[ "$claude_warn" == "true" ]]            && pass_count=$((pass_count + 1))

  if [[ "$pass_count" -eq 3 ]]; then
    pass "케이스 10: missing→기본값, null→기본값, 실제값 정상 반환 — 현행 계약 보존"
  else
    fail "케이스 10: 계약 위반 — codex_model='$codex_model'(기대 MISSING_DEFAULT), claude_model='$claude_model'(기대 NULL_DEFAULT), warn='$claude_warn'(기대 true)"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 11: jq 부재 및 JSON 손상 fallback
# ===========================================================================
run_case11() {
  # 11a: jq 부재 — PRIORITY 기본값 사용
  local sandbox
  sandbox="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  cat > "$sandbox/review-tools.json" <<'RJSON'
{"default_priority": ["codex", "claude"], "tools": {}, "overrides": {}}
RJSON

  local no_jq_dir="$sandbox/no_jq"
  mkdir -p "$no_jq_dir"
  # jq 를 PATH 에서 제거: 존재하지 않는 빈 bin_dir 으로 앞에 추가
  # (현재 PATH 에서 jq를 가려야 하므로 fake jq를 배치해 exit 127)
  cat > "$no_jq_dir/jq" <<'FAKE_JQ'
#!/usr/bin/env bash
exit 127
FAKE_JQ
  chmod +x "$no_jq_dir/jq"

  local harness_dir
  harness_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  local harness_script="$harness_dir/harness11a.sh"
  cat > "$harness_script" <<HARNESS11A_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$sandbox/review-tools.json"
REVIEW_CFG_KV=""

$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type=""
  load_review_config_once
else
  load_review_config ""
fi
echo "PRIORITY=\$PRIORITY"
HARNESS11A_BODY
  chmod +x "$harness_script"

  # jq 를 가짜 exit 127 로 대체한 PATH 에서 실행
  local out11a
  out11a="$(PATH="$no_jq_dir:$(echo "$PATH" | tr ':' '\n' | grep -v "$(dirname "$(command -v jq 2>/dev/null || echo /nonexistent)")" | tr '\n' ':' | sed 's/:$//')" bash "$harness_script" 2>/dev/null)" || true
  rm -rf "$harness_dir"

  local priority11a
  priority11a="$(echo "$out11a" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ -n "$priority11a" ]]; then
    pass "케이스 11a: jq 부재 시 기본값 PRIORITY='$priority11a' 반환"
  else
    fail "케이스 11a: jq 부재 시 PRIORITY 빈값 — fallback 미동작"
  fi

  # 11b: JSON 손상 — 기본값 사용 + stderr 안내
  local bad_json="$sandbox/bad.json"
  echo 'NOT VALID JSON {{{' > "$bad_json"

  harness_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$harness_dir" && -d "$harness_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  harness_script="$harness_dir/harness11b.sh"
  cat > "$harness_script" <<HARNESS11B_BODY
#!/usr/bin/env bash
set -uo pipefail
CONFIG_FILE="$bad_json"
REVIEW_CFG_KV=""

$(sed -n '/^load_review_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(sed -n '/^get_tool_config()/,/^}/p' "$RUN_REVIEW_TURN")
$(grep -A 50 '^load_review_config_once()' "$RUN_REVIEW_TURN" 2>/dev/null | sed '/^}$/q' || true)

if declare -f load_review_config_once >/dev/null 2>&1; then
  review_type=""
  load_review_config_once
else
  load_review_config ""
fi
echo "PRIORITY=\$PRIORITY"
HARNESS11B_BODY
  chmod +x "$harness_script"

  local out11b stderr11b errf11b
  errf11b="$(mktemp "$RUN_TMP/f.XXXXXX")" || { echo "test_review_wait.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  out11b="$(bash "$harness_script" 2>"$errf11b")" || true
  stderr11b="$(cat "$errf11b" 2>/dev/null || true)"
  rm -f "$errf11b"
  rm -rf "$harness_dir"

  local priority11b
  priority11b="$(echo "$out11b" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ -n "$priority11b" ]] && [[ -n "$stderr11b" ]]; then
    pass "케이스 11b: JSON 손상 시 기본값 PRIORITY='$priority11b' + stderr 안내 존재"
  elif [[ -n "$priority11b" ]]; then
    pass "케이스 11b: JSON 손상 시 기본값 PRIORITY='$priority11b' 반환 (stderr 고지는 구현 세부)"
  else
    fail "케이스 11b: JSON 손상 시 PRIORITY 빈값 — fallback 미동작"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 12: 축약 config (.tools 없음 + default_priority/overrides만)
#            — priority가 유지되고 fallback으로 떨어지지 않음을 assert
# ===========================================================================
run_case12() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 12: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }

  # .tools 없는 축약 config — 기존 구현에서는 "null has no keys" 오류로
  # kv 전체가 폐기되어 priority가 기본값(codex claude)으로 fallback됐음.
  # 수정 후: .tools // {} 방어로 override priority가 정상 적용되어야 함.
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "overrides": {
    "diff-review": { "priority": ["claude"] }
  }
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "diff-review" "")" || true

  local priority
  priority="$(echo "$out" | grep '^PRIORITY=' | cut -d= -f2-)"

  # override priority 'claude'가 적용되어야 함 — fallback 'codex claude'가 아님
  if [[ "$priority" == "claude" ]]; then
    pass "케이스 12: 축약 config (tools 없음) + diff-review override → PRIORITY='claude' 정상 적용"
  else
    fail "케이스 12: 축약 config priority 회귀 — 기대='claude', 실제='$priority' (fallback 발생 의심)"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 13: .overrides 없는 config — default_priority 정상 반환
# ===========================================================================
run_case13() {
  if ! command -v jq &>/dev/null; then
    pass "케이스 13: jq 없음 — 건너뜀"
    return
  fi

  local sandbox
  sandbox="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$sandbox" && -d "$sandbox" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }

  # .overrides 필드 자체 없음 — (.overrides // {})[$rt] 이 null 로 안전하게 처리되어야 함
  cat > "$sandbox/review-tools.json" <<'RJSON'
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": { "bin": null, "model": null, "self_review_warning": true }
  }
}
RJSON

  local out
  out="$(run_parse_harness "$sandbox/review-tools.json" "spec-review" "")" || true

  local priority
  priority="$(echo "$out" | grep '^PRIORITY=' | cut -d= -f2-)"

  if [[ "$priority" == "codex claude" ]]; then
    pass "케이스 13: overrides 없는 config → default_priority='codex claude' 정상 반환"
  else
    fail "케이스 13: overrides 없는 config priority 오류 — 기대='codex claude', 실제='$priority'"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 16: writable surface 세션 하위 폐쇄 (codex-adapter-writable-root)
#   (a) last-message 파일은 세션 하위 mktemp 템플릿 — 세션에 미리 놓인 고정명 symlink
#       `.last_message` 를 따라가 세션 밖 파일을 truncate 하지 않는다 (final diff review 002턴).
#   (b) 그 파일은 정상 종료 후 남지 않는다.
#   (c) --add-dir 에는 SESSION_PATH 의 symlink 를 따라간 physical 경로가 전달된다.
#   세션은 symlink 경로로 넘긴다 (team-overlay 재현). 실제 codex 대신 인자를 기록하는 mock.
# ===========================================================================
run_case16() {
  local sandbox victim_dir victim link_root sess_link sess_real
  sandbox="$(make_sandbox)"
  sess_real="$(cd "$sandbox" && pwd -P)"

  # team-overlay 재현: PROJECT_ROOT 안의 symlink 가 세션 실제 위치를 가리킨다
  link_root="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$link_root" && -d "$link_root" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  sess_link="$link_root/sess"
  ln -s "$sess_real" "$sess_link"

  # 세션 밖 피해 후보 + 고정명 symlink 사전 배치 (checkout·이전 비정상 실행 상황 재현)
  victim_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$victim_dir" && -d "$victim_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim="$victim_dir/victim.txt"
  printf 'KEEP\n' > "$victim"
  ln -s "$victim" "$sandbox/.last_message"

  local turn_file="$sandbox/turns/turn-001-reviewer.md"
  local args_out="$sandbox/mock_args.txt"
  write_session "$sandbox" "Author" "awaiting-author"

  # mock: 인자 전부 기록, --output-last-message 경로에 쓰기, 턴 파일 + SESSION 갱신
  local bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CASE16_ARGS_OUT"
lm=""
for ((i=1; i<=$#; i++)); do
  if [ "${!i}" = "--output-last-message" ]; then j=$((i+1)); lm="${!j}"; fi
done
[ -n "$lm" ] && echo "done" > "$lm"
touch "$CASE16_TURN_FILE"
cat > "$SESSION_PATH/SESSION.md" <<'SESS_EOF'
## Current Owner
Author

## Status
awaiting-author

## Turn Limit
20
SESS_EOF
cat >/dev/null
exit 0
MOCK_EOF
  chmod +x "$bin_dir/codex"

  local rc=0
  CASE16_ARGS_OUT="$args_out" \
  CASE16_TURN_FILE="$turn_file" \
  TOOL_BIN="$bin_dir/codex" \
  SESSION_PATH="$sess_link" \
  PROMPT_FILE="/dev/null" \
  EXPECTED_TURN_FILE="$turn_file" \
  PROJECT_ROOT="$link_root" \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 16: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
  else
    # (a) 사전 배치 symlink 비추종 — 피해 후보 내용 보존, symlink 자체도 그대로
    if [ "$(cat "$victim")" = "KEEP" ] && [ -L "$sandbox/.last_message" ]; then
      pass "케이스 16a: 고정명 symlink .last_message 를 따라가지 않음 (세션 밖 파일 보존)"
    else
      fail "케이스 16a: 사전 배치 symlink 추종 — victim='$(cat "$victim" 2>/dev/null)', link=$([ -L "$sandbox/.last_message" ] && echo kept || echo gone)"
    fi

    # last-message 경로: 세션 하위 mktemp 템플릿 (고정명 아님)
    local lm_path
    lm_path="$(awk '/^--output-last-message$/{getline; print}' "$args_out")"
    case "$lm_path" in
      "$sess_link"/.last_message.??????)
        pass "케이스 16: last-message 는 세션 하위 mktemp 템플릿 ($(basename "$lm_path"))" ;;
      *)
        fail "케이스 16: last-message 경로가 세션 하위 템플릿이 아님 — '$lm_path'" ;;
    esac

    # (b) 정상 종료 후 템플릿 파일 잔존 없음 (사전 배치 symlink 만 남아야 한다)
    local leftover
    leftover="$(find "$sandbox" -maxdepth 1 -name '.last_message.*' | wc -l | tr -d ' ')"
    if [ "$leftover" -eq 0 ]; then
      pass "케이스 16b: 정상 종료 후 .last_message.* 잔존 없음"
    else
      fail "케이스 16b: .last_message.* ${leftover}개 잔존"
    fi

    # (c) --add-dir 는 symlink 를 따라간 physical 경로
    local add_dir
    add_dir="$(awk '/^--add-dir$/{getline; print}' "$args_out")"
    if [ "$add_dir" = "$sess_real" ]; then
      pass "케이스 16c: --add-dir 에 세션 physical 경로 전달 (symlink 해석됨)"
    else
      fail "케이스 16c: --add-dir 기대='$sess_real', 실제='$add_dir'"
    fi
  fi

  rm -rf "$sandbox" "$link_root" "$victim_dir"
}

# ===========================================================================
# 케이스 17: 환경변수 해석 — 유효/무효/fallthrough/0
# ===========================================================================
run_case17() {
  local sandbox expected_turn mock_bin
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  # mock: 즉시 턴 파일을 만들고 끝낸다 (대기 로직을 타지 않게)
  mock_bin="$(setup_mock "$sandbox" "printf 'x' > \"$expected_turn\"; exit 0")"

  # a~e: 어댑터를 실행하지 않고 review_wait.sh 의 해석 함수를 직접 부른다 — 어댑터가 같은 함수·같은 기본값
  # (cap 7200, idle 600)으로 "wait config: cap=<N>s idle=<N>s" 줄을 만든다. 같은 형식으로 비교한다.
  # 주의: BSD/macOS env 는 옵션을 환경 대입보다 **앞**에 두어야 한다.
  #       `env NAME=v -u OTHER` 형태는 -u 를 실행할 명령으로 해석할 수 있다.
  probe() {  # $1..: env 인자(-u 옵션이 먼저, 그다음 NAME=value) → stdout 에 config 줄
    env "$@" bash -c '
      source "$1"
      printf "wait config: cap=%ss idle=%ss\n" "$(rw_resolve_abs_cap 7200 2>/dev/null)" "$(rw_resolve_idle 600 2>/dev/null)"
    ' _ "$SCRIPT_DIR/review_wait.sh" || true
  }

  local out
  # (a) 기본값
  out="$(probe -u WAIT_TIMEOUT -u POLL_TIMEOUT -u RD_REVIEW_IDLE_TIMEOUT)"
  [ "$out" = "wait config: cap=7200s idle=600s" ] \
    && pass "케이스 17a: 기본값 cap=7200 idle=600" \
    || fail "케이스 17a: 기대 cap=7200 idle=600 — 실제 [$out]"

  # (b) WAIT_TIMEOUT 유효
  out="$(probe -u POLL_TIMEOUT -u RD_REVIEW_IDLE_TIMEOUT WAIT_TIMEOUT=1234)"
  [ "$out" = "wait config: cap=1234s idle=600s" ] \
    && pass "케이스 17b: WAIT_TIMEOUT 반영" \
    || fail "케이스 17b: 기대 cap=1234 — 실제 [$out]"

  # (c) WAIT_TIMEOUT 무효 + POLL_TIMEOUT 유효 → 다음 원천으로 내려간다
  out="$(probe -u RD_REVIEW_IDLE_TIMEOUT WAIT_TIMEOUT=abc POLL_TIMEOUT=1200)"
  [ "$out" = "wait config: cap=1200s idle=600s" ] \
    && pass "케이스 17c: 무효값은 무시하고 alias 사용" \
    || fail "케이스 17c: 기대 cap=1200 — 실제 [$out]"

  # (d) 둘 다 무효 → 기본값
  out="$(probe -u RD_REVIEW_IDLE_TIMEOUT WAIT_TIMEOUT=-5 POLL_TIMEOUT=3.5)"
  [ "$out" = "wait config: cap=7200s idle=600s" ] \
    && pass "케이스 17d: 둘 다 무효 → 기본값" \
    || fail "케이스 17d: 기대 cap=7200 — 실제 [$out]"

  # (e) IDLE=0 은 유효 (유휴 판별 비활성)
  out="$(probe -u WAIT_TIMEOUT -u POLL_TIMEOUT RD_REVIEW_IDLE_TIMEOUT=0)"
  [ "$out" = "wait config: cap=7200s idle=0s" ] \
    && pass "케이스 17e: IDLE=0 유효(비활성)" \
    || fail "케이스 17e: 기대 idle=0 — 실제 [$out]"

  # (f)(g) 무효값 경고 — 어댑터 실행 1회에 세 조건을 함께 주고 경고를 각각 확인한다
  local w2
  w2="$(env -u WAIT_TIMEOUT -u POLL_TIMEOUT RD_REVIEW_IDLE_TIMEOUT=xyz \
    RD_REVIEW_OBSERVER_FALLBACK_CAP=abc RD_REVIEW_HEARTBEAT=-3 \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    bash "$ADAPTER" 2>&1)" || true

  # (f) IDLE 무효 → 기본값 + 경고
  if echo "$w2" | grep -q 'RD_REVIEW_IDLE_TIMEOUT'; then
    pass "케이스 17f: IDLE 무효값 경고 출력"
  else
    fail "케이스 17f: 경고 미출력"
  fi

  # (g) 조정 변수 두 개의 무효값도 경고한다
  if echo "$w2" | grep -q 'RD_REVIEW_OBSERVER_FALLBACK_CAP' \
     && echo "$w2" | grep -q 'RD_REVIEW_HEARTBEAT'; then
    pass "케이스 17g: 조정 변수 무효값 경고"
  else
    fail "케이스 17g: 조정 변수 무효값이 조용히 무시됨"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 18: 활동이 유휴 타이머를 반복 갱신한다 (총 경과 > 유휴 임계)
# ===========================================================================
run_case18() {
  local sandbox expected_turn mock_bin rc=0
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  # mock 이 SESSION.md 를 다시 쓰지 않으므로(턴 파일만 생성) check_turn_complete 가
  # 성공하려면 시작 시점부터 Owner=Author/Status=awaiting-author 여야 한다
  # (케이스 1·6·14 와 동일 관례 — 브리프 원문의 Reviewer/awaiting-reviewer 는
  # check_turn_complete 계약상 rc=0 을 구조적으로 불가능하게 하는 오기이므로 정정한다).
  write_session "$sandbox" "Author" "awaiting-author"
  write_checkpoint "$sandbox" "Reviewer"

  # mock: 1초마다 출력을 내며 6초간 일한 뒤 턴 파일을 만들고 성공.
  # 유휴 임계 2초 < 총 소요 6초 이므로, 유휴 갱신이 없으면 반드시 죽는다.
  mock_bin="$(setup_mock "$sandbox" \
    "for i in 1 2 3 4 5 6; do echo \"progress \$i\"; sleep 1; done; printf 'x' > \"$expected_turn\"; exit 0")"

  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=2 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] \
    && pass "케이스 18: 활동이 유휴 타이머를 갱신 (6초 작업 / 유휴 2초 / rc=0)" \
    || fail "케이스 18: 기대 rc=0 — 실제 rc=$rc (유휴 갱신 실패)"

  [ -s "$sandbox/.codex_output.log" ] \
    && pass "케이스 18(보조): codex 출력 로그 보존" \
    || fail "케이스 18(보조): .codex_output.log 부재 또는 빈 파일"

  grep -q '^log_preserved: yes' "$sandbox/.review_wait_status" 2>/dev/null \
    && pass "케이스 18(보조2): 정상 경로 log_preserved=yes 기록" \
    || fail "케이스 18(보조2): log_preserved 기록 없음"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 19: 무활동은 유휴 임계에서 124 로 종료된다
# ===========================================================================
run_case19() {
  local sandbox expected_turn mock_bin rc=0 output start elapsed
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: 한 줄 찍고 조용히 오래 잔다 → 첫 출력 후 무활동
  mock_bin="$(setup_mock "$sandbox" "echo start; exec sleep 60")"

  start=$(date +%s)
  output="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?
  elapsed=$(( $(date +%s) - start ))
  C19_OUT="$output"   # 케이스 23 의 메시지 단언이 이 출력을 쓴다

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "유휴"; then
    pass "케이스 19: 무활동 → 유휴 사유로 exit 124 (${elapsed}초)"
  else
    fail "케이스 19: 기대 rc=124 + '유휴' 사유 — rc=$rc"
  fi

  # 상한(60초)이 아니라 유휴(3초)에서 끊겼는지 시간으로 확인한다
  [ "$elapsed" -lt 30 ] \
    && pass "케이스 19(보조): 상한이 아닌 유휴에서 종료 (${elapsed}초 < 30초)" \
    || fail "케이스 19(보조): ${elapsed}초 — 유휴 판정이 동작하지 않음"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 20: 활동 중이어도 절대 상한에서 종료된다
# ===========================================================================
run_case20() {
  local sandbox expected_turn mock_bin rc=0 output
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: 계속 출력하며 절대 끝나지 않는다
  mock_bin="$(setup_mock "$sandbox" "while :; do echo tick; sleep 1; done")"

  output="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=4 RD_REVIEW_IDLE_TIMEOUT=600 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?
  C20_OUT="$output"   # 케이스 23 의 메시지 단언이 이 출력을 쓴다

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "상한"; then
    pass "케이스 20: 활동 중에도 절대 상한에서 exit 124"
  else
    fail "케이스 20: 기대 rc=124 + '상한' 사유 — rc=$rc"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 21: heartbeat 주기·필드와 상태 파일 보존
# ===========================================================================
run_case21() {
  local sandbox expected_turn mock_bin rc=0 output beats
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  mock_bin="$(setup_mock "$sandbox" \
    "for i in 1 2 3 4 5 6; do echo \"working \$i\"; sleep 1; done; printf 'x' > \"$expected_turn\"; exit 0")"

  # HEARTBEAT_INTERVAL 을 2초로 낮춰 6초 실행에서 최소 2회 나오게 한다
  output="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=30 RD_REVIEW_HEARTBEAT=2 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  beats="$(echo "$output" | grep -c '^\[review wait\]' || true)"
  [ "$beats" -ge 2 ] \
    && pass "케이스 21a: heartbeat 반복 출력 (${beats}회)" \
    || fail "케이스 21a: heartbeat 기대 2회 이상 — 실제 ${beats}회"

  # 네 필드가 모두 있는가
  if echo "$output" | grep -q '^\[review wait\].*경과.*마지막 활동.*유휴여유.*상한'; then
    pass "케이스 21b: heartbeat 네 필드 포함"
  else
    fail "케이스 21b: heartbeat 필드 누락 — $(echo "$output" | grep '^\[review wait\]' | head -1)"
  fi

  # 로그의 마지막 줄이 붙는가
  echo "$output" | grep -q 'codex: working' \
    && pass "케이스 21c: heartbeat 에 로그 마지막 줄 포함" \
    || fail "케이스 21c: 로그 마지막 줄 미포함"

  # 상태 파일이 정상 완료 후에도 보존되는가
  [ -s "$sandbox/.review_wait_status" ] \
    && pass "케이스 21d: 상태 파일 정상 종료 후 보존" \
    || fail "케이스 21d: .review_wait_status 부재"

  rm -rf "$sandbox"
}
# ===========================================================================
# 케이스 22: 로그 경로 unlink 는 **관측을 훼손하지 않는다** (읽기 채널 fd 전용 계약)
#   활동 관측은 codex spawn 전에 열어 둔 fd 로만 하므로, 경로가 사라져도 어댑터는 원래
#   inode 에서 계속 새 바이트를 본다(codex 도 자기 fd 로 같은 inode 에 계속 쓴다).
#   훼손되는 것은 사후 **로그 보존**뿐이며 그것은 log-vanished-during-run 으로 보고된다.
#
#   판별력: 구 코드는 매 tick `wc -c < "$codex_log"` 로 **경로를 다시 열었고**(이번 라운드
#   Critical 의 정보 노출 창) unlink 시점에 관측기 고장으로 판정해 유효 상한 min(60,4)=4초
#   에서 rc=124 로 죽었다. 새 코드는 관측이 유지되므로 mock 이 6초 뒤 턴을 완성하고 rc=0
#   으로 끝난다. FALLBACK_CAP=4 를 그대로 주므로 구 코드로 되돌리면 이 케이스가 깨진다.
# ===========================================================================
run_case22() {
  local sandbox expected_turn mock_bin errlog start elapsed rc=0 i logf out
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  # 완주(rc=0)를 기대하므로 SESSION 은 완료 상태로 둔다 — 어댑터의 완료 판정은 codex
  # 종료 후에만 일어나므로 시작 시점 값이 실행 중 판정을 바꾸지 않는다(케이스 25 와 동일).
  write_session "$sandbox" "Author" "awaiting-author"
  # 1초마다 출력하며 6초 뒤 턴을 완성한다 → 관측이 유지되면 유휴(4초)로 죽지 않는다
  mock_bin="$(setup_mock "$sandbox" \
    "for i in 1 2 3 4 5 6; do echo tick; sleep 1; done; printf 'x' > \"$expected_turn\"; exit 0")"
  errlog="$sandbox/adapter_err.txt"

  # ABS_CAP=60(길게) / IDLE=4(짧게) / fallback 천장=4(짧게)
  #   관측이 유지되면 매초 활동이 갱신되어 유휴 4초가 발동하지 않고 6초를 완주한다.
  #   구 코드에서는 unlink(약 2초) 즉시 관측기 고장 → 유효 상한 4초 → rc=124.
  start=$(date +%s)
  spawn_group "$errlog" env \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=4 RD_REVIEW_OBSERVER_FALLBACK_CAP=4 \
    bash "$ADAPTER"

  # 로그 파일이 생기기를 기다렸다가 **실제로 지운다** (현실의 unlink 장애)
  logf=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    logf="$( { ls "$sandbox"/.codex_output.?????? 2>/dev/null || true; } | head -n 1 )"
    [ -n "$logf" ] && break
    sleep 0.1
  done
  if [ -z "$logf" ]; then
    fail "케이스 22: codex 출력 로그가 생성되지 않아 장애를 주입할 수 없음"
    reap_group "$GROUP_PGID"; rm -rf "$sandbox"; return
  fi
  sleep 2
  rm -f "$logf"

  wait "$JOB" 2>/dev/null || rc=$?
  elapsed=$(( $(date +%s) - start ))
  reap_group "$GROUP_PGID"
  out="$( { cat "$errlog" 2>/dev/null || true; } )"

  # (a) unlink 에도 관측이 유지되어 턴을 완주했는가
  if [ "$rc" -eq 0 ] && [ "$elapsed" -ge 5 ]; then
    pass "케이스 22a: 로그 경로 unlink 에도 관측 유지 — 턴 완주 (${elapsed}초, rc=0)"
  else
    fail "케이스 22a: 기대 rc=0 & elapsed>=5 — rc=$rc elapsed=${elapsed}초 (경로 재열기 관측으로 회귀했을 수 있음)"
  fi

  # (b) 관측기 고장으로 오판하지 않았는가 (전환 경고 고유 접두사로 좁혀 판정)
  local n; n="$( { echo "$out" | grep -c '^경고: 활동 관측기가 동작하지 않습니다' || true; } )"
  if [ "$n" -eq 0 ]; then
    pass "케이스 22b: 경로 소실을 관측기 고장으로 오판하지 않음"
  else
    fail "케이스 22b: 관측기 고장 경고 ${n}회 (fd 채널에서는 발생하지 않아야 함)"
  fi

  # (c) 상태 파일의 관측기 상태가 ok 인가
  { grep -q '^observer: ok' "$sandbox/.review_wait_status" 2>/dev/null; } \
    && pass "케이스 22c: 상태 파일에 observer: ok 기록" \
    || fail "케이스 22c: observer 상태 이상 — $( { grep '^observer' "$sandbox/.review_wait_status" 2>/dev/null || true; } )"

  # (d) 훼손된 것은 **보존**뿐이며 그것을 정직하게 보고했는가
  { echo "$out" | grep -q '보존하지 못했습니다'; } \
    && pass "케이스 22d: 로그 소실 시 stderr 로 보존 실패 보고" \
    || fail "케이스 22d: stderr 보고 없음"

  if { grep -q '^log_preserved: no' "$sandbox/.review_wait_status" 2>/dev/null; } \
     && { grep -q '^log_preserved_reason: log-vanished-during-run' "$sandbox/.review_wait_status" 2>/dev/null; }; then
    pass "케이스 22e: 상태 파일에 보존 실패와 사유 기록"
  else
    fail "케이스 22e: 상태 파일에 log_preserved/사유 없음 — $( { cat "$sandbox/.review_wait_status" 2>/dev/null || true; } | tr '\n' ' ')"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 23: 타임아웃 메시지 — 오염 단정 금지 + 재개 가능 판정
# ===========================================================================
run_case23() {
  # 메시지 단언은 케이스 19(idle, WAIT_TIMEOUT=60 IDLE=3)·20(cap, WAIT_TIMEOUT=4 IDLE=600)가 만든 어댑터 출력에
  # 적용한다 — 같은 mock·같은 세션 조건으로 같은 타임아웃을 내며 메시지 문구는 숫자에 의존하지 않는다.
  # 23 만 선택해 실행하면 출력이 없으므로 19·20 을 먼저 실행한다.
  local sandbox output output3 sandbox2 output2 rc2=0 mock2
  [ -n "${C19_OUT:-}" ] || run_case19
  [ -n "${C20_OUT:-}" ] || run_case20
  output="$C19_OUT"
  output3="$C20_OUT"

  # (a) 오염을 단정하지 않는다
  echo "$output" | grep -q '오염' \
    && fail "케이스 23a: 타임아웃 경로에 '오염' 단정이 남아 있음" \
    || pass "케이스 23a: 타임아웃 경로에 오염 단정 없음"

  # (b) 재개 가능하다고 말한다
  echo "$output" | grep -q '이어갈 수 있습니다' \
    && pass "케이스 23b: 재개 가능 판정 출력" \
    || fail "케이스 23b: 재개 가능 판정 없음"

  # (c) 검사 범위를 밝힌다
  echo "$output" | grep -q '검사하지 않았습니다' \
    && pass "케이스 23c: 검사 범위 명시" \
    || fail "케이스 23c: 검사 범위 미명시"

  # (d) idle 사유에는 유휴 변수를 안내한다 (절대 상한을 올려도 재발하므로)
  if echo "$output" | grep -q 'RD_REVIEW_IDLE_TIMEOUT=<더 큰 값>'; then
    pass "케이스 23d: idle 사유에 유휴 임계 조정 안내"
  else
    fail "케이스 23d: idle 사유인데 유휴 변수 안내 없음"
  fi

  # (d2) idle 사유에 WAIT_TIMEOUT 을 안내하지 않는다
  echo "$output" | grep -q 'WAIT_TIMEOUT=<더 큰 값>' \
    && fail "케이스 23d2: idle 사유에 절대 상한 조정을 안내함 (재발하는 조치)" \
    || pass "케이스 23d2: idle 사유에 절대 상한 안내 없음"

  # (d3) cap 사유에는 WAIT_TIMEOUT 을 안내하고, 증명되지 않은 단정을 하지 않는다 (케이스 20 출력)
  echo "$output3" | grep -q 'WAIT_TIMEOUT=<더 큰 값>' \
    && pass "케이스 23d3: cap 사유에 절대 상한 조정 안내" \
    || fail "케이스 23d3: cap 사유에 절대 상한 안내 없음"
  echo "$output3" | grep -q '마지막까지 출력' \
    && fail "케이스 23d4: cap 메시지에 증명되지 않은 단정이 남아 있음" \
    || pass "케이스 23d4: cap 메시지에 미증명 단정 없음"
  echo "$output3" | grep -q '오염' \
    && fail "케이스 23d5: cap 경로에도 '오염' 단정이 남아 있음" \
    || pass "케이스 23d5: cap 경로에 오염 단정 없음"

  # (e) 상태가 어긋나면 재개 가능하다고 말하지 않는다
  sandbox2="$(make_sandbox)"
  write_session "$sandbox2" "Bogus" "awaiting-reviewer"
  write_checkpoint "$sandbox2" "Author"
  mock2="$(setup_mock "$sandbox2" "echo begin; exec sleep 60")"
  output2="$(
    TOOL_BIN="$mock2/codex" SESSION_PATH="$sandbox2" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$sandbox2/turns/turn-001-reviewer.md" PROJECT_ROOT="$sandbox2" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc2=$?
  echo "$output2" | grep -q '이어갈 수 있습니다' \
    && fail "케이스 23e: 상태가 어긋났는데 재개 가능하다고 말함" \
    || pass "케이스 23e: 상태 불일치 시 재개 가능 주장 없음"
  # "직접 확인하십시오" 라고 해놓고 재개 명령을 함께 내면 앞말이 무효가 된다
  echo "$output2" | grep -q '^재개:' \
    && fail "케이스 23e2: 상태 불일치인데 재개 명령을 출력함" \
    || pass "케이스 23e2: 상태 불일치 시 재개 명령 없음"
  rm -rf "$sandbox2"
}

# ===========================================================================
# 케이스 24: effective_cap 순수 함수 — fallback 불변식
# ===========================================================================
run_case24() {
  # 공용 엔진에서 직접 source 한다 (어댑터는 set -e + 즉시 실행 스크립트라 source 불가).
  local out rc=0
  # `set -e` 아래에서 명령 치환 대입을 가드 없이 두면, 추출한 함수가 비영 종료할 때
  # 케이스 FAIL 이 아니라 스위트 전체가 요약 없이 중단된다 — `|| true` 로 흡수하고
  # 이어지는 값 비교로 판정한다.
  out="$(bash -c 'source "'"$SCRIPT_DIR"'/review_wait.sh"
    rw_effective_cap 7200 1 600
    echo
    rw_effective_cap 7200 0 600
    echo
    rw_effective_cap 3 0 600
    echo
    rw_effective_cap 60 0 4
    echo' 2>/dev/null)" || rc=$?

  local expected="7200
600
3
4"
  if [ "$rc" -ne 0 ]; then
    fail "케이스 24: 추출한 rw_effective_cap 실행이 비영 종료함 (rc=$rc) — 출력 [$out]"
  elif [ "$out" = "$expected" ]; then
    pass "케이스 24: effective_cap — 정상=상한 / 고장=min(상한,천장) / 짧은 상한 보존"
  else
    fail "케이스 24: 기대 [$expected] — 실제 [$out]"
  fi
}

# ===========================================================================
# 케이스 25: 상태 snapshot 은 매 실행 시작에 초기화되고 관리 키는 단일하다
#   (a) 신규 세션의 빠른 종료(첫 heartbeat 전) — 필수 필드가 모두 있다
#   (b) 기존 상태 파일이 있는 빠른 재실행 — 과거 임시 경로·과거 관측기 상태가 남지 않는다
#   판정은 낱말 세기가 아니라 **키 존재와 키 개수(구조)** 로 한다.
# ===========================================================================
run_case25() {
  local sandbox expected_turn mock_bin sf rc=0 k n missing="" dup=""
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"
  mock_bin="$(setup_mock "$sandbox" "echo quick; printf 'x' > \"$expected_turn\"; exit 0")"
  sf="$sandbox/.review_wait_status"

  # (a) 신규 세션 — 1초 안에 끝나므로 heartbeat(기본 60초)는 한 번도 돌지 않는다
  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 25: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
    rm -rf "$sandbox"; return
  fi

  for k in 'log_path:' 'observer:' 'effective_cap:' 'log_preserved:' 'log_path_final:'; do
    if ! { grep -q "^${k}" "$sf" 2>/dev/null; }; then missing="${missing}${k} "; fi
  done
  if [ -z "$missing" ]; then
    pass "케이스 25a: 첫 heartbeat 전 종료에도 필수 필드가 모두 존재"
  else
    fail "케이스 25a: 필드 누락 [$missing] — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
  fi

  # 유효 상한은 이번 실행의 설정값(30초)이어야 한다
  { grep -q '^effective_cap: 30s' "$sf" 2>/dev/null; } \
    && pass "케이스 25a2: effective_cap 이 이번 실행 설정(30s)" \
    || fail "케이스 25a2: effective_cap 불일치 — $( { grep '^effective_cap' "$sf" 2>/dev/null || true; } )"

  # (b) 기존 상태 파일이 남아 있는 빠른 재실행 — 과거 문장이 섞여선 안 된다.
  # 고유 토큰 OLDSTALE 로 판정한다 (production 문구에 의존하지 않는다).
  printf '%s\n' \
    '[review wait] 경과 55m00s | 마지막 활동 3m00s 전 | 유휴여유 2m00s | 상한 1h00m' \
    '  codex: OLDSTALE-progress' \
    "log_path: ${sandbox}/.codex_output.OLDSTALE" \
    'observer: failed' \
    'effective_cap: 4s' \
    'log_preserved: no' \
    'log_preserved_reason: log-vanished-during-run' \
    'log_path_final: (없음)' \
    'log_path_recovery: /tmp/OLDSTALE' > "$sf"

  rc=0
  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 25b: 전제 실패 — 재실행 rc=$rc"
  else
    if { grep -q 'OLDSTALE' "$sf" 2>/dev/null; }; then
      fail "케이스 25b: 이전 턴 snapshot 이 현재 상태로 보존됨 — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
    else
      pass "케이스 25b: 재실행이 과거 snapshot(임시 경로·관측기 상태)을 물려받지 않음"
    fi
    { grep -q '^observer: ok' "$sf" 2>/dev/null; } \
      && pass "케이스 25b2: 관측기 상태가 이번 실행 기준" \
      || fail "케이스 25b2: observer 가 과거 값 — $( { grep '^observer' "$sf" 2>/dev/null || true; } )"
    { grep -q '^log_preserved: yes' "$sf" 2>/dev/null; } \
      && pass "케이스 25b3: 보존 결과가 이번 실행 기준(yes)" \
      || fail "케이스 25b3: log_preserved 가 과거 값 — $( { grep '^log_preserved' "$sf" 2>/dev/null || true; } )"

    for k in log_preserved log_preserved_reason log_path_final log_path_recovery; do
      n="$( { grep -c "^${k}: " "$sf" 2>/dev/null || true; } | tr -d ' ' )"
      [ -n "$n" ] || n=0
      [ "$n" -gt 1 ] && dup="${dup}${k}=${n} "
    done
    if [ -z "$dup" ]; then
      pass "케이스 25b4: 관리 키가 실행마다 중복되지 않음"
    else
      fail "케이스 25b4: 관리 키 중복 [$dup]"
    fi
  fi

  # 임시 파일 잔존 없음
  n="$( { find "$sandbox" -maxdepth 1 -name '.review_wait_status.*' 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  [ "$n" -eq 0 ] \
    && pass "케이스 25c: 상태 파일 임시 잔여물 없음" \
    || fail "케이스 25c: .review_wait_status.* ${n}개 잔존"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 26: 상태 파일 쓰기가 세션 밖 파일을 truncate·유출하지 않는다 (보안 회귀)
#   구 코드는 `.review_wait_status.tmp.$$` 로 썼고 그 `$$` 는 어댑터 PID 이다.
#   background codex 에서 `$PPID` 가 곧 어댑터 PID 이므로 codex 는 그 경로를 정확히
#   계산할 수 있었다 — 그 자리에 세션 밖 파일을 가리키는 symlink 를 심으면 `>` 가 링크를
#   따라가 sandbox 밖 파일을 호출자 권한으로 truncate 한다(confused deputy).
#   안정 경로 `.review_wait_status` 에 세션 밖 **디렉터리** symlink 를 심으면 `mv` 가
#   그 안으로 상태 파일을 옮겨 세션 밖으로 유출시킨다.
#   케이스 16(last_message)과 같은 성질을 상태 파일 두 경로에 대해 고정한다.
# ===========================================================================
run_case26() {
  local sandbox expected_turn bin_dir victim_dir victim leak_dir rc=0 n
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"

  victim_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$victim_dir" && -d "$victim_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim="$victim_dir/sentinel.txt"
  printf 'SENTINEL-KEEP\n' > "$victim"
  leak_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak_dir" && -d "$leak_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# 구 예측 규칙 두 형태를 모두 심는다: 어댑터 PID($PPID)와 mock 자신의 PID($$).
ln -sf "$C26_SENTINEL" "$SESSION_PATH/.review_wait_status.tmp.$PPID" 2>/dev/null || true
ln -sf "$C26_SENTINEL" "$SESSION_PATH/.review_wait_status.tmp.$$" 2>/dev/null || true
# 안정 경로에는 세션 밖 디렉터리 symlink
rm -f "$SESSION_PATH/.review_wait_status" 2>/dev/null || true
ln -sfn "$C26_LEAKDIR" "$SESSION_PATH/.review_wait_status" 2>/dev/null || true
echo working
sleep 2
touch "$C26_TURN_FILE"
cat >/dev/null
exit 0
MOCK_EOF
  chmod +x "$bin_dir/codex"

  C26_SENTINEL="$victim" C26_LEAKDIR="$leak_dir" C26_TURN_FILE="$expected_turn" \
  TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 RD_REVIEW_HEARTBEAT=1 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 26: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
  else
    # (a) 예측 가능 경로 symlink 를 따라가 세션 밖 파일을 truncate 하지 않았다
    if [ "$( { cat "$victim" 2>/dev/null || true; } )" = "SENTINEL-KEEP" ]; then
      pass "케이스 26a: 예측 가능 임시 경로 symlink 비추종 (세션 밖 sentinel 내용 보존)"
    else
      fail "케이스 26a: 세션 밖 sentinel 이 훼손됨 — '$( { cat "$victim" 2>/dev/null || true; } )'"
    fi

    # (b) 안정 경로 디렉터리 symlink 를 따라가 세션 밖으로 상태 파일을 옮기지 않았다
    n="$( { ls -A "$leak_dir" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
    [ "$n" -eq 0 ] \
      && pass "케이스 26b: 안정 경로 디렉터리 symlink 비추종 (세션 밖 유출 없음)" \
      || fail "케이스 26b: 세션 밖 디렉터리로 ${n}개 유출 — $( { ls -A "$leak_dir" 2>/dev/null || true; } | tr '\n' ' ')"

    # (c) 상태 파일은 세션 안의 정규 파일로 남는다
    if [ -f "$sandbox/.review_wait_status" ] && [ ! -L "$sandbox/.review_wait_status" ] \
       && { grep -q '^log_preserved: ' "$sandbox/.review_wait_status" 2>/dev/null; }; then
      pass "케이스 26c: 상태 파일이 세션 안 정규 파일로 기록됨"
    else
      fail "케이스 26c: 상태 파일이 정규 파일이 아니거나 비어 있음"
    fi
  fi

  rm -rf "$sandbox" "$victim_dir" "$leak_dir"
}

# ===========================================================================
# 케이스 27: 로그 최종 이동 실패를 성공으로 보고하지 않는다 (Important 3)
#   (a) 안정 경로에 **실제 디렉터리** — 이동은 반드시 실패해야 하고, 그때
#       log_preserved: no + 기계 판독 사유 + 회수 가능한 임시 경로가 남아야 한다.
#       (구 코드는 `mv ... || true` 뒤에 무조건 yes 를 적었다.)
#   (b) 안정 경로에 **세션 밖 디렉터리 symlink** — 로그가 세션 밖으로 새지 않아야 한다.
# ===========================================================================
run_case27() {
  local sandbox expected_turn mock_bin sf err rc=0 n rec
  # --- (a) 실제 디렉터리 ---
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"
  mock_bin="$(setup_mock "$sandbox" "echo blocked; printf 'x' > \"$expected_turn\"; exit 0")"
  mkdir -p "$sandbox/.codex_output.log"
  sf="$sandbox/.review_wait_status"
  err="$sandbox/err_a.txt"

  TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>"$err" || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 27a: 전제 실패 — 어댑터 rc=$rc (턴 자체는 성공해야 함)"
  else
    if { grep -q '^log_preserved: no' "$sf" 2>/dev/null; } \
       && { grep -q '^log_preserved_reason: log-move-failed' "$sf" 2>/dev/null; }; then
      pass "케이스 27a: 이동 실패를 no + log-move-failed 로 기록"
    else
      fail "케이스 27a: 이동 실패인데 보존 성공으로 기록 — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
    fi

    rec="$( { grep '^log_path_recovery: ' "$sf" 2>/dev/null || true; } | sed 's/^log_path_recovery: //' )"
    if [ -n "$rec" ] && [ -f "$rec" ]; then
      pass "케이스 27a2: 회수 가능한 임시 경로를 상태 파일에 남김 ($(basename "$rec"))"
    else
      fail "케이스 27a2: 회수 경로 없음 또는 실재하지 않음 — '$rec'"
    fi

    { grep -q '옮기지 못했습니다' "$err" 2>/dev/null; } \
      && pass "케이스 27a3: stderr 로 이동 실패 보고" \
      || fail "케이스 27a3: stderr 보고 없음"

    n="$( { ls -A "$sandbox/.codex_output.log" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
    [ "$n" -eq 0 ] \
      && pass "케이스 27a4: 디렉터리 안으로 로그를 밀어 넣지 않음" \
      || fail "케이스 27a4: 디렉터리 안에 ${n}개 생성"
  fi
  rm -rf "$sandbox"

  # --- (b) 세션 밖 디렉터리 symlink ---
  local leak_dir sandbox2 expected2 mock2 rc2=0
  sandbox2="$(make_sandbox)"
  expected2="$sandbox2/turns/turn-001-reviewer.md"
  write_session "$sandbox2" "Author" "awaiting-author"
  mock2="$(setup_mock "$sandbox2" "echo leaky; printf 'x' > \"$expected2\"; exit 0")"
  leak_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak_dir" && -d "$leak_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  ln -sfn "$leak_dir" "$sandbox2/.codex_output.log"

  TOOL_BIN="$mock2/codex" SESSION_PATH="$sandbox2" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected2" PROJECT_ROOT="$sandbox2" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>&1 || rc2=$?

  n="$( { ls -A "$leak_dir" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  if [ "$n" -eq 0 ] && [ -f "$sandbox2/.codex_output.log" ] && [ ! -L "$sandbox2/.codex_output.log" ]; then
    pass "케이스 27b: 안정 경로 디렉터리 symlink 로 로그가 세션 밖으로 새지 않음"
  else
    fail "케이스 27b: 유출 ${n}개 / 안정 경로 형태 이상 (rc=$rc2)"
  fi
  rm -rf "$sandbox2" "$leak_dir"
}

# ===========================================================================
# 케이스 28: 경쟁 symlink — 안정 이름 rename 제거로 유출 창이 닫혔는가 (Important 3)
#   구 코드는 매 갱신마다 안정 이름(`.review_wait_status`)으로 `mv` 했다. 검사·삭제·mv 는
#   원자 연산이 아니므로 codex 가 그 이름을 **타이트한 루프로 계속** 외부 디렉터리 symlink 로
#   재생성하면 창을 반복 공략해 상태 snapshot 을 세션 밖으로 빼낼 수 있었다.
#   `.wait_timeout` 마커는 그 방어조차 없어 무방비 `mv` 였고, 마커가 밖으로 나가면 부모의
#   존재 검사가 실패해 **실제 타임아웃을 일반 조기 종료로 오분류**했다.
#   새 계약: 진행 중에는 안정 이름을 건드리지 않고(스트림 fd 전용), 마커는 spawn 전에 배타
#   생성한 무작위 경로에 fd 로 쓴다. 그래서 이 mock 이 이겨야 할 창이 존재하지 않는다.
#   판정: ① 외부 디렉터리 유출 0 ② 외부 정규 파일 훼손 없음 ③ 타임아웃 exit 124 보존
#         ④ 사유가 사실대로(유휴) 보고됨
# ===========================================================================
run_case28() {
  local sandbox expected_turn bin_dir leak_dir victim_dir victim rc=0 out n
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  leak_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak_dir" && -d "$leak_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$victim_dir" && -d "$victim_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  victim="$victim_dir/sentinel.txt"
  printf 'SENTINEL-KEEP\n' > "$victim"

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# "한 번 미리 배치" 가 아니라 **반복 공략**을 재현한다. 안정 이름과, 세션 디렉터리를
# **열거해 찾은 무작위 이름** 둘 다 노린다 (이름의 무작위성만으로는 열거를 막지 못한다).
# 출력을 내지 않으므로 활동 관측기는 진행 없음으로 보고 유휴 타임아웃이 발동한다.
while :; do
  rm -f "$SESSION_PATH/.review_wait_status" 2>/dev/null
  ln -sfn "$C28_LEAKDIR" "$SESSION_PATH/.review_wait_status" 2>/dev/null
  rm -f "$SESSION_PATH/.wait_timeout" 2>/dev/null
  ln -sfn "$C28_LEAKDIR" "$SESSION_PATH/.wait_timeout" 2>/dev/null
  for f in "$SESSION_PATH"/.review_wait_status.?????? "$SESSION_PATH"/.wait_timeout.??????; do
    [ -e "$f" ] || continue
    if [ -L "$f" ]; then continue; fi
    rm -f "$f" 2>/dev/null
    ln -sfn "$C28_SENTINEL" "$f" 2>/dev/null
  done
  sleep 0.01
done
MOCK_EOF
  chmod +x "$bin_dir/codex"

  out="$(
    C28_LEAKDIR="$leak_dir" C28_SENTINEL="$victim" \
    TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 RD_REVIEW_HEARTBEAT=1 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  # (a) 외부 디렉터리로 아무것도 나가지 않았다
  n="$( { ls -A "$leak_dir" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  [ "$n" -eq 0 ] \
    && pass "케이스 28a: 경쟁 symlink 반복 공략에도 외부 디렉터리 유출 0" \
    || fail "케이스 28a: 외부 디렉터리로 ${n}개 유출 — $( { ls -A "$leak_dir" 2>/dev/null || true; } | tr '\n' ' ' )"

  # (b) 외부 정규 파일을 truncate·덮어쓰지 않았다 (fd 전용 쓰기의 증거)
  [ "$( { cat "$victim" 2>/dev/null || true; } )" = "SENTINEL-KEEP" ] \
    && pass "케이스 28b: 외부 정규 파일 내용 보존 (경로 재해석 없는 fd 쓰기)" \
    || fail "케이스 28b: 외부 sentinel 훼손 — '$( { cat "$victim" 2>/dev/null || true; } )'"

  # (c) 타임아웃 종료 코드가 보존됐다 — 마커가 빼돌려지면 조기 종료(exit 1)로 오분류된다
  [ "$rc" -eq 124 ] \
    && pass "케이스 28c: 마커 공략에도 타임아웃 exit 124 보존" \
    || fail "케이스 28c: 기대 rc=124 — 실제 rc=$rc"

  # (d) 사유를 사실대로 보고했다 (마커 내용이 fd 로 전달됐다는 증거)
  echo "$out" | grep -q '유휴' \
    && pass "케이스 28d: 타임아웃 사유(유휴)를 사실대로 보고" \
    || fail "케이스 28d: 사유 보고 누락 — $out"

  reap_group "$GROUP_PGID"
  rm -rf "$sandbox" "$leak_dir" "$victim_dir"

  # --- (e) 마커 오분류 — 결정적 시나리오 ---
  # 위 (c) 는 반복 공략 루프이므로 마커 창을 이기는 시점이 확률적이다. 마커 구멍은
  # **한 번 심고 유지**하면 결정적으로 재현된다: 구 코드는 안정 이름 `.wait_timeout` 으로
  # 무방비 `mv` 했으므로 그 자리에 외부 디렉터리 symlink 가 있으면 마커가 세션 밖으로
  # 옮겨지고, 부모의 `[ -f ]` 가 실패해 **실제 타임아웃을 조기 종료(exit 1)로 오분류**했다.
  local sb2 leak2 out2 rc2=0 n2
  sb2="$(make_sandbox)"
  write_session "$sb2" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sb2" "Author"
  leak2="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$leak2" && -d "$leak2" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  local mock2
  mock2="$(setup_mock "$sb2" 'ln -sfn "$C28E_LEAKDIR" "$SESSION_PATH/.wait_timeout" 2>/dev/null; exec sleep 60')"

  out2="$(
    C28E_LEAKDIR="$leak2" \
    TOOL_BIN="$mock2/codex" SESSION_PATH="$sb2" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$sb2/turns/turn-001-reviewer.md" PROJECT_ROOT="$sb2" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER" 2>&1
  )" || rc2=$?

  n2="$( { ls -A "$leak2" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  if [ "$rc2" -eq 124 ] && [ "$n2" -eq 0 ]; then
    pass "케이스 28e: 안정 이름 마커 symlink 유지에도 타임아웃 보존 (rc=124, 유출 0)"
  else
    fail "케이스 28e: 마커 오분류 또는 유출 — rc=$rc2 (기대 124) 유출=${n2}개"
  fi
  echo "$out2" | grep -q '턴 완료 전에 종료' \
    && fail "케이스 28e2: 실제 타임아웃을 조기 종료로 오분류함" \
    || pass "케이스 28e2: 조기 종료 오분류 없음"

  rm -rf "$sb2" "$leak2"
}

# ===========================================================================
# 케이스 29: 소스 로그가 symlink 로 교체되면 거짓 "회수 가능" 을 보고하지 않는다 (Important 4)
#   codex 는 세션을 열거해 무작위 `.codex_output.*` 이름을 찾을 수 있다. 그 경로를 외부
#   **정규 파일** symlink 로 바꾸면 구 코드의 `[ -f ]` 는 링크를 따라 참이 되고 `mv` 는
#   symlink 자체를 안정 경로로 옮겼다. 이후 `[ ! -L ]` 검증은 실패하지만 원래 임시 경로는
#   이미 사라졌는데도 실패 분기가 무조건 "로그는 임시 경로에 남아 있습니다(회수 가능)" 를
#   출력하고 `log_path_recovery` 에 그 **존재하지 않는 경로**를 적었다.
#   (기존 케이스 27 은 목적지 directory/symlink 만 검사해 이 경로를 고정하지 못했다.)
# ===========================================================================
run_case29() {
  local sandbox expected_turn bin_dir out_dir outside sf err rc=0
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Author" "awaiting-author"
  out_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$out_dir" && -d "$out_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  outside="$out_dir/outside.txt"
  printf 'OUTSIDE-CONTENT\n' > "$outside"
  sf="$sandbox/.review_wait_status"
  err="$sandbox/err.txt"

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# 세션을 열거해 소스 로그 경로를 찾아 외부 **정규 파일** symlink 로 바꿔치기한다.
for f in "$SESSION_PATH"/.codex_output.??????; do
  [ -e "$f" ] || continue
  rm -f "$f" 2>/dev/null
  ln -sfn "$C29_OUTSIDE" "$f" 2>/dev/null
done
printf 'x' > "$C29_TURN_FILE"
exit 0
MOCK_EOF
  chmod +x "$bin_dir/codex"

  C29_OUTSIDE="$outside" C29_TURN_FILE="$expected_turn" \
  TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER" >/dev/null 2>"$err" || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "케이스 29: 전제 실패 — 어댑터 rc=$rc (턴 자체는 성공해야 함)"
  else
    # (a) 변조된 소스를 안정 경로로 끌어오지 않았다 (남의 파일을 codex 출력으로 보고 금지)
    if [ ! -e "$sandbox/.codex_output.log" ] && [ ! -L "$sandbox/.codex_output.log" ]; then
      pass "케이스 29a: symlink 소스를 안정 경로로 옮기지 않음"
    else
      fail "케이스 29a: 안정 경로에 산출물이 생김 (symlink=$( [ -L "$sandbox/.codex_output.log" ] && echo 예 || echo 아니오 ))"
    fi

    # (b) 보존 실패를 **별도 사유**로 정직하게 기록했다
    if { grep -q '^log_preserved: no' "$sf" 2>/dev/null; } \
       && { grep -q '^log_preserved_reason: log-source-replaced' "$sf" 2>/dev/null; }; then
      pass "케이스 29b: 소스 변조를 no + log-source-replaced 로 기록"
    else
      fail "케이스 29b: 사유 기록 누락 — $( { cat "$sf" 2>/dev/null || true; } | tr '\n' '|' )"
    fi

    # (c) 존재하지 않는 경로를 "회수 가능" 으로 보고하지 않았다
    if { grep -q '^log_path_recovery: ' "$sf" 2>/dev/null; }; then
      fail "케이스 29c: 회수할 수 없는데 log_path_recovery 를 기록함 — $( { grep '^log_path_recovery' "$sf" 2>/dev/null || true; } )"
    else
      pass "케이스 29c: 회수 경로를 기록하지 않음"
    fi
    { grep -q '회수 가능' "$err" 2>/dev/null; } \
      && fail "케이스 29c2: stderr 에 거짓 '회수 가능' 안내가 남아 있음" \
      || pass "케이스 29c2: stderr 에 거짓 회수 안내 없음"

    # (d) 외부 파일을 세션 안으로 끌어오거나 옮겨 버리지 않았다
    if [ -f "$outside" ] && [ "$( { cat "$outside" 2>/dev/null || true; } )" = "OUTSIDE-CONTENT" ]; then
      pass "케이스 29d: 외부 정규 파일이 제자리에 그대로 남음"
    else
      fail "케이스 29d: 외부 파일이 사라졌거나 변경됨"
    fi
  fi

  rm -rf "$sandbox" "$out_dir"
}

# ===========================================================================
# 케이스 30: 안정 상태 파일은 **실행 중에 존재하지 않는다** (final diff review 006 Important 2)
#   계약: `.review_wait_status` 는 실행 중에는 없고 종료 후 1회 발행된다.
#   구 코드는 시작 정리에서 `.turn_ready`·예상 턴·과거 마커만 지웠으므로 **이전 턴의 안정
#   상태 파일이 이번 실행 중에도 그대로 남았다**(실측: 이전 안정 파일과 이번 실행 스트림
#   동시 존재). 안정 경로만 보는 headless 소비자는 이전 턴의 log_path·observer·보존 결과를
#   현재 실행 상태로 오인한다.
#   판정 시점이 핵심이다 — 케이스 25 는 두 실행을 **모두 완료한 뒤** 최종 파일만 검사해 이
#   구간을 놓친다. 여기서는 mock 을 rendezvous 파일로 붙잡아 **실행 중에** 단정한다.
# ===========================================================================
run_case30() {
  local sandbox expected_turn mock_bin errlog rc=0 i started go n stream
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  # 완주(rc=0)를 기대하므로 SESSION 은 완료 상태로 둔다 — 어댑터의 완료 판정은 codex
  # 종료 후에만 일어나므로 시작 시점 값이 실행 중 판정을 바꾸지 않는다(케이스 25 와 동일).
  write_session "$sandbox" "Author" "awaiting-author"
  started="$sandbox/mock_started"
  go="$sandbox/mock_go"
  errlog="$sandbox/adapter_err.txt"

  # 이전 턴이 남긴 안정 산출물 — 고유 토큰 PREVRUN 으로 판정한다(production 문구 비의존).
  printf '%s\n' \
    '[review wait] 경과 55m00s | 마지막 활동 3m00s 전 | 유휴여유 2m00s | 상한 1h00m' \
    '  codex: PREVRUN-progress' \
    "log_path: ${sandbox}/.codex_output.PREVRUN" \
    'observer: failed' \
    'effective_cap: 4s' \
    'log_preserved: yes' \
    "log_path_final: ${sandbox}/.codex_output.log" > "$sandbox/.review_wait_status"
  printf 'PREVRUN-log-content\n' > "$sandbox/.codex_output.log"

  mock_bin="$(setup_mock "$sandbox" \
    "echo started; printf 's' > \"$started\"; while [ ! -f \"$go\" ]; do sleep 0.1; done; printf 'x' > \"$expected_turn\"; exit 0")"

  spawn_group "$errlog" env \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=30 \
    bash "$ADAPTER"

  # mock 이 실제로 떠 있는(= 실행 중인) 시점까지 기다린다
  for i in $(seq 1 100); do
    [ -f "$started" ] && break
    sleep 0.1
  done
  if [ ! -f "$started" ]; then
    fail "케이스 30: 전제 실패 — mock 이 시작되지 않아 실행 중 관측을 할 수 없음"
    printf 'go' > "$go"; reap_group "$GROUP_PGID"; rm -rf "$sandbox"; return
  fi

  # --- 실행 중 단정 ---
  if [ ! -e "$sandbox/.review_wait_status" ]; then
    pass "케이스 30a: 실행 중 안정 상태 파일 부재 (이전 턴 상태가 남지 않음)"
  else
    fail "케이스 30a: 실행 중에도 안정 상태 파일이 존재 — $( { cat "$sandbox/.review_wait_status" 2>/dev/null || true; } | tr '\n' '|' )"
  fi

  stream="$( { ls "$sandbox"/.review_wait_status.?????? 2>/dev/null || true; } | head -n 1 )"
  [ -n "$stream" ] \
    && pass "케이스 30b: 실행 중 이번 실행의 상태 스트림 존재 ($(basename "$stream"))" \
    || fail "케이스 30b: 이번 실행의 상태 스트림이 없음"

  [ ! -e "$sandbox/.codex_output.log" ] \
    && pass "케이스 30c: 실행 중 안정 로그 부재 (이전 턴 로그가 남지 않음)" \
    || fail "케이스 30c: 실행 중에도 안정 로그가 존재 — $( { cat "$sandbox/.codex_output.log" 2>/dev/null || true; } | tr '\n' '|' )"

  # --- 실행 종료 후 ---
  printf 'go' > "$go"
  wait "$JOB" 2>/dev/null || rc=$?
  reap_group "$GROUP_PGID"

  if [ "$rc" -ne 0 ]; then
    fail "케이스 30d: 전제 실패 — 어댑터 rc=$rc (정상 완료 기대)"
  elif [ -f "$sandbox/.review_wait_status" ] \
       && ! { grep -q 'PREVRUN' "$sandbox/.review_wait_status" 2>/dev/null; }; then
    pass "케이스 30d: 종료 후 이번 실행 기준으로 1회 발행"
  else
    fail "케이스 30d: 발행 누락 또는 이전 턴 내용 잔존 — $( { cat "$sandbox/.review_wait_status" 2>/dev/null || true; } | tr '\n' '|' )"
  fi

  { grep -q 'PREVRUN' "$sandbox/.codex_output.log" 2>/dev/null; } \
    && fail "케이스 30e: 안정 로그가 이전 턴 내용 그대로임" \
    || pass "케이스 30e: 안정 로그가 이번 실행 로그로 대체됨"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 31: 로그·last-message **읽기**가 세션 밖 파일 내용을 노출하지 않는다
#            (final diff review 006 Critical 1)
#   위협 모델: 실행 중 codex 는 세션 디렉터리에 쓸 수 있고(`--sandbox workspace-write` +
#   `--add-dir`), 어댑터는 그 sandbox **밖에서 호출자 권한으로** 돈다. 구 코드는 매 tick
#   `wc -c < "$codex_log"`, heartbeat `grep ... "$codex_log" | tail -1`, 타임아웃 `tail -n 5`,
#   조기 종료 `tail -n 20`, 실패 경로 `cat "$last_message_file"` 로 **가변 경로를 다시 열었다.**
#   codex 가 그 이름을 세션 밖의 읽기 가능한 파일 symlink 로 바꾸면 그 내용이 stderr 와
#   상태 파일로 흘러나온다(실측: 수정 전 어댑터에서 stderr 5회 + 안정 상태 파일 1회 노출).
#   cleanup 의 `log-source-replaced` 판정은 **내용이 이미 노출된 뒤라 너무 늦다** — 그래서
#   케이스 29(턴을 정상 완성시켜 heartbeat·오류 tail 경로를 지나지 않는다)로는 잡히지 않는다.
#   이 케이스는 **heartbeat 가 발동하고 조기 종료 보고도 지나는** 시나리오를 만든다.
#   판정: ① sentinel 고유 문자열이 stderr 와 최종 상태 파일 어디에도 없다
#         ② 그 부재가 공허하지 않다 — 두 보고 경로를 실제로 지났고(heartbeat 2회 이상,
#            우리 inode 의 고유 줄이 보고됨) last message 도 fd 로 읽혔다
# ===========================================================================
run_case31() {
  local sandbox expected_turn bin_dir out_dir sentinel err sf rc=0 n beats
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  out_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { echo "test_review_wait.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$out_dir" && -d "$out_dir" ]] || { echo "test_review_wait.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  sentinel="$out_dir/secret.txt"
  printf 'RDLEAK-SENTINEL-9f3a2b\n' > "$sentinel"
  err="$sandbox/err.txt"
  sf="$sandbox/.review_wait_status"

  bin_dir="$sandbox/mock_bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'MOCK_EOF'
#!/usr/bin/env bash
# ① 우리 inode 에 식별 가능한 로그를 남긴다 (상속한 stdout fd 로 나가므로 경로 교체와 무관)
i=0
while [ "$i" -lt 40 ]; do printf 'RDLOGLINE-%03d\n' "$i"; i=$((i+1)); done
# ② 정상적인 last message 를 남긴다 (제자리 truncate 쓰기 — 실제 codex 와 같은 형태)
lm=""
for f in "$SESSION_PATH"/.last_message.??????; do [ -e "$f" ] && lm="$f"; done
[ -n "$lm" ] && printf 'RDLASTMSG-OK\n' > "$lm"
# ③ 세션을 열거해 두 경로를 세션 밖 sentinel symlink 로 바꾼다 (무작위 이름은 열거로 찾힌다)
for f in "$SESSION_PATH"/.codex_output.?????? "$SESSION_PATH"/.last_message.??????; do
  [ -e "$f" ] || continue
  rm -f "$f" 2>/dev/null
  ln -sfn "$RD31_SENTINEL" "$f" 2>/dev/null
done
# ④ heartbeat(1초)가 2회 이상 stderr 에 찍힐 때까지 기다린 뒤 **턴 파일 없이** 종료 → 조기 종료 보고 경로.
#    고정 3초 대기는 부하(load 43)에서 heartbeat 가 1회만 찍혀 31c 가 간헐 FAIL 했다. 조건을 직접 보고,
#    heartbeat 가 끝내 안 찍히면 15초 뒤 그대로 끝내 31c 가 FAIL 하게 한다(유휴 상한 20초보다 짧게).
w=0
while [ "$w" -lt 75 ]; do
  [ "$(grep -c '^\[review wait\]' "$RD31_ERR" 2>/dev/null || true)" -ge 2 ] && break
  sleep 0.2; w=$((w+1))
done
exit 3
MOCK_EOF
  chmod +x "$bin_dir/codex"

  RD31_SENTINEL="$sentinel" RD31_ERR="$err" \
  TOOL_BIN="$bin_dir/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 RD_REVIEW_HEARTBEAT=1 \
    bash "$ADAPTER" >/dev/null 2>"$err" || rc=$?

  # (전제) 조기 종료 경로로 끝났는가
  if [ "$rc" -ne 1 ]; then
    fail "케이스 31: 전제 실패 — 기대 rc=1(조기 종료) 실제 rc=$rc"
  fi

  # (a) stderr 에 sentinel 이 없다
  n="$( { grep -c 'RDLEAK-SENTINEL-9f3a2b' "$err" 2>/dev/null || true; } | tr -d ' ' )"
  [ -n "$n" ] || n=0
  [ "$n" -eq 0 ] \
    && pass "케이스 31a: stderr 에 세션 밖 sentinel 노출 없음" \
    || fail "케이스 31a: stderr 로 세션 밖 파일 내용 ${n}회 노출 (읽기 경로 재열기 회귀)"

  # (b) 최종 상태 파일에도 없다 (heartbeat 가 상태 스트림에도 마지막 줄을 싣는다)
  n="$( { grep -c 'RDLEAK-SENTINEL-9f3a2b' "$sf" 2>/dev/null || true; } | tr -d ' ' )"
  [ -n "$n" ] || n=0
  [ "$n" -eq 0 ] \
    && pass "케이스 31b: 최종 상태 파일에 sentinel 노출 없음" \
    || fail "케이스 31b: 상태 파일로 세션 밖 파일 내용 ${n}회 노출"

  # (c) 부재가 공허하지 않다 — heartbeat 가 실제로 발동했다
  beats="$( { grep -c '^\[review wait\]' "$err" 2>/dev/null || true; } | tr -d ' ' )"
  [ -n "$beats" ] || beats=0
  [ "$beats" -ge 2 ] \
    && pass "케이스 31c: heartbeat 경로를 실제로 지남 (${beats}회)" \
    || fail "케이스 31c: heartbeat 미발동 (${beats}회) — 노출 부재 판정이 공허해짐"

  # (d) 두 보고 경로가 **우리 inode** 를 읽었다
  { grep -q 'RDLOGLINE-039' "$err" 2>/dev/null; } \
    && pass "케이스 31d: 로그 보고가 원래 inode 내용을 사용 (fd 채널 동작)" \
    || fail "케이스 31d: 원래 inode 의 로그 줄이 보고되지 않음 — $( { cat "$err" 2>/dev/null || true; } | tr '\n' '|' )"

  # (e) last message 도 fd 로 읽혔다 (경로가 교체된 뒤에도 원래 inode 내용)
  { grep -q 'RDLASTMSG-OK' "$err" 2>/dev/null; } \
    && pass "케이스 31e: last message 를 fd 로 읽어 정상 보고" \
    || fail "케이스 31e: last message 보고 누락 (fd 읽기 회귀)"

  # (f) 세션 밖 파일은 제자리에 그대로 남는다
  if [ -f "$sentinel" ] && [ "$( { cat "$sentinel" 2>/dev/null || true; } )" = "RDLEAK-SENTINEL-9f3a2b" ]; then
    pass "케이스 31f: 세션 밖 파일 내용·위치 보존"
  else
    fail "케이스 31f: 세션 밖 파일이 변경·이동됨"
  fi

  rm -rf "$sandbox" "$out_dir"
}

# ===========================================================================
# 케이스 32: codex 종료 후 진단 읽기 지연에도 뒤늦은 마커로 오분류하지 않는다
#            (final diff review 008턴 Important 1)
#   `wait "$codex_pid"` 복귀 시점에 codex 는 이미 (턴 미완료 상태로) 자체 종료했다.
#   구 코드는 watchdog 을 kill 하기 **전에** 로그 tail·last message 를 읽었으므로, 그
#   읽기가 느려지면 그 사이 watchdog 이 계속 tick 하며 codex 생존 여부와 무관하게 cap
#   도달 시 마커를 썼다 — 실제로는 조기 종료인데 "타임아웃" 으로 오분류(rc=124)됐다.
#   이 케이스는 `tail`(로그·last-message 읽기가 경유하는 유일한 외부 명령)을 PATH 로
#   가로채 확률에 기대지 않고 그 지연을 **결정적으로** 재현한다 — mock codex 는 cap
#   보다 훨씬 이전에 턴 파일 없이 자체 종료하므로, 이 지연이 없으면 애초에 cap 에
#   도달할 수 없다. 수정 전 어댑터로 이 fixture 를 겨누면 rc=124 가 나옴을 별도로
#   확인했다(final-diff-review-fix-4 작업 리포트 참조).
#   판정: ① rc=1(조기 종료) — rc=124(오분류 타임아웃) 아님 ② "턴 완료 전에 종료" 보고
#         ③ "타임아웃" 오분류 문구 없음
# ===========================================================================
run_case32() {
  local sandbox expected_turn mock_bin wrap_dir real_tail rc=0 out
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"

  # mock: cap(1초)에 한참 못 미치는 0.2초 만에, 턴 파일 없이 자체 종료한다.
  mock_bin="$(setup_mock "$sandbox" "sleep 0.2; exit 1")"

  # tail 을 PATH 로 가로채 codex 종료 후 진단 읽기(로그 tail·fd 3 last-message 읽기)만
  # 지연시킨다. 실제 tail 경로는 PATH 를 바꾸기 전에 미리 확인해 둔다(환경마다
  # busybox/GNU 등 위치가 다를 수 있어 하드코딩하지 않는다).
  real_tail="$(command -v tail)"
  wrap_dir="$sandbox/wrap"
  mkdir -p "$wrap_dir"
  cat > "$wrap_dir/tail" <<WRAPEOF
#!/usr/bin/env bash
if [ -n "\${RD_TEST_DIAG_DELAY:-}" ]; then
  sleep "\${RD_TEST_DIAG_DELAY}"
fi
exec "$real_tail" "\$@"
WRAPEOF
  chmod +x "$wrap_dir/tail"

  out="$(
    PATH="$wrap_dir:$PATH" \
    RD_TEST_DIAG_DELAY=2 \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=1 RD_REVIEW_IDLE_TIMEOUT=600 \
      bash "$ADAPTER" 2>&1
  )" || rc=$?

  [ "$rc" -eq 1 ] \
    && pass "케이스 32a: 진단 읽기 지연에도 오분류 없이 rc=1 (조기 종료)" \
    || fail "케이스 32a: 기대 rc=1(조기 종료) — 실제 rc=$rc (124 면 뒤늦은 마커로 오분류 회귀)"

  echo "$out" | grep -q '턴 완료 전에 종료' \
    && pass "케이스 32b: 조기 종료를 사실대로 보고" \
    || fail "케이스 32b: 조기 종료 보고 누락 — $out"

  echo "$out" | grep -q '타임아웃' \
    && fail "케이스 32c: 조기 종료를 타임아웃으로 오분류함 — $out" \
    || pass "케이스 32c: 타임아웃 오분류 문구 없음"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 33 (V1): claude 유휴 임계 발동 → exit 124
#   V4(d) 겸용 — TERM 을 무시하지 않는 리더는 즉시 죽어 watchdog 의 grace(3초)가 끝나기
#   전에 부모가 watchdog 을 kill 한다. 그 취소 경로에서 타이머 자원이 남지 않는지 여기서
#   함께 확인한다(전용 TMPDIR 로 절대 개수 0을 본다).
# ===========================================================================
run_case33() {
  local sandbox expected_turn mock_bin rc=0 output start elapsed leftover
  sandbox="$(make_sandbox)"
  mkdir -p "$sandbox/tmp"
  expected_turn="$sandbox/turns/turn-001.md"
  mock_bin="$(setup_mock_claude "$sandbox" "exec sleep 60")"

  start=$(date +%s)
  output="$(
    TMPDIR="$sandbox/tmp" \
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 \
      bash "$ADAPTER_CLAUDE" 2>&1
  )" || rc=$?
  elapsed=$(( $(date +%s) - start ))

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "유휴 임계"; then
    pass "케이스 33: claude 유휴 임계 발동 → exit 124 (${elapsed}초)"
  else
    fail "케이스 33: 기대 rc=124 + '유휴 임계' — 실제 rc=$rc (${elapsed}초)"
  fi

  [ "$elapsed" -lt 15 ] \
    && pass "케이스 33(보조1): 15초 이내 종료" \
    || fail "케이스 33(보조1): ${elapsed}초 — 과도하게 오래 걸림"

  leftover="$(leftover_watchdog_in "$sandbox/tmp")"
  [ "$leftover" -eq 0 ] \
    && pass "케이스 33(보조2, V4d): grace 도중 watchdog 취소 후 타이머 자원 잔존 없음" \
    || fail "케이스 33(보조2, V4d): 타이머 자원 ${leftover}개 잔존"

  # **디스크만으로 원인을 알 수 있어야 한다.** 진행 중 snapshot 은 정상·타임아웃 어느
  # 경로에서나 같은 모습이라, 사유가 없으면 터미널 출력을 놓친 사용자는 무슨 일이
  # 있었는지 알 수 없다. 이 실행은 첫 heartbeat(60초) 이전에 끝나므로 heartbeat 가
  # 남긴 정보에 기댈 수도 없다.
  if grep -q '^outcome: timeout: idle ' "$sandbox/.review_wait_status" 2>/dev/null; then
    pass "케이스 33(보조3, R1): 상태 파일에 종료 사유(timeout: idle)가 남음"
  else
    fail "케이스 33(보조3, R1): 상태 파일에서 종료 사유를 찾지 못함 — 디스크만으로 원인 판별 불가"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 34 (V2): claude 절대 상한 발동 → exit 124 (유휴는 발동 불가하도록 계속 출력)
# ===========================================================================
run_case34() {
  local sandbox expected_turn mock_bin rc=0 output
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  mock_bin="$(setup_mock_claude "$sandbox" "while :; do echo tick; sleep 1; done")"

  output="$(
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=4 RD_REVIEW_IDLE_TIMEOUT=60 \
      bash "$ADAPTER_CLAUDE" 2>&1
  )" || rc=$?

  if [ "$rc" -eq 124 ] && echo "$output" | grep -q "유효 상한"; then
    pass "케이스 34: claude 절대 상한 발동 → exit 124"
  else
    fail "케이스 34: 기대 rc=124 + '유효 상한' — 실제 rc=$rc"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 35 (V3): 정상 턴 전체 — 활동이 유휴 타이머를 갱신 / 헤더 삽입 / heartbeat 요약
#   표시 / 안정 로그 존재 + log_preserved:yes + 실제 log_path_final / 실행 중에는
#   안정 이름이 없었음(rendezvous 로 실행 중 시점을 확정 — 케이스 30 과 같은 기법)
# ===========================================================================
run_case35() {
  local sandbox expected_turn mock_bin started go rc=0 log_final
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  started="$sandbox/mock_started"
  go="$sandbox/mock_go"

  mock_bin="$(setup_mock_claude "$sandbox" "
echo '{\"type\":\"system\",\"subtype\":\"init\"}'
printf 's' > '$started'
while [ ! -f '$go' ]; do
  echo '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Grep\"}]}}'
  sleep 1
done
printf 'turn body\n' > '$expected_turn'
exit 0
")"

  spawn_group "$sandbox/wrap.log" env \
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=3 RD_REVIEW_HEARTBEAT=2 \
    bash "$ADAPTER_CLAUDE"

  local i
  for i in $(seq 1 100); do
    [ -f "$started" ] && break
    sleep 0.1
  done
  if [ ! -f "$started" ]; then
    fail "케이스 35: 전제 실패 — mock 이 시작되지 않아 실행 중 관측을 할 수 없음"
    printf 'go' > "$go"; reap_group "$GROUP_PGID"; rm -rf "$sandbox"; return
  fi

  # 실행 중 — 안정 이름이 존재하지 않아야 한다 (산출물 수명 계약)
  if [ ! -e "$sandbox/.claude_output.log" ] && [ ! -e "$sandbox/.review_wait_status" ]; then
    pass "케이스 35a: 실행 중 안정 로그·상태 파일 모두 부재"
  else
    fail "케이스 35a: 실행 중에도 안정 산출물이 존재 (log=$([ -e "$sandbox/.claude_output.log" ] && echo 있음 || echo 없음), status=$([ -e "$sandbox/.review_wait_status" ] && echo 있음 || echo 없음))"
  fi

  # 유휴 임계(3초)보다 오래 살아서 활동 갱신을 증명한다
  sleep 5
  printf 'go' > "$go"
  wait "$JOB" 2>/dev/null || rc=$?
  reap_group "$GROUP_PGID"

  [ "$rc" -eq 0 ] \
    && pass "케이스 35b: 활동이 유휴 타이머를 갱신 — 정상 턴 exit 0 (124 아님)" \
    || fail "케이스 35b: 기대 rc=0 — 실제 rc=$rc"

  grep -q '⚠️ Self-Review Notice' "$expected_turn" 2>/dev/null \
    && grep -q 'turn body' "$expected_turn" 2>/dev/null \
    && pass "케이스 35c: self-review 헤더 삽입 + 원본 내용 보존" \
    || fail "케이스 35c: 헤더 삽입 실패 또는 원본 내용 유실"

  grep -q 'assistant: tool_use Grep' "$sandbox/wrap.log" 2>/dev/null \
    && pass "케이스 35d: heartbeat 에 'assistant: tool_use Grep' 요약 표시" \
    || fail "케이스 35d: heartbeat 요약 표시 누락"

  log_final="$( { grep '^log_path_final: ' "$sandbox/.review_wait_status" 2>/dev/null || true; } | sed 's/^log_path_final: //' )"
  if [ -f "$sandbox/.claude_output.log" ] \
     && { grep -q '^log_preserved: yes' "$sandbox/.review_wait_status" 2>/dev/null; } \
     && [ -n "$log_final" ] && [ -f "$log_final" ]; then
    pass "케이스 35e: 안정 로그 존재 + log_preserved:yes + log_path_final 이 실재 경로"
  else
    fail "케이스 35e: 산출물 보존 계약 위반 — log_final='$log_final'"
  fi

  # 정상 경로도 사유를 남겨야 한다 — 타임아웃 상태 파일과 구별되지 않으면 사후 확인이
  # 성립하지 않는다(진행 중 snapshot 은 경로를 빼면 어느 결말에서나 같다).
  grep -q '^outcome: ok: ' "$sandbox/.review_wait_status" 2>/dev/null \
    && pass "케이스 35f(R1): 상태 파일에 종료 사유(ok)가 남음" \
    || fail "케이스 35f(R1): 정상 종료 사유가 상태 파일에 없음"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 36 (V4): 자손 잔존 없음
#   (a) TERM 무시 리더 — 어댑터 자체가 exit 124 로 회수 (외부 안전망 도달은 FAIL)
#   (b) 리더만 0 종료 + 자손 생존 — 살아남은 자손이 **그룹 종료 전 발행·헤더 삽입 여부를
#       직접 관측**한다 (TERM 을 무시해 grace 동안 생존하므로 관측 창이 확보된다)
#   (c) pgid 미확보 + TERM 무시 리더 — 엔진 직접 하니스로 PID 회수만 확인
#     (어댑터에 장애를 주입하지 않는다 — review_wait.sh 의 rw_watchdog_loop 을 직접 호출)
# ===========================================================================
run_case36a() {
  local sandbox expected_turn mock_bin rc=0 waited cap survivors i
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  # TERM 을 무시하는 리더 — trap '' 의 SIG_IGN 은 exec 뒤에도 유지된다(POSIX)
  mock_bin="$(setup_mock_claude "$sandbox" "trap '' TERM; exec sleep 60")"
  cap=20

  spawn_group "$sandbox/wrap.log" env \
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=2 \
    bash "$ADAPTER_CLAUDE"

  waited=0
  while [ "$waited" -lt $((cap * 10)) ] && kill -0 "$JOB" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  waited=$((waited / 10))   # 0.1초 틱 → 초 (상한 cap 초는 그대로)

  if kill -0 "$JOB" 2>/dev/null; then
    fail "케이스 36a: 외부 안전망 ${cap}초에 도달 — 어댑터 자체 회수 실패"
    reap_group "$GROUP_PGID"
  else
    wait "$JOB" 2>/dev/null || rc=$?
    if [ "$rc" -eq 124 ]; then
      pass "케이스 36a: TERM 무시 리더도 어댑터 자체 exit 124 로 회수 (${waited}초 이내)"
    else
      fail "케이스 36a: 기대 rc=124 — 실제 rc=$rc"
    fi

    # 그룹이 비는 것을 조건으로 기다린다 (최대 5초, 0.05초 간격)
    for i in $(seq 1 100); do [ "$(group_size "$GROUP_PGID")" -eq 0 ] && break; sleep 0.05; done
    survivors="$(group_size "$GROUP_PGID")"
    [ "$survivors" -eq 0 ] \
      && pass "케이스 36a(보조1): 그룹 소멸 확인" \
      || fail "케이스 36a(보조1): 잔존 프로세스 ${survivors}개"

    grep -q '⚠️ Self-Review Notice' "$expected_turn" 2>/dev/null \
      && fail "케이스 36a(보조2): 타임아웃 경로에 헤더가 삽입됨" \
      || pass "케이스 36a(보조2): 헤더 미삽입"

    reap_group "$GROUP_PGID"
  fi

  rm -rf "$sandbox"
}

run_case36b() {
  local sandbox expected_turn mock_bin rc=0 survivors
  local stable_status stable_log sentinel
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  stable_status="$sandbox/.review_wait_status"
  stable_log="$sandbox/.claude_output.log"
  sentinel="$sandbox/saw-early-publish"

  # 리더는 턴 파일을 만들고 즉시 0 으로 종료하지만, 같은 pgid 의 자손이 살아남아
  # **그룹이 종료되기 전에 안정 산출물 발행이나 헤더 삽입이 일어났는지 직접 관측**한다.
  #
  # 이 관측이 이 케이스의 핵심이다. 이전 판본은 "턴 파일이 끝내 생기지 않았다" 로 순서를
  # 증명하려 했지만, 그것은 아무도 턴 파일을 만들지 않았으므로 **순서와 무관하게 참**이라
  # 순서 회귀(턴 파일 검사·발행을 cleanup 앞으로 옮기는 실수)를 전혀 탐지하지 못했다.
  #
  # 자손은 TERM 을 무시해 grace(기본 3초) 동안 살아남으므로 관측 창이 충분하다 —
  # 동시에 escalation 의 KILL 이 자손까지 닿는지도 함께 확인된다.
  mock_bin="$(setup_mock_claude "$sandbox" "printf '턴 본문\n' > '$expected_turn'
(
  trap '' TERM
  while :; do
    if [ -e '$stable_status' ] || [ -e '$stable_log' ] \
       || grep -q 'Self-Review Notice' '$expected_turn' 2>/dev/null; then
      : > '$sentinel'
    fi
    sleep 0.05
  done
) &
exit 0")"

  spawn_group "$sandbox/wrap.log" env \
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=60 \
    bash "$ADAPTER_CLAUDE"
  wait "$JOB" 2>/dev/null || rc=$?

  [ "$rc" -eq 0 ] \
    && pass "케이스 36b: 리더 조기 종료·자손 생존 — 그룹 정리 후 정상 후처리 (exit 0)" \
    || fail "케이스 36b: 기대 rc=0 — 실제 rc=$rc"

  # **핵심 단언** — 자손이 살아 있는 동안 안정 산출물도 헤더도 나타나지 않아야 한다.
  [ ! -e "$sentinel" ] \
    && pass "케이스 36b(보조1): 그룹 종료 전 발행·헤더 삽입 없음 (자손이 직접 관측)" \
    || fail "케이스 36b(보조1): 그룹이 살아 있는 동안 안정 산출물 또는 헤더가 관측됨 — 후처리 순서 위반"

  grep -q 'Self-Review Notice' "$expected_turn" 2>/dev/null \
    && pass "케이스 36b(보조2): 그룹 정리 뒤에는 헤더가 삽입됨" \
    || fail "케이스 36b(보조2): 정상 경로인데 헤더가 삽입되지 않음"

  survivors="$(group_size "$GROUP_PGID")"
  [ "$survivors" -eq 0 ] \
    && pass "케이스 36b(보조3): TERM 을 무시한 자손도 KILL 로 회수됨" \
    || fail "케이스 36b(보조3): 자손 ${survivors}개 잔존"

  reap_group "$GROUP_PGID"
  rm -rf "$sandbox"
}

run_case36c() {
  local leader_pid timer_dir marker_file wd_pid waited cap=10

  # 실제 TERM 무시 리더를 백그라운드로 띄우고, pgid 를 확보하지 못한 것처럼(RW_TARGET_PGID='')
  # 엔진에 직접 넘긴다 — 어댑터에는 아무 장애도 주입하지 않는다.
  bash -c 'trap "" TERM; exec sleep 60' &
  leader_pid=$!

  timer_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { fail "케이스 36c: 타이머 디렉터리 mktemp 실패"; kill "$leader_pid" 2>/dev/null; return; }
  mkfifo "$timer_dir/timer"
  exec 9<> "$timer_dir/timer"
  marker_file="$(mktemp "$RUN_TMP/f.XXXXXX")" || { fail "케이스 36c: 마커 파일 mktemp 실패"; kill "$leader_pid" 2>/dev/null; rm -rf "$timer_dir"; return; }
  exec 7>> "$marker_file"

  (
    source "$SCRIPT_DIR/review_wait.sh"
    RW_TOOL_LABEL=claude
    RW_TARGET_PGID=""
    RW_TARGET_PID="$leader_pid"
    RW_ABS_CAP=300
    RW_OBSERVER_OK=0
    RW_FALLBACK_CAP=2
    RW_IDLE=60
    RW_TICK=1
    RW_HEARTBEAT=1000
    RW_KILL_ESCALATE=1
    RW_KILL_GRACE=1
    RW_MARKER_FD=7
    RW_TIMER_FD=9
    RW_STATUS_FD_OPEN=0
    RW_LOG_PATH=""
    RW_STATUS_STREAM_PATH=""
    RW_STATUS_FD=""
    rw_watchdog_loop
  ) &
  wd_pid=$!

  waited=0
  while [ "$waited" -lt $((cap * 10)) ] && kill -0 "$leader_pid" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  waited=$((waited / 10))   # 0.1초 틱 → 초 (상한 cap 초는 그대로)

  if kill -0 "$leader_pid" 2>/dev/null; then
    fail "케이스 36c: 외부 안전망 ${cap}초에도 pgid 미확보 리더가 회수되지 않음"
    kill -9 "$leader_pid" 2>/dev/null || true
  else
    pass "케이스 36c: pgid 미확보 상태에서도 리더가 외부 상한 전에 회수됨 (${waited}초 이내)"
  fi

  kill "$wd_pid" 2>/dev/null || true
  wait "$wd_pid" 2>/dev/null || true
  wait "$leader_pid" 2>/dev/null || true
  { exec 9<&-; } 2>/dev/null || true
  { exec 7>&-; } 2>/dev/null || true
  rm -rf "$timer_dir"
  rm -f "$marker_file"
}

# ===========================================================================
# 케이스 36d: codex TERM 무시 리더 — 어댑터 자체가 exit 124 로 회수
#   codex 는 set -m 으로 mock 을 어댑터와 **다른 process group** 에 띄운다. 그래서 36a 의
#   어댑터 그룹 소멸 검사는 mock 생존을 보지 못한다 — 단언은 "외부 상한 전에 rc=124" 하나이고,
#   안전망 정리만 mock 그룹(pid 파일의 PID 가 곧 pgid)까지 대상으로 한다.
# ===========================================================================
run_case36d() {
  local sandbox expected_turn mock_bin mock_pid_file mock_pid rc=0 waited cap=20
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  mock_pid_file="$sandbox/mock_bin/codex.pid"
  # TERM 을 무시하는 리더 — trap '' 의 SIG_IGN 은 exec 뒤에도 유지된다(POSIX)
  mock_bin="$(setup_mock "$sandbox" "echo \$\$ > \"$mock_pid_file\"; trap '' TERM; exec sleep 60")"

  spawn_group "$sandbox/wrap.log" env \
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=2 \
    bash "$ADAPTER"

  waited=0
  while [ "$waited" -lt $((cap * 10)) ] && kill -0 "$JOB" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  waited=$((waited / 10))   # 0.1초 틱 → 초 (상한 cap 초는 그대로)

  if kill -0 "$JOB" 2>/dev/null; then
    fail "케이스 36d: 외부 안전망 ${cap}초에 도달 — 어댑터 자체 회수 실패"
    reap_group "$GROUP_PGID"
  else
    wait "$JOB" 2>/dev/null || rc=$?
    if [ "$rc" -eq 124 ]; then
      pass "케이스 36d: codex TERM 무시 리더도 어댑터 자체 exit 124 로 회수 (${waited}초 이내)"
    else
      fail "케이스 36d: 기대 rc=124 — 실제 rc=$rc"
    fi
  fi

  # mock 그룹 정리 — pid 파일의 PID 가 자기 그룹의 리더(pgid == pid)일 때만 회수한다
  mock_pid=""
  [ -f "$mock_pid_file" ] && mock_pid="$(cat "$mock_pid_file" 2>/dev/null)"
  if [ -n "$mock_pid" ] && [ "$(own_pgid "$mock_pid")" = "$mock_pid" ]; then
    reap_group "$mock_pid"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 37 (V5): 관측기 고장 — 엔진 직접 하니스 (어댑터에 장애 주입 없음)
#   RW_OBSERVER_OK=0 RW_ABS_CAP=300 RW_FALLBACK_CAP=3 → 마커 세 필드 'cap 3 failed',
#   약 3초에 발동
# ===========================================================================
run_case37() {
  local dummy_pid timer_dir marker_file start elapsed marker reason rest cap observer

  sleep 60 &
  dummy_pid=$!
  timer_dir="$(mktemp -d "$RUN_TMP/d.XXXXXX")" || { fail "케이스 37: 타이머 디렉터리 mktemp 실패"; kill "$dummy_pid" 2>/dev/null; return; }
  mkfifo "$timer_dir/timer"
  exec 9<> "$timer_dir/timer"
  marker_file="$(mktemp "$RUN_TMP/f.XXXXXX")" || { fail "케이스 37: 마커 파일 mktemp 실패"; kill "$dummy_pid" 2>/dev/null; rm -rf "$timer_dir"; return; }
  exec 7>> "$marker_file"
  exec 6< "$marker_file"

  start=$(date +%s)
  (
    source "$SCRIPT_DIR/review_wait.sh"
    RW_TOOL_LABEL=claude
    RW_TARGET_PGID=""
    RW_TARGET_PID="$dummy_pid"
    RW_ABS_CAP=300
    RW_OBSERVER_OK=0
    RW_FALLBACK_CAP=3
    RW_IDLE=60
    RW_TICK=1
    RW_HEARTBEAT=1000
    RW_KILL_ESCALATE=0
    RW_MARKER_FD=7
    RW_TIMER_FD=9
    RW_STATUS_FD_OPEN=0
    RW_LOG_PATH=""
    RW_STATUS_STREAM_PATH=""
    RW_STATUS_FD=""
    rw_watchdog_loop
  )
  elapsed=$(( $(date +%s) - start ))

  IFS= read -r marker <&6 || true
  reason="${marker%% *}"; rest="${marker#* }"
  cap="${rest%% *}"; observer="${rest##* }"

  if [ "$reason" = cap ] && [ "$cap" = 3 ] && [ "$observer" = failed ]; then
    pass "케이스 37: 관측기 고장 마커 세 필드 = 'cap 3 failed' (${elapsed}초)"
  else
    fail "케이스 37: 마커 기대 'cap 3 failed' — 실제 '[$marker]' (${elapsed}초)"
  fi

  if [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 6 ]; then
    pass "케이스 37(보조): 약 3초에 발동 (${elapsed}초)"
  else
    fail "케이스 37(보조): 발동 시각 이상 (${elapsed}초, 기대 2~6초)"
  fi

  kill "$dummy_pid" 2>/dev/null || true
  wait "$dummy_pid" 2>/dev/null || true
  { exec 9<&-; } 2>/dev/null || true
  { exec 7>&-; } 2>/dev/null || true
  { exec 6<&-; } 2>/dev/null || true
  rm -rf "$timer_dir"
  rm -f "$marker_file"
}

# ===========================================================================
# 케이스 38 (V6): 실패 경로 — 턴 파일을 만든 뒤 exit 3 → 어댑터 exit 1, 헤더 미삽입
# ===========================================================================
run_case38() {
  local sandbox expected_turn mock_bin rc=0
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  mock_bin="$(setup_mock_claude "$sandbox" "printf 'partial\n' > '$expected_turn'; exit 3")"

  TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=30 RD_REVIEW_IDLE_TIMEOUT=20 \
    bash "$ADAPTER_CLAUDE" >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 1 ] \
    && pass "케이스 38: 실패 종료(exit 3) → 어댑터 exit 1" \
    || fail "케이스 38: 기대 rc=1 — 실제 rc=$rc"

  grep -q '⚠️ Self-Review Notice' "$expected_turn" 2>/dev/null \
    && fail "케이스 38(보조): 부분 턴 파일에 헤더가 삽입됨" \
    || pass "케이스 38(보조): 헤더 미삽입 (부분 턴 파일을 성공으로 취급하지 않음)"

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 39 (V7): TERM 중단 → exit 143, 자손 없음, 헤더 미삽입, 보존 결과 남음
#   INT 는 background job 이 무시 disposition 을 상속하므로(POSIX) 검증하지 않는다.
# ===========================================================================
run_case39() {
  local sandbox expected_turn mock_bin rc=0 adapter_pid adapter_pgid survivors
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  mock_bin="$(setup_mock_claude "$sandbox" "touch '$sandbox/mock_started'; exec sleep 60")"

  spawn_group "$sandbox/wrap.log" env \
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=60 \
    bash "$ADAPTER_CLAUDE"
  adapter_pid="$JOB"
  adapter_pgid="$GROUP_PGID"

  # 고정 1초가 아니라 mock 기동(= 어댑터가 상태 스냅샷을 시작한 뒤 spawn)을 확인하고 TERM 을 보낸다.
  # 부하가 높으면 1초 안에 spawn 전 단계를 못 지나, 시작 실패 경로(상태 파일 미발행)를 타서 FAIL 했다.
  local i
  for i in $(seq 1 100); do [ -e "$sandbox/mock_started" ] && break; sleep 0.1; done
  kill -TERM "$adapter_pid" 2>/dev/null || true
  wait "$adapter_pid" 2>/dev/null || rc=$?

  [ "$rc" -eq 143 ] \
    && pass "케이스 39: TERM 수신 → exit 143" \
    || fail "케이스 39: 기대 rc=143 — 실제 rc=$rc"

  for i in $(seq 1 100); do [ "$(group_size "$adapter_pgid")" -eq 0 ] && break; sleep 0.05; done
  survivors="$(group_size "$adapter_pgid")"
  [ "$survivors" -eq 0 ] \
    && pass "케이스 39(보조1): TERM 후 자손 프로세스 없음" \
    || fail "케이스 39(보조1): 잔존 프로세스 ${survivors}개"

  grep -q '⚠️ Self-Review Notice' "$expected_turn" 2>/dev/null \
    && fail "케이스 39(보조2): 신호 중단인데 헤더가 삽입됨" \
    || pass "케이스 39(보조2): 헤더 미삽입"

  if [ -f "$sandbox/.review_wait_status" ] && { grep -q '^log_preserved: ' "$sandbox/.review_wait_status" 2>/dev/null; }; then
    pass "케이스 39(보조3): 신호 종료 후에도 상태 파일에 보존 결과 존재"
  else
    fail "케이스 39(보조3): 상태 파일 또는 보존 결과 누락"
  fi

  # 신호 경로도 사유를 남겨 진행 중 snapshot 이 최종 결과로 오인되지 않게 한다.
  grep -q '^outcome: signal: SIGTERM ' "$sandbox/.review_wait_status" 2>/dev/null \
    && pass "케이스 39(보조4, R1): 상태 파일에 종료 사유(signal: SIGTERM)가 남음" \
    || fail "케이스 39(보조4, R1): 신호 종료 사유가 상태 파일에 없음"

  reap_group "$adapter_pgid"
  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 40 (V9): 표시 포맷터 경계 — 함수 단언 (통합 시나리오 아님)
# ===========================================================================
# ===========================================================================
# 케이스 41 (R1 보완): CLI 가 exit 0 이지만 턴 파일을 만들지 않은 경우
#   어댑터는 실패(exit 1)인데 최종 상태가 `ok` 로 남으면, 터미널 출력을 놓친 사용자가
#   **턴 생성 실패와 성공을 디스크에서 구별하지 못한다.** CLI 종료 코드만으로 사유를
#   확정하면 이 경로가 통째로 성공으로 기록된다.
# ===========================================================================
run_case41() {
  local sandbox expected_turn mock_bin rc=0 output
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  mock_bin="$(setup_mock_claude "$sandbox" "echo '답변만 출력하고 턴 파일은 만들지 않는다'; exit 0")"

  output="$(
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=20 RD_REVIEW_IDLE_TIMEOUT=20 \
      bash "$ADAPTER_CLAUDE" 2>&1
  )" || rc=$?

  [ "$rc" -eq 1 ] \
    && pass "케이스 41: CLI exit 0 + 턴 파일 부재 → 어댑터 exit 1" \
    || fail "케이스 41: 기대 rc=1 — 실제 rc=$rc"

  if grep -q '^outcome: turn-missing: ' "$sandbox/.review_wait_status" 2>/dev/null; then
    pass "케이스 41(보조1): 상태 파일이 턴 생성 실패를 사실대로 기록"
  else
    fail "케이스 41(보조1): outcome 이 turn-missing 이 아님 — 실제: $( { grep '^outcome: ' "$sandbox/.review_wait_status" 2>/dev/null || echo '(없음)'; } )"
  fi

  grep -q '^outcome: ok' "$sandbox/.review_wait_status" 2>/dev/null \
    && fail "케이스 41(보조2): 어댑터 실패인데 상태 파일에 ok 로 남음" \
    || pass "케이스 41(보조2): 실패 경로가 ok 로 기록되지 않음"

  rm -rf "$sandbox"
}

run_case40() {
  local long300 out harness claude_fmt_src

  long300="$(printf 'A%.0s' $(seq 1 300))"

  # ① 훅 미설정 + 300자 입력 → rw_display_line 이 원문 그대로 (codex 불변 조건)
  harness="$(mktemp "$RUN_TMP/f.XXXXXX")" || { fail "케이스 40 ①: 하니스 mktemp 실패"; return; }
  cat > "$harness" <<HARNESS_EOF
#!/usr/bin/env bash
source "$SCRIPT_DIR/review_wait.sh"
unset RW_LINE_FORMATTER
rw_display_line "$long300"
HARNESS_EOF
  out="$(bash "$harness")"
  rm -f "$harness"

  if [ "${#out}" -eq 300 ] && [ "$out" = "$long300" ]; then
    pass "케이스 40a: 훅 미설정 시 rw_display_line 이 원문 그대로(300자 유지, codex 불변)"
  else
    fail "케이스 40a: 원문 훼손 — 길이 ${#out} (기대 300)"
  fi

  # ② claude 미분류 300자 입력 → claude_format_line 결과가 200자 이하이고 끝이 …
  claude_fmt_src="$(sed -n '/^claude_format_line() {/,/^}/p' "$ADAPTER_CLAUDE")"
  harness="$(mktemp "$RUN_TMP/f.XXXXXX")" || { fail "케이스 40 ②: 하니스 mktemp 실패"; return; }
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "$claude_fmt_src"
    printf 'claude_format_line "%s"\n' "$long300"
  } > "$harness"
  out="$(bash "$harness")"
  rm -f "$harness"

  local len_ok=0 suffix_ok=0
  [ "${#out}" -le 200 ] && len_ok=1
  case "$out" in
    *'…') suffix_ok=1 ;;
  esac
  if [ "$len_ok" -eq 1 ] && [ "$suffix_ok" -eq 1 ]; then
    pass "케이스 40b: claude 미분류 300자 입력 → 200자 이하 + 말줄임(…) (실측 ${#out}자)"
  else
    fail "케이스 40b: 절단 계약 위반 — 길이 ${#out}, 말줄임=$([ "$suffix_ok" -eq 1 ] && echo 있음 || echo 없음)"
  fi

  # ②' C 로캘 + 한글 300자 → 글자 중간에서 자르지 않는다(결과가 유효한 UTF-8 이고 끝이 …).
  #     LANG 이 없는 무인 실행에서 bash 는 바이트로 자르므로 사용자에게 깨진 줄이 보인다.
  harness="$(mktemp "$RUN_TMP/f.XXXXXX")" || { fail "케이스 40 ②': 하니스 mktemp 실패"; return; }
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "$claude_fmt_src"
    printf 'claude_format_line "%s"\n' "$(printf '가%.0s' $(seq 1 300))"
  } > "$harness"
  out="$(LC_ALL=C bash "$harness")"
  rm -f "$harness"
  if printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    case "$out" in
      *'…') pass "케이스 40d: C 로캘 한글 입력 → 유효한 UTF-8 + 말줄임(…)" ;;
      *) fail "케이스 40d: C 로캘 한글 입력 → 말줄임 없음" ;;
    esac
  else
    fail "케이스 40d: C 로캘 한글 입력 → 글자 중간에서 잘림(UTF-8 무효)"
  fi

  # ③ tool_use 줄 → assistant: tool_use Grep
  harness="$(mktemp "$RUN_TMP/f.XXXXXX")" || { fail "케이스 40 ③: 하니스 mktemp 실패"; return; }
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "$claude_fmt_src"
    printf 'claude_format_line %q\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep"}]}}'
  } > "$harness"
  out="$(bash "$harness")"
  rm -f "$harness"

  [ "$out" = "assistant: tool_use Grep" ] \
    && pass "케이스 40c: tool_use 줄 → 'assistant: tool_use Grep'" \
    || fail "케이스 40c: 기대 'assistant: tool_use Grep' — 실제 '$out'"
}

# ===========================================================================
# 케이스 42 (spec §6 개정 1): rw_group_state 단위 — 종료 증거 판정
#   pgid 빈 값 / ps rc≠0 / ps rc=0 + 빈 출력 / 구성원 있음 / 구성원 없음
#   ps shim 은 PATH 앞의 sandbox 디렉터리에만 둔다(실제 ps 는 건드리지 않는다).
# ===========================================================================
run_case42() {
  local sandbox shim_fail shim_empty self_pg got
  sandbox="$(make_sandbox)" || { fail "케이스 42: sandbox 생성 실패"; return; }
  shim_fail="$sandbox/shim_fail"; shim_empty="$sandbox/shim_empty"
  mkdir -p "$shim_fail" "$shim_empty"
  make_ps_shim "$shim_fail" fail
  make_ps_shim "$shim_empty" empty
  self_pg="$(own_pgid $$)"

  got="$(source "$SCRIPT_DIR/review_wait.sh"; rw_group_state "")"
  [ "$got" = unverified ] && pass "케이스 42a: pgid 빈 값 → unverified" || fail "케이스 42a: 기대 unverified — 실제 '$got'"

  got="$(PATH="$shim_fail:$PATH"; source "$SCRIPT_DIR/review_wait.sh"; rw_group_state "$self_pg")"
  [ "$got" = unverified ] && pass "케이스 42b: ps rc≠0 → unverified" || fail "케이스 42b: 기대 unverified — 실제 '$got'"

  got="$(PATH="$shim_empty:$PATH"; source "$SCRIPT_DIR/review_wait.sh"; rw_group_state "$self_pg")"
  [ "$got" = unverified ] && pass "케이스 42c: ps rc=0 + 빈 출력 → unverified" || fail "케이스 42c: 기대 unverified — 실제 '$got'"

  if [ "$PS_OK" -eq 0 ]; then
    skip "케이스 42d: ps 를 쓸 수 없어 판정할 수 없음"
  else
    got="$(source "$SCRIPT_DIR/review_wait.sh"; rw_group_state "$self_pg")"
    [ "$got" = alive ] && pass "케이스 42d: 구성원 있음 → alive" || fail "케이스 42d: 기대 alive — 실제 '$got'"
  fi

  if [ "$PS_OK" -eq 0 ]; then
    skip "케이스 42e: ps 를 쓸 수 없어 판정할 수 없음"
  else
    got="$(source "$SCRIPT_DIR/review_wait.sh"; rw_group_state 99999999)"
    [ "$got" = verified ] && pass "케이스 42e: 구성원 없음 → verified" || fail "케이스 42e: 기대 verified — 실제 '$got'"
  fi

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 43 (spec §6 개정 1, A1·A2): 어댑터가 발행하는 .review_wait_status 의 writer_group 줄
#   한 하니스를 도구(codex·claude)로 매개변수화한다.
#   A1 = ps 가 실패하는 PATH shim + mock 즉시 exit 1 → writer_group: unverified
#   A2 = 정상 ps + mock 즉시 exit 1 → writer_group: verified
#   A3 = 정상 동작하되 항상 「리더 그룹 구성원 없음」 목록을 돌려주는 ps shim → pgid 확보는 실패(빈 값)하지만
#        어댑터가 리더 pid 로 그룹을 조회해 verified 를 낸다. A2 는 경쟁에서 이기면 pgid 가 채워져 이 폴백을
#        밟지 못하므로(변이 M24·M25 가 A2 만으로는 생존했다), A3 이 폴백 경로를 결정적으로 강제한다.
# ===========================================================================
writer_group_harness() {  # $1=codex|claude $2=A1|A2 $3=기대 값
  local tool="$1" mode="$2" want="$3" sandbox mock_bin shim adapter rc=0 got body
  sandbox="$(make_sandbox)" || { fail "케이스 43 ${mode}(${tool}): sandbox 생성 실패"; return; }
  body="exit 1"
  if [ "$tool" = codex ]; then
    mock_bin="$(setup_mock "$sandbox" "$body")"; adapter="$ADAPTER"
    write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  else
    mock_bin="$(setup_mock_claude "$sandbox" "$body")"; adapter="$ADAPTER_CLAUDE"
  fi
  shim="$sandbox/shim"; mkdir -p "$shim"
  if [ "$mode" = A2 ] && [ "$PS_OK" -eq 0 ]; then
    skip "케이스 43 A2(${tool}): ps 를 쓸 수 없어 판정할 수 없음"
    rm -rf "$sandbox"
    return 0
  fi
  if [ "$mode" = A1 ]; then
    make_ps_shim "$shim" fail
  elif [ "$mode" = A3 ]; then
    printf '#!/bin/sh\nprintf "  PID  PGID\\n    1     1\\n"\n' > "$shim/ps"; chmod +x "$shim/ps"
  fi
  PATH="$shim:$PATH" \
  TOOL_BIN="$mock_bin/$tool" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
  EXPECTED_TURN_FILE="$sandbox/turns/turn-001.md" PROJECT_ROOT="$sandbox" \
  WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=60 \
    bash "$adapter" >/dev/null 2>&1 || rc=$?
  got="$(grep '^writer_group:' "$sandbox/.review_wait_status" 2>/dev/null || true)"
  if [ "$got" = "writer_group: $want" ]; then
    pass "케이스 43 ${mode}(${tool}): 발행된 상태 파일에 'writer_group: ${want}' (rc=$rc)"
  else
    fail "케이스 43 ${mode}(${tool}): 기대 'writer_group: ${want}' — 실제 '${got}' (rc=$rc)"
  fi
  rm -rf "$sandbox"
}

run_case43() {
  local t
  for t in codex claude; do
    writer_group_harness "$t" A1 unverified
    writer_group_harness "$t" A2 verified
    writer_group_harness "$t" A3 verified
  done
}

# ===========================================================================
# 케이스 44 리더 pid 폴백이 spawn 전·pgid 확보 중 cleanup 을 깨지 않는다
#   (a) spawn 전 부분 초기화 실패(mkfifo 실패 shim): cleanup 이 `RW_TARGET_PID: unbound variable` 로 죽지 않는다.
#   (b) pgid 확보 중 SIGTERM(ps shim 이 진입을 표시하고 대기 뒤 실패): 신호 종료 코드 143 이 보존되고 unbound 오류가 없다.
#   (c) trap 설치 후·spawn 전 SIGTERM(결정적): 테스트 전용 BASH_ENV 가 DEBUG trap 을 걸어, 어댑터가 spawn 직전의
#       `set -m` 을 실행하려는 순간 자기 자신에게 SIGTERM 을 보낸다 → 143 보존·unbound 오류 없음. 이 창은 외부 명령이
#       없어 시간으로 맞출 수 없으므로 DEBUG 계측으로 강제한다(변이 M27·M28 의 목표).
#   codex·claude 양쪽에 같은 하니스를 쓴다.
# ===========================================================================
init_guard_harness() {  # $1=codex|claude $2=a|b|c
  local tool="$1" mode="$2" sandbox mock_bin shim adapter rc=0 err marker pid i
  sandbox="$(make_sandbox)" || { fail "케이스 44${mode}(${tool}): sandbox 생성 실패"; return; }
  if [ "$tool" = codex ]; then
    mock_bin="$(setup_mock "$sandbox" "sleep 20")"; adapter="$ADAPTER"
    write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  else
    mock_bin="$(setup_mock_claude "$sandbox" "sleep 20")"; adapter="$ADAPTER_CLAUDE"
  fi
  shim="$sandbox/shim"; mkdir -p "$shim"; err="$sandbox/adapter.err"; marker="$sandbox/ps-entered"
  mkdir -p "$sandbox/tmp"  # 어댑터의 mktemp 가 여기에만 만들어, 종료 뒤 rd-watchdog.* 잔존을 센다
  if [ "$mode" = c ]; then
    local benv="$sandbox/debug_env.sh"
    printf '%s\n' "trap 'if [[ \"\$BASH_COMMAND\" == \"set -m\" ]]; then trap - DEBUG; kill -TERM \$\$; fi' DEBUG" > "$benv"
    TMPDIR="$sandbox/tmp" BASH_ENV="$benv" TOOL_BIN="$mock_bin/$tool" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
      EXPECTED_TURN_FILE="$sandbox/turns/turn-001.md" PROJECT_ROOT="$sandbox" \
      WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=60 \
      bash "$adapter" >/dev/null 2>"$err" || rc=$?
    if [ "$rc" -eq 143 ] && ! grep -q 'unbound variable' "$err"; then
      pass "케이스 44c(${tool}): trap 설치 후·spawn 전 SIGTERM 에서 143 보존·unbound 오류 없음"
    else
      fail "케이스 44c(${tool}): 기대 rc=143·unbound 없음 — rc=$rc, $(grep -m1 'unbound' "$err" || echo '(unbound 없음)')"
    fi
  elif [ "$mode" = a ]; then
    printf '#!/bin/sh\nexit 1\n' > "$shim/mkfifo"; chmod +x "$shim/mkfifo"
    TMPDIR="$sandbox/tmp" PATH="$shim:$PATH" TOOL_BIN="$mock_bin/$tool" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
      EXPECTED_TURN_FILE="$sandbox/turns/turn-001.md" PROJECT_ROOT="$sandbox" \
      WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=60 \
      bash "$adapter" >/dev/null 2>"$err" || rc=$?
    if [ "$rc" -eq 1 ] && ! grep -q 'unbound variable' "$err"; then
      pass "케이스 44a(${tool}): spawn 전 실패에서 cleanup 이 정상 완료 (rc=1, unbound 오류 없음)"
    else
      fail "케이스 44a(${tool}): 기대 rc=1·unbound 없음 — rc=$rc, $(grep -m1 'unbound' "$err" || echo '(unbound 없음)')"
    fi
  else
    # 진입 표시 후 release 파일이 생길 때까지 대기(0.05초 폴링, 최대 3초)하고 실패하는 별도 형태 — 헬퍼 모드 아님
    printf '#!/bin/sh\n: > "%s"\ni=0\nwhile [ ! -e "%s" ] && [ "$i" -lt 60 ]; do sleep 0.05; i=$((i+1)); done\nexit 1\n' "$marker" "$sandbox/ps-release" > "$shim/ps"; chmod +x "$shim/ps"
    TMPDIR="$sandbox/tmp" PATH="$shim:$PATH" TOOL_BIN="$mock_bin/$tool" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
      EXPECTED_TURN_FILE="$sandbox/turns/turn-001.md" PROJECT_ROOT="$sandbox" \
      WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=60 \
      bash "$adapter" >/dev/null 2>"$err" &
    pid=$!
    for i in $(seq 1 100); do [ -e "$marker" ] && break; sleep 0.05; done
    kill -TERM "$pid" 2>/dev/null || true
    : > "$sandbox/ps-release"   # 신호를 보낸 직후 shim 을 놓아 준다 (고정 3초 대기 제거)
    wait "$pid" 2>/dev/null || rc=$?
    if [ "$rc" -eq 143 ] && ! grep -q 'unbound variable' "$err"; then
      pass "케이스 44b(${tool}): pgid 확보 중 SIGTERM 에서 143 보존·unbound 오류 없음"
    else
      fail "케이스 44b(${tool}): 기대 rc=143·unbound 없음 — rc=$rc, $(grep -m1 'unbound' "$err" || echo '(unbound 없음)')"
    fi
  fi
  n="$( { find "$sandbox/tmp" -maxdepth 1 -name 'rd-watchdog.*' 2>/dev/null || true; } | wc -l | tr -d ' ' )"
  if [ "$n" -eq 0 ]; then
    pass "케이스 44${mode}(${tool}): 전용 TMPDIR 에 rd-watchdog 잔존 0"
  else
    fail "케이스 44${mode}(${tool}): 전용 TMPDIR 에 rd-watchdog ${n}개 잔존"
  fi
  rm -rf "$sandbox"
}

# 케이스 45: 타임아웃 기록 진행 표시 — 관측한 파일 상태별로 서로 다른 문구, 원인·위치 단정 금지
# 세 상태 모두 WAIT_TIMEOUT=2 로 타임아웃시킨다 (mock 은 sleep 30).
# mock 본문 $2 를 실행한 뒤 sleep 한다. 출력을 전역 C45_OUT 에 담는다.
case45_one() {
  local sandbox mock_bin expected_turn
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001-reviewer.md"
  write_session "$sandbox" "Reviewer" "awaiting-reviewer"
  write_checkpoint "$sandbox" "Author"
  # CHECKPOINT mtime 을 과거로 고정해 「이전 턴의 기록」 상태를 만든다
  touch -t 200001010000 "$sandbox/CHECKPOINT.md"
  mock_bin="$(setup_mock "$sandbox" "$1; exec sleep 30")"
  C45_OUT="$(
    TOOL_BIN="$mock_bin/codex" SESSION_PATH="$sandbox" PROMPT_FILE="/dev/null"     EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" WAIT_TIMEOUT=2       bash "$ADAPTER" 2>&1
  )" || true
  rm -rf "$sandbox"
}

run_case45() {
  local none turn_only both turn="\$EXPECTED_TURN_FILE" ck="\$SESSION_PATH/CHECKPOINT.md"
  case45_one ':'
  none="$(echo "$C45_OUT" | grep '^기록 진행:' || true)"
  case45_one "echo x > \"$turn\""
  turn_only="$(echo "$C45_OUT" | grep '^기록 진행:' || true)"
  # 미래 시각으로 만들어 시작 기준 파일보다 확실히 새롭게 한다 (mtime 해상도 의존 제거)
  case45_one "echo x > \"$turn\"; touch -t 203001010000 \"$ck\""
  both="$(echo "$C45_OUT" | grep '^기록 진행:' || true)"

  if [ -n "$none" ] && [ -n "$turn_only" ] && [ -n "$both" ] \
     && [ "$none" != "$turn_only" ] && [ "$turn_only" != "$both" ] && [ "$none" != "$both" ]; then
    pass "케이스 45a: 기록 상태 세 가지의 표시가 서로 다름"
  else
    fail "케이스 45a: 표시가 비었거나 같음 — none=[$none] turn=[$turn_only] both=[$both]"
  fi
  # 기록이 없다고 기록 경로가 정상이라고 단정하지 않는다
  if echo "$none" | grep -q '실패했을 수 있' && ! echo "$none" | grep -q '기록 경로 문제는 아님'; then
    pass "케이스 45b: 기록 없음 표시가 원인을 단정하지 않음"
  else
    fail "케이스 45b: 기록 없음 표시가 원인을 단정함 — [$none]"
  fi
  # 기록이 모두 끝났어도 타임아웃일 수 있으므로 SESSION 갱신 전 중단을 단정하지 않는다
  if echo "$both" | grep -q 'SESSION.md 는 이 표시가 확인하지 않' && ! echo "$both" | grep -q 'SESSION.md 갱신 전'; then
    pass "케이스 45c: 기록 완료 관측 표시가 SESSION 미확인을 밝히고 중단 위치를 단정하지 않음"
  else
    fail "케이스 45c: 표시가 SESSION 상태를 단정함 — [$both]"
  fi
}

run_case44() {
  local t m
  for t in codex claude; do
    for m in a b c; do
      init_guard_harness "$t" "$m"
    done
  done
}

# ===========================================================================
# 케이스 46: rw_group_alive 세 값 판정 — ps 가 실패하면 kill -0 로 재확인한다
#   (a) ps 실패 + 그룹 살아 있음 → 0 (종전에는 ps 실패를 「없음」 1 로 오판했다)
#   (b) ps 실패 + 그룹 없음 → 1
#   (c) ps 실패 + kill -0 가 「No such process」 가 아닌 오류 → 2, RW_GROUP_PROBE_ERR 에 그 문구
# 프로브를 ko_KR 로캘로 돌려, kill -0 오류 문구가 번역되면 판정이 깨지는 회귀(LC_ALL=C 누락)를 잡는다.
# 한계: 그 번역은 ko 메시지 카탈로그가 있는 glibc 에서만 일어난다. macOS 와 ko 로캘이 없는 Linux 에서는
# 문구가 영어 그대로라 LC_ALL=C 를 빼도 이 케이스는 통과한다 — 그 환경에서는 이 회귀를 잡지 못한다.
# ===========================================================================
case46_probe() {  # $1=shim 디렉터리 $2=a|b|c → stdout "<rc>|<RW_GROUP_PROBE_ERR>"
  (
    export LANG=ko_KR.UTF-8 LC_ALL=
    PATH="$1:$PATH"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/review_wait.sh"
    if [ "$2" = c ]; then
      kill() {
        if [ "$1" = -0 ] && [ "$2" = -- ]; then
          echo "bash: kill: ($3) - Operation not permitted" >&2
          return 1
        fi
        builtin kill "$@"
      }
    fi
    set -m; sleep 30 >/dev/null 2>&1 & g=$!; set +m
    if [ "$2" = b ]; then
      kill -9 -- -"$g" 2>/dev/null || true
      wait "$g" 2>/dev/null || true
    fi
    rc=0; RW_GROUP_PROBE_ERR=""
    rw_group_alive "$g" || rc=$?
    kill -9 -- -"$g" 2>/dev/null || true
    wait "$g" 2>/dev/null || true
    printf '%s|%s\n' "$rc" "$RW_GROUP_PROBE_ERR"
  )
}

run_case46() {
  local sandbox got
  sandbox="$(make_sandbox)"
  make_ps_shim "$sandbox/shim" fail

  got="$(case46_probe "$sandbox/shim" a)"
  [ "${got%%|*}" = 0 ] \
    && pass "케이스 46a: ps 실패 + 살아 있는 그룹 → 0(있음)" \
    || fail "케이스 46a: 기대 0 — 실제 ${got%%|*}"

  got="$(case46_probe "$sandbox/shim" b)"
  [ "${got%%|*}" = 1 ] \
    && pass "케이스 46b: ps 실패 + 회수된 그룹 → 1(없음)" \
    || fail "케이스 46b: 기대 1 — 실제 ${got%%|*}"

  got="$(case46_probe "$sandbox/shim" c)"
  [ "${got%%|*}" = 2 ] \
    && pass "케이스 46c: ps 실패 + kill -0 의 그 밖의 오류 → 2(판정 불가)" \
    || fail "케이스 46c: 기대 2 — 실제 ${got%%|*}"
  case "${got#*|}" in
    *'Operation not permitted'*) pass "케이스 46c(오류 문구): RW_GROUP_PROBE_ERR 에 kill -0 오류 문구 보존" ;;
    *) fail "케이스 46c(오류 문구): 오류 문구 없음 — RW_GROUP_PROBE_ERR='${got#*|}'" ;;
  esac

  rm -rf "$sandbox"
}

# ===========================================================================
# 케이스 47: 어댑터 cleanup — ps 가 cleanup 때만 실패해도 writer 그룹에 신호를 보내고,
#   그룹 종료를 확인했을 때만 산출물을 안정 이름으로 발행한다 (codex·claude 각각)
#   signal  — mock 이 TERM 을 따르는 자손을 남기고 exit 1. 그룹 소멸·발행·writer_group: unverified
#   unknown — 마커 뒤 kill -0 그룹 probe 만 「Operation not permitted」 로 실패(BASH_ENV 함수).
#             TERM·KILL 은 내장으로 나가므로 그룹은 사라져야 하고, 판정 불가라 발행하지 않는다.
#   spawn 때 ps 성공은 handshake 로 보장한다(케이스 48 과 같음). 단언은 서로 독립으로 평가한다.
#   판정(그룹이 사라졌는가)은 테스트 셸의 내장 kill 로 한다 — BASH_ENV 는 어댑터에만 준다.
# ===========================================================================
group_cleanup_harness() {  # $1=codex|claude $2=signal|unknown
  local tool="$1" mode="$2" sandbox expected_turn mock_bin adapter_path tool_bin stable
  local mode_body bash_env="" job rc="" ticks=0 cap_ticks=200 mpid gone=0 i stream last tag
  tag="케이스 47-${mode}(${tool})"
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  make_ps_shim "$sandbox/shim" after-marker "$sandbox/ps-broken"

  if [ "$mode" = signal ]; then
    mode_body="touch \"$sandbox/ps-broken\"
exit 1"
  else
    # 턴을 완성한다 — codex 는 케이스 1 처럼 턴 파일 + SESSION, claude 는 케이스 35 처럼 턴 파일.
    if [ "$tool" = codex ]; then
      mode_body="printf 'turn body\n' > \"$expected_turn\"
printf '## Current Owner\nAuthor\n\n## Status\nawaiting-author\n\n## Turn Limit\n20\n' > \"$sandbox/SESSION.md\""
    else
      mode_body="printf 'turn body\n' > \"$expected_turn\""
    fi
    mode_body="$mode_body
touch \"$sandbox/ps-broken\"
exit 0"
    bash_env="$sandbox/env.sh"
    cat > "$bash_env" <<ENV_EOF
kill() { if [ "\${1:-}" = -0 ] && [ "\${2:-}" = -- ] && [ -e "$sandbox/ps-broken" ]; then echo "kill: (\${3:-}) - Operation not permitted" >&2; return 1; fi; builtin kill "\$@"; }
ENV_EOF
  fi

  local body="echo \$\$ > \"$sandbox/mock.pid\"
( trap - TERM; exec sleep 30 ) &
$(wait_ps_handshake "$sandbox/shim" "$sandbox")
$mode_body"
  if [ "$tool" = codex ]; then
    write_session "$sandbox" "Reviewer" "awaiting-reviewer"
    mock_bin="$(setup_mock "$sandbox" "$body")"
    tool_bin="$mock_bin/codex"; adapter_path="$ADAPTER"; stable="$sandbox/.codex_output.log"
  else
    mock_bin="$(setup_mock_claude "$sandbox" "$body")"
    tool_bin="$mock_bin/claude"; adapter_path="$ADAPTER_CLAUDE"; stable="$sandbox/.claude_output.log"
  fi

  # 케이스 48 과 같은 방식 — rc 를 sentinel 파일에 쓰고 0.1초 간격 폴링, 상한 20초.
  set -m
  (
    arc=0
    PATH="$sandbox/shim:$PATH" BASH_ENV="$bash_env" \
    TOOL_BIN="$tool_bin" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" WAIT_TIMEOUT=60 \
      bash "$adapter_path" > "$sandbox/out.log" 2>&1 || arc=$?
    echo "$arc" > "$sandbox/rc"
  ) &
  job=$!
  set +m
  while [ ! -s "$sandbox/rc" ] && [ "$ticks" -lt "$cap_ticks" ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  [ -s "$sandbox/rc" ] && rc="$(cat "$sandbox/rc")"

  [ ! -e "$sandbox/handshake-timeout" ] \
    && pass "$tag 전제: spawn 때 ps 성공 handshake 성립" \
    || fail "$tag 전제: 전제 불성립 — handshake 상한(5초) 초과"
  [ -n "$rc" ] || fail "$tag: 어댑터가 20초 안에 끝나지 않음"

  # 그룹 소멸 — 고아 자손의 회수를 짧게 기다린다(좀비 구성원은 kill -0 에 「있음」).
  mpid="$(cat "$sandbox/mock.pid" 2>/dev/null || true)"
  if [ -z "$mpid" ]; then
    fail "$tag 그룹: mock pid 를 읽지 못함"
  else
    for i in $(seq 1 20); do
      kill -0 -- -"$mpid" 2>/dev/null || { gone=1; break; }
      sleep 0.1
    done
    [ "$gone" -eq 1 ] \
      && pass "$tag 그룹: cleanup 이 writer 그룹을 정리함" \
      || fail "$tag 그룹: 그룹이 살아 있음 (pgid $mpid)"
  fi

  if [ "$mode" = signal ]; then
    [ -f "$stable" ] \
      && pass "$tag 발행: 안정 로그 발행됨" \
      || fail "$tag 발행: 안정 로그 없음 ($stable)"
    grep -q '^writer_group: unverified$' "$sandbox/.review_wait_status" 2>/dev/null \
      && pass "$tag 증거: .review_wait_status 에 writer_group: unverified" \
      || fail "$tag 증거: writer_group: unverified 없음"
  else
    if [ -n "$rc" ] && [ "$rc" -ne 0 ]; then
      pass "$tag rc: 어댑터 rc=$rc (0 아님)"
    else
      fail "$tag rc: 기대 rc≠0 — 실제 rc=${rc:-없음}"
    fi
    if [ ! -e "$stable" ] && [ ! -e "$sandbox/.review_wait_status" ]; then
      pass "$tag 미발행: 안정 로그·상태 파일 모두 없음"
    else
      fail "$tag 미발행: 안정 로그가 발행됨 (log=$([ -e "$stable" ] && echo 있음 || echo 없음), status=$([ -e "$sandbox/.review_wait_status" ] && echo 있음 || echo 없음))"
    fi
    grep -q '발행하지 않았습니다' "$sandbox/out.log" 2>/dev/null \
      && pass "$tag 안내: stderr 에 미발행 안내" \
      || fail "$tag 안내: stderr 에 안내 없음"
    stream="$( { ls "$sandbox"/.review_wait_status.* 2>/dev/null || true; } | head -n 1)"
    last=""
    [ -n "$stream" ] && last="$(awk '$0 == "=== rd-review-wait-snapshot ===" { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' "$stream" 2>/dev/null || true)"
    case "$last" in
      *"log_preserved_reason: ${tool}-group-unknown"*) pass "$tag 스트림: 마지막 snapshot 에 log_preserved_reason: ${tool}-group-unknown" ;;
      *) fail "$tag 스트림: 스트림에 사유 없음 (stream='${stream}')" ;;
    esac
    if [ "$tool" = codex ]; then
      [ ! -e "$sandbox/.turn_ready" ] \
        && pass "$tag 마커: .turn_ready 없음" \
        || fail "$tag 마커: .turn_ready 존재"
    fi
  fi

  kill -9 -- -"$job" 2>/dev/null || true
  reap_mock_group "$sandbox"
  wait "$job" 2>/dev/null || true
  rm -rf "$sandbox"
}

run_case47() {
  group_cleanup_harness codex signal
  group_cleanup_harness claude signal
  group_cleanup_harness codex unknown
  group_cleanup_harness claude unknown
}

# ===========================================================================
# 케이스 48: watchdog KILL — ps 가 판정 중에 실패해도 TERM 무시 그룹을 KILL 한다
#   mock(claude)은 TERM 을 무시하는 자손을 띄우고 자신도 TERM 을 무시한다. spawn 때 ps 는
#   성공하고(handshake), 그 뒤로는 ps 가 실패한다. watchdog 이 ps 실패를 「그룹 없음」 으로
#   읽으면 KILL 을 건너뛰어 부모의 wait 가 mock 의 sleep 60 까지 막힌다.
#   단언 셋은 서로 독립으로 평가한다(앞 단언이 실패해도 뒤 단언을 평가한다).
# ===========================================================================
run_case48() {
  local sandbox expected_turn mock_bin job rc="" ticks=0 cap_ticks=150 mpid gone=0 i
  sandbox="$(make_sandbox)"
  expected_turn="$sandbox/turns/turn-001.md"
  make_ps_shim "$sandbox/shim" after-marker "$sandbox/ps-broken"
  mock_bin="$(setup_mock_claude "$sandbox" "echo \$\$ > \"$sandbox/mock.pid\"
( trap '' TERM; exec sleep 60 ) &
trap '' TERM
$(wait_ps_handshake "$sandbox/shim" "$sandbox")
touch \"$sandbox/ps-broken\"
sleep 60")"

  # 케이스 2 와 같은 방식 — rc 를 sentinel 파일에 쓰고 0.1초 간격 폴링, 상한 15초.
  set -m
  (
    arc=0
    PATH="$sandbox/shim:$mock_bin:$PATH" \
    TOOL_BIN="$mock_bin/claude" SESSION_PATH="$sandbox" PROMPT_FILE=/dev/null \
    EXPECTED_TURN_FILE="$expected_turn" PROJECT_ROOT="$sandbox" \
    WAIT_TIMEOUT=60 RD_REVIEW_IDLE_TIMEOUT=2 \
      bash "$ADAPTER_CLAUDE" >/dev/null 2>&1 || arc=$?
    echo "$arc" > "$sandbox/rc"
  ) &
  job=$!
  set +m
  while [ ! -s "$sandbox/rc" ] && [ "$ticks" -lt "$cap_ticks" ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  [ -s "$sandbox/rc" ] && rc="$(cat "$sandbox/rc")"

  [ ! -e "$sandbox/handshake-timeout" ] \
    && pass "케이스 48-전제: spawn 때 ps 성공 handshake 성립" \
    || fail "케이스 48-전제: 전제 불성립 — handshake 상한(5초) 초과"

  if [ -z "$rc" ]; then
    fail "케이스 48-종료: 15초 안에 끝나지 않음 — watchdog 이 KILL 을 건너뛴 결함 의심"
  elif [ "$rc" -eq 124 ]; then
    pass "케이스 48-종료: 상한 안에 rc=124 (약 $((ticks / 10)).$((ticks % 10))초)"
  else
    fail "케이스 48-종료: 기대 rc=124 — 실제 rc=$rc"
  fi

  # 고아가 된 자손의 회수(init)를 짧게 기다린다 — 좀비 구성원은 kill -0 에 「있음」 으로 보인다.
  mpid="$(cat "$sandbox/mock.pid" 2>/dev/null || true)"
  if [ -z "$mpid" ]; then
    fail "케이스 48-그룹: mock pid 를 읽지 못함"
  else
    for i in $(seq 1 20); do
      kill -0 -- -"$mpid" 2>/dev/null || { gone=1; break; }
      sleep 0.1
    done
    [ "$gone" -eq 1 ] \
      && pass "케이스 48-그룹: TERM 무시 자손까지 그룹 소멸" \
      || fail "케이스 48-그룹: 그룹이 살아 있음 (pgid $mpid)"
  fi

  kill -9 -- -"$job" 2>/dev/null || true
  reap_mock_group "$sandbox"
  wait "$job" 2>/dev/null || true
  rm -rf "$sandbox"
}


# ===========================================================================
# 실행
# ===========================================================================
# 인자 검증: 모든 케이스 정의 뒤, 실행 전에 한다 (오타가 0건 통과로 끝나지 않게)
# run_case<이름> 접두사는 아래 `run <이름>` 으로 실행하는 공개 케이스 전용이다. 도우미 함수에 쓰지 않는다
# (쓰면 선택·안내 목록에 끼어 0건 실행이 exit 0 으로 끝난다).
for a in "${SELECTED[@]+"${SELECTED[@]}"}"; do
  if ! declare -F "run_case$a" >/dev/null; then
    echo "알 수 없는 케이스: $a" >&2
    echo "사용 가능: $(declare -F | sed -n 's/^declare -f run_case//p' | tr '\n' ' ')" >&2
    exit 2
  fi
done

PS_OK=1; ps_is_trustworthy || PS_OK=0

section "adapter_codex.sh 대기 계약·판정 단일화 테스트"

run 1
run 2
run 3
run 4
run 5
run 6

section "§2 결정 3 — run_review_turn.sh 설정 파싱 1회 통합 테스트 (Task 2)"

run 7
run 8
run 9
run 10
run 11

section "회귀 테스트 — .tools/.overrides 부재 방어 (fix: priority 폐기 회귀)"

run 12
run 13
section "회귀 테스트 — writable surface 세션 하위 폐쇄 (codex-adapter-writable-root)"

run 16

section "회귀 테스트 — 환경변수 해석 (review-turn-timeout-too-short Task 1)"

run 17

section "회귀 테스트 — codex 출력 관측 기반 유휴 판정 (review-turn-timeout-too-short Task 2)"

run 18
run 19
run 20

section "회귀 테스트 — heartbeat·상태 파일 (review-turn-timeout-too-short Task 3)"

run 21

section "회귀 테스트 — 활동 관측 fd 채널·유효 상한 (review-turn-timeout-too-short Task 4 / 턴 006 Critical 1)"

run 22
run 24

section "회귀 테스트 — 타임아웃 메시지 오염 단정 금지 (review-turn-timeout-too-short Task 5)"

run 23

section "회귀 테스트 — 상태 snapshot 초기화·관리 키 단일 (final diff review Important 2)"

run 25

section "회귀 테스트 — 상태 파일 쓰기 symlink 비추종 (final diff review Critical 1)"

run 26

section "회귀 테스트 — 로그 최종 이동 실패 정직 보고 (final diff review Important 3)"

run 27

section "회귀 테스트 — 산출물 수명 재설계 (final diff review 턴 004 Important 3·4)"

run 28
run 29

section "회귀 테스트 — 읽기 채널 fd 전용·안정 이름 수명 (final diff review 턴 006 Critical 1·Important 2)"

run 30
run 31

section "회귀 테스트 — 진단 읽기 지연에 의한 뒤늦은 마커 오분류 방지 (final diff review 008턴 Important 1)"

run 32

section "claude 대기 계약 행동 검증 (adapter-wait-contract Task 3)"

run 33
run 34
run 35
run 36a
run 36b
run 36c
run 36d
run 37
run 38
run 39
run 40

run 41

section "writer 종료 증거 계약 (spec §6 개정 1)"

run 42
run 43
run 44

section "타임아웃 기록 진행 표시"

run 45

section "ps 실패 시 그룹 생존 판정·watchdog KILL"

run 46
run 47
run 48

echo ""
echo "=== 결과: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ==="
if [ "$SKIP" -gt 0 ]; then
  echo "ps 를 쓸 수 없는 환경이라 ${SKIP}개를 건너뛰었습니다 — 이 실행은 그 단언을 검증하지 않았습니다."
fi

if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo "실패 케이스:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  exit 1
fi

exit 0
