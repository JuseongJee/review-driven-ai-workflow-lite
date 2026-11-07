# Autonomy Rules (자율 실행 공용 규칙)

autopilot 모드와 반자율(semi-auto) 모드가 공통으로 따르는 자율 실행 규칙의 단일 출처다. 두 모드는 이 문서의 "절대 멈추지 않는다"·"자율 판단 기준"·"중단 조건"을 동일하게 적용한다. 모드별 특화 게이트(autopilot의 작업·실행 모드 선택 등)는 각 모드 문서에 별도로 둔다.

**적용 대상:**
- autopilot 모드: `rd-workflow/claude_skills/autopilot/SKILL.md`가 이 문서를 참조한다. autopilot 특화 예외 게이트(§1 작업 선택·실행 모드 선택)는 SKILL.md에 있으며 이 문서보다 우선한다.
- 반자율 모드: `.claude/rules/rd-workflow/core.md` "실행 모드" 규칙이 이 문서를 참조한다. 착수 지시 이후부터 적용된다 (Intake 규칙은 유지 — 새 요청은 등급 판정 후 `light`·`standard` 는 즉시 진행, `full` 만 FR 등록 후 착수 지시 대기).
- 절대 규칙과 일반 모드의 20턴 review 규칙은 이 문서로 바뀌지 않는다.

## 절대 멈추지 않는다

착수 이후 아래 상황에서 사용자 응답을 기다리지 않는다:

- "다음 단계는...", "다음: /skill-name" 안내 후 사용자 응답을 기다리지 않는다 — 바로 실행한다
- "어떻게 하시겠습니까?", "어떤 방식을 선호하시나요?" 묻지 않는다 — 추천안을 자율 선택한다
- review 완료 후 "마무리를 승인해주세요" 묻지 않는다 — Reviewer "이의 없음"이면 바로 다음 단계로 간다. 이것은 리뷰 종결 후 **다음 단계 진입**을 묻지 않는다는 뜻이지 발행을 묻지 않는다는 뜻이 아니다 (발행은 아래 "종결 마커(seal)와 발행 승인" 절이 규정한다).
- final-diff-review(`standard`·`full`) 이후의 merge·tag·push 는 **자동 선택 대상이 아니다** — 발행 직전 1회 사용자 승인을 받는다. 아래 "종결 마커(seal)와 발행 승인" 절을 따른다.
- brainstorming의 interactive gate를 모두 자율 통과한다:
  - 요구사항 탐색 질문 → 세션 컨텍스트(REQUEST.md, PROJECT_CONTEXT.md, CURRENT_TASK.md, 대화 이력)에서 답변하고 진행
  - 설계 대안 제시 + 승인 요청 → 추천안(recommended)을 선택, 없으면 REQUEST의 제약/AC와 가장 부합하는 옵션 선택, 우열이 서지 않으면 가장 단순한 옵션 선택 (단, PROJECT_CONTEXT.md의 필수 제약을 위반하는 옵션은 제외)
  - 추가 확인 질문 → 기존 컨텍스트로 판단, 판단 불가 시에만 멈춤 (판단 근거를 완료 보고서 "주요 결정" 테이블에 기록)
  - 모든 옵션이 필수 제약을 위반하거나 판단 근거가 전혀 없으면 멈추고 사용자에게 보고
- writing-plans의 "execution choice" 질문을 따르지 않는다 — `.claude/rules/rd-workflow/core.md` 실행 모드 규칙에 따라 자동 선택한다

## 자율 판단 기준

- 2-3개 선택지가 있으면 추천안(recommended)을 선택한다
- 추천이 없으면 가장 단순한 옵션을 선택한다
- 판단 근거를 완료 보고서의 "주요 결정" 테이블에 기록한다

## 모드 결정과 review 실행

**기본 실행 모드 결정**:

세션 시작 또는 작업 착수를 판단하는 시점에, agent는 `rd-workflow/config/workflow.json`의 `default_execution_mode`를 판정한다. 허용 값은 `manual` | `semi-auto` 이며, 어떤 스크립트도 이 키를 읽지 않는다 — 이 절이 정본이고 agent가 따르는 규칙이다.

**판정 표 — 이 표가 권위다.**

