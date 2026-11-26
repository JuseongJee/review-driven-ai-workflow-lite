#!/usr/bin/env bash
# _submodule_common.sh — 리뷰 입력에 submodule 안쪽 코드를 펼치고 완전성을 검사하는 함수. source 전용.
# 설계: spec 2.2 D5~D6 (submodule-archive-seal).
# 전제: 이 파일은 다른 파일을 source 하지 않습니다. `_rd_is_repo_root` 를 쓰므로 호출 스크립트가
# `_state_common.sh` 를 먼저 source 해야 합니다(`_rd_is_repo_root`·`rd_gitlink_content_id` 는 그 파일에 있습니다).

# ---------------------------------------------------------------------------
# 리뷰 입력 (spec 2.2 D5~D6) — submodule 포인터가 바뀐 구간에서 안쪽 코드를 리뷰 입력에 펼친다.
# ---------------------------------------------------------------------------

# _rd_range_has_gitlink <base> <head> — 0: 구간에 옛·새 mode 중 160000 이 있음 / 1: 없음 / 2: 판정 불가.
# `git diff --raw` 는 diff.ignoreSubmodules·submodule.<이름>.ignore 를 따라 gitlink 변경을 숨깁니다.
# `diff-tree` 는 diff.ignoreSubmodules 는 읽지 않지만 .gitmodules 의 `submodule.<이름>.ignore` 는 읽는다는 것이
# 실측(git 2.56.0)이라, `--ignore-submodules=none` 으로 두 설정을 모두 끄고 감지합니다.
# mktemp·diff-tree 가 실패하면 2(판정 불가)입니다 — 호출부가 fail-closed 로 다룹니다.
_rd_range_has_gitlink() {
  local base="$1" head="$2" raw meta path om nm found=1
  raw="$(mktemp "${TMPDIR:-/tmp}/rd-rt-raw.XXXXXX")" || return 2
  if git diff-tree -r --no-renames --ignore-submodules=none -z "$base" "$head" > "$raw" 2>/dev/null; then
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
      set -- $meta
      om="${1#:}"; nm="$2"
      if [[ "$om" == "160000" || "$nm" == "160000" ]]; then found=0; break; fi
    done < "$raw"
  else
    found=2
  fi
  rm -f "$raw"
  return "$found"
}

# rd_review_diff_target <base> <head> — 리뷰 대상 명령 문자열을 stdout 으로. 항상 return 0.
# gitlink 변경이 없으면 종전과 글자 그대로 같은 `git diff <base>..<head>` 입니다(pinned 세션 대조가 의존).
# submodule 형식에는 출력 고정 옵션(--no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/)을 넣습니다.
# rd_review_input_check 는 이 문자열을 그대로 실행하므로, 검사한 명령과 리뷰어가 실행하는 명령이 같습니다.
# (diff.external 이 켜진 저장소에서 검사만 통과하고 리뷰 출력이 0바이트가 되는 일을 막습니다.)
rd_review_diff_target() {
  local base="$1" head="$2" hg=0
  _rd_range_has_gitlink "$base" "$head" || hg=$?
  # 판정 불가(2)도 submodule 형식입니다 — 안쪽 코드를 펼치는 쪽이 안전한 쪽입니다.
  if [[ "$hg" != "1" ]]; then
    printf 'git -c diff.ignoreSubmodules=none diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ --submodule=diff --ignore-submodules=none %s..%s\n' "$base" "$head"
  else
    printf 'git diff %s..%s\n' "$base" "$head"
  fi
  return 0
}

# _rd_have_commit <dir> <oid> — dir 이 독립 저장소 루트이고 그 안에 oid 커밋 객체가 있으면 0.
_rd_have_commit() {
  _rd_is_repo_root "$1" && git -C "$1" cat-file -e "${2}^{commit}" 2>/dev/null
}

# _rd_exp_oneline <path> — 기대 파일은 줄 단위라, 경로의 개행은 글자 `\n` 으로 바꿉니다(대조가 맞지 않아 차단됨).
_rd_exp_path() { local p="$1"; printf '%s' "${p//$'\n'/\\n}"; }

# _rd_exp_expand <repo_dir> <prefix> <commit> <exp> <bad> — 새 submodule 커밋의 파일 전체를 기대 경로로.
_rd_exp_expand() {
  local rd="$1" pfx="$2" c="$3" exp="$4" bad="$5" raw rec meta path oid
  raw="$(mktemp "${TMPDIR:-/tmp}/rd-rt-ls.XXXXXX")" || { printf 'C\t%s\n' "$pfx" >> "$bad"; return 0; }
  if ! git -C "$rd" ls-tree -r -z --full-tree "$c" > "$raw" 2>/dev/null; then
    printf 'C\t%s\n' "$pfx" >> "$bad"; rm -f "$raw"; return 0
  fi
  while IFS= read -r -d '' rec; do
    [[ "$rec" == *$'\t'* ]] || continue
    meta="${rec%%$'\t'*}"; path="${rec#*$'\t'}"
    if [[ "$meta" == "160000 "* ]]; then
      oid="${meta##* }"
      if _rd_have_commit "$rd/$path" "$oid"; then
        _rd_exp_expand "$rd/$path" "${pfx}${path}/" "$oid" "$exp" "$bad"
      else
        printf 'O\t%s\n' "$(_rd_exp_path "${pfx}${path}")" >> "$bad"
      fi
    else
      printf 'P\t%s\n' "$(_rd_exp_path "${pfx}${path}")" >> "$exp"
    fi
  done < "$raw"
  rm -f "$raw"
  return 0
}

