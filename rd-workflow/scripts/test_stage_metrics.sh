#!/usr/bin/env bash
# test_stage_metrics.sh — stage_metrics.tsv 실제 lifecycle 커밋 검증(A) + 조회 알고리즘
# 회귀(B) + 전이 로깅 계약(C) + CLI 인자 계약(D) 스위트
# (change-spec 2026-09-24-2310-stage-transition-timestamps, plan Task 4)
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD="${SCRIPT_DIR}/rd"
LC="${SCRIPT_DIR}/lifecycle/_lifecycle_common.sh"

# **실제 herdr 호출 차단.** promote.sh 가 session_launch 를 호출하므로, HERDR_ENV 가
# 하위 프로세스로 상속되면 fixture 실행만으로 실제 herdr pane 이 뜬다
# (test_archive_worktree.sh 의 동일 방어를 그대로 따른다).
export HERDR_ENV=
export RD_CHILD_SESSION=1

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "ok: $1"; }
fail() { FAIL=1; echo "FAIL: $1"; }

TMPROOT="$(mktemp -d)" || { echo "test_stage_metrics.sh: 임시 루트 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMPROOT" && -d "$TMPROOT" ]] || { echo "test_stage_metrics.sh: 임시 루트 경로 검증 실패" >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT
new_tmp() { mktemp -d "$TMPROOT/fixture.XXXXXXXX"; } # mktemp-scan: custom-handler — 값 반환 헬퍼, 호출부가 || 로 검사

# 이 스위트 안에서 archive_publish_content_check·emit_current_task_baseline·
# state_stage_metrics_report 를 직접(subshell 없이) 호출하는 케이스가 있어 한 번만
# source 한다 — 정의만 가져오고 부작용(top-level 실행문)은 없다(파일 확인 완료).
# shellcheck disable=SC1090
source "$LC"

# mk_task_file <dir> <status> <short-title> — test_task_cli.sh 의 fixture 패턴을 그대로
# 따른다(CURRENT_TASK.md + task-state 동시 생성, canonical 값만 지원).
mk_task_file() {
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
  local _ts_dir="$1/rd-workflow-workspace/.lifecycle"
  mkdir -p "$_ts_dir"
  cat > "$_ts_dir/task-state" <<TSEOF
schema=1
short-title=$3
status=$2
fr-branch=null
worktree-path=null
source-fr=-
TSEOF
}

# mk_sm_commit <repo_dir> <sm_content> <mode: normal|exec|symlink|missing> — CURRENT_TASK.md·
# task-state 는 두 커밋 사이에서 항상 동일하게 유지해(archive_publish_content_check 의
# 그 두 경로 검사가 항상 통과하도록) stage_metrics.tsv 변화만 격리해서 관찰한다.
# stdout = 새 커밋 OID.
mk_sm_commit() {
  local d="$1" content="$2" mode="${3:-normal}"
  mkdir -p "$d/rd-workflow-workspace/.lifecycle"
  emit_current_task_baseline > "$d/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\n' \
    > "$d/rd-workflow-workspace/.lifecycle/task-state"
  local sm="$d/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
  rm -f "$sm"
  case "$mode" in
    missing) : ;;
    normal) printf '%s' "$content" > "$sm" ;;
    exec) printf '%s' "$content" > "$sm"; chmod +x "$sm" ;;
    symlink) ln -s CURRENT_TASK.md "$sm" ;;
    *) echo "mk_sm_commit: 알 수 없는 mode: $mode" >&2; return 1 ;;
  esac
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -q --allow-empty -m "fixture: ${mode}" >/dev/null
  git -C "$d" rev-parse HEAD
}

# ---------------------------------------------------------------------------
# A. 실제 커밋·발행 검증 (F1/F6)
# ---------------------------------------------------------------------------
echo "== A. 실제 lifecycle 커밋 검증 =="

