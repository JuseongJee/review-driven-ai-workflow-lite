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
  RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 RD_AUTOPILOT_OUTCOME_FILE="$probe_of" \
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
        RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 RD_AUTOPILOT_OUTCOME_FILE="$of" bash "$WRAPPER" >/dev/null 2>&1
    else
      env PATH="${TMP}/bin:$PATH" RD_PROBE_CHDIR="${TMP}/elsewhere" \
        RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 bash "$WRAPPER" >/dev/null 2>&1
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
    RD_PROBE_SEEN_FILE="$seen_f" RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 RD_AUTOPILOT_OUTCOME_FILE="$of" "$@" \
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
# J3 빈 결과 — 비용 줄이 사유와 함께 나온다
assert_rc_case "J3 빈 결과 → 비용 줄 'claude 결과 출력 없음'" 40 "실행 비용 확인 불가 — claude 결과 출력 없음"
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

# J5 claude 를 부르지 않은 실행(NO_INVOKE)에는 비용 줄이 없다
j5_of="${TMP}/j5-outcome"; printf 'completed\n' > "$j5_of"
j5_out="$(RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$j5_of" bash "$WRAPPER" 2>&1)"
case "$j5_out" in
  *"실행 비용"*) echo "  FAIL: J5 NO_INVOKE 에 비용 줄 — ${j5_out}" >&2; FAIL=1 ;;
  *) echo "  PASS: J5 NO_INVOKE 에 비용 줄 없음" ;;
esac

