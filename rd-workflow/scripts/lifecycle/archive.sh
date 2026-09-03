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
  printf 'archive: WARNING — dirty state 로 진행 (--force-dirty 는 이 clean 검사만 넘깁니다)\n' >&2
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

# Step 3 — merge (idempotent)
if git merge-base --is-ancestor "$FR_BRANCH" HEAD 2>/dev/null; then
  printf 'archive: %s 이미 merge 됨 — skip\n' "$FR_BRANCH"
else
  git merge --no-ff "$FR_BRANCH" -m "merge: $SLUG (autopilot 완료)" || {
    printf 'archive: merge 실패 — conflict resolve 후 재실행\n' >&2; exit 1
  }
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
BASELINE_OID=""
_bl_rc=0
BASELINE_OID="$(archive_baseline_commit "$CURRENT_WT" "$FR_BRANCH" "$MERGE_BASE_COMMIT")" || _bl_rc=$?
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
archive_extra_commits_check "$CURRENT_WT" "$BASELINE_OID" "$MERGE_BASE_COMMIT" || _ec_rc=$?
if [[ "$_ec_rc" -eq 2 ]]; then
  printf 'archive: 얹힌 커밋 판정에 필요한 git 명령이 실패했습니다 — 중단합니다\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
elif [[ "$_ec_rc" -ne 0 ]]; then
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT"
  exit 1
fi

# Step 3.5 (제거, 2026-09-03) — 이 자리에서 self_test consumer 전수를 강제하고 증명을 대조하던
# 게이트를 걷어냈다. 검증은 구현 직후 사람이 self_test.sh (그룹 지정) 로 돌리고 final diff review 가
# 그 결과를 확인한다. 아카이브가 같은 검증을 다시 돌려 얻는 것은 없었고 매번 15~20분을 썼다.

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
  # staging·커밋을 진행하면 남은 경로가 조용히 빠진다 (final diff review Turn 002 F3).
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
    esac
    _lc_paths+=( "$CURRENT_WT/$_lc_rel" )
  done <<EOF
$_lc_paths_out
EOF
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
# 이어야 검사와 발행 사이의 경쟁 창이 닫힌다 (REQUEST review Turn 004 Finding 2).
PUBLISH_OID="$(git rev-parse HEAD)" || {
  printf 'archive: 발행 후보 commit 결정 실패 — 중단\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
}

# 경로 판정을 발행 후보 기준으로 다시 한 번. merge 이후 기본 브랜치가
# 전진했을 수 있고, Step 4 의 metadata 커밋도 이 시점에는 얹힌 커밋에 포함된다
# (허용 경로만 담으므로 자연히 통과한다).
_ec2_rc=0
archive_extra_commits_check "$CURRENT_WT" "$BASELINE_OID" "$PUBLISH_OID" || _ec2_rc=$?
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
archive_publish_content_check "$CURRENT_WT" "$BASELINE_OID" "$PUBLISH_OID" || _pc_rc=$?
if [[ "$_pc_rc" -eq 2 ]]; then
  # rc 2 는 git 실행 오류와 **허용 경로 목록 생성 실패**를 함께 담는다 — 둘 다 "검사
  # 자체가 불가능" 이며, 파일 내용을 되돌려서 해결되는 상태가 아니다. 그래서 사유를
  # git 오류로 단정하지 않는다 (final diff review Turn 004 F6).
  printf 'archive: 발행 내용을 판정할 수 없습니다 (git 실행 오류 또는 허용 경로 목록 생성 실패) — 중단합니다\n' >&2
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" unknown
  exit 1
elif [[ "$_pc_rc" -ne 0 ]]; then
  archive_block_notice "$FR_BRANCH" "$CURRENT_WT" content
  exit 1
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
# 같은 결속이 있어야 check→publish 경쟁 창이 닫힌다 (final diff review Turn 002 F1).
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
  # 그래서 막지 않고 두 OID 와 로컬을 맞추는 명령을 명시적으로 보여 준다
  # (final diff review Turn 004 F5).
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
