# 실행 위치의 git commit 호출을 판정한다.
# 입력 : 명령 문자열 전체 (RS=\001 로 단일 레코드), -v start_dir=<abs>
# 출력 : 1행  gate=<0|1> uncertain=<0|1> ncand=<N>
#        2..N+1행  <차단 후보 커밋의 실행 위치 절대경로>
#   gate=0      -> 커밋이 없거나 발견된 모든 커밋에 유효 bypass 가 붙음 -> 통과
#   uncertain=1 -> 차단 후보 중 실행 위치를 확정할 수 없는 것이 있음 -> 무조건 판정
#   ncand 줄    -> 위치가 확정된 차단 후보들. 호출측이 각각 프로젝트 밖인지 검사해
#                  **전부 밖일 때만** 판정을 생략한다 (하나라도 안이면 판정)
# 명령 하나에 커밋이 여러 개일 수 있으므로 첫 커밋에서 멈추지 않고 끝까지 집계한다.
# 첫 커밋만 보면 `git -C <밖> commit; git commit` 의 두 번째 커밋이 통과해버린다.
# 종료 : 0 판정 성공 / 2 판정 불가(호출측이 현행 문자열 판정으로 폴백)
#
# 전략: 데이터 구간을 **길이를 보존한** 플레이스홀더로 치환해 판정용 문자열을 만든다.
# 길이가 같으므로 값이 필요한 워드(cd 인자, git -C 인자)는 같은 위치의 원본에서 되찾는다.
#
# 구간 분류 (기준: 셸이 그 구간에서 명령 치환을 실제로 수행하는가)
#   LITERAL   '...'  <<'EOF' 본문  <<<'word'  # 주석      -> 전체 데이터
#   EXPANDING "..."  <<EOF 본문    <<<word              -> 데이터이나 $( ) 와 ` ` 는 실행 위치

# 플레이스홀더 k 개. 문자 루프 대신 사전 생성 버퍼를 잘라 쓴다 (O(n^2) 회피).
function fill(k) {
  if (k <= 0) return ""
  while (length(PHBUF) < k) PHBUF = PHBUF PHBUF
  return substr(PHBUF, 1, k)
}

# 출력 누적. 문자마다 masked 를 재할당하면 O(n^2) 이므로 버퍼에 모아 flush 한다.
function emit(t) { buf = buf t; if (length(buf) >= 4096) { masked = masked buf; buf = "" } }

# from 이후 첫 개행 위치. substr(s, from) 로 남은 전체를 복사하면 줄마다 O(n) 이므로 1글자씩 본다.
function next_nl(from,   t) {
  for (t = from; t <= n; t++) if (substr(raw, t, 1) == "\n") return t
  return 0
}

function normpath(p,   parts, i, k, seg, out, nseg, r) {
  gsub(/\/+/, "/", p)
  k = split(p, parts, "/"); nseg = 0
  for (i = 1; i <= k; i++) {
    seg = parts[i]
    if (seg == "" || seg == ".") continue
    if (seg == "..") { if (nseg > 0) nseg--; continue }
    out[++nseg] = seg
  }
  r = ""
  for (i = 1; i <= nseg; i++) r = r "/" out[i]
  return (r == "" ? "/" : r)
}

# heredoc 델리미터의 quote removal. **인용이 하나라도 있으면 body 는 LITERAL** 이다.
# 홑따옴표 안의 백슬래시는 리터럴이고(`<<'E\OF'` 의 델리미터는 `E\OF`), 인용 밖 백슬래시는
# 제거되며(`<<\EOF` -> `EOF`), `$'…'` 는 ANSI-C 로 해석된다(`<<$'EOF'` -> `EOF`).
# 문맥 구분 없이 백슬래시를 지우면 종료 줄과 어긋나 rc=2 로 떨어지고, 폴백의 legacy 글롭이
# body 를 실제 커밋으로 오탐해 **오탐 해소가 깨진다**(실측 재현).
# 인용 여부는 전역 HD_LIT 에 남긴다.
function hd_unquote(w,   i, n, c, nx, out, seg, v) {
  n = length(w); out = ""; HD_LIT = 0
  for (i = 1; i <= n; i++) {
    c = substr(w, i, 1)
    if (c == "'") {
      HD_LIT = 1
      for (i++; i <= n; i++) { c = substr(w, i, 1); if (c == "'") break; out = out c }
      continue
    }
    if (c == "\"") {
      HD_LIT = 1
      for (i++; i <= n; i++) {
        c = substr(w, i, 1)
        if (c == "\"") break
        if (c == "\\") {
          nx = substr(w, i + 1, 1)
          if (nx == "$" || nx == "`" || nx == "\"" || nx == "\\") { i++; out = out nx; continue }
        }
        out = out c
      }
      continue
    }
    if (c == "$" && substr(w, i + 1, 1) == "'") {
      HD_LIT = 1; i += 2; seg = ""
      while (i <= n) {
        c = substr(w, i, 1)
        if (c == "'") break
        if (c == "\\") { seg = seg c; i++; if (i <= n) { seg = seg substr(w, i, 1); i++ }; continue }
        seg = seg c; i++
      }
      out = out ansi_c(seg)
      continue
    }
    if (c == "\\") { HD_LIT = 1; i++; if (i <= n) out = out substr(w, i, 1); continue }
    out = out c
  }
  return out
}

