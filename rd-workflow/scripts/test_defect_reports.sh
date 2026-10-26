#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/defect_reports.sh"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
nok()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else nok "$1 (기대='$3' 실제='$2')"; fi; }

# 케이스별 workspace 를 스위트 root **한 곳** 아래에 만들고 종료 시 한 번에 정리한다.
#
# 케이스마다 `mktemp -d` 를 부르면 두 가지가 깨진다 (final diff review Turn 010).
#  ① 실패를 검사하지 않으면 `WS` 가 빈 문자열이 되어 뒤따르는 `mkdir -p "$WS/rd-workflow/config"`
#     가 **`/rd-workflow/config`** — 저장소 밖 절대 경로 — 를 만든다. `set -e` 가 아니므로
#     계속 진행하며, 권한이 있는 CI/container 에서는 루트에 쓰거나 기존 파일을 덮어쓴다.
#  ② 정리할 경로 목록이 남지 않는다. 매 호출이 `WS` 를 덮어써서 마지막 하나만 알 수 있고,
#     self-test 는 이 스위트를 두 번(직접 실행 + 생성 트리) 돌리므로 누수가 배로 쌓인다.
SUITE_ROOT=""
CASE_N=0

_suite_root_ready() {
  [[ -n "$SUITE_ROOT" && -d "$SUITE_ROOT" ]] && return 0
  SUITE_ROOT="$(mktemp -d)" || { echo "test_defect_reports.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$SUITE_ROOT" && -d "$SUITE_ROOT" ]] || { echo "test_defect_reports.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  return 0
}

# 정리 실패를 조용히 넘기지 않는다 — 잔존 경로를 알려주고 종료 코드를 비영으로 올린다.
_cleanup_suite_root() {
  local rc=$?
  if [[ -n "$SUITE_ROOT" && -d "$SUITE_ROOT" ]]; then
    if ! rm -rf "$SUITE_ROOT" || [[ -e "$SUITE_ROOT" ]]; then
      printf '경고: 임시 디렉터리 정리 실패 — 수동으로 지워야 합니다: %s\n' "$SUITE_ROOT" >&2
      [[ "$rc" -eq 0 ]] && rc=1
    fi
  fi
  exit "$rc"
}
trap _cleanup_suite_root EXIT

setup_workspace() {
  # 임시 root 생성 실패는 **어떤 mkdir·리다이렉션보다 먼저** 치명적으로 끝낸다.
  if ! _suite_root_ready; then
    printf '치명적: 임시 디렉터리를 만들 수 없습니다 — 아무것도 만들지 않고 중단합니다.\n' >&2
    exit 2
  fi
  CASE_N=$((CASE_N + 1))
  WS="${SUITE_ROOT}/case${CASE_N}"
  if ! mkdir -p "$WS/rd-workflow-workspace/reports/workflow-defects" "$WS/rd-workflow/config"; then
    printf '치명적: case workspace 생성 실패 — %s\n' "$WS" >&2
    exit 2
  fi
  printf '{\n  "defect_report_upstream": "JuseongJee/review-driven-ai-workflow"\n}\n' \
    > "$WS/rd-workflow/config/workflow.json"
}

make_report() {
  # $1=파일명  $2=legacy면 report-id/upstream-issue 생략
  local f="$WS/rd-workflow-workspace/reports/workflow-defects/$1"
  {
    printf '# rd-workflow 결함 보고: 테스트 결함\n'
    printf -- '- 발견일: 2026-08-12\n'
    printf -- '- rd-workflow VERSION: 2026-07-10-120000\n'
    printf -- '- 대상 산출물: rd-workflow/scripts/foo.sh\n'
    if [[ "${2:-}" != "legacy" ]]; then
      printf -- '- report-id: 20260101000000-aaaaaa\n'
      printf -- '- upstream-issue: -\n'
    fi
    printf '\n## 재현 맥락\n테스트\n\n## 관찰된 결함\n테스트\n\n## 기대 동작\n테스트\n'
  } > "$f"
  echo "$f"
}

echo "== list-pending: '-' 와 legacy 를 모두 미전달로 센다 =="
setup_workspace
make_report "2026-08-12-1000-a.md" >/dev/null
make_report "2026-08-12-1001-b.md" legacy >/dev/null
out="$(cd "$WS" && bash "$TARGET" count-pending 2>/dev/null)"
check "미전달 2건" "$out" "2"

echo "== list-pending: 전달 완료 건은 제외한다 =="
f="$(make_report "2026-08-12-1002-c.md")"
(cd "$WS" && bash "$TARGET" set-issue "$f" "https://github.com/O/R/issues/7" >/dev/null 2>&1)
out="$(cd "$WS" && bash "$TARGET" count-pending 2>/dev/null)"
check "미전달 2건 유지" "$out" "2"
grep -q '^- upstream-issue: https://github.com/O/R/issues/7$' "$f" \
  && ok "set-issue 역기록" || nok "set-issue 역기록"

echo "== ensure-id: 기존 id 는 보존한다 =="
f="$(make_report "2026-08-12-1003-d.md")"
out="$(cd "$WS" && bash "$TARGET" ensure-id "$f" 2>/dev/null)"
check "기존 id 반환" "$out" "20260101000000-aaaaaa"

echo "== ensure-id: legacy 는 생성해 파일에 기록한다 =="
f="$(make_report "2026-08-12-1004-e.md" legacy)"
id1="$(cd "$WS" && bash "$TARGET" ensure-id "$f" 2>/dev/null)"
[[ "$id1" =~ ^[0-9]{14}-[0-9a-f]{6}$ ]] && ok "id 형식" || nok "id 형식 ($id1)"
grep -q "^- report-id: $id1\$" "$f" && ok "파일에 영속화" || nok "파일에 영속화"
id2="$(cd "$WS" && bash "$TARGET" ensure-id "$f" 2>/dev/null)"
check "재호출 시 동일 id" "$id2" "$id1"

echo "== 내용이 같은 legacy 2건은 서로 다른 id 를 갖는다 (AC 19) =="
fa="$(make_report "2026-08-12-1005-same1.md" legacy)"
fb="$(make_report "2026-08-12-1006-same2.md" legacy)"
ida="$(cd "$WS" && bash "$TARGET" ensure-id "$fa" 2>/dev/null)"
idb="$(cd "$WS" && bash "$TARGET" ensure-id "$fb" 2>/dev/null)"
[[ "$ida" != "$idb" ]] && ok "id 충돌 없음" || nok "id 충돌 ($ida)"

echo "== attempting: 도 미전달로 센다 (spec §2.4) =="
setup_workspace
f="$(make_report "2026-08-12-1007-att.md")"
sed -i.bak 's/^- upstream-issue: -$/- upstream-issue: attempting:20260812120000/' "$f"; rm -f "$f.bak"
out="$(cd "$WS" && bash "$TARGET" count-pending 2>/dev/null)"
check "attempting 은 미전달" "$out" "1"

echo "== ensure-id: 손상된 기존 id 는 덮어쓰지 않고 보류한다 (Turn 004 Finding 6) =="
setup_workspace
f="$(make_report "2026-08-12-1008-bad.md")"
sed -i.bak 's/^- report-id: .*$/- report-id: "; malformed/' "$f"; rm -f "$f.bak"
snap="$(cat "$f")"
(cd "$WS" && bash "$TARGET" ensure-id "$f" >/dev/null 2>&1); rc=$?
check "형식 위반은 exit 7" "$rc" "7"
check "파일 무변경 (자동 재생성 없음)" "$(cat "$f")" "$snap"

# 규약 문서의 스키마를 그대로 따라 `- report-id: -` 로 두면 형식 오류로 거부당했다 —
# 같은 규약 안에서 `upstream-issue` 는 `-` 를 "값 없음" 으로 받는데 여기만 비대칭이었다.
# 규약 자체를 논하는 보고서는 본문에 그 스키마를 인용하므로, 인용 줄을 자기 머리말로
# 읽거나 덮어쓰지 않는지도 함께 본다 (Issue #21 본안 + 부수 관찰).
echo "== ensure-id: 값 없음 표기 '-' 를 새 id 로 채운다 (Issue #21) =="
setup_workspace
f="$(make_report "2026-08-12-1009-dash.md")"
sed -i.bak 's/^- report-id: .*$/- report-id: -/' "$f"; rm -f "$f.bak"
printf '\n```\n- report-id: <자동 생성 — defect_reports.sh ensure-id>\n```\n' >> "$f"
id="$(cd "$WS" && bash "$TARGET" ensure-id "$f" 2>/dev/null)"; rc=$?
check "'-' 는 exit 0" "$rc" "0"
[[ "$id" =~ ^[0-9]{14}-[0-9a-f]{6}$ ]] && ok "새 id 생성" || nok "새 id 생성 ($id)"
check "머리말 줄을 치환 (중복 줄 없음)" "$(grep -c "^- report-id: ${id}\$" "$f")" "1"
check "본문 코드블록 인용 보존" "$(grep -c '^- report-id: <자동 생성' "$f")" "1"

# 머리말 블록이 없는 파일(첫 줄이 빈 줄·'## ', 빈 파일)에서 삽입 위치가 머리말 범위
# 밖이면 쓰기는 성공하는데 조회는 영원히 빈 값을 낸다 — ensure-id 가 매번 새 id 를
# 만들고, publish 는 기존 완료 URL·attempting 을 못 읽어 중복 Issue 를 낼 수 있다
# (final diff review Turn 002 F2).
echo "== 머리말이 없는 파일도 읽을 수 있는 위치에 기록한다 (Turn 002 F2) =="
setup_workspace
f="$WS/rd-workflow-workspace/reports/workflow-defects/2026-08-12-1011-nohdr.md"
printf '\n# rd-workflow 결함 보고: 머리말 없음\n\n본문\n' > "$f"
id1="$(cd "$WS" && bash "$TARGET" ensure-id "$f" 2>/dev/null)"
id2="$(cd "$WS" && bash "$TARGET" ensure-id "$f" 2>/dev/null)"
check "재실행 시 같은 id (영속화 성공)" "$id2" "$id1"
check "report-id 줄은 1개" "$(grep -c '^- report-id: ' "$f")" "1"
(cd "$WS" && bash "$TARGET" set-issue "$f" "https://x/issues/9" >/dev/null 2>&1)
out="$(cd "$WS" && bash "$TARGET" count-pending 2>/dev/null)"
check "set-issue 후 전달 완료로 읽힌다" "$out" "0"

echo "== 머리말 파싱은 본문 코드블록 인용을 자기 값으로 읽지 않는다 (Issue #21 부수) =="
setup_workspace
f="$(make_report "2026-08-12-1010-quote.md" legacy)"
printf '\n```\n- report-id: 99999999999999-bbbbbb\n- upstream-issue: https://example.invalid/1\n```\n' >> "$f"
out="$(cd "$WS" && bash "$TARGET" count-pending 2>/dev/null)"
check "본문 인용 URL 을 전달 완료로 보지 않음" "$out" "1"
id="$(cd "$WS" && bash "$TARGET" ensure-id "$f" 2>/dev/null)"
[[ "$id" != "99999999999999-bbbbbb" ]] && ok "본문 인용 id 를 재사용하지 않음" || nok "본문 인용 id 재사용"
check "새 id 는 머리말에 들어간다" "$(sed -n '1,/^$/p' "$f" | grep -c "^- report-id: ${id}\$")" "1"

echo "== 발행 경로 (fake gh) =="

