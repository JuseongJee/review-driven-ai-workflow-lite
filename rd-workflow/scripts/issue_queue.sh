#!/usr/bin/env bash
# issue_queue.sh — 팀 Issue 집어 가기의 원격 조작·장부·판정을 맡는 단일 진입점.
#
# 하위 명령: repos has-team-queue list claim link release forget release-fr stale close-fr issue-refs commit-url produce
# close-fr 는 `--skip-closed` 를 주면 닫힌 Issue 에 댓글·닫기를 하지 않고, stdout 에
#   Issue 마다 `closed <Issue URL>` 또는 `skipped-closed <Issue URL>` 한 줄을 낸다(연결 없으면 출력 없음).
#   호스트가 적힌 참조로 닫았는데 같은 번호의 호스트 없는 선점 행이 남으면 `kept-row <repo> <n>` 줄을 더한다.
#   html_url 키의 행이 다른 FR 에 연결돼 남으면 `kept-other-fr <키> <번호> <FR>` 줄을 낸다.
#   원격 처리 뒤 장부 정리만 실패한 Issue 는 `ledger-left <repo> <n>` 줄을 낸다(복구는 forget). 이 줄들은 rc 와
#   상관없이 나온다. 실패가 모두 장부 정리 실패면 rc 10, 원격 실패가 하나라도 있으면 그 rc 다.
# forget <repo> <n> 은 원격을 건드리지 않고 장부 행만 지운다(닫은 Issue 의 장부 정리 복구용).
#   상세의 github-issue 는 `[host/]owner/repo#N`·Issue URL 을 쉼표로 이은 목록이다. 형식이 어긋나면 rc 2.
# issue-refs <detail> 은 같은 검사로 `[host/]owner/repo#N` 을 줄마다 낸다. `--closes` 를 주면 같은 순서로 PR 본문
#   Closes 줄에 쓸 참조를 낸다(URL 은 적힌 그대로, 호스트 붙은 축약은 https Issue URL, 나머지는 그대로).
# gh 는 RD_GH(기본 gh)로 바꿀 수 있다(테스트용 가짜 주입).
# 장부: RD_ISSUE_LEDGER 또는 $(git rev-parse --git-common-dir)/rd-issue-claims.tsv
#   행: repo<TAB>number<TAB>url<TAB>fr-stem|-<TAB>claimed-at
#   claim 은 repo·url 을 gh 응답의 html_url 에서 만든다(repo = `host/owner/repo`, github.com 도 붙임). html_url 이 없던
#   응답과 옛 장부의 행은 적힌 저장소 그대로다. 호스트 없이 부른 link·release 는 같은 owner/repo·번호의 행이
#   하나면 그 행을 쓰고, 여러 호스트로 있으면 아무것도 바꾸지 않고 rc 2 로 호스트를 붙인 명령을 알린다.
#   장부를 읽지 못하면(권한·일반 파일 아님) 원격과 장부를 바꾸지 않고 rc 9 다. forget 은 적힌 키의 행만 지운다.
# 잠금: "$장부.lock" 디렉터리(mkdir). 대기 초는 RD_ISSUE_LOCK_WAIT(기본 10, 소수 허용).
# 종료 코드 공통 의미(장부를 고치는 명령): 9 = 원격 변경 전 실패(무변경), 10 = 원격 변경 뒤
#   장부 정리 실패(행 남음), 11 = 닫힌 Issue(claim), 12 = 다른 저장소로 옮겨진 Issue(claim, 무변경). 9·10 의 stderr 마지막 줄은
#   `장부 행: 남음|없음 — 재실행: <명령>`.
# bash 3.2·BSD 도구에서 동작한다(연관배열·sed -i 없음). JSON 은 python3 -I.

set -o pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${RD_GH:-gh}"
SELF_CMD="bash rd-workflow/scripts/issue_queue.sh"
ROOT="${project_root:-}"
LEDGER=""
LOCK=""
LOCK_HELD=0
TMPD=""
RHOST=""
RSLUG=""

_cleanup() {
  if [ "$LOCK_HELD" = 1 ] && [ -n "$LOCK" ]; then rmdir "$LOCK" 2>/dev/null; fi
  LOCK_HELD=0
  if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then rm -rf "$TMPD"; fi
}
trap _cleanup EXIT

die() { printf '%s\n' "$*" >&2; }

mk_tmp() {
  if [ -z "$TMPD" ]; then
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/iq.XXXXXX")" || { die "issue_queue.sh: 임시 디렉터리 생성 실패"; exit 1; }
  fi
}

