#!/usr/bin/env bash
# _fr_status.sh — FR 상세 파일의 status 판정 규칙 정본 (source 전용).
#
# 판정 규칙(정본): 값이 비어 있지 않은 첫 `- status:` 줄의 첫 토큰을 쓴다.
# 그런 줄이 없으면 `- 상태:` 에서 같은 규칙으로 보충한다.
# 허용값 7개 밖의 값과 빈 값은 비표준이다.
#
# 값은 키 뒤 문자열의 앞뒤 공백·탭·CR 을 지운 것이고, 첫 토큰은 첫 공백·탭 앞까지다.
# 키는 줄 맨 앞의 `- status:` / `- 상태:` 만 인정한다.
#
# 사용:
#   source ".../_fr_status.sh"          # 호출자가 경로를 정한다. 이 파일은 자기 위치를 쓰지 않는다.
#   fr_status_class <값>                 # FR_STATUS_CLASS = active|inactive|nonstandard
#   fr_status_scan <파일>...             # 파일당 `<판독코드>\034<값>\034<분류>`, 끝에 `#N\034<파일 수>`
#   fr_status_awk_vars                   # FR_STATUS_AWK_ARGS 채움
#   awk "${FR_STATUS_AWK_ARGS[@]}" "$FR_STATUS_AWK"'BEGIN{frs_init()} ...'
#
# awk 함수: frs_init() frs_reset() frs_feed(line, lineno) frs_value() frs_status_line()
#   frs_src_line() frs_src_raw() frs_has_key() frs_class(v)
# 전역 이름은 FR_STATUS_ / frs_ / fr_status_ 접두만 쓴다.
# bash 3.2·BSD awk 에서 동작한다 (연관배열·gensub·\s 없음).

FR_STATUS_ACTIVE="idea validated ready-for-request blocked"
FR_STATUS_INACTIVE="done dropped parked"

FR_STATUS_AWK='
function frs_trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function frs_tok1(s) { s = frs_trim(s); if (match(s, /[ \t]/)) s = substr(s, 1, RSTART - 1); return s }
function frs_init(  n, i) {
  frs_na = split(frs_act, frs_a, " ")
  frs_ni = split(frs_inact, frs_i, " ")
}
function frs_reset() {
  frs_sv = ""; frs_sn = 0; frs_stn = 0
  frs_lv = ""; frs_ln = 0
  frs_key = 0
}
function frs_feed(line, lineno,  v) {
  if (index(line, "- status:") == 1) {
    frs_key = 1
    if (frs_stn == 0) frs_stn = lineno
    if (frs_sv == "") {
      v = frs_trim(substr(line, index(line, ":") + 1))
      if (v != "") { frs_sv = v; frs_sn = lineno }
    }
    return 1
  }
  if (index(line, "- 상태:") == 1) {
    frs_key = 1
    if (frs_lv == "") {
      v = frs_trim(substr(line, index(line, ":") + 1))
      if (v != "") { frs_lv = v; frs_ln = lineno }
    }
    return 1
  }
  return 0
}
function frs_src_raw() { return (frs_sv != "" ? frs_sv : frs_lv) }
function frs_value() { return frs_tok1(frs_src_raw()) }
function frs_status_line() { return frs_stn }
function frs_src_line() { return (frs_sv != "" ? frs_sn : (frs_lv != "" ? frs_ln : 0)) }
function frs_has_key() { return frs_key }
function frs_class(v,  k) {
  if (v == "") return "nonstandard"
  for (k = 1; k <= frs_na; k++) if (frs_a[k] == v) return "active"
  for (k = 1; k <= frs_ni; k++) if (frs_i[k] == v) return "inactive"
  return "nonstandard"
}
'

fr_status_awk_vars() {
  FR_STATUS_AWK_ARGS=(-v "frs_act=${FR_STATUS_ACTIVE}" -v "frs_inact=${FR_STATUS_INACTIVE}")
}

fr_status_class() {
  local v="$1" w
  FR_STATUS_CLASS="nonstandard"
  [ -n "$v" ] || return 0
  for w in $FR_STATUS_ACTIVE; do
    if [ "$w" = "$v" ]; then FR_STATUS_CLASS="active"; return 0; fi
  done
  for w in $FR_STATUS_INACTIVE; do
    if [ "$w" = "$v" ]; then FR_STATUS_CLASS="inactive"; return 0; fi
  done
  return 0
}

fr_status_scan() {
  local f i=0 bad=" "
  for f in "$@"; do
    i=$((i + 1))
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then bad="${bad}${i} "; fi
  done
  fr_status_awk_vars
  awk "${FR_STATUS_AWK_ARGS[@]}" -v "frs_bad=${bad}" "$FR_STATUS_AWK"'
    BEGIN {
      frs_init()
      for (n = 1; n < ARGC; n++) {
        f = ARGV[n]
        if (index(frs_bad, " " n " ") > 0) { printf "2\034\034nonstandard\n"; continue }
        frs_reset(); ln = 0
        while ((r = (getline line < f)) > 0) { ln++; frs_feed(line, ln) }
        close(f)
        if (r < 0) { printf "2\034\034nonstandard\n"; continue }
        v = frs_value()
        printf "%d\034%s\034%s\n", (frs_src_raw() == "" ? 1 : 0), v, frs_class(v)
      }
      printf "#N\034%d\n", ARGC - 1
      exit 0
    }' "$@"
}
