## /fr push

로컬 FR을 GitHub Issue로 내보낸다. **GitHub 전제조건 검증 필수.**

### 호출 형식

- `/fr push` — 미연결 활성 FR 전체 대상 (목록 표시 후 사용자 확인)
- `/fr push <short-title>` — 특정 항목만

### 절차

1. 백엔드 전제조건 검증을 실행한다 (백엔드 결정 §4와 동일).
2. 대상을 수집한다:
   - **인자 있음**: 인덱스에서 해당 short-title의 GitHub 컬럼을 확인한다. 이미 연결되어 있으면 "이미 GitHub Issue에 연결되어 있습니다: {owner/repo#N}" 출력 후 종료.
   - **인자 없음**: 인덱스에서 GitHub 컬럼이 `-`인 활성(idea/validated/ready-for-request) FR 목록을 표시하고 사용자 확인을 기다린다.
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
   - **status label 생성 실패 → Issue 생성 중단, 에러 출력** (add와 동일 hard error)
   - kind label 생성 실패 → 경고 출력, kind label 없이 진행
5. 생성/연결 후 로컬 상세 파일의 `github-issue: -` 값을 `github-issue: owner/repo#N`으로 변경하고, 인덱스의 GitHub 컬럼도 `owner/repo#N`으로 갱신한다.
6. 완료 메시지 출력: "push 완료: 생성 N건, 연결 N건, 건너뜀 N건"

### 규칙

- 인덱스의 GitHub 컬럼이 `-`가 아닌 항목은 push 대상에서 제외한다.
- 대상이 0건이면 "push할 미연결 활성 항목이 없습니다" 출력 후 종료.
- Issue 생성 실패 시 해당 항목을 건너뛰고 경고를 출력한다. 다른 항목의 처리는 계속한다.
