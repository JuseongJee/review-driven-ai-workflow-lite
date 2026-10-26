# Claude Project Rules

이 파일은 프로젝트 소유다. 템플릿 sync 가 이 파일을 덮어쓰지 않으므로 프로젝트에 맞게 자유롭게 고친다. rd-workflow 의 워크플로 규칙은 이 파일이 아니라 `.claude/rules/rd-workflow/` 에 있다.

## 언어

한국어로 대화한다. 코드 주석·식별자·문체는 기존 프로젝트 컨벤션을 따른다.

## 프로젝트 규칙

<!-- 프로젝트 고유 규칙을 이 절에 적는다. rd-workflow 규칙과 다르게 하려면 대체할 규칙을 이름으로 함께 적는다 (예: "core.md 의 `**검증**` 항목을 이 프로젝트에서는 ... 로 대체한다"). -->

## rd-workflow 규칙

rd-workflow 의 워크플로 규칙은 `.claude/rules/rd-workflow/` 의 파일에 있다. Claude Code 가 이 폴더를 자동으로 읽는다 (Claude Code 2.1.310 이상 필요).

- `core.md` — 기본 인터페이스, 우선 원칙, Intake 규칙, Workflow 우선순위, 핵심 절차(REQUEST 아카이브 포함), 절대 규칙, Review 규칙, Always Read
- `task-tracking.md` — Task Tracking, Spec / Plan Naming
- `writing-style.md` — 문서 작성 스타일
- `efficiency.md` — 토큰 효율 규칙, 세션 한계 대응
- `commit.md` — 커밋 메시지

이 폴더는 템플릿 소유라 sync 가 덮어쓰므로 직접 고치지 않는다. 규칙을 다르게 하려면 위 `## 프로젝트 규칙` 에 대체할 규칙을 이름으로 적는다.
