#!/usr/bin/env bash
# 호출 세션 자기 압축. 줄기를 지휘하는 호출 세션이 안전한 때에 스스로 /compact 를 보냅니다. bash 3.2 호환.
# 사용(턴을 끝내기 직전 run_in_background): bash rd-workflow/scripts/fr_do/self_compact.sh [기준%=80] [최대 대기초=600] [회차]
# 동작: 이 세션(HERDR_PANE_ID)이 idle·done 이고, 입력줄이 「비었다」 고 확인되고, 컨텍스트가 기준 이상일 때만
# `/compact` 를 보냅니다. 안 맞으면 대기 상한까지 RD_FR_DO_COMPACT_POLL(기본 5)초마다 다시 보고, 끝내 안 맞으면 보내지 않습니다.
# 빈 입력의 증거: pane read 가 성공(rc 0)하고, ❯ 로 시작하는 입력줄이 있고, 그 뒤가 공백뿐일 때만입니다.
# 판독 실패·입력줄 부재는 빈 입력이 아닙니다(그 회차에는 보내지 않음). 첫 판독과 보내기 직전 재확인 모두 같은 기준입니다.
# 컨텍스트 비율의 증거: 마지막 입력줄 아래 상태줄의 `N% Nk/` 입니다. 재확인 화면에서도 기준 이상이어야 보냅니다.
# 출력: SENT <N>% / SKIP <사유> (마지막 한 줄). rc 는 항상 0. [회차] 를 주면 줄 끝에 ` 회차=<값>` 을 붙입니다.
# 완료 알림은 압축 뒤에 올 수 있으므로, 호출 세션은 이 값으로 결과를 건 회차에 연결합니다.
# 대기 상한 SKIP 의 사유는 원인 하나를 문장으로 밝히고 진단 값을 괄호로 붙입니다. 호출 세션은 이 문장으로 알릴지 정합니다(fr/do.md 「호출 세션의 압축」).
#   승인·선택 창이 떠 있음(blocked) / 세션이 계속 작업 중(working) / 세션 상태를 확인하지 못함 — 마지막 상태가 idle·done 이 아님. 일시 사유이며 가장 먼저 봅니다
#   입력창에 글이 남아 있음 — 마지막 판독의 입력줄에 글이 있음. 일시 사유
#   상태줄의 컨텍스트 표시를 읽지 못함 — 마지막 판독에서 빈 입력줄은 보였는데 대기 내내 비율을 한 번도 읽지 못함(고정 사유)
#   상태줄·입력줄이 화면에서 가려짐 — 그 밖(입력줄이 안 보임, 전에는 읽었던 비율이 사라짐). 일시 사유
set -u
limit="${1:-80}"; wait_max="${2:-600}"; round="${3:-}"
# out <결과>: 마지막 줄을 내고 끝냅니다.
out() { if [[ -n "$round" ]]; then echo "$1 회차=$round"; else echo "$1"; fi; exit 0; }
poll="${RD_FR_DO_COMPACT_POLL:-5}"
pane="${HERDR_PANE_ID:-}"
[[ -n "$pane" ]] || out "SKIP herdr pane 아님(HERDR_PANE_ID 없음)"

# read_screen: 화면을 SCREEN 에 담고, 입력줄 상태를 INPUT_STATE(empty|typing|unknown)에, 상태줄 비율을 PCT(없으면 빈 값)에 둡니다.
read_screen() {
  local line
  SCREEN="$(herdr pane read "$pane" --source visible --lines 8 </dev/null 2>/dev/null)" || { SCREEN=""; INPUT_STATE=unknown; PCT=""; return; }
  line="$(printf '%s\n' "$SCREEN" | grep '^❯' | tail -1)"
  if [[ -z "$line" ]]; then INPUT_STATE=unknown
  elif [[ -z "$(printf '%s' "${line#❯}" | tr -d '[:space:]')" ]]; then INPUT_STATE=empty
  else INPUT_STATE=typing; fi
  # 상태줄은 입력줄(❯) 아래에 있습니다. 마지막 입력줄 아래에서만 찾아, 작업 출력·지난 입력에 보인 같은 형식의 수치를 읽지 않습니다.
  # 입력줄이 안 보이면 비율을 읽지 않습니다(그 회차는 판단을 미룹니다). watch.sh 의 컨텍스트 판독과 같은 식 — 바꾸면 함께 바꿉니다.
  PCT="$(printf '%s\n' "$SCREEN" | awk '/^❯/ { f = 1; b = ""; next } f { b = b $0 "\n" } END { printf "%s", b }' | grep -o '[0-9]*% [0-9]*k/' | tail -1 | cut -d% -f1)"
}

start=$(date +%s); pct=""; seen=""
while :; do
  st="$(herdr agent get "$pane" </dev/null 2>/dev/null | grep -o '"agent_status":"[a-z]*"' | head -1 | cut -d'"' -f4)"
  read_screen
  pct="$PCT"; [[ -n "$pct" ]] && seen=1
  if [[ -n "$pct" && "$pct" -lt "$limit" ]]; then out "SKIP 컨텍스트 ${pct}% < ${limit}%"; fi
  if [[ ( "$st" == idle || "$st" == done ) && -n "$pct" && "$INPUT_STATE" == empty ]]; then
    # 보내기 직전에 한 번 더 읽습니다(사람이 막 치기 시작한 경우, 화면이 다시 그려져 상태줄이 사라진 경우). 재확인도 같은 증거 기준입니다.
    read_screen
    # 재확인에서 기준 아래를 읽었으면 압축할 필요가 없습니다. 첫 판독과 같은 결과로 끝냅니다.
    if [[ -n "$PCT" && "$PCT" -lt "$limit" ]]; then out "SKIP 컨텍스트 ${PCT}% < ${limit}%"; fi
    if [[ "$INPUT_STATE" == empty && -n "$PCT" && "$PCT" -ge "$limit" ]]; then
      herdr agent prompt "$pane" "/compact" </dev/null >/dev/null 2>&1 && out "SENT ${PCT}%"
      out "SKIP /compact 입력 실패(herdr agent prompt) — 컨텍스트 ${PCT}%"
    fi
  fi
  if (( $(date +%s) - start >= wait_max )); then
    # 원인은 마지막 반복의 판독으로 고릅니다. 승인 창·작업 중·입력 중은 상태줄 판정보다 먼저 봅니다
    # (처음부터 그 상태면 비율을 한 번도 못 읽지만 상태줄 설정 문제가 아닙니다).
    if [[ "$st" == blocked ]]; then why="승인·선택 창이 떠 있음"
    elif [[ "$st" == working ]]; then why="세션이 계속 작업 중"
    elif [[ "$st" != idle && "$st" != done ]]; then why="세션 상태를 확인하지 못함"
    elif [[ "$INPUT_STATE" == typing ]]; then why="입력창에 글이 남아 있음"
    # 고정 사유는 빈 입력줄 아래에 비율이 끝내 없을 때만입니다. 입력줄 자체가 안 보이면 화면 문제(일시)로 봅니다.
    elif [[ -z "$seen" && "$INPUT_STATE" == empty ]]; then why="상태줄의 컨텍스트 표시를 읽지 못함"
    else why="상태줄·입력줄이 화면에서 가려짐"; fi
    out "SKIP 대기 상한 ${wait_max}초 — ${why} (상태=${st:-?} 컨텍스트=${pct:-?}% 입력줄=$INPUT_STATE)"
  fi
  sleep "$poll"
done
