---
name: fr
description: >
  Manage future requests — add, list, prioritize, lifecycle, take team GitHub Issues, hand FRs to the team.
  Subcommands: /fr add, /fr list, /fr pri, /fr inspect, /fr groom, /fr archive, /fr park, /fr status, /fr take, /fr push, /fr do (/fr batch is an alias of /fr do --headless until the next release).
  Use when the user wants to manage backlog items.
  Model self-invocation is limited to list / pri / inspect and local add; take (claims a team Issue), push (creates a GitHub Issue)
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
- "팀 Issue 집어 가자" / "팀 대기열에서 하나 가져와" → `/fr take`로 라우팅
- "이 FR 팀에 넘겨줘" → `/fr push <short-title>`로 라우팅
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
RD_SKILL_BASE=2026-11-21-001711 RD_SKILL_NAME=fr
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
- `groom` → Read `rd-workflow/claude_skills/fr/groom.md` and follow it (it invokes the `fr-groom` skill).
- `archive` → Read `rd-workflow/claude_skills/fr/archive.md` and follow it.
- `park` → Read `rd-workflow/claude_skills/fr/park.md` and follow it.
- `status` → Read `rd-workflow/claude_skills/fr/status.md` and follow it.
- `take` → Read `rd-workflow/claude_skills/fr/take.md` and follow it.
- `pull` → `rd-workflow/claude_skills/fr/pull.md` 파일이 있으면(rd 정본 저장소) Read 하고 그 절차(결함 보고 흡수)를 따릅니다. 파일이 없으면 "`/fr pull` 은 없어졌습니다 — 팀 Issue 는 `/fr take` 로 집습니다" 를 출력하고 파일을 바꾸지 않습니다.
- `push` → Read `rd-workflow/claude_skills/fr/push.md` and follow it.
- `sync` → "`/fr sync` 는 없어졌습니다 — 팀 Issue 는 `/fr take` 로 집고, 내 FR 은 `/fr push` 로 넘깁니다" 를 출력하고 파일을 바꾸지 않습니다.
- `do` → Read `rd-workflow/claude_skills/fr/do.md` and follow it.
- `batch` → 별칭입니다. Read `rd-workflow/claude_skills/fr/do.md` 의 「`/fr batch` 별칭」 절 and follow it.
- 그 외 / 인자 없음 → 아래 사용법 출력 후 종료 (파일 수정 없음 보장)

**Legacy call 처리**: 첫 번째 단어가 `add`, `list`, `pri`, `inspect`, `groom`, `archive`, `park`, `status`, `take`, `pull`, `push`, `sync`, `do`, `batch` 중 어느 것도 아니면 사용법 help를 출력합니다. 파일을 절대 수정하지 않습니다.

### 사용법 출력

```
/fr 사용법:
- `/fr add 내용` — FR 등록
- `/fr list` — 활성 항목 목록 출력
- `/fr pri` — 우선순위 검토
- `/fr inspect <제목>` — 단일 FR 심층 검토 + autopilot 가능 여부 보고
- `/fr groom [<제목들>]` — idea FR 의 판정 권장표를 받아 한 번에 validated·parked·dropped 로 정리 (제목 없으면 idea 전부, `fr-groom` skill 호출. 모델까지 올리려면 `/fr-groom` 직접 입력)
- `/fr archive` — done 항목 인덱스에서 일괄 삭제
- `/fr park <제목>` — 항목을 parked로 이동
- `/fr status <제목> <상태>` — 항목 상태 변경
- `/fr take` — 팀 GitHub Issue 하나를 골라 선점하고 FR 을 만들어 착수
- `/fr push [제목]` — 내 FR 을 팀 GitHub Issue 로 넘김 (FR 은 handed-off 로 닫힘)
- `/fr do [--model <값>] [--effort <값>] [<slug들>]` — 여러 FR 을 줄기로 묶어 병렬로 띄우고 감시·발행 허가·마감까지 처리 (터미널 herdr)
- `/fr do --headless [--finish push|merge|none] [--model <값>] [--effort <값>] [<slug들>]` — 고른 FR 을 무인으로 순차 완주 (모델·effort 는 그 회차에만 적용)
- `/fr batch <인자>` — `/fr do --headless` 의 별칭 (별칭, 다음 배포에서 제거)

예: `/fr add autopilot에서 review gate 자동화`
```

---

## 백엔드 결정

`take`·`push`·정본 `pull`(결함 보고 흡수)은 GitHub 를 부릅니다. 아래 전제조건을 검증합니다. `add` 는 `fr_github` 값과 상관없이 GitHub 를 부르지 않습니다. `fr_github` 는 `/fr list` 의 GitHub 칸 표시에만 남습니다.

1. 인자의 `--github`·`--local` 플래그는 쓰지 않습니다. 발견하면 인자에서 제거하고 무시합니다.
2. 대상 저장소는 `bash rd-workflow/scripts/issue_queue.sh repos` 가 정합니다. 설정 키는 `rd-workflow/config/workflow.json` 의 세 가지입니다.
   - `issue_queue_repos`: Issue 를 가져올 저장소 배열 (`owner/repo`, `host/owner/repo`). 없으면 overlay 의 submodule URL 전부, submodule 이 없으면 `origin` 입니다.
   - `issue_queue_labels`: 이 중 하나라도 붙은 Issue 만 고르기 화면에 보입니다. 없으면 라벨로 거르지 않습니다.
   - `issue_claim_label`: 선점할 때 assignee 와 함께 붙이는 라벨입니다. 이 라벨이 붙은 Issue 는 고르기 화면에서 빠집니다.
