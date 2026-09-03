#!/usr/bin/env bash
# Lifecycle 공통 함수 — git 상태 / remote 검출 / metadata I/O / branch ref helpers
# v2 Phase 2b: metadata_* 함수는 task-state(_state_common.sh)를 대상으로 동작.
# LIFECYCLE_METADATA_PATH 변수 폐지 — TASK_STATE_PATH 경유 (env override는 TASK_STATE_PATH 사용).

# _state_common.sh 로드 — task-state 단일 상태 파일 I/O 제공
source "$(dirname "${BASH_SOURCE[0]}")/../_state_common.sh"

# detect_remote_mode: stdout = "remote" | "local-only"
detect_remote_mode() {
  if [[ -n "${RD_LIFECYCLE_NO_REMOTE:-}" ]]; then printf 'local-only\n'; return 0; fi
  if git remote get-url origin >/dev/null 2>&1; then printf 'remote\n'; else printf 'local-only\n'; fi
}

# ensure_worktree_clean: exit 0 if clean, 1 if dirty
ensure_worktree_clean() {
  if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then return 0; fi
  return 1
}

# resolve_unique_ref <kind=branch|tag> <base>: 충돌 시 -N suffix 적용한 ref 반환
resolve_unique_ref() {
  local kind="$1" base="$2"
  local ref_prefix
  case "$kind" in
    branch) ref_prefix="refs/heads/" ;;
    tag) ref_prefix="refs/tags/" ;;
    *) printf 'resolve_unique_ref: unknown kind: %s\n' "$kind" >&2; return 1 ;;
  esac
  local candidate="$base"
  local n=2
  # cap at base-100 to prevent runaway loops (Nit N2)
  while git rev-parse --verify "${ref_prefix}${candidate}" >/dev/null 2>&1; do
    [[ $n -gt 100 ]] && { printf 'resolve_unique_ref: too many collisions for %s\n' "$base" >&2; return 1; }
    candidate="${base}-${n}"
    n=$((n+1))
  done
  printf '%s\n' "$candidate"
}

