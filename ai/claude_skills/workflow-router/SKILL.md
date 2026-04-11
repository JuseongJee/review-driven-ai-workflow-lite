---
name: workflow-router
description: Recommend the next workflow skill. Use when a user is starting a task, when the next workflow step is unclear, or when you need to recommend the right next skill among request-to-reviewed-plan, small-task-implement, and final-output-review.
user-invocable: false
---

# Workflow Router

This is a background routing skill. Do not edit files or run side-effectful scripts from this skill.

Always Read files are already loaded. Additionally read only if needed:
- `ai/docs/flows/WORKFLOW.md`

Route the request like this:

1. If the user is describing a new task or task seed and there is no ready reviewed spec / plan yet:
   - If the user explicitly designated the task as `small-task`, recommend `/small-task-implement`.
   - Otherwise recommend `/request-to-reviewed-plan`. Do NOT classify a task as small on your own judgment.
2. If the task is already classified as `small-task` by the user and execution is next, recommend `/small-task-implement`.
3. If execution is mostly done or the user wants final review or delivery readiness, recommend `/final-output-review`.
4. If there is a reviewed spec / plan or the user is asking to execute from spec / plan, recommend the execution step described in the plan.

When you answer, keep it short and use this format:

- `Next recommended skill: /...`
- `Why: ...`
- `Stop if: ...`

If a critical fact is missing, ask one short question instead of guessing.
