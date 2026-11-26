# Review-Driven AI Workflow — Lite

비개발 도메인(기획, 마케팅, 운영, 교육 등)을 위한 AI 워크플로 템플릿.

> **"Lite"는 적용 대상이 개발과 얽히지 않는다는 뜻이지, 워크플로가 가벼워진다는 뜻이 아닙니다.**

REQUEST → 리뷰 → spec/plan → 실행 → 검증 → 최종 리뷰까지, dev 버전과 동일한 구조적 엄밀함을 유지합니다. 개발 도구 의존(test/lint/typecheck, git diff review 등)만 제거하고 프롬프트 기반 검증과 산출물 리뷰로 대체했습니다.

## 최근 변경

최근 세 발행에서 달라진 것입니다. 내 프로젝트의 `rd-workflow/VERSION` 보다 뒤의 절이 `/tpl update` 로 받을 변화입니다. 전체 이력은 [`rd-workflow/CHANGELOG.md`](rd-workflow/CHANGELOG.md) 에 있습니다.

### 2026-11-27-002331

- **gate 가 건드린 worktree 의 상태로 판정함**: 기본 체크아웃에서 시작한 세션이 작업 worktree 를 건드려도, gate 가 그 worktree 의 REQUEST·task-state·리뷰 기록·index 로 판정합니다. 대상은 subagent 의 공유 상태 파일 쓰기 차단(`implementation_gate`)과 아카이브 커밋 검사(`pre_commit_archive_gate`)입니다. 편집은 그 파일이 속한 worktree, 커밋은 커밋 위치의 worktree 로 정하고, 한 명령이 여러 worktree 에 커밋하면 각각 판정합니다. 다른 저장소는 판정하지 않고, git 밖이면 예전처럼 판정합니다. 판정 기준이 hook 을 실행한 체크아웃과 다르면 차단 메시지에 `[guard] 판정 기준 worktree: <경로>` 를 붙입니다. worktree 에서 시작한 세션(promote 가 띄운 작업 탭 등)의 판정은 그대로입니다.
- **낡은 Codex 리뷰 모델 알림**: 리뷰 세션을 만들 때(`init_review_pipeline.sh`·`prepare_review_pipeline.sh`) 이번 리뷰를 Codex 가 맡고 Codex 모델이 계열 최신이 아니면 한 번 알립니다. 대상은 고정 이름(`RD_REVIEW_CODEX_MODEL`·`models.json`)과 `~/.codex/config.toml` 의 모델입니다. 경고는 이번만 옛 모델로 진행(선택 1)과 옛 모델을 계속 쓰고 기록(선택 2)을 보입니다. 선택 2 는 `bash rd-workflow/scripts/model_select.sh keep-codex-model <현재 모델> <새 모델>` 로 사용자 단위 파일 `<상태 폴더>/rd-workflow/codex-model-keep.tsv`(`XDG_STATE_HOME` 또는 `$HOME/.local/state`)에 기록하며, 같은 계열에 더 새 모델이 나오면 다시 알립니다. 리뷰 턴마다 나오던 Codex 「고정됨, 낡을 수 있음」 경고는 없어졌습니다(Claude 고정 이름 경고는 그대로입니다).
- **직접 설치 PR 발행이 기록 파일 충돌을 자동 병합함**: 직접 설치 PR 발행(`archive_publish=pr`)에서 기본 브랜치와 충돌하는 파일이 기록 파일뿐이면, 첫 발행과 열린 PR 을 갱신하는 재발행 모두 push 전에 자동 병합하고 충돌 없는 PR 을 올립니다. 병합 커밋과 해소한 기록 파일 목록을 알립니다. 자동 병합을 못 하면(기록 파일 밖 충돌, `merge.verifySignatures` 설정, 무시 파일 겹침 등) 병합 없이 PR 을 올리고 사유별 다음 행동을 경고합니다. push 뒤 끊긴 발행은 같은 `rd publish request` 로 이어 가고, 발행 큐는 그 재개 요청을 로컬 기본 브랜치 충돌로 막지 않습니다.
- **작업 탭의 모델·effort 선택과 부모 effort 상속**: promote·대화형 `/fr do` 가 띄우는 작업 탭의 모델·effort 를 `rd-workflow/config/models.json` 의 `session.claude.model`·`session.claude.effort` 로 고릅니다(템플릿 기본값은 비어 있음). 한 번만 바꿀 때는 `RD_SESSION_MODEL`·`RD_SESSION_EFFORT` 를 쓰고, 넘기지 않으려면 `default` 를 줍니다. 아무 설정이 없으면 작업 탭이 부모 세션의 모델과 effort 로 뜹니다(effort 상속은 새 동작). promote 가 고른 값과 출처를 한 줄로 보이고, 수동 기동 안내 명령에도 같은 값이 들어갑니다. Claude CLI 가 `--effort` 를 받지 않으면 경고 뒤 effort 없이 띄웁니다. 옛 `model-strategy.json` 의 `session_model` 은 읽기만 하고 `models.json` 으로 옮기라고 안내합니다.
- **`/fr do --headless` 의 모델·effort 선택**: `/fr do --headless --model <모델> --effort <effort>` 로 그 회차의 모델·effort 를 고릅니다. 플래그가 없으면 `RD_HEADLESS_CLAUDE_MODEL`·`RD_HEADLESS_CLAUDE_EFFORT`, 그다음 `rd-workflow/config/models.json` 의 `headless.claude.model`·`headless.claude.effort` 를 칸마다 따로 씁니다. 모두 없으면 CLI 기본값입니다. 착수 보고·로그·요약에 고른 값과 출처가 나옵니다. 값이 틀렸거나 `claude` 가 옵션을 지원하지 않으면 세션을 띄우기 전에 멈춥니다.
- **`/fr do` 호출 세션이 줄기의 질문을 중계하지 않음**: 대화형 `/fr do` 에서 줄기가 사용자에게 직접 묻는 설계 질문·답변 완료·승인 다이얼로그를 호출 세션이 다시 알리지 않습니다. 사용자는 herdr 탭에서 직접 보고 답합니다.
- **seal 거부 안내가 바로 실행할 명령을 보여 줌**: seal 이 거부되면 세션 상태별로 다음 명령을 세션 절대 경로까지 채워 보입니다(수렴 세션은 `--reopen`, 종결 세션은 새 세션, 미해결 이의는 `--decision`·`--override`, 턴 한도는 `--extend-turns <N>`, 이전 형식 세션은 `--legacy-unverified`). SESSION.md 의 Status·Closure Reason 을 손으로 고치라는 안내는 없어졌습니다.
- **종결된 리뷰 세션 뒤 재확인 순서 안내**: closed 세션에 `run_review_turn.sh` 를 실행하면 옵션과 상관없이 재확인 순서를 안내합니다. diff 리뷰는 `prepare_review_pipeline.sh diff --base <그 세션의 review-head-oid>` 완성 명령을 냅니다. 종결 세션 뒤 `diff review 대기` 상태의 커밋 게이트는 seal 경로와 재확인 경로를 안내합니다.
- **final diff review 가 검사 약화를 점검함**: 리뷰어가 diff 의 검사 끄기 주석(`@ts-ignore`·`eslint-disable`·`noqa` 등), `.skip`·테스트 파일 삭제, assertion 제거, 임계값 하향, 통과만 시키는 stub 을 찾습니다. 그 사유가 REQUEST·spec 에 없으면 종결을 막는 이의로 냅니다.
- **fr 브랜치 없는 작업의 명령 대상 판정**: 기본 체크아웃에서 fr 브랜치 없이 진행 중인 작업이 있으면, 대상 없이 부른 `rd task set-status`·`rd pr open`·`rd pr check --apply` 가 그 작업을 바꿉니다. 작업이 없는 체크아웃에서 대상 없이 `rd task set-status` 를 부르면 다른 작업을 자동으로 고르지 않고 목록과 `--task <slug>` 사용법을 보이며 멈춥니다. `rd pr check` 표와 `rd task list` 의 명령은 `cd '<작업 체크아웃>' && ` 로 시작합니다.
- **Issue 선점 기록이 Issue URL 을 씀**: `/fr take` 로 만든 FR 의 `github-issue` 칸이 `owner/repo#N` 대신 Issue URL 이 됩니다. 선점·끊긴 선점 표시가 실제 호스트 URL 을 쓰고, 다른 호스트의 같은 번호 Issue 를 따로 선점할 수 있습니다. 옮겨진 Issue 는 선점하지 않고 옮긴 주소를 알립니다. 장부 행만 지우는 `forget` 은 호스트를 붙여 부릅니다(`forget <호스트>/<owner>/<repo> <번호>`).
- **Gemini 리뷰 도구 안내 정리**: Gemini 리뷰 어댑터는 이미 없으므로 `/review-config` 가 Gemini 를 감지하거나 선택지·우선순위 예시·모델 질문으로 내지 않습니다(권장 우선순위 `codex → claude`). 기존 `review-tools.json` 우선순위에 어댑터 없는 도구가 있으면 `/review-config` 상태 출력이 도구마다 경고하고, setup 은 그 도구를 빼고 저장합니다. 리뷰 턴은 `어댑터 없음, 건너뜀: gemini — … /review-config setup` 으로 알립니다. `model_select.sh set-legacy tools.gemini.*` 는 거부됩니다. 예시 설정·설치 안내·`config_reference.md`·`USER_MANUAL.md` 에서 Gemini 안내를 지웠습니다. 직접 추가한 어댑터(`adapter_<도구>.sh`)는 도구 목록에 남습니다.
- **바쁜 머신에서 끝난 작업 정리가 보류되지 않음**: 다른 작업이 함께 도는 머신에서 `rd task list` 와 archive 가 끝난 작업의 worktree 를 「점유 판정불가」로 보류하던 일이 줄어듭니다. 프로세스 목록을 찍은 뒤 끝난 프로세스와 setuid 프로그램으로 계정이 바뀐 프로세스를 점유로 세지 않습니다. 정리가 한 번에 끝나 다시 실행할 필요가 줄어듭니다.
- **대화형 `/fr do` 가 줄기마다 모델·effort 를 고름**: 착수 보고 표에 「모델·effort」 칸과 근거가 붙고, 줄기마다 그 값으로 작업 탭을 띄웁니다. 기준표는 Opus 고정에 effort 3단계입니다(문서·skill 문구만 `medium`, 스크립트 변경 `high`, lifecycle·리뷰·발행 엔진·FR 3건 묶음·큰 feature `xhigh`). 값은 사용자의 줄기별 지시 > 회차 플래그 > 기준표 순서로 정합니다. 대화형에서도 `/fr do --model <값> --effort <값>` 을 받습니다. 띄운 뒤 줄기마다 실제 적용 값과 출처가 한 줄씩 나오고, 값이 틀리면 어느 줄기도 띄우지 않고 이유를 알립니다.
- **`rd pr sync` 가 사용자 git 병합 설정을 따라가지 않음**: 브랜치에 `mergeOptions=--squash` 가 있어도 sync 가 끝나면 작업 worktree 가 push 한 병합 커밋에 있습니다. 서명 확인 설정(`merge.verifySignatures`, `mergeOptions` 의 `--verify-signatures`)이 켜져 있으면 원격·색인·작업 worktree 를 바꾸지 않고 멈추고, 기본 브랜치 끝 커밋의 서명 확인 명령과 복구·설정 끄기 순서를 안내합니다. 끝나지 않은 병합(`MERGE_HEAD`)이나 진행 중인 cherry-pick·revert 가 있어도 아무것도 바꾸지 않고 멈춥니다. 수동 복구 안내의 병합 명령은 `git merge --no-squash origin/<기본>` 입니다.
- **닫힌 PR 의 작업 폐기 안내가 두 단계로 바뀜**: `rd pr check`·`rd pr sync`·발행의 닫힌 PR 안내가 `/fr status <slug> dropped` 다음에 `cd <기본 체크아웃> && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task <slug>` 한 줄을 냅니다. 어느 폴더에서 실행해도 그 저장소의 작업만 정리합니다. 원격 착수 표시 브랜치는 rollback 이 지웁니다.
- **대상 없이 부른 발행·취소가 작업을 자동으로 고르지 않음**: 작업이 없는 위치(기본 체크아웃 등)에서 `--task` 없이 부른 `archive.sh`·`promote_rollback.sh` 는 진행 중 작업이 1건이어도 고르지 않고 멈춥니다. 작업 목록과 `--task <slug>` 사용법을 냅니다. 이렇게 부르던 자동화는 `--task` 를 붙여야 합니다. `archive.sh --fr-branch <브랜치>` 만 주면 대상 판정 없이 그 브랜치를 발행합니다.
- **기본 체크아웃 작업의 발행 재시도**: fr 브랜치 없는 작업의 발행이 정리 커밋 뒤 멈춘 상태에서 대상 없이 `archive.sh` 를 다시 부르면 그 작업의 재시도로 보고 이어서 발행합니다. push 가 두 번 이상 실패해도 같습니다. 다른 작업을 발행하려면 `--task` 를 붙이라고 알립니다.
- **다른 FR 의 선점 행을 남기면 알림**: 발행이 Issue 선점 장부에서 다른 FR 에 연결된 행을 지우지 않고 남기면 `archive: 다른 FR(<FR>)에 연결된 선점 행 … 은 남겼습니다` 줄을 냅니다.
- **낡은 Codex 모델 알림**: 리뷰 세션을 만들 때 이번 리뷰를 Codex 가 맡고 모델이 계열 최신보다 낮으면 경고를 한 번 냅니다. 새 모델 이름과 늘 최신을 쓰는 설정 명령, 선택지를 함께 보입니다. 옛 모델을 계속 쓰려면 `bash rd-workflow/scripts/model_select.sh keep-codex-model <현재 모델> <새 모델>` 로 기록하고, 같은 조합은 다시 알리지 않습니다(사용자 단위 파일 `${XDG_STATE_HOME:-~/.local/state}/rd-workflow/codex-model-keep.tsv`). 대화형 AI 는 첫 리뷰 턴 전에 선택지를 묻고, 무인 실행은 「이번만」 으로 진행한 뒤 보고에 경고를 옮깁니다. 리뷰 턴의 Codex 「고정 이름입니다」 경고는 없어졌습니다.
- **구현 subagent 의 모델·effort 를 `models.json` 에서 고름**: implement-reviewed-plan·autopilot 이 subagent 를 띄우기 전에 `bash rd-workflow/scripts/model_select.sh subagent` 로 `rd-workflow/config/models.json` 의 `subagent.claude.model`·`subagent.claude.effort` 를 읽어 Agent 도구 `model`·`effort` 인자로 넘기고, 적용값과 출처를 사용자에게 보입니다. 템플릿 기본값은 비어 있고, 설정하지 않으면 모델 `sonnet`, effort 미전달로 종전과 같습니다. 옛 키 `model-strategy.json` 의 `subagent` 는 칸이 비어 있을 때만 읽고 `models.json` 으로 옮기라고 안내합니다. `/model-strategy` 가 선택을 `models.json` 에 쓰고(`model-strategy.json` 은 더 이상 쓰지 않음), `model_select.sh set` 이 `subagent.claude.model`·`subagent.claude.effort` 를 받습니다.
- **`/fr do` 감시가 작업 중인 줄기의 컨텍스트 초과도 알림**: 감시가 턴이 끝난 줄기만이 아니라 작업 중(working)인 줄기의 컨텍스트 비율도 상태줄에서 읽습니다. 85% 이상이면 한 번, 100% 이상이면 「긴급」 으로 한 번 더 알립니다. 같은 체크아웃에서 감시가 여럿 돌면 하나만 알립니다. 작업 중에 보낸 `/compact` 는 지금 턴이 끝난 뒤 실행된다는 점을 `/fr do` 안내에 적었습니다.
- **`/fr do` 호출 세션이 압축을 건너뛴 이유를 알림**: 호출 세션의 자기 압축이 대기 상한에서 건너뛰면 결과 줄에 이유를 한 문장으로 적습니다. 「상태줄의 컨텍스트 표시를 읽지 못함」 은 회차마다 처음 한 번만 알리고, 승인 창·작업 중·입력 중 같은 일시 사유는 건너뛸 때마다 알립니다.
- **`/fr-groom` skill**: idea FR 검증(groom)을 별도 skill 로 떼었습니다. 대상 FR 전부의 판정 권장표를 한 턴에 보이고, 사용자가 한 번 답하면 그 턴에 기록·상태 반영까지 합니다. 개별 문답은 「N번 따로」 로 남았습니다. frontmatter 기본값은 모델 `fable`·effort `high` 입니다. `/fr groom` 은 이 skill 을 부르지만 그 경로에서는 effort 만 걸리므로, 모델까지 올리려면 `/fr-groom` 을 직접 입력합니다. (full·lite)
- **구현 subagent 의 모델·effort 를 hook 이 화면에 표시함**: 작업 상태가 `구현 중` 일 때 Agent 호출마다 PreToolUse hook(`subagent_dispatch_display.sh`)이 넘긴 모델·effort 와 `models.json` 설정 값·출처·경고를 한 줄로 보입니다. 대화형 화면에는 `PreToolUse:Agent says: [rd-workflow] subagent …` 로 나옵니다. 넘긴 값이 설정과 다르면 「설정과 다름」 을 붙이지만 호출은 막지 않습니다. implement-reviewed-plan·autopilot 의 「응답 텍스트로 표시」 단계는 없어졌습니다. 무인 실행에서는 transcript 에 같은 줄이 남고, `/fr do` 「4. 무인」 7단계의 조회 명령으로 작업 이름별로 찾습니다. 소비 프로젝트는 sync 때 hook 등록이 자동으로 더해집니다(M003, 안내 M019).
- **커밋 gate 가 셸이 실제로 이동한 위치로 판정함**: 아카이브 커밋 검사(`pre_commit_archive_gate`)가 `git -C`·`env -C` 경로의 심링크 뒤 `..` 를 물리 경로로 풀어, git 이 실제로 커밋하는 체크아웃 기준으로 판정합니다. `-C` 를 여러 번 이어 써도 같습니다. `cd -P`·`cd -L`·`cd --` 와 리다이렉션·here-string·here-document 가 붙은 `cd`·`git` 도 셸이 이동한 위치에서 판정합니다. 셸마다 결과가 다른 형태(해석할 수 없는 `cd` 옵션, `cd -PL`, 경로 뒤 둘째 인자, `CDPATH` 가 걸린 상대 경로)는 위치를 확정하지 않고 「대상 디렉토리를 확정할 수 없어 …」 를 알립니다. 이때 명령에 같은 저장소의 다른 worktree 경로가 있으면 그 worktree 의 상태로도 판정하고, 막을 상태가 있으면 커밋을 막습니다. 옵션·리다이렉션이 없는 `cd` 의 판정은 바뀌지 않습니다.
- **아카이브 커밋 차단 메시지가 이동할 위치를 알려 줌**: 아카이브 커밋 gate 가 셸 위치와 다른 worktree 를 판정해 막으면, 메시지 끝에 `[guard] 위 안내의 명령은 판정한 worktree 최상위에서 실행하세요: cd <경로>` 줄이 붙습니다. 경로는 셸 인용되어 그대로 붙여 넣으면 됩니다.
- **push 하지 않은 submodule 커밋도 발행이 성공함**: submodule 커밋을 팀 원격에 push 하지 않고 발행해도, 기본 체크아웃 submodule 이 발행한 커밋으로 맞춰지고 작업 worktree 가 지워집니다. 그 커밋이 팀 원격에 없으면 submodule 에 브랜치 `rd-archive/<작업 이름>` 을 남기고 `git -C <submodule 경로> push origin rd-archive/<작업 이름>` 명령을 알립니다. 커밋을 옮기지 못하거나 보존 근거를 확신할 수 없으면(alternates 사용 등) 원인을 알리고 종전처럼 worktree 를 보존합니다. 발행 병합의 `stage_metrics.tsv` add/add 충돌은 줄 합집합으로 자동 해결합니다.
- **`/fr-groom` 이 질문 창과 번호 코드로 답을 받음**: 판정 권장표 뒤에 「전부 권장대로 (Recommended)」·「행별로 바꾸기」·「한 행만 따로 문답」·「중단」 질문 창이 뜨고, 답할 때까지 화면 아래에 남습니다. Other 칸에는 번호 코드(`1` 전부 권장대로, `0` 중단, 행별 `Nv`·`Np <조건>`·`Nd`·`Ni`·`Ns`·`N?`, 쉼표로 여러 개)를 칠 수 있고, 적지 않은 행은 권장대로 반영합니다. 읽지 못한 코드가 하나라도 있으면 아무 행도 반영하지 않고 다시 묻습니다. 질문 창이 없는 실행에서는 문장이나 번호 답을 기다립니다.
- **PR 본문의 「맞닿은 곳」 목록과 리뷰어 대조**: PR 템플릿(`PR_TEMPLATE.md`)의 「되돌리기와 영향 범위」 절에 「맞닿은 곳」 항목(부르는 곳·실행 환경, 새 입력을 받는 기존 로직, 기대는 외부 동작)이 생겼습니다. 외부 동작에는 근거·「추론」·「확인 불가 — 시도한 방법과 막힌 이유」 중 하나를 붙입니다. final diff review 리뷰어는 목록 누락·사실과 다른 항목·근거 없는 「추론」·확인할 길이 있는 「확인 불가」 를 `맞닿은 곳:` 이의로 내고, 6턴 뒤 범위를 줄여도 목록의 곳을 「드문 환경」 으로 돌리지 않습니다. Author 가 「전부터 있던 동작」 을 이유로 반박·보류할 때는 `새 입력: 넣음|안 넣음 — <근거>` 를 적습니다.
- **다른 clone 과의 중복 착수를 막음**: 원격이 있는 저장소에서 promote 가 다른 clone 의 착수 표시, 원격 기본 브랜치의 FR `done`, 같은 slug 의 다른 발행 태그를 확인합니다. 하나라도 있으면 아무것도 만들지 않고 `promote: 중복 착수 — …` 로 멈추며 발견 내용과 다음 행동을 보입니다. 같은 clone 에서 같은 Source FR 의 작업이 진행 중이어도 멈춥니다. 착수에 성공하면 원격 `fr/<slug>` 에 착수 커밋을 올리고 `promote: 착수 표시 — …` 를 알립니다. 원격 조회가 실패하거나 30초(`RD_DUP_CHECK_TIMEOUT`)를 넘으면 경고만 내고 계속합니다. `rd publish request` 도 다른 곳에서 이미 발행됐거나 같은 slug 의 다른 이력이 원격에 있으면 거절합니다. `promote_rollback.sh` 는 이 작업의 원격 착수 표시를 lease 로 지우므로, 닫힌 PR 폐기 안내는 이제 rollback 한 줄만 냅니다(원격 브랜치 삭제 명령 없음). `/fr do` 인계 요약은 줄기마다 착수 표시 상태와 중복 착수 사유를 보입니다.
- **직접 실행한 `archive.sh` 도 원격 중복을 확인함**: 원격이 있는 저장소에서 `archive.sh` 를 직접 실행하면 병합 전에 `rd publish request` 와 같은 원격 중복 확인을 돌립니다. 같은 작업의 다른 구현이 있으면 「발행하지 않습니다 — 같은 작업의 다른 구현이 있습니다 (상태 변경 없음)」 과 발견 내용, 폐기 명령, 우회 옵션을 안내하고 멈춥니다. 새 우회 옵션 `--allow-duplicate-publish "<사유>"` 는 검사가 멈출 때만 사유를 보고 `review-skip-audit.log` 에 `[dup-publish] <사유>` 를 남깁니다. 원격 조회가 실패하면 경고만 내고 계속하며, 원격이 없거나 `--no-remote`·`--dry-run`, 큐가 띄운 archive 는 확인하지 않습니다.
- **리뷰 턴 한도에서 지적 추세 표를 보임**: Reviewer 턴이 턴 한도로 `awaiting-user` 가 되거나 한도로 실행이 거부되면 stderr 에 「지적 추세」 표(최근 10턴의 지적 수·새 지적 수·`범위 밖:` 줄 수·새 지적 번호)가 나옵니다. Author 는 사람에게 묻기 전에 이 표를 보이고, 새 지적이 턴마다 나오면 「범위 밖으로 넘기고 종결」 을 권장안으로 둡니다. `--override` 가 리뷰 뒤 코드 변경으로 거부되면 확인 턴(`--decision "<근거> (종결 결정 — 리뷰 뒤 변경 확인)"`)부터 `rd review seal` 까지의 명령을 채워 안내하고, 확인 턴에서 보호 범주가 아닌 이의가 남으면 같은 근거의 `--override` 를 받습니다.
- **`manual` submodule 의 gitlink 가 팀 기본 브랜치보다 뒤면 알림**: promote 가 새 worktree 를 만들 때 `manual` submodule 의 gitlink 가 팀 기본 브랜치 끝보다 뒤면 「N 커밋 뒤입니다」, 기본 브랜치에 없는 커밋이면 「origin/<브랜치> 에 없는 커밋입니다」 를 알리고, 기본 브랜치 끝에서 작업 브랜치를 따는 명령을 냅니다. archive 는 발행 뒤 gitlink 가 팀 기본 브랜치에 없는 커밋이면 팀 PR 머지 뒤 gitlink 를 옮기는 명령과 반영 방식을 `pr` 로 바꾸는 방법을 한 번 안내합니다. 둘 다 gitlink 를 옮기거나 발행을 막지 않고, 원격 조회가 실패하거나 20초(`RD_TP_LAG_TIMEOUT`)를 넘으면 건너뛴다고 한 줄 알립니다.
- **worktree 가 없는 부분 완료 발행을 큐 명령으로 풂**: `rd publish recover <slug>` 가 부분 완료를 받습니다. 작업 worktree 가 있으면 그 worktree 에서 `rd publish run` 을 안내하고, 없으면 발행 증거를 다시 판정해 발행됐으면 성공으로 바꾸고 허가 슬롯을 풉니다. 발행되지 않았으면 worktree 를 다시 만들어 `rd publish run` 할지 `rd publish cancel <slug>` 로 버릴지 명령을 채워 안내합니다. `rd publish cancel` 은 worktree 없는 부분 완료를 취소하고 슬롯을 풀되, 그 작업이 기본 브랜치에 병합된 채 origin 에 없으면 남은 커밋과 다음 행동을 보이고 슬롯을 유지합니다. `rd publish status`·감시 알림·`wait`·`next` 의 안내도 worktree 유무에 따라 다음 행동을 가리킵니다.
- **`/fr do` 가 되돌린 줄기의 낡은 줄을 정리함**: 로컬 브랜치 `fr/<slug>` 가 없는 감시 목록 줄은 `pick.py` 가 `stale` 로 내고, 그 FR 은 더 이상 보류되지 않으며 동시 상한에도 세지 않습니다. `/fr do` 는 그 줄을 `close.sh <slug> --stale` 로 정리하고(탭은 닫지 않음) 「정리한 낡은 줄」 로 보인 뒤 다시 고릅니다. promote 가 중복 착수로 멈춘 FR 은 `log.md` 에 기록하고 재선정 때 `pick.py --exclude` 로 뺍니다. 새 줄기의 slug 는 감시 목록·보고 파일에 남은 slug 와도 겹치지 않게 정합니다. `watch.sh` 는 낡은 줄의 알림을 내지 않고, `close.sh 1` 이 `01` 줄을 지우던 문제가 고쳐졌습니다.

