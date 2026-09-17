# Workflow

이 문서는 전체 작업 흐름을 한 페이지에 모아 둔 문서입니다.

평소에는 `WORKING_WITH_AI.md`를 먼저 읽고,
위험 등급 판정과 등급별 절차가 헷갈릴 때 이 문서를 읽습니다.

## 위험 등급 (risk tier)

이 판정이 전체 흐름의 핵심 분기입니다. 작업 착수 시 AI 가 아래 신호표로 등급을 판정하고 **시작 보고 블록**(등급 / 근거 신호 / 경로 / 생략 단계 / 필수 단계 / 실행 모드 / push 예정 / 미병합 브랜치 FR 후보) 을 **한 번** 냅니다. **이 괄호 안의 목록이 필드 정본입니다** — 아래 `light` 체크리스트 1항과 `/small-task-implement` 1단계·Final output 을 비롯한 모든 생산자는 목록을 다시 열거하지 않고 이 목록을 그대로 상속하며, 그 자리에서 값이 갈리는 필드(예: `push 예정` 의 경우별 문구)만 덧붙입니다. `실행 모드` 필드는 판정된 모드와 그 출처를 병기하며, 출처 값은 `workflow.json` / `키 부재 기본값` / `파일 부재 기본값` / `세션 지시` / `판정 불가 fallback` 다섯뿐입니다(판정 규칙과 경고 문구는 `AUTONOMY.md`). 생산자와 시점은 등급별로 하나씩입니다 — `light`·`standard` 는 아래 시작 계약 5항을 확인한 **직후**(생산자: `light` 체크리스트 1항 / `/small-task-implement` 1단계 / autopilot 모드 B 는 §3 promote 직전의 시작 계약 확인 직후), `full` 은 시작 계약이 없으므로 **등급 판정 직후**(생산자: 대화 Intake 규칙 또는 autopilot 모드 결정). `full` 의 블록은 FR 등록·지시 대기보다 앞서며, 블록 직전에 **비변경 preflight** `bash rd-workflow/scripts/lifecycle/start_preflight.sh` 를 실행합니다(원격 모드면 fetch 포함) — 출력의 `push 예정` 줄과 `미병합 브랜치 FR 후보` 줄을 블록에 그대로 옮기며, ahead 수를 읽어 `push 예정` 을 `archive.sh 경유(기본 브랜치 미push N개 포함)` 로 적고, fetch 실패·upstream 부재면 `archive.sh 경유(미push 수 판정 실패: 사유)` 로 적습니다(워킹트리·브랜치는 바꾸지 않습니다). 대화 Intake 의 `full` 은 블록 뒤 "다음 단계를 지정해주세요" 로 지시를 기다리므로 사용자가 그 자리에서 ahead 커밋 발행을 막거나 채택할 수 있고, autopilot 모드 A 는 지시 대기가 없으므로 ahead N>0 이면 시작하지 않고 인계합니다(사용자 명시 채택 시 진행·채택 수 병기 — `standard` 와 같은 규칙). `/workflow-router` 는 등급과 근거 신호만 말하고 블록을 내지 않습니다. `light`·`standard` 는 블록 뒤 승인을 기다리지 않고 진행하고 `full` 은 현행 실행 모드 규칙(manual 은 단계별 확인, semi-auto·autopilot 은 `AUTONOMY.md`) 을 따릅니다. 마감 시 **종료 보고 블록**(검증 결과 / review 결과 / 커밋·archive·push 상태 / 남은 조치) 을 냅니다. `push 예정` 은 원격 모드에서 필수 필드입니다 — 마감 push 방식(`light` 는 커밋 직후 push, `standard`·`full` 은 `archive.sh` 경유) 과 그 push 에 함께 올라갈 기본 브랜치 미push 커밋 수를 적고, 로컬 전용 모드는 `없음` 으로 적습니다. 자율 실행 모드의 `light` 마감 push 는 이 필드가 있어야 허용됩니다(`AUTONOMY.md` 중단 조건 6 예외 ②). `미병합 브랜치 FR 후보` 줄은 모든 등급에서 필수이며 경고 성격입니다 — 후보가 있어도 흐름을 막지 않고, 검사 실패는 `검사 실패 — 사유` 로 적고 진행합니다. 사용자가 매 작업 시작마다 이 줄을 보므로 방치 브랜치의 FR 이 사람이 찾지 않아도 드러납니다.

등급 변경은 발생 즉시 한 줄로 표시합니다. **상향은 언제나 가능**하고, **하향은 사용자만** 할 수 있으며 AI 는 하향을 제안만 합니다. 되돌리기 어려운 효과는 어떤 하향으로도 `full` 고정, 워크플로 인프라 동작 변경은 사용자가 명시 지시할 때만 `standard` 까지(지시는 감사 기록에 남김), `light` 로의 하향은 이 두 신호가 없을 때만 가능합니다.

### 판정 신호표

판정 순서: ① 의미 기반 신호로 **기본 등급**을 정한다 → ② 경로·규모 신호는 **상향에만** 쓴다 — 기본 등급의 규모 한도를 넘으면 **한 단계** 올리고, 낮은 등급의 규모 신호는 하향 근거가 아니다 → ③ 인접 두 등급 사이가 모호하면 높은 쪽 → ④ 의미 신호로 기본 등급을 정할 수 없으면 `full`. 파일 수는 정본만 세고 build 산출물(루트 `rd-workflow/` 미러) 과 워크플로 생성 파일(tier-log 행·FR done 처리·task-state) 은 세지 않습니다. 경로는 역할 명칭으로 판정합니다(소비 프로젝트도 `rd-workflow/` 설치 위치가 같습니다).

| 등급 (token) | 의미 기반 신호 (우선) | 경로·규모 신호 (보조) |
|---|---|---|
| 전면 `full` | 되돌리기 어려운 효과 — 발행·삭제·권한·외부 시스템 반영, **기본 브랜치 push 가 자동 발행·배포를 유발하는 저장소의 문서·스토어 메타데이터·정책/법률 문구** / 워크플로 인프라의 **동작** 변경 — `rd-workflow/scripts/**`(hook·lifecycle·review 포함)·`.claude/settings.json`·`claude_skills/**/SKILL.md` 의 절차·`docs/flows/**` 의 규칙 / 제품 코드의 인터페이스·데이터 모델·마이그레이션·기존 동작 변경 / 새 기능 | 여러 모듈이 함께 바뀜, 테스트 전략을 새로 잡아야 함 |
| 표준 `standard` | 제품 코드의 국소 동작 변경(인터페이스 불변) / 테스트 추가·수정 / 워크플로 스크립트의 **비동작** 변경(메시지·주석·오류 문구) / 권한·배포·보안이 아닌 설정값 조정 | 변경 파일 ≤ 3, 기존 테스트로 검증 가능 |
| 경량 `light` | 동작 변경 없음 — 문서·가이드·README 의 문구·오탈자·예문, 코드 주석, 포맷팅, backlog·FR 기록물 정리 | 변경 파일 ≤ 2, 한 파일 안의 국소 수정 |

