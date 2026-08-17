#!/usr/bin/env bash
# _edit_provenance_common.sh — 편집 출처(edit provenance) 기록 공용 헬퍼. source 전용입니다.
#
# 계약 문서:
#   rd-workflow-workspace/specs/changes/2026-08-13-2110-stop-hook-stale-nudge-during-parallel-phase-change-spec.md
#   §2.3 기록 구조 / §2.4 세대 규칙 / §2.4.1 bump 권한 / §2.4.2 포인터 권위
#   §2.4.3 bump 중간 실패 / §2.8 상한 / §2.9 정리 / §2.12 가시성
#
# 이 파일은 실행 시 아무 동작도 하지 않고 함수만 정의합니다 (_state_common.sh 와 같은 규약).
# project_root 는 caller 가 정의한 변수를 씁니다 (_guard_common.sh · _task_common.sh 모두 정의).
#
# 기록 구조 (§2.3)
#   <root>/.current            내용 'gen-<N>' — 현재 세대 포인터 (mktemp → mv)
#   <root>/.bump-failed        내용 '<stage>' — 직전 bump 실패 흔적 (판정 비참여, §2.12)
#   <root>/gen-<N>/.short-title  내용 '<short-title>'          (mktemp → mv)
#   <root>/gen-<N>/.overflow     존재 = 세대 무효 + 기록 중단   (상한, §2.8)
#   <root>/gen-<N>/<pathkey>.orc 내용 '<state_id>\t<relpath>'   (mktemp → mv)
#   <root>/gen-<N>/<pathkey>.sub 내용 '<state_id>\t<relpath>'   (mktemp → mv)
#
# 설계상 **하지 않는** 것:
#   - 세대 삭제(prune)를 제공하지 않습니다. 런타임(hook·producer·CLI)은 세대를 삭제하지
#     않습니다 (§2.9). 번호 기준·나이 기준 모두 반례가 있었고(포인터 후진 / writer 장시간
#     정지), 삭제 주체를 런타임에서 없애는 것이 유일하게 증명 가능한 안전안입니다.
#     누적 회수는 lifecycle 종료의 ep_purge_root 하나가 담당합니다.
#   - flock·python3 를 쓰지 않습니다. 쓰기가 모두 단일 원자 연산(mkdir / mktemp→mv)이라
#     읽기-고쳐-쓰기가 없어 잠금이 필요 없고, python3 기동 비용(실측 19.4~30ms)은
#     hook 증분 상한(20ms)을 그 자체로 넘깁니다.
#
# 테스트 가능성 제약: rm·mv·mkdir 을 `command` 접두어 **없이** 평문 호출합니다.
# 테스트가 셸 함수 override 로 실패를 주입해 bump 중간 실패 4지점과 정리 실패를
# 결정적으로 재현합니다 (권한 조작은 root·elevated 환경에서 비결정적입니다).
#
# bash 3.2 호환: 연관배열·globstar·extglob·mapfile 을 쓰지 않습니다.

# --- 내부 유틸 -------------------------------------------------------------

