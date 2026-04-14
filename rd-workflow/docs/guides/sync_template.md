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

### 1. 버전 확인 및 템플릿 소스 확보

먼저 버전 가드 스크립트를 실행합니다.

```bash
bash rd-workflow/scripts/sync_template.sh <배포 repo URL>
```

- 스크립트가 정상 종료(exit 0)하면 마지막 줄에 출력된 임시 clone 경로를 사용합니다.
- 스크립트가 다운그레이드 경고로 중단(exit 1)하면:
  - 사용자에게 "현재 프로젝트의 템플릿이 원격보다 최신입니다. 강제로 다운그레이드하시겠습니까?" 확인
  - 사용자가 동의하면 `--force`를 붙여 재실행
  - 사용자가 거부하면 동기화 중단

배포 repo URL을 모르면 사용자에게 물어봅니다.

동기화 대상은 현재 작업 디렉토리 (프로젝트 루트)입니다.

### 2. 파일 분류

양쪽 디렉토리의 파일 목록을 비교해서 아래 4가지로 분류합니다.

**동기화 대상** — 템플릿 소스에 있고, 프로젝트에도 있고, 내용이 다른 파일:
- `CLAUDE.md`, `WORKING_WITH_AI.md`
- `rd-workflow/claude_skills/`
- `rd-workflow/config/` (설정 예제 파일)
- `rd-workflow/docs/` (adr, flows, guides, prompts, backlog 구조 문서)
- `rd-workflow/scripts/` (보존 대상 제외)

**신규 추가** — 템플릿에 있지만 프로젝트에 없는 파일

**삭제 후보** — 프로젝트에 있지만 템플릿에 없는 파일 중, 프로젝트 작업물이 아닌 것

**보존** — 절대 덮어쓰거나 지우지 않는 파일:
- `PROJECT_CONTEXT.md`
- `REQUEST.md`, `CURRENT_TASK.md` (프로젝트 고유 내용이 있는 경우)
- `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` (항목이 있는 경우)
- `rd-workflow-workspace/backlog/request-archive/` 안의 아카이브 파일
- `rd-workflow-workspace/specs/`, `rd-workflow-workspace/plans/` 안의 작업 산출물 (README 제외)
- `rd-workflow/scripts/verify.sh` (프로젝트별 검증 명령이 들어 있음)
- `rd-workflow-workspace/handoffs/` 안의 작업 내용물
- `rd-workflow/docs/prompts/verify/` (프로젝트별 검증 프롬프트 커스터마이징)
- `rd-workflow/config/review-tools.json` (프로젝트별 리뷰 도구 설정, `.example`은 동기화 대상)
- 프로젝트 고유 설정 파일 (`.gitignore`, `.claude/` 등)

### 3. 사용자 확인

분류 결과를 사용자에게 보여주고 확인을 받습니다.

보여줄 내용:
- 내용이 바뀌어서 덮어쓸 파일 목록
- 새로 추가할 파일 목록
- 삭제할 파일 목록 (있다면)
- 보존할 파일 요약

### 4. 구조 마이그레이션 감지

동기화 실행 전에, **clone된 템플릿의** 마이그레이션 목록을 읽고 프로젝트에 적용할 항목이 있는지 확인합니다.

> **중요**: 마이그레이션 목록은 반드시 **clone된 템플릿** 쪽에서 읽습니다. 프로젝트 자체 문서는 구버전일 수 있으므로 참조하지 않습니다.

마이그레이션 파일 위치 (clone 경로 기준):
- `<임시 clone 경로>/rd-workflow/MIGRATIONS.md` (현재 구조)
- `<임시 clone 경로>/ai/MIGRATIONS.md` (구버전 구조 — fallback)

파일이 없으면 마이그레이션이 불필요합니다. 파일이 있으면 각 항목의 **조건**을 프로젝트에 대해 확인하고, 해당하는 항목을 순서대로 실행합니다.

