# 템플릿 변경사항을 프로젝트에 동기화

이 문서는 Claude가 읽고 실행하는 템플릿 동기화 가이드입니다.

사용자는 프로젝트 디렉토리에서 Claude Code를 열고 아래처럼 말하면 됩니다.

```text
템플릿 최신으로 업데이트해
```

배포 repo URL을 알고 있다면:

```text
이 템플릿으로 업데이트해: <배포 repo URL>
```

---

## Claude가 실행할 절차

### 0. 업그레이드 시점 확인

템플릿 업그레이드는 **진행 중 작업이 없을 때** 수행하는 것을 권장합니다 — `CURRENT_TASK.md`의 `## Status`가 `대기 중`이고, 열린 review 세션(`rd-workflow-workspace/handoffs/review_pipeline/*/SESSION.md`의 `## Status`가 `closed`가 아닌 세션)이 없는 상태.

동기화 시작 전에 위 두 가지를 확인합니다. 해당 파일이나 섹션이 없으면(구버전 구조) 이 확인은 건너뛰고 1단계로 진행합니다.

**진행 중 작업이 있으면** 사용자에게 알리고 선택을 받습니다:

1. **(권장) 현재 작업을 먼저 마감**: 현재 작업을 archive까지 완료한 뒤 업그레이드합니다.
2. **mid-task 업그레이드 강행**: 아래 영향을 안내한 뒤 진행합니다.
   - 구버전에서 생성된 review 세션은 `SESSION.md`에 Branch Context `fr-branch`가 없어, 이후 archive precheck가 fail-closed로 차단될 수 있습니다. 이 경우 `bash rd-workflow/scripts/lifecycle/archive.sh --force-skip-review-check "<사유>"`로만 우회할 수 있습니다 (사유 필수, `rd-workflow-workspace/.lifecycle/review-skip-audit.log`에 감사 기록됨).
   - review 세션 `CHECKPOINT.md`의 `## Open Issues`는 canonical 마커 규약을 따라야 합니다 — 미해결이 없으면 `- 없음` 또는 `- None` 한 줄을 절의 첫 줄에 둡니다 (후행 마침표 1개 허용). 종결 경위는 그 아래에 빈 줄로 띄우고 문단으로 적습니다. 미해결 항목은 리스트 항목으로 적습니다. 빈 섹션·마커 앞 산문·마커에 이어지는 줄은 미종결로 판정되어 archive가 차단됩니다.
   - 구버전 세션에는 `SESSION.md`에 `review-head-oid`가 없어(= legacy 정의) 종결 마커를 만드는 `rd review seal`이 거부합니다. 그 작업을 마감하려면 `bash rd-workflow/scripts/rd review seal --legacy-unverified "<사유>" <세션 경로>`가 유일한 경로이며, **이 마커는 리뷰 당시 트리를 증명하지 않습니다** (상세·트레이드오프: `MIGRATIONS.md` M011).

### 1. 버전 확인 및 템플릿 소스 확보

먼저 프로젝트의 이전 VERSION 을 읽어 기록합니다. 9단계 완료 보고가 이 값으로 새로 받은 변경 이력을 고릅니다. 이후 단계(구조 마이그레이션·5단계 복사·6단계 버전 갱신)가 VERSION 을 바꾸므로 버전 가드보다 먼저 읽습니다.

```bash
pv="$(git rev-parse --git-path rd-tpl-prev-version)"
{ cat rd-workflow/VERSION 2>/dev/null || cat ai/VERSION 2>/dev/null || true; } > "$pv"
v="$(cat "$pv")"; echo "이전 VERSION: ${v:-없음}"
```

- 값은 git 디렉터리 안의 `rd-tpl-prev-version` 파일에 남습니다. 커밋되지 않고, 다음 update 의 1단계가 덮어씁니다.
- `migrate post` 의 안내 판정과 9단계 `changelog` 가 이 파일을 읽습니다. 값을 명령 문자열에 옮겨 적지 않습니다. VERSION 내용이 셸 명령으로 실행되는 일을 막기 위해서입니다.
- full 판은 `YYYY-MM-DD-HHMMSS`, lite 판은 `lite-YYYY-MM-DD-HHMMSS` 형식입니다.
- 이 명령은 하위 명령으로 옮기지 않습니다. 옛 로컬 스크립트에는 하위 명령이 없고, 기록은 clone 이 생기기 전에 해야 하기 때문입니다.

이어서 버전 가드 스크립트를 실행합니다.

```bash
bash rd-workflow/scripts/sync_template.sh <배포 repo URL>
```

- 스크립트가 정상 종료(exit 0)하면 마지막 줄에 출력된 임시 clone 경로를 사용합니다. 이 문서는 그 경로를 `C` 로 부릅니다: `C=<임시 clone 경로>`.
- 스크립트가 다운그레이드 경고로 중단(exit 1)하면:
  - 사용자에게 "현재 프로젝트의 템플릿이 원격보다 최신입니다. 강제로 다운그레이드하시겠습니까?" 확인
  - 사용자가 동의하면 `--force`를 붙여 재실행
  - 사용자가 거부하면 동기화 중단
- 스크립트가 템플릿 타입 불일치 또는 타입 미확정으로 중단(exit 1)하면:
  - 1차 대응: 배포 repo URL이 현재 프로젝트의 템플릿 타입(full/lite)과 맞는지 확인합니다. URL 혼동이면 올바른 URL로 재실행합니다.
  - 교차 sync 사고로 로컬 VERSION이 오염된 프로젝트의 복구처럼 의도한 교차 적용일 때만, 사용자에게 위험(현재 타입 전용 파일이 삭제 후보로 분류될 수 있음)을 안내하고 동의를 받은 뒤 `--allow-type-mismatch`를 붙여 재실행합니다. 이 플래그는 타입 불일치·미확정 케이스에서만 효력이 있고(해당 시 버전 비교도 생략), 타입이 일치하면 효과 없이 기존 버전 가드가 그대로 적용됩니다.
  - `--force`는 타입 불일치를 우회하지 못합니다 (같은 타입 내 다운그레이드 승인 전용).

배포 repo URL을 모르면 사용자에게 물어봅니다.

동기화 대상은 현재 작업 디렉토리 (프로젝트 루트)입니다.

**절차 권위는 clone 의 이 문서입니다 (M000).** `$C/rd-workflow/docs/guides/sync_template.md` 가 프로젝트의 이 문서와 다르면(`cmp -s` 가 0 이 아니면) clone 쪽 문서를 읽고 0단계부터 그 문서를 따릅니다. 로컬 문서로 이미 한 단계(분류·확인 등)는 clone 문서 기준으로 다시 합니다.

### 하위 명령 실행 규칙

2단계부터의 기계적 처리는 `sync_template.sh` 의 하위 명령이 합니다. 분류·복사·마이그레이션·재설치 규칙의 정본은 스크립트이고, 이 문서는 부르는 순서와 판단 항목 처리만 적습니다.

