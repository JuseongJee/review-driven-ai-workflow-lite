#!/usr/bin/env bash
# claudemd_rules_migrate.sh — 프로젝트 CLAUDE.md 의 `##` 절을 템플릿 기준과 대조해 분류합니다 (M013 용).
#
# 용도: 배포본 CLAUDE.md 가 프로젝트 소유로 바뀐 뒤, 기존 소비 프로젝트의 CLAUDE.md 에 남은
#       템플릿 규칙 절을 걷어낼 대상을 가려냅니다. 파일은 바꾸지 않습니다 (읽기 전용 — 삭제·표식 삽입은
#       사용자 확인을 거치는 Claude 절차가 합니다). 예외: 얕은 clone 이면 이력을 받으려고
#       `git fetch --unshallow` 를 시도합니다 (clone 의 .git 만 건드립니다).
#
# CLI:    bash claudemd_rules_migrate.sh classify <project CLAUDE.md> <clone dir>
#
# 출력 (stdout, TSV. 모든 판정이 끝난 뒤 한 번에 냅니다 — 오류 종료 시 stdout 은 비어 있습니다):
#   절마다   class<TAB>start<TAB>end<TAB>heading<TAB>dest
#     class   keep | template | modified | project | ambiguous
#     start   절의 첫 줄(제목 줄) 번호, end 는 다음 `##` 제목 직전(또는 파일 끝) 줄 번호. 1부터 셉니다.
#             `(서두)` 는 맨 앞 `#` 제목 줄 다음 줄부터 첫 `##` 직전까지입니다
#             (출력 범위 = 비교한 줄 범위. 제목 줄이 없으면 1 줄부터).
#     heading `## ` 를 뺀 제목. 첫 `##` 앞 본문은 `(서두)` (`#` 제목 줄 제외, 비면 출력 안 함).
#     dest    template·modified 는 그 제목이 옮겨 간 rules 파일 basename, 나머지는 `-`.
#   마지막   index<TAB>present|missing        (`## rd-workflow 규칙` 목차 유무)
#   fence 줄이 있으면 위 전부 대신 `abort<TAB>fence-present` 한 줄만 냅니다.
# 경고는 stderr. 종료코드: 0 정상(abort 포함) / 2 사용법 오류 / 1 입력 부재·읽기·비교 오류 (fail-closed).
#
# 판정 순서 (첫 일치):
#   ① 제목 다음 줄이 `<!-- rd-workflow:project-override -->` → keep
#   ② 제목이 clone 현재 CLAUDE.md 에 있음 (`(서두)` 는 본문이 그 서두와 같을 때만) → keep
#   ③ 같은 제목이 프로젝트 파일에 두 번 이상 → ambiguous
#   ④ 같은 제목의 기준 절 중 하나와 정규화 본문이 cmp -s 로 같음 → template
#   ⑤ 제목이 기준 집합에 있음 → modified
#   ⑥ 그 밖 → project
# 기준 집합 = clone 현재 CLAUDE.md + 현재 .claude/rules/rd-workflow/*.md + clone CLAUDE.md 의 git 이력 각 판.
# 본문 정규화 = 줄 끝 공백 제거 + 앞뒤 빈 줄 제거. 비교는 해시 없이 바이트 단위 cmp -s 입니다.
#
# fence 정책: fence 줄(앞 공백 0~3칸 뒤 ``` 또는 ~~~)이 하나라도 있으면 분류하지 않고 abort 합니다.
#   fence 의 여닫음 규칙(문자 종류·길이·들여쓰기)을 해석하지 않고 파일 전체를 보존하는 쪽을 택했습니다.
#   템플릿 CLAUDE.md 이력 82개 판에는 fence 가 한 번도 없었으므로, fence 가 있으면 프로젝트가 넣은 내용입니다.
set -uo pipefail

OVERRIDE_MARKER='<!-- rd-workflow:project-override -->'
INDEX_HEADING='rd-workflow 규칙'

die() { echo "claudemd_rules_migrate: $*" >&2; exit 1; }

