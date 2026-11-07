#!/usr/bin/env bash
# pick.py 계약 시험. 실행: /bin/bash rd-workflow/scripts/fr_do/test_pick.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICK="$HERE/pick.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/fr-do-pick.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
fail=0
P() { echo "PASS $1"; }
F() { echo "FAIL $1: $2"; fail=1; }
TAB="$(printf '\t')"

# 새 fixture: fx <이름> → $D
fx() {
  D="$T/$1"; ITEMS="$D/rd-workflow-workspace/backlog/items"; IDX="$D/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
  mkdir -p "$ITEMS" "$D/rd-workflow/config"
  printf '## 인덱스\n\n| 날짜 | 제목 | 요약 | 종류 | 상태 | 우선순위 | 관계 | 상세 |\n|---|---|---|---|---|---|---|---|\n' > "$IDX"
}
# item <short-title> <status> <priority> [related files 줄 본문] [depends-on stem]
item() {
  local t="$1" st="$2" pri="$3" rel="${4-}" dep="${5-}" d="2026-02-01"
  { printf '# %s %s\n- status: %s\n- kind: feature\n- summary: fixture\n' "$d" "$t" "$st"
    [ -n "$dep" ] && printf -- '- depends-on: %s\n' "$dep"
    [ -n "$rel" ] && printf -- '- related files: %s\n' "$rel"
    true
  } > "$ITEMS/$d-$t.md"
  printf '| %s | %s | 요약 | feature | %s | %s | - | [상세](items/%s-%s.md) |\n' "$d" "$t" "$st" "$pri" "$d" "$t" >> "$IDX"
}
# pick <이름> [인자...] — 출력 $T/<이름>.out, rc $RC (인자의 --active 기본은 없는 파일)
pick() {
  local n="$1"; shift
  python3 -I "$PICK" --root "$D" --active "$D/none.tsv" "$@" > "$T/$n.out" 2> "$T/$n.err"; RC=$?
}
line() { grep -qxF -- "$2" "$T/$1.out" && P "$1: $2" || F "$1" "줄 없음 '$2' — $(tr '\n' '|' < "$T/$1.out")"; }
noline() { grep -qF -- "$2" "$T/$1.out" && F "$1" "있으면 안 되는 '$2' — $(tr '\n' '|' < "$T/$1.out")" || P "$1: 없음 $2"; }
count() { local c; c="$(grep -c "^$2$TAB" "$T/$1.out")"; [ "$c" = "$3" ] && P "$1: $2 ${3}줄" || F "$1" "$2 줄 수 $c (기대 $3) — $(tr '\n' '|' < "$T/$1.out")"; }
rc0() { [ "$RC" = 0 ] && P "$1: rc 0" || F "$1" "rc=$RC $(cat "$T/$1.err")"; }
S() { printf 'stream\t%s\t%s\t%s' "$1" "$2" "$3"; }
ST="2026-02-01-"

fx statuses
item i idea P1; item v validated P2; item r ready-for-request P3; item b blocked -
pick pick_interactive_statuses --mode interactive
line pick_interactive_statuses "$(S 1 ${ST}i '')"
line pick_interactive_statuses "$(S 2 ${ST}v '')"
line pick_interactive_statuses "$(S 3 ${ST}r '')"
line pick_interactive_statuses "skip	${ST}b	상태 blocked"; rc0 pick_interactive_statuses
pick pick_headless_statuses --mode headless
line pick_headless_statuses "order	${ST}v	ready"
line pick_headless_statuses "order	${ST}r	ready"
noline pick_headless_statuses "order	${ST}i"
line pick_headless_statuses "skip	${ST}i	상태 idea"; rc0 pick_headless_statuses

fx notready
item a idea P1; item w validated P2 "" "${ST}a"
pick pick_not_ready_skip --mode interactive
line pick_not_ready_skip "skip	${ST}w	waiting:${ST}a"
pick pick_not_ready_skip_h --mode headless
line pick_not_ready_skip_h "order	${ST}w	waiting:${ST}a"

