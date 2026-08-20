#!/usr/bin/env bash
# _smoke_common.sh — self_test.sh smoke 경로의 판정 헬퍼 모음입니다.
#
# 이 파일은 **함수 정의만** 두고 최상위 실행 코드를 두지 않습니다. self_test.sh 는 상단부터
# 실행이 이어지는 구조라 source 로 격리 검증할 수 없어, 판정 로직을 이 파일로 분리해야
# test_smoke_common.sh 가 함수 단위로 검증할 수 있습니다.
#
# bash 3.2 호환: 연관배열을 쓰지 않고 인덱스 배열·개행 구분 문자열만 씁니다.

SMOKE_CHANGED_FILES=()

# stdin 을 sha256 hex 한 줄로 요약합니다. 해시 도구가 없으면 1 을 반환합니다.
_smoke_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

# 워킹트리 변경 파일(수정·추가·삭제·rename 양쪽 경로·untracked)을 SMOKE_CHANGED_FILES 에
# repo-root 상대 경로로 채웁니다.
# return 0 = 수집 성공, 1 = 폴백 필요(git 실패 / 미인식 status / 필드 부족).
smoke_collect_changed_files() {
  local root="$1"
  SMOKE_CHANGED_FILES=()
  # NUL 스트림은 **변수에 담지 않습니다** — command substitution 은 NUL 을 조용히 버려
  # 필드 구분이 사라지고, 공백·개행 포함 경로 안전 계약이 그 자리에서 깨집니다.
  # 임시 파일로 받아야 git 의 종료 코드도 함께 회수할 수 있습니다(프로세스 치환은 rc 를 잃습니다).
  local tmp
  tmp="$(mktemp)" || return 1
  if ! git -C "$root" status --porcelain=v1 -z > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  local fields=() f
  while IFS= read -r -d '' f; do
    fields+=("$f")
  done < "$tmp"
  rm -f "$tmp"
  local i=0 entry x y path n
  n=${#fields[@]}   # 변경 0건이면 루프를 돌지 않고 빈 배열로 성공 반환합니다 (폴백 판정은 호출자 몫)
  while (( i < n )); do
    entry="${fields[i]}"
    # 최소 형식: "XY <path>" — 4자 미만이면 파싱 불능입니다.
    if (( ${#entry} < 4 )); then return 1; fi
    x="${entry:0:1}"; y="${entry:1:1}"; path="${entry:3}"
    if [[ "$x$y" == "??" ]]; then
      SMOKE_CHANGED_FILES+=("$path"); i=$((i + 1)); continue
    fi
    # 인식 가능한 status 만 허용합니다. U(unmerged)·그 밖의 문자는 폴백입니다.
    # 허용은 ' ' M A D R 과 ?? 뿐입니다. T(type change)·C(copy)·U(unmerged)는
    # 의미가 달라 성공 경로 테스트 없이 허용하면 조용한 오판정이 되므로 폴백합니다.
    case "$x" in ' '|M|A|D|R) ;; *) return 1 ;; esac
    case "$y" in ' '|M|A|D|R) ;; *) return 1 ;; esac
    SMOKE_CHANGED_FILES+=("$path")
    # rename/copy 는 -z 모드에서 "R  <신경로>\0<구경로>\0" 순으로 나옵니다 (실측 확인).
    # 구·신 경로를 **둘 다** 담습니다 — 어느 쪽이라도 관련 스텝이 있으면 실행해야 합니다.
    if [[ "$x" == R || "$y" == R ]]; then
      i=$((i + 1))
      if (( i >= n )); then return 1; fi
      SMOKE_CHANGED_FILES+=("${fields[i]}")
    fi
    i=$((i + 1))
  done
  return 0
}

SMOKE_SYNTAX_TARGETS=()
SMOKE_JOIN_ROOT=""

# 변경된 셸 스크립트 중 **실재하는** 파일의 절대 경로를 SMOKE_SYNTAX_TARGETS 에 채웁니다.
# 삭제된 파일과 rename 이전 경로는 `bash -n` 대상이 될 수 없으므로 제외합니다 — 남겨 두면
# 존재하지 않는 경로에서 무조건 구문 오류가 나 정상 변경이 실패로 보고됩니다.
#
# 경로를 정규화하지 않고 수집한 그대로 씁니다. 이 저장소에서 실제로 바뀐 파일은 정본이고
# 미러는 install-root 이후 별도 변경 항목으로 함께 잡히므로, 미러 경로로 접으면 아직
# 동기화하지 않은 상태에서 바뀐 적 없는 파일을 검사하고 정작 바뀐 정본을 놓칩니다.
#
# **조인 기준은 `$1` 이 아니라 그 경로가 속한 git 최상위입니다.** `SMOKE_CHANGED_FILES` 는
# `git status --porcelain` 산출이라 언제나 repo 최상위 상대 경로인데(`git -C <서브디렉터리>`
# 로 불러도 마찬가지입니다), 설치 루트가 최상위가 아니면(서브디렉터리 설치, 정본 트리를
# 직접 실행) 두 기준이 어긋나 **모든 경로가 존재하지 않게** 됩니다. 그러면 아래
# `[[ -f "$p" ]] || continue` 가 삭제 파일 필터와 구분 없이 전부 탈락시켜 검사 대상 0건으로
# **조용히 통과**합니다 — 변경된 파일의 구문 오류마저 놓치는, 축소 계약 밖의 손실입니다.
# 최상위를 구하지 못하는 경우(= git 저장소가 아님)는 실제 경로에서는 도달할 수 없습니다.
# 수집 단계가 이미 실패해 호출자가 full 로 폴백하기 때문이며, 단위 호출에서만 나타나므로
# 그때는 받은 루트를 그대로 씁니다.
#
# 두 경로가 **같은 디렉터리를 다르게 적은 것뿐**이면(symlink 경유 — macOS 의 임시
# 디렉터리가 대표적입니다) 받은 표기를 그대로 유지합니다. 같은 곳을 가리키는데도 표기를
# 갈아 끼우면 호출자가 넘긴 경로와 산출 경로가 문자열로 달라져, 경로를 대조하는 쪽이
# 이유 없이 깨집니다. 물리 경로까지 다를 때만 최상위로 바꿔 잡습니다.
#
# stdout 이 아니라 배열로 넘기는 이유: 개행이 든 경로를 줄 단위로 내면 존재하지 않는
# 두 경로로 쪼개져 정작 바뀐 파일을 검사하지 않게 됩니다 — 수집 단계의 NUL 안전성이
# 전달 단계에서 무너지면 의미가 없습니다.
smoke_changed_shell_files() {
  local root="$1" m p _top _phys
  SMOKE_SYNTAX_TARGETS=()
  _top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || _top=""
  _phys="$(cd "$root" 2>/dev/null && pwd -P)" || _phys=""
  if [[ -n "$_top" && -n "$_phys" && "$_top" != "$_phys" ]]; then
    SMOKE_JOIN_ROOT="$_top"
  else
    SMOKE_JOIN_ROOT="$root"
  fi
  for m in ${SMOKE_CHANGED_FILES[@]+"${SMOKE_CHANGED_FILES[@]}"}; do
    [[ "$m" == *.sh ]] || continue
    p="${SMOKE_JOIN_ROOT}/${m}"
    [[ -f "$p" ]] || continue
    SMOKE_SYNTAX_TARGETS+=("$p")
  done
  return 0
}

