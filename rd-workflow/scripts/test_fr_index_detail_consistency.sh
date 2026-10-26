#!/usr/bin/env bash
# check_fr_index_detail_consistency.sh 단위 테스트 — 전부 임시 fixture, 순수 스크립트 호출.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/check_fr_index_detail_consistency.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; FAIL=1; }

# 공통 fixture 루트 — 여러 테스트가 각자 mktemp -d를 쓰지만, 프로세스 종료 시 한 번에
# 정리되도록 trap을 파일 하나에만 건다(기존 test_task_cli.sh의 trap 덮어쓰기 결함 회피).
_FX_ROOTS=()
_cleanup_all() {
  local d
  for d in "${_FX_ROOTS[@]+"${_FX_ROOTS[@]}"}"; do
    chmod -R u+rwX "$d" 2>/dev/null
    rm -rf "$d"
  done
}
trap _cleanup_all EXIT

# 명령 치환(command substitution)으로 호출되므로 서브셸에서 실행된다 — 이 함수 안에서
# _FX_ROOTS 에 push해도 부모 셸에는 반영되지 않는다(final diff review Turn 002 R1 지적,
# fixture 잔존 10건 실측 재현). 정리 등록은 반드시 호출부에서 fx 값을 받은 뒤 수행한다.
_mk_fixture_root() {
  local fx
  fx="$(mktemp -d)" || { echo "mktemp 실패" >&2; exit 1; }
  mkdir -p "${fx}/rd-workflow-workspace/backlog/items"
  : > "${fx}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
  printf '%s' "$fx"
}
_track_fx() { _FX_ROOTS+=("$1"); }

# 인덱스 fixture 는 실제 FUTURE_REQUESTS.md 와 같은 모양으로 쓴다 — `## 인덱스` 절 아래에
# 헤더 행과 구분 행이 있고 그 다음부터 데이터 행이다. 검사기는 헤더에서 컬럼 이름과 개수를
# 읽으므로, 헤더 없는 fixture 는 현실에 없는 입력이면서 모든 행을 PARSEFAIL 로 떨어뜨려
# 각 검사 분기에 도달하지 못하게 한다. preamble 이 6줄이므로 첫 데이터 행은 항상 7행이다.
_IDX_ROW1=7
_HDR_LEGACY='| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 상세 |'
_SEP_LEGACY='|---|---|---|---|---|---|---|'
_HDR_RELATION='| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 관계 | 상세 |'
_SEP_RELATION='|---|---|---|---|---|---|---|---|'
_HDR_GITHUB='| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 관계 | 상세 | GitHub |'
_SEP_GITHUB='|---|---|---|---|---|---|---|---|---|'

_write_index_fmt() {
  local fx="$1" header="$2" sep="$3"; shift 3
  printf '%s\n' '# FUTURE_REQUESTS' '' '## 인덱스' '' "$header" "$sep" "$@" \
    > "${fx}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
}

_write_index() {
  local fx="$1"; shift
  _write_index_fmt "$fx" "$_HDR_LEGACY" "$_SEP_LEGACY" "$@"
}

_write_item() {
  local fx="$1" name="$2"; shift 2
  printf '%s\n' "$@" > "${fx}/rd-workflow-workspace/backlog/items/${name}"
}

# 1. 정상(정밀 검증) — N=1/M=1/P=0/K=0, stderr 완전히 비어 있음, 요약 리터럴 파이프 포함
test_normal_precise() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-01-t.md" "# 2026-01-01 t" "- status: idea" "- kind: tooling"
  _write_index "$fx" '| 2026-01-01 | t | run \|\| true 처럼 이스케이프된 파이프 포함 | tooling | idea | - | [상세](items/2026-01-01-t.md) |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err.$$)"; rc=$?
  err="$(cat /tmp/fridc_err.$$)"; rm -f /tmp/fridc_err.$$
  if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q "활성 상세 1건, 인덱스 행 1건(파싱 실패 0건 제외), 불일치 0건" \
     && [[ -z "$err" ]]; then
    pass "정상(리터럴 파이프 포함): N=1/M=1/P=0/K=0, stderr 비어 있음"
  else
    fail "정상: rc=$rc out=$out err=$err"
  fi
}

