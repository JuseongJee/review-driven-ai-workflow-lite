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

# --- D12: source-fr 를 미러에도 쓴다 (AC 28) ---
#
# 미러가 대조 출처가 되어야 promote 가 divergence 를 판정할 수 있다. `mk_task_file` 은
# `## Source FR` 이 없는 미러를 만드므로(= D12 이전 형식) append 경로를 함께 검증한다.
sfr_mirror() { awk '$0=="## Source FR"{f=1;next} f && /^[^#]/{print;exit}' "$TMP/CURRENT_TASK.md"; }
sfr_sections() { grep -c '^## Source FR$' "$TMP/CURRENT_TASK.md"; }

mk_task_file "$TMP" "대기 중" "-"
t "D12 섹션 부재 미러에서도 set-source-fr 성공" 0 - bash "$RD" task set-source-fr "$SRC_OK"
[[ "$(sfr_mirror)" == "$SRC_OK" ]] \
  && echo "ok: D12 섹션 부재 미러에 append 되어 값이 보인다" \
  || { echo "FAIL: D12 append 후 미러 값 '$(sfr_mirror)' != '$SRC_OK'"; FAIL=1; }
t "D12 권위도 같은 값" 0 "$SRC_OK" bash "$RD" task source-fr

# 두 번째 호출은 append 가 아니라 교체다 — 섹션이 늘어나면 파서가 첫 값만 보고
# 이후 갱신을 통째로 놓친다.
bash "$RD" task set-source-fr "$SRC_OK2" >/dev/null 2>&1
[[ "$(sfr_sections)" == "1" ]] \
  && echo "ok: D12 재호출은 섹션을 늘리지 않는다" \
  || { echo "FAIL: D12 '## Source FR' 섹션이 $(sfr_sections) 개"; FAIL=1; }
[[ "$(sfr_mirror)" == "$SRC_OK2" ]] \
  && echo "ok: D12 재호출이 미러 값을 교체한다" \
  || { echo "FAIL: D12 재호출 후 미러 값 '$(sfr_mirror)' != '$SRC_OK2'"; FAIL=1; }

# sentinel 도 미러에 반영된다 — 권위만 '-' 가 되고 미러에 경로가 남으면 divergence 오탐
bash "$RD" task set-source-fr "-" >/dev/null 2>&1
[[ "$(sfr_mirror)" == "-" ]] \
  && echo "ok: D12 sentinel 도 미러에 반영된다" \
  || { echo "FAIL: D12 sentinel 후 미러 값 '$(sfr_mirror)' != '-'"; FAIL=1; }

# 값 계약 위반은 미러도 건드리지 않는다 (권위 쓰기 전에 거부)
bash "$RD" task set-source-fr "$SRC_OK" >/dev/null 2>&1
bash "$RD" task set-source-fr "/etc/passwd" >/dev/null 2>&1 || true
[[ "$(sfr_mirror)" == "$SRC_OK" ]] \
  && echo "ok: D12 계약 위반은 미러를 바꾸지 않는다" \
  || { echo "FAIL: D12 계약 위반 후 미러 값이 바뀌었다 ('$(sfr_mirror)')"; FAIL=1; }

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

# --- 루트 판정: cwd 비의존 (AC 14·15·16·17·18) ---
# fixture helper — _task_common.sh 의 런타임 의존 전체를 복사한다.
# Task 2 가 lifecycle/slug.sh source 를 추가하므로 그것까지 포함한다. 빠뜨리면
# Task 2 반영 후 이 fixture 가 의존 부재로 실패해 루트 판정을 시험하지 못한다.
rt_make_root() { # rt_make_root <dir>
  local d="$1"
  mkdir -p "$d/rd-workflow-workspace/.lifecycle" \
           "$d/rd-workflow/scripts/hooks" "$d/rd-workflow/scripts/lifecycle" \
           "$d/sub/deeper"
  cp "$SCRIPT_DIR/rd" "$SCRIPT_DIR/_task_common.sh" "$SCRIPT_DIR/_state_common.sh" \
     "$d/rd-workflow/scripts/"
  cp "$SCRIPT_DIR/hooks/_guard_common.sh" "$d/rd-workflow/scripts/hooks/"
  cp "$SCRIPT_DIR/lifecycle/slug.sh" "$d/rd-workflow/scripts/lifecycle/"
}
rt_make_bare() { # rt_make_bare <dir> — 마커 없는 배치
  local d="$1"
  mkdir -p "$d/rd-workflow/scripts/hooks" "$d/rd-workflow/scripts/lifecycle"
  cp "$SCRIPT_DIR/rd" "$SCRIPT_DIR/_task_common.sh" "$SCRIPT_DIR/_state_common.sh" \
     "$d/rd-workflow/scripts/"
  cp "$SCRIPT_DIR/hooks/_guard_common.sh" "$d/rd-workflow/scripts/hooks/"
  cp "$SCRIPT_DIR/lifecycle/slug.sh" "$d/rd-workflow/scripts/lifecycle/"
}

RT_ROOT="$(mktemp -d)"
rt_make_root "$RT_ROOT"
mk_task_file "$RT_ROOT" "구현 중" "roottest"
RT_RD="$RT_ROOT/rd-workflow/scripts/rd"