setup_fake_gh() {
  FAKEBIN="$WS/fakebin"; mkdir -p "$FAKEBIN"
  GH_LOG="$WS/gh-calls.log"; GH_BODY="$WS/gh-body.txt"; GH_ARGV="$WS/gh-argv.log"
  : > "$GH_LOG"; : > "$GH_BODY"; : > "$GH_ARGV"
  cat > "$FAKEBIN/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'HOST=%s ARGS=%s\n' "${GH_HOST:-github.com}" "$*" >> "$GH_LOG"
# 인자 경계를 보존하는 대조용 로그. `$*` 는 공백으로 다시 나눌 수 없다 —
# --jq 값 안의 `-->` 가 옵션으로 오인된다 (spec 2-B).
if [[ -n "${GH_ARGV:-}" ]]; then
  { printf '%s\037' "${GH_HOST:-github.com}"
    for a in "$@"; do printf '%s\037' "$a"; done
    printf '\n'; } >> "$GH_ARGV"
fi
[[ -n "${FAKE_GH_STDERR:-}" ]] && printf '%s\n' "$FAKE_GH_STDERR" >&2
prev=""
for a in "$@"; do
  [[ "$prev" == "--body-file" ]] && cat "$a" > "$GH_BODY"
  prev="$a"
done
case "$1 $2" in
  "auth status")  [[ "${FAKE_AUTH:-ok}" == "fail" ]] && exit 1; exit 0 ;;
  "repo view")    [[ "${FAKE_VISIBILITY:-PUBLIC}" == "ERROR" ]] && exit 1
                  printf '{"visibility":"%s"}\n' "${FAKE_VISIBILITY:-PUBLIC}" ;;
  # --json/--jq 를 해석하지 않는다 (로컬 jq 의존 금지). 인자는 위 로그에 남으므로
  # 테스트가 --json url,body·--jq·정확 마커의 전달 여부를 인자 수준에서 검사한다.
  # FAKE_SEARCH=FAIL 은 조회 실패(네트워크·API 오류)를 주입한다. 이 실패를 "0건" 으로
  # 오인하면 중복 Issue 가 생기므로 반드시 구별돼야 한다 (final diff review Finding 1).
  "issue list")   [[ "${FAKE_SEARCH:-}" == "FAIL" ]] && exit 1
                  printf '%s' "${FAKE_SEARCH:-}" ;;
  "issue create") [[ "${FAKE_CREATE:-ok}" == "fail" ]] && exit 1
                  printf 'https://github.com/O/R/issues/42\n' ;;
  "issue edit")   [[ "${FAKE_EDIT:-ok}" == "fail" ]] && exit 1; exit 0 ;;
  *) exit 1 ;;
esac
FAKE
  chmod +x "$FAKEBIN/gh"

  # fake mv — 원자적 쓰기 실패를 파일 권한에 기대지 않고 결정적으로 만든다.
  # chmod 기반은 root 에서 무시되어 컨테이너/CI 에서 필수 계약이 무검증으로 남는다
  # (Turn 006 Finding 4). 패턴이 없으면 즉시 real mv 로 exec 하므로 평소엔 투명하다.
  MV_COUNT="$WS/mv-count"; : > "$MV_COUNT"
  cat > "$FAKEBIN/mv" <<'FAKEMV'
#!/usr/bin/env bash
dest="${!#}"
if [[ -n "${FAKE_MV_FAIL_PATTERN:-}" && "$dest" == *"$FAKE_MV_FAIL_PATTERN"* ]]; then
  n=0; [[ -s "${MV_COUNT:-/dev/null}" ]] && n="$(cat "$MV_COUNT")"
  n=$((n+1)); printf '%s' "$n" > "$MV_COUNT"
  (( n > ${FAKE_MV_FAIL_AFTER:-0} )) && { printf 'mv: 주입된 실패\n' >&2; exit 1; }
fi
exec /bin/mv "$@"
FAKEMV
  chmod +x "$FAKEBIN/mv"

  # fake mktemp — payload 준비 실패를 주입한다. `TMPDIR` 을 잘못된 경로로 두는 방법은
  # BSD(macOS) mktemp 가 이를 무시해 통하지 않는다.
  # **인자 없는 호출만** 실패시킨다: payload 준비는 `mktemp`(인자 없음)이고
  # `_tmp_beside` 는 템플릿 인자를 주므로, ensure-id/set-issue 경로는 건드리지 않는다.
  REAL_MKTEMP="$(command -v mktemp)"
  cat > "$FAKEBIN/mktemp" <<FAKEMK
#!/usr/bin/env bash
if [[ -n "\${FAKE_MKTEMP_FAIL:-}" && \$# -eq 0 ]]; then
  echo "mktemp: 주입된 실패" >&2; exit 1
fi
if [[ -n "\${FAKE_MKTEMP_FAIL_GH:-}" ]]; then
  for a in "\$@"; do
    case "\$a" in *rd-gh-err*) echo "mktemp: 주입된 실패 (gh 캡처)" >&2; exit 1 ;; esac
  done
fi
exec "$REAL_MKTEMP" "\$@"
FAKEMK
  chmod +x "$FAKEBIN/mktemp"

  # fake cat — 보고서 원문 읽기 실패를 주입한다. 이 실패는 heredoc 안에서 치환될 때
  # 바깥 `cat <<EOF` 의 성공 상태에 가려지므로(Turn 004 Finding 2) 별도 주입이 필요하다.
  # **인자가 대상 파일과 일치하는 호출만** 실패시킨다: 인자 없는 heredoc `cat` 과
  # 설정 파일·fake gh 의 body-file 읽기는 그대로 통과해야 한다.
  # 카운터를 `$(< …)` 로 읽는 이유 — 여기서 `cat` 을 쓰면 자기 자신을 다시 호출한다.
  CAT_COUNT="$WS/cat-count"; : > "$CAT_COUNT"
  cat > "$FAKEBIN/cat" <<'FAKECAT'
#!/usr/bin/env bash
if [[ -n "${FAKE_CAT_FAIL_PATTERN:-}" ]]; then
  for a in "$@"; do
    [[ "$a" == *"$FAKE_CAT_FAIL_PATTERN"* ]] || continue
    n=0; [[ -s "${CAT_COUNT:-/dev/null}" ]] && n="$(< "$CAT_COUNT")"
    n=$((n+1)); printf '%s' "$n" > "$CAT_COUNT"
    if (( n > ${FAKE_CAT_FAIL_AFTER:-0} )); then
      # FAKE_CAT_PARTIAL 이 있으면 **일부 bytes 를 stdout 에 쓴 뒤** 실패한다.
      # 이것이 검사하는 것은 `mv` 의 원자성이 아니라 **우리 코드의 쓰기 순서**다 —
      # 실패한 bytes 가 원본 referent 가 아니라 새 임시 파일에만 들어가야 한다.
      [[ -n "${FAKE_CAT_PARTIAL:-}" ]] && printf '%s' "$FAKE_CAT_PARTIAL"
      printf 'cat: 주입된 실패\n' >&2; exit 1
    fi
  done
fi
exec /bin/cat "$@"
FAKECAT
  chmod +x "$FAKEBIN/cat"
}
run_dr() { (cd "$WS" && PATH="$FAKEBIN:$PATH" GH_LOG="$GH_LOG" GH_ARGV="$GH_ARGV" GH_BODY="$GH_BODY" \
                       MV_COUNT="$MV_COUNT" CAT_COUNT="$CAT_COUNT" bash "$TARGET" "$@"); }

# grep -c 는 0건일 때 '0' 을 출력하고 exit 1 을 반환한다. `|| echo 0` 을 붙이면
# 출력이 '0\n0' 두 줄이 되어 모든 "0회" 비교가 깨진다 (Turn 004 Finding 3).
calls() {
  local n=0
  [[ -f "$GH_LOG" ]] && n="$(grep -c "ARGS=$1" "$GH_LOG")"
  printf '%s' "$n"
}

# PATH 에서 gh 를 가진 디렉토리만 제거한다. PATH 를 통째로 비우면 sed·grep 까지
# 사라져 스크립트가 다른 이유로 죽고, 반대로 /usr/bin 을 남기면 CI 에서 real gh 가
# 잡힐 수 있다 (Turn 004 Finding 3).
path_without_gh() {
  local out="" d; local -a dirs
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [[ -x "$d/gh" ]] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# 한글 n 자 (UTF-8 3 byte/자). 본문 한도가 byte 기준임을 검증하는 데 쓴다.
kor() { local n="$1" unit="가나다라마바사아자차" s="" i
        for ((i=0; i<n/10; i++)); do s+="$unit"; done; printf '%s' "$s"; }

echo "-- set-upstream: 빈 값이면 실제로 기록한다 (AC 8) --"
setup_workspace
printf '{\n  "defect_report_upstream": ""\n}\n' > "$WS/rd-workflow/config/workflow.json"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1)
grep -q '"defect_report_upstream": "O/R"' "$WS/rd-workflow/config/workflow.json" \
  && ok "config 에 실제 기록" || nok "config 에 실제 기록"

echo "-- set-upstream: 기존 값은 보존한다 (AC 8) --"
setup_workspace
printf '{\n  "defect_report_upstream": "Mine/private-dev"\n}\n' > "$WS/rd-workflow/config/workflow.json"
before="$(cat "$WS/rd-workflow/config/workflow.json")"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1)
check "원본 유지" "$(cat "$WS/rd-workflow/config/workflow.json")" "$before"

echo "-- set-upstream: 빈 값 + 미지원 URL 이면 원본 유지 + exit 1 --"
setup_workspace
printf '{\n  "defect_report_upstream": ""\n}\n' > "$WS/rd-workflow/config/workflow.json"
before="$(cat "$WS/rd-workflow/config/workflow.json")"
(cd "$WS" && bash "$TARGET" set-upstream 'ftp://x/y' >/dev/null 2>&1); rc=$?
check "exit 1" "$rc" "1"
check "원본 유지" "$(cat "$WS/rd-workflow/config/workflow.json")" "$before"

echo "-- set-upstream: 기존 값 + 미지원 URL 은 exit 0 (판정 순서, Turn 004 Finding 2) --"
setup_workspace
printf '{\n  "defect_report_upstream": "Mine/private-dev"\n}\n' > "$WS/rd-workflow/config/workflow.json"
before="$(cat "$WS/rd-workflow/config/workflow.json")"
(cd "$WS" && bash "$TARGET" set-upstream 'ftp://x/y' >/dev/null 2>&1); rc=$?
check "exit 0 (URL 을 보지도 않음)" "$rc" "0"
check "원본 유지" "$(cat "$WS/rd-workflow/config/workflow.json")" "$before"

echo "-- set-upstream: config 파일이 없으면 성공 skip (exit 0) --"
setup_workspace
rm -f "$WS/rd-workflow/config/workflow.json"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
[[ ! -f "$WS/rd-workflow/config/workflow.json" ]] && ok "config 를 새로 만들지 않음" || nok "config 를 새로 만들지 않음"

echo "-- set-upstream: 원자적 쓰기(mv) 실패면 원본 유지 + exit 1 --"
setup_workspace; setup_fake_gh
printf '{\n  "defect_report_upstream": ""\n}\n' > "$WS/rd-workflow/config/workflow.json"
before="$(cat "$WS/rd-workflow/config/workflow.json")"
(cd "$WS" && PATH="$FAKEBIN:$PATH" MV_COUNT="$MV_COUNT" \
   FAKE_MV_FAIL_PATTERN="workflow.json" FAKE_MV_FAIL_AFTER=0 \
   bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 1" "$rc" "1"
check "원본 유지" "$(cat "$WS/rd-workflow/config/workflow.json")" "$before"

echo "-- --yes 없으면 발행하지 않고 파일도 안 바꾼다 (AC 14) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2000-p.md")"
snap="$(cat "$f")"
run_dr publish "$f" --upstream "O/R" >/dev/null 2>&1; rc=$?
check "exit 5" "$rc" "5"
check "issue create 0회" "$(calls 'issue create')" "0"
check "파일 무변경" "$(cat "$f")" "$snap"

echo "-- 정상 발행: 인자·본문·식별자까지 확인 (AC 34-a) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2001-q.md")"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 0" "$rc" "0"
check "issue create 정확히 1회" "$(calls 'issue create')" "1"
grep -q 'ARGS=issue create.*--repo O/R' "$GH_LOG" && ok "대상 repo 인자" || nok "대상 repo 인자"
grep -q 'ARGS=issue create.*\[defect\]' "$GH_LOG" && ok "제목 접두사" || nok "제목 접두사"
id="$(sed -n 's/^- report-id: \(.*\)$/\1/p' "$f" | head -1)"
grep -q "<!-- rd-defect-id: $id -->" "$GH_BODY" && ok "본문에 식별자 주석" || nok "본문에 식별자 주석"
grep -q "관찰된 결함" "$GH_BODY" && ok "본문에 원문 포함" || nok "본문에 원문 포함"
grep -q '^- upstream-issue: https://github.com/O/R/issues/42$' "$f" \
  && ok "canonical URL 역기록" || nok "canonical URL 역기록"

echo "-- 라벨은 create 가 아니라 edit 로 붙인다 --"
grep -q 'ARGS=issue create.*--label' "$GH_LOG" && nok "create 에 --label 없어야 함" || ok "create 는 라벨 없이"
grep -q 'ARGS=issue edit.*--add-label defect-report' "$GH_LOG" && ok "edit 로 라벨 부착" || nok "edit 로 라벨 부착"

