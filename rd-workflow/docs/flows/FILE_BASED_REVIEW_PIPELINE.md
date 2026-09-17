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
- `diff` — `diff [--base <ref>] [diff-target]`

`diff` 는 base 를 판정하지 못하면 **세션을 만들지 않고 exit 1** 합니다 (빈 diff 를 리뷰 대상으로 남기지 않기 위함). 판정 우선순위는 `--base <ref>` → task-state `fr-branch`(merge-base 계산의 입력) → task-state `base-commit` → 없음(중단) 이고, 계약 본문은 `rd-workflow/docs/flows/WORKFLOW.md` 의 "diff review base 판정" 절에 있습니다. `--base` 와 위치 인자 `diff-target` 은 **동시에 줄 수 없습니다.**

판정된 base 와 현재 HEAD 는 둘 다 **저장소 native full OID 로 resolve** 되어 `Review Target` 에 `git diff <base OID>..<head OID>` 로 기록됩니다. `main` 같은 이동 ref 를 문자열로 남기면 세션 생성과 실제 리뷰 사이에 기준이 바뀝니다.

또한 `diff` 세션 생성 시 그 session-id 가 task-state `review-session` 에 기록됩니다. 발행 게이트는 세션 디렉터리를 뒤지지 않고 이 포인터 하나로 종결 마커를 찾습니다 (`rd-workflow/docs/guides/task-state-guide.md`).

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

- Codex를 background에서 실행하고 **stdout·stderr를 세션 디렉토리의 로그 파일로 리다이렉트**합니다. 파이프를 쓰지 않으므로 어댑터가 reader를 갖지 않습니다.
- **로그 경로는 두 단계입니다.** 실행 중에는 `mktemp`로 만든 무작위 경로 `.codex_output.XXXXXX`이고(symlink 추종·동시 실행 충돌 방지), 종료 시 `cleanup`이 안정 경로 `.codex_output.log`로 옮깁니다. 어댑터는 생성 직후 **실제 경로를 stderr에 1회 출력**하며 heartbeat와 상태 snapshot의 `log_path`에도 담습니다 — 진행 중 `tail -f`는 그 경로로 합니다(안정 경로는 종료 후에만 생깁니다). 안정 경로는 **세션당 최신 턴 1개**만 보존합니다(이전 턴 로그를 덮어씁니다). 이전 턴의 안정 로그는 **시작 시점(codex spawn 전)에 제거**하므로, `.codex_output.log`의 존재는 `.review_wait_status`와 마찬가지로 「이번 실행이 끝났다」를 뜻합니다.
- **watchdog + `wait`** 방식으로 종료를 감지합니다 (폴링 루프 없음). watchdog은 1초 주기로 깨어나 ① 로그에서 새 바이트 관측(= codex 발 활동) ② 절대 상한 판정 ③ 유휴 판정 ④ heartbeat 표시를 수행합니다.
- **두 축으로 대기합니다.**

  | 변수 | 의미 | 기본값 |
  |---|---|---|
  | `WAIT_TIMEOUT` (legacy alias `POLL_TIMEOUT`) | 절대 상한 | `7200` |
  | `RD_REVIEW_IDLE_TIMEOUT` | 유휴 임계. `0` = 유휴 판별 비활성 | `600` |
  | `RD_REVIEW_HEARTBEAT` | 사용자 표시 주기 | `60` |
  | `RD_REVIEW_OBSERVER_FALLBACK_CAP` | 관측기 고장 시 유효 상한의 천장 | `600` |

  값은 `WAIT_TIMEOUT` → `POLL_TIMEOUT` → 기본값 순으로 **설정됐고 유효한(양의 정수) 첫 값**을 씁니다. 설정됐지만 무효한 값은 경고 후 무시하고 다음 원천으로 내려갑니다.
