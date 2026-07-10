#!/usr/bin/env bash
# test_sync_template.sh — sync_template.sh 타입 가드·버전 가드 단위 테스트 (self_test.sh가 실행)
# fixture: mktemp에 원격 대역 git repo와 프로젝트 구조를 구성 — 네트워크 불필요
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FULL_OLD="2026-07-01-120000"
FULL_NEW="2026-07-08-120000"
LITE_OLD="lite-2026-07-01-120000"
LITE_NEW="lite-2026-07-08-120000"

make_remote() { # make_remote <dir> <version값|-> ; '-'는 VERSION 파일 없음
  local dir="$1" ver="$2"
  mkdir -p "$dir/rd-workflow"
  [[ "$ver" != "-" ]] && printf '%s\n' "$ver" > "$dir/rd-workflow/VERSION"
  git -C "$dir" init --quiet
  git -C "$dir" -c user.email=t@t.t -c user.name=t add -A
  git -C "$dir" -c user.email=t@t.t -c user.name=t commit --quiet --allow-empty -m fixture
}

make_project() { # make_project <dir> <version값|->
  local dir="$1" ver="$2"
  mkdir -p "$dir/rd-workflow/scripts"
  cp "$SCRIPT_DIR/sync_template.sh" "$dir/rd-workflow/scripts/"
  [[ "$ver" != "-" ]] && printf '%s\n' "$ver" > "$dir/rd-workflow/VERSION"
}

run_sync() { # run_sync <proj> <remote> [flags...] — 결과를 $OUT/$RC에 저장
  local proj="$1" remote="$2"; shift 2
  OUT="$(bash "$proj/rd-workflow/scripts/sync_template.sh" "$remote" "$@" 2>&1)"; RC=$?
  if [[ "$RC" == "0" ]]; then
    # 통과 시 마지막 줄이 임시 clone 경로 — 테스트에서는 즉시 정리
    local clone_path
    clone_path="$(printf '%s\n' "$OUT" | tail -1)"
    [[ -d "$clone_path" ]] && rm -rf "$(dirname "$clone_path")"
  fi
}

expect() { # expect <설명> <기대RC> <포함문자열|-> [비포함문자열]
  local desc="$1" want_rc="$2" want_sub="$3" not_sub="${4:-}"
  local ok=1
  [[ "$RC" != "$want_rc" ]] && { echo "FAIL: $desc (exit $RC != $want_rc)"; ok=0; }
  if [[ "$want_sub" != "-" && "$OUT" != *"$want_sub"* ]]; then
    echo "FAIL: $desc (출력에 '$want_sub' 없음)"; ok=0
  fi
  if [[ -n "$not_sub" && "$OUT" == *"$not_sub"* ]]; then
    echo "FAIL: $desc (출력에 '$not_sub' 있음)"; ok=0
  fi
  if [[ "$ok" == "1" ]]; then echo "ok: $desc"; else FAIL=1; fi
}

# fixture 준비 -------------------------------------------------------------
make_remote "$WORK/r_lite" "$LITE_NEW"
make_remote "$WORK/r_lite_old" "$LITE_OLD"
make_remote "$WORK/r_full_new" "$FULL_NEW"
make_remote "$WORK/r_full_old" "$FULL_OLD"
make_remote "$WORK/r_bad" "v1.2.3"
make_project "$WORK/p_full_old" "$FULL_OLD"
make_project "$WORK/p_full_new" "$FULL_NEW"
make_project "$WORK/p_lite" "$LITE_NEW"
make_project "$WORK/p_novers" "-"

# 1. full 프로젝트 + lite 원격 → 타입 불일치 차단 (AC 1)
run_sync "$WORK/p_full_old" "$WORK/r_lite"
expect "full+lite 교차 차단" 1 "템플릿 타입 불일치"

# 2. lite 프로젝트 + full 원격 → 타입 불일치 차단, 다운그레이드 오진 없음 (AC 2)
run_sync "$WORK/p_lite" "$WORK/r_full_new"
expect "lite+full 교차 차단 (오진 메시지 없음)" 1 "템플릿 타입 불일치" "오래되었습니다"

# 3. full↔full 업그레이드 → 통과 (AC 3)
run_sync "$WORK/p_full_old" "$WORK/r_full_new"
expect "같은 타입 업그레이드 통과" 0 "버전 확인 통과"

# 4. full↔full 다운그레이드 → 차단 후 --force 통과 (AC 3)
run_sync "$WORK/p_full_new" "$WORK/r_full_old"
expect "같은 타입 다운그레이드 차단" 1 "오래되었습니다"
run_sync "$WORK/p_full_new" "$WORK/r_full_old" --force
expect "같은 타입 다운그레이드 --force 통과" 0 "-"

# 5. 로컬 VERSION 부재 → 타입 미확정 차단 (AC 4)
run_sync "$WORK/p_novers" "$WORK/r_full_new"
expect "로컬 VERSION 부재 차단" 1 "템플릿 타입을 확정할 수 없습니다"

# 6. 원격 VERSION 형식 불일치 → 타입 미확정 차단 (AC 4)
run_sync "$WORK/p_full_old" "$WORK/r_bad"
expect "형식 불일치 VERSION 차단" 1 "템플릿 타입을 확정할 수 없습니다"

# 7. 교차 + --allow-type-mismatch → 경고와 함께 통과 (AC 5 복구 경로)
run_sync "$WORK/p_full_old" "$WORK/r_lite" --allow-type-mismatch
expect "--allow-type-mismatch 우회 통과" 0 "경고: --allow-type-mismatch"

# 8. 교차 + --force만 → 여전히 차단 (--force 비우회, AC 5)
run_sync "$WORK/p_full_old" "$WORK/r_lite" --force
expect "--force는 타입 불일치 비우회" 1 "템플릿 타입 불일치"

# 9. same-type 다운그레이드 + --allow-type-mismatch → 여전히 차단 (플래그가 same-type 버전 가드 비우회)
run_sync "$WORK/p_full_new" "$WORK/r_full_old" --allow-type-mismatch
expect "same-type 다운그레이드는 --allow-type-mismatch 비우회" 1 "오래되었습니다"

# 10. lite↔lite 다운그레이드 → 차단 (같은 타입 내 lite 사전순 비교 정상 동작)
run_sync "$WORK/p_lite" "$WORK/r_lite_old"
expect "lite 같은 타입 다운그레이드 차단" 1 "오래되었습니다"

if [[ "$FAIL" == "0" ]]; then
  echo "test_sync_template: 전체 통과"
else
  echo "test_sync_template: 실패 있음" >&2
  exit 1
fi
