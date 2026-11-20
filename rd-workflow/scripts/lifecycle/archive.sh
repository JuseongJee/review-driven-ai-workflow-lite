#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"
source "$SCRIPT_DIR/../_submodule_common.sh"
# 색인·락(Task 1) — launching 예약 확인·발행 기록(state=cleanup-pending)에 쓴다.
# 가볍고 project_root 를 요구하지 않아 항상 source 해 둔다(호출 시점에만 git 저장소면 된다).
source "$SCRIPT_DIR/_tasks_index.sh"
# 병합 충돌 사전 판정 공용 함수(발행 큐와 공유) — 자동 해소 대상 목록·충돌 판정·해소 안내.
source "$SCRIPT_DIR/_merge_precheck.sh"
# 팀 저장소 반영 설정·대상 판정 공용 함수(rd pr 과 공유) — archive 게이트(D10)가 쓴다.
source "$SCRIPT_DIR/_team_publish_common.sh"

# _archive_read_field_at <worktree-path> <key> — 다른 worktree 의 task-state 를
# **cd 없이 경로로 직접** 읽는다. `state_read_field` 는 source 시점에 확정된
# TASK_STATE_PATH 만 읽으므로 다른 worktree 를 대상으로 쓸 수 없다(brief 핵심 함정).
# metadata_read_field 와 같은 legacy active-fr fallback 을 유지한다.
_archive_read_field_at() {
  # bash 3.2 는 **같은 `local` 문 안에서 앞 변수를 참조**하지 못한다 — `local base="$1"
  # p="$base/..."` 는 4.x 에서는 되지만 3.2 에서는 `set -u` 아래 `base: unbound variable`
  # 로 즉사한다(이 머신이 3.2 다). 그래서 선언과 조립을 두 줄로 나눈다.
  local base="$1" key="$2"
  local p="$base/rd-workflow-workspace/.lifecycle/task-state"
  if [[ -f "$p" ]]; then
    awk -F'=' -v k="$key" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$p"
    return 0
  fi
  local legacy="$base/rd-workflow-workspace/.lifecycle/active-fr"
  if [[ -f "$legacy" ]]; then
    awk -F'=' -v k="$key" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$legacy"
  fi
}

# 파서보다 앞에서 원본 인자를 보존한다 — 파서가 shift 하므로 파싱 후에는
# --no-remote·--dry-run·--fr-branch 등이 사라진다. 기본 worktree 재실행(Step -1)이
# 이 배열을 그대로 전달한다.
ORIG_ARGS=("$@")

DRY_RUN=0; FORCE_DIRTY=0; NO_REMOTE=0; FR_BRANCH_OVERRIDE=""; FORCE_SKIP_REVIEW=0; SKIP_REASON=""; ALLOW_STATUS=0; STATUS_REASON=""; ALLOW_GITLINK=0; GITLINK_REASON=""; ALLOW_UNPUB=0; UNPUB_REASON=""; TASK_SLUG_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fr-branch) FR_BRANCH_OVERRIDE="$2"; shift 2 ;;
    --task) TASK_SLUG_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force-dirty) FORCE_DIRTY=1; shift ;;
    --no-remote) NO_REMOTE=1; shift ;;
    --force-skip-review-check)
      FORCE_SKIP_REVIEW=1
      # 다음 토큰이 없거나 -로 시작하면 사유 누락 → 빈 값 유지 (precheck에서 차단)
      if [[ $# -ge 2 && "$2" != -* ]]; then SKIP_REASON="$2"; shift 2; else shift 1; fi
      ;;
    --allow-status-mismatch)
      ALLOW_STATUS=1
      # --force-skip-review-check 와 같은 모양 — 사유 누락은 빈 값으로 두고 헬퍼가 차단한다.
      if [[ $# -ge 2 && "$2" != -* ]]; then STATUS_REASON="$2"; shift 2; else shift 1; fi
      ;;
    --allow-gitlink-drop)
      ALLOW_GITLINK=1
      # 같은 모양 — 사유 누락은 빈 값으로 두고 archive_gitlink_gate 가 차단한다.
      if [[ $# -ge 2 && "$2" != -* ]]; then GITLINK_REASON="$2"; shift 2; else shift 1; fi
      ;;
    --allow-unpublished-submodule)
      ALLOW_UNPUB=1
      # --allow-gitlink-drop 과 같은 모양 — 사유 누락은 빈 값으로 두고 archive_team_publish_gate 가 차단한다.
      if [[ $# -ge 2 && "$2" != -* ]]; then UNPUB_REASON="$2"; shift 2; else shift 1; fi
      ;;
    -h|--help) printf '%s\n' "usage: archive.sh [--fr-branch <ref>] [--task <slug>] [--no-remote] [--force-dirty] [--force-skip-review-check <사유>] [--allow-status-mismatch <사유>] [--allow-gitlink-drop <사유>] [--allow-unpublished-submodule <사유>] [--dry-run]"; exit 0 ;;
    *) printf 'archive: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Step -1 — 대상 확정과 기본 worktree 재실행 (spec D5)
#
# archive 의 core 산출물(merge·tag·push)은 항상 "기본 worktree"에서만 만들어진다.
# 작업 worktree 안에서 호출해도 그 사실은 바뀌지 않는다 — **cd 서브셸로는 해결되지
# 않는다.** `_state_common.sh` 가 `TASK_STATE_PATH` 를 source 시점에
# `${project_root:-$PWD}` 로 이미 확정했으므로, 이 프로세스 안에서 아무리 cd 해도
# 그 값은 바뀌지 않는다 — metadata_clear·state_write_fields 가 여전히 호출 worktree
# 의 상태를 지운다. 그래서 대상을 확정한 뒤 기본 worktree 로 이동해 **새 프로세스**로
# 자기 자신을 재실행한다.
#
# 기본 worktree 는 "기본 브랜치를 체크아웃한 worktree 를 찾는 방식"(구
# get_main_worktree_path)이 아니라 공유 .git 의 물리 위치(부모 디렉터리)로 확정한다.
# 전자는 `--no-worktree` 로 그 체크아웃이 fr 브랜치로 넘어가는 순간 실패한다 —
# promote.sh(Task 4)가 이미 같은 이유로 이 방식으로 갈아탔다(I4).
# `dirname "$(git ... 2>/dev/null)"` 로 한 줄에 합치면 안 된다 — `||` 가 **dirname 의
# rc** 만 보고, git 이 실패해 빈 문자열을 내도 `dirname ""` → "." 는 rc=0 이라 에러
# 분기가 실행되지 않는다(`--path-format` 은 git 2.31+ 이라 구버전에서 이 경로를 실제로
# 탄다). 그러면 PUBLISH_WT="." 가 되어 CALLER_WT 와 달라 mismatch 분기로 들어가고,
# `cd "."`(=호출자 worktree) 후 그 자리에서 재실행돼 **작업 worktree 안에서 발행**된다.
# 그래서 git 명령의 rc 와 출력값을 직접 검증한다. stderr 도 가리지 않는다
# (2>/dev/null 제거) — 실패 시 git 의 원래 진단이 그대로 보여야 원인을 알 수 있다.
_archive_git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)" || {
  printf 'archive: git-common-dir 조회 실패(git repo 외부이거나 --path-format 미지원 구버전 git) — 중단합니다.\n' >&2
  exit 1
}
case "$_archive_git_common_dir" in
  /*) ;;
  *)
    printf 'archive: git-common-dir 값이 절대경로가 아닙니다(%s) — git --version 확인 후 재실행하십시오.\n' "$_archive_git_common_dir" >&2
    exit 1
    ;;
esac
PUBLISH_WT="$(dirname "$_archive_git_common_dir")"
CALLER_WT="$(git rev-parse --show-toplevel)" || {
  printf 'archive: git repo 외부에서 실행 불가\n' >&2; exit 1
}

# 하위 디렉터리에서의 호출은 **명시적으로** 거부한다. `_state_common.sh` 가
# `TASK_STATE_PATH` 를 source 시점의 `$PWD` 로 굳히므로(FR archive-cwd-dependent-state-path),
# 여기서 그대로 진행하면 상태 파일이 하위 디렉터리 밑에 생긴다. 예전에는 metadata 를
# 읽지 못해 "active fr 없음" 으로 **우연히** 조기 종료했지만, 대상 판정이 git 대조로
# 정확해진 뒤로는 그 우연이 사라졌다 — 우연에 기대지 않고 막는다.
# (재실행 자식은 기본 worktree 루트에서 시작하므로 이 검사를 그대로 통과한다.)
_archive_cwd_real="$(pwd -P)"
_archive_caller_real="$(cd "$CALLER_WT" && pwd -P)"
if [[ "$_archive_cwd_real" != "$_archive_caller_real" ]]; then
  printf 'archive: 저장소 루트에서 실행하십시오 — 하위 디렉터리 호출은 상태 파일을 그 자리에 만듭니다 (현재: %s).\n' "$_archive_cwd_real" >&2
  printf '  실행: cd %q && bash rd-workflow/scripts/lifecycle/archive.sh\n' "$CALLER_WT" >&2
  exit 1
fi

# _archive_reexec_version_note <기본 worktree> <대상 브랜치> — 재실행이 읽을 기본 worktree 의
# rd-workflow/scripts 가 발행 대상 커밋의 같은 트리와 다르면 stderr 로 알린다(spec D1).
# 안내만 하며 항상 rc 0 이다 — 조회 실패(대상 ref 없음·git 오류)는 조용히 건너뛴다.
_archive_reexec_version_note() {
  local base="$1" branch="$2"
  local tgt="" head="" drc=0 commits="" files="" mb="" mrc=0
  tgt="$(git -C "$base" rev-parse --verify -q "refs/heads/$branch^{commit}" 2>/dev/null)" || return 0
  head="$(git -C "$base" rev-parse --verify -q HEAD 2>/dev/null)" || return 0
  git -C "$base" diff --quiet "$tgt" -- rd-workflow/scripts 2>/dev/null || drc=$?
  [[ "$drc" -eq 1 ]] || return 0
  commits="$(git -C "$base" log --format='%h %s' "$head..$tgt" -- rd-workflow/scripts 2>/dev/null)" || commits=""
  # 기본 브랜치에만 들어온 커밋(<대상>..<기본 HEAD>)은 merge 결과에도 들어가므로 세지 않는다 — 대상이 스크립트를
  # 바꾸지 않았으면 재실행 판과 merge 결과 판이 같다. 목록은 커밋으로 설명되지 않는 미커밋 차이만 담는다(AC1).
  files="$(git -C "$base" diff --name-only HEAD -- rd-workflow/scripts 2>/dev/null)" || files=""
  if [[ -z "$commits" && -z "$files" ]]; then
    # 대상이 스크립트를 바꿨는데 log 로 잡히지 않은 경우만 종전 대체 목록을 낸다.
    mb="$(git -C "$base" merge-base "$tgt" "$head" 2>/dev/null)" || return 0
    git -C "$base" diff --quiet "$mb" "$tgt" -- rd-workflow/scripts 2>/dev/null || mrc=$?
    [[ "$mrc" -eq 1 ]] || return 0
    files="$(git -C "$base" diff --name-only "$tgt" -- rd-workflow/scripts 2>/dev/null)" || files=""
  fi
  {
    printf 'archive: WARNING — 이번 발행은 기본 체크아웃의 rd-workflow/scripts 로 돕니다. 발행 대상의 스크립트와 다릅니다.\n'
    if [[ -n "$commits" ]]; then
      printf 'archive:   이번 발행에 쓰이지 않는 변경:\n'
      printf '%s\n' "$commits" | _archive_note_lines
    fi
    if [[ -n "$files" ]]; then
      printf 'archive:   기본 체크아웃에만 있는 차이 파일:\n'
      printf '%s\n' "$files" | _archive_note_lines
    fi
    printf 'archive:   새 단계가 할 일(예: Issue 닫기)이 있으면 발행 뒤 직접 처리하십시오. 다음 발행부터는 기본 브랜치에 들어간 판으로 돕니다.\n'
  } >&2
  return 0
}
# 표준입력 줄을 최대 10줄까지 들여써 내고, 넘으면 개수를 알린다.
_archive_note_lines() {
  local n=0 line=""
  while IFS= read -r line; do
    n=$((n + 1))
    [[ "$n" -le 10 ]] && printf 'archive:     %s\n' "$line"
  done
  [[ "$n" -le 10 ]] || printf 'archive:     … 외 %d개\n' "$((n - 10))"
  return 0
}

if [[ -z "${RD_ARCHIVE_REEXEC:-}" ]]; then
  # 대상 확정 — Task 3 의 task_resolve_target 을 쓴다(판정 로직 복제 금지). read 모드다:
  # 이 시점은 "누구를 발행할지" 만 정할 뿐 아직 아무것도 쓰지 않는다.
  project_root="$CALLER_WT"
  source "$SCRIPT_DIR/../_task_common.sh"

  _tr_out=""
  if ! _tr_out="$(task_resolve_target read "$TASK_SLUG_ARG")"; then
    exit 1
  fi
  _tr_kind="${_tr_out%%$'\t'*}"
  _tr_val="${_tr_out#*$'\t'}"

  if [[ -n "$TASK_SLUG_ARG" ]]; then
    # 명시 대상은 slug 자체가 곧 fr-branch 다 — 어느 worktree 의 파일도 읽지 않는다.
    # 읽기 권위는 fr tip 이고 쓰기 위치는 발행 worktree 다 — 호출 위치는 둘 중
    # 무엇도 아니므로 여기서 어떤 파일도 읽을 필요가 없다(spec D13).
    [[ -z "$FR_BRANCH_OVERRIDE" ]] && FR_BRANCH_OVERRIDE="fr/${TASK_SLUG_ARG}"
  elif [[ "$_tr_kind" == "ref" ]]; then
    [[ -z "$FR_BRANCH_OVERRIDE" ]] && FR_BRANCH_OVERRIDE="$_tr_val"
  elif [[ "$_tr_val" != "$CALLER_WT" ]]; then
    # 색인이 CALLER_WT 가 아닌 다른 작업을 단일 대상으로 자동 선택했다 — 그 worktree
    # 의 파일을 경로로 직접 읽는다(cd 로 옮겨가지 않는다 — 위 TASK_STATE_PATH 함정 회피).
    [[ -z "$FR_BRANCH_OVERRIDE" ]] && FR_BRANCH_OVERRIDE="$(_archive_read_field_at "$_tr_val" fr-branch)"
  fi
  # 그 외(대상이 CALLER_WT 자기 자신) — FR_BRANCH_OVERRIDE 를 강제하지 않는다. 아래
  # 기존 "FR identity source-of-truth" 블록이 CALLER_WT 에 바인딩된
  # metadata_read_field 로 그대로 읽는다(기존 단일 worktree 사용자와 동일 경로).

  if [[ "$CALLER_WT" != "$PUBLISH_WT" ]]; then
    # 자기 자신을 archive 하는 가장 흔한 경우(자기 worktree 안에서 호출, --task 없음)
    # 는 위에서 override 를 만들지 않았다 — cd 하기 전, 지금 CALLER_WT 에서 읽어 둔다.
    if [[ -z "$FR_BRANCH_OVERRIDE" ]]; then
      FR_BRANCH_OVERRIDE="$(metadata_read_field fr-branch)"
    fi
    # override 를 못 만들면 재실행하지 않는다. 그대로 넘기면 자식이 PUBLISH_WT 자신의
    # baseline task-state(fr-branch=null)를 읽어 no-fr 모드로 들어가고, 기본 worktree 는
    # 정의상 기본 브랜치 위에 있으므로 no-fr 의 안전 조건(§5.1)을 그냥 통과해
    # **호출자의 작업이 아니라 main 자체를 발행**한다(리뷰 지적 — 빈 값이 baseline 의
    # short-title=- 를 우연히 걸러내는 경우도 있었으나, fr-branch=null 이 그대로
    # 넘어가면 그 우연조차 없다).
    if [[ -z "$FR_BRANCH_OVERRIDE" ]]; then
      printf 'archive: 대상 작업을 확정할 수 없습니다 — --task <slug> 로 지정하십시오.\n' >&2
      exit 1
    fi
    # 호출자 override 가 자식으로 새지 않게 한다 — 새 프로세스가 PUBLISH_WT 기준으로
    # 다시 바인딩해야 한다.
    unset TASK_STATE_PATH STATE_MIGRATION_BACKUP_DIR

    # bash 3.2 + set -u 에서 빈 배열의 "${arr[@]}" 는 unbound variable 다. 인자 없이
    # 호출하는 것이 이 Task 의 대표 경로(작업 worktree 안에서 archive.sh 단독 호출)이므로
    # 가드 없는 전개는 실사용에서 바로 죽는다.
    _reexec_args=(${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"})
    if [[ -n "$FR_BRANCH_OVERRIDE" ]]; then
      _archive_has_fr_branch_opt=0
      for _archive_reexec_a in ${_reexec_args[@]+"${_reexec_args[@]}"}; do
        [[ "$_archive_reexec_a" == "--fr-branch" ]] && _archive_has_fr_branch_opt=1
      done
      [[ "$_archive_has_fr_branch_opt" -eq 0 ]] && _reexec_args+=(--fr-branch "$FR_BRANCH_OVERRIDE")
    fi

    # PUBLISH_WT 판정 자체가 틀렸을 가능성(구버전 git·예기치 못한 git-common-dir 형태)을
    # 재실행 직전에 한 번 더 막는다 — 대상 스크립트가 없으면 잘못된 위치에서 재실행을
    # 시도하는 대신 여기서 멈춘다.
    if [[ ! -f "$PUBLISH_WT/rd-workflow/scripts/lifecycle/archive.sh" ]]; then
      printf 'archive: 재실행 대상 스크립트를 찾을 수 없습니다: %s — 기본 worktree 판정이 잘못됐을 수 있습니다. 중단합니다.\n' \
        "$PUBLISH_WT/rd-workflow/scripts/lifecycle/archive.sh" >&2
      exit 1
    fi
    _archive_reexec_version_note "$PUBLISH_WT" "$FR_BRANCH_OVERRIDE"
    cd "$PUBLISH_WT" || exit 1   # ← 이것이 빠지면 위 TASK_STATE_PATH 문제가 그대로 남는다
    RD_ARCHIVE_REEXEC=1 RD_ARCHIVE_CALLER_WT="$CALLER_WT" project_root="$PUBLISH_WT" \
      bash "$PUBLISH_WT/rd-workflow/scripts/lifecycle/archive.sh" ${_reexec_args[@]+"${_reexec_args[@]}"}
    exit $?
  fi
fi

# 사전 검증 순서 (구현 시점 결정, 2026-09-05)
#
# FR identity 확정과 no-fr 실행 브랜치 검사를 Step 0 의 worktree 검사 **앞**에 둡니다.
# 뒤에 두면 `get_main_worktree_path` 가 항상 먼저 실패해, no-fr 사용자가 detached HEAD 에서
# `기본 브랜치 worktree 검출 실패` 라는 무관한 안내만 받고 무엇을 해야 하는지 알 수 없습니다
# (change spec §5.1 이 정한 두 메시지가 도달 불가였습니다 — T4 구현 보고에서 드러났습니다).
# 여기 있는 것은 전부 **읽기 전용 사전 검증**이라 발행 순서(one-shot 계약)와 무관합니다.

# FR identity source-of-truth
#
# 여기서 실행 모드를 확정합니다 (change spec §5.1·§3.2.2).
#   fr    — `fr/<slug>` 브랜치를 merge 해 발행하는 기존 경로
#   no-fr — fr 브랜치 없이 기본 브랜치에서 직접 작업한 경우의 발행 경로
#
# 판정은 `rd_branch_mode`(_state_common.sh) **한 곳**에서만 합니다. "비어 있으면 no-fr" 로
# 다루지 않는 것이 핵심입니다 — 필드가 유실된 파손 상태와 사용자가 명시한 no-fr 을
# 구분하지 못하면 파손된 task-state 가 조용히 no-fr 발행으로 흘러갑니다. canonical no-fr
# 표기는 `null` 하나뿐이고 빈 문자열·공백·`main` 등은 전부 malformed 로 막습니다.
FR_BRANCH="$FR_BRANCH_OVERRIDE"
if [[ -z "$FR_BRANCH" ]]; then
  FR_BRANCH="$(metadata_read_field fr-branch)"
fi
if [[ -z "$FR_BRANCH" ]]; then
  # 빈 값은 no-fr 이 아니라 "metadata 를 해석하지 못했다" 입니다 (파손·경로 오해석 포함).
  printf 'archive: active fr 없음. promote.sh 호출 후 archive 가능합니다.\n' >&2
  printf 'archive:   no-fr 모드는 task-state 의 fr-branch 가 canonical `null` 일 때만 진입합니다 — 빈 값은 파손으로 봅니다.\n' >&2
  exit 1
fi
BRANCH_MODE=""
BRANCH_MODE="$(rd_branch_mode "$FR_BRANCH")" || {
  # rd_branch_mode 가 허용 표기를 stderr 로 이미 안내했습니다.
  printf 'archive: fr-branch 값이 canonical 이 아니라 진행할 수 없습니다 — 중단합니다.\n' >&2
  exit 1
}

# no-fr 실행 브랜치 안전 조건 (change spec §5.1)
#
# no-fr 모드는 merge 대상 브랜치가 없어 metadata cleanup commit·tag·push 를 **현재 checkout**
# 에 그대로 수행합니다. 그래서 "어디에서 실행했는가" 가 곧 "무엇이 발행되는가" 입니다.
# 이 지점은 위 Step -1 재실행 덕분에 항상 기본 worktree 입니다 — fr 모드는 merge 대상을
# branch 이름(`$FR_BRANCH`)으로 참조하므로 어디에 체크아웃돼 있든 무관하지만, no-fr 은
# 브랜치가 아예 없어 "이 프로세스의 현재 checkout" 자체가 발행 대상입니다.
if [[ "$BRANCH_MODE" == "no-fr" ]]; then
  NOFR_DEFAULT_BRANCH="$(get_default_branch)" || {
    printf 'archive: 기본 브랜치 결정 실패 — no-fr 모드는 진행할 수 없습니다\n' >&2; exit 1
  }
  # detached HEAD 는 symbolic-ref 가 nonzero 이므로 여기서 갈립니다. 조용히 통과시키면
  # 발행 대상 브랜치가 없는 채로 tag·push 가 나갑니다.
  NOFR_CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || NOFR_CURRENT_BRANCH=""
  if [[ -z "$NOFR_CURRENT_BRANCH" ]]; then
    printf 'archive: detached HEAD 에서는 no-fr archive 를 할 수 없습니다 — 기본 브랜치로 전환 후 재실행하세요.\n' >&2
    exit 1
  fi
  if [[ "$NOFR_CURRENT_BRANCH" != "$NOFR_DEFAULT_BRANCH" ]]; then
    printf 'archive: no-fr 모드는 기본 브랜치(%s)에서만 호출 가능합니다 — 현재: %s. git switch %s 후 재실행하세요.\n' \
      "$NOFR_DEFAULT_BRANCH" "$NOFR_CURRENT_BRANCH" "$NOFR_DEFAULT_BRANCH" >&2
    exit 1
  fi
fi

# Step 0 — 기본 worktree 확정
# Step -1 이 이미 대상과 실행 위치를 확정했다 — 이 지점에 도달했다면 원래부터 기본
# worktree 에서 호출됐거나(재실행 불필요) 방금 재실행된 자식 프로세스다. 두 경우 모두
# 현재 위치는 PUBLISH_WT 와 같다.
CURRENT_WT="$PUBLISH_WT"

# Step 0 — 진행 중인 병합 (change spec 2026-11-18-0900 D1-4)
# clean 검사·팀 원격 조회보다 먼저 본다. 진행 중인 병합은 staged 변경을 남기므로 clean 검사가 먼저 돌면 이 안내가
# 가려진다. 손대지 않고 멈춰 그 병합 상태를 보존한다 — 그래서 Step 3 병합 실패 뒤의 MERGE_HEAD 는 이 실행이 만든 것이다.
if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  printf 'archive: 진행 중인 병합이 있습니다 — git merge --abort 또는 손으로 마친 뒤 다시 실행하십시오\n' >&2
  exit 1
fi

# Step 0 — clean state (unless --force-dirty)
if [[ "$FORCE_DIRTY" -eq 0 ]]; then
  ensure_worktree_clean || { printf 'archive: worktree dirty — git status 확인 후 commit/stash 후 재실행\n' >&2; exit 1; }
elif ! ensure_worktree_clean; then
  printf 'archive: WARNING — dirty state 로 진행 (--force-dirty 는 이 clean 검사만 넘깁니다)\n' >&2
fi

# Override mismatch guard — override 가 active metadata 와 다르면 unrelated FR 정리/metadata 손상을 막기 위해 중단.
if [[ -n "$FR_BRANCH_OVERRIDE" ]] && metadata_exists; then
  ACTIVE_FR="$(metadata_read_field fr-branch)"
  if [[ -n "$ACTIVE_FR" && "$ACTIVE_FR" != "$FR_BRANCH_OVERRIDE" ]]; then
    printf 'archive: --fr-branch %s 가 active metadata (%s) 와 불일치 — 중단합니다.\n' "$FR_BRANCH_OVERRIDE" "$ACTIVE_FR" >&2
    printf '  active FR 을 archive 하려면: 인자 없이 archive.sh 호출\n' >&2
    printf '  active FR 을 다른 ref 로 전환하려면: promote_rollback.sh 후 promote.sh 재호출\n' >&2
    exit 1
  fi
fi

# SLUG — tag 이름(`fr/<날짜>/<slug>`)의 재료. tag 형식은 두 모드가 같습니다 (§5.1).
#   fr    : 브랜치 이름이 곧 slug 입니다.
#   no-fr : 브랜치가 없으므로 task-state `short-title` 을 정규화해 씁니다. baseline(`-`)이나
#           비어 있는 short-title 은 normalize_slug 가 거부하므로 fail-closed 입니다 —
#           이름을 임의로 지어내면 tag 가 어떤 작업의 것인지 추적할 수 없어집니다.
if [[ "$BRANCH_MODE" == "no-fr" ]]; then
  SLUG="$(normalize_slug "$(metadata_read_field short-title)")" || {
    printf 'archive: no-fr 모드의 tag slug 를 task-state short-title 에서 만들 수 없습니다 — 중단합니다.\n' >&2
    printf 'archive:   먼저 실행: bash rd-workflow/scripts/rd task set-title <제목>\n' >&2
    exit 1
  }
else
  SLUG="${FR_BRANCH#fr/}"
fi

# ---------------------------------------------------------------------------
# 공유 락 — 여기서 **한 번** 잡고 스크립트가 끝날 때까지 쥔다.
#
# 예전에는 기동 상태 조회·색인 기록·행 삭제 세 군데에서 짧게 잡고 바로 놓았다. 그래서
# Step 3 merge → Step 4 metadata cleanup → Step 6 publish 가 전부 락 밖이었고, 두
# archive 가 각자 짧은 검사를 통과한 뒤 같은 기본 worktree 의 HEAD·index·상태 파일을
# 동시에 바꿀 수 있었다. git 의 `index.lock` 은 한 명령 안에서만 유효해 **여러 명령에
# 걸친** merge·정리·commit 을 직렬화하지 못한다. AC 13(promote·archive·rollback 배타)·
# AC 14(점유 실패 호출은 자기 변경 없이 끝나고 점유자·사유·재시도 방법을 낸다).
#
# 위치의 근거:
#   - **재실행 이후**여야 한다. 락 owner 파일에는 `$$` 가 적히고 `tasks_lock_release` 는
#     `$$` 가 일치할 때만 지운다. archive 는 Step -1 에서 기본 worktree 로 **자식 bash
#     프로세스를 재실행**하므로(`RD_ARCHIVE_REEXEC=1`), 부모가 잡은 락은 자식이 풀지
#     못한다. 이 지점은 재실행이 끝난 뒤(또는 애초에 재실행이 불필요했던 프로세스)다.
#   - **SLUG 확정 직후**여야 한다. 점유자 정보에 대상 slug 를 실어야 하고, 아직 아무것도
#     바꾸지 않은 지점이어야 점유 실패가 곧 "자기 변경 없음" 이 된다.
#
# `tasks_lock_acquire` 는 **재진입하지 않는다** — 아래 기동 상태 조회·색인 기록·행 삭제는
# 더 이상 각자 잡지 않는다(다시 잡으면 자기 자신과 교착한다).
#
# `--dry-run` 은 아무것도 바꾸지 않으므로 이 락을 요구하지 않는다. 진단 명령이 점유 때문에
# 막히면 사용자가 진단 자체를 못 하기 때문이다(기존 dry-run 우회 주석과 같은 취지).
# 읽기 경로(`tasks_index_get` 등)는 원래 락을 잡지 않으므로 조회에는 영향이 없다.
ARCHIVE_LOCK_HELD=0
_archive_on_exit() {
  if [[ "${ARCHIVE_LOCK_HELD:-0}" -eq 1 ]]; then
    tasks_lock_release || true
    ARCHIVE_LOCK_HELD=0
  fi
  return 0
}
trap '_archive_on_exit' EXIT

if [[ "$DRY_RUN" -eq 0 ]]; then
  if tasks_lock_acquire_wait archive "$SLUG" tasks-list-prune; then
    ARCHIVE_LOCK_HELD=1
  else
    _archive_lock_rc=$?
    # 점유자(cmd·slug·started-at)는 `tasks_lock_acquire` 가 이미 stderr 로 냈다.
    if [[ "$_archive_lock_rc" -eq 2 ]]; then
      printf 'archive: 락 상태가 불확실합니다 — 위 stderr 안내(rm -rf 명령)로 다른 프로세스가 없음을 검증한 뒤 회수하고 재시도하십시오 (상태 변경 없음).\n' >&2
    else
      printf 'archive: 다른 lifecycle 명령이 실행 중입니다 — 위 점유자 정보를 확인하고 끝난 뒤 재시도하십시오 (상태 변경 없음).\n' >&2
      printf 'archive:   재시도: 같은 명령을 그대로 다시 실행하십시오. 취소하려면 아무것도 하지 않아도 됩니다(이 호출은 아무 변경도 남기지 않았습니다).\n' >&2
    fi
    exit 1
  fi
fi

# launching(또는 unknown) 예약 중인 작업은 발행하지 않는다 (spec D7·plan 1076행).
#   promote.sh 는 worktree·브랜치·색인 등록을 마친 뒤 launch=launching + launch-token 을
#   기록하고 **락을 풀고 나서** 세션을 기동한다 — 그 구간은 락이 잡혀 있지 않아 다른
#   명령이 자유롭게 들어온다. 그 창에서 archive 가 merge·tag·push·worktree 정리까지
#   마치면, 방금 기동한 세션이 이미 정리된 worktree 를 넘겨받는다(promote_rollback.sh
#   에서 같은 구멍이 실제 Critical 로 확인됐다 — archive 는 발행까지 하므로 더 위험).
#   판정은 **락 안에서** 한다(promote.sh 610행 부근과 같은 패턴) — 대상 확정 직후,
#   merge 등 실제 발행 동작보다 앞이어야 TOCTOU 창이 좁아진다.
#   `unknown` 은 legacy 이관 행·probe 조회 불가 상태를 나타내는 **실제 저장값**이다
#   (promote.sh 471·474·605행) — `none`(기동 시도 없음)과 다르다. `none`·`ok`·`failed`·
#   빈 값(색인에 행이 없는 legacy 단일 worktree 사용)은 발행을 막지 않는다.
# dry-run 은 이 가드를 우회한다(경고만 내고 통과) — 가드의 목적은 "무변경 중단" 인데
# dry-run 은 애초에 아무것도 바꾸지 않는다. 오히려 tasks_list.sh 가 「⚠ 발행 확인 필요」
# 진단 명령으로 안내하는 바로 그 `archive.sh --dry-run` 이 이 가드에 막히면
# 사용자가 진단 자체를 할 수 없게 된다.
# 락은 이미 위에서 잡았다(dry-run 은 잡지 않는다 — 읽기는 원래 락이 필요 없다).
if [[ "$BRANCH_MODE" == "fr" ]]; then
  _archive_launch_state="$(tasks_index_get "$SLUG" launch 2>/dev/null)" || _archive_launch_state=""
  case "$_archive_launch_state" in
    launching|unknown)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'archive: WARNING — %s 작업이 기동 확인 대기 상태입니다(launch=%s) — dry-run 이라 계속 진행합니다. 실제 발행은 이 상태에서 거부됩니다.\n' "$SLUG" "$_archive_launch_state" >&2
        printf 'archive:   확인: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$SLUG" >&2
      else
        printf 'archive: %s 작업이 기동 확인 대기 상태입니다(launch=%s) — 발행하지 않습니다.\n' "$SLUG" "$_archive_launch_state" >&2
        printf 'archive:   확인: bash rd-workflow/scripts/rd task resolve-launch %s\n' "$SLUG" >&2
        printf 'archive:   세션을 조회할 수 없는 환경이면: bash rd-workflow/scripts/rd task resolve-launch %s --assume-ended\n' "$SLUG" >&2
        exit 1
      fi
      ;;
  esac
fi

# REMOTE_MODE_RAW — --no-remote 로 덮기 **전** 의 실제 원격 유무. tasks_list.sh 는
# --no-remote 라는 archive.sh 전용 플래그를 모르고 항상 detect_remote_mode() 로만
# 판정하므로(:40), 발행 기록(D8)의 tasks_publish_evidence 재확인도 같은 값을 써야 두
# 판정이 일치한다. REMOTE_MODE(override 반영)는 실제 push/원격 ref 삭제 등 이 스크립트
# 자신의 동작 분기에 계속 쓴다 — 그 부분은 --no-remote 의도대로 로컬만 처리해야 한다.
REMOTE_MODE_RAW="$(detect_remote_mode)"
REMOTE_MODE="$REMOTE_MODE_RAW"
[[ "$NO_REMOTE" -eq 1 ]] && REMOTE_MODE="local-only"

# 직접 설치 PR 발행(archive_publish=pr) 사전 거부 — 어떤 커밋·태그·push 보다 먼저, dry-run 도 같은 검사를 거친다 (change spec D2).
# 락은 위에서 이미 잡았지만 저장소를 바꾸지 않는다. 판정은 fr tip(no-fr 은 HEAD)에 커밋된 workflow.json 으로 한다.
# fr 브랜치가 이미 없으면(발행 끝난 재실행) 설정을 읽을 곳이 없으므로 push 로 두고 아래 「이미 archive 완료」 안전망이 처리한다.
source "$SCRIPT_DIR/_direct_pr_common.sh"
_ARCHIVE_DPR_MODE="push"
_dpr_commit="HEAD"
if [[ "$BRANCH_MODE" == "fr" ]]; then
  git rev-parse --verify -q "refs/heads/${FR_BRANCH}^{commit}" >/dev/null 2>&1 && _dpr_commit="$FR_BRANCH" || _dpr_commit=""
fi
if [[ -n "$_dpr_commit" ]]; then
  _dpr_rc=0
  _ARCHIVE_DPR_MODE="$(dpr_archive_mode "$CURRENT_WT" "$_dpr_commit")" || _dpr_rc=$?
  [[ "$_dpr_rc" -eq 0 ]] || { printf 'archive: archive_publish 설정을 판정할 수 없어 발행하지 않습니다 (상태 변경 없음).\n' >&2; exit 1; }
fi
if [[ "$_ARCHIVE_DPR_MODE" == "pr" ]]; then
  dpr_preflight "$BRANCH_MODE" "$REMOTE_MODE" || exit 1
  dpr_rerun_hint "$SLUG" "$FR_BRANCH" || exit 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'would open PR: branch=%s base=%s\n' "$FR_BRANCH" "$(get_default_branch)"; exit 0
  fi
fi

# remote tag preflight (hard-stop on fetch failure)
if [[ "$REMOTE_MODE" == "remote" ]]; then
  git fetch --tags origin >/dev/null 2>&1 || {
    printf 'archive: git fetch --tags origin 실패 — preflight 중단. 네트워크/권한 확인 후 재실행 또는 --no-remote 사용.\n' >&2
    exit 1
  }
fi

# Rerun 안전망 — fr branch 부재 + 동일 slug tag 존재 = 이미 archive 완료
#
# 이 판정의 축은 "fr 브랜치가 사라졌는가" 이므로 fr 모드 전용입니다. no-fr 모드에는 브랜치가
# 애초에 없어 조건이 항상 참이 되고, 같은 slug 로 두 번째 작업을 하면 첫 tag 만 보고
# "이미 완료" 로 조기 종료합니다. no-fr 의 재실행 멱등성은 Step 5 의 `--points-at $PUBLISH_OID`
# tag 재사용이 담당합니다 (같은 커밋이면 tag 를 새로 만들지 않습니다).
if [[ "$BRANCH_MODE" == "fr" ]]; then
  if ! git rev-parse --verify "$FR_BRANCH" >/dev/null 2>&1; then
    EXISTING_TAG="$(git tag --list "fr/*/$SLUG" 2>/dev/null | head -1)"
    if [[ -n "$EXISTING_TAG" ]]; then
      printf 'archive: 이미 archive 완료 — nothing to do (tag=%s)\n' "$EXISTING_TAG"
      exit 0
    fi
    printf 'archive: branch %s 미존재\n' "$FR_BRANCH" >&2; exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$BRANCH_MODE" == "no-fr" ]]; then
    printf 'would archive: no-fr 모드, 브랜치=%s slug=%s (tag는 cleanup commit 부착 후 결정)\n' \
      "$NOFR_CURRENT_BRANCH" "$SLUG"; exit 0
  fi
  printf 'would archive: branch=%s (tag는 cleanup commit 부착 후 결정)\n' "$FR_BRANCH"; exit 0
fi

# review 종결성 자체 검증 (dry-run exit 이후 = 실제 archive 경로에만 실행, dry-run 비파괴성 보존).
# 판정/audit/사유검증은 헬퍼에 위임.
project_root="$CURRENT_WT"
source "$SCRIPT_DIR/../hooks/_guard_common.sh"
AUDIT_LOG="$CURRENT_WT/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
# archive_team_publish_gate <tip> — 팀 저장소에 반영되지 않은 submodule 포인터의 발행을 막는다 (change spec D10, 2026-11-18-0900 D2-2·D3-2).
#   두 모드 공통이다. tip 은 fr 모드는 fr 브랜치, no-fr 모드는 정리 커밋 전 HEAD OID 이고, submodule 판정 위치는 fr 모드는
#   fr 브랜치를 체크아웃한 worktree, no-fr 모드는 호출 worktree(CURRENT_WT, 기본 체크아웃)다.
#   판정 순서: (가) tip 의 gitlink 중 반영 방식이 manual 이 아닌 것이 없으면 기준점 없이 통과 → (나) 기준점 tp_target_base
#   (리뷰한 범위) → (다) 기준점부터 tip 까지 바뀐 gitlink(seal 마커로 기준점을 정했으면 리뷰한 끝 커밋까지 바뀐 경로만,
#   tp_reviewed_head) 마다 tip 의 포인터가 submodule 의 origin/<대상 브랜치> 의 조상이거나 같아야 한다.
#   대상 브랜치는 team_publish.base, 비면 submodule 의 origin/HEAD 가 가리키는 브랜치다. gh 는 쓰지 않는다.
#   팀 원격 조회(set-head·fetch)는 시작 줄을 먼저 내고 RD_MERGE_FETCH_TIMEOUT 상한을 둔다(rd_run_limited).
#   (나)의 실패와 (다)의 반영되지 않은 포인터·판정 불가는 같은 우회 처리를 거친다: --allow-unpublished-submodule <사유>
#   (audit 기록, 기록 실패는 차단). 플래그가 없으면 거부한다(fail-closed).
#   return 0=진행, 1=차단.
# _archive_fr_worktree <fr-branch> — 그 브랜치를 체크아웃한 worktree 경로(없으면 rc 1).
_archive_fr_worktree() {
  local want="refs/heads/$1" line wt=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt="${line#worktree }" ;;
      "branch $want") [[ -n "$wt" ]] && { printf '%s\n' "$wt"; return 0; } ;;
      "") wt="" ;;
    esac
  done < <(git -C "$CURRENT_WT" worktree list --porcelain 2>/dev/null)
  return 1
}

