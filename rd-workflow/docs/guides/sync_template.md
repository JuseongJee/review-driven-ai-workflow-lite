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
   - review 세션 `CHECKPOINT.md`의 `## Open Issues`는 canonical 마커 규약을 따라야 합니다 — 미해결 이슈가 없으면 정확히 `- 없음` 또는 `- None` 한 줄로만 표기합니다 (후행 마침표 1개 허용). 빈 섹션·비정형 표기는 미종결로 판정되어 archive가 차단됩니다.

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
- 스크립트가 템플릿 타입 불일치 또는 타입 미확정으로 중단(exit 1)하면:
  - 1차 대응: 배포 repo URL이 현재 프로젝트의 템플릿 타입(full/lite)과 맞는지 확인합니다. URL 혼동이면 올바른 URL로 재실행합니다.
  - 교차 sync 사고로 로컬 VERSION이 오염된 프로젝트의 복구처럼 의도한 교차 적용일 때만, 사용자에게 위험(현재 타입 전용 파일이 삭제 후보로 분류될 수 있음)을 안내하고 동의를 받은 뒤 `--allow-type-mismatch`를 붙여 재실행합니다. 이 플래그는 타입 불일치·미확정 케이스에서만 효력이 있고(해당 시 버전 비교도 생략), 타입이 일치하면 효과 없이 기존 버전 가드가 그대로 적용됩니다.
  - `--force`는 타입 불일치를 우회하지 못합니다 (같은 타입 내 다운그레이드 승인 전용).

배포 repo URL을 모르면 사용자에게 물어봅니다.

동기화 대상은 현재 작업 디렉토리 (프로젝트 루트)입니다.

### 2. 파일 분류

양쪽 디렉토리의 파일 목록을 비교해서 아래 4가지로 분류합니다.

**동기화 대상** — 템플릿 소스에 있고, 프로젝트에도 있고, 내용이 다른 파일:
- `CLAUDE.md`, `WORKING_WITH_AI.md`
- `rd-workflow/claude_skills/`
- `rd-workflow/config/` (설정 예제 파일)
- `rd-workflow/docs/` (adr, flows, guides, prompts, backlog 구조 문서)
- `rd-workflow/scripts/` 전체 — `rd`(task CLI), `_state_common.sh`, `_task_common.sh`, `lifecycle/`, `hooks/` 포함. 단, 아래 보존 목록의 `build/test/lint/typecheck.sh`는 제외

**신규 추가** — 템플릿에 있지만 프로젝트에 없는 파일

**삭제 후보** — 프로젝트에 있지만 템플릿에 없는 파일 중, 프로젝트 작업물이 아닌 것

**보존** — 절대 덮어쓰거나 지우지 않는 파일:
- `README.md` (프로젝트 고유 문서 — 배포 repo의 README는 GitHub 페이지 표시용이며 사용자 프로젝트에 적용 대상 아님)
- `PROJECT_CONTEXT.md`
- `REQUEST.md`, `CURRENT_TASK.md` (프로젝트 고유 내용이 있는 경우)
- `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` (항목이 있는 경우)
- `rd-workflow-workspace/backlog/request-archive/` 안의 아카이브 파일
- `rd-workflow-workspace/specs/`, `rd-workflow-workspace/plans/` 안의 작업 산출물 (README 제외)
- `rd-workflow/scripts/{build,test,lint,typecheck}.sh` (프로젝트별 명령이 들어 있음)
- `rd-workflow-workspace/handoffs/` 안의 작업 내용물
- `rd-workflow/config/review-tools.json` (프로젝트별 리뷰 도구 설정, `.example`은 동기화 대상)
- `rd-workflow/config/verification.json` (프로젝트별 검증 설정, `.example`은 동기화 대상)
- `rd-workflow/config/extensions.json` (설치된 extension 이력, `.example`은 동기화 대상)
- extension으로 설치된 스킬 `rd-workflow/claude_skills/<name>/` — `<name>`이 `rd-workflow/extensions/`의 extension 디렉토리 이름 또는 `extensions.json` 기재 항목과 일치하는 경우 (예: verify, design-review). extension 스킬 원본은 템플릿의 `extensions/`에 있고 clone의 `claude_skills/`에는 없어 삭제 후보 정의에 걸리지만, 삭제하면 8단계에서 미설치로 재판정되어 불필요한 재설치 질문이 발생하므로 보존한다 (최신본 갱신은 8단계 자동 재설치가 담당)
- 프로젝트 고유 설정 파일 (`.gitignore`, `.swiftlint.yml`, `.claude/` 등)
  - 단, `.claude/settings.json`의 hook 등록 목록과 `.gitignore`의 워크플로 관리 라인은 M003 마이그레이션이 **부재 항목만 추가**하고, 템플릿 유래 stale hook 등록(존재하지 않는 스크립트를 가리키는 항목)은 M005 마이그레이션이 제거합니다 (통째 동기화 아님 — 4단계 참조)

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

