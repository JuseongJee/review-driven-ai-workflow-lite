#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

read_hook_input
cmd="$(extract_json_field "command")"

[[ -z "$cmd" ]] && exit 0

# command 안의 어떤 sub-command 라도 실제 git commit invocation 이면 commit 으로 판정.
# sub-command 시작 boundary: 라인 시작, ;, &&, ||, |, (, )
# 허용 invocation prefix:
#   git commit ...
#   env [VAR=val ...] git commit ...
#   VAR=val [VAR=val ...] [env ...] git commit ...
# 차단 예 (substring false positive): echo git commit, cat git commit log, git commitments
# 차단 예 (spoof): echo RD_LIFECYCLE_BYPASS_REASON=... && git commit ...
#                 — 두 번째 sub-command 는 RD_LIFECYCLE_BYPASS_REASON prefix 없는 git commit 이므로 commit 으로 판정
if ! [[ "$cmd" =~ (^|[\;\&\|\(\)][[:space:]]*)((env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(env[[:space:]]+)?)?git[[:space:]]+commit([[:space:]]|$) ]]; then
  exit 0
fi

# bypass marker 는 git commit invocation 의 env prefix 로 와야만 인정한다.
# sub-command 시작 boundary 까지 포함해서 검사 — 첫 sub-command 일 필요는 없지만, 그 sub-command 의 prefix 여야 한다.
# 허용: [boundary] RD_LIFECYCLE_BYPASS_REASON=<reason> [env ]git commit ...
#       [boundary] env RD_LIFECYCLE_BYPASS_REASON=<reason> [env ]git commit ...
# 차단: echo RD_LIFECYCLE_BYPASS_REASON=... && git commit ... — 두 번째 sub-command 가 prefix 없는 git commit
if [[ "$cmd" =~ (^|[\;\&\|\(\)][[:space:]]*)(env[[:space:]]+)?RD_LIFECYCLE_BYPASS_REASON=(bootstrap|lifecycle|small-task|legacy)[[:space:]]+(env[[:space:]]+)?git[[:space:]]+commit ]]; then
  exit 0
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

case "$CURRENT_BRANCH" in
  fr/*) exit 0 ;;
  main)
    printf '%s\n' "[fr_branch_gate] main 직접 commit 은 면제 reason 명시 필요." >&2
    printf '%s\n' "  사용법: RD_LIFECYCLE_BYPASS_REASON=<reason> git commit ..." >&2
    printf '%s\n' "  valid reason: bootstrap | lifecycle | small-task | legacy" >&2
    exit 2
    ;;
  *)
    printf '[fr_branch_gate] WARNING — legacy branch '\''%s'\''. 새 작업은 fr/{slug}로 전환 권장.\n' "$CURRENT_BRANCH" >&2
    exit 0
    ;;
esac
