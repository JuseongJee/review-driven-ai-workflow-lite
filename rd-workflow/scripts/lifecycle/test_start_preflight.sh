#!/usr/bin/env bash
# test_start_preflight.sh — 시작 계약 진입점 출력·종료 코드 계약 (REQUEST AC 10·16 기계 부분)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$SCRIPT_DIR/.." && pwd)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
T="$(mktemp -d)" || { echo "test_start_preflight.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$T" && -d "$T" ]] || { echo "test_start_preflight.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }
IDX=rd-workflow-workspace/backlog/FUTURE_REQUESTS.md
mk_repo() {
  mkdir -p "$1" && ( cd "$1" && git init -q && git checkout -q -b main 2>/dev/null && git config user.email t@e.com && git config user.name t \
    && mkdir -p rd-workflow rd-workflow-workspace/backlog/items rd-workflow-workspace/raw-captures && cp -R "$SCRIPTS" rd-workflow/scripts \
    && printf '# FR\n\n## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |\n|---|---|---|---|---|---|---|\n' > "$IDX" && git add -A && git commit -q -m init )
}
reg_commit() { ( cd "$1" && printf '| 2026-02-02 | %s | s | tooling | idea | - | [상세](items/2026-02-02-%s.md) |\n' "$2" "$2" >> "$IDX" \
  && printf '# %s\n' "$2" > "rd-workflow-workspace/backlog/items/2026-02-02-$2.md" && git add -A && git commit -q -m "docs: FR 등록 — $2" ); }
pf() { ( cd "$1" && bash rd-workflow/scripts/lifecycle/start_preflight.sh 2>&1 ); }

R="$T/local"; mk_repo "$R"
out="$(pf "$R")"; rc=$?
[[ "$rc" == 0 && "$out" == *"mode=local-only"* && "$out" == *"push 예정: 없음"* && "$out" == *"미병합 브랜치 FR 후보: 없음"* ]] && pass "local-only → exit 0, push 없음, 후보 없음" || fail "local-only rc=$rc — $out"

R="$T/remote"; mk_repo "$R"; B="$T/remote.git"; git init -q --bare "$B"
( cd "$R" && git remote add origin "$B" && git push -q -u origin main )
out="$(pf "$R")"; rc=$?
[[ "$rc" == 0 && "$out" == *"decision=synchronized"* && "$out" == *"push 예정: archive.sh 경유"* ]] && pass "synchronized → exit 0" || fail "sync rc=$rc — $out"
reg_commit "$R" a1; reg_commit "$R" a2
out="$(pf "$R")"; rc=$?
[[ "$rc" == 0 && "$out" == *"decision=auto-adopt"* && "$out" == *"push 예정: archive.sh 경유(기본 브랜치 미push 2개 — 전부 FR 등록 커밋, 자동 채택)"* ]] && pass "등록 커밋만 ahead → auto-adopt 문구" || fail "auto-adopt rc=$rc — $out"
( cd "$R" && echo x > other.txt && git add -A && git commit -q -m other )
out="$(pf "$R")"; rc=$?
[[ "$rc" == 10 && "$out" == *"decision=handover-ahead"* && "$out" == *"push 예정: 인계"* ]] && pass "일반 커밋 섞임 → exit 10 인계" || fail "handover rc=$rc — $out"
( cd "$R" && git checkout -q -b fr/lost && printf '# lost\n' > rd-workflow-workspace/backlog/items/2026-02-03-lost.md && git add -A && git commit -q -m lost && git checkout -q main )
out="$(pf "$R")"
[[ "$out" == *"미병합 브랜치 FR 후보: 1건"* && "$out" == *"FR lost"* ]] && pass "미병합 브랜치 FR 후보 줄 노출" || fail "후보 줄 — $out"
( cd "$R" && git remote set-url origin /nonexistent-remote )
out="$(pf "$R")"; rc=$?
[[ "$rc" == 10 && "$out" == *"fetch=failed"* && "$(printf '%s\n' "$out" | sed -n 1p)" == *"decision=handover-fetch-failed"* ]] && pass "fetch 실패 → 인계(첫 줄 decision 도 handover-fetch-failed)" || fail "fetch rc=$rc — $out"
echo "start_preflight: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
