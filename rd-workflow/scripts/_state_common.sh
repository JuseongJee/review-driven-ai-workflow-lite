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
base-commit=null
review-session=null
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

# _sfr_validate_one <value> — 원소 하나의 canonical 형식 검증 (source_fr_validate 의
#   기존 단일 값 판정을 그대로 옮긴 것 — 동작 불변). '-'·빈 값은 이 함수의 책임이 아니다
#   (호출부인 source_fr_validate 가 상위에서 처리한다).
#   거부: 절대경로, ".." 세그먼트, items 직하가 아닌 경로, .md 외 확장자
#   legacy slug 는 쓰기 금지 (읽기 호환은 소비자 책임 — pre_commit_archive_gate.sh)
_sfr_validate_one() {
  local v="${1-}"
  [[ -z "$v" ]] && return 1
  case "$v" in
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

# source_fr_validate <value> — canonical 쓰기 값 검증 (return 0: 유효, 1: 무효)
#
# **단일 값 전용입니다 — 직렬화된 목록(`a|b`)을 통과시키지 않습니다.** 호출부 전부가
# raw 입력 검증(promote `--source-fr` 인자·`guard --source-fr` 인자·`set-source-fr`
# 입력·복구 안내의 한 줄)이므로, 여기서 `|` 목록을 허용하면 「raw 인자 안의 `|` 목록은
# 어디서도 불허」(change-spec §2.3) 가 무너진다. 저장값의 역직렬화는 source_fr_split 이
# 담당하고, 그 원소는 이미 canonical 이라 이 함수로 개별 검증한다.
#   허용: "-" 또는 repo-relative backlog item path (rd-workflow-workspace/backlog/items/<파일>.md).
#   거부: 빈 값, 개행, 절대경로, ".." 세그먼트, items 직하가 아닌 경로, .md 외 확장자,
#   그리고 **직렬화된 목록(`a|b`)** — 파일명에 '|' 가 든 단일 경로는 그 자체로 유효하다
#   (분리를 시도하지 않으므로 오분리도 없다).
source_fr_validate() {
  local v="${1-}"
  [[ "$v" == "-" ]] && return 0
  [[ -z "$v" ]] && return 1
  case "$v" in
    *$'\n'*) return 1 ;;
  esac
  _sfr_validate_one "$v"
}

# source_fr_request_missing [request_file] — REQUEST 파일 부재 여부.
# return 0: 파일이 없다 / 1: 있다.
# 파일 부재와 '파일 안의 값이 -' 는 다른 신호다 — 후자는 사용자의 명시적 "FR 없음"이고,
# 전자는 정상 흐름에서 발생하지 않는다(_ROOT_FILES/REQUEST.md 가 배포에 포함되고
# archive 가 초기 템플릿으로 되돌린다). change spec D8.
source_fr_request_missing() {
  local f="${1:-${project_root:-$PWD}/REQUEST.md}"
  [[ -f "$f" ]] && return 1
  return 0
}

# REQUEST.md 의 `## Risk Tier` 에서 기계 판독 줄 `- 최종 등급: <token>` 을 읽는다.
# 출력(항상 exit 0): light | standard | full | absent | malformed
#   absent    — 파일이 없거나 `## Risk Tier` 헤더가 없다 (옛 REQUEST → 호출자가 Execution Path 로 fallback)
#   malformed — 헤더는 있는데 판독 줄이 0개 또는 2개 이상(빈 값 줄 포함), 값이 비었거나 `-`·토큰 밖, 헤더가 2개 이상
# fallback 은 오직 absent 에만 허용한다. malformed 를 absent 로 흡수하면 옛 Execution Path=small-task 가
# 살아나 effort 가 조용히 하향된다 (REQUEST review Turn 008 F2). 토큰 집합은 WORKFLOW.md 등급표와 같다.
# 헤더 수·필드 수·값을 awk 한 번에서 센다 — awk 출력을 command substitution 으로 받아 줄을 세면
# trailing newline 과 빈 줄이 지워져 2필드가 1필드로 보인다 (spec/plan review Turn 002 F3).
risk_tier_from_request() {
  local f="${1:-}" out
  [[ -f "$f" ]] || { printf 'absent\n'; return 0; }
  out="$(awk '
    /^## Risk Tier[[:space:]]*$/ { h++; f=1; next }
    f && /^## / { f=0 }
    f && /^- 최종 등급:/ {
      n++; v=$0
      sub(/^- 최종 등급:[ \t]*/, "", v); sub(/[ \t]*<!--.*$/, "", v); sub(/[ \t]+$/, "", v)
      val=v
    }
    END {
      if (h == 0) { print "absent"; exit }
      if (h != 1 || n != 1) { print "malformed"; exit }
      if (val == "light" || val == "standard" || val == "full") print val; else print "malformed"
    }' "$f" 2>/dev/null)" || out=""
  # awk 실패·빈 출력·예상 밖 출력은 모두 malformed 로 정규화한다 — 호출자는 다섯 토큰만 본다.
  case "$out" in
    light|standard|full|absent|malformed) printf '%s\n' "$out" ;;
    *) printf 'malformed\n' ;;
  esac
  return 0
}

