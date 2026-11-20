#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "${script_dir}/../.." && pwd)"
cd "${project_root}"

# 기본 브랜치 resolver (diff 기본 target 일반화)
source "${script_dir}/lifecycle/_lifecycle_common.sh"
# 리뷰 대상 문자열·완전성 검사(rd_review_diff_target·rd_review_input_check). _rd_is_repo_root 가 _state_common.sh 에 있어 먼저 부릅니다.
source "${script_dir}/_state_common.sh"
source "${script_dir}/_submodule_common.sh"

turn_limit="${REVIEW_TURN_LIMIT:-20}"

usage() {
  cat <<'EOF' >&2
사용법:
  bash rd-workflow/scripts/prepare_review_pipeline.sh <review-kind> [args...]

review-kind:
  project-context
  request
  spec-plan [spec-path] [plan-path]
  diff [--base <ref>] [diff-target]   # diff-target: [git diff ]<a>...<b> | <a>..<b> | <ref>

예:
  bash rd-workflow/scripts/prepare_review_pipeline.sh project-context
  bash rd-workflow/scripts/prepare_review_pipeline.sh request
  bash rd-workflow/scripts/prepare_review_pipeline.sh spec-plan
  bash rd-workflow/scripts/prepare_review_pipeline.sh spec-plan rd-workflow-workspace/specs/changes/2026-03-12-image-compression-change-spec.md rd-workflow-workspace/plans/2026-03-12-image-compression-plan.md
  bash rd-workflow/scripts/prepare_review_pipeline.sh diff
  bash rd-workflow/scripts/prepare_review_pipeline.sh diff --base main
  bash rd-workflow/scripts/prepare_review_pipeline.sh diff "git diff main...HEAD"
  bash rd-workflow/scripts/prepare_review_pipeline.sh diff "main...fr/x"   # 접두 없는 a...b · a..b 도 받습니다
  bash rd-workflow/scripts/prepare_review_pipeline.sh diff main            # ref 하나 = "main...HEAD"
  # diff 의 base 우선순위: --base <ref> → task-state fr-branch(merge-base 계산 입력) → task-state base-commit.
  # 셋 다 없으면 세션을 만들지 않고 실패합니다 (빈 diff 를 리뷰 대상으로 남기지 않기 위함입니다).
  # --base 와 diff-target 위치 인자는 동시에 지정할 수 없습니다.
  # ref 하나(`diff main`)는 `main...HEAD` 와 같습니다 — 커밋된 HEAD 만 보며, 작업 트리를 비교하는
  # `git diff main` 과 다릅니다. ref 를 커밋으로 해석하지 못하면 세션을 만들지 않고 실패합니다.
  # 위치 인자의 오른쪽이 `HEAD` 가 아니면(예: "git diff main..branch-B") 그 head 를 pinned 로
  # 고정합니다 — 리뷰 도중 재snapshot 하지 않으므로 iteration commit 은 반영되지 않습니다.
EOF
}

