#!/usr/bin/env bash
# _task_common.sh — task CLI 공용 함수. source 전용 (rd, test_task_cli.sh 사용).
# 정책 준거: docs/v2/policy-spec.md — SEC-01~07, SEC-13, GRD-01/02, LC-18/19/21

_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# project_root — cwd 비의존. 주입값 우선(테스트), 없으면 스크립트 위치 기준.
# 마커(rd-workflow-workspace/)가 없으면 조용히 다른 위치를 루트로 삼지 않고 멈춘다.
# readlink -f / realpath 를 쓰지 않는다 (macOS 부재·환경 차이). 그래서 실행 파일
# 자체가 심볼릭 링크면 마커를 잃고 이 검사에서 걸린다 — 의도된 비지원이다.
if [[ -z "${project_root:-}" ]]; then
  project_root="$(cd "${_TC_DIR}/../.." && pwd)"
fi
if [[ ! -d "${project_root}/rd-workflow-workspace" ]]; then
  echo "프로젝트 루트를 확정할 수 없습니다: '${project_root}' 에 rd-workflow-workspace/ 가 없습니다." >&2
  echo "  스크립트가 프로젝트 구조 밖에 놓여 있거나(사본·잘못된 배치), 실행 파일 자체가 심볼릭 링크일 수 있습니다." >&2
  echo "  확인: ls -d '${project_root}/rd-workflow-workspace'" >&2
  return 3 2>/dev/null || exit 3
fi
export project_root
# 파서 단일화: hooks 공통 파서 재사용 (제3 구현 금지 — spec §3)
source "${_TC_DIR}/hooks/_guard_common.sh"
# slug 정규화 단일 출처 — promote.sh 와 같은 규칙이어야 두 경로가 같은 값을 만든다
source "${_TC_DIR}/lifecycle/slug.sh"

TASK_CANONICAL_STATUSES=("대기 중" "REQUEST review 대기" "spec/plan 작성 중" "spec/plan review 대기" "구현 중" "검증 중" "diff review 대기" "완료")

task_status_canonical() {
  local s="$1" c
  for c in "${TASK_CANONICAL_STATUSES[@]}"; do [[ "$s" == "$c" ]] && return 0; done
  return 1
}

# LC-19 + SEC-13: Status 읽기의 CLI 계약 wrapper.
# canonical → stdout + return 0. legacy alias '실행 중' → stderr warning + stdout 원값 + return 0.
# 빈 값(섹션 부재/파싱 불가) 또는 비canonical → return 3 (상태 파일 파손 — fail-closed).
task_read_status() {
  local s
  s="$(get_task_status)"
  [[ -z "$s" ]] && return 3
  if [[ "$s" == "실행 중" ]]; then
    echo "경고: Status '실행 중' 은 legacy alias 입니다 (canonical: '구현 중')." >&2
    printf '%s\n' "$s"
    return 0
  fi
  task_status_canonical "$s" || return 3
  printf '%s\n' "$s"
}

# SEC-01: 조상 경로 component 단위 symlink 방어 (단일 구현 — 기존 6개 사본 대체)
assert_no_symlink_in_path() {
  local p="$1" d
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  d="$p"
  while [[ "$d" != "/" && -n "$d" ]]; do
    if [[ -L "$d" ]]; then
      echo "경고: path component ($d) 가 symlink 입니다. 보안상 중단합니다." >&2
      return 1
    fi
    d="$(dirname "$d")"
  done
  return 0
}

# LC-19/21: 상태 전이표 — 단일 출처 (spec §5). 모든 상태→'대기 중'은 중단/rollback 경로(LC-14).
# '구현 중→spec/plan 작성 중'은 autopilot 모드 B→A 중간 승격 경로 (autopilot SKILL.md "실행 모드" 참조).
task_transition_allowed() {
  local from="$1" to="$2"
  [[ "$to" == "대기 중" ]] && return 0
  case "${from}→${to}" in
    "대기 중→REQUEST review 대기"|"대기 중→구현 중"|\
    "REQUEST review 대기→spec/plan 작성 중"|\
    "spec/plan 작성 중→spec/plan review 대기"|\
    "spec/plan review 대기→spec/plan 작성 중"|"spec/plan review 대기→구현 중"|\
    "구현 중→spec/plan 작성 중"|\
    "구현 중→검증 중"|"검증 중→구현 중"|"검증 중→diff review 대기"|\
    "diff review 대기→구현 중"|"diff review 대기→완료") return 0 ;;
  esac
  return 1
}

