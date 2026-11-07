# 변경 이력

템플릿을 쓰는 사람이 체감하는 큰 변화만 적습니다. 절 제목은 발행 VERSION 입니다.

- **읽는 법**: 내 프로젝트의 `rd-workflow/VERSION` 값보다 뒤에 있는 절이 `/tpl update` 로 새로 받는 변화입니다. lite 배포본의 VERSION 은 앞에 `lite-` 가 붙습니다.
- **넣는 것**: 새 skill·명령, 기존 명령·절차의 동작 변경, 설정 키·파일 위치 변경, 마이그레이션이 필요한 변경, 기본값 변경.
- **빼는 것**: 내부 테스트, 리팩터, 템플릿 개발 저장소 전용 도구, 문구 수정.
- lite 배포본에 없는 skill·확장의 변화도 함께 적습니다. lite 에 없는 항목은 「(full)」 로 표시합니다.
- 구조 전환 절차(옛 `ai/` 폴더 등)는 [`MIGRATIONS.md`](MIGRATIONS.md) 에 있습니다.

<!-- 관리 규칙(템플릿 개발 저장소): 발행 전에 마지막 VERSION 이후 완료 보고의 「사용자에게 달라진 것」 절에서 골라 `## 다음 발행` 절에 적습니다. 발행 스크립트가 이 제목을 새 VERSION 으로 바꿉니다. -->

## 2026-11-08-065139

- **`/fr do` 추가**: 여러 FR 을 한 번에 처리하는 진입점입니다. `/fr do [<slug들>]` 는 대화형으로 FR 마다 줄기(세션)를 띄워 동시에 진행하고, `/fr do --headless [--finish push|merge|none] [<slug들>]` 는 무인으로 순서대로 완주합니다. 대화형의 동시 줄기 수 상한은 `workflow.json` 의 새 키 `fr_do_max_streams`(기본 `4`)로 정합니다.
- **`/fr batch` 별칭화**: `/fr batch` 는 `/fr do --headless` 로 바뀌었습니다. 이번 발행까지 별칭으로 동작하고 다음 발행에서 없어집니다.
- **batch manifest 폐지**: `rd-workflow-workspace/.batch-manifest.json` 과 `scripts/batch/` 의 `batch_manifest.sh`·`headless_result.sh` 를 없앴습니다. `fr_relations.sh batch-draft` 도 없앴습니다. 처리 대상은 slug 목록으로 지정합니다.
- **`resume_candidates.sh` 경로 이동**: `scripts/batch/resume_candidates.sh` 가 `scripts/resume_candidates.sh` 로 옮겨졌습니다.
- **후속 FR 확인**: REQUEST `## Constraints` 에 범위 밖 후속을 `- 후속 FR: <slug> — <설명>` 으로 적으면, `archive.sh` 가 등록되지 않은 slug 를 `archive: 후속 FR 확인` 경고로 알립니다. Source FR 과 서로 언급하는 dropped FR 이 있으면 `archive: 흡수 확인` 을 냅니다. 발행은 막지 않습니다. final diff review 의 최종 출력에도 같은 확인이 들어갑니다.
- **submodule 저장소의 promote·정리**: `.gitmodules` 가 있으면 promote 가 새 worktree 의 submodule 을 중첩까지 초기화합니다. 실패해도 착수는 끝나고 복구 명령을 안내합니다. 원격 tag 로 닿는 submodule 커밋은 worktree 정리에서 더 이상 「원격에 없는 커밋」 으로 보류되지 않습니다.
- **로캘과 무관한 FR 인덱스 처리**: 한글 collation 이 없는 로캘(`en_US.UTF-8` 등)에서도 `rd task fr-done`·`/fr add` 가 인덱스 칸을 바르게 찾습니다.
- **작업 색인이 막을 때 안내**: 작업 색인이 있는 저장소의 기본 브랜치에서 `rd task` 쓰기가 거부되면, 색인 경로·원인·복구 방법을 함께 보입니다.
- **손으로 띄운 세션 기록**: 자동 기동이 실패한(`launch=failed`) 작업도 `rd task resolve-launch <slug>` 로 손 기동 세션을 확정할 수 있습니다. 자동 기동 실패 안내가 이 방법을 알립니다. 확인 중 색인이 바뀌었거나 저장이 실패하면 확정했다고 보고하지 않고 다시 실행할 명령을 안내합니다. 세션이 살아 있으면 `promote_rollback.sh` 가 worktree 를 지우지 않습니다(`--force` 는 경고 후 계속).
- **리뷰 인용 경고 정확도**: 리뷰어 턴 뒤의 `cite-mismatch` 경고가 맞는 인용에는 나오지 않습니다. 리뷰어는 재현 명령과 출력을 `## Reproduction` 절에 적습니다.

