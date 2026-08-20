#!/usr/bin/env bash
# test_self_test_smoke.sh — self_test.sh 진입점(smoke/full·dry-run·폴백) 계약 테스트입니다.
# 대부분의 케이스는 전체 스텝을 실행하지 않고 dry-run 출력만 검증하므로 빠릅니다.
# 마지막 두 케이스는 최소 fixture(스텝 3~4개)에서 **실제 실행 경로**를 돌려 봅니다.
#
# 이 스위트는 self_test.sh 의 smoke 진입점을 fixture 트리에서 실행하므로,
# 실질적으로 rd-workflow/scripts/_smoke_common.sh 의 판정 로직까지 함께 검증합니다.
# (폐포 판정이 self_test.sh 를 잘라내 이 의존이 자동으로 잡히지 않으므로 명시합니다 —
#  이 한 줄이 없으면 `_smoke_common.sh` 만 고친 smoke 실행에서 이 스위트가 스킵됩니다.
#  실측 2026-08-19: 명시 전 스킵 25 / 실행 24, 이 스텝은 스킵 예정에 들어갔습니다.)
#
# ⚠️ fixture 스크립트 이름에는 `_zzfx` 접미사를 붙입니다 — 이 파일도 full 스텝이라 본문에
# 박힌 이름이 "그 이름의 실제 인프라 파일은 이미 커버됨" 으로 오판되어 무매핑 full 폴백을
# 잠식합니다. 접두사로는 막히지 않는 이유는 `test_smoke_common.sh` 상단 주석에 있습니다.
# 실제 인프라 파일명(`self_test.sh`·`test_guard_state.sh`·`test_state_common.sh`)은
# fixture 트리의 그 파일을 가리키므로 바꾸지 않습니다.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${SCRIPT_DIR}/self_test.sh"
FAIL=0
ok() { echo "ok: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { # has <설명> <출력> <기대문자열>
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1 (출력에 '$3' 없음)"; fi
}

# 1) 잘못된 인자 → 사용법 + exit 1
out="$(bash "$SELF" bogus 2>&1)"; rc=$?
if [[ "$rc" == "1" ]]; then ok "잘못된 모드 인자 exit 1"; else no "잘못된 모드 인자 exit $rc"; fi
has "사용법 안내 출력" "$out" "사용법:"

# 1b) 인자 2개 이상 → 사용법 + exit 1.
# `smoke --dry-run` 은 사람이 실제로 치는 형태입니다. 남는 인자를 무시하면 목록만 볼
# 생각으로 친 명령이 조용히 전수 실행으로 떨어지므로, 무시하지 않는 것을 고정합니다.
out="$(bash "$SELF" smoke --dry-run 2>&1)"; rc=$?
if [[ "$rc" == "1" ]]; then ok "잉여 인자 exit 1"; else no "잉여 인자 exit $rc (조용히 실행됐을 수 있습니다)"; fi
has "잉여 인자 사유 출력" "$out" "인자는 하나만"
has "dry-run 이 환경변수임을 안내" "$out" "RD_SELFTEST_SMOKE_DRYRUN=1"

# 2) dry-run smoke — mode 표시와 full 안내가 나옵니다
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$SELF" 2>&1)"; rc=$?
if [[ "$rc" == "0" ]]; then ok "dry-run smoke exit 0"; else no "dry-run smoke exit $rc"; fi
has "mode 표시" "$out" "mode: smoke"
has "full 실행 안내" "$out" "bash rd-workflow/scripts/self_test.sh full"

# 3) dry-run full — 스킵이 없습니다
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$SELF" full 2>&1)"; rc=$?
if [[ "$rc" == "0" ]]; then ok "dry-run full exit 0"; else no "dry-run full exit $rc"; fi
has "full mode 표시" "$out" "mode: full"
if printf '%s' "$out" | grep -qF "스킵 예정 스텝"; then no "full 인데 스킵 예정 블록이 나옵니다"; else ok "full 은 스킵 블록 없음"; fi
# dry-run 종료 블록의 스킵 요약에도 모드 가드가 있어야 합니다. 없으면 full 실행인데
# "smoke 스킵 요약" 이 나와 사용자가 축소 실행으로 오인합니다.
if printf '%s' "$out" | grep -qF "smoke 스킵 요약"; then no "full 인데 smoke 스킵 요약이 나옵니다"; else ok "full 은 스킵 요약 없음"; fi

# 4) self_test.sh 자기 변경 → full 폴백. 격리 fixture 저장소에서 확인합니다.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FX="$TMP/repo"
mkdir -p "$FX/rd-workflow"
cp -R "${SCRIPT_DIR}" "$FX/rd-workflow/scripts"
git -C "$FX" init -q .
git -C "$FX" config user.email t@t.t; git -C "$FX" config user.name t
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm init >/dev/null 2>&1
printf '\n# 변경 표시\n' >> "$FX/rd-workflow/scripts/self_test.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
has "self_test.sh 자기 변경 → full 폴백" "$out" "full 폴백"
has "폴백 사유 표시" "$out" "self_test.sh 자신이 변경"

# 5) 변경 0건 → full 폴백
git -C "$FX" checkout -- . >/dev/null 2>&1
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
has "변경 0건 → full 폴백" "$out" "변경 파일이 없습니다"

# 5b) 판정 엔진 자신(_smoke_common.sh) 변경 → full 폴백.
#
# 이 특례가 없으면 **깨졌을지 모르는 엔진이 자기 실행의 감축 범위를 스스로 결정**합니다.
# 엔진은 폐포에서 잘려 나가는 오케스트레이터와 달리 거의 모든 스텝의 폐포에 들어가므로
# 스킵이 줄기는 하지만 0 이 되지는 않습니다 (실측: 스킵 24 / 실행 26 으로 축소된 채 통과).
# 특례가 조용히 빠지는 것을 이 단언이 막습니다.
printf '\n# 변경 표시\n' >> "$FX/rd-workflow/scripts/_smoke_common.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
has "_smoke_common.sh 자기 변경 → full 폴백" "$out" "full 폴백"
has "폴백 사유가 판정 엔진을 지목" "$out" "_smoke_common.sh 자신이 변경"
if printf '%s' "$out" | grep -qF "스킵 예정 스텝"; then
  no "판정 엔진이 바뀌었는데 smoke 가 축소 실행으로 진행했습니다"
else
  ok "판정 엔진 변경 시 스킵 예정 블록 없음 (전수 실행)"
fi
git -C "$FX" checkout -- . >/dev/null 2>&1

# 6) git 저장소 밖(수집 실패) → full 폴백
NG="$TMP/norepo"; mkdir -p "$NG/rd-workflow"
cp -R "${SCRIPT_DIR}" "$NG/rd-workflow/scripts"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$NG/rd-workflow/scripts/self_test.sh" 2>&1)"
# `full 폴백` 문자열만 보면 안 됩니다 — 이 시나리오에서는 수집 실패 시 배열이 비어
# **바로 다음 "변경 0건" 분기가 대신 폴백**하므로, 수집 실패 분기를 통째로 무력화해도
# 문자열이 나옵니다. 어느 분기가 걸렸는지 사유로 못박습니다.
has "변경 파일 수집 실패 → full 폴백" "$out" "변경 파일 수집에 실패했습니다"

# 6b) 인식 불가 status 가 섞이면 **부분 수집으로 진행하지 않고** full 폴백합니다.
#
# `smoke_collect_changed_files` 는 인식 못 하는 status 를 만나면 그 앞까지 이미 배열에
# 담은 채로 return 1 합니다. 그래서 수집 실패 분기가 없으면 "정상 파일만 담긴 부분 수집"
# 상태로 smoke 가 진행하고, 유실된 파일과 관련된 스텝을 검사하지 않고 통과시킵니다.
# 여기서 검증하려는 것은 "**하나라도 인식 못 하면 부분 수집으로 진행하지 않는다**" 입니다.
# 정상 ` M` 하나(hooks/…)를 먼저 두고, 경로 정렬상 그 뒤에 오는 파일을 symlink 로 바꿔
# ` T`(typechange) 를 만듭니다 — 앞의 ` M` 은 이미 수집된 뒤라야 부분 수집 재현이 됩니다.
printf '\n# 무관 변경\n' >> "$FX/rd-workflow/scripts/hooks/test_guard_state.sh"
rm -f "$FX/rd-workflow/scripts/test_state_common.sh"
ln -s /dev/null "$FX/rd-workflow/scripts/test_state_common.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
has "인식 불가 status 혼재 → 부분 수집 없이 full 폴백" "$out" "변경 파일 수집에 실패했습니다"
if printf '%s' "$out" | grep -qF "스킵 예정 스텝"; then
  no "부분 수집 상태로 smoke 가 진행했습니다 (스킵 예정 블록 출력됨)"
else
  ok "부분 수집 상태로 스킵을 계산하지 않음"
fi
rm -f "$FX/rd-workflow/scripts/test_state_common.sh"
git -C "$FX" checkout -- . >/dev/null 2>&1

# 7) 무관한 파일 1개만 수정 → 스킵이 1개 이상 생깁니다 (성공 경로)
printf '\n# 무관 변경\n' >> "$FX/rd-workflow/scripts/hooks/test_guard_state.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
skipped="$(printf '%s' "$out" | sed -n '/스킵 예정 스텝/,/전체 검증:/p' | grep -c '^    - ' || true)"
if [[ -n "$skipped" && "$skipped" -gt 0 ]]; then
  ok "단일 파일 수정 시 스킵 발생 (${skipped}개)"
else
  no "단일 파일 수정인데 스킵이 0개입니다"
fi
# 스킵 목록이 **첫 스텝 실행 전**에 나와야 합니다 (spec §5.6).
first_step_line="$(printf '%s' "$out" | grep -n '^== 실행 예정 스텝' | head -1 | cut -d: -f1)"
skip_line="$(printf '%s' "$out" | grep -n '스킵 예정 스텝' | head -1 | cut -d: -f1)"
if [[ -n "$skip_line" && -n "$first_step_line" && "$skip_line" -lt "$first_step_line" ]]; then
  ok "스킵 목록이 스텝 목록보다 먼저 출력됨"
else
  no "스킵 목록이 시작 시점에 출력되지 않습니다"
fi
# 위 순서 단언은 dry-run 출력만 봅니다. 그런데 `== 실행 예정 스텝` 은 dry-run 종료 블록이
# **맨 마지막에** 찍는 헤더이고 dry-run 에서는 run_step 이 아무 출력도 내지 않으므로,
# 가시성 블록을 마지막 run_step 뒤로 옮겨도 저 단언은 그대로 통과합니다. spec §5.6 이
# 요구하는 것은 "첫 스텝 **실행 전**" 이므로, 소스상 **배치 불변식**으로도 못박습니다 —
# 구현 로직의 복사가 아니라 위치 계약 자체를 검사하는 것입니다.
mode_line="$(grep -n '^echo "mode: ' "$SELF" | head -1 | cut -d: -f1)"
first_run_step_line="$(grep -n '^run_step ' "$SELF" | head -1 | cut -d: -f1)"
if [[ -n "$mode_line" && -n "$first_run_step_line" && "$mode_line" -lt "$first_run_step_line" ]]; then
  ok "가시성 블록이 소스상 첫 run_step 앞에 있음 (${mode_line} < ${first_run_step_line})"
else
  no "가시성 블록이 첫 run_step 앞에 있지 않습니다 (mode=${mode_line:-없음}, run_step=${first_run_step_line:-없음})"
fi
# "실행 예정" 섹션만 잘라서 확인합니다 — 스킵 목록에도 같은 이름이 있을 수 있어
# 전체 출력 grep 으로는 실행/스킵을 구분하지 못합니다.
planned="$(printf '%s' "$out" | sed -n '/== 실행 예정 스텝/,$p')"
has "대상 스텝은 실행 예정" "$planned" "guard state fixture (test_guard_state.sh)"

# 8) 어떤 스텝과도 연결되지 않는 새 인프라 파일 → full 폴백
#
# ⚠️ 파일명을 **동적으로** 만듭니다. 이 파일(`test_self_test_smoke.sh`) 자신이 full 스텝으로
# 등록돼 있고, 폐포 판정은 "변경 파일의 basename 이 폐포 구성원 본문에 등장하면 관련 있음"
# 이므로, 프로브 이름을 리터럴로 박으면 **이 파일 본문이 그 이름을 담고 있다는 이유만으로**
# 커버된 것으로 오판됩니다 — 그러면 "어떤 스텝도 다루지 않는 새 파일" 이라는 이 케이스의
# 전제가 깨져 단언이 무의미해집니다. 본문에는 `$$` 가 전개되지 않은 형태로만 남으므로
# 실제 파일명과 겹치지 않습니다.
git -C "$FX" checkout -- . >/dev/null 2>&1
probe="unmapped_probe_$$.sh"
printf 'echo hi\n' > "$FX/rd-workflow/scripts/$probe"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
has "무매핑 인프라 파일 → full 폴백" "$out" "어떤 스텝과도 연결되지 않는 인프라 변경"
rm -f "$FX/rd-workflow/scripts/$probe"

# 9) 정본(_ROOT_FILES) 경로만 변경돼도 관련 스텝을 찾습니다
mkdir -p "$FX/_ROOT_FILES/rd-workflow/scripts/hooks"
cp "$FX/rd-workflow/scripts/hooks/test_guard_state.sh" \
   "$FX/_ROOT_FILES/rd-workflow/scripts/hooks/test_guard_state.sh"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm canonical >/dev/null 2>&1
printf '\n# 정본만 변경\n' >> "$FX/_ROOT_FILES/rd-workflow/scripts/hooks/test_guard_state.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
planned="$(printf '%s' "$out" | sed -n '/== 실행 예정 스텝/,$p')"
has "정본만 변경돼도 대상 스텝이 실행 예정" "$planned" "guard state fixture (test_guard_state.sh)"
git -C "$FX" checkout -- . >/dev/null 2>&1

# 10) run_step 정적 추출이 실제 호출 수와 어긋나면 full 폴백합니다 (spec §5.3 preflight 역할 3)
#
# 스텝 판정은 **호출 순번**을 키로 씁니다. 그래서 추출이 실제 호출과 한 건이라도
# 어긋나면 순번이 밀려 **관련 있는 스텝이 무관한 스텝의 판정을 물려받습니다** — 거짓
# 통과의 직행 경로입니다. `run_step consumer "설명" ...` 형식을 벗어난 호출(설명을 변수로 넘기는
# 등)이 그 상황을 만들므로, 그런 줄을 하나 심어 폴백이 실제로 걸리는지 봅니다.
#
# 어긋난 self_test.sh 를 **커밋해** 워킹트리 변경에서 빼는 것이 요점입니다. 그러지 않으면
# 앞선 "self_test.sh 자신이 변경됨" 특례가 먼저 걸려 이 분기에 도달하지 못합니다.
#
# ⚠️ **이 케이스는 fixture 를 커밋하므로 반드시 원복해야 합니다.** `git checkout -- .` 로는
# 커밋된 변경이 되돌아가지 않아, 원복하지 않으면 **뒤에 오는 모든 케이스가 영구히
# `extracted != actual` → full 폴백 상태**에서 돕니다. full 폴백 아래에서는 모든 스텝이
# 실행 예정이 되므로 "특정 스텝이 실행 예정인가" 류의 단언이 무조건 통과하는 빈 껍데기가
# 됩니다. 케이스를 뒤에 추가하는 사람이 이 순서를 깨면 드러나도록 아래에서 로그를
# 케이스 9 시점과 대조해 단언합니다.
fx_log_before_case10="$(git -C "$FX" log --oneline)"
printf '\nSTEP_DESC="변수로 넘긴 설명"\nrun_step $STEP_DESC true\n' \
  >> "$FX/rd-workflow/scripts/self_test.sh"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm mismatched-step >/dev/null 2>&1