task_set_status() {
  local to="$1" force="${2:-0}" from rc=0
  if ! task_status_canonical "$to"; then
    echo "허용되지 않은 Status 값: ${to} (canonical 8종만 허용 — LC-19)" >&2
    return 4
  fi
  from="$(task_read_status)" || {
    echo "CURRENT_TASK.md ## Status 파싱 불가 또는 비canonical 값 (상태 파일 파손)" >&2
    return 3
  }
  # legacy alias '실행 중' 은 전이 판정에서 '구현 중' 으로 간주 (파일에는 기록하지 않음)
  [[ "$from" == "실행 중" ]] && from="구현 중"
  if [[ "$from" != "$to" ]] && ! task_transition_allowed "$from" "$to"; then
    if [[ "$force" == "1" ]]; then
      echo "경고: 전이표 외 전이(${from} → ${to})를 --force로 수행합니다." >&2
    else
      echo "전이표 위반: ${from} → ${to} (--force로 우회 가능)" >&2
      return 4
    fi
  fi
  # 미러 섹션 부재를 **권위 쓰기 전에** 잡는다 (final diff review Finding 2).
  # `_task_section_write` 가 섹션 부재를 실패로 바꾼 뒤부터, 뒤에서 잡으면 task-state 는
  # 새 값이고 미러는 그대로인 부분 갱신이 남는다. `|| rc=$?` 는 코드를 보존할 뿐
  # 선행 쓰기를 되돌리지 않는다.
  # 이 검사가 `task_read_status` 로 대체되지 않는 이유: `get_task_status` 는 task-state 가
  # 있으면 그것만 읽으므로 미러의 `## Status` 부재를 보지 못한다.
  if ! _task_section_exists "Status"; then
    echo "set-status: CURRENT_TASK.md 에 '## Status' 섹션이 없어 중단합니다 (상태 변경 없음)." >&2
    echo "  미러가 baseline 형식이 아닙니다. 확인: grep -n '^## ' '${project_root}/CURRENT_TASK.md'" >&2
    return 3
  fi
  # task-state 갱신 (권위) + CURRENT_TASK.md 뷰 미러링 (결정 3: LC-18 3-way 계약 유지)
  if state_file_exists; then
    state_write_fields "status=${to}" || return 3
  fi
  _task_section_write "Status" "$to" || rc=$?
  return "$rc"
}