# ── 실행 비용 줄 (FR autopilot-headless-cost-in-report) ──
# 가짜 claude 가 결과 JSON·text 를 낸다. JSON 은 2026-11-06 Claude Code 2.1.319 실측 형식에서 필요한 필드만 옮겼다.
mkdir -p "${TMP}/jbin"
J_JSON='{"type":"result","subtype":"success","is_error":false,"duration_ms":1337,"duration_api_ms":1019,"num_turns":1,"result":"본문-표식-J1","total_cost_usd":0.00648573,"usage":{"input_tokens":2,"cache_creation_input_tokens":31824,"cache_read_input_tokens":11873,"output_tokens":4},"modelUsage":{"claude-haiku-5-5":{"costUSD":0.00648573,"costBasis":"list"}}}'
J_OUT=""; J_CODE=0
run_j_mock() {  # $1=가짜 claude 가 stdout 에 낼 내용 $2=outcome 첫 줄 — 결과는 J_OUT(stdout)·J_CODE
  printf '%s' "$1" > "${TMP}/j-payload"
  printf '#!/usr/bin/env bash\ncat "%s"\nprintf "%%s\\n" "%s" > "$RD_AUTOPILOT_OUTCOME_FILE"\n' "${TMP}/j-payload" "$2" > "${TMP}/jbin/claude"
  chmod +x "${TMP}/jbin/claude"
  J_OUT="$(env PATH="${TMP}/jbin:$PATH" RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 \
    RD_AUTOPILOT_OUTCOME_FILE="${TMP}/j-outcome" bash "$WRAPPER" 2>/dev/null)"
  J_CODE=$?
}
j_check() {  # $1=desc $2=조건 결과(0=참)
  if [[ "$2" == 0 ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 — exit ${J_CODE}, stdout: ${J_OUT}" >&2; FAIL=1; fi
}
J1_LINE='autopilot_headless: 실행 비용 $0.0065 (정가 환산) · 토큰 입력 2 · 출력 4 · 캐시 쓰기 31,824 · 캐시 읽기 11,873 · 소요 0.0분 · 턴 1'
run_j_mock "$J_JSON" completed
j_check "J1a JSON 결과 → exit 0, 본문(result) 출력" "$([[ $J_CODE == 0 && "$J_OUT" == *"본문-표식-J1"* ]]; echo $?)"
j_check "J1b 원문 JSON 누출 없음"                     "$([[ "$J_OUT" != *'"total_cost_usd"'* ]]; echo $?)"
j_check "J1c 비용 줄 값 일치"                         "$(printf '%s\n' "$J_OUT" | grep -qxF "$J1_LINE"; echo $?)"
j_check "J1d 비용 줄이 요약 줄 바로 다음 줄"          "$(printf '%s\n' "$J_OUT" | grep -A1 -xF 'autopilot_headless: 완료 (completed) [exit 0]' | tail -n1 | grep -qxF "$J1_LINE"; echo $?)"

run_j_mock "plain-text-J2" "blocked:probe"
j_check "J2 비 JSON 결과 → exit 20, 원문 보존, 사유 '결과가 JSON 이 아님'" \
  "$([[ $J_CODE == 20 && "$J_OUT" == *"plain-text-J2"* && "$J_OUT" == *"autopilot_headless: 실행 비용 확인 불가 — 결과가 JSON 이 아님"* ]]; echo $?)"

run_j_mock "$(printf '%s' "$J_JSON" | sed 's/"is_error":false/"is_error":true/; s/"subtype":"success"/"subtype":"error_max_turns"/')" completed
j_check "J6 is_error 결과 → exit 0 유지, 비용 줄 끝 '결과 오류(error_max_turns)'" \
  "$([[ $J_CODE == 0 ]] && printf '%s\n' "$J_OUT" | grep '^autopilot_headless: 실행 비용 \$' | grep -q ' · 결과 오류(error_max_turns)$'; echo $?)"

# J7 JSON 이지만 객체가 아닌 결과(null) — 파싱 실패와 구분해 원문과 정확한 사유를 내고 traceback 을 내지 않는다
printf 'null' > "${TMP}/j-payload"
printf '#!/usr/bin/env bash\ncat "%s"\nprintf "completed\\n" > "$RD_AUTOPILOT_OUTCOME_FILE"\n' "${TMP}/j-payload" > "${TMP}/jbin/claude"
J_OUT="$(env PATH="${TMP}/jbin:$PATH" RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 \
  RD_AUTOPILOT_OUTCOME_FILE="${TMP}/j-outcome" bash "$WRAPPER" 2>"${TMP}/j7-err")"; J_CODE=$?
j_check "J7 null 결과 → 원문 보존, 사유 '결과가 JSON 객체가 아님', traceback 없음" \
  "$([[ $J_CODE == 0 ]] && printf '%s\n' "$J_OUT" | grep -qx 'null' \
     && [[ "$J_OUT" == *"autopilot_headless: 실행 비용 확인 불가 — 결과가 JSON 객체가 아님"* ]] \
     && ! grep -q Traceback "${TMP}/j7-err"; echo $?)"

# J4 python3 실행 검사가 실패하는 환경 — 종전 text 실행을 유지한다
mkdir -p "${TMP}/pybin" "${TMP}/j4bin"
printf '#!/bin/sh\nexit 1\n' > "${TMP}/pybin/python3"; chmod +x "${TMP}/pybin/python3"
cat > "${TMP}/j4bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$RD_PROBE_SEEN_FILE"
echo "text-body-J4"
printf 'completed\n' > "$RD_AUTOPILOT_OUTCOME_FILE"
STUB
chmod +x "${TMP}/j4bin/claude"
: > "${TMP}/j4-seen"
J_OUT="$(env PATH="${TMP}/pybin:${TMP}/j4bin:$PATH" RD_PROBE_SEEN_FILE="${TMP}/j4-seen" RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 \
  RD_AUTOPILOT_OUTCOME_FILE="${TMP}/j4-outcome" bash "$WRAPPER" 2>/dev/null)"; J_CODE=$?
j_check "J4 python3 불가 → --output-format text, 본문 그대로, 사유 'python3 를 쓸 수 없음'" \
  "$([[ $J_CODE == 0 && "$(cat "${TMP}/j4-seen")" == *"--output-format text"* && "$J_OUT" == *"text-body-J4"* \
       && "$J_OUT" == *"autopilot_headless: 실행 비용 확인 불가 — python3 를 쓸 수 없음 (text 출력으로 실행)"* ]]; echo $?)"

# K 비용 기록 파일 — RD_AUTOPILOT_COST_FILE 에 실행마다 기계 판독 한 줄을 덧붙인다
# (인계 권장 경로가 worktree 밖이라는 점은 fixture 가 경로를 직접 적어 공허하므로 여기서 단언하지 않는다)
K_FILE="${TMP}/cost.tsv"; rm -f "$K_FILE"
export RD_AUTOPILOT_COST_FILE="$K_FILE"
run_j_mock "$J_JSON" completed
run_j_mock "" completed
unset RD_AUTOPILOT_COST_FILE
j_check "K1 비용 기록 파일이 정확히 2줄" "$([[ "$(wc -l < "$K_FILE" 2>/dev/null | tr -d ' ')" == 2 ]]; echo $?)"
j_check "K2 1줄째 cost ok 0.006486" "$([[ "$(sed -n 1p "$K_FILE" 2>/dev/null)" == "$(printf 'cost\tok\t0.006486')" ]]; echo $?)"
j_check "K3 2줄째 cost unknown 사유" "$([[ "$(sed -n 2p "$K_FILE" 2>/dev/null)" == "$(printf 'cost\tunknown\tclaude 결과 출력 없음')" ]]; echo $?)"

# K4 비용 기록 파일을 쓸 수 없어도 종료 코드는 그대로이고 경고를 낸다
run_j_mock "$J_JSON" completed
K4_ERR="${TMP}/k4-err"
env PATH="${TMP}/jbin:$PATH" RD_AUTOPILOT_FR=probe RD_FR_WALL_MINUTES=0 RD_AUTOPILOT_OUTCOME_FILE="${TMP}/j-outcome" \
  RD_AUTOPILOT_COST_FILE="${TMP}/no-such-dir/cost.tsv" bash "$WRAPPER" >/dev/null 2>"$K4_ERR"; J_CODE=$?
j_check "K4a 비용 기록 실패에도 exit 0" "$([[ $J_CODE == 0 ]]; echo $?)"
j_check "K4b 비용 기록 실패 경고" "$(grep -qxF "autopilot_headless: 경고 — 비용 기록 실패: ${TMP}/no-such-dir/cost.tsv" "$K4_ERR"; echo $?)"

# D diag_lines — wrapper 에서 함수를 뽑아 호출한다 (timecap 테스트의 load_fn 과 같은 방식)
diag_fn_load() { eval "$(sed -n "/^$1()/,/^}/p" "$WRAPPER")"; }
diag_fn_load list_open_review_sessions
diag_fn_load diag_lines
mkdir -p "${TMP}/diag-repo/sub" "${TMP}/diag-nogit"
git -C "${TMP}/diag-repo" init -q
D1_OUT="$(cd "${TMP}/diag-repo/sub" && diag_lines 2>/dev/null)"
j_check "D1 진행 중 작업 없음 한 줄, 판정 실패 없음" \
  "$([[ "$D1_OUT" == "작업 상태: 진행 중 작업 없음" ]]; echo $?)"
D2_OUT="$(cd "${TMP}/diag-nogit" && GIT_CEILING_DIRECTORIES="$TMP" diag_lines 2>/dev/null)"
j_check "D2 git 밖에서는 판정 실패" "$(printf '%s\n' "$D2_OUT" | grep -qxF '작업 상태: 판정 실패'; echo $?)"

# ── 무인 발행 (FR autopilot-archive-responsibility-to-wrapper) ──
# publish-ready outcome 을 심고, 대체 archive 명령(RD_AUTOPILOT_ARCHIVE_CMD)으로 wrapper 발행 단계를 검사한다.
cat > "${TMP}/fake_archive.sh" <<'FAKE'
#!/usr/bin/env bash
cp "$RD_FAKE_STDERR_FILE" "$RD_FAKE_SEEN" 2>/dev/null
printf '%s\n' "$*" > "$RD_FAKE_ARGS"
case "$RD_FAKE_MODE" in
  ok)
    echo 'archive: CLEANUP-PENDING'
    echo 'archive:   [k] id'
    echo 'archive:     복구: cmd'
    echo 'archive: core 완료 (정리 잔여 있음). tag=archive/x-1' ;;
  refuse) echo 'archive: worktree dirty — 커밋하지 않은 변경' >&2; exit 1 ;;
  midway) git -c user.name=t -c user.email=t@t commit --allow-empty -qm merge; echo 'archive: push 실패' >&2; exit 1 ;;
  recfail)
    echo 'archive: 완료. tag=archive/x-1'
    echo 'archive: CLEANUP-RECORD-FAILED write 정리 잔여 기록을 남기지 못함 (x)' >&2; exit 1 ;;
  unsafe)
    echo 'archive: 완료. tag=archive/x-1'
    echo 'archive: 안전 불변식 위반 — y' >&2; exit 1 ;;
  silent) exit 0 ;;
  already) echo 'archive: 이미 archive 완료 — nothing to do (tag=fr/2026/x)' ;;
  premerged) echo 'archive: fr/x 이미 merge 됨 — skip'; echo 'archive: push 실패' >&2; exit 1 ;;
  hang) printf '%s\n' "$$" > "$RD_FAKE_PIDFILE"; exec sleep 30 ;;
  hang-noterm) trap '' TERM; printf '%s\n' "$$" > "$RD_FAKE_PIDFILE"; exec sleep 30 ;;
  merge-hang)
    git -c user.name=t -c user.email=t@t commit --allow-empty -qm 'merge: x (hang)'
    printf '%s\n' "$$" > "$RD_FAKE_PIDFILE"; exec sleep 30 ;;
