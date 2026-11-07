#!/usr/bin/env bash
# self_worktree_delete_gate.sh — 세션이 자기 작업 폴더(worktree)를 셸 명령으로 지우는 것을 막는다.
#
# 왜 필요한가: 작업 세션이 자기 worktree 나 그 상위 폴더를 trash·rm·git worktree remove 로
# 지우면 이 세션의 gate hook 파일과 셸 작업 디렉터리가 함께 사라진다.
# archive-merge-safety change spec D5 표에서 20건 중 12~13건이 이 형태였다.
#
# 판정: 명령에서 삭제 대상을 구해(_delete_scan.awk) 세션 루트(스크립트 위치 기준, 논리·물리 경로)가
#   대상과 같거나 대상 아래에 있으면 차단한다. 세션 루트를 CLAUDE_PROJECT_DIR 이 아니라 스크립트
#   위치로 정하는 이유: 지워지면 hook 이 꺼지는 폴더가 바로 이 파일이 든 폴더다.
# fail-open 범위: 명령·해석 결과를 구할 수 없는 경우(필드 없음, awk 해석 불가, 대상 U)는 통과한다.
#   단 차단 때 하는 _guard_common.sh source 의 실패는 삼키지 않고 0 이 아닌 코드로 끝난다.
# 한계: eval, bash -c, find -exec, xargs, glob, rmdir, 스크립트 안의 삭제, $'…' 인용, 셸 함수·alias,
#   후보 집합이 8개를 넘는 경우와 조건부 대입 변수를 쓰는 대상은 막지 못한다.
set -euo pipefail

_hook_input="$(cat)"; _hook_input_read=1

# 빠른 종료: 이름이 드러날 수 없는 입력이면 라이브러리를 source 하기 전에 끝낸다.
# cwd·transcript_path 에도 "worktree" 가 들어 있으므로 tool_input 키 뒤쪽만 본다.
# 인용·이스케이프로 이름을 숨긴 표기("rm", r\m, 줄 연속, tra'sh')는 그 문자를 지운 사본에서 본다.
# 지우기는 sed 한 번으로 한다 — bash 3.2 의 ${v//패턴/} 는 입력 길이에 대해 급격히 느려져
# (실측 8KB 에 9.7초) 큰 heredoc 명령마다 hook 이 멈춘다. sed 는 백슬래시나 홑따옴표가 있을 때만
# 부른다. 둘 다 없으면 인용·이스케이프로 이름을 숨길 수 없다 (JSON 안의 " 는 \" 로 나타난다).
_n="${_hook_input#*\"tool_input\"}"
_bs='\'; _sq="'"
# rm 은 뒤에 영숫자·_·- 가 아닌 문자가 오면 후보로 본다. 공백만 보면 `rm</dev/null -rf .` 처럼
# 리다이렉션이 붙은 호출을 놓친다(해석기는 이 표기를 처리한다).
_swd_named() { [[ "$1" == *trash* || "$1" == *rm[!A-Za-z0-9_-]* || "$1" == *worktree* ]]; }
if ! _swd_named "$_n" && [[ "$_hook_input" != *"${_bs}u"* ]]; then
  [[ "$_n" == *"$_bs"* || "$_n" == *"$_sq"* ]] || exit 0
  # 순서: 줄 연속(JSON 의 \\\n) → 이스케이프된 백슬래시(\\) → \" → 남은 " 와 '
  _n="$(printf '%s' "$_n" | LC_ALL=C sed -e 's/\\\\\\n//g' -e 's/\\\\//g' -e 's/\\"//g' -e "s/[\"']//g" 2>/dev/null)" || _n=""
  _swd_named "$_n" || exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"

# 명령과 cwd 를 한 번의 jq(없으면 python3) 호출로 읽는다. 첫 줄이 cwd(개행 제거), 나머지가 명령이다.
# _guard_common.sh 는 차단할 때만 source 한다 — 삭제 이름이 든 명령마다 source(약 75ms)와
# jq 두 번(약 100ms)을 쓰지 않기 위해서다. 판독 순서(jq → python3 → 판정 안 함)는
# _rd_guard_json_get 과 같다.
_pair=""
if command -v jq >/dev/null 2>&1; then
  _pair="$(printf '%s' "$_hook_input" | jq -j '((.cwd // "") | tostring | gsub("\n"; "")) + "\n" + ((.tool_input.command // "") | tostring)' 2>/dev/null)" || _pair=""
elif command -v python3 >/dev/null 2>&1; then
  _pair="$(printf '%s' "$_hook_input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
ti = d.get("tool_input")
c = ti.get("command") if isinstance(ti, dict) else None
w = d.get("cwd")
sys.stdout.write((w if isinstance(w, str) else "").replace("\n", "") + "\n" + (c if isinstance(c, str) else ""))
' 2>/dev/null)" || _pair=""
fi
[[ "$_pair" == *$'\n'* ]] || exit 0
cwd="${_pair%%$'\n'*}"
cmd="${_pair#*$'\n'}"
[[ -n "$cmd" ]] || exit 0
[[ -n "$cwd" && -d "$cwd" ]] || cwd="$PWD"

