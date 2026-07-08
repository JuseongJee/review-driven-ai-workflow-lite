# lifecycle 스크립트

## 개요

fr-branch-tag-lifecycle FR로 도입된 lifecycle 스크립트 모음.
FR 작업의 git 라이프사이클 — branch 생성 → 작업 → main merge → tag → branch 삭제 — 을 자동화한다.

자세한 정책은
`rd-workflow-workspace/specs/changes/2026-04-28-0900-fr-branch-tag-lifecycle-change-spec.md` 참조.

---

## 스크립트 목록

### `slug.sh`

- `normalize_slug <input>` — 슬러그 정규화 (lowercase 영숫자 + `-`, 비-ASCII 거부, 1–60자)
- 다른 스크립트에서 source 해서 사용

### `_lifecycle_common.sh`

공통 함수 (source-only):

| 함수 | 설명 |
|------|------|
| `detect_remote_mode` | `remote` / `local-only` 판정 (`RD_LIFECYCLE_NO_REMOTE` env로 강제 가능) |
| `ensure_worktree_clean` | 현재 worktree dirty 여부 (return 0/1) |
| `resolve_unique_ref <branch\|tag> <base>` | 충돌 시 `-N` suffix 자동 부여 |
| `get_main_worktree_path` | main worktree 절대 경로 (없으면 return 1) |
| `metadata_read_field` | `task-state` 파일(`TASK_STATE_PATH`) 필드 읽기 |
| `metadata_write` | `task-state` 파일 필드 쓰기 |
| `metadata_clear` | `task-state` fr 필드 reset (`fr-branch=null` 등 sentinel 복원 — 파일 삭제 아님) |
| `metadata_exists` | `task-state` 파일 존재 여부 |
| `emit_current_task_baseline` | 빈 CURRENT_TASK.md 형태 출력 (heredoc) |

### `promote.sh`

REQUEST 승격 시 호출. fr branch 생성 + checkout(또는 worktree) + task-state fr 필드 기록 + CURRENT_TASK.md 갱신.

**용법:**

```bash
bash rd-workflow/scripts/lifecycle/promote.sh \
  [--short-title <slug>] \
  [--worktree-path <path>] \
  [--no-worktree] \
  [--status <text>] \
  [--dry-run]
```

**호출 시점:** FR 등록 main commit **직후**. 호출 위치는 main worktree.

### `archive.sh`

작업 완료 + final-diff-review 통과 후 archive 단계에서 호출.
main에 `--no-ff` merge → task-state cleanup commit(fr 필드 sentinel 복원) → tag(`fr/{YYYY-MM-DD-HHMM}/{slug}`) → push → branch / worktree 정리.

**용법:**

```bash
bash rd-workflow/scripts/lifecycle/archive.sh \
  [--fr-branch fr/<ref>] \
  [--no-remote] \
  [--force-dirty] \
  [--dry-run]
```

**호출 위치:** main worktree only.
호출 전에 fr branch에서 archive content commit
(REQUEST.md 비우기, archive 파일, FR done, CURRENT_TASK.md reset 등) 완료해야 함.

### `promote_rollback.sh`

승격 후 작업을 abandon하고 fr branch를 폐기할 때 호출.
branch + worktree 강제 삭제 + task-state fr 필드 reset + CURRENT_TASK.md baseline reset.

**용법:**

```bash
bash rd-workflow/scripts/lifecycle/promote_rollback.sh \
  [--fr-branch fr/<ref>] \
  [--dry-run]
```

**호출 위치:** main worktree only.

---

## Idempotency 보증

모든 entrypoint는 동일 인자로 재실행해도 안전하다.

- **`promote.sh`**: task-state 확인 → 동일 short-title이면 남은 step만 수행. 다른 fr 진행 중이면 hard error.
- **`archive.sh`**: 각 step idempotent. merge / tag / branch 삭제 / push 모두 git이 up-to-date 판정.
  task-state cleanup 후 publish 실패 시 재실행으로 publish 재시도.
  fr branch 부재 + 동일 slug tag 존재 시 "이미 archive 완료" success exit.
- **`promote_rollback.sh`**: branch 부재 시 skip. task-state 부재 시 `--fr-branch` 명시 필수.
  이미 archive된 fr (tag 존재)은 hard error.

---

## Env vars

| 변수 | 설명 |
|------|------|
| `RD_LIFECYCLE_BYPASS_REASON=<reason>` | `fr_branch_gate.sh` hook 우회용. command string에 노출되어 hook이 grep 검출. valid reason: `bootstrap` / `lifecycle` / `small-task` / `legacy` |
| `RD_LIFECYCLE_NO_REMOTE=1` | `detect_remote_mode`를 강제로 `local-only`로 판정 |
| `TASK_STATE_PATH` | task-state 파일 경로 override (기본 `rd-workflow-workspace/.lifecycle/task-state`) |

---

## 부분 실패 복구

### `promote.sh` partial 실패

동일 명령 재실행. task-state가 source-of-truth.

### `archive.sh` partial 실패

- merge 후 publish 실패: fr branch 보존됨.
  `git push origin main` 수동 재실행 또는 `archive.sh --fr-branch fr/<ref>` 재실행.
- tag 부착 후 push 실패: 동일.

### `promote_rollback.sh`

destructive — 재실행 안전망 없음. 조심해서 호출.

---

## 검증

```bash
bash _ROOT_FILES/rd-workflow/scripts/lifecycle/test_lifecycle.sh
```

현재 18 case (slug 정규화 11 + lifecycle helpers 7).
Task 12에서 통합 테스트(`test_integration.sh`) 추가 예정.

---

## 참조

- spec: `rd-workflow-workspace/specs/changes/2026-04-28-0900-fr-branch-tag-lifecycle-change-spec.md`
- plan: `rd-workflow-workspace/plans/2026-04-28-0930-fr-branch-tag-lifecycle-plan.md`
- canonical owner: `rd-workflow/docs/AGENTS.md` (Task 9에서 갱신 예정)
