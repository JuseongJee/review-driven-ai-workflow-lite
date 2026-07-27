## /fr batch

사람이 고른 FR 묶음을 대화형으로 큐레이션한 뒤, FR별 headless autopilot을 순차 완주시키는 오케스트레이터입니다. 오케스트레이터는 **살아있는 Claude 세션**이며, 실제 FR 작업은 각각 독립 `claude -p`(autopilot_headless.sh) 세션이 수행합니다(격리). 설계 근거: `rd-workflow-workspace/specs/base/2026-07-27-1224-batch-fr-autopilot-runner-spec.md`.

### 호출 형식

`/fr batch <slug-a> <slug-b> [<slug-c> ...]`

- 인자 없음 — 사용법 출력 후 종료(파일 수정 없음).
- 진행 중 manifest(`rd-workflow-workspace/.batch-manifest.json`, status ∈ preparing/running/paused)가 이미 있으면 — 재개 여부를 사용자에게 확인합니다(신규 인자보다 재개 우선). 재개 경로는 status에 따라 갈립니다:
  - `running`/`paused` — 국면 1이 완료된 manifest입니다. 재개를 확정하면 국면 2 진입 **전에** `bash rd-workflow/scripts/batch/batch_manifest.sh validate <manifest>`를 재실행해 통과를 확인합니다(실패 시 재개하지 않고 사용자에게 실패 사유를 보고하고 멈춥니다). 통과하면 manifest `.status`를 `running`으로 전환(아래 tmp+mv 규율 적용)한 뒤 국면 2로 진입합니다. `next`가 `running` item을 최우선 산출하므로 중단 지점부터 결정적으로 이어집니다.
  - `preparing` — 대화형 준비(국면 1)가 완료되지 않은 draft입니다. **국면 2 재개 대상이 아닙니다** — 사용자 확정 전 order/depends_on/finish_policy로 무인 실행에 들어갈 수 있기 때문입니다. 사용자에게 국면 1을 이어갈지(남은 준비 단계부터 재개) 폐기하고 새로 시작할지 확인합니다. `.status`의 `running` 전환은 국면 1의 5단계(validate 통과)를 마친 뒤에만 수행합니다.
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
   - exit 40(harness-error) → 1회 재시도 후 재발 시 `blocked` 처리(ralph와 동일 정책).
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
