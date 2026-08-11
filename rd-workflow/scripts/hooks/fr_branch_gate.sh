#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../../.." && pwd)"
source "${script_dir}/_guard_common.sh"

read_hook_input
cmd="$(extract_json_field "command")"

[[ -z "$cmd" ]] && exit 0

# 1단 필터 — 스캐너를 돌릴 가치가 있는지만 본다. **인용·백슬래시를 먼저 걷어낸다**:
# `git com'mit'` 처럼 인용으로 쪼개면 `commit` 연속 부분 문자열이 사라져 그냥 검사하면
# AC3b 가 요구하는 차단 대상을 스캐너 도달 전에 놓친다(실측 확인). 여기서의 과탐은
# 무해하다 — 최종 판정은 스캐너가 하고, 이 필터는 awk 기동 회피만 담당한다.
# `\<개행>`(line continuation)을 먼저 제거한다 — 백슬래시만 지우면 개행이 남아
# `com<개행>mit` 이 되고 `commit` 부분 문자열이 만들어지지 않는다(F12 실측).
# `$'…'` 는 escape 로 문자를 만들 수 있으므로(`$'com\x6dit'`) 있으면 무조건 스캐너로 보낸다.
_probe="${cmd//\\$'\n'/}"; _probe="${_probe//\'/}"; _probe="${_probe//\"/}"; _probe="${_probe//\\/}"
[[ "$_probe" != *commit* && "$cmd" != *\$\'* ]] && exit 0

# 2단 — 인용·heredoc·명령 치환을 인식하는 스캐너로 실행 위치의 커밋을 **모두** 집계한다.
#        판정 생략·불확실 진단은 _gate_from_scan 이 담당하므로 여기서는 참·거짓만 본다.
if scan_out="$(scan_command_commit "$cmd")"; then
  _gate_from_scan "$scan_out" "fr_branch_gate" || exit 0
else
  # 폴백 — 현행 경계 정규식을 그대로 보존한다. 강도는 오늘과 동일하고 오탐도 오늘과 같이 남는다.
  # (공통 _legacy_commit_glob 보다 정밀하므로 이 hook 은 자기 정규식을 유지한다.)
  printf '%s\n' "[fr_branch_gate] 스캐너 폴백(scan-unavailable) — 문자열 판정으로 처리합니다." >&2
  if ! [[ "$cmd" =~ (^|[\;\&\|\(\)][[:space:]]*)((env[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(env[[:space:]]+)?)?git[[:space:]]+commit([[:space:]]|$) ]]; then
    exit 0
  fi
  if [[ "$cmd" =~ (^|[\;\&\|\(\)][[:space:]]*)(env[[:space:]]+)?RD_LIFECYCLE_BYPASS_REASON=(bootstrap|lifecycle|small-task|legacy)[[:space:]]+(env[[:space:]]+)?git[[:space:]]+commit ]]; then
    exit 0
  fi
fi

# 기본 브랜치 결정 — resolver 실패 시 main fallback (현행 유지)
# AC12: source 는 POSIX 특수 내장이라 파일 부재 시 set -e 아래에서 if 조건문 안이어도
#       셸을 종료시킨다. 존재 확인을 앞세워야 fixture·부분 설치에서 hook 이 죽지 않는다.
DEFAULT_BRANCH="main"
_lc="${project_root}/rd-workflow/scripts/lifecycle/_lifecycle_common.sh"
if [[ -f "$_lc" ]] && source "$_lc" 2>/dev/null; then
  if _db="$(get_default_branch 2>/dev/null)" && [[ -n "$_db" ]]; then DEFAULT_BRANCH="$_db"; fi
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

case "$CURRENT_BRANCH" in
  fr/*) exit 0 ;;
  "$DEFAULT_BRANCH")
    printf '%s\n' "[fr_branch_gate] ${DEFAULT_BRANCH} 직접 commit 은 면제 reason 명시 필요." >&2
    printf '%s\n' "  사용법: RD_LIFECYCLE_BYPASS_REASON=<reason> git commit ..." >&2
    printf '%s\n' "  valid reason: bootstrap | lifecycle | small-task | legacy" >&2
    exit 2
    ;;
  *)
    printf '[fr_branch_gate] WARNING — legacy branch '\''%s'\''. 새 작업은 fr/{slug}로 전환 권장.\n' "$CURRENT_BRANCH" >&2
    exit 0
    ;;
esac
