#!/usr/bin/env bash
# batch_manifest.sh — /fr batch 오케스트레이터의 결정적 헬퍼 (SSOT).
# manifest JSON을 읽어 결정적 파생값만 반환합니다. 지능(선별·brainstorming 보강·의존 확정)은
# 살아있는 Claude 세션(fr/batch.md) 소관이며, 이 스크립트는 규칙의 단일 출처(SSOT)입니다.
# bash 3.2 호환: 연관배열(declare -A) 미사용. 인덱스 배열·문자열 누적·jq만 사용.
# 서브커맨드: validate | next | set-state | skip-dependents | restore-dependents | summary |
#             verify-done | archive-state | resolve-slug
set -uo pipefail

die2() { echo "batch_manifest: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die2 "jq가 필요합니다 (batch는 jq 전제)"
BM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"; shift || true

# --- validate: 스키마 + finish_policy + dangling + 순환(문자열 Kahn) ---
cmd_validate() {
  local mf="${1:-}"
  [ -n "$mf" ] && [ -f "$mf" ] || die2 "manifest 경로가 없거나 파일이 아닙니다: '${mf}'"
  jq -e . "$mf" >/dev/null 2>&1 || { echo "validate: JSON 파싱 실패" >&2; return 1; }
  jq -e '.finish_policy and .status and (.items|type=="array")' "$mf" >/dev/null 2>&1 \
    || { echo "validate: finish_policy/status/items 필드 누락" >&2; return 1; }
  jq -e '.finish_policy | .=="push" or .=="merge"' "$mf" >/dev/null 2>&1 \
    || { echo "validate: finish_policy 는 push|merge 여야 합니다 (none 미지원)" >&2; return 1; }
  jq -e '.items | all(.slug and (.order|type=="number") and (.depends_on|type=="array") and .state)' "$mf" >/dev/null 2>&1 \
    || { echo "validate: item 에 slug/order/depends_on/state 누락" >&2; return 1; }
  # status enum
  jq -e '.status | .=="preparing" or .=="running" or .=="paused" or .=="done"' "$mf" >/dev/null 2>&1 \
    || { echo "validate: status enum 위반(preparing|running|paused|done)" >&2; return 1; }
  # item state/feasibility enum + slug non-empty + order 정수 + depends_on 문자열
  jq -e '.items | all(
      ((.state) as $s | ["pending","running","completed","skipped","blocked"] | index($s)) != null
      and ((.feasibility) as $f | ["eligible","excluded"] | index($f)) != null
      and (.slug|type=="string") and (.slug|length>0)
      and (.order|type=="number") and ((.order|floor) == .order)
      and (.depends_on | all(type=="string"))
    )' "$mf" >/dev/null 2>&1 \
    || { echo "validate: item state/feasibility enum 또는 slug/order/depends_on 타입 위반" >&2; return 1; }
  # slug charset (인자 가드와 동일 규칙 — 정규식 삽입·word-splitting 안전)
  jq -e '.items | all(.slug | test("^[a-z0-9-]+$"))' "$mf" >/dev/null 2>&1 \
    || { echo "validate: slug charset 위반 (허용: ^[a-z0-9-]+$)" >&2; return 1; }
  # slug 중복 금지 (set-state 모호성 차단)
  local dup
  dup=$(jq -r '.items | map(.slug) | group_by(.) | map(select(length>1) | .[0]) | .[]' "$mf")
  [ -z "$dup" ] || { echo "validate: 중복 slug: ${dup}" >&2; return 1; }
  # 선별 제외 invariant: feasibility=excluded 는 state=skipped 여야 함(집계·보고 의미 고정)
  jq -e '.items | all(if .feasibility=="excluded" then .state=="skipped" else true end)' "$mf" >/dev/null 2>&1 \
    || { echo "validate: feasibility=excluded item 은 state=skipped 여야 합니다" >&2; return 1; }
  # dangling 의존: 존재하지 않는 slug 참조 금지
  local dangling
  dangling=$(jq -r '
    (.items|map(.slug)) as $known
    | .items[] | .slug as $s | .depends_on[]? as $d
    | select(($known|index($d))|not)
    | "\($s) -> \($d)"' "$mf")
  [ -z "$dangling" ] || { echo "validate: 존재하지 않는 slug 의존: ${dangling}" >&2; return 1; }
  # eligible 이 excluded 에 의존하면 dead-end (실행 불가능한 pending) → 거부
  local bad_excl
  bad_excl=$(jq -r '
    (.items|map(select(.feasibility=="excluded")|.slug)) as $excl
    | .items[] | select(.feasibility=="eligible") | .slug as $s
    | .depends_on[]? | select(. as $d | ($excl|index($d)) != null)
    | "\($s) -> \(.)"' "$mf")
  [ -z "$bad_excl" ] || { echo "validate: eligible 이 excluded 에 의존 (dead-end): ${bad_excl}" >&2; return 1; }
  # 순환 탐지: 문자열 Kahn. done_set 에 depends_on 이 모두 있으면 옮깁니다. 한 라운드도 못 옮기면 사이클입니다.
  local all_slugs remaining done_set="" progress=1
  all_slugs=$(jq -r '.items[].slug' "$mf")
  remaining="$all_slugs"
  while [ "$progress" -eq 1 ]; do
    progress=0
    local nr="" s
    for s in $remaining; do
      local deps ok=1 d
      deps=$(jq -r --arg s "$s" '.items[]|select(.slug==$s)|.depends_on[]?' "$mf")
      for d in $deps; do
        case " $done_set " in *" $d "*) ;; *) ok=0 ;; esac
      done
      if [ "$ok" -eq 1 ]; then
        done_set="$done_set $s"; progress=1
      else
        nr="$nr $s"
      fi
    done
    remaining="$nr"
  done
  if [ -n "$(echo "$remaining" | tr -d '[:space:]')" ]; then
    echo "validate: 순환 의존 감지 (해소 불가:${remaining})" >&2; return 1
  fi
  return 0
}