need_root() {
  [ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
}

# ---- 설정 ----
cfg() {
  need_root
  [ -f "$ROOT/rd-workflow/config/workflow.json" ] || return 0
  python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
if isinstance(v, list):
    for x in v:
        if isinstance(x, str):
            print(x)
elif isinstance(v, str):
    print(v)
' "$ROOT/rd-workflow/config/workflow.json" "$1"
}

# ---- JSON 연속 배열 읽기 ----
PYDEC='
import json, sys
def read_items(s):
    dec = json.JSONDecoder()
    i = 0
    items = []
    while True:
        while i < len(s) and s[i].isspace():
            i += 1
        if i >= len(s):
            break
        v, i = dec.raw_decode(s, i)
        if not isinstance(v, list):
            raise ValueError("배열이 아님")
        items.extend(v)
    return items
'

# ---- 저장소 표기 ----
split_repo() {
  local r="$1" s
  s="${r//[^\/]/}"
  if [ "${#s}" -ge 2 ]; then RHOST="${r%%/*}"; RSLUG="${r#*/}"; else RHOST=""; RSLUG="$r"; fi
}

repo_url() { # <repo> <n> → REPO_URL (호스트가 없으면 github.com 으로 추정한 URL — 장부 키를 만들 때 쓰지 않는다)
  split_repo "$1"
  REPO_URL="https://${RHOST:-github.com}/$RSLUG/issues/$2"
}

# url_repo <Issue URL> → URL_REPO=`host/owner/repo`(호스트 소문자), URL_NUM=번호. gh 응답의 html_url 에서 장부 키를 만든다.
#   Issue URL 형식이 아니면 rc 1. 옮겨진 Issue 는 저장소와 번호가 함께 바뀌므로 번호도 대조한다.
url_repo() {
  local u="$1" h
  case "$u" in http://*|https://*) ;; *) return 1 ;; esac
  u="${u#*://}"; u="${u%/}"
  printf '%s' "$u" | grep -Eq '^[A-Za-z0-9.-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+$' || return 1
  h="$(printf '%s' "${u%%/*}" | tr 'A-Z' 'a-z')"
  u="${u#*/}"
  URL_REPO="$h/${u%/issues/*}"
  URL_NUM="${u##*/issues/}"
}

# remote URL → `o/r`(github.com) 또는 `host/o/r`. 해석 불가면 rc 1.
remote_to_repo() {
  local u="$1" host path
  u="${u%/}"; u="${u%.git}"
  case "$u" in
    http://*|https://*) u="${u#*://}"; host="${u%%/*}"; u="${u#*@}"; host="${u%%/*}"; path="${u#*/}" ;;
    ssh://*) u="${u#ssh://}"; u="${u#*@}"; host="${u%%/*}"; path="${u#*/}"; host="${host%%:*}" ;;
    *@*:*) u="${u#*@}"; host="${u%%:*}"; path="${u#*:}" ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  case "$path" in */*/*|/*|*/|"") return 1 ;; */*) ;; *) return 1 ;; esac
  if [ "$host" = github.com ]; then printf '%s\n' "$path"; else printf '%s/%s\n' "$host" "$path"; fi
}

gm_load() { # 줄마다 repo<TAB>path (상대 URL 등 해석 불가는 경고 후 건너뜀)
  need_root
  local f="$ROOT/.gitmodules" key val name path r
  [ -f "$f" ] || return 0
  git config -f "$f" --get-regexp '^submodule\..*\.url$' 2>/dev/null | while read -r key val; do
    name="${key#submodule.}"; name="${name%.url}"
    path="$(git config -f "$f" --get "submodule.$name.path" 2>/dev/null)"
    if r="$(remote_to_repo "$val")"; then
      printf '%s\t%s\n' "$r" "${path:--}"
    else
      printf '경고: .gitmodules 의 %s (%s) URL 을 해석할 수 없어 건너뜁니다\n' "$name" "$val" >&2
    fi
  done
}

# ---- gh ----
gh_api() { # <host> <gh api 인자...>
  local host="$1"; shift
  local a=(api)
  [ -n "$host" ] && a+=(--hostname "$host")
  "$GH" "${a[@]}" "$@"
}

view_issue() { # <repo> <n> → "state<TAB>html_url|-<TAB>담당자수<TAB>login,login"
  # html_url 은 gh 가 실제로 고른 호스트의 Issue URL 이다(호스트 없는 저장소도). 없으면 `-`.
  local out
  split_repo "$1"
  out="$(gh_api "$RHOST" "repos/$RSLUG/issues/$2")" || return 1
  printf '%s' "$out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
l = [a.get("login", "") for a in (d.get("assignees") or [])]
print("%s\t%s\t%d\t%s" % (d.get("state", ""), d.get("html_url") or "-", len(l), ",".join(l)))
'
}

get_login() { # <host>
  local l
  l="$(gh_api "$1" user --jq .login 2>/dev/null)" || return 0
  l="${l%%$'\n'*}"; l="${l//[[:space:]]/}"
  printf '%s' "$l"
}

# ---- 장부 ----
ledger_path() {
  [ -n "$LEDGER" ] && return 0
  if [ -n "${RD_ISSUE_LEDGER:-}" ]; then LEDGER="$RD_ISSUE_LEDGER"
  else
    local d
    d="$(git rev-parse --git-common-dir 2>/dev/null)" && d="$(cd "$d" && pwd)" || { die "장부 위치를 찾을 수 없습니다 (git 저장소 밖)"; exit 9; }
    LEDGER="$d/rd-issue-claims.tsv"
  fi
  # 장부가 링크면 실제 파일 경로를 쓴다 — 잠금(<장부>.lock)을 같은 장부의 모든 경로가 공유하고, 임시 파일 + mv 교체가
  #   링크를 일반 파일로 바꾸지 않고 실제 파일을 원자적으로 바꾼다. 끊어진 링크는 그대로 두어 읽기 실패로 알린다.
  #   장부를 고치는 쪽은 ledger_swap 으로 실제 장부의 접근 권한을 임시 파일에 입힌 뒤 바꿔 끼운다.
  if [ -L "$LEDGER" ] && [ -e "$LEDGER" ]; then
    LEDGER="$(python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$LEDGER")" || { die "장부 링크를 풀 수 없습니다: $LEDGER"; exit 9; }
  fi
  return 0
}

lock_acquire() {
  local max i=0 w ip fp
  ledger_path
  LOCK="$LEDGER.lock"
  w="${RD_ISSUE_LOCK_WAIT:-10}"; ip="${w%%.*}"; fp="${w#*.}"
  [ "$fp" = "$w" ] && fp=0
  fp="${fp:0:1}"; max=$(( ${ip:-0} * 10 + ${fp:-0} ))
  [ "$max" -lt 1 ] && max=1
  [ -d "${LEDGER%/*}" ] || mkdir -p "${LEDGER%/*}" 2>/dev/null
  while ! mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$max" ]; then
      die "장부 잠금을 잡지 못했습니다 — 다른 rd 명령이 끝난 뒤 다시 실행하십시오. 강제 종료로 남은 잠금이면 $LOCK 폴더를 지우십시오"
      return 1
    fi
    sleep 0.1
  done
  LOCK_HELD=1
  return 0
}

lock_release() {
  if [ "$LOCK_HELD" = 1 ]; then rmdir "$LOCK" 2>/dev/null; fi
  LOCK_HELD=0
}

has_row() { # <repo> <n>
  [ -f "$LEDGER" ] || return 1
  awk -F'\t' -v r="$1" -v n="$2" '$1==r && $2==n {f=1} END{exit !f}' "$LEDGER"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# resolve_key <repo> <n> → KEY (장부 행의 키). claim 은 gh 응답의 html_url 로 `host/owner/repo` 키를 쓰므로,
#   호스트 없이 부른 명령은 장부에서 행을 찾는다. 적힌 키(대소문자 무시)의 행이 있으면 그 키다(호스트 없는 옛 행 포함).
#   없고 적힌 저장소에 호스트가 없으면 `host/<repo>` 키의 같은 번호 행을 찾아 하나면 그 키, 여럿이면 rc 3 이고
#   KEY_CANDIDATES 에 후보 키를 줄마다 남긴다. 찾지 못하면 적힌 그대로다. 호스트를 추측하지 않는다.
KEY_CANDIDATES=""
resolve_key() {
  local m cnt
  KEY="$1"; KEY_CANDIDATES=""
  ledger_path
  # 읽지 못한 장부를 「행 없음」으로 넘기면 호스트 없는 인자가 gh 기본 호스트로 간다 — rc 4 로 알린다.
  #   아직 만들지 않은 장부만 「행 없음」이다.
  #   상위 디렉터리에 들어갈 수 없으면 장부가 있는지 알 수 없으므로 읽기 실패다(ledger_delete_ref 와 같은 판정).
  if [ ! -e "$LEDGER" ] && [ ! -L "$LEDGER" ] && [ -d "$(dirname "$LEDGER")" ] && [ -x "$(dirname "$LEDGER")" ]; then return 0; fi
  { [ -f "$LEDGER" ] && [ -r "$LEDGER" ]; } || return 4
  m="$(awk -F'\t' -v r="$1" -v n="$2" '$2==n && tolower($1)==tolower(r) {print $1; exit}' "$LEDGER" 2>/dev/null)" || return 4
  if [ -n "$m" ]; then KEY="$m"; return 0; fi
  case "$1" in */*/*) return 0 ;; esac
  m="$(awk -F'\t' -v r="$1" -v n="$2" '$2==n { s=$1; if (sub(/^[^\/]*\//, "", s) && index(s, "/") && tolower(s)==tolower(r)) print $1 }' "$LEDGER" 2>/dev/null)" || return 4
  cnt="$(printf '%s' "$m" | grep -c .)"
  [ "$cnt" = 0 ] && return 0
  if [ "$cnt" = 1 ]; then KEY="$m"; return 0; fi
  KEY_CANDIDATES="$m"
  return 3
}

# 호스트 없는 인자가 여러 호스트의 행과 맞을 때: 아무것도 바꾸지 않고 호스트를 붙인 명령 전문을 알린다. rc 2.
ambiguous_key() { # <repo> <n> <하위 명령> [뒤 인자]
  local k
  die "장부에 $1#$2 의 선점 행이 여러 호스트로 있습니다 — 아무것도 바꾸지 않았습니다. 호스트를 붙여 다시 실행하십시오:"
  while IFS= read -r k; do
    [ -n "$k" ] && die "  $SELF_CMD $3 $k $2${4:+ $4}"
  done <<EOF
$KEY_CANDIDATES
EOF
  return 2
}

# need_key <repo> <n> <하위 명령> [뒤 인자] → KEY. rc 0 / 2 여러 후보 / 9 장부 읽기 실패(원격·장부 무변경).
need_key() {
  local rc=0
  resolve_key "$1" "$2" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) ambiguous_key "$1" "$2" "$3" "${4:-}"; return 2 ;;
  esac
  die "장부를 읽을 수 없습니다: $LEDGER — 원격과 장부를 바꾸지 않았습니다. 읽기 권한을 확인하십시오"
  report_last 남음 "$SELF_CMD $3 $1 $2${4:+ $4}"
  return 9
}

ledger_reserve() { # rc 0 / 8 이미 있음 / 9 잠금 실패
  lock_acquire || return 9
  # 예약은 적힌 키만 본다 — 호스트 없는 인자는 아직 어느 호스트인지 모른다. 다른 표기의 같은 Issue 는
  #   첫 조회 뒤 ledger_rekey 가 html_url 키로 판정한다.
  if has_row "$1" "$2"; then lock_release; return 8; fi
  repo_url "$1" "$2"
  if ! printf '%s\t%s\t%s\t-\t%s\n' "$1" "$2" "$REPO_URL" "$(now)" >> "$LEDGER"; then
    lock_release; return 9
  fi
  lock_release
  return 0
}

# ledger_swap <tmp> — 내용을 다 쓴 임시 파일에 장부의 접근 권한을 입혀 장부와 원자적으로 바꾼다.
#   권한은 내용을 쓴 뒤에 입힌다 — 읽기 전용(0444) 장부도 종전처럼 바꿔 끼울 수 있다. 실패하면 임시 파일을 지우고 rc 1.
#   임시 파일은 (umask 077; …) 로 만들어 권한을 입히기 전에도 다른 계정이 읽지 못하게 한다.
ledger_swap() {
  if python3 -I -c 'import os,stat,sys; os.chmod(sys.argv[2], stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$LEDGER" "$1" \
    && mv "$1" "$LEDGER"; then return 0; fi
  rm -f "$1"; return 1
}
ledger_delete() { # rc 0 / 1 잠금·쓰기 실패. 행이 없으면 잠금 없이 0
  ledger_path
  has_row "$1" "$2" || return 0
  lock_acquire || return 1
  if (umask 077; awk -F'\t' -v r="$1" -v n="$2" '!($1==r && $2==n)' "$LEDGER" > "$LEDGER.tmp.$$") && ledger_swap "$LEDGER.tmp.$$"; then
    lock_release; return 0
  fi
  rm -f "$LEDGER.tmp.$$"
  lock_release
  return 1
}

# ledger_delete_ref <repo> <n> — 저장소 키(대소문자 무시)와 번호가 같은 행을 지운다. 키는 claim 이 적은 표기
#   그대로이며 호스트를 추측해 다른 표기의 행을 함께 지우지 않는다.
#   rc 0 (행 없음 포함) / 1 장부 읽기·잠금·쓰기 실패 — 읽지 못한 장부를 "행 없음" 으로 넘기지 않는다.
#   DEL_STEM(`|stem|stem|` 목록)이 있으면 FR 칸이 `-` 이거나 목록의 stem 인 행만 지운다(다른 FR 에 연결된 행은 남긴다).
DEL_STEM=""
ledger_delete_ref() {
  local rc=0
  ledger_path
  if [ ! -e "$LEDGER" ]; then
    # 아직 만들지 않은 장부만 「행 없음」 이다. 끊어진 링크·들어갈 수 없는 상위 디렉터리는 읽기 실패다.
    if [ ! -L "$LEDGER" ] && [ -d "$(dirname "$LEDGER")" ] && [ -x "$(dirname "$LEDGER")" ]; then return 0; fi
    die "장부를 읽을 수 없습니다: $LEDGER"; return 1
  fi
  { [ -f "$LEDGER" ] && [ -r "$LEDGER" ]; } || { die "장부를 읽을 수 없습니다: $LEDGER"; return 1; }
  # 일치 행 없음은 rc 3 — awk 자체의 실패(rc 1·2)와 구분한다.
  awk -F'\t' -v r="$1" -v n="$2" -v s="$DEL_STEM" 'tolower($1)==tolower(r) && $2==n && (s=="" || $4=="-" || index(s, "|" $4 "|")) {f=1} END{exit f?0:3}' "$LEDGER" || rc=$?
  [ "$rc" = 3 ] && return 0
  [ "$rc" = 0 ] || { die "장부를 읽지 못했습니다: $LEDGER (rc $rc)"; return 1; }
  lock_acquire || return 1
  if (umask 077; awk -F'\t' -v r="$1" -v n="$2" -v s="$DEL_STEM" '!(tolower($1)==tolower(r) && $2==n && (s=="" || $4=="-" || index(s, "|" $4 "|")))' "$LEDGER" > "$LEDGER.tmp.$$") && ledger_swap "$LEDGER.tmp.$$"; then
    lock_release; return 0
  fi
  rm -f "$LEDGER.tmp.$$"
  lock_release
  return 1
}

ledger_link() { # <repo> <n> <stem> rc 0 / 1
  lock_acquire || return 1
  [ -f "$LEDGER" ] || : > "$LEDGER"
  if has_row "$1" "$2"; then
    (umask 077; awk -F'\t' -v OFS='\t' -v r="$1" -v n="$2" -v s="$3" '$1==r && $2==n {$4=s} {print}' "$LEDGER" > "$LEDGER.tmp.$$") \
      && ledger_swap "$LEDGER.tmp.$$" || { rm -f "$LEDGER.tmp.$$"; lock_release; return 1; }
  else
    repo_url "$1" "$2"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$REPO_URL" "$3" "$(now)" >> "$LEDGER" || { lock_release; return 1; }
  fi
  lock_release
  return 0
}

# ledger_rekey <적힌 키> <n> <새 키> <URL> — claim 이 예약한 행의 키·URL 을 gh 응답의 html_url 기준으로 바꾼다.
#   rc 0 / 8 새 키의 행이 이미 있음(예약한 행은 지운다) / 1 잠금·쓰기 실패(예약한 행은 그대로).
ledger_rekey() {
  lock_acquire || return 1
  if [ "$1" != "$3" ] && has_row "$3" "$2"; then
    if (umask 077; awk -F'\t' -v r="$1" -v n="$2" '!($1==r && $2==n)' "$LEDGER" > "$LEDGER.tmp.$$") && ledger_swap "$LEDGER.tmp.$$"; then
      lock_release; return 8
    fi
    rm -f "$LEDGER.tmp.$$"; lock_release; return 1
  fi
  if (umask 077; awk -F'\t' -v OFS='\t' -v r="$1" -v n="$2" -v k="$3" -v u="$4" '$1==r && $2==n {$1=k; $3=u} {print}' "$LEDGER" > "$LEDGER.tmp.$$") \
    && ledger_swap "$LEDGER.tmp.$$"; then
    lock_release; return 0
  fi
  rm -f "$LEDGER.tmp.$$"; lock_release; return 1
}

# 값이 필요한 옵션 뒤에 값이 없으면 rc 2 (shift 2 실패로 같은 옵션을 무한히 도는 것을 막는다)
need_val() { [ $# -ge 2 ] || { die "옵션 값이 없습니다: $1"; return 2; }; }

# 마지막 줄 규약: 장부 행 잔존 여부와 다시 실행할 명령 전문
report_last() { # <남음|없음> <명령>
  die "장부 행: $1 — 재실행: $2"
}

# 원격 결과를 알 수 없어 행을 남길 때: Issue URL 과 푸는 명령을 마지막 줄로 알린다.
#   claim 은 장부 키(html_url 기준 `host/owner/repo`)를 넘기므로 URL 도 그 호스트다.
keep_row_report() { # <장부 키> <n>
  repo_url "$1" "$2"
  die "Issue: $REPO_URL"
  report_last 남음 "$SELF_CMD release $1 $2"
}

# 원격 해제 뒤 행 삭제. 잠금 실패면 10.
cleanup_row() { # <repo> <n> <성공 시 rc>
  if ledger_delete "$1" "$2"; then return "$3"; fi
  report_last 남음 "$SELF_CMD release $1 $2"
  return 10
}

CLAIM_LABEL=""
CLAIM_LABEL_LOADED=0
claim_label() {
  if [ "$CLAIM_LABEL_LOADED" = 0 ]; then CLAIM_LABEL="$(cfg issue_claim_label)"; CLAIM_LABEL_LOADED=1; fi
}

remote_release() { # <repo> <n>
  local a=(issue edit "$2" --repo "$1" --remove-assignee @me) label
  claim_label; label="$CLAIM_LABEL"
  [ -n "$label" ] && a+=(--remove-label "$label")
  "$GH" "${a[@]}" >/dev/null
}

# ---- has-team-queue ----
# 팀 대기열이 있는지 판정한다(rc 0 있음 / 1 없음). repos 의 대상 결정 순서와 같다 —
#   issue_queue_repos 에 빈 문자열이 아닌 값이 있거나, .gitmodules 에서 해석되는 submodule URL 이 있으면 있음.
#   둘 다 없어 origin 으로 폴백하는 저장소는 없음이다. /fr add 의 /fr push 안내 판정에 쓴다.
cmd_has_team_queue() {
  need_root
  [ -n "$(cfg issue_queue_repos)" ] && return 0
  [ -n "$(gm_load 2>/dev/null)" ] && return 0
  return 1
}

# ---- repos ----
cmd_repos() {
  local with_path=0 cfgrepos gm list r paths
  [ "${1:-}" = "--with-path" ] && with_path=1
  need_root
  cfgrepos="$(cfg issue_queue_repos)"
  gm=""
  if [ -z "$cfgrepos" ] || [ "$with_path" = 1 ]; then gm="$(gm_load)"; fi
  if [ -n "$cfgrepos" ]; then
    list="$cfgrepos"
  elif [ -n "$gm" ]; then
    list="$(printf '%s\n' "$gm" | cut -f1 | awk '!s[$0]++')"
  elif [ -f "$ROOT/.gitmodules" ] && git config -f "$ROOT/.gitmodules" --get-regexp '^submodule\..*\.url$' >/dev/null 2>&1; then
    # overlay 인데 submodule URL 을 하나도 해석하지 못함 — origin(overlay 자신)으로 대체하면 개인 저장소에 팀 Issue 를 만든다
    die "submodule 저장소 URL 을 해석하지 못했습니다 — issue_queue_repos 설정으로 대상 저장소를 지정하십시오"; return 3
  else
    r="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" && list="$(remote_to_repo "$r")" || list=""
  fi
  if [ -z "$list" ]; then die "대상 저장소를 정할 수 없습니다 (issue_queue_repos 설정, .gitmodules, origin 모두 없음)"; return 3; fi
  if [ "$with_path" = 0 ]; then printf '%s\n' "$list"; return 0; fi
  printf '%s\n' "$list" | while IFS= read -r r; do
    paths="$(printf '%s\n' "$gm" | awk -F'\t' -v r="$r" '$1==r {p = (p == "" ? $2 : p "," $2)} END{print p}')"
    printf '%s\t%s\n' "$r" "${paths:--}"
  done
}

# ---- list ----
cmd_list() {
  local repos repo out total=0 failed=0 labels claim
  repos="$(cmd_repos)" || return 3
  labels="$(cfg issue_queue_labels)"
  claim="$(cfg issue_claim_label)"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    total=$((total + 1))
    split_repo "$repo"
    if ! out="$(gh_api "$RHOST" --paginate "repos/$RSLUG/issues?state=open&assignee=none&per_page=100")"; then
      die "경고: $repo 의 Issue 를 가져오지 못했습니다"; failed=$((failed + 1)); continue
    fi
    if ! printf '%s' "$out" | python3 -I -c "$PYDEC"'
repo, labels, claim = sys.argv[1], [x for x in sys.argv[2].split("\n") if x], sys.argv[3]
for it in read_items(sys.stdin.read()):
    if not isinstance(it, dict) or "pull_request" in it:
        continue
    names = [l.get("name", "") for l in (it.get("labels") or []) if isinstance(l, dict)]
    if labels and not (set(names) & set(labels)):
        continue
    if claim and claim in names:
        continue
    title = " ".join(str(it.get("title", "")).split())
    print("\t".join([repo, str(it.get("number")), title, str(it.get("html_url", "")), ",".join(names)]))
' "$repo" "$labels" "$claim"; then
      die "경고: $repo 의 응답을 읽지 못했습니다"; failed=$((failed + 1))
    fi
  done <<EOF
$repos
EOF
  if [ "$total" -gt 0 ] && [ "$failed" -eq "$total" ]; then return 3; fi
  return 0
}

# ---- claim ----
cmd_claim() {
  local repo="$1" n="$2" rc info state hurl cnt logins label a login key out=""
  [ -n "$repo" ] && [ -n "$n" ] || { die "사용법: claim <repo> <n>"; return 2; }
  claim_label; label="$CLAIM_LABEL"
  ledger_reserve "$repo" "$n"; rc=$?
  if [ "$rc" = 9 ]; then report_last 없음 "$SELF_CMD claim $repo $n"; return 9; fi
  if [ "$rc" = 8 ]; then die "이미 장부에 있는 선점입니다: $repo#$n"; return 8; fi
  key="$repo"
  if ! info="$(view_issue "$repo" "$n")"; then
    die "Issue 를 조회하지 못했습니다: $repo#$n"
    cleanup_row "$key" "$n" 9; rc=$?
    [ "$rc" = 9 ] && report_last 없음 "$SELF_CMD claim $repo $n"
    return "$rc"
  fi
  IFS=$'\t' read -r state hurl cnt logins <<EOF
$info
EOF
  # 장부 키·URL 을 gh 가 실제로 고른 호스트의 html_url 로 바꾼다(호스트 없는 저장소를 github.com 으로 추정하지 않는다).
  #   html_url 이 없으면 적힌 저장소와 추정 URL 을 그대로 둔다. 원격 명령은 계속 적힌 저장소로 부른다(같은 셸, 같은 호스트).
  if url_repo "$hurl" && [ "$URL_NUM" != "$n" ]; then
    # 옮겨진 Issue — 적힌 번호의 원격 명령은 옮긴 곳의 다른 Issue 에 갈 수 있다. 원격을 바꾸기 전에 멈춘다.
    #   rc 12 — /fr take 를 처음부터 다시 밟아야 FR 이 만들어지므로 claim 명령을 따로 안내하지 않는다.
    die "Issue 가 다른 저장소로 옮겨졌습니다: $repo#$n → $hurl — 선점하지 않았습니다. 옮긴 곳의 Issue 는 /fr take 로 다시 고르십시오"
    cleanup_row "$key" "$n" 12; return $?
  fi
  if url_repo "$hurl"; then
    ledger_rekey "$repo" "$n" "$URL_REPO" "$hurl"; rc=$?
    if [ "$rc" = 8 ]; then die "이미 장부에 있는 선점입니다: $URL_REPO#$n"; return 8; fi
    if [ "$rc" != 0 ]; then
      die "장부 행을 Issue URL 기준으로 바꾸지 못했습니다: $repo#$n"
      cleanup_row "$key" "$n" 9; rc=$?
      [ "$rc" = 9 ] && report_last 없음 "$SELF_CMD claim $repo $n"
      return "$rc"
    fi
    key="$URL_REPO"; out="$hurl"
  fi
  if [ "$state" = closed ]; then die "닫힌 Issue 입니다: $repo#$n"; cleanup_row "$key" "$n" 11; return $?; fi
  if [ "$cnt" -gt 0 ]; then die "이미 담당자가 있습니다: $repo#$n ($logins)"; cleanup_row "$key" "$n" 4; return $?; fi
  a=(issue edit "$n" --repo "$repo" --add-assignee @me)
  [ -n "$label" ] && a+=(--add-label "$label")
  if ! "$GH" "${a[@]}" >/dev/null; then die "선점 호출이 실패했습니다(결과 불명). 장부 행을 남깁니다: $repo#$n"; keep_row_report "$key" "$n"; return 7; fi
  if ! info="$(view_issue "$repo" "$n")"; then die "선점 뒤 재조회가 실패했습니다(결과 불명). 장부 행을 남깁니다: $repo#$n"; keep_row_report "$key" "$n"; return 7; fi
  IFS=$'\t' read -r state _hurl cnt logins <<EOF
$info
EOF
  if [ "$state" = closed ]; then
    remote_release "$repo" "$n" || { die "자기 지정 해제가 실패했습니다. 장부 행을 남깁니다"; keep_row_report "$key" "$n"; return 7; }
    die "닫힌 Issue 입니다: $repo#$n"; cleanup_row "$key" "$n" 11; return $?
  fi
  if [ "$cnt" -gt 1 ]; then
    remote_release "$repo" "$n" || { die "자기 지정 해제가 실패했습니다. 장부 행을 남깁니다"; keep_row_report "$key" "$n"; return 7; }
    die "경합: 다른 담당자가 동시에 지정됐습니다. 물러났습니다: $repo#$n"; cleanup_row "$key" "$n" 5; return $?
  fi
  split_repo "$repo"
  login="$(get_login "$RHOST")"
  case ",$logins," in
    *",$login,"*) [ -n "$login" ] && { [ -n "$out" ] || { repo_url "$repo" "$n"; out="$REPO_URL"; }; printf '%s\n' "$out"; return 0; } ;;
  esac
  remote_release "$repo" "$n" || { die "자기 지정 해제가 실패했습니다. 장부 행을 남깁니다"; keep_row_report "$key" "$n"; return 7; }
  die "내 계정이 담당자로 지정되지 않았습니다: $repo#$n"
  cleanup_row "$key" "$n" 6; return $?
}

cmd_link() {
  local left=없음
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || { die "사용법: link <repo> <n> <fr-stem>"; return 2; }
  need_key "$1" "$2" link "$3" || return $?
  if ledger_link "$KEY" "$2" "$3"; then return 0; fi
  has_row "$KEY" "$2" && left=남음
  report_last "$left" "$SELF_CMD link $1 $2 $3"
  return 9
}

# release <repo> <n> — 장부 행의 키(호스트 포함)로 원격 선점을 푼다. 행이 없으면 적힌 저장소로 푼다.
cmd_release() {
  local key
  need_key "$1" "$2" release || return $?
  key="$KEY"
  if ! remote_release "$key" "$2"; then die "원격 해제가 실패했습니다. 장부 행을 남깁니다: $key#$2"; keep_row_report "$key" "$2"; return 7; fi
  cleanup_row "$key" "$2" 0
}

cmd_release_fr() {
  local stem="$1" rows line rc=0 r left
  ledger_path
  [ -f "$LEDGER" ] || return 0
  lock_acquire || {
    left=없음
    awk -F'\t' -v s="$stem" '$4==s {f=1} END{exit !f}' "$LEDGER" && left=남음
    report_last "$left" "$SELF_CMD release-fr $stem"; return 9
  }
  rows="$(awk -F'\t' -v s="$stem" '$4==s {print $1 "\t" $2}' "$LEDGER")"
  lock_release
  [ -n "$rows" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cmd_release "${line%%$'\t'*}" "${line#*$'\t'}"; r=$?
    [ "$r" -ne 0 ] && [ "$rc" -eq 0 ] && rc=$r
  done <<EOF
$rows
EOF
  return "$rc"
}

# ---- stale ----
fr_value_of() { # <파일> → 첫 status 값 (없거나 읽기 실패면 빈 문자열)
  local line code val cls
  line="$(fr_status_scan "$1" | head -1)"
  IFS=$'\034' read -r code val cls <<EOF
$line
EOF
  [ "$code" = 0 ] && printf '%s' "$val"
}

# fr_eval <stem> → EV = dropped|done|ok|missing|unknown
fr_eval() {
  local stem="$1" rel lt lrc v wt dropped=0 refdone=0 found=0 err=0
  rel="rd-workflow-workspace/backlog/items/$stem.md"
  if [ -z "$BASE" ]; then
    err=1
  else
    lt="$(git -C "$ROOT" ls-tree --name-only "refs/heads/$BASE" -- "$rel" 2>/dev/null)"; lrc=$?
    if [ "$lrc" -ne 0 ]; then
      err=1
    elif [ -n "$lt" ]; then
      if git -C "$ROOT" show "refs/heads/$BASE:$rel" > "$TMPD/ref.md" 2>/dev/null; then
        v="$(fr_value_of "$TMPD/ref.md")"
        case "$v" in
          dropped) dropped=1 ;;
          done|handed-off) refdone=1 ;;
          "") err=1 ;;
          *) found=1 ;;
        esac
      else
        err=1
      fi
    fi
  fi
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    [ -e "$wt/$rel" ] || continue
    v="$(fr_value_of "$wt/$rel")"
    case "$v" in
      dropped) dropped=1 ;;
      "") err=1 ;;
      *) found=1 ;;
    esac
  done <<EOF
$WORKTREES
EOF
  if [ "$dropped" = 1 ]; then EV=dropped
  elif [ "$refdone" = 1 ]; then EV=done
  elif [ "$found" = 1 ]; then EV=ok
  elif [ "$err" = 1 ]; then EV=unknown
  else EV=missing
  fi
}

cmd_stale() {
  local line repo n url stem at buf="" keep reason cmd
  ledger_path
  [ -s "$LEDGER" ] || return 0
  # shellcheck disable=SC1090
  need_root
  source "$SELF_DIR/_fr_status.sh"
  source "$SELF_DIR/lifecycle/_lifecycle_common.sh"
  mk_tmp
  lock_acquire || { report_last 없음 "$SELF_CMD stale"; return 9; }
  BASE="$(project_root="$ROOT" get_default_branch 2>/dev/null)" || BASE=""
  WORKTREES="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /, ""); print}')"
  : > "$TMPD/keep"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r repo n url stem at <<EOF
$line
EOF
    reason=""
    if [ "$stem" = "-" ] || [ -z "$stem" ]; then
      reason="연결 FR 없음"
    else
      fr_eval "$stem"
      case "$EV" in
        dropped) reason="FR dropped" ;;
        done) printf '' ; continue ;;
        ok) ;;
        missing) reason="FR 파일 없음" ;;
        unknown) reason="판정 불가" ;;
      esac
    fi
    printf '%s\n' "$line" >> "$TMPD/keep"
    if [ -n "$reason" ]; then
      cmd="$SELF_CMD release $repo $n"
      [ "$reason" = "판정 불가" ] && cmd="-"
      buf="${buf}${url}"$'\t'"${reason}"$'\t'"${cmd}"$'\n'
    fi
  done < "$LEDGER"
  if ! cmp -s "$TMPD/keep" "$LEDGER"; then
    if (umask 077; cat "$TMPD/keep" > "$LEDGER.tmp.$$") && ledger_swap "$LEDGER.tmp.$$"; then :; else
      rm -f "$LEDGER.tmp.$$"; lock_release; die "장부를 정리하지 못했습니다"; return 9
    fi
  fi
  lock_release
  printf '%s' "$buf"
  return 0
}

# cleanup_closed_row <repo> <n> — 닫은(또는 이미 닫힌) Issue 의 장부 행을 지운다. 실패하면 10 이고 재실행 안내는
#   원격을 건드리지 않는 `forget <적힌 저장소> <번호>` 다(같은 행을 같은 규칙으로 지운다).
#   호스트가 적힌 참조인데 같은 번호의 호스트 없는 행이 있으면 지우지 않고 알린다(--skip-closed 면 kept-row 줄) — 그 행이
#   가리키는 호스트는 선점한 셸의 gh 기본 호스트라 여기서 확정할 수 없다.
#   close_one 이 html_url 에서 얻은 키(CLOSE_KEY)가 있으면 그 키의 행도 지운다(claim 이 쓴 `host/owner/repo` 행).
CLOSE_SKIP=0
CLOSE_KEY=""
CLOSE_STEM=""
cleanup_closed_row() {
  local slug
  ledger_path
  # 남은 호스트 없는 행은 삭제 결과와 상관없이 먼저 알린다(삭제가 실패해도 그 행은 보여야 한다).
  #   stderr 마지막 줄 규약(장부 행: … — 재실행: …)을 지키려고 삭제보다 앞에서 낸다.
  case "$1" in
    */*/*)
      slug="${1#*/}"
      if [ -f "$LEDGER" ] && [ -r "$LEDGER" ] && awk -F'\t' -v r="$slug" -v n="$2" 'tolower($1)==tolower(r) && $2==n {f=1} END{exit !f}' "$LEDGER" 2>/dev/null; then
        [ "$CLOSE_SKIP" = 1 ] && printf 'kept-row %s %s\n' "$slug" "$2"
        die "장부에 호스트 없는 선점 행 $slug#$2 이 남았습니다 — 같은 Issue 면 $SELF_CMD forget $slug $2 로 장부 행만 지우십시오(원격은 건드리지 않습니다)"
      fi ;;
  esac
  # claim 이 html_url 로 만든 키(CLOSE_KEY)의 행과 적힌 키의 행을 지운다. 둘이 같으면(대소문자 무시) 한 번만 지운다.
  #   하나가 실패해도 다른 하나를 시도하고, 실패한 키마다 ledger-left 줄과 forget 안내를 낸다.
  local k other keys="$1" left=0 own="|${CLOSE_STEM:--}|"
  if [ -n "$CLOSE_KEY" ] && [ "$(printf '%s' "$CLOSE_KEY" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ]; then
    keys="$CLOSE_KEY"$'\n'"$1"
  fi
  while IFS= read -r k; do
    # html_url 키(CLOSE_KEY)는 FR 에 적힌 참조가 아니다 — 이 FR(CLOSE_STEM) 또는 연결 FR 없는 행만 지우고,
    #   다른 FR 에 연결된 같은 Issue 의 행은 남긴다(호스트 없는 옛 FR 을 다른 기본 호스트에서 발행하는 경우).
    DEL_STEM=""
    if [ "$k" = "$CLOSE_KEY" ] && [ "$k" != "$1" ]; then
      DEL_STEM="$own"
      # 보존 판정과 FR 이름을 장부 한 번 읽기로 얻는다 — 두 번 읽으면 그 사이의 forget 이 이름을 비운다.
      #   찾으면 `=<FR>` 을 내므로 빈 값은 「행 없음」 뿐이다.
      other=""
      [ -f "$LEDGER" ] && other="$(awk -F'\t' -v r="$k" -v n="$2" -v s="$DEL_STEM" 'tolower($1)==tolower(r) && $2==n && $4!="-" && !index(s, "|" $4 "|") {print "=" $4; exit}' "$LEDGER" 2>/dev/null)"
      if [ -n "$other" ]; then
        [ "$CLOSE_SKIP" = 1 ] && printf 'kept-other-fr %s %s %s\n' "$k" "$2" "${other#=}"
        die "다른 FR 에 연결된 선점 행 $k#$2 은 남겼습니다 — 그 FR 의 선점입니다"
      fi
    fi
    if ledger_delete_ref "$k" "$2"; then DEL_STEM=""; continue; fi
    DEL_STEM=""
    left=1
    [ "$CLOSE_SKIP" = 1 ] && printf 'ledger-left %s %s\n' "$k" "$2"
    report_last 남음 "$SELF_CMD forget $k $2"
  done <<EOF
$keys
EOF
  [ "$left" = 0 ] || return 10
  return 0
}