| # | 상태 | 판정 | 시작 보고의 출처 | 경고 |
|---|---|---|---|---|
| ① | 파일 부재 — **부재를 정상적으로 확인한 경우만** | `semi-auto` | `파일 부재 기본값` | 없음 |
| ② | 유효 JSON object 인데 키 부재 | `semi-auto` | `키 부재 기본값` | 없음 |
| ③ | 값이 `manual` 또는 `semi-auto` | 그 값 | `workflow.json` | 없음 |
| ④ | 경로가 regular file 인데 **읽기 실패**(권한 없음·I/O 오류) | `manual` | `판정 불가 fallback` | 있음 |
| ⑤ | 파싱 실패 · 최상위 non-object · 비허용 값 · **`default_execution_mode` 키 중복** | `manual` | `판정 불가 fallback` | 있음 |
| ⑥ | **경로가 regular file 이 아님** — 디렉터리 · dangling symlink · FIFO · socket · 그 밖의 특수 파일 | `manual` | `판정 불가 fallback` | 있음 |
| ⑦ | **경로의 존재·종류를 확인하지 못함** — 상위 디렉터리 권한 없음 · I/O 오류 등 | `manual` | `판정 불가 fallback` | 있음 |

- 위 표의 **「경고」 칸이 권위다.** 정상 경로(선호 미표현·명시 값)는 경고를 내지 않고, 판정 불가 행에서만 경고가 난다. 어느 행이 어느 쪽인지는 표의 「판정」·「경고」 칸으로 읽는다. **라벨 범위나 갈래 수를 산문에 열거하지 않는다** — 행이 늘 때마다 어긋나기 때문이다.
- 이 절의 판정 규칙은 원문자(`①…`)로, 변경 spec 의 시나리오는 동그라미 문자(`ⓐ…`)로 표기한다. 둘은 1:1 대응이 아니므로 섞지 않는다.

**판정 순서 — 이 순서가 계약이다.**

1. **경로의 존재와 종류를 먼저 확인한다.** 확인 자체가 실패하면 판정 불가(⑦)다.
2. 정상적으로 「없음」을 확인했을 때만 파일 부재(①)다. **확인하지 못한 것을 부재로 취급하지 않는다** — 사용자의 `manual` 설정이 있을 수 있는데 조용히 `semi-auto` 로 올라간다.
3. regular file 이 아니면 판정 불가(⑥)다. **내용을 열기 전에 판정한다** — FIFO 를 먼저 읽으면 열린 채 대기해 세션이 멈춘다. socket 도 마찬가지다.
4. regular file 임을 확인한 뒤에야 내용을 읽는다(③④⑤).

**symlink 계약**: regular file 을 가리키는 symlink 는 **따라가서 위 판정 표를 그대로 적용**한다. dangling symlink 와 regular file 이 아닌 대상을 가리키는 symlink 는 ⑥(판정 불가)다 — 「파일 부재」로 처리하지 않는다.

**키 중복**: 한 object 안에 `default_execution_mode` 가 두 번 이상 나오면 도구마다 마지막 값·첫 값으로 갈리므로 판정 불가다.

**분리 근거 — 다음 사람이 이것을 다시 한 덩어리로 합치지 않도록 남긴다.**

- **「선호 미표현」과 「판정 불가」를 나눈다.** 파일 부재·키 부재는 사용자가 아무 말도 하지 않은 상태이므로 프로젝트 기본값(`semi-auto`)을 적용하는 것이 맞다. 읽기 실패·파싱 실패·non-object·비허용 값·특수 경로·키 중복은 **읽을 수 없는 상태**이므로 안전한 쪽(`manual` + 경고)으로 떨어진다.
- **「파일 부재」와 「읽기 실패」를 나눈다.** 전자는 선호를 표현한 적이 없는 상태이고, 후자는 **표현했을 수도 있는데 확인하지 못한 상태**다. 후자를 부재로 합치면 `manual` 을 명시해 둔 프로젝트가 권한 문제 하나로 조용히 자율 모드가 된다. 존재·종류 확인 실패와 non-regular 경로를 부재로 합치지 않는 이유도 같다.

**판정 불가 경고의 최소 정보** — 아래 표의 모든 경우가 원인·경로·적용 모드·복구 방법을 담는다. 문구의 정확 일치는 요구하지 않는다.