# --- set-state: 상태전이 SSOT. outcome/block_reason: 빈 인자(생략)=유지, '-'=클리어 ---
cmd_set_state() {
  local mf="${1:-}" slug="${2:-}" state="${3:-}" outcome="${4:-}" block="${5:-}"
  [ -n "$mf" ] && [ -f "$mf" ] || die2 "manifest 경로 오류: '${mf}'"
  [ -n "$slug" ] && [ -n "$state" ] || die2 "usage: set-state <manifest> <slug> <state> [outcome|-] [block_reason|-]"
  case "$state" in pending|running|completed|skipped|blocked) ;; *) die2 "잘못된 state: '${state}'" ;; esac
  # slug 존재 확인
  jq -e --arg s "$slug" '.items | any(.slug==$s)' "$mf" >/dev/null 2>&1 \
    || { echo "set-state: slug 없음: ${slug}" >&2; return 1; }
  local tmp
  tmp="$(mktemp)" || { echo "batch_manifest: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$tmp" && -f "$tmp" ]] || { echo "batch_manifest: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  jq --arg s "$slug" --arg st "$state" --arg o "$outcome" --arg b "$block" '
    .items |= map(if .slug==$s then
        .state=$st
        | (if $o=="-" then .outcome="" elif $o!="" then .outcome=$o else . end)
        | (if $b=="-" then .block_reason="" elif $b!="" then .block_reason=$b else . end)
      else . end)
  ' "$mf" > "$tmp" && mv "$tmp" "$mf" || { rm -f "$tmp"; echo "set-state: 갱신 실패" >&2; return 1; }
}

