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

   **(a) `CURRENT_TITLE = -` 또는 부재 → write:**
   - `CANDIDATE`를 `CURRENT_TASK.md ## Short Title`에 기록
   - Step 4로 진행

   **(b) `CURRENT_TITLE = CANDIDATE` (equal) → read-only continue:**
   - `CURRENT_TASK.md` 변경 없이 Step 4로 진행

   **(c) `CURRENT_TITLE ≠ CANDIDATE` AND `CURRENT_TITLE ≠ -` → active-task guard:**
   - skill 진행 차단 + 다음 경고 출력:
     > 다른 작업 (`${CURRENT_TITLE}`) 이 진행 중입니다. 새 작업 (`${CANDIDATE}`) 을 small-task 로 시작하려면 현재 작업을 archive 한 뒤 다시 진입하세요.

4. **(a) (b) 통과 후) raw-capture 생성:**
   - `rd-workflow-workspace/raw-captures/{date}-request-{short-title}.md` 생성
   - 디렉토리 0700 보장 + umask 077 subshell 로 캡처 파일 0600 보장:
     ```bash
     assert_no_symlink_in_path() {
       _aslnp_p="$1"
       case "$_aslnp_p" in
         /*) ;;
         *)  _aslnp_p="$PWD/$_aslnp_p" ;;
       esac
       _aslnp_d="$_aslnp_p"
       while [ "$_aslnp_d" != "/" ] && [ -n "$_aslnp_d" ]; do
         if [ -L "$_aslnp_d" ]; then
           echo "경고: path component ($_aslnp_d) 가 symlink 입니다. 보안상 중단합니다." >&2
           unset _aslnp_p _aslnp_d
           return 1
         fi
         _aslnp_d=$(dirname "$_aslnp_d")
       done
       unset _aslnp_p _aslnp_d
       return 0
     }
     if ! assert_no_symlink_in_path "rd-workflow-workspace/raw-captures"; then
       echo "경고: raw-captures 경로에 symlink 가 있어 캡처를 건너뜁니다." >&2
     else
       mkdir -p rd-workflow-workspace/raw-captures
       chmod 0700 rd-workflow-workspace/raw-captures
       ( umask 077 && cat > "$capture_path" <<EOF
     ---
     date: YYYY-MM-DD HH:MM
     stage: request
     short-title: {short-title}
     source: direct | routed
     ---

     ## 원본 입력
     {사용자 입력 원문}
     EOF
       )
     fi
     ```
     (`source`: 직접 호출이면 `direct`, 자연어 라우팅이면 `routed`)
   - 본문: 사용자 입력 원문

5. 캡처 실패 시: 경고만 출력, 본 작업 차단 안 함

## Execution rules

- **구현 시작 전 `REQUEST.md`의 Acceptance Criteria를 읽는다.** AC가 비어있거나(`-`) 모호하면 구현을 시작하지 않고 사용자에게 확인을 요청한다.
- Keep the change small and direct.
- Do not introduce unnecessary structure or speculative refactors.
- If the task no longer looks like a `small-task`, stop and recommend `/request-to-reviewed-plan`.
- Update `CURRENT_TASK.md`.
- Run `bash rd-workflow/scripts/test.sh`, `bash rd-workflow/scripts/lint.sh`, and `bash rd-workflow/scripts/typecheck.sh` unless the repository clearly lacks one of them.
- **구현 완료 후 반드시 `/final-diff-review`로 넘긴다. 이 단계를 건너뛰고 merge하거나 작업을 종료하지 않는다.**

Final output:
- What changed
- Verification status
- `Next recommended skill: /final-diff-review` (필수 — 건너뛸 수 없음)
- Any blocker that still needs user input
