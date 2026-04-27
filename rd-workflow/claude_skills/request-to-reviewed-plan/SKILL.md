---
name: request-to-reviewed-plan
description: Run REQUEST review, write spec or change spec and plan, and run spec / plan review until the task is ready for implementation. Requires an existing REQUEST.md written by /planning-design-intake (for free-text requirements) or by FR promotion. Use for new features and non-trivial existing code changes.
disable-model-invocation: true
---

# Request To Reviewed Plan

**이 skill 은 이미 작성된 `REQUEST.md` 를 입력으로 한다** (FR 승격 또는 `/planning-design-intake` 가 만든 REQUEST).
**새 자유 텍스트 큰 작업은 `/planning-design-intake` 를 먼저 거쳐야 한다.**

Canonical workflow:
- `rd-workflow/docs/prompts/recovery/request_to_reviewed_plan_full.md`

Read these first (Always Read files are already loaded):
- `rd-workflow/docs/prompts/recovery/request_to_reviewed_plan_full.md`

Typical user requests can be short:
- "이 요구사항으로 request-to-reviewed-plan skill로 진행해줘"
- "큰 작업으로 보고 reviewed plan까지 만들어줘"

## 진입 조건 검증 (Step 0 실행 전)

skill 진입 직후, Step 0 이전에 `REQUEST.md` 상태를 확인한다:

1. **`REQUEST.md` 가 없거나 비어 있음** → skill 진행 차단 + 경고:
   > 새 작업의 REQUEST.md 가 없습니다. 새 자유 텍스트 큰 작업은 `/planning-design-intake` 를 먼저 호출하여 REQUEST.md 를 작성한 뒤 본 skill 로 진행하세요.

2. **`REQUEST.md` 가 있고 `Source FR` 명시됨 + `## Short Title = -`** → Step 0 의 (a) rebind branch 로 진행

3. **`REQUEST.md` 가 있고 `Source FR` 명시됨 + `## Short Title = FR_TITLE`** → Step 0 의 (b) baseline equal 로 진행

4. **`REQUEST.md` 가 있고 `Source FR` 명시됨 + `## Short Title` 이 `-` 도 `FR_TITLE` 도 아닌 값** → Step 0 의 (c) active-task guard 로 진행

5. **`REQUEST.md` 가 있고 `Source FR` 미명시 (또는 `-`)** → 비-promotion 진입 (기존 REQUEST 이어서 작업):
   - `CURRENT_TASK.md`의 `## Short Title` 을 read-only 로 사용
   - `## Short Title` 이 `-` 이거나 부재이면 경고 + capture skip (skill 진행 차단 안 함):
     > 경고: `CURRENT_TASK.md ## Short Title` 이 없어 raw capture 를 skip 합니다. 새 자유 텍스트 큰 작업은 `/planning-design-intake` 를 먼저 호출하세요.
   - 유효한 `## Short Title` 이 있으면 Step 1 으로 진행

비고: stale `REQUEST.md` 가 남은 상태에서 새 자유 텍스트로 RTRP 를 호출하면, `Source FR` 가 이전 FR 인 경우 위 4번 또는 3번 케이스에서 차단되거나 이어서 처리됨 → 새 자유 텍스트는 먼저 archive 또는 `/planning-design-intake` 호출 필요.

## Short Title 정책

이 skill은 `CURRENT_TASK.md`의 `## Short Title`을 **read-only**로만 사용한다.
**예외:** Step 0의 rebind branch (`CURRENT_TITLE = -`) 일 때 한정 1회 기록.
그 외 `## Short Title` 변경 / 삭제 금지.

## Step 0. FR 승격 3-way 분기 (skill 진입 직후, 캡처 전)

**FR 승격 진입 감지:** `REQUEST.md`의 `Source FR` 필드 또는 사용자 입력에서 source FR이 명시된 경우.

승격 진입이 감지되면:

1. source FR의 short-title 추출 → `FR_TITLE` 변수
2. `CURRENT_TASK.md`의 `## Short Title` 값 read → `CURRENT_TITLE` 변수
3. **3-way 분기:**

   **(a) `CURRENT_TITLE = -` → rebind:**
   - `FR_TITLE`을 `CURRENT_TASK.md ## Short Title`에 1회 기록 (busy `/fr add` deferred 케이스)
   - Step 1으로 진행

   **(b) `CURRENT_TITLE = FR_TITLE` (equal) → baseline proceed:**
   - 정상 baseline 승격. `CURRENT_TASK.md` 변경 없이 read-only로 Step 1 진행

   **(c) `CURRENT_TITLE ≠ FR_TITLE` AND `CURRENT_TITLE ≠ -` → active-task guard:**
   - skill 진행 차단 + 다음 경고 출력:
     > 현재 진행 중인 작업 (`${CURRENT_TITLE}`) 이 archive 되지 않았습니다.
     > FR `${FR_TITLE}` 을 promote 하려면 먼저 현재 작업을 archive 한 뒤 다시 진입하세요.

**비-promotion 진입** (기존 REQUEST 이어서 작업 등): 이 분기 skip → Step 1부터 read-only로 진행.

## Step 1. skill 진입 직후 캡처 (Step 0 rebind branch 통과 후 또는 비-promotion 진입)