echo "-- 라벨 실패는 발행을 유지하되 조용히 넘어가지 않는다 (Turn 004 Finding 5) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2002-r.md")"
err="$(FAKE_EDIT=fail run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"; rc=$?
check "exit 0" "$rc" "0"
check "create 재호출 없음" "$(calls 'issue create')" "1"
grep -q '^- upstream-issue: https://' "$f" && ok "역기록 유지" || nok "역기록 유지"
case "$err" in *라벨*)      ok "라벨 미부착 경고";;   *) nok "라벨 미부착 경고";; esac
case "$err" in *maintainer*) ok "다음 행동 안내";;    *) nok "다음 행동 안내";; esac

echo "-- 라벨 성공 시에는 경고가 나오지 않는다 --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2002-r2.md")"
err="$(run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"
case "$err" in *라벨*) nok "정상 경로에 불필요한 경고";; *) ok "정상 경로는 경고 없음";; esac

echo "-- 완료 파일 재실행은 검색·생성 없이 종료한다 (fast path, AC 16) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2003-s.md")"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc1=$?
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc2=$?
check "1회차 exit 0" "$rc1" "0"
check "2회차 exit 0" "$rc2" "0"
check "create 누적 1회" "$(calls 'issue create')" "1"
check "issue list 도 1회 (2회차는 검색 안 함)" "$(calls 'issue list')" "1"

echo "-- 역기록 실패 후 재시도는 검색으로 복구한다 (AC 21) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2003-s2.md")"
export FAKE_SEARCH="https://github.com/O/R/issues/42"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 0" "$rc" "0"
check "create 없이 연결" "$(calls 'issue create')" "0"
grep -q '^- upstream-issue: https://github.com/O/R/issues/42$' "$f" \
  && ok "기존 URL 역기록" || nok "기존 URL 역기록"
unset FAKE_SEARCH

echo "-- 검색은 --json/--jq 와 정확 마커를 인자로 전달한다 (Turn 004 Finding 3) --"
id="$(sed -n 's/^- report-id: \(.*\)$/\1/p' "$f" | head -1)"
grep -q 'ARGS=issue list.*--state all'    "$GH_LOG" && ok "--state all"        || nok "--state all"
grep -q 'ARGS=issue list.*--json url,body' "$GH_LOG" && ok "--json url,body"   || nok "--json url,body"
grep -q -- 'ARGS=issue list.*--jq'        "$GH_LOG" && ok "--jq 전달"          || nok "--jq 전달"
grep -q "ARGS=issue list.*rd-defect-id: $id" "$GH_LOG" && ok "정확 마커 표현"  || nok "정확 마커 표현"

echo "-- 검색 결과 2건 이상이면 병합하지 않고 보류 (AC 17) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2004-t.md")"
export FAKE_SEARCH="https://github.com/O/R/issues/42
https://github.com/O/R/issues/43"
err="$(run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"; rc=$?
check "exit 8" "$rc" "8"
check "create 0회" "$(calls 'issue create')" "0"
case "$err" in *issues/42*issues/43*) ok "후보 표시";; *) nok "후보 표시";; esac
grep -q '^- upstream-issue: -$' "$f" && ok "미전달 유지" || nok "미전달 유지"
unset FAKE_SEARCH

echo "-- gh 미설치 (AC 22) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2005-u.md")"
NOGH="$(path_without_gh)"
rc=0; (cd "$WS" && PATH="$NOGH" bash "$TARGET" publish "$f" --upstream "O/R" --yes) >/dev/null 2>&1 || rc=$?
check "exit 4" "$rc" "4"
if PATH="$NOGH" command -v gh >/dev/null 2>&1
then nok "PATH 정리 실패 — gh 가 남아 있어 이 케이스는 무의미"
else ok "PATH 에 gh 없음 (real gh 도 없음)"; fi

echo "-- 대상 host 미인증 (AC 22) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2006-v.md")"
FAKE_AUTH=fail run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 4" "$rc" "4"
check "create 0회" "$(calls 'issue create')" "0"

echo "-- visibility 판정 실패는 fail-closed (AC 13) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2007-w.md")"
FAKE_VISIBILITY=ERROR run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 3" "$rc" "3"
check "create 0회" "$(calls 'issue create')" "0"
grep -q '^- upstream-issue: -$' "$f" && ok "미전달 유지" || nok "미전달 유지"

echo "-- create 실패는 결과 불명으로 남긴다 (AC 22) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2008-x.md")"
FAKE_CREATE=fail run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 9" "$rc" "9"
grep -q '^- upstream-issue: attempting:' "$f" && ok "attempting 기록 (미전달)" || nok "attempting 기록"
check "미전달 목록에 포함" "$(cd "$WS" && bash "$TARGET" count-pending 2>/dev/null)" "1"

echo "-- 결과 불명 상태의 재실행은 자동 재생성하지 않는다 (exit 11, Turn 004 Finding 1) --"
err="$(run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"; rc=$?
check "exit 11" "$rc" "11"
check "create 누적 1회 (재생성 없음)" "$(calls 'issue create')" "1"
case "$err" in *set-issue*)            ok "복구 안내";;     *) nok "복구 안내";; esac
case "$err" in *"upstream-issue: -"*)  ok "되돌리기 안내";; *) nok "되돌리기 안내";; esac

echo "-- 사람이 attempting 을 해제하면 정상 경로로 돌아온다 (spec §6.1) --"
sed -i.bak 's/^- upstream-issue: attempting:.*$/- upstream-issue: -/' "$f"; rm -f "$f.bak"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 0" "$rc" "0"
check "create 누적 2회" "$(calls 'issue create')" "2"

echo "-- 역기록 실패는 URL·복구 명령을 보여준다 (AC 21) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2009-y.md")"
# publish 는 같은 보고 파일에 두 번 쓴다 — 10번(attempting), 13번(set-issue).
# AFTER=1 이면 앞의 쓰기는 성공하고 뒤의 쓰기만 실패해 exit 10 이 정확히 나온다.
# 파일 권한에 기대지 않으므로 root 에서도 동일하게 실행된다 (Turn 006 Finding 4).
err="$(FAKE_MV_FAIL_PATTERN="$(basename "$f")" FAKE_MV_FAIL_AFTER=1 \
       run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"; rc=$?
check "exit 10 (7 이 아니어야 함)" "$rc" "10"
check "create 는 1회" "$(calls 'issue create')" "1"
grep -q '^- upstream-issue: attempting:' "$f" && ok "attempting 유지" || nok "attempting 유지"
case "$err" in *issues/42*) ok "생성된 URL 표시";; *) nok "생성된 URL 표시";; esac
case "$err" in *set-issue*)  ok "복구 명령 안내";; *) nok "복구 명령 안내";; esac

echo "-- attempting 기록 자체가 실패하면 원격을 건드리지 않는다 (exit 7) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2009-y2.md")"
FAKE_MV_FAIL_PATTERN="$(basename "$f")" FAKE_MV_FAIL_AFTER=0 \
  run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 7" "$rc" "7"
check "issue create 0회" "$(calls 'issue create')" "0"

echo "-- 손상된 report-id 는 원격 쓰기 전에 보류한다 (Turn 004 Finding 6) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2016-badid.md")"
sed -i.bak 's/^- report-id: .*$/- report-id: "; x/' "$f"; rm -f "$f.bak"
snap="$(cat "$f")"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 7" "$rc" "7"
# 서브커맨드별 0회가 아니라 로그 전체 0행 — auth status·repo view 조차 없어야 한다
# (Turn 006 Finding 1). 검증이 gh 가용성 확인보다 앞에 있다는 계약의 관찰 지점이다.
check "gh 호출 0회 (로그 전체)" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
check "파일 무변경" "$(cat "$f")" "$snap"

echo "-- 대상 값 형식 위반은 gh 호출 전에 보류한다 (Turn 004 Finding 6) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2017-badup.md")"
for bad in "a/b/c/d" "O R" "O/" "/R" "https://github.com/O/R" "O/R?tab=x"; do
  : > "$GH_LOG"
  run_dr publish "$f" --upstream "$bad" --yes >/dev/null 2>&1; rc=$?
  n="$(wc -l < "$GH_LOG" | tr -d ' ')"
  if [[ "$rc" -eq 2 && "$n" -eq 0 ]]; then ok "형식 위반 보류: '$bad'"
  else nok "형식 위반 보류: '$bad' (rc=$rc, gh 호출 ${n}회)"; fi
done

echo "-- 3 세그먼트 GHE 대상은 정상 통과한다 (과잉 거부 방지) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2017-ghe-ok.md")"
run_dr publish "$f" --upstream "oss.navercorp.com/O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 0" "$rc" "0"

echo "-- 설정 없으면 보류 (AC 22) --"
setup_workspace; setup_fake_gh
printf '{\n  "defect_report_upstream": ""\n}\n' > "$WS/rd-workflow/config/workflow.json"
f="$(make_report "2026-08-12-2010-z.md")"
run_dr publish "$f" >/dev/null 2>&1; rc=$?
check "exit 2" "$rc" "2"
check "create 0회" "$(calls 'issue create')" "0"

echo "-- 본문 초과는 절단 없이 보류 (AC 15) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2011-big.md")"
head -c 61000 /dev/zero | tr '\0' 'x' >> "$f"
size_before="$(wc -c < "$f")"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 6" "$rc" "6"
check "create 0회" "$(calls 'issue create')" "0"
check "파일 절단 없음" "$(wc -c < "$f")" "$size_before"

echo "-- 한도의 단위는 byte 다 (한글 경계, Turn 004 Finding 8) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2018-kor-ok.md")"
kor 19000 >> "$f"                      # 57,000 byte / 19,000 자
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "57KB 한글은 발행됨" "$rc" "0"

setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2019-kor-over.md")"
kor 21000 >> "$f"                      # 63,000 byte / 21,000 자 — 문자 기준이면 통과해버린다
size_before="$(wc -c < "$f")"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "63KB 한글은 exit 6" "$rc" "6"
check "create 0회" "$(calls 'issue create')" "0"
check "파일 절단 없음" "$(wc -c < "$f")" "$size_before"

echo "-- GHE 대상이면 GH_HOST 가 전달된다 --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2012-ghe.md")"
run_dr publish "$f" --upstream "oss.navercorp.com/O/R" --yes >/dev/null 2>&1
grep -q 'HOST=oss.navercorp.com' "$GH_LOG" && ok "GH_HOST 전달" || nok "GH_HOST 전달"

# 인자 없는 `gh auth status` 는 등록된 **모든** host 를 점검하고 하나라도 실패하면 비-0 을
# 낸다. 대상과 무관한 사내 host 의 VPN 미연결이 github.com 발행 전체를 막았다 (Issue #31).
echo "-- 인증 검사는 대상 host 만 점검한다 (--hostname 전달, Issue #31) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2018-authhost.md")"
run_dr preview "$f" --upstream "O/R" >/dev/null 2>&1
grep -q '^HOST=github.com ARGS=auth status --hostname github.com$' "$GH_LOG" \
  && ok "github.com 대상: --hostname 전달" || nok "github.com 대상: --hostname 전달"
setup_fake_gh
run_dr preview "$f" --upstream "oss.navercorp.com/O/R" >/dev/null 2>&1
grep -q 'ARGS=auth status --hostname oss.navercorp.com$' "$GH_LOG" \
  && ok "GHE 대상: --hostname 전달" || nok "GHE 대상: --hostname 전달"

echo "-- preview 는 대상·공개여부·경고·본문을 보여주고 아무것도 안 바꾼다 (AC 12·13) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2013-pv.md")"
snap="$(cat "$f")"
out="$(run_dr preview "$f" --upstream "O/R" 2>&1)"
for needle in "O/R" "PUBLIC" "공개" "관찰된 결함" "defect-report"; do
  case "$out" in *"$needle"*) ok "preview 에 '$needle'";; *) nok "preview 에 '$needle' 없음";; esac
done
check "preview 는 발행 안 함" "$(calls 'issue create')" "0"
check "preview 는 파일 무변경" "$(cat "$f")" "$snap"

echo "-- real gh 미접근: 정규화된 호출 목록이 순서까지 정확히 일치 (AC 34-b) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-2014-exact.md")"
which_gh="$(cd "$WS" && PATH="$FAKEBIN:$PATH" command -v gh)"
check "gh 는 fake 경로" "$which_gh" "$FAKEBIN/gh"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1
# 줄 수만 비교하면 "잘못된 다섯 호출" 도 통과한다 (Turn 004 Finding 3).
# host + 서브커맨드로 정규화한 전체 목록을 순서까지 비교한다.
actual="$(sed -E 's/^HOST=([^ ]+) ARGS=([a-z]+ [a-z]+).*/\1 \2/' "$GH_LOG")"
expected="github.com auth status
github.com repo view
github.com issue list
github.com issue create
github.com issue edit"
check "호출 목록·순서 정확 일치" "$actual" "$expected"

