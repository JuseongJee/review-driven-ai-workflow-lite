# Review-Driven AI Workflow — Lite

비개발 도메인(기획, 마케팅, 운영, 교육 등)을 위한 AI 워크플로 템플릿.

> **"Lite"는 적용 대상이 개발과 얽히지 않는다는 뜻이지, 워크플로가 가벼워진다는 뜻이 아닙니다.**

REQUEST → 리뷰 → spec/plan → 실행 → 검증 → 최종 리뷰까지, dev 버전과 동일한 구조적 엄밀함을 유지합니다. 개발 도구 의존(test/lint/typecheck, git diff review 등)만 제거하고 프롬프트 기반 검증과 산출물 리뷰로 대체했습니다.

## 최근 변경

최근 세 발행에서 달라진 것입니다. 내 프로젝트의 `rd-workflow/VERSION` 보다 뒤의 절이 `/tpl update` 로 받을 변화입니다. 전체 이력은 [`rd-workflow/CHANGELOG.md`](rd-workflow/CHANGELOG.md) 에 있습니다.

### 2026-11-21-001711

- **overlay 마감 때 팀 저장소에 PR 을 올림**: 소스(submodule)에서 코드를 바꾼 overlay 작업은 final diff review 종결 뒤 `bash rd-workflow/scripts/rd pr open` 으로 팀 저장소에 PR 을 올립니다. PR 이 올라가면 작업 Status 가 `PR 검토 중` 이 되고, `rd task list` 가 submodule 별 PR 상태와 다음 행동을 보입니다. 팀이 merge 하면 `rd pr check --apply` 가 submodule 포인터를 merge 된 커밋으로 옮기고 `아카이브 보류` 로 되돌리며, 재리뷰 없이 기존 발행 절차로 갑니다. `rd pr check` 는 수정 요청·닫힘도 알립니다. archive 는 반영 방식 `pr`·`push` 인 submodule 의 새 포인터가 팀 대상 브랜치에 없으면 발행을 거부합니다(우회 `--allow-unpublished-submodule <사유>`). `light` 작업이 반영 대상 submodule 을 바꾸면 `rd pr light-check` 가 `standard` 로 상향합니다. 반영 방식은 `rd-workflow/config/workflow.json` 의 `team_publish`(`mode` `pr`·`push`·`manual`, `base`, `branch_prefix`, `light`, `submodules.<경로>`)로 고릅니다. **기본값이 `pr` 이라서 기존 overlay 사용자는 업데이트 직후 첫 발행이 거부될 수 있습니다.** 이전 방식으로 두려면 `team_publish.mode` 를 `manual` 로 적고 커밋합니다. 업데이트가 설정 파일을 자동으로 고치지 않습니다. 자세한 내용은 [`MIGRATIONS.md`](MIGRATIONS.md) M018 에 있습니다.
- **`/fr take` 추가, `/fr pull`(FR 경로)·`/fr sync` 제거**: 팀 저장소의 Issue 를 `/fr take` 로 골라 선점하고, FR 을 만들어 바로 착수합니다. 제거: `/fr pull`(FR 경로)·`/fr sync`·Issue 상태 라벨·`/fr add` 자동 Issue 발행. 추가: `/fr take`·FR 종료 상태 `handed-off`·`issue_queue.sh`. 바뀜: `/fr push` 는 내 FR 을 팀 Issue 로 넘기고 FR 을 `handed-off` 로 닫습니다. 대체 경로: 팀 Issue 는 `/fr take` 로 집고, 내 FR 은 `/fr push` 로 넘깁니다. `fr_github: true` 로 쓰던 사람은 등록 때 Issue 가 생기지 않으므로 넘기려면 `/fr push` 를 부릅니다.
  - 호환성 1: 열린 `fr:*` 라벨 Issue 는 담당자가 없으면 `/fr take` 고르기 화면에 그대로 보입니다. 별도 이관은 없습니다.
  - 호환성 2: 이미 `github-issue` 로 연결된 로컬 FR 은 그대로 둡니다. 상태 동기화가 없어지므로 이후에는 `close-fr` 이나 사람이 닫습니다.
  - 호환성 3: 원격의 `fr:*` 라벨은 지우지 않습니다.
