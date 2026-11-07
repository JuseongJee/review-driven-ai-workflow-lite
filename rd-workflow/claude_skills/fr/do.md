## /fr do

여러 FR 을 한 번에 처리합니다. 대화형은 FR 을 줄기(promote 한 worktree + herdr 작업 세션)로 나눠 병렬로 띄우고, 호출 세션이 감시·발행 허가·마감을 맡습니다. 무인(`--headless`)은 고른 FR 을 `ralph_drain.sh` 엔진으로 순차 완주합니다.

호출 세션은 사람과 대화하는 이 세션입니다. 호출 세션은 기본 체크아웃(`git worktree list --porcelain` 의 첫 항목) 루트에서 이 절차를 따릅니다. 아래 명령은 모두 그 루트에서 실행합니다.

### 호출 형식

```
/fr do [<slug들>]                                              대화형 병렬 (터미널 herdr 전용)
/fr do --headless [--finish push|merge|none] [<slug들>]        무인 순차
/fr batch [<인자>]                                             별칭 — 「/fr batch 별칭」 절
```

- `<slug들>` 은 공백으로 구분한 FR short-title 입니다. 없으면 활성 FR 전체가 후보입니다. 같은 short-title 의 상세가 여러 날짜에 있으면 인덱스에 행이 있는 것(없으면 가장 늦은 날짜) 하나만 고릅니다.
- 「착수 가능한 것들 띄워」·「더 띄울 FR 없나」 처럼 대상을 지정하지 않은 요청은 `/fr do` 로 받습니다. 고르는 일까지 위임한 것으로 보고 묻지 않고 고릅니다. 고른 결과는 착수 보고 표로 보입니다.
- `--finish` 는 `--headless` 에서만 씁니다. 대화형에 `--finish` 가 오면 「`--finish` 는 `--headless` 와 함께만 씁니다」 와 사용법을 보이고 멈춥니다. 파일을 고치지 않습니다.
- 대화형은 터미널 herdr 에서만 돕니다. 판정 기준은 `HERDR_ENV` 가 설정되어 있고 `herdr` 명령이 있는 것입니다. 아니면 무인 순차로 갑니다. 이때 착수 보고 첫 줄 위에 「병렬 대화형은 터미널 herdr 에서만 지원 — 무인 순차로 진행」 을 적습니다.

스크립트는 모두 `rd-workflow/scripts/fr_do/` 에 있습니다.

| 스크립트 | 하는 일 |
| --- | --- |
| `pick.py` | 후보를 고르고 줄기로 묶음. `stream`·`order`·`hold`·`skip` 줄 출력 |
| `handoff.py <spec.json> [--launch]` | 줄기 인계 파일 작성. `--launch` 면 promote 로 줄기를 띄우고 `active.tsv` 에 등록 |
| `watch.sh` | 상태가 바뀔 때만 한 줄씩 내는 감시 루프(Monitor 용) |
| `grant_check.sh <slug>` | 발행 허가 전 점검. `GRANT-OK` 또는 `HOLD` |
| `close.sh <slug>` | 기본 체크아웃 갱신, 작업 탭 닫기, `rd task list`, 감시 목록 정리. `CLOSED` 또는 `NOT-CLOSED` |
| `self_compact.sh [기준%] [대기초]` | 호출 세션 자기 압축 |
| `batch_legacy.sh` | `/fr batch` 별칭 안내와 남은 batch manifest 요약 |

상태 폴더는 `<기본 체크아웃>/rd-workflow-workspace/.lifecycle/fr-do/` 입니다. 어느 worktree 에서 스크립트를 불러도 같은 폴더를 씁니다.

| 경로 | 내용 |
| --- | --- |
| `active.tsv` | 실행 중 줄기. 한 줄 `<slug><TAB><소유 경로;…><TAB><FR stem;…>`. 3번째 칸이 없는 옛 줄은 소유 경로만 봅니다 |
| `reports/` | 줄기가 쓰는 `<slug>-question.md`(질문)·`<slug>-closing.md`(마감 보고) |
| `waves/<wave>/` | 인계 파일 `handoff-<slug>.md` 와 `promote.log` |
| `waves/closed/` | `close.sh` 가 `CLOSED` 로 끝낸 줄기의 보고 파일. 이름은 `<slug>-<YYYYMMDD-HHMM>-question.md`·`<slug>-<YYYYMMDD-HHMM>-closing.md` 입니다. 같은 slug 를 다시 써도 옛 보고를 새 보고로 알리지 않습니다 |
| `log.md` | 호출 세션의 진행 기록 |
| `watch-seen.tsv` | `watch.sh` 가 알린 보고 파일과 그 수정 시각. 감시를 다시 걸 때 이 기록과 비교합니다 |
| `headless-<YYYYMMDD-HHMM>.log` | 무인 실행(「4. 무인」 절)의 엔진 로그 |

