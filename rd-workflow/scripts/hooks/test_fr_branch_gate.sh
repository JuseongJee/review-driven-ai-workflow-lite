#!/bin/bash
# test_fr_branch_gate.sh — 커밋 판정 스캐너 단위(S) + fr_branch_gate 회귀(H) + 성능(S24)
# macOS /bin/bash 3.2 호환. fixture 패턴: test_pre_commit_archive_gate.sh 준용.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HOOK_DIR/.." && pwd)"
AWKF="$HOOK_DIR/_commit_scan.awk"
PROJ="$(cd "$HOOK_DIR/../../.." && pwd)"
PASS=0
FAIL=0

# ---------- 임시 경로 정리 (첫 mktemp 보다 앞에 등록해야 한다) ----------
# trap 등록이 어떤 mktemp 보다 뒤에 오면 그 경로는 신호 중단 시 누수된다.
# 실행 순서가 기준이므로 변수 선언만으로는 소유가 성립하지 않는다.
H_FIX=""
cleanup_h() { [[ -n "$H_FIX" && -d "$H_FIX" ]] && rm -rf "$H_FIX"; H_FIX=""; }
# trap 은 이 파일에서 **한 번만** 등록한다. S24 블록에서 다시 등록하면 이 정리가 덮여
# 임시 경로가 사용자 환경에 남는다(성능 테스트는 반복 실행된다).
#
# **모든 임시 root 를 여기서 빈 값으로 선언한다.** 개별 구간에서만 삭제하면 그 구간에
# INT/TERM 이 들어올 때 trap 이 그 경로를 몰라 누수된다. 정상 경로에서 삭제할 때도
# 변수를 비워 이중 삭제를 피한다.
H12_PARENT=""; H16_SIB=""; L_BASE=""
cleanup_all() {
  cleanup_h
  local d
  for d in "${FX_DIR:-}" "${OUT_DIR:-}" "${H12_PARENT:-}" "${H16_SIB:-}" "${L_BASE:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
  return 0
}
# EXIT 는 정리만, INT/TERM 은 정리 후 **신호 종료 의미를 보존**한다.
# 그냥 반환하면 장시간 성능 테스트가 중단되지 않고 계속 진행된다.
trap 'cleanup_all' EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

G='git'; C='commit'          # 이 스크립트 자신이 guard 에 걸리지 않도록 조립

# scan <cmd> [start_dir] -> "출력|rc"
# 스캐너 출력은 **여러 줄**이다(1행 요약 + 후보 경로 목록). 줄바꿈을 `|` 로 바꿔 한 문자열로
# 만들고 rc 를 뒤에 붙여 **전문 + rc 를 정확히** 비교한다. 부분 문자열 비교를 쓰면
# rc=2(판정 불가) 실패를 통과로 세는 사고가 난다(프로토타입 개발 중 실제 발생).
scan_probe() {
  local out rc
  out="$(printf '%s' "$1" | awk -v start_dir="${2:-$PROJ}" -f "$AWKF")"; rc=$?
  printf '%s|%s' "$(printf '%s' "$out" | tr '\n' '|')" "$rc"
}

check_scan() { # check_scan <id> <expect "gate=.. uncertain=.. ncand=..|<후보>|…|rc"> <cmd> [start_dir]
  local id="$1" want="$2" cmd="$3" sd="${4:-$PROJ}" got
  got="$(scan_probe "$cmd" "$sd")"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); printf 'FAIL %-5s\n  want %s\n  got  %s\n' "$id" "$want" "$got" >&2
  fi
}

P="$PROJ"
PARENT="$(dirname "$PROJ")"

# --- LITERAL/EXPANDING 구분과 기본 판정 ---
check_scan S1  "gate=1 uncertain=0 ncand=1|$P|0"          "$G $C -m x"
check_scan S2  "gate=0 uncertain=0 ncand=0|0"           "rd task capture --body '$G add -A; $G $C -m 메시지'"
check_scan S4  "gate=1 uncertain=0 ncand=1|$P|0"          "echo \"\$($G $C -m x)\""
check_scan S5  "gate=1 uncertain=0 ncand=1|/other|0"    "$G -C /other $C -m x"
check_scan S6  "gate=0 uncertain=0 ncand=0|0"          "RD_LIFECYCLE_BYPASS_REASON=lifecycle $G $C"
check_scan S7  "gate=1 uncertain=0 ncand=1|$P|0"          "echo RD_LIFECYCLE_BYPASS_REASON=x && $G $C"
check_scan S8  "gate=1 uncertain=0 ncand=1|/tmp/other|0" "cd /tmp/other && $G $C"
check_scan S9  "gate=1 uncertain=1 ncand=0|0"           "cd \$DIR && $G $C"
check_scan S10 "gate=1 uncertain=0 ncand=1|$P|0"          "( cd /tmp/o && ls ); $G $C"
check_scan S11 "gate=0 uncertain=0 ncand=0|0"           "$G ${C}ments --list"
check_scan S12 "gate=0 uncertain=0 ncand=0|0"           "bash -lc '$G $C'"
check_scan S15 "gate=0 uncertain=0 ncand=0|0"           "cat <<<'$G $C -m x'"
check_scan S16 "gate=1 uncertain=0 ncand=1|$P|0"          "cat <<<\"\$($G $C -m x)\""
check_scan S17 "gate=1 uncertain=0 ncand=1|$P|0"          "echo \`$G $C -m x\`"
check_scan S18 "gate=0 uncertain=0 ncand=0|0"           "# $G $C -m x"
check_scan S19 "gate=1 uncertain=1 ncand=0|0"           "cd /tmp/other ; $G $C"
check_scan S20 "gate=1 uncertain=1 ncand=0|0"           "cd /tmp/other || $G $C"
check_scan S21 "gate=1 uncertain=0 ncand=1|$PARENT/sibling|0" "cd ../sibling && $G $C"
check_scan S22 "gate=1 uncertain=0 ncand=1|$PARENT/sibling|0" "$G -C ../sibling $C"
check_scan S23 "gate=0 uncertain=0 ncand=0|2"           "$G $C -m \"unclosed"

# --- heredoc (델리미터 인용 여부로 LITERAL/EXPANDING 이 갈린다) ---
check_scan S3  "gate=0 uncertain=0 ncand=0|0"  "$(printf 'cat > f.md <<EOF\nRD_X=1 && %s %s -m y\nEOF\n' "$G" "$C")"
check_scan S13 "gate=0 uncertain=0 ncand=0|0"  "$(printf 'cat <<'"'"'EOF'"'"'\n$(%s %s -m x)\nEOF\n' "$G" "$C")"
check_scan S14 "gate=1 uncertain=0 ncand=1|$P|0" "$(printf 'cat <<EOF\n$(%s %s -m x)\nEOF\n' "$G" "$C")"

# --- 여러 위치 변경자의 합성 (git -C 는 argv 순서로 누적) ---
check_scan S25 "gate=1 uncertain=0 ncand=1|$P|0"              "cd /tmp/outside && $G -C $P $C"
check_scan S26 "gate=1 uncertain=0 ncand=1|$P|0"              "$G -C /tmp/outside -C ../..$P $C"
check_scan S27 "gate=1 uncertain=0 ncand=1|/tmp/outside|0"    "cd $P && $G -C /tmp/outside $C"
check_scan S28 "gate=1 uncertain=0 ncand=1|/tmp/a/b|0"        "$G -C /tmp/a -C b $C"

