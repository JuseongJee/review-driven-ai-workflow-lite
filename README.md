# Review-Driven AI Workflow — Lite

비개발 도메인(기획, 마케팅, 운영, 교육 등)을 위한 AI 워크플로 템플릿.

> **"Lite"는 적용 대상이 개발과 얽히지 않는다는 뜻이지, 워크플로가 가벼워진다는 뜻이 아닙니다.**

REQUEST → 리뷰 → spec/plan → 실행 → 검증 → 최종 리뷰까지, dev 버전과 동일한 구조적 엄밀함을 유지합니다. 개발 도구 의존(test/lint/typecheck, git diff review 등)만 제거하고 프롬프트 기반 검증과 산출물 리뷰로 대체했습니다.

## 최근 변경

최근 세 발행에서 달라진 것입니다. 내 프로젝트의 `rd-workflow/VERSION` 보다 뒤의 절이 `/tpl update` 로 받을 변화입니다. 전체 이력은 [`rd-workflow/CHANGELOG.md`](rd-workflow/CHANGELOG.md) 에 있습니다.

### 2026-11-08-065139

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

### 2026-11-07-210251

- **팀 overlay 가이드**: rd-workflow 가 없는 기존 팀 저장소 클론을 새로 clone 하지 않고 overlay 아래로 옮겨 submodule 로 등록하는 짧은 경로를 이관 가이드에 더했습니다(브랜치·stash·미커밋 작업 유지). 예시 이름을 overlay `rd-myproject` 아래 submodule `myproject` 로 맞추고, 기존 클론 안의 세션에서 진행하지 말고 끝나면 overlay 루트에서 새 세션을 띄우라는 실행 위치 안내를 넣었습니다.

### 2026-11-07-201215

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
