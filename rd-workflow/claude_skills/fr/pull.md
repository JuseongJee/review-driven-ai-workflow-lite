## /fr pull

GitHub Issues를 로컬 FR로 가져온다. **GitHub 전제조건 검증 필수.**

### 절차

1. 백엔드 전제조건 검증을 실행한다 (백엔드 결정 §4와 동일).
2. 활성 status label별로 개별 조회한다:
   - `gh issue list --label "fr:idea" --state open --json number,title,body,labels,createdAt`
   - `gh issue list --label "fr:validated" --state open --json number,title,body,labels,createdAt`
   - `gh issue list --label "fr:ready-for-request" --state open --json number,title,body,labels,createdAt`
3. 결과를 병합하고 issue number 기준으로 중복을 제거한다.
4. 인덱스의 GitHub 컬럼을 확인하여 이미 연결된 항목(`-`가 아닌 값)을 제외한다.
5. 남은 후보 각각에 대해 title 완전 일치 감지를 수행한다:
   - 후보 issue title을 kebab-case로 정규화한 뒤 기존 로컬 FR의 short-title과 **완전 일치만** 비교한다 (fuzzy/포함 관계는 v1 미지원).
   - 일치 항목 발견 시 사용자에게 질문한다:
     - (a) 기존 로컬 FR `{short-title}`에 연결
     - (b) 새 로컬 FR로 생성
     - (c) 건너뜀
   - 유사 항목이 없으면 새 로컬 FR로 생성한다.
6. 생성/연결 처리:
   - **새 생성**: issue body에서 summary, kind 등을 추출하여 `items/YYYY-MM-DD-{short-title}.md` 생성. status는 GitHub의 status label에서 읽은 값을 사용한다 (`fr:validated` → `validated`). `FUTURE_REQUESTS.md` 인덱스에 행 추가 시 해당 status, 우선순위 기본값 `-`, GitHub 컬럼에 `owner/repo#N`을 사용. 상세 파일에도 `github-issue: owner/repo#N` 기록.
   - **연결**: 기존 상세 파일의 `github-issue: -` 값을 `github-issue: owner/repo#N`으로 변경하고, 인덱스의 GitHub 컬럼도 `owner/repo#N`으로 갱신한다. GitHub status label이 로컬 status와 다르면 로컬 상세 파일의 status와 인덱스 status 컬럼도 GitHub 값으로 갱신한다.
7. 완료 메시지 출력: "pull 완료: 생성 N건, 연결 N건, 건너뜀 N건"

### 규칙

- 대상은 status label(`fr:idea`, `fr:validated`, `fr:ready-for-request`) 중 하나 이상이 있는 open issues만. `fr:` 접두어만 있고 status label이 없는 issue는 무시한다.
- **status label이 2개 이상인 issue**: 첫 번째로 발견된 status label을 사용하고 "status label이 복수입니다: {labels}" 경고를 출력한다.
- 로컬 상세 파일 생성 시 `/fr add`의 상세 파일 형식을 따른다.
- issue body 파싱이 불완전해도 최소한 summary(= issue title)와 status(= label에서 추출)는 기록한다.