# 전제: 원격 추적은 origin remote 기준 (refs/remotes/origin/HEAD 조회·origin/ strip).
# origin 외 remote(upstream 등)만 있는 구성은 미지원 — workflow.json "default_branch" 설정으로 우회.
# 기본 브랜치 결정 — config(default_branch) → origin/HEAD → main/master 유일 매치 → 에러
# 빈 config 값("")은 미설정으로 간주하고 다음 체인으로 진행한다.
# stdout: 브랜치명 1줄. 실패/모호 시 stderr 안내 + return 1.
get_default_branch() {
  local cfg="${project_root:-$PWD}/rd-workflow/config/workflow.json"
  local b=""
  if [[ -f "$cfg" ]]; then
    b="$(sed -n 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
  fi
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  b="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  b="${b#origin/}"
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  local has_main=0 has_master=0
  if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then has_main=1; fi
  if git show-ref --verify --quiet refs/heads/master 2>/dev/null; then has_master=1; fi
  if (( has_main + has_master == 1 )); then
    if (( has_main )); then printf 'main\n'; else printf 'master\n'; fi
    return 0
  fi
  printf 'get_default_branch: 기본 브랜치를 결정할 수 없습니다 — rd-workflow/config/workflow.json 에 "default_branch" 를 설정하세요\n' >&2
  return 1
}

# main(기본 브랜치) worktree path 검출 — whitespace-safe full-line extraction
get_main_worktree_path() {
  local b p
  b="$(get_default_branch)" || return 1
  p="$(git worktree list --porcelain | awk -v ref="branch refs/heads/$b" '
    /^worktree /{p=$0; sub(/^worktree /,"",p); next}
    $0==ref{print p; exit}
  ')"
  if [[ -z "$p" ]]; then
    printf 'get_main_worktree_path: no worktree on refs/heads/%s\n' "$b" >&2
    return 1
  fi
  printf '%s\n' "$p"
}

# Lifecycle metadata I/O — task-state 대상 (v2 Phase 2b, 시그니처 불변)

# metadata_read_field <key>: task-state에서 값 읽기 (파일/키 부재 시 빈 출력)
# task-state 부재 시에만 legacy active-fr 파일에서 같은 키를 읽는 read-only fallback 적용.
# task-state 존재 시 절대 legacy를 읽지 않음 (guard hook fallback 원칙).
metadata_read_field() {
  local key="$1"
  if state_file_exists; then
    state_read_field "$key"
  else
    local _legacy_afr="${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/active-fr"
    if [[ -f "$_legacy_afr" ]]; then
      awk -F'=' -v k="$key" '$1==k{sub(/^[^=]+=/,""); print; exit}' "$_legacy_afr"
    fi
  fi
}

# metadata_write <fr-branch> <short-title> <worktree-path> [source-fr]: task-state에 4필드 + created-at 기록
# 4번째 인자는 optional (기본 '-') — 기존 3인자 호출과 호환 (trailing optional 확장만 허용)
metadata_write() {
  local fr_branch="$1" short_title="$2" worktree_path="$3" source_fr="${4:--}"
  if [[ "$fr_branch" == *$'\n'* || "$short_title" == *$'\n'* || "$worktree_path" == *$'\n'* || "$source_fr" == *$'\n'* ]]; then
    printf 'metadata_write: values must not contain newlines\n' >&2; return 1
  fi
  state_write_fields \
    "fr-branch=$fr_branch" \
    "short-title=$short_title" \
    "worktree-path=${worktree_path:-null}" \
    "source-fr=${source_fr:--}" \
    "created-at=$(date +%Y-%m-%d-%H%M)"
}

# lifecycle_metadata_paths — archive 가 소유하는 경로 목록 (repo-relative, 개행 구분).
#
# **단일 출처입니다.** archive.sh Step 4 의 커밋 경로와 얹힌 커밋 검사의 허용 집합이
# 모두 여기서 나옵니다. 두 벌로 두면 Step 4 가 경로를 늘렸을 때 검사가 그것을 침입으로
# 오판하고, 그 어긋남이 조용히 발생합니다 (test_lifecycle.sh 가 배선을 고정합니다).
lifecycle_metadata_paths() {
  cat <<'PATHS'
rd-workflow-workspace/.lifecycle/task-state
CURRENT_TASK.md
rd-workflow-workspace/.lifecycle/active-fr
PATHS
}

# lifecycle_owned_state_keys — archive 가 task-state 에서 바꾸는 키 (공백 구분 한 줄).
#
# **단일 출처입니다.** metadata_clear 는 fr-branch·worktree-path·source-fr 를 재설정하고
# created-at 을 제거하며, archive.sh Step 4 는 short-title·status 를 씁니다. 이 여섯이
# 전부입니다 (REQUEST review Turn 006 확인).
#
# 발행 직전 내용 검증이 "기준선 대비 이 키들 밖에서 불변인가" 를 판정하므로, 실제 쓰기
# 범위를 늘리면서 이 목록을 갱신하지 않으면 **정상 아카이브가 차단됩니다.**
lifecycle_owned_state_keys() {
  printf '%s\n' 'fr-branch worktree-path source-fr short-title status created-at'
}

# archive_baseline_commit <repo_root> <fr_ref> <head_oid>
#   얹힌 커밋 검사의 기준선 OID 를 stdout 에 낸다.
#   rc 0 = 성공, 1 = 차단(기준선 판정 불가), 2 = git 실행 오류
#
# 규칙 (change spec D2):
#   HEAD 의 first-parent 체인에서 **부모가 정확히 2개이고 두 번째 부모가 fr tip 인**
#   가장 가까운 커밋이 기준선이다.
#
#   **부모가 3개 이상인 merge(octopus)는 인정하지 않는다.** 기준선은 baseline..head
#   검사에서 제외되므로, octopus 를 기준선으로 삼으면 그 merge 가 fr tip 과 **함께**
#   들여온 다른 부모의 내용이 "기준선 이전" 으로 취급되어 L1·L2 양쪽의 검사 밖에
#   놓인다. 실측: 얹힌 커밋 0건이고 리뷰되지 않은 side.txt 가 발행 트리에 존재했다.
#   이 변경이 막으려는 것의 직접 우회이므로, 놓쳐서 차단하는 쪽을 택한다.
#   archive.sh 가 만드는 merge 는 항상 `git merge --no-ff "$FR_BRANCH"` 로 2-parent
#   이므로 이 제한은 정상 경로를 좁히지 않는다.
#
#   못 찾으면 fr tip 이 first-parent 체인에 **실제로 존재하는지 확인한 뒤에만**
#   fr tip 을 기준선으로 삼는다(fast-forward 로 합쳐진 경우). "merge 를 못 찾음"
#   을 무조건 fast-forward 로 해석하면 비표준·손상 그래프가 같은 분기로 들어온다.
#
#   fr tip 기준선을 무조건 쓰면 안 되는 이유: fr 분기 이후 기본 브랜치가 전진한
#   커밋이 first-parent 체인에 남아 오탐된다(실측).
archive_baseline_commit() {
  local root="$1" fr_ref="$2" head_oid="$3"
  local fr_tip rev_out line sha parents p chain c n p1 p2

  fr_tip="$(git -C "$root" rev-parse --verify --quiet "${fr_ref}^{commit}" 2>/dev/null)" || return 2
  [[ -n "$fr_tip" ]] || return 2

  rev_out="$(git -C "$root" rev-list --first-parent --parents "$head_oid" 2>/dev/null)" || return 2
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sha="${line%% *}"
    parents="${line#* }"
    # 부모가 없는 root commit 은 "sha" 한 필드뿐이라 위 치환이 원문을 그대로 남긴다
    [[ "$parents" == "$line" ]] && continue
    # 부모 개수를 센다 — 정확히 2개일 때만 후보다
    n=0; p1=""; p2=""
    for p in $parents; do
      n=$((n+1))
      [[ "$n" -eq 1 ]] && p1="$p"
      [[ "$n" -eq 2 ]] && p2="$p"
    done
    if [[ "$n" -eq 2 && "$p2" == "$fr_tip" ]]; then
      printf '%s\n' "$sha"
      return 0
    fi
  done <<EOF
$rev_out
EOF

  # fallback — fr tip 이 first-parent 체인에 실재할 때만
  chain="$(git -C "$root" rev-list --first-parent "$head_oid" 2>/dev/null)" || return 2
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    if [[ "$c" == "$fr_tip" ]]; then
      printf '%s\n' "$fr_tip"
      return 0
    fi
  done <<EOF
$chain
EOF

  return 1
}

# archive_extra_commits_check <repo_root> <baseline_oid> <head_oid>
#   기준선 이후 얹힌 커밋이 허용 경로 안의 변경만 담고 있는지 본다.
#   rc 0 = 통과, 1 = 차단, 2 = git 실행 오류
#
# **이 판정은 근사다** (change spec D1). 커밋의 출처를 구분하지 못하므로 단독으로는
# "리뷰되지 않은 내용이 없다" 를 증명하지 못한다. 최종 판단은 archive_publish_content_check
# 가 내린다. 이 함수를 두는 이유는 오직 **빠른 실패** — 약 6분짜리 검증을 기다린 뒤에야
# 차단되면 사용자 비용이 크다.
#
# 경로 산출에 `git show --name-only` 를 쓰지 않는다. merge 커밋에서 빈 결과를 내고,
# 빈 집합은 모든 집합의 부분집합이라 **사람이 만든 merge 가 통과한다**(실측).
# 첫 부모와 명시 비교(`<sha>^1 <sha>`)해야 그 merge 가 들여온 변경이 드러난다.
#
# NUL 구분 출력을 명령 치환으로 받지 않는다 — bash 가 NUL 을 제거해 경로가 이어붙는다.
# 프로세스 치환도 쓰지 않는다 — git 종료 코드를 잃어 "명령 실행 오류" 를 판정할 수 없다.
archive_extra_commits_check() {
  local root="$1" baseline="$2" head_oid="$3"
  local allowed_set="" rel commits sha subj tmp p n blocked=0 hit

  # 목록을 **먼저 캡처하고 helper 의 rc 를 따로 본다.** heredoc 안 명령 치환
  # (`<<EOF` + `$(lifecycle_metadata_paths)`) 은 그 함수의 종료 코드를 소거하므로,
  # "한 줄 출력 후 실패" 가 정상 목록으로 취급된다 — 축소된 허용 집합으로 판정이
  # 계속되면 fail-closed 계약이 깨진다 (final diff review Turn 002 F3).
  # 여기서는 판정 자체가 불가능한 상태이므로 rc 2 로 낸다 (호출부의 "판정 불능" 안내).
  local paths_out paths_rc
  paths_out="$(lifecycle_metadata_paths)" && paths_rc=0 || paths_rc=$?
  if [[ "$paths_rc" -ne 0 ]]; then
    printf 'archive:   허용 경로 목록 생성이 실패했습니다 (lifecycle_metadata_paths rc %s)\n' "$paths_rc" >&2
    return 2
  fi

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    allowed_set="${allowed_set}|${rel}"
  done <<EOF
$paths_out
EOF
  allowed_set="${allowed_set}|"

  commits="$(git -C "$root" rev-list --first-parent "${baseline}..${head_oid}" 2>/dev/null)" || return 2

  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    subj="$(git -C "$root" log -1 --pretty=%s "$sha" 2>/dev/null)" || return 2

    if ! git -C "$root" rev-parse --verify --quiet "${sha}^1" >/dev/null 2>&1; then
      printf 'archive:   %s %s — 부모가 없는 커밋\n' "${sha:0:8}" "$subj" >&2
      blocked=1
      continue
    fi

    tmp="$(mktemp)" || return 2
    if ! git -C "$root" diff-tree --no-commit-id -r -z --name-only "${sha}^1" "$sha" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 2
    fi

    n=0; hit=""
    while IFS= read -r -d '' p; do
      n=$((n+1))
      case "$allowed_set" in
        *"|${p}|"*) ;;
        *) hit="${hit}${hit:+, }${p}" ;;
      esac
    done < "$tmp"
    rm -f "$tmp"

    if [[ "$n" -eq 0 ]]; then
      printf 'archive:   %s %s — 변경 경로가 없는 커밋\n' "${sha:0:8}" "$subj" >&2
      blocked=1
    elif [[ -n "$hit" ]]; then
      printf 'archive:   %s %s\n' "${sha:0:8}" "$subj" >&2
      printf 'archive:     허용 경로 밖 변경: %s\n' "$hit" >&2
      blocked=1
    fi
  done <<EOF
