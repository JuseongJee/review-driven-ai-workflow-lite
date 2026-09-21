# task-state 가이드

`rd-workflow-workspace/.lifecycle/task-state` — v2 Phase 2b에서 도입된 단일 권위 상태 파일.
**Short Title / Status / fr-branch / worktree-path / source-fr / base-commit / review-session / extensions.*** 의 기계 판정 소스.

## 작업 상태와 작업 집합 색인 — 이원화된 위치

여러 작업을 worktree 로 격리해 동시 진행할 때, 「그 작업이 지금 어떤 상태인가」와 「지금 어떤 작업들이 있는가」는 서로 다른 위치에 있습니다.

| 무엇 | 어디 | git 추적 | 권위 |
|---|---|---|---|
| **작업 상태**(status·fr-branch·source-fr·base-commit·review-session 등) | 그 작업의 worktree 의 `rd-workflow-workspace/.lifecycle/task-state` | **tracked** (fr 브랜치 위) | 그 작업에 대해서만 유일한 권위 |
| **작업 집합 색인** | `$(git rev-parse --path-format=absolute --git-common-dir)/rd-workflow/tasks.local` | 저장소 밖(`.git` 내부) | 「어떤 작업들이 있는가」를 빠르게 보기 위한 **캐시** — 권위가 아님 |

**공유 위치가 `--git-common-dir` 이므로 브랜치 체크아웃과 무관합니다.** 이 경로는 어느 worktree 에서 실행하든, 그 worktree 가 지금 어떤 브랜치를 체크아웃하고 있든 항상 같은 값을 가리킵니다(주 저장소의 `.git`). `.git` 내부이므로 `.gitignore` 항목도 필요 없고, clone 마다 자연히 로컬입니다.

**작업 상태를 fr 브랜치 위 tracked 로 유지하는 이유**는 `archive_review_precheck` 등 기존 소비처가 `git show <fr-tip>:rd-workflow-workspace/.lifecycle/task-state` 로 그 작업의 상태를 직접 읽기 때문입니다. **기본 브랜치 worktree 의 task-state 는 항상 baseline** 이며 **어떤 작업도 대표하지 않습니다** — `promote` 는 더 이상 기본 브랜치에 커밋하지 않으므로, 기본 브랜치 worktree 를 열어봐도 「현재 작업」이라는 개념이 그 위에 존재하지 않습니다.

### 색인은 캐시이지 권위가 아닙니다

색인(`tasks.local`)이 가리키는 내용과 실제 `fr/*` ref·`git worktree list` 가 어긋나면(예: 파일을 손으로 지웠거나, 예기치 못한 중단으로 색인 갱신이 누락됨) **실제 ref·worktree 쪽이 맞습니다.** 색인만 믿고 판단하지 않습니다.

- **복구 경로**: `bash rd-workflow/scripts/rd task list --rebuild` — 색인을 지우고 실제 `fr/*` ref·`git worktree list`·각 fr tip 의 committed task-state 로부터 다시 계산합니다. `checkout=none`(비체크아웃) 작업을 놓치지 않도록 `git for-each-ref refs/heads/fr/*` 로 fr ref 를 먼저 열거한 뒤 체크아웃 여부를 대조합니다.
- **`--rebuild` 가 보존하는 것**: 기동 예약(`launch=launching` + `launch-token`)과 `state=cleanup-pending`(발행 후 로컬 정리만 남은 잔여)은 **덮어쓰지 않고 보존**합니다. 기동 중에는 공유 락이 비어 있어 `--rebuild` 가 끼어들 여지가 있는데, 이를 덮으면 진행 중인 기동 예약이 사라져 `rollback`·`archive` 차단이 풀립니다. 근거를 다시 확정할 수 없는 항목(예: 오래된 `cleanup-pending` 행)은 **삭제를 권하지 않고** 「확인 필요」로 남깁니다.

### 락(`tasks.lock`)

색인을 read-modify-write 하는 모든 경로 — `promote`·`archive`·`promote_rollback`·`rd task list --rebuild`·기동 결과 기록 — 는 같은 디렉터리의 `tasks.lock/` 을 공유 락으로 씁니다.

