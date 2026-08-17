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

컬럼 순서: 날짜 | 제목 | 요약 | **종류** | 상태 | 우선순위 | 상세. `종류` 값은 Step 2 에서 추론한 `kind` 를 그대로 사용한다. GitHub 연동이 활성이면 아래 `GitHub 연동` 섹션의 절차로 GitHub 정보를 추가한다 (인덱스에 GitHub 컬럼이 별도로 있는 변형 형식을 쓰는 경우에만 해당).

7. 완료 메시지 출력:

> FR 등록: **{short-title}** — {summary}

### 규칙

- 같은 short-title이 인덱스에 이미 있거나 `items/` 에 같은 파일명이 존재하면 등록하지 않고 사용자에게 알린다. (done/dropped로 인덱스에서 삭제된 항목도 상세 파일이 남아있으므로 파일 존재 여부를 반드시 확인한다.)
- 입력이 너무 짧아서 summary를 만들 수 없으면 한 줄 질문으로 보충을 요청한다.
- FUTURE_REQUESTS.md의 기존 형식(테이블 구조, 상태 값)을 변경하지 않는다.
- 이 subcommand는 FR 등록만 한다. REQUEST.md 작성이나 구현은 하지 않는다.
- 등록 대상이 rd-workflow 인프라 자체의 결함이면(소비 프로젝트 한정) FR로 등록하지 않고 `rd-workflow/docs/guides/workflow-defect-reporting.md` 규약(보고 파일 생성)을 따른다.
- GitHub 연동 시 Issue 생성 실패가 로컬 FR 등록을 막지 않는다.

### GitHub 연동

GitHub 연동이 활성화되어 있을 때만 실행한다. local 절차 완료 후 추가로 실행한다.

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