- 하위 명령은 항상 **clone 의 스크립트**로, **프로젝트 루트에서** 실행합니다: `bash "$C/rd-workflow/scripts/sync_template.sh" <하위 명령>`.
- `classify`·`apply`·`migrate` 를 프로젝트의 스크립트로 부르면 `오류: clone 의 스크립트로 실행하십시오` 와 함께 exit 2 입니다. 프로젝트 루트가 git 저장소가 아니어도 exit 2 입니다.
- 출력은 TAB 구분 줄입니다. 사용자에게 보일 요약은 Claude 가 이 줄로 만듭니다.
- python3 3.9 이상이 필요합니다. 그보다 낮으면 `오류: python3 3.9 이상이 필요합니다 (지금 <버전>)` 와 함께 exit 2 입니다. python3 가 없으면 `오류: python3 가 필요합니다` 와 함께 exit 2 입니다.

| 하위 명령 | 단계 | 하는 일 |
| --- | --- | --- |
| `policy` | 참고 | 전파 정책 표 출력 |
| `classify [--no-save]` | 2, 6 | 파일 분류. 저장하면 5단계 `apply` 의 계획이 됩니다 |
| `migrate pre` | 4 | 동기화 전 마이그레이션 |
| `apply [--delete] [--exclude <경로>]...` | 5, 6 | 복사·추가·삭제, 마지막에 VERSION 갱신 |
| `migrate post` | 6 | 동기화 후 마이그레이션과 안내 |
| `migrate M013 [--decide '<제목>=adopt\|keep\|defer']...` | 6 | `CLAUDE.md` 절 정리와 사용자 결정 반영 |
| `reinstall [답 인자]` | 7, 8 | skill·extension 재설치, preset 머지, 매니페스트 저장 |
| `changelog` | 9 | 받은 변경 이력 출력 |

### 2. 파일 분류

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" classify
```

출력 형식은 다음과 같습니다.

```
# rd-tpl-plan v1<TAB>clone-version=<clone VERSION>
<분류><TAB><경로><TAB><근거>
...
# 요약<TAB>update=N<TAB>add=N<TAB>delete=N<TAB>keep=N<TAB>ask=N<TAB>same=N
```

- 분류는 `update`(덮어쓰기)·`add`(신규 추가)·`delete`(삭제 후보)·`keep`(보존)·`ask`(판단 필요)·`same`(같음) 입니다. `same` 은 줄로 내지 않고 요약에만 셉니다.
- 줄은 경로순입니다. 계획은 git 디렉터리의 `rd-tpl-plan.tsv` 에 저장됩니다.
- exit 0 은 정상입니다. exit 2 는 실행 위치·인자 오류입니다.
- **exit 3** 은 구조 마이그레이션이 남았다는 뜻입니다. 출력은 `ask<TAB>M001|M002<TAB>구조 마이그레이션 먼저` 입니다. clone 의 `MIGRATIONS.md` 에서 그 항목(M001·M002)을 읽고 사용자와 함께 처리한 뒤 `classify` 를 다시 실행합니다.

정책 값은 다섯 가지입니다.

- `덮어쓰기` — 템플릿 내용으로 맞춥니다. 템플릿에 없는 파일은 삭제 후보입니다. extension 으로 설치된 스킬(`rd-workflow/claude_skills/<이름>/`)은 삭제 후보에서 빼고 보존합니다.
- `부재 항목 머지` — 부재한 항목이나 라인만 추가합니다. `.claude/settings.json`·`.gitignore` 이며 마이그레이션(M005·M008·M003·M015)이 처리합니다.
- `부재 시 생성` — 경로가 없을 때만 배포본을 둡니다. 경로가 있으면 5단계 복사가 건드리지 않습니다.
- `조건부 보존` — 아래 A1·A3 조건을 충족하면 보존하고, 충족하지 않으면 템플릿 본으로 맞춥니다. 경로가 없으면 배포본을 둡니다.
- `미전파` — 프로젝트 고유 파일, 휘발 상태, 작업 산출물입니다. sync 가 건드리지 않습니다.

### 2.1 파일군별 전파 정책 표

표의 정본은 스크립트 데이터(`rd-workflow/scripts/_tpl_classify.py` 의 `POLICY`)입니다. 아래 명령이 `경로 패턴<TAB>정책<TAB>수정·삭제 가능성` 줄을 출력합니다.

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" policy
```

- 경로 패턴은 정확한 경로이거나 `/` 로 끝나는 디렉토리 prefix 입니다. 한 파일이 여러 행에 걸리면 더 긴 패턴이 이깁니다.
- 어느 행에도 걸리지 않는 템플릿 파일은 `ask`(근거 `전파 정책 표에 없음`)입니다. 새 파일군을 만들면 `POLICY` 에 행을 추가합니다.
- 「있음」 판정은 `[ -e 경로 ] || [ -L 경로 ]` 와 같은 의미입니다. dangling symlink 도 있음입니다. 그래서 끊어진 symlink 인 `rd-workflow/config/workflow.json` 은 배포본으로 덮이지 않고 보존됩니다.
- `덮어쓰기`·`조건부 보존` 경로가 프로젝트에서 symlink 이거나 파일·디렉터리 종류가 템플릿과 다르면 `ask` 입니다. 링크를 따라 쓰거나 링크를 일반 파일로 바꾸지 않습니다.
- `update`·`add`·`delete` 가 될 경로의 상위 디렉터리 중 하나라도 symlink 이면 `ask`(근거 `상위 경로 symlink: <경로>`)입니다.
- `rd-workflow/config/workflow.json` 의 보존은 5단계 복사에 대한 것입니다. 5.1 절은 같은 파일에 `defect_report_upstream` 키 하나만, 값이 비어 있을 때에 한해 씁니다.

**조건부 보존 판정 (A1·A3).** 다섯 파일은 조건에 따라 보존하거나 템플릿 본으로 맞춥니다. 판정할 수 없으면 보존합니다.