esac
FAKE
P_CASE=0
# run_pub <라벨> <정책|-> <모드> <outcome 본문(printf 형식)> [setup=premerged|blocklogdir] [추가 env KEY=VAL ...]
run_pub() {
  local label="$1" policy="$2" mode="$3" outc="$4" setup="${5:-}" xenv=()
  (( $# > 5 )) && xenv=("${@:6}")
  P_CASE=$((P_CASE + 1))
  local repo="${TMP}/pub${P_CASE}"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main && git -c user.name=t -c user.email=t@t commit --allow-empty -qm init ) || true
  if [[ "$setup" == premerged ]]; then
    ( cd "$repo" && git -c user.name=t -c user.email=t@t checkout -q -b fr/x \
      && git -c user.name=t -c user.email=t@t commit --allow-empty -qm work \
      && git checkout -q main \
      && git -c user.name=t -c user.email=t@t merge -q --no-ff -m "merge: x (archive)" fr/x )
  fi
  # blocklogdir: 로그 디렉터리를 만들 수 없게 git 공용 디렉터리의 rd-workflow 자리에 빈 파일을 둔다
  [[ "$setup" == blocklogdir ]] && : > "${repo}/.git/rd-workflow"
  P_PIDFILE="${TMP}/pid-${label}"; rm -f "$P_PIDFILE"
  P_T0=$SECONDS
  RD_FAKE_ARGS="${TMP}/args-${label}"; RD_FAKE_SEEN="${TMP}/seen-${label}"
  RD_FAKE_STDERR_FILE="${TMP}/err-${label}"; P_OF="${TMP}/outcome-${label}"
  rm -f "$RD_FAKE_ARGS"
  printf "$outc" > "$P_OF"
  local penv=()
  [[ "$policy" != "-" ]] && penv=("RD_FINISH_POLICY=${policy}")
  P_OUT="$(cd "$repo" && env -u RD_FINISH_POLICY ${penv[@]+"${penv[@]}"} \
    RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$P_OF" \
    RD_AUTOPILOT_ARCHIVE_CMD="bash ${TMP}/fake_archive.sh" \
    RD_FAKE_ARGS="$RD_FAKE_ARGS" RD_FAKE_SEEN="$RD_FAKE_SEEN" RD_FAKE_STDERR_FILE="$RD_FAKE_STDERR_FILE" RD_FAKE_MODE="$mode" \
    RD_FAKE_PIDFILE="$P_PIDFILE" ${xenv[@]+"${xenv[@]}"} \
    bash "$WRAPPER" 2>"$RD_FAKE_STDERR_FILE")"; P_CODE=$?
  P_ELAPSED=$((SECONDS - P_T0))
  P_ALL="${P_OUT}
$(cat "$RD_FAKE_STDERR_FILE")"
  P_FIRST="$(head -n1 "$P_OF")"
}
p_check() {  # $1=desc $2=조건 결과(0=참)
  if [[ "$2" == 0 ]]; then echo "  PASS: $1"; else echo "  FAIL: $1 — exit ${P_CODE}, outcome: $(cat "$P_OF" 2>/dev/null | head -n3 | tr '\n' '|'), 출력: ${P_OUT}" >&2; FAIL=1; fi
}
p_exit_outcome() {  # $1=케이스 $2=기대 exit $3=기대 outcome 첫 줄
  p_check "$1 exit ${2}, 기대 ${3}" "$([[ $P_CODE == "$2" && "$P_FIRST" == "$3" ]]; echo $?)"
}
PO='publish-ready\ntask x\n'

