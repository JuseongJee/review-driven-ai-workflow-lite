#!/usr/bin/env bash
# autopilot_headless.sh — autopilot 무인(headless) 진입 wrapper.
# 환경변수로 FR/모드/종료정책을 받아 claude -p 헤드리스 세션을 기동하고,
# skill 이 남긴 outcome 파일을 의미적 exit code 로 매핑한다.
# 오케스트레이션 지능은 넣지 않는다 (front-end 소관).
#
# 환경변수:
#   RD_AUTOPILOT_FR      <slug>|auto      (필수 — 무인 분기 활성화 신호)
#   RD_AUTOPILOT_MODE    A|B              (기본 A — skill 이 해석)
#   RD_FINISH_POLICY     push|merge|none  (기본 push — skill 이 해석)
#   RD_AUTOPILOT_OUTCOME_FILE  outcome 파일 경로 (기본 rd-workflow-workspace/.autopilot-outcome)
#   RD_AUTOPILOT_HEADLESS_NO_INVOKE=1     claude -p 호출 생략 (테스트용 — 매핑만)
#   BASH_DEFAULT_TIMEOUT_MS  자식 세션의 Bash 기본 timeout(ms). 미설정·빈 값이면 7500000 을 넘긴다.
#                            비어 있지 않은 값은 그대로 전달한다 (BASH_MAX_TIMEOUT_MS 는 건드리지 않는다)
#   RD_FR_WALL_MINUTES       이 호출 1회의 경과 시간 상한(분, 소수 허용). 0 은 상한 없음.
#                            미설정이면 config/loop-guard.json 의 wall_minutes, 그것도 없으면 240.
#   RD_FR_WALL_GRACE_SECONDS 상한 도달 뒤 TERM 에서 KILL 까지의 유예(1~120 정수, 기본 30)
#
# exit code: 0 completed / 10 resume / 20 blocked / 30 queue-empty / 31 queue-blocked / 40 harness-error
# claude 자신의 종료 코드는 exit code 로 쓰지 않는다 (outcome 토큰이 우선). 항상 stderr 에 적고,
# outcome 이 없어 40 이 될 때만 요약 줄에 원인(비정상 종료·신호 종료·정상 종료)을 붙인다.
# 상한 도달: outcome blocked:time-cap (후손 회수 실패는 blocked:time-cap-unreaped) → exit 20 (중단 조건 8)
set -uo pipefail

# 이 wrapper 는 정의상 무인 진입점이다 — 사람이 보는 화면이 없다. 그러므로 이 아래에서
# 도는 모든 것은 자식 세션이며, 또 다른 대화형 세션을 기동해서는 안 된다.
# `session_launch` 는 이 변수가 있으면 기동을 건너뛰고 none 을 반환한다.
# export 자리가 여기인 이유: 호출자(batch 국면 2 등)마다 변수를 기억하게 두면 한 곳만
# 빠져도 같은 결함이 재발한다. 무인이라는 사실을 아는 것은 이 스크립트 자신이다.
# (2026-09-24 /fr batch 회귀 — promote 가 FR 마다 herdr 탭을 띄워 batch 가 exit 10 으로 멈췄다)
export RD_CHILD_SESSION=1

# 자식 세션의 Bash 기본 timeout(ms). 무인 세션이 self_test(그룹 1~3분, 전수 약 12분) 같은
# 검증을 foreground 로 돌려도 120초 기본 timeout 에 걸려 죽지 않게 올려 넘긴다.
# 7500000 = 리뷰 어댑터 절대 상한 WAIT_TIMEOUT(7200초) + 5분 여유 — 바깥 Bash 대기가
# 안쪽 watchdog 보다 커야 watchdog 이 먼저 동작한다. Claude Code 의 유효 상한은
# BASH_DEFAULT_TIMEOUT_MS 와 BASH_MAX_TIMEOUT_MS 중 큰 값이라 이 값 하나가 요구를 진다.
# 대가: 정말 멈춘 비리뷰 명령은 최대 125분 매달린다. 호출자가 env 로 낮출 수 있다.
# (FR headless-verification-exceeds-bash-timeout)
DEFAULT_BASH_TIMEOUT_MS=7500000

