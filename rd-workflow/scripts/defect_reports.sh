#!/usr/bin/env bash
# rd-workflow 결함 보고서 로컬 조작부 + upstream 전달 경로.
# 서브커맨드: list-pending, count-pending, ensure-id <file>, set-issue <file> <url>,
#            set-upstream <url>, preview <file> [--upstream <t>], publish <file> [--upstream <t>] [--yes]
set -uo pipefail

REPORT_DIR="rd-workflow-workspace/reports/workflow-defects"
CONFIG_FILE="rd-workflow/config/workflow.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat >&2 <<'EOF'
사용법: defect_reports.sh <subcommand> [args...]

  list-pending              미전달 결함 보고서 경로를 개행 구분으로 출력
  count-pending             미전달 결함 보고서 건수를 출력
  ensure-id <file>          report-id 를 보장하고 값을 출력 (없으면 생성해 영속화)
  set-issue <file> <url>    upstream-issue 값을 <url> 로 역기록
  set-upstream <url>        defect_report_upstream 이 비어 있으면 URL 을 canonical 값으로 채운다
  preview <file> [--upstream <t>]           발행 전 화면(대상·공개여부·본문)만 보여준다 (무변경)
  publish <file> [--upstream <t>] [--yes]   결함 보고서를 GitHub Issue 로 발행한다 (--yes 없으면 preview)
EOF
}

read_field() {
  # $1=file $2=field-name
  sed -n "s/^- ${2}: \(.*\)\$/\1/p" "$1" | head -1
}

is_pending() {
  # $1=file
  # upstream-issue 값이 없거나(필드 부재) 'https://' 로 시작하지 않으면 pending.
  local val
  val="$(read_field "$1" "upstream-issue")"
  case "$val" in
    https://*) return 1 ;;
    *) return 0 ;;
  esac
}

