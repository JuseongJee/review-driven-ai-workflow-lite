#!/usr/bin/env bash
# check_skill_reference_existence.sh 단위 테스트 — 전부 임시 fixture, 순수 스크립트 호출.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/check_skill_reference_existence.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=1; }

# 각 테스트는 독립 fixture 디렉터리를 만들고 끝에 정리한다.
_mk_fixture_root() {
  local fx
  fx="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
  mkdir -p "${fx}/rd-workflow/scripts"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/real.sh"
  printf '%s\n' "$fx"
}

test_normal_case_zero_warnings() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/skill.md" <<'EOF'
실행: `bash rd-workflow/scripts/real.sh`
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "참조 1건 중 경고 0건"; then
    pass "정상 케이스: 경고 0건, exit 0"
  else
    fail "정상 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_normal_case_zero_warnings

test_warning_case_missing_path() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/skill.md" <<'EOF'
실행: `bash rd-workflow/scripts/missing.sh`
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  # fixture 는 1줄이므로 줄번호는 1이다 (F5 — 이전 초안은 2를 기대해 실패했었다).
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "skill.md:1: 참조 경로 없음 — rd-workflow/scripts/missing.sh" \
     && printf '%s' "$out" | grep -q "참조 1건 중 경고 1건"; then
    pass "경고 케이스: exit 0 유지 + 경고 메시지 정확"
  else
    fail "경고 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_warning_case_missing_path

test_placeholder_word_excluded_path_word_kept() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  mkdir -p "${fx}/rd-workflow/scripts/lifecycle"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/lifecycle/promote.sh"
  cat > "${fx}/skill.md" <<'EOF'
`bash rd-workflow/scripts/lifecycle/promote.sh --short-title <slug>`
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  # <slug> 는 별도 단어라 애초에 rd-workflow/ 로 시작하지 않으므로 후보가 아니다.
  # promote.sh 경로는 온전한 단어이자 fixture 에 실재하므로 경고 없이 1건만 잡혀야 한다.
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "참조 1건 중 경고 0건"; then
    pass "플레이스홀더 케이스: <slug>는 후보 아님, 정상 경로는 그대로 인식"
  else
    fail "플레이스홀더 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_variable_prefixed_word_excluded_entirely() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/skill.md" <<'EOF'
`echo $RD_WORKFLOW_DIR/rd-workflow/scripts/x.sh`
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  # 단어 전체가 $ 로 시작해 rd-workflow/ 접두 패턴과 애초에 불일치 — 부분 추출되지 않는다.
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "참조 0건 중 경고 0건"; then
    pass "변수 케이스: \$VAR/rd-workflow/... 단어 전체 제외(부분 추출 없음)"
  else
    fail "변수 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_glob_word_excluded_regardless_of_cwd() {
  local fx out rc saved_cwd empty_cwd
  fx="$(_mk_fixture_root)"
  cat > "${fx}/skill.md" <<'EOF'
`rd-workflow/claude_skills/**/*.md`
EOF
  saved_cwd="$(pwd)"

  # cwd 1: 이 스크립트가 상주하는 저장소 루트 — glob이 실제 파일과 일치할 수 있는
  # 위치(set -f 가 없었다면 Bash pathname expansion으로 다건이 튀어나왔을 곳,
  # spec/plan review Turn 004 F1 재현 지점: 실측 25건).
  cd "$(cd "${SCRIPT_DIR}/../.." && pwd)" || { fail "glob cwd 테스트: repo root cd 실패"; rm -rf "$fx"; return; }
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  cd "$saved_cwd" || true
  if [[ "$rc" -ne 0 ]] || ! printf '%s' "$out" | grep -q "참조 0건 중 경고 0건"; then
    fail "glob cwd 테스트(repo root): rc=$rc out=$out"
    rm -rf "$fx"
    return
  fi

  # cwd 2: glob이 아무것도 일치하지 않는 빈 디렉터리 — 두 cwd에서 결과가 같아야
  # pathname expansion이 차단됐다고 말할 수 있다(fixture만으로는 cwd가 격리되지
  # 않는다는 것이 Turn 004의 핵심 지적이었다).
  empty_cwd="$(mktemp -d)" || { fail "glob cwd 테스트: empty cwd mktemp 실패"; rm -rf "$fx"; return; }
  cd "$empty_cwd" || { fail "glob cwd 테스트: empty cwd 실패"; rm -rf "$fx" "$empty_cwd"; return; }
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  cd "$saved_cwd" || true
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "참조 0건 중 경고 0건"; then
    pass "glob 케이스: cwd(저장소 루트/빈 디렉터리) 무관하게 0건 유지(set -f 로 pathname expansion 차단 확인)"
  else
    fail "glob cwd 테스트(empty): rc=$rc out=$out"
  fi
  rm -rf "$fx" "$empty_cwd"
}

