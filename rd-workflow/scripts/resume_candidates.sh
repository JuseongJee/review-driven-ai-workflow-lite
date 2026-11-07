#!/usr/bin/env bash
# resume_candidates.sh — 무인 재개 후보 계산 helper (읽기 전용).
# 저장소 루트(cwd)에서 실행한다. 인자 없음, env RD_AUTOPILOT_FR(선택, 우선 후보 slug).
# 색인(<git-common-dir>/rd-workflow/tasks.local)과 각 worktree 의 task-state 를 읽어 판정만 한다.
# 쓰기·디렉터리 생성 없음 — _tasks_index.sh 의 조회 함수는 mkdir -p 부작용이 있어 쓰지 않고 직접 읽는다.
# stdout 첫 줄: select<TAB><slug><TAB><worktree> (rc 0) | none (rc 0) | undetermined (rc 3)
# 이후 줄: skip<TAB><slug><TAB><사유><TAB><다음 조치>
#          info<TAB><slug><TAB><설명><TAB><비고>  (선택된 작업이 launch=ok 종료 확인 출신일 때만, 첫 줄 바로 다음)
# launch=ok 작업은 herdr·프로세스 관측(session_launch.sh 의 판정 함수)으로 세션 종료를 읽기 전용 판정한다.
#   색인의 launch-backend 가 hc 면 이름 조회를 hc get 으로 한다:
#   ended 면 후보, alive 면 제외, unknown 이면 제외(수동 확정 안내). 색인·저장소에는 쓰지 않는다.
# bash 3.2 호환: 연관배열 미사용.
set -uo pipefail

TAB=$'\t'
RC_DIR="${BASH_SOURCE[0]%/*}"; [ "$RC_DIR" != "${BASH_SOURCE[0]}" ] || RC_DIR="."   # 프로세스 생성 없이 디렉터리 계산
rc_judge_ok=1
# shellcheck disable=SC1091
. "$RC_DIR/lifecycle/session_launch.sh" 2>/dev/null || rc_judge_ok=0
frs_ok=1
frs_file="$RC_DIR/_fr_status.sh"
if [ -r "$frs_file" ]; then . "$frs_file" 2>/dev/null; fi
[ -n "${FR_STATUS_AWK:-}" ] || frs_ok=0
ACTIVE_STATUS="대기 중|REQUEST review 대기|spec/plan 작성 중|spec/plan review 대기|구현 대기|구현 중|검증 중|diff review 대기|아카이브 보류"

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
if [ -z "$common" ]; then
  echo "undetermined"
  printf 'skip\t-\t불확실: git 경로 계산 실패\t저장소 루트에서 실행하십시오\n'
  exit 3
fi
idx="${common}/rd-workflow/tasks.local"
if [ ! -e "$idx" ]; then echo "none"; exit 0; fi
if [ ! -r "$idx" ] || [ ! -f "$idx" ]; then
  echo "undetermined"
  printf 'skip\t-\t불확실: 색인 읽기 실패\t%s 를 확인하십시오\n' "$idx"
  exit 3
fi

skips=""      # 제외·불확실 skip 줄 누적
uncertain=0
cand_slugs=() ; cand_wts=() ; cand_ended=()
obs_dir="" ; obs_state=""   # obs_state: 빈 값(미관측) | ok(관측함) | err:<원인>(임시 파일 생성 실패)
obs_ast="" ; obs_pst=""
trap '[ -n "$obs_dir" ] && rm -rf "$obs_dir"' EXIT

# 첫 launch=ok 작업에서 한 번만 관측하고 이후 작업은 결과를 재사용한다.
rc_observe_once() {
  [ -z "$obs_state" ] || return 0
  obs_dir="$(mktemp -d 2>/dev/null)" || { obs_dir=""; obs_state="err:임시 파일 생성 실패"; return 0; }  # mktemp-scan: custom-handler
  obs_ast="$(session_observe_agents "$obs_dir/agents")"
  obs_pst="$(session_observe_procs "$obs_dir/procs")"
  obs_state="ok"
}

