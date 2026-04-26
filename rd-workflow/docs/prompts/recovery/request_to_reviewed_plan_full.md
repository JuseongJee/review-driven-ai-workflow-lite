이미 작성된 `REQUEST.md`를 입력으로 spec / plan review 완료 직전까지 한 번에 진행해줘.

> **새 자유 텍스트 큰 작업이라면** 이 프롬프트 대신 `/planning-design-intake`를 먼저 호출해 `REQUEST.md`를 생성한 뒤 이 프롬프트(또는 `/request-to-reviewed-plan`)를 사용한다.

진행 규칙:
1. `PROJECT_CONTEXT.md`를 먼저 읽는다
2. `REQUEST.md`가 없거나 비어 있으면 진행을 멈추고 안내한다:
   > 새 작업의 REQUEST.md 가 없습니다. `/planning-design-intake`를 먼저 호출하여 REQUEST.md를 작성한 뒤 이 프롬프트로 진행하세요.
3. `REQUEST.md`가 있으면 그대로 재사용하고 REQUEST review부터 시작한다. `REQUEST.md`를 새로 쓰지 않는다
4. 범위를 넓히지 말고 꼭 필요한 정보만 질문한다
5. `Execution Path`를 판단한다
6. `small-task`면 이유만 남기고 멈춘다
7. 큰 작업이면 `REQUEST review -> spec/change spec -> plan -> spec/plan review` 순서로 진행한다
8. review는 `prepare_review_pipeline.sh`와 `run_review_turn.sh ...`를 사용한다
9. Superpowers를 쓸 수 있으면 그 workflow를 실행하고, 아니면 같은 위치에 같은 산출물을 만든다
10. 구현은 하지 않는다
11. `CURRENT_TASK.md`를 업데이트한다

마지막 출력:
- Execution Path
- REQUEST 상태
- spec 경로
- plan 경로
- request review session path
- spec / plan review session path
- 다음 추천 단계
- 남은 사용자 질문
