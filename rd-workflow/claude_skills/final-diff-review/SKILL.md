---
name: final-diff-review
description: Prepare final handoff after implementation by checking verification status, drafting PR text, and orchestrating the final diff review until the branch is ready to merge or the user must decide. Use when implementation is done or nearly done; if verification has not been run yet, this skill runs it first.
---

# Final Diff Review

`manual` 모드에서는 사용자의 단계 진입 지시 없이 이 skill 을 스스로 시작하지 않는다. 판정 기준은 `rd-workflow/docs/flows/AUTONOMY.md` 의 「실행 모드와 skill 호출 권한」 절이다.

Use this after implementation is done or nearly done.

Typical user request:
- "final-diff-review skill로 진행해줘"

Read these first:
- `CURRENT_TASK.md`
- `rd-workflow/docs/PR_TEMPLATE.md`
- `rd-workflow/docs/prompts/review/diff_review.md`
- `rd-workflow-workspace/review-standards.md` (리뷰 표준 — 주석 밖 내용이 있을 때만, 리뷰어가 같은 표준으로 검토합니다)

Execution rules:
- 이 skill 은 `CURRENT_TASK.md` 의 `## Short Title` 을 read-only 로 사용한다 (변경 / 삭제 금지). short-title 은 작업 시작 시점 (`planning-design-intake` 또는 `promote.sh` 승격) 에 1회 부여되고 archive 까지 immutable 이다.
- 검증은 `bash rd-workflow/scripts/verify_record.sh -- <검증 명령>` 으로 돌려 증거를 남긴다 (프로젝트의 검증 명령 — 예: `test.sh`·`lint.sh`·`typecheck.sh`·`build.sh`, 이 저장소는 `self_test.sh <그룹>`). `rd review seal` 은 통과 증거의 트리가 리뷰 승인 트리와 같을 때만 종결 마커를 만든다. 검증 시점은 다음과 같다.
  - 세션을 열기 전: 전체 검증(이 저장소는 고친 영역의 `self_test.sh <그룹>`)을 `verify_record.sh` 로 한 번 돌린다. 리뷰 중 트리가 바뀌지 않으면 이 증거로 seal 한다.
  - 리뷰 중 코드를 고친 중간 턴: 고친 영역의 테스트만 돌리고(이 저장소는 `self_test.sh <테스트 파일>` — 그룹 전체가 아니라 고친 스크립트의 테스트 파일) 그 명령과 결과를 Author 턴에 싣는다. FAIL 을 재확인할 때도 그 파일만 다시 돌린다. 변이 결과표는 가이드 「갱신 규칙」대로 바뀐 행만 갱신한다. 전체 검증과 결과표 전체 재생성은 하지 않는다.
  - Reviewer 가 이의 없음으로 수렴한 뒤 seal 직전: 리뷰 중 트리가 바뀌었으면 전체 검증을 `verify_record.sh` 로 한 번 더 돌린다. 통과하면 seal 한다. 실패하면 고친 내용을 Author 턴으로 쓰고 `bash rd-workflow/scripts/run_review_turn.sh <세션> --reopen "<사유>"` 로 재확인 턴을 받는다.
