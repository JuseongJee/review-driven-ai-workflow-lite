#!/usr/bin/env bash
# check_root_settings_hook_registration.sh 단위 테스트 — 전부 임시 fixture, 순수 스크립트 호출.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/check_root_settings_hook_registration.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=1; }

# 공통 fixture 루트 — trap을 파일 하나에만 건다(기존 test_task_cli.sh의 trap 덮어쓰기 결함 회피).
_FX_ROOTS=()
_cleanup_all() {
  local d
  for d in "${_FX_ROOTS[@]+"${_FX_ROOTS[@]}"}"; do
    chmod -R u+rwX "$d" 2>/dev/null
    rm -rf "$d"
  done
}
trap _cleanup_all EXIT

# 명령 치환으로 호출되므로 서브셸에서 실행된다 — 호출부에서 fx 값을 받은 뒤 정리 등록한다.
_mk_fixture_root() {
  local fx
  fx="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
  mkdir -p "${fx}/rd-workflow/scripts/hooks" "${fx}/.claude"
  printf '%s' "$fx"
}
_track_fx() { _FX_ROOTS+=("$1"); }

_write_hook() {
  local fx="$1" name="$2"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/hooks/${name}"
}

_write_settings() {
  local fx="$1"; shift
  printf '%s\n' "$@" > "${fx}/.claude/settings.json"
}

# 1. 정상(미등록 0건)
test_normal_registered() {
  local fx out rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" \
    '{' \
    '  "hooks": {' \
    '    "SessionStart": [' \
    '      { "hooks": [ { "type": "command", "command": "bash rd-workflow/scripts/hooks/foo.sh" } ] }' \
    '    ]' \
    '  }' \
    '}'
  out="$(bash "$TARGET" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "실 hook 1건, 미등록 0건(예외 0건 제외)"; then
    pass "정상: 실 hook 1건 등록됨, exit 0"
  else
    fail "정상: rc=$rc out=$out"
  fi
}

# 2. 미등록 발견
test_unregistered_found() {
  local fx out rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  out="$(bash "$TARGET" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "rd-workflow/scripts/hooks/foo.sh: 루트 .claude/settings.json 에 미등록" \
     && printf '%s' "$out" | grep -q "미등록 1건"; then
    pass "미등록 발견: 메시지 + 요약, exit 0"
  else
    fail "미등록 발견: rc=$rc out=$out"
  fi
}

# 3. command 키 스코프 회귀anchor — permissions.allow 안의 동일 경로 문자열은 등록으로 오인하지 않는다
test_command_key_scope() {
  local fx out rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" \
    '{' \
    '  "hooks": {},' \
    '  "permissions": {' \
    '    "allow": [ "Bash(bash rd-workflow/scripts/hooks/foo.sh:*)" ]' \
    '  }' \
    '}'
  out="$(bash "$TARGET" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "미등록 1건"; then
    pass "command 키 스코프: permissions.allow 의 유사 경로를 등록으로 오인하지 않음"
  else
    fail "command 키 스코프: rc=$rc out=$out"
  fi
}

