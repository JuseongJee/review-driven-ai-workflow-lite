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
| `metadata_clear` | `task-state` fr 필드 reset (`fr-branch=null` 등 sentinel 복원 — 파일 삭제 아님). 되돌리는 필드는 `fr-branch`·`worktree-path`·`source-fr`·`base-commit`·`review-session` 이고 `created-at` 은 제거한다 |
| `metadata_exists` | `task-state` 파일 존재 여부 |
| `emit_current_task_baseline` | 빈 CURRENT_TASK.md 형태 출력 (heredoc) |
| `registration_commit_shape <commit>` | FR 등록 커밋 형태 검증 — 통과 시 slug 출력 (helper 자기 검증·시작 계약 공용) |
| `index_row_ncol` | stdin 한 줄의 인덱스 표 컬럼 수 (이스케이프되지 않은 `|` 기준 — `merge_fr_index.sh` 의 `xsplit()` 과 같은 계약) |
| `classify_ahead_commits <local> <upstream>` | 시작 계약 4항 분류 — `ahead= behind= registration= decision=` |

### `start_preflight.sh`

작업 시작 계약(WORKFLOW.md 4항) 진입점. 비변경(fetch 외 상태 변경 없음).

**용법:**

```bash
bash rd-workflow/scripts/lifecycle/start_preflight.sh [--no-fetch]
```

**절차:**

1. `default`·remote 모드 판정(`detect_remote_mode`). 원격 모드면 `git fetch <remote-of-upstream>`(실패 → `fetch=failed`, 이후 분류는 현존 refs 로 계속하되 decision 은 `handover-fetch-failed`).
2. `classify_ahead_commits refs/heads/$default <upstream>`.
3. `fr_backlog_scan.sh` 실행 (rc 3 → `검사 실패 — 사유`).
4. 출력:
   ```
   preflight: default=<b> mode=<remote|local-only> fetch=<ok|skipped|failed> ahead=<N> behind=<K> registration=<M> decision=<...>
   push 예정: <문구>
   미병합 브랜치 FR 후보: <없음 | N건 — <ref> …| 검사 실패 — 사유>
   ```

`push 예정` 문구 규칙: local-only → `없음` / synchronized → `archive.sh 경유` / auto-adopt → `archive.sh 경유(기본 브랜치 미push N개 — 전부 FR 등록 커밋, 자동 채택)` / handover-* → `인계(사유: …)`.

**종료 코드:** `0` 진행 가능(synchronized·auto-adopt·local-only) / `10` 인계 / `3` 판정 불능. `light` 는 exit 10 이어도 작업을 진행하되 push 를 보류하는 종전 규칙을 따른다 (WORKFLOW.md 가 규정).

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
- `full` 등급(큰 작업) → `--size large` (`대기 중`). 다음 단계 `REQUEST review 대기` 로 `--force` 없이 전이한다.
- `standard` 등급(작은 작업) → `--size small` (`구현 중`) (`light` 는 promote 를 타지 않음).
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
  [--force-skip-review-check <사유>] \
  [--allow-status-mismatch <사유>] \
  [--dry-run]