add_skip() { skips="${skips}skip${TAB}$1${TAB}$2${TAB}$3"$'\n'; }
state_val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in slug=*) ;; *) continue ;; esac
  slug=""; wt=""; launch=""; state=""; backend=""
  IFS=$'\t' read -r -a fields <<< "$line"
  for f in "${fields[@]}"; do
    case "$f" in
      slug=*) slug="${f#slug=}" ;;
      worktree-path=*) wt="${f#worktree-path=}" ;;
      launch=*) launch="${f#launch=}" ;;
      launch-backend=*) backend="${f#launch-backend=}" ;;
      state=*) state="${f#state=}" ;;
    esac
  done
  [ -n "$slug" ] || continue
  [ "$state" = "cleanup-pending" ] && continue

  # 1. worktree 디렉터리 부재 (키 없음 포함)
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    add_skip "$slug" "worktree 부재" "정리 대상이면 rd task list 로 확인하십시오"; continue
  fi
  # 2. task-state 읽기·short-title 대조
  ts="${wt}/rd-workflow-workspace/.lifecycle/task-state"
  if [ ! -r "$ts" ] || [ "$(state_val "$ts" short-title)" != "$slug" ]; then
    add_skip "$slug" "불확실: 색인과 작업 파일 불일치" "worktree 의 task-state 와 색인을 사람이 대조하십시오"
    uncertain=1; continue
  fi
  status="$(state_val "$ts" status)"
  # 3. 완료
  if [ "$status" = "완료" ]; then add_skip "$slug" "완료" "아카이브 대기 여부를 확인하십시오"; continue; fi
  # 3a. status 정상 집합
  case "|${ACTIVE_STATUS}|" in
    *"|${status}|"*) ;;
    *) add_skip "$slug" "불확실: 단계 판정 불가(status=${status})" "task-state 의 status 를 확인하십시오"; uncertain=1; continue ;;
  esac
  # 3b. source-fr 의 FR 이 worktree 사본에서 blocked 이면 제외 (cwd 사본은 읽지 않고, 읽을 수 없는 경로는 무시)
  blocked_n=0
  IFS='|' read -r -a srcs <<< "$(state_val "$ts" source-fr)"
  if [ "$frs_ok" -eq 0 ]; then
    frs_have=0
    for rel in ${srcs[@]+"${srcs[@]}"}; do
      [ -n "$rel" ] && [ "$rel" != "-" ] || continue
      [ -r "${wt}/${rel}" ] && frs_have=1
    done
    if [ "$frs_have" -eq 1 ]; then
      add_skip "$slug" "불확실: FR status 판정 파일 없음 (${frs_file})" "rd-workflow 배치를 확인하십시오"
      uncertain=1; continue
    fi
  fi
  for rel in ${srcs[@]+"${srcs[@]}"}; do
    [ -n "$rel" ] && [ "$rel" != "-" ] || continue
    fr_file="${wt}/${rel}"
    [ -r "$fr_file" ] || continue
    IFS=$'\034' read -r _c fr_status _k <<< "$(fr_status_scan "$fr_file" | head -1)"
    [ "$fr_status" = "blocked" ] || continue
    fr_slug="${rel##*/}"; fr_slug="${fr_slug%.md}"
    fr_slug="${fr_slug#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-}"
    add_skip "$slug" "FR blocked: ${fr_slug} (${fr_file})" "그 worktree 에서 /fr status ${fr_slug} validated 로 복원하십시오. 이 작업의 blocked FR 을 모두 복원해야 다음 회차에 재개됩니다. 작업을 버리려면 promote_rollback.sh 를 쓰십시오."
    blocked_n=$((blocked_n+1))
  done
  [ "$blocked_n" -gt 0 ] && continue
  # 4. launch=ok 는 대화형 세션이 맡는다 — 세션 종료를 관측으로 판정한다
  if [ "$launch" = "ok" ]; then
    verdict="unknown${TAB}판정 함수 없음"
    if [ "$rc_judge_ok" -eq 1 ]; then
      rc_observe_once
      case "$obs_state" in
        ok) verdict="$(session_ended_judge "$slug" "$wt" "$obs_ast" "$obs_dir/agents" "$obs_pst" "$obs_dir/procs" "$backend")" ;;
        *)  verdict="unknown${TAB}${obs_state#err:}" ;;
      esac
    fi
    case "$verdict" in
      ended) ;;
      alive"$TAB"*)
        add_skip "$slug" "대화형 세션 살아 있음(${verdict#alive"$TAB"})" "세션이 끝나면 다음 회차에 자동으로 재개 후보가 됩니다"; continue ;;
      *)
        add_skip "$slug" "대화형 세션 기동 이력(launch=ok) — 종료 판정 불가: ${verdict#unknown"$TAB"}" "세션이 끝났으면 rd task resolve-launch ${slug} --assume-ended"; continue ;;
    esac
  fi
  # 5/6. launch 판정
  case "$launch" in
    none|failed) cand_slugs+=("$slug"); cand_wts+=("$wt"); cand_ended+=(0) ;;
    # cand_ended: 0 = launch 판정 출신, 1 = herdr 세션 종료 확인, 2 = hc 세션 종료 확인 (info 문구를 가른다)
    ok) cand_slugs+=("$slug"); cand_wts+=("$wt"); if [ "$backend" = "hc" ]; then cand_ended+=(2); else cand_ended+=(1); fi ;;
    *) add_skip "$slug" "불확실: 생존 판정 불가(launch=${launch})" "rd task resolve-launch ${slug} 로 확정하십시오"; uncertain=1 ;;
  esac
