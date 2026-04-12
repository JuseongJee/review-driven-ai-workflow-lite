---
name: tpl
description: >
  Update project from the latest template. Run the full sync_template flow in one command.
  Use when the user says "/tpl", "템플릿 업데이트", "template update", or wants to sync the latest template changes.
user-invocable: true
disable-model-invocation: true
---

# tpl — 템플릿 업데이트

`/tpl`로 배포 repo에서 최신 템플릿을 가져와 프로젝트에 동기화한다.

Typical user requests:
- "/tpl" → 사용법 출력
- "/tpl update" → 업데이트 실행
- "템플릿 업데이트해" → 업데이트 실행
- "template update" → 업데이트 실행

## 인자 파싱

- `update` → 업데이트 실행
- 인자 없음 또는 그 외 → 사용법 출력

### 사용법 출력

```
/tpl 사용법:
- `/tpl update` — 최신 템플릿으로 업데이트

예: `/tpl update`
```

---

## 절차

`rd-workflow/docs/guides/sync_template.md`에 정의된 전체 절차를 순서대로 실행한다. 아래는 핵심 흐름 요약이며, 세부 규칙은 반드시 `sync_template.md`를 읽고 따른다.

### 1. 배포 repo URL 확보

`PROJECT_CONTEXT.md`에서 `template_repo` 값을 읽는다.

- 값이 있으면 그대로 사용한다.
- 값이 비어있거나 placeholder면 사용자에게 한 번 물어보고, 답변을 `PROJECT_CONTEXT.md`의 `template_repo`에 저장한다 (다음부터 묻지 않도록).

### 2. 마이그레이션 우선 실행

1단계에서 clone한 템플릿에 `MIGRATIONS.md`가 있는지 확인한다:
- `<clone 경로>/rd-workflow/MIGRATIONS.md` (현재 구조)
- `<clone 경로>/ai/MIGRATIONS.md` (구버전 구조 — fallback)

파일이 있으면 각 항목의 **조건**을 프로젝트에 대해 확인하고, 해당하는 항목을 순서대로 실행한다. 마이그레이션은 **sync_template.md보다 먼저** 실행해야 한다 — 디렉토리 구조가 바뀌어야 이후 파일 분류가 정상 작동한다.

### 3. sync_template.md 읽기 및 실행

`rd-workflow/docs/guides/sync_template.md`를 읽고, 문서에 정의된 절차를 **1단계부터 마지막 단계까지 전부** 실행한다. (1단계는 이미 완료되었으므로 2단계부터 시작해도 된다.)

- 버전 확인 → 파일 분류 → 사용자 확인 → 마이그레이션 감지 → 동기화 → 검증 → 버전 갱신 → skill 재설치 → extension 자동 재설치/신규 안내 → 완료 보고
- 각 단계의 세부 규칙(보존 대상, 분류 기준 등)은 sync_template.md가 권위 문서다. 이 스킬은 진입점일 뿐이다.

### 4. 완료 요약

sync_template.md의 완료 보고 단계에 따라 결과를 출력한다.

---

## 규칙

- 이 스킬은 sync_template.md의 래퍼다. 동기화 로직을 이 파일에 중복 정의하지 않는다.
- `PROJECT_CONTEXT.md`의 `template_repo`가 비어있을 때만 사용자에게 URL을 묻는다.
- 동기화 대상 파일 덮어쓰기 전에 반드시 사용자 확인을 받는다 (sync_template.md 3단계).
