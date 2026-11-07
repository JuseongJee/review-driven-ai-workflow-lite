## 발행 방법

- 발행은 제품의 발행 요청 큐로 합니다. `.claude/rules/rd-workflow/core.md` 「발행 승인」 과 `rd-workflow/docs/flows/AUTONOMY.md` 「종결 마커(seal)와 발행 승인」 절을 따릅니다. 요약: seal → 기록 커밋 → `bash rd-workflow/scripts/rd publish request` → `rd publish wait` 를 백그라운드로 실행 → 허가되면 `rd publish run`. 사용자에게 발행 승인을 묻지 않습니다(이 작업은 호출 세션이 있는 `caller` 경로입니다).
- `rd publish request` 가 종료 코드 10·11 을 내면(사용자 승인 대상) 그때만 사용자에게 묻습니다.
- `archive.sh` 의 자동 해소 대상은 `CURRENT_TASK.md`·`stage_metrics.tsv`·`FUTURE_REQUESTS.md`·`review-seals/verify-evidence` 네 파일입니다. 그 밖의 충돌이 예상되면(`git merge-tree --write-tree <기본 브랜치> HEAD`) 요청 대신 호출 세션에 충돌 보고를 보냅니다.

## 실행 규칙 (반드시 지킵니다)

- 검증·커밋·테스트 등록은 프로젝트 `CLAUDE.md` 의 검증·커밋 규칙을 따릅니다.
- **오래 걸리는 명령(전체 테스트, 리뷰 턴)은 `run_in_background` 와 로그 파일로 실행하고 `&` 로 직접 분리하지 않습니다.** 백그라운드 명령 끝의 `echo "exit=$?"` 는 알림 종료 코드를 `echo` 의 것으로 만드니 로그의 `exit=` 줄로 판단합니다.
- 시간 의존 단언이 한 번 실패하면 재실행으로 확인하고 보고에 적습니다.
- 테스트는 **임시 저장소와 로컬 bare 원격에서만** 시험합니다. 이 저장소에 시험용 worktree·브랜치를 만들지 않습니다. 새 회귀 단언은 변이를 주입해 FAIL 을 확인하고 출력을 남깁니다(`docs/guides/mutation-check.md`).
- **fr 브랜치에 기본 브랜치를 먼저 병합하지 않습니다**(seal 의 보호 트리 해시가 깨집니다).
- **리뷰 종결(seal) 뒤에는 `specs/`·`plans/`·`reports/verifications/` 를 고치지 않습니다.** 증거 파일은 `reports/reviews/` 에 둡니다. 마감 검증은 `verify_record.sh` 증거 기록을 거쳐야 `rd review seal` 이 통과합니다.
- **`rd task list` 를 실행하지 않습니다**(지연 정리는 호출 세션 몫). 상태 확인은 `rd task status` 나 `CURRENT_TASK.md` 로 합니다.
- **기본 체크아웃에 쓰기 전에 `MERGE_HEAD` 와 `git status` 를 확인합니다.**
- FR 상세의 설명을 사실로 받지 않습니다. 코드·git·실측으로 먼저 확인하고, 재현이 안 되면 추측으로 고치지 않고 보고합니다.
- 사용자 결정이 필요한 선택은 선택지마다 얻는 것·잃는 것을 풀어 써서 묻습니다(「1안」 같은 기호만으로 묻지 않습니다).
- 다른 세션이 만든 임시 파일·디렉터리·프로세스를 지우거나 멈추지 않습니다. 자기 것만 task ID·PID 로 정리합니다.
- 새로 발견한 별개 결함은 이 작업에 섞지 말고 마감 보고에 적어 호출 세션이 FR 로 등록하게 합니다.
- 컨텍스트가 80%에 가까우면 `CURRENT_TASK.md` 를 먼저 갱신합니다. 발행 전에 여유가 적으면 `/compact` 를 먼저 합니다.

## 호출 세션에 보내는 질문과 마감 보고

- **호출 세션(메인 체크아웃)의 입력창에 글을 보내지 않습니다.** `herdr agent prompt`·`pane send-text` 로 보내면 사람이 그 창에 치던 글 뒤에 붙어 섞입니다. 대신 아래 파일을 쓰고 턴을 끝내면 호출 세션의 감시가 가져갑니다.
  - 호출 세션이 정해야 할 질문: `{REPORTS}/<slug>-question.md`. 선택지마다 얻는 것·잃는 것을 적습니다. 다시 물을 때는 같은 파일을 덮어씁니다. 답은 호출 세션이 이 세션 입력으로 보냅니다.
  - 마감 보고: `{REPORTS}/<slug>-closing.md`. 행동마다 담당(받는 세션 / 호출 세션 / 사용자)과 발견한 징후(FR 후보)를 적습니다.
- 발행 결과는 큐가 호출 세션에 알립니다. 마감 보고는 발행을 마친 뒤 씁니다.
- worktree·로컬 브랜치·탭 정리는 호출 세션의 `rd task list` 가 하므로 이 세션은 지우지 않습니다. 마감 보고를 쓴 뒤 세션을 끝내도 됩니다.