### 등급 × 단계 절차표

칸 값: **필수** / **생략** (기본) / **선택** (사용자가 요청하면 등급 변동 없이 그 단계만 추가).

| 단계 | `light` | `standard` | `full` |
|---|---|---|---|
| FR 등록·지시 대기 (Intake) | 생략 | 생략 | 필수 |
| fr 브랜치 (`promote.sh`, worktree 기본 생성) | 생략 | 필수 (`--size small`) | 필수 (`--size large`) |
| raw-capture·short-title 3-way | 생략 | 생략 (short-title 은 promote 가 기록) | 필수 |
| REQUEST | 생략 | 필수 — 축약형 | 필수 |
| REQUEST review | 생략 | 생략 | 필수 |
| spec / plan | 생략 | 생략 — 필요하면 REQUEST `Change Description` 안에 한 문단 spec + 한 목록 plan | 필수 (별도 파일) |
| spec/plan review | 생략 | 생략 | 필수 |
| 구현 | 필수 | 필수 | 필수 |
| 검증 (고친 영역) | 필수 | 필수 | 필수 |
| task review (subagent) | 생략 | 생략 | 필수 (`mechanical` 제외) |
| 커밋 전 재분류 | 필수 | 필수 | 필수 |
| final diff review | 생략 | 필수 | 필수 |
| 종결 마커 (`rd review seal`) + `아카이브 보류` 전이 | 생략 | 필수 | 필수 |
| 아카이브 (`archive.sh`) | 생략 | 필수 | 필수 |
| completion report | 생략 | 생략 | `auto_completion_report` 설정 |
| 감사 기록 | `reports/tier-log.md` 한 줄 | REQUEST `## Risk Tier` | REQUEST `## Risk Tier` |

`standard` 의 **축약 REQUEST** 는 `Task Type`·`Execution Path`·`User Goal`·`Change Description`·`Acceptance Criteria`·`Risk Tier`·`Source FR` 만 채우고 나머지는 `-` 로 둡니다. `promote.sh --size` 는 `standard = small`, `full = large` 입니다. autopilot 의 모드 A = `full`, 모드 B = `standard` 이고 `light` FR 은 autopilot 에서 `standard` 로 실행합니다.

### 시작 계약 (`light`·`standard` 공통)

**worktree 격리가 기본입니다.** `promote.sh` 는 인자 없이 호출해도 기본 브랜치에 커밋하지 않고 `<main worktree>/.worktrees/<slug>` 에 별도 worktree 를 만들어 그 안에서 fr 브랜치를 체크아웃합니다(main worktree 는 `$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")`). 여러 작업을 동시에 진행할 때는 각자의 worktree 안에서 독립적으로 구현·검증·커밋합니다. `--no-worktree` 로만 기존처럼 현재 체크아웃에서 `git switch` 하며, 이 옵션은 **현재 체크아웃이 기본 브랜치일 때만** 허용되고 동시에 하나만 가능합니다(대상 선택·마감 경로는 아래 절 참조).

1. `CURRENT_TASK.md Status = 대기 중`. 진행 중 작업이 있으면 Intake 의 "등록만" 규칙을 따릅니다.
2. **어떤 switch·checkout 보다 먼저** 현재 브랜치와 워킹트리 clean 여부를 읽습니다. dirty 면 상태를 바꾸지 않은 채 중단하고 알립니다. 유일한 예외는 **이미 기본 브랜치에 있고** 사용자가 **dirty 경로 전부**를 이번 작업 입력으로 채택한다고 명시한 경우이며, 채택 경로를 감사 기록의 변경 파일 필드에 적습니다. 다른 브랜치가 dirty 면 예외 없이 중단합니다. AI 는 기존 변경을 stash·checkout·삭제하지 않습니다.
3. clean 이고 기본 브랜치가 아니면 기본 브랜치로 checkout 한 뒤 clean 을 다시 확인합니다.
4. 원격 모드(`archive.sh` 의 `detect_remote_mode` 와 같은 기준)면 기본 브랜치와 upstream 관계를 확인합니다. `git fetch` 와 판정은 `bash rd-workflow/scripts/lifecycle/start_preflight.sh` 가 한 번에 합니다(1항~3항 뒤, fetch 외 비변경). synchronized → 진행 / ahead 커밋 **전부**가 FR 등록 커밋 형태(단일 부모 + `FUTURE_REQUESTS.md` 행 1개 추가 + `items/` 상세 1개 신규 + 선택적 `raw-captures/` 캡처 1개 신규 — `registration_commit_shape`, 커밋 메시지·작성자 무관)이면 **자동 채택**해 진행하고 `push 예정` 에 `archive.sh 경유(기본 브랜치 미push N개 — 전부 FR 등록 커밋, 자동 채택)` 로 적습니다(그 커밋은 `/fr add` 가 보존한 backlog 기록이며 어차피 `archive.sh` 의 기본 브랜치 push 에 실립니다 — lifecycle 밖 push 를 새로 허용하는 것이 아닙니다) / 그 외 ahead(등록 형태가 아닌 커밋이 하나라도 있음, merge·root 커밋 포함) → 그 커밋이 이번 작업의 것이라는 보장이 없으므로 **AI 는 발행하지 않습니다**: `light` 는 작업을 진행하되 `push 예정` 에 `보류(미push 커밋 N개)` 로 적고 마감 push 를 하지 않은 채 종료 보고에 "미push" 로 인계하며, `standard` 는 `archive.sh` 가 기본 브랜치 전체를 push 하므로 시작하지 않고 인계합니다. 두 경우 모두 사용자가 **ahead 커밋 전부의 발행을 명시 채택**하면(2항 dirty 예외와 같은 방식) 정상 진행하고 채택 사실을 감사 기록 이력 필드에 적습니다 / behind·diverged·upstream 부재·fetch 실패 → 시작하지 않고 사용자에게 인계합니다(AI 는 pull·rebase·reset 을 하지 않습니다). 로컬 전용 모드는 이 항을 건너뜁니다.
5. 시작 시점 `HEAD` 를 baseline 으로 감사 기록에 남깁니다.

