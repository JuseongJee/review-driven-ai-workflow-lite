#!/usr/bin/env bash
# ralph_drain.sh — 무인 큐 드레인 supervisor (front-end A / Ralph loop).
# `/fr do --headless` 의 엔진이기도 하다 (RD_RALPH_SLUGS 로 지정한 FR 목록만 처리).
# autopilot_headless.sh 를 RD_AUTOPILOT_FR=auto 로 반복 호출해 준비된 큐(validated/ready-for-request)를
# 사람 개입 없이 자율 소진한다. 오케스트레이션 지능은 넣지 않는다 — exit code 만 보고 계속/중단한다.
#
# 환경변수:
#   RD_FINISH_POLICY           push|merge|none  미설정 시 merge 주입 (무인 드레인 안전 기본값)
#   RD_RALPH_MAX_ITER          절대 iteration 상한 (기본 50)
#   RD_RALPH_NONPROGRESS_LIMIT 연속 non-terminal(완료/blocked 미도달) 한도 (기본 5)
#   RD_AUTOPILOT_COST_FILE    비용 기록 파일 경로 (선택). 있으면 모든 wrapper 호출에 넘기고 드레인 시작 이후 덧붙은 줄만 합산한다(비우지 않음). 없으면 임시 파일을 만든다
#   RD_RALPH_SLUGS            공백 구분 short-title 목록. 설정하면 매 반복 fr_relations.sh auto-pick --slugs 로 그 안에서만 골라
#                             RD_AUTOPILOT_FR=<slug> 로 호출한다(소진 시 exit 0). 미설정이면 종전 auto. 설정됐지만 공백뿐이면 exit 1
#                             wrapper 가 완료(0)·blocked(20)로 끝낸 slug 는 이번 실행의 다음 반복 --slugs 에서 뺀다
#   RD_RALPH_RELATIONS_CMD    관계 판정 명령 오버라이드 (테스트 훅, 단어 분리되는 문자열; 기본은 <스크립트 디렉터리>/fr_relations.sh 를 공백 안전하게 호출)
#   RD_RALPH_WRAPPER_CMD      wrapper 호출 명령 오버라이드 (테스트 훅; 기본 "bash rd-workflow/scripts/autopilot_headless.sh")
#
# exit code: 0 정상 종료(queue-empty·queue-blocked) / 1 중단(backstop·harness-error 재발·관계/재개 판정 불가·미지 코드)
set -uo pipefail

FINISH_POLICY="${RD_FINISH_POLICY:-merge}"
MAX_ITER="${RD_RALPH_MAX_ITER:-50}"
NONPROGRESS_LIMIT="${RD_RALPH_NONPROGRESS_LIMIT:-5}"
WRAPPER_CMD="${RD_RALPH_WRAPPER_CMD:-bash rd-workflow/scripts/autopilot_headless.sh}"
OUTCOME_FILE="${RD_AUTOPILOT_OUTCOME_FILE:-rd-workflow-workspace/.autopilot-outcome}"

# backstop env 검증 — 무인 안전장치가 설정 실수(비숫자·0·음수·오탈자)로 무력화되지 않도록 조기 거부한다.
_die() { echo "ralph_drain: $1" >&2; exit 1; }
case "$MAX_ITER" in *[!0-9]*|'') _die "RD_RALPH_MAX_ITER 는 양수 정수여야 합니다: '${MAX_ITER}'" ;; esac
[ "$MAX_ITER" -ge 1 ] || _die "RD_RALPH_MAX_ITER 는 1 이상이어야 합니다: '${MAX_ITER}'"
case "$NONPROGRESS_LIMIT" in *[!0-9]*|'') _die "RD_RALPH_NONPROGRESS_LIMIT 는 양수 정수여야 합니다: '${NONPROGRESS_LIMIT}'" ;; esac
[ "$NONPROGRESS_LIMIT" -ge 1 ] || _die "RD_RALPH_NONPROGRESS_LIMIT 는 1 이상이어야 합니다: '${NONPROGRESS_LIMIT}'"
case "$FINISH_POLICY" in push|merge|none) ;; *) _die "RD_FINISH_POLICY 는 push|merge|none 중 하나여야 합니다: '${FINISH_POLICY}'" ;; esac

# slug 모드 — 설정 여부는 ${VAR+x} 로 가른다. 빈 목록이 auto 로 떨어져 선별에서 뺀 FR 을 실행하지 않게 한다.
SLUG_MODE=0
if [ "${RD_RALPH_SLUGS+x}" = "x" ]; then
  SLUG_MODE=1
  case "${RD_RALPH_SLUGS//[[:space:]]/}" in
    '') _die "RD_RALPH_SLUGS 가 비어 있습니다 — 실행할 FR 이 없습니다" ;;
  esac