- 구현은 `mkdir <common-dir>/rd-workflow/tasks.lock`(원자적) 뒤 그 안의 `owner` 파일에 `pid`·`cmd`·`slug`·`started-at` 을 기록합니다.
- **대기하지 않고 즉시 실패**하며 점유자 정보를 출력합니다. `owner` 의 `pid` 가 살아 있으면(`kill -0`) 정상 점유로 보고 재시도를 안내합니다.
- **stale 락을 자동으로 회수하지 않습니다.** `owner` 의 `pid` 가 죽어 있거나 `owner` 파일 자체가 없으면(mkdir 직후 중단된 경우) **불확실로 보고** 회수 명령(`rm -rf <lock>`)을 출력할 뿐 스스로 지우지 않습니다 — `mkdir` 의 원자성은 「검사 → 삭제 → 재생성」 구간까지는 보호하지 못해, 두 회수자가 같은 죽은 pid 를 읽으면 한쪽이 상대의 새 락을 지울 수 있기 때문입니다. 회수는 사람이 다른 프로세스가 없음을 확인한 뒤 수동으로 합니다.
- 보호 범위는 **공유 자원**(색인·`fr/*` ref 생성·기본 브랜치 발행)뿐입니다. 각 작업 worktree 안의 구현·커밋·검증은 락과 무관하게 병행됩니다.
- `tasks_lock_release` 는 **자기 pid 가 소유자일 때만** 해제합니다(남의 락을 지우지 않습니다).

## 스키마

| 키 | 허용값 | 소유자 | 비고 |
|----|--------|--------|------|
| `schema` | `1` | lifecycle | 파일 형식 버전 |
| `short-title` | kebab-case slug \| `-` (sentinel) | `rd task set-status` / promote | LC-18: 단 한 번 설정, 이후 immutable |
| `status` | canonical 9종 (아래 목록) | `rd task set-status` / guard | LC-19: 집합 불변 |
| `fr-branch` | `fr/<slug>` \| `null` | promote / archive | 활성 여부는 `!= null` 이 아니라 **ref 실재**로 판정 — 아래 'fr-branch 활성 판정' 참조 |
| `worktree-path` | 절대 경로 \| `null` | promote / archive | worktree 미사용 시 `null` |
| `source-fr` | `-`(sentinel) 또는 `\|` 로 구분한 backlog item path 목록(복수 가능) | promote / `rd task set-source-fr` / `rd task fr-done` | FR 출처 경로(들) — 저장은 `\|` 구분 한 줄(저장 전용 직렬화), 그 외 자리는 줄 단위 목록 — 아래 'source-fr 계약' 참조 |
| `base-commit` | full commit OID \| `null` | promote / `rd task set-base` | 작업 시작 커밋 — 아래 'base-commit / review-session 계약' 참조 |
| `review-session` | diff-review session-id \| `null` | `prepare_review_pipeline.sh diff` / archive | final diff review 세션 포인터 — 같은 절 참조 |
| `created-at` | `YYYY-MM-DD-HHMM` 형식 | promote | fr 활성 기간에만 기록; 비활성 시 부재 가능 |
| `extensions.<ext-name>.<key>` | 자유 문자열 (개행 금지) | extension | 아래 규약 참조 |

### canonical 9종 Status (LC-19)

```
대기 중
REQUEST review 대기
spec/plan 작성 중
spec/plan review 대기
구현 중
검증 중
diff review 대기
아카이브 보류
완료
```

`아카이브 보류` 의 의미는 「**리뷰 종결·발행 대기**」이며 **완료가 아닙니다.** final diff review 가 종결되고 종결 마커(`rd review seal`)를 만든 뒤, `archive.sh` 로 발행하기 전까지의 구간입니다. 이 상태에서만 `pre_commit_archive_gate.sh` 가 archive 기록 커밋(REQUEST 아카이브·FR done·completion report 등 워크플로 기록 경로만 바꾸는 커밋)을 통과시킵니다.

전이는 세 가지입니다 (`_task_common.sh` 의 전이표가 단일 출처입니다).

