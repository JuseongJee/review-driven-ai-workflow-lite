# /tpl diff

원격 템플릿과 로컬 프로젝트의 차이를 미리 보여준다. 실제 동기화는 하지 않는다.

## 절차

### 1. 배포 repo URL 확보

`PROJECT_CONTEXT.md`에서 `template_repo` 값을 읽는다.

- 값이 비어있거나 placeholder면: "원격 비교를 하려면 `PROJECT_CONTEXT.md`에 `template_repo`를 설정하세요" 출력 후 종료.

### 2. 원격 clone

```bash
TMPDIR=$(mktemp -d)
git clone --depth 1 <template_repo> "$TMPDIR" 2>/dev/null
```

실패하면 "원격 repo를 가져올 수 없습니다" 출력 후 종료.

### 3. 파일 비교

`sync_template.md` 2단계(파일 분류)와 동일한 기준으로 비교한다. `sync_template.md`를 읽고 분류 기준을 따른다.

결과를 4가지로 분류:

- **변경됨**: 양쪽에 있고 내용이 다른 파일
- **신규**: 원격에만 있는 파일
- **삭제됨**: 원격에서 제거된 파일 (로컬에만 있고, 이전 동기화로 생성된 것)
- **동일**: 내용이 같은 파일 (개수만 표시)

### 4. 출력

```
rd-workflow 템플릿 diff:
- 로컬: <로컬 버전> / 원격: <원격 버전>

변경됨 (N개):
  M rd-workflow/claude_skills/foo/SKILL.md
  M CLAUDE.md

신규 (N개):
  A rd-workflow/scripts/new_script.sh

삭제됨 (N개):
  D rd-workflow/docs/old_doc.md

동일: N개

업데이트하려면 → /tpl update
```

변경된 파일이 없으면:
```
rd-workflow 템플릿 diff: 변경 없음 (로컬이 최신)
```

### 5. 정리

```bash
rm -rf "$TMPDIR"
```

## 규칙

- 이 서브커맨드는 읽기 전용이다. 프로젝트 파일을 수정하지 않는다.
- 사용자 보존 파일(`PROJECT_CONTEXT.md` 사용자 섹션, `REQUEST.md` 등)은 비교 대상에서 제외한다.