파일이 없으면 마이그레이션이 불필요합니다. 파일이 있으면 각 항목의 **조건**을 프로젝트에 대해 확인하고, 해당하는 항목을 순서대로 실행합니다. **M000(절차 권위 전환)은 목록의 다른 어떤 항목보다, 그리고 이 문서의 나머지 단계보다 먼저** 평가·실행합니다 — M000 조건에 해당하면 이 시점부터 clone된 sync_template.md가 절차 권위 문서입니다. 단, M005는 숫자 순서와 달리 **M003보다 먼저** 실행합니다 (stale hook 제거 후 부재 항목 추가).

단, **적용 시점**이 "동기화 후"로 명시된 항목(M004)은 이 단계에서 실행하지 않습니다 — 대상 파일(`rd-workflow/scripts/rd`)이 5단계 동기화로 처음 들어올 수 있으므로, 6단계에서 조건을 확인해 실행합니다.

아래는 현재 등록된 마이그레이션 내용의 사본입니다 (최신 버전은 항상 clone된 `MIGRATIONS.md`를 참조):

#### M000: sync 절차 문서 권위 전환

**조건**: 프로젝트의 sync 절차 문서(`rd-workflow/docs/guides/sync_template.md`, 구버전 구조면 `ai/docs/guides/sync_template.md`)가 clone된 템플릿의 `rd-workflow/docs/guides/sync_template.md`와 내용이 다르거나 프로젝트에 없을 때. 판별은 `cmp -s <로컬 경로> "<임시 clone 경로>/rd-workflow/docs/guides/sync_template.md"` (exit 0이 아니면 해당).

**실행 순서**: 다른 모든 마이그레이션 항목과 sync 절차 단계보다 **먼저** 평가·실행합니다.

**실행 절차**:
1. `<임시 clone 경로>/rd-workflow/docs/guides/sync_template.md`를 읽습니다.
2. 이 시점 이후의 **모든 동기화 절차(0단계 시점 확인부터 완료 보고까지)를 clone된 sync_template.md를 권위 문서로** 실행합니다. 프로젝트 로컬 절차 문서와 로컬 skill의 절차 요약은 이번 동기화에서 따르지 않습니다.
3. 로컬 절차 문서 기준으로 이미 수행한 단계(예: 파일 분류, 사용자 확인)가 있으면 clone 문서 기준으로 다시 수행합니다.
4. 나머지 마이그레이션 항목의 실행 순서·적용 시점 규칙(M005는 M003보다 먼저, M004는 동기화 후 등)은 이 항목 이후에도 clone된 `MIGRATIONS.md` 기준으로 유지됩니다.

**주의**:
- 이 항목은 파일을 변경하지 않는 **절차 지시**입니다. 프로젝트의 sync_template.md 파일 자체는 이후 동기화 단계에서 clone 내용으로 갱신됩니다.
- 대표 사례 (v1 → v2, VERSION 2026-06-09 배포본): v1 절차 문서는 스크립트 동기화 범위를 "review pipeline 관련"으로 한정하고, 보존 목록에 `README.md`가 없으며, 0단계(업그레이드 시점 확인)가 없습니다. v1 문서로 sync하면 v2에서 변경된 hooks/lifecycle 스크립트가 갱신되지 않아 task-state 마이그레이션(M004) 이후 active-fr을 읽는 구버전 스크립트가 오동작할 수 있고, 프로젝트 README가 배포 repo의 GitHub용 README로 덮일 수 있습니다.

#### M001: `ai/` → `rd-workflow/` 디렉토리 rename

**조건**: 프로젝트 루트에 `ai/` 디렉토���가 존재하고 `rd-workflow/`가 없을 때

**실행 절차**:
1. `git mv ai rd-workflow` (git 추적 중이면) 또는 `mv ai rd-workflow` (아니면)
2. 아래 파일들에서 `ai/` 경로 참조를 `rd-workflow/`로 일괄 치환:
   - `CLAUDE.md`, `PROJECT_CONTEXT.md`, `WORKING_WITH_AI.md`
   - `.claude/settings.json` (hooks 경로)
   - `rd-workflow/` 하위 스크립트, skill, 문서 파일
3. `rd-workflow-workspace/reports/`, `rd-workflow-workspace/backlog/request-archive/`, `rd-workflow-workspace/specs/`, `rd-workflow-workspace/handoffs/`는 과거 기록이므로 치환하지 않음
4. 치환 시 URL의 `.ai/` (예: `claude.ai/code`)는 보존해야 함 — `(?<!\.)ai/` 패턴 사용
5. 스크립트 문법 검증: `find rd-workflow/scripts -name "*.sh" -exec bash -n {} \;`

