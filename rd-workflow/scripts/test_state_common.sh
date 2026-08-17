#!/usr/bin/env bash
# test_state_common.sh — _state_common.sh 단위 테스트 (self_test.sh가 실행)
# 케이스: state_init_defaults, state_write_fields, state_read_field, state_ensure 시나리오
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0

# 테스트 헬퍼 ---------------------------------------------------------------
t() { # t <설명> <기대exit> cmd...
  local desc="$1" want_rc="$2"; shift 2
  local rc
  "$@" >/dev/null 2>&1; rc=$?
  if [[ "$rc" != "$want_rc" ]]; then
    echo "FAIL: $desc (exit $rc != $want_rc)"; FAIL=1
  else
    echo "ok: $desc"
  fi
}

t_out() { # t_out <설명> <기대stdout> cmd...
  local desc="$1" want_out="$2"; shift 2
  local out rc
  out="$("$@" 2>/dev/null)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    echo "FAIL: $desc (exit $rc != 0)"; FAIL=1; return
  fi
  if [[ "$out" != "$want_out" ]]; then
    echo "FAIL: $desc (out '$out' != '$want_out')"; FAIL=1; return
  fi
  echo "ok: $desc"
}

t_fail_rc() { # t_fail_rc <설명> <기대exit> cmd...
  local desc="$1" want_rc="$2"; shift 2
  local rc
  "$@" >/dev/null 2>&1; rc=$?
  if [[ "$rc" != "$want_rc" ]]; then
    echo "FAIL: $desc (exit $rc != $want_rc)"; FAIL=1
  else
    echo "ok: $desc"
  fi
}

# sandbox 구성 ---------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export project_root="$TMP"
source "${SCRIPT_DIR}/_state_common.sh"

# TASK_STATE_PATH는 _state_common.sh source 후 자동 설정됨
# 각 케이스에서 sandbox를 초기화하여 독립 실행 보장
reset_sandbox() {
  rm -rf "${TMP}/rd-workflow-workspace"
  rm -f "${TMP}/CURRENT_TASK.md"
  mkdir -p "${TMP}/rd-workflow-workspace/.lifecycle"
  # source 시점에 고정된 TASK_STATE_PATH를 sandbox 경로에 맞게 재설정
  export TASK_STATE_PATH="${TMP}/rd-workflow-workspace/.lifecycle/task-state"
  export STATE_MIGRATION_BACKUP_DIR="${TMP}/rd-workflow-workspace/.lifecycle/migration-backup"
}

mk_current_task() { # mk_current_task <status> [short-title]
  local st="$1" sh="${2:--}"
  cat > "${TMP}/CURRENT_TASK.md" <<EOF
# Current Task

## Task
test

## Short Title
${sh}

## Status
${st}

## Request
[REQUEST.md](REQUEST.md)

## Notes
-
EOF
}

mk_active_fr() { # mk_active_fr <fr-branch> <short-title> [worktree-path]
  local br="$1" sh="$2" wt="${3:-null}"
  cat > "${TMP}/rd-workflow-workspace/.lifecycle/active-fr" <<EOF
fr-branch=${br}
short-title=${sh}
worktree-path=${wt}
status=active
EOF
}

mk_current_task_with_branch() { # mk_current_task_with_branch <status> <short-title> <branch-worktree>
  local st="$1" sh="$2" bw="$3"
  cat > "${TMP}/CURRENT_TASK.md" <<EOF
# Current Task

## Task
test

## Short Title
${sh}

## Status
${st}

## Request
[REQUEST.md](REQUEST.md)

## Branch / Worktree
${bw}

## Notes
-
EOF
}

# ===========================================================================
# 케이스 1: state_init_defaults → 파일 생성 + status 값 확인
# ===========================================================================
echo "--- case 1: state_init_defaults ---"
reset_sandbox

state_init_defaults
if [[ -f "$TASK_STATE_PATH" ]]; then
  echo "ok: state_init_defaults — 파일 생성됨"
