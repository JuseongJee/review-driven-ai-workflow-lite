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

Execution rules:
- 이 skill 은 `CURRENT_TASK.md` 의 `## Short Title` 을 read-only 로 사용한다 (변경 / 삭제 금지). short-title 은 작업 시작 시점 (`/fr add`, `planning-design-intake`, 또는 `promote.sh` 승격) 에 1회 부여되고 archive 까지 immutable 이다.
- 검증은 `bash rd-workflow/scripts/verify_record.sh -- <검증 명령>` 으로 돌려 증거를 남긴다 (프로젝트의 검증 명령 — 예: `test.sh`·`lint.sh`·`typecheck.sh`·`build.sh`, 이 저장소는 `self_test.sh <그룹>`). 증거가 없거나 리뷰 중 코드를 고쳐 트리가 바뀌었으면 다시 돌린다. `rd review seal` 은 통과 증거의 트리가 리뷰 승인 트리와 같을 때만 종결 마커를 만든다.
- Draft the PR description with `rd-workflow/docs/PR_TEMPLATE.md`.
- 세션 생성 전에 커밋 전 재분류(WORKFLOW.md 위험 등급 절) 를 끝내고 `REQUEST.md ## Risk Tier` 의 `- 최종 등급:` 이 확정되어 있어야 한다 — `prepare_review_pipeline.sh` 가 이 줄로 리뷰 effort 를 정한다.
- **변이 결과표**: 세션 생성 전에 `rd-workflow/docs/guides/mutation-check.md` 「절차」로 이 변경의 필수 대상 단언 결과표를 만들고 Author 첫 턴에 싣는다. `full` 은 task 완료 보고의 행을 모으고, `standard` 는 diff 에서 필수 대상을 직접 식별한다(plan 은 쓰지 않는다). 필수 대상이 없으면 `필수 대상 없음 — 사유` 한 줄을 싣는다. `생존`·원복 `미확인` 행이 남은 채로 세션을 열지 않는다. 리뷰 중 고친 코드가 행의 대상·동작·실행 조건을 바꾸면 가이드 「갱신 규칙」대로 다음 Author 턴에 갱신 행을 싣는다.
- Start the final diff review with `bash rd-workflow/scripts/prepare_review_pipeline.sh diff` and continue with `bash rd-workflow/scripts/run_review_turn.sh ...` until the session reaches `awaiting-user` or the latest Reviewer turn has no objections.
- 독립 reviewer가 없어 self-review(claude)로 fallback될 때, 기본 정책 `self_review_policy=block`이면 일반 모드에서 차단된다. 독립 reviewer 없이 진행하려면 `RD_SELF_REVIEW_APPROVE=1`로 재실행하거나 `review-tools.json`에서 정책을 `warn`/`off`로 바꾼다.
- Update `CURRENT_TASK.md` if the task status changes.

Final output:
- Verification status
- 변이 결과표 요약 (`검증됨`·`생존`·`미검증` 개수, 또는 `필수 대상 없음 — 사유`)
- PR summary status
- final diff review session path
- merge readiness or the exact user decision still needed

## rd-workflow 버전 대조

이 skill 은 아래 `RD_SKILL_BASE` 보다 나중에 배포된 rd-workflow 를 전제한다. 첫 작업 단계보다 먼저, 프로젝트 루트에서 아래 명령을 이 호출에서 한 번 실행한다.

- 출력이 없으면 그대로 진행한다.
- 출력이 있으면 출력 전문을 사용자에게 알리고, 템플릿을 sync 할지 그대로 계속할지 묻고 멈춘다. 사용자가 계속을 지시하면 진행한다.
- autopilot·무인 실행처럼 물을 사람이 없으면 계속하지 않고 그 출력을 중단 사유로 보고한다.

```bash
bash -s <<'RD_SKILL_COMPAT'
RD_SKILL_BASE=2026-11-01-202303 RD_SKILL_NAME=final-diff-review
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
