#!/usr/bin/env bash
# publish_queue.sh — 발행 요청 큐 (rd publish).
#   promote 가 띄운 작업 세션이 파일 큐로 발행 허가를 받아 한 번에 하나씩 발행한다.
#   큐 위치: <git-common-dir>/rd-workflow/publish-queue/ (추적하지 않음)
#     <slug>.req  요청 파일(key=value 줄)   ACTIVE  허가 슬롯(slug 한 줄)   .lock/  큐 락(mkdir)
#   이 스크립트는 herdr agent prompt · herdr pane send-text · hc send 를 부르지 않는다.
#   Spec: rd-workflow-workspace/specs/changes/2026-11-04-0917-publish-queue-tab-close-change-spec.md
#
# 종료 코드: 0 성공, 1 거부, 2 사용 오류, 3 판정 불가, 4 대기 시간 초과,
#           10 사용자 승인 대상, 11 호출 세션 소실
#
# 환경 변수: RD_PQ_POLL(폴링 간격 초, 기본 2), RD_PQ_LOCK_TRIES(락 재시도 횟수, 기본 50),
#           RD_PQ_CALLER_CHECK(wait 의 호출 세션 생존 확인 간격 초, 기본 60)
#
# bash 3.2 호환: 연관 배열·${var,,}·BASHPID 를 쓰지 않는다.

_PQ_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="${project_root:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export project_root
source "$_PQ_SELF_DIR/_lifecycle_common.sh"
source "$_PQ_SELF_DIR/_tasks_index.sh"
source "$_PQ_SELF_DIR/session_launch.sh"
source "$_PQ_SELF_DIR/_merge_precheck.sh"

# 큐 상태 값 (허용 목록). 이 밖의 값은 손상으로 본다.
PQ_STATES="requested user-approval granted running partial done failed cancelled"

# ---------------------------------------------------------------- 설정 (D1)

# 승인 주체 판정. stdout: caller | user. 허용 밖 값·파싱 실패는 user + stderr 경고.
pq_approval_mode() {
  local cfg="${project_root:-$PWD}/rd-workflow/config/workflow.json" out
  if [[ ! -f "$cfg" ]]; then printf 'caller\n'; return 0; fi
  out="$(python3 -I - "$cfg" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("ERR"); sys.exit(0)
if not isinstance(d, dict):
    print("ERR"); sys.exit(0)
if "publish_approval" not in d:
    print("caller"); sys.exit(0)
v = d["publish_approval"]
print(v if v in ("caller", "user") else "ERR")
PY
)" || out="ERR"
  case "$out" in
    caller|user) printf '%s\n' "$out" ;;
    *)
      printf '경고: workflow.json 의 publish_approval 을 읽을 수 없거나 허용 값(caller|user)이 아닙니다 — user 로 처리합니다\n' >&2
      printf 'user\n'
      ;;
  esac
}

# ---------------------------------------------------------------- 저장소 · 락 (D3)

# 큐 디렉터리 절대 경로 (없으면 만든다).
pq_dir() {
  local d
  d="$(tasks_shared_dir)" || return 1
  d="$d/publish-queue"
  mkdir -p "$d" || return 1
  printf '%s\n' "$d"
}

_pq_pid_alive() {
  local p="$1"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null
}

# 경로의 mtime 이 <초> 보다 오래됐는지. GNU stat(-c) → BSD stat(-f) 순으로 시도한다.
_pq_older_than() {  # <path> <sec>
  local m now
  m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  (( now - m > $2 ))
}

# 낡은 락 회수. 호출부가 읽은 pid(<expected>, 빈 값이면 pid 파일 없음)를 회수 가드 안에서 다시 읽어
# 여전히 같은 죽은 pid(또는 10초 넘게 pid 가 없는 락)일 때만 지운다. rc 0 회수 / 1 회수하지 않음.
# 회수 가드 `.lock.reclaim` 이 회수를 직렬화하므로, 그 사이 다른 프로세스가 새로 잡은 락을 빼앗지 않는다.
# 가드가 남은 경우(보유자 사망)는 가드 안 pid 가 죽었거나 pid 없이 10초가 지났을 때 치우고 다음 시도에 맡긴다.
_pq_lock_reclaim() {  # <queue-dir> <expected-pid>
  local d="$1" expect="$2" lock guard cur gpid
  lock="$d/.lock"; guard="$d/.lock.reclaim"
  if ! mkdir "$guard" 2>/dev/null; then
    gpid=""
    [[ -f "$guard/pid" ]] && gpid="$(cat "$guard/pid" 2>/dev/null)"
    if [[ -n "$gpid" ]]; then
      _pq_pid_alive "$gpid" || rm -rf "$guard"
    elif _pq_older_than "$guard" 10; then
      rm -rf "$guard"
    fi
    return 1
  fi
  printf '%s\n' "$$" >"$guard/pid"
  cur=""
  [[ -f "$lock/pid" ]] && cur="$(cat "$lock/pid" 2>/dev/null)"
  if [[ -d "$lock" && "$cur" == "$expect" ]]; then
    if [[ -n "$cur" ]]; then
      if ! _pq_pid_alive "$cur"; then rm -rf "$lock"; rm -rf "$guard"; return 0; fi
    elif _pq_older_than "$lock" 10; then
      rm -rf "$lock"; rm -rf "$guard"; return 0
    fi
  fi
  rm -rf "$guard"
  return 1
}

# 큐 락 획득. rc 0 획득, 1 실패. 점유 pid 가 죽었으면 회수한다(_pq_lock_reclaim).
pq_lock() {
  local d lock tries="${RD_PQ_LOCK_TRIES:-50}" n=0 pid
  case "$tries" in ''|*[!0-9]*) tries=50 ;; esac
  d="$(pq_dir)" || return 1
  lock="$d/.lock"
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock/pid"
      return 0
    fi
    pid=""
    [[ -f "$lock/pid" ]] && pid="$(cat "$lock/pid" 2>/dev/null)"
    if [[ -z "$pid" ]] || ! _pq_pid_alive "$pid"; then
      _pq_lock_reclaim "$d" "$pid" && continue
    fi
    n=$((n+1))
    (( n >= tries )) && return 1
    sleep 0.2
  done
}

# 큐 락 해제. 내 pid 의 락만 지운다.
pq_unlock() {
  local d lock
  d="$(pq_dir)" || return 1
  lock="$d/.lock"
  if [[ -f "$lock/pid" && "$(cat "$lock/pid" 2>/dev/null)" == "$$" ]]; then
    rm -rf "$lock"
    return 0
  fi
  return 1
}

_pq_slug_ok() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

_pq_req_path() { printf '%s/%s.req\n' "$(pq_dir)" "$1"; }

# 요청 파일의 키 값. 파일 없음 rc 1.
pq_get() {
  local f
  f="$(_pq_req_path "$1")" || return 1
  [[ -f "$f" ]] || return 1
  awk -v k="$2" 'index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }' "$f"
}

# 요청 파일에 k=v 를 키 단위로 병합한다 (mktemp + mv). updated-at 은 자동 갱신.
pq_set() {
  local slug="$1" f tmp pair k v now
  shift
  f="$(_pq_req_path "$slug")" || return 1
  tmp="$(mktemp "$(pq_dir)/.req.XXXXXX")" || return 1
  now="$(date +%s)"
  {
    [[ -f "$f" ]] && cat "$f"
    :
  } >"$tmp"
  for pair in "slug=$slug" "$@" "updated-at=$now"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    v="${v//$'\n'/ }"
    awk -v k="$k" 'index($0, k "=") != 1' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    printf '%s=%s\n' "$k" "$v" >>"$tmp"
  done
  mv "$tmp" "$f"
}

