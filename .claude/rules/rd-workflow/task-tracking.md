## Task Tracking

Status·Short Title·Source FR 변경은 `rd task` CLI를 경유한다 (기계 판정 권위: `rd-workflow-workspace/.lifecycle/task-state` — `CURRENT_TASK.md`의 해당 필드는 표시용 미러). 미러는 표시용이면서 **권위 손실 시의 대조 출처**이므로, 세 필드를 손으로 한쪽만 고치지 않는다 — promote 는 `source-fr` 가 양쪽에서 다르면 어느 쪽이 최신인지 판정하지 않고 중단한다.

Status 허용값 (`rd task` CLI 전이표가 이 값으로 판정하며, hook이 강제하지 않으므로 사람과 AI가 지킨다): `대기 중` / `REQUEST review 대기` / `spec/plan 작성 중` / `spec/plan review 대기` / `구현 대기` / `구현 중` / `검증 중` / `diff review 대기` / `아카이브 보류` / `완료`.

`아카이브 보류` 는 「리뷰 종결·발행 대기」이며 **`완료` 가 아니다.** final diff review 가 종결되고 종결 마커(`rd review seal`)를 만든 뒤 진입하며, 그 상태에서 기록 커밋을 하고 `archive.sh` 로 발행한다. 전이는 `diff review 대기` → `아카이브 보류` → `완료` 이고, 리뷰 후 변경이 필요해지면 `아카이브 보류` → `구현 중` 으로 되돌린다.

`구현 대기` 는 「spec/plan review 종결·구현 착수 대기」다. spec/plan review 세션의 최신 Reviewer 턴이 `이의 없음`을 명시해 종결되면 orchestrator 가 `구현 대기` 로 전이하고, 구현을 실제로 시작하면 `구현 중` 으로 전이한다. 리뷰 후 변경이 필요해지면 `구현 대기` → `spec/plan 작성 중` 으로 되돌린다.

`CURRENT_TASK.md`는 orchestrator(메인 세션)가 REQUEST 정리·spec 생성·plan 생성·구현 시작·검증 완료·REQUEST 아카이브 후에 다시 쓴다. 병렬 구현자 subagent는 이 파일을 쓰지 않는다 (`implementation_gate.sh`의 subagent 주체 게이트가 `Edit`·`Write` 경유 쓰기를 차단하며, 진행 상황은 결과로 반환한다).

각 리뷰 게이트(REQUEST review·spec/plan review·final diff review)는 최신 Reviewer 턴이 이의 없음을 명시한 시점에 갱신한다 — `awaiting-user` 전환·사람의 마무리 승인·세션 `closed` 전환은 그 뒤에 오는 별개 사건이며 갱신 의무를 그 시점까지 미루지 않는다. 세션 종료 시(사람에게 턴을 넘기며 대화가 끝나는 시점)에도 갱신한다.

Next Step 본문에 `Status: …` 문자열을 적지 않는다 — `## Status` 필드가 단일 표기 지점이다.

## Spec / Plan Naming

파일명은 `YYYY-MM-DD-HHMM-작업명-종류.md`이고 종류는 `spec` / `change-spec` / `plan` 이다. 위치는 새 기능 spec `rd-workflow-workspace/specs/base/`, 기존 코드 변경 change spec `rd-workflow-workspace/specs/changes/`, plan `rd-workflow-workspace/plans/` 이다.
