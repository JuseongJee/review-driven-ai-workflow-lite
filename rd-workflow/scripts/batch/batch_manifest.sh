#!/usr/bin/env bash
# batch_manifest.sh — /fr batch 오케스트레이터의 결정적 헬퍼 (SSOT).
# manifest JSON을 읽어 결정적 파생값만 반환합니다. 지능(선별·brainstorming 보강·의존 확정)은
# 살아있는 Claude 세션(fr/batch.md) 소관이며, 이 스크립트는 규칙의 단일 출처(SSOT)입니다.
# bash 3.2 호환: 연관배열(declare -A) 미사용. 인덱스 배열·문자열 누적·jq만 사용.
# 서브커맨드: validate | next | set-state | skip-dependents | summary | verify-done | resolve-slug
set -uo pipefail

die2() { echo "batch_manifest: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die2 "jq가 필요합니다 (batch는 jq 전제)"

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
  local tmp; tmp=$(mktemp)
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

case "$cmd" in
  validate) cmd_validate "$@" ;;
  set-state) cmd_set_state "$@" ;;
  next) cmd_next "$@" ;;
  skip-dependents) cmd_skip_dependents "$@" ;;
  summary) cmd_summary "$@" ;;
  verify-done) cmd_verify_done "$@" ;;
  resolve-slug) cmd_resolve_slug "$@" ;;
  *) die2 "알 수 없는 서브커맨드: '${cmd}' (validate|next|set-state|skip-dependents|summary|verify-done|resolve-slug)" ;;
esac