read_current_task_field() {
  local field="$1"
  local task_file="${project_root}/CURRENT_TASK.md"
  [[ -f "$task_file" ]] || return 1
  local value
  value="$(awk -v target="## ${field}" '
    $0 == target { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && NF { print; exit }
  ' "$task_file")"
  [[ -n "$value" && "$value" != "-" ]] || return 1
  [[ -f "$value" ]] || return 1
  printf '%s\n' "$value"
}

file_mtime() {
  local file="$1"
  stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null || echo 0
}

latest_markdown_file() {
  local latest_file=""
  local latest_mtime=0
  local dir file mtime

  for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r file; do
      mtime="$(file_mtime "$file")"
      if [[ -z "$latest_file" || "$mtime" -gt "$latest_mtime" ]]; then
        latest_file="$file"
        latest_mtime="$mtime"
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' -print 2>/dev/null)
  done

  [[ -n "$latest_file" ]] || return 1
  printf '%s\n' "$latest_file"
}

derive_task_slug() {
  local input="$1"
  local base="${input##*/}"

  base="${base%.md}"
  base="${base#????-??-??-}"
  base="${base%-change-spec}"
  base="${base%-spec}"
  base="${base%-plan}"
  base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9._-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"

  if [[ -z "$base" ]]; then
    base="review"
  fi

  printf '%s\n' "$base"
}

# ---------------------------------------------------------------------------
# diff review base 판정 (change-spec §5.2 / §5.2.1)
# ---------------------------------------------------------------------------
# 이 절의 계약은 "빈 diff 가 Review Target 으로 기록되는 경로를 남기지 않는다" 입니다.
# 판정에 실패하면 세션을 만들지 않고 exit 1 합니다 (AC 4).
# OID 는 언제나 `rd_resolve_commit_oid`(= `git rev-parse --verify <ref>^{commit}`) 가 돌려주는
# 저장소 native full OID 이며, 길이를 하드코딩하지 않습니다 — SHA-256 저장소를 배제하지
# 않기 위함입니다 (§3.2.1).

# diff_fail <사유> — 실패 5종의 공통 출구. 세션은 만들어지지 않습니다.
diff_fail() {
  echo "diff review: $1" >&2
  echo "  세션을 만들지 않고 중단합니다 — 빈 diff 를 리뷰 대상으로 남기지 않기 위함입니다." >&2
  echo "  base 를 직접 지정하려면: prepare_review_pipeline.sh diff --base <ref>" >&2
  exit 1
}

# diff_is_ancestor <a> <b> — a 가 b 의 조상인가 (같은 커밋도 참)
diff_is_ancestor() {
  git merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1
}

# diff_merge_base <a> <b> — merge-base OID 출력. 실패(얕은 clone 등) 시 nonzero.
diff_merge_base() {
  local mb
  mb="$(git merge-base "$1" "$2" 2>/dev/null)" || return 1
  [[ -n "$mb" ]] || return 1
  rd_resolve_commit_oid "$mb"
}

# diff_change_state <base> <head> — 두 커밋 사이에 실제 변경이 있는지 판정합니다.
#   0 = 변경 있음 / 1 = 빈 diff / 2 = 판정 오류
# `git diff --quiet` 의 종료 코드는 일반 명령과 의미가 반대입니다 — 0 이 "차이 없음",
# 1 이 "차이 있음" 이고, 그 밖(128 등)은 git 오류입니다. 세 값을 구분하지 않으면
# **오류를 통과로 오독**하므로 2 는 fail-closed 로 차단합니다.
#
# OID 가 서로 다르다는 조건만으로는 빈 diff 를 막지 못합니다 — base 뒤에 변경 커밋과
# 완전 revert 커밋을 차례로 두면 OID 는 다르지만 트리가 같아 diff 가 비어 있습니다.
diff_change_state() {
  local rc=0
  git diff --quiet "${1}..${2}" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

# review_input_warn_threshold — 규모 경고 기준(행)을 stdout 에 정수로 냅니다.
# workflow.json 의 review_input_warn_lines: 키 부재·파일 부재는 기본값 8000 (조용히),
# 0 이상의 정수가 아닌 값은 기본값 8000 + stderr 안내, 0 은 경고 끔.
review_input_warn_threshold() {
  local cfg="${project_root}/rd-workflow/config/workflow.json" v=""
  if [[ -f "$cfg" ]] && grep -q '"review_input_warn_lines"[[:space:]]*:' "$cfg" 2>/dev/null; then
    v="$(sed -n 's/.*"review_input_warn_lines"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p' "$cfg" 2>/dev/null | head -1 || true)"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$((10#$v))"
      return 0
    fi
    echo "review input: workflow.json 의 review_input_warn_lines 값('${v}')이 0 이상의 정수가 아니어서 기본값 8000 을 씁니다." >&2
  fi
  printf '8000\n'
}

# review_input_size_warning <base> <head> — 변경 행 수(추가+삭제)가 기준을 넘으면 stderr 로 경고합니다.
# 경고만 하며 항상 0 을 반환합니다 (세션 생성은 이미 끝났고 막지 않습니다).
review_input_size_warning() {
  local base="$1" head="$2" threshold numstat total=0 a d p tab=$'\t'
  [[ -n "$base" && -n "$head" ]] || return 0
  threshold="$(review_input_warn_threshold)"
  [[ "$threshold" -gt 0 ]] || return 0
  numstat="$(git -c core.quotePath=false diff --numstat "${base}..${head}" 2>/dev/null)" || return 0
  [[ -n "$numstat" ]] || return 0
  local rows=""
  while IFS="$tab" read -r a d p; do
    [[ -n "$p" ]] || continue
    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    [[ "$d" =~ ^[0-9]+$ ]] || d=0
    total=$((total + a + d))
    rows="${rows}$((a + d))${tab}${p}"$'\n'
  done <<< "$numstat"
  [[ "$total" -gt "$threshold" ]] || return 0

  echo "review input: 변경 ${total}행이 경고 기준 ${threshold}행을 넘습니다 — 리뷰가 제한 시간 안에 끝나지 않을 수 있습니다." >&2
  echo "  행 수가 큰 파일:" >&2
  local n path any_split=0 mark
  while IFS="$tab" read -r n path; do
    [[ -n "$path" ]] || continue
    mark=""
    case "${path##*/}" in
      *.lock|package-lock.json|npm-shrinkwrap.json|pnpm-lock.yaml|go.sum|*.min.js|*.min.css|*.map|*.snap)
        mark="  [분리 후보]"; any_split=1 ;;
    esac
    echo "    ${n}  ${path}${mark}" >&2
  done < <(printf '%s' "$rows" | sort -t"$tab" -k1,1nr -k2,2 | head -5)
  if [[ "$any_split" -eq 1 ]]; then
    echo "  분리 후보(락파일·축소본·소스맵·스냅샷)는 별도 커밋·별도 리뷰로 나누는 것을 검토하십시오." >&2
  fi
  echo "  경고 기준은 rd-workflow/config/workflow.json 의 review_input_warn_lines 로 바꿀 수 있습니다 (0 은 끔)." >&2
  return 0
}

# shell_quote <문자열> — 안내 명령에 붙일 문자열을 셸에서 그대로 읽히게 인용합니다.
# [A-Za-z0-9_./-] 만 있으면 그대로, 아니면 작은따옴표로 감쌉니다 (안의 ' 는 '\'' 로 바꿈).
shell_quote() {
  local q="$1" sq="'"
  if [[ "$q" =~ ^[A-Za-z0-9_./-]+$ ]]; then
    printf '%s' "$q"
  else
    # 변수로 치환해 bash 버전별 따옴표·백슬래시 해석 차이를 피합니다.
    printf "'%s'" "${q//$sq/$sq\\$sq$sq}"
  fi
}

# review_submodule_notice <base> <head> — outer diff 가 담지 못하는 서브모듈 내부 변경을 stderr 로 알립니다.
# (가) 체크아웃 OID ≠ outer HEAD 의 gitlink OID (.gitmodules 가 있을 때만),
# (나) reviewed 구간 안의 gitlink 변경 (.gitmodules 와 무관). 알림 전용이며 항상 0 을 반환합니다.
review_submodule_notice() {
  local base="$1" head="$2" lines="" p link co top real tab=$'\t' rec inner
  if [[ -f .gitmodules ]]; then
    # -z 출력은 레코드마다 "<key>\n<value>\0" 이라 공백이 있는 이름·경로도 값만 온전히 꺼냅니다.
    while IFS= read -r -d '' rec; do
      p="${rec#*$'\n'}"
      [[ "$p" != "$rec" ]] || continue
      [[ -n "$p" ]] || continue
      link="$(git ls-tree HEAD -- "$p" 2>/dev/null | awk '$1 == "160000" { print $3; exit }')"
      [[ -n "$link" ]] || continue
      [[ -d "$p" ]] || continue
      top="$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || continue
      top="$(cd "$top" 2>/dev/null && pwd -P)" || continue
      real="$(cd "$p" 2>/dev/null && pwd -P)" || continue
      [[ "$top" == "$real" ]] || continue
      co="$(git -C "$p" rev-parse HEAD 2>/dev/null)" || continue
      [[ -n "$co" && "$co" != "$link" ]] || continue
      lines="${lines}  [체크아웃] ${p}: 체크아웃 ${co:0:12} ≠ outer HEAD 기록 ${link:0:12}"$'\n'
      inner="git -C $(shell_quote "$p") diff ${link}..HEAD"
      lines="${lines}    내부 변경을 리뷰하려면: prepare_review_pipeline.sh diff $(shell_quote "$inner")"$'\n'
    done < <(git config -f .gitmodules -z --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
  fi
  if [[ -n "$base" && -n "$head" ]]; then
    local meta path om nm oo no
    # -z 출력은 "<meta>\0<path>\0" 이라 따옴표·역슬래시가 있는 경로도 C 식 인용 없이 그대로 옵니다.
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
      [[ -n "$path" ]] || continue
      # meta = ":<old mode> <new mode> <old oid> <new oid> <status>"
      set -- $meta
      om="${1#:}"; nm="$2"; oo="$3"; no="$4"
      [[ "$om" == "160000" || "$nm" == "160000" ]] || continue
      if [[ "$om" == "160000" && "$nm" == "160000" ]]; then
        lines="${lines}  [커밋된 포인터] ${path}: ${oo:0:12}→${no:0:12} (리뷰 입력에 내부 코드를 펼쳤습니다)"$'\n'
      elif [[ "$nm" == "000000" ]]; then
        lines="${lines}  [커밋된 포인터] ${path}: 서브모듈 삭제 (${oo:0:12} → 없음, 이 리뷰에는 포인터 변경만 보입니다)"$'\n'
      elif [[ "$om" != "000000" ]]; then
        lines="${lines}  [커밋된 포인터] ${path}: 서브모듈↔일반 파일 종류 변경"$'\n'
      else
        lines="${lines}  [커밋된 포인터] ${path}: 서브모듈 추가 (없음 → ${no:0:12}, 리뷰 입력에 내부 코드를 펼쳤습니다)"$'\n'
      fi
    done < <(git diff --raw -z --no-abbrev --no-renames "${base}..${head}" 2>/dev/null || true)
  fi
  [[ -n "$lines" ]] || return 0
  echo "review target: 서브모듈 변경이 있습니다 — outer diff 는 서브모듈 내부 변경을 담지 않습니다." >&2
  printf '%s' "$lines" >&2
  return 0
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

review_kind="$1"
shift || true

session_slug=""
review_type=""
review_target=""
review_goal=""
# diff review 에서만 채워지는 값 (§3.2.1). 비어 있으면 SESSION 에 기록하지 않습니다.
REVIEW_BASE_OID=""
REVIEW_HEAD_OID=""
# head 갱신 정책 (§3.2.1). `auto` 는 reviewer 턴마다 현재 HEAD 로 재snapshot 하는 기존 동작이고,
# `pinned` 는 사용자가 위치 인자로 **현재 HEAD 가 아닌 head 를 명시**한 세션입니다. pinned 세션을
# 재snapshot 하면 사용자가 지정한 검토 대상이 조용히 현재 HEAD 로 바뀌므로 갱신하지 않습니다.
REVIEW_HEAD_POLICY="auto"
DIFF_TARGET_UNRESOLVED=0

case "$review_kind" in
  project-context|project-context-review)
    review_type="project-context-review"
    session_slug="project-context-review"
    review_target="PROJECT_CONTEXT.md"
    review_goal="\`rd-workflow/docs/prompts/review/project_context_review.md\` 기준으로 build / test / lint / typecheck 명령과 프로젝트 규칙이 구현 입력으로 충분한지 점검"
    ;;
  request|request-review)
    review_type="request-review"
    session_slug="request-review"
    review_target="REQUEST.md"
    review_goal="\`rd-workflow/docs/prompts/review/request_review.md\` 기준으로 제약, 완료 조건, 플랫폼, 위험 요소, 영향 범위 누락이 없는지 점검"
    ;;
  spec-plan|spec-plan-review|spec-review)
    spec_path="${1:-}"
    plan_path="${2:-}"

    if [[ -z "$spec_path" ]]; then
      spec_path="$(read_current_task_field "Spec" || true)"
    fi
    if [[ -z "$spec_path" ]]; then
      spec_path="$(latest_markdown_file "rd-workflow-workspace/specs/changes" "rd-workflow-workspace/specs/base" || true)"
    fi

    if [[ -z "$plan_path" ]]; then
      plan_path="$(read_current_task_field "Plan" || true)"
    fi
    if [[ -z "$plan_path" ]]; then
      plan_path="$(latest_markdown_file "rd-workflow-workspace/plans" || true)"
    fi

    if [[ -z "$spec_path" || -z "$plan_path" ]]; then
      echo "spec-plan 검토는 spec과 plan 경로가 필요합니다." >&2
      echo "자동 탐지에 실패했으면 직접 지정하세요." >&2
      echo "예: bash rd-workflow/scripts/prepare_review_pipeline.sh spec-plan <spec-path> <plan-path>" >&2
      exit 1
    fi

    review_type="spec-plan-review"
    session_slug="$(derive_task_slug "$plan_path")-spec-plan-review"
    review_target="${spec_path}
${plan_path}"
    # 변이 명세는 spec_review.md 의 FULL_ONLY 구획과 짝을 맞춥니다 (lite 는 plan 지점 미적용 — docs/guides/mutation-check.md).
    review_goal="\`rd-workflow/docs/prompts/review/spec_review.md\` 기준으로 과도한 설계, 빠진 엣지 케이스, 더 단순한 대안, 테스트 전략 누락, 플랫폼 리스크를 점검"
    ;;
  diff|diff-review|final-diff)
    # --- 인자 파싱: `--base <ref>` 와 기존 위치 인자 `[diff-target]` (§5.2.1) ---
    # 위치 인자는 2026-07-08 부터 서브모듈 워크스페이스 프로젝트가 쓰고 있으므로 깨지 않습니다.
    # 다만 어느 쪽이 이기는지 모호해지지 않도록 동시 입력은 거부합니다.
    diff_base_ref=""
    diff_base_given=0
    diff_positional=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --base)
          if [[ $# -lt 2 || -z "${2:-}" ]]; then
            echo "diff review: --base 에 ref 를 지정하세요 (예: --base main)" >&2
            exit 1
          fi
          diff_base_ref="$2"
          diff_base_given=1
          shift 2
          ;;
        --base=*)
          diff_base_ref="${1#--base=}"
          if [[ -z "$diff_base_ref" ]]; then
            echo "diff review: --base 에 ref 를 지정하세요 (예: --base=main)" >&2
            exit 1
          fi
          diff_base_given=1
          shift
          ;;
        --)
          shift
          ;;
        *)
          if [[ -n "$diff_positional" ]]; then
            echo "diff review: diff-target 위치 인자는 하나만 받습니다: ${1}" >&2
            exit 1
          fi
          diff_positional="$1"
          shift
          ;;
      esac
    done

    if [[ "$diff_base_given" -eq 1 && -n "$diff_positional" ]]; then
      echo "diff review: --base 와 diff-target 위치 인자는 동시에 지정할 수 없습니다 (§5.2.1)." >&2
      echo "  둘 중 하나만 쓰세요 — 어느 쪽이 우선인지 모호해지면 리뷰 대상이 흔들립니다." >&2
      exit 1
    fi

    _head_oid="$(rd_resolve_commit_oid "HEAD")" \
      || diff_fail "현재 HEAD 를 커밋으로 해석할 수 없습니다 (빈 저장소이거나 손상되었습니다)"

    _base_oid=""
    if [[ -n "$diff_positional" ]]; then
      # --- 위치 인자 경로 (§5.2.1) ---
      # `git diff <base>..<head>` / `git diff <base>...<head>` 로 파싱되면 양끝을 OID 로
      # resolve 해 §5.2 와 같은 검증을 적용합니다. 세 점 형태는 git 의 의미 그대로
      # merge-base 를 base 로 씁니다 — 그래야 기록한 두 점 diff 가 원래 표현과 같은
      # 변경 집합을 가리킵니다.
      _pos_head_oid=""
      _pos_form=""
      # 앞뒤 공백을 걷고 선택적 접두 `git diff ` 를 뗀 나머지가 body 입니다 (change-spec 2.2).
      # body 가 공백을 포함하면 파싱 불가(legacy)입니다.
      _pos_expr="$diff_positional"
      _pos_expr="${_pos_expr#"${_pos_expr%%[![:space:]]*}"}"
      _pos_expr="${_pos_expr%"${_pos_expr##*[![:space:]]}"}"
      _pos_body="$_pos_expr"
      if [[ "$_pos_expr" =~ ^git[[:space:]]+diff[[:space:]]+(.*)$ ]]; then
        _pos_body="${BASH_REMATCH[1]}"
      fi
      if [[ -z "$_pos_body" || "$_pos_body" =~ [[:space:]] ]]; then
        :
      elif [[ "$_pos_body" =~ ^([^[:space:].][^[:space:]]*)\.\.\.([^[:space:]]+)$ ]]; then
        _pos_form="range3"
        _pos_l="${BASH_REMATCH[1]}"
        _pos_r="${BASH_REMATCH[2]}"
        _pos_l_oid="$(rd_resolve_commit_oid "$_pos_l")" \
          || diff_fail "diff-target 의 '${_pos_l}' 를 커밋으로 해석할 수 없습니다"
        _pos_head_oid="$(rd_resolve_commit_oid "$_pos_r")" \
          || diff_fail "diff-target 의 '${_pos_r}' 를 커밋으로 해석할 수 없습니다"
        _base_oid="$(diff_merge_base "$_pos_l_oid" "$_pos_head_oid")" \
          || diff_fail "merge-base 계산 실패 — '${_pos_l}' 와 '${_pos_r}' 의 공통 조상을 찾을 수 없습니다 (얕은 clone 일 수 있습니다)"
      elif [[ "$_pos_body" != *...* && "$_pos_body" =~ ^([^[:space:].][^[:space:]]*)\.\.([^[:space:]]+)$ ]]; then
        _pos_form="range2"
        _pos_l="${BASH_REMATCH[1]}"
        _pos_r="${BASH_REMATCH[2]}"
        _base_oid="$(rd_resolve_commit_oid "$_pos_l")" \
          || diff_fail "diff-target 의 '${_pos_l}' 를 커밋으로 해석할 수 없습니다"
        _pos_head_oid="$(rd_resolve_commit_oid "$_pos_r")" \
          || diff_fail "diff-target 의 '${_pos_r}' 를 커밋으로 해석할 수 없습니다"
      elif [[ "$_pos_body" != *..* && "$_pos_body" != -* ]]; then
        # ref 하나: `<ref>...HEAD` 와 같습니다 (change-spec 2.2 순서 3, head 정책 auto).
        _pos_form="single"
        _pos_l="$_pos_body"
        _pos_r="HEAD"
        _pos_l_oid="$(rd_resolve_commit_oid "$_pos_l")" \
          || diff_fail "diff-target 의 '${_pos_l}' 를 커밋으로 해석할 수 없습니다"
        _pos_head_oid="$(rd_resolve_commit_oid "$_pos_r")" \
          || diff_fail "diff-target 의 'HEAD' 를 커밋으로 해석할 수 없습니다"
        _base_oid="$(diff_merge_base "$_pos_l_oid" "$_pos_head_oid")" \
          || diff_fail "merge-base 계산 실패 — '${_pos_l}' 와 'HEAD' 의 공통 조상을 찾을 수 없습니다 (얕은 clone 일 수 있습니다)"
      fi

      if [[ -n "$_base_oid" ]]; then
        _head_oid="$_pos_head_oid"
        # head 갱신 정책 판정 (§3.2.1). 오른쪽이 **문자 그대로 `HEAD`** 이면 "지금 작업 중인 것을
        # 보라" 는 뜻이므로 기존 `auto` 동작(턴마다 재snapshot)이 사용자의 의도입니다. 그 밖의
        # ref·OID 는 사용자가 대상을 명시한 것이므로 `pinned` 으로 고정합니다 — 이때 재snapshot 하면
        # 세션이 만든 target(예: branch-B)이 첫 reviewer dispatch 직전에 현재 HEAD 로 바뀝니다.
        # OID 비교가 아니라 ref 문자열로 판정하는 이유: 생성 시점에 우연히 두 OID 가 같더라도
        # 그 뒤 HEAD 가 전진하면 같은 조용한 표류가 되살아납니다.
        if [[ "$_pos_r" != "HEAD" ]]; then
          REVIEW_HEAD_POLICY="pinned"
        fi
      else
        # 파싱되지 않는 임의 표현(예: 서브모듈을 겨냥한 `git -C sub diff ...`)은
        # 세션은 만들되 reviewed OID 를 기록하지 않습니다. 그 세션은 일반 seal 로
        # 봉인할 수 없고 `--legacy-unverified` 경로로만 갑니다.
        DIFF_TARGET_UNRESOLVED=1
        diff_target="$diff_positional"
      fi
    elif [[ "$diff_base_given" -eq 1 ]]; then
      # --- 우선순위 1: --base <ref> ---
      _base_oid="$(rd_resolve_commit_oid "$diff_base_ref")" \
        || diff_fail "--base '${diff_base_ref}' 가 존재하지 않거나 커밋이 아닙니다"
    else
      # --- 우선순위 2: task-state fr-branch (merge-base 계산의 입력이지 base 자체가 아닙니다) ---
      _fr_val="$(state_read_field "fr-branch")"
      _fr_mode=""
      if [[ -n "$_fr_val" ]]; then
        _fr_mode="$(rd_branch_mode "$_fr_val" 2>/dev/null)" \
          || diff_fail "task-state fr-branch 값이 canonical 이 아닙니다: '${_fr_val}' (허용: 'fr/<slug>' 또는 'null')"
      fi
      if [[ "$_fr_mode" == "fr" ]]; then
        _fr_tip="$(rd_resolve_commit_oid "$_fr_val")" \
          || diff_fail "task-state 의 fr-branch '${_fr_val}' 가 존재하지 않습니다 (삭제되었거나 stale 합니다)"
        _default_branch="$(get_default_branch)" \
          || diff_fail "기본 브랜치 결정 실패 — merge-base 를 계산할 수 없습니다"
        _default_oid="$(rd_resolve_commit_oid "$_default_branch")" \
          || diff_fail "기본 브랜치 '${_default_branch}' 를 커밋으로 해석할 수 없습니다"
        _base_oid="$(diff_merge_base "$_default_oid" "$_fr_tip")" \
          || diff_fail "merge-base 계산 실패 (얕은 clone 등) — '${_default_branch}' 와 '${_fr_val}' 의 공통 조상을 찾을 수 없습니다"
        if ! diff_is_ancestor "$_fr_tip" "$_head_oid"; then
          diff_fail "현재 HEAD 가 ${_fr_val} 계보에 없습니다"
        fi
      else
        # --- 우선순위 3: task-state base-commit ---
        if _stored_base="$(state_read_base_commit)"; then
          _base_oid="$(rd_resolve_commit_oid "$_stored_base")" \
            || diff_fail "task-state base-commit '${_stored_base}' 가 이 저장소에 없습니다 (stale 합니다)"
        else
          # --- 우선순위 4: 없음 ---
          diff_fail "base 판정 입력이 없습니다 — --base <ref> 를 주거나 'rd task set-base <ref>' 로 base-commit 을 설정하세요"
        fi
      fi
    fi

    if [[ -n "$_base_oid" ]]; then
      # 공통 검증: base 는 head 의 조상이어야 하고, 둘이 같으면 리뷰할 변경이 없습니다.
      # 조상 검사가 "입력이 서로 모순" 을 잡는 자리입니다 — 다른 계보의 base 는 여기서 걸립니다.
      if ! diff_is_ancestor "$_base_oid" "$_head_oid"; then
        diff_fail "base ${_base_oid} 가 현재 HEAD 의 조상이 아닙니다 — 입력이 서로 모순입니다"
      fi
      if [[ "$_base_oid" == "$_head_oid" ]]; then
        if [[ "${_pos_form:-}" == "single" ]]; then
          diff_fail "base 와 HEAD 가 같은 커밋입니다 (${_base_oid}) — 리뷰할 변경이 없습니다
  비교 기준 브랜치를 주십시오 (예: diff main)."
        fi
        diff_fail "base 와 HEAD 가 같은 커밋입니다 (${_base_oid}) — 리뷰할 변경이 없습니다"
      fi
      # 서로 다른 OID 라는 조건만으로는 부족합니다 — 변경 커밋과 완전 revert 커밋이 이어지면
      # OID 는 달라도 트리가 같아 diff 가 비어 있습니다 (AC 4).
      # `|| _cs=$?` 로 받는 이유: set -e 아래에서 nonzero 를 그대로 두면 스크립트가 즉시 끝나
      # 아래 사유 안내가 나오지 않습니다.
      _cs=0
      diff_change_state "$_base_oid" "$_head_oid" || _cs=$?
      case "$_cs" in
        1) diff_fail "base ${_base_oid} 와 head ${_head_oid} 사이에 변경이 없습니다 (커밋은 다르지만 트리가 같습니다) — 리뷰할 변경이 없습니다" ;;
        2) diff_fail "base ${_base_oid} 와 head ${_head_oid} 의 diff 판정에 실패했습니다 (git 오류) — 판정 불가이므로 차단합니다" ;;
      esac
      REVIEW_BASE_OID="$_base_oid"
      REVIEW_HEAD_OID="$_head_oid"
      # submodule 포인터가 바뀐 구간은 안쪽 코드를 펼친 형식으로 대상을 만들고, 펼치지 못하면 세션 생성 전에 멈춥니다.
      rd_review_input_check "$REVIEW_BASE_OID" "$REVIEW_HEAD_OID" \
        || diff_fail "리뷰 입력에 submodule 코드를 펼칠 수 없습니다 — 위 안내를 따르십시오"
      diff_target="$(rd_review_diff_target "$REVIEW_BASE_OID" "$REVIEW_HEAD_OID")"
    fi
    review_type="diff-review"
    session_slug="final-diff-review"
    review_target="${diff_target}"
    review_goal="\`rd-workflow/docs/prompts/review/diff_review.md\` 기준으로 논리 버그, 회귀 위험, 성능 문제, 보안 문제, 유지보수성 저하, 불필요한 복잡성, 변이 증거를 점검"
    ;;
  *)
    echo "알 수 없는 review-kind: ${review_kind}" >&2
    usage
    exit 1
    ;;