# _ep_fmt_cksum <cksum 출력줄> — '<checksum> <length>' 를 '<checksum>-<length>' 로 변환.
# 플랫폼별 cksum 출력 정렬 차이(선행·중복 공백)를 기본 IFS 단어분할로 흡수합니다.
# 두 필드가 모두 10진 정수가 아니면 아무것도 출력하지 않고 return 1.
_ep_fmt_cksum() {
  local line="${1-}" ck len
  # shellcheck disable=SC2086
  set -- $line
  [[ $# -ge 2 ]] || return 1
  ck="$1"; len="$2"
  case "$ck" in ''|*[!0-9]*) return 1 ;; esac
  case "$len" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s-%s' "$ck" "$len"
}

# _ep_read_exact <file> — 파일 전체를 **손실 없이** `_EP_RAW` 에 담습니다 (종단 개행 포함).
# 성공 0 / 파일 부재·NUL 포함 시 1. 형식 판정은 호출자가 문자열 조작으로 수행합니다.
# **파일을 읽는 모든 지점은 이 함수 하나를 씁니다** — 메타(.current·.short-title·.bump-failed)와
# 레코드가 서로 다른 읽기 규칙을 갖지 않게 하려는 것이며, 그 갈라짐이 실제로 결함 4건의
# 원인이었습니다(final diff review 턴 004·006·008).
#
# **stdout 을 쓰지 않는 이유** (턴 006 P1): 값을 `$(...)` 로 돌려받으면 command substitution 이
# **종단 개행을 전부** 지웁니다. 종전의 `_ep_read_whole` 은 LF 를 하나만 제거했지만 호출자에게
# 도착할 때는 `gen-1\n\n` 과 `gen-1\n` 이 똑같이 `gen-1` 이 되어, 손상된 `.current` 가 유효
# 포인터로 통과했습니다. 함수 쪽 규약이 정확해도 **수신 방식이 그 정확성을 무효화**한 사례라
# 그 함수는 이 파일에서 제거했습니다(마지막 호출자였던 `_task_ep_failed_stage` 도 이 함수로
# 옮겼습니다 — 턴 008 P2). 값은 전역 변수로 넘겨야 손상 정보가 남습니다.
#
# **NUL 검출**: 셸 변수는 NUL 을 담지 못하므로 "읽은 뒤 확인" 이 불가능합니다. 대신
# `read -d ''` 의 반환값을 씁니다 — 구분자(NUL)를 만나면 **0**, 못 만나고 EOF 면 **0 이 아닌 값**
# 입니다(실측). 즉 성공이 곧 "NUL 이 있다" 는 뜻이라 fork 없이 판정됩니다.
_ep_read_exact() {
  _EP_RAW=""
  [[ -f "${1-}" ]] || return 1
  if IFS= read -r -d '' _EP_RAW < "$1" 2>/dev/null; then
    _EP_RAW=""
    return 1
  fi
  return 0
}

# _ep_write_atomic <target> <content> — mktemp → mv -f 로 원자 교체합니다.
# 임시 파일 이름을 dot 으로 시작시켜 ep_cap 의 `/bin/ls -1` 카운트에 섞이지 않게 합니다.
_ep_write_atomic() {
  local target="${1-}" content="${2-}" dir tmp
  [[ -n "$target" ]] || return 1
  dir="${target%/*}"
  [[ "$dir" == "$target" ]] && dir="."
  tmp="$(mktemp "${dir}/.epw.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# --- 경로·식별자 -----------------------------------------------------------

# ep_root — provenance 루트 경로를 출력합니다.
# RD_EDIT_PROVENANCE_DIR 이 우선입니다 (테스트 격리용).
ep_root() {
  if [[ -n "${RD_EDIT_PROVENANCE_DIR:-}" ]]; then
    printf '%s\n' "$RD_EDIT_PROVENANCE_DIR"
  else
    printf '%s\n' "${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/edit-provenance.d"
  fi
}

# ep_state_id <file> — 파일 내용의 상태 식별자 '<checksum>-<length>' 를 출력합니다.
# cksum 을 쓰는 이유(§2.2): mtime 은 초 해상도라 같은 초 덮어쓰기를 구별하지 못하고
# 도구가 보존할 수도 있습니다. shasum -a 256(10.5ms)은 상한의 절반을 소모하는데
# 얻는 것이 이 용도(변경 감지)에 불필요합니다. cksum 은 1.9ms 실측입니다.
# 파일명 필드가 섞이지 않도록 stdin 리다이렉트로 읽습니다.
ep_state_id() {
  local f="${1-}" out
  [[ -n "$f" && -f "$f" ]] || return 1
  out="$(cksum < "$f" 2>/dev/null)" || return 1
  _ep_fmt_cksum "$out"
}

# ep_state_id_stdin — stdin 내용으로 같은 형식의 상태 식별자를 산출합니다 (T23 Write 검증용).
ep_state_id_stdin() {
  local out
  out="$(cksum 2>/dev/null)" || return 1
  _ep_fmt_cksum "$out"
}

# ep_pathkey <relpath> — 상대 경로 **문자열**의 cksum 을 '<checksum>-<length>' 로 출력합니다.
# printf '%s' 로 종단 개행 없이 넣습니다 — echo 를 쓰면 개행이 섞여 producer 와 consumer 가
# 서로 다른 키를 만듭니다. 결과는 숫자와 '-' 뿐이라 dot 센티널과 이름이 겹치지 않습니다.
ep_pathkey() {
  local rel="${1-}" out
  out="$(printf '%s' "$rel" | cksum 2>/dev/null)" || return 1
  _ep_fmt_cksum "$out"
}

# --- 세대 선택 -------------------------------------------------------------

# ep_current_gen — 현재 세대 디렉토리 경로를 출력합니다.
# **.current 포인터가 유일한 권위입니다** (§2.4.2) — 최대 번호를 고르지 않습니다.
# 값 비교(최대 번호·기준선 값)로 현재 세대를 추론하면 ① 정리 부분 실패로 낮은 세대가
# 잔존할 때 그것이 재선택되고 ② 동일 내용·동일 초 연속 저장에서 두 세대가 구별되지
# 않습니다. 두 반례 모두 포인터로 닫힙니다.
# 포인터 부재 / 내용이 'gen-<정수>' 형식 아님 / 지정 디렉토리 부재 → 빈 출력 + return 1.
# 내용은 파일 전체를 봅니다 — 허용 형식은 producer 가 쓰는 'gen-<N>' + **종단 LF 1개**
# (`_ep_write_atomic`) 하나뿐이고, 종단 LF 가 없는 형태도 같은 이유로 받습니다.
# 'gen-1\n<추가 줄>' 도 'gen-1\n\n' 도 형식 불일치로 거부됩니다.
#
# **_ep_read_whole 을 쓰지 않는 이유** (턴 006 P1): 그 함수는 LF 를 하나만 제거하지만
# `$(...)` 로 값을 받는 순간 command substitution 이 **남은 종단 LF 를 전부** 지웁니다.
# 그래서 'gen-1\n\n' 이 'gen-1' 로 도착해 손상 포인터가 유효 세대를 지시했고,
# "포인터 손상은 기존 mtime 판정으로 수렴" 계약이 그 경계에서 깨졌습니다.
ep_current_gen() {
  local root ptr name num
  root="$(ep_root)"
  ptr="${root}/.current"
  _ep_read_exact "$ptr" || return 1
  name="${_EP_RAW%$'\n'}"
  # 종단 LF 를 하나 떼고도 개행이 남아 있으면 추가 줄이나 추가 LF 입니다.
  case "$name" in *$'\n'*) return 1 ;; esac
  num="${name#gen-}"
  [[ -n "$num" && "$name" == "gen-${num}" ]] || return 1
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  [[ -d "${root}/${name}" ]] || return 1
  printf '%s' "${root}/${name}"
}

# ep_next_gen_name — 존재하는 gen-<N> 중 최대 N 을 구해 'gen-<N+1>' 이름을 출력합니다
# (하나도 없으면 gen-1). **새 이름 생성 전용이며 판정에 쓰지 않습니다.**
# 선행 0 이 8진수로 해석되지 않도록 10# 접두로 강제 10진 해석합니다.
ep_next_gen_name() {
  local root d base num max=0
  root="$(ep_root)"
  for d in "${root}"/gen-*; do
    [[ -d "$d" ]] || continue
    base="${d##*/}"
    num="${base#gen-}"
    [[ -n "$num" && "$base" == "gen-${num}" ]] || continue
    case "$num" in *[!0-9]*) continue ;; esac
    if [[ $((10#$num)) -gt $max ]]; then max=$((10#$num)); fi
  done
  printf 'gen-%s' "$((max + 1))"
}

# ep_set_current <gendir> — .current 에 디렉토리 **basename** 을 원자 교체합니다.
ep_set_current() {
  local gen="${1-}" root
  [[ -n "$gen" ]] || return 1
  root="$(ep_root)"
  [[ -d "$root" ]] || return 1
  _ep_write_atomic "${root}/.current" "${gen##*/}"
}

# --- 세대 유효성 -----------------------------------------------------------

# ep_gen_valid <gendir> <short-title> — 세대 유효성 (§2.4).
# .short-title 이 존재하고 **파일 전체가** 인자와 일치 + .overflow 부재일 때만 return 0.
# 하나라도 어긋나면 그 세대의 레코드는 판정에서 전부 미설명으로 취급됩니다.
#
# **첫 줄만 비교하지 않는 이유** (final diff review 턴 008 P1): 종전 주석은 "task-state 가
# 개행을 금지하므로(LC-06) 다중행은 정상 경로로 만들어지지 않고, 불일치는 block 방향" 이라고
# 근거를 댔지만, 첫 줄만 읽으면 `demo\n\n`·`demo\n추가 줄`·`demo\0` 이 전부 **일치**로 판정돼
# block 이 아니라 **통과** 방향이 됐습니다(실측). 손상 메타를 가진 세대가 유효로 인정되면
# 그 안의 `.sub` 가 편집을 설명해 넛지가 사라집니다 — 다른 손상 처리와 방향이 반대입니다.
# 허용 형식은 다른 메타와 같습니다 — 값 + 종단 LF 0/1개, 개행 잔여·NUL 은 거부.
ep_gen_valid() {
  local gen="${1-}" want="${2-}" got
  [[ -n "$gen" && -d "$gen" ]] || return 1
  [[ -e "${gen}/.overflow" ]] && return 1
  _ep_read_exact "${gen}/.short-title" || return 1
  got="${_EP_RAW%$'\n'}"
  case "$got" in *$'\n'*) return 1 ;; esac
  [[ "$got" == "$want" ]] || return 1
  return 0
}

# ep_gen_has_sentinel <gendir> — .overflow 가 존재하면 return 0 (보수적 후보화 판정용).
# .invalid 센티널은 폐기했습니다 (§2.4.3) — 실패한 bump 가 종료 시점의 포인터 대상을
# 무효화하면 그 대상이 동시에 성공한 다른 bump 의 정상 세대일 수 있어 그 저장을
# 무효로 만듭니다. 남은 센티널은 .overflow 하나입니다.
ep_gen_has_sentinel() {
  local gen="${1-}"
  [[ -n "$gen" ]] || return 1
  [[ -e "${gen}/.overflow" ]]
}

# --- 기준선 갱신 (bump) ----------------------------------------------------

# ep_bump <short-title> — 새 세대를 열고 포인터를 옮깁니다 (§2.4·§2.4.1).
# 순서: mkdir(최대 5회 재시도) → ① .short-title 기록 → ② 새 세대 존재 재확인 → ③ 포인터 교체.
# **정리하지 않습니다** (§2.4.1) — bump 직후 정리는 동시 bump 와 교차하면 방금 만들어진
# 다른 세대를 지워 dangling 포인터를 만듭니다.
# 어느 지점에서 실패해도 **권위 상태(.current 포인터 · 기존 세대의 내용·유효성)를 바꾸지 않고**
# ep_mark_bump_failed <stage> 를 남긴 뒤 non-zero 를 반환합니다. 센티널은 남기지 않습니다.
# "권위 상태 무변경" 은 파일시스템 무변경이 **아닙니다** — mkdir 이후 실패는 고아 디렉토리를
# 남깁니다. 고아는 포인터가 가리키지 않아 판정에 진입하지 않고 lifecycle 회수에서 삭제됩니다.
# **호출측(producer·CLI)은 이 반환값으로 자신을 실패시키지 않습니다** (§2.4 반환 계약).
ep_bump() {
  local title="${1-}" root name gen="" tries=0
  root="$(ep_root)"
  if [[ ! -d "$root" ]]; then
    if ! mkdir -p "$root" 2>/dev/null; then
      ep_mark_bump_failed mkdir
      return 1
    fi
  fi
  # 이름 충돌(동시 bump)은 mkdir 이 직렬화합니다 — 실패 시 최대 번호를 재계산해 재시도합니다.
  while [[ $tries -lt 5 ]]; do
    tries=$((tries + 1))
    name="$(ep_next_gen_name)"
    if mkdir "${root}/${name}" 2>/dev/null; then
      gen="${root}/${name}"
      break
    fi
  done
  if [[ -z "$gen" ]]; then
    ep_mark_bump_failed mkdir
    return 1
  fi
  # ① .short-title
  if ! _ep_write_atomic "${gen}/.short-title" "$title"; then
    ep_mark_bump_failed short-title
    return 1
  fi
  # ② 존재 재확인 — 자기 디렉토리가 외부 요인으로 사라졌으면 포인터를 옮기지 않습니다
  #    (옮기면 dangling 포인터가 되어 판정이 세대 없음으로 떨어집니다).
  if [[ ! -d "$gen" ]]; then
    ep_mark_bump_failed recheck
    return 1
  fi
  # ③ 포인터 교체
  if ! ep_set_current "$gen"; then
    ep_mark_bump_failed pointer-swap
    return 1
  fi
  ep_clear_bump_failed
  return 0
}

# --- 레코드 ---------------------------------------------------------------

# ep_record <gendir> <actor> <relpath> <state_id> — '<state_id>\t<relpath>' 를 원자 기록합니다.
# 같은 (세대, 경로, 행위자) 재편집은 덮어쓰기입니다. actor 는 orc | sub.
ep_record() {
  local gen="${1-}" actor="${2-}" rel="${3-}" sid="${4-}" pk
  [[ -n "$gen" && -n "$actor" && -n "$rel" && -n "$sid" ]] || return 1
  [[ -d "$gen" ]] || return 1
  pk="$(ep_pathkey "$rel")" || return 1
  [[ -n "$pk" ]] || return 1
  _ep_write_atomic "${gen}/${pk}.${actor}" "${sid}"$'\t'"${rel}"
}

# _ep_read_record_file <파일> — 레코드 **파일 전체**가 유효한 단일 레코드인지 검증합니다.
# 유효하면 `_EP_REC_SID` / `_EP_REC_RP` 에 두 필드를 담고 return 0, 아니면 return 1.
#
# 유효한 형식은 producer 가 쓰는 것 하나뿐입니다 — `<state_id>\t<relpath>` + **종단 LF 1개**
# (`_ep_write_atomic` 의 `printf '%s\n'`). 종단 LF 가 없는 형태도 받습니다: 읽기 쪽에서
# 구분할 이유가 없고, 마지막 LF 유실은 내용 손상이 아니기 때문입니다.
#
# **파일 전체를 보는 이유** (final diff review 턴 004 P1): 종전 구현은 `read` 한 번으로 첫
# 물리 줄만 읽어, `<정상 state_id>\t<정상 relpath>\n<아무 줄>` 같은 손상 레코드를 **유효한
# 설명으로 통과**시켰습니다. 그러면 Stop hook 이 그 편집을 subagent 소행으로 간주해
# **block JSON 을 내지 않고 저장 넛지가 사라집니다** — change spec §2.5 6단계("`.sub` 가
# malformed 면 미설명")·AC5(e)("기록 malformed → block 방향") 를 정면으로 위반하며,
# 손상이 안전한 쪽이 아니라 **위험한 쪽으로** 수렴하는 유일한 경로였습니다.
#
# **`read` 로 필드를 나누지 않는 이유** (턴 006 P1): `IFS=$'\t' read -r sid rp extra` 는
# 손상을 정상으로 **축약**합니다. TAB 은 IFS whitespace 라 `sid\trp\t` 도 `sid\trp\t\t` 도
# extra 가 빈 문자열이 되어 "2필드" 로 통과했고, `read` 가 NUL 을 버리는 성질 때문에
# `sid\trp\0` 까지 같은 값으로 통과했습니다. 셋 다 producer 가 만들 수 없는 바이트인데
# state_id·relpath 가 맞으면 유효한 설명으로 채택되어 넛지가 사라졌습니다.
# 그래서 **파일 전체를 먼저 손실 없이 보존하고**(`_ep_read_exact`) 문자열 조작으로 검사합니다.
# fork 는 늘지 않습니다 — `wc`·`stat` 대신 `${var%...}` 와 `case` 만 씁니다.
_ep_read_record_file() {
  local body rest
  _EP_REC_SID=""
  _EP_REC_RP=""
  # NUL 포함은 여기서 걸립니다 (셸 변수가 NUL 을 담지 못해 "읽고 확인" 이 불가능합니다).
  _ep_read_exact "${1-}" || return 1
  body="${_EP_RAW%$'\n'}"
  # 종단 LF 를 하나 떼고도 개행이 남으면 추가 물리 줄이거나 추가 LF 입니다.
  case "$body" in *$'\n'*) return 1 ;; esac
  # TAB 이 정확히 하나여야 합니다 — 없으면 필드 부족, 둘 이상이면 빈 필드를 포함해 초과입니다.
  case "$body" in *$'\t'*) ;; *) return 1 ;; esac
  _EP_REC_SID="${body%%$'\t'*}"
  rest="${body#*$'\t'}"
  case "$rest" in *$'\t'*) return 1 ;; esac
  [[ -n "$_EP_REC_SID" && -n "$rest" ]] || return 1
  _EP_REC_RP="$rest"
  return 0
}

