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

1. If the user is describing a new task and there is no reviewed spec / plan yet, classify the risk tier with the signal table in `rd-workflow/docs/flows/WORKFLOW.md` (위험 등급 절) and state the tier with its 근거 신호. Do NOT emit the 시작 보고 블록 here — it needs the 시작 계약 (fetch, ahead count) and is produced once by the tier's producer: `light` 체크리스트 1항 or `/small-task-implement` step 1 after the 시작 계약; for `full` the session's Intake step (CLAUDE.md Intake 규칙, or autopilot's 모드 결정) emits it right after classification and after the read-only `full` preflight (fetch + default-branch ahead count), before FR 등록 (WORKFLOW.md 위험 등급 절):
   - `light` → no skill. Follow the light 체크리스트 in WORKFLOW.md (implement → verify → reclassify → one commit on the default branch with a `reports/tier-log.md` row).
   - `standard` → recommend `/small-task-implement`.
   - `full` with external planning docs (기획서) → recommend `/planning-design-intake`; `full` with free-text requirements → `/planning-design-intake` first to create REQUEST.md, then `/request-to-reviewed-plan`. Do NOT recommend `/request-to-reviewed-plan` directly for new free-text requirements — it requires an existing REQUEST.md.
   - If there is already a valid REQUEST.md (created by `/planning-design-intake` or FR promotion), recommend `/request-to-reviewed-plan`.
   - When in doubt between two tiers, pick the higher one. Only the user may lower a tier; you may suggest lowering.
2. If the task is `standard` and implementation is next, recommend `/small-task-implement`.
3. If implementation is mostly done or the user wants PR text, final review, or merge readiness, recommend `/final-diff-review` (`standard`·`full`). For `light`, recommend the 커밋 전 재분류 step instead.
4. If there is a reviewed spec / plan or the user is asking to implement from spec / plan, recommend `/implement-reviewed-plan`.
5. When recommending a skill that keeps `disable-model-invocation: true` (`comprehensive-audit`, `tpl`, and in the development repository `ship`, `publish`), state explicitly that the user must type the command themselves — the model cannot invoke it. For every other skill, recommend it normally; the model may invoke it directly subject to the execution mode (`AUTONOMY.md`, 「실행 모드와 skill 호출 권한」).

When you answer, keep it short and use this format:

- `Next recommended skill: /...`
- `Why: ...`
- `Stop if: ...`

If a critical fact is missing, ask one short question instead of guessing.
