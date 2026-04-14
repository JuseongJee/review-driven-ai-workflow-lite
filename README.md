# Review-Driven AI Workflow — Lite

비개발 도메인(기획, 마케팅, 운영, 교육 등)을 위한 AI 워크플로 템플릿.

> **"Lite"는 적용 대상이 개발과 얽히지 않는다는 뜻이지, 워크플로가 가벼워진다는 뜻이 아닙니다.**

REQUEST → 리뷰 → spec/plan → 실행 → 검증 → 최종 리뷰까지, dev 버전과 동일한 구조적 엄밀함을 유지합니다. 개발 도구 의존(test/lint/typecheck, git diff review 등)만 제거하고 프롬프트 기반 검증과 산출물 리뷰로 대체했습니다.

## 전제 조건

- [Claude Code](https://claude.ai/code) 설치 및 로그인
- [Superpowers](https://github.com/anthropics/claude-code-superpowers) 플러그인 설치

## 빠른 시작

프로젝트 디렉토리에서 Claude Code를 열고:

```text
이 AI 워크플로 템플릿 적용해: https://github.com/JuseongJee/review-driven-ai-workflow-lite
```

> **Claude에게:** 이 요청을 받았다면 [`rd-workflow/docs/guides/setup_with_claude.md`](rd-workflow/docs/guides/setup_with_claude.md)를 읽고 절차대로 실행하세요.

AI가 필요한 파일을 가져온 뒤, 프로젝트에 대해 질문하면서 PROJECT_CONTEXT.md를 함께 채워줍니다. 빈 폴더에서 시작해도 대화를 통해 프로젝트의 목적, 산출물, 품질 기준을 구체화합니다.


### 적용 후

설정이 끝나면 바로 첫 작업을 시작합니다:

```text
이 요구사항으로 진행해줘: ...
```

## 사용 예시 — 단계별 프롬프트

### 큰 작업

```text
1. "이 요구사항으로 진행해줘: 면접 질문지에 컬쳐 인터뷰 항목 추가"
   → AI가 REQUEST를 작성하고 review를 시작합니다

2. (review 확인, AI의 질문에 답변 후) "진행해"
   → AI가 spec과 plan을 작성하고 review를 시작합니다

3. (spec/plan review 확인, 필요시 수정 방향 전달 후) "진행해"
   → AI가 작성을 시작합니다

4. 작성 완료 → AI가 자동으로 검증 + 산출물 review를 진행합니다

5. (review 확인 후) "좋아, 마무리해줘"
```

### 작은 작업

```text
1. "small-task로 바로 해줘: 운영 매뉴얼의 고객 응대 섹션 업데이트"
   → AI가 바로 작성 → 검증 → review까지 진행합니다
```

### Autopilot

```text
1. "/autopilot"
   → 백로그에서 작업을 선택하고 전체 파이프라인을 자율 실행합니다
```

사용자가 하는 건 **요구사항 전달 + review 결과 판단** 정도입니다. 나머지는 워크플로가 이어갑니다.

## 핵심 구조

| 파일 | 역할 |
|------|------|
| `CLAUDE.md` | AI 실행 규칙 |
| `PROJECT_CONTEXT.md` | 프로젝트/도메인 메타데이터 |
| `REQUEST.md` | 현재 작업 요청서 |
| `CURRENT_TASK.md` | 진행 중인 작업 상태 |
| `WORKING_WITH_AI.md` | 사용법 치트시트 |

## 워크플로

### 큰 작업
```
FR 자동 등록 → [large 판단] → REQUEST 작성 → REQUEST review → spec/plan → spec/plan review → 실행 → 검증 → final output review → 아카이브
```

### 작은 작업
```
FR 자동 등록 → [small 판단] → REQUEST 정리 → 실행 → 검증 → 아카이브
```

사용자가 작업을 요청하면 먼저 FR에 자동 등록된 뒤, Intake 규칙이 small/large를 자동 판단하여 해당 경로로 진행합니다.

## Developer 버전과의 차이

| 항목 | Developer | Lite |
|------|-----|------|
| 검증 | test.sh + lint.sh + typecheck.sh | verify.sh (프롬프트 기반) |
| 최종 리뷰 | diff review (코드 변경) | output review (산출물 품질) |
| PROJECT_CONTEXT | tech stack, build 명령 | 도메인, 산출물 유형, 품질 기준 |
| 스킬 | 12개 | 6개 (핵심만) |
| 리뷰 파이프라인 | 동일 | 동일 |
| Superpowers | 동일 | 동일 |

## 템플릿 업데이트

이미 적용된 프로젝트에서 최신 버전으로 업데이트하는 방법입니다.

### URL로 업데이트 (repo 접근 가능할 때)

```text
/tpl update
```

또는:

```text
이 템플릿으로 업데이트해: https://github.com/JuseongJee/review-driven-ai-workflow-lite
```


## 문서

- [초기 설정 가이드](rd-workflow/docs/guides/setup.md)
- [사용자 매뉴얼](rd-workflow/docs/USER_MANUAL.md)
- [워크플로 판단 기준](rd-workflow/docs/flows/WORKFLOW.md)
- [문서 인덱스](rd-workflow/docs/AI_DOC_MAP.md)
