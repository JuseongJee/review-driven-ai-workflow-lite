#!/usr/bin/env bash
# test_fr_related_history.sh — fr_related_history.sh 판정 규칙 단위 테스트.
# mktemp 임시 저장소에서만 돌고 trap 으로 지운다. 실제 저장소는 건드리지 않는다.
# 케이스마다 저장소를 새로 만든다(이력이 섞이면 어느 단언이 걸렸는지 가려진다).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/fr_related_history.sh"
FAIL=0
base=""
cleanup() { [ -n "$base" ] && rm -rf "$base"; return 0; }
trap cleanup EXIT
base="$(mktemp -d)" || { echo "test_fr_related_history.sh: 임시 디렉터리 생성 실패" >&2; exit 1; }
base="$(cd "$base" && pwd -P)"
# 사용자 전역 git 설정(hooks·서명 등)에 흔들리지 않게 하고, 저장소마다 config 호출을 줄인다.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

REPO=""
DETAIL=""
new_repo() { # 케이스마다 새 저장소. DETAIL 은 상세 파일의 절대 경로.
  rm -rf "${base:?}/repo"
  REPO="${base}/repo"
  mkdir -p "${REPO}/items" "${REPO}/rd-workflow" "${REPO}/scripts"
  git -C "$REPO" init -q
  DETAIL="${REPO}/items/fr.md"
}

commit_all() { # commit_all <제목>
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -q -m "$1"
}

bump() { # bump <root 상대 경로> — 내용을 바꿔 쓴다
  mkdir -p "${REPO}/${1%/*}"
  printf '%s\n' "$RANDOM$RANDOM" >> "${REPO}/$1"
}

detail() { # detail <related files 줄 전체 | ''> — 상세 파일 작성
  { printf '# fr\n- status: open\n'
    [ -n "$1" ] && printf '%s\n' "$1"
  } > "$DETAIL"
}

run() { # run [인자...] — stdout 을 OUT, exit 코드를 RC 에 담는다
  OUT="$(bash "$TARGET" "$@" 2>/dev/null)"; RC=$?
  FIRST="${OUT%%$'\n'*}"
}

check() { # check <설명> <기대> <실제>
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "  FAIL: $1" >&2; echo "    기대: [$2]" >&2; echo "    실제: [$3]" >&2; FAIL=1; fi
}

check_contains() { # check_contains <설명> <부분문자열> <실제>
  case "$3" in *"$2"*) echo "  ok: $1" ;;
    *) echo "  FAIL: $1" >&2; echo "    기대 포함: [$2]" >&2; echo "    실제: [$3]" >&2; FAIL=1 ;; esac
}

echo "[변경 있음]"
new_repo
bump rd-workflow/x.sh; detail '- related files: `rd-workflow/x.sh`'; commit_all "docs: 상세 등록"
bump rd-workflow/x.sh; commit_all "fix: 첫 수정"
bump rd-workflow/x.sh; commit_all "fix: 두번째 수정"
run "$DETAIL" --root "$REPO"
check "rc 0" "0" "$RC"
check_contains "첫 줄 변경 2건" "변경 2건" "$FIRST"
check_contains "둘째 줄 마지막 커밋 제목" "fix: 두번째 수정" "$(printf '%s\n' "$OUT" | sed -n 2p)"

echo "[변경 없음]"
new_repo
bump rd-workflow/x.sh; detail '- related files: `rd-workflow/x.sh`'; commit_all "docs: 상세 등록"
bump scripts/other.sh; commit_all "chore: 무관한 수정"
run "$DETAIL" --root "$REPO"
check_contains "첫 줄 변경 0건" "변경 0건" "$FIRST"

echo "[검사 대상 없음]"
new_repo
bump rd-workflow/x.sh; detail ''; commit_all "docs: 상세 등록"
bump rd-workflow/x.sh; commit_all "fix: 수정"
run "$DETAIL" --root "$REPO"
check_contains "첫 줄 검사 대상 없음" "검사 대상 없음" "$FIRST"