fi
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 관계 판정 호출. 기본 경로는 따옴표로 감싸 프로젝트 경로의 공백에 안전하다. 테스트 훅은 종전처럼 문자열 명령이다.
relations() {
  if [ -n "${RD_RALPH_RELATIONS_CMD:-}" ]; then
    $RD_RALPH_RELATIONS_CMD "$@"
  else
    bash "$SELF_DIR/fr_relations.sh" "$@"
  fi
}
FR_ARG=auto
slug_done=" "   # 이번 실행에서 완료·blocked 로 끝난 slug (다음 반복 --slugs 에서 뺀다)

iter=0
nonprogress=0
completed=0
blocked=0
blocked_reasons=""
blocked_detail=""
stop_reason=""
drain_start="$(date +%s)"
cp_helper="$SELF_DIR/lifecycle/cleanup_pending.sh"
record_failed=""
calls=0

# 비용 기록 파일 — 모든 wrapper 호출(재시도 포함)이 같은 경로에 덧붙인다. 비용 문제는 드레인의 exit code 를 바꾸지 않는다.
# 호출자가 준 파일은 지우거나 비우지 않고 시작 시 줄 수(cost_base)만 기억한다. 임시 파일만 EXIT 에서 지운다.
cost_file=""; cost_base=0; cost_err=""; cost_tmp=""
if [ -n "${RD_AUTOPILOT_COST_FILE:-}" ]; then
  cost_file="$RD_AUTOPILOT_COST_FILE"
  if [ ! -e "$cost_file" ]; then
    : >> "$cost_file" 2>/dev/null || cost_err="비용 기록 파일을 만들 수 없음: ${cost_file}"
  fi
  if [ -z "$cost_err" ] && [ ! -r "$cost_file" ]; then cost_err="비용 기록 파일을 읽을 수 없음: ${cost_file}"; fi
else
  cost_tmp="$(mktemp 2>/dev/null)" || cost_tmp=""
  if [ -n "$cost_tmp" ]; then
    cost_file="$cost_tmp"
    trap 'rm -f "$cost_tmp"' EXIT
  else
    cost_err="비용 기록용 임시 파일을 만들 수 없음"
  fi
fi
if [ -z "$cost_err" ]; then
  cost_base="$(wc -l < "$cost_file" 2>/dev/null | tr -d ' ')"
  case "$cost_base" in ''|*[!0-9]*) cost_err="비용 기록 파일을 읽을 수 없음: ${cost_file}"; cost_base=0 ;; esac
fi

# wrapper 1회 호출 — auto-pick·모드 A·finish policy·outcome 파일 경로를 주입한다.
invoke_once() {
  calls=$((calls + 1))
  RD_AUTOPILOT_COST_FILE="$([ -z "$cost_err" ] && printf '%s' "$cost_file")" \
  RD_AUTOPILOT_FR="$FR_ARG" \
  RD_AUTOPILOT_MODE=A \
  RD_FINISH_POLICY="$FINISH_POLICY" \
  RD_AUTOPILOT_OUTCOME_FILE="$OUTCOME_FILE" \
  $WRAPPER_CMD
}

# harness-error(40) 1회 재시도 — 최종 exit code 를 반환한다.
invoke_with_retry() {
  invoke_once
  local c=$?
  if [ "$c" -eq 40 ]; then
    echo "ralph_drain: iter ${iter} → harness-error(40), 1회 재시도" >&2
    invoke_once
    c=$?
  fi
  return "$c"
}

summarize() {
  echo "---- ralph_drain 요약 ----"
  echo "완료(completed): ${completed}"
  echo "blocked: ${blocked}${blocked_reasons}"
  echo "iteration: ${iter}"
  echo "종료 사유: ${stop_reason}"
  [ -n "${blocked_detail:-}" ] && { echo "---- 대기 상세 ----"; printf '%s\n' "$blocked_detail"; }
  summarize_cost
  summarize_cleanup_pending
}