printf '\n# 무관 변경\n' >> "$FX/rd-workflow/scripts/hooks/test_guard_state.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
has "추출 수 불일치 → full 폴백" "$out" "full 폴백"
has "추출 수 불일치 사유 표시" "$out" "실제 호출 수"
# fixture 원복: 위에서 만든 커밋을 되돌립니다. `$FX` 는 이 파일이 mktemp -d 로 만든
# **테스트 전용 임시 저장소**이며 저장소 본체가 아니므로 reset --hard 가 안전합니다.
# 경로가 그 임시 디렉터리 안이라는 것을 실행 시점에도 확인한 뒤에만 수행합니다.
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard HEAD~1 >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case10" ]]; then
  ok "케이스 10 이후 fixture 이력이 케이스 9 시점으로 원복됨"
else
  no "케이스 10 이 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 항상 full 폴백합니다)"
fi

# 11) preflight 순번과 실제 run_step 호출 순번이 1:1 대응하고, 스킵이 **기록과 함께** 되어야 합니다.
#
# 두 가지를 함께 봅니다 — 어느 하나만으로는 잡히지 않는 결함이 서로 다릅니다.
#   (a) 스킵 예정 + 실행 예정 = 전체 스텝 수. 순번이 어긋나면(예: STEP_INDEX 증가 누락)
#       스킵이 아예 안 걸리거나 엉뚱한 스텝에 걸려 합이 깨집니다.
#   (b) 실제 기록된 스킵 수 = 스킵 예정 수. 스킵하면서 기록만 빠뜨리면 (a) 는 그대로
#       성립하는데 사용자에게는 "스킵 0건" 으로 보입니다 — 검증이 조용히 축소되는
#       가장 위험한 형태이므로 별도 단언으로 못박습니다.
# 폴백 상태에서는 건수 표시가 아예 나오지 않아 파싱이 비고, 그때는 첫 분기가 실패시킵니다.
printf '\n# 무관 변경 3\n' >> "$FX/rd-workflow/scripts/hooks/test_guard_state.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
n_skip="$(printf '%s' "$out" | sed -n 's/^  스킵 예정 스텝 (\([0-9]*\)개).*/\1/p' | head -1)"
n_plan="$(printf '%s' "$out" | sed -n 's/^== 실행 예정 스텝 (\([0-9]*\)개).*/\1/p' | head -1)"
n_done="$(printf '%s' "$out" | sed -n 's/^실제 스킵된 스텝 (\([0-9]*\)개).*/\1/p' | head -1)"
n_all="$(grep -c '^run_step ' "$FX/rd-workflow/scripts/self_test.sh")"
if [[ -z "$n_skip" || -z "$n_plan" || -z "$n_done" ]]; then
  no "스킵/실행 건수 표시를 읽지 못했습니다 (예정=${n_skip:-없음}, 실행=${n_plan:-없음}, 실제=${n_done:-없음})"
elif [[ "$((n_skip + n_plan))" == "$n_all" ]]; then
  ok "스킵 예정 + 실행 예정 = 전체 스텝 수 (${n_skip} + ${n_plan} = ${n_all})"
else
  no "스킵 예정 + 실행 예정(${n_skip} + ${n_plan})이 전체 스텝 수(${n_all})와 다릅니다 (순번 대응이 깨졌습니다)"
fi
if [[ -n "$n_done" && -n "$n_skip" && "$n_done" == "$n_skip" ]]; then
  ok "실제 스킵 기록 수가 스킵 예정 수와 일치 (${n_done}개)"
else
  no "스킵 예정 ${n_skip:-?}개인데 실제 기록된 스킵은 ${n_done:-없음}개입니다 (스킵을 기록하지 않으면 사용자에게 축소가 보이지 않습니다)"
fi
git -C "$FX" checkout -- . >/dev/null 2>&1

# 12) 설명이 같은 두 스텝 중 하나만 무관하면, 관련 있는 쪽은 그대로 실행되어야 합니다.
#
# 스텝 식별을 순번에서 설명 문자열로 되돌리면 같은 이름의 두 스텝이 한 덩어리로 묶여
# 관련 있는 쪽까지 스킵됩니다 — 관련 파일을 고쳤는데 그 검증이 빠지는 거짓 통과입니다.
#
# ⚠️ 이 케이스는 fixture 를 커밋합니다 (케이스 10 과 같은 이유 — 커밋하지 않으면
# "self_test.sh 자신이 변경됨" 특례가 먼저 걸려 이 분기에 도달하지 못합니다). 그래서
# 케이스 10 과 같은 방식으로 아래에서 **반드시 원복**하고 이력을 대조합니다. 뒤에
# 케이스를 붙이는 사람이 이 순서를 깨면 그 단언에서 드러납니다.
fx_log_before_case12="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
printf '#!/usr/bin/env bash\necho related\n' > "$FX/rd-workflow/scripts/dup_related_zzfx.sh"
printf '#!/usr/bin/env bash\necho unrelated\n' > "$FX/rd-workflow/scripts/dup_unrelated_zzfx.sh"
# 두 스텝을 **첫 run_step 바로 뒤**에 끼워 넣습니다. 파일 끝에 append 하면 최종 판정의
# `exit` 뒤라 정적 추출에는 잡히지만 런타임에는 도달하지 못해, 스킵도 실행도 되지 않는
# 유령 스텝이 됩니다 (그러면 이 케이스가 아무것도 관측하지 못합니다).
dup_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$dup_at" "$fx_self"
  printf 'run_step consumer "중복 설명 스텝" bash "${SCRIPT_DIR}/dup_related_zzfx.sh"\n'
  printf 'run_step consumer "중복 설명 스텝" bash "${SCRIPT_DIR}/dup_unrelated_zzfx.sh"\n'
  tail -n "+$((dup_at + 1))" "$fx_self"
} > "$TMP/self_test_dup_zzfx.sh"
mv "$TMP/self_test_dup_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm dup >/dev/null 2>&1
# dup_related_zzfx.sh 만 변경 → 그 스텝은 실행, 같은 이름의 다른 스텝은 스킵되어야 합니다.
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/dup_related_zzfx.sh"
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1)"
# full 폴백이면 모든 스텝이 실행 예정이 되어 아래 단언이 무조건 통과합니다 — 먼저 막습니다.
if printf '%s' "$out" | grep -qF "full 폴백"; then
  no "중복 설명 케이스가 full 폴백 상태에서 돌았습니다 (아래 단언이 무의미해집니다)"
else
  ok "중복 설명 케이스가 smoke 정상 판정으로 돌았음"
fi
planned="$(printf '%s' "$out" | sed -n '/== 실행 예정 스텝/,$p')"
if printf '%s' "$planned" | grep -qF "중복 설명 스텝"; then
  ok "설명이 같아도 관련 스텝은 실행 예정에 남음"
else
  no "설명이 같은 스텝이 통째로 스킵되었습니다 (순번 식별 회귀)"
fi
# 실제로 스킵된 쪽은 정확히 1건이어야 합니다 (설명 식별로 되돌아가면 2건이 됩니다).
dup_skipped="$(printf '%s' "$out" | sed -n '/== smoke 스킵 요약/,/== 실행 예정 스텝/p' | grep -c '중복 설명 스텝' || true)"
if [[ "$dup_skipped" == "1" ]]; then
  ok "같은 설명 중 무관한 1건만 실제로 스킵됨"
else
  no "같은 설명 스텝의 실제 스킵이 ${dup_skipped}건입니다 (1건이어야 합니다)"
fi
# fixture 원복: 위에서 만든 커밋을 되돌립니다. `$FX` 는 이 파일이 mktemp -d 로 만든
# **테스트 전용 임시 저장소**이며 저장소 본체가 아니므로 reset --hard 가 안전합니다.
# 경로가 그 임시 디렉터리 안이라는 것을 실행 시점에도 확인한 뒤에만 수행합니다.
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard HEAD~1 >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case12" ]]; then
  ok "케이스 12 이후 fixture 이력이 케이스 11 시점으로 원복됨"
else
  no "케이스 12 가 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 항상 full 폴백합니다)"
fi

# 13) **실제(비 dry-run) 실행 경로** — 스킵 판정을 받은 스텝이 정말로 실행되지 않아야 합니다.
#
# 위 12개 케이스는 전부 `RD_SELFTEST_SMOKE_DRYRUN=1` 이라, 이 기능의 유일한 새 기여인
# "실제로 건너뛴다" 를 어떤 단언도 지키지 않습니다 — Task 4 리뷰의 돌연변이 R1(실 경로
# 스킵 요약 호출 삭제)·R2(실 경로에서만 스킵 기록 누락)·R4(실 경로 모드 가드 제거)가
# 정확히 그 빈틈에서 살아남았습니다.
#
# 정본 47스텝을 실제로 돌리면 10분이 넘으므로, fixture 의 `self_test.sh` 에서 **최상위
# `run_step` 줄만** 3건(bash 2건 + inline checker 1건)으로 갈아 끼운 최소 트리를 만들어
# 1초 안에 관측합니다. 판정 로직·가시성 블록·스킵 요약·모드 가드는 정본 그대로 남으므로
# 검사 대상이 축소되지 않습니다.
#
# 두 가지를 반드시 맞춰야 합니다.
#   (a) 정적 추출 수 == 실제 `run_step` 호출 수. 어긋나면 추출 fail-safe 가 full 폴백을
#       걸어 이 케이스가 아무것도 관측하지 못하는 빈 껍데기가 됩니다 (케이스 10 의 함정).
#   (b) fixture 를 **커밋**해야 합니다. 그러지 않으면 "self_test.sh 자신이 변경됨" 특례가
#       먼저 걸려 full 폴백합니다. 그래서 케이스 10·12 와 같이 아래에서 반드시 원복합니다.
#
# `env -u RD_SELFTEST_SMOKE_DRYRUN` 로 떨어뜨립니다 — 이 케이스의 존재 이유가 "실제 실행
# 경로" 이므로, 환경에 그 변수가 export 된 상태에서 조용히 dry-run 으로 바뀌면 안 됩니다.
fx_base_sha13="$(git -C "$FX" rev-parse HEAD)"
fx_log_before_case13="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
fx_steps_before_case13="$(grep -c '^run_step ' "$fx_self")"
printf '#!/usr/bin/env bash\necho "zzfx-a-ran"\n' > "$FX/rd-workflow/scripts/mini_a_zzfx.sh"
printf '#!/usr/bin/env bash\necho "zzfx-b-ran"\n' > "$FX/rd-workflow/scripts/mini_b_zzfx.sh"
mini_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$((mini_at - 1))" "$fx_self"
  printf 'mini_inline_zzfx() { echo "zzfx-inline-ran"; }\n'
  printf 'run_step consumer "미니 A" bash "${SCRIPT_DIR}/mini_a_zzfx.sh"\n'
  printf 'run_step consumer "미니 B" bash "${SCRIPT_DIR}/mini_b_zzfx.sh"\n'
  printf 'run_step consumer "미니 인라인" mini_inline_zzfx\n'
  # 남은 본문에서 최상위 run_step 줄만 걷어냅니다 — 스킵 요약·스텝 요약·최종 판정은
  # 그대로 남아야 이 케이스가 정본의 출력 계약을 검사할 수 있습니다.
  tail -n "+$mini_at" "$fx_self" | sed '/^run_step /d'
} > "$TMP/mini_self_test_zzfx.sh"
mv "$TMP/mini_self_test_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm mini >/dev/null 2>&1
mini_extracted="$(grep -c '^run_step ' "$fx_self")"
if [[ "$mini_extracted" == "3" ]]; then
  ok "최소 fixture 의 최상위 run_step 이 3건"
else
  no "최소 fixture 의 최상위 run_step 이 ${mini_extracted}건입니다 (3건이어야 합니다)"
fi
# `미니 A` 의 대상만 변경 → 1번은 실행, 2번(`미니 B`)은 스킵, 3번(inline)은 항상 실행입니다.
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/mini_a_zzfx.sh"
mini_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/mini_err")"; mini_rc=$?
mini_err="$(cat "$TMP/mini_err")"
if [[ "$mini_rc" == "0" ]]; then ok "최소 fixture 실 실행 exit 0"; else no "최소 fixture 실 실행 exit ${mini_rc}"; fi
has "실 실행이 full 폴백이 아님" "$mini_out" "스킵 예정 스텝 (1개)"
has "실 실행 최종 판정 PASS" "$mini_out" "== self_test 결과: PASS =="
# **smoke PASS 는 full 통과 증명이 아닙니다.** smoke 가 지문을 기록하면 감축 실행 결과가
# 전수 검증 기록으로 둔갑해, 커밋 전 대조·archive precheck 가 모두 거짓 증명 위에서 돕니다.
# 판정 규칙이 "본문 언급" heuristic 인 한 smoke 는 구조적으로 샐 수 있고, 그 구멍을 메우는
# 것이 full 강제이므로 이 구별이 이 장치 전체의 전제입니다.
mini_cache="$FX/rd-workflow-workspace/.lifecycle/selftest-full-cache"
if [[ -f "$mini_cache" ]]; then
  no "smoke PASS 가 full 통과 지문을 기록했습니다 (smoke 결과가 full 증명으로 오인됩니다)"
else
  ok "smoke PASS 는 full 통과 지문을 기록하지 않음"
fi
if printf '%s%s' "$mini_out" "$mini_err" | grep -qF "full PASS 지문을"; then
  no "smoke 실행이 full PASS 지문 기록을 보고했습니다"
else
  ok "smoke 실행은 full PASS 지문 기록을 보고하지 않음"
fi
# 양성 대조 — 이것이 없으면 아래 (i)(ii) 가 "아무것도 실행되지 않았다" 로도 통과합니다.
has "관련 스텝의 실행 배너" "$mini_out" "== 미니 A =="
has "관련 스텝이 실제로 실행됨 (표식)" "$mini_out" "zzfx-a-ran"
has "inline checker 는 실 실행에서도 항상 실행" "$mini_out" "zzfx-inline-ran"
# (i) 스킵된 스텝의 실행 배너가 없어야 합니다.
if printf '%s' "$mini_out" | grep -qF "== 미니 B =="; then
  no "(i) 스킵 예정 스텝의 실행 배너가 출력됐습니다 (실제로는 스킵하지 않았습니다)"
else
  ok "(i) 스킵된 스텝의 실행 배너 없음"
fi
# (ii) 그 스텝의 표식이 없어야 합니다 = 정말 실행되지 않았습니다.
if printf '%s' "$mini_out" | grep -qF "zzfx-b-ran"; then
  no "(ii) 스킵 예정 스텝이 실제로 실행됐습니다 (표식이 출력됐습니다)"
else
  ok "(ii) 스킵된 스텝의 표식 없음"
fi
# (iii) 종료 시 보고하는 실제 스킵 수가 시작 시 스킵 예정 수와 일치해야 합니다.
#       스킵하면서 기록만 빠뜨리는 회귀(R2)가 여기서 잡힙니다.
m_plan_skip="$(printf '%s' "$mini_out" | sed -n 's/^  스킵 예정 스텝 (\([0-9]*\)개).*/\1/p' | head -1)"
m_done_skip="$(printf '%s' "$mini_out" | sed -n 's/^실제 스킵된 스텝 (\([0-9]*\)개).*/\1/p' | head -1)"
if [[ "$m_plan_skip" == "1" && "$m_done_skip" == "1" ]]; then
  ok "(iii) 실 실행의 실제 스킵 수가 스킵 예정 수와 일치 (1개)"
else
  no "(iii) 스킵 예정 '${m_plan_skip:-없음}' / 실제 스킵 '${m_done_skip:-없음}' (둘 다 1이어야 합니다)"
