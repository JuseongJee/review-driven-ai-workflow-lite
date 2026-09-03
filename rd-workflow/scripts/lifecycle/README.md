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
| `get_main_worktree_path` | 기본 브랜치 worktree 절대 경로 (없으면 return 1) |
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
  (--size large|small | --status <canonical>) \
  [--worktree-path <path>] \
  [--no-worktree] \
  [--source-fr <path|->] \
  [--dry-run]
```

**호출 시점:** FR 등록 기본 브랜치 commit **직후**. 호출 위치는 기본 브랜치 worktree.

**시작 상태:** `--size` 로 지정하며 기본값은 없다.
- 큰 작업 → `--size large` (`대기 중`). 다음 단계 `REQUEST review 대기` 로 `--force` 없이 전이한다.
- 작은 작업 → `--size small` (`구현 중`).
- `--status <canonical>` 은 복구·마이그레이션 전용이며 `--size` 와 함께 쓸 수 없다.

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

**호출 위치:** 기본 브랜치 worktree only.
호출 전에 fr branch에서 archive content commit
(REQUEST.md 비우기, archive 파일, FR done 등) 완료해야 함.
CURRENT_TASK.md 미러는 archive.sh 가 baseline 으로 되돌리므로 호출 전 준비 대상이 아님.

#### 종료 코드 계약

| 종료 코드 | 의미 |
|-----------|------|
| `0` | core archive 성공. post-success cleanup 잔여가 있을 수 있으며, 있으면 stdout `archive: CLEANUP-PENDING` 요약 블록으로 알린다 |
| non-zero | core 단계 실패 또는 안전 불변식 위반 |

core 실패는 **원 명령의 종료 상태를 그대로 전달한다** — `set -e` 가 전파하는 경우와 명시적 guard 가 잡는 경우 모두 해당한다. guard 에서 실패를 잡을 때도 `rc=$?` 를 즉시 캡처해 그 값으로 종료하며, 특정 값으로 정규화하지 않는다.

예외는 **이 변경 이전부터 존재하던 precheck guard 들**이다 (기본 브랜치 worktree 검증·clean state·fr ref 형식·override 불일치·fetch preflight 등). 이들은 종전 동작을 유지하기 위해 `exit 1` 을 그대로 둔다. 새로 추가되는 core 경로는 원 상태 전달 규칙을 따른다.

#### 단계별 blocking 분류

| 계층 | 단계 | 실패 시 |
|------|------|---------|
| **core** | 기본 브랜치·clean state precheck · review precheck · merge · metadata cleanup commit · tag · push | 즉시 non-zero 중단 |
| **post-success cleanup** | worktree teardown(Step 7) · 로컬 브랜치(Step 8) · 원격 브랜치(Step 9) · loop-state 정리 | 다음 단계 계속, 잔여 기록, `0` 유지 |
| **safety invariant** | ref 삭제 판정 위반 (아래) | 미삭제 ref 보존 · 뒤따르는 ref 삭제 스킵 · 비파괴 cleanup 계속 · non-zero |

**안전 불변식 위반 조건** (고정 개수로 표현하지 않는다 — 조건은 추가될 수 있다):

- `merge-base --is-ancestor` 가 거짓 — 진짜 미머지
- 로컬 ref 판정 명령이 비정상 종료하거나 출력이 malformed
- ref 가 존재하는데 expected-old 삭제가 거부됨 — tip 이동
- 원격 ref 조회·파싱 실패
- 원격 tip 이 base 의 ancestor 아님, 또는 원격 tip 객체가 로컬에 없어 판정 불능
- `--force-with-lease` 미지원·버전 판정 불능으로 보호된 삭제 불가
- lease 거부 또는 원격 삭제 push 실패
- **worktree 등록 조회 실패 — 로컬 ref 삭제의 선행 조건을 판정할 수 없음**

worktree **제거 실패**나 **등록 잔존**(locked·prune 만료 등)은 이 목록에 포함되지 않는다. 로컬 브랜치 삭제만 건너뛰는 일반 cleanup 실패이며 `0` 을 유지한다.

#### 브랜치 삭제 판정

- 로컬: `git for-each-ref` 로 tip 을 읽어 **존재 / 정상 부재 / 조회·파싱 실패** 3분류하고, `git merge-base --is-ancestor <fr-tip> <merge 대상 base>` 가 참일 때만 `git update-ref -d refs/heads/<fr> <검증한-tip>` 으로 삭제한다. 종료 상태 하나로 부재와 오류를 뭉뚱그리지 않는다.
- 원격: `git ls-remote` 로 tip 을 고정해 동일하게 3분류하고, ancestor 확인 후 `git push --force-with-lease=refs/heads/<fr>:<고정한-tip> origin :refs/heads/<fr>` 로 삭제한다.
- **순서 불변식**: 판정 base 는 **merge 완료 직후**에 캡처한 commit(`MERGE_BASE_COMMIT`)이다. Step 4 의 metadata cleanup commit 이 HEAD 를 전진시키므로 Step 8 시점의 HEAD 를 base 로 쓰면 안 된다.
- **worktree 선행 조건**: `git update-ref -d` 는 `git branch -d` 와 달리 "다른 worktree 가 체크아웃 중인 브랜치" 보호가 없어, ref 를 지우면 그 worktree 가 broken HEAD 가 된다. 따라서 삭제 허용은 다음 한 문장으로 고정한다 — **정리를 마친 뒤 다시 조회했을 때 해당 브랜치를 체크아웃한 worktree 등록이 0건일 때만 로컬 ref 를 삭제한다.**
  - 제거 명령이나 `git worktree prune` 의 종료 코드를 정리 완료의 근거로 삼지 않는다. locked worktree 의 경로가 사라진 경우와 prune 만료 미도달 경우는 **exit 0 인데 등록이 남는다**.
  - 세 층위가 각각 **다른 위험**을 막는다.

    | 층위 | 수단 | 보장 대상 |
    |------|------|-----------|
    | (a) 대상 존재 판정 | `branch refs/heads/<fr>` **라인 개수** | 경로 특수문자(개행 포함)와 무관하게 대상 유무를 정확히 판정 — ref 이름에는 개행이 들어갈 수 없다 |
    | (b) 소유권 검증 | 제거 직전 `rev-parse --show-toplevel` 일치 + `symbolic-ref HEAD` 일치 | **제거 대상의 정확성** — 잘린 경로가 다른 브랜치의 worktree 를 가리켜도 그것을 제거하지 않는다 |
    | (d) 최종 재조회 | 정리 후 (a) 재실행 | **대상 로컬 ref 의 미삭제** (fail-closed) |

  - (d) 만으로는 부족하다. 재조회는 대상 ref 가 지워지지 않게 할 뿐, 잘린 경로로 **이미 제거해 버린 다른 worktree** 는 되돌리지 못한다. 그래서 (b) 가 별도로 필요하다.
  - 목록은 `while ... done < <(...)` 의 process substitution 안에서 조회하지 않는다. 그 형태는 조회 실패를 바깥 루프에 전달하지 않아 "실패" 와 "대상 0건" 이 구분되지 않는다.
  - `--porcelain -z` (NUL-safe)는 git 2.36+ 를 요구해 사실상 하한 2.23 과 충돌한다. 도입하지 않는 이유는 "재조회만으로 충분해서" 가 아니라 **(b) 소유권 검증이 버전 의존 없이 오대상 제거를 막고 (d) 가 대상 ref 를 지키기 때문**이다. `-z` 를 쓰면 2.23–2.35 사용자는 개행 경로가 없는 정상 상황에서도 자동 정리를 잃는다.

#### 정리 잔여 요약 블록

정리 미완 항목이 있으면 종료 직전 stdout 에 `archive: CLEANUP-PENDING` 마커로 시작하는 블록을 출력한다. 항목마다 `사유:` 와 `복구:` 두 줄이 따르며, **`복구:` 는 그대로 복사해 실행할 수 있는 셸 한 줄**이다. 복구 명령의 기본값은 상태 확인 같은 **비파괴 명령**이며, `git worktree remove --force` 나 `git branch -D` 처럼 데이터를 잃을 수 있는 명령은 기본값으로 제시하지 않고 필요 조건과 손실 범위를 `사유:` 에 적는다. 내부 레코드는 `<kind>\t<identifier>\t<reason>\t<command>` 4필드이고, `identifier` 는 `printf '%q'` 로 인코딩해 저장한다 (경로에 따옴표·TAB·개행이 있어도 레코드와 복사 실행이 깨지지 않게 하기 위함).

#### 보존 계약의 범위

"보존" 은 **아직 삭제하지 않았거나 이동이 감지된 ref** 에만 적용된다. 순차 삭제 도중 앞선 ref 가 검증을 통과해 삭제된 뒤 뒤쪽에서 위반이 감지되면 **이미 삭제된 ref 는 복구하지 않는다**. 검증 통과는 그 ref 의 모든 커밋이 merge 대상 base 에 포함됨을 뜻하므로 커밋 손실이 없기 때문이다. 보상 복구(compensating restore)는 구현하지 않는다. 종료 메시지도 이 범위를 그대로 표현한다 — "모든 ref 를 보존했다" 가 아니라 "아직 삭제하지 않은 ref 를 보존했다" 이다.

#### git 버전

lifecycle 스크립트 전체에 명문화된 git 최소 버전 정책은 없다. 다만 기존 코드가 `git switch`(2.23 도입)와 `git worktree`(2.5 도입)를 이미 사용하므로 **사실상 하한은 2.23** 이다.

원격 브랜치 삭제 경로는 추가로 `--force-with-lease`(1.8.5 도입)를 요구한다. **이 1.8.5 는 해당 경로의 기능 하한일 뿐 프로젝트 전체 하한이 아니다.** 실행 전에 `git --version` 을 파싱해 하한 미만이거나 버전 판정이 불가능하면 원격 삭제를 **시도하지 않고** 안전 불변식 위반으로 처리한다. 어느 경우에도 무보호 삭제로 fallback 하지 않는다.

### `promote_rollback.sh`

승격 후 작업을 abandon하고 fr branch를 폐기할 때 호출.
branch + worktree 강제 삭제 + task-state fr 필드 reset + CURRENT_TASK.md baseline reset.

**용법:**

```bash
bash rd-workflow/scripts/lifecycle/promote_rollback.sh \
  [--fr-branch fr/<ref>] \
  [--dry-run]
