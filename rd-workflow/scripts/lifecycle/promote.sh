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
source "$SCRIPT_DIR/_tasks_index.sh"
source "$SCRIPT_DIR/session_launch.sh"

# ===========================================================================
# promote.sh — 재설계 (task-4-brief). 이제 이 스크립트는 **기본 브랜치에 어떤 커밋도
# 만들지 않는다.** 작업 상태는 그 작업의 fr 브랜치 위 task-state 에만 있고, "어떤
# 작업들이 있는가" 만 로컬 색인(_tasks_index.sh, untracked)에 둔다. 그래서 한
# 프로젝트에서 여러 FR 작업을 worktree 로 격리해 동시에 진행할 수 있다 — 두 번째
# 작업의 착수가 첫 번째의 기본 브랜치 커밋 때문에 막히지 않는다.
# ===========================================================================

DRY_RUN=0; SHORT_TITLE=""; WORKTREE_PATH=""; NO_WORKTREE=0; STATUS_VAL=""; SIZE_VAL=""; SOURCE_FR_ARGS=""; SOURCE_FR_ARG_FAIL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --short-title) SHORT_TITLE="$2"; shift 2 ;;
    --worktree-path) WORKTREE_PATH="$2"; shift 2 ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --status)
      [[ $# -ge 2 ]] || { echo "promote: --status 에 값이 없습니다 — canonical 상태 문자열을 지정하세요." >&2; exit 1; }
      STATUS_VAL="$2"; shift 2 ;;
    --size)
      [[ $# -ge 2 ]] || { echo "promote: --size 에 값이 없습니다 — large 또는 small 을 지정하세요." >&2; exit 1; }
      SIZE_VAL="$2"; shift 2 ;;
    --source-fr)
      [[ $# -ge 2 ]] || { echo "promote: --source-fr 에 값이 없습니다." >&2; exit 1; }
      source_fr_check_direct_arg "$2" "$project_root" || SOURCE_FR_ARG_FAIL=1
      SOURCE_FR_ARGS="${SOURCE_FR_ARGS:+${SOURCE_FR_ARGS}$'\n'}$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "usage: promote.sh --short-title <slug> (--size large|small | --status <canonical>) [--worktree-path <path>] [--no-worktree] [--source-fr <path|-> (반복 지정 가능)] [--dry-run]"; exit 0 ;;
    *) echo "promote: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- 시작 상태 결정 (change spec D1·D2, 불변) ---
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
  if ! _state_status_canonical "$STATUS_VAL"; then
    echo "promote: --status 값이 canonical 9종이 아닙니다: '$STATUS_VAL'" >&2
    echo "  허용: ${STATE_CANONICAL_STATUSES//|/, }" >&2
    exit 1
  fi
else
  echo "promote: 시작 상태를 지정하세요 — --size large (큰 작업) 또는 --size small (작은 작업)." >&2
  echo "  복구·마이그레이션 목적으로 특정 단계로 진입하려면 --status <canonical> 를 쓰세요." >&2
  exit 1
fi

# --source-fr 명시 인자 검증·해석 (사용자 명시 오류는 hard error). 부작용 없음.
SOURCE_FR_RESOLVED_LIST=""; SOURCE_FR_JOINED=""
if [[ "$SOURCE_FR_ARG_FAIL" -eq 1 ]]; then
  echo "promote: --source-fr 항목 검증에 실패해 아무것도 쓰지 않았습니다 (위 항목을 전부 고치세요)." >&2
  exit 1
fi
if [[ -n "$SOURCE_FR_ARGS" ]]; then
  _sfr_dash=0; _sfr_n=0
  while IFS= read -r _sv; do
    [[ -z "$_sv" ]] && continue
    _sfr_n=$((_sfr_n + 1)); [[ "$_sv" == "-" ]] && _sfr_dash=$((_sfr_dash + 1))
  done <<< "$SOURCE_FR_ARGS"
  if [[ "$_sfr_dash" -gt 0 && "$_sfr_n" -gt 1 ]]; then
    echo "promote: --source-fr 의 '-' (값 없음) 은 다른 항목과 함께 지정할 수 없습니다." >&2
    exit 1
  fi
  if ! SOURCE_FR_RESOLVED_LIST="$(source_fr_resolve_list "$SOURCE_FR_ARGS" "$project_root")"; then
    echo "promote: --source-fr 값 계약 위반 — 위 항목을 확인하세요 ('-' 또는 rd-workflow-workspace/backlog/items/<파일>.md 형식·실존 여부)." >&2
    exit 1
  fi
  if ! SOURCE_FR_JOINED="$(source_fr_join "$SOURCE_FR_RESOLVED_LIST")"; then
    echo "promote: --source-fr 목록을 저장 형식으로 합칠 수 없습니다 (2개 이상 지정 시 파일명에 '|' 를 포함할 수 없습니다)." >&2
    exit 1
  fi
fi

# I2 — --no-worktree + --worktree-path 충돌 검출
if [[ "$NO_WORKTREE" -eq 1 && -n "$WORKTREE_PATH" ]]; then
  echo "promote: --no-worktree와 --worktree-path는 함께 사용할 수 없습니다." >&2; exit 1
fi

# Short title 자동 추출 (trim-only — 내부 공백 보존). project_root 는 "그 작업의 자기
# 자신의 worktree" 일 수도 있다(재기동·복구 목적 재호출) — 그래서 여전히
# project_root/CURRENT_TASK.md 를 본다.
if [[ -z "$SHORT_TITLE" && -f "$project_root/CURRENT_TASK.md" ]]; then
  SHORT_TITLE="$(awk '/^## Short Title/{flag=1; next} flag && /^[^#]/{sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print; exit}' "$project_root/CURRENT_TASK.md")"
fi
[[ -z "$SHORT_TITLE" || "$SHORT_TITLE" == "-" ]] && { echo "promote: --short-title 필수" >&2; exit 1; }
SLUG="$(normalize_slug "$SHORT_TITLE")"
TARGET_BRANCH="fr/$SLUG"

# source-fr 값 결정: 인자 > REQUEST.md 해석 > '-'
resolve_source_fr() {
  if [[ -n "$SOURCE_FR_ARGS" ]]; then printf '%s\n' "$SOURCE_FR_JOINED"; return 0; fi
  if source_fr_request_missing "$project_root/REQUEST.md"; then
    echo "promote: REQUEST.md 가 없습니다 — ${project_root}/REQUEST.md" >&2
    echo "  정상 흐름에서는 이 파일이 항상 존재합니다(템플릿에 포함되고 archive 가 되돌립니다)." >&2
    echo "  다음 중 하나로 진행하세요:" >&2
    echo "    1) REQUEST.md 를 복원합니다 (템플릿: _ROOT_FILES/REQUEST.md)" >&2
    echo "    2) --source-fr rd-workflow-workspace/backlog/items/<파일>.md 를 지정합니다 (반복 지정 가능: --source-fr a.md --source-fr b.md)" >&2
    echo "    3) FR 없이 시작하는 작업이면 --source-fr - 를 지정합니다" >&2
    return 1
  fi
  local raw_list resolved_list
  raw_list="$(source_fr_from_request_list "$project_root/REQUEST.md")"
  if ! resolved_list="$(source_fr_resolve_list "$raw_list" "$project_root")"; then return 1; fi
  source_fr_join "$resolved_list"
}

# --worktree-path canonicalize (relative→absolute / parent missing hard error).
# 경로 결정·검증은 branch 생성보다 반드시 앞에 온다 — 잘못된 경로 하나로 잔여 브랜치를
# 남기지 않기 위함이다.
if [[ -n "$WORKTREE_PATH" ]]; then
  if [[ "$WORKTREE_PATH" != /* ]]; then
    PARENT="$(dirname "$WORKTREE_PATH")"
    [[ -d "$PARENT" ]] || { echo "promote: --worktree-path parent 미존재: $PARENT" >&2; exit 1; }
    WORKTREE_PATH="$(cd "$PARENT" && pwd)/$(basename "$WORKTREE_PATH")"
  else
    PARENT="$(dirname "$WORKTREE_PATH")"
    [[ -d "$PARENT" ]] || { echo "promote: --worktree-path parent 미존재: $PARENT" >&2; exit 1; }
  fi
  echo "promote: canonical worktree-path=$WORKTREE_PATH"
fi

cd "$project_root"

# 1. clean 검증 — project_root 자체의 클린 여부는 여기서 일괄 요구하지 않는다.
#    project_root 는 이 작업과 무관한 다른 worktree·디렉터리를 담을 수 있고(예: 다른
#    작업의 worktree 가 그 밑에 있다), 이 실행이 --no-worktree 로 project_root 자체를
#    switch 하는 경우는 git switch 자체가 dirty 를 거부한다. "워킹트리가 committed
#    와 다름(증명 불가)" 검사는 대상 fr worktree 에 한정해 D11 판정 a(아래)가 담당한다.
DEFAULT_BRANCH="$(get_default_branch)" || exit 1
REMOTE_MODE="$(detect_remote_mode 2>/dev/null)" || REMOTE_MODE="local-only"

# I4 — main worktree 는 "project_root" 가 아니라 "--git-common-dir 의 부모" 로 확정한다.
# project_root 는 이 실행이 **어느 worktree 안에서 불렸는지**일 뿐이라, project_root 를
# 그대로 기준 삼으면 작업 A 의 worktree 안에서 다른 작업 B 를 착수할 때 A 의 worktree
# 아래 중첩 worktree(`<A>/.worktrees/B`)가 생긴다 — A 를 archive 하면 B 까지 함께
# 사라진다. `--git-common-dir` 는 어느 worktree 에서 불러도 항상 같은 공유 .git 을
# 가리키므로, 그 부모가 유일한 "main worktree" 후보다.
MAIN_WT_PATH="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

# spec D6 — worktree 기본 경로는 `<repo-root>/.worktrees/<slug>` 이고, workflow.json 의
# `worktree_root` 로 override 할 수 있다. 파싱은 이 저장소의 기존 관례(get_default_branch·
# _tl_stale_threshold 와 같은 `sed` 한 줄 — python3 의존을 새로 들이지 않는다)를 그대로
# 쓴다. 기준 디렉터리는 project_root 가 아니라 MAIN_WT_PATH 다 — 어느 worktree 에서
# 불러도 항상 같은 저장소 설정을 읽어야 한다.
_WORKTREE_ROOT_CFG="${MAIN_WT_PATH}/rd-workflow/config/workflow.json"
_WORKTREE_ROOT_OVERRIDE=""
if [[ -f "$_WORKTREE_ROOT_CFG" ]]; then
  _WORKTREE_ROOT_OVERRIDE="$(sed -n 's/.*"worktree_root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_WORKTREE_ROOT_CFG" | head -1)"
fi
# `~` 확장 — "~/worktrees" 는 흔한 작성 형태인데, 확장하지 않으면 `/*` 패턴에 걸리지
# 않아 상대경로로 취급돼 저장소 안에 리터럴 `~` 디렉터리(`${MAIN_WT_PATH}/~/worktrees`)
# 가 조용히 생긴다(2026-09 final diff review ②) — 에러 없이 "성공" 해 발견이 늦어진다.
case "$_WORKTREE_ROOT_OVERRIDE" in
  "~") _WORKTREE_ROOT_OVERRIDE="$HOME" ;;
  "~/"*) _WORKTREE_ROOT_OVERRIDE="${HOME}/${_WORKTREE_ROOT_OVERRIDE#"~/"}" ;;
esac
if [[ -n "$_WORKTREE_ROOT_OVERRIDE" ]]; then
  if [[ "$_WORKTREE_ROOT_OVERRIDE" == /* ]]; then
    WORKTREE_ROOT_BASE="$_WORKTREE_ROOT_OVERRIDE"
  else
    WORKTREE_ROOT_BASE="${MAIN_WT_PATH}/${_WORKTREE_ROOT_OVERRIDE}"
  fi
else
  WORKTREE_ROOT_BASE="${MAIN_WT_PATH}/.worktrees"
fi

# --no-worktree 는 현재 체크아웃이 기본 브랜치일 때만 허용한다. 다른 작업의 worktree
# 안에서 --no-worktree 를 부르면 그 worktree 의 체크아웃이 통째로 다른 fr 브랜치로
# 넘어가 버린다 — 그 worktree 를 관리 진입점으로 쓰던 작업이 사라진다.
if [[ "$NO_WORKTREE" -eq 1 ]]; then
  _cur_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || _cur_branch=""
  if [[ "$_cur_branch" != "$DEFAULT_BRANCH" ]]; then
    echo "promote: --no-worktree 는 기본 브랜치(${DEFAULT_BRANCH}) 체크아웃에서만 허용합니다 (현재: ${_cur_branch:-detached})." >&2
    echo "  다른 작업의 worktree 안에서 --no-worktree 를 쓰면 그 worktree 의 체크아웃이 통째로 넘어갑니다." >&2
    exit 1
  fi
fi

# --no-worktree 는 동시에 하나만 허용한다 — 기본 체크아웃(공유 관리 진입점)을 그 작업이
# 통째로 가져가므로, 두 작업이 동시에 요구하면 어느 한쪽도 checkout 을 못 가진다.
if [[ "$NO_WORKTREE" -eq 1 ]]; then
  while IFS= read -r _nw_s; do
    [[ -z "$_nw_s" || "$_nw_s" == "$SLUG" ]] && continue
    _nw_v="$(tasks_index_get "$_nw_s" no-worktree 2>/dev/null)" || _nw_v=""
    if [[ "$_nw_v" == "yes" ]]; then
      echo "promote: 이미 --no-worktree 로 진행 중인 작업이 있습니다 (${_nw_s}) — 동시에 하나만 허용합니다." >&2
      exit 1
    fi
  done < <(tasks_index_slugs 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# 4. D11 판정표 — 현재 상태를 확정한다 (읽기 전용, 색인을 쓰지 않는다).
#
# 단순화된 결정 공간 (task-4-brief D11 표를 다음 8갈래로 접었다 — 결과는 표와
# 동치이고, 판정 순서(a → b/c 배타(b 먼저) → d~g)가 표의 우선순위를 그대로 지킨다):
#
#   fresh           ref 부재                                          → 판정 1
#   divergent       ref 존재 + worktree 살아있음 + 그 파일이 dirty      → 판정 2·3·4 서브 a
#   reinit          ref 존재 + worktree 죽음 + 물려받음(b)·초기화 이전(d) → 판정 2 (or 3 전이)
#   reinit_noattach ref 존재 + worktree 살아있음 + 물려받음(b)·초기화
#                   이전(d)                                            → 판정 3
#   published       ref 존재 + merge 로 들어옴(c, first-parent 밖)       → 판정 2·3·4 서브 c → D8
#   resume          ref 존재 + worktree 죽음 + committed short-title ==
#                   대상 (착수됐거나 진행됨 — 보존)                    → 판정 2/4 조합
#   duplicate       ref 존재 + worktree 살아있음 + committed short-title
#                   == 대상 (이미 다 살아있음)                        → 판정 6 "진행 중"
#   ambiguous       committed short-title 이 대상도 '-' 도 아님          → 판정 7
#
# **b(물려받음)는 identity 를 묻지 않는다** — first-parent 이력에 있다는 것은 그
# ref 의 tip 이 고유 커밋 없이 기본 브랜치 자체의 커밋이라는 뜻이므로, committed
# short-title 이 무엇이든(다른 구형 작업의 잔재일 수도 있다) 그 값을 읽지 않고
# 무조건 신규 초기화한다(2026-09 final diff review I1). 이 판정이 d~g 보다 먼저다.
# ---------------------------------------------------------------------------
FR_REF="refs/heads/${TARGET_BRANCH}"
REF_OID="$(git rev-parse --verify --quiet "$FR_REF" 2>/dev/null || true)"

DECISION=""
WT_ALIVE_PATH=""
DIVERGENT_KIND=""
PUBLISH_EVIDENCE=""

if [[ -z "$REF_OID" ]]; then
  DECISION=fresh
else
  # worktree 등록·생존 여부
  WT_ALIVE_PATH="$(git worktree list --porcelain | awk -v b="$TARGET_BRANCH" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0=="branch refs/heads/"b{print p; exit}')"
  [[ -n "$WT_ALIVE_PATH" && -d "$WT_ALIVE_PATH" ]] || WT_ALIVE_PATH=""

  # 판정 a — 워킹트리가 committed 와 다름(증명 불가). worktree 가 살아있을 때만 뜻이 있다.
  # 삭제(D)와 수정(M)을 구분해 둔다 — 삭제를 그대로 커밋하면 기록이 영구히 사라지므로
  # 복구 명령이 달라야 한다(2026-09 final diff review C4).
  if [[ -n "$WT_ALIVE_PATH" ]]; then
    _rel="rd-workflow-workspace/.lifecycle/task-state"
    _st="$(git -C "$WT_ALIVE_PATH" status --porcelain -- "$_rel" 2>/dev/null)"
    if [[ -n "$_st" ]]; then
      DECISION=divergent
      case "$_st" in
        'D '*|' D'*) DIVERGENT_KIND=deleted ;;
        *)           DIVERGENT_KIND=modified ;;
      esac
    fi
  fi

  if [[ -z "$DECISION" ]]; then
    # 판정 b — 물려받음: first-parent 이력에 있으면 identity 를 묻지 않고 신규 초기화.
    _inherited=0
    if git rev-list --first-parent "refs/heads/${DEFAULT_BRANCH}" 2>/dev/null | grep -qx "$REF_OID"; then
      _inherited=1
    fi
    if [[ "$_inherited" -eq 1 ]]; then
      if [[ -n "$WT_ALIVE_PATH" ]]; then DECISION=reinit_noattach; else DECISION=reinit; fi
    else
      # 판정 c — merge 로 들어옴(ancestor 이지만 first-parent 에는 없음). 발행 증거
      # 판정은 단일 출처(tasks_publish_evidence, _tasks_index.sh)를 쓴다 — 여기서
      # 다시 계산하지 않는다(2026-09 final diff review I2).
      PUBLISH_EVIDENCE="$(tasks_publish_evidence "$SLUG" "$REF_OID" "$DEFAULT_BRANCH" "$REMOTE_MODE")"
      if [[ "$PUBLISH_EVIDENCE" != "in-progress" ]]; then
        DECISION=published
      fi
    fi
  fi

  if [[ -z "$DECISION" ]]; then
    # 판정 d/e/f/g — committed short-title 을 읽는다. worktree 가 살아있으면 그 파일이
    # 권위(진행 중 갱신분이 blob 보다 최신일 수 있다), 죽었으면 fr tip blob 을 읽는다.
    _rel="rd-workflow-workspace/.lifecycle/task-state"
    if [[ -n "$WT_ALIVE_PATH" ]]; then
      _committed_short="$(awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,""); print; exit}' "$WT_ALIVE_PATH/$_rel" 2>/dev/null || true)"
    else
      _committed_short="$(git show "${TARGET_BRANCH}:${_rel}" 2>/dev/null \
        | awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,""); print; exit}' || true)"
    fi
    if [[ "$_committed_short" == "$SLUG" ]]; then
      if [[ -n "$WT_ALIVE_PATH" ]]; then DECISION=duplicate; else DECISION=resume; fi
    elif [[ -z "$_committed_short" || "$_committed_short" == "-" ]]; then
      if [[ -n "$WT_ALIVE_PATH" ]]; then DECISION=reinit_noattach; else DECISION=reinit; fi
    else
      DECISION=ambiguous
    fi
  fi
fi

# ---------------------------------------------------------------------------
# resume(e·f) 의 source-fr 권위 검증 — 구 promote 의 idempotent-rerun 방어를 복원한다
# (2026-09 final diff review C2, brief 「구현 규약」 201행: e·f·g 분기에도 브랜치 blob
# 권위·미러 검증을 적용한다). 읽기 전용이라 DRY_RUN·락보다 앞에서 해도 안전하다.
# ---------------------------------------------------------------------------
if [[ "$DECISION" == "resume" ]]; then
  _rel="rd-workflow-workspace/.lifecycle/task-state"
  _committed_sfr="$(git show "${TARGET_BRANCH}:${_rel}" 2>/dev/null \
    | awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,""); print; exit}' || true)"
  _committed_sfr_list="$(source_fr_split "${_committed_sfr:--}" "$project_root")"

  if [[ -n "$SOURCE_FR_ARGS" ]]; then
    if ! source_fr_mirror_set_equal "$SOURCE_FR_RESOLVED_LIST" "$_committed_sfr_list"; then
      echo "promote: '${SLUG}' 는 이미 초기화된 작업이라 --source-fr 로 값을 바꾸지 않습니다 (상태 변경 없음)." >&2
      echo "  committed=${_committed_sfr:--}, 인자=${SOURCE_FR_JOINED:--}" >&2
      echo "  정정하려면: 그 worktree 를 부착한 뒤 bash rd-workflow/scripts/rd task set-source-fr <path>..." >&2
      exit 1
    fi
  fi

  _mirror_blob="$(git show "${TARGET_BRANCH}:CURRENT_TASK.md" 2>/dev/null)" || _mirror_blob=""
  if printf '%s\n' "$_mirror_blob" | grep -qx -- '## Source FR'; then
    _mirror_tmp="$(mktemp)" || { echo "promote: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
    printf '%s\n' "$_mirror_blob" > "$_mirror_tmp"
    _mirror_sfr_list="$(source_fr_mirror_read "$_mirror_tmp")"
    rm -f "$_mirror_tmp"
    if ! source_fr_mirror_set_equal "$_committed_sfr_list" "$_mirror_sfr_list"; then
      echo "promote: '${SLUG}' 의 source-fr 가 권위(task-state)와 미러(CURRENT_TASK.md)에서 다릅니다 — 판정할 수 없어 중단합니다 (상태 변경 없음)." >&2
      echo "  확인: git show ${TARGET_BRANCH}:rd-workflow-workspace/.lifecycle/task-state" >&2
      echo "        git show ${TARGET_BRANCH}:CURRENT_TASK.md" >&2
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 비-변경 결정 — 메시지만 내고 종료. 아무 락도 필요 없다(읽기 전용이었다).
# ---------------------------------------------------------------------------
case "$DECISION" in
  divergent)
    if [[ "$DIVERGENT_KIND" == "deleted" ]]; then
      echo "promote: '${SLUG}' 의 작업 기록 파일이 삭제된 채 커밋되지 않았습니다 — 그대로 커밋하면 기록이 영구히 사라집니다 (상태 변경 없음)." >&2
      echo "  복구: (cd $(printf '%q' "$WT_ALIVE_PATH") && git checkout -- rd-workflow-workspace/.lifecycle/task-state) 후 재실행하십시오." >&2
    else
      echo "promote: '${SLUG}' 의 작업 기록이 커밋되지 않았습니다 — 그 worktree(${WT_ALIVE_PATH})에서 커밋한 뒤 재실행하십시오 (상태 변경 없음)." >&2
    fi
    exit 1
    ;;
  published)
    case "$PUBLISH_EVIDENCE" in
      needs-verify)
        echo "promote: '${SLUG}' 는 기본 브랜치(${DEFAULT_BRANCH})에 merge 되어 있지만 발행 확인이 끝나지 않았습니다 — 발행 확인 필요 (상태 변경 없음)." >&2
        echo "  확인: bash rd-workflow/scripts/rd task list" >&2
        ;;
      cleanup-pending)
        echo "promote: '${SLUG}' 는 이미 발행되었습니다 — 정리 대기 상태입니다 (worktree·branch 정리 대상, 재기동하지 않습니다)." >&2
        ;;
      *)
        echo "promote: '${SLUG}' 는 기본 브랜치에 merge 되어 있습니다 — 발행 확인 필요 (상태 변경 없음)." >&2
        ;;
    esac
    exit 1
    ;;
  duplicate)
    echo "promote: '${SLUG}' 는 이미 진행 중입니다 (fr-branch=${TARGET_BRANCH}) — 아무것도 바꾸지 않습니다." >&2
    echo "  다음 중 하나를 선택하세요:" >&2
    echo "    1) 그 작업을 계속 진행합니다: bash rd-workflow/scripts/rd task list" >&2
    echo "    2) 세션 기동을 다시 확인합니다: bash rd-workflow/scripts/rd task resolve-launch ${SLUG}" >&2
    echo "    3) 그 작업을 archive 한 뒤 다시 시작합니다." >&2
    exit 1
    ;;
  ambiguous)
    echo "promote: '${SLUG}' 의 소유권을 확인할 수 없습니다(fr 브랜치의 task-state 가 다른 작업을 가리킵니다) — 아무것도 바꾸지 않습니다." >&2
    echo "  확인: git show ${TARGET_BRANCH}:rd-workflow-workspace/.lifecycle/task-state" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# 여기부터는 mutating 결정(fresh · reinit · reinit_noattach · resume) 이다.
# ---------------------------------------------------------------------------
NEED_BRANCH=0; NEED_ATTACH=0; NEED_CONTENT=0
case "$DECISION" in
  fresh)           NEED_BRANCH=1; NEED_ATTACH=1; NEED_CONTENT=1 ;;
  reinit)          NEED_BRANCH=0; NEED_ATTACH=1; NEED_CONTENT=1 ;;
  reinit_noattach) NEED_BRANCH=0; NEED_ATTACH=0; NEED_CONTENT=1 ;;
  resume)          NEED_BRANCH=0; NEED_ATTACH=1; NEED_CONTENT=0 ;;
esac

# I3 — 색인에 이미 등록된 worktree-path 를 우선한다. 인자 없이 재실행했는데 등록이
# 사라진 것뿐이라면(worktree 유실) 그 경로에 그대로 재생성한다 — 기본 경로로
# 조용히 "이사" 시키지 않는다. 인자로 다른 경로를 명시했는데 등록된 경로와 다르면
# 어느 쪽이 맞는지 사람이 정하게 한다(덮어쓰지 않는다).
IDX_WT_PATH="$(tasks_index_get "$SLUG" worktree-path 2>/dev/null)" || IDX_WT_PATH=""
if [[ "$NO_WORKTREE" -eq 1 ]]; then
  TARGET_DIR="$project_root"
elif [[ "$NEED_ATTACH" -eq 0 && -n "$WT_ALIVE_PATH" ]]; then
  # D2 (2026-09 final diff review) — reinit_noattach(worktree 는 이미 살아 있고
  # 내용만 미초기화)에서는 부착을 하지 않으므로 --worktree-path 인자나 기본 경로
  # 추정이 끼어들 자리가 없다. 실제로 등록된 위치(WT_ALIVE_PATH, git worktree list
  # 로 이미 확인됨)가 유일하게 옳은 대상이다 — 이걸 쓰지 않으면 명시 경로로 만든
  # 작업의 9단계가 존재하지 않는 기본 경로에서 죽고, I6 트랩이 그 잘못된 경로를
  # "보존 대상" 이라며 재개를 안내해 재시도 루프가 된다.
  TARGET_DIR="$WT_ALIVE_PATH"
elif [[ -n "$WORKTREE_PATH" ]]; then
  TARGET_DIR="$WORKTREE_PATH"
  if [[ -n "$IDX_WT_PATH" && "$IDX_WT_PATH" != "$TARGET_DIR" && "$NEED_ATTACH" -eq 1 ]]; then
    echo "promote: 색인에 등록된 경로(${IDX_WT_PATH})와 인자로 준 경로(${TARGET_DIR})가 다릅니다 (상태 변경 없음)." >&2
    echo "  등록된 경로를 쓰려면 --worktree-path 를 생략하세요." >&2
    echo "  정말 옮기려면 먼저 등록된 경로를 정리하세요: git worktree remove ${IDX_WT_PATH}" >&2
    exit 1
  fi
elif [[ -n "$IDX_WT_PATH" && "$NEED_ATTACH" -eq 1 ]]; then
  TARGET_DIR="$IDX_WT_PATH"
else
  TARGET_DIR="${WORKTREE_ROOT_BASE}/${SLUG}"
fi

# source-fr 값 (content 를 쓸 때만 필요). **dry-run exit 보다 앞에 둔다** — 읽기 전용
# 판정이라 dry-run 에서 실행해도 아무것도 바꾸지 않는 반면, 뒤에 두면 REQUEST.md 의
# `## Source FR` 을 해석할 수 없는 상태에서 `--dry-run` 이 exit 0 으로 "된다" 고 보고하고
# 실제 실행만 exit 1 로 실패한다 — 사전 점검이 실제와 정반대 신호를 내는 것이라, 점검을
# 믿고 착수한 사람이 그때 가서야 막힌다. `--source-fr` 명시 인자 경로는 인자 파싱 단계에서
# 이미 검증되므로 이 회귀는 REQUEST 추론 경로에만 있었다.
SOURCE_FR_VAL="-"
if [[ "$NEED_CONTENT" -eq 1 ]]; then
  if ! SOURCE_FR_VAL="$(resolve_source_fr)"; then
    if ! source_fr_request_missing "$project_root/REQUEST.md"; then
      echo "promote: REQUEST.md 의 Source FR 을 해석할 수 없어 중단합니다 (상태 변경 없음)." >&2
      echo "  REQUEST.md 를 고친 뒤 같은 명령을 다시 실행하세요." >&2
    fi
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "would ${DECISION}: fr-branch=${TARGET_BRANCH} worktree=${TARGET_DIR} (branch=${NEED_BRANCH} attach=${NEED_ATTACH} content=${NEED_CONTENT})"
  exit 0
fi

# 2. 공유 색인 락 — 실패하면 무변경 종료. rc 1(정상 점유 중)과 rc 2(owner 불확실 —
#    회수해야 풀린다)는 기다림으로 풀리는지가 다르므로 안내를 구분한다(2026-09 final
#    diff review I8). `tasks_lock_acquire` 자체가 rc 2 일 때 회수 명령을 stderr 로
#    이미 냈으므로 여기서는 그것을 참고하라고만 안내한다.
if tasks_lock_acquire promote "$SLUG"; then
  :
else
  _lock_rc=$?
  if [[ "$_lock_rc" -eq 2 ]]; then
    echo "promote: 락 상태가 불확실합니다 — 위 stderr 안내(rm -rf 명령)를 확인해 다른 프로세스가 없음을 검증한 뒤 회수하고 재시도하십시오." >&2
  else
    echo "promote: 다른 작업이 색인을 쓰는 중입니다 — 잠시 후 다시 시도하세요." >&2
  fi
  exit 1
fi
LOCK_HELD=1
# I6 — 이 트랩은 두 가지를 한다: ① 어떤 경로로 끝나든 락을 반드시 푼다 ② 착수 도중
# (branch 생성 ~ content 커밋) 실패하면 "무엇이 보존됐고 다음에 뭘 하면 되는지" 를
# 낸다(AC 15 밴드 2 — brief 208행). `_STEP789_DONE` 이 비어 있는데 rc≠0 이면 이 구간
# 안에서 죽은 것이다.
_STEP789_DONE=""
_promote_on_exit() {
  local ec=$?
  if [[ "$ec" -ne 0 && -z "$_STEP789_DONE" ]]; then
    echo "promote: 착수 중 실패했습니다(rc=${ec}) — 이미 만든 branch·worktree 는 보존됩니다(지우지 않습니다)." >&2
    echo "  대상: fr-branch=${TARGET_BRANCH}, worktree=${TARGET_DIR}" >&2
    echo "  재개: 같은 명령을 다시 실행하십시오(다음 실행은 D11 판정 2·3 번으로 재개합니다)." >&2
  fi
  # **`[[ cond ]] && { ... }` 를 함수의 마지막 문장으로 두지 않는다.** cond 가 거짓이면
  # 이 짧은-회로 표현 전체의 종료 상태가 nonzero 가 되고, EXIT 트랩 함수의 마지막
  # 문장이 nonzero 로 끝나면 **원래 스크립트의 실제 종료 코드(ec, 이미 위에서 잡아
  # 둔 값)를 밀어내고 그 nonzero 로 덮어쓴다** — 실측: `echo 완료` 로 정상 종료(rc=0)
  # 했는데도 이 트랩 때문에 최종 rc 가 1 이 됐다. `if` 로 감싸고 마지막에 `return 0`
  # 을 명시해 트랩 자신의 종료 상태가 실제 rc 에 영향을 주지 않게 한다.
  if [[ "${LOCK_HELD:-0}" -eq 1 ]]; then
    tasks_lock_release
    LOCK_HELD=0
  fi
  return 0
}
trap '_promote_on_exit' EXIT

# I7 — 구형 단일 작업 흡수(spec D12)는 메인 락 안쪽, 판정 이후(= mutating 경로에서만)
# 실행한다. 판정 전에 실행하면 duplicate/published/ambiguous/divergent 로 끝나는
# "아무것도 바꾸지 않습니다" 호출에서도 색인이 이미 바뀔 수 있다(2026-09 final diff
# review I7). 이미 메인 락을 쥐고 있으므로 자체 락을 다시 잡지 않는다 — 흡수 실패는
# 삼키지 않고 stderr 로 알린다(단, 흡수 자체는 부가 기능이라 실패해도 착수를 막지
# 않는다).
# 흡수한 행의 `launch` 는 **`unknown`(확인 필요)** 입니다 — change spec 159행이 정한
# 원칙 「**기동 기록의 부재를 세션 부재로 해석하지 않는다**」의 한 사례입니다(review R5).
#
# 한때 이 값을 `none` 으로 바꾸려 했으나 **틀렸습니다.** 흡수의 발동 조건은 「기본
# worktree 의 task-state 가 `fr/*` 를 가리킴 + 그 slug 의 색인 행 없음」뿐이고, 이 조건은
# 두 가지 서로 다른 상황에서 참이 됩니다.
#   ① 색인·자동 기동이 생기기 전의 구형 배치 — 실제로 기동한 적이 없습니다.
#   ② **색인 파일 유실** — `--no-worktree` 로 착수한 작업은 기본 worktree 가 `fr/<slug>` 에
#      체크아웃돼 있고 그 task-state 가 `fr-branch=fr/<slug>` 이므로 앞 절반이 참이며,
#      `.git/rd-workflow/tasks.local` 이 사라지면 뒤 절반도 참이 됩니다. 그 작업은
#      `--no-worktree` 여도 `session_launch` 를 그대로 타므로(12 단계는 `NO_WORKTREE` 로
#      갈라지지 않습니다) **살아 있는 세션을 가질 수 있습니다.**
# 저장소 안에는 ①과 ②를 가를 증거가 없습니다(기동 사실은 herdr 쪽에만 있고, 그 유일한
# 조회 수단인 `session_probe` 는 herdr 밖에서 unknown 만 냅니다). 그래서 `none` 으로
# 단언하면 ②에서 **살아 있는 세션 위에 두 번째 세션을 띄웁니다** — 재착수 3경로에서
# `none` 은 「예약 후 기동 시도」이기 때문입니다(10 단계 ③).
#
# 틀렸을 때의 비용이 비대칭이므로 안전한 쪽으로 기웁니다: 확인 1회(`resolve-launch`,
# herdr 밖이면 `--assume-ended`) vs 살아 있는 작업 위 중복 기동.
_promote_absorb_legacy() {
  metadata_exists || return 0
  local legacy_branch legacy_slug have legacy_wt
  legacy_branch="$(metadata_read_field fr-branch)"
  case "$legacy_branch" in fr/*) ;; *) return 0 ;; esac
  legacy_slug="${legacy_branch#fr/}"
  git rev-parse --verify --quiet "refs/heads/${legacy_branch}" >/dev/null 2>&1 || return 0
  have="$(tasks_index_get "$legacy_slug" fr-branch 2>/dev/null)" || have=""
  [[ -n "$have" ]] && return 0
  legacy_wt="$(git worktree list --porcelain | awk -v b="$legacy_branch" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0=="branch refs/heads/"b{print p; exit}')"
  if [[ -n "$legacy_wt" ]]; then
    tasks_index_upsert "$legacy_slug" fr-branch="$legacy_branch" worktree-path="$legacy_wt" checkout=yes launch=unknown \
      || echo "promote: 구형 작업(${legacy_slug}) 색인 흡수 실패 — 착수는 계속합니다." >&2
  else
    tasks_index_upsert "$legacy_slug" fr-branch="$legacy_branch" launch=unknown \
      || echo "promote: 구형 작업(${legacy_slug}) 색인 흡수 실패 — 착수는 계속합니다." >&2
  fi
}
_promote_absorb_legacy

# 5. base-commit — 기본 브랜치 tip OID (branch 생성 시에만 실제로 쓰이지만, resolve 는
#    항상 해 둔다 — 새 브랜치의 시작점 판단에 쓰인다).
BASE_TIP="$(git rev-parse --verify "refs/heads/${DEFAULT_BRANCH}")" || {
  echo "promote: 기본 브랜치(${DEFAULT_BRANCH}) tip 을 확인할 수 없습니다." >&2
  exit 1
}

# 6. worktree 부모 디렉터리 준비. override 유무와 무관하게 없으면 만든다(2026-09
#    final diff review ①) — `mkdir -p` 는 비파괴적이라 `--worktree-path` 처럼 그
#    실행 1회에 한정된 명시 인자와 위험이 같지 않고, `worktree_root` 는 **이후 모든
#    착수의 기본값**이라 override 만 써도 매번 별도 mkdir 을 선행해야 하는 마찰이
#    생긴다(.gitignore 기본값 사용자에게는 없는 비대칭) — 이 프로젝트는 기술적
#    편의보다 최종 사용자의 편의를 우선한다. 오타 경로를 놓치지 않도록 새로 만들 때는
#    안내 한 줄을 낸다(순정 기본 경로는 항상 있던 동작이라 조용히 지나간다).
if [[ "$NO_WORKTREE" -ne 1 && "$TARGET_DIR" == "${WORKTREE_ROOT_BASE}/${SLUG}" && ! -d "$WORKTREE_ROOT_BASE" ]]; then
  mkdir -p "$WORKTREE_ROOT_BASE"
  [[ -n "$_WORKTREE_ROOT_OVERRIDE" ]] && echo "promote: worktree 기본 경로를 생성했습니다: ${WORKTREE_ROOT_BASE}" >&2
fi

# 7. branch 생성 (판정 1 에서만). 락을 기다리는 동안 다른 프로세스가 먼저 만들었을
#    수 있으므로(동시 착수 경합) 재확인한다 — raw git 오류로 죽는 대신 재시도 안내로
#    끝낸다(2026-09 final diff review 「동시 경합」 결정).
if [[ "$NEED_BRANCH" -eq 1 ]]; then
  if git rev-parse --verify --quiet "refs/heads/${TARGET_BRANCH}" >/dev/null 2>&1; then
    echo "promote: '${SLUG}' 는 락을 기다리는 동안 다른 프로세스가 이미 착수했습니다 — 다시 실행하십시오 (재판정)." >&2
    exit 1
  fi
  git branch "$TARGET_BRANCH" "$BASE_TIP"
  echo "promote: branch $TARGET_BRANCH 생성 (base=${BASE_TIP})"
fi

# 8. worktree 부착
if [[ "$NEED_ATTACH" -eq 1 ]]; then
  if [[ "$NO_WORKTREE" -eq 1 ]]; then
    git switch -q "$TARGET_BRANCH"
    echo "promote: 현재 체크아웃을 $TARGET_BRANCH 로 전환 (--no-worktree)"
  else
    git worktree add "$TARGET_DIR" "$TARGET_BRANCH"
    echo "promote: worktree $TARGET_DIR 생성 ($TARGET_BRANCH)"
  fi
fi

# 9. 그 worktree 안에서 task-state + CURRENT_TASK.md 작성 → 커밋 (판정 1·2·3 에서만.
#    resume 은 이미 committed 된 값을 그대로 보존한다 — 다시 쓰지 않는다.)
if [[ "$NEED_CONTENT" -eq 1 ]]; then
  TASK_FILE="${TARGET_DIR}/CURRENT_TASK.md"
  [[ -f "$TASK_FILE" ]] || { echo "promote: ${TASK_FILE} 없음 — 중단" >&2; exit 1; }

  # 이 worktree 는 방금 새로 만들었거나(fresh) 물려받은/미초기화 상태(reinit·
  # reinit_noattach) 이므로 항상 baseline 에서 다시 쓴다 — "이전 작업 잔여 보존" 을
  # 걱정할 필요가 없다(그런 경우는 이미 resume/duplicate 로 걸러졌다).
  emit_current_task_baseline > "$TASK_FILE"
  TMP="${TASK_FILE}.promote.tmp"
  if ! awk -v bw="$TARGET_BRANCH" -v st="$STATUS_VAL" -v slug="$SLUG" '
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
    echo "promote: CURRENT_TASK.md 갱신본 생성 실패 — 중단" >&2; exit 1
  fi
  mv "$TMP" "$TASK_FILE"

  SFR_LIST="$(source_fr_split "${SOURCE_FR_VAL:--}" "$TARGET_DIR")"
  SFR_BODY="$(source_fr_mirror_body "$SFR_LIST")"
  SFR_TMP="${TASK_FILE}.sfr.tmp"
  if ! SFR_BODY="$SFR_BODY" awk '
    BEGIN { n = split(ENVIRON["SFR_BODY"], arr, "\n") }
    $0=="## Source FR" { print; sec=1; done=0; next }
    /^## /             { if (sec && !done) { for (i=1;i<=n;i++) print arr[i]; done=1 } sec=0; print; next }
    sec                { next }
    { print }
    END { if (sec && !done) { for (i=1;i<=n;i++) print arr[i] } }
  ' "$TASK_FILE" > "$SFR_TMP"; then
    rm -f "$SFR_TMP"
    echo "promote: CURRENT_TASK.md Source FR 갱신본 생성 실패 — 중단" >&2; exit 1
  fi
  mv "$SFR_TMP" "$TASK_FILE"

  # task-state — TASK_STATE_PATH 를 이 worktree 로 잠시 돌려서 기존 helper 를 그대로 쓴다.
  _SAVED_TSP="$TASK_STATE_PATH"
  TASK_STATE_PATH="${TARGET_DIR}/rd-workflow-workspace/.lifecycle/task-state"
  state_write_fields \
    "short-title=${SLUG}" "status=${STATUS_VAL}" "fr-branch=${TARGET_BRANCH}" \
    "worktree-path=${TARGET_DIR}" "source-fr=${SOURCE_FR_VAL:--}" \
    "created-at=$(date +%Y-%m-%d-%H%M)"
  state_write_base_commit "$BASE_TIP" || {
    echo "promote: base-commit 을 기록하지 못했습니다 — diff review 의 base 자동 판정이 fr-branch 에만 의존합니다." >&2
  }
  TASK_STATE_PATH="$_SAVED_TSP"

  ( cd "$TARGET_DIR" \
    && git add CURRENT_TASK.md rd-workflow-workspace/.lifecycle/task-state \
    && if ! git diff --cached --quiet -- CURRENT_TASK.md rd-workflow-workspace/.lifecycle/task-state; then
         # pathspec 을 반드시 붙인다. `--no-worktree` 착수는 사용자의 기존 체크아웃과
         # **index 를 공유**하므로, 경로 한정이 없으면 사용자가 미리 staged 해 둔 무관한
         # 파일이 lifecycle 착수 커밋에 딸려 들어가고 그의 index 에서도 사라진다.
         git commit -q -m "chore(lifecycle): ${SLUG} 작업 착수 — task-state·CURRENT_TASK 기록" \
           -- CURRENT_TASK.md rd-workflow-workspace/.lifecycle/task-state
       fi )
fi

_STEP789_DONE=1

# 10. 색인에 행 추가 + 기동 판정 (AC 7 — 이미 진행 중일 수 있는 기존 launch 값을 먼저
#     본다. 그러지 않으면 worktree 등록만 잃은 살아 있는 세션 위에 새 세션이 덧붙는다
#     — 2026-09 final diff review C1):
#       ① launch=ok 이고 session_probe 가 alive → 재사용 안내만 하고 기동하지 않는다
#       ② launch 가 launching·unknown(확인 필요), 또는 launch=ok 인데 probe 가
#          unknown(조회 불가 — alive 도 dead 도 아님) → 확인 전에는 기동하지 않는다
#       ③ 그 밖(none·failed·빈 값, 또는 launch=ok 인데 probe=dead) → 예약 후 기동을 시도한다
#
# **probe 의 unknown 을 dead 로 취급하지 않는다** (2026-09 final diff review D3) —
# 그러면 색인의 launch=unknown 은 막으면서 probe 의 unknown 은 통과시키는 비일관이
# 되고, C1 이 막으려던 "살아 있는 세션 위에 두 번째 세션" 이 probe 경로로 재발한다.
_NW_FLAG=""
[[ "$NO_WORKTREE" -eq 1 ]] && _NW_FLAG="yes"

_EXISTING_LAUNCH="$(tasks_index_get "$SLUG" launch 2>/dev/null)" || _EXISTING_LAUNCH=""
_SKIP_LAUNCH_REASON=""
case "$_EXISTING_LAUNCH" in
  launching|unknown)
    _SKIP_LAUNCH_REASON="이전 기동 결과가 아직 확인되지 않았습니다(launch=${_EXISTING_LAUNCH})"
    ;;
  ok)
    _probe="$(session_probe "$SLUG" "$TARGET_DIR")"
    case "$_probe" in
      alive)   _SKIP_LAUNCH_REASON="이미 살아 있는 세션이 있습니다" ;;
      unknown) _SKIP_LAUNCH_REASON="세션 생존 여부를 확인할 수 없습니다(probe=unknown)" ;;
    esac
    ;;
esac

LAUNCH_TOKEN=""
if [[ -n "$_SKIP_LAUNCH_REASON" ]]; then
  echo "promote: ${_SKIP_LAUNCH_REASON} — 새로 기동하지 않습니다." >&2
  echo "  확인: bash rd-workflow/scripts/rd task resolve-launch ${SLUG}" >&2
  echo "promote: 기존 세션의 모델은 확인하지 않습니다 — 새 기동이 없습니다(${_SKIP_LAUNCH_REASON})."
  _SESSION_MODEL=""
  tasks_index_upsert "$SLUG" fr-branch="$TARGET_BRANCH" worktree-path="$TARGET_DIR" checkout=yes \
    ${_NW_FLAG:+no-worktree="$_NW_FLAG"}
else
  _SESSION_MODEL_SRC="" _SESSION_MODEL=""
  IFS=$'\t' read -r _SESSION_MODEL_SRC _SESSION_MODEL < <(session_launch_model "$TARGET_DIR")
  case "$_SESSION_MODEL_SRC" in
    env)     _SESSION_MODEL_LABEL="RD_SESSION_MODEL" ;;
    config)  _SESSION_MODEL_LABEL="model-strategy.json" ;;
    inherit) _SESSION_MODEL_LABEL="현재 세션 상속" ;;
    *)       _SESSION_MODEL_LABEL="미지정 — CLI 기본값" ;;
  esac
  echo "promote: 다음 기동에 사용할 모델 — ${_SESSION_MODEL:-미지정} (출처: ${_SESSION_MODEL_LABEL})"
  LAUNCH_TOKEN="$(date -u '+%Y-%m-%d-%H%M')-$$"
  tasks_index_upsert "$SLUG" fr-branch="$TARGET_BRANCH" worktree-path="$TARGET_DIR" checkout=yes \
    ${_NW_FLAG:+no-worktree="$_NW_FLAG"} launch=launching launch-token="$LAUNCH_TOKEN"
fi

# 11. 락 해제 — 세션 기동보다 앞선다(예약은 이미 기록됐다). 기동은 락 밖에서 돈다 —
#     기동 무응답이 다른 작업의 착수·마감을 막지 않게 한다.
[[ "${LOCK_HELD:-0}" -eq 1 ]] && { tasks_lock_release; LOCK_HELD=0; }

# 12. 세션 기동 (락 밖). **판정을 복제하지 않고 항상 session_launch 를 부른다** —
#     herdr 가 없거나 이미 자식 세션이면 그 함수 자신이 그것을 판단해 수동 기동
#     명령을 stderr 로 내고 none 을 반환한다. promote 가 그 판단을 앞에서 복제해
#     조건이 거짓일 때 아예 부르지 않으면, 이 템플릿을 쓰는 대다수(비-herdr 환경)가
#     수동 기동 명령을 못 본 채 worktree 만 남는다(2026-09 final diff review I5).
#     결과 기록은 락을 다시 잡아 **token 이 같을 때만** 반영한다.
if [[ -n "$LAUNCH_TOKEN" ]]; then
  REQUEST_HANDOFF_PATH="${TARGET_DIR}/REQUEST.md"
  LAUNCH_RESULT="$(session_launch "$TARGET_DIR" "$SLUG" "$REQUEST_HANDOFF_PATH" "$_SESSION_MODEL")"
  if tasks_lock_acquire promote "$SLUG"; then
    _cur_token="$(tasks_index_get "$SLUG" launch-token 2>/dev/null)" || _cur_token=""
    if [[ "$_cur_token" == "$LAUNCH_TOKEN" ]]; then
      tasks_index_upsert "$SLUG" launch="$LAUNCH_RESULT"
    fi
    tasks_lock_release
  else
    echo "promote: 기동 결과를 기록할 락을 얻지 못했습니다 — launching 상태로 남습니다." >&2
    echo "  확인: bash rd-workflow/scripts/rd task resolve-launch ${SLUG}" >&2
  fi
  echo "promote: 세션 기동 결과 — ${LAUNCH_RESULT} ($(session_launch_status_hint "$LAUNCH_RESULT" "$SLUG"))"
fi

echo "promote: 완료 (${DECISION}). fr-branch=${TARGET_BRANCH}, worktree=${TARGET_DIR}"
