#!/bin/bash
# test_guard_block_log.sh — 가드 차단 계측(_guard_common.sh 의 guard_deny)의 계약 검증.
# macOS /bin/bash 3.2 호환.
#
# **핵심은 「계측이 판정을 바꾸지 않는가」다.** 로그를 쓸 수 없는 두 상황에서 종료 코드가
# 보존되는지 직접 검증한다 — ① 쓰기 불가 경로(AC 4) ② 외부 바이너리 부재(AC 4b). ②는 실제
# 버그였다: 초판이 `tr`·`cut` 에 의존해 그것들이 없는 PATH 에서 **차단(2)이 127 로 나갔다.**
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="/bin/bash"
[[ -x "$BASH_BIN" ]] || BASH_BIN="$(command -v bash)"
PASS=0
FAIL=0
WORK=""

cleanup() { if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf "$WORK"; WORK=""; fi; }
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }

# 템플릿을 쓸 수 없다: 실패 시 FAIL 진단과 `PASS=0 FAIL=1` 집계를 함께 내야 하는데
# 가드 템플릿의 종결자 자리는 `exit N`·`return N` 하나만 허용한다. 마커는 **집계 보존**을 위한
# 것이고 경로 안전성을 대신하지 않으므로, 템플릿 둘째 줄에 해당하는 경로 검증은 같은 집계
# 규약으로 따로 둔다 — 없으면 `rc=0 + 빈 출력`에서 아래 `R="$WORK/ac1"` 이 `/ac1` 이 된다
# (Turn 002 F2).
WORK="$(mktemp -d)" || { echo "  FAIL: mktemp 실패 — 검증 불가" >&2; echo "test_guard_block_log: PASS=0 FAIL=1"; exit 1; }   # mktemp-scan: custom-handler
[[ -n "$WORK" && -d "$WORK" ]] || { echo "  FAIL: mktemp 경로 검증 실패 (TMPDIR='${TMPDIR:-}') — 검증 불가" >&2; echo "test_guard_block_log: PASS=0 FAIL=1"; exit 1; }   # mktemp-scan: custom-handler
LOG_REL="rd-workflow-workspace/.lifecycle/guard-block-audit.log"

# 가드를 흉내내는 최소 스크립트를 만든다. 실제 hook 을 쓰지 않는 이유는 이 테스트의 대상이
# 개별 가드의 판정이 아니라 **`guard_deny` 의 계약**이기 때문이다 (개별 판정은 각 hook 테스트가
# 덮는다). 차단 지점에서 이 헬퍼를 부르면 기록·종료가 계약대로인지가 검증 대상이다.
mk_guard() { # mk_guard <루트> <종료코드>
  local root="$1" rc="$2"
  mkdir -p "$root"
  cat > "$root/fake_guard.sh" <<GUARD
#!/usr/bin/env bash
set -euo pipefail
project_root="$root"
source "$HOOK_DIR/_guard_common.sh"
read_hook_input
if [ "$rc" = "2" ]; then guard_deny; fi
exit $rc
GUARD
}

# mk_guard_reason <루트> <reason> — guard_deny 를 reason 식별자 인자와 함께 부른다
# (guard-block-reason-identifier). mk_guard 와 달리 항상 차단(exit 2)만 흉내낸다 —
# reason 필드 검증에는 통과 경로가 필요 없다.
mk_guard_reason() {
  local root="$1" reason="$2"
  mkdir -p "$root"
  cat > "$root/fake_guard.sh" <<GUARD
#!/usr/bin/env bash
set -euo pipefail
project_root="$root"
source "$HOOK_DIR/_guard_common.sh"
read_hook_input
guard_deny "$reason"
GUARD
}

# **상속된 RD_GUARD_BLOCK_LOG 를 끊는다.** `self_test.sh` 는 검증이 저장소 감사 로그를
# 오염시키지 않도록 이 변수를 export 하는데, 기본 경로 동작을 검증하는 케이스가 그것을
# 물려받으면 로그가 fixture 밖에 쓰여 전부 실패한다 (실측). override 자체는 아래 전용
# 케이스에서 따로 검증한다.
# env 옵션(-u)은 반드시 대입 인자보다 앞에 온다 — 뒤에 두면 실행 파일 이름으로 해석돼 rc 127.
run_guard() { # run_guard <루트> <stdin> — stdout/stderr 버리고 exit code 만 돌려준다
  printf '%s' "$2" | env -u RD_GUARD_BLOCK_LOG "$BASH_BIN" "$1/fake_guard.sh" >/dev/null 2>&1
}

