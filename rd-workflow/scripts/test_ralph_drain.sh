#!/usr/bin/env bash
# test_ralph_drain.sh — ralph_drain.sh supervisor 루프 단위 테스트.
# RD_RALPH_WRAPPER_CMD 로 스크립트된 exit code 시퀀스를 주입해 결정적으로 검증한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAIN="${SCRIPT_DIR}/ralph_drain.sh"

TMP="$(mktemp -d)" || { echo "test_ralph_drain.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_ralph_drain.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# 무인 세션 모델·effort 해석이 부모 셸 값이나 사용자 models.json 에 흔들리지 않게 한다.
unset RD_HEADLESS_CLAUDE_MODEL RD_HEADLESS_CLAUDE_EFFORT RD_HEADLESS_FIXED_MODEL RD_HEADLESS_FIXED_EFFORT RD_HEADLESS_FIXED_LINE
export RD_MODELS_CONFIG="${TMP}/none.json"

# exit code 시퀀스를 반환하는 stub wrapper. 호출마다 counter 파일로 다음 코드를 낸다.
STUB="${TMP}/stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
i=$(cat "$RD_STUB_COUNTER" 2>/dev/null || echo 0)
echo "STUB-ENTER $((i + 1))" >&2
# 첫 호출에서 RD_STUB_MUTATE 를 실행한다 (회차 중 설정 파일 변경 흉내).
[ "$i" -eq 0 ] && [ -n "${RD_STUB_MUTATE:-}" ] && eval "$RD_STUB_MUTATE"
# shellcheck disable=SC2206
codes=($RD_STUB_CODES)
code="${codes[$i]:-30}"
echo $((i + 1)) > "$RD_STUB_COUNTER"
# 비용 기록 — RD_STUB_COSTS(공백 구분, 호출 순서별 ok:<USD>|unk:<사유>|none|gone)를 같은 카운터로 읽어 덧붙인다.
# gone 은 드레인 도중 기록 파일이 사라진 경우(다른 batch 정리 등)를 흉내 낸다.
if [ -n "${RD_AUTOPILOT_COST_FILE:-}" ]; then
  # shellcheck disable=SC2206
  costs=($RD_STUB_COSTS)
  cspec="${costs[$i]:-none}"
  case "$cspec" in
    ok:*)  printf 'cost\tok\t%s\n' "$(awk -v v="${cspec#ok:}" 'BEGIN{printf "%.6f", v}')" >> "$RD_AUTOPILOT_COST_FILE" ;;
    unk:*) printf 'cost\tunknown\t%s\n' "${cspec#unk:}" >> "$RD_AUTOPILOT_COST_FILE" ;;
    gone)  rm -f "$RD_AUTOPILOT_COST_FILE" ;;
  esac
fi
if [ -n "${RD_STUB_HLLOG:-}" ]; then
  echo "HLM=${RD_HEADLESS_FIXED_MODEL-}|HLE=${RD_HEADLESS_FIXED_EFFORT-}|HLL=${RD_HEADLESS_FIXED_LINE-}" >> "$RD_STUB_HLLOG"
fi
if [ -n "${RD_STUB_ENVLOG:-}" ]; then
  echo "FR=${RD_AUTOPILOT_FR:-} MODE=${RD_AUTOPILOT_MODE:-} FINISH=${RD_FINISH_POLICY:-}" >> "$RD_STUB_ENVLOG"
fi
# blocked(20)·queue-blocked(31) 시 outcome 파일 기록.
# 첫 줄은 토큰, RD_STUB_DETAIL 이 있으면 둘째 줄부터 대기 상세를 덧붙인다
# (supervisor 의 사유 수집·대기 상세 전달 검증용).
if [ -n "${RD_AUTOPILOT_OUTCOME_FILE:-}" ]; then
  case "$code" in
    20) printf '%s\n' "${RD_STUB_FIRST_LINE:-blocked:${RD_STUB_REASON:-review-50turn}}" > "$RD_AUTOPILOT_OUTCOME_FILE" ;;
    31) printf '%s\n' "${RD_STUB_FIRST_LINE:-queue-blocked}" > "$RD_AUTOPILOT_OUTCOME_FILE" ;;
  esac
  case "$code" in
    20|31) [ -n "${RD_STUB_DETAIL:-}" ] && printf '%s\n' "$RD_STUB_DETAIL" >> "$RD_AUTOPILOT_OUTCOME_FILE" ;;
  esac
fi
exit "$code"
STUBEOF
chmod +x "$STUB"

