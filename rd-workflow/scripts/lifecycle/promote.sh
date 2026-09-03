#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# project_root 를 source 이전에 확정한다 — _lifecycle_common.sh → _state_common.sh 가
# TASK_STATE_PATH 를 source 시점에 굳히므로, 순서를 바꾸면 상태가 엉뚱한 파일에 기록된다.
# 주입값 우선(테스트), 없으면 스크립트 위치 기준. readlink -f 를 쓰지 않는다.
if [[ -z "${project_root:-}" ]]; then
  project_root="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi
if [[ ! -d "${project_root}/rd-workflow-workspace" ]]; then
  echo "promote: 프로젝트 루트를 확정할 수 없습니다: '${project_root}' 에 rd-workflow-workspace/ 가 없습니다." >&2
  echo "  확인: ls -d '${project_root}/rd-workflow-workspace'" >&2
  exit 3
fi
export project_root
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"

DRY_RUN=0; SHORT_TITLE=""; WORKTREE_PATH=""; NO_WORKTREE=0; STATUS_VAL=""; SIZE_VAL=""; SOURCE_FR_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --short-title) SHORT_TITLE="$2"; shift 2 ;;
    --worktree-path) WORKTREE_PATH="$2"; shift 2 ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    # 값을 읽기 전에 남은 인자 수를 확인한다. `STATUS_VAL="$2"` 만 쓰면 값이 빠졌을 때
    # set -u 가 `$2: unbound variable` 로 죽어, 허용값 안내 대신 내부 Bash 오류가 보인다.
    --status)
      [[ $# -ge 2 ]] || { echo "promote: --status 에 값이 없습니다 — canonical 상태 문자열을 지정하세요." >&2; exit 1; }
      STATUS_VAL="$2"; shift 2 ;;
    --size)
      [[ $# -ge 2 ]] || { echo "promote: --size 에 값이 없습니다 — large 또는 small 을 지정하세요." >&2; exit 1; }
      SIZE_VAL="$2"; shift 2 ;;
    --source-fr) SOURCE_FR_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "usage: promote.sh --short-title <slug> (--size large|small | --status <canonical>) [--worktree-path <path>] [--no-worktree] [--source-fr <path|->] [--dry-run]"; exit 0 ;;
    *) echo "promote: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- 시작 상태 결정 (change spec D1·D2) ---
# 사람이 canonical 8종 문자열을 직접 고르는 구조가 실수의 원인이므로 경로 2택으로 좁힌다.
# --status 는 복구·마이그레이션 전용으로 남기되 canonical 검사를 붙인다 — 종전에는
# state_write_fields 직접 호출로 전이표와 이름 검사를 모두 우회했다.
# 이 블록은 metadata_write 보다 훨씬 앞이라 어떤 상태도 바뀌지 않는다.
if [[ -n "$SIZE_VAL" && -n "$STATUS_VAL" ]]; then
  echo "promote: --size 와 --status 는 함께 쓸 수 없습니다 (둘 다 시작 상태를 정합니다)." >&2
  exit 1
fi
if [[ -n "$SIZE_VAL" ]]; then
  case "$SIZE_VAL" in
    large) STATUS_VAL="대기 중" ;;
    small) STATUS_VAL="구현 중" ;;
    *) echo "promote: --size 값이 올바르지 않습니다: '$SIZE_VAL' — large 또는 small 만 허용합니다." >&2
       echo "  large = 큰 작업(REQUEST 작성 전 승격), small = 작은 작업(바로 구현)" >&2
       exit 1 ;;
  esac
elif [[ -n "$STATUS_VAL" ]]; then
  # canonical 판정은 이미 로드된 _state_common.sh 것을 쓴다 (제3 복제 금지)
  if ! _state_status_canonical "$STATUS_VAL"; then
    echo "promote: --status 값이 canonical 8종이 아닙니다: '$STATUS_VAL'" >&2
    echo "  허용: ${STATE_CANONICAL_STATUSES//|/, }" >&2
    exit 1
  fi
else
  echo "promote: 시작 상태를 지정하세요 — --size large (큰 작업) 또는 --size small (작은 작업)." >&2
  echo "  복구·마이그레이션 목적으로 특정 단계로 진입하려면 --status <canonical> 를 쓰세요." >&2
  exit 1
fi

# --source-fr 명시 인자 검증 (사용자 명시 오류는 hard error — 추론 실패와 구분)
if [[ -n "$SOURCE_FR_ARG" ]] && ! source_fr_validate "$SOURCE_FR_ARG"; then
  echo "promote: --source-fr 값 계약 위반 — '-' 또는 rd-workflow-workspace/backlog/items/<파일>.md 만 허용: $SOURCE_FR_ARG" >&2
  exit 1
fi

# I2 — --no-worktree + --worktree-path 충돌 검출
if [[ "$NO_WORKTREE" -eq 1 && -n "$WORKTREE_PATH" ]]; then
  echo "promote: --no-worktree와 --worktree-path는 함께 사용할 수 없습니다." >&2; exit 1
fi

# Short title 자동 추출 (trim-only — 내부 공백 보존)
if [[ -z "$SHORT_TITLE" && -f "$project_root/CURRENT_TASK.md" ]]; then
  SHORT_TITLE="$(awk '/^## Short Title/{flag=1; next} flag && /^[^#]/{sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print; exit}' "$project_root/CURRENT_TASK.md")"
fi
[[ -z "$SHORT_TITLE" || "$SHORT_TITLE" == "-" ]] && { echo "promote: --short-title 필수" >&2; exit 1; }
SLUG="$(normalize_slug "$SHORT_TITLE")"