REPO="$(new_tmp)"
REPO="$(cd "$REPO" && pwd -P)"
mkdir -p "$REPO/rd-workflow"
cp -R "$SCRIPT_DIR" "$REPO/rd-workflow/scripts"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
mkdir -p "$REPO/rd-workflow-workspace/.lifecycle" "$REPO/rd-workflow-workspace/backlog/items"
cp "$SCRIPT_DIR/../../.gitignore" "$REPO/.gitignore"
emit_current_task_baseline > "$REPO/CURRENT_TASK.md"
printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
  > "$REPO/rd-workflow-workspace/.lifecycle/task-state"
printf '# Change Request\n\n## Source FR\n-\n' > "$REPO/REQUEST.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m seed

PROMOTE_SH="$REPO/rd-workflow/scripts/lifecycle/promote.sh"
ARCHIVE_SH="$REPO/rd-workflow/scripts/lifecycle/archive.sh"

# --- A1/A2/A3: rounda — promote → archive → 다음 worktree 에서 조회 ---
if ! bash "$PROMOTE_SH" --short-title rounda --size small --source-fr - >/tmp/rd_sm_a1.out 2>&1; then
  fail "A1: promote.sh 실행 실패 — $(cat /tmp/rd_sm_a1.out)"
else
  a1_line="$(git -C "$REPO/.worktrees/rounda" show HEAD:rd-workflow-workspace/.lifecycle/stage_metrics.tsv 2>/dev/null | grep -F "rounda" || true)"
  if [[ "$a1_line" == *"rounda"*"대기 중"*"구현 중"* ]]; then
    pass "A1: promote.sh 착수 커밋에 stage_metrics.tsv rounda 행이 실제로 남는다"
  else
    fail "A1: promote 착수 커밋에서 rounda 행을 찾지 못함 (내용: '$a1_line')"
  fi
fi

if out="$( cd "$REPO/.worktrees/rounda" && bash "$ARCHIVE_SH" --force-skip-review-check "테스트" 2>&1 )"; then
  a2_main="$(git -C "$REPO" rev-parse main)"
  a2_line="$(git -C "$REPO" show "${a2_main}:rd-workflow-workspace/.lifecycle/stage_metrics.tsv" 2>/dev/null | grep -F "rounda" | tail -1 || true)"
  if [[ "$a2_line" == *"rounda"*"대기 중"* ]]; then
    pass "A2: archive.sh 발행 커밋에 종료 행(→대기 중)이 실제로 들어있다"
  else
    fail "A2: 발행 커밋에서 rounda 종료 행을 찾지 못함 (내용: '$a2_line')"
  fi
else
  fail "A2: archive.sh 실행 실패 — $out"
fi

NEXT="$TMPROOT/rounda-next"
# --detach: REPO 자신이 이미 main 을 체크아웃하고 있어(기본 worktree), 같은 브랜치를
# 다른 worktree 에서 다시 체크아웃하면 git 이 거부한다. "다음 worktree" 를 재현하는
# 목적에는 detach 로 그 tip 커밋을 그대로 보는 것으로 충분하다.
if a3_wt_err="$(git -C "$REPO" worktree add --detach "$NEXT" main 2>&1)"; then
  a3_out="$(cd "$NEXT" && project_root="$NEXT" bash "$NEXT/rd-workflow/scripts/rd" task metrics --task rounda 2>&1)"
  if [[ "$a3_out" == *"rounda (종료됨)"* ]]; then
    pass "A3: 다음 worktree 에서도 종료된 회차(rounda)를 조회할 수 있다"
  else
    fail "A3: 다음 worktree 조회 결과에 '종료됨' 이 없음 — 출력: $a3_out"
  fi
  git -C "$REPO" worktree remove --force "$NEXT" >/dev/null 2>&1 || true
else
  fail "A3: 다음 worktree(git worktree add) 준비 실패 — $a3_wt_err"
fi

