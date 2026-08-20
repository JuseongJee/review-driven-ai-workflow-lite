#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"
source "$SCRIPT_DIR/_lifecycle_common.sh"

DRY_RUN=0; FORCE_DIRTY=0; NO_REMOTE=0; FR_BRANCH_OVERRIDE=""; FORCE_SKIP_REVIEW=0; SKIP_REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fr-branch) FR_BRANCH_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force-dirty) FORCE_DIRTY=1; shift ;;
    --no-remote) NO_REMOTE=1; shift ;;
    --force-skip-review-check)
      FORCE_SKIP_REVIEW=1
      # 다음 토큰이 없거나 -로 시작하면 사유 누락 → 빈 값 유지 (precheck에서 차단)
      if [[ $# -ge 2 && "$2" != -* ]]; then SKIP_REASON="$2"; shift 2; else shift 1; fi
      ;;
    -h|--help) printf '%s\n' "usage: archive.sh [--fr-branch <ref>] [--no-remote] [--force-dirty] [--force-skip-review-check <사유>] [--dry-run]"; exit 0 ;;
    *) printf 'archive: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# Step 0 — 기본 브랜치 worktree 검증
MAIN_WT="$(get_main_worktree_path)" || { printf 'archive: 기본 브랜치 worktree 검출 실패\n' >&2; exit 1; }
CURRENT_WT="$(git rev-parse --show-toplevel)" || {
  printf 'archive: git repo 외부에서 실행 불가\n' >&2; exit 1
}
if [[ "$MAIN_WT" != "$CURRENT_WT" ]]; then
  DB="$(get_default_branch)"
  printf 'archive: 기본 브랜치(%s) worktree에서만 호출 가능. 해당 worktree path: %s\n' "$DB" "$MAIN_WT" >&2; exit 1
fi

# Step 0 — clean state (unless --force-dirty)
if [[ "$FORCE_DIRTY" -eq 0 ]]; then
  ensure_worktree_clean || { printf 'archive: worktree dirty — git status 확인 후 commit/stash 후 재실행\n' >&2; exit 1; }
elif ! ensure_worktree_clean; then
  # 문구를 "강제 진행" 으로만 쓰면 네 줄 아래 전수 검증 게이트의 중단(워킹트리≠HEAD)과
  # 한 화면에서 모순돼 보입니다. 이 플래그의 실제 효과는 **이 clean 검사 하나**입니다.
  printf 'archive: WARNING — dirty state 로 진행 (--force-dirty 는 이 clean 검사만 넘깁니다. 전수 검증 게이트는 워킹트리=HEAD 를 그대로 요구합니다)\n' >&2
fi

# FR identity source-of-truth
FR_BRANCH="$FR_BRANCH_OVERRIDE"
if [[ -z "$FR_BRANCH" ]]; then
  FR_BRANCH="$(metadata_read_field fr-branch)"
fi
if [[ -z "$FR_BRANCH" ]]; then
  printf 'archive: active fr 없음. promote.sh 호출 후 archive 가능합니다.\n' >&2; exit 1