test_placeholder_word_excluded_path_word_kept
test_variable_prefixed_word_excluded_entirely
test_glob_word_excluded_regardless_of_cwd

test_scope_excludes_prose() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/skill.md" <<'EOF'
이 문단은 rd-workflow/scripts/missing.sh 를 코드블록 밖에서 설명만 한다.
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "참조 0건 중 경고 0건"; then
    pass "스코프 케이스: 코드블록 밖 설명문은 스캔하지 않음"
  else
    fail "스코프 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_scope_excludes_prose

test_multiple_inline_spans_same_line() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/second.sh"
  cat > "${fx}/skill.md" <<'EOF'
`bash rd-workflow/scripts/real.sh` 와 `bash rd-workflow/scripts/second.sh` 둘 다 실행한다.
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "참조 2건 중 경고 0건"; then
    pass "다중 인라인 케이스: 한 줄의 백틱 쌍 2개 모두 추출"
  else
    fail "다중 인라인 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_fenced_block_multirow() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/skill.md" <<'EOF'
```bash
bash rd-workflow/scripts/real.sh
bash rd-workflow/scripts/missing.sh
```
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "skill.md:3: 참조 경로 없음 — rd-workflow/scripts/missing.sh" \
     && printf '%s' "$out" | grep -q "참조 2건 중 경고 1건"; then
    pass "fenced 블록 케이스: 코드블록 여러 줄 모두 스캔, 줄번호 정확(3행)"
  else
    fail "fenced 블록 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_multiple_inline_spans_same_line
test_fenced_block_multirow

test_channel_separation() {
  local fx out_stdout out_stderr rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/skill.md" <<'EOF'
`bash rd-workflow/scripts/missing.sh`
EOF
  local stderr_file="${fx}/stderr.out"
  out_stdout="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>"$stderr_file")"; rc=$?
  out_stderr="$(cat "$stderr_file")"
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out_stdout" | grep -q "참조 1건 중 경고 1건" \
     && ! printf '%s' "$out_stdout" | grep -q "참조 경로 없음" \
     && printf '%s' "$out_stderr" | grep -q "참조 경로 없음"; then
    pass "채널 분리 케이스: 요약은 stdout, 경고는 stderr"
  else
    fail "채널 분리 케이스: rc=$rc stdout=$out_stdout stderr=$out_stderr"
  fi
  rm -rf "$fx"
}

test_channel_separation

test_optional_example_file_not_warned() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  mkdir -p "${fx}/rd-workflow/config"
  : > "${fx}/rd-workflow/config/opt.json.example"
  cat > "${fx}/skill.md" <<'EOF'
`rd-workflow/config/opt.json`
`rd-workflow/config/gone.json`
EOF
  out="$(bash "$TARGET" "${fx}/skill.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] \
     && ! printf '%s' "$out" | grep -q "참조 경로 없음 — rd-workflow/config/opt.json" \
     && printf '%s' "$out" | grep -q "참조 경로 없음 — rd-workflow/config/gone.json" \
     && printf '%s' "$out" | grep -q "참조 2건 중 경고 1건 (선택 파일 1건)"; then
    pass "선택 파일 케이스: X.example 존재 시 경고 없이 선택 파일로 집계"
  else
    fail "선택 파일 케이스: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_optional_example_file_not_warned

test_exec_error_missing_input_file() {
  local fx rc
  fx="$(_mk_fixture_root)"
  bash "$TARGET" "${fx}/does-not-exist.md" --root "$fx" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "실행 오류: 입력 파일 부재 → exit 2"
  else
    fail "실행 오류: 입력 파일 부재인데 rc=$rc (기대: 2)"
  fi
  rm -rf "$fx"
}

test_exec_error_unreadable_input_file() {
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "  SKIP: 읽기 불가 케이스 (root로 실행 중이라 permission bit이 무시됨)"
    return
  fi
  local fx rc
  fx="$(_mk_fixture_root)"
  echo "내용" > "${fx}/unreadable.md"
  chmod 000 "${fx}/unreadable.md"
  bash "$TARGET" "${fx}/unreadable.md" --root "$fx" >/dev/null 2>&1
  rc=$?
  chmod 644 "${fx}/unreadable.md"
  if [[ "$rc" -eq 2 ]]; then
    pass "실행 오류: 입력 파일 읽기 불가 → exit 2"
  else
    fail "실행 오류: 읽기 불가인데 rc=$rc (기대: 2)"
  fi
  rm -rf "$fx"
}

