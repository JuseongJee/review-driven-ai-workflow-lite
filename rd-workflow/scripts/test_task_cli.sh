#!/usr/bin/env bash
# test_task_cli.sh — rd task CLI 단위 테스트 (self_test.sh가 실행)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD="${SCRIPT_DIR}/rd"
FAIL=0
t() { # t <설명> <기대exit> <기대stdout|-> cmd...
  local desc="$1" want_rc="$2" want_out="$3"; shift 3
  local out rc
  out="$("$@" 2>/dev/null)"; rc=$?
  if [[ "$rc" != "$want_rc" ]]; then echo "FAIL: $desc (exit $rc != $want_rc)"; FAIL=1; return; fi
  if [[ "$want_out" != "-" && "$out" != "$want_out" ]]; then echo "FAIL: $desc (out '$out' != '$want_out')"; FAIL=1; return; fi
  echo "ok: $desc"
}
mk_task_file() { # mk_task_file <dir> <status> <short-title>
  cat > "$1/CURRENT_TASK.md" <<EOF
# Current Task

## Task
test

## Short Title
$3

## Status
$2

## Request
[REQUEST.md](REQUEST.md)

## Notes
-
EOF
  # v2 2b: task-state도 함께 갱신 (task-state가 권위 소스 — 결정 1/3)
  # canonical 8종이 아닌 값(손상 테스트용)은 task-state를 생성하지 않음
  local _ts_dir="$1/rd-workflow-workspace/.lifecycle"
  mkdir -p "$_ts_dir"
  # canonical 여부 판정: 기존 STATE_CANONICAL_STATUSES 파이프 문자열 사용 가능하지만
  # 함수 환경이 없으므로 직접 case 로 처리
  case "$2" in
    "대기 중"|"REQUEST review 대기"|"spec/plan 작성 중"|"spec/plan review 대기"|\
    "구현 중"|"검증 중"|"diff review 대기"|"완료"|"실행 중")
      # canonical 또는 legacy alias → task-state 생성
      local _ts_status="$2"
      # legacy alias '실행 중' → canonical '구현 중' 으로 정규화 (마이그레이션 계약)
      [[ "$_ts_status" == "실행 중" ]] && _ts_status="구현 중"
      cat > "$_ts_dir/task-state" <<TSEOF
schema=1
short-title=$3
status=${_ts_status}
fr-branch=null
worktree-path=null
source-fr=-
TSEOF
      ;;
    *)
      # 비canonical(손상) status → task-state 파일 삭제 (손상 시나리오 테스트용)
      rm -f "$_ts_dir/task-state"
      ;;
  esac
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export project_root="$TMP"
mk_task_file "$TMP" "구현 중" "my-task"

t "status 읽기" 0 "구현 중" bash "$RD" task status
t "title 읽기" 0 "my-task" bash "$RD" task title
t "mode manual" 0 "manual" env -u RD_AUTOPILOT bash "$RD" task mode
out="$(RD_AUTOPILOT=1 bash "$RD" task mode)"; [[ "$out" == "autopilot" ]] && echo "ok: mode autopilot" || { echo "FAIL: mode autopilot"; FAIL=1; }

# v2 2b: CURRENT_TASK.md 없음 + task-state 없음 → bootstrap(대기 중 exit 0)
rm "$TMP/CURRENT_TASK.md"
rm -f "$TMP/rd-workflow-workspace/.lifecycle/task-state"
t "파일 없음 status bootstrap 대기 중" 0 "대기 중" bash "$RD" task status
# Status 섹션 부재: CURRENT_TASK.md는 있지만 Status 섹션 없음 → 마이그레이션 fail-closed exit 3
rm -f "$TMP/rd-workflow-workspace/.lifecycle/task-state"
printf '# Current Task\n' > "$TMP/CURRENT_TASK.md"
t "Status 섹션 부재 exit 3" 3 "-" bash "$RD" task status
# Short Title 섹션 부재: task-state 없음 + CURRENT_TASK.md Status 섹션 없음 → exit 3
t "Short Title 섹션 부재 exit 3" 3 "-" bash "$RD" task title
# LC-19: 비canonical Status = task-state 없음 + CURRENT_TASK.md 비canonical → exit 3 (SEC-13 fail-closed)
mk_task_file "$TMP" "깨진 값" "x"   # mk_task_file이 비canonical이면 task-state 삭제
t "비canonical Status exit 3" 3 "-" bash "$RD" task status
# legacy alias '실행 중': task-state에는 '구현 중'으로 정규화되어 저장됨 (마이그레이션 계약)
mk_task_file "$TMP" "실행 중" "x"
t "legacy alias 실행 중 → 구현 중 (마이그레이션 정규화)" 0 "구현 중" bash "$RD" task status

