#!/usr/bin/env bash
# _autopilot_publish.sh — autopilot_headless.sh 가 source 하는 발행 단계 lib. 단독 실행 대상이 아니다.
# 함수: resolve_publish_cap · pub_on_signal · pub_reap · run_publish_cmd · publish_step · timeout_reason · publish_reason · publish_fail
# (본문은 wrapper 에서 옮겨 온 그대로. 바뀐 것은 완료 정규식 PUB_DONE_RE 단일화뿐이다.)
# 읽는 wrapper 전역: OUTCOME_FILE · GRACE · PY_SETSID_EXEC · add_cleanup · resolve_grace · RD_FINISH_POLICY
#                   · RD_AUTOPILOT_ARCHIVE_CMD · LOOP_GUARD_CONFIG · RD_PUBLISH_WALL_MINUTES
# 이 lib 가 소유한 상태(PUBLISH_LINE·PUB_*)는 source 시점에 초기화한다.

# archive.sh 가 완료를 알리는 줄의 정규식 — 완료 판정·tag 추출·CLEANUP-PENDING 절단이 함께 쓴다.
# sed -E "/${PUB_DONE_RE}/,\$d" 의 구분자로 쓰이므로 이 정규식에 / 를 넣지 않습니다.
PUB_DONE_RE='^archive: (완료\. tag=|core 완료|이미 archive 완료 — nothing to do \(tag=)'

PUBLISH_LINE=
# 발행 실행 결과 (run_publish_cmd 가 정한다)
PUB_RC=0            # archive 명령의 종료 코드 (회수하지 못해 기다리지 않았으면 124)
PUB_TIMED_OUT=0     # 1 = 상한 초과 또는 신호로 발행 그룹 회수를 시작했다
PUB_CAUSE=""        # timeout | signal
PUB_SIGNAME=""      # 받은 신호 이름 (INT|TERM|HUP)
PUB_SIGEXIT=""      # 신호를 받았으면 128+신호 번호 — 마지막에 이 값으로 끝난다
PUB_UNREAPED=0      # 1 = KILL 뒤에도 발행 그룹에 프로세스가 남음
PUB_PGID=""
PUB_RESIDUAL=""
PUB_CAP_MIN=0; PUB_CAP_SRC=""; PUB_CAP_SEC=0
PUB_SIG=""