# _archive_tpg_bypass — 팀 저장소 반영 게이트의 우회 처리 하나((나) 기준점 실패와 (다) 반영되지 않은 포인터가 함께 쓴다).
#   rc 0 우회(사유 검사 → audit `[team-publish] <사유>` → WARNING) / 1 차단(사유 누락·audit 실패, 안내 출력) /
#   2 우회 플래그 없음(호출부가 거부 안내를 낸다).
_archive_tpg_bypass() {
  local audit_dir
  [[ "$ALLOW_UNPUB" -eq 1 ]] || return 2
  if [[ -z "$UNPUB_REASON" ]]; then
    printf 'archive: --allow-unpublished-submodule 사유 필수\n' >&2
    return 1
  fi
  audit_dir="$(dirname "$AUDIT_LOG")"
  if ! mkdir -p "$audit_dir" 2>/dev/null \
    || ! printf '%s | %s | [team-publish] %s | %s\n' "$(date '+%Y-%m-%d %H:%M')" "$SLUG" "$UNPUB_REASON" "<세션없음>" >> "$AUDIT_LOG" 2>/dev/null; then
    printf 'archive: audit log 기록에 실패했습니다 (%s) — 우회 사유를 남길 수 없어 차단합니다.\n' "$AUDIT_LOG" >&2
    return 1
  fi
  printf 'archive: WARNING — 팀 저장소 반영 검사 우회 (사유: %s). audit log 기록.\n' "$UNPUB_REASON" >&2
  return 0
}

# _archive_tpg_tree_unreadable <tip> — (가) 발행 대상의 트리를 읽지 못했을 때의 우회 처리와 거부 안내. rc 0 우회 / 1 거부.
_archive_tpg_tree_unreadable() {
  local brc=0
  _archive_tpg_bypass || brc=$?
  [[ "$brc" -ne 0 ]] || return 0
  [[ "$brc" -eq 2 ]] || return 1
  printf 'archive: 팀 저장소 반영 대상을 판정할 수 없습니다(발행 대상 %s 의 트리를 읽지 못함) — 발행하지 않습니다.\n' "$1" >&2
  printf 'archive:   이번 작업만 반영하지 않으려면 --allow-unpublished-submodule "<사유>" 로 이 검사만 건너뛰십시오 (audit 기록).\n' >&2
  return 1
}

# _archive_tpg_remote <정리 파일> <submodule 디렉터리> <git 인자…> — 팀 원격 조회 한 번(git -C <디렉터리> <git 인자…>)을
#   RD_MERGE_FETCH_TIMEOUT 상한으로 실행한다(시작 줄은 호출부가 먼저 낸다). 입력 대기 방지 env 는 rd_git_noprompt_env 가 정한다 —
#   상한 실행은 배경 프로세스 그룹이라 입력을 묻는 ssh 가 멈춰 상한까지 기다리므로 BatchMode 로 즉시 실패시킨다(fail-closed).
#   rc 0 성공 / 그 밖 실패. 실패 원인 한 줄은 _ARCHIVE_TPG_CAUSE 에 둔다(git 오류 첫 줄 또는 「<N>초 안에 끝나지 않았습니다」).
_ARCHIVE_TPG_CAUSE=""
_archive_tpg_remote() {
  local errf="$1" dir="$2" rc=0
  shift 2
  _ARCHIVE_TPG_CAUSE=""
  rd_git_noprompt_env "$dir"
  rd_run_limited "$_ARCHIVE_TPG_LIM" "$errf" "${RD_GIT_NOPROMPT_ENV[@]}" git -C "$dir" "$@" >/dev/null || rc=$?
  [[ "$rc" -ne 0 ]] || return 0
  if [[ "$rc" -eq 124 ]]; then
    _ARCHIVE_TPG_CAUSE="${_ARCHIVE_TPG_LIM}초 안에 끝나지 않았습니다"
  else
    _ARCHIVE_TPG_CAUSE="$(sed -n 1p "$errf" 2>/dev/null)"
    [[ -n "$_ARCHIVE_TPG_CAUSE" ]] || _ARCHIVE_TPG_CAUSE="git 종료 코드 $rc"
  fi
  return "$rc"
}

_ARCHIVE_TPG_LIM=60
_archive_team_publish_gate_run() {
  local tip="$1" root="$CURRENT_WT" targets trc=0 path _old new mode br sub head rc cfg_rc found=0 bad="" brc
  local cfgroot="$_TPG_CFGROOT" sub_abs top work_wt="" new_sub base berr gl need=0 retry=0
  local retry_line='네트워크·인증을 확인한 뒤 같은 명령을 다시 실행하거나, 이번 작업만 --allow-unpublished-submodule "<사유>" 로 이 검사만 건너뛰십시오 (audit 기록).'
  _ARCHIVE_TPG_LIM="${RD_MERGE_FETCH_TIMEOUT:-60}"
  [[ "$_ARCHIVE_TPG_LIM" =~ ^[0-9]+$ && "$_ARCHIVE_TPG_LIM" -gt 0 ]] || _ARCHIVE_TPG_LIM=60
  # (가) tip 의 gitlink 중 반영 방식이 manual 이 아닌 것(설정을 읽지 못한 것 포함)이 없으면 기준점 없이 통과한다.
  #   submodule 이 없는 저장소·manual 설정·기준점이 없는 옛 no-fr 작업의 발행이 종전과 같다(spec D3-2 호환).
  #   tip 의 트리를 읽지 못하면 통과하지 않는다(fail-closed) — 원인 한 줄과 함께 (나)·(다)와 같은 우회 처리를 거친다.
  local lsf q=0 rec
  lsf="$(mktemp "${TMPDIR:-/tmp}/rd-tpg-tree.XXXXXX")" || { printf 'archive: 임시 파일을 만들 수 없어 팀 저장소 반영 대상을 판정하지 못했습니다 — 발행하지 않습니다.\n' >&2; return 1; }
  if ! git -C "$root" cat-file -e "${tip}^{commit}" 2>/dev/null \
     || ! git -C "$root" -c core.quotepath=false ls-tree -r --full-tree "$tip" >"$lsf" 2>/dev/null; then
    rm -f "$lsf"
    _archive_tpg_tree_unreadable "$tip"; return $?
  fi
  # 트리 전체를 bash read 로 돌면 파일이 많은 저장소에서 수 초가 걸린다 — gitlink(160000) 항목의 경로만 awk 로 걸러 읽는다.
  #   -z 없는 출력은 줄 경계가 분명하다: git 이 탭·개행·제어 문자·따옴표·역슬래시가 든 경로를 "…" 로 인용한다
  #   (core.quotepath=false 라 비ASCII 경로는 인용하지 않는다). 인용하지 않은 경로는 경로 그대로다.
  #   인용된 gitlink 경로가 있으면 그 경로를 정확히 읽으려고 -z 출력(NUL 경계)으로 다시 읽는다 — 드문 경우라 bash read 비용을 감수한다.
  #   여기서는 반영 방식만 보고 경로의 탭·개행은 검사하지 않는다. 표현 검사는 실제 대상만 보는 (다)의 tp_targets 가 한다.
  gl="$(awk -F'\t' '$1 ~ /^160000 /{print substr($0, index($0, "\t") + 1)}' "$lsf")"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ "$path" == \"* ]]; then q=1; continue; fi
    cfg_rc=0; mode="$(tp_config "$cfgroot" "$path" mode 2>/dev/null)" || cfg_rc=$?
    if [[ "$cfg_rc" -ne 0 || "$mode" != manual ]]; then need=1; break; fi
  done <<EOF_TPG_GL
$gl
EOF_TPG_GL
  if [[ "$need" -eq 0 && "$q" -eq 1 ]]; then
    if ! git -C "$root" ls-tree -r -z --full-tree "$tip" >"$lsf" 2>/dev/null; then
      rm -f "$lsf"
      _archive_tpg_tree_unreadable "$tip"; return $?
    fi
    while IFS= read -r -d '' rec; do
      [[ "$rec" == "160000 "* ]] || continue
      path="${rec#*$'\t'}"
      cfg_rc=0; mode="$(tp_config "$cfgroot" "$path" mode 2>/dev/null)" || cfg_rc=$?
      if [[ "$cfg_rc" -ne 0 || "$mode" != manual ]]; then need=1; break; fi
    done <"$lsf"
  fi
  rm -f "$lsf"
  [[ "$need" -eq 1 ]] || return 0
  # (나) 기준점 — 리뷰한 범위 (spec D2-1). stderr(옛 마커 경고·원인·새 세션 안내)는 그대로 전달한다.
  berr="$(mktemp "${TMPDIR:-/tmp}/rd-tpg-base.XXXXXX")" || { printf 'archive: 임시 파일을 만들 수 없어 팀 저장소 반영 대상을 판정하지 못했습니다 — 발행하지 않습니다.\n' >&2; return 1; }
  rc=0; base="$(tp_target_base "$root" "$tip" "$FR_BRANCH" 2>"$berr")" || rc=$?
  if [[ "$rc" -ne 0 || -z "$base" ]]; then
    brc=0; _archive_tpg_bypass || brc=$?
    if [[ "$brc" -eq 2 ]]; then
      # tp_target_base 의 원인을 앞세운다. 「기준 이력 없음」 은 기준점이 정말 없을 때만 쓴다(기록된 기준점이 무효면 다른 원인).
      cat "$berr" >&2
      if grep -q '^tp_target_base: 반영 대상 기준점을 정할 수 없습니다' "$berr"; then
        printf 'archive: 팀 저장소 반영 대상을 판정할 수 없습니다(기준 이력 없음) — 발행하지 않습니다.\n' >&2
        printf 'archive:   기준점 정하기: bash rd-workflow/scripts/rd task set-base <리뷰한 diff 의 기준 커밋> 으로 기준점을 정하고 task-state 를 커밋한 뒤 다시 실행하십시오(게이트는 커밋된 task-state 만 읽습니다).\n' >&2
      else
        printf 'archive: 팀 저장소 반영 대상을 판정할 수 없습니다(기록된 리뷰 기준점을 쓸 수 없음) — 발행하지 않습니다.\n' >&2
      fi
      _archive_nofr_name_hint || true
      printf 'archive:   이번 작업만 반영하지 않으려면 --allow-unpublished-submodule "<사유>" 로 이 검사만 건너뛰십시오 (audit 기록).\n' >&2
    else
      cat "$berr" >&2
    fi
    rm -f "$berr"
    [[ "$brc" -eq 0 ]] && return 0
    return 1
  fi
  cat "$berr" >&2; rm -f "$berr"
  # (다) 대상 판정 — 경로는 리뷰한 범위(기준점..seal 마커 head)로 한정하고 포인터 값은 tip 에서 읽는다(tp_reviewed_head).
  #   tp_targets 의 원인 줄(실제 대상 경로에 탭·개행이 있음)은 그대로 stderr 로 낸다. 판정하지 못하면 (가)·(나)와 같은
  #   우회 처리를 거친다(--allow-unpublished-submodule "<사유>" 가 있으면 audit 기록 뒤 통과).
  local rhead=""
  rhead="$(tp_reviewed_head "$root" "$tip" 2>/dev/null)" || trc=$?
  [[ "$trc" -ne 0 ]] || targets="$(tp_targets "$root" "$base" "$tip" "$rhead")" || trc=$?
  if [[ "$trc" -ne 0 ]]; then
    brc=0; _archive_tpg_bypass || brc=$?
    [[ "$brc" -ne 0 ]] || return 0
    [[ "$brc" -eq 2 ]] || return 1
    printf 'archive: 팀 저장소 반영 대상을 판정할 수 없습니다(gitlink 비교 실패) — 발행하지 않습니다.\n' >&2
    printf 'archive:   이번 작업만 반영하지 않으려면 --allow-unpublished-submodule "<사유>" 로 이 검사만 건너뛰십시오 (audit 기록).\n' >&2
    return 1
  fi
  [[ -n "$targets" ]] || return 0
  local errf
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpg-remote.XXXXXX")" || { printf 'archive: 임시 파일을 만들 수 없어 팀 저장소 반영 여부를 판정하지 못했습니다 — 발행하지 않습니다.\n' >&2; return 1; }
  while IFS=$'\t' read -r path _old new; do
    [[ -n "$path" ]] || continue
    # 삭제된 submodule(new=0)은 반영할 포인터가 없다.
    case "$new" in *[!0]*) ;; *) continue ;; esac
    cfg_rc=0; mode="$(tp_config "$cfgroot" "$path" mode 2>/dev/null)" || cfg_rc=$?
    if [[ "$cfg_rc" -ne 0 ]]; then
      bad="${bad}"$'\n'"archive:   - ${path}: team_publish 설정을 읽을 수 없습니다(rd-workflow/config/workflow.json 확인)"
      continue
    fi
    [[ "$mode" != manual ]] || continue
    if [[ "$found" -eq 0 ]]; then found=1; tp_notice_default "$cfgroot"; fi
    cfg_rc=0; br="$(tp_config "$cfgroot" "$path" base 2>/dev/null)" || cfg_rc=$?
    # fr 모드의 판정은 작업 worktree(fr 브랜치를 체크아웃한 곳)의 submodule 로 한다. 기본 worktree 에는 이 작업이 새로 더한
    # submodule 의 디렉터리가 없고, merge 전이라 git submodule update --init 도 듣지 않는다.
    # no-fr 모드는 작업 커밋이 이미 기본 브랜치 위에 있으므로 호출 worktree(기본 체크아웃)의 submodule 로 한다.
    if [[ -z "$work_wt" ]]; then
      if [[ "$BRANCH_MODE" == "no-fr" ]]; then
        work_wt="$CURRENT_WT"
      else
        work_wt="$(_archive_fr_worktree "$FR_BRANCH")" || work_wt=""
        if [[ -z "$work_wt" || ! -d "$work_wt" ]]; then
          work_wt=""
          bad="${bad}"$'\n'"archive:   - ${path}: ${FR_BRANCH} 를 체크아웃한 worktree(--no-worktree 작업이면 기본 worktree)를 찾을 수 없어 submodule 의 반영 여부를 판정할 수 없습니다 — git worktree add <경로> ${FR_BRANCH} 로 체크아웃한 뒤 다시 실행하십시오"; continue
        fi
      fi
    fi
    sub="$work_wt/$path"
    # submodule 이 초기화되지 않았으면(빈 디렉터리·없는 디렉터리) git -C 가 상위 overlay 저장소를 잡는다 — 그 저장소에 fetch·set-head 를 하지 않도록 먼저 막는다.
    sub_abs="$(cd "$sub" 2>/dev/null && pwd -P)" || sub_abs=""
    top="$(git -C "$sub" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [[ -z "$sub_abs" || "$top" != "$sub_abs" ]]; then
      case "$_old" in *[!0]*) new_sub="" ;; *) new_sub=" (이 작업이 새로 더한 submodule 입니다 — 반영하지 않으려면 --allow-unpublished-submodule \"<사유>\")" ;; esac
      bad="${bad}"$'\n'"archive:   - ${path}: 작업 worktree 의 submodule 이 초기화되지 않았습니다 — cd ${work_wt} && git submodule update --init ${path} 뒤 다시 실행하십시오${new_sub}"; continue
    fi
    if [[ "$cfg_rc" -ne 0 ]]; then
      bad="${bad}"$'\n'"archive:   - ${path}: team_publish.base 설정을 읽을 수 없습니다"; continue
    fi
    if [[ -z "$br" ]]; then
      head="$(git -C "$sub" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" || head=""
      if [[ -z "$head" ]]; then
        printf 'archive: 팀 저장소 반영 확인 — %s 의 origin 기본 브랜치를 조회합니다 (git remote set-head, 최대 %s초)\n' "$path" "$_ARCHIVE_TPG_LIM" >&2
        if ! _archive_tpg_remote "$errf" "$sub" remote set-head origin --auto; then
          bad="${bad}"$'\n'"archive:   - ${path}: 팀 저장소 origin 의 기본 브랜치를 조회하지 못했습니다 — ${_ARCHIVE_TPG_CAUSE}"
          retry=1; continue
        fi
        head="$(git -C "$sub" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" || head=""
      fi
      br="${head#refs/remotes/origin/}"
      if [[ -z "$head" || -z "$br" ]]; then
        bad="${bad}"$'\n'"archive:   - ${path}: 대상 브랜치를 알 수 없습니다(origin/HEAD 없음, team_publish.base 도 비어 있음)"; continue
      fi
    fi
    printf 'archive: 팀 저장소 반영 확인 — %s 의 origin/%s 를 조회합니다 (git fetch, 최대 %s초)\n' "$path" "$br" "$_ARCHIVE_TPG_LIM" >&2
    if ! _archive_tpg_remote "$errf" "$sub" fetch -q origin "+refs/heads/${br}:refs/remotes/origin/${br}"; then
      bad="${bad}"$'\n'"archive:   - ${path}: 팀 저장소 origin/${br} 를 가져오지 못해 반영 여부를 판정할 수 없습니다 — ${_ARCHIVE_TPG_CAUSE}"
      retry=1; continue
    fi
    rc=0; git -C "$sub" merge-base --is-ancestor "$new" "refs/remotes/origin/${br}" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      bad="${bad}"$'\n'"archive:   - ${path}: ${new:0:12} 가 팀 저장소 origin/${br} 에 반영되지 않았습니다"
    fi
  done <<EOF_TPG
