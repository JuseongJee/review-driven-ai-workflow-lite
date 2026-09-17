## /fr batch

사람이 고른 FR 묶음을 대화형으로 큐레이션한 뒤, FR별 headless autopilot을 순차 완주시키는 오케스트레이터입니다. 오케스트레이터는 **살아있는 Claude 세션**이며, 실제 FR 작업은 각각 독립 `claude -p`(autopilot_headless.sh) 세션이 수행합니다(격리). 설계 근거: `rd-workflow-workspace/specs/base/2026-07-27-1224-batch-fr-autopilot-runner-spec.md`.

### 호출 형식

`/fr batch <slug-a> <slug-b> [<slug-c> ...]`

- 인자 없음 — 사용법 출력 후 종료(파일 수정 없음).
- 진행 중 manifest(`rd-workflow-workspace/.batch-manifest.json`, status ∈ preparing/running/paused)가 이미 있으면 — 재개 여부를 사용자에게 확인합니다(신규 인자보다 재개 우선). 재개 경로는 status에 따라 갈립니다:
  - `running`/`paused` — 국면 1이 완료된 manifest입니다. 재개를 확정하면 국면 2 진입 **전에** `bash rd-workflow/scripts/batch/batch_manifest.sh validate <manifest>`를 재실행해 통과를 확인합니다(실패 시 재개하지 않고 사용자에게 실패 사유를 보고하고 멈춥니다). 통과하면 manifest `.status`를 `running`으로 전환(아래 tmp+mv 규율 적용)한 뒤, **국면 2 진입 전에 회수 스윕을 수행합니다.** `next`는 `blocked` 항목을 선택하지 않으므로, 스윕이 없으면 이미 발행이 끝난 blocked 작업이 회수되지 않고 `running` 완료 작업에는 무인 세션을 먼저 띄우게 됩니다.

    스윕은 **판정 패스**와 **복원 재조정 패스** 두 단계입니다.

    - **판정 패스** — 대상은 manifest 의 `blocked`·`running` 항목이며 `order` 오름차순으로 판정합니다. 각 항목에 「archive 이어붙이기 계약」 절의 분기를 그대로 적용합니다.
    - **복원 재조정 패스** — 판정 패스를 마친 뒤, **`completed` 인 모든 항목**에 대해 `bash rd-workflow/scripts/batch/batch_manifest.sh restore-dependents <manifest> "$slug"` 를 실행하고 산출된 항목을 `pending` 으로 되돌립니다. 그래프 규칙은 헬퍼가 단일 출처입니다.

      **이번 스윕에서 회수한 선행만 보면 안 됩니다.** 완료 기록(`set-state ... completed`)과 후속 복원(`set-state ... pending`)은 각각 별도 `set-state` 로 flush 되므로 그 사이에 세션이 끝날 수 있습니다. 그렇게 되면 다음 호출에서 그 선행은 이미 `completed` 라 판정 패스 대상이 아니고, 후속은 `skipped` 라 `next` 도 선택하지 않아 **영구 잔류**합니다. 후속을 일부만 복원하고 중단한 경우도 나머지에서 같은 일이 생깁니다.

      재조정 패스는 **상태를 기억하지 않고 매번 전량 재계산하므로 몇 번 중단되어도 같은 결과에 수렴합니다.** `restore-dependents` 는 `skipped` 인 항목만 산출하므로 이미 `pending` 인 항목을 다시 건드리지 않고, `excluded` 항목과 다른 `blocked` 선행이 남은 항목은 계속 제외합니다.
    - 되돌린 사실과 대상 목록을 보고합니다 — 조용히 건너뛰거나 조용히 되살리지 않습니다.
    - 스윕 결과(회수된 항목, 이어붙이기 결과, 복원된 후속, 여전히 blocked 인 항목과 사유)를 재개 보고에 출력합니다.

    스윕을 마친 뒤 국면 2로 진입합니다. `next`가 `running` item을 최우선 산출하므로 중단 지점부터 결정적으로 이어집니다.
  - `preparing` — 대화형 준비(국면 1)가 완료되지 않은 draft입니다. **국면 2 재개 대상이 아닙니다** — 사용자 확정 전 order/depends_on/finish_policy로 무인 실행에 들어갈 수 있기 때문입니다. 사용자에게 국면 1을 이어갈지(남은 준비 단계부터 재개) 폐기하고 새로 시작할지 확인합니다. `.status`의 `running` 전환은 국면 1의 5단계(validate 통과)를 마친 뒤에만 수행합니다.
  - `done` — 종료된 manifest 입니다. **`done` 은 모든 항목이 terminal 일 때만 참입니다.**

    **terminal 판정은 항목 단위로 `state=completed` 또는 `feasibility=excluded` 입니다.** 그 밖의 항목이 하나라도 있으면 회수 대상입니다. `state` 만으로 열거하면 안 됩니다 — 선별 제외는 별도 state 가 아니라 `feasibility=excluded` + `state=skipped` 조합이므로(같은 문서 아래 국면 1 규칙과 `batch_manifest.sh` 의 validate 가 이 조합을 강제합니다), `skipped` 를 그대로 미해결로 세면 **정상 종료한 배치가 매번 회수 대상이 되고** 종료 판정의 두 분기가 동시에 참이 됩니다. 미해결인 `skipped` 는 `feasibility=eligible` 인 것만입니다.

    회수 대상이 되는 비-terminal 항목은 세 종류입니다.
    - `blocked` — 국면 3은 이런 항목이 있어도 `done` 으로 종료하므로, 사용자가 그 사이 발행을 손으로 마무리했어도 자동으로는 회수되지 않습니다.
    - `skipped` + `eligible` — 선행 blocked 때문에 대기 중인 후속입니다.
    - `pending`·`running` — 스윕이 후속을 복원한 뒤 `paused` 저장 전에 중단된 흔적입니다.

    **회수 조건을 `blocked`·`skipped`(+eligible) 잔존으로만 두어도 안 됩니다.** 마지막 `skipped` 를 `pending` 으로 저장하고 `paused` 전환 전에 세션이 끝나면 `status=done` 인데 `blocked`·`skipped` 가 하나도 없는 상태가 남습니다. 그러면 다음 호출이 스윕도 재개 안내도 도달하지 못하고, 실행할 후속이 남았는데 완료된 배치처럼 취급돼 새 batch 를 시작하면 기존 작업을 놓칩니다. 복원 자체의 멱등성으로는 이 **재진입 조건의 공백**이 메워지지 않습니다.
    - 새 batch 인자와 함께 호출된 경우에도 **회수 확인을 먼저 제시**합니다. 사용자가 건너뛰면 새 batch로 갑니다.
    - **회수를 확정하면 어떤 `set-state` 보다 먼저 `.status` 를 `paused` 로 저장합니다** (tmp+mv 규율). 이렇게 하면 스윕 중 어디서 중단되어도 남는 상태가 `paused` 이고, `paused` 는 이미 재개 진입이므로 다음 호출이 반드시 도달합니다. 순서를 뒤집어 `set-state` 를 먼저 하면 모든 flush 경계가 위와 같은 공백을 만듭니다.
    - 회수는 **완료 증거 회수이며 자동 재실행이 아닙니다** — 위 회수 스윕만 수행하고 headless를 기동하지 않습니다.
    - **`not-archived`는 재시도하지 않습니다.** 「archive 이어붙이기 계약」의 `not-archived` 처리는 국면 2의 재시도 경로인데, 이 진입은 headless를 기동하지 않기로 한 자리입니다. 상태를 그대로 보존하고 보고만 합니다 — 그 항목은 아직 발행되지 않았으므로 회수 대상이 아닙니다.
    - **회수 결과에 따라 manifest 상태를 정합니다.**

      두 분기는 진입 조건과 **같은 terminal 정의**를 쓰므로 서로 배타적입니다. 판정에는 `summary` 의 배타 집계(`completed`/`skipped`/`blocked`/`excluded`/`pending`/`running`)를 쓰고 임의 jq 집계를 만들지 않습니다.

      | 회수 후 | `.status` | 제시할 다음 행동 |
      |---|---|---|
      | 모든 항목이 terminal (`completed` 또는 `excluded`) | **`done` 으로 되돌림** (tmp+mv 규율) | 새 batch 진행 여부 |
      | **비-terminal 항목이 남음** (`blocked` / `skipped`+`eligible` / `pending` / `running`) | **`paused` 유지** | ① 이 배치 이어가기 ② 나중에 재개 ③ 새 batch |

      `done` 으로 되돌리는 것은 **스윕을 끝까지 마쳤고 비-terminal 항목이 남지 않았음을 확인한 뒤**에만 합니다. 남은 것이 있는데 `done` 으로 두면 다음 호출의 회수 조건에서 빠져 그 항목이 영영 실행되지 않습니다.
    - **기존 manifest를 보존합니다.** 새 batch를 시작하기로 해도 `paused` 상태의 기존 manifest를 덮어쓰기 전에 그 사실과 잃게 되는 항목을 알리고 확인을 받습니다.
    - 회수 목록·사유·각 항목의 다음 행동을 보고에 출력합니다.
