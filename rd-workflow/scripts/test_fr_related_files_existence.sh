#!/usr/bin/env bash
# check_fr_related_files_existence.sh 단위 테스트 — 전부 임시 fixture, 순수 스크립트 호출.
# fixture는 전부 백틱으로 감싼 경로를 쓴다 — 실제 FR related files 형식과 일치시켜야
# 백틱 누락류 회귀(spec/plan review F1)를 잡는다.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/check_fr_related_files_existence.sh"
PARSER="${SCRIPT_DIR}/check_skill_reference_existence.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=1; }

_mk_fixture_root() {
  local fx
  fx="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
  mkdir -p "${fx}/rd-workflow/scripts"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/real.sh"
  printf '%s\n' "$fx"
}

test_all_present() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/second.sh"
  cat > "${fx}/item.md" <<'EOF'
# 2026-09-26 fixture
- related files: `rd-workflow/scripts/real.sh` `rd-workflow/scripts/second.sh`
EOF
  out="$(bash "$TARGET" "${fx}/item.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "대상 2개 중 0개 부재"; then
    pass "전부 실재(백틱): 대상 2개 중 0개 부재, exit 0"
  else
    fail "전부 실재(백틱): rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_partial_missing_channel_separated() {
  local fx out_stdout out_stderr rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/item.md" <<'EOF'
# fixture
- related files: `rd-workflow/scripts/real.sh` `rd-workflow/scripts/missing.sh`
EOF
  out_stdout="$(bash "$TARGET" "${fx}/item.md" --root "$fx" 2>/tmp/frrel_stderr_test.$$)"; rc=$?
  out_stderr="$(cat /tmp/frrel_stderr_test.$$)"; rm -f /tmp/frrel_stderr_test.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out_stdout" | grep -q "대상 2개 중 1개 부재" \
     && ! printf '%s' "$out_stdout" | grep -q "참조 경로 없음" \
     && printf '%s' "$out_stderr" | grep -q "item.md:2: 참조 경로 없음 — rd-workflow/scripts/missing.sh"; then
    pass "일부 부재: 요약은 stdout, 경고는 stderr, 파일:줄번호:경로 정확"
  else
    fail "일부 부재: rc=$rc stdout=$out_stdout stderr=$out_stderr"
  fi
  rm -rf "$fx"
}

test_all_missing() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/item.md" <<'EOF'
# fixture
- related files: `rd-workflow/scripts/gone-a.sh` `rd-workflow/scripts/gone-b.sh`
EOF
  out="$(bash "$TARGET" "${fx}/item.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "대상 2개 중 2개 부재"; then
    pass "전부 부재: 대상 2개 중 2개 부재, exit 0"
  else
    fail "전부 부재: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_no_related_files_line() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/item.md" <<'EOF'
# fixture
- summary: related files 줄이 아예 없다
EOF
  out="$(bash "$TARGET" "${fx}/item.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "검사 대상 없음"; then
    pass "대상 없음(줄 부재): 검사 대상 없음, exit 0"
  else
    fail "대상 없음(줄 부재): rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_related_files_line_only_excluded_tokens() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  cat > "${fx}/item.md" <<'EOF'
# fixture
- related files: $VAR/rd-workflow/x.sh 그리고 `rd-workflow/**/*.md`
EOF
  out="$(bash "$TARGET" "${fx}/item.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "검사 대상 없음"; then
    pass "대상 없음(전부 제외/백틱 밖 토큰): 검사 대상 없음, exit 0"
  else
    fail "대상 없음(전부 제외/백틱 밖 토큰): rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