INPUT_BASH='{"session_id":"sess-abc","tool_name":"Bash","tool_input":{"command":"git push --force"}}'
INPUT_EDIT='{"session_id":"sess-xyz","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.md"}}'

# --- AC 1: 차단(exit 2) 시 한 줄 append ---
R="$WORK/ac1"; mk_guard "$R" 2
run_guard "$R" "$INPUT_BASH"; rc=$?
[[ "$rc" -eq 2 ]] && ok || bad "AC1 차단 종료 코드 — 기대 2, 실제 $rc"
if [[ -f "$R/$LOG_REL" ]]; then ok; else bad "AC1 로그 파일이 만들어지지 않았습니다"; fi
n="$(wc -l < "$R/$LOG_REL" 2>/dev/null | tr -d ' ')"
[[ "$n" == "1" ]] && ok || bad "AC1 로그 줄 수 — 기대 1, 실제 '$n'"

# --- guard-block-reason-identifier: reason 필드 있음/없음 ---
# AC1 은 무인자 호출이라 reason 필드가 없어야 한다(하위호환 — 필드 누락이지 빈 값 강제가 아님).
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"reason="*) bad "무인자 호출인데 reason 필드가 붙었습니다: '$line'" ;; *) ok ;; esac

# reason 인자를 주면 로그 줄 끝에 reason=<식별자> 가 붙고, 기존 필드는 그대로 유지된다.
R="$WORK/reason1"; mk_guard_reason "$R" "fake_guard.branch-a"
run_guard "$R" "$INPUT_BASH"; rc=$?
[[ "$rc" -eq 2 ]] && ok || bad "reason 인자 있어도 종료 코드 — 기대 2, 실제 $rc"
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"reason=fake_guard.branch-a") ok ;; *) bad "reason 필드가 없거나 값이 다릅니다(정확한 끝 값 아님): '$line'" ;; esac
case "$line" in *"rc=2"*"tool="*"target="*"session="*"reason="*) ok ;; *) bad "reason 추가로 기존 필드 순서가 깨졌습니다: '$line'" ;; esac

# 같은 가드 파일 안에서도 분기마다 다른 reason 이면 로그로 구별된다(값 대응 검증).
R="$WORK/reason2"; mk_guard_reason "$R" "fake_guard.branch-b"
run_guard "$R" "$INPUT_BASH"
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"reason=fake_guard.branch-b") ok ;; *) bad "다른 분기의 reason 값이 기록되지 않았습니다(정확한 끝 값 아님): '$line'" ;; esac

# --- AC 3: 한 줄에 필수 필드가 담긴다 ---
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"fake_guard.sh"*)  ok ;; *) bad "AC3 가드 이름 없음: '$line'" ;; esac
case "$line" in *"rc=2"*)           ok ;; *) bad "AC3 exit code 없음: '$line'" ;; esac
case "$line" in *"tool=Bash"*)      ok ;; *) bad "AC3 tool_name 없음: '$line'" ;; esac
case "$line" in *"target=git"*)     ok ;; *) bad "AC3 대상 요약 없음: '$line'" ;; esac
case "$line" in *"session=sess-abc"*) ok ;; *) bad "AC3 session_id 없음: '$line'" ;; esac
case "$line" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ok ;; *) bad "AC3 시각이 줄 앞에 없음: '$line'" ;; esac

# Edit·Write 는 file_path 가 실질 대상이다.
R="$WORK/ac3b"; mk_guard "$R" 2
run_guard "$R" "$INPUT_EDIT"
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"tool=Edit"*)      ok ;; *) bad "AC3 Edit tool_name 없음: '$line'" ;; esac
case "$line" in *"/tmp/x.md"*)      ok ;; *) bad "AC3 Edit 대상(file_path) 없음: '$line'" ;; esac