fx bundle
item a validated P1 '`rd-workflow/x.sh`'; item b validated P2 '`rd-workflow/x.sh`'
pick pick_overlap_bundle --mode interactive
line pick_overlap_bundle "$(S 1 ${ST}a,${ST}b 'rd-workflow/x.sh')"; count pick_overlap_bundle stream 1

fx chain
item a validated P1 '`p/1` `p/ab`'; item b validated P2 '`p/ab` `p/bc`'
item c validated P3 '`p/bc` `p/cd`'; item d validated - '`p/cd` `p/de`'; item e validated - '`p/de`'
pick pick_chain_cap --mode interactive
line pick_chain_cap "$(S 1 ${ST}a,${ST}b,${ST}c 'p/1;p/ab;p/bc;p/cd')"
line pick_chain_cap "hold	${ST}d	겹침 보류 — a 와 같은 파일, 줄기당 3건 상한"
# 보류된 d 하고만 겹치는 e 는 d 를 거쳐 묶이지 않고 따로 줄기가 됩니다.
line pick_chain_cap "$(S 2 ${ST}e 'p/de')"

# 별 모양: d 가 a·b·c 를 모두 이어 묶음이 상한을 넘으므로 d 를 보류합니다.
# 보류된 d 는 묶음 연결에 쓰지 않으므로 서로 겹치지 않는 a·b·c 는 줄기 3개입니다.
fx star
item a validated P1 '`p/a`'; item b validated P2 '`p/b`'; item c validated P3 '`p/c`'
item d validated - '`p/a` `p/b` `p/c`'
pick pick_chain_cap_star --mode interactive
line pick_chain_cap_star "hold	${ST}d	겹침 보류 — a 와 같은 파일, 줄기당 3건 상한"
line pick_chain_cap_star "$(S 1 ${ST}a 'p/a')"
line pick_chain_cap_star "$(S 2 ${ST}b 'p/b')"
line pick_chain_cap_star "$(S 3 ${ST}c 'p/c')"
noline pick_chain_cap_star "${ST}d	p/"

fx activeov
item e validated P1 '`rd-workflow/x.sh`'
printf 's9\trd-workflow/x.sh\n' > "$D/active.tsv"
pick pick_active_overlap_hold --mode interactive --active "$D/active.tsv"
line pick_active_overlap_hold "hold	${ST}e	실행 중 줄기 s9 와 겹침"; count pick_active_overlap_hold stream 0

fx activefr
item a validated P1; item b validated P2
printf 's9\t\t%sa\n' "$ST" > "$D/active.tsv"
pick pick_active_fr_hold --mode interactive --active "$D/active.tsv" --max-streams 2
line pick_active_fr_hold "hold	${ST}a	실행 중 줄기 s9 의 FR"
line pick_active_fr_hold "$(S 1 ${ST}b '')"; count pick_active_fr_hold stream 1

fx maxs
item a validated P1 '`a/1`'; item b validated P2 '`b/1`'
pick pick_max_streams_hold --mode interactive --max-streams 1
line pick_max_streams_hold "$(S 1 ${ST}a 'a/1')"
line pick_max_streams_hold "hold	${ST}b	동시 줄기 상한 1"
# 실행 중 줄기도 상한에 센다
printf 's9\tz/1\n' > "$D/active.tsv"
pick pick_max_streams_active --mode interactive --max-streams 1 --active "$D/active.tsv"
line pick_max_streams_active "hold	${ST}a	동시 줄기 상한 1"
# 기본값은 workflow.json
printf '{"fr_do_max_streams": 1}\n' > "$D/rd-workflow/config/workflow.json"
pick pick_max_streams_json --mode interactive
line pick_max_streams_json "hold	${ST}b	동시 줄기 상한 1"

fx shared
item a validated P1 '`rd-workflow/scripts/self_test.sh` `.claude/rules/rd-workflow/core.md`'
item b validated P2 '`_ROOT_FILES/rd-workflow/scripts/self_test.sh` `_ROOT_FILES/.claude/rules/rd-workflow/core.md`'
pick pick_shared_registration_excluded --mode interactive
count pick_shared_registration_excluded stream 2
line pick_shared_registration_excluded "$(S 1 ${ST}a '')"

