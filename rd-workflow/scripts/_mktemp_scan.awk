# mktemp -d 가드 정적 대조.
# 호출: awk [-v mode=file] -f _mktemp_scan.awk <파일...>
# mode 를 생략하거나 "dir"이면 기존 디렉터리 모드(강한 템플릿 대조)이고,
# "file"이면 파일 mktemp 약한 검사(핸들러 존재 여부만 봅니다)입니다.
# 출력: VIOLATION<TAB>file<TAB>lineno<TAB>reason<TAB>line  (위반 1건당 한 줄)
#       SUMMARY<TAB>sites<TAB>violations                    (마지막 한 줄)
# files 는 내지 않습니다 — awk 의 FNR==1 은 빈 파일을 세지 않으므로 호출부가 셉니다.
#
# 후보 제외는 네 가지뿐입니다 — ① 주석 줄 ② `mktemp-scan: literal` 마커가 있는 줄
# (실행되지 않는 텍스트) ③ `mktemp-scan: custom-handler` 마커가 있는 줄 (실행되지만
# 템플릿으로 표현할 수 없는 핸들러가 붙어 있음 — 모드 공통) ④ 검사 자신의 파일(호출부가
# 목록에서 뺍니다). 이스케이프·백슬래시 parity·인용 구간
# 판정을 하지 않습니다 — 그 판정을 세 번 고쳤고 매번 새 false negative 가 나왔습니다.
#
# **아래 Step 4~6 으로 실제 실행 검증됐습니다** (BSD awk 20200816):
#   표본 → SUMMARY 12 11 · 블록별 집합 일치 · 비위반 블록 교집합 없음
#   정본 트리 → 변경 전 10건, promote.sh:456 마커 적용 시 그 파일 0건, 변경 후 8건
#
# ── 파일 모드(mode=file) ──────────────────────────────────────────────
# 강한 템플릿 대조가 아니라 약한 검사입니다. 판정은 하나뿐입니다 — 후보 줄에도
# 바로 다음(논리) 줄에도 문자열 `||` 가 전혀 없으면 위반입니다. `||` 가 있어도
# 빈 값 검사가 빠졌거나, `|| true` 처럼 무력하거나, mktemp 와 무관한 다른 명령에
# 붙어 있거나, 주석·문자열 안이면 통과로 보입니다 — 셸 파서가 아니라 텍스트
# 대조이므로 이 한계를 그대로 감수합니다(사용자 결정, 2026-09-10).
# `\` 로 끝나는 줄은 이어진 논리 줄 전체를 하나로 봅니다(f_join_active 상태).
# 파일 끝·다음 파일 경계에서 판정이 미해결로 남으면(다음 줄이 없음) 위반으로
# 처리합니다 — FNR==1 과 END 양쪽에서 확정합니다.

