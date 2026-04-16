# AI Doc Map

이 프로젝트의 AI 워크플로 문서 위치를 정리합니다.

## 루트 문서

| 파일 | 역할 |
|------|------|
| CLAUDE.md | AI 실행 규칙 |
| PROJECT_CONTEXT.md | 프로젝트/도메인 메타데이터 |
| REQUEST.md | 현재 작업 요청서 |
| CURRENT_TASK.md | 진행 중인 작업 상태 |
| WORKING_WITH_AI.md | 사용자 치트시트 |

## rd-workflow/docs/

| 경로 | 역할 |
|------|------|
| flows/WORKFLOW.md | 작업 분기 판단 기준 |
| prompts/review/ | 리뷰 평가 프롬프트 |
| guides/setup.md | 초기 설정 가이드 (수동) |
| guides/setup_with_claude.md | Claude 실행 설치 가이드 (권장) |

## rd-workflow-workspace/

| 경로 | 역할 |
|------|------|
| specs/base/ | 새 산출물 spec |
| specs/changes/ | 기존 산출물 변경 spec |
| plans/ | 실행 계획 |
| backlog/ | Future Requests, 아카이브 |
| reports/completions/ | 작업 완료 보고서 |
| reports/reviews/ | 리뷰 세션 요약 |
| reports/verifications/ | 검증 결과 |

## rd-workflow/scripts/

| 경로 | 역할 |
|------|------|
| test.sh | 테스트 실행 |
| lint.sh | 린트 실행 |
| typecheck.sh | 타입 검사 실행 |
| prepare_review_pipeline.sh | 리뷰 세션 생성 |
| run_review_turn.sh | 리뷰 턴 실행 |
| review_common.sh | 리뷰 공통 함수 |
| adapter_claude.sh | Claude CLI 어댑터 |

## rd-workflow/claude_skills/

| 스킬 | 역할 |
|------|------|
| workflow-router | 다음 단계 라우팅 |
| request-to-reviewed-plan | 요청 → 리뷰된 plan |
| small-task-implement | 작은 작업 바로 실행 |
| final-diff-review | 최종 diff 리뷰 |
| fr | Future Request 관리 |
| autopilot | 자율 파이프라인 실행 |