3. 선점 표시는 항상 GitHub assignee 입니다. 라벨은 팀 규약이 있을 때만 함께 붙습니다.
4. 전제조건을 검증합니다:
   - `gh` CLI 설치 여부 — 미설치: "gh CLI가 설치되어 있지 않습니다" 출력 후 종료
   - `gh auth status` 통과 여부 — 미인증: "gh auth login으로 인증이 필요합니다" 출력 후 종료
   - 대상 저장소 결정 — `/fr push` 에 `--repo` 가 있으면 그 값을 대상으로 쓰고 이 검사를 건너뜁니다. 그 밖에는 `issue_queue.sh repos` 가 rc 3 이면 "Issue 를 가져올 저장소를 정하지 못했습니다 — `issue_queue_repos` 를 설정하십시오" 출력 후 종료
5. 검증 실패 시 로컬 fallback 없이 종료합니다.
6. **예외 — 결함 보고 전달 경로**: `workflow-defect-reporting.md` 규약에 따른 결함 보고 발행은 전제조건 실패 시 **종료하지 않습니다.** 보고 파일을 그대로 두고 미전달로 표시한 뒤, 사유·미전달 목록·재시도 명령을 안내합니다. 여기서 종료하면 보고서가 다시 조용히 쌓여 규약이 해결하려는 문제로 되돌아갑니다. 이 예외는 결함 보고 경로에만 적용되며 `take`·`push` 는 위 5번 그대로입니다.
7. `take`·`push`·정본 `pull` 은 설정과 무관하게 항상 전제조건 검증을 실행합니다.



---

## GitHub 공통 사항

### Label 체계

rd 가 만들거나 읽는 라벨은 생산자 라벨 둘뿐입니다. Issue 상태 라벨(`fr:*`)은 만들지도 읽지도 않습니다.

- `rd-handoff`: `/fr push` 가 넘긴 Issue (`issue_queue.sh produce --label rd-handoff`)
- `defect-report`: 결함 보고 전달 (`defect_reports.sh`)
- 선점 표시는 assignee 이고, `issue_claim_label` 은 팀 규약이 있을 때만 붙입니다.
- priority 는 사용하지 않습니다 (pri 는 로컬 전용).

### 에러 처리

| 상황 | 메시지 | 동작 |
|------|--------|------|
| gh 미설치 | "gh CLI가 설치되어 있지 않습니다" | 종료 |
| gh 미인증 | "gh auth login으로 인증이 필요합니다" | 종료 |
| 대상 저장소 미결정 | "Issue 를 가져올 저장소를 정하지 못했습니다" | 종료 |
| Issue 생성·조회 실패 | `issue_queue.sh` 의 종료 코드와 stderr | push: 건너뜀+경고, take: 종료 코드별 안내 (`take.md`) |

### 데이터 분리

- 로컬과 GitHub 는 독립 저장소입니다. 연결은 인덱스의 GitHub 컬럼과 상세 파일의 `github-issue` 필드 양쪽에서 추적합니다.
- 기존 `github-issue` 필드는 설정을 바꿔도 유지합니다 (삭제 안 함).
- 선점 장부는 `$(git rev-parse --git-common-dir)/rd-issue-claims.tsv` 이고 저장소에 커밋되지 않습니다.

---

## 전역 규칙

- `priority` 허용 값: `P1`, `P2`, `P3`, `-` 만 허용. 인덱스에서만 관리하고 상세 파일에는 넣지 않습니다.
- `/fr add`는 FR 등록만 합니다. REQUEST.md 작성, 구현 착수 금지.
- 서브커맨드가 없거나 알 수 없으면 사용법만 출력하고 종료합니다. 파일 수정 없음.
- `github-issue`는 인덱스(GitHub 컬럼)와 상세 파일 양쪽에서 관리합니다. 연결/해제 시 양쪽 모두 갱신합니다.
- `take`·`push`·정본 `pull` 은 `fr_github` 설정과 무관하게 실행하며 항상 전제조건 검증을 합니다.
- 종료 상태는 `done`·`dropped`·`handed-off` 입니다. `handed-off` 는 `/fr push` 로만 만들어집니다.
- 결함 보고 전달은 FR 경로와 분리됩니다 — 라벨은 `defect-report`, 도구는 `defect_reports.sh`, 실패는 종료가 아니라 미전달 표시입니다.
- **모델 자기호출 경계**: 모델이 사용자의 명시 요청 없이 이 skill 을 스스로 호출한 경우 `list`·`pri`·`inspect` 와 **`add`** 만 수행합니다.
  - `add` 는 GitHub 를 부르지 않습니다. 팀 대기열이 있는 저장소(`issue_queue.sh has-team-queue` 가 0)이면 등록을 마친 뒤 "팀에 넘기려면 `/fr push <제목>` 을 요청해 주십시오" 를 알립니다. 판정 명령은 `add.md` 7단계에 있습니다.
  - `take`(팀 Issue 선점, 원격 변경)·`push`(외부 저장소 Issue 발행)·`do`(여러 FR 처리. 별칭 `batch` 포함)·`groom`(문답 검증 뒤 상태 변경)·`archive`·`park`·`status` 는 사용자의 명시 요청을 요구하며, 요청이 없으면 수행하지 않고 어떤 요청이 필요한지 알립니다.
  - 플래그가 skill 단위여서 부분 개방이 불가하므로 이 경계는 문서 계약이며 harness 강제가 아닙니다 (`AUTONOMY.md` 「실행 모드와 skill 호출 권한」).