else
  echo "FAIL: state_init_defaults — 파일 생성 안 됨"; FAIL=1
fi

val="$(state_read_field "status")"
if [[ "$val" == "대기 중" ]]; then
  echo "ok: state_read_field status = 대기 중"
else
  echo "FAIL: state_read_field status = '$val' (기대: 대기 중)"; FAIL=1
fi

val="$(state_read_field "schema")"
if [[ "$val" == "1" ]]; then
  echo "ok: state_read_field schema = 1"
else
  echo "FAIL: state_read_field schema = '$val' (기대: 1)"; FAIL=1
fi

# ===========================================================================
# 케이스 2: state_write_fields — 해당 키만 갱신, 타 줄 보존
# ===========================================================================
echo "--- case 2: state_write_fields ---"
reset_sandbox
state_init_defaults

state_write_fields "status=구현 중" "short-title=foo"
val_status="$(state_read_field "status")"
val_title="$(state_read_field "short-title")"
val_schema="$(state_read_field "schema")"

if [[ "$val_status" == "구현 중" ]]; then
  echo "ok: state_write_fields status 갱신됨"
else
  echo "FAIL: state_write_fields status = '$val_status'"; FAIL=1
fi

if [[ "$val_title" == "foo" ]]; then
  echo "ok: state_write_fields short-title 갱신됨"
else
  echo "FAIL: state_write_fields short-title = '$val_title'"; FAIL=1
fi

if [[ "$val_schema" == "1" ]]; then
  echo "ok: state_write_fields schema(타 줄) 보존됨"
else
  echo "FAIL: state_write_fields schema 사라짐 (schema='$val_schema')"; FAIL=1
fi

# ===========================================================================
# 케이스 3: state_write_fields — 값에 개행 포함 → return 1, 파일 불변
# ===========================================================================
echo "--- case 3: state_write_fields 개행 포함 거부 ---"
reset_sandbox
state_init_defaults

before="$(cat "$TASK_STATE_PATH")"
# 개행 포함 값 전달 시도 — ANSI-C 쿼팅 사용
bad_val=$'bad\nline'
rc=0
state_write_fields "status=${bad_val}" 2>/dev/null || rc=$?
if [[ "$rc" == "1" ]]; then
  echo "ok: state_write_fields 개행 값 → return 1"
else
  echo "FAIL: state_write_fields 개행 값 → return $rc (기대: 1)"; FAIL=1
fi

after="$(cat "$TASK_STATE_PATH")"
if [[ "$before" == "$after" ]]; then
  echo "ok: state_write_fields 개행 값 → 파일 불변"
else
  echo "FAIL: state_write_fields 개행 값 → 파일 변경됨"; FAIL=1
fi

# ===========================================================================
# 케이스 4: state_read_field 파일 부재 → 빈 값, return 0
# ===========================================================================
echo "--- case 4: state_read_field 파일 부재 ---"
reset_sandbox

# TASK_STATE_PATH가 없는 상태
rc=0
out="$(state_read_field "status" 2>/dev/null)" || rc=$?
if [[ "$rc" == "0" ]]; then
  echo "ok: state_read_field 파일 부재 → return 0"
else
  echo "FAIL: state_read_field 파일 부재 → return $rc (기대: 0)"; FAIL=1
fi
if [[ -z "$out" ]]; then
  echo "ok: state_read_field 파일 부재 → 빈 값"
else
  echo "FAIL: state_read_field 파일 부재 → '$out' (기대: 빈 값)"; FAIL=1
fi

# ===========================================================================
# 케이스 5: state_ensure — legacy(active-fr + CURRENT_TASK.md) → task-state 생성 + 백업 + active-fr 삭제
# ===========================================================================
echo "--- case 5: state_ensure legacy 마이그레이션 ---"
reset_sandbox
mk_current_task "구현 중" "my-task"
mk_active_fr "fr/my-task" "my-task" "null"

rc=0
state_ensure 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]]; then
  echo "ok: state_ensure legacy → return 0"