# Risk Tier → 리뷰 세션 `execution-path` wire 값 (small-task | other | unknown). 항상 exit 0.
#   standard → small-task (final diff review 가 유일한 게이트인 등급 — effort 하향 대상)
#   full / light → other
#   malformed → unknown + stderr 경고 (하향 미적용 = 보수적). absent 로 흡수하지 않는다.
#   absent → 종전 `## Execution Path` 판독: 정확히 `small-task` 단독일 때만 small-task,
#            existing-code-change|new-feature-or-large-task → other, 그 외(템플릿 기본값·빈 값·부재) → unknown.
#   그 밖의 값(계약 위반) → unknown + 경고. fallback 은 명시적 absent 에만 열어 fail-closed 를 지킨다.
review_execution_path_from_request() {
  local f="${1:-}" tier raw
  tier="$(risk_tier_from_request "$f")"
  case "$tier" in
    standard) printf 'small-task\n' ;;
    full|light) printf 'other\n' ;;
    malformed)
      echo "⚠️  REQUEST.md 의 '## Risk Tier' 를 판독할 수 없습니다 ('- 최종 등급: light|standard|full' 한 줄이어야 합니다)." >&2
      echo "    effort 하향을 적용하지 않고 execution-path=unknown 으로 기록합니다." >&2
      printf 'unknown\n' ;;
    absent)
      raw=""
      [[ -f "$f" ]] && raw="$(awk '
        /^## Execution Path/ { f=1; next }
        f && /^## / { exit }
        f && /^[^[:space:]]/ { sub(/[ \t]+$/, ""); print; exit }' "$f")"
      case "$raw" in
        small-task) printf 'small-task\n' ;;
        existing-code-change|new-feature-or-large-task) printf 'other\n' ;;
        *) printf 'unknown\n' ;;
      esac ;;
    *)
      echo "⚠️  Risk Tier 판독 결과가 계약 밖입니다 ('$tier'). effort 하향을 적용하지 않고 execution-path=unknown 으로 기록합니다." >&2
      printf 'unknown\n' ;;
  esac
  return 0
}

# source_fr_from_request [request_file] — REQUEST.md '## Source FR' 첫 유효행 출력
#   백틱·양끝 공백 제거. HTML 주석 행(<!-- ... -->)은 건너뛴다 — 템플릿이 형식 예시를
#   주석으로 담기 때문이다. 파일/섹션 부재·값 '-'·빈 값이면 빈 출력.
#   항상 return 0 (set -e 호출부의 명령 치환 안전 — fail-open)
source_fr_from_request() {
  local f="${1:-${project_root:-$PWD}/REQUEST.md}"
  [[ -f "$f" ]] || return 0
  local v
  v="$(awk '
    /^## Source FR/ { in_s = 1; next }
    in_s && /^## / { exit }
    in_s && incomment { if (/-->/) incomment = 0; next }
    in_s && /^[[:space:]]*<!--/ { if ($0 !~ /-->/) incomment = 1; next }
    in_s { gsub(/`/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (NF) { print; exit } }
  ' "$f")"
  if [[ -n "$v" && "$v" != "-" ]]; then
    printf '%s\n' "$v"
  fi
  return 0
}

# source_fr_from_request_list [request_file] — REQUEST.md '## Source FR' 절의
#   모든 유효행을 출력한다 (첫 행만 읽는 source_fr_from_request 와 달리 전체를 읽는다 —
#   그 함수의 동작은 바꾸지 않는다, change spec §2.3).
#   줄 단위 목록 표기(한 줄에 1건, '- ' 접두 허용, 주석 행 무시, 값 '-'·빈 줄 제외)이며,
#   줄 안의 '|' 는 분리하지 않는다 — raw 항목의 경계는 이 함수가 만드는 "한 줄" 이다.
#   항상 return 0 (fail-open, 파일/섹션 부재 시 빈 출력).
source_fr_from_request_list() {
  local f="${1:-${project_root:-$PWD}/REQUEST.md}"
  [[ -f "$f" ]] || return 0
  awk '
    /^## Source FR/ { in_s = 1; next }
    in_s && /^## / { exit }
    in_s && incomment { if (/-->/) incomment = 0; next }
    in_s && /^[[:space:]]*<!--/ { if ($0 !~ /-->/) incomment = 1; next }
    in_s {
      line = $0
      gsub(/`/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "" && line != "-") print line
    }
  ' "$f"
  return 0
}

# ---------------------------------------------------------------------------
# source-fr 복수 표현 — 직렬화·역직렬화·미러·복구 안내 (task-guard-source-fr-contract
# change spec §2.3·§2.3b·§2.4b). raw 항목의 경계는 "인자 하나" 또는 "REQUEST 의 한 줄"
# 뿐이며, 이 계층의 어떤 함수도 그 경계 안의 '|' 를 분리하지 않는다 (리뷰 F4 회귀 방지).
# 단계 분리: ① raw 항목별 정규화(source_fr_resolve, 기존/불변) → ② 정규화된 canonical
# 목록의 직렬화(source_fr_join)/역직렬화(source_fr_split, 저장 계층 전용).
# ---------------------------------------------------------------------------