fail=0
DRAIN_ARGS=()
run_case() {
  # $1 이름  $2 기대 exit  $3 codes  나머지: 추가 env (KEY=VAL)
  local name="$1" expect="$2" codes="$3"; shift 3
  local counter="${TMP}/counter"; : > "$counter"
  local outcome="${TMP}/outcome"; : > "$outcome"
  local out ec
  # ralph_drain.sh 가 소비하는 변수 중 부모 셸에서 새어들 수 있는 것을 지워 케이스를
  # 부모 환경과 무관하게 만든다. 아래 고정 대입이 덮는 RD_AUTOPILOT_OUTCOME_FILE·
  # RD_RALPH_WRAPPER_CMD 는 대상이 아니다. PATH 등은 유지해야 하므로 env -i 는 쓰지 않는다.
  # 주의: BSD/macOS env 는 옵션을 환경 대입보다 **앞**에 두어야 한다 (test_review_wait.sh probe() 와 동일).
  #       -u 를 "$@" 앞에 두므로, 호출부가 이 변수를 의도적으로 넘기면 그 대입이 이긴다.
  out=$(env -u RD_AUTOPILOT_FR -u RD_AUTOPILOT_MODE -u RD_FINISH_POLICY \
        -u RD_RALPH_MAX_ITER -u RD_RALPH_NONPROGRESS_LIMIT -u RD_AUTOPILOT_COST_FILE -u RD_RALPH_SLUGS -u RD_RALPH_RELATIONS_CMD "$@" \
        RD_STUB_CODES="$codes" RD_STUB_COUNTER="$counter" \
        RD_AUTOPILOT_OUTCOME_FILE="$outcome" \
        RD_RALPH_WRAPPER_CMD="bash $STUB" \
        bash "$DRAIN" ${DRAIN_ARGS[@]+"${DRAIN_ARGS[@]}"} 2>&1); ec=$?
  if [ "$ec" -ne "$expect" ]; then
    echo "  FAIL [$name] exit 기대 $expect, 실제 $ec"; echo "$out" | sed 's/^/    /'; fail=1
  else
    echo "  ok [$name] exit $ec"
  fi
  LAST_OUT="$out"
  LAST_INVOCATIONS="$(cat "$counter" 2>/dev/null || echo 0)"
  [ -n "$LAST_INVOCATIONS" ] || LAST_INVOCATIONS=0
}

assert_contains() {
  case "$LAST_OUT" in
    *"$1"*) echo "  ok [contains] $1" ;;
    *) echo "  FAIL [contains] '$1' 없음"; fail=1 ;;
  esac
}

# wrapper 호출 횟수 단언 — 전역 실패의 "즉시 중단" 을 재는 수단이다.
assert_invocations() {
  if [ "${LAST_INVOCATIONS:-0}" = "$1" ]; then
    echo "  ok [invocations] $1"
  else
    echo "  FAIL [invocations] 기대 $1, 실제 ${LAST_INVOCATIONS:-0}"; fail=1
  fi
}

# 전체 출력에서 ralph_drain 요약 구역만 잘라낸다 (summarize 의 실제 마커 문자열).
summary_section() {
  printf '%s\n' "$LAST_OUT" | awk '/---- ralph_drain 요약 ----/{f=1} f'
}

# 대기 상세의 각 "행 전체" 가 요약 구역 안에 남았는지 본다. 전역 검색은 부족하다 —
# wrapper 출력에만 상세가 있고 요약에는 없는 구현이 통과하기 때문이다.
assert_detail_in_summary() {
  local sec line
  sec="$(summary_section)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$sec" in
      *"$line"*) echo "  ok [summary detail] ${line%%	*}" ;;
      *) echo "  FAIL [summary detail] 요약 구역에 행 전체가 없음: [$line]"; fail=1 ;;
    esac
  done <<EOF
$1
EOF
}

echo "== ralph_drain 테스트 =="
run_case "queue-empty 즉시" 0 "30";                          assert_contains "queue-empty"
run_case "completed 후 종료" 0 "0 30";                       assert_contains "completed (누적 1)"
run_case "blocked 후 종료" 0 "20 30";                        assert_contains "blocked: 1"
run_case "blocked 사유 수집" 0 "20 30" RD_STUB_REASON=loop-guard; assert_contains "loop-guard"
run_case "queue-blocked 즉시" 0 "31";                        assert_contains "의존 대기"

# 전역 실패는 다음 FR 로 넘어가지 않고 즉시 중단한다.
# stub 이 20 을 계속 돌려줘도 wrapper 호출은 1회여야 한다.
run_case "relations-unavailable 즉시 중단" 1 "20 20 20" \
  RD_STUB_FIRST_LINE=blocked:relations-unavailable
assert_contains "relations-unavailable"
assert_invocations 1

# resume-undetermined 도 전역 실패다 — 즉시 중단하고 사유·상세를 요약에 남긴다.
RDETAIL='-	재개 후보 판정 불가	resume_candidates.sh 출력 확인'
run_case "resume-undetermined 즉시 중단" 1 "20 20 20" \
  RD_STUB_FIRST_LINE=blocked:resume-undetermined RD_STUB_DETAIL="$RDETAIL"
assert_contains "재개 판정 불가 (resume-undetermined)"
assert_invocations 1
assert_detail_in_summary "$RDETAIL"

# 발행 실패 3종도 즉시 중단한다 — 다음 FR 로 넘어가면 실패한 발행 위에 작업이 쌓인다.
PDETAIL=$'사유: s\n로그: l\n다음: n'
run_case "publish-incomplete 즉시 중단" 1 "20 0 30" RD_STUB_REASON=publish-incomplete RD_STUB_DETAIL="$PDETAIL"
assert_contains "발행 중간 상태 (publish-incomplete)"
assert_contains "다음: n"
assert_invocations 1
run_case "publish-failed 즉시 중단" 1 "20 0 30" RD_STUB_REASON=publish-failed RD_STUB_DETAIL="$PDETAIL"
assert_contains "발행 실패 (publish-failed)"
assert_contains "다음: n"
assert_invocations 1
run_case "publish-unsafe 즉시 중단" 1 "20 0 30" RD_STUB_REASON=publish-unsafe RD_STUB_DETAIL="$PDETAIL"
assert_contains "발행 후 안전 검사 실패 (publish-unsafe)"
assert_contains "다음: n"
assert_invocations 1

