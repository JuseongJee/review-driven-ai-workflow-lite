---
name: final-diff-review
description: Prepare final handoff after implementation by checking verification status, drafting PR text, and orchestrating the final diff review until the branch is ready to merge or the user must decide.
disable-model-invocation: true
---

# Final Diff Review

Use this after implementation is done or nearly done.

Typical user request:
- "final-diff-review skill로 진행해줘"

Read these first:
- `CURRENT_TASK.md`
- `rd-workflow/docs/PR_TEMPLATE.md`
- `rd-workflow/docs/prompts/review/diff_review.md`

Execution rules:
- 이 skill 은 `CURRENT_TASK.md` 의 `## Short Title` 을 read-only 로 사용한다 (변경 / 삭제 금지). short-title 은 작업 시작 시점 (`/fr add`, `planning-design-intake`, `small-task-implement` 3 곳 중 하나) 에 1회 부여되고 archive 까지 immutable 이다.
- If verification has not been run yet, run `bash rd-workflow/scripts/test.sh`, `bash rd-workflow/scripts/lint.sh`, and `bash rd-workflow/scripts/typecheck.sh` first when possible.
- Draft the PR description with `rd-workflow/docs/PR_TEMPLATE.md`.
- Start the final diff review with `bash rd-workflow/scripts/prepare_review_pipeline.sh diff` and continue with `bash rd-workflow/scripts/run_review_turn.sh ...` until the session reaches `awaiting-user` or the latest Reviewer turn has no objections.
- Update `CURRENT_TASK.md` if the task status changes.

Final output:
- Verification status
- PR summary status
- final diff review session path
- merge readiness or the exact user decision still needed
