#!/usr/bin/env bash
# test_smoke_common.sh — _smoke_common.sh 단위 테스트 (self_test.sh 가 실행합니다)
# 케이스: 변경 파일 수집 5종 · 폴백 · 참조 폐포 · 관련성 판정 · preflight · full 지문
#
# ⚠️ **fixture 스크립트 이름에는 반드시 `_zzfx` 접미사를 붙입니다.**
#
# 이 파일은 full 스텝으로 등록돼 있어 어떤 스텝의 참조 폐포 구성원입니다. 그리고 관련성
# 판정 규칙 3(ii) 는 "변경 파일의 basename 이 폐포 구성원 **본문**에 등장하면 관련 있음"
# 이므로, 여기에 리터럴로 박힌 fixture 이름은 곧 "그 이름의 실제 인프라 파일은 이미
# 커버돼 있다" 는 오판이 됩니다. 그러면 신규 파일에 대한 무매핑 full 폴백이 걸리지 않고,
# 그 파일을 검증하는 스텝이 하나도 없는 채로 25개 스텝을 건너뛰며 PASS 합니다
# (실측 2026-08-19: new·added·keep·old 라는 흔한 어간의 스크립트로 재현했습니다).
#
# **접두사로는 막히지 않습니다.** `smoke_closure_matches` 의 본문 매치는 앵커 없는
# `grep -F` 부분 문자열 검사라, 접두사만 붙이면 원래 이름이 새 이름의 부분 문자열로
# 그대로 남아 여전히 걸립니다 (실측: 접두사 → 폴백 X 스킵 25, 접미사 → 폴백 O 스킵 0).
# 그래서 **접미사**를 씁니다.
#
# 같은 이유로 **이 주석에도 fixture 후보 이름을 리터럴로 쓰지 마십시오** — 주석 한 줄이
# 그 이름의 fail-safe 를 되살아나게 무력화합니다 (구현 중 실제로 한 번 겪었습니다).
#
# 예외 — 판정 대상으로서 그 이름이어야 하는 fixture 는 바꾸지 않습니다:
#   `self_test.sh` (폐포 제외가 basename 으로 판정되므로 이 이름이어야 합니다)
#
# 오케스트레이터 대역 fixture 는 "`self_test.sh` 가 **아닌** 이름" 이기만 하면 되므로
# 여기에도 접미사를 붙입니다. 접미사 없는 이름을 쓰면 같은 이름의 실제 인프라 파일이
# 신설될 때 이 파일 본문이 그 이름을 담고 있다는 이유만으로 커버된 것으로 오판되어
# 무매핑 full 폴백이 걸리지 않습니다 (실측 2026-08-19: 접미사 없음 → 실행 25 / 스킵 24,
# 접미사 있음 → 실행 49 / 스킵 0).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL=0
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/_smoke_common.sh"