OUTCOME_FILE="${RD_AUTOPILOT_OUTCOME_FILE:-rd-workflow-workspace/.autopilot-outcome}"

# outcome 경로를 **호출자 기준 절대경로로 고정**한다. 이 wrapper 는 자신의 CWD 에서 파일을
# 비우고 같은 자리에서 읽는데, 자식 세션은 promote 가 만든 작업 worktree 로 이동해 이어간다
# (WORKFLOW.md 「이어서 진행할 때는 대상 worktree 로 먼저 이동합니다」). 상대경로를 그대로
# 넘기면 자식은 worktree 안의 다른 파일에 쓰고, wrapper 는 빈 파일을 읽어 완주를 exit 40
# (harness-error) 으로 오판한다. resume·blocked 의 중단 이유도 부모에 닿지 않는다.
case "$OUTCOME_FILE" in
  /*) ;;
  *)  OUTCOME_FILE="${PWD}/${OUTCOME_FILE}" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── FR 경과 시간 상한 (중단 조건 8) ───────────────────────────────────────────
# 아래 함수는 테스트(test_autopilot_headless_timecap.sh)가 정의를 뽑아 직접 호출한다.
# 함수 시작·끝 중괄호를 줄 맨 앞에 둔다.

# decide_timecap_outcome <미회수 수> <outcome 첫 토큰> — 상한 발동 뒤 최종 결과를 stdout 으로 낸다.
# 회수 실패가 완료 기록보다 우선한다 (미회수 프로세스가 남은 채 다음 FR 이 시작되면 안 된다).
decide_timecap_outcome() {
  local unreaped="${1:-0}" raw="${2:-}"
  if (( unreaped > 0 )); then echo "time-cap-unreaped"
  elif [[ "$raw" == "completed" ]]; then echo "completed"
  else echo "time-cap"
  fi
}

# list_open_review_sessions <worktree> — 그 worktree 에서 아직 닫히지 않은(awaiting-*) 리뷰 세션 경로. 읽기 전용.
list_open_review_sessions() {
  local wt="$1" pat="$1/rd-workflow-workspace/handoffs/review_pipeline/*/SESSION.md"
  compgen -G "$pat" >/dev/null || return 0
  awk '
    FNR==1 { want=0 }
    /^## Status/ { getline; gsub(/[[:space:]]/, "")
      if ($0=="awaiting-author" || $0=="awaiting-reviewer" || $0=="awaiting-user") print FILENAME }
  ' $pat | sed 's#/SESSION.md$##'
}

# diag_lines — outcome 둘째 줄 이후에 붙일 진단. 작업 파일은 읽기만 한다.
# 대상 worktree = `git worktree list` 의 worktree 중 CURRENT_TASK.md Status 가 대기 중이 아닌 것 + 호출 위치($PWD).
# (`rd task list` 는 수 초 걸려 상한 도달 뒤 반환이 늦어지므로 쓰지 않는다.)
# 열린 리뷰 세션은 worktree 마다 최근 5건만 적고 나머지는 건수로 줄인다.
diag_lines() {
  local wt wts="" slug st n=0 sessions total
  while IFS= read -r wt; do
    [[ -f "$wt/CURRENT_TASK.md" ]] || continue
    st="$(awk '/^## Status/{getline; print; exit}' "$wt/CURRENT_TASK.md" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$st" && "$st" != "대기 중" ]] || continue
    slug="$(awk '/^## Short Title/{getline; print; exit}' "$wt/CURRENT_TASK.md" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    echo "작업 상태: ${slug:--} ${st} ${wt}"; n=$((n + 1))
    wts="${wts}${wt}"$'\n'
  done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10)}')
  (( n == 0 )) && echo "작업 상태: 판정 실패"
  wts="${wts}${PWD}"
  printf '%s\n' "$wts" | awk 'NF && !seen[$0]++' | while IFS= read -r wt; do
    sessions="$(list_open_review_sessions "$wt" | sort -r)"
    [[ -n "$sessions" ]] || continue
    total="$(printf '%s\n' "$sessions" | grep -c .)"
    printf '%s\n' "$sessions" | head -n 5 | sed 's/^/열린 리뷰 세션: /'
    (( total > 5 )) && echo "열린 리뷰 세션: (${wt} 외 $((total - 5))건 생략)"
  done
}