esac

session_path="$("${script_dir}/init_review_pipeline.sh" "${session_slug}" "${review_type}" "${review_target}" "${review_goal}")"
prompts_path="${session_path}/PROMPTS.md"

# ref 하나 형태로 해석한 세션은 해석 결과를 알립니다 (change-spec 2.3). 거부하지 않고 알려서,
# 기본 브랜치에서 리뷰할 브랜치를 기준으로 착각해 준 경우도 바로 알아차리게 합니다.
if [[ "${_pos_form:-}" == "single" ]]; then
  _single_head_name="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || _single_head_name="${REVIEW_HEAD_OID:0:12}"
  {
    echo "diff review: '${_pos_l}' 를 비교 기준으로 해석했습니다 — 리뷰 대상은 ${REVIEW_BASE_OID:0:12}..${_single_head_name} (${_pos_l}...HEAD 와 같습니다)."
    echo "  다른 브랜치를 리뷰하려면 양끝을 주십시오. 예: prepare_review_pipeline.sh diff \"<기준>...<리뷰할 브랜치>\""
  } >&2
fi

cat <<EOF > "${prompts_path}"
# Review Pipeline Prompts

## Review Kind
${review_kind}

## Review Type
${review_type}

## Review Target
${review_target}

## Review Goal
${review_goal}