# ---- forget ----
# forget <repo> <n> — 원격을 건드리지 않고 장부 행만 지운다(저장소 키 대소문자 무시). rc 0 / 10 실패.
cmd_forget() {
  [ -n "$1" ] && [ -n "$2" ] || { die "사용법: forget <repo> <n>"; return 2; }
  # 복구 명령이므로 적힌 키의 행만 지운다 — 호스트 없는 키로 호스트 붙은 행을 찾지 않는다. 안내한 forget 을 다시
  #   실행해도 다른 호스트의 같은 번호 행(다른 FR 의 선점)을 지우지 않게 한다.
  if ledger_delete_ref "$1" "$2"; then return 0; fi
  report_last 남음 "$SELF_CMD forget $1 $2"
  return 10
}

# ---- close-fr / commit-url ----
# close_one <repo> <n> <commit-url> <skip> — Issue 하나에 댓글·닫기·장부 정리. 결과 줄은 cmd_close_fr 규약.
#   원격 처리가 끝나면 CLOSE_RESULT 에 closed|skipped 를 남긴다(부분 실패 요약용). 뒤의 장부 정리가
#   실패해도 원격 결과는 남는다.
CLOSE_RESULT=""
close_one() {
  local repo="$1" n="$2" url="$3" skip="$4" info state hurl cnt logins
  # 원격 명령과 장부 정리는 적힌 저장소를 그대로 쓴다(호스트가 없으면 gh 가 고른다). 결과 URL 은
  # gh 가 돌려준 html_url 을 쓴다 — 호스트를 추측하지 않는다.
  CLOSE_RESULT=""
  if ! info="$(view_issue "$repo" "$n")"; then die "Issue 를 조회하지 못했습니다: $repo#$n"; return 7; fi
  IFS=$'\t' read -r state hurl cnt logins <<EOF
$info
EOF
  # 장부 키는 gh 가 돌려준 html_url 로만 만든다 — 추정 URL(github.com)로는 다른 호스트의 행을 지울 수 있다.
  CLOSE_KEY=""
  if [ -z "$hurl" ] || [ "$hurl" = "-" ]; then repo_url "$repo" "$n"; hurl="$REPO_URL"
  elif url_repo "$hurl" && [ "$URL_NUM" = "$n" ]; then CLOSE_KEY="$URL_REPO"; fi
  REPO_URL="$hurl"
  # --skip-closed: 이미 닫힌 Issue 는 댓글·닫기 없이 장부 행만 정리한다.
  if [ "$skip" = 1 ] && [ "$state" = closed ]; then
    CLOSE_RESULT=skipped
    # 결과 줄은 장부 정리 전에 낸다 — 장부 정리가 실패해도 원격 결과는 보여야 한다.
    printf 'skipped-closed %s\n' "$REPO_URL"
    cleanup_closed_row "$repo" "$n" || return $?
    return 0
  fi
  "$GH" issue comment "$n" --repo "$repo" --body "반영 커밋: $url" >/dev/null || { die "댓글을 달지 못했습니다: $repo#$n"; return 7; }
  if [ "$state" != closed ]; then
    "$GH" issue close "$n" --repo "$repo" >/dev/null || { die "Issue 를 닫지 못했습니다: $repo#$n"; return 7; }
  fi
  CLOSE_RESULT=closed
  [ "$skip" = 1 ] && printf 'closed %s\n' "$REPO_URL"
  cleanup_closed_row "$repo" "$n" || return $?
  return 0
}

