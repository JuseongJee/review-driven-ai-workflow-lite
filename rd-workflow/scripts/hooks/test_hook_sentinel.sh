#!/bin/bash
# test_hook_sentinel.sh — settings.json 의 hook 무성 실패 감시 항목(: rd-hook-sentinel v1) 검증
# 감시 명령은 settings.json 에서 꺼내 sh·bash 두 셸로 실행한다. 사본을 두지 않는다.
# macOS /bin/bash 3.2 호환.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"

FAILS=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1${2:+ — $2}"; FAILS=$((FAILS + 1)); }

T="$(mktemp -d)" || { echo "test_hook_sentinel.sh: mktemp 실패" >&2; exit 1; }
[[ -n "$T" && -d "$T" ]] || exit 1
cleanup() { chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM

HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
HOOKS="session_start pre_commit_archive_gate headless_background_gate implementation_gate self_worktree_delete_gate"

# --- 감시 명령 추출 (프로젝트 settings 에서) ---
extract_cmd() {
  if [[ "$HAVE_PY" == 1 ]]; then
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for groups in d.get("hooks", {}).values():
    for g in groups:
        for h in g.get("hooks", []):
            c = h.get("command", "")
            if c.startswith(": rd-hook-sentinel v1;"):
                sys.stdout.write(c)
                sys.exit(0)
sys.exit(1)
PY
  else
    grep -m1 ': rd-hook-sentinel v1;' "$1" \
      | sed -e 's/^[[:space:]]*"command": *"//' -e 's/"[[:space:]]*,\{0,1\}$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g' | tr -d '\n'
  fi
}
CMD="$(extract_cmd "$P/.claude/settings.json")"
if [[ "$CMD" != ": rd-hook-sentinel v1;"* ]]; then
  fail "T0 감시 명령 추출" "$P/.claude/settings.json 에 ': rd-hook-sentinel v1;' 항목 없음"
  exit 1
fi

# --- 실행 도우말 ---
OUT=""; ERR=""; RC=0
# run <shell> <proj> <tmpdir> <input>
run() {
  CLAUDE_PROJECT_DIR="$2" TMPDIR="$3" "$1" -c "$CMD" <<< "$4" > "$T/o" 2> "$T/e"
  RC=$?
  OUT="$(cat "$T/o")"; ERR="$(cat "$T/e")"
}
# jparse <json> — SM·AC·HE·VALID 를 채운다 (python 한 번. python3 없으면 sed, VALID=-1)
SM=""; AC=""; HE=""; VALID=-1
jparse() {
  SM=""; AC=""; HE=""; VALID=-1
  if [[ "$HAVE_PY" != 1 ]]; then
    # python3 없음: 출력 형식(고정 printf)에 맞춰 sed 로 뽑는다. JSON 유효성(VALID)만 건너뛴다.
    HE="$(printf '%s\n' "$1" | sed -n 's/.*"hookEventName":"\([A-Za-z]*\)".*/\1/p')"
    SM="$(printf '%s\n' "$1" | sed -n 's/.*"systemMessage":"\(.*\)","hookSpecificOutput".*/\1/p')"
    AC="$(printf '%s\n' "$1" | sed -n 's/.*"additionalContext":"\(.*\)"}}.*/\1/p')"
    return 0
  fi
  local r
  r="$(printf '%s' "$1" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(1); print(d.get("systemMessage","")); h=d.get("hookSpecificOutput",{})
    print(h.get("additionalContext","")); print(h.get("hookEventName",""))
except Exception:
    print(0)')"
  VALID="$(printf '%s\n' "$r" | sed -n 1p)"
  SM="$(printf '%s\n' "$r" | sed -n 2p)"; AC="$(printf '%s\n' "$r" | sed -n 3p)"; HE="$(printf '%s\n' "$r" | sed -n 4p)"
}
has_all() { # <text> — 4개 이름 모두 포함
  local h
  for h in $HOOKS; do [[ "$1" == *"$h"* ]] || return 1; done
}
only_name() { # <text> <name> — 그 이름만 포함
  local h
  for h in $HOOKS; do
    if [[ "$h" == "$2" ]]; then [[ "$1" == *"$h"* ]] || return 1; else [[ "$1" != *"$h"* ]] || return 1; fi
  done
}
mkfix() { # <dir> — hook 4개 파일을 가진 픽스처
  local h
  mkdir -p "$1/rd-workflow/scripts/hooks"
  for h in $HOOKS; do : > "$1/rd-workflow/scripts/hooks/$h.sh"; done
}
IN() { # <session|-> <event|-> → JSON
  local s="" e=""
  [[ "$1" != "-" ]] && s="\"session_id\":\"$1\","
  [[ "$2" != "-" ]] && e="\"hook_event_name\":\"$2\","
  printf '{%s%s"tool_name":"Bash"}' "$s" "$e"
}

NOPROJ="$T/없는 폴더/proj dir"
ROOT_USER=0; [[ "$(id -u)" == 0 ]] && ROOT_USER=1

cases() {
  local SH="$1" L="[$1]" TD="$T/tmp-$1" FX="$T/fx $1/proj dir" S="$1" i
  mkdir -p "$TD"
  mkfix "$FX"

  # T1 정상
  run "$SH" "$FX" "$TD" "$(IN "$S-t1" PreToolUse)"
  if [[ -n "$OUT" ]]; then fail "$L T1" "정상인데 출력 있음: $OUT"
  elif [[ -n "$ERR" ]]; then fail "$L T1" "정상인데 stderr 있음: $ERR"
  elif [[ "$RC" != 0 ]]; then fail "$L T1" "정상인데 exit $RC"
  else ok "$L T1 정상은 출력 없음·exit 0"; fi

  # T2 폴더 없음
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t2" PreToolUse)"
  local t2=""
  [[ "$RC" == 0 ]] || t2="$t2 [경고인데 exit 0 아님: $RC]"
  jparse "$OUT"
  [[ "$VALID" == 0 ]] && t2="$t2 [유효 JSON 아님]"
  local sm="$SM" ac="$AC" he="$HE"
  has_all "$sm" || t2="$t2 [systemMessage 이름 누락]"
  has_all "$ac" || t2="$t2 [additionalContext 이름 누락]"
  [[ "$he" == PreToolUse ]] || t2="$t2 [hookEventName 이 PreToolUse 아님: $he]"
  [[ "$sm" == *"작업 폴더가 없습니다"* ]] || t2="$t2 [작업 폴더 문구 없음]"
  if [[ -z "$t2" ]]; then ok "$L T2 폴더 없음 경고"; else fail "$L T2" "$t2"; fi

  # T2b hook_event_name 없음 → PreToolUse
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t2b" -)"
  if [[ "$OUT" == *'"hookEventName":"PreToolUse"'* ]]; then ok "$L T2b 이벤트명 기본값"; else fail "$L T2b" "hookEventName 기본값 아님: $OUT"; fi

  # T3 1회 제한
  local t3=""
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t3" PreToolUse)"
  [[ -n "$OUT" ]] || t3="$t3 [첫 실행 출력 없음]"
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t3" PreToolUse)"
  [[ -z "$OUT" ]] && [[ "$RC" == 0 ]] || t3="$t3 [같은 세션 재경고]"
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t3other" PreToolUse)"
  [[ -n "$OUT" ]] || t3="$t3 [다른 세션인데 출력 없음]"
  local FX3="$T/fx3 $1/proj dir"
  mkfix "$FX3"; rm -f "$FX3/rd-workflow/scripts/hooks/implementation_gate.sh"
  run "$SH" "$FX3" "$TD" "$(IN "$S-t3new" PreToolUse)"
  jparse "$OUT"; only_name "$SM" implementation_gate || t3="$t3 [implementation_gate 만 출력 아님: $OUT]"
  rm -f "$FX3/rd-workflow/scripts/hooks/headless_background_gate.sh"
  run "$SH" "$FX3" "$TD" "$(IN "$S-t3new" PreToolUse)"
  jparse "$OUT"; only_name "$SM" headless_background_gate || t3="$t3 [새로 빠진 hook 만 출력 아님: $OUT]"
  if [[ -z "$t3" ]]; then ok "$L T3 세션당 1회 제한"; else fail "$L T3" "$t3"; fi

  # T4 동시 실행
  rm -f "$T"/c4.*
  for i in 1 2 3 4 5 6 7 8; do
    ( CLAUDE_PROJECT_DIR="$NOPROJ" TMPDIR="$TD" "$SH" -c "$CMD" <<< "$(IN "$S-t4" PreToolUse)" > "$T/c4.$i" 2>/dev/null ) &
  done
  wait
  local all="" h c t4=""
  for i in 1 2 3 4 5 6 7 8; do jparse "$(cat "$T/c4.$i")"; all="$all $SM"; done
  for h in $HOOKS; do
    c="$(printf '%s' "$all" | grep -o "$h" | wc -l | tr -d ' ')"
    [[ "$c" == 1 ]] || t4="$t4 [$h ${c}회]"
  done
  if [[ -z "$t4" ]]; then ok "$L T4 동시 8개에서 hook 이름 각 1회"; else fail "$L T4" "hook 이름 정확히 1회 아님:$t4"; fi

  # T5 SessionStart
  local t5=""
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t5" SessionStart)"
  [[ -n "$OUT" ]] || t5="$t5 [SessionStart 첫 출력 없음]"
  jparse "$OUT"; [[ "$HE" == SessionStart ]] || t5="$t5 [hookEventName 이 SessionStart 아님]"
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t5" SessionStart)"
  [[ -n "$OUT" ]] || t5="$t5 [SessionStart 두 번째 출력 없음]"
  run "$SH" "$NOPROJ" "$TD" "$(IN "$S-t5" PreToolUse)"
  [[ -n "$OUT" ]] || t5="$t5 [SessionStart 뒤 PreToolUse 출력 없음]"
  if [[ -z "$t5" ]]; then ok "$L T5 SessionStart 는 매번 알림"; else fail "$L T5" "$t5"; fi

  # T6 기록 불가
  if [[ "$ROOT_USER" == 1 ]]; then
    echo "skip: $L T6 root 는 chmod 555 를 우회함"
  else
    local RO="$T/ro $1"; mkdir -p "$RO"; chmod 555 "$RO"
    local t6=""
    run "$SH" "$NOPROJ" "$RO" "$(IN "$S-t6" PreToolUse)"
    [[ -n "$OUT" && "$RC" == 0 ]] || t6="$t6 [첫 출력 없음 또는 exit $RC]"
    run "$SH" "$NOPROJ" "$RO" "$(IN "$S-t6" PreToolUse)"
    [[ -n "$OUT" && "$RC" == 0 ]] || t6="$t6 [기록 불가인데 두 번째 출력 없음]"
    chmod 755 "$RO"
    if [[ -z "$t6" ]]; then ok "$L T6 기록 불가면 매번 알림"; else fail "$L T6" "$t6"; fi
  fi

  # T6b 세션 ID 없음
  local t6b=""
  run "$SH" "$NOPROJ" "$TD" "$(IN - PreToolUse)"
  [[ -n "$OUT" ]] || t6b="$t6b [첫 출력 없음]"
  run "$SH" "$NOPROJ" "$TD" "$(IN - PreToolUse)"
  [[ -n "$OUT" ]] || t6b="$t6b [세션 ID 없음인데 두 번째 출력 없음]"
  if [[ -z "$t6b" ]]; then ok "$L T6b 세션 ID 없으면 매번 알림"; else fail "$L T6b" "$t6b"; fi

  # T7 읽기 불가
  if [[ "$ROOT_USER" == 1 ]]; then
    echo "skip: $L T7 root 는 chmod 000 을 우회함"
  else
    local FX7="$T/fx7 $1/proj dir"; mkfix "$FX7"
    chmod 000 "$FX7/rd-workflow/scripts/hooks/pre_commit_archive_gate.sh"
    run "$SH" "$FX7" "$TD" "$(IN "$S-t7" PreToolUse)"
    jparse "$OUT"
    if only_name "$SM" pre_commit_archive_gate; then ok "$L T7 읽기 불가 hook 만 출력"; else fail "$L T7" "읽기 불가 hook 미출력 또는 다른 이름 포함: $OUT"; fi
  fi
}

[[ "$HAVE_PY" == 1 ]] || echo "skip: JSON 유효성 단언 (python3 없음, 필드는 sed 로 추출)"
SHELLS=""
for s in sh bash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
for s in $SHELLS; do cases "$s"; done

# --- T8 정합 ---
if [[ "$(basename "$P")" == "_ROOT_FILES" ]]; then R="$(cd "$P/.." && pwd -P)"; else R="$P"; fi
TARGETS="$P/.claude/settings.json"
for cand in "$R/_ROOT_FILES/.claude/settings.json" "$R/scripts/build-rules/lite-overrides/.claude/settings.json" "$R/.claude/settings.json"; do
  [[ -f "$cand" ]] || continue
  real="$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")"
  case "