# --- A5: F1 잔여 — stage_metrics.tsv 가 worktree 에 아예 없는 상태에서 archive 가 exit 0 ---
if bash "$PROMOTE_SH" --short-title roundf --size small --source-fr - >/tmp/rd_sm_a5.out 2>&1; then
  rm -f "$REPO/.worktrees/roundf/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
  ( cd "$REPO/.worktrees/roundf" \
      && git rm -q --cached --ignore-unmatch rd-workflow-workspace/.lifecycle/stage_metrics.tsv >/dev/null 2>&1 \
      && git commit -q -m "fixture: stage_metrics.tsv 제거(F1 재현)" --allow-empty >/dev/null 2>&1 )
  if out="$( cd "$REPO/.worktrees/roundf" && bash "$ARCHIVE_SH" --force-skip-review-check "테스트" 2>&1 )"; then
    pass "A5: stage_metrics.tsv 부재 상태에서도 archive.sh 가 exit 0 으로 끝난다"
  else
    fail "A5: stage_metrics.tsv 부재 상태에서 archive.sh 가 실패함 — $out"
  fi
else
  fail "A5: roundf promote.sh 준비 실패 — $(cat /tmp/rd_sm_a5.out)"
fi

# --- A4: append-only 위반 직접 호출 검증 ---
D4="$(new_tmp)"
git -C "$D4" init -q -b main
git -C "$D4" config user.email t@t && git -C "$D4" config user.name t
BASE4="$(mk_sm_commit "$D4" $'# short_title\tfrom_status\tto_status\tepoch\nrounda\t대기 중\t구현 중\t100\n' normal)"
PUB4="$(mk_sm_commit "$D4" $'# short_title\tfrom_status\tto_status\tepoch\nrounda\t대기 중\tCORRUPT\t100\n' normal)"
if archive_publish_content_check "$D4" "$BASE4" "$PUB4" >/tmp/rd_sm_a4.out 2>&1; then
  fail "A4: 기존 행을 훼손한 발행 후보가 차단되지 않음"
else
  pass "A4: append-only 위반(기존 행 훼손)이 실제로 차단된다"
fi

# --- A6: F7 — baseline 에 stage_metrics.tsv 가 없는 최초 회차 ---
D6="$(new_tmp)"
git -C "$D6" init -q -b main
git -C "$D6" config user.email t@t && git -C "$D6" config user.name t
SM_SAMPLE=$'# short_title\tfrom_status\tto_status\tepoch\nx\ty\tz\t1\n'
BASE6="$(mk_sm_commit "$D6" "" missing)"
PUB6_OK="$(mk_sm_commit "$D6" "$SM_SAMPLE" normal)"
if archive_publish_content_check "$D6" "$BASE6" "$PUB6_OK" >/tmp/rd_sm_a6a.out 2>&1; then
  pass "A6a: baseline 부재 + 발행 후보가 정상 파일이면 통과한다"
else
  fail "A6a: baseline 부재인데 정상 파일 발행이 차단됨 — $(cat /tmp/rd_sm_a6a.out)"
fi
PUB6_EXEC="$(mk_sm_commit "$D6" "$SM_SAMPLE" exec)"
if archive_publish_content_check "$D6" "$BASE6" "$PUB6_EXEC" >/tmp/rd_sm_a6b.out 2>&1; then
  fail "A6b: baseline 부재라도 실행 비트 발행 후보는 차단돼야 한다"
else
  pass "A6b: baseline 부재 + 발행 후보가 실행 파일이면 차단된다(F7)"
fi
PUB6_SYM="$(mk_sm_commit "$D6" "$SM_SAMPLE" symlink)"
if archive_publish_content_check "$D6" "$BASE6" "$PUB6_SYM" >/tmp/rd_sm_a6c.out 2>&1; then
  fail "A6c: baseline 부재라도 symlink 발행 후보는 차단돼야 한다"
else
  pass "A6c: baseline 부재 + 발행 후보가 symlink 면 차단된다(F7)"
fi
PUB6_MISS="$(mk_sm_commit "$D6" "" missing)"
if archive_publish_content_check "$D6" "$BASE6" "$PUB6_MISS" >/tmp/rd_sm_a6d.out 2>&1; then
  pass "A6d: baseline·발행 후보 양쪽 다 없으면 통과한다"