# read_issue_value <detail> — 상세의 첫 `- github-issue:` 값(앞뒤 공백 제거).
#   읽기에 실패하면(없음·권한) awk 의 rc 그대로 0 이 아니다 — 값이 없는 것과 구분한다.
read_issue_value() {
  # 일반 파일이 아니면(디렉터리 등) 읽기 실패다 — BSD awk 는 디렉터리를 빈 입력으로 읽고 rc 0 을 낸다.
  [ -f "$1" ] || return 2
  awk '/^- github-issue:/{sub(/^- github-issue:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit}' "$1" 2>/dev/null
}

# parse_issue_refs <github-issue 값> — 쉼표로 나눈 조각마다 형식을 검사해 ISSUE_REFS 에
#   `[host/]owner/repo#N` 을 줄마다 담는다(중복 제거). 조각은 `[host/]owner/repo#N` 또는
#   Issue URL `https://host/owner/repo/issues/N` 이다. URL 은 호스트를 남겨 `host/owner/repo#N` 으로 바꾼다
#   (github.com 도 남긴다 — gh 의 기본 호스트가 다른 환경에서 원격 명령이 다른 호스트로 가지 않게).
#   어긋난 조각이 있으면 그 조각을 알리고 rc 2.
#   close-fr 와 PR 발행(team_publish.sh 의 Closes 줄)이 함께 쓴다.
parse_issue_refs() {
  local rest="$1" tok h c
  ISSUE_REFS=""; ISSUE_CLOSES=""
  # 쉼표로 나눈다. 명령 치환·read -a 는 끝의 빈 조각을 버리므로 매개변수 확장으로 직접 자른다.
  while :; do
    tok="${rest%%,*}"
    tok="$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    c=""
    if printf '%s' "$tok" | grep -Eq '^https?://[A-Za-z0-9.-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+/?$'; then
      c="$tok"   # Closes 줄에는 적힌 URL 을 그대로 쓴다(스킴을 바꾸지 않는다).
      tok="${tok#*://}"; tok="${tok%/}"
      tok="${tok%/issues/*}#${tok##*/issues/}"
    elif ! printf '%s' "$tok" | grep -Eq '^([A-Za-z0-9.-]+/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$'; then
      # archive.sh 는 stderr 마지막 줄을 사유로 옮긴다 — 틀린 조각과 올바른 형식을 한 줄에 담는다.
      die "github-issue 값 형식이 어긋났습니다: '$tok' — owner/repo#N 또는 Issue URL 을 쉼표로 이어 적고(예: a/b#7, a/b#9) 설명은 상세 본문에 적으십시오"
      return 2
    fi
    # 호스트는 대소문자를 가리지 않으므로 소문자로 맞춘다(장부 키·중복 판정이 같은 표기를 쓰게).
    h="${tok%%#*}"; h="${h//[^\/]/}"
    if [ "${#h}" -ge 2 ]; then tok="$(printf '%s' "${tok%%/*}" | tr 'A-Z' 'a-z')/${tok#*/}"; fi
    if [ -z "$c" ]; then
      # 호스트가 붙은 축약 표기는 GitHub 가 읽는 Issue URL 로, 아니면 그대로(PR 저장소의 호스트로 읽힌다).
      if [ "${#h}" -ge 2 ]; then c="https://${tok%#*}/issues/${tok##*#}"; else c="$tok"; fi
    fi
    case $'\n'"$ISSUE_REFS"$'\n' in *$'\n'"$tok"$'\n'*) ;; *)
      ISSUE_REFS="${ISSUE_REFS:+$ISSUE_REFS$'\n'}$tok"; ISSUE_CLOSES="${ISSUE_CLOSES:+$ISSUE_CLOSES$'\n'}$c" ;; esac
    case "$rest" in *,*) rest="${rest#*,}" ;; *) break ;; esac
  done
  return 0
}