| 경우 | 무엇이 잘못됐는지 | 경로 | 적용 모드 | 복구 방법 |
|---|---|---|---|---|
| 파싱 실패 | JSON 을 해석할 수 없음 | `rd-workflow/config/workflow.json` | `manual` 적용 | 파일 내용을 고치도록 — 허용 값이 `manual`·`semi-auto` 둘뿐임을 밝힌다 |
| 비허용 값 | 허용되지 않는 값 `<값>` | 〃 | 〃 | 〃 |
| 최상위 non-object | 최상위가 JSON object 가 아님 | 〃 | 〃 | 〃 |
| 키 중복 | `default_execution_mode` 가 여러 번 나타남 | 〃 | 〃 | 〃 |
| **regular file 아님** | 경로가 디렉터리 / dangling symlink / FIFO / socket 등 | 〃 | 〃 | **경로 종류를 확인하도록.** 내용을 고치라고 안내하지 않는다 — 아직 내용을 보지 못했다 |
| **존재·종류 확인 실패** | 경로 상태를 판정하지 못함(상위 디렉터리 권한 없음 / I/O 오류) | 〃 | 〃 | **상위 디렉터리 권한과 경로를 확인하도록.** 파일이 있는지조차 모르는 상태이므로 파일 자체에 대한 안내를 하지 않는다 |
| **읽기 실패** | 파일을 읽지 못함(권한 없음 / I/O 오류) | 〃 | 〃 | **권한을 확인하도록.** 내용을 고치라고 안내하지 않는다 — 아직 내용을 보지 못했으므로 그 안내는 사실과 어긋난다 |

- 세션 지시("이번엔 수동으로" / "반자율로 진행")가 config 값보다 **우선**한다. 이때 시작 보고의 출처는 `세션 지시` 다.
- 이 결정은 Intake 이후 착수 지시를 받은 작업에만 적용된다 (Intake 규칙은 모드와 무관하게 유지되며, 등급별 진입 — `light`·`standard` 즉시 진행, `full` 만 FR 대기 — 도 모드와 무관하게 같다).

**review 턴 실행** (autopilot 전용):
- 아래 두 환경변수는 **autopilot 모드에만 붙인다.** 기존 스크립트를 변경하지 않고 아래처럼 실행한다:
  ```bash
  REVIEW_TURN_LIMIT=50 bash rd-workflow/scripts/prepare_review_pipeline.sh <kind> [args...]
  RD_AUTOPILOT=1 bash rd-workflow/scripts/run_review_turn.sh <session-path>
  ```
- `REVIEW_TURN_LIMIT=50`: autopilot 의 review 턴 한도를 20턴이 아닌 50턴으로 올린다.
- `RD_AUTOPILOT=1`: reviewer 입력 앞에 동일 fr의 Attempt History를 주입한다. **동시에 self-review 차단 게이트를 자동 진행으로 바꾼다** — 독립 reviewer 가 없어 reviewer 가 `claude` 로 fallback 될 때 일반 모드는 차단하는데, 이 플래그가 그 차단을 없앤다. 주입만 하는 플래그가 아니다.
- **`manual`·`semi-auto` 모두 두 변수를 붙이지 않는다.** 두 모드 모두 review 턴 한도는 20턴이고 `self_review_policy=block` 이 그대로 적용된다. semi-auto 가 self-review 를 자동 통과하는 경로는 없다.

**3모드 매트릭스**

| 모드 | 턴 한도 | `RD_AUTOPILOT` | self-review |
|---|---|---|---|
| `manual` | 20 | 미설정 | `block`(차단) |
| `semi-auto` | 20 | **미설정** | `block`(차단) |
| autopilot | 50 | `1` | 자동 진행 |