# ---------------------------------------------------------------- 슬롯 (D3)

pq_slot_get() {
  local f
  f="$(pq_dir)/ACTIVE" || return 0
  [[ -f "$f" ]] && head -1 "$f" 2>/dev/null
  return 0
}
pq_slot_set() { printf '%s\n' "$1" >"$(pq_dir)/ACTIVE"; }
pq_slot_clear() { rm -f "$(pq_dir)/ACTIVE"; }

# ---------------------------------------------------------------- 표시

pq_label() {
  case "$1" in
    requested) printf '요청됨\n' ;;
    user-approval) printf '사용자 승인 대상\n' ;;
    granted) printf '허가됨\n' ;;
    running) printf '발행 중\n' ;;
    partial) printf '부분 완료\n' ;;
    done) printf '성공\n' ;;
    failed) printf '실패\n' ;;
    cancelled) printf '취소\n' ;;
    *) printf '판정 불가\n' ;;
  esac
}

_pq_state_valid() {
  local s
  for s in $PQ_STATES; do [[ "$1" == "$s" ]] && return 0; done
  return 1
}

_pq_next_action() {
  local slug="$1"
  case "$2" in
    requested) printf '호출 세션이 rd publish next 로 허가' ;;
    user-approval) printf '사용자 승인 뒤 rd publish approve %s' "$slug" ;;
    granted) printf 'rd publish run' ;;
    running) printf '프로세스가 없으면 rd publish recover %s' "$slug" ;;
    partial) printf 'rd publish run 으로 복구' ;;
    done) printf '없음' ;;
    failed) printf '원인 해소 뒤 rd publish request' ;;
    cancelled) printf '필요하면 rd publish request' ;;
  esac
}

# 현재 worktree 의 task-state short-title. 없으면 빈 값 rc 1.
_pq_current_slug() {
  local s
  s="$(state_read_field short-title 2>/dev/null)"
  [[ -n "$s" && "$s" != "-" ]] || return 1
  printf '%s\n' "$s"
}

# 요청 한 건의 상태 판정. stdout 상태. 파일 없음 rc 1, 손상 rc 3(사유는 stderr).
_pq_state_of() {
  local f st
  f="$(_pq_req_path "$1")" || return 1
  [[ -f "$f" ]] || return 1
  st="$(pq_get "$1" state)"
  if [[ -z "$st" ]]; then
    printf '요청 파일 %s 의 state 가 비었습니다 — 판정 불가. 파일을 직접 고치거나 삭제하십시오\n' "$f" >&2
    return 3
  fi
  if ! _pq_state_valid "$st"; then
    printf '요청 파일 %s 의 state 가 허용 값이 아닙니다 (%s) — 판정 불가. 파일을 직접 고치거나 삭제하십시오\n' "$f" "$st" >&2
    return 3
  fi
  printf '%s\n' "$st"
}

# ACTIVE 슬롯 점검. 슬롯이 없으면 rc 0 + 빈 stdout, 정상이면 rc 0 + slug,
# 손상(빈 값·요청 파일 없음·요청이 granted|running|partial 이 아님)이면 rc 3 + stderr 사유.
_pq_slot_check() {
  local f slot st rc=0
  f="$(pq_dir)/ACTIVE"
  [[ -f "$f" ]] || return 0
  slot="$(pq_slot_get)"
  if [[ -z "$slot" ]]; then
    printf '허가 슬롯(ACTIVE)이 비어 있습니다 — 판정 불가. %s 를 삭제하면 슬롯이 풀립니다 (사용자 확인 필요)\n' "$f" >&2
    return 3
  fi
  st="$(_pq_state_of "$slot" 2>/dev/null)" || rc=$?
  case "$st" in
    granted|running|partial) printf '%s\n' "$slot"; return 0 ;;
  esac
  printf '허가 슬롯(ACTIVE)이 가리키는 요청 %s 가 슬롯을 쥘 수 없는 상태입니다 (%s) — 판정 불가. %s 를 삭제하면 슬롯이 풀립니다 (사용자 확인 필요)\n' "$slot" "${st:-요청 파일 없음·손상}" "$f" >&2
  return 3
}

# 7일 지난 done 요청 파일 정리.
_pq_prune_done() {
  local d f
  d="$(pq_dir)" || return 0
  find "$d" -maxdepth 1 -name '*.req' -mtime +7 -print0 2>/dev/null | while IFS= read -r -d '' f; do
    grep -q '^state=done$' "$f" 2>/dev/null && rm -f "$f"
  done
  return 0
}

# ---------------------------------------------------------------- status (D4)

_pq_status_line() {
  local slug="$1" st rc=0 reason bp
  st="$(_pq_state_of "$slug")" || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    printf '%s  판정 불가  요청 파일 손상(%s)  → 파일을 직접 고치거나 삭제하십시오 (rd publish cancel 로 정리할 수 없음)\n' "$slug" "$(_pq_req_path "$slug")"
    return 3
  elif [[ "$rc" -ne 0 ]]; then
    printf '%s  요청 없음\n' "$slug"
    return 1
  fi
  reason="$(pq_get "$slug" reason)"
  local action wait=""
  action="$(_pq_next_action "$slug" "$st")"
  if [[ "$st" == requested ]] && wait="$(_pq_wait_reason "$slug")" && [[ -n "$wait" ]]; then
    reason="${reason:+$reason · }${wait%%$'\t'*}"
    action="${wait#*$'\t'}"
  fi
  bp="$(_pq_bypass_text "$slug")"
  printf '%s  %s  %s%s  → %s\n' "$slug" "$(pq_label "$st")" "${reason:--}" "${bp:+  $bp}" "$action"
}

# 요청됨 상태가 지금 허가될 수 없는 이유 (next 의 거부 조건과 같은 순서). stdout `사유<TAB>다음 행동`.
#   허가될 수 있으면 아무것도 내지 않는다. 기본 체크아웃 확인은 한 번만 하고 결과를 재사용한다.
_PQ_MAIN_BLOCK=""
_pq_wait_reason() {  # <slug>
  local slug="$1" slot sst main common
  slot="$(pq_slot_get)"
  if [[ -n "$slot" && "$slot" != "$slug" ]]; then
    sst="$(_pq_state_of "$slot" 2>/dev/null)" || sst=""
    printf '앞 요청 %s 가 %s\t앞 발행이 끝나면 호출 세션이 rd publish next 로 허가\n' "$slot" "$(pq_label "${sst:-?}")"
    return 0
  fi
  if [[ -z "$_PQ_MAIN_BLOCK" ]]; then
    _PQ_MAIN_BLOCK="-"
    if main="$(_pq_main_checkout)" && common="$(_pq_common_dir)"; then
      if [[ -f "$common/MERGE_HEAD" ]]; then
        _PQ_MAIN_BLOCK=$'기본 체크아웃에 병합이 진행 중\t병합을 마친 뒤 호출 세션이 rd publish next 로 허가'
      elif [[ -n "$(git -C "$main" status --porcelain 2>/dev/null)" ]]; then
        _PQ_MAIN_BLOCK=$'기본 체크아웃에 미커밋 변경\t기본 체크아웃을 커밋·정리한 뒤 호출 세션이 rd publish next 로 허가'
      fi
    fi
  fi
  [[ "$_PQ_MAIN_BLOCK" == "-" ]] || printf '%s\n' "$_PQ_MAIN_BLOCK"
  return 0
}

