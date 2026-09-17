# Claude Project Rules

기본 인터페이스는 `짧은 자연어 요청`입니다 (`"future request에 기록해줘"`, `"이 요구사항으로 request-to-reviewed-plan skill로 진행해줘"`, `"standard 로 보고 바로 구현해줘"`). 프롬프트 파일은 기본 입력 방식이 아니라 예문·보정·수동 복구용입니다.

## 언어

한국어로 대화합니다. 코드 주석·식별자·문체는 기존 프로젝트 컨벤션을 따릅니다.

## 우선 원칙

1. 규칙·제약은 `PROJECT_CONTEXT.md`를 먼저 읽습니다.
2. 작업은 `REQUEST.md`·`CURRENT_TASK.md`에 적힌 범위 안에서만 합니다. REQUEST 가 없는 `light` 는 현재 사용자 요청과 시작 보고 블록에 적은 범위가 권위이며, 그 밖의 변경은 하지 않습니다.
3. 범위 밖이지만 가치 있는 항목은 `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`에 기록합니다.
4. 작업 착수 시 `rd-workflow/docs/flows/WORKFLOW.md` 위험 등급 절의 신호표로 등급(`light`/`standard`/`full`)을 판정해 시작 보고 블록을 내고(`full` 은 판정 직후, `light`·`standard` 는 시작 계약 확인 직후 1회), 그 등급의 절차표를 따릅니다. `full` 은 reviewed spec/plan 없이 구현하지 않습니다.
5. 등급 하향은 사용자만 합니다. AI 는 제안만 하고, 모호하면 한 단계 위 등급을 택합니다.
6. 구현 후에는 검증을 실행합니다 (절대 규칙 참조).

## Intake 규칙

새 작업 요청이 오면 등급을 판정합니다(시작 보고 블록의 시점은 WORKFLOW.md 위험 등급 절). `light`·`standard` 는 FR 등록 없이 바로 진행하고, `full` 은 판정 직후(원격 모드면 비변경 preflight 로 기본 브랜치 미push 수를 읽은 뒤) 시작 보고 블록을 낸 뒤 FR 에 등록하고(`/fr add`와 동일 절차 — `FUTURE_REQUESTS.md` 인덱스 + `items/` 상세 파일) "FR 등록: **{title}** — {summary}. 다음 단계를 지정해주세요."를 출력한 뒤 지시를 기다립니다. Source FR은 그 FR을 현재 작업으로 승격해 REQUEST.md를 쓸 때 채웁니다. 이미 등록된 FR 을 착수할 때 `light`·`standard` 로 판정되면 그 등급 절차로 진행하고 마감에서 FR 을 done 처리합니다.

진행 중(`CURRENT_TASK.md` Status ≠ `대기 중`)에 들어온 독립 요청은 **FR 로 등록**합니다. 등록 후 **동시 착수 여부는 사용자가 정합니다** — worktree 격리로 동시 진행이 가능해졌더라도 **AI 가 임의로 동시 착수하지 않습니다.** 사용자가 착수를 지시하면 별도 worktree 로 착수하고, 지시가 없으면 "FR 등록: **{title}**. 현재 작업 완료 후 진행하거나, 지금 별도 worktree 로 동시에 진행할 수 있습니다." 를 알린 뒤 현재 작업으로 복귀합니다.

등록 제외: `/fr add` 직접 호출(FR skill이 처리) / 단순 질문·확인, 워크플로 지시, 메타 대화 / 이미 등록된 요청의 후속 대화(clarification·수정·재시도).

**인프라 결함 라우팅**: rd-workflow 인프라 자체(산출물 문서·`rd-workflow/scripts/`·`rd-workflow/claude_skills/`)의 결함은 소비 프로젝트 FR로 등록하지 않고 `rd-workflow-workspace/reports/workflow-defects/`에 보고 파일만 만듭니다 (판별 기준·경계·형식: `rd-workflow/docs/guides/workflow-defect-reporting.md`).

## Workflow 우선순위

새 기능·큰 작업·기존 코드베이스의 중간 이상 변경에서는 Superpowers workflow부터 호출합니다 (필수 사용은 절대 규칙 참조). `light`·`standard` 등급, 초기 설정은 일반 방식으로 바로 처리해도 됩니다.

단계: 설계 `brainstorming` → 계획 `writing-plans` → 구현 `subagent-driven-development`(기본) 또는 `executing-plans`. worktree 가능 시 `using-git-worktrees` — worktree branch가 곧 fr branch로 동작하고(lifecycle 정책 결정 2) worktree path는 metadata가 authoritative입니다.

