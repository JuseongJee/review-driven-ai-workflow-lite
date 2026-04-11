---
name: fr
description: >
  Manage future requests -- add, list, prioritize, sync with GitHub Issues.
  Subcommands: /fr add, /fr list, /fr pri, /fr pull, /fr push, /fr sync.
  Use when the user wants to manage backlog items.
user-invocable: true
disable-model-invocation: true
---

# FR -- Future Request 관리

Typical user requests:
- "/fr add autopilot에서 review gate 자동화"
- "/fr list"
- "/fr pri"
- "이거 FR에 넣어줘" -> `/fr add`로 라우팅
- "future request에 기록해줘" -> `/fr add`로 라우팅
- "FR 목록 보여줘" -> `/fr list`로 라우팅
- "FR 우선순위 검토해줘" -> `/fr pri`로 라우팅

사용자가 `/fr <subcommand> [args]` 형식으로 호출하거나, 위의 자연어 요청으로 호출한다.

## 서브커맨드 라우팅

첫 번째 인자를 파싱한다:

- `add` -> [/fr add](#fr-add) 섹션으로
- `list` -> [/fr list](#fr-list) 섹션으로
- `pri` -> [/fr pri](#fr-pri) 섹션으로
- `pull` -> [/fr pull](#fr-pull) 섹션으로
- `push` -> [/fr push](#fr-push) 섹션으로
- `sync` -> [/fr sync](#fr-sync) 섹션으로
- 그 외 / 인자 없음 -> 아래 사용법 출력 후 종료 (파일 수정 없음 보장)

**Legacy call 처리**: 첫 번째 단어가 `add`, `list`, `pri`, `pull`, `push`, `sync` 중 어느 것도 아니면 사용법 help를 출력한다. 파일을 절대 수정하지 않는다.

### 사용법 출력

```
/fr 사용법:
- `/fr add 내용` -- FR 등록
- `/fr list` -- 활성 항목 목록 출력
- `/fr pri` -- 우선순위 검토
- `/fr pull` -- GitHub Issues -> 로컬 FR 가져오기
- `/fr push [제목]` -- 로컬 FR -> GitHub Issue 내보내기
- `/fr sync` -- 연결된 항목 status 동기화

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
   - `gh` CLI 설치 여부 -- 미설치: "gh CLI가 설치되어 있지 않습니다" 출력 후 종료
   - `gh auth status` 통과 여부 -- 미인증: "gh auth login으로 인증이 필요합니다" 출력 후 종료
   - `gh repo view` 성공 여부 -- 실패: "git remote가 설정되지 않았거나 Issues가 비활성화되어 있습니다" 출력 후 종료
5. 검증 실패 시 로컬 fallback 없이 종료한다.
6. `pull`, `push`, `sync` 서브커맨드는 `fr_github` 설정과 무관하게 항상 전제조건 검증을 실행한다.

이후 각 서브커맨드는 결정된 연동 여부에 따라 동작한다.

---

## /fr add {#fr-add}

`add` 뒤의 텍스트를 입력으로 받아 Future Request를 등록한다.

### 절차 (local)

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기 (인덱스 형식 확인 + 중복 체크).
2. 입력에서 다음을 추출한다:
   - **short-title**: 영문 kebab-case, 간결하게 (예: `autopilot-review-gate`)
   - **summary**: 한국어 한두 문장 요약
   - **kind**: feature | bug | refactor | tech-debt | tooling | research | test (맥락에서 추론, 불확실하면 feature)
3. 상세 파일 생성: `rd-workflow-workspace/backlog/items/YYYY-MM-DD-{short-title}.md`

```md
# YYYY-MM-DD {short-title}
- status: idea
- kind: {kind}
- summary: {summary}
- why: {사용자 입력에서 추론, 없으면 "-"}
- related context: {대화 맥락에서 추론, 없으면 "-"}
- related files: {관련 파일, 없으면 "-"}
- not now because: {왜 지금 안 하는지, 없으면 "별도 작업으로 진행 예정"}
- revisit when: -
- github-issue: -
- request seed: {REQUEST로 만들 때 쓸 초안, 없으면 summary 반복}
```

4. `FUTURE_REQUESTS.md`의 `## 인덱스` 테이블 끝에 행 추가:

```
| {날짜} | {short-title} | {summary} | idea | - | [상세](items/YYYY-MM-DD-{short-title}.md) |
```

5. 완료 메시지 출력:

> FR 등록: **{short-title}** -- {summary}

### 규칙

- 같은 short-title이 인덱스에 이미 있거나 `items/` 에 같은 파일명이 존재하면 등록하지 않고 사용자에게 알린다. (done/dropped로 인덱스에서 삭제된 항목도 상세 파일이 남아있으므로 파일 존재 여부를 반드시 확인한다.)
- 입력이 너무 짧아서 summary를 만들 수 없으면 한 줄 질문으로 보충을 요청한다.
- FUTURE_REQUESTS.md의 기존 형식(테이블 구조, 상태 값)을 변경하지 않는다.
- 이 subcommand는 FR 등록만 한다. REQUEST.md 작성이나 실행은 하지 않는다.
- GitHub 연동 시 Issue 생성 실패가 로컬 FR 등록을 막지 않는다.

### GitHub 연동

GitHub 연동이 활성화되어 있을 때만 실행한다. local 절차 완료 후 추가로 실행한다.

1. `gh issue create` 실행:
   - title: short-title
   - body: 마크다운 포맷의 FR 상세 (summary, why, related context, related files, not now because)
   - labels: `fr:idea`, `fr:{kind}`
2. label이 repo에 없으면 `gh label create`로 생성을 시도한다.
   - **status label 생성 실패 -> Issue 생성 중단, 에러 출력**
   - kind label 생성 실패 -> 경고 출력, label 없이 진행
3. 성공 시 로컬 상세 파일의 `github-issue: -` 값을 `github-issue: owner/repo#N`으로 변경한다.
4. 완료 메시지에 issue URL을 포함한다.

Issue 생성 실패 시: 로컬 FR은 유지하고 "GitHub Issue 생성 실패, 로컬 FR만 등록됨" 경고를 출력한다.

---

## /fr list {#fr-list}

활성 FR 항목을 우선순위 순으로 출력한다. **읽기 전용 -- 파일 수정 없음.**

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 인덱스에서 status가 `idea` / `validated` / `ready-for-request` 인 항목만 추린다.
3. 인덱스의 우선순위 컬럼을 기준으로 정렬: P1 -> P2 -> P3 -> unranked (`-`). 동순위는 날짜 오름차순.
4. 결과 테이블 출력:

```
| # | 우선순위 | 날짜 | 제목 | 요약 | 상태 |
```

활성 항목이 0개이면: `활성 항목이 없습니다` 출력.

### GitHub 링크 표시

각 항목의 상세 파일에서 `github-issue` 필드를 읽는다.

출력 테이블에 `GitHub` 컬럼을 항상 포함한다:

```
| # | 우선순위 | 날짜 | 제목 | 요약 | 상태 | GitHub |
```

`github-issue` 값이 있으면 `owner/repo#N` 표시, 없거나 `-`이면 `-` 표시.
GitHub 컬럼은 항상 표시한다 (활성 항목에 연결이 하나도 없어도 생략하지 않음).

---

## /fr pri {#fr-pri}

활성 FR 항목의 우선순위를 AI가 평가하고 즉시 인덱스에 반영한다.

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 활성 항목(idea / validated / ready-for-request)의 인덱스 행에서 현재 우선순위를 확인하고, 상세 파일에서 `summary`, `why`, `related context`를 수집.
   - 상세 파일이 없으면 해당 항목을 건너뛰고 경고 출력.
3. `PROJECT_CONTEXT.md` 읽기 (맥락 기반 판단 기준으로 사용. REQUEST.md 사용 금지 -- 이 backlog는 전역 기준).
4. 다음 기준으로 각 항목에 P1 / P2 / P3 부여 + 한 줄 근거 작성. 기존 우선순위(P1/P2/P3)가 있는 항목도 재평가한다. 전체 평가를 먼저 완료한 뒤 Step 5에서 한 번에 반영한다:
   - 프로젝트 목표와의 관련성
   - 사용자 경험 / 안정성 영향도
   - 노력 대비 가치
   - 다른 항목과의 의존 관계
5. 전체 평가 완료 후 `FUTURE_REQUESTS.md` 인덱스의 우선순위 컬럼을 한 번에 업데이트한다. 건너뛴 항목의 우선순위는 변경하지 않는다. 인덱스 테이블 파싱/검증에 실패하면 어떤 행도 수정하지 않고 오류 메시지를 출력하며 종료한다.
6. 결과 테이블을 출력한다:

```
| 제목 | 이전 | 신규 | 근거 | 상태 |
```

상태 값: `반영` (정상 업데이트) / `건너뜀` (상세 파일 없음 등)

활성 항목이 0개이면: `검토할 활성 항목이 없습니다` 출력.

---

## /fr pull {#fr-pull}

GitHub Issues를 로컬 FR로 가져온다. **GitHub 전제조건 검증 필수.**

### 절차

1. 백엔드 전제조건 검증을 실행한다 (백엔드 결정 4와 동일).
2. 활성 status label별로 개별 조회한다:
   - `gh issue list --label "fr:idea" --state open --json number,title,body,labels,createdAt`
   - `gh issue list --label "fr:validated" --state open --json number,title,body,labels,createdAt`
   - `gh issue list --label "fr:ready-for-request" --state open --json number,title,body,labels,createdAt`
3. 결과를 병합하고 issue number 기준으로 중복을 제거한다.
4. 로컬 상세 파일(`items/*.md`)의 `github-issue` 필드를 확인하여 이미 연결된 항목을 제외한다.
5. 남은 후보 각각에 대해 title 완전 일치 감지를 수행한다:
   - 후보 issue title을 kebab-case로 정규화한 뒤 기존 로컬 FR의 short-title과 **완전 일치만** 비교한다 (fuzzy/포함 관계는 v1 미지원).
   - 일치 항목 발견 시 사용자에게 질문한다:
     - (a) 기존 로컬 FR `{short-title}`에 연결
     - (b) 새 로컬 FR로 생성
     - (c) 건너뜀
   - 유사 항목이 없으면 새 로컬 FR로 생성한다.
6. 생성/연결 처리:
   - **새 생성**: issue body에서 summary, kind 등을 추출하여 `items/YYYY-MM-DD-{short-title}.md` 생성. status는 GitHub의 status label에서 읽은 값을 사용한다 (`fr:validated` -> `validated`). `FUTURE_REQUESTS.md` 인덱스에 행 추가 시에도 해당 status와 우선순위 기본값 `-`를 사용. `github-issue: owner/repo#N` 기록.
   - **연결**: 기존 상세 파일의 `github-issue: -` 값을 `github-issue: owner/repo#N`으로 변경. GitHub status label이 로컬 status와 다르면 로컬 상세 파일의 status와 인덱스 status 컬럼도 GitHub 값으로 갱신한다.
7. 완료 메시지 출력: "pull 완료: 생성 N건, 연결 N건, 건너뜀 N건"

### 규칙

- 대상은 status label(`fr:idea`, `fr:validated`, `fr:ready-for-request`) 중 하나 이상이 있는 open issues만. `fr:` 접두어만 있고 status label이 없는 issue는 무시한다.
- **status label이 2개 이상인 issue**: 첫 번째로 발견된 status label을 사용하고 "status label이 복수입니다: {labels}" 경고를 출력한다.
- 로컬 상세 파일 생성 시 `/fr add`의 상세 파일 형식을 따른다.
- issue body 파싱이 불완전해도 최소한 summary(= issue title)와 status(= label에서 추출)는 기록한다.

---

## /fr push {#fr-push}

로컬 FR을 GitHub Issue로 내보낸다. **GitHub 전제조건 검증 필수.**

### 호출 형식

- `/fr push` -- 미연결 활성 FR 전체 대상 (목록 표시 후 사용자 확인)
- `/fr push <short-title>` -- 특정 항목만

### 절차

1. 백엔드 전제조건 검증을 실행한다 (백엔드 결정 4와 동일).
2. 대상을 수집한다:
   - **인자 있음**: 해당 short-title의 상세 파일을 확인하고 `github-issue` 필드가 없는지 검증한다. 이미 연결되어 있으면 "이미 GitHub Issue에 연결되어 있습니다: {owner/repo#N}" 출력 후 종료.
   - **인자 없음**: `github-issue` 필드가 없는 활성(idea/validated/ready-for-request) FR 목록을 표시하고 사용자 확인을 기다린다.
3. 대상 각각에 대해 중복 감지를 수행한다:
   - `gh issue list --search "{short-title} in:title" --state open --json number,title`로 **완전 일치** title issue를 검색한다.
   - 일치 issue 발견 시 사용자에게 질문한다:
     - (a) 기존 Issue `#{N} {title}`에 연결만
     - (b) 새 Issue 생성
     - (c) 건너뜀
   - 유사 issue가 없으면 새 Issue를 생성한다.
4. Issue 생성:
   - `gh issue create` 실행 (/fr add의 GitHub 연동과 동일 포맷)
   - title: short-title
   - body: 상세 파일의 summary, why, related context, related files, not now because
   - labels: 현재 status에 해당하는 `fr:{status}` + `fr:{kind}`
   - **status label 생성 실패 -> Issue 생성 중단, 에러 출력** (add와 동일 hard error)
   - kind label 생성 실패 -> 경고 출력, kind label 없이 진행
5. 생성/연결 후 로컬 상세 파일의 `github-issue: -` 값을 `github-issue: owner/repo#N`으로 변경한다.
6. 완료 메시지 출력: "push 완료: 생성 N건, 연결 N건, 건너뜀 N건"

### 규칙

- 이미 `github-issue` 필드가 있는 항목은 push 대상에서 제외한다.
- 대상이 0건이면 "push할 미연결 활성 항목이 없습니다" 출력 후 종료.
- Issue 생성 실패 시 해당 항목을 건너뛰고 경고를 출력한다. 다른 항목의 처리는 계속한다.

---

## /fr sync {#fr-sync}

연결된 항목의 status를 동기화한다. **v1은 status만 동기화한다.** title/body/kind 등 비-status 필드는 동기화하지 않는다. **GitHub 전제조건 검증 필수.**

### 절차

1. 백엔드 전제조건 검증을 실행한다 (백엔드 결정 4와 동일).
2. `github-issue` 필드가 있는 로컬 FR을 전체 수집한다.
3. 각 항목의 GitHub Issue 현재 상태를 조회한다:
   - `gh issue view {number} --json state,labels`
4. 로컬 status와 GitHub 상태를 비교한다:
   - **GitHub closed + 로컬 활성** -> 사용자에게 질문: "#{N} {title}이 GitHub에서 close됨. 로컬 상태를 변경할까요? (a) done (b) dropped (c) 무시"
     - (a) 선택 시: 로컬 status를 `done`으로 변경 + 인덱스에서 삭제
     - (b) 선택 시: 로컬 status를 `dropped`으로 변경 + 인덱스에서 삭제
   - **로컬 done/dropped + GitHub open** -> 기존 active status label(`fr:idea` 등)을 제거한 뒤 `fr:done` 또는 `fr:dropped` label을 부여하고 Issue를 close한다.
   - **양쪽 모두 활성 + status label 불일치** -> 사용자에게 질문: "#{N} {title}: 로컬은 `{local_status}`, GitHub은 `{gh_status}`. 어느 쪽을 따를까요? (a) 로컬 유지, GitHub 갱신 (b) GitHub 따름, 로컬 갱신 (c) 무시"
     - (a) 선택 시: GitHub의 기존 status label 제거 + 로컬 status에 맞는 `fr:{status}` label 부여
     - (b) 선택 시: 로컬 상세 파일 status 변경 + 인덱스 status 컬럼 갱신
   - **일치** -> 건너뜀
5. 결과 테이블을 출력한다:

| 제목 | 로컬 | GitHub | 결과 |

결과 값: `일치` / `로컬->GitHub` / `GitHub->로컬` / `무시` / `done` / `dropped`

### 규칙

- 연결된 항목이 0건이면 "동기화할 연결된 항목이 없습니다" 출력 후 종료.
- **status label이 0개인 GitHub Issue**: "#{N} {title}: status label 없음" 경고 출력 후 건너뜀.
- **status label이 2개 이상인 GitHub Issue**: 첫 번째로 발견된 status label을 사용하고 경고 출력.
- GitHub API 호출 실패 시 해당 항목을 건너뛰고 경고를 출력한다. 다른 항목의 처리는 계속한다.
- done/dropped 처리 시 인덱스에서 행을 삭제하는 것은 기존 FR 워크플로의 done/dropped 규칙을 따른다.

---

## GitHub 공통 사항

### Label 체계

- **status**: `fr:idea`, `fr:validated`, `fr:ready-for-request`
- **종료**: `fr:done`, `fr:dropped`
- **kind**: `fr:feature`, `fr:bug`, `fr:refactor`, `fr:tech-debt`, `fr:tooling`, `fr:research`, `fr:test`
- **priority**: 사용하지 않음 (pri는 로컬 전용)

`fr:` namespace를 FR 전용으로 사용한다. 기존 repo에 `fr:*` label이 있으면 충돌 가능 -- pull은 status label 필수 조건으로 완화된다.

### 에러 처리

| 상황 | 메시지 | 동작 |
|------|--------|------|
| gh 미설치 | "gh CLI가 설치되어 있지 않습니다" | 종료 |
| gh 미인증 | "gh auth login으로 인증이 필요합니다" | 종료 |
| repo 미연결 | "git remote가 설정되지 않았습니다" | 종료 |
| Issues 비활성 | "이 저장소에서 Issues가 비활성화되어 있습니다" | 종료 |
| status label 생성 실패 | "fr:{status} label 생성 실패 -- Issue 생성 중단" | **에러, 해당 항목 중단** |
| kind label 생성 실패 | "fr:{kind} label 생성 실패" | 경고, label 없이 진행 |
| Issue 생성 실패 | "GitHub Issue 생성 실패" | add: 로컬 유지+경고, push: 건너뜀+경고 |

### 데이터 분리

- 로컬과 GitHub는 독립 저장소이다. 연결은 상세 파일의 `github-issue` 필드로만 추적한다.
- 연동을 비활성화해도 기존 `github-issue` 필드는 유지한다 (삭제 안 함).
- 사용자 안내: "GitHub 연동을 비활성화하면 로컬 데이터만 표시됩니다. GitHub Issues는 별도로 관리해야 합니다."

---

## 전역 규칙

- `priority` 허용 값: `P1`, `P2`, `P3`, `-` 만 허용. 인덱스에서만 관리하고 상세 파일에는 넣지 않는다.
- `/fr add`는 FR 등록만 한다. REQUEST.md 작성, 실행 착수 금지.
- 서브커맨드가 없거나 알 수 없으면 사용법만 출력하고 종료한다. 파일 수정 없음.
- `github-issue` 필드는 상세 파일에서만 관리한다. 인덱스(`FUTURE_REQUESTS.md`)에는 추가하지 않는다.
- pull/push/sync는 `fr_github` 설정과 무관하게 `--github` 플래그 없이도 실행 가능하다 (항상 전제조건 검증 실행).