test_cwd_independent_default_root() {
  local fx out1 out2 rc1 rc2 saved_cwd consumer_target consumer_parser
  fx="$(_mk_fixture_root)"
  mkdir -p "${fx}/rd-workflow/scripts"
  cp "$TARGET" "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh"
  cp "$PARSER" "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh"
  consumer_target="${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh"
  cat > "${fx}/item.md" <<'EOF'
# fixture
- related files: `rd-workflow/scripts/real.sh` `rd-workflow/scripts/missing.sh`
EOF
  saved_cwd="$(pwd)"

  cd "$(cd "${SCRIPT_DIR}/../.." && pwd)" || { fail "cwd 독립성: repo root cd 실패"; rm -rf "$fx"; return; }
  out1="$(bash "$consumer_target" "${fx}/item.md" 2>&1)"; rc1=$?
  cd "$saved_cwd" || true

  cd "${fx}/rd-workflow/scripts" || { fail "cwd 독립성: fixture 하위 cd 실패"; rm -rf "$fx"; return; }
  out2="$(bash "$consumer_target" "${fx}/item.md" 2>&1)"; rc2=$?
  cd "$saved_cwd" || true

  if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$out1" == "$out2" ]] && printf '%s' "$out1" | grep -q "대상 2개 중 1개 부재"; then
    pass "cwd 독립성(--root 생략): 두 cwd에서 동일 결과"
  else
    fail "cwd 독립성: rc1=$rc1 rc2=$rc2 out1=$out1 out2=$out2"
  fi
  rm -rf "$fx"
}

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

test_exec_error_missing_root_tree() {
  local fx rc
  fx="$(mktemp -d)" || { fail "입력 오류(루트 트리 부재): mktemp 실패"; return; }
  echo "- related files: x" > "${fx}/item.md"
  bash "$TARGET" "${fx}/item.md" --root "$fx" >/dev/null 2>&1
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
  echo "- related files: x" > "${fx}/item.md"
  bash "$TARGET" "${fx}/item.md" --root >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "실행 오류: --root 값 누락 → 유한 시간 내 exit 2"
  else
    fail "실행 오류: --root 값 누락인데 rc=$rc (기대: 2)"
  fi
  rm -rf "$fx"
}

test_exec_error_parser_source_failure() {
  local fx rc consumer_copy
  fx="$(_mk_fixture_root)"
  mkdir -p "${fx}/scripts_copy"
  cp "$TARGET" "${fx}/scripts_copy/check_fr_related_files_existence.sh"
  # 파서(check_skill_reference_existence.sh)를 일부러 두지 않는다 — 배포 누락 재현.
  echo "- related files: \`rd-workflow/scripts/real.sh\`" > "${fx}/item.md"
  consumer_copy="${fx}/scripts_copy/check_fr_related_files_existence.sh"
  bash "$consumer_copy" "${fx}/item.md" --root "$fx" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "파서 source 실패(배포 누락 재현): exit 2"
  else
    fail "파서 source 실패인데 rc=$rc (기대: 2, F2 회귀)"
  fi
  rm -rf "$fx"
}

test_exec_error_parser_missing_functions() {
  local fx rc consumer_copy
  fx="$(_mk_fixture_root)"
  mkdir -p "${fx}/scripts_copy"
  cp "$TARGET" "${fx}/scripts_copy/check_fr_related_files_existence.sh"
  # 공개 함수가 없는 구버전 파서를 시뮬레이션 — source는 성공하지만 함수가 비어 있다.
  cat > "${fx}/scripts_copy/check_skill_reference_existence.sh" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
STUBEOF
  echo "- related files: \`rd-workflow/scripts/real.sh\`" > "${fx}/item.md"
  consumer_copy="${fx}/scripts_copy/check_fr_related_files_existence.sh"
  bash "$consumer_copy" "${fx}/item.md" --root "$fx" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "파서 함수 부재(구버전 재현): exit 2"
  else
    fail "파서 함수 부재인데 rc=$rc (기대: 2, F2 회귀 — 정상 신호로 위장되면 안 된다)"
  fi
  rm -rf "$fx"
}