# source-fr 값 결정: 인자 > REQUEST.md 해석 > '-'
# 해석은 source_fr_resolve(_state_common.sh) 단일 구현이 담당한다 — 여기서 파싱하지 않는다.
# 값이 있는데 해석에 실패하면 return 1 로 승격을 중단시킨다. 조용히 '-' 를 기록하면
# archive 의 FR done 자동 처리가 무동작하고, 그 사실이 작업 종료 시점에야 드러난다.
resolve_source_fr() {
  if [[ -n "$SOURCE_FR_ARG" ]]; then printf '%s\n' "$SOURCE_FR_ARG"; return 0; fi
  # 파일 부재는 값 해석 실패와 다른 사유로 알린다 — 이 결정으로 새로 막히는 사용자가
  # 스스로 복구할 수 있어야 한다 (change spec D8).
  if source_fr_request_missing "$project_root/REQUEST.md"; then
    echo "promote: REQUEST.md 가 없습니다 — ${project_root}/REQUEST.md" >&2
    echo "  정상 흐름에서는 이 파일이 항상 존재합니다(템플릿에 포함되고 archive 가 되돌립니다)." >&2
    echo "  다음 중 하나로 진행하세요:" >&2
    echo "    1) REQUEST.md 를 복원합니다 (템플릿: _ROOT_FILES/REQUEST.md)" >&2
    echo "    2) --source-fr rd-workflow-workspace/backlog/items/<파일>.md 를 지정합니다" >&2
    echo "    3) FR 없이 시작하는 작업이면 --source-fr - 를 지정합니다" >&2
    return 1
  fi
  # local 선언과 대입을 분리한다 — `local x="$(cmd)"` 는 local 의 종료 코드가
  # 대입을 덮어써 해석 실패가 전파되지 않는다.
  local raw resolved
  raw="$(source_fr_from_request)"
  if ! resolved="$(source_fr_resolve "$raw")"; then return 1; fi
  printf '%s\n' "${resolved:--}"
}

