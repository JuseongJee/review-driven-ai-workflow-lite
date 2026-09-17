#!/usr/bin/env bash
# 이 스위트가 **FAIL 한 줄 없이 rc 1 로 조용히 죽는** 사건이 관측됐는데(1/5 회), 사후에
# 지점을 특정할 방법이 없어 원인 확정이 불가능했습니다. 아래 두 trap 은 다음 재발을
# "판정 불능" 이 아니라 "즉시 인지 + 가능하면 지점 확정" 으로 바꿉니다.
# 기대값을 맞추려고 이 trap 들을 약화시키지 마십시오 — 약화시키는 순간 같은 사건이
# 다시 익명이 됩니다.
#
# **`-E` 는 의도적으로 켜지 않습니다** (실측 근거). `-E` 를 켜면 trap 이 함수·서브셸·명령
# 치환까지 물려받는데, bash 는 errexit 의 "판정 문맥 유예" 를 그 안쪽으로 물려주지
# 않습니다. 그래서 `x="$(cmd)" || true` · `( f ) && rc=0 || rc=1` 처럼 **이미 처리된
# 실패**에서 trap 이 전부 울립니다 (실측: 무관한 지점 9곳 + `stderr 무출력` 단언 1건 파괴).
# 그 실패들은 판정 문맥 안이라 애초에 스위트를 죽이지 못하므로 진단 대상이 아닙니다.
#
# **ERR trap 하나로는 부족합니다** (전수 매트릭스 실측 — task-8b-review §4). 조용한 죽음은
# 세 형태이고 `-E` 없는 ERR trap 은 그중 하나만 잡습니다.
#   - 최상위 단순 명령       → ERR **잡음** (줄번호까지)
#   - 최상위에서 부른 함수 안 → ERR **놓침**
#   - 최상위 서브셸 `( … )` 안 → ERR **놓침**
# 이 스위트는 `ast_reset_marks` 같은 자기 헬퍼 함수와 `( … )` 를 전반에서 쓰므로 놓치는
# 범위가 예외가 아닙니다. 그래서 **EXIT 센티넬**을 함께 겁니다 — 결과줄을 찍고 `DONE=1`
# 을 세우기 전에 셸이 끝나면 무조건 FAIL 을 냅니다. 세 형태를 모두 덮고, 판정 문맥은
# bash 가 부모의 EXIT trap 을 `( … )`·명령 치환 안에서 실행하지 않으므로 오탐이 없습니다.
# 둘의 조합이 "항상 알려 주고, 가능하면 지점까지 짚는" 형태입니다.
set -euo pipefail
trap 'ec=$?; echo "  FAIL: 스위트가 line ${LINENO} 에서 rc=${ec} 로 중단됐습니다 (조용한 중단)" >&2' ERR
# **EXIT trap 은 하나뿐입니다 — 두 번째를 걸면 첫 번째가 조용히 사라집니다.** 그래서
# 임시 디렉터리 정리도 이 핸들러가 함께 합니다 (실측: 센티넬만 따로 걸었더니 아래
# `TMPDIR_TEST` 정리 trap 이 그것을 덮어써 세 형태 모두 검출되지 않았습니다).
# 서브셸 `( … )` 안의 `trap … EXIT` 는 그 서브셸에만 걸리므로 여기와 충돌하지 않습니다.
# 최상위에 EXIT trap 을 새로 걸지 마십시오 — 정리 대상은 `_ast_cleanup` 에 append 하고,
# 그 규칙이 지켜졌는지는 스위트 끝의 `trap -p EXIT` 단언이 실행 시점에 확인합니다.
#
# `local _ec=$?` 를 **첫 줄**에서 붙잡습니다. `[[ … ]] || echo "…$?"` 로 쓰면 `$?` 가
# `[[ ]]` 의 rc(=1)로 전개돼 실제 중단 rc(127·2 …)를 감춥니다 — 메시지가 사실과 다른
# 말을 하게 되고, 이 스위트가 반복해서 고쳐 온 결함이 바로 그것입니다.
DONE=0
_ast_cleanup=()
_suite_on_exit() {
  local _ec=$? _d
  for _d in ${_ast_cleanup[@]+"${_ast_cleanup[@]}"}; do [[ -z "$_d" ]] || rm -rf "$_d"; done
  [[ "$DONE" == 1 ]] || echo "  FAIL: 스위트가 결과줄 없이 rc=${_ec} 로 중단됐습니다 (조용한 중단 — 마지막 PASS 줄 다음을 보십시오)" >&2
}
trap _suite_on_exit EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/slug.sh"

# **실제 herdr 호출 차단 (파일 전체 적용).** 이 스위트는 promote.sh 를 자식 프로세스로
# 여러 번 실행하고, 재설계된 promote.sh 는 session_launch 를 호출한다. 이 세션 자체가
# herdr pane 안에서 돌면 HERDR_ENV=1 이 하위 프로세스로 그대로 상속되어, 임시
# fixture 에서 promote 를 실행하는 것만으로 **실제 herdr pane split/agent start** 가
# 발생한다(2026-09-15 실측 — 사용자 화면에 pane 이 실제로 생김). 지시만으로는 간접
# 호출 경로를 막지 못하므로 환경으로 원천 차단한다 — 아래 두 변수 각각이 다른
# 방어선이다(하나만으로 만족하지 않는다):
#   - HERDR_ENV= : session_launch 의 herdr 환경 판정 자체를 끈다.
#   - RD_CHILD_SESSION=1 : 이미 자식 세션이라는 깊이-1 제한 경로로 보내 기동을 거부한다.
# 파일 상단에서 한 번 export 해 이 파일의 모든 케이스(FIX1~FIX15, Task 4 worktree
# 병렬 착수 블록 포함)에 적용되게 한다. 서브셸은 export 된 환경변수를 그대로 물려받으므로
# 각 케이스에서 다시 설정할 필요가 없다.
export HERDR_ENV=
export RD_CHILD_SESSION=1

PASS=0; FAIL=0
assert_eq() {
  local got="$1" want="$2" desc="$3"
  if [[ "$got" == "$want" ]]; then PASS=$((PASS+1)); echo "  PASS: $desc";
  else FAIL=$((FAIL+1)); echo "  FAIL: $desc — got=[$got] want=[$want]" >&2; fi
}
assert_err() {
  local input="$1" desc="$2"
  if normalize_slug "$input" >/dev/null 2>&1; then
    FAIL=$((FAIL+1)); echo "  FAIL: $desc — expected error but got success" >&2
  else PASS=$((PASS+1)); echo "  PASS: $desc"; fi
}

echo "== archive 단일 출처 helper =="
source "$SCRIPT_DIR/_lifecycle_common.sh"

# 허용 경로 목록 — 개행 구분, 3개
_lmp="$(lifecycle_metadata_paths)"
assert_eq "$(printf '%s\n' "$_lmp" | wc -l | tr -d ' ')" "3" "lifecycle_metadata_paths 3행"
# 순서 고정 계약 — 행 번호에 결속해 정확히 일치를 본다.
# 포함 여부만 보면 순서가 뒤바뀌는 회귀를 놓친다 (Task 3·4 가 이 순서에 의존).
assert_eq "$(printf '%s\n' "$_lmp" | sed -n 1p)" "rd-workflow-workspace/.lifecycle/task-state" "허용 경로 1행 = task-state"
assert_eq "$(printf '%s\n' "$_lmp" | sed -n 2p)" "CURRENT_TASK.md" "허용 경로 2행 = CURRENT_TASK.md"
assert_eq "$(printf '%s\n' "$_lmp" | sed -n 3p)" "rd-workflow-workspace/.lifecycle/active-fr" "허용 경로 3행 = legacy active-fr"

# 소유 키 목록 — 공백 구분 한 줄, 8개
#
# `base-commit`·`review-session` 이 목록에 있어야 합니다 (change spec §5.3). metadata_clear 가
# 두 값을 baseline 으로 되돌리는데 목록에서 빠지면 그 차이를 archive_publish_content_check 가
# "리뷰되지 않은 내용" 으로 판정해 **정상 아카이브가 차단**됩니다.
_lok="$(lifecycle_owned_state_keys)"
assert_eq "$(printf '%s' "$_lok" | wc -w | tr -d ' ')" "8" "lifecycle_owned_state_keys 8개"
for _k in fr-branch worktree-path source-fr short-title status created-at base-commit review-session; do
  case " $_lok " in
    *" $_k "*) PASS=$((PASS+1)); echo "  PASS: 소유 키 $_k 포함" ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: 소유 키 $_k 누락" >&2 ;;
  esac
done

# 소유 키 registry 가 writer 의 **실제 동작**과 일치하는가.
#
# grep 으로 이름 존재만 보면 문자열이 있다는 사실만 증명하고 동작을 증명하지 못한다.
# metadata_clear 를 실제로 실행해 어떤 키가 바뀌었는지 관측한다.
_ok_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_ok_repo" && -d "$_ok_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_ok_repo="$(cd "$_ok_repo" && pwd -P)"
_ast_cleanup+=("$_ok_repo")
mkdir -p "$_ok_repo/rd-workflow-workspace/.lifecycle"
_ok_ts="$_ok_repo/rd-workflow-workspace/.lifecycle/task-state"
#
# **초기값은 writer 가 되돌릴 값과 달라야 한다.** `source-fr=-` 로 두면 metadata_clear 가
# 같은 `-` 를 쓰므로 값이 변하지 않고, 아래 역방향 검사가 그 키를 "실제로 안 바뀐 키" 로
# 판정해 **올바른 구현도 FAIL** 한다 (Turn 004 F4).
printf 'schema=1\nshort-title=x\nstatus=구현 중\nfr-branch=fr/x\nworktree-path=/p\nsource-fr=rd-workflow-workspace/backlog/items/x.md\ncreated-at=2026-01-01-0000\nextensions.foo.bar=v\n' > "$_ok_ts"
cp "$_ok_ts" "$_ok_ts.before"
(
  TASK_STATE_PATH="$_ok_ts" project_root="$_ok_repo"
  . "$SCRIPT_DIR/../_state_common.sh"
  . "$SCRIPT_DIR/_lifecycle_common.sh"
  metadata_clear
  # archive.sh Step 4 가 이어서 쓰는 두 키
  state_write_fields "short-title=-" "status=대기 중"
) >/dev/null 2>&1

# 바뀐 키 집합을 관측 (추가·삭제·값 변경 모두)
_changed=""
while IFS= read -r _line; do
  _k="${_line%%=*}"
  case " $_changed " in *" $_k "*) continue ;; esac
  _changed="$_changed $_k"
done < <(diff "$_ok_ts.before" "$_ok_ts" | grep -E '^[<>]' | sed 's/^..//')

_registry=" $(lifecycle_owned_state_keys) "
_extra=""
for _k in $_changed; do
  case "$_registry" in *" $_k "*) ;; *) _extra="$_extra $_k" ;; esac
done
if [[ -z "$_extra" ]]; then
  PASS=$((PASS+1)); echo "  PASS: writer 가 바꾼 키가 모두 registry 안 (관측:$_changed)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: registry 밖 키가 바뀜 —$_extra" >&2
fi
# 역방향 — registry 에만 있고 실제로 안 바뀐 키가 있으면 registry 가 과대
_unused=""
for _k in $(lifecycle_owned_state_keys); do
  case " $_changed " in *" $_k "*) ;; *) _unused="$_unused $_k" ;; esac
done
if [[ -z "$_unused" ]]; then
  PASS=$((PASS+1)); echo "  PASS: registry 의 모든 키가 실제로 바뀜 (과대 아님)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: registry 에만 있고 바뀌지 않은 키 —$_unused" >&2
fi


echo "== archive_baseline_commit =="
_bc_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_bc_repo" && -d "$_bc_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_bc_repo="$(cd "$_bc_repo" && pwd -P)"
_ast_cleanup+=("$_bc_repo")
(
  cd "$_bc_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
  git checkout -q -b fr/probe
  printf 'v1\n' > f.txt; git add .; git commit -qm feat
  git checkout -q main
  printf 'v2\n' > a.txt; git add .; git commit -qm "main 선행"
  git merge -q --no-ff fr/probe -m "merge: probe"
) >/dev/null 2>&1

_want="$(git -C "$_bc_repo" rev-parse HEAD)"
_got="$(archive_baseline_commit "$_bc_repo" fr/probe "$(git -C "$_bc_repo" rev-parse HEAD)")"
assert_eq "$_got" "$_want" "no-ff merge 를 기준선으로 찾음"

# octopus — fr tip 이 세 번째 부모. **차단해야 한다.**
#
# 기준선은 baseline..head 검사에서 제외되므로, octopus 를 기준선으로 인정하면 그 merge 가
# fr tip 과 함께 들여온 다른 부모의 미리뷰 내용이 검사 밖에 놓인다(실측: 얹힌 커밋 0건,
# side.txt 가 발행 트리에 존재). 놓쳐서 차단하는 쪽이 안전하다.
_oc_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_oc_repo" && -d "$_oc_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_oc_repo="$(cd "$_oc_repo" && pwd -P)"
_ast_cleanup+=("$_oc_repo")
(
  cd "$_oc_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
  git checkout -q -b side; printf 'MIRIVIEW\n' > side.txt; git add .; git commit -qm side
  git checkout -q main
  git checkout -q -b fr/oct; printf 'v1\n' > f.txt; git add .; git commit -qm fr
  git checkout -q main
  printf 'v2\n' > a.txt; git add .; git commit -qm "main 선행"
  git merge -q --no-ff side fr/oct -m octopus
) >/dev/null 2>&1
_rc=0; archive_baseline_commit "$_oc_repo" fr/oct "$(git -C "$_oc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "octopus 는 기준선으로 인정하지 않고 차단"

# octopus — fr tip 이 **두 번째** 부모. 역시 차단해야 한다.
#
# 위 케이스만으로는 "부모가 정확히 2개" 검사가 하중을 받지 않는다. 거기서는 p2=side 라
# p2 != fr_tip 으로 먼저 걸러지므로, `n -eq 2` 를 `n -ge 2` 로 완화해도 통과한다(실측).
# 이 케이스는 p2 == fr_tip 이면서 부모가 3개이므로 개수 검사만이 막을 수 있다.
_oc2_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_oc2_repo" && -d "$_oc2_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_oc2_repo="$(cd "$_oc2_repo" && pwd -P)"
_ast_cleanup+=("$_oc2_repo")
(
  cd "$_oc2_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
  git checkout -q -b side2; printf 'MIRIVIEW\n' > side2.txt; git add .; git commit -qm side
  git checkout -q main
  git checkout -q -b fr/oct2; printf 'v1\n' > f.txt; git add .; git commit -qm fr
  git checkout -q main
  printf 'v2\n' > a.txt; git add .; git commit -qm "main 선행"
  git merge -q --no-ff fr/oct2 side2 -m octopus
) >/dev/null 2>&1
# 전제 확인 — fr tip 이 실제로 두 번째 부모인가. 아니면 이 케이스는 의도를 잃는다.
_oc2_head="$(git -C "$_oc2_repo" rev-parse HEAD)"
_oc2_p2="$(git -C "$_oc2_repo" rev-parse "${_oc2_head}^2")"
assert_eq "$_oc2_p2" "$(git -C "$_oc2_repo" rev-parse fr/oct2)" "octopus 전제: fr tip 이 두 번째 부모"
_rc=0; archive_baseline_commit "$_oc2_repo" fr/oct2 "$_oc2_head" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "부모 3개 octopus 는 p2 가 fr tip 이어도 차단"

# fast-forward — merge 커밋 없음, fr tip 이 first-parent 체인에 존재
_ff_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_ff_repo" && -d "$_ff_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_ff_repo="$(cd "$_ff_repo" && pwd -P)"
_ast_cleanup+=("$_ff_repo")
(
  cd "$_ff_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
  git checkout -q -b fr/ff; printf 'v1\n' > f.txt; git add .; git commit -qm fr
  git checkout -q main; git merge -q --ff-only fr/ff
  printf 'v2\n' > b.txt; git add .; git commit -qm "이후 커밋"
) >/dev/null 2>&1
_got="$(archive_baseline_commit "$_ff_repo" fr/ff "$(git -C "$_ff_repo" rev-parse HEAD)")"
assert_eq "$_got" "$(git -C "$_ff_repo" rev-parse fr/ff)" "fast-forward 는 fr tip 이 기준선"

# fr tip 이 조상이 아님 → 차단(rc 1)
_no_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_no_repo" && -d "$_no_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_no_repo="$(cd "$_no_repo" && pwd -P)"
_ast_cleanup+=("$_no_repo")
(
  cd "$_no_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
  git checkout -q -b fr/none; printf 'v1\n' > f.txt; git add .; git commit -qm fr
  git checkout -q main; printf 'v2\n' > b.txt; git add .; git commit -qm other
) >/dev/null 2>&1
_rc=0; archive_baseline_commit "$_no_repo" fr/none "$(git -C "$_no_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "merge 없고 체인에도 없으면 rc 1 차단"

# 없는 ref → git 오류(rc 2)
_rc=0; archive_baseline_commit "$_bc_repo" fr/does-not-exist "$(git -C "$_bc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "2" "없는 fr ref 는 rc 2 git 오류"

echo "== archive_extra_commits_check =="
_ec_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_ec_repo" && -d "$_ec_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_ec_repo="$(cd "$_ec_repo" && pwd -P)"
_ast_cleanup+=("$_ec_repo")
(
  cd "$_ec_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  mkdir -p rd-workflow-workspace/.lifecycle
  printf 'v1\n' > a.txt; git add .; git commit -qm base
) >/dev/null 2>&1
_ec_base="$(git -C "$_ec_repo" rev-parse HEAD)"

# 얹힌 커밋 없음 → 통과
_rc=0; archive_extra_commits_check "$_ec_repo" "$_ec_base" "$_ec_base" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "얹힌 커밋 0건은 통과"

# 허용 경로만 바꾼 커밋 → 통과
( cd "$_ec_repo" && printf 'x\n' > CURRENT_TASK.md && git add CURRENT_TASK.md \
  && git commit -qm "metadata only" ) >/dev/null 2>&1
_rc=0; archive_extra_commits_check "$_ec_repo" "$_ec_base" "$(git -C "$_ec_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "허용 경로만 바꾼 커밋은 통과"

# 제품 코드 커밋 → 차단
( cd "$_ec_repo" && printf 'v2\n' > a.txt && git add a.txt && git commit -qm "제품 코드" ) >/dev/null 2>&1
_rc=0; archive_extra_commits_check "$_ec_repo" "$_ec_base" "$(git -C "$_ec_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "허용 경로 밖 커밋은 차단"

# 허용 경로와 밖 경로를 **한 커밋에 섞음** → 차단
#
# 위 케이스들은 경로가 모두 허용이거나 모두 밖이라, "하나라도 허용이면 통과" 로
# 완화해도 전부 통과한다. 섞인 커밋만이 "모든 경로가 허용이어야 한다" 를 검증한다.
#
# **별도 fixture 를 쓴다.** _ec_repo 는 앞 케이스의 제품 코드 커밋이 이미 범위에 있어
# 혼합 커밋이 없어도 차단되므로, 그 repo 에서는 이 케이스가 의도를 잃는다.
_mx_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_mx_repo" && -d "$_mx_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_mx_repo="$(cd "$_mx_repo" && pwd -P)"
_ast_cleanup+=("$_mx_repo")
(
  cd "$_mx_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
) >/dev/null 2>&1
_mx_base="$(git -C "$_mx_repo" rev-parse HEAD)"
( cd "$_mx_repo" \
    && printf 'x\n' > CURRENT_TASK.md \
    && printf 'v2\n' > a.txt \
    && git add CURRENT_TASK.md a.txt \
    && git commit -qm "허용+밖 혼합" ) >/dev/null 2>&1
# 전제 확인 — 이 커밋이 실제로 두 경로를 함께 담았는가
assert_eq "$(git -C "$_mx_repo" diff-tree --no-commit-id -r --name-only HEAD^1 HEAD | LC_ALL=C sort | tr '\n' ' ')" \
          "CURRENT_TASK.md a.txt " "혼합 전제: 한 커밋에 허용·밖 경로가 함께 있다"
_rc=0; archive_extra_commits_check "$_mx_repo" "$_mx_base" "$(git -C "$_mx_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "허용 경로와 밖 경로가 섞인 커밋은 차단"

# 허용 경로에 근접한 이름 → 차단 (정확 일치여야 한다)
#
# `CURRENT_TASK.md.bak` 은 허용 경로를 접두로 갖는다. 부분 문자열 비교로 완화하면
# 통과하므로, 이 케이스가 정확 일치 계약의 하중을 받는다.
_nm_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_nm_repo" && -d "$_nm_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_nm_repo="$(cd "$_nm_repo" && pwd -P)"
_ast_cleanup+=("$_nm_repo")
(
  cd "$_nm_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
) >/dev/null 2>&1
_nm_base="$(git -C "$_nm_repo" rev-parse HEAD)"
( cd "$_nm_repo" && printf 'x\n' > CURRENT_TASK.md.bak && git add . && git commit -qm "근접 이름" ) >/dev/null 2>&1
_rc=0; archive_extra_commits_check "$_nm_repo" "$_nm_base" "$(git -C "$_nm_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "허용 경로에 근접한 이름은 차단 (정확 일치)"

# 빈 커밋 → 차단
_em_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_em_repo" && -d "$_em_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_em_repo="$(cd "$_em_repo" && pwd -P)"
_ast_cleanup+=("$_em_repo")
(
  cd "$_em_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
) >/dev/null 2>&1
_em_base="$(git -C "$_em_repo" rev-parse HEAD)"
( cd "$_em_repo" && git commit -q --allow-empty -m "빈 커밋" ) >/dev/null 2>&1
_rc=0; archive_extra_commits_check "$_em_repo" "$_em_base" "$(git -C "$_em_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "빈 커밋은 차단"

# 사람이 다른 브랜치를 merge → 차단 (첫 부모 비교로 경로가 드러남)
_mg_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_mg_repo" && -d "$_mg_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_mg_repo="$(cd "$_mg_repo" && pwd -P)"
_ast_cleanup+=("$_mg_repo")
(
  cd "$_mg_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
) >/dev/null 2>&1
_mg_base="$(git -C "$_mg_repo" rev-parse HEAD)"
(
  cd "$_mg_repo"
  git checkout -q -b side; printf 'v1\n' > side.txt; git add .; git commit -qm side
  git checkout -q main; git merge -q --no-ff side -m "사람이 merge"
) >/dev/null 2>&1
_rc=0; archive_extra_commits_check "$_mg_repo" "$_mg_base" "$(git -C "$_mg_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "사람이 만든 merge 커밋은 차단 (git show --name-only 로는 통과했던 경로)"

# 공백·따옴표 경로 → 정확 판정 (차단)
_sp_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_sp_repo" && -d "$_sp_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_sp_repo="$(cd "$_sp_repo" && pwd -P)"
_ast_cleanup+=("$_sp_repo")
(
  cd "$_sp_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  printf 'v1\n' > a.txt; git add .; git commit -qm base
) >/dev/null 2>&1
_sp_base="$(git -C "$_sp_repo" rev-parse HEAD)"
( cd "$_sp_repo" && printf 'v1\n' > "sp ace'q.txt" && git add -A && git commit -qm "특수문자 경로" ) >/dev/null 2>&1
_rc=0; archive_extra_commits_check "$_sp_repo" "$_sp_base" "$(git -C "$_sp_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "공백·따옴표 경로도 정확 판정"