```
diff review 대기 → 아카이브 보류      리뷰 종결 후 진입
아카이브 보류   → 완료                 발행 완료
아카이브 보류   → 구현 중              리뷰 후 변경이 필요해 되돌아감
```

되돌아가면 보호 경로가 바뀌므로 기존 마커의 트리 해시가 어긋나고, 재리뷰·재seal 없이는 다시 발행할 수 없습니다.

**게이트가 보는 것은 index 만이 아닙니다.** hook 은 커밋 명령이 실행되기 **전**에 돌므로, `git commit -a`·`git commit <경로>` 처럼 커밋 집합을 명령 실행 중에 만드는 형태에서는 index 가 비어 있습니다. 그래서 판정 대상은 **index ∪ 워킹트리(추적 파일)** 이고, 보류 상태에서 기록 경로 밖의 파일이 **수정되어 있기만 해도** 커밋이 막힙니다. 코드 변경이 필요해진 것이므로 복구 경로는 상태를 되돌리는 것입니다: `bash rd-workflow/scripts/rd task set-status "구현 중"`.

이 판정은 Source FR status 검사보다 **앞**에 있습니다. 정상 archive content commit 은 바로 그 커밋에서 FR 을 `done` 으로 바꾸므로, 순서가 뒤바뀌면 워킹트리의 `done` 표기 하나로 제한이 통째로 우회됩니다.

### 파일 형식 예시

```
schema=1
short-title=my-feature
status=구현 중
fr-branch=fr/my-feature
worktree-path=/path/to/worktree
source-fr=rd-workflow-workspace/backlog/items/2026-07-05-my-feature.md
base-commit=3f2a1c9d8e7b6a5f4c3d2e1b0a9f8e7d6c5b4a39
review-session=20260906_101500_final-diff-review
created-at=2026-07-05-1030
```

### source-fr 계약

`source-fr` 은 **복수 값**을 담을 수 있다(묶음 FR). 자리마다 표현이 다르다 — 자리의 제약이 서로 다르기 때문이다.

| 자리 | 표현 |
|---|---|
| task-state `source-fr=` | 한 줄, `\|` 구분 — **저장 전용 직렬화** (`state_write_fields` 가 개행을 거부하므로) |
| `REQUEST.md ## Source FR` / `CURRENT_TASK.md ## Source FR` 미러 | 줄 단위 목록 (한 줄에 1건, `- ` 접두 허용, 주석 행 무시) |
| CLI 인자 | 명령별로 다름 — 아래 '명령별 인자 문법' 참조 |

- **raw 항목의 경계는 언제나 「CLI 인자 하나」 또는 「REQUEST 의 한 줄」이다.** 한 인자·한 줄 안의 `|` 는 **어느 소비처에서도** 분리하지 않는다 — `source_fr_resolve` 가 괄호 표기의 레이블 문법을 제한하지 않으므로 `[A|B](items/x.md)` 가 유효 입력이기 때문이다. `|` 분리는 저장값을 역직렬화(`source_fr_split`)할 때만 일어난다.
- **정규화 순서 보존·중복 축약**: 정규화 후 첫 등장 순서를 보존하고 중복은 1건으로 축약한다. 첫 원소가 대표(기존 단일 값 소비처의 호환 값)다.
- **하위 호환**: 원소 1개인 집합의 task-state 표현은 현행과 **바이트 동일**하다(`source-fr=<path>`). 기존 파일·기존 REQUEST 표기는 마이그레이션 없이 읽힌다. `source_fr_split` 은 저장값 전체가 실존하는 canonical path 면(그 안에 `|` 가 있어도) 원소 1개로 확정하는 fast path 를 먼저 시도해 이 호환을 보장한다. `source_fr_join` 도 원소가 1개면 그 canonical 값을 그대로 반환하고, **2개 이상일 때만** `|` 포함 원소를 거부한다(되읽을 수 없기 때문).

#### 명령별 인자 문법

옵션 파서를 새로 만들지 않는 가장 작은 수정 — 명령마다 현행 형태(위치 인자·옵션)를 유지한다.