- 어느 축이 만료되든 **타임아웃 마커**에 사유를 쓰고 Codex process group을 종료합니다. 마커 내용은 공백으로 구분된 **세 필드** `<사유(idle|cap)> <유효상한(초)> <관측기상태(ok|failed)>`입니다 — 관측기가 고장나면 유효 상한이 절대 상한보다 조여지므로, 사유 하나만으로는 부모가 "몇 초에서, 관측기가 살아 있었는지"를 알 수 없어 나머지 두 값도 함께 싣습니다. `wait` 복귀 후 **마커 내용**으로 타임아웃/비정상 종료를 구분하며 종료 코드는 `124`입니다.
  - **마커는 안정 이름(`.wait_timeout`)을 쓰지 않습니다.** 마커는 codex 생존 중에 만들어져야 하므로 상태 파일처럼 "종료 후 1회 발행"으로 옮길 수 없습니다. 안정 이름은 예측 가능하므로 실행 중 codex가 그 자리에 세션 밖 디렉터리 symlink를 심을 수 있고, 그러면 마커가 sandbox 밖으로 나가 부모의 검사가 실패해 **실제 타임아웃을 일반 조기 종료로 오분류**합니다. 그래서 codex spawn **전에** 배타 `mktemp`로 `.wait_timeout.XXXXXX`를 만들고(그 시점엔 사전 심기가 불가능) 쓰기·읽기 fd를 그 자리에서 열어 둡니다. watchdog은 그 fd로 쓰고 부모는 그 fd로 읽으므로, codex가 세션을 열거해 경로를 unlink·symlink로 바꿔도 두 쪽 모두 원래 inode를 봅니다. 파일은 시작부터 존재하고 비어 있으므로 **판정 기준은 존재가 아니라 내용**이며, 쓰기가 실패해 내용이 비면 부모는 타임아웃이 아닌 조기 종료(`exit 1`)로 끝냅니다(무한 대기보다 낫습니다).
- **활동 신호와 heartbeat는 다릅니다.** 유휴 타이머를 갱신할 자격은 codex 프로세스에서 비롯된 로그 증가에만 있습니다. heartbeat는 표시 전용이며 타이머를 갱신하지 않습니다 (어댑터가 자기 신호로 자기 타이머를 갱신하면 유휴 판별이 무력해집니다).
- **읽기도 경로가 아니라 fd로 합니다(쓰기와 같은 계약).** 어댑터는 실행 중 codex가 쓸 수 있는 세션 디렉터리를 그 sandbox **밖에서 호출자 권한으로** 다룹니다. 가변 경로를 다시 열어 읽으면 codex가 그 이름을 세션 밖의 읽기 가능한 파일 symlink로 바꿔 그 내용을 stderr·상태 파일로 끌어낼 수 있습니다(cleanup의 `log-source-replaced` 판정은 내용이 이미 노출된 뒤라 너무 늦습니다). 그래서 로그와 last-message의 **모든 내용 읽기**를 codex spawn 전에 열어 둔 fd로만 합니다:
  - 로그 읽기 fd는 **부모용과 watchdog용을 각각 따로** 엽니다. 서브셸이 상속한 fd는 부모와 **파일 오프셋을 공유**하므로 하나만 열면 양쪽이 서로 줄을 놓칩니다(`exec`를 두 번 하면 open file description이 둘이 되어 오프셋이 독립합니다).
  - watchdog은 매 tick 자기 fd에서 **가용한 줄을 bounded 루프로 드레인**합니다(상한 500줄 — 실측 근거는 어댑터 주석). 한 줄이라도 읽혔으면 활동이고, 마지막으로 읽은 완성된 줄이 heartbeat가 보여줄 줄입니다. `wc`·`tr` fork가 사라집니다. 상한·유휴 판정은 tick 수가 아니라 `date` 벽시계로 하므로 드레인이 밀려도 판정은 왜곡되지 않습니다.
  - 부모는 `wait` 복귀 **후** 자기 fd에서 tail(20줄)과 last-message를 한 번 읽어 변수에 담고, 타임아웃·조기 종료 보고는 그 변수만 씁니다. `[ -s <경로> ]` 같은 존재·크기 검사도 쓰지 않고 **읽어 온 값이 비었는지**로만 판단합니다.
  - **읽기 채널 open 실패는 시작 실패가 아닙니다.** 쓰기 채널(로그 생성·상태 스트림·마커)이 없으면 이번 실행을 정직하게 수행할 수 없어 조기 실패가 맞지만, 읽기 채널이 없으면 잃는 것은 관측·진단뿐이므로 기능 저하로 합류시킵니다 — 관측 fd 부재는 관측기 고장, 부모 쪽 fd 부재는 해당 진단 출력의 생략입니다.
