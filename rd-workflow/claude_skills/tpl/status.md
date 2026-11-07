# /tpl status

현재 프로젝트의 템플릿 버전, 최신 원격 버전, verify 설정 상태, 앱 실행 절 상태를 표시한다.

## 절차

어느 분기도 4단계 출력 전에 끝나지 않는다. 1~3b단계는 값을 정하고 다음 단계로 간다.

### 1. 로컬 버전 읽기

`rd-workflow/VERSION` 파일을 읽어 현재 설치된 버전을 확인한다.

### 2. 원격 버전 확인

`PROJECT_CONTEXT.md`에서 `template_repo` 값을 읽는다. 결과를 `원격` 값으로 정하고 3단계로 간다. 조기 종료하지 않는다.

- 값이 비어있거나 placeholder면: `원격 = 미설정`. 원격 가져오기를 건너뛰고 3단계로 간다. 안내 문구("원격 비교를 하려면 `PROJECT_CONTEXT.md`에 `template_repo`를 설정하세요")는 4단계에서 함께 낸다.
- 값이 있으면: 원격 repo의 `rd-workflow/VERSION` 파일을 가져온다.

```bash
git archive --remote=<template_repo> HEAD rd-workflow/VERSION 2>/dev/null | tar -xO 2>/dev/null
```

실패하면 shallow clone으로 fallback:

```bash
tpl_tmp="$(mktemp -d)" || { echo "tpl status: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$tpl_tmp" && -d "$tpl_tmp" ]] || { echo "tpl status: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
git clone --depth 1 <template_repo> "$tpl_tmp" 2>/dev/null
cat "$tpl_tmp/rd-workflow/VERSION"
[[ -n "$tpl_tmp" ]] && rm -rf "$tpl_tmp"
```

둘 다 실패하면 `원격 = 확인 불가`로 정하고 3단계로 간다. 위 fallback 블록이 임시 디렉터리를 만들지 못해 비영 종료하는 경우도 "실패" 에 포함된다. 블록의 `exit 1` 은 그 명령 실행만 끝내며 이 절차를 끝내지 않는다.

### 3. verify 설정 상태

- `rd-workflow/claude_skills/verify/SKILL.md` 가 없으면 verify 줄을 만들지 않고 3b 단계로 간다.
- 있으면 `bash rd-workflow/extensions/verify/verify.sh --check` 를 실행하고, 종료 코드와 `verify-check:` 줄로 한 줄을 만든 뒤 3b 단계로 간다.

| 종료 코드 | 표시 |
|---|---|
| 0, attention=0 | `verify: 설정 완료` |
| 0, attention=M>0 | `verify: 설정 완료, 확인 필요 M건` |
| 2 | `verify: 설정 미완료 (N건) — bash rd-workflow/extensions/verify/verify.sh --check` |
| 3 | `verify: 설정 없음` |
| 1 | `verify: 점검 불가 (<출력 첫 줄>)` |

### 3b. 앱 실행 절 상태

`PROJECT_CONTEXT.md` 의 `## Run`·`## Feature Entry Paths` 두 절이 채워졌는지 판정한다. 이 판정 블록이 두 절 상태의 유일한 판정 수단이며, `tpl/update.md` 와 `WORKFLOW.md` 시제품 절이 이 블록을 가리킨다.

판정 규칙:

- `절 없음`: `PROJECT_CONTEXT.md` 가 없거나 그 제목 줄(`## Run` 또는 `## Feature Entry Paths`, 줄 전체 일치)이 없다.
- 절 경계(제목 줄과 다음 `## ` 줄)는 HTML 주석 밖의 줄만 센다. 주석 안의 `## ` 줄은 경계가 아니다.
- `미작성`: 제목 줄 다음부터 다음 `## ` 줄 전까지에서 HTML 주석(여러 줄 포함), 빈 줄, 공백을 뺀 내용이 `-` 뿐인 줄을 빼면 남는 줄이 없다.
- `작성됨`: 그 밖의 경우. "해당 없음" 한 줄도 `작성됨` 이다.

```bash
bash -s <<'RD_RUN_SECTIONS'
v="$(cat rd-workflow/VERSION 2>/dev/null)"
if [[ "$v" == lite-* ]]; then echo "skip=lite"; exit 0; fi
state() {
  local f="PROJECT_CONTEXT.md"
  if [[ ! -f "$f" ]]; then echo "절 없음"; return; fi
  awk -v h="## $1" '
    {
      line = $0; incmt = cmt
      while (1) {
        if (cmt) { i = index(line, "-->"); if (!i) { line = ""; break }; line = substr(line, i + 3); cmt = 0 }
        i = index(line, "<!--"); if (!i) break
        rest = substr(line, i + 4); j = index(rest, "-->")
        if (j) line = substr(line, 1, i - 1) substr(rest, j + 3)
        else { line = substr(line, 1, i - 1); cmt = 1; break }
      }
      if (!in_s) { if (!incmt && $0 == h) in_s = 1; next }
      if (line ~ /^## /) exit
      gsub(/[[:space:]]/, "", line)
      if (line != "" && line != "-") found = 1
    }
    END { print (!in_s ? "절 없음" : (found ? "작성됨" : "미작성")) }' "$f"
}
echo "run=$(state Run)"
echo "entry=$(state 'Feature Entry Paths')"
RD_RUN_SECTIONS
```

- 출력이 `skip=lite` 한 줄이면 앱 실행 줄을 만들지 않고 4단계로 간다.
- 그 밖에는 `앱 실행: Run <run 값>, Feature Entry Paths <entry 값>` 한 줄을 만든다.

### 4. 출력

모든 경로가 이 블록 하나로 끝난다.

```
rd-workflow 템플릿 상태:
- 로컬: <로컬 버전>
- 원격: <원격 버전 | 미설정 | 확인 불가>
- 상태: 최신 / 업데이트 가능 → /tpl update / 확인 불가
- 앱 실행: <3b 결과>          ← lite 면 줄 생략
- verify: <3단계 결과>          ← verify 미설치면 줄 생략
```

- 로컬 == 원격 → `최신`
- 로컬 < 원격 → `업데이트 가능 → /tpl update`
- 비교 불가(`원격 = 미설정`·`확인 불가` 포함) → `확인 불가`

`원격 = 미설정` 이면 블록 뒤에 `template_repo` 안내 한 줄을 붙인다.

`앱 실행` 줄의 두 값 중 `미작성`·`절 없음` 이 있으면 블록 뒤에 안내 한 줄을 붙인다: "`PROJECT_CONTEXT.md` 의 `## Run`·`## Feature Entry Paths` 절을 채우십시오. 양식은 배포 템플릿의 `PROJECT_CONTEXT.md` 에 있습니다."