**주의**: `.claude/settings.json`의 hooks에 `ai/scripts/` 경로가 있으면 반드시 `rd-workflow/scripts/`로 변경해야 세션 시작 훅이 작동합니다.

#### M002: `rd-workflow/workspace/` → `rd-workflow-workspace/` 분리

**조건**: `rd-workflow/workspace/` 디렉토리가 존재하고 루트에 `rd-workflow-workspace/`가 없을 때

**실행 절차**:
1. `git mv rd-workflow/workspace rd-workflow-workspace` (git 추적 중이면) 또는 `mv rd-workflow/workspace rd-workflow-workspace`
2. 아래 파일들에서 `rd-workflow/workspace/` 경로 참조를 `rd-workflow-workspace/`로 일괄 치환:
   - `CLAUDE.md`, `PROJECT_CONTEXT.md`
   - `rd-workflow/` 하위 스크립트, skill, 문서 파일
3. `rd-workflow-workspace/reports/`, `rd-workflow-workspace/backlog/request-archive/`, `rd-workflow-workspace/specs/`, `rd-workflow-workspace/handoffs/`는 과거 기록이므로 치환하지 않음

**참고**: M001과 M002는 동시에 적용될 수 있습니다. M001을 먼저 실행한 후 M002를 실행합니다.

#### M003: v2 설정 파일 reconciliation (`.claude/settings.json` hooks + `.gitignore`)

**조건** (둘 중 하나라도 해당):
- 프로젝트 `.claude/settings.json`의 hooks에 clone된 템플릿 `.claude/settings.json`의 hook 항목이 하나 이상 없을 때
- 프로젝트 `.gitignore`에 clone된 템플릿 `.gitignore`의 유효 라인(빈 줄·주석 제외)이 하나 이상 없을 때

**실행 절차**:
1. 선행 검증: 프로젝트에 `.claude/settings.json`이 있으면 먼저 `python3 -m json.tool .claude/settings.json > /dev/null`로 parse를 검증합니다. 실패(깨진 JSON)하면 병합을 시도하지 않고 사용자에게 보고한 뒤 선택을 받습니다 — (a) 수동 복구 후 재시도, (b) 기존 파일을 `.claude/settings.json.bak`으로 백업하고 clone된 파일로 대체. 파일이 없으면(`.claude/` 디렉토리 부재 포함) `mkdir -p .claude && cp "<임시 clone 경로>/.claude/settings.json" .claude/`로 복사하고 2번(hooks 대조)을 건너뜁니다.
2. hooks 대조: clone된 템플릿 `.claude/settings.json`의 각 hook 항목(event → matcher → command 단위)을 프로젝트 `.claude/settings.json`과 대조하고, **부재 항목만** 같은 event/matcher 아래에 추가합니다.
3. `.gitignore` 대조: clone된 템플릿 `.gitignore`의 유효 라인별로 프로젝트 `.gitignore`에 정확 일치하는지 검사하고, **부재 라인만** 파일 끝에 추가합니다:
   ```bash
   while IFS= read -r line || [[ -n "$line" ]]; do
     [[ -z "$line" || "$line" == \#* ]] && continue
     grep -Fxq -- "$line" .gitignore || printf '%s\n' "$line" >> .gitignore
   done < "<임시 clone 경로>/.gitignore"
   ```
4. 사후 JSON 유효성 검증: `python3 -m json.tool .claude/settings.json > /dev/null`

**주의**:
- 프로젝트 고유 hook·permissions 등 **기존 항목은 수정·삭제하지 않습니다.** 대조는 추가 방향으로만 동작합니다.
- 대조 기준은 항상 clone된 템플릿 파일입니다 (full/lite 산출물 차이에 자동 정합).

#### M004: task-state 마이그레이션 트리거

**조건**: `rd-workflow-workspace/.lifecycle/task-state`가 없고 `rd-workflow/scripts/rd`가 존재할 때 (sync 직후의 pre-migration 상태)

**적용 시점**: 이 항목은 다른 항목과 달리 **동기화 실행(파일 복사) 이후**에 조건을 확인하고 실행합니다. 구버전 프로젝트에는 `rd-workflow/scripts/rd`가 이번 동기화로 처음 들어오므로, 동기화 전에 조건을 평가하면 건너뛰게 됩니다.

