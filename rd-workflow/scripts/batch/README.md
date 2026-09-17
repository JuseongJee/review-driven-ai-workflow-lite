# scripts/batch

`/fr batch` 오케스트레이터의 결정적 헬퍼 디렉토리.

- `batch_manifest.sh` — manifest JSON을 읽어 결정적 파생값만 반환하는 SSOT 헬퍼 (validate/next/set-state/skip-dependents/restore-dependents/summary/verify-done/archive-state/resolve-slug). bash 3.2 호환(연관배열 미사용), jq 전제.
- `test_batch_manifest.sh` — 헬퍼 단위 테스트.
- `test_archive_state.sh` — `archive-state`·`restore-dependents` 단위 테스트.

오케스트레이션 지능(선별·brainstorming 보강·의존 확정·요약)은 `claude_skills/fr/batch.md`(살아있는 Claude 세션) 소관입니다. 이 디렉토리는 규칙의 단일 출처이며 skill 문서는 여기로 위임합니다.

## 서브커맨드

### `archive-state <manifest> <slug>`

slug 의 archive **발행** 완료 여부를 git 사실로 판정한다. `verify-done` 은 workspace
사실만 보므로(items status=done + request-archive 파일), merge 만 되고 tag·push·브랜치
정리가 남은 상태를 완료와 구분하지 못한다. 이 서브커맨드가 그 구멍을 막는다.

- stdout 첫 줄: `state=<complete|incomplete-archive|not-archived|unknown> policy=<push|merge> missing=<csv|-> reason=<token|->`
- 이어서 사람용 줄 1개.
- exit 0 (판정 성공, 결과는 stdout) / 2 (인자·manifest 오류).

| state | 의미 | 호출측 처리 |
|---|---|---|
| `complete` | 정책상 필수 증거를 모두 충족 | 완료 집계 |
| `incomplete-archive` | merge 는 됐으나 발행 미완 | `archive.sh --fr-branch "fr/<slug>"` 재호출로 이어붙이기 (merge 정책이면 `--no-remote` 추가) |
| `not-archived` | merge 근거 없음 | 일반 재시도 |
| `unknown` | 증거를 얻지 못함 | 상태 보존·중단·보고 (완료로도 미병합으로도 취급 금지) |

**정책별 필수 증거**

| 증거 토큰 | `push` | `merge` |
|---|---|---|
| `verify-done` | 필수 | 필수 |
| merge 반영 | 필수 | 필수 |
| `tag` / `tag-points` | 필수 | 필수 |
| `local-branch` 정리 | 필수 | 필수 |
| `remote-branch` / `remote-tag` / `remote-tag-mismatch` / `remote-fr-branch` | 필수 | 비필수 (조회하지 않음) |

**reason 토큰**: `lifecycle-common-missing` / `no-default-branch` / `default-ref-missing` /
`remote-unreachable` / `remote-object-missing`.

**조회 실패와 부재를 구별한다.** `ls-remote` 실패는 「원격 ref 없음」이 아니라 판정 불가다.
`ls-remote` 가 알려준 tip 이 로컬 object DB 에 없으면(다른 clone 이 전진시킨 경우) 조상
판정을 할 수 없으므로 미충족이 아니라 `unknown` 이다. 기본 브랜치는 이름을 얻은 뒤 로컬
ref 실재까지 확인한다 — 확인하지 않으면 ref 부재가 「merge 근거 없음」으로 바뀌어 이미
merge 된 작업이 일반 재시도로 간다.

**원격 tag 는 OID 로 확인한다.** 이름이 같아도 다른 커밋을 가리킬 수 있고, 그때 이름만
보면 잘못된 원격 산출물을 완료로 집계한다.

`merge` 정책은 원격을 조회하지 않으므로 remote 가 없거나 오프라인이어도 판정이 멈추지
않는다.

### `restore-dependents <manifest> <root-slug>`

`skip-dependents` 의 대칭이다. `<root-slug>` 를 회수(재시도 대상으로 되돌림)한 뒤,
그 (전이) 후손 중 `pending` 으로 되돌릴 항목을 한 줄에 하나씩 stdout 에 낸다.

산출 조건: `state=skipped`, `feasibility=eligible`, 그리고 직접 의존이 모두
`completed`·`pending` 이거나 이번 산출 집합에 포함될 것. 다른 `blocked` 선행이 남은
가지, `feasibility=excluded` 항목, root 와 무관한 가지는 산출하지 않는다.

exit 0 / 2 (인자·manifest 오류).