- **Orca 세션에서 promote 가 Orca 에이전트를 띄움**: Orca 채팅·터미널 세션에서 promote 하면 Orca 사이드바의 `fr/<slug>` 아래에 claude 에이전트가 뜨고 인계 문구가 첫 메시지로 처리됩니다. 포커스는 옮기지 않습니다. 신뢰 확인 등으로 첫 턴이 시작되지 않으면 `launch=unknown` 과 「확인 창을 승인한 뒤 resolve-launch 를 실행하십시오」 안내가 나옵니다. 세션을 닫거나 Orca 에서 workspace 를 지운 뒤에는 rollback·archive 가드가 `--assume-ended` 없이 통과합니다. herdr·herdr app 사용자의 동작과 문구는 그대로입니다.
- **promote 가 기본 브랜치의 REQUEST review 세션을 작업으로 옮김**: 기본 브랜치에서 작업 이름을 정하고 REQUEST review 를 한 뒤 promote 하면, 그 `…_request-review/` 세션이 「문서 이관」 목록에 나오고 작업 worktree 로 옮겨져 바로 이어 쓸 수 있습니다. git 이 무시하는 로컬 로그는 커밋하지 않고 같은 폴더로 옮깁니다. 리뷰 턴이 실행 중이거나 옮길 수 없는 파일이 있으면 세션을 통째로 남기고 사유를 알리며, 같은 promote 를 다시 실행하면 이어받습니다.
- **`/fr list` 가 끝난 `/fr do` 줄기를 진행 중으로 보이지 않음**: 감시 목록에 줄이 남아 있어도 로컬 브랜치 `fr/<slug>` 가 없으면 그 줄로 「진행 중(/fr do 줄기 <slug>)」 을 붙이지 않습니다. 같은 FR 의 낡은 줄이 살아 있는 줄보다 앞에 있어도 살아 있는 줄기로 표시하고, promote 의 중복 착수 확인도 그 줄기를 찾아 막습니다.
- **lifecycle push 가 로컬 태그를 함께 올리지 않음**: `push.followTags=true` 인 저장소에서도 archive 발행·PR 방식 발행·`rd pr check --apply`·`rd pr open` 이 원격에 새로 만드는 태그는 이번 발행 태그 하나뿐입니다. 원격에 없던 다른 로컬 태그는 사용자가 직접 push 할 때 올라갑니다. 사용자에게 직접 실행하라고 보여 주는 복구 push 명령(promote 중복 착수, promote_rollback, `rd pr check --apply`, archive 의 submodule·원격 브랜치 삭제, `rd pr open` force push 안내)도 `git push --no-follow-tags …` 로 나옵니다. archive 의 원격 fr 브랜치 삭제 실패 안내는 병합을 확인한 tip 으로 lease 를 고정한 삭제 명령을 냅니다.
- **fr 브랜치에서 만든 리뷰 세션 이름에 작업 slug 가 붙음**: 작업 worktree 에서 만든 리뷰 세션 폴더 이름이 `<시각>_<slug>_<세션 종류>` 가 됩니다(예: `20261126_174331_review-session-id-collision_final-diff-review`). 서로 다른 작업이 같은 초에 세션을 만들어도 이름이 겹치지 않습니다. 기본 체크아웃·detached HEAD 의 세션과 자기 plan 의 spec/plan review 세션은 이름이 그대로입니다.
- **발행이 끝나지 않은 작업의 정리 보류 안내**: 발행 요청이 「부분 완료」·「발행 중」·「허가됨」 인 작업은 `rd task list`(와 `/fr do` 마감의 `close.sh`)가 worktree·브랜치를 지우지 않고 `정리 보류: <slug> — …` 줄에 상태별 재시도 명령을 냅니다(작업 worktree 에서 `rd publish run`, `rd publish recover`, `rd publish cancel`, worktree 를 다시 만드는 `git worktree add` 명령 등). 요청 상태를 판정하지 못해도 지우지 않습니다.
- **발행 큐의 다음 행동이 실행 위치를 알려 줌**: `rd publish status` 의 허가됨 줄과 `rd publish wait` 의 허가 보고가 `→ 작업 worktree(<경로>)에서 rd publish run` 을 냅니다. 허가 슬롯을 쥔 요청이 허가됨이면 `rd publish next` 거부 문구에도 그 다음 행동이 붙습니다. 작업 worktree 에 다른 작업이나 다른 커밋이 체크아웃돼 있으면 fr 브랜치로 되돌리는 명령을 안내하고, 허가됨인데 worktree 가 없으면 다시 만드는 방법과 `rd publish cancel` 을 냅니다. `/fr do` 의 큐 감시는 「→」 앞(slug·상태·사유)만 보고 알림을 냅니다.

