# Migrations

템플릿 구조 변경 시 기존 프로젝트에 적용할 마이그레이션 목록.
`sync_template.md` Step 4에서 이 파일(**clone된 템플릿의 사본**)을 읽고 해당하는 항목을 실행합니다.

---

## M000: sync 절차 문서 권위 전환

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

## M001: `ai/` → `rd-workflow/` 디렉토리 rename

**조건**: 프로젝트 루트에 `ai/` 디렉토리가 존재하고 `rd-workflow/`가 없을 때

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

## M002: `rd-workflow/workspace/` → `rd-workflow-workspace/` 분리

**조건**: `rd-workflow/workspace/` 디렉토리가 존재하고 루트에 `rd-workflow-workspace/`가 없을 때

**실행 절차**:
1. `git mv rd-workflow/workspace rd-workflow-workspace` (git 추적 중이면) 또는 `mv rd-workflow/workspace rd-workflow-workspace`
2. 아래 파일들에서 `rd-workflow/workspace/` 경로 참조를 `rd-workflow-workspace/`로 일괄 치환:
   - `CLAUDE.md`, `PROJECT_CONTEXT.md`
   - `rd-workflow/` 하위 스크립트, skill, 문서 파일
3. `rd-workflow-workspace/reports/`, `rd-workflow-workspace/backlog/request-archive/`, `rd-workflow-workspace/specs/`, `rd-workflow-workspace/handoffs/`는 과거 기록이므로 치환하지 않음

**참고**: M001과 M002는 동시에 적용될 수 있습니다. M001을 먼저 실행한 후 M002를 실행합니다.

## M003: v2 설정 파일 reconciliation (`.claude/settings.json` hooks + `.gitignore`)

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

## M004: task-state 마이그레이션 트리거

**조건**: `rd-workflow-workspace/.lifecycle/task-state`가 없고 `rd-workflow/scripts/rd`가 존재할 때 (sync 직후의 pre-migration 상태)

**적용 시점**: 이 항목은 다른 항목과 달리 **동기화 실행(파일 복사) 이후**에 조건을 확인하고 실행합니다. 구버전 프로젝트에는 `rd-workflow/scripts/rd`가 이번 동기화로 처음 들어오므로, 동기화 전에 조건을 평가하면 건너뛰게 됩니다.

**실행 절차**:
1. `bash rd-workflow/scripts/rd task status`를 1회 실행합니다.
2. exit 0이고 `rd-workflow-workspace/.lifecycle/task-state`가 생성/존재하면 완료입니다. 마이그레이션이 수행되었다면(stderr 안내 출력) tracked 변경(active-fr 삭제·task-state 생성)을 다음 정규 커밋에 포함하라고 사용자에게 안내합니다.
3. exit 3이면 `CURRENT_TASK.md`의 `## Status`를 canonical 8종 중 하나로 수동 복구한 뒤 재실행합니다. 복구 절차는 `rd-workflow/docs/guides/task-state-guide.md`의 "실패 시 복구"를 참조합니다.

**주의**: 마이그레이션이 만든 변경은 자동 커밋하지 않습니다 ("다음 정규 커밋에 편승" 계약 — LC-20 archive clean 검증은 이 변경이 커밋된 상태를 전제합니다).

## M005: 템플릿 유래 stale hook 제거 (`.claude/settings.json`)

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

**예시 (대표 사례)**: 배포 lite(VERSION 2026-06-09)로 부트스트랩한 프로젝트에는 PreToolUse/Bash에 `bash rd-workflow/scripts/hooks/pre_commit_verify.sh` 등록이 남아 있으나, 그 스크립트는 lite 산출물에 존재하지 않고 v2 lite의 `.claude/settings.json`에도 등록이 없습니다. 3중 조건에 걸려 이 항목만 제거되고, 스크립트가 존재하는 나머지 hook 등록은 보존됩니다.

**주의**:
- 프로젝트 고유 hook(command가 `rd-workflow/scripts/hooks/` 하위를 가리키지 않는 항목)은 검사 대상이 아니며 절대 제거되지 않습니다.
- full 템플릿과 sync하는 경우 스크립트가 clone에 존재해 조건 2가 성립하지 않습니다 — full/lite 산출물 차이에 자동 정합합니다.
- 대조 기준은 항상 clone된 템플릿 파일입니다.
- 제거가 수행되면 JSON 재직렬화로 들여쓰기가 2칸으로 정규화될 수 있습니다.
