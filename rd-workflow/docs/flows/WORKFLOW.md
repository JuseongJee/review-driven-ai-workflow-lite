# Workflow

이 문서는 전체 작업 흐름을 한 페이지에 모아 둔 문서입니다.

평소에는 `WORKING_WITH_AI.md`를 먼저 읽고,
큰 작업과 작은 작업의 분기가 헷갈릴 때 이 문서를 읽습니다.

## 큰 작업 vs 작은 작업 판단 기준

이 판단이 전체 흐름의 핵심 분기입니다.

**작은 작업은 사용자가 직접 지정합니다.** AI가 자체적으로 작은 작업이라고 판단하지 않습니다.
사용자가 "small-task로 처리해줘", "이건 small이야" 등 명시적으로 말한 경우에만 작은 작업 흐름을 탑니다.

작은 작업의 일반적 특징 (참고용):
- 변경 파일이 2~3개 이하
- 새 API/인터페이스를 만들지 않음
- 기존 테스트로 검증이 충분하거나 테스트 추가가 간단함
- 다른 모듈에 파급 영향이 거의 없음
- 예: 버그 수정, 문구 변경, 설정값 조정, 단순 유틸 추가

**큰 작업**으로 봐야 하는 경우:
- 여러 파일/모듈이 함께 바뀜
- 새 API, 데이터 모델, UI 흐름이 추가됨
- 기존 동작이 달라지거나 마이그레이션이 필요함
- 테스트 전략을 새로 잡아야 함
- 예: 새 기능 추가, 아키텍처 변경, 대규모 리팩터링

사용자가 small로 지정하지 않은 모든 작업은 큰 작업으로 취급합니다.

## 입력 소스

작업을 시작할 때 입력이 어디서 오는지에 따라 진입점이 달라집니다.

### 자유 텍스트 요구사항 (기본)

사용자가 직접 요구사항을 말하면:
1. FR에 자동 등록 (Intake 규칙 적용)
2. 사용자가 다음 단계를 지정 → 해당 skill로 진행

큰 작업의 자유 텍스트 진행 순서:
`/planning-design-intake` → REQUEST.md 생성 → `/request-to-reviewed-plan` (spec/plan)

`/request-to-reviewed-plan` 은 이미 작성된 REQUEST.md 를 입력으로 한다.
새 자유 텍스트 큰 작업에서 RTRP 를 직접 호출하지 않는다 — `/planning-design-intake` 를 먼저 호출한다.

### /fr add 직접 호출

등록만 수행, 실행하지 않음 (기존과 동일).

### 기획서 (외부 문서)

기획서 텍스트가 있으면:
1. FR에 자동 등록 (Intake 규칙 적용)
2. `/planning-design-intake` → REQUEST.md 생성 → `/request-to-reviewed-plan`
(v1: 기획서 텍스트 필수. 디자인 URL/스크린샷은 선택 — 있으면 Design Reference Memo로 수집)

### 갭 체크 (선택)

spec 작성 직후, spec/plan review 전에 → `/gap-check`
Design Reference가 있으면 추천. 없어도 에러/엣지 케이스 점검 가능.

## 기본 분기

### 작은 작업

`FR 자동 등록 → REQUEST 정리 → 구현 → 검증 → 필요 시 final diff review → REQUEST 아카이브`

### 큰 작업 / 기존 코드베이스의 중간 이상 변경

`FR 자동 등록 → REQUEST 정리 → REQUEST review → spec/change spec → plan → spec/plan review → 구현 → 검증 → final diff review → REQUEST 아카이브`

## REQUEST 아카이브

작업이 완료되면 현재 `REQUEST.md`를 `rd-workflow-workspace/backlog/request-archive/`에 보관합니다.

- 파일명: `YYYY-MM-DD-HHMM-${SHORT_TITLE}.md` (`SHORT_TITLE` 은 `CURRENT_TASK.md ## Short Title` 에서 read — canonical regex 검증된 값)
- 새 REQUEST로 덮어쓰기 전에 먼저 아카이브합니다
- 아카이브 후 `REQUEST.md`는 빈 템플릿으로 되돌립니다

## Raw Capture

각 진입점에서 사용자 원본 입력을 `rd-workflow-workspace/raw-captures/YYYY-MM-DD-HHMM-{stage}-{short-title}.md` 에 가공 없이 기록한다.

### Stage / 진입점

| stage | skill |
|-------|-------|
| fr | `/fr add` |
| request | `planning-design-intake`, `request-to-reviewed-plan`, `small-task-implement` |
| spec | `request-to-reviewed-plan` (spec 작성 직전) |
| plan | `request-to-reviewed-plan` (plan 작성 직전) |

### Short Title 계약

