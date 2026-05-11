#!/usr/bin/env bash
# Lifecycle 공통 함수 — git 상태 / remote 검출 / metadata I/O / branch ref helpers

LIFECYCLE_METADATA_PATH="${LIFECYCLE_METADATA_PATH:-rd-workflow-workspace/.lifecycle/active-fr}"

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

# main worktree path 검출 — whitespace-safe full-line extraction
get_main_worktree_path() {
  local p
  p="$(git worktree list --porcelain | awk '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0=="branch refs/heads/main"{print p; exit}
  ')"
  if [[ -z "$p" ]]; then
    printf 'get_main_worktree_path: no worktree on refs/heads/main\n' >&2
    return 1
  fi
  printf '%s\n' "$p"
}

# Lifecycle metadata I/O (key=value lines)
metadata_read_field() {
  local key="$1"
  # Returns empty stdout if file missing OR key missing OR value empty.
  # Callers should use metadata_exists() + [[ -n "$val" ]] for full check.
  [[ -f "$LIFECYCLE_METADATA_PATH" ]] || return 0
  awk -F'=' -v k="$key" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$LIFECYCLE_METADATA_PATH"
}

metadata_write() {
  local fr_branch="$1" short_title="$2" worktree_path="$3"
  if [[ "$fr_branch" == *$'\n'* || "$short_title" == *$'\n'* || "$worktree_path" == *$'\n'* ]]; then
    printf 'metadata_write: values must not contain newlines\n' >&2; return 1
  fi
  mkdir -p "$(dirname "$LIFECYCLE_METADATA_PATH")"
  cat > "$LIFECYCLE_METADATA_PATH" <<EOF
fr-branch=$fr_branch
short-title=$short_title
worktree-path=${worktree_path:-null}
created-at=$(date +%Y-%m-%d-%H%M)
status=active
EOF
}

metadata_clear() {
  [[ -f "$LIFECYCLE_METADATA_PATH" ]] && rm -f "$LIFECYCLE_METADATA_PATH"
  return 0
}

metadata_exists() {
  [[ -f "$LIFECYCLE_METADATA_PATH" ]]
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