pq_cmd_status() {
  local slug="${1:-}" d f rc=0 r
  d="$(pq_dir)" || return 1
  _pq_prune_done
  if [[ -n "$slug" ]]; then
    _pq_slug_ok "$slug" || { printf '올바르지 않은 slug: %s\n' "$slug" >&2; return 2; }
    _pq_status_line "$slug" || rc=$?
    return "$rc"
  fi
  local lines="" s
  for f in "$d"/*.req; do
    [[ -f "$f" ]] || continue
    s="$(basename "$f" .req)"
    r="$(awk 'index($0,"seq=")==1{sub(/^[^=]*=/,""); print; exit}' "$f")"
    lines="${lines}${r:-0} ${s}"$'\n'
  done
  if [[ -n "$lines" ]]; then
    while read -r _ s; do
      [[ -n "$s" ]] || continue
      r=0
      _pq_status_line "$s" || r=$?
      [[ "$r" -eq 3 ]] && rc=3
    done < <(printf '%s' "$lines" | sort -n -k1,1)
  else
    printf '발행 큐 비어 있음\n'
  fi
  _pq_slot_check >/dev/null || rc=3
  return "$rc"
}

# ---------------------------------------------------------------- cancel (D10)

pq_cmd_cancel() {
  local slug="${1:-}" st rc=0
  if [[ -z "$slug" ]]; then
    slug="$(_pq_current_slug)" || { printf 'slug 를 정할 수 없습니다 — rd publish cancel <slug>\n' >&2; return 2; }
  fi
  _pq_slug_ok "$slug" || { printf '올바르지 않은 slug: %s\n' "$slug" >&2; return 2; }
  pq_lock || { printf '큐 락 획득 실패 — 잠시 뒤 다시 시도하십시오\n' >&2; return 1; }
  st="$(_pq_state_of "$slug")" || rc=$?
  if [[ "$rc" -eq 3 ]]; then pq_unlock; return 3; fi
  if [[ "$rc" -ne 0 ]]; then pq_unlock; printf '취소할 요청 없음: %s\n' "$slug"; return 1; fi
  case "$st" in
    requested|user-approval)
      pq_set "$slug" state=cancelled "reason=사용자 취소"
      ;;
    granted)
      pq_set "$slug" state=cancelled "reason=사용자 취소"
      [[ "$(pq_slot_get)" == "$slug" ]] && pq_slot_clear
      ;;
    running|partial)
      pq_unlock
      printf '%s 는 %s 상태입니다 — 발행 중이거나 부분 완료 — rd publish recover 로 판정하십시오\n' "$slug" "$(pq_label "$st")"
      return 1
      ;;
    *)
      pq_unlock
      printf '취소할 요청 없음: %s (%s)\n' "$slug" "$(pq_label "$st")"
      return 1
      ;;
  esac
  pq_unlock
  printf '취소했습니다: %s\n' "$slug"
  return 0
}

# ---------------------------------------------------------------- 사전 확인 (D6·D12)

# 기본 체크아웃 = 공유 git 디렉터리의 부모.
_pq_common_dir() { git -C "${project_root:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }
_pq_main_checkout() { local c; c="$(_pq_common_dir)" || return 1; [[ -n "$c" ]] || return 1; dirname "$c"; }

_pq_default_branch() { (cd "${project_root:-$PWD}" && get_default_branch 2>/dev/null); }

# 병합 충돌 사전 확인 (D12). 판정은 공용 rd_merge_conflicts(_merge_precheck.sh)가 한다.
#   자동 해소 경로를 뺀 충돌 파일이 남으면 stdout 에 한 줄씩 내고 rc 1. rc 0 통과 / 1 충돌 / 3 판정 불가
pq_merge_check() {  # <default-branch> <head>
  rd_merge_conflicts "${project_root:-$PWD}" "${1:-}" "${2:-}"
}

# archive 우회 옵션 파싱 (rd publish request). 결과는 전역 PQ_BP_GITLINK·PQ_BP_REVIEW·PQ_BP_BASIS.
#   오류면 stderr 한 줄과 rc 2. 우회 옵션이 있으면 --basis 필수, 없으면 --basis 거부.
PQ_BP_GITLINK=""; PQ_BP_REVIEW=""; PQ_BP_BASIS=""
_pq_bp_value() {  # <옵션> <값...> — 사유·근거 값 규칙 검사. 통과하면 값을 stdout 으로 낸다.
  local opt="$1" v="${2-}"   # 값 토큰이 없으면 빈 값으로 보고 아래 빈 값 검사가 거부한다
  case "$v" in -*) printf '%s 의 값이 -로 시작합니다: %s\n' "$opt" "$v" >&2; return 2 ;; esac
  if [[ -z "$v" || "$v" =~ ^[[:space:]]+$ ]]; then printf '%s 의 값이 없거나 공백뿐입니다\n' "$opt" >&2; return 2; fi
  case "$v" in *$'\n'*|*$'\r'*) printf '%s 의 값에 줄바꿈이 있습니다\n' "$opt" >&2; return 2 ;; esac
  printf '%s' "$v"
}
_pq_parse_bypass() {
  local g=0 r=0 b=0 v
  PQ_BP_GITLINK=""; PQ_BP_REVIEW=""; PQ_BP_BASIS=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-gitlink-drop)
        if [[ "$g" -eq 1 ]]; then printf '%s 를 두 번 줄 수 없습니다\n' "$1" >&2; return 2; fi
        v="$(_pq_bp_value "$@")" || return 2
        PQ_BP_GITLINK="$v"; g=1 ;;
      --force-skip-review-check)
        if [[ "$r" -eq 1 ]]; then printf '%s 를 두 번 줄 수 없습니다\n' "$1" >&2; return 2; fi
        v="$(_pq_bp_value "$@")" || return 2
        PQ_BP_REVIEW="$v"; r=1 ;;
      --basis)
        if [[ "$b" -eq 1 ]]; then printf '%s 를 두 번 줄 수 없습니다\n' "$1" >&2; return 2; fi
        v="$(_pq_bp_value "$@")" || return 2
        PQ_BP_BASIS="$v"; b=1 ;;
      --allow-status-mismatch)
        printf '큐는 Status 아카이브 보류에서만 발행하므로 이 우회를 받지 않습니다 — 사용자 승인 뒤 archive.sh --allow-status-mismatch "<사유>" 를 직접 실행하십시오\n' >&2
        return 2 ;;
      *)
        printf '알 수 없는 인자: %s — 사용법: rd publish request [--allow-gitlink-drop <사유>] [--force-skip-review-check <사유>] --basis <근거>\n' "$1" >&2
        return 2 ;;
    esac
    shift
    [[ $# -gt 0 ]] && shift
  done
  if [[ $((g + r)) -gt 0 && "$b" -eq 0 ]]; then
    printf '우회 옵션에는 --basis "<날짜> <결정한 사람> — <한 말>" 이 필요합니다\n' >&2; return 2
  fi
  if [[ $((g + r)) -eq 0 && "$b" -eq 1 ]]; then
    printf -- '--basis 는 우회 옵션(--allow-gitlink-drop·--force-skip-review-check)과 함께만 줄 수 있습니다\n' >&2; return 2
  fi
  return 0
}

# 요청 파일의 우회 기록을 한 줄 조각으로 낸다. 우회가 없으면 빈 출력.
_pq_bypass_text() {  # <slug>
  local slug="$1" gl rv ba out=""
  gl="$(pq_get "$slug" bypass-gitlink 2>/dev/null)"; rv="$(pq_get "$slug" bypass-review 2>/dev/null)"
  ba="$(pq_get "$slug" bypass-basis 2>/dev/null)"
  [[ -n "$gl" ]] && out="--allow-gitlink-drop (사유: $gl)"
  [[ -n "$rv" ]] && out="${out:+$out, }--force-skip-review-check (사유: $rv)"
  [[ -n "$out" ]] || return 0
  printf '우회: %s · 근거: %s\n' "$out" "$ba"
}

# 인자를 작은따옴표로 감싼다(내부의 ' 는 '\'' 로). UTF-8 을 그대로 두고 복사해 실행해도 원문으로 복원된다.
_pq_shq() {
  local q="'\\''"
  printf "'%s'" "${1//\'/$q}"
}

# archive.sh 에 넘길 인자 배열 PQ_BP_ARGS. 사유는 "<사유> (근거: <근거>)" 로 합친다.
_pq_bypass_args() {  # <slug>
  local slug="$1" gl rv ba
  PQ_BP_ARGS=()
  gl="$(pq_get "$slug" bypass-gitlink 2>/dev/null)"; rv="$(pq_get "$slug" bypass-review 2>/dev/null)"
  ba="$(pq_get "$slug" bypass-basis 2>/dev/null)"
  [[ -n "$gl" ]] && PQ_BP_ARGS+=(--allow-gitlink-drop "$gl (근거: $ba)")
  [[ -n "$rv" ]] && PQ_BP_ARGS+=(--force-skip-review-check "$rv (근거: $ba)")
  return 0
}

# 요청 파일을 새로 쓴다. 같은 slug 의 이전 실행 흔적(run-*·result-*)은 비운다. 큐 락 안에서 부른다.
_pq_write_request() {  # <slug> <state> <reason> <backend> <caller-id> <fr-branch> <head>
  local slug="$1" state="$2" reason="$3" now maxseq=0 f s seq
  now="$(date +%s)"
  for f in "$(pq_dir)"/*.req; do
    [[ -f "$f" ]] || continue
    s="$(awk 'index($0,"seq=")==1{sub(/^[^=]*=/,""); print; exit}' "$f")"
    case "$s" in ''|*[!0-9]*) continue ;; esac
    (( s > maxseq )) && maxseq="$s"
  done
  seq=$(( now * 1000 ))
  (( seq <= maxseq )) && seq=$(( maxseq + 1 ))
  pq_set "$slug" "state=$state" "notified=" "seq=$seq" "requested-at=$now" \
    "worktree=${project_root:-$PWD}" "fr-branch=$6" "head=$7" \
    "caller-backend=$4" "caller-id=$5" "reason=$reason" \
    "bypass-gitlink=$PQ_BP_GITLINK" "bypass-review=$PQ_BP_REVIEW" "bypass-basis=$PQ_BP_BASIS" \
    "run-pid=" "run-token=" "archive-pgid=" "result-main=" "result-tag="
}

# ---------------------------------------------------------------- request (D5)

pq_cmd_request() {
  local slug mode backend cid launch st dirty def head frb conflicts rc lost=0 cur p bp
  _pq_parse_bypass "$@" || return 2
  slug="$(_pq_current_slug)" || { printf 'slug 를 정할 수 없습니다 — 작업 worktree 에서 실행하십시오\n' >&2; return 2; }
  _pq_slug_ok "$slug" || { printf '올바르지 않은 slug: %s\n' "$slug" >&2; return 2; }
  mode="$(pq_approval_mode)"
  cid="$(tasks_index_get "$slug" caller-id 2>/dev/null || true)"
  launch="$(tasks_index_get "$slug" launch 2>/dev/null || true)"
  if [[ "$mode" == user || -z "$cid" || "$launch" != ok ]]; then
    printf '사용자 승인 대상 — 발행 전에 사용자에게 승인을 받은 뒤 archive.sh 를 실행하십시오\n'
    if [[ -n "$PQ_BP_GITLINK$PQ_BP_REVIEW" ]]; then
      local a=""
      [[ -n "$PQ_BP_GITLINK" ]] && a="$a --allow-gitlink-drop $(_pq_shq "$PQ_BP_GITLINK (근거: $PQ_BP_BASIS)")"
      [[ -n "$PQ_BP_REVIEW" ]] && a="$a --force-skip-review-check $(_pq_shq "$PQ_BP_REVIEW (근거: $PQ_BP_BASIS)")"
      printf '승인 뒤 실행할 명령: bash rd-workflow/scripts/lifecycle/archive.sh%s\n' "$a"
    fi
    return 10
  fi
  backend="$(tasks_index_get "$slug" caller-backend 2>/dev/null || true)"

  st="$(cd "${project_root:-$PWD}" && bash rd-workflow/scripts/rd task status 2>/dev/null | head -1)"
  if [[ -z "$st" ]]; then printf 'Status 를 읽을 수 없습니다 — 판정 불가\n' >&2; return 3; fi
  if [[ "$st" != "아카이브 보류" ]]; then
    printf '요청할 수 없습니다 — Status 가 %s 입니다 (아카이브 보류 필요)\n' "$st"
    return 1
  fi
  dirty="$(git -C "${project_root:-$PWD}" status --porcelain 2>/dev/null)" || { printf '작업 worktree 상태를 읽을 수 없습니다 — 판정 불가\n' >&2; return 3; }
  if [[ -n "$dirty" ]]; then
    printf '요청할 수 없습니다 — 작업 worktree 에 미커밋 변경이 있습니다:\n%s\n' "$dirty"
    return 1
  fi
  def="$(_pq_default_branch)" || { printf '기본 브랜치를 정할 수 없습니다 — 판정 불가\n' >&2; return 3; }
  head="$(git -C "${project_root:-$PWD}" rev-parse HEAD 2>/dev/null)" || return 3
  frb="$(git -C "${project_root:-$PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  conflicts="$(pq_merge_check "$def" "$head")"; rc=$?
  if [[ "$rc" -eq 1 ]]; then
    printf '요청할 수 없습니다 — 기본 브랜치(%s)와 병합 충돌하는 파일이 있습니다:\n' "$def"
    while IFS= read -r p; do [[ -n "$p" ]] && printf '  - %s\n' "$p"; done <<EOF2
$conflicts
EOF2
    rd_merge_conflict_guide '' "$frb" "$def" "${project_root:-$PWD}"
    return 1
  elif [[ "$rc" -ne 0 ]]; then
    printf '병합 충돌 사전 확인을 판정할 수 없습니다\n' >&2
    return 3
  fi

  rc=0
  session_caller_alive "$backend" "$cid" || rc=$?
  case "$rc" in
    0) ;;
    1) lost=1 ;;
    *) printf '경고: 호출 세션 생존을 판정할 수 없습니다 — 그대로 큐에 넣습니다\n' >&2 ;;
  esac

  pq_lock || { printf '큐 락 획득 실패 — 잠시 뒤 다시 시도하십시오\n' >&2; return 1; }
  _pq_prune_done
  rc=0
  cur="$(_pq_state_of "$slug")" || rc=$?
  if [[ "$rc" -eq 3 ]]; then pq_unlock; return 3; fi
  if [[ "$rc" -eq 0 ]]; then
    case "$cur" in
      granted|running|partial)
        pq_unlock
        printf '이미 %s 상태의 요청이 있습니다 — 중복 요청하지 않습니다\n' "$(pq_label "$cur")"
        return 1 ;;
    esac
  fi
  if [[ "$lost" -eq 1 ]]; then
    _pq_write_request "$slug" user-approval "호출 세션 소실" "$backend" "$cid" "$frb" "$head"
    pq_unlock
    printf '호출 세션이 사라졌습니다 — 사용자에게 승인을 물으십시오. 승인되면 rd publish approve %s 뒤 rd publish run 을 실행합니다\n' "$slug"
    bp="$(_pq_bypass_text "$slug")"
    [[ -n "$bp" ]] && printf '%s\n' "$bp"
    return 11
  fi
  _pq_write_request "$slug" requested "" "$backend" "$cid" "$frb" "$head"
  pq_unlock
  printf '요청했습니다: %s\n' "$slug"
  bp="$(_pq_bypass_text "$slug")"
  [[ -n "$bp" ]] && printf '%s\n' "$bp"
  printf '다음 행동: rd publish wait 를 백그라운드로 실행해 허가를 기다리십시오\n'
  return 0
}

# ---------------------------------------------------------------- next (D6)

pq_cmd_next() {
  local main common slot best="" bestseq="" f s seq st rc corrupt=0 d bp
  main="$(_pq_main_checkout)" || { printf '기본 체크아웃을 찾을 수 없습니다 — 판정 불가\n' >&2; return 3; }
  common="$(_pq_common_dir)"
  if [[ -f "$common/MERGE_HEAD" ]]; then
    printf '허가하지 않습니다 — 기본 체크아웃에 병합이 진행 중입니다 (MERGE_HEAD)\n'
    return 1
  fi
  if [[ -n "$(git -C "$main" status --porcelain 2>/dev/null)" ]]; then
    printf '허가하지 않습니다 — 기본 체크아웃에 미커밋 변경이 있습니다\n'
    return 1
  fi
  d="$(pq_dir)" || return 1
  pq_lock || { printf '큐 락 획득 실패 — 잠시 뒤 다시 시도하십시오\n' >&2; return 1; }
  if [[ -f "$d/ACTIVE" ]]; then
    rc=0
    slot="$(_pq_slot_check)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      pq_unlock
      return 3
    fi
    st="$(_pq_state_of "$slot" 2>/dev/null)"
    pq_unlock
    printf '허가하지 않습니다 — 앞 요청 %s 가 %s 입니다\n' "$slot" "$(pq_label "$st")"
    return 1
  fi
  for f in "$d"/*.req; do
    [[ -f "$f" ]] || continue
    s="$(basename "$f" .req)"
    rc=0
    st="$(_pq_state_of "$s" 2>/dev/null)" || rc=$?
    if [[ "$rc" -eq 3 ]]; then corrupt=1; _pq_state_of "$s" >/dev/null; continue; fi
    [[ "$st" == requested ]] || continue
    seq="$(pq_get "$s" seq)"
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    if [[ -z "$best" ]] || (( seq < bestseq )); then best="$s"; bestseq="$seq"; fi
  done
  if [[ "$corrupt" -eq 1 ]]; then
    pq_unlock
    printf '허가하지 않습니다 — 손상된 요청 파일이 있어 순서를 보장할 수 없습니다 (판정 불가). 위 파일을 직접 고치거나 삭제하십시오\n'
    return 3
  fi
  if [[ -z "$best" ]]; then
    pq_unlock
    printf '허가할 요청 없음\n'
    return 1
  fi
  pq_set "$best" state=granted reason=
  pq_slot_set "$best"
  pq_unlock
  bp="$(_pq_bypass_text "$best")"
  printf '허가했습니다: %s%s\n' "$best" "${bp:+ — $bp}"
  return 0
}

# ---------------------------------------------------------------- approve (D4·D13)

pq_cmd_approve() {
  local slug="${1:-}" st rc=0 d slot bp
  if [[ -z "$slug" ]]; then
    slug="$(_pq_current_slug)" || { printf 'slug 를 정할 수 없습니다 — rd publish approve <slug>\n' >&2; return 2; }
  fi
  _pq_slug_ok "$slug" || { printf '올바르지 않은 slug: %s\n' "$slug" >&2; return 2; }
  d="$(pq_dir)" || return 1
  pq_lock || { printf '큐 락 획득 실패 — 잠시 뒤 다시 시도하십시오\n' >&2; return 1; }
  st="$(_pq_state_of "$slug")" || rc=$?
  if [[ "$rc" -eq 3 ]]; then pq_unlock; return 3; fi
  if [[ "$rc" -ne 0 ]]; then pq_unlock; printf '승인할 요청 없음: %s\n' "$slug"; return 1; fi
  if [[ "$st" != user-approval ]]; then
    pq_unlock
    printf '승인할 수 없습니다 — %s 는 %s 상태입니다 (사용자 승인 대상만 승인)\n' "$slug" "$(pq_label "$st")"
    return 1
  fi
  if [[ -f "$d/ACTIVE" ]]; then
    slot="$(pq_slot_get)"
    pq_unlock
    printf '승인할 수 없습니다 — 앞 요청 %s 가 허가 슬롯을 쥐고 있습니다\n' "${slot:-손상된 슬롯}"
    return 1
  fi
  pq_set "$slug" state=granted reason=
  pq_slot_set "$slug"
  pq_unlock
  printf '승인했습니다: %s — rd publish run 을 실행하십시오\n' "$slug"
  bp="$(_pq_bypass_text "$slug")"
  [[ -n "$bp" ]] && printf '%s\n' "$bp"
  return 0
}

# ---------------------------------------------------------------- run (D8)

# 재검증 (AC14). <mode> granted 면 a~e, partial 이면 a·b·d. 실패 사유 한 줄을 stdout 에 내고 rc 1.
_pq_reverify() {  # <slug> <mode> <head>
  local slug="$1" mode="$2" head="$3" st dirty def now_head main common conflicts rc wtp
  st="$(cd "${project_root:-$PWD}" && bash rd-workflow/scripts/rd task status 2>/dev/null | head -1)"
  if [[ "$st" != "아카이브 보류" ]]; then printf 'Status 가 %s 입니다 (아카이브 보류 필요)\n' "${st:-읽을 수 없음}"; return 1; fi
  dirty="$(git -C "${project_root:-$PWD}" status --porcelain 2>/dev/null)" || { printf '작업 worktree 상태를 읽을 수 없습니다\n'; return 1; }
  [[ -z "$dirty" ]] || { printf '작업 worktree 에 미커밋 변경이 있습니다\n'; return 1; }
  if [[ "$mode" == granted ]]; then
    now_head="$(git -C "${project_root:-$PWD}" rev-parse HEAD 2>/dev/null)"
    [[ -n "$head" && "$now_head" == "$head" ]] || { printf '작업 브랜치 HEAD 가 요청 때와 다릅니다 — 다시 요청하십시오\n'; return 1; }
  fi
  main="$(_pq_main_checkout)" || { printf '기본 체크아웃을 찾을 수 없습니다\n'; return 1; }
  common="$(_pq_common_dir)"
  [[ ! -f "$common/MERGE_HEAD" ]] || { printf '기본 체크아웃에 병합이 진행 중입니다 (MERGE_HEAD)\n'; return 1; }
  [[ -z "$(git -C "$main" status --porcelain 2>/dev/null)" ]] || { printf '기본 체크아웃에 미커밋 변경이 있습니다\n'; return 1; }
  if [[ "$mode" == granted ]]; then
    def="$(_pq_default_branch)" || { printf '기본 브랜치를 정할 수 없습니다\n'; return 1; }
    conflicts="$(pq_merge_check "$def" "$head")"; rc=$?
    if [[ "$rc" -eq 1 ]]; then
      printf '기본 브랜치(%s)와 병합 충돌: %s\n' "$def" "$(printf '%s' "$conflicts" | tr '\n' ' ')"
      wtp="$(pq_get "$slug" worktree || true)"
      rd_merge_conflict_guide '' "$(pq_get "$slug" fr-branch || true)" "$def" "${wtp:-${project_root:-$PWD}}"
      return 1
    elif [[ "$rc" -ne 0 ]]; then printf '병합 충돌 사전 확인을 판정할 수 없습니다\n'; return 1; fi
  fi
  return 0
}

# 발행 증거 판정 (작업 worktree 의 저장소 기준). stdout: in-progress|needs-verify|cleanup-pending, 실패 rc 3.
_pq_evidence() {  # <slug>
  local head def mode
  head="$(pq_get "$1" head)"
  [[ -n "$head" ]] || return 3
  git -C "${project_root:-$PWD}" cat-file -e "${head}^{commit}" 2>/dev/null || return 3
  def="$(_pq_default_branch)" || return 3
  [[ -n "$def" ]] || return 3
  mode="$(cd "${project_root:-$PWD}" && detect_remote_mode 2>/dev/null)" || mode=local-only
  (cd "${project_root:-$PWD}" && tasks_publish_evidence "$1" "$head" "$def" "$mode") || return 3
}

pq_cmd_run() {
  local slug st rc=0 from token mypid wt why ev arc_rc lastline hint
  slug="$(_pq_current_slug)" || { printf 'slug 를 정할 수 없습니다 — 작업 worktree 에서 실행하십시오\n' >&2; return 2; }
  _pq_slug_ok "$slug" || { printf '올바르지 않은 slug: %s\n' "$slug" >&2; return 2; }
  pq_lock || { printf '큐 락 획득 실패 — 잠시 뒤 다시 시도하십시오\n' >&2; return 1; }
  st="$(_pq_state_of "$slug")" || rc=$?
  if [[ "$rc" -eq 3 ]]; then pq_unlock; return 3; fi
  if [[ "$rc" -ne 0 ]]; then pq_unlock; printf '발행 요청이 없습니다: %s — 먼저 rd publish request\n' "$slug"; return 1; fi
  case "$st" in
    granted|partial)
      if [[ "$(pq_slot_get)" != "$slug" ]]; then
        pq_unlock; printf '발행할 수 없습니다 — 허가 슬롯이 %s 의 것이 아닙니다\n' "$slug"; return 1
      fi ;;
    running)
      mypid="$(pq_get "$slug" run-pid)"
      pq_unlock; printf '이미 발행 중입니다 (pid %s)\n' "${mypid:-?}"; return 1 ;;
    cancelled) pq_unlock; printf '취소된 요청입니다 — 필요하면 rd publish request\n'; return 1 ;;
    *) pq_unlock; printf '발행할 수 없습니다 — %s 는 %s 상태입니다\n' "$slug" "$(pq_label "$st")"; return 1 ;;
  esac
  from="$st"
  token="$(date +%s)-$$-$RANDOM"
  pq_set "$slug" state=running "run-pid=$$" "run-token=$token" "archive-pgid=" "run-from=$from" reason=
  pq_unlock

  why="$(_pq_reverify "$slug" "$from" "$(pq_get "$slug" head)")" || {
    pq_lock || { printf '큐 락 획득 실패 — 상태가 running 으로 남았습니다. rd publish recover %s\n' "$slug" >&2; return 1; }
    if [[ "$from" == partial ]]; then
      pq_set "$slug" state=partial "run-token=" "reason=재검증 실패: $why — 원인을 해소한 뒤 rd publish run"
    else
      pq_set "$slug" state=failed "run-token=" "reason=재검증 실패: $why"
      [[ "$(pq_slot_get)" == "$slug" ]] && pq_slot_clear
    fi
    pq_unlock
    printf '발행하지 않았습니다 — 재검증 실패: %s\n' "$why"
    return 1
  }

  wt="${project_root:-$PWD}"
  : >"$(pq_dir)/$slug.log"
  set -m
  bash "${BASH_SOURCE[0]}" _exec "$slug" "$token" &
  local epid=$!
  set +m
  wait "$epid"; arc_rc=$?
  # 출력 로그를 나르는 tee 가 마저 비울 때까지 기다린다. archive 가 끝나면 그 프로세스 그룹에는 tee 만
  # 남으므로 그룹이 비는 시점이 곧 tee 종료다. 부하가 높으면 tee 가 2초 가까이 걸려(실측) 상한은
  # 넉넉히 30초로 두고, 상한은 출력을 쥔 채 남은 프로세스 때문에 발행이 끝없이 멈추지 않게 하는 용도다.
  local pgw pgn=0 drained=1 logf
  logf="$(pq_dir)/$slug.log"
  pgw="$(pq_get "$slug" archive-pgid)"
  case "$pgw" in ''|*[!0-9]*) ;; *)
    while kill -0 -- "-$pgw" 2>/dev/null; do
      (( pgn < 300 )) || { drained=0; break; }
      # 2초를 넘기면 멈춘 것으로 보이지 않게 한 번 알린다 (stderr — archive 출력 로그에는 섞이지 않는다).
      (( pgn == 20 )) && printf 'archive 출력 기록이 끝나기를 기다립니다 (최대 30초) — 전체 출력: %s\n' "$logf" >&2
      sleep 0.1; pgn=$((pgn+1))
    done ;;
  esac
  lastline="$(grep -v '^[[:space:]]*$' "$logf" 2>/dev/null | tail -1)"
  # 상한에 닿으면 마지막 줄이 실제 마지막이 아닐 수 있다 — 전체 출력 위치를 함께 알린다.
  [[ "$drained" -eq 1 ]] || lastline="${lastline:+$lastline }(출력 기록이 끝나지 않았습니다 — 전체 출력: $logf)"

  ev="$(_pq_evidence "$slug")" || ev=""
  pq_lock || { printf '큐 락 획득 실패 — 상태가 running 으로 남았습니다. rd publish recover %s\n' "$slug" >&2; return 1; }
  case "$ev" in
    cleanup-pending)
      pq_set "$slug" state=done "run-token=" "result-main=$(git -C "$wt" rev-parse "refs/heads/$(_pq_default_branch)" 2>/dev/null)" \
        "result-tag=$(git -C "$wt" tag --list "fr/*/${slug}" 2>/dev/null | sort | tail -1)" reason=
      [[ "$(pq_slot_get)" == "$slug" ]] && pq_slot_clear
      pq_unlock; printf '발행 완료: %s\n' "$slug"; return 0 ;;
    needs-verify)
      pq_set "$slug" state=partial "run-token=" "reason=병합됐으나 tag·push 미확인 — rd publish run 으로 복구"
      pq_unlock; printf '부분 완료: 병합됐으나 tag·push 미확인 — rd publish run 으로 복구하십시오\n'; return 1 ;;
    *)
      pq_set "$slug" state=failed "run-token=" "reason=archive.sh 종료 코드 ${arc_rc}${lastline:+ — $lastline}"
      [[ "$(pq_slot_get)" == "$slug" ]] && pq_slot_clear
      pq_unlock; printf '발행 실패: archive.sh 종료 코드 %s%s\n' "$arc_rc" "${lastline:+ — $lastline}"
      hint=""
      grep -q -e '--allow-gitlink-drop' "$(pq_dir)/$slug.log" 2>/dev/null && hint="$hint --allow-gitlink-drop \"<사유>\""
      grep -q -e '--force-skip-review-check' "$(pq_dir)/$slug.log" 2>/dev/null && hint="$hint --force-skip-review-check \"<사유>\""
      [[ -n "$hint" ]] && printf '큐 경로에서는 사람의 결정을 받은 뒤 rd publish request%s --basis "<날짜> <결정한 사람> — <한 말>" 로 다시 요청하십시오\n' "$hint"
      return 1 ;;
  esac
}

