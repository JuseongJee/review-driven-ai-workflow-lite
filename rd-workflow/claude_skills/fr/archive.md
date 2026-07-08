## /fr archive

`FUTURE_REQUESTS.md` 인덱스에서 종료 상태(`done`/`dropped`) 항목을 일괄 삭제한다. 상세 파일(`items/`)은 삭제하지 않는다.

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 인덱스에서 status가 `done` 또는 `dropped`인 행을 모두 찾는다.
3. 대상이 0건이면 "삭제할 종료 항목이 없습니다" 출력 후 종료.
4. 대상 행을 인덱스에서 일괄 삭제한다.
5. 완료 메시지 출력: "archive 완료: done {N}건, dropped {M}건 인덱스에서 삭제"
6. archive 대상 항목들의 short-title 을 모은다 — Step 2 에서 식별한 done/dropped 대상 행의 두 번째 컬럼 (short-title) 을 수집. **Step 4 의 인덱스 행 삭제 전에 추출하거나 임시 보관해 두어야 함** (삭제 후에는 행 데이터 접근 불가).
7. 각 short-title에 대해 `fr` stage 캡처를 `rd-workflow-workspace/raw-captures/archive/` 로 이동한다 — done 처리한 각 `${SHORT_TITLE}` 에 대해 아래 호출을 반복:
   ```bash
   bash rd-workflow/scripts/rd task archive-captures --stages fr --title "${SHORT_TITLE}"
   ```
   - `request`/`spec`/`plan` stage 캡처는 이동 안 함 (REQUEST archive 책임)
   - 매칭 0건이면 skip (경고 없음)
8. 완료 메시지에 "raw capture 이동: {N}건" 추가

### 규칙

- `done`과 `dropped` 상태 모두 대상이다. 두 상태 모두 종료 상태이며, 상세 파일에서 원래 상태를 추적할 수 있다.
- 상세 파일(`items/*.md`)은 삭제하지 않는다 — 이력 보존. done/dropped 구분은 상세 파일의 status 필드로 유지된다.
- 인덱스 테이블 형식을 변경하지 않는다.

### REQUEST archive 흐름과의 연결

`/fr archive` 는 FR 인덱스 정리와 `fr` stage raw capture 이동까지만 담당한다. REQUEST archive 전체 흐름 (큰 작업) 에서는 다음 순서로 진행한다:

1. fr branch 에서 archive content commit 수행 (REQUEST.md 비우기, archive 파일 생성, FR done 처리, completion report, CURRENT_TASK.md reset).
2. main 으로 switch 후 `bash rd-workflow/scripts/lifecycle/archive.sh` 호출 → merge + tag + push + branch/worktree 정리 일괄 처리.

즉, **사용자가 수동으로 REQUEST archive 를 진행할 때**:
- archive content는 fr branch 에서 commit 한다 (기존 절차 유지).
- main 으로 switch 한 뒤 `bash rd-workflow/scripts/lifecycle/archive.sh` 를 실행한다.
- `archive.sh` 가 merge/tag/push/cleanup 을 자동 처리하므로 사용자는 archive content commit 과 main switch 만 수동 수행하면 된다.