echo "[백틱 없음]"
new_repo
bump rd-workflow/x.sh; bump scripts/y.sh
detail '- related files: rd-workflow/x.sh, scripts/y.sh (설명)'; commit_all "docs: 상세 등록"
bump rd-workflow/x.sh; commit_all "fix: x 수정"
bump scripts/y.sh; commit_all "fix: y 수정"
run "$DETAIL" --root "$REPO"
check_contains "변경 2건" "변경 2건" "$FIRST"
check_contains "경로 2개" "경로 2개" "$FIRST"

echo "[미커밋 상세]"
new_repo
bump rd-workflow/x.sh; commit_all "chore: 초기"
detail '- related files: `rd-workflow/x.sh`'
run "$DETAIL" --root "$REPO"
check_contains "판정 불가 기준점 없음" "판정 불가 (기준점 없음" "$FIRST"

echo "[얕은 clone]"
new_repo
bump rd-workflow/x.sh; detail '- related files: `rd-workflow/x.sh`'; commit_all "docs: 상세 등록"
bump rd-workflow/x.sh; commit_all "fix: 수정"
git clone -q --depth 1 "file://${REPO}" "${base}/shallow" 2>/dev/null
run "${base}/shallow/items/fr.md" --root "${base}/shallow"
check_contains "판정 불가 이력 불완전" "판정 불가 (이력 불완전" "$FIRST"
rm -rf "${base}/shallow"

echo "[경로 삭제 뒤]"
new_repo
bump rd-workflow/x.sh; detail '- related files: `rd-workflow/x.sh`'; commit_all "docs: 상세 등록"
bump rd-workflow/x.sh; commit_all "fix: 수정"
git -C "$REPO" rm -q rd-workflow/x.sh; commit_all "chore: 삭제"
run "$DETAIL" --root "$REPO"
check_contains "삭제된 경로도 집계" "변경 2건" "$FIRST"

echo "[상세 rename]"
new_repo
bump rd-workflow/x.sh; detail '- related files: `rd-workflow/x.sh`'; commit_all "docs: 상세 등록"
bump rd-workflow/x.sh; commit_all "fix: 수정"
git -C "$REPO" mv items/fr.md items/renamed.md; commit_all "docs: 상세 이름 변경"
run "${REPO}/items/renamed.md" --root "$REPO"
check_contains "rename 뒤에도 원래 추가 시점 기준" "변경 1건" "$FIRST"

echo "[병합 커밋]"
# 일반 병합은 이력 단순화로 한 번만 세고, 병합 때만 생긴 수정은 셉니다.
new_repo
bump rd-workflow/x.sh; detail '- related files: `rd-workflow/x.sh`'; commit_all "docs: 상세 등록"
trunk="$(git -C "$REPO" symbolic-ref --short HEAD)"
git -C "$REPO" checkout -q -b side
bump rd-workflow/x.sh; commit_all "fix: 분기에서 수정"
git -C "$REPO" checkout -q "$trunk"
bump scripts/other.sh; commit_all "chore: 무관한 수정"
git -C "$REPO" merge -q --no-ff -m "merge: side" side >/dev/null 2>&1
run "$DETAIL" --root "$REPO"
check_contains "일반 병합은 분기 커밋 1건만" "변경 1건" "$FIRST"
git -C "$REPO" checkout -q -b side2 HEAD~1
bump scripts/a.sh; commit_all "chore: 분기 무관 수정"
git -C "$REPO" checkout -q "$trunk"
git -C "$REPO" merge -q --no-ff --no-commit side2 >/dev/null 2>&1
bump rd-workflow/x.sh; commit_all "merge: side2 와 함께 x 수정"
run "$DETAIL" --root "$REPO"
check_contains "병합 때만 생긴 수정도 집계" "변경 2건" "$FIRST"
check_contains "목록 첫 줄이 그 병합" "merge: side2 와 함께 x 수정" "$(printf '%s\n' "$OUT" | sed -n 2p)"

echo "[인자 없음]"
run
check "rc 2" "2" "$RC"

if [ "$FAIL" -eq 0 ]; then echo "test_fr_related_history.sh: PASS"; exit 0; fi
echo "test_fr_related_history.sh: FAIL" >&2; exit 1
