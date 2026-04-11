#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
cd "${project_root}"

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "사용법: bash ai/scripts/init_review_pipeline.sh <session-slug> <review-type> [review-target] [review-goal]" >&2
  echo "예: bash ai/scripts/init_review_pipeline.sh image-compression-spec spec-plan-review ai/workspace/specs/changes/2026-03-12-image-compression-change-spec.md \"spec / plan 검토\"" >&2
  exit 1
fi

session_slug="$1"
review_type="$2"
review_target="${3:--}"
review_goal="${4:--}"
turn_limit="${REVIEW_TURN_LIMIT:-20}"

safe_slug="$(
  printf '%s' "$session_slug" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9._-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
)"

if [[ -z "$safe_slug" ]]; then
  safe_slug="review-session"
fi

timestamp="$(date '+%Y%m%d_%H%M%S')"
session_id="${timestamp}_${safe_slug}"
session_dir="ai/workspace/handoffs/review_pipeline/${session_id}"

mkdir -p "${session_dir}/turns"

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
- 사람이 "마무리"를 승인하기 전에는 \`closed\`로 바꾸지 않는다.
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

echo "${session_dir}"
