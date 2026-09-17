---
name: small-task-implement
description: Implement a standard-tier change — promote to a fr branch, write the abbreviated REQUEST.md with Risk Tier, implement, verify, reclassify before final diff review, and update CURRENT_TASK.md. Use when the risk tier is `standard` (see WORKFLOW.md 위험 등급 절).
---

# Small Task Implement (`standard` 등급)

`manual` 모드에서는 사용자의 단계 진입 지시 없이 이 skill 을 스스로 시작하지 않는다. 판정 기준은 `rd-workflow/docs/flows/AUTONOMY.md` 의 「실행 모드와 skill 호출 권한」 절이다.

`standard` 등급 작업의 구현 skill 입니다. 등급 판정은 이 skill 진입 **전**에 끝나 있어야 하고, 시작 보고 블록은 이 skill 의 1단계(시작 계약 확인) **직후**에 이 skill 이 1회 냅니다 — 라우터는 블록을 내지 않습니다 (`rd-workflow/docs/flows/WORKFLOW.md` 위험 등급 절). `light` 는 이 skill 을 쓰지 않고 WORKFLOW.md 의 light 체크리스트를 따르며, `full` 은 `/request-to-reviewed-plan` 입니다. 하향은 사용자만 할 수 있습니다 — 사용자가 `standard` 로 하향 지시했으면 그 지시를 `## Risk Tier` 이력에 적습니다.

Typical user requests:
- "standard 로 보고 바로 구현해줘"
- "이거 작은 수정으로 처리해줘" (AI 가 신호표로 `standard` 판정 후 진입)

## 절차

1. **시작 계약 확인** (WORKFLOW.md 시작 계약 5항, 순서 그대로): `Status = 대기 중` → switch 전에 현재 브랜치·clean 선확인(dirty 면 상태 변경 없이 중단 — 이미 기본 브랜치이고 사용자가 전부 채택을 명시한 경우만 예외) → 필요 시 기본 브랜치 checkout 후 clean 재확인 → `bash rd-workflow/scripts/lifecycle/start_preflight.sh` 실행 — exit 0(synchronized·등록 커밋만 ahead 인 자동 채택·local-only)이면 진행, exit 10 은 인계(사용자가 ahead 커밋 발행을 명시 채택하면 진행하고 `## Risk Tier` 이력에 기록) → baseline HEAD 기록 → **시작 보고 블록 1회 출력** — 필드는 WORKFLOW.md 위험 등급 절의 정본 목록을 그대로 상속하고(`실행 모드: <모드> (출처: <출처>)` 포함), 여기서 값이 정해지는 것은 둘뿐입니다: `push 예정` = `archive.sh 경유`(채택한 ahead 커밋 수 병기), `미병합 브랜치 FR 후보` = preflight 출력 줄 그대로.
2. **fr 브랜치 승격**: `bash rd-workflow/scripts/lifecycle/promote.sh --short-title <slug> --size small --source-fr <items 경로 또는 ->`. short-title 은 promote 가 기록하므로 이 skill 은 `CURRENT_TASK.md ## Short Title` 을 read-only 로만 씁니다. raw-capture 와 3-way 분기는 하지 않습니다.

> **주의:** 위 2단계 직후 `launch=ok` 면 이 세션은 여기서 멈춘다 — 3단계부터는 기동된
> 세션이 진행한다. `launch=unknown` 이면 이 세션도 아직 이어받지 않는다 —
> `bash rd-workflow/scripts/rd task resolve-launch <slug>` 로 확정한 뒤에만 갈린다(살아
> 있으면 멈춤 / `failed` 로 확정되면 3단계로 진행). `launch` 가 `failed`·`none` 이면
> 이 세션이 곧바로 3단계로 진행한다 — 단 **`--no-worktree` 를 쓰지 않았다면 먼저 위
> promote 출력의 `worktree <path>` 로 이동한다.** promote 는 기본적으로 별도 worktree
> 를 만들 뿐 현재 세션의 작업 디렉터리를 바꾸지 않으므로, 이동하지 않고 3단계를 진행하면
> 원래 디렉터리(대개 기본 브랜치)의 파일을 건드리게 된다.
>
> **알려진 한계:** `--source-fr -`(FR 없는 자연어 요청)로 herdr 환경에서
> `launch=ok` 가 된 경우 — 위 2단계 직후 곧바로든, `launch=unknown` 을
> `resolve-launch` 로 확정해 `ok` 가 된 경우든 동일하게 — 기동된 세션은 slug·경로만
> 인계받고 원래 사용자 요구사항은 모른다. 이 skill 은 raw-capture 를 하지 않으므로(위
> 2단계) 인계 문구만으로는 3단계(축약 REQUEST 작성)를 수행할 수 없다. 이 한계는 FR
> `small-task-implement-handoff-content-gap` 로 별도 추적한다(session-handoff-
> contract-and-model final-diff-review 결정 — 재현 조건이 herdr+FR 없음으로 좁고,
> 해소하려면 raw-capture·인계 문구 확장 등 새 데이터 흐름 설계가 필요해 별도 FR 로
> 분리했다). 그 전까지는 이 조합에서 **호출 세션이 멈추기 전에** 원 요구사항을
> 기동된 세션에 직접 붙여넣거나(`herdr agent prompt`), 기동된 세션 화면에서 사람이
> 직접 원 요구사항을 입력해야 한다.

3. **축약 REQUEST 작성**: `Task Type`·`Execution Path`·`User Goal`·`Change Description`·`Acceptance Criteria`·`Risk Tier`·`Source FR` 만 채우고 나머지는 `-`. `## Risk Tier` 는 `- 최종 등급: standard` 를 포함해 6항목을 **작성 즉시** 채웁니다(`-` 로 두지 않음 — 파서가 malformed 로 봅니다. 재분류 때 확인·갱신). 필요하면 `Change Description` 안에 한 문단 spec + 한 목록 plan 을 적습니다.
4. **AC 확인**: Acceptance Criteria 가 비어 있거나(`-`) 모호하면 구현을 시작하지 않고 사용자에게 확인을 요청합니다.
5. **구현**: 변경을 작고 직접적으로 유지합니다. 불필요한 구조·투기적 리팩터를 넣지 않습니다.
6. **검증**: 고친 영역에 맞는 범위만. 제품 코드는 `bash rd-workflow/scripts/{test,lint,typecheck,build}.sh` (프로젝트가 교체한 경우), 워크플로 인프라는 해당 `self_test.sh` 그룹.
7. **커밋 전 재분류**: `git status --porcelain` + `git diff --name-only <baseline>..HEAD` 의 변경 집합을 신호표와 대조합니다. `full` 신호가 있으면 이 skill 을 멈추고 등급 상향을 한 줄로 알린 뒤 `/request-to-reviewed-plan` 으로 넘깁니다(브랜치 유지, spec/plan 정식 작성). 벗어나지 않으면 `## Risk Tier` 를 확정합니다.
8. `CURRENT_TASK.md` 를 갱신하고 **`/final-diff-review` 로 넘깁니다. `standard` 는 이 단계를 건너뛰지 않습니다.**

## Final output

- 시작 보고 블록(필드는 WORKFLOW.md 위험 등급 절의 정본 목록 — 여기서 다시 열거하지 않습니다) 을 1단계 직후 1회 냈는지
- What changed
- Verification status
- 재분류 결과 (유지 / 상향)
- `Next recommended skill: /final-diff-review`
- Any blocker that still needs user input