$targets
EOF_TPG
  rm -f "$errf"
  [[ -n "$bad" ]] || return 0
  brc=0; _archive_tpg_bypass || brc=$?
  [[ "$brc" -ne 0 ]] || return 0
  [[ "$brc" -eq 2 ]] || return 1
  printf 'archive: 팀 저장소에 반영되지 않은 submodule 포인터가 있어 발행하지 않습니다.%s\n' "$bad" >&2
  if [[ "$retry" -eq 1 ]]; then
    printf 'archive:   팀 원격 조회 실패: %s\n' "$retry_line" >&2
  fi
  printf 'archive:   다음 행동: bash rd-workflow/scripts/rd pr open 으로 PR 을 올리거나, PR 이 merge 됐다면 bash rd-workflow/scripts/rd pr check --apply 를 실행하십시오.\n' >&2
  printf 'archive:   이번 작업만 반영하지 않으려면 --allow-unpublished-submodule "<사유>" 로 이 검사만 건너뛰십시오 (audit 기록).\n' >&2
  printf 'archive:   다음 작업부터 반영하지 않으려면 기본 브랜치에서 rd-workflow/config/workflow.json 의 team_publish.mode 를 manual 로 바꿔 커밋하십시오(submodule 별은 team_publish.submodules.<경로>.mode).\n' >&2
  if [[ "$BRANCH_MODE" == "no-fr" ]]; then
    printf 'archive:   이번 작업(기본 브랜치)에서 설정을 바꾸려면 bash rd-workflow/scripts/rd task set-status "구현 중" → 설정 커밋 → final diff review 재종결 → rd review seal 순서로 하십시오(seal 이 설정을 보호합니다).\n' >&2
  else
    printf 'archive:   이번 fr 브랜치에서 설정을 바꾸려면 bash rd-workflow/scripts/rd task set-status "구현 중" → 설정 커밋 → final diff review 재종결 → rd review seal 순서로 하십시오(seal 이 설정을 보호합니다).\n' >&2
  fi
  return 1
}

_TPG_CFGROOT=""
archive_team_publish_gate() {
  local tip="$1" root="$CURRENT_WT" _r=0
  # 설정은 tip(fr 브랜치, no-fr 은 정리 전 HEAD)의 workflow.json 에서 읽는다 — rd pr open 이 작업 worktree 의 설정을 읽으므로
  # 같은 기준이어야 하고, 사용자가 안내대로 작업 줄기에서 mode 를 manual 로 바꾸면 이 게이트도 그 값을 따라야 한다.
  # tp_config 는 <root>/rd-workflow/config/workflow.json 을 읽으므로 임시 root 에 둔다(파일이 없으면 없는 대로 기본값).
  _TPG_CFGROOT="$(mktemp -d)" || { printf 'archive: 임시 디렉터리를 만들 수 없어 팀 저장소 반영 설정을 읽지 못했습니다 — 발행하지 않습니다.\n' >&2; return 1; }
  if git -C "$root" cat-file -e "${tip}:rd-workflow/config/workflow.json" 2>/dev/null; then
    mkdir -p "$_TPG_CFGROOT/rd-workflow/config"
    if ! git -C "$root" show "${tip}:rd-workflow/config/workflow.json" > "$_TPG_CFGROOT/rd-workflow/config/workflow.json" 2>/dev/null; then
      printf 'archive: 발행 대상의 rd-workflow/config/workflow.json 을 읽을 수 없습니다 — 발행하지 않습니다.\n' >&2
      rm -rf "$_TPG_CFGROOT"; return 1
    fi
  fi
  _archive_team_publish_gate_run "$@" || _r=$?
  rm -rf "$_TPG_CFGROOT"
  return "$_r"
}

# Status 게이트는 seal 검사 **앞**에 둔다 — no-fr 의 cleanup 이후 재실행은 seal 포인터가
# 지워져 seal 검사가 먼저 거부하므로, 뒤에 두면 Status 쪽 재실행 안내에 도달하지 못한다.
# 두 게이트는 서로의 판정을 바꾸지 않는 독립 게이트다(각각 자기 우회 플래그만 받는다).
archive_status_precheck "$ALLOW_STATUS" "$STATUS_REASON" "$SLUG" "$AUDIT_LOG" "$FR_BRANCH" || exit 1
archive_review_precheck "$FORCE_SKIP_REVIEW" "$SKIP_REASON" "$SLUG" "$AUDIT_LOG" "$FR_BRANCH" || exit 1
# 팀 저장소 반영 게이트 (change spec D10·2026-11-18-0900 D3-2) — Status·seal 게이트 다음, merge·정리 커밋 전. 두 모드 공통이다.
#   tip: fr 모드는 fr 브랜치, no-fr 모드는 이 시점의 HEAD OID(Step 4 정리 커밋 전). 기준점은 게이트 안에서 구한다
#   (기준점 실패도 --allow-unpublished-submodule 우회가 닿아야 하므로).
#
#   no-fr 의 정리 커밋 뒤 재실행 — Step 4 정리 커밋은 review-session·base-commit 을 지운다. push 실패 같은 부분 성공 뒤
#   재실행에서 그 HEAD 를 판정하면 기준점이 없어 거부되므로, 정리 커밋임을 확인한 경우에만 정리 전 커밋을 tip 으로 둔다.
#   그 커밋은 첫 실행이 판정한 커밋과 같다(같은 seal 마커·review-session·workflow.json). 판정 기준(모두 맞아야 함):
#     (1) 정리 커밋 C 가 _dpr_cleanup_shape(_direct_pr_common.sh) 모양이다 — 제목이 Step 4 의 「chore(lifecycle): archive
#         <SLUG> metadata 정리」, 부모 하나, 부모의 task-state Status 가 `아카이브 보류`, 바뀐 경로가 lifecycle_metadata_paths
#         와 팀 PR 기록 경로뿐.
#     (2) C 의 task-state Status 가 `대기 중` 이다(Step 4 가 쓴 값).
#     (3) C 는 HEAD 이거나 HEAD 의 부모다. 부모일 때 HEAD 는 부모 하나이고, 바뀐 경로가 lifecycle_metadata_paths 뿐이며,
#         Status 가 `대기 중` 이다 — slug 단계가 요구하는 `rd task set-title` 복구를 커밋한 경우다.
#   하나라도 맞지 않으면 종전대로 HEAD 를 판정한다(재실행 때 다른 short-title 을 주면 (1)의 제목이 달라 이쪽이다).
_archive_status_at() {  # <커밋> — 그 커밋의 task-state Status(읽지 못하면 빈 값)
  git show "$1:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null | awk -F= '$1=="status"{sub(/^[^=]+=/,""); print; exit}'
}
_archive_only_lifecycle_paths() {  # <커밋> — 부모 하나이고 바뀐 경로가 lifecycle_metadata_paths 뿐이면 rc 0
  local c="$1" parents changed allowed p
  parents="$(git rev-list --parents -n 1 "$c" 2>/dev/null)" || return 1
  set -- $parents
  [[ "$#" -eq 2 ]] || return 1
  changed="$(git diff-tree --no-commit-id --name-only -r --no-renames --ignore-submodules=none "$1" 2>/dev/null)" || return 1
  [[ -n "$changed" ]] || return 1
  allowed="$(lifecycle_metadata_paths)" || return 1
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "
$allowed
" in *"
$p
"*) ;; *) return 1 ;; esac
  done <<EOF_ALP
$changed
EOF_ALP
  return 0
}
_archive_nofr_gate_tip() {  # HEAD OID 또는 확인된 정리 커밋의 부모 OID 를 stdout 으로. HEAD 를 읽지 못하면 rc 1.
  local head c root
  head="$(git rev-parse HEAD 2>/dev/null)" || return 1
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { printf '%s\n' "$head"; return 0; }
  for c in "$head" "$(git rev-parse -q --verify "${head}^1" 2>/dev/null || true)"; do
    [[ -n "$c" ]] || continue
    if [[ "$c" != "$head" ]]; then
      _archive_only_lifecycle_paths "$head" || break
      [[ "$(_archive_status_at "$head")" == "대기 중" ]] || break
    fi
    if _dpr_cleanup_shape "$root" "$c" "$SLUG" >/dev/null 2>&1 && [[ "$(_archive_status_at "$c")" == "대기 중" ]]; then
      git rev-parse "${c}^1" 2>/dev/null && return 0
      break
    fi
  done
  printf '%s\n' "$head"
}
# _archive_nofr_name_hint — no-fr 재실행이 기준점을 못 찾을 때 원인 후보(첫 실행의 작업 이름)와 복구 순서를 stderr 로 안내한다 (spec D8).
#   HEAD 와 (_archive_nofr_gate_tip 의 (3) 조건을 만족하는) HEAD 의 부모 중 제목이 「chore(lifecycle): archive <이름> metadata 정리」이고,
#   <이름> 이 이번 SLUG 와 다르며 그 이름으로 _dpr_cleanup_shape 와 Status `대기 중` 이 맞는 커밋을 찾는다. 판정·종료 코드는 바꾸지 않는다(rc 0).
#   <이름> != SLUG 는 방어 조건이다: 이름이 같으면 _archive_nofr_gate_tip 이 정리 커밋을 이미 알아봐 이 안내에 오지 않는다.
_archive_nofr_name_hint() {
  local head root c parent name subj re def="" recov anc rtip="" fcmd="" qd=""
  [[ "${BRANCH_MODE:-}" == "no-fr" ]] || return 0
  head="$(git rev-parse HEAD 2>/dev/null)" || return 0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  parent="$(git rev-parse -q --verify "${head}^1" 2>/dev/null || true)"
  re='^chore\(lifecycle\): archive (.+) metadata 정리$'
  for c in "$head" "$parent"; do
    [[ -n "$c" ]] || continue
    if [[ "$c" != "$head" ]]; then
      _archive_only_lifecycle_paths "$head" || break
      [[ "$(_archive_status_at "$head")" == "대기 중" ]] || break
    fi
    subj="$(git log -1 --format=%s "$c" 2>/dev/null)" || continue
    [[ "$subj" =~ $re ]] || continue
    name="${BASH_REMATCH[1]}"
    # set-title 이 그대로 받는 이름(normalize_slug 결과가 원문과 같음)만 안내합니다 — [a-z0-9-] 라 셸 인자로 그대로 쓸 수 있습니다.
    [[ "$(normalize_slug "$name" 2>/dev/null)" == "$name" ]] || continue
    [[ "$name" != "$SLUG" ]] || continue
    _dpr_cleanup_shape "$root" "$c" "$name" >/dev/null 2>&1 || continue
    [[ "$(_archive_status_at "$c")" == "대기 중" ]] || continue
    printf 'archive:   원인 후보: 첫 실행의 작업 이름은 %s 인데 이번 실행은 %s 입니다 — 정리 커밋을 알아보지 못해 기준점을 찾지 못했습니다.\n' "$name" "$SLUG" >&2
    recov='bash rd-workflow/scripts/rd task set-title '"$name"' --force (복구 전용)'
    if [[ "$c" == "$head" ]]; then
      printf 'archive:   다시 실행: %s → git commit -m "chore(lifecycle): %s 작업 이름 복구" -- rd-workflow-workspace/.lifecycle/task-state CURRENT_TASK.md → archive.sh 재실행\n' "$recov" "$name" >&2
    else
      # 고쳐 쓰기(amend)는 HEAD 가 원격에 없다고 확인했을 때만 안내합니다. 원격 기본 브랜치의 지금 끝을 ls-remote 로 읽습니다 —
      # 원격 추적 ref 는 다른 체크아웃의 push 뒤에 뒤처져 있을 수 있습니다. 끝을 읽지 못하거나 그 커밋이 로컬에 없으면 원인 줄만 냅니다.
      def="$(get_default_branch 2>/dev/null)" || def=""
      anc=2; rtip=""
      if [[ -n "$def" ]]; then
        rtip="$(git ls-remote origin "refs/heads/$def" 2>/dev/null)" || rtip=""
        rtip="${rtip%%[[:space:]]*}"
      fi
      if [[ -n "$rtip" ]] && git cat-file -e "${rtip}^{commit}" 2>/dev/null; then
        anc=0; git merge-base --is-ancestor "$head" "$rtip" 2>/dev/null || anc=$?
        # 얕은 복제는 원격 쪽 이력이 끊겨 있어 「조상이 아님(rc 1)」 을 믿을 수 없습니다 — 판정하지 않습니다.
        [[ "$anc" == 1 && "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && anc=3
      fi
      case "$anc" in
        0) printf 'archive:   HEAD 가 원격에 있어 고쳐 쓰지 않습니다 — 기준점을 정하려면 rd task set-base <리뷰한 diff 의 기준 커밋>\n' >&2 ;;
        1) printf 'archive:   다시 실행: %s → git commit --amend --no-edit -- rd-workflow-workspace/.lifecycle/task-state CURRENT_TASK.md (정리 커밋이 HEAD 의 부모로 남아야 합니다) → archive.sh 재실행\n' "$recov" >&2 ;;
        *)
          # 기본 브랜치를 이름으로 가져오게 안내합니다 — 단일 브랜치 복제의 git fetch origin 은 기본 브랜치를 가져오지 않습니다.
          qd="<기본 브랜치>"; [[ -n "$def" ]] && qd="$(dpr_shq "$def")"
          fcmd="git fetch origin $qd"
          [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && fcmd="git fetch --unshallow origin $qd"
          if [[ "$anc" == 3 ]]; then
            printf 'archive:   얕은 복제라 HEAD 가 원격(origin/%s)에 있는지 판정하지 못해 고쳐 쓰는 순서를 안내하지 않습니다 — %s 뒤 다시 실행하면 안내합니다.\n' "$def" "$fcmd" >&2
          else
            printf 'archive:   원격 상태(origin/%s)를 확인하지 못해 고쳐 쓰는 순서를 안내하지 않습니다 — %s 뒤 다시 실행하면 안내합니다.\n' "${def:-<기본 브랜치>}" "$fcmd" >&2
          fi ;;
      esac
    fi
    return 0
  done
  return 0
}
if [[ "$BRANCH_MODE" == "fr" ]]; then
  _tpg_tip="$FR_BRANCH"
else
  _tpg_tip="$(_archive_nofr_gate_tip)" || { printf 'archive: HEAD 를 읽을 수 없어 팀 저장소 반영 여부를 판정하지 못했습니다 — 발행하지 않습니다.\n' >&2; exit 1; }
fi
archive_team_publish_gate "$_tpg_tip" || exit 1

# Step 2 — archive content 휴리스틱 (warning만)
# no-fr 모드에는 fr tip 이 없으므로 같은 휴리스틱을 현재 HEAD 의 마지막 커밋에 적용합니다.
# 경고일 뿐이라 판정을 바꾸지 않지만, "아카이브 내용을 커밋하지 않았다" 는 흔한 실수는
# 두 모드에서 똑같이 일어나므로 no-fr 이라고 알림을 없애지 않습니다.
# fr 모드는 마지막 커밋이 아니라 기본 브랜치와의 공통 조상 이후 커밋 전체에서 아카이브 사본
# (request-archive/*.md) **추가** 를 찾습니다. REQUEST.md·CURRENT_TASK.md 변경은 착수 커밋부터
# 계속 있으므로 신호로 쓰지 않습니다.
if [[ "$BRANCH_MODE" == "no-fr" ]]; then
  LAST_COMMIT_REF="HEAD"
  LAST_COMMIT_FILES="$(git log -1 "$LAST_COMMIT_REF" --name-only --pretty=format: 2>/dev/null || true)"
  if ! grep -qE '(^|/)(REQUEST\.md|CURRENT_TASK\.md|FUTURE_REQUESTS\.md|request-archive/.*\.md)' <<<"$LAST_COMMIT_FILES"; then
    printf 'archive: WARNING — %s 마지막 commit 에 archive content 미감지\n' "$LAST_COMMIT_REF" >&2
  fi
else
  _cd_default="$(get_default_branch 2>/dev/null)" || _cd_default=""
  _cd_base=""
  if [[ -n "$_cd_default" ]]; then
    _cd_base="$(git merge-base "$_cd_default" "$FR_BRANCH" 2>/dev/null)" || _cd_base=""
  fi
  if [[ -z "$_cd_base" ]]; then
    printf 'archive: WARNING — archive content 감지를 수행하지 못했습니다 (기준 이력 없음)\n' >&2
  elif [[ "$_cd_base" == "$(git rev-parse "$FR_BRANCH" 2>/dev/null)" ]]; then
    printf 'archive: archive content 감지를 건너뜁니다 (fr 브랜치가 이미 기본 브랜치에 병합됨)\n' >&2
  else
    # 출력을 변수에 모은 뒤 끝까지 소비하는 grep 으로 판정한다 — grep -q 로 일찍 끝내면
    # SIGPIPE 가 pipefail 아래에서 양성 판정을 뒤집을 수 있다.
    _cd_added="$(git log --diff-filter=A --name-only --pretty=format: "$_cd_base..$FR_BRANCH" 2>/dev/null || true)"
    if ! grep -E 'rd-workflow-workspace/backlog/request-archive/[^/]+\.md$' <<<"$_cd_added" | grep -v '/README\.md$' >/dev/null; then
      printf 'archive: WARNING — %s 의 기본 브랜치 이후 커밋 전체에 archive content(request-archive/*.md 추가) 미감지\n' "$FR_BRANCH" >&2
    fi
  fi
fi

# Step 2b — 범위 밖 후속·흡수 확인 (경고만, 발행을 막지 않음)
# 아카이브 사본은 REQUEST.md 를 비우기 전의 내용이므로 그 사본의 「후속 FR:」 줄과 Source FR 을 읽는다.
# 대상 사본: fr 모드는 Step 2 가 모은 기본 브랜치 이후 추가 목록, no-fr 모드는 마지막 커밋의 추가 목록.
# 등록 대조 ref 는 작업 tip 과 기본 브랜치다 — 호출 세션이 기본 브랜치에 먼저 등록한 후속도 등록으로 센다.
if [[ -f "$SCRIPT_DIR/followup_check.sh" ]]; then
  if [[ "$BRANCH_MODE" == "no-fr" ]]; then
    _fc_ref="HEAD"; _fc_def="$(get_default_branch 2>/dev/null)" || _fc_def=""
    _fc_added="$(git log -1 --diff-filter=A --name-only --pretty=format: HEAD 2>/dev/null || true)"
  else
    _fc_ref="$FR_BRANCH"; _fc_def="${_cd_default:-}"; _fc_added="${_cd_added:-}"
  fi
  # git log 는 최신 커밋부터 나열하므로 첫 항목이 이번 마감의 사본이다(앞선 사본이 남은 브랜치에서 옛 사본을 고르지 않는다).
  _fc_path="$(grep -E 'rd-workflow-workspace/backlog/request-archive/[^/]+\.md$' <<<"$_fc_added" | grep -v '/README\.md$' | head -1 || true)"
  if [[ -n "$_fc_path" ]]; then
    _fc_tmp="$(mktemp "${TMPDIR:-/tmp}/rd-followup.XXXXXX" 2>/dev/null)" || _fc_tmp=""
    if [[ -n "$_fc_tmp" ]] && git show "$_fc_ref:$_fc_path" > "$_fc_tmp" 2>/dev/null; then
      RD_FC_PREFIX=archive bash "$SCRIPT_DIR/followup_check.sh" "$_fc_tmp" "$_fc_ref" ${_fc_def:+"$_fc_def"} || true
    fi
    if [[ -n "$_fc_tmp" ]]; then rm -f "$_fc_tmp"; fi
  fi
fi

# Step 3 이 이번 실행에서 직접 병합했으면 1 (D5 는 그때 검사하지 않는다: archive.sh 가 만든 병합은 자동 병합과 네 파일 해소뿐이다).
ARCHIVE_MERGED_THIS_RUN=0

