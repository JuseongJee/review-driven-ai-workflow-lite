# Migrations

템플릿 구조 변경 시 기존 프로젝트에 적용할 마이그레이션 목록.
`sync_template.md` Step 4에서 이 파일(**clone된 템플릿의 사본**)을 읽고 해당하는 항목을 실행합니다.

## 항목 추가 규칙

**보존 파일의 정의 문구를 바꾸는 배포는 그 문구를 갱신하는 마이그레이션 항목을 동반합니다.**

`sync_template.md` 2단계의 보존 목록에 있는 파일은 동기화가 덮지 않습니다. 그래서 배포가
그 파일의 **정의 문구**(상태 값·종류 값 목록, 규약 서술 등)를 바꾸면 기존 프로젝트의 문구는
구버전에 묶입니다. 그 문구를 검사하는 self_test 스텝이 있으면 **sync 직후 반드시 실패**하며,
신규 부트스트랩 프로젝트만 통과합니다.

새 어휘·새 규약을 도입할 때는 다음을 함께 확인하십시오.

1. 바뀐 문구가 보존 파일에 있는가 (`sync_template.md` 2단계 목록 대조)
2. 그 문구를 검사하는 스텝이 있는가 (`scripts/test_*.sh` 에서 해당 파일을 grep 하는지 확인)
3. 둘 다 참이면 이 문서에 마이그레이션 항목을 추가한다 — 조건·실행·**보존 범위**(사용자
   데이터를 건드리지 않는 경계)를 명시하고, 실행은 재실행이 안전한 형태로 쓴다

이 규칙이 없어 실제로 발생한 사례: FR status 어휘 `blocked` 도입 시 정의처
`rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 가 보존 대상인데 갱신 항목이 없어,
FR 항목을 가진 모든 기존 프로젝트가 sync 직후 `test_fr_blocked_status.sh` 로 실패했습니다
(M009 가 그 뒤처리입니다).

---

## M000: sync 절차 문서 권위 전환

**조건**: 프로젝트의 sync 절차 문서(`rd-workflow/docs/guides/sync_template.md`, 구버전 구조면 `ai/docs/guides/sync_template.md`)가 clone된 템플릿의 `rd-workflow/docs/guides/sync_template.md`와 내용이 다르거나 프로젝트에 없을 때. 판별은 `cmp -s <로컬 경로> "<임시 clone 경로>/rd-workflow/docs/guides/sync_template.md"` (exit 0이 아니면 해당).

**실행 순서**: 다른 모든 마이그레이션 항목과 sync 절차 단계보다 **먼저** 평가·실행합니다.

**실행 절차**:
1. `<임시 clone 경로>/rd-workflow/docs/guides/sync_template.md`를 읽습니다.
2. 이 시점 이후의 **모든 동기화 절차(0단계 시점 확인부터 완료 보고까지)를 clone된 sync_template.md를 권위 문서로** 실행합니다. 프로젝트 로컬 절차 문서와 로컬 skill의 절차 요약은 이번 동기화에서 따르지 않습니다.
3. 로컬 절차 문서 기준으로 이미 수행한 단계(예: 파일 분류, 사용자 확인)가 있으면 clone 문서 기준으로 다시 수행합니다.
4. 나머지 마이그레이션 항목의 실행 순서·적용 시점 규칙(**M005 → M008 → M003** 순, M004는 동기화 후 등)은 이 항목 이후에도 clone된 `MIGRATIONS.md` 기준으로 유지됩니다.

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
- **이 "추가 방향으로만" 규약은 "표기 차이는 앞선 항목이 먼저 정규화한다" 는 전제 위에 있습니다.** 동일성 판정이 command 문자열 **정확 일치**이므로, 같은 스크립트를 가리키는 표기가 프로젝트와 템플릿에서 다르면 이 항목은 그것을 "부재" 로 읽어 **같은 hook 을 이중 등록**합니다. 그래서 표기 정규화는 **M008 이 M003 보다 먼저** 처리합니다. 앞으로 hook command 표기를 바꿀 때는 M003 을 고치는 대신 **정규화 항목을 하나 추가**하십시오 — 그러지 않으면 같은 사고가 반복됩니다 (실제 발생: 2026-08-21, 구 상대경로 표기 프로젝트에서 hook 4건이 8건으로).

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

**예시 (대표 사례)**: 2026-08-20 게이트 정리 이전 템플릿으로 부트스트랩한 프로젝트에는 PreToolUse/Bash에 `bash rd-workflow/scripts/hooks/pre_commit_verify.sh` 등록이 남아 있으나, 그 스크립트는 지금 산출물에 존재하지 않고 템플릿 `.claude/settings.json`에도 등록이 없습니다. 3중 조건에 걸려 이 항목만 제거되고, 스크립트가 존재하는 나머지 hook 등록은 보존됩니다.

**주의**:
- 프로젝트 고유 hook(command가 `rd-workflow/scripts/hooks/` 하위를 가리키지 않는 항목)은 검사 대상이 아니며 절대 제거되지 않습니다.
- 스크립트가 clone에 존재하면 조건 2가 성립하지 않습니다 — full/lite 산출물 차이와 게이트 제거 여부에 자동 정합합니다.
- 대조 기준은 항상 clone된 템플릿 파일입니다.
- 제거가 수행되면 JSON 재직렬화로 들여쓰기가 2칸으로 정규화될 수 있습니다.

## M006: source-fr 계약 구현 — archive gate enforcement 활성화

**조건**: VERSION 2026-08-03 이후 템플릿으로 동기화하는 모든 프로젝트.

**동작 변화**:
1. promote가 task-state `source-fr`를 실제로 기록합니다 (`promote.sh`: `--source-fr` 인자 > `REQUEST.md ## Source FR` 추론 > `-`; `rd task guard --mode promote`: 인자 없으면 `-` 리셋).
2. `pre_commit_archive_gate.sh`가 path 형식(백틱 포함) `Source FR`을 올바르게 해석합니다. **이전에는 path 형식에서 enforcement가 조용히 무력화되어 통과하던 커밋이, 이제 diff review 종결 + FR 미아카이브 상태에서 차단됩니다 (exit 2).**

