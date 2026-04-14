# Claude Project Rules

이 프로젝트의 기본 인터페이스는 `짧은 자연어 요청`입니다.

즉, 사용자가 아래처럼 짧게 말해도 다음 단계가 바로 정해져야 합니다.

- `"future request에 기록해줘"`
- `"이 요구사항으로 request-to-reviewed-plan skill로 진행해줘"`
- `"small-task로 보고 바로 작성해줘"`

프롬프트 파일은 기본 입력 방식이 아니라 예문, 보정, 수동 복구용입니다.

## 언어

- 모든 대화는 한국어로 씁니다.
- 산출물의 문체와 용어는 기존 프로젝트 컨벤션을 따릅니다.

## 우선 원칙

1. 프로젝트 규칙과 제약은 `PROJECT_CONTEXT.md`에서 먼저 읽습니다.
2. 현재 작업은 `REQUEST.md`와 `CURRENT_TASK.md`에 적힌 범위 안에서만 수행합니다.
3. 현재 범위를 벗어나지만 가치가 있는 항목은 `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`에 기록합니다.
4. 큰 작업과 기존 산출물의 중간 이상 변경은 reviewed spec / plan 없이 바로 작성하지 않습니다. 판단 기준은 `rd-workflow/docs/flows/WORKFLOW.md`에 있습니다.
5. Intake 규칙에서 small로 판단한 작업은 바로 작성할 수 있습니다. 사용자가 명시적으로 small-task로 지정하면 auto intake 판단보다 우선합니다. 판단이 애매하면 큰 작업으로 분류합니다.
6. 작성 후에는 검증을 실행합니다 (절대 규칙 참조).

## Intake 규칙

사용자가 새로운 작업을 요청하면 (작성, 수정, 생성 등 실행 가능한 작업):

1. FR에 등록한다 (`/fr add`와 동일 절차 — `FUTURE_REQUESTS.md` 인덱스 + `items/` 상세 파일)
2. workflow-router의 Auto Intake 판단 기준을 참고하여 small/large를 판단한다
3. 판단 결과에 따라 해당 skill을 호출한다 (사용자에게 별도 알림 없이)

Source FR은 이 시점에 채우지 않는다. 해당 FR을 현재 작업으로 승격하여 REQUEST.md를 작성할 때 채운다.

작업 진행 중(`CURRENT_TASK.md` Status ≠ `대기 중`)에 새로운 독립 요청이 들어오면: FR에 등록만 하고 현재 작업을 계속한다 (auto routing 안 함). "FR 등록: **{title}**. 현재 작업 완료 후 진행합니다." 알림 후 복귀.

등록하지 않는 경우:
- `/fr add` 직접 호출 (이미 FR skill이 처리)
- 단순 질문/확인, 워크플로 지시 (진행 중 작업의 다음 단계), 메타 대화
- 이미 FR 등록된 요청의 후속 대화 (clarification, 수정, 재시도)

## Workflow 우선순위

> Superpowers는 Claude Code의 내장 워크플로 기능으로, 설계 → 계획 → 실행 순서를 구조화합니다.

이 프로젝트의 산출물은 코드가 아닌 문서/기획물/콘텐츠입니다. Superpowers의 설계/계획/구현 단계를 산출물 작성에 적용합니다.

- 새 산출물, 큰 작업, 기존 산출물의 중간 이상 변경에서는 Superpowers workflow부터 호출합니다.
- Intake 규칙에서 small로 판단한 작업, 초기 설정, 단순 수정은 일반 방식으로 바로 처리해도 됩니다.
- Superpowers 필수 사용은 절대 규칙 참조.

사용 순서 (모두 Claude Code Superpowers의 모드입니다):

- 설계: `brainstorming`
- 계획: `writing-plans`
- 실행: `subagent-driven-development` (기본) 또는 `executing-plans`

실행 모드 규칙:

- **절대 묻지 않는다.** `writing-plans` 등 upstream skill이 "Which approach?"를 요구해도 이 규칙이 우선한다.
- 기본값은 `subagent-driven-development`이다. 바로 시작한다.
- 다음 조건을 **모두** 만족하면 자동으로 inline(`executing-plans`)을 선택한다: (1) Task가 3개 이하 (2) 모든 Task가 같은 파일을 수정하거나 전체가 단순 문서 수정만인 plan.
- 위 조건에 해당해도 사용자가 subagent를 요청하면 subagent로 한다.