# git 오류 → rc 2
_rc=0; archive_extra_commits_check "$_ec_repo" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$(git -C "$_ec_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "2" "존재하지 않는 기준선은 rc 2 git 오류"

echo "== archive_publish_content_check =="
_pc_repo="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_pc_repo" && -d "$_pc_repo" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_pc_repo="$(cd "$_pc_repo" && pwd -P)"
_ast_cleanup+=("$_pc_repo")
_pc_ts="rd-workflow-workspace/.lifecycle/task-state"
(
  cd "$_pc_repo"
  git init -q .; git checkout -q -b main
  git config user.email t@t; git config user.name t
  mkdir -p rd-workflow-workspace/.lifecycle
  printf 'schema=1\nshort-title=x\nstatus=구현 중\nfr-branch=fr/x\nworktree-path=null\nsource-fr=-\ncreated-at=2026-01-01-0000\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  printf 'placeholder\n' > CURRENT_TASK.md
  git add -A; git commit -qm "기준선"
) >/dev/null 2>&1
_pc_base="$(git -C "$_pc_repo" rev-parse HEAD)"

# 정상 — CURRENT_TASK.md 가 baseline, task-state 는 소유 키만 전이
(
  cd "$_pc_repo"
  emit_current_task_baseline > CURRENT_TASK.md
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A; git commit -qm "정상 metadata 정리"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "소유 키만 전이한 정상 상태는 통과"

# 반례 a — task-state 에 임의 키 추가 + extensions 변조
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=변조된 값\nevil.key=주입\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A; git commit -qm "metadata-only 주입"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "소유 키 밖 task-state 변화는 차단"

# 반례 b — schema 변조
(
  cd "$_pc_repo"
  printf 'schema=2\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A; git commit -qm "schema 변조"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "schema 변조는 차단"

# 반례 c — CURRENT_TASK.md 가 baseline 이 아님 (Step 4 skip 상황)
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  printf '# Current Task\n\n## Status\n구현 중\n' > CURRENT_TASK.md
  git add -A; git commit -qm "미러가 baseline 아님"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "CURRENT_TASK.md 가 baseline 이 아니면 차단"

# 반례 d — legacy active-fr 잔존
(
  cd "$_pc_repo"
  emit_current_task_baseline > CURRENT_TASK.md
  printf 'fr/x\n' > "rd-workflow-workspace/.lifecycle/active-fr"
  git add -A; git commit -qm "legacy active-fr 잔존"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "legacy active-fr 잔존은 차단"

# 반례 e — CURRENT_TASK.md 끝에 빈 줄만 추가 (byte-exact 여야 잡힌다)
(
  cd "$_pc_repo"
  rm -f "rd-workflow-workspace/.lifecycle/active-fr"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  { emit_current_task_baseline; printf '\n'; } > CURRENT_TASK.md
  git add -A && git commit -q -m "끝에 빈 줄 추가"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "CURRENT_TASK.md 끝의 빈 줄 추가도 차단 (byte-exact)"

# 반례 f — 허용 경로 목록에 검사 규칙 없는 항목이 있으면 fail-closed
(
  cd "$_pc_repo"
  emit_current_task_baseline > CURRENT_TASK.md
  git add -A && git commit -q -m "정상 복구"
) >/dev/null 2>&1

# 복원 검증 — 복원이 불완전하면 이후 반례가 자기 주입이 아니라 남은 오염 때문에
# 차단되어 전부 엉뚱한 이유로 통과한다. 여기서 통과(rc 0)를 확인해야 그 다음 반례의
# 차단이 그 반례의 주입 때문임이 보장된다.
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "복원 직후에는 통과 — 이후 반례의 차단이 자기 주입 때문임을 보증"
_saved_paths="$(declare -f lifecycle_metadata_paths)"
lifecycle_metadata_paths() { printf '%s\n' 'CURRENT_TASK.md' 'rd-workflow-workspace/.lifecycle/task-state' 'unknown/new-path'; }
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "검사 규칙 없는 허용 경로는 fail-closed 차단"
eval "$_saved_paths"

# 반례 f2 — lifecycle_metadata_paths 가 빈 출력 (Important I1)
# 명령 치환이 이 함수의 rc 를 소거하므로 "목록 생성 실패" 와 "검사할 경로가 원래
# 없음" 을 구분할 수 없다. 한 건도 처리하지 못했으면 fail-closed 로 차단해야 한다 —
# 그러지 않으면 목록이 통째로 비거나 실패해도 L2 가 공허하게 rc 0 을 낸다.
_saved_paths="$(declare -f lifecycle_metadata_paths)"
lifecycle_metadata_paths() { :; }
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "허용 경로 목록이 빈 출력이면 차단 (처리 0건은 fail-closed)"
eval "$_saved_paths"

# 반례 f3 — lifecycle_metadata_paths 자체가 실패(nonzero, 빈 출력 동반)
#
# **rc 는 2(판정 불능) 다.** 검사 목록을 만들 수 없는 것은 파일 내용 판정이 아니므로,
# rc 1 로 고정하면 호출부가 content 차단으로 해석해 "baseline 상태로 되돌리십시오" 라는
# 잘못된 절차를 낸다. L1 도 같은 실패를 rc 2 로 내므로 두 층이 일치한다
# (final diff review Turn 004 F6 — 기존에 rc 1 을 고정하고 있던 자리다).
_saved_paths="$(declare -f lifecycle_metadata_paths)"
lifecycle_metadata_paths() { return 7; }
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "2" "허용 경로 목록 생성이 실패하면 판정 불능(rc 2) — content 차단으로 오분류하지 않는다"
eval "$_saved_paths"

# 반례 f4 — lifecycle_metadata_paths 가 **한 줄을 출력한 뒤** nonzero (final diff review F3)
# 반례 f3 는 "nonzero + 빈 출력" 만 다루므로 `n_paths == 0` 가드가 우연히 막아 준다.
# 부분 출력은 그 가드를 통과해 축소된 목록으로 검사가 끝나고 rc 0 이 나온다 — 변조된
# task-state 나 남은 active-fr 이 조용히 검사에서 빠진다. helper 의 rc 를 별도로 봐야
# 막힌다.
_saved_paths="$(declare -f lifecycle_metadata_paths)"
lifecycle_metadata_paths() { printf '%s\n' 'CURRENT_TASK.md'; return 7; }
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "2" "허용 경로 목록이 부분 출력 후 실패하면 판정 불능(rc 2) (n_paths 가드로는 못 막는 갈래)"
eval "$_saved_paths"

# 같은 소거가 L1 소비처에도 없어야 한다 — 판정 불능이므로 rc 2 (호출부의 unknown 안내)
_saved_paths="$(declare -f lifecycle_metadata_paths)"
lifecycle_metadata_paths() { printf '%s\n' 'CURRENT_TASK.md'; return 7; }
_rc=0; archive_extra_commits_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "2" "L1 도 허용 경로 목록 실패를 판정 불능(rc 2)으로 낸다"
eval "$_saved_paths"

# 반례 g — task-state 가 발행 후보에 **없다** (정상적인 발견 실패 → rc 1 차단, rc 2 아님)
(
  cd "$_pc_repo"
  git rm -q --cached "rd-workflow-workspace/.lifecycle/task-state"
  rm -f "rd-workflow-workspace/.lifecycle/task-state"
  git commit -qm "task-state 삭제"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "task-state 부재는 rc 1 차단 — 실행 오류(rc 2)와 구분된다"
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  emit_current_task_baseline > CURRENT_TASK.md
  git add -A && git commit -qm "task-state 복구"
) >/dev/null 2>&1

# 복원 검증 — 복원이 불완전하면 이후 반례가 자기 주입이 아니라 남은 오염 때문에
# 차단되어 전부 엉뚱한 이유로 통과한다. 여기서 통과(rc 0)를 확인해야 그 다음 반례의
# 차단이 그 반례의 주입 때문임이 보장된다.
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "복원 직후에는 통과 — 이후 반례의 차단이 자기 주입 때문임을 보증"

# 반례 h — **git 명령을 실제로 실패시킨다** (Turn 004 F1)
# 파이프로 filter 를 잇던 구현에서는 이 실패가 filter 의 정상 종료로 소거되어
# 빈 파일끼리 cmp 하며 통과했다. rc 2 여야 한다.
git() {
  case "$*" in
    *"cat-file blob"*) return 128 ;;
  esac
  command git "$@"
}
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(command git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
unset -f git
assert_eq "$_rc" "2" "cat-file blob 실행 실패는 통과로 소거되지 않고 rc 2"

# 반례 i — blob OID 조회 자체가 실패하는 경우도 rc 2
git() {
  case "$*" in
    *"rev-parse --verify --quiet"*":rd-workflow-workspace"*) return 128 ;;
  esac
  command git "$@"
}
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(command git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
unset -f git
assert_eq "$_rc" "2" "blob OID 조회 실패도 rc 2 (부재 rc 1 과 구분)"

# 반례 j — emit_current_task_baseline 실패도 소거되지 않는다
_saved_emit="$(declare -f emit_current_task_baseline)"
emit_current_task_baseline() { return 3; }
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
eval "$_saved_emit"
assert_eq "$_rc" "2" "baseline 생성 실패는 빈 기대값으로 소거되지 않고 rc 2"

# 반례 k — 소유 키 밖 행을 **마지막 LF 없이** 주입 (Turn 006 F1 의 fail-open)
# 행 단위 필터는 이 행을 버려 기준선과 같은 결과를 내고 rc 0 으로 통과했다 (실증).
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\nevil.key=주입' > "rd-workflow-workspace/.lifecycle/task-state"
  emit_current_task_baseline > CURRENT_TASK.md
  git add -A && git commit -q -m "LF 없이 임의 키 주입"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "마지막 LF 없는 임의 키 주입은 차단 (행 필터가 버리지 못하게)"

# 반례 l — 주입 없이 마지막 LF 만 제거해도 정규 형식 위반으로 차단
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -q -m "마지막 LF 제거"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "LF 종단이 아닌 task-state 는 차단 (rc 1 — 실행 오류 2 와 구분)"

# 반례 m — task-state 가 빈 파일
(
  cd "$_pc_repo"
  : > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -q -m "빈 task-state"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "빈 task-state 는 차단 (LF 종단 검사가 빈 파일을 통과시키지 않음)"
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -qm "task-state 복구"
) >/dev/null 2>&1

# 복원 검증 — 복원이 불완전하면 이후 반례가 자기 주입이 아니라 남은 오염 때문에
# 차단되어 전부 엉뚱한 이유로 통과한다. 여기서 통과(rc 0)를 확인해야 그 다음 반례의
# 차단이 그 반례의 주입 때문임이 보장된다.
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "복원 직후에는 통과 — 이후 반례의 차단이 자기 주입 때문임을 보증"

# 반례 n — **NUL 종단** 주입 (Turn 008 F1)
# `[ -z "$(tail -c 1 f)" ]` 방식은 명령 치환이 NUL 을 버려 이것을 LF 종단으로 오인했다.
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\nevil.key=주입' > "rd-workflow-workspace/.lifecycle/task-state"
  printf '\000' >> "rd-workflow-workspace/.lifecycle/task-state"
  emit_current_task_baseline > CURRENT_TASK.md
  git add -A && git commit -q -m "NUL 종단으로 임의 키 주입"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "NUL 종단 임의 키 주입은 차단 (LF 종단으로 오인하지 않음)"

# 반례 o — **중간 NUL**. read 가 NUL 을 삼켜 행을 잃게 만드는 경로도 막는다.
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\n' > "rd-workflow-workspace/.lifecycle/task-state"
  printf '\000' >> "rd-workflow-workspace/.lifecycle/task-state"
  printf 'source-fr=-\nextensions.foo.bar=리뷰된 값\n' >> "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -q -m "중간 NUL 삽입"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "중간 NUL 이 든 task-state 는 차단"
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -qm "task-state 복구"
) >/dev/null 2>&1

# 복원 검증 — 복원이 불완전하면 이후 반례가 자기 주입이 아니라 남은 오염 때문에
# 차단되어 전부 엉뚱한 이유로 통과한다. 여기서 통과(rc 0)를 확인해야 그 다음 반례의
# 차단이 그 반례의 주입 때문임이 보장된다.
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "복원 직후에는 통과 — 이후 반례의 차단이 자기 주입 때문임을 보증"

# 반례 p — **owned 키 값 뒤 NUL 은닉** (조건 ②의 진짜 증인, Minor M2)
# 반례 o 는 NUL 이 행 선두라서 read 가 빈 키(owned 아님)를 남겨 우연히 cmp 불일치가
# 된다 — 조건 ② 를 빼도 다른 경로로 우연히 차단될 수 있어 충실한 증인이 아니다.
# 이 반례는 NUL 을 owned 키(status)의 **값 중간**에 심는다. read 는 NUL 을 조용히
# 삼키고 다음 개행까지 이어 붙이므로 "status=대기 중" 과 "evil.key=주입" 이 한 행으로
# 합쳐진다 — 그 행의 key 는 여전히 "status" (owned) 이므로 _archive_strip_owned 가
# evil.key 전체를 통째로 제거해 버려, strip 이후 비교만으로는 절대 잡히지 않는다.
# 마지막 바이트는 LF 이므로 종단 검사(조건 ③)도 통과한다 — 오직 조건 ②(NUL 포함
# 검사)만이 이 우회를 막는다.
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중' > "rd-workflow-workspace/.lifecycle/task-state"
  printf '\000' >> "rd-workflow-workspace/.lifecycle/task-state"
  printf 'evil.key=주입\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' >> "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -q -m "owned 키 값 뒤 NUL 은닉으로 임의 키 주입"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "owned 키 값 뒤 NUL 로 은닉한 임의 키 주입도 차단 (조건 ②의 진짜 증인)"
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -qm "task-state 복구"
) >/dev/null 2>&1

# 복원 검증 — 복원이 불완전하면 이후 반례가 자기 주입이 아니라 남은 오염 때문에
# 차단되어 전부 엉뚱한 이유로 통과한다. 여기서 통과(rc 0)를 확인해야 그 다음 반례의
# 차단이 그 반례의 주입 때문임이 보장된다.
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "복원 직후에는 통과 — 이후 반례의 차단이 자기 주입 때문임을 보증"

# 반례 q — **소유 키 "이름" 만 있고 `=` 가 없는 행** (다섯 번째 fail-open, final review Critical 1)
# `_archive_strip_owned` 가 `${line%%=*}` 를 `=` 유무 확인 없이 그대로 쓰면, `=` 가
# 없는 행에서는 **행 전체**가 key 가 된다. 그래서 "status"·"fr-branch" 처럼 소유 키
# "이름" 만 있고 값이 없는 행이 owned 목록의 해당 key 문자열과 우연히 일치해 필터가
# 조용히 버린다. 이 행이 baseline 에는 없고 발행 후보에만 있어도 양쪽 필터 결과가
# 같아져 cmp 가 일치 — L2 가 rc 0 을 낸다. 그 행은 `state_write_fields` 의 "나열하지
# 않은 행 보존" 계약 때문에 이후 실행에서도 지워지지 않고 영구히 남고,
# `_archive_regular_text` 의 세 조건(비어 있지 않음·NUL 없음·LF 종단)은 이것을 정규
# 텍스트로 보아 걸러내지 못한다.
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\nstatus\nfr-branch\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -qm "소유 키 이름만 있는 행(= 없음) 주입"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "소유 키 이름만 있는 행(= 없음) 주입도 차단 (다섯 번째 fail-open)"
(
  cd "$_pc_repo"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nextensions.foo.bar=리뷰된 값\n' > "rd-workflow-workspace/.lifecycle/task-state"
  git add -A && git commit -qm "task-state 복구"
) >/dev/null 2>&1

# 복원 검증 — 위와 동일한 이유로, 이 반례 뒤에도 통과를 재확인한다.
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "복원 직후에는 통과 — 반례 q 이후에도 자기 주입만이 차단 사유임을 보증"

# 반례 r — 같은 내용을 **실행 비트(100755)** 로 커밋 (final diff review F2)
# blob OID 는 그대로이므로 blob 비교만 하는 구현에서는 통과한다. git 은 같은 blob 을
# 다른 mode 로 참조할 수 있으므로 tree entry mode 를 따로 봐야 잡힌다.
# `update-index --cacheinfo` 로 같은 blob 을 다른 mode 로 심는다 — 파일시스템의
# 실행 비트·core.fileMode 설정에 의존하지 않는 결정적 주입이다.
(
  cd "$_pc_repo"
  _m_blob="$(git rev-parse "HEAD:CURRENT_TASK.md")"
  git update-index --add --cacheinfo "100755,$_m_blob,CURRENT_TASK.md"
  git commit -qm "CURRENT_TASK.md 를 실행 비트로 (내용 동일)"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "같은 내용의 실행 비트(100755) 커밋은 차단 (blob 비교만으로는 못 잡는 갈래)"
(
  cd "$_pc_repo"
  _m_blob="$(git rev-parse "HEAD:CURRENT_TASK.md")"
  git update-index --add --cacheinfo "100644,$_m_blob,CURRENT_TASK.md"
  git commit -qm "CURRENT_TASK.md mode 복구"
) >/dev/null 2>&1

# 반례 s — 같은 blob 을 **symlink(120000)** entry 로 커밋
# 내용 bytes 가 같아도 checkout 후에는 정규 파일이 아니라 링크가 되어, metadata 소비자가
# 파일을 잃거나 다른 경로를 따라간다. task-state 쪽 갈래에도 같은 검사가 있어야 한다.
(
  cd "$_pc_repo"
  _m_blob="$(git rev-parse "HEAD:rd-workflow-workspace/.lifecycle/task-state")"
  git update-index --add --cacheinfo "120000,$_m_blob,rd-workflow-workspace/.lifecycle/task-state"
  git commit -qm "task-state 를 symlink entry 로 (blob 동일)"
) >/dev/null 2>&1
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "같은 blob 의 symlink(120000) entry 는 차단 (type change)"
(
  cd "$_pc_repo"
  _m_blob="$(git rev-parse "HEAD:rd-workflow-workspace/.lifecycle/task-state")"
  git update-index --add --cacheinfo "100644,$_m_blob,rd-workflow-workspace/.lifecycle/task-state"
  git commit -qm "task-state mode 복구"
) >/dev/null 2>&1

# 복원 직후 통과 가드 — 이 단언이 없으면 위 두 차단이 "무엇이든 차단" 과 구별되지 않는다.
_rc=0; archive_publish_content_check "$_pc_repo" "$_pc_base" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "0" "mode 복원 직후에는 통과 — mode 검사가 정상 상태를 막지 않음"

# _archive_tree_entry_mode 단위 — 부재는 rc 1, git 실행 오류는 rc 2 (기존 rc 규약)
_mode_out="$(_archive_tree_entry_mode "$_pc_repo" HEAD "CURRENT_TASK.md")" && _rc=0 || _rc=$?
assert_eq "$_rc" "0" "_archive_tree_entry_mode: 존재하는 경로는 rc 0"
assert_eq "$_mode_out" "100644" "_archive_tree_entry_mode: 정규 파일 mode 를 돌려준다"
_rc=0; _archive_tree_entry_mode "$_pc_repo" HEAD "없는/경로" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "1" "_archive_tree_entry_mode: 부재는 rc 1 (실행 오류와 구분)"
_rc=0; _archive_tree_entry_mode "$_pc_repo" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "CURRENT_TASK.md" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "2" "_archive_tree_entry_mode: ls-tree 실행 오류는 rc 2 (통과로 소거하지 않음)"

# _archive_regular_text 단위 판정 — 9 케이스
_lf_t="$(mktemp)" || { echo "test_lifecycle.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$_lf_t" && -f "$_lf_t" ]] || { echo "test_lifecycle.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_ast_cleanup+=("$_lf_t")
_rt_case() {  # _rt_case <기대: pass|block> <설명>
  if _archive_regular_text "$_lf_t"; then
    [[ "$1" == "pass" ]] && assert_eq "0" "0" "$2" || assert_eq "0" "1" "$2"
  else
    [[ "$1" == "block" ]] && assert_eq "0" "0" "$2" || assert_eq "1" "0" "$2"
  fi
}
printf 'a=1\n' > "$_lf_t";                        _rt_case pass  "정상 LF 종단은 통과"
printf 'a=1\nevil=x' > "$_lf_t";                  _rt_case block "평문 비종단은 거부"
printf 'a=1\nevil=x' > "$_lf_t"; printf '\000' >> "$_lf_t"; _rt_case block "NUL 종단은 거부"
printf 'a=1\n' > "$_lf_t"; printf '\000' >> "$_lf_t"; printf 'b=2\n' >> "$_lf_t"; _rt_case block "중간 NUL 은 거부"
: > "$_lf_t";                                      _rt_case block "빈 파일은 거부"
printf 'a=1\n \n' > "$_lf_t";                     _rt_case pass  "공백 행 + LF 는 통과"
printf 'a=1\n\n' > "$_lf_t";                      _rt_case pass  "빈 줄 + LF 는 통과"
printf '키=값 한글\n' > "$_lf_t";                  _rt_case pass  "UTF-8 다바이트 + LF 는 통과"
printf 'a=1\r\n' > "$_lf_t";                      _rt_case pass  "CRLF 는 통과 (마지막 바이트가 LF)"

# git 오류 → rc 2
_rc=0; archive_publish_content_check "$_pc_repo" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$(git -C "$_pc_repo" rev-parse HEAD)" >/dev/null 2>&1 || _rc=$?
assert_eq "$_rc" "2" "존재하지 않는 기준선은 rc 2 git 오류"

echo "== archive.sh 검사 배선·순서 불변식 =="
_arch="$SCRIPT_DIR/archive.sh"
_ln() { grep -n "$1" "$_arch" 2>/dev/null | head -1 | cut -d: -f1; }

_l_merge="$(_ln 'MERGE_BASE_COMMIT=')"
_l_l1="$(_ln 'archive_extra_commits_check')"
_l_pub="$(_ln 'PUBLISH_OID=')"
_l_l2="$(_ln 'archive_publish_content_check')"
_l_tag="$(_ln 'git tag "\$TARGET_TAG"')"

for _v in _l_merge _l_l1 _l_pub _l_l2 _l_tag; do
  eval "_val=\$$_v"
  if [[ -n "$_val" ]]; then PASS=$((PASS+1)); echo "  PASS: $_v 지점 발견 ($_val)"
  else FAIL=$((FAIL+1)); echo "  FAIL: $_v 지점을 찾을 수 없음" >&2; fi
done

if [[ -n "$_l_merge" && -n "$_l_l1" && "$_l_merge" -lt "$_l_l1" ]]; then
  PASS=$((PASS+1)); echo "  PASS: L1 이 merge 판정 뒤"
else FAIL=$((FAIL+1)); echo "  FAIL: L1 이 merge 판정 뒤가 아님" >&2; fi

if [[ -n "$_l_pub" && -n "$_l_l2" && "$_l_pub" -lt "$_l_l2" ]]; then
  PASS=$((PASS+1)); echo "  PASS: PUBLISH_OID 캡처가 L2 앞"
else FAIL=$((FAIL+1)); echo "  FAIL: PUBLISH_OID 캡처가 L2 앞이 아님" >&2; fi

if [[ -n "$_l_l2" && -n "$_l_tag" && "$_l_l2" -lt "$_l_tag" ]]; then
  PASS=$((PASS+1)); echo "  PASS: L2 가 tag 생성 앞"
else FAIL=$((FAIL+1)); echo "  FAIL: L2 가 tag 앞이 아님" >&2; fi

# L3 결속 — tag 와 push 가 PUBLISH_OID 를 소비
if grep -q 'git tag "\$TARGET_TAG" "\$PUBLISH_OID"' "$_arch"; then
  PASS=$((PASS+1)); echo "  PASS: tag 가 PUBLISH_OID 를 명시 소비"
else FAIL=$((FAIL+1)); echo "  FAIL: tag 가 여전히 암묵 HEAD 를 가리킴" >&2; fi

if grep -q 'push origin "\${PUBLISH_OID}:refs/heads/' "$_arch"; then
  PASS=$((PASS+1)); echo "  PASS: 기본 브랜치 push 가 PUBLISH_OID 를 명시 소비"
else FAIL=$((FAIL+1)); echo "  FAIL: push 가 여전히 브랜치 tip 을 해석" >&2; fi

if grep -q 'push origin "\${TAG_OID}:refs/tags/' "$_arch"; then
  PASS=$((PASS+1)); echo "  PASS: tag push 가 캡처한 tag object OID 를 명시 소비"
else FAIL=$((FAIL+1)); echo "  FAIL: tag push 가 여전히 로컬 tag ref 이름을 재해석" >&2; fi

if grep -q 'TAG_COMMIT" == "\$PUBLISH_OID' "$_arch"; then
  PASS=$((PASS+1)); echo "  PASS: 캡처한 tag OID 의 peeled commit 을 PUBLISH_OID 와 재확인"
else FAIL=$((FAIL+1)); echo "  FAIL: tag OID 캡처 후 재확인이 없음" >&2; fi

if grep -q 'points-at "\$PUBLISH_OID"' "$_arch"; then
  PASS=$((PASS+1)); echo "  PASS: tag 재사용 판정이 PUBLISH_OID 기준"
else FAIL=$((FAIL+1)); echo "  FAIL: tag 재사용 판정이 HEAD 기준" >&2; fi

# 재결속(no-fr) 이 PUBLISH_OID 확정 뒤·tag 생성 앞에 있어야 의미가 있다 — tag 뒤로 밀리면
# 이미 발행된 뒤에 알리는 꼴이라 차단이 아니다. 소스 위치로 고정한다.
_l_rb="$(_ln 'archive_publish_rebind_check "')"
if [[ -n "$_l_rb" && -n "$_l_pub" && -n "$_l_tag" && "$_l_pub" -lt "$_l_rb" && "$_l_rb" -lt "$_l_tag" ]]; then
  PASS=$((PASS+1)); echo "  PASS: no-fr 재결속이 PUBLISH_OID 확정 뒤·tag 생성 앞"
else FAIL=$((FAIL+1)); echo "  FAIL: no-fr 재결속 위치 이상 — rebind=$_l_rb pub=$_l_pub tag=$_l_tag" >&2; fi

echo "== archive_block_notice 갈래(commit/unknown/content) =="
_abn_has() {  # _abn_has <haystack> <needle> — 0 = 포함
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}
_abn_out() { archive_block_notice "fr/abn-test" "/tmp/abn-root" "$1" 2>&1; }

_abn_commit="$(_abn_out commit)"
_abn_unknown="$(_abn_out unknown)"
_abn_content="$(_abn_out content)"

# 공통 요건 — 세 갈래 모두 첫 줄·보존 문구·merge/metadata 잔존 안내·fr ref·상태 확인 명령을 낸다
for _abn_pair_kind in commit unknown content; do
  case "$_abn_pair_kind" in
    commit) _abn_out_val="$_abn_commit" ;;
    unknown) _abn_out_val="$_abn_unknown" ;;
    content) _abn_out_val="$_abn_content" ;;
  esac
  if _abn_has "$_abn_out_val" "tag 와 push 를 실행하지 않았습니다"; then
    PASS=$((PASS+1)); echo "  PASS: $_abn_pair_kind — 발행 안 함 고지"
  else FAIL=$((FAIL+1)); echo "  FAIL: $_abn_pair_kind — 발행 안 함 고지 누락" >&2; fi
  if _abn_has "$_abn_out_val" "그대로 보존"; then
    PASS=$((PASS+1)); echo "  PASS: $_abn_pair_kind — 보존 문구"
  else FAIL=$((FAIL+1)); echo "  FAIL: $_abn_pair_kind — 보존 문구 누락" >&2; fi
  if _abn_has "$_abn_out_val" "merge·metadata 커밋은 이력에 남아 있을 수 있습니다"; then
    PASS=$((PASS+1)); echo "  PASS: $_abn_pair_kind — merge/metadata 잔존 고지"
  else FAIL=$((FAIL+1)); echo "  FAIL: $_abn_pair_kind — merge/metadata 잔존 고지 누락" >&2; fi
  if _abn_has "$_abn_out_val" "fr 브랜치: fr/abn-test"; then
    PASS=$((PASS+1)); echo "  PASS: $_abn_pair_kind — fr ref 명시"
  else FAIL=$((FAIL+1)); echo "  FAIL: $_abn_pair_kind — fr ref 누락" >&2; fi
  if _abn_has "$_abn_out_val" "현재 상태 확인:"; then
    PASS=$((PASS+1)); echo "  PASS: $_abn_pair_kind — 상태 확인 명령"
  else FAIL=$((FAIL+1)); echo "  FAIL: $_abn_pair_kind — 상태 확인 명령 누락" >&2; fi
done

# unknown 전용 — 판정 불능 고지
if _abn_has "$_abn_unknown" "무엇이 얹혔는지 판정할 수 없었습니다"; then
  PASS=$((PASS+1)); echo "  PASS: unknown — 판정 불능 고지"
else FAIL=$((FAIL+1)); echo "  FAIL: unknown — 판정 불능 고지 누락" >&2; fi

# unknown 전용 — "위에 보고된 변경" 자기모순 제거 (final review Minor M2).
# 판정 자체가 불가능한 갈래에는 특정할 수 있는 "보고된 변경" 이 없으므로 보존·복구
# 절차 문구가 그 존재를 전제해서는 안 된다. commit·content 는 특정 대상이 있으므로
# 계속 전제해도 된다 — unknown 에서만 없어야 함을 확인한다.
if ! _abn_has "$_abn_unknown" "위에 보고된 변경"; then
  PASS=$((PASS+1)); echo "  PASS: unknown — '위에 보고된 변경' 자기모순 문구 없음"
else FAIL=$((FAIL+1)); echo "  FAIL: unknown — 존재를 전제하는 문구가 남아 있음" >&2; fi
if _abn_has "$_abn_commit" "위에 보고된 변경"; then
  PASS=$((PASS+1)); echo "  PASS: commit — 특정 변경을 전제하는 문구 유지"
else FAIL=$((FAIL+1)); echo "  FAIL: commit — 변경 특정 문구가 사라짐" >&2; fi

# commit·unknown 전용 — "기본 브랜치를 merge 이전으로 되돌리고" 복구 절차
if _abn_has "$_abn_commit" "기본 브랜치를 merge 이전으로 되돌리고"; then
  PASS=$((PASS+1)); echo "  PASS: commit — 기본 브랜치 되돌리기 절차"
else FAIL=$((FAIL+1)); echo "  FAIL: commit — 기본 브랜치 되돌리기 절차 누락" >&2; fi
if _abn_has "$_abn_unknown" "기본 브랜치를 merge 이전으로 되돌리고"; then
  PASS=$((PASS+1)); echo "  PASS: unknown — 기본 브랜치 되돌리기 절차"
else FAIL=$((FAIL+1)); echo "  FAIL: unknown — 기본 브랜치 되돌리기 절차 누락" >&2; fi

# content 전용 — 기본 브랜치를 되돌리라는 절차가 **없어야** 하고, baseline 복원 + 사전 확인 절차가 있어야 함
if ! _abn_has "$_abn_content" "기본 브랜치를 merge 이전으로 되돌리고"; then
  PASS=$((PASS+1)); echo "  PASS: content — 기본 브랜치 되돌리기 절차 없음 (Task 5 리뷰 조치 2)"
else FAIL=$((FAIL+1)); echo "  FAIL: content — 기본 브랜치 되돌리기 절차가 여전히 나옴" >&2; fi
if _abn_has "$_abn_content" "baseline 상태로 되돌리고"; then
  PASS=$((PASS+1)); echo "  PASS: content — baseline 복원 절차"
else FAIL=$((FAIL+1)); echo "  FAIL: content — baseline 복원 절차 누락" >&2; fi
if _abn_has "$_abn_content" "리뷰가 필요한 변경인지"; then
  PASS=$((PASS+1)); echo "  PASS: content — 되돌리기 전 리뷰 필요성 확인 요구"
else FAIL=$((FAIL+1)); echo "  FAIL: content — 되돌리기 전 리뷰 필요성 확인 요구 누락" >&2; fi

echo "== slug normalization =="
assert_eq "$(normalize_slug 'Foo Bar')" "foo-bar" "공백 + 대문자"
assert_eq "$(normalize_slug 'foo  bar')" "foo-bar" "다중 공백 압축"
assert_eq "$(normalize_slug 'foo_bar')" "foo-bar" "underscore 치환"
assert_eq "$(normalize_slug 'foo.bar')" "foo-bar" "dot 치환"
assert_eq "$(normalize_slug '--foo--')" "foo" "양끝 trim"
assert_eq "$(normalize_slug 'foo--bar')" "foo-bar" "연속 dash 압축"
assert_err "한글" "비-ASCII 거부"
assert_err "foo!bar" "특수문자 거부"
assert_err "" "빈 문자열 거부"
assert_err "   " "공백만 거부"
assert_err "$(printf 'x%.0s' {1..61})" "61자 거부"


# === Task 2: _lifecycle_common.sh fixtures ===
source "$SCRIPT_DIR/_lifecycle_common.sh"

echo "== git state helpers =="
assert_in_set() {
  local got="$1" set="$2" desc="$3"
  if [[ ",$set," == *",$got,"* ]]; then PASS=$((PASS+1)); echo "  PASS: $desc";
  else FAIL=$((FAIL+1)); echo "  FAIL: $desc — got=[$got]" >&2; fi
}

assert_in_set "$(detect_remote_mode)" "remote,local-only" "detect_remote_mode 반환값"
ensure_worktree_clean >/dev/null 2>&1 && rc=0 || rc=$?
assert_in_set "$rc" "0,1" "ensure_worktree_clean exit code"

echo "== metadata I/O =="
TMPDIR_TEST="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
_ast_cleanup+=("$TMPDIR_TEST")   # 최상위 EXIT trap 은 `_suite_on_exit` 하나뿐입니다 (상단 주석)
# v2 2b: task-state 경로로 격리 (LIFECYCLE_METADATA_PATH 폐지 — TASK_STATE_PATH 사용)
TASK_STATE_PATH="$TMPDIR_TEST/task-state"
if metadata_exists; then FAIL=$((FAIL+1)); echo "  FAIL: empty metadata 인데 exists 반환" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: metadata 부재 (fr-branch=null 또는 파일 없음)"; fi
metadata_write "fr/foo" "foo" "/path"
if metadata_exists; then PASS=$((PASS+1)); echo "  PASS: write 후 exists (fr-branch=fr/foo)"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: metadata write 실패 — fr-branch 값 없음" >&2; fi
assert_eq "$(metadata_read_field fr-branch)" "fr/foo" "metadata_read fr-branch"
assert_eq "$(metadata_read_field short-title)" "foo" "metadata_read short-title"
assert_eq "$(metadata_read_field worktree-path)" "/path" "metadata_read worktree-path"
# created-at 존재 확인 (write 후 생성)
if grep -q "^created-at=" "$TASK_STATE_PATH" 2>/dev/null; then PASS=$((PASS+1)); echo "  PASS: write 후 created-at 존재"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: created-at 누락" >&2; fi
metadata_clear
# clear 후: fr-branch=null, worktree-path=null, created-at 제거
assert_eq "$(metadata_read_field fr-branch)" "null" "metadata_clear 후 fr-branch=null"
assert_eq "$(metadata_read_field worktree-path)" "null" "metadata_clear 후 worktree-path=null"

echo "== source-fr metadata (promote-source-fr-sync) =="
SRC_T3="rd-workflow-workspace/backlog/items/2026-01-01-baz.md"
metadata_write "fr/bar" "bar" "/path"
assert_eq "$(metadata_read_field source-fr)" "-" "3인자 metadata_write → source-fr=- 기본 (하위 호환)"
metadata_write "fr/baz" "baz" "/path" "$SRC_T3"
assert_eq "$(metadata_read_field source-fr)" "$SRC_T3" "4인자 metadata_write → source-fr 기록"
metadata_clear
assert_eq "$(metadata_read_field source-fr)" "-" "metadata_clear → source-fr=-"

echo "== promote.sh source-fr 결정 (fixture repo) =="
# 아래 호출은 저장소의 promote.sh 를 절대 경로로 실행하므로 project_root 를 fixture 로
# 주입한다. promote 는 이제 기준 위치를 cwd 가 아니라 스크립트 배치에서 산출하므로
# (change spec D7), 주입하지 않으면 fixture 안에서 부른 호출이 실제 작업공간의
# task-state·CURRENT_TASK 를 대상으로 삼는다. 주입값 우선은 promote 가 보장하는 계약이다.
# mk_promote_fixture <dir> <request-source-fr-라인>  ("__NONE__" 이면 Source FR 섹션 없음)
mk_promote_fixture() {
  local dir="$1" src_line="$2"
  mkdir -p "$dir"
  ( cd "$dir" \
    && { git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }; } \
    && git config user.email "t@t" && git config user.name "t" \
    && mkdir -p rd-workflow-workspace/backlog/items \
    && printf '%s\n' "# Current Task" "" "## Short Title" "-" "" "## Status" "대기 중" "" "## Branch / Worktree" "-" > CURRENT_TASK.md \
    && if [[ "$src_line" == "__NONE__" ]]; then
         printf '%s\n' "# Change Request" "" "## Task Type" "change" > REQUEST.md
       else
         printf '%s\n' "# Change Request" "" "## Source FR" "$src_line" > REQUEST.md
       fi \
    && touch "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" \
    && git add -A && git commit -qm init )
}
read_fix_source_fr() { # read_fix_source_fr <dir> [slug]
  # Task 4 재설계 — --no-worktree 작업은 이제 task-state 를 fr 브랜치에만 커밋한다
  # (기본 브랜치에는 무커밋). 실패 경로가 main 으로 되돌아간 채 끝나면(예: 인자
  # 검증 실패로 promote 가 fr 브랜치로 switch 하기 전에 종료) 워킹트리에는 그
  # 값이 보이지 않는다 — 워킹트리에 없으면 fr/<slug> blob 에서 읽는다.
  local f="$1/rd-workflow-workspace/.lifecycle/task-state"
  if [[ -f "$f" ]]; then
    awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,"");print;exit}' "$f"
    return 0
  fi
  local br
  if [[ -n "${2:-}" ]]; then
    # 대상을 명시한다 — fr 브랜치가 둘 이상인 fixture 에서 최근 발견 순서에 기대지
    # 않는다(2026-09 final diff review C4 참고 지적).
    br="fr/${2}"
    git -C "$1" rev-parse --verify --quiet "refs/heads/${br}" >/dev/null 2>&1 || return 0
  else
    br="$(git -C "$1" for-each-ref --format='%(refname:short)' 'refs/heads/fr/*' 2>/dev/null | head -1)"
    [[ -n "$br" ]] || return 0
  fi
  git -C "$1" show "${br}:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null \
    | awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,"");print;exit}'
}