- **리뷰어 발견의 확신도 칸 제거**: 리뷰어 발견 머리 줄이 `- F<번호> [confidence N/10] <제목>` 에서 `- F<번호> <제목>` 으로 바뀝니다. 확신도가 8~10 에만 몰려 경중 신호로 쓰이지 않았기 때문입니다. 리뷰 턴 뒤 `confidence-missing`·`appendix-confidence` 경고가 더는 나오지 않습니다. 근거 줄 없는 본문 발견은 「본문 발견에 근거 줄이 없습니다. 해소 확인·합의라면 Agreement 에 적습니다」 경고 하나로 안내합니다. 세션 폴더의 `finding_metrics.tsv` 는 마지막 `confidences` 칸이 빠져 7칸이 됩니다.
- **promote 의 submodule 을 메인 체크아웃에서 받음**: promote 가 새 worktree 의 submodule 을 원격이 아니라 메인 체크아웃에서 복제해 빨라지고, 원격에 닿지 못해도 착수합니다. 메인 체크아웃에서 초기화하지 않은 submodule 은 비워 두고, 그 경로와 받는 명령 `bash rd-workflow/scripts/rd submodule init [<경로>...]` 을 알립니다. 브랜치가 메인에 없는 submodule 커밋을 가리킬 때만 원격에서 받으며, 원격 대기는 한 번의 promote 전체에서 `RD_SUBMODULE_REMOTE_TIMEOUT` 초(기본 120)까지입니다. 받기에 실패하면 경로·원인·재시도 명령을 알리고 착수는 계속합니다. 리뷰 입력 검사가 submodule 객체 부재로 막힐 때의 첫 복구 안내도 `rd submodule init` 입니다.
- **final diff review 가 사용자 확인을 점검함**: final diff review 리뷰어가 사용자에게 보이는 결과나 백그라운드 동작이 바뀐 diff 에서 결과·진행·실패를 사용자가 볼 수 있는지 점검합니다. 빠졌거나 spec·AC 와 다르면 이의로 냅니다. 사용자에게 닿지 않는 내부 변경은 이 점검을 하지 않습니다. 이제 REQUEST review·spec/plan review·final diff review 세 단계가 모두 사용자 확인을 봅니다.
- **`/tpl update` 의 기계적 단계를 스크립트가 맡음**: `/tpl update` 가 파일 분류·복사·마이그레이션·skill 재설치·변경 이력 추출을 `sync_template.sh` 하위 명령(`policy`·`classify`·`apply`·`migrate`·`reinstall`·`changelog`)으로 처리하고, Claude 는 스크립트가 넘긴 판단 항목만 다룹니다. 그래서 update 한 번에 드는 시간이 줄어듭니다. 3단계에서 확인한 분류 목록과 복사 시점의 분류·내용이 다르면 `apply` 가 아무것도 바꾸지 않고 멈추고, 바뀐 쪽(`프로젝트 내용 바뀜`·`clone 내용 바뀜`)을 알립니다. 판단이 필요한 마이그레이션(M001·M002·M011·M014·M017, M013 의 `modified` 절)은 자동 적용하지 않고 판단 항목으로 묻습니다. 마이그레이션이 실패하면 이미 바꾼 파일과 바꾸지 않은 파일을 나눠 보고합니다. `sync_template.md` 는 1,074줄에서 약 600줄로, `MIGRATIONS.md` 는 893줄에서 약 510줄로 줄었습니다.
- **archive 뒤 `CURRENT_TASK.md` 가 배포 템플릿과 같음**: archive 가 쓰는 초기본을 배포 템플릿과 같게 맞췄습니다. `## Request` 는 `REQUEST.md`, `## Branch / Worktree` 는 `-` 이고, 쓰이지 않던 `## Output Files` 절이 없어집니다. 그래서 archive 를 거친 프로젝트도 `/tpl update` 에서 `REQUEST.md`·`CURRENT_TASK.md` 가 「판정 불가로 보존」 되지 않고 템플릿 본으로 동기화됩니다. 이전 초기본이 남은 파일도 템플릿 본으로 인정합니다. 사용자가 쓴 줄이 남아 있으면 지금처럼 보존합니다. lite 배포본의 `CURRENT_TASK.md` 도 full 과 같아집니다(`## Source FR` 절과 안내 주석이 생기고 절 순서가 같아짐). 세션 시작 안내가 Next Step 안내 주석을 값으로 보이지 않습니다.
- **발행 대기가 호출 세션의 감시 생존을 확인함**: 호출 세션의 감시(`rd publish watch`, `/fr do` 감시)가 5분 넘게 없으면 `rd publish request` 가 「경고: 호출 세션의 감시가 없습니다」 줄을 냅니다(종료 코드 0 그대로). 같은 상황에서 `rd publish wait` 는 같은 경고와 종료 코드 5 로 바로 끝나고, 요청은 큐에 「요청됨」 그대로 남습니다. 작업 세션은 사용자에게 알리고 `wait` 를 다시 띄웁니다. `rd publish watch` 는 인자 없이 실행하면 사건이 있을 때만 끝나므로 1시간마다 다시 띄울 필요가 없습니다. `--timeout <초>` 를 주면 그 시간 뒤 종료 코드 4 로 끝납니다. `/fr do` 감시는 발행 큐를 읽지 못하면 `QUEUE 조회 실패 (rc=N)` 이벤트를 냅니다.
- **`/fr list` 가 진행 중 FR 을 표시함**: 작업 worktree 나 `/fr do` 줄기가 맡은 FR 의 `착수` 칸이 `진행 중(구현 중)`·`진행 중(PR 검토 중)`·`진행 중(/fr do 줄기 <slug>)` 처럼 보입니다. 판정에 실패하면 경고 한 줄을 보이고 목록은 그대로 냅니다.
- **대화형 `/fr do` 의 설계 문답**: 착수 보고 전에 「설계 문답 / 그냥 진행」 을 한 번 묻습니다. 설계 문답을 고르면 각 줄기 탭에 설계 질문이 뜨고, 호출 세션은 대신 답하지 않고 어느 탭에서 답을 기다리는지 알립니다. 무인(`--headless`)은 바뀌지 않았습니다.
- **기록 커밋 뒤 리뷰와 수렴한 세션 재개**: 기록 커밋(REQUEST.md 비우기) 뒤 연 diff review 는 완료 기준과 effort 를 REQUEST 보관본에서 읽습니다. 수렴한 세션은 새 Author 턴을 쓴 뒤 `run_review_turn.sh <세션> --reopen "<사유>"` 로 재확인 턴을 받습니다. final-diff-review 는 중간 턴에 고친 영역의 테스트만 돌리고, 전체 검증은 seal 직전 한 번입니다.
- **사람 결정 뒤 리뷰 재개·종결·턴 연장**: 미해결 이의로 멈춘 세션은 `run_review_turn.sh <세션> --decision "<결정>"` 으로 결정을 기록하고 Reviewer 턴을 바로 돌립니다. `--override "<결정한 사람> — <그 사람이 한 말>"` 은 남은 이의를 덮고 세션을 `closed` 로 종결합니다(seal 이 거부할 세션은 미리 거부). 턴 한도에 닿은 세션은 `--extend-turns <N>` 으로 한도를 늘립니다.
- **리뷰 이의의 중요도 문턱**: 리뷰어가 이의마다 현실에서 일어나는 경로를 `경로:` 줄로 적습니다. 문구·서식·주석·유지보수성, 검증 증거의 형식 같은 지적은 Summary 끝 `메모:` 줄로 나오고 종결을 막지 않습니다. 검증 관련 이의는 검증이 실제로 결함을 덮지 못할 때만 나옵니다.
- **리뷰 비용 표시와 6턴 뒤 자동 범위 축소**: Reviewer 턴마다 `리뷰 비용: 누적 N턴 · 세션 경과 X · 리뷰 도구 Y · 토큰 …` 한 줄이 나옵니다. 6턴(`REVIEW_SCOPE_NARROW_AFTER`)을 넘기면 리뷰어는 기본 사용 경로 결함·데이터 손실·보안·요청 이탈·검증 공백만 이의로 내고, 나머지는 `범위 밖:` 줄로 적어 종결을 막지 않습니다. 사람에게 묻지 않습니다. `범위 밖:` 줄은 같은 작업의 다음 리뷰 단계에 자동으로 넘어가고, 사람이 정한 범위 밖은 REQUEST `## Constraints` 의 `- 범위 밖:` 줄로 넘깁니다. 새 세션의 `turn_metrics.tsv` 는 12열(`tokens`)입니다.
- **리뷰 모델·effort 를 `models.json` 에서 고름**: `rd-workflow/config/models.json` 에 리뷰어별 모델·effort, 리뷰 종류별 effort, small-task effort 를 적습니다. Codex 는 계열 이름(`sol` 등)으로 가장 높은 버전을 고르고, 지원하지 않는 effort 는 한 단계 낮추며 경고합니다. `RD_REVIEW_CODEX_MODEL`·`RD_REVIEW_CODEX_EFFORT`·`RD_REVIEW_CLAUDE_MODEL`·`RD_REVIEW_CLAUDE_EFFORT` 로 한 번만 바꿀 수 있습니다. 리뷰 턴 출력에 요청값과 실제 모델·effort 가 나오고, 새 세션의 `turn_metrics.tsv` 에 `model` 열이 생깁니다. `bash rd-workflow/scripts/model_select.sh show review` 가 칸마다 값과 출처를 보입니다. `/review-config`(full)는 이 파일에 씁니다. 기존 `review-tools.json` 의 모델·effort 키는 계속 동작하며 옮길 칸을 안내합니다.
- **직접 설치 프로젝트의 PR 발행(`archive_publish: pr`)**: `rd-workflow/config/workflow.json` 에 `"archive_publish": "pr"` 을 두면 발행이 fr 브랜치를 push 하고 PR 을 만들거나 갱신한 뒤 멈춥니다. 팀이 merge 하면 `rd pr check --task <작업> --apply` 가 태그를 달아 마감합니다. 수정 요청은 `rd pr reopen --task <작업>` 으로 되돌려 고칩니다. PR 이 기록 파일만 충돌하면 새 명령 `rd pr sync [--task <slug>]` 가 기본 브랜치를 병합해 PR 을 갱신합니다(재리뷰·새 seal 없음). 값이 없거나 `push` 이면 지금과 같습니다. 흐름은 `WORKFLOW.md` 「직접 설치 PR 발행」 절에 있습니다.
- **기본 브랜치 작업도 팀 저장소 PR 흐름을 씀**: 기본 브랜치에서 한 작업도 `rd pr open` → 팀 merge → `rd pr check --apply` → archive 순서로 발행합니다. `rd task list` 는 진행 중 fr 작업이 없어도 기본 체크아웃 작업의 「PR 검토 중」 표를 보이고, 행동 줄의 경로·이름·PR 주소를 작은따옴표로 인용합니다. archive 는 submodule 포인터 충돌에서 한쪽이 조상이면 자손 커밋으로 풀고, 팀 원격 조회와 받기에 시간 상한을 둡니다.
- **발행 뒤 연결된 Issue 를 닫음**: 원격 push 발행이 끝나면 Source FR 의 `github-issue` 에 적힌 Issue 마다 반영 커밋 댓글을 달고 닫습니다. 값은 `owner/repo#N` 을 쉼표로 잇거나 브라우저의 Issue URL 을 적습니다. 형식이 어긋나면 어느 Issue 도 건드리지 않고 틀린 조각을 알립니다. 닫기 실패는 발행을 실패로 두지 않고 재실행 명령을 보입니다. `issue_queue.sh close-fr` 에 `--skip-closed` 가, 장부 행만 지우는 `issue_queue.sh forget <저장소> <번호>` 가 생겼습니다. PR 본문의 `Closes` 줄은 값 형식이 맞을 때만 들어가고, 호스트가 붙은 값은 URL 로 씁니다.
- **늦게 끝난 줄기의 발행 충돌 자동 해소**: 늦은 줄기의 `archive.sh` 가 task-state 충돌을 스스로 풉니다. FR 인덱스 안의 한 줄 주석도 병합하고, 병합할 수 없는 인덱스는 병합을 시작하기 전에 사유와 함께 멈춥니다.
- **`/fr add` 가 미커밋 변경을 남기지 않음**: `/fr add`(와 `/fr take` 의 등록 단계)를 마친 뒤 기본 체크아웃의 Short Title 은 `-` 그대로이고 미커밋 변경이 남지 않습니다. 이전 버전이 남긴 Short Title 은 `rd task set-title -` 로 되돌립니다.
- **큰 FR 은 REQUEST review 에서 나눔(full)**: full 작업의 REQUEST review 리뷰어가 `분할:` 발견을 내면 Author 는 묻지 않고 범위를 선행 없는 기능으로 좁히고, 뗀 기능은 후속 FR 로 등록합니다.
- **`self_test.sh` 에 테스트 파일 하나만 돌리기**: `bash rd-workflow/scripts/self_test.sh test_tasks_list.sh` 처럼 테스트 파일 이름이나 검사 함수 이름을 주면 그 스텝만 돕니다. 맞는 스텝이 없으면 FAIL 로 끝납니다. 그룹과 함께 주면 합집합을 돕니다.