# --- 인용·이스케이프 결합 워드 (quote removal 후 직접 호출) ---
check_scan S29 "gate=1 uncertain=0 ncand=1|$P|0"           "'$G' $C -m x"
check_scan S30 "gate=1 uncertain=0 ncand=1|$P|0"           "g\"it\" $C -m x"
check_scan S31 "gate=1 uncertain=0 ncand=1|$P|0"           "$G '$C' -m x"
check_scan S32 "gate=1 uncertain=0 ncand=1|$P|0"           "$G com'mit' -m x"
check_scan S33 "gate=1 uncertain=0 ncand=1|$P|0"           "g\\it $C -m x"
check_scan S34 "gate=0 uncertain=0 ncand=0|0"            "'$G $C'"
check_scan S35 "gate=1 uncertain=0 ncand=1|/tmp/outside|0" "$G '-C' /tmp/outside $C"
check_scan S36 "gate=0 uncertain=0 ncand=0|0"            "\$CMD $C -m x"
check_scan S37 "gate=0 uncertain=0 ncand=0|0"           "RD_LIFECYCLE_BYPASS_REASON=lifecycle $G $C"
check_scan S38 "gate=0 uncertain=0 ncand=0|0"            "'RD_LIFECYCLE_BYPASS_REASON=lifecycle' $G $C"

# --- 백슬래시는 인용 문맥별로 의미가 다르다 (bash 3.2 실측 대조) ---
check_scan S39 "gate=0 uncertain=0 ncand=0|0"  "g\"\\i\"t $C -m x"
check_scan S40 "gate=0 uncertain=0 ncand=0|0"  "'g\\it' $C -m x"
check_scan S41 "gate=0 uncertain=0 ncand=0|0"  "$G \"com\\mit\" -m x"
check_scan S42 "gate=1 uncertain=0 ncand=1|$P|0" "g\\it $C -m x"
check_scan S43 "gate=1 uncertain=0 ncand=1|$P|0" "$G \"commit\" -m x"

# --- 개행은 서브커맨드 경계다 (현행 정규식은 이것을 미탐한다 — AC13) ---
check_scan S44 "gate=1 uncertain=0 ncand=1|$P|0" "cat > f.md <<'EOF'
내용 한 줄
EOF
$G $C -m x"

# --- 다중 커밋은 끝까지 집계한다 (첫 커밋만 보면 안전장치가 뚫린다 — AC14) ---
check_scan S45 "gate=1 uncertain=0 ncand=2|/other|$P|0"  "$G -C /other $C -m a; $G $C -m b"
check_scan S46 "gate=1 uncertain=0 ncand=1|$P|0"         "RD_LIFECYCLE_BYPASS_REASON=lifecycle $G $C -m a; $G $C -m b"
check_scan S47 "gate=0 uncertain=0 ncand=0|0"            "RD_LIFECYCLE_BYPASS_REASON=lifecycle $G $C -m a; RD_LIFECYCLE_BYPASS_REASON=legacy $G $C -m b"

# --- repo 대상을 바꾸는 옵션·환경은 fail-closed (AC15) ---
check_scan S48 "gate=1 uncertain=1 ncand=0|0"            "cd /other && GIT_DIR=/x/.git $G $C -m x"
check_scan S49 "gate=1 uncertain=1 ncand=0|0"            "$G --git-dir /x/.git $C -m x"
check_scan S50 "gate=1 uncertain=1 ncand=0|0"            "export GIT_DIR=/x/.git; cd /other && $G $C -m x"

# --- heredoc 종료는 bash 의미와 일치해야 한다 (AC16) ---
# <<EOF 는 줄 전문 정확 일치. 선행 공백이 있는 " EOF" 는 종료가 아니므로 이후도 데이터다.
check_scan S51 "gate=0 uncertain=0 ncand=0|0" "cat > f.md <<'EOF'
 EOF
$G $C -m x
EOF"
# <<-EOF 는 선행 탭만 제거 후 일치 -> 종료되고 다음 줄의 커밋은 실행 위치다.
check_scan S52 "gate=1 uncertain=0 ncand=1|$P|0" "cat > f.md <<-EOF
내용
	EOF
$G $C -m x"

# --- 명령 치환 안의 cd 는 subshell 이므로 바깥에 영향이 없다 (AC18) ---
check_scan S53 "gate=1 uncertain=0 ncand=2|/other|$P|0"  "echo \"\$(cd /other && $G $C -m a)\"; $G $C -m b"

# --- 복수 heredoc 은 pending 을 덮어쓰므로 폴백으로 보낸다 (AC19) ---
check_scan S54 "gate=0 uncertain=0 ncand=0|2" "cat <<EOF <<'Q' >/dev/null
\$($G $C -m x)
EOF
second
Q"

# --- backslash-newline 은 line continuation 이므로 워드가 이어진다 (AC20) ---
check_scan S55 "gate=1 uncertain=0 ncand=1|$P|0" "$G com\\
${C:3} -m x"

# --- repo override 불확실은 절대 -C 로 해소되지 않는다 (AC21) ---
# `export GIT_DIR` 는 이후 커밋의 실행 repo 를 바꾸므로, 절대 -C 가 cwd 를 확정해도
# 위치를 확정하면 안 된다. 확정하면 외부 생략으로 빠져 실제 프로젝트 커밋이 통과한다.
check_scan S56 "gate=1 uncertain=1 ncand=0|0" "export GIT_DIR=/x/.git; $G -C /tmp $C -m x"
# subshell 안의 export 는 바깥 커밋에 영향이 없다 -> 확정 유지
check_scan S57 "gate=1 uncertain=0 ncand=1|$P|0" "( export GIT_DIR=/x/.git ); $G $C -m x"

# --- ANSI-C 인용은 정적 lexical 이므로 직접 호출이다 (AC22) ---
check_scan S58 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'$C' -m x"
check_scan S59 "gate=1 uncertain=0 ncand=1|$P|0" "g\$'it' $C -m x"
# 내부 escape 도 정적 변환이므로 복원한다 (8진 155 = 'm'). rc=2 폴백으로 보내면
# 1단 필터와 legacy 글롭이 모두 통과시켜 hook 종단에서 차단이 뚫린다(Turn 004 실측).
check_scan S60 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'com\\155it' -m x"

# --- 셸 예약어·실행 prefix·선행 redirection 뒤의 커밋도 실제 커밋이다 (AC23) ---
check_scan S61 "gate=1 uncertain=0 ncand=1|$P|0" "command $G $C -m x"
check_scan S62 "gate=1 uncertain=0 ncand=1|$P|0" "exec $G $C -m x"
check_scan S63 "gate=1 uncertain=0 ncand=1|$P|0" "env -i $G $C -m x"
check_scan S64 "gate=1 uncertain=0 ncand=1|$P|0" "if $G $C -m x; then :; fi"
check_scan S65 "gate=1 uncertain=0 ncand=1|$P|0" ">/tmp/rdlog $G $C -m x"
check_scan S66 "gate=1 uncertain=0 ncand=1|$P|0" "2> /tmp/rderr $G $C -m x"
# `command -v` 는 조회일 뿐 실행이 아니다 -> 커밋 아님 (과탐 방지)
check_scan S67 "gate=0 uncertain=0 ncand=0|0" "command -v $G $C"

# --- backslash 로 인용한 heredoc 델리미터는 LITERAL 이다 (AC24) ---
# `cat <<\EOF` 는 `<<'EOF'` 와 같다. 델리미터에 백슬래시를 남기면 종료를 못 찾아
# rc=2 로 떨어지고, 폴백의 legacy 글롭이 body 를 오탐해 오탐 해소가 깨진다.
check_scan S68 "gate=0 uncertain=0 ncand=0|0" "$(printf 'cat <<\\EOF\n%s %s -m x\nEOF\n' "$G" "$C")"