# drain 의 최종 요약 구역에 대기 상세 2건이 "행 전체" 로 남는지 본다.
DETAIL='alpha-task	대기(선행: lead-task)	선행 lead-task 완료 필요
beta-task	오류(series)	fr_relations.sh validate 로 관계 데이터 수정'
run_case "대기 상세가 요약에 실린다" 0 "31" RD_STUB_DETAIL="$DETAIL"
assert_detail_in_summary "$DETAIL"

# exit 20(전역 실패) 경로도 같은 방식으로 본다 — 진단 전달까지 함께 덮는다.
# 고정 문구가 아니라 구별 가능한 실제 오류 메시지를 넣는다.
ERRLINE='-	인덱스 파일 없음: /tmp/nonexistent/FUTURE_REQUESTS.md	fr_relations.sh validate --root . 로 원인 확인'
run_case "전역 실패 진단이 요약에 실린다" 1 "20" \
  RD_STUB_FIRST_LINE=blocked:relations-unavailable RD_STUB_DETAIL="$ERRLINE"
assert_detail_in_summary "$ERRLINE"
assert_contains "인덱스 파일 없음: /tmp/nonexistent/FUTURE_REQUESTS.md"

run_case "harness-error 재시도 성공" 0 "40 30";              assert_contains "1회 재시도"
run_case "harness-error 재발 중단" 1 "40 40";                assert_contains "harness-error 재발"
run_case "non-progress 가드" 1 "10 10 10" RD_RALPH_NONPROGRESS_LIMIT=3; assert_contains "non-progress 가드"
run_case "iteration 상한" 1 "0 0 0" RD_RALPH_MAX_ITER=3;     assert_contains "iteration 상한"
run_case "MAX_ITER 비숫자 거부" 1 "30" RD_RALPH_MAX_ITER=abc; assert_contains "RD_RALPH_MAX_ITER 는 양수 정수"
run_case "MAX_ITER 0 거부" 1 "30" RD_RALPH_MAX_ITER=0;       assert_contains "1 이상"
run_case "NONPROGRESS 음수 거부" 1 "30" RD_RALPH_NONPROGRESS_LIMIT=-1; assert_contains "RD_RALPH_NONPROGRESS_LIMIT 는 양수 정수"
run_case "FINISH_POLICY 잘못된 값 거부" 1 "30" RD_FINISH_POLICY=bogus; assert_contains "push|merge|none"

# 기본 env 주입(merge/A/auto) 검증
ENVLOG="${TMP}/envlog"; : > "$ENVLOG"
run_case "기본 env 주입" 0 "30" RD_STUB_ENVLOG="$ENVLOG"
if grep -q "FR=auto MODE=A FINISH=merge" "$ENVLOG"; then
  echo "  ok [env] FR=auto MODE=A FINISH=merge 주입"
else
  echo "  FAIL [env] 기본 주입 불일치: $(cat "$ENVLOG")"; fail=1
fi

# finish policy override 검증
ENVLOG2="${TMP}/envlog2"; : > "$ENVLOG2"
run_case "finish policy override" 0 "30" RD_STUB_ENVLOG="$ENVLOG2" RD_FINISH_POLICY=push
if grep -q "FINISH=push" "$ENVLOG2"; then
  echo "  ok [env] FINISH=push 오버라이드"
else
  echo "  FAIL [env] override 불일치: $(cat "$ENVLOG2")"; fail=1
fi

# --- 정리 잔여(cleanup-pending) 요약 표시 (T3) ---
# 전용 stub·러너. 기존 STUB·run_case 는 건드리지 않는다.
CP_HELPER="${SCRIPT_DIR}/lifecycle/cleanup_pending.sh"
CP_STUB="${TMP}/cp_stub.sh"
cat > "$CP_STUB" <<'CPSTUBEOF'
#!/usr/bin/env bash
i=$(cat "$RD_STUB_COUNTER" 2>/dev/null); i="${i:-0}"
# shellcheck disable=SC2206
codes=($RD_CP_CODES)
code="${codes[$i]:-30}"
echo $((i + 1)) > "$RD_STUB_COUNTER"
if [ "$i" -eq 0 ] && [ -n "${RD_CP_WRITE:-}" ]; then
  for spec in $RD_CP_WRITE; do
    slug="${spec%%:*}"; n="${spec##*:}"; k=0
    while [ "$k" -lt "$n" ]; do
      k=$((k + 1)); printf 'worktree\tw%s\t사유\t복구\n' "$k"
    done | bash "$RD_CP_HELPER" write "$slug"
  done
fi
if [ "$code" -eq 0 ] && [ -n "${RD_AUTOPILOT_OUTCOME_FILE:-}" ]; then
  echo completed > "$RD_AUTOPILOT_OUTCOME_FILE"
  [ -n "${RD_CP_OUTCOME_EXTRA:-}" ] && printf '%s\n' "$RD_CP_OUTCOME_EXTRA" >> "$RD_AUTOPILOT_OUTCOME_FILE"
fi
exit "$code"
CPSTUBEOF
chmod +x "$CP_STUB"

