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
      echo "  복구: git submodule update --init --recursive"
      echo "        원격 객체가 없으면: git -C <submodule 경로> fetch"
      echo "        출력 누락이면: git -C <상위 저장소> config -f .gitmodules --get-regexp 'submodule\\..*\\.ignore' 로 원인 설정을 찾아 해제"
    } >&2
  fi
  rm -f "$exp" "$bad" "$out" "$missing" "$missing.raw"
  return "$rc"
}

# ---------------------------------------------------------------------------
# worktree 정리 (spec 2.4 D15~D16) — submodule 을 품은 worktree 는 `git worktree remove` 가 거부한다.
# ---------------------------------------------------------------------------

# rd_submodule_tree_clean <path> [--require-pushed] — 최상위와 초기화된 모든 깊이의 submodule 을 검사한다.
# 0: clean / 1: dirty — stdout 한 줄 `<원인>\t<경로>`, 원인 ∈ changes · unrecorded-commit · unpushed.
# 판정 불가(명령 실패)도 1 이며 `changes` 로 보고한다.
rd_submodule_tree_clean() {
  local wt="$1" req="${2:-}" list tl smp disp head idx st repo
  list="$(mktemp "${TMPDIR:-/tmp}/rd-wt-sub.XXXXXX")" || { printf 'changes\t.\n'; return 1; }
  # 한 레코드 = toplevel \0 sm_path \0 displaypath \0 HEAD \0 (경로의 개행·탭에 안전하도록 NUL 구분)
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
      if ! st="$(git -C "$repo" rev-list --all --not --remotes 2>/dev/null)"; then
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
      printf 'submodule %s 에 원격에 없는 커밋이 있어 지우지 않았습니다. 지우면 그 커밋을 잃습니다. 원격에 이미 있다면 git -C %q fetch 뒤 다시 실행하십시오\tgit -C %q log --oneline --all --not --remotes\n' "$lbl" "$wt/$sub" "$wt/$sub" ;;
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