# archive_conflict_precheck <default_branch> <fr_branch> <worktree> — 병합 전 코드 충돌 사전 감지 (change spec D4)
#   rc 0 진행 / 1 충돌(안내 출력 후, HEAD·인덱스·워킹트리를 바꾸지 않음) / 3 판정 불가(경고 출력 후 진행)
#   판정은 공용 rd_merge_conflicts(_merge_precheck.sh)가 한다(경로 인용·자동 해소 대상 제외 포함).
#   --gitlink-auto(change spec 2026-11-18-0900 D1-3): 조상·자손 gitlink 충돌은 Step 3 병합이 자손 커밋으로 풀므로 충돌로 세지 않는다.
archive_conflict_precheck() {
  local def="$1" fr="$2" wt="$3" keep rc=0 p
  keep="$(rd_merge_conflicts "$PWD" HEAD "$fr" --gitlink-auto)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *)
      printf 'archive: WARNING — 충돌 사전 확인을 할 수 없습니다(git 2.38 이상 필요) — 병합을 진행합니다\n' >&2
      return 3 ;;
  esac
  # 작업 worktree 경로: fr 브랜치가 체크아웃된 worktree. 못 찾으면 호출자 worktree, 그것도 없으면 자리표시.
  local fr_wt
  fr_wt="$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$fr" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0 == "branch " b {print p; exit}')" || fr_wt=""
  [[ -n "$fr_wt" ]] || fr_wt="${wt:-<작업 worktree>}"
  printf 'archive: main 과 %s 사이에 코드 충돌이 있습니다 — main 을 바꾸지 않고 멈춥니다.\n' "$fr" >&2
  printf 'archive:   충돌 경로:\n' >&2
  while IFS= read -r p; do
    [[ -n "$p" ]] && printf 'archive:     - %s\n' "$p" >&2
  done <<EOF2
$keep
EOF2
  rd_merge_conflict_guide 'archive:   ' "$fr" "$def" "$fr_wt" >&2
  return 1
}

# archive_gitlink_auto_resolve <fr tip> — Step 3 의 git merge 가 실패한 뒤, 조상·자손 gitlink 충돌을 자손 커밋으로 푼다
#   (change spec 2026-11-18-0900 D1-4). 조건: MERGE_HEAD 가 fr tip 과 같고 병합 기준이 하나(rd_merge_single_base)일 때만.
#   미병합 경로 중 stage 2·3 이 모두 gitlink(160000)인 경로마다 rd_merge_gitlink_pick(stage 1 은 모드 160000 일 때만 <base>)이
#   rc 0 이면 git update-index --cacheinfo 로 해소하고 해소 줄을 낸다(stdout). rc 1·3 인 경로는 그대로 둔다.
#   해소한 경로마다 기본 체크아웃 submodule 에 자손 커밋 객체를 확보하고(_archive_gl_acquire), 재실행 안내 줄을
#   ARCHIVE_GL_RESUME_NOTES 에 모은다 — 호출부가 병합 커밋을 만든 **뒤에** 출력한다(_archive_gl_print_notes).
#   rc 0 해소 1건 이상이고 남은 미병합 경로 없음 / 1 그 밖(조건 불충족, 해소 0건, 남은 충돌 있음).
#   기본 체크아웃 submodule 의 워킹트리(체크아웃)는 바꾸지 않는다.
ARCHIVE_GL_RESUME_NOTES=""
ARCHIVE_GL_RESOLVED=0
archive_gitlink_auto_resolve() {
  local fr="$1" mh frtip tmp rec meta path mode oid stage i n=0
  local -a P=() M1=() O1=() M2=() O2=() M3=() O3=()
  ARCHIVE_GL_RESUME_NOTES=""
  ARCHIVE_GL_RESOLVED=0
  mh="$(git rev-parse -q --verify MERGE_HEAD 2>/dev/null)" || return 1
  frtip="$(git rev-parse -q --verify "${fr}^{commit}" 2>/dev/null)" || return 1
  [[ -n "$mh" && "$mh" == "$frtip" ]] || return 1
  rd_merge_single_base "$PWD" HEAD "$frtip" >/dev/null || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/rd-gl-unmerged.XXXXXX")" || return 1
  git ls-files -u -z >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # 경로마다 stage 1·2·3 의 모드·OID 를 모은다(ls-files -u 는 같은 경로의 stage 를 이어서 낸다).
  while IFS= read -r -d '' rec; do
    meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    read -r mode oid stage <<<"$meta"
    if [[ "$n" -eq 0 || "${P[$((n - 1))]}" != "$path" ]]; then
      P+=("$path"); M1+=(""); O1+=(""); M2+=(""); O2+=(""); M3+=(""); O3+=(""); n=$((n + 1))
    fi
    i=$((n - 1))
    case "$stage" in
      1) M1[$i]="$mode"; O1[$i]="$oid" ;;
      2) M2[$i]="$mode"; O2[$i]="$oid" ;;
      3) M3[$i]="$mode"; O3[$i]="$oid" ;;
    esac
  done <"$tmp"
  rm -f "$tmp"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    path="${P[$i]}"
    if [[ "${M2[$i]}" == 160000 && "${M3[$i]}" == 160000 ]]; then
      # 직접 부른다(명령 치환 아님): fetch 기록 RD_GL_FETCHED·RD_GL_PICKED 를 이 셸에 남긴다.
      # stage 1 은 모드 160000 일 때만 <base> 로 넘긴다(기준의 일반 파일을 두 줄기가 gitlink 로 바꾼 경우는 blob 이다).
      if [[ "${M1[$i]}" == 160000 ]]; then
        rd_merge_gitlink_pick "$PWD" "$path" "${O2[$i]}" "${O3[$i]}" "${O1[$i]}" </dev/null || { i=$((i + 1)); continue; }
      else
        rd_merge_gitlink_pick "$PWD" "$path" "${O2[$i]}" "${O3[$i]}" </dev/null || { i=$((i + 1)); continue; }
      fi
      if git update-index --cacheinfo "160000,$RD_GL_PICKED,$path" </dev/null 2>/dev/null; then
        ARCHIVE_GL_RESOLVED=$((ARCHIVE_GL_RESOLVED + 1))
        printf 'archive: submodule %s 충돌을 자손 커밋 %s 로 해결했습니다\n' "$path" "${RD_GL_PICKED:0:7}"
        _archive_gl_acquire "$path" "$RD_GL_PICKED" </dev/null
      fi
    fi
    i=$((i + 1))
  done
  [[ "$ARCHIVE_GL_RESOLVED" -ge 1 ]] || return 1
  [[ -z "$(git ls-files -u 2>/dev/null)" ]] || return 1
  return 0
}

# _archive_gl_print_notes — archive_gitlink_auto_resolve 가 모은 재실행 안내를 낸다(병합 커밋을 만든 뒤에만 부른다).
_archive_gl_print_notes() {
  [[ -z "$ARCHIVE_GL_RESUME_NOTES" ]] || printf '%s' "$ARCHIVE_GL_RESUME_NOTES" >&2
  return 0
}

# _archive_gl_note <줄> — 재실행 안내 한 줄을 ARCHIVE_GL_RESUME_NOTES 에 더한다.
_archive_gl_note() { ARCHIVE_GL_RESUME_NOTES="${ARCHIVE_GL_RESUME_NOTES}$1"$'\n'; }

# _archive_gl_acquire <path> <자손 OID> — 기본 체크아웃 submodule 에 자손 커밋 객체를 확보하고 재실행 안내를 모은다 (spec D1-4 (1)(2)).
#   해소 뒤 발행이 Step 6 등에서 멈추면 상위 git status 가 ` M <path>` 를 보여 재실행이 Step 0 clean 검사에 막힌다.
#   그래서 사용자가 체크아웃을 자손 커밋으로 옮길 수 있게 객체를 받아 두고, 그 명령을 안내한다.
#   대상이 실제 submodule 저장소가 아니면(초기화 안 됨 — 빈 디렉터리에서 git -C 가 상위 저장소를 잡음) 확보도 안내도 하지 않는다.
#   출처는 객체를 직접 가진 git dir 다(rd_gl_src). 판정용 객체 풀(공통 git dir + alternates)은 fetch 출처가 될 수 없다.
#   ref·체크아웃은 바꾸지 않는다(FETCH_HEAD 만 씀). 확보 성공은 alternates 없이 대상 저장소에서 확인한다.
#   확보에 실패하면 원인 한 줄(stderr)과, 안내 줄 대신 복구 절차((가) push (나) fetch origin <ref> (다) checkout)를 모은다.
#   모든 명령의 경로·URL·ref 인자는 printf %q 로 써서 출력 그대로 실행된다.
_archive_gl_acquire() {
  local path="$1" oid="$2" wt="${CURRENT_WT:-$PWD}" dir abs top lim errf frc=0 cause="" kind="" url br qd qo
  dir="$wt/$path"
  abs="$(cd "$dir" 2>/dev/null && pwd -P)" || abs=""
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
  [[ -n "$abs" && -n "$top" && "$top" == "$abs" ]] || return 0
  qd="$(printf '%q' "$dir")"; qo="$(printf '%q' "$oid")"
  if ! env -u GIT_ALTERNATE_OBJECT_DIRECTORIES git -C "$dir" cat-file -e "${oid}^{commit}" 2>/dev/null; then
    if rd_gl_src "$wt" "$path" "$oid"; then
      lim="${RD_MERGE_FETCH_TIMEOUT:-60}"
      [[ "$lim" =~ ^[0-9]+$ && "$lim" -gt 0 ]] || lim=60
      errf="$(mktemp "${TMPDIR:-/tmp}/rd-gl-acq.XXXXXX")" || errf=/dev/null
      rd_run_limited "$lim" "$errf" env -u GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_TERMINAL_PROMPT=0 \
        git -C "$dir" fetch --quiet --no-recurse-submodules "$RD_GL_SRC" "$oid" >/dev/null || frc=$?
      if [[ "$frc" -eq 124 ]]; then
        cause="기본 체크아웃 submodule 로 받는 fetch 가 ${lim}초 안에 끝나지 않아 중단했습니다"
      elif [[ "$frc" -ne 0 ]]; then
        cause="$(sed -n 1p "$errf" 2>/dev/null)"
        [[ -n "$cause" ]] || cause="git fetch 종료 코드 $frc"
      elif ! env -u GIT_ALTERNATE_OBJECT_DIRECTORIES git -C "$dir" cat-file -e "${oid}^{commit}" 2>/dev/null; then
        cause="받은 뒤에도 기본 체크아웃 submodule 에 커밋 객체가 없습니다"
      fi
      [[ "$errf" == /dev/null ]] || rm -f "$errf"
    else
      cause="이 커밋을 직접 가진 저장소를 이 컴퓨터에서 찾지 못했습니다"
    fi
  fi
  if [[ -z "$cause" ]]; then
    _archive_gl_note "archive:   발행이 중간에 멈춰 다시 실행해야 하면: git -C ${qd} status 로 바꾼 내용이 없는지 확인한 뒤 git -C ${qd} checkout --detach ${qo}"
    return 0
  fi
  printf 'archive: submodule %s 의 자손 커밋 %s 를 기본 체크아웃 submodule 에 받지 못했습니다 — %s\n' "$path" "${oid:0:7}" "$cause" >&2
  if [[ "$cause" =~ transport\ \'([^\']+)\'\ not\ allowed ]]; then
    kind="${BASH_REMATCH[1]}"
    printf 'archive:   이 저장소가 %s 전송을 막고 있습니다. submodule 원격도 같은 전송이면 (나)도 막히므로, 허용된 전송의 원격을 쓰거나 이 저장소의 protocol.%s.allow 를 바꾼 뒤 진행하십시오\n' "$kind" "$kind" >&2
  fi
  br="rd-archive/${SLUG:-archive}-${oid:0:7}"
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || url=""
  _archive_gl_note "archive:   발행이 중간에 멈춰 다시 실행해야 하면 기본 체크아웃 submodule ${path} 에 커밋 ${oid:0:7} 을 받은 뒤 체크아웃하십시오:"
  if [[ -z "$url" ]]; then
    _archive_gl_note "archive:     기본 체크아웃 submodule 에 origin 이 없습니다 — 팀 원격을 origin 으로 설정한 뒤 다시 실행하거나, 이 커밋을 직접 받아 checkout 하십시오"
  else
    if [[ -n "$RD_GL_SRC" ]]; then
      # -C 로 submodule 디렉터리에서 실행합니다 — origin 이 상대 URL(../team.git)이면 (나)의 fetch 와 같은 기준으로 풀립니다.
      _archive_gl_note "archive:     (가) git -C ${qd} $(printf '%q' "--git-dir=$RD_GL_SRC") push $(printf '%q' "$url") $(printf '%q' "${oid}:refs/heads/${br}")"
    else
      _archive_gl_note "archive:     (가) 이 커밋을 가진 저장소에서 ${url} 의 ${br} 로 push 하십시오"
    fi
    _archive_gl_note "archive:         이 원격에 쓰기 권한이 없으면 권한이 있는 사람에게 이 커밋의 push 를 요청하십시오"
    _archive_gl_note "archive:     (나) git -C ${qd} fetch origin $(printf '%q' "refs/heads/${br}")"
  fi
  _archive_gl_note "archive:     (다) git -C ${qd} status 로 바꾼 내용이 없는지 확인한 뒤 git -C ${qd} checkout --detach ${qo}"
  return 0
}

# archive_merge_commit_check <M> — 기본 브랜치의 병합 커밋 M 이 자동 병합 결과와 같은가 (change spec D5)
#   rc 0 같음 / 1 다름(차이 경로를 stdout 한 줄씩) / 2 판정 불가
#   기록 경로는 차이로 세지 않는다: seal 보호 대상이 아니고, 자동 해소 결과가 merge-tree 결과와 다르기 때문이다.
#   gitlink 예외(change spec 2026-11-18-0900 D1-5): merge-tree 가 **충돌로 보고한** 경로 중 M^1·M^2 양쪽이 gitlink 이고
#   rd_merge_gitlink_pick(M^1 쪽, M^2 쪽, 병합 기준 쪽 — 모드 160000 일 때만)이 rc 0 인 경로는 Step 3 의 자동 해소(D1-4)가
#   푸는 경로다. 그 경로에 한해 기대 OID 를 pick 결과로 두고, 충돌 목록 검사와 diff-tree 비교 모두 M 의 gitlink 가 그 값과
#   같을 때만 차이로 세지 않는다. 병합 기준이 하나가 아니면(rd_merge_single_base rc 1) 예외가 없다. 충돌 없이 merge-tree 가
#   고른 경로(예: 리뷰한 롤백)는 예외가 없어 손 병합이 바꾸면 종전대로 차이로 센다.
archive_merge_commit_check() {
  local m="$1" out rc=0 t p diff_out bad="" mb="" g1 g2 gb gm exp=""
  out="$(git merge-tree --write-tree --name-only --no-messages -z "${m}^1" "${m}^2" 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}")" || rc=$?
  case "$rc" in 0|1) ;; *) return 2 ;; esac
  t="$(printf '%s\n' "$out" | sed -n 1p)"
  [[ -n "$t" ]] || return 2
  if [[ "$rc" -eq 1 ]]; then
    mb="$(rd_merge_single_base "$PWD" "${m}^1" "${m}^2")" || mb=""
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      rd_path_is_record "$p" && continue
      if [[ -n "$mb" ]] && g1="$(_rd_merge_gl_entry "$PWD" "${m}^1" "$p")" && g2="$(_rd_merge_gl_entry "$PWD" "${m}^2" "$p")"; then
        gb="$(_rd_merge_gl_entry "$PWD" "$mb" "$p")" || gb=""
        # 직접 부른다(명령 치환 아님): RD_GL_PICKED·fetch 기록을 이 셸에 남긴다.
        if rd_merge_gitlink_pick "$PWD" "$p" "$g1" "$g2" ${gb:+"$gb"} </dev/null; then
          exp="${exp}${p}"$'\t'"${RD_GL_PICKED}"$'\n'
          gm="$(_rd_merge_gl_entry "$PWD" "$m" "$p")" || gm=""
          [[ -n "$gm" && "$gm" == "$RD_GL_PICKED" ]] && continue
        fi
      fi
      bad="${bad}${p}"$'\n'
    done < <(printf '%s\n' "$out" | sed 1d | sort -u)
    if [[ -n "$bad" ]]; then printf '%s' "$bad"; return 1; fi
  fi
  # NUL 구분 출력은 tr 로 줄바꿈으로 바꿔 받는다(pipefail 이 git 실패를 전달한다). 줄바꿈을 품은 경로는 조각이 기록 경로가
  # 아니므로 차이로 잡혀 거부 쪽으로 기운다. --ignore-submodules=none: submodule.<이름>.ignore=all 이 손 병합에 섞은
  # gitlink 변경을 목록에서 빼지 못하게 한다(한정 해시와 같은 이유).
  diff_out="$(git diff-tree -r -z --no-renames --ignore-submodules=none --name-only "$t" "${m}^{tree}" 2>/dev/null | tr '\0' '\n')" || return 2
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    rd_path_is_record "$p" && continue
    # gitlink 예외 경로: M 의 gitlink 가 기대 OID(자손)와 같으면 차이로 세지 않는다.
    if [[ -n "$exp" ]] && gb="$(printf '%s' "$exp" | awk -F'\t' -v k="$p" '$1 == k { print $2; f = 1; exit } END { exit f ? 0 : 1 }')"; then
      gm="$(_rd_merge_gl_entry "$PWD" "$m" "$p")" || gm=""
      [[ -n "$gm" && "$gm" == "$gb" ]] && continue
    fi
    bad="${bad}${p}"$'\n'
  done <<EOF2
$diff_out
EOF2
  if [[ -n "$bad" ]]; then printf '%s' "$bad"; return 1; fi
  return 0
}

# archive_gitlink_merge_check <tip> <exclude> <stage> — 병합 커밋이 submodule 커밋을 빠뜨리지 않았는가 (change spec 2026-11-06-2215 D1~D4)
#   범위 `<tip> --not <exclude>` 의 병합 커밋 M 마다, 각 부모 Pi 의 submodule gitlink 가 M 의 gitlink 에 담겼는지(조상 관계) 본다.
#   M 결과에서 빠졌어도 M 뒤 커밋(M..tip)에서 담으면 통과한다. M·tip·Pi 중 한쪽에 gitlink 가 없는 경로는 건너뛴다(추가·삭제·이동).
#   stage: pre(병합 전) | post(병합 뒤) — 안내 문구만 다르다.
#   rc 0 통과 / 1 누락 / 2 판정 불가. 안내는 표준 오류로 낸다. 통과하면 아무것도 내지 않는다.
# 객체 찾기·제한 fetch 는 _merge_precheck.sh 의 rd_gl_select·rd_gl_git·rd_gl_fetch_once 를 쓴다(spec 2026-11-18-0900 D1-2).
#   같은 셸 안에서는 사전 판정·병합의 gitlink 판정과 이 검사가 fetch 기록 하나(RD_GL_FETCHED)를 함께 쓴다.

# _archive_gl_oid <commit> <path> — commit 의 path gitlink OID (gitlink 가 아니면 빈 출력)
_archive_gl_oid() {
  git ls-tree -r -z --full-tree "$1" -- "$2" 2>/dev/null | tr '\0' '\n' | awk -F'\t' '$1 ~ /^160000 /{split($1, a, " "); print a[3]; exit}' || true
}

# _archive_gitlink_is_ancestor <path> <a> <b> — submodule path 에서 a 가 b 의 조상인가 (D3)
#   rc 0 조상(같은 커밋 포함) / 1 아님 / 2 판정 불가. 객체가 없으면 경로마다 한 번만 fetch 해 다시 조회한다
#   (rd_gl_fetch_once — RD_MERGE_FETCH_TIMEOUT 상한, 안내 줄 접두 `archive:`).
_archive_gitlink_is_ancestor() {
  local p="$1" a="$2" b="$3" root o miss="" rc=0
  [[ "$a" != "$b" ]] || return 0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 2
  if ! rd_gl_select "$root" "$p" "$a" "$b"; then
    for o in "$a" "$b"; do
      if ! git -C "$root/$p" cat-file -e "${o}^{commit}" 2>/dev/null; then miss="$o"; break; fi
    done
    rd_gl_fetch_once "$root" "$p" "${miss:-$a}" "archive:" </dev/null || true
    rd_gl_select "$root" "$p" "$a" "$b" || return 2
  fi
  rd_gl_git merge-base --is-ancestor "$a" "$b" 2>/dev/null || rc=$?
  case "$rc" in 0|1) return "$rc" ;; *) return 2 ;; esac
}

archive_gitlink_merge_check() {
  local tip="$1" excl="$2" stage="$3" merges m ms tl p gm gt gi pi parents cand c cands step1 ok crc miss=0 unk=0 one mbase gb
  local -a par
  merges="$(git rev-list --merges "$tip" --not "$excl" 2>/dev/null)" || {
    printf 'archive: submodule gitlink 검사 범위를 읽지 못했습니다 (판정 불가) — 발행하지 않습니다.\n' >&2; return 2; }
  [[ -n "$merges" ]] || return 0
  tl="$(git ls-tree -r -z --full-tree "$tip" 2>/dev/null | tr '\0' '\n' | awk '/^160000 /{n=1} END{if(n) print "x"}')" || tl=""
  [[ -n "$tl" ]] || return 0
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    ms="$(git rev-parse --short "$m" 2>/dev/null)" || ms="$m"
    parents="$(git rev-list --parents -n 1 "$m" 2>/dev/null)" || parents=""
    read -r -a par <<<"$parents"
    # 병합 기준(부모 2개일 때 merge-base) — 한 부모가 p 를 바꾸지 않았으면 병합은 반대쪽 변경만 가져온 것이라 빠뜨림이 아니다.
    # 계산에 실패하면 기준 없음으로 두고 예외를 적용하지 않는다(통과로 새지 않게).
    mbase=""
    if [[ "${#par[@]}" -eq 3 ]]; then mbase="$(git merge-base "${par[1]}" "${par[2]}" 2>/dev/null)" || mbase=""; fi
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      gt="$(_archive_gl_oid "$tip" "$p")"
      [[ -n "$gt" ]] || continue
      gm="$(_archive_gl_oid "$m" "$p")"
      [[ -n "$gm" ]] || continue
      for pi in "${par[@]:1}"; do
        gi="$(_archive_gl_oid "$pi" "$p")"
        [[ -n "$gi" ]] || continue
        [[ "$gi" != "$gm" ]] || continue
        # 이 부모가 병합 기준과 같은 gitlink 면 이 쪽은 p 를 바꾸지 않았다 — 기준에 p gitlink 가 없으면 적용하지 않는다.
        if [[ -n "$mbase" ]]; then
          gb="$(_archive_gl_oid "$mbase" "$p")"
          [[ -z "$gb" || "$gi" != "$gb" ]] || continue
        fi
        # 1단계: 병합 결과가 부모 쪽 gitlink 를 담는가
        step1=0; _archive_gitlink_is_ancestor "$p" "$gi" "$gm" || step1=$?
        [[ "$step1" -ne 0 ]] || continue
        # 2단계: 병합 뒤 커밋(M..tip)이 담았는가
        cands="$gt"
        while IFS= read -r c; do
          [[ -n "$c" ]] || continue
          cand="$(_archive_gl_oid "$c" "$p")"
          [[ -n "$cand" ]] || continue
          printf '%s\n' "$cands" | grep -qxF -- "$cand" || cands="${cands}"$'\n'"${cand}"
        done < <(git rev-list --ancestry-path "$m..$tip" -- "$p" 2>/dev/null)
        ok=0; crc=0
        while IFS= read -r cand; do
          [[ -n "$cand" ]] || continue
          c=0; _archive_gitlink_is_ancestor "$p" "$gi" "$cand" || c=$?
          if [[ "$c" -eq 0 ]]; then ok=1; break; fi
          [[ "$c" -eq 1 ]] || crc=2
        done <<EOF2
$cands
EOF2
        [[ "$ok" -eq 0 ]] || continue
        if [[ "$step1" -eq 2 || "$crc" -eq 2 ]]; then
          unk=1
          printf 'archive: submodule %s 의 커밋 %s 가 병합 커밋 %s 에 담겼는지 판정 불가입니다 — 발행하지 않습니다.\n' "$p" "$(printf '%s' "$gi" | cut -c1-7)" "$ms" >&2
          printf 'archive:   원인: submodule 이 초기화되지 않았거나, 원격에서 받은 뒤에도 커밋 객체가 없습니다.\n' >&2
          printf 'archive:   조치: 기본 체크아웃에서 git submodule update --init -- %s 를 실행하거나 그 커밋을 submodule 원격에 push 한 뒤 다시 발행하십시오.\n' "$p" >&2
        else
          miss=1
          one=""
          if rd_gl_select "$PWD" "$p" "$gi"; then one="$(rd_gl_git log --oneline -1 "$gi" 2>/dev/null)" || one=""; fi
          printf 'archive: 병합 커밋 %s 가 submodule %s 의 커밋을 빠뜨렸습니다 — 발행하지 않습니다.\n' "$ms" "$p" >&2
          printf 'archive:   빠진 gitlink: %s%s\n' "$(printf '%s' "$gi" | cut -c1-7)" "${one:+ ($one)}" >&2
        fi
      done
    done < <(git ls-tree -r -z --full-tree "$m" 2>/dev/null | tr '\0' '\n' | awk -F'\t' '$1 ~ /^160000 /{print substr($0, index($0, "\t") + 1)}')
  done <<EOF
$merges
EOF
  if [[ "$miss" -eq 1 ]]; then
    printf 'archive:   작업 브랜치의 병합이 submodule 한쪽 커밋만 골라, 다른 쪽 커밋이 기본 브랜치 이력에 들어오지 않습니다. 복구:\n' >&2
    if [[ "$stage" == post ]]; then
      printf 'archive:     1. 기본 체크아웃에서 이번 병합을 되돌립니다: git reset --keep %s\n' "$excl" >&2
      printf 'archive:        (먼저 git log --oneline %s..HEAD 로 되돌릴 커밋이 이 병합과 archive 정리 커밋뿐인지 확인하십시오)\n' "$excl" >&2
      printf 'archive:     2. 작업 worktree 의 submodule 에서 두 커밋을 모두 담은 커밋을 만들고(예: git -C <경로> merge <빠진 커밋>) submodule 원격에 push 합니다.\n' >&2
      printf 'archive:     3. 작업 worktree 에서 gitlink 를 그 커밋으로 갱신하는 커밋을 더합니다(과거 병합은 다시 쓰지 않습니다). 이후 검증 → 새 final diff review → seal → 다시 발행\n' >&2
    else
      printf 'archive:     1. 작업 worktree 의 submodule 에서 두 커밋을 모두 담은 커밋을 만들고(예: git -C <경로> merge <빠진 커밋>) submodule 원격에 push 합니다.\n' >&2
      printf 'archive:     2. 작업 worktree 에서 gitlink 를 그 커밋으로 갱신하는 커밋을 더합니다(과거 병합은 다시 쓰지 않습니다). 이후 검증 → 새 final diff review → seal → 다시 발행\n' >&2
    fi
    return 1
  fi
  [[ "$unk" -eq 0 ]] || return 2
  return 0
}

