#!/usr/bin/env bash
# _state_common.sh — task-state 단일 상태 파일 I/O (v2 Phase 2b). source 전용.
# 스키마·마이그레이션 계약: rd-workflow/docs/guides/task-state-guide.md
# 정책 준거: docs/v2/policy-spec.md — LC-05/06/14/18/19, GRD-01/02, SEC-13

TASK_STATE_PATH="${TASK_STATE_PATH:-${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/task-state}"
STATE_MIGRATION_BACKUP_DIR="${STATE_MIGRATION_BACKUP_DIR:-${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/migration-backup}"

# state_file_exists — task-state 파일 존재 여부 (return 0: 존재, 1: 없음)
state_file_exists() { [[ -f "$TASK_STATE_PATH" ]]; }

# state_read_field <key> — stdout에 값 출력 (파일/키 부재 시 빈 값 + return 0)
state_read_field() {
  local key="$1"
  [[ -f "$TASK_STATE_PATH" ]] || return 0
  awk -F'=' -v k="$key" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$TASK_STATE_PATH"
}

# state_init_defaults — 기본값으로 task-state 파일 생성 (덮어쓰기)
state_init_defaults() {
  mkdir -p "$(dirname "$TASK_STATE_PATH")"
  cat > "$TASK_STATE_PATH" <<'EOF'
schema=1
short-title=-
status=대기 중
fr-branch=null
worktree-path=null
source-fr=-
EOF
}

# state_write_fields <key=value>... — 나열된 키만 교체/추가, 나머지 줄 보존, tmp+mv 원자적
# 값에 개행 포함 시 return 1. 파일 부재 시 defaults 생성 후 적용.
state_write_fields() {
  local kv tmp
  # --- 사전 검증: key=value 형식 + 개행 금지 (LC-06) ---
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *) printf 'state_write_fields: key=value 형식이 아닙니다: %s\n' "$kv" >&2; return 1 ;;
    esac
    case "$kv" in
      *"
"*) printf 'state_write_fields: 값에 개행을 포함할 수 없습니다 (LC-06)\n' >&2; return 1 ;;
    esac
  done
  # --- 파일 없으면 defaults 생성 ---
  state_file_exists || state_init_defaults
  tmp="$(mktemp "$(dirname "$TASK_STATE_PATH")/.task-state.XXXXXX")" \
    || { printf 'state_write_fields: mktemp 실패\n' >&2; return 1; }
  # --- awk: 나열 키만 교체, 나머지 보존, 없는 키 추가 ---
  # 인자 처리: 임시 인덱스 파일 + export ENVIRON 경유 (BSD awk/Bash 3.2 호환)
  local idx_file
  idx_file="$(mktemp "$(dirname "$TASK_STATE_PATH")/.task-state-idx.XXXXXX")" \
    || { rm -f "$tmp"; printf 'state_write_fields: mktemp(idx) 실패\n' >&2; return 1; }
  for kv in "$@"; do printf '%s\n' "$kv" >> "$idx_file"; done
  export _SW_IDX="$idx_file"
  awk '
    # BEGIN: 인덱스 파일에서 key=value 읽기 (ENVIRON 경유 — BSD awk 호환)
    BEGIN {
      n = 0
      idx = ENVIRON["_SW_IDX"]
      while ((getline line < idx) > 0) {
        eq = index(line, "=")
        if (eq > 0) {
          k = substr(line, 1, eq - 1)
          v = substr(line, eq + 1)
          keys[++n] = k
          vals[k] = v
        }
      }
      close(idx)
    }
    # 본문: 기존 행 처리 — 대상 키면 교체, 아니면 그대로
    {
      eq = index($0, "=")
      k = (eq > 0 ? substr($0, 1, eq - 1) : "")
      if (k != "" && (k in vals)) {
        print k "=" vals[k]
        done[k] = 1
      } else {
        print
      }
    }
    # END: 미처리(신규) 키 추가
    END {
      for (i = 1; i <= n; i++) {
        k = keys[i]
        if (!(k in done)) print k "=" vals[k]
      }
    }
  ' "$TASK_STATE_PATH" > "$tmp"
  local rc=$?
  rm -f "$idx_file"
  unset _SW_IDX
  if [[ "$rc" != "0" ]]; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$TASK_STATE_PATH" || { rm -f "$tmp"; return 1; }
}