| 명령 | 복수 입력 문법 |
|---|---|
| `rd task set-source-fr <path>...` | 위치 인자 반복 |
| `promote.sh --source-fr <path>` | 옵션 반복 지정 |
| `rd task guard --source-fr <path>` | 옵션 반복 지정 (promote 모드 전용) |
| `rd task fr-done [<path>...]` | 위치 인자 반복 (생략 시 task-state `source-fr` 집합이 대상) |

- **저장 값 형식** (원소 단위): `-`(sentinel) 또는 repo-relative backlog item path (`rd-workflow-workspace/backlog/items/<파일>.md`). 절대경로·`..` 세그먼트·개행·legacy slug는 쓰기 거부 (`source_fr_validate` — `_state_common.sh` 단일 구현). **이 계약은 해석 계층이 넓어져도 바뀌지 않는다.**
- **쓰기 검증은 전부-또는-전무다**: 입력 항목을 전부 정규화한 뒤 하나라도 해석 실패·파일 부재면 **아무것도 쓰지 않고** 실패한다. stderr 에 문제 항목을 전부 열거한다(첫 실패에서 멈추지 않는다 — 사람이 한 번에 고칠 수 있어야 한다). `-` 단독은 「값 없음」이며 다른 항목과 섞이면 거부한다.
- **읽기 해석**: `REQUEST.md ## Source FR` 의 원문은 `source_fr_resolve`(`_state_common.sh` 단일 구현)가 각 유효 행을 canonical path 로 정규화한다(`source_fr_from_request_list` 가 모든 유효 행을 반환, 기존 `source_fr_from_request` 는 첫 행만 반환하는 단일 값 소비처용으로 남아 있다). 지원 표기는 canonical path · markdown 링크 `[텍스트](path)` · 괄호 병기 `slug (path)` · `slug — [상세](path)` 계열 · 위 형식 앞의 `- ` 리스트 접두 · `items/<파일>.md` 축약 · `YYYY-MM-DD slug` · `slug` 단독이다.
  - 괄호 계열에서 **레이블(괄호 앞부분)의 문법은 제한하지 않되 비어 있으면 거부**한다. 정확성은 괄호 안 target 의 형식·실존 검증이 보장하며, 레이블 문법을 고정하면 새 서술 변형마다 다시 실패하기 때문이다. 괄호 뒤에 `)` 와 공백 외의 문자가 남으면 거부한다.
  - **파일명 자체에 괄호가 있으면 링크·괄호 병기 표기를 쓰지 않는다.** `[텍스트](.../2026-04-04-a(b).md)` 는 마지막 괄호를 target 경계로 보는 규칙 때문에 해석되지 않는다. 이런 파일은 `rd-workflow-workspace/backlog/items/2026-04-04-a(b).md` 또는 `items/2026-04-04-a(b).md` 처럼 **경로를 그대로** 적는다 — 이 두 형식은 괄호 해석보다 먼저 판정되므로 파일명의 괄호가 문제되지 않는다.
  - slug 는 소문자 영숫자와 `-` 만 허용한다. `items/<slug>.md` 정확 일치를 먼저 보고, 없으면 `items/*-<slug>.md` 가 **유일하게** 매칭될 때만 채택한다. 0건·복수건은 거부한다.
  - 정규화 결과는 실존하는 **일반 파일**이어야 한다. 디렉토리·깨진 심링크는 거부한다.