# 호출 전 상태 파일 집합 기록 (AC 15-(3))
rt_state_set() { ( cd "$RT_ROOT" && find . -name task-state -type f | LC_ALL=C sort ); }
RT_BEFORE="$(rt_state_set)"

# (1) 하위 디렉터리에서 호출 — 정본을 읽는다
t "root: 하위 디렉터리 호출이 정본 status 를 읽는다" 0 "구현 중" \
  env -u project_root bash -c "cd '$RT_ROOT/sub/deeper' && bash '$RT_RD' task status"

# (2) 파일 집합이 변하지 않았다 (AC 15-(3))
if [[ "$(rt_state_set)" != "$RT_BEFORE" ]]; then
  echo "FAIL: root: 하위 디렉터리 호출이 상태 파일을 새로 만들었다"; FAIL=1
else
  echo "ok: root: 하위 디렉터리 호출이 상태 파일을 만들지 않는다"
fi

# (3) 금지 경로 부재 (AC 15-(2))
if [[ -e "$RT_ROOT/sub/deeper/rd-workflow-workspace" ]]; then
  echo "FAIL: root: 하위 cwd 아래에 금지 경로가 생겼다"; FAIL=1
else
  echo "ok: root: 하위 cwd 아래 금지 경로 부재"
fi

# (4) 프로젝트 밖 cwd + 절대 경로 호출 = 성공 (AC 16)
RT_OUT="$(mktemp -d)"
t "root: 밖의 cwd 에서 절대 경로 호출이 성공한다" 0 "구현 중" \
  env -u project_root bash -c "cd '$RT_OUT' && bash '$RT_RD' task status"

# (4-1) PATH 경유 호출도 성공 (AC 16)
t "root: PATH 경유 호출이 성공한다" 0 "구현 중" \
  env -u project_root PATH="$RT_ROOT/rd-workflow/scripts:$PATH" bash -c "cd '$RT_OUT' && rd task status"

# (5) 마커 없는 배치 = 멈춤 + 파일 0개 생성 (AC 17)
RT_BAD="$(mktemp -d)"
rt_make_bare "$RT_BAD"
rt_bad_out="$(env -u project_root bash "$RT_BAD/rd-workflow/scripts/rd" task status 2>&1)"; rt_bad_rc=$?
if [[ "$rt_bad_rc" == "0" ]]; then
  echo "FAIL: root: 마커 없는 배치가 성공했다"; FAIL=1
elif ! printf '%s' "$rt_bad_out" | grep -q "프로젝트 루트"; then
  echo "FAIL: root: 마커 없는 배치 메시지에 루트 미확정 사유가 없다 ('$rt_bad_out')"; FAIL=1
elif [[ -n "$(find "$RT_BAD" -name task-state -type f)" ]]; then
  echo "FAIL: root: 마커 없는 배치가 상태 파일을 만들었다"; FAIL=1
else
  echo "ok: root: 마커 없는 배치는 멈추고 파일을 만들지 않는다"
fi

# (6) 조상 경로 심볼릭 링크는 지원 (AC 18)
RT_LINKBASE="$(mktemp -d)"
ln -s "$RT_ROOT" "$RT_LINKBASE/linked"
t "root: 조상 경로 링크 경유가 동작한다" 0 "구현 중" \
  env -u project_root bash "$RT_LINKBASE/linked/rd-workflow/scripts/rd" task status

# (6-1) 실행 파일 자체가 링크 = 비지원, 명시적 오류 + 파일 0개 (AC 18)
# 링크를 마커 밖에 두면 dirname 이 그 위치를 주므로 마커를 잃는다.
RT_EXECLINK="$(mktemp -d)"
ln -s "$RT_RD" "$RT_EXECLINK/rd-link"
rt_el_out="$(env -u project_root bash "$RT_EXECLINK/rd-link" task status 2>&1)"; rt_el_rc=$?
if [[ "$rt_el_rc" == "0" ]]; then
  echo "FAIL: root: 실행 파일 링크 경유가 성공했다 (비지원이어야 함)"; FAIL=1
elif ! printf '%s' "$rt_el_out" | grep -q "프로젝트 루트"; then
  echo "FAIL: root: 실행 파일 링크 오류에 루트 미확정 사유가 없다 ('$rt_el_out')"; FAIL=1
elif [[ -n "$(find "$RT_EXECLINK" -name task-state -type f 2>/dev/null)" ]]; then
  echo "FAIL: root: 실행 파일 링크 경유가 상태 파일을 만들었다"; FAIL=1
else
  echo "ok: root: 실행 파일 링크는 명시적 오류로 멈추고 파일을 만들지 않는다"
fi

# (7) 공백 포함 경로 (AC 18)
RT_SP="$(mktemp -d)/has space"
mkdir -p "$RT_SP"
cp -R "$RT_ROOT/." "$RT_SP/"
t "root: 공백 포함 경로에서 동작한다" 0 "구현 중" \
  env -u project_root bash "$RT_SP/rd-workflow/scripts/rd" task status

rm -rf "$RT_ROOT" "$RT_OUT" "$RT_BAD" "$RT_LINKBASE" "$RT_EXECLINK" "${RT_SP%/*}"