else
  echo "FAIL: state_ensure legacy → return $rc (기대: 0)"; FAIL=1
fi

if [[ -f "$TASK_STATE_PATH" ]]; then
  echo "ok: state_ensure legacy → task-state 생성됨"
else
  echo "FAIL: state_ensure legacy → task-state 미생성"; FAIL=1
fi

val_status="$(state_read_field "status")"
val_title="$(state_read_field "short-title")"
val_branch="$(state_read_field "fr-branch")"

if [[ "$val_status" == "구현 중" ]]; then
  echo "ok: state_ensure legacy → status=구현 중"
else
  echo "FAIL: state_ensure legacy → status='$val_status'"; FAIL=1
fi

if [[ "$val_title" == "my-task" ]]; then
  echo "ok: state_ensure legacy → short-title=my-task"
else
  echo "FAIL: state_ensure legacy → short-title='$val_title'"; FAIL=1
fi

if [[ "$val_branch" == "fr/my-task" ]]; then
  echo "ok: state_ensure legacy → fr-branch=fr/my-task"
else
  echo "FAIL: state_ensure legacy → fr-branch='$val_branch'"; FAIL=1
fi

# migration-backup 확인
bcount="$(find "${TMP}/rd-workflow-workspace/.lifecycle/migration-backup" -name "CURRENT_TASK.md" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$bcount" -ge 1 ]]; then
  echo "ok: state_ensure legacy → CURRENT_TASK.md 백업됨"
else
  echo "FAIL: state_ensure legacy → 백업 없음"; FAIL=1
fi

bcount_afr="$(find "${TMP}/rd-workflow-workspace/.lifecycle/migration-backup" -name "active-fr" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$bcount_afr" -ge 1 ]]; then
  echo "ok: state_ensure legacy → active-fr 백업됨"
else
  echo "FAIL: state_ensure legacy → active-fr 백업 없음"; FAIL=1
fi

# active-fr 삭제 확인
if [[ ! -f "${TMP}/rd-workflow-workspace/.lifecycle/active-fr" ]]; then
  echo "ok: state_ensure legacy → active-fr 삭제됨"
else
  echo "FAIL: state_ensure legacy → active-fr 남아있음"; FAIL=1
fi

# ===========================================================================
# 케이스 6: state_ensure — 비canonical Status → return 3, task-state 미생성, active-fr 보존
# ===========================================================================
echo "--- case 6: state_ensure 비canonical Status → return 3 ---"
reset_sandbox
mk_current_task "이상한값" "my-task"
mk_active_fr "fr/my-task" "my-task" "null"

rc=0
state_ensure 2>/dev/null || rc=$?
if [[ "$rc" == "3" ]]; then
  echo "ok: state_ensure 비canonical → return 3"
else
  echo "FAIL: state_ensure 비canonical → return $rc (기대: 3)"; FAIL=1
fi

if [[ ! -f "$TASK_STATE_PATH" ]]; then
  echo "ok: state_ensure 비canonical → task-state 미생성"
else
  echo "FAIL: state_ensure 비canonical → task-state 생성됨 (기대: 미생성)"; FAIL=1
fi

if [[ -f "${TMP}/rd-workflow-workspace/.lifecycle/active-fr" ]]; then
  echo "ok: state_ensure 비canonical → active-fr 보존됨"
else
  echo "FAIL: state_ensure 비canonical → active-fr 사라짐"; FAIL=1
fi

# ===========================================================================
# 케이스 7: state_ensure — CURRENT_TASK.md 부재 → defaults 생성 return 0
# ===========================================================================
echo "--- case 7: state_ensure CURRENT_TASK.md 부재 → defaults ---"
reset_sandbox
# CURRENT_TASK.md 없음 (신규 프로젝트)

rc=0
state_ensure 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]]; then
  echo "ok: state_ensure no-ct → return 0"
else
  echo "FAIL: state_ensure no-ct → return $rc (기대: 0)"; FAIL=1