**대응**: 차단 메시지가 나오면 REQUEST 아카이브(FR status done 처리)를 먼저 실행한 뒤 커밋합니다. stale `source-fr` 정정은 `rd task set-source-fr <path|->`를 사용합니다.

## M007: 게이트 정리 — 값어치를 증명하지 못한 hook 제거

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
- `lifecycle/archive.sh` 의 `archive_review_precheck` — 아카이브 시점의 리뷰 종결 확인. 강화도 완화도 하지 않았습니다.

**아카이브 검증 게이트에 관하여**: 이 마이그레이션의 초기 버전은 `lifecycle/archive.sh` 에 `archive_selftest_gate` 를 신설해 아카이브마다 `self_test.sh consumer` 통과를 강제했습니다. 2026-09-03 에 그 게이트와 smoke 감축 엔진을 걷어냈습니다 — 구현 직후 돌린 검증을 아카이브가 다시 돌려 얻는 것이 없었고, 아카이브마다 15~20분을 썼습니다. 지금 템플릿에는 그 게이트가 없으며, 검증은 구현 직후 `bash rd-workflow/scripts/self_test.sh [그룹...]` 로 사람이 돌리고 final diff review 가 결과를 확인합니다.

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

## M008: hook command 경로 표기 정규화 (`.claude/settings.json`)

**조건**: 프로젝트 `.claude/settings.json` 의 `hooks` 아래 어느 `command` 든 접두가 정확히 `bash rd-workflow/scripts/hooks/` 인 항목이 하나 이상 있을 때.

**실행 순서**: **M005 → M008 → M003** 입니다. M005(제거) 다음, **M003 보다 먼저** 실행합니다 — "정규화 후 대조" 순서입니다.

