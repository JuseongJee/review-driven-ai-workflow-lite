# Prompts

이 디렉토리에는 워크플로에서 사용하는 프롬프트 파일이 있습니다.

## 구조

| 경로 | 용도 |
|------|------|
| `review/request_review.md` | REQUEST 리뷰 평가 기준 |
| `review/spec_review.md` | spec/plan 리뷰 평가 기준 |
| `review/project_context_review.md` | PROJECT_CONTEXT 리뷰 평가 기준 |
| `review/diff_review.md` | 최종 diff 리뷰 평가 기준 |

## 사용 방식

- 리뷰 프롬프트는 `prepare_review_pipeline.sh`가 자동으로 참조합니다.
- 검증은 `test.sh`, `lint.sh`, `typecheck.sh`가 담당합니다. 각 스크립트는 `PROJECT_CONTEXT.md`의 설정을 참조합니다.
- 프로젝트에 맞게 프롬프트를 수정하거나 추가할 수 있습니다.
