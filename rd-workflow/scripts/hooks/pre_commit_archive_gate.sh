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

# --- 이 게이트의 실제 적용 범위 (spec §2.5.3, 리뷰 F2 — 정직한 기술) ---
# 이 게이트는 REQUEST 가 없거나 Source FR 이 비면 통과하고, `아카이브 보류` 상태의
# 기록 전용 커밋도 통과한다. 정규 마감은 이 두 경로를 지나므로 **이 게이트는 마감
# 누락의 최종 보장이 아니다.** 실제로 막는 것은 「Source FR 이 남아 있는 REQUEST 로
# 아카이브 커밋을 시도하는 경우」 하나이며, 이 변경의 값은 그 범위 안에서 1건만
# 보던 것을 전부 보게 하는 것이다. 최종 보장은 절차(`rd task fr-done` 호출)와
# 발행 후 보고에 있다.

# REQUEST.md에서 Source FR 추출
request_file="${project_root}/REQUEST.md"
[[ ! -f "$request_file" ]] && exit 0

# Source FR 추출·해석 — _state_common.sh 단일 구현에 위임한다 (복수 표현 지원).
#   from_request_list 가 '## Source FR' 절의 원문을 전부(줄 단위) 반환하고
#   ('- ' 리스트 접두는 벗기지 않은 채 — 접두 제거는 resolve 단계 0 의 책임),
#   resolve_list 가 각 줄을 canonical path 로 정규화한다.
raw_source_fr_list="$(source_fr_from_request_list "$request_file")"

# 값이 없으면 아카이브 불필요 → 통과
[[ -z "$raw_source_fr_list" ]] && exit 0

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
#   해석 실패 항목은 첫 건에서 멈추지 않고 전부 열거한다(사람이 한 번에 고쳐야
#   한다) — 실패 메시지는 source_fr_resolve_list 가 이미 stderr 에 낸다.
if ! source_fr_list="$(source_fr_resolve_list "$raw_source_fr_list" "$project_root")"; then
  echo "[guard] 위 Source FR 항목을 해석할 수 없어 아카이브 커밋을 막습니다." >&2
  echo "[guard] REQUEST.md 의 ## Source FR 을 다음 형식으로 고치세요:" >&2
  echo "[guard]   rd-workflow-workspace/backlog/items/<파일>.md" >&2
  # reason: Source FR 항목을 canonical path 로 해석할 수 없어 아카이브 커밋을 막은 분기.
  guard_deny "pre_commit_archive_gate.unresolved-source-fr"
fi
[[ -z "$source_fr_list" ]] && exit 0

# --- 아카이브 보류 상태의 기록 커밋 예외 (spec §4.3) ---
# task-state status 가 `아카이브 보류` 이면, 커밋에 들어갈 수 있는 변경이 전부 제외 경로(§2.1)
# 안일 때만 통과시킵니다. 그래야 §4.2 정상 경로(seal → 상태 전이 → 기록 커밋)가 성립합니다.
#
# **이 분기는 아래 `done|dropped` 조기 통과보다 반드시 앞에 있어야 합니다.** 정상 archive
# content commit 은 바로 그 커밋에서 FR status 를 `done` 으로 바꾸므로, 순서가 뒤바뀌면
# 워킹트리의 `done` 표기 하나로 이 제한이 통째로 우회됩니다 (final diff review Finding 3).
#
# 상태는 워킹트리의 task-state 파일에서 읽습니다(index도 HEAD 도 아님) — 전이가 커밋 없이
# 즉시 반영되어야 순환이 생기지 않기 때문입니다.
# 경로 판정은 rd_commit_scope_all_records 한 곳에 위임합니다 — 허용 목록(RD_RECORD_PATHS)을
# 여기에 다시 적지 않습니다. 두 곳이 어긋나면 "커밋은 되는데 발행에서 막히는" 상태가 생깁니다.
# 환경변수로 이 게이트를 우회하는 경로는 만들지 않는 것이 계약입니다(AC 26).
pending_block=0
if [[ "$(state_read_field "status")" == "아카이브 보류" ]]; then
  # 3값 반환: 0=전부 기록 경로, 1=밖에 있는 것 존재, 2=판정 불가.
  # 2 는 통과가 아니라 차단입니다(fail-closed).
  if rd_commit_scope_all_records; then
    records_rc=0
  else
    records_rc=$?
  fi
  case "$records_rc" in
    0)
      exit 0
      ;;
    1)
      echo "[guard] 아카이브 보류 상태이지만 커밋 대상 변경에 기록 경로 밖의 파일이 있습니다." >&2
      pending_block=1
      ;;
    *)
      echo "[guard] 커밋 대상 변경이 기록 경로 안인지 판정할 수 없어 차단합니다." >&2
      pending_block=1
      ;;
  esac
fi

# --- Source FR 전부의 status 확인 (AC C-16) ---
# 실존은 source_fr_resolve_list 가 이미 보장하므로 여기서 다시 확인하지 않는다.
# done/dropped 가 아닌 FR 이 하나라도 있으면 첫 건에서 멈추지 않고 전부 모은다 —
# 사람이 REQUEST 아카이브 전에 한 번에 고칠 수 있어야 한다.
incomplete=""
while IFS= read -r fr; do
  [[ -z "$fr" ]] && continue
  fr_file="${project_root}/${fr}"
  fr_status="$(awk '
    /^- status:/ { gsub(/^- status:[[:space:]]*/, ""); print; exit }
  ' "$fr_file")"
  if [[ "$fr_status" != "done" && "$fr_status" != "dropped" ]]; then
    incomplete="${incomplete:+${incomplete}$'\n'}${fr}"$'\t'"${fr_status}"
  fi
done <<< "$source_fr_list"

if [[ -z "$incomplete" ]]; then
  # 보류 분기에서 이미 차단이 확정된 경우에만 여기로 옵니다.
  # 종전에는 이 조기 통과가 보류 분기보다 앞에 있어 제한이 사실상 죽어 있었습니다.
  if [[ "$pending_block" == "0" ]]; then
    exit 0
  fi
  echo "[guard] 아카이브 보류 상태에서는 기록 경로 밖의 변경을 커밋할 수 없습니다." >&2
  echo "[guard] 코드 변경이 필요하면 상태를 '구현 중' 으로 되돌리고 리뷰를 다시 받으세요:" >&2
  echo "[guard]   bash rd-workflow/scripts/rd task set-status \"구현 중\"" >&2
  # reason: `아카이브 보류` 상태에서 기록 경로 밖의 변경을 커밋하려 한 분기.
  guard_deny "pre_commit_archive_gate.pending-out-of-scope"
fi

echo "[guard] diff review가 통과했지만 REQUEST 아카이브가 완료되지 않았습니다." >&2
while IFS=$'\t' read -r fr fr_status; do
  [[ -z "$fr" ]] && continue
  echo "[guard] Source FR '${fr}'의 status가 '${fr_status}'입니다 (done/dropped 필요)." >&2
done <<< "$incomplete"
echo "[guard] REQUEST 아카이브를 먼저 실행하세요." >&2
# reason: diff review는 통과했지만 Source FR 중 done/dropped가 아닌 항목이 남은 분기.
guard_deny "pre_commit_archive_gate.incomplete-source-fr"
