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

# 소유 키 목록 — 공백 구분 한 줄, 6개
_lok="$(lifecycle_owned_state_keys)"
assert_eq "$(printf '%s' "$_lok" | wc -w | tr -d ' ')" "6" "lifecycle_owned_state_keys 6개"
for _k in fr-branch worktree-path source-fr short-title status created-at; do
  case " $_lok " in
    *" $_k "*) PASS=$((PASS+1)); echo "  PASS: 소유 키 $_k 포함" ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: 소유 키 $_k 누락" >&2 ;;
  esac
done

# 소유 키 registry 가 writer 의 **실제 동작**과 일치하는가.
#
# grep 으로 이름 존재만 보면 문자열이 있다는 사실만 증명하고 동작을 증명하지 못한다.
# metadata_clear 를 실제로 실행해 어떤 키가 바뀌었는지 관측한다.
_ok_repo="$(mktemp -d)"; _ok_repo="$(cd "$_ok_repo" && pwd -P)"
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
_bc_repo="$(mktemp -d)"; _bc_repo="$(cd "$_bc_repo" && pwd -P)"
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
_oc_repo="$(mktemp -d)"; _oc_repo="$(cd "$_oc_repo" && pwd -P)"
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
_oc2_repo="$(mktemp -d)"; _oc2_repo="$(cd "$_oc2_repo" && pwd -P)"
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
_ff_repo="$(mktemp -d)"; _ff_repo="$(cd "$_ff_repo" && pwd -P)"
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
_no_repo="$(mktemp -d)"; _no_repo="$(cd "$_no_repo" && pwd -P)"
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
_ec_repo="$(mktemp -d)"; _ec_repo="$(cd "$_ec_repo" && pwd -P)"
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
_mx_repo="$(mktemp -d)"; _mx_repo="$(cd "$_mx_repo" && pwd -P)"
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
_nm_repo="$(mktemp -d)"; _nm_repo="$(cd "$_nm_repo" && pwd -P)"
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
_em_repo="$(mktemp -d)"; _em_repo="$(cd "$_em_repo" && pwd -P)"
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
_mg_repo="$(mktemp -d)"; _mg_repo="$(cd "$_mg_repo" && pwd -P)"
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
_sp_repo="$(mktemp -d)"; _sp_repo="$(cd "$_sp_repo" && pwd -P)"
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
_pc_repo="$(mktemp -d)"; _pc_repo="$(cd "$_pc_repo" && pwd -P)"
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
_lf_t="$(mktemp)"; _ast_cleanup+=("$_lf_t")
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
TMPDIR_TEST="$(mktemp -d)"
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
read_fix_source_fr() { # read_fix_source_fr <dir>
  awk -F'=' '$1=="source-fr"{sub(/^[^=]+=/,"");print;exit}' "$1/rd-workflow-workspace/.lifecycle/task-state"
}