- **A1** (`rd-workflow-workspace/backlog/FUTURE_REQUESTS.md`·`FUTURE_REQUESTS_PARKED.md`·`rd-workflow-workspace/reports/tier-log.md`): 첫 구분선 줄(`|---` 또는 `| ---`) 아래에 표 행이 하나라도 있으면 보존합니다. 구분선이 없거나 읽지 못하면 보존합니다.
- **A3** (`REQUEST.md`·`CURRENT_TASK.md` 한 묶음): 프로젝트 파일에서 빈 줄, 줄 전체가 주석인 줄·블록, clone 의 같은 이름 파일에 글자 그대로 있는 줄을 뺍니다. 두 파일 모두 남는 줄이 없을 때만(또는 경로가 없을 때만) 둘 다 동기화합니다. 하나라도 남으면 둘 다 보존합니다. 주석과 본문이 섞인 줄, 닫는 줄 뒤에 본문이 있는 블록, 닫히지 않은 주석은 남는 줄로 셉니다. `CURRENT_TASK.md` 는 2026-11-13 까지 archive 가 쓰던 이전 초기본의 줄(`[REQUEST.md](REQUEST.md)`·`main`·`## Output Files`)도 템플릿 본 줄로 봅니다.
- 근거 칸이 판정 결과를 보입니다: `A1 행 N개`·`A1 구분선 없음(판정 불가)`·`A1 읽지 못함`·`A3 남은 줄 N개: <첫 줄>`·`A3 읽지 못함`.
- 두 파일을 묶어 판정하는 이유: 한쪽만 새 템플릿으로 바꾸면 REQUEST 와 CURRENT_TASK 의 섹션 체계가 갈라집니다.
- 「판정 불가」의 비용: 내용 없는 옛 템플릿 일부는 새 템플릿으로 바뀌지 않습니다. 지울 수 없는 기록을 지우는 쪽보다 안전하므로 이 비용을 받습니다.

### 2.2 설치 범위 밖 파일의 내용 drift — 검토 결론

검토 질문은 다음과 같습니다. `.claude/settings.json` 처럼 `rd-workflow/` 밖에 있어 템플릿과 어긋날 수 있는 파일의 drift 를 자동으로 잡는 수단이 필요합니까.

결론: 자동 감지 수단을 지금은 채택하지 않습니다. 이유는 둘입니다.

1. 감지를 session_start hook 에 두면, hook 이 무력화된 환경에서는 경고도 뜨지 않습니다. 감지 대상과 감지 수단이 같은 파일에 걸려 있습니다.
2. 이 템플릿에는 소비 프로젝트 목록이 없습니다. 개발 쪽에서 설치본의 상태를 읽거나 강제로 전파할 수 없습니다. 전파는 각 프로젝트가 `/tpl update` 를 실행해야 닿습니다.

대신 아래 「기존 설치본 1회성 백필」 절의 읽기 전용 점검을 hook 에 의존하지 않는 수동 경로로 둡니다.

남는 위험은 `/tpl update` 를 하지 않는 설치본이 계속 낡은 상태로 남는다는 점입니다. 그 설치본이 몇 개인지 개발 쪽에서 알 수 없습니다.

재검토 조건은 소비 프로젝트에서 hook 무력화나 정책 drift 가 실제로 관측되는 경우입니다. 그때 감지 수단(버전 가시성, 점검 스크립트 배포)을 별도 작업으로 다룹니다.


### 3. 사용자 확인

`classify` 출력으로 화면을 만들어 사용자에게 보이고 확인을 받습니다.

보여줄 내용:
- 내용이 바뀌어서 덮어쓸 파일 목록 (`update` 줄)
- 새로 추가할 파일 목록 (`add` 줄)
- 삭제할 파일 목록 (`delete` 줄, 있다면)
- 보존할 파일 요약 (`keep` 줄)
- 조건부 보존 파일 다섯 개의 판정 결과(보존 / 템플릿으로 동기화 / 신규 추가)와 그 근거(근거 칸의 행 수, 남은 줄 수와 첫 줄). 판정 불가로 보존한 파일은 사용자가 직접 바꿀 수 있도록 남은 줄을 보입니다
- 판단 필요 경로 (`ask` 줄)와 그 근거. 이 경로는 5단계가 건드리지 않습니다. 사용자가 직접 처리합니다

사용자 답을 5단계 인자로 옮깁니다.
- 사용자가 빼라고 한 경로마다 `--exclude <경로>` 를 붙입니다.
- 삭제를 확인받았으면 `--delete` 를 붙입니다. 확인받지 않았으면 붙이지 않습니다. 이때 삭제 후보는 지우지 않고 남습니다.

### 4. 마이그레이션 (동기화 전)

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" migrate pre
```

- 실행 순서는 M000 → M001 → M002 → M005 → M008 → M003 → M015 → M009 입니다. 항목 목록과 순서의 정본은 clone 의 스크립트이며, 각 항목의 조건·동작 변화는 clone 의 `MIGRATIONS.md` 에 있습니다.
- 출력은 항목마다 첫 줄 `<Mxxx><TAB><APPLIED|NOOP|ASK|NOTICE|FAIL><TAB><한 줄 요약>` 이고, 그 아래 두 칸 들여쓴 세부 줄이 붙습니다.
- exit 0 은 정상입니다. exit 1 은 `FAIL` 이 하나 이상 있다는 뜻입니다. exit 3 은 M001·M002 가 `ASK` 라 나머지를 실행하지 않았다는 뜻입니다.

결과 처리:
- `APPLIED`·`NOOP` — 세부 줄을 9단계 보고에 옮깁니다. 바뀐 파일은 자동 커밋하지 않고 다음 정규 커밋에 함께 넣습니다.
- `FAIL` — 원본을 바꿨는지는 요약과 세부 줄이 말합니다. 요약이 `원본을 바꾸지 않았습니다` 이면 그 항목은 파일을 바꾸지 않았습니다. `적용 후 .gitignore 실패` 나 `파일은 바꿨고 계획 갱신 실패` 는 파일을 이미 바꾼 뒤의 실패입니다. 계획 갱신 실패는 `classify` 부터 다시 합니다. 세부 줄의 원인과 조치를 사용자에게 보이고 판단을 받습니다. 원인을 고친 뒤 `bash "$C/rd-workflow/scripts/sync_template.sh" migrate <Mxxx>` 로 그 항목만 다시 실행합니다.
  - 프로젝트 `.claude/settings.json` 을 읽지 못해 난 `FAIL` 은 settings 를 다루는 항목(M005·M008·M003·M015)에 함께 납니다. 사용자에게 선택을 받습니다. (a) 수동 복구 후 `migrate pre` 재실행, (b) 기존 파일을 `.claude/settings.json.bak` 으로 백업하고 clone 된 파일로 대체한 뒤 `migrate pre` 재실행.
- `ASK`(exit 3, M001·M002) — clone 의 `MIGRATIONS.md` 에서 그 항목을 읽고, 사용자 파일 경로 치환을 사용자와 함께 정한 뒤 처리합니다. 처리 뒤 2단계 `classify` 부터 다시 합니다.

마이그레이션이 3단계 계획에 있는 파일(`.claude/settings.json`·`.gitignore`·`FUTURE_REQUESTS.md`)을 바꾸면 `migrate` 가 계획 파일의 그 줄을 함께 고칩니다. 그래서 5단계가 그 변경을 「분류 뒤 프로젝트가 바뀜」 으로 보지 않습니다.

### 5. 동기화 실행

사용자 확인 후, 3단계에서 정한 인자로 실행합니다.

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" apply [--delete] [--exclude <경로>]...
```

출력 줄:

| 줄 | 뜻 |
| --- | --- |
| `copied<TAB><경로>` | 덮어썼습니다 (`update`) |
| `added<TAB><경로>` | 새로 추가했습니다 (`add`) |
| `deleted<TAB><경로>` | 삭제했습니다 (`--delete` 가 있을 때만) |
| `skipped<TAB><경로><TAB>exclude` | 사용자가 뺀 경로라 건너뛰었습니다 |
| `skipped<TAB><경로><TAB>delete-not-confirmed` | 삭제를 확인받지 않아 남겼습니다 |
| `skipped<TAB><경로><TAB>ask` | 판단 필요 경로라 건드리지 않았습니다 (`rd-workflow/VERSION` 이 `ask` 여도 같은 줄이 나오며 `version` 줄은 나오지 않습니다) |
| `version<TAB><이전><TAB><새>` | 마지막에 `rd-workflow/VERSION` 을 갱신했습니다 |

- `keep` 경로는 출력하지 않고 건드리지 않습니다.
- VERSION 은 다른 파일을 모두 처리한 뒤 마지막에 복사합니다. 중간에 실패하면 VERSION 이 옛 값으로 남아 다음 update 가 다시 시도합니다.

멈춤과 오류:
- **분류 뒤 프로젝트가 바뀌었으면** 아무것도 바꾸지 않고 멈춥니다. stdout 에 `changed<TAB><경로><TAB>계획: <분류><TAB>지금: <분류>` 줄을, stderr 에 `오류: 분류 뒤 프로젝트가 바뀌었습니다 — classify 부터 다시` 를 내고 exit 1 입니다. 분류가 같고 내용만 바뀐 경우도 멈추며, 그때는 `지금: <분류> (프로젝트 내용 바뀜)` 또는 `(clone 내용 바뀜)` 처럼 바뀐 쪽을 덧붙입니다. 이때 **3단계 확인을 처음부터 다시 합니다**: `classify` 재실행 → 사용자 확인 → `apply`.
- 계획 파일이 없으면 `오류: 계획 파일이 없습니다 — classify 를 먼저 실행하십시오` 와 함께 exit 2 입니다.
- 계획의 clone 버전이 지금 clone 과 다르면 exit 1 입니다. `classify` 부터 다시 합니다.
- 계획에 없는 `--exclude` 경로는 `오류: 계획에 없는 --exclude 경로: <경로>` 와 함께 exit 2 입니다. 오타를 고쳐 다시 실행합니다.
- 복사·삭제 중 오류는 처리한 줄까지 출력하고 `오류: 복사·삭제 중 실패: <원인>` 과 함께 exit 1 입니다. 원인을 사용자에게 보이고, 고친 뒤 `classify` 부터 다시 합니다.

### 5.1 defect_report_upstream 자동 채우기

결함 보고서를 보낼 대상 저장소를 배포 repo URL 에서 유도해 채웁니다.
**이미 값이 있으면 건드리지 않습니다** — 사용자가 의도적으로 지정한 값(예: 개인 저장소)이
업그레이드 때마다 덮어써지면 안 되기 때문입니다.

```bash
bash rd-workflow/scripts/defect_reports.sh set-upstream "<배포 repo URL>"
```

- 값이 비어 있으면 canonical 값(`owner/repo` 또는 `host/owner/repo`)을 기록합니다.
- 이미 값이 있으면 "이미 설정됨" 을 출력하고 원본을 유지합니다.
- **이 절이 쓰는 것은 `defect_report_upstream` 키 하나뿐입니다.** `default_execution_mode`
  를 포함한 다른 키의 값과 경로 종류(regular file / symlink)는 바꾸지 않습니다. 2단계
  보존 규칙과 모순되지 않습니다 — 그 규칙은 5단계 복사에 대한 것이고, 이 절은 그 위에서
  키 하나만 채우는 별도 단계입니다.
- **URL 문법을 지원하지 않아 유도에 실패하면(스크립트 exit 1) 이는 예상 분기입니다.**
  아무것도 쓰지 않고 **보류한 뒤 sync 를 계속합니다** — 6단계 이후(검증·버전 갱신·skill
  재설치·extension 재설치)를 건너뛰지 않습니다. 잘못된 대상에 추측 발행하지 않기 위함이며,
  이 경우 결함 보고 전달은 미전달 목록에 남습니다. 9단계 완료 보고에
  「`defect_report_upstream` 미설정」과 그 사유, 수동 지정 방법(결함 보고 발행 시
  `--upstream <owner/repo>` 로 지정하거나 `rd-workflow/config/workflow.json` 에 직접 기입)
  을 표시합니다.
- **유도 실패와 실제 쓰기 실패는 구분합니다.** 위 보류-후-계속은 URL 에서 대상을 유도하지
  못한 경우에만 해당합니다. 파일 갱신 자체가 실패했다면(쓰기 권한·JSON 훼손 등) 그것은
  보류가 아니라 보고하고 사람이 확인할 문제이므로, 사용자에게 알리고 판단을 받습니다.
- **스크립트에 새 exit code 를 만들지 않는 이유**: 이 절차는 에이전트가 따르는 문서이고,
  standalone 호출자에게는 유도 실패에 exit 1 이 올바른 신호이므로 분기 처리는 이 문서가 맡습니다.
- **5단계가 배포본을 복사하므로 이 절에 들어오는 시점에는 `rd-workflow/config/workflow.json`
  이 존재합니다.** 2단계 보존 규칙에 따라 경로가 이미 있었다면 그 파일이 그대로 남아 있고,
  없었다면 배포본이 새로 놓입니다.
- **그럼에도 파일이 여전히 없는 경우의 동작은 바꾸지 않습니다** — 이 스크립트는 sync 밖에서
  직접 호출되기도 하기 때문입니다. `set-upstream` 은 안내 후 **성공 종료**(무변경),
  `preview`·`publish` 는 전달 대상을 빈 값으로 보고 **미전달로 남깁니다**. 세 경우 모두
  파일을 만들지 않으며, 이때 결함 보고 전달은 발행 시 `--upstream <owner/repo>` 수동 지정에
  의존합니다.

### 6. 검증 및 동기화 후 마이그레이션

**동기화 결과 검증.** 분류를 저장하지 않고 다시 실행합니다.

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" classify --no-save
```

- 남은 `update`·`add`·`delete` 줄이 3단계에서 사용자가 뺀 경로(`--exclude` 경로, 확인받지 않은 삭제 후보)뿐이어야 합니다. `--exclude` 로 뺀 경로가 다시 `update` 로 나오는 것은 정상입니다.
- 그 밖의 경로가 남으면 `apply` 출력과 대조해 원인을 사용자에게 보고합니다.
- `rd-workflow/VERSION` 은 5단계 `apply` 가 마지막에 이미 갱신했습니다. 따로 복사하지 않습니다.

**동기화 후 마이그레이션.**

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" migrate post
```