echo "-- 검색 실패는 0건이 아니다 — 발행하지 않는다 (final diff review Finding 1) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3001-searchfail.md")"
FAKE_SEARCH=FAIL run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 3 (fail-closed)" "$rc" "3"
check "issue create 0회 (중복 생성 없음)" "$(calls 'issue create')" "0"
grep -q '^- upstream-issue: -$' "$f" && ok "미전달 유지" || nok "미전달 유지"

echo "-- attempting 상태에서도 검색 실패를 exit 11 로 오인하지 않는다 --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3002-searchfail-att.md")"
sed -i.bak 's/^- upstream-issue: -$/- upstream-issue: attempting:20260812120000/' "$f"; rm -f "$f.bak"
FAKE_SEARCH=FAIL run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 3 (11 이 아니어야 함)" "$rc" "3"
check "issue create 0회" "$(calls 'issue create')" "0"

echo "-- 본문 크기는 발행 시점 기준이다 — legacy 의 report-id 증가분이 반영돼야 한다 (Finding 2) --"
# production 에 진단 훅을 넣지 않고 공개 계약(publish 종료 코드)만으로 경계를 찾는다.
# ① 비-legacy 파일을 이분 탐색해 발행이 성공하는 **최대 파일 크기**를 구한다.
#    그 크기에서 발행 본문은 정확히 한도(60,000 byte)다.
# ② 같은 파일 크기의 legacy 파일은 발행 시 report-id 한 줄(35 byte)이 더 붙으므로
#    반드시 초과(exit 6)여야 한다. 수정 전 구현은 쓰기 전 크기만 재어 통과시켰다.
setup_workspace; setup_fake_gh
pad_to() {  # $1=file $2=목표 총 byte
  local cur need; cur="$(wc -c < "$1")"; need=$(( $2 - cur ))
  (( need > 0 )) && head -c "$need" /dev/zero | tr '\0' 'x' >> "$1"
}
probe() {   # $1=목표 총 byte $2=legacy|dash|"" -> publish 종료 코드
  local target="$1" mode="${2:-}" ff
  ff="$(make_report "2026-08-12-3003-probe-${target}-${mode:-normal}.md" "$([[ "$mode" == "legacy" ]] && printf 'legacy')")"
  if [[ "$mode" == "dash" ]]; then
    sed -i.bak 's/^- report-id: .*$/- report-id: -/' "$ff"; rm -f "$ff.bak"
  fi
  pad_to "$ff" "$target"
  run_dr publish "$ff" --upstream "O/R" --yes >/dev/null 2>&1
  printf '%s' $?
}
lo=1000; hi=61000
while (( hi - lo > 1 )); do
  mid=$(( (lo + hi) / 2 ))
  if [[ "$(probe "$mid")" == "0" ]]; then lo=$mid; else hi=$mid; fi
done
maxsize=$lo
check "비-legacy 최대 크기(${maxsize}B)에서 발행 성공" "$(probe "$maxsize")" "0"
check "1 byte 더하면 exit 6" "$(probe "$hi")" "6"
check "같은 크기 legacy 는 exit 6 (증가분 반영)" "$(probe "$maxsize" legacy)" "6"
# 값 없음 표기(`-`)도 발행 시 21자 id 로 치환되므로 같은 크기에서 한도를 넘는다.
# `-` 를 그대로 검사값으로 쓰면 60 byte 과소 계산돼 한도 초과 본문이 발행된다
# (final diff review Turn 002 F1).
check "같은 크기 '-' 도 exit 6 (치환 증가분 반영)" "$(probe "$maxsize" dash)" "6"

echo "-- 본문 초과 시 로컬·원격 모두 무변경 (Finding 2) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3004-over.md" legacy)"
kor 21000 >> "$f"
snap="$(cat "$f")"
run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 6" "$rc" "6"
check "gh 호출은 auth·repo view 까지만 (create 0회)" "$(calls 'issue create')" "0"
check "파일 무변경 (report-id 도 안 생김)" "$(cat "$f")" "$snap"

echo "-- 보고서 원문 읽기 실패는 크기 검사에서 잡힌다 (Turn 004 Finding 2) --"
# 실패한 본문은 원문이 빠져 **짧다**. 크기 검사가 실패를 흘려보내면 "작아서 정상" 으로
# 오판하고 발행까지 간다. 읽기 실패는 반드시 비영으로 전파돼야 한다.
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3006-readfail.md")"
snap="$(cat "$f")"
FAKE_CAT_FAIL_PATTERN="$(basename "$f")" FAKE_CAT_FAIL_AFTER=0 \
  run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 7" "$rc" "7"
check "issue create 0회" "$(calls 'issue create')" "0"
grep -q '^- upstream-issue: attempting:' "$f" && nok "거짓 attempting 잔존" || ok "거짓 attempting 없음"
check "파일 무변경" "$(cat "$f")" "$snap"

echo "-- 10-a payload 의 원문 읽기 실패도 발행을 막는다 (Turn 004 Finding 2) --"
# 크기 검사(1회차)는 통과시키고 payload 생성(2회차)만 실패시킨다 — `if ! issue_body`
# 가드가 임시 파일 쓰기 실패만 잡고 원문 읽기 실패는 성공으로 보던 경로다.
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3007-readfail2.md")"
snap="$(cat "$f")"
FAKE_CAT_FAIL_PATTERN="$(basename "$f")" FAKE_CAT_FAIL_AFTER=1 \
  run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 7" "$rc" "7"
check "issue create 0회" "$(calls 'issue create')" "0"
grep -q '^- upstream-issue: attempting:' "$f" && nok "거짓 attempting 잔존" || ok "거짓 attempting 없음"
check "파일 무변경" "$(cat "$f")" "$snap"

echo "-- 승인 화면도 반쯤 만들어진 본문을 보여주지 않는다 (Turn 004 Finding 2) --"
# preview 는 사람이 발행을 결정하는 유일한 근거다. 원문이 빠진 화면을 승인 근거로
# 내놓으면 안 된다. `preview` 서브커맨드는 publish 와 달리 앞선 크기 검사가 없어
# 첫 읽기부터 화면 생성에 쓰인다 — 그래서 1회차를 실패시킨다.
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3008-previewfail.md")"
snap="$(cat "$f")"
out="$(FAKE_CAT_FAIL_PATTERN="$(basename "$f")" FAKE_CAT_FAIL_AFTER=0 \
  run_dr preview "$f" --upstream "O/R" 2>/dev/null)"; rc=$?
check "exit 7 (성공 0 아님)" "$rc" "7"
printf '%s' "$out" | grep -q -- '--- 본문 ---' && nok "반쯤 만든 본문 출력" || ok "본문 섹션 미출력"
check "파일 무변경" "$(cat "$f")" "$snap"

echo "-- 실패 안내는 원래 --upstream 대상을 보존한다 (Turn 006 Finding 1) --"
# config 는 A/B, 사용자는 C/D 로 실행. 안내가 `--upstream` 을 떨어뜨리면 그 안내를 그대로
# 실행하는 순간 **다른 저장소(A/B)에 발행**된다. 안내 문자열과 안내를 따른 실행 결과를 함께 고정한다.
setup_workspace; setup_fake_gh
printf '{\n  "defect_report_upstream": "AAA/BBB"\n}\n' > "$WS/rd-workflow/config/workflow.json"
f="$(make_report "2026-08-12-3009-hint-target.md")"
err="$(FAKE_VISIBILITY=ERROR run_dr publish "$f" --upstream "CCC/DDD" --yes 2>&1 >/dev/null)"; rc=$?
check "exit 3 (visibility fail-closed)" "$rc" "3"
printf '%s' "$err" | grep -q -- '--upstream CCC/DDD' && ok "안내가 원래 대상 보존" || nok "안내가 원래 대상 유실: [$err]"
printf '%s' "$err" | grep -qE 'publish [^ ]+ --yes$' && nok "대상 없는 재시도 안내" || ok "대상 없는 재시도 안내 아님"
# 안내를 그대로 따라 실행하면 원래 대상으로 가야 한다 (config 대상으로 바꿔치기 금지).
: > "$GH_LOG"
run_dr publish "$f" --upstream "CCC/DDD" --yes >/dev/null 2>&1
check "안내대로 실행 시 원래 대상" "$(grep -c 'ARGS=issue create --repo CCC/DDD' "$GH_LOG")" "1"
check "config 대상으로 발행 0회" "$(grep -c 'issue create --repo AAA/BBB' "$GH_LOG" || true)" "0"

echo "-- config 대상 실행도 effective target 을 안내에 고정한다 (Turn 008 Finding 1) --"
# `--upstream` 을 준 경우만 보존하면 부족하다. config 로 대상을 정한 실행이 실패한 뒤 config 가
# 바뀌면(사람 편집·템플릿 동기화), 대상 없는 안내를 따라 **승인 화면에서 본 적 없는 저장소**로
# 발행된다. 안내 문자열을 직접 파싱해 실행함으로써 "안내가 곧 실행 가능한 계약" 임을 고정한다.
setup_workspace; setup_fake_gh
printf '{\n  "defect_report_upstream": "AAA/BBB"\n}\n' > "$WS/rd-workflow/config/workflow.json"
f="$(make_report "2026-08-12-3012-hint-config.md")"
err="$(FAKE_VISIBILITY=ERROR run_dr publish "$f" --yes 2>&1 >/dev/null)"; rc=$?
check "exit 3" "$rc" "3"
opts="$(printf '%s\n' "$err" | sed -n 's|^재시도: bash rd-workflow/scripts/defect_reports.sh publish [^ ]* ||p')"
check "안내가 effective target 고정" "$opts" "--upstream AAA/BBB --yes"
# 실패와 재시도 사이에 config 를 바꾼다 — 안내를 따르면 최초 대상으로만 발행돼야 한다.
printf '{\n  "defect_report_upstream": "CCC/DDD"\n}\n' > "$WS/rd-workflow/config/workflow.json"
: > "$GH_LOG"
# shellcheck disable=SC2086 -- 안내 문자열을 옵션으로 분리해 그대로 실행한다 (의도된 단어 분할)
run_dr publish "$f" $opts >/dev/null 2>&1
check "최초 대상으로 발행" "$(grep -c 'ARGS=issue create --repo AAA/BBB' "$GH_LOG")" "1"
check "변경된 config 대상 발행 0회" "$(grep -c 'issue create --repo CCC/DDD' "$GH_LOG" || true)" "0"

echo "-- 승인 화면을 못 본 실패에는 --yes 를 붙이지 않는다 (Turn 006 Finding 1) --"
# `--yes` 없이 실행한 사용자는 아직 발행을 승인하지 않았다. 안내가 `--yes` 를 덧붙이면
# 이 기능의 핵심인 발행 전 사람 확인을 건너뛰게 한다.
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3010-hint-noyes.md")"
err="$(FAKE_VISIBILITY=ERROR run_dr publish "$f" --upstream "CCC/DDD" 2>&1 >/dev/null)"; rc=$?
check "exit 3" "$rc" "3"
printf '%s' "$err" | grep -q -- '--yes' && nok "미승인 실패에 --yes 안내" || ok "미승인 실패에 --yes 없음"
printf '%s' "$err" | grep -q -- '--upstream CCC/DDD' && ok "대상은 보존" || nok "대상 유실: [$err]"
# 안내를 따라 실행하면 승인 화면(exit 5)에서 멈추고 아무것도 쓰지 않아야 한다.
: > "$GH_LOG"
snap="$(cat "$f")"
run_dr publish "$f" --upstream "CCC/DDD" >/dev/null 2>&1; rc=$?
check "안내대로 실행 시 승인 화면 (exit 5)" "$rc" "5"
check "issue create 0회" "$(calls 'issue create')" "0"
check "파일 무변경" "$(cat "$f")" "$snap"

echo "-- 대상 값이 무효면 재시도 명령을 만들지 않는다 (Turn 006 Finding 1) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3011-hint-badtarget.md")"
err="$(run_dr publish "$f" --upstream "A/B/C/D" --yes 2>&1 >/dev/null)"; rc=$?
check "exit 2" "$rc" "2"
printf '%s' "$err" | grep -q 'publish .*--yes' && nok "무효 대상으로 재시도 안내" || ok "재시도 명령 미제시"
printf '%s' "$err" | grep -q '조치' && ok "조치 안내 존재" || nok "조치 안내 없음: [$err]"

