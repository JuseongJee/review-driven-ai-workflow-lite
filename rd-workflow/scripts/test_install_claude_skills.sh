#!/usr/bin/env bash
# test_install_claude_skills.sh — install_claude_skills.sh 단위 테스트 (self_test.sh가 실행)
# copy 모드 설치본 갱신(백업 후 재복사)과 기존 link/skip 동작 회귀를 검증한다.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
CLEANUP_DIRS=()
trap 'for d in "${CLEANUP_DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done' EXIT

ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# 샌드박스: 가짜 프로젝트 루트 구성 (project scope → <sandbox>/.claude/skills 에 설치됨)
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  CLEANUP_DIRS+=("$SANDBOX")
  mkdir -p "${SANDBOX}/rd-workflow/scripts" \
           "${SANDBOX}/rd-workflow/claude_skills/alpha" \
           "${SANDBOX}/rd-workflow/claude_skills/beta"
  cp "${SCRIPT_DIR}/install_claude_skills.sh" "${SANDBOX}/rd-workflow/scripts/"
  printf 'alpha v1\n' > "${SANDBOX}/rd-workflow/claude_skills/alpha/SKILL.md"
  printf 'beta v1\n' > "${SANDBOX}/rd-workflow/claude_skills/beta/SKILL.md"
}

run_install() { # run_install [mode] [skill...] — project scope 고정
  OUT="$(cd "$SANDBOX" && bash rd-workflow/scripts/install_claude_skills.sh project "$@" 2>&1)"
  RC=$?
}

# --- T1: 신규 copy 설치 ---
setup_sandbox
run_install copy
[[ "$RC" == 0 ]] && ok "T1-a copy 설치 exit 0" || fail "T1-a copy 설치 exit $RC"
[[ -d "${SANDBOX}/.claude/skills/alpha" && ! -L "${SANDBOX}/.claude/skills/alpha" ]] \
  && ok "T1-b alpha가 real dir로 설치됨" || fail "T1-b alpha 설치 상태 이상"
grep -q 'alpha v1' "${SANDBOX}/.claude/skills/alpha/SKILL.md" \
  && ok "T1-c 내용 일치" || fail "T1-c 내용 불일치"

# --- T2: 동일 내용 재실행 → up-to-date skip ---
run_install copy
echo "$OUT" | grep -q "already up to date (copy): alpha" \
  && ok "T2-a 동일 내용 skip 메시지" || fail "T2-a skip 메시지 없음: $OUT"
[[ ! -d "${SANDBOX}/.claude/skills-backup" ]] \
  && ok "T2-b 불필요한 백업 없음" || fail "T2-b 백업이 생성됨"

# --- T3: source 변경 후 기본(link) mode 재실행 → 백업 후 갱신 ---
printf 'alpha v2\n' > "${SANDBOX}/rd-workflow/claude_skills/alpha/SKILL.md"
run_install link
echo "$OUT" | grep -q "refreshed: alpha" \
  && ok "T3-a refreshed 출력" || fail "T3-a refreshed 없음: $OUT"
grep -q 'alpha v2' "${SANDBOX}/.claude/skills/alpha/SKILL.md" \
  && ok "T3-b dst가 최신 내용" || fail "T3-b dst 갱신 안 됨"
[[ ! -L "${SANDBOX}/.claude/skills/alpha" ]] \
  && ok "T3-c copy본이 copy로 유지 (link 전환 안 됨)" || fail "T3-c symlink로 전환됨"
backup_alpha="$(find "${SANDBOX}/.claude/skills-backup" -maxdepth 1 -name 'alpha-*' -type d 2>/dev/null | head -1)"
[[ -n "$backup_alpha" ]] && grep -q 'alpha v1' "${backup_alpha}/SKILL.md" \
  && ok "T3-d 백업에 구버전 보존" || fail "T3-d 백업 없음/내용 이상"