- **`.status` 전환 규율**: manifest `.status` 필드를 직접 전환할 때(재개 시 `running`, 국면 2 중단 시 `paused`, 국면 3 종료 시 `done` — 이하 모두 동일 규율 적용)는 `jq '...' "$mf" > tmp && mv tmp "$mf"` 형태의 임시파일+mv로 갱신·flush합니다. `jq ... "$mf" > "$mf"`처럼 같은 파일로 직접 리다이렉트하면 파일이 truncate됩니다.
- 전제: `jq` 설치. 미설치면 "batch는 jq가 필요합니다" 안내 후 종료.

### 국면 1 — 대화형 준비 (사람 있음)

0. **slug resolve**: 각 입력 slug를 `bash rd-workflow/scripts/batch/batch_manifest.sh resolve-slug <slug>`로 확인합니다. exit≠0(미존재 또는 복수 매칭)이면 그 slug를 보고하고 batch를 시작하지 않습니다(전체 중단). 사용자 입력 오타·미존재를 준비 착수 전에 차단합니다.
1. **선별(feasibility)**: 각 slug에 autopilot 적합성 기준(autopilot SKILL.md 단일 출처 — `/fr inspect`가 인용하는 것과 동일)을 적용해 가능/조건부/불가 판정합니다.
   - 불가: 묶음에서 제외, manifest item `feasibility=excluded` + `state=skipped` + `exclude_reason` 기록. (선별 제외 invariant — `validate`가 `excluded ⟹ state=skipped`를 강제하고, `summary`는 이를 `excluded`로만 집계하여 `skipped`(실행 중 선행 blocked로 건너뛴 eligible)와 구분합니다.)
   - 조건부: 다음 단계에서 결정을 닫으면 승격, 못 닫으면 excluded.