# 중간 실행기 (D8-3). 큐 락 안에서 running·토큰 확인 → archive-pgid 기록 → 락 해제 → archive 로 exec.
pq_cmd_exec() {  # <slug> <token>
  local slug="${1:-}" token="${2:-}" st pg cmd
  PQ_BP_ARGS=()
  [[ -n "$slug" && -n "$token" ]] || return 1
  _pq_slug_ok "$slug" || return 1
  pq_lock || return 1
  st="$(_pq_state_of "$slug" 2>/dev/null)" || st=""
  if [[ "$st" != running || "$(pq_get "$slug" run-token)" != "$token" ]]; then
    pq_unlock
    printf '발행 진입을 거부합니다 — 요청 상태가 달라졌습니다 (rd publish status)\n' >&2
    return 1
  fi
  pg="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  # 전용 프로세스 그룹을 기록하지 못하면 recover 가 실행 중인 발행을 알아보지 못한다 — 진입하지 않는다.
  case "$pg" in
    ''|*[!0-9]*)
      pq_unlock
      printf '발행 진입을 거부합니다 — 프로세스 그룹을 확인하지 못했습니다 (ps 실패)\n' >&2
      return 1 ;;
  esac
  pq_set "$slug" "archive-pgid=$pg"
  _pq_bypass_args "$slug"
  pq_unlock
  cd "${project_root:-$PWD}" || return 1
  # 출력은 터미널과 로그 파일 둘 다로 보낸다 (run 이 실패 사유에 마지막 줄을 남긴다).
  exec > >(tee -a "$(pq_dir)/$slug.log") 2>&1
  if [[ -n "${RD_PQ_ARCHIVE:-}" ]]; then
    exec env -u project_root -u TASK_STATE_PATH "$RD_PQ_ARCHIVE" ${PQ_BP_ARGS[@]+"${PQ_BP_ARGS[@]}"}
  fi
  exec env -u project_root -u TASK_STATE_PATH bash rd-workflow/scripts/lifecycle/archive.sh ${PQ_BP_ARGS[@]+"${PQ_BP_ARGS[@]}"}
}