이 폴더는 `.gitignore` 에 `rd-workflow-workspace/.lifecycle/fr-do/` 로 들어 있어야 합니다. 없으면 발행 허가 점검이 「미커밋 변경」 HOLD 를 냅니다.

#### 줄기의 에이전트 이름

줄기에 `herdr agent read`·`herdr agent prompt` 를 쓸 때는 slug 가 아니라 에이전트 이름을 씁니다. 이 문서의 `<에이전트 이름>` 은 모두 이 이름입니다.

- promote 는 에이전트 이름을 slug 에서 계산합니다. slug 가 32자 이하면 slug 그대로입니다. 32자를 넘으면 앞 32자이고, 끝이 `-` 면 그 `-` 를 뗍니다. 예: `promote-handoff-loses-caller-decisions` → `promote-handoff-loses-caller-dec`.
- 이름이 slug 와 다르면 promote 출력에 `promote: herdr 에이전트 이름 — <이름>` 줄이 나옵니다(`waves/<wave>/promote.log`).
- 직접 계산하려면 `bash -c '. rd-workflow/scripts/fr_do/_state.sh; fr_do_agent_name <slug>'` 를 실행합니다.
- 감시 이벤트 줄, `active.tsv`, 보고 파일 이름은 slug 를 씁니다. `watch.sh`·`close.sh` 는 이름을 스스로 계산합니다.

---

### 1. 고르기와 착수 보고 표

1. 후보를 고릅니다.

   ```bash
   python3 -I rd-workflow/scripts/fr_do/pick.py --mode interactive [--slugs "<s> <s>"]
   ```

   - 무인이면 `--mode headless` 입니다. 무인의 다음 단계는 「4. 무인」 절입니다.
   - 동시 줄기 상한은 `workflow.json` 의 `fr_do_max_streams`(없으면 4)입니다. `--max-streams N` 으로 이번 호출만 바꿀 수 있습니다.
   - rc 2 면 실행 불가입니다. stderr 전문을 사용자에게 보이고 멈춥니다. 흔한 원인은 `--slugs 에 없는 FR: <s>`(slug 오타), 관계 판정 불가, 상태 폴더를 찾지 못함입니다.
2. 출력 줄을 읽습니다. 순서는 `stream` → `hold` → `skip` 입니다(무인은 `order` → `skip`).

   | 줄 | 뜻 |
   | --- | --- |
   | `stream<TAB><번호><TAB><stem,stem><TAB><소유 경로;…>` | 함께 띄울 줄기. 같은 파일을 고치는 FR 을 최대 3건 묶음 |
   | `hold<TAB><stem><TAB><사유>` | 이번에는 띄우지 않음. 사유는 `실행 중 줄기 <slug> 의 FR`·`겹침 보류 — <FR> 와 같은 파일, 줄기당 3건 상한`·`실행 중 줄기 <slug> 와 겹침`·`동시 줄기 상한 <N>` |
   | `skip<TAB><stem><TAB><사유>` | 대상이 아님. 사유는 `상태 <status>` 또는 readiness 판정(선행 FR 미완 등). `--slugs` 로 지정한 FR 이 이미 `done` 이면 `상태 done` 으로 나옵니다 |
   | `order<TAB><stem><TAB><readiness>` | 무인 전용. 우선순위 순 실행 후보 |

3. 기계가 판정하지 않는 것을 호출 세션이 봅니다. `stream`·`order` 의 FR 마다 상세 파일을 읽고 아래를 확인합니다.
   - `revisit when` 이 아직 오지 않았으면 뺍니다.
   - 해결 흔적: `bash rd-workflow/scripts/fr_related_history.sh <상세 파일>` 과 `bash rd-workflow/scripts/check_fr_related_files_existence.sh <상세 파일>` 을 봅니다. 신호는 참고입니다. 이미 해결된 것으로 보이면 코드를 열어 확인한 뒤 뺍니다. 확인 없이 신호만으로 빼지 않습니다.
   - 뺀 FR 이 줄기의 유일한 FR 이면 그 줄기를 띄우지 않습니다. 줄기 안 한 건만 빼면 소유 경로에서 그 FR 만의 경로를 뺍니다.
