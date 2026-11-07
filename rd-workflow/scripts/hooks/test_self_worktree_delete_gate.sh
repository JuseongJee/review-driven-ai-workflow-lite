#!/bin/bash
# test_self_worktree_delete_gate.sh — 세션 자기 worktree 삭제 차단 가드의 판정표 테스트.
# macOS /bin/bash 3.2 호환. fixture 는 mktemp -d 아래에만 만든다 (경로에 공백 포함).
# 케이스 설명 앞의 ID(B1 등)는 change spec 4절 단언 묶음과 짝이다.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="/bin/bash"; [[ -x "$BASH_BIN" ]] || BASH_BIN="$(command -v bash)"
PASS=0; FAIL=0; ISO_DIR=""; T=""

RD_GUARD_BLOCK_LOG="$(mktemp -t rd-guard-block-test.XXXXXX 2>/dev/null)" || RD_GUARD_BLOCK_LOG="/dev/null"
export RD_GUARD_BLOCK_LOG
cleanup() {
  [[ -n "$ISO_DIR" && -d "$ISO_DIR" ]] && rm -rf "$ISO_DIR"
  [[ -n "$T" && -d "$T" ]] && rm -rf "$T"
  [[ "$RD_GUARD_BLOCK_LOG" == "/dev/null" ]] || rm -f "$RD_GUARD_BLOCK_LOG"
}
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }

HAVE_JQ=0; HAVE_PY=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
command -v python3 >/dev/null 2>&1 && HAVE_PY=1
if [[ $HAVE_JQ -eq 0 && $HAVE_PY -eq 0 ]]; then echo "skip: jq·python3 없음"; exit 0; fi

# mkjson <cmd> <cwd|__NONE__>
mkjson() {
  if [[ $HAVE_JQ -eq 1 ]]; then
    if [[ "$2" == "__NONE__" ]]; then
      jq -cn --arg c "$1" '{tool_name:"Bash",session_id:"t",tool_input:{command:$c}}'
    else
      jq -cn --arg c "$1" --arg d "$2" '{tool_name:"Bash",session_id:"t",cwd:$d,tool_input:{command:$c}}'
    fi
  else
    python3 -c 'import json,sys
d={"tool_name":"Bash","session_id":"t","tool_input":{"command":sys.argv[1]}}
if sys.argv[2]!="__NONE__": d["cwd"]=sys.argv[2]
print(json.dumps(d))' "$1" "$2"
  fi
}

T="$(mktemp -d)" || { echo "mktemp 실패"; exit 1; }   # mktemp-scan: custom-handler
[[ -n "$T" && -d "$T" ]] || { echo "mktemp 경로 검증 실패"; exit 1; }   # mktemp-scan: custom-handler
B="$T/my repo"; M="$B/main"; R="$M/.worktrees/x"
mkfix() { # <루트> [common 포함 1|0]
  mkdir -p "$1/rd-workflow/scripts/hooks"
  cp "$HOOK_DIR/self_worktree_delete_gate.sh" "$HOOK_DIR/_delete_scan.awk" "$1/rd-workflow/scripts/hooks/"
  if [[ "${2:-1}" == 1 ]]; then
    cp "$HOOK_DIR/_guard_common.sh" "$1/rd-workflow/scripts/hooks/"
    cp "$HOOK_DIR/../_state_common.sh" "$1/rd-workflow/scripts/"
  fi
}
mkfix "$R"
mkfix "$M/.worktrees/x-old"
mkdir -p "$M/.worktrees/x-old" "$M/.worktrees/proto-y" "$R/node_modules"
ln -s "$M" "$B/alias"
S="$T/solo"; mkfix "$S"; git init -q "$S" 2>/dev/null
# 실제 git worktree fixture (B20·P11·M3). 기본 체크아웃 경로에 공백을 넣는다.
GM="$T/git main"; GW="$GM/.worktrees/w"
git init -q "$GM" 2>/dev/null && git -C "$GM" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init 2>/dev/null \
  && git -C "$GM" worktree add -q --detach "$GW" 2>/dev/null && git -C "$GM" worktree add -q --detach "$GM/.worktrees/w2" 2>/dev/null \
  && mkfix "$GW" || bad "환경: git worktree fixture 를 만들지 못했습니다"
# 끝 이름이 같은 worktree 가 둘(.worktrees/w = 세션, w = 다른 worktree)이면 git 은 축약 대신 정확한 경로를 지운다 (P12).
GM2="$T/git two"; GW2="$GM2/.worktrees/w"
git init -q "$GM2" 2>/dev/null && git -C "$GM2" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init 2>/dev/null \
  && git -C "$GM2" worktree add -q --detach "$GW2" 2>/dev/null && git -C "$GM2" worktree add -q --detach "$GM2/w" 2>/dev/null \
  && mkfix "$GW2" || bad "환경: 끝 이름이 겹치는 git worktree fixture 를 만들지 못했습니다"
GATE="rd-workflow/scripts/hooks/self_worktree_delete_gate.sh"

