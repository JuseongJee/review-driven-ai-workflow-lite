# Review-Driven AI Workflow — Lite

비개발 도메인(기획, 마케팅, 운영, 교육 등)을 위한 AI 워크플로 템플릿.

> **"Lite"는 적용 대상이 개발과 얽히지 않는다는 뜻이지, 워크플로가 가벼워진다는 뜻이 아닙니다.**

REQUEST → 리뷰 → spec/plan → 실행 → 검증 → 최종 리뷰까지, dev 버전과 동일한 구조적 엄밀함을 유지합니다. 개발 도구 의존(test/lint/typecheck, git diff review 등)만 제거하고 프롬프트 기반 검증과 산출물 리뷰로 대체했습니다.

## 최근 변경

최근 세 발행에서 달라진 것입니다. 내 프로젝트의 `rd-workflow/VERSION` 보다 뒤의 절이 `/tpl update` 로 받을 변화입니다. 전체 이력은 [`rd-workflow/CHANGELOG.md`](rd-workflow/CHANGELOG.md) 에 있습니다.

### 2026-11-08-074131

- **거절한 extension 을 다시 묻지 않음**: `/tpl update` 가 설치하지 않은 extension(design-review·verify)을 update 마다 다시 묻지 않습니다. 안내한 extension 을 `rd-workflow/config/extensions.json` 의 `seen_extensions` 에 기록하고, 템플릿에 새로 추가된 extension 만 묻습니다. 새 extension 이 없으면 질문이 나오지 않습니다. 이미 설치해 쓰던 프로젝트는 첫 update 에서 묻지 않고 지금 있는 extension 으로 기록을 채웁니다. 거절한 extension 을 설치하려면 「<이름> extension 설치해줘」 로 요청하고, update 에서 다시 질문을 받으려면 `seen_extensions` 에서 그 이름을 빼고 `/tpl update` 를 실행합니다.

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