if [[ $# -ne 3 || "$1" != "classify" ]]; then
  echo "usage: claudemd_rules_migrate.sh classify <project CLAUDE.md> <clone dir>" >&2
  exit 2
fi
PROJECT_FILE="$2"
CLONE="$3"
RULES_DIR="$CLONE/.claude/rules/rd-workflow"

[[ -f "$PROJECT_FILE" && -r "$PROJECT_FILE" ]] || die "프로젝트 CLAUDE.md 를 읽을 수 없습니다: $PROJECT_FILE"
[[ -d "$CLONE" ]] || die "clone 경로가 없습니다: $CLONE"
[[ -f "$CLONE/CLAUDE.md" && -r "$CLONE/CLAUDE.md" ]] || die "clone 의 CLAUDE.md 를 읽을 수 없습니다: $CLONE/CLAUDE.md"
[[ -d "$RULES_DIR" ]] || die "clone 에 .claude/rules/rd-workflow/ 가 없습니다 (구버전 템플릿): $RULES_DIR"

WORK="$(mktemp -d)" || { echo "claudemd_rules_migrate: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "claudemd_rules_migrate: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# fence 검사 — 어떤 분류보다 먼저.
if grep -Eq '^ {0,3}(```|~~~)' "$PROJECT_FILE"; then
  printf 'abort\tfence-present\n'
  exit 0
fi

# parse_sections <file> <prefix> : `##` 절로 나눠 목록(stdout)과 정규화 본문 파일($WORK/<prefix>N)을 만듭니다.
#   목록 줄: id<TAB>heading<TAB>start<TAB>end<TAB>marker(1|0)
parse_sections() {
  MARKER="$OVERRIDE_MARKER" awk -v dir="$WORK" -v pfx="$2" '
    function flush(endline,   s, e, i, f) {
      if (!active) return
      s = 1; while (s <= nb && buf[s] == "") s++
      e = nb; while (e >= s && buf[e] == "") e--
      if (head == "(서두)" && e < s) { active = 0; return }
      cnt++
      f = dir "/" pfx cnt
      printf "" > f
      for (i = s; i <= e; i++) print buf[i] > f
      close(f)
      printf "%s%d\t%s\t%d\t%d\t%d\n", pfx, cnt, head, startl, endline, mk
      active = 0
    }
    BEGIN { marker = ENVIRON["MARKER"]; cnt = 0; active = 1; head = "(서두)"; startl = 1; nb = 0; mk = 0; inpre = 1; first = 0; ptitle = 1 }
    {
      t = $0; sub(/[ \t\r]+$/, "", t)
      if (t ~ /^##([ \t]|$)/) {
        flush(NR - 1)
        head = t; sub(/^##[ \t]*/, "", head); gsub(/\t/, " ", head)
        active = 1; startl = NR; nb = 0; mk = 0; inpre = 0; first = 1
        next
      }
      if (inpre && ptitle) {
        if (t ~ /^# / || t == "#") { startl = NR + 1; next }   # 맨 앞 제목 줄은 비교·출력 범위 밖
        if (t != "") ptitle = 0
      }
      if (first) { if (t == marker) mk = 1; first = 0 }
      buf[++nb] = t
    }
    END { flush(NR) }
  ' "$1"
}

# ids_for <list> <heading> : 그 제목의 절 id 들
ids_for() { H="$2" awk -F'\t' '$2 == ENVIRON["H"] { print $1 }' "$1"; }

: > "$WORK/proj.list"
: > "$WORK/cur.list"
: > "$WORK/base.list"      # 기준 집합 전체 (현재 CLAUDE.md + 현재 rules + 이력)
: > "$WORK/rules.map"      # heading<TAB>basename (현재 rules 파일)

parse_sections "$PROJECT_FILE" p > "$WORK/proj.list" || die "프로젝트 CLAUDE.md 파싱 실패"
parse_sections "$CLONE/CLAUDE.md" c > "$WORK/cur.list" || die "clone CLAUDE.md 파싱 실패"
cat "$WORK/cur.list" >> "$WORK/base.list"

# 현재 rules 파일
ri=0
for rf in "$RULES_DIR"/*.md; do
  [[ -f "$rf" ]] || continue
  ri=$((ri + 1))
  parse_sections "$rf" "r${ri}_" > "$WORK/r${ri}.list" || die "rules 파일 파싱 실패: $rf"
  cat "$WORK/r${ri}.list" >> "$WORK/base.list"
  bn="$(basename "$rf")"
  awk -F'\t' -v bn="$bn" '{ print $2 "\t" bn }' "$WORK/r${ri}.list" >> "$WORK/rules.map"
done
[[ "$ri" -gt 0 ]] || die "clone 의 .claude/rules/rd-workflow/ 에 *.md 가 없습니다: $RULES_DIR"

# git 이력 각 판
if git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ "$(git -C "$CLONE" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    # 원격이 없으면 fetch 가 rc=0 으로 아무것도 안 하므로, rc 뿐 아니라 얕은 상태가 풀렸는지도 봅니다.
    if ! git -C "$CLONE" fetch --quiet --unshallow >/dev/null 2>&1 \
       || [[ "$(git -C "$CLONE" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
      echo "경고: 과거 템플릿 이력을 받지 못해 현재 템플릿만으로 판정합니다" >&2
    fi
  fi
  hi=0
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    hi=$((hi + 1))
    # 그 커밋에 CLAUDE.md 가 없으면(삭제된 판) 건너뜁니다.
    git -C "$CLONE" show "$c:CLAUDE.md" > "$WORK/h${hi}.md" 2>/dev/null || continue
    parse_sections "$WORK/h${hi}.md" "h${hi}_" > "$WORK/h${hi}.list" || die "이력 판 파싱 실패: $c"
    cat "$WORK/h${hi}.list" >> "$WORK/base.list"
  done < <(git -C "$CLONE" log --format=%H -- CLAUDE.md 2>/dev/null)
else
  echo "경고: clone 이 git 저장소가 아니어서 현재 템플릿만으로 판정합니다" >&2
fi

: > "$WORK/out.tsv"
INDEX=missing
while IFS=$'\t' read -r id heading start end mk; do
  [[ "$heading" == "$INDEX_HEADING" ]] && INDEX=present
  class=""
  dest="-"
  cur_ids="$(ids_for "$WORK/cur.list" "$heading")"
  base_ids="$(ids_for "$WORK/base.list" "$heading")"
  if [[ "$heading" != "(서두)" || -n "$base_ids" ]]; then
    dest="$(H="$heading" awk -F'\t' '$1 == ENVIRON["H"] { print $2; exit }' "$WORK/rules.map")"
    [[ -n "$dest" ]] || dest="-"
  fi

  if [[ "$mk" == "1" ]]; then
    class=keep
  elif [[ "$heading" != "(서두)" && -n "$cur_ids" ]]; then
    class=keep
  elif [[ "$heading" == "(서두)" ]] && [[ -n "$cur_ids" ]]; then
    for cid in $cur_ids; do
      cmp -s "$WORK/$id" "$WORK/$cid"; rc=$?
      [[ "$rc" -le 1 ]] || die "cmp 오류 (rc=$rc): $id vs $cid"
      [[ "$rc" -eq 0 ]] && { class=keep; break; }
    done
  fi

  if [[ -z "$class" ]]; then
    n="$(H="$heading" awk -F'\t' '$2 == ENVIRON["H"] { n++ } END { print n + 0 }' "$WORK/proj.list")"
    if [[ "$n" -ge 2 ]]; then
      class=ambiguous
    else
      for bid in $base_ids; do
        cmp -s "$WORK/$id" "$WORK/$bid"; rc=$?
        [[ "$rc" -le 1 ]] || die "cmp 오류 (rc=$rc): $id vs $bid"
        [[ "$rc" -eq 0 ]] && { class=template; break; }
      done
      if [[ -z "$class" ]]; then
        if [[ -n "$base_ids" ]]; then class=modified; else class=project; fi
      fi
    fi
  fi

  case "$class" in
    template|modified) ;;
    *) dest="-" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$class" "$start" "$end" "$heading" "$dest" >> "$WORK/out.tsv"
done < "$WORK/proj.list"

cat "$WORK/out.tsv"
printf 'index\t%s\n' "$INDEX"
exit 0