**실행 절차**:
1. `bash rd-workflow/scripts/rd task status`를 1회 실행합니다.
2. exit 0이고 `rd-workflow-workspace/.lifecycle/task-state`가 생성/존재하면 완료입니다. 마이그레이션이 수행되었다면(stderr 안내 출력) tracked 변경(active-fr 삭제·task-state 생성)을 다음 정규 커밋에 포함하라고 사용자에게 안내합니다.
3. exit 3이면 `CURRENT_TASK.md`의 `## Status`를 canonical 8종 중 하나로 수동 복구한 뒤 재실행합니다. 복구 절차는 `rd-workflow/docs/guides/task-state-guide.md`의 "실패 시 복구"를 참조합니다.

**주의**: 마이그레이션이 만든 변경은 자동 커밋하지 않습니다 ("다음 정규 커밋에 편승" 계약 — LC-20 archive clean 검증은 이 변경이 커밋된 상태를 전제합니다).

#### M005: 템플릿 유래 stale hook 제거 (`.claude/settings.json`)

**조건**: 프로젝트 `.claude/settings.json`에 아래 3가지를 모두 만족하는 hook 항목이 하나 이상 있을 때:

1. hook command 문자열이 `rd-workflow/scripts/hooks/` 하위 스크립트를 가리킨다 (템플릿 유래 항목 한정 — 그 외 경로의 프로젝트 고유 hook은 검사 대상이 아님)
2. 그 스크립트가 clone된 템플릿 산출물에 존재하지 않는다
3. 같은 event/matcher 아래 동일 command 문자열의 hook 항목이 clone된 템플릿 `.claude/settings.json`에도 존재하지 않는다

비교 단위는 M003과 동일한 event → matcher → command 3요소이며, 동일성은 command 문자열 전체의 정확 일치로 판단합니다.

**실행 순서**: M005는 **M003보다 먼저** 실행합니다 (제거 후 추가). 제거를 먼저 수행하면 M003이 대조할 프로젝트 상태가 깨끗해지고, M003이 방금 추가한 유효 항목을 재검사하지 않습니다.

**실행 절차**:
1. 선행 검증: 프로젝트에 `.claude/settings.json`이 없으면 M005는 해당 없음입니다. 있으면 `python3 -m json.tool .claude/settings.json > /dev/null`로 parse를 검증합니다. 실패(깨진 JSON)하면 제거를 시도하지 않고 사용자에게 보고합니다.
2. 아래 스니펫으로 제거 대상 식별·제거를 수행합니다 (프로젝트 루트에서 실행, `<임시 clone 경로>`를 실제 경로로 치환):
   ```bash
   python3 - "<임시 clone 경로>" <<'PY'
   import json, os, re, sys

   clone = sys.argv[1]
   proj_path = ".claude/settings.json"
   tpl_path = os.path.join(clone, ".claude/settings.json")

   with open(proj_path) as f:
       proj = json.load(f)

   tpl = {}
   if os.path.exists(tpl_path):
       with open(tpl_path) as f:
           tpl = json.load(f)

   def entry_set(cfg):
       out = set()
       for event, groups in (cfg.get("hooks") or {}).items():
           for g in groups:
               for h in g.get("hooks", []):
                   out.add((event, g.get("matcher", ""), h.get("command", "")))
       return out

   tpl_entries = entry_set(tpl)
   removed = []
   hooks = proj.get("hooks") or {}

   for event in list(hooks.keys()):
       for g in hooks[event]:
           kept = []
           for h in g.get("hooks", []):
               cmd = h.get("command", "")
               m = re.search(r'rd-workflow/scripts/hooks/[^\s"\']+', cmd)
               is_stale = (
                   m is not None
                   and not os.path.exists(os.path.join(clone, m.group(0)))
                   and (event, g.get("matcher", ""), cmd) not in tpl_entries
               )
               if is_stale:
                   removed.append((event, g.get("matcher", ""), cmd))
               else:
                   kept.append(h)
           g["hooks"] = kept
       hooks[event] = [g for g in hooks[event] if g.get("hooks")]
       if not hooks[event]:
           del hooks[event]

   if removed:
       with open(proj_path, "w") as f:
           json.dump(proj, f, indent=2, ensure_ascii=False)
           f.write("\n")
       for event, matcher, cmd in removed:
           print(f"removed: {event} / {matcher or '(matcher 없음)'} / {cmd}")
   else:
       print("removed: 없음")
   PY
   ```
3. 사후 JSON 유효성 검증: `python3 -m json.tool .claude/settings.json > /dev/null`
4. 스니펫이 출력한 제거 내역(event / matcher / command)을 사용자에게 보고합니다. `removed: 없음`이면 파일은 변경되지 않은 것입니다.