# run_cp_case <이름> <기대 exit> <codes> [env...] — CP_SETUP 이 있으면 임시 저장소 안에서 먼저 eval 한다.
run_cp_case() {
  local name="$1" expect="$2" codes="$3"; shift 3
  local repo
  repo="$(mktemp -d "${TMP}/cprepo.XXXXXX")" || { echo "  FAIL [$name] mktemp"; fail=1; return 1; }
  local counter="${repo}.counter"; : > "$counter"
  local outcome="${repo}.outcome"; : > "$outcome"
  local out ec
  out=$( cd "$repo" && git init -q . && { [ -z "${CP_SETUP:-}" ] || eval "$CP_SETUP"; } &&
        env -u RD_AUTOPILOT_FR -u RD_AUTOPILOT_MODE -u RD_FINISH_POLICY \
        -u RD_RALPH_MAX_ITER -u RD_RALPH_NONPROGRESS_LIMIT -u RD_AUTOPILOT_COST_FILE "$@" \
        RD_CP_CODES="$codes" RD_STUB_COUNTER="$counter" RD_CP_HELPER="$CP_HELPER" \
        RD_AUTOPILOT_OUTCOME_FILE="$outcome" \
        RD_RALPH_WRAPPER_CMD="bash $CP_STUB" \
        bash "$DRAIN" 2>&1 ); ec=$?
  if [ "$ec" -ne "$expect" ]; then
    echo "  FAIL [$name] exit 기대 $expect, 실제 $ec"; echo "$out" | sed 's/^/    /'; fail=1
  else
    echo "  ok [$name] exit $ec"
  fi
  LAST_OUT="$out"
}

assert_not_contains() {
  case "$LAST_OUT" in
    *"$1"*) echo "  FAIL [not-contains] '$1' 있음"; echo "$LAST_OUT" | sed 's/^/    /'; fail=1 ;;
    *) echo "  ok [not-contains] $1" ;;
  esac
}

CP_SETUP=""
run_cp_case "T3-1 기록 없음" 0 "0 30";                       assert_not_contains "잔여(cleanup-pending)"
run_cp_case "T3-2 slug 별 항목 합" 0 "0 30" RD_CP_WRITE="sa:2 sb:1"
assert_contains "잔여(cleanup-pending): 3건 (sa 2건, sb 1건)"
CP_SETUP='printf "worktree\tw\tr\tc\n" | bash "$RD_CP_HELPER_SETUP" write old && touch -t 200001010000 "$(git rev-parse --path-format=absolute --git-common-dir)/rd-workflow/archive-cleanup-pending/old"'
CP_SETUP="export RD_CP_HELPER_SETUP='$CP_HELPER'; $CP_SETUP"
run_cp_case "T3-3 드레인 전 기록 제외" 0 "0 30";             assert_not_contains "잔여(cleanup-pending)"
CP_SETUP='mkdir -p "$(git rev-parse --path-format=absolute --git-common-dir)/rd-workflow" && : > "$(git rev-parse --path-format=absolute --git-common-dir)/rd-workflow/archive-cleanup-pending"'
run_cp_case "T3-4 조회 실패" 0 "0 30";                       assert_contains "잔여(cleanup-pending): 조회 실패"
CP_SETUP=""
run_cp_case "T3-5 기록 실패 보고" 0 "0 30" RD_CP_OUTCOME_EXTRA="cleanup-record-failed sx /r/x.md"
assert_contains "잔여(cleanup-pending): 기록 실패 1건 (sx — 기록 /r/x.md)"

# --- 실행 비용 합계 (spec D6) ---
run_case "비용 합계: 일부 누락·확인 불가" 0 "0 0 0 30" RD_STUB_COSTS="ok:0.5 ok:0.25 unk:x none"
assert_contains '실행 비용 합계: $0.7500 (정가 환산, 리뷰 도구 비용 제외) · wrapper 호출 4회 · 확인 불가 1회'
assert_contains '비용 기록 없는 호출 1회'
assert_contains '실제 비용은 더 큼'
run_case "비용 합계: 확인 불가만" 0 "30" RD_STUB_COSTS="unk:x"
assert_contains '실행 비용 합계: 확인 불가 — wrapper 호출 1회'
PRE="${TMP}/precost"; printf 'cost\tok\t9.000000\n' > "$PRE"
run_case "비용 합계: 호출자 파일은 시작 이후 줄만" 0 "0 30" RD_AUTOPILOT_COST_FILE="$PRE" RD_STUB_COSTS="ok:0.5 none"
assert_contains '$0.5000'
assert_not_contains '9.5'
if [ "$(wc -l < "$PRE" | tr -d ' ')" = "2" ]; then echo "  ok [cost] 호출자 파일 보존·덧붙임"; else echo "  FAIL [cost] 호출자 파일이 잘렸거나 변경됨"; fail=1; fi
run_case "비용 합계: 읽을 수 없는 경로" 0 "30" RD_AUTOPILOT_COST_FILE="${TMP}/nodir/x/cost" RD_STUB_COSTS="ok:0.5"
assert_contains '집계 불가'
assert_not_contains '$0'
run_case "비용 합계: 드레인 도중 기록 파일이 사라짐" 0 "0 30" RD_STUB_COSTS="ok:0.5 gone"
assert_contains '집계 불가 — 비용 기록 파일을 읽을 수 없음'
assert_not_contains '$0'