# write_timecap_outcome <최종토큰: time-cap|time-cap-unreaped> <경과분> <상한분> <출처> <미회수목록파일> <completed였는지 0|1>
# $OUTCOME_FILE 을 다시 쓴다. 작업 파일(CURRENT_TASK.md·FR·리뷰 세션)은 쓰지 않는다.
write_timecap_outcome() {
  local token="$1" elapsed="$2" cap="$3" src="$4" ufile="$5" was_completed="$6"
  {
    echo "blocked:${token}"
    echo "경과 ${elapsed}분 / 상한 ${cap}분 (${src})"
    if [[ "$token" == "time-cap-unreaped" && -s "$ufile" ]]; then
      sed 's/^/잔여 프로세스: /' "$ufile"
    fi
    if [[ "$token" == "time-cap-unreaped" && "$was_completed" == "1" ]]; then
      echo "작업은 completed 로 기록됨"
    fi
    diag_lines
  } > "$OUTCOME_FILE" 2>/dev/null || echo "autopilot_headless: 경고 — time-cap outcome 기록 실패: $OUTCOME_FILE" >&2
}

# ps_all — 모든 프로세스를 `pid stat ppid lstart(5단어) command[+환경]` 로 한 번에 낸다.
# 한 번만 부르는 이유: ps 가 느린 환경(샌드박스·프로세스 수천 개)에서 호출 횟수가 곧 반환 지연이다.
# macOS 는 -E, procps(Linux) 는 e 로 환경을 command 뒤에 붙인다.
ps_all() {
  ps -A -E -ww -o pid=,stat=,ppid=,lstart=,command= 2>/dev/null \
    || ps -A eww -o pid=,stat=,ppid=,lstart=,command= 2>/dev/null
}

# collect_targets <child pid> <토큰 패턴 파일> <본 적 있는 프로세스 기록 파일> — 회수 대상 pid(한 줄에 하나).
# ① child ② child 의 ppid 후손 ③ 기록 파일에 있고 지금도 같은 프로세스(pid+시작 시각 일치)인 것
# ④ 환경에 실행 토큰이 있는 프로세스(환경을 읽을 수 있는 경우에 한한다).
# ②③ 이 부모를 잃어 트리에서 떨어진 후손을 잡는다. 호출할 때마다 새로 본 대상을 기록 파일에 더한다.
# 좀비(stat Z)와 wrapper 자신은 제외한다. 토큰은 파일로 읽어 awk 의 인자·환경에 실리지 않게 한다.
collect_targets() {
  local child="$1" tokfile="$2" seenfile="${3:-}" listing
  # 프로세스 목록을 얻지 못한 것(rc 2, seenfile 이 있으면 <seenfile>.fail 표식)과 대상이 없는 것(rc 0, 빈 출력)을 구분한다.
  listing="$(ps_all)" && [[ -n "$listing" ]] || { [[ -n "$seenfile" ]] && : > "${seenfile}.fail"; return 2; }
  printf '%s\n' "$listing" | awk -v c="$child" -v sf="$seenfile" -v tf="$tokfile" '
    BEGIN {
      if (tf != "") { getline tok < tf }
      if (sf != "") while ((getline line < sf) > 0) { split(line, a, "\t"); old[a[1]] = a[2] }
    }
    { n++; id[n]=$1; st[$1]=$2; par[$1]=$3; lst[$1]=$4 " " $5 " " $6 " " $7 " " $8
      if (tok != "" && index($0, tok) > 0) hastok[$1]=1 }
    END {
      # 시작 집합(child + 기록으로 되살린 프로세스 + 토큰 보유 프로세스)을 먼저 모두 세운 뒤 후손 폐쇄를 계산한다.
      # 부모를 잃은 채 추적 중인 프로세스가 새 자식을 낳아도 그 자식이 잡힌다.
      keep[c]=1
      for (p in old) if ((p in st) && lst[p]==old[p]) keep[p]=1
      for (p in hastok) keep[p]=1
      ch=1
      while (ch) { ch=0; for (i=1;i<=n;i++) { p=id[i]; if (!(p in keep) && (par[p] in keep)) { keep[p]=1; ch=1 } } }
      for (p in keep) if ((p in st) && st[p] !~ /^Z/) { print p; if (sf != "") print p "\t" lst[p] >> sf }
    }' 2>/dev/null | sort -un | grep -vx "$$"
  return 0
}