# $'…' 안의 ANSI-C escape 를 bash 3.2 규칙으로 복원한다. 토큰화 단계의 **정적 변환**이므로
# 런타임 결정이 아니다.
# **NUL 은 "표현 불가" 가 아니라 truncation 이다** — bash 3.2 는 ANSI-C 세그먼트를 NUL 앞에서
# 자르고 같은 워드의 바깥 suffix 는 계속 결합한다(실측: `$'commit\0ignored'` → `commit`,
# `$'com\0x'mit` → `commit`, `\x00`·`\c@` 동일). 값을 버리면 실제 커밋을 놓치고,
# 값 안에 표식을 실으면 같은 byte 의 정상 문자와 구분되지 않는다(둘 다 실측으로 확인된 결함).
# 따라서 NUL 을 만나면 **그 앞까지 반환**한다.
function ansi_c(s,   i, n, c, nx, out, v, d, cnt) {
  n = length(s); out = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\\") { out = out c; continue }
    i++; nx = substr(s, i, 1)
    if (nx == "n") out = out "\n"
    else if (nx == "t") out = out "\t"
    else if (nx == "r") out = out "\r"
    else if (nx == "a") out = out sprintf("%c", 7)
    else if (nx == "b") out = out sprintf("%c", 8)
    else if (nx == "f") out = out sprintf("%c", 12)
    else if (nx == "v") out = out sprintf("%c", 11)
    else if (nx == "e" || nx == "E") out = out sprintf("%c", 27)
    else if (nx == "\\" || nx == "'" || nx == "\"" || nx == "?") out = out nx
    else if (nx == "c") {                      # \cX — control 문자
      # bash 3.2 규칙은 **하위 5비트**(c & 0x1F)다. 영문만 처리하면 `$'\c['`(=27)·
      # `$'\c?'`(=31) 같은 값을 문자 그대로 남겨 heredoc 델리미터를 다르게 기억한다
      # (실측: `[`→27, `?`→31, `A`→1, `_`→31 — 전부 c & 0x1F 와 일치).
      i++; c = substr(s, i, 1)
      if (c == "") { out = out "\\c"; continue }
      v = ORD[c] % 32
      if (v == 0) return out                   # \c@ = NUL -> 세그먼트를 여기서 자른다
      out = out sprintf("%c", v)
    }
    else if (nx == "x") {                      # \xHH — 최대 2자리
      v = 0; cnt = 0
      while (cnt < 2) {
        d = index("0123456789abcdef", tolower(substr(s, i + 1, 1)))
        if (d == 0) break
        v = v * 16 + (d - 1); i++; cnt++
      }
      if (cnt == 0) { out = out "x"; continue }
      if (v == 0) return out                   # NUL -> 세그먼트를 여기서 자른다
      out = out sprintf("%c", v)
    }
    else if (nx ~ /^[0-7]$/) {                 # \nnn / \0nnn — 최대 3자리 8진
      v = 0; cnt = 0
      while (cnt < 3) {
        d = substr(s, i, 1)
        if (d !~ /^[0-7]$/) break
        v = v * 8 + (d + 0); i++; cnt++
      }
      i--
      # **8-bit 로 정규화한 뒤 NUL 을 판정한다** — `\400` 은 256 이지만 byte 로는 NUL 이므로
      # bash 는 세그먼트를 여기서 자른다(실측: `$'commit\400ignored'` 의 argv 는 `commit`).
      # 정수 그대로 `v == 0` 만 보면 이 형태를 놓친다.
      v = v % 256
      if (v == 0) return out                   # NUL -> 세그먼트를 여기서 자른다
      out = out sprintf("%c", v)
    }
    # **알려지지 않은 escape 는 백슬래시를 보존한다** — bash 3.2 실측: $'com\mit' 의 argv 는
    # `com\mit` 이지 `commit` 이 아니다. 백슬래시를 지우면 실행되지도 않는 명령을 차단하는
    # 오탐이 된다(Turn 006 지적).
    else out = out "\\" nx
  }
  return out
}

# `env -S <string>` 전용 lexer. 결과는 ESW[1..ESN], 확장이 섞이면 ES_UNSURE=1.
# 단순 whitespace split 에 예외를 덧붙이면 규칙이 계속 어긋나므로(선행 구분자가 빈 워드를
# 만들어 미탐, 인용을 못 읽어 과탐 — 둘 다 실측) 문법을 직접 읽는다.
# 지원 플랫폼(macOS/FreeBSD env) 규칙 — 실측으로 확인한 것:
#   * 공백·탭과 `\_` 는 인자 구분자. **선행·후행·연속 구분자는 빈 인자를 만들지 않는다**
#     (`env -S ' git --version'`·`'\_git --version'`·`'git  --version'` 모두 git 을 실행).
#   * `'…'` 는 리터럴, `"…"` 는 escape 를 해석. 인용 안에서는 구분자가 아니다
#     (`env -S 'printf "git commit\n"'` 은 문자열을 출력할 뿐 git 을 실행하지 않는다).
#   * escape: `\_`(구분) `\t \n \v \f \r`(제어) `\\ \' \" \# \$`(리터럴) `\c`(이후 전부 버림)
#   * `$…` 확장은 값이 런타임 결정이므로 ES_UNSURE 로 올린다.
function env_s_lex(s,   i, n, c, nx, q, w, open) {
  ESN = 0; ES_UNSURE = 0; ES_BAD = 0; w = ""; open = 0; q = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "'") {
      if (c == "'") { q = ""; continue }
      w = w c; open = 1; continue
    }
    if (q == "\"") {
      if (c == "\"") { q = ""; continue }
      if (c == "\\") {
        nx = substr(s, i + 1, 1)
        if (nx == "\"" || nx == "\\" || nx == "$" || nx == "`") { i++; w = w nx; open = 1; continue }
        w = w c; open = 1; continue
      }
      if (c == "$") { ES_UNSURE = 1; return }   # 겹따옴표 안 확장
      w = w c; open = 1; continue
    }
    if (c == "'" || c == "\"") { q = c; open = 1; continue }
    if (c == " " || c == "\t") {
      if (open) { ESW[++ESN] = w; w = ""; open = 0 }
      continue
    }
    if (c == "\\") {
      nx = substr(s, i + 1, 1)
      if (nx == "_") { i++; if (open) { ESW[++ESN] = w; w = ""; open = 0 } continue }
      # `\c` 는 이후를 버리지만 **조립 중인 워드는 보존**한다
      # (실측: `env -S 'printf ok\cignored'` 가 `ok` 를 출력한다).
      if (nx == "c") { if (open) ESW[++ESN] = w; return }
      if (nx == "t") { i++; w = w "\t"; open = 1; continue }
      if (nx == "n") { i++; w = w "\n"; open = 1; continue }
      if (nx == "v") { i++; w = w sprintf("%c", 11); open = 1; continue }
      if (nx == "f") { i++; w = w sprintf("%c", 12); open = 1; continue }
      if (nx == "r") { i++; w = w "\r"; open = 1; continue }
      if (nx == "") { open = 1; continue }
      # macOS env 가 인정하는 escape 만 처리한다. 그 밖은 `Invalid sequence '\X' in -S` 로
      # **utility 실행 전에 종료**되므로 커밋이 아니다(실측: `env -S 'git com\mit'` → exit 1).
      if (nx != "\\" && nx != "'" && nx != "\"" && nx != "#" && nx != "$") { ES_BAD = 1; return }
      i++; w = w nx; open = 1; continue
    }
    if (c == "$") { ES_UNSURE = 1; return }
    # man page 규칙은 "새 인자가 # 로 시작하면" 이므로 **첫 워드에 한정되지 않는다**
    # (실측: `env -S 'printf # ignored' ok` 가 `ok` 를 출력한다 — # 뒤 split 문자열만 버려지고
    # 원래 argv 는 그대로 이어진다).
    if (c == "#" && !open) return              # 새 워드 위치의 # 는 주석
    w = w c; open = 1
  }
  if (q != "") { ES_UNSURE = 1; return }       # 닫히지 않은 인용
  if (open) ESW[++ESN] = w
}