ok()  { echo "ok: $1"; }
no()  { echo "FAIL: $1"; FAIL=1; }
eq()  { # eq <설명> <실제> <기대>
  if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (실제 '$2' != 기대 '$3')"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# repo fixture — 5개 변경 상태를 한 번에 만듭니다.
mk_repo() {
  local r="$TMP/repo"
  rm -rf "$r"; mkdir -p "$r"
  git -C "$r" init -q .
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  printf 'a\n' > "$r/keep_zzfx.sh"
  printf 'b\n' > "$r/gone_zzfx.sh"
  printf 'c\n' > "$r/old_zzfx.sh"
  git -C "$r" add -A
  RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$r" commit -qm init
  printf 'a2\n' >> "$r/keep_zzfx.sh"        # (i) tracked 수정
  printf 'n\n' > "$r/added_zzfx.sh"; git -C "$r" add "$r/added_zzfx.sh"  # (ii) 추가(staged)
  rm "$r/gone_zzfx.sh"                       # (iii) 삭제
  git -C "$r" mv old_zzfx.sh new_zzfx.sh          # (iv) rename
  printf 'u\n' > "$r/untracked_zzfx.sh"      # (v) untracked
  printf '%s' "$r"
}

# 배열을 정렬된 한 줄 문자열로 — 순서 비의존 비교용
joined() { printf '%s\n' ${SMOKE_CHANGED_FILES[@]+"${SMOKE_CHANGED_FILES[@]}"} | sort | tr '\n' ' '; }

# preflight 산출 전역을 set -u 안전하게 읽는 헬퍼들입니다.
# (구현 전에는 전역 자체가 없으므로 `${var-}` / `${arr[i]+...}` 형태로 접근해야
#  스크립트가 unbound variable 로 죽지 않고 FAIL 로 관찰됩니다.)
# 무매핑 목록은 개행 구분 문자열이라 **개행이 든 경로는 원리상 정확히 셀 수 없습니다**
# (그런 경로 1건과 보통 경로 2건이 같은 문자열이 됩니다). 산출 표현 자체는 Task 3 배선
# 계약이라 여기서 바꾸지 않고, 이 한계를 명시한 채 빈 줄만 걸러 셉니다 — `wc -l` 은
# 빈 문자열에도 1을 세므로 bash 루프로 바꿉니다.
unmapped_count() {
  local n=0 line
  [[ -n "${SMOKE_UNMAPPED-}" ]] || { printf '0'; return 0; }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n=$((n + 1))
  done <<< "$SMOKE_UNMAPPED"
  printf '%s' "$n"
}
skip_count() { local n=0 d; for d in ${SMOKE_SKIP_DESCS[@]+"${SMOKE_SKIP_DESCS[@]}"}; do n=$((n + 1)); done; printf '%s' "$n"; }
skip_desc()  { printf '%s' "${SMOKE_SKIP_DESCS[$1]+${SMOKE_SKIP_DESCS[$1]}}"; }
# 순번→설명 대응표를 `|` 구분 한 줄로 — 순번(위치)까지 함께 보기 위한 것입니다.
# 빈 배열에 printf 를 그대로 걸면 포맷이 한 번 적용되어 `|` 하나가 나오므로, 비었을 때는
# 빈 문자열이 되도록 먼저 걸러 냅니다 (없음과 1건을 구분하지 못하면 단언이 무의미합니다).
step_descs() {
  local d
  for d in ${SMOKE_STEP_DESCS[@]+"${SMOKE_STEP_DESCS[@]}"}; do printf '%s|' "$d"; done
}
# fixture 트리에 파일을 더한 뒤에는 스크립트 인덱스 캐시를 무효화합니다
# (실제 실행에서는 scripts_dir 이 고정이라 발생하지 않는 상황입니다).
reset_scripts_index() { SMOKE_SCRIPTS_INDEX_DIR=""; SMOKE_SCRIPTS_INDEX=""; }

R="$(mk_repo)"
smoke_collect_changed_files "$R" && rc=0 || rc=1
eq "수집 성공 rc" "$rc" "0"
eq "5개 상태 수집 (rename 은 양쪽 경로)" "$(joined)" "added_zzfx.sh gone_zzfx.sh keep_zzfx.sh new_zzfx.sh old_zzfx.sh untracked_zzfx.sh "

# 개행·공백이 든 경로도 원소가 쪼개지지 않아야 합니다 (NUL 파싱의 존재 이유)
NLR="$(mk_repo)"
printf 'x\n' > "$NLR/$(printf 'we\nird sp_zzfx.sh')"
smoke_collect_changed_files "$NLR"
nl_hit=0
for _m in ${SMOKE_CHANGED_FILES[@]+"${SMOKE_CHANGED_FILES[@]}"}; do
  [[ "$_m" == "$(printf 'we\nird sp_zzfx.sh')" ]] && nl_hit=1
done
eq "개행·공백 경로가 한 원소로 보존됨" "$nl_hit" "1"

# 폴백 1: git repo 가 아닌 경로
mkdir -p "$TMP/notrepo"
smoke_collect_changed_files "$TMP/notrepo" && rc=0 || rc=1
eq "git 실패 → 폴백 rc=1" "$rc" "1"

# 폴백 2: 미인식 status (unmerged) — 충돌 상태를 만들어 확인합니다
mk_conflict() {
  local r="$TMP/conflict"
  rm -rf "$r"; mkdir -p "$r"
  git -C "$r" init -q .
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  printf 'base\n' > "$r/f_zzfx.txt"; git -C "$r" add -A; RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$r" commit -qm base
  git -C "$r" checkout -qb other
  printf 'other\n' > "$r/f_zzfx.txt"; RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$r" commit -qam other
  git -C "$r" checkout -q master 2>/dev/null || git -C "$r" checkout -q main
  printf 'main\n' > "$r/f_zzfx.txt"; RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$r" commit -qam main
  git -C "$r" merge other >/dev/null 2>&1 || true
  printf '%s' "$r"
}
C="$(mk_conflict)"
smoke_collect_changed_files "$C" && rc=0 || rc=1
eq "unmerged(U) status → 폴백 rc=1" "$rc" "1"

# 폴백 3: type change (일반 파일 → symlink)
TC="$(mk_repo)"
rm -f "$TC/keep_zzfx.sh"; ln -s /dev/null "$TC/keep_zzfx.sh"
smoke_collect_changed_files "$TC" && rc=0 || rc=1
eq "type change(T) status → 폴백 rc=1" "$rc" "1"

# 해시 헬퍼
h1="$(printf 'x' | _smoke_hash)"
h2="$(printf 'x' | _smoke_hash)"
h3="$(printf 'y' | _smoke_hash)"
eq "_smoke_hash 결정론적" "$h1" "$h2"
if [[ "$h1" == "$h3" ]]; then no "_smoke_hash 가 다른 입력을 구분하지 못함"; else ok "_smoke_hash 입력 구분"; fi
if [[ "$h1" =~ ^[0-9a-f]{64}$ ]]; then ok "_smoke_hash 형식 (sha256 hex)"; else no "_smoke_hash 형식: $h1"; fi

# --- 참조 폐포 -------------------------------------------------------------
S="$TMP/scripts"
mkdir -p "$S/hooks"
cat > "$S/test_alpha_zzfx.sh" <<'EOF'
#!/usr/bin/env bash
. "${SCRIPT_DIR}/_alpha_lib_zzfx.sh"
bash "${SCRIPT_DIR}/hooks/alpha_target_zzfx.sh"
EOF
cat > "$S/_alpha_lib_zzfx.sh" <<'EOF'
#!/usr/bin/env bash
# deep_leaf_zzfx.sh 를 문자열로 참조합니다
# 참조 문서: alpha_notes_zzfx.md
EOF
cat > "$S/hooks/alpha_target_zzfx.sh" <<'EOF'
#!/usr/bin/env bash
echo alpha
EOF
cat > "$S/hooks/deep_leaf_zzfx.sh" <<'EOF'
#!/usr/bin/env bash
echo leaf
EOF
cat > "$S/test_beta_zzfx.sh" <<'EOF'
#!/usr/bin/env bash
echo beta
EOF

smoke_ref_closure "$S" "$S/test_alpha_zzfx.sh"
closure_names="$(printf '%s\n' ${SMOKE_CLOSURE[@]+"${SMOKE_CLOSURE[@]}"} | sed 's#.*/##' | sort | tr '\n' ' ')"
eq "폐포: source·서브프로세스·문자열 참조를 전이적으로 전개" \
   "$closure_names" "_alpha_lib_zzfx.sh alpha_target_zzfx.sh deep_leaf_zzfx.sh test_alpha_zzfx.sh "

smoke_ref_closure "$S" "$S/test_beta_zzfx.sh"
closure_names="$(printf '%s\n' ${SMOKE_CLOSURE[@]+"${SMOKE_CLOSURE[@]}"} | sed 's#.*/##' | sort | tr '\n' ' ')"
eq "폐포: 참조 없는 스크립트는 자기 자신만" "$closure_names" "test_beta_zzfx.sh "

# --- 관련성 판정 -----------------------------------------------------------
SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/alpha_target_zzfx.sh")
smoke_step_relevant "$S" bash "$S/test_alpha_zzfx.sh" && rc=0 || rc=1
eq "서브프로세스로 실행되는 대상이 바뀌면 실행" "$rc" "0"
smoke_step_relevant "$S" bash "$S/test_beta_zzfx.sh" && rc=0 || rc=1
eq "무관한 스텝은 스킵" "$rc" "1"

SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/deep_leaf_zzfx.sh")
smoke_step_relevant "$S" bash "$S/test_alpha_zzfx.sh" && rc=0 || rc=1
eq "2단계 폐포(라이브러리가 문자열로 참조) 도 실행" "$rc" "0"

SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/deep_leaf_zzfx.sh")
smoke_step_relevant "$S" some_inline_checker && rc=0 || rc=1
eq "inline checker 함수 스텝은 항상 실행" "$rc" "0"

SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/deep_leaf_zzfx.sh")
smoke_step_relevant "$S" bash "$S/does_not_exist_zzfx.sh" && rc=0 || rc=1
eq "대상 스크립트가 없으면(형태 불명) 항상 실행" "$rc" "0"

SMOKE_CHANGED_FILES=("rd-workflow/scripts/test_alpha_zzfx.sh")
smoke_step_relevant "$S" bash "$S/test_alpha_zzfx.sh" && rc=0 || rc=1
eq "스텝 스크립트 자신이 바뀌면 실행" "$rc" "0"

# 판정 규칙 3(ii): 폐포 구성원 **본문**에 변경 파일의 basename 이 등장하면 실행합니다.
# `alpha_notes_zzfx.md` 는 폐포 구성원(모두 `*.sh`)의 경로·basename 과 절대 겹치지 않으므로,
# 이 케이스는 오직 본문 등장 규칙만으로 성립합니다. 실제 저장소에서는 이 규칙이
# `docs/prompts/**` 변경에서 리뷰 관련 bash 스텝을 살려 두는 결정적 근거입니다.
SMOKE_CHANGED_FILES=("rd-workflow/docs/alpha_notes_zzfx.md")
smoke_step_relevant "$S" bash "$S/test_alpha_zzfx.sh" && rc=0 || rc=1
eq "폐포 구성원 본문에 등장하는 이름이면 실행 (규칙 3-ii)" "$rc" "0"
smoke_step_relevant "$S" bash "$S/test_beta_zzfx.sh" && rc=0 || rc=1
eq "본문에 등장하지 않는 스텝은 그대로 스킵 (규칙 3-ii 의 판별력 확인)" "$rc" "1"

# --- env 접두 형태 -----------------------------------------------------------
eq "env 접두를 건너뛰고 bash 대상을 찾음" \
   "$(smoke_cmd_target env FOO=1 BAR=2 bash "$S/test_alpha_zzfx.sh")" "$S/test_alpha_zzfx.sh"
eq "inline checker 는 대상 없음" "$(smoke_cmd_target some_inline_checker)" ""

SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/deep_leaf_zzfx.sh")
smoke_step_relevant "$S" env FOO=1 bash "$S/test_beta_zzfx.sh" && rc=0 || rc=1
eq "env 접두가 있어도 무관 스텝은 스킵 (정체성 유지)" "$rc" "1"
smoke_step_relevant "$S" env FOO=1 bash "$S/test_alpha_zzfx.sh" && rc=0 || rc=1
eq "env 접두가 있어도 관련 스텝은 실행" "$rc" "0"

# --- 정본 경로 정규화 --------------------------------------------------------
eq "_ROOT_FILES 접두사 제거" "$(smoke_normalize_path '_ROOT_FILES/rd-workflow/scripts/x_zzfx.sh')" "rd-workflow/scripts/x_zzfx.sh"
eq "미러 경로는 그대로" "$(smoke_normalize_path 'rd-workflow/scripts/x_zzfx.sh')" "rd-workflow/scripts/x_zzfx.sh"
eq "그 밖의 경로도 그대로" "$(smoke_normalize_path 'CURRENT_TASK.md')" "CURRENT_TASK.md"

SMOKE_CHANGED_FILES=("_ROOT_FILES/rd-workflow/scripts/hooks/alpha_target_zzfx.sh")
smoke_step_relevant "$S" bash "$S/test_alpha_zzfx.sh" && rc=0 || rc=1
eq "정본 경로만 변경돼도 관련 스텝을 찾음" "$rc" "0"

# --- run_step 정적 추출 ------------------------------------------------------
cat > "$S/fake_self_test_zzfx.sh" <<'EOF'
#!/usr/bin/env bash
run_step "alpha 테스트" bash "${SCRIPT_DIR}/test_alpha_zzfx.sh"
run_step "beta 테스트" bash "${SCRIPT_DIR}/test_beta_zzfx.sh"
run_step "inline 검사" some_checker
  run_step "들여쓰기된 호출은 최상위가 아님" bash "${SCRIPT_DIR}/test_beta_zzfx.sh"
run_step "미정의 변수 스텝" env "X=${UNDEFINED_FOR_TEST}" bash "${SCRIPT_DIR}/test_alpha_zzfx.sh"
run_step "깨진 인용" bash "unbalanced
EOF
reset_scripts_index
# 뒤의 두 스텝은 preflight 의 eval 이 밟는 지뢰 두 개(미정의 변수·인용 파손)를 재현합니다.
# 기존 순번(1 alpha · 2 beta · 3 inline)을 보존하려고 **끝에** 붙였습니다.
eq "최상위 run_step 만 추출 (5건)" "$(smoke_extract_steps "$S/fake_self_test_zzfx.sh" | wc -l | tr -d ' ')" "5"

# set -u 아래에서 미정의 변수 확장은 `|| continue` 로도 막지 못하는 **셸 종료**이고,
# eval 의 2>/dev/null 이 메시지까지 삼켜 아무 단서 없이 죽습니다. 보호가 빠지면 아래
# preflight 호출부터 이 테스트 프로세스가 통째로 사라져 FAIL 조차 남지 않으므로,
# 먼저 서브셸에 가둬 "살아남았는지" 를 명시적으로 관찰합니다.
( set -u
  SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/alpha_target_zzfx.sh")
  smoke_preflight "$S" "$S/fake_self_test_zzfx.sh" && printf 'alive' ) > "$TMP/u_probe" 2>/dev/null
eq "미정의 변수 스텝이 있어도 preflight 가 살아남음 (set -u)" "$(cat "$TMP/u_probe")" "alive"

# --- smoke_preflight: 무매핑 인프라 파일 + 스킵 순번 계약 ---------------------
# 무매핑 3건은 smoke_unmapped_infra_files 시절의 기대값을 그대로 유지한 채
# 호출부만 smoke_preflight + SMOKE_UNMAPPED 로 옮긴 것입니다.
SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/alpha_target_zzfx.sh")
# preflight 는 eval 구간에서만 -u 를 내립니다. set -u 는 셸 **전역** 옵션이라 복원이
# 빠지면 호출자(self_test.sh 는 set -euo pipefail)가 나머지 실행 내내 -u 를 잃고,
# 오타 난 변수가 중단 대신 빈 문자열로 접히는 조용한 열화가 됩니다. fixture 5번(인용
# 파손)이 eval 실패 경로를, 1~4번이 정상 경로를 지나므로 한 호출로 양쪽을 덮습니다.
_opts_before="$-"
smoke_preflight "$S" "$S/fake_self_test_zzfx.sh" && rc=0 || rc=1
eq "preflight 이 셸 옵션을 원래대로 복원 (set -u)" "$-" "$_opts_before"
eq "preflight 정상 종료 rc" "$rc" "0"
eq "매핑되는 파일은 무매핑 목록에 없음" "$(unmapped_count)" "0"
eq "스킵 순번 집합은 |순번| 형태" "${SMOKE_SKIP_IDX-}" "|2|"
eq "스킵 스텝 수" "$(skip_count)" "1"
eq "스킵 설명은 '<순번>. <설명>' 형태" "$(skip_desc 0)" "2. beta 테스트"
# 5번 스텝은 인용이 깨져 eval 이 실패합니다 — 스킵 목록에 들어가지 않는 것이
# "판정 불능은 항상 실행" 계약입니다. 4번(미정의 변수)은 -u 가드 덕에 판정 불능이
# 아니라 정상 판정 대상이 됩니다(빈 문자열로 접혀 `env "X=" bash <test_alpha_zzfx.sh>` 가
# 되고 대상이 실재합니다) — 여기서는 alpha 계열 변경이라 관련 있음으로 실행됩니다.
eq "eval 실패 스텝은 스킵 목록에 없음" "${SMOKE_SKIP_IDX-}" "|2|"

# 순번 → 설명 **대응표** (spec §5.3 역할 3). 스킵 여부와 무관하게 모든 스텝이, 추출 순서
# 그대로 들어가야 합니다. 호출자는 실행 중 이 표와 실제 설명을 대조해 어긋난 스텝을
# 스킵하지 않고 실행합니다 — 표가 비거나 순서가 틀어지면 그 대조 자체가 무의미해집니다.
# 들여쓰기된 호출은 실제 스텝이 아니므로 표에도 없어야 합니다 (4번째 자리가 그 증거입니다).
eq "대응표는 최상위 스텝 전부를 순번 순서로 담음" "$(step_descs)" \
   "alpha 테스트|beta 테스트|inline 검사|미정의 변수 스텝|깨진 인용|"

# 변경 파일이 0건이면 관련성 판정이 무의미하므로 스킵을 하나도 만들지 않습니다
# (안전 기본값 — 상위 호출자의 full 폴백과 별개로 이 함수 단독으로도 지킵니다).
SMOKE_CHANGED_FILES=()
smoke_preflight "$S" "$S/fake_self_test_zzfx.sh" && rc=0 || rc=1
eq "변경 파일 0건 preflight rc" "$rc" "0"
eq "변경 파일 0건이면 스킵 없음 (안전 기본값)" "${SMOKE_SKIP_IDX-}" ""
eq "변경 파일 0건이면 스킵 설명도 없음" "$(skip_count)" "0"
# 대응표는 조기 반환 경로에서도 채워져야 합니다. 비워서 내면 호출자의 순번↔설명 대조가
# **모든 스텝에서** 어긋난 것으로 보여 경고가 도배되고, 그 소음이 진짜 어긋남을 덮습니다.
eq "변경 파일 0건에서도 대응표는 채워짐" "$(step_descs)" \
   "alpha 테스트|beta 테스트|inline 검사|미정의 변수 스텝|깨진 인용|"

printf 'echo new\n' > "$S/brand_new_helper_zzfx.sh"
reset_scripts_index
SMOKE_CHANGED_FILES=("rd-workflow/scripts/brand_new_helper_zzfx.sh")
smoke_preflight "$S" "$S/fake_self_test_zzfx.sh"
eq "어느 폐포에도 없는 새 인프라 파일은 무매핑" "$(unmapped_count)" "1"
# 무매핑이 있으면 호출자는 full 로 폴백해야 하므로 스킵 목록은 의미가 없을 뿐 아니라
# 위험합니다 — 신규 파일은 어떤 폐포에도 없어 bash 스텝 전부가 스킵 판정되기 때문입니다.
eq "무매핑이 있으면 스킵 목록을 내지 않음 (full 폴백 전제)" "${SMOKE_SKIP_IDX-}" ""
# 표시용 배열도 함께 비워야 합니다 — 절반만 비우면 호출자가 full 폴백을 하면서도
# 사용자에게는 거짓 스킵 목록을 출력하게 됩니다 (spec §5.3 preflight 역할 2).
eq "무매핑이면 스킵 설명도 내지 않음 (표시 계약)" "$(skip_count)" "0"
# 대응표는 **비우지 않습니다**. 순번↔설명 대응은 관련성 판정과 무관하게 그대로 참이고,
# 여기서 비우면 폴백 상태에서 호출자가 순번 밀림을 감지할 근거를 잃습니다.
eq "무매핑이어도 대응표는 유지됨" "$(step_descs)" \
   "alpha 테스트|beta 테스트|inline 검사|미정의 변수 스텝|깨진 인용|"

SMOKE_CHANGED_FILES=("CURRENT_TASK.md" "rd-workflow-workspace/plans/x_zzfx.md")
smoke_preflight "$S" "$S/fake_self_test_zzfx.sh"
eq "인프라 코드가 아닌 변경은 무매핑 검사 대상이 아님" "$(unmapped_count)" "0"

# 스텝을 하나도 추출하지 못하면 호출자가 full 로 폴백하도록 rc=1 을 냅니다.
printf '#!/usr/bin/env bash\n# run_step 호출이 없습니다\n' > "$S/no_steps_zzfx.sh"
reset_scripts_index
SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/alpha_target_zzfx.sh")
smoke_preflight "$S" "$S/no_steps_zzfx.sh" && rc=0 || rc=1
eq "스텝 추출 0건이면 rc=1 (full 폴백)" "$rc" "1"

# --- self_test.sh 는 폐포에서 제외됩니다 --------------------------------------
# self_test.sh 는 모든 스텝 스크립트 이름을 언급하는 오케스트레이터라, 폐포에 들어오면
# 무관한 파일까지 모든 스텝에 매치되어 관련성 판정이 무력화됩니다.
cat > "$S/self_test.sh" <<'EOF'
#!/usr/bin/env bash
run_step "gamma 테스트" bash "${SCRIPT_DIR}/test_gamma_zzfx.sh"
run_step "무관한 스텝" bash "${SCRIPT_DIR}/unrelated_target_zzfx.sh"
EOF
cat > "$S/test_gamma_zzfx.sh" <<'EOF'
#!/usr/bin/env bash
# self_test.sh 가 이 테스트를 실행합니다
bash "${SCRIPT_DIR}/gamma_target_zzfx.sh"
EOF
printf '#!/usr/bin/env bash\necho gamma\n' > "$S/gamma_target_zzfx.sh"
printf '#!/usr/bin/env bash\necho unrelated\n' > "$S/unrelated_target_zzfx.sh"
reset_scripts_index

smoke_ref_closure "$S" "$S/test_gamma_zzfx.sh"
closure_names="$(printf '%s\n' ${SMOKE_CLOSURE[@]+"${SMOKE_CLOSURE[@]}"} | sed 's#.*/##' | sort | tr '\n' ' ')"
eq "폐포에 self_test.sh 가 들어오지 않음" "$closure_names" "gamma_target_zzfx.sh test_gamma_zzfx.sh "

SMOKE_CHANGED_FILES=("rd-workflow/scripts/unrelated_target_zzfx.sh")
smoke_step_relevant "$S" bash "$S/test_gamma_zzfx.sh" && rc=0 || rc=1
eq "self_test.sh 만 경유해 닿는 무관한 변경은 스킵" "$rc" "1"

SMOKE_CHANGED_FILES=("rd-workflow/scripts/gamma_target_zzfx.sh")
smoke_step_relevant "$S" bash "$S/test_gamma_zzfx.sh" && rc=0 || rc=1
eq "실제로 참조하는 대상이 바뀌면 실행" "$rc" "0"

# --- preflight ↔ smoke_step_relevant 교차 검증 --------------------------------
# 두 경로가 갈라지면 preflight 가 보여준 스킵 목록과 실제 실행이 어긋납니다.
cross_check() {
  local label="$1" desc cmd idx=0 expect="" _u_on=0
  smoke_preflight "$S" "$S/fake_self_test_zzfx.sh" || { no "$label (preflight rc=1)"; return 0; }
  while IFS=$'\t' read -r desc cmd; do
    idx=$((idx + 1))
    cmd="${cmd//\$\{SCRIPT_DIR\}/$S}"
    # preflight 와 같은 이유로 이 구간에서만 -u 를 내립니다 (미정의 변수 확장 = 셸 종료).
    _u_on=0; case "$-" in *u*) _u_on=1; set +u ;; esac
    eval "set -- $cmd" 2>/dev/null || { (( _u_on )) && set -u; continue; }
    (( _u_on )) && set -u
    smoke_step_relevant "$S" "$@" || expect="${expect}|${idx}|"
  done <<< "$(smoke_extract_steps "$S/fake_self_test_zzfx.sh")"
  # 무매핑이 있으면 preflight 는 스킵 산출을 **의도적으로 비웁니다**(full 폴백 전제).
  # 스텝별 판정과 갈라지는 것이 정상이며, 여기서는 그 차단이 실제로 일어나는지를 봅니다 —
  # 스텝별 판정이 스킵을 내놓았는데도 preflight 산출이 비어 있어야 위험 경로가 막힌 것입니다.
  if [[ -n "${SMOKE_UNMAPPED-}" ]]; then
    eq "$label (무매핑 → preflight 스킵 산출 없음)" "${SMOKE_SKIP_IDX-}" ""
    if [[ -n "$expect" ]]; then
      ok "$label (스텝별 판정은 스킵 $expect 를 냈으나 preflight 가 차단)"
    else
      no "$label (무매핑인데 스텝별 판정에도 스킵이 없어 차단 효과를 확인하지 못함)"
    fi
    return 0
  fi
  eq "$label" "${SMOKE_SKIP_IDX-}" "$expect"
}

SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/alpha_target_zzfx.sh")
cross_check "교차 검증: 대상 스크립트 변경"
SMOKE_CHANGED_FILES=("rd-workflow/scripts/hooks/deep_leaf_zzfx.sh")
cross_check "교차 검증: 2단계 폐포 변경"
SMOKE_CHANGED_FILES=("rd-workflow/scripts/brand_new_helper_zzfx.sh")
cross_check "교차 검증: 무매핑 신규 파일"
SMOKE_CHANGED_FILES=("CURRENT_TASK.md")
cross_check "교차 검증: 인프라가 아닌 변경"

# --- syntax_check 대상 선택 ---------------------------------------------------
# 변경된 셸 스크립트 중 **실재하는** 것만 `bash -n` 대상이 되어야 합니다. 삭제된 파일과
# rename 이전 경로는 디스크에 없어 무조건 실패하고, `*.sh` 가 아닌 변경은 애초에 대상이
# 아닙니다.
R2="$(mk_repo)"
printf 'doc\n' > "$R2/notes_zzfx.md"       # *.sh 아닌 변경도 섞습니다
smoke_collect_changed_files "$R2"
smoke_changed_shell_files "$R2"
targets="$(printf '%s\n' ${SMOKE_SYNTAX_TARGETS[@]+"${SMOKE_SYNTAX_TARGETS[@]}"} | sed 's#.*/##' | sort | tr '\n' ' ')"
eq "syntax 대상은 존재하는 변경 *.sh 만" "$targets" "added_zzfx.sh keep_zzfx.sh new_zzfx.sh untracked_zzfx.sh "

