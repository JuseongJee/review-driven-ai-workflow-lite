#!/usr/bin/env bash
# 호출 세션 자기 압축. 줄기를 지휘하는 호출 세션이 안전한 때에 스스로 /compact 를 보냅니다. bash 3.2 호환.
# 사용(턴을 끝내기 직전 run_in_background): bash rd-workflow/scripts/fr_do/self_compact.sh [기준%=80] [최대 대기초=600]
# 동작: 이 세션(HERDR_PANE_ID)이 idle·done 이고, 입력줄이 「비었다」 고 확인되고, 컨텍스트가 기준 이상일 때만
# `/compact` 를 보냅니다. 안 맞으면 대기 상한까지 RD_FR_DO_COMPACT_POLL(기본 5)초마다 다시 보고, 끝내 안 맞으면 보내지 않습니다.
# 빈 입력의 증거: pane read 가 성공(rc 0)하고, ❯ 로 시작하는 입력줄이 있고, 그 뒤가 공백뿐일 때만입니다.
# 판독 실패·입력줄 부재는 빈 입력이 아닙니다(그 회차에는 보내지 않음). 첫 판독과 보내기 직전 재확인 모두 같은 기준입니다.
# 출력: SENT <N>% / SKIP <사유> (마지막 한 줄). rc 는 항상 0.
set -u
limit="${1:-80}"; wait_max="${2:-600}"
poll="${RD_FR_DO_COMPACT_POLL:-5}"
pane="${HERDR_PANE_ID:-}"
[[ -n "$pane" ]] || { echo "SKIP herdr pane 아님(HERDR_PANE_ID 없음)"; exit 0; }

# read_screen: 화면을 SCREEN 에 담고, 입력줄 상태를 INPUT_STATE(empty|typing|unknown)에 둡니다.
read_screen() {
  local line
  SCREEN="$(herdr pane read "$pane" --source visible --lines 8 </dev/null 2>/dev/null)" || { SCREEN=""; INPUT_STATE=unknown; return; }
  line="$(printf '%s\n' "$SCREEN" | grep '^❯' | tail -1)"
  if [[ -z "$line" ]]; then INPUT_STATE=unknown
  elif [[ -z "$(printf '%s' "${line#❯}" | tr -d '[:space:]')" ]]; then INPUT_STATE=empty
  else INPUT_STATE=typing; fi
}

start=$(date +%s); pct=""
while :; do
  st="$(herdr agent get "$pane" </dev/null 2>/dev/null | grep -o '"agent_status":"[a-z]*"' | head -1 | cut -d'"' -f4)"
  read_screen
  pct="$(printf '%s\n' "$SCREEN" | grep -o '[0-9]*% [0-9]*k/' | head -1 | cut -d% -f1)"
  if [[ -n "$pct" && "$pct" -lt "$limit" ]]; then echo "SKIP 컨텍스트 ${pct}% < ${limit}%"; exit 0; fi
  if [[ ( "$st" == idle || "$st" == done ) && -n "$pct" && "$INPUT_STATE" == empty ]]; then
    # 보내기 직전에 한 번 더 읽습니다(사람이 막 치기 시작한 경우). 재확인도 같은 증거 기준입니다.
    read_screen
    if [[ "$INPUT_STATE" == empty ]]; then
      herdr agent prompt "$pane" "/compact" </dev/null >/dev/null 2>&1 && { echo "SENT ${pct}%"; exit 0; }
      echo "SKIP agent prompt 실패"; exit 0
    fi
  fi
  if (( $(date +%s) - start >= wait_max )); then
    echo "SKIP 대기 상한 ${wait_max}초 — 상태=${st:-?} 컨텍스트=${pct:-?}% 입력줄=$INPUT_STATE"; exit 0
  fi
  sleep "$poll"
done
