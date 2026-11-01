#!/usr/bin/env bash
# test_autopilot_headless.sh — autopilot_headless.sh 의 outcome→exit-code 매핑 단위 테스트.
# 라이브 claude 불필요: RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 로 claude -p 호출을 생략하고
# outcome 파일을 심어 exit code 를 단언한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/autopilot_headless.sh"
TMP="$(mktemp -d)" || { echo "test_autopilot_headless.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_autopilot_headless.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

FAIL=0
assert_exit() {
  local desc="$1" outcome="$2" expected="$3"
  local of="${TMP}/outcome"
  printf '%s\n' "$outcome" > "$of"
  RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$of" \
    bash "$WRAPPER" >/dev/null 2>&1
  local code=$?
  if [[ "$code" == "$expected" ]]; then
    echo "  PASS: ${desc} (exit ${code})"
  else
    echo "  FAIL: ${desc} — expected ${expected}, got ${code}" >&2
    FAIL=1
  fi
}

assert_exit "completed → 0"       "completed"             0
assert_exit "resume → 10"         "resume"                10
assert_exit "blocked → 20"        "blocked:review-50turn" 20
assert_exit "blocked:time-cap → 20"          "blocked:time-cap"          20
assert_exit "blocked:time-cap-unreaped → 20" "blocked:time-cap-unreaped" 20
assert_exit "queue-empty → 30"    "queue-empty"           30
assert_exit "queue-blocked → 31"  "queue-blocked"         31
assert_exit "unknown → 40"        "garbage"               40

# outcome 둘째 줄 이후(대기 상세)가 사용자 출력까지 전달되는지 확인한다.
# queue-blocked(31) 와 blocked(20) 양쪽에서 확인한다 — 전역 실패도 상세가 필요하다.
# 상세를 2건 심어 둘 다 보이는지 본다. 1건만 검사하면 "둘째 줄만 읽는" 구현도 통과한다.
assert_detail_forwarded() {
  local desc="$1" token="$2"
  local of="${TMP}/detail-outcome"
  printf '%s\nalpha-task\t대기(선행: lead-task)\t선행 lead-task 완료 필요\nbeta-task\t오류(series)\tfr_relations.sh validate 로 관계 데이터 수정\n' \
    "$token" > "$of"
  local out
  out="$(RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$of" \
    bash "$WRAPPER" 2>&1)"
  local missing=""
  case "$out" in *"alpha-task	대기(선행: lead-task)	선행 lead-task 완료 필요"*) ;; *) missing="alpha-task 행" ;; esac
  case "$out" in *"beta-task	오류(series)	fr_relations.sh validate 로 관계 데이터 수정"*) ;; *) missing="${missing:+${missing}, }beta-task 행" ;; esac
  if [[ -z "$missing" ]]; then
    echo "  PASS: ${desc}"
  else
    echo "  FAIL: ${desc} — 출력에 없음: ${missing}" >&2
    FAIL=1
  fi
}
assert_detail_forwarded "queue-blocked(31) 상세 2건 전달" "queue-blocked"
assert_detail_forwarded "blocked(20) 상세 2건 전달"       "blocked:relations-unavailable"

# 빈 outcome 파일 → 40
empty_of="${TMP}/empty"; : > "$empty_of"
RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$empty_of" \
  bash "$WRAPPER" >/dev/null 2>&1
if [[ $? == 40 ]]; then echo "  PASS: 빈 outcome → 40"; else echo "  FAIL: 빈 outcome → 40" >&2; FAIL=1; fi

# 존재하지 않는 outcome 경로 → 40 (harness-error 핵심 경로 — 세션 크래시/무기록)
missing_of="${TMP}/does-not-exist"
RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$missing_of" \
  bash "$WRAPPER" >/dev/null 2>&1
if [[ $? == 40 ]]; then echo "  PASS: 부재 outcome → 40"; else echo "  FAIL: 부재 outcome → 40" >&2; FAIL=1; fi