# --- AC 2: 통과(exit 0)는 기록하지 않는다 ---
R="$WORK/ac2"; mk_guard "$R" 0
run_guard "$R" "$INPUT_BASH"; rc=$?
[[ "$rc" -eq 0 ]] && ok || bad "AC2 통과 종료 코드 — 기대 0, 실제 $rc"
if [[ -f "$R/$LOG_REL" ]]; then bad "AC2 통과인데 로그가 생겼습니다"; else ok; fi

# 차단 아닌 실패(exit 1)도 기록하지 않는다 — 계측 대상은 「막았나」이지 「죽었나」가 아니다.
R="$WORK/ac2b"; mk_guard "$R" 1
run_guard "$R" "$INPUT_BASH"; rc=$?
[[ "$rc" -eq 1 ]] && ok || bad "AC2 exit 1 보존 — 기대 1, 실제 $rc"
if [[ -f "$R/$LOG_REL" ]]; then bad "AC2 exit 1 인데 로그가 생겼습니다"; else ok; fi

# --- AC 4: 로그를 쓸 수 없어도 종료 코드가 바뀌지 않는다 (핵심) ---
# .lifecycle 자리에 **파일**을 놓아 mkdir -p 와 append 를 모두 실패시킨다.
for want in 2 0; do
  R="$WORK/ac4-$want"; mk_guard "$R" "$want"
  mkdir -p "$R/rd-workflow-workspace"
  printf 'blocker' > "$R/rd-workflow-workspace/.lifecycle"
  run_guard "$R" "$INPUT_BASH"; rc=$?
  [[ "$rc" -eq "$want" ]] && ok || bad "AC4 쓰기 불가에서 종료 코드 — 기대 $want, 실제 $rc"
done
# 기록 실패의 사용자 가시성은 아래 F4 케이스에서 검증한다 (셸 원시 오류는 막고 우리 경고만).

# --- AC 4b: 계측이 새로운 외부 바이너리 의존을 만들지 않는다 ---
# 초판은 trap 안에서 `tr`·`cut`·`basename` 을 썼고, 그것들이 없는 PATH 에서 trap 이 127 로
# 죽어 **차단(2)이 127 로 나갔다.** `self_test.sh hooks` 의 격리 PATH 케이스가 이를 잡았다.
#
# **절대적인 "빈 PATH 에서 동작" 은 검증할 수 없다** — `_guard_common.sh` 는 load 시점에
# 이미 `dirname` 을 쓰므로 빈 PATH 에서는 계측과 무관하게 죽는다(실측). 그래서 **가드가 실제로
# 돌아야 하는 최소 환경**에서 종료 코드가 보존되는지를 본다.
ISO="$WORK/isoPATH"; mkdir -p "$ISO"
# **의존 집합은 test_headless_background_gate.sh 의 ISO_BASE_DEPS 와 같게 둔다.** 그 값이
# 「가드가 실제로 돌아야 하는 최소 환경」의 기준이고, 초판 버그를 잡은 것도 그 집합이다.
# 여기서 임의로 줄이면 계측과 무관한 이유로 먼저 죽어 이 검사가 버그를 놓친다 — 초판을
# 되살려 실측했더니 `cat` 이 빠진 집합에서는 원인 구별이 되지 않았다.
# 이 집합에 `cut`·`basename`·`date`·`mkdir` 은 **없다** — 계측이 그것들에 의존하면 잡힌다.
for b in bash dirname cat sed grep env mktemp rm ln head tr; do
  src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$ISO/$b" 2>/dev/null
done
# **전제 확인은 새 프로세스에서 한다.** 같은 셸에서 `PATH=$ISO command -v mkdir` 을 쓰면
# bash 의 해시 테이블에 남은 이전 실행 경로를 찾아내 「있음」으로 오판한다(실측). 실제
# 가드는 `env PATH=… bash` 로 새로 뜨므로 해시가 비어 있다 — 그 조건을 그대로 재현한다.
for b in cut basename date mkdir; do
  if env "PATH=$ISO" "$BASH_BIN" -c 'command -v "$1"' _ "$b" >/dev/null 2>&1; then
    bad "AC4b 전제: 격리 PATH 에 $b 가 남아 있어 의존을 검증할 수 없습니다"
  else ok; fi
done