- seal 뒤 발행(`archive.sh`)의 승인 주체와 순서는 `rd-workflow/docs/flows/AUTONOMY.md` 「종결 마커(seal)와 발행 승인」 절을 따른다(`publish_approval` — 호출 세션 허가 또는 사용자 승인).
- seal·`아카이브 보류`·기록 커밋 뒤, 반영 방식 `pr` 인 submodule 이 있으면 발행 앞의 다음 단계는 `bash rd-workflow/scripts/rd pr open` 입니다(`--dry-run` 으로 대상 표를 먼저 볼 수 있습니다). PR 이 올라가면 Status 가 `PR 검토 중` 이 되고, merge 뒤 `rd pr check --apply` 가 포인터를 옮기고 `아카이브 보류` 로 되돌립니다. 흐름의 정본은 `rd-workflow/docs/flows/WORKFLOW.md` 「`PR 검토 중` — 팀 저장소 반영」 절입니다. 이 PR 본문은 팀 저장소 PR 본문으로 쓰이므로 팀 독자가 읽을 수 있게 씁니다.
- PR 본문은 `rd-workflow/docs/PR_TEMPLATE.md` 로 쓰고 Author 첫 턴의 `## PR 본문` 절에 싣는다. `## PR 본문` 절 안에서는 템플릿의 `##` 제목을 그대로 쓰고, 템플릿에 없는 `##` 제목이 나오면 그 앞에서 본문이 끝난다. `## 되돌리기와 영향 범위` 는 커밋 전 재분류 결과(`REQUEST.md ## Risk Tier` 의 근거 신호)에서 채운다. 리뷰 중 본문을 고치면 그 Author 턴에 `## PR 본문` 절 전체를 다시 싣는다. 완료 보고와 발행 승인 질문이 옮겨 쓰는 출처는 이 절을 담은 가장 최근 Author 턴 하나다.
- 세션 생성 전에 커밋 전 재분류(WORKFLOW.md 위험 등급 절) 를 끝내고 `REQUEST.md ## Risk Tier` 의 `- 최종 등급:` 이 확정되어 있어야 한다 — `prepare_review_pipeline.sh` 가 이 줄로 리뷰 effort 를 정한다.
- **변이 결과표**: 세션 생성 전에 `rd-workflow/docs/guides/mutation-check.md` 「절차」로 이 변경의 필수 대상 단언 결과표를 만들고 Author 첫 턴에 싣는다. `full` 은 task 완료 보고의 행을 모으고, `standard` 는 diff 에서 필수 대상을 직접 식별한다(plan 은 쓰지 않는다). 필수 대상이 없으면 `필수 대상 없음 — 사유` 한 줄을 싣는다. `생존`·원복 `미확인` 행이 남은 채로 세션을 열지 않는다. 리뷰 중 고친 코드가 행의 대상·동작·실행 조건을 바꾸면 가이드 「갱신 규칙」대로 다음 Author 턴에 갱신 행을 싣는다.
- 세션 생성 전에 Status 를 `diff review 대기` 로 전이하고(`구현 중 → 검증 중 → diff review 대기`), 작업물과 `rd task set-status` 가 알린 「커밋할 파일」 을 커밋한다. 커밋하지 않은 `CURRENT_TASK.md`·task-state 는 리뷰 대상 HEAD 에서 낡은 값으로 보인다.
- Start the final diff review with `bash rd-workflow/scripts/prepare_review_pipeline.sh diff` and continue with `bash rd-workflow/scripts/run_review_turn.sh ...` until the session reaches `awaiting-user` or the latest Reviewer turn has no objections.
- Do not edit the SESSION.md Status or Current Owner by hand after writing an Author turn. `run_review_turn.sh` hands them over, and tells you the next action when it cannot.
- 수렴한(이의 없음) 세션에 재확인이 필요하면(seal 직전 전체 검증 실패, 기록 커밋 뒤 변경, main 병합 뒤 확인) 새 세션을 만들지 않고 바뀐 내용을 Author 턴으로 쓴 뒤 `run_review_turn.sh <세션> --reopen "<사유>"` 로 다시 연다. 사유는 SESSION 의 `## Reopen History` 에 남는다. 미해결 이의가 남은 `awaiting-user` 세션은 `--reopen` 으로 열리지 않는다. 사람이 `USER_ACTION.md` 의 질문에 답한 뒤 다음 둘 중 하나로 잇는다. 두 경우 모두 SESSION 을 손으로 고치지 않는다.
  - 사람의 결정대로 이어 가기: 결정을 반영한 Author 턴을 쓴 뒤 `run_review_turn.sh <세션> --decision "<사용자 결정>"` 을 실행한다. 결정은 SESSION 의 `## Reopen History` 와 `USER_ACTION.md` 의 `## User Decision` 에 남고 Reviewer 턴이 이어서 돈다.
  - 남은 이의를 덮고 종결하기(사람이 정한 경우만): `run_review_turn.sh <세션> --override "<결정한 사람> — <그 사람이 한 말>"` 을 실행한다. Closure Reason 이 `user-override` 와 날짜가 붙은 `근거:` 줄이 되고 Status 가 `closed` 가 된다. 자율 모드는 스스로 이 결정을 내리지 않는다.
  - 사람이 남은 이의를 범위 밖으로 정하면 `--decision` 실행 전에 `REQUEST.md ## Constraints` 에 `- 범위 밖: <항목> — <사유> (결정: 사람, <리뷰 종류> 턴 NNN)` 줄을 쓴다. 다음 리뷰어 지시가 이 줄을 읽는다.
  - 턴 한도(20턴)에 도달한 세션을 이어 가려면 `--decision`·`--reopen` 실행에 사람이 정한 연장 폭 `--extend-turns <N>` 을 함께 붙인다.
