---
name: tpl
description: >
  Manage rd-workflow template — update, check status, preview diff.
  Subcommands: /tpl update, /tpl status, /tpl diff.
  Use when the user says "/tpl", "템플릿 업데이트", "template update", or wants to check template version.
user-invocable: true
disable-model-invocation: true
---

# tpl — 템플릿 관리

Typical user requests:
- "/tpl" → 사용법 출력
- "/tpl update" → 업데이트 실행
- "/tpl status" → 버전 확인
- "/tpl diff" → 변경 미리보기
- "템플릿 업데이트해" → `/tpl update`로 라우팅
- "템플릿 버전 확인해" → `/tpl status`로 라우팅

사용자가 `/tpl <subcommand>` 형식으로 호출하거나, 위의 자연어 요청으로 호출한다.

## 서브커맨드 라우팅

첫 번째 인자를 파싱한다:

- `update` → Read `rd-workflow/claude_skills/tpl/update.md` and follow it.
- `status` → Read `rd-workflow/claude_skills/tpl/status.md` and follow it.
- `diff` → Read `rd-workflow/claude_skills/tpl/diff.md` and follow it.
- 그 외 / 인자 없음 → 아래 사용법 출력 후 종료 (파일 수정 없음 보장)

### 사용법 출력

```
/tpl 사용법:
- `/tpl update` — 최신 템플릿으로 업데이트
- `/tpl status` — 현재 버전과 최신 버전 비교
- `/tpl diff` — 원격 템플릿과의 차이 미리보기

예: `/tpl status`
```

---

## 규칙

- 이 스킬은 라우터다. 동기화/비교 로직을 이 파일에 중복 정의하지 않는다.
- `PROJECT_CONTEXT.md`의 `template_repo`가 비어있을 때만 사용자에게 URL을 묻는다.
- 동기화 대상 파일 덮어쓰기 전에 반드시 사용자 확인을 받는다 (sync_template.md 3단계).
- 서브커맨드가 없거나 알 수 없으면 사용법만 출력하고 종료한다. 파일 수정 없음.