- **`## Source FR` 절의 HTML 주석**(`<!-- ... -->`)은 값으로 채택하지 않는다. 템플릿이 형식 예시를 주석으로 담기 때문이다.
- **해석 실패 시**: 값이 있는데 정규화할 수 없으면 **조용히 `-` 로 기록하지 않는다.**
  - `lifecycle/promote.sh`: non-zero 로 중단한다. 이 지점은 `metadata_write` 직전이라 어떤 상태도 바뀌지 않으며, REQUEST 를 고쳐 재실행하면 된다.
  - `lifecycle/promote.sh` 의 `--dry-run` 도 같은 판정을 낸다. 해석은 read-only 라 dry-run 조기 종료보다 먼저 수행하며, 사전 점검이 성공을 알리고 실제 실행만 실패하는 반대 신호를 만들지 않는다.
  - `hooks/pre_commit_archive_gate.sh`: archive 커밋을 차단한다(exit 2), 미완료 항목을 전부 열거한다. 표기가 어긋났다는 이유로 게이트를 건너뛰지 않는다. 단 이 차단은 **diff review 세션이 종결된 뒤(= archive 커밋 경로)에만** 적용한다 — 세션이 없거나 미종결이면 그 커밋은 아직 archive 단계가 아니므로(구현 중 iteration commit 등) 통과시킨다. **이 게이트는 마감 누락의 최종 보장이 아니다** — REQUEST 부재·Source FR 공백·`아카이브 보류` 기록 커밋은 통과한다(정규 마감이 지나는 경로). 실제로 막는 것은 「Source FR 이 남아 있는 REQUEST 로 아카이브 커밋을 시도하는 경우」 하나이며, 이 범위 안에서 1건만 보던 것을 전부 보게 하는 것이 이번 변경의 값이다.
- **직접 주는 값은 엄격하다**: `rd task set-source-fr` · `rd task guard --source-fr` · `promote.sh --source-fr` 는 원소마다 canonical path 또는 `-` 만 받으며 **해석을 적용하지 않는다.** 비대칭인 이유는 — REQUEST 본문은 사람·AI 가 자유 서술로 쓰는 문서의 일부라 표기가 발산하지만, 직접 주는 값은 호출자가 형식을 아는 인터페이스이므로 관대화가 오히려 오류를 감춘다.
- **기록 시점**:
  - `rd task guard --mode promote`: `--source-fr <path> ...` 인자값(반복 가능), 인자 없으면 **`-` 리셋** (이전 작업 stale 값 차단). guard 시점의 REQUEST.md는 작성 전이므로 추론하지 않는다.
  - `lifecycle/promote.sh`: `--source-fr` 인자(반복 가능) > `REQUEST.md ## Source FR` 해석(모든 유효 행) > `-`. 명시 인자가 있으면 REQUEST 를 읽지도 해석하지도 않는다. 미러 쓰기·검증·rerun 비교는 목록 전체를 대상으로 하고(줄 단위 목록 교체 + 정규화된 집합 비교), 복구 안내 명령 문자열도 목록 전체로 만든다 — 전체가 계약을 통과할 때만 제시하고, 하나라도 통과하지 못하면 부분 목록을 제시하지 않고 「사람이 확인」으로 넘긴다.
- **리셋 시점**: `metadata_clear` (`lifecycle/archive.sh`·`lifecycle/promote_rollback.sh`) 가 `-`로 복원. `rd task set-title -` (아래 'Short Title reset' 참조) 도 허용 조건을 만족하면 `short-title` 과 함께 `-`로 되돌린다.
- **done 처리**: `rd task fr-done` 이 묶은 FR 전부의 `items/` status 와 `FUTURE_REQUESTS.md` 인덱스 행 status 를 함께 `done` 으로 바꾼다(각각 독립 판정 — 한쪽만 종료 상태여도 다른 쪽을 마저 갱신). **인덱스 행 삭제는 여전히 `/fr archive` 몫**이고 **발행(merge·tag·push)은 `archive.sh` 몫**이다(둘 다 변경 없음). 실패해도 발행은 막지 않는다 — 결과는 completion report 의 「FR 정리 결과」 절로 옮겨 발행 결과와 분리 보고하고, 재시도 대상은 아카이브된 REQUEST 사본의 `## Source FR` 과 그 보고서 절에서 회수한다.
- **정정 CLI**: `bash rd-workflow/scripts/rd task source-fr` (조회, 줄 단위 목록 출력), `bash rd-workflow/scripts/rd task set-source-fr <값>...` (검증 후 설정 — 직접 파일 편집 금지), `bash rd-workflow/scripts/rd task fr-done [<값>...]` (done 처리).

### guard 판정 (`task_guard_decide`, 7순위)

`rd task guard --candidate <slug> --mode <intake|promote|fr-add> [--source-fr <path> ...]` 의 판정 순서다. `planning-design-intake`·`request-to-reviewed-plan` 은 이 함수 하나를 mode 만 다르게 호출하므로(`rd-workflow/docs/flows/WORKFLOW.md` 「Short Title 계약」 참조), 판정표는 **이 절 하나만 정본으로 둔다.**