- 기록 커밋(REQUEST.md 비우기·보관본 추가) 뒤에 여는 리뷰는 구간에 추가된 `request-archive/` 보관본을 완료 기준과 리뷰 effort 의 출처로 쓴다. 세션 준비와 리뷰 턴이 보관본 경로를 자동으로 찾아 리뷰어에게 알린다.
- Author 턴은 Reviewer 지적에 응답하기 전에 `receiving-code-review` 로 지적마다 사실을 확인하고 「수용 / 반박 / 보류」 와 근거를 적는다 (`FILE_BASED_REVIEW_PIPELINE.md` 턴 규칙).
- 독립 reviewer가 없어 self-review(claude)로 fallback될 때, 기본 정책 `self_review_policy=block`이면 일반 모드에서 차단된다. 독립 reviewer 없이 진행하려면 `RD_SELF_REVIEW_APPROVE=1`로 재실행하거나 `review-tools.json`에서 정책을 `warn`/`off`로 바꾼다.
- **범위 밖 항목 보고**: `run_review_turn.sh` 가 Reviewer 턴 뒤에 출력하는 「범위 밖으로 돌린 항목」 목록(6턴 뒤 범위 축소 — `FILE_BASED_REVIEW_PIPELINE.md` 턴 규칙)을 세션이 끝날 때 리뷰 보고서(`rd-workflow-workspace/reports/reviews/`)와 사용자 응답에 옮긴다. final diff review 의 범위 밖 항목은 다음 리뷰 단계가 없으므로 completion report 「정리 후보」 에도 남긴다.
- Update `CURRENT_TASK.md` if the task status changes.

Final output:
- Verification status
- 변이 결과표 요약 (`검증됨`·`생존`·`미검증` 개수와 `무효(사유)` 시도 수, 또는 `필수 대상 없음 — 사유`)
- PR 본문 위치 (`## PR 본문` 절을 담은 가장 최근 Author 턴 경로)
- final diff review session path
- 정리 후보 (Reviewer 턴의 `정리 후보:` 줄과 Author 가 본 범위 밖 정리거리, 없으면 `없음`) — 완료 보고 `## 정리 후보` 로 옮긴다
- 후속 FR 확인 — 기록 커밋 전에 `bash rd-workflow/scripts/lifecycle/followup_check.sh REQUEST.md HEAD <기본 브랜치>` 를 실행해 출력을 싣는다(출력이 없으면 `없음`). REQUEST 에서 범위 밖으로 뺀 후속은 `- 후속 FR: <slug>` 줄로 적혀 있어야 한다. 미등록 slug 와 흡수 확인 후보(Source FR 과 서로 언급하는 dropped FR)는 완료 보고 `## 정리 후보` 로 옮기고, 흡수 후보마다 이번 작업이 그 범위를 처리했는지 또는 어느 후속 FR 로 넘겼는지 적는다
- merge readiness or the exact user decision still needed

## rd-workflow 버전 대조

이 skill 은 아래 `RD_SKILL_BASE` 보다 나중에 배포된 rd-workflow 를 전제한다. 첫 작업 단계보다 먼저, 프로젝트 루트에서 아래 명령을 이 호출에서 한 번 실행한다.

- 출력이 없으면 그대로 진행한다.
- 출력이 있으면 출력 전문을 사용자에게 알리고, 템플릿을 sync 할지 그대로 계속할지 묻고 멈춘다. 사용자가 계속을 지시하면 진행한다.
- autopilot·무인 실행처럼 물을 사람이 없으면 계속하지 않고 그 출력을 중단 사유로 보고한다.

```bash
bash -s <<'RD_SKILL_COMPAT'
RD_SKILL_BASE=2026-11-08-092219 RD_SKILL_NAME=final-diff-review
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