else
  fail "A6d: 양쪽 다 없는데 차단됨 — $(cat /tmp/rd_sm_a6d.out)"
fi

# ---------------------------------------------------------------------------
# B. 조회 알고리즘 회귀 (F2/F3/F4) — state_stage_metrics_report 직접 호출, sleep 미사용
# ---------------------------------------------------------------------------
echo "== B. 조회 알고리즘 회귀 =="

B7="$TMPROOT/b7.tsv"
cat > "$B7" <<'EOF'
# short_title	from_status	to_status	epoch
smoke	대기 중	구현 중	100
smoke	구현 중	검증 중	700
smoke	검증 중	구현 중	1000
EOF
b7_out="$(state_stage_metrics_report "smoke" "$B7" 1300)"
b7_want=$'회차: smoke (진행 중)\n  구현 중: 2회, 확정 10분 + 진행 중 5분(잠정, 합계 15분)\n  검증 중: 1회, 총 5분'
if [[ "$b7_out" == "$b7_want" ]]; then
  pass "B7: change-spec §5 데이터 모델 예시(F3)가 값 그대로 재현된다"
else
  fail "B7: 기대값과 다름 — 출력:
$b7_out"
fi

B8="$TMPROOT/b8.tsv"
cat > "$B8" <<'EOF'
# short_title	from_status	to_status	epoch
rounda	대기 중	구현 중	100
rounda	구현 중	대기 중	400
roundB	대기 중	구현 중	500
EOF
b8a_out="$(state_stage_metrics_report "rounda" "$B8" 1000)"
b8b_out="$(state_stage_metrics_report "roundB" "$B8" 1000)"
if [[ "$b8a_out" == *"rounda (종료됨)"* && "$b8a_out" == *"구현 중: 1회, 총 5분"* ]]; then
  pass "B8: rounda(닫힘) 조회가 자기 구간만 반환한다(F2)"
else
  fail "B8: rounda 조회 결과가 기대와 다름 — $b8a_out"
fi
if [[ "$b8b_out" == *"roundB (진행 중)"* && "$b8b_out" == *"진행 중 8분(잠정)"* ]]; then
  pass "B8: roundB(열림) 조회가 rounda 와 섞이지 않는다(F2/AC8)"
else
  fail "B8: roundB 조회 결과가 기대와 다름 — $b8b_out"
fi

B9="$TMPROOT/b9.tsv"
cat > "$B9" <<'EOF'
# short_title	from_status	to_status	epoch
rounda	대기 중	구현 중	100
rounda	구현 중	대기 중	200
roundB	대기 중	구현 중	300
roundB	구현 중	대기 중	400
rounda	대기 중	구현 중	500
rounda	구현 중	검증 중	600
EOF
b9_out="$(state_stage_metrics_report "rounda" "$B9" 700)"
if [[ "$b9_out" == *"구현 중: 1회, 총 1분"* && "$b9_out" == *"검증 중: 1회, 진행 중 1분(잠정)"* ]]; then
  pass "B9: 같은 slug 재사용 시 조회가 마지막(두 번째) 구간만 반환한다(Review Focus)"
else
  fail "B9: 재사용 fixture 결과가 기대와 다름(1회차 값이 섞였을 가능성) — $b9_out"
fi

# --- B10: 무결성 위반 개별 fixture (F4) ---
B10a="$TMPROOT/b10a.tsv"
cat > "$B10a" <<'EOF'
# short_title	from_status	to_status	epoch
r	대기 중	구현 중	500
r	구현 중	검증 중	400
r	검증 중	대기 중	600
EOF
b10a_out="$(state_stage_metrics_report "r" "$B10a" 900)"
if [[ "$b10a_out" == *"구현 중: 1회, 측정 불가 (일부 구간 누락 가능)"* && "$b10a_out" == *"검증 중: 1회, 총 3분"* ]]; then
  pass "B10a: 닫힌 세그먼트 시간 역전이 (일부 구간 누락 가능)으로 표시된다"