# --- 전이표 (spec §5) ---
mk_task_file "$TMP" "대기 중" "-"
t "허용 전이: 대기 중→REQUEST review 대기" 0 "-" bash "$RD" task set-status "REQUEST review 대기"
t "결과 확인" 0 "REQUEST review 대기" bash "$RD" task status
mk_task_file "$TMP" "대기 중" "-"
t "허용 전이: 대기 중→구현 중 (small-task)" 0 "-" bash "$RD" task set-status "구현 중"
mk_task_file "$TMP" "구현 중" "x"
t "차단 전이: 구현 중→완료" 4 "-" bash "$RD" task set-status "완료"
t "차단 후 Status 불변" 0 "구현 중" bash "$RD" task status
mk_task_file "$TMP" "구현 중" "x"
t "승격 전이: 구현 중→spec/plan 작성 중 허용 (모드 B→A 중간 승격)" 0 "-" bash "$RD" task set-status "spec/plan 작성 중"
t "force 우회" 0 "-" bash "$RD" task set-status "완료" --force
mk_task_file "$TMP" "구현 중" "x"
t "비허용 값 거부" 4 "-" bash "$RD" task set-status "이상한 값"
t "모든 상태→대기 중 허용 (LC-14)" 0 "-" bash "$RD" task set-status "대기 중"
# 현재 Status 파손: task-state 없음 + 비canonical CURRENT_TASK.md → state_ensure fail-closed exit 3
mk_task_file "$TMP" "깨진 값" "x"   # mk_task_file이 비canonical이면 task-state 삭제
t "비canonical 현재값 exit 3" 3 "-" bash "$RD" task set-status "구현 중"
# legacy alias: mk_task_file이 '실행 중' → task-state에 '구현 중'으로 저장 (v2 정규화)
# 전이 판정은 task-state의 '구현 중' 기준
mk_task_file "$TMP" "실행 중" "x"
t "alias 실행 중→검증 중 허용 (task-state='구현 중'으로 정규화)" 0 "-" bash "$RD" task set-status "검증 중"
mk_task_file "$TMP" "실행 중" "x"
t "alias 실행 중→완료 차단 (task-state='구현 중')" 4 "-" bash "$RD" task set-status "완료"

# 전이표 전수 (8×8): 허용 목록 외 전부 차단인지 기계 검증
ALLOWED="대기 중→REQUEST review 대기|대기 중→구현 중|REQUEST review 대기→spec/plan 작성 중|spec/plan 작성 중→spec/plan review 대기|spec/plan review 대기→spec/plan 작성 중|spec/plan review 대기→구현 중|구현 중→spec/plan 작성 중|구현 중→검증 중|검증 중→구현 중|검증 중→diff review 대기|diff review 대기→구현 중|diff review 대기→완료"
STATUSES=("대기 중" "REQUEST review 대기" "spec/plan 작성 중" "spec/plan review 대기" "구현 중" "검증 중" "diff review 대기" "완료")
for from in "${STATUSES[@]}"; do
  for to in "${STATUSES[@]}"; do
    [[ "$from" == "$to" ]] && continue
    mk_task_file "$TMP" "$from" "x"
    bash "$RD" task set-status "$to" >/dev/null 2>&1; rc=$?
    if [[ "$to" == "대기 중" ]] || printf '%s' "$ALLOWED" | grep -qF "${from}→${to}"; then want=0; else want=4; fi
    [[ "$rc" == "$want" ]] && echo "ok: 전이 ${from}→${to} rc=$rc" || { echo "FAIL: 전이 ${from}→${to} rc=$rc want=$want"; FAIL=1; }
  done
done

# --- golden fixture round-trip (REQUEST AC 2 baseline) ---
for st in "${STATUSES[@]}"; do
  mk_task_file "$TMP" "$st" "gold-task"
  cp "$TMP/CURRENT_TASK.md" "$TMP/golden.md"
  got="$(bash "$RD" task status)"
  [[ "$got" == "$st" ]] || { echo "FAIL: golden read $st"; FAIL=1; }
  bash "$RD" task set-status "$st" --force >/dev/null 2>&1
  if ! diff -q "$TMP/golden.md" "$TMP/CURRENT_TASK.md" >/dev/null; then
    echo "FAIL: golden round-trip byte 불일치 ($st)"; FAIL=1
  else
    echo "ok: golden round-trip $st"
  fi
done

# --- guard (spec §4, GRD-01/02, SEC-13) ---
g() { # g <설명> <기대exit> <기대decision> cmd...
  local desc="$1" want_rc="$2" want_d="$3"; shift 3
  local out rc d
  out="$("$@" 2>/dev/null)"; rc=$?
  d="$(printf '%s\n' "$out" | awk -F= '$1=="decision"{print $2}')"
  [[ "$rc" == "$want_rc" && "$d" == "$want_d" ]] && echo "ok: $desc" || { echo "FAIL: $desc (rc=$rc d=$d)"; FAIL=1; }
}
# intake: 빈 title → write
mk_task_file "$TMP" "대기 중" "-"
g "intake -: write" 0 "write" bash "$RD" task guard --candidate new-task --mode intake
t "write 후 title" 0 "new-task" bash "$RD" task title
# intake: 동일 → proceed-readonly
g "intake 동일: readonly" 0 "proceed-readonly" bash "$RD" task guard --candidate new-task --mode intake
# intake: 상이 + Status=대기 중 → rebind
mk_task_file "$TMP" "대기 중" "stale-task"
g "intake stale: rebind" 0 "rebind" bash "$RD" task guard --candidate fresh --mode intake
t "rebind 후 title" 0 "fresh" bash "$RD" task title
# intake: 상이 + Status=구현 중 → block-active
mk_task_file "$TMP" "구현 중" "busy-task"
g "intake active: block" 2 "block-active" bash "$RD" task guard --candidate other --mode intake
t "block 후 title 불변" 0 "busy-task" bash "$RD" task title
# intake: task-state 없음 + Status 파싱 불가 → state_ensure fail-closed exit 3 (v2: 마이그레이션 차단)
# task-state가 있는 상태에서 손상 status는 TC-T4-f에서 block-parse exit 2로 검증
rm -f "$TMP/rd-workflow-workspace/.lifecycle/task-state"
printf '# Current Task\n\n## Short Title\nbusy-task\n' > "$TMP/CURRENT_TASK.md"
g "intake 파싱불가(legacy): state_ensure exit 3" 3 "" bash "$RD" task guard --candidate other --mode intake
# intake: task-state 없음 + 비canonical Status → state_ensure fail-closed exit 3
mk_task_file "$TMP" "깨진 값" "busy-task"   # mk_task_file이 비canonical → task-state 삭제
g "intake 비canonical(legacy): state_ensure exit 3" 3 "" bash "$RD" task guard --candidate other --mode intake
# intake: legacy alias 실행 중 → 활성으로 간주 block-active
mk_task_file "$TMP" "실행 중" "busy-task"
g "intake alias 실행 중: block-active" 2 "block-active" bash "$RD" task guard --candidate other --mode intake
# promote: intake와 동일 로직
mk_task_file "$TMP" "대기 중" "stale"
g "promote stale: rebind" 0 "rebind" bash "$RD" task guard --candidate fr-x --mode promote
# fr-add: Status guard 없음 (GRD-02)
mk_task_file "$TMP" "구현 중" "busy-task"
g "fr-add active: readonly (차단 없음)" 0 "proceed-readonly" bash "$RD" task guard --candidate other --mode fr-add
mk_task_file "$TMP" "대기 중" "-"
# fr-add + task-state 존재 + short-title=-(sentinel) → write (LC-18: sentinel은 Short Title 부여 진입점)
out_fr_sentinel="$(bash "$RD" task guard --candidate new-fr --mode fr-add 2>/dev/null)"
d_fr_sentinel="$(printf '%s\n' "$out_fr_sentinel" | awk -F= '$1=="decision"{print $2}')"
[[ "$d_fr_sentinel" == "write" ]] && echo "ok: fr-add sentinel -: write (Short Title 부여)" \
  || { echo "FAIL: fr-add sentinel -: '$d_fr_sentinel' (기대: write)"; FAIL=1; }