- **활동 관측기 고장의 조건**: **로그 관측 fd를 확보하지 못한 경우** 하나입니다(codex spawn 전 open 실패). 그때 유휴 판별을 끄고 유효 상한을 `min(해석된 절대 상한, RD_REVIEW_OBSERVER_FALLBACK_CAP)`으로 조입니다. 기준은 어댑터 시작 시점부터의 **총 경과**이며, 고장 시점부터 새로 재지 않습니다. 사용자가 지정한 더 짧은 상한은 절대 늘어나지 않습니다.
  - **크기 감소(truncation)·경로 소실은 더 이상 관측기 고장이 아닙니다.** 관측 기준이 「경로의 절대 크기」에서 「내 fd에서 새 바이트가 보이는가」로 바뀌었기 때문입니다. 외부의 truncate·unlink·경로 교체는 fd가 가리키는 inode를 바꾸지 못하므로 관측을 **훼손하지 못하고**(codex도 spawn 시 열린 자기 fd로 같은 inode에 계속 씁니다), 훼손이 가능한 유일한 방향인 「새 바이트가 보이지 않는」 쪽은 활동 없음과 구별할 필요가 없어 유휴 판정·절대 상한이 그대로 받습니다. 경로 사보타주는 이제 관측 문제가 아니라 **사후 로그 보존 실패**로만 나타납니다(`log-vanished-during-run` / `log-source-replaced`).