# --- final diff review Turn 004 회귀 (AC21~AC24 보강) ---
# ANSI-C escape 복원: \x6d = 'm'
check_scan S69 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'com\\x6dit' -m x"
# bare export + 독립 대입으로 나눠도 repo override 는 지속된다
check_scan S70 "gate=1 uncertain=1 ncand=0|0" "export GIT_DIR; GIT_DIR=/x/.git; $G -C /tmp $C -m x"
# env -C 는 cd 와 같은 실행 위치 변경자다 (macOS env 도 지원)
check_scan S71 "gate=1 uncertain=0 ncand=1|/tmp|0"  "env -C /tmp $G $C -m x"
check_scan S72 "gate=1 uncertain=0 ncand=1|$P|0"    "cd /tmp && env -C $P $G $C -m x"
check_scan S73 "gate=1 uncertain=0 ncand=1|/tmp|0"  "env --chdir=/tmp $G $C -m x"
check_scan S74 "gate=1 uncertain=1 ncand=0|0"       "env -C \$VAR $G $C -m x"
# builtin 은 외부 명령을 실행하지 않으므로 커밋이 아니다 (과탐 방지)
check_scan S75 "gate=0 uncertain=0 ncand=0|0" "builtin $G $C -m x"
# 델리미터의 인용 문맥: 홑따옴표 안 백슬래시는 리터럴, $'…' 는 ANSI-C
check_scan S76 "gate=0 uncertain=0 ncand=0|0" "$(printf "cat <<'E\\\\OF'\n%s %s -m x\nE\\\\OF\n" "$G" "$C")"
check_scan S77 "gate=0 uncertain=0 ncand=0|0" "$(printf "cat <<\$'EOF'\n%s %s -m x\nEOF\n" "$G" "$C")"
# 빈 델리미터(<<'')는 빈 줄로 닫힌다 — pending 없음과 구분되어야 body 가 데이터로 남는다
check_scan S78 "gate=1 uncertain=0 ncand=1|$P|0" "$(printf "cat <<''\n%s %s -m data\n\n%s %s -m real\n" "$G" "$C" "$G" "$C")"
check_scan S79 "gate=0 uncertain=0 ncand=0|0"    "$(printf "cat <<''\n%s %s -m data\n\necho done\n" "$G" "$C")"

# --- final diff review Turn 006 회귀 (AC22~AC25) ---
# env 식별은 quote removal + basename 기준이다
check_scan S80 "gate=1 uncertain=0 ncand=1|$P|0" "/usr/bin/env -C $P $G $C -m x"
check_scan S81 "gate=1 uncertain=0 ncand=1|$P|0" "e\"nv\" -C $P $G $C -m x"
# macOS env 의 인자 소비 옵션: -P utilpath, -S string, 붙임형 -C<dir>
check_scan S82 "gate=1 uncertain=0 ncand=1|$P|0" "env -P /usr/bin $G $C -m x"
check_scan S83 "gate=1 uncertain=0 ncand=1|$P|0" "env -S \"$G $C -m x\""
check_scan S84 "gate=0 uncertain=0 ncand=0|0"    "env -S \"echo hi\""
check_scan S85 "gate=1 uncertain=0 ncand=1|$P|0" "cd /tmp && env -C$P $G $C -m x"
# wrapper 별 옵션 소비: /usr/bin/time -a 는 인자 없음, -o file 은 소비, exec -a name 은 소비
check_scan S86 "gate=1 uncertain=0 ncand=1|$P|0" "/usr/bin/time -a $G $C -m x"
check_scan S87 "gate=1 uncertain=0 ncand=1|$P|0" "/usr/bin/time -o /dev/null $G $C -m x"
check_scan S88 "gate=1 uncertain=0 ncand=1|$P|0" "exec -a nm $G $C -m x"
# 알려지지 않은 ANSI-C escape 는 백슬래시를 보존한다 -> com\mit 은 git 서브커맨드가 아니다
check_scan S89 "gate=0 uncertain=0 ncand=0|0" "$G \$'com\\mit' -m x"
# 종료 델리미터 없이 EOF 로 끝난 heredoc 은 bash 에서 정상이다 (body 는 데이터)
check_scan S90 "gate=0 uncertain=0 ncand=0|0" "$(printf "cat <<'EOF'\n%s %s -m x" "$G" "$C")"
check_scan S91 "gate=1 uncertain=0 ncand=1|$P|0" "$(printf 'cat <<EOF\n$(%s %s -m x)' "$G" "$C")"

# --- final diff review Turn 008 회귀 (AC22·AC23 보강) ---
# 셸은 옵션의 따옴표도 제거한다 -> 옵션 판정도 quote removal 기준이어야 한다
check_scan S92 "gate=1 uncertain=0 ncand=1|$P|0" "env '-C' $P $G $C -m x"
check_scan S93 "gate=1 uncertain=0 ncand=1|$P|0" "env '-P' /usr/bin $G $C -m x"
check_scan S94 "gate=1 uncertain=0 ncand=1|$P|0" "/usr/bin/time '-a' $G $C -m x"
check_scan S95 "gate=1 uncertain=0 ncand=1|$P|0" "exec '-a' nm $G $C -m x"
# env -S 는 split 결과 뒤에 원래 argv 가 이어진다 -> 토큰이 나뉘어도 실제 커밋이다
check_scan S96 "gate=1 uncertain=0 ncand=1|$P|0" "env -S '$G' $C -m x"
# command 의 조회 옵션은 묶음으로도 온다 (`-pv`)
check_scan S97 "gate=0 uncertain=0 ncand=0|0"    "command -pv $G $C"
check_scan S98 "gate=1 uncertain=0 ncand=1|$P|0" "command -p $G $C -m x"
# \cX 는 하위 5비트다: $'"'"'\c['"'"' = ESC(27). 델리미터를 다르게 기억하면 종료를 놓쳐
# 이후의 실제 커밋까지 LITERAL body 로 삼킨다.
ESC_CH="$(printf '\033')"
check_scan S99 "gate=1 uncertain=0 ncand=1|$P|0" "$(printf "cat <<\$'\\c['\n%s %s -m data\n%s\n%s %s -m real\n" "$G" "$C" "$ESC_CH" "$G" "$C")"

# --- final diff review Turn 010 회귀 ---
# 표현 불가 표식을 값에 실으면 같은 값의 정상 문자와 구분되지 않는다: Ctrl-B(\002)가 그 예다.
# 델리미터가 Ctrl-B 로 확정돼야 그 줄에서 heredoc 이 닫히고 이후 커밋이 실행 위치가 된다.
CTRLB_CH="$(printf '\002')"
check_scan S100 "gate=1 uncertain=0 ncand=1|$P|0" "$(printf "cat <<\$'\\cB'\n%s %s -m data\n%s\n%s %s -m real\n" "$G" "$C" "$CTRLB_CH" "$G" "$C")"
check_scan S101 "gate=1 uncertain=0 ncand=1|$P|0" "$(printf "cat <<\$'\\x02'\n%s %s -m data\n%s\n%s %s -m real\n" "$G" "$C" "$CTRLB_CH" "$G" "$C")"
# short option cluster 안의 인자 소비 옵션도 정확히 소비해야 한다
check_scan S102 "gate=1 uncertain=0 ncand=1|$P|0" "env -iC $P $G $C -m x"
check_scan S103 "gate=1 uncertain=0 ncand=1|$P|0" "exec -ca label $G $C -m x"
check_scan S104 "gate=1 uncertain=0 ncand=1|$P|0" "/usr/bin/time -ao /dev/null $G $C -m x"
# env -S 의 `\_` 는 인자 구분 공백이다
check_scan S105 "gate=1 uncertain=0 ncand=1|$P|0" "env -S '$G\\_$C -m x'"
# 정확히 분해할 수 없는 -S 문자열은 보수 판정한다 (커밋 후보)
check_scan S106 "gate=1 uncertain=0 ncand=1|$P|0" "env -S '\$VAR $C -m x'"
# 미지원 옵션은 wrapper 가 오류로 끝나 utility 를 실행하지 않는다 -> 커밋 아님
check_scan S107 "gate=0 uncertain=0 ncand=0|0" "command -x $G $C -m x"
check_scan S108 "gate=0 uncertain=0 ncand=0|0" "env -Z $G $C -m x"
check_scan S109 "gate=0 uncertain=0 ncand=0|0" "/usr/bin/time -Z $G $C -m x"