# task-state short-title 갱신 확인
ts_fr_title="$(awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,"");print;exit}' "${TMP}/rd-workflow-workspace/.lifecycle/task-state")"
[[ "$ts_fr_title" == "new-fr" ]] && echo "ok: fr-add sentinel write — task-state 갱신됨" \
  || { echo "FAIL: fr-add sentinel write — task-state 미갱신 (got='${ts_fr_title}')"; FAIL=1; }
# CURRENT_TASK.md 뷰 미러 확인
ct_fr_title="$(awk '/^## Short Title/{s=1;next} s&&/^## /{exit} s&&NF{print;exit}' "${TMP}/CURRENT_TASK.md")"
[[ "$ct_fr_title" == "new-fr" ]] && echo "ok: fr-add sentinel write — 뷰 미러됨" \
  || { echo "FAIL: fr-add sentinel write — 뷰 미러 안됨 (got='${ct_fr_title}')"; FAIL=1; }
# fr-add + task-state 존재 + short-title 키 부재(손상, 빈 값) → proceed-readonly (손상 방어)
# mk_task_file을 사용하면 task-state가 short-title=- 로 덮어써지므로 직접 생성
mkdir -p "${TMP}/rd-workflow-workspace/.lifecycle"
cat > "${TMP}/rd-workflow-workspace/.lifecycle/task-state" <<'_TSFIX'
schema=1
status=구현 중
fr-branch=null
worktree-path=null
source-fr=-
_TSFIX
printf '# Current Task\n\n## Short Title\nsome-task\n\n## Status\n구현 중\n' > "$TMP/CURRENT_TASK.md"
out_fr_corrupt="$(bash "$RD" task guard --candidate new-fr2 --mode fr-add 2>/dev/null)"
d_fr_corrupt="$(printf '%s\n' "$out_fr_corrupt" | awk -F= '$1=="decision"{print $2}')"
[[ "$d_fr_corrupt" == "proceed-readonly" ]] && echo "ok: fr-add 손상(키 부재) → proceed-readonly" \
  || { echo "FAIL: fr-add 손상(키 부재) → '$d_fr_corrupt' (기대: proceed-readonly)"; FAIL=1; }
# task-state의 short-title 키가 추가되지 않았는지 확인 (write 금지)
ts_corrupt_title="$(awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,"");print;exit}' "${TMP}/rd-workflow-workspace/.lifecycle/task-state")"
[[ -z "$ts_corrupt_title" ]] && echo "ok: fr-add 손상 — task-state short-title 갱신 없음" \
  || { echo "FAIL: fr-add 손상 — short-title이 갱신됨 (got='${ts_corrupt_title}')"; FAIL=1; }
# Short Title 섹션 부재 + task-state 없음 → 마이그레이션 후 sentinel → write (LC-18)
# (마이그레이션이 short-title=-로 task-state를 생성 → sentinel이므로 write가 올바름)
rm -f "$TMP/rd-workflow-workspace/.lifecycle/task-state"
printf '# Current Task\n\n## Status\n구현 중\n' > "$TMP/CURRENT_TASK.md"
g "fr-add 섹션 부재(마이그레이션 후 sentinel): write" 0 "write" bash "$RD" task guard --candidate x --mode fr-add