# --- RD_RALPH_SLUGS: 지정 목록 모드 (/fr do --headless 엔진) ---
# 관계 판정 stub — 호출마다 $RD_REL_DIR/<n>.out 을 내고 <n>.rc 가 있으면 그 코드로 끝낸다.
REL_STUB="${TMP}/rel_stub.sh"
cat > "$REL_STUB" <<'RELEOF'
#!/usr/bin/env bash
n=$(( $(cat "$RD_REL_DIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$RD_REL_DIR/n"
echo "$*" >> "$RD_REL_DIR/args"
cat "$RD_REL_DIR/$n.out" 2>/dev/null || printf 'queue-empty\n'
exit "$(cat "$RD_REL_DIR/$n.rc" 2>/dev/null || echo 0)"
RELEOF
slug_case() {
  # $1 이름 $2 기대 exit $3 wrapper codes, 나머지 env. 호출 전 REL_DIR 에 <n>.out 을 채운다.
  local name="$1" expect="$2" codes="$3"; shift 3
  run_case "$name" "$expect" "$codes" RD_RALPH_RELATIONS_CMD="bash $REL_STUB" RD_REL_DIR="$REL_DIR" "$@"
}
new_rel_dir() { REL_DIR="${TMP}/rel.$1"; mkdir -p "$REL_DIR"; }

new_rel_dir 1; printf 'select\t2026-01-01-b\n' > "$REL_DIR/1.out"; printf 'queue-empty\n' > "$REL_DIR/2.out"
SENV="${TMP}/slugenv1"; : > "$SENV"
slug_case "slugs_pick_passes_slug" 0 "0" RD_RALPH_SLUGS="b c" RD_FINISH_POLICY=push RD_STUB_ENVLOG="$SENV"
assert_contains "queue-empty (지정 목록 소진)"
if [ "$(head -n1 "$SENV")" = "FR=b MODE=A FINISH=push" ]; then echo "  ok [slugs] 첫 호출 FR=b MODE=A FINISH=push"; else echo "  FAIL [slugs] envlog: $(cat "$SENV")"; fail=1; fi
if grep -q -- '--slugs b c' "$REL_DIR/args"; then echo "  ok [slugs] --slugs 전달"; else echo "  FAIL [slugs] args: $(cat "$REL_DIR/args")"; fail=1; fi

new_rel_dir 2; printf 'queue-blocked\nb\t대기\t선행 FR 완료 후\n' > "$REL_DIR/1.out"
slug_case "slugs_queue_blocked" 0 "0" RD_RALPH_SLUGS="b"
assert_contains "queue-blocked"
assert_detail_in_summary "b	대기	선행 FR 완료 후"

new_rel_dir 3; printf 'unavailable\n-\t인덱스 없음\t확인\n' > "$REL_DIR/1.out"; echo 2 > "$REL_DIR/1.rc"
slug_case "slugs_unavailable" 1 "0" RD_RALPH_SLUGS="b"
assert_contains "관계 판정 불가"

# 완료(0)한 slug 는 다음 반복의 --slugs 에서 빠진다. stub 이 매번 같은 FR 을 골라도 wrapper 는 1회다.
new_rel_dir 4; for k in 1 2 3; do printf 'select\t2026-01-01-b\n' > "$REL_DIR/$k.out"; done
slug_case "slugs_done_not_reselected" 0 "0 0 0" RD_RALPH_SLUGS="b"
assert_invocations 1
assert_contains "queue-empty (지정 목록 소진)"
# blocked(20) 로 끝난 slug 도 빠지고, 남은 slug 만 다음 --slugs 로 넘긴다.
new_rel_dir 5; printf 'select\t2026-01-01-b\n' > "$REL_DIR/1.out"; printf 'queue-empty\n' > "$REL_DIR/2.out"
slug_case "slugs_blocked_excluded" 0 "20" RD_RALPH_SLUGS="b c"
if [ "$(sed -n 2p "$REL_DIR/args")" = "auto-pick --root . --slugs c" ]; then echo "  ok [slugs] blocked slug 제외 후 --slugs c"; else echo "  FAIL [slugs] args: $(cat "$REL_DIR/args")"; fail=1; fi

# 관계 판정 실패 요약에 stderr 마지막 줄을 붙인다.
new_rel_dir 6; printf 'unavailable\n' > "$REL_DIR/1.out"; echo 2 > "$REL_DIR/1.rc"
cat > "${TMP}/rel_err.sh" <<'ERREOF'
#!/usr/bin/env bash
echo "첫 줄" >&2; echo "fr_relations.sh: 마지막 오류 줄" >&2
exec bash "$RD_REL_STUB" "$@"
ERREOF
run_case "slugs_unavailable_stderr" 1 "0" RD_RALPH_SLUGS="b" RD_RALPH_RELATIONS_CMD="bash ${TMP}/rel_err.sh" RD_REL_STUB="$REL_STUB" RD_REL_DIR="$REL_DIR"
assert_contains "stderr: fr_relations.sh: 마지막 오류 줄"

# 프로젝트 경로에 공백이 있어도 기본 관계 판정(훅 미설정)이 실제 fr_relations.sh 로 돈다.
SP="${TMP}/with space"; mkdir -p "$SP/scripts/lifecycle" "$SP/proj/rd-workflow-workspace/backlog/items"
cp "${SCRIPT_DIR}/ralph_drain.sh" "${SCRIPT_DIR}/fr_relations.sh" "${SCRIPT_DIR}/_fr_status.sh" "${SCRIPT_DIR}/model_select.sh" "$SP/scripts/"
cp "${SCRIPT_DIR}/lifecycle/cleanup_pending.sh" "$SP/scripts/lifecycle/"
printf '# 2026-01-01 b\n- status: validated\n- kind: feature\n- summary: fixture\n' > "$SP/proj/rd-workflow-workspace/backlog/items/2026-01-01-b.md"
{ printf '## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 관계 | 상세 |\n|------|------|------|------|------|----------|------|------|\n'
  printf '| 2026-01-01 | b | 요약 | feature | validated | P1 | - | [상세](items/2026-01-01-b.md) |\n'; } > "$SP/proj/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
DRAIN_SAVED="$DRAIN"; DRAIN="$SP/scripts/ralph_drain.sh"; cd "$SP/proj" || exit 1
SENV3="${TMP}/slugenv3"; : > "$SENV3"
run_case "slugs_space_path_default_relations" 0 "0" RD_RALPH_SLUGS="b" RD_STUB_ENVLOG="$SENV3"
cd "$SCRIPT_DIR" || exit 1; DRAIN="$DRAIN_SAVED"
assert_contains "queue-empty (지정 목록 소진)"
if [ "$(cat "$SENV3")" = "FR=b MODE=A FINISH=merge" ]; then echo "  ok [slugs] 공백 경로에서 FR=b 선택"; else echo "  FAIL [slugs] envlog: $(cat "$SENV3")"; fail=1; fi

COUNTER_EMPTY="${TMP}/counter"
run_case "slugs_empty_set" 1 "0" RD_RALPH_SLUGS="" RD_RALPH_RELATIONS_CMD="bash $REL_STUB" RD_REL_DIR="$TMP"
assert_contains "RD_RALPH_SLUGS 가 비어 있습니다"
if [ "$LAST_INVOCATIONS" = "0" ]; then echo "  ok [slugs] 빈 목록 wrapper 호출 0회"; else echo "  FAIL [slugs] wrapper 호출 ${LAST_INVOCATIONS}회"; fail=1; fi

SENV2="${TMP}/slugenv2"; : > "$SENV2"
run_case "slugs_unset_keeps_auto" 0 "30" RD_STUB_ENVLOG="$SENV2"
if grep -q "FR=auto" "$SENV2"; then echo "  ok [slugs] 미설정은 FR=auto"; else echo "  FAIL [slugs] envlog: $(cat "$SENV2")"; fail=1; fi

# ------------------------------------------------------------
# 무인 세션 모델·effort
# ------------------------------------------------------------
hd_ok()   { echo "  ok [hl] $1"; }
hd_bad()  { echo "  FAIL [hl] $1 — ${2:-}"; fail=1; }
hd_chk()  { if [ "$2" = 0 ]; then hd_ok "$1"; else hd_bad "$1" "${3:-}"; fi; }   # hd_chk <설명> <rc 0=참> [상세]

HD_BIN="${TMP}/hdbin"; mkdir -p "$HD_BIN"
cat > "${HD_BIN}/claude" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\n' "${RD_FAKE_HELP-  --model <model>
  --effort <level>}"
  exit 0
fi
if [[ "${1:-}" == "-p" ]]; then
  [[ -n "${RD_FAKE_ARGS:-}" ]] && printf '%s\n' "$@" > "$RD_FAKE_ARGS"
  [[ -n "${RD_AUTOPILOT_OUTCOME_FILE:-}" ]] && printf 'queue-empty\n' > "$RD_AUTOPILOT_OUTCOME_FILE"
  printf '{"result":"ok"}\n'
  exit 0
fi
exit 0
FAKE
chmod +x "${HD_BIN}/claude"
HD_PYFAIL="${TMP}/hdpyfail"; mkdir -p "$HD_PYFAIL"
printf '#!/bin/sh\nexit 1\n' > "${HD_PYFAIL}/python3"; chmod +x "${HD_PYFAIL}/python3"
# jq 없는 PATH
HD_NOJQ="${TMP}/hdnojq"; mkdir -p "$HD_NOJQ"
for _t in bash awk grep sed cat dirname basename head tr env cut; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "${HD_NOJQ}/${_t}"
done
ln -sf "${HD_BIN}/claude" "${HD_NOJQ}/claude"

# 케이스 CWD(공백 없음)의 rd-workflow/scripts 를 루트 미러로 이어, 드레인 기본 호출이 실제 wrapper 에 닿게 한다.
HD_CWD="${TMP}/hdcwd"; mkdir -p "$HD_CWD/rd-workflow"; ln -s "$SCRIPT_DIR" "$HD_CWD/rd-workflow/scripts"
HD_N=0; HD_OUT=""; HD_RC=0; HD_ARGS=""
# hd_run <env 할당…> -- <드레인 인자…> : 실제 wrapper·가짜 claude 로 드레인을 돈다. 케이스마다 outcome·args 파일이 따로다.
hd_run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  HD_N=$((HD_N + 1)); HD_ARGS="${TMP}/hd-args-${HD_N}"; rm -f "$HD_ARGS"; HD_RC=0
  HD_OUT="$( cd "$HD_CWD" && env -u RD_AUTOPILOT_FR -u RD_AUTOPILOT_MODE -u RD_FINISH_POLICY -u RD_RALPH_SLUGS \
      -u RD_RALPH_WRAPPER_CMD -u RD_RALPH_RELATIONS_CMD -u RD_AUTOPILOT_COST_FILE \
      RD_AUTOPILOT_OUTCOME_FILE="${TMP}/hd-outcome-${HD_N}" RD_FAKE_ARGS="$HD_ARGS" RD_FR_WALL_MINUTES=0 \
      PATH="${HD_BIN}:${PATH}" ${envs[@]+"${envs[@]}"} \
      bash "$HD_CWD/rd-workflow/scripts/ralph_drain.sh" "$@" 2>&1 )" || HD_RC=$?
}
# 옵션이 정확히 한 번 나오면 바로 다음 줄 (없거나 두 번 이상이면 빈 값)
hd_arg_after() { awk -v o="$2" '$0 == o { c++; if (c == 1) getline v } END { if (c == 1) print v }' "$1" 2>/dev/null; }
hd_has() { printf '%s\n' "$HD_OUT" | grep -qxF -- "$1"; }          # 로그에 줄 전체가 있음
hd_in_summary() { printf '%s\n' "$HD_OUT" | awk '/---- ralph_drain 요약 ----/{f=1} f' | grep -qxF -- "$1"; }

# AC1·AC4 setsid / AC1 fallback
L='무인 세션 모델: sonnet (플래그 --model) · effort: high (플래그 --effort)'
hd_run RD_HEADLESS_CLAUDE_MODEL=haiku RD_HEADLESS_CLAUDE_EFFORT=low -- --model sonnet --effort high
hd_chk "AC1 setsid exit 0" "$([ "$HD_RC" = 0 ]; echo $?)" "rc=$HD_RC"
hd_chk "AC1 setsid --model" "$([ "$(hd_arg_after "$HD_ARGS" --model)" = sonnet ]; echo $?)" "$(tr '\n' ' ' < "$HD_ARGS" 2>/dev/null)"
hd_chk "AC1 setsid --effort" "$([ "$(hd_arg_after "$HD_ARGS" --effort)" = high ]; echo $?)" "$(tr '\n' ' ' < "$HD_ARGS" 2>/dev/null)"
hd_chk "AC1 드레인 표시 줄" "$(hd_has "ralph_drain: $L"; echo $?)" "$HD_OUT"
hd_chk "AC1 wrapper 표시 줄" "$(hd_has "autopilot_headless: $L"; echo $?)" "$HD_OUT"
hd_chk "AC4 요약 절 표시 줄" "$(hd_in_summary "$L"; echo $?)" "$HD_OUT"
hd_run RD_HEADLESS_CLAUDE_MODEL=haiku RD_HEADLESS_CLAUDE_EFFORT=low PATH="${HD_PYFAIL}:${HD_BIN}:${PATH}" -- --model sonnet --effort high
hd_chk "AC1 fallback --model" "$([ "$(hd_arg_after "$HD_ARGS" --model)" = sonnet ]; echo $?)" "$HD_OUT"
hd_chk "AC1 fallback --effort" "$([ "$(hd_arg_after "$HD_ARGS" --effort)" = high ]; echo $?)" "$HD_OUT"
hd_chk "AC1 fallback 경로 확인(세션 추적 불가)" "$([[ "$HD_OUT" == *"세션 추적 불가"* ]]; echo $?)"

# AC8: ultra → max, 변환 경고는 드레인 해석에서 한 번만
hd_run RD_HEADLESS_CLAUDE_MODEL=haiku RD_HEADLESS_CLAUDE_EFFORT=low -- --model sonnet --effort ultra
hd_chk "AC8 --effort max" "$([ "$(hd_arg_after "$HD_ARGS" --effort)" = max ]; echo $?)" "$(tr '\n' ' ' < "$HD_ARGS" 2>/dev/null)"
hd_chk "AC8 변환 경고 1회" "$([ "$(printf '%s\n' "$HD_OUT" | grep -cF "'max' 로 바꿉니다")" = 1 ]; echo $?)" "$HD_OUT"

# AC3: default 지정·미설정은 인자 없음, wrapper 표시 줄은 구분 유지
printf '{"headless":{"claude":{"model":"default","effort":"default"}}}' > "${TMP}/hd-default.json"
hd_run RD_MODELS_CONFIG="${TMP}/hd-default.json" --
hd_chk "AC3 default args 파일에 -p" "$([ -f "$HD_ARGS" ] && grep -qxF -- -p "$HD_ARGS"; echo $?)" "$HD_OUT"
hd_chk "AC3 default --model·--effort 없음" "$(! grep -qxF -- --model "$HD_ARGS" && ! grep -qxF -- --effort "$HD_ARGS"; echo $?)"
hd_chk "AC3 default wrapper 줄 전체" "$(hd_has 'autopilot_headless: 무인 세션 모델: CLI 기본값 (default 지정, models.json headless.claude.model) · effort: CLI 기본값 (default 지정, models.json headless.claude.effort)'; echo $?)" "$HD_OUT"
hd_run --
hd_chk "AC3 미설정 args 파일에 -p" "$([ -f "$HD_ARGS" ] && grep -qxF -- -p "$HD_ARGS"; echo $?)" "$HD_OUT"
hd_chk "AC3 미설정 --model·--effort 없음" "$(! grep -qxF -- --model "$HD_ARGS" && ! grep -qxF -- --effort "$HD_ARGS"; echo $?)"
hd_chk "AC3 미설정 wrapper 줄 전체" "$(hd_has 'autopilot_headless: 무인 세션 모델: CLI 기본값 (미설정) · effort: CLI 기본값 (미설정)'; echo $?)" "$HD_OUT"

# AC5·AC9: 회차 시작에 한 번 해석해 고정, 설정 줄이 wrapper 첫 진입보다 먼저
HD_CONF="${TMP}/hd-run.json"; printf '{"headless":{"claude":{"model":"opus"}}}' > "$HD_CONF"
HD_LL="${TMP}/hd-hllog"; rm -f "$HD_LL"
run_case "hl_fixed_per_round" 0 "0 30" RD_MODELS_CONFIG="$HD_CONF" RD_STUB_HLLOG="$HD_LL" \
  RD_STUB_MUTATE="printf '{\"headless\":{\"claude\":{\"model\":\"haiku\"}}}' > $HD_CONF"
hd_chk "AC5 wrapper 두 번 호출" "$([ "$(wc -l < "$HD_LL" | tr -d ' ')" = 2 ]; echo $?)" "$(cat "$HD_LL" 2>/dev/null)"
hd_chk "AC5 두 줄 모두 HLM=opus|" "$([ "$(grep -c '^HLM=opus|' "$HD_LL")" = 2 ]; echo $?)" "$(cat "$HD_LL" 2>/dev/null)"
hd_chk "AC5 두 줄의 HLL 동일" "$([ "$(sed 's/.*|HLL=//' "$HD_LL" | sort -u | wc -l | tr -d ' ')" = 1 ]; echo $?)" "$(cat "$HD_LL" 2>/dev/null)"
assert_contains "opus (models.json headless.claude.model)"
hd_chk "AC5 요약 줄에 opus" "$(summary_section | grep -qF 'opus (models.json headless.claude.model)'; echo $?)"
L_SET="$(printf '%s\n' "$LAST_OUT" | grep -n 'ralph_drain: 무인 세션 모델:' | head -n1 | cut -d: -f1)"
L_ENTER="$(printf '%s\n' "$LAST_OUT" | grep -n 'STUB-ENTER 1' | head -n1 | cut -d: -f1)"
hd_chk "AC9 설정 줄이 wrapper 진입보다 먼저" "$([ -n "$L_SET" ] && [ -n "$L_ENTER" ] && [ "$L_SET" -lt "$L_ENTER" ]; echo $?)" "set=$L_SET enter=$L_ENTER"

# AC6: strict 실패는 wrapper 를 부르기 전에 멈춘다
HD_FAILMSG='ralph_drain: 무인 세션 모델·effort 설정을 적용할 수 없습니다 — 위 이유를 고친 뒤 다시 실행하십시오'
hd_strict_fail() {  # hd_strict_fail <이름> <포함 문자열…> — 직전 run_case 결과 점검
  local name="$1"; shift; local s
  hd_chk "$name HLLOG 없음" "$([ ! -e "$HD_LL" ]; echo $?)"
  hd_chk "$name 마지막 줄" "$([ "$(printf '%s\n' "$LAST_OUT" | tail -n1)" = "$HD_FAILMSG" ]; echo $?)" "$LAST_OUT"
  for s in "$@"; do hd_chk "$name 포함 [$s]" "$([[ "$LAST_OUT" == *"$s"* ]]; echo $?)" "$LAST_OUT"; done
}
rm -f "$HD_LL"; DRAIN_ARGS=(--model gpt-5)
run_case "hl_fail_a_flag_model" 1 "30" RD_STUB_HLLOG="$HD_LL"; DRAIN_ARGS=()
hd_strict_fail "AC6(a)" "플래그 --model" "opus"
rm -f "$HD_LL"
run_case "hl_fail_a2_env_model" 1 "30" RD_STUB_HLLOG="$HD_LL" RD_HEADLESS_CLAUDE_MODEL=gpt-5
hd_strict_fail "AC6(a2)" "환경 변수 RD_HEADLESS_CLAUDE_MODEL" "opus"
printf '{"headless":{"claude":{"effort":"turbo"}}}' > "${TMP}/hd-bad-effort.json"; rm -f "$HD_LL"
run_case "hl_fail_b_file_effort" 1 "30" RD_STUB_HLLOG="$HD_LL" RD_MODELS_CONFIG="${TMP}/hd-bad-effort.json"
hd_strict_fail "AC6(b)" "${TMP}/hd-bad-effort.json" "headless.claude.effort" "low"
printf '{"headless":' > "${TMP}/hd-bad-syntax.json"; rm -f "$HD_LL"
run_case "hl_fail_c_syntax" 1 "30" RD_STUB_HLLOG="$HD_LL" RD_MODELS_CONFIG="${TMP}/hd-bad-syntax.json"
hd_strict_fail "AC6(c)" "파일을 고치십시오"
printf '{"headless":{"claude":{"model":"opus"}}}' > "${TMP}/hd-nojq.json"; rm -f "$HD_LL"
run_case "hl_fail_d_nojq" 1 "30" RD_STUB_HLLOG="$HD_LL" RD_MODELS_CONFIG="${TMP}/hd-nojq.json" PATH="$HD_NOJQ"
hd_strict_fail "AC6(d)" "brew install jq"

# AC7: CLI 가 --effort 를 모르면 strict 실패
rm -f "$HD_LL"; DRAIN_ARGS=(--effort high)
run_case "hl_fail_ac7_cli" 1 "30" RD_STUB_HLLOG="$HD_LL" RD_FAKE_HELP="  --model <model>" PATH="${HD_BIN}:${PATH}"; DRAIN_ARGS=()
hd_chk "AC7 HLLOG 없음" "$([ ! -e "$HD_LL" ]; echo $?)"
assert_contains "claude update"

# 인자 오류
hd_arg_case() {  # hd_arg_case <이름> <드레인 인자…>
  local name="$1"; shift
  rm -f "$HD_LL"; DRAIN_ARGS=("$@")
  run_case "hl_args_${name}" 1 "30" RD_STUB_HLLOG="$HD_LL"; DRAIN_ARGS=()
  hd_chk "인자 ${name} 사용법" "$([[ "$LAST_OUT" == *"사용법"* ]]; echo $?)" "$LAST_OUT"
  hd_chk "인자 ${name} HLLOG 없음" "$([ ! -e "$HD_LL" ]; echo $?)"
}
hd_arg_case "값없음" --model
hd_arg_case "중복" --model sonnet --model haiku
hd_arg_case "모르는인자" --bogus

if [ "$fail" -ne 0 ]; then echo "test_ralph_drain: FAIL"; exit 1; fi
echo "test_ralph_drain: PASS"