RL="$project_root"
RP="$(cd -P "$project_root" && pwd)"

scan="$(printf '%s' "$cmd" | awk -v start_dir="$cwd" -v home="${HOME:-/}" -f "${script_dir}/_delete_scan.awk" 2>/dev/null)" || exit 0

# _swd_under <대상> <루트>: 루트가 대상과 같거나 대상 아래에 있으면 참 (디렉터리 경계 기준).
_swd_under() { [[ "$2" == "$1" || "$2" == "$1"/* || "$1" == / ]]; }

# _swd_phys_target <t>: 부모 디렉터리만 물리 경로로 풀고 마지막 구성 요소는 그대로 둔다.
_swd_phys_target() {
  local t="$1" d b
  d="${t%/*}"; b="${t##*/}"
  [[ -z "$d" ]] && d=/
  [[ -d "$d" ]] || { printf '%s' "$t"; return; }
  d="$(cd -P "$d" 2>/dev/null && pwd)" || { printf '%s' "$t"; return; }
  [[ "$d" == / ]] && d=""
  printf '%s/%s' "$d" "$b"
}

hit=""
# _swd_suffix <이름> <루트>: 루트의 끝 구성 요소들이 이름과 같으면 참 (git worktree 이름 축약).
_swd_suffix() {
  local w="$1"
  while [[ "$w" == */ ]]; do w="${w%/}"; done
  [[ -n "$w" && ( "$2" == "$w" || "$2" == */"$w" ) ]]
}

# _swd_suffix_unique <이름>: 등록된 worktree 중 끝 이름이 <이름>인 것이 둘 이상이면 거짓.
# git 은 끝 이름 일치가 정확히 하나일 때만 축약으로 풀고, 둘 이상이면 정확한 경로로 해석한다
# (worktree.c find_worktree_by_suffix). 정확한 경로 쪽은 T 줄이 따로 판정한다.
# 목록을 못 읽으면 참(차단 유지)이다.
_swd_suffix_unique() {
  local list p n=0
  list="$(git -C "$RL" worktree list --porcelain 2>/dev/null)" || return 0
  while IFS= read -r p; do
    [[ "$p" == "worktree "* ]] || continue
    _swd_suffix "$1" "${p#worktree }" && n=$((n + 1))
  done <<< "$list"
  [[ "$n" -lt 2 ]]
}

while IFS=$'\t' read -r kind t; do
  if [[ "$kind" == S && -n "$t" ]]; then
    if { _swd_suffix "$t" "$RL" || _swd_suffix "$t" "$RP"; } && _swd_suffix_unique "$t"; then
      hit="$t (git worktree 이름)"; break
    fi
    continue
  fi
  [[ "$kind" == T && -n "$t" ]] || continue
  tp="$(_swd_phys_target "$t")"
  if _swd_under "$t" "$RL" || _swd_under "$t" "$RP" || _swd_under "$tp" "$RL" || _swd_under "$tp" "$RP"; then
    hit="$t"; break
  fi
done <<< "$scan"
[[ -n "$hit" ]] || exit 0

source "${script_dir}/_guard_common.sh"

main_co=""
common="$(git -C "$RL" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
[[ -n "$common" ]] && main_co="${common%/*}"

{
  echo "[guard] 이 세션이 쓰는 작업 폴더를 지우는 명령이라 막았습니다."
  echo "        작업 폴더: ${RL}"
  echo "        지우려던 대상: ${hit}"
  echo "        이 폴더가 사라지면 이 세션의 gate hook 과 셸 작업 디렉터리가 함께 사라집니다."
  if [[ -n "$main_co" && ( "$main_co" == "$RL" || "$main_co" == "$RP" ) ]]; then
    echo "        이 폴더는 저장소의 기본 체크아웃입니다. 지우려면 세션을 끝낸 뒤 직접 지우십시오."
  else
    echo "        worktree 정리는 세션이 끝난 뒤 기본 체크아웃에서 합니다:"
    # 경로는 홑따옴표로 감싸 그대로 붙여 넣을 수 있게 한다 (공백 경로). 경로 안의 ' 는 '\'' 로 바꾼다.
    if [[ -n "$main_co" ]]; then
      _sq="'"; _co="'${main_co//$_sq/$_sq\\$_sq$_sq}'"
    else
      _co="<기본 체크아웃>"
    fi
    echo "          cd ${_co} && bash rd-workflow/scripts/rd task list"
    echo "        세션 안에서 이 worktree 를 직접 지우지 마십시오."
  fi
} >&2
# reason: 세션이 자기 작업 폴더(또는 그 상위)를 지우려 한 분기.
guard_deny "self_worktree_delete_gate.self-delete"
