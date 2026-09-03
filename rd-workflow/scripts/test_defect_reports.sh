#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/defect_reports.sh"
PASS=0; FAIL=0

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
  SUITE_ROOT="$(mktemp -d)" || return 1
  [[ -n "$SUITE_ROOT" && -d "$SUITE_ROOT" ]] || return 1
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

echo "== 발행 경로 (fake gh) =="

setup_fake_gh() {
  FAKEBIN="$WS/fakebin"; mkdir -p "$FAKEBIN"
  GH_LOG="$WS/gh-calls.log"; GH_BODY="$WS/gh-body.txt"
  : > "$GH_LOG"; : > "$GH_BODY"
  cat > "$FAKEBIN/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'HOST=%s ARGS=%s\n' "${GH_HOST:-github.com}" "$*" >> "$GH_LOG"
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
    (( n > ${FAKE_CAT_FAIL_AFTER:-0} )) && { printf 'cat: 주입된 실패\n' >&2; exit 1; }
  done
fi
exec /bin/cat "$@"
FAKECAT
  chmod +x "$FAKEBIN/cat"
}
run_dr() { (cd "$WS" && PATH="$FAKEBIN:$PATH" GH_LOG="$GH_LOG" GH_BODY="$GH_BODY" \
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
probe() {   # $1=목표 총 byte $2=legacy|"" -> publish 종료 코드
  local target="$1" mode="${2:-}" ff
  ff="$(make_report "2026-08-12-3003-probe-${target}-${mode:-normal}.md" $mode)"
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
DR9_DIR="$(mktemp -d)"
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

printf '\n결과: pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