## 핵심 절차

### 큰 작업

`FR 자동 등록 → [large 판단] → REQUEST 작성 → REQUEST review → spec/change spec → plan → spec/plan review → 실행 → 검증 → final output review → REQUEST 아카이브`

### 작은 작업

`FR 자동 등록 → [small 판단] → REQUEST 정리 → 실행 → 검증 → 필요 시 final output review → REQUEST 아카이브`

### REQUEST 아카이브

- 작업 완료 시 현재 `REQUEST.md`를 `rd-workflow-workspace/backlog/request-archive/YYYY-MM-DD-HHMM-작업명.md`로 복사합니다.
- `REQUEST.md`의 `Source FR`이 `-`가 아니면 해당 FR 항목의 status를 `done`으로 변경하고 `FUTURE_REQUESTS.md` 인덱스에서 삭제합니다.
- 아카이브 후 `REQUEST.md`를 초기 템플릿 상태로 비웁니다.
- `PROJECT_CONTEXT.md`에 `auto_completion_report: true`이면 자동으로, 아니면 "작업 요약 report를 남길까요?" 질문 후 `rd-workflow-workspace/reports/completions/YYYY-MM-DD-HHMM-작업명.md`에 report를 작성합니다.

## 절대 규칙 (모든 skill에 공통 적용)

- **실행 완료 후 반드시 `/final-output-review`를 거친다.** 이 단계를 건너뛰고 작업을 종료하지 않는다.
- **Superpowers가 사용 가능한 환경에서는 반드시 사용한다.** 사용 불가능할 때만 직접 산출물을 작성한다.
- **검증**: 실행 후 `bash rd-workflow/scripts/verify.sh`를 실행한다.

## Review 규칙

- 큰 작업과 기존 산출물의 중간 이상 변경에서는 `REQUEST review`, `spec/plan review`, `final output review`를 건너뛰지 않습니다.
- review는 기본적으로 `prepare_review_pipeline.sh`로 세션을 만들고 `run_review_turn.sh`로 턴을 이어갑니다.
- 최신 Reviewer 턴이 `이의 없음`을 명시할 때까지 review를 이어갑니다.
- 사람 결정이 필요하거나 총 20턴에 도달하면 `awaiting-user`로 바꾸고 멈춥니다.
- **autopilot 모드에서는** `rd-workflow/claude_skills/autopilot/SKILL.md`의 Autonomy Override가 이 Review 규칙 섹션보다 우선합니다 (예: review 턴 한도 50턴, 자율 판단 등). 절대 규칙과 일반 모드의 20턴 규칙은 변하지 않습니다.
- review 세션 종료 시 `rd-workflow-workspace/reports/reviews/`에 주요 쟁점과 결론을 요약한 report를 작성합니다.

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

Status 필드는 아래 값만 사용합니다 (guard hook이 이 값으로 판정):

- `대기 중`
- `REQUEST review 대기`
- `spec/plan 작성 중`
- `spec/plan review 대기`
- `실행 중`
- `검증 중`
- `output review 대기`
- `완료`

`CURRENT_TASK.md`는 아래 시점마다 다시 씁니다.

- REQUEST 정리 후
- spec 생성 후
- plan 생성 후
- 실행 시작 시
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

- 새 산출물 spec: `rd-workflow-workspace/specs/base/`
- 기존 산출물 변경 change spec: `rd-workflow-workspace/specs/changes/`
- plan: `rd-workflow-workspace/plans/`

## 토큰 효율 규칙

- 이미 읽었거나 skill/memory에 있는 정보는 파일을 다시 읽지 않는다.
- 추측성 도구 호출을 하지 않는다 — 근거 없이 파일을 탐색하지 않는다.
- 독립적인 도구 호출은 병렬로 실행한다.
- 사용자가 방금 말한 내용을 반복하지 않는다.

## 버전 관리

- 산출물은 파일 시스템에 저장하고 변경 이력은 git으로 추적합니다.
- 커밋 메시지는 한국어로 작성합니다.
- 형식은 Conventional Commits를 따릅니다: `type: 요약`
- 파일 나열보다 무엇이 왜 바뀌었는지를 우선 적습니다.