run_pub A - ok "$PO"
p_exit_outcome "발행 A 정책 미설정 ok" 0 completed
p_check "발행 A args 에 --task x" "$([[ "$(cat "$RD_FAKE_ARGS")" == *"--task x"* ]]; echo $?)"
p_check "발행 A args 에 --no-remote 없음" "$([[ "$(cat "$RD_FAKE_ARGS")" != *"--no-remote"* ]]; echo $?)"
p_check "발행 A 발행 완료·push 정책 줄" "$([[ "$P_ALL" == *"autopilot_headless: 발행 완료"* && "$P_ALL" == *"push 정책"* ]]; echo $?)"
p_check "발행 A 정리 잔여 복구 줄 전달" "$([[ "$P_ALL" == *"archive:     복구: cmd"* ]]; echo $?)"

run_pub B merge ok "$PO"
p_exit_outcome "발행 B merge ok" 0 completed
p_check "발행 B args 에 --no-remote" "$([[ "$(cat "$RD_FAKE_ARGS")" == *"--no-remote"* ]]; echo $?)"
p_check "발행 B push 하지 않음 줄" "$([[ "$P_ALL" == *"push 하지 않음"* ]]; echo $?)"

run_pub C push refuse "$PO"
p_exit_outcome "발행 C push refuse" 20 blocked:publish-failed
p_check "발행 C 사유·로그·다음 출력" "$([[ "$P_ALL" == *"사유: archive: worktree dirty"* && "$P_ALL" == *"로그: "* && "$P_ALL" == *"다음: "* && "$P_ALL" == *"--task x"* ]]; echo $?)"
p_check "발행 C 시작 줄이 archive 실행 전에 나옴" "$([[ "$(cat "$RD_FAKE_SEEN" 2>/dev/null)" == *"발행 시작 — task x · push 정책 · 로그 "* ]]; echo $?)"