# issue-refs <detail> — 상세의 github-issue 를 parse_issue_refs 로 검사해 `[host/]owner/repo#N` 을 줄마다 낸다.
#   값이 없거나 `-` 면 출력 없이 rc 0, 형식이 어긋나면 출력 없이 rc 2(stderr 마지막 줄이 틀린 조각).
cmd_issue_refs() {
  local gi
  [ -n "$1" ] || { die "사용법: issue-refs <detail> [--closes]"; return 2; }
  gi="$(read_issue_value "$1")" || { die "FR 상세를 읽을 수 없습니다: $1"; return 2; }
  if [ -z "$gi" ] || [ "$gi" = "-" ]; then return 0; fi
  parse_issue_refs "$gi" || return 2
  if [ "${2:-}" = --closes ]; then printf '%s\n' "$ISSUE_CLOSES"; else printf '%s\n' "$ISSUE_REFS"; fi
}

# close-fr <detail> — `- github-issue:` 값은 parse_issue_refs 형식의 목록이다(중복 보고 포함).
#   gh 를 부르기 전에 모든 조각을 검사해, 어긋난 조각이 있으면 아무것도 건드리지 않고 rc 2.
#   한 Issue 가 실패해도 나머지를 처리하고 처음 실패한 rc 를 돌려준다.
cmd_close_fr() {
  local detail="$1" url="" skip=0 gi tok list="" r rc=0 remote_rc=0 total=0 failed="" closed_list="" skipped_list="" reason hs
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --commit-url) need_val "$@" || return 2; url="$2"; shift 2 ;;
      --skip-closed) skip=1; shift ;;
      *) shift ;;
    esac
  done
  [ -n "$url" ] || { die "사용법: close-fr <detail> --commit-url <URL> [--skip-closed]"; return 2; }
  CLOSE_SKIP="$skip"
  # 이 FR 의 stem 목록(`stem|stem`): 상세 파일 이름과 상세 첫 줄(`# YYYY-MM-DD 이름` → `YYYY-MM-DD-이름`, fr/add.md 형식).
  #   발행(archive.sh)은 상세를 임시 파일로 넘기므로 파일 이름만으로는 FR 을 알 수 없다.
  CLOSE_STEM="$(basename "$detail" .md)"
  hs="$(sed -n '1s/^# \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\) \([^ ][^ ]*\)[ \r]*$/\1-\2/p' "$detail" 2>/dev/null)" || hs=""
  [ -n "$hs" ] && CLOSE_STEM="$CLOSE_STEM|$hs"
  gi="$(read_issue_value "$detail")" || { die "FR 상세를 읽을 수 없습니다: $detail"; return 2; }
  if [ -z "$gi" ] || [ "$gi" = "-" ]; then return 0; fi
  parse_issue_refs "$gi" || return 2
  list="$ISSUE_REFS"
  mk_tmp
  while IFS= read -r tok; do
    total=$((total+1))
    close_one "${tok%#*}" "${tok##*#}" "$url" "$skip" 2>"$TMPD/close.err"; r=$?
    cat "$TMPD/close.err" >&2
    case "$CLOSE_RESULT" in
      skipped) skipped_list="${skipped_list:+$skipped_list, }$tok" ;;
      closed) closed_list="${closed_list:+$closed_list, }$tok" ;;
    esac
    if [ "$r" -ne 0 ]; then
      [ "$rc" -eq 0 ] && rc=$r
      [ "$r" -ne 10 ] && [ "$remote_rc" -eq 0 ] && remote_rc=$r
      reason="$(awk 'NF{l=$0} END{print l}' "$TMPD/close.err")"
      case "$reason" in "Issue 를 닫지 못했습니다"*) reason="$reason (댓글은 달렸습니다)" ;; esac
      # 장부 정리 실패처럼 사유에 Issue 가 없으면 앞에 붙인다.
      case "$reason" in *"$tok"*) ;; *) reason="$tok: ${reason:-실패 (rc $r)}" ;; esac
      failed="${failed:+$failed; }${reason:-$tok 실패 (rc $r)}"
    fi
  done <<EOF
