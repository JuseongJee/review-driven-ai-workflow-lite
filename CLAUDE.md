# Claude Project Rules

기본 인터페이스는 `짧은 자연어 요청`입니다 (`"future request에 기록해줘"`, `"이 요구사항으로 request-to-reviewed-plan skill로 진행해줘"`, `"small-task로 보고 바로 구현해줘"`). 프롬프트 파일은 기본 입력 방식이 아니라 예문·보정·수동 복구용입니다.

## 언어

한국어로 대화합니다. 코드 주석·식별자·문체는 기존 프로젝트 컨벤션을 따릅니다.

## 우선 원칙

1. 규칙·제약은 `PROJECT_CONTEXT.md`를 먼저 읽습니다.
2. 작업은 `REQUEST.md`·`CURRENT_TASK.md`에 적힌 범위 안에서만 합니다.
3. 범위 밖이지만 가치 있는 항목은 `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`에 기록합니다.
4. 큰 작업과 기존 코드베이스의 중간 이상 변경은 reviewed spec/plan 없이 바로 구현하지 않습니다 (기준: `rd-workflow/docs/flows/WORKFLOW.md`).
5. 사용자가 명시적으로 small-task로 지정한 작업만 바로 구현합니다. AI가 스스로 small로 판단하지 않습니다.
6. 구현 후에는 검증을 실행합니다 (절대 규칙 참조).

## Intake 규칙

새 작업(구현·작성·수정·생성 등 실행 가능한 작업) 요청이 오면 FR에 등록하고(`/fr add`와 동일 절차 — `FUTURE_REQUESTS.md` 인덱스 + `items/` 상세 파일), "FR 등록: **{title}** — {summary}. 다음 단계를 지정해주세요."를 출력한 뒤 지시를 기다립니다. Source FR은 그 FR을 현재 작업으로 승격해 REQUEST.md를 쓸 때 채웁니다.

진행 중(`CURRENT_TASK.md` Status ≠ `대기 중`)에 들어온 독립 요청은 등록만 하고 현재 작업을 중단하지 않습니다 — "FR 등록: **{title}**. 현재 작업 완료 후 진행합니다." 알림 후 복귀합니다.

등록 제외: `/fr add` 직접 호출(FR skill이 처리) / 단순 질문·확인, 워크플로 지시, 메타 대화 / 이미 등록된 요청의 후속 대화(clarification·수정·재시도).

**인프라 결함 라우팅**: rd-workflow 인프라 자체(산출물 문서·`rd-workflow/scripts/`·`rd-workflow/claude_skills/`)의 결함은 소비 프로젝트 FR로 등록하지 않고 `rd-workflow-workspace/reports/workflow-defects/`에 보고 파일만 만듭니다 (판별 기준·경계·형식: `rd-workflow/docs/guides/workflow-defect-reporting.md`).

## Workflow 우선순위

새 기능·큰 작업·기존 코드베이스의 중간 이상 변경에서는 Superpowers workflow부터 호출합니다 (필수 사용은 절대 규칙 참조). small-task로 지정된 작업, 초기 설정, 단순 문서 작업은 일반 방식으로 바로 처리해도 됩니다.

단계: 설계 `brainstorming` → 계획 `writing-plans` → 구현 `subagent-driven-development`(기본) 또는 `executing-plans`. worktree 가능 시 `using-git-worktrees` — worktree branch가 곧 fr branch로 동작하고(lifecycle 정책 결정 2) worktree path는 metadata가 authoritative입니다.

실행 모드 규칙:

- **절대 묻지 않는다.** upstream skill이 "Which approach?"를 요구해도 이 규칙이 우선하며, 기본값 `subagent-driven-development`로 바로 시작한다.
- **확인 생략**: 확정된 사안의 재확인, worktree 사용 동의, 설계·스펙 승인 대기, 과정상 체크포인트 응답 대기를 모두 생략하고 진행 보고만 남긴다. 생략 대상은 skill 내부의 확인 질문·응답 대기이며, 필수 review 수행 자체와 manual 모드의 단계 진입 지시 대기는 생략하지 않는다.
- **생략 금지**: merge·폐기·데이터 삭제·외부 발행 등 파괴적·비가역 결정, 블로커(정보 부족·반복 실패·진행 불능), 요구사항이 바뀌는 범위 변경, 제품 방향은 반드시 묻는다.
- 순차 의존성이 있으면 순차 dispatch한다. plan이 phase(파일 비중첩 task 그룹)를 표현하면 phase 내 task를 병렬 dispatch한다 (`rd-workflow/docs/guides/plan-parallel-phases.md`).
- inline(`executing-plans`)은 Task 1개 + 수정 파일 3개 이하, 또는 Task 2개 + 동일 경로 파일 1개만 수정일 때만 고른다 (검증 전용 Task도 센다). 사용자가 방식을 지정하면 그쪽을 따른다.
- subagent dispatch prompt에 `rd-workflow/docs/guides/subagent-git-safety.md`의 git 안전 문구를 포함한다 (공유 워킹트리 브랜치 전환 금지).

실행 모드 체계: `manual`(기본 — 단계마다 사용자 확인) / `semi-auto`(착수 지시 후 중대한 변경 시에만 묻고 자율 진행, 중단 조건은 `rd-workflow/docs/flows/AUTONOMY.md`, Intake 규칙 유지) / autopilot(`/autopilot` 명시 호출 전용 skill). 기본값은 `rd-workflow/config/workflow.json`의 `default_execution_mode`(`manual`|`semi-auto`, 부재·비허용 값 → `manual`)이고 세션 지시가 우선합니다.

## 핵심 절차

- **큰 작업**: `FR 등록 → REQUEST 작성 → REQUEST review → spec/change spec → plan → spec/plan review → 구현 → 검증 → final diff review → REQUEST 아카이브`
- **작은 작업**: `FR 등록 → REQUEST 정리 → 구현 → 검증 → 필요 시 final diff review → REQUEST 아카이브` (main 직접 commit 가능, `RD_LIFECYCLE_BYPASS_REASON=small-task` 명시)

### REQUEST 아카이브

- `REQUEST.md`를 `rd-workflow-workspace/backlog/request-archive/YYYY-MM-DD-HHMM-${SHORT_TITLE}.md`로 복사한 뒤 초기 템플릿 상태로 비웁니다.
- `Source FR`이 `-`가 아니면 그 FR status를 `done`으로 바꾸고 `FUTURE_REQUESTS.md` 인덱스에서 삭제합니다.
- `PROJECT_CONTEXT.md`의 `auto_completion_report: true`면 자동으로, 아니면 "작업 요약 report를 남길까요?" 질문 후 `rd-workflow-workspace/reports/completions/YYYY-MM-DD-HHMM-작업명.md`에 report를 씁니다.
- **완전 마감 후 `/clear` 안내 (필수)**: 아카이브 완료 + 산출물 손실 없음 확인(remote-mode는 push까지, local-only는 commit·merge까지) 후 마지막 응답에 `/clear` 가능 여부를 반드시 한 줄 명시합니다. 사용자가 추가 FR 등록 의사를 보이면 등록을 먼저 처리한 뒤 안내합니다.
- **큰 작업 lifecycle**: ① fr branch에서 archive content commit(REQUEST.md 비우기, archive 파일 생성, FR done 처리, completion report) — `CURRENT_TASK.md` 미러는 `archive.sh`가 baseline으로 되돌리므로 사람이 하지 않습니다. ② 기본 브랜치로 switch 후 `bash rd-workflow/scripts/lifecycle/archive.sh` 호출 (merge + tag + push + branch/worktree 정리 일괄).

## 절대 규칙 (모든 skill에 공통 적용)