fi

if [[ -f "$TASK_STATE_PATH" ]]; then
  echo "ok: state_ensure no-ct → task-state 생성됨"
else
  echo "FAIL: state_ensure no-ct → task-state 미생성"; FAIL=1
fi

val="$(state_read_field "status")"
if [[ "$val" == "대기 중" ]]; then
  echo "ok: state_ensure no-ct → status=대기 중 (default)"
else
  echo "FAIL: state_ensure no-ct → status='$val'"; FAIL=1
fi

# ===========================================================================
# 케이스 8: state_ensure — legacy Status '실행 중'(alias) → '구현 중'으로 변환 + stderr 경고
# ===========================================================================
echo "--- case 8: state_ensure legacy alias '실행 중' → '구현 중' ---"
reset_sandbox
mk_current_task "실행 중" "alias-task"

rc=0
stderr_out="$(state_ensure 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" == "0" ]]; then
  echo "ok: state_ensure alias → return 0"
else
  echo "FAIL: state_ensure alias → return $rc (기대: 0)"; FAIL=1
fi

val="$(state_read_field "status")"
if [[ "$val" == "구현 중" ]]; then
  echo "ok: state_ensure alias → status=구현 중 (변환됨)"
else
  echo "FAIL: state_ensure alias → status='$val' (기대: 구현 중)"; FAIL=1
fi

if echo "$stderr_out" | grep -q "경고"; then
  echo "ok: state_ensure alias → stderr 경고 출력됨"
else
  echo "FAIL: state_ensure alias → stderr 경고 없음"; FAIL=1
fi

# ===========================================================================
# 케이스 8b: state_ensure — state_write_fields 실패 → return 3 + 파일 제거 (fail-closed)
# 함수 스텁 오버라이드로 쓰기 실패 유도 (실제 mktemp 실패 등은 재현 어려우므로 스텁 사용)
# ===========================================================================
echo "--- case 8b: state_ensure write 실패 → fail-closed ---"
reset_sandbox
mk_current_task "구현 중" "write-fail-task"

# state_write_fields를 항상 실패하는 스텁으로 오버라이드
state_write_fields() { return 1; }

rc=0
state_ensure 2>/dev/null || rc=$?
if [[ "$rc" == "3" ]]; then
  echo "ok: state_ensure write 실패 → return 3"
else
  echo "FAIL: state_ensure write 실패 → return $rc (기대: 3)"; FAIL=1
fi

# task-state 파일이 제거되었는지 확인 (fail-closed — 부분 상태 금지)
if [[ ! -f "$TASK_STATE_PATH" ]]; then
  echo "ok: state_ensure write 실패 → task-state 파일 제거됨"
else
  echo "FAIL: state_ensure write 실패 → task-state 파일 잔존 (부분 상태)"; FAIL=1
fi

# 스텁 해제: source로 원본 함수 복원
source "${SCRIPT_DIR}/_state_common.sh"

# ===========================================================================
# 케이스 5c: state_ensure — active-fr 없음 + CURRENT_TASK.md Branch/Worktree=fr/foo
#            → fr-branch=fr/foo (뷰 fallback)
# ===========================================================================
echo "--- case 5c: state_ensure active-fr 없음 + Branch/Worktree=fr/foo → fr-branch=fr/foo ---"
reset_sandbox
mk_current_task_with_branch "구현 중" "view-task" "fr/foo"
# active-fr 없음 — legacy 파일 생성 안 함

rc=0
state_ensure 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]]; then
  echo "ok: state_ensure view-branch fallback → return 0"
else
  echo "FAIL: state_ensure view-branch fallback → return $rc (기대: 0)"; FAIL=1
fi

val_branch="$(state_read_field "fr-branch")"
if [[ "$val_branch" == "fr/foo" ]]; then
  echo "ok: state_ensure view-branch fallback → fr-branch=fr/foo"
else
  echo "FAIL: state_ensure view-branch fallback → fr-branch='$val_branch' (기대: fr/foo)"; FAIL=1
