#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
cd "${project_root}"

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "사용법: bash rd-workflow/scripts/init_review_pipeline.sh <session-slug> <review-type> [review-target] [review-goal]" >&2
  echo "예: bash rd-workflow/scripts/init_review_pipeline.sh image-compression-spec spec-plan-review rd-workflow-workspace/specs/changes/2026-03-12-image-compression-change-spec.md \"spec / plan 검토\"" >&2
  exit 1
fi

session_slug="$1"
review_type="$2"
review_target="${3:--}"
review_goal="${4:--}"
turn_limit="${REVIEW_TURN_LIMIT:-20}"

to_safe_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9._-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

safe_slug="$(to_safe_slug "$session_slug")"

if [[ -z "$safe_slug" ]]; then
  safe_slug="review-session"
fi

# 세션 이름은 <시각>_<세션 slug> 입니다. fr 브랜치에서는 시각과 세션 slug 사이에 작업 slug 를 넣습니다.
# 이유: REQUEST·final diff·PROJECT_CONTEXT review 의 세션 slug 는 고정 값이라, 병렬 줄기가 같은 초에
# 세션을 열면 이름이 같아지고 나중에 병합하는 쪽이 add/add 충돌로 멈춥니다. 작업 slug 는 fr 브랜치
# 이름에서 읽으므로 줄기끼리 겹치지 않습니다.
# 이름 끝(`_final-diff-review` 등)과 앞 15자 시각은 그대로 둡니다. 커밋 가드의 `*_final-diff-review` glob 과
# review_common.sh 의 시각 해석이 이 형식에 기댑니다. promote 의 문서 이관(lifecycle/promote.sh `_carry_name_ok`)은
# spec/plan 세션 이름을 정규식으로 읽으므로, 이 형식을 바꾸면 그 정규식도 함께 고칩니다.
# 기본 체크아웃·detached HEAD 의 세션과, 자기 plan 의 spec/plan review 세션(정확히 `<HHMM>-<작업 slug>-spec-plan-review`)은 그대로입니다.
# 브랜치는 전체 ref 로 읽습니다. `--short` 는 같은 이름의 태그가 있으면 `heads/fr/<slug>` 를 내어 fr 판정을 놓칩니다.
task_slug=""
current_ref="$(git symbolic-ref --quiet HEAD 2>/dev/null)" || current_ref=""
if [[ "$current_ref" == refs/heads/fr/* ]]; then
  task_slug="$(to_safe_slug "${current_ref#refs/heads/fr/}")"
fi

timestamp="$(date '+%Y%m%d_%H%M%S')"
if [[ -n "$task_slug" && "$safe_slug" != [0-9][0-9][0-9][0-9]-"${task_slug}"-spec-plan-review ]]; then
  session_id="${timestamp}_${task_slug}_${safe_slug}"
else
  session_id="${timestamp}_${safe_slug}"
fi
session_dir="rd-workflow-workspace/handoffs/review_pipeline/${session_id}"

mkdir -p "${session_dir}/turns"

# 아래 SESSION.md 의 "## Turn Limit" 줄은 정본 형식이다:
#   <N> total turns in `turns/*.md`
# review_common.sh:parse_turn_limit_line 이 이 형식을 anchored regex 로 파싱한다.
# 이 형식을 바꾸면 parse_turn_limit_line 의 정규식과 test_lifecycle.sh 단위 테스트를 함께 갱신할 것.
cat <<EOF > "${session_dir}/SESSION.md"
# Review Session

## Session ID
${session_id}

## Topic
${session_slug}

## Review Type
${review_type}

## Review Target
${review_target}

## Review Goal
${review_goal}

## Status
awaiting-author

## Closure Reason
<!-- 비워 두면 seal 이 실행 기록으로 판정합니다. 손으로 고치지 않습니다. 사람이 리뷰어의 남은 이의를 덮고 종결하기로 정하면 bash rd-workflow/scripts/run_review_turn.sh <세션> --override "<결정한 사람> — <그 사람이 한 말>" 을 실행합니다. 이 명령이 user-override 와 '근거:' 줄을 적고 Status 를 closed 로 바꿉니다. 허용 값: reviewer-no-objection | user-override -->
-

## Current Owner
Author

## Turn Limit
${turn_limit} total turns in \`turns/*.md\`

## Stop Rule
- 기본값: 최신 Reviewer 턴이 \`이의 없음\`을 명시할 때까지 Author와 Reviewer가 번갈아 검토한다.
- Author는 Reviewer 지적에 답한 뒤 최신 Reviewer 재확인 없이 \`awaiting-user\`로 넘기지 않는다.
- 추가 진행 전에 사람 결정이 필요하면 \`awaiting-user\`로 전환한다.
- 총 턴 수가 ${turn_limit}에 도달하면 더 이상 다음 턴을 만들지 않고 \`awaiting-user\`로 전환한다.

## Finalize Rule
- Reviewer 는 자기 턴을 마칠 때 Status·Current Owner 를 갱신한다. Author 와 사람은 Status·Current Owner·Closure Reason 을 손으로 고치지 않고 \`run_review_turn.sh\` 로 잇는다.
  - Author 턴 뒤 Reviewer 에게 넘길 때는 옵션 없이 실행한다.
  - 미해결 이의가 남은 \`awaiting-user\` 세션에 사람이 결정했으면 결정을 반영한 Author 턴을 쓰고 \`--decision "<사용자 결정>"\` 으로 Reviewer 턴을 받는다.
  - 이의 없음으로 수렴한 \`awaiting-user\` 세션을 다시 확인하려면 바뀐 내용을 Author 턴으로 쓰고 \`--reopen "<사유>"\` 로 다시 연다.
  - 미해결 이의가 남은 \`awaiting-user\` 세션에서 사람이 남은 이의를 덮고 종결하기로 정했을 때만 \`--override "<결정한 사람> — <그 사람이 한 말>"\` 로 \`closed\` 로 바꾼다.
  - 다음 Reviewer 턴이 턴 한도를 넘어 \`run_review_turn.sh\` 가 거부하면 사람이 정한 연장 폭 \`--extend-turns <N>\` 을 옵션 없는 실행·\`--decision\`·\`--reopen\` 에 함께 붙인다. \`--override\` 에는 붙이지 않는다.
  - \`closed\` 세션은 다시 열지 않는다. 종결 뒤 재확인은 Author 턴을 쓰기 전에 새 세션을 만들어 한다.
- 턴 제한 때문에 \`awaiting-user\`가 되면 \`USER_ACTION.md\`에 남은 이의와 다음 선택지를 적는다.
- \`awaiting-user\` 상태에서는 \`USER_ACTION.md\`에 질문을 남기고 멈춘다.
EOF

cat <<EOF > "${session_dir}/CHECKPOINT.md"
# Review Checkpoint

## Current Summary
-

## Agreed Points
-

## Open Issues
<!-- 미해결 항목은 리스트로 적는다. 미해결이 없으면 이 절의 첫 줄에 \`- 없음\` 또는 \`- None\` 을 둔다 (후행 마침표 1개 허용). -->
<!-- 종결 경위는 그 아래에 빈 줄로 한 번 띄우고 문단으로 적는다 — 마커에 붙이거나 마커 앞에 적으면 미해결로 판정된다. -->
-

## Questions For Next Agent
-

## Suggested Next Owner
Author
EOF

cat <<EOF > "${session_dir}/USER_ACTION.md"
# User Action

## Current Recommendation
-

## Why
-

## Question For User
아직 사용자 확인이 필요한 단계가 아닙니다.
EOF

# 리뷰 모델이 계열 최신이 아니면 stderr 로 알린다. 알림 실패가 세션 생성을 막지 않는다.
if source "${script_dir}/model_select.sh" 2>/dev/null; then
  ms_codex_stale_notice "$review_type" || true
fi

echo "${session_dir}"
