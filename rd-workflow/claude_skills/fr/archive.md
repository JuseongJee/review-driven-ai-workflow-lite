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

1. final diff review 종결 후 `bash rd-workflow/scripts/rd review seal <세션 경로>` 로 종결 마커를 만든다.
2. `bash rd-workflow/scripts/rd task set-status "아카이브 보류"` 로 전이한다 (「리뷰 종결·발행 대기」 — 완료가 아니다).
3. fr branch 에서 archive content commit 수행 (REQUEST.md 비우기, archive 파일 생성, **FR done 처리**, completion report) — **1번의 seal 파일도 이 커밋에 함께 싣는다.** `CURRENT_TASK.md` 미러는 `archive.sh` 가 baseline 으로 되돌리므로 사람이 하지 않습니다 (fr·no-fr 두 모드 모두 그렇습니다).

   **FR done 처리**는 이 기록 커밋 단계(task-state 가 아직 살아 있는 시점)에서 다음을 호출한다:
   ```bash
   bash rd-workflow/scripts/rd task fr-done
   ```
   인자 없이 부르면 task-state 의 `source-fr` 집합 전부가 대상이다. **`fr-done` 은 묶은 FR 전부의 `items/` status 와 인덱스 행 status 를 함께 `done` 으로 바꾼다** — 인덱스 행의 **삭제**는 여전히 `/fr archive` 몫이며, `/fr archive` 는 그 status 를 보고 삭제 대상을 고른다. 즉 `fr-done` 이 status 를 두 자리 모두 바꾸지 않으면(예: items 만 바꾸면) `/fr archive` 는 인덱스가 여전히 활성이라 0건으로 끝나고 FR 이 활성으로 남는다 — 이 연결이 끊기지 않게 항상 `fr-done` 을 먼저 호출한다.

   **실패해도 발행을 계속한다.** `fr-done` 이 exit 1(실패 1건 이상)이어도 이 기록 커밋과 이어지는 4번 발행을 중단하지 않는다. 대신:
   - `fr-done` 의 표준출력(FR 별 items/인덱스 결과 + `처리 N / 건너뜀 M / 실패 K` 요약 + 실패 목록)을 completion report 의 **「FR 정리 결과」 절**에 그대로 옮긴다.
   - `PROJECT_CONTEXT.md` 의 `auto_completion_report` 가 꺼진 프로젝트는 같은 내용을 **아카이브된 REQUEST 사본**(`request-archive/YYYY-MM-DD-HHMM-*.md`) 말미에 적는다.
   - 최종 사용자 보고는 **발행 결과**(`archive.sh` 의 merge/tag/push 성공 여부)와 **FR 정리 결과**(`fr-done` 성공/실패)를 **두 줄로 분리**해 보고한다 — 섞어서 한 줄로 보고하지 않는다.

   **재시도**: 발행 후 task-state 는 초기화되므로 `fr-done` 을 인자 없이 다시 부를 수 없다. 미완료 FR 목록은 **아카이브된 REQUEST 사본의 `## Source FR`** 과 completion report(또는 REQUEST 사본 말미)의 「FR 정리 결과」 절에 남아 있다 — 거기서 경로를 회수해 다음처럼 다시 부른다:
   ```bash
   bash rd-workflow/scripts/rd task fr-done <path>...
   ```
4. main 으로 switch 후 `bash rd-workflow/scripts/lifecycle/archive.sh` 호출 → merge + tag + push + branch/worktree 정리 일괄 처리. (`archive.sh` 자체는 FR 정리에 관여하지 않는다 — 위 3번에서 이미 끝나 있어야 한다.)

즉, **사용자가 수동으로 REQUEST archive 를 진행할 때**:
- 리뷰 종결 직후 seal → `아카이브 보류` 전이 순으로 준비한다. 이 둘은 커밋 **앞**이다 — 게이트가 워킹트리의 task-state 를 읽으므로 전이는 즉시 반영되고, 보류 상태에서만 archive 기록 커밋이 통과한다.
- archive content 는 seal 파일과 함께 fr branch 에서 commit 한다. **마커는 커밋되어야 효력이 생긴다** — `archive.sh` 는 워킹트리가 아니라 fr tip(no-fr 모드면 현재 `HEAD`)에서 마커를 읽는다.
- main 으로 switch 한 뒤 `bash rd-workflow/scripts/lifecycle/archive.sh` 를 실행한다.
- `archive.sh` 가 merge/tag/push/cleanup 을 자동 처리하므로 사용자는 seal·상태 전이·archive content commit 과 main switch 만 수동 수행하면 된다. `archive.sh` 의 호출 형태·인자·내부 순서는 종전과 같아, 위 준비를 마친 뒤 곧바로 부르면 종전의 one-shot 실행과 동일하다.
- 다음에 할 일이 헷갈리면 `bash rd-workflow/scripts/rd task status` 를 실행한다 — `발행` / `seal 과 archive 기록을 커밋하세요` / 실패 사유별 복구 안내 중 하나를 낸다.

### fr 브랜치 없이 작업한 경우 (no-fr 모드)

fr 브랜치를 만들지 않고 기본 브랜치에서 작업했다면 위 3번의 커밋을 **기본 브랜치에서** 하고 4번에서 switch 없이 그대로 `archive.sh` 를 호출한다. merge·branch/worktree 정리는 건너뛰고 metadata cleanup commit·tag·push 만 수행한다.

- 진입 조건은 task-state 의 `fr-branch` 가 canonical `null` 일 때뿐이다. 빈 문자열·공백·`main` 등은 no-fr 이 아니라 **malformed 로 차단**된다.
- **기본 브랜치가 아니거나 detached HEAD 이면 차단된다** — 각각 "기본 브랜치로 전환 후 재실행" 안내가 나온다. no-fr 은 tag·push 를 현재 checkout 에 그대로 수행하므로 실행 위치가 곧 발행 대상이기 때문이다.
- tag slug 는 task-state `short-title` 에서 나오므로 비어 있으면 먼저 `bash rd-workflow/scripts/rd task set-title <제목>` 을 실행한다.

### legacy 리뷰 세션 (`review-head-oid` 가 없는 세션)

`## Branch Context` 에 `review-head-oid` 가 **없는** 세션은 리뷰 당시 커밋이 어디에도 기록되어 있지 않아 일반 `rd review seal` 로 봉인할 수 없다. 이때만 `bash rd-workflow/scripts/rd review seal --legacy-unverified "<사유>" <세션 경로>` 를 쓴다.

**포기하는 것:** 이 마커는 **리뷰 당시 트리를 증명하지 않는다.** 종결 이후 코드가 변경되었어도 발행을 막지 못한다. 사유는 `rd-workflow-workspace/.lifecycle/review-skip-audit.log` 에 append 되고, `archive.sh` 와 `rd task status` **양쪽이 통과할 때마다 경고**를 낸다. 반대로 `review-head-oid` 가 **있는** 세션에 이 플래그를 쓰면 거부된다 — 검증 가능한 세션을 무검증으로 낮추지 않는다.