# --worktree-path canonicalize (relative→absolute / parent missing hard error)
if [[ -n "$WORKTREE_PATH" ]]; then
  if [[ "$WORKTREE_PATH" != /* ]]; then
    PARENT="$(dirname "$WORKTREE_PATH")"
    [[ -d "$PARENT" ]] || { echo "promote: --worktree-path parent 미존재: $PARENT" >&2; exit 1; }
    WORKTREE_PATH="$(cd "$PARENT" && pwd)/$(basename "$WORKTREE_PATH")"
  fi
  echo "promote: canonical worktree-path=$WORKTREE_PATH"
fi

# 기준 위치를 루트로 옮긴다. --worktree-path 는 호출자 cwd 기준 해석이 정상이므로
# 위의 canonicalize 를 반드시 지나온 뒤여야 한다 (change spec D7).
cd "$project_root"

# Step 0 — metadata 확인
TARGET_BRANCH=""; STORED_WT=""; IS_RERUN=0
if metadata_exists; then
  EXISTING_SHORT="$(metadata_read_field short-title)"
  EXISTING_BRANCH="$(metadata_read_field fr-branch)"
  STORED_WT="$(metadata_read_field worktree-path)"
  # stale 감지 — fr-branch가 실재하는 로컬 브랜치가 아니면 진행 불가 (refs/heads 전용 판정: 동명 tag 배제)
  if ! git rev-parse --verify "refs/heads/$EXISTING_BRANCH" >/dev/null 2>&1; then
    echo "promote: task-state의 fr-branch($EXISTING_BRANCH)가 실재하지 않는 stale 상태입니다 (short-title=$EXISTING_SHORT)." >&2
    echo "  원인 후보: 브랜치 수동 삭제, 또는 이전 archive/rollback 비정상 종료." >&2
    echo "  복구: bash rd-workflow/scripts/lifecycle/promote_rollback.sh (기본 브랜치 worktree — task-state fr 필드 reset 포함) 후 promote 재시도." >&2
    exit 1
  fi
  if [[ "$EXISTING_SHORT" == "$SLUG" ]]; then
    TARGET_BRANCH="$EXISTING_BRANCH"
    echo "promote: metadata 발견 (idempotent rerun) — fr-branch=$TARGET_BRANCH, stored worktree-path=$STORED_WT"
    # idempotent rerun 은 source-fr 를 갱신하지 않는다 — rerun 경로는 커밋을 만들지 않으므로
    # 갱신하면 uncommitted dirty task-state 가 남는다 (final diff review Finding 1).
    # 동일 값 인자는 복구 rerun 호환을 위해 no-op 허용, 다른 값은 거부 — 정정 단일 경로는 rd task set-source-fr.
    if [[ -n "$SOURCE_FR_ARG" ]]; then
      STORED_SRC="$(metadata_read_field source-fr)"
      if [[ "$SOURCE_FR_ARG" != "${STORED_SRC:--}" ]]; then
        echo "promote: idempotent rerun 에서는 source-fr 를 갱신하지 않습니다 (stored=${STORED_SRC:--}, 인자=$SOURCE_FR_ARG)." >&2
        echo "  정정하려면: bash rd-workflow/scripts/rd task set-source-fr '$SOURCE_FR_ARG' 실행 후 변경을 정규 커밋에 포함하세요." >&2
        exit 1
      fi
      echo "promote: source-fr 동일 값 재지정 (${SOURCE_FR_ARG}) — 변경 없음"
    fi
    if [[ -n "$WORKTREE_PATH" && "$WORKTREE_PATH" != "$STORED_WT" ]]; then
      echo "promote: 기존 worktree path 와 다름 (metadata=$STORED_WT, 인자=$WORKTREE_PATH)." >&2
      echo "  metadata 갱신 후 재시도 또는 --worktree-path 인자 생략 권장." >&2; exit 1
    fi
    # rerun 에서 시작 상태 인자는 status 에 대해 **no-op** 이다. 실제 값은 Step C 의
    # mutation 직전에 대상 권위(task-state)를 읽어 정한다 — 근거는 그 블록 주석에 있다.
    IS_RERUN=1
  else
    echo "promote: 이미 진행 중인 fr ($EXISTING_BRANCH, short-title=$EXISTING_SHORT)." >&2
    echo "  archive.sh 또는 promote_rollback.sh 후 재시도." >&2; exit 1
  fi
fi

# Step A — 기본 브랜치 worktree 검증
MAIN_WT="$(get_main_worktree_path)" || { echo "promote: 기본 브랜치 worktree 검출 실패" >&2; exit 1; }
CURRENT_WT="$(git rev-parse --show-toplevel)"
if [[ "$MAIN_WT" != "$CURRENT_WT" ]]; then
  DB="$(get_default_branch)"
  echo "promote: 기본 브랜치($DB) worktree에서 호출하세요. 해당 worktree path: $MAIN_WT" >&2; exit 1
fi

# Step B — metadata 부재 시 신규 결정
if [[ -z "$TARGET_BRANCH" ]]; then
  TARGET_BRANCH="$(resolve_unique_ref branch "fr/$SLUG")"
  # set -e 에 의존하지 않고 명시적으로 검사한다. 이 시점은 metadata_write 직전이며
  # 앞선 Step 0·A 는 읽기·검증뿐이므로, 여기서 끝내면 어떤 상태도 바뀌지 않는다.
  # 해석은 read-only 이므로 --dry-run 조기 종료보다 **앞**에 둔다. 뒤에 두면 사전 점검이
  # 성공을 알리고 실제 실행만 실패해, dry-run 이 반대 신호를 내는 도구가 된다.
  if ! SOURCE_FR_VAL="$(resolve_source_fr)"; then
    # 아래 두 줄은 값 해석 전용 문구다. 부재 분기는 이미 자체 메시지와 복구 안내를
    # 냈으므로, 여기서 다시 붙이면 두 사유가 한 출력에 섞여 구분되지 않는다.
    if ! source_fr_request_missing "$project_root/REQUEST.md"; then
      echo "promote: REQUEST.md 의 Source FR 을 해석할 수 없어 중단합니다 (상태 변경 없음)." >&2
      echo "  REQUEST.md 를 고친 뒤 같은 명령을 다시 실행하세요." >&2
    fi
    exit 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "would create branch $TARGET_BRANCH"; exit 0; fi
  metadata_write "$TARGET_BRANCH" "$SLUG" "${WORKTREE_PATH:-null}" "$SOURCE_FR_VAL"
  # 권위 status를 뷰(Step D CURRENT_TASK.md)와 동일 값으로 기록 — 권위-뷰 이원화 방지
  state_write_fields "status=$STATUS_VAL"
  # v2 2b: LIFECYCLE_METADATA_PATH 폐지 → TASK_STATE_PATH 사용 (LC-05)
  # add 실패를 삼키면 안 된다 — 경로 한정 커밋은 워킹트리 내용을 취하므로
  # "직전 add 로 index 와 워킹트리가 같다" 는 전제가 add 성공에 달려 있다
  # (promote_rollback.sh·archive.sh 와 같은 fail-fast 형태).
  if ! git add "$TASK_STATE_PATH"; then
    echo "promote: task-state staging 실패 — 중단" >&2
    exit 1
  fi
  # --no-verify: git pre-commit·commit-msg hook 우회 (main/master 차단 hook 대응).
  #   차단 대상 브랜치일 때만 붙인다 — trunk 등 커스텀 기본 브랜치는 hook 이 막지 않으므로
  #   붙이면 소비 프로젝트의 검증만 불필요하게 줄어든다
  # RD_LIFECYCLE_BYPASS_REASON: rd-workflow PreToolUse hook 용 — 별개 계층이라 둘 다 필요하다.
  #   이쪽은 브랜치와 무관하게 항상 유지한다
  # pathspec: 사용자가 미리 stage 해 둔 무관한 파일이 이 커밋에 딸려 들어가지 않게 한다
  _nv=""
  if lifecycle_needs_hook_bypass; then _nv="--no-verify"; fi
  RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit ${_nv:+"$_nv"} \
    -m "chore(lifecycle): promote $SLUG metadata 기록" -- "$TASK_STATE_PATH"
  if [[ -n "$_nv" ]]; then lifecycle_notify_hook_bypass promote; fi
  # 브랜치를 metadata 커밋 뒤에 생성 — fr 브랜치가 task-state 정합 커밋을 포함해 baseline 회귀 방지
  git branch "$TARGET_BRANCH"
  echo "promote: branch $TARGET_BRANCH 생성"
fi

[[ "$DRY_RUN" -eq 1 ]] && { echo "would proceed (idempotent rerun)"; exit 0; }

# Step C — TARGET_WT_PATH 결정 (metadata > 인자)
TARGET_WT_PATH=""
if [[ -n "$STORED_WT" && "$STORED_WT" != "null" ]]; then
  TARGET_WT_PATH="$STORED_WT"
elif [[ -n "$WORKTREE_PATH" ]]; then
  TARGET_WT_PATH="$WORKTREE_PATH"
fi

# rerun 의 권위 검증은 **Step C 의 어떤 mutation 보다 앞**이다
# (final diff review 4라운드 Finding 1).
#
# 뒤에 두면 metadata 의 worktree 가 제거된 상태에서 대상 브랜치의 status 가 손상돼 있을 때,
# `git worktree add` 로 새 worktree 와 등록을 만든 뒤 "(상태 변경 없음)" 이라며 실패한다.
# no-worktree rerun 도 `git switch` 로 브랜치를 옮긴 뒤 실패한다. fail-closed 의 정의는
# "실패했다" 가 아니라 **"아무것도 바뀌지 않았다"** 이므로 worktree 목록·HEAD 도 포함된다.
#
# 읽기 출처는 두 갈래다. 둘 다 read-only 다.
#   - 대상 worktree 가 이미 있으면 그 파일 (커밋 전 진행분이 있을 수 있어 파일이 더 최신)
#   - 없으면 대상 브랜치의 blob (`git show <branch>:<path>`) — worktree 를 만들지 않고 읽는다
if [[ "$IS_RERUN" -eq 1 ]]; then
  RERUN_STATE_REL="rd-workflow-workspace/.lifecycle/task-state"
  RERUN_WT_NOW=""
  if [[ -n "$TARGET_WT_PATH" ]]; then
    RERUN_WT_NOW="$(git worktree list --porcelain | awk -v b="$TARGET_BRANCH" '
      /^worktree /{p=$0; sub(/^worktree /,"",p); next}
      $0=="branch refs/heads/"b{print p; exit}')"
  fi
  if [[ -n "$RERUN_WT_NOW" ]]; then
    # 등록된 대상 worktree 가 있으면 **그 파일만** 권위다. 파일이 없거나 읽을 수 없는 것은
    # "worktree 가 없음" 이 아니라 **권위 부재·손상**이므로 blob 으로 물러서지 않는다
    # (final diff review 5라운드 Finding 1). 물러서면 브랜치에 남은 승격 시점 blob 의
    # 시작 상태를 채택해 미러를 되돌리고, 그 변경을 커밋하면서 "완료" 를 보고한다.
    if [[ ! -f "$RERUN_WT_NOW/$RERUN_STATE_REL" || ! -r "$RERUN_WT_NOW/$RERUN_STATE_REL" ]]; then
      echo "promote: 대상 worktree 의 권위 파일이 없거나 읽을 수 없습니다 (상태 변경 없음)." >&2
      echo "  경로: $RERUN_WT_NOW/$RERUN_STATE_REL" >&2
      echo "  브랜치에 남은 승격 시점 값으로 물러서지 않습니다 — 그러면 진행 단계가 조용히 되돌아갑니다." >&2
      # 복구 안내 설계 (final diff review 6·7라운드 Finding 1·2):
      #
      # ① `git checkout -- <파일>` 만 안내하면 안 된다. 그것은 삭제 직전의 워킹트리 값이
      #    아니라 **index/HEAD 의 승격 시점 값**을 되살린다. 진행 중 갱신은 즉시 커밋되지
      #    않으므로 그 값은 보통 시작 상태다. 그대로 재시도하면 rerun 이 오래된 값을 권위로
      #    확정해, 이 검사가 막으려던 회귀를 복구 절차가 재현한다.
      # ② 되돌아가는 것은 status 만이 아니다. `rd task set-source-fr`·`set-title` 도
      #    task-state 만 고치고 커밋을 남기지 않으므로 `source-fr`·`short-title` 도 같이
      #    과거 값이 된다. status 만 되돌려 놓고 "복구 완료" 라고 말하면 Source FR 유실이
      #    조용히 남아 archive 가 다른 FR 을 완료 처리한다.
      # ③ **실행 가능한 명령에 파일 내용을 끼워 넣지 않는다.** 미러 값이나 worktree 경로를
      #    따옴표 안에 그대로 넣으면, 값에 `'` 나 `;` 가 있을 때 출력된 명령의 따옴표가
      #    닫히고 사용자가 그것을 복사 실행한다. 그래서 경로는 `printf %q` 로 인코딩하고,
      #    미러 status 는 **canonical 8종을 통과할 때만** 값으로 보여준다(고정 집합이라
      #    안전하다). 통과하지 못하면 값을 노출하지 않고 사람이 확인하게 한다.
      _rc_wt_q="$(printf '%q' "$RERUN_WT_NOW")"
      _rc_rel_q="$(printf '%q' "$RERUN_STATE_REL")"
      _rc_mirror=""
      if [[ -r "$RERUN_WT_NOW/CURRENT_TASK.md" ]]; then
        _rc_raw="$(awk '/^## Status/{f=1; next} f && /^[^#]/{print; exit}' \
          "$RERUN_WT_NOW/CURRENT_TASK.md" 2>/dev/null || true)"
        if [[ -n "$_rc_raw" ]] && _state_status_canonical "$_rc_raw"; then
          _rc_mirror="$_rc_raw"
        fi
      fi
      echo "  복구 절차 — **이 파일은 status 외에 short-title·source-fr 도 담습니다.**" >&2
      echo "    되살린 파일은 승격 시점 값이므로, 그 뒤 CLI 로 고쳤던 필드는 모두 과거 값입니다." >&2
      echo "    1) 그 worktree 에서 파일을 되살립니다:" >&2
      echo "       (cd $_rc_wt_q && git checkout -- $_rc_rel_q)" >&2
      echo "    2) 아래 세 필드를 **각각 확인해 현재 값으로 다시 기록합니다.** 하나라도 건너뛰면" >&2
      echo "       그 필드가 승격 시점 값으로 남습니다:" >&2
      if [[ -n "$_rc_mirror" ]]; then
        echo "       - status: 미러의 현재 단계는 '$_rc_mirror' 입니다 (canonical 확인됨)" >&2
        echo "         (cd $_rc_wt_q && bash rd-workflow/scripts/rd task set-status $(printf '%q' "$_rc_mirror") --force)" >&2
      else
        echo "       - status: 미러에서 canonical 값을 얻지 못했습니다 — 실제 단계를 사람이 확인하세요" >&2
        echo "         (cd $_rc_wt_q && bash rd-workflow/scripts/rd task set-status '<현재 단계>' --force)" >&2
      fi
      # ④ **세 명령 모두 대상 worktree 에 묶는다** (final diff review 8라운드 Finding 2).
      #    1단계 checkout 은 subshell 이라 호출자의 cwd 를 바꾸지 않는다. 그래서 `cd` 없이
      #    `rd task ...` 만 안내하면, 안내를 성실히 따른 사용자가 promote 를 호출한 기본
      #    worktree 의 task-state 를 고치고 대상에는 승격 시점 값이 남는다.
      #
      #    값을 적을 수 있는 필드와 적으면 안 되는 필드를 구분한다.
      #    - short-title 은 `$SLUG` 을 적는다. 작업 시작 시 1회 부여되고 archive 까지
      #      immutable 이며(`set-title --force` 는 복구 전용), 이 값이 metadata 와 일치한
      #      것이 곧 rerun 판정 근거다. 즉 승격 시점 값 = 현재 값이 계약으로 보장된다.
      #    - source-fr 는 **값을 적지 않는다.** rerun 에서 `--source-fr` 인자는 stored 와
      #      같아야 통과하므로(위 idempotent 블록), 그 값은 정확히 "승격 시점 값" 이고
      #      되살린 파일이 담고 있는 stale 값과 같다. 그것을 복구 목표로 제시하면 이
      #      안내가 막으려는 회귀를 안내가 지시하는 것이 된다. 현재 값을 아는 것은 사람뿐이다.
      echo "       - short-title: '$SLUG' (시작 시 1회 부여되고 archive 까지 immutable — 이 값이 맞습니다)" >&2
      echo "         (cd $_rc_wt_q && bash rd-workflow/scripts/rd task set-title $(printf '%q' "$SLUG") --force)" >&2
      # source-fr 도 미러가 담게 됐으므로(change spec D12) 값을 제시할 수 있다.
      # `source_fr_validate` 를 통과할 때만 쓴다 — 통과 조건이 고정 문법이라 실행
      # 문자열에 넣어도 안전하고, canonical status 8종에 적용한 규칙과 같다.
      # rerun 의 `--source-fr` 인자는 여전히 쓰지 않는다: stored 와 같아야 통과하므로
      # 정확히 stale 값이고, 그것을 복구 목표로 제시하면 안내가 회귀를 지시하게 된다.
      _rc_sfr=""
      if [[ -r "$RERUN_WT_NOW/CURRENT_TASK.md" ]]; then
        _rc_sfr_raw="$(awk '$0=="## Source FR"{f=1; next} f && /^[^#]/{print; exit}' \
          "$RERUN_WT_NOW/CURRENT_TASK.md" 2>/dev/null || true)"
        if [[ -n "$_rc_sfr_raw" ]] && source_fr_validate "$_rc_sfr_raw"; then _rc_sfr="$_rc_sfr_raw"; fi
      fi
      if [[ -n "$_rc_sfr" ]]; then
        echo "       - source-fr: 미러의 현재 값은 '$_rc_sfr' 입니다 (값 계약 확인됨)" >&2
        echo "         (cd $_rc_wt_q && bash rd-workflow/scripts/rd task set-source-fr $(printf '%q' "$_rc_sfr"))" >&2
      else
        echo "       - source-fr: 미러에서 계약을 통과하는 값을 얻지 못했습니다 — 사람이 확인하세요" >&2
        echo "         rerun 의 --source-fr 인자는 승격 시점 값과 같아야 통과하므로 쓸 수 없습니다." >&2
        echo "         (cd $_rc_wt_q && bash rd-workflow/scripts/rd task set-source-fr '<path|->')" >&2
      fi
      echo "         Source FR 은 되돌아가도 실행이 성공하므로 유실이 드러나지 않습니다." >&2
      echo "         archive 가 다른 FR 을 완료 처리하지 않도록 여기서 반드시 확인하세요." >&2
      echo "    3) 세 필드를 확인한 뒤 promote 를 재시도합니다." >&2
      exit 1
    fi
    # 전체 본문을 한 번 읽어 둔다 — status 와 source-fr 를 같은 스냅샷에서 판정해야
    # 두 필드가 서로 다른 시점의 파일을 가리키지 않는다 (change spec D12-4).
    if ! RERUN_STATE_TEXT="$(cat "$RERUN_WT_NOW/$RERUN_STATE_REL")"; then
      echo "promote: 대상 worktree 의 권위 파일을 읽지 못했습니다 (상태 변경 없음)." >&2
      echo "  경로: $RERUN_WT_NOW/$RERUN_STATE_REL" >&2
      exit 1
    fi
    if ! RERUN_STATUS="$(printf '%s\n' "$RERUN_STATE_TEXT" \
      | awk -F'=' '$1=="status"{sub(/^[^=]+=/,""); print; exit}')"; then
      echo "promote: 대상 worktree 의 권위 파일을 읽지 못했습니다 (상태 변경 없음)." >&2
      echo "  경로: $RERUN_WT_NOW/$RERUN_STATE_REL" >&2
      exit 1
    fi
    RERUN_SRC_DESC="$RERUN_WT_NOW/$RERUN_STATE_REL"
    # 미러도 **같은 트리에서** 읽는다. 출처를 짝짓지 않으면 다른 git tree 의 두 파일을
    # 비교하게 되어 정상 상태를 divergence 로 오판한다 (final diff review 9라운드 Finding 1).
    RERUN_MIRROR_DESC="$RERUN_WT_NOW/CURRENT_TASK.md"
    if [[ -r "$RERUN_WT_NOW/CURRENT_TASK.md" ]]; then
      RERUN_MIRROR_TEXT="$(cat "$RERUN_WT_NOW/CURRENT_TASK.md")" || RERUN_MIRROR_TEXT=""
    else
      RERUN_MIRROR_TEXT=""
    fi
  else
    # worktree 가 없으면 브랜치 blob 을 읽는다 — 여기서 worktree 를 만들면 그것이 곧
    # "실패했는데 뭔가 만들었다" 가 된다.
    if ! RERUN_BLOB="$(git show "$TARGET_BRANCH:$RERUN_STATE_REL" 2>/dev/null)"; then
      echo "promote: 대상 브랜치($TARGET_BRANCH)에서 task-state 를 읽을 수 없어 rerun 을 진행할 수 없습니다 (상태 변경 없음)." >&2
      echo "  확인: git show '$TARGET_BRANCH:$RERUN_STATE_REL'" >&2
      exit 1
    fi
    RERUN_STATE_TEXT="$RERUN_BLOB"
    RERUN_STATUS="$(printf '%s\n' "$RERUN_BLOB" | awk -F'=' '$1=="status"{sub(/^[^=]+=/,""); print; exit}')"
    RERUN_SRC_DESC="$TARGET_BRANCH:$RERUN_STATE_REL"
    # 권위를 브랜치 blob 에서 읽었으므로 미러도 **같은 브랜치 blob** 에서 읽는다.
    # 기본 worktree 의 `CURRENT_TASK.md` 는 대상 브랜치의 미러가 아니다 — 보통 baseline
    # 이거나 다른 작업의 값이므로, 비교하면 정상 rerun 이 거짓 divergence 로 막힌다.
    RERUN_MIRROR_DESC="$TARGET_BRANCH:CURRENT_TASK.md"
    RERUN_MIRROR_TEXT="$(git show "$TARGET_BRANCH:CURRENT_TASK.md" 2>/dev/null)" \
      || RERUN_MIRROR_TEXT=""
  fi
  if [[ -z "$RERUN_STATUS" ]]; then
    echo "promote: 대상 권위($RERUN_SRC_DESC)에 status 가 없어 rerun 을 진행할 수 없습니다 (상태 변경 없음)." >&2
    echo "  복구: bash rd-workflow/scripts/rd task set-status '<canonical>' 후 재시도." >&2
    exit 1
  fi
  if ! _state_status_canonical "$RERUN_STATUS"; then
    echo "promote: 대상 권위($RERUN_SRC_DESC)의 status 가 canonical 8종이 아닙니다: '$RERUN_STATUS' (상태 변경 없음)." >&2
    echo "  허용: ${STATE_CANONICAL_STATUSES//|/, }" >&2
    echo "  복구: bash rd-workflow/scripts/rd task set-status '<canonical>' 후 재시도." >&2
    exit 1
  fi
  if [[ "$RERUN_STATUS" != "$STATUS_VAL" ]]; then
    echo "promote: rerun 이므로 시작 상태 인자를 무시하고 권위 상태를 씁니다 (현재=$RERUN_STATUS)."
  fi
  STATUS_VAL="$RERUN_STATUS"

  # --- source-fr divergence 판정 (change spec D12-4) ---
  #
  # 권위 파일이 사라진 뒤 index 에서 되살리면 `source-fr` 가 승격 시점 값으로 돌아간다.
  # 실행은 성공하므로 유실이 드러나지 않고, archive 가 **다른 FR** 을 done 처리한다
  # (final diff review Turn 016 Finding 1). 종전에는 이것을 판정할 두 번째 출처가
  # 없었다 — 이제 미러가 `## Source FR` 을 담으므로 대조할 수 있다.
  #
  # **어느 쪽이 최신인지는 여전히 모른다.** 그래서 고르지 않고 멈추고 두 값을 보여준다.
  # 해소 경로는 `rd task set-source-fr` 하나이고, 그것이 권위와 미러를 함께 쓴다.
  #
  # 미러에 섹션이 아예 없으면 D12 이전에 만들어진 미러다 — 판정하지 않고 통과시킨다
  # (Step D 가 씨앗을 심는다). 없는 것을 divergence 로 읽으면 이 결정 이전에 시작한
  # 모든 작업의 rerun 이 막힌다.
  # 판정은 위에서 **짝지어 읽은 두 텍스트**로 한다. 파일 경로를 다시 조립하면 출처가
  # 갈라지므로(9라운드 Finding 1) 여기서는 경로를 만들지 않는다.
  RERUN_SFR_AUTH="$(printf '%s\n' "${RERUN_STATE_TEXT}" \
    | awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,""); print; exit}')"
  if printf '%s\n' "${RERUN_MIRROR_TEXT}" | grep -qx -- '## Source FR'; then
    RERUN_SFR_MIRROR="$(printf '%s\n' "${RERUN_MIRROR_TEXT}" \
      | awk '$0=="## Source FR"{f=1; next} f && /^[^#]/{print; exit}')"
    if [[ "${RERUN_SFR_AUTH:--}" != "${RERUN_SFR_MIRROR:--}" ]]; then
      echo "promote: source-fr 가 권위와 미러에서 다릅니다 — 어느 쪽이 최신인지 판정할 수 없어 중단합니다 (상태 변경 없음)." >&2
      echo "  권위($RERUN_SRC_DESC): ${RERUN_SFR_AUTH:--}" >&2
      echo "  미러($RERUN_MIRROR_DESC): ${RERUN_SFR_MIRROR:--}" >&2
      echo "  권위 파일을 index 에서 되살린 직후라면 권위 쪽이 승격 시점 값입니다." >&2
      echo "  이 필드를 틀리면 archive 가 다른 FR 을 완료 처리합니다." >&2
      if [[ -n "$RERUN_WT_NOW" ]]; then
        echo "  현재 값을 확정해 양쪽을 함께 갱신한 뒤 재시도하세요:" >&2
        echo "    (cd $(printf '%q' "$RERUN_WT_NOW") && bash rd-workflow/scripts/rd task set-source-fr '<path|->')" >&2
      else
        # 등록된 작업 트리가 없으면 CLI 를 실행할 위치가 없다. 여기서 promote 가
        # worktree 를 만들면 "실패했는데 뭔가 만들었다" 가 되므로 만들지 않고 안내한다.
        #
        # **안내는 성공까지 이어져야 한다** (final diff review 재확인 세션 Finding 1).
        # 두 경우의 복구 순서가 다르다 — 갈래를 나누지 않으면 안내를 따라도 같은
        # divergence 에 다시 막힌다.
        _rc_br_q="$(printf '%q' "$TARGET_BRANCH")"
        echo "  대상 브랜치($TARGET_BRANCH)에 등록된 작업 트리가 없어 CLI 로 고칠 위치가 없습니다." >&2
        if [[ -n "$TARGET_WT_PATH" ]]; then
          # metadata 가 경로를 알고 있으므로 그 경로에 트리를 복원하면 다음 rerun 이
          # 그것을 대상으로 인식한다(worktree 탐색이 metadata 경로로 이뤄진다).
          # 따라서 커밋하지 않아도 되고, 트리는 남겨 두는 것이 정상 상태다.
          _rc_wt_q2="$(printf '%q' "$TARGET_WT_PATH")"
          echo "  metadata 의 경로에 트리를 복원한 뒤 그 안에서 갱신하고 재시도하세요:" >&2
          echo "    git worktree add $_rc_wt_q2 $_rc_br_q" >&2
          echo "    (cd $_rc_wt_q2 && bash rd-workflow/scripts/rd task set-source-fr '<path|->')" >&2
          echo "    # 이후 promote 재시도 — 다음 실행은 이 트리를 대상으로 읽습니다." >&2
        else
          # worktree-path=null 은 no-worktree 로 시작한 정상 상태다. 이 경우 다음 rerun 도
          # 대상 브랜치 **blob** 을 읽고(worktree 탐색을 하지 않는다) 기본 worktree 에서
          # 브랜치를 checkout 한다. 그래서 ① 정정은 **커밋**해야 보이고 ② 임시 트리를
          # 남기면 'already checked out' 으로 재시도가 실패한다. 둘 다 안내에 넣는다.
          echo "  이 작업은 worktree 없이 시작했으므로(worktree-path=null) 다음 재시도도" >&2
          echo "  대상 브랜치의 커밋된 내용을 읽습니다. 임시 트리에서 정정·커밋하고" >&2
          echo "  **그 트리를 제거한 뒤** 재시도하세요 — 남겨 두면 재시도가 checkout 충돌로 실패합니다:" >&2
          echo "    TMP_WT=\"\$(mktemp -d)/fix\"" >&2
          echo "    git worktree add \"\$TMP_WT\" $_rc_br_q" >&2
          echo "    (cd \"\$TMP_WT\" && bash rd-workflow/scripts/rd task set-source-fr '<path|->')" >&2
          echo "    (cd \"\$TMP_WT\" && git add CURRENT_TASK.md rd-workflow-workspace/.lifecycle/task-state \\" >&2
          echo "        && git commit -m 'fix: source-fr 정정')" >&2
          echo "    git worktree remove \"\$TMP_WT\"" >&2
          echo "    # 이후 promote 재시도" >&2
        fi
      fi
      exit 1
    fi
  fi
fi

if [[ -n "$TARGET_WT_PATH" ]]; then
  EXISTING_WT="$(git worktree list --porcelain | awk -v b="$TARGET_BRANCH" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0=="branch refs/heads/"b{print p; exit}')"
  if [[ -n "$EXISTING_WT" ]]; then
    if [[ "$EXISTING_WT" == "$TARGET_WT_PATH" ]]; then
      echo "promote: worktree 이미 존재 ($EXISTING_WT) — skip"
    else
      echo "promote: worktree 가 다른 path 에 있음 (existing=$EXISTING_WT, target=$TARGET_WT_PATH). metadata 갱신 필요" >&2; exit 1
    fi
  elif [[ -e "$TARGET_WT_PATH" ]]; then
    echo "promote: worktree path 이미 존재 (다른 용도)" >&2; exit 1
  else
    git worktree add "$TARGET_WT_PATH" "$TARGET_BRANCH"
  fi
elif [[ "$(git rev-parse --abbrev-ref HEAD)" != "$TARGET_BRANCH" ]]; then
  git switch "$TARGET_BRANCH"
fi

# Step D — CURRENT_TASK.md 갱신 commit (fr branch 위 = TARGET_WT_PATH 또는 기본 브랜치 worktree)
TARGET_DIR="${TARGET_WT_PATH:-.}"
TASK_FILE="$TARGET_DIR/CURRENT_TASK.md"
[[ -f "$TASK_FILE" ]] || { echo "promote: $TASK_FILE 없음" >&2; exit 1; }

# 이전 작업 잔여 초기화 — 미러의 Short Title 이 승격 대상과 다르면 baseline 으로 되돌린다.
#   같으면 건드리지 않는다: 중단 후 재개·재실행에서 그 사이 작성한 내용을 보존해야 한다.
#   baseline 값 '-' 과 빈 값은 "다름" 에 포함된다 — 이미 baseline 인 파일을 다시 baseline 으로
#   덮는 것은 결과가 같고, 분기를 늘리면 규칙만 복잡해진다.
#   대상은 $TASK_FILE 이므로 worktree 승격에서는 대상 worktree 의 미러만 초기화된다.
#
# **rerun 은 이 초기화를 건너뛴다** (final diff review 3라운드 Finding 1).
#   `IS_RERUN=1` 은 metadata 의 short-title 이 `$SLUG` 와 같다는 뜻이므로, 미러의 slug 가
#   다르다면 그것은 "이전 작업 잔여" 가 아니라 **같은 작업의 미러 drift** 다. 전체를
#   baseline 으로 덮으면 Request·Spec·Plan·Notes 등 진행 중 내용을 지운다. drift 는 Step D 가
#   세 필드만 보존 갱신해 복구한다.
#
# **이 블록이 권위 검증 뒤에 있는 것도 계약이다.** 앞에 두면 권위 status 가 없거나
# 비canonical 일 때 "상태 변경 없음" 이라고 실패하면서 미러는 이미 바꿔 놓는다.
#
# 아래 awk 는 verify_field 와 같은 패턴이다(그 함수는 이 지점보다 뒤에 정의되므로 인라인).
# 쓰기는 임시 파일 → mv 교체다. `> "$TASK_FILE"` 로 직접 쓰면 실패 시 미러가 빈 채 남는다.
PREV_SLUG="$(awk '$0=="## Short Title"{flag=1; next} flag && /^[^#]/{print; exit}' "$TASK_FILE")"
if [[ "$IS_RERUN" -eq 0 && "$PREV_SLUG" != "$SLUG" ]]; then
  _pt_tmp="${TASK_FILE}.baseline.tmp"
  if ! emit_current_task_baseline > "$_pt_tmp" 2>/dev/null; then
    rm -f "$_pt_tmp"
    echo "promote: CURRENT_TASK.md baseline 생성 실패 — 중단 (기존 미러 보존)" >&2; exit 1
  fi
  if ! mv "$_pt_tmp" "$TASK_FILE"; then
    rm -f "$_pt_tmp"
    echo "promote: CURRENT_TASK.md 교체 실패 — 중단 (기존 미러 보존)" >&2; exit 1
  fi
  echo "promote: 이전 작업($PREV_SLUG) 잔여를 baseline 으로 초기화"
elif [[ "$IS_RERUN" -eq 1 && "$PREV_SLUG" != "$SLUG" ]]; then
  echo "promote: rerun 이므로 미러 slug drift($PREV_SLUG → $SLUG)를 초기화 없이 복구합니다."
fi

if [[ -n "$TARGET_WT_PATH" ]]; then BW_VAL="$TARGET_BRANCH @ $TARGET_WT_PATH"; else BW_VAL="$TARGET_BRANCH"; fi

# 세 대상 섹션이 **모두 있는지 쓰기 전에** 확인한다 (final diff review 4라운드 Finding 2).
# 하나라도 없으면 awk 는 있는 것만 바꾸고 끝나므로, 뒤의 verify_field 가 실패할 때
# 이미 다른 필드는 바뀌어 있다 — 부분 갱신이다.
for _sec in "## Branch / Worktree" "## Status" "## Short Title"; do
  if ! grep -qx -- "$_sec" "$TASK_FILE"; then
    echo "promote: $TASK_FILE 에 '$_sec' 섹션이 없습니다 — 미러를 갱신할 수 없습니다 (상태 변경 없음)." >&2
    echo "  미러가 baseline 형식이 아닙니다. 확인: grep -n '^## ' '$TASK_FILE'" >&2
    exit 1
  fi
done

# C2 — 세 필드 갱신 검증. **임시 파일에서 먼저 검증하고 통과한 것만 원자 교체**한다.
# 종전에는 `cat "$TMP" > "$TASK_FILE"` 로 먼저 덮고 그 뒤에 검증했다 — 검증이 실패하면
# 이미 바뀐 파일이 남고, 출력 실패 시에는 원본이 truncate 된 채 남는다. 바로 위 baseline
# 블록이 임시 파일 → mv 로 보존 계약을 지키는데 여기서 그것을 깨고 있었다.
verify_field() {
  local file="$1" header="$2" expected="$3" desc="$4"
  local actual
  actual="$(awk -v h="$header" '
    $0==h{flag=1; next}
    flag && /^[^#]/{print; exit}
  ' "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "promote: CURRENT_TASK.md 갱신 검증 실패 — $desc (expected=[$expected] got=[$actual])" >&2
    return 1
  fi
}

TMP="${TASK_FILE}.promote.tmp"
trap 'rm -f "$TMP"' EXIT
if ! awk -v bw="$BW_VAL" -v st="$STATUS_VAL" -v slug="$SLUG" '
  BEGIN { sec="" }
  /^## Branch \/ Worktree/ { print; sec="bw"; next }
  /^## Status/             { print; sec="st"; next }
  /^## Short Title/        { print; sec="slug"; next }
  /^## /                   { sec=""; print; next }
  sec=="bw" && /^[^#]/      { print bw; sec=""; next }
  sec=="st" && /^[^#]/      { print st; sec=""; next }
  sec=="slug" && /^[^#]/    { print slug; sec=""; next }
  { print }
' "$TASK_FILE" > "$TMP"; then
  rm -f "$TMP"
  echo "promote: CURRENT_TASK.md 갱신본 생성 실패 — 중단 (기존 미러 보존)" >&2; exit 1
fi
verify_field "$TMP" "## Branch / Worktree" "$BW_VAL" "Branch / Worktree" || { rm -f "$TMP"; exit 1; }
verify_field "$TMP" "## Status" "$STATUS_VAL" "Status" || { rm -f "$TMP"; exit 1; }
verify_field "$TMP" "## Short Title" "$SLUG" "Short Title" || { rm -f "$TMP"; exit 1; }
if ! mv "$TMP" "$TASK_FILE"; then
  rm -f "$TMP"
  echo "promote: CURRENT_TASK.md 교체 실패 — 중단 (기존 미러 보존)" >&2; exit 1
fi

# `## Source FR` 미러 (change spec D12-3). 위 세 필드와 분리한 이유는 **마이그레이션**이다 —
# 이 섹션은 D12 에서 신설됐으므로 이 결정 이전에 만들어진 미러에는 없다. 위의 사전 검사에
# 넣으면 그런 미러의 rerun 이 전부 hard error 가 된다. 없으면 append 해서 씨앗을 심고,
# 있으면 세 필드와 같은 임시 파일 → 검증 → 원자 교체를 거친다.
if [[ "$IS_RERUN" -eq 1 ]]; then SFR_VAL="${RERUN_SFR_AUTH:--}"; else SFR_VAL="${SOURCE_FR_VAL:--}"; fi
if grep -qx -- '## Source FR' "$TASK_FILE"; then
  SFR_TMP="${TASK_FILE}.sfr.tmp"
  if ! awk -v v="$SFR_VAL" '
    $0=="## Source FR" { print; sec=1; next }
    /^## /             { sec=0; print; next }
    sec && /^[^#]/     { print v; sec=0; next }
    { print }
  ' "$TASK_FILE" > "$SFR_TMP"; then
    rm -f "$SFR_TMP"
    echo "promote: CURRENT_TASK.md Source FR 갱신본 생성 실패 — 중단 (기존 미러 보존)" >&2; exit 1
  fi
  verify_field "$SFR_TMP" "## Source FR" "$SFR_VAL" "Source FR" || { rm -f "$SFR_TMP"; exit 1; }
  if ! mv "$SFR_TMP" "$TASK_FILE"; then
    rm -f "$SFR_TMP"
    echo "promote: CURRENT_TASK.md Source FR 교체 실패 — 중단" >&2; exit 1
  fi
else
  if ! printf '\n## Source FR\n%s\n' "$SFR_VAL" >> "$TASK_FILE"; then
    echo "promote: CURRENT_TASK.md 에 '## Source FR' 섹션을 추가하지 못했습니다 — 중단" >&2; exit 1
  fi
  echo "promote: 미러에 '## Source FR' 섹션을 추가했습니다 (D12 이전 형식 마이그레이션)."
fi

# 판정·커밋 모두 CURRENT_TASK.md 로 한정한다 — 한정하지 않으면 사용자가 미리 stage 해 둔
# 무관한 변경이 이 커밋에 그대로 흡수되어, 앞선 metadata 커밋의 경로 한정 보호가 같은 실행
# 안에서 무의미해진다 (change spec 결정 5-1 · REQUEST AC6 의 index 보존).
# --no-verify 는 붙이지 않는다 — 이 커밋은 fr 브랜치에서 실행되어 hook 차단 대상이 아니고,
# 붙이면 소비 프로젝트의 검증만 줄어든다 (REQUEST AC2 가 비대상으로 확정).
( cd "$TARGET_DIR" && git add CURRENT_TASK.md && \
  if ! git diff --cached --quiet -- CURRENT_TASK.md; then
    git commit -m "chore(lifecycle): $SLUG fr 브랜치 승격 — CURRENT_TASK 갱신" -- CURRENT_TASK.md
  else
    echo "promote: CURRENT_TASK.md 변경 없음 — commit skip"
  fi
)

echo "promote: 완료. fr-branch=$TARGET_BRANCH"