# reap_timecap <child pid> <토큰 패턴 파일> <유예 초> <미회수 목록 파일> <기록 파일> — TERM → 유예 → KILL → 5초 재확인.
# 반환 전에 미회수 목록 파일을 채운다(비어 있으면 회수 성공). 마지막 재수집이 비었을 때만 성공으로 본다.
reap_timecap() {
  local child="$1" tokfile="$2" grace="$3" ufile="$4" seen="$5" pids t0 pg
  : > "$ufile"
  pids="$(collect_targets "$child" "$tokfile" "$seen")"
  [[ -n "$pids" ]] && kill -TERM $pids 2>/dev/null
  t0=$SECONDS
  while (( SECONDS - t0 < grace )); do
    pids="$(collect_targets "$child" "$tokfile" "$seen")"
    [[ -z "$pids" ]] && break
    kill -TERM $pids 2>/dev/null
    sleep 1
  done
  rm -f "${seen}.fail"
  pids="$(collect_targets "$child" "$tokfile" "$seen")"
  if [[ -n "$pids" ]]; then
    kill -KILL $pids 2>/dev/null
    pg="$(ps -o pgid= -p "$child" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$pg" && "$pg" != "$$" ]] && kill -KILL -- "-${pg}" 2>/dev/null
    t0=$SECONDS
    while (( SECONDS - t0 < 5 )); do
      pids="$(collect_targets "$child" "$tokfile" "$seen")"
      [[ -z "$pids" ]] && break
      kill -KILL $pids 2>/dev/null
      sleep 1
    done
    rm -f "${seen}.fail"
    pids="$(collect_targets "$child" "$tokfile" "$seen")"
  fi
  if [[ -n "$pids" ]]; then
    local p
    for p in $pids; do ps -o pid=,command= -p "$p" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-200; done > "$ufile"
    [[ -s "$ufile" ]] || printf '%s (명령 확인 실패)\n' $pids > "$ufile"
  fi
  # 마지막 재수집이 프로세스 목록을 얻지 못했으면 「없음」이 아니라 「확인 불가」다 — 회수 성공으로 세지 않는다.
  if [[ -e "${seen}.fail" ]]; then
    echo "프로세스 목록 조회 실패 — 회수를 확인할 수 없음" >> "$ufile"
  fi
  # 목록과 무관하게 claude 본체가 살아 있으면 미회수다.
  if kill -0 "$child" 2>/dev/null && ! grep -q "^${child} " "$ufile" 2>/dev/null; then
    echo "${child} claude (종료 확인 실패)" >> "$ufile"
  fi
}