# GRD-01/02 + SEC-13: Short Title 3-way + Status guard 통합 판정 (기존 4개 산문 변형 대체)
# stdout: decision=... / message=...  return: 0 진행, 2 차단
# v2 2b: Short Title 읽기는 get_current_short_title(task-state 우선), 쓰기는 task-state + 뷰 미러
task_guard_decide() {
  local cand="$1" mode="$2" src="${3:-}" cur status file="${project_root}/CURRENT_TASK.md"
  # promote 모드 write/rebind 시 기록할 source-fr — 인자 없으면 '-' 리셋 (stale 차단).
  # REQUEST.md 추론을 여기 두지 않는 이유: guard 시점의 REQUEST.md 는 새 작업용으로
  # 작성 전(빈 템플릿 또는 이전 작업 잔재)이라 추론값이 '-' 또는 오염값이다.
  # 실제 FR path 추론·기록은 promote.sh 책임 (change-spec §2 접근 A).
  local src_val="${src:--}"

  # Short Title 읽기 — task-state 우선, fallback: CURRENT_TASK.md 산문
  if state_file_exists; then
    cur="$(state_read_field "short-title")"
  else
    # task-state 부재 시 CURRENT_TASK.md 산문 파싱 (마이그레이션 전 호환)
    if ! grep -q '^## Short Title' "$file" 2>/dev/null; then
      if [[ "$mode" == "fr-add" ]]; then
        echo "decision=proceed-readonly"
        echo "message=CURRENT_TASK.md에 ## Short Title 섹션이 없습니다. 갱신 없이 진행합니다."
        return 0
      fi
      printf '## Short Title\n-\n\n' >> "$file"   # intake/promote: 부재 = write 대상 (small-task 현행 의미)
    fi
    cur="$(_extract_task_section "Short Title")"
  fi

  # fr-add + ## Short Title 섹션 부재(task-state 없고 뷰 섹션도 없음) → proceed-readonly
  if [[ -z "$cur" && "$mode" == "fr-add" && ! state_file_exists ]]; then
    echo "decision=proceed-readonly"
    echo "message=CURRENT_TASK.md에 ## Short Title 섹션이 없습니다. 갱신 없이 진행합니다."
    return 0
  fi

  if [[ -z "$cur" || "$cur" == "-" ]]; then
    # fr-add + task-state 존재 + short-title 키 부재/빈 값(손상): write 금지 — proceed-readonly (GRD-02)
    # "-"(sentinel)은 정상 상태 → write 허용. ""(키 부재·빈 값)만 손상으로 간주.
    if [[ "$mode" == "fr-add" ]] && state_file_exists && [[ -z "$cur" ]]; then
      echo "decision=proceed-readonly"
      echo "message=task-state의 short-title이 비어있습니다(손상 가능). 갱신 없이 진행합니다."
      return 0
    fi
    # Short Title 쓰기: task-state + 뷰 미러 (결정 3 LC-18)
    if state_file_exists; then
      if [[ "$mode" == "promote" ]]; then
        state_write_fields "short-title=${cand}" "source-fr=${src_val}"
      else
        state_write_fields "short-title=${cand}"
      fi
    fi
    # 뷰에 ## Short Title 섹션이 없으면 append (기존 동작 유지)
    if ! grep -q '^## Short Title' "$file" 2>/dev/null; then
      printf '## Short Title\n-\n\n' >> "$file"
    fi
    _task_section_write "Short Title" "$cand"
    # promote 모드는 source-fr 도 권위에 썼으므로 미러도 함께 맞춘다 (change spec D12-3).
    # 씨앗 값이 없으면 이후 모든 rerun 이 거짓 divergence 를 본다.
    [[ "$mode" == "promote" ]] && _task_source_fr_mirror_write "$src_val"
    echo "decision=write"
    if [[ "$mode" == "promote" ]]; then
      echo "message=Short Title을 ${cand} 로 기록했습니다 (source-fr=${src_val})."
    else
      echo "message=Short Title을 ${cand} 로 기록했습니다."
    fi
    return 0
  fi
  if [[ "$cur" == "$cand" ]]; then
    echo "decision=proceed-readonly"
    echo "message=동일 Short Title(${cand}) — 변경 없이 진행합니다."
    return 0
  fi
  if [[ "$mode" == "fr-add" ]]; then
    echo "decision=proceed-readonly"
    echo "message=진행 중 작업(${cur})이 있어 Short Title을 변경하지 않고 진행합니다."
    return 0
  fi
  status="$(task_read_status 2>/dev/null)" || {
    echo "decision=block-parse"
    echo "message=## Status 가 없거나 파싱 불가/비canonical 값입니다. 유효한 Status 를 설정한 뒤 다시 진입하세요. (보수적 차단 — SEC-13)"
    return 2
  }
  [[ "$status" == "실행 중" ]] && status="구현 중"
  if [[ "$status" == "대기 중" ]]; then
    # Short Title 쓰기: task-state + 뷰 미러 (결정 3 LC-18)
    if state_file_exists; then
      if [[ "$mode" == "promote" ]]; then
        state_write_fields "short-title=${cand}" "source-fr=${src_val}"
      else
        state_write_fields "short-title=${cand}"
      fi
    fi
    # write 경로와 같은 append 를 둔다 — 없으면 task-state 만 갱신되고 미러는 빠진
    # partial state 가 남는다 (`_task_section_write` 가 섹션 부재를 실패로 바꿨으므로).
    if ! grep -q '^## Short Title' "$file" 2>/dev/null; then
      printf '## Short Title\n-\n\n' >> "$file"
    fi
    _task_section_write "Short Title" "$cand"
    [[ "$mode" == "promote" ]] && _task_source_fr_mirror_write "$src_val"
    echo "decision=rebind"
    if [[ "$mode" == "promote" ]]; then
      echo "message=이전 Short Title (${cur}) 이 Status = 대기 중 인 stale 값이라 ${cand} 로 교체하고 진행합니다 (source-fr=${src_val})."
    else
      echo "message=이전 Short Title (${cur}) 이 Status = 대기 중 인 stale 값이라 ${cand} 로 교체하고 진행합니다."
    fi
    return 0
  fi
  echo "decision=block-active"
  echo "message=현재 진행 중인 작업 (${cur}) 이 archive 되지 않았습니다. ${cand} 을 진행하려면 먼저 현재 작업을 archive 한 뒤 다시 진입하세요."
  return 2
}