SMOKE_CLOSURE=()
SMOKE_SCRIPTS_INDEX=""
SMOKE_SCRIPTS_INDEX_DIR=""
SMOKE_SCRIPTS_PATHS=()

# scripts_dir 하위 `*.sh` 절대 경로 목록을 SMOKE_SCRIPTS_INDEX(개행 구분 문자열)과
# SMOKE_SCRIPTS_PATHS(배열)에 1회만 채웁니다. 같은 디렉터리로 다시 부르면 캐시를 재사용합니다
# — 폐포를 스텝 수만큼 계산하는 preflight 에서 매번 트리를 스캔하지 않기 위한 것입니다
# (basename 조회마다 find 를 띄우던 것이 원래의 주 병목이었습니다).
# 조회는 배열을 직접 훑습니다. 수십 줄 규모라 순수 bash 루프가 가장 빠르고, basename→경로
# 대응표를 문자열에 memoize 하는 편은 그 문자열을 매번 다시 스캔하느라 오히려 느립니다(실측).
smoke_scripts_index() {
  local scripts_dir="$1" line
  [[ "$SMOKE_SCRIPTS_INDEX_DIR" == "$scripts_dir" && -n "$SMOKE_SCRIPTS_INDEX" ]] && return 0
  SMOKE_SCRIPTS_INDEX="$(find "$scripts_dir" -type f -name '*.sh' 2>/dev/null)"
  SMOKE_SCRIPTS_PATHS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    SMOKE_SCRIPTS_PATHS+=("$line")
  done <<< "$SMOKE_SCRIPTS_INDEX"
  SMOKE_SCRIPTS_INDEX_DIR="$scripts_dir"
  return 0
}

SMOKE_FILE_REFS=""

# $1 파일 본문에 등장하는 `*.sh` basename 목록(공백 구분·중복 제거)을 SMOKE_FILE_REFS 에 냅니다.
#
# 스텝마다 구하는 폐포는 서로 상당 부분 겹쳐 같은 파일을 몇 번이고 다시 읽게 됩니다
# (실측: 대표 시나리오에서 폐포 구성원 누적 320회, 고유 파일은 66개). 그래서 파일 단위로
# memoize 합니다. 중복 제거도 bash 안에서 해 `sort` 서브프로세스를 없앱니다.
#
# bash 3.2 라 연관배열을 못 쓰고, 임시 디렉터리 캐시는 EXIT trap 을 호출자와 다투게 되므로
# 경로를 식별자로 바꾼 **동적 변수 이름**에 담습니다. 레코드를 큰 문자열 하나에 이어 붙이고
# glob 으로 찾는 방식은 bash 의 `*X*` 매칭이 사실상 제곱 비용이라 memo 가 커질수록 급격히
# 느려집니다 (실측: 9.5KB memo 에서 조회 1회당 약 100ms).
#
# 식별자화는 서로 다른 경로가 같은 키로 접히는 충돌이 원리상 가능하므로, 레코드에 원래
# 경로를 함께 담아 대조하고 어긋나면 캐시를 쓰지 않고 다시 계산합니다.
smoke_file_refs() {
  local f="$1" tok vname stored
  vname="SMOKE_REFS_${f//[^A-Za-z0-9]/_}"
  if [[ -n "${!vname+x}" ]]; then
    stored="${!vname}"
    if [[ "${stored%%$'\t'*}" == "$f" ]]; then
      SMOKE_FILE_REFS="${stored#*$'\t'}"
      return 0
    fi
  fi
  SMOKE_FILE_REFS=""
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    case " $SMOKE_FILE_REFS " in *" $tok "*) continue ;; esac
    SMOKE_FILE_REFS="${SMOKE_FILE_REFS}${SMOKE_FILE_REFS:+ }$tok"
  done < <(grep -oE '[A-Za-z0-9_.-]+\.sh' "$f" 2>/dev/null)
  printf -v "$vname" '%s\t%s' "$f" "$SMOKE_FILE_REFS"
  return 0
}