**종결 마커(seal)와 발행 승인**:
- spec/plan 구간의 Status 전이(`REQUEST review 대기` → `spec/plan 작성 중` → `spec/plan review 대기` → `구현 대기` → `구현 중`)는 `request-to-reviewed-plan`·`implement-reviewed-plan` SKILL.md 의 절차대로 **묻지 않고 진행한다.** `아카이브 보류` 전이와 마찬가지로 되돌릴 수 있는 로컬 작업이다. 구현 착수 때 spec/plan review 종결 증거(`## Notes` 의 종결 기록과 현재 spec/plan 해시 비교)가 무효이면 그 skill 이 구현 없이 중단하고 재리뷰를 안내한다. 기록만 없는 기존 작업에 한해 사용자가 "리뷰 이후 spec/plan 이 바뀌지 않았다" 를 확인하면 진행할 수 있으며, 이 확인은 사람만 내릴 수 있는 판단이므로 자율 모드가 스스로 하지 않는다(중단 조건 3). 리뷰가 없거나 수렴하지 않았으면 확인으로 대신하지 않고 재리뷰로 보낸다.
- final diff review 가 `이의 없음` 으로 종결되면 `rd review seal <세션 경로>` → `rd task set-status "아카이브 보류"` → archive 기록 커밋(seal 파일 포함) 까지는 **묻지 않고 진행한다.** 이 셋은 되돌릴 수 있는 로컬 작업이다.
- **발행 승인 주체는 `rd-workflow/config/workflow.json` 의 `publish_approval` 이 정한다.** 값은 `caller`(기본 — 키·파일 없음 포함) 또는 `user` 이고, 허용 밖 값·파싱 실패는 `user` 로 보고 경고한다. 승인(허가) 전에는 `archive.sh` 를 호출하지 않는다. 허가 이후의 merge·tag·push 만 중단 조건 6의 예외 ①(정규 archive lifecycle)에 포함된다.
  - **호출 세션 허가** — `caller` 이고 promote 가 호출 세션을 기록한 작업(색인 `caller-id` 있음, `launch=ok`): 기록 커밋 뒤 `bash rd-workflow/scripts/rd publish request` 로 발행 요청 큐에 넣고, `rd publish wait` 를 백그라운드로 실행해 허가를 기다린다. 허가되면 `rd publish run` 으로 발행한다(`archive.sh` 를 직접 부르지 않는다). 사용자에게 묻지 않는다. 결과가 「부분 완료」 면 같은 `rd publish run` 으로 복구하고, 「발행 중」 으로 멈췄으면 `rd publish recover` 로 판정한다. 상태는 `rd publish status` 로 본다.
    - archive 우회(`--allow-gitlink-drop`, `--force-skip-review-check`)가 필요하면 `rd publish request [--allow-gitlink-drop <사유>] [--force-skip-review-check <사유>] --basis <근거>` 로 옵션과 사유를 붙인다. 큐는 `--allow-status-mismatch` 를 받지 않는다.
    - 우회는 사람만 내릴 수 있는 판단이다(중단 조건 3). 자율 모드는 스스로 우회 옵션을 넣지 않고 멈춰 막힌 사유와 선택지를 보고한다.
    - 사람이 답하면 AI 가 그 말을 `--basis` 로 옮긴다. 권장 형식은 `user-override` 근거 줄과 같다: `<날짜> <결정한 사람> — "<그 사람이 한 말>"`. 사용자가 작업 세션에 이미 지시한 결정이면 다시 묻지 않고 그 지시를 옮긴다.
    - `archive.sh` 는 사유를 `<사유> (근거: <근거>)` 로 합친 값으로 받아 audit 에 남긴다.
    - 호출 세션은 `rd publish watch`·`next` 출력에 우회가 보이면 허가 사실과 함께 옵션·사유·근거를 사용자에게 알린다. 사용자는 인용된 근거로 자기 결정인지 확인한다.
  - **사용자 승인** — `user` 이거나 호출 세션이 없는 작업(직접 띄운 세션, 자동 기동 실패·미지원): `rd publish request` 가 종료 코드 10 으로 이 경로를 알린다. **`archive.sh` 호출 직전에 사용자에게 1회 묻고** 승인 뒤 `archive.sh` 를 실행한다(우회가 필요하면 같은 옵션과 `<사유> (근거: <근거>)` 로 합친 사유를 붙인다). 호출 세션이 사라져 요청이 「사용자 승인 대상」 이 되면(종료 코드 11) 사용자에게 묻고, 승인 뒤 `rd publish approve` → `rd publish run` 으로 진행한다.
  - **호출 세션의 몫** — 작업을 띄운 호출 세션은 `rd publish watch` 를 백그라운드로 두고, 끝나면 출력된 사건을 처리한 뒤 다시 띄운다. 요청이 오면 `rd publish next` 로 가장 오래된 요청 하나만 허가한다. 결과·부분 완료·사용자 승인 대상은 사용자에게 알리고, 자동 해소 밖 충돌·발행 실패는 사용자에게 올린다. 요청·허가·결과는 큐 파일로만 주고받고 어느 세션의 입력창에도 글을 넣지 않는다.
- 사용자 승인 질문에는 실제 효과를 드러낸다. 표시값의 의미는 현행 `archive.sh` 와 일치시킨다 — 지금 확정할 수 있는 것만 확정값으로 적고, 확정할 수 없는 것은 그렇게 적는다.

| 표시 항목 | 확정성 | 비고 |
|---|---|---|
| 변경 요약 | **PR 본문에서 옮김** | 무엇을·왜(`## Summary`)와 되돌리기와 영향 범위(`## 되돌리기와 영향 범위`)를 각 한 줄로, PR 본문 위치(`## PR 본문` 절을 담은 가장 최근 Author 턴 경로)와 함께 적는다. 새로 쓰지 않는다 — PR 본문과 어긋난다. |
| merge 대상 | **확정값 — branch 모드별** | 아래 모드 표 |
| push 대상 | **확정값 — remote 모드별** | 아래 모드 표 |
| tag | **이름 규칙과 예상값**(정확한 ref 아님) | 실제 이름은 merge·metadata cleanup 커밋 뒤 현재 분 시각과 충돌 회피 결과로 정해진다. **정확한 ref 를 약속하지 않는다.** |
| 기본 브랜치 미push 커밋 수 | **확정값 — `archive.sh` 호출 전 기준** | archive 가 새로 만들 merge·cleanup 커밋은 포함하지 않는다. 「이 발행에 얹혀 함께 올라갈, 이미 존재하는 커밋이 몇 개인가」이며, 이 정의를 질문 문구에 밝힌다. |

