## /fr push

로컬 FR을 GitHub Issue로 내보낸다. **GitHub 전제조건 검증 필수.**

### 호출 형식

- `/fr push` — 미연결 활성 FR 전체 대상 (목록 표시 후 사용자 확인)
- `/fr push <short-title>` — 특정 항목만
- `/fr push --repo <owner/repo>` — 대상 repo 를 지정해 내보냅니다 (미지정 시 현재 repo — 기존 동작)

### 절차

1. 백엔드 전제조건 검증을 실행한다 (백엔드 결정 §4와 동일).
2. 대상을 수집한다:
   - **인자 있음**: 인덱스에서 해당 short-title의 GitHub 컬럼을 확인한다. 이미 연결되어 있으면 "이미 GitHub Issue에 연결되어 있습니다: {owner/repo#N}" 출력 후 종료.
   - **인자 없음**: 인덱스에서 GitHub 컬럼이 `-`인 활성(idea/validated/ready-for-request; `blocked` 은 set-aside 상태로 제외) FR 목록을 표시하고 사용자 확인을 기다린다.
3. 대상 각각에 대해 중복 감지를 수행한다:
   - `gh issue list --search "{short-title} in:title" --state open --json number,title`로 **완전 일치** title issue를 검색한다. `--repo <target>` 지정 시 이 검색에도 같은 `--repo <target>` 을 전달한다 — **발행 대상과 검색 대상이 어긋나면 중복 감지가 무의미해져 대상 repo 에 중복 Issue 가 생긴다.**
   - 일치 issue 발견 시 사용자에게 질문한다:
     - (a) 기존 Issue `#{N} {title}`에 연결만
     - (b) 새 Issue 생성
     - (c) 건너뜀
   - 유사 issue가 없으면 새 Issue를 생성한다.
4. Issue 생성:
   - `gh issue create` 실행 (`--repo <target>` 지정 시 그 값을 전달 — 미지정 시 현재 repo, 기존 동작과 동일. /fr add의 GitHub 연동과 동일 포맷)
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

### 결함 보고 전달

결함 보고 파일 전달은 위 FR push 절차와는 **다른 경로**입니다. FR Issue 가 아니라 `bash rd-workflow/scripts/defect_reports.sh` 를 사용하며, 라벨도 `fr:*` 가 아니라 `defect-report` 를 씁니다. 상세 규약은 `rd-workflow/docs/guides/workflow-defect-reporting.md` 를 참조하십시오.

1. `bash rd-workflow/scripts/defect_reports.sh preview <file> [--upstream <target>]` 를 실행해 승인 화면(대상 host/repo·공개 여부·제목·라벨·본문 전체)을 출력합니다.
2. 출력 전체를 사용자에게 그대로 보여주고 발행 승인을 요청합니다.
3. 사용자가 승인하면 `bash rd-workflow/scripts/defect_reports.sh publish <file> [--upstream <target>] --yes` 를 실행합니다. 거절하면 발행하지 않고 미전달 상태로 둡니다.
4. **비대화형 실행에서는 `--yes` 를 붙이지 않습니다.** preview 결과만 보여주고 사람의 승인을 기다립니다.
5. 종료 코드가 0이 아니면 스크립트가 stderr 에 출력한 사유와 다음 행동을 **그대로** 사용자에게 전달합니다. 여러 건을 처리하는 중이면 실패한 건만 보류하고 나머지 건은 계속 처리합니다.
   - **재시도 명령을 직접 만들어 붙이지 않습니다.** 종료 코드마다 안전한 다음 행동이 다르며, 스크립트가 이미 그 코드에 맞는 안내를 출력합니다. 출력된 명령은 이번 실행이 실제로 겨냥한 대상(effective target)과 승인 상태를 보존하므로 **옵션을 빼거나 `--yes` 를 덧붙이지 않고 그대로** 전달합니다 — `--upstream` 을 빼면 config 가 바뀐 뒤 다른 저장소에 발행되고, `--yes` 를 덧붙이면 사용자가 승인 화면을 보지 못한 채 발행됩니다. 아래 셋은 일반 재시도가 **위험하거나 무의미**하므로 특히 주의하십시오.

   | 코드 | 안전한 다음 행동 |
   |---|---|
   | 8 (일치 Issue 2건 이상) | 재시도는 같은 모호함을 반복할 뿐입니다. 출력된 후보 중 하나를 사람이 고른 뒤 `defect_reports.sh set-issue <file> <고른-url>` 로 연결합니다 |
   | 10 (원격 생성 성공 + 역기록 실패) | 재시도하면 중복 Issue 가 생길 수 있습니다. 출력된 URL 로 `defect_reports.sh set-issue <file> <url>` 만 실행합니다 |
   | 11 (이전 시도 결과 불명) | 재실행 전에 **원격 확인이 먼저**입니다. 아래 7번을 따릅니다 |
6. **exit 0 이어도 stderr 에 경고가 있으면 그대로 전달합니다.** 예를 들어 `defect-report` 라벨 부착에 실패하면 Issue 는 생성됐지만 아직 정본 흡수 대상이 아니라는 경고가 함께 나옵니다 — 이 경고를 요약하거나 생략하면 사용자가 전달이 완전히 끝났다고 오해합니다.
7. **exit 11(이전 시도 결과 불명)은 재실행을 안내하지 않습니다.** 스크립트가 출력하는 원격 확인 절차를 그대로 보여주고 사람의 확인을 기다립니다. 확인 없이 `upstream-issue` 값을 임의로 되돌리면 중복 Issue 가 생길 수 있습니다.