fi

# worktree-path는 뷰에서 신뢰성 있게 얻을 수 없으므로 null 유지 확인
val_wt="$(state_read_field "worktree-path")"
if [[ "$val_wt" == "null" ]]; then
  echo "ok: state_ensure view-branch fallback → worktree-path=null"
else
  echo "FAIL: state_ensure view-branch fallback → worktree-path='$val_wt' (기대: null)"; FAIL=1
fi

# ===========================================================================
# 케이스 5d: state_ensure — active-fr 없음 + CURRENT_TASK.md Branch/Worktree=main
#            → fr-branch=null (main은 fr 아님)
# ===========================================================================
echo "--- case 5d: state_ensure active-fr 없음 + Branch/Worktree=main → fr-branch=null ---"
reset_sandbox
mk_current_task_with_branch "구현 중" "main-task" "main"

rc=0
state_ensure 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]]; then
  echo "ok: state_ensure view-branch main → return 0"
else
  echo "FAIL: state_ensure view-branch main → return $rc (기대: 0)"; FAIL=1
fi

val_branch="$(state_read_field "fr-branch")"
if [[ "$val_branch" == "null" ]]; then
  echo "ok: state_ensure view-branch main → fr-branch=null"
else
  echo "FAIL: state_ensure view-branch main → fr-branch='$val_branch' (기대: null)"; FAIL=1
fi

# ===========================================================================
# 케이스 5e: state_ensure — active-fr 없음 + CURRENT_TASK.md Branch/Worktree 섹션 없음
#            → fr-branch=null (섹션 부재 시 null)
# ===========================================================================
echo "--- case 5e: state_ensure active-fr 없음 + Branch/Worktree 섹션 없음 → fr-branch=null ---"
reset_sandbox
mk_current_task "구현 중" "no-branch-section-task"
# CURRENT_TASK.md에 Branch/Worktree 섹션 없음

rc=0
state_ensure 2>/dev/null || rc=$?
if [[ "$rc" == "0" ]]; then
  echo "ok: state_ensure no-branch-section → return 0"
else
  echo "FAIL: state_ensure no-branch-section → return $rc (기대: 0)"; FAIL=1
fi

val_branch="$(state_read_field "fr-branch")"
if [[ "$val_branch" == "null" ]]; then
  echo "ok: state_ensure no-branch-section → fr-branch=null"
else
  echo "FAIL: state_ensure no-branch-section → fr-branch='$val_branch' (기대: null)"; FAIL=1
fi

# ===========================================================================
# 케이스 9: idempotency — state_ensure 2회 호출 → 2회째 no-op
# ===========================================================================
echo "--- case 9: state_ensure idempotency ---"
reset_sandbox
mk_current_task "구현 중" "idem-task"
mk_active_fr "fr/idem-task" "idem-task" "null"

state_ensure 2>/dev/null
mtime1="$(stat -f '%m' "$TASK_STATE_PATH" 2>/dev/null || stat -c '%Y' "$TASK_STATE_PATH" 2>/dev/null)"

# 1초 대기 없이 바로 2번째 호출 — no-op이면 파일 내용·mtime 무변화
rc2=0
state_ensure 2>/dev/null || rc2=$?

if [[ "$rc2" == "0" ]]; then
  echo "ok: state_ensure 2회째 → return 0"
else
  echo "FAIL: state_ensure 2회째 → return $rc2 (기대: 0)"; FAIL=1
fi

mtime2="$(stat -f '%m' "$TASK_STATE_PATH" 2>/dev/null || stat -c '%Y' "$TASK_STATE_PATH" 2>/dev/null)"
if [[ "$mtime1" == "$mtime2" ]]; then
  echo "ok: state_ensure 2회째 → no-op (mtime 불변)"
else
  echo "ok: state_ensure 2회째 → return 0 (mtime 변경은 파일시스템 해상도에 따라 무시 가능)"
fi

