#!/usr/bin/env bash
# followup_check.sh <REQUEST 파일> <ref> [ref...] — 범위 밖 후속의 등록 여부와 흡수 후보를 알린다.
#
# 1. REQUEST 의 주석 밖 `후속 FR: <slug>` 줄을 읽는다. 주어진 ref 중 한 곳이라도
#    backlog/items/YYYY-MM-DD-<slug>.md 가 있으면 등록된 것으로 본다. 기본 브랜치를 ref 로
#    함께 주면, 호출 세션이 기본 브랜치에 먼저 등록한 후속도 등록으로 센다.
# 2. `## Source FR` 의 각 FR 에 대해, 첫 ref 의 dropped item 중 그 FR 을 언급하거나 그 FR
#    상세가 언급하는 항목을 흡수 후보로 나열한다. 흡수는 자유 문장으로 기록되므로 상호 언급으로
#    고른다 — 관련 FR 도 섞일 수 있어 판정이 아니라 확인 안내다.
#
# 경고만 낸다. 발행을 막지 않으며 항상 exit 0 이다(병렬 줄기는 후속을 마감 보고에 적고 호출
# 세션이 발행 뒤 등록한다 — 막으면 그 정상 흐름이 멈춘다). 출력은 stderr, 접두는 RD_FC_PREFIX
# (기본 `followup-check`)다. 후속·흡수 후보가 모두 없으면 아무것도 출력하지 않는다.
set -uo pipefail

P="${RD_FC_PREFIX:-followup-check}"
ITEMS="rd-workflow-workspace/backlog/items"
req="${1:-}"
[[ -n "$req" && -f "$req" ]] || exit 0
shift
(($# > 0)) || exit 0
refs=("$@")
# REQUEST 는 호출 위치 기준 경로다. git 경로는 저장소 최상위 기준이라 그쪽으로 옮긴다.
req="$(cd "$(dirname "$req")" && pwd)/$(basename "$req")"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$top" || exit 0

# 주석 밖 줄만 내보낸다(템플릿의 형식 예시는 주석 안에 있다).
_uncommented() {
  awk '
    inc { if (index($0, "-->")) { inc = 0; sub(/^.*-->/, "") } else next }
    { while ((p = index($0, "<!--")) > 0) {
        q = index(substr($0, p), "-->")
        if (q == 0) { $0 = substr($0, 1, p - 1); inc = 1; break }
        $0 = substr($0, 1, p - 1) substr($0, p + q + 2)
      }
      print }
  ' "$req"
}
body="$(_uncommented)"

# --- 1. 후속 FR ---------------------------------------------------------------
followups="$(awk '
  match($0, /^[[:space:]]*(-[[:space:]]+)?후속 FR:[[:space:]]*/) {
    v = substr($0, RLENGTH + 1); gsub(/`/, "", v)
    split(v, a, /[[:space:],]+/)
    if (a[1] != "" && a[1] != "-") print a[1]
  }' <<<"$body")"

item_listing=()
for r in "${refs[@]}"; do
  item_listing+=("$(git ls-tree --name-only "$r" "$ITEMS/" 2>/dev/null || true)")
done

missing=() bad=() found=0
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  if [[ ! "$s" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then bad+=("$s"); continue; fi
  hit=0
  for l in "${item_listing[@]}"; do
    if grep -Eq "^$ITEMS/[0-9]{4}-[0-9]{2}-[0-9]{2}-$s\.md\$" <<<"$l"; then hit=1; break; fi
  done
  if ((hit)); then found=$((found + 1)); else missing+=("$s"); fi
done <<<"$followups"

if ((${#missing[@]} + ${#bad[@]} > 0)); then
  printf '%s: 후속 FR 확인 — REQUEST 의 「후속 FR:」 항목이 백로그(%s)에 없습니다. 발행은 계속합니다\n' "$P" "$ITEMS" >&2
  for s in ${missing[@]+"${missing[@]}"}; do printf '%s:   - %s (미등록)\n' "$P" "$s" >&2; done
  for s in ${bad[@]+"${bad[@]}"}; do printf '%s:   - %s (slug 형식이 아님 — 소문자·숫자·하이픈만)\n' "$P" "$s" >&2; done
  printf '%s:   /fr add 로 등록하거나, 등록을 맡을 세션에 넘기십시오\n' "$P" >&2
elif ((found > 0)); then
  printf '%s: 후속 FR 확인 — 「후속 FR:」 %d건이 모두 백로그에 있습니다\n' "$P" "$found" >&2
fi

# --- 2. 흡수 후보 -------------------------------------------------------------
sources="$(awk '
  /^## Source FR/ { s = 1; next }
  s && /^## / { exit }
  s { l = $0; gsub(/`/, "", l); sub(/^[[:space:]]*-[[:space:]]+/, "", l); gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
      if (l != "" && l != "-") print l }' <<<"$body")"
[[ -n "$sources" ]] || exit 0

r0="${refs[0]}"
dropped="$(git grep -l -E '^- status: dropped[[:space:]]*$' "$r0" -- "$ITEMS/" 2>/dev/null | sed "s|^$r0:||" || true)"
[[ -n "$dropped" ]] || exit 0

_slug_of() { local b="${1##*/}"; b="${b%.md}"; [[ "$b" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.+)$ ]] && b="${BASH_REMATCH[1]}"; printf '%s' "$b"; }
# slug 를 단어로 언급하는가 — `foo` 가 `foo-bar`·`bar-foo` 에 걸리지 않게 앞뒤가 slug 문자가 아니어야 한다.
# 앞쪽은 FR 파일명의 날짜 접두(`2026-11-01-foo.md`, `items/…-foo.md` 링크)도 경계로 인정한다.
_mention_re() { printf '(^|[^a-z0-9-]|[0-9]{4}-[0-9]{2}-[0-9]{2}-)%s([^a-z0-9-]|$)' "$1"; }
_mentions() { grep -Eq "$(_mention_re "$2")" <<<"$1"; }

while IFS= read -r src; do
  [[ -n "$src" ]] || continue
  ss="$(_slug_of "$src")"
  [[ "$ss" =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
  src_body="$(git show "$r0:$ITEMS/${src##*/}" 2>/dev/null || true)"
  # Source FR 을 언급하는 item 은 git grep 한 번으로 고른다(dropped 수만큼 git show 하지 않는다).
  mention_src="$(git grep -l -E "$(_mention_re "$ss")" "$r0" -- "$ITEMS/" 2>/dev/null | sed "s|^$r0:||" || true)"
  cands=()
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    ds="$(_slug_of "$d")"
    [[ "$ds" == "$ss" ]] && continue
    if grep -qxF -- "$d" <<<"$mention_src" || { [[ -n "$src_body" ]] && _mentions "$src_body" "$ds"; }; then
      cands+=("$ds ($d)")
    fi
  done <<<"$dropped"
  if ((${#cands[@]} > 0)); then
    printf '%s: 흡수 확인 — Source FR %s 와 서로 언급하는 dropped FR 이 있습니다. 발행은 계속합니다\n' "$P" "$ss" >&2
    for c in "${cands[@]}"; do printf '%s:   - %s\n' "$P" "$c" >&2; done
    printf '%s:   흡수된 범위 중 이번 작업이 처리하지 않은 부분이 있으면 후속 FR 로 등록하십시오\n' "$P" >&2
  fi
done <<<"$sources"
exit 0