- **시계 점프를 보정합니다.** tick 간격이 `max(30초, TICK×5)`를 넘으면(시스템 절전·NTP 스텝 등으로 프로세스 자체가 멈춰 있었다는 뜻) 그 초과분을 총 경과·유휴 경과 양쪽 계산에서 제외합니다. 정지 구간 동안 codex도 함께 멈춰 있었으므로 그 구간을 유휴로 오판하지 않기 위함이며, 임계를 고정 5초가 아니라 30초 이상으로 둔 것은 부하로 인한 통상적인 tick 지연(수 초)까지 정지로 오판하지 않기 위함입니다.
- **로그 파일을 처음부터 만들지 못하면** 관측기 고장이 아니라 **시작 실패**입니다(`exit 1`). codex를 시작할 출력 대상 자체가 없으므로 fallback하지 않습니다.
- **보존 산출물**: `.codex_output.log`(codex 전체 출력)와 `.review_wait_status`(대기 상태 snapshot)는 정상·타임아웃·신호 종료 모든 경로에서 **삭제하지 않습니다.** 사후 관찰이 목적이며 `turn_metrics.tsv`와 같은 세션 아티팩트로 취급합니다. 다만 **소스 관리 대상은 아닙니다** — 리뷰어 입력 전문·CLI 세션 ID·홈 절대 경로·명령 출력이 담기므로 `.gitignore`로 추적에서 제외하고 로컬에만 남깁니다.
  - **산출물 수명 계약: 안정 이름은 실행 중에 존재하지 않습니다.** `.review_wait_status`는 진행 중에는 만들지 않고, codex process group 종료를 확인한 뒤 cleanup이 **1회 발행**합니다. 이 계약을 실제로 지키려면 발행만으로는 부족합니다 — 이전 턴이 발행한 안정 파일이 남아 있으면 이번 실행 중에도 그것이 현재 상태처럼 보이므로(안정 경로만 보는 headless 소비자는 이전 턴의 `log_path`·observer·보존 결과를 현재 실행 상태로 오인합니다), **codex spawn 전 안전한 시점에 이전 안정 파일(`.review_wait_status`·`.codex_output.log`)을 제거**합니다. 잃는 것은 「이번 실행 동안의 이전 산출물 열람」뿐이고(둘 다 이번 실행 종료 시 어차피 덮어쓰입니다), 얻는 것은 두 안정 이름의 존재가 곧 「이번 실행이 끝났다」를 뜻하는 단일 계약입니다. 진행 중 갱신은 `mktemp` 스트림 `.review_wait_status.XXXXXX`에만 하며, 각 갱신은 구분선으로 시작하는 **완전한 snapshot 블록**을 append합니다(발행 시 마지막 블록만 씁니다). 진행 가시성은 stderr heartbeat가 담당하고, heartbeat는 codex 로그 경로와 **상태 스트림의 실제 경로**를 함께 냅니다.
  - **진행 중 쓰기는 경로가 아니라 fd로 합니다.** 세션 디렉토리는 실행 중인 codex가 쓸 수 있습니다. 예측 가능한 규칙(`.review_wait_status.tmp.$$` — background codex에서 `$PPID`가 곧 어댑터 PID)은 codex가 계산할 수 있고, `mktemp`로 무작위화해도 codex는 세션 디렉터리를 **열거**해 이름을 찾을 수 있습니다. 그 자리에 세션 밖 파일 symlink를 심으면 `>` 리다이렉션이 링크를 따라가 **sandbox 밖에서 호출자 권한으로** 그 파일을 truncate하는 confused-deputy 경로가 됩니다. 그래서 스트림은 codex spawn **전에** 배타 `mktemp`(권한 `600`)로 만들고 그 시점에 append fd를 열어, 이후 모든 갱신을 그 fd로만 씁니다 — 경로를 다시 해석하지 않으므로 심어 둔 symlink가 무해해집니다(codex 자식에게는 이 fd들을 닫아 전달합니다).
  - **안정 이름 rename은 경쟁자가 없을 때만 합니다.** 검사(`-L`/`-d`)·삭제·`mv`는 셸에서 하나의 원자 연산이 될 수 없습니다. 진행 중에 매 갱신마다 rename하면 codex가 그 이름을 외부 디렉터리 symlink로 **타이트한 루프로 계속 재생성**해 창을 반복 공략할 수 있고, 한 번만 이겨도 그 교체분이 세션 밖으로 나갑니다("한 번 미리 배치"가 아니라 반복 공략입니다). codex process group 종료를 확인한 뒤 발행하면 그 창을 공략할 주체가 없어 경쟁이 **구조적으로 사라집니다.** 발행 시에도 목적지가 symlink면 링크째 제거한 뒤 교체하고 실제 디렉터리면 교체를 포기하며(`mv`는 목적지가 디렉터리면 그 **안으로** 옮깁니다), 발행 실패는 삼키지 않고 스트림 경로와 함께 stderr로 알립니다. 그룹이 아직 살아 있으면 발행하지 않고 그 사실을 알립니다(`log_preserved_reason: codex-group-alive`).
  - **로그 최종 이동도 process group 정리 후에, 결과를 확인한 뒤에만 성공으로 기록합니다.** `mv ... || true` 뒤에 무조건 `log_preserved: yes`를 적으면 I/O·권한 오류로 안정 경로에 로그가 없어도 보존 성공으로 보고합니다. 기대 형태(안정 경로가 symlink가 아닌 정규 파일이고 원본이 사라짐)를 확인한 경우에만 `yes`입니다. 실패하면 **원본이 실제로 남아 있는 경우에만** `log_preserved_reason: log-move-failed` / `log_path_recovery: <임시 경로>`로 회수 경로를 남기고, 남아 있지 않으면 `log-move-failed-source-lost`로 회수 불가를 밝힙니다(존재하지 않는 경로를 "회수 가능"으로 보고하지 않습니다).
  - **소스 변조 예외**: codex는 무작위 `.codex_output.*` 이름을 열거로 찾아 그 경로를 세션 밖 **정규 파일** symlink로 바꿀 수 있습니다. 그러면 `[ -f ]`가 링크를 따라 참이 되고 `mv`는 symlink 자체를 안정 경로로 옮겨 **남의 파일을 codex 출력이라고 보고**하게 됩니다. 그래서 이동 전에 소스가 symlink가 아닌 정규 파일인지 확인하고, symlink면 옮기지 않고 링크만 제거한 뒤 `log_preserved_reason: log-source-replaced`로 보존 실패를 알립니다(회수 경로는 적지 않습니다). 안정 경로에 symlink가 들어앉은 경우에도 남기지 않습니다.
  - **소실 예외**: 실행 중 로그 경로가 사라진 경우(관측 자체는 fd로 계속되므로 훼손되는 것은 보존뿐입니다)에는 옮길 원본이 없어 보존할 수 없습니다. 이때는 `log_preserved: no` / `log_preserved_reason: log-vanished-during-run` / `log_path_final: (없음)` 세 필드와 stderr 알림으로 보존 실패를 명시적으로 보고하며, 복구 설계는 두지 않습니다.