- single source of truth: `CURRENT_TASK.md ## Short Title`
- canonical: `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (영문 kebab-case, 영숫자 시작·끝, `-` 단독 / empty / hyphen-only 금지 — `-` 는 reserved sentinel)
- 부여 진입점 (start point — 3 곳): `/fr add` (FR 시작), `planning-design-intake` (FR 없는 직접 REQUEST), `small-task-implement` (FR 없는 직접 small-task). 부여 조건은 진입점별로 다름:
  - **`planning-design-intake` / `small-task-implement` — equality-aware 3-way:**
    - (a) `## Short Title = -` 또는 섹션 부재 → CANDIDATE 기록 (부재 시 섹션 자동 추가)
    - (b) `## Short Title = CANDIDATE` (equal) → read-only continue
    - (c) `## Short Title ≠ CANDIDATE` AND ≠ `-` → active-task guard (명시 경고 + skill 차단)
  - **`/fr add` — `Intake 규칙` 따라:**
    - `## Short Title = -` → 새로 부여 (baseline)
    - non-`-` → read-only (FR 등록 + FR 캡처는 새 short-title, `CURRENT_TASK` 변경 안 함)
    - 섹션 부재 → warn-only (legacy active task 보호)
- `request-to-reviewed-plan` FR 승격 진입 — 3-way (rebind / baseline equal / active-task guard) 별도 항목
- 부여 후 ~ archive 까지 immutable (변경 금지)
- 캡처 단계 (`request-to-reviewed-plan` 의 일반 진입) 는 short-title 부재 시 부여 안 함, 캡처 생략 + 경고
- post-plan skill (`implement-reviewed-plan`, `final-diff-review`) 은 read-only
- reset trigger 3 가지: (1) autopilot REQUEST archive, (2) 수동 archive (`request-archive/README.md` 4 단계), (3) `planning-design-intake` overwrite-backup (implicit archive). 모두 default `-` 로 복귀

### Archive 통합

archive trigger 3 가지:

- `/fr archive`: `done`/`dropped` FR 의 short-title → `*-fr-{short-title}.md` 를 `raw-captures/archive/` 로 이동
- REQUEST archive (autopilot / 수동): 활성 작업 short-title → `*-{request,spec,plan}-{short-title}.md` 를 `raw-captures/archive/` 로 이동 + `## Short Title` reset
- `planning-design-intake` overwrite-backup = implicit archive: 기존 REQUEST.md 존재 시 자동으로 REQUEST 백업 + 같은 short-title 의 request/spec/plan 캡처 archive + `## Short Title` reset → 새 작업 진행. drift 상태 (REQUEST.md 있는데 `## Short Title` = `-`/부재) 는 캡처 archive skip + 명시적 경고

archive 매칭은 frontmatter exact match (filename prefix collision + body-content collision 모두 차단).

### git 미추적

`rd-workflow-workspace/raw-captures/` 는 `.gitignore` 로 제외 (소스 dev / `_ROOT_FILES*` / 마이그레이션 가이드 3중 보장).

## 기본 원칙

- skill이 있으면 skill부터 호출합니다
- skill이 없거나 원하는 출력이 안 나오면 `rd-workflow/docs/prompts/`에서 맞는 프롬프트를 꺼냅니다
- 큰 작업은 reviewed spec / plan 파일을 만든 뒤에만 구현합니다
- 범위를 벗어난 아이디어는 `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`에 적습니다

## 권장 skill 순서

- 다음 단계를 고르기 어렵다면 `workflow-router`
- 기획서 텍스트가 있으면 `planning-design-intake`
- 자유 텍스트 큰 작업 시작은 `planning-design-intake` → REQUEST.md 생성 → `request-to-reviewed-plan`
- REQUEST.md 가 이미 있으면 `request-to-reviewed-plan` (spec/plan 작성 + review)
- spec 갭 점검은 `gap-check`
- 작은 작업 구현은 `small-task-implement`
- reviewed plan 구현은 `implement-reviewed-plan`
- 마무리는 `final-diff-review`

## 프로젝트 초기 설정

1. `PROJECT_CONTEXT.md`를 만듭니다
2. `rd-workflow/scripts/{build,test,lint,typecheck}.sh`를 프로젝트 명령으로 채웁니다
3. 빈칸이나 불명확한 제약이 남아 있으면 `PROJECT_CONTEXT` review를 돌립니다

초기 설정 절차는 `rd-workflow/docs/guides/setup_with_claude.md`에 있습니다.

## Review Pipeline

- review는 기본적으로 `prepare_review_pipeline.sh`로 세션을 만들고 `run_review_turn.sh`로 턴을 이어갑니다
- 사용자는 보통 검토 시작만 말하고, 세션 파일 작성과 턴 전환은 AI가 처리합니다
- 세부 규칙은 `rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md`에 적혀 있습니다

## Prompt 사용 위치

- 보정: `rd-workflow/docs/prompts/recovery/`
- 수동 복구: `rd-workflow/docs/prompts/manual/`
- 리뷰 기준: `rd-workflow/docs/prompts/review/`
