# FUTURE_REQUESTS

현재 작업 범위 밖이지만 나중에 별도 task로 다룰 후보 목록.

## 상태 값

- `idea`: 아직 검증 안 됨
- `validated`: 필요성 확인, 우선순위 아님
- `ready-for-request`: REQUEST.md로 바로 올릴 수 있음
- `parked`: 검토 완료, 지금은 안 함, 조건 변화 시 재평가 → `FUTURE_REQUESTS_PARKED.md`로 이동
- `done` / `dropped`: 인덱스에서 삭제, `items/` 상세 파일의 status로만 추적

## 종류 값

- `feature` / `improvement` / `restructure` / `content` / `research` / `tooling`
- 인덱스 표의 `종류` 컬럼은 상세 파일의 `- kind:` 값을 그대로 옮겨 담는다. 변경 시 상세 파일과 인덱스를 함께 갱신한다.

## 기록 원칙

- 이 파일은 **인덱스**만 관리한다. 항목 상세는 `items/YYYY-MM-DD-제목.md`에 작성한다.
- 인덱스 행에는 반드시 **요약** 컬럼을 포함한다. 상세 파일을 열지 않아도 내용을 파악할 수 있어야 한다.
- "왜 필요한지"와 "왜 지금 안 하는지"를 상세 파일에 같이 적는다.
- 하나의 항목은 독립된 REQUEST.md로 승격 가능한 단위로 쓴다.

## 파일 분리

- **이 파일**: 활성 항목만 (idea, validated, ready-for-request)
- **`FUTURE_REQUESTS_PARKED.md`**: 보류 항목 (parked) — 재평가 조건 포함
- **`items/`**: 상세 파일. done/dropped는 여기서 status만 변경하고 인덱스에서 삭제

## 항목 템플릿

상세 파일 형식: `items/YYYY-MM-DD-short-title.md`

```md
# YYYY-MM-DD short-title
- status: idea
- kind: feature | improvement | restructure | content | research | tooling
- summary: 한두 문장 요약
- why: 왜 필요한지
- related context: 어디서 발견했는지
- related files: file/path/a, file/path/b
- not now because: 왜 지금 안 하는지
- revisit when: (parked일 때) 재평가 조건
- request seed: REQUEST로 만들 때 쓸 초안
```

---

## 인덱스

| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |
|------|------|------|------|------|----------|------|