# 2. ①(인덱스 누락)
test_index_missing() {
  local fx err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-02-t.md" "# 2026-01-02 t" "- status: idea" "- kind: bug"
  err="$(bash "$TARGET" --root "$fx" 2>&1 >/dev/null)"; rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$err" | grep -q "2026-01-02-t.md: 활성인데 인덱스에 행 없음"; then
    pass "①: 활성인데 인덱스에 행 없음"
  else
    fail "①: rc=$rc err=$err"
  fi
}

# 3. ②(인덱스만 존재, 상세 파일 부재)
test_index_orphan() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_index "$fx" '| 2026-01-03 | t | 요약 | bug | idea | - | [상세](items/2026-01-03-missing.md) |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err3.$$)"; rc=$?
  err="$(cat /tmp/fridc_err3.$$)"; rm -f /tmp/fridc_err3.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "인덱스 행 1건(파싱 실패 0건 제외)" \
     && printf '%s' "$err" | grep -q "인덱스에 있으나 상세 파일 부재 (items/2026-01-03-missing.md)"; then
    pass "②(고아): 인덱스에 있으나 상세 파일 부재"
  else
    fail "②(고아): rc=$rc err=$err"
  fi
}

# 4. ②(비활성인데 인덱스 잔존) — R1b 회귀 anchor: enum 필터 없이도 PARSEFAIL로 스킵되지 않아야 함
test_inactive_lingering() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-04-t.md" "# 2026-01-04 t" "- status: done" "- kind: bug"
  _write_index "$fx" '| 2026-01-04 | t | 요약 | bug | done | - | [상세](items/2026-01-04-t.md) |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err4.$$)"; rc=$?
  err="$(cat /tmp/fridc_err4.$$)"; rm -f /tmp/fridc_err4.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "인덱스 행 1건(파싱 실패 0건 제외)" \
     && printf '%s' "$err" | grep -q "인덱스(FUTURE_REQUESTS.md:${_IDX_ROW1})에 남아 있으나 상세 status=done"; then
    pass "②(비활성 잔존, R1b): status=done 행도 파싱돼 잡힘"
  else
    fail "②(비활성 잔존): rc=$rc err=$err"
  fi
}

# 5. ③(필드 부재) — status/kind 각각
test_missing_fields() {
  local fx err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-05-a.md" "# 2026-01-05 a" "- kind: bug"
  _write_item "$fx" "2026-01-05-b.md" "# 2026-01-05 b" "- status: idea"
  err="$(bash "$TARGET" --root "$fx" 2>&1 >/dev/null)"; rc=$?
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$err" | grep -q "2026-01-05-a.md: 활성인데 - status: 필드 없음" \
     && printf '%s' "$err" | grep -q "2026-01-05-b.md: 활성인데 - kind: 필드 없음"; then
    pass "③: status/kind 필드 부재 각각 검출(fail-safe 활성 판정 포함)"
  else
    fail "③: rc=$rc err=$err"
  fi
}

# 6. ④(종류 불일치, R1b 회귀 anchor 겸용) — 인덱스 종류가 enum 밖(오타)이어도 잡힘
test_kind_mismatch_enum_outside() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-06-t.md" "# 2026-01-06 t" "- status: idea" "- kind: tooling"
  _write_index "$fx" '| 2026-01-06 | t | 요약 | toolin | idea | - | [상세](items/2026-01-06-t.md) |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err6.$$)"; rc=$?
  err="$(cat /tmp/fridc_err6.$$)"; rm -f /tmp/fridc_err6.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "인덱스 행 1건(파싱 실패 0건 제외)" \
     && printf '%s' "$err" | grep -q "종류 불일치 (인덱스(FUTURE_REQUESTS.md:${_IDX_ROW1})=toolin, 상세=tooling)"; then
    pass "④(R1b): enum 밖 오타 값도 PARSEFAIL 없이 종류 불일치로 검출"
  else
    fail "④: rc=$rc err=$err"
  fi
}