**모드별 표시값** — 두 축(branch 모드 × remote 모드)이 독립이므로 각각 표시한다.

| 축 | 값 | merge / push 표시 |
|---|---|---|
| branch `fr` | fr 브랜치 있음 | `merge: <fr 브랜치> → <기본 브랜치>` |
| branch `no-fr` | `fr-branch` 가 canonical `null` | **`merge 없음`** — 작업 커밋이 이미 기본 브랜치 위에 있다 |
| remote `remote` | 원격 있음 | `push: origin → refs/heads/<기본 브랜치>` + tag push |
| remote `local-only` | 원격 없음 또는 `--no-remote` | **`push 없음`** |

`local-only` 에서는 「기본 브랜치 미push 커밋 수」도 **`해당 없음`** 으로 표시한다 — 발행할 원격이 없으므로 그 수가 의미를 갖지 않는다.

- 질문 끝에 「승인 전에 변경을 퀴즈나 그림 설명으로 확인할 수 있습니다」 한 줄을 둔다. 기본은 바로 승인이고, 확인은 사용자가 원할 때만 한다.
- `아카이브 보류` 는 「리뷰 종결·발행 대기」이며 **완료가 아니다.** 사용자가 승인을 보류하거나 큐 허가를 기다리면 이 상태와 기록 커밋이 그대로 유지되어 나중에 재개할 수 있고, 이 상태로 세션이 끝나면 완료 보고에 "발행 미완" 으로 남긴다.
- seal 이 「리뷰 종결 후 보호 경로가 변경되었습니다」로 거부되면 그것은 실패가 아니라 정상 판정이다. 같은 세션에서 재리뷰를 이어 종결시킨 뒤 seal 을 다시 실행한다 (마커는 4검사를 모두 통과할 때만 교체되고, 실패하면 기존 마커가 보존된다).
- seal 은 세션의 `reviewer_runs.tsv` 실행 기록을 대조한다. 기록이 없거나(`run-missing`) 마지막 리뷰어 턴이 이의 없이 끝났다는 기록이 없으면(`reason-unproven`) 거부한다. 거부되면 `run_review_turn.sh` 로 리뷰어 턴을 다시 돌린다. 사람이 남은 이의를 덮고 종결하기로 정한 경우에만 SESSION 의 `## Closure Reason` 에 `user-override` 를 적는다.
  - 이 결정은 중단 조건 3(사람만 내릴 수 있는 판단)이다. 자율 모드는 스스로 `user-override` 를 정하지 않고 `awaiting-user` 로 멈춰 남은 이의와 선택지를 보고한다.
  - 사람이 답하면(예: autopilot 이 멈춘 뒤 사람이 「덮고 종결해」 라고 답함) AI 가 그 말을 `근거:` 줄로 옮겨 적고 seal 한다. 이 경로는 막히지 않는다.
  - seal 은 근거 줄이 없으면 거부한다(`override-basis-missing`, `FILE_BASED_REVIEW_PIPELINE.md` 「종결 사유 (Closure Reason)」 절).