# ---------------------------------------------------------------- recover (D11)

pq_cmd_recover() {
  local slug="${1:-}" st rc=0 pid pg err owner own_pid own_cmd own_slug lockf ev cmd
  if [[ -z "$slug" ]]; then
    slug="$(_pq_current_slug)" || { printf 'slug 를 정할 수 없습니다 — rd publish recover <slug>\n' >&2; return 2; }
  fi
  _pq_slug_ok "$slug" || { printf '올바르지 않은 slug: %s\n' "$slug" >&2; return 2; }
  pq_lock || { printf '큐 락 획득 실패 — 잠시 뒤 다시 시도하십시오\n' >&2; return 1; }
  st="$(_pq_state_of "$slug")" || rc=$?
  if [[ "$rc" -eq 3 ]]; then pq_unlock; return 3; fi
  if [[ "$rc" -ne 0 ]]; then pq_unlock; printf '복구할 요청 없음: %s\n' "$slug"; return 1; fi
  if [[ "$st" != running ]]; then
    pq_unlock
    printf '복구 대상이 아닙니다 — %s 는 %s 상태입니다 (partial 은 rd publish run)\n' "$slug" "$(pq_label "$st")"
    return 1
  fi
  pid="$(pq_get "$slug" run-pid)"
  if _pq_pid_alive "$pid"; then
    # 살아 있는 pid 의 명령을 읽지 못하면 실행 종료의 증거가 아니다 — 슬롯을 그대로 둔다.
    if ! cmd="$(ps -o command= -p "$pid" 2>/dev/null)"; then
      pq_unlock; printf 'pid %s 가 살아 있으나 명령을 확인하지 못했습니다 — 판정 불가, 복구하지 않습니다\n' "$pid" >&2; return 3
    fi
    if [[ "$cmd" == *publish_queue.sh* ]]; then
      pq_unlock; printf '발행 명령이 실행 중입니다 (pid %s) — 복구하지 않습니다\n' "$pid"; return 1
    fi
  fi
  pg="$(pq_get "$slug" archive-pgid)"
  case "$pg" in
    '') ;;
    *[!0-9]*) pq_unlock; printf 'archive-pgid 값이 올바르지 않습니다 (%s) — 판정 불가\n' "$pg" >&2; return 3 ;;
    *)
      rc=0; err="$(kill -0 -- "-$pg" 2>&1)" || rc=$?
      if [[ "$rc" -eq 0 ]]; then
        pq_unlock; printf '발행 명령이 실행 중입니다 (archive 프로세스 그룹 %s) — 복구하지 않습니다\n' "$pg"; return 1
      elif [[ "$err" != *"No such process"* ]]; then
        pq_unlock; printf '프로세스 그룹 %s 확인 실패 (%s) — 판정 불가\n' "$pg" "$err" >&2; return 3
      fi ;;
  esac
  lockf="$(tasks_shared_dir)/tasks.lock/owner"
  if [[ -f "$lockf" ]]; then
    own_pid="$(_tasks_lock_owner_field "$lockf" pid || true)"
    own_cmd="$(_tasks_lock_owner_field "$lockf" cmd || true)"
    own_slug="$(_tasks_lock_owner_field "$lockf" slug || true)"
    if [[ "$own_cmd" == archive && "$own_slug" == "$slug" ]] && _pq_pid_alive "$own_pid"; then
      pq_unlock; printf '발행 명령이 실행 중입니다 (tasks 락 보유 pid %s) — 복구하지 않습니다\n' "$own_pid"; return 1
    fi
  fi
  rc=0
  ev="$(_pq_evidence "$slug")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then pq_unlock; printf '판정 불가 — 발행 증거를 확인할 수 없습니다. 사용자 확인 필요\n' >&2; return 3; fi
  case "$ev" in
    cleanup-pending)
      pq_set "$slug" state=done "run-token=" reason=
      [[ "$(pq_slot_get)" == "$slug" ]] && pq_slot_clear
      printf '복구: 발행이 이미 끝났습니다 (성공)\n' ;;
    needs-verify)
      pq_set "$slug" state=partial "run-token=" "reason=병합됐으나 tag·push 미확인 — rd publish run 으로 복구"
      printf '복구: 부분 완료 — rd publish run 으로 이어가십시오\n' ;;
    in-progress)
      pq_set "$slug" state=requested "run-token=" "reason=발행 전 중단 — 다시 허가 필요"
      [[ "$(pq_slot_get)" == "$slug" ]] && pq_slot_clear
      printf '복구: 발행 전에 중단됐습니다 — 요청됨으로 되돌렸습니다 (다시 허가 필요)\n' ;;
    *) pq_unlock; printf '판정 불가\n' >&2; return 3 ;;
  esac
  pq_unlock
  return 0
}