# 헬퍼를 다시 불러도 대상이 **누적되지 않아야** 합니다. 산출이 전역 배열이라 함수 진입 시
# 초기화가 빠지면 두 번째 호출부터 같은 파일이 겹쳐 쌓입니다. 위 정확 일치 단언이 우연히
# 잡아 주기는 하지만 그것은 "마지막 호출이 첫 호출" 일 때만 성립합니다 — 케이스 순서가
# 바뀌면 사라지는 검출이므로, 누적 없음 자체를 직접 봅니다.
smoke_changed_shell_files "$R2"; n_first=${#SMOKE_SYNTAX_TARGETS[@]}
smoke_changed_shell_files "$R2"; n_second=${#SMOKE_SYNTAX_TARGETS[@]}
eq "헬퍼를 두 번 불러도 대상이 늘지 않음" "${n_first}/${n_second}" "4/4"

# --- 조인 기준은 설치 루트가 아니라 git 최상위입니다 --------------------------
# `SMOKE_CHANGED_FILES` 는 `git status` 산출이라 언제나 repo 최상위 상대 경로입니다.
# 설치 루트가 최상위가 아니면(서브디렉터리 설치) 받은 루트로 조인한 경로가 전부 존재하지
# 않게 되고, 삭제 파일 필터와 구분 없이 탈락해 **대상 0건으로 조용히 통과**합니다 —
# 변경된 파일의 구문 오류마저 놓치는, 축소 계약 밖의 손실입니다.
SUBR="$TMP/subrepo"
mkdir -p "$SUBR/sub/rd-workflow/scripts"
git -C "$SUBR" init -q .
git -C "$SUBR" config user.email t@t.t; git -C "$SUBR" config user.name t
printf 'echo s\n' > "$SUBR/sub/rd-workflow/scripts/subfile_zzfx.sh"
git -C "$SUBR" add -A
RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$SUBR" commit -qm init
printf '\n# 변경\n' >> "$SUBR/sub/rd-workflow/scripts/subfile_zzfx.sh"
sub_top="$(cd "$SUBR" && pwd -P)"
smoke_collect_changed_files "$SUBR/sub"
smoke_changed_shell_files "$SUBR/sub"
eq "설치 루트가 git 최상위가 아니면 조인 기준을 최상위로 잡음" "${SMOKE_JOIN_ROOT-}" "$sub_top"
eq "서브디렉터리 설치에서도 변경 파일이 대상에 들어옴 (0건으로 조용히 비지 않음)" \
   "$(printf '%s\n' ${SMOKE_SYNTAX_TARGETS[@]+"${SMOKE_SYNTAX_TARGETS[@]}"})" \
   "$sub_top/sub/rd-workflow/scripts/subfile_zzfx.sh"

# 반대로 설치 루트가 곧 최상위이면(같은 곳을 다르게 적은 경우 포함) 받은 표기를 그대로
# 유지해야 합니다 — 같은 디렉터리인데 표기만 갈아 끼우면 경로를 대조하는 쪽이 이유 없이
# 깨집니다 (macOS 의 임시 디렉터리가 symlink 라 실제로 밟는 경로입니다).
smoke_collect_changed_files "$R2"
smoke_changed_shell_files "$R2"
eq "루트가 최상위와 같으면 받은 표기를 유지" "${SMOKE_JOIN_ROOT-}" "$R2"

# 개행이 든 경로도 **한 원소**로 남아야 합니다 — 산출을 배열로 두는 이유가 이것입니다.
# 줄 단위 stdout 으로 내면 이 경로가 두 개의 존재하지 않는 경로로 쪼개져, 정작 바뀐
# 파일의 구문 검사가 실행되지 않습니다 (수집 단계의 NUL 안전성이 전달 단계에서 무너집니다).
NL2="$(mk_repo)"
nl_name="$(printf 'we\nird sp_zzfx.sh')"
printf 'x\n' > "$NL2/$nl_name"
smoke_collect_changed_files "$NL2"
smoke_changed_shell_files "$NL2"
nl_target_hit=0
for _t in ${SMOKE_SYNTAX_TARGETS[@]+"${SMOKE_SYNTAX_TARGETS[@]}"}; do
  [[ "$_t" == "$NL2/$nl_name" ]] && nl_target_hit=1
done
eq "개행이 든 *.sh 경로가 대상에서도 한 원소로 보존됨" "$nl_target_hit" "1"

# 정본 경로(`_ROOT_FILES/…`)는 **정규화하지 않고 그대로** 검사합니다. 실제로 바뀐 파일이
# 정본이고, 미러는 install-root 이후 별도 변경 항목으로 함께 잡히기 때문입니다. 여기서
# 미러 경로로 접으면 아직 install-root 를 돌리지 않은 상태에서 바뀐 적 없는 파일을
# 검사하고 정작 바뀐 정본은 검사하지 않습니다.
mkdir -p "$TMP/canon/_ROOT_FILES/rd-workflow/scripts"
printf 'echo c\n' > "$TMP/canon/_ROOT_FILES/rd-workflow/scripts/canon_zzfx.sh"
SMOKE_CHANGED_FILES=("_ROOT_FILES/rd-workflow/scripts/canon_zzfx.sh")
smoke_changed_shell_files "$TMP/canon"
eq "정본 경로는 정규화 없이 그대로 대상" \
   "$(printf '%s\n' ${SMOKE_SYNTAX_TARGETS[@]+"${SMOKE_SYNTAX_TARGETS[@]}"})" \
   "$TMP/canon/_ROOT_FILES/rd-workflow/scripts/canon_zzfx.sh"

# --- fixture 이름 규약 검사 스크립트 자신을 지키는 단언 -----------------------
# 이 저장소의 `_zzfx` 규약 강제는 검사 스크립트 **한 파일**에 전부 얹혀 있습니다. 그 파일을
# 무력화해도 어떤 스위트도 붉어지지 않으면 규약이 통째로 꺼진 채 모든 검증이 초록입니다
# (실측 2026-08-19: 실재 검사를 항상 참으로 바꿔도, 대상 목록에서 한 줄만 지워도 두 스위트
# PASS 였습니다). 그래서 여기서 검사 스크립트를 **실제로 실행**해 판별력을 관측합니다.
#
# 이 스위트에 두는 이유: 검사 스크립트는 진입점 계약이 아니라 단독으로 돌려 판정을 보는
# 단위 도구이고, 이 스위트는 4초·다른 스위트는 56초라 붙이는 비용이 자릿수로 다릅니다.
# 여기에 이름을 리터럴로 적어도 규칙 (2)(실재하는 파일) 로 통과하며, 그 대가로 검사
# 스크립트가 이 스위트의 폐포에 들어와 **검사 스크립트를 고친 smoke 실행에서 이 단언들이
# 함께 돕니다** — 오히려 필요한 연결입니다.
CONV="${SCRIPT_DIR}/check_fixture_name_convention.sh"

# (i) 정본 실행 — 검사 **대상 수**를 기대값으로 못박습니다. 대상을 완전히 비우는 방향은
#     아래 (v) 가 잡지만, 리팩터링 중 한 줄만 지우는 흔한 실수는 rc=0 으로 조용히
#     통과합니다 ("대상 0건일 때 조용히 통과" 결함 부류의 변종입니다).
conv_out="$(bash "$CONV" 2>&1)"; conv_rc=$?
eq "규약 검사 정본 rc" "$conv_rc" "0"
eq "규약 검사 대상 수 (줄어들면 여기서 드러납니다)" \
   "$(printf '%s' "$conv_out" | sed -n 's/.*검사 대상 \([0-9]*\)개.*/\1/p')" "3"

# (ii) 대상 목록의 각 항목이 실재해야 합니다. 오타·경로 이동이면 그 항목은 검사되지 않고,
#      어느 항목이 깨졌는지는 rc 만으로 알 수 없으므로 항목 단위로 봅니다.
#      목록은 **런타임에 파싱**하므로 아래 fixture 가 대상 구성 변경을 자동으로 따라갑니다.
conv_names=()
while IFS= read -r _cn; do
  [[ -n "$_cn" ]] && conv_names+=("$_cn")
done < <(sed -n '/^TARGETS=(/,/^)/p' "$CONV" \
         | sed -n 's#^[[:space:]]*"\${SCRIPT_DIR}/\([^"]*\)"[[:space:]]*$#\1#p')
# 파싱이 0건이 되면 아래 단언이 전부 공허하게 통과하므로 파싱 자체를 먼저 못박습니다.
# 그리고 고정하는 대상은 **건수가 아니라 이름 집합**입니다. 건수만 보면 한 줄을 **실재하는
# 다른 대상으로 치환·중복**하는 편집(리팩터링·복붙에서 흔합니다)이 건수를 유지하며 통과하고,
# 그러면 한 스위트가 통째로 규약 강제 밖으로 나가 그 파일의 실제 위반이 rc=0 으로 지나갑니다
# (실측 2026-08-19: 한 줄 치환으로 두 스위트와 규약 검사가 전부 초록이었습니다).
# 집합 대조는 건수 단언을 자동으로 포함합니다.
#
# 여기에 세 이름을 리터럴로 적어도 새 구멍이 생기지 않습니다 — 세 파일 모두 실재하므로 규칙
# (2) 로 통과하고, 대상 목록을 담은 검사 스크립트가 이미 이 스위트의 폐포 구성원이라 세 이름은
# 그 폐포에 이미 들어 있습니다. 대상을 늘릴 때 이 줄을 함께 갱신해야 하는 것은 **의도된
# 비용**입니다 (의식적 갱신을 강제하는 것이 이 검사의 목적입니다).
eq "규약 검사 대상 구성 (건수가 아니라 이름 집합을 고정합니다)" \
   "$(printf '%s\n' ${conv_names[@]+"${conv_names[@]}"} | sort | tr '\n' ' ')" \
   "check_fixture_name_convention.sh test_self_test_smoke.sh test_smoke_common.sh "
conv_missing=""
for _cn in ${conv_names[@]+"${conv_names[@]}"}; do
  [[ -f "${SCRIPT_DIR}/${_cn}" ]] || conv_missing="${conv_missing} ${_cn}"
done
eq "대상 목록의 각 항목이 실재" "$conv_missing" ""

# (iii) 규칙 (1)(`_zzfx` 접미사)·(2)(실재하면 통과) 가 **실제로 판별**하는지 봅니다.
#       임시 사본에 이름을 심어 관측합니다 — 정본을 건드리지 않고, 규칙을 항상 참으로
#       바꾸는 형태(존재 검사 무력화)를 여기서 죽입니다.
#
#       프로브 이름은 **런타임에 조립**합니다. 이 파일 본문에 접미사 없는 이름을 리터럴로
#       박으면 그 이름이 규약 검사의 추출 대상이 되어 이 스위트 자신이 위반으로 걸립니다
#       (`$$` 는 전개되지 않은 형태로 남고 `$` 가 추출 문자 집합 밖이라 토큰이 되지 않습니다).
CONVFX="$TMP/convfx"
mkdir -p "$CONVFX"
cp "$CONV" "$CONVFX/"
conv_self="${CONV##*/}"
conv_fx="$CONVFX/$conv_self"
conv_probe_target=""
for _cn in ${conv_names[@]+"${conv_names[@]}"}; do
  # 사본 자신은 이미 있으므로 덮어쓰지 않습니다 (덮어쓰면 검사 스크립트가 사라집니다).
  [[ -e "$CONVFX/$_cn" ]] || printf '#!/usr/bin/env bash\n' > "$CONVFX/$_cn"
  [[ "$_cn" == "$conv_self" || -n "$conv_probe_target" ]] || conv_probe_target="$CONVFX/$_cn"
done
conv_bad="zzconv_absent_$$.sh"
conv_good="zzconv_absent_$$_zzfx.sh"
# 규약의 핵심은 `_zzfx` 가 **접미사**라는 것입니다. 부분 문자열 판정으로 약화해도(`*_zzfx.sh`
# → `*_zzfx*`) 위 두 프로브는 그대로 통과하므로(하나는 접미사가 있고 하나는 아예 없습니다)
# **접미사가 아닌 위치**의 이름을 따로 봅니다. 그 약화가 열어 주는 구멍이 이 규약의 존재
# 이유 그 자체입니다 — 접두사·중간 위치 이름은 원래 이름을 본문에 그대로 남겨 무매핑
# full 폴백을 잠식합니다.
#
# 꼬리도 `_$$` 로 끊습니다. 접미사가 아닌 이름을 리터럴로 남기면 그 토큰이 규약 검사에
# 추출되어 이 스위트 자신이 위반으로 걸립니다 (`$` 가 추출 문자 집합 밖이라 토큰이 끊깁니다).
conv_mid="zzconv_absent_$$_zzfx_mid_$$.sh"
if [[ -z "$conv_probe_target" ]]; then
  no "규약 검사 사본에 심을 대상 파일을 찾지 못했습니다 (아래 단언을 수행하지 않았습니다)"
else
  # 기준선 — 아무것도 심지 않은 사본은 통과해야 합니다. 이것이 없으면 아래 두 단언이
  # "사본이 애초에 실패 상태" 라는 이유로도 통과합니다.
  bash "$conv_fx" >/dev/null 2>&1; eq "사본 기준선 rc (심기 전)" "$?" "0"
  # 양성 대조 — 규약을 지킨 이름은 실재하지 않아도 통과해야 합니다 (규칙 (1)).
  printf '#!/usr/bin/env bash\n# %s\n' "$conv_good" > "$conv_probe_target"
  bash "$conv_fx" >/dev/null 2>&1; eq "규약을 지킨 이름은 실재하지 않아도 통과 (규칙 1)" "$?" "0"
  # 본 단언 — 접미사 없는 실재하지 않는 이름은 반드시 걸려야 합니다 (규칙 (1)·(2) 판별).
  printf '#!/usr/bin/env bash\n# %s\n' "$conv_bad" > "$conv_probe_target"
  conv_v="$(bash "$conv_fx" 2>&1)"; conv_vrc=$?
  eq "접미사 없는 실재하지 않는 이름은 위반 (규칙 1·2 판별)" "$conv_vrc" "1"
  if printf '%s' "$conv_v" | grep -qF -- "$conv_bad"; then
    ok "위반 보고가 그 이름을 지목"
  else
    no "위반 보고가 '$conv_bad' 를 지목하지 않았습니다"
  fi
  # 접미사성 프로브 — `_zzfx` 가 **중간에** 든 이름은 규약을 지킨 것이 아니므로 위반이어야
  # 합니다. 접미사 판정을 부분 문자열 판정으로 바꾸는 약화가 여기서만 죽습니다.
  printf '#!/usr/bin/env bash\n# %s\n' "$conv_mid" > "$conv_probe_target"
  conv_m="$(bash "$conv_fx" 2>&1)"; conv_mrc=$?
  eq "_zzfx 가 접미사가 아닌 위치면 위반 (접미사성 판별)" "$conv_mrc" "1"
  if printf '%s' "$conv_m" | grep -qF -- "$conv_mid"; then
    ok "접미사성 위반 보고가 그 이름을 지목"
  else
    no "접미사성 위반 보고가 '$conv_mid' 를 지목하지 않았습니다"
  fi
  printf '#!/usr/bin/env bash\n' > "$conv_probe_target"
fi

# (iv) 검사 스크립트가 **자기 자신도** 대상이어야 합니다. 자기 규칙 밖에 두면 이 파일에
#      적은 평범한 이름이 폐포에 구멍을 내면서 자기 검사에는 걸리지 않습니다.
#      사본 본문에 심어 관측합니다 (마지막 줄이 `exit` 이라 뒤에 붙여도 동작은 같고,
#      규약 검사는 실행 여부와 무관하게 본문을 훑습니다).
printf '# %s\n' "$conv_bad" >> "$conv_fx"
bash "$conv_fx" >/dev/null 2>&1; eq "검사 스크립트가 자기 규칙의 대상" "$?" "1"

# (v) 대상이 0건이면 **명시적으로 실패**해야 합니다. 빈 배열이 `set -u` 아래에서 우연히
#     터지는 것에 기대면 가드를 넣거나 bash 가 바뀌는 순간 조용한 통과로 뒤집힙니다.
CONVZ="$TMP/convzero"
mkdir -p "$CONVZ"
# 배열 정의를 **그 자리에서** 빈 배열로 갈아 끼웁니다. 파일 끝에 덧붙이면 최종 `exit` 뒤라
# 실행되지 않아 아무것도 관측하지 못합니다.
awk 'f && /^\)$/ { f=0; next } /^TARGETS=\(/ { print "TARGETS=()"; f=1; next } !f' \
  "$CONV" > "$CONVZ/$conv_self"
conv_z="$(bash "$CONVZ/$conv_self" 2>&1)"; conv_zrc=$?
eq "대상 0건이면 rc=1 (조용히 통과하지 않음)" "$conv_zrc" "1"
has_zero=0
printf '%s' "$conv_z" | grep -qF "검사 대상이 0건입니다" && has_zero=1
eq "대상 0건을 사유로 보고" "$has_zero" "1"

# --- full 증명 지문 -------------------------------------------------------
#
# 지문은 "이 내용으로 full 을 통과한 적이 있는가" 를 판정하는 근거입니다. 그래서 **바뀐 것을
# 하나라도 놓치면 안 되고**(stale 증명 재사용), 계산이 불가능할 때는 통과가 아니라 차단
# 쪽으로 판정해야 합니다(fail-closed). 아래 케이스는 그 두 성질을 축별로 못박습니다.
FR2="$TMP/fp"
mkdir -p "$FR2/rd-workflow/scripts/hooks"
printf 'echo a\n' > "$FR2/rd-workflow/scripts/a_zzfx.sh"
git -C "$FR2" init -q .
git -C "$FR2" config user.email t@t.t; git -C "$FR2" config user.name t
git -C "$FR2" add -A >/dev/null 2>&1
RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$FR2" commit -qm init >/dev/null 2>&1

# transient 제외는 lifecycle 감사 로그로 한정합니다 — 맨 `*.log` 는 git pathspec 특성상
# 저장소 전역·임의 깊이에 걸려 인프라 디렉터리의 로그까지 증명 밖으로 뺍니다.
eq "로그 제외가 lifecycle 로 한정됨" "$(smoke_proof_exclude | grep -cFx -- ":(exclude)*.log")" "0"
eq "lifecycle 로그 제외는 유지"      "$(smoke_proof_exclude | grep -cFx -- ":(exclude)rd-workflow-workspace/.lifecycle/*.log")" "1"

# 증명 캐시는 `mktemp "<캐시>.XXXXXX"` → `mv -f` 로 씁니다. 전수 검증이 그 창에서 중단되면
# `selftest-full-cache.abc123` 이 남아 untracked 로 잡히고, **우회 밸브가 없는 아카이브
# 게이트가 영구 차단**됩니다. 정확한 이름만 제외하면 이 임시 파일이 걸립니다.
eq "캐시 임시 파일 제외 항목 존재" "$(smoke_proof_exclude | grep -cFx -- ":(exclude)rd-workflow-workspace/.lifecycle/selftest-full-cache.*")" "1"

# proof 는 인프라 파일에 한정되지 않습니다 — 문서 변경도 증명을 무효화합니다.
printf 'doc v1\n' > "$FR2/docs_note.md"
git -C "$FR2" add -A >/dev/null 2>&1
RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$FR2" commit -qm doc >/dev/null 2>&1
fp_doc1="$(smoke_proof_fingerprint "$FR2" worktree)"
printf 'doc v2\n' > "$FR2/docs_note.md"
fp_doc2="$(smoke_proof_fingerprint "$FR2" worktree)"
if [[ "$fp_doc1" == "$fp_doc2" ]]; then
  no "trigger 밖 문서 변경인데 proof 지문이 그대로입니다 (stale 증명 재사용 경로)"
else
  ok "인프라 밖 문서 변경도 proof 지문을 바꿈"
fi
git -C "$FR2" checkout -- docs_note.md >/dev/null 2>&1

# transient 산출물은 proof 에서 제외됩니다 — 캐시 자신이 캐시를 무효화하면 안 됩니다.
mkdir -p "$FR2/rd-workflow-workspace/.lifecycle"
printf 'x\n' > "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
git -C "$FR2" add -A >/dev/null 2>&1
RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$FR2" commit -qm cache >/dev/null 2>&1
fp_c1="$(smoke_proof_fingerprint "$FR2" worktree)"
printf 'y\n' > "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
eq "transient 변경은 proof 지문에 영향 없음" "$(smoke_proof_fingerprint "$FR2" worktree)" "$fp_c1"

fp1="$(smoke_proof_fingerprint "$FR2" worktree)"; rc=$?
if [[ "$rc" == "0" && -n "$fp1" ]]; then ok "지문 계산 성공"; else no "지문 계산 실패 (rc=$rc)"; fi
fp_idx="$(smoke_proof_fingerprint "$FR2" index)"
eq "워킹트리 = index 일 때 지문 일치" "$fp1" "$fp_idx"

printf 'echo b\n' >> "$FR2/rd-workflow/scripts/a_zzfx.sh"
fp2="$(smoke_proof_fingerprint "$FR2" worktree)"
if [[ "$fp1" == "$fp2" ]]; then no "인프라 파일이 바뀌었는데 지문이 같습니다"; else ok "인프라 변경 시 지문 변화"; fi

git -C "$FR2" add -A >/dev/null 2>&1
fp_idx2="$(smoke_proof_fingerprint "$FR2" index)"
eq "staged 반영 후 index 지문 = 워킹트리 지문" "$fp2" "$fp_idx2"

# 정본만 있는 저장소도 지문 대상에 잡혀야 합니다 (미러 동기화 전 상태).
CAN="$TMP/canon"
mkdir -p "$CAN/_ROOT_FILES/rd-workflow/scripts"
printf 'echo c\n' > "$CAN/_ROOT_FILES/rd-workflow/scripts/c_zzfx.sh"
git -C "$CAN" init -q .
git -C "$CAN" config user.email t@t.t; git -C "$CAN" config user.name t
git -C "$CAN" add -A >/dev/null 2>&1
RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$CAN" commit -qm init >/dev/null 2>&1
smoke_proof_fingerprint "$CAN" worktree >/dev/null && rc=0 || rc=1
eq "정본만 있어도 지문 계산 성공" "$rc" "0"

# tracked 파일이 하나도 없는 저장소 → 계산 실패(1) → 호출자는 차단 쪽으로 판정해야 합니다.
# 빈 목록의 해시를 그대로 내면 "무엇을 넣어도 통과하는 지문" 이 생깁니다.
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
git -C "$EMPTY" init -q .
smoke_proof_fingerprint "$EMPTY" worktree >/dev/null 2>&1 && rc=0 || rc=1
eq "인프라 파일 부재 → 지문 계산 실패" "$rc" "1"

# clean 상태에서 worktree/index 지문이 일치해야 합니다 — 일반 파일·실행 비트·symlink 각각.
git -C "$FR2" checkout -- . >/dev/null 2>&1
printf 'echo x\n' > "$FR2/rd-workflow/scripts/exec_bit_zzfx.sh"; chmod 755 "$FR2/rd-workflow/scripts/exec_bit_zzfx.sh"
ln -sf a_zzfx.sh "$FR2/rd-workflow/scripts/link_to_a_zzfx.sh"
git -C "$FR2" add -A >/dev/null 2>&1
RD_LIFECYCLE_BYPASS_REASON=bootstrap git -C "$FR2" commit -qm modes >/dev/null 2>&1
eq "clean 상태 worktree=index 지문 (파일·실행비트·symlink 포함)" \
   "$(smoke_proof_fingerprint "$FR2" worktree)" "$(smoke_proof_fingerprint "$FR2" index)"

# 실행 비트만 바뀌어도 지문이 달라져야 합니다.
fp_x1="$(smoke_proof_fingerprint "$FR2" worktree)"
chmod 644 "$FR2/rd-workflow/scripts/exec_bit_zzfx.sh"
if [[ "$fp_x1" == "$(smoke_proof_fingerprint "$FR2" worktree)" ]]; then
  no "실행 비트만 바뀌었는데 지문이 같습니다 (stale 증명 경로)"
else
  ok "실행 비트 변경이 지문에 반영됨"
fi
chmod 755 "$FR2/rd-workflow/scripts/exec_bit_zzfx.sh"

# 반대 방향 — index 가 100644 인 파일에 실행 비트가 **붙는** 경우도 잡아야 합니다.
# 한 방향만 두면 워킹트리 레코드의 mode 를 상수로 내는 구현이 그대로 살아남습니다
# (실측: 그 돌연변이가 위 단언만으로는 검출되지 않았습니다).
fp_x_add="$(smoke_proof_fingerprint "$FR2" worktree)"
chmod 755 "$FR2/rd-workflow/scripts/a_zzfx.sh"
if [[ "$fp_x_add" == "$(smoke_proof_fingerprint "$FR2" worktree)" ]]; then
  no "실행 비트가 붙었는데 지문이 같습니다 (워킹트리 mode 가 상수입니다)"
else
  ok "실행 비트 추가가 지문에 반영됨"
fi
chmod 644 "$FR2/rd-workflow/scripts/a_zzfx.sh"

# symlink 는 **링크 문자열 자체**를 해시합니다. 대상 내용을 따라가면 워킹트리 분기와 index
# 분기가 서로 다른 것을 재게 되어 clean 상태에서도 두 지문이 갈립니다.
ln -sf b_target_zzfx.sh "$FR2/rd-workflow/scripts/link_to_a_zzfx.sh"
if [[ "$fp_x1" == "$(smoke_proof_fingerprint "$FR2" worktree)" ]]; then
  no "링크 대상이 바뀌었는데 지문이 같습니다"
else
  ok "symlink 링크 문자열 변경이 지문에 반영됨"
fi
# 존재하지 않는 대상을 가리키는 링크에서도 지문이 계산돼야 합니다 — 대상을 따라 읽는
# 구현으로 되돌아가면 여기서 계산 자체가 실패합니다.
smoke_proof_fingerprint "$FR2" worktree >/dev/null 2>&1 && rc=0 || rc=1
eq "끊어진 symlink 에서도 지문 계산 성공" "$rc" "0"
git -C "$FR2" checkout -- . >/dev/null 2>&1

# tracked 파일이 워킹트리에서 사라진 상태도 지문에 반영돼야 합니다.
fp_del1="$(smoke_proof_fingerprint "$FR2" worktree)"
mv "$FR2/rd-workflow/scripts/exec_bit_zzfx.sh" "$TMP/exec_bit_stash"
if [[ "$fp_del1" == "$(smoke_proof_fingerprint "$FR2" worktree)" ]]; then
  no "tracked 파일이 삭제됐는데 지문이 같습니다"
else
  ok "워킹트리 삭제가 지문에 반영됨"
fi
mv "$TMP/exec_bit_stash" "$FR2/rd-workflow/scripts/exec_bit_zzfx.sh"

# untracked 가 있으면 기록을 거부합니다 — untracked 파일도 full checker 의 입력이라
# tracked 지문만으로는 검증 상태를 증명할 수 없습니다.
printf 'tmpfile\n' > "$FR2/stray_new_file_zzfx.sh"
now_fp="$(smoke_proof_fingerprint "$FR2" worktree)"
smoke_record_full_pass "$FR2" "$now_fp" 0 2>/dev/null && rc=0 || rc=1
eq "untracked 존재 → 기록 거부" "$rc" "1"
smoke_untracked_state "$FR2" >/dev/null; eq "untracked 상태 = 1(있음)" "$?" "1"
rm -f "$FR2/stray_new_file_zzfx.sh"
smoke_untracked_state "$FR2" >/dev/null; eq "untracked 없음 상태 = 0" "$?" "0"

# 기록이 중단되어 남은 캐시 임시 파일이 게이트를 영구 차단하면 안 됩니다 — **양방향**으로
# 고정합니다. 좁히면 결함이 남고, 넓히면 증명 범위가 함께 좁아집니다.
printf 'stale\n' > "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache.ab12cd"
smoke_untracked_state "$FR2" >/dev/null; eq "캐시 임시 파일이 남아도 untracked 0건" "$?" "0"
fp_tmpleft="$(smoke_proof_fingerprint "$FR2" worktree)"
smoke_record_full_pass "$FR2" "$fp_tmpleft" 0 2>/dev/null && rc=0 || rc=1
eq "캐시 임시 파일이 남아도 기록을 거부하지 않음" "$rc" "0"
rm -f "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache.ab12cd"
# 반대 방향 — 접두가 같아도 `.lifecycle` 밖이거나 다른 이름이면 여전히 차단해야 합니다.
printf 'x\n' > "$FR2/selftest-full-cache.ab12cd"
smoke_untracked_state "$FR2" >/dev/null; eq ".lifecycle 밖의 동명 파일은 여전히 untracked" "$?" "1"
rm -f "$FR2/selftest-full-cache.ab12cd"
printf 'x\n' > "$FR2/rd-workflow-workspace/.lifecycle/other-temp_zzfx"
smoke_untracked_state "$FR2" >/dev/null; eq "무관한 untracked 는 여전히 차단" "$?" "1"
rm -f "$FR2/rd-workflow-workspace/.lifecycle/other-temp_zzfx"

# git 실패는 "untracked 없음" 이 아니라 무효로 판정해야 합니다 (fail-closed).
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT/rd-workflow-workspace/.lifecycle"
printf 'x\n' > "$NOGIT/rd-workflow-workspace/.lifecycle/selftest-full-cache"
smoke_cache_valid "$NOGIT" worktree 2>/dev/null && rc=0 || rc=1
eq "git 저장소가 아니면 캐시 무효 (fail-closed)" "$rc" "1"

# --- fake-git: git 하위 명령을 선택적으로 실패시켜 fail-closed 를 확인합니다 -----------
# **각 소비 경로가 실제로 호출하는 명령만** 단언합니다. 호출하지도 않는 명령을 실패시켜
# 거부를 기대하면 정상 구현이 FAIL 로 판정됩니다.
#
#   smoke_untracked_state    → ls-files --others
#   proof 지문 (공통)        → ls-files -s
#   proof 지문 worktree 전용 → diff-files, 그리고 다른 파일이 있을 때만 hash-object
#   smoke_cache_valid        → untracked 조회 + proof 지문(mode 별)
#   smoke_record_full_pass   → untracked 조회 + **worktree** 지문
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/git" <<'FG'
#!/usr/bin/env bash
real="$(PATH="$FAKE_GIT_REALPATH" command -v git)"
args="$*"
case "${FAKE_GIT_FAIL:-}" in
  others)     case "$args" in *"ls-files --others"*) exit 3 ;; esac ;;
  lsfiles)    case "$args" in *"ls-files -s"*)       exit 3 ;; esac ;;
  difffiles)  case "$args" in *"diff-files"*)        exit 3 ;; esac ;;
  hashobject) case "$args" in *"hash-object"*)       exit 3 ;; esac ;;
esac
exec "$real" "$@"
FG
chmod +x "$FAKEBIN/git"
FAKE_GIT_REALPATH="$PATH"; export FAKE_GIT_REALPATH

# 유효한 캐시를 먼저 만들어 둡니다 (실패 주입 전에는 통과해야 대조가 의미 있습니다).
git -C "$FR2" checkout -- . >/dev/null 2>&1
mkdir -p "$FR2/rd-workflow-workspace/.lifecycle"
smoke_proof_fingerprint "$FR2" worktree > "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
CACHED_FP="$(head -1 "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache")"
smoke_cache_valid "$FR2" worktree >/dev/null 2>&1 && rc=0 || rc=1
eq "실패 주입 전에는 캐시 유효" "$rc" "0"

fake_run() { # fake_run <fail-mode> <함수> <인자...>
  local m="$1"; shift
  ( PATH="$FAKEBIN:$PATH"; export FAKE_GIT_FAIL="$m"; "$@" >/dev/null 2>&1 ) && echo 0 || echo 1
}

# (a) untracked 조회 실패 → **untracked 를 보는 경로만** fail-closed 입니다.
#     index 모드는 untracked 를 아예 조회하지 않으므로 이 실패에 영향을 받지 않아야 합니다.
#     여기서 index 도 무효를 기대하면 "무슨 실패든 전부 거부" 하는 구현이 통과해 mode 분기의
#     판별력이 사라집니다.
eq "others 실패 → cache_valid(worktree) 무효" "$(fake_run others smoke_cache_valid "$FR2" worktree)" "1"
eq "others 실패 → PASS 기록 거부"             "$(fake_run others smoke_record_full_pass "$FR2" "$CACHED_FP" 0)" "1"
eq "others 실패 → cache_valid(index) 는 영향 없음" "$(fake_run others smoke_cache_valid "$FR2" index)" "0"

# (b) proof 목록 조회 실패 → worktree·index 양쪽 지문과 그 소비처가 모두 실패
eq "ls-files -s 실패 → worktree 지문 실패" "$(fake_run lsfiles smoke_proof_fingerprint "$FR2" worktree)" "1"
eq "ls-files -s 실패 → index 지문 실패"    "$(fake_run lsfiles smoke_proof_fingerprint "$FR2" index)" "1"
eq "ls-files -s 실패 → cache_valid 무효"   "$(fake_run lsfiles smoke_cache_valid "$FR2" worktree)" "1"
eq "ls-files -s 실패 → PASS 기록 거부"     "$(fake_run lsfiles smoke_record_full_pass "$FR2" "$CACHED_FP" 0)" "1"

# (c) worktree 전용 경로 — index 지문은 diff-files 를 부르지 않으므로 영향이 없어야 합니다.
#     이 대조가 없으면 "무슨 실패든 전부 거부" 하는 구현도 통과해 판별력이 사라집니다.
eq "diff-files 실패 → worktree 지문 실패"      "$(fake_run difffiles smoke_proof_fingerprint "$FR2" worktree)" "1"
eq "diff-files 실패 → cache_valid(worktree) 무효" "$(fake_run difffiles smoke_cache_valid "$FR2" worktree)" "1"
eq "diff-files 실패 → index 지문은 영향 없음"  "$(fake_run difffiles smoke_proof_fingerprint "$FR2" index)" "0"

# (d) 워킹트리에 다른 파일이 있을 때만 hash-object 를 부릅니다. clean 이면 부르지 않으므로
#     실패를 주입해도 지문이 나와야 하고, dirty 면 계산 불능으로 거부해야 합니다.
eq "hash-object 실패 + clean → worktree 지문 성공" "$(fake_run hashobject smoke_proof_fingerprint "$FR2" worktree)" "0"
printf 'echo dirty\n' >> "$FR2/rd-workflow/scripts/a_zzfx.sh"
eq "hash-object 실패 + dirty → worktree 지문 실패" "$(fake_run hashobject smoke_proof_fingerprint "$FR2" worktree)" "1"
git -C "$FR2" checkout -- . >/dev/null 2>&1

# TOCTOU: 시작 지문과 종료 지문이 다르면 기록하지 않습니다 — 검증하지 않은 내용을 통과로
# 증명하게 되기 때문입니다.
rm -f "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
start_fp="$(smoke_proof_fingerprint "$FR2" worktree)"
printf 'echo drift\n' >> "$FR2/rd-workflow/scripts/a_zzfx.sh"
mkdir -p "$FR2/rd-workflow-workspace/.lifecycle"
smoke_record_full_pass "$FR2" "$start_fp" 0 2>/dev/null && rc=0 || rc=1
eq "실행 중 변경 → 캐시 미기록" "$rc" "1"
if [[ -f "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache" ]]; then
  no "미기록이어야 하는데 캐시 파일이 생겼습니다"
else
  ok "미기록 시 캐시 파일 없음"
fi
now_fp="$(smoke_proof_fingerprint "$FR2" worktree)"
smoke_record_full_pass "$FR2" "$now_fp" 0 && rc=0 || rc=1
eq "시작=종료 지문 → 기록 성공" "$rc" "0"
eq "기록 내용이 지문과 일치" "$(head -1 "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache")" "$now_fp"

# 시작 시점 untracked 상태도 기록 조건입니다 — 종료 시점만 보면 **실행 중에 생겼다가 사라진**
# 파일이 아무 흔적을 남기지 않고, 그 상태를 가린 채 PASS 가 기록됩니다. 그 기록을 index 모드가
# untracked 검사 없이 소비하므로(생략의 근거가 바로 이 기록 조건입니다) 전제가 깨집니다.
# 지문 축의 `start_fp` 와 같은 모양이라, 두 축을 같은 강도로 못박습니다.
rm -f "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
smoke_record_full_pass "$FR2" "$now_fp" 1 2>/dev/null && rc=0 || rc=1
eq "시작 시점 untracked 있었음(=1) → 종료가 깨끗해도 기록 거부" "$rc" "1"
if [[ -f "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache" ]]; then
  no "시작 시점 untracked 였는데 캐시 파일이 생겼습니다"
else
  ok "시작 시점 untracked → 캐시 파일 없음"
fi
smoke_record_full_pass "$FR2" "$now_fp" 2 2>/dev/null && rc=0 || rc=1
eq "시작 시점 untracked 조회 실패(=2) → 기록 거부" "$rc" "1"
# 값을 아예 넘기지 않으면 "확인하지 못함" 이며 기록하지 않습니다 (fail-closed).
# 이 단언이 없으면 호출부에서 인자를 빠뜨리는 회귀가 조용히 살아남습니다.
smoke_record_full_pass "$FR2" "$now_fp" 2>/dev/null && rc=0 || rc=1
eq "시작 시점 untracked 상태 미전달 → 기록 거부" "$rc" "1"
smoke_record_full_pass "$FR2" "$now_fp" 0 && rc=0 || rc=1
eq "시작·종료 양쪽 0건 → 기록 성공" "$rc" "0"
# 기록 직후에는 캐시가 유효해야 합니다 (기록과 판정이 같은 지문 정의를 쓰는지 대조).
smoke_cache_valid "$FR2" worktree >/dev/null 2>&1 && rc=0 || rc=1
eq "기록 직후 캐시 유효" "$rc" "0"
# 지문이 다르면 무효입니다 — 이 대조가 장치 전체의 핵심이므로 간접 경로에 맡기지 않고
# 직접 못박습니다. 대조를 통째로 없애는 회귀는 여기서 죽습니다.
printf 'deadbeef\n' > "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
smoke_cache_valid "$FR2" worktree 2>/dev/null && rc=0 || rc=1
eq "지문 불일치 → 캐시 무효" "$rc" "1"
# 기록 후 인프라가 바뀌면(= 검증하지 않은 내용) 무효가 되어야 합니다.
smoke_proof_fingerprint "$FR2" worktree > "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
printf 'echo after\n' >> "$FR2/rd-workflow/scripts/a_zzfx.sh"
smoke_cache_valid "$FR2" worktree 2>/dev/null && rc=0 || rc=1
eq "기록 후 인프라 변경 → 캐시 무효" "$rc" "1"
git -C "$FR2" checkout -- . >/dev/null 2>&1

# --- 소비 시점 untracked 검사의 mode 분기 -----------------------------------
#
# 두 모드가 **서로 다르게** 판정하는 것이 의도된 설계입니다.
#   index    → 커밋될 것은 index 트리뿐이므로 지문만 봅니다. untracked 는 커밋에 들어가지
#              않아 커밋될 트리의 증명 상태를 바꾸지 못합니다.
#   worktree → 커밋·아카이브 대상이 워킹트리 자체이므로 untracked 도 함께 봅니다.
# 한쪽만 단언하면 분기를 통째로 뒤집는 회귀(worktree 에서 검사 생략)가 살아남습니다.
git -C "$FR2" checkout -- . >/dev/null 2>&1
mkdir -p "$FR2/rd-workflow-workspace/.lifecycle"
smoke_proof_fingerprint "$FR2" index > "$FR2/rd-workflow-workspace/.lifecycle/selftest-full-cache"
printf 'orchestrator note\n' > "$FR2/mode_split_note_zzfx.sh"
smoke_untracked_state "$FR2" >/dev/null; eq "분기 대조 준비: untracked 있음" "$?" "1"
smoke_cache_valid "$FR2" index >/dev/null 2>&1 && rc=0 || rc=1
eq "index 모드: untracked 가 있어도 지문이 맞으면 유효" "$rc" "0"
smoke_cache_valid "$FR2" worktree >/dev/null 2>&1 && rc=0 || rc=1
eq "worktree 모드: untracked 가 있으면 무효" "$rc" "1"
# index 모드가 untracked 를 무시한다고 해서 지문 대조까지 무르지는 않아야 합니다.
printf 'echo idx\n' >> "$FR2/rd-workflow/scripts/a_zzfx.sh"
git -C "$FR2" add rd-workflow/scripts/a_zzfx.sh >/dev/null 2>&1
smoke_cache_valid "$FR2" index >/dev/null 2>&1 && rc=0 || rc=1
eq "index 모드: 지문이 다르면 여전히 무효" "$rc" "1"
git -C "$FR2" reset -q >/dev/null 2>&1
git -C "$FR2" checkout -- . >/dev/null 2>&1
rm -f "$FR2/mode_split_note_zzfx.sh"

echo ""
if [[ "$FAIL" -eq 0 ]]; then echo "test_smoke_common: PASS"; exit 0; else echo "test_smoke_common: FAIL" >&2; exit 1; fi