# 비용 합계 한 줄 (spec D6). a=ok 기록 수, b=unknown 기록 수, m=기록 없는 호출 수.
summarize_cost() {
  [ "$calls" -ge 1 ] || return 0
  local res a b sum m extra=""
  if [ -n "$cost_err" ]; then
    echo "실행 비용 합계: 집계 불가 — ${cost_err} (wrapper 호출 ${calls}회)"; return 0
  fi
  if ! res="$(awk -F'\t' -v base="$cost_base" 'NR>base && $1=="cost" { if ($2=="ok") { a++; s+=$3 } else if ($2=="unknown") b++ } END { printf "%d %d %.4f", a, b, s }' "$cost_file" 2>/dev/null)"; then
    echo "실행 비용 합계: 집계 불가 — 비용 기록 파일을 읽을 수 없음: ${cost_file} (wrapper 호출 ${calls}회)"; return 0
  fi
  read -r a b sum <<< "$res"
  m=$((calls - a - b)); [ "$m" -ge 0 ] || m=0
  if [ "$a" -ge 1 ]; then
    [ "$m" -gt 0 ] && extra=" · 비용 기록 없는 호출 ${m}회 — 일부 호출 누락, 실제 비용은 더 큼"
    [ -n "$extra" ] || [ "$b" -eq 0 ] || extra=" — 실제 비용은 더 큼"
    echo "실행 비용 합계: \$${sum} (정가 환산, 리뷰 도구 비용 제외) · wrapper 호출 ${calls}회 · 확인 불가 ${b}회${extra}"
  else
    echo "실행 비용 합계: 확인 불가 — wrapper 호출 ${calls}회 · 확인 불가 ${b}회 · 비용 기록 없는 호출 ${m}회"
  fi
  return 0
}

# 드레인 시작 이후 기록된 정리 잔여·조회 실패·기록 실패를 요약 끝에 덧붙인다.
summarize_cleanup_pending() {
  local out err rc total=0 parts="" slug n first
  err="$(mktemp 2>/dev/null)" || err=""
  if [ -n "$err" ]; then
    out="$(bash "$cp_helper" summary --since "$drain_start" 2>"$err")"; rc=$?
  else
    out="$(bash "$cp_helper" summary --since "$drain_start" 2>/dev/null)"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    first="$(head -n1 "$err" 2>/dev/null)"; first="${first#cleanup_pending: }"
    [ -n "$first" ] || first="종료 코드 ${rc}"
    echo "잔여(cleanup-pending): 조회 실패 (${first})"
  else
    while IFS=$'\t' read -r slug n; do
      [ -n "$slug" ] || continue
      total=$((total + n))
      parts="${parts:+${parts}, }${slug} ${n}건"
    done <<< "$out"
    [ "$total" -gt 0 ] && echo "잔여(cleanup-pending): ${total}건 (${parts})"
  fi
  [ -n "$err" ] && rm -f "$err"
  if [ -n "$record_failed" ]; then
    local k=0 list="" a b c
    while read -r a b c; do
      [ -n "$b" ] || continue
      k=$((k + 1))
      list="${list:+${list}, }${b} — 기록 ${c}"
    done <<< "$record_failed"
    echo "잔여(cleanup-pending): 기록 실패 ${k}건 (${list})"
  fi
  return 0
}