# --- final diff review Turn 012 회귀 ---
# NUL 은 표현 불가가 아니라 truncation 이다: $'commit\0ignored' 의 argv 는 commit 이다.
check_scan S110 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'$C\\0ignored' -m x"
check_scan S111 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'com\\0x'${C:3} -m x"
check_scan S112 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'$C\\x00ig' -m x"
check_scan S113 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'$C\\c@ig' -m x"
# env -S 의 선행·연속·후행 구분자는 빈 인자를 만들지 않는다
check_scan S114 "gate=1 uncertain=0 ncand=1|$P|0" "env -S \" $G $C -m x\""
check_scan S115 "gate=1 uncertain=0 ncand=1|$P|0" "env -S \"\\_$G $C -m x\""
check_scan S116 "gate=1 uncertain=0 ncand=1|$P|0" "env -S \"$G  $C -m x\""
check_scan S117 "gate=1 uncertain=0 ncand=1|$P|0" "env -S \"$G $C -m x \""
# env -S 의 인용 안에서는 구분자가 아니다 -> printf 는 문자열을 출력할 뿐 커밋이 아니다
check_scan S118 "gate=0 uncertain=0 ncand=0|0" "env -S 'printf \"$G $C\"'"
# 실행 주체 구분: nohup 은 옵션이 없고, 슬래시 없는 time 은 셸 예약어(-p 만)다
check_scan S119 "gate=0 uncertain=0 ncand=0|0"    "nohup -x $G $C -m x"
check_scan S120 "gate=1 uncertain=0 ncand=1|$P|0" "nohup $G $C -m x"
check_scan S121 "gate=0 uncertain=0 ncand=0|0"    "time -a $G $C -m x"
check_scan S122 "gate=1 uncertain=0 ncand=1|$P|0" "time -p $G $C -m x"
check_scan S123 "gate=1 uncertain=0 ncand=1|$P|0" "/usr/bin/time -a $G $C -m x"

# --- final diff review Turn 014 회귀 ---
# octal 은 8-bit 로 정규화한 뒤 NUL 을 판정해야 한다: \400 은 byte 로 NUL 이다.
check_scan S124 "gate=1 uncertain=0 ncand=1|$P|0" "$G \$'$C\\400ignored' -m x"
check_scan S125 "gate=1 uncertain=0 ncand=1|$P|0" "$(printf "cat <<\$'EOF\\\\400ig'\n%s %s -m data\nEOF\n%s %s -m real\n" "$G" "$C" "$G" "$C")"
# env -S 의 \c 는 조립 중인 워드를 보존하고, # 는 새 워드 위치의 주석이다(원래 argv 는 이어진다)
check_scan S126 "gate=1 uncertain=0 ncand=1|$P|0" "env -S '$G $C\\cignored'"
check_scan S127 "gate=1 uncertain=0 ncand=1|$P|0" "env -S '$G # ig' $C -m x"
# 셸 parse context 를 떠난 뒤의 time 은 외부 utility 다
check_scan S128 "gate=1 uncertain=0 ncand=1|$P|0" "env time -a $G $C -m x"
check_scan S129 "gate=1 uncertain=0 ncand=1|$P|0" "exec time -a $G $C -m x"
check_scan S130 "gate=1 uncertain=0 ncand=1|$P|0" "nohup time -a $G $C -m x"
check_scan S131 "gate=1 uncertain=0 ncand=1|$P|0" "env -S 'time -a $G $C -m x'"
# 확장이 섞여도 그 앞에서 명령명이 확정되면 그것으로 판정한다 (실행되지 않는 커밋을 막지 않는다)
check_scan S132 "gate=0 uncertain=0 ncand=0|0" "env -S 'printf \"\${HOME} $G $C\"'"
# macOS env 가 모르는 escape 는 utility 실행 전에 종료된다 -> 커밋 아님
check_scan S133 "gate=0 uncertain=0 ncand=0|0" "env -S '$G com\\mit'"

# ---------- L: bash 계약 계층 (fail-closed 해석) ----------
# S 케이스는 awk 를 직접 호출하므로 scan_command_commit 의 형식 검증을 거치지 않는다.
# malformed stdout·awk 비정상 종료·후보 수 불일치가 실제로 rc=2 / 판정 유지가 되는지
# 여기서 고정한다. 이것이 없으면 §2.2.1 의 실패 계약이 반복 검증되지 않는다.
# _guard_common.sh 는 ../_state_common.sh 를 source 하므로 hooks/ 계층을 흉내낸다.
L_BASE="$(mktemp -d)"; L_TMP="$L_BASE/hooks"; mkdir -p "$L_TMP"   # cleanup_all 소유
cp "$SCRIPTS_DIR/_state_common.sh" "$L_BASE/"
lchk() { # lchk <id> <기대 rc> <awk 프로그램 내용>
  local id="$1" want="$2" prog="$3" rc
  # _commit_scan_awk() 는 **_guard_common.sh 와 같은 디렉토리**의 awk 를 찾는다.
  # 따라서 조작된 스캐너를 쓰려면 _guard_common.sh 도 함께 그 디렉토리에 두고
  # 그쪽을 source 해야 한다 (HOOK_DIR 쪽을 source 하면 정상 스캐너가 쓰인다).
  printf '%s\n' "$prog" > "$L_TMP/_commit_scan.awk"
  cp "$HOOK_DIR/_guard_common.sh" "$L_TMP/"
  ( cd "$L_TMP" && project_root="$L_TMP" && source "$L_TMP/_guard_common.sh" \
      && scan_command_commit "$G $C -m x" >/dev/null 2>&1 ); rc=$?
  if [[ "$rc" == "$want" ]]; then PASS=$((PASS+1)); printf 'ok   %-5s rc=%s\n' "$id" "$rc"
  else FAIL=$((FAIL+1)); printf 'FAIL %-5s rc=%s (기대 %s)\n' "$id" "$rc" "$want" >&2; fi
}
# L1: 1행 형식이 깨진 출력 -> rc=2 (판정 성공으로 오인하면 안 된다)
lchk L1 2 'BEGIN { print "commit=1 bypass=0 target=/x"; exit 0 }'
# L2: 1행은 맞지만 필드값이 계약 밖 -> rc=2
lchk L2 2 'BEGIN { print "gate=2 uncertain=0 ncand=0"; exit 0 }'
# L3: awk 가 비정상 종료 -> rc=2
lchk L3 2 'BEGIN { print "gate=1 uncertain=0 ncand=1"; print "/x"; exit 3 }'
# L4: 정상 계약 -> rc=0
lchk L4 0 'BEGIN { print "gate=1 uncertain=0 ncand=1"; print "'"$PROJ"'" }'
# L5: ncand 와 후보 줄 수가 어긋나면 _gate_from_scan 이 생략하지 않는다 (fail-closed)
out5="$(printf 'gate=1 uncertain=0 ncand=2\n/tmp\n')"
if ( project_root="$PROJ"; source "$HOOK_DIR/_guard_common.sh"; _gate_from_scan "$out5" test >/dev/null 2>&1 ); then
  PASS=$((PASS+1)); printf 'ok   L5    판정 유지 (후보 수 불일치)\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL L5    후보 수 불일치인데 생략했습니다\n' >&2