for want in 2 0; do
  R="$WORK/ac4b-$want"; mk_guard "$R" "$want"
  printf '%s' "$INPUT_BASH" | env -u RD_GUARD_BLOCK_LOG "PATH=$ISO" "$BASH_BIN" "$R/fake_guard.sh" >/dev/null 2>&1
  rc=$?
  [[ "$rc" -eq "$want" ]] && ok || bad "AC4b 제한 PATH 에서 종료 코드 — 기대 $want, 실제 $rc"
done

# --- AC 5: 개행·제어문자가 있어도 한 줄을 유지한다 ---
R="$WORK/ac5"; mk_guard "$R" 2
MULTI='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"line1\nline2\ttabbed|piped"}}'
run_guard "$R" "$MULTI"
n="$(wc -l < "$R/$LOG_REL" 2>/dev/null | tr -d ' ')"
[[ "$n" == "1" ]] && ok || bad "AC5 개행 포함 입력에서 줄 수 — 기대 1, 실제 '$n'"
# 내용 전문 보존은 기대하지 않는다 — F1 에 따라 인자는 기록하지 않는다. 여기서 묻는 것은
# 제어문자가 줄을 쪼개지 않는가와 필드 구조가 유지되는가다.
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"rc=2"*"tool="*"target="*"session="*) ok ;; *) bad "AC5 필드 구조가 깨졌습니다: '$line'" ;; esac
case "$line" in *$'\n'*) bad "AC5 줄 안에 개행이 남았습니다: '$line'" ;; *) ok ;; esac

# --- 차단 2회는 2줄 (append-only) ---
R="$WORK/append"; mk_guard "$R" 2
run_guard "$R" "$INPUT_BASH"; run_guard "$R" "$INPUT_EDIT"
n="$(wc -l < "$R/$LOG_REL" 2>/dev/null | tr -d ' ')"
[[ "$n" == "2" ]] && ok || bad "append: 차단 2회 후 줄 수 — 기대 2, 실제 '$n'"

# --- 경로 override: 테스트 오염 방지 장치가 실제로 동작하는가 ---
# `self_test.sh` 와 실제 hook 을 부르는 개별 테스트가 이 override 로 운영 감사 로그를
# 오염시키지 않게 한다. override 가 무시되면 그 격리가 조용히 사라진다.
R="$WORK/override"; mk_guard "$R" 2
ALT="$WORK/alt-guard-log"
printf '%s' "$INPUT_BASH" | env "RD_GUARD_BLOCK_LOG=$ALT" "$BASH_BIN" "$R/fake_guard.sh" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] && ok || bad "override: 종료 코드 — 기대 2, 실제 $rc"
if [[ -f "$ALT" ]]; then ok; else bad "override: RD_GUARD_BLOCK_LOG 가 무시됐습니다"; fi
if [[ -f "$R/$LOG_REL" ]]; then bad "override: 기본 경로에도 썼습니다 — 격리가 되지 않습니다"; else ok; fi

# --- F1: 원문 인자를 기록하지 않는다 (자격 증명 유출 방지) ---
# 차단은 임의의 Bash 명령에 걸리므로 토큰이 담긴 명령이 들어온다. 로그를 추적 제외로 두는
# 것과 별개로, 기록 내용 자체에 인자를 남기지 않는다 — 두 방어를 함께 둔다.
R="$WORK/f1"; mk_guard "$R" 2
SECRET='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"curl -H \"Authorization: Bearer SENTINEL_TOKEN_VALUE\" https://example.invalid"}}'
run_guard "$R" "$SECRET"
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *SENTINEL_TOKEN_VALUE*) bad "F1 토큰이 로그에 남았습니다: '$line'" ;; *) ok ;; esac
case "$line" in *Authorization*) bad "F1 헤더 인자가 로그에 남았습니다: '$line'" ;; *) ok ;; esac
case "$line" in *"target=curl"*) ok ;; *) bad "F1 프로그램 이름이 남지 않았습니다: '$line'" ;; esac