# ep_read_record <gendir> <actor> <relpath> — 레코드의 state_id 를 출력합니다.
# 파일 부재 / 단일 레코드 형식 위반 / relpath 불일치 → return 1.
# 형식 검증은 `_ep_read_record_file` 이 전담합니다 — self_test 의 D4 진단도 **같은 함수**를
# 쓰므로, 판정과 사용자 가시성이 서로 다른 규칙으로 갈리지 않습니다 (턴 004 질문 1).
# pathkey 는 CRC 라 이론상 충돌하므로(404개 기준 약 2e-5) 레코드에 relpath 를 저장해
# 읽을 때 검증하고, 불일치는 미설명(block 방향)입니다.
ep_read_record() {
  local gen="${1-}" actor="${2-}" rel="${3-}" pk file
  [[ -n "$gen" && -n "$actor" && -n "$rel" ]] || return 1
  pk="$(ep_pathkey "$rel")" || return 1
  file="${gen}/${pk}.${actor}"
  _ep_read_record_file "$file" || return 1
  [[ "$_EP_REC_RP" == "$rel" ]] || return 1
  printf '%s' "$_EP_REC_SID"
}

# ep_record_file_exists <gendir> <relpath> — <pathkey>.orc 또는 <pathkey>.sub 의 **원시 존재**.
# **내용 유효성을 보지 않습니다.** 유효한 레코드만 후보 조건으로 삼으면
# mtime == baseline 상태에서 malformed·pathkey 충돌 레코드가 후보에서 빠져 통과해,
# "손상은 block 방향" 이라는 전제가 깨집니다 (§2.5 4단계 근거).
ep_record_file_exists() {
  local gen="${1-}" rel="${2-}" pk
  [[ -n "$gen" && -n "$rel" ]] || return 1
  pk="$(ep_pathkey "$rel")" || return 1
  [[ -e "${gen}/${pk}.orc" || -e "${gen}/${pk}.sub" ]]
}