## 2026-11-07-210251

- **팀 overlay 가이드**: rd-workflow 가 없는 기존 팀 저장소 클론을 새로 clone 하지 않고 overlay 아래로 옮겨 submodule 로 등록하는 짧은 경로를 이관 가이드에 더했습니다(브랜치·stash·미커밋 작업 유지). 예시 이름을 overlay `rd-myproject` 아래 submodule `myproject` 로 맞추고, 기존 클론 안의 세션에서 진행하지 말고 끝나면 overlay 루트에서 새 세션을 띄우라는 실행 위치 안내를 넣었습니다.

## 2026-11-07-201215

- 이 변경 이력(`rd-workflow/CHANGELOG.md`)을 새로 두었습니다. 배포 README 첫 화면에 최근 세 발행의 변화가 나옵니다.
- **리뷰 턴 넘기기**: Author 턴 파일을 쓴 뒤 `run_review_turn.sh <세션>` 한 줄이면 Reviewer 턴이 돕니다. SESSION 의 Status·Owner 를 손으로 바꾸지 않습니다. 넘길 수 없는 상태면 다음 행동을 안내합니다.
- **리뷰 종결 근거**: 사람이 남은 이의를 덮고 종결하면 `## Closure Reason` 의 `user-override` 아래에 `근거: <날짜> <결정한 사람> — <한 말>` 줄을 적어야 `rd review seal` 이 통과합니다. 자율 모드는 `user-override` 를 스스로 정하지 않고 `awaiting-user` 로 멈춥니다.
- **리뷰 실행 기록**: `rd review seal` 이 리뷰어 턴 실행 기록(`reviewer_runs.tsv`)을 대조합니다. 리뷰어 턴을 돌리지 않은 세션과 이의를 손으로 지운 세션을 거부합니다.
- **리뷰 발견 형식**: 리뷰어는 발견마다 `[confidence N/10]` 과 `경로:줄` 인용을 붙입니다. 프로젝트 리뷰 표준 파일 `rd-workflow-workspace/review-standards.md` 를 새로 둡니다. 내용이 있으면 diff review 리뷰어와 standard 구현이 읽습니다.
- **완료 보고 양식**: completion report 와 autopilot 보고가 「사용자에게 달라진 것」 절로 시작하고 「정리 후보」 절로 끝납니다.
- **자기 worktree 삭제 차단**: 세션 안에서 자기 작업 worktree 를 지우는 명령을 막고 정리 명령(`rd task list`)을 안내합니다.
- **archive 안전**: 살아 있는 세션의 worktree 를 지우지 않고 정리 잔여로 남깁니다. submodule 커밋을 빠뜨린 병합은 기본 브랜치를 바꾸기 전에 멈춥니다.
- **FR status 읽기**: `- status: done (설명)` 과 옛 키 `- 상태:` 를 모든 FR 도구가 같은 규칙으로 읽습니다. 아카이브 커밋 게이트가 막을 때 FR 마다 판정 값과 원문을 보입니다.
- **무인 실행 발행**(full): `ralph_drain.sh`·`/fr batch` 의 발행을 wrapper 가 맡고 로그를 남깁니다. 실패는 `publish-failed`·`publish-incomplete`·`publish-unsafe` 로 나뉩니다. 발행 단계는 기본 30분 상한이 있습니다(`RD_PUBLISH_WALL_MINUTES`, `loop-guard.json` 의 `publish_wall_minutes`).
- **무인 실행 비용**(full): 무인 실행 출력에 실행 비용·토큰·소요 시간 줄이 나옵니다. `/fr batch`·`ralph_drain.sh` 요약에 합계가 나옵니다.
- **verify 설정 점검**(full): `verify.sh --check` 가 덜 채운 설정(TODO, 필수 환경 변수 미설정, 실행 대상 0개)을 나열합니다. `/tpl status` 에 `verify:` 줄이 나옵니다. verifier 에 `requires_env` 필드가 생겼습니다.
- **`/tpl update` 와 verify 프리셋**(full): 기존 verifier 에 없는 `requires_env` 를 템플릿 값으로 채웁니다. 사용자가 지운 프리셋 verifier 를 다시 넣지 않습니다(`extensions.verify.seen_verifiers`).
- **마이그레이션**: settings.json 의 권한 허용 10건(M015), gate hook 감시 항목(M003)이 sync 때 더해집니다. M003·M005·M015 는 저장에 실패하면 원본을 두고 실패를 알립니다.
- **권한 허용 배포**: 템플릿 settings 가 리뷰·검증 스크립트 실행을 권한 확인 없이 허용합니다. 발행·archive·`rd` 는 지금처럼 확인을 받습니다.
- **hook 실패 알림**: gate hook 파일이 없거나 읽을 수 없으면 화면과 모델 문맥에 경고합니다.
- **설계 중 시제품**: 실행해 봐야 답이 나오는 동작 질문을 일회용 시제품 worktree 로 확인하는 절차가 `WORKFLOW.md` 에 생겼습니다. `PROJECT_CONTEXT.md` 에 `## Run`·`## Feature Entry Paths` 절이 생겼고 `/tpl status` 가 작성 여부를 보입니다(full).
- **`/tpl update` 변경 이력**: update 완료 보고 끝에 이전 VERSION 뒤의 CHANGELOG 절이 나옵니다. 항목이 40개를 넘으면 가장 최근 절만 전문으로 보입니다. 이전 VERSION 을 모르거나 같은 버전을 다시 받으면 한 줄로 알립니다.
- **판단 원칙 규칙**: `.claude/rules/rd-workflow/judgment.md` 가 새로 로드됩니다. root cause 우선, 테스트 편의를 위한 production 변경 금지, 사용자 편의 우선을 따릅니다.
- **AI 등급 하향**: AI 가 근거를 `## Risk Tier` 이력에 적고 등급을 내릴 수 있습니다. 되돌리기 어려운 효과가 있으면 `full` 로 고정됩니다. `rd task set-status "구현 중"` 이 리뷰 단계(`REQUEST review 대기`·`spec/plan 작성 중`·`spec/plan review 대기`)에서 바로 통과합니다. 템플릿 규칙 합계가 약 1,000자 줄었습니다.
- **standard 절차 안내**: `/small-task-implement`·`/final-diff-review` 가 `구현 중 → 검증 중 → diff review 대기` 순서와, 증거 기록·리뷰 세션 전에 작업물을 커밋하라고 안내합니다.
- **FR 인덱스 병합**: 한 FR 행의 서로 다른 칸을 양쪽이 바꿔도 발행이 멈추지 않습니다. 같은 칸을 다르게 바꾸면 멈추고 풀어야 할 칸을 알립니다.
- **FR 폐기 마감**: FR 을 폐기로 닫을 때는 `/fr status <slug> dropped` 뒤 `fr-done` 을 부릅니다. `/fr status` 로 종료하면 그 FR 의 raw capture 를 `raw-captures/archive/` 로 옮깁니다.
- **발행 큐 우회 옵션**: `rd publish request --allow-gitlink-drop '<사유>' --basis '<근거>'`(또는 `--force-skip-review-check`)로 archive 우회를 요청합니다. 잘못된 인자는 종료 코드 2 로 거부합니다. 호출 세션의 `status`·`watch`·`next` 가 우회 사유와 근거를 보입니다.
- **발행 실패 사유**: `rd publish run` 이 실패하면 부하와 상관없이 실패 사유에 archive 의 마지막 출력 줄이 남습니다. 출력 기록이 늦으면 대기 안내와 전체 로그 경로가 나옵니다.
- **hook 입력 해석**: jq 가 없어도 hook 이 이스케이프된 경로·명령 값을 jq 와 같게 읽습니다. 해석할 수 없는 값은 막습니다.
- **리뷰 기준**: diff review 리뷰어가 새·변경 셸 테스트를 macOS 기본 PATH 로 한 번 실행합니다.
- **리뷰 진행 줄**: C 로캘에서 Claude 리뷰어 진행 줄을 글자 경계에서 자릅니다.
- **lite 보완**: lite 의 세션 시작 화면에 진행 중 작업 표와 `rd task list` 안내가 나옵니다. lite autopilot 리뷰 턴의 `command not found: build_attempt_history` 를 고쳤습니다. lite 설치 직후 `self_test.sh consumer` 가 통과합니다. `subagent-git-safety.md` 가 lite 에 들어갑니다.
- **`/fr batch` 재개**(full): 신호로 멈춘 batch 를 다시 돌리면 재개 확인에 판정 불가 사유가 보입니다. batch 밖 의존 FR 때문에 착수할 수 없는 FR 은 `blocked` 로 기록하고 독립 FR 은 계속합니다.
- **`/fr batch` 원격 시간 상한**(full): 원격 조회가 30초 안에 응답하지 않으면 batch 를 `paused` 로 멈추고 `remote-timeout` 을 남깁니다. `RD_BATCH_REMOTE_TIMEOUT`(1~600초)으로 바꿉니다.