fi
rm -rf "$L_BASE"; L_BASE=""

# --- S24: 성능 (축 1 = 스캐너 bundle 평균·max, 축 2 = 단일 스캔 CPU 선형성) ---
# 보장 대상은 "이 변경이 추가한 계산의 비용" 이다. gate wrapper(bash 기동·source·JSON 파싱)·
# 각 gate 후속 로직·pre_commit_verify·Claude dispatch 는 관측 단위 밖이며, 따라서
# 사용자가 실제로 기다리는 전체 시간은 보장하지 않는다 (spec §2.4 「범위를 좁힌 근거」).
FX_DIR="$(mktemp -d)"   # 정리는 상단 cleanup_all 이 담당한다 (trap 재등록 금지)
REPS=20
GATES=3   # 스캐너를 호출하는 PreToolUse gate 수. settings.json 등록이 바뀌면 갱신한다.

mk_fixture() { # mk_fixture <목표바이트> <경로>
  local target="$1" path="$2" unit
  unit="재현: RD_X=1 && $G $C -m 메시지 로 차단됨. 경계 문자 포함 산문."
  printf 'cat > f.md <<EOF\n' > "$path"
  while [[ $(wc -c < "$path") -lt $target ]]; do printf '%s\n' "$unit" >> "$path"; done
  printf 'EOF\n' >> "$path"
}

# 축 1 — 한 표본에서 평균과 회별 max 를 함께 낸다.
#   평균만 두면 한 번의 긴 stall 을 흡수한다(10ms × 19 + 2,000ms × 1 → 평균 109.5ms 통과).
#   max 만 두면 상시 지연을 놓친다. 같은 표본에서 내야 두 값이 비교 가능하다.
#   gate 3종은 병렬 실행되므로 동시에 띄우고 마지막이 끝날 때까지를 1 bundle 로 본다.
bundle_stats() { # bundle_stats <fixture 경로|empty>  ->  "<평균> <최대>"
  local f="$1" i out vals=""
  TIMEFORMAT='%3R'
  for ((i=0;i<REPS;i++)); do
    if [[ "$f" == "empty" ]]; then
      out=$( { time ( awk 'BEGIN{}' >/dev/null ) ; } 2>&1 )
    else
      out=$( { time ( for ((g=0;g<GATES;g++)); do
                        awk -v start_dir="$PROJ" -f "$AWKF" < "$f" >/dev/null &
                      done; wait ) ; } 2>&1 )
    fi
    vals+="$out"$'\n'
  done
  printf '%s' "$vals" | awk '{ s+=$1; if ($1>m) m=$1; n++ }
                             END { printf "%.1f %.1f", s*1000/n, m*1000 }'
}

# 축 2 — 계산량은 병렬 경합이 섞이지 않는 단일 스캔 CPU 로 잰다. 10KB 는 이 축 전용이다.
measure_cpu_ms() { # measure_cpu_ms <fixture 경로>
  local out u s
  TIMEFORMAT='%3U %3S'
  out=$( { time awk -v start_dir="$PROJ" -f "$AWKF" < "$1" >/dev/null ; } 2>&1 )
  u="${out%% *}"; s="${out##* }"
  awk -v a="$u" -v b="$s" 'BEGIN { printf "%.1f", (a+b)*1000 }'
}

median_cpu_ms() { # median_cpu_ms <fixture 경로> [반복]
  local f="$1" reps="${2:-7}" i vals=""
  measure_cpu_ms "$f" >/dev/null              # 워밍업 1회 버림
  for ((i=0;i<reps;i++)); do vals+="$(measure_cpu_ms "$f")"$'\n'; done
  printf '%s' "$vals" | sort -n | awk '{a[NR]=$1} END { print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2) }'
}

# 실패 진단 — 축·fixture·관측값·상한·empty·시도 번호를 모두 노출한다 (AC10b).
# 성능 검사는 사용자가 직접 보지 않는 배경 검증이므로 메시지만으로 원인 판단이 되어야 한다.
perf_fail() { # perf_fail <id> <지표이름> <fixture> <관측값> <상한> [부가설명]
  FAIL=$((FAIL+1))
  printf 'FAIL %s [%s] fixture=%s 관측=%s 상한=%s | empty=%sms(임계 20ms) 환경검사시도=%s/3\n' \
    "$1" "$2" "$3" "$4" "$5" "$E" "$ENV_ATTEMPT" >&2
  [[ -n "${6:-}" ]] && printf '  %s\n' "$6" >&2
  return 0
}

mk_fixture 1024  "$FX_DIR/fx1k"
mk_fixture 10000 "$FX_DIR/fx10k"
mk_fixture 20000 "$FX_DIR/fx20k"
awk -v start_dir="$PROJ" -f "$AWKF" < "$FX_DIR/fx20k" >/dev/null   # 워밍업

# 환경 이상이면 묶음을 버리고 다시 잰다. 총 3회 시도(최초 1 + 재측정 2).
# 소진 시 skip 이 아니라 FAIL 이다 — 항상 시끄러운 기기에서 성능 검사가 영구 무효화되는 것을 막는다.
W_OK=0; ENV_ATTEMPT=0
for attempt in 1 2 3; do
  ENV_ATTEMPT="$attempt"
  read -r E  _EM <<< "$(bundle_stats empty)"
  read -r A1 M1  <<< "$(bundle_stats "$FX_DIR/fx1k")"     # 같은 표본에서 평균·max
  read -r A20 M20 <<< "$(bundle_stats "$FX_DIR/fx20k")"
  if awk -v v="$E" 'BEGIN { exit !(v <= 20) }'; then W_OK=1; break; fi
  printf 'S24 환경 이상 — awk 빈 기동 평균 %sms > 20ms. 묶음 폐기 후 재측정 (시도 %d/3)\n' "$E" "$attempt" >&2
done

printf 'S24 참고: empty=%sms | 스캐너 bundle 1KB 평균/최대=%s/%sms 20KB=%s/%sms\n' \
  "$E" "$A1" "$M1" "$A20" "$M20"

if [[ $W_OK -eq 0 ]]; then
  FAIL=$((FAIL+1))
  printf 'FAIL S24-env [환경 검사] 3회 시도 모두 불안정 (awk 빈 기동 %sms > 20ms, 시도 3/3).\n' "$E" >&2
  printf '  이는 구현 결함이 아니라 환경 요인입니다 — 다른 부하를 줄이고 다시 실행하십시오.\n' >&2