$commits
EOF

  [[ "$blocked" -eq 0 ]] || return 1
  return 0
}

# _archive_regular_text <file> — rc 0 = 정규 텍스트, 1 = 그 밖
#   정규 텍스트 = ① 비어 있지 않음 ② NUL 을 포함하지 않음 ③ 마지막 바이트가 LF
#
# **행 단위 필터에 넣기 전에 반드시 통과해야 한다.** `while IFS= read -r line` 은 마지막
# 행에 LF 가 없으면 그 행을 **버린다**(read 가 내용을 채우고도 EOF 로 nonzero 를 내
# loop body 가 실행되지 않는다). 그래서 소유 키 밖 행을 **마지막 LF 없이** 붙이면 필터
# 결과가 기준선과 같아지고 L2 가 rc 0 으로 통과한다 — 실증했다 (Turn 006 F1).
#
# ```
# 기준선:   schema=1 / extensions.foo.bar=리뷰된 값 (LF 종단)
# 발행후보: 같은 내용 + "evil.key=주입" (LF 없음)
# → 두 필터 결과가 cmp 일치 = FAIL-OPEN
# ```
#
# `read … || [[ -n "$line" ]]` 로 행을 잡는 방향은 택하지 않았다. 행은 살리지만
# `printf '%s\n'` 이 종단 상태를 정규화해, "LF 없음" 과 "LF 있음" 이 같은 결과로
# 뭉개진다 — 검사가 byte 단위라는 계약이 다시 흐려진다.
#
# `task-state` 는 `state_write_fields` 가 항상 LF 종단으로 쓴다. 그렇지 않은 blob 은
# 정규 형식이 아니므로 **판정 결과로서 차단**한다(rc 1). 이는 git 실행 오류(rc 2)와
# 다른 갈래다.
_archive_regular_text() {
  local f="$1" sz nul_sz last
  sz="$(wc -c < "$f" 2>/dev/null)" || return 1
  sz="${sz//[^0-9]/}"
  # ① 비어 있지 않음 — 빈 파일은 조건 ③(마지막 바이트 = LF)에도 걸린다
  # (tail -c 1 이 빈 출력을 내 last="" != "10"). 이 검사는 그 사실을 조기에
  # 드러내는 의도 문서화이며 독립된 하중은 없다.
  [ "${sz:-0}" -gt 0 ] || return 1

  # ② NUL 이 있으면 정규 텍스트가 아니다.
  #
  # bash 의 `read` 는 NUL 을 조용히 삼켜 그 행을 잃게 만들고, 명령 치환도 NUL 을
  # 보존하지 못한다. 그래서 NUL 을 허용하면 "마지막 바이트 검사" 를 어떻게 고쳐도
  # 중간 NUL 로 행을 가리는 경로가 남는다. 텍스트 파일이 아닌 것을 텍스트로 다루지
  # 않는 것이 근본이다 (Turn 008 F1).
  nul_sz="$(LC_ALL=C tr -d '\000' < "$f" 2>/dev/null | wc -c)" || return 1
  nul_sz="${nul_sz//[^0-9]/}"
  [ "$nul_sz" = "$sz" ] || return 1

  # ③ 마지막 바이트의 **값**으로 판정한다.
  #
  # `[ -z "$(tail -c 1 "$f")" ]` 는 안 된다 — 명령 치환이 NUL 을 버려 **NUL 종단을
  # LF 종단으로 오인**한다. macOS `/bin/bash` 3.2.57 에서 실측했고, 그 상태에서
  # `evil.key=주입<NUL>` 을 붙이면 종단 검사는 통과하고 행 필터가 그 행을 버려
  # Turn 006 F1 과 같은 우회가 성립했다.
  #
  # sentinel 을 덧붙여 비교하는 방법도 있지만, "왜 x 를 붙이는가" 가 코드에 드러나지
  # 않는다. `od` 로 바이트 값을 직접 보는 편이 의도가 그대로 읽힌다.
  last="$(tail -c 1 "$f" 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' \n')" || return 1
  [ "$last" = "10" ] || return 1
  return 0
}