$list
EOF
  # Issue 가 여럿이면 마지막 줄을 요약으로 둔다 — archive.sh 는 실패 때 마지막 줄만 보여 준다.
  # 원격 실패가 없고 장부 정리만 실패했으면 rc 10 — 복구는 Issue 마다의 forget 이고 close-fr 재실행이 아니다.
  if [ "$rc" -ne 0 ] && [ "$total" -gt 1 ]; then
    if [ "$remote_rc" -eq 0 ]; then
      die "Issue ${total}건 중 장부 정리 실패: $failed / 닫음: ${closed_list:-없음} / 이미 닫혀 건너뜀: ${skipped_list:-없음} — 원격 처리는 끝났습니다. 장부는 위 forget 명령으로 정리하십시오"
    else
      die "Issue ${total}건 중 실패: $failed / 닫음: ${closed_list:-없음} / 이미 닫혀 건너뜀: ${skipped_list:-없음} — --skip-closed 로 재실행하면 닫힌 Issue 는 건너뜁니다"
    fi
  fi
  [ "$remote_rc" -ne 0 ] && return "$remote_rc"
  return "$rc"
}

cmd_commit_url() {
  local sha="$1" dir u r
  need_root; dir="$ROOT"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in --dir) need_val "$@" || return 2; dir="$2"; shift 2 ;; *) shift ;; esac
  done
  u="$(git -C "$dir" remote get-url origin 2>/dev/null)" || { die "origin 을 읽을 수 없습니다: $dir"; return 3; }
  r="$(remote_to_repo "$u")" || { die "origin URL 을 해석할 수 없습니다: $u"; return 3; }
  case "$r" in
    */*/*) printf 'https://%s/commit/%s\n' "$r" "$sha" ;;
    *) printf 'https://github.com/%s/commit/%s\n' "$r" "$sha" ;;
  esac
}

# ---- produce ----
cmd_produce() {
  local repo="" label="" fp="" title="" bodyfile="" out best state reason num url marker newbody prev="" created c elabel
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) need_val "$@" || return 2; repo="$2"; shift 2 ;;
      --label) need_val "$@" || return 2; label="$2"; shift 2 ;;
      --fingerprint) need_val "$@" || return 2; fp="$2"; shift 2 ;;
      --title) need_val "$@" || return 2; title="$2"; shift 2 ;;
      --body-file) need_val "$@" || return 2; bodyfile="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$label" ] && [ -n "$fp" ] && [ -n "$title" ] && [ -f "$bodyfile" ] || { die "사용법: produce --repo R --label L --fingerprint F --title T --body-file B"; return 2; }
  marker="<!-- fingerprint: $fp -->"
  split_repo "$repo"
  elabel="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$label")"
  out="$(gh_api "$RHOST" --paginate "repos/$RSLUG/issues?labels=$elabel&state=all&per_page=100")" || { die "라벨 Issue 조회 실패: $repo"; return 7; }
  best="$(printf '%s' "$out" | python3 -I -c "$PYDEC"'
marker = sys.argv[1]
import re
tail_fp = lambda b: (re.search(r"<!-- fingerprint: (.*?) -->\s*\Z", b or "") or [None, None])[1]
c = [x for x in read_items(sys.stdin.read()) if isinstance(x, dict) and "pull_request" not in x and tail_fp(x.get("body")) == marker]
if c:
    x = max(c, key=lambda x: (x.get("state") == "open", x.get("number", 0)))
    print("%s\t%s\t%s\t%s" % (x.get("state", ""), x.get("state_reason") or "null", x.get("number"), x.get("html_url", "")))
' "$fp")" || { die "라벨 Issue 응답을 읽지 못했습니다: $repo"; return 7; }
  if [ -n "$best" ]; then
    IFS=$'\t' read -r state reason num url <<EOF
$best
EOF
    if [ "$state" = open ]; then
      "$GH" issue comment "$num" --repo "$repo" --body-file "$bodyfile" >/dev/null || { die "댓글 실패: $url"; return 7; }
      printf 'commented %s\n' "$url"; return 0
    fi
    if [ "$reason" = not_planned ]; then printf 'skipped %s\n' "$url"; return 0; fi
    prev="$url"
  fi
  mk_tmp
  newbody="$TMPD/body.md"
  { cat "$bodyfile"; printf '\n'; [ -n "$prev" ] && printf '이전 Issue: %s\n\n' "$prev"; printf '%s\n' "$marker"; } > "$newbody"
  if ! created="$("$GH" issue create --repo "$repo" --title "$title" --body-file "$newbody" --label "$label")"; then
    "$GH" label create "$label" --repo "$repo" >/dev/null 2>&1 || { die "라벨을 만들지 못해 Issue 를 만들지 않았습니다: $label"; return 7; }
    created="$("$GH" issue create --repo "$repo" --title "$title" --body-file "$newbody" --label "$label")" || { die "Issue 생성 실패: $repo"; return 7; }
  fi
  c="$(printf '%s\n' "$created" | tail -1)"
  if [ -n "$prev" ]; then printf 'created %s (이전: %s)\n' "$c" "$prev"; else printf 'created %s\n' "$c"; fi
}

# ---- main ----
sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  repos) cmd_repos "$@" ;;
  has-team-queue) cmd_has_team_queue ;;
  list) cmd_list ;;
  claim) cmd_claim "${1:-}" "${2:-}" ;;
  link) cmd_link "${1:-}" "${2:-}" "${3:-}" ;;
  release) cmd_release "${1:-}" "${2:-}" ;;
  forget) cmd_forget "${1:-}" "${2:-}" ;;
  release-fr) cmd_release_fr "${1:-}" ;;
  stale) cmd_stale ;;
  close-fr) cmd_close_fr "${1:-}" "${@:2}" ;;
  issue-refs) cmd_issue_refs "${1:-}" "${2:-}" ;;
  commit-url) cmd_commit_url "${1:-}" "${@:2}" ;;
  produce) cmd_produce "$@" ;;
  *) die "사용법: issue_queue.sh <repos|has-team-queue|list|claim|link|release|forget|release-fr|stale|close-fr|issue-refs|commit-url|produce> ..."; exit 2 ;;
esac
exit $?