echo "-- payload 준비 실패는 거짓 attempting 을 남기지 않는다 (Finding 3) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3005-payload.md")"
snap="$(cat "$f")"
FAKE_MKTEMP_FAIL=1 run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 7 (문서화된 코드)" "$rc" "7"
check "issue create 0회" "$(calls 'issue create')" "0"
grep -q '^- upstream-issue: attempting:' "$f" && nok "거짓 attempting 잔존" || ok "거짓 attempting 없음"
check "파일 무변경" "$(cat "$f")" "$snap"

echo "-- 인자 오류는 무한 반복하지 않고 즉시 종료한다 (Finding 4) --"
# macOS 에는 coreutils `timeout` 이 없으므로 백그라운드 + 폴링으로 상한을 건다.
# 상한 초과는 124 로 보고해 무한 반복을 감지한다.
run_bounded() {  # $1=최대 초 ... 나머지=명령
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( i >= secs * 10 )); then
      kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
    i=$((i + 1)); sleep 0.1
  done
  wait "$pid"
}
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3006-optarg.md")"
for cmd in publish preview; do
  for bad_args in "--upstream" "--nope"; do
    rc=0
    run_bounded 15 env "PATH=$FAKEBIN:$PATH" bash -c \
      "cd '$WS' && bash '$TARGET' $cmd '$f' $bad_args" || rc=$?
    label="$cmd '$bad_args'"
    if [[ "$rc" -eq 2 ]]; then ok "$label: exit 2"
    elif [[ "$rc" -eq 124 ]]; then nok "$label: 무한 반복 (상한 초과)"
    else nok "$label: rc=$rc (기대 2)"; fi
  done
done

echo "-- exit 8 은 일반 재시도가 아니라 후보 선택을 안내한다 (Finding 5) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-3007-ambig.md")"
export FAKE_SEARCH="https://github.com/O/R/issues/42
https://github.com/O/R/issues/43"
err="$(run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"; rc=$?
unset FAKE_SEARCH
check "exit 8" "$rc" "8"
case "$err" in *set-issue*) ok "set-issue 연결 안내";; *) nok "set-issue 연결 안내";; esac
case "$err" in *"publish $f --yes"*) nok "일반 재시도 안내가 남아 있음";; *) ok "일반 재시도 안내 없음";; esac

echo "-- 쓰기 임시 파일이 대상과 같은 디렉토리에 만들어진다 (원자성) --"
setup_workspace
f="$(make_report "2026-08-12-3008-atomic.md" legacy)"
chmod 640 "$f"
(cd "$WS" && bash "$TARGET" ensure-id "$f" >/dev/null 2>&1)
mode="$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f" 2>/dev/null)"
check "원본 권한 보존 (640)" "$mode" "640"
leftover="$(find "$(dirname "$f")" -name '.rd-defect.*' | wc -l | tr -d ' ')"
check "임시 파일 잔존 없음" "$leftover" "0"

# --- config 부재에서 set-upstream 은 성공 skip 이다 (파일을 만들지 않는다) ---
DR9_DIR="$(mktemp -d)" || { echo "test_defect_reports.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$DR9_DIR" && -d "$DR9_DIR" ]] || { echo "test_defect_reports.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
mkdir -p "$DR9_DIR/rd-workflow/config" "$DR9_DIR/rd-workflow/scripts"
cp "$SCRIPT_DIR/defect_reports.sh" "$DR9_DIR/rd-workflow/scripts/"
cp "$SCRIPT_DIR/sync_template.sh" "$DR9_DIR/rd-workflow/scripts/" 2>/dev/null || true

DR9_OUT="$DR9_DIR/out.txt"
( cd "$DR9_DIR" && bash rd-workflow/scripts/defect_reports.sh set-upstream \
    "https://github.com/example/repo" ) > "$DR9_OUT" 2>&1
DR9_RC=$?

check "config 부재 set-upstream 종료코드 0" "$DR9_RC" "0"
check "config 파일을 만들지 않음" \
  "$( [ -e "$DR9_DIR/rd-workflow/config/workflow.json" ] && echo exists || echo absent )" "absent"
check "건너뜀 안내 출력" "$(grep -c '건너뜁니다' "$DR9_OUT")" "1"
check "--upstream 대안 안내 출력" "$(grep -c -- '--upstream' "$DR9_OUT")" "1"

# 기존 파일이 있으면 변경하지 않는다 (이미 설정됨 경로와 구분)
printf '{\n  "defect_report_upstream": "owner/repo"\n}\n' \
  > "$DR9_DIR/rd-workflow/config/workflow.json"
cp "$DR9_DIR/rd-workflow/config/workflow.json" "$DR9_DIR/wj.before"
( cd "$DR9_DIR" && bash rd-workflow/scripts/defect_reports.sh set-upstream \
    "https://github.com/other/repo" ) > /dev/null 2>&1
check "이미 설정됨 — 파일 무변경" \
  "$(diff "$DR9_DIR/wj.before" "$DR9_DIR/rd-workflow/config/workflow.json" | wc -l | tr -d ' ')" "0"
rm -rf "$DR9_DIR"

echo "== set-upstream: 줄 배치를 전제하지 않는다 (Turn 011 Finding 2) =="
# 이전 구현은 "1행에 { 가 있으면 그 행 전체를 출력한 뒤 키 줄을 붙였다". 그래서
#  - 한 줄 객체는 완성된 객체 **뒤**에 멤버가 붙어 invalid JSON 이 되는데 exit 0 이었고
#  - 첫 줄이 빈 줄이면 키가 삽입되지 않은 채 exit 0 이었다 (완료 보고만 "설정됨").
# python3 이 없는 환경에서는 JSON 파싱 검증만 건너뛴다 (production 과 같은 정책).
# JSON 유효성 단언. **검사기가 없으면 조용히 통과시키지 않고 skip 으로 표시한다** —
# 종전 구현은 python3 이 없으면 무조건 성공을 반환해, 검증되지 않은 사실을 "ok" 로 셌다.
assert_json_valid() {  # $1=파일 $2=라벨
  if ! command -v python3 >/dev/null 2>&1; then
    SKIP=$((SKIP+1)); printf '  skip %s (python3 없음 — JSON 구조 검증 불가)\n' "$2"; return 0
  fi
  if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
  then ok "$2"; else nok "$2 ($(cat "$1"))"; fi
}
CFG_REL="rd-workflow/config/workflow.json"

echo "-- 한 줄 객체 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{"default_execution_mode":"manual"}\n' > "$CFG"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
assert_json_valid "$CFG" "유효 JSON 유지"
check "upstream 값 삽입" \
  "$(sed -n 's/.*"defect_report_upstream"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)" "O/R"
grep -q '"default_execution_mode"[[:space:]]*:[[:space:]]*"manual"' "$CFG" \
  && ok "기존 키 보존" || nok "기존 키 보존"

echo "-- 첫 줄이 빈 줄인 객체 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '\n{\n  "default_execution_mode": "manual"\n}\n' > "$CFG"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
check "키가 실제로 삽입됨" \
  "$(sed -n 's/.*"defect_report_upstream"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)" "O/R"
assert_json_valid "$CFG" "유효 JSON"

echo "-- 빈 객체는 쉼표 없이 삽입한다 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{}\n' > "$CFG"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
assert_json_valid "$CFG" "유효 JSON (쉼표 없음)"
check "upstream 값 삽입" \
  "$(sed -n 's/.*"defect_report_upstream"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)" "O/R"

echo "-- 여는 '{' 가 없으면 원본 유지 + exit 1 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '[\n  "not-an-object"\n]\n' > "$CFG"
before="$(cat "$CFG")"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 1" "$rc" "1"
check "원본 bytes 불변" "$(cat "$CFG")" "$before"
leftover="$(find "$(dirname "$CFG")" -name '.rd-defect.*' | wc -l | tr -d ' ')"
check "임시 파일 잔존 없음" "$leftover" "0"

echo "-- symlink config 는 링크를 유지한 채 referent 를 갱신한다 --"
setup_workspace
CFG="$WS/$CFG_REL"
mkdir -p "$WS/real"
printf '{\n  "default_execution_mode": "manual"\n}\n' > "$WS/real/workflow.json"
rm -f "$CFG"
ln -s "../../real/workflow.json" "$CFG"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
[[ -L "$CFG" ]] && ok "여전히 symlink" || nok "여전히 symlink"
check "링크 target 동일" "$(readlink "$CFG")" "../../real/workflow.json"
check "referent 내용 갱신" \
  "$(sed -n 's/.*"defect_report_upstream"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WS/real/workflow.json" | head -1)" "O/R"
assert_json_valid "$WS/real/workflow.json" "referent 유효 JSON"

echo "-- pretty-printed 통제군은 종전과 같은 결과 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{\n  "default_execution_mode": "manual"\n}\n' > "$CFG"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
check "종전 형식 그대로" "$(cat "$CFG")" '{
  "defect_report_upstream": "O/R",
  "default_execution_mode": "manual"
}'

