---
name: small-task-implement
description: Execute a small-task directly from REQUEST.md and PROJECT_CONTEXT.md, keep the scope tight, run verification, and update CURRENT_TASK.md. Use when the task is clearly a small-task.
disable-model-invocation: true
---

# Small Task Implement

Use this only when the user explicitly designated the task as `small-task`. Do NOT use this based on AI's own judgment about task size.

Read these first (Always Read files are already loaded):
- `rd-workflow/docs/prompts/README.md`

Typical user requests can be short:
- "small-task로 보고 바로 실행해줘"
- "이거 작은 작업으로 처리해줘"

Execution rules:
- **실행 시작 전 `REQUEST.md`의 Acceptance Criteria를 읽는다.** AC가 비어있거나(`-`) 모호하면 실행을 시작하지 않고 사용자에게 확인을 요청한다.
- Keep the task small and direct.
- Do not introduce unnecessary structure or speculative changes.
- If the task no longer looks like a `small-task`, stop and recommend `/request-to-reviewed-plan`.
- Update `CURRENT_TASK.md`.
- Run `bash rd-workflow/scripts/verify.sh` unless the repository clearly lacks it.
- **실행 완료 후 반드시 `/final-output-review`로 넘긴다. 이 단계를 건너뛰고 작업을 종료하지 않는다.**

Final output:
- What changed
- Verification status
- `Next recommended skill: /final-output-review` (필수 -- 건너뛸 수 없음)
- Any blocker that still needs user input