# start_script 의 **참조 폐포**를 SMOKE_CLOSURE 에 절대 경로로 채웁니다.
#
# 본문에 등장하는 `*.sh` basename 을 모두 후보로 보고 scripts_dir 안에서 찾아 재귀 전개합니다.
# `source` 만 따라가면 "테스트가 대상 스크립트를 서브프로세스로 실행하는" 흔한 형태에서
# 관련성이 누락되어 거짓 통과가 납니다 — 그래서 문자열 등장 자체를 참조로 봅니다.
# 과다 매칭은 스킵을 줄이는 안전한 방향이므로 허용합니다.
smoke_ref_closure() {
  local scripts_dir="$1" start="$2"
  SMOKE_CLOSURE=()
  smoke_scripts_index "$scripts_dir"
  # 큐는 슬라이스로 재구성하지 않고 읽기 위치(qi)만 옮깁니다 — 재구성은 배열 전체를
  # 매번 복사해 스텝 수만큼 반복되면 그 복사 비용이 무시할 수 없게 커집니다.
  local queue=("$start") qi=0 seen="" cur base cand
  while (( qi < ${#queue[@]} )); do
    cur="${queue[qi]}"
    qi=$((qi + 1))
    case "$seen" in *"|${cur}|"*) continue ;; esac
    [[ -f "$cur" ]] || continue
    seen="${seen}|${cur}|"
    # self_test.sh 는 모든 스텝의 스크립트 이름을 본문에 언급하는 오케스트레이터라, 폐포에
    # 들어오면 아래 매치 규칙이 어떤 변경 파일에 대해서도 모든 스텝에서 동일하게 참을 냅니다
    # — 스텝을 구분하지 못하는 판별력 0 의 상수항이 되어 관련성 판정 자체를 무력화합니다.
    # 구성원으로도 넣지 않고 전개도 하지 않습니다. self_test.sh 자신의 변경은 상위 호출자가
    # 하드코딩 특례로 무조건 full 폴백하므로 이 제외로 놓치는 경로는 없습니다 (spec §5.3).
    [[ "${cur##*/}" == "self_test.sh" ]] && continue
    SMOKE_CLOSURE+=("$cur")
    smoke_file_refs "$cur"
    # basename 은 `[A-Za-z0-9_.-]+` 만으로 이루어져 공백·glob 문자가 없으므로 분리해도 안전합니다.
    for base in $SMOKE_FILE_REFS; do
      # basename **정확 일치**로 비교합니다. `grep -F "/$base"` 는 foo.sh 가 barfoo.sh 에도
      # 걸리는 부분 문자열 매칭이고, `grep -E "/${base}$"` 는 basename 의 `.` 이 정규식
      # 메타로 해석됩니다.
      for cand in ${SMOKE_SCRIPTS_PATHS[@]+"${SMOKE_SCRIPTS_PATHS[@]}"}; do
        [[ "${cand##*/}" == "$base" ]] || continue
        case "$seen" in *"|${cand}|"*) continue ;; esac
        queue+=("$cand")
      done
    done
  done
  return 0
}

# 현재 SMOKE_CLOSURE 안에서 정규화된 변경 경로 $1 이 매치되는지 판정합니다.
# return 0 = 매치(관련 있음), 1 = 매치 없음.
#
# smoke_step_relevant 와 smoke_preflight 가 **같은 함수**를 쓰게 해서 두 경로의 판정이
# 갈라질 수 없게 하는 것이 이 추출의 목적입니다.
smoke_closure_matches() {
  local n="$1" b="${1##*/}" c
  [[ -n "$b" ]] || return 1
  for c in ${SMOKE_CLOSURE[@]+"${SMOKE_CLOSURE[@]}"}; do
    # 폐포 구성원 자신이 변경 파일과 같은 스크립트인 경우입니다(basename 동일).
    # 전체 상대경로 접미사 비교는 scripts_dir 트리 구조가 repo-root 구조와 다를 때
    # (테스트 fixture 등) 성립하지 않아 자기참조 변경을 놓치므로 함께 둡니다.
    [[ "$c" == *"/$n" || "${c##*/}" == "$b" ]] && return 0
    grep -qF -- "$b" "$c" 2>/dev/null && return 0
  done
  return 1
}

# run_step 이 받은 명령 인자로 이 스텝을 실행해야 하는지 판정합니다.
# return 0 = 실행해야 함, 1 = 스킵 가능.
#
# 규칙 (spec §5.3):
#   1. `bash <경로>` 형태가 아니면(= self_test.sh 내부 checker 함수) 항상 실행합니다.
#      함수 본문이 무엇을 검사하는지 정적으로 확정할 수 없으므로 안전 기본값을 택합니다.
#   2. 형태가 맞으면 그 스크립트의 참조 폐포를 구합니다.
#   3. 변경 파일이 폐포 경로에 해당하거나 그 basename 이 폐포 구성원 본문에 등장하면 실행합니다.
# 변경 파일 경로를 설치 미러 상대 경로로 정규화합니다.
# 이 저장소의 정본은 `_ROOT_FILES/` 이고 루트 `rd-workflow/` 는 그 미러이므로, 정본만 편집한
# 정상 상태에서 이 정규화가 없으면 관련 스텝을 통째로 놓칩니다.
smoke_normalize_path() {
  local p="$1"
  printf '%s\n' "${p#_ROOT_FILES/}"
}

# 명령 인자에서 `bash <경로>` 대상을 찾습니다. 선행 `env VAR=값 ...` 은 건너뜁니다.
# env 를 인식하지 않으면 (b) 회차 전달을 위해 wrapper 함수로 감싸는 순간 그 스텝이
# inline checker 로 분류되어 항상 실행됩니다 — 51초 병목이 무관한 변경에서도 매번 돕니다.
# 대상을 찾지 못하면 빈 문자열을 냅니다 (호출자는 "항상 실행" 으로 처리).
smoke_cmd_target() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      env) shift; while [[ $# -gt 0 && "$1" == *=* ]]; do shift; done; continue ;;
      bash) shift; printf '%s\n' "${1:-}"; return 0 ;;
      *) return 0 ;;
    esac
  done
  return 0
}