# 무인 경로의 세션 기동 억제 — wrapper 가 RD_CHILD_SESSION 을 자식에게 넘기는지 본다.
# 이것이 없으면 HERDR_ENV=1 환경에서 promote.sh 가 FR 마다 herdr 탭을 띄워 무인 완주가
# 깨진다(2026-09-24 /fr batch 회귀). 변수가 비어 있는 상태로 wrapper 를 부른 뒤,
# wrapper 가 만든 환경에서 값이 보이는지 확인한다.
# 자식 프로세스가 실제로 값을 받는지 재야 하므로, claude 를 대역으로 세워 그 안에서
# 본 값을 파일에 적게 한다. NO_INVOKE 경로는 claude 를 부르지 않아 이 기전을 못 본다.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${RD_CHILD_SESSION:-}" > "$RD_PROBE_SEEN_FILE"
STUB
chmod +x "${TMP}/bin/claude"
probe_of="${TMP}/probe"; seen_file="${TMP}/seen"; : > "$seen_file"
env -u RD_CHILD_SESSION PATH="${TMP}/bin:$PATH" RD_PROBE_SEEN_FILE="$seen_file" \
  RD_AUTOPILOT_FR=probe RD_AUTOPILOT_OUTCOME_FILE="$probe_of" \
  bash "$WRAPPER" >/dev/null 2>&1
probe_seen="$(cat "$seen_file" 2>/dev/null)"
if [[ "$probe_seen" == "1" ]]; then
  echo "  PASS: wrapper 가 RD_CHILD_SESSION=1 을 export"
else
  echo "  FAIL: wrapper 가 RD_CHILD_SESSION 을 export 하지 않음 (본 값: '${probe_seen}')" >&2
  FAIL=1
fi

# 자식이 작업 worktree 로 이동해도 outcome 이 회수되는지 — R1 회귀.
# wrapper 는 자기 CWD 에서 outcome 을 비우고 읽는데 자식은 다른 디렉터리로 옮겨 간다.
# 상대경로를 그대로 넘기면 자식이 쓴 completed 를 부모가 못 읽어 exit 40 이 된다.
mkdir -p "${TMP}/caller/rd-workflow-workspace" "${TMP}/elsewhere"
cat > "${TMP}/bin/claude" <<'STUB'
#!/usr/bin/env bash
cd "$RD_PROBE_CHDIR" || exit 1
printf 'completed\n' > "$RD_AUTOPILOT_OUTCOME_FILE"
STUB
chmod +x "${TMP}/bin/claude"
assert_chdir_outcome() {  # $1=desc $2=RD_AUTOPILOT_OUTCOME_FILE 값(빈값이면 기본 경로)
  local desc="$1" of="$2"
  ( cd "${TMP}/caller" || exit 40
    if [[ -n "$of" ]]; then
      env PATH="${TMP}/bin:$PATH" RD_PROBE_CHDIR="${TMP}/elsewhere" \
        RD_AUTOPILOT_FR=probe RD_AUTOPILOT_OUTCOME_FILE="$of" bash "$WRAPPER" >/dev/null 2>&1
    else
      env PATH="${TMP}/bin:$PATH" RD_PROBE_CHDIR="${TMP}/elsewhere" \
        RD_AUTOPILOT_FR=probe bash "$WRAPPER" >/dev/null 2>&1
    fi )
  local code=$?
  if [[ "$code" == 0 ]]; then
    echo "  PASS: ${desc}"
  else
    echo "  FAIL: ${desc} — expected 0, got ${code}" >&2
    FAIL=1
  fi
}
assert_chdir_outcome "자식이 이동해도 기본 outcome 경로 회수" ""
assert_chdir_outcome "자식이 이동해도 batch 형태 상대 outcome 경로 회수" "rd-workflow-workspace/.batch-outcome-probe"