**왜 필요한가**: hook command 표기가 `bash rd-workflow/scripts/hooks/X` 에서 `bash "${CLAUDE_PROJECT_DIR:-.}"/rd-workflow/scripts/hooks/X` 로 바뀌었습니다. 구 표기는 **cwd 의존**이라 프로젝트 루트가 아닌 곳에서 hook 이 조용히 실패합니다. 그리고 M003 의 동일성 판정이 command 문자열 **정확 일치**이므로, 정규화 없이 M003 을 돌리면 같은 스크립트를 가리키는 템플릿 항목을 "부재" 로 읽어 **같은 hook 을 이중 등록**합니다 (실측: hook 4건 → 8건).

**계약**:
- **대상**: `hooks` 아래 모든 event/group 의 `command` 중 접두가 정확히 `bash rd-workflow/scripts/hooks/` 인 것만. **`command` 가 없거나 문자열이 아닌 item**(프로젝트 고유 prompt·agent 형태 등)은 정규화도 중복 판정도 하지 않고 내용·순서를 그대로 보존합니다.
- **치환**: `bash rd-workflow/scripts/hooks/X` → `bash "${CLAUDE_PROJECT_DIR:-.}"/rd-workflow/scripts/hooks/X`
- **보존**: 그 밖의 command(프로젝트 고유 hook), event 순서, group 순서, `matcher`·`timeout` 등 다른 필드는 그대로 둡니다.
- **접기(first-wins)**: 정규화 후 **같은 group 안에서** command 가 같은 항목이 둘 이상이면 **등장 순서상 처음 항목 전체를 남기고 나머지 항목을 버립니다.** 부가 필드가 서로 다르면 살아남은 항목의 필드가 결과이며, 버려진 항목의 필드는 유지되지 않습니다 ("다른 필드 보존" 은 접히지 않은 항목에 적용되는 규칙입니다).
- **group 경계**: 같은 matcher 를 가진 group 이 여럿이면 **각 group 을 독립으로 처리**하고 group 을 합치지 않습니다. group 을 합치면 matcher 그룹핑 의미가 바뀌고 무관한 hook 순서가 흐트러지기 때문입니다. 다른 event·다른 matcher 는 접지 않습니다. 여러 group 에 같은 command 가 걸쳐 있으면 접지 않고 **알림만** 냅니다.
- **멱등**: 신 표기만 있는 입력에 다시 실행하면 무변경이며 **파일을 재작성하지 않습니다**(mtime 도 그대로).
- **안전**: parse 또는 schema 오류는 **원본 byte 를 바꾸지 않고 실패**합니다. 변경이 있을 때만 같은 디렉터리 임시 파일에 쓴 뒤 `os.replace` 로 **원자 교체**합니다.