smoke_step_relevant() {
  local scripts_dir="$1"; shift
  local target
  target="$(smoke_cmd_target "$@")"
  [[ -n "$target" && -f "$target" ]] || return 0
  (( ${#SMOKE_CHANGED_FILES[@]} > 0 )) || return 0
  smoke_ref_closure "$scripts_dir" "$target"
  local m n
  for m in ${SMOKE_CHANGED_FILES[@]+"${SMOKE_CHANGED_FILES[@]}"}; do
    n="$(smoke_normalize_path "$m")"
    smoke_closure_matches "$n" && return 0
  done
  return 1
}

# self_test.sh 본문에서 **최상위** run_step 호출을 `<desc>\t<나머지 인자>` 로 추출합니다.
# 들여쓰기된 호출(함수 안·문자열 안)은 실제 스텝이 아니므로 제외합니다.
# 추출 결과가 0건이면 구조가 바뀐 것이므로 실패로 봅니다 (호출자는 full 폴백).
smoke_extract_steps() {
  local self="$1" n
  [[ -f "$self" ]] || return 1
  n="$(grep -c '^run_step ' "$self" 2>/dev/null || true)"
  [[ -n "$n" && "$n" -gt 0 ]] || return 1
  sed -n 's/^run_step "\([^"]*\)" \(.*\)$/\1\t\2/p' "$self"
}

SMOKE_SKIP_IDX=""
SMOKE_SKIP_DESCS=()
SMOKE_STEP_DESCS=()
SMOKE_UNMAPPED=""

# 모든 스텝을 미리 판정합니다 (spec §5.3 preflight).
#   SMOKE_SKIP_IDX   — 스킵할 스텝 **순번** 집합 ("|3||7|" 형태)
#   SMOKE_SKIP_DESCS — ("3. 설명" ...) 표시용 배열
#   SMOKE_STEP_DESCS — 순번 → 설명 **대응표** (0-based: 순번 N 의 설명은 [N-1]).
#                      스킵 여부와 무관하게 **모든 스텝**을 담습니다. 호출자는 실행 중
#                      각 스텝의 실제 설명을 이 표와 대조해, 어긋나면 그 스텝을 스킵하지
#                      않고 실행하며 경고를 남겨야 합니다 (spec §5.3 역할 3).
#                      순번 집합만으로는 "preflight 가 모르는 스텝이 끼어들어 순번을
#                      밀어낸" 형태를 구분하지 못합니다 — 그때 밀려난 순번이 남의 판정을
#                      물려받아, preflight 가 모르는 스텝이 오히려 **스킵**됩니다.
#   SMOKE_UNMAPPED   — 어떤 스텝의 폐포에도 걸리지 않은 인프라 변경 파일 (개행 구분).
#                      하나라도 나오면 호출자는 full 로 폴백해야 합니다 — 스텝별 독립 판정만
#                      하면 "새 파일이라 아무 폐포에도 없다 → 모든 bash 스텝 스킵" 이라는
#                      정확히 반대 방향의 결과가 납니다. 그래서 무매핑이 있으면 스킵 산출
#                      두 개를 **비워서** 냅니다 — 호출자가 SMOKE_UNMAPPED 검사를 빠뜨려도
#                      "가장 위험한 변경에서 가장 적게 검사" 하는 경로가 생기지 않게 합니다.
# return 0 = 정상, 1 = 스텝 추출 실패(호출자는 full 폴백).
#
# 스텝 식별에 설명 문자열이 아니라 호출 순번을 쓰는 이유: 설명이 같은 두 스텝 중 하나만
# 무관해도 관련 있는 쪽까지 스킵되고, 설명에 구분자가 섞이면 집합 표현 자체가 깨집니다.
#
# 스텝마다 폐포를 **한 번만** 계산해 그 자리에서 (a) 관련성 판정과 (b) 커버 기록을 함께
# 끝냅니다. 두 가지를 따로 돌면 폐포 계산이 스텝 수만큼 중복됩니다.
smoke_preflight() {
  local scripts_dir="$1" self="$2"
  SMOKE_SKIP_IDX=""; SMOKE_SKIP_DESCS=(); SMOKE_STEP_DESCS=(); SMOKE_UNMAPPED=""

  local steps idx=0 desc cmd target j relevant
  steps="$(smoke_extract_steps "$self")" || return 1
  [[ -n "$steps" ]] || return 1

  # 대응표는 관련성 판정보다 **먼저** 채웁니다. 아래 조기 반환(변경 0건)에서도 호출자가
  # 순번↔설명을 대조할 수 있어야 하기 때문입니다 — 표가 비면 모든 스텝이 어긋난 것으로
  # 보여 경고가 도배되고, 그 소음이 진짜 어긋남을 덮습니다.
  while IFS=$'\t' read -r desc cmd; do
    SMOKE_STEP_DESCS+=("$desc")
  done <<< "$steps"

  # 변경 파일이 없으면 관련성 판정이 무의미하므로 스킵을 하나도 만들지 않고 반환합니다
  # (= 전부 실행). 빈 집합은 상위 호출자가 이미 full 폴백으로 처리하지만, 이 함수 단독
  # 호출에서도 안전 기본값을 지킵니다.
  (( ${#SMOKE_CHANGED_FILES[@]} > 0 )) || return 0

  # 정규화는 스텝마다 반복할 이유가 없으므로 한 번만 해 둡니다.
  # 인프라 코드 변경만 무매핑 검사 대상입니다 — 문서·workspace 변경을 검사하는 스텝은
  # 전부 inline checker 라 어차피 항상 실행됩니다.
  local changed=() infra=() covered="" m n
  for m in ${SMOKE_CHANGED_FILES[@]+"${SMOKE_CHANGED_FILES[@]}"}; do
    n="$(smoke_normalize_path "$m")"
    changed+=("$n")
    case "$n" in
      rd-workflow/scripts/*|rd-workflow/claude_skills/*) infra+=("$n") ;;
    esac
  done

  while IFS=$'\t' read -r desc cmd; do
    idx=$((idx + 1))
    # `bash "${SCRIPT_DIR}/x.sh"` / `env V=1 bash "..."` → 실제 경로로 복원합니다.
    # ${SCRIPT_DIR} 를 문자열 치환한 뒤 eval 로 따옴표만 벗깁니다. eval 을 쓰는 이유는
    # 인자에 따옴표가 섞여 있어 단순 분할로는 경로를 정확히 뽑을 수 없기 때문이고,
    # 입력은 self_test.sh 본문(신뢰 대상)에서만 옵니다.
    cmd="${cmd//\$\{SCRIPT_DIR\}/$scripts_dir}"
    # eval 실패·대상 없음(= inline checker)은 **항상 실행**이며 커버로도 치지 않습니다.
    #
    # 스텝 명령이 ${SCRIPT_DIR} 밖의 변수를 참조할 수 있고(예: env "X=${SELFTEST_EP_ITER}"),
    # set -u 아래에서 미정의 변수 확장은 `|| continue` 로도 `if` 로도 막지 못하는 **셸 종료**
    # 입니다. 게다가 2>/dev/null 이 unbound variable 메시지까지 삼켜, 호출자(self_test.sh 는
    # set -euo pipefail)가 아무 단서 없이 exit 1 로 죽습니다. preflight 는 bash 대상 경로만
    # 필요하므로 이 구간에서만 -u 를 내려 미정의 변수를 빈 문자열로 접습니다.
    local _u_on=0; case "$-" in *u*) _u_on=1; set +u ;; esac
    eval "set -- $cmd" 2>/dev/null || { (( _u_on )) && set -u; continue; }
    (( _u_on )) && set -u
    target="$(smoke_cmd_target "$@")"
    [[ -n "$target" && -f "$target" ]] || continue

    smoke_ref_closure "$scripts_dir" "$target"

    relevant=0
    for n in ${changed[@]+"${changed[@]}"}; do
      if smoke_closure_matches "$n"; then relevant=1; break; fi
    done
    if [[ "$relevant" -eq 0 ]]; then
      SMOKE_SKIP_IDX="${SMOKE_SKIP_IDX}|${idx}|"
      SMOKE_SKIP_DESCS+=("${idx}. ${desc}")
    fi

    # 커버 기록 — 이미 커버된 원소는 다시 검사하지 않아 불필요한 grep 을 줄입니다.
    # bash 3.2 라 연관배열을 못 쓰므로 인덱스 문자열 집합을 씁니다.
    j=0
    while (( j < ${#infra[@]} )); do
      case "$covered" in *"|${j}|"*) j=$((j + 1)); continue ;; esac
      smoke_closure_matches "${infra[j]}" && covered="${covered}|${j}|"
      j=$((j + 1))
    done
  done <<< "$steps"

  j=0
  while (( j < ${#infra[@]} )); do
    case "$covered" in
      *"|${j}|"*) ;;
      *) if [[ -n "$SMOKE_UNMAPPED" ]]; then
           SMOKE_UNMAPPED="${SMOKE_UNMAPPED}
${infra[j]}"
         else
           SMOKE_UNMAPPED="${infra[j]}"
         fi ;;
    esac
    j=$((j + 1))
  done

  # 무매핑이 하나라도 있으면 호출자는 full 로 폴백해야 합니다. 그 경우 스킵 목록은
  # 의미가 없을 뿐 아니라 **위험합니다** — 신규 파일 추가는 어떤 폐포에도 걸리지 않아
  # bash 스텝 전부가 스킵 판정되므로, 호출자가 SMOKE_UNMAPPED 를 빠뜨리면 가장 위험한
  # 변경에서 가장 적게 검사하게 됩니다. 산출 자체를 비워 그 경로를 원천 차단합니다.
  # `SMOKE_STEP_DESCS` 는 비우지 않습니다 — 순번↔설명 대응은 관련성 판정과 무관하게
  # 그대로 참이고, 비우면 폴백 상태에서 대조가 불가능해집니다.
  if [[ -n "$SMOKE_UNMAPPED" ]]; then
    SMOKE_SKIP_IDX=""; SMOKE_SKIP_DESCS=()
  fi
  return 0
}

# --- full 증명 지문 (spec §5.5) ---------------------------------------------
#
# 증명 집합(proof)은 "기존 full 증명이 아직 유효한가" 를 묻습니다 — tracked 전체에서
# transient 산출물만 뺀 것입니다. 인프라로만 좁히면 "full 통과 → 문서 변경으로 full 이
# 깨질 상태가 됨 → stale 증명으로 통과" 라는 경로가 열립니다. full 스텝에는 문서·workspace
# 를 검사하는 inline checker 가 여럿 있어, 문서 변경도 full 결과를 바꿉니다.
#
# **smoke 는 이 지문을 절대 기록하지 않습니다.** 기록은 self_test.sh 의 full 경로에서만
# 일어나므로 "smoke 만 통과한 상태" 와 "full 통과 상태" 가 캐시의 존재·일치로 구별됩니다.
# 이 구별이 무너지면 감축 실행 결과가 전수 검증 증명으로 둔갑해, smoke 가 새는 만큼
# (판정이 "본문 언급" heuristic 이라 새는 경로가 구조적으로 남습니다) 안전망 전체가
# 함께 무너집니다.

# proof 집합에서 제외할 transient 산출물 — 캐시·감사 로그 성격만 뺍니다.
# 이 목록을 넓히는 것은 곧 증명 범위를 좁히는 것이므로 신중해야 합니다.
#
# 로그 제외는 **lifecycle 감사 로그로 한정**합니다. git pathspec 의 `*` 는 `/` 를 넘으므로
# 맨 `*.log` 는 저장소 전역·임의 깊이에 걸려, 앞으로 인프라 디렉터리에 `.log` 파일이
# 생기면 그 파일이 조용히 증명 밖으로 빠집니다 (같은 목록을 untracked 판정도 쓰므로
# untracked `.log` 도 차단하지 못하게 됩니다).
#
# `selftest-full-cache.*` 도 함께 뺍니다. 기록은 `mktemp "<캐시>.XXXXXX"` → `mv -f` 로
# 이루어지는데, 전수 검증이 그 창에서 중단되면 `selftest-full-cache.ab12cd` 가 남습니다.
# 정확한 이름만 제외하면 그 잔여물이 untracked 로 잡혀 **우회 밸브가 없는 아카이브 게이트가
# 영구 차단**됩니다. 접두를 `selftest-full-cache.` 로 못박아 임시 파일만 걸리게 했고,
# 캐시 본체(`selftest-full-cache`)는 점이 없어 이 항목에 걸리지 않습니다.
smoke_proof_exclude() {
  cat <<'SPEC'
:(exclude)rd-workflow-workspace/.lifecycle/verify-cache
:(exclude)rd-workflow-workspace/.lifecycle/selftest-full-cache
:(exclude)rd-workflow-workspace/.lifecycle/selftest-full-cache.*
:(exclude)rd-workflow-workspace/.lifecycle/*-audit.log
:(exclude)rd-workflow-workspace/.lifecycle/*.log
SPEC
}

# 워킹트리에서 index 와 다른 파일 하나의 지문 레코드를 NUL 종단으로 냅니다.
# 형식은 index 쪽과 같은 `<경로>|<mode>|<blob 해시>` 입니다 — 같은 내용이면 두 모드가
# **같은 값**을 내야 "staged 하면 index 지문 = 워킹트리 지문" 계약이 성립합니다.
#
# 경로+내용만으로는 부족합니다: 실행 비트만 바뀐 상태가 기존 PASS 와 같은 지문이 되면
# full 재실행 없이 stale 증명이 통과합니다. 그래서 mode 를 레코드에 넣습니다.
# symlink 는 **링크 문자열 자체**를 해시합니다 (git 이 symlink blob 에 담는 값과 같습니다).
# 대상을 따라 읽으면 끊어진 링크에서 계산이 실패하고, 대상 파일의 변경을 두 번 세게 됩니다.
_smoke_worktree_record() {
  local root="$1" f="$2" p="$1/$2" h
  if [[ -L "$p" ]]; then
    h="$(printf '%s' "$(readlink "$p")" | git -C "$root" hash-object --stdin 2>/dev/null)" || return 1
    [[ -n "$h" ]] || return 1
    printf '%s|120000|%s\0' "$f" "$h"
  elif [[ -f "$p" ]]; then
    # `--path` 를 주어야 clean 필터가 index 에 담길 때와 같게 적용되어, 내용이 같은 파일이
    # 두 모드에서 같은 해시를 냅니다.
    h="$(git -C "$root" hash-object --path "$f" -- "$p" 2>/dev/null)" || return 1
    [[ -n "$h" ]] || return 1
    if [[ -x "$p" ]]; then printf '%s|100755|%s\0' "$f" "$h"
    else printf '%s|100644|%s\0' "$f" "$h"; fi
  else
    printf '%s|deleted|\0' "$f"
  fi
}

# **proof 집합**(tracked 전체 − transient)의 지문을 stdout 에 1줄로 냅니다.
# mode=worktree → 워킹트리 내용, mode=index → staged(index) 내용 기준입니다.
# 실패 시 1 을 반환하며 아무것도 내지 않습니다 — 호출자는 차단 쪽으로 판정해야 합니다.
#
# 파일 목록·해시를 git 에서 **일괄로** 받습니다. 파일마다 해시 도구를 띄우는 방식은 이
# 저장소(tracked 5,400여 개)에서 한 번에 수 분이 걸려(실측: 800개에 23.6초) 커밋마다 도는
# 대조로도, full 실행 앞뒤 기록으로도 쓸 수 없습니다. `git ls-files -s` 가 이미
# `<mode> <blob> <stage>\t<경로>` 를 한 번에 주므로 index 지문은 그 출력의 변환이면 충분하고,
# 워킹트리 지문은 index 와 **다른 파일만** 갈아 끼우면 됩니다 (실측 0.6초).
#
# **전제 (worktree 모드)**: "워킹트리가 index 와 같은가" 의 판정을 `git diff-files` 에
# 위임합니다 — clean 으로 나온 파일은 다시 읽지 않고 index blob 을 그대로 씁니다.
# 따라서 `core.fileMode=false`·`assume-unchanged`·`skip-worktree`·sparse-checkout 처럼
# `diff-files` 를 침묵시키는 축은 **자동으로 이 지문의 사각지대**가 됩니다. 지금 그 축들은
# 모두 git 이 커밋 내용에 반영하지 않는 변경이라 실질 위험이 없지만, 워킹트리 자체를
# 검증 대상으로 삼는 소비처(아카이브 전 강제 등)를 새로 붙일 때는 이 전제를 함께 봐야
# 합니다. 파일마다 해시를 다시 뜨는 방식은 이 저장소에서 92초가 걸려(실측) 선택지가
# 아니었고, 이 위임이 그 비용을 0.6초로 낮춘 트레이드오프입니다.
smoke_proof_fingerprint() {
  local root="$1" mode="${2:-worktree}"
  case "$mode" in worktree|index) ;; *) return 1 ;; esac

  local specs=(".") sp
  while IFS= read -r sp; do [[ -n "$sp" ]] && specs+=("$sp"); done < <(smoke_proof_exclude)

  local base dirty acc
  base="$(mktemp)" || return 1
  if ! git -C "$root" ls-files -s -z -- ${specs[@]+"${specs[@]}"} > "$base" 2>/dev/null; then
    rm -f "$base"; return 1
  fi
  # tracked 파일이 하나도 없으면 증명할 대상이 없다는 뜻입니다. 빈 목록의 해시를 그대로
  # 내면 "무엇을 넣어도 통과하는 지문" 이 생기므로 계산 실패로 봅니다.
  if [[ ! -s "$base" ]]; then rm -f "$base"; return 1; fi

  local dp=() dset="" dset_ok=1 p
  if [[ "$mode" == "worktree" ]]; then
    dirty="$(mktemp)" || { rm -f "$base"; return 1; }
    if ! git -C "$root" diff-files --name-only -z -- ${specs[@]+"${specs[@]}"} > "$dirty" 2>/dev/null; then
      rm -f "$base" "$dirty"; return 1
    fi
    while IFS= read -r -d '' p; do dp+=("$p"); done < "$dirty"
    rm -f "$dirty"
    # 조회는 개행 구분 문자열이 가장 빠르지만, 개행이 든 경로가 하나라도 있으면 그 표현이
    # 성립하지 않습니다. 그때만 배열 선형 탐색으로 내려갑니다 — 느려도 판정을 놓치지
    # 않습니다. 놓치면 워킹트리가 다른데 index 와 같은 지문이 나오는 fail-open 입니다.
    for p in ${dp[@]+"${dp[@]}"}; do
      case "$p" in *$'\n'*) dset_ok=0; break ;; esac
    done
    if (( dset_ok )); then
      for p in ${dp[@]+"${dp[@]}"}; do dset="${dset}${p}"$'\n'; done
      dset=$'\n'"$dset"
    fi
  fi

  acc="$(mktemp)" || { rm -f "$base"; return 1; }
  local rec meta sha f rc=0 hit
  {
    while IFS= read -r -d '' rec; do
      f="${rec#*$'\t'}"
      hit=0
      if (( ${#dp[@]} > 0 )); then
        if (( dset_ok )); then
          case "$dset" in *$'\n'"$f"$'\n'*) hit=1 ;; esac
        else
          for p in "${dp[@]}"; do
            if [[ "$p" == "$f" ]]; then hit=1; break; fi
          done
        fi
      fi
      if (( hit )); then
        if ! _smoke_worktree_record "$root" "$f"; then rc=1; break; fi
      else
        meta="${rec%%$'\t'*}"          # "<mode> <blob> <stage>"
        sha="${meta#* }"; sha="${sha%% *}"
        printf '%s|%s|%s\0' "$f" "${meta%% *}" "$sha"
      fi
    done < "$base"
  } > "$acc"
  rm -f "$base"
  if [[ "$rc" -ne 0 ]]; then rm -f "$acc"; return 1; fi

  local out
  out="$(_smoke_hash < "$acc")" || { rm -f "$acc"; return 1; }
  rm -f "$acc"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# transient 를 제외한 untracked 상태를 **3분류**로 판정합니다.
#   0 = 없음, 1 = 있음(목록은 stdout), 2 = 조회 오류(fail-closed 로 다뤄야 함)
# 캐시 판정과 PASS 기록이 **같은 helper 를 소비**합니다 — 각자 git 을 부르면 한쪽만 rc 를
# 흘려 정책이 갈립니다.
smoke_untracked_state() {
  local root="$1" specs=() sp tmp
  while IFS= read -r sp; do [[ -n "$sp" ]] && specs+=("$sp"); done < <(smoke_proof_exclude)
  tmp="$(mktemp)" || return 2
  # 판정은 NUL 스트림 유무로 합니다 (개행이 든 경로에서도 안전해야 합니다).
  if ! git -C "$root" ls-files --others --exclude-standard -z -- "." ${specs[@]+"${specs[@]}"} > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 2
  fi
  if [[ ! -s "$tmp" ]]; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  # 표시용 목록은 git 기본 출력을 씁니다 — 특수문자 경로를 quote 해서 내므로 사람이 읽기에
  # 안전합니다. 이 두 번째 조회가 실패해도 "있음" 판정은 이미 확정이므로 뒤집지 않습니다.
  git -C "$root" ls-files --others --exclude-standard -- "." ${specs[@]+"${specs[@]}"} 2>/dev/null || true
  return 1
}

# 캐시 유효성 판정 — **hook 과 archive 가 공통으로 씁니다.**
# mode=index → 커밋 전 대조, mode=worktree → 워킹트리를 커밋하는 형태·archive precheck.
# return 0 = 유효, 1 = 무효(사유는 stderr).
#
# **untracked 검사는 mode 에 따라 갈립니다** (spec §5.5, 2026-08-20 정정 · 사용자 승인).
#   - worktree 모드: 검사합니다. 커밋·아카이브 대상이 워킹트리 자체이고, untracked 파일도
#     full checker 의 입력이라 tracked 지문만으로는 그 상태를 증명하지 못합니다.
#   - index 모드: 검사하지 않고 지문만 봅니다. 캐시는 untracked 0건일 때만 기록되므로
#     (`smoke_record_full_pass`) 증명의 내용은 "untracked 없는 상태에서 tracked 트리 T 가
#     full 을 통과했다" 이고, index 트리가 T 와 같으면 **커밋될 트리는 정확히 T** 입니다.
#     기록 이후 생긴 untracked 는 커밋에 들어가지 않아 그 사실을 바꾸지 못합니다 — 넣으려면
#     `git add` 해야 하고 그러면 index 지문이 달라져 정상적으로 차단됩니다.
#
# 이 분기가 없으면 게이트가 형해화합니다: 작업 중 신규 파일이 상시 존재하는 저장소에서는
# 캐시 내용과 무관하게 항상 무효가 나와 인프라 커밋이 100% 차단되고, 우회 밸브가 유일한
# 통로가 됩니다. 그때의 실질 동작은 "검증 강제" 가 아니라 "커밋마다 사유 한 줄을 받는
# 로깅 장치" 이며, 형식적으로 반복되는 우회 사유는 경보 가치를 잃습니다.
smoke_cache_valid() {
  local root="$1" mode="$2"
  local cache="$root/rd-workflow-workspace/.lifecycle/selftest-full-cache" cached now
  local untracked="" ustate=0
  if [[ "$mode" != "index" ]]; then
    untracked="$(smoke_untracked_state "$root")" || ustate=$?
    if [[ "$ustate" -eq 2 ]]; then
      printf 'self_test full 증명 무효: untracked 목록 조회 실패 (git 오류)\n' >&2
      return 1
    fi
    if [[ "$ustate" -eq 1 ]]; then
      printf 'self_test full 증명 무효: proof 에 담기지 않는 untracked 파일이 있습니다\n' >&2
      printf '%s\n' "$untracked" | sed 's/^/  /' >&2
      printf '  git add 후 self_test.sh full 을 다시 실행하세요\n' >&2
      return 1
    fi
  fi
  [[ -f "$cache" ]] || { printf 'self_test full 증명 없음: 캐시 파일이 없습니다\n' >&2; return 1; }
  cached="$(head -1 "$cache" 2>/dev/null || true)"
  now="$(smoke_proof_fingerprint "$root" "$mode" 2>/dev/null || true)"
  if [[ -z "$now" || -z "$cached" || "$now" != "$cached" ]]; then
    printf 'self_test full 증명 무효: 현재 내용으로 full 을 통과한 기록이 없습니다\n' >&2
    return 1
  fi
  return 0
}

# full PASS 지문을 캐시에 기록합니다.
# **시작 지문과 종료 지문이 같을 때만** 기록합니다 — 실행 중 인프라가 바뀌었다면 검증하지
# 않은 내용을 통과로 증명하게 되므로 기록하지 않습니다.
# 기록 실패를 성공으로 숨기지 않습니다: 0 = 기록함, 1 = 기록 안 함(사유는 stderr).
#
# **이 캐시 파일(`rd-workflow-workspace/.lifecycle/selftest-full-cache`)이 무엇을 막는지**:
# 이 장치는 **정직한 실수를 막는 용도이지 의도적 우회를 막는 용도가 아닙니다.** 캐시는
# 서명 없는 로컬 평문 파일이라 `smoke_proof_fingerprint <root> index > <캐시>` 한 줄이면
# full 을 한 번도 돌리지 않고 유효한 증명을 만들 수 있습니다. 커밋 게이트에는 우회 밸브가
# 있어 이것이 추가 위험이 아니지만, **우회 불가가 존재 이유인 소비처**(아카이브 전 강제 등)를
# 새로 붙일 때는 이 성질이 그 가치를 그대로 무력화한다는 점을 전제로 설계해야 합니다.
smoke_record_full_pass() {
  local root="$1" start_fp="$2" start_ustate="${3-}"
  local cache="$root/rd-workflow-workspace/.lifecycle/selftest-full-cache" now tmp
  local untracked="" ustate=0
  # **시작 시점의 untracked 상태도 함께 봅니다** — 종료 시점만 보면, 실행 중에 생겼다가
  # 끝나기 전에 사라진 파일이 아무 흔적을 남기지 않습니다. 그 파일이 checker 의 입력이었다면
  # "tracked 트리 단독으로는 실패할 상태" 를 가린 채 PASS 가 기록되고, index 모드는 이 기록을
  # untracked 검사 없이 그대로 소비합니다(그 생략의 근거가 바로 이 기록 조건입니다).
  # 지문 축의 `start_fp` 와 완전히 같은 모양이며, 값을 받지 못하면(빈 값) 기록하지 않습니다.
  if [[ "$start_ustate" != "0" ]]; then
    printf '  경고: 실행 시작 시점의 untracked 상태가 0건이 아니거나 확인되지 않아 full PASS 기록을 남기지 않았습니다 (시작·종료 양쪽이 0건일 때만 증명이 성립합니다).\n' >&2
    return 1
  fi
  untracked="$(smoke_untracked_state "$root")" || ustate=$?
  if [[ "$ustate" -eq 2 ]]; then
    printf '  경고: untracked 조회에 실패해 full PASS 기록을 남기지 않았습니다 (git 오류)\n' >&2
    return 1
  fi
  if [[ "$ustate" -eq 1 ]]; then
    printf '  경고: untracked 파일이 있어 full PASS 기록을 남기지 않았습니다 — 이 파일들은 proof 에 담기지 않아 검증 상태를 증명할 수 없습니다.\n' >&2
    printf '%s\n' "$untracked" | sed 's/^/    /' >&2
    printf '  git add 후 full 을 다시 실행하세요 (index 에 올린 상태가 곧 커밋될 상태입니다).\n' >&2
    return 1
  fi
  now="$(smoke_proof_fingerprint "$root" worktree)" || {
    printf '  경고: 지문을 계산하지 못해 full PASS 기록을 남기지 못했습니다\n' >&2
    return 1
  }
  if [[ -z "$start_fp" || "$start_fp" != "$now" ]]; then
    printf '  경고: 실행 중 인프라 파일이 바뀌어 full PASS 기록을 남기지 않았습니다 (검증하지 않은 내용을 통과로 증명할 수 없습니다)\n' >&2
    return 1
  fi
  mkdir -p "$(dirname "$cache")" 2>/dev/null || {
    printf '  경고: 캐시 디렉터리를 만들지 못했습니다: %s\n' "$(dirname "$cache")" >&2
    return 1
  }
  tmp="$(mktemp "${cache}.XXXXXX")" || {
    printf '  경고: 캐시 임시 파일을 만들지 못했습니다\n' >&2
    return 1
  }
  if ! printf '%s\n' "$now" > "$tmp" || ! mv -f "$tmp" "$cache"; then
    rm -f "$tmp"
    printf '  경고: full PASS 기록을 저장하지 못했습니다: %s\n' "$cache" >&2
    return 1
  fi
  return 0
}