### 2026-11-21-001711

- **overlay 마감 때 팀 저장소에 PR 을 올림**: 소스(submodule)에서 코드를 바꾼 overlay 작업은 final diff review 종결 뒤 `bash rd-workflow/scripts/rd pr open` 으로 팀 저장소에 PR 을 올립니다. PR 이 올라가면 작업 Status 가 `PR 검토 중` 이 되고, `rd task list` 가 submodule 별 PR 상태와 다음 행동을 보입니다. 팀이 merge 하면 `rd pr check --apply` 가 submodule 포인터를 merge 된 커밋으로 옮기고 `아카이브 보류` 로 되돌리며, 재리뷰 없이 기존 발행 절차로 갑니다. `rd pr check` 는 수정 요청·닫힘도 알립니다. archive 는 반영 방식 `pr`·`push` 인 submodule 의 새 포인터가 팀 대상 브랜치에 없으면 발행을 거부합니다(우회 `--allow-unpublished-submodule <사유>`). `light` 작업이 반영 대상 submodule 을 바꾸면 `rd pr light-check` 가 `standard` 로 상향합니다. 반영 방식은 `rd-workflow/config/workflow.json` 의 `team_publish`(`mode` `pr`·`push`·`manual`, `base`, `branch_prefix`, `light`, `submodules.<경로>`)로 고릅니다. **기본값이 `pr` 이라서 기존 overlay 사용자는 업데이트 직후 첫 발행이 거부될 수 있습니다.** 이전 방식으로 두려면 `team_publish.mode` 를 `manual` 로 적고 커밋합니다. 업데이트가 설정 파일을 자동으로 고치지 않습니다. 자세한 내용은 [`MIGRATIONS.md`](MIGRATIONS.md) M018 에 있습니다.
- **`/fr take` 추가, `/fr pull`(FR 경로)·`/fr sync` 제거**: 팀 저장소의 Issue 를 `/fr take` 로 골라 선점하고, FR 을 만들어 바로 착수합니다. 제거: `/fr pull`(FR 경로)·`/fr sync`·Issue 상태 라벨·`/fr add` 자동 Issue 발행. 추가: `/fr take`·FR 종료 상태 `handed-off`·`issue_queue.sh`. 바뀜: `/fr push` 는 내 FR 을 팀 Issue 로 넘기고 FR 을 `handed-off` 로 닫습니다. 대체 경로: 팀 Issue 는 `/fr take` 로 집고, 내 FR 은 `/fr push` 로 넘깁니다. `fr_github: true` 로 쓰던 사람은 등록 때 Issue 가 생기지 않으므로 넘기려면 `/fr push` 를 부릅니다.
  - 호환성 1: 열린 `fr:*` 라벨 Issue 는 담당자가 없으면 `/fr take` 고르기 화면에 그대로 보입니다. 별도 이관은 없습니다.
  - 호환성 2: 이미 `github-issue` 로 연결된 로컬 FR 은 그대로 둡니다. 상태 동기화가 없어지므로 이후에는 `close-fr` 이나 사람이 닫습니다.
  - 호환성 3: 원격의 `fr:*` 라벨은 지우지 않습니다.