# _rd_exp_walk <repo_dir> <prefix> <base> <head> <exp> <bad> — spec D6 표대로 기대 목록을 만든다.
# exp 줄: `P<TAB>경로`(diff --git 머리줄에 있어야 함, 최상위 기준) / `D<TAB>경로`(submodule deleted 머리줄에 있어야 함, 그 단계 기준).
# bad 줄: `O<TAB>경로`(객체 부재) / `C<TAB>경로`(명령 실패).
_rd_exp_walk() {
  local rd="$1" pfx="$2" b="$3" h="$4" exp="$5" bad="$6" raw meta path om nm oo no full
  raw="$(mktemp "${TMPDIR:-/tmp}/rd-rt-dt.XXXXXX")" || { printf 'C\t%s\n' "$pfx" >> "$bad"; return 0; }
  if ! git -C "$rd" diff-tree -r --no-renames --ignore-submodules=none -z "$b" "$h" > "$raw" 2>/dev/null; then
    printf 'C\t%s\n' "${pfx:-.}" >> "$bad"; rm -f "$raw"; return 0
  fi
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    set -- $meta
    om="${1#:}"; nm="$2"; oo="$3"; no="$4"
    full="$(_rd_exp_path "${pfx}${path}")"
    if [[ "$om" == "160000" && "$nm" == "160000" ]]; then
      if _rd_have_commit "$rd/$path" "$oo" && _rd_have_commit "$rd/$path" "$no"; then
        _rd_exp_walk "$rd/$path" "${pfx}${path}/" "$oo" "$no" "$exp" "$bad"
      else
        printf 'O\t%s\n' "$full" >> "$bad"
      fi
    elif [[ "$nm" == "160000" ]]; then
      [[ "$om" == "000000" ]] || printf 'P\t%s\n' "$full" >> "$exp"
      if _rd_have_commit "$rd/$path" "$no"; then
        _rd_exp_expand "$rd/$path" "${pfx}${path}/" "$no" "$exp" "$bad"
      else
        printf 'O\t%s\n' "$full" >> "$bad"
      fi
    elif [[ "$om" == "160000" ]]; then
      # 삭제 머리줄의 경로는 접두 없이 그 단계 저장소 기준입니다(실측: 중첩 단계 삭제는 `Submodule inner ...` 로 나옴).
      printf 'D\t%s\n' "$(_rd_exp_path "$path")" >> "$exp"
      [[ "$nm" == "000000" ]] || printf 'P\t%s\n' "$full" >> "$exp"
    else
      printf 'P\t%s\n' "$full" >> "$exp"
    fi
  done < "$raw"
  rm -f "$raw"
  return 0
}

# rd_review_input_check <base> <head> — 리뷰 대상 출력이 기대 경로를 모두 담는지 검사 (spec D6).
# 기본 형식 구간은 즉시 0. 차단(1)이면 stderr 에 원인 분류(객체 부재/명령 실패/출력 누락)·빠진 경로·복구 명령.
rd_review_input_check() {
  local base="$1" head="$2" top target cmd exp bad out missing rc=0 tag p n_o=0 n_c=0 n_m=0
  local hg=0
  _rd_range_has_gitlink "$base" "$head" || hg=$?
  [[ "$hg" != "1" ]] || return 0
  if [[ "$hg" == "2" ]]; then
    {
      echo "review input: submodule 변경 여부를 판정할 수 없습니다 (${base}..${head})."
      echo "  원인: 명령 실패 — git diff-tree 또는 임시 파일 생성이 실패했습니다. 판정 불가이므로 차단합니다."
    } >&2
    return 1
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "review input: 저장소 루트를 찾을 수 없습니다 — 판정 불가로 차단합니다." >&2; return 1; }
  exp="$(mktemp "${TMPDIR:-/tmp}/rd-rt-exp.XXXXXX")" || return 1
  bad="$(mktemp "${TMPDIR:-/tmp}/rd-rt-bad.XXXXXX")" || { rm -f "$exp"; return 1; }
  out="$(mktemp "${TMPDIR:-/tmp}/rd-rt-out.XXXXXX")" || { rm -f "$exp" "$bad"; return 1; }
  missing="$(mktemp "${TMPDIR:-/tmp}/rd-rt-mis.XXXXXX")" || { rm -f "$exp" "$bad" "$out"; return 1; }
  _rd_exp_walk "$top" "" "$base" "$head" "$exp" "$bad"
  if [[ ! -s "$bad" ]]; then
    target="$(rd_review_diff_target "$base" "$head")"
    # 리뷰 대상 문자열을 그대로 실행합니다(출력 고정 옵션은 문자열 안에 있습니다). 더하는 것은 경로 인용을 끄는 -c 하나뿐입니다.
    cmd="${target/#git /git -c core.quotePath=false }"
    # shellcheck disable=SC2086
    if ! ( cd "$top" && $cmd ) > "$out" 2>/dev/null; then
      printf 'C\t(리뷰 대상 명령 종료 코드 ≠ 0)\n' >> "$bad"
    else
      if ! LC_ALL=C awk '
        NR == FNR { kind[NR] = substr($0, 1, 1); path[NR] = substr($0, 3); n = NR; next }
        /^diff --git a\// {
          line = substr($0, 14); i = 1
          while ((j = index(substr(line, i), " b/")) > 0) {
            pos = i + j - 1; A[substr(line, 1, pos - 1)] = 1; B[substr(line, pos + 3)] = 1; i = pos + 1
          }
        }
        /^Submodule / && /\(submodule deleted\)$/ {
          dp = substr($0, 11)
          sub(/ [0-9a-f]+\.\.\.[0-9a-f]+ \(submodule deleted\)$/, "", dp)
          dcnt[dp]++
        }
        END {
          for (k = 1; k <= n; k++) {
            p = path[k]
            if (kind[k] == "P") { if (!(p in A) && !(p in B)) print p }
            else ecnt[p]++
          }
          for (p in ecnt) if (ecnt[p] > dcnt[p]) print p " (submodule deleted 머리줄)"
        }' "$exp" "$out" > "$missing.raw"; then
        printf 'C\t(출력 대조 awk 실패)\n' >> "$bad"
      elif ! sort -u "$missing.raw" > "$missing"; then
        printf 'C\t(출력 대조 정렬 실패)\n' >> "$bad"
      elif [[ -s "$missing" ]]; then
        while IFS= read -r p; do printf 'M\t%s\n' "$p" >> "$bad"; done < "$missing"
      fi
    fi
  fi
  if [[ -s "$bad" ]]; then
    rc=1
    n_o="$(grep -c '^O	' "$bad" || true)"; n_c="$(grep -c '^C	' "$bad" || true)"; n_m="$(grep -c '^M	' "$bad" || true)"
    {
      echo "review input: submodule 안쪽 코드를 리뷰 입력에 펼칠 수 없습니다 (${base}..${head})."
      for tag in O C M; do
        case "$tag" in
          O) [[ "$n_o" != "0" ]] && echo "  원인: 객체 부재 — submodule 커밋 객체를 읽을 수 없습니다 (${n_o}개)" ;;
          C) [[ "$n_c" != "0" ]] && echo "  원인: 명령 실패 — git 명령이 실패했습니다 (${n_c}개)" ;;
          M) [[ "$n_m" != "0" ]] && echo "  원인: 출력 누락 — 리뷰 대상 출력에 없는 경로가 있습니다 (${n_m}개)" ;;
        esac
        { grep "^${tag}	" "$bad" || true; } | head -20 | sed 's/^[A-Z]	/    - /'
      done
      echo "  복구: submodule 이 비어 있으면: bash rd-workflow/scripts/rd submodule init"
      echo "        원격 객체가 없으면: git -C <submodule 경로> fetch"
      echo "        출력 누락이면: git -C <상위 저장소> config -f .gitmodules --get-regexp 'submodule\\..*\\.ignore' 로 원인 설정을 찾아 해제"
    } >&2
  fi
  rm -f "$exp" "$bad" "$out" "$missing" "$missing.raw"
  return "$rc"
}