# --- set-title (AC 8~12) ---
ST_ROOT="$(mktemp -d)"
mkdir -p "$ST_ROOT/rd-workflow-workspace/.lifecycle"
mk_task_file "$ST_ROOT" "대기 중" "-"
st_rd() { env project_root="$ST_ROOT" bash "$RD" "$@"; }
st_state() { awk -F= '$1=="short-title"{print $2}' "$ST_ROOT/rd-workflow-workspace/.lifecycle/task-state"; }
st_mirror() { awk '/^## Short Title/{f=1;next} f&&NF{print;exit}' "$ST_ROOT/CURRENT_TASK.md"; }

# (1) sentinel 에서 기록 성공 + 미러 갱신 (AC 8)
t "set-title: sentinel 에서 기록한다" 0 "-" st_rd task set-title my-task
[[ "$(st_state)" == "my-task" ]] && echo "ok: set-title: task-state 기록" || { echo "FAIL: set-title: task-state='$(st_state)'"; FAIL=1; }
[[ "$(st_mirror)" == "my-task" ]] && echo "ok: set-title: 미러 갱신" || { echo "FAIL: set-title: 미러='$(st_mirror)'"; FAIL=1; }

# (2) 동일 값 재실행 = 멱등 성공 + 미러 복구 (AC 11)
# sed -i.bak + rm 은 BSD(macOS)·GNU 양립 형태다. 이 저장소의 test_defect_reports.sh 가
# 쓰는 관례와 같다. `sed -i 's/../../' f` 는 macOS 에서 실패한다.
sed -i.bak 's/^my-task$/drifted/' "$ST_ROOT/CURRENT_TASK.md"; rm -f "$ST_ROOT/CURRENT_TASK.md.bak"
t "set-title: 동일 값 재실행이 성공한다" 0 "-" st_rd task set-title my-task
[[ "$(st_mirror)" == "my-task" ]] && echo "ok: set-title: 동일 값 재실행이 미러를 복구한다" || { echo "FAIL: set-title: 미러 미복구='$(st_mirror)'"; FAIL=1; }

# (3) 다른 값은 거부 + 현재 값·복구 방법 노출 (AC 9·12)
st_out="$(st_rd task set-title other-task 2>&1)"; st_rc=$?
[[ "$st_rc" == "2" ]] && echo "ok: set-title: 다른 값 거부(exit 2)" || { echo "FAIL: set-title: 거부 exit=$st_rc"; FAIL=1; }
printf '%s' "$st_out" | grep -q "my-task" && echo "ok: set-title: 메시지에 현재 값" || { echo "FAIL: set-title: 메시지에 현재 값 없음"; FAIL=1; }
printf '%s' "$st_out" | grep -q -- "--force" && echo "ok: set-title: 메시지에 복구 방법" || { echo "FAIL: set-title: 메시지에 --force 없음"; FAIL=1; }
[[ "$(st_state)" == "my-task" ]] && echo "ok: set-title: 거부 시 값 미변경" || { echo "FAIL: set-title: 거부인데 값이 바뀜"; FAIL=1; }

# (4) --force 로 덮기 (AC 9)
t "set-title: --force 로 덮는다" 0 "-" st_rd task set-title other-task --force
[[ "$(st_state)" == "other-task" ]] && echo "ok: set-title: force 덮기" || { echo "FAIL: set-title: force 후 '$(st_state)'"; FAIL=1; }

# (5) 값 계약 위반 (AC 10)
t "set-title: 빈 값 거부" 1 "-" st_rd task set-title ""
t "set-title: sentinel 값 거부" 1 "-" st_rd task set-title -
t "set-title: 비-ASCII 거부" 1 "-" st_rd task set-title 한글제목
t "set-title: 인자 누락은 usage" 1 "-" st_rd task set-title
t "set-title: 잉여 인자는 usage" 1 "-" st_rd task set-title a b c
# slug 자리의 option token — 이 케이스가 없으면 val='--force' 가 'force' 로 정규화되어
# 실제 제목으로 기록된다 (Turn 004 Finding 3)
t "set-title: slug 없이 --force 만 주면 usage" 1 "-" st_rd task set-title --force
t "set-title: slug 자리의 알 수 없는 옵션은 usage" 1 "-" st_rd task set-title --nope x
# 이 블록 진입 시점의 값은 (4) 가 --force 로 기록한 other-task 다. 거부 케이스는
# 어느 것도 값을 바꾸지 않아야 한다.
[[ "$(st_state)" == "other-task" ]] && echo "ok: set-title: 거부 케이스가 값을 바꾸지 않았다" \
  || { echo "FAIL: set-title: 거부 케이스가 값을 바꿨다 ('$(st_state)')"; FAIL=1; }
# 개행 포함 입력 거부 (AC 10, D3 값 검증) — state_write_fields 의 개행 금지 계약보다
# 앞에서 걸러야 오류 메시지가 사용자 입력을 지목한다
t "set-title: 개행 포함 거부" 1 "-" st_rd task set-title "$(printf 'a\nb')"
# 정규화 후 빈 값이 되는 입력 — normalize_slug 가 거부하는 계약을 명시적으로 고정한다
t "set-title: 정규화 후 빈 값이 되는 입력 거부" 1 "-" st_rd task set-title "---"