list_pending() {
  [[ -d "$REPORT_DIR" ]] || return 0
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if is_pending "$f"; then
      printf '%s\n' "$f"
    fi
  done < <(find "$REPORT_DIR" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
}

count_pending() {
  list_pending | grep -c . || true
}

# 파일에 필드를 삽입할 위치를 정한다: '- 대상 산출물:' 줄 다음, 없으면
# 머리말 블록의 마지막 '- ' 줄 다음, 그것도 없으면 첫 줄(제목) 다음.
# $1=file  -> stdout 으로 삽입 대상 라인 번호를 출력
_insert_after_line() {
  local file="$1" line
  line="$(grep -n '^- 대상 산출물:' "$file" | head -1 | cut -d: -f1)"
  if [[ -n "$line" ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  line="$(grep -n '^- ' "$file" | tail -1 | cut -d: -f1)"
  if [[ -n "$line" ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  printf '1\n'
}

# 원자적 교체용 임시 파일 — **대상과 같은 디렉토리**에 만든다.
# 시스템 임시 디렉토리(`/tmp`)는 다른 파일시스템일 수 있어 `mv` 가 rename 이 아니라
# 복사+삭제로 떨어지고, 그 순간 크래시하면 파일이 깨진다. 같은 디렉토리면 rename 이
# 보장된다 (final diff review 개선 제안).
_tmp_beside() {
  local dir f; dir="$(dirname "$1")"
  f="$(mktemp "${dir}/.rd-defect.XXXXXX")" || { echo "_tmp_beside: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$f" && -f "$f" ]] || { echo "_tmp_beside: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  printf '%s\n' "$f"
}

# symlink 체인을 따라가 **최종 referent(실제 regular file) 경로**를 출력한다.
# `readlink -f` 는 GNU 전용이라 배포 대상인 macOS 에서 쓸 수 없으므로 `readlink` 만으로
# 직접 돈다. 상대 경로 target 은 **링크가 놓인 디렉터리 기준**으로 이어 붙이고, 순환·과도한
# 체인을 막기 위해 횟수 상한(16회)을 둔다. 해석에 실패하면 아무것도 쓰지 않고 비영을 낸다.
# $1=경로 -> stdout 에 referent 경로
_resolve_symlink() {
  local path="$1" hops=0 target dir
  while [[ -L "$path" ]]; do
    hops=$((hops + 1))
    if (( hops > 16 )); then
      echo "오류: symlink 체인이 너무 깊습니다(16회 초과) — '$1' 의 최종 대상을 해석할 수 없습니다." >&2
      return 1
    fi
    target="$(readlink "$path")" || {
      echo "오류: symlink 를 읽을 수 없습니다: '$path'" >&2
      return 1
    }
    if [[ -z "$target" ]]; then
      echo "오류: symlink target 이 비어 있습니다: '$path'" >&2
      return 1
    fi
    case "$target" in
      /*) path="$target" ;;
      *)  dir="$(dirname "$path")"; path="${dir%/}/${target}" ;;
    esac
  done
  if [[ ! -e "$path" ]]; then
    echo "오류: symlink '$1' 의 최종 대상이 존재하지 않습니다: '$path'" >&2
    return 1
  fi
  printf '%s\n' "$path"
}

# 권한을 보존하며 교체한다. mktemp 는 0600 으로 만들므로 그대로 mv 하면 원본 권한을 잃는다.
# `chmod --reference` 는 GNU 전용이라 stat 으로 mode 를 읽어 적용한다 (BSD → GNU 폴백).
#
# **대상이 symlink 이면 링크 자체를 `mv` 로 갈아치우지 않는다.** `mv` 는 링크를 지우고 그
# 자리에 regular file 을 놓으므로, 사용자가 `workflow.json` 을 dotfile 저장소 등으로 링크해
# 둔 경우 링크가 조용히 사라지고 원본과의 연결이 끊긴다.
# 그래서 링크가 최종적으로 가리키는 **referent 를 해석해 그 옆에 임시 파일을 만들고 `mv` 로
# 원자 교체**한다. 이렇게 하면 링크 정체성(링크는 그대로 남는다)과 원자성(교체는 같은
# 파일시스템 안의 rename 이라 중간 상태가 관찰되지 않는다)을 동시에 지킨다. 임시 파일을
# 링크가 놓인 디렉터리에 만들면 referent 와 파일시스템이 달라 rename 이 복사+삭제로 떨어지고
# 원자성이 깨지므로, 반드시 referent 쪽에 만든다.
# 실패하면 임시 파일만 지우고 referent 의 기존 내용을 그대로 남긴 채 비영을 반환한다.
_replace_preserving_mode() {
  local tmp="$1" target="$2" mode referent rtmp
  if [[ -L "$target" ]]; then
    referent="$(_resolve_symlink "$target")" || {
      echo "오류: '$target' 의 링크 대상을 해석하지 못해 아무것도 쓰지 않았습니다." >&2
      return 1
    }
    rtmp="$(_tmp_beside "$referent")" || {
      echo "오류: '$referent' 옆에 임시 파일을 만들지 못했습니다." >&2
      return 1
    }
    if ! cat "$tmp" > "$rtmp"; then
      rm -f "$rtmp"
      return 1
    fi
    mode="$(stat -f %Lp "$referent" 2>/dev/null || stat -c %a "$referent" 2>/dev/null || true)"
    [[ -n "$mode" ]] && chmod "$mode" "$rtmp" 2>/dev/null
    if ! mv "$rtmp" "$referent"; then
      rm -f "$rtmp"
      return 1
    fi
    rm -f "$tmp"
    return 0
  fi
  mode="$(stat -f %Lp "$target" 2>/dev/null || stat -c %a "$target" 2>/dev/null || true)"
  [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null
  mv "$tmp" "$target"
}

_insert_line_after() {
  # $1=file $2=line-number $3=content-to-insert
  local file="$1" lineno="$2" content="$3" tmp
  tmp="$(_tmp_beside "$file")" || return 1
  awk -v n="$lineno" -v ins="$content" '
    { print }
    NR == n { print ins }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  _replace_preserving_mode "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

ensure_id() {
  # $1=file
  local file="$1" existing
  existing="$(read_field "$file" "report-id")"
  if [[ -n "$existing" ]]; then
    if [[ "$existing" =~ ^[0-9]{14}-[0-9a-f]{6}$ ]]; then
      printf '%s\n' "$existing"
      return 0
    fi
    echo "오류: report-id 형식이 올바르지 않습니다 ('$existing'). 값을 고치거나 \`- report-id:\` 줄을 지운 뒤 재실행하십시오." >&2
    return 7
  fi

  local new_id line
  new_id="$(date +%Y%m%d%H%M%S)-$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"
  line="$(_insert_after_line "$file")"
  if _insert_line_after "$file" "$line" "- report-id: ${new_id}"; then
    printf '%s\n' "$new_id"
    return 0
  else
    echo "오류: '$file' 에 report-id 삽입 실패" >&2
    return 1
  fi
}

set_issue() {
  # $1=file $2=url
  local file="$1" url="$2" tmp
  if grep -q '^- upstream-issue:' "$file"; then
    tmp="$(_tmp_beside "$file")" || { echo "오류: 임시 파일 생성 실패" >&2; return 1; }
    sed "s|^- upstream-issue:.*\$|- upstream-issue: ${url}|" "$file" > "$tmp" \
      && _replace_preserving_mode "$tmp" "$file" \
      || { rm -f "$tmp"; echo "오류: '$file' upstream-issue 갱신 실패" >&2; return 1; }
  else
    local line
    line="$(grep -n '^- report-id:' "$file" | head -1 | cut -d: -f1)"
    if [[ -z "$line" ]]; then
      line="$(_insert_after_line "$file")"
    fi
    _insert_line_after "$file" "$line" "- upstream-issue: ${url}" \
      || { echo "오류: '$file' upstream-issue 삽입 실패" >&2; return 1; }
  fi
  return 0
}

# ---- upstream 설정 (config) --------------------------------------------

# JSON 구조 검사기를 탐지합니다. `python3` 이 있으면 그것을 쓰고, 없으면 비영을 냅니다.
# **`python3` 을 이 스크립트의 필수 의존성으로 선언하지 않습니다** — 없으면 config 기반 자동
# 판정(설정·발행 대상)을 모두 보류할 뿐, 명시적 `--upstream` 경로는 그대로 동작합니다.
_json_checker() {
  command -v python3 >/dev/null 2>&1
}

# 파일을 **구조적으로** 읽어 최상위 object 여부와 top-level `defect_report_upstream` 을 답합니다.
# 정규식과 달리 중첩 object 안의 동명 키를 top-level 로 오인하지 않고, 중복 top-level 키를
# 판정 불가로 처리합니다 (`object_pairs_hook` 로 쌍 목록을 그대로 받아 검사합니다).
# $1=파일
#   0 = 최상위 object + top-level 키 존재 (stdout 에 문자열 값)
#   3 = 최상위 object + top-level 키 없음
#   2 = 구조 검사기 없음 (판정 자체가 불가능)
#   1 = 판정 불가 (JSON 파싱 실패 · 최상위가 object 아님 · 중복 top-level 키 · 값이 문자열 아님)
_json_top_upstream() {
  local file="$1" rc
  _json_checker || return 2
  python3 - "$file" <<'PY'
import json, sys


class Obj(dict):
    pass


def hook(pairs):
    o = Obj(pairs)
    keys = [k for k, _ in pairs]
    o.dup = len(keys) != len(set(keys))
    return o


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh, object_pairs_hook=hook)
except Exception:
    sys.exit(1)
if not isinstance(data, Obj):
    sys.exit(4)          # 최상위가 object 가 아닙니다 (배열·스칼라)
if data.dup:
    sys.exit(5)          # 최상위에 같은 키가 두 번 — 어느 쪽이 유효한지 판정하지 않습니다
if "defect_report_upstream" not in data:
    sys.exit(3)
value = data["defect_report_upstream"]
if not isinstance(value, str):
    sys.exit(6)
sys.stdout.write(value)
PY
  rc=$?
  case "$rc" in
    0|2|3) return "$rc" ;;
    *)     return 1 ;;
  esac
}

# config 의 top-level `defect_report_upstream` 을 **구조적으로만** 읽습니다.
# $1 없음 -> stdout 에 값(있을 때만). 종료 상태가 계약입니다.
#   0 = top-level 에 비어 있지 않은 문자열 값이 있습니다 (stdout 에 값)
#   3 = 값이 없습니다 (config 파일 부재 · top-level 키 없음 · 빈 문자열)
#   2 = **판정 불가** — JSON 구조 검사기(python3)가 없습니다
#   1 = **판정 불가** — 파싱 실패 · 최상위가 object 아님 · top-level 중복 키 · 값이 문자열 아님
#
# **정규식 폴백을 두지 않습니다.** 정규식은 중첩 object 안의 동명 키를 top-level 로 오인하는데,
# 이 값은 `set_upstream` 의 「이미 설정됨」 판정과 **발행 대상 판정** 양쪽에 쓰입니다. 오인하면
# 인자 없는 `publish --yes` 가 사용자가 승인한 적 없는 외부 저장소로 결함 보고를 내보냅니다.
# 「읽기 전용이라 오판해도 보류로 이어질 뿐」이라는 종전 근거는 틀렸습니다 — 검증할 수 없으면
# 값을 추측하지 않고 「판정 불가」를 알려, 호출자가 「미설정」과 다르게 다루게 합니다.
cfg_upstream() {
  [[ -f "$CONFIG_FILE" ]] || return 3
  local val rc
  val="$(_json_top_upstream "$CONFIG_FILE")"; rc=$?
  case "$rc" in
    0)
      [[ -n "$val" ]] || return 3
      printf '%s\n' "$val"
      return 0
      ;;
    3) return 3 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

sync_template_bin() {
  bash "$SCRIPT_DIR/sync_template.sh" "$@"
}

# 교체 후보(임시 파일)가 실제로 쓸 만한 결과인지 **교체 전에** 구조적으로 확인합니다.
# 쓰기와 같은 정규식으로 확인하면 "정규식이 스스로를 검사" 하는 꼴이라, 중첩 object 안의 동명
# 키를 고쳐 놓고도 통과합니다. 그래서 파서로 최상위 object 여부와 **top-level 키의 값**을 봅니다.
# $1=임시 파일 $2=기대하는 canonical 값
_verify_upstream_result() {
  local candidate="$1" expected="$2" got rc
  got="$(_json_top_upstream "$candidate")"; rc=$?
  [[ "$rc" -eq 0 ]] || return 1
  [[ "$got" == "$expected" ]] || return 1
  return 0
}

set_upstream() {
  # $1=url
  local url="${1:-}" current canonical tmp gen_rc=0

  # config 파일을 새로 만들지 않습니다 — 생성은 이 스크립트의 책임이 아니고,
  # 배포는 템플릿 sync 5단계가 합니다. 그러므로 sync 를 거친 프로젝트에서는 이 경로가
  # 이미 있으며, 그래도 없는 경우(sync 밖에서 이 스크립트를 직접 호출한 경우)에는
  # 만들지 않고 건너뜁니다.
  # 조용한 exit 0 은 호출자가 "설정됐다" 고 오인하므로 사유와 대안을 함께 냅니다.
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "'$CONFIG_FILE' 이 없어 건너뜁니다 (이 스크립트는 설정 파일을 만들지 않습니다 — 배포는 템플릿 sync 5단계가 합니다)."
    echo "  전달 대상을 지정하려면 발행 시 --upstream <owner/repo> 를 주십시오."
    return 0
  fi

  local cfg_rc
  current="$(cfg_upstream)"; cfg_rc=$?

  # ── 구조 검사기가 없으면 **아무것도 쓰지 않고 보류합니다** (exit 0).
  #
  # 이 분기는 「이미 설정됨」 판정보다 **먼저** 옵니다. 검사기가 없으면 현재 값이 top-level 에
  # 있는지조차 알 수 없어, 중첩 object 안의 동명 키를 보고 「이미 설정됨」으로 거짓 성공한 뒤
  # 이 안내에 닿지 못했습니다.
  # **exit 0 인 이유**: 이것은 환경 조건이지 사용자 오류가 아니고, config 부재 시 exit 0 으로
  # 건너뛰는 기존 계약과 같은 성격이며, 템플릿 sync 5.1 이 여기서 멈추면 안 되기 때문입니다.
  if [[ "$cfg_rc" -eq 2 ]]; then
    canonical="$(sync_template_bin --print-upstream "$url" 2>/dev/null)" || canonical=""
    echo "JSON 구조 검증기(python3)가 없어 '$CONFIG_FILE' 을 고치지 않고 보류합니다."
    echo "  현재 값을 구조적으로 확인할 수 없어 이미 설정됐는지도 판정하지 않습니다 (추측하지 않습니다)."
    if [[ -n "$canonical" ]]; then
      echo "  수동 설정: '$CONFIG_FILE' 의 **최상위**에 \"defect_report_upstream\": \"${canonical}\" 을 직접 추가하십시오."
      echo "  또는 발행 시 --upstream ${canonical} 를 주십시오."
    else
      echo "  수동 설정: '$CONFIG_FILE' 의 **최상위**에 \"defect_report_upstream\": \"<owner/repo>\" 를 직접 추가하십시오."
      echo "  또는 발행 시 --upstream <owner/repo> 를 주십시오."
    fi
    return 0
  fi

  if [[ "$cfg_rc" -eq 0 && -n "$current" ]]; then
    echo "이미 설정됨: $current"
    return 0
  fi

  canonical="$(sync_template_bin --print-upstream "$url" 2>/dev/null)"
  if [[ $? -ne 0 || -z "$canonical" ]]; then
    echo "오류: '$url' 에서 전달 대상을 유도할 수 없습니다. defect_report_upstream 값을 수동으로 설정하십시오." >&2
    return 1
  fi

  # ── 쓰기 **전에** 원본이 유효한 JSON object 인지 구조적으로 확인합니다.
  # 여기서 걸리는 것: 파싱 실패(malformed) · 최상위가 object 아님(배열 등) · 중복 top-level 키 ·
  # 키 값이 문자열이 아님. 어느 쪽이든 **아무것도 쓰지 않습니다.**
  local pre_rc
  _json_top_upstream "$CONFIG_FILE" >/dev/null; pre_rc=$?
  if [[ "$pre_rc" -ne 0 && "$pre_rc" -ne 3 ]]; then
    echo "오류: '$CONFIG_FILE' 을 구조적으로 읽을 수 없어 아무것도 쓰지 않았습니다 (원본 그대로)." >&2
    echo "      유효한 JSON object 가 아니거나, 최상위에 defect_report_upstream 키가 중복됩니다." >&2
    echo "      조치 : '$CONFIG_FILE' 을 고친 뒤, 또는 발행 시 --upstream ${canonical} 로 지정하십시오." >&2
    return 1
  fi

  tmp="$(_tmp_beside "$CONFIG_FILE")" || { echo "오류: 임시 파일 생성 실패" >&2; return 1; }
  # 분기는 **구조적 판정**으로 정합니다. `grep` 은 중첩 object 안의 동명 키에도 걸려, 키가
  # top-level 에 없는데도 치환 경로로 보내 남의 값을 고칩니다.
  if [[ "$pre_rc" -eq 0 ]]; then
    # `sed` 는 구조를 모릅니다 — 같은 이름의 키가 파일 안에 둘 이상이면(중첩 object 등)
    # 어느 쪽이 바뀔지 보장할 수 없으므로 치환하지 않고 보류합니다.
    local key_hits
    key_hits="$(grep -o '"defect_report_upstream"' "$CONFIG_FILE" | grep -c . || true)"
    if [[ "$key_hits" != "1" ]]; then
      rm -f "$tmp"
      echo "오류: '$CONFIG_FILE' 안에 defect_report_upstream 이 여러 곳에 나타나 안전하게 치환할 수 없습니다 (원본 그대로)." >&2
      echo "      조치 : 최상위 값을 직접 \"${canonical}\" 로 고치십시오." >&2
      return 1
    fi
    sed "s|\"defect_report_upstream\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"defect_report_upstream\": \"${canonical}\"|" \
      "$CONFIG_FILE" > "$tmp" || gen_rc=1
  else
    # **줄 배치를 전제하지 않는다.** 이전 구현은 "1행에 `{` 가 있으면 그 행 전체를 출력한 뒤
    # 키 줄을 붙이는" 방식이라, 한 줄 객체(`{"a":"b"}`)에서는 완성된 객체 뒤에 멤버를 붙여
    # invalid JSON 을 만들고, 첫 줄이 빈 줄이면 아무것도 삽입하지 않은 채 성공을 보고했다.
    # 그래서 여는 `{` 를 **위치로** 찾아 바로 뒤에 넣는다.
    #   - `{` 가 그 줄의 마지막 유의미 문자면 기존 pretty-printed 형식을 지켜 다음 줄에 삽입
    #   - 그렇지 않으면(한 줄 객체 등) `{` 바로 뒤에 인라인 삽입
    #   - 빈 객체면 뒤따르는 쉼표를 넣지 않아야 유효하다
    # 여는 `{` 가 없으면(배열·잘린 파일 등) 아무것도 쓰지 않고 실패한다.
    local compact empty_obj=0
    compact="$(tr -d '[:space:]' < "$CONFIG_FILE")"
    [[ "$compact" == "{}" ]] && empty_obj=1
    awk -v val="$canonical" -v empty="$empty_obj" '
      BEGIN { inserted = 0; sep = (empty == 1 ? "" : ",") }
      inserted { print; next }
      /^[[:space:]]*$/ { print; next }
      {
        lead = $0
        sub(/[^[:space:]].*$/, "", lead)
        pos = length(lead) + 1
        if (substr($0, pos, 1) != "{") { exit 3 }
        head = substr($0, 1, pos)
        rest = substr($0, pos + 1)
        if (rest ~ /^[[:space:]]*$/) {
          print head rest
          print "  \"defect_report_upstream\": \"" val "\"" sep
        } else {
          print head "\"defect_report_upstream\": \"" val "\"" sep rest
        }
        inserted = 1
        next
      }
      END { if (inserted == 0) exit 3 }
    ' "$CONFIG_FILE" > "$tmp" || gen_rc=1
  fi

  # 생성 실패거나, 결과가 계약을 만족하지 못하면 **원본 bytes 를 그대로 둔 채** 실패한다.
  if [[ "$gen_rc" -ne 0 ]] || ! _verify_upstream_result "$tmp" "$canonical"; then
    rm -f "$tmp"
    echo "오류: '$CONFIG_FILE' 에 defect_report_upstream 을 안전하게 넣지 못했습니다 (원본은 변경하지 않았습니다)." >&2
    echo "      여는 '{' 를 찾지 못했거나 결과가 유효한 JSON 이 아닙니다." >&2
    echo "      조치 : '$CONFIG_FILE' 을 열어 \"defect_report_upstream\": \"${canonical}\" 을 직접 추가하십시오." >&2
    return 1
  fi

  if ! _replace_preserving_mode "$tmp" "$CONFIG_FILE"; then
    rm -f "$tmp"
    echo "오류: '$CONFIG_FILE' 갱신 실패" >&2
    return 1
  fi
  return 0
}

# ---- 발행 대상 판정 ------------------------------------------------------

valid_target() {
  # $1=owner/repo 또는 host/owner/repo. '/' 개수로 세지 않고 세그먼트 문자를 그대로 검사한다.
  local t="$1"
  [[ "$t" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && return 0
  [[ "$t" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && return 0
  return 1
}

_slash_count() {
  local t="$1"
  printf '%s' "$t" | tr -cd '/' | wc -c | tr -d ' '
}

target_host() {
  local t="$1"
  if [[ "$(_slash_count "$t")" -eq 1 ]]; then
    printf '%s\n' "github.com"
  else
    printf '%s\n' "${t%%/*}"
  fi
}

target_repo() {
  local t="$1"
  if [[ "$(_slash_count "$t")" -eq 1 ]]; then
    printf '%s\n' "$t"
  else
    printf '%s\n' "${t#*/}"
  fi
}

# $1=--upstream 인자(없으면 빈 문자열). 유효하면 stdout 에 target, 무효/미설정이면 exit 1(무출력).
# **명시적 `--upstream` 은 구조 검사기 유무와 무관하게 동작합니다.** config 에서 대상을 고르는
# 것은 검사기가 있고 top-level 값을 확실히 읽었을 때뿐입니다 — 판정 불가(검사기 부재·파싱 실패·
# 최상위 비 object·top-level 중복 키)는 「대상 없음」으로 fail-closed 합니다. 추측한 값으로
# 발행하면 사용자가 승인한 적 없는 저장소에 결함 보고가 나갑니다.
resolve_target() {
  local arg="${1:-}" target rc
  if [[ -n "$arg" ]]; then
    valid_target "$arg" || return 1
    printf '%s\n' "$arg"
    return 0
  fi
  target="$(cfg_upstream)"; rc=$?
  case "$rc" in
    0) ;;
    2)
      echo "참고: JSON 구조 검증기(python3)가 없어 '$CONFIG_FILE' 의 전달 대상을 판정하지 않았습니다 (추측하지 않습니다)." >&2
      echo "      발행하려면 --upstream <owner/repo> 로 대상을 직접 지정하십시오." >&2
      return 1
      ;;
    1)
      echo "참고: '$CONFIG_FILE' 을 구조적으로 읽을 수 없어 전달 대상을 판정하지 않았습니다 (fail-closed)." >&2
      echo "      발행하려면 --upstream <owner/repo> 로 대상을 직접 지정하십시오." >&2
      return 1
      ;;
    *) return 1 ;;
  esac
  [[ -n "$target" ]] && valid_target "$target" || return 1
  printf '%s\n' "$target"
}