# _archive_strip_owned — stdin 의 task-state 내용에서 archive 소유 키 행을 제거해 낸다.
# 소유 키 밖의 행만 남으므로, 기준선과 발행 후보의 결과가 같으면 "리뷰된 내용 그대로" 다.
# **호출 전에 `_archive_regular_text` 로 입력을 검증한다** — 위 주석 참조.
#
# **`=` 가 없는 행은 key 를 빈 문자열로 둔다.** `${line%%=*}` 를 `=` 유무 확인 없이 그대로
# 쓰면 `=` 가 없는 행에서 **행 전체**가 key 가 된다. `status`·`fr-branch` 처럼 소유 키
# "이름" 만 있고 값이 없는 행이 발행 후보에만 얹혀도 그 행 전체가 owned 목록의 한
# key(`status` 등)와 우연히 문자열 일치해 필터가 조용히 버리고, 그 결과 기준선·발행
# 후보의 필터 결과가 같아져 `cmp` 가 일치 — L2 가 rc 0 을 낸다 (다섯 번째 fail-open,
# final review Critical 1). 그 행은 `state_write_fields` 의 "나열하지 않은 행 보존"
# 계약 때문에 이후 실행에서도 지워지지 않고 영구히 남고, `_archive_regular_text` 의
# 세 조건(비어 있지 않음·NUL 없음·LF 종단)은 이 행을 정규 텍스트로 보아 걸러내지
# 못한다. 빈 key 는 `" $owned "` 의 어떤 " key "  패턴과도 매치되지 않으므로 행이
# 보존되어 아래 cmp 가 어긋나 정상적으로 차단된다.
_archive_strip_owned() {
  local owned line key
  owned=" $(lifecycle_owned_state_keys) "
  while IFS= read -r line; do
    case "$line" in *=*) key="${line%%=*}" ;; *) key="" ;; esac
    case "$owned" in *" ${key} "*) continue ;; esac
    printf '%s\n' "$line"
  done
}

# _archive_blob_oid <repo_root> <rev> <path> — stdout = blob OID
#   rc 0 = 존재, 1 = **경로 부재**(정상적인 발견 실패), 2 = **git 실행 오류**
#
# 부재와 실행 오류를 분리하는 것이 이 helper 의 존재 이유다 (D9).
# `cat-file -e` 는 둘을 같은 nonzero 로 내므로 쓰지 않는다. 호출 전에 baseline·publish
# 커밋의 실재를 확인해 두므로, 여기서 남은 rc 1 은 "그 커밋에 그 경로가 없다" 로 읽어도
# 안전하다. 128 등 그 밖의 rc 는 오류이며 통과로 소거하지 않는다.
_archive_blob_oid() {
  local out rc
  out="$(git -C "$1" rev-parse --verify --quiet "${2}:${3}" 2>/dev/null)"; rc=$?
  if [[ "$rc" -eq 0 ]]; then printf '%s\n' "$out"; return 0; fi
  [[ "$rc" -eq 1 ]] && return 1
  return 2
}

# _archive_tree_entry_mode <repo_root> <rev> <path> — stdout = tree entry mode (예 100644)
#   rc 0 = 존재, 1 = **경로 부재**(정상적인 발견 실패), 2 = **git 실행 오류**
#
# **blob OID 비교만으로는 mode·type 변경을 잡지 못합니다.** git 은 같은 blob OID 를
# 서로 다른 mode 로 참조할 수 있어(`100644` 정규 파일 / `100755` 실행 비트 /
# `120000` symlink), 기준선과 같은 bytes 를 symlink entry 로 커밋하면 L1 은 허용
# 경로라 통과하고 L2 의 blob 비교도 통과합니다. 그러나 발행 트리에서는 그 경로가
# 더 이상 정규 파일이 아니어서 checkout 후 파일 해석이 달라집니다 — 표현 차이가
# 아니라 tree 수준의 내용 변화입니다 (final diff review Turn 002 F2).
#
# `ls-tree` 는 판정 전용이며 fail-closed 입니다. 출력이 비면 rc 1(부재)로, git 실패는
# rc 2 로 갈라 기존 rc 규약(부재 != 실행 오류)을 그대로 지킵니다. 첫 필드만 읽으므로
# 경로에 공백·탭이 있어도 mode 판정은 영향을 받지 않습니다.
_archive_tree_entry_mode() {
  local out rc
  out="$(git -C "$1" ls-tree --full-tree "$2" -- "$3" 2>/dev/null)" && rc=0 || rc=$?
  [[ "$rc" -eq 0 ]] || return 2
  [[ -n "$out" ]] || return 1
  printf '%s\n' "${out%% *}"
  return 0
}

