#!/usr/bin/env bash
# archive.sh 정리 잔여(worktree·브랜치 등을 지우지 못한 항목)를 slug 별로 git 공용 디렉터리에 기록하고 보인다.
# 실행 파일로 부른다: bash cleanup_pending.sh <write|clear|resolve|show|summary> ...
# source 하지 않는다 — 호출부 셸 옵션·변수 이름과 섞이지 않게 한다.
#
# 기록: <git-common-dir>/rd-workflow/archive-cleanup-pending/<slug> (한 줄 = 잔여 항목 1건, TAB 4필드:
#   kind / identifier(%q 인코딩 그대로) / 사유 / 복구 명령).
# 쓰기는 같은 디렉터리의 임시 파일에 쓴 뒤 mv 로 교체한다. 실행은 직렬 전제다(archive.sh 는 기본 브랜치 락 안에서 돈다).
# 종료 코드: 쓰기 계열(write·clear·resolve) 0/1, 보이기 계열(show·summary) 0/2.
set -uo pipefail

_CP_SUB=archive-cleanup-pending

cp_die() { # <rc> <메시지>
  echo "cleanup_pending: $2" >&2
  exit "$1"
}

# slug 검사: 빈 값, '/' 포함, '.' 으로 시작하면 거부. 거부 rc 는 호출자가 정한다.
cp_slug_ok() {
  local s="$1"
  [[ -n "$s" ]] || return 1
  case "$s" in
    */*) return 1 ;;
    .*) return 1 ;;
  esac
  return 0
}

# 기록 디렉터리 경로를 CP_DIR 에 넣는다. 실패하면 rc 1.
cp_resolve_dir() {
  local common
  common="$(git -C "${project_root:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$common" ]] || return 1
  CP_DIR="$common/rd-workflow/$_CP_SUB"
  return 0
}

# 기록 디렉터리 상태. 0: 디렉터리이고 읽고 들어갈 수 있음 / 3: 실제로 없음 / 1: 접근 실패·디렉터리 아님.
# `-e` 는 상위 경로에 들어갈 수 없을 때도 거짓이라, 상위 경로마다 들어갈 수 있음을 확인한 뒤에만 「없음」 으로 본다.
cp_dir_state() {
  local parent="${CP_DIR%/*}" common
  common="${parent%/*}"
  [[ -d "$common" && -x "$common" ]] || return 1
  [[ -e "$parent" ]] || return 3
  [[ -d "$parent" && -x "$parent" ]] || return 1
  [[ -e "$CP_DIR" ]] || return 3
  [[ -d "$CP_DIR" && -r "$CP_DIR" && -x "$CP_DIR" ]] || return 1
  return 0
}

# 파일 mtime(epoch 초). GNU stat 먼저, 실패하면 BSD stat.
cp_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" && [[ "$m" =~ ^[0-9]+$ ]] && { printf '%s' "$m"; return 0; }
  m="$(stat -f %m "$1" 2>/dev/null)" && [[ "$m" =~ ^[0-9]+$ ]] && { printf '%s' "$m"; return 0; }
  return 1
}

# --- 쓰기 계열 ---
cmd_write() {
  local slug="${1:-}"
  cp_slug_ok "$slug" || cp_die 1 "slug 가 올바르지 않습니다: [$slug]"
  cp_resolve_dir || cp_die 1 "git 공용 디렉터리를 구하지 못했습니다"
  mkdir -p "$CP_DIR" 2>/dev/null || cp_die 1 "기록 디렉터리를 만들지 못했습니다: $CP_DIR"
  # 기록 자리가 디렉터리 등 일반 파일이 아니면 mv 가 그 안으로 옮겨 성공처럼 보인다. 쓰기 전에 막는다.
  if [[ -e "$CP_DIR/$slug" && ! -f "$CP_DIR/$slug" ]]; then
    cp_die 1 "기록 파일 자리가 일반 파일이 아닙니다: $CP_DIR/$slug"
  fi
  local tmp="$CP_DIR/.$slug.tmp.$$" line
  if ! { while IFS= read -r line || [[ -n "$line" ]]; do
           if [[ -n "$line" ]]; then printf '%s\n' "$line"; fi
         done > "$tmp"; } 2>/dev/null; then
    rm -f "$tmp"; cp_die 1 "기록 임시 파일을 쓰지 못했습니다: $tmp"
  fi
  # 비어 있지 않은 줄이 하나도 없으면 clear 와 같다: 기존 기록을 지우고 아무것도 만들지 않는다.
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp" "$CP_DIR/$slug" 2>/dev/null || cp_die 1 "기록 파일을 지우지 못했습니다: $CP_DIR/$slug"
    return 0
  fi
  mv -f "$tmp" "$CP_DIR/$slug" 2>/dev/null || { rm -f "$tmp"; cp_die 1 "기록 파일을 교체하지 못했습니다: $CP_DIR/$slug"; }
}

cmd_clear() {
  local slug="${1:-}"
  cp_slug_ok "$slug" || cp_die 1 "slug 가 올바르지 않습니다: [$slug]"
  cp_resolve_dir || cp_die 1 "git 공용 디렉터리를 구하지 못했습니다"
  local st=0; cp_dir_state || st=$?
  [[ $st -ne 3 ]] || return 0
  [[ $st -eq 0 ]] || cp_die 1 "기록 디렉터리에 접근하지 못했습니다: $CP_DIR"
  [[ -e "$CP_DIR/$slug" ]] || return 0
  rm -f "$CP_DIR/$slug" 2>/dev/null || cp_die 1 "기록 파일을 지우지 못했습니다: $CP_DIR/$slug"
}

cmd_resolve() {
  local slug="${1:-}"; shift || true
  cp_slug_ok "$slug" || cp_die 1 "slug 가 올바르지 않습니다: [$slug]"
  cp_resolve_dir || cp_die 1 "git 공용 디렉터리를 구하지 못했습니다"
  local st=0; cp_dir_state || st=$?
  [[ $st -ne 3 ]] || return 0
  [[ $st -eq 0 ]] || cp_die 1 "기록 디렉터리에 접근하지 못했습니다: $CP_DIR"
  local f="$CP_DIR/$slug"
  [[ -e "$f" ]] || return 0
  [[ -f "$f" ]] || cp_die 1 "기록 파일 자리가 일반 파일이 아닙니다: $f"
  local tmp="$CP_DIR/.$slug.tmp.$$" line kind k drop kept=0
  # 원본을 끝까지 읽고 임시 파일에 다 쓴 경우에만 교체·삭제한다. 실패하면 원본을 그대로 둔다.
  if ! { while IFS= read -r line || [[ -n "$line" ]]; do
           [[ -n "$line" ]] || continue
           kind="${line%%$'\t'*}"
           drop=0
           for k in "$@"; do [[ "$kind" == "$k" ]] && drop=1; done
           if [[ $drop -eq 0 ]]; then printf '%s\n' "$line" || exit 1; kept=$((kept+1)); fi
         done < "$f" > "$tmp"; } 2>/dev/null; then
    rm -f "$tmp"; cp_die 1 "기록 파일을 읽거나 걸러 쓰지 못했습니다: $f"
  fi
  if [[ $kept -eq 0 ]]; then
    rm -f "$tmp" "$f" 2>/dev/null || cp_die 1 "기록 파일을 지우지 못했습니다: $f"
  else
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; cp_die 1 "기록 파일을 교체하지 못했습니다: $f"; }
  fi
}

# --- 보이기 계열 ---
# 대상 기록 파일을 CP_FILES(개행 구분 slug 목록)에 모은다. 조회 실패는 rc 2 로 끝낸다.
cp_collect() {
  local since="" slugs=() s m f
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since)
        [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || cp_die 2 "조회 실패 — --since 값이 올바르지 않습니다"
        since="$2"; shift 2 ;;
      *) slugs+=("$1"); shift ;;
    esac
  done
  cp_resolve_dir || cp_die 2 "조회 실패 — git 공용 디렉터리를 구하지 못했습니다"
  CP_FILES=""
  local st=0; cp_dir_state || st=$?
  [[ $st -ne 3 ]] || return 0
  if [[ $st -ne 0 ]]; then
    [[ ! -e "$CP_DIR" || -d "$CP_DIR" ]] || cp_die 2 "조회 실패 — 기록 디렉터리 자리가 디렉터리가 아닙니다: $CP_DIR"
    cp_die 2 "조회 실패 — 기록 디렉터리에 접근하지 못했습니다: $CP_DIR"
  fi
  if [[ ${#slugs[@]} -gt 0 ]]; then
    for s in "${slugs[@]}"; do cp_slug_ok "$s" || cp_die 2 "조회 실패 — slug 가 올바르지 않습니다: [$s]"; done
  else
    for f in "$CP_DIR"/*; do
      [[ -f "$f" ]] || continue
      slugs+=("$(basename "$f")")
    done
  fi
  [[ ${#slugs[@]} -gt 0 ]] || return 0
  for s in "${slugs[@]}"; do
    f="$CP_DIR/$s"
    [[ -e "$f" ]] || continue
    [[ -f "$f" ]] || cp_die 2 "조회 실패 — 기록 파일 자리가 일반 파일이 아닙니다: $f"
    if [[ -n "$since" ]]; then
      m="$(cp_mtime "$f")" || cp_die 2 "조회 실패 — mtime 을 읽지 못했습니다: $f"
      [[ "$m" -ge "$since" ]] || continue
    fi
    [[ -r "$f" ]] || cp_die 2 "조회 실패 — 기록 파일을 읽지 못했습니다: $f"
    CP_FILES="$CP_FILES$s"$'\n'
  done
  return 0
}

cmd_summary() {
  cp_collect "$@"
  local s n
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    n="$(grep -c . "$CP_DIR/$s" 2>/dev/null)" || n=0
    printf '%s\t%s\n' "$s" "$n"
  done <<< "$CP_FILES"
  return 0
}

cmd_show() {
  cp_collect "$@"
  local s n kind ident why fix any=0
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    any=1
    n="$(grep -c . "$CP_DIR/$s" 2>/dev/null)" || n=0
    echo "$s: 정리 잔여 ${n}건"
    while IFS=$'\t' read -r kind ident why fix || [[ -n "$kind" ]]; do
      [[ -n "$kind" ]] || continue
      echo "  [$kind] $ident"
      echo "    사유: $why"
      echo "    복구: $fix"
    done < "$CP_DIR/$s"
    echo "(정리를 마친 뒤 기록 지우기: bash rd-workflow/scripts/lifecycle/cleanup_pending.sh clear $s)"
  done <<< "$CP_FILES"
  [[ $any -eq 1 ]] || echo "없음"
  return 0
}

sub="${1:-}"; [[ $# -gt 0 ]] && shift
case "$sub" in
  write) cmd_write "$@" ;;
  clear) cmd_clear "$@" ;;
  resolve) cmd_resolve "$@" ;;
  show) cmd_show "$@" ;;
  summary) cmd_summary "$@" ;;
  *) echo "사용법: cleanup_pending.sh <write|clear|resolve|show|summary> ..." >&2; exit 1 ;;
esac