- 감지 항목은 M004 → M013 → M011 → M014 → M017 순서로 실행합니다. 그다음 안내 항목(M006·M007·M010·M011·M012·M016·M017·M018)을 냅니다.
- 안내(`NOTICE`)는 1단계에 기록한 이전 VERSION 의 날짜가 그 항목의 기준 날짜 이하일 때만 나옵니다. 이전 VERSION 을 모르면 안내를 모두 내고 `NOTICE<TAB>-<TAB>이전 VERSION 을 몰라 안내를 모두 보였습니다` 를 덧붙입니다.
- exit 0 은 정상이고, exit 1 은 `FAIL` 이 하나 이상 있다는 뜻입니다.

결과 처리:
- `NOTICE` — clone 의 `MIGRATIONS.md` 에서 그 항목의 「동작 변화」·「사용자가 할 일」 을 읽고 9단계 보고에 요약합니다.
- `ASK` M004 — `rd task status` 가 exit 3 입니다. `CURRENT_TASK.md` 의 `## Status` 를 canonical 값으로 수동 복구한 뒤 `bash rd-workflow/scripts/rd task status` 를 다시 실행합니다 (`rd-workflow/docs/guides/task-state-guide.md` 「실패 시 복구」).
- `ASK` M011·M014·M017 — 세부 줄의 안내(고칠 `.gitignore` 규칙, 추적 해제 명령, 남은 batch manifest 처리)를 사용자에게 그대로 보입니다. 사용자 파일 편집과 커밋은 사용자 몫입니다.
- `<Mxxx><TAB>ASK<TAB>스크립트에 없는 항목 — MIGRATIONS.md 를 읽고 처리하십시오` — 스크립트가 모르는 새 항목입니다. clone 의 `MIGRATIONS.md` 에서 그 항목을 읽고, 조건과 절차를 사용자와 함께 처리합니다. 건너뛰지 않습니다.
- `FAIL` — 세부 줄의 원인을 보고하고 사용자 판단을 받습니다. 고친 뒤 `migrate <Mxxx>` 로 그 항목만 다시 실행합니다.

**M013 (`CLAUDE.md` 절 정리).** `migrate post` 가 묻지 않는 처리를 이미 했습니다: 템플릿 그대로인 절(`template`)을 걷어내고, 목차 절이 없으면 보충합니다. 사용자 선택이 필요한 절이 있으면 `M013<TAB>ASK` 와 세부 줄을 냅니다.

| 세부 줄 | 뜻과 할 일 |
| --- | --- |
| `modified<TAB><제목><TAB><diff 파일>` | 템플릿 제목이지만 본문을 고친 절입니다. diff 파일을 사용자에게 보이고 셋 중 하나를 받습니다 |
| `ambiguous<TAB><제목>` | 같은 제목이 반복된 절입니다. 손대지 않고 보고합니다 |
| `abort<TAB>…` | fence 가 있어 편집하지 않았습니다. 사용자가 절 목록과 diff 를 보고 직접 정리한 뒤 sync 를 다시 실행합니다 |
| `fail<TAB><원인>` | 분류기 오류나 파일 입출력 실패(디스크 공간·권한·경로 충돌)로 멈췄습니다 (`M013<TAB>FAIL`). 이미 걷어낸 절·표식·덧붙인 목차는 `removed`·`override`·`index` 줄로 함께 나오며 CLAUDE.md 에 반영된 상태입니다. 입출력 실패는 원인을 고친 뒤 결정 없이 `migrate M013` 을 다시 실행합니다. 결정 없이 실행했다면 지운 절은 모두 템플릿 그대로였던 절입니다. `--decide adopt` 로 실행했다면 사용자가 고친 절도 들어 있습니다 |
| `removed<TAB><제목>` | 걷어낸 절입니다 |
| `index<TAB>목차 절을 보충했습니다` | `## rd-workflow 규칙` 절을 붙였습니다 |
| `gitignore<TAB><check-ignore 출력><TAB><고치는 방법>` | `.gitignore` 가 rules 를 가립니다. 그 줄과 고치는 방법을 사용자에게 보입니다 |

`modified` 절마다 받을 답:
- 템플릿 채택(`adopt`) — 절을 지웁니다.
- 프로젝트 판 유지(`keep`) — 절을 남기고 제목 다음 줄에 `<!-- rd-workflow:project-override -->` 를 넣습니다. 이 절과 rules 판이 함께 로드되므로 사용자가 절 첫 줄에 대체 대상을 적도록 안내합니다.
- 보류(`defer`) — 원문 그대로 둡니다. 다음 sync 에 다시 묻습니다.

답을 모두 받으면 결정을 넘겨 다시 실행합니다. 보류도 넘깁니다. 그래야 결정 기준본이 정리되고 보고 줄이 나옵니다.

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" migrate M013 --decide '<제목>=adopt' --decide '<제목>=keep' --decide '<제목>=defer'
```

- 결정 반영의 세부 줄은 `removed`·`override`·`deferred`(이 절과 rules 판이 두 벌로 로드되는 상태)·`unknown-decision`(분류 결과에 `modified` 절로 없어 반영하지 않음)·`ambiguous`·`index`·`gitignore` 입니다.
- 사용자 답을 받는 동안 `CLAUDE.md` 가 바뀌었으면 결정을 모두 버리고 `changed<TAB>CLAUDE.md 가 결정을 받는 동안 바뀌어 다시 묻습니다` 와 새 `modified` 줄을 냅니다. 사유를 알리고 새 diff 로 다시 묻습니다.
- 결정 없이 먼저 실행하지 않았으면 `결정 없이 먼저 실행하십시오` 와 함께 exit 2 입니다.
- 무인 실행이라 물을 수 없으면 `--decide` 를 넘기지 않습니다. `modified` 절은 원문 그대로 남고 다음 sync 에 다시 나옵니다.

### 7. Skill 재설치 · 8. Extension 재설치

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" reinstall
```

이 명령이 7단계와 8단계를 함께 합니다.

- 7단계: `bash rd-workflow/scripts/install_claude_skills.sh project` 를 실행합니다. copy 모드로 설치된 스킬이 템플릿과 다르면 기존 사본을 `.claude/skills-backup/<스킬>-<타임스탬프>/` 로 백업한 뒤 갱신합니다. 스킬을 프로젝트에서 직접 수정했다면 백업본에서 수정분을 병합하고, 확인이 끝나면 `.claude/skills-backup/` 을 지웁니다.
- 8단계: extension 설치 이력(`rd-workflow/config/extensions.json`)을 읽어 설치된 extension 을 묻지 않고 다시 설치하고, verify preset 을 머지하고, 매니페스트를 한 번 저장합니다. 규칙의 정본은 `rd-workflow/scripts/_tpl_reinstall.py` 입니다.
- 사용자에게 물을 항목은 묻지 않고 질문 줄로 냅니다. 답은 다음 실행의 인자로 넘깁니다.
- exit 0 은 정상입니다(질문 줄이 있어도 0). exit 2 는 허용하지 않는 `--preset` 이나 알 수 없는 인자입니다. exit 1 은 skill 설치·파일 쓰기 실패이며 stderr 에 `FAIL<TAB><대상><TAB><원인>` 을 냅니다.