# _archive_assert_regular_mode <repo_root> <rev> <path> — rc 0 = 정규 파일(100644)
#   rc 1 = 부재이거나 정규 파일이 아님(차단), 2 = git 실행 오류
# 차단 사유는 이 함수가 stderr 로 낸다 — 호출부가 rc 만 보고 blocked 를 세우면 된다.
_archive_assert_regular_mode() {
  local mode rc
  mode="$(_archive_tree_entry_mode "$1" "$2" "$3")" && rc=0 || rc=$?
  if [[ "$rc" -eq 2 ]]; then return 2; fi
  if [[ "$rc" -eq 1 ]]; then
    printf 'archive:   발행 후보에 %s 의 tree entry 가 없습니다\n' "$3" >&2
    return 1
  fi
  if [[ "$mode" != "100644" ]]; then
    printf 'archive:   %s 의 발행 tree entry mode 가 정규 파일이 아닙니다 (%s != 100644)\n' "$3" "$mode" >&2
    printf 'archive:     실행 비트(100755)·symlink(120000)·submodule(160000) 은 같은 blob 이어도 차단합니다\n' >&2
    return 1
  fi
  return 0
}

# _archive_cat_blob <repo_root> <blob_oid> <outfile> — rc 0 = 성공, 2 = git 실행 오류
# 내용을 **raw 파일로 먼저 받는다.** filter 를 파이프로 잇지 않는 이유는 아래 주석에 있다.
_archive_cat_blob() {
  git -C "$1" cat-file blob "$2" > "$3" 2>/dev/null || return 2
  return 0
}

