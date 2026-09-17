#!/usr/bin/env bash
# start_preflight.sh [--no-fetch] — 작업 시작 계약(WORKFLOW.md 4항) 진입점. 비변경(fetch 외 상태 변경 없음).
#   fetch(원격 모드) → 기본 브랜치 vs upstream 분류(classify_ahead_commits, 등록 커밋만 ahead 면 auto-adopt)
#   → 미병합 브랜치 backlog 대조(fr_backlog_scan.sh) → 시작 보고 블록에 옮겨 적을 줄을 출력한다.
#   exit 0 진행 가능 / 10 인계 / 3 판정 불능. light 는 exit 10 이어도 진행하되 push 를 보류한다(WORKFLOW.md).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lifecycle_common.sh"
NO_FETCH=0; [[ "${1:-}" == "--no-fetch" ]] && NO_FETCH=1
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "preflight: git 저장소가 아닙니다" >&2; exit 3; }
cd "$root" || exit 3
project_root="$root"
default="$(get_default_branch 2>/dev/null)" || { echo "preflight: 기본 브랜치를 판정할 수 없습니다" >&2; exit 3; }
mode="$(detect_remote_mode)"
fetch=skipped
up="$(git rev-parse --symbolic-full-name "${default}@{upstream}" 2>/dev/null || true)"
if [[ "$mode" == "remote" && $NO_FETCH -eq 0 ]]; then
  remote="${up#refs/remotes/}"; remote="${remote%%/*}"; [[ -n "$remote" ]] || remote=origin
  if git fetch -q "$remote" >/dev/null 2>&1; then fetch=ok; else fetch=failed; fi
fi
if [[ "$mode" == "remote" ]]; then
  cls="$(classify_ahead_commits "refs/heads/$default" "$up")" || { echo "preflight: ahead 분류 실패" >&2; exit 3; }
else
  cls="ahead=0 behind=0 registration=0 decision=local-only"
fi
ahead="${cls#ahead=}"; ahead="${ahead%% *}"
behind="${cls#*behind=}"; behind="${behind%% *}"
reg="${cls#*registration=}"; reg="${reg%% *}"
decision="${cls##*decision=}"
[[ "$fetch" == "failed" ]] && decision=handover-fetch-failed
cls="ahead=${ahead} behind=${behind} registration=${reg} decision=${decision}"   # 첫 줄에도 최종 decision 을 싼다(첫 줄만 읽는 소비자가 stale 판정을 진행으로 오독하지 않게)
case "$decision" in
  local-only) push="없음"; rc=0 ;;
  synchronized) push="archive.sh 경유"; rc=0 ;;
  auto-adopt) push="archive.sh 경유(기본 브랜치 미push ${ahead}개 — 전부 FR 등록 커밋, 자동 채택)"; rc=0 ;;
  handover-ahead) push="인계(사유: 기본 브랜치 미push ${ahead}개 중 FR 등록 커밋 아님 $((ahead - reg))개 — 사용자 명시 채택 필요)"; rc=10 ;;
  handover-behind) push="인계(사유: 기본 브랜치가 upstream 보다 ${behind}개 뒤처짐)"; rc=10 ;;
  handover-diverged) push="인계(사유: 기본 브랜치와 upstream 이 갈라짐 — ahead ${ahead} / behind ${behind})"; rc=10 ;;
  handover-fetch-failed) push="인계(사유: fetch 실패 — 미push 수 판정 실패)"; rc=10 ;;
  no-upstream) push="인계(사유: upstream 부재)"; rc=10 ;;
  *) push="인계(사유: 판정 불능 $decision)"; rc=10 ;;
esac
scan_out="$(bash "$SCRIPT_DIR/../fr_backlog_scan.sh" 2>&1)"; scan_rc=$?
# rc 3 이어도 스캐너가 후보 줄(2행 이상)을 냈으면 그대로 보인다(검사 오류 접미 포함). 첫 줄만 있으면 판정 불능이다.
if [[ $scan_rc -eq 0 || "$(printf '%s\n' "$scan_out" | grep -c .)" -ge 2 ]]; then scan_lines="$(printf '%s\n' "$scan_out" | sed 1d)"
else scan_lines="미병합 브랜치 FR 후보: 검사 실패 — $(printf '%s\n' "$scan_out" | sed -n 1p)"; fi
printf 'preflight: default=%s mode=%s fetch=%s %s\n' "$default" "$mode" "$fetch" "$cls"
printf 'push 예정: %s\n' "$push"
printf '%s\n' "$scan_lines"
exit "$rc"
