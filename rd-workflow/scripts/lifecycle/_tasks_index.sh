#!/usr/bin/env bash
# 작업 집합 색인(untracked) 과 공유 자원 락.
#   색인은 캐시이지 권위가 아니다 — 손상되어도 `git worktree list` + 각 worktree 의
#   task-state 로 재구성 가능하다(rd task list --rebuild).
#   내용이 머신 종속(절대 경로·pane id)이라 추적하지 않는다. 추적하면 착수마다 기본
#   브랜치 커밋이 생겨, 이 변경이 없애려는 경합이 그대로 돌아온다.
#
# bash 3.2 호환: 연관배열(declare -A) 미사용. 인덱스 배열·문자열 누적만 사용.

# 공유 위치는 --git-common-dir 이다. 기본 브랜치를 체크아웃한 worktree 를 찾는 방식은
# --no-worktree 로 그 체크아웃이 fr 브랜치로 넘어가는 순간 공유 위치와 관리 진입점을
# 통째로 잃는다 (spec/plan review R1).
#
# **어느 저장소인지는 `project_root` 가 정한다 — cwd 가 아니다** (final diff review).
# 예전에는 `git rev-parse` 를 cwd 에서 돌렸는데, 이 코드베이스에서 "작업 대상 저장소" 를
# 가리키는 값은 `project_root` 이고 둘은 갈릴 수 있다. 특히 `rd` 는 `promote.sh`·
# `promote_rollback.sh` 와 달리 `cd "$project_root"` 를 하지 않으므로, 다른 저장소 안에서
# `rd task ...` 를 부르면 **그 저장소의 색인에 썼다.** 실제로 이 스위트가 개발자의 실제
# 저장소 색인에 행을 남긴 사고가 있었다. `archive.sh` 의 `TASK_STATE_PATH` 가 source
# 시점 `$PWD` 로 굳던 결함(FR archive-cwd-dependent-state-path)과 같은 뿌리다.
#
# `project_root` 가 없을 때의 동작은 예전과 같다(`$PWD`) — 이 파일을 단독으로 source 해
# 쓰는 호출부(테스트·일회성 조회)가 그대로 동작한다.
_TASKS_SD_KEY="${_TASKS_SD_KEY:-}"; _TASKS_SD_COMMON="${_TASKS_SD_COMMON:-}"; _TASKS_SD_VAL="${_TASKS_SD_VAL:-}"
_tasks_sd_key() {
  local r="${project_root:-$PWD}"
  case "$r" in /*) ;; *) r="$PWD/$r" ;; esac
  _TASKS_SD_K="$r|${GIT_DIR:-}|${GIT_COMMON_DIR:-}"
}
# 현재 셸에 공유 위치를 채운다(서브셸 없이). 실패하면 _TASKS_SD_VAL 을 비우고 rc 1.
_tasks_shared_dir_fill() {
  _tasks_sd_key
  if [[ -n "$_TASKS_SD_COMMON" && "$_TASKS_SD_K" == "$_TASKS_SD_KEY" && -d "$_TASKS_SD_COMMON" ]]; then
    [[ -d "$_TASKS_SD_COMMON/rd-workflow" ]] || mkdir -p "$_TASKS_SD_COMMON/rd-workflow" || { _TASKS_SD_VAL=""; return 1; }
    _TASKS_SD_VAL="$_TASKS_SD_COMMON/rd-workflow"; return 0
  fi
  _TASKS_SD_KEY=""; _TASKS_SD_COMMON=""; _TASKS_SD_VAL=""
  local cd_
  cd_="$(git -C "${project_root:-$PWD}" rev-parse --path-format=absolute --git-common-dir)" || return 1
  _TASKS_SD_KEY="$_TASKS_SD_K"; _TASKS_SD_COMMON="$cd_"
  [[ -d "$cd_/rd-workflow" ]] || mkdir -p "$cd_/rd-workflow" || return 1
  _TASKS_SD_VAL="$cd_/rd-workflow"
}
tasks_shared_dir() { _tasks_shared_dir_fill || return 1; printf '%s\n' "$_TASKS_SD_VAL"; }
tasks_index_path() { _tasks_shared_dir_fill || :; printf '%s/tasks.local\n' "$_TASKS_SD_VAL"; }
# source 시점 선계산 — 조용히, mkdir 없이 common dir 만 채운다.
if [[ -z "$_TASKS_SD_COMMON" ]]; then
  _tasks_sd_key
  _TASKS_SD_COMMON="$(git -C "${project_root:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && _TASKS_SD_KEY="$_TASKS_SD_K" || { _TASKS_SD_COMMON=""; _TASKS_SD_KEY=""; }
fi

# 색인 파일이 없으면 schema=1 한 줄로 새로 만들고 경로를 돌려준다.
_tasks_index_ensure() {
  local path
  path="$(tasks_index_path)" || return 1
  if [[ ! -f "$path" ]]; then
    printf 'schema=1\n' > "$path" || return 1
  fi
  printf '%s\n' "$path"
}

# $1 의 값에 탭·개행이 있으면 실패한다.
_tasks_index_no_tab_nl() {
  case "$1" in
    *$'\t'*|*$'\n'*) return 1 ;;
  esac
  return 0
}

# 행 형식: slug=<slug>\tk=v\tk=v ...  (첫 줄은 schema=1)
# 값에 탭·개행을 허용하지 않는다 (upsert 가 거부한다).
# 원자적 쓰기: mktemp + mv 로 부분 기록 상태를 남기지 않는다.
# 계약: upsert 는 "전체 행 교체"가 아니라 **키 단위 병합**이다 — 호출 시 넘긴 k=v 만
# 갱신·추가되고, 그 행에 이미 있던 다른 키는 그대로 보존된다. 예: `launch=launching` 로
# 갱신한 뒤 다른 호출에서 `launch-token=...` 만 넘겨도 launch 값은 사라지지 않는다.
# "전체 행 교체"로 리팩터링하면 매 upsert 호출마다 그 행의 모든 키를 다시 채워 넣어야
# 하며, 누락 시 이런 예약 필드가 조용히 사라진다.
tasks_index_upsert() {
  local slug="$1"; shift || true
  [[ -n "${slug:-}" ]] || return 1
  _tasks_index_no_tab_nl "$slug" || return 1

  local kv
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *) return 1 ;;
    esac
    _tasks_index_no_tab_nl "$kv" || return 1
  done

  local path tmp
  _tasks_shared_dir_fill || :; path="$_TASKS_SD_VAL/tasks.local"; [[ -f "$path" ]] || printf 'schema=1\n' > "$path" || return 1
  tmp="$(mktemp "${path}.XXXXXX")" || return 1

  local found=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "slug=${slug}" || "$line" == "slug=${slug}"$'\t'* ]]; then
      found=1
      local fields
      IFS=$'\t' read -r -a fields <<<"$line"
      # fields[0]="slug=..." — 그 뒤 필드만 기존 k=v.
      local kept=()
      local i field key nkv nkey skip
      for ((i = 1; i < ${#fields[@]}; i++)); do
        field="${fields[$i]}"
        key="${field%%=*}"
        skip=0
        for nkv in "$@"; do
          nkey="${nkv%%=*}"
          if [[ "$key" == "$nkey" ]]; then
            skip=1
            break
          fi
        done
        [[ "$skip" == 1 ]] || kept+=("$field")
      done
      {
        printf 'slug=%s' "$slug"
        if ((${#kept[@]} > 0)); then
          for field in "${kept[@]}"; do printf '\t%s' "$field"; done
        fi
        for nkv in "$@"; do printf '\t%s' "$nkv"; done
        printf '\n'
      } >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$path"

  if [[ "$found" == 0 ]]; then
    {
      printf 'slug=%s' "$slug"
      for kv in "$@"; do printf '\t%s' "$kv"; done
      printf '\n'
    } >>"$tmp"
  fi

  mv -f "$tmp" "$path"
}

tasks_index_remove() {
  local slug="$1"
  [[ -n "${slug:-}" ]] || return 1

  local path
  _tasks_shared_dir_fill || :; path="$_TASKS_SD_VAL/tasks.local"; [[ -f "$path" ]] || printf 'schema=1\n' > "$path" || return 1

  local tmp line
  tmp="$(mktemp "${path}.XXXXXX")" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "slug=${slug}" || "$line" == "slug=${slug}"$'\t'* ]]; then
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"$path"
  mv -f "$tmp" "$path"
}

tasks_index_get() {
  local slug="$1" key="$2"
  local path
  _tasks_shared_dir_fill || :; path="$_TASKS_SD_VAL/tasks.local"
  [[ -f "$path" ]] || { printf ''; return 1; }

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "slug=${slug}" || "$line" == "slug=${slug}"$'\t'* ]]; then
      local fields
      IFS=$'\t' read -r -a fields <<<"$line"
      local f k v
      for f in "${fields[@]}"; do
        k="${f%%=*}"
        v="${f#*=}"
        if [[ "$k" == "$key" ]]; then
          printf '%s\n' "$v"
          return 0
        fi
      done
      printf ''
      return 1
    fi
  done <"$path"
  printf ''
  return 1
}

# 색인의 모든 행(정리 대기 포함)의 slug. 표시·정리 판정용.
tasks_index_all_slugs() {
  local path
  _tasks_shared_dir_fill || :; path="$_TASKS_SD_VAL/tasks.local"
  [[ -f "$path" ]] || return 0

  local line rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      slug=*)
        rest="${line#slug=}"
        printf '%s\n' "${rest%%$'\t'*}"
        ;;
    esac
  done <"$path"
}

# 진행 중인 작업의 slug. `state=cleanup-pending` 행(발행 끝, worktree 정리만 남음)은
# 세지 않는다 — 세면 task_resolve_target 의 「여러 건」 판정이 오판한다.
tasks_index_slugs() {
  local path
  _tasks_shared_dir_fill || :; path="$_TASKS_SD_VAL/tasks.local"
  [[ -f "$path" ]] || return 0

  local line rest
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      slug=*)
        case "$line" in
          *$'\t'state=cleanup-pending|*$'\t'state=cleanup-pending$'\t'*) continue ;;
        esac
        rest="${line#slug=}"
        printf '%s\n' "${rest%%$'\t'*}"
        ;;
    esac
  done <"$path"
}

# owner 파일 한 줄(k=v)의 값을 읽는다. 없으면 rc 1.
_tasks_lock_owner_field() {
  local ownerfile="$1" key="$2" line
  [[ -f "$ownerfile" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "${key}="*)
        printf '%s\n' "${line#${key}=}"
        return 0
        ;;
    esac
  done <"$ownerfile"
  return 1
}

# 락 — mkdir 은 원자적이다. 대기하지 않고 즉시 실패한다.
# rc 0: 획득 / rc 1: 정상 점유 중(살아 있는 pid) / rc 2: 오류·불확실
#   (owner 부재, 또는 owner 의 pid 가 죽어 있음 — 자동 회수하지 않는다. 「검사 → 삭제
#   → 재생성」이 원자적이지 않아 두 회수자가 서로의 새 락을 지울 수 있기 때문이다.)
tasks_lock_acquire() {
  local cmd="$1" slug="$2"
  local shared lockdir ownerfile
  _tasks_shared_dir_fill || return 2; shared="$_TASKS_SD_VAL"
  lockdir="$shared/tasks.lock"
  ownerfile="$lockdir/owner"

  if mkdir "$lockdir" 2>/dev/null; then
    printf 'pid=%s\ncmd=%s\nslug=%s\nstarted-at=%s\n' \
      "$$" "$cmd" "$slug" "$(date -u '+%Y-%m-%d-%H%M')" >"$ownerfile"
    return 0
  fi

  if [[ ! -f "$ownerfile" ]]; then
    {
      printf '락 디렉터리는 있지만 점유자 정보(owner)가 없습니다 — 불확실한 상태입니다.\n'
      printf '이전 실행이 mkdir 직후 중단됐을 수 있습니다. 다른 프로세스가 작업 중이 아님을 직접 확인한 뒤 회수하십시오:\n'
      printf '  rm -rf %q\n' "$lockdir"
    } >&2
    return 2
  fi

  local owner_pid owner_cmd owner_slug owner_started
  owner_pid="$(_tasks_lock_owner_field "$ownerfile" pid || true)"
  owner_cmd="$(_tasks_lock_owner_field "$ownerfile" cmd || true)"
  owner_slug="$(_tasks_lock_owner_field "$ownerfile" slug || true)"
  owner_started="$(_tasks_lock_owner_field "$ownerfile" started-at || true)"

  if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
    printf '락이 이미 점유 중입니다: pid=%s cmd=%s slug=%s started-at=%s\n' \
      "$owner_pid" "$owner_cmd" "$owner_slug" "$owner_started" >&2
    return 1
  fi

  {
    printf '락 점유자(pid=%s cmd=%s slug=%s started-at=%s)가 살아 있지 않아 불확실합니다.\n' \
      "$owner_pid" "$owner_cmd" "$owner_slug" "$owner_started"
    printf '자동 회수하지 않습니다 (경합 시 서로의 새 락을 지울 수 있습니다). 다른 프로세스가 없음을 직접 확인한 뒤 회수하십시오:\n'
    printf '  rm -rf %q\n' "$lockdir"
  } >&2
  return 2
}

# tasks_lock_acquire_wait <cmd> <slug> <wait_for_cmd> [max_sec]
#   점유자 cmd 가 wait_for_cmd 일 때만 1초 간격으로 한정 대기한다. tasks_lock_acquire 의
#   의미는 바꾸지 않는다. rc 0 획득 / 1 점유·상한 초과·다른 점유자 / 2 불확실(종전과 같음).
#   max_sec 생략 시 RD_ARCHIVE_LOCK_WAIT_MAX(기본 60, 0 이면 대기 안 함, 무효값은 경고 후 60).
#   대기 중에는 $(tasks_shared_dir)/archive-waiting 에 자기 pid 를 두어 지연 정리가 양보하게 한다.
tasks_lock_acquire_wait() {
  local cmd="$1" slug="$2" wait_for="$3" max="${4:-}"
  if [[ -z "$max" ]]; then
    max="${RD_ARCHIVE_LOCK_WAIT_MAX:-60}"
    case "$max" in
      *[!0-9]*|[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
        printf '경고: RD_ARCHIVE_LOCK_WAIT_MAX 값이 올바르지 않아 60초를 씁니다 (받은 값: %s)\n' "$max" >&2
        max=60
        ;;
    esac
  fi
  # 선행 0(`08`·`010`)을 bash 산술이 8진수로 읽지 않도록 십진수로 정규화한다.
  case "$max" in
    ''|*[!0-9]*) max=60 ;;
    *) max=$((10#$max)) ;;
  esac

  local shared ownerfile marker err rc=0
  _tasks_shared_dir_fill || return 2; shared="$_TASKS_SD_VAL"
  ownerfile="$shared/tasks.lock/owner"
  marker="$shared/archive-waiting"

  err="$(tasks_lock_acquire "$cmd" "$slug" 2>&1 >/dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] && return 0
  if [[ "$rc" -eq 2 ]]; then printf '%s\n' "$err" >&2; return 2; fi

  local owner_cmd owner_pid
  owner_cmd="$(_tasks_lock_owner_field "$ownerfile" cmd || true)"
  if [[ "$owner_cmd" != "$wait_for" || "$max" -eq 0 ]]; then
    printf '%s\n' "$err" >&2
    return 1
  fi

  owner_pid="$(_tasks_lock_owner_field "$ownerfile" pid || true)"
  printf '%s\n' "$$" >"$marker" 2>/dev/null || true
  local note=""
  [[ "$wait_for" == "tasks-list-prune" ]] && note=" (낡은 정리 대기 기록 정리 중)"
  printf '%s: 락 대기 — 점유자 pid=%s cmd=%s%s, 상한 %s초\n' "$cmd" "$owner_pid" "$wait_for" "$note" "$max" >&2

  local elapsed=0 mark_pid
  while [[ "$elapsed" -lt "$max" ]]; do
    sleep 1
    elapsed=$((elapsed + 1))
    rc=0
    err="$(tasks_lock_acquire "$cmd" "$slug" 2>&1 >/dev/null)" || rc=$?
    if [[ "$rc" -ne 1 ]]; then
      mark_pid="$(cat "$marker" 2>/dev/null || true)"
      [[ "$mark_pid" == "$$" ]] && rm -f "$marker"
      if [[ "$rc" -eq 0 ]]; then
        printf '%s: 락을 얻어 이어갑니다 (대기 %s초)\n' "$cmd" "$elapsed" >&2
        return 0
      fi
      printf '%s\n' "$err" >&2
      return "$rc"
    fi
    owner_cmd="$(_tasks_lock_owner_field "$ownerfile" cmd || true)"
    if [[ -n "$owner_cmd" && "$owner_cmd" != "$wait_for" ]]; then
      mark_pid="$(cat "$marker" 2>/dev/null || true)"
      [[ "$mark_pid" == "$$" ]] && rm -f "$marker"
      printf '%s\n' "$err" >&2
      return 1
    fi
    if [[ $((elapsed % 10)) -eq 0 && "$elapsed" -lt "$max" ]]; then
      printf '%s: 락 대기 중 — %s초 경과 / 상한 %s초\n' "$cmd" "$elapsed" "$max" >&2
    fi
  done

  mark_pid="$(cat "$marker" 2>/dev/null || true)"
  [[ "$mark_pid" == "$$" ]] && rm -f "$marker"
  printf '%s\n' "$err" >&2
  printf '%s: 락 대기 %s초 후 중단 — 점유자가 끝난 뒤 같은 명령을 다시 실행하십시오 (상태 변경 없음).\n' "$cmd" "$max" >&2
  return 1
}

# 자기 pid 가 소유자일 때만 지운다. 남의 락을 지우지 않는다.
tasks_lock_release() {
  local shared lockdir ownerfile owner_pid
  _tasks_shared_dir_fill || return 1; shared="$_TASKS_SD_VAL"
  lockdir="$shared/tasks.lock"
  ownerfile="$lockdir/owner"

  [[ -d "$lockdir" ]] || return 0
  owner_pid="$(_tasks_lock_owner_field "$ownerfile" pid || true)"
  if [[ "$owner_pid" == "$$" ]]; then
    rm -rf "$lockdir"
    return 0
  fi
  return 1
}

# tasks_publish_evidence <slug> <fr_tip_oid> <default_branch> <remote_mode>
#   stdout: in-progress | needs-verify | cleanup-pending
#
# 발행 증거 판정의 **단일 출처**다(spec D8 — merge 여부는 발행 완료의 증거가 아니다).
# `tasks_list.sh`(목록 표시) 와 `promote.sh`(재착수 판정 c → D8) 가 함께 쓴다. 두 곳에
# 각자 복제하면 "로컬 merge·tag 는 있고 push 는 안 된" 흔한 상태에서 한쪽은 "정리
# 대기", 다른 쪽은 "발행 확인 필요" 를 내고, 전자의 안내를 따라 지우면 push 되지 않은
# 작업이 소실된다(2026-09 final diff review I2).
tasks_publish_evidence() {
  local slug="$1" fr_tip="$2" default_branch="$3" remote_mode="$4"
  [[ -z "$default_branch" ]] && { printf 'in-progress\n'; return 0; }

  git merge-base --is-ancestor "$fr_tip" "refs/heads/${default_branch}" 2>/dev/null || {
    printf 'in-progress\n'; return 0
  }

  local tag tag_oid
  tag="$(git tag --list "fr/*/${slug}" 2>/dev/null | sort | tail -1)"
  if [[ -z "$tag" ]]; then
    printf 'needs-verify\n'; return 0
  fi
  tag_oid="$(git rev-parse --verify --quiet "refs/tags/${tag}^{commit}" 2>/dev/null)" || {
    printf 'needs-verify\n'; return 0
  }
  git merge-base --is-ancestor "$fr_tip" "$tag_oid" 2>/dev/null || {
    printf 'needs-verify\n'; return 0
  }

  if [[ "$remote_mode" == "remote" ]]; then
    git merge-base --is-ancestor "$tag_oid" "refs/remotes/origin/${default_branch}" 2>/dev/null || {
      printf 'needs-verify\n'; return 0
    }
    local ls remote_oid
    ls="$(git ls-remote --tags origin "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null)" || ls=""
    remote_oid="$(printf '%s\n' "$ls" | awk -v t="refs/tags/${tag}^{}" '$2==t{print $1; exit}')"
    if [[ -z "$remote_oid" ]]; then
      remote_oid="$(printf '%s\n' "$ls" | awk -v t="refs/tags/${tag}" '$2==t{print $1; exit}')"
    fi
    if [[ -z "$remote_oid" || "$remote_oid" != "$tag_oid" ]]; then
      printf 'needs-verify\n'; return 0
    fi
  fi

  printf 'cleanup-pending\n'
}

