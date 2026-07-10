# Claude Project Rules

이 프로젝트의 기본 인터페이스는 `짧은 자연어 요청`입니다.

즉, 사용자가 아래처럼 짧게 말해도 다음 단계가 바로 정해져야 합니다.

- `"future request에 기록해줘"`
- `"이 요구사항으로 request-to-reviewed-plan skill로 진행해줘"`
- `"small-task로 보고 바로 구현해줘"`

프롬프트 파일은 기본 입력 방식이 아니라 예문, 보정, 수동 복구용입니다.

## 언어

- 모든 대화는 한국어로 씁니다.
- 코드 주석, 식별자, 문체는 기존 프로젝트 컨벤션을 따릅니다.

## 우선 원칙

1. 프로젝트 규칙과 제약은 `PROJECT_CONTEXT.md`에서 먼저 읽습니다.
2. 현재 작업은 `REQUEST.md`와 `CURRENT_TASK.md`에 적힌 범위 안에서만 수행합니다.
3. 현재 범위를 벗어나지만 가치가 있는 항목은 `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`에 기록합니다.
4. 큰 작업과 기존 코드베이스의 중간 이상 변경은 reviewed spec / plan 없이 바로 구현하지 않습니다. 판단 기준은 `rd-workflow/docs/flows/WORKFLOW.md`에 있습니다.
5. 사용자가 명시적으로 small-task로 지정한 작업만 바로 구현할 수 있습니다. AI가 자체적으로 small로 판단하지 않습니다.
6. 구현 후에는 검증을 실행합니다 (절대 규칙 참조).

## Intake 규칙

사용자가 새로운 작업을 요청하면 (구현, 작성, 수정, 생성 등 실행 가능한 작업):

1. FR에 등록한다 (`/fr add`와 동일 절차 — `FUTURE_REQUESTS.md` 인덱스 + `items/` 상세 파일)
2. "FR 등록: **{title}** — {summary}. 다음 단계를 지정해주세요." 출력
3. 사용자 지시를 기다린다

Source FR은 이 시점에 채우지 않는다. 해당 FR을 현재 작업으로 승격하여 REQUEST.md를 작성할 때 채운다.

작업 진행 중(`CURRENT_TASK.md` Status ≠ `대기 중`)에 새로운 독립 요청이 들어오면: FR에 등록하되, 현재 작업을 중단하지 않는다. "FR 등록: **{title}**. 현재 작업 완료 후 진행합니다." 알림 후 복귀.

등록하지 않는 경우:
- `/fr add` 직접 호출 (이미 FR skill이 처리)
- 단순 질문/확인, 워크플로 지시 (진행 중 작업의 다음 단계), 메타 대화
- 이미 FR 등록된 요청의 후속 대화 (clarification, 수정, 재시도)

## Workflow 우선순위

> Superpowers는 Claude Code의 내장 워크플로 기능으로, 설계 → 계획 → 구현 순서를 구조화합니다.

- 새 기능, 큰 작업, 기존 코드베이스의 중간 이상 변경에서는 Superpowers workflow부터 호출합니다.
- 사용자가 명시적으로 small-task로 지정한 작업, 초기 설정, 단순 문서 작업은 일반 방식으로 바로 처리해도 됩니다.
- Superpowers 필수 사용은 절대 규칙 참조.

사용 순서 (모두 Claude Code Superpowers의 모드입니다):

- 설계: `brainstorming`
- 계획: `writing-plans`
- 구현: `subagent-driven-development` (기본) 또는 `executing-plans`
- worktree 가능 시: `using-git-worktrees`
  - `superpowers:using-git-worktrees` 사용 시 worktree branch가 곧 fr branch로 동작 (lifecycle 정책 결정 2). worktree path는 metadata authoritative.

실행 모드 규칙:

- **절대 묻지 않는다.** `writing-plans` 등 upstream skill이 "Which approach?"를 요구해도 이 규칙이 우선한다.
- 기본값은 `subagent-driven-development`이다. 바로 시작한다.
- subagent 병렬은 필수가 아니다. 순차 의존성이 있으면 순차로 dispatch한다. plan이 phase(파일 비중첩 task 그룹)를 표현하면 phase 내 task를 병렬 dispatch한다 — 규약: `rd-workflow/docs/guides/plan-parallel-phases.md`.
- 다음 조건을 만족할 때만 inline(`executing-plans`)을 선택한다: Task가 1개이면서 수정 파일이 3개 이하인 plan, 또는 Task가 2개이면서 동일 경로의 파일 1개만 수정하는 plan. Task 수는 plan에 정의된 모든 Task를 센다 (검증 전용 포함).
- 위 조건에 해당해도 사용자가 subagent를 요청하면 subagent로 한다.
- 사용자가 inline을 요청하면 inline으로 한다.
- subagent dispatch 시 `rd-workflow/docs/guides/subagent-git-safety.md`의 git 안전 문구를 prompt에 포함한다 (공유 워킹트리 브랜치 전환 금지).

