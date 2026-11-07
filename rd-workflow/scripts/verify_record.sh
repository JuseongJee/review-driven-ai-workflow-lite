#!/usr/bin/env bash
# verify_record.sh — 검증 명령을 돌리고, 통과하면 그 트리의 검증 증거를 남깁니다.
# 사용: bash rd-workflow/scripts/verify_record.sh -- <검증 명령> [인자…]
#
# 증거 파일: rd-workflow-workspace/.lifecycle/review-seals/verify-evidence (key=value)
#   schema command exit-code tree-hash head recorded-at
# 이 경로는 RD_RECORD_PATHS 안이므로 증거를 쓰거나 커밋해도 보호 트리 해시가 바뀌지 않습니다.
# `rd review seal` 이 `rd_seal_evidence_check` 로 이 파일을 읽어 현재 트리와 대조합니다.
#
# 종료 코드: 검증 명령이 실패하면 그 exit code, 래퍼 자체가 중단하면 1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_state_common.sh"

EVIDENCE_REL="rd-workflow-workspace/.lifecycle/review-seals/verify-evidence"

if [[ "${1-}" != "--" || $# -lt 2 ]]; then
  echo "사용법: bash rd-workflow/scripts/verify_record.sh -- <검증 명령> [인자…]" >&2
  exit 1
fi
shift

# 명령 한 줄 표기 — 개행이 있으면 key=value 증거 형식이 깨지므로 거부합니다.
for _a in "$@"; do
  case "$_a" in
    *$'\n'*)
      echo "verify_record: 인자에 개행이 있어 증거 형식으로 기록할 수 없습니다 — 중단합니다." >&2
      exit 1 ;;
  esac
done
# 증거의 command 와 재실행 안내는 사용자가 그대로 붙여 넣는 문자열이므로 인자별로 셸 이스케이프(%q)해
# 인자 경계를 보존합니다 (`$*` 는 따옴표·공백 경계를 지웁니다). 이 문자열을 eval 하지는 않습니다.
cmd_line=""
for _a in "$@"; do
  cmd_line="${cmd_line:+${cmd_line} }$(printf '%q' "$_a")"
done

# _protected_dirty — 기록 경로 밖에 미커밋 변경(추적 변경·미추적)이 있으면 그 경로를 출력합니다.
# 보호 트리 해시는 커밋된 트리 기준이므로, 미커밋 변경이 있으면 증거가 HEAD 와 어긋납니다.
_protected_dirty() {
  local rec path skip_next=0 out="" st
  st="$(mktemp "${TMPDIR:-/tmp}/rd-verify-st.XXXXXX")" || return 2
  [[ -n "$st" && -f "$st" ]] || return 2
  if ! git -C "$project_root" status --porcelain -z --untracked-files=all > "$st" 2>/dev/null; then
    rm -f "$st"
    return 2
  fi
  while IFS= read -r -d '' rec; do
    if [[ "$skip_next" == "1" ]]; then
      # rename/copy 의 원본 경로 레코드 — 상태 접두가 없습니다.
      skip_next=0
      path="$rec"
    else
      path="${rec:3}"
      case "${rec:0:2}" in *R*|*C*) skip_next=1 ;; esac
    fi
    rd_path_is_record "$path" && continue
    out="${out}${path}"$'\n'
  done < "$st"
  rm -f "$st"
  printf '%s' "$out"
  return 0
}

_dirty_msg() {
  echo "verify_record: 보호 경로에 미커밋 변경이 있어 증거가 HEAD 와 어긋납니다 — 커밋한 뒤 다시 실행하십시오." >&2
  # head 로 자르면 큰 목록에서 printf 가 SIGPIPE 를 받는다. sed 가 끝까지 읽는다.
  printf '%s' "$1" | sed -n '1,5s/^/  - /p' >&2
}

dirty="$(_protected_dirty)" || {
  echo "verify_record: git status 를 읽을 수 없습니다 — 판정 불가로 중단합니다." >&2
  exit 1
}
if [[ -n "$dirty" ]]; then
  _dirty_msg "$dirty"
  exit 1
fi

before="$(rd_protected_tree_hash HEAD)" || {
  echo "verify_record: 보호 트리 해시를 계산할 수 없습니다 — 중단합니다." >&2
  exit 1
}

evidence="${project_root}/${EVIDENCE_REL}"
# 실패·변경 시 이전 통과 증거를 재사용할 수 없게 먼저 지웁니다.
rm -f "$evidence"

rc=0
"$@" || rc=$?

if [[ "$rc" != "0" ]]; then
  echo "verify_record: 검증 명령이 실패했습니다 (exit ${rc}) — 증거를 남기지 않습니다." >&2
  exit "$rc"
fi

after="$(rd_protected_tree_hash HEAD)" || {
  echo "verify_record: 실행 후 보호 트리 해시를 계산할 수 없습니다 — 증거를 남기지 않습니다." >&2
  exit 1
}
dirty="$(_protected_dirty)" || {
  echo "verify_record: 실행 후 git status 를 읽을 수 없습니다 — 증거를 남기지 않습니다." >&2
  exit 1
}
if [[ "$before" != "$after" || -n "$dirty" ]]; then
  echo "verify_record: 검증 중 보호 경로가 바뀌었습니다 — 같은 명령을 다시 실행하십시오: bash rd-workflow/scripts/verify_record.sh -- ${cmd_line}" >&2
  [[ -n "$dirty" ]] && printf '%s' "$dirty" | sed -n '1,5s/^/  - /p' >&2
  exit 1
fi

head_oid="$(rd_resolve_commit_oid HEAD)" || {
  echo "verify_record: HEAD 를 해석할 수 없습니다 — 증거를 남기지 않습니다." >&2
  exit 1
}
mkdir -p "$(dirname "$evidence")"
tmp="$(mktemp "$(dirname "$evidence")/.verify-evidence.XXXXXX")" || {
  echo "verify_record: mktemp 실패 — 증거를 남기지 않습니다." >&2
  exit 1
}
[[ -n "$tmp" && -f "$tmp" ]] || { echo "verify_record: mktemp 결과가 비정상입니다." >&2; exit 1; }
cat > "$tmp" <<EOF
schema=1
command=${cmd_line}
exit-code=0
tree-hash=${after}
head=${head_oid}
recorded-at=$(date '+%Y-%m-%d-%H%M')
EOF
mv "$tmp" "$evidence"
echo "verify_record: 증거를 기록했습니다 (tree-hash ${after:0:8}) — ${EVIDENCE_REL}"
