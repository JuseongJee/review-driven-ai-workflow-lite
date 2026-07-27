# rd-workflow 결함 보고 규약

rd-workflow 워크플로 템플릿을 사용하는 소비 프로젝트에서, 발견한 문제가 rd-workflow **인프라 자체의 결함**일 때 따르는 규약입니다. 인프라 결함은 소비 프로젝트의 책임 범위가 아니므로 소비 프로젝트 backlog(FR)에 등록하지 않고, rd-workflow repo로 전달할 보고 파일만 생성합니다.

## 적용 스코프

- 이 규약은 rd-workflow를 **소비하는** 프로젝트에만 적용됩니다.
- rd-workflow 본체 repo(이 워크플로 템플릿을 개발하는 repo)에서는 인프라 결함을 **정상 FR로 등록**합니다. 본 규약을 적용하지 않습니다.

## 결함 소유권 판별

다음 중 하나에 해당하면 **rd-workflow 인프라 결함**입니다:

- rd-workflow 산출물 문서(`rd-workflow/docs/`, 배포된 `CLAUDE.md`·`PROJECT_CONTEXT.md` 템플릿 등)의 오류·모순·누락
- `rd-workflow/scripts/` 스크립트의 버그·오동작
- `rd-workflow/claude_skills/` skill 지침의 결함

다음은 인프라 결함이 **아니며**, 기존 Intake대로 소비 프로젝트 FR로 등록합니다:

- 소비 프로젝트 자신의 코드·설정·산출물 문제
- 소비 프로젝트가 rd-workflow를 잘못 설정·사용한 경우 (설정 수정으로 해결)

### 경계 케이스 (conservative default)

판별이 애매하거나 소비 프로젝트 문제와 인프라 결함이 동시에 의심되면 **보고 파일 생성을 우선**합니다 (인프라 신호를 소비 backlog에 묻지 않습니다). 소비 프로젝트 고유의 후속 작업이 분리 가능하면 그 부분만 별도 FR로 등록합니다. 완전히 뭉쳐 판별이 불가능하면 보고 파일 생성 쪽으로 기웁니다.

## 보고 파일 규약

- 위치: `rd-workflow-workspace/reports/workflow-defects/` (디렉토리가 없으면 생성)
- 파일명: `YYYY-MM-DD-HHMM-<short-slug>.md` (동일 파일명이 있으면 `-2`, `-3` suffix)
- 결함마다 새 파일을 만듭니다 (기존 파일에 append 금지).

### 형식 스키마

    # rd-workflow 결함 보고: <제목>
    - 발견일: YYYY-MM-DD
    - rd-workflow VERSION: <rd-workflow/VERSION 값>
    - 대상 산출물: <문제가 있는 파일·스크립트·skill 경로>

    ## 재현 맥락
    어떤 작업 중 발견했는지

    ## 관찰된 결함
    실제로 무엇이 잘못 동작했는지

    ## 기대 동작
    어떻게 동작해야 하는지

## 전달

생성한 보고 파일을 rd-workflow repo로 실제 전달하는 방법(파일 복사·issue 등록 등)은 본 규약의 범위 밖입니다. 소비 프로젝트 운영자가 수동으로 전달합니다.
