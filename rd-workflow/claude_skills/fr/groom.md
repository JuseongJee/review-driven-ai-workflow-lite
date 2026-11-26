## /fr groom

groom 절차의 정본은 `fr-groom` skill(`rd-workflow/claude_skills/fr-groom/SKILL.md`)입니다. 판정 기준표·절차·규칙은 그 skill 한 곳에만 둡니다. 이 문서는 `/fr groom` 과 `/fr do` 의 groom 경로를 그 skill 로 잇기만 합니다.

### 절차

1. Skill 도구로 `fr-groom` 을 부릅니다. 인자는 `/fr groom` 뒤의 slug 들을 그대로 넘깁니다(없으면 비웁니다). `/fr do` 에서 왔으면 `do.md` 가 정한 slug 들을 넘깁니다.
2. Skill 도구 호출이 성공하면 `fr-groom` 의 절차를 따르기 전에 아래 한 줄을 보입니다. 모델이 Skill 도구로 skill 을 부르면 frontmatter 의 `effort` 만 걸리고 `model` 은 걸리지 않기 때문입니다(`fr-groom` 「모델·effort」 절).
   - 사용자가 `/fr groom` 을 입력한 경우: 「groom 은 effort 를 높여 돌립니다. 모델까지 올리려면 이 턴을 멈추고 `/fr-groom <같은 인자>` 를 직접 입력하십시오.」
   - `/fr do` 의 groom 경로인 경우: 「groom 은 effort 를 높여 돌립니다. 이번 회차는 세션 모델로 이어 갑니다. 다음부터 모델까지 올리려면 `/fr do` 전에 `/fr-groom <slug들>` 을 직접 입력하고 결과를 커밋하십시오.」 이번 회차를 멈추라고 안내하지 않습니다. 멈추면 `do.md` 의 groom 결과 커밋과 착수가 끊깁니다.
3. Skill 도구로 `fr-groom` 을 부를 수 없으면(skill 링크가 없거나 이 세션이 아직 등록하지 못함) `rd-workflow/claude_skills/fr-groom/SKILL.md` 를 Read 하고 그 절차를 따릅니다. 이때는 2단계 안내 대신 아래 한 줄을 보입니다.
   - 「`fr-groom` skill 을 부르지 못해 세션의 모델·effort 로 진행합니다. 높여 돌리려면 프로젝트 루트에서 `bash rd-workflow/scripts/install_claude_skills.sh project link fr-groom` 을 실행하고 Claude Code 를 다시 시작한 뒤 `/fr-groom` 을 입력하십시오.」

### 규칙

- 사용자 명시 요청 전용입니다(SKILL.md 「모델 자기호출 경계」). `/fr do` 대화형의 groom 질문에 사용자가 groom 을 고른 것은 명시 요청입니다.
- 무인 실행(`/fr do --headless`, autopilot)에서는 돌리지 않습니다.
- 커밋은 하지 않습니다. 대화형 `/fr do` 가 이 절차를 불렀으면 결과 커밋은 `do.md` 「1. 고르기와 착수 보고 표」 4단계가 합니다. `do.md` 가 가리키는 「일괄 모드」 는 `fr-groom` 의 판정 권장표 흐름입니다.
