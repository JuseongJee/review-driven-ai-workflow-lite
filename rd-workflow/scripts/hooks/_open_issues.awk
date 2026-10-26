# CHECKPOINT.md 의 `## Open Issues` 절을 판정한다.
# 출력은 한 줄 — 종결이면 `ok`, 아니면 사유 문자열.
#
# 판정 축은 라인의 순서가 아니라 구조다. 리스트 항목만 판정 대상이고,
# 빈 줄로 분리된 독립 문단은 내용을 보지 않는다 — 자유 산문의 의미를
# 추론하지 않는 것이 이 설계의 전제이며, 판정에 반영되어야 할 미해결
# 이의는 리스트 항목으로 적는다는 작성 계약이 이를 보완한다.
#
# 종결 조건 (모두 만족해야 한다):
#   1. 절의 첫 내용 라인이 리스트 항목이다   → 마커 앞 산문을 막는다
#   2. 종결 마커인 리스트 항목이 하나 이상 있다
#   3. 마커가 아닌 리스트 항목이 하나도 없다  → 마커 뒤 이의를 막는다
#   4. 마커 항목에 이어지는 줄이 없다        → 줄을 바꾼 단서를 막는다
#
# 마커 문법은 확장하지 않는다. `- ` 의 공백 1개와 후행 ASCII 마침표
# 1개까지만 허용하며, 이 문법이 리스트 판별(기호 뒤 공백 필수)과 정합한다.

/^## Open Issues/          { s = 1; next }
s && /^## /                { exit }
!s                         { next }
/^[ \t]*<!--/              { next }
/^[ \t]*$/                 { prev_marker = 0; next }
{
  is_list = ($0 ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/)
  if (!seen) {
    seen = 1
    if (!is_list) { reason = "open-issues-prose-before-marker:" $0; exit }
  }
  if (is_list) {
    if ($0 ~ /^- (없음|None)\.?[ \t]*$/) { markers++; prev_marker = 1 }
    else { reason = "open-issues-unresolved:" $0; exit }
    next
  }
  if (prev_marker) { reason = "open-issues-marker-continued:" $0; exit }
  prev_marker = 0
}
END {
  if (!s)             { print "open-issues-missing"; exit }
  if (reason != "")   { print reason; exit }
  if (markers == 0)   { print "open-issues-empty"; exit }
  print "ok"
}