test_exec_error_missing_root_tree() {
  local fx rc
  fx="$(mktemp -d)" || { fail "입력 오류(루트 트리 부재): mktemp 실패"; return; }
  echo "내용" > "${fx}/skill.md"
  bash "$TARGET" "${fx}/skill.md" --root "$fx" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "실행 오류: --root에 rd-workflow/ 없음 → exit 2"
  else
    fail "실행 오류: rd-workflow/ 부재인데 rc=$rc (기대: 2)"
  fi
  rm -rf "$fx"
}

test_exec_error_root_flag_missing_value() {
  local fx rc
  fx="$(_mk_fixture_root)"
  echo "내용" > "${fx}/skill.md"
  # --root 뒤에 값이 없다 — 무한 반복하지 않고 유한 시간 내 exit 2 로 끝나야 한다(F2).
  bash "$TARGET" "${fx}/skill.md" --root >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "실행 오류: --root 값 누락 → 유한 시간 내 exit 2 (무한 반복 회귀 anchor)"
  else
    fail "실행 오류: --root 값 누락인데 rc=$rc (기대: 2)"
  fi
  rm -rf "$fx"
}

test_exec_error_missing_input_file
test_exec_error_unreadable_input_file
test_exec_error_missing_root_tree
test_exec_error_root_flag_missing_value

test_selftest_propagates_nonzero_non2_exit() {
  local fx code
  fx="$(mktemp -d)" || { fail "mutation fixture mktemp 실패"; return; }
  mkdir -p "${fx}/rd-workflow/scripts" "${fx}/rd-workflow/claude_skills/dummy"
  echo "# dummy" > "${fx}/rd-workflow/claude_skills/dummy/SKILL.md"
  cp "${SCRIPT_DIR}/self_test.sh" "${fx}/rd-workflow/scripts/self_test.sh"
  # 항상 127로 죽는 스텁 — 실제 스크립트 부재/손상을 흉내낸다.
  cat > "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh" <<'STUBEOF'
#!/usr/bin/env bash
exit 127
STUBEOF
  chmod +x "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh"

  RD_SELFTEST_CHECKER_ONLY=skill_reference_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" >/dev/null 2>&1
  code=$?
  if [[ "$code" -ne 0 ]]; then
    pass "self_test 오류 전파: 하위 스크립트 exit 127도 실패로 잡음(-ne 0 판정)"
  else
    fail "self_test 오류 전파: 하위 스크립트가 127로 죽었는데 rc=0 (F4 회귀)"
  fi
  rm -rf "$fx"
}

test_selftest_find_partial_failure_detected() {
  local fx stub_dir code out
  fx="$(mktemp -d)" || { fail "find 실패 fixture mktemp 실패"; return; }
  mkdir -p "${fx}/rd-workflow/scripts" "${fx}/rd-workflow/claude_skills/dummy"
  echo "# dummy1" > "${fx}/rd-workflow/claude_skills/dummy/SKILL.md"
  echo "# dummy2" > "${fx}/rd-workflow/claude_skills/dummy/OTHER.md"
  cp "${SCRIPT_DIR}/self_test.sh" "${fx}/rd-workflow/scripts/self_test.sh"
  cp "${SCRIPT_DIR}/check_skill_reference_existence.sh" "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh"

  # 대조군 — 스텁 없이 정상 find로 실행하면 통과해야 한다.
  RD_SELFTEST_CHECKER_ONLY=skill_reference_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" >/dev/null 2>&1
  code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "find 실패 대조군: 스텁 없이도 실패함(fixture 자체 결함, rc=$code)"
    rm -rf "$fx"
    return
  fi

  # 실험군 — PATH 맨 앞에 "유효 경로 1개 출력 후 exit 1"하는 find 스텁을 둔다.
  stub_dir="$(mktemp -d)" || { fail "find 스텁 테스트: stub_dir mktemp 실패"; rm -rf "$fx"; return; }
  cat > "${stub_dir}/find" <<STUBEOF
#!/usr/bin/env bash
echo "${fx}/rd-workflow/claude_skills/dummy/SKILL.md"
exit 1
STUBEOF
  chmod +x "${stub_dir}/find"

  out="$(PATH="${stub_dir}:${PATH}" RD_SELFTEST_CHECKER_ONLY=skill_reference_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if [[ "$code" -ne 0 ]] && printf '%s' "$out" | grep -q "find 실패"; then
    pass "find 실패 케이스: 부분 출력 후 비정상 종료를 실패로 잡음(대조군은 통과)"
  else
    fail "find 실패 케이스: rc=$code out=$out"
  fi
  rm -rf "$fx" "$stub_dir"
}

test_selftest_propagates_nonzero_non2_exit
test_selftest_find_partial_failure_detected

exit $FAIL
