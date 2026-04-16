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

# REQUEST.md에서 Source FR 추출
request_file="${project_root}/REQUEST.md"
[[ ! -f "$request_file" ]] && exit 0

source_fr="$(awk '
  /^## Source FR/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) { print; exit } }
' "$request_file")"

# Source FR이 없거나 "-"이면 통과 (아카이브 불필요)
[[ -z "$source_fr" || "$source_fr" == "-" ]] && exit 0

# diff review가 통과했는지 확인
review_dir="$(get_latest_diff_review_dir)"
[[ -z "$review_dir" ]] && exit 0

checkpoint="${review_dir}/CHECKPOINT.md"
[[ ! -f "$checkpoint" ]] && exit 0

has_real_issues="$(awk '
  /^## Open Issues/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section && /^- / && !/^- 없음/ { found = 1; exit }
  END { print (found ? "yes" : "no") }
' "$checkpoint")"

# diff review가 아직 미완료면 통과 (review_gate가 처리)
[[ "$has_real_issues" == "yes" ]] && exit 0

# diff review 통과 + Source FR 있음 → FR 상세 파일 status 확인
items_dir="${project_root}/rd-workflow-workspace/backlog/items"
fr_file="${items_dir}/${source_fr}.md"

if [[ ! -f "$fr_file" ]]; then
  # 상세 파일이 없으면 경고만
  exit 0
fi

fr_status="$(awk '
  /^- status:/ { gsub(/^- status:[[:space:]]*/, ""); print; exit }
' "$fr_file")"

if [[ "$fr_status" == "done" || "$fr_status" == "dropped" ]]; then
  exit 0
fi

echo "[guard] diff review가 통과했지만 REQUEST 아카이브가 완료되지 않았습니다." >&2
echo "[guard] Source FR '${source_fr}'의 status가 '${fr_status}'입니다 (done/dropped 필요)." >&2
echo "[guard] REQUEST 아카이브를 먼저 실행하세요." >&2
exit 2