# archive_publish_content_check <repo_root> <baseline_oid> <publish_oid>
#   발행 후보의 허용 경로 파일 **최종 내용**을 확인한다.
#   rc 0 = 통과, 1 = 내용 불일치 차단, 2 = 판정 불능 (git 실행 오류·허용 경로 목록 실패)
#
# **git 명령을 filter 에 파이프로 잇지 않는다.** `if ! git show ... | _archive_strip_owned;`
# 형태는 조건이 파이프라인의 **마지막** 명령 rc 만 보므로(pipefail 을 이 파일이 켜지 않는다)
# `git show` 실패가 filter 의 정상 종료로 소거된다. 기준선과 발행 후보에서 task-state 를
# 모두 읽지 못하면 빈 파일끼리 cmp 하여 검사가 통과할 수도 있다 — fail-open 이다.
# 그래서 blob OID 조회 → raw 파일 수신 → filter 를 각 단계 rc 를 확인하며 분리한다
# (spec/plan review Turn 004 F1).
#
# 경로 판정(archive_extra_commits_check)은 커밋의 출처를 구분하지 못하는 근사다.
# "허용 경로는 Step 4 가 결정적으로 덮어쓰므로 안전하다" 는 전제는 CURRENT_TASK.md 에는
# 참이지만(emit_current_task_baseline 이 완전 재작성) **task-state 에는 거짓**이다 —
# metadata_clear 는 3개 키만, Step 4 는 2개 키만 바꾸고 state_write_fields 는 나열하지
# 않은 행을 보존한다. Step 4 자체도 metadata_exists 조건부다.
# 그래서 여기서 최종 내용을 직접 본다 (REQUEST review Turn 004 Finding 1).
archive_publish_content_check() {
  local root="$1" baseline="$2" publish="$3"
  local rel blocked=0 want got td rc=0 b_oid p_oid n_paths=0

  # 기준선·발행 후보가 실재하는 커밋인지 먼저 확인한다 — 이후 show 실패를 "파일 부재" 와 구분한다
  git -C "$root" rev-parse --verify --quiet "${baseline}^{commit}" >/dev/null 2>&1 || return 2
  git -C "$root" rev-parse --verify --quiet "${publish}^{commit}" >/dev/null 2>&1 || return 2

  # 목록을 **먼저 캡처하고 helper 의 rc 를 따로 본다** — 아래 `n_paths` 가드는 "빈 출력"
  # 만 막고 "일부 출력 후 실패" 를 놓친다. 한 경로만 출력하고 nonzero 로 끝나면 그 한
  # 경로만 검사하고 rc 0 을 낼 수 있어, 변조된 task-state 나 남은 active-fr 이 조용히
  # 검사에서 빠진다 (final diff review Turn 002 F3).
  #
  # **rc 는 1(내용 불일치) 이 아니라 2(판정 불능) 다.** 검사 목록을 만들 수 없다는 것은
  # 파일 내용에 대한 판정이 아니므로, rc 1 로 내면 호출부가 content 차단으로 해석해
  # "파일을 baseline 상태로 되돌리십시오" 라는 잘못된 절차를 낸다 — 되돌려도 해결되지
  # 않는다. 같은 실패를 L1(archive_extra_commits_check)도 rc 2 로 내므로 두 층의 처리가
  # 일치한다 (final diff review Turn 004 F6).
  local paths_out paths_rc
  paths_out="$(lifecycle_metadata_paths)" && paths_rc=0 || paths_rc=$?
  if [[ "$paths_rc" -ne 0 ]]; then
    printf 'archive:   허용 경로 목록 생성이 실패했습니다 (lifecycle_metadata_paths rc %s) — 부분 출력도 신뢰하지 않습니다\n' "$paths_rc" >&2
    return 2
  fi

  td="$(mktemp -d)" || return 2

  # **허용 경로 목록을 순회한다** — 목록이 구동원이다.
  # 대응 규칙이 없는 경로를 만나면 fail-closed 로 막는다. 그러지 않으면 목록에 항목을
  # 더했을 때 그 경로가 검사 없이 조용히 통과한다.
  #
  # `lifecycle_metadata_paths` 가 빈 출력이나 실패를 내는 경우도 여기서 함께 막는다.
  # 명령 치환(`$(lifecycle_metadata_paths)`) 은 그 함수의 rc 를 소거하므로, "목록 생성
  # 실패" 와 "검사할 경로가 원래 없음" 을 여기서는 구분할 수 없다. 하지만 한 건도
  # 처리하지 못했다면 이 함수는 아무것도 검사하지 못한 채 rc 0 을 내게 되어, "검사
  # 규칙이 없는 경로는 fail-closed" 라는 위 원칙과 정면으로 어긋난다. 그래서 처리
  # 건수를 세어 0 건이면 차단한다 (spec/plan review Turn 004 Finding I1).
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    n_paths=$((n_paths + 1))
    case "$rel" in

      CURRENT_TASK.md)
        # **byte 단위 비교다.** `$(git show ...)` 로 받아 문자열 비교하면 bash 가 trailing
        # newline 을 소거해, 끝에 빈 줄을 더하거나 지운 커밋이 "일치" 로 통과한다.
        # blob 해시는 내용을 그대로 반영하므로 그 구멍이 없다.
        # baseline 생성도 파이프로 잇지 않는다 — emit_current_task_baseline 의 실패가
        # hash-object 의 정상 종료로 소거되면 "빈 내용의 해시" 를 기대값으로 삼게 된다.
        #
        # 이 호출은 emit_current_task_baseline 이 **정적 heredoc** 이라는 전제에 기대고
        # 있다 — $root 를 인자로 넘기지 않는다. 이후 이 함수가 repo 상태를 읽도록 바뀌면
        # 기대값이 호출자의 cwd 를 따라가는 잠재 결함이 되므로, 그때는 $root 기준으로
        # 다시 설계해야 한다 (Minor M4).
        emit_current_task_baseline > "$td/want.raw" || { rm -rf "$td"; return 2; }
        want="$(git -C "$root" hash-object --stdin < "$td/want.raw" 2>/dev/null)" || { rm -rf "$td"; return 2; }
        got="$(_archive_blob_oid "$root" "$publish" "$rel")"; rc=$?
        if [[ "$rc" -eq 2 ]]; then rm -rf "$td"; return 2; fi
        if [[ "$rc" -eq 1 ]]; then
          printf 'archive:   발행 후보에 %s 가 없습니다\n' "$rel" >&2
          blocked=1
        elif [[ "$want" != "$got" ]]; then
          printf 'archive:   %s 가 baseline 상태가 아닙니다 (blob %s != 기대 %s)\n' \
            "$rel" "${got:0:8}" "${want:0:8}" >&2
          blocked=1
        else
          # blob 이 같아도 mode 가 다를 수 있다 — tree entry mode 를 따로 본다 (F2)
          _archive_assert_regular_mode "$root" "$publish" "$rel"; rc=$?
          if [[ "$rc" -eq 2 ]]; then rm -rf "$td"; return 2; fi
          [[ "$rc" -eq 0 ]] || blocked=1
        fi
        ;;

      */active-fr)
        # 부재(rc 1)는 정상이고 존재(rc 0)는 차단이며, 실행 오류(rc 2)는 통과가 아니다.
        _archive_blob_oid "$root" "$publish" "$rel" >/dev/null; rc=$?
        case "$rc" in
          0)
            printf 'archive:   legacy %s 가 발행 후보에 남아 있습니다\n' "$rel" >&2
            blocked=1
            ;;
          1) : ;;
          *) rm -rf "$td"; return 2 ;;
        esac
        ;;

      */task-state)
        # 소유 키 행을 제거한 결과를 파일로 만들어 cmp 로 byte 비교한다.
        # 단계마다 rc 를 확인한다 — 파이프 한 줄로 줄이면 git 실패가 소거된다.
        b_oid="$(_archive_blob_oid "$root" "$baseline" "$rel")"; rc=$?
        if [[ "$rc" -eq 2 ]]; then rm -rf "$td"; return 2; fi
        if [[ "$rc" -eq 1 ]]; then
          printf 'archive:   기준선 커밋에 %s 가 없습니다 — 대조할 수 없습니다\n' "$rel" >&2
          blocked=1
          continue
        fi
        p_oid="$(_archive_blob_oid "$root" "$publish" "$rel")"; rc=$?
        if [[ "$rc" -eq 2 ]]; then rm -rf "$td"; return 2; fi
        if [[ "$rc" -eq 1 ]]; then
          printf 'archive:   발행 후보에 %s 가 없습니다\n' "$rel" >&2
          blocked=1
          continue
        fi
        # blob 이 같아도 mode 가 다를 수 있다 — tree entry mode 를 따로 본다 (F2)
        _archive_assert_regular_mode "$root" "$publish" "$rel"; rc=$?
        if [[ "$rc" -eq 2 ]]; then rm -rf "$td"; return 2; fi
        if [[ "$rc" -ne 0 ]]; then blocked=1; continue; fi
        _archive_cat_blob "$root" "$b_oid" "$td/base.raw" || { rm -rf "$td"; return 2; }
        _archive_cat_blob "$root" "$p_oid" "$td/pub.raw" || { rm -rf "$td"; return 2; }
        # 행 필터에 넣기 전 종단 상태를 검증한다 — 마지막 LF 없는 행은 필터가 버린다
        if ! _archive_regular_text "$td/base.raw"; then
          printf 'archive:   기준선의 %s 가 정규 텍스트가 아닙니다 (빈 파일·NUL 포함·LF 미종단) — 대조할 수 없습니다\n' "$rel" >&2
          blocked=1
          continue
        fi
        if ! _archive_regular_text "$td/pub.raw"; then
          printf 'archive:   발행 후보의 %s 가 정규 텍스트가 아닙니다 (빈 파일·NUL 포함·LF 미종단)\n' "$rel" >&2
          printf 'archive:     행 단위 비교가 마지막 행을 놓치므로 통과시키지 않습니다\n' >&2
          blocked=1
          continue
        fi
        _archive_strip_owned < "$td/base.raw" > "$td/base" || { rm -rf "$td"; return 2; }
        _archive_strip_owned < "$td/pub.raw" > "$td/pub" || { rm -rf "$td"; return 2; }
        if ! cmp -s "$td/base" "$td/pub"; then
          printf 'archive:   %s 가 archive 소유 키 밖에서 달라졌습니다\n' "$rel" >&2
          printf 'archive:     소유 키: %s\n' "$(lifecycle_owned_state_keys)" >&2
          diff "$td/base" "$td/pub" 2>/dev/null | sed 's/^/archive:     /' >&2
          blocked=1
        fi
        ;;

      *)
        printf 'archive:   허용 경로 %s 에 대응하는 검사 규칙이 없습니다 — 안전하게 중단합니다\n' "$rel" >&2
        printf 'archive:     lifecycle_metadata_paths 에 항목을 더했다면 이 함수에 규칙도 함께 더하십시오\n' >&2
        blocked=1
        ;;

    esac
  done <<EOF
