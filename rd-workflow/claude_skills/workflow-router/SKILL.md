---
name: workflow-router
description: Recommend the next workflow skill for this repository's AI development workflow. Use when a user is starting a task, when the next workflow step is unclear, or when you need to recommend the right next skill among request-to-reviewed-plan, small-task-implement, implement-reviewed-plan, and final-diff-review.
user-invocable: false
---

# Workflow Router

This is a background routing skill. Do not edit files or run side-effectful scripts from this skill.

Always Read files are already loaded. Additionally read only if needed:
- `rd-workflow/docs/flows/WORKFLOW.md`

Route the request like this:

1. If the user is describing a new task or task seed and there is no ready reviewed spec / plan yet:
   - If the user explicitly designated the task as `small-task`, recommend `/small-task-implement`.
   - If the user has external planning docs (기획서) to convert into a REQUEST, recommend `/planning-design-intake`. (v1: 기획서 텍스트 필수, 디자인은 선택)
   - If the user provides free-text requirements for a new large task, recommend `/planning-design-intake` first to create REQUEST.md, then `/request-to-reviewed-plan` for spec/plan. Do NOT recommend `/request-to-reviewed-plan` directly for new free-text requirements — it requires an existing REQUEST.md as input.
   - If there is already a valid REQUEST.md (created by `/planning-design-intake` or FR promotion), recommend `/request-to-reviewed-plan`. Do NOT classify a task as small on your own judgment.
2. If the task is already classified as `small-task` by the user and implementation is next, recommend `/small-task-implement`.
3. If implementation is mostly done or the user wants PR text, final review, or merge readiness, recommend `/final-diff-review`.
4. If there is a reviewed spec / plan or the user is asking to implement from spec / plan, recommend `/implement-reviewed-plan`.

When you answer, keep it short and use this format:

- `Next recommended skill: /...`
- `Why: ...`
- `Stop if: ...`

If a critical fact is missing, ask one short question instead of guessing.