# wrapper 별 short option 스펙과 cluster 파서.
# 지원 플랫폼(macOS) usage 기준:
#   env     [-0iv] [-C workdir] [-P utilpath] [-S string] [-u name]
#   exec    [-cl] [-a name]
#   time    [-al] [-h|-p] [-o file]
#   command [-pVv]
# short option 은 **묶어 쓸 수 있다** (`env -iC <dir>`·`exec -ca label`·`time -ao <file>` —
# 셋 다 실측으로 utility 를 실행한다). 독립 spelling 만 처리하면 그 형태가 통째로 미탐이 된다.
# 또한 **미지원 옵션은 wrapper 가 오류로 끝나 utility 를 실행하지 않는다**(`command -x git commit`
# 은 invalid option 으로 exit 2) — 이를 소비하고 커밋으로 세면 실행되지 않은 커밋을 차단하는
# 오탐이 된다.
#
# 반환: 0 정상 / 1 조회(실행 아님) / 2 미지원 옵션(실행 아님)
# 부수 출력: OPT_ARG(인자 소비 옵션 문자, "" = 없음), OPT_VAL(붙임 값), OPT_EAT(다음 워드 소비)
function parse_cluster(w, name,   i, n, c) {
  OPT_ARG = ""; OPT_VAL = ""; OPT_EAT = 0
  n = length(w)
  for (i = 2; i <= n; i++) {
    c = substr(w, i, 1)
    if (WQ[name] != "" && index(WQ[name], c) > 0) return 1
    if (WA[name] != "" && index(WA[name], c) > 0) {
      OPT_ARG = c
      if (i < n) OPT_VAL = substr(w, i + 1)
      else OPT_EAT = 1
      return 0
    }
    if (WF[name] != "" && index(WF[name], c) > 0) continue
    return 2
  }
  return 0
}

# 이미 복원된 값에 대한 경로 검사 — 확장 메타문자가 있으면 리터럴이 아니다.
function literal_path_val(v) {
  if (v == "" || v ~ /[$`*?\[~]/) return ""
  return v
}

# 원본 워드에서 인용·이스케이프를 제거해 **셸이 실제로 보는 워드 값**을 만든다.
# 'git' commit / g"it" commit / git com'mit' / g\it commit 은 quote removal 후 직접 호출이다.
# 확장($ 또는 backtick)이 섞이면 값이 런타임에 결정되므로 빈 문자열(불확정)을 반환한다.
function unquote(w,   c, i, n, out, q, nx, seg, v) {
  n = length(w); out = ""; q = ""
  for (i = 1; i <= n; i++) {
    c = substr(w, i, 1)
    if (q == "'") {                       # 홑따옴표 안 — 백슬래시도 리터럴
      if (c == "'") { q = ""; continue }
      out = out c; continue
    }
    if (c == "\\") {
      nx = substr(w, i + 1, 1)
      # `\<개행>` 은 line continuation — bash 가 토큰화 전에 **둘 다 제거**한다(워드가 이어진다).
      # 홑따옴표 안은 위에서 이미 리터럴로 처리되므로 여기 도달하지 않는다.
      if (nx == "\n") { i++; continue }
      if (q == "") { i++; if (nx != "") out = out nx; continue }   # 인용 밖 — 다음 문자 리터럴화
      # 겹따옴표 안 — $ ` " \ 앞에서만 이스케이프, 그 외는 백슬래시 유지
      if (nx == "$" || nx == "`" || nx == "\"" || nx == "\\") { i++; out = out nx; continue }
      out = out c; continue
    }
    if (q == "") {
      if (c == "'" || c == "\"") { q = c; continue }
      # $'...' 는 ANSI-C 인용이다. `git $'commit'` 은 quote removal 후 직접 호출이며
      # 런타임 결정이 아니라 **정적 lexical rule** 이므로 AC3b 의 차단 대상이다.
      # escape 도 정적 변환이므로 ansi_c() 로 복원한다. rc=2 폴백으로 보내면 hook 종단에서
      # 1단 필터(백슬래시 단순 제거)와 legacy 글롭이 모두 통과시켜 **차단이 뚫린다**
      # (`git $'com\x6dit'` 실측 — bash argv 는 [commit]).
      if (c == "$" && substr(w, i + 1, 1) == "'") {
        i += 2; seg = ""
        while (i <= n) {
          c = substr(w, i, 1)
          if (c == "'") break
          if (c == "\\") { seg = seg c; i++; if (i <= n) { seg = seg substr(w, i, 1); i++ }; continue }
          seg = seg c; i++
        }
        if (i > n) return ""                 # 닫히지 않음 -> 값 확정 불가
        out = out ansi_c(seg)                # NUL 이 있으면 그 앞까지만 값에 들어간다
        continue                             # i 는 닫는 ' — for 의 i++ 가 다음으로 옮긴다
      }
      if (c == "$" || c == "`") return ""
      out = out c; continue
    }
    if (c == q) { q = ""; continue }       # q == "\""
    if (c == "$" || c == "`") return ""
    out = out c
  }
  if (q != "") return ""
  return out
}