2. **brainstorming 보강**: 처리 가능한 각 FR에 대해, headless mode A가 자율로 못 닫을 **사람 결정**(제품 방향·외부 의존 채택 등)만 사용자와 대화로 확정하고 FR 상세(request seed/범위/제약)에 명시적으로 기록합니다. full brainstorming skill을 FR마다 호출하는 것이 아니라 경량 "결정 닫기"입니다.
3. **의존/순서 확정**: 묶음의 인과관계를 분석해 실행 순서(order)와 의존 그래프(depends_on)를 사용자에게 제시·확정합니다. 자동 탐지가 아니라 사용자 확정입니다.
4. **종료 정책 확정**: `push` / `merge` 중 1회 확인합니다. `none`은 지원하지 않습니다(archive를 하지 않아 완료 목표와 모순입니다). 확정값은 모든 FR에 일관 적용됩니다.
5. **manifest 작성**: 위 결과를 `rd-workflow-workspace/.batch-manifest.json`에 기록하고 `bash rd-workflow/scripts/batch/batch_manifest.sh validate <manifest>`로 검증합니다(순환 의존·dangling·finish_policy 차단). **validate 통과 후에만** status를 `running`으로 전환합니다(tmp+mv 규율 — 호출 형식 참조). 이 전환이 국면 1 완료의 유일한 신호이며, `preparing`인 동안은 국면 2에 진입하지 않습니다.