# ---------------------------------------------------------------- wait · watch (D9·D13)

# 소수 초 간격 값 검증. 비었거나 숫자가 아니면 기본값.
_pq_num() {  # <값> <기본>
  case "$1" in ''|*[!0-9.]*|*.*.*|.) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# --timeout 인자 파싱. stdout 초(정수).
_pq_timeout_arg() {  # <args...>
  local t=3600
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) shift; t="${1:-}"; case "$t" in ''|*[!0-9]*) return 2 ;; esac ;;
      *) return 2 ;;
    esac
    shift
  done
  printf '%s\n' "$t"
}

# wait 가 요청의 새 상태를 보고한다.
_pq_wait_report() {  # <slug> <state>
  local slug="$1" st="$2" reason
  reason="$(pq_get "$slug" reason)"
  case "$st" in
    granted) printf '허가됨: %s — rd publish run 으로 발행하십시오\n' "$slug" ;;
    user-approval) printf '사용자 승인 대상: %s%s — 사용자에게 승인을 받은 뒤 rd publish approve → rd publish run\n' "$slug" "${reason:+ ($reason)}" ;;
    *) printf '%s: %s%s → %s\n' "$slug" "$(pq_label "$st")" "${reason:+ ($reason)}" "$(_pq_next_action "$slug" "$st")" ;;
  esac
}