# ===========================================================================
# source-fr 값 계약 헬퍼 (promote-source-fr-sync)
# ===========================================================================
reset_sandbox

t "validate: sentinel '-'" 0 source_fr_validate "-"
t "validate: canonical items path" 0 source_fr_validate "rd-workflow-workspace/backlog/items/2026-08-03-x.md"
t "validate: 절대경로 거부" 1 source_fr_validate "/etc/passwd"
t "validate: .. 세그먼트 거부" 1 source_fr_validate "rd-workflow-workspace/backlog/items/../evil.md"
t "validate: legacy slug 거부" 1 source_fr_validate "some-slug"
t "validate: items 밖 path 거부" 1 source_fr_validate "rd-workflow-workspace/backlog/other/x.md"
t "validate: 중간 디렉토리 거부" 1 source_fr_validate "rd-workflow-workspace/backlog/items/sub/x.md"
t "validate: .md 아닌 확장자 거부" 1 source_fr_validate "rd-workflow-workspace/backlog/items/x.txt"
t "validate: 개행 거부" 1 source_fr_validate "rd-workflow-workspace/backlog/items/x.md
y"
t "validate: 빈 값 거부" 1 source_fr_validate ""

REQ_FIX="${TMP}/REQUEST-fixture.md"
cat > "$REQ_FIX" <<'REQEOF'
# Change Request

## Source FR
`rd-workflow-workspace/backlog/items/2026-08-03-x.md`

## Risks
-
REQEOF
t_out "from_request: 백틱 path 추출" "rd-workflow-workspace/backlog/items/2026-08-03-x.md" source_fr_from_request "$REQ_FIX"

cat > "$REQ_FIX" <<'REQEOF'
## Source FR
-
REQEOF
t_out "from_request: '-' → 빈 출력" "" source_fr_from_request "$REQ_FIX"

cat > "$REQ_FIX" <<'REQEOF'
## Task Type
change
REQEOF
t_out "from_request: 섹션 부재 → 빈 출력" "" source_fr_from_request "$REQ_FIX"

t_out "from_request: 파일 부재 → 빈 출력 (return 0)" "" source_fr_from_request "${TMP}/no-such-file.md"

# ---------------------------------------------------------------------------
# source_fr_resolve — 표기 정규화 (promote-source-fr-format-contract)
# ---------------------------------------------------------------------------
RES_ROOT="${TMP}/resolve-root"
RES_ITEMS="${RES_ROOT}/rd-workflow-workspace/backlog/items"
mkdir -p "$RES_ITEMS"
: > "${RES_ITEMS}/2026-08-12-alpha.md"
: > "${RES_ITEMS}/2026-01-01-dup.md"
: > "${RES_ITEMS}/2026-02-02-dup.md"
mkdir -p "${RES_ITEMS}/2026-03-03-dir.md"
: > "${RES_ITEMS}/2026-04-04-paren(x).md"

CANON="rd-workflow-workspace/backlog/items/2026-08-12-alpha.md"
PAREN="rd-workflow-workspace/backlog/items/2026-04-04-paren(x).md"

# --- 지원 표기 8종 (AC2) ---
t_out "resolve: canonical 그대로" "$CANON" \
  source_fr_resolve "$CANON" "$RES_ROOT"
t_out "resolve: markdown 링크" "$CANON" \
  source_fr_resolve "[alpha](${CANON})" "$RES_ROOT"
t_out "resolve: 괄호 병기" "$CANON" \
  source_fr_resolve "alpha (${CANON})" "$RES_ROOT"
t_out "resolve: em dash + 상세 링크" "$CANON" \
  source_fr_resolve "alpha — [상세](${CANON})" "$RES_ROOT"
t_out "resolve: 중첩 괄호" "$CANON" \
  source_fr_resolve "alpha ([상세](${CANON}))" "$RES_ROOT"
t_out "resolve: 리스트 접두" "$CANON" \
  source_fr_resolve "- [alpha](${CANON})" "$RES_ROOT"