run_pub D merge midway "$PO"
p_exit_outcome "발행 D merge midway" 20 blocked:publish-incomplete
p_check "발행 D 이어붙이기 안내" "$([[ "$P_ALL" == *"--fr-branch fr/x --no-remote"* ]]; echo $?)"

run_pub E push ok 'publish-ready\n'
p_exit_outcome "발행 E 작업 이름 없음" 20 blocked:publish-failed
p_check "발행 E archive 호출 안 됨" "$([[ ! -e "$RD_FAKE_ARGS" ]]; echo $?)"

run_pub E2 push ok 'publish-ready\ntask a b\n'
p_exit_outcome "발행 E2 이름 내부 공백" 20 blocked:publish-failed
p_check "발행 E2 archive 호출 안 됨" "$([[ ! -e "$RD_FAKE_ARGS" ]]; echo $?)"

run_pub F push recfail "$PO"
p_exit_outcome "발행 F recfail" 0 completed
p_check "발행 F outcome 둘째 줄 cleanup-record-failed x" "$([[ "$(sed -n 2p "$P_OF")" == "cleanup-record-failed x "* ]]; echo $?)"

run_pub G push unsafe "$PO"
p_exit_outcome "발행 G unsafe" 20 blocked:publish-unsafe
p_check "발행 G 출력에 --fr-branch 없음" "$([[ "$P_ALL" != *"--fr-branch"* ]]; echo $?)"

