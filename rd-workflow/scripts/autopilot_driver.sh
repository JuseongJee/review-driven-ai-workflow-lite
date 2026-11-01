#!/usr/bin/env bash
# autopilot_driver.sh — autopilot 실행 주체 표식 관리 (begin / end / check)
# 표식: <git common dir>/rd-workflow/autopilot-driver.<slug>, 내용 `created-at=<값>` 한 줄.
# begin 은 실패를 숨기지 않는다(exit 2 + stderr). end·check 는 fail-open.
set -uo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state="${project_root}/rd-workflow-workspace/.lifecycle/task-state"

_read() {
  [[ -f "$state" ]] || return 0
  awk -F'=' -v k="$1" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$state"
}

_slug_ok() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

_marker() {
  local common
  common="$(git -C "$project_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  printf '%s\n' "${common}/rd-workflow/autopilot-driver.$1"
}

# 활성 작업 판정. 어긋나면 사유를 stdout 으로 내고 return 1.
_active() {
  local slug created frb head
  slug="$(_read short-title)"
  created="$(_read created-at)"
  frb="$(_read fr-branch)"
  if ! _slug_ok "$slug"; then echo "short-title 이 slug 형식이 아닙니다 (${slug:-비어 있음})"; return 1; fi
  if [[ -z "$created" ]]; then echo "created-at 이 없습니다"; return 1; fi
  if [[ -z "$frb" || "$frb" == "null" ]]; then echo "fr-branch 가 없습니다 (활성 작업 아님)"; return 1; fi
  head="$(git -C "$project_root" symbolic-ref --short HEAD 2>/dev/null)" || head=""
  if [[ "$head" != "$frb" ]]; then echo "현재 브랜치(${head:-detached})가 fr-branch(${frb})와 다릅니다"; return 1; fi
  return 0
}

_usage() { echo "사용법: autopilot_driver.sh begin|end|check" >&2; exit 2; }

cmd_begin() {
  local reason slug created marker
  if ! reason="$(_active)"; then
    echo "autopilot_driver: begin 거부 — ${reason}" >&2
    exit 2
  fi
  slug="$(_read short-title)"
  created="$(_read created-at)"
  if ! marker="$(_marker "$slug")"; then
    echo "autopilot_driver: begin 거부 — git common dir 을 구하지 못했습니다" >&2
    exit 2
  fi
  if ! mkdir -p "$(dirname "$marker")" || ! printf 'created-at=%s\n' "$created" > "$marker"; then
    echo "autopilot_driver: begin 거부 — 표식을 쓰지 못했습니다 (${marker})" >&2
    exit 2
  fi
  exit 0
}

cmd_end() {
  local slug marker
  slug="$(_read short-title)"
  _slug_ok "$slug" || exit 0
  marker="$(_marker "$slug")" || exit 0
  rm -f "$marker" 2>/dev/null
  exit 0
}

cmd_check() {
  local slug created marker
  _active >/dev/null 2>&1 || exit 1
  slug="$(_read short-title)"
  created="$(_read created-at)"
  marker="$(_marker "$slug" 2>/dev/null)" || exit 1
  [[ -f "$marker" ]] || exit 1
  [[ "$(cat "$marker" 2>/dev/null)" == "created-at=${created}" ]] || exit 1
  exit 0
}

case "${1:-}" in
  begin) cmd_begin ;;
  end) cmd_end ;;
  check) cmd_check ;;
  *) _usage ;;
esac
