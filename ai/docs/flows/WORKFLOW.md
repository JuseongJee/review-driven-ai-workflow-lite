# Workflow

이 문서는 전체 작업 흐름을 한 페이지에 모아 둔 문서입니다.

평소에는 `WORKING_WITH_AI.md`를 먼저 읽고,
큰 작업과 작은 작업의 분기가 헷갈릴 때 이 문서를 읽습니다.

## 큰 작업 vs 작은 작업 판단 기준

이 판단이 전체 흐름의 핵심 분기입니다.

**작은 작업은 사용자가 직접 지정합니다.** AI가 자체적으로 작은 작업이라고 판단하지 않습니다.
사용자가 "small-task로 처리해줘", "이건 small이야" 등 명시적으로 말한 경우에만 작은 작업 흐름을 탑니다.

작은 작업의 일반적 특징 (참고용):
- 변경/생성 파일이 2~3개 이하
- 새 구조나 체계를 도입하지 않음
- 기존 산출물에 미치는 영향이 거의 없음
- 단순 수정, 문구 변경, 설정 조정 수준
- 예: 오타 수정, 문구 다듬기, 설정값 변경, 짧은 메모 추가

**큰 작업**으로 봐야 하는 경우:
- 여러 산출물이 함께 바뀜
- 새 구조, 체계, 프레임워크를 도입함
- 기존 산출물의 방향이나 논조가 달라짐
- 품질 기준을 새로 정해야 함
- 예: 새 보고서 작성, 기획서 전면 재구성, 콘텐츠 시리즈 기획

사용자가 small로 지정하지 않은 모든 작업은 큰 작업으로 취급합니다.

## 입력 소스

작업을 시작할 때 입력이 어디서 오는지에 따라 진입점이 달라집니다.

### 자유 텍스트 요구사항 (기본)

사용자가 직접 요구사항을 말하면 → `/request-to-reviewed-plan`

### 기획 문서 (외부 문서)

기획 문서나 참고 자료 텍스트가 있으면 → REQUEST.md에 정리 → `/request-to-reviewed-plan`

## 기본 분기

### 작은 작업

`REQUEST 정리 -> 실행 -> 검증 -> 필요 시 final output review -> REQUEST 아카이브`

### 큰 작업 / 기존 산출물의 중간 이상 변경

`REQUEST 정리 -> REQUEST review -> spec/change spec -> plan -> spec/plan review -> 실행 -> 검증 -> final output review -> REQUEST 아카이브`

## Spec 유형 선택

- **새 산출물 spec** (`ai/workspace/specs/base/`): 처음 만드는 산출물. 목적, 대상, 구조, 품질 기준을 정의.
- **기존 산출물 변경 spec** (`ai/workspace/specs/changes/`): 이미 있는 산출물을 고치거나 확장. 현재 상태, 변경 이유, 변경 범위를 정의.

판단 기준:
- 산출물이 아직 없다 → 새 산출물 spec
- 산출물이 있고 그걸 고친다 → 변경 spec
- 애매하면 변경 spec으로 시작 (범위가 더 좁아서 안전)

## REQUEST 아카이브

작업이 완료되면 현재 `REQUEST.md`를 `ai/workspace/backlog/request-archive/`에 보관합니다.

- 파일명: `YYYY-MM-DD-HHMM-작업명.md`
- 새 REQUEST로 덮어쓰기 전에 먼저 아카이브합니다
- 아카이브 후 `REQUEST.md`는 빈 템플릿으로 되돌립니다

## 핵심 원칙

- skill이 있으면 skill부터 호출합니다
- skill이 없거나 원하는 출력이 안 나오면 `ai/docs/prompts/`에서 맞는 프롬프트를 꺼냅니다
- 큰 작업은 reviewed spec / plan 파일을 만든 뒤에만 실행합니다
- 범위를 벗어난 아이디어는 `ai/workspace/backlog/FUTURE_REQUESTS.md`에 적습니다

## 권장 skill 순서

- 다음 단계를 고르기 어렵다면 `workflow-router`
- 큰 작업 시작은 `request-to-reviewed-plan`
- 작은 작업 실행은 `small-task-implement`
- 마무리는 `final-output-review`

## 프로젝트 초기 설정

1. `PROJECT_CONTEXT.md`를 채웁니다
2. `ai/docs/prompts/verify/default.md`를 프로젝트에 맞게 조정합니다
3. 빈칸이나 불명확한 제약이 남아 있으면 `PROJECT_CONTEXT` review를 돌립니다

초기 설정 절차는 `ai/docs/guides/setup.md`에 있습니다.

## Review Pipeline

- review는 기본적으로 `prepare_review_pipeline.sh`로 세션을 만들고 `run_review_turn.sh`로 턴을 이어갑니다
- 사용자는 보통 검토 시작만 말하고, 세션 파일 작성과 턴 전환은 AI가 처리합니다

## Prompt 사용 위치

- 보정: `ai/docs/prompts/recovery/`
- 리뷰 기준: `ai/docs/prompts/review/`
- 검증: `ai/docs/prompts/verify/`