### 5. 동기화 실행

사용자 확인 후:
- 변경된 템플릿 파일을 프로젝트에 복사합니다
- 신규 파일을 추가합니다
- 확인받은 삭제 후보를 제거합니다

### 6. settings.json Hook 머지

`.claude/settings.json`은 보존 대상이므로 5단계에서 덮어쓰지 않습니다. 대신 이 단계에서 템플릿의 새 hook 엔트리를 프로젝트에 머지합니다.

**입력:**
- 템플릿: `<임시 clone 경로>/.claude/settings.json`
- 프로젝트: `.claude/settings.json`

**머지 규칙:**

1. 템플릿 settings.json이 없으면 건너뜁니다.
2. 프로젝트 settings.json이 없으면 템플릿 것을 그대로 복사합니다.
3. 양쪽 모두 있으면 `hooks` 객체를 이벤트별로 머지합니다:

| 이벤트 (SessionStart, PreToolUse 등) | 템플릿 | 프로젝트 | 동작 |
|---|---|---|---|
| 있음 | 있음 | matcher별로 hook command 합집합 (아래 참조) |
| 있음 | 없음 | 템플릿 엔트리 추가 |
| 없음 | 있음 | 프로젝트 엔트리 유지 |

**matcher별 hook command 합집합:**
- matcher가 없는 엔트리 (SessionStart 등): 양쪽의 hooks 배열에서 `command` 문자열이 같으면 중복, 다르면 추가
- matcher가 있는 엔트리 (PreToolUse 등): 같은 matcher 값끼리 hooks 배열의 `command` 합집합. 프로젝트에 없는 matcher는 통째로 추가

4. 머지 결과를 `.claude/settings.json`에 저장합니다.

**보고:**
- 추가된 hook이 있으면: "settings.json에 N개 hook 추가됨: [command 목록]"
- 변경 없으면: "settings.json hook 구성은 변경없음"

### 7. 검증 및 버전 갱신

동기화 후 임시 clone의 템플릿 파일과 프로젝트 파일이 일치하는지 확인합니다. (보존 대상 제외)

원격 템플릿의 VERSION을 프로젝트에 복사합니다 (이미 동기화 과정에서 복사되었다면 건너뜀):

```bash
# 구버전 배포 repo는 ai/VERSION일 수 있음
if [[ -f "<임시 clone 경로>/rd-workflow/VERSION" ]]; then
  cp <임시 clone 경로>/rd-workflow/VERSION rd-workflow/VERSION
elif [[ -f "<임시 clone 경로>/ai/VERSION" ]]; then
  cp <임시 clone 경로>/ai/VERSION rd-workflow/VERSION
fi
```

검증과 버전 갱신이 끝나면 1단계에서 받은 임시 clone 디렉토리를 정리합니다:
```bash
rm -rf <임시 clone 경로의 부모 디렉토리>
```

### 8. Skill 재설치

`rd-workflow/claude_skills/`가 동기화되었으므로 `.claude/skills/`에도 반영합니다.

```bash
bash rd-workflow/scripts/install_claude_skills.sh project
```

- link 모드로 설치된 기존 스킬: 파일 내용은 symlink으로 자동 반영되지만, **새로 추가된 스킬**은 symlink이 없으므로 재설치가 필요합니다.
- copy 모드로 설치된 기존 스킬: 스크립트가 기존 디렉토리를 건너뛰므로, 먼저 `.claude/skills/` 아래의 해당 디렉토리를 삭제한 뒤 재실행해야 합니다.
- 새로 추가된 스킬은 link/copy 모드 모두에서 자동 설치됩니다.

### 9. 완료 보고

- 복사/추가/삭제된 파일 수
- 마이그레이션 실행 여부와 결과
- 보존된 파일 요약
- settings.json Hook 머지 결과 (추가된 hook 수, 또는 변경없음)
- Skill 재설치 결과 (설치/건너뛴 수)
