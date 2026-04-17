## /fr sync

연결된 항목의 status를 동기화한다. **v1은 status만 동기화한다.** title/body/kind 등 비-status 필드는 동기화하지 않는다. **GitHub 전제조건 검증 필수.**

### 절차

1. 백엔드 전제조건 검증을 실행한다 (백엔드 결정 §4와 동일).
2. 인덱스의 GitHub 컬럼이 `-`가 아닌 로컬 FR을 전체 수집한다.
3. 각 항목의 GitHub Issue 현재 상태를 조회한다:
   - `gh issue view {number} --json state,labels`
4. 로컬 status와 GitHub 상태를 비교한다:
   - **GitHub closed + 로컬 활성** → 사용자에게 질문: "#{N} {title}이 GitHub에서 close됨. 로컬 상태를 변경할까요? (a) done (b) dropped (c) 무시"
     - (a) 선택 시: 로컬 status를 `done`으로 변경 + 인덱스에서 삭제
     - (b) 선택 시: 로컬 status를 `dropped`으로 변경 + 인덱스에서 삭제
   - **로컬 done/dropped + GitHub open** → 기존 active status label(`fr:idea` 등)을 제거한 뒤 `fr:done` 또는 `fr:dropped` label을 부여하고 Issue를 close한다.
   - **양쪽 모두 활성 + status label 불일치** → 사용자에게 질문: "#{N} {title}: 로컬은 `{local_status}`, GitHub은 `{gh_status}`. 어느 쪽을 따를까요? (a) 로컬 유지, GitHub 갱신 (b) GitHub 따름, 로컬 갱신 (c) 무시"
     - (a) 선택 시: GitHub의 기존 status label 제거 + 로컬 status에 맞는 `fr:{status}` label 부여
     - (b) 선택 시: 로컬 상세 파일 status 변경 + 인덱스 status 컬럼 갱신
   - **일치** → 건너뜀
5. 결과 테이블을 출력한다:

| 제목 | 로컬 | GitHub | 결과 |

결과 값: `일치` / `로컬→GitHub` / `GitHub→로컬` / `무시` / `done` / `dropped`

### 규칙

- 연결된 항목이 0건이면 "동기화할 연결된 항목이 없습니다" 출력 후 종료.
- **status label이 0개인 GitHub Issue**: "#{N} {title}: status label 없음" 경고 출력 후 건너뜀.
- **status label이 2개 이상인 GitHub Issue**: 첫 번째로 발견된 status label을 사용하고 경고 출력.
- GitHub API 호출 실패 시 해당 항목을 건너뛰고 경고를 출력한다. 다른 항목의 처리는 계속한다.
- done/dropped 처리 시 인덱스에서 행을 삭제하는 것은 기존 FR 워크플로의 done/dropped 규칙을 따른다.