echo "== set-upstream: 구조 검증 없이는 사용자 config 를 고치지 않는다 (Turn 013 Finding 1) =="
# python3 만 없는 PATH 를 만든다. /usr/bin 을 통째로 빼면 sed·awk 까지 사라져 다른 이유로
# 죽으므로, 필요한 도구만 심링크한 디렉터리를 PATH 로 삼는다.
make_nopython_path() {
  local dir="$WS/nopybin" t path
  mkdir -p "$dir" || return 1
  for t in bash sed grep awk head tail cut sort tr wc find mktemp mkdir dirname basename \
           stat chmod mv rm cp ln cat od date diff env; do
    path="$(command -v "$t" 2>/dev/null)" || continue
    [[ "$path" == /* ]] && ln -sf "$path" "$dir/$t"
  done
  printf '%s' "$dir"
}

echo "-- python3 이 없으면 malformed 원본을 건드리지 않는다 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{"default_execution_mode":"manual",}\n' > "$CFG"   # 유효하지 않은 JSON
before="$(cat "$CFG")"
NOPY="$(make_nopython_path)"
if ( PATH="$NOPY"; command -v python3 >/dev/null 2>&1 )
then nok "PATH 정리 실패 — python3 가 남아 이 케이스는 무의미"
else ok "PATH 에 python3 없음"; fi
(cd "$WS" && PATH="$NOPY" bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "malformed + 검사기 부재: 원본 bytes 불변" "$(cat "$CFG")" "$before"
check "키가 삽입되지 않음" "$(grep -c 'defect_report_upstream' "$CFG")" "0"
check "임시 파일 잔존 없음" "$(find "$(dirname "$CFG")" -name '.rd-defect.*' | wc -l | tr -d ' ')" "0"

echo "-- python3 이 없으면 정상 원본에도 쓰지 않고 보류한다 (exit 0 + 안내) --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{\n  "default_execution_mode": "manual"\n}\n' > "$CFG"
before="$(cat "$CFG")"
NOPY="$(make_nopython_path)"
out="$( (cd "$WS" && PATH="$NOPY" bash "$TARGET" set-upstream 'https://github.com/O/R.git') 2>&1 )"; rc=$?
check "exit 0 (환경 조건이므로 sync 를 멈추지 않는다)" "$rc" "0"
check "원본 bytes 불변" "$(cat "$CFG")" "$before"
case "$out" in *보류*) ok "보류 사유 안내";;        *) nok "보류 사유 안내 없음: [$out]";; esac
case "$out" in *수동*) ok "수동 설정 방법 안내";;   *) nok "수동 설정 방법 안내 없음";; esac
case "$out" in *--upstream*) ok "--upstream 대안 안내";; *) nok "--upstream 대안 안내 없음";; esac

echo "-- 중첩 object 안의 동명 키를 top-level 로 오인하지 않는다 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{"integration":{"defect_report_upstream":""},"default_execution_mode":"manual"}\n' > "$CFG"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
grep -q '"integration":{"defect_report_upstream":""}' "$CFG" \
  && ok "중첩 값 무변경" || nok "중첩 값이 바뀜 ($(cat "$CFG"))"
assert_json_valid "$CFG" "유효 JSON 유지"
if command -v python3 >/dev/null 2>&1; then
  top="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("defect_report_upstream",""))' "$CFG")"
  check "top-level 키에 canonical 값" "$top" "O/R"
else
  SKIP=$((SKIP+1)); printf '  skip top-level 키 확인 (python3 없음)\n'
fi

echo "-- 최상위 중복 키는 판정 불가로 보류한다 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{"defect_report_upstream":"","defect_report_upstream":""}\n' > "$CFG"
before="$(cat "$CFG")"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "중복 키는 비영 종료 (rc=$rc)" || nok "중복 키인데 exit 0"
check "원본 bytes 불변" "$(cat "$CFG")" "$before"
check "임시 파일 잔존 없음" "$(find "$(dirname "$CFG")" -name '.rd-defect.*' | wc -l | tr -d ' ')" "0"

echo "-- 통제군: top-level 빈 값은 정상 치환된다 --"
setup_workspace
CFG="$WS/$CFG_REL"
printf '{"defect_report_upstream":"","default_execution_mode":"manual"}\n' > "$CFG"
(cd "$WS" && bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
check "exit 0" "$rc" "0"
check "값 치환" \
  "$(sed -n 's/.*"defect_report_upstream"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -1)" "O/R"
grep -q '"default_execution_mode":"manual"' "$CFG" && ok "기존 키 보존" || nok "기존 키 보존"
assert_json_valid "$CFG" "유효 JSON"

echo "-- symlink 대상에 쓰다 실패해도 referent 는 훼손되지 않는다 (Turn 013 Finding 2) --"
# 부분 출력 후 실패하는 `cat` 대역을 끼운다. 종전 구현(`cat "$tmp" > "$target"`)은 링크를
# 통해 원본에 직접 흘려보내 부분 bytes 로 referent 를 훼손했다.
setup_workspace; setup_fake_gh
CFG="$WS/$CFG_REL"
mkdir -p "$WS/real2"
printf '{\n  "default_execution_mode": "manual"\n}\n' > "$WS/real2/workflow.json"
before="$(cat "$WS/real2/workflow.json")"
rm -f "$CFG"
ln -s "../../real2/workflow.json" "$CFG"
(cd "$WS" && PATH="$FAKEBIN:$PATH" CAT_COUNT="$CAT_COUNT" \
   FAKE_CAT_FAIL_PATTERN=".rd-defect." FAKE_CAT_FAIL_AFTER=0 FAKE_CAT_PARTIAL='{"partial' \
   bash "$TARGET" set-upstream 'https://github.com/O/R.git' >/dev/null 2>&1); rc=$?
[[ "$rc" -ne 0 ]] && ok "쓰기 실패는 비영 종료 (rc=$rc)" || nok "쓰기 실패인데 exit 0"
check "referent bytes 불변" "$(cat "$WS/real2/workflow.json")" "$before"
[[ -L "$CFG" ]] && ok "여전히 symlink" || nok "여전히 symlink"
check "링크 target 동일" "$(readlink "$CFG")" "../../real2/workflow.json"
check "임시 파일 잔존 없음 (referent 쪽)" \
  "$(find "$WS/real2" -name '.rd-defect.*' | wc -l | tr -d ' ')" "0"
check "임시 파일 잔존 없음 (링크 쪽)" \
  "$(find "$(dirname "$CFG")" -name '.rd-defect.*' | wc -l | tr -d ' ')" "0"

echo "== no-python × 중첩 동명 키: 값을 추측하지 않는다 (Turn 015 Finding 1) =="
# 정규식 폴백은 `{"integration":{"defect_report_upstream":"other/repo"}}` 의 **중첩** 값을
# top-level 로 읽었다. 그 값은 set-upstream 의 「이미 설정됨」 판정과 **발행 대상 판정**에
# 함께 쓰이므로, 인자 없는 `publish --yes` 가 사용자가 승인한 적 없는 외부 저장소로 결함
# 보고를 내보낼 수 있었다. 교차 조건(검사기 부재 × 중첩 동명 키)을 한 케이스로 고정한다.
setup_workspace; setup_fake_gh
CFG="$WS/$CFG_REL"
printf '{"integration":{"defect_report_upstream":"other/repo"}}\n' > "$CFG"
before="$(cat "$CFG")"
NOPY="$(make_nopython_path)"
if ( PATH="$NOPY"; command -v python3 >/dev/null 2>&1 )
then nok "PATH 정리 실패 — python3 가 남아 이 케이스는 무의미"
else ok "PATH 에 python3 없음"; fi

# NOPY 를 앞에 두어 python3 을 가리고, fake gh 는 뒤쪽 FAKEBIN 에서 잡는다.
# (NOPY 의 cat·mv·mktemp 는 실물 심링크라 주입 대역이 끼어들지 않는다.)
nopy_dr() { (cd "$WS" && PATH="$NOPY:$FAKEBIN" GH_LOG="$GH_LOG" GH_ARGV="$GH_ARGV" GH_BODY="$GH_BODY" \
                        bash "$TARGET" "$@"); }

out="$(nopy_dr set-upstream 'https://github.com/O/R.git' 2>&1)"; rc=$?
check "set-upstream exit 0" "$rc" "0"
case "$out" in *"이미 설정됨"*) nok "중첩 값으로 거짓 성공";; *) ok "거짓 「이미 설정됨」 없음";; esac
case "$out" in *보류*)          ok "보류 사유 안내";; *) nok "보류 사유 안내 없음: [$out]";; esac
case "$out" in *수동*)          ok "수동 설정 안내";; *) nok "수동 설정 안내 없음";; esac
case "$out" in *--upstream*)    ok "--upstream 대안 안내";; *) nok "--upstream 대안 안내 없음";; esac
check "원본 bytes 불변" "$(cat "$CFG")" "$before"

f="$(make_report "2026-08-12-4001-nopy-nested.md")"
snap="$(cat "$f")"
: > "$GH_LOG"
nopy_dr publish "$f" --yes >/dev/null 2>&1; rc=$?
check "config 기반 publish 는 exit 2 (대상 없음)" "$rc" "2"
check "gh 호출 0회 (로그 전체)" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
check "파일 무변경" "$(cat "$f")" "$snap"
: > "$GH_LOG"
nopy_dr preview "$f" >/dev/null 2>&1; rc=$?
check "config 기반 preview 도 exit 2" "$rc" "2"
check "preview 도 gh 호출 0회" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

echo "-- 명시적 --upstream 은 검사기 유무와 무관하게 동작한다 --"
: > "$GH_LOG"
nopy_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; rc=$?
check "exit 0" "$rc" "0"
check "지정한 대상으로 발행 1회" "$(grep -c 'ARGS=issue create --repo O/R' "$GH_LOG")" "1"

echo "-- no-python + 정상 top-level 값도 자동 판정을 보류한다 (fail-closed 의 비용) --"
setup_workspace; setup_fake_gh
CFG="$WS/$CFG_REL"
printf '{\n  "defect_report_upstream": "AAA/BBB"\n}\n' > "$CFG"
NOPY="$(make_nopython_path)"
f="$(make_report "2026-08-12-4002-nopy-top.md")"
: > "$GH_LOG"
err="$(nopy_dr publish "$f" --yes 2>&1 >/dev/null)"; rc=$?
check "정상 값이어도 exit 2" "$rc" "2"
check "gh 호출 0회" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
case "$err" in *--upstream*) ok "--upstream 진행 방법 안내";; *) nok "--upstream 안내 없음: [$err]";; esac

echo "-- gh 실패 진단: 4갈래가 서로 구별되고 미분류는 원인을 단정하지 않는다 (AC 1·2) --"
# **명령 치환 안에서 부르지 않는다.** 서브셸이면 setup_workspace 의 케이스 디렉터리
# 변경과 rc 가 부모에 남지 않아 set -u 에서 스위트가 죽는다 (spec/plan review R9).
# 결과는 부모 셸의 DIAG_ERR·DIAG_RC 에 남긴다.
DIAG_ERR=""; DIAG_RC=0
diag_run() {  # $1=주입할 stderr 원문 — 부모 셸에서 직접 호출한다
  setup_workspace; setup_fake_gh
  local f
  f="$(make_report "2026-08-12-5001-diag.md")"
  DIAG_ERR="$(FAKE_VISIBILITY=ERROR FAKE_GH_STDERR="$1" run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"
  DIAG_RC=$?   # 바로 앞 명령 치환의 rc = publish 의 rc
}
diag_case() {  # $1=주입 $2=있어야 할 문구 $3=이름
  diag_run "$1"
  check "$3: exit 3 유지" "$DIAG_RC" "3"
  case "$DIAG_ERR" in *"$2"*) ok "$3: '$2' 도달";; *) nok "$3: '$2' 없음 — [$DIAG_ERR]";; esac
}
diag_case 'unknown flag: --repo'             '명령 인자가'      '문법 오류'
diag_case 'HTTP 401: Bad credentials'        '인증 문제'        '인증 실패'
diag_case 'HTTP 404: Not Found'              '찾을 수 없습니다'  '대상 없음'
diag_case 'dial tcp: lookup x: no such host' '네트워크로'       '네트워크'

echo "-- 미분류 오류는 원인을 단정하지 않고 원문만 낸다 (AC 2) --"
diag_run 'something entirely new happened'; err="$DIAG_ERR"
case "$err" in *"something entirely new happened"*) ok "미분류: 원문 도달";; *) nok "미분류: 원문 없음 — [$err]";; esac
case "$err" in
  *네트워크로*|*"인증 문제"*|*"명령 인자가"*|*"찾을 수 없습니다"*) nok "미분류인데 갈래를 단정함 — [$err]" ;;
  *) ok "미분류: 갈래 단정 없음" ;;
esac

echo "-- 분류는 절단 전 전문 기준이고, 잘림은 표시된다 (AC 1) --"
long_usage="unknown flag: --repo"
for i in $(seq 1 40); do long_usage="${long_usage}
usage line ${i}"; done
diag_run "$long_usage"; err="$DIAG_ERR"
case "$err" in *"명령 인자가"*) ok "긴 usage 뒤에도 문법 갈래 판정";; *) nok "절단 때문에 갈래를 놓침 — [$err]";; esac
case "$err" in *"unknown flag: --repo"*) ok "핵심 원문 보존";; *) nok "핵심 원문 소실 — [$err]";; esac
case "$err" in *"줄만 표시"*) ok "잘림 표시";; *) nok "잘렸는데 표시 없음 — [$err]";; esac

echo "-- 누적 byte 한도가 첫 줄을 포함해 지켜진다 (R7 후속) --"
# 첫 줄 3990 byte + 둘째 줄 100 byte → 첫 줄만 나오고 잘림 표시가 붙어야 한다.
big1="$(printf 'A%.0s' $(seq 1 3990))"
diag_run "${big1}
$(printf 'B%.0s' $(seq 1 100))"
case "$DIAG_ERR" in *"$big1"*) ok "한도 초과: 첫 줄은 보존";; *) nok "한도 초과: 첫 줄 소실";; esac
case "$DIAG_ERR" in *BBBBBBBBBB*) nok "한도 초과: 둘째 줄이 한도를 넘겨 출력됨";; *) ok "한도 초과: 둘째 줄 생략";; esac
case "$DIAG_ERR" in *"줄만 표시"*) ok "한도 초과: 잘림 표시";; *) nok "한도 초과: 잘림 표시 없음";; esac

echo "-- 첫 줄 자체가 한도를 넘어도 첫 줄은 보존하고 잘림을 알린다 (R7 후속) --"
huge="$(printf 'C%.0s' $(seq 1 5000))"
diag_run "${huge}
tail line"
case "$DIAG_ERR" in *"$huge"*) ok "거대 첫 줄 보존";; *) nok "거대 첫 줄 소실";; esac
case "$DIAG_ERR" in *"줄만 표시"*) ok "거대 첫 줄: 잘림 표시";; *) nok "거대 첫 줄: 잘림 표시 없음";; esac

echo "-- 한국어 원문이 어느 로케일에서도 UTF-8 로 온전하다 (R7) --"
# 500자를 훌쩍 넘는 한 줄. 문자·byte 슬라이스를 쓰면 LC_ALL=C 에서 마지막 문자가
# UTF-8 중간에서 잘린다. 줄 경계 절단은 로케일과 무관하게 안전하다.
kor_line="$(kor 400)"
if ! command -v iconv >/dev/null 2>&1; then
  SKIP=$((SKIP+1)); printf '  skip %s\n' "한국어 UTF-8 회귀 (iconv 없음)"
fi
for loc in "" "C"; do
  command -v iconv >/dev/null 2>&1 || break
  name="로케일=${loc:-기본}"
  if [[ -n "$loc" ]]; then
    setup_workspace; setup_fake_gh
    f="$(make_report "2026-08-12-5006-kor.md")"
    err="$(LC_ALL=C FAKE_VISIBILITY=ERROR FAKE_GH_STDERR="$kor_line" \
           run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"
  else
    diag_run "$kor_line"; err="$DIAG_ERR"
  fi
  # BSD(macOS) iconv 는 출력이 /dev/null 일 때 **대량 멀티바이트 입력에서** 유효한
  # UTF-8 에도 "Inappropriate ioctl for device" 로 실패한다 (같은 조합에서 ASCII 는
  # 통과하므로 입력 유효성과 무관한 환경 고유 결함이다). `wc -c` 를 한 단계 끼워
  # 출력을 파이프로 만들면 피할 수 있고, 진짜 잘못된 byte 열은 `set -o pipefail`
  # 아래에서 여전히 rc=1 로 전파된다 (실측 확인).
  if printf '%s' "$err" | iconv -f UTF-8 -t UTF-8 2>/dev/null | wc -c >/dev/null; then
    ok "$name: 출력이 유효한 UTF-8"
  else
    nok "$name: UTF-8 경계가 깨짐"
  fi
  case "$err" in *"$kor_line"*) ok "$name: 한국어 원문 보존";; *) nok "$name: 한국어 원문 손실";; esac
done

echo "-- 마스킹: credential 은 가리고 repo 이름은 남긴다 (AC 5) --"
mask_case() {  # $1=주입 $2=사라져야 할 문자열 $3=이름
  diag_run "$1"; local err="$DIAG_ERR"
  case "$err" in *"$2"*) nok "$3: credential 노출 — [$err]";; *) ok "$3: 마스킹됨";; esac
  case "$err" in *O/R*) ok "$3: repo 이름 보존";; *) nok "$3: repo 이름까지 가려짐 — [$err]";; esac
}
mask_case 'HTTP 401 using ghp_AAAAAAAAAAAAAAAAAAAA for O/R' 'ghp_AAAAAAAAAAAAAAAAAAAA' '토큰'
mask_case 'O/R rejected; Authorization: Bearer SYNTHETIC_SECRET_VALUE' 'SYNTHETIC_SECRET_VALUE' 'Bearer'
mask_case 'O/R rejected; authorization: Basic SYNTHETIC_BASE64_VALUE'  'SYNTHETIC_BASE64_VALUE' 'Basic'

echo "-- 캡처 불가(mktemp 실패)에서도 credential 이 새지 않는다 (AC 5) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-5005-nocapture.md")"
err="$(FAKE_MKTEMP_FAIL_GH=1 FAKE_VISIBILITY=ERROR \
       FAKE_GH_STDERR='HTTP 401 using ghp_BBBBBBBBBBBBBBBBBBBB' \
       run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"; rc=$?
check "캡처 불가에도 exit 3 유지" "$rc" "3"
case "$err" in *ghp_BBBBBBBBBBBBBBBBBBBB*) nok "캡처 불가 경로에서 credential 노출 — [$err]";; *) ok "캡처 불가: credential 미노출";; esac
case "$err" in *"수집하지 못했습니다"*) ok "캡처 불가: 사실을 알림";; *) nok "캡처 불가: 안내 없음 — [$err]";; esac

echo "-- 성공 경로는 조용하다 (AC 4) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-5004-quiet.md")"
err="$(FAKE_GH_STDERR='gh: a new release is available' \
       run_dr publish "$f" --upstream "O/R" --yes 2>&1 >/dev/null)"
check "성공 시 stderr 비어 있음" "$err" ""

echo "-- 호출 지점별로 진단이 사용자 stderr 까지 도달하고 stdout 은 오염되지 않는다 (AC 3·8) --"
# 갈래 × 지점을 곱하지 않는다 — 지점마다 대표 실패 하나로 리다이렉션 누락을 잡는다.
# 기대 exit 는 defect_reports.sh 를 직접 읽어 확인한 실제 값이다(추측값 아님):
#   auth 실패(778-779, 853-856) -> 4 / repo view 실패(785-786, 862-865) -> 3
#   issue list 실패(933-936, fail-closed) -> 3 / issue create 실패(1019-1022) -> 9
#   issue edit 실패(1035-1041) 는 best-effort 경고만 내고 발행 자체는 유지되어
#   13 역기록이 성공하면 publish exit 는 0 이다(line 374 기존 테스트가 이미 이를 전제).
# 임시 파일 생성 실패를 삼키지 않는다 (mktemp 가드 규약). 실패를 흘리면 빈 경로로
# 리다이렉트해 저장소 밖에 쓰는 사고가 난다 — 같은 유형의 사고 이력이 있다.
site_tmp() {  # stdout=임시 파일 경로
  local t
  t="$(mktemp)" || { echo "  FAIL 임시 파일 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$t" && -f "$t" ]] || { echo "  FAIL 임시 파일 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  printf '%s' "$t"
}
site_check() {  # $1=marker $2=기대 exit $3=이름 $4=out파일 $5=err파일 $6=rc
  local marker="$1" want="$2" name="$3" out="$4" err="$5" rc="$6"
  check "$name: exit $want" "$rc" "$want"
  grep -q "$marker" "$err" && ok "$name: 진단이 사용자 stderr 에 도달" || nok "$name: 진단 소실 — [$(cat "$err")]"
  grep -q "$marker" "$out" && nok "$name: 진단이 stdout 을 오염시킴" || ok "$name: stdout 미오염"
}

setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-7001-site-auth.md")"
out="$(site_tmp)" || exit 1; err="$(site_tmp)" || exit 1
FAKE_AUTH=fail FAKE_GH_STDERR="SYNTHETIC_SITE_MARKER_auth_publish" \
  run_dr publish "$f" --upstream "O/R" --yes >"$out" 2>"$err"; rc=$?
site_check "SYNTHETIC_SITE_MARKER_auth_publish" 4 "auth-publish" "$out" "$err" "$rc"
rm -f "$out" "$err"

setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-7002-site-repoview.md")"
out="$(site_tmp)" || exit 1; err="$(site_tmp)" || exit 1
FAKE_VISIBILITY=ERROR FAKE_GH_STDERR="SYNTHETIC_SITE_MARKER_repo_view" \
  run_dr publish "$f" --upstream "O/R" --yes >"$out" 2>"$err"; rc=$?
site_check "SYNTHETIC_SITE_MARKER_repo_view" 3 "repo-view" "$out" "$err" "$rc"
rm -f "$out" "$err"

setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-7003-site-issuelist.md")"
out="$(site_tmp)" || exit 1; err="$(site_tmp)" || exit 1
FAKE_SEARCH=FAIL FAKE_GH_STDERR="SYNTHETIC_SITE_MARKER_issue_list" \
  run_dr publish "$f" --upstream "O/R" --yes >"$out" 2>"$err"; rc=$?
site_check "SYNTHETIC_SITE_MARKER_issue_list" 3 "issue-list" "$out" "$err" "$rc"
rm -f "$out" "$err"

setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-7004-site-issuecreate.md")"
out="$(site_tmp)" || exit 1; err="$(site_tmp)" || exit 1
FAKE_CREATE=fail FAKE_GH_STDERR="SYNTHETIC_SITE_MARKER_issue_create" \
  run_dr publish "$f" --upstream "O/R" --yes >"$out" 2>"$err"; rc=$?
site_check "SYNTHETIC_SITE_MARKER_issue_create" 9 "issue-create" "$out" "$err" "$rc"
rm -f "$out" "$err"

setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-7005-site-issueedit.md")"
out="$(site_tmp)" || exit 1; err="$(site_tmp)" || exit 1
FAKE_EDIT=fail FAKE_GH_STDERR="SYNTHETIC_SITE_MARKER_issue_edit" \
  run_dr publish "$f" --upstream "O/R" --yes >"$out" 2>"$err"; rc=$?
site_check "SYNTHETIC_SITE_MARKER_issue_edit" 0 "issue-edit" "$out" "$err" "$rc"
rm -f "$out" "$err"

echo "-- preview 경로의 auth status 도 진단을 낸다 (AC 3 — 별도 호출 지점) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-7006-site-preview.md")"
# **`preview` 서브커맨드를 실제로 부른다.** `publish` 를 --yes 없이 부르면
# cmd_publish() 의 auth 지점을 지날 뿐 cmd_preview() 의 별도 auth 지점에는
# 닿지 않아, 그쪽 회귀를 놓친다 (final diff review F1).
err="$(FAKE_AUTH=fail FAKE_GH_STDERR='SYNTHETIC_PREVIEW_MARKER' \
       run_dr preview "$f" --upstream "O/R" 2>&1 >/dev/null)"; rc=$?
check "preview: exit 4" "$rc" "4"
case "$err" in *SYNTHETIC_PREVIEW_MARKER*) ok "preview: 진단 도달";; *) nok "preview: 진단 소실 — [$err]";; esac
case "$err" in *"인증 상태를 확인하지 못했습니다"*) ok "preview: 원인을 단정하지 않음";; *) nok "preview: 메시지 미변경 — [$err]";; esac

echo "-- L1: gh 호출 인자 형태 계약 (gh 불필요) --"
# 옵션 이름 추출은 **현재 6개 호출 지점이 쓰는 형태로 한정한 명시적 계약**이다
# (spec 2-B). 일반 CLI 파서가 아니다. `$*` 공백 분할과 `eval` 은 쓰지 않는다 —
# --jq 값의 `-->` 가 옵션으로 오인된다.
_argv_sub() {  # $1=레코드
  local -a f; IFS=$'\037' read -r -a f <<< "$1"; printf '%s %s' "${f[1]:-}" "${f[2]:-}"
}
_argv_opts() {  # $1=레코드 -> 옵션 이름 (개행 구분)
  local -a f; local i n; IFS=$'\037' read -r -a f <<< "$1"; n=${#f[@]}; i=1
  while (( i < n )); do
    case "${f[i]}" in
      --*) printf '%s\n' "${f[i]%%=*}"
           # 다음 토큰이 옵션이 아니면 이 옵션의 **값**이므로 건너뛴다.
           if [[ "${f[i]}" != *=* ]] && (( i+1 < n )) && [[ -n "${f[i+1]}" && "${f[i+1]}" != --* ]]; then i=$((i+1)); fi ;;
    esac
    i=$((i+1))
  done
}
_argv_positionals() {  # $1=레코드 -> 위치 인자 (서브커맨드 2개 제외)
  local -a f; local i n; IFS=$'\037' read -r -a f <<< "$1"; n=${#f[@]}; i=3
  while (( i < n )); do
    case "${f[i]}" in
      --*) if [[ "${f[i]}" != *=* ]] && (( i+1 < n )) && [[ -n "${f[i+1]}" && "${f[i+1]}" != --* ]]; then i=$((i+1)); fi ;;
      "")  ;;
      *)   printf '%s\n' "${f[i]}" ;;
    esac
    i=$((i+1))
  done
}
_l1_fail() { [[ "$1" == report ]] && nok "L1: $2"; return 0; }
_l1_need() {  # $1=옵션목록 $2=필요옵션 $3=서브커맨드 $4=mode
  printf '%s\n' "$1" | grep -qx -- "$2" && return 0
  _l1_fail "$4" "${3} 에 ${2} 가 없습니다"; return 1
}

gh_contract_l1() {  # $1=argv로그 $2=report|quiet -> 0 통과 / 1 위반
  local log="$1" mode="$2" rec sub opts o seen="" bad=0
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    sub="$(_argv_sub "$rec")"; opts="$(_argv_opts "$rec")"
    seen="${seen}[${sub}]"
    case "$sub" in
      "auth status") _l1_need "$opts" --hostname "$sub" "$mode" || bad=1 ;;
      "repo view")
        _l1_need "$opts" --json "$sub" "$mode" || bad=1
        if printf '%s\n' "$opts" | grep -qx -- '--repo'; then
          _l1_fail "$mode" "repo view 가 --repo 를 사용합니다 — 저장소는 위치 인자여야 합니다"; bad=1
        fi
        [[ -n "$(_argv_positionals "$rec")" ]] || { _l1_fail "$mode" "repo view 에 위치 인자(저장소)가 없습니다"; bad=1; } ;;
      "issue list")   for o in --repo --state --search --json --jq; do _l1_need "$opts" "$o" "$sub" "$mode" || bad=1; done ;;
      "issue create") for o in --repo --title --body-file;          do _l1_need "$opts" "$o" "$sub" "$mode" || bad=1; done ;;
      "issue edit")   _l1_need "$opts" --add-label "$sub" "$mode" || bad=1 ;;
    esac
  done < "$log"
  local s
  for s in "auth status" "repo view" "issue list" "issue create" "issue edit"; do
    case "$seen" in *"[${s}]"*) ;; *) _l1_fail "$mode" "호출 지점 미관측: ${s}"; bad=1 ;; esac
  done
  return $bad
}

echo "-- L1 전수: preview 와 publish 의 호출을 합쳐 6개 지점을 모두 본다 (AC 8) --"
setup_workspace; setup_fake_gh
f="$(make_report "2026-08-12-8001-l1.md")"
PREVIEW_ARGV="$WS/argv-preview.log"; PUBLISH_ARGV="$WS/argv-publish.log"
: > "$GH_ARGV"; run_dr preview "$f" --upstream "O/R" >/dev/null 2>&1; cp "$GH_ARGV" "$PREVIEW_ARGV"
: > "$GH_ARGV"; run_dr publish "$f" --upstream "O/R" --yes >/dev/null 2>&1; cp "$GH_ARGV" "$PUBLISH_ARGV"
ALL_ARGV="$WS/argv-all.log"; cat "$PREVIEW_ARGV" "$PUBLISH_ARGV" > "$ALL_ARGV"

# preview 와 publish 각각이 독립적으로 auth status 를 부른다 — 두 개의 다른 호출 지점이다.
check "preview 경로가 auth status 호출" "$(cut -d$'\037' -f2,3 "$PREVIEW_ARGV" | grep -c '^auth')" "1"
check "publish 경로가 auth status 호출" "$(cut -d$'\037' -f2,3 "$PUBLISH_ARGV" | grep -c '^auth')" "1"

if gh_contract_l1 "$ALL_ARGV" report; then ok "L1: 현재 호출이 인자 계약을 만족"; else nok "L1: 위반 있음 (위 항목 참조)"; fi

echo "-- L2: 로그에 실제로 남은 옵션이 gh --help 에 존재하는가 (AC 7·9·10·11) --"
# 검사 대상은 **기대값 표가 아니라 로그의 실제 옵션**이다. 기대값을 검사하면
# "기대값 자체가 틀린 경우"(원 결함)를 그대로 놓친다.
# 대조는 help 정의줄에서 뽑은 **옵션 이름 목록과의 고정 문자열 비교**다 (정규식 삽입 금지).
REAL_GH="$(command -v gh || true)"
REAL_GH_VER=""; [[ -n "$REAL_GH" ]] && REAL_GH_VER="$("$REAL_GH" --version 2>/dev/null | head -1)"
CLI_CONTRACT_NOTE="미검증 (검사 미도달)"

gh_contract_l2() {  # $1=argv로그 $2=report|quiet -> 0 통과 / 1 위반 / 2 미검증
  local log="$1" mode="$2" rec sub opt cache tmp hrc bad=0 helpdir unver=""
  [[ -n "$REAL_GH" ]] || { CLI_CONTRACT_NOTE="미검증 (gh 미설치)"; return 2; }
  helpdir="$WS/ghhelp"
  mkdir -p "$helpdir" || { CLI_CONTRACT_NOTE="미검증 (help 캐시 디렉터리 생성 실패)"; return 2; }
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    sub="$(_argv_sub "$rec")"
    case "$sub" in [a-z]*" "[a-z]*) ;; *) continue ;; esac
    cache="$helpdir/${sub// /_}"
    if [[ ! -f "$cache" ]]; then
      tmp="$helpdir/.help.tmp"; hrc=0
      "$REAL_GH" ${sub} --help > "$tmp" 2>&1 || hrc=$?
      if (( hrc != 0 )); then
        # **중단하지 않습니다.** 이미 찾은 위반을 버리고 '미검증' 만 남기면 실제
        # 계약 위반이 사용자 눈에서 사라집니다. 이 서브커맨드만 미검증으로 둡니다.
        [[ -z "$unver" ]] && unver="gh ${sub} --help 실패 rc=${hrc}, ${REAL_GH_VER} — 원인: $(head -3 "$tmp" | tr '\n' ' ')"
        rm -f "$tmp"; continue
      fi
      # 정의줄에서 **옵션 이름만** 뽑아 캐시한다. 성공한 출력만 캐시한다.
      sed -nE 's/^[[:space:]]*(-[a-zA-Z], )?(--[a-zA-Z0-9][a-zA-Z0-9-]*).*/\2/p' "$tmp" > "${cache}.names"
      mv "$tmp" "$cache"
    fi
    [[ -f "${cache}.names" ]] || continue
    while IFS= read -r opt; do
      [[ -n "$opt" ]] || continue
      # **고정 문자열 전체 줄 비교.** 로그의 옵션을 정규식에 끼워 넣으면 문법 오류를
      # 잡는 검사가 문법 오류 입력을 신뢰합니다 — `--j.on` 이 `--json` 에 일치합니다.
      grep -qxF -- "$opt" "${cache}.names" || {
        [[ "$mode" == report ]] && nok "L2: gh ${sub} 에 존재하지 않는 옵션 ${opt} (${REAL_GH_VER})"
        bad=$((bad+1))
      }
    done <<< "$(_argv_opts "$rec")"
  done < "$log"
  if (( bad > 0 )); then
    if [[ -n "$unver" ]]; then CLI_CONTRACT_NOTE="수행·실패 (${bad}건, ${REAL_GH_VER}; 일부 미검증: ${unver})"
    else                       CLI_CONTRACT_NOTE="수행·실패 (${bad}건, ${REAL_GH_VER})"; fi
    return 1
  fi
  if [[ -n "$unver" ]]; then CLI_CONTRACT_NOTE="미검증 (${unver})"; return 2; fi
  CLI_CONTRACT_NOTE="수행·통과 (${REAL_GH_VER})"
  return 0
}

gh_contract_l2 "$ALL_ARGV" report; l2_rc=$?
case "$l2_rc" in
  0) ok "L2: 로그의 모든 옵션이 gh --help 정의줄에 존재" ;;
  1) : ;;   # nok 는 함수 안에서 기록했다
  2) SKIP=$((SKIP+1)); printf '  skip %s\n' "L2 실제 CLI 계약 — ${CLI_CONTRACT_NOTE}" ;;
