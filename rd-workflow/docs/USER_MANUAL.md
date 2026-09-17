# 사용자 매뉴얼

## 개요

이 템플릿은 비개발 도메인(기획, 마케팅, 운영, 교육 등)에서 AI와 체계적으로 산출물을 만들기 위한 워크플로입니다.

해결하는 문제:
- AI에게 "알아서 해줘"라고 하면 품질이 들쭉날쭉
- 큰 작업을 한 번에 시키면 방향이 틀어져도 늦게 발견
- 피드백과 수정 이력이 남지 않음

접근 방식:
- 요청 → 설계 → 리뷰 → 실행 → 검증 → 최종 리뷰 순서를 강제
- 각 단계에서 AI 스스로 교차 검토
- 모든 과정이 파일로 남아 추적 가능

## 초기 설정

`rd-workflow/docs/guides/setup.md`를 참조하세요.

핵심: `PROJECT_CONTEXT.md`를 채우는 것이 첫 번째이자 가장 중요한 단계입니다.

### 팀 프로젝트에 개인 설치

내 private overlay repo 를 루트로 두고 팀 저장소를 그 아래 git submodule 로 붙입니다.
팀 repo 워킹트리에는 아무것도 두지 않습니다.

- **처음 설치**: [team-overlay-fresh-install.md](guides/team-overlay-fresh-install.md)
- **이미 설치된 프로젝트에서 이관**: [team-overlay-migration.md](guides/team-overlay-migration.md)

## 핵심 개념

### 작업 분류

| 등급 | 기준 | 흐름 |
|------|------|------|
| `light` | 문구·오탈자 등 경미한 수정 | 실행 → 검증 → 재분류 → 기본 브랜치 커밋 1회 |
| `standard` | 국소 변경, 산출물 구조 불변 | REQUEST → 실행 → 검증 → 재분류 → final output review → 아카이브 |
| `full` | 새 기능, 산출물 구조·품질 기준의 큰 변경 | REQUEST → 리뷰 → spec/plan → 리뷰 → 실행 → 검증 → output 리뷰 → 아카이브 |

AI가 `rd-workflow/docs/flows/WORKFLOW.md` 위험 등급 절의 신호표로 `light`/`standard`/`full` 등급을 판정해 시작 보고를 냅니다. 등급 하향은 사용자만 할 수 있습니다.

### 4개 핵심 문서

| 문서 | 역할 | 갱신 시점 |
|------|------|-----------|
| PROJECT_CONTEXT.md | 프로젝트 메타데이터, 품질 규칙 | 초기 설정, 프로젝트 변경 시 |
| REQUEST.md | 현재 작업 요청서 | 매 작업 시작 시 |
| CURRENT_TASK.md | 진행 상태 추적 | 단계 전환마다 자동 갱신 |
| WORKING_WITH_AI.md | 사용자 치트시트 | 변경 없음 (참조용) |

### Superpowers

Claude Code의 내장 워크플로 기능입니다. 설계 → 계획 → 실행 순서를 구조화합니다.

- **brainstorming**: 아이디어 탐색, 요구사항 정리
- **writing-plans**: spec과 plan 작성
- **subagent-driven-development**: 태스크를 subagent로 dispatch (기본, 병렬·순차 모두 가능)
- **executing-plans**: 메인 세션에서 직접 실행 (태스크 1개+파일 3개 이하, 또는 태스크 2개+동일 파일 1개일 때)

Superpowers가 사용 가능한 환경에서는 반드시 사용합니다.

### Future Request 생명주기

```
idea → validated → ready-for-request → REQUEST로 승격 → done
                                     ↘ parked (조건부 보류)
                                     ↘ dropped (폐기)
```

활성 항목은 `FUTURE_REQUESTS.md`, 보류 항목은 `FUTURE_REQUESTS_PARKED.md`에서 관리합니다.

## 일상 워크플로

### `full` 등급

```
1. "이 요구사항으로 진행해줘: ..."
2. AI가 REQUEST.md 작성 → REQUEST 리뷰
3. spec/plan 작성 → spec/plan 리뷰
4. 실행 (산출물 작성)
5. 검증 (bash rd-workflow/scripts/test.sh, lint.sh, typecheck.sh)
6. final diff review
7. REQUEST 아카이브
```

사용자는 각 리뷰 결과를 확인하고, 필요하면 피드백을 줍니다.

### `standard` 등급

```
1. "바로 작성해줘: ..."
2. AI가 등급 판정(`standard`) → 축약 REQUEST → 바로 실행
3. 검증
4. final diff review
5. REQUEST 아카이브
```