gh_run() {
  local host="$1"; shift
  if [[ "$host" == "github.com" ]]; then
    gh "$@"
  else
    GH_HOST="$host" gh "$@"
  fi
}

visibility_of() {
  local host="$1" repo="$2" out
  # gh repo view 는 저장소를 위치 인자로 받는다 (--repo 플래그는 존재하지 않는다).
  out="$(gh_run "$host" repo view "$repo" --json visibility 2>/dev/null)" || return 1
  printf '%s\n' "$out" | sed -n 's/.*"visibility"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

search_matches() {
  # $1=host $2=repo $3=id -> 일치하는 Issue URL 을 개행 구분으로 출력. jq 는 gh 내장 --jq 사용.
  #
  # **종료 상태가 계약의 일부입니다.** 조회 실패(네트워크·API·권한·서비스 오류)를 "일치 없음"
  # 으로 흘리면 기존 Issue 가 있어도 새로 만들어 중복이 생깁니다 — 이 기능의 존재 이유가
  # 무너집니다. 호출자는 종료 상태를 먼저 보고, 실패면 발행하지 않아야 합니다.
  #   0    = 조회 성공 (stdout 이 비어 있으면 진짜 0건)
  #   그 외 = 조회 실패 (0건과 구별 불가 — fail-closed)
  local host="$1" repo="$2" id="$3"
  gh_run "$host" issue list --repo "$repo" --state all \
    --search "${id} in:body" --json url,body \
    --jq ".[] | select(.body | contains(\"<!-- rd-defect-id: ${id} -->\")) | .url"
}

issue_title() {
  local file="$1" first_line
  first_line="$(head -1 "$file")" || return 1
  printf '[defect] %s' "${first_line#"# rd-workflow 결함 보고: "}"
}

issue_body() {
  # $1=file $2=id(표시용 — 실제 값 또는 preview 안내문)
  #
  # **필수 읽기는 전부 heredoc 밖에서 변수로 받고 실패를 비영으로 전파한다.**
  # heredoc 안의 명령 치환(`$(cat "$file")`)은 실패해도 바깥 `cat <<EOF` 의 성공 상태에
  # 가려진다. 그대로 두면 호출부의 `if ! issue_body ...` 가 통과해 원문이 빠진 Issue 를
  # 발행할 수 있다 (final diff review Turn 004 Finding 2).
  local file="$1" id="$2" version target_artifact original
  version="$(read_field "$file" "rd-workflow VERSION")" || return 1
  target_artifact="$(read_field "$file" "대상 산출물")" || return 1
  # 명령 치환은 뒤쪽 개행을 지우므로, heredoc 안에서 직접 치환했을 때와 바이트가 같다.
  original="$(cat "$file")" || return 1
  cat <<EOF
<!-- rd-defect-id: ${id} -->

| 항목 | 값 |
|---|---|
| report-id | ${id} |
| rd-workflow VERSION | ${version} |
| 대상 산출물 | ${target_artifact} |

---

${original}
EOF
}

print_pending_hint() {
  echo "미전달 목록: bash rd-workflow/scripts/defect_reports.sh list-pending" >&2
}

print_failure_hint() {
  # $1=file $2=재시도 시 보존할 옵션 문자열(빈 문자열 가능)
  #
  # **원래 대상과 승인 상태를 보존한다** (final diff review Turn 006 Finding 1).
  # - `--upstream` 을 떨어뜨리면 재시도가 config 대상으로 바뀌어 **다른 저장소에 발행**된다.
  #   config 가 `A/B` 인데 사용자가 `--upstream C/D` 로 실행했다가 실패한 경우가 그렇다.
  # - 승인 화면을 끝까지 보지 못한 실패에 `--yes` 를 붙이면 이 기능의 핵심인 발행 전 사람
  #   확인을 건너뛰게 한다. 그래서 `--yes` 는 **호출이 이미 승인 상태였을 때만** 붙인다.
  # 여기서 출력되는 대상 값은 모두 `resolve_target` 형식 검증을 통과한 값이다 — 검증 실패
  # 경로는 재시도 명령을 만들지 않고 `print_pending_hint` + 조치 안내만 낸다.
  print_pending_hint
  echo "재시도: bash rd-workflow/scripts/defect_reports.sh publish $1${2:+ $2}" >&2
}

render_preview() {
  # $1=file $2=host $3=repo $4=visibility $5=report-id(없으면 빈 문자열)
  local file="$1" host="$2" repo="$3" visibility="$4" existing_id="$5" id_display title body
  id_display="${existing_id:-(발행 시 생성)}"
  # 승인 화면은 사람이 발행 여부를 결정하는 유일한 근거다 — 읽기가 실패했다면 반쯤 만들어진
  # 화면을 보여주지 않고 실패한다. 호출 순서상 6번 크기 검사가 먼저 걸리지만, 순서가 바뀌어도
  # 화면이 거짓을 말하지 않도록 여기서도 막는다.
  if ! title="$(issue_title "$file")" || ! body="$(issue_body "$file" "$id_display")"; then
    echo "오류: 승인 화면 생성 실패(보고서 읽기 실패). 아무것도 발행하지 않았습니다." >&2
    return 1
  fi
  printf '전달 대상 : %s / %s   [%s]\n' "$host" "$repo" "$visibility"
  if [[ "$visibility" == "PUBLIC" ]]; then
    printf '⚠ 공개 저장소입니다 — 경로·프로젝트명이 공개됩니다.\n'
  fi
  printf '제목      : %s\n' "$title"
  printf '라벨      : defect-report (권한이 없으면 부착만 실패하고 Issue 는 생성됩니다)\n'
  printf -- '--- 본문 ---\n%s\n' "$body"
}

# ---- preview / publish --------------------------------------------------

# 옵션 파서 — preview/publish 공용.
# `--upstream` 뒤 값이 없을 때 `shift 2` 는 실패하고, `set -e` 가 아니므로 같은 인자가
# 남아 while 이 무한 반복한다 (final diff review Finding 4). 값 유무와 미지원 옵션을
# 명시적으로 검증해 즉시 종료한다.
_parse_publish_opts() {
  # 결과를 전역 OPT_UPSTREAM / OPT_YES 에 담는다. 인자 오류면 return 2.
  OPT_UPSTREAM=""; OPT_YES=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upstream)
        if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
          echo "오류: --upstream 에 값이 필요합니다." >&2
          echo "사용법: defect_reports.sh publish|preview <file> [--upstream <owner/repo|host/owner/repo>] [--yes]" >&2
          return 2
        fi
        OPT_UPSTREAM="$2"; shift 2 ;;
      --yes) OPT_YES=1; shift ;;
      *)
        echo "오류: 알 수 없는 옵션입니다: '$1'" >&2
        echo "사용법: defect_reports.sh publish|preview <file> [--upstream <owner/repo|host/owner/repo>] [--yes]" >&2
        return 2 ;;
    esac
  done
  return 0
}

