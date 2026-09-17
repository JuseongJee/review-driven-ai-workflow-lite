## /fr add

`add` 뒤의 텍스트를 입력으로 받아 Future Request를 등록한다.

### 절차 (local)

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기 (인덱스 형식 확인 + 중복 체크).
2. 입력에서 다음을 추출한다:
   - **short-title**: 영문 kebab-case, 간결하게 (예: `autopilot-review-gate`)
     canonical 정규화: `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (영문 kebab-case, 영숫자 시작·끝, 사이만 `-` 허용)
     추가 거절 케이스: `-` 단독, empty, hyphen-only (`---` 등) — reserved sentinel 충돌이므로 보정 요청.
   - **summary**: 한국어 한두 문장 요약
   - **kind**: feature | bug | refactor | tech-debt | tooling | research | test (맥락에서 추론, 불확실하면 feature)
3. raw capture 파일 생성: `rd-workflow-workspace/raw-captures/{date}-fr-{short-title}.md`

   frontmatter(date/stage/short-title/source)는 CLI가 생성한다. stdin에는 본문만 전달한다:
   ```bash
   bash rd-workflow/scripts/rd task capture --stage fr --title {short-title} --source direct <<'CAPTURE_EOF'
   ## 원본 입력
   {사용자 원문}
   CAPTURE_EOF
   ```
   `--title` 은 반드시 넘긴다 — Step 2 에서 확정한 short-title 을 그대로 쓴다. 생략하면 진행 중 작업의 Short Title(5단계에서 건드리지 않기로 한 값)이 아니라 `untitled` 로 저장되어 사후 정정이 필요하다.
   (`--source`: 직접 호출이면 `--source direct`, 자연어 라우팅이면 `--source routed`. CLI 기본값은 `routed`)
   충돌 시 `-2`, `-3` suffix.
   캡처 실패 시 경고만 — FR 등록 차단 안 함 — CLI 가 fail-open (exit 0) 으로 처리.

4. 상세 파일 생성: `rd-workflow-workspace/backlog/items/YYYY-MM-DD-{short-title}.md`

```md
# YYYY-MM-DD {short-title}
- status: idea
- kind: {kind}
- summary: {summary}
- why: {사용자 입력에서 추론, 없으면 "-"}
- related context: {대화 맥락에서 추론, 없으면 "-"}
- related files: {관련 파일, 없으면 "-"}
- not now because: {왜 지금 안 하는지, 없으면 "별도 작업으로 진행 예정"}
- revisit when: -
- github-issue: -
- request seed: {REQUEST로 만들 때 쓸 초안, 없으면 summary 반복}
```

5. `CURRENT_TASK.md ## Short Title` 갱신 분기:

   `bash rd-workflow/scripts/rd task guard --candidate "<short-title>" --mode fr-add` 를 실행하고 출력의 `decision` 에 따라 진행한다:
   - `write`: `message` 를 사용자에게 알리고 진행 (task-state `short-title` 이 sentinel `-` 인 경우 — LC-18 write 진입점)
   - `proceed-readonly`: 변경 없이 진행 (진행 중 작업이 있어 Short Title 을 건드리지 않고 FR 등록만 계속)

   fr-add 모드는 차단이 없다 (`block-*` decision 발생 안 함). task-state의 `short-title` 키가 부재이거나 값이 비어있으면 CLI 가 `proceed-readonly` 를 반환하고, FR 등록 절차(인덱스 + items/ + FR 캡처)는 정상 계속한다.

6. `FUTURE_REQUESTS.md`의 `## 인덱스` 테이블 끝에 행 추가:

```
| {날짜} | {short-title} | {summary} | {kind} | idea | - | [상세](items/YYYY-MM-DD-{short-title}.md) |
```

컬럼 순서: 날짜 | 제목 | 요약 | **종류** | 상태 | 우선순위 | 상세. `종류` 값은 Step 2 에서 추론한 `kind` 를 그대로 사용한다. **셀 본문의 `|` 는 코드 스팬 안이라도 반드시 `\|` 로 이스케이프한다** — 이스케이프하지 않으면 GFM 이 그 자리에서 칸을 쪼개 표가 깨지고, `archive.sh` 의 인덱스 충돌 자동 병합(`merge_fr_index.sh`)이 그 행을 거부해 발행이 중단된다. 셸 코드를 인용할 때 특히 주의한다. GitHub 연동이 활성이면 아래 `GitHub 연동` 섹션의 절차로 GitHub 정보를 추가한다 (인덱스에 GitHub 컬럼이 별도로 있는 변형 형식을 쓰는 경우에만 해당).