- 타임아웃(124)뿐 아니라 **턴 완료 전 조기 종료(exit 1)에서도** codex 로그의 최근 tail(20줄)을 stderr로 출력합니다 — codex가 시작 직후 설정 오류 등으로 죽으면 그 사유가 last-message 파일이 아니라 로그에만 남기 때문입니다. 그 tail은 **spawn 전에 열어 둔 fd에서 읽은 값**이며 경로를 다시 열지 않습니다(타임아웃 보고의 5줄도 같은 값에서 잘라 냅니다).
- cleanup 시 watchdog reap, 열어 둔 fd 전부 닫기, 마커 파일 제거를 수행합니다.

### 턴 완료 판정 계약 (SESSION 단일 권위)

완료 판정 조건은 **세 가지 모두 충족**이어야 합니다.

1. 턴 파일 존재
2. SESSION `Current Owner` ∈ `{Author, User}` (enum 긍정 조건 — 부정 조건 금지)
3. SESSION `Status` ∈ `{awaiting-author, awaiting-user}`

**CHECKPOINT.md는 리뷰어 산문 전용**입니다 — Summary / Agreed Points / Open Issues / Questions / Suggested Next Owner 섹션은 리뷰 기록과 종결성 판정(`is_review_session_resolved`의 Open Issues 확인)에 사용되며, 어댑터의 턴 완료 판정에는 소비되지 않습니다. 기계 판정 필드(Status·Current Owner·Turn Limit·Branch Context)는 SESSION.md가 유일 권위입니다.

## diff-review iteration 중 commit (review-gate-iteration-commit)

final-diff-review 진행 중 reviewer 가 코드 수정을 요청하면, author 는 작업 브랜치(fr 브랜치, fr 브랜치를 쓰지 않으면 기본 브랜치) 에 수정을 **그대로 commit** 합니다 (iteration commit). 수정이 HEAD 에 반영되어야 reviewer 가 다음 턴에서 확인할 수 있습니다.

- author: 수정 commit → 새 author 턴 파일 작성 → `SESSION.md` Status 를 `awaiting-reviewer` 로 전환.
- reviewer: `run_review_turn.sh` 가 갱신된 target 을 재검토합니다 (아래 재snapshot 계약).
- 미검증 archive/merge 의 최종 차단은 `archive.sh` 의 종결 마커 재검증이 담당합니다(마커 부재·malformed 포함 fail-closed). iteration commit 허용이 이 안전장치를 약화하지 않습니다.

### reviewer 턴마다의 `review-head-oid` 재snapshot (계약)

다회차 리뷰가 정상 경로이므로, **head 는 reviewer 턴마다 다시 snapshot 되고 base 는 불변**입니다. 단, 사용자가 검토 대상 head 를 명시한 세션(`review-head-policy: pinned`)은 예외입니다 — 아래 정책 절을 보십시오.

| 값 | 생성 | 갱신 |
|---|---|---|
| `review-base-oid` | 세션 생성 시 base 판정 우선순위로 1회 | **하지 않습니다 (불변)** |
| `review-head-oid` | 세션 생성 시 `HEAD^{commit}` | **reviewer 턴 dispatch 직전마다** 현재 `HEAD^{commit}` 으로 다시 snapshot |

