붙어 있는 세션 경로(예: `rd-workflow-workspace/handoffs/review_pipeline/YYYYMMDD_HHMMSS_세션명`)와 `rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md`를 읽고 파일 기반 review를 이어줘.

수동으로 쓴 리뷰어 턴은 실행 기록을 남기지 않습니다. 수동으로만 리뷰한 final diff 세션은 `rd review seal` 이 거부하며, 발행은 `archive.sh --force-skip-review-check <사유>`(audit 기록)로 합니다.

절차:
1. `SESSION.md`, `CHECKPOINT.md`, 최신 턴 파일 1개, 검토 대상을 읽는다. 이전 턴은 `turns/` 디렉토리에서 필요할 때만 참조한다
2. 자기 차례가 아니면 상태만 짧게 알린다
3. 자기 차례면 `turns/NNN_<agent>.md` 한 파일만 추가한다
4. `CHECKPOINT.md`와 `SESSION.md`를 갱신한다
5. 최신 Reviewer 턴이 `이의 없음`을 명시할 때까지 반복한다
6. 사람만 정할 쟁점(제품 방향·범위·검증 방식 — 자동 테스트와 수동 QA 중 무엇으로 볼지)을 발견하면 다른 쟁점이 남아 있어도 그 턴에서 바로 `awaiting-user`로 바꾸고 `USER_ACTION.md`에 선택지를 적은 뒤 멈춘다
7. 총 턴 수가 20에 도달하면 `awaiting-user`로 바꾸고 멈춘다

Author 턴 수렴 규칙 (Author 만 적용한다):
- 같은 세션의 연속된 Reviewer 턴 3개가 모두 같은 설계 축(동시성·상태 머신·시간 기반 억제·재실행 계약 등)을 지적하면, 세 번째 지적에 응답하는 Author 턴은 국소 guard 를 더하기 전에 구조를 단순화·직렬화·결정적 설계로 바꿀 수 있는지 먼저 검토하고 채택·기각 판단과 이유를 `Proposed Decision`에 적는다. 사이의 Reviewer 턴 하나라도 그 축을 지적하지 않으면 0부터 다시 센다
- spec-plan 리뷰에서 합의를 반영할 때는 spec 과 plan 양쪽(요약부·표 포함)을 고치고 이전 설계의 서술이 남지 않았는지 확인한 뒤 턴을 쓴다