**실행 절차**:
1. 선행 검증: 프로젝트에 `.claude/settings.json` 이 없으면 M008 은 해당 없음입니다.
2. 아래 스니펫을 프로젝트 루트에서 실행합니다.
   ```bash
   python3 - <<'PY'
   import json, os, sys, tempfile

   OLD = "bash rd-workflow/scripts/hooks/"
   NEW = 'bash "${CLAUDE_PROJECT_DIR:-.}"/rd-workflow/scripts/hooks/'
   path = ".claude/settings.json"

   if not os.path.exists(path):
       print("M008: .claude/settings.json 없음 — 해당 없음"); sys.exit(0)

   with open(path, "rb") as f:
       original = f.read()
   try:
       cfg = json.loads(original.decode("utf-8"))
   except Exception as e:
       print("M008 실패: JSON parse 오류 — 원본을 바꾸지 않았습니다: %s" % e, file=sys.stderr)
       sys.exit(1)

   # schema 검증을 먼저 통과시킨 뒤에만 손댑니다 (write-before-validate 방지).
   if not isinstance(cfg, dict):
       print("M008 실패: 최상위가 객체가 아닙니다 — 원본을 바꾸지 않았습니다", file=sys.stderr); sys.exit(1)
   hooks = cfg.get("hooks")
   if hooks is None:
       print("M008: hooks 키 없음 — 무변경"); sys.exit(0)
   if not isinstance(hooks, dict):
       print("M008 실패: hooks 가 객체가 아닙니다 — 원본을 바꾸지 않았습니다", file=sys.stderr); sys.exit(1)
   for ev, groups in hooks.items():
       if not isinstance(groups, list):
           print("M008 실패: hooks[%s] 가 배열이 아닙니다 — 원본을 바꾸지 않았습니다" % ev, file=sys.stderr); sys.exit(1)
       for g in groups:
           if not isinstance(g, dict) or not isinstance(g.get("hooks", []), list):
               print("M008 실패: hooks[%s] 의 group 구조가 예상과 다릅니다 — 원본을 바꾸지 않았습니다" % ev, file=sys.stderr); sys.exit(1)
           for it in g.get("hooks", []):
               if not isinstance(it, dict):
                   print("M008 실패: hooks[%s] 의 item 이 객체가 아닙니다 — 원본을 바꾸지 않았습니다" % ev, file=sys.stderr); sys.exit(1)

   normalized = folded = 0
   seen_across = {}
   for ev, groups in hooks.items():
       for g in groups:
           items = g.get("hooks", [])
           kept, seen = [], set()
           for it in items:
               cmd = it.get("command")
               if isinstance(cmd, str) and cmd.startswith(OLD):
                   it["command"] = NEW + cmd[len(OLD):]
                   normalized += 1
                   cmd = it["command"]
               # **command 가 문자열이 아닌 item 은 중복 판정 대상이 아닙니다.**
               # `command` 키가 없는 프로젝트 고유 item(예: prompt·agent 형태)은 모두
               # key=null 로 접혀 같은 group 의 두 번째부터 조용히 삭제됩니다 — 사용자
               # hook 이 사라지는 데이터 손실입니다. 내용·순서를 그대로 보존합니다.
               if not isinstance(cmd, str):
                   kept.append(it)
                   continue
               key = json.dumps(cmd, ensure_ascii=False)
               if key in seen:      # first-wins: 처음 항목 전체를 남기고 나머지를 버립니다
                   folded += 1
                   continue
               seen.add(key)
               # **알림 키에 matcher 를 포함합니다.** matcher 가 다른 group 에 같은 command 가
               # 있는 것은 정상 구성입니다(예: Edit·Write 둘 다 implementation_gate.sh).
               # matcher 를 빼면 그 정상 구성마다 경고가 나와 진짜 신호를 덮습니다.
               mk = (ev, json.dumps(g.get("matcher"), ensure_ascii=False), key)
               seen_across[mk] = seen_across.get(mk, 0) + 1
               kept.append(it)
           if "hooks" in g:
               g["hooks"] = kept

   for (ev, matcher, key), n in seen_across.items():
       if n > 1:
           print("M008 알림: event %s / matcher %s 에서 같은 command 가 %d 개 group 에 걸쳐 있습니다 (group 경계는 합치지 않습니다): %s" % (ev, matcher, n, key))

   if normalized == 0 and folded == 0:
       print("M008: 변경 없음 (이미 정규화됨) — 파일을 재작성하지 않았습니다"); sys.exit(0)

   rendered = (json.dumps(cfg, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
   # 임시 파일 생성까지 try 안에 둡니다 — 디렉터리 쓰기 권한이 없는 경우가 실제로 있고,
   # 밖에 두면 그 실패가 traceback 으로 터져 "원본은 유지된다" 는 보장이 사용자에게 보이지 않습니다.
   d = os.path.dirname(os.path.abspath(path)) or "."
   tmp = None
   try:
       fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.json.m008.")
       with os.fdopen(fd, "wb") as f:
           f.write(rendered)
       os.replace(tmp, path)          # 원자 교체
   except Exception as e:
       if tmp is not None:
           try: os.unlink(tmp)
           except OSError: pass
       print("M008 실패: 교체 중 오류 — 원본이 유지됩니다: %s" % e, file=sys.stderr)
       sys.exit(1)
   print("M008: 표기 정규화 %d건, 중복 접기 %d건" % (normalized, folded))
   PY
   ```