- base 를 함께 갱신하지 않는 이유: 리뷰 도중 기본 브랜치가 전진할 때 base 가 따라 움직이면 **이미 리뷰된 변경분이 조용히 diff 에서 빠집니다.** 리뷰 대상은 작업 전체이지 마지막 턴의 증분이 아닙니다.
- 갱신 주체는 `run_review_turn.sh` 이고, author 턴은 갱신하지 않습니다. `review-base-oid`·`review-head-oid` 가 **둘 다 있는 diff-review 세션에서만** 갱신합니다 — 두 OID 가 없는 세션(위치 인자를 OID 로 해석할 수 없었던 세션, 이 계약 이전의 legacy 세션) 은 건드리지 않습니다.
- 새 head 가 base 의 후손이 아니면(`amend`·`reset` 등으로 계보가 끊긴 경우) 판정 불가이므로 갱신하지 않고 실패합니다.
- **base 와 새 head 사이에 실제 변경이 없으면 갱신하지 않고 실패합니다.** 조상 관계와 OID 상이만으로는 부족합니다 — iteration 중 변경이 완전히 revert 되면 OID 는 달라도 트리가 같아 diff 가 비어 있습니다. 판정은 `git diff --quiet <base>..<head>` 의 **세 값**(0=차이 없음 → 차단, 1=차이 있음 → 진행, 그 밖=git 오류 → 판정 불가로 차단)으로 합니다.
- **원자성**: `review-head-oid` 와 `Review Target` 은 한 번에 교체됩니다. ① OID resolve·계보 검증을 먼저 전부 끝내고 ② SESSION 전체를 같은 디렉터리의 임시 파일에 렌더링한 뒤 ③ `mv` 로 교체하고 그 종료 상태를 확인하며 ④ 교체가 성공한 뒤에야 어댑터 호출·턴 파일 생성으로 넘어갑니다. 1~3 중 어디서 실패해도 기존 SESSION 을 그대로 두고 턴을 시작하지 않습니다. 한쪽만 바뀐 SESSION 으로 reviewer 가 dispatch 되면 "기록된 OID 와 reviewer 가 읽은 diff 가 다름" 이라는, 이 계약이 막으려는 상태가 그대로 생깁니다.
- 기계 판독 권위는 `SESSION.md` 의 `## Branch Context` 에 있는 `- review-base-oid:` / `- review-head-oid:` 두 줄입니다. **`Review Target` 문자열을 파싱하지 않습니다** — 파싱 계약을 두면 표현이 바뀔 때마다 깨집니다.
- **종결 마커(`rd review seal`) 의 권위는 마지막 reviewer 턴의 snapshot 입니다.** 「이의 없음」을 낸 그 턴이 실제로 본 head 가 `review-head-oid` 이므로, 그 뒤에 보호 경로를 고치면 seal 이 거부합니다 — 재리뷰 없이 봉인할 방법이 없습니다.

### head 갱신 정책 (`review-head-policy`)

`## Branch Context` 의 `- review-head-policy: auto|pinned` 가 위 재snapshot 을 할지 정합니다.

| 값 | 언제 붙는가 | 동작 |
|---|---|---|
| `auto` | 기본. `--base <ref>` 세션, 그리고 위치 인자의 **오른쪽이 문자 그대로 `HEAD`** 인 세션(예: `git diff main...HEAD`) | 위 재snapshot 계약대로 reviewer 턴마다 갱신 |
| `pinned` | 위치 인자의 오른쪽이 `HEAD` 가 **아닌** ref·OID 인 세션(예: `git diff main..branch-B`) | 갱신하지 않습니다. 지정된 head 를 그대로 유지합니다 |