```

**Status 검사:** 발행 대상 커밋(fr 모드는 fr tip, no-fr 은 HEAD)의 task-state `status` 가 `아카이브 보류` 가 아니면 seal 검사보다 먼저 거부합니다(merge·push 전). `--allow-status-mismatch <사유>` 는 이 검사만 건너뛰며 사유가 필수이고 audit 로그에 `[status:<값>]` 로 남습니다. `--force-skip-review-check` 와 서로를 우회하지 않습니다.

**락 대기:** 점유자가 `tasks-list-prune`(`rd task list` 의 지연 정리)이면 `RD_ARCHIVE_LOCK_WAIT_MAX` 초(기본 60, `0` 이면 대기 안 함) 안에서 기다립니다. 다른 점유자는 즉시 중단합니다.

**submodule gitlink 검사:** 병합 전과 병합 뒤에 `archive_gitlink_merge_check` 가 병합 커밋이 submodule 커밋을 빠뜨렸는지 봅니다. 병합이 한쪽 gitlink 만 골랐고 그 뒤 커밋도 빠진 커밋을 담지 않으면 `exit 1` 로 멈춥니다(`--dry-run` 은 검사하지 않습니다). 판정에 필요한 객체가 없으면 submodule 경로마다 한 번 `git fetch` 하며, 그래도 없으면 판정 불가로 멈춥니다. submodule 저장소가 squash·rebase 로 병합하면 내용이 이미 들어 있어도 막힙니다. 확인한 뒤 `--allow-gitlink-drop <사유>` 로 이 검사만 건너뛸 수 있고, 사유는 audit 로그에 `[gitlink:rc<1|2>]` 로 남습니다. 발행 큐(`rd publish run`)는 이 옵션을 넘기지 않으므로 `archive.sh` 를 직접 부릅니다.

**점유 검사:** Step 7 이 작업 worktree 를 지우기 전에 `tasks_path_occupied` 로 그 안에 작업 디렉터리를 둔 내 계정 프로세스(세션)가 있는지 봅니다. 점유이거나 판정 불가이면 지우지 않고 정리 잔여 `worktree` 로 기록하며(로컬 브랜치도 남음), 세션이 끝난 뒤 기본 체크아웃의 `rd task list` 가 지연 정리합니다. 복구 명령은 `cd <기본 체크아웃> && bash rd-workflow/scripts/rd task list` 입니다.

**호출 위치:** 작업 worktree 에서 부르면 기본 체크아웃에서 다시 실행합니다(호출자 worktree·로컬 브랜치는 정리 대기). 기본 체크아웃에서 `--task <slug>` 로 불러도 됩니다.
호출 전에 archive content commit
(REQUEST.md 비우기, archive 파일, FR done 등) 완료해야 함 — fr 모드는 fr branch 에서, no-fr 모드는 기본 브랜치에서 커밋한다.
CURRENT_TASK.md 미러는 archive.sh 가 baseline 으로 되돌리므로 호출 전 준비 대상이 아님.
**이 미러 복원은 두 모드 모두에서 일어난다** — Step 4 의 조건이 `metadata_exists || BRANCH_MODE == no-fr` 이라,
fr 필드가 sentinel 인 no-fr 작업도 status·short-title·base-commit·review-session·`CURRENT_TASK.md` 를 함께 baseline 으로 되돌린다.

Step 3 merge 가 `FUTURE_REQUESTS.md` 단독 충돌로 실패하면 `merge_fr_index.sh` 로 해결한다 (fr 모드 전용 — no-fr 은 merge 자체를 건너뛴다).

#### 기록/발행 간격 (change-spec §4.2·§4.5)

final diff review 종결과 발행 사이에 `아카이브 보류` 상태가 들어간다. **아래 순서가 계약이다.**

| # | 행위 | 비고 |
|---|------|------|
| 1 | final diff review 가 `이의 없음` 으로 종결 | — |
| 2 | `bash rd-workflow/scripts/rd review seal <세션 경로>` | 종결 마커(`rd-workflow-workspace/.lifecycle/review-seals/<session-id>.seal`) 생성 — 워킹트리 |
| 3 | `bash rd-workflow/scripts/rd task set-status "아카이브 보류"` | task-state 파일 쓰기 (커밋 불필요 — 게이트가 워킹트리를 읽는다) |
| 4 | seal 파일 + archive content commit | `pre_commit_archive_gate.sh` 가 「보류 상태 + 변경이 전부 기록 경로 안」이면 통과시킨다 |
| 5 | `bash rd-workflow/scripts/lifecycle/archive.sh` | `archive_review_precheck` 가 마커를 strict 검증한 뒤 발행 |

- **마커는 커밋되어야 효력이 생긴다.** precheck 는 워킹트리가 아니라 **판정 대상 commit**(fr 모드=fr tip, no-fr 모드=현재 `HEAD`)에서 마커·`review-session` 포인터·보호 트리 해시를 읽는다 (§3.3.1). 4번이 그래서 5번보다 앞에 있다.
- 2·3번을 마친 직후 곧바로 5번을 부르는 **연속 실행은 종전과 동일하다.** `archive.sh` 의 호출 형태·인자·내부 순서는 이번 변경으로 바뀌지 않았다 (one-shot 보존).
- 지금 무엇을 해야 하는지는 `bash rd-workflow/scripts/rd task status` 가 안내한다 — 판정 대상 commit 의 seal 이 유효하면 `발행`, 워킹트리 seal 만 유효하면 `seal 과 archive 기록을 커밋하세요`, 둘 다 아니면 실패 사유별 복구 안내를 낸다.
- 리뷰 종결 뒤 보호 경로(코드·spec·plan 등 기록 경로 밖)를 고치면 seal 과 precheck 가 모두 막는다. 재리뷰 후 `rd review seal` 을 다시 실행하면 마커가 교체된다(4검사를 전부 통과할 때만 — 실패하면 기존 마커를 보존한다).

#### no-fr 모드 — fr 브랜치 없이 기본 브랜치에서 작업한 경우 (change-spec §5.1)

**진입 조건은 task-state 의 `fr-branch` 가 canonical `null` 일 때뿐이다.** 빈 문자열·공백·`main` 같은 그 밖의 값은
no-fr 이 아니라 **malformed 로 차단**한다 — 필드가 유실된 파손 상태를 사용자가 명시한 no-fr 과 구분하지 못하면
파손된 task-state 가 조용히 발행으로 흘러가기 때문이다. 판정은 `rd_branch_mode`(`_state_common.sh`) 한 곳에서만 한다.

**실행 브랜치 안전 조건** — no-fr 은 metadata cleanup commit·tag·push 를 **현재 checkout** 에 그대로 수행하므로,
"어디에서 실행했는가" 가 곧 "무엇이 발행되는가" 이다. 그래서 Step 0 앞의 읽기 전용 사전 검증에서 다음을 확인하고 실패하면 중단한다.

| 상황 | 메시지 |
|------|--------|
| detached HEAD | `archive: detached HEAD 에서는 no-fr archive 를 할 수 없습니다 — 기본 브랜치로 전환 후 재실행하세요.` |
| 기본 브랜치가 아닌 브랜치 | `archive: no-fr 모드는 기본 브랜치(<X>)에서만 호출 가능합니다 — 현재: <Y>. git switch <X> 후 재실행하세요.` |

**건너뛰는 것:** Step 3 merge, fr 로컬·원격 브랜치 삭제, worktree 정리, `--fr-branch` override 검사,
Step 3.6 의 기준선 기반 얹힌 커밋 검사(기준선이 되는 merge 커밋이 없다 — 리뷰 대상 동일성은 seal 의 보호 트리 해시 비교가 보증한다),
그리고 「fr 브랜치 부재 + 동일 slug tag 존재 = 이미 완료」 재실행 안전망(no-fr 은 조건이 항상 참이라 오판한다 — 멱등성은 Step 5 의 `--points-at` tag 재사용이 담당한다).

**유지되는 것:** Step 0 의 기본 브랜치 worktree·clean state 검사, `archive_review_precheck`, metadata cleanup commit,
tag, push. tag 이름은 fr 모드와 같은 `fr/<YYYY-MM-DD-HHMM>/<slug>` 형식이고 slug 는 task-state `short-title` 을
`normalize_slug` 로 정규화해 만든다 — baseline(`-`)이나 빈 short-title 은 거부되므로, 먼저
`bash rd-workflow/scripts/rd task set-title <제목>` 을 실행해야 한다. push 는 `REMOTE_MODE` 계약 그대로여서
`local-only`·`--no-remote` 면 tag 가 로컬에만 남는다.

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

#### 정리 잔여 기록

`archive.sh` 는 종료 직전 정리 잔여를 파일로도 남긴다. stdout 블록은 그 실행에서만 보이므로, 무인 소비처(autopilot 보고서·`ralph_drain.sh` 요약·`/fr batch` 최종 요약)가 읽을 수 있게 하기 위해서다. 읽고 쓰는 명령은 `cleanup_pending.sh` 가 맡는다.

- **위치**: `<git-common-dir>/rd-workflow/archive-cleanup-pending/<slug>`. git 추적 밖이므로 `.gitignore` 도 마이그레이션도 필요 없고, worktree 가 지워져도 남는다.
- **항목 단위**: 파일은 잔여 항목 줄만 담는다. 한 줄이 위 요약 블록의 내부 레코드 하나(4필드, TAB 구분, identifier 는 `%q` 인코딩 그대로)이고, 잔여 항목 1건이 1줄이다.
- **소유권**: `archive.sh` 실행은 자기 slug 파일만 쓰거나 지운다. 잔여가 있으면 `write`, 없으면 `clear` 를 부른다. 다른 slug 의 파일과 시간 경과는 보지 않는다.
- **원자성**: 같은 디렉터리의 임시 파일(`.<slug>.tmp.<pid>`)에 쓴 뒤 `mv` 로 교체한다. 실행은 직렬이어야 한다. `archive.sh` 가 기본 브랜치 락 안에서 돌기 때문에 성립하는 전제이고, 이 파일을 쓰는 다른 경로를 락 밖에 두지 않는다.
- **해제 경로**
  - ① 지연 정리: 기본 체크아웃의 `rd task list` 가 정리를 끝내고 색인 행을 지우면 `resolve <slug> worktree local-branch` 로 그 kind 항목을 뺀다. 남은 항목이 없으면 파일째 지운다. 해제에 실패하면 stderr 에 경고만 내고 stdout·종료 코드는 바꾸지 않는다.
  - ② 다음 `archive.sh` 실행: 같은 slug 의 잔여가 없으면 `clear` 가 파일을 지운다.
  - 수동 해제: 직접 정리를 마친 뒤 `bash rd-workflow/scripts/lifecycle/cleanup_pending.sh clear <slug>`.
- **조회**: `bash rd-workflow/scripts/lifecycle/cleanup_pending.sh show <slug>` 는 사람이 읽는 형식으로, `summary` 는 `<slug><TAB><항목 수>` 줄로 낸다. 기록이 없으면 `show` 는 `없음` 을 낸다. 조회 자체가 실패하면 rc 2 와 stderr `cleanup_pending: 조회 실패 — <사유>` 를 내며 `없음` 을 내지 않는다.
- **기록 실패 종료 계약**: `write`·`clear` 가 실패하면 stderr 에 `archive: CLEANUP-RECORD-FAILED <write|clear> <사유>` 줄을 낸다. stdout 요약 블록과 `archive: core 완료` / `archive: 완료. tag=` 줄은 그대로 낸다. 안전 불변식 위반이 있으면 그 처리(exit 1)가 먼저이고, 위반이 없으면 기록 실패로 exit 1 한다. 발행(merge·tag·push)은 이미 끝났으므로 되돌리지 않는다. 호출자는 위 세 조건(표식 줄 + 완료 줄 + 위반 없음)을 「발행 완료 + 기록 실패」 로 읽는다.

#### 보존 계약의 범위

"보존" 은 **아직 삭제하지 않았거나 이동이 감지된 ref** 에만 적용된다. 순차 삭제 도중 앞선 ref 가 검증을 통과해 삭제된 뒤 뒤쪽에서 위반이 감지되면 **이미 삭제된 ref 는 복구하지 않는다**. 검증 통과는 그 ref 의 모든 커밋이 merge 대상 base 에 포함됨을 뜻하므로 커밋 손실이 없기 때문이다. 보상 복구(compensating restore)는 구현하지 않는다. 종료 메시지도 이 범위를 그대로 표현한다 — "모든 ref 를 보존했다" 가 아니라 "아직 삭제하지 않은 ref 를 보존했다" 이다.

#### git 버전

lifecycle 스크립트 전체에 명문화된 git 최소 버전 정책은 없다. 다만 기존 코드가 `git switch`(2.23 도입)와 `git worktree`(2.5 도입)를 이미 사용하므로 **사실상 하한은 2.23** 이다.

원격 브랜치 삭제 경로는 추가로 `--force-with-lease`(1.8.5 도입)를 요구한다. **이 1.8.5 는 해당 경로의 기능 하한일 뿐 프로젝트 전체 하한이 아니다.** 실행 전에 `git --version` 을 파싱해 하한 미만이거나 버전 판정이 불가능하면 원격 삭제를 **시도하지 않고** 안전 불변식 위반으로 처리한다. 어느 경우에도 무보호 삭제로 fallback 하지 않는다.

### `publish_queue.sh`

발행 요청 큐 (`rd publish <하위 명령>`). 저장소는 `<git-common-dir>/rd-workflow/publish-queue/` 이고 추적하지 않는다. 작업 세션은 `request`·`wait`·`run`, 호출 세션은 `watch`·`next`, 누구나 `status`·`cancel`·`recover` 를 쓴다. 허가 슬롯(`ACTIVE`)은 하나뿐이라 동시에 한 작업만 발행한다. 결과는 `tasks_publish_evidence` 로 판정한다(성공·부분 완료·실패). 설계: `rd-workflow-workspace/specs/changes/2026-11-04-0917-publish-queue-tab-close-change-spec.md`.

### `merge_fr_index.sh`

`FUTURE_REQUESTS.md` 행 집합 3-way 병합. `archive.sh` Step 3 merge 가 인덱스 단독 충돌로 실패했을 때 호출한다.

**용법:**

```bash
bash merge_fr_index.sh <base> <ours> <theirs>   # stdout = 병합 결과, exit 0 / 1(충돌)
```

- 파일 = 서문(`|` 로 시작하는 줄 없음) + 헤더 1줄 + 구분선 1줄(`|`·`-`·`:`·공백만, 헤더와 같은 컬럼 수) + 행들(헤더와 같은 컬럼 수, 제목 비어 있지 않고 고유) + 꼬리(빈 줄만). **세 입력 모두** 이 문법을 검증하고 하나라도 어긋나면 fail-closed(exit 1, stdout 없음) — archive 가 손상된 인덱스를 merge 커밋으로 확정하지 못하게 한다. 행 키 = 두 번째 컬럼(제목).
- 컬럼 분해는 GFM 과 같게 **이스케이프되지 않은 `|` 로만** 나눈다 — 셀 본문의 `\|` 는 코드 스팬 안이든 밖이든 구분자가 아니고, `\\|` 는 「본문 역슬래시 + 구분자」다. 이스케이프되지 않은 생 `|` 는 GFM 에서도 셀이 쪼개지는 깨진 행이므로 계속 거부하며, 이때 실패 메시지가 파일 역할·행 번호·실제/기대 컬럼 수와 **구분자로 센 `|` 를 `>|<` 로 표시한 행**을 함께 알린다(어느 `|` 가 본문 의도였는지는 도구가 알 수 없으므로 지목을 추측하지 않는다).
- 서문·헤더: ours==theirs → 그대로 / 한쪽==base → 다른 쪽 / 둘 다 다르면 exit 1.
- 행: 키별 (b,o,t) — o==t → o / o==b → t (theirs 의 추가·수정·삭제) / t==b → o / 그 외 exit 1. 부재는 "삭제" 값.
- 칸: 기존 행이 위 규칙으로 충돌하면 칸마다 같은 규칙을 다시 적용한다 — 한쪽은 우선순위만, 다른 쪽은 상태만 바꾼 행이 합쳐진다. 행 삭제 대 수정, 세 판 헤더 줄 불일치(열 이름·순서가 바뀌면 같은 위치의 칸이 다른 의미일 수 있음)는 칸 단위로 풀지 않고 `행 충돌(양쪽 상이 수정): <제목>` 으로 exit 1. 같은 칸을 양쪽이 다르게 바꾸면 `행 충돌(같은 칸을 양쪽이 다르게 수정): <제목> — 칸: <칸 이름>[, …]`(헤더 순서) 으로 exit 1.
- 순서: base 순서 유지 → ours 에만 새로 추가된 행(ours 순서) → theirs 에만 새로 추가된 행(theirs 순서).
- `archive.sh` Step 3: `git merge --no-ff …` 실패 시 `git diff --name-only --diff-filter=U` 가 정확히 인덱스 경로 하나이면 `git show :1:/:2:/:3:` 로 세 판을 뽑아 병합 → 성공 시 파일에 쓰고 `git add` → `git commit --no-edit -m "merge: <slug> (archive)"` (기존 hook bypass 규약 `lifecycle_needs_hook_bypass` 와 동일 처리) → `archive: FUTURE_REQUESTS.md 충돌을 행 집합 병합으로 해결` 알림. 병합 실패(충돌·malformed) 또는 다른 경로 충돌 → 종전 메시지·exit 1 (충돌 상태 유지). 자동 해결 뒤 커밋 실패 → `git status` 확인 → `git commit --no-edit` 재시도 또는 `git merge --abort` 를 안내(재실행만 안내하면 이미 resolve 된 상태에서 다시 실패한다).

### `fr-register` (rd task, scripts/_fr_register_common.sh)

`/fr add` 의 등록 결과(인덱스 행·`items/` 상세·선택 캡처)를 호출 브랜치와 무관하게 **기본 브랜치에 커밋**하는 helper. 본체는 `scripts/_fr_register_common.sh`(source 전용), 진입점은 `rd task fr-register`.

**용법:**

```bash
bash rd-workflow/scripts/rd task fr-register --slug <slug>
```

- stdout 첫 줄은 기계 판독 줄: `result=committed|already|skipped branch=<default> commit=<short-sha|-> reason=<token|->`
- 이어서 사람용 한 줄:
  - committed: `FR 등록 커밋: <default> <short-sha>`
  - already: `FR 등록 커밋: 이미 기본 브랜치에 있습니다 (<default>)`
  - skipped: `경고: 기본 브랜치 등록 커밋을 생략했습니다 — <사유>. 등록 파일은 현재 워킹트리에 있습니다. 복구: bash rd-workflow/scripts/rd task fr-register --slug <slug>`
- **종료 코드:** committed·already → `0`, skipped → `3`. `/fr add` 는 3 을 경고로 다루고 등록 성공으로 계속한다 (fail-open).
- **reason 토큰 (skipped):** `bad-slug`(kebab-case 아님) / `no-default-ref` / `row-not-found` / `index-format`(인덱스 표에 `제목` 헤더 칸이 없음 — 재실행으로 풀리지 않음) / `row-column-mismatch`(slug 가 제목 칸이 아닌 다른 칸에만 있음) / `row-ambiguous` / `detail-missing`(파일 없음·링크가 items/ 직접 자식 아님) / `detail-conflict`(기본 브랜치에 다른 내용으로 존재) / `row-conflict`(상세는 같은데 행 전문이 다름) / `row-missing-on-default`(상세는 같은데 행 없음 — 자동 복구하지 않고 사용자에게 안내) / `capture-conflict`(같은 경로 캡처가 다른 내용) / `capture-missing-on-default`(행·상세는 있는데 로컬 캡처가 기본 브랜치에 없음) / `row-exists`(행만 있고 상세 없음) / `staged` / `other-worktree-dirty` / `write-failed` / `ref-moved`(CAS 거부 또는 update-ref 실패) / `index-no-newline`(기본 브랜치 인덱스가 개행으로 끝나지 않음 — 합성이 마지막 행을 수정으로 만들어 자기 검증에 영구히 걸리므로 사전에 실행 가능한 안내로 중단) / `path-symlink`(인덱스 파일·캡처 파일 또는 등록 경로의 상위 디렉터리가 symlink — 현재 worktree 와 대상 기본 브랜치 worktree 양쪽. 저장소 밖 내용을 blob 으로 넣지 않고 저장소 밖에 쓰지 않는다) / `shape-mismatch`(자기 검증 실패) / `git-error`(worktree 탐색·status·ls-files 등 사전 git 명령 실패 — ref 이동 전 중단) / `interrupted`(INT/TERM 또는 비정상 종료 — CAS 전이면 준비분 rollback 뒤 종료, exit 130/143). **committed 의 reason**: `-` 또는 `wt-sync-incomplete`(사후 동기화 실패·사후 status 확인 실패·CAS 뒤 중단 — 모두 실제 short SHA 와 worktree 복구 명령을 병기, exit 0).
- `already` 는 보존 대상 tuple(행 전문·상세 blob·선택 캡처의 경로+blob) 이 **전부** 같을 때만이다. 부분 일치는 위 명시 reason 으로 skipped 한다 — 조용히 제외·덮어쓰기 하지 않는다.
- **캡처 선택**: `raw-captures/*-fr-<slug>.md`·`*-fr-<slug>-N.md` 중 날짜(파일명 앞 10자)가 가장 늦은 것, 같은 날짜면 충돌 번호 N(없으면 1)이 가장 큰 것 하나. capture writer 가 같은 날 재시도 때 `-2`, `-3`… 을 붙이므로 문자열 순서가 아니라 번호로 고른다.

**상태별 동작 (REQUEST CD (1)-3):**

| 상태 | 동작 |
|------|------|
| 체크아웃 안 됨 (fr 브랜치 세션) | plumbing 커밋 + CAS 만. 워킹트리·HEAD 불변. 현재 트리의 등록 파일은 그대로 남아 다음 iteration commit 에 실린다(동일 입력·동일 내용) |
| 현재 worktree 에 체크아웃 (clean / 등록 경로 외 dirty / 인덱스 unstaged 선행 편집) | 합성 내용으로 커밋 후 `git update-index --add --cacheinfo` 로 사후 동기화. 사용자 변경은 상태 그대로 |
| 현재 worktree 에 체크아웃, 등록 경로 staged | `staged` skipped |
| 다른 worktree 에 체크아웃 | 준비(① 인덱스 무손실 교체 — 원본을 같은 디렉터리의 `.frr-old-*` 로 옮기고 새 내용을 hard link 로 놓은 뒤 옮긴 원본이 status 검사 시점의 blob 과 같을 때만 성공, 다르면 사용자 바이트를 되돌리고 실패 ② 상세 hard-link no-clobber ③ 캡처 hard-link no-clobber ④ `update-index --add --cacheinfo` 3개) → CAS → 사후 동기화 확인. 어느 단계든 실패하면 역순 rollback(인덱스는 no-clobber 복원 — 대상을 임시 이름으로 치운 뒤 그것이 helper 링크 그대로일 때만 원본을 ln 으로 되돌리고, 사용자가 그 뒤 또 썼으면 사용자 내용을 제자리에 두고 원본도 남겨 두 버전을 모두 보존). **사용자 경로에 놓여 있던 inode 는 어느 경로에서도 rm 하지 않는다** — 이미 열린 FD 의 늦은 쓰기가 살아남도록 이름만 그 worktree 의 `<git-dir>/fr-register/` 로 옮겨 보관하며(성공 시 원본 인덱스, 복원 시 치운 파일), 보관한 경로는 결과(committed/skipped/interrupted)와 무관하게 사람용 줄에 `| 보관: <경로…>` 로 **항상** 병기한다 — 늦은 쓰기가 출력 뒤에 도착해도 사용자가 찾을 수 있다. 이 디렉터리는 helper 가 비우지 않으며(사용자가 확인 뒤 지운다), 다른 worktree 등록 1회당 이전 인덱스 사본 1개가 남는다. 대상 worktree 의 등록 경로 조상(`rd-workflow-workspace`·`backlog`·`items`·`raw-captures`) 이 symlink 면 `path-symlink` 로 거부하고, 쓰기는 해석한 물리 경로로 하며 놓은 뒤 논리 경로와 같은 inode 인지 확인한다. **보장 범위는 호출 시 이미 존재하거나 해석 시점까지 드러난 조상 symlink** 이며, 해석 뒤 같은 사용자가 그 디렉터리를 동시에 교체하는 경우는 막지 않는다(git 자신의 worktree 쓰기와 같은 노출) 후 skipped(`write-failed`/`other-worktree-dirty`/`ref-moved`/`interrupted`). 복구 안내는 `status` 확인 뒤 보존할 편집이 없을 때의 `checkout` 이며 무조건 `reset` 하지 않는다 |
| ref 부재·판정 실패 | `no-default-ref` skipped |

helper 는 인덱스 행 1개·상세 1개·캡처 1개(선택) 외 어떤 변경도 커밋하지 않는다. 임시 worktree·임시 브랜치를 만들지 않는다(plumbing + `update-ref` CAS). 실패는 전부 fail-open(skipped, exit 3) — 등록 파일 자체는 현재 워킹트리에 그대로 남는다.

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