# _sfr_list_contains <needle> <newline-list> — 목록 안에 정확히 일치하는 원소가
#   있는가. bash 3.2 호환(연관배열 없이) 집합 멤버십은 이 case 매칭으로 구현한다.
_sfr_list_contains() {
  local needle="${1-}" hay="${2-}"
  case $'\n'"${hay}"$'\n' in
    *$'\n'"${needle}"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# source_fr_resolve_list <raw-lines> [project_root]
#   개행 구분 입력의 각 줄을 raw 항목 하나로 source_fr_resolve 에 넘겨 정규화한다.
#   줄 안의 '|' 는 분리하지 않는다 (§2.3 — 괄호 레이블 안의 '|' 가 유효 입력이다).
#   빈 줄·'-'(값 없음)은 건너뛴다.
#   하나라도 실패하면 stdout 을 내지 않고 실패 항목을 전부 stderr 에 열거한 뒤 return 1
#   (첫 실패에서 멈추지 않는다 — 사람이 한 번에 고칠 수 있어야 한다).
#   성공 시 첫 등장 순서 보존 + 중복 축약된 개행 구분 canonical 목록.
source_fr_resolve_list() {
  local input="${1-}" root="${2:-.}"
  local line resolved rc seen="" fail_out="" any_fail=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$(_sfr_trim "$line")" ]] && continue
    resolved="$(source_fr_resolve "$line" "$root" 2>&1)"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      any_fail=1
      fail_out="${fail_out:+${fail_out}$'\n'}${resolved}"
      continue
    fi
    [[ -z "$resolved" ]] && continue
    _sfr_list_contains "$resolved" "$seen" && continue
    seen="${seen:+${seen}$'\n'}${resolved}"
  done <<< "$input"
  if [[ "$any_fail" -eq 1 ]]; then
    printf '%s\n' "$fail_out" >&2
    return 1
  fi
  [[ -n "$seen" ]] && printf '%s\n' "$seen"
  return 0
}

# source_fr_join <canonical-list> — 정규화된 canonical 목록(개행 구분, 이미
#   source_fr_resolve 를 거친 값이라고 가정)을 task-state 저장 형식(한 줄, '|' 구분)으로
#   직렬화한다. 저장 계층 전용 — raw 정규화는 이 함수의 책임이 아니다.
#   중복은 축약하고 첫 등장 순서를 보존한다(대표는 첫 원소). 결과가
#     - 0개면 '-' (값 없음)
#     - 1개면 그 값을 그대로 반환한다 ('|' 를 포함해도 거부하지 않는다 — 리뷰 F8.
#       무조건 거부는 파일명에 '|' 가 있는 기존 단일 값의 재설정·복구 경로를 막는다)
#     - 2개 이상이면 '|' 를 포함한 원소가 하나라도 있으면 거부한다(되읽을 수 없다).
source_fr_join() {
  local input="${1-}" line out="" count=0 has_pipe=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    _sfr_list_contains "$line" "$out" && continue
    out="${out:+${out}$'\n'}${line}"
    count=$((count + 1))
    case "$line" in *"|"*) has_pipe=1 ;; esac
  done <<< "$input"
  if [[ "$count" -eq 0 ]]; then
    printf -- '-\n'
    return 0
  fi
  if [[ "$count" -eq 1 ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  if [[ "$has_pipe" -eq 1 ]]; then
    echo "source_fr_join: 2개 이상을 묶을 때는 '|' 를 포함한 항목을 담을 수 없습니다 (되읽을 수 없습니다)." >&2
    return 1
  fi
  local joined="" first=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$first" -eq 1 ]]; then joined="$line"; first=0; else joined="${joined}|${line}"; fi
  done <<< "$out"
  printf '%s\n' "$joined"
  return 0
}

# source_fr_split <stored-value> [project_root] — task-state 저장값을 canonical
#   목록(개행 구분)으로 역직렬화한다. '-'·빈 값은 아무 것도 출력하지 않는다.
#   fast path: 저장값 전체가 「계약 형식을 통과하고 + 실존하는」 canonical path 면
#   원소 1개로 확정한 뒤에만 '|' 분리를 시도한다 — legacy 단일 값 호환. 이 순서가
#   없으면 파일명에 '|' 를 담은 canonical 경로가 두 항목으로 찢어진다 (§2.3).
source_fr_split() {
  local v="${1-}" root="${2:-.}"
  [[ -z "$v" || "$v" == "-" ]] && return 0
  if _sfr_validate_one "$v" && [[ -f "$root/$v" ]]; then
    printf '%s\n' "$v"
    return 0
  fi
  case "$v" in
    *"|"*)
      local saved_IFS="$IFS" part
      IFS='|'
      set -- $v
      IFS="$saved_IFS"
      for part in "$@"; do
        [[ -n "$part" ]] && printf '%s\n' "$part"
      done
      ;;
    *)
      printf '%s\n' "$v"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 미러 helper (change spec §2.3b) — promote.sh 의 자체 미러 경로와
# _task_source_fr_mirror_write(_task_common.sh) 양쪽이 이 셋만 쓴다. 표현이
# 갈리면(직렬화 형식이 사람이 보는 자리로 새거나, 순서 차이가 거짓 divergence 가
# 되거나) 복구 안내가 깨진다.
# ---------------------------------------------------------------------------

# source_fr_mirror_read <file> — CURRENT_TASK.md 류 미러 파일의 '## Source FR'
#   절 전체를 목록(개행 구분)으로 읽는다. 절 형식이 REQUEST.md 와 같으므로
#   source_fr_from_request_list 에 위임한다(중복 구현 금지).
# 미러의 허용 표기(`- ` 접두·앞뒤 공백)를 벗겨 canonical 목록으로 낸다. raw 추출
# helper(`source_fr_from_request_list`)는 REQUEST 해석의 항목 경계를 지키기 위해 접두를
# 남기므로, 그것을 그대로 집합 비교·복구 안내에 쓰면 권위 `…/a.md` 와 미러 `- …/a.md` 가
# 다른 값으로 읽혀 **정상 상태가 divergence 로 차단**된다 (final diff review F6).
# 실존 검사는 하지 않는다 — 비교·안내 경로에 새 실패 모드를 만들지 않기 위함이다.
source_fr_mirror_read() {
  local line trimmed out=""
  while IFS= read -r line; do
    trimmed="$(_sfr_trim "$line")"
    if [[ "$trimmed" == "- "* ]]; then trimmed="$(_sfr_trim "${trimmed#- }")"; fi
    [[ -z "$trimmed" ]] && continue
    out="${out:+${out}$'\n'}${trimmed}"
  done <<< "$(source_fr_from_request_list "${1-}")"
  printf '%s' "$out"
  [[ -n "$out" ]] && printf '\n'
  return 0
}

# source_fr_mirror_body <canonical-list> — 미러 섹션 본문으로 쓸 문자열을 만든다.
#   목록을 줄 단위로(1건당 1줄) 반환하고, 빈 목록이면 sentinel '-' 한 줄을 반환한다.
#   저장 형식('|' 구분)을 절대 노출하지 않는다 — 사람이 보는 자리다.
source_fr_mirror_body() {
  local input="${1-}" line out=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    out="${out:+${out}$'\n'}${line}"
  done <<< "$input"
  if [[ -z "$out" ]]; then
    printf -- '-\n'
  else
    printf '%s\n' "$out"
  fi
}

# source_fr_mirror_set_equal <list-a> <list-b> — 정규화된 집합 비교 (return 0: 동일).
#   순서·표기(직렬화 vs 목록) 차이는 동일 판정으로 흡수한다 — 표현이 다르다고
#   promote rerun 의 idempotent 비교가 거짓 divergence 로 실패하지 않게 한다.
source_fr_mirror_set_equal() {
  local a="${1-}" b="${2-}" sa sb
  sa="$(printf '%s\n' "$a" | sed '/^$/d' | sort -u)"
  sb="$(printf '%s\n' "$b" | sed '/^$/d' | sort -u)"
  [[ "$sa" == "$sb" ]]
}

# ---------------------------------------------------------------------------
# 복구 안내 문자열 생성 (change spec §2.4b, 리뷰 F7) — 명령별 인자 문법이
# 달라 두 helper 로 분리한다. 한 helper 가 겸하지 않는다. 둘 다 전부가 값
# 계약(source_fr_validate)을 통과할 때만 문자열을 내고, 하나라도 실패하면
# 빈 출력 + return 1 이다(부분 목록 금지 — 안내대로 복구한 사람이 나머지를 잃는다).
# ---------------------------------------------------------------------------

# source_fr_recovery_cmd_positional <canonical-list> — `rd task set-source-fr` 용.
#   현행이 위치 인자이므로(§2.4b) 셸 인용된 위치 인자 전체를 만든다
#   (예: rd task set-source-fr 'a.md' 'b.md'). 목록이 비면 reset 명령('-')을 만든다.
source_fr_recovery_cmd_positional() {
  local input="${1-}" line cmd="rd task set-source-fr" any=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    source_fr_validate "$line" || return 1
    cmd="${cmd} $(printf '%q' "$line")"
    any=1
  done <<< "$input"
  [[ "$any" -eq 0 ]] && cmd="${cmd} -"
  printf '%s\n' "$cmd"
  return 0
}

# source_fr_recovery_cmd_repeat_opt <base-command> <canonical-list> —
#   promote.sh --source-fr / rd task guard --source-fr 용. 현행이 옵션 반복
#   지정이므로(§2.4b) <base-command> 뒤에 '--source-fr <값>' 을 목록 개수만큼
#   반복한다 (예: promote.sh --size large --source-fr 'a.md' --source-fr 'b.md').
#   목록이 비면 실패한다 — 이 경로는 실제 FR 목록을 복구하는 자리이고, reset 은
#   source_fr_recovery_cmd_positional 의 몫이다.
source_fr_recovery_cmd_repeat_opt() {
  local base="${1-}" input="${2-}" line any=0
  local cmd="$base"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    source_fr_validate "$line" || return 1
    cmd="${cmd} --source-fr $(printf '%q' "$line")"
    any=1
  done <<< "$input"
  [[ "$any" -eq 0 ]] && return 1
  printf '%s\n' "$cmd"
  return 0
}

# source_fr_check_direct_arg <raw> [project_root] — **직접 인자 1개** 검증
#
# REQUEST 의 자유 표기 해석(`source_fr_resolve_list`)과 구분되는 경로다. CLI 옵션·위치
# 인자는 이미 canonical 을 요구하므로 레이블·slug 같은 서술 표기를 통과시키지 않고,
# 검증을 **인자 경계 그대로** 수행한다 — 값들을 개행 목록으로 합친 뒤 줄 단위로 보면
# **개행이 든 인자 하나가 두 항목으로 승인**된다 (final diff review F4).
#
# 실패 사유는 stderr 로 낸다. 호출부는 첫 실패에서 멈추지 말고 전부 열거한 뒤 아무것도
# 쓰지 않는다 (change-spec §2.4 전부-또는-전무).
# return 0 유효 ('-' 포함) / 1 무효
source_fr_check_direct_arg() {
  local v="${1-}" root="${2:-${project_root:-.}}"
  if [[ -z "$v" ]]; then
    echo "source-fr: 빈 값은 지정할 수 없습니다." >&2; return 1
  fi
  case "$v" in
    *"
"*) echo "source-fr: 인자 하나에 개행을 포함할 수 없습니다 (인자마다 따로 지정하세요): '${v}'" >&2; return 1 ;;
  esac
  [[ "$v" == "-" ]] && return 0
  if ! source_fr_validate "$v"; then
    echo "source-fr: 값 계약 위반 — '-' 또는 ${_SFR_ITEMS_PREFIX}/<파일>.md 만 허용: '${v}'" >&2
    return 1
  fi
  if [[ ! -f "${root}/${v}" ]]; then
    echo "source-fr: 파일이 존재하지 않습니다: '${v}'" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# source_fr_resolve — REQUEST 원문 표기를 canonical path 로 정규화
# ---------------------------------------------------------------------------
# 사용: source_fr_resolve <raw> [project_root]
#   stdout : canonical repo-relative path, 또는 빈 문자열(값 없음)
#   return : 0 = 성공 또는 값 없음 / 1 = 해석 실패
#   stderr : 실패 시 원문 값과 허용 형식
#
# 판정 순서 자체가 계약이다 (change-spec §3.3). 첫 매칭에서 확정하며, 특히
# 'YYYY-MM-DD slug'(공백 포함) 검사는 slug 문법 검사보다 앞에 와야 한다 —
# 순서를 바꾸면 그 표기가 공백 때문에 slug 문법에서 떨어진다.
#
# 괄호 계열에서 레이블(마지막 '(' 앞부분)의 문법은 제한하지 않는다. 결과의
# 정확성은 레이블이 아니라 target 쪽 검증(단계 2~4)이 보장하며, 레이블 문법을
# 고정하면 새 서술 변형마다 다시 실패한다 — 그것이 canonical-only 파서가
# 이력 48% 를 버린 원인이다. 다만 빈 레이블은 거부한다.
#
# project_root 는 실존 확인의 base 로만 쓰고, 출력은 언제나 repo-relative 다.
# bash 3.2 호환: 연관배열·mapfile·globstar·extglob 을 쓰지 않는다.

_SFR_ITEMS_PREFIX="rd-workflow-workspace/backlog/items"

# _sfr_trim <str> — 앞뒤 공백 제거 (외부 프로세스 없이)
_sfr_trim() {
  if [[ "${1-}" =~ ^[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' ""
  fi
}

# _sfr_reject <raw> <reason> — 해석 실패를 사람이 고칠 수 있는 형태로 알린다
_sfr_reject() {
  echo "source-fr: '${1}' 를 해석할 수 없습니다 — ${2}." >&2
  echo "  허용 형식: ${_SFR_ITEMS_PREFIX}/<파일>.md" >&2
  echo "  예: ${_SFR_ITEMS_PREFIX}/2026-08-12-example.md" >&2
}

source_fr_resolve() {
  local raw="${1-}" root="${2:-.}"
  local v label target rest cand slug hit count f fast

  # 단계 0 — 전처리: trim → 리스트 접두 1회 제거 → 재trim
  v="$(_sfr_trim "$raw")"
  if [[ "$v" == "- "* ]]; then v="$(_sfr_trim "${v#- }")"; fi
  if [[ -z "$v" || "$v" == "-" ]]; then printf ''; return 0; fi

  # 단계 0.5 — canonical / items 축약 fast path (괄호 해석보다 먼저)
  #   저장 계약은 basename 에 '(' 를 허용한다. 이 경로가 없으면
  #   items/2026-04-04-paren(x).md 처럼 유효하고 실존하는 canonical path 가
  #   괄호 표기로 오해석되어 거부된다.
  #   괄호 안 target 의 괄호는 지원하지 않는다 — 그런 파일은 canonical 직접 표기로 쓴다.
  fast=0
  case "$v" in
    "$_SFR_ITEMS_PREFIX"/*.md|items/*.md) fast=1 ;;
  esac

  # 단계 1 — 괄호 target 추출: 마지막 '(' 이후 ~ 그 뒤 첫 ')' 까지
  if [[ "$fast" -eq 1 ]]; then
    target="$v"
  elif [[ "$v" == *"("* ]]; then
    label="${v%(*}"            # 마지막 '(' 앞부분
    target="${v##*(}"
    rest="${target#*)}"
    target="${target%%)*}"
    # 레이블이 비면 거부한다. '(아무거나)' 를 입구로 열어 두지 않기 위함이다.
    if [[ -z "$(_sfr_trim "$label")" ]]; then
      _sfr_reject "$raw" "괄호 앞 레이블이 비어 있습니다"
      return 1
    fi
    # 꼬리에는 ')' 와 공백만 남아야 한다. 그 외가 남으면 뒤에 다른 내용이 붙은
    # 입력이므로 거부한다. 닫는 괄호가 아예 없는 깨진 링크도 여기서 걸린다.
    while [[ "$rest" == ")"* || "$rest" == [[:space:]]* ]]; do rest="${rest#?}"; done
    if [[ -n "$rest" ]]; then
      # 이 사유는 두 경우에 나온다 — 괄호 뒤에 설명이 붙은 표기, 그리고 파일명에
      # 괄호가 있는데 링크 표기로 감싼 경우. 둘 다 교정 방향이 같으므로 함께 안내한다.
      _sfr_reject "$raw" \
        "괄호 뒤에 해석할 수 없는 내용이 남습니다 (파일명에 괄호가 있으면 링크 표기 대신 경로를 직접 쓰세요)"
      return 1
    fi
  else
    target="$v"
  fi
  target="$(_sfr_trim "$target")"
  if [[ -z "$target" ]]; then
    _sfr_reject "$raw" "값이 비어 있습니다"
    return 1
  fi

  # 단계 2 — 분류 (첫 매칭 확정)
  cand=""; slug=""
  if [[ "$target" == "$_SFR_ITEMS_PREFIX"/* ]]; then
    cand="$target"
  elif [[ "$target" == items/* ]]; then
    cand="$_SFR_ITEMS_PREFIX/${target#items/}"
  elif [[ "$target" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([a-z0-9][a-z0-9-]*)$ ]]; then
    cand="$_SFR_ITEMS_PREFIX/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.md"
  elif [[ "$target" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    slug="$target"
  else
    _sfr_reject "$raw" "지원하지 않는 표기입니다"
    return 1
  fi

  # 단계 3 — slug glob 해석 (정확 일치 우선 → 유일 매칭)
  if [[ -n "$slug" ]]; then
    if [[ -f "$root/$_SFR_ITEMS_PREFIX/$slug.md" ]]; then
      cand="$_SFR_ITEMS_PREFIX/$slug.md"
    else
      count=0; hit=""
      # nullglob 을 쓰지 않는다 — 미매칭 시 glob 이 리터럴로 남지만 -f 에서 걸러진다.
      # 셸 옵션을 건드리지 않아 호출자 환경에 영향이 없다.
      for f in "$root/$_SFR_ITEMS_PREFIX"/*-"$slug".md; do
        [[ -f "$f" ]] || continue
        count=$((count + 1)); hit="$f"
      done
      if [[ "$count" -eq 1 ]]; then
        cand="$_SFR_ITEMS_PREFIX/${hit##*/}"
      elif [[ "$count" -gt 1 ]]; then
        _sfr_reject "$raw" "slug '$slug' 가 items 파일 ${count}건에 매칭됩니다 — 파일명을 직접 쓰세요"
        return 1
      else
        _sfr_reject "$raw" "slug '$slug' 에 해당하는 items 파일이 없습니다"
        return 1
      fi
    fi
  fi

  # 단계 4 — 최종 검증: 계약 형식 + 실존 일반 파일
  if ! source_fr_validate "$cand"; then
    _sfr_reject "$raw" "정규화 결과가 계약 형식이 아닙니다 ($cand)"
    return 1
  fi
  if [[ ! -f "$root/$cand" ]]; then
    _sfr_reject "$raw" "파일이 존재하지 않습니다 ($cand)"
    return 1
  fi

  printf '%s\n' "$cand"
  return 0
}

# ---------------------------------------------------------------------------
# 워크플로 기록 경로와 보호 트리 (change-spec §2)
# ---------------------------------------------------------------------------
# `RD_RECORD_PATHS` 는 archive 절차가 실제로 생성·이동하는 경로와 그 작업의 상태
# 파일입니다. 두 소비처 — 보호 트리 해시(§2.2) 와 기록 커밋 게이트(§4.2) — 가 **이 하나의
# 정의만** 씁니다. 목록을 다른 곳에 다시 적으면 한쪽만 고쳐져 "커밋은 되는데 발행에서
# 막히는" 상태가 생깁니다.
#
# 디렉터리 항목은 반드시 `/` 로 끝냅니다 — 경로 판정이 그 `/` 로 컴포넌트 경계를 지키며,
# 없으면 `rd-workflow-workspace-x/` 같은 유사 접두사를 기록 경로로 오판합니다.
#
# 이 목록에 항목을 더하는 것은 신뢰 경계를 넓히는 일입니다. `.lifecycle/` 을 통째로 넣지
# 않고 archive 절차가 실제로 쓰는 3개 항목으로 좁힌 이유가 그것입니다 — 넓은 동적
# 디렉터리를 제외하면 자동화의 입력이 되는 파일(설정·hook 입력·source 되는 조각)이
# 나중에 들어와 신뢰 경계가 조용히 넓어집니다. 목록은 change-spec §3.1 의 11개 항목(디렉터리 7,
# 파일 4)과 정확히 일치해야 하며, 바꾸려면 테스트 기대값(`hooks/test_pre_commit_archive_gate.sh` 의
# `record-paths 4b`)도 함께 고쳐야 합니다.
#
# `raw-captures/` 는 선행 spec(2026-09-05-1944 §2.1)이 「입력 원문」이라는 이유로
# **보호 대상에 남긴** 항목입니다. 2026-09-10 에 뒤집었습니다 — 같은 spec 이 세운 기준이
# 「archive 절차가 실제로 생성·이동하는 경로로 한정」인데, autopilot §6 3·6단계
# (`rd task archive-captures`, `/fr archive`)가 정확히 이 디렉터리를 이동시키기 때문입니다.
# 같은 성격의 `backlog/` 가 이미 제외돼 있는 것과도 어긋났습니다. 되돌리려면 그 절차부터
# 함께 고쳐야 합니다 — 목록만 되돌리면 캡처가 있는 모든 full 작업의 마감이 다시 막힙니다.
# `specs/`·`plans/`·`reports/tier-log.md` 는 그 결정 중 **뒤집지 않은** 항목이며 보호 대상으로
# 남습니다.
RD_RECORD_PATHS=(
  "rd-workflow-workspace/.lifecycle/task-state"
  "rd-workflow-workspace/.lifecycle/review-seals/"
  "rd-workflow-workspace/.lifecycle/review-skip-audit.log"
  "rd-workflow-workspace/backlog/"
  "rd-workflow-workspace/raw-captures/"
  "rd-workflow-workspace/reports/completions/"
  "rd-workflow-workspace/reports/reviews/"
  "rd-workflow-workspace/reports/autopilot/"
  "rd-workflow-workspace/handoffs/review_pipeline/"
  "REQUEST.md"
  "CURRENT_TASK.md"
)

# rd_repo_root — repo 최상위 경로를 stdout 에 출력합니다 (실패 시 nonzero).
# 하위 디렉터리에서 호출해도 같은 값이 나와야 하므로(§2.2 이식성) 호출 위치가 아니라
# project_root 를 기준으로 찾습니다.
rd_repo_root() {
  local root
  root="$(git -C "${project_root:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$root" ]] || return 1
  printf '%s\n' "$root"
}

# rd_resolve_commit_oid <ref> [repo_root] — 저장소 native full OID 출력, 커밋이 아니면 nonzero.
#
# **길이를 검사하지 않습니다.** 형식 검증은 이 명령의 성공 여부 하나로 합니다 — `{40}` 을
# 하드코딩하면 SHA-256 object-format 저장소를 이유 없이 배제합니다 (§3.2.1).
rd_resolve_commit_oid() {
  local ref="${1-}" root="${2-}" oid
  [[ -n "$ref" ]] || return 1
  if [[ -z "$root" ]]; then
    root="$(rd_repo_root)" || return 1
  fi
  oid="$(git -C "$root" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" || return 1
  [[ -n "$oid" ]] || return 1
  printf '%s\n' "$oid"
}

# rd_protected_tree_hash <commit-ish> — 기록 경로를 제외한 트리의 canonical 해시 (§2.2)
#
# **fail-closed 가 이 함수의 계약입니다.** repo root 탐색 / OID 확인 / `ls-tree` / 필터 /
# `hash-object` 중 어느 단계가 실패해도 nonzero 로 끝냅니다. `ls-tree` 실패를 흘려보내면
# `hash-object` 가 **빈 입력의 해시**를 정상 반환하고, 비교 양쪽이 모두 그 빈 해시가 되어
# 검증이 조용히 통과합니다. 해시 계산 실패는 "판정 불가" 이지 통과가 아닙니다.
#
# bash 3.2 라 `pipefail` 에 의존하지 않고 중간 산출을 임시 파일에 받아 각 단계의 종료
# 상태를 그 자리에서 확인합니다.
#
# **제외를 pathspec 이 아니라 필터로 하는 이유**: `git ls-tree` 는 `:(exclude)` 지시어를
# 지원하지 않습니다 (`fatal: 경로명세 지시어가 이 명령어에서 지원하지 않습니다: 'exclude'`).
# spec §2.2 의 예시 명령은 실제로는 실행되지 않으며, 그 실패가 곧 §2.2 가 경고한 "빈 해시
# 일치" 경로입니다. 그래서 트리 전체를 `-z`(NUL 구분) 로 받아 `RD_RECORD_PATHS` 로 걸러냅니다.
# 걸러내는 판정은 `rd_path_is_record` 한 곳이며(게이트와 같은 함수), 목록을 여기 다시 적지
# 않습니다.
#
# 이식성 계약은 그대로입니다 — `-z` 로 공백·탭·개행·비ASCII 파일명이 안전하고
# (`core.quotePath` 등 출력 설정에 무관), `-C <repo root>` 와 `--full-tree` 로 호출 위치가
# 결과에 영향을 주지 않습니다.
rd_protected_tree_hash() {
  local ref="${1-}" root oid raw filtered hash rc rec path bad=0
  if [[ -z "$ref" ]]; then
    echo "rd_protected_tree_hash: 대상 commit 이 지정되지 않았습니다 — 판정 불가." >&2
    return 1
  fi
  root="$(rd_repo_root)" || {
    echo "rd_protected_tree_hash: repo root 를 찾을 수 없습니다 — 판정 불가." >&2
    return 1
  }
  oid="$(rd_resolve_commit_oid "$ref" "$root")" || {
    echo "rd_protected_tree_hash: '${ref}' 를 commit 으로 해석할 수 없습니다 — 판정 불가." >&2
    return 1
  }
  raw="$(mktemp "${TMPDIR:-/tmp}/rd-tree-raw.XXXXXX")" || {
    echo "rd_protected_tree_hash: mktemp 실패 — 판정 불가." >&2
    return 1
  }
  filtered="$(mktemp "${TMPDIR:-/tmp}/rd-tree-flt.XXXXXX")" || {
    rm -f "$raw"
    echo "rd_protected_tree_hash: mktemp 실패 — 판정 불가." >&2
    return 1
  }
  git -C "$root" ls-tree -r -z --full-tree "$oid" > "$raw" 2>/dev/null
  rc=$?
  if [[ "$rc" != "0" ]]; then
    rm -f "$raw" "$filtered"
    echo "rd_protected_tree_hash: git ls-tree 실패 (exit ${rc}) — 판정 불가로 차단합니다." >&2
    return 1
  fi
  # 각 레코드는 `<mode> <type> <object>\t<path>` 이고 NUL 로 끝납니다. 탭이 없으면 형식이
  # 깨진 것이므로 통과가 아니라 판정 불가입니다.
  while IFS= read -r -d '' rec; do
    if [[ "$rec" != *$'\t'* ]]; then bad=1; break; fi
    path="${rec#*$'\t'}"
    rd_path_is_record "$path" && continue
    printf '%s\0' "$rec"
  done < "$raw" > "$filtered"
  rm -f "$raw"
  if [[ "$bad" != "0" ]]; then
    rm -f "$filtered"
    echo "rd_protected_tree_hash: ls-tree 출력 형식이 예상과 다릅니다 — 판정 불가로 차단합니다." >&2
    return 1
  fi
  hash="$(git -C "$root" hash-object --stdin < "$filtered" 2>/dev/null)"
  rc=$?
  rm -f "$filtered"
  if [[ "$rc" != "0" || -z "$hash" ]]; then
    echo "rd_protected_tree_hash: git hash-object 실패 — 판정 불가로 차단합니다." >&2
    return 1
  fi
  printf '%s\n' "$hash"
}

# rd_path_is_record <repo-relative path> — 경로가 기록 경로 안인가 (0: 안, 1: 밖)
#
# 디렉터리 항목은 `/` 로 끝나므로 접두 비교가 곧 컴포넌트 경계 비교입니다
# (`rd-workflow-workspace-x/...` 는 매칭되지 않습니다). 파일 항목은 정확히 일치해야 합니다.
rd_path_is_record() {
  local p="${1-}" item
  [[ -n "$p" ]] || return 1
  for item in "${RD_RECORD_PATHS[@]}"; do
    case "$item" in
      */) [[ "$p" == "$item"* ]] && return 0 ;;
      *)  [[ "$p" == "$item" ]] && return 0 ;;
    esac
  done
  return 1
}

# rd_commit_scope_all_records — 커밋에 들어갈 수 있는 변경이 전부 기록 경로 안인가 (§2.3)
#   return 0 — 전부 기록 경로 안 (판정 대상이 하나도 없으면 0 — 아래 근거)
#   return 1 — 하나라도 밖 (차단 사유)
#   return 2 — 판정 불가 (repo root·mktemp·`git diff` 실패, 목록이 잘린 경우). **통과가 아닙니다.**
#
# **판정 대상은 index ∪ 워킹트리(추적 파일)** 입니다. 종전에는 index 만 봤는데, hook 은 커밋
# 명령이 실행되기 **전에** 돌므로 `git commit -a`·`git commit <경로>` 처럼 커밋 집합을 명령
# 실행 중에 만드는 형태에서는 index 가 비어 있어 공허참으로 통과했습니다
# (final diff review Finding 3). raw command 를 파싱해 `-a`·pathspec 의미를 재현하는 방향은
# 택하지 않았습니다 — 인용·별칭·`-C`·`--` 조합마다 의미가 달라 파서가 곧 새는 반면,
# 「아카이브 보류 상태에서 보호 경로가 수정되어 있다」는 사실 자체가 이미 정상이 아니어서
# 명령 형태와 무관하게 차단하는 편이 계약(§4.3)에 더 가깝기 때문입니다.
#
# 판정 대상이 비어 있으면 통과입니다 — 공허참이 아니라 근거가 있습니다. git 은 추적되지
# 않는 경로를 `git commit <경로>` 로 받지 않으므로(pathspec 미매칭 오류), index 와 워킹트리가
# 모두 HEAD 와 같으면 그 커밋은 빈 커밋(`--allow-empty`) 밖에 될 수 없습니다. 입력을 읽지
# 못한 경우는 이 자리가 아니라 return 2 로 갑니다.
#
# rename 은 old·new 를 **양쪽 다** 봅니다 — 밖에서 안으로 옮긴 변경의 삭제 원본이 밖이면,
# 검사를 new 쪽만 하는 구현에서는 코드 변경이 기록 커밋으로 위장해 통과합니다.
# 삭제도 변경으로 셉니다. 목록은 NUL 구분으로 읽습니다 — 공백·개행이 든 파일명에서
# 줄 단위 파싱이 어긋나기 때문입니다.
rd_commit_scope_all_records() {
  local root tmp rc verdict=0
  root="$(rd_repo_root)" || {
    echo "rd_commit_scope_all_records: repo root 를 찾을 수 없습니다 — 판정 불가." >&2
    return 2
  }
  tmp="$(mktemp "${TMPDIR:-/tmp}/rd-scope.XXXXXX")" || {
    echo "rd_commit_scope_all_records: mktemp 실패 — 판정 불가." >&2
    return 2
  }
  # 두 스트림을 이어 붙여 한 번에 훑습니다. `-z` 레코드는 자기 자신이 경계를 갖고 있어
  # 이어 붙여도 파싱이 어긋나지 않습니다. 같은 경로가 양쪽에 나와도 판정 결과는 같습니다.
  : > "$tmp"
  git -C "$root" diff --cached -z --name-status >> "$tmp" 2>/dev/null
  rc=$?
  if [[ "$rc" != "0" ]]; then
    rm -f "$tmp"
    echo "rd_commit_scope_all_records: git diff --cached 실패 (exit ${rc}) — 판정 불가." >&2
    return 2
  fi
  git -C "$root" diff -z --name-status >> "$tmp" 2>/dev/null
  rc=$?
  if [[ "$rc" != "0" ]]; then
    rm -f "$tmp"
    echo "rd_commit_scope_all_records: git diff (워킹트리) 실패 (exit ${rc}) — 판정 불가." >&2
    return 2
  fi
  # -z 형식: <status>NUL<path>NUL, rename/copy 는 <status>NUL<old>NUL<new>NUL
  local st p1 p2
  while IFS= read -r -d '' st; do
    [[ -n "$st" ]] || continue
    if ! IFS= read -r -d '' p1; then verdict=2; break; fi
    case "$st" in
      R*|C*)
        if ! IFS= read -r -d '' p2; then verdict=2; break; fi
        if ! rd_path_is_record "$p1" || ! rd_path_is_record "$p2"; then verdict=1; break; fi
        ;;
      *)
        if ! rd_path_is_record "$p1"; then verdict=1; break; fi
        ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  if [[ "$verdict" == "2" ]]; then
    echo "rd_commit_scope_all_records: 변경 목록이 형식에 맞지 않습니다 — 판정 불가." >&2
  fi
  return "$verdict"
}

# rd_branch_mode <fr-branch 값> — canonical 표기 판정 (§3.2.2)
#   stdout `fr` | `no-fr` + return 0 / 그 밖의 값은 malformed 로 nonzero (fail-closed)
#
# canonical no-fr 표기는 `null` **하나뿐**입니다. "비어 있으면 no-fr" 로 다루면 필드가
# 유실된 파손 상태와 사용자가 명시한 no-fr 을 구분할 수 없어, 파손된 task-state 가
# 조용히 no-fr 발행으로 흘러갑니다. 빈 문자열·공백·`main` 등은 전부 차단합니다.
#
# 표기 변환 지점은 이 한 곳입니다 — 소비처(archive·seal·마커 검증)는 자기 자리에서
# 다시 판정하지 않습니다.
rd_branch_mode() {
  local v="${1-}"
  if [[ "$v" == "null" ]]; then
    printf 'no-fr\n'
    return 0
  fi
  case "$v" in
    fr/?*)
      case "$v" in
        *[[:space:]]*) ;;
        *) printf 'fr\n'; return 0 ;;
      esac
      ;;
  esac
  echo "rd_branch_mode: fr-branch 값이 canonical 이 아닙니다: '${v}' (허용: 'fr/<slug>' 또는 'null')" >&2
  return 1
}