### 마감 상태 계약

| 항목 | `light` | `standard` | `full` |
|---|---|---|---|
| 브랜치 | 기본 브랜치 커밋 1회 | fr → `archive.sh` merge | 현행 |
| push | 원격 모드면 커밋 직후 push (`archive.sh` 의 `detect_remote_mode` 와 같은 기준). 시작 계약 4항이 ahead 를 보류로 적었고 사용자 채택이 없으면 push 하지 않음. 실패 시 완료로 보고하지 않고 종료 보고에 "미push". 반자율·autopilot 에서도 허용되는 유일한 lifecycle 밖 push 이며 조건은 `AUTONOMY.md` 중단 조건 6 | `archive.sh` | 현행 |
| tag | 없음 | `archive.sh` | 현행 |
| task-state·CURRENT_TASK·REQUEST·raw-capture | 건드리지 않음 | 현행 small 경로와 같음 | 현행 |
| 기존 FR | 있으면 같은 커밋에서 done (인덱스 삭제 + 상세 status) | archive content commit 에서 done | 현행 |
| 사용자 가시 결과 | 종료 보고 블록 | 종료 보고 + archive 출력 | 현행 |

**`archive.sh` 는 작업 worktree 안에서 호출해도 됩니다.** 발행 대상이 기본 브랜치 worktree(main worktree)가 아니면 그쪽으로 `cd` 해 자기 자신을 재실행하며, 원래 호출한 worktree 는 정리하지 않고 보존합니다. `--task <slug>` 를 명시하면 어느 위치에서 불러도 그 작업을 대상으로 삼습니다.

**merge 만으로는 발행 완료가 아닙니다.** `archive.sh` 는 merge 이후 tag·기본 브랜치 push·tag push 를 별도 단계로 수행하므로, merge 직후 중단되거나 push 가 실패해도 "merge 됐다"는 사실만으로는 발행이 끝난 게 아닙니다. `rd task list`(및 `--rebuild`)는 아래 세 상태로 구별해 보여줍니다.

| 상태 | 의미 | 목록 표시 | 삭제·정리 권고 |
|---|---|---|---|
| 진행 중 | fr ref 가 기본 브랜치에 merge 되지 않음 | 진행 중 | 하지 않음 |
| **발행 확인 필요** | merge 됐지만 archive tag 가 없거나 원격 반영을 확인할 수 없음 | ⚠ 발행 확인 필요 | **하지 않음** — `archive.sh --task <slug>` 재실행으로 확인·재개를 안내 |
| 정리 잔여 | merge + 이 작업의 발행 commit 을 가리키는 archive tag + (원격 모드면) 그 commit 이 원격 기본 브랜치에 포함됨이 확인됨 | 정리 대기 | 정리 명령 제시 |

### 세션 기동

worktree 를 만든 뒤 `promote.sh` 는 **그 worktree 에서 작업할 에이전트 세션을 기동하려 시도**합니다. 여기서 보장하는 것은 두 가지뿐입니다 — worktree 가 준비되고, 그 안에서 세션을 여는 명령이 화면에 제시됩니다. **실제 자동 기동은 herdr 안에서 돌고 있을 때만** 일어나며(`HERDR_ENV=1`), 그 밖의 환경에서는 제시된 명령을 사람이 직접 실행합니다. 즉 herdr 는 선택적 의존이지 전제가 아닙니다.

기동은 **현재 workspace 안에 tab 을 새로 만들어** 그 안에 세션을 띄웁니다(화면을 분할하지 않습니다). tab 의 이름은 작업 slug 이고, herdr 의 agents 패널은 행마다 그 tab 이름을 보여주므로 **동시에 여러 작업이 떠 있어도 목록에서 바로 구분됩니다.** 사용자의 focus 는 가져오지 않습니다.

기동 직후 세션이 신뢰 확인 같은 다이얼로그를 띄워 `blocked` 로 들어가는 경우가 있습니다 — worktree 는 늘 처음 여는 경로라 드문 일이 아닙니다. 이때 결과는 `unknown` 이고 **tab 은 닫지 않습니다.** 승인은 사람이 합니다. 다만 **승인만으로 작업이 이어지지는 않습니다** — 인계 문구는 승인 뒤에야 전달할 수 있으므로, 그 세션은 승인 직후 지시를 기다리는 상태입니다. 승인한 뒤 `bash rd-workflow/scripts/rd task resolve-launch <slug>` 를 실행하면 세션 생존을 확인해 `launch=ok` 로 확정하고 **그 자리에서 인계 문구를 전달**합니다. 전달에 실패해도 생존 확정은 유효하며, 그때는 인계 문구를 화면에 출력하므로 세션에 직접 붙여 넣으면 됩니다. 시작 요청 뒤 응답이 늦어 시간 초과된 경우(`unknown`)도 같습니다 — tab 을 닫지 않고 같은 명령으로 확인·인계합니다.

**호출 세션의 거취 (launch 상태별).** 아래 표는 `session_launch_status_hint()` 가 내는
문구와 정확히 같다 — 코드와 문서가 어긋나면 grep 으로 바로 드러난다. **`unknown` 을
`failed`·`none` 과 같은 줄로 합치지 않는다** — `unknown` 은 자식 세션이 살아 있을 수
있어 호출 세션도 아직 이어받으면 안 된다.

| `launch` | 호출 세션의 거취 |
|---|---|
| `ok` | 이 세션은 여기서 멈춘다 — 이후 단계는 기동된 탭의 세션이 진행한다 |
| `unknown` | 호출 세션도 이어받지 않는다 — `resolve-launch` 로 확정한 뒤에만 갈린다(살아 있으면 멈춤 / `failed` 확정이면 이어서 진행) |
| `failed`·`none` | 자식 세션이 없다 — 호출 세션이 이어서 진행하거나 안내된 명령으로 세션을 연다 |

**이어서 진행할 때는 대상 worktree 로 먼저 이동합니다.** `promote.sh` 는 `--no-worktree`
를 쓰지 않는 한 별도 worktree 를 만들 뿐 호출 세션의 작업 디렉터리를 바꾸지 않습니다 —
`failed`·`none`(또는 `resolve-launch` 의 `dead` 확정)으로 같은 세션이 이어서 진행하는
경우, promote 출력의 `worktree <path>` 로 `cd` 한 뒤에 이후 단계를 진행해야 원래
디렉터리의 파일을 건드리지 않습니다.