### 백로그 관리

```
"future request에 기록해줘: ..."     → 아이디어 등록
"future request 목록 보여줘"         → 현재 백로그 조회
"이거 REQUEST로 올려서 진행해줘"       → FR을 작업으로 승격
```

### Autopilot

FUTURE_REQUESTS에서 작업을 선택하고 전체 파이프라인을 자율 실행합니다.

```
"autopilot으로 다음 작업 진행해줘"
```

자율 실행 중에도 모든 리뷰 단계를 거칩니다. 사람 결정이 필요하면 멈추고 알려줍니다.

## 스킬 레퍼런스

### workflow-router

다음 단계를 추천합니다. 어떤 skill을 써야 할지 모를 때 자동으로 라우팅합니다.
사용자가 직접 호출하지 않아도 배경에서 동작합니다.

### request-to-reviewed-plan

`full` 등급 작업의 전체 준비 과정을 담당합니다.
자유 텍스트 요구사항 → FR 자동 등록 → 위험 등급 판정 → 해당 skill로 진행.
`full`일 때: REQUEST.md → REQUEST 리뷰 → spec → plan → spec/plan 리뷰.

```
"이 요구사항으로 request-to-reviewed-plan으로 진행해줘"
```

### small-task-implement

`standard` 등급(국소 변경, 산출물 구조 불변) 작업을 바로 실행합니다. 등급은 AI 가 `WORKFLOW.md` 위험 등급 절의 신호표로 판정하고, 하향은 사용자만 합니다. `light`(문구·오탈자) 는 skill 없이 커밋 1회로 끝납니다.
promote → 축약 REQUEST → 실행 → 검증 → 재분류 → final diff review.

```
"standard 로 바로 작성해줘: ..."
```

### final-diff-review

실행 완료 후 산출물 최종 리뷰를 수행합니다.
검증 통과 여부 확인 → 산출물 품질 리뷰 → 이의 없을 때까지 반복.

```
"final-diff-review로 진행해줘"
```

### fr

Future Request를 관리합니다.
서브커맨드: add, list, pri(우선순위 변경), archive, park, status.

```
"/fr add 분기 보고서 양식 표준화"
"/fr list"
"/fr archive 2026-04-01-report-template"
```

### autopilot

FUTURE_REQUESTS에서 작업을 선택하고 전체 파이프라인(리뷰 포함)을 자율 실행합니다.
사람 판단이 필요한 시점에서 멈춥니다.

## 리뷰 파이프라인

### 구조

리뷰는 파일 기반 턴제로 동작합니다.

```
rd-workflow-workspace/handoffs/review-{세션명}/
├── session.json       # 세션 메타데이터
├── 001_author.md      # Author의 초기 제출
├── 002_reviewer.md    # Reviewer 피드백
├── 003_author.md      # Author 수정/응답
└── ...
```

### 리뷰 유형

| 유형 | 시점 | 평가 대상 |
|------|------|-----------|
| REQUEST review | 요청 정리 후 | 목표 명확성, 범위 적정성, 제약 충분성 |
| spec/plan review | spec/plan 작성 후 | 설계 적합성, 누락 여부, 실행 가능성 |
| final diff review | 구현 완료 후 | diff 품질, REQUEST 충족도, 회귀 위험 |

### 흐름

1. `prepare_review_pipeline.sh`로 세션 생성
2. `run_review_turn.sh`로 턴 실행 (Author → Reviewer → Author → ...)
3. Reviewer가 `이의 없음`을 명시하면 종료
4. 20턴 도달 시 `awaiting-user`로 전환

## 검증 시스템

프로젝트의 검증 스크립트를 실행합니다.

```bash
bash rd-workflow/scripts/test.sh
bash rd-workflow/scripts/lint.sh
bash rd-workflow/scripts/typecheck.sh
```

각 스크립트는 `PROJECT_CONTEXT.md`의 설정을 참조하여 적절한 검증을 실행합니다. 프로젝트에 해당 도구가 없으면 스크립트가 건너뜁니다.

## 설정 파일

### rd-workflow/config/workflow.json

```json
{
  "auto_completion_report": false,
  "intake_source": "text",
  "fr_github": false,
  "default_execution_mode": "semi-auto"
}
```

- `auto_completion_report`: 작업 완료 시 보고서 자동 생성 여부
- `intake_source`: 입력 소스 유형
- `fr_github`: GitHub Issues 연동 여부
- `default_execution_mode`: 기본 실행 모드. **기본값은 `"semi-auto"`** 이며 파일이나 키가 없어도 `semi-auto` 로 판정합니다. 단계마다 확인받는 종전 동작으로 되돌리려면 이 키에 `"manual"` 을 적습니다. 값을 판정할 수 없으면 `manual` 로 떨어지며 경고가 표시되고, 세션 지시가 이 값보다 우선합니다.