# resolve_publish_cap — PUB_CAP_MIN / PUB_CAP_SRC / PUB_CAP_SEC(0 이면 상한 없음)를 정한다.
# 우선순위: RD_PUBLISH_WALL_MINUTES > loop-guard.json 의 publish_wall_minutes > 기본 30. 유예(GRACE)는 FR 상한과 공유한다.
resolve_publish_cap() {
  local v="" src="" cfg="${LOOP_GUARD_CONFIG:-rd-workflow/config/loop-guard.json}"
  if [[ -n "${RD_PUBLISH_WALL_MINUTES:-}" ]]; then v="$RD_PUBLISH_WALL_MINUTES"; src="환경변수"
  elif [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    v="$(jq -r '.publish_wall_minutes // empty' "$cfg" 2>/dev/null || true)"; [[ -n "$v" ]] && src="loop-guard.json"
  fi
  if [[ -z "$v" ]]; then v=30; src="기본값"
  elif [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "autopilot_headless: 경고 — 발행 상한 '${v}' 는 0 이상의 숫자가 아닙니다 (30분으로 대체)" >&2
    src="기본값(잘못된 값 '${v}' 대체)"; v=30
  fi
  PUB_CAP_MIN="$v"; PUB_CAP_SRC="$src"
  if [[ "$v" =~ ^0+(\.0+)?$ ]]; then PUB_CAP_SEC=0
  else PUB_CAP_SEC="$(awk -v m="$v" 'BEGIN{v=int(m*60+0.999); if (v<1) v=1; print v}')"
  fi
  [[ -n "${GRACE:-}" ]] || resolve_grace
}

pub_on_signal() { [[ -n "$PUB_SIG" ]] || PUB_SIG="$1"; }   # 처음 받은 신호만 기록한다

# pub_reap <pgid> — 발행 그룹에 TERM → 유예(1초 간격 확인) → KILL → 5초 확인. 남았으면 PUB_UNREAPED=1 과 잔여 목록을 정한다.
# TERM 을 먼저 보내는 이유: archive.sh 의 EXIT trap 이 tasks.lock 을 풀고, git 이 index.lock 을 지울 기회를 주기 위해서다.
pub_reap() {
  local pg="$1" t0
  kill -TERM -- "-${pg}" 2>/dev/null
  t0=$SECONDS
  while (( SECONDS - t0 < GRACE )); do
    kill -0 -- "-${pg}" 2>/dev/null || break
    sleep 1
  done
  if kill -0 -- "-${pg}" 2>/dev/null; then
    kill -KILL -- "-${pg}" 2>/dev/null
    t0=$SECONDS
    while (( SECONDS - t0 < 5 )); do
      kill -0 -- "-${pg}" 2>/dev/null || break
      sleep 1
    done
  fi
  if kill -0 -- "-${pg}" 2>/dev/null; then
    PUB_UNREAPED=1
    # ps -g 는 플랫폼마다 뜻이 달라(procps 는 세션·그룹 ID) pgid 열로 거른다.
    PUB_RESIDUAL="$(ps -A -o pid=,pgid=,command= 2>/dev/null | awk -v g="$pg" '$2 == g { $2 = ""; sub(/^[[:space:]]+/, ""); print }' | cut -c1-200)"
    [[ -n "$PUB_RESIDUAL" ]] || PUB_RESIDUAL="${pg} (명령 확인 실패)"
  fi
}

# run_publish_cmd <기본 worktree> <로그> <archive 명령> <작업 이름> <추가 인자(예: " --no-remote" 또는 빈 값)> — 발행 명령을 실행해 PUB_* 를 정한다.
# 상한 없음(PUB_CAP_SEC=0)이면 종전 포그라운드 실행. 상한이 있으면 별도 프로세스 그룹(가능하면 새 세션)의 백그라운드 작업으로 띄우고
# 0.2초 간격으로 감시한다. 상한 도달이나 INT·TERM·HUP 수신 시 그룹을 회수한다 (신호 처리기는 이름만 기록하고, 회수는 루프 밖에서 한다).
run_publish_cmd() {
  local mainwt="$1" log="$2" cmd="$3" name="$4" noremote="$5" t0 sigmode=0 pg sig
  if (( PUB_CAP_SEC <= 0 )); then
    ( cd "$mainwt" && GIT_TERMINAL_PROMPT=0 $cmd --task "$name"${noremote} ) >"$log" 2>&1 </dev/null
    PUB_RC=$?
    return 0
  fi
  # 실행 검사는 claude 기동과 따로 한다 — NO_INVOKE 경로에서도 발행 단계는 돈다.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import os; os.setsid' >/dev/null 2>&1; then sigmode=1; fi
  PUB_SIG=""
  trap 'pub_on_signal INT' INT
  trap 'pub_on_signal TERM' TERM
  trap 'pub_on_signal HUP' HUP
  if (( sigmode )); then
    ( cd "$mainwt" && GIT_TERMINAL_PROMPT=0 exec python3 -c "$PY_SETSID_EXEC" $cmd --task "$name"${noremote} ) >"$log" 2>&1 </dev/null &
    pg=$!
  else
    set -m
    ( cd "$mainwt" && GIT_TERMINAL_PROMPT=0 $cmd --task "$name"${noremote} ) >"$log" 2>&1 </dev/null &
    pg=$!
    set +m
  fi
  PUB_PGID="$pg"
  t0=$SECONDS
  while kill -0 "$pg" 2>/dev/null; do
    [[ -n "$PUB_SIG" ]] && break
    if (( SECONDS - t0 >= PUB_CAP_SEC )); then PUB_TIMED_OUT=1; PUB_CAUSE=timeout; break; fi
    sleep 0.2
  done
  sig="$PUB_SIG"
  if [[ -n "$sig" ]]; then
    case "$sig" in INT) PUB_SIGEXIT=130 ;; TERM) PUB_SIGEXIT=143 ;; HUP) PUB_SIGEXIT=129 ;; esac
    PUB_SIGNAME="$sig"
    # 발행 명령이 이미 끝났으면 회수할 것이 없다 — 결과는 정상 경로로 분류하고 종료 코드만 신호를 따른다.
    if kill -0 "$pg" 2>/dev/null; then
      PUB_TIMED_OUT=1; PUB_CAUSE=signal
      echo "autopilot_headless: 신호 ${sig} 수신 — 발행 그룹 회수 시작 (유예 ${GRACE}초)" >&2
    fi
  elif (( PUB_TIMED_OUT )); then
    echo "autopilot_headless: 발행 시간 상한(${PUB_CAP_MIN}분) 도달 — archive 중단 (TERM, 유예 ${GRACE}초)" >&2
  fi
  if (( PUB_TIMED_OUT )); then pub_reap "$pg"; fi
  trap - INT TERM HUP
  # 상한 초과로 회수하는 동안 받은 신호도 종료 코드에 반영한다 — 원인은 상한 초과로 둔다.
  if [[ -z "$PUB_SIGEXIT" && -n "$PUB_SIG" ]]; then
    case "$PUB_SIG" in INT) PUB_SIGEXIT=130 ;; TERM) PUB_SIGEXIT=143 ;; HUP) PUB_SIGEXIT=129 ;; esac
    PUB_SIGNAME="$PUB_SIG"
  fi
  if (( PUB_UNREAPED )); then
    PUB_RC=124   # 기다리지 않는다 — 유한 시간에 반환해야 batch 가 paused 로 멈춘다
  else
    wait "$pg" 2>/dev/null; PUB_RC=$?
  fi
  return 0
}