cmd_preview() {
  local file="${1:-}"; shift || true
  _parse_publish_opts "$@" || return 2
  local upstream_arg="$OPT_UPSTREAM"

  local target
  if ! target="$(resolve_target "$upstream_arg")"; then
    echo "오류: 전달 대상이 설정되지 않았거나 형식이 올바르지 않습니다." >&2
    return 2
  fi
  local host repo
  host="$(target_host "$target")"
  repo="$(target_repo "$target")"

  if ! command -v gh >/dev/null 2>&1; then
    echo "오류: gh CLI 를 찾을 수 없습니다. https://cli.github.com/ 에서 설치하십시오." >&2
    return 4
  fi
  if ! gh_run "$host" auth status >/dev/null 2>&1; then
    echo "오류: '$host' 에 인증되지 않았습니다. 'gh auth login --hostname $host' 를 실행하십시오." >&2
    return 4
  fi

  local visibility
  visibility="$(visibility_of "$host" "$repo")"
  if [[ -z "$visibility" ]]; then
    echo "오류: '$host/$repo' 의 공개 여부를 확인할 수 없습니다 (fail-closed)." >&2
    return 3
  fi

  local existing_id
  existing_id="$(read_field "$file" "report-id")"
  # 화면 생성 실패를 성공으로 보고하지 않는다 — publish 와 달리 이 경로에는 앞선 크기
  # 검사가 없어, 원문이 빠진 화면이 그대로 승인 근거가 될 수 있다 (Turn 004 Finding 2).
  render_preview "$file" "$host" "$repo" "$visibility" "$existing_id" || return 7
  return 0
}