# archive_gitlink_gate <tip> <exclude> <stage> — gitlink 검사를 돌리고, 막히면 --allow-gitlink-drop 우회를 처리한다.
#   submodule 저장소가 squash·rebase 로 병합하면 작업 브랜치의 submodule 커밋이 기본 브랜치 커밋의 조상이 되지 않아,
#   내용이 이미 담겼어도 누락·판정 불가로 막힌다. 그런 경우의 출구다. 사유 필수, audit 기록, 기록 실패는 차단.
#   병합 전에 우회했으면 같은 실행의 병합 뒤 검사는 다시 기록하지 않는다. return 0=진행, 1=차단.
_ARCHIVE_GL_BYPASSED=0
archive_gitlink_gate() {
  local rc=0 audit_dir
  archive_gitlink_merge_check "$1" "$2" "$3" || rc=$?
  [[ "$rc" -ne 0 ]] || return 0
  [[ "$_ARCHIVE_GL_BYPASSED" -eq 0 ]] || return 0
  if [[ "$ALLOW_GITLINK" -ne 1 ]]; then
    printf 'archive:   submodule 저장소가 squash·rebase 로 병합해 내용이 이미 기본 브랜치에 들어 있다면, 확인한 뒤 --allow-gitlink-drop "<사유>" 로 이 검사만 건너뛸 수 있습니다 (audit 기록).\n' >&2
    return 1
  fi
  if [[ -z "$GITLINK_REASON" ]]; then
    printf 'archive: --allow-gitlink-drop 사유 필수\n' >&2
    return 1
  fi
  audit_dir="$(dirname "$AUDIT_LOG")"
  if ! mkdir -p "$audit_dir" 2>/dev/null \
    || ! printf '%s | %s | [gitlink:rc%s] %s | %s\n' "$(date '+%Y-%m-%d %H:%M')" "$SLUG" "$rc" "$GITLINK_REASON" "<세션없음>" >> "$AUDIT_LOG" 2>/dev/null; then
    printf 'archive: audit log 기록에 실패했습니다 (%s) — 우회 사유를 남길 수 없어 차단합니다.\n' "$AUDIT_LOG" >&2
    return 1
  fi
  _ARCHIVE_GL_BYPASSED=1
  printf 'archive: WARNING — submodule gitlink 검사 우회 (사유: %s). audit log 기록.\n' "$GITLINK_REASON" >&2
  return 0
}

# ---------------------------------------------------------------------------
# 발행 뒤 Issue 닫기 (change spec 2026-11-17-1710 D4)
#
# Source FR 목록은 발행 대상에 결속된 기록에서 읽는다 — 첫 실행과 재실행이 같은 목록을 얻어야 한다.
#   fr 모드: fr tip 의 task-state `source-fr`. push 실패 뒤 재실행에도 fr 브랜치는 남아 있다(삭제는 Step 8).
#   no-fr 모드: 작업 커밋마다 하나인 보류 기록 `<git-common-dir>/rd-archive-issues/<작업 커밋 OID>`(내용 `source-fr=<목록>`).
#     읽을 때는 이름의 OID 가 발행 커밋의 조상이거나 같은 기록만 고른다. 버려진 회차·다른 줄기의 기록은 건드리지 않는다.
#     지우기는 Issue 닫기 단계 끝에서 고른 기록만 한다. 그 단계에 닿지 못한 실행(push 실패 등)은 기록을 남겨 재실행이 쓴다.
# 목록은 push 전에 한 번 확정해 ARCHIVE_ISSUE_FRS(줄바꿈 구분)에 두고, push 뒤에는 그 목록만 쓴다.
# Issue 닫기 실패는 경고만 하고 발행 rc 를 바꾸지 않는다. 로컬 전용 모드는 이 단계를 통째로 건너뛴다.
# ---------------------------------------------------------------------------
ARCHIVE_ISSUE_FRS=""
ARCHIVE_ISSUE_RECS=""
_ARCHIVE_ISSUE_REC_DIR="$_archive_git_common_dir/rd-archive-issues"
_ARCHIVE_IQ="$SCRIPT_DIR/../issue_queue.sh"

# archive_issue_record_write — no-fr 정리 직전에 그 시점 HEAD(작업 커밋) 이름으로 source-fr 목록을 남긴다.
#   source-fr 가 비었거나 `-` 이면 쓰지 않는다. 쓰기 실패는 경고만 한다(발행을 막지 않는다).
archive_issue_record_write() {
  local sfr oid
  sfr="$(state_read_field "source-fr" 2>/dev/null)" || sfr=""
  [[ -n "$sfr" && "$sfr" != "-" ]] || return 0
  if oid="$(git rev-parse HEAD 2>/dev/null)" && mkdir -p "$_ARCHIVE_ISSUE_REC_DIR" 2>/dev/null \
     && printf 'source-fr=%s\n' "$sfr" > "$_ARCHIVE_ISSUE_REC_DIR/$oid" 2>/dev/null; then
    return 0
  fi
  printf 'archive: WARNING — Issue 닫기 보류 기록을 쓰지 못했습니다 (%s) — 발행 뒤 연결된 Issue 를 닫지 못할 수 있습니다. Source FR: %s\n' "$_ARCHIVE_ISSUE_REC_DIR" "$sfr" >&2
  return 0
}

# _archive_issue_add_one <FR 상세 경로> — ARCHIVE_ISSUE_FRS 에 하나 더한다(빈 값·`-`·중복 제외).
_archive_issue_add_one() {
  local part="$1"
  [[ -n "$part" && "$part" != "-" ]] || return 0
  case $'\n'"$ARCHIVE_ISSUE_FRS" in *$'\n'"$part"$'\n'*) return 0 ;; esac
  ARCHIVE_ISSUE_FRS="${ARCHIVE_ISSUE_FRS}${part}"$'\n'
  return 0
}

# _archive_issue_add <source-fr 저장값> <publish_oid> — 저장값을 FR 상세 경로 목록으로 나눠 ARCHIVE_ISSUE_FRS 에 더한다.
#   계약은 source_fr_split(_state_common.sh)과 같다: 저장값 전체가 계약 형식을 통과하고 실존하면 원소 1개(파일 이름에 `|` 가
#   든 단일 경로를 찢지 않는다), 아니면 `|` 로 나눈다. 실존은 작업 트리가 아니라 발행 커밋의 트리로 본다(상세도 거기서 읽는다).
#   나누기는 read 로 한다 — `set -- $v` 는 경로의 `[`·`*` 를 glob 으로 펼쳐 다른 FR 상세를 고를 수 있다.
_archive_issue_add() {
  local v="$1" pub="$2" part parts=()
  [[ -n "$v" && "$v" != "-" ]] || return 0
  if _sfr_validate_one "$v" && git cat-file -e "$pub:$v" 2>/dev/null; then
    _archive_issue_add_one "$v"
    return 0
  fi
  IFS='|' read -r -a parts <<<"$v" || true
  for part in ${parts[@]+"${parts[@]}"}; do
    _archive_issue_add_one "$part"
  done
  return 0
}

# archive_issue_source_frs <publish_oid> — Source FR 목록을 확정해 ARCHIVE_ISSUE_FRS 에, 고른 no-fr 기록을 ARCHIVE_ISSUE_RECS 에 둔다.
archive_issue_source_frs() {
  local pub="$1" ts="" raw f oid
  ARCHIVE_ISSUE_FRS=""; ARCHIVE_ISSUE_RECS=""
  if [[ "$BRANCH_MODE" == "fr" ]]; then
    ts="$(git show "$FR_BRANCH:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null)" || ts=""
    raw="$(awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,""); print; exit}' <<<"$ts")" || raw=""
    _archive_issue_add "$raw" "$pub"
    return 0
  fi
  [[ -d "$_ARCHIVE_ISSUE_REC_DIR" ]] || return 0
  for f in "$_ARCHIVE_ISSUE_REC_DIR"/*; do
    [[ -f "$f" ]] || continue
    oid="${f##*/}"
    git merge-base --is-ancestor "$oid" "$pub" 2>/dev/null || continue
    raw="$(awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,""); print; exit}' "$f" 2>/dev/null)" || raw=""
    _archive_issue_add "$raw" "$pub"
    ARCHIVE_ISSUE_RECS="${ARCHIVE_ISSUE_RECS}${f}"$'\n'
  done
  return 0
}

# _archive_issue_warn <FR 상세 경로> <사유> — 경고 첫 줄 (D4-4).
_archive_issue_warn() {
  printf 'archive: WARNING — Issue 닫기 실패 (%s): %s\n' "$1" "$2" >&2
}

# archive_close_issues <publish_oid> — ARCHIVE_ISSUE_FRS 의 FR 마다 연결된 Issue 를 닫는다 (D4-3·D4-4·D4-5).
#   한 FR 이 실패해도 나머지를 처리하고, 항상 rc 0 이다. 끝에서 고른 no-fr 기록을 지운다.
archive_close_issues() {
  local pub="$1" fr det err gi url="" url_tried=0 url_reason="" out rc reason line f kr left
  det="$(mktemp)" || { echo "archive: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}') — Issue 닫기를 건너뜁니다" >&2; return 0; }
  err="$(mktemp)" || { rm -f "$det"; echo "archive: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}') — Issue 닫기를 건너뜁니다" >&2; return 0; }
  while IFS= read -r fr; do
    [[ -n "$fr" ]] || continue
    # 1. 상세를 발행 커밋에서 꺼낸다. 없으면 연결 정보가 없어 재실행 명령도 Issue 를 찾지 못한다 — 수동 조치를 안내한다.
    if ! git show "$pub:$fr" > "$det" 2>/dev/null; then
      _archive_issue_warn "$fr" "발행 커밋에서 FR 상세를 읽지 못했습니다"
      printf 'archive:   수동 조치: 발행 커밋에 이 FR 상세가 없어 연결된 Issue 를 알 수 없습니다. 상세 파일의 github-issue 를 확인해 Issue 를 직접 닫으십시오.\n' >&2
      continue
    fi
    # 4. 연결이 없으면 gh 를 부르지 않는다.
    gi="$(awk '/^- github-issue:/{sub(/^- github-issue:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit}' "$det" 2>/dev/null)" || gi=""
    [[ -n "$gi" && "$gi" != "-" ]] || continue
    # 2. 커밋 URL 은 연결된 FR 이 처음 나왔을 때 한 번 만든다. 실패하면 연결된 FR 마다 경고한다.
    if [[ "$url_tried" -eq 0 ]]; then
      url_tried=1
      url="$(bash "$_ARCHIVE_IQ" commit-url "$pub" --dir "$CURRENT_WT" 2>"$err" </dev/null)" || url=""
      if [[ -z "$url" ]]; then
        url_reason="$(awk 'NF{l=$0} END{print l}' "$err" 2>/dev/null)" || url_reason=""
        url_reason="커밋 URL 을 만들지 못했습니다${url_reason:+ — ${url_reason}}"
      fi
    fi
    if [[ -z "$url" ]]; then
      _archive_issue_warn "$fr" "$url_reason"
      # 재실행 줄은 사람·에이전트가 그대로 실행한다 — 파일에서 온 경로는 %q 로 인용한다(공백 분리·셸 메타문자 실행 방지).
      #   commit-url 의 명령 치환은 의도한 형태이고, 들어가는 OID 는 rev-parse 가 낸 16진수다.
      printf 'archive:   재실행: bash rd-workflow/scripts/issue_queue.sh close-fr %q --skip-closed --commit-url "$(bash rd-workflow/scripts/issue_queue.sh commit-url %s)"\n' "$fr" "$pub" >&2
      continue
    fi
    # 3. close-fr --skip-closed. 결과 줄로 닫음·건너뜀·남은 장부 행을 알린다. 일부 Issue 가 실패해도 성공한 Issue 의
    #   결과 줄은 나오므로 rc 와 상관없이 먼저 보인다.
    rc=0; left=""
    out="$(project_root="$CURRENT_WT" bash "$_ARCHIVE_IQ" close-fr "$det" --skip-closed --commit-url "$url" 2>"$err" </dev/null)" || rc=$?
    while IFS= read -r line; do
      case "$line" in
        "closed "*) printf 'archive: Issue 를 닫았습니다: %s\n' "${line#closed }" ;;
        "skipped-closed "*) printf 'archive: Issue 가 이미 닫혀 있어 건너뜁니다: %s\n' "${line#skipped-closed }" ;;
        # 호스트 없는 선점 행은 어느 호스트인지 확정할 수 없어 지우지 않았다 — 남은 사실과 원격을 건드리지 않는 정리 명령을 보인다.
        "kept-row "*) kr="${line#kept-row }"
          printf 'archive: 장부에 호스트 없는 선점 행 %s#%s 이 남았습니다 — 같은 Issue 면 bash rd-workflow/scripts/issue_queue.sh forget %s 로 장부 행만 지우십시오\n' "${kr% *}" "${kr##* }" "$kr" ;;
        # 원격 처리는 끝났고 장부 정리만 실패했다 — 경고 뒤에 Issue 마다 복사해 실행할 forget 줄을 낸다.
        "ledger-left "*) left="${left}${line#ledger-left }"$'\n' ;;
      esac
    done <<EOF_IQ
$out
EOF_IQ
    [[ "$rc" -eq 0 ]] && continue
    reason="$(awk 'NF{l=$0} END{print l}' "$err" 2>/dev/null)" || reason=""
    [[ -n "$reason" ]] || reason="close-fr 실패 (rc $rc)"
    # 닫기 실패는 댓글이 이미 달린 뒤다 — 재실행하면 댓글이 한 번 더 달린다.
    case "$reason" in "Issue 를 닫지 못했습니다"*) reason="$reason (댓글은 달렸습니다)" ;; esac
    _archive_issue_warn "$fr" "$reason"
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf 'archive:   장부 정리: bash rd-workflow/scripts/issue_queue.sh forget %s\n' "$line" >&2
    done <<EOF_LEFT
$left
EOF_LEFT
    # rc 10 은 원격 처리 뒤 장부 정리만 실패한 경우다 — 위 forget 줄이 복구이고, 상세를 다시 읽어 호스트를 다시 고르는
    #   close-fr 재실행은 안내하지 않는다.
    [[ "$rc" -eq 10 ]] && continue
    printf 'archive:   재실행: bash rd-workflow/scripts/issue_queue.sh close-fr %q --skip-closed --commit-url %q\n' "$fr" "$url" >&2
  done <<EOF_FRS
$ARCHIVE_ISSUE_FRS
EOF_FRS
  rm -f "$det" "$err"
  # 이 단계에 닿았으므로 고른 no-fr 기록을 지운다(실패한 FR 은 위 재실행 명령으로 안내했다).
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rm -f "$f"
  done <<EOF_RECS
$ARCHIVE_ISSUE_RECS
EOF_RECS
  return 0
}

# 직접 설치 PR 발행 분기 (change spec D3) — archive_publish=pr 이면 기본 브랜치를 건드리지 않고 fr 브랜치를 push 해 PR 을 올린 뒤 여기서 끝낸다.
# Step 3~9(merge·태그·기본 브랜치 push·worktree·fr 브랜치 정리)는 돌지 않는다. 게이트는 위에서 모두 지났다.
if [[ "$_ARCHIVE_DPR_MODE" == "pr" ]]; then
  _dpr_rc=0
  dpr_publish "$SLUG" "$FR_BRANCH" "$(get_default_branch)" || _dpr_rc=$?
  exit "$_dpr_rc"
fi

# Step 3 — merge (idempotent)
# no-fr 모드는 합칠 브랜치가 없습니다 — 작업 커밋이 이미 기본 브랜치 위에 있습니다 (§5.1).
if [[ "$BRANCH_MODE" == "no-fr" ]]; then
  printf 'archive: no-fr 모드 — merge 대상 브랜치가 없어 merge 를 건너뜁니다\n'
elif git merge-base --is-ancestor "$FR_BRANCH" HEAD 2>/dev/null; then
  printf 'archive: %s 이미 merge 됨 — skip\n' "$FR_BRANCH"
else
  # 병합 전 코드 충돌 사전 감지 (change spec D4) — 충돌이면 main 을 건드리기 전에 멈춘다.
  _pc_def="$(get_default_branch 2>/dev/null)" || _pc_def=""
  _pc_rc=0
  archive_conflict_precheck "$_pc_def" "$FR_BRANCH" "$CURRENT_WT" || _pc_rc=$?
  [[ "$_pc_rc" -ne 1 ]] || exit 1
  # submodule gitlink 누락 검사 (병합 전) — 작업 브랜치의 병합이 submodule 커밋을 빠뜨렸으면 main 을 바꾸지 않고 멈춘다.
  archive_gitlink_gate "$FR_BRANCH" HEAD pre || exit 1
  # git merge 출력은 변수에 잡아 둔다. 충돌이 자동 해소되면 git 의 「자동 병합이 실패했습니다」 가 거짓 실패로 읽히므로
  # 성공·멈춤 경로에서만 낸다. 해소 성공 경로는 내지 않는다. 대입 단독 실행은 set -e 로 종료하므로 if 조건에 둔다.
  _merge_out=""
  _merge_dump() { [[ -z "${_merge_out:-}" ]] || printf '%s\n' "$_merge_out" >&2; }
  if _merge_out="$(git merge --no-ff "$FR_BRANCH" -m "merge: $SLUG (archive)" 2>&1)"; then
    printf '%s\n' "$_merge_out"
  else
    # FUTURE_REQUESTS.md 단독 충돌은 행 집합 3-way 병합으로 해결한다 (spec D7).
    #   등록 커밋이 기본 브랜치에 먼저 쌓이는 구조에서 fr 브랜치와 기본 브랜치가 표 끝에 서로 다른 행을
    #   append 하면 git 줄 병합은 반드시 충돌한다. 인덱스는 제목을 키로 하는 행 집합이므로 집합 병합이 맞다.
    #   다른 경로가 함께 충돌하거나 집합 병합도 실패하면 종전대로 사람이 해결한다 (충돌 상태 유지).
    # 네 파일 경로는 RD_MERGE_AUTO_RESOLVE_PATHS(_merge_precheck.sh)와 같은 값이다 — 목록이 갈라지지 않게 거기서 꺼낸다.
    _CT="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 1p)"
    _SM="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 2p)"
    _IDX="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 3p)"
    # verify-evidence 는 모든 작업이 같은 경로에 쓰는 검증 증거다. seal 시점(rd_seal_evidence_check)에만 읽히고
    #   병합 뒤에는 아무도 읽지 않으므로, 발행 줄기가 seal 에 쓴 증거(stage 3)를 남긴다 (change spec 2026-11-02-0740 D1).
    _VE="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 4p)"
    # task-state 는 모든 작업이 같은 경로에 쓰는 진행 상태다. 병렬 발행에서 먼저 나간 줄기의 정리 커밋이 기본 브랜치의 값을
    #   기준 상태로 되돌리므로 늦은 줄기와 반드시 충돌한다. 발행 줄기 쪽(stage 3)을 남기면 Step 4 의 정리가 그 작업의
    #   상태(아카이브 보류 등)를 읽어 전이 행을 남긴 뒤 기준 상태로 되돌린다 (change spec 2026-11-17-1710 D1-2~D1-4).
    _TS="$(printf '%s\n' "$RD_MERGE_AUTO_RESOLVE_PATHS" | sed -n 5p)"
    # 조상·자손 gitlink 충돌을 자손 커밋으로 푼다 (change spec 2026-11-18-0900 D1-4). MERGE_HEAD 가 fr tip 이고 병합 기준이
    #   하나일 때만 들어간다 — 병합이 시작되지 않은 실패(예: --force-dirty 아래 staged 파일)는 MERGE_HEAD 가 없어 종전대로 멈춘다.
    #   남은 충돌 경로로 아래 기존 분기(인덱스 단독·다섯 파일·그 밖)를 그대로 고른다. 재실행 안내는 병합 커밋 뒤에 낸다.
    _glr_rc=0
    archive_gitlink_auto_resolve "$FR_BRANCH" || _glr_rc=$?
    _conf="$(git diff --name-only --diff-filter=U 2>/dev/null)"
    if [[ "$_glr_rc" -eq 0 && -z "$_conf" && "$ARCHIVE_GL_RESOLVED" -ge 1 ]]; then
      _nv=""; if lifecycle_needs_hook_bypass; then _nv="--no-verify"; fi
      RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit ${_nv:+"$_nv"} --no-edit -m "merge: $SLUG (archive)" >/dev/null || {
        printf 'archive: submodule 충돌은 해결했으나 merge 커밋이 실패했습니다. git status 로 확인한 뒤 git commit --no-edit 으로 merge 를 마치고 archive.sh 를 재실행하거나, git merge --abort 로 되돌리십시오\n' >&2
        _merge_dump; exit 1; }
      [[ -n "$_nv" ]] && lifecycle_notify_hook_bypass archive
      _archive_gl_print_notes
    elif [[ -n "$_conf" ]] && [[ -z "$(printf '%s\n' "$_conf" | grep -vxF -e "$_SM" -e "$_IDX" -e "$_CT" -e "$_VE" -e "$_TS")" ]]; then
      # 다섯 경로 안의 충돌은 경로마다 rd_merge_resolve_record(_merge_precheck.sh)로 푼다 (change spec 2026-11-19-1430 D2).
      #   규칙: stage_metrics.tsv = 줄 합집합 (change spec 2026-10-29-1800) / CURRENT_TASK.md = main 쪽(stage 2) —
      #   발행이 이 파일을 어차피 기준 상태로 되돌리므로 fr 쪽 내용은 버려도 잃는 것이 없다 (2026-10-30-1245 D1) /
      #   FUTURE_REQUESTS.md = 행 집합 병합 (spec D7) / verify-evidence·task-state = 발행 줄기 쪽(stage 3).
      #   작업 트리·인덱스는 임시 파일에서 병합·검증을 모두 마친 뒤에만 바꾼다 — 하나라도 실패하면 충돌 상태를 그대로 두고
      #   종전처럼 멈춘다. 그 밖의 파일이 섞인 충돌은 이 분기에 오지 않는다.
      _only_idx=0; [[ "$_conf" == "$_IDX" ]] && _only_idx=1
      _rb=""; _ro=""; _rt=""; _rp=(); _rf=()
      _sm_stop() {  # _sm_stop [사유] — 임시 파일을 지우고 충돌 상태를 둔 채 중단한다
        rm -f "$_rb" "$_ro" "$_rt" ${_rf[@]+"${_rf[@]}"}
        if (( _only_idx )); then
          # 인덱스 단독 충돌은 종전 출력을 그대로 유지한다: 임시 파일 실패는 해당 줄만, 반영 실패는 한 줄만,
          #   병합·stage 추출 실패는 인덱스 전용 두 줄.
          case "${1:-}" in
            "") ;;
            *"병합 결과 반영 실패"*) printf 'archive: %s\n' "$1" >&2 ;;
            *) printf 'archive: merge 실패 — FUTURE_REQUESTS.md 행 집합 병합도 실패했습니다. conflict resolve 후 재실행\n' >&2; printf 'archive:   main 에서 직접 풀지 말고 git merge --abort 후 작업 worktree 에서 처리하십시오\n' >&2 ;;
          esac
          _merge_dump; exit 1
        fi
        [[ -n "${1:-}" ]] && printf 'archive: %s\n' "$1" >&2
        printf 'archive: merge 실패 — conflict resolve 후 재실행\n' >&2; printf 'archive:   main 에서 직접 풀지 말고 git merge --abort 후 작업 worktree 에서 main 을 병합해 처리하십시오(리뷰한 코드와 다른 결과는 다시 리뷰해야 발행할 수 있습니다)\n' >&2; _merge_dump; exit 1
      }
      _sm_tmp() {  # 가드된 임시 파일 경로를 stdout 으로 낸다
        local _t
        _t="$(mktemp)" || { echo "archive: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
        [[ -n "$_t" && -f "$_t" ]] || { echo "archive: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
        printf '%s' "$_t"
      }
      _sm_stage() {  # _sm_stage <stage> <경로> <임시 파일> — 그 stage 가 있으면 파일에 꺼내 경로를 _stage_arg 에, 없으면 빈 값
        _stage_arg=""
        git ls-files -u -- "$2" | awk '{print $3}' | grep -qx "$1" || return 0
        git show ":$1:$2" > "$3" 2>/dev/null || _sm_stop "stage 추출 실패: $2"
        _stage_arg="$3"
      }
      _rb="$(_sm_tmp)" || _sm_stop; _ro="$(_sm_tmp)" || _sm_stop; _rt="$(_sm_tmp)" || _sm_stop
      # 검사 순서는 종전과 같다: CURRENT_TASK.md → verify-evidence → task-state → stage_metrics.tsv → 인덱스.
      for _p in "$_CT" "$_VE" "$_TS" "$_SM" "$_IDX"; do
        printf '%s\n' "$_conf" | grep -qxF -e "$_p" || continue
        _res="$(_sm_tmp)" || _sm_stop
        _rp+=("$_p"); _rf+=("$_res")
        _sm_stage 1 "$_p" "$_rb"; _a1="$_stage_arg"
        _sm_stage 2 "$_p" "$_ro"; _a2="$_stage_arg"
        _sm_stage 3 "$_p" "$_rt"; _a3="$_stage_arg"
        RD_MERGE_RESOLVE_QUIET=1 rd_merge_resolve_record "$_p" "$_a1" "$_a2" "$_a3" "$_res" \
          || _sm_stop "$RD_MERGE_RESOLVE_WHY"
      done
      # 결과 반영 순서는 종전과 같다: stage_metrics.tsv → CURRENT_TASK.md → verify-evidence → task-state → 인덱스.
      for _p in "$_SM" "$_CT" "$_VE" "$_TS" "$_IDX"; do
        _i=0; _hit=-1
        while (( _i < ${#_rp[@]} )); do [[ "${_rp[$_i]}" == "$_p" ]] && _hit=$_i; _i=$((_i + 1)); done
        (( _hit >= 0 )) || continue
        case "$_p" in
          "$_SM") _lbl="stage_metrics.tsv" ;; "$_CT") _lbl="CURRENT_TASK.md" ;; "$_VE") _lbl="verify-evidence" ;;
          "$_TS") _lbl="task-state" ;; *) _lbl="인덱스" ;;
        esac
        cp "${_rf[$_hit]}" "$_p" && git add "$_p" \
          || _sm_stop "$_lbl 병합 결과 반영 실패 — git status 로 확인 후 수동 resolve 하고 git commit --no-edit, 또는 git merge --abort"
      done
      _nv=""; if lifecycle_needs_hook_bypass; then _nv="--no-verify"; fi
      if (( _only_idx )); then
        RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit ${_nv:+"$_nv"} --no-edit -m "merge: $SLUG (archive)" >/dev/null \
          || { rm -f "$_rb" "$_ro" "$_rt" ${_rf[@]+"${_rf[@]}"}; printf 'archive: 인덱스 충돌은 해결했으나 merge 커밋이 실패했습니다. git status 로 확인한 뒤 git commit --no-edit 으로 merge 를 마치고 archive.sh 를 재실행하거나, git merge --abort 로 되돌리십시오\n' >&2; _merge_dump; exit 1; }
      else
        RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit ${_nv:+"$_nv"} --no-edit -m "merge: $SLUG (archive)" >/dev/null \
          || _sm_stop "충돌은 해결했으나 merge 커밋이 실패했습니다. git status 로 확인한 뒤 git commit --no-edit 으로 merge 를 마치고 archive.sh 를 재실행하거나, git merge --abort 로 되돌리십시오"
      fi
      [[ -n "$_nv" ]] && lifecycle_notify_hook_bypass archive
      for _p in "$_SM" "$_CT" "$_IDX" "$_VE" "$_TS"; do
        printf '%s\n' "$_conf" | grep -qxF -e "$_p" || continue
        case "$_p" in
          "$_SM") printf 'archive: stage_metrics.tsv 충돌을 줄 합집합으로 해결했습니다 (git merge-file --union)\n' ;;
          "$_CT") printf 'archive: CURRENT_TASK.md 충돌을 main 쪽으로 해결했습니다 (발행이 이 파일을 기준 상태로 되돌립니다)\n' ;;
          "$_IDX") printf 'archive: FUTURE_REQUESTS.md 충돌을 행 집합 병합으로 해결했습니다 (merge_fr_index.sh)\n' ;;
          "$_VE") printf 'archive: verify-evidence 충돌을 발행 줄기 쪽으로 해결했습니다 (seal 에 쓴 증거를 남깁니다)\n' ;;
          "$_TS") printf 'archive: task-state 충돌을 발행 줄기 쪽으로 해결했습니다 (정리 단계가 기준 상태로 되돌립니다)\n' ;;
        esac
      done
      _archive_gl_print_notes
      rm -f "$_rb" "$_ro" "$_rt" ${_rf[@]+"${_rf[@]}"}
    else
      printf 'archive: merge 실패 — conflict resolve 후 재실행\n' >&2; printf 'archive:   main 에서 직접 풀지 말고 git merge --abort 후 작업 worktree 에서 main 을 병합해 처리하십시오(리뷰한 코드와 다른 결과는 다시 리뷰해야 발행할 수 있습니다)\n' >&2; _merge_dump; exit 1
    fi
  fi
  # 여기까지 왔으면 이번 실행이 병합했다(자동 병합 성공 또는 자동 해소 성공 — 실패 분기는 모두 exit 1).
  ARCHIVE_MERGED_THIS_RUN=1