**깊이 1 제한.** 기동된 자식 세션은 또 다른 세션을 기동하지 않습니다(`RD_CHILD_SESSION=1` 이 상속됩니다). 자식 세션에서 `promote.sh` 를 부르면 worktree 는 정상적으로 만들어지고 기동만 건너뛰며, 수동 기동 명령이 나옵니다.

기동 결과는 색인의 `launch` 필드에 네 값 중 하나로 남고 `rd task list` 가 그대로 보여줍니다.

| `launch` | 의미 | 사용자가 할 일 |
|---|---|---|
| `ok` | 세션이 붙었음이 확인됨 | 없음 |
| `failed` | 기동을 시도했고 실패가 확정됨 | 제시된 수동 기동 명령 실행 |
| `none` | 기동을 시도하지 않음(herdr 밖, 자식 세션 등) | 제시된 수동 기동 명령 실행 |
| `unknown` | 시도했으나 성공·실패를 판정하지 못함(승인 대기·응답 지연·시간 초과 등) | `rd task resolve-launch <slug>` — 생존 확인 후 `ok`/`failed` 로 확정하고, 살아 있으면 인계까지 전달. herdr 로 조회할 수 없으면 아래 「herdr 밖에서 `unknown` 해소하기」 |

**`unknown` 은 `none` 이 아닙니다.** 세션이 실제로 떠 있는데도 없는 것으로 다루면 같은 worktree 에 두 번째 세션을 띄우게 되므로, 자동 재기동을 하지 않고 사람이 확인합니다.

기동이 진행 중인 동안 색인의 `launch` 는 `launching` 으로 예약됩니다. 이 상태에서는 그 작업의 `rollback`·`archive` 가 거부됩니다(기동 중인 세션의 worktree 를 지우지 않기 위해서입니다). `unknown` 도 같은 이유로 거부되므로, **`launching` 과 `unknown` 은 모두 `bash rd-workflow/scripts/rd task resolve-launch <slug>` 로 해소합니다** — 세션이 살아 있으면 `ok`, 찾을 수 없으면 `failed` 로 확정하고, 판정이 서지 않으면 아무것도 바꾸지 않습니다. `launching` 은 예약을 만든 프로세스가 아직 살아 있으면 해소하지 않습니다(`unknown` 은 예약이 없을 수 있으므로 곧바로 생존 확인으로 갑니다).

#### herdr 밖에서 `unknown` 해소하기

herdr 가 없는 셸(또는 herdr 미설치)에서는 생존 조회가 언제나 "판정 불가" 로 돌아옵니다. 그래도 작업을 끝낼 수 있도록 `resolve-launch` 는 두 갈래로 갈립니다.

- **자동 기동을 시도한 기록이 없는 작업** — 기동 예약(`launch-token`)이 없는 행입니다. 구버전 작업을 색인으로 흡수할 때 `launch=unknown` 으로 적히는 경우가 여기 해당합니다. 띄운 세션이 애초에 없으므로 사람 확인 없이 `launch=none` 으로 확정하고, 그 자리에서 `rollback`·`archive` 차단이 풀립니다.
- **기동을 시도했는데 결과를 모르는 작업** — 조용히 확정하지 않습니다. 살아 있는 세션을 없다고 적으면 같은 worktree 에 두 번째 세션을 띄우게 되기 때문입니다. 세션이 없거나 이미 끝났음을 **직접 확인한 뒤** `bash rd-workflow/scripts/rd task resolve-launch <slug> --assume-ended` 로 `failed` 확정합니다.

### 대상 선택 규칙

여러 작업이 동시에 진행 중일 때 `rd task` 명령(`set-status`·`archive`·`rollback` 등)이 어떤 작업을 대상으로 삼는지는 **호출 위치**가 정합니다(단일 판정 함수 `task_resolve_target`, `rd-workflow/scripts/_task_common.sh`).

| 호출 | 대상 판정 |
|---|---|
| 대상 지정 없이, 현재 체크아웃이 그 작업의 worktree 안 | 그 작업 (인자 불요) |
| 대상 지정 없이, 그 밖의 위치(기본 브랜치 worktree 등) | 진행 중인 작업이 1건이면 그 작업 / **2건 이상이면 아무것도 바꾸지 않고 중단** + 목록과 `--task` 지정 방법 안내 |
| `--task <slug>` 명시 | 어느 위치에서 불러도 그 작업. 현재 worktree 의 작업과 다르면 **경고 한 줄 후 진행**(거부하지 않음) |

### `--no-worktree` 작업의 마감 경로

`--no-worktree` 로 시작한 작업은 기본 브랜치 체크아웃을 그대로 점유하므로, 별도 worktree 로 옮기지 않고 마감합니다.

1. 작업 기록을 그 체크아웃 위에서 커밋합니다.
2. `git switch <기본 브랜치>` 로 되돌립니다.
3. `bash rd-workflow/scripts/lifecycle/archive.sh --task <slug>` 로 마감합니다 — `--task` 로 대상을 명시해야 하며, 되돌린 체크아웃에는 이제 그 작업의 파일이 없으므로 경로가 아니라 fr 브랜치 tip 에 커밋된 상태를 읽습니다.

마감이 아니라 **취소**할 때도 기본 worktree 를 지우지 않습니다. `bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task <slug>` 는 대상이 기본 worktree 이면 worktree 제거 대신 **체크아웃을 기본 브랜치로 되돌린 뒤** fr 브랜치와 색인 행만 정리합니다(되돌릴 수 없으면 — 예: 커밋되지 않은 변경 — 아무것도 바꾸지 않고 멈춥니다).

### 취소(rollback)가 보존하는 것과 `--force`

`rollback` 은 worktree 와 브랜치를 지우는 파괴적 명령이므로, 지우기 전에 두 가지를 확인하고 **하나라도 걸리면 아무것도 바꾸지 않고 멈춥니다.**

| 확인 | 걸렸을 때 |
|---|---|
| 그 작업에 기동된 에이전트 세션이 살아 있는가(`launch=ok` 이고 생존 확인이 `dead` 가 아님) | 세션을 먼저 끝내라고 안내하고 중단. 실행 중인 세션이 만든 변경을 지우지 않기 위해서입니다 |
| 대상 worktree 에 커밋되지 않은 변경이 있는가 | 변경 목록(앞 10건)을 보여 주고 중단. 커밋·stash 방법을 함께 안내합니다 |