else
  STALL='같은 fixture 반복이므로 작업량은 동일합니다 — OS 스케줄링 요인일 수 있으니 부하를 줄여 재실행해 재현되는지 확인하십시오.'
  awk -v v="$A1"  'BEGIN { exit !(v <= 150) }' && PASS=$((PASS+1)) || \
    perf_fail S24a "bundle 평균" 1KB  "${A1}ms"  "150ms" "§2.4 의 과호출 함정 5종을 확인하십시오."
  awk -v v="$A20" 'BEGIN { exit !(v <= 500) }' && PASS=$((PASS+1)) || \
    perf_fail S24b "bundle 평균" 20KB "${A20}ms" "500ms" "입력 크기에 따른 비용 증가를 확인하십시오."
  awk -v v="$M1"  'BEGIN { exit !(v <= 150) }' && PASS=$((PASS+1)) || \
    perf_fail S24d "bundle max"  1KB  "${M1}ms"  "150ms" "$STALL"
  awk -v v="$M20" 'BEGIN { exit !(v <= 500) }' && PASS=$((PASS+1)) || \
    perf_fail S24e "bundle max"  20KB "${M20}ms" "500ms" "$STALL"
fi

T10="$(median_cpu_ms "$FX_DIR/fx10k")"
T20="$(median_cpu_ms "$FX_DIR/fx20k")"
printf 'S24 참고: 단일 스캔 cpu median 10KB=%sms 20KB=%sms\n' "$T10" "$T20"
if awk -v a="$T10" -v b="$T20" 'BEGIN { exit !(a > 0 && b/a < 3.0) }'; then PASS=$((PASS+1)); else
  RATIO="$(awk -v a="$T10" -v b="$T20" 'BEGIN { printf "%.2f", b/a }')"
  perf_fail S24c "선형성" "20KB/10KB" "$RATIO" "3.00(비율)" "O(n)≈2.0 / O(n²)≈4.0 입니다. §2.4 의 과호출 함정 5종을 확인하십시오."
fi

# ---------- H: fr_branch_gate hook 회귀 ----------
# hook 은 script_dir/../../.. 를 project_root 로 계산하므로
# fixture/rd-workflow/scripts/hooks/ 에 hook 과 의존 파일을 배치한다.
# 임시 경로 정리는 **파일 최상단**에서 등록한다 (Task 1 Step 3 참조).
# 여기서 등록하면 그보다 먼저 실행되는 L 계약 계층의 L_BASE 가 trap 소유 밖에 놓인다.

make_h_fixture() { # make_h_fixture <브랜치명>
  local branch="$1" fx
  fx="$(mktemp -d)"
  mkdir -p "$fx/rd-workflow/scripts/hooks"
  cp "$HOOK_DIR/fr_branch_gate.sh"  "$fx/rd-workflow/scripts/hooks/"
  cp "$HOOK_DIR/_guard_common.sh"   "$fx/rd-workflow/scripts/hooks/"
  # _guard_common.sh 는 상위의 _state_common.sh 를 source 한다. 빠뜨리면 hook 이
  # 그 지점에서 죽어(exit 1) 전 H 케이스가 무의미해진다 (조립 검증에서 실제 검출).
  cp "$SCRIPTS_DIR/_state_common.sh" "$fx/rd-workflow/scripts/"
  # 스캐너를 반드시 함께 복사한다. 누락하면 hook 이 폴백 경로로 동작해
  # 새 판정을 전혀 검사하지 못한 채 테스트가 통과한다 (거짓 통과).
  # 2번째 인자가 "no-awk" 면 의도적으로 빼서 scanner-unavailable 폴백을 주입한다.
  # (awk 를 PATH 에서 지우는 방식은 dirname 등 hook 기동 필수 명령까지 깨져
  #  폴백이 아니라 PATH 파손으로 실패한다 — 실측 확인.)
  if [[ "${2:-}" != "no-awk" ]]; then
    [[ -f "$HOOK_DIR/_commit_scan.awk" ]] && cp "$HOOK_DIR/_commit_scan.awk" "$fx/rd-workflow/scripts/hooks/"
  fi
  git -C "$fx" init -q
  git -C "$fx" config user.email t@t
  git -C "$fx" config user.name t
  # **초기 커밋이 반드시 필요하다.** unborn branch 에서는 hook 의
  # `git rev-parse --abbrev-ref HEAD` 가 실패해 CURRENT_BRANCH 가 빈 문자열이 되고,
  # legacy branch 통과 경로로 빠져 H2·H4 가 exit 2 가 될 수 없다.
  git -C "$fx" commit -q --allow-empty -m init
  git -C "$fx" branch -M "$branch"
  # 하네스 자체가 브랜치를 단언한다 — fixture 가 조용히 틀리면 전 케이스가 무의미해진다.
  local got
  got="$(git -C "$fx" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [[ "$got" != "$branch" ]]; then
    printf 'FATAL: fixture 브랜치가 [%s] 입니다 (기대 [%s]).\n' "$got" "$branch" >&2
    exit 1
  fi
  printf '%s\n' "$fx"
}

run_hook() { # run_hook <브랜치> <cmd> [no-awk] ; stdout=hook stderr, 반환=exit code
  local branch="$1" cmd="$2" noawk="${3:-}" out rc
  cleanup_h
  H_FIX="$(make_h_fixture "$branch" "$noawk")"
  out=$( cd "$H_FIX" && printf '{"tool_input":{"command":%s}}' "$(json_str "$cmd")" \
         | bash "$H_FIX/rd-workflow/scripts/hooks/fr_branch_gate.sh" 2>&1 )
  rc=$?
  printf '%s' "$out"
  return $rc
}

# hook 입력은 JSON 이므로 문자열을 안전하게 인용한다 (역슬래시·겹따옴표·개행).
json_str() {
  # awk -v 는 값에 개행이 있으면 "newline in string" 으로 실패한다(실측). heredoc 케이스가
  # 전부 무효가 되므로 stdin 으로 넘겨 줄 단위로 조립한다.
  # **제어문자는 `\uXXXX` 로 이스케이프한다** — JSON 은 raw 제어문자를 허용하지 않으므로
  # 그대로 넣으면 jq 파싱이 실패해 hook 이 빈 command 를 받고 조용히 통과한다(실측).
  # 실제 Claude Code 도 같은 형태로 넘기므로 이 인코딩이 실환경과 일치한다.
  printf '"%s"' "$(printf '%s' "$1" | awk 'BEGIN{ ORS=""; for (i = 1; i < 32; i++) CTL[sprintf("%c", i)] = sprintf("\\u%04x", i) } {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\"")
    out = ""
    for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); out = out ((c in CTL) ? CTL[c] : c) }
    if (NR>1) printf "\\n"; printf "%s", out }')"
}

check_hook() { # check_hook <id> <기대 exit> <브랜치> <cmd> [기대 메시지 부분문자열]
  local id="$1" want="$2" branch="$3" cmd="$4" want_msg="${5:-}" out rc
  out="$(run_hook "$branch" "$cmd")"; rc=$?
  if [[ "$rc" != "$want" ]]; then
    FAIL=$((FAIL+1)); printf 'FAIL %s exit=%s (기대 %s)\n  cmd: %s\n  out: %s\n' \
      "$id" "$rc" "$want" "$cmd" "$out" >&2; return
  fi
  if [[ -n "$want_msg" && "$out" != *"$want_msg"* ]]; then
    FAIL=$((FAIL+1)); printf 'FAIL %s 메시지에 %s 없음\n  out: %s\n' "$id" "$want_msg" "$out" >&2; return
  fi
  PASS=$((PASS+1))
}
check_hook H2 2 main "$G $C -m x"                                    "면제 reason"
check_hook H3 0 main "RD_LIFECYCLE_BYPASS_REASON=lifecycle $G $C -m x"
check_hook H4 2 main "echo RD_LIFECYCLE_BYPASS_REASON=x && $G $C -m x"
check_hook H5 0 fr/demo "$G $C -m x"
# 프로젝트 밖 실재 경로 / 프로젝트 안 경로 준비
OUT_DIR="$(mktemp -d)"          # 프로젝트 밖 실재 디렉토리
NOPE="/tmp/rd-nonexistent-$$"   # 실재하지 않는 경로