test_exec_error_parser_premature_exit0() {
  local fx rc consumer_copy
  fx="$(_mk_fixture_root)"
  mkdir -p "${fx}/scripts_copy"
  cp "$TARGET" "${fx}/scripts_copy/check_fr_related_files_existence.sh"
  # 파서가 함수 정의 전에 top-level에서 exit 0으로 조기 종료하는 손상 상태를
  # 시뮬레이션한다 — 단순 `if ! source ...; then exit 2; fi` 방식이라면 이 exit이
  # 호출자 프로세스까지 즉시 끝내버려 무출력 exit 0(정상 신호)으로 위장된다
  # (spec/plan review Turn 004 F2 재개, 실측 재현). probe 방식(성공 마커 확인)이
  # 이 케이스를 구조적으로 잡아내는지 확인하는 것이 이 테스트의 핵심이다.
  cat > "${fx}/scripts_copy/check_skill_reference_existence.sh" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
exit 0
STUBEOF
  echo "- related files: \`rd-workflow/scripts/real.sh\`" > "${fx}/item.md"
  consumer_copy="${fx}/scripts_copy/check_fr_related_files_existence.sh"
  bash "$consumer_copy" "${fx}/item.md" --root "$fx" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "파서 조기 종료(exit 0 손상 재현): exit 2 (probe가 조기 종료를 잡음)"
  else
    fail "파서 조기 종료인데 rc=$rc (기대: 2, F2 재개 회귀 — 무출력 exit 0으로 위장되면 안 된다)"
  fi
  rm -rf "$fx"
}

test_probe_handles_special_char_install_path() {
  local fx_base fx out rc
  fx_base="$(mktemp -d)" || { fail "특수문자 경로 fixture mktemp 실패"; return; }
  # 설치 경로에 $ ·따옴표·공백이 섞여도 probe가 정상 로딩해야 한다. 이전 방식
  # (SCRIPT_DIR을 bash -c 코드 문자열에 이어붙임)은 이런 문자를 셸 코드로
  # 재해석해 정상 파서도 로딩 실패로 오판했다(Turn 006 F5, 실측 재현).
  fx="${fx_base}/proj\$x \"q\""
  mkdir -p "${fx}/rd-workflow/scripts"
  cp "$TARGET" "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh"
  cp "$PARSER" "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/real.sh"
  cat > "${fx}/item.md" <<'EOF'
- related files: `rd-workflow/scripts/real.sh`
EOF
  out="$(bash "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh" "${fx}/item.md" --root "${fx}" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "대상 1개 중 0개 부재"; then
    pass "특수문자 설치 경로(\$·따옴표·공백): probe 정상 로딩, exit 0"
  else
    fail "특수문자 설치 경로: rc=$rc out=$out (F5 회귀 — 위치 인자 대신 문자열 이어붙이기로 되돌아갔을 가능성)"
  fi
  rm -rf "$fx_base"
}

test_selftest_empty_backlog_succeeds_and_propagates_error() {
  local fx code out
  fx="$(mktemp -d)" || { fail "self_test mutation fixture mktemp 실패"; return; }
  mkdir -p "${fx}/rd-workflow/scripts" "${fx}/rd-workflow-workspace/backlog/items"
  cp "${SCRIPT_DIR}/self_test.sh" "${fx}/rd-workflow/scripts/self_test.sh"
  cp "$TARGET" "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh"
  cp "$PARSER" "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh"
  cp "${SCRIPT_DIR}/_fr_status.sh" "${fx}/rd-workflow/scripts/_fr_status.sh"

  # 대조군 1 — 빈 백로그는 성공해야 한다(D4 핵심 판정).
  RD_SELFTEST_CHECKER_ONLY=fr_related_files_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" >/dev/null 2>&1
  code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "self_test 빈 백로그: 성공해야 하는데 rc=$code"
    rm -rf "$fx"
    return
  fi

  # 대조군 2 — FR 1개를 두고 정상 스크립트로 실행하면 여전히 성공해야 한다(fixture 유효성 증명).
  echo "- related files: \`rd-workflow/scripts/real.sh\`" > "${fx}/rd-workflow-workspace/backlog/items/sample.md"
  RD_SELFTEST_CHECKER_ONLY=fr_related_files_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" >/dev/null 2>&1
  code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "self_test 대조군(정상 fixture): 성공해야 하는데 rc=$code"
    rm -rf "$fx"
    return
  fi

  # 실험군 — 검사 스크립트를 "항상 exit 2" 스텁으로 치환하면 self_test가 실패로 잡아야 한다.
  cat > "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh" <<'STUBEOF'
#!/usr/bin/env bash
exit 2
STUBEOF
  chmod +x "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh"
  out="$(RD_SELFTEST_CHECKER_ONLY=fr_related_files_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if [[ "$code" -ne 0 ]] && printf '%s' "$out" | grep -q "검사 실행 오류"; then
    pass "self_test 오류 전파: 빈 백로그 성공(대조군 2건) + 하위 스크립트 exit 2를 실패로 잡음"
  else
    fail "self_test 오류 전파: rc=$code out=$out"
  fi
  rm -rf "$fx"
}

