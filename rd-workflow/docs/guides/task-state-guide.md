# task-state 가이드

`rd-workflow-workspace/.lifecycle/task-state` — v2 Phase 2b에서 도입된 단일 권위 상태 파일.
**Short Title / Status / fr-branch / worktree-path / source-fr / extensions.*** 의 기계 판정 소스.

## 스키마

| 키 | 허용값 | 소유자 | 비고 |
|----|--------|--------|------|
| `schema` | `1` | lifecycle | 파일 형식 버전 |
| `short-title` | kebab-case slug \| `-` (sentinel) | `rd task set-status` / promote | LC-18: 단 한 번 설정, 이후 immutable |
| `status` | canonical 8종 (아래 목록) | `rd task set-status` / guard | LC-19: 집합 불변 |
| `fr-branch` | `fr/<slug>` \| `null` | promote / archive | fr 활성 여부는 `!= null` 로 판정 |
| `worktree-path` | 절대 경로 \| `null` | promote / archive | worktree 미사용 시 `null` |
| `source-fr` | `rd-workflow-workspace/backlog/items/<파일>.md` \| `-` | promote / `rd task set-source-fr` | FR 출처 경로 — 아래 'source-fr 계약' 참조 |
| `created-at` | `YYYY-MM-DD-HHMM` 형식 | promote | fr 활성 기간에만 기록; 비활성 시 부재 가능 |
| `extensions.<ext-name>.<key>` | 자유 문자열 (개행 금지) | extension | 아래 규약 참조 |

### canonical 8종 Status (LC-19)

```
대기 중
REQUEST review 대기
spec/plan 작성 중
spec/plan review 대기
구현 중
검증 중
diff review 대기
완료
```

### 파일 형식 예시

```
schema=1
short-title=my-feature
status=구현 중
fr-branch=fr/my-feature
worktree-path=/path/to/worktree
source-fr=rd-workflow-workspace/backlog/items/2026-07-05-my-feature.md
created-at=2026-07-05-1030
```

### source-fr 계약

- **저장 값 형식**: `-`(sentinel) 또는 repo-relative backlog item path (`rd-workflow-workspace/backlog/items/<파일>.md`). 절대경로·`..` 세그먼트·개행·legacy slug는 쓰기 거부 (`source_fr_validate` — `_state_common.sh` 단일 구현). **이 계약은 해석 계층이 넓어져도 바뀌지 않는다.**
- **읽기 해석**: `REQUEST.md ## Source FR` 의 원문은 `source_fr_resolve`(`_state_common.sh` 단일 구현)가 canonical path 로 정규화한다. 지원 표기는 canonical path · markdown 링크 `[텍스트](path)` · 괄호 병기 `slug (path)` · `slug — [상세](path)` 계열 · 위 형식 앞의 `- ` 리스트 접두 · `items/<파일>.md` 축약 · `YYYY-MM-DD slug` · `slug` 단독이다.
  - 괄호 계열에서 **레이블(괄호 앞부분)의 문법은 제한하지 않되 비어 있으면 거부**한다. 정확성은 괄호 안 target 의 형식·실존 검증이 보장하며, 레이블 문법을 고정하면 새 서술 변형마다 다시 실패하기 때문이다. 괄호 뒤에 `)` 와 공백 외의 문자가 남으면 거부한다.
  - **파일명 자체에 괄호가 있으면 링크·괄호 병기 표기를 쓰지 않는다.** `[텍스트](.../2026-04-04-a(b).md)` 는 마지막 괄호를 target 경계로 보는 규칙 때문에 해석되지 않는다. 이런 파일은 `rd-workflow-workspace/backlog/items/2026-04-04-a(b).md` 또는 `items/2026-04-04-a(b).md` 처럼 **경로를 그대로** 적는다 — 이 두 형식은 괄호 해석보다 먼저 판정되므로 파일명의 괄호가 문제되지 않는다.
  - slug 는 소문자 영숫자와 `-` 만 허용한다. `items/<slug>.md` 정확 일치를 먼저 보고, 없으면 `items/*-<slug>.md` 가 **유일하게** 매칭될 때만 채택한다. 0건·복수건은 거부한다.
  - 정규화 결과는 실존하는 **일반 파일**이어야 한다. 디렉토리·깨진 심링크는 거부한다.