4. 착수 보고 표를 사용자에게 보입니다. 질문하지 않고 바로 다음 단계로 갑니다.

   | 줄기 | FR | 소유 파일 |
   | --- | --- | --- |
   | `<slug>` | `<short-title>`, … | `<경로>`, … |

   그 아래 「뺀 FR」 표에 `hold`·`skip` 줄과 호출 세션이 뺀 FR 을 모두 적습니다.

   | 뺀 FR | 이유 |
   | --- | --- |
   | `<short-title>` | `pick.py` 사유 그대로, 또는 호출 세션이 뺀 근거(revisit when 미도래, 해결 흔적과 확인한 파일) |

5. 띄울 줄기가 0개면 「띄울 줄기 없음」 과 뺀 FR 표만 보이고 끝냅니다.

### 2. 대화형: 띄우기와 감시

#### 띄우기

1. 줄기 slug 를 정합니다. FR 1건이면 그 short-title 을 씁니다. 여러 건이면 공통 주제를 담은 짧은 이름을 씁니다. slug 는 `^[A-Za-z0-9._-]+$` 이고 `.`·`..` 가 아니어야 합니다. 이미 있는 브랜치 `fr/<slug>` 와 겹치지 않게 합니다.
2. spec JSON 을 scratchpad 에 씁니다. 형식은 `handoff.py` 머리 주석이 정본입니다.
   - `wave` 는 `YYYY-MM-DD-<차수>` 처럼 이번 착수를 가리키는 이름입니다.
   - `why` 에 사용자 지시를 따옴표로 옮깁니다.
   - `owns` 는 사람이 읽는 소유 파일 문자열이고, `owns_paths` 는 `stream` 줄의 소유 경로를 배열로 옮긴 것입니다.
   - `notes` 에는 FR 상세를 사실로 받지 말고 재현부터 할 지점, 실제 배포·원격 조작 금지 같은 줄기별 주의, 「검증은 프로젝트 규칙의 검증 절차를 따름」 을 적습니다.
3. 띄웁니다.

   ```bash
   python3 -I rd-workflow/scripts/fr_do/handoff.py <spec.json> --launch
   ```

   - 줄마다 `<slug>: promote rc=<rc> <요약 줄>` 이 나옵니다. 요약 줄은 promote 출력의 마지막 `promote: 세션 기동 …` 줄입니다. promote 는 기동이 실패해도 rc 0 을 냅니다. 그래서 `handoff.py` 는 rc 0 이고 기동 결과가 `failed` 가 아닌 줄기만 `active.tsv` 에 넣습니다.

     | 요약 줄 | 처리 |
     | --- | --- |
     | `promote: 세션 기동 결과 — ok (…)` | 정상입니다. 감시 대상입니다 |
     | `promote: 세션 기동 성공 / 상태 기록 미완료 — …` | 줄기는 떴습니다. 감시 대상입니다. 「복구:」 뒤의 명령을 실행합니다 |
     | `promote: 세션 기동 결과 — unknown (…)` | 세션이 떴는지 모릅니다. `bash rd-workflow/scripts/rd task resolve-launch <slug>` 로 확인합니다. 떠 있으면 감시 대상으로 둡니다. 떠 있지 않으면 사용자에게 알리고 `active.tsv` 에서 그 줄을 지웁니다(아래 명령) |
     | `promote: 세션 기동 결과 — failed (…)` | 세션이 없습니다. `active.tsv` 에 들어가지 않았습니다. 사용자에게 사유(괄호 안)를 알립니다 |

     `active.tsv` 에서 첫 칸이 `<slug>` 인 줄을 지우는 명령입니다.

     ```bash
     a=rd-workflow-workspace/.lifecycle/fr-do/active.tsv
     awk -F'\t' -v s="<slug>" '$1!=s' "$a" > "$a.tmp" && mv "$a.tmp" "$a"
     ```

   - rc 가 0 이 아니면 `waves/<wave>/promote.log` 를 읽고 사유를 사용자에게 알립니다. 이 줄기는 `active.tsv` 에 들어가지 않으며 감시 대상이 아닙니다.
   - rc 0 인데 「기동 결과 줄 없음」 이면 `active.tsv` 에는 들어갔습니다. `promote.log` 의 그 줄기 구간(`=== <slug>` 아래)을 읽고, 세션이 없으면 사용자에게 알리고 위 명령으로 그 줄을 지웁니다.
   - rc 2 와 「slug 값이 올바르지 않습니다」·「wave 값이 올바르지 않습니다」 는 spec JSON 의 이름 문제입니다. 고쳐서 다시 실행합니다.
   - rc 1 과 `FR 상세 없음: <경로>` 는 spec JSON 의 `frs` 에 없는 stem 이 있다는 뜻입니다. 이때는 어느 줄기도 띄우지 않았습니다. stem 을 `rd-workflow-workspace/backlog/items/` 의 파일 이름에 맞게 고쳐 다시 실행합니다.