publish_step() {
  local first policy name mainwt pre_head post_head logdir log stamp cmd rc tag unsafe_re
  local pf_reason="" status="" fr_ref merged=0 detail="" tmp reason_lines nextcmd noremote="" pline_policy
  local cause_long="" cause_short="" reason_text="" next_text=""
  first="$(head -n1 "$OUTCOME_FILE" 2>/dev/null | tr -d '[:space:]')"
  [[ "$first" == "publish-ready" ]] || return 0

  policy="${RD_FINISH_POLICY:-push}"
  if [[ "$policy" == "none" ]]; then
    printf 'completed\n' > "$OUTCOME_FILE" 2>/dev/null
    PUBLISH_LINE="autopilot_headless: 발행 하지 않음 (none 정책)"
    return 0
  fi
  [[ "$policy" == "merge" ]] && noremote=" --no-remote"
  if [[ "$policy" != "push" && "$policy" != "merge" ]]; then
    publish_fail blocked:publish-failed "정책 값 오류 (RD_FINISH_POLICY='${policy}')" "" \
      "RD_FINISH_POLICY 를 push|merge|none 중 하나로 고친 뒤 기본 체크아웃에서 archive.sh --task <이름> 을 실행"
    return 0
  fi
  # 줄 끝 공백·CR 만 지운다. 내부 공백을 지우면 다른 작업 이름이 되어 엉뚱한 작업을 발행한다.
  name="$(sed -n '2p' "$OUTCOME_FILE" 2>/dev/null | sed -n 's/^task //p' | sed 's/[[:space:]]*$//')"
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    publish_fail blocked:publish-failed "작업 이름 없음 (outcome 둘째 줄이 'task <이름>' 이 아님)" "" \
      "작업 worktree 의 CURRENT_TASK.md Short Title 을 확인한 뒤 기본 체크아웃에서 bash rd-workflow/scripts/lifecycle/archive.sh --task <작업 이름>[ --no-remote]"
    return 0
  fi
  mainwt="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n1)"
  if [[ -z "$mainwt" ]]; then
    publish_fail blocked:publish-failed "기본 worktree 를 찾지 못함" "" \
      "원인을 해소한 뒤 기본 체크아웃에서 bash rd-workflow/scripts/lifecycle/archive.sh --task ${name}${noremote}"
    return 0
  fi
  pre_head="$(git -C "$mainwt" rev-parse HEAD 2>/dev/null)"
  if [[ -z "$pre_head" ]]; then
    publish_fail blocked:publish-failed "기본 worktree HEAD 를 읽지 못함 (실행 전)" "" \
      "원인을 해소한 뒤 기본 체크아웃에서 bash rd-workflow/scripts/lifecycle/archive.sh --task ${name}${noremote}"
    return 0
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  logdir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/rd-workflow/autopilot-publish"
  log=""
  if [[ "$logdir" != "/rd-workflow/autopilot-publish" ]] && mkdir -p "$logdir" 2>/dev/null; then
    # 같은 초에 같은 작업을 다시 실행해도 앞 실행의 로그를 덮지 않도록 배타적으로 만든다.
    local i=0 cand="${logdir}/${name}-${stamp}.log"
    while ! ( set -C; : > "$cand" ) 2>/dev/null; do
      i=$((i + 1))
      if [[ ! -e "$cand" || $i -gt 50 ]]; then cand=""; break; fi
      cand="${logdir}/${name}-${stamp}-${i}.log"
    done
    log="$cand"
  fi
  if [[ -z "$log" ]]; then
    log="$(mktemp 2>/dev/null)" || log=""
  fi
  if [[ -z "$log" ]]; then
    publish_fail blocked:publish-failed "로그 파일 생성 실패" "" \
      "원인을 해소한 뒤 기본 체크아웃에서 bash rd-workflow/scripts/lifecycle/archive.sh --task ${name}${noremote}"
    return 0
  fi

  cmd="${RD_AUTOPILOT_ARCHIVE_CMD:-bash rd-workflow/scripts/lifecycle/archive.sh}"
  resolve_publish_cap
  if (( PUB_CAP_SEC > 0 )); then
    echo "autopilot_headless: 발행 시간 상한=${PUB_CAP_MIN}분 (${PUB_CAP_SRC})" >&2
  else
    echo "autopilot_headless: 발행 시간 상한=상한 없음 (${PUB_CAP_SRC})" >&2
  fi
  echo "autopilot_headless: 발행 시작 — task ${name} · ${policy} 정책 · 로그 ${log}" >&2
  # 무인 실행: 자격 증명 프롬프트가 뜨면 GIT_TERMINAL_PROMPT=0 으로 막고, 응답 없는 원격 등으로 멈추는 경우는 발행 시간 상한(PUB_CAP_SEC)이 끊는다
  run_publish_cmd "$mainwt" "$log" "$cmd" "$name" "$noremote"
  rc=$PUB_RC

  if (( PUB_TIMED_OUT )); then
    if [[ "$PUB_CAUSE" == signal ]]; then
      cause_long="신호 ${PUB_SIGNAME} 수신"; cause_short="$cause_long"
    else
      cause_long="발행 시간 상한(${PUB_CAP_MIN}분, ${PUB_CAP_SRC}) 초과"; cause_short="발행 시간 상한(${PUB_CAP_MIN}분) 초과"
      if [[ -n "$PUB_SIGNAME" ]]; then cause_long+=" · 회수 중 신호 ${PUB_SIGNAME} 수신"; cause_short+=" · 회수 중 신호 ${PUB_SIGNAME} 수신"; fi
    fi
  fi

  if (( PUB_UNREAPED )); then
    status="unsafe-running"   # 회수하지 못한 프로세스가 있으면 어떤 판정보다 우선한다 (발행이 아직 진행 중일 수 있다)
  elif grep -Eq "$PUB_DONE_RE" "$log" 2>/dev/null; then
    if grep -q '안전 불변식 위반' "$log" 2>/dev/null; then
      status="unsafe"
    elif (( PUB_TIMED_OUT )); then
      :   # 완료 문구 뒤 정리 단계가 끝났는지 알 수 없다 — done 으로 보지 않고 아래 HEAD 판정으로 넘긴다
    elif (( rc == 0 )); then
      status="done"
    elif grep -q '^archive: CLEANUP-RECORD-FAILED' "$log" 2>/dev/null; then
      status="done-recfail"
    fi
  fi
  if [[ -z "$status" ]]; then
    # 기본 브랜치에 병합이 남았는지 — 확인하지 못하면 incomplete (「변화 없음」 으로 다루지 않는다)
    status="failed"
    post_head="$(git -C "$mainwt" rev-parse HEAD 2>/dev/null)"
    if [[ -z "$post_head" ]]; then
      status="incomplete"
    elif [[ "$post_head" != "$pre_head" ]]; then
      status="incomplete"
    else
      local mc
      if mc="$(git -C "$mainwt" log --grep="^merge: ${name} " -n1 --format=%H HEAD 2>/dev/null)"; then
        if [[ -n "$mc" ]]; then
          if git -C "$mainwt" rev-parse --verify -q "refs/heads/fr/${name}" >/dev/null 2>&1; then
            git -C "$mainwt" merge-base --is-ancestor "fr/${name}" HEAD >/dev/null 2>&1 && status="incomplete"
          else
            status="incomplete"
          fi
        fi
      else
        status="incomplete"
      fi
    fi
  fi

  case "$status" in
    done|done-recfail)
      tag="$(grep -E "$PUB_DONE_RE" "$log" | head -n1 | sed -n 's/.*tag=\([^) ]*\).*/\1/p')"
      if [[ "$policy" == "merge" ]]; then pline_policy="merge 정책, push 하지 않음"; else pline_policy="push 정책"; fi
      tmp="$(mktemp 2>/dev/null)" || tmp=""
      [[ -n "$tmp" ]] && add_cleanup "$tmp"
      local ofail=0
      {
        echo "completed"
        [[ "$status" == "done-recfail" ]] && echo "cleanup-record-failed ${name} ${log}"
        sed -n '/^archive: CLEANUP-PENDING/,$p' "$log" 2>/dev/null | grep -Eqm1 "$PUB_DONE_RE" \
          && sed -n '/^archive: CLEANUP-PENDING/,$p' "$log" 2>/dev/null | sed -E "/${PUB_DONE_RE}/,\$d"
        true
      } > "${tmp:-$OUTCOME_FILE}" 2>/dev/null || ofail=1
      if [[ -n "$tmp" ]]; then cat "$tmp" > "$OUTCOME_FILE" 2>/dev/null || ofail=1; rm -f "$tmp"; fi
      if (( ofail )); then echo "autopilot_headless: 경고 — 발행은 끝났으나 outcome 파일을 다시 쓰지 못했습니다 (로그: ${log})" >&2; fi
      if [[ "$status" == "done-recfail" ]]; then
        PUBLISH_LINE="autopilot_headless: 발행 완료 — 정리 잔여 기록 실패 (로그: ${log})"
      else
        PUBLISH_LINE="autopilot_headless: 발행 완료 — tag=${tag} (${pline_policy})"
      fi
      ;;
    unsafe)
      reason_text="$(publish_reason "$log" "$rc")"
      (( PUB_TIMED_OUT )) && reason_text="$(timeout_reason "$cause_long")"$'\n'"${reason_text}"
      publish_fail blocked:publish-unsafe "$reason_text" "$log" \
        "발행(merge·tag·push)은 끝났습니다. 로그의 안전 불변식 위반 줄과 남은 ref 를 확인해 수동으로 정리하십시오 — archive.sh 를 다시 실행하지 않습니다"
      PUBLISH_LINE="autopilot_headless: 발행 완료됐으나 안전 검사 실패 — ref 정리를 멈췄습니다 (로그: ${log})"
      ;;
    unsafe-running)
      reason_text="$(timeout_reason "$cause_long")"$'\n'"$(printf '%s\n' "$PUB_RESIDUAL" | sed 's/^/잔여 프로세스: /')"$'\n'"$(publish_reason "$log" "$rc")"
      publish_fail blocked:publish-unsafe "$reason_text" "$log" \
        "발행 프로세스가 KILL 뒤에도 남아 있어 발행이 아직 진행 중일 수 있습니다. 프로세스가 끝난 것을 확인한 뒤 로그와 기본 브랜치·tag 상태를 확인하십시오 — 그 전에는 archive.sh 를 다시 실행하지 않습니다"
      PUBLISH_LINE="autopilot_headless: ${cause_short} — 중단을 시도했으나 발행 프로세스가 남아 있습니다. archive.sh 를 다시 실행하지 마십시오 (로그: ${log})"
      ;;
    incomplete)
      reason_text="$(publish_reason "$log" "$rc")"
      (( PUB_TIMED_OUT )) && reason_text="$(timeout_reason "$cause_long")"$'\n'"${reason_text}"
      next_text="사유 줄의 원인을 해소한 뒤 기본 체크아웃에서 이어붙이기 bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/${name}${noremote}"
      (( PUB_TIMED_OUT )) && next_text="원격 응답을 확인한 뒤 기본 체크아웃에서 이어붙이기 bash rd-workflow/scripts/lifecycle/archive.sh --fr-branch fr/${name}${noremote} (archive 락이 남았다는 안내가 나오면 그 안내대로 먼저 회수)"
      publish_fail blocked:publish-incomplete "$reason_text" "$log" "$next_text"
      if (( PUB_TIMED_OUT )); then
        PUBLISH_LINE="autopilot_headless: ${cause_short} — 병합됐으나 tag·push·정리가 끝나지 않았습니다 (로그: ${log})"
      else
        PUBLISH_LINE="autopilot_headless: 발행 중간 상태 — 병합됐으나 tag·push·정리가 끝나지 않았습니다 (로그: ${log})"
      fi
      ;;
    *)
      reason_text="$(publish_reason "$log" "$rc")"
      (( PUB_TIMED_OUT )) && reason_text="$(timeout_reason "$cause_long")"$'\n'"${reason_text}"
      next_text="거부 사유를 해소한 뒤 기본 체크아웃에서 bash rd-workflow/scripts/lifecycle/archive.sh --task ${name}${noremote}"
      (( PUB_TIMED_OUT )) && next_text="원격 응답을 확인하고, 기본 체크아웃(${mainwt})의 git status 로 merge 진행 흔적(MERGE_HEAD)·남은 변경을 확인하십시오(있으면 git merge --abort). archive 락이 남았다는 안내가 나오면 그 안내대로 회수한 뒤 기본 체크아웃에서 bash rd-workflow/scripts/lifecycle/archive.sh --task ${name}${noremote}"
      publish_fail blocked:publish-failed "$reason_text" "$log" "$next_text"
      # publish_fail 이 정한 기본 발행 줄을 상한 초과 문구로 덮는다 (호출 뒤에 정한다)
      if (( PUB_TIMED_OUT )); then
        PUBLISH_LINE="autopilot_headless: ${cause_short} — 기본 브랜치는 그대로입니다. 작업 worktree 를 보존했습니다 (로그: ${log})"
      else
        PUBLISH_LINE="autopilot_headless: 발행 실패 — 기본 브랜치는 그대로입니다. 작업 worktree 를 보존했습니다 (로그: ${log})"
      fi
      ;;
  esac
  return 0
}