### 2026-11-08-092219

- **`/fr groom` 추가**: `/fr groom <제목>` 으로 idea 상태 FR 한 건을, `/fr groom` 으로 idea FR 전부를 차례로 문답 검증합니다. AI 가 한 번에 한 질문과 권장 답을 내고, 마지막에 validated·parked·dropped 중 하나를 제안합니다. 결정하면 상세 파일에 `## groom 기록` 이 남고 상태가 바뀝니다. 일괄 모드에서는 「건너뛰기」·「중단」 을 말할 수 있고, 끝에 결과 요약표가 나옵니다. 사용자가 직접 요청할 때만 실행합니다.
- **`/fr do` 의 idea FR 확인**: 대화형 `/fr do` 는 띄울 줄기에 idea FR 이 있을 때만 「groom 먼저 / 그대로 띄우기」 를 묻습니다. groom 을 고르면 결과를 기본 브랜치에 커밋한 뒤 후보를 다시 골라 띄우고, groom 을 중단하면 그 `/fr do` 는 새 줄기를 띄우지 않습니다. 무인 `/fr do --headless` 는 동작이 같고, 뺀 FR 표에 「groom 대상」 표시만 더합니다.

### 2026-11-08-074131

- **거절한 extension 을 다시 묻지 않음**: `/tpl update` 가 설치하지 않은 extension(design-review·verify)을 update 마다 다시 묻지 않습니다. 안내한 extension 을 `rd-workflow/config/extensions.json` 의 `seen_extensions` 에 기록하고, 템플릿에 새로 추가된 extension 만 묻습니다. 새 extension 이 없으면 질문이 나오지 않습니다. 이미 설치해 쓰던 프로젝트는 첫 update 에서 묻지 않고 지금 있는 extension 으로 기록을 채웁니다. 거절한 extension 을 설치하려면 「<이름> extension 설치해줘」 로 요청하고, update 에서 다시 질문을 받으려면 `seen_extensions` 에서 그 이름을 빼고 `/tpl update` 를 실행합니다.

