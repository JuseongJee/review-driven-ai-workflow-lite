# /tpl update

배포 repo에서 최신 템플릿을 가져와 프로젝트에 동기화합니다.

## 절차

`rd-workflow/docs/guides/sync_template.md` 의 절차를 순서대로 실행합니다. 아래는 흐름 요약이며, 단계별 출력 줄과 판단 항목 처리는 반드시 `sync_template.md` 를 읽고 따릅니다. 분류·복사·마이그레이션·재설치 규칙의 정본은 `sync_template.sh` 하위 명령입니다.

> **업그레이드 시점**: 진행 중 작업이 없을 때(`CURRENT_TASK.md` Status `대기 중`, 열린 review 세션 없음) 수행을 권장합니다. 진행 중 작업이 있으면 `sync_template.md` 0단계의 대처 절차를 따릅니다.

### 1. 배포 repo URL 확보

`PROJECT_CONTEXT.md`에서 `template_repo` 값을 읽습니다.

- 값이 있으면 그대로 사용합니다.
- 값이 비어있거나 placeholder면 사용자에게 한 번 물어보고, 답변을 `PROJECT_CONTEXT.md`의 `template_repo`에 저장합니다 (다음부터 묻지 않도록).

### 2. 이전 VERSION 기록과 버전 가드

`sync_template.md` 1단계 명령으로 프로젝트의 이전 VERSION 을 git 디렉터리 안 파일에 기록합니다. 그다음 로컬 `bash rd-workflow/scripts/sync_template.sh <URL>` 로 버전 가드를 통과시키고, 출력된 임시 clone 경로를 `C` 로 둡니다.

clone 의 `sync_template.md` 가 로컬 사본과 다르면 clone 쪽 문서를 읽고 그 문서를 따릅니다(M000). 이후 하위 명령은 모두 clone 의 스크립트로, 프로젝트 루트에서 실행합니다: `bash "$C/rd-workflow/scripts/sync_template.sh" <하위 명령>`.

### 3. 하위 명령 순서

1. `classify` — 파일 분류와 계획 저장. **exit 3** 이면 구조 마이그레이션(M001·M002)이 남은 것입니다. clone 의 `MIGRATIONS.md` 에서 그 항목을 읽고 사용자와 함께 처리한 뒤 `classify` 를 다시 실행합니다.
2. 사용자 확인 — `classify` 출력으로 덮어쓰기·추가·삭제·보존·판단 필요 목록을 보이고 확인을 받습니다(`sync_template.md` 3단계). 뺄 경로는 `--exclude`, 삭제를 확인받았으면 `--delete` 로 옮깁니다.
3. `migrate pre` — 동기화 전 마이그레이션. `FAIL`·`ASK` 는 `sync_template.md` 4단계대로 처리합니다.
4. `apply [--delete] [--exclude <경로>]...` — 복사·추가·삭제와 마지막 VERSION 갱신. 「분류 뒤 프로젝트가 바뀌었습니다」 로 멈추면 2번 사용자 확인부터 다시 합니다(`classify` → 확인 → `apply`). 이어서 `sync_template.md` 5.1 절 명령을 실행합니다.
5. `classify --no-save` — 남은 `update`·`add`·`delete` 가 사용자가 뺀 경로뿐인지 확인합니다.
6. `migrate post` — 동기화 후 마이그레이션과 안내. M013 의 `modified` 절은 사용자에게 묻고 `migrate M013 --decide '<제목>=adopt|keep|defer'` 로 답을 넘깁니다. 스크립트에 없는 항목(`스크립트에 없는 항목 — MIGRATIONS.md 를 읽고 처리하십시오`)은 건너뛰지 않고 clone 의 `MIGRATIONS.md` 를 읽고 처리합니다.
7. `reinstall` — skill·extension 재설치. `ask-ext`·`ask-verifier`·`ask-preset` 줄은 사용자에게 묻고 `--declined`·`--failed`·`--verifier-add`·`--verifier-skip`·`--preset` 인자로 다시 실행합니다. extension 신규 안내는 `seen_extensions` 에 없는 extension 만 나옵니다 (`sync_template.md` 8.4·8.7).
8. `changelog` — 받은 변경 이력.

### 4. 완료 요약

`sync_template.md` 9단계 보고 항목을 각 하위 명령의 출력 줄로 씁니다(출처 표와 보고 예시는 9단계).
- 실패·보류·미응답 항목은 원인과 재시도 방법을 함께 적습니다.
- 마지막 항목은 `changelog` 출력입니다. 출력을 줄이지 않고 그대로 옮깁니다.
- lite 가 아니면 `status.md` 3b 의 판정 블록을 실행하고, `미작성`·`절 없음` 인 절마다 절 이름과 함께 "`PROJECT_CONTEXT.md` 의 `## Run`·`## Feature Entry Paths` 절을 채우십시오. 양식은 배포 템플릿의 `PROJECT_CONTEXT.md` 에 있습니다." 안내를 완료 요약에 넣습니다.
- 보고 뒤 임시 clone 을 정리합니다(`sync_template.md` 9단계 끝).