else
  fail "B10a: 시간 역전 결과가 기대와 다름 — $b10a_out"
fi

B10b="$TMPROOT/b10b.tsv"
cat > "$B10b" <<'EOF'
# short_title	from_status	to_status	epoch
r	대기 중	구현 중	abc
r	구현 중	대기 중	300
EOF
b10b_out="$(state_stage_metrics_report "r" "$B10b" 900)"
if [[ "$b10b_out" == *"구현 중"*"측정 불가"* && "$b10b_out" != *"0분"* ]]; then
  pass "B10b: 유일 세그먼트 손상 시 '측정 불가'(0분이 아님)로 표시된다"
else
  fail "B10b: 유일 손상 세그먼트 결과가 기대와 다름 — $b10b_out"
fi

B10c="$TMPROOT/b10c.tsv"
cat > "$B10c" <<'EOF'
# short_title	from_status	to_status	epoch
r	대기 중	구현 중	abc
EOF
b10c_out="$(state_stage_metrics_report "r" "$B10c" 900)"
if [[ "$b10c_out" == *"진행 중(측정 불가 — 시작 시각 손상)"* ]]; then
  pass "B10c: 열린 행 epoch 가 숫자가 아니면 '진행 중(측정 불가 — 시작 시각 손상)'"
else
  fail "B10c: 열린 행 손상 결과가 기대와 다름 — $b10c_out"
fi

B10d="$TMPROOT/b10d.tsv"
cat > "$B10d" <<'EOF'
# short_title	from_status	to_status	epoch
r	대기 중	구현 중	5000
EOF
b10d_out="$(state_stage_metrics_report "r" "$B10d" 1000)"
if [[ "$b10d_out" == *"진행 중(측정 불가 — 시작 시각 손상)"* ]]; then
  pass "B10d: 열린 행 epoch 가 미래면 같은 '측정 불가' 메시지가 나온다"
else
  fail "B10d: 미래 epoch 결과가 기대와 다름 — $b10d_out"
fi

B10e="$TMPROOT/b10e.tsv"
cat > "$B10e" <<'EOF'
# short_title	from_status	to_status	epoch
r	대기 중	구현 중	100
r	검증 중	대기 중	300
EOF
b10e_out="$(state_stage_metrics_report "r" "$B10e" 900)"
if [[ "$b10e_out" == *"구현 중: 1회, 측정 불가 (일부 구간 누락 가능)"* ]]; then
  pass "B10e: 연결 불일치(from≠앞행 to)가 (일부 구간 누락 가능)으로 표시된다"
else
  fail "B10e: 연결 불일치 결과가 기대와 다름 — $b10e_out"
fi

B10f="$TMPROOT/b10f.tsv"
printf '# short_title\tfrom_status\tto_status\tepoch\nr\t대기 중\t구현 중\t100\nr\t구현 중\t대기 중\n' > "$B10f"
b10f_out1="$(state_stage_metrics_report "r" "$B10f" 1300)"
b10f_out2="$(state_stage_metrics_report "r" "$B10f" 1900)"
if [[ "$b10f_out1" == "$b10f_out2" && "$b10f_out1" == *"r (종료됨)"* && "$b10f_out1" == *"측정 불가 (일부 구간 누락 가능)"* ]]; then
  pass "B10f: 마지막 행 epoch 잘림 — 종료로 인식되고 now 와 무관하게 같은 결과(늘어나지 않음)"
else
  fail "B10f: 마지막 행 잘림 결과가 now 에 따라 달라지거나 기대와 다름 — now=1300: $b10f_out1 / now=1900: $b10f_out2"
fi