3. 사후 JSON 유효성 검증: `python3 -m json.tool .claude/settings.json > /dev/null`
4. M008 이 끝난 뒤 M003 을 실행합니다. 이 순서를 지키면 M003 의 정확 일치 대조가 정상 동작합니다.

**주의**: 이 항목이 만든 변경은 자동 커밋하지 않고 다음 정규 커밋에 편승시킵니다 (M004 와 같은 계약).

## M009: 보존 파일 정의 문구 — FR status `blocked` (`FUTURE_REQUESTS.md`)

**조건**: 프로젝트 `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 의 「상태 값」 또는
「파일 분리」 섹션에 `blocked` 서술이 없을 때. 파일 자체가 없으면 해당 없음입니다.

**실행 순서**: 다른 항목과 독립입니다 (대상 파일이 `.claude/settings.json` 이 아닙니다).
순서 제약을 두지 않습니다.

**동작 범위**:
- **추가만 합니다.** 기존 행을 교체하지 않습니다 — 프로젝트가 그 행을 손댔을 수 있습니다.
- **인덱스 표와 기존 FR 항목 내용은 건드리지 않습니다.**
- 「상태 값」은 `- \`done\`` 행 앞에 넣어 배포본 순서를 따릅니다. 「파일 분리」는 **첫 목록
  항목 앞**에 넣습니다 — `test_fr_blocked_status.sh` 가 `grep -A4` 로 판정하므로 섹션 끝에
  붙이면 범위를 벗어납니다.
- **안전**: 사전검증 실패는 원본을 바꾸지 않고 종료합니다. 변경이 있을 때만 같은 디렉터리
  임시 파일에 쓴 뒤 `os.replace` 로 **원자 교체**하므로, 쓰기 도중 중단돼도 원본이 남습니다.
  기존 파일 권한을 보존합니다.
- **멱등입니다.** 판정은 **정식 항목 형태**(아래 canonical 행의 접두)로 하며, 단순 `blocked`
  문자열 포함 여부로 보지 않습니다 — 섹션에 `blocked 는 아직 미지원` 같은 메모만 있어도
  정식 정의가 없는 상태에서 건너뛰면 거짓 성공이 됩니다.

**canonical 결과** — 이 마이그레이션이 설치하는 정식 형태는 아래 두 행입니다.

```
## 상태 값
- `blocked`: 무인 드레인(ralph)이 …

## 파일 분리
- **`blocked` 항목**: 활성 인덱스에 **잔류**합니다 …
```

**신규 부트스트랩 프로젝트와 형태가 다릅니다.** 배포본 「파일 분리」는 `- **이 파일**:` 항목
본문 안에 `blocked` 서술을 품는데, 이 마이그레이션은 그 행을 **교체하지 않고**(프로젝트가
손댄 내용을 지우지 않기 위해) 전용 행을 추가합니다. 따라서 두 경로의 문장 구조가 갈리며,
**그것이 의도된 계약입니다** — 마이그레이션 경로의 정본은 위 전용 행이고, `test_sync_template.sh`
의 M009 회귀가 그 정확한 행을 oracle 로 고정합니다. 형태를 통일하려면 「이 파일」 행 교체가
필요하고 그것은 사용자 데이터 보존과 충돌합니다.