# 원본 워드에서 리터럴 경로를 복원한다. 확장이 섞이면 빈 문자열.
function literal_path(w,   c, i, n, out, q, nx) {
  n = length(w); out = ""; q = ""
  for (i = 1; i <= n; i++) {
    c = substr(w, i, 1)
    if (q == "'") { if (c == "'") { q = ""; continue } out = out c; continue }
    if (c == "\\") {
      nx = substr(w, i + 1, 1)
      if (nx == "\n") { i++; continue }   # line continuation — 둘 다 제거
      if (q == "") { i++; if (nx != "") out = out nx; continue }
      if (nx == "$" || nx == "`" || nx == "\"" || nx == "\\") { i++; out = out nx; continue }
      out = out c; continue
    }
    if (q == "") {
      if (c == "'" || c == "\"") { q = c; continue }
      if (c == "$" || c == "`" || c == "*" || c == "?" || c == "[" || c == "~") return ""
      out = out c; continue
    }
    if (c == q) { q = ""; continue }
    if (c == "$" || c == "`") return ""
    out = out c
  }
  if (q != "") return ""
  return out
}

BEGIN {
  RS = "\001"; PH = sprintf("%c", 4)
  PHBUF = PH; while (length(PHBUF) < 1024) PHBUF = PHBUF PHBUF
  # 문자 -> 코드 테이블 (awk 에 ord() 가 없다). ANSI-C `\cX` 복원에 쓴다.
  for (_i = 1; _i < 128; _i++) ORD[sprintf("%c", _i)] = _i
  # wrapper short option: WF = 인자 없는 플래그, WA = 인자 소비, WQ = 조회(실행 아님)
  WF["env"] = "0iv";    WA["env"] = "CPSu";  WQ["env"] = ""
  WF["exec"] = "cl";    WA["exec"] = "a";    WQ["exec"] = ""
  WF["time"] = "alhp";  WA["time"] = "o";    WQ["time"] = ""   # /usr/bin/time
  WF["shtime"] = "p";   WA["shtime"] = "";   WQ["shtime"] = ""  # 셸 예약어 time
  WF["command"] = "p";  WA["command"] = "";  WQ["command"] = "vV"
}