while : ; do
  iter=$((iter + 1))
  if [ "$iter" -gt "$MAX_ITER" ]; then
    stop_reason="iteration 상한(${MAX_ITER}) 도달"
    summarize
    exit 1
  fi

  if [ "$SLUG_MODE" -eq 1 ]; then
    slugs_left=""
    for s_ in $RD_RALPH_SLUGS; do
      case "$slug_done" in *" $s_ "*) ;; *) slugs_left="${slugs_left:+$slugs_left }$s_" ;; esac
    done
    if [ -z "$slugs_left" ]; then
      stop_reason="queue-empty (지정 목록 소진)"; summarize; exit 0
    fi
    pick_err="$(mktemp 2>/dev/null)" || pick_err=""
    pick_out="$(relations auto-pick --root . --slugs "$slugs_left" 2>"${pick_err:-/dev/null}")"; pick_rc=$?
    pick_head="$(printf '%s\n' "$pick_out" | head -n1)"
    pick_detail="$(printf '%s\n' "$pick_out" | awk 'NR>1')"
    pick_errline=""
    if [ -n "$pick_err" ]; then
      pick_errline="$(awk 'NF{l=$0} END{print l}' "$pick_err" 2>/dev/null)"; rm -f "$pick_err"
    fi
    if [ "$pick_rc" -ne 0 ] || [ "$pick_head" = "unavailable" ]; then
      stop_reason="관계 판정 불가 (relations-unavailable) — 전역 실패이므로 즉시 중단"
      [ -n "$pick_errline" ] && stop_reason="${stop_reason} (rc ${pick_rc}, stderr: ${pick_errline})"
      blocked_detail="$pick_detail"; summarize; exit 1
    fi
    case "$pick_head" in
      select"$(printf '\t')"*)
        stem="${pick_head#select$(printf '\t')}"; FR_ARG="${stem:11}"
        [ -n "$FR_ARG" ] || { stop_reason="auto-pick 결과 해석 불가: '${pick_head}' — 중단"; summarize; exit 1; } ;;
      queue-empty)
        stop_reason="queue-empty (지정 목록 소진)"; summarize; exit 0 ;;
      queue-blocked)
        stop_reason="queue-blocked (의존 대기 — 지정 목록에 착수 가능 FR 없음)"
        blocked_detail="$pick_detail"; summarize; exit 0 ;;
      *)
        stop_reason="auto-pick 결과 해석 불가: '${pick_head}' — 중단"; summarize; exit 1 ;;
    esac
  fi

  invoke_with_retry
  code=$?

  case "$code" in
    0)
      completed=$((completed + 1)); nonprogress=0
      [ "$SLUG_MODE" -eq 1 ] && slug_done="$slug_done$FR_ARG "
      rf="$(awk 'NR>1 && /^cleanup-record-failed /' "$OUTCOME_FILE" 2>/dev/null)"
      [ -z "$rf" ] || record_failed="${record_failed:+${record_failed}
}${rf}"
      echo "ralph_drain: iter ${iter} → completed (누적 ${completed})" ;;
    10)
      nonprogress=$((nonprogress + 1))
      echo "ralph_drain: iter ${iter} → resume (non-progress ${nonprogress}/${NONPROGRESS_LIMIT})" ;;
    20)
      reason="$(head -n1 "$OUTCOME_FILE" 2>/dev/null)"; reason="${reason#blocked:}"
      [ -n "$reason" ] || reason="(사유 미상)"
      # relations-unavailable 은 일반 blocked 와 다르다. 일반 blocked 는 그 FR 하나를
      # set-aside 하고 다음 FR 로 넘어가는 계약이지만, 관계 판정 실패는 FR 을 고르기
      # **전의 전역 실패**라 다음 iteration 도 똑같이 실패한다. 카운터를 올리지 않고
      # 즉시 중단한다 (그러지 않으면 같은 실패를 상한까지 되풀이한다).
      # resume-undetermined(재개 대상 판정 불가)도 전역 상태라 다음 iteration 이 같은 실패를 되풀이한다.
      # 이 경로에는 FR status 변경·CURRENT_TASK 초기화 같은 일반 blocked 절차도
      # 적용되지 않는다 — 대상 FR 이 없기 때문이다.
      if [ "$reason" = "relations-unavailable" ] || [ "$reason" = "resume-undetermined" ]; then
        if [ "$reason" = "resume-undetermined" ]; then
          stop_reason="재개 판정 불가 (resume-undetermined) — 전역 실패이므로 즉시 중단"
        else
          stop_reason="관계 판정 불가 (relations-unavailable) — 전역 실패이므로 즉시 중단"
        fi
        blocked_detail="$(awk 'NR>1' "$OUTCOME_FILE" 2>/dev/null)"
        summarize; exit 1
      fi
      # 발행 실패 3종(wrapper 가 outcome 을 바꿔 쓴다)도 중단한다. 다음 FR 로 넘어가면
      # 실패·중간 상태의 발행 위에 작업이 쌓인다. 상세(사유·로그·다음)는 outcome 둘째 줄 이후다.
      case "$reason" in
        publish-failed|publish-incomplete|publish-unsafe)
          case "$reason" in
            publish-failed)     stop_reason="발행 실패 (publish-failed) — 사람 확인 필요" ;;
            publish-incomplete) stop_reason="발행 중간 상태 (publish-incomplete) — 이어붙이기 필요" ;;
            *)                  stop_reason="발행 후 안전 검사 실패 (publish-unsafe) — ref 수동 정리 필요" ;;
          esac
          blocked_detail="$(awk 'NR>1' "$OUTCOME_FILE" 2>/dev/null)"
          summarize; exit 1 ;;
      esac
      blocked=$((blocked + 1)); nonprogress=0
      [ "$SLUG_MODE" -eq 1 ] && slug_done="$slug_done$FR_ARG "
      blocked_reasons="${blocked_reasons}
  - ${reason}"
      echo "ralph_drain: iter ${iter} → blocked: ${reason} (누적 ${blocked})" ;;
    30)
      stop_reason="queue-empty (드레인 완료)"; summarize; exit 0 ;;
    31)
      stop_reason="queue-blocked (의존 대기 — 착수 가능 FR 없음)"
      blocked_detail="$(awk 'NR>1' "$OUTCOME_FILE" 2>/dev/null)"
      summarize; exit 0 ;;
    40)
      stop_reason="harness-error 재발 — 중단"; summarize; exit 1 ;;
    *)
      stop_reason="미지 exit code(${code}) — 중단"; summarize; exit 1 ;;
  esac

  if [ "$nonprogress" -ge "$NONPROGRESS_LIMIT" ]; then
    stop_reason="연속 non-terminal ${NONPROGRESS_LIMIT}회 — non-progress 가드"
    summarize
    exit 1
  fi
done
