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
tasks_shared_dir() {
  local cd_
  cd_="$(git -C "${project_root:-$PWD}" rev-parse --path-format=absolute --git-common-dir)" || return 1
  mkdir -p "$cd_/rd-workflow" || return 1
  printf '%s/rd-workflow\n' "$cd_"
}

tasks_index_path() { printf '%s/tasks.local\n' "$(tasks_shared_dir)"; }

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
  path="$(_tasks_index_ensure)" || return 1
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
  path="$(_tasks_index_ensure)" || return 1

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
  path="$(tasks_index_path)"
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

tasks_index_slugs() {
  local path
  path="$(tasks_index_path)"
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
  shared="$(tasks_shared_dir)" || return 2
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

# 자기 pid 가 소유자일 때만 지운다. 남의 락을 지우지 않는다.
tasks_lock_release() {
  local shared lockdir ownerfile owner_pid
  shared="$(tasks_shared_dir)" || return 1
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

tasks_lock_owner_info() {
  local shared lockdir ownerfile
  shared="$(tasks_shared_dir)" || return 1
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
