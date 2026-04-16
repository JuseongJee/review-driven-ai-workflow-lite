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
command -v gemini &>/dev/null && echo "gemini: 설치됨" || echo "gemini: 없음"
```

**하나 이상 설치된 경우**: 교차 리뷰가 가능합니다. 아래 설정에서 우선순위를 조정하세요.

**모두 없는 경우**: Claude self-review로 동작합니다. 다른 모델로 교차 리뷰하면 품질이 크게 올라가므로 나중에라도 설치를 권장합니다.

`rd-workflow/config/review-tools.json.example`을 `review-tools.json`으로 복사해서 시작하세요.

```json
{
  "default_priority": ["codex", "gemini", "claude"],
  "tools": {
    "gemini": { "bin": null, "model": null },
    "codex": { "bin": null },
    "claude": { "bin": null, "model": null, "self_review_warning": true }
  }
}
```

- 외부 도구가 있으면 `bin`에 경로를 넣으면 교차 리뷰가 가능합니다.

## 첫 작업 시작하기

설정이 끝나면 Claude Code를 열고:

```text
"이 요구사항으로 진행해줘: ..."        # 큰 작업
"small-task로 바로 작성해줘: ..."     # 작은 작업
```

자세한 사용법은 `WORKING_WITH_AI.md`를 참조하세요.