4. 감시를 겁니다. Monitor 에 아래 명령을 `timeout_ms` 1800000 으로 겁니다. **만료 알림이 올 때마다 다시 겁니다.** 이미 알린 보고는 다시 걸어도 알리지 않습니다. 감시가 꺼져 있던 동안(첫 기동 전·다시 걸기 전) 쓰인 보고는 다시 걸 때 알립니다.

   ```bash
   bash rd-workflow/scripts/fr_do/watch.sh 2>&1 | grep --line-buffered -E "^(STREAM|QUEUE|CTX|REPORT)|rror|No such"
   ```

5. `log.md` 에 착수 줄(wave, 줄기별 FR, 인계 폴더)을 덧붙입니다.
6. 사용자에게 한 줄로 보고합니다: 띄운 줄기 수, 실패한 줄기와 사유, 「감시 중 — 이벤트마다 보고합니다」.

#### 감시 이벤트 처리

이벤트마다 사용자에게 한두 줄로 보고합니다. 「할 일 없음」 이면 보고를 생략해도 됩니다.

| 이벤트 | 호출 세션 행동 | 사용자에게 보일 것 |
| --- | --- | --- |
| `STREAM <s> idle`·`STREAM <s> done` | `herdr agent read <에이전트 이름> --source visible` 로 화면을 봅니다. 백그라운드 작업을 기다리는 중이면 둡니다. 줄기가 사람 입력 없이 멈춰 있고 보고 파일도 없으면 화면 내용을 확인해 다음 이벤트를 기다립니다 | 기다리는 중이면 생략. 멈춘 것으로 보이면 「`<s>` 가 멈춰 있습니다 — <화면 요지>」 |
| `STREAM <s> blocked` | 다이얼로그(도구 권한·선택 창)가 떠 있습니다. **입력을 보내지 않습니다**(승인은 사람). 화면을 읽고 무엇을 기다리는지 확인합니다 | 「`<s>` 가 <무엇> 승인을 기다립니다 — `<s>` 탭에서 직접 승인해 주십시오」 와 다이얼로그 원문 |
| `STREAM <s> gone` | 작업 세션이 없어졌습니다. `reports/<s>-closing.md` 가 있으면 마감으로 갑니다. 없으면 `git worktree list` 로 작업 worktree 를 찾고 그 안의 `bash rd-workflow/scripts/rd task status` 로 상태를 확인합니다. 다시 띄우지 않습니다. 사용자가 다시 띄우지 않기로 하면 감시 목록에서 뺍니다(아래 「다시 띄우지 않는 줄기」) | 「`<s>` 세션이 마감 보고 없이 끝났습니다」, 작업 상태, worktree 경로, 인계 파일 경로. 다시 띄울지는 사용자가 정합니다 |
| `CTX <s> N%` | 턴이 끝난 줄기의 컨텍스트가 85% 이상입니다. 발행이나 마감 보고 중이 아니면 `herdr agent prompt <에이전트 이름> "/compact"` 를 보냅니다. 발행·마감 중이면 보내지 않습니다(발행이 끝나면 그 세션은 마감함). `idle` 화면을 읽을 때 80% 대이고 다음 단계가 리뷰처럼 길면 이벤트 없이 먼저 보내도 됩니다 | 「`<s>` 컨텍스트 N% — 압축을 보냈습니다」 또는 「발행 중이라 압축하지 않았습니다」 |
| `QUEUE <큐 줄;…>` | `요청됨` 줄이 있으면 「HOLD 처리」 절의 점검을 합니다. `rd publish next` 는 가장 앞의 `요청됨` 요청을 허가하므로 그 요청의 slug 로 `grant_check.sh` 를 부릅니다. `GRANT-OK` 면 `bash rd-workflow/scripts/rd publish next` 를 실행하고 「허가했습니다: <slug>」 를 확인합니다. `rd publish next` 가 「허가하지 않습니다 — <사유>」 또는 「허가할 요청 없음」 을 내면 허가하지 않은 것입니다. 사유를 기록하고 다음 `QUEUE` 이벤트를 기다립니다. `HOLD` 면 허가하지 않습니다. `사용자 승인 대상` 줄은 호출 세션이 허가하지 않습니다. 사용자에게 승인을 묻고, 승인하면 `bash rd-workflow/scripts/rd publish approve <s>` 를 실행합니다. `실패`·`충돌` 줄이면 `bash rd-workflow/scripts/rd publish status` 를 읽습니다 | 허가: 「`<s>` 발행을 허가했습니다」. 허가 거부: `rd publish next` 출력 원문. HOLD: 사유 목록과 처리 내용. 사용자 승인 대상: 큐 줄 원문과 「승인하면 `rd publish approve <s>` 를 실행합니다」. 실패·충돌: 큐 줄 원문과 다음 행동 |
| `REPORT …/<s>-question.md` | 줄기의 질문입니다. 파일을 읽고 「위임 답변 경계」 로 답을 정합니다. 답할 수 있으면 `herdr agent prompt <에이전트 이름> "<한 문장 답>"` 으로 보내고 답과 근거를 `log.md` 에 남깁니다. 사용자 판단이 필요하면 보내지 않고 사용자에게 묻습니다. 사용자 답을 받으면 그 답을 같은 방법으로 보냅니다 | 대신 답했으면 답과 근거(수치·파일) 한두 줄. 사용자 판단이 필요하면 질문 원문과 선택지마다 얻는 것·잃는 것 |
| `REPORT …/<s>-closing.md` | 마감 보고입니다. 「3. 마감과 재선정」 으로 갑니다 | 마감 결과(3절 7단계) |