**예시 (대표 사례)**: 2026-08-20 게이트 정리 이전 템플릿으로 부트스트랩한 프로젝트에는 PreToolUse/Bash에 `bash rd-workflow/scripts/hooks/pre_commit_verify.sh` 등록이 남아 있으나, 그 스크립트는 지금 산출물에 존재하지 않고 템플릿 `.claude/settings.json`에도 등록이 없습니다. 3중 조건에 걸려 이 항목만 제거되고, 스크립트가 존재하는 나머지 hook 등록은 보존됩니다.

**주의**:
- 프로젝트 고유 hook(command가 `rd-workflow/scripts/hooks/` 하위를 가리키지 않는 항목)은 검사 대상이 아니며 절대 제거되지 않습니다.
- 스크립트가 clone에 존재하면 조건 2가 성립하지 않습니다 — full/lite 산출물 차이와 게이트 제거 여부에 자동 정합합니다.
- 대조 기준은 항상 clone된 템플릿 파일입니다.
- 제거가 수행되면 JSON 재직렬화로 들여쓰기가 2칸으로 정규화될 수 있습니다.

#### M007: 게이트 정리 — 값어치를 증명하지 못한 hook 제거

**조건**: VERSION 2026-08-20 이후 템플릿으로 동기화하는 모든 프로젝트.

**동작 변화**: 아래 hook 스크립트가 템플릿에서 사라집니다.

| 제거된 hook | 사라진 동작 |
|---|---|
| `hooks/pre_commit_verify.sh` | 커밋 전 staged 경로 기반 검증 실행·전수 검증 증명 대조 |
| `hooks/pre_commit_review_gate.sh` | diff review 미종결 중 archive 신호 커밋 차단 |
| `hooks/fr_branch_gate.sh` | 기본 브랜치 직접 커밋 차단 (`RD_LIFECYCLE_BYPASS_REASON` 우회) |
| `hooks/stop_task_save_reminder.sh` | 세션 종료 시 진행 상태 저장 넛지 |
| `hooks/edit_provenance_record.sh` + `_edit_provenance_common.sh` | 편집 출처 기록 (위 넛지의 판정 근거) |
| `hooks/implementation_gate.sh` 의 **단계 게이트** | 리뷰 대기 단계에서 구현 파일 수정 차단 |

**유지되는 것** (혼동 주의):
- `hooks/pre_commit_archive_gate.sh` — FR 미아카이브 커밋 차단. 그대로 동작합니다.
- `hooks/implementation_gate.sh` 의 **subagent 주체 게이트** — 병렬 구현자가 `CURRENT_TASK.md`·`REQUEST.md`·`task-state` 를 쓰는 것을 계속 차단합니다. hook 파일 자체는 남으므로 등록을 지우지 마십시오.
- `hooks/session_start.sh` — 그대로 동작합니다.
- `lifecycle/archive.sh` 의 `archive_review_precheck` — 아카이브 시점의 리뷰 종결성 검사이며 강화도 완화도 하지 않았습니다. (같은 자리에 있던 `archive_selftest_gate` 는 2026-09-03 에 제거했습니다.)

**실행 절차**:
1. `.claude/settings.json` 의 stale hook 등록 제거는 **M005 가 그대로 처리합니다.** 제거된 5개 스크립트는 clone 에 존재하지 않고 템플릿 `.claude/settings.json` 에도 등록이 없으므로 M005 의 3중 조건에 걸립니다. M007 을 위해 따로 스니펫을 돌릴 필요가 없습니다.
2. M005 실행 후 `.claude/settings.json` 의 `Stop` · `PostToolUse` 이벤트가 비어 남을 수 있습니다. M005 스니펫이 빈 event 를 지우므로 추가 조치는 불필요합니다.
3. 런타임 잔여물 정리 (선택, 판정에 영향 없음):
   - `rd-workflow-workspace/.lifecycle/verify-cache`
   - `rd-workflow-workspace/.lifecycle/edit-provenance.d/`
   두 항목은 `.gitignore` 에 그대로 남겨 두었습니다 — 지우지 않고 두어도 아카이브 게이트를 막지 않습니다.

**주의**:
- **`RD_LIFECYCLE_BYPASS_REASON=<reason>` 접두는 lifecycle 스크립트에 그대로 남아 있습니다.** 읽는 hook 이 사라져 템플릿 안에서는 무의미하지만, 아직 동기화하지 않은 다른 프로젝트·worktree 에 hook 사본이 남아 있을 수 있어 제거하지 않았습니다.
- 단계 게이트가 사라졌으므로 "리뷰 대기 중에는 구현 파일을 못 고친다" 는 **더 이상 기계가 강제하지 않습니다.** `CLAUDE.md` 의 Review 규칙을 사람과 AI 가 지킵니다.

### 5. 동기화 실행

사용자 확인 후:
- 변경된 템플릿 파일을 프로젝트에 복사합니다
- 신규 파일을 추가합니다
- 확인받은 삭제 후보를 제거합니다