# (6) usage 에 복구 전용 표기 (AC 12)
printf '%s' "$(st_rd task set-title 2>&1)" | grep -q "복구 전용" \
  && echo "ok: set-title: usage 에 복구 전용 표기" || { echo "FAIL: set-title: usage 에 복구 전용 표기 없음"; FAIL=1; }

# (7) 정규화 적용 (AC 10)
mk_task_file "$ST_ROOT" "대기 중" "-"
printf 'schema=1\nshort-title=-\nstatus=대기 중\n' > "$ST_ROOT/rd-workflow-workspace/.lifecycle/task-state"
t "set-title: 대문자·공백을 정규화한다" 0 "-" st_rd task set-title "My Task"
[[ "$(st_state)" == "my-task" ]] && echo "ok: set-title: 정규화" || { echo "FAIL: set-title: 정규화 결과 '$(st_state)'"; FAIL=1; }

# (8) 미러에 '## Short Title' 섹션이 없으면 **아무것도 쓰지 않고** 실패한다
#     (final diff review Finding 4)
#
# 종전에는 `_task_section_write` 가 섹션을 못 찾아도 입력을 그대로 복사하고 0 을 반환해,
# CLI 가 "기록 성공" 을 보고하면서 미러는 계속 부재했다. 게다가 task-state 는 이미
# 갱신된 뒤였으므로 partial state write 였다. 그래서 "실패한다" 만이 아니라
# **"권위도 바뀌지 않았다"** 를 함께 단언한다.
ST_NOSEC="$(mktemp -d)"
mkdir -p "$ST_NOSEC/rd-workflow-workspace/.lifecycle"
printf '# Current Task\n\n## Task\ntest\n\n## Status\n대기 중\n' > "$ST_NOSEC/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\n' \
  > "$ST_NOSEC/rd-workflow-workspace/.lifecycle/task-state"
ns_state() { awk -F= '$1=="short-title"{print $2}' "$ST_NOSEC/rd-workflow-workspace/.lifecycle/task-state"; }
NS_FILE_BEFORE="$(cat "$ST_NOSEC/CURRENT_TASK.md")"
ns_out="$(env project_root="$ST_NOSEC" bash "$RD" task set-title my-task 2>&1)"; ns_rc=$?
[[ "$ns_rc" != "0" ]] && echo "ok: set-title: 섹션 부재는 실패한다 (exit $ns_rc)" \
  || { echo "FAIL: set-title: 섹션 부재인데 성공했다"; FAIL=1; }
[[ "$(ns_state)" == "-" ]] && echo "ok: set-title: 섹션 부재 시 task-state 불변" \
  || { echo "FAIL: set-title: 섹션 부재인데 task-state 를 썼다 ('$(ns_state)')"; FAIL=1; }
[[ "$(cat "$ST_NOSEC/CURRENT_TASK.md")" == "$NS_FILE_BEFORE" ]] \
  && echo "ok: set-title: 섹션 부재 시 미러 byte 불변" \
  || { echo "FAIL: set-title: 섹션 부재인데 미러를 고쳤다"; FAIL=1; }
printf '%s' "$ns_out" | grep -q "Short Title" \
  && echo "ok: set-title: 섹션 부재 사유를 사용자에게 알린다" \
  || { echo "FAIL: set-title: 섹션 부재 메시지가 사유를 지목하지 않는다 ('$ns_out')"; FAIL=1; }
rm -rf "$ST_NOSEC"

# (9) set-status 도 같은 계약이다 — 미러에 '## Status' 가 없으면 **권위도 쓰지 않는다**
#     (final diff review 2라운드 Finding 2)
#
# `_task_section_write` 가 섹션 부재를 실패로 바꾼 뒤부터, 선검사가 없으면 task-state 는
# 새 값이고 미러는 그대로인 부분 갱신이 남는다. `task_read_status` 로는 못 잡는다 —
# `get_task_status` 는 task-state 가 있으면 그것만 읽어 미러의 섹션 부재를 보지 못한다.
ST_NOST="$(mktemp -d)"
mkdir -p "$ST_NOST/rd-workflow-workspace/.lifecycle"
printf '# Current Task\n\n## Task\ntest\n\n## Short Title\nx\n' > "$ST_NOST/CURRENT_TASK.md"
printf 'schema=1\nshort-title=x\nstatus=대기 중\n' \
  > "$ST_NOST/rd-workflow-workspace/.lifecycle/task-state"
nst_state() { awk -F= '$1=="status"{sub(/^[^=]+=/,"");print;exit}' \
  "$ST_NOST/rd-workflow-workspace/.lifecycle/task-state"; }
NST_FILE_BEFORE="$(cat "$ST_NOST/CURRENT_TASK.md")"
nst_out="$(env project_root="$ST_NOST" bash "$RD" task set-status "REQUEST review 대기" 2>&1)"; nst_rc=$?
[[ "$nst_rc" != "0" ]] && echo "ok: set-status: Status 섹션 부재는 실패한다 (exit $nst_rc)" \
  || { echo "FAIL: set-status: Status 섹션 부재인데 성공했다"; FAIL=1; }
[[ "$(nst_state)" == "대기 중" ]] && echo "ok: set-status: 섹션 부재 시 권위 불변 (부분 갱신 없음)" \
  || { echo "FAIL: set-status: 섹션 부재인데 권위를 썼다 ('$(nst_state)')"; FAIL=1; }