- 다시 띄우지 않는 줄기: 작업을 폐기할지 남길지는 사용자가 정합니다.
  - 폐기하면 프로젝트의 롤백 절차(기본 체크아웃에서 `bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task <s>`)로 worktree 와 브랜치 `fr/<s>` 를 없앤 뒤 `bash rd-workflow/scripts/fr_do/close.sh <s>` 를 부릅니다.
  - 남기면 worktree 와 브랜치는 그대로 두고, 「띄우기」 절의 `active.tsv` 줄 삭제 명령으로 `<s>` 줄만 지웁니다. 이 줄기의 소유 파일과 FR 은 다음 재선정부터 보류되지 않습니다.
- `CTX` 이벤트와 「호출 세션의 압축」 은 Claude Code 상태줄에 `NN% NNNk/` 형식의 컨텍스트 표시가 있어야 동작합니다. 그 표시가 없으면 `CTX` 이벤트가 나오지 않고 `self_compact.sh` 는 `SKIP` 으로 끝납니다.
- `herdr agent prompt` 는 줄기 세션의 입력창으로 갑니다. 사람이 호출 세션에 치는 글과 섞이지 않습니다.
- 줄기는 호출 세션 입력창에 글을 보내지 않고 `reports/` 에 파일을 씁니다. 옛 인계로 띄운 줄기가 입력창으로 보내 오면 그 문장만 골라 읽습니다.
- 발행이 도는 동안에는 기본 체크아웃에 쓰지 않습니다. 호출 세션이 직접 발행 중이면 허가를 그 뒤로 미룹니다.
- `rror`·`No such` 줄은 감시 스크립트 오류입니다. 원문을 사용자에게 보이고, 원인을 고친 뒤 감시를 다시 겁니다.

#### 위임 답변 경계

- 되돌리기 어려운 효과가 없으면 줄기 권장안을 따릅니다. 따르기 전에 근거(수치·파일)를 직접 확인합니다.
- 되돌리기 어려운 선택(merge·폐기, 데이터 삭제, 외부 발행, 요구사항이 바뀌는 범위 변경, 제품 방향)은 대신 답하지 않습니다. 사용자에게 질문 원문과 선택지를 보이고 답을 받습니다.
- 등급: AI 하향은 허용합니다. 되돌리기 어려운 효과가 있으면 `full` 로 고정합니다.
- 범위 밖 파일 수정 요청은 그 파일이 다른 줄기 소유가 아니고 FR 목적에 필요할 때만 허가합니다. 다른 줄기 소유면 거절하고 마감 보고에 적게 합니다.
- 답과 근거는 `log.md` 에 남깁니다.

#### HOLD 처리