# ---------------------------------------------------------------------------
# submodule 받기 (change-spec promote-submodule-lazy-local-init D1~D11)
# ---------------------------------------------------------------------------
# promote 와 `rd submodule init` 이 함께 씁니다. 메인 체크아웃(원천)에서 초기화된 submodule 은 원천을 로컬 복제해
# 원격 없이 받고, 그렇지 않은 submodule 은 모드에 따라 비워 두거나 원격에서 받습니다.
# 전역: _RD_SUB_PREFIX(최상위 기준 접두 경로, 최상위는 빈 값) · _RD_SUB_BUDGET0(원래 원격 예산, 빈 값 = 상한 없음) ·
#       _RD_SUB_LEFT(남은 원격 예산 초) · _RD_SUB_NOSRC_REASON(원천 없는 원격 받기의 안내 사유).

# _rd_sub_list <super> — <super>/.gitmodules 의 `submodule.<name>.path` 를 `.gitmodules` 순서로 NUL 구분 레코드(`키\n값`)로 냅니다.
_rd_sub_list() {
  git -C "$1" config -f .gitmodules -z --get-regexp '^submodule\..*\.path$' 2>/dev/null || true
}

# _rd_sub_is_gitlink <super> <경로> — index 에 그 경로의 gitlink(160000)가 있으면 0. gitlink 없는 `.gitmodules` 항목은 git 도 무시합니다.
_rd_sub_is_gitlink() {
  local x
  x="$(GIT_LITERAL_PATHSPECS=1 git -C "$1" ls-files -s -- "$2" 2>/dev/null | head -n 1)"
  [[ "${x%% *}" == "160000" ]]
}