## Session Path
${session_path}

## Preferred Flow
Claude 중심 권장 흐름에서는 아래 프롬프트만 Claude에게 넣고, 이후 Codex 차례는 Claude가 이 세션 경로로 \`bash rd-workflow/scripts/run_review_turn.sh ...\`를 처리한다.

## Step 1. Paste To Claude
\`\`\`text
\`rd-workflow/docs/prompts/manual/review_pipeline_continue_manual.md\`대로 이어줘.

session path:
${session_path}
\`\`\`

## Step 2. Manual Codex Fallback
Claude가 CLI를 실행할 수 없고, Claude가 첫 턴을 작성한 뒤 \`SESSION.md\`의 \`Current Owner\`가 \`Reviewer\`가 되면 아래를 Reviewer에게 넣는다.
수동으로 쓴 리뷰어 턴은 실행 기록을 남기지 않습니다. 수동으로만 리뷰한 final diff 세션은 \`rd review seal\` 이 거부하며, 발행은 \`archive.sh --force-skip-review-check <사유>\`(audit 기록)로 합니다.

\`\`\`text
\`rd-workflow/docs/prompts/manual/review_pipeline_continue_manual.md\`대로 이어줘.

session path:
${session_path}
\`\`\`

## Step 3. Repeat
- 권장 흐름에서는 Claude가 최신 Reviewer 턴이 \`이의 없음\`을 명시할 때까지 같은 세션을 계속 읽고 필요할 때 리뷰 어댑터를 호출한다.
- 수동 fallback에서는 같은 이어가기 프롬프트를 계속 재사용한다.
- 총 턴 수는 최대 ${turn_limit}개이며, ${turn_limit}턴에 도달하면 남은 쟁점을 정리하고 \`awaiting-user\`로 넘긴다.
- 현재 차례는 \`SESSION.md\`의 \`Current Owner\`를 본다.
- \`awaiting-user\`가 되면 \`USER_ACTION.md\` 질문에 답하거나 마무리를 승인한다.
EOF

# Branch Context section (Task 8 — fr-branch-tag-lifecycle)
CTX_FR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
# canonical no-fr 표기는 `null` 하나뿐입니다 (§3.2.2). 빈 값·detached HEAD·기본 브랜치 이름은
# 전부 여기서 `null` 로 접히고, 판정은 rd_branch_mode 한 곳에서만 합니다.
[[ "$CTX_FR_BRANCH" != fr/* ]] && CTX_FR_BRANCH="null"
rd_branch_mode "$CTX_FR_BRANCH" >/dev/null || {
  echo "review pipeline: fr-branch 표기가 canonical 이 아닙니다: '${CTX_FR_BRANCH}'" >&2
  exit 1
}
CTX_WT_PATH="$(git rev-parse --show-toplevel 2>/dev/null || echo "null")"
CTX_SHORT_TITLE="$(awk '/^## Short Title/{flag=1; next} flag && /^[^#]/{sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print; exit}' CURRENT_TASK.md 2>/dev/null || true)"
[[ -z "$CTX_SHORT_TITLE" || "$CTX_SHORT_TITLE" == "-" ]] && CTX_SHORT_TITLE="unknown"
# lifecycle-stage 는 alias 가 정규화된 review_type 을 source-of-truth 로 삼는다.
# review_kind 는 alias(`request|request-review`, `diff|diff-review|final-diff` 등)를 받지만
# review_type 은 case 문에서 단일 값으로 정규화된 뒤 stage 매핑된다.
case "${review_type:-}" in
  request-review) CTX_STAGE="request-review" ;;
  spec-plan-review) CTX_STAGE="spec-review" ;;
  diff-review) CTX_STAGE="validating" ;;
  project-context-review) CTX_STAGE="implementing" ;;
  *) CTX_STAGE="implementing" ;;
esac
if git remote get-url origin >/dev/null 2>&1 && [[ -z "${RD_LIFECYCLE_NO_REMOTE:-}" ]]; then
  CTX_REMOTE_MODE="remote"
else
  CTX_REMOTE_MODE="local-only"
fi

cat >> "${session_path}/SESSION.md" <<EOF

## Branch Context
- fr-branch: $CTX_FR_BRANCH
- worktree-path: $CTX_WT_PATH
- short-title: $CTX_SHORT_TITLE
- lifecycle-stage: $CTX_STAGE
- remote-mode: $CTX_REMOTE_MODE
EOF

# reviewed OID (change-spec §3.2.1) — Review Target 문자열을 파싱하는 계약을 만들지 않기 위해
# 기계 판독 값을 `- key: value` 형식으로 따로 남깁니다. 두 값이 다 있는 세션만 일반 seal 로
# 봉인할 수 있고, run_review_turn.sh 의 head 재snapshot 대상도 이 세션들입니다.
if [[ -n "$REVIEW_BASE_OID" && -n "$REVIEW_HEAD_OID" ]]; then
  cat >> "${session_path}/SESSION.md" <<EOF
- review-base-oid: $REVIEW_BASE_OID
- review-head-oid: $REVIEW_HEAD_OID
- review-head-policy: $REVIEW_HEAD_POLICY
EOF
fi

# final diff review 세션 포인터 (§3.3) — 소비처는 디렉터리를 뒤지지 않고 이 값 하나만 씁니다.
if [[ "$review_type" == "diff-review" ]]; then
  if ! state_write_review_session "${session_path##*/}"; then
    echo "diff review: task-state 에 review-session 포인터를 기록하지 못했습니다." >&2
    echo "  세션은 ${session_path} 에 만들어졌지만, 포인터 없이는 발행 게이트가 이 세션의 마커를 찾지 못합니다." >&2
    exit 1
  fi
fi

# pinned 세션의 성질을 사용자에게 알립니다 — 조용히 고정해 두면 "왜 내 수정 커밋이 리뷰에
# 안 잡히지" 라는 혼란이 생깁니다.
if [[ "$REVIEW_HEAD_POLICY" == "pinned" ]]; then
  echo "review head 정책: pinned — 지정하신 head (${REVIEW_HEAD_OID}) 를 그대로 유지합니다." >&2
  echo "  이 세션은 reviewer 턴마다 현재 HEAD 로 다시 snapshot 하지 않으므로, 리뷰 도중의" >&2
  echo "  iteration commit 은 리뷰 대상에 반영되지 않습니다." >&2
  echo "  현재 작업분을 계속 따라가려면 'diff --base <ref>' 또는 'diff \"git diff <base>..HEAD\"' 를 쓰세요." >&2
fi

if [[ "$DIFF_TARGET_UNRESOLVED" -eq 1 ]]; then
  echo "diff-target 을 OID 로 해석할 수 없어 reviewed OID 를 기록하지 않았습니다 — 이 세션은 봉인 시 --legacy-unverified 가 필요합니다" >&2
fi

# 리뷰 입력 규모 경고 — reviewed OID 가 둘 다 있을 때만 잽니다 (경고 전용, 세션 생성은 막지 않음).
review_input_size_warning "${REVIEW_BASE_OID:-}" "${REVIEW_HEAD_OID:-}" || true
if [[ "$review_type" == "diff-review" ]]; then
  review_submodule_notice "${REVIEW_BASE_OID:-}" "${REVIEW_HEAD_OID:-}" || true
fi

# Review Scope section (review-turn-latency-reduction — A / review-tiering-by-risk — D8)
# 판정을 세션 생성 시 1회 수행해 고정한다. 턴마다 REQUEST.md 를 재파싱하면
# diff-review 시점에는 REQUEST 가 아카이브되어 비어 있을 수 있다.
# Branch Context 밖에 두는 이유: validate_branch_context 가 5필드를 strict 검증하므로
# 6번째 필드를 넣으면 진행 중인 legacy 세션이 죽는다.
# 판정 규칙(Risk Tier 1차 키, malformed → unknown + 경고, 헤더 부재 → Execution Path fallback)은
# _state_common.sh 의 review_execution_path_from_request 에 있고 test_review_effort_override.sh 가 표로 검증한다.
# 기록 커밋 뒤에 여는 세션(main 병합 확인 등)은 루트 REQUEST.md 가 비어 있으므로 구간에 추가된 보관본을 씁니다.
CTX_REQUEST_FILE="REQUEST.md"
if [[ "$review_type" == "diff-review" ]]; then
  CTX_REQUEST_FILE="$(review_request_file "${REVIEW_BASE_OID:-}" "${REVIEW_HEAD_OID:-}")"
  if [[ "$CTX_REQUEST_FILE" != "REQUEST.md" ]]; then
    echo "diff review: 구간에 REQUEST 보관본이 있어 완료 기준과 리뷰 effort 를 ${CTX_REQUEST_FILE} 에서 읽습니다." >&2
  fi
fi
CTX_EXEC_PATH="$(review_execution_path_from_request "${project_root}/${CTX_REQUEST_FILE}")"

cat >> "${session_path}/SESSION.md" <<EOF

## Review Scope
- execution-path: $CTX_EXEC_PATH
EOF

cat <<EOF
review pipeline prepared

session path:
${session_path}

review type:
${review_type}

review target:
${review_target}

review goal:
${review_goal}

next:
1. 아래 프롬프트를 Claude에게 넣으세요.
2. 권장 흐름에서는 Claude가 Codex 차례에 이 세션 경로로 \`bash rd-workflow/scripts/run_review_turn.sh ...\`를 실행합니다.
3. Claude가 CLI를 실행할 수 없을 때만 ${prompts_path} 의 수동 fallback 블록을 사용하세요.

----- CLAUDE -----
\`rd-workflow/docs/prompts/manual/review_pipeline_continue_manual.md\`대로 이어줘.

session path:
${session_path}
EOF
