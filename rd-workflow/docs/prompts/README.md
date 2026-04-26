# Prompt Guide

이 폴더는 상시 입력창이 아니라 보조 도구 상자입니다.

프롬프트를 꺼내야 할지 판단할 때는 이 문서를 먼저 봅니다.

## 기본 원칙

- 평소에는 입력창에 짧은 자연어 요청을 먼저 넣습니다.
- skill이 있으면 skill 이름만 붙여도 원하는 단계까지 가는 경우가 많습니다.
- 프롬프트 파일은 예문, 보정, 수동 복구에만 씁니다.

짧은 요청 예:

```text
이 요구사항으로 planning-design-intake skill로 진행해줘.
```
(새 자유 텍스트 큰 작업은 planning-design-intake 로 REQUEST.md 를 만든 후 request-to-reviewed-plan 으로 진행)

```text
REQUEST.md 있으니 request-to-reviewed-plan으로 spec/plan 진행해줘.
```

```text
small-task로 보고 바로 구현해줘.
```

```text
future request에 기록해줘.
```

```text
future request 후보 보여줘.
```

## 폴더 역할

`guides/`
- 설정, 마이그레이션, 템플릿 동기화 등 실행 절차 문서

`recovery/`
- 모델이 형식이나 절차를 자꾸 놓칠 때 그대로 붙여 넣는 보정 프롬프트

`manual/`
- review pipeline이나 특정 절차를 수동으로 시작하거나 이어갈 때 그대로 붙여 넣는 프롬프트

## 추천 사용 순서

1. 자연어로 짧게 요청 (`WORKING_WITH_AI.md` 참조)
2. 설정/마이그레이션/동기화가 필요하면 `guides/`
3. 모델이 형식이나 절차를 반복해서 놓치면 `recovery/`
4. 스크립트나 자동화가 막히면 `manual/`

## 자주 쓰는 파일

- `guides/setup_with_claude.md`
- `guides/sync_template.md`
- `guides/migrate_existing_project.md`
- `recovery/request_to_reviewed_plan_full.md`
- `manual/review_pipeline_continue_manual.md`
