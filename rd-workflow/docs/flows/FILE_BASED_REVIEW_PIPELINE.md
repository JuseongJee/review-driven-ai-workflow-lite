# File-based Review Pipeline

이 문서는 review 세션을 어떻게 만들고 어떻게 끝내는지 적어 둔 규칙 문서입니다.

평소 사용 흐름:

- 사용자는 검토 시작만 말합니다
- Claude가 세션 파일과 검토 대상을 읽고 자기 턴 파일을 씁니다
- Reviewer 차례가 되면 Author가 adapter를 실행해 Reviewer 턴 파일을 만듭니다
- 사람 결정이 필요할 때만 `awaiting-user`로 바꿔 사용자에게 돌립니다

## 언제 쓰는가

- `PROJECT_CONTEXT.md` 검토
- `REQUEST.md` 검토
- spec / plan 검토
- 최종 diff 검토

## 세션 위치

- `rd-workflow-workspace/handoffs/review_pipeline/<session-id>/`

## 세션 생성

권장 명령:

- `bash rd-workflow/scripts/prepare_review_pipeline.sh <review-kind> [args...]`

스크립트를 쓸 수 없을 때:

- `bash rd-workflow/scripts/init_review_pipeline.sh "<session-slug>" "<review-type>" "<review-target>" "<review-goal>"`

review kind:

- `project-context`
- `request`
- `spec-plan`
- `diff`

## 세션 기본 파일

- `SESSION.md`: 상태와 현재 차례
- `CHECKPOINT.md`: 합의 내용과 열린 쟁점
- `USER_ACTION.md`: 사람에게 물을 질문
- `turns/NNN_<agent>.md`: Author / Reviewer 턴 기록

## 상태 값

- `awaiting-author`
- `awaiting-reviewer`
- `awaiting-user`
- `closed`

## 기본 흐름

1. `prepare_review_pipeline.sh`로 세션 디렉터리와 기본 파일을 만듭니다
2. Author가 세션 파일과 검토 대상을 읽습니다
3. Author가 자기 턴 파일 하나를 씁니다
4. Reviewer 차례가 되면 `run_review_turn.sh ...`를 실행해 Reviewer 턴을 생성합니다
5. 최신 Reviewer 턴에 `이의 없음`이 나올 때까지 3~4 단계를 반복합니다
6. 사람 결정이 필요하거나 총 턴 수가 20에 도달하면 `awaiting-user`로 바꿉니다

## 턴 규칙

- 자기 차례가 아니면 새 턴 파일을 만들지 않는다
- 자기 차례면 새 턴 파일 하나만 추가한다
- `CHECKPOINT.md`와 `SESSION.md`를 함께 갱신한다
- 구현이나 머지를 직접 확정하지 않는다
- 이미 합의된 쟁점은 반복하지 않는다
- 이전 턴 파일을 전부 읽지 않는다. CHECKPOINT.md와 최신 턴 파일로 맥락을 파악하고, 부족할 때만 특정 턴을 선택적으로 참조한다 (턴 파일 경로: SESSION_DIR/turns/NNN_role.md)
- CHECKPOINT.md의 Open Issues에는 근거 턴, 해소 조건, 미해결 사유를 포함한다. Agreed Points에는 합의 내용과 근거 턴 번호를 포함한다
- Open Issues에 미해결 이슈가 없으면 정확히 `- 없음` 또는 `- None` 한 줄로만 표기한다 (후행 마침표 1개 허용). 그 외 산문 표기는 `is_review_session_resolved`가 미해결로 판정한다 (fail-closed)

## 어댑터 대기 계약 (adapter_codex.sh)

Reviewer 턴 생성 시 `adapter_codex.sh`는 다음 계약으로 대기합니다.

- Codex를 background에서 실행한 뒤 **watchdog + `wait`** 방식으로 프로세스 종료를 직접 감지합니다 (폴링 루프 없음).
- **WAIT_TIMEOUT** (기본 600초, env override 가능): watchdog이 만료 시 **타임아웃 마커 파일**(`.wait_timeout`)을 원자적으로 생성하고 Codex를 kill합니다. `wait` 복귀 후 마커 파일 존재 여부로 타임아웃/비정상 종료를 구분합니다.
- cleanup 시 watchdog reap과 마커 파일 제거를 수행합니다.

