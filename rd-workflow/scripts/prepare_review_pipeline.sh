#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
cd "${project_root}"

turn_limit="${REVIEW_TURN_LIMIT:-20}"

usage() {
  cat <<'EOF' >&2
사용법:
  bash rd-workflow/scripts/prepare_review_pipeline.sh <review-kind> [args...]

review-kind:
  project-context
  request
  spec-plan [spec-path] [plan-path]
  output

예:
  bash rd-workflow/scripts/prepare_review_pipeline.sh project-context
  bash rd-workflow/scripts/prepare_review_pipeline.sh request
  bash rd-workflow/scripts/prepare_review_pipeline.sh spec-plan
  bash rd-workflow/scripts/prepare_review_pipeline.sh spec-plan rd-workflow-workspace/specs/changes/2026-03-12-campaign-plan-change-spec.md rd-workflow-workspace/plans/2026-03-12-campaign-plan-plan.md
  bash rd-workflow/scripts/prepare_review_pipeline.sh output
EOF
}

read_current_task_field() {
  local field="$1"
  local task_file="${project_root}/CURRENT_TASK.md"
  [[ -f "$task_file" ]] || return 1
  local value
  value="$(awk -v target="## ${field}" '
    $0 == target { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && NF { print; exit }
  ' "$task_file")"
  [[ -n "$value" && "$value" != "-" ]] || return 1
  [[ -f "$value" ]] || return 1
  printf '%s\n' "$value"
}

file_mtime() {
  local file="$1"
  stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo 0
}

latest_markdown_file() {
  local latest_file=""
  local latest_mtime=0
  local dir file mtime

  for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r file; do
      mtime="$(file_mtime "$file")"
      if [[ -z "$latest_file" || "$mtime" -gt "$latest_mtime" ]]; then
        latest_file="$file"
        latest_mtime="$mtime"
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null)
  done

  [[ -n "$latest_file" ]] || return 1
  printf '%s\n' "$latest_file"
}

derive_task_slug() {
  local input="$1"
  local base="${input##*/}"

  base="${base%.md}"
  base="${base#????-??-??-}"
  base="${base%-change-spec}"
  base="${base%-spec}"
  base="${base%-plan}"
  base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9._-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"

  if [[ -z "$base" ]]; then
    base="review"
  fi

  printf '%s\n' "$base"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

review_kind="$1"
shift || true

session_slug=""
review_type=""
review_target=""
review_goal=""

case "$review_kind" in
  project-context|project-context-review)
    review_type="project-context-review"
    session_slug="project-context-review"
    review_target="PROJECT_CONTEXT.md"
    review_goal="\`rd-workflow/docs/prompts/review/project_context_review.md\` 기준으로 품질 기준, 대상, 제약 조건 등 프로젝트 규칙이 실행 입력으로 충분한지 점검"
    ;;
  request|request-review)
    review_type="request-review"
    session_slug="request-review"
    review_target="REQUEST.md"
    review_goal="\`rd-workflow/docs/prompts/review/request_review.md\` 기준으로 제약, 완료 조건, 산출물 유형, 위험 요소, 영향 범위 누락이 없는지 점검"
    ;;
  spec-plan|spec-plan-review|spec-review)
    spec_path="${1:-}"
    plan_path="${2:-}"

    if [[ -z "$spec_path" ]]; then
      spec_path="$(read_current_task_field "Spec" || true)"
    fi
    if [[ -z "$spec_path" ]]; then
      spec_path="$(latest_markdown_file "rd-workflow-workspace/specs/changes" "rd-workflow-workspace/specs/base" || true)"
    fi

    if [[ -z "$plan_path" ]]; then
      plan_path="$(read_current_task_field "Plan" || true)"
    fi
    if [[ -z "$plan_path" ]]; then
      plan_path="$(latest_markdown_file "rd-workflow-workspace/plans" || true)"
    fi

    if [[ -z "$spec_path" || -z "$plan_path" ]]; then
      echo "spec-plan 검토는 spec과 plan 경로가 필요합니다." >&2
      echo "자동 탐지에 실패했으면 직접 지정하세요." >&2
      echo "예: bash rd-workflow/scripts/prepare_review_pipeline.sh spec-plan <spec-path> <plan-path>" >&2
      exit 1
    fi

    review_type="spec-plan-review"
    session_slug="$(derive_task_slug "$plan_path")-spec-plan-review"
    review_target="${spec_path}