{
  raw = $0
  n = length(raw)
  masked = ""; buf = ""
  st = "N"; sp = 0; cs = 0; bt = 0; pend = ""; pend_on = 0; pend_lit = 0; pend_dash = 0; hd_d = ""; hd_lit = 0; hd_dash = 0
  bol = 1                                   # 줄 시작 여부

  for (i = 1; i <= n; i++) {
    c = substr(raw, i, 1)

    # ---- heredoc 본문: 줄 시작에서 델리미터 판정 ----
    if ((st == "H" || st == "L") && bol) {
      j = next_nl(i); if (j > 0) j = j - i + 1
      if (j == 0) { seg = substr(raw, i); nl = 0 } else { seg = substr(raw, i, j - 1); nl = 1 }
      # bash 의미: <<EOF 는 줄 전문 정확 일치, <<-EOF 는 **선행 탭만** 제거 후 일치.
      # 앞뒤 공백을 모두 걷어내면 quoted heredoc 안의 " EOF" 를 종료로 오인해
      # 이후 데이터의 커밋 문자열이 실행 위치로 보인다 (오탐 재발).
      if (hd_dash) { w = seg; sub(/^\t+/, "", w) } else { w = seg }
      if (w == hd_d) {                       # 델리미터 줄 -> heredoc 종료
        emit(fill(length(seg)))
        if (nl) { emit("\n"); i = i + j - 1 } else { i = n }
        st = "N"; bol = 1
        continue
      }
      if (st == "L") {                       # LITERAL 본문 -> 줄 전체 데이터
        emit(fill(length(seg)))
        if (nl) { emit("\n"); i = i + j - 1 } else { i = n }
        bol = 1
        continue
      }
      # EXPANDING 본문이라도 그 줄에 명령 치환이 없으면 줄 전체가 데이터다 -> 청크 처리.
      # (문자마다 함수 호출하면 20KB 입력에서 100ms 를 넘는다)
      if (index(seg, "$(") == 0 && index(seg, "`") == 0) {
        emit(fill(length(seg)))
        if (nl) { emit("\n"); i = i + j - 1 } else { i = n }
        bol = 1
        continue
      }
      bol = 0                                # 치환이 있는 줄만 문자 단위로 계속
    }

    if (st == "S") {                         # '...' — 전부 데이터
      if (c == "'") st = (sp > 0 ? stack[sp--] : "N")
      emit(PH); bol = 0; continue
    }

    if (c == "\\") {                         # 이스케이프 — 두 글자 중성화
      emit(PH); if (i < n) { emit(PH); i++ }
      bol = 0; continue
    }

    if (st == "D" || st == "H") {            # EXPANDING — 데이터이나 $( 와 ` 는 실행 위치
      if (st == "D" && c == "\"") { st = (sp > 0 ? stack[sp--] : "N"); emit(PH); bol = 0; continue }
      if (c == "$" && substr(raw, i + 1, 1) == "(") { stack[++sp] = st; st = "N"; cs++; emit("(;"); i++; bol = 0; continue }
      if (c == "`") { stack[++sp] = st; st = "N"; bt++; emit("("); bol = 0; continue }
      if (c == "\n") { emit("\n"); bol = 1; continue }   # pend 는 남겨 둔다 -> 미해소 시 rc=2 폴백
      emit(PH); bol = 0; continue
    }

    # ---- st == "N" : 실행 위치 ----
    if (c == "'") { stack[++sp] = "N"; st = "S"; emit(PH); bol = 0; continue }
    if (c == "\"") { stack[++sp] = "N"; st = "D"; emit(PH); bol = 0; continue }
    if (c == "`") { if (bt > 0) { bt--; if (sp > 0) st = stack[sp--]; emit(")") } else { bt++; emit("(") } bol = 0; continue }
    if (c == "$" && substr(raw, i + 1, 1) == "(") { cs++; emit("(;"); i++; bol = 0; continue }
    if (c == ")" && cs > 0) { cs--; if (sp > 0) st = stack[sp--]; emit(")"); bol = 0; continue }

    if (c == "#" && bol_word()) {             # 워드 시작 위치의 # 만 주석
      j = next_nl(i); if (j > 0) j = j - i + 1
      if (j == 0) { emit(fill(n - i + 1)); i = n }
      else { emit(fill(j - 1) "\n"); i = i + j - 1; bol = 1 }
      continue
    }

    if (c == "<" && substr(raw, i + 1, 1) == "<") {
      if (cs > 0) { print "gate=0 uncertain=0 ncand=0"; exit 2 }   # 명령 치환 안의 heredoc — 규칙 밖
      if (substr(raw, i + 2, 1) == "<") {                          # <<< here-string
        # 연산자 3글자만 중성화하고 피연산자는 일반 인용 규칙에 맡긴다.
        #   <<<'…'  -> 홑따옴표 규칙이 LITERAL 로 처리
        #   <<<"…"  -> 겹따옴표 규칙이 EXPANDING 으로 처리
        #   <<<word -> unquoted 이므로 내부 $( ) 가 실행 위치로 처리
        # 피연산자는 항상 명령 뒤에 오므로 서브커맨드의 첫 워드가 되지 않는다.
        emit(fill(3)); i += 2; bol = 0; continue
      }
      # heredoc 델리미터 파싱
      j = i + 2; emit(fill(2)); dash = 0
      if (substr(raw, j, 1) == "-") { emit(PH); j++; dash = 1 }
      while (j <= n && substr(raw, j, 1) ~ /[ \t]/) { emit(PH); j++ }
      # 복수 heredoc(`cat <<EOF <<'Q'`)은 pending 을 단일 변수로 보관하면 뒤 것이 앞 것을
      # 덮어써, 실제로 확장되는 첫 body 를 LITERAL 로 오판한다. queue 대신 폴백으로 보낸다.
      if (pend_on) { print "gate=0 uncertain=0 ncand=0"; exit 2 }
      # 델리미터 워드 추출 — **인용 안에서는 공백·연산자도 델리미터의 일부**다(`<<'A B'`).
      # 인용 상태를 추적하며 워드 끝을 찾고, 값 복원은 hd_unquote 가 문맥별로 처리한다.
      ds = j; dq = ""
      while (j <= n) {
        c2 = substr(raw, j, 1)
        if (dq == "'") { if (c2 == "'") dq = "" }
        else if (dq == "\"") {
          if (c2 == "\\") { emit(PH); j++; if (j <= n) { emit(PH); j++ }; continue }
          if (c2 == "\"") dq = ""
        }
        else {
          if (c2 ~ /[ \t\n;&|<>()]/) break
          if (c2 == "'" || c2 == "\"") dq = c2
          else if (c2 == "\\") { emit(PH); j++; if (j <= n) { emit(PH); j++ }; continue }
        }
        emit(PH); j++
      }
      if (dq != "") { print "gate=0 uncertain=0 ncand=0"; exit 2 }   # 닫히지 않은 델리미터
      hd_tmp = hd_unquote(substr(raw, ds, j - ds)); lit = HD_LIT
      # 빈 델리미터(`<<''`)는 "pending 없음"과 구분해야 한다. 같은 빈 문자열로 표현하면
      # heredoc 이 시작되지 않은 것으로 보여 **body 가 실행 구간으로 판정된다**(실측 오탐).
      i = j - 1; pend = hd_tmp; pend_on = 1; pend_lit = lit; pend_dash = dash
      bol = 0; continue
    }

    if (c == "\n") {
      emit("\n"); bol = 1
      if (pend_on) { hd_d = pend; hd_lit = pend_lit; hd_dash = pend_dash; pend = ""; pend_on = 0; st = (hd_lit ? "L" : "H") }
      continue
    }

    emit(c)
    bol = (c == " " || c == "\t") ? bol : 0
  }

  masked = masked buf; buf = ""          # 남은 버퍼 flush (판정은 masked 를 substr 로 읽는다)

  # 닫히지 않은 인용·치환, 길이 불변식 위반 -> 판정 불가.
  # **heredoc 이 종료 델리미터 없이 EOF 로 끝나는 것은 bash 에서 정상**이다(실측: exit 0,
  # body 는 그대로 데이터). 이를 rc=2 로 보내면 폴백의 legacy 글롭이 body 의 커밋 문자열을
  # 오탐해 이 작업의 1순위 목표인 오탐 해소가 깨진다(Turn 006 지적). 따라서 st/pend_on 은
  # 판정 불가 조건에서 제외한다 — 그 시점까지의 body 는 이미 데이터로 마스킹돼 있다.
  if (sp > 0 || cs > 0 || bt > 0 || length(masked) != n) {
    print "gate=0 uncertain=0 ncand=0"; exit 2
  }

  # ---- 서브커맨드 분해 + 판정 ----
  cwd = start_dir; uncertain = 0; repo_unc = 0; NC = 0
  ss = 1; depth = 0
  for (i = 1; i <= n + 1; i++) {
    c = (i <= n ? substr(masked, i, 1) : ";")
    if (c != ";" && c != "&" && c != "|" && c != "(" && c != ")" && c != "{" && c != "}" && c != "\n") continue

    # 경계 종류 판별 (cd 신뢰 규칙: && 만 신뢰)
    op = c
    if ((c == "&" || c == "|") && substr(masked, i + 1, 1) == c) op = c c

    if (i > ss) judge(ss, i - 1, op)

    # subshell 은 cwd 뿐 아니라 환경 대입도 격리한다 — `( export GIT_DIR=… )` 는 바깥
    # 커밋의 실행 repo 를 바꾸지 못하므로 repo_unc 도 함께 저장·복원한다.
    if (c == "(") { depth++; saved[depth] = cwd; saved_u[depth] = uncertain; saved_r[depth] = repo_unc }
    else if (c == ")" && depth > 0) { cwd = saved[depth]; uncertain = saved_u[depth]; repo_unc = saved_r[depth]; depth-- }

    ss = i + length(op)
    i = ss - 1
  }

  # 집계: 유효 bypass 가 붙은 커밋은 면제되고, 나머지가 차단 후보다.
  gate = 0; unc = 0; ncand = 0
  for (i = 1; i <= NC; i++) {
    if (CB[i]) continue
    gate = 1
    if (CT[i] == "?") unc = 1
    else { ncand++; CAND[ncand] = CT[i] }
  }
  printf "gate=%d uncertain=%d ncand=%d\n", gate, unc, ncand
  for (i = 1; i <= ncand; i++) print CAND[i]
  exit 0
}