# --- next: running 재개 우선, 없으면 pending 로직. 빈값+pending 잔존 = dead-end(exit 3) ---
cmd_next() {
  local mf="${1:-}"
  [ -n "$mf" ] && [ -f "$mf" ] || die2 "manifest 경로 오류: '${mf}'"
  jq -e . "$mf" >/dev/null 2>&1 || die2 "manifest JSON 파싱 실패: '${mf}'"
  local out
  out=$(jq -r '
    (.items | map(select(.state=="running")) | sort_by(.order) | (.[0].slug // null)) as $running
    | if $running != null then $running
      else
        ((.items | map(select(.state=="completed") | .slug)) as $done
         | .items
         | map(select(.feasibility=="eligible" and .state=="pending"
                      and (.depends_on | all(. as $d | ($done|index($d)) != null))))
         | sort_by(.order) | (.[0].slug // ""))
      end
  ' "$mf")
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  # 빈값: 진짜 terminal vs dead-end 구분. pending/running 잔존이면 dead-end(exit 3).
  local leftover
  leftover=$(jq -r '[.items[] | select(.state=="pending" or .state=="running")] | length' "$mf")
  if [ "$leftover" -gt 0 ]; then
    echo "next: dead-end — 실행 가능한 대상 없음, pending/running ${leftover}건 잔존" >&2
    return 3
  fi
  return 0
}

# --- skip-dependents: 직·간접 의존자(pending) BFS. 연관배열 미사용. ---
cmd_skip_dependents() {
  local mf="${1:-}" root="${2:-}"
  [ -n "$mf" ] && [ -f "$mf" ] || die2 "manifest 경로 오류: '${mf}'"
  jq -e . "$mf" >/dev/null 2>&1 || die2 "manifest JSON 파싱 실패: '${mf}'"
  [ -n "$root" ] || die2 "blocked-slug 인자가 필요합니다"
  local pending_list; pending_list=" $(jq -r '.items[]|select(.state=="pending")|.slug' "$mf" | tr '\n' ' ') "
  local seen=" ${root} "
  local queue=("$root") n c children
  while [ ${#queue[@]} -gt 0 ]; do
    n="${queue[0]}"; queue=("${queue[@]:1}")
    # n 에 의존하는 자식(depends_on 에 n 포함)
    children=$(jq -r --arg n "$n" '.items[] | select(.depends_on | index($n)) | .slug' "$mf")
    for c in $children; do
      case "$seen" in
        *" ${c} "*) ;;
        *) seen="${seen}${c} "; queue+=("$c")
           case "$pending_list" in *" ${c} "*) echo "$c" ;; esac ;;
      esac
    done
  done
}

# --- restore-dependents: <slug> 회수 후 pending 으로 되돌릴 후속 산출 ---
# skip-dependents 의 대칭이다. 그쪽은 pending 상태만 산출하므로(pending_list 필터)
# skipped 를 되살리는 데 쓸 수 없다 — 실측으로 확인했다.
#
# 산출 조건: root 의 (전이) 후손이면서 state=skipped, feasibility=eligible, 그리고
#   직접 의존이 모두 completed·pending 이거나 이번 산출 집합에 포함될 것.
# 다른 blocked 선행이 남은 가지는 복원하지 않는다 — 성급히 되살리면 실행할 수 없는
# 항목이 큐에 들어간다. excluded 는 손대지 않는다 (선별 제외 invariant).
# root 와 무관한 가지도 건드리지 않는다 — 이번 회수의 결과만 되돌린다.
cmd_restore_dependents() {
  local mf="${1:-}" root="${2:-}"
  [ -n "$mf" ] && [ -f "$mf" ] || die2 "manifest 경로 오류: '${mf}'"
  jq -e . "$mf" >/dev/null 2>&1 || die2 "manifest JSON 파싱 실패: '${mf}'"
  [ -n "$root" ] || die2 "회수된 slug 인자가 필요합니다"

  # 1) root 의 후손(전이)을 모은다 — skip-dependents 와 같은 BFS.
  local seen=" ${root} " queue=("$root") n c children desc=" "
  while [ ${#queue[@]} -gt 0 ]; do
    n="${queue[0]}"; queue=("${queue[@]:1}")
    children=$(jq -r --arg n "$n" '.items[] | select(.depends_on | index($n)) | .slug' "$mf")
    for c in $children; do
      case "$seen" in *" ${c} "*) continue ;; esac
      seen="${seen}${c} "; queue+=("$c"); desc="${desc}${c} "
    done
  done

  # 2) 후손 중 복원 가능한 것을 고정점까지 산출한다
  #    (의존이 이번 집합에 들어가면서 다음 항목이 복원 가능해지므로 반복한다).
  local emitted=" ${root} " progressed=1 deps d okdep st
  while [ "$progressed" = "1" ]; do
    progressed=0
    for c in $desc; do
      case "$emitted" in *" ${c} "*) continue ;; esac
      st=$(jq -r --arg s "$c" '(.items[]|select(.slug==$s)|.state) // ""' "$mf")
      [ "$st" = "skipped" ] || continue
      [ "$(jq -r --arg s "$c" '(.items[]|select(.slug==$s)|.feasibility) // ""' "$mf")" = "eligible" ] || continue
      deps=$(jq -r --arg s "$c" '.items[]|select(.slug==$s)|.depends_on[]?' "$mf")
      okdep=1
      for d in $deps; do
        case "$emitted" in *" ${d} "*) continue ;; esac
        st=$(jq -r --arg s "$d" '(.items[]|select(.slug==$s)|.state) // "missing"' "$mf")
        case "$st" in completed|pending) ;; *) okdep=0 ;; esac
      done
      if [ "$okdep" = "1" ]; then emitted="${emitted}${c} "; echo "$c"; progressed=1; fi
    done
  done
}

# --- summary ---
cmd_summary() {
  local mf="${1:-}"
  [ -n "$mf" ] && [ -f "$mf" ] || die2 "manifest 경로 오류: '${mf}'"
  jq -e . "$mf" >/dev/null 2>&1 || die2 "manifest JSON 파싱 실패: '${mf}'"
  jq -r '
    .items as $i
    | "completed=\(($i|map(select(.state=="completed"))|length)) " +
      "skipped=\(($i|map(select(.state=="skipped" and .feasibility=="eligible"))|length)) " +
      "blocked=\(($i|map(select(.state=="blocked"))|length)) " +
      "excluded=\(($i|map(select(.feasibility=="excluded"))|length)) " +
      "pending=\(($i|map(select(.state=="pending"))|length)) " +
      "running=\(($i|map(select(.state=="running"))|length))"
  ' "$mf"
}

# --- verify-done: FR 완료 ground truth (exit code 무관 사실 검증) ---
cmd_verify_done() {
  local slug="${1:-}"
  [ -n "$slug" ] || die2 "slug 인자가 필요합니다"
  [[ "$slug" =~ ^[a-z0-9-]+$ ]] || die2 "비정규 slug: '${slug}' (허용: ^[a-z0-9-]+$)"
  local items_dir="${RD_BATCH_ITEMS_DIR:-rd-workflow-workspace/backlog/items}"
  local arch_dir="${RD_BATCH_ARCHIVE_DIR:-rd-workflow-workspace/backlog/request-archive}"
  local f base fr_file=""
  for f in "$items_dir"/*-"$slug".md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-${slug}\.md$ ]] && { fr_file="$f"; break; }
  done
  [ -n "$fr_file" ] || { echo "verify-done: items 파일 없음: ${slug}" >&2; return 1; }
  local status
  status="$(awk '/^- status:/{gsub(/^- status:[[:space:]]*/,"");print;exit}' "$fr_file")"
  [ "$status" = "done" ] || { echo "verify-done: status=${status} (≠done): ${slug}" >&2; return 1; }
  for f in "$arch_dir"/*-"$slug".md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-${slug}\.md$ ]] && return 0
  done
  echo "verify-done: archive 파일 없음: ${slug}" >&2; return 1
}

# --- resolve-slug: items 에서 <slug> 를 정확히 1개로 resolve (오타/미존재 착수 전 차단) ---
cmd_resolve_slug() {
  local slug="${1:-}"
  [ -n "$slug" ] || die2 "slug 인자가 필요합니다"
  [[ "$slug" =~ ^[a-z0-9-]+$ ]] || die2 "비정규 slug: '${slug}' (허용: ^[a-z0-9-]+$)"
  local items_dir="${RD_BATCH_ITEMS_DIR:-rd-workflow-workspace/backlog/items}"
  local f base matches=0 found=""
  for f in "$items_dir"/*-"$slug".md; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-${slug}\.md$ ]] && { matches=$((matches+1)); found="$f"; }
  done
  if [ "$matches" -eq 1 ]; then printf '%s\n' "$found"; return 0; fi
  if [ "$matches" -eq 0 ]; then echo "resolve-slug: items 미존재: ${slug}" >&2; return 1; fi
  echo "resolve-slug: 복수 매칭(${matches}건): ${slug}" >&2; return 1
}

# --- archive-state: slug 의 archive 발행 완료 상태 판정 ---
# verify-done 은 workspace 사실만 본다 (items status=done + request-archive 파일).
# archive content commit 은 merge **이전에** fr 브랜치에서 끝나므로, merge 만 되고
# tag·push·브랜치 정리가 남은 상태에서도 verify-done 은 통과한다. 게다가 archive.sh 는
# "fr branch 부재 + 동일 slug tag 존재" 만으로 success exit 한다. 둘을 합치면 미push
# 상태가 완료로 통과한다 — 이 서브커맨드가 그 구멍을 git 사실로 막는다.
#
# **조회 실패 / 조회 성공+결과 없음 / 관계 불성립을 구별한다.** 뭉개면 조회 실패가
# "증거 부재" 로 바뀌어 잘못된 complete·incomplete-archive 가 나온다. hook 의 fail-open 을
# 완료 판정으로 확장하지 않는다는 원칙의 실질이 여기 있다.
_as_emit() {
  printf 'state=%s policy=%s missing=%s reason=%s\n' "$1" "$2" "${3:--}" "${4:--}"
  case "$1" in
    complete)           printf 'archive-state: 발행까지 완료 (policy=%s)\n' "$2" ;;
    incomplete-archive) printf 'archive-state: merge 는 됐으나 발행 미완 — 미충족: %s\n' "${3:--}" ;;
    not-archived)       printf 'archive-state: merge 근거 없음 — 일반 재시도 대상\n' ;;
    unknown)            printf 'archive-state: 판정 불가 (%s) — 상태를 보존하고 중단합니다. 완료로도 미병합으로도 취급하지 않습니다\n' "${4:--}" ;;
  esac
}

cmd_archive_state() {
  local mf="${1:-}" slug="${2:-}"
  [ -n "$mf" ] && [ -f "$mf" ] || die2 "manifest 경로가 없거나 파일이 아닙니다: '${mf}'"
  [ -n "$slug" ] || die2 "slug 인자가 필요합니다"
  case "$slug" in *[!a-z0-9-]*|'') die2 "비정규 slug: '${slug}' (허용: ^[a-z0-9-]+$)" ;; esac

  local policy
  policy="$(jq -r '.finish_policy // empty' "$mf" 2>/dev/null)"
  case "$policy" in push|merge) ;; *) die2 "finish_policy 가 push|merge 가 아닙니다: '${policy}'" ;; esac

  # SSOT 재사용 — 기본 브랜치 결정·remote 판정 규칙을 복제하지 않는다.
  # source 실패를 조용히 삼키지 않는다.
  # shellcheck source=/dev/null
  if ! . "${BM_DIR}/../lifecycle/_lifecycle_common.sh" 2>/dev/null \
     || ! command -v get_default_branch >/dev/null 2>&1; then
    _as_emit unknown "$policy" "-" "lifecycle-common-missing"; return 0
  fi

  local default_branch
  default_branch="$(get_default_branch 2>/dev/null)" || default_branch=""
  if [ -z "$default_branch" ]; then
    _as_emit unknown "$policy" "-" "no-default-branch"; return 0
  fi
  # 이름만으로는 부족하다 — get_default_branch 는 로컬 ref 실재를 확인하지 않는다.
  # ref 가 없으면 이후 log/ancestor 오류가 빈 merge 근거로 바뀌어 not-archived
  # (= 일반 재시도) 로 잘못 간다.
  if ! git rev-parse --verify --quiet "refs/heads/${default_branch}" >/dev/null 2>&1; then
    _as_emit unknown "$policy" "-" "default-ref-missing"; return 0
  fi

  local fr_ref="refs/heads/fr/${slug}"
  local merge_oid=""

  # --- merge 판정 (tag 유무와 무관해야 한다 — merge 직후 tag 전에 죽는 경우가 있다) ---
  merge_oid="$(git log "$default_branch" --grep="^merge: ${slug} " --format=%H -n1 2>/dev/null)"
  # **fr 브랜치가 기본 브랜치의 ancestor 라는 사실은 merge 의 증거가 아니다.**
  # promote 직후에는 두 tip 이 같아 ancestor 조건이 참이므로, 구현·archive 를 한 번도
  # 하지 않은 작업이 "merge 됐으나 발행 미완" 으로 오판정된다 (이후 기본 브랜치만
  # 전진해도 새 fr tip 은 여전히 ancestor 다). 그러면 재개 스윕이 착수 직후 중단된
  # 작업에 archive.sh 를 호출하고, 전제조건 거부 → 재판정도 미완 → blocked 로 떨어져
  # 정상적으로 이어갈 작업이 사용자 개입을 요구하는 실패로 바뀐다.
  # 커버리지 손실은 없다 — merge 를 만드는 주체는 archive.sh 뿐이고, 그것은 항상
  # `git merge --no-ff -m "merge: <slug> (autopilot 완료)"` 로 병합하므로 위 grep 이
  # 실제 merge 를 모두 잡는다 (인덱스 충돌 해결 경로의 재커밋도 같은 메시지다).
  if [ -z "$merge_oid" ]; then
    local anytag
    anytag="$(git tag --list "fr/*/${slug}" 2>/dev/null | head -1)"
    if [ -n "$anytag" ] && git merge-base --is-ancestor "$anytag" "$default_branch" 2>/dev/null; then
      merge_oid="$(git rev-list -n1 "$anytag" 2>/dev/null)"
    fi
  fi
  if [ -z "$merge_oid" ]; then
    _as_emit not-archived "$policy" "-" "-"; return 0
  fi

  # --- 증거 수집 ---
  local missing=""
  _as_miss() { if [ -z "$missing" ]; then missing="$1"; else missing="${missing},$1"; fi; }

  cmd_verify_done "$slug" >/dev/null 2>&1 || _as_miss "verify-done"

  # tag 선택 — 같은 slug 에 tag 가 여럿일 수 있다 (같은 slug 로 두 번째 작업 등).
  # 이번 merge 커밋을 조상으로 갖는 tag 중 생성 시각이 가장 늦은 것을 고른다.
  local tag="" any_tag="" t
  any_tag="$(git tag --list "fr/*/${slug}" 2>/dev/null | head -1)"
  for t in $(git tag --list "fr/*/${slug}" --sort=-creatordate 2>/dev/null); do
    if git merge-base --is-ancestor "$merge_oid" "$t" 2>/dev/null; then tag="$t"; break; fi
  done

  local publish_oid="" local_tag_oid=""
  if [ -z "$tag" ]; then
    if [ -z "$any_tag" ]; then _as_miss "tag"; else _as_miss "tag-points"; fi
  else
    publish_oid="$(git rev-list -n1 "$tag" 2>/dev/null)"
    local_tag_oid="$(git rev-parse "$tag" 2>/dev/null)"
  fi

  git rev-parse --verify --quiet "$fr_ref" >/dev/null 2>&1 && _as_miss "local-branch"

  if [ "$policy" = "push" ]; then
    local remote_mode
    remote_mode="$(detect_remote_mode 2>/dev/null || printf 'local-only')"
    if [ "$remote_mode" != "remote" ]; then
      _as_emit unknown "$policy" "${missing:--}" "remote-unreachable"; return 0
    fi

    # 원격 ref 를 한 번의 호출로 함께 읽는다 — 실패 지점이 하나로 모인다.
    local ls_out
    if ! ls_out="$(git ls-remote origin \
          "refs/heads/${default_branch}" \
          "refs/tags/${tag:-__none__}" \
          "refs/heads/fr/${slug}" 2>/dev/null)"; then
      _as_emit unknown "$policy" "${missing:--}" "remote-unreachable"; return 0
    fi

    local remote_head remote_tag remote_fr
    remote_head="$(printf '%s\n' "$ls_out" | awk -v r="refs/heads/${default_branch}" '$2==r{print $1; exit}')"
    remote_tag="$(printf '%s\n' "$ls_out"  | awk -v r="refs/tags/${tag}" '$2==r{print $1; exit}')"
    remote_fr="$(printf '%s\n' "$ls_out"   | awk -v r="refs/heads/fr/${slug}" '$2==r{print $1; exit}')"

    if [ -z "$remote_head" ]; then
      _as_miss "remote-branch"
    elif ! git cat-file -e "${remote_head}^{commit}" 2>/dev/null; then
      # ls-remote 가 알려준 tip 이 로컬 object DB 에 없다 — 다른 clone 이 전진시킨
      # 경우다. merge-base 는 "조상 아님(rc 1)" 이 아니라 object 부재 오류를 낸다.
      # 이를 미충족으로 처리하면 불필요한 archive 재실행과 blocked 전파가 일어난다.
      _as_emit unknown "$policy" "${missing:--}" "remote-object-missing"; return 0
    elif [ -z "$publish_oid" ]; then
      : # tag 가 없어 이미 tag 미충족으로 기록됨 — 중복 기록하지 않는다
    elif ! git merge-base --is-ancestor "$publish_oid" "$remote_head" 2>/dev/null; then
      _as_miss "remote-branch"
    fi

    if [ -n "$tag" ]; then
      if [ -z "$remote_tag" ]; then
        _as_miss "remote-tag"
      elif [ -z "$local_tag_oid" ] || [ "$local_tag_oid" != "$remote_tag" ]; then
        # 이름의 존재만으로는 같은 발행물임을 증명하지 못한다. archive.sh 는
        # <TAG_OID>:refs/tags/<tag> 로 tag object OID 를 명시해 push 한다.
        _as_miss "remote-tag-mismatch"
      fi
    fi

    [ -n "$remote_fr" ] && _as_miss "remote-fr-branch"
  fi

  if [ -z "$missing" ]; then
    _as_emit complete "$policy" "-" "-"
  else
    _as_emit incomplete-archive "$policy" "$missing" "-"
  fi
  return 0
}

case "$cmd" in
  validate) cmd_validate "$@" ;;
  set-state) cmd_set_state "$@" ;;
  next) cmd_next "$@" ;;
  skip-dependents) cmd_skip_dependents "$@" ;;
  restore-dependents) cmd_restore_dependents "$@" ;;
  summary) cmd_summary "$@" ;;
  verify-done) cmd_verify_done "$@" ;;
  archive-state) cmd_archive_state "$@" ;;
  resolve-slug) cmd_resolve_slug "$@" ;;
  *) die2 "알 수 없는 서브커맨드: '${cmd}' (validate|next|set-state|skip-dependents|restore-dependents|summary|verify-done|archive-state|resolve-slug)" ;;
esac