FIX1="$TMPDIR_TEST/fix-infer"
mk_promote_fixture "$FIX1" '`rd-workflow-workspace/backlog/items/2026-01-01-fix.md`'
_fix1_out="$( cd "$FIX1" && project_root="$FIX1" bash "$SCRIPT_DIR/promote.sh" --short-title fix-infer --size small --no-worktree 2>&1 )"
assert_eq "$(read_fix_source_fr "$FIX1" fix-infer)" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: REQUEST 백틱 path 추론 기록"
assert_eq "$(printf '%s' "$_fix1_out" | grep -c '다음 기동에 사용할 모델')" "1" "promote: 새 기동 시 모델 표시 줄이 정확히 한 번 나온다"

FIX2="$TMPDIR_TEST/fix-none"
mk_promote_fixture "$FIX2" "-"
( cd "$FIX2" && project_root="$FIX2" bash "$SCRIPT_DIR/promote.sh" --short-title fix-none --size small --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX2" fix-none)" "-" "promote: REQUEST '-' → source-fr=-"

FIX3="$TMPDIR_TEST/fix-arg"
mk_promote_fixture "$FIX3" "-"
( cd "$FIX3" && project_root="$FIX3" bash "$SCRIPT_DIR/promote.sh" --short-title fix-arg --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX3" fix-arg)" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: --source-fr 명시 인자 기록"

FIX4="$TMPDIR_TEST/fix-slug"
mk_promote_fixture "$FIX4" "2026-01-01-fix"
( cd "$FIX4" && project_root="$FIX4" bash "$SCRIPT_DIR/promote.sh" --short-title fix-slug --size small --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX4" fix-slug)" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: legacy slug 추론 → path 정규화 (실존)"

FIX5="$TMPDIR_TEST/fix-badslug"
mk_promote_fixture "$FIX5" "no-such-item"
rc5=0
( cd "$FIX5" && project_root="$FIX5" bash "$SCRIPT_DIR/promote.sh" --short-title fix-badslug --size small --no-worktree >/dev/null 2>&1 ) || rc5=$?
assert_eq "$rc5" "1" "promote: 해석 실패(no-such-item) → hard error exit 1"
if [[ -f "$FIX5/rd-workflow-workspace/.lifecycle/task-state" ]]; then
  FAIL=$((FAIL+1)); echo "  FAIL: promote: 해석 실패인데 task-state 생성됨" >&2
else PASS=$((PASS+1)); echo "  PASS: promote: 해석 실패 시 task-state 미생성 (상태 무변경)"; fi
if ( cd "$FIX5" && git rev-parse --verify fr/fix-badslug >/dev/null 2>&1 ); then
  FAIL=$((FAIL+1)); echo "  FAIL: promote: 해석 실패인데 fr 브랜치 생성됨" >&2
else PASS=$((PASS+1)); echo "  PASS: promote: 해석 실패 시 fr 브랜치 미생성"; fi

FIX6="$TMPDIR_TEST/fix-badarg"
mk_promote_fixture "$FIX6" "-"
rc6=0
( cd "$FIX6" && project_root="$FIX6" bash "$SCRIPT_DIR/promote.sh" --short-title fix-badarg --size small --no-worktree \
    --source-fr "/abs/evil.md" >/dev/null 2>&1 ) || rc6=$?
assert_eq "$rc6" "1" "promote: --source-fr 무효값 hard error exit 1"

# dry-run 무변경 계약: idempotent rerun + --dry-run --source-fr 에서도 상태 불변
FIX7="$TMPDIR_TEST/fix-dryrun"
mk_promote_fixture "$FIX7" '`rd-workflow-workspace/backlog/items/2026-01-01-fix.md`'
( cd "$FIX7" && project_root="$FIX7" bash "$SCRIPT_DIR/promote.sh" --short-title fix-dryrun --size small --no-worktree >/dev/null 2>&1 )
( cd "$FIX7" && git checkout -q main 2>/dev/null || true )
( cd "$FIX7" && project_root="$FIX7" bash "$SCRIPT_DIR/promote.sh" --short-title fix-dryrun --size small --no-worktree --dry-run \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-other.md" >/dev/null 2>&1 || true )
assert_eq "$(read_fix_source_fr "$FIX7" fix-dryrun)" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: --dry-run 은 source-fr 를 변경하지 않음 (idempotent rerun)"

# non-dry idempotent rerun: 동일 값 인자 = no-op 허용 (exit 0), dirty task-state 없음
# Step A(기본 브랜치 worktree 검증) 전제 충족을 위해 첫 promote 후 main 으로 checkout (FIX7과 동일 패턴)
FIX8="$TMPDIR_TEST/fix-rerun-same"
mk_promote_fixture "$FIX8" "-"
( cd "$FIX8" && project_root="$FIX8" bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-same --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
( cd "$FIX8" && git checkout -q main 2>/dev/null || true )
rc8=0
( cd "$FIX8" && project_root="$FIX8" bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-same --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 ) || rc8=$?
assert_eq "$rc8" "0" "promote rerun: 동일 --source-fr no-op 허용 (exit 0)"
assert_eq "$(read_fix_source_fr "$FIX8" fix-rerun-same)" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote rerun: 동일 값 유지"
assert_eq "$(cd "$FIX8" && git status --porcelain | grep -c "task-state" || true)" "0" "promote rerun: task-state dirty 없음 (동일 값)"

# non-dry idempotent rerun: 다른 값 인자 = exit 1 거부 + 값 불변 + dirty 없음 (정정은 set-source-fr 일원화)
FIX9="$TMPDIR_TEST/fix-rerun-diff"
mk_promote_fixture "$FIX9" "-"
# Task 4 재설계(C3) — 이 두 번째 --source-fr 는 **실재하는** 파일이어야 한다. 실재하지
# 않으면 promote 가 인자 파싱 단계(source_fr_check_direct_arg 의 실존 검사)에서
# 먼저 죽어, "rerun 이 다른 source-fr 를 거부한다" 는 resume 경로의 권위 검증(C2)을
# 전혀 태우지 못한 채로 rc9==1 이 우연히 통과하는 공백 테스트가 된다.
touch "$FIX9/rd-workflow-workspace/backlog/items/2026-02-02-other.md"
( cd "$FIX9" && git add -A && git commit -qm "second item" )
( cd "$FIX9" && project_root="$FIX9" bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-diff --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
( cd "$FIX9" && git checkout -q main 2>/dev/null || true )
rc9=0
FIX9_ERR="$TMPDIR_TEST/fix-rerun-diff.err"
( cd "$FIX9" && project_root="$FIX9" bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-diff --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-02-02-other.md" >/dev/null 2>"$FIX9_ERR" ) || rc9=$?
assert_eq "$rc9" "1" "promote rerun: 다른 --source-fr 거부 (exit 1)"
if grep -q "이미 초기화된 작업" "$FIX9_ERR"; then
  PASS=$((PASS+1)); echo "  PASS: promote rerun: 거부 사유가 source-fr 불일치(resume 권위 검증, C2)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: promote rerun: 거부 사유가 source-fr 불일치가 아님(공백 테스트 재발 의심)" >&2
  echo "    --- stderr ---" >&2; sed 's/^/    /' "$FIX9_ERR" >&2
fi
assert_eq "$(read_fix_source_fr "$FIX9" fix-rerun-diff)" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote rerun: 거부 후 값 불변"
assert_eq "$(cd "$FIX9" && git status --porcelain | grep -c "task-state" || true)" "0" "promote rerun: task-state dirty 없음 (거부)"

# === 미러 초기화: 이전 작업 잔여 제거 (AC4) ===
FIX10="$TMPDIR_TEST/fix-mirror-reset"
mk_promote_fixture "$FIX10" "-"
# 직전 작업 잔여를 재현한다 — baseline 에 없는 서술이 Task·Next Step 에 들어 있는 상태
printf '%s\n' \
  "# Current Task" "" \
  "## Task" "이전 작업 설명 — 남아 있으면 안 된다" "" \
  "## Short Title" "old-task" "" \
  "## Status" "완료" "" \
  "## Spec" "specs/changes/old-spec.md" "" \
  "## Branch / Worktree" "-" "" \
  "## Next Step" "이전 작업의 다음 단계 — 남아 있으면 안 된다" "" \
  "## Notes" "이전 작업 메모" > "$FIX10/CURRENT_TASK.md"
( cd "$FIX10" && git add -A && git commit -qm "stale mirror" )
( cd "$FIX10" && project_root="$FIX10" bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-reset --size small --no-worktree >/dev/null 2>&1 )
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "-" "promote 초기화: Task 가 baseline 으로 리셋"
assert_eq "$(awk '$0=="## Next Step"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "-" "promote 초기화: Next Step 이 baseline 으로 리셋"
assert_eq "$(awk '$0=="## Spec"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "-" "promote 초기화: Spec 이 baseline 으로 리셋"
assert_eq "$(awk '$0=="## Short Title"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "fix-mirror-reset" "promote 초기화: Short Title 은 승격 값"
assert_eq "$(awk '$0=="## Status"{getline; print; exit}' "$FIX10/CURRENT_TASK.md")" "구현 중" "promote 초기화: Status 는 승격 값"
assert_eq "$(cd "$FIX10" && ls CURRENT_TASK.md.baseline.* 2>/dev/null | wc -l | tr -d ' ')" "0" "promote 초기화: 임시 파일 정리됨"

# === 미러 보존: 같은 slug 재실행 (AC5) ===
FIX11="$TMPDIR_TEST/fix-mirror-keep"
mk_promote_fixture "$FIX11" "-"
( cd "$FIX11" && project_root="$FIX11" bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-keep --size small --no-worktree >/dev/null 2>&1 )
# 승격 후 사용자가 작업 설명을 적었다고 가정한다
( cd "$FIX11" && awk '$0=="## Task"{print; getline; print "작업 중 적어 둔 설명"; next} {print}' CURRENT_TASK.md > .ct.tmp && mv .ct.tmp CURRENT_TASK.md )
( cd "$FIX11" && git add -A && git commit -qm "author note" )
( cd "$FIX11" && git checkout -q main 2>/dev/null || true )
( cd "$FIX11" && project_root="$FIX11" bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-keep --size small --no-worktree >/dev/null 2>&1 )
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX11/CURRENT_TASK.md")" "작업 중 적어 둔 설명" "promote 보존: 같은 slug 재실행 시 작성 내용 유지"

# === worktree 승격: 대상 worktree 만 초기화 (AC4 경로 변형) ===
# TASK_FILE 은 ${TARGET_WT_PATH:-.}/CURRENT_TASK.md 이므로 기본 worktree 의 미러는 불변이어야 한다.
FIX12="$TMPDIR_TEST/fix-mirror-wt"
mk_promote_fixture "$FIX12" "-"
printf '%s\n' \
  "# Current Task" "" \
  "## Task" "기본 worktree 내용 — 유지되어야 한다" "" \
  "## Short Title" "old-wt-task" "" \
  "## Status" "완료" "" \
  "## Branch / Worktree" "-" > "$FIX12/CURRENT_TASK.md"
( cd "$FIX12" && git add -A && git commit -qm "base mirror" )
FIX12_WT="$TMPDIR_TEST/fix-mirror-wt-tree"
( cd "$FIX12" && project_root="$FIX12" bash "$SCRIPT_DIR/promote.sh" --short-title fix-mirror-wt --size small --worktree-path "$FIX12_WT" >/dev/null 2>&1 )
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX12_WT/CURRENT_TASK.md")" "-" "promote worktree: 대상 worktree 미러가 초기화됨"
assert_eq "$(awk '$0=="## Short Title"{getline; print; exit}' "$FIX12_WT/CURRENT_TASK.md")" "fix-mirror-wt" "promote worktree: 대상 worktree Short Title 이 승격 값"
assert_eq "$(awk '$0=="## Task"{getline; print; exit}' "$FIX12/CURRENT_TASK.md")" "기본 worktree 내용 — 유지되어야 한다" "promote worktree: 기본 worktree 미러는 불변"

# === 복수 source-fr (task-guard-source-fr-contract T3) ===
# 미러 '## Source FR' 섹션 본문(줄 단위 목록)을 읽는다 — 헤더 다음부터 다음 '## ' 헤더
# 또는 EOF 까지의 비어있지 않은 줄 전부.
read_fix_mirror_sfr() { # read_fix_mirror_sfr <CURRENT_TASK.md path>
  awk '$0=="## Source FR"{f=1; next} f && /^## /{exit} f && NF{print}' "$1"
}

# --- 복수 승격: task-state 직렬화 1줄 · 미러 줄 단위 목록 ---
FIX13="$TMPDIR_TEST/fix-multi"
mk_promote_fixture "$FIX13" "-"
touch "$FIX13/rd-workflow-workspace/backlog/items/2026-01-01-second.md"
( cd "$FIX13" && git add -A && git commit -qm "second item" )
( cd "$FIX13" && project_root="$FIX13" bash "$SCRIPT_DIR/promote.sh" --short-title fix-multi --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-second.md" >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX13" fix-multi)" \
  "rd-workflow-workspace/backlog/items/2026-01-01-fix.md|rd-workflow-workspace/backlog/items/2026-01-01-second.md" \
  "promote: 복수 --source-fr → task-state 직렬화 1줄('|' 구분)"
assert_eq "$(read_fix_mirror_sfr "$FIX13/CURRENT_TASK.md")" \
  "$(printf '%s\n%s' "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "rd-workflow-workspace/backlog/items/2026-01-01-second.md")" \
  "promote: 복수 --source-fr → 미러는 줄 단위 목록 (저장 형식 '|' 미노출)"

# --- 순서만 다른 rerun → 성공 (거짓 거부 없음) ---
( cd "$FIX13" && git checkout -q main 2>/dev/null || true )
rc13=0
( cd "$FIX13" && project_root="$FIX13" bash "$SCRIPT_DIR/promote.sh" --short-title fix-multi --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-second.md" \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 ) || rc13=$?
assert_eq "$rc13" "0" "promote rerun: 순서만 다른 --source-fr 는 집합 비교로 성공"
assert_eq "$(read_fix_source_fr "$FIX13" fix-multi)" \
  "rd-workflow-workspace/backlog/items/2026-01-01-fix.md|rd-workflow-workspace/backlog/items/2026-01-01-second.md" \
  "promote rerun: 순서만 다른 값 재지정은 no-op (저장값 불변)"

# --- 손상된 대상 worktree task-state 의 복구 안내가 목록 전체를 담는가 ---
# ('실행하고 그대로 검증' 은 rd task set-source-fr 의 복수 positional 지원(T2, 동시
#  진행 중)에 의존하므로, 이 fixture 는 promote 자체가 만드는 **안내 문구**가 모든 FR을
#  담는지만 검증한다 — T2·T3 어느 한쪽만 끝난 상태에서도 T3 자체 결함을 놓치지 않는다.)
FIX14="$TMPDIR_TEST/fix-divergence-multi"
mk_promote_fixture "$FIX14" "-"
touch "$FIX14/rd-workflow-workspace/backlog/items/2026-01-01-second.md"
( cd "$FIX14" && git add -A && git commit -qm "second item" )
FIX14_WT="$TMPDIR_TEST/fix-divergence-multi-wt"
( cd "$FIX14" && project_root="$FIX14" bash "$SCRIPT_DIR/promote.sh" --short-title fix-divmulti --size small \
    --worktree-path "$FIX14_WT" \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-second.md" >/dev/null 2>&1 )
rm -f "$FIX14_WT/rd-workflow-workspace/.lifecycle/task-state"
( cd "$FIX14" && git checkout -q main 2>/dev/null || true )
FIX14_ERR="$TMPDIR_TEST/fix-divergence-multi.err"
rc14=0
( cd "$FIX14" && project_root="$FIX14" bash "$SCRIPT_DIR/promote.sh" --short-title fix-divmulti --size small \
    --worktree-path "$FIX14_WT" >/dev/null 2>"$FIX14_ERR" ) || rc14=$?
assert_eq "$rc14" "1" "promote: 대상 worktree task-state 손상 시 exit 1"
# Task 4 재설계 — 이 값 divergence 는 이제 D11 판정 a(워킹트리가 committed 와 다름 —
# 증명 불가)로 흡수된다. 종전에는 promote 가 committed vs 미러 source-fr 를 직접
# 비교해 두 FR 을 모두 담은 positional 복구 명령을 냈지만, 그 비교 로직 자체가 이
# 재설계로 없어졌다.
#
# 이 fixture 는 **파일을 지운(rm -f)** 상태다 — 판정 a 는 삭제와 수정을 구분해
# 안내한다(2026-09 final diff review C4). 이 시나리오에 "커밋한 뒤 재실행하십시오"
# 를 그대로 따르면(git add -A && git commit) **삭제가 그대로 커밋되어 task-state 가
# 영구 유실**된다 — 맞는 복구 명령은 `git checkout -- <path>` 다. 그래서 assert 는
# 느슨한 "커밋" 포함 여부가 아니라 이 시나리오 전용 명령 문자열을 구체적으로 본다
# (느슨한 assert 는 그 오류를 통과시켜 회귀를 가린다).
if grep -q "git checkout -- rd-workflow-workspace/.lifecycle/task-state" "$FIX14_ERR"; then
  PASS=$((PASS+1)); echo "  PASS: promote: 삭제 시나리오(D11-a)는 git checkout -- 를 안내함(커밋 유도로 인한 영구 유실 방지)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: promote: 삭제 시나리오인데 git checkout -- 안내가 없음(삭제를 커밋하라고 유도할 위험)" >&2
  echo "    --- stderr ---" >&2; sed 's/^/    /' "$FIX14_ERR" >&2
fi

# --- '|' 포함 canonical 경로 1건 재지정 → 성공 (단일 값 쓰기 경로 회귀 방지) ---
# source_fr_split 의 fast-path(실존 파일이면 원소 1개로 확정)가 promote 자체의
# idempotent 비교·미러 검증에서도 지켜지는지 — 순진하게 '|' 로 나누면 이 파일 하나가
# 두 항목으로 찢어져 거짓 divergence 가 된다.
FIX15="$TMPDIR_TEST/fix-pipe-path"
mk_promote_fixture "$FIX15" "-"
mkdir -p "$FIX15/rd-workflow-workspace/backlog/items"
touch "$FIX15/rd-workflow-workspace/backlog/items/2026-01-01-a|b.md"
( cd "$FIX15" && git add -A && git commit -qm "pipe-named item" )
( cd "$FIX15" && project_root="$FIX15" bash "$SCRIPT_DIR/promote.sh" --short-title fix-pipe-path --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-a|b.md" >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX15" fix-pipe-path)" "rd-workflow-workspace/backlog/items/2026-01-01-a|b.md" \
  "promote: '|' 포함 canonical 경로 단일값 기록 (분리 없음)"
assert_eq "$(read_fix_mirror_sfr "$FIX15/CURRENT_TASK.md")" "rd-workflow-workspace/backlog/items/2026-01-01-a|b.md" \
  "promote: '|' 포함 경로 미러도 한 줄"
( cd "$FIX15" && git checkout -q main 2>/dev/null || true )
rc15=0
( cd "$FIX15" && project_root="$FIX15" bash "$SCRIPT_DIR/promote.sh" --short-title fix-pipe-path --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-a|b.md" >/dev/null 2>&1 ) || rc15=$?
assert_eq "$rc15" "0" "promote rerun: '|' 포함 단일값 재지정은 성공 (오분리로 인한 거짓 divergence 없음)"

if grep -q "^created-at=" "$TASK_STATE_PATH" 2>/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: clear 후 created-at 잔존" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: clear 후 created-at 제거"; fi
if metadata_exists; then FAIL=$((FAIL+1)); echo "  FAIL: clear 후에도 metadata_exists true" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: metadata_exists false (fr-branch=null)"; fi

# --- legacy active-fr fallback (수정 2: metadata_read_field legacy fallback) ---
echo "== legacy active-fr fallback =="
LEGACY_AFR_DIR="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle"
mkdir -p "$LEGACY_AFR_DIR"
printf 'fr-branch=fr/legacy-test\nshort-title=legacy-task\nworktree-path=/tmp/legacy\n' > "$LEGACY_AFR_DIR/active-fr"
# task-state 없는 상태 + project_root 격리
(
  set +e
  export project_root="$TMPDIR_TEST/legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle/task-state"
  rm -f "$TASK_STATE_PATH"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  got="$(metadata_read_field fr-branch)"
  if [[ "$got" == "fr/legacy-test" ]]; then
    echo "  PASS: task-state 부재 + active-fr → fr-branch=fr/legacy-test"
    exit 0
  else
    echo "  FAIL: task-state 부재 legacy fallback — got=[$got] want=[fr/legacy-test]" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# task-state 존재 시 legacy active-fr 무시 확인
(
  set +e
  export project_root="$TMPDIR_TEST/legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle/task-state2"
  mkdir -p "$(dirname "$TASK_STATE_PATH")"
  printf 'schema=1\nfr-branch=fr/real-state\nshort-title=real\nstatus=구현 중\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
  # active-fr도 존재 (무시 대상)
  printf 'fr-branch=fr/legacy-test\nshort-title=legacy-task\n' > "$LEGACY_AFR_DIR/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  got="$(metadata_read_field fr-branch)"
  if [[ "$got" == "fr/real-state" ]]; then
    echo "  PASS: task-state 존재 시 active-fr 무시 → fr-branch=fr/real-state"
    exit 0
  else
    echo "  FAIL: task-state 존재 시 legacy 값이 노출됨 — got=[$got] want=[fr/real-state]" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# metadata_clear — legacy active-fr 삭제 확인 (수정 3)
(
  set +e
  export project_root="$TMPDIR_TEST/legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/legacy-root/rd-workflow-workspace/.lifecycle/task-state3"
  mkdir -p "$(dirname "$TASK_STATE_PATH")"
  printf 'schema=1\nfr-branch=fr/to-clear\nshort-title=clr\nstatus=구현 중\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
  printf 'fr-branch=fr/to-clear\nshort-title=clr\n' > "$LEGACY_AFR_DIR/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  metadata_clear
  if [[ ! -f "$LEGACY_AFR_DIR/active-fr" ]]; then
    echo "  PASS: metadata_clear → legacy active-fr 삭제됨"
    exit 0
  else
    echo "  FAIL: metadata_clear 후 active-fr 잔존" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# metadata_exists — legacy fallback 회귀 테스트
# metadata_exists가 metadata_read_field 경유로 legacy fallback을 공유하는지 검증
echo "== metadata_exists legacy fallback =="
# Case 1: task-state 부재 + active-fr(fr-branch=fr/x) → metadata_exists return 0 (참)
(
  set +e
  export project_root="$TMPDIR_TEST/exists-legacy-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/exists-legacy-root/rd-workflow-workspace/.lifecycle/task-state"
  local_afr="$TMPDIR_TEST/exists-legacy-root/rd-workflow-workspace/.lifecycle"
  mkdir -p "$local_afr"
  rm -f "$TASK_STATE_PATH"
  printf 'fr-branch=fr/x\nshort-title=legacy-x\n' > "$local_afr/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  if metadata_exists; then
    echo "  PASS: task-state 부재 + active-fr(fr/x) → metadata_exists true"
    exit 0
  else
    echo "  FAIL: task-state 부재 + active-fr(fr/x) → metadata_exists false (legacy fallback 미적용)" >&2
    exit 1
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# Case 2: task-state 존재(fr-branch=null) + active-fr 잔존(fr-branch=fr/x) → metadata_exists return 1 (task-state 우선)
(
  set +e
  export project_root="$TMPDIR_TEST/exists-ts-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/exists-ts-root/rd-workflow-workspace/.lifecycle/task-state"
  local_afr="$TMPDIR_TEST/exists-ts-root/rd-workflow-workspace/.lifecycle"
  mkdir -p "$local_afr"
  printf 'schema=1\nfr-branch=null\nshort-title=cleared\nstatus=대기 중\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
  printf 'fr-branch=fr/x\nshort-title=legacy-x\n' > "$local_afr/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  if metadata_exists; then
    echo "  FAIL: task-state(fr-branch=null) + active-fr → metadata_exists true (legacy 값이 우선됨)" >&2
    exit 1
  else
    echo "  PASS: task-state(fr-branch=null) + active-fr → metadata_exists false (task-state 우선)"
    exit 0
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

# Case 3: task-state 부재 + active-fr 부재 → metadata_exists return 1
(
  set +e
  export project_root="$TMPDIR_TEST/exists-empty-root"
  export TASK_STATE_PATH="$TMPDIR_TEST/exists-empty-root/rd-workflow-workspace/.lifecycle/task-state"
  mkdir -p "$(dirname "$TASK_STATE_PATH")"
  rm -f "$TASK_STATE_PATH" "$TMPDIR_TEST/exists-empty-root/rd-workflow-workspace/.lifecycle/active-fr"
  source "$SCRIPT_DIR/_lifecycle_common.sh"
  if metadata_exists; then
    echo "  FAIL: task-state 부재 + active-fr 부재 → metadata_exists true" >&2
    exit 1
  else
    echo "  PASS: task-state 부재 + active-fr 부재 → metadata_exists false"
    exit 0
  fi
) && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo "== Task 2 누적: PASS=$PASS FAIL=$FAIL =="

echo "== loop-state primitives =="
LOOP_STATE_PATH="$TMPDIR_TEST/loop-state"
rm -f "$LOOP_STATE_PATH"
assert_eq "$(loop_state_get 'verify-fail::test')" "0" "미존재 키 → 0"
loop_state_record "verify-fail::test" incr
loop_state_record "verify-fail::test" incr
assert_eq "$(loop_state_get 'verify-fail::test')" "2" "incr 2회 → 2"
loop_state_record "verify-fail::test" reset
assert_eq "$(loop_state_get 'verify-fail::test')" "0" "reset → 0"
loop_state_record "reedit::a/b.sh" incr
loop_state_record "rollback::foo" incr
loop_state_record "verify-fail::lint" incr
loop_state_clear_attempt
assert_eq "$(loop_state_get 'reedit::a/b.sh')" "0" "clear_attempt → reedit 제거"
assert_eq "$(loop_state_get 'verify-fail::lint')" "0" "clear_attempt → verify-fail 제거"
assert_eq "$(loop_state_get 'rollback::foo')" "1" "clear_attempt → rollback 보존"
loop_state_clear_all
if [[ -f "$LOOP_STATE_PATH" ]]; then FAIL=$((FAIL+1)); echo "  FAIL: clear_all 후 파일 잔존" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: clear_all"; fi
rc=0; loop_state_record "bad=key" incr 2>/dev/null || rc=$?
assert_eq "$rc" "1" "잘못된 키(=) 거부"
rc=0; loop_state_record "$(printf 'a\nb')" incr 2>/dev/null || rc=$?
assert_eq "$rc" "1" "잘못된 키(개행) 거부"

echo "== loop-guard check =="
LOOP_GUARD_CONFIG="$TMPDIR_TEST/loop-guard.json"
export LOOP_GUARD_CONFIG
rm -f "$LOOP_STATE_PATH" "$LOOP_GUARD_CONFIG"
SLUG_T="demo"
# config 미존재 → 기본 임계 3
assert_eq "$(loop_guard_threshold verify_fail)" "3" "config 미존재 → 기본 3"
# verify-fail 임계 도달 → halt (slug-scoped key)
loop_state_record "verify-fail::${SLUG_T}::test" incr
loop_state_record "verify-fail::${SLUG_T}::test" incr
loop_state_record "verify-fail::${SLUG_T}::test" incr
rc=0; out="$(loop_guard_check "$SLUG_T")" || rc=$?
assert_eq "$rc" "1" "verify-fail 3회 → halt(return 1)"
case "$out" in *"검증 연속 실패"*) PASS=$((PASS+1)); echo "  PASS: verify-fail 사유 출력";; *) FAIL=$((FAIL+1)); echo "  FAIL: 사유 누락 — [$out]" >&2;; esac
# FR scoping: 다른 slug 로 조회 → 현재 FR 키 무시 → halt 안 함
rc=0; loop_guard_check "other" >/dev/null || rc=$?
assert_eq "$rc" "0" "다른 slug → FR scoping (halt 안 함)"
# rollback 임계 도달 → halt
rm -f "$LOOP_STATE_PATH"
loop_state_record "rollback::${SLUG_T}" incr; loop_state_record "rollback::${SLUG_T}" incr; loop_state_record "rollback::${SLUG_T}" incr
rc=0; loop_guard_check "$SLUG_T" >/dev/null || rc=$?
assert_eq "$rc" "1" "rollback 3회 → halt"
# reedit 단독 → halt 안 함
rm -f "$LOOP_STATE_PATH"
loop_state_record "reedit::${SLUG_T}::a.sh" incr; loop_state_record "reedit::${SLUG_T}::a.sh" incr; loop_state_record "reedit::${SLUG_T}::a.sh" incr
rc=0; loop_guard_check "$SLUG_T" >/dev/null || rc=$?
assert_eq "$rc" "0" "reedit 단독 3회 → halt 안 함"
# reedit + verify-fail 결합(ceil(3/2)=2) → halt
loop_state_record "verify-fail::${SLUG_T}::lint" incr; loop_state_record "verify-fail::${SLUG_T}::lint" incr
rc=0; loop_guard_check "$SLUG_T" >/dev/null || rc=$?
assert_eq "$rc" "1" "reedit 3 + verify-fail 2 → halt"
# enabled=false → 항상 0 (jq 있을 때만 의미; 없으면 skip+PASS)
if command -v jq >/dev/null 2>&1; then
  printf '{"enabled":false,"thresholds":{"verify_fail":1}}' > "$LOOP_GUARD_CONFIG"
  rm -f "$LOOP_STATE_PATH"; loop_state_record "verify-fail::${SLUG_T}::test" incr
  rc=0; loop_guard_check "$SLUG_T" >/dev/null || rc=$?
  assert_eq "$rc" "0" "enabled=false → halt 안 함"
  rm -f "$LOOP_GUARD_CONFIG"
else
  PASS=$((PASS+1)); echo "  PASS: jq 미설치 → enabled=false skip (fallback 기본값 동작)"
fi
unset LOOP_GUARD_CONFIG

echo "== rollback persistence =="
rm -f "$LOOP_STATE_PATH"
# 시뮬레이션: rollback 시 rollback:: 증가 후 clear_attempt (slug-scoped within-attempt 키)
loop_state_record "verify-fail::mytask::test" incr
loop_state_record "reedit::mytask::x.sh" incr
loop_state_record "rollback::mytask" incr
loop_state_clear_attempt
assert_eq "$(loop_state_get 'verify-fail::mytask::test')" "0" "clear_attempt → verify-fail 제거"
assert_eq "$(loop_state_get 'rollback::mytask')" "1" "rollback 1회 기록 + attempt clear 후 보존"
loop_state_record "rollback::mytask" incr
loop_state_clear_attempt
assert_eq "$(loop_state_get 'rollback::mytask')" "2" "2회 rollback 누적 (cross-attempt 지속)"
loop_state_clear_all
assert_eq "$(loop_state_get 'rollback::mytask')" "0" "clear_all → rollback 제거"

echo "== M2 attempt history 주입 =="
( # 서브셸 — review_common.sh의 set -e / PROJECT_ROOT 격리. fixture PROJECT_ROOT 사용.
  FAKE_ROOT="$TMPDIR_TEST/m2root"
  prev_dir="$FAKE_ROOT/rd-workflow-workspace/handoffs/review_pipeline/20260101_000000_prev"
  mkdir -p "$prev_dir" "$FAKE_ROOT/cur"
  printf '## Branch Context\n- short-title: demo\n' > "$prev_dir/SESSION.md"
  printf '## Current Summary\n이전 시도 요약입니다.\n' > "$prev_dir/CHECKPOINT.md"
  printf '## Branch Context\n- short-title: demo\n' > "$FAKE_ROOT/cur/SESSION.md"
  PROJECT_ROOT="$FAKE_ROOT"; export PROJECT_ROOT
  LOOP_STATE_PATH="$TMPDIR_TEST/m2-loop-state"; export LOOP_STATE_PATH
  # fixture loop-state (slug-scoped). demo reedit 6개 → top-5 cap 검증 (bar.sh=2 가 rank6 으로 제외).
  # reedit::other:: 는 negative — 출력에 안 나와야 함.
  {
    printf 'reedit::demo::c1.sh=10\nreedit::demo::c2.sh=9\nreedit::demo::c3.sh=8\n'
    printf 'reedit::demo::c4.sh=7\nreedit::demo::foo.sh=4\nreedit::demo::bar.sh=2\n'
    printf 'rollback::demo=1\nreedit::other::zzz.sh=9\n'
  } > "$LOOP_STATE_PATH"
  source "$SCRIPT_DIR/../review_common.sh"
  out_file="$TMPDIR_TEST/prompt_auto.txt"
  # $3 = cur/SESSION.md (short-title 정본). cur_session=sdir 이라 prev 와 겹치지 않음.
  RD_AUTOPILOT=1 build_review_prompt "$out_file" sdir cur/SESSION.md cfile uafile ltfile etfile spec-plan-review target goal 20 003
  grep -q "Attempt History" "$out_file" || { echo "  FAIL: autopilot prepend 누락" >&2; exit 9; }
  grep -q "c1.sh=10" "$out_file" || { echo "  FAIL: reedit 최상위 누락" >&2; exit 9; }
  grep -q "foo.sh=4" "$out_file" || { echo "  FAIL: reedit rank5 누락" >&2; exit 9; }
  grep -q "rollback 1회" "$out_file" || { echo "  FAIL: rollback count 누락" >&2; exit 9; }
  grep -q "이전 시도 요약" "$out_file" || { echo "  FAIL: 이전 종결 사유 누락" >&2; exit 9; }
  if grep -q "bar.sh" "$out_file"; then echo "  FAIL: top-5 cap 미적용 (rank6 bar.sh 노출)" >&2; exit 9; fi
  if grep -q "zzz.sh" "$out_file"; then echo "  FAIL: 다른 slug(other) 키가 샘" >&2; exit 9; fi
  out_file2="$TMPDIR_TEST/prompt_manual.txt"
  # 수동 모드 — RD_AUTOPILOT 을 명시적으로 비워 외부 환경(autopilot 세션) 오염을 격리한다.
  RD_AUTOPILOT="" build_review_prompt "$out_file2" sdir cur/SESSION.md cfile uafile ltfile etfile spec-plan-review target goal 20 003
  if grep -q "Attempt History" "$out_file2"; then echo "  FAIL: 수동 모드인데 prepend 됨" >&2; exit 9; fi
  echo "  PASS: M2 (prepend/reedit-top5/rollback/prev/negative-slug/manual)"
) && PASS=$((PASS+7)) || { FAIL=$((FAIL+1)); echo "  FAIL: M2 블록 실패" >&2; }

echo "== M2 prev-session exact slug match (api vs api-v2) =="
( # prefix slug 가 다른 FR 세션을 오인하지 않는지 — diff review turn 002 회귀
  FR="$TMPDIR_TEST/m2exact"
  api_dir="$FR/rd-workflow-workspace/handoffs/review_pipeline/20260101_000000_api"
  apiv2_dir="$FR/rd-workflow-workspace/handoffs/review_pipeline/20260102_000000_apiv2"
  mkdir -p "$api_dir" "$apiv2_dir"
  printf '## Branch Context\n- short-title: api\n' > "$api_dir/SESSION.md"
  printf '## Current Summary\nAPI 세션 요약.\n' > "$api_dir/CHECKPOINT.md"
  printf '## Branch Context\n- short-title: api-v2\n' > "$apiv2_dir/SESSION.md"
  printf '## Current Summary\nAPIV2 세션 요약.\n' > "$apiv2_dir/CHECKPOINT.md"
  PROJECT_ROOT="$FR"; export PROJECT_ROOT
  LOOP_STATE_PATH="$TMPDIR_TEST/m2exact-loop"; export LOOP_STATE_PATH
  : > "$LOOP_STATE_PATH"
  source "$SCRIPT_DIR/../review_common.sh"
  out="$(build_attempt_history api "")"
  printf '%s' "$out" | grep -q "API 세션 요약" || { echo "  FAIL: api 세션 요약 누락" >&2; exit 9; }
  if printf '%s' "$out" | grep -q "APIV2"; then echo "  FAIL: api-v2 세션이 api 로 오인 주입됨" >&2; exit 9; fi
  echo "  PASS: prev-session exact slug match (api ≠ api-v2)"
) && PASS=$((PASS+2)) || { FAIL=$((FAIL+1)); echo "  FAIL: M2 exact-match 블록 실패" >&2; }

echo "== build_ac_enforcement_notice =="
( # 서브셸 — review_common.sh의 set -e / PROJECT_ROOT 격리
  set +e
  source "$SCRIPT_DIR/../review_common.sh"
  acn_tmp="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  [[ -n "$acn_tmp" && -d "$acn_tmp" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  trap "rm -rf '$acn_tmp'" EXIT

  mk_req() { # $1=AC 본문, $2=bypass 본문 → REQUEST.md 생성, 경로 echo
    local f="$acn_tmp/REQUEST_$RANDOM.md"
    printf '# Change Request\n\n## Acceptance Criteria\n%s\n\n## AC Bypass Reason\n%s\n\n## Source FR\n-\n' "$1" "$2" > "$f"
    printf '%s' "$f"
  }

  # 1) AC 채워짐 → 무주입 (빈 문자열)
  out="$(build_ac_enforcement_notice "$(mk_req '- 통과 조건 X' '-')")"
  [[ -z "$out" ]] || { echo "  FAIL: AC 채워짐인데 notice 발생 — [$out]" >&2; exit 9; }
  echo "  PASS: AC 채워짐 → 무주입"

  # 2) AC 비어있음(-) + bypass 없음 → 주입
  out="$(build_ac_enforcement_notice "$(mk_req '-' '-')")"
  printf '%s' "$out" | grep -q "완료 기준이 정의되지 않" || { echo "  FAIL: 누락 주입 메시지 없음" >&2; exit 9; }
  echo "  PASS: AC 비어있음 + 면제 없음 → 주입"

  # 3) AC 비어있음 + bypass=small-task → 면제 인정 (주입 메시지 미포함)
  out="$(build_ac_enforcement_notice "$(mk_req '-' 'small-task')")"
  printf '%s' "$out" | grep -q "면제 사유: small-task" || { echo "  FAIL: 면제 주석 없음" >&2; exit 9; }
  if printf '%s' "$out" | grep -q "완료 기준이 정의되지 않"; then echo "  FAIL: 면제인데 주입 메시지 포함" >&2; exit 9; fi
  echo "  PASS: bypass=small-task → 면제 인정"

  # 4) AC 비어있음 + bypass=오타 → 주입 + 경고
  out="$(build_ac_enforcement_notice "$(mk_req '-' 'typo')")"
  printf '%s' "$out" | grep -q "완료 기준이 정의되지 않" || { echo "  FAIL: 허용 외 값인데 주입 안 됨" >&2; exit 9; }
  printf '%s' "$out" | grep -q "인식할 수 없는 AC_BYPASS_REASON 값: typo" || { echo "  FAIL: 경고 누락" >&2; exit 9; }
  echo "  PASS: bypass=허용 외 값 → 주입 + 경고"

  # 5) AC가 HTML comment + '-' 만 → 비어있음 판정 → 주입 (Finding 1)
  out="$(build_ac_enforcement_notice "$(mk_req '<!-- 완료 기준을 적으세요 -->
-' '-')")"
  printf '%s' "$out" | grep -q "완료 기준이 정의되지 않" || { echo "  FAIL: comment+- 인데 채워짐으로 오판" >&2; exit 9; }
  echo "  PASS: AC=comment+'-' → 비어있음 → 주입"

  # 6) AC가 '-' 여러 줄(복수 placeholder) → 비어있음 → 주입 (Finding 1)
  out="$(build_ac_enforcement_notice "$(mk_req '-
-' '-')")"
  printf '%s' "$out" | grep -q "완료 기준이 정의되지 않" || { echo "  FAIL: 복수 '-' 인데 채워짐으로 오판" >&2; exit 9; }
  echo "  PASS: AC='-' 여러 줄 → 비어있음 → 주입"

  # 7) REQUEST.md 부재 → 빈 출력 + 성공 종료 (Finding 2)
  out="$(build_ac_enforcement_notice "$acn_tmp/NO_SUCH_REQUEST.md")" || { echo "  FAIL: 부재 경로에서 비정상 종료" >&2; exit 9; }
  [[ -z "$out" ]] || { echo "  FAIL: REQUEST 부재인데 notice 발생 — [$out]" >&2; exit 9; }
  echo "  PASS: REQUEST.md 부재 → 빈 출력 + 성공"

  # 8) AC가 multi-line HTML comment 블록 + '-' 만 → 비어있음 판정 → 주입 (diff-review Finding 1)
  out="$(build_ac_enforcement_notice "$(mk_req '<!--
완료 기준을 여기에 적으세요
placeholder 줄
-->
-' '-')")"
  printf '%s' "$out" | grep -q "완료 기준이 정의되지 않" || { echo "  FAIL: multi-line comment 블록 내부를 의미있는 줄로 오판" >&2; exit 9; }
  echo "  PASS: AC=multi-line comment 블록+'-' → 비어있음 → 주입"

  echo "  (build_ac_enforcement_notice OK)"
) || { FAIL=$((FAIL+1)); echo "FAIL: build_ac_enforcement_notice 단위 테스트" >&2; }
PASS=$((PASS+1))

echo "== build_review_prompt: AC enforcement 주입 =="
( set +e
  source "$SCRIPT_DIR/../review_common.sh"
  bp_tmp="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  [[ -n "$bp_tmp" && -d "$bp_tmp" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  trap "rm -rf '$bp_tmp'" EXIT
  export PROJECT_ROOT="$bp_tmp"
  # AC 비어있는 REQUEST.md
  printf '# Change Request\n\n## Acceptance Criteria\n-\n\n## AC Bypass Reason\n-\n' > "$bp_tmp/REQUEST.md"
  # 첫 reviewer 턴 세션 (turns/ 에 reviewer 파일 없음)
  mkdir -p "$bp_tmp/sess/turns"; printf '# Turn 001 — Author\n' > "$bp_tmp/sess/turns/001_author.md"

  out_f="$bp_tmp/p1.txt"
  build_review_prompt "$out_f" sess sess/SESSION.md c u sess/turns/001_author.md sess/turns/002_reviewer.md request-review target goal 20 002
  grep -q "완료 기준이 정의되지 않" "$out_f" || { echo "  FAIL: request-review 첫 턴 주입 누락" >&2; exit 9; }
  echo "  PASS: request-review 첫 reviewer 턴 주입"

  out_f="$bp_tmp/p2.txt"
  build_review_prompt "$out_f" sess sess/SESSION.md c u sess/turns/001_author.md sess/turns/002_reviewer.md diff-review target goal 20 002
  grep -q "완료 기준이 정의되지 않" "$out_f" || { echo "  FAIL: diff-review 첫 턴 주입 누락" >&2; exit 9; }
  echo "  PASS: diff-review 첫 reviewer 턴 주입"

  # 둘째 reviewer 턴: turns/ 에 reviewer 파일 존재 → 미주입
  printf '# Turn 002 — Reviewer\n' > "$bp_tmp/sess/turns/002_reviewer.md"
  out_f="$bp_tmp/p3.txt"
  build_review_prompt "$out_f" sess sess/SESSION.md c u sess/turns/002_reviewer.md sess/turns/004_reviewer.md request-review target goal 20 004
  if grep -q "완료 기준이 정의되지 않" "$out_f"; then echo "  FAIL: 둘째 reviewer 턴인데 주입됨" >&2; exit 9; fi
  echo "  PASS: 둘째 reviewer 턴 → 미주입"

  # legacy *_codex.md 턴도 reviewer 턴으로 취급 → 둘째 턴 미주입 (diff-review Finding 2)
  rm -f "$bp_tmp/sess/turns/002_reviewer.md"
  printf '# Turn 002 — Reviewer (codex)\n' > "$bp_tmp/sess/turns/002_codex.md"
  out_f="$bp_tmp/p_legacy.txt"
  build_review_prompt "$out_f" sess sess/SESSION.md c u sess/turns/002_codex.md sess/turns/004_reviewer.md request-review target goal 20 004
  if grep -q "완료 기준이 정의되지 않" "$out_f"; then echo "  FAIL: legacy codex 턴 있는데 재주입됨" >&2; exit 9; fi
  echo "  PASS: legacy *_codex.md 턴 → reviewer 인식 → 미주입"
  rm -f "$bp_tmp/sess/turns/002_codex.md"

  # spec-plan-review: 대상 아님 → 미주입 (첫 턴이어도)
  rm -f "$bp_tmp/sess/turns/002_reviewer.md"
  out_f="$bp_tmp/p4.txt"
  build_review_prompt "$out_f" sess sess/SESSION.md c u sess/turns/001_author.md sess/turns/002_reviewer.md spec-plan-review target goal 20 002
  if grep -q "완료 기준이 정의되지 않" "$out_f"; then echo "  FAIL: spec-plan-review에 주입됨" >&2; exit 9; fi
  echo "  PASS: spec-plan-review → 미주입"
) || { FAIL=$((FAIL+1)); echo "FAIL: build_review_prompt AC 주입 테스트" >&2; }
PASS=$((PASS+1))

echo "== build_review_prompt: autopilot 공존 (AC notice + attempt history) =="
( set +e
  source "$SCRIPT_DIR/../review_common.sh"
  ar_tmp="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  [[ -n "$ar_tmp" && -d "$ar_tmp" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  trap "rm -rf '$ar_tmp'" EXIT
  export PROJECT_ROOT="$ar_tmp"
  printf '# Change Request\n\n## Acceptance Criteria\n-\n\n## AC Bypass Reason\n-\n' > "$ar_tmp/REQUEST.md"
  mkdir -p "$ar_tmp/cur/turns"
  printf '## Branch Context\n- short-title: demo\n' > "$ar_tmp/cur/SESSION.md"
  printf '# Turn 001 — Author\n' > "$ar_tmp/cur/turns/001_author.md"
  prev="$ar_tmp/rd-workflow-workspace/handoffs/review_pipeline/20260101_000000_prev"
  mkdir -p "$prev"
  printf '## Branch Context\n- short-title: demo\n' > "$prev/SESSION.md"
  printf '## Current Summary\n이전 시도 요약입니다.\n' > "$prev/CHECKPOINT.md"
  export LOOP_STATE_PATH="$ar_tmp/loop-state"
  printf 'reedit::demo::c1.sh=10\nrollback::demo=1\n' > "$LOOP_STATE_PATH"

  out_f="$ar_tmp/auto.txt"
  RD_AUTOPILOT=1 build_review_prompt "$out_f" cur cur/SESSION.md c u cur/turns/001_author.md cur/turns/002_reviewer.md request-review target goal 20 002
  grep -q "완료 기준이 정의되지 않" "$out_f" || { echo "  FAIL: autopilot에서 AC notice 누락" >&2; exit 9; }
  grep -q "Attempt History" "$out_f" || { echo "  FAIL: autopilot attempt history 누락" >&2; exit 9; }
  ac_line="$(grep -n "완료 기준이 정의되지 않" "$out_f" | head -1 | cut -d: -f1)"
  ah_line="$(grep -n "Attempt History" "$out_f" | head -1 | cut -d: -f1)"
  [[ "$ac_line" -lt "$ah_line" ]] || { echo "  FAIL: AC notice 가 attempt history 보다 먼저가 아님 (ac=$ac_line ah=$ah_line)" >&2; exit 9; }
  echo "  PASS: autopilot 공존 — AC notice 먼저 + 두 블록 존재"
) || { FAIL=$((FAIL+1)); echo "FAIL: autopilot 공존 테스트" >&2; }
PASS=$((PASS+1))

echo "== parse_turn_limit_line / read_session_turn_limit (turn-limit-parser-anchored) =="
tl_tmp="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$tl_tmp" && -d "$tl_tmp" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }

# (a) 정본 형식 추출 — 백틱 포함 리터럴
got="$( source "$SCRIPT_DIR/../review_common.sh"; parse_turn_limit_line '50 total turns in `turns/*.md`' 2>/dev/null )"
assert_eq "$got" "50" "parse: 정본 형식 → 50"

# (b) Stop Rule류 다른 줄 비추출 (exit 1 기대)
if ( source "$SCRIPT_DIR/../review_common.sh"; parse_turn_limit_line '총 턴 수가 20에 도달하면 더 이상 다음 턴을 만들지 않고' ) >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "  FAIL: 비정본 줄에서 추출됨" >&2
else
  PASS=$((PASS+1)); echo "  PASS: 비정본 줄 비추출"
fi

# (b2) 앵커 위반(뒤에 추가 텍스트) 비추출
if ( source "$SCRIPT_DIR/../review_common.sh"; parse_turn_limit_line '50 total turns in `turns/*.md` (note)' ) >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "  FAIL: 추가 텍스트 줄에서 추출됨" >&2
else
  PASS=$((PASS+1)); echo "  PASS: 앵커 위반 줄 비추출"
fi

# (f) read_session_turn_limit 정본 회귀
printf '## Turn Limit\n50 total turns in `turns/*.md`\n\n## Stop Rule\n- x\n' > "$tl_tmp/SESSION.md"
got="$( source "$SCRIPT_DIR/../review_common.sh"; REVIEW_TURN_LIMIT='' read_session_turn_limit "$tl_tmp/SESSION.md" 2>/dev/null )"
assert_eq "$got" "50" "read: 정본 → 50 (회귀)"

# (c) malformed-present → default 20 + stderr 경고
printf '## Turn Limit\nfifty turns\n\n## Stop Rule\n- x\n' > "$tl_tmp/SESSION.md"
got="$( source "$SCRIPT_DIR/../review_common.sh"; REVIEW_TURN_LIMIT='' read_session_turn_limit "$tl_tmp/SESSION.md" 2>/dev/null )"
assert_eq "$got" "20" "read: malformed-present → default 20"
warn="$( source "$SCRIPT_DIR/../review_common.sh"; REVIEW_TURN_LIMIT='' read_session_turn_limit "$tl_tmp/SESSION.md" 2>&1 >/dev/null )"
if printf '%s' "$warn" | grep -q "형식 미인식"; then
  PASS=$((PASS+1)); echo "  PASS: malformed-present stderr 경고"
else
  FAIL=$((FAIL+1)); echo "  FAIL: malformed-present 경고 누락" >&2
fi

# (d) section 부재 → fallback, 경고 없음
printf '## Stop Rule\n- x\n' > "$tl_tmp/SESSION.md"
got="$( source "$SCRIPT_DIR/../review_common.sh"; REVIEW_TURN_LIMIT='' read_session_turn_limit "$tl_tmp/SESSION.md" 2>/dev/null )"
assert_eq "$got" "20" "read: section 부재 → default 20"
warn="$( source "$SCRIPT_DIR/../review_common.sh"; REVIEW_TURN_LIMIT='' read_session_turn_limit "$tl_tmp/SESSION.md" 2>&1 >/dev/null )"
if [ -z "$warn" ]; then
  PASS=$((PASS+1)); echo "  PASS: section 부재 시 경고 없음"
else
  FAIL=$((FAIL+1)); echo "  FAIL: section 부재인데 경고 출력" >&2
fi

# (e) env fallback
printf '## Stop Rule\n- x\n' > "$tl_tmp/SESSION.md"
got="$( source "$SCRIPT_DIR/../review_common.sh"; REVIEW_TURN_LIMIT='33' read_session_turn_limit "$tl_tmp/SESSION.md" 2>/dev/null )"
assert_eq "$got" "33" "read: section 없음 + env 33 → 33"
rm -rf "$tl_tmp"

echo "== review-gate 헬퍼 (safeguard-review-completion-checks) =="
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GUARD_ROOT="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$GUARD_ROOT" && -d "$GUARD_ROOT" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
mkdir -p "$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline"
mkdir -p "$GUARD_ROOT/rd-workflow-workspace/.lifecycle"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"

# mk_session <dirname> <status> <open_issues_line> <short_title>
mk_session() {
  local d="$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline/$1"
  mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}

project_root="$GUARD_ROOT"
# v2 2b: task-state 격리 — metadata I/O 테스트의 잔여 상태가 오염되지 않도록 TASK_STATE_PATH 재설정
TASK_STATE_PATH="$GUARD_ROOT/rd-workflow-workspace/.lifecycle/task-state"
# task-state 초기값: 대기 중 (get_current_short_title이 task-state에서 short-title을 읽음)
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
source "$REPO_ROOT/rd-workflow/scripts/hooks/_guard_common.sh"

assert_eq "$(get_current_short_title)" "mytask" "get_current_short_title — CURRENT_TASK"

# fr-scope: mytask 세션만 반환, 다른 fr 세션 제외
mk_session "20260101_000000_final-diff-review" "closed" "- 없음" "otherfr"
mk_session "20260102_000000_final-diff-review" "closed" "- 없음" "mytask"
assert_eq "$(basename "$(get_latest_diff_review_dir)")" "20260102_000000_final-diff-review" "fr-scope — mytask 세션만"

RP="$GUARD_ROOT/rd-workflow-workspace/handoffs/review_pipeline"
# (a) closed + 없음 → 종결(0)
mk_session "20260103_000000_final-diff-review" "closed" "- 없음" "mytask"
is_review_session_resolved "$RP/20260103_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + 없음"
# (b) awaiting-user + 없음 → 종결(0)  ※ 운영상 정상 종료 패턴(75%)
mk_session "20260104_000000_final-diff-review" "awaiting-user" "- 없음" "mytask"
is_review_session_resolved "$RP/20260104_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — awaiting-user + 없음 (정상 종료)"
# (c) awaiting-reviewer (루프 진행 중) → 미종결(1)
mk_session "20260105_000000_final-diff-review" "awaiting-reviewer" "- 없음" "mytask"
is_review_session_resolved "$RP/20260105_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — awaiting-reviewer (루프 진행 중)"
# (d) awaiting-user + 실제 이슈 → 미종결(1)
mk_session "20260106_000000_final-diff-review" "awaiting-user" "- 미해결 쟁점" "mytask"
is_review_session_resolved "$RP/20260106_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — awaiting-user + 실제 이슈"
# (e) closed (후행 공백) → trim 후 종결(0)
mk_session "20260107_000000_final-diff-review" "closed " "- 없음" "mytask"
is_review_session_resolved "$RP/20260107_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — 'closed ' trim"
# (f) malformed: CHECKPOINT.md 없음 → fail-closed(1)
mkdir -p "$RP/20260108_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: mytask\n' > "$RP/20260108_000000_final-diff-review/SESSION.md"
is_review_session_resolved "$RP/20260108_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — CHECKPOINT.md 부재"
# (g) malformed: Open Issues 섹션 없음 → fail-closed(1)
mkdir -p "$RP/20260109_000000_final-diff-review"
printf '## Status\nclosed\n\n## Branch Context\n- short-title: mytask\n' > "$RP/20260109_000000_final-diff-review/SESSION.md"
printf '# Review Checkpoint\n\n## Current Summary\n-\n' > "$RP/20260109_000000_final-diff-review/CHECKPOINT.md"
is_review_session_resolved "$RP/20260109_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — Open Issues 섹션 부재"

# (h)~(q) canonical 마커 계약 (precheck-open-issues-marker) — 별도 short-title(markertask)로
# 격리해 아래 get_latest_diff_review_dir(mytask 최신=20260109) assert에 간섭하지 않는다.
# (h) closed + None (영어 canonical 마커) → 종결(0)
mk_session "20260301_000000_final-diff-review" "closed" "- None" "markertask"
is_review_session_resolved "$RP/20260301_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + None (영어 마커)"
# (i) closed + None. (후행 마침표 — 실제 관측된 거짓 양성 사례) → 종결(0)
mk_session "20260302_000000_final-diff-review" "closed" "- None." "markertask"
is_review_session_resolved "$RP/20260302_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + None. (후행 마침표)"
# (j) closed + 없음. (한국어 + 후행 마침표) → 종결(0)
mk_session "20260303_000000_final-diff-review" "closed" "- 없음." "markertask"
is_review_session_resolved "$RP/20260303_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — closed + 없음. (후행 마침표)"
# (k) closed + 비마커 산문 → 미종결(1) (fail-closed)
mk_session "20260304_000000_final-diff-review" "closed" "- no issues" "markertask"
is_review_session_resolved "$RP/20260304_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 비마커 산문 (no issues)"
# (l) closed + 마커 뒤 후행 텍스트 → 미종결(1) (라인 전체 매칭, fail-closed 강화)
mk_session "20260305_000000_final-diff-review" "closed" "- 없음 (단, 후속 확인 필요)" "markertask"
is_review_session_resolved "$RP/20260305_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 마커 뒤 후행 텍스트"
# (m) closed + 빈 섹션 (내용 라인 없음) → 미종결(1) (마커 존재 요구)
mk_session "20260306_000000_final-diff-review" "closed" "" "markertask"
is_review_session_resolved "$RP/20260306_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 빈 Open Issues 섹션 (마커 부재)"
# (n) closed + HTML 주석만 → 미종결(1) (주석은 무시, 마커 부재)
mk_session "20260307_000000_final-diff-review" "closed" "<!-- 규약 주석 -->" "markertask"
is_review_session_resolved "$RP/20260307_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 주석만 있는 섹션 (마커 부재)"
# (o) closed + 비-bullet 산문 (dash 없는 None) → 미종결(1)
mk_session "20260308_000000_final-diff-review" "closed" "None" "markertask"
is_review_session_resolved "$RP/20260308_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 비-bullet 산문 (None)"
# (p) closed + 마커와 실제 이슈 혼재 → 미종결(1)
mk_session "20260309_000000_final-diff-review" "closed" "$(printf -- '- 없음\n- 실제 이슈')" "markertask"
is_review_session_resolved "$RP/20260309_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "1" "unresolved — 마커와 실제 이슈 혼재"
# (q) closed + 규약 주석 + 마커 (신규 템플릿 정상 종결 형태) → 종결(0)
mk_session "20260310_000000_final-diff-review" "closed" "$(printf -- '<!-- 규약 주석 -->\n- 없음')" "markertask"
is_review_session_resolved "$RP/20260310_000000_final-diff-review" && rc=0 || rc=1
assert_eq "$rc" "0" "resolved — 규약 주석 + 마커 (신규 템플릿 형태)"

# fr 세션 부재 시 빈 값 (다른 fr만 존재)
printf '# Current Task\n\n## Short Title\nlonelytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
# v2 2b: task-state도 함께 업데이트 (get_current_short_title이 task-state에서 읽음)
printf 'schema=1\nshort-title=lonelytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
assert_eq "$(get_latest_diff_review_dir)" "" "fr-scope — 현재 fr 세션 없으면 빈 값"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"

# malformed 세션은 short-title 미상 → fr-scope 후보 제외 (legacy/unscoped 통과, 3d 오발화 방지)
mkdir -p "$RP/20260110_000000_final-diff-review"
mkdir -p "$RP/20260111_000000_final-diff-review"
printf '## Status\nclosed\n' > "$RP/20260111_000000_final-diff-review/SESSION.md"
assert_eq "$(basename "$(get_latest_diff_review_dir)")" "20260109_000000_final-diff-review" "malformed 제외 — short-title 매칭 세션만 반환"
printf '# Current Task\n\n## Short Title\nzzz\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=zzz\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
assert_eq "$(get_latest_diff_review_dir)" "" "malformed-only → 빈 값 (unscoped 통과, 오발화 방지)"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"

# archive_review_precheck (3c)
PRECHECK_AUDIT="$GUARD_ROOT/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
rm -f "$PRECHECK_AUDIT"
printf '# Current Task\n\n## Short Title\nlonelytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=lonelytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
archive_review_precheck "0" "" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — 미종결 + force-skip 아님 → 차단"
archive_review_precheck "1" "" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — force-skip + 사유 누락 → 차단"
archive_review_precheck "1" "긴급 핫픽스" "lonelytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — force-skip + 사유 → 통과"
assert_eq "$(awk -F' \\| ' 'END{print $2}' "$PRECHECK_AUDIT")" "lonelytask" "precheck — audit slug 기록"
assert_eq "$(awk -F' \\| ' 'END{print $3}' "$PRECHECK_AUDIT")" "긴급 핫픽스" "precheck — audit 사유 기록"
printf '# Current Task\n\n## Short Title\nmytask\n' > "$GUARD_ROOT/CURRENT_TASK.md"
printf 'schema=1\nshort-title=mytask\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
# 종결 세션이 있어도 **마커가 없으면 차단**입니다 (change spec §3.3, AC 11).
# 종전 계약은 `handoffs/` 의 최신 종결 세션을 찾아 통과시켰고, 여기가 그것을 단언하던
# 자리입니다. consumer 가 마커 하나만 읽도록 전면 교체됐으므로 기대값을 뒤집습니다 —
# 이 단언이 없으면 "세션만 종결하면 발행된다" 는 옛 경로가 되살아나도 아무도 모릅니다.
mk_session "20260120_000000_final-diff-review" "closed" "- 없음" "mytask"   # 최신 종결 mytask 세션
archive_review_precheck "0" "" "mytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "precheck — 종결 세션만 있고 마커 없음 → 차단 (세션 종결성만으로 통과하지 않는다)"

# === archive precheck 권위 tree (change spec §3.3.1) ===
#
# 이 블록은 종전의 「fr tip 세션 가시성」·「fr-branch identity 매칭」 두 블록을 대체합니다.
# 그 두 블록은 precheck 가 `handoffs/` 의 세션을 찾아 종결성을 판정하던 계약을 단언했는데,
# consumer 가 **마커 한 파일**만 읽도록 전면 교체되어(AC 11) 그 판정 경로 자체가 없어졌습니다.
# 남겨 두면 통과하더라도 없는 동작을 증명하게 되므로, 같은 실수(=main 워킹트리에 마커가
# 없다고 표준 흐름이 막히는 것)를 새 계약 위에서 잡는 케이스로 다시 씁니다.
echo "== archive precheck 권위 tree (fr tip 커밋 마커) =="
FT_REPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$FT_REPO" && -d "$FT_REPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
FT_REPO="$(cd "$FT_REPO" && pwd -P)"
git -C "$FT_REPO" init -q -b main
git -C "$FT_REPO" config user.email t@t && git -C "$FT_REPO" config user.name t
mkdir -p "$FT_REPO/rd-workflow-workspace/.lifecycle/review-seals"
printf '# Current Task\n\n## Short Title\n-\n' > "$FT_REPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=fttask\nstatus=구현 중\nfr-branch=fr/fttask\nworktree-path=null\nsource-fr=-\ncreated-at=2026-07-05-0000\n' \
  > "$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"
printf 'code\n' > "$FT_REPO/src.txt"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m seed

FT_SID="20260906_000000_final-diff-review"
FT_TS="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"
FT_SEAL="$FT_REPO/rd-workflow-workspace/.lifecycle/review-seals/${FT_SID}.seal"
# ft_write_seal <파일> <tree-hash> — 마커 10필드. rd-version 은 fixture 에 VERSION 이 없어
# `_rd_version` 이 내는 값과 같은 `unknown` 을 씁니다 (다르면 경고만 나므로 판정과 무관).
ft_write_seal() {
  # `git switch` 는 추적 파일이 사라지면 빈 디렉터리를 함께 정리하므로 매번 만듭니다.
  mkdir -p "$(dirname "$1")"
  printf 'schema=1\nsession-id=%s\nreview-type=diff-review\ntree-hash=%s\nhead=%s\nbranch-mode=fr\nfr-branch=fr/fttask\nrd-version=unknown\nverified=yes\nsealed-at=2026-09-06-0000\n' \
    "$FT_SID" "$2" "$(git -C "$FT_REPO" rev-parse HEAD)" > "$1"
}
ft_precheck() {  # ft_precheck <force_skip> <reason> <audit> [fr_ref] — rc 를 stdout 에 낸다
  local _rc=0
  ( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_TS"; \
    archive_review_precheck "$1" "$2" "fttask" "$3" "${4-}" ) >/dev/null 2>&1 || _rc=1
  printf '%s' "$_rc"
}

# fr 브랜치: 작업 커밋 → 그 커밋의 보호 트리 해시로 마커 작성 → 포인터·마커 커밋.
# 마커와 포인터는 둘 다 §2.1 의 기록 경로라 커밋해도 보호 트리 해시가 변하지 않습니다 —
# 그래서 「seal → 상태 전이 → 기록 커밋」 순서가 자기 차단을 일으키지 않습니다 (§4.2).
git -C "$FT_REPO" switch -q -c fr/fttask
printf 'work\n' >> "$FT_REPO/src.txt"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "구현"
FT_HASH="$( ( project_root="$FT_REPO"; rd_protected_tree_hash "fr/fttask" ) )"
ft_write_seal "$FT_SEAL" "$FT_HASH"
printf 'review-session=%s\n' "$FT_SID" >> "$FT_TS"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "기록 커밋 (포인터 + 마커)"
git -C "$FT_REPO" switch -q main

# Case A (핵심 회귀): 기본 브랜치 워킹트리에는 포인터도 마커도 없지만 fr tip 에 있으면 통과.
# 「fr 브랜치에 커밋 → 기본 브랜치로 switch → archive.sh」 표준 흐름이 이 케이스입니다.
[[ -e "$FT_SEAL" ]] && rc=0 || rc=1
assert_eq "$rc" "1" "권위 tree — 기본 브랜치 워킹트리에 마커 없음(sanity)"
assert_eq "$(ft_precheck 0 "" "$FT_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" "fr/fttask")" "0" \
  "권위 tree — fr tip 의 포인터+마커로 통과 (main 워킹트리 비의존)"

# Case B: 기본 브랜치 워킹트리에 **stale 마커**가 있어도 판정은 fr tip 을 봅니다 → 통과 유지.
ft_write_seal "$FT_SEAL" "0000000000000000000000000000000000000000"
assert_eq "$(ft_precheck 0 "" "$FT_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" "fr/fttask")" "0" \
  "권위 tree — 워킹트리의 stale 마커가 fr tip 판정을 오염시키지 않음"

# Case C (권위 tree 음성): 마커를 fr tip 에서 지우고 워킹트리에만 두면 통과하지 못합니다.
# 「워킹트리에 seal 만 만들고 커밋하지 않은」 상태이며, 여기서 통과하면 마커는 증명이
# 아니라 실행 시점의 로컬 파일이 됩니다.
rm -f "$FT_SEAL"   # 워킹트리의 stale 마커를 치워야 fr 브랜치 체크아웃이 덮어쓰지 않습니다
git -C "$FT_REPO" switch -q fr/fttask
git -C "$FT_REPO" rm -q "rd-workflow-workspace/.lifecycle/review-seals/${FT_SID}.seal"
git -C "$FT_REPO" commit -q -m "마커 제거 (음성 케이스)"
git -C "$FT_REPO" switch -q main
ft_write_seal "$FT_SEAL" "$FT_HASH"   # 워킹트리에만 유효한 마커
assert_eq "$(ft_precheck 0 "" "$FT_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" "fr/fttask")" "1" \
  "권위 tree — 워킹트리에만 있는 마커로는 통과 못 함"

# Case D: 지정된 fr 브랜치의 ref 가 없으면 판정 대상이 없으므로 차단 (§3.3.1).
assert_eq "$(ft_precheck 0 "" "$FT_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" "fr/nonexistent")" "1" \
  "권위 tree — fr ref 부재 → 판정 대상 없음으로 차단"

# Case E (audit 정규화 회귀): 마커 무효 + force-skip + 사유 → 통과하되, audit 의 세션참조는
# temp 절대경로가 아니라 repo-상대 **마커** 경로여야 합니다.
FT_AUDIT2="$FT_REPO/rd-workflow-workspace/.lifecycle/audit2.log"
assert_eq "$(ft_precheck 1 "긴급 사유" "$FT_AUDIT2" "fr/fttask")" "0" "권위 tree — force-skip + 사유 → 통과"
assert_eq "$(awk -F' \\| ' 'END{print $4}' "$FT_AUDIT2")" \
  "rd-workflow-workspace/.lifecycle/review-seals/${FT_SID}.seal" \
  "권위 tree — audit 세션참조가 repo-상대 마커 경로"
rm -rf "$FT_REPO"

# === 발행 직전 재결속 (no-fr) — precheck 승인 해시 ↔ PUBLISH_OID (Finding 1) ===
#
# no-fr 은 fr 의 기준선(= fr tip 을 들여온 merge) 에 대응물이 없어
# `archive_extra_commits_check`·`archive_publish_content_check` 를 건너뜁니다. 그래서
# precheck 통과 뒤 metadata cleanup commit 이 붙는 사이에 보호 경로를 바꾼 커밋이 HEAD 를
# 전진시키면, tag/push 가 잘 결속된 `PUBLISH_OID` 그 자체가 미검토 코드를 담습니다.
# 이 블록은 그 창이 닫혀 있는지를 봅니다. fixture 는 git 로컬 연산 몇 번이라 1초 미만입니다.
echo "== 발행 직전 재결속 (no-fr) =="
RB_REPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$RB_REPO" && -d "$RB_REPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
RB_REPO="$(cd "$RB_REPO" && pwd -P)"
git -C "$RB_REPO" init -q -b main
git -C "$RB_REPO" config user.email t@t && git -C "$RB_REPO" config user.name t
mkdir -p "$RB_REPO/rd-workflow-workspace/.lifecycle/review-seals" "$RB_REPO/rd-workflow-workspace/backlog"
printf '# Current Task\n\n## Short Title\n-\n' > "$RB_REPO/CURRENT_TASK.md"
printf 'code\n' > "$RB_REPO/src.txt"
git -C "$RB_REPO" add -A && git -C "$RB_REPO" commit -q -m seed

RB_SID="20260906_010000_final-diff-review"
RB_TS="$RB_REPO/rd-workflow-workspace/.lifecycle/task-state"
RB_SEAL="$RB_REPO/rd-workflow-workspace/.lifecycle/review-seals/${RB_SID}.seal"
# 구현 커밋 → 그 트리로 마커 작성 → 포인터+마커 기록 커밋 (기록 경로라 보호 해시 불변).
printf 'work\n' >> "$RB_REPO/src.txt"
git -C "$RB_REPO" add -A && git -C "$RB_REPO" commit -q -m "구현"
RB_HASH="$( ( project_root="$RB_REPO"; rd_protected_tree_hash "HEAD" ) )"
printf 'schema=1\nsession-id=%s\nreview-type=diff-review\ntree-hash=%s\nhead=%s\nbranch-mode=no-fr\nfr-branch=null\nrd-version=unknown\nverified=yes\nsealed-at=2026-09-06-0100\n' \
  "$RB_SID" "$RB_HASH" "$(git -C "$RB_REPO" rev-parse HEAD)" > "$RB_SEAL"
printf 'schema=1\nshort-title=rbtask\nstatus=구현 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\ncreated-at=2026-09-06-0000\nreview-session=%s\n' \
  "$RB_SID" > "$RB_TS"
git -C "$RB_REPO" add -A && git -C "$RB_REPO" commit -q -m "기록 커밋 (포인터 + 마커)"

# precheck 를 **현재 셸에서** 돌립니다 — 승인 해시가 전역으로 나오는지가 검사 대상이라
# 서브셸로 감싸면 그 전달 자체를 확인할 수 없습니다.
_rb_saved_root="${project_root:-}"; _rb_saved_ts="${TASK_STATE_PATH:-}"
project_root="$RB_REPO"; TASK_STATE_PATH="$RB_TS"
_rb_rc=0
archive_review_precheck 0 "" "rbtask" "$RB_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" "null" \
  >/dev/null 2>&1 || _rb_rc=1
assert_eq "$_rb_rc" "0" "재결속 — no-fr precheck 통과 (sanity)"
assert_eq "$RD_ARCHIVE_REVIEWED_TREE_HASH" "$RB_HASH" "재결속 — precheck 가 승인한 보호 트리 해시를 밖으로 노출"
RB_APPROVED="$RD_ARCHIVE_REVIEWED_TREE_HASH"

# 정상 경로: cleanup commit 처럼 **기록 경로만** 바뀐 채 HEAD 가 전진하면 그대로 통과.
# 이 케이스가 없으면 아래 차단 케이스가 "무엇이든 다 막는다" 로도 통과합니다.
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\ncreated-at=2026-09-06-0000\n' > "$RB_TS"
git -C "$RB_REPO" add -A && git -C "$RB_REPO" commit -q -m "chore(lifecycle): metadata 정리"
_rb_rc=0
archive_publish_rebind_check "$RB_APPROVED" "$(git -C "$RB_REPO" rev-parse HEAD)" >/dev/null 2>&1 || _rb_rc=$?
assert_eq "$_rb_rc" "0" "재결속 — 기록 경로만 바뀐 cleanup commit 은 통과"

# 회귀 케이스: precheck 이후 보호 경로를 바꾼 커밋이 HEAD 를 전진시키면 tag/push 전에 차단.
printf 'sneaky\n' >> "$RB_REPO/src.txt"
git -C "$RB_REPO" add -A && git -C "$RB_REPO" commit -q -m "다른 프로세스의 보호 경로 커밋"
_rb_rc=0
archive_publish_rebind_check "$RB_APPROVED" "$(git -C "$RB_REPO" rev-parse HEAD)" >/dev/null 2>&1 || _rb_rc=$?
assert_eq "$_rb_rc" "1" "재결속 — precheck 이후 보호 경로 커밋이 얹히면 차단"

# fail-closed: 판정에 필요한 값이 없거나 해시를 못 구하면 통과가 아니라 판정 불가(rc 2).
_rb_rc=0
archive_publish_rebind_check "" "$(git -C "$RB_REPO" rev-parse HEAD)" >/dev/null 2>&1 || _rb_rc=$?
assert_eq "$_rb_rc" "2" "재결속 — 승인 해시 부재는 통과가 아니라 판정 불가"
_rb_rc=0
archive_publish_rebind_check "$RB_APPROVED" "refs/heads/does-not-exist" >/dev/null 2>&1 || _rb_rc=$?
assert_eq "$_rb_rc" "2" "재결속 — 발행 대상 해시 계산 실패는 판정 불가"

project_root="$_rb_saved_root"; TASK_STATE_PATH="$_rb_saved_ts"
rm -rf "$RB_REPO"

# commit_has_archive_signal (review-gate-iteration-commit)
echo "== commit_has_archive_signal =="
SIG_REPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$SIG_REPO" && -d "$SIG_REPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
git -C "$SIG_REPO" init -q
git -C "$SIG_REPO" config user.email t@t && git -C "$SIG_REPO" config user.name t
mkdir -p "$SIG_REPO/rd-workflow-workspace/backlog/request-archive" "$SIG_REPO/rd-workflow-workspace/.lifecycle"
printf '# Current Task\n\n## Status\n구현 중\n\n## Short Title\nsigtask\n' > "$SIG_REPO/CURRENT_TASK.md"
# v2 2b: task-state 격리 — TASK_STATE_PATH를 SIG_REPO 기반으로 재설정
TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"
# task-state 초기값: 구현 중, short-title=sigtask (비-baseline)
printf 'schema=1\nshort-title=sigtask\nstatus=구현 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
ARCH="rd-workflow-workspace/backlog/request-archive/2026-05-24-0000-sigtask.md"
# 신호 없음: 비-baseline + staged archive 없음 → 1(허용)
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — 신호 없음 → 1(허용)"
# AS1 경계: untracked stale archive 파일(add 안 함) → 1(허용, false-positive 방지)
printf 'x\n' > "$SIG_REPO/$ARCH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — AS1 untracked stale archive → 1(허용)"
# AS1: staged 추가 → 0(차단)
git -C "$SIG_REPO" add "$ARCH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "0" "archive_signal — AS1 staged request-archive 추가 → 0(차단)"
# AS1 경계: 기존 archive 파일 삭제(staged D) → 1(허용, 추가 아님)
git -C "$SIG_REPO" commit -q -m seed
git -C "$SIG_REPO" rm -q "$ARCH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "1" "archive_signal — request-archive 삭제(staged D) → 1(허용)"
# AS2: task-state baseline(status=대기 중, short-title=-) → 0(차단)
# v2 2b: task-state가 권위 소스 — CURRENT_TASK.md 변경과 함께 task-state도 베이스라인으로 설정
printf '# Current Task\n\n## Status\n대기 중\n\n## Short Title\n-\n' > "$SIG_REPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' > "$TASK_STATE_PATH"
( project_root="$SIG_REPO"; TASK_STATE_PATH="$SIG_REPO/rd-workflow-workspace/.lifecycle/task-state"; commit_has_archive_signal ) && rc=0 || rc=1
assert_eq "$rc" "0" "archive_signal — AS2 task-state baseline → 0(차단)"
rm -rf "$SIG_REPO"

echo "== archive_gate hook exit code =="
AG_REPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$AG_REPO" && -d "$AG_REPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
mkdir -p "$AG_REPO/rd-workflow/scripts/hooks" "$AG_REPO/rd-workflow/scripts" "$AG_REPO/rd-workflow-workspace/handoffs/review_pipeline" "$AG_REPO/rd-workflow-workspace/backlog/items"
cp "$REPO_ROOT/rd-workflow/scripts/hooks/_guard_common.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
cp "$REPO_ROOT/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
# _guard_common.sh가 상위 디렉토리의 _state_common.sh를 source하므로 함께 복사 (v2 2b)
cp "$REPO_ROOT/rd-workflow/scripts/_state_common.sh" "$AG_REPO/rd-workflow/scripts/"
printf '# Current Task\n\n## Short Title\nagtask\n' > "$AG_REPO/CURRENT_TASK.md"
printf '# Change Request\n\n## Source FR\n2026-05-15-agtask\n' > "$AG_REPO/REQUEST.md"
printf '# agtask\n- status: idea\n' > "$AG_REPO/rd-workflow-workspace/backlog/items/2026-05-15-agtask.md"
ag_mk_session() {
  local d="$AG_REPO/rd-workflow-workspace/handoffs/review_pipeline/$1"; mkdir -p "$d"
  printf '## Status\n%s\n\n## Branch Context\n- short-title: %s\n' "$2" "$4" > "$d/SESSION.md"
  printf '## Open Issues\n%s\n' "$3" > "$d/CHECKPOINT.md"
}
run_ag() {
  printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
    | bash "$AG_REPO/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh" >/dev/null 2>&1; echo $?
}
ag_mk_session "20260301_000000_final-diff-review" "closed" "- 없음" "agtask"
touch "$AG_REPO/.autopilot_active"
assert_eq "$(run_ag)" "2" "archive_gate — autopilot active + 종결 + FR not done → 차단"
rm -f "$AG_REPO/.autopilot_active"
printf '# agtask\n- status: done\n' > "$AG_REPO/rd-workflow-workspace/backlog/items/2026-05-15-agtask.md"
assert_eq "$(run_ag)" "0" "archive_gate — FR done → 통과"
rm -rf "$AG_REPO"

echo "== archive.sh dry-run 비파괴성 (precheck 배치) =="
# review precheck(audit write 가능)는 dry-run exit 뒤에 있어야 dry-run --force-skip-review-check 가 audit log를 오염시키지 않는다.
ARCHIVE_SH="$REPO_ROOT/rd-workflow/scripts/lifecycle/archive.sh"
dry_ln="$(grep -n 'DRY_RUN.*-eq 1' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
pc_ln="$(grep -n 'archive_review_precheck "' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$dry_ln" && -n "$pc_ln" && "$pc_ln" -gt "$dry_ln" ]]; then
  PASS=$((PASS+1)); echo "  PASS: archive_review_precheck($pc_ln) 가 dry-run exit($dry_ln) 뒤 — dry-run 비파괴"
else
  FAIL=$((FAIL+1)); echo "  FAIL: precheck($pc_ln) 가 dry-run($dry_ln) 앞 — dry-run audit 오염 위험" >&2
fi
# fr_ref 배선 회귀 (archive-precheck-premerge-session-visibility): precheck 호출이 $FR_BRANCH 를 5번째 인자로 전달하는지
pc_wire="$(grep -E 'archive_review_precheck "' "$ARCHIVE_SH" | head -1)"
if printf '%s' "$pc_wire" | grep -q '"\$AUDIT_LOG" "\$FR_BRANCH"'; then
  PASS=$((PASS+1)); echo "  PASS: archive.sh precheck 호출이 \$FR_BRANCH 를 5번째 인자로 전달"
else
  FAIL=$((FAIL+1)); echo "  FAIL: archive.sh precheck 호출에 \$FR_BRANCH(5번째 인자) 누락 — [$pc_wire]" >&2
fi
# 순서 불변식 (미러 확정 → metadata 정리): 실패 주입 테스트가 어려운 대신 배선으로 고정한다.
#   외부 도구 없이 "baseline 생성 실패" 를 fixture 에서 재현하려면 워킹트리를 쓰기 불가로
#   만들어야 하는데, 그러면 Step 4 이전의 merge 부터 실패해 이 경로에 도달하지 못한다.
#   따라서 순서 자체를 소스에서 검증한다 — 이 순서가 뒤집히면 미러 실패가 복구 불가가 된다.
_ord_mirror="$(grep -n '_ct_tmp' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
_ord_clear="$(grep -n '^  metadata_clear$' "$ARCHIVE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$_ord_mirror" && -n "$_ord_clear" && "$_ord_mirror" -lt "$_ord_clear" ]]; then
  PASS=$((PASS+1)); echo "  PASS: archive.sh 미러 확정이 metadata_clear 보다 앞선다 (순서 불변식)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: archive.sh 순서 불변식 위반 — mirror=$_ord_mirror clear=$_ord_clear" >&2
fi

echo "== archive.sh force-skip audit 기록 실패 → tag/push 전 정지 =="
#
# 우회 경로(`--force-skip-review-check`)의 audit 기록은 그 발행의 **유일한 흔적**입니다.
# 기록이 불가능한데도 발행이 이어지면, 리뷰 검증을 명시적으로 건너뛴 tag/push 가 사유
# 한 줄 없이 남습니다 (final diff review turn 004 Finding 1). 여기서는 헬퍼를 직접 부르지
# 않고 **실제 archive.sh 호출 경로**에서 그 정지를 봅니다 — 배선이 빠지면 헬퍼만 고쳐도
# 발행은 계속되기 때문입니다.
#
# 실패는 권한이 아니라 경로 형태(audit 파일 자리에 디렉터리)로 만듭니다 — root 실행에서도
# 결과가 같아야 합니다.
#
# 비용: fixture 2개가 실제 archive 를 끝까지 돌리므로 이 블록만 수 초입니다. 헬퍼 단위
# 테스트(test_guard_state.sh fixture 10)로는 "차단이 tag/push 앞에 있는가" 를 증명할 수
# 없어 그 비용을 집니다 — 통제군이 tag·push 까지 실제로 도달하는 것이 판정의 근거입니다.
AUD_TMP="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$AUD_TMP" && -d "$AUD_TMP" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
AUD_TMP="$(cd "$AUD_TMP" && pwd -P)"
_ast_cleanup+=("$AUD_TMP")
AUD_REL="rd-workflow-workspace/.lifecycle/review-skip-audit.log"

mk_aud_repo() { # mk_aud_repo <경로> — fr 브랜치 + 로컬 bare remote 를 갖춘 archive 대상
  local r="$1"
  mkdir -p "$r/rd-workflow-workspace/.lifecycle"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf 'code\n' > "$r/src.txt"
  printf '# Current Task\n\n## Short Title\naudittask\n' > "$r/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=audittask\nstatus=아카이브 보류\nfr-branch=fr/audittask\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
    > "$r/$(dirname "$AUD_REL")/task-state"
  git -C "$r" add -A; git -C "$r" commit -q -m seed
  git -C "$r" switch -q -c fr/audittask
  printf 'work\n' >> "$r/src.txt"
  printf '# Change Request\n' > "$r/REQUEST.md"
  git -C "$r" add -A; git -C "$r" commit -q -m "구현"
  git -C "$r" switch -q main
  git init -q --bare "$r.git"
  git -C "$r" remote add origin "$r.git"
  git -C "$r" push -q origin main
}
# archive.sh 는 cwd 의 저장소를 대상으로 삼으므로 fixture 안에 사본을 두지 않고 그대로 부릅니다.
# 스위트가 앞서 세운 project_root·TASK_STATE_PATH 가 export 되어 있으면 대상이 뒤바뀌므로 지웁니다.
run_aud_archive() { # run_aud_archive <경로> — rc 를 stdout 에 낸다
  local r="$1" rc=0
  ( cd "$r" && env -u project_root -u TASK_STATE_PATH -u STATE_MIGRATION_BACKUP_DIR \
      bash "$ARCHIVE_SH" --force-skip-review-check "긴급 발행" \
  ) >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# 통제군 — audit 을 남길 수 있으면 우회 경로를 통과해 발행이 tag·push 까지 끝난다.
# (이 단언들이 없으면 아래 차단 케이스가 "fixture 가 그냥 망가져서" 통과한다.)
AUD_OK="$AUD_TMP/ok"; mk_aud_repo "$AUD_OK"
assert_eq "$(run_aud_archive "$AUD_OK")" "0" "archive.sh — audit 가능하면 발행이 끝까지 진행 (통제군)"
assert_eq "$(awk -F' \\| ' 'END{print $3}' "$AUD_OK/$AUD_REL" 2>/dev/null)" \
  "긴급 발행" "archive.sh — 우회 사유가 audit 에 기록 (통제군)"
assert_eq "$(git -C "$AUD_OK.git" tag -l | wc -l | tr -d ' ')" "1" "archive.sh — 통제군은 tag 를 push 한다"

# 차단군 — audit 파일 자리에 디렉터리를 두어 append 를 불가능하게 만든다.
AUD_NG="$AUD_TMP/ng"; mk_aud_repo "$AUD_NG"
mkdir -p "$AUD_NG/$AUD_REL"
AUD_SEED="$(git -C "$AUD_NG.git" rev-parse main)"
assert_eq "$(run_aud_archive "$AUD_NG")" "1" "archive.sh — audit 기록 불가 → nonzero 종료"
assert_eq "$(git -C "$AUD_NG" tag -l | wc -l | tr -d ' ')" "0" "archive.sh — audit 기록 불가 → 로컬 tag 미생성"
assert_eq "$(git -C "$AUD_NG.git" tag -l | wc -l | tr -d ' ')" "0" "archive.sh — audit 기록 불가 → remote tag push 없음"
assert_eq "$(git -C "$AUD_NG.git" rev-parse main)" "$AUD_SEED" "archive.sh — audit 기록 불가 → remote 기본 브랜치 push 없음"

rm -rf "$GUARD_ROOT"

# === safeguard-self-review-block: self-review 게이트 ===
source "$SCRIPT_DIR/../review_common.sh"

echo "== resolve_self_review_policy =="
assert_eq "$(resolve_self_review_policy block "")" "block" "policy=block 그대로"
assert_eq "$(resolve_self_review_policy warn "")"  "warn"  "policy=warn 그대로"
assert_eq "$(resolve_self_review_policy off "")"   "off"   "policy=off 그대로"
assert_eq "$(resolve_self_review_policy "" false)" "off"   "미설정(빈값)+warning=false → off"
assert_eq "$(resolve_self_review_policy "" true)"  "block" "미설정(빈값)+warning=true → block"
assert_eq "$(resolve_self_review_policy "" "")"    "block" "미설정(빈값)+warning 미설정 → block"
assert_eq "$(resolve_self_review_policy bogus "")" "block" "미인식 policy + warning 빈값 → block (fail-safe)"
assert_eq "$(resolve_self_review_policy bogus false)" "block" "미인식 policy + warning=false → block (finding1 회귀방지)"

echo "== evaluate_self_review_gate =="
assert_eq "$(evaluate_self_review_gate off "" "")"   "proceed-silent"    "off → silent"
assert_eq "$(evaluate_self_review_gate warn "" "")"  "proceed-warn"      "warn → warn"
assert_eq "$(evaluate_self_review_gate block 1 "")"  "proceed-autopilot" "block+autopilot → autopilot"
assert_eq "$(evaluate_self_review_gate block "" 1)"  "proceed-warn"      "block+approve → warn"
assert_eq "$(evaluate_self_review_gate block "" "")" "block"             "block+일반 → block"
assert_eq "$(evaluate_self_review_gate block 1 1)"   "proceed-autopilot" "block+autopilot이 approve보다 우선"

echo "== record_self_review_block =="
SR_UA="$(mktemp)" || { echo "test_lifecycle.sh: 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$SR_UA" && -f "$SR_UA" ]] || { echo "test_lifecycle.sh: 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
# 기본 USER_ACTION 템플릿(차단 안내가 지워져야 하는 문구 포함)
printf '# User Action\n\n## Current Recommendation\n-\n\n## Why\n- \n\n## Question For User\n아직 사용자 확인이 필요한 단계가 아닙니다.\n' > "$SR_UA"
record_self_review_block "$SR_UA"
if grep -q "RD_SELF_REVIEW_APPROVE=1" "$SR_UA"; then PASS=$((PASS+1)); echo "  PASS: 승인 재실행 안내 포함"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: 승인 안내 누락" >&2; fi
if grep -q "아직 사용자 확인이 필요한 단계가 아닙니다" "$SR_UA"; then \
  FAIL=$((FAIL+1)); echo "  FAIL: 기본 no-action 문구가 남아 모순(finding3)" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: no-action 문구 제거됨"; fi
sr_snap1="$(cat "$SR_UA")"
record_self_review_block "$SR_UA"
sr_snap2="$(cat "$SR_UA")"
assert_eq "$sr_snap1" "$sr_snap2" "멱등 — 재호출 시 내용 동일"
rm -f "$SR_UA"

echo "== run_review_turn.sh self-review 차단 (script-level 통합) =="
SR_INT="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$SR_INT" && -d "$SR_INT" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
mkdir -p "$SR_INT/bin" "$SR_INT/session/turns"
# fake claude: 게이트가 block이면 호출되지 않아야 함 (호출되면 흔적 파일 생성)
cat > "$SR_INT/bin/claude" <<FAKE
#!/bin/sh
touch "$SR_INT/CLAUDE_WAS_CALLED"
exit 99
FAKE
chmod +x "$SR_INT/bin/claude"
# 임시 config: claude만 우선, policy=block
cat > "$SR_INT/review-tools.json" <<'CFG'
{ "default_priority": ["claude"], "tools": { "claude": { "self_review_policy": "block" } } }
CFG
# 최소 세션 fixture (Branch Context 생략 → validate_branch_context가 legacy로 skip)
cat > "$SR_INT/session/SESSION.md" <<'SES'
# Review Session
## Status
awaiting-reviewer
## Current Owner
Reviewer
## Review Type
spec-plan-review
## Review Target
target
## Review Goal
goal
## Turn Limit
20 total turns in `turns/*.md`
SES
printf '# Checkpoint\n## Current Summary\n-\n' > "$SR_INT/session/CHECKPOINT.md"
printf '# User Action\n\n## Current Recommendation\n-\n\n## Why\n- \n\n## Question For User\n아직 사용자 확인이 필요한 단계가 아닙니다.\n' > "$SR_INT/session/USER_ACTION.md"
printf '# Turn 001 Author\n' > "$SR_INT/session/turns/001_author.md"
# 일반 모드 실행 (RD_AUTOPILOT / RD_SELF_REVIEW_APPROVE 미설정)
sr_rc=0
PATH="$SR_INT/bin:$PATH" REVIEW_TOOLS_CONFIG="$SR_INT/review-tools.json" \
  RD_AUTOPILOT="" RD_SELF_REVIEW_APPROVE="" \
  bash "$SCRIPT_DIR/../run_review_turn.sh" "$SR_INT/session" >/dev/null 2>&1 || sr_rc=$?
assert_eq "$sr_rc" "3" "차단 exit code 3"
if [ ! -f "$SR_INT/session/turns/002_reviewer.md" ]; then PASS=$((PASS+1)); echo "  PASS: reviewer turn 미생성"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: reviewer turn 생성됨" >&2; fi
if grep -q "RD_SELF_REVIEW_APPROVE=1" "$SR_INT/session/USER_ACTION.md"; then PASS=$((PASS+1)); echo "  PASS: USER_ACTION 차단 안내 기록"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: USER_ACTION 차단 안내 누락" >&2; fi
assert_eq "$(awk '/^## Status/{getline; gsub(/[ \t]/,"",$0); print; exit}' "$SR_INT/session/SESSION.md")" "awaiting-reviewer" "SESSION Status awaiting-reviewer 유지"
if [ ! -f "$SR_INT/CLAUDE_WAS_CALLED" ]; then PASS=$((PASS+1)); echo "  PASS: fake claude 미호출(게이트가 adapter 전 차단)"; \
  else FAIL=$((FAIL+1)); echo "  FAIL: claude adapter 실행됨" >&2; fi
rm -rf "$SR_INT"

# === get_default_branch resolver (lifecycle-default-branch-generalize) ===
echo "== get_default_branch resolver =="
GDB_TMP="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$GDB_TMP" && -d "$GDB_TMP" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
make_gdb_repo() {  # <dir> <initial-branch>
  local d="$1" b="$2"
  mkdir -p "$d"
  ( cd "$d" && { git init -q -b "$b" 2>/dev/null || { git init -q; git checkout -q -b "$b"; }; } \
    && git config user.email t@example.com && git config user.name t \
    && git commit -q --allow-empty -m init )
}
gdb_in() { ( cd "$1" && unset project_root && get_default_branch 2>/dev/null ); }

# case 1: config 최우선 (브랜치 실존 여부와 무관하게 config 값 채택)
R="$GDB_TMP/c1"; make_gdb_repo "$R" main
mkdir -p "$R/rd-workflow/config"
printf '{\n  "default_branch": "trunk"\n}\n' > "$R/rd-workflow/config/workflow.json"
assert_eq "$(gdb_in "$R")" "trunk" "config default_branch 최우선"

# case 2: 빈 config 값("")은 미설정 — 다음 체인 진행 (master 유일 매치)
R="$GDB_TMP/c2"; make_gdb_repo "$R" master
mkdir -p "$R/rd-workflow/config"
printf '{\n  "default_branch": ""\n}\n' > "$R/rd-workflow/config/workflow.json"
assert_eq "$(gdb_in "$R")" "master" "빈 config 값 → 자동 검출 fallthrough"

# case 3: origin/HEAD 검출
R="$GDB_TMP/c3"; make_gdb_repo "$R" main
( cd "$R" && git update-ref refs/remotes/origin/devel HEAD \
  && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/devel )
assert_eq "$(gdb_in "$R")" "devel" "origin/HEAD 검출"

# case 4: 로컬 유일 매치 (master만 존재)
R="$GDB_TMP/c4"; make_gdb_repo "$R" master
assert_eq "$(gdb_in "$R")" "master" "main/master 유일 매치"

# case 5: 모호 (main+master 동시 존재) → 에러
R="$GDB_TMP/c5"; make_gdb_repo "$R" main
( cd "$R" && git branch master )
if gdb_in "$R" >/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: 모호 케이스에서 성공 반환" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: main/master 동시 존재 시 에러"; fi

# case 6: 후보 전무 → 에러
R="$GDB_TMP/c6"; make_gdb_repo "$R" work
if gdb_in "$R" >/dev/null; then FAIL=$((FAIL+1)); echo "  FAIL: 후보 전무에서 성공 반환" >&2; \
  else PASS=$((PASS+1)); echo "  PASS: 후보 전무 시 에러"; fi

# get_main_worktree_path 일반화: master 유일 repo에서 해당 worktree path 반환
R="$GDB_TMP/c7"; make_gdb_repo "$R" master
assert_eq "$( cd "$R" && get_main_worktree_path )" "$( cd "$R" && pwd -P )" "get_main_worktree_path master 일반화"

rm -rf "$GDB_TMP"

echo "== registration_commit_shape / classify_ahead_commits =="
RCS_TMP="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$RCS_TMP" && -d "$RCS_TMP" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
RCS_TMP="$(cd "$RCS_TMP" && pwd -P)"
_ast_cleanup+=("$RCS_TMP")
_rcs_idx="rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
make_rcs_repo() { # make_rcs_repo <dir>
  mkdir -p "$1" && ( cd "$1" && git init -q && git checkout -q -b main 2>/dev/null; \
    git config user.email t@e.com; git config user.name t; \
    mkdir -p rd-workflow-workspace/backlog/items rd-workflow-workspace/raw-captures; \
    printf '# FR\n\n## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |\n|---|---|---|---|---|---|---|\n| 2026-01-01 | base-a | a | tooling | idea | - | [상세](items/2026-01-01-base-a.md) |\n' > "$_rcs_idx"; \
    printf '# base-a\n- status: idea\n' > rd-workflow-workspace/backlog/items/2026-01-01-base-a.md; \
    git add -A && git commit -q -m init )
}
rcs_reg_commit() { # rcs_reg_commit <dir> <slug> [with-capture=1] [요약=s] — 등록 커밋 형태의 커밋 1개
  ( cd "$1" && printf '| 2026-02-02 | %s | %s | tooling | idea | - | [상세](items/2026-02-02-%s.md) |\n' "$2" "${4:-s}" "$2" >> "$_rcs_idx" \
    && printf '# %s\n- status: idea\n' "$2" > "rd-workflow-workspace/backlog/items/2026-02-02-$2.md" \
    && { [[ "${3:-1}" == 1 ]] && mkdir -p rd-workflow-workspace/raw-captures && printf -- '---\nstage: fr\n---\n' > "rd-workflow-workspace/raw-captures/2026-02-02-fr-$2.md" || true; } \
    && git add -A && git commit -q -m "docs: FR 등록 — $2" )
}
R="$RCS_TMP/r1"; make_rcs_repo "$R"
rcs_reg_commit "$R" foo
assert_eq "$( cd "$R" && registration_commit_shape HEAD )" "foo" "shape: 행1+상세1+캡처1 → slug"
rcs_reg_commit "$R" bar 0
assert_eq "$( cd "$R" && registration_commit_shape HEAD )" "bar" "shape: 캡처 없음도 통과"
# 요약에 이스케이프된 파이프가 든 등록 행 — `/fr add` 규약이 요구하는 형태다. 컬럼 수를 raw `|` 로
# 세면 헤더보다 많다고 오판해 정상 등록 커밋이 비등록으로 떨어지고 시작 계약의 자동 채택이 막힌다.
# (merge_fr_index.sh 의 xsplit() 와 같은 계약 — 한쪽만 고치면 갈린다)
rcs_reg_commit "$R" esc 0 '`x \| y` 를 셈'
assert_eq "$( cd "$R" && registration_commit_shape HEAD )" "esc" "shape: 요약의 이스케이프된 \| 는 구분자가 아니다"
# 음성 대조: 이스케이프되지 않은 생 | 가 든 행은 GFM 에서도 칸이 쪼개지므로 계속 거부한다
rcs_reg_commit "$R" raw 0 '`x | y` 를 셈'
if ( cd "$R" && registration_commit_shape HEAD >/dev/null ); then FAIL=$((FAIL+1)); echo "  FAIL: shape: 요약의 생 | 를 통과시킴" >&2; else PASS=$((PASS+1)); echo "  PASS: shape: 요약의 생 | → 거부"; fi
# 음성: 등록 경로 외 파일 동반
( cd "$R" && printf '| 2026-02-03 | baz | s | tooling | idea | - | [상세](items/2026-02-03-baz.md) |\n' >> "$_rcs_idx" \
  && printf '# baz\n' > rd-workflow-workspace/backlog/items/2026-02-03-baz.md && echo x > other.txt && git add -A && git commit -q -m mixed )
if ( cd "$R" && registration_commit_shape HEAD >/dev/null ); then FAIL=$((FAIL+1)); echo "  FAIL: shape: 등록 경로 외 파일 섞임을 통과시킴" >&2; else PASS=$((PASS+1)); echo "  PASS: shape: 등록 경로 외 파일 섞임 → 거부"; fi
# 음성: 기존 행 수정(상태 변경)
( cd "$R" && sed 's/| base-a | a | tooling | idea |/| base-a | a | tooling | validated |/' "$_rcs_idx" > "$_rcs_idx.n" && mv "$_rcs_idx.n" "$_rcs_idx" && git add -A && git commit -q -m status )
if ( cd "$R" && registration_commit_shape HEAD >/dev/null ); then FAIL=$((FAIL+1)); echo "  FAIL: shape: 기존 행 수정을 통과시킴" >&2; else PASS=$((PASS+1)); echo "  PASS: shape: 기존 행 수정 → 거부"; fi
# 음성: merge 커밋 (등록 파일만 보여도 부모 2개)
( cd "$R" && git checkout -q -b side && printf '| 2026-02-04 | qux | s | tooling | idea | - | [상세](items/2026-02-04-qux.md) |\n' >> "$_rcs_idx" \
  && printf '# qux\n' > rd-workflow-workspace/backlog/items/2026-02-04-qux.md && git add -A && git commit -q -m qux \
  && git checkout -q main && git merge -q --no-ff side -m merge )
if ( cd "$R" && registration_commit_shape HEAD >/dev/null ); then FAIL=$((FAIL+1)); echo "  FAIL: shape: merge 커밋을 통과시킴" >&2; else PASS=$((PASS+1)); echo "  PASS: shape: merge 커밋 → 거부"; fi
# 음성: helper 산출물보다 넓은 형태 4종 — 중첩 상세 경로 / symlink 상세 / 링크 불일치 / 표 아닌 줄
rcs_neg() { # rcs_neg <desc> <setup-cmds...>: 커밋 후 shape 거부를 단언
  local desc="$1"; shift
  ( cd "$R" && eval "$*" && git add -A && git commit -q -m neg ) >/dev/null 2>&1
  if ( cd "$R" && registration_commit_shape HEAD >/dev/null ); then FAIL=$((FAIL+1)); echo "  FAIL: shape: $desc 를 통과시킴" >&2; else PASS=$((PASS+1)); echo "  PASS: shape: $desc → 거부"; fi
}
rcs_neg "중첩 상세 경로" 'printf "| 2026-02-07 | n1 | s | tooling | idea | - | [상세](items/2026-02-07-n1.md) |\n" >> "$_rcs_idx" && mkdir -p rd-workflow-workspace/backlog/items/nested && printf "# n1\n" > rd-workflow-workspace/backlog/items/nested/2026-02-07-n1.md'
rcs_neg "symlink 상세(mode 120000)" 'printf "| 2026-02-08 | n2 | s | tooling | idea | - | [상세](items/2026-02-08-n2.md) |\n" >> "$_rcs_idx" && ln -s ../../../README.md rd-workflow-workspace/backlog/items/2026-02-08-n2.md'
rcs_neg "행의 상세 링크가 추가 상세와 불일치" 'printf "| 2026-02-09 | n3 | s | tooling | idea | - | [상세](items/2026-02-09-other.md) |\n" >> "$_rcs_idx" && printf "# n3\n" > rd-workflow-workspace/backlog/items/2026-02-09-n3.md'
rcs_neg "표 아닌 한 줄 추가" 'printf "<!-- n4 -->\n" >> "$_rcs_idx" && printf "# n4\n" > rd-workflow-workspace/backlog/items/2026-02-10-n4.md'

# classify_ahead_commits — bare upstream 으로 ahead/behind 상태 구성
R2="$RCS_TMP/r2"; make_rcs_repo "$R2"; B2="$RCS_TMP/r2.git"; git init -q --bare "$B2"
( cd "$R2" && git remote add origin "$B2" && git push -q -u origin main )
assert_eq "$( cd "$R2" && classify_ahead_commits refs/heads/main refs/remotes/origin/main )" "ahead=0 behind=0 registration=0 decision=synchronized" "classify: synchronized"
rcs_reg_commit "$R2" a1; rcs_reg_commit "$R2" a2 0 '`x \| y` 요약'
assert_eq "$( cd "$R2" && classify_ahead_commits refs/heads/main refs/remotes/origin/main )" "ahead=2 behind=0 registration=2 decision=auto-adopt" "classify: 등록 커밋 2개(하나는 이스케이프된 \| 요약) → auto-adopt (AC 14a)"
( cd "$R2" && sed 's/| a1 | s | tooling | idea |/| a1 | s | tooling | validated |/' "$_rcs_idx" > "$_rcs_idx.n" && mv "$_rcs_idx.n" "$_rcs_idx" && git add -A && git commit -q -m status )
assert_eq "$( cd "$R2" && classify_ahead_commits refs/heads/main refs/remotes/origin/main )" "ahead=3 behind=0 registration=2 decision=handover-ahead" "classify: 상태 변경 커밋 섞임 → handover (AC 14b)"
( cd "$R2" && git reset -q --hard HEAD~1 && printf '| 2026-02-05 | a3 | s | tooling | idea | - | [상세](items/2026-02-05-a3.md) |\n' >> "$_rcs_idx" && printf '# a3\n' > rd-workflow-workspace/backlog/items/2026-02-05-a3.md && echo y > other.txt && git add -A && git commit -q -m mixed )
assert_eq "$( cd "$R2" && classify_ahead_commits refs/heads/main refs/remotes/origin/main )" "ahead=3 behind=0 registration=2 decision=handover-ahead" "classify: 등록 경로 외 파일 섞인 커밋 → handover (AC 14c)"
( cd "$R2" && git reset -q --hard HEAD~1 && git checkout -q -b side2 && printf '| 2026-02-06 | a4 | s | tooling | idea | - | [상세](items/2026-02-06-a4.md) |\n' >> "$_rcs_idx" && printf '# a4\n' > rd-workflow-workspace/backlog/items/2026-02-06-a4.md && git add -A && git commit -q -m a4 && git checkout -q main && git merge -q --no-ff side2 -m merge )
assert_eq "$( cd "$R2" && classify_ahead_commits refs/heads/main refs/remotes/origin/main | sed 's/.*decision=//' )" "handover-ahead" "classify: merge 커밋 포함 → handover (AC 14d)"
( cd "$R2" && git reset -q --hard origin/main && git checkout -q -b tmp && rcs_reg_commit "$R2" b1 && git push -q origin tmp:main && git checkout -q main && git fetch -q )
assert_eq "$( cd "$R2" && classify_ahead_commits refs/heads/main refs/remotes/origin/main )" "ahead=0 behind=1 registration=0 decision=handover-behind" "classify: behind → handover"
assert_eq "$( cd "$R2" && classify_ahead_commits refs/heads/main "" )" "ahead=0 behind=0 registration=0 decision=no-upstream" "classify: upstream 부재"

# 조용한 중단 센티넬이 **끝까지 살아 있었는지**를 실행 시점에 확인합니다. bash 는 EXIT trap
# 을 하나만 갖고, 나중에 건 것이 앞의 것을 말없이 지웁니다 — 실제로 그 사고가 있었고
# (임시 디렉터리 정리 trap 이 센티넬을 덮어써 조용한 죽음 3형태가 전부 통과), 소스만 봐서는
# 드러나지 않았습니다. 이 단언이 실패하면 센티넬은 이미 없는 상태입니다.
# === seal 기록 경로 — raw-captures/ · reports/autopilot/ (change-spec §5.2·§5.3) ===
#
# 정규 마감 절차(캡처 이동 + autopilot 완료 보고)가 보호 트리를 건드리지 않는지, 그 면제가
# 코드까지 넓어지지 않았는지를 한 fixture 에서 봅니다.
#
# 비교하는 두 해시는 **언제나 같은 제외 정책**으로 계산합니다. 정상 정책의 이동 전 해시와
# 축소 정책의 이동 후 해시를 비교하면 두 변수가 동시에 달라져 아무것도 증명하지 못합니다.
echo "== seal 기록 경로 (raw-captures · reports/autopilot) =="
SR_REPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$SR_REPO" && -d "$SR_REPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
SR_REPO="$(cd "$SR_REPO" && pwd -P)"
_ast_cleanup+=("$SR_REPO")   # 최상위 EXIT trap 을 새로 걸지 않습니다 (30행 주석)
git -C "$SR_REPO" init -q -b main
git -C "$SR_REPO" config user.email t@t && git -C "$SR_REPO" config user.name t
mkdir -p "$SR_REPO/rd-workflow-workspace/.lifecycle/review-seals" \
         "$SR_REPO/rd-workflow-workspace/raw-captures" \
         "$SR_REPO/rd-workflow-workspace/reports/autopilot" \
         "$SR_REPO/rd-workflow-workspace/specs/changes" \
         "$SR_REPO/_ROOT_FILES/rd-workflow/scripts"
printf '# Current Task\n\n## Short Title\n-\n' > "$SR_REPO/CURRENT_TASK.md"
printf 'echo code\n'   > "$SR_REPO/_ROOT_FILES/rd-workflow/scripts/x.sh"
printf 'spec body\n'   > "$SR_REPO/rd-workflow-workspace/specs/changes/s.md"
printf 'capture body\n' > "$SR_REPO/rd-workflow-workspace/raw-captures/2026-09-10-request-srtask.md"
git -C "$SR_REPO" add -A && git -C "$SR_REPO" commit -q -m seed

# 구현 커밋.
printf 'echo work\n' >> "$SR_REPO/_ROOT_FILES/rd-workflow/scripts/x.sh"
git -C "$SR_REPO" add -A && git -C "$SR_REPO" commit -q -m "구현"

SR_SID="20260910_000000_final-diff-review"
SR_TS="$SR_REPO/rd-workflow-workspace/.lifecycle/task-state"
SR_SEAL="$SR_REPO/rd-workflow-workspace/.lifecycle/review-seals/${SR_SID}.seal"
SR_AUDIT="$SR_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log"

# sr_hash_pol <제외에서 뺄 항목|''> <commit> — 지정한 정책으로 그 커밋의 보호 트리 해시.
# 빈 문자열이면 정상 정책(11개). 옛 코드를 재현하는 것이 아니라 목록에서 항목이 지워지는
# 실제 회귀를 재현합니다.
sr_hash_pol() {
  ( project_root="$SR_REPO"
    if [[ -n "$1" ]]; then
      local _keep=() _i
      for _i in "${RD_RECORD_PATHS[@]}"; do
        [[ "$_i" == "$1" ]] || _keep+=("$_i")
      done
      RD_RECORD_PATHS=("${_keep[@]}")
    fi
    rd_protected_tree_hash "$2" )
}
# sr_differ <a> <b> — 이 스위트에 assert_ne 가 없으므로 assert_eq 위에 얹습니다.
sr_differ() { [[ "$1" != "$2" ]] && printf 'differ' || printf 'same'; }
# sr_write_seal <tree-hash> <head-oid> — 마커 10필드. rd-version 은 fixture 에 VERSION 이
# 없어 `_rd_version` 이 내는 값과 같은 `unknown` 을 씁니다.
sr_write_seal() {
  mkdir -p "$(dirname "$SR_SEAL")"
  printf 'schema=1\nsession-id=%s\nreview-type=diff-review\ntree-hash=%s\nhead=%s\nbranch-mode=no-fr\nfr-branch=null\nrd-version=unknown\nverified=yes\nsealed-at=2026-09-10-0000\n' \
    "$SR_SID" "$1" "$2" > "$SR_SEAL"
}
# sr_precheck_pol <제외에서 뺄 항목|''> — 지정한 정책으로 현재 HEAD 의 발행 직전 검증.
# rc 를 stdout 에 낸다. 마커를 만든 정책과 검증하는 정책이 어긋나면 관측이 혼합되므로,
# mutation 에서도 같은 정책을 씁니다.
sr_precheck_pol() {
  local _rc=0
  ( project_root="$SR_REPO"; TASK_STATE_PATH="$SR_TS"
    if [[ -n "$1" ]]; then
      local _keep=() _i
      for _i in "${RD_RECORD_PATHS[@]}"; do
        [[ "$_i" == "$1" ]] || _keep+=("$_i")
      done
      RD_RECORD_PATHS=("${_keep[@]}")
    fi
    archive_review_precheck 0 "" "srtask" "$SR_AUDIT" ) >/dev/null 2>&1 || _rc=1
  printf '%s' "$_rc"
}
sr_precheck() { sr_precheck_pol ''; }

SR_PRE="$(git -C "$SR_REPO" rev-parse HEAD)"
SR_HASH="$(sr_hash_pol '' "$SR_PRE")"
sr_write_seal "$SR_HASH" "$SR_PRE"
printf 'schema=1\nshort-title=srtask\nstatus=구현 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\ncreated-at=2026-09-10-0000\nreview-session=%s\n' \
  "$SR_SID" > "$SR_TS"
# 마커·포인터는 둘 다 기록 경로라 커밋해도 보호 트리 해시가 변하지 않습니다.
git -C "$SR_REPO" add -A && git -C "$SR_REPO" commit -q -m "기록 커밋 (포인터 + 마커)"
SR_PRE="$(git -C "$SR_REPO" rev-parse HEAD)"
assert_eq "$(sr_hash_pol '' "$SR_PRE")" "$SR_HASH" \
  "seal 기록경로 (전제) — 마커·포인터 기록 커밋은 보호 트리 해시를 바꾸지 않음"

# (a) 양성 — 마감 절차가 실제로 하는 일: 캡처를 archive/ 로 옮기고 완료 보고를 남긴다.
mkdir -p "$SR_REPO/rd-workflow-workspace/raw-captures/archive"
git -C "$SR_REPO" mv -f "rd-workflow-workspace/raw-captures/2026-09-10-request-srtask.md" \
                        "rd-workflow-workspace/raw-captures/archive/"
printf 'autopilot report\n' > "$SR_REPO/rd-workflow-workspace/reports/autopilot/2026-09-10-srtask.md"
git -C "$SR_REPO" add -A && git -C "$SR_REPO" commit -q -m "아카이브 기록 커밋"
SR_POST="$(git -C "$SR_REPO" rev-parse HEAD)"
assert_eq "$(sr_hash_pol '' "$SR_POST")" "$(sr_hash_pol '' "$SR_PRE")" \
  "seal 기록경로 (a) — 정상 정책에서 캡처 이동 + autopilot 보고 추가가 보호 트리 해시를 바꾸지 않음"

# (b) 연결 — 실제 seal 마커와 대조하는 발행 직전 검증까지 통과해야 한다.
#     경로 분류만 맞고 마커 대조가 끊긴 구현은 여기서 걸립니다.
assert_eq "$(sr_precheck)" "0" \
  "seal 기록경로 (b) — 그 상태에서 archive_review_precheck 통과"

# (c) 음성 — 리뷰된 코드가 바뀌면 여전히 차단되어야 한다 (게이트 목적 보존).
printf 'echo tampered\n' >> "$SR_REPO/_ROOT_FILES/rd-workflow/scripts/x.sh"
git -C "$SR_REPO" add -A && git -C "$SR_REPO" commit -q -m "코드 변경"
assert_eq "$(sr_differ "$(sr_hash_pol '' HEAD)" "$SR_HASH")" "differ" \
  "seal 기록경로 (c1) — _ROOT_FILES/ 코드 변경은 보호 트리 해시를 바꿈"
assert_eq "$(sr_precheck)" "1" \
  "seal 기록경로 (c2) — 코드 변경 후에는 archive_review_precheck 가 차단"
# 뒤 단계가 이 변경에 가려지지 않도록 SR_POST 로 되돌립니다.
git -C "$SR_REPO" reset -q --hard "$SR_POST"
assert_eq "$(sr_precheck)" "0" \
  "seal 기록경로 (c3) — SR_POST 복구 후 다시 통과 (뒤 단계의 기준선 회복 확인)"

# (d) mutation — 항목 하나를 뺀 정책에서는 마감 절차가 보호 트리를 깨뜨려야 한다.
#     다른 신규 경로는 정상 제외 상태로 두므로 실패 원인이 개별 식별됩니다.
sr_mutation_case() {  # <제외에서 뺄 항목> <라벨>
  local _item="$1" _label="$2" _pre _post
  _pre="$(sr_hash_pol "$_item" "$SR_PRE")"
  _post="$(sr_hash_pol "$_item" "$SR_POST")"
  assert_eq "$(sr_differ "$_pre" "$_post")" "differ" \
    "seal 기록경로 (d-${_label}-hash) — ${_item} 를 뺀 정책에서는 마감 절차가 보호 트리를 바꿈"
  # 그 정책의 이동 전 해시를 담은 마커로 발행 직전 검증 → 차단되어야 한다.
  sr_write_seal "$_pre" "$SR_PRE"
  git -C "$SR_REPO" add -A && git -C "$SR_REPO" commit -q -m "mutation 마커 (${_label})"
  assert_eq "$(sr_precheck_pol "$_item")" "1" \
    "seal 기록경로 (d-${_label}-precheck) — 같은 정책의 archive_review_precheck 가 차단"
  git -C "$SR_REPO" reset -q --hard "$SR_POST"
}
sr_mutation_case 'rd-workflow-workspace/raw-captures/'     'raw-captures'
sr_mutation_case 'rd-workflow-workspace/reports/autopilot/' 'reports-autopilot'
assert_eq "$(sr_precheck)" "0" \
  "seal 기록경로 (d-복구) — mutation 관측 후 정상 마커 상태로 복귀"

# (§5.3) 보호 대상 고정 목록 전수 대조 — 구현의 제외 목록을 읽지 않고 고정 경로를 직접 씁니다.
#        AC4 는 각 항목을 요구하며, 항목마다 문자열이 달라 하나의 결과가 나머지를 보장하지
#        않습니다. tripwire(record-paths 4b)는 목록 변경을 눈에 띄게 할 뿐 이 판정을 하지
#        않으므로 대체하지 못합니다.
sr_assert_protected() {  # <경로>
  local _r=protected
  ( project_root="$SR_REPO"; rd_path_is_record "$1" ) && _r=record
  assert_eq "$_r" "protected" "seal 기록경로 (5.3) — 보호 대상: $1"
}
sr_assert_protected "_ROOT_FILES/rd-workflow/scripts/_state_common.sh"
sr_assert_protected "_ROOT_FILES_LITE/rd-workflow/claude_skills/fr/add.md"
sr_assert_protected "rd-workflow/scripts/_state_common.sh"
sr_assert_protected "scripts/publish.sh"
sr_assert_protected "rd-workflow-workspace/specs/changes/x-change-spec.md"
sr_assert_protected "rd-workflow-workspace/plans/x-plan.md"
sr_assert_protected "CLAUDE.md"
sr_assert_protected "PROJECT_CONTEXT.md"
sr_assert_protected ".claude/settings.json"
# 대조 기준의 sanity — 실제 기록 경로는 record 로 잡혀야 합니다. 이것이 없으면 위 9건은
# `rd_path_is_record` 가 항상 false 를 내는 고장에도 전부 통과합니다.
sr_is_record() {
  local _r=protected
  ( project_root="$SR_REPO"; rd_path_is_record "$1" ) && _r=record
  printf '%s' "$_r"
}
assert_eq "$(sr_is_record 'rd-workflow-workspace/raw-captures/archive/a.md')" "record" \
  "seal 기록경로 (5.3-sanity) — raw-captures/archive/ 는 기록으로 판정"
assert_eq "$(sr_is_record 'rd-workflow-workspace/reports/autopilot/a.md')" "record" \
  "seal 기록경로 (5.3-sanity) — reports/autopilot/ 는 기록으로 판정"

echo "== promote.sh 재설계 — worktree 병렬 착수 (Task 4) =="
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# 실배포와 같은 진입점(rd-workflow/scripts/lifecycle/promote.sh · rd-workflow/scripts/rd)을
# 그대로 호출해야 하므로(테스트가 절대경로 literal 로 그것들을 부른다), $REPO 는 이
# dev repo 의 scripts/ 트리를 그대로 복사해 갖는다(문서·claude_skills 는 불필요해 제외).
REPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$REPO" && -d "$REPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
REPO="$(cd "$REPO" && pwd -P)"
_ast_cleanup+=("$REPO")
mkdir -p "$REPO/rd-workflow"
cp -R "$SCRIPT_DIR/.." "$REPO/rd-workflow/scripts"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
mkdir -p "$REPO/rd-workflow-workspace/.lifecycle" "$REPO/rd-workflow-workspace/backlog/items"
# 실배포 .gitignore 와 같은 계약 — .worktrees/ 는 ignored 다. 없으면 착수마다 만드는
# .worktrees/<slug> 가 untracked 로 잡혀 다음 호출의 clean 검증(1단계)이 항상 실패한다.
printf '.worktrees/\n' > "$REPO/.gitignore"
emit_current_task_baseline > "$REPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$REPO/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$REPO/REQUEST.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m seed

# promote 는 기본 브랜치에 커밋을 만들지 않는다
before="$(git -C "$REPO" rev-parse main)"
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title alpha --size large --source-fr -
after="$(git -C "$REPO" rev-parse main)"
[[ "$before" == "$after" ]] && pass "promote 가 기본 브랜치를 전진시키지 않는다" || fail "기본 브랜치 무커밋"

# 두 번째 작업이 첫 번째를 덮지 않고 성공한다
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title beta --size large --source-fr -
# beta 를 진행 상태로 만들어 둔다 — 뒤의 "(b) 진행된 권위" D11 케이스가 이 값을 쓴다.
# **여기서 지금 커밋해 둔다.** 뒤의 eta 케이스가 `rm -rf "$REPO/.worktrees"` 로 이
# 물리 디렉터리를 통째로 지우므로(자기 시나리오상 의도된 것), 그 뒤에는 이 경로에
# 더 이상 쓸 수 없다 — 커밋해 두면 물리 디렉터리가 사라져도 fr/beta ref 의 이력에는
# 남는다(뒤에서 git show 로 읽는다).
sed -i 's/^status=.*/status=검증 중/' "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state"
printf 'review-session=zzz\n' >> "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state"
git -C "$REPO/.worktrees/beta" add rd-workflow-workspace/.lifecycle/task-state
git -C "$REPO/.worktrees/beta" commit -q -m "progress: 검증 중"
[[ -n "$(git -C "$REPO" rev-parse --verify fr/alpha)" ]] \
  && [[ -n "$(git -C "$REPO" rev-parse --verify fr/beta)" ]] \
  && pass "두 작업이 공존한다" || fail "동시 착수"

# 각 worktree 의 task-state 가 자기 작업만 가리킨다
a="$(grep '^short-title=' "$REPO/.worktrees/alpha/rd-workflow-workspace/.lifecycle/task-state")"
b="$(grep '^short-title=' "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")"
[[ "$a" == "short-title=alpha" && "$b" == "short-title=beta" ]] \
  && pass "작업별 task-state 분리" || fail "task-state 분리"

# 기본 브랜치의 task-state 는 baseline 이다
m="$(grep '^short-title=' "$REPO/rd-workflow-workspace/.lifecycle/task-state")"
[[ "$m" == "short-title=-" ]] && pass "기본 브랜치 task-state 는 baseline" || fail "baseline"

# 같은 FR 재착수는 무변경 + 안내
out="$(bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title alpha --size large --source-fr - 2>&1 || true)"
[[ "$out" == *"이미 진행 중"* ]] && pass "중복 착수 안내" || fail "중복 착수"

# --no-worktree 작업이 이미 있으면 두 번째 --no-worktree 는 거부된다

# --no-worktree 로 기본 체크아웃이 fr 브랜치가 된 뒤에도 공유 위치와 관리 진입점이 산다
# (brief 는 이 전제를 서술만 하고 착수 자체는 생략했다 — 실제로 fr/nw 를 --no-worktree 로
#  착수해야 아래 `git switch -q fr/nw` 가 뜻을 갖는다.)
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title nw --size large --source-fr - --no-worktree
( cd "$REPO" && git switch -q fr/nw )
out="$( cd "$REPO" && bash rd-workflow/scripts/rd task list 2>&1 )"
[[ "$out" == *"alpha"* ]] && pass "기본 브랜치 미체크아웃에서도 목록이 동작한다" || fail "R1 회귀"
# 이 R1 회귀 시나리오만을 위해 $REPO 자신의 체크아웃을 fr/nw 로 옮겨 뒀다 — 이후
# 케이스(merge 등)는 기본 브랜치 위에서 진행한다는 전제이므로 되돌린다.
git -C "$REPO" switch -q main

# 잘못된 --worktree-path 는 branch 를 남기지 않는다 (경로 검증이 branch 생성보다 앞)
#   set -e 아래에서 `cmd; rc=$?` 는 rc 에 도달하지 못한다. if 로 감싼다.
if bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title zeta --size large \
     --source-fr - --worktree-path /nonexistent-parent/zeta 2>/dev/null; then
  fail "잘못된 경로인데 promote 가 성공했다"
else
  git -C "$REPO" rev-parse --verify fr/zeta >/dev/null 2>&1 \
    && fail "경로 오류인데 잔여 branch 가 남았다" \
    || pass "경로 오류는 잔여 branch 를 남기지 않는다"
fi

# 새 저장소에 .worktrees 가 없어도 첫 착수가 성공한다
rm -rf "$REPO/.worktrees"
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title eta --size large --source-fr -
[[ -d "$REPO/.worktrees/eta" ]] && pass ".worktrees 부모를 자동 생성한다" || fail "부모 생성"

# 공백이 든 경로에서도 동작한다 (명시 경로는 부모가 있어야 하므로 먼저 만든다)
mkdir -p "$REPO/with space"
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title theta --size large \
  --source-fr - --worktree-path "$REPO/with space/theta"
[[ -d "$REPO/with space/theta" ]] && pass "공백 경로 지원" || fail "공백 경로"

# --- spec D6: workflow.json 의 worktree_root override ---
# (문서 작업 중 발견된 누락 — promote.sh 가 .worktrees 를 하드코딩하고 있었다.)
mkdir -p "$REPO/rd-workflow/config"
printf '{\n  "worktree_root": "custom-root"\n}\n' > "$REPO/rd-workflow/config/workflow.json"
# 부모 디렉터리를 일부러 만들지 않는다 — override 경로도 순정 기본 경로와 같이
# 자동 생성돼야 한다(사용자가 매 착수마다 mkdir 을 선행하지 않게).
[[ -e "$REPO/custom-root" ]] && fail "D6 전제 붕괴: custom-root 가 이미 있어 자동 생성을 검증하지 못한다"
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title hotel --size large --source-fr -
if [[ -d "$REPO/custom-root/hotel" && ! -e "$REPO/.worktrees/hotel" ]]; then
  pass "worktree_root override 가 기본 경로를 대체한다(D6)"
else
  fail "D6: worktree_root override 미적용 (custom-root/hotel 없음 또는 옛 기본 경로에도 생성됨)"
fi

# --worktree-path 명시 인자가 override 보다 우선한다(기존 우선순위 불변)
mkdir -p "$REPO/explicit-india"
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title india --size large \
  --source-fr - --worktree-path "$REPO/explicit-india/india"
[[ -d "$REPO/explicit-india/india" ]] \
  && pass "--worktree-path 가 worktree_root override 보다 우선한다" \
  || fail "D6: --worktree-path 우선순위 붕괴"

# workflow.json 은 있는데 worktree_root 키만 없는 경우 기존 기본 동작이 그대로인지(회귀).
# 파일을 지우면 `-f` 분기 자체를 건너뛰어 키 파싱 경로를 검사하지 못한다 — 파일 부재
# 쪽은 이 절 위쪽의 eta·theta 케이스가 이미 지나므로, 여기서는 파일을 남긴 채 키만 뺀다.
printf '{\n  "default_branch": "main"\n}\n' > "$REPO/rd-workflow/config/workflow.json"
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title juliet --size large --source-fr -
[[ -d "$REPO/.worktrees/juliet" ]] \
  && pass "worktree_root 키 부재 시 기존 .worktrees 기본 경로 유지(회귀)" \
  || fail "D6 회귀: worktree_root 부재인데 기본 경로가 깨짐"

# branch-only 잔여(판정 2)에서 재실행이 git branch 중복으로 죽지 않는다
git -C "$REPO" branch fr/iota main
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title iota --size large --source-fr -
[[ -d "$REPO/.worktrees/iota" ]] && pass "branch-only 잔여에서 재개한다" || fail "판정 2"

# 소유권 불명확(판정 7)은 아무것도 바꾸지 않는다

# --- D11 초기화 증명 (판정 2·3·4 공통 검증) ---
# (a) baseline 을 승계한 worktree 만 남은 경우 → 신규 초기화가 허용된다
# (b) 진행된 권위(status=검증 중, review-session 있음)가 fr ref 에만 있는 경우
#     → 덮어쓰지 않고 그 상태로 재개한다
# (beta 를 진행 상태로 만드는 커밋은 위에서 beta 착수 직후에 이미 만들어 뒀다 — eta
#  케이스의 `rm -rf "$REPO/.worktrees"` 가 이 디렉터리를 통째로 지우기 전이어야 한다.)
git -C "$REPO" worktree remove --force "$REPO/.worktrees/beta" 2>/dev/null || true
rm -f "$(cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_path')"
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title beta --size large --source-fr -
st="$(grep '^status=' "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")"
[[ "$st" == "status=검증 중" ]] \
  && pass "진행된 권위를 착수 값으로 되돌리지 않는다" || fail "권위 유실: $st"

# (c) 워킹트리가 committed 와 다르면(작성 후 commit 실패·파일 유실) 무변경 + 안내로 끝난다
#     문자열만이 아니라 대상 파일·index 보존을 함께 본다
echo "drift" >> "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state"
b_file="$(cat "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")"
# index 보존은 status --porcelain 으로 증명되지 않는다 — staged blob 이 바뀌어도 같은 M 이 나온다.
# 경로·mode·OID 를 그대로 비교한다.
b_idx="$(git -C "$REPO/.worktrees/beta" ls-files --stage)"
if out="$(bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title beta --size large --source-fr - 2>&1)"; then
  fail "증명 불가 상태인데 진행했다"
else
  [[ "$out" == *"커밋"* ]] \
    && [[ "$(cat "$REPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state")" == "$b_file" ]] \
    && [[ "$(git -C "$REPO/.worktrees/beta" ls-files --stage)" == "$b_idx" ]] \
    && pass "증명 불가는 무변경 + 복구 안내" || fail "증명 불가 보존"
fi

# (d) 구형 alpha 상태가 기본 브랜치에 남아 있어도 새 beta 착수가 막히지 않는다
#     새 ref 에는 고유 커밋이 없으므로 committed task-state 는 '물려받은 값' 이다 (판정 b)
# (brief 서술만 있고 코드가 없던 슬롯이다 — 2026-09 final diff review I1 이 이 판정
#  자체가 미구현이었음을 지적했다. b 와 g(소유권 불명확) 를 가르는 유일한 차이는
#  "그 ref 가 first-parent 이력에 있는가" 이므로, 실제로 그 상태를 만들어야 한다.
#  기본 브랜치 자체의 task-state 를 구형 값으로 오염시켜 커밋한다(이 재설계에서
#  promote 는 절대 이렇게 하지 않는다 — 이 테스트 전용 재현이다). 그 뒤 만드는
#  fr/gamma 는 고유 커밋이 없으므로 그 오염값을 그대로 물려받는다.)
sed -i 's/^short-title=.*/short-title=alpha/' "$REPO/rd-workflow-workspace/.lifecycle/task-state"
git -C "$REPO" add rd-workflow-workspace/.lifecycle/task-state
git -C "$REPO" commit -q -m "구형 잔여 재현 (테스트 전용)"
git -C "$REPO" branch fr/gamma main
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title gamma --size large --source-fr -
gst="$(grep '^short-title=' "$REPO/.worktrees/gamma/rd-workflow-workspace/.lifecycle/task-state")"
[[ "$gst" == "short-title=gamma" ]] \
  && pass "물려받은 구형 상태(short-title=alpha)는 identity 를 묻지 않고 신규 초기화된다 (판정 b)" \
  || fail "판정 b 미구현 의심: $gst"

# (e) merge 후 tag 전 중단 + 색인·worktree 유실 → 초기화하지 않고 발행 확인 필요 (판정 c)
#     alpha 를 진행 상태로 만든 뒤 merge 만 하고 tag 는 만들지 않는다
# (brief 서술은 "alpha" 라 썼지만 아래 코드는 "eps" 를 참조한다 — 이 슬롯도 착수 코드가
#  생략됐으므로 실제로 fr/eps 를 먼저 만든다.)
bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title eps --size large --source-fr -
git -C "$REPO" merge --no-ff -q fr/eps -m "merge: eps"
git -C "$REPO" worktree remove --force "$REPO/.worktrees/eps"
rm -f "$(cd "$REPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_path')"
eps_blob="$(git -C "$REPO" show fr/eps:rd-workflow-workspace/.lifecycle/task-state)"
if out="$(bash "$REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title eps --size large --source-fr - 2>&1)"; then
  fail "merge 후 tag 전 잔여인데 새로 착수했다"
else
  [[ "$out" == *"발행 확인"* ]] \
    && [[ "$(git -C "$REPO" show fr/eps:rd-workflow-workspace/.lifecycle/task-state)" == "$eps_blob" ]] \
    && pass "merge 후 tag 전 잔여는 권위 보존 + 발행 확인 필요" || fail "판정 c (tag 전)"
fi

# (f) 정상 발행(merge + 규약 tag + 원격 반영) 후 잔여 → 권위 보존 + 정리 대기 (판정 c)

# --- 기동 예약(launch-token) — 실제 herdr 없이 예약·완료-기록 로직만 태운다 ---
# (2026-09 final diff review I9) test_lifecycle.sh 최상단의 RD_CHILD_SESSION=1 이
# `session_launch` 를 항상 깊이-1 조기 반환으로 보내므로, 이 파일의 다른 promote
# 호출은 전부 launch=none 경로만 타고 예약(launch=launching+token)·완료 시 token
# 일치 기록 로직을 전혀 실행하지 않는다. `RD_LAUNCH_STUB` seam(session_launch.sh)
# 으로 herdr 를 대신할 대역 실행 파일을 꽂아 이 로직만 독립적으로 검증한다.
# **실제 herdr 는 이 블록에서도 호출되지 않는다** — 대역이 herdr 를 대신한다.
RLREPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$RLREPO" && -d "$RLREPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
RLREPO="$(cd "$RLREPO" && pwd -P)"
_ast_cleanup+=("$RLREPO")
mkdir -p "$RLREPO/rd-workflow"
cp -R "$SCRIPT_DIR/.." "$RLREPO/rd-workflow/scripts"
git -C "$RLREPO" init -q -b main
git -C "$RLREPO" config user.email t@t && git -C "$RLREPO" config user.name t
mkdir -p "$RLREPO/rd-workflow-workspace/.lifecycle" "$RLREPO/rd-workflow-workspace/backlog/items"
printf '.worktrees/\n' > "$RLREPO/.gitignore"
emit_current_task_baseline > "$RLREPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$RLREPO/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$RLREPO/REQUEST.md"
git -C "$RLREPO" add -A && git -C "$RLREPO" commit -q -m seed

# 대역 1 — 그냥 ok 를 낸다. 예약(launching+token) → session_launch 호출(대역) →
# 완료 기록(launch=ok, 같은 token) 경로가 전부 실행되는지 본다.
RL_STUB_OK="$RLREPO/stub-ok.sh"
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > "$RL_STUB_OK"
chmod +x "$RL_STUB_OK"
RD_LAUNCH_STUB="$RL_STUB_OK" bash "$RLREPO/rd-workflow/scripts/lifecycle/promote.sh" \
  --short-title launchok --size large --source-fr -
rl_launch="$(cd "$RLREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get launchok launch')"
[[ "$rl_launch" == "ok" ]] \
  && pass "기동 예약 → token 일치 시 결과를 기록한다(ok)" || fail "예약-확정 불일치: launch=$rl_launch"

# 대역 2 — 기동 "도중"(대역이 실행되는 시점) 다른 프로세스가 이 slug 의
# launch-token 을 경쟁적으로 덮어썼다고 흉내낸다. promote 가 자신이 예약한 token 과
# 다른 것을 보면 결과를 쓰지 않아야 한다 — 그러지 않으면 오래된 기동 결과가 그
# 경쟁자의 새 예약을 덮어써 "확인 필요" 상태가 조용히 사라진다.
RL_STUB_RACE="$RLREPO/stub-race.sh"
cat > "$RL_STUB_RACE" <<STUBEOF
#!/usr/bin/env bash
cd "$RLREPO" || exit 1
project_root="$RLREPO"
source "$RLREPO/rd-workflow/scripts/lifecycle/_tasks_index.sh"
if tasks_lock_acquire stub-race "\$2"; then
  tasks_index_upsert "\$2" launch-token=competitor-token
  tasks_lock_release
fi
printf 'ok\n'
STUBEOF
chmod +x "$RL_STUB_RACE"
RD_LAUNCH_STUB="$RL_STUB_RACE" bash "$RLREPO/rd-workflow/scripts/lifecycle/promote.sh" \
  --short-title race --size large --source-fr -
rl_race_launch="$(cd "$RLREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get race launch')"
rl_race_token="$(cd "$RLREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get race launch-token')"
[[ "$rl_race_launch" != "ok" && "$rl_race_token" == "competitor-token" ]] \
  && pass "launch-token 불일치 시 기동 결과를 기록하지 않는다(경쟁자 예약 보존)" \
  || fail "token 불일치 보호 실패: launch=$rl_race_launch token=$rl_race_token"

# --- D2: reinit_noattach 는 등록된 worktree 경로를 대상으로 삼는다 ---
# (2026-09 final diff review D2) TARGET_DIR 선택이 NEED_ATTACH 로만 게이트돼 있으면
# worktree 는 이미 살아 있고 내용만 미초기화인 상태(reinit_noattach, NEED_ATTACH=0)
# 에서 색인/인자 경로를 무시하고 기본 경로(.worktrees/<slug>)로 떨어진다 — 그 작업이
# 명시 경로로 만들어졌다면 9단계가 존재하지 않는 경로에서 죽고, I6 트랩이 존재하지도
# 않는 경로를 "보존 대상" 이라며 재시도를 안내해 재시도 루프가 된다. RLREPO 를 재사용
# 한다(그 자체 checkout 은 여전히 main 이라 무관하다).
D2_CUSTOM="$RLREPO/custom-delta"
git -C "$RLREPO" branch fr/delta main
git -C "$RLREPO" worktree add "$D2_CUSTOM" fr/delta >/dev/null
bash "$RLREPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title delta --size large --source-fr -
if [[ -f "$D2_CUSTOM/rd-workflow-workspace/.lifecycle/task-state" ]] \
  && grep -qx 'short-title=delta' "$D2_CUSTOM/rd-workflow-workspace/.lifecycle/task-state" \
  && [[ ! -e "$RLREPO/.worktrees/delta" ]]; then
  pass "reinit_noattach 는 실제 등록된 worktree(WT_ALIVE_PATH)를 대상 삼는다(D2)"
else
  fail "D2: 명시 경로로 이미 살아 있는 worktree 의 대상 경로 유실"
fi

# --- D3: session_probe 의 unknown 을 dead 로 취급하지 않는다 ---
# (2026-09 final diff review D3) 색인의 launch=ok 인데 session_probe 가 alive 도
# dead 도 아닌 unknown(조회 불가)을 내면, "확인 전에는 기동하지 않는다" 는 launching·
# unknown 과 같은 경로로 가야 한다. 이 스위트는 HERDR_ENV 를 전역 차단(파일 상단)
# 했으므로 session_probe 는 herdr 부재로 **항상 unknown** 을 낸다 — 그 사실 자체를
# seam 으로 쓴다: worktree 를 잃되(그래서 resume 판정) 색인의 launch=ok 는 보존한
# 채 재실행했을 때, D3 수정 전이라면 probe=unknown 을 dead 로 오판해 재기동을
# 시도하고(RD_CHILD_SESSION=1 이 그 시도를 실제 herdr 없이 launch=none 으로 귀결시켜
# 관측 가능하다) launch=ok 가 사라진다.
RL_STUB_OK2="$RLREPO/stub-ok2.sh"
printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > "$RL_STUB_OK2"
chmod +x "$RL_STUB_OK2"
RD_LAUNCH_STUB="$RL_STUB_OK2" bash "$RLREPO/rd-workflow/scripts/lifecycle/promote.sh" \
  --short-title foxtrot --size large --source-fr -
git -C "$RLREPO" worktree remove --force "$RLREPO/.worktrees/foxtrot"
fx_launch_before="$(cd "$RLREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get foxtrot launch')"
if [[ "$fx_launch_before" != "ok" ]]; then
  fail "D3 사전조건 실패 — 색인에 launch=ok 가 없음(got=$fx_launch_before)"
else
  bash "$RLREPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title foxtrot --size large --source-fr -
  fx_launch_after="$(cd "$RLREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get foxtrot launch')"
  [[ "$fx_launch_after" == "ok" ]] \
    && pass "probe=unknown 은 dead 로 취급하지 않고 재기동을 보류한다(D3, launch=ok 보존)" \
    || fail "D3: probe unknown 이 dead 로 처리돼 재기동됨(launch=$fx_launch_after)"
fi

echo "== promote_rollback.sh — 작업 대상 선택 (Task 5) =="

RBREPO="$(mktemp -d)" || { echo "test_lifecycle.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$RBREPO" && -d "$RBREPO" ]] || { echo "test_lifecycle.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
RBREPO="$(cd "$RBREPO" && pwd -P)"
_ast_cleanup+=("$RBREPO")
mkdir -p "$RBREPO/rd-workflow"
cp -R "$SCRIPT_DIR/.." "$RBREPO/rd-workflow/scripts"
git -C "$RBREPO" init -q -b main
git -C "$RBREPO" config user.email t@t && git -C "$RBREPO" config user.name t
mkdir -p "$RBREPO/rd-workflow-workspace/.lifecycle" "$RBREPO/rd-workflow-workspace/backlog/items"
printf '.worktrees/\n' > "$RBREPO/.gitignore"
emit_current_task_baseline > "$RBREPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$RBREPO/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$RBREPO/REQUEST.md"
git -C "$RBREPO" add -A && git -C "$RBREPO" commit -q -m seed

bash "$RBREPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title alpha --size large --source-fr -
bash "$RBREPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title beta --size large --source-fr -

# 작업 2건 상태에서 대상 없이 부르면 nonzero + 두 작업의 ref·task-state·색인이 전후 동일
snap() { git -C "$RBREPO" rev-parse fr/alpha fr/beta; \
         cat "$RBREPO/.worktrees/alpha/rd-workflow-workspace/.lifecycle/task-state" \
             "$RBREPO/.worktrees/beta/rd-workflow-workspace/.lifecycle/task-state"; \
         cat "$(cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_path')"; }
before="$(snap)"
if out="$(bash "$RBREPO/rd-workflow/scripts/lifecycle/promote_rollback.sh" 2>&1)"; then
  fail "다건인데 대상 없는 rollback 이 성공했다"
else
  [[ "$out" == *"alpha"* && "$out" == *"beta"* && "$out" == *"--task"* ]] \
    && [[ "$(snap)" == "$before" ]] \
    && pass "다건 rollback 은 nonzero + ref·상태·색인 무변경" || fail "대상 미지정 중단"
fi

# 대상 worktree 가 현재 실행 중인 worktree 이면 제거하지 않는다(요구사항 5) — 이
# worktree 자신의 스크립트 사본으로 호출해 "그 worktree 안에서 실행 중" 을 재현한다.
before2="$(snap)"
if out="$(bash "$RBREPO/.worktrees/alpha/rd-workflow/scripts/lifecycle/promote_rollback.sh" --task alpha 2>&1)"; then
  fail "실행 중인 worktree 자기 자신을 rollback 대상으로 삼아 성공했다"
else
  [[ "$out" == *"기본"* ]] \
    && [[ "$(snap)" == "$before2" ]] \
    && pass "실행 중인 worktree 자기 자신은 기본 worktree 안내와 함께 중단" || fail "자기-worktree 보호 실패: $out"
fi

# launching/unknown 예약 중인 작업은 rollback 이 건드리지 않는다 — promote.sh 는
# worktree 부착·branch 체크아웃·색인 등록을 먼저 끝낸 뒤 launch=launching 을 기록하고
# **락을 풀고** 그 밖에서 세션을 기동한다. 그 구간에 rollback 이 끼어들면 막 기동됐거나
# 기동 중인 세션의 worktree·branch 를 통째로 지운다(spec 169행). alpha 가 다음 케이스에서
# 지워지므로 beta 로 검증한다. worktree·branch·색인(snap) 이 모두 무변경이어야 한다.
(cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_upsert beta launch=launching launch-token=stub-token')
before3="$(snap)"
if out="$(bash "$RBREPO/rd-workflow/scripts/lifecycle/promote_rollback.sh" --task beta 2>&1)"; then
  fail "launching 예약 중인데 rollback 이 성공했다"
else
  [[ "$out" == *"beta"* && "$out" == *"launch"* && "$out" == *"resolve-launch"* ]] \
    && [[ "$(snap)" == "$before3" ]] \
    && [[ -d "$RBREPO/.worktrees/beta" ]] \
    && [[ -n "$(git -C "$RBREPO" rev-parse --verify fr/beta)" ]] \
    && pass "launching 예약 중인 작업은 rollback 이 무변경으로 거부한다" || fail "launching 가드 실패: $out"
fi

# unknown(확인 불가)도 launching 과 동일하게 차단한다 — unknown 을 none 으로 다루지 않는다.
(cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_upsert beta launch=unknown')
if out="$(bash "$RBREPO/rd-workflow/scripts/lifecycle/promote_rollback.sh" --task beta 2>&1)"; then
  fail "launch=unknown 인데 rollback 이 성공했다"
else
  [[ "$out" == *"beta"* ]] \
    && [[ -d "$RBREPO/.worktrees/beta" ]] \
    && [[ -n "$(git -C "$RBREPO" rev-parse --verify fr/beta)" ]] \
    && pass "launch=unknown 도 launching 과 동일하게 rollback 을 차단한다" || fail "unknown 가드 실패: $out"
fi
# 이후 케이스에 영향 없도록 정상 확정 상태로 되돌린다.
(cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_upsert beta launch=ok')

# --task 로 지정하면 그 작업만 되돌린다
bash "$RBREPO/rd-workflow/scripts/lifecycle/promote_rollback.sh" --task alpha
git -C "$RBREPO" rev-parse --verify fr/alpha 2>/dev/null && fail "alpha 가 남았다" \
  || { [[ -n "$(git -C "$RBREPO" rev-parse --verify fr/beta)" ]] \
       && pass "대상만 되돌리고 다른 작업은 보존" || fail "beta 유실"; }
[[ ! -e "$RBREPO/.worktrees/alpha" ]] && pass "alpha worktree 제거됨" || fail "alpha worktree 잔존"
[[ -d "$RBREPO/.worktrees/beta" ]] && pass "beta worktree 보존됨" || fail "beta worktree 유실"
alpha_idx="$(cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get alpha fr-branch' 2>/dev/null || true)"
[[ -z "$alpha_idx" ]] && pass "색인에서 alpha 행 제거됨" || fail "색인에 alpha 잔존: $alpha_idx"
beta_idx="$(cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get beta fr-branch' 2>/dev/null || true)"
[[ "$beta_idx" == "fr/beta" ]] && pass "색인에 beta 행 보존됨" || fail "색인에서 beta 유실: $beta_idx"

# --- F5: `--no-worktree` 작업의 취소 경로 (final diff review) ---
# 대상 경로가 기본 worktree 자체이므로 예전에는 self-removal 가드가 "기본 worktree 로
# 이동해 같은 명령을 실행하라" 며 거부했다 — 이미 거기 서 있는 사용자에게는 무한 루프
# 안내였고, 단일 체크아웃 시절에 있던 취소 기능의 회귀였다. 지금은 worktree 를 제거하지
# 않고 체크아웃을 기본 브랜치로 되돌린 뒤 fr 브랜치·색인 행만 정리한다.
bash "$RBREPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title zulu --size large --no-worktree --source-fr -
zulu_head="$(git -C "$RBREPO" symbolic-ref --quiet --short HEAD)"
if [[ "$zulu_head" != "fr/zulu" ]]; then
  fail "F5 사전조건 실패 — --no-worktree 착수 후 체크아웃이 fr/zulu 가 아니다(${zulu_head})"
elif ! bash "$RBREPO/rd-workflow/scripts/lifecycle/promote_rollback.sh" --task zulu; then
  fail "F5: --no-worktree 작업의 rollback 이 실패했다"
else
  zulu_after_head="$(git -C "$RBREPO" symbolic-ref --quiet --short HEAD)"
  zulu_idx="$(cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get zulu fr-branch' 2>/dev/null || true)"
  if [[ "$zulu_after_head" == "main" ]] \
    && ! git -C "$RBREPO" rev-parse --verify --quiet refs/heads/fr/zulu >/dev/null \
    && [[ -z "$zulu_idx" ]] \
    && [[ -d "$RBREPO" ]] \
    && [[ -d "$RBREPO/.worktrees/beta" ]] \
    && [[ -n "$(git -C "$RBREPO" rev-parse --verify fr/beta)" ]]; then
    pass "--no-worktree 작업을 기본 worktree 보존 + fr 브랜치·색인 행 제거로 취소한다(F5)"
  else
    fail "F5 취소 결과: head=${zulu_after_head} idx=[${zulu_idx}]"
  fi
fi

# --- F1 근본 (final diff review): 기록 부재는 `unknown` 이고, 재기동을 막는다 ---
# 흡수의 발동 조건(기본 worktree task-state 가 `fr/*` + 색인 행 없음)은 ① 구형 배치와
# ② **색인 유실**에서 모두 참이다. ②에는 `--no-worktree` 로 착수해 세션이 살아 있는
# 작업이 포함될 수 있고, 저장소 안에는 둘을 가를 증거가 없다. 그래서 `none`(기동한 적
# 없음)으로 단언하면 재착수가 살아 있는 세션 위에 두 번째 세션을 띄운다
# (change spec 159행 R5 · AC 11). 값은 `unknown` 이어야 하고, 그 상태에서 재착수가
# **기동하지 않는 것**까지 확인한다 — 값만 보면 회귀가 되살아나도 알 수 없다.
git -C "$RBREPO" branch fr/oldtask main
# 구형/유실 배치 재현 — 기본 worktree 의 task-state 가 활성 fr 을 가리킨다.
sed -i 's|^fr-branch=.*|fr-branch=fr/oldtask|' "$RBREPO/rd-workflow-workspace/.lifecycle/task-state"
old_idx="$( cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get oldtask launch' 2>/dev/null || true )"
if [[ -n "$old_idx" ]]; then
  fail "F1 근본 사전조건 실패 — oldtask 색인 행이 이미 있다: $old_idx"
else
  ( cd "$RBREPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title absorbnew --size large --source-fr - ) >/dev/null 2>&1 || true
  absorbed="$( cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_get oldtask launch' 2>/dev/null || true )"
  [[ "$absorbed" == "unknown" ]] \
    && pass "F1 근본: 흡수는 기록 부재를 unknown 으로 둔다(세션 부재로 해석하지 않는다)" \
    || fail "F1 근본: 흡수가 기록한 launch 값이 unknown 이 아니다: '$absorbed'"
  # 재착수가 그 상태에서 기동하지 않는다 — R5 가 실제로 닫혀 있는지의 본체다.
  reout="$( cd "$RBREPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title oldtask --size large --source-fr - 2>&1 || true )"
  [[ "$reout" == *"새로 기동하지 않습니다"* ]] \
    && pass "F1 근본: unknown 인 작업의 재착수는 세션을 다시 띄우지 않는다 (R5·AC 11)" \
    || fail "F1 근본: 재착수가 기동을 시도했다 — $reout"
  [[ "$reout" == *"기존 세션의 모델은 확인하지 않습니다"* && "$reout" != *"다음 기동에 사용할 모델"* ]] \
    && pass "F9: 기동을 건너뛴 재착수는 모델을 적용된 것처럼 표시하지 않는다" \
    || fail "F9: 건너뛴 재착수인데 모델 표시가 뒤섞임 — $reout"
  # 그래도 herdr 없이 마감이 막히지는 않는다 — 명시 확정 경로가 열려 있다.
  _ae_out="$( cd "$RBREPO" && env -u HERDR_ENV bash rd-workflow/scripts/rd task resolve-launch oldtask --assume-ended 2>&1 )" || _ae_out="RC!=0 $_ae_out"
  _rb_out="$( cd "$RBREPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task oldtask --force 2>&1 )" || _rb_out="RC!=0 $_rb_out"
  if [[ "$_ae_out" != RC!=0* && "$_rb_out" != RC!=0* ]]; then
    pass "F1 근본: --assume-ended 로 herdr 없이 마감까지 도달한다 (AC 8·AC 18)"
  else
    fail "F1 근본: 명시 확정 경로로도 차단이 풀리지 않았다 — resolve=[$_ae_out] rollback=[$_rb_out]"
  fi
  [[ "$_ae_out" == *"이어서 진행"* ]] \
    && pass "resolve-launch(dead 확정)가 호출 세션 거취(이어서 진행) 문구를 출력한다" \
    || fail "resolve-launch dead 출력에 거취 문구 없음: $_ae_out"
fi
# 기본 worktree 의 task-state 를 baseline 으로 되돌린다(이후 케이스 오염 방지).
sed -i 's|^fr-branch=.*|fr-branch=null|' "$RBREPO/rd-workflow-workspace/.lifecycle/task-state"

# --- F6 (final diff review): rollback 이 살아 있는 세션과 미커밋 작업물을 보존한다 ---
# 예전에는 보호가 거꾸로였다 — 생존이 **불확실할 때**(launching·unknown) 막고 생존이
# **확인됐을 때**(ok) 통과시킨 뒤 dirty 검사 없이 `worktree remove --force` 로 지웠다.
# AC 16(실행 중인 에이전트 세션이 만든 변경을 지우지 않는다).

# ① 미커밋 작업물 — 기본 동작으로 지우지 않고, 무엇을 잃는지 보여 준다.
( cd "$RBREPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title dirtywt --size large --source-fr - ) >/dev/null
printf 'uncommitted work\n' > "$RBREPO/.worktrees/dirtywt/user-work.txt"
if out="$( cd "$RBREPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task dirtywt 2>&1 )"; then
  fail "F6: 미커밋 변경이 있는데 rollback 이 그대로 지웠다"
else
  [[ -f "$RBREPO/.worktrees/dirtywt/user-work.txt" ]] \
    && [[ -n "$(git -C "$RBREPO" rev-parse --verify --quiet fr/dirtywt)" ]] \
    && pass "F6: 미커밋 작업물이 있으면 무변경으로 거부하고 파일·브랜치를 보존한다" \
    || fail "F6: 거부했는데 파일·브랜치가 사라졌다"
  [[ "$out" == *"user-work.txt"* ]] \
    && pass "F6: 무엇을 잃는지(변경 목록)를 삭제 전에 보여 준다" || fail "F6 변경 목록 누락: $out"
  [[ "$out" == *"--force"* ]] \
    && pass "F6: 그래도 버리겠다는 명시 경로를 안내한다" || fail "F6 --force 안내 누락: $out"
fi
if ( cd "$RBREPO" && bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task dirtywt --force ) >/dev/null 2>&1; then
  [[ ! -d "$RBREPO/.worktrees/dirtywt" ]] \
    && ! git -C "$RBREPO" rev-parse --verify --quiet refs/heads/fr/dirtywt >/dev/null \
    && pass "F6: --force 를 주면 취소가 끝까지 완주한다(취소를 불가능하게 만들지 않는다)" \
    || fail "F6: --force 인데 정리가 끝나지 않았다"
else
  fail "F6: --force 로도 rollback 이 실패했다"
fi

# ② 기동된 세션(launch=ok) — 생존 확인이 서지 않으면(여기서는 herdr 없는 환경) 보존한다.
( cd "$RBREPO" && bash rd-workflow/scripts/lifecycle/promote.sh --short-title livewt --size large --source-fr - ) >/dev/null
( cd "$RBREPO" && bash -c 'source rd-workflow/scripts/lifecycle/_tasks_index.sh; tasks_index_upsert livewt launch=ok' )
if out="$( cd "$RBREPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task livewt 2>&1 )"; then
  fail "F6: launch=ok 인데 rollback 이 통과했다"
else
  [[ -d "$RBREPO/.worktrees/livewt" ]] \
    && [[ -n "$(git -C "$RBREPO" rev-parse --verify --quiet fr/livewt)" ]] \
    && pass "F6: 살아 있을 수 있는 세션의 worktree·브랜치를 보존한다 (AC 16)" \
    || fail "F6: launch=ok 인데 worktree·브랜치가 지워졌다"
  [[ "$out" == *"세션"* && "$out" == *"--force"* ]] \
    && pass "F6: 세션을 끝내는 방법과 재시도·강제 경로를 함께 안내한다" || fail "F6 안내 누락: $out"
fi
if ( cd "$RBREPO" && env -u HERDR_ENV bash rd-workflow/scripts/lifecycle/promote_rollback.sh --task livewt --force ) >/dev/null 2>&1; then
  pass "F6: launch=ok 도 --force 로는 취소할 수 있다"
else
  fail "F6: launch=ok 를 --force 로도 취소하지 못했다"
fi

if [[ "$(trap -p EXIT)" == *_suite_on_exit* ]]; then
  PASS=$((PASS+1)); echo "  PASS: 조용한 중단 센티넬(EXIT trap)이 스위트 끝까지 유지됨"
else
  FAIL=$((FAIL+1)); echo "  FAIL: 최상위 EXIT trap 이 센티넬을 덮어썼다 — 조용한 중단이 다시 익명이 된다. 정리 대상은 _ast_cleanup 에 append 하십시오 — [$(trap -p EXIT)]" >&2; fi

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
# `DONE=1` 은 결과줄 **직후**이고 `[[ $FAIL -eq 0 ]]` **앞**입니다. 뒤에 두면 정상적으로
# FAIL 로 끝나는 실행(rc 1)에서 센티넬이 "조용한 중단" 을 오탐합니다 — 센티넬이 묻는 것은
# "결과를 보고했는가" 이지 "통과했는가" 가 아닙니다.
DONE=1
[[ $FAIL -eq 0 ]]