출력 줄:

| 줄 | 뜻 |
| --- | --- |
| `skills<TAB>installed=N<TAB>refreshed=N<TAB>skipped=N` | skill 재설치 결과 |
| `auto<TAB><이름>` | 자동 재설치한 extension |
| `added<TAB><이름>` / `removed<TAB><이름>` | 매니페스트와 실제 설치 상태를 맞춰 추가·제거한 extension |
| `declined<TAB><이름>` | 이전에 안내했고 설치하지 않은 extension (다시 묻지 않음) |
| `failed<TAB><이름>[<TAB><원인>]` | 자동 재설치 실패 또는 `--failed` 로 받은 설치 실패 |
| `merge<TAB>added=…<TAB>kept=…<TAB>updated=…<TAB>requires_env=…<TAB>criteria+=…<TAB>criteria-=…<TAB>deleted=…` | verify preset 머지 요약 (`-` 는 없음) |
| `note<TAB><내용>` | presets 잔재 삭제, legacy presets 이전, `seen_*` 새로 기록·형식 오류 처리, settings 충돌 같은 알림 |
| `ask-ext<TAB><이름><TAB><설명>` | 설치 여부를 물을 새 extension |
| `ask-verifier<TAB><이름>` | 추가 여부를 물을 template verifier |
| `ask-preset<TAB><지금 값>` | 허용 목록 밖 preset — 키를 지웠고 다시 고르게 합니다 |

질문 줄의 답을 받으면 같은 명령을 답 인자와 함께 다시 실행합니다. 다시 실행해도 안전합니다.

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" reinstall --declined a,b --failed c --verifier-add x --verifier-skip y --preset <값>
```

#### 8.4 다시 묻지 않는 extension

`extensions.json` 최상위 `seen_extensions` 는 설치 여부를 안내한 적 있는 extension 이름의 누적 집합입니다. 설치한 것과 거절한 것을 모두 담습니다. 여기에 있는 extension 은 다시 묻지 않고 `declined` 줄로만 보고합니다. 템플릿에 새로 추가된 extension 만 `ask-ext` 로 나옵니다. manifest 는 있는데 이 키가 없으면(이 규칙 이전 설치본의 첫 update) 묻지 않고 지금 있는 extension 으로 키를 만듭니다.

#### 8.6 Verify preset 머지

manifest 에 `verify.preset` 이 있으면 템플릿 preset 의 `verification.json` 을 프로젝트 `rd-workflow/config/verification.json` 에 verifier 단위로 머지합니다. `run`·`adapter` 는 템플릿 값을, `evaluate` 는 프로젝트 값을 씁니다. `criteria` 는 이름으로 머지합니다. `requires_env` 는 프로젝트에 키가 없을 때만 템플릿 값을 더합니다. 필수 변수를 원하지 않으면 `"requires_env": []` 로 적습니다. 머지가 이 값을 유지합니다.

`extensions.verify.seen_verifiers` 는 이 프로젝트가 템플릿에서 받은 적 있는 verifier 이름의 누적 집합입니다. 템플릿에만 있는 verifier 가 이 집합에 있으면 사용자가 지운 것으로 보고 다시 넣지 않습니다(`merge` 줄의 `deleted=`). 이 집합이 없거나 형식 오류면 `ask-verifier` 로 묻습니다.

- 질문 문구: `템플릿 verifier '<이름>' 이 프로젝트 verification.json 에 없습니다. 추가할까요? (지운 것이면 건너뛰기 — 다음 update 부터는 묻지 않습니다)`
- 답: 추가는 `--verifier-add <이름>`, 건너뛰기는 `--verifier-skip <이름>` 입니다.
- 무인 실행(autopilot 등)이라 물을 수 없으면 답 인자 없이 끝냅니다. 스크립트는 그 verifier 를 추가하지 않고 `seen_verifiers` 를 만들지도 고치지도 않습니다. 완료 보고에 「확인 필요 — 기록이 없어 묻지 못하고 추가하지 않은 verifier: <이름>. 다음 대화형 `/tpl update` 에서 다시 묻습니다」 로 적습니다.
- 복원: 사용자가 지운 verifier 를 다시 받으려면 `extensions.json` 의 `seen_verifiers` 에서 그 이름을 빼고 `/tpl update` 를 실행합니다.

`ask-preset` 이 나오면 허용 목록(`react-web`·`api`·`cli`·`ios`·`macos`)에서 하나를 고르게 하고 `--preset <값>` 으로 넘깁니다.

#### 8.7 새 Extension 질문

`ask-ext` 줄이 있으면 사용자에게 묻습니다.

```
새로운 확장 기능이 감지되었습니다:
1. {name} — {설명}
...