- **리뷰어 발견의 확신도 칸 제거**: 리뷰어 발견 머리 줄이 `- F<번호> [confidence N/10] <제목>` 에서 `- F<번호> <제목>` 으로 바뀝니다. 확신도가 8~10 에만 몰려 경중 신호로 쓰이지 않았기 때문입니다. 리뷰 턴 뒤 `confidence-missing`·`appendix-confidence` 경고가 더는 나오지 않습니다. 근거 줄 없는 본문 발견은 「본문 발견에 근거 줄이 없습니다. 해소 확인·합의라면 Agreement 에 적습니다」 경고 하나로 안내합니다. 세션 폴더의 `finding_metrics.tsv` 는 마지막 `confidences` 칸이 빠져 7칸이 됩니다.
- **promote 의 submodule 을 메인 체크아웃에서 받음**: promote 가 새 worktree 의 submodule 을 원격이 아니라 메인 체크아웃에서 복제해 빨라지고, 원격에 닿지 못해도 착수합니다. 메인 체크아웃에서 초기화하지 않은 submodule 은 비워 두고, 그 경로와 받는 명령 `bash rd-workflow/scripts/rd submodule init [<경로>...]` 을 알립니다. 브랜치가 메인에 없는 submodule 커밋을 가리킬 때만 원격에서 받으며, 원격 대기는 한 번의 promote 전체에서 `RD_SUBMODULE_REMOTE_TIMEOUT` 초(기본 120)까지입니다. 받기에 실패하면 경로·원인·재시도 명령을 알리고 착수는 계속합니다. 리뷰 입력 검사가 submodule 객체 부재로 막힐 때의 첫 복구 안내도 `rd submodule init` 입니다.
- **final diff review 가 사용자 확인을 점검함**: final diff review 리뷰어가 사용자에게 보이는 결과나 백그라운드 동작이 바뀐 diff 에서 결과·진행·실패를 사용자가 볼 수 있는지 점검합니다. 빠졌거나 spec·AC 와 다르면 이의로 냅니다. 사용자에게 닿지 않는 내부 변경은 이 점검을 하지 않습니다. 이제 REQUEST review·spec/plan review·final diff review 세 단계가 모두 사용자 확인을 봅니다.
- **`/tpl update` 의 기계적 단계를 스크립트가 맡음**: `/tpl update` 가 파일 분류·복사·마이그레이션·skill 재설치·변경 이력 추출을 `sync_template.sh` 하위 명령(`policy`·`classify`·`apply`·`migrate`·`reinstall`·`changelog`)으로 처리하고, Claude 는 스크립트가 넘긴 판단 항목만 다룹니다. 그래서 update 한 번에 드는 시간이 줄어듭니다. 3단계에서 확인한 분류 목록과 복사 시점의 분류·내용이 다르면 `apply` 가 아무것도 바꾸지 않고 멈추고, 바뀐 쪽(`프로젝트 내용 바뀜`·`clone 내용 바뀜`)을 알립니다. 판단이 필요한 마이그레이션(M001·M002·M011·M014·M017, M013 의 `modified` 절)은 자동 적용하지 않고 판단 항목으로 묻습니다. 마이그레이션이 실패하면 이미 바꾼 파일과 바꾸지 않은 파일을 나눠 보고합니다. `sync_template.md` 는 1,074줄에서 약 600줄로, `MIGRATIONS.md` 는 893줄에서 약 510줄로 줄었습니다.
- **archive 뒤 `CURRENT_TASK.md` 가 배포 템플릿과 같음**: archive 가 쓰는 초기본을 배포 템플릿과 같게 맞췄습니다. `## Request` 는 `REQUEST.md`, `## Branch / Worktree` 는 `-` 이고, 쓰이지 않던 `## Output Files` 절이 없어집니다. 그래서 archive 를 거친 프로젝트도 `/tpl update` 에서 `REQUEST.md`·`CURRENT_TASK.md` 가 「판정 불가로 보존」 되지 않고 템플릿 본으로 동기화됩니다. 이전 초기본이 남은 파일도 템플릿 본으로 인정합니다. 사용자가 쓴 줄이 남아 있으면 지금처럼 보존합니다. lite 배포본의 `CURRENT_TASK.md` 도 full 과 같아집니다(`## Source FR` 절과 안내 주석이 생기고 절 순서가 같아짐). 세션 시작 안내가 Next Step 안내 주석을 값으로 보이지 않습니다.
- **발행 대기가 호출 세션의 감시 생존을 확인함**: 호출 세션의 감시(`rd publish watch`, `/fr do` 감시)가 5분 넘게 없으면 `rd publish request` 가 「경고: 호출 세션의 감시가 없습니다」 줄을 냅니다(종료 코드 0 그대로). 같은 상황에서 `rd publish wait` 는 같은 경고와 종료 코드 5 로 바로 끝나고, 요청은 큐에 「요청됨」 그대로 남습니다. 작업 세션은 사용자에게 알리고 `wait` 를 다시 띄웁니다. `rd publish watch` 는 인자 없이 실행하면 사건이 있을 때만 끝나므로 1시간마다 다시 띄울 필요가 없습니다. `--timeout <초>` 를 주면 그 시간 뒤 종료 코드 4 로 끝납니다. `/fr do` 감시는 발행 큐를 읽지 못하면 `QUEUE 조회 실패 (rc=N)` 이벤트를 냅니다.
- **`/fr list` 가 진행 중 FR 을 표시함**: 작업 worktree 나 `/fr do` 줄기가 맡은 FR 의 `착수` 칸이 `진행 중(구현 중)`·`진행 중(PR 검토 중)`·`진행 중(/fr do 줄기 <slug>)` 처럼 보입니다. 판정에 실패하면 경고 한 줄을 보이고 목록은 그대로 냅니다.
- **대화형 `/fr do` 의 설계 문답**: 착수 보고 전에 「설계 문답 / 그냥 진행」 을 한 번 묻습니다. 설계 문답을 고르면 각 줄기 탭에 설계 질문이 뜨고, 호출 세션은 대신 답하지 않고 어느 탭에서 답을 기다리는지 알립니다. 무인(`--headless`)은 바뀌지 않았습니다.
- **기록 커밋 뒤 리뷰와 수렴한 세션 재개**: 기록 커밋(REQUEST.md 비우기) 뒤 연 diff review 는 완료 기준과 effort 를 REQUEST 보관본에서 읽습니다. 수렴한 세션은 새 Author 턴을 쓴 뒤 `run_review_turn.sh <세션> --reopen "<사유>"` 로 재확인 턴을 받습니다. final-diff-review 는 중간 턴에 고친 영역의 테스트만 돌리고, 전체 검증은 seal 직전 한 번입니다.
- **사람 결정 뒤 리뷰 재개·종결·턴 연장**: 미해결 이의로 멈춘 세션은 `run_review_turn.sh <세션> --decision "<결정>"` 으로 결정을 기록하고 Reviewer 턴을 바로 돌립니다. `--override "<결정한 사람> — <그 사람이 한 말>"` 은 남은 이의를 덮고 세션을 `closed` 로 종결합니다(seal 이 거부할 세션은 미리 거부). 턴 한도에 닿은 세션은 `--extend-turns <N>` 으로 한도를 늘립니다.
- **리뷰 이의의 중요도 문턱**: 리뷰어가 이의마다 현실에서 일어나는 경로를 `경로:` 줄로 적습니다. 문구·서식·주석·유지보수성, 검증 증거의 형식 같은 지적은 Summary 끝 `메모:` 줄로 나오고 종결을 막지 않습니다. 검증 관련 이의는 검증이 실제로 결함을 덮지 못할 때만 나옵니다.
- **리뷰 비용 표시와 6턴 뒤 자동 범위 축소**: Reviewer 턴마다 `리뷰 비용: 누적 N턴 · 세션 경과 X · 리뷰 도구 Y · 토큰 …` 한 줄이 나옵니다. 6턴(`REVIEW_SCOPE_NARROW_AFTER`)을 넘기면 리뷰어는 기본 사용 경로 결함·데이터 손실·보안·요청 이탈·검증 공백만 이의로 내고, 나머지는 `범위 밖:` 줄로 적어 종결을 막지 않습니다. 사람에게 묻지 않습니다. `범위 밖:` 줄은 같은 작업의 다음 리뷰 단계에 자동으로 넘어가고, 사람이 정한 범위 밖은 REQUEST `## Constraints` 의 `- 범위 밖:` 줄로 넘깁니다. 새 세션의 `turn_metrics.tsv` 는 12열(`tokens`)입니다.
- **리뷰 모델·effort 를 `models.json` 에서 고름**: `rd-workflow/config/models.json` 에 리뷰어별 모델·effort, 리뷰 종류별 effort, small-task effort 를 적습니다. Codex 는 계열 이름(`sol` 등)으로 가장 높은 버전을 고르고, 지원하지 않는 effort 는 한 단계 낮추며 경고합니다. `RD_REVIEW_CODEX_MODEL`·`RD_REVIEW_CODEX_EFFORT`·`RD_REVIEW_CLAUDE_MODEL`·`RD_REVIEW_CLAUDE_EFFORT` 로 한 번만 바꿀 수 있습니다. 리뷰 턴 출력에 요청값과 실제 모델·effort 가 나오고, 새 세션의 `turn_metrics.tsv` 에 `model` 열이 생깁니다. `bash rd-workflow/scripts/model_select.sh show review` 가 칸마다 값과 출처를 보입니다. `/review-config`(full)는 이 파일에 씁니다. 기존 `review-tools.json` 의 모델·effort 키는 계속 동작하며 옮길 칸을 안내합니다.
- **직접 설치 프로젝트의 PR 발행(`archive_publish: pr`)**: `rd-workflow/config/workflow.json` 에 `"archive_publish": "pr"` 을 두면 발행이 fr 브랜치를 push 하고 PR 을 만들거나 갱신한 뒤 멈춥니다. 팀이 merge 하면 `rd pr check --task <작업> --apply` 가 태그를 달아 마감합니다. 수정 요청은 `rd pr reopen --task <작업>` 으로 되돌려 고칩니다. PR 이 기록 파일만 충돌하면 새 명령 `rd pr sync [--task <slug>]` 가 기본 브랜치를 병합해 PR 을 갱신합니다(재리뷰·새 seal 없음). 값이 없거나 `push` 이면 지금과 같습니다. 흐름은 `WORKFLOW.md` 「직접 설치 PR 발행」 절에 있습니다.
- **기본 브랜치 작업도 팀 저장소 PR 흐름을 씀**: 기본 브랜치에서 한 작업도 `rd pr open` → 팀 merge → `rd pr check --apply` → archive 순서로 발행합니다. `rd task list` 는 진행 중 fr 작업이 없어도 기본 체크아웃 작업의 「PR 검토 중」 표를 보이고, 행동 줄의 경로·이름·PR 주소를 작은따옴표로 인용합니다. archive 는 submodule 포인터 충돌에서 한쪽이 조상이면 자손 커밋으로 풀고, 팀 원격 조회와 받기에 시간 상한을 둡니다.
- **발행 뒤 연결된 Issue 를 닫음**: 원격 push 발행이 끝나면 Source FR 의 `github-issue` 에 적힌 Issue 마다 반영 커밋 댓글을 달고 닫습니다. 값은 `owner/repo#N` 을 쉼표로 잇거나 브라우저의 Issue URL 을 적습니다. 형식이 어긋나면 어느 Issue 도 건드리지 않고 틀린 조각을 알립니다. 닫기 실패는 발행을 실패로 두지 않고 재실행 명령을 보입니다. `issue_queue.sh close-fr` 에 `--skip-closed` 가, 장부 행만 지우는 `issue_queue.sh forget <저장소> <번호>` 가 생겼습니다. PR 본문의 `Closes` 줄은 값 형식이 맞을 때만 들어가고, 호스트가 붙은 값은 URL 로 씁니다.
- **늦게 끝난 줄기의 발행 충돌 자동 해소**: 늦은 줄기의 `archive.sh` 가 task-state 충돌을 스스로 풉니다. FR 인덱스 안의 한 줄 주석도 병합하고, 병합할 수 없는 인덱스는 병합을 시작하기 전에 사유와 함께 멈춥니다.
- **`/fr add` 가 미커밋 변경을 남기지 않음**: `/fr add`(와 `/fr take` 의 등록 단계)를 마친 뒤 기본 체크아웃의 Short Title 은 `-` 그대로이고 미커밋 변경이 남지 않습니다. 이전 버전이 남긴 Short Title 은 `rd task set-title -` 로 되돌립니다.
- **큰 FR 은 REQUEST review 에서 나눔(full)**: full 작업의 REQUEST review 리뷰어가 `분할:` 발견을 내면 Author 는 묻지 않고 범위를 선행 없는 기능으로 좁히고, 뗀 기능은 후속 FR 로 등록합니다.
- **`self_test.sh` 에 테스트 파일 하나만 돌리기**: `bash rd-workflow/scripts/self_test.sh test_tasks_list.sh` 처럼 테스트 파일 이름이나 검사 함수 이름을 주면 그 스텝만 돕니다. 맞는 스텝이 없으면 FAIL 로 끝납니다. 그룹과 함께 주면 합집합을 돕니다.

