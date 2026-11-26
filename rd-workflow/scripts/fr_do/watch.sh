#!/usr/bin/env bash
# 병렬 줄기 감시. 상태가 바뀔 때만 한 줄씩 출력합니다(Monitor 이벤트용). bash 3.2 호환.
#   STREAM <slug> <idle|done|blocked|gone>   세션 상태 변화
#   CTX <slug> <N>% <idle|done|working> @<구간>       세션의 컨텍스트가 문턱(기본 85) 이상
#   CTX <slug> <N>% <idle|done|working> 긴급 @<구간>  세션의 컨텍스트가 긴급 문턱(기본 100) 이상
#     구간은 문턱을 넘은 때부터 문턱 아래로 내려갈 때까지이고, <구간> 은 그 시작 시각(epoch 초)입니다. 같은 구간의 두 줄은 같은 <구간> 을 씁니다.
#     줄기마다 구간의 문턱 줄 한 번, 긴급 줄 한 번을 냅니다. 상태가 바뀌거나 감시를 다시 걸어도 다시 내지 않습니다.
#     긴급 줄은 같은 구간의 문턱 줄을 낸 뒤에만 냅니다(문턱을 거치지 않고 긴급 문턱을 넘으면 문턱 줄·긴급 줄 순서로 함께 냄).
#   QUEUE <발행 큐 줄;...>                    발행 큐에 처리할 요청이 생김
#   QUEUE 조회 실패 (rc=N): <오류 첫 줄>       발행 큐를 읽지 못함(그동안 생존 표시를 남기지 않음). 회복하면 처리할 큐 줄을 QUEUE 로 다시 냄
#   REPORT <절대 경로>                        줄기가 질문(-question.md)·마감 보고(-closing.md)를 새로 씀
#     같은 체크아웃에서 감시가 여럿 돌면 담당 감시 하나만 CTX 를 냅니다. 담당은 살아 있는 동안 바뀌지 않습니다.
# 줄기 목록: <상태 폴더>/active.tsv 첫 열(로컬 브랜치 fr/<slug> 가 없는 낡은 줄은 건너뜀). 보고 폴더: <상태 폴더>/reports/. 컨텍스트 알림 기록: <상태 폴더>/watch-ctx/<slug>.1·.2
# CTX 담당 감시 기록: <상태 폴더>/watch-owner/owner.<세대>(내용: 그 세대 담당 감시의 PID). 가장 큰 세대가 지금 담당입니다.
# 발행 큐를 읽은 반복마다 큐에 감시 생존 표시를 남깁니다(작업 세션의 rd publish request·wait 가 감시 없음을 경고하는 근거).
# 큐를 읽지 못한 반복은 표시를 남기지 않으므로, 조회 실패가 5분 넘게 이어지면 작업 세션도 경고합니다.
# 큐 명령은 rd 를 거치지 않습니다(rd 는 하위 명령 전에 기본 체크아웃의 작업 상태를 점검하며, 그 실패가 큐 조회를 막지 않게 함).
# env: RD_FR_DO_WATCH_INTERVAL(30) RD_FR_DO_CTX_LIMIT(85) RD_FR_DO_CTX_URGENT(100)
#      RD_FR_DO_QUEUE_CMD(bash rd-workflow/scripts/lifecycle/publish_queue.sh status)
#      RD_FR_DO_BEAT_CMD(bash rd-workflow/scripts/lifecycle/publish_queue.sh _beat fr-do)
# 실행: bash rd-workflow/scripts/fr_do/watch.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_state.sh"
ROOT="$(fr_do_main_root)" || exit 1
cd "$ROOT" || exit 1
STATE="$(fr_do_state_dir)" || exit 1
LIST="$STATE/active.tsv"
REPORTS="$STATE/reports"
CTX_LIMIT="${RD_FR_DO_CTX_LIMIT:-85}"
CTX_URGENT="${RD_FR_DO_CTX_URGENT:-100}"
QUEUE_CMD="${RD_FR_DO_QUEUE_CMD:-bash rd-workflow/scripts/lifecycle/publish_queue.sh status}"
BEAT_CMD="${RD_FR_DO_BEAT_CMD:-bash rd-workflow/scripts/lifecycle/publish_queue.sh _beat fr-do}"
CTXD="$STATE/watch-ctx"
# 담당 파일은 알림 기록과 다른 폴더에 둡니다. 같은 폴더면 slug 가 owner 인 줄기의 기록(owner.1·.2)과 이름이 겹칩니다(턴 024 F12).
OWND="$STATE/watch-owner"
OWNF="$OWND/owner"   # 세대 파일 이름 앞부분(owner.<세대>)
mkdir -p "$REPORTS" "$CTXD" "$OWND"
# 키별 상태는 임시 디렉터리의 파일로 둡니다(bash 3.2 에는 연관 배열이 없음).
ST="$(mktemp -d "${TMPDIR:-/tmp}/fr-do-watch.XXXXXX")" || exit 1
trap 'rm -rf "$ST"; rm -f "$OWNF.tmp.$$" "$OWND/rec.tmp.$$"' EXIT
trap 'exit 0' INT TERM
get() { cat "$ST/$1" 2>/dev/null; }
put() { printf '%s' "$2" > "$ST/$1"; }
# 컨텍스트 알림 기록은 상태 폴더에 둡니다. Monitor 만료로 감시를 다시 걸어도 같은 구간을 다시 알리지 않습니다.
# 단계마다 파일 하나입니다: <slug>.1(문턱 알림)·<slug>.2(긴급 알림), 내용 "<구간> <pane> <출력>".
# <출력> 은 기록을 만들 때 0 이고 그 줄을 낸 뒤 1 로 바꿉니다. 기록을 만든 뒤 줄을 내기 전에 감시가 끝나면 0 으로 남으므로,
# 다음 담당이 그 줄을 같은 구간 ID 로 냅니다(턴 024 F13). 줄을 낸 직후 1 로 바꾸기 전에 끝나면 같은 줄이 한 번 더 나갈 수 있고,
# 호출 세션은 같은 구간 ID 의 처리 기록으로 그 줄을 알아봅니다(do.md).
# 기록은 담당 감시 하나만 씁니다. 임시 파일에 다 쓴 뒤 mv 로 한 번에 바꾸므로, 쓰는 도중에 감시가 끝나도 기록이 빈 채로 남지 않습니다(턴 026 F14).
# 임시 파일은 같은 상태 폴더 아래(watch-owner/)에 둡니다. 다른 파일 시스템이면 mv 가 한 번에 바뀌지 않습니다.
cread() { cat "$CTXD/$1" 2>/dev/null; }
cset() { printf '%s' "$2" > "$OWND/rec.tmp.$$" && mv -f "$OWND/rec.tmp.$$" "$CTXD/$1"; }
cclear() { rm -f "$CTXD/$1.1" "$CTXD/$1.2"; }
# CTX 는 담당 감시 하나만 판단합니다. 감시마다 판단하면 기록을 읽고 쓰는 사이에 다른 감시가 끼어들어 같은 구간을 두 번 알리거나
# 긴급 줄이 문턱 줄을 앞지릅니다(final diff review 턴 014~022). 담당은 가장 큰 세대 파일(watch-owner/owner.<세대>)에 PID 를 적은 감시입니다.
# 담당이 살아 있는 동안에는 다른 감시가 더 큰 세대를 만들지 않으므로 담당이 바뀌지 않습니다.
# 담당 파일이 없거나 담당이 죽었으면 다음 세대 파일을 만들어 이어받습니다. 다 쓴 임시 파일을 하드 링크로 걸므로(이미 있으면 실패)
# 같은 세대는 한 감시만 가집니다. 이어받을 때 남의 파일을 옮기거나 지우지 않으므로 지금 담당의 파일이 잠시라도 사라지지 않습니다.
# 살아 있는지는 kill -0 로 보고, 그 PID 가 이 감시 스크립트인지 ps 로 확인합니다. ps 를 쓸 수 없는 환경이면 kill -0 결과만 씁니다.
alive_watch() {
  [[ "$1" == "$$" ]] && return 0
  kill -0 "$1" 2>/dev/null || return 1
  local c
  c="$(ps -p "$1" -o command= 2>/dev/null)" || return 0
  [[ "$c" == *fr_do/watch.sh* ]]
}
# 세대 번호 목록과 가장 큰 세대. 끝난 담당의 파일은 남겨 둡니다. 지우면 가장 큰 세대가 작아져, 그 순간 낮은 세대로 담당이 된 감시와
# 오래 멈췄다 깨어나 높은 세대를 만든 감시가 겹칠 수 있습니다. 남은 파일은 PID 가 죽었으므로 다음 감시가 이어받고 그 감시가 지웁니다.
owner_gens() { local f n; for f in "$OWNF".*; do n="${f##*/owner.}"; [[ "$n" =~ ^[0-9]+$ ]] && echo "$n"; done; }
owner_gen() { owner_gens | sort -n | tail -1; }
ctx_owner() {
  local g o r k
  g="$(owner_gen)"
  if [[ -n "$g" ]]; then
    o="$(cat "$OWNF.$g" 2>/dev/null)"
    [[ "$o" == "$$" ]] && return 0
    alive_watch "$o" && return 1
  else
    g=0
  fi
  printf '%s' "$$" > "$OWNF.tmp.$$"
  ln "$OWNF.tmp.$$" "$OWNF.$((g + 1))" 2>/dev/null; r=$?
  rm -f "$OWNF.tmp.$$"
  [[ $r -eq 0 ]] || return 1
  # 오래 멈췄다 깨어난 감시는 이미 정리된 낮은 세대를 만들 수 있습니다. 만든 세대가 가장 큰 세대가 아니면 물러납니다.
  if [[ "$(owner_gen)" != "$((g + 1))" ]]; then rm -f "$OWNF.$((g + 1))"; return 1; fi
  # 지난 세대 파일은 지웁니다. 담당 판정은 가장 큰 세대만 보므로 작은 세대를 지워도 판정이 바뀌지 않습니다.
  for k in $(owner_gens); do
    [[ "$k" -lt "$((g + 1))" ]] && rm -f "$OWNF.$k"
  done
  return 0
}
# reports/*.md 의 "<이름><TAB><mtime>" 줄. 어느 OS 에서나 같게 python 으로 읽습니다(date -r 은 BSD 전용).
report_mtimes() {
  python3 -I -c 'import os,sys
d=sys.argv[1]
for n in sorted(os.listdir(d)):
    p=os.path.join(d,n)
    if n.endswith(".md") and os.path.isfile(p):
        print(n+"\t"+repr(os.stat(p).st_mtime))' "$REPORTS" 2>/dev/null
}
# 알린 보고는 상태 폴더의 watch-seen.tsv("<이름><TAB><mtime>")에 남깁니다. 감시를 다시 걸면 이 기록과 비교하므로
# 이미 알린 보고는 다시 알리지 않고, 감시가 꺼져 있던 동안(첫 기동 전·Monitor 재등록 사이) 쓰인 보고는 알립니다.
SEEN="$STATE/watch-seen.tsv"
if [[ -f "$SEEN" ]]; then
  while IFS=$'\t' read -r n m; do
    [[ -n "$n" ]] && put "seen.$n" "$m"
  done < "$SEEN"