이 파일은 배포본에 실체로 포함되어 있으므로 **직접 편집합니다.** example 파일을 무조건 복사하면 배포한 기본값과 적어 둔 설정이 덮이므로, 복사는 **경로가 없을 때만** 합니다. `.example` 에서 최초 1회 만드는 것은 배포본에 실체가 없는 설정(예: `review-tools.json`)에 해당합니다.

### rd-workflow/config/review-tools.json

리뷰 도구 우선순위와 설정. 교차 리뷰를 위해 여러 도구를 등록할 수 있습니다.

codex 의 추론 깊이는 `tools.codex.reasoning_effort`(리뷰 타입별로는 `overrides.{타입}.tools.codex.reasoning_effort`)로
조절합니다. 키가 없으면 아무것도 전달하지 않고 전역 `~/.codex/config.toml` 설정을 그대로 따릅니다.
`RD_REVIEW_EFFORT_OVERRIDE=0` 이면 설정을 남긴 채 즉시 무력화하며, 적용 결과는 턴 완료 시
`effort override: <상태>` 로 표시됩니다. 모델은 전역 설정이 단일 진실 원천이라 codex 에는 `model` 을 두지 않습니다.

## 디렉토리 구조

```
프로젝트 루트/
├── CLAUDE.md                    # AI 실행 규칙
├── PROJECT_CONTEXT.md           # 프로젝트 메타데이터
├── REQUEST.md                   # 현재 작업 요청서
├── CURRENT_TASK.md              # 진행 상태
├── WORKING_WITH_AI.md           # 사용자 치트시트
├── .claude/settings.json        # Claude Code 설정
└── rd-workflow/
    ├── config/
    │   ├── workflow.json        # 워크플로 설정
    │   └── review-tools.json    # 리뷰 도구 설정
    ├── docs/
    │   ├── AI_DOC_MAP.md        # 문서 인덱스
    │   ├── USER_MANUAL.md       # 이 파일
    │   ├── flows/
    │   │   └── WORKFLOW.md      # 작업 분기 기준
    │   ├── guides/
    │   │   └── setup.md         # 초기 설정 가이드
    │   └── prompts/
    │       ├── review/          # 리뷰 프롬프트
    │       └── verify/          # 검증 프롬프트
    ├── claude_skills/
    │   ├── workflow-router/
    │   ├── request-to-reviewed-plan/
    │   ├── small-task-implement/
    │   ├── final-diff-review/
    │   ├── fr/
    │   └── autopilot/
    ├── scripts/
    │   ├── test.sh
    │   ├── lint.sh
    │   ├── typecheck.sh
    │   ├── prepare_review_pipeline.sh
    │   ├── run_review_turn.sh
    │   ├── review_common.sh
    │   └── adapter_claude.sh
    └── workspace/
        ├── backlog/
        │   ├── FUTURE_REQUESTS.md
        │   ├── FUTURE_REQUESTS_PARKED.md
        │   ├── items/
        │   └── request-archive/
        ├── specs/
        │   ├── base/
        │   └── changes/
        ├── plans/
        └── reports/
            ├── completions/
            ├── reviews/
            └── verifications/
```

## 트러블슈팅

| 상황 | 해결 |
|------|------|
| AI가 워크플로를 안 따름 | "CLAUDE.md 다시 읽고 워크플로대로 진행해" |
| 등급이 과하게 잡힘 | "standard 로 내려서 진행해줘" 명시 (하향은 사용자만) |
| 검증이 계속 FAIL | `test.sh`/`lint.sh`/`typecheck.sh` 설정과 PROJECT_CONTEXT.md 검증 명령 확인 |
| 리뷰가 20턴 넘어도 끝나지 않음 | `awaiting-user`로 전환됨 — 직접 판단 후 진행 지시 |
| 산출물 파일을 못 찾음 | CURRENT_TASK.md의 `Output Files` 섹션 확인 |
| skill이 원하는 출력을 안 냄 | `rd-workflow/docs/prompts/recovery/` 참조 |
| 검증 스크립트 실행 실패 | test.sh/lint.sh/typecheck.sh 및 의존 도구 설치 상태 확인 |
| PROJECT_CONTEXT.md가 비어 있음 | `rd-workflow/docs/guides/setup.md` 참조하여 채우기 |