실행 모드 규칙:

- **절대 묻지 않는다.** upstream skill이 "Which approach?"를 요구해도 이 규칙이 우선하며, 기본값 `subagent-driven-development`로 바로 시작한다.
- **확인 생략**: 확정된 사안의 재확인, worktree 사용 동의, 설계·스펙 승인 대기, 과정상 체크포인트 응답 대기를 모두 생략하고 진행 보고만 남긴다. 생략 대상은 skill 내부의 확인 질문·응답 대기이며, 필수 review 수행 자체와 manual 모드의 단계 진입 지시 대기는 생략하지 않는다.
- **생략 금지**: merge·폐기·데이터 삭제·외부 발행 등 파괴적·비가역 결정, 블로커(정보 부족·반복 실패·진행 불능), 요구사항이 바뀌는 범위 변경, 제품 방향은 반드시 묻는다.
- 순차 의존성이 있으면 순차 dispatch한다. plan이 phase(파일 비중첩 task 그룹)를 표현하면 phase 내 task를 병렬 dispatch한다 (`rd-workflow/docs/guides/plan-parallel-phases.md`).
- inline(`executing-plans`)은 Task 1개 + 수정 파일 3개 이하, 또는 Task 2개 + 동일 경로 파일 1개만 수정일 때만 고른다 (검증 전용 Task도 센다). 사용자가 방식을 지정하면 그쪽을 따른다.
- subagent dispatch prompt에 `rd-workflow/docs/guides/subagent-git-safety.md`의 git 안전 문구를 포함한다 (공유 워킹트리 브랜치 전환 금지).

실행 모드 체계: `manual`(단계마다 사용자 확인) / `semi-auto`(**기본** — 착수 지시 후 중대한 변경 시에만 묻고 자율 진행, 중단 조건은 `rd-workflow/docs/flows/AUTONOMY.md`, Intake 규칙 유지) / autopilot(`/autopilot` 명시 호출 전용 skill). 기본값은 `rd-workflow/config/workflow.json`의 `default_execution_mode`(`manual`|`semi-auto`)이며 파일·키 부재는 `semi-auto`, 판정 불가(예: 파싱 실패·비허용 값·특수 경로·키 중복)는 `manual` + 경고이고(정본 목록은 `AUTONOMY.md`) 세션 지시가 우선합니다.

## 핵심 절차

- **`full`**: `FR 등록 → REQUEST 작성 → REQUEST review → spec/change spec → plan → spec/plan review → 구현 → 검증 → final diff review → REQUEST 아카이브`
- **`standard`**: `promote.sh --size small → 축약 REQUEST → 구현 → 검증 → 커밋 전 재분류 → final diff review → REQUEST 아카이브` (promote 이후는 인계된 세션이 수행 — 기동 실패·비-herdr 는 호출 세션이 계속. `unknown` 은 `resolve-launch` 로 확정하기 전까지 호출 세션도 이어받지 않는다)
- **`light`**: `구현 → 검증 → 커밋 전 재분류 → 기본 브랜치 커밋 1회 (+ reports/tier-log.md 행)` — REQUEST·리뷰·아카이브 없음. 시작·마감 계약은 `WORKFLOW.md` 위험 등급 절.

### REQUEST 아카이브

- `REQUEST.md`를 `rd-workflow-workspace/backlog/request-archive/YYYY-MM-DD-HHMM-${SHORT_TITLE}.md`로 복사한 뒤 초기 템플릿 상태로 비웁니다.
- `Source FR`이 `-`가 아니면 아카이브 기록 커밋 단계에서 `bash rd-workflow/scripts/rd task fr-done`을 호출합니다. `fr-done`이 묶은 FR 전부의 `items/` status와 인덱스 행 status를 함께 `done`으로 바꾸고, **인덱스 행 삭제는 `/fr archive`가 그 status를 보고 수행**합니다(연결이 끊기면 `/fr archive`가 0건으로 끝나 FR이 활성으로 남습니다). `fr-done`이 실패해도 발행은 계속하고, 출력을 completion report의 「FR 정리 결과」 절로 옮겨 발행 결과와 분리 보고합니다(재시도 대상은 아카이브된 REQUEST 사본의 `## Source FR`에서 회수, 상세는 `fr/archive.md`).
- `PROJECT_CONTEXT.md`의 `auto_completion_report: true`면 자동으로, 아니면 "작업 요약 report를 남길까요?" 질문 후 `rd-workflow-workspace/reports/completions/YYYY-MM-DD-HHMM-작업명.md`에 report를 씁니다.
- **완전 마감 후 `/clear` 안내 (필수)**: 아카이브 완료 + 산출물 손실 없음 확인(remote-mode는 push까지, local-only는 commit·merge까지) 후 마지막 응답에 `/clear` 가능 여부를 반드시 한 줄 명시합니다. 사용자가 추가 FR 등록 의사를 보이면 등록을 먼저 처리한 뒤 안내합니다. **herdr 환경(`HERDR_ENV=1`)이고 이번 아카이브로 worktree 를 정리했다면, 같은 응답에 그 작업의 herdr tab이 이제 사라진 worktree 를 가리키니 직접 닫아 달라는 안내를 함께 포함합니다** (AI 는 자신이 만들지 않은 tab을 닫을 수 없습니다).
- **큰 작업 lifecycle**: ① fr branch에서 archive content commit(REQUEST.md 비우기, archive 파일 생성, FR done 처리, completion report) — `CURRENT_TASK.md` 미러는 `archive.sh`가 baseline으로 되돌리므로 사람이 하지 않습니다. ② 기본 브랜치로 switch 후 `bash rd-workflow/scripts/lifecycle/archive.sh` 호출 (merge + tag + push + branch/worktree 정리 일괄).