fi
prevq=""
prevqe=""
while true; do
  own=""; ctx_owner && own=1
  if [[ -f "$LIST" ]]; then
    while IFS=$'\t' read -r s _ <&3; do
      [[ -z "$s" ]] && continue
      # 로컬 브랜치 fr/<slug> 가 없다고 git 이 답한(rc 1) 줄은 끝난 줄기의 낡은 줄입니다(pick.py·중복 착수 확인과 같은 기준).
      #   세션을 읽지 않고 건너뜁니다. 같은 slug 로 다시 뜨면 처음부터 알리도록 이전 상태 기억을 지웁니다. git 실패는 건너뛰지 않습니다.
      grc=0; git show-ref --verify --quiet "refs/heads/fr/$s" 2>/dev/null || grc=$?
      if [[ "$grc" -eq 1 ]]; then put "prev.$s" ""; put "rep.$s" ""; continue; fi
      # herdr 에이전트 이름은 slug 와 다를 수 있습니다(32자 초과면 잘림). 이벤트 줄은 slug 를 씁니다.
      info="$(herdr agent get "$(fr_do_agent_name "$s")" </dev/null 2>/dev/null)"
      st="$(printf '%s' "$info" | grep -o '"agent_status":"[a-z]*"' | head -1 | cut -d'"' -f4)"
      [[ -z "$st" ]] && st=gone
      # working 중에도 읽습니다. subagent 를 오래 기다리는 턴은 working 이 이어지는 동안 문턱을 넘습니다(2026-11-22 107%).
      if [[ -n "$own" ]] && [[ "$st" == idle || "$st" == done || "$st" == working ]]; then
        pn="$(printf '%s' "$info" | grep -o '"pane_id":"[^"]*"' | cut -d'"' -f4)"
        scr="$(herdr pane read "$pn" --source visible --lines 8 </dev/null 2>/dev/null)"
        # 상태줄은 입력줄(❯) 아래에 있습니다. 마지막 입력줄 아래에서만 찾아, 작업 출력에 보인 같은 형식의 수치를 읽지 않습니다.
        # 입력줄이 안 보이면(스크롤 등) 상태줄인지 확인할 수 없으므로 읽지 않습니다. 컨텍스트 표시를 끈 세션은 아무것도 찾지 않습니다.
        # self_compact.sh 의 컨텍스트 판독과 같은 식 — 바꾸면 함께 바꿉니다.
        pct="$(printf '%s\n' "$scr" | awk '/^❯/ { f = 1; b = ""; next } f { b = b $0 "\n" } END { printf "%s", b }' | grep -o '[0-9]*% [0-9]*k/' | tail -1 | cut -d% -f1)"
        # 알림 기록은 상태와 무관하게 줄기마다 하나입니다. 문턱 알림 파일(<slug>.1)이 있으면 이번 구간의 문턱 줄을 정했습니다.
        bid=""; bpn=""; bok=""; read -r bid bpn bok <<EOT
$(cread "$s.1")
EOT
        # pane 이 다르면 같은 slug 로 새로 띄운 줄기이므로 이전 줄기의 기록을 지웁니다(감시를 다시 걸면 pane 은 그대로).
        if [[ -n "$bid" && "$bpn" != "$pn" ]]; then cclear "$s"; bid=""; fi
        if [[ -n "$pct" && "$pct" -ge "$CTX_LIMIT" ]]; then
          if [[ -z "$bid" ]]; then
            bid="$(date +%s)"; bok=0; cset "$s.1" "$bid $pn 0"
          fi
          # 문턱 줄을 먼저 냅니다. 출력 표시가 0 이면 아직 내지 않은 줄이므로 같은 구간 ID 로 냅니다.
          if [[ -n "$bid" && "$bok" == 0 ]]; then echo "CTX $s $pct% $st @$bid"; cset "$s.1" "$bid $pn 1"; fi
          if [[ -n "$bid" ]]; then
            ubid=""; upn=""; uok=""; read -r ubid upn uok <<EOT
$(cread "$s.2")
EOT
            if [[ -z "$ubid" && "$pct" -ge "$CTX_URGENT" ]]; then ubid="$bid"; uok=0; cset "$s.2" "$bid $pn 0"; fi
            if [[ -n "$ubid" && "$uok" == 0 ]]; then echo "CTX $s $pct% $st 긴급 @$ubid"; cset "$s.2" "$ubid $pn 1"; fi
          fi
        fi
        [[ -n "$pct" && "$pct" -lt "$CTX_LIMIT" ]] && cclear "$s"
      fi
      if [[ "$(get "prev.$s")" != "$st" ]]; then
        case "$st" in
          blocked|gone) echo "STREAM $s $st"; put "rep.$s" "$st" ;;
          idle|done) [[ "$(get "rep.$s")" != rest ]] && echo "STREAM $s $st"; put "rep.$s" rest ;;
          # 다시 일하기 시작하면 휴지 표시를 지워, 일을 마치고 다시 멈출 때 알립니다(idle·done 사이 전환만 억제).
          *) put "rep.$s" "" ;;
        esac
        put "prev.$s" "$st"
      fi
    done 3< "$LIST"
  fi
  mt="$(report_mtimes)"
  while IFS=$'\t' read -r n m; do
    [[ -n "$n" ]] || continue
    if [[ "$(get "seen.$n")" != "$m" ]]; then
      echo "REPORT $REPORTS/$n"; put "seen.$n" "$m"; printf '%s\t%s\n' "$n" "$m" >> "$SEEN"
    fi
  done <<EOT