## 2026-11-04-203832

2026-11-01-202303 이후의 변화입니다. 같은 날 앞선 발행(2026-11-04-101302 ~ 195042)의 변화도 여기에 있습니다.

- **발행 요청 큐**: promote 로 띄운 작업 세션이 호출 세션에 발행을 요청합니다(`rd publish request·wait·run`). 지연 정리(`rd task list`)가 세션이 끝난 작업 탭을 닫습니다.
- **herdr app 기동**: promote 가 herdr app 안에서도 작업 세션을 자동으로 띄웁니다.
- **세션 이름 충돌 거부**: promote 가 다른 작업과 세션 이름이 같은 slug 를 거부합니다.
- **`rd task set-status`**: 커밋할 파일을 알립니다. `rd task guard --dry-run` 이 생겼습니다.
- **seal 위치**: seal 뒤 fr 브랜치에 기본 브랜치를 병합하면 seal 이 깨집니다. 문서가 그 순서를 안내합니다.
- **submodule 저장소**: 제품 코드가 submodule 안에 있어도 seal·발행·worktree 정리가 끝까지 돕니다.
- **sync 보존 규칙**: `/tpl update` 가 행이 있는 표 파일(FUTURE_REQUESTS·PARKED·tier-log)과 템플릿 본이 아닌 REQUEST·CURRENT_TASK 를 보존합니다.
- **`prepare_review_pipeline.sh diff main`**: 리뷰한 커밋을 고정한 세션을 만듭니다. `rd review seal <세션 이름>` 이 표준 위치에서 세션을 찾습니다.
- **병렬 발행 충돌**: `archive.sh` 가 `verify-evidence` 충돌을 자동으로 풉니다.
- **세션 기동 대기**: promote 가 기동이 느린 세션에도 시작 프롬프트를 전달합니다(`RD_LAUNCH_START_TIMEOUT` 기본 60초). autopilot 이 승격한 자식 세션에 autopilot 지시를 넘깁니다.
- **FR 인덱스 칸**: 맨 앞에 칸을 더한 FR 인덱스에서도 `/fr add` 등록 커밋이 성공합니다.

