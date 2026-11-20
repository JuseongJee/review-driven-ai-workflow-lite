#!/usr/bin/env bash
# 병렬 줄기 감시. 상태가 바뀔 때만 한 줄씩 출력합니다(Monitor 이벤트용). bash 3.2 호환.
#   STREAM <slug> <idle|done|blocked|gone>   세션 상태 변화
#   CTX <slug> <N>%                           턴이 끝난 세션의 컨텍스트가 문턱(기본 85) 이상
#   QUEUE <발행 큐 줄;...>                    발행 큐에 처리할 요청이 생김
#   QUEUE 조회 실패 (rc=N): <오류 첫 줄>       발행 큐를 읽지 못함(그동안 생존 표시를 남기지 않음). 회복하면 처리할 큐 줄을 QUEUE 로 다시 냄
#   REPORT <절대 경로>                        줄기가 질문(-question.md)·마감 보고(-closing.md)를 새로 씀
# 줄기 목록: <상태 폴더>/active.tsv 첫 열. 보고 폴더: <상태 폴더>/reports/
# 발행 큐를 읽은 반복마다 큐에 감시 생존 표시를 남깁니다(작업 세션의 rd publish request·wait 가 감시 없음을 경고하는 근거).
# 큐를 읽지 못한 반복은 표시를 남기지 않으므로, 조회 실패가 5분 넘게 이어지면 작업 세션도 경고합니다.
# 큐 명령은 rd 를 거치지 않습니다(rd 는 하위 명령 전에 기본 체크아웃의 작업 상태를 점검하며, 그 실패가 큐 조회를 막지 않게 함).
# env: RD_FR_DO_WATCH_INTERVAL(30) RD_FR_DO_CTX_LIMIT(85)
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
QUEUE_CMD="${RD_FR_DO_QUEUE_CMD:-bash rd-workflow/scripts/lifecycle/publish_queue.sh status}"
BEAT_CMD="${RD_FR_DO_BEAT_CMD:-bash rd-workflow/scripts/lifecycle/publish_queue.sh _beat fr-do}"
mkdir -p "$REPORTS"
# 키별 상태는 임시 디렉터리의 파일로 둡니다(bash 3.2 에는 연관 배열이 없음).
ST="$(mktemp -d "${TMPDIR:-/tmp}/fr-do-watch.XXXXXX")" || exit 1
trap 'rm -rf "$ST"' EXIT
trap 'exit 0' INT TERM
get() { cat "$ST/$1" 2>/dev/null; }
put() { printf '%s' "$2" > "$ST/$1"; }
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
  if [[ -f "$LIST" ]]; then
    while IFS=$'\t' read -r s _ <&3; do
      [[ -z "$s" ]] && continue
      # herdr 에이전트 이름은 slug 와 다를 수 있습니다(32자 초과면 잘림). 이벤트 줄은 slug 를 씁니다.
      info="$(herdr agent get "$(fr_do_agent_name "$s")" </dev/null 2>/dev/null)"
      st="$(printf '%s' "$info" | grep -o '"agent_status":"[a-z]*"' | head -1 | cut -d'"' -f4)"
      [[ -z "$st" ]] && st=gone
      if [[ "$st" == idle || "$st" == done ]]; then
        pn="$(printf '%s' "$info" | grep -o '"pane_id":"[^"]*"' | cut -d'"' -f4)"
        pct="$(herdr pane read "$pn" --source visible --lines 8 </dev/null 2>/dev/null | grep -o '[0-9]*% [0-9]*k/' | head -1 | cut -d% -f1)"
        if [[ -n "$pct" && "$pct" -ge "$CTX_LIMIT" && "$(get "ctx.$s")" != 1 ]]; then
          echo "CTX $s $pct%"; put "ctx.$s" 1
        fi
        [[ -n "$pct" && "$pct" -lt "$CTX_LIMIT" ]] && put "ctx.$s" ""
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
    q="$(printf '%s\n' "$qraw" | grep -v "성공  -  → 없음" | grep -E "요청됨|실패|충돌|승인|진행" || true)"
    if [[ "$q" != "$prevq" && -n "$q" ]]; then
      echo "QUEUE $(printf '%s' "$q" | tr '\n' ';')"
    fi
    prevq="$q"
  fi
  sleep "${RD_FR_DO_WATCH_INTERVAL:-30}"
done
