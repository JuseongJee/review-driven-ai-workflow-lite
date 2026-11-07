# _delete_scan.awk — 명령 문자열에서 삭제 호출(trash·rm·git worktree remove)의 대상 경로를 구한다.
#
# 입력: 명령 전체 (RS="\001" 한 레코드), -v start_dir=<절대 경로> -v home=<절대 경로>
# 출력: 줄마다  T<TAB><절대 경로>        — 정규화한 삭제 대상 (논리 경로)
#               U<TAB><원문 단어>        — 대상을 구할 수 없음 (호출측은 통과로 다룬다)
#               S<TAB><단어 값>          — git worktree remove 의 상대 인자. git 의 이름 축약(worktree 경로의
#                                         끝 구성 요소) 비교용이다. 같은 인자의 T·U 줄도 함께 나온다.
# 종료 코드: 0 해석 성공, 3 해석 불가 (닫히지 않은 따옴표). 호출측은 3 을 통과로 다룬다.
#
# `_commit_scan.awk` 와 독립이다 (출력 계약이 다르다). `normpath` 만 같은 모양이다.
#
# 셸 상태 추적 (change spec 3.3):
#   - 작업 디렉터리는 값 하나가 아니라 후보 집합이다. cd 는 실패할 수 있다고 본다.
#   - AND/OR 목록은 OK(직전 명령 성공 경로)·FAIL(실패 또는 건너뛴 경로) 두 집합으로 추적한다.
#   - 파이프라인 구성 명령과 `&` 로 끝난 목록은 subshell 이라 cd·대입이 밖으로 나가지 않는다.
#   - `( … )` 는 후보 집합과 변수 표 전체를 저장했다가 `)` 에서 되돌린다.
#   - 후보가 8개를 넘으면 "?"(모름) 하나로 줄인다. 상대 경로 대상은 U 가 된다.
# 이 해석기가 다루지 않는 형태(eval, bash -c, find -exec, xargs, glob, rmdir, 스크립트 안의 삭제,
# $'…', 셸 함수·alias, sudo·env 의 옵션 값)는 대상을 내지 않는다. `$( … )` 안 heredoc 본문에
# 짝 없는 괄호가 있으면 괄호 짝 세기가 어긋나 해석 불가(3, 통과)가 된다.

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

