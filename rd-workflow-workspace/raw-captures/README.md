# Raw Captures

워크플로 진입점 (FR / REQUEST / spec / plan) 직전의 사용자 원본 입력을 가공 없이 보존한다.

## 파일 형식

- 경로: `YYYY-MM-DD-HHMM-{stage}-{short-title}.md`
- stage: `fr` | `request` | `spec` | `plan`
- short-title: `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (영문 kebab-case, 영숫자 시작·끝, 사이만 `-`). `-` 단독 / hyphen-only / empty 금지 (`-` 는 reserved sentinel)
- 충돌 시 `-2`, `-3` suffix
- frontmatter: `date`, `stage`, `short-title`, `source` (`direct` | `routed`) 4개 고정
- 본문: `## 원본 입력` 헤더 + 입력 원문 (byte-level 동일, 가공 금지)

## Archive

- `/fr archive` 또는 status `done`/`dropped`: 같은 short-title 의 `*-fr-*.md` → `archive/` 로 이동
- REQUEST archive: 같은 short-title 의 `*-{request,spec,plan}-*.md` → `archive/` 로 이동

## git 미추적

이 디렉토리는 `.gitignore` 로 제외됨 (`raw-captures/*` + `!raw-captures/README.md` negation 패턴 — README 만 추적 가능). 민감정보가 포함될 수 있으므로 git 추적 / 공유 금지. 의도적으로 공유하려면 `git add -f` 명시적 호출 필요.