LAST_ERR=""
# run_case <기대rc> <설명> <cwd> <cmd> [루트=$R]
run_case() {
  local want="$1" desc="$2" cwd="$3" cmd="$4" root="${5:-$R}" json rc
  json="$(mkjson "$cmd" "$cwd")"
  if [[ "$cwd" == "__NONE__" ]]; then
    LAST_ERR="$(cd "$root" && printf '%s' "$json" | "$BASH_BIN" "$root/$GATE" 2>&1 >/dev/null)"; rc=$?
  else
    LAST_ERR="$(printf '%s' "$json" | "$BASH_BIN" "$root/$GATE" 2>&1 >/dev/null)"; rc=$?
  fi
  if [[ "$rc" -eq "$want" ]]; then ok; else bad "$desc — 기대 $want, 실제 $rc / cmd=[$cmd]${LAST_ERR:+ / $LAST_ERR}"; fi
}
block() { run_case 2 "$1" "$R" "$2"; }
pass()  { run_case 0 "$1" "$R" "$2"; }

: > "$RD_GUARD_BLOCK_LOG" 2>/dev/null || true
block "B1" "/usr/bin/trash \"$R\" && git -C \"$M\" worktree prune"
B1_ERR="$LAST_ERR"
if [[ "$RD_GUARD_BLOCK_LOG" != "/dev/null" ]]; then
  n="$(grep -c 'self_worktree_delete_gate.sh.*reason=self_worktree_delete_gate.self-delete' "$RD_GUARD_BLOCK_LOG")"
  [[ "$n" == 1 && "$(wc -l < "$RD_GUARD_BLOCK_LOG" | tr -d ' ')" == 1 ]] && ok || bad "A5: 차단 로그 줄 수 n=$n"
fi
case "$B1_ERR" in *"$R"*"지우려던 대상:"*"rd task list"*) ok ;; *) bad "M1: 문구 누락 [$B1_ERR]" ;; esac

block "B2a" "M=\"$M\"; cd \"\$M\" && /usr/bin/trash \"\$M/.worktrees/x\""
block "B2b" "W=\"$R\"; /usr/bin/trash \"\$W\""
block "B3" "cd \"$M\" && git worktree remove .worktrees/x 2>&1 | head -5"
block "B4" "cd \"$M\" && git worktree remove --force \"$R\""
block "B5a" "trash \"$M/.worktrees\""
block "B5b" "trash \"$M\""
block "B6a" "trash ."
block "B6b" "rm -rf \"\$PWD\""
block "B7a" "trash '$R'"
block "B7b" "W='$R'; trash \"\$W\""
block "B8a" "trash \"$R/\""
block "B8b" "trash \"$R/../x\""
block "B9" "trash \"$T/my repo/alias/.worktrees/x\""
block "B10" "cd \"$R/missing\"; trash ."
block "B16" "cd \"$R/missing\" && true; trash ."
block "B17a" $'r\\\nm -rf .'
block "B17b" $'rm\\\n -rf .'
block "B18" "cd -- \"$M\" && trash .worktrees/x"
# 이름 바로 뒤에 리다이렉션이 붙은 호출도 빠른 종료를 지나야 한다.
block "B19" "rm</dev/null -rf \"\$PWD\""
# git 은 worktree 경로의 끝 구성 요소(유일하면)로도 대상을 찾는다.
run_case 2 "B20" "$GW" "git -C \"$GM\" worktree remove --force w" "$GW"
run_case 0 "P11" "$GW" "git -C \"$GM\" worktree remove --force w2" "$GW"
run_case 0 "P12" "$GW2" "git -C \"$GM2\" worktree remove --force w" "$GW2"
# 파이프라인 안의 cd 는 밖으로 나가지 않는다. `&&` 로 이어 실패 경로 규칙과 분리해 격리만 본다.
block "B11" "cd \"$R/node_modules\" | cat && trash ."
block "B12" "W=\"$R\"; (W=\"$R-old\"); trash \"\$W\""
block "B13a" '"rm" -rf .'
block "B13b" 'r\m -rf .'
block "B14" "{ cd \"$M\"; trash .worktrees/x; }"
run_case 2 "B15" "__NONE__" "trash ."