### archive 이어붙이기 계약

`archive.sh` 도중 세션이 죽으면 merge 만 되고 tag·push·브랜치 정리가 남은 중간 상태가 됩니다. `verify-done` 은 workspace 사실만 보므로 이것을 완료와 구분하지 못합니다. 판정은 헬퍼가 단일 출처이며 이 문서는 규칙을 복제하지 않습니다.

```bash
bash rd-workflow/scripts/batch/batch_manifest.sh archive-state <manifest> "$slug"
```

stdout 첫 줄의 `state=` 로 분기합니다.

- `complete` → 발행은 끝났고 outcome 기록만 실패한 경우입니다. 이어붙이기 없이 `verify-done` 재확인 후 `set-state <manifest> "$slug" completed completed -` 로 전이합니다. **마지막 `-` 는 `block_reason` 을 비우는 인자입니다** — 생략하면 옛 실패 사유가 완료 항목 요약에 그대로 남습니다.
- `incomplete-archive` → **이어붙이기 1회**. 기본 브랜치 worktree 에서 아래를 실행합니다. **무인자 재호출은 금지입니다** — `archive.sh` 는 tag·push 이전에 metadata 를 baseline 으로 되돌리므로 무인자로는 원래 slug 를 복원하지 못하고, 다른 작업이 활성화된 뒤라면 **다른 FR 을 대상으로 실행**할 수 있습니다. `archive.sh` 는 `RD_FINISH_POLICY` 를 읽지 않으므로 정책도 인자로 전달해야 합니다.

  | policy | 명령 |
  |---|---|
  | `push` | `bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch "fr/$slug"` |
  | `merge` | `bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch "fr/$slug" --no-remote` |

  재호출 뒤 **같은 `archive-state` 를 다시 실행합니다.** `archive.sh` 의 성공 exit 만으로는 발행 완료가 보증되지 않습니다 — "fr branch 부재 + 동일 slug tag 존재" 만으로도 success exit 하기 때문입니다. **재판정에도 최초 판정과 같은 원칙을 적용합니다.**

  | 재판정 | 처리 |
  |---|---|
  | `complete` | `set-state <manifest> "$slug" completed completed -` |
  | `incomplete-archive` | 확정된 미완료 → `set-state <manifest> "$slug" blocked "" "archive 이어붙이기 실패 — 미충족: <missing>"` |
  | `not-archived` | 확정된 미완료 → `blocked` |
  | `unknown` | **`blocked` 로 보내지 않습니다.** 상태를 보존한 채 중단·보고합니다 |

  재판정의 `unknown` 을 `blocked` 로 바꾸면 **증거 부족이 작업 실패로 둔갑**합니다 — 최초 조회는 성공해 `incomplete-archive` 였는데 `archive.sh` 수행 후 원격이 끊기면 재판정은 `unknown(remote-unreachable)` 이고, 이때 `blocked` 로 넘기면 `missing=-` 인 "이어붙이기 실패" 만 남습니다.

  **보고는 두 가지를 구분합니다** — `archive.sh` 자체의 실행 결과(성공/실패와 메시지)와 재판정 결과(`state`·`missing`·`reason`). 하나로 뭉치면 무엇이 실패했는지 흐려집니다.

  `archive.sh` 가 활성 metadata 불일치·dirty worktree 로 거부하면 그것은 정상 동작입니다. **같은 명령을 반복 안내하지 말고** 그 사유와 그 상태에서 유효한 다음 행동(worktree 정리, 활성 작업 마무리 등)을 남깁니다.