run_pub H push silent "$PO"
p_exit_outcome "발행 H silent exit 0" 20 blocked:publish-failed

run_pub I push already "$PO"
p_exit_outcome "발행 I already" 0 completed
p_check "발행 I 발행 완료·tag=fr/2026/x" "$([[ "$P_ALL" == *"발행 완료"* && "$P_ALL" == *"tag=fr/2026/x"* ]]; echo $?)"

run_pub J push premerged "$PO" premerged
p_exit_outcome "발행 J premerged" 20 blocked:publish-incomplete
p_check "발행 J 이어붙이기 안내" "$([[ "$P_ALL" == *"--fr-branch fr/x"* ]]; echo $?)"

# N1 none 정책 — 발행하지 않고 completed 로 끝낸다 (archive 대역 미호출)
run_pub N none ok "$PO"
p_exit_outcome "발행 N none 정책" 0 completed
p_check "발행 N 발행 하지 않음 줄" "$([[ "$P_ALL" == *"발행 하지 않음 (none 정책)"* ]]; echo $?)"
p_check "발행 N archive 미호출" "$([[ ! -e "$RD_FAKE_ARGS" ]]; echo $?)"

# ── 발행 단계 시간 상한 (FR unattended-publish-step-timeout) ──
# 대역은 모두 sleep 30 으로 끝나므로 감시가 고장 나도 케이스는 30초 안에 끝나고 경과 시간 단언이 FAIL 한다.
reap_pidfile() {  # 케이스 끝 정리 — pid 파일의 프로세스를 KILL (남아 있을 때만)
  local pp; pp="$(cat "$1" 2>/dev/null)"
  [[ -n "$pp" ]] && kill -KILL "$pp" 2>/dev/null
  return 0
}
pid_gone() {  # pid 파일의 프로세스가 없으면 0 (파일이 없으면 판정 불가 → 1)
  local pp; pp="$(cat "$1" 2>/dev/null)"
  [[ -n "$pp" ]] && ! kill -0 "$pp" 2>/dev/null
}
TCAP=(RD_PUBLISH_WALL_MINUTES=0.02 RD_FR_WALL_GRACE_SECONDS=1)

# T1 멈춘 발행 + TERM 무시 → 감시가 상한에서 TERM, 유예 뒤 KILL
run_pub T1 push hang-noterm "$PO" "" "${TCAP[@]}"
p_exit_outcome "T1 발행 상한 초과" 20 blocked:publish-failed
p_check "T1 사유 첫 줄(원인·출처·중단)" "$([[ "$(sed -n 2p "$P_OF")" == "사유: 발행 시간 상한(0.02분, 환경변수) 초과 — archive 를 중단했습니다" ]]; echo $?)"
p_check "T1 다음 줄 git status·--task x" "$([[ "$(grep '^다음: ' "$P_OF")" == *"git status"* && "$(grep '^다음: ' "$P_OF")" == *"--task x"* ]]; echo $?)"
p_check "T1 stderr 상한 줄" "$([[ "$P_ALL" == *"autopilot_headless: 발행 시간 상한=0.02분 (환경변수)"* ]]; echo $?)"
p_check "T1 pid 부재" "$(pid_gone "$P_PIDFILE"; echo $?)"
p_check "T1 경과 10초 미만 (${P_ELAPSED}초)" "$(( P_ELAPSED < 10 ? 0 : 1 ))"
reap_pidfile "$P_PIDFILE"

