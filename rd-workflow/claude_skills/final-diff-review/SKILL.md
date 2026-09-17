---
name: final-diff-review
description: Prepare final handoff after implementation by checking verification status, drafting PR text, and orchestrating the final diff review until the branch is ready to merge or the user must decide. Use when implementation is done or nearly done; if verification has not been run yet, this skill runs it first.
---

# Final Diff Review

`manual` 모드에서는 사용자의 단계 진입 지시 없이 이 skill 을 스스로 시작하지 않는다. 판정 기준은 `rd-workflow/docs/flows/AUTONOMY.md` 의 「실행 모드와 skill 호출 권한」 절이다.

Use this after implementation is done or nearly done.

Typical user request:
- "final-diff-review skill로 진행해줘"

Read these first:
- `CURRENT_TASK.md`
- `rd-workflow/docs/PR_TEMPLATE.md`
- `rd-workflow/docs/prompts/review/diff_review.md`

Execution rules:
- 이 skill 은 `CURRENT_TASK.md` 의 `## Short Title` 을 read-only 로 사용한다 (변경 / 삭제 금지). short-title 은 작업 시작 시점 (`/fr add`, `planning-design-intake`, 또는 `promote.sh` 승격) 에 1회 부여되고 archive 까지 immutable 이다.
- If verification has not been run yet, run `bash rd-workflow/scripts/test.sh`, `bash rd-workflow/scripts/lint.sh`, `bash rd-workflow/scripts/typecheck.sh`, and `bash rd-workflow/scripts/build.sh` first when possible.
- Draft the PR description with `rd-workflow/docs/PR_TEMPLATE.md`.
- 세션 생성 전에 커밋 전 재분류(WORKFLOW.md 위험 등급 절) 를 끝내고 `REQUEST.md ## Risk Tier` 의 `- 최종 등급:` 이 확정되어 있어야 한다 — `prepare_review_pipeline.sh` 가 이 줄로 리뷰 effort 를 정한다.
- Start the final diff review with `bash rd-workflow/scripts/prepare_review_pipeline.sh diff` and continue with `bash rd-workflow/scripts/run_review_turn.sh ...` until the session reaches `awaiting-user` or the latest Reviewer turn has no objections.
- 독립 reviewer가 없어 self-review(claude)로 fallback될 때, 기본 정책 `self_review_policy=block`이면 일반 모드에서 차단된다. 독립 reviewer 없이 진행하려면 `RD_SELF_REVIEW_APPROVE=1`로 재실행하거나 `review-tools.json`에서 정책을 `warn`/`off`로 바꾼다.
- Update `CURRENT_TASK.md` if the task status changes.

Final output:
- Verification status
- PR summary status
- final diff review session path
- merge readiness or the exact user decision still needed