# resolve_wall_cap — CAP_MIN / CAP_SRC / GRACE 를 정한다 (설정 해석 우선순위는 위 환경변수 설명).
resolve_wall_cap() {
  local v="" src="" cfg="${LOOP_GUARD_CONFIG:-rd-workflow/config/loop-guard.json}"
  if [[ -n "${RD_FR_WALL_MINUTES:-}" ]]; then v="$RD_FR_WALL_MINUTES"; src="환경변수"
  elif [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r '.wall_minutes // empty' "$cfg" 2>/dev/null || true)"; [[ -n "$v" ]] && src="loop-guard.json"
  fi
  if [[ -z "$v" ]]; then v=240; src="기본값"
  elif [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "autopilot_headless: 경고 — 상한 '${v}' 는 0 이상의 숫자가 아닙니다 (240분으로 대체)" >&2
    src="기본값(잘못된 값 '${v}' 대체)"; v=240
  fi
  CAP_MIN="$v"; CAP_SRC="$src"
  GRACE="${RD_FR_WALL_GRACE_SECONDS:-30}"
  if [[ ! "$GRACE" =~ ^[0-9]+$ ]] || (( 10#$GRACE < 1 || 10#$GRACE > 120 )); then
    echo "autopilot_headless: 경고 — 유예 '${GRACE}' 는 1~120 의 정수가 아닙니다 (30초로 대체)" >&2
    GRACE=30
  fi
  GRACE=$((10#$GRACE))   # 08·010 같은 값을 이후 산술에서 8진수로 다시 읽지 않도록 십진 정수로 고정한다
}

# claude 종료 코드. 실행하지 않았거나(NO_INVOKE) 회수 뒤에도 살아 있어 기다리지 않았으면 빈 값이다.
CLAUDE_RC=

# 1. 실제 실행 시에만 outcome 파일 초기화 (테스트 모드는 심어둔 outcome 보존)
if [[ "${RD_AUTOPILOT_HEADLESS_NO_INVOKE:-0}" != "1" ]]; then
  if [[ -z "${RD_AUTOPILOT_FR:-}" ]]; then
    echo "autopilot_headless: RD_AUTOPILOT_FR 미설정 — 무인 진입 불가" >&2
    exit 40
  fi
  : > "$OUTCOME_FILE" 2>/dev/null || {
    echo "autopilot_headless: outcome 파일 초기화 실패: $OUTCOME_FILE" >&2
    exit 40
  }
  # 유효 timeout 결정 — 빈 문자열은 미설정과 같이 기본값. 비숫자는 값을 바꾸지 않고 경고만.
  if [[ -z "${BASH_DEFAULT_TIMEOUT_MS:-}" ]]; then
    EFFECTIVE_TIMEOUT_MS="$DEFAULT_BASH_TIMEOUT_MS"; TIMEOUT_SOURCE="기본값"
  else
    EFFECTIVE_TIMEOUT_MS="$BASH_DEFAULT_TIMEOUT_MS"; TIMEOUT_SOURCE="호출자 설정"
    if [[ ! "$EFFECTIVE_TIMEOUT_MS" =~ ^[0-9]+$ ]]; then
      echo "autopilot_headless: 경고 — BASH_DEFAULT_TIMEOUT_MS='${EFFECTIVE_TIMEOUT_MS}' 은 숫자가 아닙니다 (그대로 전달)" >&2
    fi
  fi
  echo "autopilot_headless: BASH_DEFAULT_TIMEOUT_MS=${EFFECTIVE_TIMEOUT_MS} (${TIMEOUT_SOURCE})" >&2
  # 2. claude -p 헤드리스 기동 (max-turns 미설정 — 실연 truncation 방지)
  # timeout 은 claude 명령 앞 접두 env 로만 넘긴다 (wrapper 환경에 export 하지 않는다).
  # 경과 시간 상한(중단 조건 8): claude 를 자체 프로세스 그룹의 백그라운드 작업으로 띄우고 폴링으로 감시한다.
  # 실행 토큰은 접두 env 로만 넘겨 wrapper 환경에 두지 않는다 — 회수 스캔이 wrapper 를 후보로 잡지 않게 한다.
  resolve_wall_cap
  if [[ "$CAP_MIN" == "0" || "$CAP_MIN" =~ ^0+(\.0+)?$ ]]; then
    echo "autopilot_headless: FR 경과 시간 상한=상한 없음 (${CAP_SRC})" >&2
    CAP_SEC=0
  else
    echo "autopilot_headless: FR 경과 시간 상한=${CAP_MIN}분 (${CAP_SRC})" >&2
    CAP_SEC="$(awk -v m="$CAP_MIN" 'BEGIN{v=int(m*60+0.999); if (v<1) v=1; print v}')"
  fi
  RUN_TOKEN="RD_FR_RUN_TOKEN=$$-$(date +%s)-${RANDOM}"
  TOKFILE="$(mktemp)" || { echo "autopilot_headless: 임시 파일 생성 실패" >&2; exit 40; }
  UFILE="$(mktemp)" || { echo "autopilot_headless: 임시 파일 생성 실패" >&2; exit 40; }
  SEENFILE="$(mktemp)" || { echo "autopilot_headless: 임시 파일 생성 실패" >&2; exit 40; }
  printf '%s\n' "$RUN_TOKEN" > "$TOKFILE"
  trap 'rm -f "$TOKFILE" "$UFILE" "$SEENFILE" "${SEENFILE}.fail"' EXIT
  START_SEC=$SECONDS
  set -m
  env "$RUN_TOKEN" \
  RD_AUTOPILOT_OUTCOME_FILE="$OUTCOME_FILE" \
  BASH_DEFAULT_TIMEOUT_MS="$EFFECTIVE_TIMEOUT_MS" \
  claude -p "autopilot skill 을 무인(headless) 모드로 실행하라. 환경변수 RD_AUTOPILOT_FR / RD_AUTOPILOT_MODE / RD_FINISH_POLICY 를 읽어 §1 작업선택·모드선택 게이트를 AskUserQuestion 없이 건너뛰고 자율 완주하라. 종료 시 outcome 토큰(completed|resume|blocked:<reason>|queue-empty|queue-blocked)을 \$RD_AUTOPILOT_OUTCOME_FILE 에 기록하라." \
    --permission-mode bypassPermissions \
    --output-format text &
  CHILD=$!
  set +m
  TIMECAP_FIRED=0
  if (( CAP_SEC > 0 )); then
    while kill -0 "$CHILD" 2>/dev/null; do
      if (( SECONDS - START_SEC >= CAP_SEC )); then TIMECAP_FIRED=1; break; fi
      # 폴링마다 후손을 기록해 둔다 — 중간에 부모를 잃은 프로세스도 회수 대상에 남기려는 것이다.
      collect_targets "$CHILD" "$TOKFILE" "$SEENFILE" >/dev/null
      sleep 1
    done
  fi
  if (( TIMECAP_FIRED )); then
    echo "autopilot_headless: FR 경과 시간 상한(${CAP_MIN}분) 도달 — 후손 프로세스 회수 시작" >&2
    # 완료 여부는 회수를 시작하기 전에 읽는다 — 유예 중 TERM 처리기가 늦게 쓴 completed 는 「상한 전 완료」가 아니다.
    RAW_FIRST="$(head -n1 "$OUTCOME_FILE" 2>/dev/null | tr -d '[:space:]')"
    reap_timecap "$CHILD" "$TOKFILE" "$GRACE" "$UFILE" "$SEENFILE"
    ELAPSED_MIN="$(awk -v s="$((SECONDS - START_SEC))" 'BEGIN{printf "%.1f", s/60}')"
    UNREAPED_N="$(grep -c . "$UFILE" 2>/dev/null || true)"
    WAS_COMPLETED=0; [[ "$RAW_FIRST" == "completed" ]] && WAS_COMPLETED=1
    TC_FINAL="$(decide_timecap_outcome "${UNREAPED_N:-0}" "$RAW_FIRST")"
    case "$TC_FINAL" in
      completed)
        echo "autopilot_headless: 완료 후 상한 도달 — 잔여 프로세스 회수" >&2 ;;
      *)
        write_timecap_outcome "$TC_FINAL" "$ELAPSED_MIN" "$CAP_MIN" "$CAP_SRC" "$UFILE" "$WAS_COMPLETED"
        [[ "$TC_FINAL" == "time-cap-unreaped" ]] && echo "autopilot_headless: 경고 — 후손 프로세스 회수 실패 (outcome 둘째 줄 이후 참조)" >&2 ;;
    esac
  fi
  # claude 종료 코드는 exit code 로 쓰지 않는다 — outcome 토큰이 의미를 정한다. 다만 값은 보존해
  # stderr 에 적고, outcome 미기록(exit 40) 요약 줄의 원인 진단에 쓴다.
  # 상한이 발동했는데 CHILD 가 KILL 뒤에도 살아 있으면(미회수) 기다리지 않는다 — 유한 시간에 반환해야 batch 가 paused 로 멈춘다.
  if (( TIMECAP_FIRED )) && kill -0 "$CHILD" 2>/dev/null; then
    echo "autopilot_headless: 경고 — claude(pid ${CHILD}) 가 회수 뒤에도 살아 있어 종료를 기다리지 않습니다" >&2
  else
    wait "$CHILD" 2>/dev/null; CLAUDE_RC=$?
  fi
  echo "autopilot_headless: claude 종료 코드=${CLAUDE_RC:-확인 불가}" >&2
fi

# describe_claude_exit — outcome 미기록 시 claude 종료 코드의 원인 문구를 stdout 으로 낸다.
# 129~255 는 128+신호 라는 셸 관례로 신호 종료로 본다 (claude 가 그 값으로 직접 종료한 경우와는 구별되지 않는다).
describe_claude_exit() {
  local rc="${CLAUDE_RC:-}" sig name
  if [[ -z "$rc" ]]; then echo "claude 종료 코드 확인 불가"
  elif (( rc == 0 )); then echo "claude 정상 종료(0) 인데 outcome 미기록"
  elif (( rc >= 129 && rc <= 255 )); then
    sig=$((rc - 128)); name="$(kill -l "$sig" 2>/dev/null)"
    echo "claude 신호 종료(${name:-$sig}) [128+${sig}]"
  else echo "claude 비정상 종료(코드 ${rc})"
  fi
}

# 3. outcome → exit code 매핑
map_outcome() {
  local raw
  raw="$(head -n1 "$OUTCOME_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$raw" in
    completed)   echo "완료 (completed)"; return 0 ;;
    resume)      echo "세션 한계 — 재개 필요 (resume)"; return 10 ;;
    blocked:*)   echo "중단 — ${raw#blocked:} (blocked)"; return 20 ;;
    queue-empty) echo "큐 빔 (queue-empty)"; return 30 ;;
    queue-blocked) echo "의존 대기로 착수 가능 FR 없음 (queue-blocked)"; return 31 ;;
    *)           echo "outcome 판독 불가 ('${raw}') — 세션 크래시 의심 (harness-error) — $(describe_claude_exit)"; return 40 ;;
  esac
}

SUMMARY="$(map_outcome)"; CODE=$?
echo "autopilot_headless: ${SUMMARY} [exit ${CODE}]"

# 4. 상세 출력 — outcome 둘째 줄 이후를 그대로 낸다.
# 0·10·20·30·31 에 적용한다: 전역 실패(relations-unavailable·resume-undetermined)의 원인 진단과
# 재개 안내가 사용자 요약까지 닿아야 한다. 40 은 outcome 을 신뢰할 수 없어 제외한다.
# 이 출력을 map_outcome 안에 넣지 않는다 — 그 함수의 stdout 은 SUMMARY 로 캡처돼
# 한 줄 요약이 되므로, 상세를 섞으면 요약이 깨진다.
case "$CODE" in
  0|10|20|30|31) awk 'NR>1' "$OUTCOME_FILE" 2>/dev/null ;;
esac
exit "$CODE"
