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

AI가 필요한 파일을 가져와서 프로젝트에 맞게 배치하고, PROJECT_CONTEXT.md를 채워줍니다.

### 적용 후 할 일

1. AI에게 말한다: "프로젝트 분석해서 PROJECT_CONTEXT.md 채워줘"
2. 첫 작업을 요청한다: "이 요구사항으로 진행해줘: ..."

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
REQUEST 작성 → REQUEST review → spec/plan → spec/plan review → 실행 → 검증 → final output review → 아카이브
```

### 작은 작업
```
REQUEST 정리 → 실행 → 검증 → 아카이브
```

## Developer 버전과의 차이

| 항목 | Developer | Lite |
|------|-----|------|
| 검증 | test.sh + lint.sh + typecheck.sh | verify.sh (프롬프트 기반) |
| 최종 리뷰 | diff review (코드 변경) | output review (산출물 품질) |
| PROJECT_CONTEXT | tech stack, build 명령 | 도메인, 산출물 유형, 품질 기준 |
| 스킬 | 12개 | 6개 (핵심만) |
| 리뷰 파이프라인 | 동일 | 동일 |
| Superpowers | 동일 | 동일 |

## 문서

- [초기 설정 가이드](ai/docs/guides/setup.md)
- [사용자 매뉴얼](ai/docs/USER_MANUAL.md)
- [워크플로 판단 기준](ai/docs/flows/WORKFLOW.md)
- [문서 인덱스](ai/docs/AI_DOC_MAP.md)