# SEC-03/04/05/06: raw-capture 생성 (기존 6개 heredoc 블록 대체).
# stdin: 본문(무가공 passthrough). 실패는 fail-open — 경고 후 return 0 (본 작업 차단 금지).
task_capture_write() {
  local stage="$1" title="$2" src="${3:-routed}"
  # project_root를 physical(non-symlink) path로 resolve — macOS /var→/private/var 등 시스템 symlink 제외
  local _proot
  _proot="$(realpath "$project_root" 2>/dev/null)" \
    || _proot="$(cd -P "$project_root" && pwd)" \
    || _proot="$project_root"
  local dir="${_proot}/rd-workflow-workspace/raw-captures"
  if ! assert_no_symlink_in_path "$dir"; then
    echo "경고: raw-capture 경로 검증 실패 — 캡처를 생략하고 작업은 계속합니다." >&2
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null || { echo "경고: 캡처 디렉토리 생성 실패 — 캡처 생략." >&2; return 0; }
  chmod 0700 "$dir"
  local base dest n=2
  base="${dir}/$(date +%F)-${stage}-${title}.md"
  dest="$base"
  while [[ -e "$dest" || -L "$dest" ]]; do dest="${base%.md}-${n}.md"; n=$((n+1)); done
  ( umask 077
    {
      printf -- '---\ndate: %s\nstage: %s\nshort-title: %s\nsource: %s\n---\n\n' \
        "$(date '+%Y-%m-%d %H:%M')" "$stage" "$title" "$src"
      cat
    } > "$dest"
  ) || { rm -f "$dest"; echo "경고: 캡처 파일 생성 실패 — 작업은 계속합니다." >&2; return 0; }
  printf '%s\n' "$dest"
}

# SEC-01/02/05: REQUEST.md collision-safe 백업 (기존 3개 블록 대체). 차단 시 return 2 (fail-closed).
task_backup_request() {
  local title="$1" orphan="${2:-0}"
  # project_root를 physical(non-symlink) path로 resolve — macOS /var→/private/var 등 시스템 symlink 제외
  local _proot
  _proot="$(realpath "$project_root" 2>/dev/null)" \
    || _proot="$(cd -P "$project_root" && pwd)" \
    || _proot="$project_root"
  local dir="${_proot}/rd-workflow-workspace/backlog/request-archive"
  local stamp; stamp="$(date '+%Y-%m-%d-%H%M')"
  local name="${stamp}-${title}.md"
  [[ "$orphan" == "1" ]] && name="${stamp}-orphan.md"
  # SEC-01/02: 원본 REQUEST.md 자체가 symlink 이면 차단 (source-file symlink 방어)
  if [[ -L "${_proot}/REQUEST.md" ]]; then
    echo "경고: REQUEST.md 가 symlink 입니다. 보안상 중단합니다." >&2
    return 2
  fi
  assert_no_symlink_in_path "$dir" || return 2
  mkdir -p "$dir"
  local base dest n
  base="${dir}/${name}"; dest="$base"; n=2
  while [[ -e "$dest" || -L "$dest" ]]; do dest="${base%.md}-${n}.md"; n=$((n+1)); done
  if [[ -L "$dest" ]]; then
    echo "경고: archive 대상 ($dest) 이 symlink 입니다. 보안상 중단합니다." >&2
    return 2
  fi
  cp "${_proot}/REQUEST.md" "$dest" && printf '%s\n' "$dest"
}