B10g="$TMPROOT/b10g.tsv"
printf '# short_title\tfrom_status\tto_status\tepoch\nr\t대기 중\t구현 중\t100\nr\t구현 중\t검증 중\nr\t검증 중\t대기 중\t500\n' > "$B10g"
b10g_out="$(state_stage_metrics_report "r" "$B10g" 900)"
if [[ "$b10g_out" == *"구현 중"*"측정 불가"*"일부 구간 누락 가능"* && "$b10g_out" == *"검증 중"*"측정 불가"*"일부 구간 누락 가능"* ]]; then
  pass "B10g: 중간 행 잘림 — 앞뒤 세그먼트 모두 불완전 표시되고 조용히 통과하지 않는다"
else
  fail "B10g: 중간 행 잘림 결과가 기대와 다름 — $b10g_out"
fi

B10h="$TMPROOT/b10h.tsv"
cat > "$B10h" <<'EOF'
# short_title	from_status	to_status	epoch
r	대기 중	구현 중	100
r	구현 중	검증 중	160
r	검증 중	구현 중	300
r	구현 중	검증 중	250
r	검증 중	구현 중	abc
EOF
b10h_out="$(state_stage_metrics_report "r" "$B10h" 500)"
if [[ "$b10h_out" == *"구현 중: 3회, 확정 1분 + 진행 중(측정 불가 — 시작 시각 손상) (일부 구간 누락 가능)"* \
      && "$b10h_out" == *"검증 중: 2회, 총 2분 (일부 구간 누락 가능)"* ]]; then
  pass "B10h: 유효+무효 닫힌 방문 + 무효 열린 방문 복합 — 확정 합계와 손상 표시가 서로를 가리지 않는다"
else
  fail "B10h: 복합 fixture 결과가 기대와 다름 — $b10h_out"
fi

# --- B11: short-title=- 안내 ---
TMPB11="$(new_tmp)"
export project_root="$TMPB11"
mk_task_file "$TMPB11" "대기 중" "-"
b11_out="$(bash "$RD" task metrics 2>&1)"
if [[ "$b11_out" == "현재 진행 중인 작업이 없습니다." ]]; then
  pass "B11: short-title=- 대상은 '현재 진행 중인 작업이 없습니다' 안내로 끝난다(AC8)"
else
  fail "B11: 안내 문구가 기대와 다름 — $b11_out"
fi
unset project_root

# --- B12: 숫자형 short-title 회차 분리 (Reviewer Turn 002 F1) ---
B12="$TMPROOT/b12.tsv"
cat > "$B12" <<'EOF'
# short_title	from_status	to_status	epoch
001	대기 중	구현 중	100
001	구현 중	대기 중	160
1	대기 중	검증 중	200
1	검증 중	대기 중	320
EOF
b12a_out="$(state_stage_metrics_report "001" "$B12" 1000)"
b12b_out="$(state_stage_metrics_report "1" "$B12" 1000)"
if [[ "$b12a_out" == *"구현 중: 1회, 총 1분"* && "$b12a_out" != *"검증 중"* ]]; then
  pass "B12: short-title '001' 조회가 '1' 회차와 섞이지 않는다(F1)"
else
  fail "B12: '001' 조회 결과에 다른 회차 값이 섞였다 — $b12a_out"
fi
if [[ "$b12b_out" == *"검증 중: 1회, 총 2분"* && "$b12b_out" != *"구현 중"* ]]; then
  pass "B12: short-title '1' 조회가 '001' 회차와 섞이지 않는다(F1)"
else
  fail "B12: '1' 조회 결과에 다른 회차 값이 섞였다 — $b12b_out"
fi

# ---------------------------------------------------------------------------
# C. 전이 로깅 계약 (AC1/AC4/AC5)
# ---------------------------------------------------------------------------
echo "== C. 전이 로깅 계약 =="

sm_lines() { # sm_lines <dir> — stage_metrics.tsv 의 데이터 행 수(헤더 제외)
  local f="$1/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
  [[ -f "$f" ]] || { echo 0; return; }
  grep -vc '^#' "$f" 2>/dev/null || echo 0
}