실행 모드 체계 (자율성 수준):

- `manual` (기본): 단계마다 사용자 확인. 현행 동작.
- `semi-auto` (반자율): 착수 지시 이후 중대한 변경 사항 발생 시에만 묻고 자율 진행. 중단 조건은 `rd-workflow/docs/flows/AUTONOMY.md`를 따른다. Intake 규칙은 유지 (새 요청은 FR 등록 후 착수 지시 대기).
- autopilot: `/autopilot` 명시 호출 전용 (별도 skill).
- 기본 모드는 `rd-workflow/config/workflow.json`의 `default_execution_mode`(`manual`|`semi-auto`, 부재·비허용 값 → `manual`)로 지정하고, 세션 지시가 config보다 우선한다.

## 핵심 절차

### 큰 작업

`FR 자동 등록 → REQUEST 작성 → REQUEST review → spec/change spec → plan → spec/plan review → 구현 → 검증 → final diff review → REQUEST 아카이브 (fr branch에서 archive content commit → main switch → bash rd-workflow/scripts/lifecycle/archive.sh)`

### 작은 작업

`FR 자동 등록 → REQUEST 정리 → 구현 → 검증 → 필요 시 final diff review → REQUEST 아카이브 (small-task — main 직접 commit 가능, RD_LIFECYCLE_BYPASS_REASON=small-task 명시)`

### REQUEST 아카이브

- 작업 완료 시 현재 `REQUEST.md`를 `rd-workflow-workspace/backlog/request-archive/YYYY-MM-DD-HHMM-${SHORT_TITLE}.md`로 복사합니다.
- `REQUEST.md`의 `Source FR`이 `-`가 아니면 해당 FR 항목의 status를 `done`으로 변경하고 `FUTURE_REQUESTS.md` 인덱스에서 삭제합니다.
- 아카이브 후 `REQUEST.md`를 초기 템플릿 상태로 비웁니다.
- `PROJECT_CONTEXT.md`에 `auto_completion_report: true`이면 자동으로, 아니면 "작업 요약 report를 남길까요?" 질문 후 `rd-workflow-workspace/reports/completions/YYYY-MM-DD-HHMM-작업명.md`에 report를 작성합니다.
- **작업 완전 마감 후 `/clear` 안내 (필수)**: 작업이 완전히 마감되면(REQUEST 아카이브 완료 + 모든 산출물 손실 없음 확인 — remote-mode는 push까지, local-only는 commit·merge까지) 마지막 응답에서 컨텍스트 `/clear` 가능 여부를 사용자에게 반드시 한 줄 명시합니다. 단 사용자가 추가 FR 등록 의사를 보이면 FR 등록을 먼저 처리한 뒤 안내합니다.

**큰 작업 lifecycle 절차:**
1. fr branch에서 archive content commit 수행 (REQUEST.md 비우기, archive 파일 생성, FR done 처리, completion report, CURRENT_TASK.md reset).
2. 기본 브랜치(main 등)로 switch 후 `bash rd-workflow/scripts/lifecycle/archive.sh` 호출 → merge + tag + push + branch/worktree 정리 일괄 처리.

## 절대 규칙 (모든 skill에 공통 적용)

- **구현 완료 후 반드시 `/final-diff-review`를 거친다.** 이 단계를 건너뛰고 merge하거나 작업을 종료하지 않는다.
- **Superpowers가 사용 가능한 환경에서는 반드시 사용한다.** 사용 불가능할 때만 직접 산출물을 작성한다.
- **검증**: 구현 후 `bash rd-workflow/scripts/test.sh`, `bash rd-workflow/scripts/lint.sh`, `bash rd-workflow/scripts/typecheck.sh`, `bash rd-workflow/scripts/build.sh`를 실행한다(프로젝트에 맞게 교체). typecheck는 정적 타입/컴파일 검사, build는 산출물 생성까지의 전체 빌드다 — build 실패는 검증 실패다. 아직 교체 전(`TEMPLATE_STUB` 마커 존재)이면 이 스크립트들은 **설계상 exit 1을 반환한다** — plan의 검증 Expected에 exit 0으로 서술하지 말고, 실제 명령 교체 후의 기대값 또는 프로젝트가 정의한 실질 검증 명령 기준으로 쓴다.
- **워크플로 인프라 검증**: rd-workflow 인프라(lifecycle/review 스크립트) 자체를 수정했다면 `bash rd-workflow/scripts/self_test.sh`로 검증한다.