- **검증 단위는 「snapshot 묶음」입니다** — `review-base-oid`·`review-head-oid`·`review-head-policy`·`Review Target` 네 값을 한 묶음으로 봅니다. 아래 세 상태는 SESSION 을 바꾸지 않고 어댑터를 부르지 않은 채 중단합니다: ① 두 OID 중 한쪽만 있음(legacy 가 아니라 손상 — seal 도 같이 막습니다) ② raw 필드가 저장소 native full OID 가 아님(이동 ref·축약 OID 는 reviewer 시점과 seal 시점 사이에 대상이 다시 움직입니다 — seal 도 같이 막습니다) ③ `pinned` 세션의 `Review Target` 이 `git diff <resolved-base>..<resolved-head>` 와 다름. `auto` 는 target 을 원자적으로 재렌더링하므로 ③ 이 필요 없습니다 — 갱신 자체가 결속입니다.
- **정책은 갱신 여부만 가릅니다.** 기록된 base/head 의 resolve·조상 관계·비어 있지 않은 diff 검증은 `auto`·`pinned` 양쪽 모두 받으며, 검증 대상 head 만 다릅니다(`auto` 는 현재 `HEAD`, `pinned` 은 세션에 기록된 head). 검증에 실패하면 SESSION 을 바꾸지 않고 어댑터를 부르지 않은 채 중단합니다 — 그러지 않으면 기록 OID 가 더 이상 resolve 되지 않는 세션이 reviewer dispatch 까지 가서, 성공한 리뷰 턴처럼 보이는 결과가 나옵니다.
- 판정 기준은 OID 비교가 아니라 **ref 문자열**입니다. 생성 시점에 두 OID 가 우연히 같더라도 그 뒤 HEAD 가 전진하면 사용자가 지정한 대상이 조용히 바뀌므로, 적힌 표현의 의미를 보존합니다.
- `pinned` 세션에는 **리뷰 도중의 iteration commit 이 반영되지 않습니다.** 세션 생성 시와 reviewer 턴마다 그 사실과 대안(`diff --base <ref>` 또는 `diff "git diff <base>..HEAD"`)을 알립니다.
- 필드가 없는 기존 세션은 `auto` 로 봅니다(하위호환). `auto`·`pinned` 가 아닌 값은 판정 불가이므로 턴을 시작하지 않습니다.

### archive precheck 의 판정 대상 commit

`archive.sh` 의 `archive_review_precheck` 는 **세션 디렉터리(`handoffs/`) 를 더 이상 읽지 않습니다.** 검증 입력은 세 가지이고, 셋 다 **하나의 판정 대상 commit** 에서 읽습니다.

| 검증 입력 | 읽는 곳 |
|---|---|
| task-state 의 `review-session` 포인터 | `git show <판정 대상>:rd-workflow-workspace/.lifecycle/task-state` |
| 포인터가 가리키는 `<session-id>.seal` 마커 | `git show <판정 대상>:rd-workflow-workspace/.lifecycle/review-seals/<session-id>.seal` |
| 현재 보호 트리 해시 (마커의 `tree-hash` 와 비교) | `git ls-tree` 로 계산 (워크플로 기록 경로 제외) |

판정 대상 commit 은 모드에 따라 정해집니다.

| 모드 | 판정 대상 commit | 근거 |
|---|---|---|
| fr | `<fr-branch>^{commit}` (fr branch tip) | 기존 main 워킹트리 비의존 계약을 그대로 보존합니다 |
| no-fr | 현재 `HEAD^{commit}` (clean 검사 통과 후) | 병합할 다른 브랜치가 없습니다 |

- 따라서 "마커와 task-state 를 fr branch 에 commit → 기본 브랜치로 switch → `archive.sh`" 표준 흐름이 force-skip 없이 통과합니다. 세션 본문을 커밋하지 않는 프로젝트도 **마커만 커밋하면** 통과합니다.
- **마커는 커밋되어야 효력이 생깁니다.** 워킹트리에만 있는 seal 로는 발행하지 못합니다.
- fr 브랜치 **이름만** 예외입니다. 그것은 판정 입력이 아니라 판정 대상을 **찾는** 값이므로 워킹트리 task-state 또는 `archive.sh --fr-branch` 에서 옵니다. 그 이름이 가리키는 ref 가 없으면 차단합니다.
- 마커 검증은 strict 입니다 — 파일 존재 / `schema` 지원 / 필수 필드 / 파일명과 내부 `session-id` 일치 / 포인터와 일치 / `review-type=diff-review` / `branch-mode`·`fr-branch` 일치 / `verified` 값 / `tree-hash` 일치 / 해시 계산 성공. 부재·문법 오류·의미 불일치·해시 불일치가 각각 다른 메시지로 나옵니다.
- `verified=legacy-unverified` 마커로 통과할 때는 `archive.sh` 와 `rd task status` **양쪽**이 매번 경고를 냅니다 (리뷰 당시 트리를 증명하지 않는 마커이므로).
- 발행 순서는 `WORKFLOW.md` 의 "아카이브 보류" 절에 있습니다: **리뷰 종결 → seal → 상태 전이 → 기록 커밋 → 발행.**

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