**legacy 세션 — `--legacy-unverified` 는 자율 진행 대상이 아니다**:
- **legacy 의 정의는 기계적이다.** 세션 `SESSION.md` 의 `## Branch Context` 에 `review-head-oid` 가 **없는** 세션이 legacy 다. 사람도 AI 도 "오래된 세션 같다" 로 판단하지 않는다. 이런 세션은 리뷰 당시 커밋이 어디에도 기록되어 있지 않아 일반 `rd review seal` 이 검사 3에서 거부한다.
- 전환 경로는 `bash rd-workflow/scripts/rd review seal --legacy-unverified "<사유>" <세션 경로>` 하나뿐이다. **자율 모드는 이 플래그를 스스로 붙이지 않는다** — 중단 조건 3(사람만 내릴 수 있는 판단)에 해당하므로 사유와 아래 트레이드오프를 보고하고 사용자 결정을 받는다.
- **무엇을 포기하는가:** 이 마커는 **리뷰 당시 트리를 증명하지 않는다.** 종결 이후 코드가 변경되었어도 발행을 막지 못한다. `verified=yes` 마커가 주는 "리뷰된 대상이 그대로 발행된다" 는 보장이 이 세션에 대해서만 사라진다.
- **남는 것:** 사유가 `rd-workflow-workspace/.lifecycle/review-skip-audit.log` 에 append 되고, `archive.sh` 와 `rd task status` **양쪽이 그 마커로 통과할 때마다 경고**를 낸다 — 나중에 다른 사람이 실행해도 차이를 알 수 있다.
- `review-head-oid` 가 **있는** 세션에 이 플래그를 쓰면 거부된다. 검증 가능한 세션을 무검증으로 낮추는 우회로는 없다.
- `--force-skip-review-check` 와 혼동하지 않는다 — 그쪽은 "리뷰를 아예 건너뜀", 이쪽은 "리뷰는 했으나 대상을 증명 못 함" 이다. 둘 다 자율 진행 대상이 아니다.

## 실행 모드와 skill 호출 권한

`disable-model-invocation` 은 **자율성 통제 축이 아니다.** 자율성은 `rd-workflow/config/workflow.json` 의 `default_execution_mode` 가 담당하고, 이 플래그는 **파괴적·고비용 행위에 사람 승인을 요구**하는 데만 쓴다. 두 축을 겹쳐 쓰면 설정과 동작이 어긋난다.

| skill 분류 | 대상 | `manual` | `semi-auto` | autopilot |
|---|---|---|---|---|
| 단계 전환 | `request-to-reviewed-plan` `planning-design-intake` `implement-reviewed-plan` `final-diff-review` `small-task-implement` `gap-check` | 모델 호출 가능하나 **사용자의 단계 진입 지시 없이 시작하지 않는다** | 자율 진입 | 자율 진입 |
| 기록·설정 | `fr` `review-config` | 자율 (`fr` 은 아래 서브커맨드 경계를 따른다) | 자율 (같음) | 자율 (같음) |
| 파괴적·고비용 | `comprehensive-audit` `tpl` (개발 저장소에서는 `ship` `publish` 포함) | 사람만 | 사람만 | 사람만 |

`fr` 서브커맨드 경계 — 모델이 사용자의 명시 요청 없이 스스로 호출한 경우 `list`·`pri`·`inspect`·`pull` 과 **로컬 전용 `add`** 만 수행한다. 자기호출 `add` 는 `fr_github` 가 활성이어도 `gh issue create` 로 넘어가지 않고 로컬 등록에서 멈추며, 발행이 필요하면 사용자에게 요청을 안내한다 — **외부 발행은 파괴적·비가역 행위이므로 backend 설정이 승인을 대신하지 않는다.** `push`(외부 저장소 Issue 발행)·`sync`(원격 label 변경·Issue close)·`do`(여러 FR 처리)·`archive`·`park`·`status` 는 사용자의 명시 요청을 요구한다. 플래그가 skill 단위여서 부분 개방이 불가하므로 이 경계는 문서 계약이며 harness 강제가 아니다.

`manual` 의 단계 진입 대기도 문서 계약이다. 2026-09-07 결정으로 harness 강제 대신 이 절과 각 skill 본문의 자기 점검 한 줄이 그 계약을 담당한다.

### 오해 이력 (2026-04-07)

`rd-workflow-workspace/handoffs/review_pipeline/20260407_051351_final-diff-review/turns/007_author.md:7` 은 이 플래그를 **"이 skill 이 내부에서 다른 모델을 호출하지 않는다는 의미이며 자연어 매칭 자체를 막지 않는다"** 로 해석해, 같은 세션 `turns/006_reviewer.md:9`(Medium) 과 `20260409_100035_final-diff-review/turns/002_reviewer.md`(High) 의 "자연어 진입 경로 dead-end" 지적을 종결시켰다. **이 해석은 사실과 다르다.** 실제 의미는 **"모델이 이 skill 을 Skill 도구로 호출할 수 없다"** 이며, 2026-09-07 세션의 거부 메시지(`cannot be used with Skill tool due to disable-model-invocation`)가 이를 직접 확인했다. 플래그를 새로 붙이거나 떼기 전에 위 축 분리를 먼저 확인한다.

## 중단 조건 (= "중대한 변경 사항"의 객관 정의)

아래 중 하나라도 발생하면 자율 진행을 멈추고 `awaiting-user`로 전환한 뒤 사유를 보고한다:

1. review 턴 한도 도달 — **50턴은 autopilot 기준**이다. `semi-auto` 는 manual 과 동일하게 20턴에서 `awaiting-user` 로 전환한다.
2. 디버깅 3회 실패
3. 사람의 우선순위 결정이 반드시 필요한 경우 (기술적 판단이 아닌 비즈니스 판단 — REQUEST/FR의 전제가 깨지는 요구사항·범위 변화 포함)
4. 세션 한계 도달
5. brainstorming에서 모든 옵션이 필수 제약을 위반하거나 판단 근거가 전혀 없는 경우
6. **파괴적·비가역 작업** — 데이터 삭제, 외부 배포·공개 릴리즈 발행, 권한/계정 변경 등은 자율 진행하지 않고 멈춘다. **예외 두 가지**: ① **사용자 승인 또는 호출 세션 허가 이후** 현재 FR의 정규 archive lifecycle(`archive.sh`, 큐 경유면 `rd publish run`)에서 수행되는 merge·tag·push — 「종결 마커(seal)와 발행 승인」 절의 승인·허가를 받은 뒤의 단계다. **사용자 승인 경로에서는 승인 자체를 이 조건의 일반 규칙대로 반드시 묻는다.** 무인(headless) 실행에서는 front-end(`/fr do --headless`, 엔진 `ralph_drain.sh`)를 띄울 때 사람이 고른 `RD_FINISH_POLICY` 가 그 실행의 발행 승인이며, wrapper 가 발행 요청 큐 없이 `archive.sh` 를 실행한다. ② `light` 등급 마감의 기본 브랜치 커밋 1개 직후 push — 원격 모드이고, 시작 보고 블록의 `push 예정` 필드에 `light` 마감 push 를 적었고, 커밋 전 재분류가 `light` 를 확정한 경우에 한한다(WORKFLOW.md 시작 계약·마감 상태 계약). 시작 계약 4항이 ahead 를 감지해 `push 예정` 을 보류로 적었으면 사용자의 명시 채택 없이는 이 push 도 하지 않고 "미push" 로 인계한다. 실패하면 push 를 재시도하지 않고 종료 보고에 "미push" 로 넘긴다. 그 밖의 lifecycle script 밖 push·배포·릴리즈·삭제는 착수 지시가 있어도 항상 중단 대상이다.

8. **FR 경과 시간 상한** — 무인(headless) 실행에만 적용한다. 기준은 `autopilot_headless.sh` 호출 1회에서 claude 세션이 도는 경과 시간이고(세션 종료 뒤 wrapper 의 발행 단계는 포함하지 않는다), 기본 상한은 240분이다. 상한은 환경변수 `RD_FR_WALL_MINUTES` > `loop-guard.json` 의 `wall_minutes` 키(분 단위 정수) > 기본값 순으로 정하며, `0` 은 상한 없음이다. 대화형 autopilot·반자율에는 적용하지 않는다. 무인에서는 `awaiting-user` 대신 outcome `blocked:time-cap` 을 기록한다. 발행 단계는 별도 상한을 가진다. 상한은 환경변수 `RD_PUBLISH_WALL_MINUTES` > `loop-guard.json` 의 `publish_wall_minutes` 키 > 기본 30분 순으로 정하며, 분 단위이고 소수를 허용한다. `0` 은 상한 없음이다. 유예는 `RD_FR_WALL_GRACE_SECONDS` 를 공유한다. 상한을 넘기면 발행 그룹에 TERM 을 보내고 유예 뒤 KILL 한다. 결과는 병합 전이면 `blocked:publish-failed`, 병합 후이면 `blocked:publish-incomplete`(이어붙이기)이다. KILL 뒤에도 프로세스가 남으면 `blocked:publish-unsafe` 이며 재실행하지 않는다. 발행 중 wrapper 가 INT·TERM·HUP 을 받으면 같은 회수·분류를 한 뒤 128+신호 번호로 끝난다. 발행 그룹 밖으로 스스로 빠져나간 후손(`setsid` 를 직접 부른 프로세스)은 회수 대상이 아니다.

## 무인(headless) 모드 outcome 매핑