### 턴 완료 판정 계약 (SESSION 단일 권위)

완료 판정 조건은 **세 가지 모두 충족**이어야 합니다.

1. 턴 파일 존재
2. SESSION `Current Owner` ∈ `{Author, User}` (enum 긍정 조건 — 부정 조건 금지)
3. SESSION `Status` ∈ `{awaiting-author, awaiting-user}`

**CHECKPOINT.md는 리뷰어 산문 전용**입니다 — Summary / Agreed Points / Open Issues / Questions / Suggested Next Owner 섹션은 리뷰 기록과 종결성 판정(`is_review_session_resolved`의 Open Issues 확인)에 사용되며, 어댑터의 턴 완료 판정에는 소비되지 않습니다. 기계 판정 필드(Status·Current Owner·Turn Limit·Branch Context)는 SESSION.md가 유일 권위입니다.

## diff-review iteration 중 commit (review-gate-iteration-commit)

final-diff-review 진행 중 reviewer 가 코드 수정을 요청하면, author 는 fr branch 에 수정을 **그대로 commit** 한다 (iteration commit). review target 은 `git diff <기본 브랜치>...HEAD` 이므로, 수정이 HEAD 에 반영되어야 reviewer 가 다음 턴에서 확인할 수 있다.

- author: 수정 commit → 새 author 턴 파일 작성 → `SESSION.md` Status 를 `awaiting-reviewer` 로 전환.
- reviewer: `run_review_turn.sh` 로 갱신된 `<기본 브랜치>...HEAD` 를 재검토.
- `pre_commit_review_gate.sh` 는 미종결 중 **archive/완료 신호 commit**(staged `request-archive/` 파일 추가 또는 `CURRENT_TASK.md` baseline reset)만 차단하고, iteration 수정 commit 은 허용한다. 종결 여부를 파싱할 수 없는 malformed 세션도 동일하게 archive 신호일 때만 차단한다.
- 미검증 archive/merge 의 최종 차단은 `archive.sh` 의 review 종결 재검증이 담당한다(malformed 세션 포함 fail-closed). iteration commit 허용이 이 안전장치를 약화하지 않는다.
- archive.sh 의 precheck 는 merge 전에 **fr branch tip** 에 commit 된 diff-review 세션을 검증한다(main 워킹트리 비의존). 따라서 "세션을 fr branch 에 commit → main switch → archive.sh" 표준 흐름이 force-skip 없이 통과한다.

## 종료 규칙

아래 중 하나면 `awaiting-user`로 전환합니다.

1. 최신 Reviewer 턴이 `이의 없음`을 명시했다
2. 사람의 우선순위 결정이나 승인 여부가 필요하다
3. 총 턴 수가 20에 도달했다

`awaiting-user` 전환 시:

- `SESSION.md`의 `Status`를 `awaiting-user`로 바꿉니다
- `Current Owner`를 `User`로 바꿉니다
- `CHECKPOINT.md`에 현재 결론과 남은 쟁점을 적습니다
- `USER_ACTION.md`에 사용자 질문을 남깁니다

## 리뷰 요약 report

리뷰 세션이 종료(`awaiting-user` 또는 `closed`)되면, 요약 report를 작성한다.

저장 위치: `rd-workflow-workspace/reports/reviews/YYYY-MM-DD-HHMM-작업명-<review종류>.md`

review종류: `request-review`, `spec-plan-review`, `diff-review`, `project-context-review`

형식:

```markdown
# [Review 종류] 요약

- 일시: YYYY-MM-DD HH:MM
- 세션: rd-workflow-workspace/handoffs/review_pipeline/<session-id>/
- 대상: [검토 대상 파일/경로]

## 주요 쟁점
1. [쟁점] — Author: [입장] / Reviewer: [입장]

## 결론
1. [합의 내용과 근거]

## 반영 내역
- [변경한 내용]
```

## Branch Context schema (fr-branch-tag-lifecycle FR 도입)