## 절대 규칙 (모든 skill에 공통 적용)

- **`standard`·`full` 은 구현 완료 후 반드시 `/final-diff-review`를 거친다.** 건너뛰고 merge하거나 작업을 종료하지 않는다. `light` 는 커밋 전 재분류가 이를 대신하며, 재분류에서 신호가 벗어나면 상향한다.
- **Superpowers가 사용 가능하면 반드시 사용한다.** 불가능할 때만 직접 산출물을 작성한다.
- **테스트는 꼭 필요한 것만, 시간 비용을 재서 만든다.** 테스트의 가치는 실수를 잡는 데 있다. 통과만 하고 시간을 먹는 테스트는 부채이므로 만들지 않고, 발견하면 지운다. spec/plan 과 리뷰에서 다음을 점검한다: ① 이 테스트가 없으면 어떤 실수가 실제로 새는가 — 답이 없으면 만들지 않는다 ② 테스트 도구·fixture·판정 로직 자체를 검사하는 메타 테스트, 같은 사실을 다른 경로로 다시 확인하는 중복, "옛 패턴이 다시 나타나지 않는가" 류의 잔존 grep, 현실에서 일어나지 않는 실패 주입(가짜 git·바이트 훼손·경쟁 창 재현)은 기본적으로 만들지 않는다 ③ 실행 시간을 추정해 수 초를 넘는 케이스는 그 비용을 정당화하는 사유를 plan 에 적는다 ④ 검증은 고친 영역에 맞는 범위만 돌리고, 전수 재실행을 절차(아카이브·커밋 게이트)에 넣지 않는다. (근거: 2026-09-03 self_test 정리 — 감축 엔진·아카이브 재검증·주입 시나리오를 걷어내 전수 21분 → 12분)
- **검증**: 구현 후 `bash rd-workflow/scripts/{test,lint,typecheck,build}.sh`를 실행한다(프로젝트에 맞게 교체). typecheck는 정적 타입·컴파일 검사, build는 전체 빌드이며 build 실패는 검증 실패다. 교체 전(`TEMPLATE_STUB` 마커 존재)에는 **설계상 exit 1을 반환한다** — plan의 검증 Expected를 exit 0으로 쓰지 말고, 교체 후 기대값이나 프로젝트가 정의한 실질 검증 명령 기준으로 쓴다.
- **워크플로 인프라 검증**: rd-workflow 인프라(lifecycle·review 스크립트)를 수정했다면 `bash rd-workflow/scripts/self_test.sh [그룹...]`로 검증한다. 그룹은 `hooks` `review` `lifecycle` `skills` `build`이고 고친 영역의 그룹만 골라 돌린다. 인자 없음은 전수, `consumer`는 소비 프로젝트에서 뜻이 있는 스텝만, `RD_SELFTEST_DRYRUN=1`은 실행 예정 스텝만 출력한다.

## Review 규칙