fi

# 순서 불변식: 판정 base 는 반드시 merge 완료 "이후" 에 캡처한다.
# Step 4 의 metadata cleanup commit 이 HEAD 를 전진시키므로 Step 8 시점의 HEAD 는 base 로 부적합하다
# (그 HEAD 를 쓰면 merge 가 실제로 수행되지 않은 상황에서도 판정이 참이 될 여지가 생긴다).
# core 실패이므로 원 명령의 종료 상태를 그대로 전달한다 (특정 값으로 정규화하지 않는다).
MERGE_BASE_COMMIT="$(git rev-parse HEAD)" || {
  _mb_rc=$?
  printf 'archive: merge 대상 commit 결정 실패 (rc=%s) — 중단\n' "$_mb_rc" >&2
  exit "$_mb_rc"
}

# Step 3.6 — 기준선 이후 얹힌 커밋 검사 (빠른 실패)
#
# 재실행 경로의 구멍을 막는다: merge 직후 중단된 뒤 기본 브랜치를 직접 고쳐 재실행하면 review 종결성 검사가 예전 fr tip
# 세션만 보고 통과해(_guard_common.sh 의 fr_ref 조회) 리뷰되지 않은 커밋이 발행된다.
#
# **이 판정은 근사다.** 커밋의 출처를 구분하지 못하므로 최종 판단은 Step 4.5 의 내용
# 검증이 내린다. 여기 두는 이유는 빠른 실패다.
#
# **이 검사군(3.6·4.5)은 fr 모드 전용입니다.** 기준선의 정의가 "fr tip 을 들여온 merge"
# 이므로 no-fr 에는 대응물이 없습니다. base-commit 을 기준선으로 대신 쓸 수도 없습니다 —
# no-fr 에서 base-commit..HEAD 사이 커밋은 정리 대상이 아니라 **작업 그 자체**여서,
# 허용 경로 밖 변경으로 판정되어 정상 아카이브를 통째로 막습니다.
# no-fr 에서 "리뷰된 대상이 그대로 발행되는가" 는 seal 의 보호 트리 해시 비교가
# 담당합니다 (§2·§3.3.1 — archive_review_precheck 가 이미 위에서 돌았습니다).
BASELINE_OID=""
_bl_rc=0
if [[ "$BRANCH_MODE" == "fr" ]]; then
  BASELINE_OID="$(archive_baseline_commit "$CURRENT_WT" "$FR_BRANCH" "$MERGE_BASE_COMMIT")" || _bl_rc=$?
else
  printf 'archive: no-fr 모드 — 기준선 기반 얹힌 커밋 검사를 건너뜁니다 (리뷰 대상 동일성은 seal 이 보증합니다)\n'
fi
if [[ "$_bl_rc" -eq 2 ]]; then
  printf 'archive: 기준선 판정에 필요한 git 명령이 실패했습니다 — 무엇이 얹혔는지 알 수 없어 중단합니다\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
elif [[ "$_bl_rc" -ne 0 ]]; then
  printf 'archive: %s 를 부모로 갖는 merge 를 찾지 못했고, first-parent 이력에도 없습니다\n' "$FR_BRANCH" >&2
  printf 'archive:   기대하지 않은 커밋 그래프라 무엇이 발행될지 판정할 수 없습니다 — 중단합니다\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
fi

_ec_rc=0
if [[ "$BRANCH_MODE" == "fr" ]]; then
  archive_extra_commits_check "$CURRENT_WT" "$BASELINE_OID" "$MERGE_BASE_COMMIT" || _ec_rc=$?
fi
if [[ "$_ec_rc" -eq 2 ]]; then
  printf 'archive: 얹힌 커밋 판정에 필요한 git 명령이 실패했습니다 — 중단합니다\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
elif [[ "$_ec_rc" -ne 0 ]]; then
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT"
  exit 1
fi

# Step 3.6b — 손으로 푼 병합 커밋 거부 (change spec D5)
# 이번 실행이 직접 병합했으면 검사하지 않는다. 이미 병합돼 있던 경우(재실행)에 한해, 기준선이 fast-forward 가 아닌 병합 커밋 M 이면
# M 이 자동 병합 결과(M^1 + M^2)와 같은지 본다. fast-forward 기준선(= fr tip)이면 병합 커밋이 없어 대상이 아니다.
if [[ "$BRANCH_MODE" == "fr" && "$ARCHIVE_MERGED_THIS_RUN" -eq 0 && -n "$BASELINE_OID" \
      && "$BASELINE_OID" != "$(git rev-parse "$FR_BRANCH" 2>/dev/null)" ]]; then
  _mc_rc=0
  _mc_paths="$(archive_merge_commit_check "$BASELINE_OID")" || _mc_rc=$?
  if [[ "$_mc_rc" -eq 1 ]]; then
    _mc_short="$(git rev-parse --short "$BASELINE_OID" 2>/dev/null)" || _mc_short="$BASELINE_OID"
    _mc_p1="$(git rev-parse "${BASELINE_OID}^1" 2>/dev/null)" || _mc_p1="<M^1 OID>"
    printf 'archive: main 의 병합 커밋 %s 에 리뷰하지 않은 변경이 있습니다 — 발행하지 않습니다.\n' "$_mc_short" >&2
    printf 'archive:   자동 병합 결과와 다른 경로:\n' >&2
    while IFS= read -r _mc_p; do
      [[ -n "$_mc_p" ]] && printf 'archive:     - %s\n' "$_mc_p" >&2
    done <<EOF
$_mc_paths
EOF
    printf 'archive:   이 병합은 archive.sh 가 아니라 손으로 만든 것으로 보입니다. 리뷰한 코드만 발행하려면:\n' >&2
    printf 'archive:     1. 기본 체크아웃에서 손 병합을 되돌립니다: git reset --keep %s\n' "$_mc_p1" >&2
    printf 'archive:        (먼저 git log --oneline %s..HEAD 로 되돌릴 커밋이 이 병합과 archive 정리 커밋뿐인지 확인하십시오)\n' "$_mc_p1" >&2
    printf 'archive:     2. 이후는 충돌 감지 때와 같습니다 — 작업 worktree 에서 main 병합·해결 → 검증 → 새 final diff review → seal → 다시 발행\n' >&2
    exit 1
  elif [[ "$_mc_rc" -ne 0 ]]; then
    printf 'archive: main 의 병합 커밋 %s 가 자동 병합 결과와 같은지 확인할 수 없습니다(git 2.38 이상이 필요하거나 저장소 상태를 읽을 수 없음) — 발행하지 않습니다.\n' "$(git rev-parse --short "$BASELINE_OID" 2>/dev/null || printf '%s' "$BASELINE_OID")" >&2
    _mc_p1="$(git rev-parse "${BASELINE_OID}^1" 2>/dev/null)" || _mc_p1="<M^1 OID>"
    printf 'archive:   git --version 이 2.38 이상인지 확인하십시오. 이 병합을 손으로 만들었다면 리뷰한 코드만 발행하려면:\n' >&2
    printf 'archive:     1. 기본 체크아웃에서 손 병합을 되돌립니다: git reset --keep %s\n' "$_mc_p1" >&2
    printf 'archive:        (먼저 git log --oneline %s..HEAD 로 되돌릴 커밋이 이 병합과 archive 정리 커밋뿐인지 확인하십시오)\n' "$_mc_p1" >&2
    printf 'archive:     2. 이후는 충돌 감지 때와 같습니다 — 작업 worktree 에서 main 병합·해결 → 검증 → 새 final diff review → seal → 다시 발행\n' >&2
    exit 1
  fi
fi

# submodule gitlink 누락 검사 (병합 후) — 재실행으로 이미 병합된 경우와 archive 의 병합 자신을 본다.
# 기준선이 fr tip 을 둘째 부모로 가진 병합이면 병합 전 기본 브랜치(기준선^1)를, 아니면(fast-forward 폴백) 기준선을 제외한다.
if [[ "$BRANCH_MODE" == "fr" ]]; then
  _gl_excl="$BASELINE_OID"
  if [[ "$(git rev-parse --verify --quiet "${BASELINE_OID}^2" 2>/dev/null)" == "$(git rev-parse "$FR_BRANCH" 2>/dev/null)" ]]; then
    _gl_excl="${BASELINE_OID}^1"
  fi
  archive_gitlink_gate "$MERGE_BASE_COMMIT" "$_gl_excl" post || exit 1
fi

# Step 3.5 (제거, 2026-09-03) — 이 자리에서 self_test consumer 전수를 강제하고 증명을 대조하던
# 게이트를 걷어냈다. 검증은 구현 직후 사람이 self_test.sh (그룹 지정) 로 돌리고 final diff review 가
# 그 결과를 확인한다. 아카이브가 같은 검증을 다시 돌려 얻는 것은 없었고 매번 15~20분을 썼다.

# Step 4 — metadata cleanup commit on main (publish 전)
#
# no-fr 모드에서는 `metadata_exists` 가 거짓입니다 (fr-branch 가 canonical `null` 이므로).
# 그런데 이 블록은 fr 필드 정리만 하는 것이 아니라 **작업 상태 전체를 baseline 으로
# 되돌리는 자리**입니다 (status·short-title·base-commit·review-session·CURRENT_TASK.md).
# 조건을 그대로 두면 no-fr 작업이 끝난 뒤에도 완료된 작업이 진행 중으로 남아, 다음 세션이
# 끝난 일을 남은 일로 안내받습니다. 그래서 no-fr 을 명시적으로 함께 태웁니다 (§5.1 "유지").
if metadata_exists || [[ "$BRANCH_MODE" == "no-fr" ]]; then
  # LC-14 대칭: archive 완료 시 미러(CURRENT_TASK.md)와 권위(task-state)를 함께 baseline 으로
  # 되돌린다 (promote_rollback.sh:82,98 과 동일 패턴). 권위만 되돌리면 완료된 작업 내용이
  # 진입점 문서에 남아 다음 세션이 끝난 일을 남은 일로 안내받는다.
  #
  # 순서 불변식: 미러를 먼저 확정하고 metadata 를 나중에 정리한다.
  #   metadata_clear 를 먼저 하면 미러 단계 실패 시 metadata_exists 가 거짓이 되어
  #   재실행이 이 블록을 통째로 건너뛰고 손상된 미러가 영구히 남는다.
  #
  # 쓰기 방식: 임시 파일 → 검증 → mv 교체. `> CURRENT_TASK.md` 로 직접 쓰면 리다이렉션이
  #   대상을 먼저 비우므로 생성 실패 시 빈 미러가 남는다.
  #
  # 실패 처리는 즉시 중단이다. cleanup_add 는 쓰지 않는다 — 정의가 이 지점보다 뒤(186행)라
  #   호출하면 command not found 다. core 실패 전달 방식은 111-118행 선례를 따른다.
  _ct_path="$CURRENT_WT/CURRENT_TASK.md"
  _ct_tmp="${_ct_path}.baseline.tmp"
  if ! emit_current_task_baseline > "$_ct_tmp" 2>/dev/null; then
    rm -f "$_ct_tmp"
    printf 'archive: CURRENT_TASK.md baseline 생성 실패 — 중단 (기존 미러 보존)\n' >&2
    exit 1
  fi
  if ! grep -q '^대기 중$' "$_ct_tmp"; then
    rm -f "$_ct_tmp"
    printf 'archive: CURRENT_TASK.md baseline 검증 실패 — 중단 (기존 미러 보존)\n' >&2
    exit 1
  fi
  if ! mv "$_ct_tmp" "$_ct_path"; then
    rm -f "$_ct_tmp"
    printf 'archive: CURRENT_TASK.md 교체 실패 — 중단 (기존 미러 보존)\n' >&2
    exit 1
  fi

  # 미러가 확정된 뒤에 권위를 정리한다 (위 순서 불변식).
  _ARCHIVE_FROM_STATUS="$(state_read_field "status")"
  # no-fr 의 Issue 닫기 보류 기록 (change spec 2026-11-17-1710 D4-2). metadata_clear 가 source-fr 를 지우기 직전에
  #   이 작업 커밋(HEAD)의 OID 를 이름으로 목록을 남긴다. fr 모드는 fr tip 의 task-state 에서 읽으므로 쓰지 않는다.
  #   로컬 전용 모드는 Issue 닫기 단계를 건너뛰므로 쓰지 않는다 — 쓰면 지워지지 않고 남아 다음 원격 발행이 조상으로 골라
  #   이 작업의 Issue 를 엉뚱한 반영 커밋으로 닫는다(fr 모드도 로컬 전용 발행의 Issue 는 닫지 않는다).
  if [[ "$BRANCH_MODE" == "no-fr" && "$REMOTE_MODE" == "remote" ]]; then
    _air_rc=0; archive_issue_record_write || _air_rc=$?
  fi
  metadata_clear
  state_write_fields "short-title=-" "status=대기 중"
  # 종료되는 회차($SLUG, 아직 '-'로 바뀌기 전 값)에 귀속시킨다(change-spec D4-3, D1).
  # archive.sh 는 이미 cd "$PUBLISH_WT" 이후 _state_common.sh 를 source 했으므로
  # TASK_STATE_PATH 는 이 시점에 PUBLISH_WT 를 가리킨다(별도 전환 불필요, :92,174 참조 —
  # Task 4 의 실제 archive 스모크에서 커밋 위치를 git show 로 재확인한다).
  state_log_stage_transition "$SLUG" "$_ARCHIVE_FROM_STATUS" "대기 중"

  # 이 커밋에 포함할 경로 — staging·판정·커밋이 **모두** 이 목록에서 나온다.
  # 단일 출처는 lifecycle_metadata_paths() 이고 얹힌 커밋 검사·발행 내용 검증도 같은
  # 함수를 소비한다. 여기서 직접 나열하면 두 벌이 되어 조용히 갈라진다.
  #
  # legacy active-fr 은 **tracked 일 때만** 포함한다 — 삭제분 staging 이 목적이라
  # 존재 여부가 조건인 유일한 항목이다. 목록에서 빼지 않고 여기서 걸러야
  # "목록에 있는 경로는 전부 다뤄진다" 는 계약이 유지된다.
  #
  # **목록을 먼저 캡처하고 helper 의 rc 를 따로 본다.** heredoc 안 명령 치환은 그 함수의
  # 종료 코드를 소거하므로 "일부 출력 후 실패" 가 정상 목록으로 취급된다 — 축소된 목록으로
  # staging·커밋을 진행하면 남은 경로가 조용히 빠진다.
  _lc_paths_out="$(lifecycle_metadata_paths)" && _lc_paths_rc=0 || _lc_paths_rc=$?
  if [[ "$_lc_paths_rc" -ne 0 ]]; then
    printf 'archive: 허용 경로 목록 생성 실패 (lifecycle_metadata_paths rc %s) — 중단\n' "$_lc_paths_rc" >&2
    exit 1
  fi
  _lc_paths=()
  while IFS= read -r _lc_rel; do
    [[ -n "$_lc_rel" ]] || continue
    case "$_lc_rel" in
      */active-fr)
        git ls-files --error-unmatch "$CURRENT_WT/$_lc_rel" >/dev/null 2>&1 || continue
        ;;
      */stage_metrics.tsv)
        # best-effort 로그다 — 이 회차에서 로그가 한 번도 안 남았으면(최초 회차에서
        # append 자체가 실패했거나, from==to 라 기록할 전이가 없었던 경우) 파일이
        # 없을 수 있다. 존재하지 않는 pathspec 을 git add 에 넘기면 실패해 archive
        # 전체가 중단된다 — 존재할 때만 포함한다.
        [[ -f "$CURRENT_WT/$_lc_rel" ]] || continue
        ;;
    esac
    _lc_paths+=( "$CURRENT_WT/$_lc_rel" )
  done <<EOF
$_lc_paths_out
EOF
  # 팀 저장소 PR 기록(rd pr)은 이 작업의 것이므로 task-state 와 함께 지운다 — 다음 작업이 이전 PR 기록을 물려받지 않게 한다
  # (change spec D4). 목록(lifecycle_metadata_paths)에 두지 않고 여기서만 다룬다: 없는 작업이 대부분이라 존재할 때만 포함한다.
  _tp_rec="$CURRENT_WT/$RD_TEAM_PR_RECORD"
  if [[ -e "$_tp_rec" ]] || git ls-files --error-unmatch "$_tp_rec" >/dev/null 2>&1; then
    if git ls-files --error-unmatch "$_tp_rec" >/dev/null 2>&1; then
      _lc_paths+=( "$_tp_rec" )
    fi
    if ! rm -f "$_tp_rec"; then
      printf 'archive: PR 기록 파일 삭제 실패 (%s) — 중단\n' "$_tp_rec" >&2
      exit 1
    fi
  fi
  # staging 대상도 _lc_paths 다 — 목록에 항목이 늘면 staging 도 함께 늘어야 한다.
  if ! git add "${_lc_paths[@]}"; then
    printf 'archive: lifecycle metadata staging 실패 — 중단\n' >&2
    exit 1
  fi
  # index 에 올라간 CURRENT_TASK.md 의 "내용" 이 방금 만든 baseline 과 같은지 확인한다.
  #   staged diff 에 경로가 나타나는지로 판정하면 안 된다 — fr branch 의 archive content
  #   commit 이 이미 미러를 baseline 으로 만들어 둔 경우 merge 후 다시 써도 HEAD 와 동일해
  #   staged 변경이 없고, 정상 상태가 실패로 오판된다(그때 merge 는 이미 끝나 있어 사용자가
  #   수동 복구를 해야 한다). 확인해야 하는 것은 변경 여부가 아니라
  #   "커밋될 내용이 올바른 baseline 인가" 다.
  if ! git show ":CURRENT_TASK.md" 2>/dev/null | diff -q - "$_ct_path" >/dev/null 2>&1; then
    printf 'archive: index 의 CURRENT_TASK.md 가 baseline 과 불일치 — 중단\n' >&2
    exit 1
  fi
  # 판정을 경로로 좁힌다 — index 전체를 보면 사용자의 무관한 staged 변경만으로도
  # 커밋이 진행되어 lifecycle 커밋에 제품 코드가 담긴다
  if ! git diff --cached --quiet -- "${_lc_paths[@]}" 2>/dev/null; then
    # --no-verify + RD_LIFECYCLE_BYPASS_REASON 병기 (서로 다른 hook 계층).
    # --no-verify 는 hook 이 실제로 차단하는 브랜치(main|master)에서만 붙인다 —
    # RD_LIFECYCLE_BYPASS_REASON 은 별개 계층이라 브랜치와 무관하게 항상 유지한다.
    _nv=""
    if lifecycle_needs_hook_bypass; then _nv="--no-verify"; fi
    RD_LIFECYCLE_BYPASS_REASON=lifecycle git commit ${_nv:+"$_nv"} \
      -m "chore(lifecycle): archive $SLUG metadata 정리" -- "${_lc_paths[@]}"
    if [[ -n "$_nv" ]]; then lifecycle_notify_hook_bypass archive; fi
    printf 'archive: metadata cleanup commit 완료\n'
  fi
fi

# Step 4.5 — 발행 후보 확정과 내용 검증
#
# **여기서 캡처한 OID 가 발행 대상이다.** 이후 tag 와 push 는 HEAD 나 브랜치 tip 을
# 다시 해석하지 않고 이 값을 소비한다. "다시 검사" 가 아니라 **"검사한 객체를 발행"**
# 이어야 검사와 발행 사이의 경쟁 창이 닫힌다.
PUBLISH_OID="$(git rev-parse HEAD)" || {
  printf 'archive: 발행 후보 commit 결정 실패 — 중단\n' >&2
  # archive_block_notice 의 복구 절차는 "fr 브랜치에서 다시 만들라" 를 전제하므로
  # no-fr 에서는 성립하지 않습니다. 사유는 위 한 줄로 이미 나갔습니다.
  if [[ "$BRANCH_MODE" == "fr" ]]; then
    archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  fi
  exit 1
}

# 경로 판정을 발행 후보 기준으로 다시 한 번. merge 이후 기본 브랜치가
# 전진했을 수 있고, Step 4 의 metadata 커밋도 이 시점에는 얹힌 커밋에 포함된다
# (허용 경로만 담으므로 자연히 통과한다).
_ec2_rc=0
if [[ "$BRANCH_MODE" == "fr" ]]; then
  archive_extra_commits_check "$CURRENT_WT" "$BASELINE_OID" "$PUBLISH_OID" || _ec2_rc=$?
fi
if [[ "$_ec2_rc" -eq 2 ]]; then
  printf 'archive: 발행 전 얹힌 커밋 판정에 필요한 git 명령이 실패했습니다 — 중단합니다\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
elif [[ "$_ec2_rc" -ne 0 ]]; then
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT"
  exit 1
fi

# 최종 판단 — 허용 경로 파일의 **내용**이 실제로 baseline 인가.
# 경로 판정만으로는 사람이 만든 metadata-only 커밋의 내용이 남는 것을 막지 못한다.
_pc_rc=0
if [[ "$BRANCH_MODE" == "fr" ]]; then
  archive_publish_content_check "$CURRENT_WT" "$BASELINE_OID" "$PUBLISH_OID" || _pc_rc=$?
fi
if [[ "$_pc_rc" -eq 2 ]]; then
  # rc 2 는 git 실행 오류와 **허용 경로 목록 생성 실패**를 함께 담는다 — 둘 다 "검사
  # 자체가 불가능" 이며, 파일 내용을 되돌려서 해결되는 상태가 아니다. 그래서 사유를
  # git 오류로 단정하지 않는다.
  printf 'archive: 발행 내용을 판정할 수 없습니다 (git 실행 오류 또는 허용 경로 목록 생성 실패) — 중단합니다\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
elif [[ "$_pc_rc" -ne 0 ]]; then
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" content
  exit 1
fi