### 5.1 defect_report_upstream 자동 채우기

결함 보고서를 보낼 대상 저장소를 배포 repo URL 에서 유도해 채웁니다.
**이미 값이 있으면 건드리지 않습니다** — 사용자가 의도적으로 지정한 값(예: 개인 저장소)이
업그레이드 때마다 덮어써지면 안 되기 때문입니다.

```bash
bash rd-workflow/scripts/defect_reports.sh set-upstream "<배포 repo URL>"
```

- 값이 비어 있으면 canonical 값(`owner/repo` 또는 `host/owner/repo`)을 기록합니다.
- 이미 값이 있으면 "이미 설정됨" 을 출력하고 원본을 유지합니다.
- URL 문법을 지원하지 않으면 아무것도 쓰지 않고 보류합니다. 잘못된 대상에 추측 발행하지
  않기 위함이며, 이 경우 결함 보고 전달은 미전달 목록에 남습니다.
- **`rd-workflow/config/workflow.json` 이 없으면 이 단계를 건너뜁니다.** 설정 파일을 새로
  만들지 않습니다 — 파일 부재는 `CLAUDE.md` 가 규정한 정상 상태입니다. 이 경우 결함 보고
  전달은 발행 시 `--upstream <owner/repo>` 수동 지정에 의존합니다.
- config 부재에서의 각 서브커맨드 동작: `set-upstream` 은 안내 후 **성공 종료**(무변경),
  `preview`·`publish` 는 전달 대상을 빈 값으로 보고 **미전달로 남깁니다**. 세 경우 모두
  파일을 만들지 않습니다.

### 6. 검증 및 버전 갱신

동기화 후 임시 clone의 템플릿 파일과 프로젝트 파일이 일치하는지 확인합니다. (보존 대상 제외)

이어서 적용 시점이 "동기화 후"인 마이그레이션(M004)을 실행합니다: `rd-workflow-workspace/.lifecycle/task-state`가 없으면 `bash rd-workflow/scripts/rd task status`를 1회 실행하고, 판정과 후속 조치는 clone된 `MIGRATIONS.md`의 M004 항목을 따릅니다.

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

### 7. Skill 재설치

`rd-workflow/claude_skills/`가 동기화되었으므로 `.claude/skills/`에도 반영합니다.

```bash
bash rd-workflow/scripts/install_claude_skills.sh project
```

- link 모드로 설치된 기존 스킬: 파일 내용은 symlink으로 자동 반영되고, **새로 추가된 스킬**은 이 실행에서 함께 설치됩니다.
- copy 모드로 설치된 기존 스킬: 템플릿과 내용이 다르면 기존 사본을 `.claude/skills-backup/<스킬>-<타임스탬프>/`로 백업한 뒤 자동 갱신됩니다 (`refreshed:` 출력). 스킬을 프로젝트에서 직접 수정했다면 백업본에서 수정분을 병합하세요.
- 백업 정리: 백업 내용 확인·병합이 끝나면 `.claude/skills-backup/`을 삭제하세요. 이 디렉토리는 템플릿 `.gitignore` 대상(로컬 병합용 임시 산출물)이라 커밋되지 않지만, 잔존 백업은 다음 갱신 시 혼동 요인이 됩니다.
- 최신 상태인 스킬은 자동으로 건너뛰므로 항상 실행해도 안전합니다.

**이 단계를 완료한 뒤 반드시 8단계로 진행합니다.**

### 8. Extension 자동 재설치 및 신규 안내

동기화 후 extension 설치 이력(`rd-workflow/config/extensions.json`)을 기반으로 자동 재설치하고, 새 extension만 사용자에게 안내합니다.

#### 8.1 매니페스트 읽기

`rd-workflow/config/extensions.json`을 읽고 파싱합니다.

- 파일 없음 → `manifest = null`
- JSON 파싱 실패 → `manifest = null` (손상된 매니페스트는 부재와 동일하게 처리)

#### 8.1.1 Legacy presets 마이그레이션

manifest에 `extensions.presets`가 있으면 1회 이전을 수행합니다:

**Case A: `extensions.presets.preset` 값이 있고 `extensions.verify`도 있음**
→ `extensions.verify.preset`으로 값 복사 후 `extensions.presets` 키 삭제

**Case B: `extensions.presets.preset` 값이 있지만 `extensions.verify`가 없음 (orphan)**
→ verify가 실제 설치되어 있으면(`rd-workflow/claude_skills/verify/SKILL.md` 존재) `extensions.verify` object를 생성(`installed_at: now`)하고 preset을 이전 후 `extensions.presets` 키 삭제
→ verify가 미설치면 `extensions.presets` 키를 삭제하고 `new_extensions`로 내려 사용자에게 verify + preset 설치를 질문