FIX1="$TMPDIR_TEST/fix-infer"
mk_promote_fixture "$FIX1" '`rd-workflow-workspace/backlog/items/2026-01-01-fix.md`'
( cd "$FIX1" && project_root="$FIX1" bash "$SCRIPT_DIR/promote.sh" --short-title fix-infer --size small --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX1")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: REQUEST 백틱 path 추론 기록"

FIX2="$TMPDIR_TEST/fix-none"
mk_promote_fixture "$FIX2" "-"
( cd "$FIX2" && project_root="$FIX2" bash "$SCRIPT_DIR/promote.sh" --short-title fix-none --size small --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX2")" "-" "promote: REQUEST '-' → source-fr=-"

FIX3="$TMPDIR_TEST/fix-arg"
mk_promote_fixture "$FIX3" "-"
( cd "$FIX3" && project_root="$FIX3" bash "$SCRIPT_DIR/promote.sh" --short-title fix-arg --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX3")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: --source-fr 명시 인자 기록"

FIX4="$TMPDIR_TEST/fix-slug"
mk_promote_fixture "$FIX4" "2026-01-01-fix"
( cd "$FIX4" && project_root="$FIX4" bash "$SCRIPT_DIR/promote.sh" --short-title fix-slug --size small --no-worktree >/dev/null 2>&1 )
assert_eq "$(read_fix_source_fr "$FIX4")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: legacy slug 추론 → path 정규화 (실존)"

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
assert_eq "$(read_fix_source_fr "$FIX7")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote: --dry-run 은 source-fr 를 변경하지 않음 (idempotent rerun)"

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
assert_eq "$(read_fix_source_fr "$FIX8")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote rerun: 동일 값 유지"
assert_eq "$(cd "$FIX8" && git status --porcelain | grep -c "task-state" || true)" "0" "promote rerun: task-state dirty 없음 (동일 값)"

# non-dry idempotent rerun: 다른 값 인자 = exit 1 거부 + 값 불변 + dirty 없음 (정정은 set-source-fr 일원화)
FIX9="$TMPDIR_TEST/fix-rerun-diff"
mk_promote_fixture "$FIX9" "-"
( cd "$FIX9" && project_root="$FIX9" bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-diff --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" >/dev/null 2>&1 )
( cd "$FIX9" && git checkout -q main 2>/dev/null || true )
rc9=0
( cd "$FIX9" && project_root="$FIX9" bash "$SCRIPT_DIR/promote.sh" --short-title fix-rerun-diff --size small --no-worktree \
    --source-fr "rd-workflow-workspace/backlog/items/2026-02-02-other.md" >/dev/null 2>&1 ) || rc9=$?
assert_eq "$rc9" "1" "promote rerun: 다른 --source-fr 거부 (exit 1)"
assert_eq "$(read_fix_source_fr "$FIX9")" "rd-workflow-workspace/backlog/items/2026-01-01-fix.md" "promote rerun: 거부 후 값 불변"
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

echo "== review-gate 헬퍼 (safeguard-review-completion-checks) =="
LITE_HOOKS_DIR="$SCRIPT_DIR/../hooks"
GUARD_ROOT="$(mktemp -d)"
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
source "$LITE_HOOKS_DIR/_guard_common.sh"

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
mk_session "20260120_000000_final-diff-review" "closed" "- 없음" "mytask"   # 최신 종결 mytask 세션
archive_review_precheck "0" "" "mytask" "$PRECHECK_AUDIT" 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "precheck — 종결 세션 존재 → 통과"

# === archive precheck fr-branch tip 가시성 (archive-precheck-premerge-session-visibility) ===
echo "== archive precheck fr-branch tip 가시성 =="
FT_REPO="$(mktemp -d)"
git -C "$FT_REPO" init -q -b main
git -C "$FT_REPO" config user.email t@t && git -C "$FT_REPO" config user.name t
mkdir -p "$FT_REPO/rd-workflow-workspace/handoffs/review_pipeline" "$FT_REPO/rd-workflow-workspace/.lifecycle"
# 실제 archive 시점 재현: main 의 CURRENT_TASK ## Short Title 은 baseline(-),
# short-title 은 task-state metadata fallback 으로 해소된다(get_current_short_title).
printf '# Current Task\n\n## Short Title\n-\n' > "$FT_REPO/CURRENT_TASK.md"
# v2 2b: active-fr → task-state 전환 (schema=1, fr-branch=fr/fttask)
printf 'schema=1\nshort-title=fttask\nstatus=구현 중\nfr-branch=fr/fttask\nworktree-path=null\nsource-fr=-\ncreated-at=2026-07-05-0000\n' > "$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m seed
# fr branch 에 종결 diff-review 세션 commit
git -C "$FT_REPO" branch fr/fttask
git -C "$FT_REPO" switch -q fr/fttask
FTS="$FT_REPO/rd-workflow-workspace/handoffs/review_pipeline/20260301_000000_final-diff-review"
mkdir -p "$FTS"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/fttask\n- short-title: fttask\n' > "$FTS/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$FTS/CHECKPOINT.md"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "diff-review session on fr"
git -C "$FT_REPO" switch -q main
FT_AUDIT="$FT_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
# sanity 1: short-title 은 task-state fallback 으로 해소 (CURRENT_TASK Short Title=-)
# v2 2b: TASK_STATE_PATH를 명시적으로 FT_REPO 기반으로 설정 (서브셸에서 재설정 필요)
assert_eq "$( ( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; get_current_short_title ) )" "fttask" "fr-tip — metadata fallback 으로 short-title 해소(Short Title=-)"
# sanity 2: 세션은 fr branch tip 에만 있고 main 워킹트리엔 없음
assert_eq "$( ( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; get_latest_diff_review_dir ) )" "" "fr-tip — main 워킹트리에 세션 없음(sanity)"
# Case A (핵심 회귀): main Short Title=- + metadata fallback + fr_ref 지정 → fr tip 종결 세션 인식 → 통과(0)
( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; archive_review_precheck "0" "" "fttask" "$FT_AUDIT" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "fr-tip — 종결 세션을 fr branch tip 에서 검증 → 통과 (metadata fallback 결합)"
# Case B (안전 회귀): fr tip 세션을 미종결로 변경 → 차단(1)
git -C "$FT_REPO" switch -q fr/fttask
printf '## Status\nawaiting-reviewer\n\n## Branch Context\n- fr-branch: fr/fttask\n- short-title: fttask\n' > "$FTS/SESSION.md"
git -C "$FT_REPO" add -A && git -C "$FT_REPO" commit -q -m "session unterminated"
git -C "$FT_REPO" switch -q main
( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; archive_review_precheck "0" "" "fttask" "$FT_AUDIT" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "fr-tip — 미종결(awaiting-reviewer) 세션 → 차단 (안전 속성 보존)"
# Case C (audit 정규화): 미종결 fr 세션(위 Case B 상태) + force-skip + 사유 → 통과(0)
#   + audit 의 세션참조 필드가 temp 절대경로가 아닌 repo-상대 경로여야 한다.
FT_AUDIT2="$FT_REPO/rd-workflow-workspace/.lifecycle/audit2.log"
( project_root="$FT_REPO"; TASK_STATE_PATH="$FT_REPO/rd-workflow-workspace/.lifecycle/task-state"; archive_review_precheck "1" "긴급 사유" "fttask" "$FT_AUDIT2" "fr/fttask" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "fr-tip — force-skip + 사유 → 통과"
assert_eq "$(awk -F' \\| ' 'END{print $4}' "$FT_AUDIT2")" "rd-workflow-workspace/handoffs/review_pipeline/20260301_000000_final-diff-review" "fr-tip — audit 세션참조 repo-상대 경로(temp 절대경로 금지)"
rm -rf "$FT_REPO"

# === Case D~G (archive-precheck-fr-ref-short-title-fallback): fr-branch identity 매칭 ===
# active metadata 없이 archive.sh --fr-branch 호출 시, fr tip SESSION.md 의 Branch Context
# fr-branch == fr_ref 로 후보를 고정해 종결 세션을 인식한다(main 워킹트리 의존 제거).
echo "== archive precheck fr_ref — fr-branch identity 매칭 =="
FT2="$(mktemp -d)"
git -C "$FT2" init -q -b main
git -C "$FT2" config user.email t@t && git -C "$FT2" config user.name t
mkdir -p "$FT2/rd-workflow-workspace/handoffs/review_pipeline" "$FT2/rd-workflow-workspace/.lifecycle"
# main: baseline Short Title=- + task-state 부재 → get_current_short_title "-" 반환(fr-scope 미해소)
# v2 2b: active-fr 폐지 → task-state도 없는 상태로 테스트 (legacy fallback: CURRENT_TASK.md Short Title=-)
printf '# Current Task\n\n## Short Title\n-\n' > "$FT2/CURRENT_TASK.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m seed
FT2_AUDIT="$FT2/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
# task-state 없음 → legacy CURRENT_TASK.md Short Title=- 반환 (TASK_STATE_PATH 격리)
assert_eq "$( ( project_root="$FT2"; TASK_STATE_PATH="$FT2/rd-workflow-workspace/.lifecycle/task-state"; get_current_short_title ) )" "-" "metadata 부재 — short-title 빈 값(회귀 전제)"

# Case D (AC1 — metadata 부재 핵심 회귀): fr/d1 tip 종결 세션(fr-branch=fr/d1) → 통과(0)
git -C "$FT2" branch fr/d1
git -C "$FT2" switch -q fr/d1
D1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260401_000000_final-diff-review"
mkdir -p "$D1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/d1\n- short-title: d1\n' > "$D1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$D1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "diff-review on fr/d1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "d1" "$FT2_AUDIT" "fr/d1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "AC1 — metadata 부재 + fr tip 종결 세션 → 통과 (fr-branch identity)"

# Case E (AC2 — suffix slug): fr/e1-2 tip, 세션 fr-branch=fr/e1-2, slug 인자=e1-2 → 통과(0)
git -C "$FT2" branch fr/e1-2
git -C "$FT2" switch -q fr/e1-2
E1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260402_000000_final-diff-review"
mkdir -p "$E1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/e1-2\n- short-title: e1\n' > "$E1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$E1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "diff-review on fr/e1-2"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "e1-2" "$FT2_AUDIT" "fr/e1-2" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "0" "AC2 — suffix branch fr/e1-2 (fr-branch identity) → 통과 (slug≠short-title)"

# Case F (fail-closed — legacy): fr/f1 tip 세션에 Branch Context 부재 → 매칭 실패 → 차단(1)
git -C "$FT2" branch fr/f1
git -C "$FT2" switch -q fr/f1
F1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260403_000000_final-diff-review"
mkdir -p "$F1S"
printf '## Status\nclosed\n' > "$F1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$F1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "legacy diff-review on fr/f1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "f1" "$FT2_AUDIT" "fr/f1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "fail-closed — fr tip 세션 Branch Context 부재 → 차단"

# Case G (AC8 — stale/unrelated false-positive 차단): fr/g1 tip 최신 세션이 fr-branch=fr/other(종결)
#   이고 fr/g1 매칭 세션 없음 → 차단(1). short-title 역산 설계였다면 통과했을 false-positive 를 차단.
git -C "$FT2" branch fr/g1
git -C "$FT2" switch -q fr/g1
G1S="$FT2/rd-workflow-workspace/handoffs/review_pipeline/20260404_000000_final-diff-review"
mkdir -p "$G1S"
printf '## Status\nclosed\n\n## Branch Context\n- fr-branch: fr/other\n- short-title: other\n' > "$G1S/SESSION.md"
printf '## Open Issues\n- 없음\n' > "$G1S/CHECKPOINT.md"
git -C "$FT2" add -A && git -C "$FT2" commit -q -m "unrelated closed session on fr/g1"
git -C "$FT2" switch -q main
( project_root="$FT2"; archive_review_precheck "0" "" "g1" "$FT2_AUDIT" "fr/g1" ) 2>/dev/null && rc=0 || rc=1
assert_eq "$rc" "1" "AC8 — stale/unrelated(fr/other) closed 세션만 최신 → 차단 (false-positive 방지)"
rm -rf "$FT2"

# commit_has_archive_signal (review-gate-iteration-commit)
echo "== commit_has_archive_signal =="
SIG_REPO="$(mktemp -d)"
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
AG_REPO="$(mktemp -d)"
mkdir -p "$AG_REPO/rd-workflow/scripts/hooks" "$AG_REPO/rd-workflow/scripts" "$AG_REPO/rd-workflow-workspace/handoffs/review_pipeline" "$AG_REPO/rd-workflow-workspace/backlog/items"
cp "$LITE_HOOKS_DIR/_guard_common.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/pre_commit_archive_gate.sh" "$AG_REPO/rd-workflow/scripts/hooks/"
cp "$LITE_HOOKS_DIR/../_state_common.sh" "$AG_REPO/rd-workflow/scripts/"
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
ARCHIVE_SH="$SCRIPT_DIR/archive.sh"
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
SR_UA="$(mktemp)"
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
SR_INT="$(mktemp -d)"
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
GDB_TMP="$(mktemp -d)"
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

# 조용한 중단 센티넬이 **끝까지 살아 있었는지**를 실행 시점에 확인합니다. bash 는 EXIT trap
# 을 하나만 갖고, 나중에 건 것이 앞의 것을 말없이 지웁니다 — 실제로 그 사고가 있었고
# (임시 디렉터리 정리 trap 이 센티넬을 덮어써 조용한 죽음 3형태가 전부 통과), 소스만 봐서는
# 드러나지 않았습니다. 이 단언이 실패하면 센티넬은 이미 없는 상태입니다.
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