pq_cmd_wait() {
  local slug timeout poll chk since=0 st rc backend cid start alive
  timeout="$(_pq_timeout_arg "$@")" || { printf '사용법: rd publish wait [--timeout 초]\n' >&2; return 2; }
  slug="$(_pq_current_slug)" || { printf 'slug 를 정할 수 없습니다 — 작업 worktree 에서 실행하십시오\n' >&2; return 2; }
  _pq_slug_ok "$slug" || { printf '올바르지 않은 slug: %s\n' "$slug" >&2; return 2; }
  poll="$(_pq_num "${RD_PQ_POLL:-}" 2)"
  chk="$(_pq_num "${RD_PQ_CALLER_CHECK:-}" 60)"
  backend="$(tasks_index_get "$slug" caller-backend 2>/dev/null || true)"
  cid="$(tasks_index_get "$slug" caller-id 2>/dev/null || true)"
  start=$SECONDS
  while :; do
    rc=0
    st="$(_pq_state_of "$slug")" || rc=$?
    if [[ "$rc" -eq 3 ]]; then _pq_state_of "$slug" >/dev/null; return 3; fi
    if [[ "$rc" -ne 0 ]]; then printf '발행 요청이 없습니다: %s — 먼저 rd publish request\n' "$slug"; return 1; fi
    if [[ "$st" != requested ]]; then
      _pq_wait_report "$slug" "$st"
      return 0
    fi
    if (( SECONDS - start >= timeout )); then
      printf '대기 시간 초과 (%s초) — 호출 세션에 큐 확인을 요청하거나 사용자에게 알리십시오\n' "$timeout"
      return 4
    fi
    sleep "$poll"
    since="$(awk -v a="$since" -v b="$poll" 'BEGIN{print a+b}')"
    if awk -v a="$since" -v b="$chk" 'BEGIN{exit !(a>=b)}'; then
      since=0
      alive=0
      session_caller_alive "$backend" "$cid" || alive=$?
      if [[ "$alive" -eq 1 ]]; then
        pq_lock || { printf '큐 락 획득 실패 — 호출 세션 소실을 기록하지 못했습니다\n' >&2; return 1; }
        st="$(_pq_state_of "$slug" 2>/dev/null)" || st=""
        if [[ "$st" == requested ]]; then
          pq_set "$slug" state=user-approval "reason=호출 세션 소실"
          [[ "$(pq_slot_get)" == "$slug" ]] && pq_slot_clear
          pq_unlock
          printf '호출 세션이 사라졌습니다 — 사용자에게 승인을 받은 뒤 rd publish approve %s → rd publish run\n' "$slug"
          _pq_bypass_text "$slug"
          return 11
        fi
        pq_unlock
      fi
    fi
  done
}