| 순위 | 조건 | decision | 상태 변경 |
|---|---|---|---|
| 1 | 현재 Short Title 이 빈 값/`-` | `write` | `short-title`(+promote 는 `source-fr`) |
| 2 | 현재 값 == candidate | `proceed-readonly` | 없음 |
| 3 | `mode == fr-add` | `proceed-readonly` | 없음 |
| 4 | candidate 가 현재 task-state 의 `source-fr` 집합 구성원과 slug 일치 (mode 무관) | `proceed-readonly` | 없음 |
| 5 | `fr-branch` **활성** (아래 'fr-branch 활성 판정' 참조) | `block-active` | 없음 |
| 6 | `## Status == 대기 중` | `rebind` | `short-title` 교체(+promote 는 `source-fr` 교체) |
| 7 | 그 외 | `block-active` | 없음 |

순위 4 는 「통합 slug 작업이 자기 source FR 로 재진입」하는 정상 흐름을 보호하고, 순위 5 는 「승격 완료 + 무관 후보」를 막는다(둘 다 신설 — 이전에는 순위 6/7 만 있었다). 자동 정합화는 하지 않는다 — rename(ref 실재 + slug 불일치)은 순위 5 로 차단되고, message 에 현재 Short Title 과 `fr-branch` slug 를 함께 보이며 사람이 ① 제목을 브랜치 slug 에 맞춰 그 작업을 계속하거나 ② 그 작업을 archive 하는 것 중 하나를 고른다.

### fr-branch 활성 판정

「활성」의 근거는 **`fr-branch` ref 의 실재** 하나다 (현재 Short Title 과 slug 가 일치하는지는 보지 않는다).

| `fr-branch` | 활성 | 근거 |
|---|---|---|
| `null`·빈 값·공백 | 아님 | 승격 이력 없음 |
| ref 실재 (`git show-ref --verify --quiet refs/heads/<branch>`, `-C <project_root>`) | **활성** | 작업이 살아 있음 (slug 일치 여부 무관) |
| 값은 있으나 ref 부재 | 아님 | `archive.sh` 가 브랜치를 삭제하므로 ref 부재 = archive 완료의 증거 |
| ref 조회 자체가 실패(git 아님·조회 오류) | **활성으로 간주** | 판정 불가는 보호 쪽으로 기운다. `block-active` 는 상태를 바꾸지 않으므로 오판 비용이 rebind 오판보다 작다. 단, 안내 문구는 「ref 실재 확인」과 구별한다(조회 실패를 확인처럼 표시하면 사람이 없는 브랜치를 있다고 믿는다) |

구현: `_fr_branch_active` (`_task_common.sh`).

### Short Title reset (`rd task set-title -`)

- 새 서브커맨드를 늘리지 않고 `set-status` 와 대칭으로 `set-title -` 에 둔다.
- 허용 조건: `## Status == 대기 중` **그리고** `fr-branch` 가 활성이 아님(위 'fr-branch 활성 판정' 표). **`--force` 로는 허용되지 않는다** — 열면 그것이 곧 진행 중 작업 보호의 우회 통로이기 때문이다. 정말 막힌 상태의 정본 경로는 「그 작업을 archive」다.
- 허용 시 `short-title` 과 `source-fr` 을 함께 sentinel(`-`)로 되돌린다(미러 포함). 거부 시 **아무 상태도 바꾸지 않고** 사유·다음 행동만 stderr 로 알린다.
- 기존 「값 → 다른 값」 변경 규칙(`--force` 필요)과 write 조건(guard 순위 1)은 불변이다.
- 구현: `task_reset_title` (`_task_common.sh`).

### base-commit / review-session 계약

두 필드의 **미설정 sentinel 은 `null`** 입니다 (`fr-branch`·`worktree-path` 와 같은 규칙). `-` 나 빈 문자열을 미설정으로 쓰지 않습니다.