# timeout_reason <원인> — 상한 초과·신호 뒤 사유 첫 줄. 회수했으면 「중단했습니다」, 못 했으면 「프로세스가 남아 있습니다」.
timeout_reason() {
  if (( PUB_UNREAPED )); then
    printf '사유: %s — archive 중단을 시도했으나 프로세스가 남아 있습니다 (그룹 %s)' "$1" "$PUB_PGID"
  else
    printf '사유: %s — archive 를 중단했습니다' "$1"
  fi
}

# publish_reason <로그> <rc> — 로그의 비어 있지 않은 마지막 5줄에 `사유: ` 접두를 붙여 낸다.
publish_reason() {
  local lines
  lines="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 5 | sed 's/^/사유: /')"
  if [[ -n "$lines" ]]; then printf '%s\n' "$lines"; else echo "사유: archive 출력 없음 (exit $2)"; fi
}

# publish_fail <blocked 토큰> <사유 줄(들)> <로그 경로> <다음 안내> — 실패 outcome 을 다시 쓴다.
# 사유가 `사유: ` 로 시작하지 않으면 접두를 붙인다.
publish_fail() {
  local token="$1" reason="$2" lg="$3" nx="$4"
  case "$reason" in "사유: "*) ;; *) reason="사유: ${reason}" ;; esac
  {
    echo "$token"
    printf '%s\n' "$reason"
    [[ -n "$lg" ]] && echo "로그: ${lg}"
    [[ -n "$nx" ]] && echo "다음: ${nx}"
  } > "$OUTCOME_FILE" 2>/dev/null || echo "autopilot_headless: 경고 — 발행 outcome 기록 실패: $OUTCOME_FILE" >&2
  case "$token" in
    blocked:publish-failed) PUBLISH_LINE="autopilot_headless: 발행 실패 — 기본 브랜치는 그대로입니다. 작업 worktree 를 보존했습니다${lg:+ (로그: ${lg})}" ;;
  esac
}