$paths_out
EOF

  if [[ "$n_paths" -eq 0 ]]; then
    printf 'archive:   검사할 허용 경로 목록을 얻지 못했습니다 (lifecycle_metadata_paths 빈 출력 또는 실패)\n' >&2
    blocked=1
  fi

  rm -rf "$td"
  [[ "$blocked" -eq 0 ]] || return 1
  return 0
}

# archive_block_notice <fr_ref> <repo_root> [kind]
#   차단 시 공통 안내. 무엇이 막혔는지(개별 사유)는 호출 전에 각 판정 helper 가 이미
#   stderr 로 냈다. 여기서는 "그래서 무엇을 해야 하는가" 만 낸다.
#
#   kind = commit  (기본) 얹힌 커밋을 특정했다(L1 차단) — 복구 절차는 fr 브랜치에서
#                  다시 만들고 diff review 후 기본 브랜치를 merge 이전으로 되돌리는 것
#        = unknown        판정 자체가 불가능했다 (git 실행 오류, 기대 밖 커밋 그래프)
#        = content        허용 경로 파일의 내용이 baseline 이 아니다(L2 차단) — 커밋의
#                  출처 문제가 아니므로 기본 브랜치를 되돌릴 필요가 없고, 그 파일을
#                  baseline 으로 되돌린 뒤 재실행하는 것이 복구 절차다 (Task 5 리뷰 조치 2)
#
# **사전 발행 실패 경로는 모두 이 함수를 지난다.** 안전하게 막힌 경우에도 사용자는
# 발행 여부·변경 보존 여부·다음 조치를 알아야 한다. 안전장치의 결과가 사용자에게
# 보이지 않으면 그 자리가 그대로 공백이 된다 (Turn 004 F5).
#
# 문구는 **특정 커밋의 존재에 의존하지 않는다.** git 오류로 막힌 경우에는 "위 커밋" 이
# 없을 수 있으므로 kind 에 따라 다르게 쓴다.
#
# **"보존" 의 의미와 "현재 이력 상태" 를 분리해서 쓴다** (Turn 006 F2). 이 함수는 merge 를
# 만든 뒤의 L1 오류에서도, Step 4 가 metadata 커밋을 만든 뒤의 후행 검증 오류에서도
# 호출된다. 그러므로 "기본 브랜치의 커밋을 아무것도 바꾸지 않았다" 는 문구는 **거짓**이다 —
# 이번 실행이 이미 HEAD 를 전진시켰을 수 있다. 보존이 뜻하는 것은 "차단 처리에서
# reset·rewrite·삭제를 하지 않았다" 이며, 실행 전 상태로 되돌아갔다는 뜻이 아니다.
# 현재 이력은 사용자가 상태 확인 명령으로 직접 보게 한다.
#
# 명령은 **실행 위치에 결속**한다. FR promote-advice-not-target-bound 가 기록한 결함을
# 반복하지 않는다 — 위치를 지정하지 않은 안내는 사용자가 다른 워킹트리에서 실행해
# 엉뚱한 대상을 바꾸게 만든다.
archive_block_notice() {
  local fr_ref="$1" root="$2" kind="${3:-commit}"
  printf 'archive: tag 와 push 를 실행하지 않았습니다 — 리뷰를 거치지 않은 내용이 발행될 수 있습니다\n' >&2
  if [[ "$kind" == "unknown" ]]; then
    printf 'archive:   무엇이 얹혔는지 판정할 수 없었습니다 — 통과시키지 않고 막았습니다\n' >&2
    # unknown 갈래에는 "위에 보고된 변경" 이 없다 — 판정 자체가 불가능했으므로 특정할
    # 수 있는 대상이 없다. "위에 보고된 변경을 그대로 보존했다" 는 존재하지 않는
    # 것을 보존했다는 자기모순 문장이 되므로(final review Minor M2), 보존의 대상을
    # "차단 처리" 로 좁혀 쓴다. 보존의 의미(reset·rewrite·삭제를 하지 않았다)는
    # 그대로 유지한다.
    printf 'archive:   차단 처리가 이력을 **그대로 보존**했습니다 — reset·rewrite·삭제를 하지 않았습니다\n' >&2
  else
    # 보존의 의미: 차단 처리가 이력을 건드리지 않았다. 실행 전 상태라는 뜻이 아니다.
    printf 'archive:   위에 보고된 변경을 **그대로 보존**했습니다 — reset·rewrite·삭제를 하지 않았습니다\n' >&2
  fi
  printf 'archive:   단, 이번 실행이 만든 merge·metadata 커밋은 이력에 남아 있을 수 있습니다\n' >&2
  printf 'archive:     아래 상태 확인 명령으로 현재 이력을 직접 확인하십시오\n' >&2
  printf 'archive:   fr 브랜치: %s\n' "$fr_ref" >&2
  printf 'archive:   복구 절차 —\n' >&2
  if [[ "$kind" == "content" ]]; then
    # L2(내용 검증) 차단 전용 절차. "얹힌 커밋" 차단과 원인이 다르다 — 문제는 커밋의
    # 출처가 아니라 발행 후보에 남은 **허용 경로 파일의 내용**이므로, "기본 브랜치를
    # merge 이전으로 되돌리라" 는 지시는 원인과 무관한 훨씬 무거운 절차로 사용자를
    # 잘못 유도한다 (Task 5 리뷰 조치 2).
    printf 'archive:     0) 되돌리기 전에 — 위에 보고된 값이 실제로 리뷰가 필요한 변경인지 먼저 확인하십시오\n' >&2
    printf 'archive:     1) 위에 보고된 파일을 baseline 상태로 되돌리고 (CURRENT_TASK.md 는 대기 중 초기 상태, task-state 는 owned 키를 제외한 나머지가 baseline 과 일치해야 합니다)\n' >&2
    printf 'archive:     2) archive 를 다시 실행하십시오 — 기본 브랜치를 merge 이전으로 되돌릴 필요는 없습니다\n' >&2
  elif [[ "$kind" == "unknown" ]]; then
    # unknown 갈래는 "무엇이 얹혔는지 모르는" 상태이므로 "그 변경을 다시 만들라" 는
    # 지시가 성립하지 않는다(final review Minor M2). 먼저 아래 상태 확인 명령으로
    # 현재 이력을 파악하는 것을 첫 단계로 두고, 이후 절차는 commit 갈래와 같다.
    printf 'archive:     1) 아래 상태 확인 명령으로 지금 이력에 무엇이 있는지 먼저 확인하고\n' >&2
    printf 'archive:     2) 확인된 변경을 %s 에서 다시 만들고\n' "$fr_ref" >&2
    printf 'archive:     3) diff review 를 거친 뒤\n' >&2
    printf 'archive:     4) 기본 브랜치를 merge 이전으로 되돌리고 archive 를 다시 실행하십시오\n' >&2
  else
    printf 'archive:     1) 그 변경을 %s 에서 다시 만들고\n' "$fr_ref" >&2
    printf 'archive:     2) diff review 를 거친 뒤\n' >&2
    printf 'archive:     3) 기본 브랜치를 merge 이전으로 되돌리고 archive 를 다시 실행하십시오\n' >&2
    # 3) 은 선택적 정리가 아니라 **필수**입니다 — 되돌리지 않고 fr 브랜치에서만 고쳐
    # 재실행하면, 다음 merge 가 이 커밋을 기준선 밑으로 묻어 이번 검사가 그 커밋을
    # 다시는 보지 못합니다 (final review Important I1 — `Risks` 절 참고).
    printf 'archive:     3) 을 건너뛰면 다음 실행이 이 커밋을 다시 검사하지 못할 수 있습니다\n' >&2
  fi
  printf 'archive:   현재 상태 확인: (cd %s && git log --oneline --first-parent -10)\n' "$root" >&2
}

