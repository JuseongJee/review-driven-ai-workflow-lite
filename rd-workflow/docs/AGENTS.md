# AGENTS.md

이 문서는 Git 워크플로와 handoff 규칙만 다룹니다.

AI 협업 기본 규칙은 프로젝트 루트의 `CLAUDE.md`를 기준으로 봅니다.

## Git 워크플로 규칙

아래는 AI가 Git을 사용할 때 따르는 규칙입니다.

### 브랜치 전략
- 기능 개발 시작 시 반드시 새 브랜치를 생성합니다.
- 브랜치 네이밍: `fr/{slug}` 단일 규칙.
  - slug 정규화는 `rd-workflow/scripts/lifecycle/slug.sh`의 `normalize_slug()` 사용.
  - 예: `fr/my-feature`, `fr/fix-login-bug`
- 작업 완료 후 lifecycle 정책에 따라 archive 처리:
  - `main --no-ff merge → fr/{YYYY-MM-DD-HHMM}/{slug} tag → branch 삭제 (local + remote)`
  - 자세한 절차는 `rd-workflow/scripts/lifecycle/README.md` 참조.

### 커밋 규칙
- 커밋 메시지 언어와 형식은 `CLAUDE.md`를 따릅니다.
- 모든 커밋 메시지는 한글로 작성합니다.
- 의미 있는 단위로 커밋합니다.

### 머지 규칙
Fast Forward 머지 금지

예:

git merge --no-ff fr/기능명

---

## Handoff Branch Context

review_pipeline 세션의 `SESSION.md`에는 `## Branch Context` 섹션(5필드)을 보존한다:

- `fr-branch`: 현재 작업 중인 fr/{slug} 브랜치 이름 (null 또는 main 가능)
- `worktree-path`: worktree 절대 경로 (null이면 main worktree)
- `short-title`: fr branch의 slug 식별자 (unknown이면 미확정)
- `lifecycle-stage`: 현재 lifecycle 단계 (request-review / spec-review / plan-review / implementing / validating / archive-pending / archived)
- `remote-mode`: remote 또는 local-only

자세한 schema와 검증 정책은 `rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md` 참조.

---

# 핸드오프 규칙

작업을 다른 사람이나 세션에 넘길 때 rd-workflow-workspace/handoffs/ 폴더에 작업 컨텍스트를 저장합니다.

파일명 형식:

{순번}_{커밋해시8자}_{날짜시간}_{요약}.md

예:

rd-workflow-workspace/handoffs/001_ed5d699a_20260224_190530_앱아이콘추가.md