[[ "$(cat "$ST_NOST/CURRENT_TASK.md")" == "$NST_FILE_BEFORE" ]] \
  && echo "ok: set-status: 섹션 부재 시 미러 byte 불변" \
  || { echo "FAIL: set-status: 섹션 부재인데 미러를 고쳤다"; FAIL=1; }
printf '%s' "$nst_out" | grep -q "Status" \
  && echo "ok: set-status: 섹션 부재 사유를 사용자에게 알린다" \
  || { echo "FAIL: set-status: 섹션 부재 메시지가 사유를 지목하지 않는다 ('$nst_out')"; FAIL=1; }
rm -rf "$ST_NOST"

rm -rf "$ST_ROOT"

# --- promote 호출 인자 정적 점검 (AC 7) ---
# 임시 루트를 인자로 주므로 실제 저장소를 건드리지 않는다.
CK="$SCRIPT_DIR/check_promote_call_args.sh"
CK_ROOT="$(mktemp -d)"
mkdir -p "$CK_ROOT/rd-workflow/docs" "$CK_ROOT/rd-workflow-workspace/plans"

# (1) 인자 있는 단일 줄 호출 = 통과
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title x --size large\n' \
  > "$CK_ROOT/rd-workflow/docs/ok.md"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: 인자 있는 호출은 통과" \
  || { echo "FAIL: check: 인자 있는 호출을 위반으로 봤다"; FAIL=1; }

# (2) 멀티라인 호출 = 통과 (README 용법 블록 형태 — 오탐 회귀)
printf 'bash rd-workflow/scripts/lifecycle/promote.sh \\\n  [--short-title <slug>] \\\n  (--size large|small) \\\n  [--no-worktree]\n' \
  > "$CK_ROOT/rd-workflow/docs/multiline.md"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: 멀티라인 호출을 오탐하지 않는다" \
  || { echo "FAIL: check: 멀티라인 호출을 위반으로 오탐했다"; FAIL=1; }

# (3) usage 문자열 = 대상 아님
printf 'echo "usage: promote.sh --short-title <slug>"\n' > "$CK_ROOT/rd-workflow/docs/usage.sh"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: usage 문자열은 대상이 아니다" \
  || { echo "FAIL: check: usage 문자열을 위반으로 봤다"; FAIL=1; }

# (4) 이력(rd-workflow-workspace/)은 제외
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title old\n' \
  > "$CK_ROOT/rd-workflow-workspace/plans/past.md"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: 이력 자료는 점검 대상이 아니다" \
  || { echo "FAIL: check: 이력 자료를 점검했다"; FAIL=1; }

# (5) 위반은 실제로 잡는다 — 이 케이스가 실패하면 검사가 아무것도 보지 않는 것이다
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title x --no-worktree\n' \
  > "$CK_ROOT/rd-workflow/docs/bad.md"
ck_out="$(bash "$CK" "$CK_ROOT" 2>&1)"; ck_rc=$?
# exit 1 이어야 한다. 0 은 못 잡은 것이고 2 는 점검 자체가 성립하지 않은 것이므로
# 둘 다 "위반을 잡았다" 의 증거가 아니다.
if [[ "$ck_rc" != "1" ]]; then
  echo "FAIL: check: 위반 검출 exit=$ck_rc (1 이어야 한다)"; FAIL=1
elif ! printf '%s' "$ck_out" | grep -q "bad.md"; then
  echo "FAIL: check: 위반 목록에 파일명이 없다 ('$ck_out')"; FAIL=1
else
  echo "ok: check: 위반을 잡고 파일명을 보고한다"
fi

# (6) 위반을 고치면 다시 통과
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title x --no-worktree --size small\n' \
  > "$CK_ROOT/rd-workflow/docs/bad.md"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: 고친 뒤 통과" \
  || { echo "FAIL: check: 고쳤는데 여전히 위반"; FAIL=1; }

# (7) 없는 root 는 실패한다 — fail-open 회귀 (Turn 004 Finding 4)
# 이 케이스가 없으면 경로 오타가 "위반 0건 통과" 로 보여 게이트가 조용히 죽는다.
bash "$CK" "$CK_ROOT/does-not-exist-$$" >/dev/null 2>&1; ck_rc=$?
[[ "$ck_rc" == "2" ]] && echo "ok: check: 없는 root 는 exit 2" \
  || { echo "FAIL: check: 없는 root 를 exit $ck_rc 로 처리했다"; FAIL=1; }

# (8) 점검 대상이 하나도 없으면 실패한다
CK_EMPTY="$(mktemp -d)"
mkdir -p "$CK_EMPTY/unrelated"
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title x\n' > "$CK_EMPTY/unrelated/x.md"
bash "$CK" "$CK_EMPTY" >/dev/null 2>&1; ck_rc=$?
[[ "$ck_rc" == "2" ]] && echo "ok: check: 점검 대상 0개는 exit 2" \
  || { echo "FAIL: check: 점검 대상이 없는데 exit $ck_rc"; FAIL=1; }
rm -rf "$CK_EMPTY"