# --- capture (SEC-03/04/05/06) ---
mk_task_file "$TMP" "구현 중" "cap-task"
mkdir -p "$TMP/rd-workflow-workspace"
out="$(printf '## 원본 입력\n원문 그대로 <특수문자> $VAR `backtick`\n' | bash "$RD" task capture --stage request)"
rc=$?
[[ "$rc" == 0 && -f "$out" ]] && echo "ok: capture 생성" || { echo "FAIL: capture 생성 (rc=$rc out=$out)"; FAIL=1; }
# 파일 권한 0600, 디렉토리 0700
perm="$(stat -f %Lp "$out" 2>/dev/null || stat -c %a "$out")"
dperm="$(stat -f %Lp "$TMP/rd-workflow-workspace/raw-captures" 2>/dev/null || stat -c %a "$TMP/rd-workflow-workspace/raw-captures")"
[[ "$perm" == "600" && "$dperm" == "700" ]] && echo "ok: capture 권한" || { echo "FAIL: capture 권한 ($perm/$dperm)"; FAIL=1; }
# frontmatter + 본문 무가공 (SEC-04)
grep -q '^stage: request$' "$out" && grep -q '^short-title: cap-task$' "$out" \
  && grep -qF '원문 그대로 <특수문자> $VAR `backtick`' "$out" \
  && echo "ok: capture 내용" || { echo "FAIL: capture 내용"; FAIL=1; }
# collision suffix (SEC-05)
out2="$(printf 'x\n' | bash "$RD" task capture --stage request)"
[[ "$out2" == "${out%.md}-2.md" ]] && echo "ok: collision suffix" || { echo "FAIL: collision suffix ($out2)"; FAIL=1; }
# title 명시 인자
out3="$(printf 'y\n' | bash "$RD" task capture --stage fr --title other-title)"
grep -q '^short-title: other-title$' "$out3" && echo "ok: capture --title" || { echo "FAIL: capture --title"; FAIL=1; }
# fr stage + --title 미지정 → 진행 중 short-title 폴백 금지, untitled 로 저장 (fail-open 유지)
out4="$(printf 'w\n' | bash "$RD" task capture --stage fr 2>/dev/null)"; rc=$?
[[ "$rc" == 0 && "$out4" == *"-fr-untitled.md" ]] \
  && grep -q '^short-title: untitled$' "$out4" \
  && ! ls "$TMP/rd-workflow-workspace/raw-captures/"*-fr-cap-task.md >/dev/null 2>&1 \
  && echo "ok: capture fr --title 미지정 → untitled" \
  || { echo "FAIL: capture fr --title 미지정 (rc=$rc out=$out4)"; FAIL=1; }
# 위 분기는 stderr 경고를 남긴다 (조용히 통과하지 않음)
err4="$(printf 'w2\n' | bash "$RD" task capture --stage fr 2>&1 >/dev/null)"
[[ "$err4" == *untitled* ]] && echo "ok: capture fr 경고 출력" || { echo "FAIL: capture fr 경고 출력 ($err4)"; FAIL=1; }
# fr 이외 stage 는 기존 폴백 유지 (회귀 방지)
out5="$(printf 'v\n' | bash "$RD" task capture --stage request)"
grep -q '^short-title: cap-task$' "$out5" && echo "ok: 비-fr stage 폴백 유지" || { echo "FAIL: 비-fr stage 폴백 유지 ($out5)"; FAIL=1; }
# symlink 조상 → fail-open (경고 + exit 0 + 파일 미생성) (SEC-01 + SEC-06)
mv "$TMP/rd-workflow-workspace/raw-captures" "$TMP/real-captures"
ln -s "$TMP/real-captures" "$TMP/rd-workflow-workspace/raw-captures"
cnt_before="$(ls "$TMP/real-captures" | wc -l)"
printf 'z\n' | bash "$RD" task capture --stage request >/dev/null 2>&1; rc=$?
cnt_after="$(ls "$TMP/real-captures" | wc -l)"
[[ "$rc" == 0 && "$cnt_before" == "$cnt_after" ]] && echo "ok: capture symlink fail-open" || { echo "FAIL: capture symlink (rc=$rc)"; FAIL=1; }
rm "$TMP/rd-workflow-workspace/raw-captures"; mv "$TMP/real-captures" "$TMP/rd-workflow-workspace/raw-captures"