## 전제 조건

- [Claude Code](https://claude.ai/code) 설치 및 로그인 (2.1.310 이상 — 그 미만은 `.claude/rules/` 하위 폴더 로드를 보장하지 않습니다)
- [Superpowers](https://github.com/anthropics/claude-code-superpowers) 플러그인 설치

## 빠른 시작

프로젝트 디렉토리에서 Claude Code를 열고:

```text
이 AI 워크플로 템플릿 적용해: https://github.com/JuseongJee/review-driven-ai-workflow-lite
```

> **Claude에게:** 이 요청을 받았다면 [`rd-workflow/docs/guides/setup_with_claude.md`](rd-workflow/docs/guides/setup_with_claude.md)를 읽고 절차대로 실행하세요.

AI가 필요한 파일을 가져온 뒤, 프로젝트에 대해 질문하면서 PROJECT_CONTEXT.md를 함께 채워줍니다. 빈 폴더에서 시작해도 대화를 통해 프로젝트의 목적, 산출물, 품질 기준을 구체화합니다.


### 적용 후

설정이 끝나면 바로 첫 작업을 시작합니다:

```text
이 요구사항으로 진행해줘: ...
```

## 사용 예시 — 단계별 프롬프트

### `full` 등급

```text
1. "이 요구사항으로 진행해줘: 면접 질문지에 컬쳐 인터뷰 항목 추가"
   → AI가 REQUEST를 작성하고 review를 시작합니다

2. (review 확인, AI의 질문에 답변 후) "진행해"
   → AI가 spec과 plan을 작성하고 review를 시작합니다

3. (spec/plan review 확인, 필요시 수정 방향 전달 후) "진행해"
   → AI가 작성을 시작합니다

4. 작성 완료 → AI가 자동으로 검증 + 산출물 review를 진행합니다

5. (review 확인 후) "좋아, 마무리해줘"
```

### `standard` 등급

```text
1. "운영 매뉴얼의 고객 응대 섹션 업데이트해줘"
   → AI 가 등급(`standard`) 을 보고하고 작성 → 검증 → review 까지 진행합니다
```

### Autopilot

```text
1. "/autopilot"
   → 백로그에서 작업을 선택하고 전체 파이프라인을 자율 실행합니다
```

사용자가 하는 건 **요구사항 전달 + review 결과 판단** 정도입니다. 나머지는 워크플로가 이어갑니다.

## 핵심 구조

| 파일 | 역할 |
|------|------|
| `CLAUDE.md` | 프로젝트 규칙 (프로젝트 소유 — sync 가 덮어쓰지 않음) |
| `.claude/rules/rd-workflow/` | AI 실행 규칙 (템플릿 소유 — sync 가 덮어씀) |
| `PROJECT_CONTEXT.md` | 프로젝트/도메인 메타데이터 |
| `REQUEST.md` | 현재 작업 요청서 |
| `CURRENT_TASK.md` | 진행 중인 작업 상태 |
| `WORKING_WITH_AI.md` | 사용법 치트시트 |

## 워크플로

모든 작업은 위험 등급(`light` / `standard` / `full`) 에 따라 절차가 달라집니다. 등급은 AI 가 `rd-workflow/docs/flows/WORKFLOW.md` 위험 등급 절의 신호표로 판정해 시작 보고를 내고, 하향은 사용자만 합니다.

### `full` (새 기능, 산출물 구조·품질 기준의 큰 변경)

FR 자동 등록 → REQUEST 작성 → REQUEST review → spec/plan → spec/plan review → 실행 → 검증 → final output review → 아카이브

### `standard` (국소 변경)

promote → 축약 REQUEST → 실행 → 검증 → 재분류 → final output review → 아카이브

### `light` (문구·포맷 수정)

실행 → 검증 → 재분류 → 기본 브랜치 커밋 1회 (+ `reports/tier-log.md` 행, 원격 모드면 push — 실패 시 "미push" 로 보고). REQUEST·리뷰·아카이브 없음

## Developer 버전과의 차이

| 항목 | Developer | Lite |
|------|-----|------|
| 검증 | test.sh + lint.sh + typecheck.sh | verify.sh (프롬프트 기반) |
| 최종 리뷰 | diff review (코드 변경) | output review (산출물 품질) |
| PROJECT_CONTEXT | tech stack, build 명령 | 도메인, 산출물 유형, 품질 기준 |
| 스킬 | 12개 | 6개 (핵심만) |
| 리뷰 파이프라인 | 동일 | 동일 |
| Superpowers | 동일 | 동일 |

## 템플릿 업데이트

이미 적용된 프로젝트에서 최신 버전으로 업데이트하는 방법입니다.

### URL로 업데이트 (repo 접근 가능할 때)

```text
/tpl update
```

또는:

```text
이 템플릿으로 업데이트해: https://github.com/JuseongJee/review-driven-ai-workflow-lite
```


## 문서

- [초기 설정 가이드](rd-workflow/docs/guides/setup.md)
- [사용자 매뉴얼](rd-workflow/docs/USER_MANUAL.md)
- [워크플로 판단 기준](rd-workflow/docs/flows/WORKFLOW.md)
- [문서 인덱스](rd-workflow/docs/AI_DOC_MAP.md)
