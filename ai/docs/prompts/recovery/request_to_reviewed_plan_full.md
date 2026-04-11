# Request To Reviewed Plan — 전체 흐름 (수동 복구용)

이 프롬프트는 `request-to-reviewed-plan` skill이 작동하지 않을 때 수동으로 같은 절차를 따르기 위한 것입니다.

## 절차

### 1. REQUEST 작성
- 사용자의 요구사항을 `REQUEST.md`에 정리
- Task Type, Execution Path, Acceptance Criteria를 빠짐없이 채움

### 2. REQUEST review
```bash
bash ai/scripts/prepare_review_pipeline.sh request
```
- 리뷰어가 `이의 없음`을 명시할 때까지 턴을 이어감

### 3. Spec 작성
- Execution Path에 따라 spec 또는 change-spec 작성
- 저장: `ai/workspace/specs/base/` 또는 `ai/workspace/specs/changes/`
- 파일명: `YYYY-MM-DD-HHMM-작업명-spec.md`

### 4. Plan 작성
- spec을 기반으로 실행 계획 작성
- 저장: `ai/workspace/plans/YYYY-MM-DD-HHMM-작업명-plan.md`

### 5. Spec/Plan review
```bash
bash ai/scripts/prepare_review_pipeline.sh spec-plan [spec-path] [plan-path]
```
- 리뷰어가 `이의 없음`을 명시할 때까지 턴을 이어감

### 6. 완료
- `CURRENT_TASK.md` 업데이트
- 실행 단계로 전환
