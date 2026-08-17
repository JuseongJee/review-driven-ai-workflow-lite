#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

read_hook_input
cmd="$(extract_json_field "command")"

# command가 비어있으면 통과
[[ -z "$cmd" ]] && exit 0

# 실행 위치의 커밋이 아니면 통과 (인용·heredoc·명령 치환 인식 — _guard_common.sh)
# 1단 필터는 command_targets_our_commit 이 단일 소유자로 갖는다.
command_targets_our_commit "$cmd" "archive_gate" || exit 0

# REQUEST.md에서 Source FR 추출
request_file="${project_root}/REQUEST.md"
[[ ! -f "$request_file" ]] && exit 0

# Source FR 추출·해석 — _state_common.sh 단일 구현에 위임한다.
#   from_request 가 원문 한 줄을, resolve 가 canonical path 로의 정규화를 담당한다.
raw_source_fr="$(source_fr_from_request "$request_file")"

# 값이 없거나 '-' 이면 아카이브 불필요 → 통과
[[ -z "$raw_source_fr" ]] && exit 0

# diff review가 통과했는지 확인
review_dir="$(get_latest_diff_review_dir)"
[[ -z "$review_dir" ]] && exit 0

# diff review가 아직 미종결이면 통과 (review_gate가 처리). 종결성 판정은 헬퍼로 통일.
is_review_session_resolved "$review_dir" || exit 0

# --- 여기서부터가 archive 커밋 경로다 ---
# 값이 있는데 해석에 실패하면 차단한다 (fail-closed).
#   종전에는 파일을 못 찾으면 검증을 건너뛰고 통과시켰다. 그 결과 표기가 어긋난
#   REQUEST 에서는 이 게이트가 통째로 꺼져, promote 의 '-' 기록과 함께 안전장치가
#   둘 다 무력화됐다.
#   이 판정을 review 종결 확인보다 **뒤**에 두는 것이 계약이다. 앞에 두면 세션이
#   없거나 미종결인 상태의 커밋(구현 중 iteration commit 등)까지 막혀, 게이트가
#   'archive 커밋 차단' 이라는 적용 범위를 벗어난다.
if ! source_fr="$(source_fr_resolve "$raw_source_fr" "$project_root")"; then
  echo "[guard] Source FR '${raw_source_fr}' 를 해석할 수 없어 아카이브 커밋을 막습니다." >&2
  echo "[guard] REQUEST.md 의 ## Source FR 을 다음 형식으로 고치세요:" >&2
  echo "[guard]   rd-workflow-workspace/backlog/items/<파일>.md" >&2
  exit 2
fi
[[ -z "$source_fr" ]] && exit 0

# Source FR 있음 → FR 상세 파일 status 확인
# 실존은 source_fr_resolve 가 이미 보장하므로 여기서 다시 확인하지 않는다.
fr_file="${project_root}/${source_fr}"

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
