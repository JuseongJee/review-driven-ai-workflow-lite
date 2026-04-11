---
name: final-output-review
description: Prepare final handoff after execution by checking verification status and orchestrating the final output review until the work is ready for delivery or the user must decide.
disable-model-invocation: true
---

# Final Output Review

Use this after execution is done or nearly done.

Typical user request:
- "final-output-review skill로 진행해줘"

Read these first:
- `CURRENT_TASK.md`
- `ai/docs/prompts/review/output_review.md`

Execution rules:
- If verification has not been run yet, run `bash ai/scripts/verify.sh` first when possible.
- Start the final output review with `bash ai/scripts/prepare_review_pipeline.sh output` and continue with `bash ai/scripts/run_review_turn.sh ...` until the session reaches `awaiting-user` or the latest Reviewer turn has no objections.
- Update `CURRENT_TASK.md` if the task status changes.

Final output:
- Verification status
- final output review session path
- delivery readiness or the exact user decision still needed