# 4a. settings.json 구조 손상 오탐 방지 — 문자열 값 안의 [/] 를 손상으로 오인하지 않는다
test_structure_check_no_false_positive() {
  local fx out rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" \
    '{' \
    '  "hooks": {' \
    '    "SessionStart": [' \
    '      {' \
    '        "hooks": [' \
    '          {' \
    '            "type": "command",' \
    '            "command": "bash rd-workflow/scripts/hooks/foo.sh"' \
    '          }' \
    '        ]' \
    '      }' \
    '    ]' \
    '  },' \
    '  "permissions": {' \
    '    "allow": [' \
    '      "Bash(grep -F [:*)"' \
    '    ]' \
    '  }' \
    '}'
  out="$(bash "$TARGET" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "미등록 0건"; then
    pass "구조 손상 검사 오탐 방지: 문자열 값 안의 대괄호를 손상으로 오인하지 않음(여러 줄 + 순수 구조 줄 포함)"
  else
    fail "구조 손상 검사 오탐 방지: rc=$rc out=$out"
  fi
}

# 4b. settings.json 실제 구조 손상 탐지
test_structure_check_true_positive() {
  local fx out rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {'
  out="$(bash "$TARGET" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 2 ]] && printf '%s' "$out" | grep -q "구조 손상 의심"; then
    pass "구조 손상 검사: 실제 손상(중괄호 누락) 탐지, exit 2"
  else
    fail "구조 손상 검사(실제 손상): rc=$rc out=$out"
  fi
}

# 5. 예외 목록 동작
test_exception_applied() {
  local fx out rc excf
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  excf="${fx}/exceptions.txt"
  printf 'foo.sh|의도적 미등록\n' > "$excf"
  out="$(bash "$TARGET" --root "$fx" --exceptions-file "$excf" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] \
     && ! printf '%s' "$out" | grep -q "미등록 1건"'$' \
     && printf '%s' "$out" | grep -q "미등록 0건(예외 1건 제외)"; then
    pass "예외 목록 동작: 미등록 메시지 없음, 요약에 예외 1건 반영"
  else
    fail "예외 목록 동작: rc=$rc out=$out"
  fi
}

# 6. 예외 목록 형식 오류
test_exception_format_no_separator() {
  local fx out rc excf
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  excf="${fx}/exceptions.txt"
  printf 'foo.sh\n' > "$excf"
  out="$(bash "$TARGET" --root "$fx" --exceptions-file "$excf" 2>&1)"; rc=$?
  if [[ "$rc" -eq 2 ]] && printf '%s' "$out" | grep -q "형식 오류"; then
    pass "예외 형식 오류(구분자 없음): exit 2"
  else
    fail "예외 형식 오류(구분자 없음): rc=$rc out=$out"
  fi
}

test_exception_format_empty_reason() {
  local fx out rc excf
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  excf="${fx}/exceptions.txt"
  printf 'foo.sh|\n' > "$excf"
  out="$(bash "$TARGET" --root "$fx" --exceptions-file "$excf" 2>&1)"; rc=$?
  if [[ "$rc" -eq 2 ]] && printf '%s' "$out" | grep -q "형식 오류"; then
    pass "예외 형식 오류(빈 사유): exit 2 — 사유 없는 예외가 미등록 경고를 숨기지 않음"
  else
    fail "예외 형식 오류(빈 사유): rc=$rc out=$out"
  fi
}

# 7. 예외 목록 읽기 실패
test_exception_read_failure() {
  local fx out rc excf
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  excf="${fx}/exceptions.txt"
  printf 'foo.sh|사유\n' > "$excf"
  chmod 000 "$excf"
  out="$(bash "$TARGET" --root "$fx" --exceptions-file "$excf" 2>&1)"; rc=$?
  chmod 644 "$excf"
  if [[ "$rc" -eq 2 ]]; then
    pass "예외 목록 읽기 실패: exit 2"
  else
    fail "예외 목록 읽기 실패: rc=$rc out=$out"
  fi
}

# 8. 명시적 --exceptions-file 경로 부재
test_exception_explicit_missing() {
  local fx out rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  out="$(bash "$TARGET" --root "$fx" --exceptions-file "${fx}/nonexistent.txt" 2>&1)"; rc=$?
  if [[ "$rc" -eq 2 ]]; then
    pass "명시적 --exceptions-file 경로 부재: exit 2"
  else
    fail "명시적 --exceptions-file 경로 부재: rc=$rc out=$out"
  fi
}

# 9. 예외 건수 표시 정확성 (C1) — 대상이 사라진 오래된 예외 항목은 제외 건수에 포함하지 않는다
test_excepted_count_accuracy() {
  local fx out rc excf
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  excf="${fx}/exceptions.txt"
  printf 'foo.sh|사유1\nbar.sh|사유2\n' > "$excf"
  out="$(bash "$TARGET" --root "$fx" --exceptions-file "$excf" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "예외 1건 제외"; then
    pass "예외 건수 표시 정확성: 목록 2건 중 실제 제외 1건만 집계"
  else
    fail "예외 건수 표시 정확성: rc=$rc out=$out"
  fi
}

# 10. `_`/`test_` 접두 제외
test_prefix_exclusion() {
  local fx out rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "_lib.sh"
  _write_hook "$fx" "test_foo.sh"
  _write_settings "$fx" '{ "hooks": {} }'
  out="$(bash "$TARGET" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "실 hook 0건, 미등록 0건"; then
    pass "\`_\`/\`test_\` 접두 제외: 실 hook 집계에 나타나지 않음"
  else
    fail "접두 제외: rc=$rc out=$out"
  fi
}

# 10b. pipefail SIGPIPE 회귀anchor (final diff review Turn 002/004 실측 — printf | grep -q 파이프는
# grep 조기 종료 시 printf 가 SIGPIPE(rc=141)로 죽고 pipefail 아래 그 141이 파이프라인 종료
# 코드가 되어 정상 등록을 미등록으로 오판했다. Turn 004 지적: permissions.allow 는 command
# 값 추출 대상이 아니므로 $commands 를 실제로 키우려면 "command" 키 항목 자체를 대량으로
# 늘려야 한다 — 등록 hook 을 목록 맨 앞에 두고 뒤에 5000개 더미 command 를 붙여, grep 이
# 첫 줄에서 즉시 매치·종료하는 동안 printf 가 남은 대량 데이터를 쓰다 SIGPIPE 를 맞는
# 조건을 구조적으로 재현한다(수정 전 구현으로 실측 재현 확인 — 미등록 1건 오판, 수정 후
# 미등록 0건 정상 판정)
test_pipefail_sigpipe_large_commands() {
  local fx out rc i
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  {
    echo '{'
    echo '  "hooks_debug_wrapper": ['
    echo '    { "type": "command", "command": "bash rd-workflow/scripts/hooks/foo.sh" },'
    for i in $(seq 1 5000); do
      if [[ "$i" -eq 5000 ]]; then
        echo "    { \"type\": \"command\", \"command\": \"bash some/other/dummy_${i}.sh\" }"
      else
        echo "    { \"type\": \"command\", \"command\": \"bash some/other/dummy_${i}.sh\" },"
      fi
    done
    echo '  ]'
    echo '}'
  } > "${fx}/.claude/settings.json"
  out="$(bash "$TARGET" --root "$fx" 2>&1)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "미등록 0건"; then
    pass "pipefail SIGPIPE 회귀anchor: 대형 command 목록(5000건)에서도 정상 등록을 미등록으로 오판하지 않음"
  else
    fail "pipefail SIGPIPE 회귀anchor: rc=$rc out=$out"
  fi
}

# 11. 입력 오류
test_input_error_no_hooks_dir() {
  local fx rc
  fx="$(mktemp -d)" || { fail "입력 오류(hooks 디렉터리 부재): mktemp 실패"; return; }
  _track_fx "$fx"
  mkdir -p "${fx}/.claude"
  printf '{}' > "${fx}/.claude/settings.json"
  bash "$TARGET" --root "$fx" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 2 ]] && pass "입력 오류(hooks 디렉터리 없음): exit 2" || fail "입력 오류(hooks 디렉터리 없음): rc=$rc"
}