`launching`·`unknown` 은 기존대로 `resolve-launch` 로 해소한 뒤 다시 시도합니다.

취소를 정말 진행하려면 **`--force`** 를 붙입니다 — "살아 있을 수 있는 세션과 미커밋 작업물을 알고도 버린다" 는 뜻이며, 버리는 내용을 경고로 출력한 뒤 진행합니다. 무엇을 잃게 되는지 미리 보려면 `--dry-run` 이 같은 요약(세션 상태 + 미커밋 변경)을 출력합니다.

### 커밋 전 재분류와 상향

- **시점**: `light` 는 유일한 커밋 직전, `standard`·`full` 은 final diff review 세션 생성 직전.
- **대상**: baseline 이후의 실제 변경 집합 = `git status --porcelain`(staged·unstaged·untracked) + `git diff --name-only <baseline>..HEAD`. 워크플로 생성 파일은 제외.
- **판정**: 변경 집합에 현재 등급의 신호를 벗어나는 항목이 있으면 상향하고, 상향된 등급의 필수 단계 중 생략한 것을 그 시점부터 수행합니다.
  - `light → standard`: `promote.sh --size small --source-fr <FR|->` (dirty 변경은 `git switch` 로 새 fr 브랜치에 실림) → 축약 REQUEST 작성(`## Risk Tier` 의 baseline HEAD 는 tier-log 행과 같은 값, 이력에 상향 사유) → 변경 + REQUEST 를 **같은 커밋** → final diff review → `archive.sh`. tier-log 에는 이 시점에 확정 행 1개를 append 합니다(최종 등급 `standard`, 이력 `light → standard`) — 같은 커밋에 포함하며 canonical token 밖의 값은 쓰지 않습니다.
  - `standard → full`: 별도 spec/plan 파일 작성 → spec/plan review → final diff review. 브랜치 유지.
- **사후 발견** (`light` 커밋이 이미 기본 브랜치에 있음): `bash rd-workflow/scripts/prepare_review_pipeline.sh diff "git diff <오분류 커밋>^..HEAD"` 로 세션 1개를 만들고 iteration commit 규칙으로 진행합니다. Finding 이 있으면 `이의 없음` 까지 새 작업 착수·발행을 차단하고 force-push 는 금지합니다. revert 는 리뷰가 권고할 때 사용자가 결정합니다. Finding 이 없으면 tier-log 에 사후 리뷰 결과 한 줄을 추가합니다.

### 감사 기록

단일 스키마 `baseline HEAD | 최초 등급 | 최종 등급 | 근거 신호 | override·상향 이력 | 변경 파일 요약`. 기록 시점: `standard`·`full` 은 활성 REQUEST 를 만들 때 `최종 등급` 에 **현재 등급**을 즉시 적고(`-`·빈 값으로 두지 않음 — `full` 은 REQUEST review 부터, `standard` 는 final diff review 에서 이 값을 읽습니다) 재분류 직후 확인·갱신합니다. `light` 는 재분류 직후 tier-log 에 확정 행을 **1회 append** 합니다(시작 시점에는 쓰지 않음 — light 커밋 전 상태는 Git 에 남지 않아 2회 쓰기가 이력을 더하지 않고, 중단되면 `-` 행만 남습니다). 표 값의 `|` 는 `\|` 로, 개행은 공백으로 바꾸고, 변경 파일 요약은 `파일 수 + 대표 경로 ≤ 3` 로 적습니다.

- `light`: `rd-workflow-workspace/reports/tier-log.md` 에 `| 날짜 | baseline HEAD | 최초 등급 | 최종 등급 | 근거 신호 | override·상향 이력 | 변경 파일 요약 |` 한 행을 append 하고 같은 커밋에 포함합니다. 커밋 메시지에는 넣지 않습니다.
- `standard`·`full`: `REQUEST.md ## Risk Tier` 의 항목에 적고 아카이브와 함께 보존합니다. `- 최종 등급: <token>` 줄은 `prepare_review_pipeline.sh` 가 읽는 기계 판독 줄이므로 형식을 지킵니다(`standard` 면 리뷰 effort 가 `small_task_reasoning_effort` 를 따릅니다).

### light 등급 체크리스트

1. 시작 계약 5항 확인 → 그 직후 시작 보고 블록 1회. 필드는 위 위험 등급 절의 정본 목록을 그대로 상속하고(`실행 모드` 포함), `light` 는 여기에 `baseline HEAD` 만 덧붙입니다 — 블록에만 남기고 파일에는 아직 쓰지 않습니다. `light` 에서 값이 갈리는 필드는 `push 예정` 뿐입니다: 원격 모드면 synchronized 는 "커밋 직후 push", ahead 가 전부 FR 등록 커밋이면 `start_preflight.sh` 의 자동 채택 문구 그대로, 그 외 ahead 는 "보류(미push 커밋 N개)", 사용자가 채택을 명시했으면 "커밋 직후 push(ahead N개 채택)" 로 적고, 로컬 전용 모드는 `없음` 으로 적습니다.
2. 구현 → 고친 영역 검증.
3. 커밋 전 재분류 → tier-log 에 확정 행 1개 append(최종 등급 `light`, 변경 파일 요약). 상향이면 위 절차로(행은 `standard` / `light → standard` 로 append).
4. 기존 FR 이 있으면 done 처리(인덱스 행 삭제 + 상세 `status: done`).
5. 커밋 1회(한국어 한 줄 요약) → 원격 모드면 push(`push 예정` 이 보류였고 채택이 없으면 push 하지 않고 "미push" 로 보고) → 종료 보고 블록.

## 입력 소스

작업을 시작할 때 입력이 어디서 오는지에 따라 진입점이 달라집니다.

### 자유 텍스트 요구사항 (기본)

사용자가 직접 요구사항을 말하면 위험 등급을 판정합니다(Intake 규칙). 시작 보고 블록은 위 위험 등급 절의 생산자·시점(`full` 은 판정 직후, `light`·`standard` 는 시작 계약 확인 직후) 을 따릅니다:
1. `light`·`standard` → FR 등록 없이 그 등급의 절차로 즉시 진행합니다. `light` 의 범위는 현재 요청과 시작 보고 블록이 권위입니다.
2. `full` → FR 에 자동 등록하고 사용자가 다음 단계를 지정하면 해당 skill 로 진행합니다.

