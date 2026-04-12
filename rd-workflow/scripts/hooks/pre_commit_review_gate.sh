#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

read_hook_input
cmd="$(extract_json_field "command")"

# command가 비어있으면 통과
[[ -z "$cmd" ]] && exit 0

# git commit 패턴이 아니면 통과
if ! [[ "$cmd" == *git\ *commit* || "$cmd" == *git$'\t'*commit* || "$cmd" == git\ commit* ]]; then
  exit 0
fi

# autopilot 활성 시 통과
is_autopilot_active && exit 0

# 최신 diff-review 세션 확인
review_dir="$(get_latest_diff_review_dir)"
if [[ -z "$review_dir" ]]; then
  echo "[guard] diff review 세션이 없습니다. 커밋 전에 diff review를 실행하세요." >&2
  exit 2
fi

# CHECKPOINT.md에서 Open Issues 확인
checkpoint="${review_dir}/CHECKPOINT.md"
if [[ ! -f "$checkpoint" ]]; then
  echo "[guard] diff review CHECKPOINT.md가 없습니다." >&2
  exit 2
fi

# Open Issues 판정: "- "로 시작하는 줄 중 "- 없음"이 아닌 줄이 있으면 미완료
has_real_issues="$(awk '
  /^## Open Issues/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section && /^- / && !/^- 없음/ { found = 1; exit }
  END { print (found ? "yes" : "no") }
' "$checkpoint")"

if [[ "$has_real_issues" == "no" ]]; then
  exit 0
fi

echo "[guard] diff review가 완료되지 않았습니다. Open Issues가 남아있습니다." >&2
exit 2