test_input_error_no_settings_file() {
  local fx rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  rm -f "${fx}/.claude/settings.json"
  bash "$TARGET" --root "$fx" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 2 ]] && pass "입력 오류(settings.json 없음): exit 2" || fail "입력 오류(settings.json 없음): rc=$rc"
}

# 12. Bash 3.2 호환성 회귀anchor
test_bash32_compat() {
  local fx out1 rc1 out2 rc2
  if [[ ! -x /bin/bash ]] || ! /bin/bash --version 2>/dev/null | head -1 | grep -q "version 3\.2"; then
    echo "  SKIP: /bin/bash 가 3.2 계열이 아니라 이 시나리오를 건너뜁니다"
    return
  fi
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_hook "$fx" "foo.sh"
  _write_settings "$fx" \
    '{' \
    '  "hooks": {' \
    '    "SessionStart": [' \
    '      { "hooks": [ { "type": "command", "command": "bash rd-workflow/scripts/hooks/foo.sh" } ] }' \
    '    ]' \
    '  }' \
    '}'
  out1="$(/bin/bash "$TARGET" --root "$fx" 2>&1)"; rc1=$?

  local fx2
  fx2="$(_mk_fixture_root)"; _track_fx "$fx2"
  _write_hook "$fx2" "foo.sh"
  _write_settings "$fx2" '{ "hooks": {} }'
  out2="$(/bin/bash "$TARGET" --root "$fx2" 2>&1)"; rc2=$?

  if [[ "$rc1" -eq 0 ]] && printf '%s' "$out1" | grep -q "미등록 0건" \
     && [[ "$rc2" -eq 0 ]] && printf '%s' "$out2" | grep -q "미등록 1건"; then
    pass "Bash 3.2 호환성: 정상/미등록 경로 둘 다 unbound-variable 오류 없이 exit 0"
  else
    fail "Bash 3.2 호환성: rc1=$rc1 out1=$out1 / rc2=$rc2 out2=$out2"
  fi
}