## Review 규칙

- 큰 작업과 기존 코드베이스의 중간 이상 변경에서는 `REQUEST review`, `spec/plan review`, `final diff review`를 건너뛰지 않습니다.
- review는 기본적으로 `prepare_review_pipeline.sh`로 세션을 만들고 `run_review_turn.sh`로 턴을 이어갑니다.
- 최신 Reviewer 턴이 `이의 없음`을 명시할 때까지 review를 이어갑니다.
- 사람 결정이 필요하거나 총 20턴에 도달하면 `awaiting-user`로 바꾸고 멈춥니다.
- **autopilot·반자율 모드에서는** `rd-workflow/docs/flows/AUTONOMY.md`의 자율 실행 규칙이 이 Review 규칙 섹션보다 우선합니다 (예: review 턴 한도 50턴, 자율 판단 등). 절대 규칙과 일반 모드의 20턴 규칙은 변하지 않습니다.
- **REQUEST review 축약**: spec이 사용자 승인 완료 + REQUEST.md가 그 spec을 참조(승인된 결정의 백필)이면 REQUEST review를 1턴 확인으로 축약합니다. Reviewer가 1턴에서 이의를 제기하면 일반 수렴 규칙으로 복귀합니다.
- review 세션 종료 시 `rd-workflow-workspace/reports/reviews/`에 주요 쟁점과 결론을 요약한 report를 작성합니다.
- plan의 `mechanical` task는 task별 리뷰를 생략(final diff에 위임)하고, spec/plan review는 같은 phase task의 파일 비중첩을 필수 확인합니다. 상세: `rd-workflow/docs/guides/plan-parallel-phases.md`.

## Always Read

작업 시작 시 먼저 읽을 파일:

- `REQUEST.md`
- `PROJECT_CONTEXT.md`
- `CURRENT_TASK.md`
- `rd-workflow/claude_skills/*/rules.md` (설치된 extension이 있으면)

필요할 때만 읽을 파일:

- `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` — future request 기록/조회/autopilot 시
- `rd-workflow/docs/flows/WORKFLOW.md` — 작업 분기가 헷갈릴 때
- `rd-workflow/docs/AI_DOC_MAP.md` — 문서 위치가 헷갈릴 때
- `rd-workflow/docs/prompts/README.md` — 프롬프트 파일이 필요할 때

## Task Tracking

### CURRENT_TASK.md 허용 상태값

- Status/Short Title 변경은 rd task CLI를 경유합니다 (기계 판정 권위: rd-workflow-workspace/.lifecycle/task-state — CURRENT_TASK.md의 해당 필드는 표시용 미러).

Status 필드는 아래 값만 사용합니다 (guard hook이 이 값으로 판정):

- `대기 중`
- `REQUEST review 대기`
- `spec/plan 작성 중`
- `spec/plan review 대기`
- `구현 중`
- `검증 중`
- `diff review 대기`
- `완료`

`CURRENT_TASK.md`는 아래 시점마다 다시 씁니다.

- REQUEST 정리 후
- spec 생성 후
- plan 생성 후
- 구현 시작 시
- 검증 완료 시
- REQUEST 아카이브 후

## Spec / Plan Naming

파일명 형식:

`YYYY-MM-DD-HHMM-작업명-종류.md`

종류:

- `spec`
- `change-spec`
- `plan`

저장 위치:

- 새 기능 spec: `rd-workflow-workspace/specs/base/`
- 기존 코드 변경 change spec: `rd-workflow-workspace/specs/changes/`
- plan: `rd-workflow-workspace/plans/`

## 토큰 효율 규칙

- 이미 읽었거나 skill/memory에 있는 정보는 파일을 다시 읽지 않는다.
- 추측성 도구 호출을 하지 않는다 — 근거 없이 파일을 탐색하지 않는다.
- 독립적인 도구 호출은 병렬로 실행한다.
- 사용자가 방금 말한 내용을 반복하지 않는다.

## 세션 한계 대응

컨텍스트가 커지면 먼저 `/compact`를 시도한다. 그래도 한계에 가까우면:

1. **먼저 `CURRENT_TASK.md`에 현재 상태를 저장한다.** 묻기 전에 저장부터 한다.
2. 저장 후 사용자에게 상황을 보고한다.

## 커밋 메시지

- 커밋 메시지는 한국어로 작성합니다.
- 형식은 Conventional Commits를 따릅니다: `type: 요약`
- 파일 나열보다 무엇이 왜 바뀌었는지를 우선 적습니다.