Review pipeline session의 `SESSION.md`는 `## Branch Context` 섹션에 5필드를 보존한다:

```
## Branch Context
- fr-branch: fr/{slug} | null | main
- worktree-path: {absolute-path} | null
- short-title: {slug} | unknown
- lifecycle-stage: request-review | spec-review | plan-review | implementing | validating | archive-pending | archived
- remote-mode: remote | local-only
```

### Producer / Consumer
- **Producer**: `rd-workflow/scripts/prepare_review_pipeline.sh` — session 생성 시 자동 채움.
- **Consumer**: `rd-workflow/scripts/review_common.sh`의 `validate_branch_context()` — `run_review_turn.sh`가 adapter 호출 직전에 strict 검증.

### 검증 정책
- 5필드 모두 strict parse — 라벨/값 누락 시 hard error.
- `fr-branch` (null/main 외) → `git rev-parse --verify` 검증, 미존재 시 hard error.
- `worktree-path` (null/main 외) → 디렉토리 존재 검증, 미존재 시 hard error.
- `short-title` / `remote-mode` → 현재 상태와 비교, 불일치 시 informational warning.
- `## Branch Context` 섹션 부재 = legacy session → warning + skip (grandfathering).

## 수동 fallback

Claude가 CLI를 실행할 수 없을 때만 `rd-workflow/docs/prompts/manual/` 안의 프롬프트를 사용합니다.

- 시작: `review_pipeline_start_manual.md`
- 이어가기: `review_pipeline_continue_manual.md`

## 관련 스크립트

- `rd-workflow/scripts/prepare_review_pipeline.sh`
- `rd-workflow/scripts/init_review_pipeline.sh`
- `rd-workflow/scripts/run_review_turn.sh`
- `rd-workflow/scripts/review_common.sh`
- `rd-workflow/scripts/adapter_codex.sh`
- `rd-workflow/scripts/adapter_claude.sh`

## 리뷰 도구 설정

설정 파일: `rd-workflow/config/review-tools.json`

예제를 복사해서 시작:

```bash
cp rd-workflow/config/review-tools.json.example rd-workflow/config/review-tools.json
```

주요 설정:

| 키 | 설명 | 기본값 |
|----|------|--------|
| `default_priority` | 도구 우선순위 | `["codex", "claude"]` |
| `tools.<name>.bin` | 바이너리 경로 (`null`이면 PATH 탐색) | `null` |
| `tools.claude.self_review_warning` | 셀프 리뷰 경고 표시 | `true` |
| `tools.claude.self_review_policy` | self-review 정책 `block`(기본,차단) / `warn`(경고 후 통과) / `off`(무음 통과) | `block` |
| `overrides.<type>.priority` | 리뷰 타입별 우선순위 오버라이드 | - |

`REVIEW_TOOLS_CONFIG` 환경변수로 설정 파일 경로를 override할 수 있다.

`jq`가 설치되지 않으면 설정 파일을 무시하고 기본값(`codex → claude`)으로 동작한다.
설정 파일이 없어도 기본값으로 동작한다.

### self-review 차단 게이트 (safeguard-self-review-block)

독립 reviewer(codex 등)가 없어 reviewer가 `claude`로 fallback되면 generator와 동일 모델이 평가하는 self-review가 된다. `self_review_policy=block`(기본)이면:

- **일반 모드**: review turn을 차단한다(reviewer turn 미생성, exit 3). `USER_ACTION.md`에 재개 안내를 남기고 세션 Status는 `awaiting-reviewer`로 유지한다.
- **autopilot**(`RD_AUTOPILOT=1`): 자율성 보존을 위해 자동 진행하되 `mode=self-review`로 기록한다.
- **1회 승인**(`RD_SELF_REVIEW_APPROVE=1`): 해당 실행 1회만 통과한다.

`warn`은 기존 동작(경고 후 통과), `off`는 무음 통과다. `self_review_policy` 미설정 시 `self_review_warning=false`이면 `off`, 그 외에는 `block`으로 해석한다(하위호환). 이는 기존 `self_review_warning=true` 환경의 동작을 "경고 후 통과"에서 "차단"으로 격상한다.