# 호출 세션용 사건 수집. stdout 에 사건 줄, 결과 사건은 큐 락 안에서 notified 기록.
# rc 0 사건 있음 / 1 없음.
_pq_watch_scan() {
  local d f s st n got=0 slot nreq=0 first="" rc reason bp
  d="$(pq_dir)" || return 1
  for f in "$d"/*.req; do
    [[ -f "$f" ]] || continue
    s="$(basename "$f" .req)"
    rc=0
    st="$(_pq_state_of "$s" 2>/dev/null)" || rc=$?
    [[ "$rc" -eq 0 ]] || continue
    case "$st" in
      done|partial|failed|user-approval)
        n="$(pq_get "$s" notified)"
        if [[ "$n" != "$st" ]]; then
          reason="$(pq_get "$s" reason)"
          if pq_lock; then
            pq_set "$s" "notified=$st"
            pq_unlock
          fi
          printf '발행 결과 %s: %s%s → %s\n' "$s" "$(pq_label "$st")" "${reason:+ ($reason)}" "$(_pq_next_action "$s" "$st")"
          if [[ "$st" == user-approval ]]; then
            bp="$(_pq_bypass_text "$s")"
            [[ -n "$bp" ]] && printf '  %s\n' "$bp"
          fi
          got=1
        fi ;;
      requested) nreq=$((nreq+1)); [[ -n "$first" ]] || first="$s" ;;
    esac
  done
  slot="$(pq_slot_get)"
  if [[ -z "$slot" && "$nreq" -gt 0 ]]; then
    for f in "$d"/*.req; do
      [[ -f "$f" ]] || continue
      s="$(basename "$f" .req)"
      [[ "$(_pq_state_of "$s" 2>/dev/null)" == requested ]] && { bp="$(_pq_bypass_text "$s")"; printf '발행 요청 %s%s — rd publish next 로 허가\n' "$s" "${bp:+ — $bp}"; }
    done
    got=1
  fi
  [[ "$got" -eq 1 ]]
}

pq_cmd_watch() {
  local timeout poll start
  timeout="$(_pq_timeout_arg "$@")" || { printf '사용법: rd publish watch [--timeout 초]\n' >&2; return 2; }
  poll="$(_pq_num "${RD_PQ_POLL:-}" 2)"
  start=$SECONDS
  while :; do
    if _pq_watch_scan; then
      printf '처리한 뒤 rd publish watch 를 다시 백그라운드로 실행하십시오\n'
      return 0
    fi
    if (( SECONDS - start >= timeout )); then
      printf '변화 없음 — 다시 대기\n'
      return 4
    fi
    sleep "$poll"
  done
}

# ---------------------------------------------------------------- 디스패치

_pq_usage() {
  printf '사용법: rd publish <request|wait|next|approve|run|watch|status|cancel|recover> [인자]\n  request [--allow-gitlink-drop <사유>] [--force-skip-review-check <사유>] --basis <근거>\n' >&2
}

main() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    status) pq_cmd_status "$@" ;;
    cancel) pq_cmd_cancel "$@" ;;
    request) pq_cmd_request "$@" ;;
    next) pq_cmd_next "$@" ;;
    approve) pq_cmd_approve "$@" ;;
    run) pq_cmd_run "$@" ;;
    _exec) pq_cmd_exec "$@" ;;
    recover) pq_cmd_recover "$@" ;;
    wait) pq_cmd_wait "$@" ;;
    watch) pq_cmd_watch "$@" ;;
    ''|-h|--help) _pq_usage; return 2 ;;
    *) printf '알 수 없는 하위 명령: %s\n' "$sub" >&2; _pq_usage; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  exit $?
fi
