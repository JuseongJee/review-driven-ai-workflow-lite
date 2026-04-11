# Review-Driven AI Workflow — Lite

비개발 도메인(기획, 마케팅, 운영, 교육 등)을 위한 AI 워크플로 템플릿.

> **"Lite"는 적용 대상이 개발과 얽히지 않는다는 뜻이지, 워크플로가 가벼워진다는 뜻이 아닙니다.**

REQUEST → 리뷰 → spec/plan → 실행 → 검증 → 최종 리뷰까지, dev 버전과 동일한 구조적 엄밀함을 유지합니다. 개발 도구 의존(test/lint/typecheck, git diff review 등)만 제거하고 프롬프트 기반 검증과 산출물 리뷰로 대체했습니다.

## 전제 조건

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) 설치

## 빠른 시작

```bash
# 1. 템플릿 파일을 프로젝트 루트에 복사
cp -r <이 repo>/* <프로젝트 루트>/

# 2. PROJECT_CONTEXT.md 채우기
#    프로젝트 목적, 도메인, 산출물 유형, 품질 기준, 대상 독자 등

# 3. Claude Code 실행
claude

# 4. 첫 작업
#    "이 요구사항으로 진행해줘: ..."    (큰 작업)
#    "small-task로 바로 작성해줘: ..." (작은 작업)
```

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

## dev 버전과의 차이

| 항목 | dev | lite |
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
