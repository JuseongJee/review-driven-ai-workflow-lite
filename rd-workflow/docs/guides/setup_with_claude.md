# Claude에게 템플릿 설치 시키기

이 문서는 Claude가 읽고 실행하는 설치 가이드입니다.

사용자는 프로젝트 디렉토리에서 Claude Code를 열고 아래처럼만 말하면 됩니다.

```text
이 AI 워크플로 템플릿 적용해: <배포 repo URL>
```

---

## Claude가 실행할 절차

이 문서를 읽고 있다면 아래 절차를 순서대로 실행하세요.

### 1. 템플릿 소스 확보

사용자가 제공한 배포 repo URL을 임시 디렉토리에 clone합니다.

```bash
git clone --depth 1 <배포 repo URL> /tmp/ai-workflow-lite-src
```

### 2. 현재 프로젝트에 파일 복사

템플릿 소스에서 현재 작업 디렉토리(프로젝트 루트)에 아래 파일을 복사합니다.

복사 대상:
- `CLAUDE.md`
- `REQUEST.md`
- `PROJECT_CONTEXT.md`
- `CURRENT_TASK.md`
- `WORKING_WITH_AI.md`
- `.claude/settings.json`
- `rd-workflow/` (전체 디렉토리)

이미 존재하는 파일이 있으면 사용자에게 덮어쓸지 확인합니다.

사용자가 제공한 배포 repo URL을 `PROJECT_CONTEXT.md`의 `template_repo`에 저장합니다. (이후 `/tpl update`에서 사용)

임시 clone 디렉토리 정리:
```bash
rm -rf /tmp/ai-workflow-lite-src
```

### 3. PROJECT_CONTEXT.md 채우기 — 대화형 발견

템플릿 파일 외에 프로젝트 고유 파일(기존 문서, 기획서, 참고 자료 등)이 있는지 확인합니다.

**프로젝트 고유 파일이 있는 경우:** 파일을 분석해서 PROJECT_CONTEXT.md를 최대한 채우고, 채울 수 없는 항목만 질문합니다.

**프로젝트 고유 파일이 없는 경우:** 아래 질문을 하나씩 물어봅니다. 한 번에 여러 개를 묻지 않습니다.

1. "이 프로젝트에서 뭘 만들려고 하세요?" → `purpose`, `domain`
2. "주요 산출물은 뭔가요? (예: 보고서, 기획서, 콘텐츠, 매뉴얼 등)" → `primary_outputs`, `output_format`
3. "산출물을 누가 읽나요?" → `audience`
4. "어떤 톤으로 쓰면 될까요? (공식적, 캐주얼, 기술적 등)" → `tone`
5. "좋은 결과물의 기준이 뭐라고 생각하세요?" → `quality_criteria`
6. "분량, 마감, 브랜드 가이드 같은 제약이 있나요?" → `constraints`

답변이 모호하면 따라가며 구체화합니다. 이 과정이 brainstorming입니다.
전부 파악하면 `PROJECT_CONTEXT.md`를 채웁니다.

파악 가능한 항목은 먼저 채우고, 불확실한 항목만 질문합니다.

### 4. Skill 설치

```bash
bash rd-workflow/scripts/install_claude_skills.sh project
```

### 5. 리뷰 도구 감지

외부 리뷰 도구(Codex, Gemini CLI)가 설치되어 있는지 확인합니다.

```bash
command -v codex &>/dev/null && echo "codex: 설치됨" || echo "codex: 없음"
command -v gemini &>/dev/null && echo "gemini: 설치됨" || echo "gemini: 없음"
```

**하나 이상 설치된 경우:** "리뷰 도구가 감지되었습니다. 교차 리뷰가 가능합니다." 안내 후 다음 단계로 진행.

**모두 없는 경우:** 아래 메시지를 출력합니다.

```
외부 리뷰 도구(Codex, Gemini CLI)가 감지되지 않았습니다.
현재 상태에서도 Claude self-review로 동작하지만,
다른 모델로 교차 리뷰하면 품질이 크게 올라갑니다.
```

`rd-workflow/config/review-tools.json.example`을 `rd-workflow/config/review-tools.json`으로 복사합니다.

### 6. PROJECT_CONTEXT 검토 (선택)

3단계에서 채운 내용에 빈칸이나 불확실한 부분이 있으면 사용자에게 PROJECT_CONTEXT review를 돌릴지 물어봅니다.

### 7. 완료 보고

설치 결과를 사용자에게 보고합니다.

보고 항목:
- 복사된 파일 목록
- PROJECT_CONTEXT.md 요약 (채워진 항목 / 빈 항목)
- Skill 설치 결과
- 리뷰 도구 상태
- 다음 단계 안내: "WORKING_WITH_AI.md를 참고해서 첫 작업을 시작하세요"