- **`## Source FR` 절의 HTML 주석**(`<!-- ... -->`)은 값으로 채택하지 않는다. 템플릿이 형식 예시를 주석으로 담기 때문이다.
- **해석 실패 시**: 값이 있는데 정규화할 수 없으면 **조용히 `-` 로 기록하지 않는다.**
  - `lifecycle/promote.sh`: non-zero 로 중단한다. 이 지점은 `metadata_write` 직전이라 어떤 상태도 바뀌지 않으며, REQUEST 를 고쳐 재실행하면 된다.
  - `lifecycle/promote.sh` 의 `--dry-run` 도 같은 판정을 낸다. 해석은 read-only 라 dry-run 조기 종료보다 먼저 수행하며, 사전 점검이 성공을 알리고 실제 실행만 실패하는 반대 신호를 만들지 않는다.
  - `hooks/pre_commit_archive_gate.sh`: archive 커밋을 차단한다(exit 2). 표기가 어긋났다는 이유로 게이트를 건너뛰지 않는다. 단 이 차단은 **diff review 세션이 종결된 뒤(= archive 커밋 경로)에만** 적용한다 — 세션이 없거나 미종결이면 그 커밋은 아직 archive 단계가 아니므로(구현 중 iteration commit 등) 통과시킨다.
- **직접 주는 값은 엄격하다**: `rd task set-source-fr` · `rd task guard --source-fr` · `promote.sh --source-fr` 는 canonical path 또는 `-` 만 받으며 **해석을 적용하지 않는다.** 비대칭인 이유는 — REQUEST 본문은 사람·AI 가 자유 서술로 쓰는 문서의 일부라 표기가 발산하지만, 직접 주는 값은 호출자가 형식을 아는 인터페이스이므로 관대화가 오히려 오류를 감춘다.
- **기록 시점**:
  - `rd task guard --mode promote`: `--source-fr <path|->` 인자값, 인자 없으면 **`-` 리셋** (이전 작업 stale 값 차단). guard 시점의 REQUEST.md는 작성 전이므로 추론하지 않는다.
  - `lifecycle/promote.sh`: `--source-fr` 인자 > `REQUEST.md ## Source FR` 해석 > `-`. 명시 인자가 있으면 REQUEST 를 읽지도 해석하지도 않는다.
- **리셋 시점**: `metadata_clear` (`lifecycle/archive.sh`·`lifecycle/promote_rollback.sh`) 가 `-`로 복원.
- **정정 CLI**: `rd task source-fr` (조회), `rd task set-source-fr <값>` (검증 후 설정 — 직접 파일 편집 금지).

---

## durable / volatile 파티션

| 파티션 | 파일 | git | 접점 |
|--------|------|-----|------|
| **durable** | `task-state` | tracked (promote 커밋) | `rd task` CLI + `_state_common.sh` 단일 구현 |
| **volatile** | `loop-state` | gitignored | `_lifecycle_common.sh` helper 단일 구현 (`loop_state_record` / `loop_guard_check`) |

task-state와 loop-state를 물리적으로 통합하지 않는 이유:

- task-state는 promote 시 커밋되어야 합니다(LC-05 승계). 카운터는 검증 실패마다 변경되는 로컬 휘발값입니다.
- 통합하면 카운터 증가마다 tracked 파일이 dirty 상태가 되어 LC-20(archive clean 검증) 및 pre-commit gate와 매 사이클 충돌합니다.
- loop-guard 카운터의 "단일 소스"는 현행에도 loop-state 하나이며 이 설계에서도 하나입니다.

**volatile 파티션(loop-guard)의 접점은 `_lifecycle_common.sh` helper(`loop_state_record`/`loop_guard_check`) 단일 구현입니다.** `rd task` wrapper를 신설하지 않습니다.

---

## extensions.* 규약