```

**호출 위치:** 기본 브랜치 worktree only.

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
| `RD_LIFECYCLE_BYPASS_REASON=<reason>` | 과거 `fr_branch_gate.sh` hook 우회용이었습니다. 그 hook 은 제거됐고 템플릿에는 이 값을 읽는 곳이 없습니다. 아직 동기화하지 않은 소비 프로젝트에 hook 이 남아 있을 수 있어 lifecycle 스크립트는 접두를 그대로 유지합니다. valid reason: `bootstrap` / `lifecycle` / `small-task` / `legacy` |
| `RD_LIFECYCLE_NO_REMOTE=1` | `detect_remote_mode`를 강제로 `local-only`로 판정 |
| `TASK_STATE_PATH` | task-state 파일 경로 override (기본 `rd-workflow-workspace/.lifecycle/task-state`) |

---

## pre-commit·commit-msg hook 우회

기본 브랜치를 대상으로 하는 lifecycle 커밋 3곳 — `promote` 의 metadata 기록,
`promote_rollback` 의 완료 기록, `archive` 의 metadata 정리 — 은 **현재 브랜치명이
`main` 또는 `master` 일 때만** `git commit --no-verify` 로 실행됩니다.

**이유:** Claude Code 가 설치하는 `.git/hooks/pre-commit` 은 `main`/`master` 직접 커밋을
무조건 차단하며 `--no-verify` 로만 우회를 허용합니다. 이 hook 은 브랜치명만 검사하고
`RD_LIFECYCLE_BYPASS_REASON` 을 참조하지 않으므로, 이 플래그가 없으면 lifecycle 이 커밋
단계에서 멈추고 사람이 hook 을 임시로 꺼야 합니다.

**조건부인 이유:** `workflow.json` 의 `default_branch` 로 `trunk` 같은 커스텀 기본 브랜치를
쓰는 프로젝트에서는 이 hook 이 애초에 커밋을 막지 않습니다. 그런 브랜치에까지 `--no-verify`
를 붙이면 필요 없이 소비 프로젝트의 `pre-commit`·`commit-msg` 검증만 건너뛰게 되므로,
차단 대상 브랜치에서만 붙입니다. 우회 안내 메시지도 실제로 우회한 실행에서만 출력됩니다.
반면 `RD_LIFECYCLE_BYPASS_REASON=lifecycle` 은 별개 hook 계층(제거된 `fr_branch_gate.sh`,
또는 아직 동기화하지 않은 소비 프로젝트에 남은 그 사본)을 상대하므로 브랜치와 무관하게
세 지점 모두에서 항상 유지됩니다.

**건너뛰는 범위:** `--no-verify` 는 `pre-commit` 과 `commit-msg` 두 hook 을 모두 건너뜁니다.
즉 프로젝트 자체의 lint·포맷 검사뿐 아니라 **커밋 메시지 정책 검사도 실행되지 않습니다.**
lifecycle 커밋 메시지는 스크립트가 `chore(lifecycle): …` 고정 형식으로 생성하므로 규약 위반
가능성은 낮지만, 프로젝트 규약이 그 형식과 다르면 검출되지 않습니다. 각 실행 시 이 사실이
안내 메시지로 출력됩니다.

**적용 범위:** 위 3곳뿐입니다. `promote` 의 fr 브랜치 승격 커밋은 fr 브랜치에서 실행되어
차단 대상이 아니므로 `--no-verify` 를 붙이지 않습니다.

**staged 보존:** lifecycle 이 만드는 커밋은 모두 경로를 한정해(`git commit … -- <paths>`)
실행되므로, 사용자가 미리 stage 해 둔 무관한 변경은 그 커밋에 포함되지 않고 index 에 그대로
남습니다. `promote` 의 fr 브랜치 승격 커밋(`chore(lifecycle): … fr 브랜치 승격 — CURRENT_TASK
갱신`)도 `CURRENT_TASK.md` 로 한정되므로, `promote` 는 실행 전 구간에서 무관한 staged 를
보존합니다.

단 `archive` 는 **merge 를 실제로 수행하는 경로**에서 사전에 worktree clean 상태를
요구해(`--force-dirty` 없으면 Step 0, 붙여도 뒤따르는 `git merge --no-ff` 에서) 무관한 staged
가 있으면 metadata 커밋 자체에 도달하지 못하고 중단됩니다 — `promote`/`promote_rollback` 처럼
커밋을 완주하면서 무관 파일만 제외하는 것과는 다릅니다. 반면 **이미 merge 된 fr 을 archive 하는
경우**(재실행, 또는 사람이 먼저 수동 merge 한 경우)에는 merge 단계를 건너뛰므로 다른 두
스크립트와 똑같이 동작합니다 — 커밋을 완주하면서 무관한 staged 는 경로 한정으로 제외되고 index
에 그대로 남습니다.

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
bash _ROOT_FILES/rd-workflow/scripts/lifecycle/test_lifecycle.sh    # 헬퍼 함수 단위 테스트
bash _ROOT_FILES/rd-workflow/scripts/lifecycle/test_integration.sh  # temp repo 기반 git state 전이 테스트
```

두 스크립트 모두 `bash rd-workflow/scripts/self_test.sh` 가 함께 실행한다.
`archive.sh` 를 프로세스로 실행하는 시나리오(브랜치 정리·cleanup 잔여·안전 불변식)는 `test_integration.sh` 소관이다.

---

## 참조

- spec: `rd-workflow-workspace/specs/changes/2026-04-28-0900-fr-branch-tag-lifecycle-change-spec.md`
- plan: `rd-workflow-workspace/plans/2026-04-28-0930-fr-branch-tag-lifecycle-plan.md`
- canonical owner: `rd-workflow/docs/AGENTS.md` (Task 9에서 갱신 예정)