6.5. **기본 브랜치 등록 커밋** — 등록 결과가 fr 브랜치와 함께 유실되지 않도록, 호출 브랜치와 무관하게 기본 브랜치에 커밋한다. **GitHub 연동이 활성이면 아래 `GitHub 연동` 절차(상세·인덱스 행에 issue 정보 반영)를 먼저 마친 뒤 한 번만 호출한다** — 등록 커밋 뒤에 행·상세를 고치면 기본 브랜치의 원본과 fr 브랜치의 수정본이 같은 경로에서 갈라져 archive 가 인덱스 단독 충돌로 처리하지 못한다(상세 add/add 충돌):

   ```bash
   bash rd-workflow/scripts/rd task fr-register --slug {short-title}
   ```

   첫 줄 `result=…` 로 분기한다:
   - `committed`: 둘째 줄(`FR 등록 커밋: <기본 브랜치> <해시>`) 을 완료 메시지에 그대로 포함한다. **AI 는 별도 등록 커밋을 만들지 않고 push 하지 않는다** — 이 커밋이 등록 커밋이며, 그 작업의 `archive.sh` push 에 실린다. fr 브랜치 세션이면 현재 워킹트리의 등록 파일은 그대로 두어(다음 iteration commit 에 동일 내용으로 실림) 즉시 보이게 한다.
   - `already`: 이미 기본 브랜치에 있다 — 완료 메시지에 그 줄을 포함한다.
   - `skipped` (exit 3): **등록은 성공**이다(파일은 현재 워킹트리에 있음). 둘째 줄의 사유와 복구 명령을 경고로 그대로 보이고 계속한다. 커밋 게이트·훅을 우회해 대신 커밋하지 않는다.
   helper 는 인덱스 행 1개·상세 1개·캡처 1개(선택) 외 어떤 변경도 커밋할 수 없다. 규약 상세는 `rd-workflow/scripts/lifecycle/README.md` 의 `fr-register` 절.

7. 완료 메시지 출력:

> FR 등록: **{short-title}** — {summary}
> FR 등록 커밋: {기본 브랜치} {해시}   ← 6.5 의 둘째 줄 (skipped 면 경고 줄)

### 규칙

- **한 세션에서 여러 건을 등록해도 `CURRENT_TASK.md ## Short Title` 은 첫 등록으로 고정된다** (5단계 guard 의 `write`/`proceed-readonly` 분기).
- **reset**: 위 5단계에서 잘못 고정된 Short Title 을 되돌려야 하면 `bash rd-workflow/scripts/rd task set-title -` 를 쓴다. 허용 조건은 `Status == 대기 중` **그리고** `fr-branch` 가 활성이 아님(값이 비었거나 그 브랜치 ref 가 없음) 이며, 둘 다 성립해야 `short-title`·`source-fr` 을 함께 sentinel(`-`)로 되돌린다. **`--force` 로는 reset 되지 않는다** — 이 경로는 진행 중 작업 보호의 우회 통로를 열지 않기 위해 의도적으로 `--force` 를 받지 않으며, 조건 미충족·force 동반 모두 상태를 바꾸지 않고 사유만 알린다. 정말 막혔다면 그 작업을 archive 하는 것이 정본 경로다.
- 같은 short-title이 인덱스에 이미 있거나 `items/` 에 같은 파일명이 존재하면 등록하지 않고 사용자에게 알린다. (done/dropped로 인덱스에서 삭제된 항목도 상세 파일이 남아있으므로 파일 존재 여부를 반드시 확인한다.) 기본 브랜치의 `items/` 에 같은 파일이 있는지도 확인한다 (`git cat-file -e <기본 브랜치>:rd-workflow-workspace/backlog/items/<파일>`) — fr 브랜치 세션에서는 현재 트리에 없어도 기본 브랜치에 이미 등록된 FR 이 있을 수 있다.
- 입력이 너무 짧아서 summary를 만들 수 없으면 한 줄 질문으로 보충을 요청한다.
- FUTURE_REQUESTS.md의 기존 형식(테이블 구조, 상태 값)을 변경하지 않는다.
- 이 subcommand는 FR 등록만 한다. REQUEST.md 작성이나 구현은 하지 않는다.
- 등록 대상이 rd-workflow 인프라 자체의 결함이면(소비 프로젝트 한정) FR로 등록하지 않고 `rd-workflow/docs/guides/workflow-defect-reporting.md` 규약(보고 파일 생성)을 따른다.
- GitHub 연동 시 Issue 생성 실패가 로컬 FR 등록을 막지 않는다.

### GitHub 연동

**모델 자기호출이면 이 절을 실행하지 않는다.** 사용자의 명시 요청 없이 모델이 스스로 `/fr add` 를 호출한 경우, `fr_github` 가 활성이어도 로컬 등록에서 멈추고 "GitHub Issue 발행은 사용자 요청이 필요합니다 — 발행하려면 `/fr push <제목>` 를 요청해 주십시오" 를 알린다. `gh issue create` 는 외부 저장소에 공개 기록을 남기는 비가역 행위이므로 backend 설정이 사용자 승인을 대신하지 않는다 (`AUTONOMY.md` 「실행 모드와 skill 호출 권한」).

GitHub 연동이 활성화되어 있고 **사용자가 직접 호출**했을 때만 실행한다. 6단계(행·상세 작성)까지 마친 뒤, **6.5(기본 브랜치 등록 커밋) 앞에** 실행한다 — 등록 커밋에는 issue 정보가 반영된 최종 행·상세가 실려야 한다.

1. `gh issue create` 실행:
   - title: short-title
   - body: 마크다운 포맷의 FR 상세 (summary, why, related context, related files, not now because)
   - labels: `fr:idea`, `fr:{kind}`
2. label이 repo에 없으면 `gh label create`로 생성을 시도한다.
   - **status label 생성 실패 → Issue 생성 중단, 에러 출력**
   - kind label 생성 실패 → 경고 출력, label 없이 진행
3. 성공 시 로컬 상세 파일의 `github-issue: -` 값을 `github-issue: owner/repo#N`으로 변경하고, 인덱스의 GitHub 컬럼도 `owner/repo#N`으로 갱신한다.
4. 완료 메시지에 issue URL을 포함한다.

Issue 생성 실패 시: 로컬 FR은 유지하고 "GitHub Issue 생성 실패, 로컬 FR만 등록됨" 경고를 출력한다.