# tasks_path_occupied <path>
#   rc 0: 점유 — 내 계정 프로세스의 CWD 가 <path> 이거나 그 아래다.
#   rc 1: 비점유 — 내 계정 프로세스 전부의 CWD 를 읽었고 <path> 안에 있는 것이 없다.
#   rc 2: 판정불가 — lsof 없음 / 조회 실패 / 내 계정 프로세스의 CWD 를 읽지 못함.
#         사유는 전역 TASKS_OCCUPIED_REASON 에 남긴다(서브셸로 부르면 잃는다).
#
# 범위는 **내 계정(id -u) 프로세스까지**다(사용자 결정 2026-10-29). 다른 계정(root 포함)의
# 프로세스는 lsof 가 CWD 를 읽지 못하므로 범위 밖이다. 내 계정 프로세스인데 읽지 못한 것이
# 있으면 점유 여부를 보증할 수 없으므로 rc 2 다.
# 「읽지 못함」 대조는 실 uid 와 유효 uid 가 모두 내 계정인 프로세스만 센다(사용자 결정 2026-11-02).
# setuid 프로세스는 실 uid 가 나여도 유효 uid 가 다른 계정이라 lsof 가 CWD 를 읽지 못한다 — 실측
# 사례는 `login`, F5 VPN helper `svpn`(오래 살아 모든 정리를 막았다), `top`, `ps` 다(2026-11-02).
# 읽힌 CWD 가 대상 안이면 유효 uid 와 관계없이 점유다(아래 첫 대조가 거름보다 앞선다).
# 오판 범위: worktree 안에 CWD 를 둔 setuid 프로세스는 판정불가를 만들지 않으므로, 그 프로그램을
# 띄운 셸이 끝났거나 `cd` 로 대상 밖에 나갔으면 점유를 잡지 못한다.
# ps 는 BSD·procps 모두 `-U <uid>` 가 실 uid 선택이고 `-o uid` 가 유효 uid 다(macOS 의 `-u` 는 형식 옵션이다).
tasks_path_occupied() {
  TASKS_OCCUPIED_REASON=""
  local target uid
  target="$(cd "$1" 2>/dev/null && pwd -P)" || return 1   # 없는 경로는 누구의 CWD 도 아니다
  command -v lsof >/dev/null 2>&1 || { TASKS_OCCUPIED_REASON="lsof 없음"; return 2; }
  uid="$(id -u)"

  # 점유가 확인되면(rc 0) 읽지 못한 프로세스가 있어도 점유다. 비점유(rc 1)는 읽지 못한 프로세스가
  # 없을 때만 낸다. 재시도를 들인 사례인 `top -l 2`(2026-10-29 실측)는 setuid 라 이제 유효 uid 거름으로
  # 빠지지만, 그 밖의 일시적 읽기 불가에 대비해 읽기 불가가 남으면 TASKS_OCCUPIED_RETRY(기본 3)회까지
  # 1초 간격으로 다시 읽는다.
  local retry="${TASKS_OCCUPIED_RETRY:-3}" attempt=0 ps_out snap lsof_out lrc pid missed candidates line
  while :; do
    lsof_out=""; lrc=0
    # ps 실패나 빈 스냅샷(숫자 pid 행이 하나도 없음 — 빈 출력 포함)은 대조 근거가 사라진다는 뜻이다 — 비점유로 흘리지 않고 판정불가로 낸다.
    ps_out="$(ps -U "$uid" -o pid=,uid=,stat= 2>/dev/null)" || { TASKS_OCCUPIED_REASON="프로세스 목록 조회 실패"; return 2; }
    # 유효 uid 가 숫자가 아니면 거르지 않는다 — 대조에 남겨 읽지 못하면 판정불가가 되게 한다(fail-closed).
    snap="$(printf '%s\n' "$ps_out" | awk -v me="$uid" '
      $1 !~ /^[0-9]+$/ {next}
      $3 ~ /^Z/ {next}
      $2 ~ /^[0-9]+$/ && $2 != me {next}
      {print $1}')"
    [[ -n "$snap" ]] || { TASKS_OCCUPIED_REASON="프로세스 목록이 비어 있음"; return 2; }
    # -a 가 없으면 lsof 는 조건을 OR 로 묶어 내 계정의 모든 파일을 훑는다(실측 17초·5만 줄).
    lsof_out="$(lsof -a -u "$uid" -d cwd -Fpn 2>/dev/null)" || lrc=$?
    if [[ "$lrc" -ne 0 && -z "$lsof_out" ]]; then
      TASKS_OCCUPIED_REASON="조회 실패"; return 2
    fi

    while IFS= read -r line; do
      case "$line" in
        n"$target"|n"$target"/*) return 0 ;;
      esac
    done <<<"$lsof_out"

    # 권한 제한 대조 — 살아 있는 내 계정 pid 중 CWD 경로를 실제로 읽지 못한 것을 센다.
    #   lsof 출력에 `p<pid>` 가 있어도 뒤따르는 `n` 줄이 절대경로가 아니면(예: `n/proc/<pid>/cwd (readlink:
    #   Permission denied)` 같은 오류 설명) 읽은 것으로 치지 않는다 — 프로세스 식별과 경로 읽기는 별개다.
    #   pid 마다 grep 을 띄우면 프로세스가 수백 개일 때 수십 초가 걸린다 — awk 한 번으로 거른다.
    missed=0
    candidates="$(printf '%s\n' "$snap" | LSOF_OUT="$lsof_out" awk '
      BEGIN { n = split(ENVIRON["LSOF_OUT"], a, "\n"); cur = ""
        for (i = 1; i <= n; i++) {
          if (a[i] ~ /^p/) cur = substr(a[i], 2)
          else if (a[i] ~ /^n\// && a[i] !~ /\(.*\)$/ && cur != "") seen[cur] = 1
        } }
      $1 != "" && !($1 in seen) { print $1 }')"
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      kill -0 "$pid" 2>/dev/null || continue
      missed=$((missed + 1))
    done <<<"$candidates"
    [[ "$missed" -eq 0 ]] && return 1
    if [[ "$attempt" -ge "$retry" ]]; then
      TASKS_OCCUPIED_REASON="내 계정 프로세스 ${missed}건 CWD 읽기 불가"; return 2
    fi
    attempt=$((attempt + 1)); sleep 1
  done
}

tasks_lock_owner_info() {
  local shared lockdir ownerfile
  _tasks_shared_dir_fill || return 1; shared="$_TASKS_SD_VAL"
  lockdir="$shared/tasks.lock"
  ownerfile="$lockdir/owner"
  [[ -f "$ownerfile" ]] || return 1

  local pid cmd slug started
  pid="$(_tasks_lock_owner_field "$ownerfile" pid || true)"
  cmd="$(_tasks_lock_owner_field "$ownerfile" cmd || true)"
  slug="$(_tasks_lock_owner_field "$ownerfile" slug || true)"
  started="$(_tasks_lock_owner_field "$ownerfile" started-at || true)"
  printf 'pid=%s cmd=%s slug=%s started-at=%s\n' "$pid" "$cmd" "$slug" "$started"
}