fi
# (iv) 스킵 요약 블록이 정확히 1회 나와야 합니다 (실 경로 호출 삭제 = R1, 중복 출력 모두 차단).
m_sum="$(printf '%s' "$mini_out" | grep -cF "== smoke 스킵 요약 ==" || true)"
if [[ "$m_sum" == "1" ]]; then
  ok "(iv) 실 실행에 스킵 요약 블록이 정확히 1회"
else
  no "(iv) 실 실행의 스킵 요약 블록이 ${m_sum}회입니다 (1회여야 합니다)"
fi
# 건수만 맞추고 목록을 지우는 회귀도 막습니다.
m_listed="$(printf '%s' "$mini_out" | sed -n '/== smoke 스킵 요약 ==/,$p' | grep -c '미니 B' || true)"
if [[ "$m_listed" == "1" ]]; then
  ok "스킵 요약이 스킵된 스텝을 이름으로 보고"
else
  no "스킵 요약 목록의 '미니 B' 가 ${m_listed}건입니다 (1건이어야 합니다)"
fi
# 예정 == 실제 인 정상 상태에서는 불일치 경고가 나오지 않아야 합니다 (경고 조건 반전 차단).
if printf '%s' "$mini_err" | grep -qF "스킵 예정"; then
  no "예정과 실제가 일치하는데 불일치 경고가 나왔습니다 (경고 조건이 뒤집혔습니다)"
else
  ok "예정 == 실제 이면 불일치 경고 없음"
fi
# (iii-b) **정상 경로 무손실 회귀** — 어긋남이 없는 실행에서는 정렬 불명이 켜지지 않아야
#         합니다. 어긋남 이후 전면 실행 장치가 정상 경로까지 번지면 스킵이 사라져 감축
#         효과가 rc 0 인 채로 조용히 없어집니다. 위 (iii) 이 스킵 1건을 이미 못박고,
#         여기서 "정렬 불명 보고 자체가 없음" 을 함께 고정합니다.
if printf '%s' "$mini_err" | grep -qF "순번 정렬 불명"; then
  no "(iii-b) 어긋남이 없는데 정렬 불명이 켜졌습니다 (정상 경로에서 감축이 사라집니다)"
else
  ok "(iii-b) 어긋남이 없는 정상 경로는 정렬 불명이 아니고 스킵 감축이 그대로 유지됨"
fi
# (v) 같은 fixture 에 `full` 을 **실제로** 실행하면 스킵 요약이 나오지 않아야 합니다.
#     실 경로 호출의 모드 가드를 제거하는 회귀(R4)가 여기서 잡힙니다 — 케이스 3 은
#     dry-run full 만 보므로 잡지 못합니다.
mini_full="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" full 2>&1)"; mini_full_rc=$?
if [[ "$mini_full_rc" == "0" ]]; then ok "최소 fixture 실 full 실행 exit 0"; else no "최소 fixture 실 full 실행 exit ${mini_full_rc}"; fi
if printf '%s' "$mini_full" | grep -qF "smoke 스킵 요약"; then
  no "(v) full 실 실행에 smoke 스킵 요약이 누출됐습니다 (축소 실행으로 오인됩니다)"
else
  ok "(v) full 실 실행에는 스킵 요약이 없음"
fi
has "(v) full 실 실행은 스킵 없이 전부 실행" "$mini_full" "zzfx-b-ran"
# (vi) **full 통과만 지문을 남깁니다** — 위 smoke 부재 단언과 한 쌍입니다. 한쪽만 있으면
#      "아무도 기록하지 않는다" 또는 "누구나 기록한다" 로도 통과해 구별력이 사라집니다.
if [[ -f "$mini_cache" ]]; then
  ok "(vi) full PASS 가 지문을 기록함"
else
  no "(vi) full PASS 인데 지문이 기록되지 않았습니다 (커밋 전 대조가 영구히 막힙니다)"
fi
has "(vi) full 실행이 기록 사실을 사용자에게 알림" "$mini_full" "full PASS 지문을 기록했습니다"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/_smoke_common.sh"
mini_fp_now="$(smoke_proof_fingerprint "$FX" worktree 2>/dev/null || true)"
if [[ -n "$mini_fp_now" && "$(head -1 "$mini_cache" 2>/dev/null)" == "$mini_fp_now" ]]; then
  ok "(vi) 기록된 지문이 현재 워킹트리 지문과 일치"
else
  no "(vi) 기록된 지문이 현재 워킹트리 지문과 다릅니다 (기록과 대조가 같은 정의를 쓰지 않습니다)"
fi
# fixture 를 원래 상태로 되돌립니다 — 이 캐시는 tracked 가 아니라 이후 케이스의 변경 파일
# 목록에 섞여 스킵 판정을 흔들 수 있습니다.
rm -f "$mini_cache"

# 14) preflight 예정 ≠ 실제 스킵이면 **stderr** 로 경고를 냅니다 (spec §5.3 preflight 역할 3).
#
# 최종 판정 `exit` **뒤에** `run_step` 을 붙이면 정적 추출에는 잡히지만(추출 수 == 실제
# 호출 수라 추출 fail-safe 는 통과합니다) 런타임에는 도달하지 못합니다. 그래서 preflight 는
# 스킵 예정 2건을 내는데 실제 기록은 1건이 됩니다 — 사용자가 두 숫자를 직접 대조하지
# 않으면 알 수 없는 상태이므로 경고가 필요합니다.
#
# 이 경고는 **스킵 기록 누락(R2)을 런타임에 자기 신고**하게 만드는 이중 효과가 있으므로,
# 조건 반전·stdout 오염·rc 변경 세 방향을 모두 못박습니다.
printf '#!/usr/bin/env bash\necho "zzfx-ghost-ran"\n' > "$FX/rd-workflow/scripts/mini_ghost_zzfx.sh"
printf 'run_step consumer "미니 유령" bash "${SCRIPT_DIR}/mini_ghost_zzfx.sh"\n' >> "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm ghost >/dev/null 2>&1
printf '\n# 변경 2\n' >> "$FX/rd-workflow/scripts/mini_a_zzfx.sh"
g_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/ghost_err")"; g_rc=$?
g_err="$(cat "$TMP/ghost_err")"
has "유령 스텝이 스킵 예정에 포함됨 (예정 2건)" "$g_out" "스킵 예정 스텝 (2개)"
has "실제 스킵은 1건 (유령 스텝에 도달하지 못함)" "$g_out" "실제 스킵된 스텝 (1개)"
has "예정 ≠ 실제 경고가 stderr 로 출력됨" "$g_err" "스킵 예정(2개)과 실제 스킵(1개)이 다릅니다"
has "경고가 전수 실행을 안내함" "$g_err" "self_test.sh full 로 전수 실행"
if printf '%s' "$g_out" | grep -qF "경고: smoke 스킵 예정"; then
  no "경고가 stdout 을 오염시켰습니다 (건수·목록을 파싱하는 다른 단언이 깨집니다)"
else
  ok "경고가 stdout 을 오염시키지 않음 (stderr 전용)"
fi
if [[ "$g_rc" == "0" ]]; then
  ok "예정 ≠ 실제 경고가 판정(rc)을 바꾸지 않음"
else
  no "경고가 rc 를 ${g_rc} 로 바꿨습니다 (fail-safe 신고이지 판정이 아닙니다)"
fi
# fixture 원복: 케이스 13·14 가 만든 커밋 2개를 케이스 12 직후 지점으로 되돌립니다.
# `$FX` 는 이 파일이 mktemp -d 로 만든 테스트 전용 임시 저장소이며 저장소 본체가 아니므로
# reset --hard 가 안전합니다. 경로가 그 임시 디렉터리 안이라는 것을 실행 시점에도 확인합니다.
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard "$fx_base_sha13" >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case13" ]]; then
  ok "케이스 13·14 이후 fixture 이력이 케이스 12 시점으로 원복됨"
else
  no "케이스 13·14 가 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 왜곡됩니다)"
fi
if [[ "$(grep -c '^run_step ' "$fx_self")" == "$fx_steps_before_case13" ]]; then
  ok "원복 후 fixture self_test.sh 의 스텝 수가 케이스 12 시점과 같음 (${fx_steps_before_case13}개)"
else
  no "원복 후 스텝 수가 ${fx_steps_before_case13}개가 아닙니다 (최소 fixture 가 남았습니다)"
fi

# 15) **구문 검사 축소의 검출력 계약** — 얻는 것과 잃는 것을 한 쌍으로 못박습니다.
#
# smoke 의 구문 검사는 이제 **변경된 `*.sh` 만** 봅니다. 이것은 검사 범위를 좁히는 =
# 검출력을 줄이는 변경이므로, "대상 선택이 맞는가"(단위 테스트가 봅니다) 만으로는
# 부족합니다. 진입점 계약 쪽에서 아래 셋을 실측으로 고정합니다.
#
#   (A) 얻은 것  — 변경된 파일의 구문 오류를 smoke 가 **잡습니다**.
#   (B) 잃은 것  — 변경되지 않은 파일의 구문 오류를 smoke 는 **놓치고**, `full` 은 **잡습니다**.
#                  두 단언은 반드시 한 쌍입니다. 앞만 있으면 "놓치는 것을 정상이라고 못박은"
#                  테스트가 되고, 뒤만 있으면 축소의 대가가 기록되지 않습니다.
#   (C) 폴백     — 폴백 상태에서는 전수 검사로 돌아갑니다. 폴백은 "전수 실행" 을 뜻하는데
#                  이 스텝만 축소된 채면 폴백 계약이 반쯤 거짓이 됩니다.
#
# 정본 49스텝을 네 번 실제로 돌릴 수는 없으므로 케이스 13 의 최소 fixture 기법을 씁니다 —
# 최상위 `run_step` 줄만 2건(bash 대상 1건 + 구문 검사 1건)으로 갈아 끼우고, `syntax_check`
# 함수 본문과 모드·폴백 판정은 정본 그대로 남깁니다. `env -u RD_SELFTEST_SMOKE_DRYRUN` 로
# 떨어뜨리는 이유도 같습니다 — dry-run 은 스텝을 실행하지 않아 구문 검사를 관측할 수 없습니다.
fx_base_sha15="$(git -C "$FX" rev-parse HEAD)"
fx_log_before_case15="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
fx_steps_before_case15="$(grep -c '^run_step ' "$fx_self")"
printf '#!/usr/bin/env bash\necho "zzfx-syn-a-ran"\n' > "$FX/rd-workflow/scripts/syn_a_zzfx.sh"
# 워킹트리에서 **끝까지 바뀌지 않는** 파일에 구문 오류를 심고 커밋합니다 (닫히지 않은 if).
# 커밋해야 변경 목록에서 빠져 "변경되지 않은 파일" 이라는 전제가 성립합니다.
printf '#!/usr/bin/env bash\nif true; then\n  echo dangling\n' \
  > "$FX/rd-workflow/scripts/syn_untouched_zzfx.sh"
# 같은 것을 **서브디렉터리 안**에도 하나 둡니다. full 의 전수 스윕이 깊이를 잃어도
# (예: 탐색에 최대 깊이 1 이 붙어도) 최상위 파일만으로는 드러나지 않기 때문입니다 —
# 실측으로 검사 대상이 67 → 39 로 줄어 하위 디렉터리 28개가 통째로 빠지는데도 두
# 스위트가 통과했습니다. "미변경 파일은 full 이 잡는다" 가 축소의 상환 근거이므로,
# 그 그물의 **크기**를 회귀에서 고정합니다.
printf '#!/usr/bin/env bash\nif true; then\n  echo dangling deep\n' \
  > "$FX/rd-workflow/scripts/hooks/syn_deep_untouched_zzfx.sh"
# **세 번째 층**에도 하나 둡니다. 두 층(최상위 · `hooks/`)만 있으면 그 두 위치를 그대로 남긴
# 채 다른 서브디렉터리만 그물에서 빼는 형태가 안 잡힙니다 (실측: 전수 스윕에 특정 하위
# 디렉터리 제외 조건 하나만 붙여도 두 스위트가 PASS 했습니다). 깊이를 잃는 축과 **어느
# 디렉터리를 빠뜨리는가** 축은 다르므로 층을 하나 더 씁니다.
printf '#!/usr/bin/env bash\nif true; then\n  echo dangling batch\n' \
  > "$FX/rd-workflow/scripts/batch/syn_deep2_untouched_zzfx.sh"
syn_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$((syn_at - 1))" "$fx_self"
  printf 'run_step consumer "미니 구문 A" bash "${SCRIPT_DIR}/syn_a_zzfx.sh"\n'
  printf 'run_step consumer "스크립트 구문 검사 (bash -n)" syntax_check\n'
  tail -n "+$syn_at" "$fx_self" | sed '/^run_step /d'
} > "$TMP/syn_self_test_zzfx.sh"
mv "$TMP/syn_self_test_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm syntax-fixture >/dev/null 2>&1
syn_extracted="$(grep -c '^run_step ' "$fx_self")"
if [[ "$syn_extracted" == "2" ]]; then
  ok "구문 검사 fixture 의 최상위 run_step 이 2건"
else
  no "구문 검사 fixture 의 최상위 run_step 이 ${syn_extracted}건입니다 (2건이어야 합니다)"
fi

# (A) 변경된 파일에 구문 오류를 심습니다 → smoke 가 잡아야 합니다.
printf '\nif true; then\n' >> "$FX/rd-workflow/scripts/syn_a_zzfx.sh"
a_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/syn_a_err")" || true
a_err="$(cat "$TMP/syn_a_err")"
has "(A) 변경된 파일의 구문 오류로 구문 검사 스텝이 FAIL" "$a_err" "FAIL: 스크립트 구문 검사 (bash -n)"
has "(A) 구문 오류 경로가 stderr 로 보고됨" "$a_err" "구문 오류: "
has "(A) 보고된 경로가 변경된 그 파일" "$a_err" "syn_a_zzfx.sh"
# 같은 실행에서 변경되지 않은 쪽은 보고되지 않아야 합니다 — 이것이 축소의 직접 증거입니다.
if printf '%s' "$a_err" | grep -qF "syn_untouched_zzfx.sh"; then
  no "(A) smoke 가 변경되지 않은 파일까지 보고했습니다 (축소가 적용되지 않았습니다)"
else
  ok "(A) smoke 는 변경되지 않은 파일을 보고하지 않음"
fi

# (B-1) 잃은 것 — 변경된 파일을 정상으로 돌리면, 변경되지 않은 파일의 구문 오류는 놓칩니다.
git -C "$FX" checkout -- . >/dev/null 2>&1
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/syn_a_zzfx.sh"
b_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/syn_b_err")"; b_rc=$?
b_err="$(cat "$TMP/syn_b_err")"
# 폴백이면 전수 검사가 돌아 아래 단언이 "축소" 가 아닌 다른 이유로 흔들립니다 — 먼저 막습니다.
if printf '%s' "$b_out" | grep -qF "full 폴백"; then
  no "(B-1) 축소 관측이 full 폴백 상태에서 돌았습니다 (아래 단언이 무의미해집니다)"
else
  ok "(B-1) 축소 관측이 smoke 정상 판정으로 돌았음"
fi
has "(B-1) 변경되지 않은 파일의 구문 오류를 smoke 는 놓침 (축소의 대가)" \
    "$b_out" "PASS: 스크립트 구문 검사 (bash -n)"
if printf '%s' "$b_err" | grep -qF "구문 오류: "; then
  no "(B-1) smoke 가 구문 오류를 보고했습니다 (변경 목록에 없는 파일인데 검사했습니다)"
else
  ok "(B-1) smoke 의 구문 오류 보고 없음"
fi
if [[ "$b_rc" == "0" ]]; then ok "(B-1) 축소된 smoke 는 exit 0"; else no "(B-1) 축소된 smoke exit ${b_rc}"; fi

# (B-2) 안전망 — 같은 워킹트리에서 `full` 은 그 오류를 잡아야 합니다.
c_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" full 2>"$TMP/syn_c_err")"; c_rc=$?
c_err="$(cat "$TMP/syn_c_err")"
has "(B-2) full 은 변경되지 않은 파일의 구문 오류를 FAIL 로 잡음" \
    "$c_err" "FAIL: 스크립트 구문 검사 (bash -n)"
