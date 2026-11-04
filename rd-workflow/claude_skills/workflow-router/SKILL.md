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

1. If the user is describing a new task and there is no reviewed spec / plan yet, classify the risk tier with the signal table in `rd-workflow/docs/flows/WORKFLOW.md` (위험 등급 절) and state the tier with its 근거 신호. Do NOT emit the 시작 보고 블록 here — it needs the 시작 계약 (fetch, ahead count) and is produced once by the tier's producer: `light` 체크리스트 1항 or `/small-task-implement` step 1 after the 시작 계약; for `full` the session's Intake step (`.claude/rules/rd-workflow/core.md` Intake 규칙, or autopilot's 모드 결정) emits it right after classification and after the read-only `full` preflight (fetch + default-branch ahead count), before FR 등록 (WORKFLOW.md 위험 등급 절):
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

## rd-workflow 버전 대조

이 skill 은 아래 `RD_SKILL_BASE` 보다 나중에 배포된 rd-workflow 를 전제한다. 첫 작업 단계보다 먼저, 프로젝트 루트에서 아래 명령을 이 호출에서 한 번 실행한다.

- 출력이 없으면 그대로 진행한다.
- 출력이 있으면 출력 전문을 사용자에게 알리고, 템플릿을 sync 할지 그대로 계속할지 묻고 멈춘다. 사용자가 계속을 지시하면 진행한다.
- autopilot·무인 실행처럼 물을 사람이 없으면 계속하지 않고 그 출력을 중단 사유로 보고한다.

```bash
bash -s <<'RD_SKILL_COMPAT'
RD_SKILL_BASE=2026-11-01-202303 RD_SKILL_NAME=workflow-router
vf="rd-workflow/VERSION"
if [ ! -f "$vf" ] && [ -f "_ROOT_FILES/rd-workflow/VERSION" ]; then exit 0; fi
v=""; [ -f "$vf" ] && v="$(cat "$vf")"; v="${v#lite-}"
if [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]] && [[ "$v" > "$RD_SKILL_BASE" ]]; then exit 0; fi
echo "rd-workflow 버전 불일치 — skill '$RD_SKILL_NAME' 은 $RD_SKILL_BASE 보다 나중에 배포된 rd-workflow 가 필요합니다."
echo "프로젝트: $PWD"
echo "프로젝트 VERSION: ${v:-없음} (파일: $vf)"
echo "이 상태로 진행하면 skill 이 가리키는 문서 절·스크립트·인자가 없어 중간에 실패할 수 있습니다."
echo "해결: 템플릿을 sync 하십시오 (/tpl update 또는 rd-workflow/docs/guides/sync_template.md 절차)."
RD_SKILL_COMPAT
```
