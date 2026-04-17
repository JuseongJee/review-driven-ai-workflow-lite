## /fr park

활성 항목을 `parked` 상태로 변경하고 `FUTURE_REQUESTS_PARKED.md`로 이동한다.

### 호출 형식

`/fr park <short-title>`

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 인덱스에서 해당 short-title 행을 찾는다. 없으면 `FUTURE_REQUESTS_PARKED.md`를 읽어 해당 항목이 있는지 확인한다.
   - PARKED 인덱스에 있으면 "이미 parked 상태입니다" 출력 후 종료.
   - 어디에도 없으면 "'{short-title}' 항목을 찾을 수 없습니다" 출력 후 종료.
3. 해당 항목의 status가 활성 상태(`idea`/`validated`/`ready-for-request`)인지 검증한다. `done`/`dropped` 등 비활성 상태이면 "활성 상태의 항목만 park할 수 있습니다 (현재: {status})" 출력 후 종료.
4. AskUserQuestion으로 재평가 조건을 묻는다: "재평가 조건을 입력해주세요 (언제 다시 검토할지)"
5. `rd-workflow-workspace/backlog/FUTURE_REQUESTS_PARKED.md` 읽기 (Step 2에서 이미 읽었으면 재사용).
6. 다음을 순서대로 실행한다:
   a. `FUTURE_REQUESTS.md` 인덱스에서 해당 행을 삭제한다.
   b. `FUTURE_REQUESTS_PARKED.md` 인덱스 끝에 행을 추가한다: `| {날짜} | {short-title} | {요약} | {재평가 조건} | [상세](...) |`
   c. 상세 파일(`items/*.md`)의 `status`를 `parked`로, `revisit when`을 입력받은 재평가 조건으로 변경한다.
7. 완료 메시지 출력: "park 완료: **{short-title}** → parked (재평가: {조건})"

### 규칙

- short-title 인자가 없으면 "사용법: `/fr park <short-title>`" 출력 후 종료.
- 상세 파일이 없으면 경고를 출력하되 인덱스 이동은 수행한다.
- PARKED 인덱스 테이블 형식(날짜, 제목, 요약, 재평가 조건, 상세)을 따른다.
