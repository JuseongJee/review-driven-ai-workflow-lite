## /fr archive

`FUTURE_REQUESTS.md` 인덱스에서 종료 상태(`done`/`dropped`) 항목을 일괄 삭제한다. 상세 파일(`items/`)은 삭제하지 않는다.

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 인덱스에서 status가 `done` 또는 `dropped`인 행을 모두 찾는다.
3. 대상이 0건이면 "삭제할 종료 항목이 없습니다" 출력 후 종료.
4. 대상 행을 인덱스에서 일괄 삭제한다.
5. 완료 메시지 출력: "archive 완료: done {N}건, dropped {M}건 인덱스에서 삭제"

### 규칙

- `done`과 `dropped` 상태 모두 대상이다. 두 상태 모두 종료 상태이며, 상세 파일에서 원래 상태를 추적할 수 있다.
- 상세 파일(`items/*.md`)은 삭제하지 않는다 — 이력 보존. done/dropped 구분은 상세 파일의 status 필드로 유지된다.
- 인덱스 테이블 형식을 변경하지 않는다.