has "(B-2) full 이 그 파일 경로를 보고" "$c_err" "syn_untouched_zzfx.sh"
has "(B-2) full 의 그물이 서브디렉터리까지 덮음 (전수 스윕 범위 고정)" \
    "$c_err" "syn_deep_untouched_zzfx.sh"
has "(B-2) full 의 그물이 세 번째 층까지 덮음 (특정 디렉터리 제외 차단)" \
    "$c_err" "syn_deep2_untouched_zzfx.sh"
if [[ "$c_rc" != "0" ]]; then ok "(B-2) full 실행이 실패로 종료 (안전망이 살아 있음)"; else no "(B-2) full 실행이 exit 0 입니다"; fi

# (C) 폴백 상태에서는 전수 검사로 돌아가야 합니다.
#
# ⚠️ 프로브 파일명을 **동적으로** 만듭니다 (케이스 8 과 같은 이유). 이 파일 본문에 이름을
# 리터럴로 박으면 폐포 본문 매치로 커버된 것으로 오판되어 무매핑 폴백 자체가 걸리지 않습니다.
syn_probe="syn_unmapped_probe_$$.sh"
printf 'echo hi\n' > "$FX/rd-workflow/scripts/$syn_probe"
d_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/syn_d_err")"; d_rc=$?
d_err="$(cat "$TMP/syn_d_err")"
has "(C) 무매핑 신규 파일로 full 폴백이 걸림" "$d_out" "어떤 스텝과도 연결되지 않는 인프라 변경"
has "(C) 폴백 상태의 구문 검사는 전수로 돌아가 FAIL" "$d_err" "FAIL: 스크립트 구문 검사 (bash -n)"
has "(C) 폴백 상태에서 변경되지 않은 파일도 보고" "$d_err" "syn_untouched_zzfx.sh"
if [[ "$d_rc" != "0" ]]; then ok "(C) 폴백 실행이 실패로 종료"; else no "(C) 폴백 실행이 exit 0 입니다"; fi
rm -f "$FX/rd-workflow/scripts/$syn_probe"

# fixture 원복: 케이스 15 가 만든 커밋 1개를 케이스 14 직후 지점으로 되돌립니다.
# `$FX` 는 이 파일이 mktemp -d 로 만든 테스트 전용 임시 저장소이며 저장소 본체가 아니므로
# reset --hard 가 안전합니다. 경로가 그 임시 디렉터리 안이라는 것을 실행 시점에도 확인합니다.
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard "$fx_base_sha15" >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case15" ]]; then
  ok "케이스 15 이후 fixture 이력이 케이스 14 시점으로 원복됨"
else
  no "케이스 15 가 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 왜곡됩니다)"
fi
if [[ "$(grep -c '^run_step ' "$fx_self")" == "$fx_steps_before_case15" ]]; then
  ok "원복 후 fixture self_test.sh 의 스텝 수가 케이스 14 시점과 같음 (${fx_steps_before_case15}개)"
else
  no "원복 후 스텝 수가 ${fx_steps_before_case15}개가 아닙니다 (구문 검사 fixture 가 남았습니다)"
fi

# 16) **preflight 가 모르는 스텝이 끼어들어 순번을 밀어내는 형태** (spec §5.3 역할 3)
#
# 정적 추출은 **최상위** `run_step` 만 봅니다. 그래서 함수 안에서 부른 `run_step` 은 추출
# 수를 바꾸지 않아 추출 fail-safe 를 그대로 통과하면서 런타임 순번만 한 칸씩 밀어냅니다.
# 그러면 밀려난 순번이 남의 판정을 물려받아 **preflight 가 알지도 못하는 스텝이 오히려
# 스킵**됩니다 — spec 이 요구한 "스킵하지 않고 실행" 의 정반대 방향입니다.
#
# 건수 대조로는 잡히지 않습니다. 스킵 1건이 다른 1건으로 바뀔 뿐이라 `1 == 1` 로 침묵하고,
# rc 0 · PASS · stderr 비어 있음으로 끝나 사용자가 두 목록을 눈으로 대조해야만 압니다.
# 그래서 **순번 → 설명 대응** 자체를 실행 시점에 확인하고, 어긋나면 스킵하지 않고 실행합니다.
#
# 케이스 13 과 같은 최소 fixture 기법입니다 (커밋 → 원복 포함).
fx_base_sha16="$(git -C "$FX" rev-parse HEAD)"
fx_log_before_case16="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
fx_steps_before_case16="$(grep -c '^run_step ' "$fx_self")"
printf '#!/usr/bin/env bash\necho "zzfx-na-ran"\n' > "$FX/rd-workflow/scripts/nest_a_zzfx.sh"
printf '#!/usr/bin/env bash\necho "zzfx-nb-ran"\n' > "$FX/rd-workflow/scripts/nest_b_zzfx.sh"
printf '#!/usr/bin/env bash\necho "zzfx-nx-ran"\n' > "$FX/rd-workflow/scripts/nest_x_zzfx.sh"
nest_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$((nest_at - 1))" "$fx_self"
  # 들여쓰기된 호출이라 정적 추출에 잡히지 않습니다 — 이것이 이 케이스의 전제입니다.
  printf 'nest_hidden_zzfx() {\n'
  printf '  run_step consumer "미니 X" bash "${SCRIPT_DIR}/nest_x_zzfx.sh"\n'
  printf '}\n'
  printf 'run_step consumer "미니 A" bash "${SCRIPT_DIR}/nest_a_zzfx.sh"\n'
  printf 'nest_hidden_zzfx\n'
  printf 'run_step consumer "미니 B" bash "${SCRIPT_DIR}/nest_b_zzfx.sh"\n'
  tail -n "+$nest_at" "$fx_self" | sed '/^run_step /d'
} > "$TMP/nest_self_test_zzfx.sh"
mv "$TMP/nest_self_test_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm nested >/dev/null 2>&1
nest_extracted="$(grep -c '^run_step ' "$fx_self")"
if [[ "$nest_extracted" == "2" ]]; then
  ok "순번 밀림 fixture 의 최상위 run_step 이 2건 (숨은 호출은 추출되지 않음)"
else
  no "순번 밀림 fixture 의 최상위 run_step 이 ${nest_extracted}건입니다 (2건이어야 합니다)"
fi
# `미니 A` 의 대상만 변경 → preflight 는 2번(`미니 B`)을 스킵 예정으로 냅니다.
# 런타임 순번은 A(1) · X(2) · B(3) 이라 2번 자리에 `미니 X` 가 옵니다.
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/nest_a_zzfx.sh"
n_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/nest_err")"; n_rc=$?
n_err="$(cat "$TMP/nest_err")"
if printf '%s' "$n_out" | grep -qF "full 폴백"; then
  no "순번 밀림 케이스가 full 폴백 상태에서 돌았습니다 (아래 단언이 무의미해집니다)"
else
  ok "순번 밀림 케이스가 smoke 정상 판정으로 돌았음"
fi
has "순번 밀림 예고 (2번을 스킵 예정으로 냄)" "$n_out" "스킵 예정 스텝 (1개)"
# (i) 어긋난 순번을 stderr 로 경고합니다.
has "(i) 순번 대응 어긋남을 경고" "$n_err" "스텝 순번 2 의 preflight 대응이 어긋났습니다"
has "(i) 경고가 예정·실제 설명을 함께 보여줌" "$n_err" "preflight: '미니 B' / 실제: '미니 X'"
has "(i) 경고가 전수 실행을 안내함" "$n_err" "self_test.sh full 로 전수 실행"
# (ii) preflight 가 모르는 스텝은 **실제로 실행**되어야 합니다 (spec 문장 그대로).
#      대응 검사를 없애거나 "어긋나면 경고만 내고 그대로 스킵" 으로 바꾸면 여기서 죽습니다.
has "(ii) preflight 미지 스텝이 실제로 실행됨" "$n_out" "zzfx-nx-ran"
has "(ii) 그 스텝의 실행 배너도 출력됨" "$n_out" "== 미니 X =="
# (iii) 예고된 스킵 스텝조차 스킵되지 않아야 합니다 — 순번이 밀린 뒤의 판정은 신뢰할 수
#       없으므로 덜 스킵하는 쪽(fail-safe)으로 갑니다.
has "(iii) 밀려난 뒤의 스텝도 스킵하지 않고 실행" "$n_out" "zzfx-nb-ran"
has "(iii) 실제 스킵은 0건" "$n_out" "실제 스킵된 스텝 (0개)"
# (iv) 손실은 스킵 요약에서 **정렬 불명 사유로** 보고됩니다. 어긋남이 곧 원인이므로 예정 ≠ 실제
#      경고로 중복 신고하지 않고(사용자가 원인을 오판합니다) 사유와 손실 규모를 한 번에 냅니다.
has "(iv) 요약이 정렬 불명 사유로 손실을 보고" "$n_err" "smoke 순번 정렬 불명"
has "(iv) 손실 규모(순번 2 이후 2개)를 함께 보고" "$n_err" "순번 2 이후 2개 스텝을 스킵 판정 없이"
if printf '%s' "$n_err" | grep -qF "스킵 예정(1개)과 실제 스킵(0개)이 다릅니다"; then
  no "(iv) 정렬 불명인데 예정 ≠ 실제 경고까지 함께 나왔습니다 (한 사건을 두 문구로 신고합니다)"
else
  ok "(iv) 정렬 불명이면 예정 ≠ 실제 경고로 중복 신고하지 않음"
fi
# (v) 경고는 신고이지 판정이 아닙니다.
if [[ "$n_rc" == "0" ]]; then
  ok "(v) 순번 대응 경고가 판정(rc)을 바꾸지 않음"
else
  no "(v) 순번 대응 경고가 rc 를 ${n_rc} 로 바꿨습니다 (fail-safe 신고이지 판정이 아닙니다)"
fi
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard "$fx_base_sha16" >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case16" ]]; then
  ok "케이스 16 이후 fixture 이력이 케이스 15 시점으로 원복됨"
else
  no "케이스 16 이 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 왜곡됩니다)"
fi
if [[ "$(grep -c '^run_step ' "$fx_self")" == "$fx_steps_before_case16" ]]; then
  ok "원복 후 fixture self_test.sh 의 스텝 수가 케이스 15 시점과 같음 (${fx_steps_before_case16}개)"
else
  no "원복 후 스텝 수가 ${fx_steps_before_case16}개가 아닙니다 (순번 밀림 fixture 가 남았습니다)"
fi

# 17) 스킵 예정과 실제 스킵의 **내용**이 어긋나면 경고합니다 — 양쪽 방향 모두.
#
# 건수 대조는 두 가지를 놓칩니다.
#   (a) 같은 건수인데 **다른 스텝**이 스킵된 상태 (`1 == 1` 로 침묵)
#   (b) 예정보다 **더 많이** 건너뛴 상태 — 더 위험한 방향인데, 조건을 `<` 로 바꾸는 것만
#       으로 조용해집니다 (기존 케이스는 `1 < 2` 라 그대로 통과했습니다).
# 그래서 정렬 목록 비교로 승격했고, 여기서 두 방향을 실측으로 못박습니다.
#
# 두 상태 모두 현재 코드로는 자연 발생하지 않으므로(`SMOKE_SKIP_IDX` 와 `SMOKE_SKIP_DESCS`
# 를 항상 함께 채웁니다) fixture 에서 실제 스킵 기록만 직접 흔듭니다. 검사 대상은 요약의
# **대조 로직**이지 그 상태에 이르는 경로가 아니므로 이 주입이 곧 계약 검사입니다.
fx_base_sha17="$(git -C "$FX" rev-parse HEAD)"
fx_log_before_case17="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
fx_steps_before_case17="$(grep -c '^run_step ' "$fx_self")"
printf '#!/usr/bin/env bash\necho "zzfx-oa-ran"\n' > "$FX/rd-workflow/scripts/ov_a_zzfx.sh"
printf '#!/usr/bin/env bash\necho "zzfx-ob-ran"\n' > "$FX/rd-workflow/scripts/ov_b_zzfx.sh"
ov_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$((ov_at - 1))" "$fx_self"
  printf 'run_step consumer "미니 A" bash "${SCRIPT_DIR}/ov_a_zzfx.sh"\n'
  printf 'run_step consumer "미니 B" bash "${SCRIPT_DIR}/ov_b_zzfx.sh"\n'
  printf 'if [[ -n "${ZZFX_EXTRA_SKIP:-}" ]]; then SKIPPED_STEPS+=("$ZZFX_EXTRA_SKIP"); fi\n'
  printf 'if [[ -n "${ZZFX_SWAP_SKIP:-}" ]]; then SKIPPED_STEPS=("$ZZFX_SWAP_SKIP"); fi\n'
  # 순서만 다른 두 목록을 만드는 주입입니다. 두 목록의 **기록 순서 자체는 계약이 아니므로**
  # (양쪽 원소가 `"<순번>. <설명>"` 이라 순번이 내용에 들어 있습니다) 이 상태에서는 경고가
  # 나오면 안 됩니다. 현재 두 목록의 생성 순서가 같아 순서 비의존성이 자연 관측되지 않고,
  # 정렬을 빼도 통과합니다 — 그래서 순서가 갈라진 상태를 직접 만들어 못박습니다.
  printf 'if [[ -n "${ZZFX_REORDER:-}" ]]; then\n'
  printf '  SKIPPED_STEPS=("2. 미니 B" "7. 딴 스텝 zzfx")\n'
  printf '  SMOKE_SKIP_DESCS=("7. 딴 스텝 zzfx" "2. 미니 B")\n'
  printf 'fi\n'
  tail -n "+$ov_at" "$fx_self" | sed '/^run_step /d'
} > "$TMP/ov_self_test_zzfx.sh"
mv "$TMP/ov_self_test_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm overskip >/dev/null 2>&1
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/ov_a_zzfx.sh"
# 대조군 — 예정 1건 == 실제 1건, 내용도 같으므로 경고가 없어야 합니다.
o0_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/ov0_err")"; o0_rc=$?
o0_err="$(cat "$TMP/ov0_err")"
has "대조군이 smoke 정상 판정 (스킵 예정 1건)" "$o0_out" "스킵 예정 스텝 (1개)"
if printf '%s' "$o0_err" | grep -qF "경고"; then
  no "예정과 실제가 일치하는데 경고가 나왔습니다 (내용 대조가 항상 참을 냅니다)"
else
  ok "예정 == 실제 이면 경고 없음"
fi
if [[ "$o0_rc" == "0" ]]; then ok "대조군 exit 0"; else no "대조군 exit ${o0_rc}"; fi
# (a) 같은 건수, 다른 내용.
o1_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN ZZFX_SWAP_SKIP="9. 다른 스텝 zzfx" \
  bash "$fx_self" 2>"$TMP/ov1_err")"; o1_rc=$?
o1_err="$(cat "$TMP/ov1_err")"
has "(a) 건수가 같아도 내용이 다르면 경고" "$o1_err" "실제 스킵의 내용이 다릅니다 (건수는 1개로 같습니다)"
has "(a) 경고가 전수 실행을 안내함" "$o1_err" "self_test.sh full 로 전수 실행"
if printf '%s' "$o1_out" | grep -qF "내용이 다릅니다"; then
  no "(a) 경고가 stdout 을 오염시켰습니다"
else
  ok "(a) 경고가 stderr 전용"
fi
if [[ "$o1_rc" == "0" ]]; then ok "(a) 내용 불일치 경고가 rc 를 바꾸지 않음"; else no "(a) rc 가 ${o1_rc} 입니다"; fi
# (b) **예정보다 많이** 스킵된 방향. 조건을 `<`(실제 < 예정)로 좁히면 이 방향이 침묵합니다.
o2_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN ZZFX_EXTRA_SKIP="9. 유령 스킵 zzfx" \
  bash "$fx_self" 2>"$TMP/ov2_err")"; o2_rc=$?