# H1: 데이터 구간의 커밋 문자열 — 오탐 해소 (현행은 exit 2)
check_hook H1 0 main "cat > f.md <<'EOF'
$G $C -m x 로 차단됨
EOF"

# H6~H12: 대상 디렉토리 추적
check_hook H6  0 main "cd $OUT_DIR && $G $C -m x"   "판정 생략"
check_hook H7  2 main 'cd $VAR && '"$G $C"' -m x'   "확정할 수 없어"
check_hook H8  2 main "$G -C . $C -m x"
check_hook H9  0 main "$G -C $OUT_DIR $C -m x"      "판정 생략"
check_hook H10 2 main "cd $OUT_DIR ; $G $C -m x"
check_hook H11 2 main "cd $NOPE && $G $C -m x"
# H12 는 Step 3 에서 symlink 를 만들어 검사한다 (fixture 경로가 런타임에 정해짐).

# H15~H17: 여러 위치 변경자 합성
check_hook H15 2 main "cd $OUT_DIR && $G -C \$PWD_PROJECT $C -m x"   # Step 3 에서 실경로로 교체
# H16 은 Step 3 의 전용 검사로 옮겼다 — `-C .` 은 직전 기준($OUT_DIR)에 합성되므로
# 대상이 계속 외부이고, exit 2 를 기대하면 잘못된 합성을 통과시킨다.
check_hook H17 0 main "cd . && $G -C $OUT_DIR $C -m x"               "판정 생략"

# H23: heredoc 종료 후 개행 뒤 실제 커밋 — 현행은 미탐(통과), 스캐너는 차단 (AC13)
check_hook H23 2 main "cat > f.md <<'EOF'
내용 한 줄
EOF
$G $C -m x"

# H18~H22: 인용·이스케이프 결합
check_hook H18 2 main "'$G' $C -m x"
check_hook H19 2 main "$G ${C:0:3}'${C:3}' -m x"
check_hook H20 0 main "'$G $C' -m x"
check_hook H21 0 main "g\"\\i\"t $C -m x"
check_hook H22 2 main "g\\it $C -m x"

# --- 다중 커밋은 끝까지 집계 (AC14) ---
check_hook H25 2 main "$G -C $OUT_DIR $C -m a; $G $C -m b"
check_hook H26 2 main "RD_LIFECYCLE_BYPASS_REASON=lifecycle $G $C -m a; $G $C -m b"
check_hook H27 0 main "$G -C $OUT_DIR $C -m a; $G -C $OUT_DIR $C -m b" "판정 생략"
check_hook H28 0 main "RD_LIFECYCLE_BYPASS_REASON=lifecycle $G $C -m a; RD_LIFECYCLE_BYPASS_REASON=legacy $G $C -m b"

# --- repo 대상 변경은 fail-closed (AC15) ---
check_hook H29 2 main "cd $OUT_DIR && GIT_DIR=/x/.git $G $C -m x" "확정할 수 없어"
check_hook H30 2 main "$G -C $OUT_DIR --git-dir=/x/.git $C -m x"  "확정할 수 없어"

# --- heredoc 종료는 bash 의미와 일치 (AC16) ---
check_hook H31 0 main "cat > f.md <<'EOF'
 EOF
$G $C -m 실행안됨
EOF"

# --- 명령 치환 안의 cd 는 subshell (AC18) ---
check_hook H32 2 main "echo \"\$(cd $OUT_DIR && $G $C -m a)\"; $G $C -m b"
check_hook H33 0 main "echo \"\$(cd $OUT_DIR && $G $C -m a)\"" "판정 생략"

# --- 복수 heredoc 은 rc=2 폴백 (AC19) ---
check_hook H34 2 main "cat <<EOF <<'Q' >/dev/null
\$($G $C -m x)
EOF
second
Q" "폴백"

# --- backslash-newline line continuation (AC20) ---
check_hook H35 2 main "$G com\\
${C:3} -m x"

# --- repo override 는 절대 -C 로 해소되지 않는다 (AC21) ---
# 대상이 밖($OUT_DIR)이어도 GIT_DIR 선행 변경이 있으면 생략하지 않고 판정한다.
check_hook H36 2 main "export GIT_DIR=/x/.git; $G -C $OUT_DIR $C -m x" "확정할 수 없어"

# --- ANSI-C 인용 직접 호출 (AC22) ---
check_hook H37 2 main "$G \$'$C' -m x"

# --- 예약어·실행 prefix·선행 redirection (AC23) ---
check_hook H38 2 main "command $G $C -m x"
check_hook H39 2 main "if $G $C -m x; then :; fi"
check_hook H40 0 main "command -v $G $C"

# --- backslash 로 인용한 heredoc 델리미터는 LITERAL (AC24) ---
check_hook H41 0 main "cat > f.md <<\\EOF
$G $C -m x
EOF"

# --- final diff review Turn 004 회귀 — **hook 종단**까지 단언한다 (Reviewer 제안) ---
# 스캐너 단위 케이스만으로는 1단 필터·폴백·생략 판정을 검사하지 못한다.
# ANSI-C escape: 1단 필터가 백슬래시를 지우면 `comx6dit` 이 되어 스캐너에 닿지도 않는다.
check_hook H42 2 main "$G \$'com\\x6dit' -m x"
# bare export + 독립 대입으로 나눠도 생략되지 않는다
check_hook H43 2 main "export GIT_DIR; GIT_DIR=/x/.git; $G -C $OUT_DIR $C -m x" "확정할 수 없어"
# env -C 로 밖을 가리키면 생략, 안을 가리키면 차단
check_hook H44 0 main "env -C $OUT_DIR $G $C -m x" "판정 생략"
# builtin 은 외부 명령을 실행하지 않으므로 통과 (과탐 방지)
check_hook H46 0 main "builtin $G $C -m x"
# 델리미터 인용 문맥이 틀리면 폴백으로 떨어져 데이터 구간이 다시 차단된다
check_hook H47 0 main "cat > f.md <<'E\\OF'
$G $C -m x
E\\OF"

# --- final diff review Turn 006 회귀 — hook 종단 ---
check_hook H48 2 main "env -P /usr/bin $G $C -m x"
check_hook H49 2 main "env -S \"$G $C -m x\""
check_hook H50 2 main "/usr/bin/time -a $G $C -m x"
# unknown escape 보존 -> 실행되지 않는 명령을 차단하지 않는다 (오탐 방지)
check_hook H51 0 main "$G \$'com\\mit' -m x"
# EOF 로 끝난 literal heredoc 의 body 는 데이터다 (오탐 해소)
check_hook H52 0 main "$(printf "cat > f.md <<'EOF'\n%s %s -m x" "$G" "$C")"

# --- final diff review Turn 008 회귀 — hook 종단 ---
check_hook H53 2 main "env '-P' /usr/bin $G $C -m x"
check_hook H54 2 main "env -S '$G' $C -m x"
check_hook H55 2 main "/usr/bin/time '-a' $G $C -m x"
check_hook H56 0 main "command -pv $G $C"

# --- final diff review Turn 010 회귀 — hook 종단 ---
# cluster 안의 인자 소비 검증. `-C` 의 위치 추적은 fixture 경로가 필요해 S102 가 담당한다.
check_hook H57 2 main "env -iu FOO $G $C -m x"
check_hook H58 2 main "exec -ca label $G $C -m x"
check_hook H59 2 main "/usr/bin/time -ao /dev/null $G $C -m x"
check_hook H60 2 main "env -S '$G\\_$C -m x'"
check_hook H61 0 main "command -x $G $C -m x"
check_hook H62 2 main "$(printf "cat <<\$'\\cB'\n%s %s -m data\n%s\n%s %s -m real\n" "$G" "$C" "$(printf '\002')" "$G" "$C")"

