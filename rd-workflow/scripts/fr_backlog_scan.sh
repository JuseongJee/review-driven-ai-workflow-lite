#!/usr/bin/env bash
# fr_backlog_scan.sh — 미병합 브랜치(로컬·remote-tracking)에 기본 브랜치에 없는 backlog 추가 파일이 있는지 대조한다.
#   fetch 하지 않는다(현존 refs 만). 제외: 기본 브랜치, 그 upstream, 각 remote 의 <remote>/<기본 브랜치>,
#   <remote>/HEAD 와 그 symbolic 대상. 같은 tip 은 한 묶음. 기본 브랜치에 같은 경로가 **같은 내용**으로 있으면(회수·done) 보고하지 않고,
#   같은 경로가 **다른 내용**이면 '내용 다름' 후보로 보고한다. 공통 조상이 없는 ref(orphan) 는 빈 트리 기준으로 대조한다.
#   exit 0 (후보 있음/없음 모두) / 3 (기본 브랜치 ref 부재, 또는 ref 판정 중 git 오류 — 이때도 판정된 후보는 함께 출력한다).
#   start_preflight.sh 가 호출하며 단독 실행도 가능.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lifecycle/_lifecycle_common.sh"
cd "$project_root" || exit 3
BACKLOG="rd-workflow-workspace/backlog"
default="$(get_default_branch 2>/dev/null)" || { echo "scan: 기본 브랜치를 판정할 수 없습니다" >&2; exit 3; }
git rev-parse -q --verify "refs/heads/${default}^{commit}" >/dev/null 2>&1 || { echo "scan: 기본 브랜치 ref 가 없습니다: $default" >&2; exit 3; }
DEF="refs/heads/$default"
EMPTY_TREE="$(git hash-object -t tree /dev/null)"

excl="$DEF"$'\n'
u="$(git rev-parse --symbolic-full-name "${default}@{upstream}" 2>/dev/null || true)"
[[ -n "$u" ]] && excl="${excl}${u}"$'\n'
while IFS= read -r r; do
  [[ -n "$r" ]] || continue
  excl="${excl}refs/remotes/$r/$default"$'\n'"refs/remotes/$r/HEAD"$'\n'
  h="$(git symbolic-ref -q "refs/remotes/$r/HEAD" 2>/dev/null || true)"
  [[ -n "$h" ]] && excl="${excl}${h}"$'\n'
done <<EOF
$(git remote 2>/dev/null)
EOF
# remote 등록 없이 refs/remotes/* 만 있는 경우도 HEAD symbolic 대상을 제외한다
while IFS= read -r hd; do
  [[ -n "$hd" ]] || continue
  excl="${excl}${hd}"$'\n'
  h="$(git symbolic-ref -q "$hd" 2>/dev/null || true)"
  [[ -n "$h" ]] && excl="${excl}${h}"$'\n'
done <<EOF
$(git for-each-ref --format='%(refname)' 'refs/remotes/*/HEAD' 2>/dev/null)
EOF
is_excluded() { case "$excl" in *"$1"$'\n'*) return 0 ;; esac; return 1; }

errors=0; errlines=""
# ref 열거 자체의 실패도 오류로 집계한다 — heredoc 안 command substitution 은 rc 를 버리므로 먼저 따로 캡처한다.
refs_out="$(git for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes 2>/dev/null)"; refs_rc=$?
if [[ $refs_rc -ne 0 ]]; then errors=$((errors+1)); errlines="${errlines}  오류: git for-each-ref rc=${refs_rc} — 일부 ref 를 보지 못했을 수 있습니다"$'\n'; fi
tips=(); names=()
while read -r ref sha; do
  [[ -n "$ref" ]] || continue
  is_excluded "$ref" && continue
  git merge-base --is-ancestor "$sha" "$DEF" 2>/dev/null; rc=$?
  if [[ $rc -eq 0 ]]; then continue
  elif [[ $rc -gt 1 ]]; then errors=$((errors+1)); errlines="${errlines}  오류: ${ref} merge-base --is-ancestor rc=${rc}"$'\n'; continue; fi
  short="${ref#refs/heads/}"; short="${short#refs/remotes/}"
  found=-1; i=0
  for t in ${tips[@]+"${tips[@]}"}; do [[ "$t" == "$sha" ]] && found=$i; i=$((i+1)); done
  if [[ $found -ge 0 ]]; then names[$found]="${names[$found]} $short"; else tips+=("$sha"); names+=("$short"); fi
done <<EOF
$refs_out
EOF

cand=0; other=0; blocks=""; i=0
for sha in ${tips[@]+"${tips[@]}"}; do
  mb="$(git merge-base "$sha" "$DEF" 2>/dev/null)"; rc=$?
  if [[ $rc -eq 1 ]]; then mb="$EMPTY_TREE"           # 공통 조상 없음(orphan) → 빈 트리 기준
  elif [[ $rc -gt 1 ]]; then errors=$((errors+1)); errlines="${errlines}  오류: ${names[$i]} merge-base rc=${rc}"$'\n'; i=$((i+1)); continue; fi
  added="$(git diff --name-only --diff-filter=A "$mb" "$sha" -- "$BACKLOG/" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 ]]; then errors=$((errors+1)); errlines="${errlines}  오류: ${names[$i]} diff rc=${rc}"$'\n'; i=$((i+1)); continue; fi
  block=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    note=""
    if git cat-file -e "${DEF}:${p}" 2>/dev/null; then
      [[ "$(git rev-parse "${DEF}:${p}")" == "$(git rev-parse "${sha}:${p}")" ]] && continue   # 같은 내용으로 회수됨
      note=" — 기본 브랜치에 같은 경로가 다른 내용으로 존재(내용 다름)"
    fi
    case "$p" in
      "$BACKLOG"/items/*.md)
        b="$(basename "$p" .md)"; slug="${b#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}"
        if git show "${sha}:${BACKLOG}/FUTURE_REQUESTS.md" 2>/dev/null | grep -q "| ${slug} |"; then rowtxt="있음"; else rowtxt="없음"; fi
        d="$(git log -1 --format=%cs "$sha" -- "$p" 2>/dev/null || true)"
        block="${block}  FR ${slug} (인덱스 행 ${rowtxt}, 마지막 커밋 ${d})${note}"$'\n'; cand=$((cand+1)) ;;
      *) block="${block}  기타: ${p}${note}"$'\n'; other=$((other+1)) ;;
    esac
  done <<EOF
$added
EOF
  [[ -n "$block" ]] && blocks="${blocks}- ${names[$i]} (tip ${sha:0:8})"$'\n'"${block}"
  i=$((i+1))
done
nref="$(printf '%s' "$blocks" | grep -c '^- ' || true)"
suffix=""; [[ "$errors" -eq 0 ]] || suffix=" (검사 오류 ${errors}건 — 일부 ref 판정 불능)"
printf 'scan: candidates=%s refs=%s errors=%s\n' "$cand" "$nref" "$errors"
if [[ "$cand" -eq 0 && "$other" -eq 0 ]]; then printf '미병합 브랜치 FR 후보: 없음%s\n%s' "$suffix" "$errlines"
elif [[ "$cand" -eq 0 ]]; then printf '미병합 브랜치 FR 후보: 없음 (기타 backlog 추가 파일 %s개)%s\n%s%s' "$other" "$suffix" "$blocks" "$errlines"
else printf '미병합 브랜치 FR 후보: %s건%s\n%s%s' "$cand" "$suffix" "$blocks" "$errlines"; fi
[[ "$errors" -eq 0 ]] && exit 0 || exit 3