1. `CURRENT_TASK.md`의 `## Short Title` 값 read → `SHORT_TITLE`
2. `SHORT_TITLE`이 없거나 `-`이면: 경고 출력 + 캡처 생략 (skill 진행은 차단 안 함)
   - 필드가 없거나 default `-`이면 경고 + 캡처 생략 (skill 진행 차단 안 함). 이는 `Source FR` 없는 진입이면서 `## Short Title`도 비어 있는 edge 케이스 — `Source FR` 없는 정상 continuing-work 진입은 active task의 valid `## Short Title`을 갖고 있으므로 정상 캡처됨. 이 경고가 뜨는 경우는 오직 진행 중 작업이 없어 캡처할 short-title을 알 수 없는 상태.
3. `SHORT_TITLE`이 유효하면: `rd-workflow-workspace/raw-captures/{date}-request-{short-title}.md` 생성
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

## Step 2. spec / change-spec 작성 단계 직전 캡처

1. 명시적 사용자 입력 원문이 있으면: `rd-workflow-workspace/raw-captures/{date}-spec-{short-title}.md` 생성
   - 디렉토리 0700 보장 + umask 077 subshell 로 캡처 파일 0600 보장:
     ```bash
     if ! assert_no_symlink_in_path "rd-workflow-workspace/raw-captures"; then
       echo "경고: raw-captures 경로에 symlink 가 있어 캡처를 건너뜁니다." >&2
     else
       mkdir -p rd-workflow-workspace/raw-captures
       chmod 0700 rd-workflow-workspace/raw-captures
       ( umask 077 && cat > "$capture_path" <<EOF
     ---
     date: YYYY-MM-DD HH:MM
     stage: spec
     short-title: {short-title}
     source: direct | routed
     ---

     ## 원본 입력
     {spec 작성 트리거 사용자 입력 원문}
     EOF
       )
     fi
     ```
     (`source`: 직접 호출이면 `direct`, 자연어 라우팅이면 `routed`)
   - 본문: spec 작성 트리거 사용자 입력 원문
2. **명시적 원문 부재 시 (모델 자체 판단으로 진행): 캡처 생략 + 경고** — surrogate(직전 사용자 메시지 등) 저장 금지. spec의 raw-input 계약과 일관성 유지.

## Step 3. plan 작성 단계 직전 캡처

1. 명시적 사용자 입력 원문이 있으면: `rd-workflow-workspace/raw-captures/{date}-plan-{short-title}.md` 생성
   - 디렉토리 0700 보장 + umask 077 subshell 로 캡처 파일 0600 보장:
     ```bash
     if ! assert_no_symlink_in_path "rd-workflow-workspace/raw-captures"; then
       echo "경고: raw-captures 경로에 symlink 가 있어 캡처를 건너뜁니다." >&2
     else
       mkdir -p rd-workflow-workspace/raw-captures
       chmod 0700 rd-workflow-workspace/raw-captures
       ( umask 077 && cat > "$capture_path" <<EOF
     ---
     date: YYYY-MM-DD HH:MM
     stage: plan
     short-title: {short-title}
     source: direct | routed
     ---

     ## 원본 입력
     {plan 작성 트리거 사용자 입력 원문}
     EOF
       )
     fi
     ```
     (`source`: 직접 호출이면 `direct`, 자연어 라우팅이면 `routed`)
   - 본문: plan 작성 트리거 사용자 입력 원문
2. 명시적 원문 부재 시: 캡처 생략 + 경고 (Step 2와 동일 정책)

## Execution rules

- Keep the original scope. Do not widen the request.
- Ask only when a missing fact is required to create `REQUEST.md` or to choose the execution path safely.
- 사용자가 명시적으로 `small-task`로 지정한 경우에만 spec / plan 흐름을 중단하고 `/small-task-implement`를 추천한다. AI가 자체적으로 small-task로 재분류하지 않는다.
- If `Execution Path` is `existing-code-change` or `new-feature-or-large-task`, continue through request review, spec or change spec, plan, and spec / plan review.
- Use `bash rd-workflow/scripts/prepare_review_pipeline.sh request` and `bash rd-workflow/scripts/run_review_turn.sh ...` for `REQUEST` review.
- Use `bash rd-workflow/scripts/prepare_review_pipeline.sh spec-plan` or the explicit spec / plan paths plus `bash rd-workflow/scripts/run_review_turn.sh ...` for spec / plan review.
- **Superpowers가 사용 가능하면 반드시 `brainstorming`과 `writing-plans`를 사용한다.** 사용 불가능할 때만 같은 산출물을 직접 작성한다.
- Update `CURRENT_TASK.md` at the major checkpoints.
- Stop before implementation.
- `/planning-design-intake`에서 REQUEST.md가 이미 생성된 경우, REQUEST.md를 읽고 REQUEST review부터 시작한다. REQUEST를 처음부터 새로 작성하지 않는다.
- REQUEST.md에 `## Design Reference Memo`가 있으면, spec 작성 시 해당 내용을 spec의 `## Design Reference` 섹션으로 승격한다.
- spec 작성 완료 후 `/gap-check` 실행을 추천한다: "spec 작성 완료. → `/gap-check`로 기획-디자인 갭 체크를 추천합니다."

Final output:
- `Execution Path`
- `REQUEST.md` status
- spec path
- plan path
- request review session path
- spec / plan review session path
- `Next recommended skill: /implement-reviewed-plan` or `/small-task-implement`
- Any remaining user question, only if it is actually blocking
