#!/usr/bin/env bash
# Lifecycle 공통 함수 — git 상태 / remote 검출 / metadata I/O / branch ref helpers
# v2 Phase 2b: metadata_* 함수는 task-state(_state_common.sh)를 대상으로 동작.
# LIFECYCLE_METADATA_PATH 변수 폐지 — TASK_STATE_PATH 경유 (env override는 TASK_STATE_PATH 사용).

# _state_common.sh 로드 — task-state 단일 상태 파일 I/O 제공
source "$(dirname "${BASH_SOURCE[0]}")/../_state_common.sh"

# detect_remote_mode: stdout = "remote" | "local-only"
detect_remote_mode() {
  if [[ -n "${RD_LIFECYCLE_NO_REMOTE:-}" ]]; then printf 'local-only\n'; return 0; fi
  if git remote get-url origin >/dev/null 2>&1; then printf 'remote\n'; else printf 'local-only\n'; fi
}

# ensure_worktree_clean: exit 0 if clean, 1 if dirty
ensure_worktree_clean() {
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then return 0; fi
  return 1
}

# resolve_unique_ref <kind=branch|tag> <base>: 충돌 시 -N suffix 적용한 ref 반환
resolve_unique_ref() {
  local kind="$1" base="$2"
  local ref_prefix
  case "$kind" in
    branch) ref_prefix="refs/heads/" ;;
    tag) ref_prefix="refs/tags/" ;;
    *) printf 'resolve_unique_ref: unknown kind: %s\n' "$kind" >&2; return 1 ;;
  esac
  local candidate="$base"
  local n=2
  # cap at base-100 to prevent runaway loops (Nit N2)
  while git rev-parse --verify "${ref_prefix}${candidate}" >/dev/null 2>&1; do
    [[ $n -gt 100 ]] && { printf 'resolve_unique_ref: too many collisions for %s\n' "$base" >&2; return 1; }
    candidate="${base}-${n}"
    n=$((n+1))
  done
  printf '%s\n' "$candidate"
}