extension은 CURRENT_TASK.md에 임의 섹션을 추가하는 대신 이 네임스페이스만 사용합니다.

```
extensions.<ext-name>.<key>=<value>
```

- `<ext-name>` 은 extension 디렉토리명 (`claude_skills/<ext-name>/`)과 일치시킵니다.
- 예약 키(`schema`, `short-title`, `status`, `fr-branch`, `worktree-path`, `source-fr`, `created-at`)와 충돌하는 이름은 금지합니다. CLI가 자동 거부하지 않으므로 명명 규칙을 준수해야 합니다.
- 값에 개행 문자를 포함할 수 없습니다(LC-06).

---

## 마이그레이션 절차

첫 `rd task` 호출 시 `state_ensure` 함수가 자동으로 수행합니다.

1. `task-state` 존재 → no-op.
2. `task-state` 부재, `CURRENT_TASK.md` 존재:
   - CURRENT_TASK.md의 `## Status` 섹션에서 Status를 추출합니다.
   - legacy alias `실행 중` → `구현 중` 자동 변환합니다.
   - Status가 canonical 8종이 아니면 **fail-closed**: task-state를 만들지 않고 exit 3 + 복구 안내 메시지 출력(SEC-13).
   - `active-fr`(있으면)에서 fr-branch / worktree-path / short-title을 추출합니다.
   - 백업 저장: `.lifecycle/migration-backup/<YYYYMMDD-HHMMSS>/CURRENT_TASK.md` 및 `active-fr`
   - task-state 생성 후 active-fr 삭제(단일 트랜잭션 — 임시 파일 + mv).
3. `CURRENT_TASK.md` 부재 → 기본값(status=대기 중, sentinel `-`/null)으로 task-state 생성(bootstrap).

### 백업 위치

```
rd-workflow-workspace/.lifecycle/migration-backup/<YYYYMMDD-HHMMSS>/
  CURRENT_TASK.md   ← 마이그레이션 직전 CURRENT_TASK.md 사본
  active-fr         ← (있으면) 직전 active-fr 사본
```

### 실패 시 복구

1. `CURRENT_TASK.md`의 `## Status` 값을 canonical 8종 중 하나로 수정합니다.
2. task-state 파일이 잔존하면 삭제합니다(`rm rd-workflow-workspace/.lifecycle/task-state`).
3. `rd task status` 재실행 → 마이그레이션 재시도.

### "다음 정규 커밋에 편승" 안내

마이그레이션이 만든 tracked 변경(active-fr 삭제 + task-state 추가)은 **자동 커밋하지 않습니다.** 다음 lifecycle 커밋(예: `rd task set-status`, promote 커밋)에 함께 포함하세요. LC-20(archive clean 검증)은 archive 시점에 이 변경이 커밋된 상태를 전제합니다.

---

## LIFECYCLE_METADATA_PATH → TASK_STATE_PATH 마이그레이션 노트

v2 Phase 2b 이전의 `LIFECYCLE_METADATA_PATH` 환경 변수(`.lifecycle/active-fr` 경로 override)는 폐지됩니다.

- 대체: `TASK_STATE_PATH` 환경 변수 (기본값 `rd-workflow-workspace/.lifecycle/task-state`)
- `_lifecycle_common.sh`의 `metadata_*` 함수들은 내부적으로 `TASK_STATE_PATH`를 사용합니다.
- `LIFECYCLE_METADATA_PATH`를 설정하던 코드는 `TASK_STATE_PATH`로 교체해야 합니다.

---

## 관련 파일

- `_state_common.sh` — task-state I/O 함수 (`state_file_exists`, `state_read_field`, `state_write_fields`, `state_ensure`)
- `_task_common.sh` — CLI 계층 (`TASK_CANONICAL_STATUSES`, `task_read_status`)
- `hooks/_guard_common.sh` — guard 판정 함수 (`get_task_status`, `get_current_short_title`)
- `lifecycle/_lifecycle_common.sh` — `metadata_*` 래퍼 + loop-guard helper
- `scripts/self_test.sh` — LC-19 3자 일치 + stale 참조 회귀 grep 검증