fi
[[ "$FR_BRANCH" == fr/* ]] || { printf 'archive: 잘못된 fr ref: %s\n' "$FR_BRANCH" >&2; exit 1; }

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

SLUG="${FR_BRANCH#fr/}"
REMOTE_MODE="$(detect_remote_mode)"
[[ "$NO_REMOTE" -eq 1 ]] && REMOTE_MODE="local-only"

# remote tag preflight (hard-stop on fetch failure)
if [[ "$REMOTE_MODE" == "remote" ]]; then
  git fetch --tags origin >/dev/null 2>&1 || {
    printf 'archive: git fetch --tags origin 실패 — preflight 중단. 네트워크/권한 확인 후 재실행 또는 --no-remote 사용.\n' >&2
    exit 1
  }
fi

# Rerun 안전망 — fr branch 부재 + 동일 slug tag 존재 = 이미 archive 완료
if ! git rev-parse --verify "$FR_BRANCH" >/dev/null 2>&1; then
  EXISTING_TAG="$(git tag --list "fr/*/$SLUG" 2>/dev/null | head -1)"
  if [[ -n "$EXISTING_TAG" ]]; then
    printf 'archive: 이미 archive 완료 — nothing to do (tag=%s)\n' "$EXISTING_TAG"
    exit 0
  fi
  printf 'archive: branch %s 미존재\n' "$FR_BRANCH" >&2; exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'would archive: branch=%s (tag는 cleanup commit 부착 후 결정)\n' "$FR_BRANCH"; exit 0
fi

# review 종결성 자체 검증 (dry-run exit 이후 = 실제 archive 경로에만 실행, dry-run 비파괴성 보존).
# 판정/audit/사유검증은 헬퍼에 위임.
project_root="$CURRENT_WT"
source "$SCRIPT_DIR/../hooks/_guard_common.sh"
AUDIT_LOG="$CURRENT_WT/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
archive_review_precheck "$FORCE_SKIP_REVIEW" "$SKIP_REASON" "$SLUG" "$AUDIT_LOG" "$FR_BRANCH" || exit 1

# Step 2 — archive content 휴리스틱 (warning만)
LAST_COMMIT_FILES="$(git log -1 "$FR_BRANCH" --name-only --pretty=format: 2>/dev/null || true)"
if ! grep -qE '(^|/)(REQUEST\.md|CURRENT_TASK\.md|FUTURE_REQUESTS\.md|request-archive/.*\.md)' <<<"$LAST_COMMIT_FILES"; then
  printf 'archive: WARNING — fr branch 마지막 commit 에 archive content 미감지\n' >&2
fi

# Step 2.5 — 증명 전제를 **merge 전에** 확인 (final diff review 2026-08-20 turn 004 Finding 1)
#
# Step 3.5 의 게이트도 같은 확인을 하지만, 거기서 실패하면 **main 은 이미 merge 된 뒤**입니다.
# 그리고 그 실패 사유가 dirty 이면 아래 rollback 이 clean 을 요구하므로 발동하지 못해
# merge 가 그대로 남습니다. 특히 `--force-dirty` 는 이 상태를 **정상 호출로 만들어** 줍니다.
# 그 뒤 사용자가 안내대로 main 에서 commit 하고 재실행하면 fr 이 이미 조상이라 merge 가
# skip 되고, **예전 fr tip 리뷰만으로 그 main commit 이 발행**됩니다.
#
# 여기서 먼저 막으면 main 이 아예 움직이지 않아 그 경로가 생기지 않습니다. 어차피 Step 3.5
# 에서 같은 사유로 막힐 것이므로 **차단 결과는 같고 부작용만 없앱니다** — `--force-dirty` 가
# 전수 검증 게이트를 넘지 못한다는 것은 이미 문서화된 계약입니다.
archive_selftest_preconditions "$CURRENT_WT" || {
  printf 'archive: merge 전에 중단했습니다 — main 은 움직이지 않았습니다\n' >&2
  exit 1
}

# Step 3 — merge (idempotent)
#
# **이 지점의 HEAD 를 기억해 둡니다** — Step 3.5 의 전수 검증이 실패하면 여기로 되돌립니다.
# 이유는 아래 rollback 블록 주석에 있습니다.
PRE_MERGE_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
MERGE_CREATED_HERE=0
if git merge-base --is-ancestor "$FR_BRANCH" HEAD 2>/dev/null; then
  printf 'archive: %s 이미 merge 됨 — skip\n' "$FR_BRANCH"
else
  git merge --no-ff "$FR_BRANCH" -m "merge: $SLUG (autopilot 완료)" || {
    printf 'archive: merge 실패 — conflict resolve 후 재실행\n' >&2; exit 1
  }
  MERGE_CREATED_HERE=1
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

# Step 3.5 — 전수 검증(self_test full) 통과 강제 (change spec §5.5)
#
# 위치가 계약의 일부입니다. 이 게이트는 "지금 워킹트리 내용" 의 지문을 증명과 대조하므로:
#   - merge **뒤**여야 합니다. 머지 전 기본 브랜치 워킹트리에는 fr 내용이 없어 증명이
#     구조적으로 항상 불일치하고, 게이트가 매번 무의미한 전수 검증을 강요합니다.
#   - Step 4 **앞**이어야 합니다. Step 4 는 CURRENT_TASK.md 와 task-state 를 baseline 으로
#     덮어쓰는데 둘 다 tracked = 증명 대상이라, 뒤에 두면 지문이 다시 구조적으로
#     불일치합니다.
#   - tag·push **앞**이어야 합니다. 게이트 뒤에 오는 변경이 적을수록 발행물과 검증
#     대상이 가까워집니다.
# 이 세 조건을 동시에 만족하는 구간은 여기뿐입니다 (lifecycle 테스트가 이 순서를
# 단언합니다).
#
# **게이트 이후 변경은 Step 4 의 metadata baseline 복원 2파일(CURRENT_TASK.md·task-state)
# 뿐입니다.** 둘 다 증명 집합에 속하므로 tag 가 가리키는 트리는 전수 검증이 본 트리와
# 정확히 같지는 않습니다 — "미검증 내용이 전혀 발행되지 않는다" 고 읽지 마십시오.
# 배치 제약상 불가피하고 delta 가 결정적인 baseline 복원으로 한정되어 실질 위험은
# 낮습니다. 이 두 파일 밖의 변경을 게이트 뒤로 옮기면 그 순간 이 서술이 거짓이 됩니다.
#
# 우회 밸브를 두지 않습니다. 커밋 전 게이트에는 사용자 승인 우회가 있고 이 저장소는
# 인프라 커밋이 대부분이라 상시 우회됩니다 — 통합 직전인 이 지점이 축소 실행(smoke)이
# 놓친 것을 반드시 잡는 유일한 지점입니다. 판정·실행·재대조는 전부 헬퍼가 하고 여기서는
# 호출만 합니다 (그래야 실행 여부와 rc 반영을 격리 fixture 로 회귀 고정할 수 있습니다).
if ! archive_selftest_gate "$CURRENT_WT"; then
  # **실패하면 이 실행이 만든 merge 를 되돌립니다.**
  #
  # 되돌리지 않으면 이런 경로가 생깁니다 (final diff review 2026-08-20 Finding 2):
  #   merge 성공 → 전수 검증 실패 → 사용자가 **지금 보고 있는 main 워킹트리**에서 고쳐 커밋
  #   → 재실행 → review precheck 는 여전히 **예전 fr tip** 만 보고 통과하고, fr 이 이미
  #   조상이라 merge 는 skip → 리뷰된 적 없는 main 커밋이 tag·push 됩니다.
  # 공격적 우회가 아니라 **정상적인 복구 행동**에서 발생합니다. 실패 안내가 수정 위치를
  # 제한하지 않고, 이 브랜치에서 main 직접 커밋을 막던 fr_branch_gate 도 제거됐기 때문입니다.
  #
  # main 을 merge 이전으로 되돌리면 고칠 곳이 fr branch 밖에 남지 않아 경로가 끊깁니다.
  # 잃는 것은 없습니다 — fr branch 가 내용을 그대로 들고 있고, 재실행하면 다시 merge 합니다.
  #
  # **완전한 처방은 아닙니다.** 사용자가 전수 검증 도중 중단하면 여기에 닿지 못해 merge 가
  # 남습니다. 그 구간까지 닫으려면 archive 시작 시점의 main 을 lifecycle 상태로 남기고
  # 재실행 때 대조해야 하며, 새 상태 파일과 계약이 필요해 FR
  # `archive-retry-unreviewed-main-commit` 로 분리했습니다.
  #
  # 되돌리기는 **이 실행이 만든 merge 가 HEAD 그대로일 때만** 합니다. 그 뒤에 무엇이든
  # 얹혔거나 워킹트리가 더러우면 사람의 것을 지울 수 있으므로 손대지 않고 알리기만 합니다.
  #
  # clean 판정은 **증명과 같은 제외 규칙**을 써야 합니다. raw `git status --porcelain` 은
  # `.lifecycle/*.log` 같은 일시 산출물까지 더럽다고 보는데, 그것들은 증명 대상이 아니라
  # 아카이브가 스스로 만드는 파일입니다. 더 엄격하게 잡으면 **정당한 되돌리기가 스스로
  # 막혀** 되돌림이 죽은 코드가 됩니다 (통합 테스트가 실제로 이 상태를 잡았습니다 —
  # `--force-skip-review-check` 가 쓰는 audit log 하나 때문에 발동하지 않았습니다).
  # 헬퍼를 못 읽으면 raw 판정으로 내려갑니다 — 그쪽이 더 엄격해 되돌리지 않을 뿐이라 안전합니다.
  _rb_specs=(".") _rb_sp=""
  # 게이트는 헬퍼를 서브셸에서 읽으므로 이 스코프에는 남지 않습니다. 여기서 한 번 더 읽습니다
  # (quiet — 실패해도 아래 raw 판정으로 내려가면 되고, 사유는 게이트가 이미 냈습니다).
  if ! declare -F smoke_proof_exclude >/dev/null 2>&1; then
    _archive_selftest_helper_load "$CURRENT_WT" quiet || true
  fi
  if declare -F smoke_proof_exclude >/dev/null 2>&1; then
    while IFS= read -r _rb_sp; do [[ -n "$_rb_sp" ]] && _rb_specs+=("$_rb_sp"); done < <(smoke_proof_exclude)
  fi
  # **`git -C "$CURRENT_WT"` 가 필수입니다.** `.` pathspec 은 **호출 위치 기준**이라, 저장소
  # 하위 디렉터리에서 archive 를 부르면(Step 0 은 main worktree 안이기만 하면 통과하므로
  # 지원되는 형태입니다) 그 prefix 밖의 변경이 판정에서 통째로 빠집니다. clean 으로 오판하면
  # 바로 아래 `git reset --hard` 가 **저장소 전체를 되돌려 사용자 변경을 지웁니다** —
  # "사람의 것을 지우지 않는다" 는 이 가드의 존재 이유가 정확히 뒤집힙니다.
  # (실측: 같은 시점에 하위 디렉터리 `status -- .` 은 0건, 저장소 루트는 5건이었습니다.)
  _rb_dirty="$(git -C "$CURRENT_WT" status --porcelain -- ${_rb_specs[@]+"${_rb_specs[@]}"} 2>/dev/null || echo dirty)"
  if [[ "$MERGE_CREATED_HERE" -eq 1 && -n "$PRE_MERGE_HEAD" ]] \
     && [[ "$(git rev-parse HEAD 2>/dev/null || true)" == "$MERGE_BASE_COMMIT" ]] \
     && [[ -z "$_rb_dirty" ]]; then
    if git reset --hard "$PRE_MERGE_HEAD" >/dev/null 2>&1; then
      printf 'archive: 전수 검증이 실패해 이 실행이 만든 merge 를 되돌렸습니다 (main = %s)\n' \
        "$(git rev-parse --short "$PRE_MERGE_HEAD")" >&2
      printf 'archive:   원인은 **%s 브랜치에서** 고치고 diff review 를 거친 뒤 다시 실행하십시오\n' \
        "$FR_BRANCH" >&2
      printf 'archive:   main 에서 직접 고치면 그 수정은 리뷰를 거치지 않은 채 발행됩니다\n' >&2
    else
      printf 'archive: 전수 검증 실패 후 merge 되돌리기에 실패했습니다 — main 이 merge 된 상태로 남았습니다\n' >&2
      printf 'archive:   **main 에서 직접 고치지 마십시오.** %s 브랜치에서 고쳐야 리뷰를 거칩니다\n' "$FR_BRANCH" >&2
    fi
  else
    printf 'archive: merge 는 이 실행이 만들지 않았거나 이후 변경이 있어 그대로 둡니다\n' >&2
    printf 'archive:   **main 에서 직접 고치지 마십시오.** %s 브랜치에서 고쳐야 리뷰를 거칩니다\n' "$FR_BRANCH" >&2
  fi
  exit 1
fi

# Step 4 — metadata cleanup commit on main (publish 전)
if metadata_exists; then
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
  metadata_clear
  state_write_fields "short-title=-" "status=대기 중"

  # 이 커밋에 포함할 경로 — 판정과 커밋 양쪽에 같은 목록을 쓴다
  _lc_paths=( "$TASK_STATE_PATH" "$_ct_path" )
  # staging 은 두 파일 모두 성공해야 한다. CURRENT_TASK.md staging 이 실패해도 task-state
  # 변경 때문에 아래 git diff --cached --quiet 가 non-quiet 이 되어 커밋이 진행되고,
  # 미러가 빠진 채 tag·push 로 이어진다.
  # v2 2b: LIFECYCLE_METADATA_PATH 폐지 → TASK_STATE_PATH 사용
  if ! git add "$TASK_STATE_PATH" "$_ct_path"; then
    printf 'archive: task-state·CURRENT_TASK.md staging 실패 — 중단\n' >&2
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
  # legacy active-fr 잔재가 tracked 파일로 존재하면 삭제분도 staged (metadata_clear가 rm -f 처리)
  _legacy_afr_path="$CURRENT_WT/rd-workflow-workspace/.lifecycle/active-fr"
  # "선택" 은 경로의 존재 여부에만 적용된다. tracked 임이 확인된 경로는 metadata_clear 가
  # 이미 삭제한 cleanup 대상이므로, 그 add 실패는 선택 사항이 아니라 중단 사유다.
  # 경고 후 진행하면 archive 가 tag·push 까지 성공한 것처럼 보이면서 워킹트리에 삭제가
  # 남고 metadata 커밋이 불완전해진다 (rollback 필수 경로·기존 archive 선례와 같은 원칙).
  if git ls-files --error-unmatch "$_legacy_afr_path" >/dev/null 2>&1; then
    if ! git add "$_legacy_afr_path"; then
      printf 'archive: legacy active-fr staging 실패 — 중단\n' >&2
      exit 1
    fi
    _lc_paths+=( "$_legacy_afr_path" )
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

# Step 5 — Tag (HEAD = cleanup commit, rerun reuse)
TARGET_TAG="$(git tag --list "fr/*/$SLUG" --points-at HEAD 2>/dev/null | head -1)"
if [[ -z "$TARGET_TAG" ]]; then
  TS="$(date +%Y-%m-%d-%H%M)"
  TARGET_TAG="$(resolve_unique_ref tag "fr/$TS/$SLUG")" || {
    printf 'archive: tag ref 생성 실패 (%s, TS=%s)\n' "$SLUG" "$TS" >&2; exit 1
  }
fi

if git rev-parse --verify "refs/tags/$TARGET_TAG" >/dev/null 2>&1; then
  EXISTING="$(git rev-parse "refs/tags/$TARGET_TAG^{commit}")"
  HEAD_REV="$(git rev-parse HEAD)"
  [[ "$EXISTING" == "$HEAD_REV" ]] || {
    printf 'archive: tag %s 충돌 (다른 commit) — 수동 해결 후 재실행: git tag -d %s\n' "$TARGET_TAG" "$TARGET_TAG" >&2
    exit 1
  }
  printf 'archive: tag %s 이미 존재 (HEAD 가리킴) — skip\n' "$TARGET_TAG"
else
  git tag "$TARGET_TAG" -m "archive: $SLUG @ $(date +"%Y-%m-%d %H:%M")"
  printf 'archive: tag %s 부착 (cleanup commit 가리킴)\n' "$TARGET_TAG"
fi

# Step 6 — Remote publish (blocking)
if [[ "$REMOTE_MODE" == "remote" ]]; then
  DEFAULT_BRANCH="$(get_default_branch)" || { printf 'archive: 기본 브랜치 결정 실패 — push 중단\n' >&2; exit 1; }
  git push origin "$DEFAULT_BRANCH" || { printf 'archive: %s push 실패 — 재실행으로 복구\n' "$DEFAULT_BRANCH" >&2; exit 1; }
  git push origin "$TARGET_TAG" || { printf 'archive: tag push 실패 — 재실행으로 복구\n' >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# post-success cleanup 경계
# core 산출물(merge · metadata cleanup commit · tag · push)이 만들어진 이후 단계는
# 개별 실패가 스크립트를 중단시키지 않는다. 미완 항목을 모아 종료 직전에 한 번에 요약한다.
# 잔여 레코드 형식: <kind>\t<identifier>\t<reason>\t<command>
#   kind    ∈ worktree | local-branch | remote-branch | loop-state
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
if ! WT_COUNT_BEFORE="$(wt_match_count)"; then
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
    if ! git worktree remove "$fr_wt"; then
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
if [[ "$WORKTREE_PENDING" -eq 1 ]]; then
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
if [[ "$REMOTE_MODE" == "remote" ]]; then
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