# 전제: 원격 추적은 origin remote 기준 (refs/remotes/origin/HEAD 조회·origin/ strip).
# origin 외 remote(upstream 등)만 있는 구성은 미지원 — workflow.json "default_branch" 설정으로 우회.
# 기본 브랜치 결정 — config(default_branch) → origin/HEAD → main/master 유일 매치 → 에러
# 빈 config 값("")은 미설정으로 간주하고 다음 체인으로 진행한다.
# stdout: 브랜치명 1줄. 실패/모호 시 stderr 안내 + return 1.
get_default_branch() {
  local cfg="${project_root:-$PWD}/rd-workflow/config/workflow.json"
  local b=""
  if [[ -f "$cfg" ]]; then
    b="$(sed -n 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
  fi
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  b="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  b="${b#origin/}"
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  local has_main=0 has_master=0
  if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then has_main=1; fi
  if git show-ref --verify --quiet refs/heads/master 2>/dev/null; then has_master=1; fi
  if (( has_main + has_master == 1 )); then
    if (( has_main )); then printf 'main\n'; else printf 'master\n'; fi
    return 0
  fi
  printf 'get_default_branch: 기본 브랜치를 결정할 수 없습니다 — rd-workflow/config/workflow.json 에 "default_branch" 를 설정하세요\n' >&2
  return 1
}

# main(기본 브랜치) worktree path 검출 — whitespace-safe full-line extraction
get_main_worktree_path() {
  local b p
  b="$(get_default_branch)" || return 1
  p="$(git worktree list --porcelain | awk -v ref="branch refs/heads/$b" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0==ref{print p; exit}
  ')"
  if [[ -z "$p" ]]; then
    printf 'get_main_worktree_path: no worktree on refs/heads/%s\n' "$b" >&2
    return 1
  fi
  printf '%s\n' "$p"
}

# Lifecycle metadata I/O — task-state 대상 (v2 Phase 2b, 시그니처 불변)

# metadata_read_field <key>: task-state에서 값 읽기 (파일/키 부재 시 빈 출력)
# task-state 부재 시에만 legacy active-fr 파일에서 같은 키를 읽는 read-only fallback 적용.
# task-state 존재 시 절대 legacy를 읽지 않음 (guard hook fallback 원칙).
metadata_read_field() {
  local key="$1"
  if state_file_exists; then
    state_read_field "$key"
  else
    local _legacy_afr="${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/active-fr"
    if [[ -f "$_legacy_afr" ]]; then
      awk -F'=' -v k="$key" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$_legacy_afr"
    fi
  fi
}

# metadata_write <fr-branch> <short-title> <worktree-path> [source-fr]: task-state에 4필드 + created-at 기록
# 4번째 인자는 optional (기본 '-') — 기존 3인자 호출과 호환 (trailing optional 확장만 허용)
metadata_write() {
  local fr_branch="$1" short_title="$2" worktree_path="$3" source_fr="${4:--}"
  if [[ "$fr_branch" == *$'\n'* || "$short_title" == *$'\n'* || "$worktree_path" == *$'\n'* || "$source_fr" == *$'\n'* ]]; then
    printf 'metadata_write: values must not contain newlines\n' >&2; return 1
  fi
  state_write_fields \
    "fr-branch=$fr_branch" \
    "short-title=$short_title" \
    "worktree-path=${worktree_path:-null}" \
    "source-fr=${source_fr:--}" \
    "created-at=$(date +%Y-%m-%d-%H%M)"
}

# metadata_clear: fr-branch=null, worktree-path=null, source-fr=- reset + created-at 줄 제거 (파일 삭제 아님)
# legacy active-fr 파일이 잔존하면 함께 삭제 (merge 후 main에 남는 legacy 잔재 정리).
metadata_clear() {
  state_file_exists || return 0
  state_write_fields "fr-branch=null" "worktree-path=null" "source-fr=-"
  # created-at 줄 제거 (fr 비활성 시 부재 계약)
  local tmp
  tmp="$(mktemp "$(dirname "$TASK_STATE_PATH")/.task-state.XXXXXX")"
  awk -F'=' '$1!="created-at"' "$TASK_STATE_PATH" > "$tmp" && mv "$tmp" "$TASK_STATE_PATH"
  # legacy active-fr 잔재 정리 (archive cleanup 커밋에 자연 포함)
  local _legacy_afr="${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/active-fr"
  [[ -f "$_legacy_afr" ]] && rm -f "$_legacy_afr"
  return 0
}

# metadata_exists: fr-branch 값이 비어있지 않고 null이 아니면 참 (파일 존재 여부가 아님)
# 존재 판정도 읽기와 동일한 legacy fallback을 공유 — pre-migration repo의 active 작업 보호
metadata_exists() {
  local v; v="$(metadata_read_field "fr-branch")"
  [[ -n "$v" && "$v" != "null" ]]
}

# CURRENT_TASK.md baseline form (Reviewer Turn 008 Issue 2 — runtime accessible inline heredoc)
emit_current_task_baseline() {
  cat <<'EOF'
# Current Task

## Task
-

## Short Title
-

## Status
대기 중

## Request
[REQUEST.md](REQUEST.md)

## Spec
-

## Plan
-

## Branch / Worktree
main

## Output Files
-

## Next Step
-

## Notes
-
EOF
}

# Claude Code 가 설치하는 .git/hooks/pre-commit 은 브랜치명이 main|master 일 때만 커밋을
# 차단합니다. trunk 등 커스텀 기본 브랜치에서는 차단되지 않으므로 --no-verify 를 붙일 이유가
# 없고, 붙이면 소비 프로젝트의 pre-commit·commit-msg 검증만 불필요하게 줄어듭니다.
lifecycle_needs_hook_bypass() {
  local b
  b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ "$b" == "main" || "$b" == "master" ]]
}

# lifecycle 커밋은 git pre-commit·commit-msg hook 을 --no-verify 로 건너뛴다.
# 우회 사실과 그 범위를 사용자에게 알린다 — "pre-commit 우회" 같은 축약은 금지다.
# 사용자가 무엇이 실행되지 않았는지 읽어서 알 수 있어야 한다 (change spec 결정 4).
# 반드시 커밋 직후에 호출한다 — staged 잔여 건수가 커밋 후 index 기준이어야 정확하다.
# 실제로 우회한 경우에만 호출한다 — 우회하지 않았는데 이 안내를 내보내면 거짓이다.
# $1: 호출 스크립트 이름 (promote | promote_rollback | archive)
lifecycle_notify_hook_bypass() {
  local script="$1"
  printf '%s: pre-commit·commit-msg hook 을 건너뛰고 커밋했습니다 — 프로젝트 자체 lint·포맷 검사와 커밋 메시지 정책 검사가 실행되지 않았습니다.\n' "$script"
  local leftover
  leftover="$(git diff --cached --name-only 2>/dev/null | grep -c . || true)"
  if [[ "$leftover" -gt 0 ]]; then
    printf '  (staged 변경 %s건은 lifecycle 커밋에 포함하지 않았습니다 — 그대로 남아 있습니다.)\n' "$leftover"
  fi
}