esac

echo "-- L2 대조: 접두사 오타와 정규식 메타문자가 통과하지 못한다 (R2 후속) --"
# **help 를 새로 부르지 않는다.** 본 검사가 성공했을 때만 만드는 이름 목록을 재사용한다.
# 다시 부르면 그 호출이 실패했을 때 도구 실행 불가를 계약 위반으로 보고하게 된다.
L2_PROBE_NOTE=""
l2_probe() {
  local names="$WS/ghhelp/issue_list.names"
  if [[ -s "$names" ]]; then
    L2_PROBE_NOTE="ran"
    grep -qxF -- '--json' "$names" && ok "L2 대조: 정상 --json 통과" || nok "L2 대조: 정상 --json 거부됨"
    grep -qxF -- '--stat' "$names" && nok "L2 대조: 접두사 오타 --stat 통과함"  || ok "L2 대조: --stat 거부"
    grep -qxF -- '--j.on' "$names" && nok "L2 대조: 정규식 --j.on 통과함"       || ok "L2 대조: --j.on 거부"
  else
    L2_PROBE_NOTE="$CLI_CONTRACT_NOTE"
    SKIP=$((SKIP+1)); printf '  skip %s\n' "L2 대조 probe — ${CLI_CONTRACT_NOTE}"
  fi
}
l2_probe

