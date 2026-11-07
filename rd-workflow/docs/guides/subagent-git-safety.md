# Subagent Git 안전 가이드

subagent-driven-development으로 dispatch한 subagent는 **공유 git 워킹트리**에서 실행된다. subagent가 브랜치를 전환하면 진행 중인 fr branch가 바뀌어 메인 세션의 REQUEST.md/CURRENT_TASK.md/FR items가 baseline 상태로 노출된다. 이 가이드는 그 교란을 막는 단일 출처다.

**worktree 격리가 기본이 되어도 이 문제가 사라지지 않는다.** 각 FR 작업은 서로 다른 worktree 로 격리되지만, **같은 worktree 안에서 동시에 dispatch한 병렬 subagent 들은 여전히 그 worktree 의 git index 를 공유한다** — worktree 격리는 작업(FR) 사이의 교란만 막을 뿐, 한 작업 안의 병렬 구현자 사이의 index 경합까지 해결하지는 않는다(FR `shared-worktree-index-race`). 병렬 구현자에게 커밋을 맡기지 않고(아래 "phase 병렬 dispatch" 참조) orchestrator 가 barrier 후 일괄 커밋하는 규칙은 이 문제 때문에 여전히 필요하다.

## 1. Subagent Git 안전 문구 (dispatch prompt 삽입용)

subagent를 dispatch할 때 아래 문구를 dispatch prompt에 **그대로 포함**한다:

> 이 작업은 공유 git 워킹트리에서 실행됩니다. `git checkout` / `git switch` / `git branch` / `git worktree` 등 브랜치·작업트리를 전환하거나 생성/삭제하는 명령을 절대 실행하지 마십시오. git은 읽기 전용(`git log` / `git diff` / `git show` / `git status` / `git rev-parse`)으로만 사용하십시오. 브랜치 전환이 필요하다고 판단되면 실행하지 말고 그 사실을 결과에 보고하십시오. commit은 메인 세션이 수행합니다.
> 또한 `CURRENT_TASK.md` / `REQUEST.md` / `rd-workflow-workspace/.lifecycle/task-state` 는 orchestrator 전용 공유 진행 상태입니다. 수정하지 마십시오 — 진행 상황·완료 보고는 결과 텍스트로 반환하면 orchestrator 가 반영합니다.

git 전환 금지는 **advisory**입니다 — LLM이 무시할 수 있고, 그 부분의 구조적 차단은 2번(worktree 격리)만 보장합니다. 반면 **공유 진행 상태 금지는 advisory가 아닙니다** — `implementation_gate.sh` 가 hook 입력 **최상위**의 subagent 전용 필드(`agent_type`, 없으면 `agent_id`) 존재와 대상 3종을 판정해 `exit 2` 로 차단합니다. `tool_input` 하위의 동명 필드는 판별에 쓰지 않습니다. 단 이 차단은 `Edit`·`Write` 도구 경유에 한합니다 — `Bash` 로 직접 쓰는 경로는 이 hook 의 matcher 밖이라 발동하지 않으며, 그 경우 위 dispatch 문구가 최종 방어선입니다.

## 1-2. 진행 기록 문구 (dispatch prompt 삽입용)

다단계이거나 파괴적 상태를 만드는 task 를 dispatch 할 때는 보고서 경로를 지정하고, 아래 문구를 dispatch prompt 에 **그대로 포함**한다 (`<보고서 경로>` 만 치환):

> 이 task 의 보고서는 `<보고서 경로>` 입니다. 각 Step(또는 각 커밋)을 끝낼 때마다 그 직후에 보고서에 그 Step 의 명령과 실제 출력을 이어 쓰십시오(append). 끝에 한 번에 쓰지 않습니다.
> 워킹트리에 의도적으로 비정상 상태(변이 주입·임시 파일·되돌려야 할 편집)를 만드는 Step 은 **만들기 직전에** 그 사실과 복구 명령을 보고서에 먼저 적으십시오. 만든 뒤에 적으면 그 사이에 종료됐을 때 아무도 모릅니다. 상태를 되돌린 직후 되돌렸다고 적으십시오.

짧은 단일 Step task 는 보고서 경로를 지정하지 않아도 되므로 이 문구를 생략할 수 있다.

## 2. worktree 격리 권장 (선택)

`isolation: "worktree"`(Claude Code Agent 도구의 파라미터)로 격리한 subagent는 공유 워킹트리와 물리적으로 분리되어 git 전환 교란을 구조적으로 차단한다. 단, 격리 worktree는 **commit된 branch 상태만** 복제하므로 메인 워킹트리의 unstaged/uncommitted 변경과 미추적 파일은 보이지 않는다.

- **적합**: 검토 대상이 commit된 branch 상태로 충분한 read-only 탐색/리뷰/감사.
- **부적합 / 대안**: 미커밋 변경·미추적 파일을 검토해야 하면, 격리 worktree에 diff/context를 명시 전달하거나 격리를 쓰지 않고 1번 강제 문구만 적용한다.

이번 단계에서는 강제하지 않는다. 전면 강제·cleanup/naming/concurrent 정책 설계는 후속 FR `subagent-worktree-isolation-enforce`에서 다룬다.

## 3. 사고 감지·복구 절차

subagent dispatch 후 워킹트리가 교란된 것으로 의심되면:

1. **현재 브랜치 확인**: `git rev-parse --abbrev-ref HEAD` — 의도한 fr branch가 아니면 교란 발생.
2. **커밋 보존 확인**: `git log --oneline -5 <fr-branch>` 와 `git reflog` — 작업이 commit돼 있으면 손실 없음.
3. **미커밋 변경 확인**: 전환 전 미커밋 변경이 있으면 `git status` / `git stash list`로 확인한다. 미커밋 변경이 있으면 `git switch`가 거부할 수 있으니 먼저 commit하거나 stash한다.
4. **복구**: `git switch <fr-branch>` — 워킹트리를 원래 fr branch로 되돌린다. stash했다면 복귀 후 `git stash pop`으로 복원한다.

대부분의 경우 모든 작업이 commit돼 있어 `git switch`만으로 손실 없이 복구된다.

## 4. 적용 대상 (본 repo 통제 dispatch 지점)

아래 dispatch 지점은 subagent dispatch 시 1번의 Subagent Git 안전 문구를 dispatch prompt에 포함한다. 각 dispatch 지점은 1-2 의 진행 기록 문구도 포함한다.

- `.claude/rules/rd-workflow/core.md` 실행 모드 규칙 (subagent-driven-development 기본 dispatch)
- `rd-workflow/claude_skills/autopilot/SKILL.md` (§4 자율 구현)

외부 superpowers skill(`subagent-driven-development`, `using-git-worktrees`)은 본 repo에서 직접 수정할 수 없으므로, 위 통제 지점에서 dispatch prompt에 1번 문구를 주입하는 방식으로 우회한다.

## phase 병렬 dispatch

phase 병렬 실행(`plan-parallel-phases.md`)에서 여러 구현자 subagent를 동시에 dispatch할 때:

- 각 구현자는 자기 task의 **disjoint 파일만 Edit/Write**한다. git 조작(commit 포함)을 하지 않는다 — 동시 커밋은 index 경합을 일으킨다.
- 커밋은 barrier 후 **orchestrator(실행 세션 본체)가 일괄** 수행한다.
- 위 git 안전 문구(브랜치 전환 금지 + 공유 진행 상태 수정 금지)는 병렬 구현자 각각의 dispatch prompt에도 동일하게 포함한다.