- `not-archived` → 국면 2 의 재시도 경로를 따릅니다.
- `unknown` → **상태를 보존한 채 중단하고 사용자에게 보고합니다.** `set-state` 로 상태를 바꾸지 않습니다. 완료로도 미병합으로도 취급하지 않으며, 일반 재시도로도 보내지 않습니다 — 이미 merge 된 작업을 재시도로 보내면 처음부터 다시 구현할 위험이 있습니다. **막다른 안내를 만들지 않도록 `reason` 별로 유효한 다음 행동을 제시합니다.**

  | reason | 다음 행동 |
  |---|---|
  | `remote-unreachable` | 네트워크·인증 확인 후 **판정만** 재실행 (`archive-state`). `archive.sh` 재실행은 불필요합니다 |
  | `remote-object-missing` | `git fetch origin` 으로 필요한 object 를 확보한 뒤 판정 재실행 |
  | `default-ref-missing` | 기본 브랜치 ref 를 로컬에 확보한 뒤 판정 재실행 |
  | `no-default-branch` | `rd-workflow/config/workflow.json` 의 `default_branch` 확인 |
  | `lifecycle-common-missing` | 설치 상태 확인 (`install-root`) |

판정 사유(`state`·`missing`), 이어붙이기 시작·결과, 실패 시 미충족 증거와 유효한 다음 행동을 진행 표시·로그와 국면 3 최종 요약에 노출합니다. 별도 UI 는 만들지 않습니다.

### 국면 2 — 무인 순차 실행 (사람 없음)

manifest status가 `running`인 동안 반복합니다:

1. **다음 대상**: `slug=$(bash rd-workflow/scripts/batch/batch_manifest.sh next <manifest>); rc=$?`.
   - `slug` 있음 → 2로 진행합니다. (`running` item이 있으면 `next`가 최우선 산출하므로 중단 후 재개 자동입니다.)
   - `slug` 빈값 + `rc=0` → 진짜 terminal, 국면 3으로 갑니다.
   - `slug` 빈값 + `rc=3` → **dead-end**(validate가 정상 차단하나 방어적 감지). 완료로 보지 않고 남은 stranded 규모를 `bash rd-workflow/scripts/batch/batch_manifest.sh summary <manifest>` 의 `pending=`/`running=` 값으로 요약에 명시한 뒤(임의 jq 집계 금지) 중단·사용자 보고합니다.
   - `slug` 빈값 + **그 외 `rc`**(예: 손상 manifest·경로 오류의 `2`) → 완료·dead-end 로 간주하지 않고 즉시 중단·사용자 보고합니다.
2. **상태전이 → running**: `bash rd-workflow/scripts/batch/batch_manifest.sh set-state <manifest> "$slug" running` 후 headless를 기동합니다:
   ```bash
   RD_AUTOPILOT_FR="$slug" RD_AUTOPILOT_MODE=A RD_FINISH_POLICY=<manifest.finish_policy> \
     RD_AUTOPILOT_OUTCOME_FILE=rd-workflow-workspace/.batch-outcome-"$slug" \
     bash rd-workflow/scripts/autopilot_headless.sh
   ```
3. **완주 판정(ground truth 재확인)**: exit 0이어도 `bash rd-workflow/scripts/batch/batch_manifest.sh verify-done "$slug"`로 재확인합니다.
   - 재확인 통과 → `set-state <manifest> "$slug" completed completed`.
   - exit 0이나 재확인 실패(outcome 오기록) → `set-state <manifest> "$slug" blocked "" "ground truth 불일치"` 후 4의 전파 적용.
