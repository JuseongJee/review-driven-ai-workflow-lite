## /fr status

항목의 status를 변경한다.

### 호출 형식

`/fr status <short-title> <new-status>`

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 인덱스에서 해당 short-title 행을 찾는다. 인덱스에 없으면 `FUTURE_REQUESTS_PARKED.md`에서 찾는다. 둘 다 없으면 상세 파일(`items/*.md`)에서 찾는다. 모두 없으면 "'{short-title}' 항목을 찾을 수 없습니다" 출력 후 종료.
3. new-status 유효성을 검증한다. 허용 값: `idea`, `validated`, `ready-for-request`, `blocked`, `done`, `dropped`. 그 외 값이면 "허용되지 않는 상태입니다: {value}" 출력 후 종료.
4. 항목의 현재 위치를 판별하고 상태 변경을 실행한다:
   - **활성 인덱스에 있는 항목:**
     - 활성 → 활성: 인덱스의 status 컬럼 변경 + 상세 파일의 status 변경.
     - 활성 → done/dropped: 인덱스에서 해당 행 삭제 + 상세 파일의 status 변경.
   - **PARKED 인덱스에 있는 항목:**
     - parked → 활성: PARKED 인덱스에서 해당 행 삭제 + FUTURE_REQUESTS.md 인덱스에 행 추가 (종류는 상세 파일의 `kind`, 우선순위 `-`) + 상세 파일의 status 변경.
     - parked → done/dropped: PARKED 인덱스에서 해당 행 삭제 + 상세 파일의 status 변경.
   - **인덱스 없이 상세 파일만 있는 항목 (done/dropped):**
     - done/dropped → 활성: 상세 파일의 status 변경 + FUTURE_REQUESTS.md 인덱스에 행 추가 (날짜, 제목, 요약, 종류는 상세 파일에서 읽음, 우선순위 `-`).
     - done ↔ dropped (종료 상태 간 전환): 상세 파일의 status만 변경. 인덱스에는 추가하지 않는다.

   활성 인덱스에 행을 새로 추가할 때는 **`fr/add.md` 6단계 「인덱스 행 추가」 절차를 그대로 수행한다** — 6-a(헤더 이관)·6-b(행 조립)·6-c(요약 앞머리)를 전부 따른다. 비활성 FR 의 상세 요약에는 앞머리가 없는 것이 정상이므로, 관계가 있는 항목을 복원할 때 **6-c 로 앞머리를 새로 만들어 인덱스 요약 칸에 붙인다.** 상세 파일의 `- summary:` 는 바꾸지 않는다. 앞머리를 빠뜨리면 복원은 성공 메시지를 내고도 `fr_relations.sh validate` 가 `summary-prefix` 로 막는다.

   복원 시 status 가 채우는 값: 날짜·제목·요약·`종류`는 상세 파일에서 읽고, 우선순위는 `-`, `관계`는 상세의 `depends-on`·`series` 에서 옮긴 값이다. 상세 파일에 `kind` 가 없으면 `-` 로 표시하고 경고 출력.
5. 완료 메시지 출력: "status 변경: **{short-title}** {old-status} → {new-status}"

### 규칙

- 인자가 부족하면 "사용법: `/fr status <short-title> <new-status>`" 출력 후 종료.
- `parked`로 변경하려면 `/fr park`를 사용하도록 안내한다 (재평가 조건 입력 필요).
- 현재 상태와 동일한 상태로 변경 시도 시 "이미 {status} 상태입니다" 출력 후 종료.
- `blocked` 은 무인 드레인(ralph)이 중단조건에 걸린 FR 을 set-aside 한 상태다. 활성 인덱스에 잔류하되 auto-pick·`/fr pri`·`/fr push` 대상에서 제외되고 `/fr list` 기본 목록 행에서도 제외되어 표 아래 set-aside 요약(건수)으로만 표기된다. 활성 ↔ blocked 전이는 인덱스 status 컬럼 + 상세 status 변경(인덱스 행 유지), blocked → done/dropped 는 인덱스 행 삭제 + 상세 status 변경이다. blocked 를 재시도하려면 `/fr status <slug> validated` 로 되돌린다.