# SEC-07/17: stage 캡처를 raw-captures/archive/ 로 이동 (frontmatter exact match — 기존 3개 awk 블록 대체).
# stage 경계 책임은 호출부: REQUEST archive 는 request,spec,plan / '/fr archive' 는 fr 만 넘긴다.
task_archive_captures() {
  local stages="$1" title="$2"
  # project_root를 physical(non-symlink) path로 resolve — macOS /var→/private/var 등 시스템 symlink 제외
  local _proot
  _proot="$(realpath "$project_root" 2>/dev/null)" \
    || _proot="$(cd -P "$project_root" && pwd)" \
    || _proot="$project_root"
  local src="${_proot}/rd-workflow-workspace/raw-captures"
  local dst="${src}/archive"
  assert_no_symlink_in_path "$dst" || return 2
  mkdir -p "$dst"
  chmod 0700 "$src" "$dst"
  local stage f
  local IFS=','
  for stage in $stages; do
    find "$src" -maxdepth 1 -type f -name "*-${stage}-*.md" 2>/dev/null \
      | while IFS= read -r f; do
          if awk -v t="$title" -v s="$stage" '
              BEGIN{c=0; st=0; sg=0}
              /^---$/{c++; if(c==2)exit}
              c==1 && $0=="short-title: " t {st=1}
              c==1 && $0=="stage: " s {sg=1}
              END{exit !(st && sg)}
            ' "$f"; then
            mv "$f" "$dst/" && printf '%s\n' "$f"
          fi
        done
  done
}