`grant_check.sh <s>` 가 `HOLD` 를 내면 첫 줄 `HOLD <s>` 아래 `  - <사유>` 줄을 읽습니다.

`grant_check.sh` 출력에 `GRANT-OK` 도 `HOLD` 도 없거나, `close.sh` 출력에 `CLOSED` 도 `NOT-CLOSED` 도 없으면 스크립트가 판정 전에 끝난 것입니다. 허가·정리를 하지 않고 출력 전문을 사용자에게 보인 뒤 멈춥니다.

| 사유 | 쪽 | 행동 |
| --- | --- | --- |
| `메인 체크아웃에 병합 진행 중(MERGE_HEAD)` | 기본 체크아웃 | 호출 세션이 병합을 끝내거나 거둔 뒤 `grant_check.sh` 를 다시 부릅니다 |
| `메인 체크아웃에 미커밋 변경: …` | 기본 체크아웃 | 호출 세션이 커밋하거나 치운 뒤 다시 부릅니다. 사유 끝에 `.gitignore 에 … 를 더하십시오` 가 붙었으면 그 줄을 `.gitignore` 에 더해 커밋합니다 |
| `충돌 판정 생략 — 로컬 브랜치 fr/<s> 가 없습니다` | 줄기 | 줄기가 브랜치를 지웠거나 다른 이름으로 작업했습니다. 줄기 화면을 읽어 확인하고, 원인을 모르면 허가하지 않고 사용자에게 알립니다 |
| `충돌 판정 실패 …` | 기본 체크아웃 | 브랜치 `fr/<s>` 와 기본 브랜치가 있는지 확인하고 원인을 고친 뒤 다시 부릅니다. 기본 브랜치를 정하지 못했다는 사유면 `rd-workflow/config/workflow.json` 에 `default_branch` 를 적습니다. `(git 2.38 이상 필요)` 가 붙으면 `git --version` 도 확인합니다. 원인을 모르면 허가하지 않고 사용자에게 알립니다 |
| `작업 상태가 '아카이브 보류' 가 아님: …` | 줄기 | 줄기에 보냅니다(아래) |
| `worktree 없음: …` | 줄기 | 허가하지 않고 사용자에게 알립니다 |
| `자동 해소 대상이 아닌 충돌: <파일들>` | 줄기 | 줄기에 보냅니다(아래) |

- 줄기 쪽 사유는 `herdr agent prompt <에이전트 이름>` 으로 사유와 함께 보냅니다: 「`bash rd-workflow/scripts/rd publish cancel` 로 요청을 거두고, 충돌 파일을 기본 브랜치의 내용에 맞춰 fr 브랜치에서 고친 뒤(보호 트리가 바뀌면 재seal) 다시 요청하십시오」.
- **줄기 브랜치에 기본 브랜치를 병합하게 하지 않습니다.** seal 의 보호 트리 해시가 깨집니다.
- 다시 요청이 오면 처음부터 점검합니다.
- 사용자에게 HOLD 사유와 처리 내용을 한두 줄로 보입니다.

#### 호출 세션의 압축

계정 자동 압축을 끈 사용자를 위한 절차입니다. 자동 압축이 켜져 있어도 해가 없습니다. 호출 세션은 잃을 게 없는 시점에 스스로 압축합니다.

- 부르는 시점: `log.md`·`active.tsv`·보고 파일에 상태를 남긴 턴을 끝내기 직전입니다. 보통 줄기 마감을 끝낸 턴, 감시 이벤트에 「할 일 없음」 으로 답한 턴입니다.
- 부르지 않는 시점: 발행 허가나 마감 절차의 중간, 기본 체크아웃에 호출 세션의 미커밋 변경이 있을 때입니다.
- 방법: `bash rd-workflow/scripts/fr_do/self_compact.sh 80` 을 `run_in_background` 로 겁니다. 스크립트는 이 세션이 `idle`·`done` 이고, 입력줄이 비었다고 확인되고, 컨텍스트가 80% 이상일 때만 `/compact` 를 입력합니다. 사람이 입력창에 치는 중이면 보내지 않고 기다립니다(최대 600초). 마지막 줄은 `SENT <N>%` 또는 `SKIP <사유>` 이고 rc 는 항상 0 입니다. 결과는 사용자에게 따로 보고하지 않습니다.
- 압축 뒤 이어 가기: 감시(Monitor)는 압축과 상관없이 돕니다. 다음 감시 이벤트가 오면 `log.md` 와 `active.tsv` 로 상태를 다시 잡습니다.

