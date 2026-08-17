# Plan Phase 병렬 실행 규약

plan이 phase를 표현하면 autopilot/subagent-driven 실행이 phase 내 task를 병렬 dispatch하여 wall-clock 시간을 단축한다. 이 문서는 plan 작성자와 실행 주체(autopilot SKILL §4)가 공유하는 단일 규약이다.

## plan 산출물에 추가하는 3요소

1. **phase 그룹핑**: task를 phase로 묶는다. **같은 phase의 task는 서로 파일 비중첩·의존 없음(병렬 안전)**이어야 한다. phase 간에는 순차 의존이 성립한다 (phase N+1은 phase N 완료 후 시작).
2. **task별 파일 목록**: 각 task의 `Files:` 블록(Create/Modify)이 그대로 비중첩 판정 근거가 된다. 정확히 적는다.
3. **task별 review flag**: `mechanical`(리뷰어 생략) 또는 `needs-review`(리뷰어 유지). flag가 없으면 `needs-review`로 간주한다.

### mechanical 판정 — 3조건 전부 충족 시에만

- 변경 파일 2개 이하
- brief(task 본문)에 전체 코드가 verbatim으로 포함됨 (전사 수준)
- 신규 로직 분기 없음

하나라도 불충족이면 `needs-review`.

## 실행 의미 (autopilot SKILL §4가 이 절차를 따른다)

phase 단위 순차 루프:

1. phase 내 task들의 구현자 subagent를 **병렬 dispatch** 합니다. 구현자는 자기 task 파일의 Edit/Write만 하고 git 조작을 하지 않습니다 (subagent-git-safety.md). 공유 진행 상태(`CURRENT_TASK.md`·`REQUEST.md`·`task-state`)는 그 disjoint 집합에서 **제외**됩니다 — 구현자는 진행 상황을 결과 텍스트로 반환하고, `implementation_gate.sh` 가 `Edit`·`Write` 경유 쓰기를 hook 수준에서 차단합니다.
2. barrier: phase 내 모든 구현자 완료 대기.
3. **orchestrator(실행 세션 본체)가 커밋**한다 (동시 커밋 경합 회피).
4. 검증(test/lint/build 또는 프로젝트 실질 검증)을 **phase barrier 후 1회** 실행. loop-guard `verify-fail` 기록도 이 검증 기준으로 1회 (키 포맷 불변). 실패 시 systematic-debugging으로 phase 단위 수정 후 재검증.
5. 리뷰어 **병렬 dispatch** (read-only라 공유 트리 안전). `mechanical` task는 리뷰어를 생략하고 final diff review에 위임한다. `needs-review` task만 리뷰어를 dispatch한다.
6. barrier: 리뷰 수렴 후 다음 phase로.

phase 내 task가 1개면 병렬의 의미가 없어 순차와 동일하게 동작한다.

### barrier 실패 정책 (부분 완료)

- orchestrator 커밋(step 3)은 **phase 내 모든 구현자가 정상 완료한 뒤에만** 수행한다. 하나라도 실패·타임아웃·사멸하면 phase를 실패로 처리하고 **부분 완료 파일을 커밋하지 않는다**.
- 실패 시 워킹트리를 점검하여 실패 task의 부분 변경을 systematic-debugging으로 완결하거나 되돌린 뒤 phase를 재실행한다. 성공한 형제 task 결과는 disjoint이므로 유지 가능하나, 커밋은 phase 전체 성공 시점에 일괄로만 한다.
- 디버깅 3회 실패 시 상태를 보고하고 사용자에게 넘긴다.

## Backward compatibility

- phase를 하나도 표현하지 않은 plan(legacy 포함)은 **전체를 순차 실행**으로 degrade한다.
- review flag가 없는 task는 `needs-review`로 간주한다 (안전 기본값).

## 안전망 — spec/plan review의 phase 비중첩 검증 (주 게이트)

병렬 실행은 config 플래그 없이 plan에 phase가 있으면 자동 발동합니다. 공유 진행 상태 3종은 `implementation_gate.sh` 가 `Edit`·`Write` 경유에 한해 구조적으로 차단하지만, **그 밖의 task 간 파일 중첩을 막는 것은 spec/plan review가 유일**합니다. 리뷰어는 다음을 필수로 확인합니다:

- 같은 phase에 속한 task들의 `Files:` 목록이 실제로 서로 **disjoint**한가.
- **실효 쓰기 집합 기준**: disjoint 판정은 직접 편집뿐 아니라 그 편집이 유발하는 **생성·전파 산출물까지 포함**한다. 정본(`_ROOT_FILES/`) 편집과 그 산출물(빌드/전파로 생성되는 루트 `rd-workflow/`)은 같은 실효 대상이다.
- **빌드·전파 단계(예: `install-root`)나 생성 산출물 쓰기는 소스 편집 task와 같은 phase에 두지 않고, 소스 편집이 모두 끝난 뒤의 순차 최종 task로 분리한다.**
- 중첩이 발견되면 phase 재구성(중첩 task를 다른 phase로 분리)을 요구한다.

## 불변

- **final diff review는 어떤 경우에도 생략·축약하지 않는다.** 병렬·리뷰 생략과 무관하게 최종 독립 게이트로 유지한다.
- 이 규약은 상호작용 모드(manual/semi-auto/autopilot)와 무관하게, subagent-driven-development를 쓰는 모든 실행에 적용한다.