# ep_orc_exists <gendir> <relpath> — <pathkey>.orc 원시 존재 (내용 불문 미설명 판정용).
# malformed .orc 와 유효한 .sub 가 공존할 때 .orc 를 무시하면 설명됨으로 통과합니다.
# orchestrator 편집의 흔적이 있으면 그 자체로 저장이 필요하므로 보수적으로 봅니다.
ep_orc_exists() {
  local gen="${1-}" rel="${2-}" pk
  [[ -n "$gen" && -n "$rel" ]] || return 1
  pk="$(ep_pathkey "$rel")" || return 1
  [[ -e "${gen}/${pk}.orc" ]]
}

# ep_cap <gendir> — 상한 처리 (§2.8). **레코드를 삭제하지 않습니다.**
# 레코드 파일 수가 1000 을 초과하면 .overflow 를 만들고 return 1(기록 중단 신호)입니다.
# 오래된 레코드를 지우는 방식은 안전하지 않습니다 — .orc 만 지워지고 .sub 가 남으면
# 설명됨으로 통과하고, 둘 다 사라지면 mtime == baseline 에서 후보 자체가 없어집니다.
# 카운트는 `/bin/ls -1 | wc -l`(1000개에서 5.9ms 실측)이며 ls 가 dotfile 을 제외하므로
# 센티널·임시 파일이 카운트에 섞이지 않습니다.
# 카운트 자체가 실패하면 위생 조치를 포기하고 기록을 계속합니다(return 0) — 상한은
# 정확성 장치가 아니라 누적 방지 장치이므로 카운트 실패로 기록을 막지 않습니다.
ep_cap() {
  local gen="${1-}" n
  [[ -n "$gen" && -d "$gen" ]] || return 1
  n="$(/bin/ls -1 "$gen" 2>/dev/null | wc -l 2>/dev/null)" || return 0
  n="${n//[[:space:]]/}"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [[ "$n" -gt 1000 ]] || return 0
  : > "${gen}/.overflow" 2>/dev/null || true
  return 1
}