# 9. 인덱스 행 파싱 실패(구조 자체가 깨짐) — 정상 행과 섞어 M/P 집계 확인
test_parsefail_structural() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-09-t.md" "# 2026-01-09 t" "- status: idea" "- kind: bug"
  _write_index "$fx" \
    '| 2026-01-09 | t | 요약 | bug | idea | - | [상세](items/2026-01-09-t.md) |' \
    '| 2026-01-09 | 짧음 |' \
    '| 2026-01-09 | t2 | 요약 | bug | idea | - | [상세](wrong/path.md) |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err9.$$)"; rc=$?
  err="$(cat /tmp/fridc_err9.$$)"; rm -f /tmp/fridc_err9.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -qE "인덱스 행 1건\(파싱 실패 2건 제외\)" \
     && printf '%s' "$err" | grep -c "인덱스 행 파싱 실패" | grep -qx 2; then
    pass "PARSEFAIL(구조 깨짐): M=1/P=2, 정상 행 처리에 영향 없음"
  else
    fail "PARSEFAIL: rc=$rc out=$out err=$err"
  fi
}

# 9b. 빈 종류 컬럼 — 구분자 함정 회귀 anchor
test_empty_kind_column() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-10-t.md" "# 2026-01-10 t" "- status: idea" "- kind: tooling"
  _write_index "$fx" '| 2026-01-10 | t | 요약 |  | idea | - | [상세](items/2026-01-10-t.md) |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err9b.$$)"; rc=$?
  err="$(cat /tmp/fridc_err9b.$$)"; rm -f /tmp/fridc_err9b.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "인덱스 행 1건(파싱 실패 0건 제외)" \
     && printf '%s' "$err" | grep -q "종류 불일치 (인덱스(FUTURE_REQUESTS.md:${_IDX_ROW1})=<비어있음>, 상세=tooling)"; then
    pass "9b: 빈 종류 컬럼도 뒤 컬럼(상세) 밀림 없이 정확히 추출"
  else
    fail "9b: rc=$rc err=$err"
  fi
}

# 9c. 빈 items + PARSEFAIL 1건
test_empty_items_with_parsefail() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_index "$fx" '| 2026-01-11 | 짧음 |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err9c.$$)"; rc=$?
  err="$(cat /tmp/fridc_err9c.$$)"; rm -f /tmp/fridc_err9c.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "활성 상세 0건, 인덱스 행 0건(파싱 실패 1건 제외), 불일치 0건" \
     && printf '%s' "$err" | grep -q "인덱스 행 파싱 실패"; then
    pass "9c: 빈 items + PARSEFAIL 1건 → N=0/M=0/P=1/K=0"
  else
    fail "9c: rc=$rc out=$out err=$err"
  fi
}

# 9d. 세 인덱스 형식 — 기존 7컬럼 / 관계 8컬럼 / 상세 뒤 GitHub 컬럼.
# 컬럼 수와 상세 컬럼의 위치가 형식마다 다르므로, 헤더 이름으로 위치를 찾지 못하면 종류·상세가
# 밀려 PARSEFAIL 이나 엉뚱한 종류 값이 된다. 형식별로 종류 불일치를 정확히 잡는지 확인한다.
_assert_format() {
  local label="$1" header="$2" sep="$3" row="$4"
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-13-t.md" "# 2026-01-13 t" "- status: idea" "- kind: tooling"
  _write_index_fmt "$fx" "$header" "$sep" "$row"
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_errfmt.$$)"; rc=$?
  err="$(cat /tmp/fridc_errfmt.$$)"; rm -f /tmp/fridc_errfmt.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "인덱스 행 1건(파싱 실패 0건 제외)" \
     && printf '%s' "$err" | grep -q "종류 불일치 (인덱스(FUTURE_REQUESTS.md:${_IDX_ROW1})=bug, 상세=tooling)"; then
    pass "형식(${label}): 종류·상세 컬럼을 헤더 이름으로 정확히 해석"
  else
    fail "형식(${label}): rc=$rc out=$out err=$err"
  fi
}