설치할 확장을 선택하세요 (예: 1,2 또는 건너뛰기). 건너뛴 확장은 다음 update 부터 묻지 않습니다:
```

- 사용자가 고른 extension 은 `rd-workflow/extensions/{name}/install.md` 를 읽고 안내대로 설치합니다. `depends` 가 있으면 먼저 설치할지 묻습니다. 설치에 성공한 extension 은 인자로 넘기지 않습니다. 다시 실행한 `reinstall` 이 매니페스트에 넣습니다(`added` 줄).
- 건너뛴 extension 은 `--declined <이름>` 으로 넘깁니다. 다음 update 부터 묻지 않습니다.
- 설치를 골랐지만 실패하거나 중단된 extension 은 `--failed <이름>` 으로 넘깁니다. 다음 update 가 다시 묻습니다. 완료 보고에 「설치 실패 — <이름>: <원인 한 줄>. 다음 `/tpl update` 에서 다시 묻습니다. 바로 다시 하려면 『<이름> extension 설치해줘』」 로 적습니다. 자동 재설치 실패(`failed` 줄)로 다시 물은 extension 도 같습니다.
- 무인 실행이라 물을 수 없으면 답 인자 없이 끝냅니다. 스크립트는 그 extension 을 `seen_extensions` 에 넣지 않습니다. 완료 보고에 「확인 필요 — 묻지 못한 extension: <이름>. 다음 대화형 `/tpl update` 에서 다시 묻습니다」 로 적습니다. 응답 없음이 거절로 굳지 않게 하려는 규칙입니다.
- 복원: 설치하지 않은 extension 을 나중에 설치하려면 「<이름> extension 설치해줘」 로 요청합니다. 다음 update 에서 다시 질문을 받으려면 `extensions.json` 의 `seen_extensions` 에서 그 이름을 빼고 `/tpl update` 를 실행합니다.

### 9. 완료 보고

보고 항목:

- 복사/추가/삭제된 파일 수
- 마이그레이션 실행 여부와 결과
- M013 결과 — 걷어낸 절, 유지(override)한 절, 보류한 절, 두 벌 로드 여부(보류·`ambiguous`·`abort` 절이 남아 rules 와 함께 로드되는 상태인지), 다음 행동
- 보존된 파일 요약
- `rd-workflow/config/workflow.json` 의 5단계 복사 결과 — `신규 생성`(경로가 없어 배포본을 새로 두었습니다. 다음 작업부터 기본 실행 모드가 `semi-auto` 입니다) 또는 `기존 파일 보존`(경로가 있어 내용도 경로 종류도 손대지 않았습니다. 현재 판정 모드는 그 파일 내용이 정합니다). 이 결과는 복사 단계에 대한 것이며, 아래 `defect_report_upstream` 항목은 5.1 절이 같은 파일에 키 하나를 채운 별도 결과입니다
- `defect_report_upstream` 결과 — `설정됨: <값>` 또는 `미설정 — <사유>`(사유와 함께 수동 지정 방법을 적습니다: 결함 보고 발행 시 `--upstream <owner/repo>` 로 지정하거나 `rd-workflow/config/workflow.json` 에 직접 기입). 유도 실패로 보류했더라도 sync 자체는 끝까지 진행된 것이므로 실패가 아니라 이 항목으로 보고합니다
- Skill 재설치 결과 (설치/건너뛴 수)
- Extension 자동 재설치 결과 (자동 재설치/신규 설치/건너뛴 수)
- 묻지 않은 미설치 extension — `declined_extensions` 가 있을 때만 적습니다. 이름마다 「이전에 안내함 — 설치하려면 『<이름> extension 설치해줘』」 를 적습니다. 이번 update 가 `seen_extensions` 를 새로 만들었으면(기록 없음·형식 오류) 「`seen_extensions` 를 새로 기록함」 을 함께 적습니다. 무인 실행으로 묻지 못한 extension 은 8.7 의 「확인 필요」 문구로, 설치가 실패한 extension 은 8.7 의 「설치 실패」 문구로 적습니다
- Verify Preset 머지 결과 요약 (추가/보존/업데이트된 verifier, `requires_env` 를 더한 verifier, 변경된 criteria, 사용자가 지워 추가하지 않은 verifier, 기록이 없어 물어본 verifier 와 결과) — verify preset이 자동 재설치된 경우에만
- 템플릿 변경 이력 — 보고의 마지막 항목입니다. 아래 `changelog` 출력을 줄이지 않고 그대로 옮깁니다.

각 항목은 하위 명령의 출력 줄로 씁니다.

| 보고 항목 | 출처 |
| --- | --- |
| 덮어쓰기·추가·삭제·보존 수와 목록 | `apply` 의 `copied`·`added`·`deleted`·`skipped` 줄, `classify` 의 `keep` 줄 |
| 마이그레이션 결과 | `migrate pre`·`post` 의 항목 줄(`APPLIED`·`NOOP`·`ASK`·`NOTICE`·`FAIL`) |
| M013 결과 | `migrate post`·`migrate M013` 의 세부 줄 |
| `workflow.json` 복사 결과 | `classify` 의 그 경로 줄(`add` → `신규 생성`, `keep` → `기존 파일 보존`) |
| `defect_report_upstream` 결과 | 5.1 명령 출력 |
| skill 재설치 결과 | `reinstall` 의 `skills` 줄 |
| extension 결과 | `reinstall` 의 `auto`·`declined`·`ask-ext`·`failed` 줄과 사용자 답 |
| preset 머지 요약 | `reinstall` 의 `merge` 줄 |
| 실패·보류·미응답 항목, 원인, 재시도 방법 | 각 하위 명령의 `FAIL`·`ASK`·질문 줄. 재시도 방법은 4·6단계와 8.6·8.7 의 문구 |
| 템플릿 변경 이력 | `changelog` 출력 그대로 |

변경 이력은 동기화된 `rd-workflow/CHANGELOG.md` 에서 이전 VERSION 보다 뒤의 절을 골라 보입니다. 사용자가 CHANGELOG 를 열지 않아도 규칙 변경을 알게 하려는 단계입니다. CHANGELOG 를 읽기만 합니다.

```bash
bash "$C/rd-workflow/scripts/sync_template.sh" changelog
```

보고 예시:

```
템플릿 업데이트 완료 (2026-11-01-120000 → 2026-11-13-090000)

- 파일: 덮어쓰기 12 · 추가 3 · 삭제 1 (rd-workflow/docs/guides/old_guide.md)
- 보존: CLAUDE.md, PROJECT_CONTEXT.md, rd-workflow/config/verification.json 외 8개
  · FUTURE_REQUESTS.md — 보존 (A1 행 5개)
- 마이그레이션: M005 APPLIED — stale hook 1건 제거
  (removed: PreToolUse / Bash / bash rd-workflow/scripts/hooks/pre_commit_verify.sh). 나머지 NOOP