cmd_publish() {
  local file="${1:-}"; shift || true
  _parse_publish_opts "$@" || return 2
  local upstream_arg="$OPT_UPSTREAM" yes="$OPT_YES"

  # 1. 대상 결정 (읽기 전용, gh 호출 없음)
  local target
  if ! target="$(resolve_target "$upstream_arg")"; then
    echo "오류: 전달 대상이 설정되지 않았거나 형식이 올바르지 않습니다." >&2
    # 이 경로에서는 재시도 명령을 만들지 않는다 — 대상 값 자체가 무효라서 그 값을 되돌려
    # 제시하면 같은 실패를 반복하게 하고, 값을 떨어뜨리면 config 대상으로 바꿔치기가 된다.
    print_pending_hint
    echo "조치 : --upstream 값 또는 config 의 defect_report_upstream 을 고친 뒤 다시 실행하십시오." >&2
    return 2
  fi

  # 실패 안내가 **이번 실행이 실제로 겨냥한 대상(effective target)** 과 승인 상태를 잃지
  # 않게 보존한다 (Turn 006 Finding 1, Turn 008 Finding 1).
  #
  # `--upstream` 을 준 경우만 보존하면 부족하다. config 로 대상을 정한 실행이 실패한 뒤
  # config 가 바뀌면(사람 편집·템플릿 동기화), 대상 없는 안내를 그대로 따라 **사용자가
  # 승인 화면에서 본 적 없는 저장소로 발행**된다. 그래서 해소된 `$target` 을 항상 고정한다.
  # 여기 오는 `$target` 은 `resolve_target` 형식 검증을 통과한 값이다.
  local retry_opts="--upstream $target"
  [[ -n "$yes" ]] && retry_opts="$retry_opts --yes"
  local host repo
  host="$(target_host "$target")"
  repo="$(target_repo "$target")"

  # 2. 로컬 상태 — fast path
  local upstream_val unknown=0
  upstream_val="$(read_field "$file" "upstream-issue")"
  case "$upstream_val" in
    https://*)
      echo "이미 전달됨: $upstream_val"
      return 0
      ;;
    attempting:*)
      unknown=1
      ;;
  esac

  # 3. report-id 읽기 전용 검증 — gh 가용성 확인보다 앞선다 (malformed 시 gh 호출 0회)
  local existing_id
  existing_id="$(read_field "$file" "report-id")"
  if [[ -n "$existing_id" && ! "$existing_id" =~ ^[0-9]{14}-[0-9a-f]{6}$ ]]; then
    echo "오류: report-id 형식이 올바르지 않습니다 ('$existing_id'). 값을 고치거나 \`- report-id:\` 줄을 지운 뒤 재실행하십시오." >&2
    return 7
  fi

  # 4. gh 가용성
  if ! command -v gh >/dev/null 2>&1; then
    echo "오류: gh CLI 를 찾을 수 없습니다. https://cli.github.com/ 에서 설치하십시오." >&2
    print_failure_hint "$file" "$retry_opts"
    return 4
  fi
  if ! gh_run "$host" auth status >/dev/null 2>&1; then
    echo "오류: '$host' 에 인증되지 않았습니다. 'gh auth login --hostname $host' 를 실행하십시오." >&2
    print_failure_hint "$file" "$retry_opts"
    return 4
  fi

  # 5. visibility (fail-closed)
  local visibility
  visibility="$(visibility_of "$host" "$repo")"
  if [[ -z "$visibility" ]]; then
    echo "오류: '$host/$repo' 의 공개 여부를 확인할 수 없습니다 (fail-closed)." >&2
    print_failure_hint "$file" "$retry_opts"
    return 3
  fi

  # 6. 본문 크기 (60,000 byte)
  #
  # **발행 시점의 최종 본문을 재야 한다.** 현재 파일로만 재면 한도 바로 아래인 보고서가
  # 검사를 통과한 뒤 한도를 넘겨 발행될 수 있다 (final diff review Finding 2).
  #
  # 최종 본문 = 머리말(실제 id 삽입) + **8번 ensure-id 직후의 파일 내용**.
  # `attempting:` 기록(10-b)은 payload 생성(10-a) **뒤**이므로 본문에 들어가지 않는다.
  # 따라서 증가분은 legacy 파일에 report-id 한 줄이 붙는 경우뿐이며, 그 줄은 길이가
  # 고정이라 산술로 정확히 계산된다 — "- report-id: "(13) + id(21) + 개행(1) = 35 byte.
  local size_check_id body_size delta=0
  size_check_id="${existing_id:-00000000000000-000000}"   # 21자 — 실제 id 와 같은 길이
  # 본문 생성 실패를 크기로 흘려보내지 않는다 — 실패한 본문은 짧아서 한도 검사를 통과한다.
  # `set -o pipefail` 이 있으므로 issue_body 실패가 파이프라인 실패로 드러난다.
  if ! body_size="$(issue_body "$file" "$size_check_id" | wc -c | tr -d ' ')"; then
    echo "오류: 발행 본문 생성 실패(보고서 읽기 실패). 로컬·원격 모두 변경하지 않았습니다." >&2
    print_failure_hint "$file" "$retry_opts"
    return 7
  fi
  [[ -z "$existing_id" ]] && delta=35
  body_size=$((body_size + delta))
  if (( body_size > 60000 )); then
    echo "오류: 발행 시점 본문이 60,000 byte 를 초과합니다 (${body_size} byte)." >&2
    print_failure_hint "$file" "$retry_opts"
    return 6
  fi

  # 7. --yes 없으면 preview 출력 후 종료 (로컬/원격 쓰기 없음)
  if [[ -z "$yes" ]]; then
    render_preview "$file" "$host" "$repo" "$visibility" "$existing_id" || {
      print_failure_hint "$file" "$retry_opts"; return 7
    }
    return 5
  fi

  # -- 승인 후 (쓰기 시작) --

  # 8. ensure-id
  local id ensure_rc
  id="$(ensure_id "$file")"; ensure_rc=$?
  if [[ $ensure_rc -ne 0 ]]; then
    # 쓰기 실패는 원격 무변경이므로 재시도가 안전하다 — 공통 안내를 붙인다.
    print_failure_hint "$file" "$retry_opts"
    return 7
  fi

  # 9. 식별자 정확 일치 검색
  #
  # 조회 실패와 "0건" 을 반드시 분리한다. 실패를 0건으로 오인하면 기존 Issue 가 있어도
  # 새로 만들어 중복이 생긴다 (final diff review Finding 1).
  local search_out search_rc match_count
  search_out="$(search_matches "$host" "$repo" "$id" 2>/dev/null)"; search_rc=$?
  if [[ $search_rc -ne 0 ]]; then
    echo "오류: report-id $id 의 기존 Issue 조회에 실패했습니다 (gh issue list rc=$search_rc)." >&2
    echo "      중복 여부를 확인할 수 없어 발행하지 않았습니다 (fail-closed)." >&2
    print_failure_hint "$file" "$retry_opts"
    return 3
  fi
  if [[ -z "$search_out" ]]; then
    match_count=0
  else
    match_count="$(printf '%s\n' "$search_out" | grep -c .)"
  fi

  if [[ "$match_count" -ge 2 ]]; then
    echo "오류: report-id $id 와 일치하는 Issue 가 여러 건 발견되어 자동으로 연결하지 않습니다. 후보:" >&2
    printf '%s\n' "$search_out" >&2
    # 일반 재시도는 같은 모호함을 반복할 뿐이다 — 후보 선택 후 연결을 안내한다
    # (final diff review Finding 5).
    echo "  조치 : 위 후보 중 하나를 고른 뒤 아래를 실행하십시오." >&2
    echo "         bash rd-workflow/scripts/defect_reports.sh set-issue $file <고른-url>" >&2
    echo "  참고 : 미전달 목록 — bash rd-workflow/scripts/defect_reports.sh list-pending" >&2
    return 8
  fi

  if [[ "$match_count" -eq 1 ]]; then
    local found_url
    found_url="$(printf '%s\n' "$search_out" | head -1)"
    if set_issue "$file" "$found_url"; then
      echo "전달 완료(기존 Issue 연결): $found_url"
      return 0
    else
      echo "원격 Issue 는 이미 존재하지만 로컬 기록에 실패했습니다." >&2
      echo "  Issue: $found_url" >&2
      echo "  복구 : bash rd-workflow/scripts/defect_reports.sh set-issue $file $found_url" >&2
      return 10
    fi
  fi

  # match_count == 0
  if [[ "$unknown" -eq 1 ]]; then
    cat >&2 <<EOF