# 13. self_test 통합(mutation-fixture, whitelist 포함)
test_selftest_mutation_and_whitelist() {
  local fx code out
  fx="$(mktemp -d)" || { fail "self_test mutation fixture mktemp 실패"; return; }
  _track_fx "$fx"
  mkdir -p "${fx}/rd-workflow/scripts/hooks" "${fx}/.claude"
  cp "${SCRIPT_DIR}/self_test.sh" "${fx}/rd-workflow/scripts/self_test.sh"
  cp "$TARGET" "${fx}/rd-workflow/scripts/check_root_settings_hook_registration.sh"
  printf '#!/usr/bin/env bash\n' > "${fx}/rd-workflow/scripts/hooks/foo.sh"
  _write_settings "$fx" \
    '{' \
    '  "hooks": {' \
    '    "SessionStart": [' \
    '      { "hooks": [ { "type": "command", "command": "bash rd-workflow/scripts/hooks/foo.sh" } ] }' \
    '    ]' \
    '  }' \
    '}'

  # whitelist 등록 확인 — 등록 안 됐으면 "허용값이 아닙니다"로 거절되어 대조군이 성립하지 않는다.
  out="$(RD_SELFTEST_CHECKER_ONLY=root_settings_hook_registration_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if printf '%s' "$out" | grep -q "허용값이 아닙니다"; then
    fail "self_test whitelist: RD_SELFTEST_CHECKER_ONLY 가 거절됨(등록 누락) out=$out"
    return
  fi
  if [[ "$code" -ne 0 ]]; then
    fail "self_test 대조군1(정상 등록): 성공해야 하는데 rc=$code out=$out"
    return
  fi

  # 대조군 2 — 미등록 신호(U>0)가 있어도 성공해야 한다(신호 전용 계약).
  _write_settings "$fx" '{ "hooks": {} }'
  out="$(RD_SELFTEST_CHECKER_ONLY=root_settings_hook_registration_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "self_test 대조군2(미등록 신호 있음): 성공해야 하는데 rc=$code out=$out"
    return
  fi

  # 실험군 — 검사 스크립트를 "항상 exit 2" 스텁으로 치환하면 self_test가 실패로 잡아야 한다.
  cat > "${fx}/rd-workflow/scripts/check_root_settings_hook_registration.sh" <<'STUBEOF'
#!/usr/bin/env bash
exit 2
STUBEOF
  chmod +x "${fx}/rd-workflow/scripts/check_root_settings_hook_registration.sh"
  out="$(RD_SELFTEST_CHECKER_ONLY=root_settings_hook_registration_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if [[ "$code" -ne 0 ]] && printf '%s' "$out" | grep -q "검사 실행 오류"; then
    pass "self_test 통합: whitelist 등록됨 + 대조군 2건 성공 + 스텁 exit 2 실패로 잡음"
  else
    fail "self_test 통합: rc=$code out=$out"
  fi
}

test_normal_registered
test_unregistered_found
test_command_key_scope
test_structure_check_no_false_positive
test_structure_check_true_positive
test_exception_applied
test_exception_format_no_separator
test_exception_format_empty_reason
test_exception_read_failure
test_exception_explicit_missing
test_excepted_count_accuracy
test_prefix_exclusion
test_pipefail_sigpipe_large_commands
test_input_error_no_hooks_dir
test_input_error_no_settings_file
test_bash32_compat
test_selftest_mutation_and_whitelist
exit $FAIL
