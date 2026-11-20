## /fr push

내 로컬 FR 을 팀 GitHub Issue 로 넘깁니다. 넘긴 FR 은 `handed-off` 로 닫힙니다. **GitHub 전제조건 검증 필수. 외부 저장소에 기록을 남기므로 사용자의 명시 요청이 있을 때만 실행합니다.**

### 호출 형식

- `/fr push` — 미연결 활성 FR 목록을 보이고 사용자가 고르게 합니다.
- `/fr push <short-title>` — 특정 항목만
- `/fr push --repo <owner/repo>` — 대상 저장소를 지정합니다.

### 절차

1. 백엔드 전제조건 검증을 실행합니다 (SKILL.md 「백엔드 결정」 4항). `--repo` 가 있으면 대상 저장소 결정 검사는 건너뜁니다 — 자동 탐색이 실패하는 저장소에서 명시한 대상으로 넘기는 경로입니다.
2. 대상을 수집합니다.
   - **인자 있음**: 인덱스에서 해당 short-title 의 GitHub 칸을 확인합니다. 이미 연결되어 있으면 "이미 GitHub Issue 에 연결되어 있습니다: {값}" 을 출력하고 종료합니다.
   - **인자 없음**: GitHub 칸이 `-` 인 활성(idea·validated·ready-for-request) FR 목록을 표시하고 사용자 선택을 기다립니다. `blocked` 는 제외합니다.
3. 대상 저장소를 정합니다.
   - `--repo` 가 있으면 그 값을 씁니다.
   - 없으면 `bash rd-workflow/scripts/issue_queue.sh repos --with-path` 를 실행합니다. 저장소가 하나면 그것입니다. 여럿(overlay)이면 FR 의 `related files` 경로 앞부분과 submodule 경로를 맞춰 하나로 정해지면 그것을 쓰고, 정해지지 않으면 후보 목록을 보이고 묻습니다. rc 3(대상 없음)이면 "대상 저장소를 정하지 못했습니다 — `--repo` 를 지정하거나 `issue_queue_repos` 를 설정하십시오" 를 알리고 종료합니다.
4. 본문 파일을 만듭니다. 내용은 상세 파일의 summary·why·related context·related files·not now because 입니다. 임시 파일에 씁니다.
5. 넘깁니다.

   ```bash
   bash rd-workflow/scripts/issue_queue.sh produce --repo <저장소> --label rd-handoff \
     --fingerprint "handoff:<fr-stem>" --title "<short-title>" --body-file <본문 파일>
   ```

   `fr-stem` 은 상세 파일 이름에서 `.md` 를 뺀 값입니다. 중복 감지는 이 fingerprint 로 합니다. 같은 FR 을 다시 넘겨도 Issue 가 늘지 않습니다. 상태 라벨·kind 라벨은 달지 않습니다.
6. 결과로 분기합니다.

   | 출력 | 동작 |
   |---|---|
   | `created <url>` / `created <url> (이전: <old>)` | 아래 7번 |
   | `commented <url>` | 같은 FR 의 열린 Issue 에 새 본문을 댓글로 달았습니다. 아래 7번 |
   | `skipped <url>` | 팀이 같은 내용을 not planned 로 닫았다는 뜻입니다. FR 을 그대로 두고 그 URL 을 알립니다 |
   | rc 7 | 원격 조회·생성 실패입니다. FR 을 바꾸지 않고 stderr 를 그대로 보이고 건너뜁니다. 다른 항목은 계속합니다 |

7. 성공하면 상세의 `github-issue: -` 를 `github-issue: <저장소>#<번호>` 로 바꾸고 FR 을 닫습니다.
   - 인덱스 행을 삭제합니다.
   - 상세에 `status: handed-off` 와 `status note: <url> 로 넘김` 을 씁니다.
   - 이 상태는 `/fr push` 로만 만들어집니다.
   - 행을 지운 뒤 `bash rd-workflow/scripts/rd task archive-captures --stages fr --title <short-title>` 로 `fr` stage raw capture 를 `raw-captures/archive/` 로 옮깁니다 (매칭 0건이면 그대로 지나갑니다). 이동이 실패해도 넘김은 유지하고 실패 사실과 이 명령 전문을 알립니다.
8. 완료 메시지를 출력합니다: "push 완료: 넘김 N건, 건너뜀 N건" 과 각 Issue URL.

### 규칙

- GitHub 칸이 `-` 가 아닌 항목은 대상에서 제외합니다.
- 대상이 0건이면 "넘길 미연결 활성 항목이 없습니다" 를 출력하고 종료합니다.
- 한 항목이 실패해도 다른 항목의 처리는 계속합니다.

### 결함 보고 전달

결함 보고 파일 전달은 위 FR push 절차와는 **다른 경로**입니다. FR Issue 가 아니라 `bash rd-workflow/scripts/defect_reports.sh` 를 사용하며, 라벨은 `defect-report` 를 씁니다. 상세 규약은 `rd-workflow/docs/guides/workflow-defect-reporting.md` 를 참조하십시오.

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