### 3. 마감과 재선정 (`REPORT …/<s>-closing.md` 가 오면)

1. 보고 파일을 끝까지 읽습니다.
2. 정리합니다.

   ```bash
   bash rd-workflow/scripts/fr_do/close.sh <s>
   ```

   - 마지막 줄이 `CLOSED <s>` 면 정리가 끝났습니다. `active.tsv` 에서 그 줄이 빠지고, `reports/` 의 그 줄기 보고 파일은 `waves/closed/` 로 옮겨집니다(`보고 보관: <경로>` 줄).
   - 마지막 줄이 `NOT-CLOSED <s> (worktree 또는 로컬 브랜치 fr/<s> 가 남음)` 이면 함께 나온 `rd task list` 줄(예: 「정리 보류 — 점유」)이 정리 보류 사유입니다. 사유를 없앤 뒤 `close.sh <s>` 를 다시 부릅니다.
   - 마지막 줄이 `NOT-CLOSED <s> (git pull --ff-only 실패)` 면 기본 체크아웃 갱신이 실패한 것입니다. `git status` 로 원인(미커밋 변경, 갈라진 이력)을 확인해 없앤 뒤 다시 부릅니다.
   - 사유를 없앨 수 없으면 사용자에게 사유와 남은 worktree 경로·브랜치 `fr/<s>` 를 알립니다. `active.tsv` 의 줄은 남아 있으므로 그 줄기의 소유 파일은 재선정에서 계속 보류됩니다.
3. 보고의 「호출 세션」 담당 행동을 처리합니다. 흔한 것은 테스트 등록과 문서 한 줄 보완입니다. 테스트 등록·검증은 프로젝트 규칙의 검증·테스트 등록 절차를 따릅니다. 등급은 프로젝트 규칙의 등급 판정을 따르고, 고친 영역의 검증을 돌려 통과를 확인합니다.
4. FR 후보: 재현·관측 근거가 있는 것만 등록합니다. 관측 1회나 추정은 「목록만」 으로 남기고 이유를 적습니다. 등록은 `/fr add` 절차(items + 인덱스 행 → `rd task fr-register` → `fr_relations.sh validate`)입니다.
5. 줄기 FR 에 GitHub issue 가 걸려 있으면 `fr:done` 라벨과 함께 닫습니다.
6. `log.md` 에 마감 줄(merge 커밋, 처리한 후속, 등록·보류한 FR 후보)을 덧붙입니다.
7. 사용자에게 보고합니다.
   - 줄기 결과: FR 별 완료·보류.
   - 처리한 후속과 등록한 FR 후보(「목록만」 포함).
   - 남은 줄기: `active.tsv` 의 slug 목록.
   - 커밋·issue·저장소는 `https://` 로 시작하는 전체 URL 로 씁니다.
8. 재선정: 사용자가 「더 띄워」 처럼 계속을 지시했거나 처음 지시가 착수 가능한 FR 전부였으면 「1. 고르기」 부터 다시 합니다. `pick.py` 는 `active.tsv` 를 읽어 실행 중 줄기가 맡은 FR, 실행 중 줄기와 겹치는 FR, 동시 상한을 넘는 FR 을 `hold` 로 냅니다. 새로 띄울 줄기가 없으면 착수 보고 없이 「새로 띄울 줄기 없음」 한 줄만 보입니다.
9. `active.tsv` 가 비고 재선정할 줄기도 없으면 감시를 멈추고 「모든 줄기 마감」 과 전체 요약을 보입니다.

### 4. 무인 (`--headless`)

1. 후보를 고릅니다: `python3 -I rd-workflow/scripts/fr_do/pick.py --mode headless [--slugs "<s> <s>"]`. 출력은 `order`(우선순위 순 실행 후보)와 `skip` 입니다. 무인은 `idea` 상태를 고르지 않습니다.
2. 선별합니다. `order` 의 FR 마다 아래를 봅니다.
   - `revisit when` 미도래와 해결 흔적은 「1. 고르기」 3단계와 같습니다.
   - autopilot 적합성: `rd-workflow/claude_skills/autopilot/SKILL.md` 의 「autopilot 적합성 기준」 으로 가능 / 조건부 가능 / 불가를 판정합니다(`/fr inspect` 와 같은 기준). 가능만 통과합니다. 조건부 가능은 충족 조건이 이미 채워졌을 때만 통과합니다.
