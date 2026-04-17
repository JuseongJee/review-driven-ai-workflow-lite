---
name: fr
description: >
  Manage future requests — add, list, prioritize, lifecycle, sync with GitHub Issues.
  Subcommands: /fr add, /fr list, /fr pri, /fr archive, /fr park, /fr status, /fr pull, /fr push, /fr sync.
  Use when the user wants to manage backlog items.
user-invocable: true
disable-model-invocation: true
---

# FR — Future Request 관리

Typical user requests:
- "/fr add autopilot에서 review gate 자동화"
- "/fr list"
- "/fr pri"
- "/fr archive"
- "/fr park workflow-branch-clarification"
- "/fr status some-title validated"
- "이거 FR에 넣어줘" → `/fr add`로 라우팅
- "future request에 기록해줘" → `/fr add`로 라우팅
- "FR 목록 보여줘" → `/fr list`로 라우팅
- "FR 우선순위 검토해줘" → `/fr pri`로 라우팅
- "done 항목 정리해줘" → `/fr archive`로 라우팅
- "이거 parked로 옮겨줘" → `/fr park`로 라우팅

사용자가 `/fr <subcommand> [args]` 형식으로 호출하거나, 위의 자연어 요청으로 호출한다.

## 서브커맨드 라우팅

첫 번째 인자를 파싱한다:

- `add` → Read `rd-workflow/claude_skills/fr/add.md` and follow it.
- `list` → Read `rd-workflow/claude_skills/fr/list.md` and follow it.
- `pri` → Read `rd-workflow/claude_skills/fr/pri.md` and follow it.
- `archive` → Read `rd-workflow/claude_skills/fr/archive.md` and follow it.
- `park` → Read `rd-workflow/claude_skills/fr/park.md` and follow it.
- `status` → Read `rd-workflow/claude_skills/fr/status.md` and follow it.
- `pull` → Read `rd-workflow/claude_skills/fr/pull.md` and follow it.
- `push` → Read `rd-workflow/claude_skills/fr/push.md` and follow it.
- `sync` → Read `rd-workflow/claude_skills/fr/sync.md` and follow it.
- 그 외 / 인자 없음 → 아래 사용법 출력 후 종료 (파일 수정 없음 보장)

**Legacy call 처리**: 첫 번째 단어가 `add`, `list`, `pri`, `archive`, `park`, `status`, `pull`, `push`, `sync` 중 어느 것도 아니면 사용법 help를 출력한다. 파일을 절대 수정하지 않는다.

### 사용법 출력

```
/fr 사용법:
- `/fr add 내용` — FR 등록
- `/fr list` — 활성 항목 목록 출력
- `/fr pri` — 우선순위 검토
- `/fr archive` — done 항목 인덱스에서 일괄 삭제
- `/fr park <제목>` — 항목을 parked로 이동
- `/fr status <제목> <상태>` — 항목 상태 변경
- `/fr pull` — GitHub Issues → 로컬 FR 가져오기
- `/fr push [제목]` — 로컬 FR → GitHub Issue 내보내기
- `/fr sync` — 연결된 항목 status 동기화

예: `/fr add autopilot에서 review gate 자동화`
```

---

## 백엔드 결정

서브커맨드 실행 전에 GitHub 연동 여부를 결정한다.

1. 인자에서 `--github` 또는 `--local` 플래그를 탐색한다. 발견하면 인자에서 제거한다.
   - `--github`: GitHub 연동 강제 활성화
   - `--local`: GitHub 연동 강제 비활성화
2. 플래그가 없으면 `rd-workflow/config/workflow.json`의 `fr_github` 값을 읽는다.
3. 파일이 없거나 `fr_github` 키가 없으면 기본값 `false` (연동 비활성).
4. GitHub 연동 활성화 시 전제조건을 검증한다:
   - `gh` CLI 설치 여부 — 미설치: "gh CLI가 설치되어 있지 않습니다" 출력 후 종료
   - `gh auth status` 통과 여부 — 미인증: "gh auth login으로 인증이 필요합니다" 출력 후 종료
   - `gh repo view` 성공 여부 — 실패: "git remote가 설정되지 않았거나 Issues가 비활성화되어 있습니다" 출력 후 종료
5. 검증 실패 시 로컬 fallback 없이 종료한다.
6. `pull`, `push`, `sync` 서브커맨드는 `fr_github` 설정과 무관하게 항상 전제조건 검증을 실행한다.

이후 각 서브커맨드는 결정된 연동 여부에 따라 동작한다.

---

## GitHub 공통 사항

### Label 체계

- **status**: `fr:idea`, `fr:validated`, `fr:ready-for-request`
- **종료**: `fr:done`, `fr:dropped`
- **kind**: `fr:feature`, `fr:bug`, `fr:refactor`, `fr:tech-debt`, `fr:tooling`, `fr:research`, `fr:test`
- **priority**: 사용하지 않음 (pri는 로컬 전용)

`fr:` namespace를 FR 전용으로 사용한다. 기존 repo에 `fr:*` label이 있으면 충돌 가능 — pull은 status label 필수 조건으로 완화된다.

### 에러 처리

| 상황 | 메시지 | 동작 |
|------|--------|------|
| gh 미설치 | "gh CLI가 설치되어 있지 않습니다" | 종료 |
| gh 미인증 | "gh auth login으로 인증이 필요합니다" | 종료 |
| repo 미연결 | "git remote가 설정되지 않았습니다" | 종료 |
| Issues 비활성 | "이 저장소에서 Issues가 비활성화되어 있습니다" | 종료 |
| status label 생성 실패 | "fr:{status} label 생성 실패 — Issue 생성 중단" | **에러, 해당 항목 중단** |
| kind label 생성 실패 | "fr:{kind} label 생성 실패" | 경고, label 없이 진행 |
| Issue 생성 실패 | "GitHub Issue 생성 실패" | add: 로컬 유지+경고, push: 건너뜀+경고 |

### 데이터 분리

- 로컬과 GitHub는 독립 저장소이다. 연결은 인덱스의 GitHub 컬럼과 상세 파일의 `github-issue` 필드 양쪽에서 추적한다.
- 연동을 비활성화해도 기존 `github-issue` 필드는 유지한다 (삭제 안 함).
- 사용자 안내: "GitHub 연동을 비활성화하면 로컬 데이터만 표시됩니다. GitHub Issues는 별도로 관리해야 합니다."

---

## 전역 규칙

- `priority` 허용 값: `P1`, `P2`, `P3`, `-` 만 허용. 인덱스에서만 관리하고 상세 파일에는 넣지 않는다.
- `/fr add`는 FR 등록만 한다. REQUEST.md 작성, 구현 착수 금지.
- 서브커맨드가 없거나 알 수 없으면 사용법만 출력하고 종료한다. 파일 수정 없음.
- `github-issue`는 인덱스(GitHub 컬럼)와 상세 파일 양쪽에서 관리한다. 연결/해제 시 양쪽 모두 갱신한다.
- pull/push/sync는 `fr_github` 설정과 무관하게 `--github` 플래그 없이도 실행 가능하다 (항상 전제조건 검증 실행).