fx norel
item a validated P1; item b validated P2 '-'
pick pick_no_related --mode interactive
count pick_no_related stream 2; line pick_no_related "$(S 1 ${ST}a '')"

fx dirp
item a validated P1 '`rd-workflow/scripts/`'; item b validated P2 '`rd-workflow/scripts/fr_do/pick.py`'
item c validated P3 '`rd-workflow/scriptsX/y.sh`'
pick pick_dir_prefix_overlap --mode interactive
line pick_dir_prefix_overlap "$(S 1 ${ST}a,${ST}b 'rd-workflow/scripts/;rd-workflow/scripts/fr_do/pick.py')"
line pick_dir_prefix_overlap "$(S 2 ${ST}c 'rd-workflow/scriptsX/y.sh')"

fx rootpre
item a validated P1 '`_ROOT_FILES/rd-workflow/x.sh`'; item b validated P2 '`rd-workflow/x.sh`'
pick pick_root_prefix_normalize --mode interactive
line pick_root_prefix_normalize "$(S 1 ${ST}a,${ST}b 'rd-workflow/x.sh')"

fx noactive
item a validated P1 '`a/1`'
python3 -I "$PICK" --root "$D" --mode interactive --active "$D/nonexistent.tsv" > "$T/pick_no_active_file.out" 2>&1; RC=$?
rc0 pick_no_active_file; line pick_no_active_file "$(S 1 ${ST}a 'a/1')"

fx rootfile
item a validated P1 '`CLAUDE.md`'; item b validated P2 '`CLAUDE.md`'
item c validated P3 '`newdir/new.sh`'; item d validated - '`newdir/new.sh`'
item e validated - '`Makefile`'; item f validated - '`Makefile`'
pick pick_root_file_overlap --mode interactive
line pick_root_file_overlap "$(S 1 ${ST}a,${ST}b 'CLAUDE.md')"
line pick_root_file_overlap "$(S 2 ${ST}c,${ST}d 'newdir/new.sh')"
line pick_root_file_overlap "$(S 3 ${ST}e,${ST}f 'Makefile')"

fx rootact
item a validated P1 '`CLAUDE.md`'; item b validated P2 '`Makefile`'
printf 's9\tCLAUDE.md;Makefile\n' > "$D/active.tsv"
pick pick_root_file_active_hold --mode interactive --active "$D/active.tsv"
line pick_root_file_active_hold "hold	${ST}a	실행 중 줄기 s9 와 겹침"
line pick_root_file_active_hold "hold	${ST}b	실행 중 줄기 s9 와 겹침"

fx tokens
item a validated P1 '`fr_relations.sh readiness` `<slug>` `--slugs`'
item b validated P2 '`fr_relations.sh readiness` `<slug>` `--slugs`'
pick pick_non_path_tokens --mode interactive
count pick_non_path_tokens stream 2; line pick_non_path_tokens "$(S 1 ${ST}a '')"

fx slugs
item a validated P1 '`a/1`'; item b validated P2 '`b/1`'
pick pick_slugs_filter --mode interactive --slugs "b"
line pick_slugs_filter "$(S 1 ${ST}b 'b/1')"; noline pick_slugs_filter "${ST}a"; rc0 pick_slugs_filter
pick pick_slugs_unresolved --mode interactive --slugs "nope"
[ "$RC" = 2 ] && P "pick_slugs_unresolved: rc 2" || F pick_slugs_unresolved "rc=$RC"

# --slugs 로 이름을 지정한 비활성 FR 은 사라지지 않고 skip 사유로 나옵니다.
fx nameddone
item a done -; item b validated P1
pick pick_named_done_skip --mode interactive --slugs "a b"
line pick_named_done_skip "skip	${ST}a	상태 done"; line pick_named_done_skip "$(S 1 ${ST}b '')"; rc0 pick_named_done_skip

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit "$fail"