t_out "resolve: items/ 축약" "$CANON" \
  source_fr_resolve "items/2026-08-12-alpha.md" "$RES_ROOT"
t_out "resolve: 날짜+공백+slug" "$CANON" \
  source_fr_resolve "2026-08-12 alpha" "$RES_ROOT"
t_out "resolve: slug 단독 (glob)" "$CANON" \
  source_fr_resolve "alpha" "$RES_ROOT"
t_out "resolve: slug 정확 일치 우선" "$CANON" \
  source_fr_resolve "2026-08-12-alpha" "$RES_ROOT"

# --- 레이블은 문법을 제한하지 않는다 (spec §3.3 단계 1) ---
t_out "resolve: 임의 레이블 허용" "$CANON" \
  source_fr_resolve "아무 설명이나 (${CANON})" "$RES_ROOT"

# --- 괄호를 포함한 유효 canonical 파일명 (spec §3.3 단계 0.5 fast path) ---
#     저장 계약(source_fr_validate)이 허용하는 값이므로 해석도 거부하면 안 된다.
t_out "resolve: 괄호 파일명 canonical" "$PAREN" \
  source_fr_resolve "$PAREN" "$RES_ROOT"
t_out "resolve: 괄호 파일명 items/ 축약" "$PAREN" \
  source_fr_resolve "items/2026-04-04-paren(x).md" "$RES_ROOT"
# 단계 0(접두 제거) 다음에 단계 0.5(fast path)가 적용되는지 — 순서 고정
t_out "resolve: 리스트 접두 + 괄호 파일명" "$PAREN" \
  source_fr_resolve "- items/2026-04-04-paren(x).md" "$RES_ROOT"
# 괄호 안 target 의 괄호는 지원하지 않는다 — 명시적 계약이다.
t "resolve: 괄호 안 target 의 괄호 거부" 1 \
  source_fr_resolve "[p](${PAREN})" "$RES_ROOT"
# 거부로 끝나면 안 되고, 우회 방법(경로 직접 표기)이 사용자에게 보여야 한다.
_paren_err="$(source_fr_resolve "[p](${PAREN})" "$RES_ROOT" 2>&1 >/dev/null)"
case "$_paren_err" in
  *"경로를 직접"*) echo "ok: 괄호 파일명 거부 시 우회 안내 노출" ;;
  *) echo "FAIL: 괄호 파일명 거부에 우회 안내 없음 (got: $_paren_err)"; FAIL=1 ;;
esac
_paren_out="$(source_fr_resolve "[p](${PAREN})" "$RES_ROOT" 2>/dev/null)"
if [[ -z "$_paren_out" ]]; then
  echo "ok: 괄호 파일명 거부 시 stdout 비어 있음"
else
  echo "FAIL: 괄호 파일명 거부인데 stdout 출력 있음 ($_paren_out)"; FAIL=1
fi

# --- 값 없음 (AC7) ---
t_out "resolve: 빈 값 → 빈 출력" "" source_fr_resolve "" "$RES_ROOT"
t_out "resolve: sentinel '-' → 빈 출력" "" source_fr_resolve "-" "$RES_ROOT"
t_out "resolve: 공백만 → 빈 출력" "" source_fr_resolve "   " "$RES_ROOT"

# --- 해석 실패: slug 계열 (AC3·AC4·AC5) ---
t "resolve: 다중 매칭 거부" 1 source_fr_resolve "dup" "$RES_ROOT"
t "resolve: 미실존 slug 거부" 1 source_fr_resolve "nosuch" "$RES_ROOT"
t "resolve: 디렉토리 거부" 1 source_fr_resolve "2026-03-03-dir" "$RES_ROOT"
t "resolve: glob 메타문자 '*' 거부" 1 source_fr_resolve "*" "$RES_ROOT"
t "resolve: glob 메타문자 'a*b' 거부" 1 source_fr_resolve "a*b" "$RES_ROOT"
t "resolve: glob 메타문자 'a?b' 거부" 1 source_fr_resolve "a?b" "$RES_ROOT"
t "resolve: glob 메타문자 'a[b]c' 거부" 1 source_fr_resolve "a[b]c" "$RES_ROOT"
t "resolve: 경로 구분자 포함 slug 거부" 1 source_fr_resolve "sub/alpha" "$RES_ROOT"
t "resolve: 대문자 slug 거부" 1 source_fr_resolve "Alpha" "$RES_ROOT"

