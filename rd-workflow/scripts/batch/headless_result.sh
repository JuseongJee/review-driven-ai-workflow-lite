#!/bin/bash
# headless_result.sh — autopilot wrapper 결과를 /fr batch 처리 토큰과 비용 표기로 바꾸는 헬퍼.
# bash 3.2 호환, 외부 의존은 awk 뿐. spec: rd-workflow-workspace/specs/changes/
#   2026-11-07-1110-autopilot-headless-tidy-change-spec.md §3.6
#
# 서브커맨드
#   route <outcome 파일> <exit code>   처리 경로 토큰 한 줄 (판정 순서는 spec §3.6 표). exit 0.
#   tokens                             route 가 낼 수 있는 토큰 10개를 한 줄에 하나씩. exit 0.
#   cost-item <비용 tsv>               국면 3 항목 꼬리 한 줄. exit 0.
#   cost-total <비용 tsv>...           국면 3 전체 합계 한 줄. 인자 없으면 출력 없음. exit 0.
# 종료 코드: 0 성공 / 2 인자 오류(stderr 사용법).
set -uo pipefail

usage() {
  echo "사용법: headless_result.sh route <outcome 파일> <exit code> | tokens | cost-item <tsv> | cost-total <tsv>..." >&2
  exit 2
}

# _stat <파일> → stdout "<ok합> <ok횟수> <unknown횟수>", 반환 0 정상 / 1 파일 없음 / 2 읽지 못함.
_stat() {
  local f="$1" out
  [ -e "$f" ] || return 1
  [ -d "$f" ] && return 2
  out="$(awk -F'\t' '$1=="cost"{ if($2=="ok"){s+=$3;n++} else if($2=="unknown"){k++} }
                     END{ printf "%.10g %d %d\n", s, n, k }' < "$f" 2>/dev/null)" || return 2
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

cmd_route() {
  [ $# -eq 2 ] || usage
  local f="$1" rc="$2" first="" second=""
  if [ -f "$f" ]; then
    first="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
    second="$(sed -n 2p "$f" 2>/dev/null)"
  fi
  if [ "$rc" = "0" ]; then echo verify-done; return 0; fi
  case "$first" in
    blocked:time-cap-unreaped)   echo pause-unreaped; return 0 ;;
    blocked:resume-undetermined) echo pause-resume-undetermined; return 0 ;;
    blocked:publish-incomplete)
      case "$second" in
        "사유: 발행 시간 상한"*) echo pause-publish-timeout ;;
        *) echo archive-continue ;;
      esac
      return 0 ;;
    blocked:publish-unsafe)      echo pause-publish-unsafe; return 0 ;;
  esac
  case "$rc" in
    10) echo pause-resume ;;
    20|30|31) echo blocked ;;   # 31 queue-blocked: 의존 FR 미완료라 다시 띄워도 같은 결과 — 후속만 건너뛰고 독립 FR 은 계속
    40) echo harness-error ;;
    *) echo unknown ;;
  esac
}

cmd_tokens() {
  printf '%s\n' verify-done pause-unreaped pause-resume-undetermined pause-publish-timeout \
    archive-continue pause-publish-unsafe pause-resume blocked harness-error unknown
}

cmd_cost_item() {
  [ $# -eq 1 ] || usage
  local st rc s n k
  st="$(_stat "$1")"; rc=$?
  if [ $rc -eq 1 ]; then echo "· 비용 기록 없음"; return 0; fi
  if [ $rc -ne 0 ]; then echo "· 비용 집계 불가"; return 0; fi
  set -- $st; s=$1; n=$2; k=$3
  if [ "$n" -ge 1 ]; then
    awk -v s="$s" -v k="$k" 'BEGIN{ printf "· 비용 $%.4f (확인 불가 %d회)\n", s, k }'
  elif [ "$k" -ge 1 ]; then
    echo "· 비용 확인 불가 (${k}회)"
  else
    echo "· 비용 기록 없음"
  fi
}

cmd_cost_total() {
  [ $# -ge 1 ] || return 0
  local f st rc s n k S=0 N=0 K=0 M=0
  for f in "$@"; do
    st="$(_stat "$f")"; rc=$?
    if [ $rc -eq 2 ]; then
      echo "실행 비용 합계: 집계 불가 — 비용 기록 파일을 읽을 수 없음: $f"
      return 0
    fi
    if [ $rc -eq 1 ]; then M=$((M+1)); continue; fi
    set -- $st; s=$1; n=$2; k=$3
    S="$(awk -v a="$S" -v b="$s" 'BEGIN{ printf "%.10g", a+b }')"
    N=$((N+n)); K=$((K+k))
    if [ "$n" -eq 0 ] && [ "$k" -eq 0 ]; then M=$((M+1)); fi
  done
  if [ "$N" -ge 1 ]; then
    awk -v s="$S" -v k="$K" -v m="$M" 'BEGIN{
      printf "실행 비용 합계: $%.4f (정가 환산, 리뷰 도구 비용 제외) · 확인 불가 %d회", s, k
      if (k > 0 || m > 0) printf " — 실제 비용은 더 큼"
      printf "\n" }'
  else
    echo "실행 비용 합계: 확인 불가 — 확인 불가 ${K}회 · 비용 기록 없음 ${M}항목"
  fi
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  route)      cmd_route "$@" ;;
  tokens)     cmd_tokens ;;
  cost-item)  cmd_cost_item "$@" ;;
  cost-total) cmd_cost_total "$@" ;;
  *) usage ;;
esac