# ---------------------------------------------------------------------------
# task-state 신설 필드 — base-commit (§5.3), review-session (§3.3)
# ---------------------------------------------------------------------------
# 두 필드의 미설정 sentinel 은 `null` 입니다 (fr-branch·worktree-path 와 같은 규칙).
# `archive.sh` 의 metadata cleanup 이 baseline 으로 되돌릴 때 함께 비웁니다.

# state_read_base_commit — 작업 시작 커밋 OID 출력. 미설정이면 빈 출력 + return 1.
state_read_base_commit() {
  local v
  v="$(state_read_field "base-commit")"
  case "$v" in
    ""|null|-) return 1 ;;
  esac
  printf '%s\n' "$v"
  return 0
}

# state_write_base_commit <ref> — 입력이 ref 여도 **저장 시점에 OID 로 resolve** 해 기록합니다.
# ref 이름을 저장하면 그 ref 가 움직였을 때 "작업 시작 커밋" 이 조용히 달라집니다 (§5.3).
# 커밋으로 해석되지 않으면 기록하지 않고 nonzero 입니다.
state_write_base_commit() {
  local ref="${1-}" oid
  oid="$(rd_resolve_commit_oid "$ref")" || {
    echo "base-commit: '${ref}' 를 commit 으로 해석할 수 없습니다 — 기록하지 않습니다." >&2
    return 1
  }
  state_write_fields "base-commit=${oid}"
}