`full` 등급의 자유 텍스트 진행 순서:
`/planning-design-intake` → REQUEST.md 생성 → `/request-to-reviewed-plan` (spec/plan)

`/request-to-reviewed-plan` 은 이미 작성된 REQUEST.md 를 입력으로 한다.
새 자유 텍스트 `full` 작업에서 RTRP 를 직접 호출하지 않는다 — `/planning-design-intake` 를 먼저 호출한다.

### /fr add 직접 호출

등록만 수행, 실행하지 않음 (기존과 동일).

### 기획서 (외부 문서)

기획서 텍스트가 있으면:
1. FR에 자동 등록 (기획서 기반 새 기능은 `full` 이므로 Intake 규칙상 FR 등록 후 지시 대기)
2. `/planning-design-intake` → REQUEST.md 생성 → `/request-to-reviewed-plan`
(v1: 기획서 텍스트 필수. 디자인 URL/스크린샷은 선택 — 있으면 Design Reference Memo로 수집)

### 갭 체크 (선택)

spec 작성 직후, spec/plan review 전에 → `/gap-check`
Design Reference가 있으면 추천. 없어도 에러/엣지 케이스 점검 가능.

## 기본 분기

### `light`

`구현 → 검증 → 커밋 전 재분류 → 기본 브랜치 커밋 1회 (+ tier-log 행)` — 위 "light 등급 체크리스트".

### `standard`

`promote.sh --size small → 축약 REQUEST → 구현 → 검증 → 커밋 전 재분류 → final diff review → seal → 아카이브 보류 → 기록 커밋 → REQUEST 아카이브(archive.sh)`

### `full`

`FR 등록 → REQUEST 정리 → REQUEST review → spec/change spec → plan → spec/plan review → 구현 → 검증 → final diff review → seal → 아카이브 보류 → 기록 커밋 → REQUEST 아카이브`

FR 승격은 `bash rd-workflow/scripts/lifecycle/promote.sh --short-title <slug> --size large|small` (`full` = large, `standard` = small). rollback 은 `promote_rollback.sh`.

autopilot 에서는 이 분기가 모드 A(`full`)/모드 B(`standard`) 로 나타나며 등급 판정이 모드를 정합니다. 상세는 `rd-workflow/claude_skills/autopilot/SKILL.md` "실행 모드".

## REQUEST 아카이브

작업이 완료되면 현재 `REQUEST.md`를 `rd-workflow-workspace/backlog/request-archive/`에 보관합니다.

- 파일명: `YYYY-MM-DD-HHMM-${SHORT_TITLE}.md` (`SHORT_TITLE` 은 `CURRENT_TASK.md ## Short Title` 에서 read — canonical regex 검증된 값)
- 새 REQUEST로 덮어쓰기 전에 먼저 아카이브합니다
- 아카이브 후 `REQUEST.md`는 빈 템플릿으로 되돌립니다
- `full`·`standard`(fr 브랜치 작업): fr branch에서 archive content commit 후 main으로 switch, `bash rd-workflow/scripts/lifecycle/archive.sh` 호출로 merge + tag + push + branch 정리를 일괄 처리한다.

### `아카이브 보류` — 리뷰 종결과 발행 사이

`아카이브 보류` 는 canonical Status 9종 중 하나이며, 의미는 「**리뷰 종결·발행 대기**」로 **완료가 아닙니다.** 전이는 `diff review 대기 → 아카이브 보류 → 완료` 이고, 리뷰 후 변경이 필요해지면 `아카이브 보류 → 구현 중` 으로 되돌아갑니다(그러면 마커의 트리 해시가 어긋나 재리뷰·재seal 없이는 발행할 수 없습니다).

**정상 경로의 순서가 계약입니다 — 리뷰 종결 → seal → 상태 전이 → 기록 커밋 → 발행.**

| # | 행위 | 게이트 판정 |
|---|---|---|
| 1 | final diff review 가 `이의 없음` 으로 종결 | — |
| 2 | `bash rd-workflow/scripts/rd review seal <세션>` — 종결 마커 생성 (워킹트리) | — |
| 3 | `bash rd-workflow/scripts/rd task set-status "아카이브 보류"` | — |
| 4 | 마커 + archive content commit (REQUEST 아카이브·FR done·completion report) | 보류 상태이고 변경이 전부 워크플로 기록 경로 안이면 **통과** |
| 5 | `bash rd-workflow/scripts/lifecycle/archive.sh` | 마커 strict 검증 통과 시 발행 |

- 마커와 상태 전이가 **커밋 앞에** 오는 것이 핵심입니다. 게이트는 워킹트리의 task-state 를 읽으므로 상태 전이가 커밋 없이 즉시 반영되고, 순서를 뒤집어 「기록 커밋 후 보류 전이」로 적으면 보류 상태에서만 통과하는 커밋을 보류 전에 하려는 **진입 불가 순환**이 됩니다.
- 4번 커밋 이후에야 마커가 발행 게이트의 판정 대상 commit 에 들어갑니다 — 워킹트리에만 있는 seal 로는 발행하지 못합니다 (판정 대상 commit 의 정의는 `FILE_BASED_REVIEW_PIPELINE.md`).
- 현재 상태에서 무엇을 해야 하는지는 `bash rd-workflow/scripts/rd task status` 가 안내합니다 (seal 이 커밋되었으면 `발행`, 워킹트리에만 있으면 `커밋하세요`, 없거나 무효면 사유별 복구 안내).
- 4번 커밋에서 게이트가 보는 대상은 index 만이 아니라 **index ∪ 워킹트리(추적 파일)** 입니다. `git commit -a`·`git commit <경로>` 도 같은 제한을 받으며, 보류 상태에서 기록 경로 밖의 파일이 수정되어 있기만 해도 막힙니다 — 코드 변경이 필요해진 것이므로 `rd task set-status "구현 중"` 으로 되돌린 뒤 재리뷰합니다.
- 5번에서 `archive.sh` 는 fr 브랜치가 없는(no-fr) 운용일 때 **발행 대상 commit 을 확정한 뒤 tag 를 만들기 전에** 마커가 승인한 보호 트리 해시와 한 번 더 대조합니다. precheck 이후 HEAD 가 전진해 미검토 코드가 발행되는 창을 닫기 위함이며, 어긋나면 되돌리거나 재리뷰(`prepare_review_pipeline.sh diff` → `rd review seal`) 후 다시 실행하라고 안내하고 중단합니다. fr 모드는 merge 이후 구간을 보는 기존 두 검사가 같은 창을 이미 닫습니다.

