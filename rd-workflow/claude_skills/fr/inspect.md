## /fr inspect

단일 FR 하나를 심층 검토하여 요약 보고하고, 그 FR 을 autopilot 으로 자율 실행할 수 있는지까지 판정한다. **읽기 전용 — 파일 수정 없음.**

### 호출 형식

`/fr inspect <short-title>`

### 절차

1. **인자 검증**: `<short-title>` 이 없으면 `사용법: /fr inspect <short-title>` 출력 후 종료. 인자는 short-title 전용이다. 사용자가 "15번"처럼 번호로 말한 경우, 번호→short-title 변환은 자연어 라우팅 단계(SKILL.md)에서 직전 `/fr list` 출력 기준으로 이뤄지며, inspect 절차 자체는 번호를 받지 않는다 (list 번호는 정렬·필터로 매번 바뀌는 휘발성 값이다).
2. **항목 탐색** (인덱스 기반):
   - `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 활성 인덱스에 있으면 → 검토 진행.
   - 활성에 없고 `rd-workflow-workspace/backlog/FUTURE_REQUESTS_PARKED.md` 인덱스에 있으면 → parked 상태를 보고서에 명시하고 검토 진행.
   - 두 인덱스 어디에도 없으면 → `'<short-title>' 은 활성/parked 목록에 없습니다 (done/dropped 로 종료되었거나 오타일 수 있습니다)` 안내 후 종료. done/dropped 등 종료된 항목은 inspect 대상이 아니다 (inspect 는 "진행할까" 판단 도구이므로). 날짜 미상 glob 탐색은 도입하지 않는다.
3. **최소 입력 범위 read** (이 범위 이상은 판단에 따라 확장 가능):
   - (a) 대상 FR 상세 파일 (`items/*.md`)
   - (b) 활성 상태 확인용 `FUTURE_REQUESTS.md` 인덱스 (+ 필요 시 PARKED)
   - (c) `rd-workflow/claude_skills/fr/SKILL.md` 및 관련 기존 절차 파일
   - (d) `rd-workflow/claude_skills/autopilot/SKILL.md` 의 **autopilot 적합성 기준** 섹션
   - (e) 대상 FR `related files` 중 직접 영향 파일
4. **검토 수행**: 본질과 객관 규칙 기준으로 타당성·범위·근본성을 비판적으로 검토한다 (진짜 root cause 인가, 본말전도 없는가, 범위가 닫혀 있는가).
5. **autopilot 판정**: autopilot SKILL.md 의 **autopilot 적합성 기준** 섹션을 적용해 가능 / 조건부 가능 / 불가 를 판정한다. 별도 판정 로직을 만들지 않고 그 섹션을 인용한다.
6. **고정 섹션 보고서 출력** (아래). 어떤 파일도 수정하지 않는다.

### 출력 — 고정 섹션 보고서

자유 형식 요약이 아니라 아래 6개 섹션을 모두 채운다 (해당 없으면 "없음" 명시):

1. **대상 FR 식별**: 제목 / 상태 / 종류 / 우선순위 / 상세 경로.
2. **읽은 근거 파일**: 실제로 읽은 파일 목록.
3. **핵심 요약**: FR 이 무엇을 요구하는지 1–3문장.
4. **타당성·범위·근본성 검토**: 비판적 검토 결과.
5. **누락·위험·질문**: 빠진 정보, 위험, 사람이 답해야 할 질문.
6. **autopilot 판정**: 가능 / 조건부 가능 / 불가 + 근거.
   - **조건부 가능**: 충족 조건과 사람 결정 필요 여부를 분리해 표시.
   - **불가**: 차단 사유 명시.

### 규칙

- **읽기 전용**: FR 파일·인덱스·산출물을 절대 수정하지 않는다. 상태 변경은 `/fr status`, 우선순위 기록은 `/fr pri`, 실제 실행은 `autopilot` 의 책임이다.
- 모든 출력은 존댓말로 작성한다.
- autopilot 판정은 autopilot SKILL.md 의 적합성 기준을 단일 출처로 인용하며 기준을 여기에 복제하지 않는다.
- 단일 항목 전용이다. 여러 항목 일괄 검토는 하지 않는다 (전체 우선순위는 `/fr pri`).