# --- backup-request (SEC-01/02/05) ---
mk_task_file "$TMP" "완료" "bk-task"
printf '# Change Request\ncontent-1\n' > "$TMP/REQUEST.md"
out="$(bash "$RD" task backup-request)"
[[ -f "$out" ]] && grep -q 'content-1' "$out" && echo "ok: backup 생성" || { echo "FAIL: backup 생성"; FAIL=1; }
case "$out" in */rd-workflow-workspace/backlog/request-archive/*-bk-task.md) echo "ok: backup 파일명" ;; *) echo "FAIL: backup 파일명 ($out)"; FAIL=1 ;; esac
out2="$(bash "$RD" task backup-request)"
[[ "$out2" == "${out%.md}-2.md" ]] && echo "ok: backup collision" || { echo "FAIL: backup collision ($out2)"; FAIL=1; }
out3="$(bash "$RD" task backup-request --orphan)"
case "$out3" in *-orphan.md) echo "ok: backup orphan" ;; *) echo "FAIL: backup orphan ($out3)"; FAIL=1 ;; esac
# REQUEST.md 자체가 symlink → exit 2 + 백업 미생성 (SEC-01/02)
mv "$TMP/REQUEST.md" "$TMP/real-request.md"; ln -s "$TMP/real-request.md" "$TMP/REQUEST.md"
cnt_b="$(ls "$TMP/rd-workflow-workspace/backlog/request-archive" | wc -l)"
bash "$RD" task backup-request >/dev/null 2>&1; rc=$?
cnt_a="$(ls "$TMP/rd-workflow-workspace/backlog/request-archive" | wc -l)"
[[ "$rc" == 2 && "$cnt_b" == "$cnt_a" ]] && echo "ok: backup source symlink 차단" || { echo "FAIL: backup source symlink (rc=$rc)"; FAIL=1; }
rm "$TMP/REQUEST.md"; mv "$TMP/real-request.md" "$TMP/REQUEST.md"

# --- archive-captures (SEC-07/17) ---
CAPD="$TMP/rd-workflow-workspace/raw-captures"
rm -rf "$CAPD"; mkdir -p "$CAPD"
mkcap() { printf -- '---\ndate: 2026-07-05 00:00\nstage: %s\nshort-title: %s\nsource: routed\n---\n\nbody\n' "$1" "$2" > "$CAPD/2026-07-05-$1-$2.md"; }
mkcap request bk-task; mkcap spec bk-task; mkcap plan bk-task; mkcap fr bk-task
mkcap request other-task
# 파일명은 매칭되지만 frontmatter 불일치 → 이동 금지 (SEC-07)
printf -- '---\ndate: x\nstage: request\nshort-title: DIFFERENT\nsource: r\n---\n' > "$CAPD/2026-07-05-request-bk-task-fake.md"
bash "$RD" task archive-captures --stages request,spec,plan >/dev/null
[[ -f "$CAPD/archive/2026-07-05-request-bk-task.md" && -f "$CAPD/archive/2026-07-05-spec-bk-task.md" && -f "$CAPD/archive/2026-07-05-plan-bk-task.md" ]] \
  && echo "ok: archive-captures 이동" || { echo "FAIL: archive-captures 이동"; FAIL=1; }
[[ -f "$CAPD/2026-07-05-fr-bk-task.md" ]] && echo "ok: fr stage 미이동 (SEC-17)" || { echo "FAIL: fr stage가 이동됨"; FAIL=1; }
[[ -f "$CAPD/2026-07-05-request-other-task.md" ]] && echo "ok: 타 title 미이동" || { echo "FAIL: 타 title 이동됨"; FAIL=1; }
[[ -f "$CAPD/2026-07-05-request-bk-task-fake.md" ]] && echo "ok: frontmatter 불일치 미이동" || { echo "FAIL: frontmatter 불일치 이동됨"; FAIL=1; }
bash "$RD" task archive-captures --stages fr >/dev/null
[[ -f "$CAPD/archive/2026-07-05-fr-bk-task.md" ]] && echo "ok: fr stage 명시 이동" || { echo "FAIL: fr stage 명시 이동"; FAIL=1; }
dperm="$(stat -f %Lp "$CAPD/archive" 2>/dev/null || stat -c %a "$CAPD/archive")"
[[ "$dperm" == "700" ]] && echo "ok: archive 권한" || { echo "FAIL: archive 권한 ($dperm)"; FAIL=1; }

# ===========================================================================
# --- task-state 기반 golden 계약 (Task 3: v2 2b 전환 검증) ---
# ===========================================================================

# task-state 헬퍼: 파일 직접 생성 (rd CLI를 거치지 않고 선제 주입)
mk_task_state() { # mk_task_state <dir> <status> <short-title>
  local dir="$1" st="$2" sh="$3"
  mkdir -p "${dir}/rd-workflow-workspace/.lifecycle"
  cat > "${dir}/rd-workflow-workspace/.lifecycle/task-state" <<EOF
schema=1
short-title=${sh}
status=${st}
fr-branch=null
worktree-path=null
source-fr=-
EOF
}

# --- TC-T1: rd task status — task-state 우선 ---
echo "--- TC-T1: task status task-state 우선 ---"
TMP2="$(mktemp -d)"; trap 'rm -rf "$TMP2"' EXIT
# task-state(status=검증 중) + CURRENT_TASK.md(status=구현 중): task-state 우선 보장
mk_task_file "$TMP2" "구현 중" "foo"
mk_task_state "$TMP2" "검증 중" "foo"
t "T1-a status task-state 우선" 0 "검증 중" env project_root="$TMP2" bash "$RD" task status
# task-state status=zzz(비canonical) → exit 3
mk_task_state "$TMP2" "zzz" "foo"
t "T1-b status 비canonical task-state → exit 3" 3 "-" env project_root="$TMP2" bash "$RD" task status

# --- TC-T2: rd task title — task-state 우선 ---
echo "--- TC-T2: task title task-state 우선 ---"
# task-state(short-title=foo), CURRENT_TASK.md(short-title=old): task-state 우선
# mk_task_file 호출 후 mk_task_state로 덮어써야 task-state가 우선값을 유지
mk_task_file "$TMP2" "구현 중" "old"
mk_task_state "$TMP2" "구현 중" "foo"
t "T2-a title task-state 우선" 0 "foo" env project_root="$TMP2" bash "$RD" task title
# sentinel '-' 도 그대로 출력 exit 0
mk_task_state "$TMP2" "대기 중" "-"
t "T2-b title sentinel '-' 출력 exit 0" 0 "-" env project_root="$TMP2" bash "$RD" task title

# --- TC-T3: rd task set-status — task-state 갱신 + CURRENT_TASK.md 뷰 미러 ---
echo "--- TC-T3: set-status 양쪽 갱신 ---"
mk_task_file "$TMP2" "구현 중" "ts-task"
mk_task_state "$TMP2" "구현 중" "ts-task"
env project_root="$TMP2" bash "$RD" task set-status "검증 중" >/dev/null 2>&1
# task-state 갱신 확인
ts_status="$(awk -F'=' '$1=="status"{sub(/^[^=]+=/,"");print;exit}' "${TMP2}/rd-workflow-workspace/.lifecycle/task-state")"
[[ "$ts_status" == "검증 중" ]] && echo "ok: T3-a set-status task-state 갱신됨" || { echo "FAIL: T3-a set-status task-state 미갱신 (got='${ts_status}')"; FAIL=1; }
# CURRENT_TASK.md 뷰 미러 확인
ct_status="$(awk '/^## Status/{s=1;next} s&&/^## /{exit} s&&NF{print;exit}' "${TMP2}/CURRENT_TASK.md")"
[[ "$ct_status" == "검증 중" ]] && echo "ok: T3-b set-status 뷰 미러됨" || { echo "FAIL: T3-b set-status 뷰 미러 안됨 (got='${ct_status}')"; FAIL=1; }
# 전이 위반 exit 4
mk_task_state "$TMP2" "구현 중" "ts-task"
mk_task_file "$TMP2" "구현 중" "ts-task"
t "T3-c 전이 위반 exit 4" 4 "-" env project_root="$TMP2" bash "$RD" task set-status "완료"
# --force 우회 (stderr 경고 있어야 함)
mk_task_state "$TMP2" "구현 중" "ts-task"
mk_task_file "$TMP2" "구현 중" "ts-task"
out_force_err="$(env project_root="$TMP2" bash "$RD" task set-status "완료" --force 2>&1 >/dev/null)"
rc_force=$?
[[ "$rc_force" == "0" ]] && echo "ok: T3-d --force 우회 exit 0" || { echo "FAIL: T3-d --force 우회 exit $rc_force"; FAIL=1; }
[[ -n "$out_force_err" ]] && echo "ok: T3-e --force stderr 경고 있음" || { echo "FAIL: T3-e --force stderr 경고 없음"; FAIL=1; }

# --- TC-T4: rd task guard — task-state 기반 판정 + 뷰 미러 ---
echo "--- TC-T4: guard task-state 기반 ---"
# 신규(short-title=-) → write + task-state 갱신 + 뷰 미러
mk_task_state "$TMP2" "대기 중" "-"
mk_task_file "$TMP2" "대기 중" "-"
out_guard="$(env project_root="$TMP2" bash "$RD" task guard --candidate new-cand --mode intake 2>/dev/null)"
d_write="$(printf '%s\n' "$out_guard" | awk -F= '$1=="decision"{print $2}')"
[[ "$d_write" == "write" ]] && echo "ok: T4-a guard 신규 → write" || { echo "FAIL: T4-a guard 신규 → '$d_write'"; FAIL=1; }
# task-state short-title 갱신 확인
ts_title="$(awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,"");print;exit}' "${TMP2}/rd-workflow-workspace/.lifecycle/task-state")"
[[ "$ts_title" == "new-cand" ]] && echo "ok: T4-b guard write task-state 갱신됨" || { echo "FAIL: T4-b guard write task-state 미갱신 (got='${ts_title}')"; FAIL=1; }
# CURRENT_TASK.md 뷰 미러
ct_title="$(awk '/^## Short Title/{s=1;next} s&&/^## /{exit} s&&NF{print;exit}' "${TMP2}/CURRENT_TASK.md")"
[[ "$ct_title" == "new-cand" ]] && echo "ok: T4-c guard write 뷰 미러됨" || { echo "FAIL: T4-c guard write 뷰 미러 안됨 (got='${ct_title}')"; FAIL=1; }
# stale(status=대기 중) → rebind
mk_task_state "$TMP2" "대기 중" "old-title"
mk_task_file "$TMP2" "대기 중" "old-title"
out_guard2="$(env project_root="$TMP2" bash "$RD" task guard --candidate fresh --mode intake 2>/dev/null)"
d_rebind="$(printf '%s\n' "$out_guard2" | awk -F= '$1=="decision"{print $2}')"
[[ "$d_rebind" == "rebind" ]] && echo "ok: T4-d guard stale → rebind" || { echo "FAIL: T4-d guard stale → '$d_rebind'"; FAIL=1; }
# 충돌(status=구현 중) → block-active exit 2
mk_task_state "$TMP2" "구현 중" "busy"
mk_task_file "$TMP2" "구현 중" "busy"
out_guard3="$(env project_root="$TMP2" bash "$RD" task guard --candidate other --mode intake 2>/dev/null)"; rc_block=$?
d_block="$(printf '%s\n' "$out_guard3" | awk -F= '$1=="decision"{print $2}')"
[[ "$rc_block" == "2" && "$d_block" == "block-active" ]] && echo "ok: T4-e guard 충돌 → block-active exit 2" || { echo "FAIL: T4-e guard 충돌 → rc=$rc_block d='$d_block'"; FAIL=1; }
# 손상 status → block-parse exit 2
# mk_task_file 먼저(CURRENT_TASK.md 설정), 그 뒤 mk_task_state로 task-state를 손상 값으로 덮어씀
mk_task_file "$TMP2" "구현 중" "some"
mk_task_state "$TMP2" "zzz" "some"
out_guard4="$(env project_root="$TMP2" bash "$RD" task guard --candidate x --mode intake 2>/dev/null)"; rc_parse=$?
d_parse="$(printf '%s\n' "$out_guard4" | awk -F= '$1=="decision"{print $2}')"
[[ "$rc_parse" == "2" && "$d_parse" == "block-parse" ]] && echo "ok: T4-f guard 손상 status → block-parse exit 2" || { echo "FAIL: T4-f guard 손상 status → rc=$rc_parse d='$d_parse'"; FAIL=1; }

# --- TC-T5: 마이그레이션 통합 (task-state 부재 + legacy fixture → 첫 CLI 호출 자동 마이그레이션) ---
echo "--- TC-T5: 마이그레이션 통합 ---"
TMP3="$(mktemp -d)"; trap 'rm -rf "$TMP3"' EXIT
# legacy 환경: task-state 없이 CURRENT_TASK.md + active-fr만 존재
mkdir -p "${TMP3}/rd-workflow-workspace/.lifecycle"
cat > "${TMP3}/CURRENT_TASK.md" <<'CTEOF'
# Current Task

## Task
test

## Short Title
mig-task

## Status
구현 중

## Request
[REQUEST.md](REQUEST.md)

## Notes
-
CTEOF
# active-fr 주입 (legacy) — task-state 없음
cat > "${TMP3}/rd-workflow-workspace/.lifecycle/active-fr" <<'AFEOF'
fr-branch=fr/mig-task
short-title=mig-task
worktree-path=null
status=active
AFEOF
# rd task status 첫 호출 → 자동 마이그레이션 + 정상 출력
mig_status="$(env project_root="$TMP3" bash "$RD" task status 2>/dev/null)"
rc_mig=$?
[[ "$rc_mig" == "0" && "$mig_status" == "구현 중" ]] && echo "ok: T5-a 마이그레이션 후 status 정상" || { echo "FAIL: T5-a 마이그레이션 후 status (rc=$rc_mig out='$mig_status')"; FAIL=1; }
# task-state 생성 확인
[[ -f "${TMP3}/rd-workflow-workspace/.lifecycle/task-state" ]] && echo "ok: T5-b task-state 생성됨" || { echo "FAIL: T5-b task-state 미생성"; FAIL=1; }
# active-fr 소멸 확인
[[ ! -f "${TMP3}/rd-workflow-workspace/.lifecycle/active-fr" ]] && echo "ok: T5-c active-fr 소멸됨" || { echo "FAIL: T5-c active-fr 잔존"; FAIL=1; }
# migration-backup 생성 확인
bk_cnt="$(find "${TMP3}/rd-workflow-workspace/.lifecycle/migration-backup" -name "CURRENT_TASK.md" 2>/dev/null | wc -l | tr -d ' ')"
[[ "$bk_cnt" -ge 1 ]] && echo "ok: T5-d migration-backup 생성됨" || { echo "FAIL: T5-d migration-backup 없음"; FAIL=1; }
# 손상 legacy(비canonical status) → exit 3 + task-state 미생성
TMP4="$(mktemp -d)"; trap 'rm -rf "$TMP4"' EXIT
mk_task_file "$TMP4" "이상한값" "bad-task"
env project_root="$TMP4" bash "$RD" task status >/dev/null 2>&1; rc_bad=$?
[[ "$rc_bad" == "3" ]] && echo "ok: T5-e 손상 legacy → exit 3" || { echo "FAIL: T5-e 손상 legacy → exit $rc_bad (기대: 3)"; FAIL=1; }
[[ ! -f "${TMP4}/rd-workflow-workspace/.lifecycle/task-state" ]] && echo "ok: T5-f 손상 legacy → task-state 미생성" || { echo "FAIL: T5-f 손상 legacy → task-state 생성됨"; FAIL=1; }

# ===========================================================================
# --- TC-FIX: 리뷰 지적 사항 fix 검증 (v2-state-file-unification Task 3 리뷰) ---
# ===========================================================================

echo "--- TC-FIX-1: fr-add guard + task-state 존재 + short-title 손상 → proceed-readonly ---"
TMP_FIX="$(mktemp -d)"; trap 'rm -rf "$TMP_FIX"' EXIT
# task-state 존재하지만 short-title 키 없는 손상 fixture (mk_task_file 대신 직접 생성)
mkdir -p "${TMP_FIX}/rd-workflow-workspace/.lifecycle"
cat > "${TMP_FIX}/rd-workflow-workspace/.lifecycle/task-state" <<'FIXEOF'
schema=1
status=구현 중
fr-branch=null
worktree-path=null
source-fr=-
FIXEOF
# CURRENT_TASK.md도 직접 생성 (mk_task_file은 task-state를 덮어쓰므로 사용 불가)
cat > "${TMP_FIX}/CURRENT_TASK.md" <<'CTFIX'
# Current Task

## Task
test

## Short Title
some-task

## Status
구현 중

## Request
[REQUEST.md](REQUEST.md)

## Notes
-
CTFIX
# fr-add 모드: task-state에 short-title 키 없음(빈 값 반환) → proceed-readonly (write 금지)
out_fix1="$(env project_root="$TMP_FIX" bash "$RD" task guard --candidate new-fr --mode fr-add 2>/dev/null)"
d_fix1="$(printf '%s\n' "$out_fix1" | awk -F= '$1=="decision"{print $2}')"
[[ "$d_fix1" == "proceed-readonly" ]] && echo "ok: TC-FIX-1a fr-add 손상 task-state → proceed-readonly" || { echo "FAIL: TC-FIX-1a fr-add 손상 task-state → '$d_fix1' (기대: proceed-readonly)"; FAIL=1; }
# task-state의 short-title 키가 추가되지 않았는지 확인 (write 금지 — 손상 키 방치)
ts_title_fix="$(awk -F'=' '$1=="short-title"{sub(/^[^=]+=/,"");print;exit}' "${TMP_FIX}/rd-workflow-workspace/.lifecycle/task-state")"
[[ -z "$ts_title_fix" ]] && echo "ok: TC-FIX-1b short-title 갱신 없음 (write 금지)" || { echo "FAIL: TC-FIX-1b short-title이 갱신됨 (got='${ts_title_fix}')"; FAIL=1; }

echo "--- TC-FIX-2: set-status 쓰기 실패 → exit 3 ---"
TMP_FIX2="$(mktemp -d)"; trap 'rm -rf "$TMP_FIX2"' EXIT
mk_task_file "$TMP_FIX2" "구현 중" "fix2-task"
# task-state를 읽기 전용으로 만들어 state_write_fields 실패 시나리오 시뮬레이션
_ts_path_fix2="${TMP_FIX2}/rd-workflow-workspace/.lifecycle"
mkdir -p "$_ts_path_fix2"
cat > "${_ts_path_fix2}/task-state" <<'TS2EOF'
schema=1
short-title=fix2-task
status=구현 중
fr-branch=null
worktree-path=null
source-fr=-
TS2EOF
# 디렉토리를 읽기 전용으로 만들어 mktemp 실패 → state_write_fields return 1 → task_set_status return 3
chmod 000 "$_ts_path_fix2"
rc_fix2=0
env project_root="$TMP_FIX2" bash "$RD" task set-status "검증 중" >/dev/null 2>&1; rc_fix2=$?
chmod 700 "$_ts_path_fix2"
[[ "$rc_fix2" == "3" ]] && echo "ok: TC-FIX-2 set-status 쓰기 실패 → exit 3" || { echo "FAIL: TC-FIX-2 set-status 쓰기 실패 → exit ${rc_fix2} (기대: 3)"; FAIL=1; }

# --- source-fr 계약 (promote-source-fr-sync) ---
SRC_OK="rd-workflow-workspace/backlog/items/2026-01-01-old.md"
SRC_OK2="rd-workflow-workspace/backlog/items/2026-02-02-new.md"

mk_task_file "$TMP" "대기 중" "-"
t "set-source-fr 유효 path" 0 - bash "$RD" task set-source-fr "$SRC_OK"
t "source-fr 조회" 0 "$SRC_OK" bash "$RD" task source-fr
t "set-source-fr 절대경로 거부" 1 - bash "$RD" task set-source-fr "/etc/passwd"
t "set-source-fr .. 거부" 1 - bash "$RD" task set-source-fr "rd-workflow-workspace/backlog/items/../evil.md"
t "set-source-fr slug 거부" 1 - bash "$RD" task set-source-fr "some-slug"
t "set-source-fr 거부 후 값 불변" 0 "$SRC_OK" bash "$RD" task source-fr
t "set-source-fr sentinel '-'" 0 - bash "$RD" task set-source-fr "-"
t "sentinel 후 조회 '-'" 0 "-" bash "$RD" task source-fr

# guard promote write 분기: 인자 없음 → 리셋
mk_task_file "$TMP" "대기 중" "-"
bash "$RD" task set-source-fr "$SRC_OK" >/dev/null 2>&1
t "guard promote(write) 인자 없음" 0 - bash "$RD" task guard --candidate task-a --mode promote
t "write 후 source-fr 리셋" 0 "-" bash "$RD" task source-fr

# guard promote rebind 분기: stale 값 리셋 (monitoring 실사례 재현)
mk_task_file "$TMP" "대기 중" "stale-task"
bash "$RD" task set-source-fr "$SRC_OK" >/dev/null 2>&1
t "guard promote(rebind) 인자 없음" 0 - bash "$RD" task guard --candidate task-b --mode promote
t "rebind 후 source-fr 리셋" 0 "-" bash "$RD" task source-fr

# intake rebind 는 source-fr 를 건드리지 않는다 (spec: intake 는 write·rebind 모두 불변)
mk_task_file "$TMP" "대기 중" "stale-task-2"
bash "$RD" task set-source-fr "$SRC_OK" >/dev/null 2>&1
t "guard intake(rebind) 진행" 0 - bash "$RD" task guard --candidate task-g --mode intake
t "intake rebind 후 source-fr 불변" 0 "$SRC_OK" bash "$RD" task source-fr

# guard promote --source-fr 명시 기록
mk_task_file "$TMP" "대기 중" "-"
t "guard promote --source-fr 기록" 0 - bash "$RD" task guard --candidate task-c --mode promote --source-fr "$SRC_OK2"
t "기록값 조회" 0 "$SRC_OK2" bash "$RD" task source-fr
t "guard --source-fr 무효값 exit 1" 1 - bash "$RD" task guard --candidate task-d --mode promote --source-fr "/abs/path.md"

# --source-fr 는 promote 전용 — 비promote 모드에서 지정 시 오용 거부 (fail fast)
mk_task_file "$TMP" "대기 중" "-"
t "guard intake --source-fr 오용 exit 1" 1 - bash "$RD" task guard --candidate task-e --mode intake --source-fr "$SRC_OK"
t "guard fr-add --source-fr 오용 exit 1" 1 - bash "$RD" task guard --candidate task-f --mode fr-add --source-fr "$SRC_OK"

# fr-add 모드는 source-fr 를 건드리지 않는다 (proceed-readonly 계약 유지)
mk_task_file "$TMP" "구현 중" "busy-task"
bash "$RD" task set-source-fr "$SRC_OK" >/dev/null 2>&1
t "guard fr-add 진행 중" 0 - bash "$RD" task guard --candidate other --mode fr-add
t "fr-add 후 source-fr 불변" 0 "$SRC_OK" bash "$RD" task source-fr

[[ "$FAIL" == 0 ]] && echo "test_task_cli: ALL PASS" || echo "test_task_cli: FAIL"
exit "$FAIL"