o2_err="$(cat "$TMP/ov2_err")"
has "(b) 예정보다 많이 스킵되면 경고 (과대 스킵 방향)" "$o2_err" "스킵 예정(1개)과 실제 스킵(2개)이 다릅니다"
if [[ "$o2_rc" == "0" ]]; then ok "(b) 과대 스킵 경고가 rc 를 바꾸지 않음"; else no "(b) rc 가 ${o2_rc} 입니다"; fi
if printf '%s' "$o2_out" | grep -qF "실제 스킵된 스텝 (2개)"; then
  ok "(b) 요약이 실제 스킵 2건을 그대로 보고 (경고가 목록을 감추지 않음)"
else
  no "(b) 요약의 실제 스킵 건수가 2개로 보고되지 않았습니다"
fi
# (c) **순서만 다른** 상태 — 내용이 같으므로 경고가 없어야 합니다. 대조가 순서에 의존하면
#     두 목록의 생성 순서가 갈라지는 날 이유 없는 오탐이 나고, 그 소음이 진짜 어긋남을 덮습니다.
o3_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN ZZFX_REORDER=1 bash "$fx_self" 2>"$TMP/ov3_err")"; o3_rc=$?
o3_err="$(cat "$TMP/ov3_err")"
if printf '%s' "$o3_err" | grep -qF "경고"; then
  no "(c) 순서만 다른데 경고가 나왔습니다 (대조가 순서에 의존합니다): $(printf '%s' "$o3_err" | head -1)"
else
  ok "(c) 순서만 다르고 내용이 같으면 경고 없음 (순서 비의존)"
fi
if [[ "$o3_rc" == "0" ]]; then ok "(c) 순서 비의존 경로 exit 0"; else no "(c) exit ${o3_rc}"; fi
# 양성 대조 — 주입이 실제로 두 목록을 흔들었는지 확인합니다. 이것이 없으면 주입이 무효였을
# 때에도 "경고 없음" 으로 통과합니다.
if printf '%s' "$o3_out" | grep -qF "실제 스킵된 스텝 (2개)"; then
  ok "(c) 순서 비의존 주입이 실제로 2건을 만들었음 (양성 대조)"
else
  no "(c) 순서 비의존 주입이 적용되지 않았습니다 (위 단언이 공허합니다)"
fi
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard "$fx_base_sha17" >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case17" ]]; then
  ok "케이스 17 이후 fixture 이력이 케이스 16 시점으로 원복됨"
else
  no "케이스 17 이 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 왜곡됩니다)"
fi
if [[ "$(grep -c '^run_step ' "$fx_self")" == "$fx_steps_before_case17" ]]; then
  ok "원복 후 fixture self_test.sh 의 스텝 수가 케이스 16 시점과 같음 (${fx_steps_before_case17}개)"
else
  no "원복 후 스텝 수가 ${fx_steps_before_case17}개가 아닙니다 (과대 스킵 fixture 가 남았습니다)"
fi

# 18) **설치 루트가 git 최상위가 아닌 레이아웃** — 조용한 통과를 막습니다.
#
# 변경 파일 목록은 `git status` 산출이라 언제나 repo 최상위 상대 경로입니다. 설치 루트를
# 기준으로 조인하면 서브디렉터리 설치에서 모든 경로가 존재하지 않게 되고, 삭제 파일 필터와
# 구분 없이 전부 탈락해 **검사 대상 0건으로 통과**합니다. 이것은 "미변경 파일을 놓친다"
# 는 의도된 대가와 급이 다릅니다 — smoke 가 검사하기로 약속한 것마저 놓칩니다.
#
# 기존 fixture 는 전부 `git 최상위 == 설치 루트` 라 이 축을 밟지 않으므로 별도 저장소를
# 만듭니다. 케이스 15 와 같은 2스텝 최소 fixture 이고, 다른 점은 트리 위치뿐입니다.
SUBFX="$TMP/subfx"
mkdir -p "$SUBFX/sub/rd-workflow"
cp -R "${SCRIPT_DIR}" "$SUBFX/sub/rd-workflow/scripts"
git -C "$SUBFX" init -q .
git -C "$SUBFX" config user.email t@t.t; git -C "$SUBFX" config user.name t
sub_self="$SUBFX/sub/rd-workflow/scripts/self_test.sh"
printf '#!/usr/bin/env bash\necho "zzfx-sub-ran"\n' > "$SUBFX/sub/rd-workflow/scripts/sub_a_zzfx.sh"
sub_at="$(grep -n '^run_step ' "$sub_self" | head -1 | cut -d: -f1)"
{
  head -n "$((sub_at - 1))" "$sub_self"
  printf 'run_step consumer "미니 서브 A" bash "${SCRIPT_DIR}/sub_a_zzfx.sh"\n'
  printf 'run_step consumer "스크립트 구문 검사 (bash -n)" syntax_check\n'
  tail -n "+$sub_at" "$sub_self" | sed '/^run_step /d'
} > "$TMP/sub_self_test_zzfx.sh"
mv "$TMP/sub_self_test_zzfx.sh" "$sub_self"
git -C "$SUBFX" add -A >/dev/null 2>&1
git -C "$SUBFX" commit -qm init >/dev/null 2>&1
# 변경된 파일에 구문 오류를 심습니다 (닫히지 않은 if).
printf '\nif true; then\n' >> "$SUBFX/sub/rd-workflow/scripts/sub_a_zzfx.sh"
s_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$sub_self" 2>"$TMP/sub_err")"; s_rc=$?
s_err="$(cat "$TMP/sub_err")"
# 폴백이면 전수 검사가 돌아 아래 단언이 다른 이유로 통과합니다 — 먼저 막습니다.
if printf '%s' "$s_out" | grep -qF "full 폴백"; then
  no "(D) 서브 레이아웃 관측이 full 폴백 상태에서 돌았습니다 (아래 단언이 무의미해집니다)"
else
  ok "(D) 서브 레이아웃 관측이 smoke 정상 판정으로 돌았음"
fi
has "(D) 서브디렉터리 설치에서도 변경 파일의 구문 오류를 FAIL 로 잡음" \
    "$s_err" "FAIL: 스크립트 구문 검사 (bash -n)"
has "(D) 보고된 경로가 변경된 그 파일" "$s_err" "sub_a_zzfx.sh"
if [[ "$s_rc" != "0" ]]; then
  ok "(D) 서브 레이아웃 실행이 실패로 종료 (조용한 통과가 아님)"
else
  no "(D) 서브 레이아웃 실행이 exit 0 입니다 (변경 파일의 구문 오류를 놓쳤습니다)"
fi

# 19) **설명 중복 + 순번 밀림** — 변경된 파일 자신의 스텝이 조용히 스킵되지 않아야 합니다.
#
# 순번↔설명 대조가 "**그 순번의** 설명인가" 에서 "설명이 표 **어딘가에** 있는가" 로 약해지면
# (인덱스 조회를 멤버십 검색으로 바꾸는 형태) 케이스 16 은 그대로 통과합니다. 그 약화가
# 실제로 위험해지는 조건이 **설명 중복 + 순번 밀림** 입니다 — 밀려난 순번의 설명이 표의
# 다른 자리와 우연히 맞아떨어지면 그 스텝이 남의 스킵 판정을 물려받고, 스킵 요약은 예정과
# 일치하는 그림을 보여 주므로 경고조차 나오지 않습니다 (실측: 그 조합에서 변경된 파일
# 자신의 스텝이 rc=0 · 요약 완전 일치 상태로 조용히 스킵됐습니다).
#
# 먼저 **정본이 그 조건에 들어가 있지 않은지**부터 봅니다. 지금은 스텝 설명이 전부 고유해
# 사고가 나지 않는데, 그 유일성을 지키는 장치가 없으면 설명 하나를 복사해 붙이는 편집이
# 위 상태를 조용히 만들어 냅니다.
dup_desc_all="$(sed -n 's/^run_step [a-z-]* "\([^"]*\)".*/\1/p' "$SELF")"
# 양성 대조 — 추출이 0건이거나 일부만 걸리면 "중복 없음" 이 **공허하게** 통과합니다. 건수를
# 이미 출력하면서 단언하지 않으면 그 줄을 고치는 편집이 조용히 지나갑니다. 기대값은 정본에서
# 동적으로 읽으므로 스텝이 늘어도 낡지 않습니다.
dup_desc_n="$(printf '%s\n' "$dup_desc_all" | grep -c . || true)"
dup_step_n="$(grep -c '^run_step ' "$SELF")"
if [[ "$dup_desc_n" == "$dup_step_n" ]]; then
  ok "정본 스텝 설명 추출 건수가 run_step 호출 수와 일치 (${dup_step_n}개)"
else
  no "정본 스텝 설명 추출이 ${dup_desc_n}건인데 run_step 호출은 ${dup_step_n}건입니다 (추출이 어긋나 유일성 단언이 공허합니다)"
fi
dup_desc_dupes="$(printf '%s\n' "$dup_desc_all" | sort | uniq -d)"
if [[ -z "$dup_desc_dupes" ]]; then
  ok "정본 스텝 설명이 전부 고유 ($(printf '%s\n' "$dup_desc_all" | grep -c . )개)"
else
  no "정본에 중복된 스텝 설명이 있습니다 — 순번이 밀리면 조용한 오스킵이 납니다: $(printf '%s' "$dup_desc_dupes" | tr '\n' ' ')"
fi
#
# fixture 는 정적 추출 4건(`미니 A` · `미니 D` · `미니 E` · `미니 D`) 에 함수 안 숨은 호출
# 1건(설명도 `미니 D`)을 끼워 넣고, **첫 번째 `미니 D` 의 대상(b)만** 변경합니다. 런타임 순번은
# A(1) · D(2, 숨은 호출) · D(3, b) · E(4) · D(5) 로 한 칸씩 밀립니다.
#   · 순번 2 는 표의 2번 설명(`미니 D`)과 **우연히 일치**해 대조를 통과합니다. 그 자리의 판정은
#     "관련 있음(b 가 변경됨)" 이라 스킵되지 않고, 어긋남은 아직 드러나지 않습니다 — 그래서
#     이 케이스는 "숨은 호출이 곧 즉시 발각" 이라는 낙관에 기대지 않습니다.
#   · 순번 3 의 표 설명은 `미니 E` 인데 실제는 `미니 D` → 어긋남 → 그 스텝과 이후 전부 실행
#     (= 변경된 파일 자신의 스텝이 살아남습니다). 멤버십 검색으로 약해지면 `미니 D` 가 표에
#     있다는 이유로 일치 판정이 되어 순번 3 이 3번 자리의 스킵 판정을 물려받아 **조용히 스킵**됩니다.
#   · 순번 4·5 는 정렬 불명이므로 스킵 판정을 조회하지 않고 실행됩니다.
#
# 케이스 13·16 과 같은 최소 fixture 기법입니다 (커밋 → 원복 포함).
fx_base_sha19="$(git -C "$FX" rev-parse HEAD)"
fx_log_before_case19="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
fx_steps_before_case19="$(grep -c '^run_step ' "$fx_self")"
for _dn in a b c e x; do
  printf '#!/usr/bin/env bash\necho "zzfx-%s-ran"\n' "$_dn" \
    > "$FX/rd-workflow/scripts/dupx_${_dn}_zzfx.sh"
done
dupx_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$((dupx_at - 1))" "$fx_self"
  # 들여쓰기된 호출이라 정적 추출에 잡히지 않습니다 — 순번을 밀어내는 장치입니다.
  printf 'dupx_hidden_zzfx() {\n'
  printf '  run_step consumer "미니 D" bash "${SCRIPT_DIR}/dupx_x_zzfx.sh"\n'
  printf '}\n'
  printf 'run_step consumer "미니 A" bash "${SCRIPT_DIR}/dupx_a_zzfx.sh"\n'
  printf 'dupx_hidden_zzfx\n'
  printf 'run_step consumer "미니 D" bash "${SCRIPT_DIR}/dupx_b_zzfx.sh"\n'
  printf 'run_step consumer "미니 E" bash "${SCRIPT_DIR}/dupx_e_zzfx.sh"\n'
  printf 'run_step consumer "미니 D" bash "${SCRIPT_DIR}/dupx_c_zzfx.sh"\n'
  tail -n "+$dupx_at" "$fx_self" | sed '/^run_step /d'
} > "$TMP/dupx_self_test_zzfx.sh"
mv "$TMP/dupx_self_test_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm dupshift >/dev/null 2>&1
dupx_extracted="$(grep -c '^run_step ' "$fx_self")"
if [[ "$dupx_extracted" == "4" ]]; then
  ok "설명 중복 fixture 의 최상위 run_step 이 4건 (숨은 호출은 추출되지 않음)"
else
  no "설명 중복 fixture 의 최상위 run_step 이 ${dupx_extracted}건입니다 (4건이어야 합니다)"
fi
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/dupx_b_zzfx.sh"
d_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/dupx_err")"; d_rc=$?
d_err="$(cat "$TMP/dupx_err")"
if printf '%s' "$d_out" | grep -qF "full 폴백"; then
  no "설명 중복 케이스가 full 폴백 상태에서 돌았습니다 (아래 단언이 무의미해집니다)"
else
  ok "설명 중복 케이스가 smoke 정상 판정으로 돌았음"
fi
has "설명 중복 fixture 의 스킵 예정 3건" "$d_out" "스킵 예정 스텝 (3개)"
# (i) **이 케이스의 본론** — 변경된 파일 자신의 스텝이 실행되어야 합니다. 순번 3 을 표의
#     다른 자리와 맞춰 일치로 판정하는 약화가 여기서 죽습니다.
has "(i) 변경된 파일 자신의 스텝이 실행됨 (중복 설명에도 물려받은 스킵 없음)" "$d_out" "zzfx-b-ran"
has "(i) 그 순번의 어긋남을 표 설명과 함께 경고" "$d_err" "preflight: '미니 E' / 실제: '미니 D'"
# (ii) 우연히 일치한 순번 2 에서는 어긋남이 드러나지 않으므로, 첫 신고는 **순번 3** 이어야
#      합니다. 여기서 순번을 못박지 않으면 "아무 순번에서든 한 번 경고" 로도 통과합니다.
has "(ii) 첫 어긋남이 순번 3 으로 신고됨" "$d_err" "스텝 순번 3 의 preflight 대응이 어긋났습니다"
d_warn_n="$(printf '%s\n' "$d_err" | grep -c '의 preflight 대응이 어긋났습니다' || true)"
if [[ "$d_warn_n" == "1" ]]; then
  ok "(ii) 어긋남 경고가 첫 1회만 출력됨"
else
  no "(ii) 어긋남 경고가 ${d_warn_n}회 출력됐습니다 (1회여야 합니다)"
fi
# (iii) 밀려난 뒤의 스텝은 전부 실행되고, 손실은 정렬 불명 사유로 요약에 보고됩니다.
has "(iii) 실제 스킵은 1건" "$d_out" "실제 스킵된 스텝 (1개)"
has "(iii) 정렬 불명 이후의 스텝도 전부 실행" "$d_out" "zzfx-e-ran"
has "(iii) 요약이 정렬 불명 사유로 손실을 보고" "$d_err" "순번 3 이후 3개 스텝을 스킵 판정 없이"
if [[ "$d_rc" == "0" ]]; then
  ok "(iv) 순번 어긋남 경고가 판정(rc)을 바꾸지 않음"
else
  no "(iv) 경고가 rc 를 ${d_rc} 로 바꿨습니다 (fail-safe 신고이지 판정이 아닙니다)"
fi
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard "$fx_base_sha19" >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case19" ]]; then
  ok "케이스 19 이후 fixture 이력이 케이스 18 시점으로 원복됨"
else
  no "케이스 19 가 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 왜곡됩니다)"
fi
if [[ "$(grep -c '^run_step ' "$fx_self")" == "$fx_steps_before_case19" ]]; then
  ok "원복 후 fixture self_test.sh 의 스텝 수가 케이스 18 시점과 같음 (${fx_steps_before_case19}개)"
else
  no "원복 후 스텝 수가 ${fx_steps_before_case19}개가 아닙니다 (설명 중복 fixture 가 남았습니다)"
fi

# 19b) **정렬 불명** — 어긋남을 한 번 만난 뒤에는 어떤 스텝도 스킵하지 않아야 합니다.
#
# 케이스 19 는 "어긋난 **그 순번**" 을 지킵니다. 그런데 어긋남은 순번을 **한 칸 밀어내는**
# 사건이라, 밀린 뒤의 순번은 전부 남의 판정을 물려받은 상태입니다. 그 중 하나가 우연히
# 자기 자리 설명과 맞아떨어지면 대조가 통과하고, **변경된 파일 자신의 스텝이 rc=0 ·
# 스킵 요약 완전 일치 · 해당 순번 무경고로 조용히 스킵**됩니다.
#
# 아래 3스텝 fixture 가 그 상태를 만듭니다 (실측으로 확인된 조합입니다).
#   추출 표: 1.`미니 A`(a) · 2.`미니 D`(b, **변경 대상**) · 3.`미니 D`(c)
#   런타임 : 1.`미니 A`(a) · 2.`미니 X`(숨은 호출) · 3.`미니 D`(b) · 4.`미니 D`(c)
#   · 순번 2 에서 어긋남 → 여기서 정렬이 깨집니다.
#   · 순번 3 은 표의 3번 설명(`미니 D`)과 **우연히 일치**해 대조를 통과하고, 3번의 스킵 판정
#     (c 는 무관)을 물려받아 **b 가 스킵**됩니다. 예정 {1,3} == 실제 {1,3} 이라 요약도 조용합니다.
#   · 순번 4 는 표 범위 밖이라 경고는 나오지만 그 스텝은 어차피 실행됩니다.
# 그래서 "그 순번만 살린다" 로는 부족하고, **어긋남 이후 전면 실행**이어야 b 가 살아납니다.
fx_base_sha19b="$(git -C "$FX" rev-parse HEAD)"
fx_log_before_case19b="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
fx_steps_before_case19b="$(grep -c '^run_step ' "$fx_self")"
for _tn in a b c x; do
  printf '#!/usr/bin/env bash\necho "zzfx-t%s-ran"\n' "$_tn" \
    > "$FX/rd-workflow/scripts/trip_${_tn}_zzfx.sh"
done
trip_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$((trip_at - 1))" "$fx_self"
  # 들여쓰기된 호출이라 정적 추출에 잡히지 않습니다 — 순번을 밀어내는 장치입니다.
  printf 'trip_hidden_zzfx() {\n'
  printf '  run_step consumer "미니 X" bash "${SCRIPT_DIR}/trip_x_zzfx.sh"\n'
  printf '}\n'
  printf 'run_step consumer "미니 A" bash "${SCRIPT_DIR}/trip_a_zzfx.sh"\n'
  printf 'trip_hidden_zzfx\n'
  printf 'run_step consumer "미니 D" bash "${SCRIPT_DIR}/trip_b_zzfx.sh"\n'
  printf 'run_step consumer "미니 D" bash "${SCRIPT_DIR}/trip_c_zzfx.sh"\n'
  tail -n "+$trip_at" "$fx_self" | sed '/^run_step /d'
} > "$TMP/trip_self_test_zzfx.sh"
mv "$TMP/trip_self_test_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm tripshift >/dev/null 2>&1
trip_extracted="$(grep -c '^run_step ' "$fx_self")"
if [[ "$trip_extracted" == "3" ]]; then
  ok "정렬 불명 fixture 의 최상위 run_step 이 3건 (숨은 호출은 추출되지 않음)"