**실행 절차**: 프로젝트 루트에서 아래 스니펫을 실행합니다.

   ```bash
   python3 - <<'PY'
   import os, stat, sys, tempfile

   PATH = "rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"

   STATUS_ITEM = (
       "- `blocked`: 무인 드레인(ralph)이 중단조건에 걸려 set-aside 한 항목. 활성 인덱스에 "
       "잔류하되 auto-pick·`/fr pri`·`/fr push` 대상에서 제외되고 `/fr list` 에는 set-aside "
       "요약(건수)으로만 표기. 원인 해소 후 `validated` 로 복원해 재시도"
   )
   SPLIT_ITEM = (
       "- **`blocked` 항목**: 활성 인덱스에 **잔류**합니다 (parked 처럼 별도 파일로 옮기지 "
       "않습니다). auto-pick·`/fr pri`·`/fr push` 대상에서 제외되고 `/fr list` 에는 "
       "set-aside 요약으로만 표기됩니다."
   )

   if not os.path.exists(PATH):
       print("M009: %s 없음 — 해당 없음" % PATH)
       sys.exit(0)

   with open(PATH, encoding="utf-8") as f:
       lines = f.read().split("\n")

   # --- 판정 단계: 쓰기 전에 전부 끝낸다 ---
   targets = {}
   for name in ("상태 값", "파일 분리"):
       hits = [i for i, l in enumerate(lines) if l.strip() == "## " + name]
       if len(hits) != 1:
           print(
               "M009 실패: '## %s' 헤딩이 %d개입니다 (정확히 1개여야 합니다) — "
               "원본을 바꾸지 않았습니다." % (name, len(hits)),
               file=sys.stderr,
           )
           print(
               "  조치: %s 에서 그 헤딩을 하나만 남기거나, 배포본의 해당 섹션 문구를 "
               "직접 옮겨 적으십시오." % PATH,
               file=sys.stderr,
           )
           sys.exit(1)
       targets[name] = hits[0]

   def section_end(start):
       for i in range(start + 1, len(lines)):
           if lines[i].startswith("## "):
               return i
       return len(lines)

   # 완료 판정은 **정식 항목 형태**로 합니다. 단순히 "blocked" 라는 글자가 섹션 안에
   # 있는지만 보면, 예컨대 "blocked 는 아직 미지원" 같은 메모만 있어도 정식 정의가 없는
   # 상태에서 건너뛰어 거짓 성공이 됩니다.
   MARKERS = {"상태 값": "- `blocked`:", "파일 분리": "- **`blocked` 항목**:"}

   pending = []   # (삽입 인덱스, 본문)
   for name, item in (("상태 값", STATUS_ITEM), ("파일 분리", SPLIT_ITEM)):
       start = targets[name]
       body = lines[start + 1:section_end(start)]
       if any(l.startswith(MARKERS[name]) for l in body):
           continue
       offset = None
       if name == "상태 값":
           for j, l in enumerate(body):
               if l.startswith("- `done`"):
                   offset = j
                   break
       if offset is None:
           for j, l in enumerate(body):
               if l.startswith("- "):
                   offset = j
                   break
       if offset is None:
           print(
               "M009 실패: '## %s' 섹션에 목록 항목이 없습니다 — 원본을 바꾸지 "
               "않았습니다." % name,
               file=sys.stderr,
           )
           print("  조치: 배포본의 해당 섹션 문구를 직접 옮겨 적으십시오.", file=sys.stderr)
           sys.exit(1)
       pending.append((start + 1 + offset, item))

   if not pending:
       print("M009: 두 섹션에 이미 blocked 서술이 있습니다 — 해당 없음")
       sys.exit(0)

   # --- 쓰기 단계: 임시 파일 + os.replace 원자 교체 ---
   for idx, text in sorted(pending, reverse=True):
       lines.insert(idx, text)
   rendered = "\n".join(lines).encode("utf-8")

   d = os.path.dirname(os.path.abspath(PATH))
   mode = stat.S_IMODE(os.stat(PATH).st_mode)
   tmp = None
   try:
       fd, tmp = tempfile.mkstemp(dir=d, prefix=".FUTURE_REQUESTS.md.m009.")
       with os.fdopen(fd, "wb") as f:
           f.write(rendered)
           f.flush()
           os.fsync(f.fileno())
       os.chmod(tmp, mode)
       os.replace(tmp, PATH)
       tmp = None
   except Exception as e:
       if tmp is not None:
           try:
               os.unlink(tmp)
           except OSError:
               pass
       print("M009 실패: 쓰기 오류 — 원본을 바꾸지 않았습니다: %s" % e, file=sys.stderr)
       sys.exit(1)

   print("M009: %d개 섹션에 blocked 서술을 삽입했습니다." % len(pending))
   PY
   ```

**검증**: `bash rd-workflow/scripts/test_fr_blocked_status.sh` 가 PASS 합니다.