function basename(s) { sub(/.*\//, "", s); return s }

# ---- 후보 집합 (SEP 로 이은 문자열) ----
function scount(set,   a) { return (set == "" ? 0 : split(set, a, SEP)) }
function sadd(set, x,   n, a, i) {
  if (x == "") return set
  n = split(set, a, SEP)
  for (i = 1; i <= n; i++) if (a[i] == x) return set
  return (set == "" ? x : set SEP x)
}
function capset(set) { return (scount(set) > 8 ? "?" : set) }
function sunion(a, b,   n, arr, i, r) {
  r = a; n = split(b, arr, SEP)
  for (i = 1; i <= n; i++) r = sadd(r, arr[i])
  return capset(r)
}

# PWD 자리표시자(PH)를 후보 경로로 바꾼다. gsub 는 &·\ 해석이 있어 쓰지 않는다.
function subph(p, c,   k) {
  while ((k = index(p, PH)) > 0) p = substr(p, 1, k - 1) c substr(p, k + 1)
  return p
}

# 후보 base 에서 단어 p 를 절대 경로로 푼다. 구할 수 없으면 "".
function resolve(p, ok, base) {
  if (!ok) return ""
  if (index(p, PH)) { if (base == "?" || base == "") return ""; p = subph(p, base) }
  if (substr(p, 1, 1) == "/") return normpath(p)
  if (base == "?" || base == "") return ""
  return normpath(base "/" p)
}

function emit(p, ok, raw, base,   r) {
  if (ok && p == "") return
  r = resolve(p, ok, base)
  if (r == "") print "U\t" raw
  else print "T\t" r
}

# ---- 변수 표 저장·복원 ----
function savevars(s,   k, n, a, i, lst, m, KK) {
  n = split(SVN[s], a, SEP)
  for (i = 1; i <= n; i++) { delete SV[s, a[i]]; delete SVO[s, a[i]] }
  lst = ""; m = 0
  for (k in V) KK[++m] = k
  for (i = 1; i <= m; i++) { k = KK[i]; SV[s, k] = V[k]; SVO[s, k] = VOK[k]; lst = (lst == "" ? k : lst SEP k) }
  SVN[s] = lst
}
function restorevars(s,   k, n, a, i, m, KK) {
  m = 0
  for (k in V) KK[++m] = k
  for (i = 1; i <= m; i++) { delete V[KK[i]]; delete VOK[KK[i]] }
  n = split(SVN[s], a, SEP)
  for (i = 1; i <= n; i++) { V[a[i]] = SV[s, a[i]]; VOK[a[i]] = SVO[s, a[i]] }
}

# NAME=값 단어를 변수 표에 넣는다. cond 이면(건너뛸 수 있는 위치) 값을 구할 수 없음으로 표시한다.
function setvar(wd, ok, cond, run,   nm, val) {
  nm = wd; sub(/=.*/, "", nm)
  val = wd; sub(/^[^=]*=/, "", val)
  if (cond) ok = 0
  if (ok && index(val, PH)) {
    if (scount(run) == 1 && run != "?") val = subph(val, run); else ok = 0
  }
  V[nm] = val; VOK[nm] = ok
}

# ---- 단어 ----
function endword() {
  if (inword) {
    nw++; W[nw] = w; WOK[nw] = wok; WRAW[nw] = wraw
    if (skipnext) { nw-- ; skipnext = 0 }
  }
  inword = 0; w = ""; wok = 1; wraw = ""
}
function addc(c) { inword = 1; w = w c; wraw = wraw c }

function expand(name) {
  inword = 1; wraw = wraw "$" name
  if (name == "PWD") { w = w PH; return }
  if (name == "HOME") { w = w home; return }
  if (name in V) { if (VOK[name]) w = w V[name]; else wok = 0; return }
  wok = 0
}

function iswrapper(x) { return (x == "sudo" || x == "command" || x == "exec" || x == "nohup" || x == "time") }
function isreserved(x) { return (x == "{" || x == "if" || x == "then" || x == "else" || x == "elif" || x == "do" || x == "while" || x == "until" || x == "!") }

# 목록·파이프 구분자 처리. 구분자 종류: ; \n ) && || | &
function seponly(sep) {
  nw = 0
  if (sep == "&&" || sep == "||") prevsep = sep
  else if (sep == "|") prevsep = "|"
  else if (sep == "&") {
    restorevars(100 + sp)
    CUR = LCUR[100 + sp]; OK = CUR; FAIL = ""; prevsep = ";"
  } else {
    CUR = sunion(OK, FAIL); OK = CUR; FAIL = ""; prevsep = ";"
    LCUR[100 + sp] = CUR; savevars(100 + sp)
  }
}

# 앞뒤 구분자(prevsep, sep)에 따라 실행 후보 집합을 정한다.
function runset() {
  if (prevsep == "|") return PRUN
  PRUN = (prevsep == "&&" ? OK : (prevsep == "||" ? FAIL : sunion(OK, FAIL)))
  listsep = prevsep
  return PRUN
}

# 실행 결과(newok·newfail)를 AND/OR 목록 상태에 합친다.
function merge(newok, newfail) {
  if (listsep == "&&") { OK = newok; FAIL = sunion(newfail, FAIL) }
  else if (listsep == "||") { OK = sunion(newok, OK); FAIL = newfail }
  else { OK = newok; FAIL = newfail }
}

function endcmd(sep,   run, inpipe, newok, newfail, i, k, c, na, AS, ci, nc, CA, cond, d, opts, gn, GW, GWO, j, base) {
  endword()
  if (nw == 0) {
    if (sep == "\n" && (prevsep == "&&" || prevsep == "||" || prevsep == "|")) return
    seponly(sep); return
  }
  run = runset()
  inpipe = (prevsep == "|" || sep == "|")
  newok = run; newfail = run
  i = 1; na = 0
  while (i <= nw) {
    if (W[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { AS[++na] = i; i++; continue }
    if (iswrapper(W[i])) { i++; while (i <= nw && WOK[i] && W[i] ~ /^-/) i++; continue }
    if (isreserved(W[i])) { i++; continue }
    break
  }
  cond = ((prevsep == "&&" && FAIL != "") || (prevsep == "||" && OK != ""))
  if (i > nw) {
    if (!inpipe) for (k = 1; k <= na; k++) setvar(W[AS[k]], WOK[AS[k]], cond, run)
  } else {
    c = basename(W[i])
    if (c == "export" || c == "declare" || c == "local" || c == "readonly") {
      if (!inpipe) for (k = i + 1; k <= nw; k++) if (W[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) setvar(W[k], WOK[k], cond, run)
    } else if (c == "cd" || c == "pushd") {
      if (!inpipe) {
        k = i + 1
        while (k <= nw && WOK[k] && W[k] ~ /^-[LPe@]+$/) k++
        if (k <= nw && WOK[k] && W[k] == "--") k++
        newok = ""
        nc = split(run, CA, SEP)
        for (ci = 1; ci <= nc; ci++) {
          if (k > nw) d = home
          else if (WOK[k] && W[k] == "-") d = ""
          else d = resolve(W[k], WOK[k], CA[ci])
          newok = sadd(newok, (d == "" ? "?" : d))
        }
        newok = capset(newok)
      }
    } else if (c == "trash" || c == "rm") {
      opts = 1
      nc = split(run, CA, SEP)
      for (k = i + 1; k <= nw; k++) {
        if (opts && W[k] == "--") { opts = 0; continue }
        if (opts && WOK[k] && W[k] ~ /^-/) continue
        for (ci = 1; ci <= nc; ci++) emit(W[k], WOK[k], WRAW[k], CA[ci])
      }
    } else if (c == "git") {
      gn = 0
      for (k = i + 1; k <= nw; k++) {
        if (W[k] == "-C" && k < nw) { k++; gn++; GW[gn] = W[k]; GWO[gn] = WOK[k]; continue }
        if (W[k] == "-c" && k < nw) { k++; continue }
        if (W[k] ~ /^-/) continue
        break
      }
      if (k + 1 <= nw && W[k] == "worktree" && W[k + 1] == "remove") {
        nc = split(run, CA, SEP)
        for (ci = 1; ci <= nc; ci++) {
          base = CA[ci]
          for (j = 1; j <= gn; j++) { base = resolve(GW[j], GWO[j], base); if (base == "") base = "?" }
          for (j = k + 2; j <= nw; j++) {
            if (WOK[j] && W[j] ~ /^-/) continue
            emit(W[j], WOK[j], WRAW[j], base)
            # git 은 worktree 경로의 마지막 구성 요소들(유일하면)로도 대상을 찾는다 — `git worktree remove x`.
            # 경로 해석과 별도로 이름 그대로 S 줄을 내고, 호출측이 세션 루트의 끝 구성 요소와 비교한다.
            if (ci == 1 && WOK[j] && W[j] != "" && substr(W[j], 1, 1) != "/") print "S\t" W[j]
          }
        }
      }
    }
  }
  if (sep != "|") merge(newok, newfail)
  seponly(sep)
}

function dollar(i,   nx, j, name, depth, c2) {
  nx = substr(s, i + 1, 1)
  if (nx == "{") {
    j = index(substr(s, i + 2), "}"); if (j == 0) { wok = 0; inword = 1; return n + 1 }
    name = substr(s, i + 2, j - 1)
    if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/) expand(name); else { inword = 1; wok = 0 }
    return i + 2 + j
  }
  if (nx == "(") {
    if (substr(s, i, 6) == "$(pwd)") { inword = 1; wraw = wraw "$(pwd)"; w = w PH; return i + 6 }
    depth = 0
    for (j = i + 1; j <= n; j++) { c2 = substr(s, j, 1); if (c2 == "(") depth++; else if (c2 == ")") { depth--; if (depth == 0) break } }
    inword = 1; wok = 0; wraw = wraw substr(s, i, j - i + 1); return j + 1
  }
  if (nx ~ /[A-Za-z_]/) {
    name = ""; j = i + 1
    while (j <= n && substr(s, j, 1) ~ /[A-Za-z0-9_]/) { name = name substr(s, j, 1); j++ }
    expand(name); return j
  }
  if (nx ~ /[0-9@*#?!$-]/) { inword = 1; wok = 0; wraw = wraw "$" nx; return i + 2 }
  addc("$"); return i + 1
}

function skip_heredocs(i,   k, line, j) {
  for (k = 1; k <= hd; k++) {
    while (i <= n) {
      j = index(substr(s, i), "\n")
      line = (j ? substr(s, i, j - 1) : substr(s, i))
      i = (j ? i + j : n + 1)
      if (HDS[k]) sub(/^\t+/, "", line)
      if (line == HDD[k]) break
    }
  }
  hd = 0
  return i
}

BEGIN { RS = "\001"; SEP = "\001"; PH = "\002" }
{
  s = $0; gsub(PH, " ", s); n = length(s)
  CUR = start_dir; OK = CUR; FAIL = ""; prevsep = ";"; PRUN = CUR; listsep = ";"; sp = 0
  nw = 0; inword = 0; w = ""; wok = 1; wraw = ""; hd = 0; skipnext = 0
  savevars(100)
  LCUR[100] = CUR
  i = 1
  while (i <= n) {
    ch = substr(s, i, 1)
    if (ch == "\\") {
      nx = substr(s, i + 1, 1)
      if (nx == "\n") { i += 2; continue }
      addc(nx); i += 2; continue
    }
    if (ch == "'") {
      j = index(substr(s, i + 1), "'"); if (j == 0) exit 3
      inword = 1; t = substr(s, i + 1, j - 1); w = w t; wraw = wraw "'" t "'"; i += j + 1; continue
    }
    if (ch == "\"") {
      i++; inword = 1; closed = 0
      while (i <= n) {
        ch = substr(s, i, 1)
        if (ch == "\"") { i++; closed = 1; break }
        if (ch == "\\") {
          nx = substr(s, i + 1, 1)
          if (nx ~ /[$`"\\]/) { w = w nx; wraw = wraw nx; i += 2; continue }
          if (nx == "\n") { i += 2; continue }
        }
        if (ch == "`") { wok = 0; j = index(substr(s, i + 1), "`"); i += (j ? j + 1 : n); continue }
        if (ch == "$") { i = dollar(i); continue }
        w = w ch; wraw = wraw ch; i++
      }
      if (!closed) exit 3
      continue
    }
    if (ch == "$") { i = dollar(i); continue }
    if (ch == "`") { inword = 1; wok = 0; j = index(substr(s, i + 1), "`"); i += (j ? j + 1 : n); continue }
    if (ch == "#" && !inword) { j = index(substr(s, i), "\n"); if (j == 0) break; i += j - 1; continue }
    if (ch == "~" && !inword && (substr(s, i + 1, 1) == "/" || substr(s, i + 1, 1) ~ /[ \t\n;&|)]/ || i == n)) { inword = 1; w = w home; wraw = wraw "~"; i++; continue }
    if (ch == " " || ch == "\t") { endword(); i++; continue }
    if (ch == "\n") {
      endcmd("\n")
      if (hd) { i = skip_heredocs(i + 1); continue }
      i++; continue
    }
    if (ch == ";") { endcmd(";"); i += (substr(s, i + 1, 1) == ";" ? 2 : 1); continue }
    if (ch == "&") {
      nx = substr(s, i + 1, 1)
      if (nx == "&") { endcmd("&&"); i += 2; continue }
      if (nx == ">") {
        endword(); i += 2
        while (substr(s, i, 1) == ">") i++
        skipnext = 1; continue
      }
      endcmd("&"); i++; continue
    }
    if (ch == "|") {
      nx = substr(s, i + 1, 1)
      if (nx == "|") { endcmd("||"); i += 2; continue }
      if (nx == "&") { endcmd("|"); i += 2; continue }
      endcmd("|"); i++; continue
    }
    if (ch == "(") {
      endword(); if (nw > 0) endcmd(";")
      if (sp < 90) {
        run = runset()
        sp++; GRUN[sp] = run; GPREV[sp] = prevsep; GLS[sp] = listsep; GPR[sp] = PRUN; GOK[sp] = OK; GFAIL[sp] = FAIL
        savevars(sp)
        CUR = run; OK = run; FAIL = ""; prevsep = ";"; LCUR[100 + sp] = CUR; savevars(100 + sp)
      }
      i++; continue
    }
    if (ch == ")") {
      endcmd(")")
      if (sp > 0) {
        restorevars(sp)
        run = GRUN[sp]; OK = GOK[sp]; FAIL = GFAIL[sp]; prevsep = GPREV[sp]; listsep = GLS[sp]; PRUN = GPR[sp]
        sp--
        merge(run, run)
        prevsep = ";"
      }
      i++; continue
    }
    if (ch == "<" || ch == ">") {
      if (inword && w ~ /^[0-9]+$/) { inword = 0; w = ""; wraw = ""; wok = 1 } else endword()
      if (substr(s, i, 3) == "<<<") { i += 3; skipnext = 1; continue }
      if (substr(s, i, 2) == "<<") {
        i += 2; strip = 0
        if (substr(s, i, 1) == "-") { strip = 1; i++ }
        while (substr(s, i, 1) ~ /[ \t]/) i++
        d = ""
        while (i <= n && substr(s, i, 1) !~ /[ \t\n;&|<>()]/) { c1 = substr(s, i, 1); if (c1 != "'" && c1 != "\"" && c1 != "\\") d = d c1; i++ }
        HDD[++hd] = d; HDS[hd] = strip
        continue
      }
      i++
      while (substr(s, i, 1) ~ /[>&|]/) i++
      skipnext = 1
      continue
    }
    addc(ch); i++
  }
  endcmd(";")
}