# Step 4.6 — 발행 직전 재결속 (no-fr 전용)
#
# precheck(`archive_review_precheck`) 는 **cleanup commit 이전의 commit** 을 봅니다. 그 뒤
# metadata cleanup commit 이 붙고 `PUBLISH_OID` 가 확정되는데, 그 사이에 다른 프로세스나
# hook 이 보호 경로 변경 커밋으로 HEAD 를 전진시키면 cleanup commit 이 그 커밋을 부모로
# 삼거나 `PUBLISH_OID` 가 그 커밋을 가리킵니다. tag/push 는 OID 에 잘 결속되어 있지만
# **그 OID 자체가 리뷰되지 않은 코드를 담게 됩니다.** 그래서 precheck 가 승인한 보호 트리
# 해시를 실제 발행 대상의 해시와 여기서 한 번 더 대조합니다.
#
# **fr 모드는 대상이 아닙니다.** fr 의 발행 트리는 fr tip 의 트리와 원래 같지 않습니다
# (기본 브랜치에 정당하게 먼저 들어온 다른 작업이 merge 로 합쳐집니다). 같은 대조를 걸면
# 정상 아카이브가 통째로 막힙니다. fr 에서 이 창을 닫는 것은 위 Step 4.5 의
# `archive_extra_commits_check`·`archive_publish_content_check` 이며, 둘 다
# `BASELINE_OID..PUBLISH_OID`(= merge 이후 전진분 전체) 를 보므로 precheck 이후에 얹힌
# 커밋을 이미 잡습니다. 여기 중복해서 넣지 않습니다.
#
# 우회(`--force-skip-review-check`) 로 통과한 경우에는 승인된 해시 자체가 없습니다. 대조할
# 기준이 없어 건너뛰되 무엇을 확인하지 못했는지 알립니다 — 우회 사실 자체는 precheck 가
# 이미 audit log 와 경고로 남겼습니다.
if [[ "$BRANCH_MODE" == "no-fr" ]]; then
  if [[ -z "${RD_ARCHIVE_REVIEWED_TREE_HASH:-}" ]]; then
    printf 'archive: WARNING — 승인된 보호 트리 해시가 없어 발행 대상 재대조를 건너뜁니다 (review 검증 우회)\n' >&2
  else
    _rb_rc=0
    # 셋째 인자: 리뷰 검사가 승인한 정리 전 커밋(change spec 2026-11-18-0900 D3-3). 해시는 그 커밋의 PR 기록으로 센다 —
    #   Step 4 정리 커밋이 PR 기록을 지우므로 발행 대상에서 다시 읽으면 PR merge 로 옮긴 포인터가 merged 커밋 내용으로 세어진다.
    #   HEAD 를 다시 읽지 않는다. 승인 해시가 있는데 이 값이 비면 판정 불가로 멈춘다(함수 안 검사).
    archive_publish_rebind_check "$RD_ARCHIVE_REVIEWED_TREE_HASH" "$PUBLISH_OID" "$RD_ARCHIVE_REVIEWED_OID" || _rb_rc=$?
    if [[ "$_rb_rc" -ne 0 ]]; then
      printf 'archive:   미검토 코드를 발행하지 않기 위해 tag/push 전에 중단합니다.\n' >&2
      printf 'archive:   git log 로 늘어난 커밋을 확인해 되돌리거나, 재리뷰(prepare_review_pipeline.sh diff → rd review seal) 후 다시 실행하십시오.\n' >&2
      exit 1
    fi
  fi
fi