## Raw Capture

각 진입점에서 사용자 원본 입력을 `rd-workflow-workspace/raw-captures/YYYY-MM-DD-HHMM-{stage}-{short-title}.md` 에 가공 없이 기록한다.

### Stage / 진입점

| stage | skill |
|-------|-------|
| fr | `/fr add` |
| request | `planning-design-intake`, `request-to-reviewed-plan` |
| spec | `request-to-reviewed-plan` (spec 작성 직전) |
| plan | `request-to-reviewed-plan` (plan 작성 직전) |

### Short Title 계약

- single source of truth: `CURRENT_TASK.md ## Short Title`
- canonical: `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (영문 kebab-case, 영숫자 시작·끝, `-` 단독 / empty / hyphen-only 금지 — `-` 는 reserved sentinel)
- 부여 진입점 (start point — 3 곳): `/fr add` (FR 시작), `planning-design-intake` (FR 없는 직접 REQUEST), `promote.sh` (FR 없는 직접 `standard` 작업 — `small-task-implement`가 이를 호출하며 skill 자체는 read-only). 부여 조건은 진입점별로 다름:
  - **`planning-design-intake`(`--mode intake`) · `request-to-reviewed-plan` FR 승격 진입(`--mode promote`)** — 둘 다 `rd task guard` 의 같은 판정 함수(`task_guard_decide`)를 mode 만 다르게 호출한다. 판정 7순위·`fr-branch` 활성 판정은 `rd-workflow/docs/guides/task-state-guide.md` 「guard 판정」·「fr-branch 활성 판정」 절이 정본이며 여기서 중복 서술하지 않는다. 요지만 적으면:
    - (a) `## Short Title = -` 또는 섹션 부재 → CANDIDATE 기록 (부재 시 섹션 자동 추가)
    - (b) `## Short Title = CANDIDATE` (equal) → read-only continue
    - (c) 그 외 → 순위 4(같은 source FR 로 재진입) 이후를 따른다 — `fr-branch` 활성이면 차단, `## Status = 대기 중` 이면 stale 값으로 보고 rebind, 그 외(완료 포함)·부재/파싱불가는 차단
  - **`/fr add`(`--mode fr-add`) — `Intake 규칙` 따라:**
    - `## Short Title = -` → 새로 부여 (baseline)
    - non-`-` → read-only (FR 등록 + FR 캡처는 새 short-title, `CURRENT_TASK` 변경 안 함)
    - 섹션 부재 → warn-only (legacy active task 보호)
- 부여 후 ~ archive 까지 원칙적으로 immutable (변경 금지). 예외: `rd task set-title -` — `## Status == 대기 중` 이고 `fr-branch` 가 비활성일 때만 허용되는 수동 reset(상세는 `task-state-guide.md` 「Short Title reset」)
- 캡처 단계 (`request-to-reviewed-plan` 의 일반 진입) 는 short-title 부재 시 부여 안 함, 캡처 생략 + 경고
- post-plan skill (`implement-reviewed-plan`, `final-diff-review`) 은 read-only
- reset trigger 4 가지: (1) autopilot REQUEST archive, (2) 수동 archive (`request-archive/README.md` 4 단계), (3) `planning-design-intake` overwrite-backup (implicit archive), (4) `rd task set-title -` 수동 reset(위 예외 조건 충족 시). (1)~(3) 은 default `-` 로 복귀, (4) 는 `short-title` 과 `source-fr` 을 함께 `-` 로 복귀

### Archive 통합

archive trigger 3 가지:

- `/fr archive`: `done`/`dropped` FR 의 short-title → `*-fr-{short-title}.md` 를 `raw-captures/archive/` 로 이동
- REQUEST archive (autopilot / 수동): 활성 작업 short-title → `*-{request,spec,plan}-{short-title}.md` 를 `raw-captures/archive/` 로 이동 + `## Short Title` reset
- `planning-design-intake` overwrite-backup = implicit archive: 기존 REQUEST.md 존재 시 자동으로 REQUEST 백업 + 같은 short-title 의 request/spec/plan 캡처 archive + `## Short Title` reset → 새 작업 진행. drift 상태 (REQUEST.md 있는데 `## Short Title` = `-`/부재) 는 캡처 archive skip + 명시적 경고

archive 매칭은 frontmatter exact match (filename prefix collision + body-content collision 모두 차단).

### git 추적

`rd-workflow-workspace/raw-captures/` 는 git 추적 대상이다 (정책 변경 — 이전엔 `.gitignore` 제외). capture 본문은 입력 원문이라 민감정보 (token / API key / password) 포함 가능 — commit 전 검토와 노출 시 secret rotation 은 프로젝트 책임 (`raw-captures/README.md` 보안 경고 참조).

`/fr add` 의 등록 결과(인덱스 행·`items/` 상세·`fr` 캡처)는 `rd task fr-register` 가 호출 브랜치와 무관하게 **기본 브랜치에 커밋**합니다(내용 단위 합성, plumbing + CAS, push 안 함, 실패는 fail-open). fr 브랜치의 워킹트리에도 같은 파일이 남아 iteration commit 에 실리며 archive merge 에서 같은 변경으로 수렴합니다. 상세는 `rd-workflow/scripts/lifecycle/README.md`.

## Lifecycle 자동화

fr branch lifecycle 관련 스크립트 요약:

| 스크립트 | 역할 |
|----------|------|
| `rd-workflow/scripts/lifecycle/promote.sh` | FR 승격 시 fr branch 생성 |
| `rd-workflow/scripts/lifecycle/archive.sh` | 작업 완료 시 merge + tag + push + branch 삭제 일괄 처리 |
| `rd-workflow/scripts/lifecycle/promote_rollback.sh` | fr branch abandon (rollback) |
| `rd-workflow/scripts/lifecycle/slug.sh` | slug 정규화 (`normalize_slug()`) |
| `rd-workflow/scripts/lifecycle/test_lifecycle.sh` | lifecycle 전체 self-test |
| `rd-workflow/scripts/lifecycle/start_preflight.sh` | 작업 시작 계약 진입점 — fetch·ahead 분류(등록 커밋 자동 채택)·미병합 브랜치 backlog 대조를 한 번에 |
| `rd-workflow/scripts/lifecycle/merge_fr_index.sh` | `FUTURE_REQUESTS.md` 행 집합 3-way 병합 (archive 의 인덱스 단독 충돌 해결) |
| `rd-workflow/scripts/fr_backlog_scan.sh` | 미병합 브랜치의 backlog 추가 파일 대조 (단독 실행 가능) |