# 회귀 단언 — 다중 파일 호출에서 가운데 파일의 실행 오류가 뒤 파일 성공에 덮이지 않아야 한다.
test_multi_file_middle_error() {
  local fx out rc
  fx="$(_mk_fixture_root)"
  printf -- '- related files: `rd-workflow/scripts/missA.sh`\n' > "${fx}/a.md"
  printf -- '- related files: `rd-workflow/scripts/missC.sh`\n' > "${fx}/c.md"
  out="$(bash "$TARGET" "${fx}/a.md" "${fx}/absent.md" "${fx}/c.md" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 2 ]] \
     && printf '%s' "$out" | grep -q "a.md:1: 참조 경로 없음 — rd-workflow/scripts/missA.sh" \
     && printf '%s' "$out" | grep -q "입력 FR 파일이 없습니다" \
     && printf '%s' "$out" | grep -q "c.md:1: 참조 경로 없음 — rd-workflow/scripts/missC.sh" \
     && printf '%s' "$out" | grep -q "c.md: 대상 1개 중 1개 부재"; then
    pass "multi_file_middle_error: 가운데 파일 부재 → rc 2, 앞뒤 파일 결과 모두 출력"
  else
    fail "multi_file_middle_error: rc=$rc out=$out"
  fi
  rm -rf "$fx"
}

# 회귀 단언 — self_test 래퍼가 done 항목은 검사하지 않고 status 줄 없는 항목은 검사한다.
# 래퍼가 활성 항목만 걸러 검사기에 넘기도록 바뀌기 전에는 FAIL 한다(done 항목 경고도 나옴).
test_wrapper_active_filter() {
  local fx out
  fx="$(mktemp -d)" || { fail "wrapper_active_filter fixture mktemp 실패"; return; }
  mkdir -p "${fx}/rd-workflow/scripts" "${fx}/rd-workflow-workspace/backlog/items"
  cp "${SCRIPT_DIR}/self_test.sh" "${fx}/rd-workflow/scripts/self_test.sh"
  cp "$TARGET" "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh"
  cp "$PARSER" "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh"
  cp "${SCRIPT_DIR}/_fr_status.sh" "${fx}/rd-workflow/scripts/_fr_status.sh"
  printf -- '# done item\n- status: done\n- related files: `rd-workflow/scripts/gone_done.sh`\n' \
    > "${fx}/rd-workflow-workspace/backlog/items/done-item.md"
  printf -- '# no status item\n- related files: `rd-workflow/scripts/gone_nostatus.sh`\n' \
    > "${fx}/rd-workflow-workspace/backlog/items/nostatus-item.md"
  # status 가 개행 없는 마지막 줄인 done 항목도 비활성으로 판정해야 한다 (final diff review F2)
  printf -- '# eof done item\n- related files: `rd-workflow/scripts/gone_eofdone.sh`\n- status: done' \
    > "${fx}/rd-workflow-workspace/backlog/items/eofdone-item.md"
  out="$(RD_SELFTEST_CHECKER_ONLY=fr_related_files_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  if printf '%s' "$out" | grep -q "gone_nostatus.sh" \
     && ! printf '%s' "$out" | grep -q "gone_done.sh" \
     && ! printf '%s' "$out" | grep -q "gone_eofdone.sh"; then
    pass "wrapper_active_filter: status 없는 항목만 경고, done 항목(개행 없는 마지막 줄 포함)은 검사하지 않음"
  else
    fail "wrapper_active_filter: out=$out"
  fi
  rm -rf "$fx"
}

