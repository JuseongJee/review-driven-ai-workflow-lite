#!/usr/bin/env bash
# 발행을 마친 줄기 정리: 기본 체크아웃 갱신 → 작업 탭 닫기 → rd task list(worktree·브랜치 정리) → 판정 → CLOSED 면 감시 목록에서 빼기.
# CLOSED 면 reports/<slug>-question.md·<slug>-closing.md 를 waves/closed/<slug>-<YYYYMMDD-HHMM>-<종류>.md 로 옮깁니다(같은 slug 재사용 시 옛 보고 오판 방지).
# 사용: bash rd-workflow/scripts/fr_do/close.sh <slug>
# 탭은 promote 가 이 줄기용으로 띄운 것만 닫습니다(이름이 fr_do_agent_name <slug> 인 herdr agent — 32자 초과 slug 는 잘린 이름).
set -u
slug="${1:?slug 필요}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_state.sh"
ROOT="$(fr_do_main_root)" || exit 1
cd "$ROOT" || exit 1
STATE="$(fr_do_state_dir)" || exit 1
LIST="$STATE/active.tsv"
if [[ -n "$(git remote)" ]]; then
  git pull -q --ff-only || { echo "NOT-CLOSED $slug (git pull --ff-only 실패)"; exit 1; }
fi
tab="$(herdr agent get "$(fr_do_agent_name "$slug")" </dev/null 2>/dev/null | python3 -I -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["agent"]["tab_id"])
except Exception: pass')"
if [[ -n "$tab" ]]; then herdr tab close "$tab" </dev/null >/dev/null && echo "탭 닫음: $slug"; else echo "탭 없음: $slug"; fi
bash rd-workflow/scripts/rd task list </dev/null 2>&1 | grep -E "정리|보류|진행 중" || true
if [[ -z "$(fr_do_worktree_of "$slug" 2>/dev/null || true)" ]] && ! git show-ref --verify --quiet "refs/heads/fr/$slug"; then
  if [[ -f "$LIST" ]]; then
    awk -F'\t' -v s="$slug" '$1!=s' "$LIST" > "$LIST.tmp.$$" && mv "$LIST.tmp.$$" "$LIST"
  fi
  stamp="$(date +%Y%m%d-%H%M)"
  for kind in question closing; do
    src="$STATE/reports/$slug-$kind.md"
    [[ -f "$src" ]] || continue
    mkdir -p "$STATE/waves/closed"
    dst="$STATE/waves/closed/$slug-$stamp-$kind.md"; n=2
    while [[ -e "$dst" ]]; do dst="$STATE/waves/closed/$slug-$stamp-$kind-$n.md"; n=$((n + 1)); done
    mv "$src" "$dst" && echo "보고 보관: $dst"
  done
  echo "감시 중: $(cut -f1 "$LIST" 2>/dev/null | tr '\n' ' ')"
  echo "CLOSED $slug"
else
  echo "감시 중: $(cut -f1 "$LIST" 2>/dev/null | tr '\n' ' ')"
  echo "NOT-CLOSED $slug (worktree 또는 로컬 브랜치 fr/$slug 가 남음)"; exit 1
fi
