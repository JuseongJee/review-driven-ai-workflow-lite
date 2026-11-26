# 초기 설정 가이드

## 권장: AI에게 설치 시키기

프로젝트 디렉토리에서 Claude Code를 열고 한 마디만 하면 됩니다:

```text
이 AI 워크플로 템플릿 적용해: <배포 repo URL>
```

Claude가 [setup_with_claude.md](setup_with_claude.md)를 읽고 설치 → 프로젝트 파악 → PROJECT_CONTEXT.md 채우기까지 진행합니다.

아래 내용은 수동으로 설정할 때 참고하세요.

---

## 전제 조건

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) 설치 완료
- 프로젝트 디렉토리 생성 완료

## 수동 설치

1. 배포 저장소에서 템플릿 파일을 프로젝트 루트에 복사합니다.

```
복사 대상:
├── CLAUDE.md
├── REQUEST.md
├── PROJECT_CONTEXT.md
├── CURRENT_TASK.md
├── WORKING_WITH_AI.md
├── .claude/settings.json
├── .claude/rules/rd-workflow/    (전체 디렉토리)
└── rd-workflow/                  (전체 디렉토리)
```

2. 이미 존재하는 파일이 있으면 내용을 확인하고 머지합니다.

## PROJECT_CONTEXT.md 채우기

프로젝트에서 가장 먼저 해야 할 일입니다. 각 섹션을 채우세요:

- **프로젝트 개요**: 프로젝트 이름, 목적, 도메인(기획/마케팅/운영 등)
- **산출물 정의**: 주요 산출물 유형, 형식, 품질 기준
- **대상과 제약**: 독자, 문체, 분량/마감 등 제약
- **품질 규칙**: 용어 일관성, 사실 관계, 독자 수준 등

파일만으로 확정 가능한 내용은 먼저 채우고, 모르는 것만 질문합니다.

## Skill 설치

템플릿의 Claude skill을 프로젝트에 설치합니다.

```bash
bash rd-workflow/scripts/install_claude_skills.sh project
```

설치 후 Claude Code를 재시작하면 skill이 인식됩니다.

## 검증 스크립트 설정

`rd-workflow/scripts/test.sh`, `lint.sh`, `typecheck.sh`가 검증을 담당합니다.

각 스크립트는 `PROJECT_CONTEXT.md`의 Build/Test/Lint/Typecheck 섹션을 참조합니다.
프로젝트에 맞게 검증 명령을 설정하세요.

## 리뷰 도구 감지 및 설정

먼저 외부 리뷰 도구가 설치되어 있는지 확인합니다.

```bash
command -v codex &>/dev/null && echo "codex: 설치됨" || echo "codex: 없음"
```

**설치된 경우**: 교차 리뷰가 가능합니다. 아래 설정에서 우선순위를 조정하세요.

**없는 경우**: Claude self-review로 동작합니다. 다른 모델로 교차 리뷰하면 품질이 크게 올라가므로 나중에라도 설치를 권장합니다.

`rd-workflow/config/review-tools.json.example`을 `review-tools.json`으로 복사해서 시작하세요.

```json
{
  "default_priority": ["codex", "claude"],
  "tools": {
    "codex": { "bin": null },
    "claude": { "bin": null, "self_review_warning": true }
  }
}
```

- 외부 도구가 있으면 `bin`에 경로를 넣으면 교차 리뷰가 가능합니다.

리뷰어의 모델과 추론 깊이(effort)는 `rd-workflow/config/models.json` 에서 고칩니다.

1. `rd-workflow/config/models.json.example` 을 `rd-workflow/config/models.json` 으로 복사합니다.
2. 바꿀 칸만 고칩니다. 값이 `null` 인 칸은 비어 있고, 비어 있으면 도구 자체 설정을 씁니다.
3. 다음 리뷰 턴의 실행 줄 `리뷰 도구: <도구> / 모델 요청: <값> (source: …) / effort 시도: <값> (source: …)` 에서 값과 출처를 확인합니다. 리뷰 턴 없이 확인하려면 `bash rd-workflow/scripts/model_select.sh show review` 를 실행합니다.

칸 목록:

- `review.codex.model`: Codex 모델. 계열 이름(`sol` 처럼 소문자만)을 쓰면 `~/.codex/models_cache.json` 에서 그 계열의 최신 모델을 고릅니다. 비어 있으면 `~/.codex/config.toml` 의 모델을 씁니다.
- `review.codex.effort`: Codex effort 기본값.
- `review.codex.small_task_effort`: `standard` 등급 리뷰(세션 `execution-path: small-task`)의 Codex effort. `medium` 이 하한입니다.
- `review.codex.review_types.<리뷰 종류>.effort`: 리뷰 종류별 Codex effort.
- `review.claude.model`: Claude 모델. 별칭(`opus`·`sonnet`·`haiku`·`fable`)을 씁니다.
- `review.claude.effort`: Claude effort.

effort 값은 `low`·`medium`·`high`·`xhigh`·`max`·`ultra`·`lowest`·`highest` 입니다. 모델이 지원하지 않는 단계는 바로 아래 지원 단계로 낮추고 경고합니다. `default` 는 「이 칸에서 넘기지 않음」 입니다.
`RD_REVIEW_EFFORT_OVERRIDE=0` 이면 설정을 남긴 채 Codex effort 를 즉시 무력화합니다.
`review-tools.json` 의 옛 키(`tools.claude.model`·`tools.codex.reasoning_effort`·`tools.codex.small_task_reasoning_effort`·`overrides.<종류>.tools.codex.reasoning_effort`)는 아직 읽지만 새로 쓰지 마십시오. 옛 키를 쓰면 리뷰 턴이 `models.json` 으로 옮기라고 안내합니다.

## 첫 작업 시작하기

설정이 끝나면 Claude Code를 열고:

```text
"이 요구사항으로 진행해줘: ..."        # 큰 작업
"바로 작성해줘: ..."     # AI 가 등급 판정
```

자세한 사용법은 `WORKING_WITH_AI.md`를 참조하세요.
