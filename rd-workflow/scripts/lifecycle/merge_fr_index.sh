#!/usr/bin/env bash
# merge_fr_index.sh <base> <ours> <theirs> — FUTURE_REQUESTS.md 행 집합 3-way 병합.
#   인덱스는 제목(두 번째 컬럼)을 키로 하는 행 집합이다. git 의 줄 병합은 양쪽이 표 끝에 서로 다른
#   행을 append 하면 반드시 충돌하므로(등록 커밋이 기본 브랜치에 먼저 쌓이는 구조에서 흔함),
#   archive.sh 가 인덱스 단독 충돌을 이 규칙으로 해결한다 (spec D7).
#   허용 문법(세 입력 모두 검증, 하나라도 어긋나면 fail-closed rc 1): 서문(| 로 시작하는 줄 없음) → 헤더 1줄 → 구분선 1줄(| - : 공백만)
#   → 행들(헤더와 같은 컬럼 수, 제목 비어 있지 않고 파일 안에서 고유) → 꼬리(빈 줄만).
#   컬럼 분해는 GFM 과 같게 **이스케이프되지 않은 `|` 로만** 나눈다 — 셀 본문의 `\|` 는 코드 스팬 안이든
#   밖이든 구분자가 아니고, `\\|` 는 「본문 역슬래시 + 구분자」다. 이스케이프되지 않은 생 `|` 는 GFM 에서도
#   셀이 쪼개지므로 계속 거부하며, 이때 구분자로 센 `|` 를 표시한 행을 함께 낸다(그 거부가 잡던
#   실수는 test_merge_fr_index.sh 8~12).
#   규칙: 서문·헤더·구분선·꼬리 = 한쪽만 바뀌면 그쪽, 양쪽 다르면 충돌 / 행 = 키별 (b,o,t): o==t→o, o==b→t, t==b→o, 그 외 충돌.
#   순서: base 순서 → ours 신규(ours 순서) → theirs 신규(theirs 순서). 출력은 줄 끝 개행으로 정규화된다.
#   stdout = 병합 결과 (rc 0). 충돌·malformed = stderr 한 줄 + rc 1 (stdout 없음).
set -uo pipefail
[[ $# -eq 3 ]] || { echo "usage: merge_fr_index.sh <base> <ours> <theirs>" >&2; exit 2; }
for f in "$1" "$2" "$3"; do [[ -f "$f" ]] || { echo "merge_fr_index: 파일 없음: $f" >&2; exit 2; }; done
out="$(awk '
# 이스케이프를 아는 컬럼 분해기. `\` 를 만나면 다음 한 글자를 본문으로 함께 먹으므로
# `\|` 는 본문이 되고 `\\|` 는 「본문 역슬래시 + 구분자」가 된다 (GFM 과 동일).
# arr 은 추가 인자여서 호출마다 지역·빈 배열이다.
function xsplit(l, arr,   i, n, c, cur) {
  n = 1; cur = ""
  for (i = 1; i <= length(l); i++) {
    c = substr(l, i, 1)
    if (c == "\\" && i < length(l)) { cur = cur c substr(l, i + 1, 1); i++; continue }
    if (c == "|") { arr[n] = cur; n++; cur = ""; continue }
    cur = cur c
  }
  arr[n] = cur
  return n
}
function xn(l,   a) { return xsplit(l, a) }
function role(i) { return (i == 1 ? "base" : (i == 2 ? "ours" : "theirs")) }
function key(l,   a, s) { xsplit(l, a); s = a[3]; gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function bad(msg) { ABORT = 1; print "merge_fr_index: " msg > "/dev/stderr"; exit 1 }
function pick(b, o, t) { if (o == t) return o; if (o == b) return t; if (t == b) return o; CONF = 1; return "" }
# 컬럼 수가 어긋난 행의 사유 설명. 어느 `|` 가 여분인지는 도구가 알 수 없다(무엇이 본문이고
# 무엇이 칸 경계인지는 쓴 사람의 의도다). 그래서 지목을 추측하지 않고 **구분자로 센 `|` 를 전부
# >|< 로 표시한 행**을 보여 준다 — 사람이 본문이어야 할 것을 바로 짚을 수 있고, 코드 스팬 문법을
# 해석하지 않으므로 틀린 곳을 가리키는 일이 없다.
function mark(l,   i, L, c, o) {
  o = ""; L = length(l)
  for (i = 1; i <= L; i++) {
    c = substr(l, i, 1)
    if (c == "\\" && i < L) { o = o c substr(l, i + 1, 1); i++; continue }
    o = o (c == "|" ? ">|<" : c)
  }
  return o
}
function why(l, got, want) {
  if (got < want) return "칸이 모자랍니다. 구분자로 센 위치: " mark(l)
  return "여분 파이프 " (got - want) "개 — 본문의 `|` 는 코드 스팬 안이라도 `\\|` 로 이스케이프해야 합니다." \
         " 구분자로 센 위치: " mark(l)
}
FNR == 1 { fi++ }
{
  if (st[fi] == 0) { if ($0 ~ /^\|/) { hdr[fi] = $0; ncol[fi] = xn($0); st[fi] = 1 } else pre[fi] = pre[fi] $0 "\n"; next }
  if (st[fi] == 1) { if ($0 !~ /^\|[-: |]+\|$/ || xn($0) != ncol[fi]) bad(role(fi) " " FNR "행 구분선이 잘못됐습니다(형식 또는 컬럼 수): " $0); sep[fi] = $0; st[fi] = 2; next }
  if ($0 ~ /^\|/) {
    if (st[fi] == 3) bad(role(fi) " " FNR "행 — 표가 둘 이상 있습니다")
    nc = xn($0)
    if (nc != ncol[fi]) bad(role(fi) " " FNR "행 컬럼 " nc "개(헤더는 " ncol[fi] "개). " why($0, nc, ncol[fi]))
    k = key($0)
    if (k == "") bad(role(fi) " " FNR "행 — 제목이 비어 있습니다: " $0)
    if ((fi, k) in row) bad(role(fi) " " FNR "행 — 파일 안 제목 중복: " k)
    row[fi, k] = $0; ord[fi, ++cnt[fi]] = k; next
  }
  if ($0 !~ /^[ \t]*$/) bad(role(fi) " " FNR "행 — 표 뒤에 빈 줄이 아닌 내용이 있습니다: " $0)
  st[fi] = 3; post[fi] = post[fi] $0 "\n"
}
END {
  if (ABORT) exit 1
  if (fi != 3) bad("입력 3개 필요")
  for (i = 1; i <= 3; i++) if (st[i] < 2) bad(role(i) " 에 인덱스 표(헤더+구분선)가 없습니다")
  CONF = 0
  P = pick(pre[1], pre[2], pre[3]); H = pick(hdr[1], hdr[2], hdr[3]); S = pick(sep[1], sep[2], sep[3]); Q = pick(post[1], post[2], post[3])
  if (CONF) bad("서문·헤더·구분선·꼬리가 양쪽에서 다르게 바뀌었습니다")
  n = 0
  for (i = 1; i <= cnt[1]; i++) {
    k = ord[1, i]
    b = row[1, k]; o = ((2, k) in row) ? row[2, k] : ""; t = ((3, k) in row) ? row[3, k] : ""
    r = pick(b, o, t)
    if (CONF) bad("행 충돌(양쪽 상이 수정): " k)
    if (r != "") res[++n] = r
  }
  for (i = 1; i <= cnt[2]; i++) {
    k = ord[2, i]; if ((1, k) in row) continue
    o = row[2, k]; t = ((3, k) in row) ? row[3, k] : ""
    if (t != "" && t != o) bad("신규 행 충돌(양쪽 상이 추가): " k)
    res[++n] = o
  }
  for (i = 1; i <= cnt[3]; i++) { k = ord[3, i]; if ((1, k) in row || (2, k) in row) continue; res[++n] = row[3, k] }
  hc = xn(H)
  for (i = 1; i <= n; i++) { rc = xn(res[i]); if (rc != hc) bad("병합 결과의 행 컬럼 " rc "개(헤더는 " hc "개) — 스키마 변경과 행 변경이 함께 있습니다: " res[i]) }
  printf "%s", P; print H; print S
  for (i = 1; i <= n; i++) print res[i]
  printf "%s", Q
}' "$1" "$2" "$3")" || exit 1
printf '%s\n' "$out"
