## /fr status

항목의 status를 변경한다.

### 호출 형식

`/fr status <short-title> <new-status>`

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 인덱스에서 해당 short-title 행을 찾는다. 인덱스에 없으면 `FUTURE_REQUESTS_PARKED.md`에서 찾는다. 둘 다 없으면 상세 파일(`items/*.md`)에서 찾는다. 모두 없으면 "'{short-title}' 항목을 찾을 수 없습니다" 출력 후 종료.
3. new-status 유효성을 검증한다. 허용 값: `idea`, `validated`, `ready-for-request`, `done`, `dropped`. 그 외 값이면 "허용되지 않는 상태입니다: {value}" 출력 후 종료.
4. 항목의 현재 위치를 판별하고 상태 변경을 실행한다:
   - **활성 인덱스에 있는 항목:**
     - 활성 → 활성: 인덱스의 status 컬럼 변경 + 상세 파일의 status 변경.
     - 활성 → done/dropped: 인덱스에서 해당 행 삭제 + 상세 파일의 status 변경.
   - **PARKED 인덱스에 있는 항목:**
     - parked → 활성: PARKED 인덱스에서 해당 행 삭제 + FUTURE_REQUESTS.md 인덱스에 행 추가 (우선순위 `-`) + 상세 파일의 status 변경.
     - parked → done/dropped: PARKED 인덱스에서 해당 행 삭제 + 상세 파일의 status 변경.
   - **인덱스 없이 상세 파일만 있는 항목 (done/dropped):**
     - done/dropped → 활성: 상세 파일의 status 변경 + FUTURE_REQUESTS.md 인덱스에 행 추가 (날짜, 제목, 요약은 상세 파일에서 읽음, 우선순위 `-`).
     - done ↔ dropped (종료 상태 간 전환): 상세 파일의 status만 변경. 인덱스에는 추가하지 않는다.
5. 완료 메시지 출력: "status 변경: **{short-title}** {old-status} → {new-status}"

### 규칙

- 인자가 부족하면 "사용법: `/fr status <short-title> <new-status>`" 출력 후 종료.
- `parked`로 변경하려면 `/fr park`를 사용하도록 안내한다 (재평가 조건 입력 필요).
- 현재 상태와 동일한 상태로 변경 시도 시 "이미 {status} 상태입니다" 출력 후 종료.