# 직전 마스킹 문자가 워드 경계인지 (주석 판정용)
function bol_word(   p) {
  if (length(buf) > 0) p = substr(buf, length(buf), 1)
  else if (length(masked) > 0) p = substr(masked, length(masked), 1)
  else return 1
  return (p == " " || p == "\t" || p == "\n" || p == ";")
}

# 서브커맨드 [a,b] 판정. op = 이 서브커맨드 뒤에 오는 제어 연산자.
function judge(a, b, op,   i, c, ws, we, nw, k, cmd0, gdir, gunc, gabs, genv, lb, p, edir, eunc, ew, ov, ep, eat, rc2, sv, tname, ext_wrap, esn1) {
  # MW/RW/UW 는 전역 배열이지만 매 호출에서 1..nw 를 전부 덮어쓰므로 잔류 영향이 없다.
  nw = 0; i = a; split_unsure = 0
  while (i <= b) {
    c = substr(masked, i, 1)
    if (c == " " || c == "\t") { i++; continue }
    ws = i
    while (i <= b) { c = substr(masked, i, 1); if (c == " " || c == "\t") break; i++ }
    we = i - 1
    nw++; MW[nw] = substr(masked, ws, we - ws + 1); RW[nw] = substr(raw, ws, we - ws + 1)
  }
  if (nw == 0) return 0

  # 워드 값 복원(unquote)은 **필요한 워드에만** 수행한다. 전 워드를 미리 복원하면
  # 20KB 입력에서 호출이 폭증한다 (대부분의 서브커맨드는 git 이 아니므로 첫 워드로 끝난다).

  # 명령명 앞에 올 수 있는 것들을 순서 무관하게 걷어낸다. 모두 **정적 lexical** 이므로
  # 미탐 범위(런타임 결정·간접 호출)가 아니다 — `command git commit`·`exec git commit`·
  # `env -i git commit`·`if git commit; then`·`>/tmp/log git commit` 은 전부 실제 커밋이다.
  k = 1; lb = 0; genv = 0
  while (k <= nw) {
    # (a) 선행 redirection — 명령명이 아니다. 연산자만 있는 워드면 대상 워드도 함께 건너뛴다.
    if (MW[k] ~ /^([0-9]*|&)(>>?\|?|<<?|<>|>&|<&)/) {
      if (MW[k] ~ /^([0-9]*|&)(>>?\|?|<<?|<>|>&|<&)$/) k++
      k++; continue
    }
    # (b) env 와 그 옵션. 뒤따르는 VAR=val 은 (c) 가 처리한다.
    #     식별·옵션 판정 모두 **quote removal 기준**이다 (셸은 옵션의 따옴표도 제거한다).
    #     short option cluster·미지원 옵션 판정은 parse_cluster 가 담당한다.
    ew = unquote(RW[k]); sub(/^.*\//, "", ew)
    if (ew == "env") {
      ext_wrap = 1        # env 뒤의 명령은 PATH 에서 찾은 외부 utility 다 (예약어가 아니다)
      k++
      while (k <= nw) {
        ov = unquote(RW[k])
        if (ov == "" || ov !~ /^-/ || ov == "-") break
        if (ov == "--") { k++; break }
        ep = "\001"; sv = "\001"          # 이번 옵션이 만든 값 (미설정 표시)
        if (ov ~ /^--/) {
          # long option 은 이름이 정확해야 한다. 미지원이면 env 가 오류로 끝나 utility 를
          # 실행하지 않으므로 커밋으로 세지 않는다.
          if (ov ~ /^--chdir=/)             { ep = literal_path_val(substr(ov, index(ov, "=") + 1)); k++ }
          else if (ov == "--chdir")         { ep = (k + 1 <= nw ? literal_path(RW[k+1]) : ""); k += 2 }
          else if (ov ~ /^--split-string=/) { sv = substr(ov, index(ov, "=") + 1); k++ }
          else if (ov == "--split-string")  { sv = (k + 1 <= nw ? unquote(RW[k+1]) : ""); k += 2 }
          else if (ov == "--unset")         { k += 2 }
          else if (ov ~ /^--unset=/ || ov == "--ignore-environment" || ov == "--null") { k++ }
          else return 0
        } else {
          rc2 = parse_cluster(ov, "env")
          if (rc2 != 0) return 0          # 조회이거나 미지원 옵션 -> 실행되지 않는다
          if (OPT_ARG == "C") {
            ep = OPT_EAT ? (k + 1 <= nw ? literal_path(RW[k+1]) : "") : literal_path_val(OPT_VAL)
            k += (OPT_EAT ? 2 : 1)
          } else if (OPT_ARG == "S") {
            sv = OPT_EAT ? (k + 1 <= nw ? unquote(RW[k+1]) : "") : OPT_VAL
            k += (OPT_EAT ? 2 : 1)
          } else {
            k += (OPT_ARG != "" && OPT_EAT ? 2 : 1)
          }
        }
        # -C / --chdir 로 정해진 위치를 누적한다 (cd 와 같은 규칙).
        if (ep != "\001") {
          if (ep == "") eunc = 1
          else edir = (ep ~ /^\//) ? normpath(ep) : normpath((edir != "" ? edir : cwd) "/" ep)
          continue
        }
        # -S / --split-string 문자열을 분해해 **워드 목록에 삽입**한다. macOS env 는 split
        # 결과 뒤에 원래 argv 를 이어 붙이므로, 삽입하면 일반 판정 흐름이 그대로 적용된다
        # (별도 합성 규칙이 필요 없다). `\_` 는 인자 구분 공백이다
        # (실측: `env -S 'git\_--version'` 이 실제 실행됨).
        # 그 밖의 escape·`${…}`·인용이 남으면 정확히 분해할 수 없으므로 **보수 판정**한다
        # — 아래에서 커밋 후보로 남긴다. rc=2 폴백은 legacy 글롭이 이 spelling 을 놓쳐
        # 해소가 되지 않는다.
        if (sv != "\001") {
          if (sv == "") { eunc = 1; continue }
          env_s_lex(sv)
          if (ES_BAD) return 0                            # 잘못된 escape -> 실행되지 않는다
          if (ES_UNSURE) {
            # 확장이 섞였어도 **그 앞에서 명령명이 확정되면 그것으로 판정**한다 —
            # `env -S 'printf "${HOME} git commit"'` 은 printf 가 문자열을 출력할 뿐이다.
            # 전체를 보수 판정하면 실행되지 않는 커밋으로 사용자를 막는다.
            if (ESN >= 1) {
              esn1 = ESW[1]; sub(/^.*\//, "", esn1)
              if (esn1 != "git") return 0
            }
            split_unsure = 1; continue
          }
          if (ESN == 0) { eunc = 1; continue }
          for (i = nw; i >= k; i--) { MW[i + ESN] = MW[i]; RW[i + ESN] = RW[i] }
          for (i = 1; i <= ESN; i++) { MW[k + i - 1] = ESW[i]; RW[k + i - 1] = ESW[i] }
          nw += ESN
          continue
        }
      }
      continue
    }

    # (c) 환경 대입 — 인식은 **마스킹 기준**을 유지한다. 셸은 'VAR=val' cmd 를 대입이 아니라
    #     명령명으로 취급하므로, 인용이 섞인 워드를 대입으로 인식하면 안 된다.
    if (MW[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
      if (RW[k] ~ /^RD_LIFECYCLE_BYPASS_REASON=(bootstrap|lifecycle|small-task|legacy)$/) lb = 1
      # repo 대상을 바꾸는 환경 대입은 추적하지 않고 **불확실로 떨어뜨린다**(fail-closed).
      # cd/-C 로 계산한 위치가 실제 커밋 repo 와 달라져 외부 생략이 우회되기 때문이다.
      if (MW[k] ~ /^(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_OBJECT_DIRECTORY)=/) genv = 1
      k++; continue
    }
    # (d) 셸 예약어와 실행 prefix. 값이 필요하므로 여기서 복원한다.
    UW[k] = unquote(RW[k])
    if (UW[k] == "") return 0              # 명령명이 런타임 결정 -> 현행과 동일하게 미탐
    cmd0 = UW[k]; sub(/^.*\//, "", cmd0)
    if (cmd0 == "if" || cmd0 == "then" || cmd0 == "else" || cmd0 == "elif" ||
        cmd0 == "do" || cmd0 == "while" || cmd0 == "until" || cmd0 == "!") { k++; continue }
    # `builtin` 은 여기 넣지 않는다 — 셸 내장만 실행하므로 `builtin git commit` 은
    # 실행 자체가 실패한다. prefix 로 취급하면 실행되지 않는 명령을 차단하는 오탐이 된다.
    # 실행 prefix — 옵션 소비·조회·미지원 판정은 parse_cluster 가 wrapper 별로 처리한다.
    # **옵션 표만으로는 부족하고 실행 주체를 구분해야 한다**(실측):
    #   * `nohup` 은 옵션이 없다. `nohup -x git commit` 의 `-x` 는 **utility 이름**이므로
    #     nohup 이 그것을 실행하려다 실패하고 git 은 실행되지 않는다 -> 커밋 아님.
    #   * 슬래시 없는 `time` 은 **셸 예약어**로 `-p` 만 받는다. `time -a git commit` 은 `-a` 를
    #     utility 로 찾다 실패한다(`bash: -a: command not found`) -> 커밋 아님.
    #     `/usr/bin/time` 처럼 경로가 있거나 `command time` 을 지난 경우만 외부 utility 표를 쓴다.
    if (cmd0 == "command" || cmd0 == "exec" || cmd0 == "time" || cmd0 == "nohup") {
      if (cmd0 == "time" && UW[k] !~ /\// && !ext_wrap) tname = "shtime"
      else tname = cmd0
      # **셸이 직접 파싱하는 위치를 떠나면 이후 `time` 은 외부 utility 다.** `command` 뿐 아니라
      # `env`·`exec`·`nohup`·외부 `time` 뒤도 같다(실측: `env time -a git commit` 은 외부
      # time 이 `-a` 를 소비하고 git 을 실행한다).
      ext_wrap = 1
      k++
      while (k <= nw) {
        ov = unquote(RW[k])
        if (ov == "" || ov !~ /^-/ || ov == "-") break
        if (ov == "--") { k++; break }
        if (tname == "nohup") return 0                 # 옵션이 없으므로 -x 는 utility 이름이다
        if (ov ~ /^--/) return 0                       # 네 wrapper 는 long option 이 없다
        rc2 = parse_cluster(ov, tname)
        if (rc2 != 0) return 0                         # 조회·미지원 옵션 -> 실행되지 않는다
        k += (OPT_ARG != "" && OPT_EAT ? 2 : 1)
      }
      continue
    }
    break
  }
  # `-S` 문자열을 정확히 분해할 수 없었으면 커밋 여부를 확정할 수 없다 -> 보수적으로
  # 커밋 후보로 남긴다(위치는 확정된 것을 쓴다). 이 wrapper 자체가 드물어 과탐 비용이 낮다.
  if (split_unsure) {
    NC++
    CB[NC] = (lb ? 1 : 0)
    if (genv || repo_unc || eunc) CT[NC] = "?"
    else if (edir != "") CT[NC] = edir
    else CT[NC] = (uncertain ? "?" : cwd)
    return 0
  }
  # 명령 없이 대입만 있는 서브커맨드(`GIT_DIR=…;`)는 **셸 변수를 설정**한다. 그 변수가
  # export 되어 있으면 이후 커밋의 실행 repo 가 바뀌므로 지속되는 불확실로 남긴다.
  # 커밋 prefix 의 대입(`GIT_DIR=… git commit`)은 그 명령에만 적용되므로 genv(지역)로 남는다.
  if (k > nw) {
    if (genv) repo_unc = 1
    return 0
  }
  # 선행 서브커맨드가 repo 대상 환경을 export 하면 이후 커밋의 실행 repo 를 증명할 수 없다.
  # **cwd 불확실(uncertain)과 다른 변수에 담는다.** 절대 `-C` 는 cwd 불확실만 해소할 수 있고
  # repo override 는 해소하지 못한다. 같은 변수에 담으면 `export GIT_DIR=<프로젝트>/.git;
  # git -C /tmp commit` 이 `/tmp` 로 확정되어 외부 생략으로 빠진다(실측 재현 — 실제 커밋
  # repo 는 프로젝트다).
  # 값 없는 bare export(`export GIT_DIR`)도 이후의 같은 이름 대입을 환경으로 올린다.
  # 따라서 `=` 유무를 가리지 않고 이름만 일치해도 불확실로 남긴다
  # (`export GIT_DIR; GIT_DIR=<프로젝트>/.git; git -C /tmp commit` 실측 우회).
  if (cmd0 == "export" || cmd0 == "set" || cmd0 == "declare" || cmd0 == "typeset") {
    for (i = k + 1; i <= nw; i++)
      if (MW[i] ~ /^(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_OBJECT_DIRECTORY)(=|$)/) { repo_unc = 1; break }
    return 0
  }
  if (cmd0 != "cd" && cmd0 != "git") return 0    # 여기서 끝나면 워드 1개만 복원한 셈이다

  if (cmd0 == "cd") {
    if (op != "&&") { uncertain = 1; return 0 }        # 성공 보장 없음
    if (k + 1 > nw) { uncertain = 1; return 0 }
    UW[k+1] = unquote(RW[k+1])
    if (UW[k+1] == "-") { uncertain = 1; return 0 }
    p = literal_path(RW[k+1])
    if (p == "") { uncertain = 1; return 0 }
    cwd = (p ~ /^\//) ? normpath(p) : normpath(cwd "/" p)
    return 0
  }

  if (cmd0 != "git") return 0

  # git -C 는 argv 순서로 누적된다 (git 문서: -C a -C b 는 b 가 상대면 a/b, 절대면 b 로 대체).
  # 따라서 각 -C 를 직전 유효 위치 기준으로 순차 합성한다. 하나라도 리터럴이 아니면 불확실.
  # base 는 `env -C` 가 정한 위치(edir)가 있으면 그것, 없으면 cwd 다.
  gdir = ""; gunc = 0; gabs = 0; k++
  while (k <= nw) {
    UW[k] = unquote(RW[k])
    if (UW[k] == "-C") {
      if (k + 1 > nw) break
      p = literal_path(RW[k+1])
      if (p == "") gunc = 1
      else if (p ~ /^\//) { gdir = normpath(p); gabs = 1 }
      else gdir = normpath((gdir != "" ? gdir : (edir != "" ? edir : cwd)) "/" p)
      k += 2; continue
    }
    if (UW[k] == "-c") { k += 2; continue }
    # repo 대상을 바꾸는 옵션은 fail-closed. `--git-dir=X` 와 `--git-dir X` 두 형태 모두.
    if (UW[k] ~ /^--(git-dir|work-tree|common-dir)=/) { genv = 1; k++; continue }
    if (UW[k] == "--git-dir" || UW[k] == "--work-tree" || UW[k] == "--common-dir") { genv = 1; k += 2; continue }
    if (UW[k] ~ /^--(exec-path|namespace)=/) { k++; continue }
    if (UW[k] ~ /^-/) { k++; continue }
    break
  }
  if (k > nw || UW[k] != "commit") return 0

  # 커밋 하나를 후보로 기록한다. bypass 는 **이 커밋의 환경 prefix** 에 붙은 것만 인정한다
  # (다른 서브커맨드의 bypass 가 이 커밋을 면제시키면 안 된다).
  NC++
  CB[NC] = (lb ? 1 : 0)
  # 절대 -C 가 기준을 세우면 **cwd 불확실**과 무관하게 실행 위치가 확정된다.
  # 상대 -C 만으로 구성되면 cwd 에 의존하므로 불확실이 전파된다.
  # 다만 repo override 불확실(repo_unc)은 -C 로 해소되지 않으므로 항상 우선한다.
  if (gunc || genv || repo_unc || eunc) CT[NC] = "?"
  else if (gdir != "" && gabs) CT[NC] = gdir
  else if (gdir != "") CT[NC] = (uncertain ? "?" : gdir)
  else if (edir != "") CT[NC] = edir            # env -C 는 cwd 불확실과 무관하게 위치를 정한다
  else CT[NC] = (uncertain ? "?" : cwd)
  return 0
}