# ---------------------------------------------------------------------------
# source-fr 값 계약 헬퍼 (task-state-guide.md 'source-fr 계약'의 단일 구현)
# ---------------------------------------------------------------------------

# source_fr_validate <value> — canonical 쓰기 값 검증 (return 0: 유효, 1: 무효)
#   허용: "-" 또는 repo-relative backlog item path (rd-workflow-workspace/backlog/items/<파일>.md)
#   거부: 빈 값, 개행, 절대경로, ".." 세그먼트, items 직하가 아닌 경로, .md 외 확장자
#   legacy slug 는 쓰기 금지 (읽기 호환은 소비자 책임 — pre_commit_archive_gate.sh)
source_fr_validate() {
  local v="${1-}"
  [[ "$v" == "-" ]] && return 0
  [[ -z "$v" ]] && return 1
  case "$v" in
    *$'\n'*) return 1 ;;
    /*) return 1 ;;
    ../*|*/../*|*/..) return 1 ;;
  esac
  case "$v" in
    rd-workflow-workspace/backlog/items/*.md) ;;
    *) return 1 ;;
  esac
  local rest="${v#rd-workflow-workspace/backlog/items/}"
  [[ "$rest" == */* ]] && return 1
  return 0
}

# source_fr_from_request [request_file] — REQUEST.md '## Source FR' 첫 유효행 출력
#   백틱·양끝 공백 제거. 파일/섹션 부재·값 '-'·빈 값이면 빈 출력.
#   항상 return 0 (set -e 호출부의 명령 치환 안전 — fail-open)
source_fr_from_request() {
  local f="${1:-${project_root:-$PWD}/REQUEST.md}"
  [[ -f "$f" ]] || return 0
  local v
  v="$(awk '
    /^## Source FR/ { in_s = 1; next }
    in_s && /^## / { exit }
    in_s { gsub(/`/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) { print; exit } }
  ' "$f")"
  if [[ -n "$v" && "$v" != "-" ]]; then
    printf '%s\n' "$v"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 마이그레이션 보조 함수 (state_ensure 전용 — _state_common.sh 내부)
# ---------------------------------------------------------------------------

# _state_legacy_section <section-name> — CURRENT_TASK.md 산문 섹션 첫 값 추출
_state_legacy_section() {
  local file="${project_root:-$PWD}/CURRENT_TASK.md"
  [[ -f "$file" ]] || return 0
  awk -v target="## $1" '
    $0 == target { in_s = 1; next }
    in_s && /^## / { exit }
    in_s { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) { print; exit } }
  ' "$file"
}

# canonical 8종 집합 (LC-19) — _state_common.sh 독자 정의 (guard_common.sh에 의존하지 않음)
# 파이프(|) 구분 문자열. _state_status_canonical() 의 단일 진실 출처.
STATE_CANONICAL_STATUSES="대기 중|REQUEST review 대기|spec/plan 작성 중|spec/plan review 대기|구현 중|검증 중|diff review 대기|완료"

# _state_status_canonical <status> — return 0: canonical, 1: 비canonical
# STATE_CANONICAL_STATUSES 변수를 단일 출처로 사용 (Bash 3.2 호환: IFS 분리 루프)
_state_status_canonical() {
  local s="$1" item
  local saved_IFS="$IFS"
  IFS='|'
  # shellcheck disable=SC2086
  set -- $STATE_CANONICAL_STATUSES
  IFS="$saved_IFS"
  for item in "$@"; do
    [[ "$s" == "$item" ]] && return 0
  done
  return 1
}

# state_ensure — task-state 존재하면 no-op(return 0).
# 부재 시: legacy(CURRENT_TASK.md + active-fr) 감지 → 백업 → 변환 생성 → active-fr 삭제.
# legacy Status 비canonical → 파일 만들지 않고 return 3 + 안내 stderr (SEC-13 fail-closed).
# CURRENT_TASK.md 부재(신규 프로젝트) → defaults 생성 return 0.
state_ensure() {
  # 이미 존재하면 no-op
  state_file_exists && return 0

  local ct="${project_root:-$PWD}/CURRENT_TASK.md"
  local legacy_meta="${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/active-fr"

  # CURRENT_TASK.md 없음 → 신규 프로젝트, defaults 생성
  if [[ ! -f "$ct" ]]; then
    state_init_defaults
    return 0
  fi

  # legacy Status 추출
  local st sh br wt
  st="$(_state_legacy_section "Status")"
  sh="$(_state_legacy_section "Short Title")"

  # legacy alias '실행 중' → canonical '구현 중' 으로 변환
  if [[ "$st" == "실행 중" ]]; then
    echo "경고: legacy Status '실행 중' 을 canonical '구현 중' 으로 변환합니다." >&2
    st="구현 중"
  fi

  # Status 비어있거나 비canonical → fail-closed (SEC-13)
  if [[ -z "$st" ]] || ! _state_status_canonical "$st"; then
    echo "task-state 마이그레이션 실패: CURRENT_TASK.md ## Status ('${st:-<없음>}') 가 canonical 8종이 아닙니다." >&2
    echo "CURRENT_TASK.md 의 Status 를 유효한 값으로 복구한 뒤 다시 실행하세요 (묵시적 초기화 금지 — SEC-13)." >&2
    return 3
  fi

  # active-fr 에서 fr-branch, worktree-path, short-title 추출
  br="null"; wt="null"
  if [[ -f "$legacy_meta" ]]; then
    local br_val; br_val="$(awk -F'=' '$1=="fr-branch"{sub(/^[^=]+=/,"");print;exit}' "$legacy_meta")"
    local wt_val; wt_val="$(awk -F'=' '$1=="worktree-path"{sub(/^[^=]+=/,"");print;exit}' "$legacy_meta")"
    local sh_val; sh_val="$(awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,"");print;exit}' "$legacy_meta")"
    [[ -n "$br_val" ]] && br="$br_val"
    [[ -n "$wt_val" ]] && wt="$wt_val"
    [[ -n "$sh_val" ]] && sh="$sh_val"
  fi

  # active-fr 부재 시 CURRENT_TASK.md ## Branch / Worktree fallback
  # fr/ 시작 값만 fr-branch로 채택; main/'-'/빈 값 → null 유지 (worktree-path는 null 유지 — 뷰 비신뢰성)
  if [[ "$br" == "null" ]]; then
    local bw_val; bw_val="$(_state_legacy_section "Branch / Worktree")"
    if [[ "$bw_val" == fr/* ]]; then
      br="$bw_val"
    fi
  fi

  # 백업 디렉토리 생성 + 원본 2개 백업
  local bdir; bdir="${STATE_MIGRATION_BACKUP_DIR}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bdir"
  cp "$ct" "$bdir/CURRENT_TASK.md"
  [[ -f "$legacy_meta" ]] && cp "$legacy_meta" "$bdir/active-fr"

  # task-state 생성 (defaults 후 덮어쓰기)
  state_init_defaults
  # state_write_fields 실패 시 fail-closed — 부분 상태 금지 (추가 지시: 쓰기 실패 처리)
  if ! state_write_fields \
    "short-title=${sh:--}" \
    "status=${st}" \
    "fr-branch=${br:-null}" \
    "worktree-path=${wt:-null}"; then
    echo "task-state 마이그레이션 실패: state_write_fields 쓰기 오류 — 생성된 파일을 제거하고 중단합니다." >&2
    rm -f "$TASK_STATE_PATH"
    return 3
  fi

  # active-fr 삭제 (흡수 완료)
  [[ -f "$legacy_meta" ]] && rm -f "$legacy_meta"

  echo "task-state 마이그레이션 완료: ${TASK_STATE_PATH} (백업: ${bdir})" >&2
  echo "tracked 변경(active-fr 삭제·task-state 생성)은 다음 정규 커밋에 포함하세요." >&2
  return 0
}