# T2 merge 뒤 멈춤 → incomplete, 이어붙이기 안내
run_pub T2 push merge-hang "$PO" "" "${TCAP[@]}"
p_exit_outcome "T2 merge 뒤 상한 초과" 20 blocked:publish-incomplete
p_check "T2 --fr-branch 안내" "$([[ "$P_ALL" == *"--fr-branch fr/x"* ]]; echo $?)"
p_check "T2 발행 줄 상한 초과" "$([[ "$P_ALL" == *"autopilot_headless: 발행 시간 상한(0.02분) 초과 — 병합됐으나"* ]]; echo $?)"
reap_pidfile "$P_PIDFILE"

# T3 발행 중 wrapper 가 TERM 을 받음 → 발행 그룹 회수, 143
T3_REPO="${TMP}/pubT3"; mkdir -p "$T3_REPO"
( cd "$T3_REPO" && git init -q -b main && git -c user.name=t -c user.email=t@t commit --allow-empty -qm init ) || true
T3_OF="${TMP}/outcome-T3"; printf 'publish-ready\ntask x\n' > "$T3_OF"; T3_PID="${TMP}/pid-T3"; rm -f "$T3_PID"
( cd "$T3_REPO" && exec env -u RD_FINISH_POLICY RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$T3_OF" \
    RD_AUTOPILOT_ARCHIVE_CMD="bash ${TMP}/fake_archive.sh" RD_FAKE_ARGS="${TMP}/args-T3" RD_FAKE_SEEN="${TMP}/seen-T3" \
    RD_FAKE_STDERR_FILE="${TMP}/err-T3" RD_FAKE_MODE=hang RD_FAKE_PIDFILE="$T3_PID" \
    RD_PUBLISH_WALL_MINUTES=5 RD_FR_WALL_GRACE_SECONDS=1 bash "$WRAPPER" >"${TMP}/out-T3" 2>"${TMP}/err-T3" ) &
T3_WP=$!
for _i in $(seq 1 50); do [[ -s "$T3_PID" ]] && break; sleep 0.1; done
T3_T0=$SECONDS
kill -TERM "$T3_WP" 2>/dev/null
for _i in $(seq 1 75); do kill -0 "$T3_WP" 2>/dev/null || break; sleep 0.2; done
T3_ALIVE=0
if kill -0 "$T3_WP" 2>/dev/null; then T3_ALIVE=1; kill -KILL "$T3_WP" 2>/dev/null; fi
wait "$T3_WP" 2>/dev/null; T3_CODE=$?
T3_ELAPSED=$((SECONDS - T3_T0))
P_CODE=$T3_CODE; P_OF="$T3_OF"; P_OUT="$(cat "${TMP}/out-T3" 2>/dev/null)"
p_check "T3 wrapper 가 15초 안에 반환 (${T3_ELAPSED}초)" "$T3_ALIVE"
p_check "T3 종료 코드 143" "$([[ $T3_CODE == 143 ]]; echo $?)"
p_check "T3 outcome publish-failed" "$([[ "$(head -n1 "$T3_OF")" == blocked:publish-failed ]]; echo $?)"
p_check "T3 사유 첫 줄 신호 TERM 수신" "$([[ "$(sed -n 2p "$T3_OF")" == "사유: 신호 TERM 수신 — archive 를 중단했습니다" ]]; echo $?)"
p_check "T3 pid 부재" "$(pid_gone "$T3_PID"; echo $?)"
p_check "T3 요약 줄이 실제 종료 코드 143 을 보임" "$(grep -q '^autopilot_headless: .*\[exit 143 — 신호 TERM 수신\]$' "${TMP}/out-T3"; echo $?)"
p_check "T3 신호부터 반환까지 8초 미만 (${T3_ELAPSED}초)" "$(( T3_ELAPSED < 8 ? 0 : 1 ))"
reap_pidfile "$T3_PID"

# T5 상한 초과로 회수하는 중에 TERM 을 받음 → 원인은 상한 초과, 종료 코드는 143
T5_REPO="${TMP}/pubT5"; mkdir -p "$T5_REPO"
( cd "$T5_REPO" && git init -q -b main && git -c user.name=t -c user.email=t@t commit --allow-empty -qm init ) || true
T5_OF="${TMP}/outcome-T5"; printf 'publish-ready\ntask x\n' > "$T5_OF"; T5_PID="${TMP}/pid-T5"; rm -f "$T5_PID"
( cd "$T5_REPO" && exec env -u RD_FINISH_POLICY RD_AUTOPILOT_HEADLESS_NO_INVOKE=1 RD_AUTOPILOT_OUTCOME_FILE="$T5_OF" \
    RD_AUTOPILOT_ARCHIVE_CMD="bash ${TMP}/fake_archive.sh" RD_FAKE_ARGS="${TMP}/args-T5" RD_FAKE_SEEN="${TMP}/seen-T5" \
    RD_FAKE_STDERR_FILE="${TMP}/ferr-T5" RD_FAKE_MODE=hang-noterm RD_FAKE_PIDFILE="$T5_PID" \
    RD_PUBLISH_WALL_MINUTES=0.02 RD_FR_WALL_GRACE_SECONDS=2 bash "$WRAPPER" >"${TMP}/out-T5" 2>"${TMP}/err-T5" ) &
T5_WP=$!
for _i in $(seq 1 50); do grep -q '도달' "${TMP}/err-T5" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$T5_WP" 2>/dev/null
for _i in $(seq 1 75); do kill -0 "$T5_WP" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$T5_WP" 2>/dev/null; then kill -KILL "$T5_WP" 2>/dev/null; fi
wait "$T5_WP" 2>/dev/null; T5_CODE=$?
P_CODE=$T5_CODE; P_OF="$T5_OF"; P_OUT="$(cat "${TMP}/out-T5" 2>/dev/null)"
p_check "T5 회수 중 신호 종료 코드 143" "$([[ $T5_CODE == 143 ]]; echo $?)"
p_check "T5 사유 첫 줄에 상한 초과와 회수 중 신호" "$([[ "$(sed -n 2p "$T5_OF")" == "사유: 발행 시간 상한(0.02분, 환경변수) 초과 · 회수 중 신호 TERM 수신 — archive 를 중단했습니다" ]]; echo $?)"
reap_pidfile "$T5_PID"

# T4 로그 디렉터리를 만들 수 없을 때 대체 로그는 wrapper 반환 뒤에도 남는다
run_pub T4 push refuse "$PO" blocklogdir
T4_LOG="$(sed -n 's/^로그: //p' "$P_OF" | head -n1)"
p_check "T4 대체 로그 파일 존재" "$([[ -n "$T4_LOG" && -f "$T4_LOG" ]]; echo $?)"
p_check "T4 대체 로그에 worktree dirty" "$(grep -q 'worktree dirty' "$T4_LOG" 2>/dev/null; echo $?)"

# J8 비용이 NaN — `$nan`·`cost ok nan` 으로 새지 않는다
J8_FILE="${TMP}/cost-j8.tsv"; rm -f "$J8_FILE"
export RD_AUTOPILOT_COST_FILE="$J8_FILE"
run_j_mock "$(printf '%s' "$J_JSON" | sed 's/"total_cost_usd":0.00648573/"total_cost_usd":NaN/')" completed
unset RD_AUTOPILOT_COST_FILE
j_check "J8 비용 줄 확인 불가 — 비용 값이 유한한 0 이상의 수가 아님" \
  "$(printf '%s\n' "$J_OUT" | grep -qxF 'autopilot_headless: 실행 비용 확인 불가 — 비용 값이 유한한 0 이상의 수가 아님'; echo $?)"
j_check "J8 기록 줄 cost unknown" \
  "$([[ "$(cat "$J8_FILE" 2>/dev/null)" == "$(printf 'cost\tunknown\t비용 값이 유한한 0 이상의 수가 아님')" ]]; echo $?)"

if [[ $FAIL == 0 ]]; then echo "test_autopilot_headless: PASS"; exit 0
else echo "test_autopilot_headless: FAIL" >&2; exit 1; fi