# 선행 환경변수 대입은 첫 토큰 자체가 비밀일 수 있다.
R="$WORK/f1b"; mk_guard "$R" 2
ENVASSIGN='{"session_id":"s","tool_name":"Bash","tool_input":{"command":"API_TOKEN=SENTINEL2 curl https://x.invalid"}}'
run_guard "$R" "$ENVASSIGN"
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *SENTINEL2*) bad "F1b 환경변수 값이 로그에 남았습니다: '$line'" ;; *) ok ;; esac
case "$line" in *"<env-assign>"*) ok ;; *) bad "F1b 환경변수 대입 표식이 없습니다: '$line'" ;; esac

# --- F2: jq 가 없어도 필드가 기록된다 (python3 폴백) ---
# 판정(hook_input_bool_true)은 python3 폴백을 갖는데 계측만 jq 를 요구하면, jq 없는 지원
# 환경에서 차단은 되고 로그는 `tool=- target=- session=-` 만 남아 목적이 무너진다.
ISO2="$WORK/isoNoJq"; mkdir -p "$ISO2"
for b in bash dirname cat sed grep env mktemp rm ln head tr date mkdir python3; do
  src="$(command -v "$b" 2>/dev/null)" && ln -s "$src" "$ISO2/$b" 2>/dev/null
done
if env "PATH=$ISO2" "$BASH_BIN" -c 'command -v jq' >/dev/null 2>&1; then
  bad "F2 전제: 격리 PATH 에 jq 가 남아 있어 폴백을 검증할 수 없습니다"
else ok; fi
if env "PATH=$ISO2" "$BASH_BIN" -c 'command -v python3' >/dev/null 2>&1; then ok; else
  bad "F2 전제: 격리 PATH 에 python3 이 없어 폴백을 검증할 수 없습니다"; fi
R="$WORK/f2"; mk_guard "$R" 2
printf '%s' "$INPUT_BASH" | env -u RD_GUARD_BLOCK_LOG "PATH=$ISO2" "$BASH_BIN" "$R/fake_guard.sh" >/dev/null 2>&1
rc=$?
[[ "$rc" -eq 2 ]] && ok || bad "F2 jq 부재에서 종료 코드 — 기대 2, 실제 $rc"
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"tool=Bash"*)        ok ;; *) bad "F2 jq 부재에서 tool 누락: '$line'" ;; esac
case "$line" in *"session=sess-abc"*) ok ;; *) bad "F2 jq 부재에서 session 누락: '$line'" ;; esac
case "$line" in *"target=git"*)       ok ;; *) bad "F2 jq 부재에서 target 누락: '$line'" ;; esac

# --- F4: 기록 실패를 사용자에게 알린다 ---
# 무음으로 흡수하면 「차단한 적 없음」이라는 반대 결론으로 이어진다. 셸의 원시 오류는 막고
# 우리가 만든 한 줄 경고와 로그 경로를 보여준다 — 차단 안내와 exit 2 는 그대로.
R="$WORK/f4"; mk_guard "$R" 2
mkdir -p "$R/rd-workflow-workspace"; printf 'blocker' > "$R/rd-workflow-workspace/.lifecycle"
err="$(printf '%s' "$INPUT_BASH" | env -u RD_GUARD_BLOCK_LOG "$BASH_BIN" "$R/fake_guard.sh" 2>&1 >/dev/null)"
case "$err" in *"감사 로그 기록에 실패"*) ok ;; *) bad "F4 기록 실패 경고가 없습니다: '$err'" ;; esac
case "$err" in *"guard-block-audit.log"*) ok ;; *) bad "F4 경고에 로그 경로가 없습니다: '$err'" ;; esac
case "$err" in *"No such file"*|*"Not a directory"*) bad "F4 셸 원시 오류가 그대로 샜습니다: '$err'" ;; *) ok ;; esac

# --- F1 잔여: 공백 없는 셸 연산자에 붙은 비밀값 ---
# bash 의 리다이렉션·here-string 은 공백 없이 붙을 수 있어 첫 토큰 자체가 비밀을 담는다.
# 첫 토큰을 그대로 믿지 않고 화이트리스트로 판정하는지 확인한다. 입력은 실행하지 않는다.
for pair in "cat<<<SENTINEL_HERESTRING|herestring" \
            "printf>/tmp/SENTINEL_REDIR_PATH|redir" \
            "echo\$SENTINEL_EXPAND|expand" \
            "eval\`SENTINEL_SUBST\`|subst"; do
  cmdtxt="${pair%%|*}"; label="${pair#*|}"
  R="$WORK/f1r-$label"; mk_guard "$R" 2
  run_guard "$R" "{\"session_id\":\"s\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${cmdtxt}\"}}"
  line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
  case "$line" in *SENTINEL_*) bad "F1 잔여($label): 비밀값이 로그에 남았습니다 — '$line'" ;; *) ok ;; esac
  case "$line" in *"target=<unparsed>"*) ok ;; *) bad "F1 잔여($label): 축약 표식이 없습니다 — '$line'" ;; esac