${plan_path}"
    review_goal="\`rd-workflow/docs/prompts/review/spec_review.md\` 기준으로 과도한 설계, 빠진 엣지 케이스, 더 단순한 대안, 품질 검증 전략 누락, 대상 적합성을 점검"
    ;;
  output|output-review|final-output)
    review_type="output-review"
    session_slug="final-output-review"
    review_target="CURRENT_TASK.md"
    review_goal="\`rd-workflow/docs/prompts/review/output_review.md\` 기준으로 Acceptance Criteria 충족, 품질 기준 부합, 논리적 일관성, 제약 준수, 과잉 표현 여부를 점검"
    ;;
  *)
    echo "알 수 없는 review-kind: ${review_kind}" >&2
    usage
    exit 1
    ;;
esac

session_path="$("${script_dir}/init_review_pipeline.sh" "${session_slug}" "${review_type}" "${review_target}" "${review_goal}")"
prompts_path="${session_path}/PROMPTS.md"

cat <<EOF > "${prompts_path}"
# Review Pipeline Prompts

## Review Kind
${review_kind}

## Review Type
${review_type}

## Review Target
${review_target}

## Review Goal
${review_goal}

## Session Path
${session_path}

## Preferred Flow
Claude 중심 권장 흐름에서는 아래 프롬프트만 Claude에게 넣고, 이후 Codex 차례는 Claude가 이 세션 경로로 \`bash rd-workflow/scripts/run_review_turn.sh ...\`를 처리한다.

## Step 1. Paste To Claude
\`\`\`text
\`rd-workflow/docs/prompts/manual/review_pipeline_continue_manual.md\`대로 이어줘.

session path:
${session_path}
\`\`\`

## Step 2. Manual Codex Fallback
Claude가 CLI를 실행할 수 없고, Claude가 첫 턴을 작성한 뒤 \`SESSION.md\`의 \`Current Owner\`가 \`Reviewer\`가 되면 아래를 Reviewer에게 넣는다.

\`\`\`text
\`rd-workflow/docs/prompts/manual/review_pipeline_continue_manual.md\`대로 이어줘.

session path:
${session_path}
\`\`\`

## Step 3. Repeat
- 권장 흐름에서는 Claude가 최신 Reviewer 턴이 \`이의 없음\`을 명시할 때까지 같은 세션을 계속 읽고 필요할 때 리뷰 어댑터를 호출한다.
- 수동 fallback에서는 같은 이어가기 프롬프트를 계속 재사용한다.
- 총 턴 수는 최대 ${turn_limit}개이며, ${turn_limit}턴에 도달하면 남은 쟁점을 정리하고 \`awaiting-user\`로 넘긴다.
- 현재 차례는 \`SESSION.md\`의 \`Current Owner\`를 본다.
- \`awaiting-user\`가 되면 \`USER_ACTION.md\` 질문에 답하거나 마무리를 승인한다.
EOF

cat <<EOF
review pipeline prepared

session path:
${session_path}

review type:
${review_type}

review target:
${review_target}

review goal:
${review_goal}

next:
1. 아래 프롬프트를 Claude에게 넣으세요.
2. 권장 흐름에서는 Claude가 Codex 차례에 이 세션 경로로 \`bash rd-workflow/scripts/run_review_turn.sh ...\`를 실행합니다.
3. Claude가 CLI를 실행할 수 없을 때만 ${prompts_path} 의 수동 fallback 블록을 사용하세요.

----- CLAUDE -----
\`rd-workflow/docs/prompts/manual/review_pipeline_continue_manual.md\`대로 이어줘.

session path:
${session_path}
EOF