# 자식 세션이 받는 Bash timeout env — wrapper 가 BASH_DEFAULT_TIMEOUT_MS 를 올려 넘기는지 본다.
# 무인 claude -p 가 self_test 를 foreground 로 돌리면 기본 120초 timeout 에 걸린다
# (FR headless-verification-exceeds-bash-timeout). 대역 claude 가 자기 환경에서 본
# 두 변수를 파일에 적게 해, wrapper 의 덮어쓰기·누락·MAX 변조를 잡는다.
mkdir -p "${TMP}/tbin"
cat > "${TMP}/tbin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'D=%s M=%s' "${BASH_DEFAULT_TIMEOUT_MS-}" "${BASH_MAX_TIMEOUT_MS-}" > "$RD_PROBE_SEEN_FILE"
printf 'completed\n' > "$RD_AUTOPILOT_OUTCOME_FILE"
STUB
chmod +x "${TMP}/tbin/claude"
assert_timeout_env() {  # $1=desc $2=기대 seen $3=stderr 부분문자열 $4..=env 인자
  local desc="$1" want_seen="$2" want_err="$3"; shift 3
  local seen_f="${TMP}/t-seen" err_f="${TMP}/t-err" of="${TMP}/t-outcome"
  : > "$seen_f"; : > "$err_f"
  env -u BASH_DEFAULT_TIMEOUT_MS -u BASH_MAX_TIMEOUT_MS PATH="${TMP}/tbin:$PATH" \
    RD_PROBE_SEEN_FILE="$seen_f" RD_AUTOPILOT_FR=probe RD_AUTOPILOT_OUTCOME_FILE="$of" "$@" \
    bash "$WRAPPER" >/dev/null 2>"$err_f"
  local seen err; seen="$(cat "$seen_f")"; err="$(cat "$err_f")"
  if [[ "$seen" == "$want_seen" && "$err" == *"$want_err"* ]]; then
    echo "  PASS: ${desc}"
  else
    echo "  FAIL: ${desc} — seen='${seen}' (기대 '${want_seen}'), stderr 에 '${want_err}' ${err:+있는지 확인: ${err}}" >&2
    FAIL=1
  fi
}
assert_timeout_env "T1 미설정 → 7500000 (기본값)"       "D=7500000 M="        "BASH_DEFAULT_TIMEOUT_MS=7500000 (기본값)"
assert_timeout_env "T2 호출자 900000 보존 (호출자 설정)" "D=900000 M="         "(호출자 설정)" BASH_DEFAULT_TIMEOUT_MS=900000
assert_timeout_env "T3 빈 문자열 → 기본값"              "D=7500000 M="        "(기본값)" BASH_DEFAULT_TIMEOUT_MS=
assert_timeout_env "T4 비숫자 abc 유지 + 경고"           "D=abc M="            "경고" BASH_DEFAULT_TIMEOUT_MS=abc
assert_timeout_env "T5 BASH_MAX_TIMEOUT_MS 600000 보존" "D=7500000 M=600000"  "(기본값)" BASH_MAX_TIMEOUT_MS=600000