- **구현 완료 후 반드시 `/final-diff-review`를 거친다.** 건너뛰고 merge하거나 작업을 종료하지 않는다.
- **Superpowers가 사용 가능하면 반드시 사용한다.** 불가능할 때만 직접 산출물을 작성한다.
- **검증**: 구현 후 `bash rd-workflow/scripts/{test,lint,typecheck,build}.sh`를 실행한다(프로젝트에 맞게 교체). typecheck는 정적 타입·컴파일 검사, build는 전체 빌드이며 build 실패는 검증 실패다. 교체 전(`TEMPLATE_STUB` 마커 존재)에는 **설계상 exit 1을 반환한다** — plan의 검증 Expected를 exit 0으로 쓰지 말고, 교체 후 기대값이나 프로젝트가 정의한 실질 검증 명령 기준으로 쓴다.
- **워크플로 인프라 검증**: rd-workflow 인프라(lifecycle·review 스크립트)를 수정했다면 `bash rd-workflow/scripts/self_test.sh`로 검증한다. **인자 없이 부르면 `smoke`다**(`full`은 명시해야 한다) — 변경 파일과 참조 관계로 연결된 스텝만 돌고, 어떤 스텝과도 연결되지 않으면 자동으로 full로 되돌아간다. `RD_SELFTEST_SMOKE_DRYRUN=1`은 미리보기이므로 검증 결과가 아니다. **`CURRENT_TASK.md`·`REQUEST.md`가 dirty하면 감축이 거의 사라지므로** 진행 상태를 먼저 커밋하고 돌린다. `full`은 전수 실행이며 **아카이브 시 `archive.sh`가 우회 없이 강제**하므로 평소에 손으로 돌릴 필요는 없다 — `--force-dirty`로도 이 게이트는 넘지 못하니(증명 대상=워킹트리, 발행 대상=HEAD) 무관한 변경은 commit이나 stash 후 아카이브한다.

## Review 규칙

- 큰 작업과 중간 이상 변경에서 `REQUEST review`, `spec/plan review`, `final diff review`를 건너뛰지 않습니다.
- `prepare_review_pipeline.sh`로 세션을 만들고 `run_review_turn.sh`로 턴을 잇습니다. 최신 Reviewer 턴이 `이의 없음`을 명시할 때까지 이어가고, 사람 결정이 필요하거나 총 20턴에 도달하면 `awaiting-user`로 바꾸고 멈춥니다.
- **autopilot·반자율 모드에서는** `rd-workflow/docs/flows/AUTONOMY.md`의 자율 실행 규칙이 이 섹션보다 우선합니다 (예: 턴 한도 50턴). 절대 규칙과 일반 모드의 20턴 규칙은 변하지 않습니다.
- **REQUEST review 축약**: spec이 사용자 승인 완료 + REQUEST.md가 그 spec을 참조(승인된 결정의 백필)이면 1턴 확인으로 축약합니다. 1턴에서 이의가 나오면 일반 수렴 규칙으로 복귀합니다.
- 세션 종료 시 `rd-workflow-workspace/reports/reviews/`에 주요 쟁점과 결론을 요약한 report를 씁니다.
- plan의 `mechanical` task는 task별 리뷰를 생략(final diff에 위임)하고, spec/plan review는 같은 phase task의 파일 비중첩을 필수 확인합니다 (`rd-workflow/docs/guides/plan-parallel-phases.md`).

## Always Read

- 작업 시작 시: `REQUEST.md`, `PROJECT_CONTEXT.md`, `CURRENT_TASK.md`, `rd-workflow/claude_skills/*/rules.md`(설치된 extension이 있으면)
- 필요할 때만: `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`(FR 기록·조회·autopilot) / `rd-workflow/docs/flows/WORKFLOW.md`(작업 분기) / `rd-workflow/docs/AI_DOC_MAP.md`(문서 위치) / `rd-workflow/docs/prompts/README.md`(프롬프트 파일)

## Task Tracking

Status·Short Title 변경은 `rd task` CLI를 경유합니다 (기계 판정 권위: `rd-workflow-workspace/.lifecycle/task-state` — `CURRENT_TASK.md`의 해당 필드는 표시용 미러).

Status 허용값 (`rd task` CLI 전이표가 이 값으로 판정하며, hook이 강제하지 않으므로 사람과 AI가 지킵니다): `대기 중` / `REQUEST review 대기` / `spec/plan 작성 중` / `spec/plan review 대기` / `구현 중` / `검증 중` / `diff review 대기` / `완료`.

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