# _rd_sub_resolve <super> <경로> — 경로가 submodule 이거나, 앞부분이 초기화된 submodule 이고 나머지가 그 안의 submodule 이면 0.
_rd_sub_resolve() {
  local super="$1" a="$2" rec p
  while IFS= read -r -d '' rec; do
    p="${rec#*$'\n'}"
    if [[ "$a" == "$p" ]]; then _rd_sub_is_gitlink "$super" "$p" && return 0; continue; fi
    if [[ "$a" == "$p"/* ]] && _rd_is_repo_root "$super/$p"; then
      _rd_sub_resolve "$super/$p" "${a#"$p"/}" && return 0
    fi
  done < <(_rd_sub_list "$super")
  return 1
}

# _rd_sub_remote <stderr 파일> <명령…> — 원격에 닿는 명령 하나를 실행합니다. 명령의 stdout 은 stderr 로, stderr 는 파일로 보냅니다.
# 예산(_RD_SUB_BUDGET0)이 있으면 `_rd_run_limited` 로 남은 초 안에서 실행하고 그 명령의 경과 초만 남은 예산에서 뺍니다.
# 반환: 명령의 종료 코드 / 124 시간 초과 / 125 예산 소진으로 실행하지 않음. 124·125 는 stderr 파일에 원인 한 줄을 적습니다.
_rd_sub_remote() {
  local errf="$1" rc=0 t0 b="${_RD_SUB_BUDGET0:-}"
  shift
  if [[ -z "$b" ]]; then
    "$@" >&2 2>"$errf" || rc=$?
    return "$rc"
  fi
  if (( ${_RD_SUB_LEFT:-0} <= 0 )); then
    printf '원격 대기 상한(%s초)을 다 써서 시도하지 않았습니다\n' "$b" > "$errf"
    return 125
  fi
  t0=$SECONDS
  _rd_run_limited "$_RD_SUB_LEFT" "$errf" env GIT_TERMINAL_PROMPT=0 "$@" >&2 || rc=$?
  _RD_SUB_LEFT=$(( _RD_SUB_LEFT - (SECONDS - t0) ))
  if [[ "$rc" == 124 ]]; then
    printf '시간 초과(%s초) — 원격이 응답하지 않습니다\n' "$b" > "$errf"
  fi
  return "$rc"
}

# _rd_sub_fail <표시 경로> <stderr 파일> — 실패 안내(원인 3줄 이내와 재시도 명령)를 stderr 로 냅니다.
_rd_sub_fail() {
  local disp="$1" errf="$2"
  {
    printf 'submodule 받기 실패: %s\n' "$disp"
    tail -n 3 "$errf" 2>/dev/null | sed 's/^/  /'
    printf '  재시도: bash rd-workflow/scripts/rd submodule init %q\n' "$disp"
  } >&2
}

# _rd_sub_not_ready <super> <경로> <name> <errf> — 받기 명령이 성공해도 그 경로가 체크아웃된 submodule 저장소가
# 아니면(git 이 submodule.<name>.update=none 등으로 받기를 건너뜀) 원인을 errf 에 쓰고 0 을 돌려줍니다.
# 저장소가 없는 경우와, 받기 실패로 남은 index 없는 저장소가 그대로인 경우를 모두 잡습니다.
# 빈 디렉터리에서 git 명령을 부르면 상위 저장소에 적용되므로, origin 을 바꾸기 전에 이 확인을 거칩니다.
_rd_sub_not_ready() {
  local idx=""
  if _rd_is_repo_root "$1/$2"; then
    idx="$(git -C "$1/$2" rev-parse --path-format=absolute --git-path index 2>/dev/null)" || idx=""
    [[ -n "$idx" && -e "$idx" ]] && return 1
  fi
  printf 'git 이 받기를 건너뛰어 submodule 이 체크아웃되지 않았습니다. submodule.%s.update=none 이면 그 설정을 지운 뒤 다시 받으십시오\n' "$3" > "$4"
  return 0
}

# rd_submodule_fill <super> <src> <mode> [<경로>...] — mode: main-only | all.
# stdout: 비워 둔 경로(최상위 기준) 줄 단위 / stderr: 안내 / 반환 0 또는 1(하나 이상 실패, 잘못된 경로 인자).
# <src> 가 빈 값이면 원천 없음입니다. 환경 RD_SUBMODULE_REMOTE_BUDGET(초, 빈 값 = 상한 없음)이 원격 명령 시간의 합을 제한합니다.
rd_submodule_fill() {
  local super="$1" src="$2" mode="$3" top=0 rc=0 errf i p name disp a bad=0 direct target
  local st c st_src src_init kind idx orig oid x reason rec key ok
  local -a sm_paths=() sm_names=() args=() subs=() flags=()
  shift 3
  if [[ -z "${_RD_SUB_PREFIX:-}" ]]; then
    top=1
    _RD_SUB_BUDGET0="${RD_SUBMODULE_REMOTE_BUDGET:-}"
    _RD_SUB_LEFT="$_RD_SUB_BUDGET0"
    for a in "$@"; do
      a="${a#./}"; a="${a%/}"
      args+=("$a")
      if ! _rd_sub_resolve "$super" "$a"; then
        echo "submodule 이 아닙니다: $a" >&2
        bad=1
      fi
    done
    [[ "$bad" == 0 ]] || return 1
  elif [[ $# -gt 0 ]]; then
    args=("$@")
  fi
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-sub-err.XXXXXX")" || { echo "submodule 받기 실패: 임시 파일을 만들 수 없습니다" >&2; return 1; }
  while IFS= read -r -d '' rec; do
    p="${rec#*$'\n'}"
    # gitlink 가 없는 .gitmodules 항목은 후보에서 조용히 뺍니다.
    _rd_sub_is_gitlink "$super" "$p" || continue
    sm_paths+=("$p")
    key="${rec%%$'\n'*}"; key="${key#submodule.}"
    sm_names+=("${key%.path}")
  done < <(_rd_sub_list "$super")

  for ((i = 0; i < ${#sm_paths[@]}; i++)); do
    p="${sm_paths[i]}"; name="${sm_names[i]}"; disp="${_RD_SUB_PREFIX:-}${p}"
    direct=0; target=1; subs=()
    if (( ${#args[@]} > 0 )); then
      for a in "${args[@]}"; do
        if [[ "$a" == "$p" ]]; then direct=1
        elif [[ "$a" == "$p"/* ]]; then subs+=("${a#"$p"/}"); fi
      done
      # 경로를 직접 지정하면 그 아래는 전부 대상입니다.
      (( direct == 1 )) && subs=()
      (( direct == 0 && ${#subs[@]} == 0 )) && continue
      (( direct == 1 )) || target=0
    fi
    st="$(git -C "$super" submodule status -- "$p" 2>/dev/null | head -n 1)" || true
    if [[ -z "$st" ]]; then
      echo "submodule 받기 실패: $disp" >&2
      echo "  submodule 상태를 읽을 수 없습니다" >&2
      rc=1; continue
    fi
    c="${st:0:1}"
    # kind: empty(비어 있음) / noindex(복제만 되고 체크아웃한 적 없음) / ready(초기화됨)
    kind=ready
    if [[ "$c" == "-" ]]; then
      kind=empty
    elif _rd_is_repo_root "$super/$p"; then
      idx="$(git -C "$super/$p" rev-parse --path-format=absolute --git-path index 2>/dev/null)" || idx=""
      [[ -n "$idx" && ! -e "$idx" ]] && kind=noindex
    fi
    src_init=0
    if [[ -n "$src" ]]; then
      st_src="$(git -C "$src" submodule status -- "$p" 2>/dev/null | head -n 1)" || true
      [[ -n "$st_src" && "${st_src:0:1}" != "-" ]] && _rd_is_repo_root "$src/$p" && src_init=1
    fi
    ok=0
    if [[ "$kind" == ready ]]; then
      (( direct == 1 )) && echo "이미 받았습니다: $disp" >&2
      ok=1
    elif (( target == 1 )); then
      if (( src_init == 0 )) && [[ "$mode" == main-only ]]; then
        printf '%s\n' "$disp"
        continue
      fi
      x="$(GIT_LITERAL_PATHSPECS=1 git -C "$super" ls-files -s -- "$p" 2>/dev/null | head -n 1)"
      x="${x#* }"; oid="${x%% *}"; oid="${oid:0:7}"
      flags=()
      if (( src_init == 0 )); then
        reason="${_RD_SUB_NOSRC_REASON:-메인 체크아웃에서 초기화하지 않았습니다}"
        if [[ "$kind" == empty ]]; then flags=(--init --recursive); fi
      else
        reason="커밋 ${oid} 이 메인 체크아웃에 없습니다"
        git -C "$super" submodule init -- "$p" >&2 2>"$errf" || true
      fi
      orig="$(git -C "$super" config "submodule.${name}.url" 2>/dev/null)" || orig=""
      if (( src_init == 1 )) && [[ "$kind" == empty ]]; then
        # D2 3~4: 메인 체크아웃을 원천으로 로컬 복제. 이 명령에만 protocol.file.allow 를 줍니다.
        echo "submodule ${disp}: 메인 체크아웃에서 받습니다" >&2
        if git -C "$super" -c protocol.file.allow=always -c "submodule.${name}.url=${src}/${p}" \
             submodule update -- "$p" >&2 2>"$errf"; then
          if _rd_sub_not_ready "$super" "$p" "$name" "$errf"; then
            _rd_sub_fail "$disp" "$errf"; rc=1; continue
          fi
          if [[ -n "$orig" ]]; then
            git -C "$super/$p" remote set-url origin "$orig" >&2 2>"$errf" || {
              _rd_sub_fail "$disp" "$errf"; rc=1; continue; }
          fi
          ok=1
        elif ! _rd_is_repo_root "$super/$p"; then
          reason="메인 체크아웃에서 받지 못했습니다"
        fi
      fi
      if (( ok == 0 )); then
        # D2 5~6, D1 표 3행: 원격에서 받습니다. 복제가 남아 있으면 origin 을 원래 URL 로 먼저 되돌립니다.
        if _rd_is_repo_root "$super/$p" && [[ -n "$orig" ]]; then
          git -C "$super/$p" remote set-url origin "$orig" >&2 2>/dev/null || true
        fi
        printf '원격 접근이 필요합니다: %s — %s\n' "$disp" "$reason" >&2
        if _rd_sub_remote "$errf" git -C "$super" submodule update ${flags[@]+"${flags[@]}"} -- "$p"; then
          cat "$errf" >&2
          if _rd_sub_not_ready "$super" "$p" "$name" "$errf"; then
            _rd_sub_fail "$disp" "$errf"; rc=1; continue
          fi
          ok=1
        else
          _rd_sub_fail "$disp" "$errf"; rc=1; continue
        fi
      fi
    fi
    # D4: 초기화된 경로 아래 중첩으로 한 단계 내려갑니다. 원천도 같은 경로로 내려갑니다.
    if (( ok == 1 )) && _rd_is_repo_root "$super/$p"; then
      local saved="${_RD_SUB_PREFIX:-}" nsrc=""
      (( src_init == 1 )) && nsrc="$src/$p"
      _RD_SUB_PREFIX="${saved}${p}/"
      rd_submodule_fill "$super/$p" "$nsrc" "$mode" ${subs[@]+"${subs[@]}"} || rc=1
      _RD_SUB_PREFIX="$saved"
    fi
  done
  rm -f "$errf"
  return "$rc"
}

# ---------------------------------------------------------------------------
# worktree 정리 (spec 2.4 D15~D16) — submodule 을 품은 worktree 는 `git worktree remove` 가 거부한다.
# ---------------------------------------------------------------------------

# _rd_run_limited <초> <stderr 파일> <명령…> — 명령의 stdout 을 내고 종료 코드를 돌려줍니다.
# <초> 안에 끝나지 않으면 TERM 을 보내고, 2초 유예 뒤에도 살아 있으면 KILL 합니다. 이때 124 를 돌려줍니다.
# TERM 을 무시하는 실행(호출 셸의 `trap '' TERM` 상속)에서도 유한 시간에 돌아오게 하기 위해서입니다.
# macOS 기본 환경에 timeout 명령이 없어 bash 로 감시합니다. 명령의 stdout 은 임시 파일로 받습니다 — 멈춘 명령의
# 자식이 살아남아도 호출부 명령 치환의 파이프를 붙잡지 않게 합니다. 감시 프로세스의 출력도 /dev/null 입니다.
# 명령은 자기 프로세스 그룹(set -m)으로 띄우고 신호를 그룹에 보냅니다. git 이 띄운 fetch·ssh·submodule helper 가
# 살아남아 반환 뒤에 submodule 을 체크아웃하면, 사용자의 재시도·작업과 경쟁하기 때문입니다.
# 시간 초과면 그룹이 모두 사라진 뒤(유예 2초, 그 뒤 KILL) 돌아옵니다.
_rd_run_limited() {
  local lim="$1" errf="$2" pid wd rc=0 flag outf had_m=0 i=0
  shift 2
  flag="$(mktemp "${TMPDIR:-/tmp}/rd-lim.XXXXXX")" || return 1
  outf="$(mktemp "${TMPDIR:-/tmp}/rd-lim-out.XXXXXX")" || { rm -f "$flag"; return 1; }
  [[ "$-" == *m* ]] && had_m=1
  set -m
  "$@" </dev/null >"$outf" 2>"$errf" &
  pid=$!
  # 감시도 자기 프로세스 그룹으로 띄우고 끝낼 때 그룹째 끝냅니다. 서브셸만 끝내면 그 안의 sleep 이 시한까지 남고,
  # 호출부 프로세스 그룹에 들어 있으면 그 그룹을 붙잡습니다(큐 발행은 archive 그룹이 빌 때까지 기다립니다).
  ( sleep "$lim"
    if kill -0 "$pid" 2>/dev/null; then
      echo 1 > "$flag"; kill -TERM -- "-$pid" 2>/dev/null
      sleep 2
      kill -KILL -- "-$pid" 2>/dev/null
    fi ) >/dev/null 2>&1 &
  wd=$!
  [[ "$had_m" == 1 ]] || set +m
  # 신호로 끝난 작업의 셸 알림(「Terminated: 15 …」·「Killed: 9 …」)이 호출부 stderr 에 섞이지 않게 막습니다.
  wait "$pid" 2>/dev/null || rc=$?
  # 끝낸 감시를 여기서 거둡니다. 거두지 않으면 bash 가 나중에 「Terminated」 를 호출부 stderr 에 찍습니다.
  # KILL 로 끝냅니다. 호출 셸이 TERM 을 무시하면 감시도 이를 상속해, TERM 으로는 아래 wait 가 시한까지 막힙니다.
  kill -KILL -- "-$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  if [[ -s "$flag" ]]; then
    rc=124
    while kill -0 -- "-$pid" 2>/dev/null && [[ "$i" -lt 20 ]]; do sleep 0.1; i=$((i + 1)); done
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  [[ "$rc" == 124 ]] || cat "$outf"
  rm -f "$flag" "$outf"
  return "$rc"
}

# _rd_keeper_borrows <keeper 저장소> — <keeper> 가 objects/info/alternates 파일로 다른 저장소의 객체를 빌려 쓰면 0, 아니면 1.
#   빌린 객체는 원래 저장소가 지워지면 읽을 수 없다. 그 원래 저장소가 정리하려는 작업 worktree 의 submodule 이면, keeper 의
#   브랜치가 가리키는 커밋을 worktree 와 함께 잃는다. alternates 가 어디를 가리키는지는 해석하지 않고(상대 경로·중첩 alternates),
#   빌려 쓰는 keeper 는 보존 근거로 쓰지 않는다. 경로를 구하지 못해도 빌려 쓰는 쪽(0)으로 본다.
_rd_keeper_borrows() {
  local af
  af="$(git -C "$1" rev-parse --git-path objects/info/alternates 2>/dev/null)" || return 0
  [[ -n "$af" ]] || return 0
  [[ "$af" == /* ]] || af="$1/$af"
  [[ -s "$af" ]]
}

# _rd_keeper_drop <keeper 저장소> — stdin 의 커밋 OID 목록에서 <keeper> 의 로컬 브랜치·태그로 닿는 커밋을 빼고 나머지를 낸다.
#   <keeper> 에 객체만 있거나 원격 추적 ref·FETCH_HEAD·HEAD 로만 닿는 커밋은 빼지 않는다 — gc·체크아웃 이동으로 잃을 수 있고,
#   원격 추적 ref 는 원격 브랜치가 지워진 뒤 `fetch --prune` 으로 사라진다. 원격에 있는지는 호출부(_rd_unpushed_commits)가
#   작업 쪽 저장소의 원격 추적 ref 와 원격 tag 조회로 따로 본다.
#   판정 명령이 실패하면 아무것도 빼지 않는다(미push 로 남기는 안전한 쪽). 호출부는 이 함수가 실패하면 판정 실패(return 1)로 본다.
#   환경 변수 GIT_ALTERNATE_OBJECT_DIRECTORIES 는 빼고 조회한다. 파일 alternates 를 쓰는 keeper 는 호출부가 넘기지 않는다
#   (_rd_keeper_borrows).
_rd_keeper_drop() {
  local keeper="$1" list have unreach res
  list="$(cat)"
  [[ -n "$list" ]] || return 0
  # 목록은 인자·환경 변수·임시 파일이 아니라 pipe 로 넘긴다 — 미push 이력이 길면(수천~수만 커밋) OS 의 인자 크기 상한(ARG_MAX)을
  #   넘어 awk·git 실행 자체가 실패하고, 임시 파일은 디스크·할당량이 차면 일부만 쓰인다. 어느 쪽이든 빈 출력이나 빠진 판정이
  #   「모두 보존됨」 으로 읽혀 worktree 를 지운다.
  have="$(printf '%s\n' "$list" | env -u GIT_ALTERNATE_OBJECT_DIRECTORIES git -C "$keeper" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null \
    | awk '$2 == "commit" { print $1 }')" || have=""
  if [[ -z "$have" ]]; then printf '%s\n' "$list"; return 0; fi
  if ! unreach="$(printf '%s\n' "$have" | env -u GIT_ALTERNATE_OBJECT_DIRECTORIES git -C "$keeper" rev-list --stdin --not --branches --tags 2>/dev/null)"; then
    printf '%s\n' "$list"; return 0
  fi
  # 세 목록을 구획 표시(#H·#U·#L)와 함께 한 흐름으로 넘기고(printf 는 셸 내장이라 인자 크기 상한이 없다), 끝 표시 #E 까지 읽었을
  #   때만 결과를 낸다. 흐름이 중간에 끊기면 awk 가 실패로 끝나고 원래 목록을 그대로 낸다.
  if ! res="$(printf '%s\n' '#H' "$have" '#U' "$unreach" '#L' "$list" '#E' | awk '
      /^#/ { sec = $0; next }
      $0 == "" { next }
      sec == "#H" { has[$0] = 1; next }
      sec == "#U" { un[$0] = 1; next }
      sec == "#L" { out[++n] = $0 }
      END { if (sec != "#E") exit 3
            for (i = 1; i <= n; i++) if (!(out[i] in has) || (out[i] in un)) print out[i] }')"; then
    printf '%s\n' "$list"; return 0
  fi
  [[ -z "$res" ]] || printf '%s\n' "$res"
}

# _rd_unpushed_commits <repo> [표시 경로] [keeper 저장소] — 원격 브랜치에도 원격 tag 에도 없는 커밋을 stdout 으로. 명령 실패는 return 1.
# <keeper> 를 주면(작업 worktree 의 submodule 에 대응하는 기본 체크아웃의 같은 경로 submodule 저장소) 그 저장소의 로컬 브랜치·태그로
# 닿는 커밋도 뺍니다 — 발행(archive_submodule_carry)이 작업 커밋을 그 저장소로 옮겨 브랜치로 남기면 worktree 를 지워도 잃지
# 않습니다(FR archive-carry-worktree-submodule-commits). keeper 의 원격 추적 ref 는 근거로 쓰지 않습니다 — 원격 브랜치가 지워진 뒤
# `fetch --prune` 하면 사라져, 지운 worktree 의 커밋을 붙잡는 ref 가 남지 않습니다.
# keeper 가 objects/info/alternates 로 다른 저장소의 객체를 빌려 쓰면 keeper 를 쓰지 않습니다(_rd_keeper_borrows, 안내 줄은 stderr).
# 원격 tracking ref 만 보면 원격에 push 한 tag 로만 닿는 커밋을 미push 로 셉니다. 그래서 후보가 있을 때만
# 원격마다 `ls-remote --tags` 를 묻고, 로컬에 있는 tag 객체를 제외 기준에 더해 다시 셉니다.
# ls-remote 가 실패한 원격(네트워크·인증)은 제외 기준에 넣지 않습니다 — 미push 로 남기는 안전한 쪽입니다.
# 조회 시작과 실패 원인은 stderr 로 알립니다(stdout 은 판정 결과 전용). 전송 설정(core.sshCommand·GIT_SSH 등)은
# 사용자 것을 그대로 쓰고, https 자격 증명 프롬프트만 끕니다.
# 조회마다 대기 상한(RD_LSREMOTE_TIMEOUT 초, 기본 20)을 둡니다. 이 함수는 `rd task list` 의 공유 락 안에서도
# 불리므로, 응답하지 않는 원격이 목록과 다른 작업의 promote·archive 를 붙잡지 않게 합니다. 초과는 조회 실패와 같습니다.
_rd_unpushed_commits() {
  local repo="$1" disp="${2:-$1}" keeper="${3:-}" out remote refs oid name err rc lim="${RD_LSREMOTE_TIMEOUT:-20}"
  local -a excl=()
  out="$(git -C "$repo" rev-list --all --not --remotes 2>/dev/null)" || return 1
  if [[ -n "$out" && -n "$keeper" ]] && _rd_keeper_borrows "$keeper"; then
    echo "submodule ${disp}: 기본 체크아웃 submodule 이 다른 저장소의 객체를 빌려 써(objects/info/alternates) 그 브랜치·태그를 보존 근거로 쓰지 않습니다" >&2
    keeper=""
  fi
  [[ -z "$out" || -z "$keeper" ]] || out="$(printf '%s\n' "$out" | _rd_keeper_drop "$keeper")" || return 1
  [[ -n "$out" ]] || return 0
  err="$(mktemp "${TMPDIR:-/tmp}/rd-lsr-err.XXXXXX")" || err=/dev/null
  while IFS= read -r remote; do
    [[ -n "$remote" ]] || continue
    echo "submodule ${disp}: 원격 브랜치에 없는 커밋이 있어 원격 ${remote} 의 tag 를 조회합니다 (git ls-remote --tags, 최대 ${lim}초)" >&2
    rc=0; refs="$(_rd_run_limited "$lim" "$err" env GIT_TERMINAL_PROMPT=0 git -C "$repo" ls-remote --tags "$remote")" || rc=$?
    if [[ "$rc" != 0 ]]; then
      if [[ "$rc" == 124 ]]; then
        echo "submodule ${disp}: 원격 ${remote} tag 조회가 ${lim}초 안에 끝나지 않아 멈췄습니다 — 이 원격의 tag 는 push 근거로 쓰지 않습니다" >&2
      else
        echo "submodule ${disp}: 원격 ${remote} tag 조회 실패 — 이 원격의 tag 는 push 근거로 쓰지 않습니다 ($(head -1 "$err" 2>/dev/null))" >&2
      fi
      continue
    fi
    while IFS=$'\t' read -r oid name; do
      [[ -n "$oid" ]] || continue
      git -C "$repo" cat-file -e "${oid}^{commit}" 2>/dev/null && excl+=("$oid")
    done <<<"$refs"
  done < <(git -C "$repo" remote 2>/dev/null)
  [[ "$err" == /dev/null ]] || rm -f "$err"
  [[ "${#excl[@]}" -gt 0 ]] || { printf '%s\n' "$out"; return 0; }
  out="$(git -C "$repo" rev-list --all --not --remotes "${excl[@]}" 2>/dev/null)" || return 1
  [[ -z "$out" || -z "$keeper" ]] || out="$(printf '%s\n' "$out" | _rd_keeper_drop "$keeper")" || return 1
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# rd_submodule_tree_clean <path> [--require-pushed] — 최상위와 초기화된 모든 깊이의 submodule 을 검사한다.
# 0: clean / 1: dirty — stdout 한 줄 `<원인>\t<경로>`, 원인 ∈ changes · unrecorded-commit · unpushed.
# 판정 불가(명령 실패)도 1 이며 `changes` 로 보고한다.
rd_submodule_tree_clean() {
  local wt="$1" req="${2:-}" list tl smp disp head idx st repo main="" keeper
  list="$(mktemp "${TMPDIR:-/tmp}/rd-wt-sub.XXXXXX")" || { printf 'changes\t.\n'; return 1; }
  # 한 레코드 = toplevel \0 sm_path \0 displaypath \0 HEAD \0 (경로의 개행·탭에 안전하도록 NUL 구분)
  # 미push 판정에서 커밋을 이미 보존한 곳으로 볼 기본 체크아웃(주 worktree). <wt> 자신이면 쓰지 않는다.
  if [[ "$req" == "--require-pushed" ]]; then
    main="$(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || main=""
    if [[ -n "$main" ]] && [[ "$(cd "$main" 2>/dev/null && pwd -P)" == "$(cd "$wt" 2>/dev/null && pwd -P)" ]]; then main=""; fi
  fi
  if ! git -C "$wt" submodule foreach --recursive --quiet \
        'printf "%s\0%s\0%s\0%s\0" "$toplevel" "$sm_path" "$displaypath" "$(git rev-parse HEAD)"' > "$list" 2>/dev/null; then
    rm -f "$list"; printf 'changes\t.\n'; return 1
  fi
  # 최상위 저장소의 수정·미추적 파일, 그리고 스테이징만 된 gitlink 변경(--ignore-submodules=all 이 숨김)
  if ! st="$(git -C "$wt" status --porcelain --untracked-files=normal --ignore-submodules=all 2>/dev/null)" || [[ -n "$st" ]] \
     || ! git -C "$wt" diff --cached --quiet --ignore-submodules=none 2>/dev/null; then
    rm -f "$list"; printf 'changes\t.\n'; return 1
  fi
  while IFS= read -r -d '' tl && IFS= read -r -d '' smp && IFS= read -r -d '' disp && IFS= read -r -d '' head; do
    repo="$wt/$disp"
    if ! st="$(git -C "$repo" status --porcelain --untracked-files=normal --ignore-submodules=all 2>/dev/null)" || [[ -n "$st" ]] \
       || ! git -C "$repo" diff --cached --quiet --ignore-submodules=none 2>/dev/null; then
      rm -f "$list"; printf 'changes\t%s\n' "$disp"; return 1
    fi
    # 체크아웃 HEAD 대 상위 인덱스 gitlink
    if ! idx="$(GIT_LITERAL_PATHSPECS=1 git -C "$tl" ls-files -s -- "$smp" 2>/dev/null)"; then
      rm -f "$list"; printf 'changes\t%s\n' "$disp"; return 1
    fi
    idx="${idx#* }"; idx="${idx%% *}"
    if [[ -z "$idx" || "$idx" != "$head" ]]; then
      rm -f "$list"; printf 'unrecorded-commit\t%s\n' "$disp"; return 1
    fi
    if [[ "$req" == "--require-pushed" ]]; then
      # 기본 체크아웃의 같은 경로가 초기화된 submodule 저장소일 때만 keeper 로 쓴다(빈 디렉터리면 상위 저장소를 잡으므로 최상위 대조).
      keeper=""
      if [[ -n "$main" ]] && _rd_is_repo_root "$main/$disp"; then keeper="$main/$disp"; fi
      if ! st="$(_rd_unpushed_commits "$repo" "$disp" "$keeper")"; then
        rm -f "$list"; printf 'changes\t%s\n' "$disp"; return 1
      fi
      if [[ -n "$st" ]]; then
        rm -f "$list"; printf 'unpushed\t%s\n' "$disp"; return 1
      fi
    fi
  done < "$list"
  rm -f "$list"
  return 0
}

# rd_worktree_has_submodule <path> — 0: 초기화된 submodule 이 있음 / 1: 없음.
# 조회 자체가 실패하면 0(있음으로 간주)입니다 — 있음 쪽이 더 많은 검사를 거치는 안전한 쪽입니다.
rd_worktree_has_submodule() {
  local out line
  out="$(git -C "$1" submodule status --recursive 2>/dev/null)" || return 0
  while IFS= read -r line; do
    [[ -n "$line" && "${line:0:1}" != "-" ]] && return 0
  done <<EOF
$out
EOF
  return 1
}

# rd_worktree_remove_safe <path> — 0: 제거함 / 1: dirty 라 지우지 않음(stdout: rd_submodule_tree_clean 한 줄)
# / 2: git 실패(stdout: git 출력 첫 줄). submodule 이 없으면 종전과 같은 `git worktree remove <path>` 입니다.
# submodule 이 있으면 `--require-pushed` 검사를 통과한 경우에만 `--force` 로 지웁니다.
rd_worktree_remove_safe() {
  local wt="$1" out
  if rd_worktree_has_submodule "$wt"; then
    if out="$(rd_submodule_tree_clean "$wt" --require-pushed)"; then
      if out="$(git worktree remove --force "$wt" 2>&1)"; then return 0; fi
      printf '%s\n' "${out%%$'\n'*}"; return 2
    fi
    printf '%s\n' "$out"; return 1
  fi
  if out="$(git worktree remove "$wt" 2>&1)"; then return 0; fi
  printf '%s\n' "${out%%$'\n'*}"; return 2
}

# rd_worktree_hold_info <원인> <submodule 경로> <worktree 경로> — spec D17 표의 사유와 복구 명령을 `사유<TAB>명령` 한 줄로 낸다.
# 원인은 rd_submodule_tree_clean 이 낸 값(changes · unrecorded-commit · unpushed)입니다. 명령은 쉘 인용을 거칩니다.
rd_worktree_hold_info() {
  local cause="$1" sub="$2" wt="$3" lbl
  # 사유 문구에 넣는 경로의 TAB·개행은 사유<TAB>명령 형식을 깨므로 공백으로 바꿉니다. 명령 쪽 %q 는 원래 경로를 씁니다.
  lbl="${sub//[$'\t\n']/ }"
  case "$cause" in
    unrecorded-commit)
      printf 'submodule %s 에 gitlink 로 올리지 않은 커밋이 체크아웃되어 있어 지우지 않았습니다\tgit -C %q log --oneline -1\n' "$lbl" "$wt/$sub" ;;
    unpushed)
      printf 'submodule %s 에 원격에 없는 커밋(기본 체크아웃 submodule 의 브랜치·태그에도 없음)이 있어 지우지 않았습니다. 지우면 그 커밋을 잃습니다. 원격에 이미 있다면 git -C %q fetch 뒤 다시 실행하십시오\tgit -C %q log --oneline --all --not --remotes\n' "$lbl" "$wt/$sub" "$wt/$sub" ;;
    *)
      if [[ "$sub" != "." ]]; then
        printf 'worktree 또는 그 submodule 에 미커밋 변경이 있어 지우지 않았습니다 (submodule 경로: %s)\tgit -C %q status --short\n' "$lbl" "$wt/$sub"
      else
        printf 'worktree 또는 그 submodule 에 미커밋 변경이 있어 지우지 않았습니다 (submodule 경로: %s)\tgit -C %q status --short\n' "$lbl" "$wt"
      fi ;;
  esac
}

# ---------------------------------------------------------------------------
# 발행 뒤 체크아웃 갱신 (spec 2.3 D11~D14) — 기본 worktree 의 submodule 체크아웃을 발행된 gitlink 에 맞춘다.
# ---------------------------------------------------------------------------

# _rd_repo_has_changes <repo> — 0: 수정·미추적·스테이징된 변경이 있음(판정 불가 포함) / 1: 없음.
# rd_submodule_tree_clean 과 달리 「체크아웃 HEAD ≠ 상위 gitlink」 는 보지 않습니다 — 그 상태가 이 단계가 고칠 대상입니다.
_rd_repo_has_changes() {
  local st
  st="$(git -C "$1" status --porcelain --untracked-files=normal --ignore-submodules=all 2>/dev/null)" || return 0
  [[ -z "$st" ]] || return 0
  git -C "$1" diff --cached --quiet --ignore-submodules=none 2>/dev/null || return 0
  return 1
}

# rd_submodule_checkout_sync <wt> <oid> — <oid> 의 직접 gitlink 마다 <wt> 의 체크아웃이 어긋나 있으면 맞춘다.
# stdout 은 NUL 구분 4필드 레코드 `kind \0 경로 \0 사유 \0 복구명령 \0` 입니다.
#   kind = ok(맞춤, 사유·명령 빈 값) / submodule(정리 잔여 항목: 갱신하지 않았거나 갱신 실패)
# 반환: 0 / 1 목록 조회 실패(레코드 없음). 초기화 안 된 경로(저장소 루트가 아님)와 불일치 없는 경로는 아무것도 내지 않습니다.
# 불일치는 `submodule status --recursive` 의 `+` 줄로 보므로 중첩 submodule 만 어긋나도 잡힙니다.
# 보존 검사(변경·ref 도달)는 불일치가 있는 최상위 항목 아래 초기화된 모든 깊이의 저장소(직접 submodule 자신 포함)에 합니다.
# 중첩 저장소의 `+` 는 지금 체크아웃된 부모 인덱스 기준이라, 부모가 옮겨지면 `+` 가 없던 중첩 HEAD 도 재귀 갱신으로 옮겨집니다.
rd_submodule_checkout_sync() {
  local wt="$1" oid="$2" raw rec path meta sline disp="" repo blocked mismatch reason cmd upd first
  local qwt qpath rc subs ent
  raw="$(mktemp "${TMPDIR:-/tmp}/rd-sync-ls.XXXXXX")" || return 1
  git -C "$wt" ls-tree -r -z "$oid" > "$raw" 2>/dev/null || { rm -f "$raw"; return 1; }
  qwt="$(printf '%q' "$wt")"
  while IFS= read -r -d '' rec; do
    [[ "$rec" == "160000 "* && "$rec" == *$'\t'* ]] || continue
    path="${rec#*$'\t'}"
    qpath="$(printf '%q' "$path")"
    _rd_is_repo_root "$wt/$path" || continue
    blocked=""; mismatch=0; disp="$path"; upd=""
    if ! meta="$(git -C "$wt" submodule status --recursive -- "$path" 2>&1)"; then
      blocked="failed"; upd="${meta%%$'\n'*}"
    else
      while IFS= read -r sline; do
        if [[ "${sline:0:1}" == "+" ]]; then mismatch=1; break; fi
      done <<EOF2
$meta
EOF2
      [[ "$mismatch" == 1 ]] || continue
      # 갱신이 옮길 수 있는 저장소 목록: 직접 submodule 자신("") + 초기화된 모든 깊이의 중첩 저장소(NUL 구분 displaypath).
      subs="$(mktemp "${TMPDIR:-/tmp}/rd-sync-sub.XXXXXX")" || subs=""
      if [[ -z "$subs" ]]; then
        blocked="failed"; upd="임시 파일 생성 실패"
      elif ! git -C "$wt/$path" submodule foreach --recursive --quiet 'printf "%s\0" "$displaypath"' > "$subs" 2> "$subs.err"; then
        blocked="failed"; upd="$(head -1 "$subs.err" 2>/dev/null || true)"
      else
        while IFS= read -r -d '' ent; do
          if [[ -z "$ent" ]]; then disp="$path"; else disp="$path/$ent"; fi
          repo="$wt/$disp"
          if _rd_repo_has_changes "$repo"; then blocked="changes"; break; fi
          rc=0; first="$(git -C "$repo" for-each-ref --contains HEAD 2> "$subs.ferr")" || rc=$?
          if [[ "$rc" != 0 ]]; then
            # 판정에는 stdout 만 쓰고, stderr 는 실패 사유 문구에만 씁니다.
            blocked="failed"; upd="$(head -1 "$subs.ferr" 2>/dev/null || true)"; [[ -n "$upd" ]] || upd="rc=$rc"; break
          fi
          if [[ -z "$first" ]]; then blocked="unreachable"; break; fi
        done < <(printf '\0'; cat "$subs")
      fi
      [[ -z "$subs" ]] || rm -f "$subs" "$subs.err" "$subs.ferr"
      subs=""
    fi
    case "$blocked" in
      changes)
        reason="발행된 gitlink 와 다른 커밋이 체크아웃되어 있고 변경이 있어 갱신하지 않았습니다. 이 상태에서 git add -A 나 git commit -a 를 하면 발행을 되돌리는 커밋이 생깁니다. 변경을 정리한 뒤 git -C ${qwt} submodule update --init --recursive -- ${qpath}"
        cmd="git -C $(printf '%q' "$wt/$disp") status --short" ;;
      unreachable)
        reason="submodule ${disp} 의 체크아웃 커밋이 어떤 브랜치·태그에도 없어 갱신하지 않았습니다. 옮기면 그 커밋은 reflog 에만 남습니다. 커밋을 브랜치로 보존한 뒤(git -C $(printf '%q' "$wt/$disp") branch <이름>) git -C ${qwt} submodule update --init --recursive -- ${qpath}"
        cmd="git -C $(printf '%q' "$wt/$disp") log --oneline -1" ;;
      failed)
        reason="submodule ${disp} 판정 실패 (${upd})"
        cmd="git -C ${qwt} submodule status --recursive -- ${qpath}" ;;
      *)
        if upd="$(git -C "$wt" submodule update --init --recursive --checkout -- "$path" 2>&1)"; then
          # update=none·merge·rebase 설정이면 성공해도 체크아웃이 안 맞을 수 있다 — 다시 본다.
          if meta="$(git -C "$wt" submodule status --recursive -- "$path" 2>/dev/null)" && [[ "$meta" != *$'\n+'* && "${meta:0:1}" != "+" ]]; then
            printf 'ok\0%s\0\0\0' "$path"
            continue
          fi
          upd="갱신 뒤에도 체크아웃이 gitlink 와 다름"
        else
          upd="${upd%%$'\n'*}"
        fi
        reason="submodule 체크아웃 갱신 실패 (${upd})"
        cmd="git -C ${qwt} submodule update --init --recursive -- ${qpath}" ;;
    esac
    reason="${reason//$'\n'/ }"; reason="${reason//$'\t'/ }"
    printf 'submodule\0%s\0%s\0%s\0' "$path" "$reason" "$cmd"
  done < "$raw"
  rm -f "$raw"
  return 0
}