## 2026-11-01-202303

2026-10-27-004054 이후의 변화입니다.

- **`promote.sh --handoff <file>`**: 호출 세션이 확정한 결정을 기동 전에 worktree 의 `handoff.md` 로 넘깁니다.
- **미커밋 문서 이관**: promote 가 호출한 체크아웃에 남은 이 작업의 REQUEST·spec·plan·리뷰 세션을 fr 브랜치로 옮깁니다.
- **지연 정리**: 작업 worktree 안에서 `archive.sh` 를 불러도 됩니다. 남은 worktree·브랜치는 기본 체크아웃의 `rd task list` 가 안전할 때 지웁니다.
- **seal 의 검증 증거**: `rd review seal` 이 `verify_record.sh` 로 남긴 새 검증 증거를 요구합니다.
- **리뷰 응답 언어**: `workflow.json` 의 `review_response_language` 로 리뷰 턴 언어를 정합니다(기본 한국어). seal 거부 때 사유별 복구 안내가 나옵니다.
- **리뷰 어댑터 실패 진단**: 원인(로그 끝 오류 줄)과 세션 안전성을 따로 보입니다. 설정을 영구히 바꾸라고 안내하지 않습니다.
- **리뷰 턴 중단**: `run_review_turn.sh` 가 신호를 받으면 어댑터를 정리하고 128+n 으로 끝납니다. codex 가 TERM 을 무시해도 리뷰 턴이 멈추지 않습니다.
- **Status 전이**: 리뷰 종결 뒤에도 Status `구현 중`·`검증 중` 이면 커밋을 허용합니다. `아카이브 보류 → 검증 중` 전이가 생겼습니다. spec/plan 구간에 `구현 대기` 단계가 보입니다.
- **archive 자동 해소**: 병합 충돌이 `stage_metrics.tsv`·`FUTURE_REQUESTS.md`·`CURRENT_TASK.md` 안에만 있으면 자동으로 풉니다.
- **무인 실행 시간 상한**(full): `autopilot_headless.sh` 1회 호출에 기본 240분 상한이 있습니다(`RD_FR_WALL_MINUTES`). 무인 재개가 진행 중인 fr worktree 를 찾습니다.
- **압축 뒤 autopilot**: 컨텍스트 압축 뒤 SessionStart 훅이 autopilot 규칙을 다시 읽으라고 안내합니다.

## 그 이전

2026-10-27-004054 이전 발행은 이 파일에 기록하지 않았습니다. 구조 전환이 필요한 변화는 [`MIGRATIONS.md`](MIGRATIONS.md) 를 봅니다.