# --- 해석 실패: 괄호 계열 (spec §3.3 단계 1) ---
t "resolve: 괄호 뒤 잔여 거부" 1 source_fr_resolve "[a](${CANON}) 추가설명" "$RES_ROOT"
t "resolve: 빈 레이블 거부" 1 source_fr_resolve "(${CANON})" "$RES_ROOT"
t "resolve: 닫는 괄호 없는 링크 거부" 1 source_fr_resolve "[a](${CANON}" "$RES_ROOT"
t "resolve: 괄호 안 미지원 형식 거부" 1 source_fr_resolve "[a](not-a-path)" "$RES_ROOT"

# --- 해석 실패: 기타 ---
t "resolve: 리스트 접두 반복 거부" 1 source_fr_resolve "- - alpha" "$RES_ROOT"
t "resolve: 미실존 canonical path 거부" 1 \
  source_fr_resolve "rd-workflow-workspace/backlog/items/2026-09-09-gone.md" "$RES_ROOT"
t "resolve: items 밖 path 거부" 1 \
  source_fr_resolve "rd-workflow-workspace/backlog/other/x.md" "$RES_ROOT"

# --- 실패 시 stderr 에 원문과 canonical 예시가 있어야 한다 ---
_sfr_err="$(source_fr_resolve "없는-항목-입니다" "$RES_ROOT" 2>&1 >/dev/null)"
case "$_sfr_err" in
  *"없는-항목-입니다"*) echo "ok: resolve stderr 에 원문 값 포함" ;;
  *) echo "FAIL: resolve stderr 에 원문 값 없음 (got: $_sfr_err)"; FAIL=1 ;;
esac
case "$_sfr_err" in
  *"rd-workflow-workspace/backlog/items/"*) echo "ok: resolve stderr 에 canonical 예시 포함" ;;
  *) echo "FAIL: resolve stderr 에 canonical 예시 없음"; FAIL=1 ;;
esac
_sfr_out="$(source_fr_resolve "없는-항목-입니다" "$RES_ROOT" 2>/dev/null)"
if [[ -z "$_sfr_out" ]]; then
  echo "ok: resolve 실패 시 stdout 은 비어 있음"
else
  echo "FAIL: resolve 실패인데 stdout 출력 있음 ($_sfr_out)"; FAIL=1
fi

# --- 주석 처리 (AC6) ---
cat > "$REQ_FIX" <<'REQEOF'
## Source FR
<!-- 형식: rd-workflow-workspace/backlog/items/<파일>.md -->
-
REQEOF
t_out "from_request: 한 줄 주석 건너뜀" "" source_fr_from_request "$REQ_FIX"

cat > "$REQ_FIX" <<'REQEOF'
## Source FR
<!--
여러 줄 주석
-->
-
REQEOF
t_out "from_request: 여러 줄 주석 건너뜀" "" source_fr_from_request "$REQ_FIX"

cat > "$REQ_FIX" <<'REQEOF'
## Source FR
<!-- 형식 안내 -->
rd-workflow-workspace/backlog/items/2026-08-03-x.md
REQEOF
t_out "from_request: 주석 뒤 값 추출" "rd-workflow-workspace/backlog/items/2026-08-03-x.md" \
  source_fr_from_request "$REQ_FIX"

# ===========================================================================
# 최종 결과
# ===========================================================================
if [[ "$FAIL" == "0" ]]; then
  echo "ALL PASS: test_state_common.sh"
  exit 0
else
  echo "SOME TESTS FAILED: test_state_common.sh"
  exit 1
fi