**Case C: `extensions.presets`는 있지만 `preset` 값이 없음**
→ `extensions.presets` 키를 삭제. preset 선택은 질문하지 않음

**Invalid preset validation:**
모든 Case에서 preset 값이 허용 목록(`react-web`, `api`, `cli`, `ios`, `macos`) 밖이면 해당 키를 삭제하고 사용자에게 preset 선택을 질문합니다.

**파일시스템 마이그레이션:**
프로젝트에 `rd-workflow/extensions/presets/`가 남아 있으면 `rd-workflow/extensions/verify/presets/`로 통합된 구버전 잔재이므로 삭제합니다. 삭제 전 별도 질문 없이 진행하되, 완료 보고에 "presets → verify/presets 통합으로 구 폴더 삭제됨"을 포함합니다.

이전 결과는 메모리에 보관 (8.8에서 저장)

#### 8.2 파일시스템 상태 스캔

`rd-workflow/extensions/` 내 각 extension 디렉토리에 대해 설치 여부를 확인합니다.

설치 판정 기준 (extension별로 다름):
- **verify, design-review**: `rd-workflow/claude_skills/{name}/SKILL.md`가 존재하면 설치됨. 디렉토리만 있고 SKILL.md가 없으면 미설치.

두 집합을 구성합니다:
- `fs_installed`: 위 판정 기준에 따라 설치된 것으로 확인된 extension
- `fs_available`: `rd-workflow/extensions/` 내 모든 extension 디렉토리

#### 8.3 매니페스트-파일시스템 조정

`manifest != null`일 때만 실행합니다.

**파일시스템 판정 가능 extension (verify, design-review):**

| manifest | filesystem | 동작 |
|----------|-----------|------|
| 있음 | 설치됨 | 유지 (자동 재설치 대상) |
| 있음 | 미설치 | manifest에서 제거 (삭제/손상된 것으로 판단) |
| 없음 | 설치됨 | manifest에 추가 (`installed_at: now`) |

조정 결과는 메모리에 보관합니다 (파일 저장은 8.8에서 한 번만).

#### 8.4 분류

- `manifest != null`: `auto_reinstall` = manifest에 있는 extension, `new_extensions` = `fs_available` 중 manifest에도 `fs_installed`에도 없는 것
- `manifest == null`: `fs_installed`에 있는 extension은 `auto_reinstall`로, 나머지는 `new_extensions`로 분류합니다. 매니페스트가 없어도 이미 설치된 extension에 대해서는 불필요한 질문을 하지 않습니다.

#### 8.5 자동 재설치

`auto_reinstall`에 속한 extension을 **묻지 않고** 재설치합니다.

- **verify, design-review**: `rd-workflow/extensions/{name}/SKILL.md`와 `rules.md`를 `rd-workflow/claude_skills/{name}/`에 복사 (덮어쓰기)
- **verify의 preset 머지**: manifest에 `verify.preset` 값이 있고 허용 목록 내이면 8.6 머지 알고리즘 실행. 값이 허용 목록 밖이면 키를 삭제하고 사용자에게 질문. 값이 없으면 머지를 건너뛰고 조용히 유지 (preset 없는 verify는 정상 상태이므로 질문하지 않음)

자동 재설치 실패 시: 해당 extension을 manifest에서 제거하고 `new_extensions`로 이동하여 8.7에서 사용자에게 질문합니다.

각 성공한 extension의 `installed_at`을 현재 시각으로 갱신합니다 (메모리).

#### 8.6 Verify Preset AI 자동 머지

manifest의 `verify.preset` 값이 기록되어 있을 때 실행합니다.

**입력:**
- template preset: `rd-workflow/extensions/verify/presets/{manifest.verify.preset}/verification.json`
- project current: `rd-workflow/config/verification.json`

**머지 규칙 (2-way):**

각 verifier를 name 기준으로 비교합니다:

| template | project | 결과 |
|----------|---------|------|
| 있음 | 있음 | **구조적 머지** (아래 참조) |
| 있음 | 없음 | template에서 추가 |
| 없음 | 있음 | **프로젝트 고유 항목 — 유지** |

**구조적 머지 (양쪽 모두 있는 verifier):**
- `run`: template 값 사용 (CLI 플래그, 버그 수정 반영)
- `adapter`: template 값 사용 (경로 변경 반영)
- `evaluate`: project 값 유지 (사용자 커스텀 보존)
- `criteria`: name 기준 머지
  - project에 있고 template에도 있는 name → project 값 유지 (커스텀 weight/description 보존)
  - template에만 있는 name → 추가
  - project에만 있는 name → template에서 삭제된 것으로 판단, 제거