$TARGETS
" in *"
$real
"*) continue ;; esac
  TARGETS="$TARGETS
$real"
done

if [[ "$HAVE_PY" == 1 ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    res="$(python3 - "$f" "$CMD" <<'PY'
import json, re, sys
f, cmd = sys.argv[1], sys.argv[2]
d = json.load(open(f))
errs = []
groups = {}
for ev, gl in d.get("hooks", {}).items():
    for g in gl:
        key = ev + ":" + (g.get("matcher") or "")
        if ev == "SessionStart": key = "SessionStart"
        groups.setdefault(key, []).extend(g.get("hooks", []))
want = ["SessionStart", "PreToolUse:Bash", "PreToolUse:Edit", "PreToolUse:Write"]
names = set()
for k, hl in groups.items():
    for h in hl:
        m = re.search(r'rd-workflow/scripts/hooks/([A-Za-z0-9_]+)\.sh', h.get("command", ""))
        if h.get("command", "").startswith("bash ") and m:
            names.add(m.group(1))
names.discard("root_mirror_drift_gate")
for k in want:
    sent = [h.get("command", "") for h in groups.get(k, []) if h.get("command", "").startswith(": rd-hook-sentinel v1;")]
    short = k.replace("PreToolUse:", "") + " 그룹" if k != "SessionStart" else "SessionStart 그룹"
    if len(sent) != 1:
        errs.append("%s 감시 항목 %d개" % (short, len(sent)))
    elif sent[0] != cmd:
        errs.append("%s 문자열 불일치" % short)
    else:
        m = re.search(r'for h in ([a-z_ ]+); do', sent[0])
        lst = sorted(m.group(1).split()) if m else []
        if lst != sorted(names):
            errs.append("목록 불일치: 감시=%s 등록=%s" % (lst, sorted(names)))
print("; ".join(errs))
PY
)"
    prc=$?
    if [[ "$prc" != 0 ]]; then fail "T8 정합: $f" "검사 실행 실패(rc=$prc) — settings 파싱 불가 등"
    elif [[ -z "$res" ]]; then ok "T8 정합: $f"; else fail "T8 정합: $f" "$res"; fi
  done <<< "$TARGETS"
else
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n="$(grep -c ': rd-hook-sentinel v1;' "$f")"
    if [[ "$n" == 4 ]]; then ok "T8 정합(출현 횟수만): $f"; else fail "T8 정합: $f" "감시 문자열 출현 ${n}회, 기대 4"; fi
  done <<< "$TARGETS"
fi

[[ "$FAILS" -eq 0 ]] || exit 1
exit 0
