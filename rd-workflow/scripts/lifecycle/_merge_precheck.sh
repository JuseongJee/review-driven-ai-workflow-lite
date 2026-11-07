#!/usr/bin/env bash
# _merge_precheck.sh — 병합 충돌 사전 판정 공용 함수 (source 전용).
#   archive.sh 와 publish_queue.sh 가 같이 쓴다. 다른 파일을 source 하지 않는다.
#   set -euo pipefail 아래에서 source 돼도 안전하다(실패 가능한 대입은 `|| rc=$?`).
#   Spec: rd-workflow-workspace/specs/changes/2026-11-04-2100-lifecycle-pipe-merge-check-change-spec.md (D3)

# 병합 자동 해소 대상 네 파일(줄바꿈 구분). archive.sh 병합 단계의 자동 해소 분기가 이 순서로 꺼내 쓴다.
RD_MERGE_AUTO_RESOLVE_PATHS="CURRENT_TASK.md
rd-workflow-workspace/.lifecycle/stage_metrics.tsv
rd-workflow-workspace/backlog/FUTURE_REQUESTS.md
rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"

# rd_merge_conflicts <repo-dir> <ours> <theirs>
#   stdout: 자동 해소 대상이 아닌 충돌 경로(정렬, 중복 없음, 한 줄에 하나, 인용 없음)
#   rc 0 충돌 없음(또는 자동 해소 대상만 충돌) / 1 그 밖의 충돌 / 3 판정 불가(인자 빔 포함)
#   merge-tree 는 -z 로 받아 경로 인용(core.quotePath)을 피하고, NUL 경계를 지킨 채 경로 하나씩 읽는다.
#   줄바꿈을 품은 경로는 자동 해소 대상과 비교하지 않고 충돌로 잡는다. 표시는 줄바꿈을 `\n` 두 글자로 바꾼다
#   (줄바꿈으로 바꾸면 조각이 자동 해소 대상과 맞아 실제 충돌을 빼 버린다 — final diff review F1).
#   잘못된 ref 에도 merge-tree 가 rc 1 을 내므로, 충돌 판정은 첫 항목(트리 OID)이 있을 때만 인정한다.
rd_merge_conflicts() {
  local dir="${1:-}" ours="${2:-}" theirs="${3:-}" tmp rc=0 p a auto keep="" first=1 tree=""
  [[ -n "$dir" && -n "$ours" && -n "$theirs" ]] || return 3
  tmp="$(mktemp)" || { echo "rd_merge_conflicts: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 3; }
  [[ -n "$tmp" && -f "$tmp" ]] || { echo "rd_merge_conflicts: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 3; }
  git -C "$dir" merge-tree --write-tree --name-only --no-messages -z "$ours" "$theirs" >"$tmp" 2>/dev/null || rc=$?
  case "$rc" in
    0) rm -f "$tmp"; return 0 ;;
    1) ;;
    *) rm -f "$tmp"; return 3 ;;
  esac
  while IFS= read -r -d '' p; do
    if [[ "$first" -eq 1 ]]; then first=0; tree="$p"; continue; fi
    [[ -n "$p" ]] || continue
    if [[ "$p" == *$'\n'* ]]; then keep="${keep}${p//$'\n'/\\n}"$'\n'; continue; fi
    auto=0
    while IFS= read -r a; do [[ "$p" == "$a" ]] && auto=1; done <<EOF2
$RD_MERGE_AUTO_RESOLVE_PATHS
EOF2
    [[ "$auto" -eq 1 ]] || keep="${keep}${p}"$'\n'
  done <"$tmp"
  rm -f "$tmp"
  [[ -n "$tree" ]] || return 3
  [[ -z "$keep" ]] && return 0
  # LC_ALL=C: UTF-8 이 아닌 바이트 경로에서 sort 가 「Illegal byte sequence」 로 실패해 목록이 비지 않게 한다.
  printf '%s' "$keep" | LC_ALL=C sort -u
  return 1
}

# rd_merge_conflict_guide <prefix> <fr-branch> <default-branch> <fr-worktree>
#   stdout: 해소 절차 안내 6줄(첫 줄은 prefix 바로 뒤, 단계 줄은 prefix 뒤 2칸 들여쓰기). 출력 위치는 호출부가 정한다.
#   <fr-branch> 는 호출부 문맥용이며 문구에는 쓰지 않는다(안내는 작업 worktree 안에서 실행하는 절차다).
rd_merge_conflict_guide() {
  local pre="${1:-}" def="${3:-}" wt="${4:-}"
  [[ -n "$def" ]] || def="<기본 브랜치>"
  [[ -n "$wt" ]] || wt="<작업 worktree>"
  printf '%s리뷰한 코드와 %s 의 변경을 합친 결과는 리뷰를 거쳐야 발행할 수 있습니다. 작업 worktree(%s)에서:\n' "$pre" "$def" "$wt"
  printf '%s  1. bash rd-workflow/scripts/rd task set-status "구현 중"\n' "$pre"
  printf '%s  2. git merge %s   — 충돌을 풀고 커밋합니다\n' "$pre" "$def"
  printf '%s  3. bash rd-workflow/scripts/rd task set-status "검증 중" 후 검증, bash rd-workflow/scripts/verify_record.sh -- <검증 명령>\n' "$pre"
  printf '%s  4. bash rd-workflow/scripts/rd task set-status "diff review 대기" 후 새 final diff review 세션을 종결합니다\n' "$pre"
  printf '%s  5. bash rd-workflow/scripts/rd review seal <새 세션> → set-status "아카이브 보류" → 기록 커밋 → 다시 발행\n' "$pre"
}