test_index_formats() {
  _assert_format "기존 7컬럼" "$_HDR_LEGACY" "$_SEP_LEGACY" \
    '| 2026-01-13 | t | 요약 | bug | idea | - | [상세](items/2026-01-13-t.md) |'
  _assert_format "관계 8컬럼" "$_HDR_RELATION" "$_SEP_RELATION" \
    '| 2026-01-13 | t | 요약 | bug | idea | P2 | blocks:2026-01-14-x | [상세](items/2026-01-13-t.md) |'
  _assert_format "GitHub 컬럼(상세 뒤)" "$_HDR_GITHUB" "$_SEP_GITHUB" \
    '| 2026-01-13 | t | 요약 | bug | idea | P2 | - | [상세](items/2026-01-13-t.md) | [#12](https://example.test/12) |'
}

# 9e. 셀 누락 + 이스케이프 파이프 — `\|` 를 셀로 세면 개수 검사를 통과해 컬럼이 통째로 밀리고,
# 검사기가 요약 조각을 종류 값으로 읽어 엉뚱한 불일치를 보고한다. PARSEFAIL 로 잡아야 한다.
test_escaped_pipe_masks_missing_cell() {
  local fx out err rc
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-14-t.md" "# 2026-01-14 t" "- status: idea" "- kind: bug"
  # 7컬럼 헤더인데 우선순위 셀이 빠졌고, 요약에 이스케이프 파이프가 하나 있다.
  _write_index "$fx" '| 2026-01-14 | t | 요약 `a \| b` | bug | idea | [상세](items/2026-01-14-t.md) |'
  out="$(bash "$TARGET" --root "$fx" 2>/tmp/fridc_err9e.$$)"; rc=$?
  err="$(cat /tmp/fridc_err9e.$$)"; rm -f /tmp/fridc_err9e.$$
  if [[ "$rc" -eq 0 ]] \
     && printf '%s' "$out" | grep -q "인덱스 행 0건(파싱 실패 1건 제외)" \
     && printf '%s' "$err" | grep -q "인덱스 행 파싱 실패" \
     && ! printf '%s' "$err" | grep -q "종류 불일치"; then
    pass "9e: 이스케이프 파이프가 누락 셀을 가리지 못함 → PARSEFAIL"
  else
    fail "9e: rc=$rc out=$out err=$err"
  fi
}

# 10. 입력 오류 3종
test_exec_error_missing_index() {
  local fx rc
  fx="$(mktemp -d)" || { fail "입력 오류(인덱스 부재): mktemp 실패"; return; }
  _FX_ROOTS+=("$fx")
  mkdir -p "${fx}/rd-workflow-workspace/backlog/items"
  bash "$TARGET" --root "$fx" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 2 ]] && pass "입력 오류: FUTURE_REQUESTS.md 부재 → exit 2" || fail "입력 오류(인덱스 부재): rc=$rc"
}

test_exec_error_missing_items_dir() {
  local fx rc
  fx="$(mktemp -d)" || { fail "입력 오류(items 부재): mktemp 실패"; return; }
  _FX_ROOTS+=("$fx")
  mkdir -p "${fx}/rd-workflow-workspace/backlog"
  : > "${fx}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
  bash "$TARGET" --root "$fx" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 2 ]] && pass "입력 오류: items/ 디렉터리 부재 → exit 2" || fail "입력 오류(items 부재): rc=$rc"
}

test_exec_error_root_flag_missing_value() {
  local rc
  bash "$TARGET" --root >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 2 ]] && pass "입력 오류: --root 값 누락 → exit 2" || fail "입력 오류(--root 누락): rc=$rc"
}