# (9) 테스트 스크립트는 대상이 아니다 — 의도적 위반 fixture 를 만드는 것이 그 일이다.
# 이 케이스가 없으면 제외 규칙이 조용히 넓어지거나(다른 .sh 도 빠짐) 사라진다(회귀
# fixture 에 --size 를 넣게 되어 (5)(8) 이 검증력을 잃음).
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title x\n' \
  > "$CK_ROOT/rd-workflow/docs/test_fixture_writer.sh"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: test_*.sh 는 점검 대상이 아니다" \
  || { echo "FAIL: check: test_*.sh 를 위반으로 봤다"; FAIL=1; }

# (10) 인자 전달 래퍼는 대상이 아니다 — 시작 상태는 호출자가 준다
printf 'run_promote() { bash rd-workflow/scripts/lifecycle/promote.sh "$@"; }\n' \
  > "$CK_ROOT/rd-workflow/docs/wrapper.sh"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: 인자 전달 래퍼는 대상이 아니다" \
  || { echo "FAIL: check: 인자 전달 래퍼를 위반으로 봤다"; FAIL=1; }

# (11) 점검기 자신은 대상이 아니다 — 패턴 문자열이 자기 검사에 걸리는 순환을 막는다
printf 'case "$l" in *bash*promote.sh*) ;; esac\n' \
  > "$CK_ROOT/rd-workflow/docs/check_promote_call_args.sh"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1 && echo "ok: check: 점검기 자신은 대상이 아니다" \
  || { echo "FAIL: check: 점검기 자신을 위반으로 봤다"; FAIL=1; }

# (12) 제외 규칙이 .md 안내 예시까지 넓어지지 않았음을 재확인한다.
# (9)~(11) 로 제외를 넣은 뒤에도 실제 안내 예시의 위반은 여전히 잡혀야 한다.
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title y\n' \
  > "$CK_ROOT/rd-workflow/docs/still_bad.md"
bash "$CK" "$CK_ROOT" >/dev/null 2>&1; ck_rc=$?
[[ "$ck_rc" == "1" ]] && echo "ok: check: 제외 규칙이 안내 예시 판정을 무력화하지 않았다" \
  || { echo "FAIL: check: 제외 규칙이 안내 예시 위반을 놓쳤다 (exit $ck_rc)"; FAIL=1; }

# (13) 파일을 읽지 못하면 exit 2 다 — "위반 0건" 으로 소실되지 않는다
#      (final diff review Finding 5)
#
# `find` 가 이름은 찾았지만 `awk` 가 읽지 못하는 상황을 만든다. 종전에는 awk 종료 상태를
# 검사하지 않아 `joined` 가 비고 pipeline 이 0 으로 끝나서, 검사하지 못한 파일이
# 깨끗한 것으로 처리됐다 — "점검 자체 실패는 exit 2" 계약과 어긋난다.
# root 를 깨끗한 상태로 두고 읽기 불가 파일 하나만 넣어, exit 2 가 이 파일 때문임을 고립한다.
CK_UNREAD="$(mktemp -d)"
mkdir -p "$CK_UNREAD/rd-workflow/docs"
printf 'bash rd-workflow/scripts/lifecycle/promote.sh --short-title x --size large\n' \
  > "$CK_UNREAD/rd-workflow/docs/unreadable.md"
chmod 000 "$CK_UNREAD/rd-workflow/docs/unreadable.md"
if [[ -r "$CK_UNREAD/rd-workflow/docs/unreadable.md" ]]; then
  # root 권한 등으로 chmod 가 무력한 환경 — 이 케이스는 성립하지 않으므로 건너뛴다.
  echo "ok: check: 읽기 실패 케이스 건너뜀 (이 환경에서는 chmod 000 이 읽기를 막지 못함)"
else
  bash "$CK" "$CK_UNREAD" >/dev/null 2>&1; ck_rc=$?
  [[ "$ck_rc" == "2" ]] && echo "ok: check: 읽지 못한 파일은 exit 2 (깨끗함으로 소실 안 됨)" \
    || { echo "FAIL: check: 읽기 실패를 exit $ck_rc 로 처리했다 (2 여야 한다)"; FAIL=1; }
fi
chmod 644 "$CK_UNREAD/rd-workflow/docs/unreadable.md" 2>/dev/null || true
rm -rf "$CK_UNREAD"

rm -rf "$CK_ROOT"

# --- autopilot 승격 명령 계약 정적 점검 (final diff review 4라운드 Finding 3) ---
#
# 판정 로직을 스크립트로 분리한 이유가 바로 이 회귀다 — 실제 SKILL.md 를 오염시켜
# 확인하면 같은 작업의 다른 변경과 로컬 변경을 함께 날린다. fixture 로 시험한다.
AP="$SCRIPT_DIR/check_autopilot_promote_contract.sh"
AP_DIR="$(mktemp -d)"
ap_write() { # ap_write <파일> — 계약을 만족하는 최소 SKILL.md
  cat > "$1" <<'APEOF'
### 1. 작업 선택

- 목록을 보여주고 사용자가 선택한다
- **선택한 항목의 상세 파일 경로를 기억한다.** 이 값이 §3 승격의 `--source-fr` 인자이고,
  이 단계가 유일한 producer 다.
- **다음은 §3 승격이다** (아래 REQUEST.md 생성보다 **앞**).
- §3 승격 완료 후 REQUEST.md 를 생성한다.

### 3. fr 브랜치 승격 (promote)

- 호출한다:
  모드 A (큰 작업):
  ```bash
  bash rd-workflow/scripts/lifecycle/promote.sh --short-title <slug> --size large \
    --source-fr rd-workflow-workspace/backlog/items/<선택한-항목>.md
  ```
  모드 B (작은 작업):
  ```bash
  bash rd-workflow/scripts/lifecycle/promote.sh --short-title <slug> --size small \
    --source-fr rd-workflow-workspace/backlog/items/<선택한-항목>.md
  ```
APEOF
}

