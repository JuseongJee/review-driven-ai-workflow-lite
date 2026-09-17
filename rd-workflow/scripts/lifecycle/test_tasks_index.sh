#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1" >&2; }
pass() { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }

TMP="$(mktemp -d)" || { echo "test_tasks_index.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_tasks_index.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# macOS 는 /var -> /private/var 심링크다. mktemp 가 돌려주는 $TMP 는 심링크를 통과한
# 경로이지만, git rev-parse --path-format=absolute 는 실경로(canonical path)를
# 돌려준다. 이 한 줄로 $TMP 자체를 실경로로 맞춰야 아래 접두사 비교가 같은 표현을
# 비교한다 — 비교 로직을 느슨하게 바꾸는 것이 아니라 두 경로 표현을 정규화하는 것이다.
TMP="$(cd "$TMP" && pwd -P)"
mkdir -p "$TMP/rd-workflow-workspace/.lifecycle"
git -C "$TMP" init -q
# fixture 자체의 identity. GIT_CONFIG_GLOBAL=/dev/null 로 전역을 비웠으므로, 이것이 없으면
# 개발자 전역 설정이 있는 머신에서만 commit 이 통과한다.
git -C "$TMP" config user.name "rd-test"
git -C "$TMP" config user.email "rd-test@example.invalid"
export project_root="$TMP"
# tasks_shared_dir 는 `project_root` 의 저장소를 조회한다(아래 10번 회귀). cwd 도 함께
# 맞춰 두어 두 값이 갈리지 않게 한다 — 이 스위트의 다른 케이스는 그 구분을 시험하지 않는다.
cd "$TMP"
source "$SCRIPT_DIR/_tasks_index.sh"
[[ "$(tasks_shared_dir)" == "$TMP"/* ]] \
  || { printf '  FAIL: 공유 위치가 임시 저장소 밖을 가리킨다: %s\n' "$(tasks_shared_dir)" >&2; exit 1; }

# 1) upsert → get
tasks_index_upsert alpha fr-branch=fr/alpha worktree-path=/tmp/a launch=none
[[ "$(tasks_index_get alpha fr-branch)" == "fr/alpha" ]] \
  && pass "upsert 후 get 이 값을 돌려준다" || fail "upsert/get"

# 2) upsert 재호출은 같은 slug 의 행을 늘리지 않고 갱신한다
tasks_index_upsert alpha launch=ok
[[ "$(tasks_index_get alpha launch)" == "ok" ]] \
  && [[ "$(tasks_index_slugs | grep -c '^alpha$')" == "1" ]] \
  && pass "재 upsert 는 행을 늘리지 않고 갱신한다" || fail "upsert 갱신"

# 3) 다른 slug 는 서로 영향을 주지 않는다
tasks_index_upsert beta fr-branch=fr/beta launch=none
[[ "$(tasks_index_get alpha launch)" == "ok" ]] \
  && [[ "$(tasks_index_get beta launch)" == "none" ]] \
  && pass "행끼리 독립이다" || fail "행 독립성"

# 4) remove 는 그 행만 지운다
tasks_index_remove alpha
[[ -z "$(tasks_index_get alpha fr-branch || true)" ]] \
  && [[ "$(tasks_index_get beta fr-branch)" == "fr/beta" ]] \
  && pass "remove 는 대상 행만 지운다" || fail "remove"

# 5) 락: 획득 후 재획득은 실패하고 점유자 정보를 낸다
tasks_lock_acquire promote beta && pass "락 획득" || fail "락 획득"
if tasks_lock_acquire archive gamma 2>"$TMP/err"; then
  fail "점유 중인데 락이 두 번 잡혔다"
else
  grep -q "beta" "$TMP/err" && pass "점유 실패 시 점유자 정보를 낸다" || fail "점유자 정보"
fi

# 6) 해제 후에는 다시 획득된다
tasks_lock_release
tasks_lock_acquire archive gamma && pass "해제 후 재획득" || fail "해제 후 재획득"
tasks_lock_release

# 7) 죽은 pid 의 락은 "불확실" 로 보고 중단하며, 회수 명령을 안내한다 (자동 회수하지 않는다)
#    주의: 락 획득은 반드시 **현재 셸에서** 한다. 서브셸·파이프 안에서 잡으면 $$ 가
#    살아 있어 판정이 뒤집힌다.
mkdir -p "$(tasks_shared_dir)/tasks.lock"
printf 'pid=999999\ncmd=promote\nslug=dead\nstarted-at=2026-01-01-0000\n' \
  > "$(tasks_shared_dir)/tasks.lock/owner"
if tasks_lock_acquire promote delta 2>"$TMP/err2"; then
  fail "죽은 pid 락을 자동 회수해 버렸다 (남의 새 락을 지울 수 있는 경로)"
else
  grep -q "rm -rf" "$TMP/err2" && grep -q "dead" "$TMP/err2" \
    && pass "불확실한 락은 중단하고 회수 명령을 안내한다" || fail "회수 안내"
fi
rm -rf "$(tasks_shared_dir)/tasks.lock"

# 8) owner 가 없는 락(mkdir 직후 중단)도 같은 "불확실" 로 다룬다
mkdir -p "$(tasks_shared_dir)/tasks.lock"
if tasks_lock_acquire promote delta 2>/dev/null; then
  fail "owner 부재 락을 그냥 가져갔다"
else
  pass "owner 부재 락도 중단한다"
fi
rm -rf "$(tasks_shared_dir)/tasks.lock"

# 9) 공유 위치는 브랜치 체크아웃과 무관하다
before="$(tasks_index_path)"
git -C "$TMP" commit -q --allow-empty -m init
git -C "$TMP" checkout -q -b other
[[ "$(tasks_index_path)" == "$before" ]] \
  && pass "브랜치를 바꿔도 공유 위치가 같다" || fail "공유 위치 불변"

# 10) 공유 위치는 **cwd 가 아니라 project_root** 를 따른다 (final diff review)
#     `rd` 는 promote.sh·promote_rollback.sh 와 달리 `cd "$project_root"` 를 하지 않으므로,
#     이 구분이 깨지면 다른 저장소 안에서 부른 `rd task ...` 가 **그 저장소의 색인에 쓴다.**
#     실제로 이 프로젝트의 테스트가 개발자의 실제 저장소 색인에 행을 남긴 사고가 있었다.
OTHER="$(mktemp -d)" || { echo "test_tasks_index.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$OTHER" && -d "$OTHER" ]] || { echo "test_tasks_index.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
OTHER="$(cd "$OTHER" && pwd -P)"
git -C "$OTHER" init -q
(
  cd "$OTHER"                      # ← cwd 는 남의 저장소, project_root 는 $TMP 그대로
  [[ "$(tasks_shared_dir)" == "$TMP"/* ]] || exit 1
  tasks_index_upsert crosscheck fr-branch=fr/crosscheck
) && [[ "$(tasks_index_get crosscheck fr-branch)" == "fr/crosscheck" ]] \
  && pass "공유 위치는 cwd 가 아니라 project_root 를 따른다" || fail "cwd 의 저장소를 색인 대상으로 삼았다"
[[ ! -e "$OTHER/.git/rd-workflow" ]] \
  && pass "cwd 쪽 저장소에는 아무것도 만들지 않는다" || fail "남의 저장소에 .git/rd-workflow 를 만들었다"
rm -rf "$OTHER"

printf 'tasks_index: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