done < "$idx"

n=${#cand_slugs[@]}
# 명시 slug(RD_AUTOPILOT_FR=<slug>, auto 가 아님)는 요청한 FR 만 재개한다. batch 는 요청 item 의 결과를
# 그 FR 에 적용하므로, 다른 작업을 재개하면 요청 item 이 실행되지 않은 채 blocked 로 오판된다 (final diff review F1).
explicit=""
[ -n "${RD_AUTOPILOT_FR:-}" ] && [ "${RD_AUTOPILOT_FR}" != "auto" ] && explicit="$RD_AUTOPILOT_FR"
pick=-1
i=0
while [ "$i" -lt "$n" ]; do
  if [ -n "$explicit" ]; then
    [ "${cand_slugs[$i]}" = "$explicit" ] && { pick=$i; break; }
  else
    pick=0
    [ -z "${RD_AUTOPILOT_FR:-}" ] || [ "${cand_slugs[$i]}" != "$RD_AUTOPILOT_FR" ] || { pick=$i; break; }
  fi
  i=$((i+1))
done
if [ "$pick" -ge 0 ] && [ "$n" -gt 0 ]; then
  printf 'select\t%s\t%s\n' "${cand_slugs[$pick]}" "${cand_wts[$pick]}"
  case "${cand_ended[$pick]}" in
    1) printf 'info\t%s\t대화형 세션 종료 확인(launch=ok, herdr·프로세스 어디에도 세션 없음)\t색인의 launch 값은 바꾸지 않았습니다\n' "${cand_slugs[$pick]}" ;;
    2) printf 'info\t%s\t대화형 세션 종료 확인(launch=ok, herdr app·프로세스 어디에도 세션 없음)\t색인의 launch 값은 바꾸지 않았습니다\n' "${cand_slugs[$pick]}" ;;
  esac
  printf '%s' "$skips"
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "$i" -ne "$pick" ] && printf 'skip\t%s\t다른 후보(미선택)\t다음 회차에 재개됩니다\n' "${cand_slugs[$i]}"
    i=$((i+1))
  done
  exit 0
fi
if [ "$n" -gt 0 ] && [ -n "$explicit" ] && [ "$uncertain" -eq 0 ]; then
  echo "none"; printf '%s' "$skips"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'skip\t%s\t다른 후보(미선택, 명시 FR %s 지정 중)\t지정한 FR 이 끝난 뒤 다음 회차에 재개됩니다\n' "${cand_slugs[$i]}" "$explicit"
    i=$((i+1))
  done
  exit 0
fi
if [ "$uncertain" -eq 1 ]; then echo "undetermined"; printf '%s' "$skips"; exit 3; fi
echo "none"; printf '%s' "$skips"; exit 0