# (1) 계약을 만족하는 문서는 통과
ap_write "$AP_DIR/ok.md"
bash "$AP" "$AP_DIR/ok.md" >/dev/null 2>&1 \
  && echo "ok: ap: 계약을 만족하는 문서는 통과" \
  || { echo "FAIL: ap: 정상 문서를 위반으로 봤다 ($(bash "$AP" "$AP_DIR/ok.md" 2>&1))"; FAIL=1; }

# (2) 모드 B 도 large — 이번 리뷰에서 실제로 발견된 오용
ap_write "$AP_DIR/b_large.md"
sed -i.bak 's/--size small/--size large/' "$AP_DIR/b_large.md"; rm -f "$AP_DIR/b_large.md.bak"
bash "$AP" "$AP_DIR/b_large.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: 모드 B 의 large 오용을 잡는다" \
  || { echo "FAIL: ap: 모드 B large 오용에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (3) A/B 의 size 를 서로 바꿈 — 전역 존재 검사로는 통과해 버리는 오용
ap_write "$AP_DIR/swap.md"
sed -i.bak 's/--size large/--size SWAP/; s/--size small/--size large/; s/--size SWAP/--size small/' \
  "$AP_DIR/swap.md"; rm -f "$AP_DIR/swap.md.bak"
bash "$AP" "$AP_DIR/swap.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: A/B size 교차를 잡는다" \
  || { echo "FAIL: ap: A/B size 교차에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (4) --source-fr 삭제 — continuation(`\`) 이 남아 있어 한 줄 grep 으로는 못 잡는 오용
ap_write "$AP_DIR/no_sfr.md"
sed -i.bak '/--source-fr rd-workflow-workspace/d' "$AP_DIR/no_sfr.md"; rm -f "$AP_DIR/no_sfr.md.bak"
bash "$AP" "$AP_DIR/no_sfr.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: --source-fr 누락을 잡는다 (논리 줄 판정)" \
  || { echo "FAIL: ap: --source-fr 누락에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (5) 블록을 하나로 병합 — 모드 라벨과 한쪽 명령을 없앤 형태
ap_write "$AP_DIR/merged.md"
awk '!/모드 B \(/ && !/--size small/' "$AP_DIR/merged.md" > "$AP_DIR/merged.tmp" \
  && mv "$AP_DIR/merged.tmp" "$AP_DIR/merged.md"
bash "$AP" "$AP_DIR/merged.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: 블록 병합을 잡는다" \
  || { echo "FAIL: ap: 블록 병합에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (6) §1 의 producer 서술 제거
ap_write "$AP_DIR/no_producer.md"
sed -i.bak '/유일한 producer/d' "$AP_DIR/no_producer.md"; rm -f "$AP_DIR/no_producer.md.bak"
bash "$AP" "$AP_DIR/no_producer.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: §1 producer 서술 제거를 잡는다" \
  || { echo "FAIL: ap: §1 producer 제거에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (7) §1 의 **순서 관계** 서술 제거 — '§3' 과 '앞' 이 한 줄에 함께 있어야 한다.
#     토큰을 따로 세면 두 단어가 무관한 문장에 흩어져 있어도 통과한다.
ap_write "$AP_DIR/no_order.md"
sed -i.bak 's/- \*\*다음은 §3 승격이다\*\* (아래 REQUEST.md 생성보다 \*\*앞\*\*)./- 다음 단계로 넘어간다./' \
  "$AP_DIR/no_order.md"; rm -f "$AP_DIR/no_order.md.bak"
bash "$AP" "$AP_DIR/no_order.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: §1 순서 관계 서술 제거를 잡는다" \
  || { echo "FAIL: ap: §1 순서 관계 제거에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (8) 값 prefix 통과 차단 — `--size largeish` 는 large 가 아니다 (5라운드 Finding 2)
ap_write "$AP_DIR/prefix.md"
sed -i.bak 's/--size large /--size largeish /' "$AP_DIR/prefix.md"; rm -f "$AP_DIR/prefix.md.bak"
bash "$AP" "$AP_DIR/prefix.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: --size 값 prefix(largeish)를 잡는다" \
  || { echo "FAIL: ap: --size largeish 에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (9) 한쪽 모드만 --source-fr - 로 바꿈 — CLI 가 허용해 **조용히** FR 연결을 잃는 형태.
#     canonical 예시를 문서 전체에서 한 번만 확인하면 통과해 버린다.
ap_write "$AP_DIR/sfr_dash.md"
awk '{ if ($0 ~ /--source-fr rd-workflow-workspace/ && !seen) { seen=1; print } else if ($0 ~ /--source-fr rd-workflow-workspace/) { sub(/--source-fr rd-workflow-workspace\/backlog\/items\/<선택한-항목>\.md/, "--source-fr -"); print } else print }' \
  "$AP_DIR/sfr_dash.md" > "$AP_DIR/sfr_dash.tmp" && mv "$AP_DIR/sfr_dash.tmp" "$AP_DIR/sfr_dash.md"
bash "$AP" "$AP_DIR/sfr_dash.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: 한쪽 모드의 --source-fr - 를 잡는다" \
  || { echo "FAIL: ap: 한쪽 --source-fr - 에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (10) --source-fr 값 누락 (이름만 남김)
ap_write "$AP_DIR/sfr_noval.md"
sed -i.bak 's|--source-fr rd-workflow-workspace/backlog/items/<선택한-항목>.md|--source-fr|' \
  "$AP_DIR/sfr_noval.md"; rm -f "$AP_DIR/sfr_noval.md.bak"
bash "$AP" "$AP_DIR/sfr_noval.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "1" ]] && echo "ok: ap: --source-fr 값 누락을 잡는다" \
  || { echo "FAIL: ap: --source-fr 값 누락에서 exit $ap_rc (1 이어야 한다)"; FAIL=1; }

# (11a~11d) **같은 옵션 중복** — 파서는 마지막 값을 쓰므로 기대값의 존재만 보면 뚫린다
#           (6라운드 Finding 2). 앞뒤 순서를 바꾼 네 형태를 모두 고정한다.
ap_dup() { # ap_dup <이름> <sed 식> <설명>
  ap_write "$AP_DIR/$1.md"
  sed -i.bak "$2" "$AP_DIR/$1.md"; rm -f "$AP_DIR/$1.md.bak"
  bash "$AP" "$AP_DIR/$1.md" >/dev/null 2>&1; local r=$?
  [[ "$r" == "1" ]] && echo "ok: ap: $3 을 잡는다" \
    || { echo "FAIL: ap: $3 에서 exit $r (1 이어야 한다)"; FAIL=1; }
}
ap_dup dup_sb 's/--size small /--size small --size large /' "--size small 뒤 large 중복"
ap_dup dup_bs 's/--size large /--size large --size small /' "--size large 뒤 small 중복"
ap_dup dup_sfr1 \
  's|--source-fr rd-workflow-workspace/backlog/items/<선택한-항목>.md|--source-fr rd-workflow-workspace/backlog/items/<선택한-항목>.md --source-fr -|' \
  "--source-fr canonical 뒤 - 중복"
ap_dup dup_sfr2 \
  's|--source-fr rd-workflow-workspace/backlog/items/<선택한-항목>.md|--source-fr - --source-fr rd-workflow-workspace/backlog/items/<선택한-항목>.md|' \
  "--source-fr - 뒤 canonical 중복"

# (11e~11f) **옵션명 왼쪽 경계** — `x--size` 는 파서가 unknown arg 로 거부하는데,
#           오른쪽 경계만 보면 정상 1회로 세어진다 (7라운드 Finding 3).
ap_dup pre_size 's/ --size large/ x--size large/' "--size 앞 prefix 오타(x--size)"
ap_dup pre_sfr 's| --source-fr rd-workflow| x--source-fr rd-workflow|' \
  "--source-fr 앞 prefix 오타(x--source-fr)"

# (11) 읽기 불가 파일은 exit 2 — 계약 위반(1)으로 오분류하지 않는다 (5라운드 Finding 3)
ap_write "$AP_DIR/unreadable.md"
chmod 000 "$AP_DIR/unreadable.md"
if [[ -r "$AP_DIR/unreadable.md" ]]; then
  echo "ok: ap: 읽기 불가 케이스 건너뜀 (이 환경에서는 chmod 000 이 읽기를 막지 못함)"
else
  bash "$AP" "$AP_DIR/unreadable.md" >/dev/null 2>&1; ap_rc=$?
  [[ "$ap_rc" == "2" ]] && echo "ok: ap: 읽기 불가는 exit 2 (계약 위반으로 오분류 안 함)" \
    || { echo "FAIL: ap: 읽기 불가에서 exit $ap_rc (2 여야 한다)"; FAIL=1; }
fi
chmod 644 "$AP_DIR/unreadable.md" 2>/dev/null || true

# (12) 점검이 성립하지 않으면 exit 2 — 위반(1)과 구분한다
bash "$AP" "$AP_DIR/does-not-exist-$$.md" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "2" ]] && echo "ok: ap: 대상 파일 부재는 exit 2" \
  || { echo "FAIL: ap: 파일 부재에서 exit $ap_rc (2 여야 한다)"; FAIL=1; }
bash "$AP" >/dev/null 2>&1; ap_rc=$?
[[ "$ap_rc" == "2" ]] && echo "ok: ap: 인자 없음은 exit 2" \
  || { echo "FAIL: ap: 인자 없음에서 exit $ap_rc (2 여야 한다)"; FAIL=1; }
rm -rf "$AP_DIR"

[[ "$FAIL" == 0 ]] && echo "test_task_cli: ALL PASS" || echo "test_task_cli: FAIL"
exit "$FAIL"