### 2026-11-08-092219

- **`/fr groom` 추가**: `/fr groom <제목>` 으로 idea 상태 FR 한 건을, `/fr groom` 으로 idea FR 전부를 차례로 문답 검증합니다. AI 가 한 번에 한 질문과 권장 답을 내고, 마지막에 validated·parked·dropped 중 하나를 제안합니다. 결정하면 상세 파일에 `## groom 기록` 이 남고 상태가 바뀝니다. 일괄 모드에서는 「건너뛰기」·「중단」 을 말할 수 있고, 끝에 결과 요약표가 나옵니다. 사용자가 직접 요청할 때만 실행합니다.
- **`/fr do` 의 idea FR 확인**: 대화형 `/fr do` 는 띄울 줄기에 idea FR 이 있을 때만 「groom 먼저 / 그대로 띄우기」 를 묻습니다. groom 을 고르면 결과를 기본 브랜치에 커밋한 뒤 후보를 다시 골라 띄우고, groom 을 중단하면 그 `/fr do` 는 새 줄기를 띄우지 않습니다. 무인 `/fr do --headless` 는 동작이 같고, 뺀 FR 표에 「groom 대상」 표시만 더합니다.

## 전제 조건

- [Claude Code](https://claude.ai/code) 설치 및 로그인 (2.1.310 이상 — 그 미만은 `.claude/rules/` 하위 폴더 로드를 보장하지 않습니다)
- [Superpowers](https://github.com/anthropics/claude-code-superpowers) 플러그인 설치

## 빠른 시작

프로젝트 디렉토리에서 Claude Code를 열고:

```text
이 AI 워크플로 템플릿 적용해: https://github.com/JuseongJee/review-driven-ai-workflow-lite
```

> **Claude에게:** 이 요청을 받았다면 [`rd-workflow/docs/guides/setup_with_claude.md`](rd-workflow/docs/guides/setup_with_claude.md)를 읽고 절차대로 실행하세요.

AI가 필요한 파일을 가져온 뒤, 프로젝트에 대해 질문하면서 PROJECT_CONTEXT.md를 함께 채워줍니다. 빈 폴더에서 시작해도 대화를 통해 프로젝트의 목적, 산출물, 품질 기준을 구체화합니다.


### 적용 후

설정이 끝나면 바로 첫 작업을 시작합니다:

```text
이 요구사항으로 진행해줘: ...
```

## 사용 예시 — 단계별 프롬프트

### `full` 등급

```text
1. "이 요구사항으로 진행해줘: 면접 질문지에 컬쳐 인터뷰 항목 추가"
   → AI가 REQUEST를 작성하고 review를 시작합니다

2. (review 확인, AI의 질문에 답변 후) "진행해"
   → AI가 spec과 plan을 작성하고 review를 시작합니다

3. (spec/plan review 확인, 필요시 수정 방향 전달 후) "진행해"
   → AI가 작성을 시작합니다

4. 작성 완료 → AI가 자동으로 검증 + 산출물 review를 진행합니다

5. (review 확인 후) "좋아, 마무리해줘"
```

### `standard` 등급

```text
1. "운영 매뉴얼의 고객 응대 섹션 업데이트해줘"
   → AI 가 등급(`standard`) 을 보고하고 작성 → 검증 → review 까지 진행합니다
```

### Autopilot

```text
1. "/autopilot"
   → 백로그에서 작업을 선택하고 전체 파이프라인을 자율 실행합니다
```

사용자가 하는 건 **요구사항 전달 + review 결과 판단** 정도입니다. 나머지는 워크플로가 이어갑니다.

## 핵심 구조

| 파일 | 역할 |
|------|------|
| `CLAUDE.md` | 프로젝트 규칙 (프로젝트 소유 — sync 가 덮어쓰지 않음) |
| `.claude/rules/rd-workflow/` | AI 실행 규칙 (템플릿 소유 — sync 가 덮어씀) |
| `PROJECT_CONTEXT.md` | 프로젝트/도메인 메타데이터 |
| `REQUEST.md` | 현재 작업 요청서 |
| `CURRENT_TASK.md` | 진행 중인 작업 상태 |
| `WORKING_WITH_AI.md` | 사용법 치트시트 |

## 워크플로

모든 작업은 위험 등급(`light` / `standard` / `full`) 에 따라 절차가 달라집니다. 등급은 AI 가 `rd-workflow/docs/flows/WORKFLOW.md` 위험 등급 절의 신호표로 판정해 시작 보고를 내고, 하향은 사용자만 합니다.

### `full` (새 기능, 산출물 구조·품질 기준의 큰 변경)

FR 자동 등록 → REQUEST 작성 → REQUEST review → spec/plan → spec/plan review → 실행 → 검증 → final output review → 아카이브

### `standard` (국소 변경)

promote → 축약 REQUEST → 실행 → 검증 → 재분류 → final output review → 아카이브

### `light` (문구·포맷 수정)

실행 → 검증 → 재분류 → 기본 브랜치 커밋 1회 (+ `reports/tier-log.md` 행, 원격 모드면 push — 실패 시 "미push" 로 보고). REQUEST·리뷰·아카이브 없음

## Developer 버전과의 차이

| 항목 | Developer | Lite |
|------|-----|------|
| 검증 | test.sh + lint.sh + typecheck.sh | verify.sh (프롬프트 기반) |
| 최종 리뷰 | diff review (코드 변경) | output review (산출물 품질) |
| PROJECT_CONTEXT | tech stack, build 명령 | 도메인, 산출물 유형, 품질 기준 |
| 스킬 | 12개 | 6개 (핵심만) |
| 리뷰 파이프라인 | 동일 | 동일 |
| Superpowers | 동일 | 동일 |

## 템플릿 업데이트

이미 적용된 프로젝트에서 최신 버전으로 업데이트하는 방법입니다.

### URL로 업데이트 (repo 접근 가능할 때)

```text
/tpl update
```

또는:

```text
이 템플릿으로 업데이트해: https://github.com/JuseongJee/review-driven-ai-workflow-lite
```


## 문서

- [초기 설정 가이드](rd-workflow/docs/guides/setup.md)
- [사용자 매뉴얼](rd-workflow/docs/USER_MANUAL.md)
- [워크플로 판단 기준](rd-workflow/docs/flows/WORKFLOW.md)
- [문서 인덱스](rd-workflow/docs/AI_DOC_MAP.md)