머지 결과를 `rd-workflow/config/verification.json`에 저장합니다.

**머지 요약을 기록합니다** (9단계 완료 보고에 포함):
- 추가된 verifier
- 보존된 프로젝트 고유 verifier
- 구조 업데이트된 verifier (run/adapter 변경)
- 추가/제거된 criteria

#### 8.7 새 Extension 질문

`new_extensions`가 있을 때만 실행합니다.

프로젝트에 아직 설치되지 않은 extension을 사용자에게 안내합니다:

```
새로운 확장 기능이 감지되었습니다:
1. {name} — {설명}
...

설치할 확장을 선택하세요 (예: 1,2 또는 건너뛰기):
```

사용자가 선택하면 해당 extension의 `rd-workflow/extensions/{name}/install.md`를 읽고 안내에 따라 설치합니다.
`depends`가 있으면 먼저 설치할지 물어봅니다.

설치 성공한 extension을 manifest에 추가합니다 (메모리). 거절한 extension은 추가하지 않습니다 (다음 sync에서 다시 질문).

#### 8.8 매니페스트 저장

최종 manifest를 `rd-workflow/config/extensions.json`에 저장합니다.

- **생략 분기**: manifest가 null이고 `fs_available`이 공집합이면(예: lite 산출물 — `rd-workflow/extensions/` 부재) 매니페스트 파일을 생성하지 않습니다. 기록할 extension이 없는 빈 매니페스트는 무의미하고 혼란 요인입니다.
- manifest가 null이었고 사용자가 모든 extension을 건너뛰어도, `fs_available`이 비어 있지 않으면 `fs_installed` 기준으로 manifest를 생성합니다 (다음 sync에서 다시 묻지 않도록)
- 이 시점에서 1회만 파일에 기록합니다 (중간 저장 없음)

### 9. 완료 보고

- 복사/추가/삭제된 파일 수
- 마이그레이션 실행 여부와 결과
- 보존된 파일 요약
- Skill 재설치 결과 (설치/건너뛴 수)
- Extension 자동 재설치 결과 (자동 재설치/신규 설치/건너뛴 수)
- Verify Preset 머지 결과 요약 (추가/보존/업데이트된 verifier, 변경된 criteria) — verify preset이 자동 재설치된 경우에만

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

   **Step 3-a: `fr-title` → `short-title` 자동 변환** (macOS BSD sed 기준):
   ```bash
   # macOS BSD sed: sed -i ''
   # GNU sed (Linux): sed -i (빈 인수 없이)
   find rd-workflow-workspace/raw-captures -maxdepth 1 -type f -name "*.md" 2>/dev/null \
     | while IFS= read -r f; do
         sed -i '' 's/^fr-title:/short-title:/' "$f"
       done
   ```

   **Step 3-b: `stage` 필드 추가** (수동 검토 후 적용 권장):

   legacy capture 가 모두 FR 등록 시점 생성분이면 (구 형식은 fr stage capture 만 생성) 아래 명령으로 `stage: fr` 일괄 삽입 가능. 여러 stage 가 혼재하거나 출처가 불분명하면 수동 편집 필수.

   ```bash
   # stage 필드가 없는 파일에 short-title 라인 직후 stage: fr 삽입 (macOS BSD sed 기준)
   find rd-workflow-workspace/raw-captures -maxdepth 1 -type f -name "*.md" 2>/dev/null \
     | while IFS= read -r f; do
         if ! awk '/^---$/{c++; if(c==2)exit} c==1 && /^stage:/{found=1} END{exit !found}' "$f"; then
           sed -i '' '/^short-title:/a\
   stage: fr
   ' "$f"
         fi
       done
   ```

   주의: `sed -i '' '/^---$/a\...'` 는 파일 안의 모든 `---` 라인 다음에 삽입될 수 있으므로 결과를 반드시 검토할 것. frontmatter 외부에 `---` 가 있으면 수동 편집 권장.

   본 변환은 신 형식만 인식하는 runtime 코드와 호환을 맞춘다. runtime 호환 코드는 추가하지 않으므로 변환 누락 시 신 코드가 구 캡처를 인식 못 한다.

4. **`CURRENT_TASK.md` 에 `## Short Title` 섹션 추가** (default 값 `-`).

### 기존 raw-captures 권한 보정

기존 0644 capture / 0755 디렉토리 (이전 ambient umask 환경 생성분) 가 있다면:

```bash
find rd-workflow-workspace/raw-captures -type d -exec chmod 0700 {} +
find rd-workflow-workspace/raw-captures -type f ! -name 'README.md' -exec chmod 0600 {} +
```

README 는 추적 대상 — 기존 mode (보통 0644) 유지.