else
  no "정렬 불명 fixture 의 최상위 run_step 이 ${trip_extracted}건입니다 (3건이어야 합니다)"
fi
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/trip_b_zzfx.sh"
t_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/trip_err")"; t_rc=$?
t_err="$(cat "$TMP/trip_err")"
if printf '%s' "$t_out" | grep -qF "full 폴백"; then
  no "정렬 불명 케이스가 full 폴백 상태에서 돌았습니다 (아래 단언이 무의미해집니다)"
else
  ok "정렬 불명 케이스가 smoke 정상 판정으로 돌았음"
fi
has "정렬 불명 fixture 의 스킵 예정 2건" "$t_out" "스킵 예정 스텝 (2개)"
# (i) **이 케이스의 본론** — 변경된 파일 자신의 스텝이 실행되어야 합니다. 어긋남 이후
#     전면 실행이 아니면 순번 3 이 대조를 통과해 여기서 b 가 조용히 스킵됩니다.
has "(i) 어긋남 뒤 순번이 우연히 일치해도 변경된 파일 자신의 스텝이 실행됨" "$t_out" "zzfx-tb-ran"
has "(i) 정렬 불명 이후의 남은 스텝도 실행됨" "$t_out" "zzfx-tc-ran"
# (ii) 어긋남 **이전에** 이미 스킵된 건은 되돌릴 수 없으므로 그대로 남습니다 — 0 이 아니라
#      정확히 1건(순번 1)이어야 합니다. "어긋나면 즉시 full 폴백" 으로 만들면 이 건수가
#      0 으로 보고되어 표기가 거짓이 됩니다.
has "(ii) 어긋남 이전 스킵 1건은 그대로 남음" "$t_out" "실제 스킵된 스텝 (1개)"
t_listed="$(printf '%s' "$t_out" | sed -n '/== smoke 스킵 요약 ==/,$p' | grep -c '1\. 미니 A' || true)"
if [[ "$t_listed" == "1" ]]; then
  ok "(ii) 남은 스킵이 순번 1 로 이름과 함께 보고됨"
else
  no "(ii) 스킵 요약의 '1. 미니 A' 가 ${t_listed}건입니다 (1건이어야 합니다)"
fi
# (iii) 경고는 **첫 어긋남에서 1회만** 냅니다. 스텝마다 반복하면 소음이 진짜 신호를 덮습니다.
t_warn_n="$(printf '%s\n' "$t_err" | grep -c '의 preflight 대응이 어긋났습니다' || true)"
if [[ "$t_warn_n" == "1" ]]; then
  ok "(iii) 어긋남 경고가 첫 1회만 출력됨"
else
  no "(iii) 어긋남 경고가 ${t_warn_n}회 출력됐습니다 (1회여야 합니다)"
fi
has "(iii) 첫 어긋남이 순번 2 로 신고됨" "$t_err" "스텝 순번 2 의 preflight 대응이 어긋났습니다"
has "(iii) 이후 전면 실행을 예고" "$t_err" "이후 스텝도 스킵 판정을 조회하지 않고 전부 실행합니다"
# (iv) 요약은 손실을 **반드시** 1줄 보고합니다. 이 보고가 유일한 완화 장치이므로
#      침묵시키면 감축 효과가 rc=0 인 채로 조용히 사라집니다.
has "(iv) 요약이 정렬 불명을 사유로 보고" "$t_err" "smoke 순번 정렬 불명"
has "(iv) 손실 규모(순번·건수)를 함께 보고" "$t_err" "순번 2 이후 3개 스텝을 스킵 판정 없이"
has "(iv) full 재실행을 안내" "$t_err" "self_test.sh full 로 전수 실행"
t_align_n="$(printf '%s\n' "$t_err" | grep -c 'smoke 순번 정렬 불명' || true)"
if [[ "$t_align_n" == "1" ]]; then
  ok "(iv) 정렬 불명 보고가 정확히 1줄"
else
  no "(iv) 정렬 불명 보고가 ${t_align_n}줄입니다 (1줄이어야 합니다)"
fi
# (v) 같은 사건을 두 문구로 신고하지 않습니다 — 사용자가 원인을 오판합니다.
if printf '%s' "$t_err" | grep -qF "스킵 예정(2개)과 실제 스킵(1개)이 다릅니다"; then
  no "(v) 정렬 불명인데 예정 ≠ 실제 경고까지 함께 나왔습니다 (한 사건을 두 문구로 신고합니다)"
else
  ok "(v) 정렬 불명이면 예정 ≠ 실제 경고로 중복 신고하지 않음"
fi
# (vi) 경고는 신고이지 판정이 아닙니다.
if [[ "$t_rc" == "0" ]]; then
  ok "(vi) 정렬 불명이 판정(rc)을 바꾸지 않음"
else
  no "(vi) 정렬 불명이 rc 를 ${t_rc} 로 바꿨습니다 (fail-safe 신고이지 판정이 아닙니다)"
fi
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard "$fx_base_sha19b" >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case19b" ]]; then
  ok "케이스 19b 이후 fixture 이력이 케이스 19 시점으로 원복됨"
else
  no "케이스 19b 가 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 왜곡됩니다)"
fi
if [[ "$(grep -c '^run_step ' "$fx_self")" == "$fx_steps_before_case19b" ]]; then
  ok "원복 후 fixture self_test.sh 의 스텝 수가 케이스 19 시점과 같음 (${fx_steps_before_case19b}개)"
else
  no "원복 후 스텝 수가 ${fx_steps_before_case19b}개가 아닙니다 (정렬 불명 fixture 가 남았습니다)"
fi

# 19c) **표 범위 밖(꼬리) 어긋남** — 예정 == 실제 인데도 손실을 보고해야 합니다.
#
# 두 축을 함께 못박습니다.
#   (a) 표 **범위 밖** 순번에서도 어긋남을 경고합니다. 그 스텝은 어차피 실행되므로 눈에 보이는
#       손실이 없어 보이지만, 꼬리에서만 어긋난 경우에는 그 경고가 유일한 사용자 신호입니다.
#   (b) 정렬 불명 보고가 **예정 ≠ 실제 조건에 딸린 것이 아님**을 고정합니다. 이 fixture 는
#       어긋남이 꼬리에서 나므로 스킵 예정(1) == 실제 스킵(1) 이고 내용도 같습니다 — 즉 기존
#       불일치 경고는 원래 침묵합니다. 정렬 불명 보고를 불일치 블록 **안**에 넣으면 여기서
#       손실이 통째로 조용해지고, rc 가 0 이라 사용자는 감축이 사라진 것을 알 수 없습니다.
#
#   추출 표: 1.`미니 P`(a) · 2.`미니 Q`(b, **변경 대상**)  / 숨은 호출은 **맨 끝**에 둡니다
#   런타임 : 1.`미니 P` · 2.`미니 Q` · 3.`미니 T`(표 길이 2 를 넘는 범위 밖)
fx_base_sha19c="$(git -C "$FX" rev-parse HEAD)"
fx_log_before_case19c="$(git -C "$FX" log --oneline)"
fx_self="$FX/rd-workflow/scripts/self_test.sh"
fx_steps_before_case19c="$(grep -c '^run_step ' "$fx_self")"
for _un in a b t; do
  printf '#!/usr/bin/env bash\necho "zzfx-u%s-ran"\n' "$_un" \
    > "$FX/rd-workflow/scripts/tail_${_un}_zzfx.sh"
done
tail_at="$(grep -n '^run_step ' "$fx_self" | head -1 | cut -d: -f1)"
{
  head -n "$((tail_at - 1))" "$fx_self"
  printf 'tail_hidden_zzfx() {\n'
  printf '  run_step consumer "미니 T" bash "${SCRIPT_DIR}/tail_t_zzfx.sh"\n'
  printf '}\n'
  printf 'run_step consumer "미니 P" bash "${SCRIPT_DIR}/tail_a_zzfx.sh"\n'
  printf 'run_step consumer "미니 Q" bash "${SCRIPT_DIR}/tail_b_zzfx.sh"\n'
  printf 'tail_hidden_zzfx\n'
  tail -n "+$tail_at" "$fx_self" | sed '/^run_step /d'
} > "$TMP/tail_self_test_zzfx.sh"
mv "$TMP/tail_self_test_zzfx.sh" "$fx_self"
git -C "$FX" add -A >/dev/null 2>&1
git -C "$FX" commit -qm tailshift >/dev/null 2>&1
tail_extracted="$(grep -c '^run_step ' "$fx_self")"
if [[ "$tail_extracted" == "2" ]]; then
  ok "꼬리 어긋남 fixture 의 최상위 run_step 이 2건 (숨은 호출은 추출되지 않음)"
else
  no "꼬리 어긋남 fixture 의 최상위 run_step 이 ${tail_extracted}건입니다 (2건이어야 합니다)"
fi
printf '\n# 변경\n' >> "$FX/rd-workflow/scripts/tail_b_zzfx.sh"
u_out="$(env -u RD_SELFTEST_SMOKE_DRYRUN bash "$fx_self" 2>"$TMP/tail_err")"; u_rc=$?
u_err="$(cat "$TMP/tail_err")"
if printf '%s' "$u_out" | grep -qF "full 폴백"; then
  no "꼬리 어긋남 케이스가 full 폴백 상태에서 돌았습니다 (아래 단언이 무의미해집니다)"
else
  ok "꼬리 어긋남 케이스가 smoke 정상 판정으로 돌았음"
fi
has "꼬리 어긋남 fixture 의 스킵 예정 1건" "$u_out" "스킵 예정 스텝 (1개)"
# (a) 범위 밖 순번의 경고 — 표 설명은 '(없음)' 으로 보고됩니다.
has "(a) 표 범위 밖 순번에서도 어긋남을 경고" "$u_err" "스텝 순번 3 의 preflight 대응이 어긋났습니다"
has "(a) 범위 밖은 표 설명 없음으로 보고" "$u_err" "preflight: '(없음)' / 실제: '미니 T'"
has "(a) 꼬리 스텝이 실제로 실행됨" "$u_out" "zzfx-ut-ran"
# (b) 양성 대조 — 예정 == 실제 == 1건이고 내용도 같은 상태임을 먼저 확정합니다. 이것이
#     없으면 아래 단언이 "그저 불일치가 있었을 뿐" 으로도 통과합니다.
has "(b) 예정과 실제가 모두 1건 (기존 불일치 경고는 침묵하는 상태)" "$u_out" "실제 스킵된 스텝 (1개)"
if printf '%s' "$u_err" | grep -qF "이 다릅니다"; then
  no "(b) 예정 == 실제 인데 불일치 경고가 나왔습니다 (양성 대조 전제가 깨졌습니다)"
else
  ok "(b) 예정 == 실제 이므로 불일치 경고는 침묵"
fi
has "(b) 그래도 정렬 불명으로 손실을 보고" "$u_err" "smoke 순번 정렬 불명"
has "(b) 손실 규모(순번 3 이후 1개)를 함께 보고" "$u_err" "순번 3 이후 1개 스텝을 스킵 판정 없이"
if [[ "$u_rc" == "0" ]]; then
  ok "(c) 꼬리 어긋남이 판정(rc)을 바꾸지 않음"
else
  no "(c) 꼬리 어긋남이 rc 를 ${u_rc} 로 바꿨습니다 (fail-safe 신고이지 판정이 아닙니다)"
fi
if [[ "$FX" == "$TMP/"* ]]; then
  git -C "$FX" reset --hard "$fx_base_sha19c" >/dev/null 2>&1
else
  no "fixture 경로가 임시 디렉터리 밖입니다 — reset 을 수행하지 않았습니다: $FX"
fi
if [[ "$(git -C "$FX" log --oneline)" == "$fx_log_before_case19c" ]]; then
  ok "케이스 19c 이후 fixture 이력이 케이스 19b 시점으로 원복됨"
else
  no "케이스 19c 가 fixture 를 오염시킨 채 남았습니다 (뒤따르는 케이스가 왜곡됩니다)"