echo "$OUT" | grep -q "already up to date (copy): beta" \
  && ok "T3-e 변경 없는 beta는 skip" || fail "T3-e beta 처리 이상: $OUT"

# --- T4: 사용자 추가 파일 → 백업에 보존, dst는 source와 동일해짐 ---
printf 'custom\n' > "${SANDBOX}/.claude/skills/beta/CUSTOM.md"
run_install copy
backup_beta="$(find "${SANDBOX}/.claude/skills-backup" -maxdepth 1 -name 'beta-*' -type d 2>/dev/null | head -1)"
[[ -n "$backup_beta" && -f "${backup_beta}/CUSTOM.md" ]] \
  && ok "T4-a 사용자 파일이 백업에 보존" || fail "T4-a 백업에 CUSTOM.md 없음"
[[ ! -f "${SANDBOX}/.claude/skills/beta/CUSTOM.md" ]] \
  && ok "T4-b dst는 source와 동일 (추가 파일 제거)" || fail "T4-b dst에 CUSTOM.md 잔존"

# --- T5: link 모드 정상 symlink 재실행 → 기존 skip 동작 유지 ---
setup_sandbox
run_install link
run_install link
echo "$OUT" | grep -q "already installed: alpha" \
  && ok "T5-a link 재실행 skip" || fail "T5-a link skip 메시지 없음: $OUT"
[[ -L "${SANDBOX}/.claude/skills/alpha" ]] \
  && ok "T5-b symlink 유지" || fail "T5-b symlink 아님"

# --- T6: dangling symlink → 제거 후 재설치 (기존 동작) ---
setup_sandbox
mkdir -p "${SANDBOX}/.claude/skills"
ln -s "${SANDBOX}/nonexistent-target" "${SANDBOX}/.claude/skills/alpha"
run_install link
[[ "$RC" == 0 && -L "${SANDBOX}/.claude/skills/alpha" && -e "${SANDBOX}/.claude/skills/alpha" ]] \
  && ok "T6 dangling symlink 재설치" || fail "T6 dangling symlink 처리 이상 (exit $RC)"

# --- T7: dst가 일반 파일 → 기존 skip 에러 경로 유지 ---
setup_sandbox
mkdir -p "${SANDBOX}/.claude/skills"
printf 'not a dir\n' > "${SANDBOX}/.claude/skills/alpha"
run_install copy
[[ "$RC" == 0 ]] && echo "$OUT" | grep -q "destination already exists, skipping" \
  && ok "T7-a 일반 파일 skip 메시지 유지" || fail "T7-a skip 경로 회귀 (exit $RC): $OUT"
grep -q 'not a dir' "${SANDBOX}/.claude/skills/alpha" \
  && ok "T7-b 기존 파일 무손상" || fail "T7-b 기존 파일 변경됨"

# --- T8: 임시 복사 실패(백업 루트 쓰기 불가) → 갱신 skip, 기존 설치본 무손상 ---
setup_sandbox
run_install copy
printf 'alpha v2\n' > "${SANDBOX}/rd-workflow/claude_skills/alpha/SKILL.md"
mkdir -p "${SANDBOX}/.claude/skills-backup"
chmod 555 "${SANDBOX}/.claude/skills-backup"
run_install copy
chmod 755 "${SANDBOX}/.claude/skills-backup"
[[ "$RC" == 0 ]] && echo "$OUT" | grep -q "재복사 실패로 갱신을 건너뜁니다" \
  && ok "T8-a 임시 복사 실패 시 graceful skip" || fail "T8-a skip 처리 이상 (exit $RC): $OUT"
grep -q 'alpha v1' "${SANDBOX}/.claude/skills/alpha/SKILL.md" \
  && ok "T8-b 기존 설치본 무손상" || fail "T8-b 설치본 손상/소실"

[[ "$FAIL" == 0 ]] && echo "test_install_claude_skills: ALL PASS" || echo "test_install_claude_skills: FAIL"
exit "$FAIL"