# state_read_review_session — final diff review 세션 포인터 (§3.3).
#   출력 + return 0 / 미설정 return 1 / 경로 이탈 값 return 2 (stderr 사유)
#
# 소비처는 이 값으로 마커 경로(`.lifecycle/review-seals/<session-id>.seal`)를 조립하므로,
# 경로 구분자·`..` 가 섞인 값은 basename 으로 깎지 않고 **거부**합니다. 조용히 깎으면
# 사용자가 지정한 것과 다른 마커를 읽게 됩니다.
state_read_review_session() {
  local v
  v="$(state_read_field "review-session")"
  case "$v" in
    ""|null|-) return 1 ;;
  esac
  case "$v" in
    */*|*\\*|.|..)
      echo "review-session: 경로 구분자나 '..' 가 포함된 값은 허용되지 않습니다: '${v}'" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$v"
  return 0
}

# state_write_review_session <session-id> — 포인터 기록. 값 계약은 읽기와 같습니다.
state_write_review_session() {
  local v="${1-}"
  if [[ -z "$v" ]]; then
    echo "review-session: 빈 값은 허용되지 않습니다 (미설정은 'null')." >&2
    return 1
  fi
  case "$v" in
    */*|*\\*|.|..)
      echo "review-session: 경로 구분자나 '..' 가 포함된 값은 허용되지 않습니다: '${v}'" >&2
      return 1
      ;;
  esac
  state_write_fields "review-session=${v}"
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

# canonical 9종 집합 (LC-19) — _state_common.sh 독자 정의 (guard_common.sh에 의존하지 않음)
# 파이프(|) 구분 문자열. _state_status_canonical() 의 단일 진실 출처.
# `아카이브 보류` 는 「리뷰 종결·발행 대기」입니다 (change-spec §4.1). 완료가 아니며,
# 이 상태에서만 기록 커밋(제외 경로 한정)이 게이트를 통과합니다.
STATE_CANONICAL_STATUSES="대기 중|REQUEST review 대기|spec/plan 작성 중|spec/plan review 대기|구현 중|검증 중|diff review 대기|아카이브 보류|완료"

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
    echo "task-state 마이그레이션 실패: CURRENT_TASK.md ## Status ('${st:-<없음>}') 가 canonical 9종이 아닙니다." >&2
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