fi
if [[ "$(grep -c '^run_step ' "$fx_self")" == "$fx_steps_before_case19c" ]]; then
  ok "원복 후 fixture self_test.sh 의 스텝 수가 케이스 19b 시점과 같음 (${fx_steps_before_case19c}개)"
else
  no "원복 후 스텝 수가 ${fx_steps_before_case19c}개가 아닙니다 (꼬리 어긋남 fixture 가 남았습니다)"
fi

# 19b) **full 시작 시점의 untracked 사전 경고**
#
# 기록 거부 사유(untracked 존재)는 시작 시점에 **이미 확정**입니다. 종료 시점에만 알리면
# 사용자는 수 분을 쓰고 나서야 증명이 남지 않는다는 것을 알고, git add 후 같은 시간을
# 다시 써야 합니다. dry-run 은 스텝을 하나도 실행하지 않지만 이 경고는 첫 스텝 **전에**
# 나오므로 여기서 관측할 수 있습니다.
printf 'stray\n' > "$FX/untracked_warn_zzfx.sh"
uw_out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" full 2>"$TMP/uw_err")" || true
uw_err="$(cat "$TMP/uw_err")"
has "full 시작 시 untracked 사전 경고" "$uw_err" "이대로는 full PASS 기록이 남지 않습니다"
has "경고가 원인 파일을 지목" "$uw_err" "untracked_warn_zzfx.sh"
# stdout 형식을 오염시키면 그 출력을 파싱하는 다른 계약이 함께 깨집니다.
if printf '%s' "$uw_out" | grep -qF "untracked_warn_zzfx.sh"; then
  no "untracked 경고가 stdout 으로 샜습니다"
else
  ok "untracked 경고는 stderr 로만 나감"
fi
# untracked 가 없으면 경고도 없어야 합니다 — 늘 내는 경고는 경보 가치를 잃습니다.
rm -f "$FX/untracked_warn_zzfx.sh"
uw_err2="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" full 2>&1 >/dev/null)"
if printf '%s' "$uw_err2" | grep -qF "이대로는 full PASS 기록이 남지 않습니다"; then
  no "untracked 가 없는데 경고가 나왔습니다"
else
  ok "untracked 가 없으면 경고 없음"
fi
# smoke 는 기록 자체를 하지 않으므로 이 경고도 내지 않아야 합니다.
printf 'stray\n' > "$FX/untracked_warn_zzfx.sh"
uw_err3="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$FX/rd-workflow/scripts/self_test.sh" 2>&1 >/dev/null)"
if printf '%s' "$uw_err3" | grep -qF "이대로는 full PASS 기록이 남지 않습니다"; then
  no "smoke 실행에서 full 기록 경고가 나왔습니다"
else
  ok "smoke 에서는 기록 경고 없음"
fi
rm -f "$FX/untracked_warn_zzfx.sh"
# 조회 실패(git 오류)도 기록 거부 사유입니다. 여기서만 침묵하면 이 경고가 없애려던 손실
# (수 분을 쓰고 나서야 증명이 남지 않는다는 것을 아는 것)이 이 경로에 그대로 남습니다.
UWFAKE="$TMP/uw_fakebin"; mkdir -p "$UWFAKE"
cat > "$UWFAKE/git" <<'UWG'
#!/usr/bin/env bash
real="$(PATH="$UW_REAL_PATH" command -v git)"
case "$*" in *"ls-files --others"*) exit 3 ;; esac
exec "$real" "$@"
UWG
chmod +x "$UWFAKE/git"
uw_err4="$(UW_REAL_PATH="$PATH" PATH="$UWFAKE:$PATH" RD_SELFTEST_SMOKE_DRYRUN=1 \
  bash "$FX/rd-workflow/scripts/self_test.sh" full 2>&1 >/dev/null)" || true
has "untracked 조회 실패도 시작 시점에 알림" "$uw_err4" "untracked 조회에 실패해"

# 19d) **기록 호출이 시작 시점 untracked 상태를 함께 넘기는가** (호출 형태 계약)
#
# 종료 시점만 보면 실행 중에 생겼다 사라진 파일이 흔적을 남기지 않아, 그 상태를 가린 채
# PASS 가 기록되고 index 모드가 그 증명을 그대로 소비합니다(생략의 근거가 이 기록 조건입니다).
# 이 축은 full 을 실제로 돌려야만 행동으로 관측되는데 그 비용이 수 분이라, **호출부의 형태**로
# 못박습니다. 리터럴 `0` 을 넘기는 회귀도 여기서 함께 죽습니다.
if grep -qF 'smoke_record_full_pass "$SELFTEST_ROOT" "$SELFTEST_START_FP" "$SELFTEST_START_USTATE"' "$SELF"; then
  ok "full 기록 호출이 시작 지문과 시작 untracked 상태를 함께 넘김"
else
  no "full 기록 호출이 시작 시점 untracked 상태를 넘기지 않습니다 (기록 시점만 보는 구멍이 되살아납니다)"
fi

# 20) **절대 앵커** — 원복 사슬이 통째로 미끄러지는 것을 막습니다.
#
# 각 케이스는 "자기 직전 시점" 을 캡처해 대조합니다. 그래서 원복을 빠뜨린 케이스가 중간에
# 삽입되면 그 오염이 다음 케이스의 기준선으로 흡수되어 **모든 원복 단언이 그대로 통과**
# 합니다. 상대 대조만으로는 사슬 전체가 밀린 것을 알 수 없으므로, 스위트 끝에서 fixture 를
# 절대 기준과 맞춰 봅니다.
fx_final_log="$(git -C "$FX" log --oneline --format='%s' | tr '\n' ' ')"
if [[ "$fx_final_log" == "canonical init " ]]; then
  ok "스위트 종료 시 fixture 이력이 절대 기준과 일치 (canonical + init 2개)"
else
  no "스위트 종료 시 fixture 이력이 '${fx_final_log}' 입니다 (원복을 빠뜨린 케이스가 있습니다)"
fi
fx_final_dirty="$(git -C "$FX" status --porcelain | wc -l | tr -d ' ')"
if [[ "$fx_final_dirty" == "0" ]]; then
  ok "스위트 종료 시 fixture 워킹트리가 깨끗함"
else
  no "스위트 종료 시 fixture 워킹트리에 ${fx_final_dirty}건이 남았습니다 (정리를 빠뜨린 케이스가 있습니다)"
fi
canon_steps="$(grep -c '^run_step ' "$SELF")"
fx_final_steps="$(grep -c '^run_step ' "$FX/rd-workflow/scripts/self_test.sh")"
if [[ "$fx_final_steps" == "$canon_steps" ]]; then
  ok "스위트 종료 시 fixture self_test.sh 의 스텝 수가 정본과 동일 (${canon_steps}개)"
else
  no "스위트 종료 시 fixture 스텝 수 ${fx_final_steps} 가 정본 ${canon_steps} 와 다릅니다 (최소 fixture 가 남았습니다)"
fi

