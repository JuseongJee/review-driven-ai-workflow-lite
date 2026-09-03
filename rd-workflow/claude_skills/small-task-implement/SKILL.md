---
name: small-task-implement
description: Implement a small-task change directly from REQUEST.md and PROJECT_CONTEXT.md, keep the change tightly scoped, run verification scripts, and update CURRENT_TASK.md. Use when the task is clearly a small-task.
disable-model-invocation: true
---

# Small Task Implement

Use this only when the user explicitly designated the task as `small-task`. Do NOT use this based on AI's own judgment about task size.

Read these first (Always Read files are already loaded):
- `rd-workflow/docs/prompts/README.md`

Typical user requests can be short:
- "small-task로 보고 바로 구현해줘"
- "이거 작은 수정으로 처리해줘"

## REQUEST 정리 단계 직전: Short Title equality-aware 3-way 분기 + raw-capture

### 절차

1. 사용자 입력에서 short-title 후보 추론 → canonical 정규화
   - 정규식: `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`
   - `-` 단독 / empty / hyphen-only 금지
   - 위반 시 보정 요청 후 확정 → `CANDIDATE` 변수

2. `CURRENT_TASK.md`의 `## Short Title` 값 read → `CURRENT_TITLE`
   - 섹션 자체가 없으면 (legacy 템플릿) → 부재 케이스: 섹션 자동 추가 + 알림:
     > "legacy 템플릿이므로 `## Short Title` 섹션을 추가했습니다 — sync_template 마이그레이션 권장"
   - 부재 케이스는 (a) 분기로 이동

3. **3-way 분기 (CANDIDATE 확정 후):**

   `bash rd-workflow/scripts/rd task guard --candidate "${CANDIDATE}" --mode intake` 를 실행하고 출력의 `decision` 에 따라 진행한다:
   - `write` / `rebind`: `message` 를 사용자에게 알리고 Step 4로 진행
   - `proceed-readonly`: 변경 없이 Step 4로 진행
   - `block-parse` / `block-active` (exit 2): `message` 를 출력하고 skill 진행을 중단

4. 작업 이름을 시스템에 기록한다. **이 단계가 없으면 캡처가 직전 작업 이름으로 저장된다.**

   ```bash
   bash rd-workflow/scripts/rd task set-title "${CANDIDATE}"
   ```

   이미 다른 이름이 있으면 exit 2 로 거부된다 — 직전 작업이 아카이브되지 않았다는 신호이므로 먼저 그것을 확인한다.

5. **(a) (b) 통과 후) raw-capture 생성:**
   - `rd-workflow-workspace/raw-captures/{date}-request-{short-title}.md` 생성
   - frontmatter(date/stage/short-title/source)는 CLI가 생성한다. stdin에는 본문만 전달한다:
     ```bash
     bash rd-workflow/scripts/rd task capture --stage request --source direct <<'CAPTURE_EOF'
     ## 원본 입력
     {사용자 원본 입력 무가공}
     CAPTURE_EOF
     ```
     (`--source`: 직접 호출이면 `--source direct`, 자연어 라우팅이면 `--source routed`. CLI 기본값은 `routed`)

6. 캡처 실패 시: 경고만 출력, 본 작업 차단 안 함 — CLI 가 fail-open (exit 0) 으로 처리

## Execution rules

- **구현 시작 전 `REQUEST.md`의 Acceptance Criteria를 읽는다.** AC가 비어있거나(`-`) 모호하면 구현을 시작하지 않고 사용자에게 확인을 요청한다.
- Keep the change small and direct.
- Do not introduce unnecessary structure or speculative refactors.
- If the task no longer looks like a `small-task`, stop and recommend `/request-to-reviewed-plan`.
- Update `CURRENT_TASK.md`.
- Run `bash rd-workflow/scripts/test.sh`, `bash rd-workflow/scripts/lint.sh`, `bash rd-workflow/scripts/typecheck.sh`, and `bash rd-workflow/scripts/build.sh` unless the repository clearly lacks one of them.
- **구현 완료 후 반드시 `/final-diff-review`로 넘긴다. 이 단계를 건너뛰고 merge하거나 작업을 종료하지 않는다.**

Final output:
- What changed
- Verification status
- `Next recommended skill: /final-diff-review` (필수 — 건너뛸 수 없음)
- Any blocker that still needs user input