# 섹션 값 재기록 — 해당 섹션의 첫 비어있지 않은 줄만 교체, 나머지 byte 보존.
# 섹션이 비어 있으면 다음 헤더 직전(또는 EOF)에 값 삽입.
# **섹션 헤더 자체가 없으면 return 1.** 종전에는 입력을 그대로 복사하고 0 으로 끝나서,
# 호출자가 "미러 갱신 성공" 을 받고도 미러는 계속 부재했다 (final diff review Finding 4).
# 헤더를 임의 위치에 새로 만들지는 않는다 — 미러의 섹션 순서는 baseline 계약이고,
# 없다는 것은 파일이 baseline 이 아니라는 신호이므로 사람이 볼 일이다.
_task_section_write() {
  local file="${project_root}/CURRENT_TASK.md" section="$1" value="$2" tmp
  if ! grep -q "^## ${section}\$" "$file" 2>/dev/null; then
    echo "CURRENT_TASK.md 에 '## ${section}' 섹션이 없습니다 — 미러를 갱신할 수 없습니다." >&2
    echo "  확인: grep -n '^## ' '$file'" >&2
    return 1
  fi
  tmp="$(mktemp)"
  awk -v target="## ${section}" -v val="$value" '
    $0 == target { print; in_s=1; replaced=0; next }
    in_s && /^## / { if (!replaced) { print val; replaced=1 } in_s=0; print; next }
    in_s && !replaced && NF { print val; replaced=1; next }
    { print }
    END { if (in_s && !replaced) print val }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# _task_section_exists <section> — 미러에 섹션 헤더가 있는지. 쓰기 전 선검사용.
# task-state 를 먼저 쓰고 미러 쓰기가 실패하면 partial state write 가 남으므로,
# 값 계약 검증과 같은 단계에서 확인한다.
_task_section_exists() {
  grep -q "^## ${1}\$" "${project_root}/CURRENT_TASK.md" 2>/dev/null
}

# _task_source_fr_mirror_write <value> — 미러의 '## Source FR' 갱신. 섹션이 없으면 append.
#
# `Status`·`Short Title` 은 섹션 부재를 hard error 로 다루는데(미러가 깨졌다는 뜻) 여기는
# append 한다. 이 섹션은 change spec D12 에서 신설됐으므로, 부재는 "깨졌다" 가 아니라
# **"그 결정 이전에 만들어진 미러"** 라는 다른 사실이다. 같은 hard error 로 다루면
# 진행 중인 기존 작업의 정상 흐름이 끊긴다 (D12-2).
_task_source_fr_mirror_write() {
  local v="${1-}" f="${project_root}/CURRENT_TASK.md"
  [[ -f "$f" ]] || return 0
  if _task_section_exists "Source FR"; then
    _task_section_write "Source FR" "$v"
    return
  fi
  printf '\n## Source FR\n%s\n' "$v" >> "$f" || {
    echo "set-source-fr: CURRENT_TASK.md 에 '## Source FR' 섹션을 추가하지 못했습니다." >&2
    return 1
  }
}

# task_set_source_fr <value> — 값 계약 검증 후 task-state + 미러 source-fr 갱신.
# 위반 return 1 (stderr 사유), 쓰기 실패 return 1. 검증 규칙: source_fr_validate (_state_common.sh).
#
# 미러를 함께 쓰는 이유는 표시 편의가 아니라 **대조 출처**다 (change spec D12).
# `source-fr` 만 미러에 없어서, 권위 파일이 사라진 뒤 index 에서 되살리면 이 필드가
# 승격 시점 값으로 돌아간 것을 아무도 판정할 수 없었다 — 실행은 성공하므로 유실이
# 드러나지 않고 archive 가 다른 FR 을 done 처리한다. 미러가 있으면 promote 가 divergence
# 를 보고 멈출 수 있다 (D12-4).
task_set_source_fr() {
  local v="${1-}"
  if ! source_fr_validate "$v"; then
    echo "set-source-fr: 값 계약 위반 — '-' 또는 rd-workflow-workspace/backlog/items/<파일>.md 만 허용 (절대경로/../개행/slug 거부): '${v}'" >&2
    return 1
  fi
  state_write_fields "source-fr=${v}" || return 1
  _task_source_fr_mirror_write "$v" || return 1
}

# task_set_title <slug> [force] — short-title 기록. sentinel '-' → 값 방향만 허용.
# return 0 성공(멱등 포함) / 1 값 계약 위반 / 2 다른 값 존재(force 없음) / 3 쓰기 실패
# 동일 값 재실행은 성공이지만 완전 no-op 이 아니다 — CURRENT_TASK.md 미러가 어긋나 있으면
# 복구한다. prepare_review_pipeline.sh 처럼 미러를 직접 파싱하는 소비처가 틀린 값을
# 계속 보는 것을 막기 위함이다 (change spec D3).
task_set_title() {
  local raw="${1-}" force="${2:-0}" slug cur
  if [[ -z "$raw" || "$raw" == "-" ]]; then
    echo "set-title: 빈 값과 '-' 는 허용되지 않습니다 (sentinel 은 archive 가 되돌립니다)." >&2
    return 1
  fi
  case "$raw" in
    *"
"*) echo "set-title: 값에 개행을 포함할 수 없습니다." >&2; return 1 ;;
  esac
  slug="$(normalize_slug "$raw")" || return 1
  cur="$(get_current_short_title)"
  if [[ -n "$cur" && "$cur" != "-" && "$cur" != "$slug" && "$force" != "1" ]]; then
    echo "set-title: 이미 다른 작업 이름이 있습니다 — 현재 값: '${cur}'" >&2
    echo "  작업 이름은 시작 시 1회 정하고 archive 까지 유지합니다." >&2
    echo "  정말 바꾸려면 --force 를 쓰세요 (복구 전용)." >&2
    return 2
  fi
  # 미러 섹션 부재를 **task-state 쓰기 전에** 잡는다. 뒤에서 잡으면 권위는 갱신되고
  # 미러만 안 된 partial state 가 남는다 (final diff review Finding 4).
  if ! _task_section_exists "Short Title"; then
    echo "set-title: CURRENT_TASK.md 에 '## Short Title' 섹션이 없어 중단합니다 (상태 변경 없음)." >&2
    echo "  미러가 baseline 형식이 아닙니다. 확인: grep -n '^## ' '${project_root}/CURRENT_TASK.md'" >&2
    return 3
  fi
  if state_file_exists; then
    state_write_fields "short-title=${slug}" || return 3
  fi
  # 값이 같아도 미러는 맞춘다 (drift 복구)
  _task_section_write "Short Title" "$slug" || return 3
  return 0
}
