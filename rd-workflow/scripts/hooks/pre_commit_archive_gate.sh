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

# Source FR 추출 — source_fr_from_request 가 백틱·공백 제거, '-'/부재는 빈 값 반환 (_state_common.sh 단일 구현)
source_fr="$(source_fr_from_request "$request_file")"

# Source FR이 없거나 "-"이면 통과 (아카이브 불필요)
[[ -z "$source_fr" ]] && exit 0

# diff review가 통과했는지 확인
review_dir="$(get_latest_diff_review_dir)"
[[ -z "$review_dir" ]] && exit 0

# diff review가 아직 미종결이면 통과 (review_gate가 처리). 종결성 판정은 헬퍼로 통일.
is_review_session_resolved "$review_dir" || exit 0

# diff review 통과 + Source FR 있음 → FR 상세 파일 status 확인
items_dir="${project_root}/rd-workflow-workspace/backlog/items"
if [[ "$source_fr" == */* ]]; then
  # path 형식 (canonical) — repo-relative 만 허용. 절대경로/.. 는 경고 후 통과 (fail-open)
  case "$source_fr" in
    /*|../*|*/../*|*/..)
      echo "[guard] Source FR path 형식 위반('${source_fr}') — 검증을 건너뜁니다." >&2
      exit 0 ;;
  esac
  fr_file="${project_root}/${source_fr}"
else
  # legacy slug — items/<slug>.md 해석 (읽기 호환)
  fr_file="${items_dir}/${source_fr}.md"
fi

if [[ ! -f "$fr_file" ]]; then
  echo "[guard] Source FR 상세 파일(${fr_file})을 찾지 못했습니다 — 검증을 건너뜁니다." >&2
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