TMPC12="$(new_tmp)"
export project_root="$TMPC12"
mk_task_file "$TMPC12" "구현 중" "c12"
if bash "$RD" task set-status "검증 중" >/dev/null 2>/tmp/rd_sm_c12.err; then
  c12_row="$(grep -F "c12" "$TMPC12/rd-workflow-workspace/.lifecycle/stage_metrics.tsv" 2>/dev/null || true)"
  if [[ "$c12_row" == *"c12"*"구현 중"*"검증 중"* ]]; then
    pass "C12: 허용된 전이는 로그에 실제로 행이 추가된다(AC1)"
  else
    fail "C12: 허용 전이 후 로그 행을 찾지 못함 — $(cat "$TMPC12/rd-workflow-workspace/.lifecycle/stage_metrics.tsv" 2>/dev/null)"
  fi
else
  fail "C12: 허용 전이인데 set-status 가 실패함 — $(cat /tmp/rd_sm_c12.err)"
fi
unset project_root

TMPC13="$(new_tmp)"
export project_root="$TMPC13"
mk_task_file "$TMPC13" "구현 중" "c13"
before13="$(sm_lines "$TMPC13")"
bash "$RD" task set-status "완료" >/dev/null 2>/tmp/rd_sm_c13.err
c13_rc=$?
after13="$(sm_lines "$TMPC13")"
if [[ "$c13_rc" -eq 4 && "$after13" == "$before13" ]]; then
  pass "C13: 거부되는 전이는 exit 4 이고 로그 행 수가 늘지 않는다(AC4)"
else
  fail "C13: 거부 경로 결과가 기대와 다름 — rc=$c13_rc before=$before13 after=$after13"
fi
unset project_root

TMPC14="$(new_tmp)"
export project_root="$TMPC14"
mk_task_file "$TMPC14" "구현 중" "c14"
before14="$(sm_lines "$TMPC14")"
bash "$RD" task set-status "완료" --force >/dev/null 2>/tmp/rd_sm_c14.err
c14_rc=$?
after14="$(sm_lines "$TMPC14")"
if [[ "$c14_rc" -eq 0 && "$after14" -gt "$before14" ]]; then
  pass "C14: --force 로 전이표 밖 전이를 강제하면 exit 0 이고 로그가 늘어난다(AC4)"
else
  fail "C14: 강제 전이 결과가 기대와 다름 — rc=$c14_rc before=$before14 after=$after14"
fi
unset project_root

TMPC15="$(new_tmp)"
export project_root="$TMPC15"
mk_task_file "$TMPC15" "구현 중" "c15"
before15="$(sm_lines "$TMPC15")"
bash "$RD" task set-status "구현 중" >/dev/null 2>/tmp/rd_sm_c15.err
c15_rc=$?
after15="$(sm_lines "$TMPC15")"
if [[ "$c15_rc" -eq 0 && "$after15" == "$before15" ]]; then
  pass "C15: from==to 재기록은 로그 행 수가 불변이다(AC1 제약)"
else
  fail "C15: from==to 결과가 기대와 다름 — rc=$c15_rc before=$before15 after=$after15"
fi
unset project_root

TMPC16="$(new_tmp)"
export project_root="$TMPC16"
mk_task_file "$TMPC16" "구현 중" "c16"
mkdir -p "$TMPC16/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
c16_err="$(bash "$RD" task set-status "검증 중" 2>&1 >/dev/null)"
c16_rc=$?
c16_status="$(bash "$RD" task status 2>/dev/null)"
if [[ "$c16_rc" -eq 0 && "$c16_status" == "검증 중" && "$c16_err" == *"경고: stage_metrics.tsv 기록 실패"* ]]; then
  pass "C16: 로그 경로가 디렉터리에 선점돼도 전이는 성공하고 stderr 경고만 남는다(AC5)"
else
  fail "C16: 쓰기 실패 주입 결과가 기대와 다름 — rc=$c16_rc status=$c16_status err=$c16_err"
fi
unset project_root
rm -rf "$TMPC16/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"