# 활성 판정은 _fr_status.sh 공용 판정을 따른다: 한글 키·주석 붙은 값은 비활성, obsolete·비표준은 검사 대상.
# 출력: "rc=<self_test 검사 종료 코드> warn=<0|1>". 경로 부재는 경고일 뿐 rc 0 이다. 실행 오류(rc≠0)를 비활성 제외로 오인하지 않도록 rc 를 함께 낸다.
_wrapper_single_item_result() {
  local content="$1" fx out rc
  fx="$(mktemp -d)" || { echo "mktemp 실패" >&2; return 2; }
  mkdir -p "${fx}/rd-workflow/scripts" "${fx}/rd-workflow-workspace/backlog/items"
  cp "${SCRIPT_DIR}/self_test.sh" "${fx}/rd-workflow/scripts/self_test.sh"
  cp "$TARGET" "${fx}/rd-workflow/scripts/check_fr_related_files_existence.sh"
  cp "$PARSER" "${fx}/rd-workflow/scripts/check_skill_reference_existence.sh"
  cp "${SCRIPT_DIR}/_fr_status.sh" "${fx}/rd-workflow/scripts/_fr_status.sh"
  printf -- "$content" > "${fx}/rd-workflow-workspace/backlog/items/one.md"
  out="$(RD_SELFTEST_CHECKER_ONLY=fr_related_files_existence_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"; rc=$?
  rm -rf "$fx"
  if printf '%s' "$out" | grep -q "gone_x.sh"; then echo "rc=${rc} warn=1"; else echo "rc=${rc} warn=0"; fi
}

test_wrapper_shared_status_judgement() {
  local r
  r="$(_wrapper_single_item_result '# t\n- 상태: done\n- related files: `rd-workflow/scripts/gone_x.sh`\n')"
  if [ "$r" = "rc=0 warn=0" ]; then
    pass "wrapper_shared(a): '- 상태: done' 은 검사 대상 아님 (rc=0)"
  else fail "wrapper_shared(a): '- 상태: done' 기대 rc=0 warn=0, 실제 $r"; fi
  r="$(_wrapper_single_item_result '# t\n- status: done (→ 설명)\n- related files: `rd-workflow/scripts/gone_x.sh`\n')"
  if [ "$r" = "rc=0 warn=0" ]; then
    pass "wrapper_shared(b): 'done (→ 설명)' 은 검사 대상 아님 (rc=0)"
  else fail "wrapper_shared(b): 'done (→ 설명)' 기대 rc=0 warn=0, 실제 $r"; fi
  r="$(_wrapper_single_item_result '# t\n- status: obsolete\n- related files: `rd-workflow/scripts/gone_x.sh`\n')"
  if [ "$r" = "rc=0 warn=1" ]; then
    pass "wrapper_shared(c): 'obsolete' 은 검사 대상 (rc=0, 부재 경고)"
  else fail "wrapper_shared(c): 'obsolete' 기대 rc=0 warn=1, 실제 $r"; fi
}

test_all_present
test_partial_missing_channel_separated
test_all_missing
test_no_related_files_line
test_related_files_line_only_excluded_tokens
test_cwd_independent_default_root
test_exec_error_missing_input_file
test_exec_error_missing_root_tree
test_exec_error_root_flag_missing_value
test_exec_error_parser_source_failure
test_exec_error_parser_missing_functions
test_exec_error_parser_premature_exit0
test_probe_handles_special_char_install_path
test_selftest_empty_backlog_succeeds_and_propagates_error
test_multi_file_middle_error
test_wrapper_active_filter
test_wrapper_shared_status_judgement
exit $FAIL