echo "-- help 실행 불가는 계약 위반이 아니라 미검증이다 (R6 후속) --"
FAKE_GH_BIN="$WS/fakegh/gh"; mkdir -p "$WS/fakegh"
printf '#!/usr/bin/env bash\nif [[ "$*" == *--help* ]]; then echo "gh: synthetic help failure" >&2; exit 7; fi\nexec true\n' > "$FAKE_GH_BIN"
chmod +x "$FAKE_GH_BIN"

SAVED_GH="$REAL_GH"; SAVED_VER="$REAL_GH_VER"; SAVED_NOTE="$CLI_CONTRACT_NOTE"
REAL_GH="$FAKE_GH_BIN"; REAL_GH_VER="gh synthetic"; rm -rf "$WS/ghhelp"
gh_contract_l2 "$ALL_ARGV" quiet; inj_rc=$?
fail_before="$FAIL"; skip_before="$SKIP"
l2_probe
fail_after="$FAIL"; skip_after="$SKIP"

check "help 실패: gh_contract_l2 rc=2" "$inj_rc" "2"
case "$CLI_CONTRACT_NOTE" in
  *미검증*rc=7*) ok "help 실패: 요약이 미검증·원인을 담음" ;;
  *) nok "help 실패: 요약이 미검증·원인을 담지 않음 — [$CLI_CONTRACT_NOTE]" ;;
esac
check "help 실패: probe 가 FAIL 을 늘리지 않음" "$fail_after" "$fail_before"
check "help 실패: probe 가 SKIP 을 늘림"        "$skip_after" "$((skip_before+1))"
case "$L2_PROBE_NOTE" in *rc=7*) ok "help 실패: probe skip 사유에 원인 포함";; *) nok "help 실패: probe skip 사유 부족 — [$L2_PROBE_NOTE]";; esac

# 원래 환경으로 되돌리고 본 검사 기준 캐시·요약을 복원한다.
REAL_GH="$SAVED_GH"; REAL_GH_VER="$SAVED_VER"; rm -rf "$WS/ghhelp"
gh_contract_l2 "$ALL_ARGV" quiet >/dev/null 2>&1 || true

echo "-- 회귀 fixture: 원 결함(gh repo view --repo)을 검사가 실제로 거부하는가 (AC 7) --"
setup_workspace; setup_fake_gh
BROKEN="$WS/defect_reports_broken.sh"
cp "$TARGET" "$BROKEN"
# 정본은 건드리지 않는다 — 사본에만 원 결함을 되돌린다.
sed -i.bak 's|repo view "\$repo" --json visibility|repo view --repo "$repo" --json visibility|' "$BROKEN"
rm -f "$BROKEN.bak"
grep -q 'repo view --repo' "$BROKEN" && ok "fixture: 원 결함 주입됨" || nok "fixture: 주입 실패"

f="$(make_report "2026-08-12-9001-regress.md")"
BROKEN_ARGV="$WS/argv-broken.log"; : > "$GH_ARGV"
( cd "$WS" && PATH="$FAKEBIN:$PATH" GH_LOG="$GH_LOG" GH_ARGV="$GH_ARGV" GH_BODY="$GH_BODY" \
    MV_COUNT="$MV_COUNT" CAT_COUNT="$CAT_COUNT" bash "$BROKEN" publish "$f" --upstream "O/R" ) >/dev/null 2>&1
( cd "$WS" && PATH="$FAKEBIN:$PATH" GH_LOG="$GH_LOG" GH_ARGV="$GH_ARGV" GH_BODY="$GH_BODY" \
    MV_COUNT="$MV_COUNT" CAT_COUNT="$CAT_COUNT" bash "$BROKEN" publish "$f" --upstream "O/R" --yes ) >/dev/null 2>&1
cp "$GH_ARGV" "$BROKEN_ARGV"

# 같은 진입점, 서로 다른 입력 — 결과가 갈려야 한다.
# 예상 실패는 quiet 로 돌려 스위트의 FAIL 카운터를 오염시키지 않는다.
gh_contract_l1 "$ALL_ARGV" quiet;    l1_ok_rc=$?
gh_contract_l1 "$BROKEN_ARGV" quiet; l1_bad_rc=$?
check "L1: 정상 로그를 통과시킴" "$l1_ok_rc" "0"
check "L1: 결함 로그를 거부함"   "$l1_bad_rc" "1"

# **L2 거부는 정상 로그가 rc=0 일 때만 요구한다.** gh 설치 여부만 보고 요구하면
# 도구를 못 돌린 상황(help 실패)이 계약 위반으로 보고된다 (R6 후속).
gh_contract_l2 "$ALL_ARGV" quiet; l2_ok_rc=$?; l2_ok_note="$CLI_CONTRACT_NOTE"
if (( l2_ok_rc == 0 )); then
  ok "L2: 정상 로그를 통과시킴"
  gh_contract_l2 "$BROKEN_ARGV" quiet; l2_bad_rc=$?
  check "L2: 결함 로그를 거부함" "$l2_bad_rc" "1"
elif (( l2_ok_rc == 2 )); then
  SKIP=$((SKIP+1)); printf '  skip %s\n' "L2 회귀 — 정상 로그가 미검증(${l2_ok_note}). L1 의 거부는 위에서 검증됨"
else
  nok "L2: 정상 로그를 거부함 (${l2_ok_note})"
fi
# CLI_CONTRACT_NOTE 가 quiet 회귀(결함 로그)의 값으로 덮인 채 요약에 나가지 않도록
# 정상 로그 기준 값을 되돌린다.
CLI_CONTRACT_NOTE="$l2_ok_note"

printf '\n실제 CLI 계약 검증: %s\n' "$CLI_CONTRACT_NOTE"
printf '결과: pass=%d fail=%d skip=%d\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
