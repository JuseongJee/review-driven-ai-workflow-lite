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

   디렉토리 0700 보장 + umask 077 subshell 로 캡처 파일 0600 보장:
   ```bash
   assert_no_symlink_in_path() {
     _aslnp_p="$1"
     case "$_aslnp_p" in
       /*) ;;
       *)  _aslnp_p="$PWD/$_aslnp_p" ;;
     esac
     _aslnp_d="$_aslnp_p"
     while [ "$_aslnp_d" != "/" ] && [ -n "$_aslnp_d" ]; do
       if [ -L "$_aslnp_d" ]; then
         echo "경고: path component ($_aslnp_d) 가 symlink 입니다. 보안상 중단합니다." >&2
         unset _aslnp_p _aslnp_d
         return 1
       fi
       _aslnp_d=$(dirname "$_aslnp_d")
     done
     unset _aslnp_p _aslnp_d
     return 0
   }
   if ! assert_no_symlink_in_path "rd-workflow-workspace/raw-captures"; then
     echo "경고: raw-captures 경로에 symlink 가 있어 캡처를 건너뜁니다." >&2
   else
     mkdir -p rd-workflow-workspace/raw-captures
     chmod 0700 rd-workflow-workspace/raw-captures
     ( umask 077 && cat > "$capture_path" <<EOF
   ---
   date: YYYY-MM-DD HH:MM
   stage: fr
   short-title: {short-title}
   source: direct | routed
   ---

   ## 원본 입력
   {사용자 원문}
   EOF
     )
   fi
   ```
   frontmatter 형식: `date`, `stage`, `short-title`, `source` (`direct` | `routed`) 4개 고정.
   본문: `## 원본 입력` 섹션 + 사용자 원문 (byte-level 동일, 가공 금지).
   충돌 시 `-2`, `-3` suffix.
   캡처 실패 시 경고만 — FR 등록 차단 안 함.

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

   현재 `## Short Title` 값을 read 한다.

   - **분기 1 — 필드 자체가 없음 (legacy repo, 구 템플릿):** `CURRENT_TASK.md` 갱신 안 함 (warn-only). FR 등록 절차(인덱스 + items/ + FR 캡처)는 정상 진행. 사용자에게 명시적 안내:
     > `CURRENT_TASK.md ## Short Title` 섹션이 없습니다 (구 템플릿).
     > FR 은 등록되었지만 진행 중 작업 추적이 없는 상태입니다.
     > `sync_template` 마이그레이션 후 `CURRENT_TASK.md` 의 `## Short Title` 을 명시적으로 설정하세요.

   - **분기 2 — 값이 `-`:** start point로서 부여. Step 2의 short-title 로 `## Short Title` 갱신.

   - **분기 3 — 값이 이미 non-`-`:** 진행 중 작업의 short-title이므로 **read-only** (변경 금지). 새 FR 등록은 그대로 진행 — FR 자체와 FR 캡처는 새 short-title 사용, `CURRENT_TASK.md ## Short Title` 만 손대지 않음.

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
