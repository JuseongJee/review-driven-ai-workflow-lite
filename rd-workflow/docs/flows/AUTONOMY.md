# Autonomy Rules (자율 실행 공용 규칙)

autopilot 모드와 반자율(semi-auto) 모드가 공통으로 따르는 자율 실행 규칙의 단일 출처다. 두 모드는 이 문서의 "절대 멈추지 않는다"·"자율 판단 기준"·"중단 조건"을 동일하게 적용한다. 모드별 특화 게이트(autopilot의 작업·실행 모드 선택 등)는 각 모드 문서에 별도로 둔다.

**적용 대상:**
- autopilot 모드: `rd-workflow/claude_skills/autopilot/SKILL.md`가 이 문서를 참조한다. autopilot 특화 예외 게이트(§1 작업 선택·실행 모드 선택)는 SKILL.md에 있으며 이 문서보다 우선한다.
- 반자율 모드: CLAUDE.md "실행 모드" 규칙이 이 문서를 참조한다. 착수 지시 이후부터 적용된다 (Intake 규칙은 유지 — 새 요청은 FR 등록 후 착수 지시 대기).
- 절대 규칙과 일반 모드의 20턴 review 규칙은 이 문서로 바뀌지 않는다.

## 절대 멈추지 않는다

착수 이후 아래 상황에서 사용자 응답을 기다리지 않는다:

- "다음 단계는...", "다음: /skill-name" 안내 후 사용자 응답을 기다리지 않는다 — 바로 실행한다
- "어떻게 하시겠습니까?", "어떤 방식을 선호하시나요?" 묻지 않는다 — 추천안을 자율 선택한다
- review 완료 후 "마무리를 승인해주세요" 묻지 않는다 — Reviewer "이의 없음"이면 바로 다음 단계로 간다
- final-diff-review 완료 후 "merge할까요?" 묻지 않는다 — 추천 옵션을 자동 선택한다
- brainstorming의 interactive gate를 모두 자율 통과한다:
  - 요구사항 탐색 질문 → 세션 컨텍스트(REQUEST.md, PROJECT_CONTEXT.md, CURRENT_TASK.md, 대화 이력)에서 답변하고 진행
  - 설계 대안 제시 + 승인 요청 → 추천안(recommended)을 선택, 없으면 REQUEST의 제약/AC와 가장 부합하는 옵션 선택, 우열이 서지 않으면 가장 단순한 옵션 선택 (단, PROJECT_CONTEXT.md의 필수 제약을 위반하는 옵션은 제외)
  - 추가 확인 질문 → 기존 컨텍스트로 판단, 판단 불가 시에만 멈춤 (판단 근거를 완료 보고서 "주요 결정" 테이블에 기록)
  - 모든 옵션이 필수 제약을 위반하거나 판단 근거가 전혀 없으면 멈추고 사용자에게 보고
- writing-plans의 "execution choice" 질문을 따르지 않는다 — CLAUDE.md 실행 모드 규칙에 따라 자동 선택한다

## 자율 판단 기준

- 2-3개 선택지가 있으면 추천안(recommended)을 선택한다
- 추천이 없으면 가장 단순한 옵션을 선택한다
- 판단 근거를 완료 보고서의 "주요 결정" 테이블에 기록한다

## 모드 결정과 review 실행

**기본 실행 모드 결정** (반자율 opt-in):
- 세션 시작 또는 작업 착수를 판단하는 시점에, agent는 `rd-workflow/config/workflow.json`의 `default_execution_mode`를 읽는다.
- 허용 값은 `manual` | `semi-auto`. 파일 부재·키 부재·비허용 값이면 `manual`로 간주하고 경고 한 줄을 출력한다.
- 세션 지시("이번엔 수동으로" / "반자율로 진행")가 config 값보다 우선한다.
- 이 결정은 Intake 이후 착수 지시를 받은 작업에만 적용된다 (Intake 규칙은 모드와 무관하게 유지된다).

**review 턴 실행** (autopilot·반자율 공통):
- 기존 스크립트를 변경하지 않고 아래처럼 실행한다:
  ```bash
  REVIEW_TURN_LIMIT=50 bash rd-workflow/scripts/prepare_review_pipeline.sh <kind> [args...]
  RD_AUTOPILOT=1 bash rd-workflow/scripts/run_review_turn.sh <session-path>
  ```
- `REVIEW_TURN_LIMIT=50`: 자율 모드의 review 턴 한도를 20턴이 아닌 50턴으로 올린다.
- `RD_AUTOPILOT=1`: reviewer 입력 앞에 동일 fr의 Attempt History를 주입한다.
- 수동(manual) 모드에서는 두 변수를 붙이지 않는다 (기존 20턴·비주입).

## 중단 조건 (= "중대한 변경 사항"의 객관 정의)

아래 중 하나라도 발생하면 자율 진행을 멈추고 `awaiting-user`로 전환한 뒤 사유를 보고한다:

1. review 50턴 도달 (자율 실행 모드에서는 20턴이 아닌 50턴까지 허용)
2. 디버깅 3회 실패
3. 사람의 우선순위 결정이 반드시 필요한 경우 (기술적 판단이 아닌 비즈니스 판단 — REQUEST/FR의 전제가 깨지는 요구사항·범위 변화 포함)
4. 세션 한계 도달
5. brainstorming에서 모든 옵션이 필수 제약을 위반하거나 판단 근거가 전혀 없는 경우
6. **파괴적·비가역 작업** — 데이터 삭제, 외부 배포·공개 릴리즈 발행, 권한/계정 변경 등은 자율 진행하지 않고 멈춘다. **유일한 예외**: 현재 FR의 정규 archive lifecycle(`archive.sh`)에 진입한 뒤 수행되는 merge·tag·push — 이는 review 게이트가 종결된 승인된 파이프라인의 일부다. lifecycle script 밖의 push·배포·릴리즈·삭제는 착수 지시가 있어도 항상 중단 대상이다.

## 무인(headless) 모드 outcome 매핑

무인 진입(autopilot SKILL.md "무인 진입" 섹션)에서는 위 중단조건에 도달해도 사람을 기다릴 수 없다. 따라서 `awaiting-user` 로 멈춰 대기하는 대신, outcome 토큰 `blocked:<reason>` 을 `$RD_AUTOPILOT_OUTCOME_FILE` 에 기록하고 종료한다(중단조건 도달 시 skill 은 해당 FR status 를 `blocked` 로 기록하고 `CURRENT_TASK.md` 를 `대기 중`/Short Title `-` 로 reset 한다 — 보존 상태는 FR 의 blocked 항목이 든다. 상세는 autopilot SKILL.md "중단조건 → blocked 매핑"). 정상 완주는 `completed`, 세션 한계는 `resume`, 큐 빔은 `queue-empty` 다. wrapper `rd-workflow/scripts/autopilot_headless.sh` 가 이를 exit code(0/10/20/30/40)로 매핑한다. exit code 해석은 front-end(ralph/batch) 소관이다.
