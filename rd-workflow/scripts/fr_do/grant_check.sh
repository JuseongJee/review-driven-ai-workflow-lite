#!/usr/bin/env bash
# 발행 허가 전 점검. 통과하면 GRANT-OK 와 exit 0, 아니면 HOLD 사유와 exit 1.
# 사용: bash rd-workflow/scripts/fr_do/grant_check.sh <slug>
# 허가 자체(rd publish next)는 이 스크립트가 하지 않습니다.
set -u
slug="${1:?slug 필요}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_state.sh"
ROOT="$(fr_do_main_root)" || exit 1
cd "$ROOT" || exit 1
# 기본 브랜치 판정(get_default_branch)과 충돌 판정(rd_merge_conflicts)은 발행 큐·archive.sh 와 같은 공용 함수를 씁니다.
project_root="$ROOT"
source "$HERE/../lifecycle/_lifecycle_common.sh"
source "$HERE/../lifecycle/_merge_precheck.sh"
hold=()
base="$(get_default_branch 2>/dev/null)" || base=""
# 작업 worktree 는 브랜치 fr/<slug> 의 체크아웃 위치로 찾습니다.
wt="$(fr_do_worktree_of "$slug" 2>/dev/null || true)"
if [[ -n "$wt" && -d "$wt" ]]; then
  st="$(cd "$wt" && bash rd-workflow/scripts/rd task status 2>/dev/null | head -1)"
  [[ "$st" == "아카이브 보류" ]] || hold+=("작업 상태가 '아카이브 보류' 가 아님: ${st:-조회 실패}")
else
  hold+=("worktree 없음: 브랜치 fr/$slug 를 체크아웃한 worktree 가 없습니다")
fi
gd="$(git rev-parse --git-dir)"
[[ -e "$gd/MERGE_HEAD" ]] && hold+=("메인 체크아웃에 병합 진행 중(MERGE_HEAD)")
dirty="$(git status --porcelain --untracked-files=all)"
if [[ -n "$dirty" ]]; then
  msg="메인 체크아웃에 미커밋 변경: $(tr '\n' ' ' <<<"$dirty")"
  grep -q 'rd-workflow-workspace/\.lifecycle/fr-do/' <<<"$dirty" \
    && msg="${msg} — .gitignore 에 rd-workflow-workspace/.lifecycle/fr-do/ 를 더하십시오"
  hold+=("$msg")
fi
# archive.sh 가 자동으로 푸는 파일만 충돌하면 통과입니다(rd_merge_conflicts 가 그 파일을 뺀 충돌만 냅니다).
if [[ -z "$base" ]]; then
  hold+=("충돌 판정 실패 — 기본 브랜치를 정할 수 없습니다. rd-workflow/config/workflow.json 에 \"default_branch\" 를 설정하십시오")
elif ! git -C "$ROOT" rev-parse --verify -q "refs/heads/fr/$slug" >/dev/null; then
  hold+=("충돌 판정 생략 — 로컬 브랜치 fr/$slug 가 없습니다")
else
  mc_rc=0
  bad="$(rd_merge_conflicts "$ROOT" "$base" "fr/$slug")" || mc_rc=$?
  case "$mc_rc" in
    0) ;;
    1) hold+=("자동 해소 대상이 아닌 충돌: $(tr '\n' ' ' <<<"$bad")") ;;
    *) hold+=("충돌 판정 실패 — git merge-tree --write-tree 가 결과를 내지 못했습니다(git 2.38 이상 필요)") ;;
  esac
fi
if [[ ${#hold[@]} -eq 0 ]]; then
  echo "GRANT-OK $slug"
  exit 0
fi
printf 'HOLD %s\n' "$slug"; printf '  - %s\n' "${hold[@]}"
exit 1