3. 착수 보고를 보입니다. 첫 줄은 발행 정책입니다.

   | `--finish` | 첫 줄 |
   | --- | --- |
   | `push` 또는 생략 | `발행: push(원격까지)` |
   | `merge` | `발행: merge(로컬 병합까지)` |
   | `none` | `발행: none(fr 브랜치 커밋까지)` |

   그 아래 실행할 FR 목록(순서대로)과 「뺀 FR」 표(`skip` 줄과 선별에서 뺀 FR, 이유)를 둡니다.
4. 통과한 FR 이 0건이면 엔진을 부르지 않습니다. 「실행 대상 없음」 과 FR 별 제외 사유를 보이고 끝냅니다.
5. 엔진을 `run_in_background` 로 실행합니다. 로그는 상태 폴더의 파일로 받습니다.

   ```bash
   mkdir -p rd-workflow-workspace/.lifecycle/fr-do
   RD_RALPH_SLUGS="<통과한 short-title들>" RD_FINISH_POLICY=<push|merge|none> \
     bash rd-workflow/scripts/ralph_drain.sh > rd-workflow-workspace/.lifecycle/fr-do/headless-<YYYYMMDD-HHMM>.log 2>&1
   ```

   - `--finish` 를 생략했으면 `RD_FINISH_POLICY=push` 를 명시해 넘깁니다. 엔진을 직접 실행할 때의 기본값은 `merge` 입니다.
   - 엔진은 매 반복 지정 목록 안에서 다음 FR 을 골라 `autopilot_headless.sh` 로 완주합니다. 완료·blocked 된 FR 은 다음 반복에서 빠집니다.
   - 사용자에게 「무인 실행을 시작했습니다 — 대상 N건, 로그: <절대 경로>」 를 보입니다.
6. 끝나면 로그의 `---- ralph_drain 요약 ----` 절을 사용자에게 옮깁니다: 완료 건수, blocked 건수와 사유, 종료 사유, 대기 상세, 실행 비용 합계, 정리 잔여.

   | 엔진 종료 | 뜻 |
   | --- | --- |
   | exit 0 `queue-empty (지정 목록 소진)` | 지정 FR 을 모두 처리함 |
   | exit 0 `queue-blocked (의존 대기 — 지정 목록에 착수 가능 FR 없음)` | 남은 FR 이 선행 FR 을 기다림. 대기 상세를 보임 |
   | exit 1 | 중단(관계 판정 불가, 반복 상한, harness 오류 재발 등). 종료 사유와 로그 경로를 보임 |

   blocked FR 은 `/fr status <slug> validated` 로 되돌려 다시 시도할 수 있다고 알립니다.

### 5. `/fr batch` 별칭

`/fr batch` 는 `/fr do --headless` 의 별칭입니다. 이번 배포까지 동작하고 다음 배포에서 없어집니다.

1. `bash rd-workflow/scripts/fr_do/batch_legacy.sh` 를 실행하고 출력을 그대로 사용자에게 보입니다.
   - 첫 줄은 항상 이관 안내입니다. 둘째 줄은 발행 기본값 안내(`push`, `--finish merge` 로 바꿈)입니다.
   - 남은 batch manifest(`rd-workflow-workspace/.batch-manifest.json`)가 있으면 이어 처리할 slug 목록이 나옵니다. 읽지 못하면 그 경로를 직접 열어 보라는 안내가 나옵니다.
   - rc 는 항상 0 입니다.
2. 인자를 그대로 `/fr do --headless <인자>` 로 처리합니다(「4. 무인」 절).
3. 남은 manifest 파일은 지우지 않습니다. 사용자가 확인한 뒤 지웁니다.

### 하지 않는 것

- 줄기의 다이얼로그(`blocked`)에 입력을 보내지 않습니다. 승인은 사람이 합니다.
- 되돌리기 어려운 선택을 줄기 대신 답하지 않습니다(「위임 답변 경계」).
- 줄기 브랜치에 기본 브랜치를 병합하게 하지 않습니다.
- 패턴으로 프로세스를 죽이지 않습니다(`pkill -f` 금지). 멈출 때는 task ID·PID 로 합니다.
- 호출 세션이 만들지 않은 탭·pane 을 닫지 않습니다. `close.sh` 는 promote 가 그 줄기용으로 띄운 slug 탭만 닫습니다.
- `/fr archive`·`park`·`status`·`push`·`sync` 와 발행(`/publish`)은 사용자 요청이 있을 때만 합니다.
- 파일 삭제는 `trash` 로 합니다.