세부 사용법은 `rd-workflow/scripts/lifecycle/README.md` 참조.

### 관련 `workflow.json` 설정 키

- `stale_behind_threshold`(기본 `20`) — `rd task list` 가 작업을 "묵은 작업"(`⚠ N커밋 뒤처짐`)으로 표시하는 기준. 판정은 기본 브랜치 대비 그 fr 브랜치가 뒤처진 커밋 수(`git rev-list --count <fr-branch>..<default-branch>`)입니다. `tasks_list.sh` 가 이 키를 읽고, 없거나 파싱할 수 없으면 `20` 을 씁니다.
- `worktree_root`(기본값 `.worktrees`) — `promote.sh` 가 worktree 를 만드는 기본 위치. 상대 경로는 main worktree 기준이고(`<main worktree>/<worktree_root>/<slug>`), 절대 경로와 `~/...` 도 씁니다. 부모 디렉터리가 없으면 만듭니다(새로 만들 때 안내 한 줄). `--worktree-path` 로 넘긴 명시 경로가 이 키보다 우선하며, 그 경우는 부모가 이미 있어야 합니다. 저장소 밖으로 옮기면 `.gitignore` 의 `.worktrees/` 항목이 더는 의미가 없으므로, 새 위치가 저장소 안이면 그 경로를 직접 무시 목록에 넣어야 합니다.

## 기본 원칙

- skill이 있으면 skill부터 호출합니다
- skill이 없거나 원하는 출력이 안 나오면 `rd-workflow/docs/prompts/`에서 맞는 프롬프트를 꺼냅니다
- `full` 등급은 reviewed spec / plan 파일을 만든 뒤에만 구현합니다
- 범위를 벗어난 아이디어는 `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`에 적습니다

## 권장 skill 순서

- 다음 단계를 고르기 어렵다면 `workflow-router`
- 기획서 텍스트가 있으면 `planning-design-intake`
- 자유 텍스트 `full` 작업 시작은 `planning-design-intake` → REQUEST.md 생성 → `request-to-reviewed-plan`
- REQUEST.md 가 이미 있으면 `request-to-reviewed-plan` (spec/plan 작성 + review)
- spec 갭 점검은 `gap-check`
- `standard` 등급 구현은 `small-task-implement`, `light` 는 위 체크리스트(skill 없음)
- reviewed plan 구현은 `implement-reviewed-plan`
- 마무리는 `final-diff-review`

## 프로젝트 초기 설정

1. `PROJECT_CONTEXT.md`를 만듭니다
2. `rd-workflow/scripts/{build,test,lint,typecheck}.sh`를 프로젝트 명령으로 채웁니다
3. 빈칸이나 불명확한 제약이 남아 있으면 `PROJECT_CONTEXT` review를 돌립니다

초기 설정 절차는 `rd-workflow/docs/guides/setup_with_claude.md`에 있습니다.

## Review Pipeline

- review는 기본적으로 `prepare_review_pipeline.sh`로 세션을 만들고 `run_review_turn.sh`로 턴을 이어갑니다
- 사용자는 보통 검토 시작만 말하고, 세션 파일 작성과 턴 전환은 AI가 처리합니다
- 세부 규칙은 `rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md`에 적혀 있습니다

### diff review base 판정

final diff review 의 base 는 고정되어 있지 않습니다. `bash rd-workflow/scripts/prepare_review_pipeline.sh diff [--base <ref>] [diff-target]` 가 아래 우선순위로 판정합니다.

| 순위 | 입력 | base |
|---|---|---|
| 1 | `--base <ref>` | `<ref>^{commit}` |
| 2 | task-state `fr-branch` | `merge-base <기본 브랜치> <fr-branch tip>` — `fr-branch` 는 **merge-base 계산의 입력이지 base 자체가 아닙니다** |
| 3 | task-state `base-commit` | 저장된 OID 그대로 |
| 4 | 없음 | **세션을 만들지 않고 중단 (exit 1)** |

- **판정 실패는 중단입니다.** 빈 diff 나 엉뚱한 base 를 리뷰 대상으로 남기지 않기 위함이며, 다음도 모두 세션 미생성 + exit 1 입니다 — `--base` ref 가 없거나 커밋이 아님 / merge-base 계산 실패(얕은 clone 등) / `fr-branch` 가 stale·삭제됨 / 현재 HEAD 가 `fr-branch` 계보에 없음 / base 가 HEAD 의 조상이 아님(입력이 서로 모순) / base 와 HEAD 가 같은 커밋(리뷰할 변경 없음).
- **base 와 head 는 둘 다 full commit OID 로 resolve 되어 기록됩니다** — `Review Target` 은 `git diff <base OID>..<head OID>` 이고, `SESSION.md ## Branch Context` 의 `review-base-oid`·`review-head-oid` 가 기계 판독 권위입니다. `main` 같은 이동 ref 를 문자열로 남기면 세션 생성과 실제 리뷰 사이에 기준이 바뀝니다.
- **fr 브랜치를 쓰지 않는 운용**(기본 브랜치에서 바로 작업) 은 2번이 성립하지 않으므로 `bash rd-workflow/scripts/rd task set-base <ref>` 로 `base-commit` 을 1회 설정합니다. 입력이 ref 여도 저장 시점에 OID 로 resolve 되며, 커밋으로 해석되지 않으면 기록하지 않습니다.
- FR 승격을 거치는 경로는 이 값을 자동으로 기록하므로 별도 설정이 필요 없습니다 (승격 직전 HEAD).
- 기존 위치 인자 `diff-target` 은 그대로 지원합니다. `--base` 와 **동시에 줄 수 없고**, `git diff <base>..<head>` / `git diff <base>...<head>` 형태로 파싱되면 양끝을 OID 로 resolve 해 같은 검증을 적용합니다. 파싱되지 않는 임의 표현(서브모듈을 겨냥한 `git -C sub diff ...` 등) 은 세션은 만들되 두 OID 를 기록하지 않으므로, 그 세션은 봉인 시 `rd review seal --legacy-unverified` 가 필요합니다.

## Prompt 사용 위치

- 보정: `rd-workflow/docs/prompts/recovery/`
- 수동 복구: `rd-workflow/docs/prompts/manual/`
- 리뷰 기준: `rd-workflow/docs/prompts/review/`
