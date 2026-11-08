---
name: fr
description: >
  Manage future requests — add, list, prioritize, lifecycle, sync with GitHub Issues.
  Subcommands: /fr add, /fr list, /fr pri, /fr inspect, /fr groom, /fr archive, /fr park, /fr status, /fr pull, /fr push, /fr sync, /fr do (/fr batch is an alias of /fr do --headless until the next release).
  Use when the user wants to manage backlog items.
  Model self-invocation is limited to list / pri / inspect / pull and local-only add; publishing to GitHub (add while fr_github is enabled, push, sync)
  and do (batch alias), groom, archive, park, status all require an explicit user request.
user-invocable: true
---

# FR — Future Request 관리

Typical user requests:
- "/fr add autopilot에서 review gate 자동화"
- "/fr list"
- "/fr pri"
- "/fr archive"
- "/fr park workflow-branch-clarification"
- "/fr status some-title validated"
- "/fr groom" / "/fr groom some-title"
- "이거 FR에 넣어줘" → `/fr add`로 라우팅
- "future request에 기록해줘" → `/fr add`로 라우팅
- "FR 목록 보여줘" → `/fr list`로 라우팅
- "FR 우선순위 검토해줘" → `/fr pri`로 라우팅
- "이 FR 검토해줘" → `/fr inspect <short-title>`로 라우팅
- "N번 검토해줘" / "N번 autopilot 가능한지 봐줘" → 직전 `/fr list` 출력에서 N번 행의 short-title을 찾아 `/fr inspect <short-title>`로 라우팅 (번호는 inspect의 공식 인자가 아니라 라우팅 단계 변환용)
- "done 항목 정리해줘" → `/fr archive`로 라우팅
- "이거 parked로 옮겨줘" → `/fr park`로 라우팅
- "idea FR 검증해줘" / "이 FR 문답으로 정리해줘" → `/fr groom [<short-title>]`로 라우팅
- "착수 가능한 것들 띄워" / "더 띄울 FR 없나" → `/fr do`로 라우팅
- "/fr do --headless" / "준비된 FR 무인으로 돌려줘" → `/fr do --headless`로 라우팅

사용자가 `/fr <subcommand> [args]` 형식으로 호출하거나, 위의 자연어 요청으로 호출합니다.

## rd-workflow 버전 대조

이 skill 은 아래 `RD_SKILL_BASE` 보다 나중에 배포된 rd-workflow 를 전제한다. 첫 작업 단계보다 먼저, 프로젝트 루트에서 아래 명령을 이 호출에서 한 번 실행한다.

- 출력이 없으면 그대로 진행한다.
- 출력이 있으면 출력 전문을 사용자에게 알리고, 템플릿을 sync 할지 그대로 계속할지 묻고 멈춘다. 사용자가 계속을 지시하면 진행한다.
- autopilot·무인 실행처럼 물을 사람이 없으면 계속하지 않고 그 출력을 중단 사유로 보고한다.

```bash
bash -s <<'RD_SKILL_COMPAT'
RD_SKILL_BASE=2026-11-07-210251 RD_SKILL_NAME=fr
vf="rd-workflow/VERSION"
if [ ! -f "$vf" ] && [ -f "_ROOT_FILES/rd-workflow/VERSION" ]; then exit 0; fi
v=""; [ -f "$vf" ] && v="$(cat "$vf")"; v="${v#lite-}"
if [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]] && [[ "$v" > "$RD_SKILL_BASE" ]]; then exit 0; fi
echo "rd-workflow 버전 불일치 — skill '$RD_SKILL_NAME' 은 $RD_SKILL_BASE 보다 나중에 배포된 rd-workflow 가 필요합니다."
echo "프로젝트: $PWD"
echo "프로젝트 VERSION: ${v:-없음} (파일: $vf)"
echo "이 상태로 진행하면 skill 이 가리키는 문서 절·스크립트·인자가 없어 중간에 실패할 수 있습니다."
echo "해결: 템플릿을 sync 하십시오 (/tpl update 또는 rd-workflow/docs/guides/sync_template.md 절차)."
RD_SKILL_COMPAT
```

## 서브커맨드 라우팅

첫 번째 인자를 파싱합니다:

- `add` → Read `rd-workflow/claude_skills/fr/add.md` and follow it.
- `list` → Read `rd-workflow/claude_skills/fr/list.md` and follow it.
- `pri` → Read `rd-workflow/claude_skills/fr/pri.md` and follow it.
- `inspect` → Read `rd-workflow/claude_skills/fr/inspect.md` and follow it.
- `groom` → Read `rd-workflow/claude_skills/fr/groom.md` and follow it.
- `archive` → Read `rd-workflow/claude_skills/fr/archive.md` and follow it.
- `park` → Read `rd-workflow/claude_skills/fr/park.md` and follow it.
- `status` → Read `rd-workflow/claude_skills/fr/status.md` and follow it.
- `pull` → Read `rd-workflow/claude_skills/fr/pull.md` and follow it.
- `push` → Read `rd-workflow/claude_skills/fr/push.md` and follow it.
- `sync` → Read `rd-workflow/claude_skills/fr/sync.md` and follow it.
- `do` → Read `rd-workflow/claude_skills/fr/do.md` and follow it.
- `batch` → 별칭입니다. Read `rd-workflow/claude_skills/fr/do.md` 의 「`/fr batch` 별칭」 절 and follow it.
- 그 외 / 인자 없음 → 아래 사용법 출력 후 종료 (파일 수정 없음 보장)

**Legacy call 처리**: 첫 번째 단어가 `add`, `list`, `pri`, `inspect`, `groom`, `archive`, `park`, `status`, `pull`, `push`, `sync`, `do`, `batch` 중 어느 것도 아니면 사용법 help를 출력합니다. 파일을 절대 수정하지 않습니다.

### 사용법 출력

```
/fr 사용법:
- `/fr add 내용` — FR 등록
- `/fr list` — 활성 항목 목록 출력
- `/fr pri` — 우선순위 검토
- `/fr inspect <제목>` — 단일 FR 심층 검토 + autopilot 가능 여부 보고
- `/fr groom [<제목들>]` — idea FR 을 문답으로 검증해 validated·parked·dropped 로 정리 (제목 없으면 idea 전부)
- `/fr archive` — done 항목 인덱스에서 일괄 삭제
- `/fr park <제목>` — 항목을 parked로 이동
- `/fr status <제목> <상태>` — 항목 상태 변경
- `/fr pull` — GitHub Issues → 로컬 FR 가져오기
- `/fr push [제목]` — 로컬 FR → GitHub Issue 내보내기
- `/fr sync` — 연결된 항목 status 동기화
- `/fr do [<slug들>]` — 여러 FR 을 줄기로 묶어 병렬로 띄우고 감시·발행 허가·마감까지 처리 (터미널 herdr)
- `/fr do --headless [--finish push|merge|none] [<slug들>]` — 고른 FR 을 무인으로 순차 완주
- `/fr batch <인자>` — `/fr do --headless` 의 별칭 (별칭, 다음 배포에서 제거)

예: `/fr add autopilot에서 review gate 자동화`
```

---

## 백엔드 결정

서브커맨드 실행 전에 GitHub 연동 여부를 결정합니다.

1. 인자에서 `--github` 또는 `--local` 플래그를 탐색합니다. 발견하면 인자에서 제거합니다.
   - `--github`: GitHub 연동 강제 활성화
   - `--local`: GitHub 연동 강제 비활성화
2. 플래그가 없으면 `rd-workflow/config/workflow.json`의 `fr_github` 값을 읽습니다.
3. 파일이 없거나 `fr_github` 키가 없으면 기본값 `false` (연동 비활성).
4. GitHub 연동 활성화 시 전제조건을 검증합니다:
   - `gh` CLI 설치 여부 — 미설치: "gh CLI가 설치되어 있지 않습니다" 출력 후 종료
   - `gh auth status` 통과 여부 — 미인증: "gh auth login으로 인증이 필요합니다" 출력 후 종료
   - `gh repo view` 성공 여부 — 실패: "git remote가 설정되지 않았거나 Issues가 비활성화되어 있습니다" 출력 후 종료
5. 검증 실패 시 로컬 fallback 없이 종료합니다.
6. **예외 — 결함 보고 전달 경로**: `workflow-defect-reporting.md` 규약에 따른 결함 보고 발행은 전제조건 실패 시 **종료하지 않습니다.** 보고 파일을 그대로 두고 미전달로 표시한 뒤, 사유·미전달 목록·재시도 명령을 안내합니다. 여기서 종료하면 보고서가 다시 조용히 쌓여 규약이 해결하려는 문제로 되돌아갑니다. 이 예외는 결함 보고 경로에만 적용되며 `add`/`push`/`pull`/`sync` 의 FR 경로는 위 5번 그대로입니다.
7. `pull`, `push`, `sync` 서브커맨드는 `fr_github` 설정과 무관하게 항상 전제조건 검증을 실행합니다.