- M013: 걷어낸 절 2개(## 절대 규칙, ## Review 규칙). 보류 1개(## 커밋 메시지) —
  이 절과 rules 판이 두 벌로 로드되는 상태입니다. 다음 /tpl update 에서 다시 묻습니다
- workflow.json: 기존 파일 보존
- defect_report_upstream: 설정됨: example/rd-workflow
- Skill 재설치: 설치 1 · 갱신 0 · 건너뜀 22
- Extension: 자동 재설치 verify
  · 확인 필요 — 묻지 못한 extension: design-review. 다음 대화형 /tpl update 에서 다시 묻습니다
- Verify preset 머지: 구조 업데이트 lint, 그 밖 변화 없음

템플릿 변경 이력 (이전 VERSION 2026-11-01-120000 뒤의 절):
## 2026-11-13-090000
- …
```

보고 뒤 1단계에서 받은 임시 clone 디렉토리를 정리합니다:
```bash
rm -rf <임시 clone 경로의 부모 디렉토리>
```

## 기존 설치본 1회성 백필

대상은 한 번도 `/tpl update` 를 하지 않았거나 오래전 버전에 머문 설치본입니다.

절차는 `/tpl update` 를 한 번 실행하는 것입니다. M000 부터 M005, M008, M003 까지 이 가이드의 순서대로 처리됩니다. 별도 수작업이나 스크립트는 없습니다. 옛 표기 hook command 의 정규화와 같은 group 안 중복 정리는 M008 이 맡습니다.

### 적용 확인 (읽기 전용 점검)

점검은 파일을 바꾸지 않습니다. hook 에 의존하지 않으므로 hook 이 무력화된 환경에서도 프로젝트 루트에서 직접 실행할 수 있습니다.

문제로 보고하는 경우는 둘입니다.

- hook command 가 옛 표기 `bash rd-workflow/scripts/hooks/` 로 시작합니다.
- 같은 event, 같은 matcher group 안에 command 가 같은 항목이 둘 이상 있습니다.

다른 event 나 다른 group 에 같은 command 가 있는 경우와, `command` 가 없거나 문자열이 아닌 항목은 정상으로 봅니다.

출력과 exit code 는 다음과 같습니다.

| 상황 | 출력 | exit |
| --- | --- | --- |
| 문제 없음 | `OK` 한 줄 | 0 |
| 문제 있음 | 문제마다 `문제: <종류> <event> <command>` 한 줄 | 1 |
| `.claude/settings.json` 없음 | `해당 없음: .claude/settings.json 없음` | 0 |
| 깨진 JSON 또는 schema 오류 | `오류: <사유>` | 2 |

판정에 실패한 경우에는 `OK` 를 출력하지 않습니다.

```bash
python3 -c '
import json, sys
p = ".claude/settings.json"
OLD = "bash rd-workflow/scripts/hooks/"
try:
    with open(p, encoding="utf-8") as f:
        cfg = json.load(f)
except FileNotFoundError:
    print("해당 없음: .claude/settings.json 없음")
    sys.exit(0)
except Exception as e:
    print("오류: " + str(e))
    sys.exit(2)
def bad(msg):
    print("오류: " + msg)
    sys.exit(2)
if not isinstance(cfg, dict):
    bad("최상위가 객체가 아닙니다")
hooks = cfg.get("hooks", {})
if not isinstance(hooks, dict):
    bad("hooks 가 객체가 아닙니다")
problems = []
for event, groups in hooks.items():
    if not isinstance(groups, list):
        bad("%s 가 배열이 아닙니다" % event)
    for g in groups:
        if not isinstance(g, dict):
            bad("%s 의 group 이 객체가 아닙니다" % event)
        items = g.get("hooks", [])
        if not isinstance(items, list):
            bad("%s 의 group.hooks 가 배열이 아닙니다" % event)
        seen = set()
        for h in items:
            if not isinstance(h, dict):
                bad("%s 의 hook 항목이 객체가 아닙니다" % event)
            c = h.get("command")
            if not isinstance(c, str):
                continue
            if c.startswith(OLD):
                problems.append("문제: 옛표기 %s %s" % (event, c))
            if c in seen:
                problems.append("문제: 중복 %s %s" % (event, c))
            seen.add(c)
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("OK")
'
```

`문제:` 줄이 나오면 `/tpl update` 를 실행합니다.

## Raw Capture 마이그레이션 (기존 프로젝트)

본 sync 가 raw-captures 인프라를 도입한다. **capture 는 git 추적 대상이다** (정책 — 입력 원문을 백업·이력 보존). 기존 프로젝트는 다음을 적용:

1. **`raw-captures/` 디렉토리 + README 생성:**
   ```bash
   mkdir -p rd-workflow-workspace/raw-captures
   chmod 0700 rd-workflow-workspace/raw-captures
   # 본 sync 가 README 를 함께 가져오므로 별도 생성 불필요. sync 후 다음 검증:
   test -f rd-workflow-workspace/raw-captures/README.md
   ```

2. **이전에 raw-captures 를 `.gitignore` 로 제외했다면 그 2 라인을 제거** (추적 정책으로 전환):
   ```
   rd-workflow-workspace/raw-captures/*
   !rd-workflow-workspace/raw-captures/README.md
   ```
   제거 후 기존 capture 들이 추적 대상이 된다. 추적하고 싶지 않은 특정 capture 만 프로젝트 `.gitignore` 에 개별 추가한다.

### 보안 경고 — capture 가 추적되므로 secret 노출 위험 (중요)

capture 본문은 입력 원문이라 token / API key / password 가 포함될 수 있고, 추적·commit·push 되면 git history 에 영구 기록된다. **보안은 프로젝트 책임이다:**

1. **commit 전 검토:** 민감 capture 는 commit 전에 확인. 추적을 원치 않으면 프로젝트 `.gitignore` 에 개별 추가.
2. **이미 push 된 secret rotation 우선:** 노출된 token / API key / password 를 즉시 폐기 + 재발급. history rewrite 보다 rotation 이 안전 (이미 다른 곳에 캐시되었을 가능성).
3. **history rewrite (선택):** git filter-repo 또는 BFG Repo-Cleaner 로 history 에서 capture 파일 제거.
   - `git filter-repo --path rd-workflow-workspace/raw-captures/ --invert-paths`
   - 협업 repo 라면 모든 collaborator 가 fresh clone 필요 (force push 후 기존 clone 무효화)
4. **GitHub Secret Scanning** 활성화하여 향후 자동 감지.

3. **legacy capture frontmatter 변환** (구 형식 `fr-title` frontmatter 의 capture 가 있는 프로젝트):

   **Step 3-a: `fr-title` → `short-title` 자동 변환** (BSD·GNU sed 공용):
   ```bash
   # sed -i.bak 은 BSD·GNU 둘 다에서 동작합니다. 만든 .bak 은 바로 지웁니다.
   find rd-workflow-workspace/raw-captures -maxdepth 1 -type f -name "*.md" 2>/dev/null \
     | while IFS= read -r f; do
         sed -i.bak 's/^fr-title:/short-title:/' "$f" && rm -f "$f.bak"
       done
   ```

   **Step 3-b: `stage` 필드 추가** (수동 검토 후 적용 권장):

   legacy capture 가 모두 FR 등록 시점 생성분이면 (구 형식은 fr stage capture 만 생성) 아래 명령으로 `stage: fr` 일괄 삽입 가능. 여러 stage 가 혼재하거나 출처가 불분명하면 수동 편집 필수.

   ```bash
   # stage 필드가 없는 파일에 short-title 라인 직후 stage: fr 삽입 (BSD·GNU sed 공용)
   find rd-workflow-workspace/raw-captures -maxdepth 1 -type f -name "*.md" 2>/dev/null \
     | while IFS= read -r f; do
         if ! awk '/^---$/{c++; if(c==2)exit} c==1 && /^stage:/{found=1} END{exit !found}' "$f"; then
           sed -i.bak '/^short-title:/a\
   stage: fr
   ' "$f" && rm -f "$f.bak"
         fi
       done
   ```

   주의: `sed -i.bak '/^---$/a\...'` 는 파일 안의 모든 `---` 라인 다음에 삽입될 수 있으므로 결과를 반드시 검토할 것. frontmatter 외부에 `---` 가 있으면 수동 편집 권장.

   본 변환은 신 형식만 인식하는 runtime 코드와 호환을 맞춘다. runtime 호환 코드는 추가하지 않으므로 변환 누락 시 신 코드가 구 캡처를 인식 못 한다.

4. **`CURRENT_TASK.md` 에 `## Short Title` 섹션 추가** (default 값 `-`).

### 기존 raw-captures 권한 보정

기존 0644 capture / 0755 디렉토리 (이전 ambient umask 환경 생성분) 가 있다면:

```bash
find rd-workflow-workspace/raw-captures -type d -exec chmod 0700 {} +
find rd-workflow-workspace/raw-captures -type f ! -name 'README.md' -exec chmod 0600 {} +
```

README 는 추적 대상 — 기존 mode (보통 0644) 유지.
