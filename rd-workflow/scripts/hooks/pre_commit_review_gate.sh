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

# 현재 fr 범위 diff-review 세션 (fr-scope, short-title 매칭)
review_dir="$(get_latest_diff_review_dir)"
# 세션 없음 = 아직 구현/검증 단계 → 통과 (autopilot rollback commit 보호, unscoped 세션 제외)
[[ -z "$review_dir" ]] && exit 0

# 세션 존재: SESSION Status + Open Issues 종결성 검사 (autopilot 여부 무관)
if is_review_session_resolved "$review_dir"; then
  exit 0
fi
# 미종결: archive/종결 신호 commit만 차단(B1). iteration 수정 commit 은 허용(A1).
# review 루프의 review target 은 main...HEAD 이므로 iteration 수정은 commit 되어야 reviewer 가 본다.
# malformed 세션(미종결 취급)도 동일 — archive 신호일 때만 차단, iteration 은 허용.
#   "malformed = fail-closed" 는 commit 전체 차단에서 archive 경로 fail-closed 로 좁혀진다.
# 안전 경계의 최종 보루는 archive.sh 의 archive_review_precheck(B2).
if commit_has_archive_signal; then
  echo "[guard] diff review가 종결되지 않았습니다. archive/완료 commit 은 review 종결 후 수행하세요 (iteration 수정 commit 은 허용)." >&2
  exit 2
fi
exit 0