- `full` 은 `REQUEST review`, `spec/plan review`, `final diff review`를 건너뛰지 않습니다. `standard` 는 `final diff review` 를 건너뛰지 않습니다.
- `prepare_review_pipeline.sh`로 세션을 만들고 `run_review_turn.sh`로 턴을 잇습니다. 최신 Reviewer 턴이 `이의 없음`을 명시할 때까지 이어가고, 사람 결정이 필요하거나 총 20턴에 도달하면 `awaiting-user`로 바꾸고 멈춥니다.
- **autopilot·반자율 모드에서는** `rd-workflow/docs/flows/AUTONOMY.md`의 자율 실행 규칙이 이 섹션보다 우선합니다 (예: 턴 한도 50턴). 절대 규칙과 일반 모드의 20턴 규칙은 변하지 않습니다.
- **REQUEST review 축약**: spec이 사용자 승인 완료 + REQUEST.md가 그 spec을 참조(승인된 결정의 백필)이면 1턴 확인으로 축약합니다. 1턴에서 이의가 나오면 일반 수렴 규칙으로 복귀합니다.
- 세션 종료 시 `rd-workflow-workspace/reports/reviews/`에 주요 쟁점과 결론을 요약한 report를 씁니다.
- plan의 `mechanical` task는 task별 리뷰를 생략(final diff에 위임)하고, spec/plan review는 같은 phase task의 파일 비중첩을 필수 확인합니다 (`rd-workflow/docs/guides/plan-parallel-phases.md`).

## Always Read

- 작업 시작 시: `REQUEST.md`, `PROJECT_CONTEXT.md`, `CURRENT_TASK.md`, `rd-workflow/claude_skills/*/rules.md`(설치된 extension이 있으면)
- 필요할 때만: `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`(FR 기록·조회·autopilot) / `rd-workflow/docs/flows/WORKFLOW.md`(작업 분기) / `rd-workflow/docs/AI_DOC_MAP.md`(문서 위치) / `rd-workflow/docs/prompts/README.md`(프롬프트 파일)

## Task Tracking

Status·Short Title·Source FR 변경은 `rd task` CLI를 경유합니다 (기계 판정 권위: `rd-workflow-workspace/.lifecycle/task-state` — `CURRENT_TASK.md`의 해당 필드는 표시용 미러). 미러는 표시용이면서 **권위 손실 시의 대조 출처**이므로, 세 필드를 손으로 한쪽만 고치지 않습니다 — promote 는 `source-fr` 가 양쪽에서 다르면 어느 쪽이 최신인지 판정하지 않고 중단합니다.

Status 허용값 (`rd task` CLI 전이표가 이 값으로 판정하며, hook이 강제하지 않으므로 사람과 AI가 지킵니다): `대기 중` / `REQUEST review 대기` / `spec/plan 작성 중` / `spec/plan review 대기` / `구현 중` / `검증 중` / `diff review 대기` / `아카이브 보류` / `완료`.

`아카이브 보류` 는 「리뷰 종결·발행 대기」이며 **`완료` 가 아닙니다.** final diff review 가 종결되고 종결 마커(`rd review seal`)를 만든 뒤 진입하며, 그 상태에서 기록 커밋을 하고 `archive.sh` 로 발행합니다. 전이는 `diff review 대기` → `아카이브 보류` → `완료` 이고, 리뷰 후 변경이 필요해지면 `아카이브 보류` → `구현 중` 으로 되돌립니다.

`CURRENT_TASK.md`는 orchestrator(메인 세션)가 REQUEST 정리·spec 생성·plan 생성·구현 시작·검증 완료·REQUEST 아카이브 후에 다시 씁니다. 병렬 구현자 subagent는 이 파일을 쓰지 않습니다 (`implementation_gate.sh`의 subagent 주체 게이트가 `Edit`·`Write` 경유 쓰기를 차단하며, 진행 상황은 결과로 반환합니다).

## Spec / Plan Naming

파일명은 `YYYY-MM-DD-HHMM-작업명-종류.md`이고 종류는 `spec` / `change-spec` / `plan`입니다. 위치는 새 기능 spec `rd-workflow-workspace/specs/base/`, 기존 코드 변경 change spec `rd-workflow-workspace/specs/changes/`, plan `rd-workflow-workspace/plans/`입니다.

## 토큰 효율 규칙

- 이미 읽었거나 skill·memory에 있는 정보는 다시 읽지 않는다.
- 근거 없는 추측성 탐색·도구 호출을 하지 않는다.
- 독립적인 도구 호출은 병렬로 실행한다.
- 사용자가 방금 말한 내용을 반복하지 않는다.

## 세션 한계 대응

컨텍스트가 커지면 `/compact`를 시도하고, 그래도 한계에 가까우면 **묻기 전에 `CURRENT_TASK.md`에 현재 상태를 저장**한 뒤 사용자에게 보고한다.

## 커밋 메시지

한국어 Conventional Commits(`type: 요약`) 형식을 쓰고, 파일 나열보다 무엇이 왜 바뀌었는지를 우선 적습니다.
