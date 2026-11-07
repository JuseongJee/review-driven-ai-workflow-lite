#!/usr/bin/env bash
# batch_legacy.sh 계약 시험. 실행: /bin/bash rd-workflow/scripts/fr_do/test_batch_legacy.sh
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/fr-do-legacy.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
HEAD1="/fr batch 는 /fr do --headless 로 바뀌었습니다. 이번 배포까지 별칭으로 동작하고 다음 배포에서 없어집니다."
HEAD2="발행 기본값은 push(원격까지)입니다 — --finish merge 로 바꿀 수 있습니다."
fail=0
P() { echo "PASS $1"; }
F() { echo "FAIL $1: $2"; fail=1; }
# run <이름> <manifest 내용|-> — 출력 $T/<이름>.out, rc $RC
run() {
  local d="$T/$1"; mkdir -p "$d/rd-workflow" "$d/rd-workflow-workspace"
  git -C "$d" init -q -b main; cp -R "$SRC" "$d/rd-workflow/scripts"
  [ "$2" = - ] || printf '%s' "$2" > "$d/rd-workflow-workspace/.batch-manifest.json"
  bash "$d/rd-workflow/scripts/fr_do/batch_legacy.sh" > "$T/$1.out" 2>&1; RC=$?
}
line() { grep -qxF -- "$2" "$T/$1.out" && P "$1: $2" || F "$1" "줄 없음 '$2' — $(tr '\n' '|' < "$T/$1.out")"; }
nlines() { [ "$(wc -l < "$T/$1.out" | tr -d ' ')" = "$2" ] && P "$1: ${2}줄" || F "$1" "줄 수 $(wc -l < "$T/$1.out") (기대 $2) — $(tr '\n' '|' < "$T/$1.out")"; }
rc0() { [ "$RC" = 0 ] && P "$1: rc 0" || F "$1" "rc=$RC"; }

run legacy_no_manifest -; line legacy_no_manifest "$HEAD1"; line legacy_no_manifest "$HEAD2"; nlines legacy_no_manifest 2; rc0 legacy_no_manifest
M='{"status":"running","items":[
 {"slug":"a","order":1,"state":"completed","feasibility":"eligible"},
 {"slug":"b","order":3,"state":"pending","feasibility":"eligible"},
 {"slug":"c","order":2,"state":"skipped","feasibility":"excluded"},
 {"slug":"d","order":0,"state":"running","feasibility":"eligible"}]}'
run legacy_running_manifest "$M"; line legacy_running_manifest "$HEAD1"
line legacy_running_manifest "남은 batch manifest 를 발견했습니다 — 남은 항목은 /fr do <slug들> 로 이어 처리하십시오: d b"; rc0 legacy_running_manifest
run legacy_broken_json '{not json'; line legacy_broken_json "$HEAD1"
grep -q "남은 batch manifest 를 읽지 못했습니다: .*\.batch-manifest\.json — 직접 열어 남은 항목을 확인하십시오" "$T/legacy_broken_json.out" \
  && P "legacy_broken_json: 읽지 못함 안내" || F legacy_broken_json "안내 없음 — $(tr '\n' '|' < "$T/legacy_broken_json.out")"
rc0 legacy_broken_json
run legacy_completed_manifest '{"status":"completed","items":[{"slug":"b","order":1,"state":"pending","feasibility":"eligible"}]}'
line legacy_completed_manifest "$HEAD1"; nlines legacy_completed_manifest 2; rc0 legacy_completed_manifest
[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