**`base-commit`** — 이 작업이 시작된 커밋. 값은 **full commit OID** 이며 `main` 같은 ref 이름을 저장하지 않습니다. ref 를 저장하면 그 ref 가 움직였을 때 "작업 시작 커밋" 이 조용히 달라집니다.

- 기록: `lifecycle/promote.sh` 가 fr 브랜치 승격 **직전 HEAD** 를 OID 로 기록합니다.
- 수동 설정: `bash rd-workflow/scripts/rd task set-base <ref>` — **입력이 ref 여도 저장 시점에 `git rev-parse --verify <ref>^{commit}` 으로 OID 를 resolve** 해 기록하고, 커밋으로 해석되지 않으면 기록하지 않고 nonzero 로 끝냅니다. promote 를 쓰지 않는 프로젝트(fr 브랜치 없이 기본 브랜치에서 작업)는 이 명령으로 1회 설정합니다.
- 소비: `prepare_review_pipeline.sh diff` 의 base 판정 우선순위 3번 (`FILE_BASED_REVIEW_PIPELINE.md` 참조).
- 구현: `state_read_base_commit` / `state_write_base_commit` (`_state_common.sh`).

**`review-session`** — final diff review 세션 포인터. `prepare_review_pipeline.sh diff` 가 세션을 만들 때 그 session-id 를 기록하고, 발행 게이트는 디렉터리를 뒤지지 않고 **이 값 하나로** 종결 마커 경로(`rd-workflow-workspace/.lifecycle/review-seals/<session-id>.seal`) 를 조립합니다.