done
# 평범한 명령은 계속 프로그램 이름을 남긴다 — 보수적 판정이 목적을 죽이지 않았는지 확인.
R="$WORK/f1r-plain"; mk_guard "$R" 2
run_guard "$R" '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"/usr/bin/git push --force origin main"}}'
line="$(head -n1 "$R/$LOG_REL" 2>/dev/null)"
case "$line" in *"target=git"*) ok ;; *) bad "F1 잔여: 평범한 명령의 이름이 사라졌습니다 — '$line'" ;; esac

# --- F5: 슬래시 없는 override 가 디렉터리로 오인되지 않는다 ---
# `${v%/*}` 는 슬래시 없는 값을 그대로 돌려주므로 mkdir 이 로그 파일 자리에 디렉터리를
# 만들고 이후 모든 append 가 영구 실패한다. 권한을 고쳐도 기록되지 않는 상태다.
for name in "audit.log" "./audit.log"; do
  tag="$(printf '%s' "$name" | tr -d './')"
  R="$WORK/f5-$tag"; mk_guard "$R" 2
  CWD="$WORK/f5cwd-$tag"; mkdir -p "$CWD"
  ( cd "$CWD" && printf '%s' "$INPUT_BASH" \
      | env "RD_GUARD_BLOCK_LOG=$name" "$BASH_BIN" "$R/fake_guard.sh" >/dev/null 2>&1 )
  rc=$?
  [[ "$rc" -eq 2 ]] && ok || bad "F5($name) 종료 코드 — 기대 2, 실제 $rc"
  if [[ -d "$CWD/${name#./}" ]]; then
    bad "F5($name): 로그 파일 자리에 디렉터리가 만들어졌습니다"
  elif [[ -f "$CWD/${name#./}" ]]; then ok
  else bad "F5($name): 로그가 만들어지지 않았습니다"; fi
done

# --- 추적 제외: 로그가 원격 이력에 들어가지 않는다 ---
# 차단은 임의의 Bash 명령에 걸리므로 인자 제거(1차 방어)가 새더라도 원격으로 나가면 영구
# 보존된다. `.gitignore` 등록이 2차 방어이고, 그것이 빠지면 조용히 추적된다.
# 정본과 루트 양쪽을 본다 — 정본만 고치고 루트를 빠뜨리는 것이 이 저장소의 흔한 실수다.
# 이 파일은 정본(`_ROOT_FILES/rd-workflow/scripts/hooks/`)과 루트 사본 양쪽에 존재하므로
# HOOK_DIR 기준 상대 경로가 두 경우에 다르다. `.gitignore` 가 실제로 있는 후보만 본다.
_gbl_bases=""
for cand in "$HOOK_DIR/../../.." "$HOOK_DIR/../../../.." "$HOOK_DIR/../../../_ROOT_FILES" "$HOOK_DIR/../../../../_ROOT_FILES"; do
  [[ -f "$cand/.gitignore" ]] || continue
  cand="$(cd "$cand" && pwd)"
  case " $_gbl_bases " in *" $cand "*) continue ;; esac
  _gbl_bases="${_gbl_bases} ${cand}"
done
[[ -n "$_gbl_bases" ]] && ok || bad "추적 제외: .gitignore 후보를 찾지 못했습니다"
for base in $_gbl_bases; do
  if [[ -f "$base/.gitignore" ]]; then
    if grep -qF "rd-workflow-workspace/.lifecycle/guard-block-audit.log" "$base/.gitignore"; then
      ok
    else
      bad "추적 제외: $base/.gitignore 에 감사 로그 항목이 없습니다"
    fi
  else
    bad "추적 제외: $base/.gitignore 가 없습니다"
  fi
done

echo "test_guard_block_log: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