이전 발행 시도의 결과를 확인하지 못했습니다 (${upstream_val}).
  확인 : 대상 repo 에서 report-id $id 를 검색하십시오. 검색 인덱싱은 수 분 지연될 수 있어
         "지금 안 보임" 은 "생성되지 않음" 이 아닙니다.
  Issue 가 있으면 : bash rd-workflow/scripts/defect_reports.sh set-issue $file <url>
  없다고 확인되면 : 파일의 \`- upstream-issue: -\` 로 되돌린 뒤 재실행하십시오.
EOF
    return 11
  fi

  # 10-a. payload 준비 — attempting 기록보다 **앞**에 온다.
  #
  # 순서를 뒤집으면 mktemp·본문 생성 실패만으로 파일에 attempting: 이 남아, 생성된 적
  # 없는 원격 Issue 를 사람이 찾아 헤매게 된다 (final diff review Finding 3).
  # 여기서 실패하면 로컬·원격 모두 무변경이므로 재시도가 안전하다.
  local tmp_body title created_url create_rc
  tmp_body="$(mktemp)" || {
    echo "오류: 임시 파일 생성 실패. 로컬·원격 모두 변경하지 않았습니다." >&2
    print_failure_hint "$file" "$retry_opts"; return 7
  }
  if ! issue_body "$file" "$id" > "$tmp_body"; then
    rm -f "$tmp_body"
    echo "오류: 발행 본문 생성 실패. 로컬·원격 모두 변경하지 않았습니다." >&2
    print_failure_hint "$file" "$retry_opts"; return 7
  fi
  if ! title="$(issue_title "$file")"; then
    rm -f "$tmp_body"
    echo "오류: 발행 제목 생성 실패. 로컬·원격 모두 변경하지 않았습니다." >&2
    print_failure_hint "$file" "$retry_opts"; return 7
  fi

  # 10-b. attempting 기록 — gh issue create 직전
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  if ! set_issue "$file" "attempting:${ts}"; then
    rm -f "$tmp_body"
    echo "오류: 발행 시도 기록에 실패했습니다. 원격 Issue 를 생성하지 않았습니다." >&2
    # 원격 무변경이 확실하므로 재시도가 안전하다.
    print_failure_hint "$file" "$retry_opts"
    return 7
  fi

  # 11. gh issue create (라벨 없이 1회만 — 재시도하지 않는다)
  created_url="$(gh_run "$host" issue create --repo "$repo" --title "$title" --body-file "$tmp_body" 2>/dev/null)"
  create_rc=$?
  rm -f "$tmp_body"
  if [[ $create_rc -ne 0 || -z "$created_url" ]]; then
    echo "오류: gh issue create 실패. upstream-issue 는 attempting: 상태로 남아 다음 실행에서 결과를 확인합니다." >&2
    print_failure_hint "$file" "$retry_opts"
    return 9
  fi
  created_url="$(printf '%s\n' "$created_url" | head -1)"

  # 12. 라벨 부착 (best-effort — 실패해도 발행 자체는 유지하되 조용히 넘어가지 않는다)
  if ! gh_run "$host" issue edit "$created_url" --add-label defect-report >/dev/null 2>&1; then
    cat >&2 <<EOF
전달 완료(라벨 미부착): $created_url
  라벨 defect-report 를 붙이지 못했습니다. 이 상태로는 정본 /fr pull 의 흡수 대상이
  아닙니다. maintainer 가 라벨을 붙여야 검토 대기열에 올라갑니다.
EOF
  fi

  # 13. 역기록
  if ! set_issue "$file" "$created_url"; then
    cat >&2 <<EOF
원격 Issue 는 생성됐지만 로컬 기록에 실패했습니다.
  Issue: $created_url
  복구 : bash rd-workflow/scripts/defect_reports.sh set-issue $file $created_url
EOF
    return 10
  fi

  echo "전달 완료: $created_url"
  return 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    list-pending)
      list_pending
      ;;
    count-pending)
      count_pending
      ;;
    ensure-id)
      shift
      ensure_id "${1:-}"
      ;;
    set-issue)
      shift
      set_issue "${1:-}" "${2:-}"
      ;;
    set-upstream)
      shift
      set_upstream "${1:-}"
      ;;
    preview)
      shift
      cmd_preview "$@"
      ;;
    publish)
      shift
      cmd_publish "$@"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