# =============================================================================
# 청중(audience) 계약 — AC 1·2·3·4·5·9 · spec §6.2·§6.3
# =============================================================================
# 정본 등록부를 **실행하지 않고** 정적으로 봅니다 (AC 2·3).
aud_raw="$(grep -c '^run_step ' "$SELF")"
aud_declared="$(sed -n 's/^run_step \([a-z-]*\) "\([^"]*\)".*/\1/p' "$SELF" | grep -c .)"
aud_dev="$(sed -n 's/^run_step \([a-z-]*\) "\([^"]*\)".*/\1/p' "$SELF" | grep -c '^dev-only$')"
aud_con="$(sed -n 's/^run_step \([a-z-]*\) "\([^"]*\)".*/\1/p' "$SELF" | grep -c '^consumer$')"

# AC 2 — 청중 미선언 스텝이 0건. 미선언 호출은 추출식에 매치되지 않으므로 두 수의 차이가
# 곧 미선언 건수입니다. 사람이 눈으로 세는 것으로 갈음하지 않습니다.
if [[ "$aud_raw" == "$aud_declared" ]]; then
  ok "청중 미선언 스텝 0건 (등록 ${aud_raw}건 전부 선언)"
else
  no "청중 미선언 스텝이 $((aud_raw - aud_declared))건 있습니다 (등록 ${aud_raw} / 선언 ${aud_declared})"
fi
# 허용값 밖의 청중이 등록부에 없어야 합니다 (추출식의 `[a-z-]*` 는 임의 소문자를 받습니다).
aud_bad="$(sed -n 's/^run_step \([a-z-]*\) "\([^"]*\)".*/\1/p' "$SELF" | grep -vc '^\(consumer\|dev-only\)$' || true)"
if [[ "$aud_bad" == "0" ]]; then ok "등록부의 청중 값이 모두 consumer|dev-only"; else no "허용값 밖의 청중이 ${aud_bad}건 있습니다"; fi

# AC 3 — **exact `dev-only` 집합**을 고정합니다. `consumer` 는 여집합으로 계산합니다
# (이진 enum + 총건수 + 미선언 0 검사와 합치면 42쌍 전량 대조와 동치).
#
# 이것은 의도된 트립와이어입니다. 청중 오분류는 **rc 를 바꾸지 않는 방향으로** 위험합니다 —
# consumer 를 dev-only 로 잘못 옮기면 소비처 검증이 조용히 약해지고 아무 신호도 나지 않습니다.
# **스크립트 이름의 `.sh` 를 떼어 적습니다.** 실재하지 않는 이름(`build_template` 등은
# 이 트리가 아니라 dev 저장소 `scripts/` 에 있습니다)을 `*.sh` 리터럴로 박으면 참조 폐포
# 판정이 그것을 "이미 커버됨" 으로 읽어 그 이름의 신규 파일에 대한 무매핑 fail-safe 를
# 무력화합니다 (fixture 이름 규약이 막는 바로 그 오염입니다). 비교할 때 실제 설명에서도
# 같은 방식으로 떼어 냅니다.
AUD_DEVONLY_EXPECTED="smoke 판정 단위 테스트 (test_smoke_common)
smoke fixture 이름 규약 (check_fixture_name_convention)
판정 소스 회귀 grep (_extract_task_section Status 직접 호출)
stale active-fr/LIFECYCLE_METADATA_PATH 참조 회귀
adapter 폴링 잔존 회귀 (POLL_INTERVAL 없음)
autopilot SKILL lifecycle 정합 (promote/rollback 일원화)
무인 진입 계약 정합 (autopilot_headless_entry_check)
phase 병렬 규약 문서 정합 (plan_parallel_phase_check)
hook 표기 회귀 방지 (hook_path_notation_regression_check)
템플릿 build 검증 (build_template verify)
템플릿 빌더 단위 테스트 (test_build_template)
배포 미러 계약 (test_publish_mirror)
생성 full 트리 결함 보고 회귀 (generated_tree_defect_reports_check)"
aud_devonly_actual="$(sed -n 's/^run_step dev-only "\([^"]*\)".*/\1/p' "$SELF" | sed 's/\.sh//g')"
if [[ "$aud_devonly_actual" == "$AUD_DEVONLY_EXPECTED" ]]; then
  ok "dev-only exact 집합 일치 (${aud_dev}건)"
else
  no "dev-only 집합이 기대와 다릅니다 — 청중 분류가 바뀌었다면 spec §3 정본 표와 이 목록을 함께 고치십시오"
  diff <(printf '%s\n' "$AUD_DEVONLY_EXPECTED") <(printf '%s\n' "$aud_devonly_actual") | sed 's/^/    /' >&2 || true
fi
eq "consumer 는 dev-only 의 여집합" "$aud_con" "$((aud_raw - aud_dev))"

# AC 4 — 상태표: 모드별 실행 예정 건수. AC 9 — 배너에 청중·실행·제외·이유 표시.
out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$SELF" consumer 2>&1)"; rc=$?
if [[ "$rc" == "0" ]]; then ok "dry-run consumer exit 0"; else no "dry-run consumer exit $rc"; fi
has "배너: consumer 모드 표시" "$out" "모드: consumer"
has "배너: 실행 예정/청중 제외 건수" "$out" "실행 예정: ${aud_con}스텝 / 청중 제외: ${aud_dev}스텝"
has "배너: 제외 이유 표시" "$out" "제외 이유: dev-only"
has "배너: 전수 검증이 아님을 명시" "$out" "전수 검증이 아닙니다"
has "요약: 청중 제외 목록" "$out" "청중 제외된 스텝 (${aud_dev}개)"
eq "consumer 실행 예정 스텝 수" "$(printf '%s' "$out" | sed -n 's/^== 실행 예정 스텝 (\([0-9]*\)개) ==$/\1/p')" "$aud_con"
# `consumer` 는 smoke preflight 에 들어가지 않아야 합니다 (spec §6.1).
if printf '%s' "$out" | grep -qE "폴백|스킵 요약"; then no "consumer 실행에 smoke 폴백/스킵 문구가 나옵니다 (preflight 에 들어갔습니다)"; else ok "consumer 는 smoke preflight 에 들어가지 않음"; fi

out="$(RD_SELFTEST_SMOKE_DRYRUN=1 bash "$SELF" full 2>&1)"
eq "full 실행 예정 스텝 수" "$(printf '%s' "$out" | sed -n 's/^== 실행 예정 스텝 (\([0-9]*\)개) ==$/\1/p')" "$aud_raw"
has "배너: full 은 두 청중 모두" "$out" "청중 두 종류 모두"
if printf '%s' "$out" | grep -qF "청중 제외 요약"; then no "full 인데 청중 제외 요약이 나옵니다"; else ok "full 은 청중 제외 요약 없음"; fi

# --- 청중 fixture (AC 1 · 5 · 6.2 · 6.3) -------------------------------------
# 합성 스텝 2개만 남긴 최소 fixture 를 별 저장소에 만듭니다. 정본 FX 를 건드리지 않아
# 스위트 종료 시의 "fixture 스텝 수 == 정본" 불변이 유지됩니다.
AUDFX="$TMP/audfx"
mkdir -p "$AUDFX/rd-workflow"
cp -R "${SCRIPT_DIR}" "$AUDFX/rd-workflow/scripts"
git -C "$AUDFX" init -q .
git -C "$AUDFX" config user.email zzfx@example.com
git -C "$AUDFX" config user.name zzfx
aud_self="$AUDFX/rd-workflow/scripts/self_test.sh"
printf '#!/usr/bin/env bash\necho zzfx-aud-a-ran\nexit 0\n' > "$AUDFX/rd-workflow/scripts/aud_a_zzfx.sh"
# **실패하는 dev-only 스텝**입니다. marker 를 먼저 찍고 실패하므로 "실행 가능한 상태였다" 가
# 증명됩니다 — marker 없이 rc 만 보면 "실행되지 않아서 실패도 없었다" 와 구분되지 않습니다.
printf '#!/usr/bin/env bash\necho zzfx-aud-d-ran\nexit 1\n' > "$AUDFX/rd-workflow/scripts/aud_d_zzfx.sh"
aud_at="$(grep -n '^run_step ' "$aud_self" | head -1 | cut -d: -f1)"
{
  head -n "$((aud_at - 1))" "$aud_self"
  printf 'run_step consumer "청중 A" bash "${SCRIPT_DIR}/aud_a_zzfx.sh"\n'
  printf 'run_step dev-only "청중 D" bash "${SCRIPT_DIR}/aud_d_zzfx.sh"\n'
  tail -n "+$aud_at" "$aud_self" | sed '/^run_step /d'
} > "$aud_self.new" && mv "$aud_self.new" "$aud_self"
git -C "$AUDFX" add -A >/dev/null 2>&1
git -C "$AUDFX" commit -q -m "aud fixture" >/dev/null 2>&1
eq "청중 fixture 의 최상위 run_step 이 2건" "$(grep -c '^run_step ' "$aud_self")" "2"

AUD_FULLC="$AUDFX/rd-workflow-workspace/.lifecycle/selftest-full-cache"
AUD_CONC="$AUDFX/rd-workflow-workspace/.lifecycle/selftest-consumer-cache"

# AC 5(c)(d) — **같은 fixture·같은 스텝을 두 모드로 대조**합니다.
out="$(bash "$aud_self" full 2>&1)"; rc=$?
has "(full) dev-only 스텝이 실행됨 (marker)" "$out" "zzfx-aud-d-ran"
has "(full) consumer 스텝도 실행됨 (marker)" "$out" "zzfx-aud-a-ran"
if [[ "$rc" != "0" ]]; then ok "(full) dev-only 실패가 rc 에 반영됨 (rc=$rc)"; else no "(full) dev-only 가 실패했는데 rc=0 입니다"; fi

out="$(bash "$aud_self" consumer 2>&1)"; rc=$?
has "(consumer) consumer 스텝이 실제로 실행됨 (marker)" "$out" "zzfx-aud-a-ran"
if printf '%s' "$out" | grep -qF "zzfx-aud-d-ran"; then
  no "(consumer) dev-only 스텝이 실행되었습니다 (청중 필터가 동작하지 않았습니다)"
else
  ok "(consumer) dev-only 스텝은 실행되지 않음 (marker 없음)"
fi
if [[ "$rc" == "0" ]]; then ok "(consumer) dev-only 실패가 rc 를 오염시키지 않음 (rc=0)"; else no "(consumer) rc=$rc — dev-only 실패가 새어 들어왔습니다"; fi
if [[ -s "$AUD_CONC" ]]; then ok "(consumer) consumer 증명을 기록"; else no "(consumer) consumer 증명이 기록되지 않았습니다"; fi
if [[ -e "$AUD_FULLC" ]]; then no "(consumer) full 증명 파일이 생겼습니다 (부분 실행이 전수 통과로 위장)"; else ok "(consumer) full 증명 파일은 건드리지 않음"; fi
# consumer 캐시가 **자기 증명을 무효화하지 않아야** 합니다.
# **두 축을 따로 봅니다** — (a) proof 제외 목록(`smoke_proof_exclude`)과 (b) git 의
# `.gitignore`. 어느 하나만 있어도 사용자는 막힙니다: (a) 가 없으면 증명이 스스로를
# 무효화하고, (b) 가 없으면 archive 의 선행 clean 검사에서 걸립니다.
#
# `git status --porcelain` 은 새 untracked **디렉터리를 `?? rd-workflow-workspace/` 로 축약**
# 하므로, 그 출력에서 파일명을 grep 하는 단언은 캐시가 전혀 ignore 되지 않아도 통과합니다
# (구현 중 실제로 공허했습니다). 그래서 정확한 경로로 관측합니다.
aud_cache_rel="rd-workflow-workspace/.lifecycle/selftest-consumer-cache"
# (a) proof 제외 축
aud_us=0; ( cd "$AUDFX" && . rd-workflow/scripts/_smoke_common.sh && smoke_untracked_state "$AUDFX" >/dev/null 2>&1 ) || aud_us=$?
if [[ "$aud_us" == "0" ]]; then ok "(proof 제외 축) consumer 캐시가 untracked 판정에 잡히지 않음"; else no "(proof 제외 축) consumer 캐시가 untracked 로 잡힙니다 — 증명이 자기를 무효화"; fi
# (b) .gitignore 축 — 배포될 `.gitignore` 를 fixture 에 설치한 뒤 `git check-ignore` 로 직접 봅니다.
aud_gi_src="${SCRIPT_DIR}/../../.gitignore"
if [[ -f "$aud_gi_src" ]]; then
  cp "$aud_gi_src" "$AUDFX/.gitignore"
  if git -C "$AUDFX" check-ignore -q "$aud_cache_rel"; then
    ok "(.gitignore 축) consumer 캐시 본체가 ignore 됨"
  else
    no "(.gitignore 축) consumer 캐시 본체가 ignore 되지 않습니다 (archive 의 clean 검사에서 막힙니다)"
  fi
  if git -C "$AUDFX" check-ignore -q "${aud_cache_rel}.tmpXYZ"; then
    ok "(.gitignore 축) 원자 기록 임시 파일도 ignore 됨"
  else
    no "(.gitignore 축) 원자 기록 임시 파일이 ignore 되지 않습니다"
  fi
  # 반대 방향 — `.lifecycle` 밖의 같은 이름은 ignore 되면 안 됩니다 (패턴 과다 확장 방지).
  if git -C "$AUDFX" check-ignore -q "selftest-consumer-cache"; then
    no "(.gitignore 축) .lifecycle 밖 동명 파일까지 ignore 됩니다 (패턴이 과하게 넓습니다)"
  else
    ok "(.gitignore 축) .lifecycle 밖 동명 파일은 ignore 되지 않음"
  fi
  rm -f "$AUDFX/.gitignore"
else
  ok "배포 .gitignore 를 찾을 수 없어 .gitignore 축 검증 건너뜀 (설치본)"
fi

# AC 1 — 청중 누락·허용값 밖은 **FAIL** 입니다 (조용한 skip 이 아닙니다).
#
# **원인을 격리한 fixture 를 씁니다.** 파일 끝에 잘못된 호출을 붙이면 최종 판정 `exit` 뒤라
# 실행되지 않고, rc≠0 은 다른 스텝의 실패에서 옵니다 — 단언이 공허해집니다(구현 중 실측).
# 그래서 통과하는 스텝 하나 + 잘못된 호출 하나만 남긴 별 fixture 를 만들어, rc≠0 의 원인이
# 청중 오류일 수밖에 없게 만듭니다.
aud_mk_bad() { # aud_mk_bad <fixture 경로> <잘못된 run_step 줄>
  local dst="$1" bad="$2" at
  cp -R "$AUDFX" "$dst"
  local dself="$dst/rd-workflow/scripts/self_test.sh"
  at="$(grep -n '^run_step ' "$dself" | head -1 | cut -d: -f1)"
  {
    head -n "$((at - 1))" "$dself"
    printf 'run_step consumer "정상 스텝" bash "${SCRIPT_DIR}/aud_a_zzfx.sh"\n'
    printf '%s\n' "$bad"
    tail -n "+$at" "$dself" | sed '/^run_step /d'
  } > "$dself.new" && mv "$dself.new" "$dself"
  printf '%s\n' "$dself"
}

bad1_self="$(aud_mk_bad "$TMP/audbad1" 'run_step "청중 없음" true')"
eq "청중 누락 fixture 의 최상위 run_step 이 2건" "$(grep -c '^run_step ' "$bad1_self")" "2"
out="$(bash "$bad1_self" full 2>&1)"; rc=$?
if [[ "$rc" != "0" ]]; then ok "청중 누락 → rc≠0"; else no "청중 누락인데 rc=0 입니다 (조용히 통과)"; fi
has "청중 누락 사유 표시" "$out" "청중이 없거나 허용값이 아닙니다"
# 정상 스텝은 실행돼야 합니다 — rc≠0 이 "아무것도 안 돌았다" 가 아님을 못박습니다.
has "청중 누락 케이스에서도 정상 스텝은 실행됨" "$out" "zzfx-aud-a-ran"

bad2_self="$(aud_mk_bad "$TMP/audbad2" 'run_step bogus "허용값 밖" true')"
out="$(bash "$bad2_self" full 2>&1)"; rc=$?
if [[ "$rc" != "0" ]]; then ok "허용값 밖 청중 → rc≠0"; else no "허용값 밖인데 rc=0 입니다"; fi
has "허용값 밖 사유 표시" "$out" "청중이 없거나 허용값이 아닙니다"

# 대조군 — 같은 fixture 형태에서 청중이 올바르면 rc=0 이어야 합니다. 이것이 없으면 위 두
# 단언이 "이 fixture 는 무슨 이유로든 실패한다" 와 구분되지 않습니다.
good_self="$(aud_mk_bad "$TMP/audgood" 'run_step consumer "또 하나의 정상 스텝" true')"
out="$(bash "$good_self" full 2>&1)"; rc=$?
if [[ "$rc" == "0" ]]; then ok "대조군: 청중이 올바르면 rc=0 (위 단언이 공허하지 않음)"; else no "대조군 fixture 가 rc=$rc 로 실패합니다 — 위 두 단언의 원인 격리가 깨졌습니다"; fi

# Finding 2 회귀 — 시작 경고가 **실행 모드에 맞는 증명 이름**을 말해야 합니다.
# `consumer` 실행인데 "full PASS 기록" 이라고 하면, 이 변경의 핵심(dev-only 는 강제하지
# 않는다)이 가시성이 가장 필요한 순간에 깨집니다.
aud_untracked_probe="$AUDFX/untracked_probe_zzfx.sh"
printf 'echo probe\n' > "$aud_untracked_probe"
out="$(bash "$aud_self" consumer 2>&1)" || true
has "(consumer) untracked 경고가 consumer 증명을 가리킴" "$out" "consumer PASS 기록이 남지 않습니다"
if printf '%s' "$out" | grep -qF "full PASS 기록이 남지 않습니다"; then
  no "(consumer) untracked 경고가 여전히 full 이라고 말합니다"
else
  ok "(consumer) untracked 경고에 full 표현이 남지 않음"
fi
out="$(bash "$aud_self" full 2>&1)" || true
has "(full) untracked 경고가 full 증명을 가리킴" "$out" "full PASS 기록이 남지 않습니다"
rm -f "$aud_untracked_probe"

# spec §6.3 — dry-run 은 **어떤 모드에서도 증명을 만들지 않습니다.**
# 현행은 dry-run 블록의 exit 0 이 기록 지점보다 앞이라 구조적으로 성립하지만, 기록 지점을
# 앞으로 옮기는 변경이 조용히 깨뜨릴 수 있으므로 계약으로 고정합니다.
rm -f "$AUD_CONC" "$AUD_FULLC"
RD_SELFTEST_SMOKE_DRYRUN=1 bash "$aud_self" consumer >/dev/null 2>&1 || true
if [[ -e "$AUD_CONC" ]]; then no "dry-run consumer 가 증명을 만들었습니다"; else ok "dry-run consumer 는 증명을 만들지 않음"; fi
RD_SELFTEST_SMOKE_DRYRUN=1 bash "$aud_self" full >/dev/null 2>&1 || true
if [[ -e "$AUD_FULLC" ]]; then no "dry-run full 이 증명을 만들었습니다"; else ok "dry-run full 은 증명을 만들지 않음"; fi

# spec §6.2 — `_smoke_common.sh` 부재 시 `consumer` 는 **즉시 실패**합니다.
# 기존 동작이 full 폴백이라 가장 쉽게 되살아나는 경계입니다.
mv "$AUDFX/rd-workflow/scripts/_smoke_common.sh" "$AUDFX/_smoke_common.sh.hidden"
out="$(bash "$aud_self" consumer 2>&1)"; rc=$?
if [[ "$rc" != "0" ]]; then ok "(헬퍼 부재) consumer → rc≠0"; else no "(헬퍼 부재) consumer 가 rc=0 으로 끝났습니다 (조용한 full 확대)"; fi
has "(헬퍼 부재) 사유 표시" "$out" "증명"
has "(헬퍼 부재) full 대안 안내" "$out" "self_test.sh full"
if printf '%s' "$out" | grep -qF "zzfx-aud-d-ran"; then no "(헬퍼 부재) consumer 가 dev-only 까지 실행했습니다 (full 로 확대)"; else ok "(헬퍼 부재) 스텝을 실행하지 않고 중단"; fi
if [[ -e "$AUD_CONC" || -e "$AUD_FULLC" ]]; then no "(헬퍼 부재) 증명 파일이 생겼습니다"; else ok "(헬퍼 부재) 증명 파일 무변경"; fi
mv "$AUDFX/_smoke_common.sh.hidden" "$AUDFX/rd-workflow/scripts/_smoke_common.sh"

# =============================================================================
# CLAUDE.md 크기 검사 — 판정 행렬 (AC 8)
# =============================================================================
# 검사기를 **직접** 호출합니다 (`self_test.sh` 의 `claudemd_size_check` 래퍼를 거치지 않음).
#
# 이 검사기는 원래 `<root>/CLAUDE.md` 만 봤습니다. 배포되는 것은 `_ROOT_FILES/CLAUDE.md` 이므로
# 정본이 제한을 넘겨도 dev self_test 는 통과하고 **소비 프로젝트에서만** 터졌습니다.
# 그래서 "통과함" 확인만으로는 불충분하고, **초과 시 실제로 실패하는지**를 봐야 합니다.
CMD_CHECKER="${SCRIPT_DIR}/check_claudemd_size.sh"
if [[ ! -f "$CMD_CHECKER" ]]; then
  ok "check_claudemd_size.sh 없음 — 크기 검사 행렬 건너뜀 (lite 산출물)"
else
  cmd_case() { # cmd_case <라벨> <프로젝트 줄수|-> <정본 줄수|-> <기대rc>
    local label="$1" proj="$2" tpl="$3" want="$4" d rc
    d="$TMP/cmdsz_$RANDOM"
    mkdir -p "$d/rd-workflow/scripts"
    cp "$CMD_CHECKER" "$d/rd-workflow/scripts/"
    [[ "$proj" == "-" ]] || seq "$proj" > "$d/CLAUDE.md"
    if [[ "$tpl" != "-" ]]; then mkdir -p "$d/_ROOT_FILES"; seq "$tpl" > "$d/_ROOT_FILES/CLAUDE.md"; fi
    bash "$d/rd-workflow/scripts/check_claudemd_size.sh" >/dev/null 2>&1 && rc=0 || rc=1
    if [[ "$rc" == "$want" ]]; then ok "크기 검사 — ${label}"; else no "크기 검사 — ${label} (rc=$rc, 기대 $want)"; fi
    rm -rf "$d"
  }
  # REQUIRED 부재는 rc=1 입니다. 예전에는 안내만 하고 exit 0 이었는데, 그것은 이름만 필수이고
  # 동작은 fail-open 이라 "검사했다" 는 신호를 거짓으로 만듭니다.
  cmd_case "REQUIRED 부재 → 실패"            -   -   1
  cmd_case "정상 / OPTIONAL 부재 → 통과"     10  -   0
  cmd_case "정상 / 정본 초과 → 실패"         10  201 1
  cmd_case "프로젝트 초과 / 정본 정상 → 실패" 201 10  1
  cmd_case "둘 다 정상 → 통과"               10  20  0
  cmd_case "둘 다 초과 → 실패"               201 201 1
  # 경계값 — 제한과 같은 줄 수는 통과입니다 (`-gt` 판정).
  cmd_case "정본이 제한과 동률 → 통과"        10  200 0

  # 실패 이유가 **어느 파일 때문인지** 사용자에게 보여야 합니다. 파일이 둘이라 이유 없이
  # 실패하면 어디를 줄여야 할지 알 수 없습니다.
  cmd_d="$TMP/cmdsz_reason"
  mkdir -p "$cmd_d/rd-workflow/scripts" "$cmd_d/_ROOT_FILES"
  cp "$CMD_CHECKER" "$cmd_d/rd-workflow/scripts/"
  seq 10 > "$cmd_d/CLAUDE.md"; seq 201 > "$cmd_d/_ROOT_FILES/CLAUDE.md"
  out="$(bash "$cmd_d/rd-workflow/scripts/check_claudemd_size.sh" 2>&1 || true)"
  has "크기 검사 — 실패 이유에 배포 정본 표시" "$out" "배포 정본"
  has "크기 검사 — 파일별 줄 수 표시" "$out" "201줄"
  has "크기 검사 — 실패 이유 블록" "$out" "실패 이유"
  rm -rf "$cmd_d"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then echo "test_self_test_smoke: PASS"; exit 0; else echo "test_self_test_smoke: FAIL" >&2; exit 1; fi