# --- final diff review Turn 012 회귀 — hook 종단 ---
check_hook H63 2 main "$G \$'$C\\0ignored' -m x"
check_hook H64 2 main "env -S \" $G $C -m x\""
check_hook H65 2 main "env -S \"\\_$G $C -m x\""
check_hook H66 0 main "env -S 'printf \"$G $C\"'"
check_hook H67 0 main "nohup -x $G $C -m x"
check_hook H68 0 main "time -a $G $C -m x"
check_hook H69 2 main "/usr/bin/time -a $G $C -m x"

# --- final diff review Turn 014 회귀 — hook 종단 ---
check_hook H70 2 main "$G \$'$C\\400ignored' -m x"
check_hook H71 2 main "$(printf "cat <<\$'EOF\\\\400ig'\n%s %s -m data\nEOF\n%s %s -m real\n" "$G" "$C" "$G" "$C")"
check_hook H72 2 main "env -S '$G $C\\cignored'"
check_hook H73 2 main "env -S '$G # ig' $C -m x"
check_hook H74 2 main "env time -a $G $C -m x"
check_hook H75 0 main "env -S 'printf \"\${HOME} $G $C\"'"
check_hook H76 0 main "env -S '$G com\\mit'"
# H12: 프로젝트를 가리키는 symlink — 물리 경로가 안이므로 차단
cleanup_h; H_FIX="$(make_h_fixture main)"
H12_PARENT="$(mktemp -d)"; SYM="$H12_PARENT/link"; ln -s "$H_FIX" "$SYM"
out=$( cd "$H_FIX" && printf '{"tool_input":{"command":%s}}' \
        "$(json_str "cd $SYM && $G $C -m x")" \
      | bash "$H_FIX/rd-workflow/scripts/hooks/fr_branch_gate.sh" 2>&1 ); rc=$?
if [[ "$rc" == 2 ]]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); printf 'FAIL H12 exit=%s (기대 2)\n  out: %s\n' "$rc" "$out" >&2; fi
rm -rf "$H12_PARENT"; H12_PARENT=""

# H16: git -C <형제 밖> -C <상대로 fixture 복귀> commit — 상대 -C 누적 합성이 안을 가리킨다.
#      `-C .` 은 직전 기준에 합성되어 계속 외부이므로 실제 복귀 경로를 계산해야 한다.
cleanup_h; H_FIX="$(make_h_fixture main)"
H16_SIB="$(dirname "$H_FIX")/h16-sibling-$$"; mkdir -p "$H16_SIB"   # cleanup_all 소유
out=$( cd "$H_FIX" && printf '{"tool_input":{"command":%s}}' \
        "$(json_str "$G -C $H16_SIB -C ../$(basename "$H_FIX") $C -m x")" \
      | bash "$H_FIX/rd-workflow/scripts/hooks/fr_branch_gate.sh" 2>&1 ); rc=$?
if [[ "$rc" == 2 ]]; then PASS=$((PASS+1)); printf 'ok   H16   exit=%s\n' "$rc"
else FAIL=$((FAIL+1)); printf 'FAIL H16 exit=%s (기대 2)\n  out: %s\n' "$rc" "$out" >&2; fi
rmdir "$H16_SIB" 2>/dev/null; H16_SIB=""

# H15: cd <밖> && git -C <프로젝트 절대경로> commit — 합성 결과가 안이므로 차단
cleanup_h; H_FIX="$(make_h_fixture main)"
out=$( cd "$H_FIX" && printf '{"tool_input":{"command":%s}}' \
        "$(json_str "cd $OUT_DIR && $G -C $H_FIX $C -m x")" \
      | bash "$H_FIX/rd-workflow/scripts/hooks/fr_branch_gate.sh" 2>&1 ); rc=$?
if [[ "$rc" == 2 ]]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); printf 'FAIL H15 exit=%s (기대 2)\n  out: %s\n' "$rc" "$out" >&2; fi

# H45: cd <밖> && env -C <fixture 절대경로> commit — env -C 가 fixture 로 되돌리므로 차단.
#      fixture 경로가 런타임에 정해지므로 H15 와 같은 전용 검사로 둔다.
cleanup_h; H_FIX="$(make_h_fixture main)"
out=$( cd "$H_FIX" && printf '{"tool_input":{"command":%s}}' \
        "$(json_str "cd $OUT_DIR && env -C $H_FIX $G $C -m x")" \
      | bash "$H_FIX/rd-workflow/scripts/hooks/fr_branch_gate.sh" 2>&1 ); rc=$?
if [[ "$rc" == 2 ]]; then PASS=$((PASS+1)); printf 'ok   H45   exit=%s\n' "$rc"
else FAIL=$((FAIL+1)); printf 'FAIL H45 exit=%s (기대 2)\n  out: %s\n' "$rc" "$out" >&2; fi
# H24: lifecycle/_lifecycle_common.sh 부재 fixture 에서도 정상 판정 (AC12)
#      방어가 없으면 source 가 셸을 종료시켜 exit 1 이 된다.
[[ -f "$H_FIX/rd-workflow/scripts/lifecycle/_lifecycle_common.sh" ]] && \
  printf 'WARN H24: fixture 에 lifecycle 이 존재합니다 — 이 케이스가 방어를 검증하지 못합니다\n' >&2
check_hook H24 2 main "$G $C -m x" "면제 reason"
# H13/H14/H14b — scanner-unavailable 폴백. fixture 에서 **_commit_scan.awk 만 제거**한다.
# awk 를 PATH 에서 지우면 dirname 등이 깨져 폴백이 아닌 PATH 파손으로 실패한다(실측).
out="$(run_hook main "$G $C -m x" no-awk)"; rc=$?
if [[ "$rc" == 2 && "$out" == *"폴백"* ]]; then PASS=$((PASS+1)); printf 'ok   H13   exit=%s\n' "$rc"
else FAIL=$((FAIL+1)); printf 'FAIL H13   exit=%s out=%s\n' "$rc" "$out" >&2; fi

# H14 — 폴백이 현행 정규식을 그대로 적용하는지. 입력은 현행이 **매칭하는** 형태여야 한다.
out="$(run_hook main "echo x && $G $C -m y" no-awk)"; rc=$?
if [[ "$rc" == 2 && "$out" == *"폴백"* ]]; then PASS=$((PASS+1)); printf 'ok   H14   exit=%s (폴백 정규식 적용 확인)\n' "$rc"
else FAIL=$((FAIL+1)); printf 'FAIL H14   exit=%s out=%s\n' "$rc" "$out" >&2; fi

# H14b — 현행이 미탐하던 형태는 폴백에서도 미탐 (강도 = 현행).
# fr_branch_gate 의 현행 경계 정규식은 개행 뒤 커밋을 미탐하므로 heredoc 데이터도 통과한다.
out="$(run_hook main "cat > f.md <<'EOF'
$G $C -m x
EOF" no-awk)"; rc=$?
if [[ "$rc" == 0 && "$out" == *"폴백"* ]]; then PASS=$((PASS+1)); printf 'ok   H14b  exit=%s\n' "$rc"
else FAIL=$((FAIL+1)); printf 'FAIL H14b  exit=%s out=%s\n' "$rc" "$out" >&2; fi

printf 'test_fr_branch_gate: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