BEGIN {
  sites = 0; violations = 0; pend = 0
  if (mode == "") mode = "dir"
  MK     = "mktemp"
  NEEDLE = MK " -d"
  SUB    = "$("
  MARKER = "mktemp" "-scan: literal"   # 선언적 제외 마커 ① — 이 줄의 mktemp -d 는 실행되지 않는 텍스트 (리터럴을 쪼개 자기참조 회피)
  MARKER2 = "mktemp" "-scan: custom-handler"   # 선언적 제외 마커 ② — 실행되지만 템플릿으로 표현할 수 없는 핸들러가 붙어 있음 (모드 공통 — 파일 모드도 재사용)
  A_MID  = "=\"" SUB NEEDLE
  A_TAIL = ")\" || { echo \""
  A_MSG  = ": 임시 디렉터리 생성 실패 (" "mktemp" " rc≠0, TMPDIR='${TMPDIR:-}')\" >&2; "
  B_PRE  = "[[ -n \"$"
  B_MID  = "\" && -d \"$"
  B_TAIL = "\" ]] || { echo \""
  B_MSG  = ": 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')\" >&2; "
  TAIL   = "; }"
  # 파일 모드 상태
  f_join_active = 0; f_await_next = 0; f_joined = ""; f_no = 0; f_file = ""; f_line = ""
  f_next_joined = ""   # 「다음 논리 줄」을 모으는 버퍼 — 그 줄도 `\` 로 이어질 수 있다
  # 대기 중 후보의 식별자는 따로 보존한다 — 대기 중에 다음 줄이 새 후보로 등록되면
  # f_no·f_file·f_line 이 새 후보 값으로 덮여, 이전 후보의 위반 위치를 잘못 보고한다
  # (Turn 004 F4).
  f_pend_no = 0; f_pend_file = ""; f_pend_line = ""
}
FNR == 1 {
  resolve("")
  if (mode == "file") file_boundary_resolve()
}
{
  if (mode == "file") {
    if (f_await_next) {
      # 「다음 논리 줄」도 `\` 로 이어질 수 있으므로 그 줄이 끝날 때까지 모아서 판정한다.
      # 물리 줄 하나만 보고 확정하면 `echo x \` + `  || exit 1` 처럼 핸들러가 이어진
      # 줄 뒤쪽에 있는 형태를 위반으로 오판한다 (Turn 002 F3).
      f_next_joined = (f_next_joined == "" ? $0 : f_next_joined " " $0)
      if ($0 !~ /\\$/) {
        if (index(f_next_joined, "||") == 0) f_report(f_pend_no, f_pend_file, f_pend_line)
        f_await_next = 0; f_next_joined = ""
      }
    }
    if (f_join_active) {
      f_joined = f_joined " " $0
      if ($0 ~ /\\$/) next                # 논리 줄이 계속 이어짐
      f_join_active = 0
      if (index(f_joined, "||") == 0) { f_await_next = 1; f_pend_no = f_no; f_pend_file = f_file; f_pend_line = f_line }
      next                                 # 이 물리 줄은 이어진 줄의 일부라 새 후보로 다시 보지 않음
    }
  } else {
    if (pend) resolve($0)
  }
  line = $0
  if (line ~ /^[ \t]*#/) next               # ① 주석 줄
  if (mode == "file") {
    if (!has_file_call(line)) next
  } else {
    if (index(line, NEEDLE) == 0) next
  }
  if (index(line, MARKER) > 0) next         # ② 선언적 제외 마커 (literal)
  if (index(line, MARKER2) > 0) next        # ② 선언적 제외 마커 (custom-handler)
  sites++
  if (mode == "file") {
    f_no = FNR; f_file = FILENAME; f_line = line
    if (index(line, "||") > 0) {
      # 후보 줄 자신에 || 가 있으면 그것으로 통과 — 다음 줄을 볼 필요가 없음
    } else if (line ~ /\\$/) {
      f_join_active = 1; f_joined = line
    } else {
      f_await_next = 1; f_pend_no = f_no; f_pend_file = f_file; f_pend_line = f_line
    }
  } else {
    p_line = line; p_no = FNR; p_file = FILENAME; pend = 1
  }
}
END {
  resolve("")
  if (mode == "file") file_boundary_resolve()
  printf "SUMMARY\t%d\t%d\n", sites, violations
}




function resolve(second) {
  if (!pend) return
  pend = 0
  if (p_line ~ /^[ \t]*(local|export)[ \t]/) { report("decl-combined"); return }
  if (second == "") { report("template-mismatch"); return }
  if (!template_ok(p_line, second)) report("template-mismatch")
}
function report(reason) {
  printf "VIOLATION\t%s\t%d\t%s\t%s\n", p_file, p_no, reason, p_line
  violations++
}
# 파일 모드에서 파일 끝·파일 경계에 도달했을 때 미해결 상태를 확정합니다.
# 「다음 줄」이 없다는 것은 곧 || 를 찾지 못했다는 뜻이므로 위반입니다.
function file_boundary_resolve() {
  if (f_await_next) {
    # 다음 논리 줄이 끝나기 전에 파일이 끝났으면 모은 부분 텍스트로 판정한다.
    if (f_next_joined == "" || index(f_next_joined, "||") == 0) f_report(f_pend_no, f_pend_file, f_pend_line)
    f_await_next = 0; f_next_joined = ""
  }
  if (f_join_active) {
    if (index(f_joined, "||") == 0) f_report(f_no, f_file, f_line)
    f_join_active = 0
  }
}
function f_report(no, file, line) {
  printf "VIOLATION\t%s\t%d\t%s\t%s\n", file, no, "no-handler", line
  violations++
}
# 후보 판정: `mktemp` 실행 지점 중 「-d 만 있는」 것을 뺀 나머지(파일 호출).
# 한 줄에 여러 mktemp 호출이 섞여 있으면 그중 하나라도 파일 호출이면 후보로 셉니다.
#
# 「실행」의 기준은 이 저장소의 실제 관례를 따라 커맨드 치환 시작 `$(` 바로 다음에
# 오는 `mktemp` 뿐입니다. 그냥 substring 대조만 하면 이미 보호된 줄 자신의 진단
# 메시지("... 임시 디렉터리 생성 실패 (mktemp rc≠0, ...)")나 주석·설명 문자열 안의
# "mktemp" 언급까지 실행으로 오인합니다 — 이 저장소는 mktemp 검사 도구 자신을 담고
# 있어 그런 언급이 흔합니다(실측: `$(` 요구 전 196건 → 요구 후 실제 실행만 남음).
# 이 저장소의 실제 실행은 전부 `$(mktemp ...)` 형태이고 backtick·bare 실행은 쓰이지
# 않습니다(실측 확인). 식별자 뒤 문자 검사는 `mktemp_guard_scan_*` 같은 식별자를
# 이중으로 막기 위한 안전장치입니다.
# 실행 위치 판정 — 증거 파일의 계수 규칙과 같은 세 형태만 실행으로 인정합니다:
# ① `$(mktemp` 커맨드 치환 ② 백틱 치환 ③ 명령 시작 위치(줄 머리 · `;` · `&` · `|` 뒤).
# 서브셸 `(` 는 일부러 명령 시작으로 세지 않습니다 — 가드 자신의 진단 문구
# `(mktemp rc≠0, ...)` 가 모두 그 형태라 세는 순간 대량 오탐이 돌아옵니다(실측 196건).
# `then`/`do` 뒤의 한 줄 실행은 이 저장소에 없어 인정하지 않습니다(약한 검사의 경계).
function is_exec_pos(line, p,   prefix, c) {
  if (p >= 3 && substr(line, p - 2, 2) == "$(") return 1
  if (p >= 2 && substr(line, p - 1, 1) == "`") return 1
  prefix = substr(line, 1, p - 1)
  sub(/[ \t]+$/, "", prefix)
  if (prefix == "") return 1
  c = substr(prefix, length(prefix), 1)
  if (c == ";" || c == "&" || c == "|") return 1
  return 0
}

function has_file_call(line,   pos, i, p, after) {
  pos = 0
  while ((i = index(substr(line, pos + 1), MK)) > 0) {
    p = pos + i
    pos = p
    if (!is_exec_pos(line, p)) continue
    after = substr(line, p + length(MK), 1)
    if (after ~ /[A-Za-z0-9_-]/) continue    # 식별자의 일부 (예: $(mktemp_something) — 이 저장소엔 없지만 안전장치)
    if (substr(line, p + length(MK), 3) != " -d") return 1
  }
  return 0
}
function template_ok(a, b,   ia, ib, ra, rb, v, args, label, term, want, p) {
  ia = indent_of(a); ib = indent_of(b)
  if (ia == "TAB" || ib == "TAB" || ia != ib) return 0
  ra = substr(a, length(ia) + 1); rb = substr(b, length(ib) + 1)
  v = head_ident(ra)
  if (v == "") return 0
  if (substr(ra, length(v) + 1, length(A_MID)) != A_MID) return 0
  args = substr(ra, length(v) + length(A_MID) + 1)
  if (substr(args, 1, length(A_TAIL)) == A_TAIL) { args = "" }
  else {
    p = index(args, A_TAIL)
    if (p == 0) return 0
    args = substr(args, 1, p - 1)
    if (args !~ /^ "[^"]*"$/) return 0
  }
  ra = substr(ra, length(v) + length(A_MID) + length(args) + length(A_TAIL) + 1)
  p = index(ra, A_MSG)
  if (p == 0) return 0
  label = substr(ra, 1, p - 1)
  if (label == "" || index(label, "\"") > 0) return 0
  term = substr(ra, p + length(A_MSG))
  if (substr(term, length(term) - length(TAIL) + 1) != TAIL) return 0
  term = substr(term, 1, length(term) - length(TAIL))
  if (!term_ok(term)) return 0
  want = B_PRE v B_MID v B_TAIL label B_MSG term TAIL
  return (rb == want)
}
function indent_of(s,   i, c, r) {
  r = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == " ") r = r " "
    else if (c == "\t") return "TAB"
    else break
  }
  return r
}
function head_ident(s,   i, c, r) {
  r = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (i == 1) { if (c !~ /^[A-Za-z_]$/) return "" }
    else if (c !~ /^[A-Za-z0-9_]$/) break
    r = r c
  }
  return r
}
function term_ok(t,   n) {
  if (t !~ /^(exit|return) [1-9][0-9]*$/) return 0
  n = t; sub(/^(exit|return) /, "", n); n = n + 0
  return (n >= 1 && n <= 255)
}