# 11. 읽기 실행 실패 — 상세 파일 읽기 권한 제거
test_exec_error_read_permission() {
  local fx rc f
  fx="$(_mk_fixture_root)"; _track_fx "$fx"
  _write_item "$fx" "2026-01-12-t.md" "# 2026-01-12 t" "- status: idea" "- kind: bug"
  f="${fx}/rd-workflow-workspace/backlog/items/2026-01-12-t.md"
  chmod 000 "$f"
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "  SKIP: 읽기 권한 테스트(root 실행 환경 — 권한 무시됨)"
    chmod 644 "$f"
    return
  fi
  bash "$TARGET" --root "$fx" >/dev/null 2>&1; rc=$?
  chmod 644 "$f"
  [[ "$rc" -eq 2 ]] && pass "읽기 실행 실패(R4): 권한 없음 파일 → exit 2" || fail "읽기 실행 실패: rc=$rc"
}

# 12. self_test 통합(mutation-fixture, R2 whitelist 포함)
test_selftest_mutation_and_whitelist() {
  local fx code out
  fx="$(mktemp -d)" || { fail "self_test mutation fixture mktemp 실패"; return; }
  _FX_ROOTS+=("$fx")
  mkdir -p "${fx}/rd-workflow/scripts" "${fx}/rd-workflow-workspace/backlog/items"
  cp "${SCRIPT_DIR}/self_test.sh" "${fx}/rd-workflow/scripts/self_test.sh"
  cp "$TARGET" "${fx}/rd-workflow/scripts/check_fr_index_detail_consistency.sh"
  : > "${fx}/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"

  # whitelist 등록 확인 — 등록 안 됐으면 "허용값이 아닙니다"로 거절되어 rc=2, 아래
  # 대조군이 성립하지 않는다. 거절 문구와 실제 checker 실패를 구분해 확인한다.
  out="$(RD_SELFTEST_CHECKER_ONLY=fr_index_detail_consistency_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if printf '%s' "$out" | grep -q "허용값이 아닙니다"; then
    fail "self_test whitelist: RD_SELFTEST_CHECKER_ONLY 가 거절됨(등록 누락) out=$out"
    return
  fi
  if [[ "$code" -ne 0 ]]; then
    fail "self_test 대조군1(빈 백로그): 성공해야 하는데 rc=$code out=$out"
    return
  fi

  # 대조군 2 — 불일치 신호(K>0)가 있어도 성공해야 한다(신호 전용 계약).
  echo "- status: idea" > "${fx}/rd-workflow-workspace/backlog/items/sample.md"
  echo "- kind: bug" >> "${fx}/rd-workflow-workspace/backlog/items/sample.md"
  out="$(RD_SELFTEST_CHECKER_ONLY=fr_index_detail_consistency_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if [[ "$code" -ne 0 ]]; then
    fail "self_test 대조군2(불일치 신호 있음): 성공해야 하는데 rc=$code out=$out"
    return
  fi

  # 실험군 — 검사 스크립트를 "항상 exit 2" 스텁으로 치환하면 self_test가 실패로 잡아야 한다.
  cat > "${fx}/rd-workflow/scripts/check_fr_index_detail_consistency.sh" <<'STUBEOF'
#!/usr/bin/env bash
exit 2
STUBEOF
  chmod +x "${fx}/rd-workflow/scripts/check_fr_index_detail_consistency.sh"
  out="$(RD_SELFTEST_CHECKER_ONLY=fr_index_detail_consistency_check \
    bash "${fx}/rd-workflow/scripts/self_test.sh" 2>&1)"
  code=$?
  if [[ "$code" -ne 0 ]] && printf '%s' "$out" | grep -q "검사 실행 오류"; then
    pass "self_test 통합(R2): whitelist 등록됨 + 대조군 2건 성공 + 스텁 exit 2 실패로 잡음"
  else
    fail "self_test 통합: rc=$code out=$out"
  fi
}

test_normal_precise
test_index_missing
test_index_orphan
test_inactive_lingering
test_missing_fields
test_kind_mismatch_enum_outside
test_parsefail_structural
test_empty_kind_column
test_empty_items_with_parsefail
test_index_formats
test_escaped_pipe_masks_missing_cell
test_exec_error_missing_index
test_exec_error_missing_items_dir
test_exec_error_root_flag_missing_value
test_exec_error_read_permission
test_selftest_mutation_and_whitelist
exit $FAIL