# --- 가시성 흔적 (§2.12) ---------------------------------------------------

# ep_mark_bump_failed <stage> — 루트에 .bump-failed(내용 '<stage>' 한 줄)를 best-effort 로 남깁니다.
# stage 는 고정 4토큰: mkdir | short-title | recheck | pointer-swap.
# **판정 비참여** — current_task_is_stale() 은 이 파일을 읽지 않습니다. 세대 디렉토리 **밖**에
# 있어 어떤 세대도 무효화할 수 없으므로 "실패한 bump 가 남의 성공 세대를 오염" 이 구조적으로
# 불가능합니다. 쓰기 실패는 무시합니다 (가시성 상실뿐, 판정 무영향).
# 원자 교체(mktemp→mv)를 쓰지 않는 이유: 이 흔적은 mv 실패 지점(pointer-swap)에서도
# 남아야 하므로 mv 에 의존하면 정작 필요한 순간에 기록되지 않습니다.
ep_mark_bump_failed() {
  local stage="${1-}" root
  root="$(ep_root)"
  [[ -d "$root" ]] || return 0
  printf '%s\n' "$stage" > "${root}/.bump-failed" 2>/dev/null || true
  return 0
}

# ep_clear_bump_failed — .bump-failed 를 best-effort 로 삭제합니다 (bump 성공 시).
# 삭제 실패는 무시합니다 — 이미 복구된 상태를 D7 이 경고하는 오진으로 나타나지만
# 다음 저장에서 다시 삭제를 시도하고 판정에는 영향이 없습니다.
ep_clear_bump_failed() {
  local root
  root="$(ep_root)"
  rm -f "${root}/.bump-failed" 2>/dev/null || true
  return 0
}

