#!/usr/bin/env bash
# 발행을 마친 줄기 정리: 기본 체크아웃 갱신 → 작업 탭 닫기 → rd task list(worktree·브랜치 정리) → 판정 → CLOSED 면 감시 목록에서 빼기.
# CLOSED 면 reports/<slug>-question.md·<slug>-closing.md 를 waves/closed/<slug>-<YYYYMMDD-HHMM>-<종류>.md 로 옮깁니다(같은 slug 재사용 시 옛 보고 오판 방지).
# 사용: bash rd-workflow/scripts/fr_do/close.sh <slug> [--stale]
#   --stale: pick.py 의 stale 줄(낡은 감시 목록 줄) 정리용. 로컬 브랜치 fr/<slug> 가 다시 있으면 낡은 줄이 아니므로
#            worktree·목록을 건드리지 않고 NOT-CLOSED 로 끝냅니다. 탭은 닫지 않습니다. 탭은 에이전트 이름으로만 찾으므로
#            같은 이름을 쓰는 다른 줄기(다른 체크아웃 포함)의 탭일 수 있고, 낡은 줄기의 세션은 이미 끝나 있습니다
#            (롤백은 살아 있는 세션을 거부하고, 발행 뒤 탭은 rd task list 정리가 소유를 확인해 닫음).
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
# --stale 은 git pull 뒤, 목록·worktree 정리 전에 확인합니다. git pull 이 도는 동안 브랜치가 다시 생겨도 잡습니다.
if [[ "${2:-}" == --stale ]] && git show-ref --verify --quiet "refs/heads/fr/$slug"; then
  echo "NOT-CLOSED $slug (로컬 브랜치 fr/$slug 가 다시 있음 — 낡은 줄이 아니라 정리하지 않음)"; exit 1
fi
if [[ "${2:-}" == --stale ]]; then
  echo "탭 건드리지 않음: $slug (낡은 줄 정리)"
else
  tab="$(herdr agent get "$(fr_do_agent_name "$slug")" </dev/null 2>/dev/null | python3 -I -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["agent"]["tab_id"])
except Exception: pass')"
  if [[ -n "$tab" ]]; then herdr tab close "$tab" </dev/null >/dev/null && echo "탭 닫음: $slug"; else echo "탭 없음: $slug"; fi
fi
# rd task list 는 저장소 전체의 정리 대기 작업을 정리하고, 다른 작업의 탭을 닫으면 「탭 닫음: <그 작업>」 을 냅니다. 그 줄도 넘깁니다.
bash rd-workflow/scripts/rd task list </dev/null 2>&1 | grep -E "정리|보류|진행 중|탭 닫음" || true
if [[ -z "$(fr_do_worktree_of "$slug" 2>/dev/null || true)" ]] && ! git show-ref --verify --quiet "refs/heads/fr/$slug"; then
  if [[ -f "$LIST" ]]; then
    # 문자열로 비교합니다. awk 는 숫자 모양 값끼리 숫자로 비교해 01 과 1 을 같게 봅니다.
    awk -F'\t' -v s="$slug" '($1 "") != (s "")' "$LIST" > "$LIST.tmp.$$" && mv "$LIST.tmp.$$" "$LIST"
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
