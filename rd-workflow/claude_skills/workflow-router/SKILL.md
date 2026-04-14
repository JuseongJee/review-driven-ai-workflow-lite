---
name: workflow-router
description: Recommend the next workflow skill. Use when a user is starting a task, when the next workflow step is unclear, or when you need to recommend the right next skill among request-to-reviewed-plan, small-task-implement, and final-output-review.
user-invocable: false
---

# Workflow Router

This is a background routing skill. Do not edit files or run side-effectful scripts from this skill.

Always Read files are already loaded. Additionally read only if needed:
- `rd-workflow/docs/flows/WORKFLOW.md`

Route the request like this:

1. If the user is describing a new task or task seed and there is no ready reviewed spec / plan yet:
   - If the user explicitly designated the task as `small-task`, recommend `/small-task-implement`. (사용자 명시는 auto intake 판단보다 우선한다.)
   - If invoked via Intake 규칙 (auto intake): use the Auto Intake 판단 기준 below.
   - Otherwise recommend `/request-to-reviewed-plan`.
2. If the task is already classified as `small-task` by the user and execution is next, recommend `/small-task-implement`.
3. If execution is mostly done or the user wants final review or delivery readiness, recommend `/final-output-review`.
4. If there is a reviewed spec / plan or the user is asking to execute from spec / plan, recommend the execution step described in the plan.

When you answer, keep it short and use this format:

- `Next recommended skill: /...`
- `Why: ...`
- `Stop if: ...`

If a critical fact is missing, ask one short question instead of guessing.

## Auto Intake 판단 기준

CLAUDE.md의 Intake 규칙이 참조하는 small/large 판단 기준이다. 이 skill은 recommend-only를 유지한다 — 실제 skill 호출은 Intake 규칙이 담당한다.

### Small 조건 (모두 충족해야 함)
- 변경/생성 대상이 2~3개 이하
- 새 구조, 체계, 프레임워크를 도입하지 않음
- 기존 산출물의 부분 수정 수준

### Large 조건
- 위 small 조건 중 하나라도 미충족
- 판단이 애매하면 large로 분류

### 추천 매핑
- small → `/small-task-implement`
- large → `/request-to-reviewed-plan`