무인 진입(autopilot SKILL.md "무인 진입" 섹션)에서는 위 중단조건에 도달해도 사람을 기다릴 수 없다. 따라서 `awaiting-user` 로 멈춰 대기하는 대신, outcome 토큰 `blocked:<reason>` 을 `$RD_AUTOPILOT_OUTCOME_FILE` 에 기록하고 종료한다(중단조건 도달 시 skill 은 해당 FR status 를 `blocked` 로 기록한다. fr 브랜치가 활성인 작업의 `CURRENT_TASK.md`·task-state 는 reset 하지 않고 보존하며, 재개 후보 제외는 FR 의 blocked 항목이 맡는다. 상세는 autopilot SKILL.md "중단조건 → blocked 매핑"). 정상 완주는 `completed`, 세션 한계는 `resume`, 큐 빔은 `queue-empty` 다. wrapper `rd-workflow/scripts/autopilot_headless.sh` 가 이를 exit code(0/10/20/30/40)로 매핑한다. exit code 해석은 front-end(`/fr do --headless`·`ralph_drain.sh`) 소관이다. `push`·`merge` 정책의 발행은 세션이 아니라 wrapper 가 한다. 세션은 기록 커밋 뒤 내부 토큰 `publish-ready` 를 남기고 끝나며, wrapper 가 `archive.sh` 를 실행한 결과로 `completed` 또는 `blocked:publish-failed`·`blocked:publish-incomplete`·`blocked:publish-unsafe` 를 쓴다. exit code 표는 바뀌지 않는다.

**재개 판정과 `blocked:resume-undetermined`**: 무인 진입은 새 작업을 고르기 전에 진행 중인 fr 작업이 있는지 `rd-workflow/scripts/resume_candidates.sh` 로 판정한다. 출처는 tasks 색인(`<git-common-dir>/rd-workflow/tasks.local`)과 각 worktree 의 `task-state` 이며 메인 `CURRENT_TASK.md` 가 아니다. 판정은 읽기 전용이다. `launch=ok`(대화형 세션 기동 이력) 작업은 무조건 제외하지 않고 세 갈래로 판정한다. herdr 에이전트 목록·이름과 로컬 `claude` 프로세스 cwd 를 읽기 전용으로 관측해 세 관측이 모두 완전하고 세션이 없으면 종료로 보고 후보에 넣는다(색인의 launch 값은 바꾸지 않는다). herdr app 으로 기동한 작업(색인 `launch-backend=hc`)은 이름 조회를 `hc get` 으로 한다. 세션이 살아 있다는 근거가 있으면 제외한다. 판정할 수 없으면(herdr 없음·조회 실패·시간 초과·불완전 관측) 제외하고 `rd task resolve-launch <slug> --assume-ended` 로 수동 확정하라고 안내한다. `완료`·정리 대기·worktree 부재·source FR 이 `blocked` 인 작업은 후보가 아니다. 생존·소유를 확인할 수 없는 작업(`launch` 가 `unknown`·`launching`·빈 값, 단계 판정 불가, 색인과 작업 파일 불일치, 색인 읽기 실패)이 있고 검증된 후보가 없으면 새 FR 을 고르지 않고 outcome `blocked:resume-undetermined` 로 멈춘다. FR status 와 `CURRENT_TASK.md` 는 바꾸지 않는다(대상 FR 이 없는 전역 실패). 재개 대상·제외 사유·다음 조치는 outcome 둘째 줄 이후에 남고 wrapper 가 이를 출력한다. exit code 표(0/10/20/30/40)는 바뀌지 않는다.

**claude 종료 코드 보존**: wrapper 는 `claude -p` 의 종료 코드를 보존해 stderr 에 `claude 종료 코드=<N>` 으로 남긴다. outcome 토큰이 있으면 종료 코드와 무관하게 토큰대로 매핑한다. outcome 이 비었거나 판독 불가여서 exit 40 이 될 때만 요약 줄에 비정상 종료(코드 N)·신호 종료·정상 종료(0)인데 outcome 미기록·종료 코드 확인 불가를 구분해 붙인다. exit code 표와 40 의 재시도 정책은 바뀌지 않는다.

**wrapper 가 직접 기록하는 blocked**: 중단조건 8 은 skill 이 아니라 wrapper 가 판정한다. 상한에 도달하면 wrapper 가 후손 프로세스까지 회수하고 outcome 을 `blocked:time-cap` 으로 기록한다. 회수에 실패하면 `blocked:time-cap-unreaped` 를 기록하며, 유예 시간+5초+폴링 오차 안에 반환한다. 상한 전에 `completed` 가 이미 기록됐으면 회수 성공 시 `completed` 를 유지하고, 회수 실패 시 `time-cap-unreaped` 가 우선한다. wrapper 는 `CURRENT_TASK.md`·FR·리뷰 세션 파일을 쓰지 않는다. outcome 둘째 줄 이후에 진단(경과·상한·상한 출처·작업 상태·열린 리뷰 세션·잔여 프로세스)만 남긴다. exit code 표(0/10/20/30/40)는 바뀌지 않는다.