# Step 5 — Tag (HEAD = cleanup commit, rerun reuse)
TARGET_TAG="$(git tag --list "fr/*/$SLUG" --points-at "$PUBLISH_OID" 2>/dev/null | head -1)"
if [[ -z "$TARGET_TAG" ]]; then
  TS="$(date +%Y-%m-%d-%H%M)"
  TARGET_TAG="$(resolve_unique_ref tag "fr/$TS/$SLUG")" || {
    printf 'archive: tag ref 생성 실패 (%s, TS=%s)\n' "$SLUG" "$TS" >&2; exit 1
  }
fi

if git rev-parse --verify "refs/tags/$TARGET_TAG" >/dev/null 2>&1; then
  EXISTING="$(git rev-parse "refs/tags/$TARGET_TAG^{commit}")"
  HEAD_REV="$PUBLISH_OID"
  [[ "$EXISTING" == "$HEAD_REV" ]] || {
    printf 'archive: tag %s 충돌 (다른 commit) — 수동 해결 후 재실행: git tag -d %s\n' "$TARGET_TAG" "$TARGET_TAG" >&2
    exit 1
  }
  printf 'archive: tag %s 이미 존재 (HEAD 가리킴) — skip\n' "$TARGET_TAG"
else
  git tag "$TARGET_TAG" "$PUBLISH_OID" -m "archive: $SLUG @ $(date +"%Y-%m-%d %H:%M")"
  printf 'archive: tag %s 부착 (cleanup commit 가리킴)\n' "$TARGET_TAG"
fi

# 생성·재사용 **직후** tag object OID 를 고정하고, 그 객체가 실제로 $PUBLISH_OID 를
# 가리키는지 다시 확인한다. 이후 tag 발행은 이 불변 OID 만 소비한다.
#
# **ref 이름(`git push origin "$TARGET_TAG"`)으로 발행하면 안 된다.** 그 형태는 push
# 실행 시점의 로컬 tag ref 를 다시 해석하므로, 위 검증 이후 다른 프로세스가 tag 를
# force-move 하면 기본 브랜치는 $PUBLISH_OID 로 안전하게 나가도 **원격 tag 만 미검증
# 커밋을 가리킨다.** 기본 브랜치 push 와 같은 이유(검사한 객체를 발행)이며, tag 쪽에도
# 같은 결속이 있어야 check→publish 경쟁 창이 닫힌다.
TAG_OID="$(git rev-parse --verify --quiet "refs/tags/$TARGET_TAG")" || {
  printf 'archive: tag %s 의 OID 를 읽지 못했습니다 — 수동 해결 후 재실행: git tag -d %s\n' "$TARGET_TAG" "$TARGET_TAG" >&2
  exit 1
}
TAG_COMMIT="$(git rev-parse --verify --quiet "${TAG_OID}^{commit}")" || {
  printf 'archive: tag %s 가 커밋을 가리키지 않습니다 — 수동 해결 후 재실행: git tag -d %s\n' "$TARGET_TAG" "$TARGET_TAG" >&2
  exit 1
}
[[ "$TAG_COMMIT" == "$PUBLISH_OID" ]] || {
  printf 'archive: tag %s 가 발행 대상이 아닌 커밋을 가리킵니다 (%s != %s) — 수동 해결 후 재실행: git tag -d %s\n' \
    "$TARGET_TAG" "${TAG_COMMIT:0:8}" "${PUBLISH_OID:0:8}" "$TARGET_TAG" >&2
  exit 1
}

# Issue 닫기 대상 확정 — push 전에 한 번 (change spec 2026-11-17-1710 D4-2). push 뒤에는 이 목록만 쓴다.
_ais_rc=0; archive_issue_source_frs "$PUBLISH_OID" || _ais_rc=$?

# Step 6 — Remote publish (blocking)
#
# **검증된 OID 를 명시적으로 push 한다.** `git push origin <branch>` 는 실행 시점의
# 로컬 tip 을 해석하므로, 검사 이후 전진한 미검증 커밋이 함께 나간다.
# `${PUBLISH_OID}` 의 중괄호는 refspec 문자열에서 변수 경계를 명확히 하기 위한 것이다.
if [[ "$REMOTE_MODE" == "remote" ]]; then
  DEFAULT_BRANCH="$(get_default_branch)" || { printf 'archive: 기본 브랜치 결정 실패 — push 중단\n' >&2; exit 1; }

  # push 실패는 **git 의 원래 진단을 보존**한다. "재실행으로 복구" 만 내면 원격이 앞선
  # 경우 재실행이 같은 실패를 반복하고, 사용자를 force push 라는 잘못된 처방으로 민다
  # (FR publish-clone-failure-init-fallback 이 같은 유형을 기록했다).
  _push_out=""
  if ! _push_out="$(git push origin "${PUBLISH_OID}:refs/heads/${DEFAULT_BRANCH}" 2>&1)"; then
    printf 'archive: %s push 실패\n' "$DEFAULT_BRANCH" >&2
    printf '%s\n' "$_push_out" | sed 's/^/archive:   git: /' >&2
    case "$_push_out" in
      *"non-fast-forward"*|*"fetch first"*)
        printf 'archive:   원격이 이 저장소보다 앞서 있습니다. 재실행만으로는 해결되지 않습니다\n' >&2
        printf 'archive:   **force push 를 쓰지 마십시오** — 원격 이력이 사라집니다\n' >&2
        printf 'archive:   (cd %s && git fetch origin && git log --oneline %s..origin/%s) 로 원격 쪽 커밋을 먼저 확인하십시오\n' \
          "$CURRENT_WT" "$DEFAULT_BRANCH" "$DEFAULT_BRANCH" >&2
        ;;
      *)
        # 원인을 단정하지 않는다. non-fast-forward 계열이 아닌 거부는 네트워크·권한 실패일
        # 수도, 서버측 거부(pre-receive hook·보호 브랜치 규칙)일 수도 있다 — 위 git 원문
        # 진단이 실제 원인을 담고 있으므로 그쪽을 보라고 가리키기만 한다.
        printf 'archive:   위에 출력된 git 진단을 확인하십시오 — 네트워크·권한 문제이거나, 서버측 거부(pre-receive hook·보호 브랜치 규칙)일 수 있습니다\n' >&2
        printf 'archive:   원인을 특정할 수 없어 단정하지 않습니다. 원인 해소 후 재실행하십시오\n' >&2
        ;;
    esac
    exit 1
  fi
  # 캡처한 tag object OID 를 명시한 refspec 으로 발행한다 — ref 이름을 주면 push 시점의
  # 로컬 tag 를 다시 해석해 그 사이 force-move 된 미검증 커밋이 원격 tag 로 나간다
  # (위 TAG_OID 주석 참조). `${TAG_OID}` 의 중괄호는 refspec 문자열에서 변수 경계를
  # 명확히 하기 위한 것이다.
  git push origin "${TAG_OID}:refs/tags/${TARGET_TAG}" \
    || { printf 'archive: tag push 실패 — 재실행으로 복구\n' >&2; exit 1; }

  # tag push **직후** 로컬 tag ref 를 다시 읽어 캡처한 OID 와 비교한다.
  #
  # 원격은 검증된 $TAG_OID 로 나갔으므로 발행 무결성은 지켜졌다. 그러나 그 사이 로컬
  # refs/tags/$TARGET_TAG 가 force-move 되면 같은 이름의 로컬 tag 와 원격 tag 가 서로
  # 다른 커밋을 가리킨 채 실행이 완료·정리되고, 다음 재실행은 fr branch 가 사라진
  # 상태에서 slug tag 의 존재만 보고 Step 0 의 "이미 archive 완료" 를 출력한다.
  #
  # **여기서 차단하지 않는다.** 원격 발행이 이미 정상 완료된 지점이라, 실패시키면
  # 아카이브가 반쯤 끝난 상태(원격은 나갔고 로컬 정리는 안 된 상태)로 남아 더 나쁘다.
  # 그래서 막지 않고 두 OID 와 로컬을 맞추는 명령을 명시적으로 보여 준다.
  #
  # 로컬 tag 를 **읽지 못하는 경우**(ref 삭제 등)도 같은 경고 경로로 보낸다 — 조용히
  # 넘기면 사용자는 로컬에 검증된 tag 가 남아 있다고 오해한다.
  _local_tag_commit="$(git rev-parse --verify --quiet "refs/tags/${TARGET_TAG}^{commit}")" || _local_tag_commit=""
  if [[ "$_local_tag_commit" != "$TAG_COMMIT" ]]; then
    printf 'archive: 로컬 tag %s 가 검증 시점 이후 이동했습니다 (원격 발행은 이미 완료됐습니다)\n' "$TARGET_TAG" >&2
    printf 'archive:   검증·발행된 커밋: %s\n' "$TAG_COMMIT" >&2
    printf 'archive:   현재 로컬 tag 커밋: %s\n' \
      "${_local_tag_commit:-읽지 못했습니다 (ref 삭제 또는 커밋이 아님)}" >&2
    printf 'archive:   원격 tag 는 위 검증된 커밋으로 발행됐습니다 — 원격은 안전합니다\n' >&2
    printf 'archive:   로컬을 맞추려면: git tag -f %s %s\n' "$TARGET_TAG" "$TAG_COMMIT" >&2
    printf 'archive:   맞추지 않으면 다음 재실행이 이 로컬 tag 만 보고 "이미 archive 완료" 로 오판할 수 있습니다\n' >&2
  fi

  # 발행이 확정된 뒤 Source FR 에 연결된 Issue 를 닫는다 (D4-3). 실패는 경고만 한다.
  _aci_rc=0; archive_close_issues "$PUBLISH_OID" || _aci_rc=$?
fi

# 로컬 tip 이 발행 대상과 다르면 알린다 (차단하지 않는다).
#
# OID 결속으로 미검증 발행은 이미 막혔다. 여기서 실패까지 시키면 다른 세션의 정당한
# 병행 커밋이 archive 를 실패시킨다. 다만 조용히 넘기면 사용자는 자기 커밋이 발행된
# 줄 안다 — 무엇이 빠졌는지 보여준다.
#
# **"앞서 있다" 를 단정하지 않는다.** 분기·후퇴·detached 상태에서는 그 말이 거짓이고
# 제외 커밋 목록도 틀린다. 조상 관계를 확인해 ahead 와 diverged 를 구분한다.
_local_tip="$(git rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$_local_tip" && "$_local_tip" != "$PUBLISH_OID" ]]; then
  if git merge-base --is-ancestor "$PUBLISH_OID" "$_local_tip" 2>/dev/null; then
    printf 'archive: 로컬 기본 브랜치가 발행 대상보다 앞서 있습니다 (ahead)\n' >&2
    printf 'archive:   발행: %s / 로컬: %s\n' \
      "$(git rev-parse --short "$PUBLISH_OID")" "$(git rev-parse --short "$_local_tip")" >&2
    printf 'archive:   아래 커밋은 검증을 거치지 않아 발행에서 제외했습니다 —\n' >&2
    git log --oneline --first-parent "${PUBLISH_OID}..${_local_tip}" 2>/dev/null | sed 's/^/archive:     /' >&2
    printf 'archive:   발행하려면 diff review 를 거친 뒤 archive 를 다시 실행하십시오\n' >&2
  else
    printf 'archive: 로컬 tip 이 발행 대상의 자손이 아닙니다 (diverged 또는 detached)\n' >&2
    printf 'archive:   발행: %s / 로컬: %s\n' \
      "$(git rev-parse --short "$PUBLISH_OID")" "$(git rev-parse --short "$_local_tip")" >&2
    printf 'archive:   두 지점이 갈라져 있어 제외된 커밋을 단정할 수 없습니다\n' >&2
    printf 'archive:   (cd %s && git log --oneline --graph %s %s) 로 관계를 확인하십시오\n' \
      "$CURRENT_WT" "$(git rev-parse --short "$PUBLISH_OID")" "$(git rev-parse --short "$_local_tip")" >&2
  fi
fi

# ---------------------------------------------------------------------------
# post-success cleanup 경계
# core 산출물(merge · metadata cleanup commit · tag · push)이 만들어진 이후 단계는
# 개별 실패가 스크립트를 중단시키지 않는다. 미완 항목을 모아 종료 직전에 한 번에 요약한다.
# 잔여 레코드 형식: <kind>\t<identifier>\t<reason>\t<command>
#   kind    ∈ worktree | local-branch | remote-branch | loop-state | submodule
#             (분리 FR archive-cleanup-visibility 가 이 4필드를 마커 파일로 직렬화한다)
#   reason  : 사람이 읽는 사유. TAB·개행 없는 고정 문구만 쓴다.
#   command : 복사해 그대로 실행 가능한 셸 한 줄. 자연어 지시문을 넣지 않는다.
#             데이터를 지울 수 있는 명령(worktree remove --force / branch -D)은 기본값으로
#             제시하지 않고, 필요 조건과 손실 범위를 reason 에 적는다.
# identifier 를 %q 로 인코딩하는 이유: 경로에 작은따옴표·TAB·개행이 들어가도
#   (1) TAB 구분·개행 구분 레코드가 깨지지 않고 (2) 출력을 셸에 그대로 붙여넣어도 안전하다.
# ---------------------------------------------------------------------------
CLEANUP_PENDING=""
SAFETY_VIOLATION=0
WORKTREE_PENDING=0
CLEANUP_TAB="$(printf '\t')"

cleanup_add() {  # cleanup_add <kind> <identifier> <reason> <command>
  CLEANUP_PENDING="${CLEANUP_PENDING}${1}${CLEANUP_TAB}$(printf '%q' "$2")${CLEANUP_TAB}${3}${CLEANUP_TAB}${4}"$'\n'
}

safety_violation() {  # safety_violation <kind> <identifier> <reason> <command>
  SAFETY_VIOLATION=1
  printf 'archive: 안전 불변식 위반 — %s\n' "$3" >&2
  cleanup_add "$1" "$2" "$3" "$4"
}

is_oid() {  # is_oid <string> — sha1(40) 또는 sha256(64) hex 이면 0
  case "$1" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [[ "${#1}" -eq 40 || "${#1}" -eq 64 ]]
}

git_supports_lease() {  # git >= 1.8.5 이면 0. 미지원·판정 불능이면 1 (fail-closed)
  local v major minor patch
  v="$(git --version 2>/dev/null | awk '{print $3}')" || return 1
  major="$(printf '%s' "$v" | cut -d. -f1)"
  minor="$(printf '%s' "$v" | cut -d. -f2)"
  patch="$(printf '%s' "$v" | cut -d. -f3)"
  patch="${patch%%[!0-9]*}"          # "0.rc1" 같은 표기에서 선행 숫자만
  [[ -z "$patch" ]] && patch=0
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$major" -gt 1 ]] && return 0
  [[ "$major" -lt 1 ]] && return 1
  [[ "$minor" -gt 8 ]] && return 0
  [[ "$minor" -lt 8 ]] && return 1
  [[ "$patch" -ge 5 ]]
}

# ---------------------------------------------------------------------------
# 발행 기록 — 색인 행을 지우지 않고 state=cleanup-pending 을 남긴다 (spec D8).
#   즉시 tasks_index_remove 로 지우면, 아직 살아 있는 worktree(예: skipped-self)를
#   --rebuild 가 다시 "진행 중" 으로 재구성하고, 그 뒤 그 worktree 에서 새 커밋이
#   쌓이면 동적 발행 증거 판정(tasks_publish_evidence)이 in-progress 로 되돌아가
#   이미 발행된 작업이 목록에 되살아난다. 행을 남겨 두면 tasks_list.sh 가 이 필드를
#   보고 dynamic 판정 없이 무조건 "정리 대기" 로 고정해 보여준다.
#   락 획득 실패는 발행 자체를 되돌리지 않는다(이미 끝난 core 산출물) — 경고만 남긴다.
#   no-fr 모드는 tasks_index 대상이 아니므로 건드리지 않는다.
# ---------------------------------------------------------------------------
if [[ "$BRANCH_MODE" == "fr" ]]; then
  # tasks_publish_evidence 가 단일 출처다 — 그냥 기록하면 --no-remote(로컬만 완료,
  # 원격 미반영)에서도 "정리 대기" 가 영구히 고정돼 tasks_list.sh 의 needs-verify
  # (⚠ 발행 확인 필요) 경로를 조용히 지운다.
  # **REMOTE_MODE 가 아니라 REMOTE_MODE_RAW 를 쓴다.** REMOTE_MODE 는 --no-remote 로
  # local-only 로 덮여 있을 수 있는데, tasks_list.sh 는 --no-remote 라는 archive.sh
  # 전용 플래그를 모르고 항상 detect_remote_mode() 로만 판정한다(:40). origin 이 있는
  # 저장소에서 --no-remote 로 마감하면 이 재확인이 remote_mode="local-only" 로 원격
  # 검사를 건너뛰어 merge+tag 만으로 cleanup-pending 을 내고, tasks_list.sh 는
  # remote_mode="remote" 로 「⚠ 발행 확인 필요」를 내야 할 상황을 놓친다.
  _archive_publish_default_branch="$(get_default_branch 2>/dev/null)" || _archive_publish_default_branch=""
  _archive_publish_fr_tip="$(git rev-parse --verify --quiet "$FR_BRANCH" 2>/dev/null)" || _archive_publish_fr_tip=""
  _archive_publish_evidence=""
  if [[ -n "$_archive_publish_default_branch" && -n "$_archive_publish_fr_tip" ]]; then
    _archive_publish_evidence="$(tasks_publish_evidence "$SLUG" "$_archive_publish_fr_tip" "$_archive_publish_default_branch" "$REMOTE_MODE_RAW")"
  fi
  if [[ "$_archive_publish_evidence" == "cleanup-pending" ]]; then
    # 락은 이 스크립트 시작 지점에서 이미 쥐고 있다 — 다시 잡으면 자기 자신과 교착한다.
    tasks_index_upsert "$SLUG" \
      "state=cleanup-pending" \
      "published-at=$(date -u '+%Y-%m-%d-%H%M')" \
      "publish-tag=$TARGET_TAG" \
      || printf 'archive: WARNING — tasks 색인 갱신 실패(state=cleanup-pending) — rd task list 가 이 작업을 정리 대기로 보여주지 못할 수 있습니다\n' >&2
  else
    # 증거가 아직 cleanup-pending 이 아니다(예: --no-remote 로 원격 미반영, 또는 판정
    # 불가) — 정적 기록을 남기지 않는다. tasks_list.sh 는 이 slug 를 dynamic
    # tasks_publish_evidence 로 계속 판정해 needs-verify(⚠ 발행 확인 필요) 를 정확히
    # 보여준다. 여기서 "state=cleanup-pending" 을 써 버리면 그 판정을 영구히 덮는다.
    printf 'archive: 색인에 정리 대기 기록을 남기지 않았습니다(발행 증거=%s) — rd task list 는 dynamic 판정으로 보여줍니다.\n' "${_archive_publish_evidence:-판정불가}"
  fi
fi

# Step 6.5 — 기본 worktree 의 submodule 체크아웃을 발행된 gitlink 에 맞춘다 (spec D11~D14).
# merge 는 gitlink 만 옮기고 submodule 안쪽 체크아웃은 건드리지 않아, 그대로 두면 `git status` 가
# 「modified: <경로> (new commits)」 를 보이고 `git add -A` 가 발행을 되돌립니다. no-fr 은 건너뜁니다.
# 갱신하지 않았거나 실패한 항목은 정리 잔여 `submodule` 로 기록하고 계속합니다(종료 코드에 영향 없음).
if [[ "$BRANCH_MODE" == "fr" ]]; then
  _ss_file="$(mktemp "${TMPDIR:-/tmp}/rd-archive-sync.XXXXXX")" || _ss_file=""
  _ss_rc=1
  [[ -z "$_ss_file" ]] || { rd_submodule_checkout_sync "$PUBLISH_WT" "$PUBLISH_OID" > "$_ss_file" 2>/dev/null && _ss_rc=0 || _ss_rc=$?; }
  if [[ "$_ss_rc" -ne 0 ]]; then
    printf 'archive: submodule 체크아웃 갱신 대상을 판정하지 못했습니다 — 정리 잔여로 기록\n' >&2
    cleanup_add "submodule" "." "submodule 체크아웃 갱신 대상을 판정하지 못했습니다" \
      "git -C $(printf '%q' "$PUBLISH_WT") submodule status --recursive"
  else
    while IFS= read -r -d '' _ss_kind && IFS= read -r -d '' _ss_path && IFS= read -r -d '' _ss_reason && IFS= read -r -d '' _ss_cmd; do
      if [[ "$_ss_kind" == "ok" ]]; then
        printf 'archive: submodule %s 체크아웃을 발행된 커밋으로 맞췄습니다\n' "$_ss_path"
      else
        printf 'archive: submodule %s 체크아웃을 갱신하지 않았습니다 — 정리 잔여로 기록\n' "$_ss_path" >&2
        cleanup_add "submodule" "$_ss_path" "$_ss_reason" "$_ss_cmd"
      fi
    done < "$_ss_file"
  fi
  [[ -z "$_ss_file" ]] || rm -f "$_ss_file"
fi

# Step 7 — Worktree teardown (post-success cleanup)
#
# 안전 불변식: "정리를 마친 뒤 다시 조회했을 때 fr 브랜치를 체크아웃한 worktree 등록이 0건" 일 때만
# 로컬 ref 삭제를 허용한다. update-ref -d 에는 branch -d 가 갖던 worktree 보호가 없으므로
# (실측: worktree 가 살아 있어도 ref 가 삭제되고 그 worktree 는 broken HEAD 가 됨)
# 제거 명령의 성공 여부가 아니라 "최종 상태" 를 근거로 삼는다.
# 아래 세 경우가 모두 "명령은 성공했는데 등록이 남는" 형태이기 때문이다 (셋 다 실측 확인):
#   1) locked worktree 의 경로 소실 → prune 이 exit 0 인데 등록 잔존
#   2) prune 만료 기준 미도달 → 동일
#   3) 경로에 개행 포함 → --porcelain 출력이 쪼개져 경로 추출값이 잘림 (줄 수는 정상과 같아 개수 비교로 감지 불가)
#
# 대상 존재 판정은 경로가 아니라 branch 라인 개수로 한다.
# ref 이름에는 개행이 들어갈 수 없으므로 이 판정은 경로 특수문자와 무관하게 정확하다.
# grep -F 로 브랜치명의 정규식 메타문자를 무력화하고 -x 로 접두사 오탐(fr/foo ↔ fr/foobar)을 막는다.
wt_match_count() {  # stdout: 등록 수. 조회 실패 시 return 1
  local out
  out="$(git worktree list --porcelain 2>/dev/null)" || return 1
  printf '%s\n' "$out" | grep -c -x -F "branch refs/heads/$FR_BRANCH" || true
}

# 제거 대상의 정확성 게이트.
# 경로에 개행이 있으면 --porcelain 추출값이 잘리는데, 그 잘린 접두사가 마침 "다른 브랜치의
# clean worktree" 이면 git worktree remove 가 실패하지 않고 범위 밖 worktree 를 지운다 (실측 확인).
# 최종 재조회는 대상 ref 의 미삭제만 보장할 뿐 이미 벌어진 오대상 제거를 되돌리지 못하므로,
# 제거 직전에 "이 경로가 정말 대상 브랜치의 worktree 루트인가" 를 확인한다.
# --show-toplevel 비교가 필요한 이유: git -C 는 worktree 가 아닌 디렉토리에서도 상위 저장소를
# 찾아 올라가므로, 경로 자체가 루트인지 확인하지 않으면 상위 repo 의 HEAD 를 보고 오판정한다.
wt_owns_fr_branch() {  # wt_owns_fr_branch <path> — 0 = 대상 브랜치의 worktree 루트
  local p="$1" top ref
  top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ "$top" == "$p" ]] || return 1
  ref="$(git -C "$p" symbolic-ref --quiet HEAD 2>/dev/null)" || return 1
  [[ "$ref" == "refs/heads/$FR_BRANCH" ]]
}

WT_COUNT_BEFORE=""
if [[ "$BRANCH_MODE" == "no-fr" ]]; then
  : # no-fr — 정리할 fr worktree 가 없습니다 (WORKTREE_PENDING 은 0 을 유지합니다)
elif ! WT_COUNT_BEFORE="$(wt_match_count)"; then
  WORKTREE_PENDING=1
  safety_violation "worktree" "$FR_BRANCH" \
    "worktree 등록 조회 실패 — 로컬 ref 삭제의 선행 조건을 판정할 수 없어 삭제하지 않았습니다" \
    "git worktree list --porcelain"
elif [[ "$WT_COUNT_BEFORE" -gt 0 ]]; then
  # (b) 제거 시도. 경로 추출 자체는 개행에 취약하므로, 제거 대상의 정확성은 아래 wt_owns_fr_branch
  # 소유권 검증이 보증한다 — (d) 재조회는 대상 ref 의 미삭제만 보증할 뿐 이미 벌어진 오대상 제거는 되돌리지 못한다.
  # break 를 두지 않아 대상이 여럿이면 모두 시도한다.
  # git worktree add --force 로 동일 브랜치를 여러 worktree 에서 체크아웃할 수 있으므로(실측)
  # 이 루프는 실제로 다중 대상에 도달한다.
  WT_TARGETS="$(git worktree list --porcelain 2>/dev/null | awk -v b="$FR_BRANCH" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0=="branch refs/heads/"b{print p}
  ')" || WT_TARGETS=""
  while IFS= read -r fr_wt; do
    [[ -z "$fr_wt" ]] && continue
    if [[ ! -d "$fr_wt" ]]; then
      # 경로가 사라진 등록. prune 은 "경로가 실재하지 않는 등록" 만 지우는 비파괴 명령이라
      # 자동 실행이 안전하다. 다만 그 성공을 정리 완료의 근거로 삼지 않는다 (locked entry 는 exit 0 인데 남는다).
      git worktree prune || true
      continue
    fi
    if ! wt_owns_fr_branch "$fr_wt"; then
      # 추출값이 잘렸거나 다른 브랜치의 worktree 를 가리킨다 → 건드리지 않는다.
      # 대상이 실제로 남아 있다면 아래 (d) 재조회가 잡아 pending 으로 만든다.
      printf 'archive: %s 는 %s 의 worktree 루트가 아님 — 제거 건너뜀\n' "$fr_wt" "$FR_BRANCH" >&2
      continue
    fi
    # skipped-self — 제거 대상이 이 archive 를 호출한(re-exec 이전) worktree 면 지우지
    # 않는다. RD_ARCHIVE_CALLER_WT 는 재실행 때만 설정된다(spec D5) — 재실행이 없었으면
    # (원래부터 기본 worktree 에서 호출) 이 분기는 적용되지 않는다. 아래 (d) 재조회가
    # 이 worktree 를 여전히 등록된 것으로 보고 WORKTREE_PENDING 을 자연히 세운다 —
    # 로컬 branch 삭제(Step 8)도 그 값으로 함께 막힌다.
    if [[ -n "${RD_ARCHIVE_CALLER_WT:-}" ]]; then
      _archive_caller_norm="$(cd "$RD_ARCHIVE_CALLER_WT" 2>/dev/null && pwd -P)" || _archive_caller_norm="$RD_ARCHIVE_CALLER_WT"
      _archive_frwt_norm="$(cd "$fr_wt" 2>/dev/null && pwd -P)" || _archive_frwt_norm="$fr_wt"
      if [[ "$_archive_frwt_norm" == "$_archive_caller_norm" ]]; then
        printf 'archive: %s 는 이 archive 를 호출한 worktree 라 제거하지 않습니다 — 기본 체크아웃에서 `rd task list` 를 실행하면 세션이 이 worktree 를 나온 뒤 자동으로 정리됩니다\n' "$fr_wt" >&2
        cleanup_add "worktree" "$fr_wt" \
          "세션이 이 worktree 안에 있어 지우지 않았습니다(호출자 worktree). 세션 안에서 이 worktree 를 직접 지우지 마십시오. 세션이 끝난 뒤 기본 체크아웃에서 rd task list 를 실행하면 정리됩니다" \
          "cd $(printf '%q' "$PUBLISH_WT") && bash rd-workflow/scripts/rd task list"
        continue
      fi
    fi
    # 점유 검사 — 다른 프로세스(세션)의 CWD 가 이 worktree 안이면 지우지 않는다. 지우면 그 세션의
    # gate hook 이 꺼진다. 서브셸 없이 불러야 TASKS_OCCUPIED_REASON 을 읽는다. rc 1(점유 없음)만 지운다.
    _oc_rc=0; tasks_path_occupied "$fr_wt" || _oc_rc=$?
    if [[ "$_oc_rc" -eq 0 || "$_oc_rc" -eq 2 ]]; then
      if [[ "$_oc_rc" -eq 0 ]]; then
        _oc_reason="세션이 이 worktree 안에 있어 지우지 않았습니다(내 계정 프로세스의 작업 디렉터리가 이 worktree 안). 세션 안에서 이 worktree 를 직접 지우지 마십시오. 세션이 끝난 뒤 기본 체크아웃에서 rd task list 를 실행하면 정리됩니다"
      else
        _oc_why="$(printf '%s' "${TASKS_OCCUPIED_REASON:-사유 불명}" | tr '\t\r\n' '   ')"
        _oc_reason="세션이 있는지 확인하지 못해 지우지 않았습니다(${_oc_why}). 세션 안에서 이 worktree 를 직접 지우지 마십시오. 세션이 끝난 뒤 기본 체크아웃에서 rd task list 를 실행하면 정리됩니다"
      fi
      printf 'archive: worktree %s 를 지우지 않았습니다 — %s\n' "$fr_wt" "$_oc_reason" >&2
      cleanup_add "worktree" "$fr_wt" "$_oc_reason" \
        "cd $(printf '%q' "$PUBLISH_WT") && bash rd-workflow/scripts/rd task list"
      continue
    fi
    _rm_rc=0; _rm_out="$(rd_worktree_remove_safe "$fr_wt")" || _rm_rc=$?
    if [[ "$_rm_rc" -eq 1 ]]; then
      _rm_cause="${_rm_out%%$'\t'*}"; _rm_sub="${_rm_out#*$'\t'}"
      _rm_info="$(rd_worktree_hold_info "$_rm_cause" "$_rm_sub" "$fr_wt")"
      printf 'archive: worktree %s 를 지우지 않았습니다 (%s) — 정리 잔여로 기록\n' "$fr_wt" "${_rm_info%%$'\t'*}" >&2
      cleanup_add "worktree" "$fr_wt" "${_rm_info%%$'\t'*}" "${_rm_info#*$'\t'}"
    elif [[ "$_rm_rc" -ne 0 ]]; then
      printf 'archive: worktree remove %s 실패 — 정리 잔여로 기록\n' "$fr_wt" >&2
      # 복구 기본값은 비파괴 확인 명령이다. --force 는 미커밋 변경을 잃으므로 사유에만 조건부로 적는다.
      cleanup_add "worktree" "$fr_wt" \
        "worktree 제거 실패 — 미커밋 변경 확인 필요. 변경이 없으면 git worktree remove 로 재시도하고, --force 는 미커밋 변경을 삭제합니다" \
        "git -C $(printf '%q' "$fr_wt") status --short"
    fi
  done <<EOF
$WT_TARGETS
EOF

  # (d) 최종 재조회 — 권위 판정. 여기서만 WORKTREE_PENDING 을 확정한다.
  WT_COUNT_AFTER=""
  if ! WT_COUNT_AFTER="$(wt_match_count)"; then
    WORKTREE_PENDING=1
    safety_violation "worktree" "$FR_BRANCH" \
      "worktree 등록 재조회 실패 — 정리 완료를 확인할 수 없어 로컬 ref 를 삭제하지 않았습니다" \
      "git worktree list --porcelain"
  elif [[ "$WT_COUNT_AFTER" -gt 0 ]]; then
    WORKTREE_PENDING=1
    cleanup_add "worktree" "$FR_BRANCH" \
      "정리 후에도 이 브랜치를 체크아웃한 worktree 등록이 ${WT_COUNT_AFTER}건 남아 있습니다 (locked·경로 이상 등). 로컬 브랜치 삭제를 건너뜁니다" \
      "git worktree list --porcelain"
  fi
fi

# Step 8 — Local branch 삭제 (검증 → expected-old 삭제)
# git branch -d 는 upstream 이 설정된 브랜치를 "HEAD 기준" 이 아니라 "upstream 기준" 으로 판정한다.
# 이 워크플로는 fr 을 매 커밋마다 push 하지 않으므로 local fr tip > origin/fr tip 이 정상 상태이고,
# 그 정상 상태가 오판정되어 실패했다. 판정을 MERGE_BASE_COMMIT 기준 ancestor 검사로 바꾼다.
if [[ "$BRANCH_MODE" == "no-fr" ]]; then
  : # no-fr — 삭제할 fr 로컬 브랜치가 없습니다
elif [[ "$WORKTREE_PENDING" -eq 1 ]]; then
  # update-ref -d 는 branch -d 와 달리 "다른 worktree 가 체크아웃 중인 브랜치" 보호가 없다.
  # worktree 가 남았거나 목록 판정이 불가능한 상태에서 ref 를 지우면 그 worktree 가
  # broken HEAD 가 되므로 시도하지 않는다.
  # worktree 제거 실패(일반 cleanup 실패)는 exit 0 을 유지하고,
  # 목록 판정 불능은 Step 7 에서 이미 안전 불변식 위반으로 기록되어 non-zero 가 된다.
  printf 'archive: worktree 정리 미완 — 로컬 브랜치 삭제 미시도\n' >&2
  # command 는 비파괴 확인 명령이어야 한다. archive.sh 재실행은 merge/tag/push 까지 다시 진입할 수 있는
  # 변이 명령이며, "fr 잔존 + tag 존재" 상태의 멱등 continuation 경로는 이번 범위에서 설계·검증하지 않았다.
  # 따라서 후속 조치 안내는 reason 에만 둔다.
  cleanup_add "local-branch" "$FR_BRANCH" \
    "worktree 정리가 끝나지 않아 로컬 브랜치 삭제를 시도하지 않았습니다 (update-ref -d 에는 worktree 보호가 없습니다). 아래로 남은 등록을 확인하고 worktree 를 정리한 뒤 브랜치를 수동으로 정리하십시오" \
    "git worktree list --porcelain"
else
  # for-each-ref 의 패턴은 정확 일치뿐 아니라 slash 경계의 하위 ref 도 매치한다 (실측).
  # 대상 refs/heads/fr/foo 가 없고 refs/heads/fr/foo/child 하나만 있으면 %(objectname) 만 읽을 때
  # child 의 유효 OID 한 줄이 나와 "대상 존재" 로 오인되고, 그 OID 로 ancestor 판정·update-ref -d 까지 진행된다.
  # 따라서 %(refname) 을 함께 읽어 정확 일치 행만 존재 판정에 쓴다 (ref 이름에는 공백이 들어갈 수 없다).
  LOCAL_REF_RAW=""; LOCAL_REF_RC=0
  LOCAL_REF_RAW="$(git for-each-ref --format='%(refname) %(objectname)' "refs/heads/$FR_BRANCH" 2>/dev/null)" \
    || LOCAL_REF_RC=$?
  # 정확 일치 "행 수" 와 "OID 값" 을 분리해 보존한다.
  # 둘을 합치면 (정확 행 1건 + OID 필드 누락) 이 빈 문자열이 되어 "정상 부재" 로 오분류되고,
  # fail-closed 계약이 깨진 채 원격 삭제까지 진행된다.
  LOCAL_REF_LINES="$(printf '%s\n' "$LOCAL_REF_RAW" | awk -v r="refs/heads/$FR_BRANCH" '$1==r{c++} END{print c+0}')"
  LOCAL_REF_OUT="$(printf '%s\n' "$LOCAL_REF_RAW" | awk -v r="refs/heads/$FR_BRANCH" '$1==r{print $2}' | head -1)"

  FRQ="$(printf '%q' "$FR_BRANCH")"   # 복구 명령 조립용 shell-quoted 브랜치명
  if [[ "$LOCAL_REF_RC" -ne 0 ]]; then
    # 종료 상태 비정상 = 판정 불능. "정상 부재" 로 오분류해 숨기지 않는다.
    safety_violation "local-branch" "$FR_BRANCH" \
      "로컬 ref 조회 실패 (rc=$LOCAL_REF_RC) — 판정 불능이므로 삭제하지 않았습니다" \
      "git for-each-ref --format='%(refname) %(objectname)' refs/heads/$FRQ"
  elif [[ "$LOCAL_REF_LINES" -eq 0 ]]; then
    # 정상 부재 — 이미 정리된 멱등 상태. 잔여도 위반도 아닌 성공 no-op.
    # 하위 ref(refs/heads/<fr>/*)가 있어도 여기로 온다. 그것들은 대상이 아니므로 건드리지 않는다.
    printf 'archive: 로컬 브랜치 %s 없음 — skip\n' "$FR_BRANCH"
  elif [[ "$LOCAL_REF_LINES" -ne 1 ]] || ! is_oid "$LOCAL_REF_OUT"; then
    # 정확 행이 2건 이상이거나, 행은 있는데 OID 가 비었거나 형식이 틀린 경우 — 모두 판정 불능이다.
    safety_violation "local-branch" "$FR_BRANCH" \
      "로컬 ref 판정 불능 (정확 일치 행 ${LOCAL_REF_LINES}건 또는 malformed OID)" \
      "git for-each-ref --format='%(refname) %(objectname)' refs/heads/$FRQ"
  else
    LOCAL_ANC_RC=0
    git merge-base --is-ancestor "$LOCAL_REF_OUT" "$MERGE_BASE_COMMIT" 2>/dev/null || LOCAL_ANC_RC=$?
    if [[ "$LOCAL_ANC_RC" -eq 0 ]]; then
      # 검증한 OID 를 expected-old 로 지정 — 검증~삭제 사이 tip 이동(TOCTOU)을 막는다.
      if git update-ref -d "refs/heads/$FR_BRANCH" "$LOCAL_REF_OUT"; then
        printf 'archive: 로컬 브랜치 %s 삭제\n' "$FR_BRANCH"
      else
        safety_violation "local-branch" "$FR_BRANCH" \
          "expected-old 삭제 거부 — 검증 후 tip 이동 의심. 아래로 남은 커밋을 확인한 뒤 필요하면 git branch -D 로 삭제하십시오(강제 삭제는 미머지 커밋을 잃습니다)" \
          "git log --oneline $FRQ --not $MERGE_BASE_COMMIT"
      fi
    elif [[ "$LOCAL_ANC_RC" -eq 1 ]]; then
      safety_violation "local-branch" "$FR_BRANCH" \
        "미머지 커밋 존재 (merge 대상 base 의 ancestor 아님). 아래로 남은 커밋을 확인하십시오. 버려도 되는 커밋이면 git branch -D 로 삭제합니다" \
        "git log --oneline $FRQ --not $MERGE_BASE_COMMIT"
    else
      # fail-closed: 판정 명령 자체가 실패하면 "정상 부재" 나 "거짓" 과 구분해 삭제를 금지한다.
      safety_violation "local-branch" "$FR_BRANCH" \
        "merge 판정 명령 실패 (rc=$LOCAL_ANC_RC) — 판정 불능이므로 삭제하지 않았습니다" \
        "git merge-base --is-ancestor $FRQ $MERGE_BASE_COMMIT; echo rc=\$?"
    fi
  fi
fi

# Step 9 — Remote branch delete (검증 → lease 삭제)
# no-fr 모드에는 삭제할 원격 fr 브랜치가 없습니다 (기본 브랜치 push 는 Step 6 에서 끝났습니다).
if [[ "$BRANCH_MODE" == "fr" && "$REMOTE_MODE" == "remote" ]]; then
  FRQ="$(printf '%q' "$FR_BRANCH")"
  if [[ "$SAFETY_VIOLATION" -eq 1 ]]; then
    # 안전 불변식 위반이 이미 감지되면 뒤따르는 ref 삭제를 건너뛴다.
    printf 'archive: 안전 불변식 위반 감지 — 원격 브랜치 삭제 건너뜀\n' >&2
    cleanup_add "remote-branch" "$FR_BRANCH" \
      "앞선 안전 불변식 위반 때문에 원격 브랜치 삭제를 시도하지 않았습니다. 위반을 해소한 뒤 아래로 원격 상태를 확인하고 수동으로 정리하십시오" \
      "git ls-remote origin refs/heads/$FRQ"
  elif ! git_supports_lease; then
    # 사전 feature detection — 무보호 삭제로 fallback 하지 않는다.
    safety_violation "remote-branch" "$FR_BRANCH" \
      "git 1.8.5 미만(--force-with-lease 미지원) 또는 버전 판정 불능 — 보호된 삭제가 불가능해 시도하지 않았습니다" \
      "git --version"
  else
    REMOTE_LS_OUT=""; REMOTE_LS_RC=0
    REMOTE_LS_OUT="$(git ls-remote origin "refs/heads/$FR_BRANCH" 2>/dev/null)" || REMOTE_LS_RC=$?
    REMOTE_LS_LINES="$(printf '%s' "$REMOTE_LS_OUT" | grep -c . || true)"
    REMOTE_OID="$(printf '%s' "$REMOTE_LS_OUT" | head -1 | awk '{print $1}')"

    if [[ "$REMOTE_LS_RC" -ne 0 ]]; then
      safety_violation "remote-branch" "$FR_BRANCH" \
        "원격 ref 조회 실패 (rc=$REMOTE_LS_RC) — 판정 불능이므로 삭제하지 않았습니다" \
        "git ls-remote origin refs/heads/$FRQ"
    elif [[ -z "$REMOTE_LS_OUT" ]]; then
      printf 'archive: 원격 브랜치 %s 없음 — skip\n' "$FR_BRANCH"
    elif [[ "$REMOTE_LS_LINES" -ne 1 ]] || ! is_oid "$REMOTE_OID"; then
      safety_violation "remote-branch" "$FR_BRANCH" \
        "원격 ref 판정 불능 (malformed 출력, lines=$REMOTE_LS_LINES)" \
        "git ls-remote origin refs/heads/$FRQ"
    elif ! git cat-file -e "${REMOTE_OID}^{commit}" 2>/dev/null; then
      # 원격 tip 객체가 로컬에 없으면 ancestor 판정 자체가 불가능하다 (오류를 거짓으로 오해하지 않는다).
      # 재실행 안내를 넣지 않는다 — 이 시점에는 tag·metadata cleanup 이 이미 끝났고 로컬 ref 도 삭제되었을 수 있어,
      # archive 재실행은 rerun 안전망에서 조기 종료할 수 있다 (Step 9 continuation 이 되지 않는다).
      safety_violation "remote-branch" "$FR_BRANCH" \
        "원격 tip 객체($REMOTE_OID)가 로컬에 없어 ancestor 판정이 불가능합니다. 아래로 원격 상태를 확인하고, 객체를 받아 직접 비교하려면 git fetch origin $FRQ 후 git merge-base --is-ancestor $REMOTE_OID $MERGE_BASE_COMMIT 를 실행하십시오" \
        "git ls-remote origin refs/heads/$FRQ"
    else
      REMOTE_ANC_RC=0
      git merge-base --is-ancestor "$REMOTE_OID" "$MERGE_BASE_COMMIT" 2>/dev/null || REMOTE_ANC_RC=$?
      if [[ "$REMOTE_ANC_RC" -ne 0 ]]; then
        safety_violation "remote-branch" "$FR_BRANCH" \
          "원격 tip 이 merge 대상 base 의 ancestor 아님 (rc=$REMOTE_ANC_RC). 아래로 원격에만 있는 커밋을 확인하십시오" \
          "git log --oneline $REMOTE_OID --not $MERGE_BASE_COMMIT"
      else
        # 고정한 원격 tip 을 lease 로 지정 — 검증~push 사이 원격 이동을 막는다.
        REMOTE_PUSH_OUT=""; REMOTE_PUSH_RC=0
        REMOTE_PUSH_OUT="$(git push --force-with-lease="refs/heads/$FR_BRANCH:$REMOTE_OID" \
          origin ":refs/heads/$FR_BRANCH" 2>&1)" || REMOTE_PUSH_RC=$?
        printf '%s\n' "$REMOTE_PUSH_OUT" | sed 's/^/archive: remote-branch-delete: /'
        if [[ "$REMOTE_PUSH_RC" -eq 0 ]]; then
          printf 'archive: 원격 브랜치 %s 삭제\n' "$FR_BRANCH"
        else
          # 이 시점에 로컬 ref 는 이미 삭제되었을 수 있으나 복구하지 않는다.
          # 로컬 삭제는 ancestor 검증을 통과했으므로 그 ref 의 모든 커밋이 base 에 포함되어 커밋 손실이 없다.
          safety_violation "remote-branch" "$FR_BRANCH" \
            "lease 거부 또는 push 실패 (rc=$REMOTE_PUSH_RC) — 원격 tip 이동 의심. 아래로 현재 원격 tip 을 확인한 뒤 필요하면 git push origin --delete 로 삭제하십시오" \
            "git ls-remote origin refs/heads/$FRQ"
        fi
      fi
    fi
  fi
fi

# 정리가 완전히 끝났을 때만 색인 행을 지운다 (spec D8) — 부분 정리(예: skipped-self)
# 상태에서 지우면 state=cleanup-pending 표시가 사라지고, 다음 --rebuild 가 아직 살아
# 있는 worktree/branch 를 다시 "진행 중" 으로 재구성한다. 락 획득 실패는 조용한 경고로
# 남긴다 — 정리 완료 자체(worktree·branch 제거)는 이미 끝난 뒤라 되돌릴 것이 없다.
if [[ "$BRANCH_MODE" == "fr" && "$WORKTREE_PENDING" -eq 0 && "$SAFETY_VIOLATION" -eq 0 ]]; then
  # 락은 이 스크립트가 계속 쥐고 있다 — 종료 trap 이 해제한다.
  tasks_index_remove "$SLUG" \
    || printf 'archive: WARNING — 정리 완료 후 색인 행 제거 실패 — rd task list 에 완료된 작업이 남아 보일 수 있습니다\n' >&2
fi

# ---- 정리 잔여 기록 (slug 별 파일) ----
# 요약 출력 직전에 자기 slug 기록을 남기거나(잔여 있음) 지운다(잔여 없음). 기록 실패는 발행을 되돌리지 않고
# stderr 표식과 종료 코드 1 로만 알린다 — stdout 요약·완료 줄은 그대로 낸다.
RECORD_FAILED=0
_cp_helper="$SCRIPT_DIR/cleanup_pending.sh"
_cp_op="clear"; [[ -n "$CLEANUP_PENDING" ]] && _cp_op="write"
if [[ ! -f "$_cp_helper" ]]; then
  printf 'archive: CLEANUP-RECORD-FAILED %s 헬퍼 파일이 없음 (%s)\n' "$_cp_op" "$_cp_helper" >&2
  RECORD_FAILED=1
elif [[ "$_cp_op" == "write" ]]; then
  if ! printf '%s' "$CLEANUP_PENDING" | bash "$_cp_helper" write "$SLUG"; then
    printf 'archive: CLEANUP-RECORD-FAILED write 정리 잔여 기록을 남기지 못함 (%s)\n' "$SLUG" >&2
    RECORD_FAILED=1
  fi
else
  if ! bash "$_cp_helper" clear "$SLUG"; then
    printf 'archive: CLEANUP-RECORD-FAILED clear 정리 잔여 기록을 지우지 못함 (%s)\n' "$SLUG" >&2
    RECORD_FAILED=1
  fi
fi

# ---- 정리 잔여 요약 (stdout) ----
# 종료 코드 0 의 의미가 "완전 정리 완료" 에서 "core 성공(잔여 가능)" 으로 넓어지므로,
# 잔여가 조용히 지나가지 않도록 종료 직전에 사유와 복구 명령을 함께 출력한다.
# 복구 줄은 그대로 복사해 실행할 수 있는 한 줄이며, 기본값은 비파괴 확인 명령이다.
if [[ -n "$CLEANUP_PENDING" ]]; then
  printf 'archive: CLEANUP-PENDING\n'
  while IFS="$CLEANUP_TAB" read -r ck cid creason ccmd; do
    [[ -z "$ck" ]] && continue
    printf 'archive:   [%s] %s\n' "$ck" "$cid"
    printf 'archive:     사유: %s\n' "$creason"
    printf 'archive:     복구: %s\n' "$ccmd"
  done <<EOF
$CLEANUP_PENDING
EOF
  printf 'archive: core 완료 (정리 잔여 있음). tag=%s\n' "$TARGET_TAG"
else
  printf 'archive: 완료. tag=%s\n' "$TARGET_TAG"
fi

if [[ "$SAFETY_VIOLATION" -eq 1 ]]; then
  # 보존 범위를 정확히 표현한다 — 이미 검증을 통과해 삭제된 ref 는 복구하지 않는다(AC10).
  printf 'archive: 안전 불변식 위반으로 종료 — 아직 삭제하지 않은 ref 는 보존했습니다.\n' >&2
  printf 'archive:   앞서 검증을 통과해 삭제된 ref 는 복구하지 않습니다 (해당 커밋은 merge 대상에 모두 포함되어 손실 없음).\n' >&2
  exit 1
fi

# 기록 실패 종료 — `[[ ... ]] && exit 1` 꼴은 값이 0 일 때 마지막 명령 상태가 1 이라 쓰지 않는다.
if [[ "$RECORD_FAILED" -eq 1 ]]; then
  exit 1
fi
exit 0
