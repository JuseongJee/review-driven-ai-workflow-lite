# /tpl diff

원격 템플릿과 로컬 프로젝트의 차이를 미리 보여줍니다. 실제 동기화는 하지 않습니다.

## 절차

### 1. 배포 repo URL 확보

`PROJECT_CONTEXT.md`에서 `template_repo` 값을 읽습니다.

- 값이 비어있거나 placeholder면: "원격 비교를 하려면 `PROJECT_CONTEXT.md`에 `template_repo`를 설정하세요" 출력 후 종료합니다.

### 2. 원격 clone

```bash
tpl_tmp="$(mktemp -d)" || { echo "tpl diff: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$tpl_tmp" && -d "$tpl_tmp" ]] || { echo "tpl diff: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
git clone --depth 1 <template_repo> "$tpl_tmp" 2>/dev/null
```

실패하면 "원격 repo를 가져올 수 없습니다" 출력 후 종료합니다.

### 3. 파일 비교

clone 의 스크립트로, 프로젝트 루트에서 분류합니다. `--no-save` 이므로 계획 파일을 쓰지 않습니다.

```bash
bash "$tpl_tmp/rd-workflow/scripts/sync_template.sh" classify --no-save
```

- 출력 줄은 `<분류><TAB><경로><TAB><근거>` 이고, 마지막 줄 `# 요약<TAB>update=N<TAB>add=N<TAB>delete=N<TAB>keep=N<TAB>ask=N<TAB>same=N` 이 분류별 개수입니다. 분류 기준은 `sync_template.md` 2단계입니다.
- `update` 는 변경됨, `add` 는 신규, `delete` 는 삭제됨, `ask` 는 판단 필요입니다. `same` 은 요약의 개수만 씁니다. `keep`(보존)은 비교 대상에서 뺍니다.
- exit 3(`ask<TAB>M001|M002<TAB>구조 마이그레이션 먼저`)이면 "구조 마이그레이션(M001·M002)이 남아 있어 비교하지 못했습니다. `/tpl update` 로 먼저 처리하십시오" 를 출력하고 5단계로 갑니다.
- 그 밖의 오류(exit 2)는 stderr 내용을 그대로 보이고 5단계로 갑니다.

### 4. 출력

```
rd-workflow 템플릿 diff:
- 로컬: <로컬 버전> / 원격: <원격 버전>

변경됨 (N개):
  M rd-workflow/claude_skills/foo/SKILL.md

신규 (N개):
  A rd-workflow/scripts/new_script.sh

삭제됨 (N개):
  D rd-workflow/docs/old_doc.md

판단 필요 (N개):
  ? <경로> — <근거>

동일: N개

업데이트하려면 → /tpl update
```

`update`·`add`·`delete`·`ask` 가 모두 0 이면:
```
rd-workflow 템플릿 diff: 변경 없음 (로컬이 최신)
```

### 5. 정리

```bash
[[ -n "$tpl_tmp" ]] && rm -rf "$tpl_tmp"
```

## 규칙

- 이 서브커맨드는 읽기 전용입니다. 프로젝트 파일을 수정하지 않습니다(`classify --no-save` 도 쓰지 않습니다).
- 사용자 보존 파일(`PROJECT_CONTEXT.md`, 보존 판정을 받은 `REQUEST.md` 등)은 `keep` 으로 분류되어 비교 대상에서 빠집니다.