4. **실패 처리(exit 10/20/30/40 또는 재확인 실패)**:
   - exit 20/30 또는 재확인 실패 → `set-state <manifest> "$slug" blocked ...`. 이어서 `skip=$(... skip-dependents <manifest> "$slug")`의 각 slug를 `set-state <manifest> <s> skipped "" "선행 $slug blocked"`로 기록합니다. 독립 FR은 계속합니다.
   - exit 10(resume) → item은 `running` 유지(set-state로 바꾸지 않음), manifest `.status`를 `paused`로 저장(tmp+mv 규율 — 호출 형식 참조)하고 재개 안내 후 멈춥니다. 다음 `/fr batch` 실행이 이 paused manifest를 감지해 재개를 확인하고, `.status`를 `running`으로 되돌린 뒤(호출 형식 참조) 국면 2를 재진입하면 `next`가 이 `running` item을 최우선 산출해 같은 FR을 이어갑니다. 잔여 규모 보고가 필요하면 `batch_manifest.sh summary` 의 `pending=`/`running=` 값을 사용합니다(임의 jq 집계 금지).
   - exit 40(harness-error) → **먼저 「archive 이어붙이기 계약」 절의 판정을 수행합니다.** `complete`·`incomplete-archive`·`unknown` 은 그 절의 처리를 따릅니다. `not-archived` 일 때만 아래 재시도 경로로 갑니다.

     `not-archived` 재시도 경로 — 1회 재시도 후 재발 시 `blocked` 처리(ralph와 동일 정책). **재시도 전에 재개 지점을 정리합니다**:
     1. 열린 리뷰 세션의 최신 Reviewer 턴이 `이의 없음` 이면 그 세션을 `awaiting-user` 로 종결 처리합니다 — 네 가지를 모두 갱신합니다.
        - `SESSION.md`: `Status=awaiting-user`, `Current Owner=User`
        - `CHECKPOINT.md`: 현재 결론과 남은 쟁점. 미해결이 없으면 Open Issues 를 정확히 `- 없음` 한 줄로 적습니다 (그 외 산문 표기는 미해결로 판정됩니다)
        - `USER_ACTION.md`: 사용자가 취할 다음 행동과 질문. **이 갱신을 빠뜨리면 Owner 는 User 인데 안내는 "확인이 필요한 단계가 아닙니다" 라고 말하는 모순 상태가 사용자에게 노출됩니다**
        - 리뷰 요약 report: `rd-workflow-workspace/reports/reviews/` 에 작성
        사람이 마무리를 승인하기 전에는 `closed` 로 전환하지 않습니다 (`rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md` 종료 규칙).
     2. `CURRENT_TASK.md` Status 를 실제 진행 단계에 맞게 보정합니다.
     3. 정리 결과를 `CURRENT_TASK.md` Notes 에 기록합니다.

     매 시도가 서로 다른 지점까지 진도를 냈다면 작업 결함이 아니라 세션 수명 문제입니다. `blocked` 로 버리기 전에 autopilot SKILL.md 「무인 진입」의 「결과 대기 규율」 위반 여부를 확인합니다.

     **적용 범위**: 신규 exit 40 과 재개 회수 스윕이 같은 분기를 씁니다. 이미 `completed` 로 집계된 항목의 판정은 소급하지 않습니다.
   - 상태전이는 모두 `set-state`로 수행되어 매번 flush됩니다(재개 지점 최신화).

### 국면 3 — 최종 요약

1. `bash rd-workflow/scripts/batch/batch_manifest.sh summary <manifest>`로 집계를 받습니다.
2. 완료/skip(+선행 사유)/제외(+사유)/실패(+blocked 사유)/적용 종료정책을 정리해 `rd-workflow-workspace/reports/`에 저장하고 사용자에게 출력합니다.
3. manifest status를 `done`으로 전환합니다(tmp+mv 규율 — 호출 형식 참조).

### 규칙

- **SSOT 위임**: 다음 대상 선정·재개(`next`)·상태전이(`set-state`)·실패 전파(`skip-dependents`)·집계(`summary`)·완주 재확인(`verify-done`) 규칙은 `batch_manifest.sh`가 단일 출처입니다. 이 문서는 규칙을 산문으로 복제하지 않고 헬퍼를 호출합니다.
- mode A 고정. mode B FR은 batch 대상이 아닙니다(개별 처리).
- `none` 종료 정책은 지원하지 않습니다(비범위).
- 실제 headless 완주·순차 merge 충돌은 자동 검증 불가한 잔여 위험입니다(spec §7). 구현/운영 검수 시 소규모 수동 smoke로 확인합니다.
- 모든 출력은 존댓말입니다.