$mt
EOT
  qraw="$(bash -c "$QUEUE_CMD" </dev/null 2>"$ST/qerr")"; qrc=$?
  if [[ "$qrc" -ne 0 ]]; then
    qe="QUEUE 조회 실패 (rc=$qrc): $(grep -m1 . "$ST/qerr" 2>/dev/null)"
    [[ "$qe" != "$prevqe" ]] && echo "$qe"
    prevqe="$qe"
    # 회복하면 처리할 큐 줄을 다시 내도록 비웁니다(실패 전과 같은 내용이어도 회복 신호가 됩니다).
    prevq=""
  else
    prevqe=""
    bash -c "$BEAT_CMD" </dev/null >/dev/null 2>&1 || :
    # 상태 단어는 「  → 」 앞(slug·상태·사유)에서만 찾습니다. 뒤의 다음 행동에는 작업 worktree 경로가 들어가므로,
    #   경로에 든 단어(…/승인-…, …/진행중/…)로 허가됨·부분 완료 줄이 걸리지 않게 합니다. 걸린 줄은 통째로 냅니다.
    q="$(printf '%s\n' "$qraw" | grep -v "성공  -  → 없음" | awk '{ h = $0; i = index(h, "  → "); if (i) h = substr(h, 1, i - 1) } h ~ /요청됨|실패|충돌|승인|진행/' || true)"
    if [[ "$q" != "$prevq" && -n "$q" ]]; then
      echo "QUEUE $(printf '%s' "$q" | tr '\n' ';')"
    fi
    prevq="$q"
  fi
  sleep "${RD_FR_DO_WATCH_INTERVAL:-30}"
done
