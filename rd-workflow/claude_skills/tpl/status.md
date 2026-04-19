# /tpl status

현재 프로젝트의 템플릿 버전과 최신 원격 버전을 비교하여 표시한다.

## 절차

### 1. 로컬 버전 읽기

`rd-workflow/VERSION` 파일을 읽어 현재 설치된 버전을 확인한다.

### 2. 원격 버전 확인

`PROJECT_CONTEXT.md`에서 `template_repo` 값을 읽는다.

- 값이 비어있거나 placeholder면: 로컬 버전만 출력하고 "원격 비교를 하려면 `PROJECT_CONTEXT.md`에 `template_repo`를 설정하세요" 안내 후 종료.
- 값이 있으면: 원격 repo의 `rd-workflow/VERSION` 파일을 가져온다.

```bash
git archive --remote=<template_repo> HEAD rd-workflow/VERSION 2>/dev/null | tar -xO 2>/dev/null
```

실패하면 shallow clone으로 fallback:

```bash
TMPDIR=$(mktemp -d)
git clone --depth 1 <template_repo> "$TMPDIR" 2>/dev/null
cat "$TMPDIR/rd-workflow/VERSION"
rm -rf "$TMPDIR"
```

둘 다 실패하면 "원격 버전을 확인할 수 없습니다" 출력 후 로컬 버전만 표시.

### 3. 출력

```
rd-workflow 템플릿 상태:
- 로컬: <로컬 버전>
- 원격: <원격 버전>
- 상태: 최신 / 업데이트 가능 / 확인 불가
```

- 로컬 == 원격 → `최신`
- 로컬 < 원격 → `업데이트 가능 → /tpl update`
- 비교 불가 → `확인 불가`