# claude 종료 코드 보존 — outcome 미기록 종료(exit 40)의 원인을 요약 줄에서 구분하는지 본다.
# 대역 claude 가 종료 방식만 바꾼다. 시간 상한 경로는 RD_FR_WALL_MINUTES=0 으로 피한다.
# 목표 단언마다 별도 mock 을 쓴다 — 한 단언이 실패해도 다른 단언에 도달하게 하려는 것이다.
mkdir -p "${TMP}/rcbin"
RC_OUT=""; RC_CODE=0
run_rc_mock() {  # $1=mock 본문 — 결과는 RC_OUT(stdout+stderr)·RC_CODE
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "${TMP}/rcbin/claude"
  chmod +x "${TMP}/rcbin/claude"
  RC_OUT="$(env PATH="${TMP}/rcbin:$PATH" RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 \
    RD_AUTOPILOT_OUTCOME_FILE="${TMP}/rc-outcome" bash "$WRAPPER" 2>&1)"
  RC_CODE=$?
}
assert_rc_case() {  # $1=desc $2=기대 exit $3=출력 부분문자열(빈 값이면 생략)
  local desc="$1" want_code="$2" want_text="$3"
  if [[ "$RC_CODE" == "$want_code" && ( -z "$want_text" || "$RC_OUT" == *"$want_text"* ) ]]; then
    echo "  PASS: ${desc}"
  else
    echo "  FAIL: ${desc} — exit ${RC_CODE} (기대 ${want_code}), 출력에 '${want_text}' 없음: ${RC_OUT}" >&2
    FAIL=1
  fi
}
run_rc_mock 'exit 3'
assert_rc_case "① claude exit 3·outcome 미기록 → 40, 비정상 종료(코드 3)" 40 "비정상 종료(코드 3)"
run_rc_mock 'kill -TERM $$; sleep 5'
assert_rc_case "② claude 가 TERM 으로 죽음 → 40, 신호 종료(TERM)" 40 "신호 종료(TERM)"
run_rc_mock 'exit 0'
assert_rc_case "③ claude exit 0·outcome 미기록 → 40, 정상 종료(0) 인데 outcome 미기록" 40 "정상 종료(0) 인데 outcome 미기록"
run_rc_mock 'printf "completed\n" > "$RD_AUTOPILOT_OUTCOME_FILE"; exit 3'
assert_rc_case "④ outcome completed + claude exit 3 → 0 (토큰 우선)" 0 ""
# ⑥ 종료 코드 줄은 stderr 채널에만 나온다 — 2>&1 로 합치면 stdout 으로 옮겨도 통과하므로 채널을 나눠 본다.
printf '#!/usr/bin/env bash\nexit 3\n' > "${TMP}/rcbin/claude"; chmod +x "${TMP}/rcbin/claude"
CH_OUT="$(env PATH="${TMP}/rcbin:$PATH" RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 \
  RD_AUTOPILOT_OUTCOME_FILE="${TMP}/rc-outcome" bash "$WRAPPER" 2>"${TMP}/ch-err")"
CH_ERR="$(cat "${TMP}/ch-err")"
if [[ "$CH_ERR" == *"autopilot_headless: claude 종료 코드=3"* && "$CH_OUT" != *"claude 종료 코드="* ]]; then
  echo "  PASS: ⑥ 종료 코드 줄이 stderr 에만 나옴"
else
  echo "  FAIL: ⑥ 종료 코드 줄이 stderr 에만 나옴 — stderr='${CH_ERR}' stdout='${CH_OUT}'" >&2
  FAIL=1
fi

# outcome 둘째 줄 이후 출력 확대 — completed 도 상세가 나오고, 신뢰 불가한 40 은 내지 않는다.
assert_second_line() {  # $1=desc $2=첫 줄 $3=둘째 줄 $4=1(출력돼야 함)|0(나오면 안 됨)
  local desc="$1" first="$2" second="$3" want="$4" of="${TMP}/second-outcome" out
  printf '%s\n%s\n' "$first" "$second" > "$of"
  out="$(RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$of" bash "$WRAPPER" 2>/dev/null)"
  local has=0; case "$out" in *"$second"*) has=1 ;; esac
  if [[ "$has" == "$want" ]]; then echo "  PASS: ${desc}"
  else echo "  FAIL: ${desc} — 둘째 줄 출력 여부 ${has} (기대 ${want}): ${out}" >&2; FAIL=1; fi
}
assert_second_line "⑤ completed 둘째 줄 stdout 출력" "completed" "재개: s /p" 1
assert_second_line "⑤ garbage(40) 둘째 줄 미출력"     "garbage"   "재개: s /p" 0

if [[ $FAIL == 0 ]]; then echo "test_autopilot_headless: PASS"; exit 0
else echo "test_autopilot_headless: FAIL" >&2; exit 1; fi