이후 각 서브커맨드는 결정된 연동 여부에 따라 동작합니다.

---

## GitHub 공통 사항

### Label 체계

- **status**: `fr:idea`, `fr:validated`, `fr:ready-for-request`
- **종료**: `fr:done`, `fr:dropped`
- **kind**: `fr:feature`, `fr:bug`, `fr:refactor`, `fr:tech-debt`, `fr:tooling`, `fr:research`, `fr:test`
- **priority**: 사용하지 않음 (pri는 로컬 전용)

`fr:` namespace를 FR 전용으로 사용합니다. 기존 repo에 `fr:*` label이 있으면 충돌 가능 — pull은 status label 필수 조건으로 완화됩니다.

### 에러 처리

| 상황 | 메시지 | 동작 |
|------|--------|------|
| gh 미설치 | "gh CLI가 설치되어 있지 않습니다" | 종료 |
| gh 미인증 | "gh auth login으로 인증이 필요합니다" | 종료 |
| repo 미연결 | "git remote가 설정되지 않았습니다" | 종료 |
| Issues 비활성 | "이 저장소에서 Issues가 비활성화되어 있습니다" | 종료 |
| status label 생성 실패 | "fr:{status} label 생성 실패 — Issue 생성 중단" | **에러, 해당 항목 중단** |
| kind label 생성 실패 | "fr:{kind} label 생성 실패" | 경고, label 없이 진행 |
| Issue 생성 실패 | "GitHub Issue 생성 실패" | add: 로컬 유지+경고, push: 건너뜀+경고 |

### 데이터 분리

- 로컬과 GitHub는 독립 저장소입니다. 연결은 인덱스의 GitHub 컬럼과 상세 파일의 `github-issue` 필드 양쪽에서 추적합니다.
- 연동을 비활성화해도 기존 `github-issue` 필드는 유지합니다 (삭제 안 함).
- 사용자 안내: "GitHub 연동을 비활성화하면 로컬 데이터만 표시됩니다. GitHub Issues는 별도로 관리해야 합니다."

---

## 전역 규칙

- `priority` 허용 값: `P1`, `P2`, `P3`, `-` 만 허용. 인덱스에서만 관리하고 상세 파일에는 넣지 않습니다.
- `/fr add`는 FR 등록만 합니다. REQUEST.md 작성, 구현 착수 금지.
- 서브커맨드가 없거나 알 수 없으면 사용법만 출력하고 종료합니다. 파일 수정 없음.
- `github-issue`는 인덱스(GitHub 컬럼)와 상세 파일 양쪽에서 관리합니다. 연결/해제 시 양쪽 모두 갱신합니다.
- pull/push/sync는 `fr_github` 설정과 무관하게 `--github` 플래그 없이도 실행 가능합니다 (항상 전제조건 검증 실행).
- 결함 보고 전달은 FR 경로와 분리됩니다 — 라벨은 `defect-report`, 도구는 `defect_reports.sh`, 실패는 종료가 아니라 미전달 표시입니다.
- **모델 자기호출 경계**: 모델이 사용자의 명시 요청 없이 이 skill 을 스스로 호출한 경우 `list`·`pri`·`inspect`·`pull` 과 **로컬 전용 `add`** 만 수행합니다.
  - `add` 는 자기호출일 때 **유효 backend 와 무관하게 로컬로만 등록**합니다. GitHub 연동이 활성이어도 `gh issue create` 로 넘어가지 않고, 로컬 등록을 마친 뒤 "GitHub Issue 발행은 사용자 요청이 필요합니다 — 발행하려면 `/fr push <제목>` 를 요청해 주십시오" 를 알립니다. `add` 의 `GitHub 연동` 절차는 사용자가 직접 호출한 경우에만 실행합니다.
  - `push`(외부 저장소 Issue 발행)·`sync`(원격 label 변경·Issue close)·`do`(여러 FR 처리. 별칭 `batch` 포함)·`groom`(문답 검증 뒤 상태 변경)·`archive`·`park`·`status` 는 사용자의 명시 요청을 요구하며, 요청이 없으면 수행하지 않고 어떤 요청이 필요한지 알립니다.
  - 플래그가 skill 단위여서 부분 개방이 불가하므로 이 경계는 문서 계약이며 harness 강제가 아닙니다 (`AUTONOMY.md` 「실행 모드와 skill 호출 권한」).