diff-review 세션은 여기에 **reviewed OID 두 줄**을 덧붙입니다. 두 값을 다 resolve 한 세션에만 붙으므로, 없는 세션은 일반 `rd review seal` 로 봉인할 수 없고 `--legacy-unverified` 경로로만 갑니다.

```
- review-base-oid: {full OID}
- review-head-oid: {full OID}
- review-head-policy: auto|pinned
```

- 이 두 줄이 리뷰 대상의 **기계 판독 권위**입니다. `Review Target` 문자열은 사람이 읽는 표현이며 파싱 대상이 아닙니다.
- OID 길이를 하드코딩하지 않습니다. 값은 언제나 `git rev-parse --verify <입력>^{commit}` 이 돌려준 **저장소 native full OID** 이며(SHA-256 object-format 저장소를 배제하지 않기 위함), 형식 검증도 같은 명령의 성공 여부로 합니다.
- `review-head-oid` 는 reviewer 턴마다 갱신됩니다 (위 재snapshot 계약). 단 `review-head-policy: pinned` 세션은 갱신하지 않습니다 (위 정책 절).
- 5필드 strict 검증(`validate_branch_context`) 의 대상은 그대로 위 5필드이며, 이 두 줄은 추가 정보입니다.

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
- `rd-workflow/scripts/rd` — `review seal` (종결 마커 생성), `task set-base` (base-commit 설정)

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
| `overrides.<type>.tools.codex.reasoning_effort` | 리뷰 타입별 codex reasoning effort | - |

`REVIEW_TOOLS_CONFIG` 환경변수로 설정 파일 경로를 override할 수 있다.

### 턴 계측 (turn_metrics.tsv)

`run_review_turn.sh` 는 리뷰어 턴마다 세션 디렉토리의 `turn_metrics.tsv` 에
`turn / review_type / tool / effort / prompt_bytes / target_bytes / start_epoch / end_epoch / wall_seconds / status(ok|timeout|fail)` 를 append 한다.
`status` 는 어댑터 프로세스 종료 상태(0→ok, 124→timeout, 그 외→fail)이며 턴 최종 유효성과는 별개다.
기록 실패는 턴 실행을 막지 않는다(fail-open — 시간 원천 실패 포함). 단, 기록 실패는 stderr 에 `⚠️ turn metric ...` 경고로 표시되므로, 파일 부재는 계측 도입 이전 세션이거나 **기록 실패**(실행 stderr 의 경고로 구분)일 수 있다.
턴 완료 시 stdout `turn time: <N>s` 와 stderr `turn time: <N>s (status: <s>)` 로도 표시된다.

`jq`가 설치되지 않으면 설정 파일을 무시하고 기본값(`codex → claude`)으로 동작한다.
설정 파일이 없어도 기본값으로 동작한다.

### self-review 차단 게이트 (safeguard-self-review-block)

독립 reviewer(codex 등)가 없어 reviewer가 `claude`로 fallback되면 generator와 동일 모델이 평가하는 self-review가 된다. `self_review_policy=block`(기본)이면:

- **일반 모드**: review turn을 차단한다(reviewer turn 미생성, exit 3). `USER_ACTION.md`에 재개 안내를 남기고 세션 Status는 `awaiting-reviewer`로 유지한다.
- **autopilot**(`RD_AUTOPILOT=1`): 자율성 보존을 위해 자동 진행하되 `mode=self-review`로 기록한다.
- **1회 승인**(`RD_SELF_REVIEW_APPROVE=1`): 해당 실행 1회만 통과한다.

`warn`은 기존 동작(경고 후 통과), `off`는 무음 통과다. `self_review_policy` 미설정 시 `self_review_warning=false`이면 `off`, 그 외에는 `block`으로 해석한다(하위호환). 이는 기존 `self_review_warning=true` 환경의 동작을 "경고 후 통과"에서 "차단"으로 격상한다.