- 값은 session-id 하나입니다. **경로 구분자(`/`·`\`)나 `..` 가 섞이면 basename 으로 깎지 않고 거부**합니다 — 조용히 깎으면 사용자가 지정한 것과 다른 마커를 읽게 됩니다.
- 구현: `state_read_review_session` / `state_write_review_session` (`_state_common.sh`).

**리셋**: 두 필드 모두 `lifecycle_owned_state_keys`(`lifecycle/_lifecycle_common.sh` — archive 가 task-state 에서 바꾸는 키의 단일 출처) 에 포함되며, `metadata_clear` 가 `null` baseline 으로 되돌립니다 (`archive.sh`·`promote_rollback.sh`). 되돌리지 않으면 다음 작업이 이전 작업의 base·세션 포인터를 물려받습니다.

---

## durable / volatile 파티션

| 파티션 | 파일 | git | 접점 |
|--------|------|-----|------|
| **durable** | `task-state` | tracked (promote 커밋) | `rd task` CLI + `_state_common.sh` 단일 구현 |
| **volatile** | `loop-state` | gitignored | `_lifecycle_common.sh` helper 단일 구현 (`loop_state_record` / `loop_guard_check`) |

task-state와 loop-state를 물리적으로 통합하지 않는 이유:

- task-state는 promote 시 커밋되어야 합니다(LC-05 승계). 카운터는 검증 실패마다 변경되는 로컬 휘발값입니다.
- 통합하면 카운터 증가마다 tracked 파일이 dirty 상태가 되어 LC-20(archive clean 검증) 및 pre-commit gate와 매 사이클 충돌합니다.
- loop-guard 카운터의 "단일 소스"는 현행에도 loop-state 하나이며 이 설계에서도 하나입니다.

**volatile 파티션(loop-guard)의 접점은 `_lifecycle_common.sh` helper(`loop_state_record`/`loop_guard_check`) 단일 구현입니다.** `rd task` wrapper를 신설하지 않습니다.

---

## extensions.* 규약

extension은 CURRENT_TASK.md에 임의 섹션을 추가하는 대신 이 네임스페이스만 사용합니다.

```
extensions.<ext-name>.<key>=<value>
```

- `<ext-name>` 은 extension 디렉토리명 (`claude_skills/<ext-name>/`)과 일치시킵니다.
- 예약 키(`schema`, `short-title`, `status`, `fr-branch`, `worktree-path`, `source-fr`, `base-commit`, `review-session`, `created-at`)와 충돌하는 이름은 금지합니다. CLI가 자동 거부하지 않으므로 명명 규칙을 준수해야 합니다.
- 값에 개행 문자를 포함할 수 없습니다(LC-06).

---

## 마이그레이션 절차

첫 `rd task` 호출 시 `state_ensure` 함수가 자동으로 수행합니다.

1. `task-state` 존재 → no-op.
2. `task-state` 부재, `CURRENT_TASK.md` 존재:
   - CURRENT_TASK.md의 `## Status` 섹션에서 Status를 추출합니다.
   - legacy alias `실행 중` → `구현 중` 자동 변환합니다.
   - Status가 canonical 9종이 아니면 **fail-closed**: task-state를 만들지 않고 exit 3 + 복구 안내 메시지 출력(SEC-13).
   - `active-fr`(있으면)에서 fr-branch / worktree-path / short-title을 추출합니다.
   - 백업 저장: `.lifecycle/migration-backup/<YYYYMMDD-HHMMSS>/CURRENT_TASK.md` 및 `active-fr`
   - task-state 생성 후 active-fr 삭제(단일 트랜잭션 — 임시 파일 + mv).
3. `CURRENT_TASK.md` 부재 → 기본값(status=대기 중, sentinel `-`/null)으로 task-state 생성(bootstrap).

### 백업 위치

```
rd-workflow-workspace/.lifecycle/migration-backup/<YYYYMMDD-HHMMSS>/
  CURRENT_TASK.md   ← 마이그레이션 직전 CURRENT_TASK.md 사본
  active-fr         ← (있으면) 직전 active-fr 사본
```

### 실패 시 복구

1. `CURRENT_TASK.md`의 `## Status` 값을 canonical 9종 중 하나로 수정합니다.
2. task-state 파일이 잔존하면 삭제합니다(`rm rd-workflow-workspace/.lifecycle/task-state`).
3. `bash rd-workflow/scripts/rd task status` 재실행 → 마이그레이션 재시도.

### "다음 정규 커밋에 편승" 안내

마이그레이션이 만든 tracked 변경(active-fr 삭제 + task-state 추가)은 **자동 커밋하지 않습니다.** 다음 lifecycle 커밋(예: `rd task set-status`, promote 커밋)에 함께 포함하세요. LC-20(archive clean 검증)은 archive 시점에 이 변경이 커밋된 상태를 전제합니다.

---

## LIFECYCLE_METADATA_PATH → TASK_STATE_PATH 마이그레이션 노트

v2 Phase 2b 이전의 `LIFECYCLE_METADATA_PATH` 환경 변수(`.lifecycle/active-fr` 경로 override)는 폐지됩니다.

- 대체: `TASK_STATE_PATH` 환경 변수 (기본값 `rd-workflow-workspace/.lifecycle/task-state`)
- `_lifecycle_common.sh`의 `metadata_*` 함수들은 내부적으로 `TASK_STATE_PATH`를 사용합니다.
- `LIFECYCLE_METADATA_PATH`를 설정하던 코드는 `TASK_STATE_PATH`로 교체해야 합니다.

---

## 관련 파일

- `_state_common.sh` — task-state I/O 함수 (`state_file_exists`, `state_read_field`, `state_write_fields`, `state_ensure`) + 신설 필드 접근자 (`state_read_base_commit`, `state_write_base_commit`, `state_read_review_session`, `state_write_review_session`) + source-fr 복수 처리 (`source_fr_resolve_list`, `source_fr_from_request_list`, `source_fr_join`, `source_fr_split`, `source_fr_mirror_read`, `source_fr_mirror_set_equal`, `source_fr_recovery_cmd_positional`, `source_fr_recovery_cmd_repeat_opt`)
- `_task_common.sh` — CLI 계층 (`TASK_CANONICAL_STATUSES`, `task_read_status`, `task_guard_decide`, `_fr_branch_active`, `task_set_title`/`task_reset_title`, `task_set_source_fr`, `task_fr_done`)
- `hooks/_guard_common.sh` — guard 판정 함수 (`get_task_status`, `get_current_short_title`)
- `lifecycle/_lifecycle_common.sh` — `metadata_*` 래퍼 + loop-guard helper
- `scripts/self_test.sh` — LC-19 3자 일치 검증 (`lifecycle` 그룹)