# metadata_clear: fr-branch=null, worktree-path=null, source-fr=- reset + created-at 줄 제거 (파일 삭제 아님)
# legacy active-fr 파일이 잔존하면 함께 삭제 (merge 후 main에 남는 legacy 잔재 정리).
metadata_clear() {
  state_file_exists || return 0
  state_write_fields "fr-branch=null" "worktree-path=null" "source-fr=-"
  # created-at 줄 제거 (fr 비활성 시 부재 계약)
  local tmp
  tmp="$(mktemp "$(dirname "$TASK_STATE_PATH")/.task-state.XXXXXX")"
  awk -F'=' '$1!="created-at"' "$TASK_STATE_PATH" > "$tmp" && mv "$tmp" "$TASK_STATE_PATH"
  # legacy active-fr 잔재 정리 (archive cleanup 커밋에 자연 포함)
  local _legacy_afr="${project_root:-$PWD}/rd-workflow-workspace/.lifecycle/active-fr"
  [[ -f "$_legacy_afr" ]] && rm -f "$_legacy_afr"
  return 0
}

# metadata_exists: fr-branch 값이 비어있지 않고 null이 아니면 참 (파일 존재 여부가 아님)
# 존재 판정도 읽기와 동일한 legacy fallback을 공유 — pre-migration repo의 active 작업 보호
metadata_exists() {
  local v; v="$(metadata_read_field "fr-branch")"
  [[ -n "$v" && "$v" != "null" ]]
}

# CURRENT_TASK.md baseline form (Reviewer Turn 008 Issue 2 — runtime accessible inline heredoc)
emit_current_task_baseline() {
  cat <<'EOF'
# Current Task

## Task
-

## Short Title
-

## Status
대기 중

## Request
[REQUEST.md](REQUEST.md)

## Source FR
-

## Spec
-

## Plan
-

## Branch / Worktree
main

## Output Files
-

## Next Step
-

## Notes
-
EOF
}

# Claude Code 가 설치하는 .git/hooks/pre-commit 은 브랜치명이 main|master 일 때만 커밋을
# 차단합니다. trunk 등 커스텀 기본 브랜치에서는 차단되지 않으므로 --no-verify 를 붙일 이유가
# 없고, 붙이면 소비 프로젝트의 pre-commit·commit-msg 검증만 불필요하게 줄어듭니다.
lifecycle_needs_hook_bypass() {
  local b
  b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ "$b" == "main" || "$b" == "master" ]]
}

# lifecycle 커밋은 git pre-commit·commit-msg hook 을 --no-verify 로 건너뛴다.
# 우회 사실과 그 범위를 사용자에게 알린다 — "pre-commit 우회" 같은 축약은 금지다.
# 사용자가 무엇이 실행되지 않았는지 읽어서 알 수 있어야 한다 (change spec 결정 4).
# 반드시 커밋 직후에 호출한다 — staged 잔여 건수가 커밋 후 index 기준이어야 정확하다.
# 실제로 우회한 경우에만 호출한다 — 우회하지 않았는데 이 안내를 내보내면 거짓이다.
# $1: 호출 스크립트 이름 (promote | promote_rollback | archive)
lifecycle_notify_hook_bypass() {
  local script="$1"
  printf '%s: pre-commit·commit-msg hook 을 건너뛰고 커밋했습니다 — 프로젝트 자체 lint·포맷 검사와 커밋 메시지 정책 검사가 실행되지 않았습니다.\n' "$script"
  local leftover
  leftover="$(git diff --cached --name-only 2>/dev/null | grep -c . || true)"
  if [[ "$leftover" -gt 0 ]]; then
    printf '  (staged 변경 %s건은 lifecycle 커밋에 포함하지 않았습니다 — 그대로 남아 있습니다.)\n' "$leftover"
  fi
}