pass "P1a" "trash \"$R/node_modules\""
pass "P1b" "rm -rf build"
pass "P2" "trash \"$R-old\""
# 루트 이름이 대상 이름으로 시작하는 쪽(루트 x-old, 대상 x)이 문자열 접두 비교의 실제 오탐 방향이다.
run_case 0 "P2b" "$M/.worktrees/x-old" "trash \"$R\"" "$M/.worktrees/x-old"
pass "P3a" "git worktree remove --force \"$M/.worktrees/proto-y\""
run_case 0 "P3b" "$M" "trash .worktrees/x-old"
pass "P4a" 'trash $UNKNOWN'
pass "P4b" 'rm -rf $(git rev-parse --show-toplevel)'
pass "P5" "git rm -r --cached ."
pass "P6a" "echo 'trash $R'"
pass "P6b" "printf '%s' \"rm -rf $R\""
# 인용 없이 단어로 나뉜 문구도 명령 위치가 아니면 삭제가 아니다.
pass "P6c" "echo trash \"$R\""
pass "P6d" "printf '%s\\n' rm -rf \"$R\""
# 본문 경로를 인용해 둔다 — 인용이 없으면 공백 경로가 두 단어로 나뉘어 heredoc 건너뛰기를 지워도 막히지 않는다.
pass "P7" $'cat > f.txt <<\'EOF\'\ntrash "'"$R"$'"\nEOF'
pass "P8" "cd \"$R/node_modules\" && trash ."
pass "P10" "cd \"$R/node_modules\" && true && trash ."
pass "P9" "W=\"$R-old\"; (W=\"$R\"); trash \"\$W\""
# 빠른 종료 통과 케이스 (tool_input 앞쪽 필드의 worktree 문구는 무시)
pass "Q1" "ls -la"
# Q2: 큰 명령에서 빠른 종료 비용이 선형인지. bash 3.2 의 ${v//패턴/} 로 정규화하면 8KB 에 약 10초가
# 걸려 모든 큰 heredoc 명령에서 hook 이 멈췄다(구현 중 실측). 정상은 수십 ms 이므로 5초로 가른다.
_q2="cat > f.txt <<'EOF'"$'\n'; while [[ ${#_q2} -lt 12000 ]]; do _q2+="echo \"a \\\$b 'c'\" >> log"$'\n'; done; _q2+="EOF"
_s=$SECONDS; pass "Q2" "$_q2"
[[ $((SECONDS - _s)) -lt 5 ]] && ok || bad "Q2: 12KB 명령에 $((SECONDS - _s))초"

# AC4(빠른 종료)는 판정 결과가 아니라 비용의 차이라 이 판정표로 관찰할 수 없다. 빠른 종료가
# 너무 좁아지는 회귀는 B13·B17 이 잡고, 비용은 mutation 보고의 실측으로 남긴다.

# M3: 안내의 정리 명령을 그대로 붙여 넣으면 (공백 경로라도) 기본 체크아웃으로 이동한다.
run_case 2 "M3" "$GW" "trash ." "$GW"
_m3="$(printf '%s\n' "$LAST_ERR" | sed -n 's/^ *\(cd .*\) && bash rd-workflow\/scripts\/rd task list$/\1/p')"
_m3d="$( (eval "$_m3" && pwd -P) 2>/dev/null )"
[[ -n "$_m3" && "$_m3d" == "$(cd "$GM" && pwd -P)" ]] && ok || bad "M3: 안내 명령 [$_m3] 이 기본 체크아웃으로 가지 않음 (도착: $_m3d)"

# M2: 기본 체크아웃 자체
run_case 2 "M2" "$S" "trash \"$S\"" "$S"
case "$LAST_ERR" in *"기본 체크아웃입니다"*) ok ;; *) bad "M2: 문구 누락 [$LAST_ERR]" ;; esac

# J1·J2: 한 도구를 뺀 PATH
ISO_BASE_DEPS="bash dirname cat sed grep env mktemp rm ln head tr awk date mkdir git"
make_iso() { # <넣을 판독기> <뺄 판독기>
  local b src
  [[ -n "$ISO_DIR" && -d "$ISO_DIR" ]] && rm -rf "$ISO_DIR"
  ISO_DIR="$(mktemp -d)" || return 1   # mktemp-scan: custom-handler
  [[ -n "$ISO_DIR" && -d "$ISO_DIR" ]] || return 1   # mktemp-scan: custom-handler
  for b in $ISO_BASE_DEPS $1; do
    src="$(command -v "$b" 2>/dev/null)"
    [[ -n "$src" && -x "$src" ]] || continue
    ln -s "$src" "$ISO_DIR/$b" 2>/dev/null
  done
  if PATH="$ISO_DIR" command -v "$2" >/dev/null 2>&1; then bad "환경: 격리 PATH 에서 $2 가 보임"; return 1; fi
  return 0
}
run_iso() { # <ID> <기대rc> <cmd>
  local json rc
  json="$(mkjson "$3" "$R")"
  printf '%s' "$json" | env PATH="$ISO_DIR" "$BASH_BIN" "$R/$GATE" >/dev/null 2>&1; rc=$?
  [[ $rc -eq $2 ]] && ok || bad "$1 — 기대 $2, 실제 $rc"
}
if [[ $HAVE_JQ -eq 1 ]]; then
  if make_iso jq python3; then
    run_iso "J1-B1" 2 "/usr/bin/trash \"$R\" && git -C \"$M\" worktree prune"
    run_iso "J1-P1" 0 "trash \"$R/node_modules\""
  fi
else echo "skip: J1 (jq 없음)"; fi
if [[ $HAVE_PY -eq 1 ]]; then
  if make_iso python3 jq; then
    run_iso "J2-B1" 2 "/usr/bin/trash \"$R\" && git -C \"$M\" worktree prune"
    run_iso "J2-P1" 0 "trash \"$R/node_modules\""
  fi
else echo "skip: J2 (python3 없음)"; fi

echo "test_self_worktree_delete_gate: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
