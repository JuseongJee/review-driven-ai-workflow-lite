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

## git 추적

이 디렉토리는 git 추적 대상이다 (정책: 입력 원문을 백업·팀 공유·이력 보존). 이전에는 `.gitignore` 로 제외했으나, 워크플로 산출물을 추적하는 정책으로 전환했다.

**보안 경고 — 추적 시 책임은 프로젝트에.** capture 본문은 사용자 원본 입력을 가공 없이 보존하므로 민감정보 (token / API key / password) 가 포함될 수 있다. 추적된 capture 를 commit·push 하면 git 히스토리에 영구 기록되고, 공개 repo 라면 노출된다. 다음은 각 프로젝트의 책임이다:

- commit 전 capture 내용 검토
- 추적하고 싶지 않은 capture 는 프로젝트 `.gitignore` 에 개별 추가 (`git add -f` 의 반대)
- 이미 push 된 secret 은 즉시 rotation (token/key/password 폐기·재발급) — history rewrite 보다 rotation 우선

## 파일 권한

생성 시 권한 (로컬 multi-user 노출 방지):

- capture 파일: 0600
- `raw-captures/` + `archive/` 디렉토리: 0700

생성 코드는 `umask 077` subshell (capture 0600) + `mkdir -p` + `chmod 0700` 패턴 사용. **단 git 은 0600/0700 권한을 보존하지 않는다** — checkout 사본은 보통 0644 이므로, 권한 보호는 로컬 작업 사본에만 적용되고 추적·공유된 사본에는 적용되지 않는다.