# --- lifecycle 회수 (§2.9) -------------------------------------------------

# ep_purge_root [삭제 대상] — 대상 디렉토리 전체를 삭제합니다. 성공 0 / 실패 non-zero.
# **런타임이 아니라 archive.sh 의 lifecycle 종료에서만 호출합니다.** 그 시점에는 병렬
# subagent 도 hook 도 돌지 않으므로 동시성이 없고 세대별 판단이 필요 없습니다.
# 삭제를 이 함수로 분리한 이유(테스트 seam): archive.sh 는 별도 프로세스라 셸 함수
# override 가 전파되지 않으므로, 실패 경로 검증을 함수 단위로 옮겨야 권한 조작 없이
# 결정적으로 재현됩니다.
#
# **인자가 있으면 그 경로를, 없으면 종전대로 ep_root() 를 삭제합니다** (final diff review
# 턴 002 P1). 인자를 받는 이유: ep_root() 는 테스트 격리용 RD_EDIT_PROVENANCE_DIR 을 무조건
# 우선하므로, 그 변수가 환경에 남은 채 archive 를 실행하면 **정상 성공 경로의 마지막 단계에서
# 프로젝트 밖 임의 경로가 통째로 재귀 삭제**됩니다. 테스트 격리 seam 이 운영의 파괴적 대상
# 선택으로 이어지지 않도록, 운영 호출자(archive.sh)가 대상을 명시적으로 넘깁니다.
# 인자 없는 형태는 함수 단위 실패 주입 테스트를 위해 그대로 남겨 둡니다.
ep_purge_root() {
  local root="${1-}"
  [[ -n "$root" ]] || root="$(ep_root)"
  [[ -n "$root" ]] || return 1
  # 최소 방어 — 파일시스템 루트와 홈 디렉토리 자체는 어느 경로로 지목되든 삭제하지 않습니다.
  # 이름 형태(basename 이 edit-provenance.d 인지)까지 검사하지는 않습니다: 함수 단위 테스트가
  # 임의 fixture 경로를 대상으로 실패를 주입하므로 그 seam 을 막아 버립니다.
  case "$root" in /|//) return 1 ;; esac
  [[ "$root" == "${HOME:-}" ]] && return 1
  [[ -e "$root" ]] || return 0
  rm -rf "$root" 2>/dev/null || return 1
  [[ -e "$root" ]] && return 1
  return 0
}