# C16b — promote.sh·archive.sh 는 실제로 `set -euo pipefail` 아래에서 이 함수를 호출한다
# (두 파일 모두 shebang 다음 줄이 `set -euo pipefail`). archive.sh 안에서 병합·발행
# 커밋까지 실제로 재현하면 우리가 검사하려는 것(로그 함수의 안전성)과 무관한 이유로
# 병합이 실패할 여지가 커진다 — 그 대신 promote.sh/archive.sh 가 이 함수를 부르는 것과
# 똑같은 셸 옵션 조합(`set -euo pipefail`) 아래에서 직접 호출해, "쓰기가 실패해도
# `return 0`이라 `-e`가 이후 줄을 죽이지 않는다"는 실제 제약을 정확히 재현한다.
D16B="$(new_tmp)"
mkdir -p "$D16B/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"
if c16b_out="$( ( set -euo pipefail
    TASK_STATE_PATH="$D16B/rd-workflow-workspace/.lifecycle/task-state"
    state_log_stage_transition "c16b" "구현 중" "검증 중"
    echo "REACHED_AFTER" ) 2>&1 )"; then
  if [[ "$c16b_out" == *"경고: stage_metrics.tsv 기록 실패"* && "$c16b_out" == *"REACHED_AFTER"* ]]; then
    pass "C16b: promote.sh/archive.sh 와 같은 set -euo pipefail 환경에서도 로그 쓰기 실패가 이후 줄을 죽이지 않는다(AC5)"
  else
    fail "C16b: 경고 또는 REACHED_AFTER 가 출력에 없음 — $c16b_out"
  fi
else
  fail "C16b: set -euo pipefail 아래에서 로그 쓰기 실패가 오히려 셸을 중단시켰다 — $c16b_out"
fi

# ---------------------------------------------------------------------------
# D. CLI 인자 계약 (F5)
# ---------------------------------------------------------------------------
echo "== D. CLI 인자 계약 =="

TMPD="$(new_tmp)"
export project_root="$TMPD"
mk_task_file "$TMPD" "구현 중" "-"
printf '# short_title\tfrom_status\tto_status\tepoch\nrounda\t대기 중\t구현 중\t100\nrounda\t구현 중\t대기 중\t200\n' \
  > "$TMPD/rd-workflow-workspace/.lifecycle/stage_metrics.tsv"

d_err="$(bash "$RD" task metrics --task 2>&1 >/dev/null)"; d_rc=$?
[[ "$d_rc" -eq 1 && "$d_err" == *"--task 에 값이 없습니다"* ]] \
  && pass "D17a: --task 값 누락 → exit 1 + 안내" || fail "D17a: rc=$d_rc err=$d_err"

d_err="$(bash "$RD" task metrics --task '' 2>&1 >/dev/null)"; d_rc=$?
[[ "$d_rc" -eq 1 && "$d_err" == *"--task 에 값이 없습니다"* ]] \
  && pass "D17b: --task '' (빈 문자열) → exit 1 + 안내" || fail "D17b: rc=$d_rc err=$d_err"

d_err="$(bash "$RD" task metrics --task --help 2>&1 >/dev/null)"; d_rc=$?
[[ "$d_rc" -eq 1 && "$d_err" == *"--task 에 값이 없습니다"* ]] \
  && pass "D17c: --task 뒤에 옵션처럼 보이는 토큰 → 값 누락으로 취급(exit 1)" || fail "D17c: rc=$d_rc err=$d_err"

d_out="$(bash "$RD" task metrics --task rounda 2>&1)"; d_rc=$?
[[ "$d_rc" -eq 0 && "$d_out" == *"rounda (종료됨)"* ]] \
  && pass "D17d: --task rounda(정상 slug) → 정상 조회" || fail "D17d: rc=$d_rc out=$d_out"
unset project_root

echo "== 결과: PASS=$PASS FAIL=$FAIL =="
[[ "$FAIL" == 0 ]] && echo "test_stage_metrics: ALL PASS" || echo "test_stage_metrics: FAIL"
exit "$FAIL"
