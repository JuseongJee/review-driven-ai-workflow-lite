#!/usr/bin/env bash
# test_review_effort_override.sh — reasoning effort override 판정·전달·즉시 실패·환경 격리 검증
# AC 1~9·13(개정: 자동 재시도 없음)·14b·23 (review-turn-latency-reduction)
# codex 실행 없이 판정 로직과 stub 어댑터만 검사한다.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }
chk()  { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }
eq()   { # eq <실제> <기대> <라벨>
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (기대=[$2] 실제=[$1])"; fi
}

TMP="$(mktemp -d)" || { echo "test_review_effort_override.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_review_effort_override.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# 검사 대상이 읽는 환경 변수를 호출 환경에서 물려받지 않는다. 값이 필요한 케이스는 그 호출에만 붙인다.
# 물려받으면 effort 미전달 케이스가 상속값을 전달하고(TOOL_EFFORT), 격리 케이스가 kill switch·다른
# 설정 파일·다른 턴 한도로 돈다(RD_REVIEW_EFFORT_OVERRIDE·REVIEW_TOOLS_CONFIG·REVIEW_TURN_LIMIT).
unset TOOL_EFFORT RD_REVIEW_EFFORT_OVERRIDE REVIEW_TOOLS_CONFIG REVIEW_TURN_LIMIT
unset CODEX_HOME RD_MODELS_CONFIG RD_REVIEW_CODEX_MODEL RD_REVIEW_CLAUDE_MODEL \
      RD_REVIEW_CODEX_EFFORT RD_REVIEW_CLAUDE_EFFORT

finish() {
  echo
  if [ "$FAIL" -eq 0 ]; then
    echo "test_review_effort_override: ALL PASS"
    exit 0
  else
    echo "test_review_effort_override: FAILED"
    exit 1
  fi
}

# ============================================================
# 예시 복사 (spec D1·D12, REQUEST AC11) — 배포 트리의 models.json.example 을 그대로 복사해 쓰면
# 리뷰 턴이 그 값을 쓰는지 본다. 트리의 스크립트로 임시 프로젝트를 만들고 가짜 codex 로 실행한다.
#   기본: 이 파일이 든 트리.  RD_TEST_TREE=<트리 루트> RD_TEST_ONLY=example-copy: 그 트리에서 이 케이스만.
# ============================================================
example_copy_case() { # example_copy_case <트리 루트>
  local tree="$1" ex="$TMP/excopy" f
  rm -rf "$ex"
  mkdir -p "$ex/rd-workflow/scripts" "$ex/rd-workflow/config" "$ex/rd-workflow/docs/flows" \
           "$ex/rd-workflow/docs/prompts/review" "$ex/home/.codex" "$ex/bin" "$ex/args" "$ex/sess/turns"
  for f in run_review_turn.sh review_common.sh review_wait.sh adapter_codex.sh adapter_claude.sh model_select.sh; do
    if ! cp "$tree/rd-workflow/scripts/$f" "$ex/rd-workflow/scripts/$f" 2>/dev/null; then
      fail "example-copy: 트리에 rd-workflow/scripts/$f 가 없음 ($tree)"; return
    fi
  done
  if ! jq '.review.codex.effort = "high"' "$tree/rd-workflow/config/models.json.example" \
         > "$ex/rd-workflow/config/models.json" 2>/dev/null; then
    fail "example-copy: 트리의 rd-workflow/config/models.json.example 을 읽지 못함 ($tree)"; return
  fi
  printf '{"default_priority":["codex"]}\n' > "$ex/rd-workflow/config/review-tools.json"
  printf '기준\n' > "$ex/rd-workflow/docs/prompts/review/diff_review.md"
  printf '규칙\n' > "$ex/rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md"
  printf 'target\n' > "$ex/TARGET.md"
  cat > "$ex/sess/SESSION.md" <<'EOF'
# Review Session

## Status
awaiting-reviewer

## Current Owner
Reviewer

## Review Type
diff-review

## Review Target
TARGET.md

## Review Goal
goal

## Turn Limit
20

## Review Scope
- execution-path: other
EOF
  printf '# C\n\n## Open Issues\n- 없음\n' > "$ex/sess/CHECKPOINT.md"
  printf '# U\n\n## Question For User\n-\n' > "$ex/sess/USER_ACTION.md"
  printf '# T1\n' > "$ex/sess/turns/001_claude.md"
  cat > "$ex/bin/codex" <<'FKEOF'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done > "$ARGDIR/args.codex"
cat > /dev/null
printf '# T\n' > "$EXPECTED_TURN_FILE"
sed -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' \
  "$SESSION_PATH/SESSION.md" > "$SESSION_PATH/S.tmp"
mv "$SESSION_PATH/S.tmp" "$SESSION_PATH/SESSION.md"
FKEOF
  chmod +x "$ex/bin/codex"
  ( cd "$ex" && env -u RD_MODELS_CONFIG -u REVIEW_TOOLS_CONFIG -u CODEX_HOME -u TOOL_MODEL -u TOOL_EFFORT \
      -u RD_REVIEW_EFFORT_OVERRIDE HOME="$ex/home" ARGDIR="$ex/args" WAIT_TIMEOUT=20 PATH="$ex/bin:$PATH" \
      bash "$ex/rd-workflow/scripts/run_review_turn.sh" sess >"$ex/out" 2>"$ex/err" )
  grep -qF "effort 시도: high (source: tool-default · file:" "$ex/err" \
    && grep -qF "models.json#review.codex.effort)" "$ex/err"
  chk $? "example-copy 예시 복사본의 review.codex.effort=high → 실행 줄 tool-default · models.json#review.codex.effort"
  grep -qxF 'model_reasoning_effort="high"' "$ex/args/args.codex" 2>/dev/null
  chk $? "example-copy 가짜 codex 가 effort high 를 받음"
}

# ============================================================
# 구현 subagent 칸 (change-spec subagent-model-effort-selection D2~D4·D8)
# 자기 하네스를 함수 안에서 만든다: $TMP/sa 아래 사본 트리와 jq 를 뺀 PATH 폴더.
# ============================================================
subagent_cli_case() {
  local SAP="$TMP/sa" SAC SANOJQ d SAPY=1
  mkdir -p "$SAP/rd-workflow/scripts" "$SAP/rd-workflow/config"
  cp "${script_dir}/model_select.sh" "$SAP/rd-workflow/scripts/model_select.sh"
  SAC="$SAP/rd-workflow/config"
  SANOJQ="$TMP/sa-nojq"; mkdir -p "$SANOJQ"
  for d in /bin /usr/bin /usr/sbin /sbin; do [ -d "$d" ] && ln -s "$d"/* "$SANOJQ/" 2>/dev/null; done
  rm -f "$SANOJQ/jq"
  [ -x "$SANOJQ/python3" ] || SAPY=0
  sa_cli() { ( cd "$SAP" && HOME="$TMP/sa-home" bash rd-workflow/scripts/model_select.sh "$@" ) >"$TMP/sa.out" 2>"$TMP/sa.err"; echo $?; }
  sa_out() { grep -qxF -- "$1" "$TMP/sa.out"; }
  sa_has() { grep -qF -- "$1" "$TMP/sa.out"; }
  sa_err() { grep -qF -- "$1" "$TMP/sa.err"; }
  sa_reset() { rm -f "$SAC/models.json" "$SAC/model-strategy.json"; }
  sa_models() { printf '%s' "$1" > "$SAC/models.json"; }
  sa_legacy() { printf '%s' "$1" > "$SAC/model-strategy.json"; }
  sa_quiet() { [ ! -s "$TMP/sa.err" ]; }

  # S1 파일 없음
  sa_reset; eq "$(sa_cli subagent)" 0 "S1 rc 0"
  eq "$(cat "$TMP/sa.out")" "$(printf '%s\n' 'model=sonnet' 'effort=' "설정 파일: $SAC/models.json" \
    'subagent 모델: sonnet (기본값) · effort: 넘기지 않음 (미설정)')" "S1 stdout 네 줄 전문·순서(spec D3)"
  sa_quiet; chk $? "S1 stderr 비어 있음"
  eq "$(sa_cli subagent extra)" 1 "S1 인자를 주면 rc 1"
  sa_err "사용법" && [ ! -s "$TMP/sa.out" ]; chk $? "S1 인자 → 사용법·stdout 비어 있음"

  # S2 별칭 모델·단계 effort
  sa_reset; sa_models '{"subagent":{"claude":{"model":"opus","effort":"high"}}}'; sa_cli subagent >/dev/null
  sa_out "model=opus" && sa_out "effort=high" \
    && sa_out "subagent 모델: opus (models.json subagent.claude.model) · effort: high (models.json subagent.claude.effort)"; chk $? "S2 두 값·두 출처"
  cp "$TMP/sa.out" "$TMP/sa-s2.out"
  sa_quiet; chk $? "S2 stderr 비어 있음"

  # S3 고정 이름·무효 값·숫자
  sa_reset; sa_models '{"subagent":{"claude":{"model":"claude-opus-5-5"}}}'; sa_cli subagent >/dev/null
  sa_out "model=sonnet" && sa_err "고정 이름입니다" && sa_has "sonnet (기본값 — 경고 참조)"; chk $? "S3 고정 이름 → sonnet·「고정 이름입니다」"
  sa_models '{"subagent":{"claude":{"model":"gpt-5"}}}'; sa_cli subagent >/dev/null
  sa_out "model=sonnet" && sa_err "올바르지 않습니다: gpt-5"; chk $? "S3 gpt-5 → sonnet·「올바르지 않습니다」"
  sa_models '{"subagent":{"claude":{"model":3}}}'; sa_legacy '{"subagent":"haiku"}'; sa_cli subagent >/dev/null
  sa_out "model=sonnet" && sa_err "올바르지 않습니다: 3"; chk $? "S3 숫자 3 → sonnet·「올바르지 않습니다」"
  ! sa_err "옛 키"; chk $? "S3 숫자 3 → 옛 키로 내려가지 않음(옛 키 안내 없음)"

  # S4 default
  sa_reset; sa_models '{"subagent":{"claude":{"model":"default"}}}'; sa_cli subagent >/dev/null
  sa_out "model=" && sa_has "subagent 모델: 넘기지 않음 (default 지정"; chk $? "S4 default → model= 빈 값·표시"
  sa_quiet; chk $? "S4 stderr 비어 있음"

  # S5 옛 키
  sa_reset; sa_legacy '{"subagent":"haiku"}'; sa_cli subagent >/dev/null
  sa_out "model=haiku" && sa_err "ℹ️  subagent 모델을 model-strategy.json(옛 키)" \
    && sa_has "haiku (model-strategy.json subagent — 옛 키)"; chk $? "S5(a) models.json 없음 + 옛 키 → haiku·안내"
  sa_models '{"review":{"codex":{"effort":"high"}},"subagent":{"claude":{"effort":"medium"}}}'; sa_cli subagent >/dev/null
  sa_out "model=haiku" && sa_out "effort=medium" && sa_err "ℹ️  subagent 모델을 model-strategy.json(옛 키)"; chk $? "S5(e) 모델 칸 없음 → 옛 키 haiku + effort=medium"
  sa_models '{"review":{"codex":{"effort":"high"}},"subagent":{"claude":{"model":null,"effort":"medium"}}}'; sa_cli subagent >/dev/null
  sa_out "model=haiku" && sa_out "effort=medium" && sa_err "ℹ️  subagent 모델을 model-strategy.json(옛 키)"; chk $? "S5(f) 모델 null → 옛 키 haiku + effort=medium"
  sa_models '{"subagent":{"claude":{"model":"opus"}}}'; sa_cli subagent >/dev/null
  sa_out "model=opus" && sa_quiet; chk $? "S5(b) 두 파일 모두 → models.json(opus)·옛 키 안내 없음"
  rm -f "$SAC/models.json"; sa_legacy '{"subagent":"gpt-5"}'; sa_cli subagent >/dev/null
  sa_out "model=sonnet" && sa_err "model-strategy.json(옛 키) 의 subagent 값이 올바르지 않습니다: gpt-5"; chk $? "S5(c) 무효 옛 키 → sonnet·경고"
  sa_legacy '[]'; sa_cli subagent >/dev/null
  sa_out "model=sonnet" && sa_err "model-strategy.json 를 읽을 수 없습니다"; chk $? "S5(d) 옛 키 파일 [] → sonnet·읽기 경고"

  # S6 models.json 손상 — 옛 키로 내려가지 않는다
  sa_reset; sa_models '[]'; sa_legacy '{"subagent":"haiku"}'; sa_cli subagent >/dev/null
  sa_out "model=sonnet" && sa_out "effort=" && sa_err "해석할 수 없습니다" && ! sa_err "옛 키"; chk $? "S6 models.json [] → sonnet·effort 빈 값·옛 키 안내 없음"
  sa_has "effort: 넘기지 않음 (경고 참조)"; chk $? "S6 effort 표시 「경고 참조」"

  # S7 effort 변환
  sa_reset; sa_models '{"subagent":{"claude":{"model":"opus","effort":"ultra"}}}'; sa_cli subagent >/dev/null
  sa_out "effort=max" && sa_err "'ultra' 를 'max' 로 바꿉니다" && sa_has "ultra → max (models.json subagent.claude.effort)"; chk $? "S7 ultra → max(변환 경고)"
  sa_models '{"subagent":{"claude":{"model":"opus","effort":"lowest"}}}'; sa_cli subagent >/dev/null
  sa_out "effort=low" && sa_has "lowest → low (models.json subagent.claude.effort)"; chk $? "S7 lowest → low"
  sa_models '{"subagent":{"claude":{"model":"opus","effort":"default"}}}'; sa_cli subagent >/dev/null
  sa_out "effort=" && sa_has "effort: 넘기지 않음 (default 지정"; chk $? "S7 default → 빈 값·표시"
  sa_models '{"subagent":{"claude":{"model":"opus","effort":"huge"}}}'; sa_cli subagent >/dev/null
  sa_out "effort=" && sa_out "model=opus" && sa_err "effort 값이 올바르지 않습니다: huge" && sa_has "effort: 넘기지 않음 (경고 참조)"; chk $? "S7 huge → effort 빈 값·model=opus 유지·경고"

  # S8 set — 다른 칸 보존·고정 ID 거부
  sa_reset; sa_models '{"review":{"codex":{"effort":"high"}},"subagent":{"claude":{"model":"opus","effort":"low"}}}'
  eq "$(sa_cli set subagent.claude.model fable)" 0 "S8 set model fable rc 0"
  jq -e '.subagent.claude.model == "fable" and .subagent.claude.effort == "low"' "$SAC/models.json" >/dev/null; chk $? "S8 model 반영·다른 subagent 칸(effort) 보존"
  jq -e '.review.codex.effort == "high"' "$SAC/models.json" >/dev/null; chk $? "S8 review.codex.effort 그대로"
  eq "$(sa_cli set subagent.claude.effort medium)" 0 "S8 set effort medium rc 0"
  jq -e '.subagent.claude.effort == "medium" and .subagent.claude.model == "fable" and .review.codex.effort == "high"' "$SAC/models.json" >/dev/null; chk $? "S8 effort 반영·model·review 보존"
  cp "$SAC/models.json" "$TMP/sa-s8.bak"
  eq "$(sa_cli set subagent.claude.model claude-opus-5-5)" 1 "S8 고정 ID 저장 rc 1"
  cmp -s "$SAC/models.json" "$TMP/sa-s8.bak"; chk $? "S8 고정 ID 거부 → 파일 불변"
  sa_err "Agent 도구는 별칭만 받습니다" && sa_err "models.json 은 바꾸지 않았습니다"; chk $? "S8 고정 ID 거부 안내"

  # S8a null 저장
  sa_reset; sa_models '{"review":{"codex":{"effort":"high"}},"subagent":{"claude":{"model":"opus","effort":"high"}}}'
  eq "$(sa_cli set subagent.claude.effort null)" 0 "S8a set effort null rc 0"
  jq -e '.subagent.claude | has("effort") and .effort == null' "$SAC/models.json" >/dev/null; chk $? "S8a effort 키가 있고 JSON null"
  jq -e '.review.codex.effort == "high"' "$SAC/models.json" >/dev/null; chk $? "S8a review.codex.effort 그대로"
  jq -e '.subagent.claude.model == "opus"' "$SAC/models.json" >/dev/null; chk $? "S8a subagent.claude.model 그대로"
  sa_cli subagent >/dev/null
  sa_quiet && sa_out "effort=" && sa_has "effort: 넘기지 않음 (미설정)"; chk $? "S8a 이어서 subagent → stderr 없음·effort= ·미설정 표시"

  # S8b jq 없는 PATH 에서 set·apply
  printf '%s\n%s\n' 'models subagent.claude.model opus' 'models subagent.claude.effort low' > "$TMP/sa-list"
  sa_reset
  eq "$(PATH="$SANOJQ" sa_cli set subagent.claude.model opus)" 1 "S8b set(파일 없음) rc 1"
  sa_err "jq 가 없어 실행할 수 없습니다" && [ ! -s "$TMP/sa.out" ] && [ ! -e "$SAC/models.json" ]; chk $? "S8b set(파일 없음) stderr·stdout 비어 있음·파일 없음 유지"
  eq "$(PATH="$SANOJQ" sa_cli apply "$TMP/sa-list")" 1 "S8b apply(파일 없음) rc 1"
  sa_err "jq 가 없어 실행할 수 없습니다" && [ ! -s "$TMP/sa.out" ] && [ ! -e "$SAC/models.json" ]; chk $? "S8b apply(파일 없음) stderr·stdout 비어 있음·파일 없음 유지"
  sa_models '{"subagent":{"claude":{"model":"haiku"}}}'; cp "$SAC/models.json" "$TMP/sa-s8b.bak"
  eq "$(PATH="$SANOJQ" sa_cli set subagent.claude.model opus)" 1 "S8b set(기존 파일) rc 1"
  sa_err "jq 가 없어 실행할 수 없습니다" && [ ! -s "$TMP/sa.out" ] && cmp -s "$SAC/models.json" "$TMP/sa-s8b.bak"; chk $? "S8b set(기존 파일) stderr·stdout 비어 있음·파일 불변"
  eq "$(PATH="$SANOJQ" sa_cli apply "$TMP/sa-list")" 1 "S8b apply(기존 파일) rc 1"
  sa_err "jq 가 없어 실행할 수 없습니다" && [ ! -s "$TMP/sa.out" ] && cmp -s "$SAC/models.json" "$TMP/sa-s8b.bak"; chk $? "S8b apply(기존 파일) stderr·stdout 비어 있음·파일 불변"

  # S8c 설정 파일 경로 표시 (공백 경로·상대 경로)
  mkdir -p "$TMP/sa other" "$SAP/cfg"
  printf '%s' '{"subagent":{"claude":{"model":"opus"}}}' > "$TMP/sa other/m.json"; printf '%s' '{"subagent":{"claude":{"model":"opus"}}}' > "$SAP/cfg/m.json"
  RD_MODELS_CONFIG="$TMP/sa other/m.json" sa_cli subagent >/dev/null
  sa_out "설정 파일: $TMP/sa other/m.json" && sa_out "model=opus"; chk $? "S8c 공백 절대 경로(jq 있음)"
  RD_MODELS_CONFIG="cfg/m.json" sa_cli subagent >/dev/null
  sa_out "설정 파일: $SAP/cfg/m.json" && sa_out "model=opus"; chk $? "S8c 상대 경로 → \$PWD 를 붙이고 그 파일을 읽음(jq 있음)"
  if [ "$SAPY" = 1 ]; then
    RD_MODELS_CONFIG="$TMP/sa other/m.json" PATH="$SANOJQ" sa_cli subagent >/dev/null
    sa_out "설정 파일: $TMP/sa other/m.json" && sa_out "model=opus"; chk $? "S8c 공백 절대 경로(jq 없음)"
    RD_MODELS_CONFIG="cfg/m.json" PATH="$SANOJQ" sa_cli subagent >/dev/null
    sa_out "설정 파일: $SAP/cfg/m.json" && sa_out "model=opus"; chk $? "S8c 상대 경로 → \$PWD 를 붙이고 그 파일을 읽음(jq 없음)"
  fi

  # S8d apply 부분 실패 출력 순서
  sa_reset; sa_models '{"subagent":{"claude":{"model":"haiku","effort":"low"}}}'
  printf '%s\n%s\n' 'models subagent.claude.model opus' 'models subagent.claude.effort huge' > "$TMP/sa-list"
  eq "$(sa_cli apply "$TMP/sa-list")" 1 "S8d apply rc 1"
  case "$(sed -n 1p "$TMP/sa.out")" in 반영됨:*subagent.claude.model*) true ;; *) false ;; esac; chk $? "S8d 1행 반영됨(model)"
  case "$(sed -n 2p "$TMP/sa.out")" in 실패:*subagent.claude.effort*) true ;; *) false ;; esac; chk $? "S8d 2행 실패(effort)"
  case "$(sed -n 3p "$TMP/sa.out")" in 다시\ 실행:*subagent.claude.effort*) true ;; *) false ;; esac; chk $? "S8d 3행 다시 실행(effort)"
  case "$(sed -n 3p "$TMP/sa.out")" in *subagent.claude.model*) false ;; *) true ;; esac; chk $? "S8d 3행에 subagent.claude.model 없음"
  jq -e '.subagent.claude.model == "opus" and .subagent.claude.effort == "low"' "$SAC/models.json" >/dev/null; chk $? "S8d 파일 model opus·effort low 유지"

  # S9 jq 없이 S2 와 같은 네 줄
  if [ "$SAPY" = 1 ]; then
    sa_reset; sa_models '{"subagent":{"claude":{"model":"opus","effort":"high"}}}'
    PATH="$SANOJQ" sa_cli subagent >/dev/null
    eq "$(cat "$TMP/sa.out")" "$(cat "$TMP/sa-s2.out")" "S9 jq 없이도 S2 와 같은 네 줄(두 값·두 출처)"
  fi
  if [ "$SAPY" = 0 ]; then echo "env-skip: S9 — python3 없음" >&2; fi
}

case "${RD_TEST_ONLY:-}" in
  "") ;;
  example-copy)
    echo "=== 예시 복사 (example-copy) ==="
    example_copy_case "${RD_TEST_TREE:-$(cd "${script_dir}/../.." && pwd)}"
    finish ;;
  subagent)
    echo "=== 구현 subagent 칸 (subagent) ==="
    subagent_cli_case
    finish ;;
  *) echo "test_review_effort_override.sh: 알 수 없는 RD_TEST_ONLY 값: ${RD_TEST_ONLY}" >&2; exit 2 ;;
esac

# ============================================================
# 0) 선택 함수 (model_select.sh) — 계열 해석·값 판정·effort 변환·설정 읽기·조회·저장
#    HOME·CODEX_HOME 을 임시 경로로 바꾸고 고정 캐시 표본을 쓴다. 실제 ~/.codex 는 읽지 않는다.
# ============================================================
echo "=== 선택 함수 ==="

MS="${script_dir}/model_select.sh"
MS_SAMPLE="${script_dir}/fixtures/models_cache.sample.json"
MSH="$TMP/home"
mkdir -p "$MSH/.codex"
cp "$MS_SAMPLE" "$MSH/.codex/models_cache.json"
TAB="$(printf '\t')"

# ms <함수> <인자...> — HOME=$MSH 로 source 해 함수 하나를 부른다. stderr 는 $TMP/ms.err.
# 다른 홈이 필요하면 MS_HOME 을, Codex 홈은 호출 앞에 CODEX_HOME 을 붙인다.
ms() { ( export HOME="${MS_HOME:-$MSH}"; source "$MS"; "$@" ) 2>"$TMP/ms.err"; }
has_err() { grep -qF -- "$1" "$TMP/ms.err"; }

# --- U1·U2 계열 해석 (숨은 gpt-6.3-sol 이 표본에 있음) ---
eq "$(ms ms_codex_resolve_family sol)"   "gpt-6.2-sol"   "U1/U2 sol → gpt-6.2-sol (숨은 gpt-6.3-sol 제외)"
eq "$(ms ms_codex_resolve_family luna)"  "gpt-6-luna"    "U1 luna → gpt-6-luna (6 > 5.6)"
eq "$(ms ms_codex_resolve_family astra)" "gpt-6.2-astra" "U1 astra → gpt-6.2-astra"

# --- U3 버전은 정수 배열로 비교 (6.10 > 6.2) ---
mkdir -p "$TMP/h3/.codex"
jq '.models += [{"slug":"gpt-6.10-sol","visibility":"list","priority":50,
                 "supported_reasoning_levels":[{"effort":"low"}],"default_reasoning_level":"low"}]' \
  "$MS_SAMPLE" > "$TMP/h3/.codex/models_cache.json"
eq "$(MS_HOME="$TMP/h3" ms ms_codex_resolve_family sol)" "gpt-6.10-sol" "U3 gpt-6.10-sol 이 gpt-6.2-sol 보다 새 버전"

# --- U4 해석 실패 ---
out="$(ms ms_codex_resolve_family nosuch)"; rc=$?
eq "$out|$rc" "|1" "U4 없는 계열 → 빈 값·rc 1"
has_err "계열 'nosuch'"; chk $? "U4 없는 계열 경고 문구"
mkdir -p "$TMP/h4/.codex"
out="$(MS_HOME="$TMP/h4" ms ms_codex_resolve_family sol)"; rc=$?
eq "$out|$rc" "|1" "U4 캐시 없음 → 빈 값·rc 1"
has_err "$TMP/h4/.codex/models_cache.json"; chk $? "U4 캐시 없음 경고에 캐시 경로"
eq "$(ms ms_codex_resolve_family reserve)" "" "U4 버전 없는 gpt-reserve 는 계열 후보가 아님"

# --- U5 CODEX_HOME 하나로 캐시·config.toml·경고 경로를 정함 ---
mkdir -p "$TMP/h5home/.codex" "$TMP/h2"
cp "$MS_SAMPLE" "$TMP/h5home/.codex/models_cache.json"
printf 'model = "gpt-6.1-sol"\n' > "$TMP/h5home/.codex/config.toml"
printf '{"models":[{"slug":"gpt-9-sol","visibility":"list","priority":1,"supported_reasoning_levels":[{"effort":"high"}]}]}\n' \
  > "$TMP/h2/models_cache.json"
printf 'model = "gpt-9-sol"\n' > "$TMP/h2/config.toml"
eq "$(MS_HOME="$TMP/h5home" CODEX_HOME="$TMP/h2" ms ms_codex_resolve_family sol)" "gpt-9-sol" "U5 CODEX_HOME 의 캐시를 씀"
eq "$(MS_HOME="$TMP/h5home" CODEX_HOME="$TMP/h2" ms ms_codex_config_model)"     "gpt-9-sol" "U5 CODEX_HOME 의 config.toml 을 씀"
MS_HOME="$TMP/h5home" CODEX_HOME="$TMP/h2" ms ms_codex_resolve_family nosuch >/dev/null
has_err "$TMP/h2/"; chk $? "U5 경고 문구의 경로가 CODEX_HOME"

# --- U6 값 판정 ---
while IFS='|' read -r t k v want; do
  eq "$(ms ms_classify "$t" "$k" "$v")" "$want" "U6 classify $t $k [$v] → $want"
done <<'U6_TABLE'
codex|model|gpt-6.2-sol|pinned
claude|model|claude-opus-5-5|pinned
claude|model|opus|alias
codex|model|Sol|invalid
codex|effort|ultra|step
codex|effort|highest|relative
claude|effort|default|default
codex|model||invalid
U6_TABLE

# --- U7 effort 변환 — 결과값과 경고 ---
u7() { # u7 <tool> <값> <지원 단계> <기대값> <경고 기대: 낮춤|해석|없음> <이름>
  local out; out="$(ms ms_convert_effort "$1" "$2" "$3")"
  eq "$out" "$4" "$6"
  case "$5" in
    낮춤) has_err "'$2' 를 '$4' 로 바꿉니다"; chk $? "$6 — 낮춤 경고" ;;
    해석) has_err "'$2' 를 해석하지 못했습니다"; chk $? "$6 — 해석 실패 경고" ;;
    없음) ! has_err "⚠️"; chk $? "$6 — 경고 없음" ;;
  esac
}
u7 codex  ultra   "low medium high xhigh max"       max    낮춤 "U7 codex ultra → 바로 아래 max"
u7 codex  low     "medium high"                     medium 낮춤 "U7 codex low → 아래가 없으면 최저 지원 단계"
u7 codex  highest "low medium high xhigh max ultra" ultra  없음 "U7 codex highest → 최고 단계"
u7 codex  lowest  ""                                ""     해석 "U7 codex 상대어 + 모델 정보 없음 → 미전달"
u7 codex  xhigh   ""                                xhigh  없음 "U7 codex 단계 + 모델 정보 없음 → 그대로"
u7 claude ultra   ""                                max    낮춤 "U7 claude ultra → max"
u7 claude lowest  ""                                low    없음 "U7 claude lowest → low"

# --- U8 config.toml 최상위 model ---
mkdir -p "$TMP/h8/.codex" "$TMP/h8b/.codex"
printf 'model = "gpt-6.1-sol"\nmodel_reasoning_effort = "high"\n\n[features]\nmodel = "x"\n' > "$TMP/h8/.codex/config.toml"
printf "model = 'gpt-6-luna'\n" > "$TMP/h8b/.codex/config.toml"
eq "$(MS_HOME="$TMP/h8"  ms ms_codex_config_model)" "gpt-6.1-sol" "U8 첫 [ 절 앞의 model 만 읽음"
eq "$(MS_HOME="$TMP/h8b" ms ms_codex_config_model)" "gpt-6-luna"  "U8 작은따옴표(리터럴 문자열) model"

# --- U9~U13 models.json 읽기 ---
mj() { printf '%s' "$2" > "$TMP/mj_$1.json"; printf '%s' "$TMP/mj_$1.json"; }
f="$(mj u9 '{"session":{}}')"
out="$(ms ms_load_models "$f" request-review)"; rc=$?
eq "$out|$rc" "|0" "U9 review 절 없음 → 빈 출력·rc 0"
[ ! -s "$TMP/ms.err" ]; chk $? "U9 경고 없음"
for spec in 'empty|' 'brace|{' 'concat|{}{"review":{"claude":{"model":"opus"}}}'; do
  name="${spec%%|*}"; body="${spec#*|}"
  f="$(mj "u10_$name" "$body")"
  out="$(ms ms_load_models "$f" request-review)"
  eq "$out" "" "U10 손상($name) → 빈 출력"
  has_err "models.json 을 읽지 못했습니다($f)"; chk $? "U10 손상($name) → D6 경고"
done
f="$(mj u11 '{"review":{"codex":true,"claude":{"model":"opus"}}}')"
eq "$(ms ms_load_models "$f" request-review)" "review.claude.model${TAB}ok${TAB}opus" "U11 무효 절 밖의 칸은 남음"
has_err "review.codex"; chk $? "U11 review.codex 절 무효 경고"
f="$(mj u12 '{"review":{"claude":{"model":3,"effort":""}}}')"
eq "$(ms ms_load_models "$f" request-review | cut -f1,2 | tr '\n' ' ')" \
   "review.claude.model${TAB}invalid review.claude.effort${TAB}invalid " "U12 숫자·빈 문자열 → invalid"
f="$(mj u13 '{"review":{"codex":{"review_types":{"request-review":{"effort":"high"}}}}}')"
eq "$(ms ms_load_models "$f" request-review)" "review.codex.review_type_effort${TAB}ok${TAB}high" "U13 현재 리뷰 종류의 칸만 냄"
eq "$(ms ms_load_models "$f" diff-review)" "" "U13 다른 리뷰 종류면 행 없음"

# --- U21 Codex·Claude 가 아닌 도구(adapter-interface.md 로 추가한 어댑터 mytool)는 선택하지 않음 (Claude 환경 변수를 빌려 쓰지 않고 Codex 계열 해석도 하지 않음) ---
u21="$( ( export HOME="$MSH" RD_MODELS_CONFIG="$TMP/no_models.json" RD_REVIEW_CLAUDE_MODEL=nosuch RD_REVIEW_CLAUDE_EFFORT=high
          source "$MS"; ms_resolve_review mytool other request-review
          printf '%s|%s|%s|%s' "$MS_MODEL_VALUE" "$MS_MODEL_SOURCE" "$MS_EFFORT_VALUE" "$MS_EFFORT_SOURCE" ) 2>"$TMP/ms.err" )"
eq "$u21" "|cli-default||global" "U21 mytool → 모델·effort 값 없음 (cli-default·global)"
! has_err "계열";                 chk $? "U21 mytool → Codex 계열 경고 없음"
printf '{"default_priority":["mytool","claude"],"tools":{"mytool":{"model":"my-model"},"claude":{"model":"sonnet"}}}' > "$TMP/u21b.json"
u21b="$( ( export HOME="$MSH" RD_MODELS_CONFIG="$TMP/no_models.json" RD_REVIEW_CLAUDE_MODEL=opus
           source "$MS"; ms_load_legacy "$TMP/u21b.json" request-review; ms_resolve_review mytool other request-review
           printf '%s|%s|%s' "$MS_MODEL_VALUE" "$MS_MODEL_SOURCE" "$MS_EFFORT_VALUE" ) 2>"$TMP/ms.err" )"
eq "$u21b" "my-model|review-tools.json|" "U21b mytool → tools.mytool.model 을 그대로 넘김 (Claude 칸·환경 변수 아님)"
u21r="$( ( source "${script_dir}/run_review_turn.sh" 2>/dev/null; set +e
           MODEL_VALUE=my-model; MODEL_ORIGIN="file:$TMP/u21b.json#tools.mytool.model"; REVIEW_JQ_MISSING=0
           print_selection_recovery mytool "confirmed model" ) 2>&1 )"
printf '%s' "$u21r" | grep -qF "tools.mytool.model"; chk $? "U21b mytool 모델 거부 안내가 tools.mytool.model 을 가리킴"
! printf '%s' "$u21r" | grep -q "RD_REVIEW_";      chk $? "U21b mytool 안내에 RD_REVIEW_* 없음"

# --- CLI: 임시 프로젝트에 model_select.sh 를 복사해 기본 경로가 임시 폴더가 되게 한다 ---
MSP="$TMP/msp"
mkdir -p "$MSP/rd-workflow/scripts" "$MSP/rd-workflow/config"
cp "$MS" "$MSP/rd-workflow/scripts/model_select.sh"
MSC="$MSP/rd-workflow/config"
MSCLI="$MSP/rd-workflow/scripts/model_select.sh"
# U15 준비: (d) 가 이 예시를 쓰지 않는지 확인하는 데만 쓴다.
printf '{"version":1,"review":{"codex":{"small_task_effort":"medium"}}}\n' > "$MSC/models.json.example"
# cli <인자...> → rc 출력. stdout·stderr 는 $TMP/cli.out·$TMP/cli.err.
cli() { ( cd "$MSP" && HOME="$MSH" bash "$MSCLI" "$@" ) >"$TMP/cli.out" 2>"$TMP/cli.err"; echo $?; }
cli_out() { grep -qxF -- "$1" "$TMP/cli.out"; }
cli_err() { grep -qF -- "$1" "$TMP/cli.err"; }
clean_cfg() { rm -f "$MSC/models.json" "$MSC/review-tools.json"; }

# --- U14 show review <종류> ---
clean_cfg
printf '{"version":1,"review":{"codex":{"effort":"high"},"claude":{"model":"Opus"}}}' > "$MSC/models.json"
printf '{"default_priority":["codex","claude"],"tools":{"codex":{"small_task_reasoning_effort":"medium"},"claude":{"model":"sonnet"}}}' \
  > "$MSC/review-tools.json"
rc="$(RD_REVIEW_CODEX_EFFORT=max cli show review request-review)"
eq "$rc" "0" "U14 show review rc 0"
cli_out "Codex effort: high — models.json";                                chk $? "U14 models.json 칸 → — models.json"
cli_out "Codex small-task effort: medium — review-tools.json (옛 키)";      chk $? "U14 옛 키만 있는 칸 → (옛 키)"
cli_out "Codex 모델: - — 미설정";                                           chk $? "U14 없는 칸 → 미설정"
cli_out "Claude 모델: sonnet — review-tools.json (옛 키)";                  chk $? "U14 무효 새 칸(Opus) → 옛 키 sonnet"
! grep -q 'max' "$TMP/cli.out";                                            chk $? "U14 환경 변수 RD_REVIEW_CODEX_EFFORT 는 표에 반영되지 않음"
clean_cfg
printf '{"review":{"codex":{"effort":"medium","review_types":{"diff-review":{"effort":"xhigh"}}}}}' > "$MSC/models.json"
cli show review >/dev/null
cli_out "Codex effort: medium — models.json";              chk $? "U14 종류별 칸이 기본 Codex effort 칸을 가리지 않음"
cli_out "Codex effort (diff-review): xhigh — models.json"; chk $? "U14 diff-review 종류별 칸"

# --- U16 show review (종류 생략) — 옛 종류 열거·옛 설정 손상 ---
clean_cfg
printf '{"default_priority":["codex","claude"],"overrides":{"_comment":"x","diff-review":{"tools":{"codex":{"reasoning_effort":"high"}}}}}' \
  > "$MSC/review-tools.json"
cli show review >/dev/null
cli_out "Codex effort (diff-review): high — review-tools.json (옛 키)"; chk $? "U16 옛 설정의 종류별 effort 를 열거"
printf '{"default_priority":"codex","tools":{"claude":{"model":"sonnet"}}}' > "$MSC/review-tools.json"
cli show review >/dev/null
cli_err "설정 파일 파싱 실패";            chk $? "U16 옛 설정 파싱 실패 경고"
cli_out "Claude 모델: - — 미설정";        chk $? "U16 옛 설정 파싱 실패 → 옛 칸 모두 미설정"

# --- U18 kill switch 줄 ---
clean_cfg
cli show review >/dev/null
cli_out "kill switch: RD_REVIEW_EFFORT_OVERRIDE=미설정 (적용 중)"; chk $? "U18 kill switch 미설정"
RD_REVIEW_EFFORT_OVERRIDE=0 cli show review >/dev/null
cli_out "kill switch: RD_REVIEW_EFFORT_OVERRIDE=0 (무력화됨)";   chk $? "U18 kill switch 0"
RD_REVIEW_EFFORT_OVERRIDE=yes cli show review >/dev/null
cli_out "kill switch: RD_REVIEW_EFFORT_OVERRIDE=yes (무력화됨 · 인식 불가 값)"; chk $? "U18 kill switch 인식 불가 값"

# --- U15 set ---
clean_cfg
printf '{"version":1,"review":{"claude":{"model":"opus"}},"session":{"model":"sonnet"}}' > "$MSC/models.json"
eq "$(cli set review.codex.effort high)" "0" "U15(a) set rc 0"
eq "$(jq -r '[.review.codex.effort, .review.claude.model, .session.model] | join(",")' "$MSC/models.json")" \
   "high,opus,sonnet" "U15(a) 지정 칸만 바꾸고 다른 칸·최상위 절 보존"
printf '{}{"review":{}}' > "$MSC/models.json"; cp "$MSC/models.json" "$TMP/orig.json"
eq "$(cli set review.codex.effort high)" "1" "U15(b) 이어 붙은 값 2개 → rc 1"
cli_err "$MSC/models.json";                 chk $? "U15(b) 경고에 파일 경로"
cmp -s "$MSC/models.json" "$TMP/orig.json"; chk $? "U15(b) 원본 그대로"
printf '{"review":{"codex":true}}' > "$MSC/models.json"; cp "$MSC/models.json" "$TMP/orig.json"
eq "$(cli set review.codex.effort high)" "1" "U15(c) 상위 칸이 객체가 아님 → rc 1"
cli_err "$MSC/models.json" && cli_err "review.codex"; chk $? "U15(c) 경고에 파일 경로와 review.codex"
cmp -s "$MSC/models.json" "$TMP/orig.json"; chk $? "U15(c) 원본 그대로"
clean_cfg
eq "$(cli set review.claude.model haiku)" "0" "U15(d) 파일 없음 → rc 0"
eq "$(jq -c . "$MSC/models.json")" '{"version":1,"review":{"claude":{"model":"haiku"}}}' \
   "U15(d) {\"version\":1} 에서 시작 (예시 파일을 쓰지 않음)"
perm_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
eq "$(perm_of "$MSC/models.json")" "644" "U15(i) 새 파일 권한 0644 (임시 파일의 0600 을 옮기지 않음)"
chmod 640 "$MSC/models.json"
eq "$(cli set review.codex.effort medium)" "0" "U15(i) 0640 파일 set rc 0"
eq "$(perm_of "$MSC/models.json")" "640" "U15(i) 기존 파일 권한 0640 유지"
mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/fakebin/mv"; chmod +x "$TMP/fakebin/mv"
clean_cfg
eq "$(PATH="$TMP/fakebin:$PATH" cli set review.claude.model haiku)" "1" "U15(f) 옮기기 실패 → rc 1"
[ ! -e "$MSC/models.json" ];      chk $? "U15(f) models.json 이 생기지 않음"
[ ! -e "$MSC/models.json.lock" ]; chk $? "U15(f) 잠금 폴더가 남지 않음"
cli_err "옮기지 못함";            chk $? "U15(f) 경고에 옮기지 못함"
printf '{"version":1,"review":{"claude":{"model":"sonnet"}}}' > "$MSC/models.json"; cp "$MSC/models.json" "$TMP/orig.json"
eq "$(PATH="$TMP/fakebin:$PATH" cli set review.claude.model haiku)" "1" "U15(e) 기존 원본 + 옮기기 실패 → rc 1"
cli_err "옮기지 못함";                      chk $? "U15(e) 경고에 옮기지 못함"
cmp -s "$MSC/models.json" "$TMP/orig.json"; chk $? "U15(e) 원본 그대로"
[ ! -e "$MSC/models.json.lock" ];           chk $? "U15(e) 잠금 폴더가 남지 않음"
eq "$(cli set review.claude.model Opus)" "1" "U15(g) 무효 값 → rc 1"
cli_err "review.claude.model";              chk $? "U15(g) 경고에 칸 이름"
cmp -s "$MSC/models.json" "$TMP/orig.json"; chk $? "U15(g) 원본 그대로"
eq "$(cli set review.claude.model null)"    "0" "U15(g) null(칸 비우기) 허용"
eq "$(cli set review.codex.effort default)" "0" "U15(g) default(의도적 미전달) 허용"
eq "$(RD_MODELS_CONFIG="$TMP/nodir/sub/models.json" cli set review.codex.effort high)" "1" "U15(h) 상위 폴더 없음 → rc 1"
cli_err "잠금을 만들지 못했습니다" && cli_err "$TMP/nodir/sub"; chk $? "U15(h) 잠금 생성 실패 안내와 상위 폴더 경로"
! cli_err "다른 저장이 진행 중";  chk $? "U15(h) 점유 안내를 내지 않음"
mkdir -p "$TMP/dircfg/models.json"
eq "$(RD_MODELS_CONFIG="$TMP/dircfg/models.json" cli set review.claude.model opus)" "1" "U15(j) 설정 경로가 폴더 → rc 1"
cli_err "일반 파일이 아님" && cli_err "$TMP/dircfg/models.json"; chk $? "U15(j) 일반 파일이 아님 안내와 경로"
eq "$(find "$TMP/dircfg" -mindepth 1 | sort | tr '\n' ' ')" "$TMP/dircfg/models.json " "U15(j) 임시 파일·잠금이 남지 않음"
mkdir -p "$TMP/lnk/real"; printf '{"version":1}' > "$TMP/lnk/real/actual.json"; ln -s real/actual.json "$TMP/lnk/models.json"
eq "$(RD_MODELS_CONFIG="$TMP/lnk/models.json" cli set review.claude.model sonnet)" "0" "U15(k) 심볼릭 링크 경로 set → rc 0"
[ -L "$TMP/lnk/models.json" ]; chk $? "U15(k) 링크가 링크로 남음"
eq "$(jq -r '.review.claude.model' "$TMP/lnk/real/actual.json")" "sonnet" "U15(k) 실제 파일에 씀"
eq "$(find "$TMP/lnk" -mindepth 1 | sort | tr '\n' ' ')" "$TMP/lnk/models.json $TMP/lnk/real $TMP/lnk/real/actual.json " "U15(k) 임시 파일·잠금이 남지 않음"

# --- U17 잠금 점유 ---
printf '{"version":1}' > "$MSC/models.json"; cp "$MSC/models.json" "$TMP/orig.json"
mkdir "$MSC/models.json.lock"
eq "$(cli set review.codex.effort high)" "1" "U17 잠금 점유 → rc 1"
cli_err "$MSC/models.json.lock";            chk $? "U17 경고에 잠금 경로"
cmp -s "$MSC/models.json" "$TMP/orig.json"; chk $? "U17 원본 그대로"
[ -d "$MSC/models.json.lock" ];             chk $? "U17 남의 잠금을 지우지 않음"
rmdir "$MSC/models.json.lock"
eq "$(cli set review.codex.effort high)" "0" "U17 잠금 해제 뒤 set rc 0"
[ ! -e "$MSC/models.json.lock" ];           chk $? "U17 정상 set 뒤 잠금 없음"

# --- U19 set-legacy ---
clean_cfg
eq "$(cli set-legacy default_priority '["claude","codex"]')" "0" "U19(a) 파일 없음 → rc 0"
eq "$(jq -c . "$MSC/review-tools.json")" '{"default_priority":["claude","codex"]}' "U19(a) 지정 칸으로 파일 생성"
clean_cfg
eq "$(cli set-legacy tools.codex.bin '"g"')" "0" "U19(e) 파일 없음 → rc 0"
eq "$(jq -c .default_priority "$MSC/review-tools.json")" '["codex","claude"]' "U19(e) 기본 우선순위에서 시작"
leg="$( ( source "$MS"; ms_load_legacy "$MSC/review-tools.json" request-review; printf '%s' "$MS_LEGACY_KV" ) 2>"$TMP/ms.err")"
! has_err "파싱 실패";                                    chk $? "U19(e) 지금 로더가 파싱 실패 없이 읽음"
printf '%s\n' "$leg" | grep -qxF "priority${TAB}codex claude"; chk $? "U19(e) priority 행"
printf '%s\n' "$leg" | grep -qxF "tool.codex.bin${TAB}g";      chk $? "U19(e) tool.codex.bin 행"
printf '{"default_priority":["codex"],"tools":{"claude":{"model":"sonnet"}}}' > "$MSC/review-tools.json"
eq "$(cli set-legacy tools.codex.bin '"g"')" "0" "U19(b) 기존 파일 → rc 0"
eq "$(jq -r '.tools.claude.model' "$MSC/review-tools.json")" "sonnet" "U19(b) 옛 tools.claude.model 보존"
cp "$MSC/review-tools.json" "$TMP/orig.json"
eq "$(cli set-legacy tools.codex.reasoning_effort '"high"')" "1" "U19(c) 허용 밖 경로 → rc 1"
cmp -s "$MSC/review-tools.json" "$TMP/orig.json"; chk $? "U19(c) 원본 그대로"
eq "$(cli set-legacy tools.gemini.model '"g"')" "1" "U19(f) 어댑터 없는 gemini 칸 → rc 1"
cmp -s "$MSC/review-tools.json" "$TMP/orig.json"; chk $? "U19(f) 원본 그대로"
eq "$(cli set-legacy tools.gemini.bin '"/usr/bin/true"')" "1" "U19(g) 어댑터 없는 gemini 실행 파일 칸 → rc 1"
cmp -s "$MSC/review-tools.json" "$TMP/orig.json"; chk $? "U19(g) 원본 그대로"
printf '{"default_priority":' > "$MSC/review-tools.json"; cp "$MSC/review-tools.json" "$TMP/orig.json"
eq "$(cli set-legacy tools.codex.bin '"g"')" "1" "U19(d) 손상 파일 → rc 1"
cmp -s "$MSC/review-tools.json" "$TMP/orig.json"; chk $? "U19(d) 원본 그대로"

# --- U20 apply — 공백이 든 설정 경로, 둘째 줄 실패 ---
clean_cfg
SPC="$TMP/my cfg"; mkdir -p "$SPC"
printf 'models review.claude.model haiku\nlegacy tools.claude.bin "x"\nmodels review.codex.effort high\n' > "$TMP/apply.list"
mkdir "$SPC/review-tools.json.lock"
rc="$(RD_MODELS_CONFIG="$SPC/models.json" REVIEW_TOOLS_CONFIG="$SPC/review-tools.json" cli apply "$TMP/apply.list")"
eq "$rc" "1" "U20 중간 실패 → rc 1"
eq "$(grep -c '^반영됨: ' "$TMP/cli.out")|$(grep -c '^실패: ' "$TMP/cli.out")|$(grep -c '^미적용: ' "$TMP/cli.out")" \
   "1|1|1" "U20 반영됨·실패·미적용 각 1줄"
eq "$(jq -r '.review.codex.effort // "없음"' "$SPC/models.json")" "없음" "U20 첫 실패에서 멈춤 (셋째 칸 미반영)"
retry="$(sed -n 's/^다시 실행: //p' "$TMP/cli.out")"
( cd "$TMP" && env -u RD_MODELS_CONFIG -u REVIEW_TOOLS_CONFIG HOME="$MSH" bash -c "$retry" ) >/dev/null 2>&1
[ $? -ne 0 ]; chk $? "U20c 재시도 중 재실패 → rc≠0"
eq "$(jq -r '.review.codex.effort // "없음"' "$SPC/models.json")" "없음" "U20c 재실패 뒤 셋째 칸 미반영"
rmdir "$SPC/review-tools.json.lock"
( cd "$TMP" && env -u RD_MODELS_CONFIG -u REVIEW_TOOLS_CONFIG HOME="$MSH" bash -c "$retry" ) >/dev/null 2>&1
chk $? "U20b 다른 작업 폴더에서 다시 실행 → rc 0"
eq "$(jq -r '.review.codex.effort // "없음"' "$SPC/models.json")" "high" "U20b 셋째 칸까지 반영"
eq "$(jq -r '.tools.claude.bin | type + ":" + .' "$SPC/review-tools.json" 2>/dev/null)" "string:x" "U20b tools.claude.bin 이 문자열 x"
[ ! -e "$MSC/models.json" ] && [ ! -e "$MSC/review-tools.json" ]; chk $? "U20b 기본 경로에는 파일이 생기지 않음"

# --- U20d apply — 형식이 틀린 줄이 있으면 아무 칸도 쓰지 않음 ---
rm -f "$SPC/models.json"
printf 'models review.claude.model sonnet\ntypo review.claude.effort high\nmodels review.claude.effort high\n' > "$TMP/bad.list"
rc="$(RD_MODELS_CONFIG="$SPC/models.json" REVIEW_TOOLS_CONFIG="$SPC/review-tools.json" cli apply "$TMP/bad.list")"
eq "$rc" "1" "U20d 형식 오류 줄 → rc 1"
[ ! -e "$SPC/models.json" ]; chk $? "U20d 앞의 정상 줄도 쓰지 않음"
cli_err "2번째 줄" && cli_err "typo review.claude.effort high"; chk $? "U20d 안내에 줄 번호와 줄 내용"
! grep -q '^반영됨: ' "$TMP/cli.out"; chk $? "U20d 반영됨 줄 없음"
printf 'models review.claude.model opus\nmodels  review.claude.effort high\n' > "$TMP/bad2.list"
rc="$(RD_MODELS_CONFIG="$SPC/models.json" REVIEW_TOOLS_CONFIG="$SPC/review-tools.json" cli apply "$TMP/bad2.list")"
eq "$rc" "1" "U20e 구분 공백이 둘인 줄 → rc 1"
[ ! -e "$SPC/models.json" ]; chk $? "U20e 앞의 정상 줄도 쓰지 않음"
cli_err "2번째 줄"; chk $? "U20e 안내에 줄 번호"
printf 'models review.claude.model opus\n' > "$TMP/noread.list"; chmod 000 "$TMP/noread.list"
rc="$(RD_MODELS_CONFIG="$SPC/models.json" REVIEW_TOOLS_CONFIG="$SPC/review-tools.json" cli apply "$TMP/noread.list")"
chmod 644 "$TMP/noread.list"
eq "$rc" "1" "U20f 읽지 못하는 목록 → rc 1"
cli_err "읽지 못했습니다" && cli_err "$TMP/noread.list"; chk $? "U20f 안내에 목록 경로"

# --- D2 /review-config skill 의 저장 명령 — 본문 펜스 블록의 표지 주석 다음 줄을 그대로 실행한다 ---
SKILL_MD="${script_dir}/../claude_skills/review-config/SKILL.md"
skill_line() { awk -v m="# rd:$1" '{ t = $0; sub(/^[ \t]+/, "", t) } t == m { if ((getline n) > 0) { sub(/^[ \t]+/, "", n); print n }; exit }' "$SKILL_MD"; }
clean_cfg
printf '{"version":1,"review":{"claude":{"model":"opus"}},"session":{"model":"sonnet"}}' > "$MSC/models.json"
line="$(skill_line review-config-write)"
[ -n "$line" ]; chk $? "D2 skill 에 rd:review-config-write 표지 줄이 있음"
( cd "$MSP" && HOME="$MSH" bash -c "$line" ) >/dev/null 2>&1
eq "$(jq -r '[.review.codex.effort, .review.claude.model, .session.model] | join(",")' "$MSC/models.json")" \
   "high,opus,sonnet" "D2 skill 쓰기 명령이 model_select.sh set 으로 U15(a) 와 같은 결과"

# --- D2e skill 완료 메시지는 apply 가 성공할 때만 ---
line="$(skill_line review-config-apply)"
[ -n "$line" ]; chk $? "D2e skill 에 rd:review-config-apply 표지 줄이 있음"
rm -f "$SPC/models.json" "$SPC/review-tools.json"; mkdir "$SPC/review-tools.json.lock"
( cd "$MSP" && HOME="$MSH" RD_MODELS_CONFIG="$SPC/models.json" REVIEW_TOOLS_CONFIG="$SPC/review-tools.json" \
    list="$TMP/apply.list" bash -c "$line" ) >"$TMP/d2e.out" 2>&1
rmdir "$SPC/review-tools.json.lock"
grep -q '^실패: ' "$TMP/d2e.out";  chk $? "D2e apply 가 실제로 돌아 실패 줄을 냄"
! grep -q '저장 완료' "$TMP/d2e.out"; chk $? "D2e apply 실패 → 완료 메시지 없음"

# --- D5 review-tools.json.example 에서 옮긴 키는 없고, 이 파일이 맡는 키는 남음 (REQUEST AC11) ---
RTX="${script_dir}/../config/review-tools.json.example"
rtx_paths() { jq "[paths | map(tostring) | select($1)] | length" "$RTX" 2>/dev/null; }
eq "$(rtx_paths '. == ["tools","codex","reasoning_effort"]')"            "0" "D5 tools.codex.reasoning_effort 없음"
eq "$(rtx_paths '. == ["tools","codex","small_task_reasoning_effort"]')" "0" "D5 tools.codex.small_task_reasoning_effort 없음"
eq "$(rtx_paths '. == ["tools","claude","model"]')"                      "0" "D5 tools.claude.model 없음"
eq "$(rtx_paths 'length == 5 and .[0] == "overrides" and .[2:] == ["tools","codex","reasoning_effort"]')" \
   "0" "D5 overrides.*.tools.codex.reasoning_effort 없음"
eq "$(jq 'has("default_priority")' "$RTX" 2>/dev/null)"               "true" "D5 default_priority 남음"
eq "$(jq '.tools.codex | has("bin")' "$RTX" 2>/dev/null)"             "true" "D5 tools.codex.bin 남음"
eq "$(jq '.tools.claude | has("bin")' "$RTX" 2>/dev/null)"            "true" "D5 tools.claude.bin 남음"
eq "$(jq '.tools.claude | has("self_review_policy")' "$RTX" 2>/dev/null)" "true" "D5 tools.claude.self_review_policy 남음"

# ============================================================
# 1) 해석 우선순위 (AC 1~8) — run_review_turn.sh 를 source 해 함수만 쓴다
# ============================================================
echo "=== 해석 우선순위 ==="

cfg() { printf '%s' "$2" > "$TMP/$1.json"; }
cfg full '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high","small_task_reasoning_effort":"medium"}},
 "overrides":{"request-review":{"tools":{"codex":{"reasoning_effort":"xhigh"}}}}}'
cfg lowfloor '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high","small_task_reasoning_effort":"low"}}}'
cfg minfloor '{"default_priority":["codex","claude"],
 "tools":{"codex":{"small_task_reasoning_effort":"minimal"}}}'
cfg nostkey '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high"}}}'
cfg same '{"default_priority":["codex","claude"],
 "tools":{"codex":{"reasoning_effort":"high"}},
 "overrides":{"request-review":{"tools":{"codex":{"reasoning_effort":"high"}}}}}'
cfg empty '{"default_priority":["codex","claude"],"tools":{"codex":{"bin":null}}}'

mk_session() { # $1=이름 $2=execution-path (빈 값이면 `## Review Scope` 자체 없음 = legacy)
  mkdir -p "$TMP/$1"
  { printf '# Review Session\n\n## Status\nawaiting-reviewer\n\n## Branch Context\n- fr-branch: null\n'; } > "$TMP/$1/SESSION.md"
  [ -n "$2" ] && printf '\n## Review Scope\n- execution-path: %s\n' "$2" >> "$TMP/$1/SESSION.md"
  printf '%s' "$TMP/$1/SESSION.md"
}
S_SMALL="$(mk_session s_small small-task)"
S_OTHER="$(mk_session s_other other)"
S_LEGACY="$(mk_session s_legacy '')"

# 서브셸에서 판정만 수행하고 `값|source|rejected|경고유무` 를 출력한다.
# 판정은 실행기와 같은 공용 선택 함수 ms_resolve_review 가 한다(옛 설정만 둔 표본 — models.json 없음).
# 주의: ms_resolve_review 를 command substitution 으로 감싸면 서브셸이 되어
# MS_* 할당이 소실된다. 직접 호출하고 경고만 파일로 캡처한다.
resolve() { # resolve <config> <session-file> <kill: unset|값> <review_type>
  (
    export REVIEW_TOOLS_CONFIG="$TMP/$1.json" RD_MODELS_CONFIG="$TMP/no_models.json" HOME="$MSH"
    if [ "$3" = "unset" ]; then unset RD_REVIEW_EFFORT_OVERRIDE; else export RD_REVIEW_EFFORT_OVERRIDE="$3"; fi
    source "${script_dir}/run_review_turn.sh" 2>/dev/null
    set +e   # source 대상이 set -e 를 켜므로 다시 해제한다
    review_type="$4"
    load_review_config_once 2>/dev/null
    ms_resolve_review codex "$(read_execution_path "$2")" "$4" 2>"$TMP/warn.txt"
    w=none; [ -s "$TMP/warn.txt" ] && w=warn
    printf '%s|%s|%s|%s' "$MS_EFFORT_VALUE" "$MS_EFFORT_SOURCE" "$MS_EFFORT_REJECTED" "$w"
  )
}

eq "$(resolve empty    "$S_OTHER"  unset request-review)" "|global||none"          "AC2 설정 전무 → 미전달 (후퇴 없음)"
eq "$(resolve full     "$S_OTHER"  0     request-review)" "|kill-switch||none"     "AC3 kill switch 0 → 미전달, 경고 없음"
eq "$(resolve full     "$S_OTHER"  yes   request-review)" "|kill-switch||warn"     "AC4 kill switch 인식 불가 값 → 경고 + 미전달"
eq "$(resolve full     "$S_SMALL"  unset request-review)" "medium|small-task||none" "AC5 small-task 가 review type override 를 이김"
eq "$(resolve nostkey  "$S_SMALL"  unset request-review)" "high|tool-default||none" "AC6 small-task + 키 부재 → 자동 medium 없이 다음 단계"
eq "$(resolve lowfloor "$S_SMALL"  unset request-review)" "|below-floor|low|warn"   "AC7 small-task low → 경고 후 미전달 (보정 금지)"
eq "$(resolve minfloor "$S_SMALL"  unset request-review)" "|below-floor|minimal|warn" "AC7 small-task minimal 도 하한 거부"
eq "$(resolve full     "$S_LEGACY" unset request-review)" "xhigh|review-type||none" "AC8 legacy 세션 → small-task 미적용"
eq "$(resolve full     "$S_OTHER"  unset request-review)" "xhigh|review-type||none" "AC1 review type override"
eq "$(resolve full     "$S_OTHER"  unset diff-review)"    "high|tool-default||none" "AC1 매칭 override 없으면 tool 기본"
eq "$(resolve same     "$S_OTHER"  unset request-review)" "high|review-type||none"  "override 와 default 가 동일 값이어도 source 는 키 존재로 판정"

# execution-path 판정 원본 (AC 8)
ep() { ( source "${script_dir}/run_review_turn.sh" 2>/dev/null; set +e; read_execution_path "$1" ); }
eq "$(ep "$S_SMALL")"  "small-task" "AC8 execution-path: small-task"
eq "$(ep "$S_OTHER")"  "other"      "AC8 execution-path: other"
eq "$(ep "$S_LEGACY")" "unknown"    'AC8 "## Review Scope" 섹션 부재 → unknown'
printf '\n## Review Scope\n- execution-path: bogus\n' >> "$TMP/s_other/SESSION.md"
eq "$(ep "$TMP/s_other/SESSION.md")" "other" "AC8 첫 항목만 읽고 인식 불가 값에 영향받지 않음"

# AC 9 — 새 섹션이 Branch Context strict 검증을 깨뜨리지 않아야 한다.
# `## Review Scope` 를 Branch Context 안에 6번째 필드로 넣으면 5필드 strict 검증이
# 진행 중인 legacy 세션을 죽이므로 별도 섹션으로 뒀다. 그 경계가 실제로 유지되는지 고정한다.
mkdir -p "$TMP/bc"
cat > "$TMP/bc/SESSION.md" <<EOF
# Review Session

## Status
awaiting-reviewer

## Branch Context
- fr-branch: null
- worktree-path: null
- short-title: parity-fixture
- lifecycle-stage: request-review
- remote-mode: remote

## Review Scope
- execution-path: small-task
EOF
bc_out="$( ( source "${script_dir}/review_common.sh" 2>/dev/null; set +e
             parse_branch_context "$TMP/bc" | grep -c . ) )"
eq "$bc_out" "5" "AC9 Review Scope 가 뒤따라도 Branch Context 는 5필드로 파싱됨"
( source "${script_dir}/review_common.sh" 2>/dev/null; set +e
  validate_branch_context "$TMP/bc" >/dev/null 2>&1 )
chk $? "AC9 Branch Context strict 검증이 새 섹션과 공존해도 통과"
eq "$(ep "$TMP/bc/SESSION.md")" "small-task" "AC8 두 섹션 공존 시 execution-path 정상 판정"

# ============================================================
# 1b) REQUEST `## Risk Tier` → execution-path 매핑 (review-tiering-by-risk AC 9) — _state_common.sh
#     케이스마다 파서의 다른 분기 하나를 잡는다. 기대값 `unknown` 은 stderr 경고까지 확인한다.
# ============================================================
echo "=== Risk Tier 판독 ==="
mkdir -p "$TMP/rt"
rtfix() { # rtfix <이름> <Execution Path 값> <Risk Tier 블록 (빈 값이면 섹션 없음)> [<Source FR 뒤 추가 줄>]
  { printf '# Change Request\n\n## Execution Path\n%s\n\n' "$2"
    [ -n "$3" ] && printf '## Risk Tier\n%s\n\n' "$3"
    printf '## Source FR\n-\n%s\n' "${4:-}"; } > "$TMP/rt/$1.md"
}
rtfix standard  existing-code-change '- 최종 등급: standard
- 최초 등급: standard'
rtfix full      existing-code-change '- 최종 등급: full'
rtfix absent    small-task           ''
rtfix nofield   small-task           '- 최초 등급: standard'
rtfix dupempty  existing-code-change '- 최종 등급: standard
- 최종 등급:'
rtfix duphdr    existing-code-change '- 최종 등급: full

## Risk Tier'
rtfix template  existing-code-change '- 최종 등급: -'
rtfix badcase   existing-code-change '- 최종 등급: Standard'
rtfix nextsect  existing-code-change '- 최초 등급: full' '- 최종 등급: full'
rtfix comment   existing-code-change '- 최종 등급: standard            <!-- light | standard | full -->'

# rtx <fixture> → "값|warn|nowarn"
rtx() { ( source "${script_dir}/_state_common.sh" 2>/dev/null; set +e
  v="$(review_execution_path_from_request "$TMP/rt/$1.md" 2>"$TMP/rt/$1.err")"
  if grep -q 'Risk Tier' "$TMP/rt/$1.err"; then w=warn; else w=nowarn; fi
  printf '%s|%s' "$v" "$w" ); }
while IFS='|' read -r name v w label; do
  eq "$(rtx "$name")" "$v|$w" "RT $label"
done <<'RT_TABLE'
standard|small-task|nowarn|standard → small-task
full|other|nowarn|full → other
absent|small-task|nowarn|헤더 부재 → Execution Path fallback
nofield|unknown|warn|헤더 있음 + 줄 없음 → unknown+경고
dupempty|unknown|warn|유효 1줄 + 빈 값 1줄 → unknown+경고 (필드 계수)
duphdr|unknown|warn|헤더 2개 → unknown+경고
template|unknown|warn|템플릿 값 - → unknown+경고
badcase|unknown|warn|미인식 값 Standard → unknown+경고
nextsect|unknown|warn|다음 섹션의 최종 등급 줄은 무시 → unknown+경고
comment|small-task|nowarn|inline comment 붙은 standard → small-task
RT_TABLE

# prepare_review_pipeline.sh 연결 정적 단언 — 함수 테스트는 호출 한 줄과 heredoc 기록의 회귀를 보지 못한다.
PREP="${script_dir}/prepare_review_pipeline.sh"
grep -qF -- '- execution-path: $CTX_EXEC_PATH' "$PREP"
chk $? "RT prepare 가 CTX_EXEC_PATH 를 execution-path 로 기록"

# ============================================================
# 2) 가시성 상태 5종 (AC 23) — compute_effort_status
# ============================================================
# 어댑터가 effort 거부 시 즉시 실패하므로(자동 재시도 없음) "턴 성공 + effort 전달" =
# "codex 가 그 값을 수락" 이고, 부모가 아는 정보만으로 상태가 결정된다.
echo "=== 가시성 상태 5종 ==="
status() { # status <EFFORT_VALUE> <EFFORT_SOURCE> <EFFORT_REJECTED>
  (
    source "${script_dir}/run_review_turn.sh" 2>/dev/null
    set +e
    EFFORT_VALUE="$1"; EFFORT_SOURCE="$2"; EFFORT_REJECTED="$3"
    compute_effort_status
  )
}
eq "$(status xhigh review-type '')" \
   "applied:xhigh (source: review-type)"      "상태1 applied (source 동반)"
eq "$(status medium small-task '')" \
   "applied:medium (source: small-task)"      "상태1 source 가 실제 판정 단계를 반영"
eq "$(status '' global '')"  "none/global"                 "상태2 none/global (설정 부재)"
eq "$(status '' kill-switch '')" "disabled-by-kill-switch" "상태3 disabled-by-kill-switch"
eq "$(status '' below-floor low)" "rejected-below-floor:low" \
   "상태4 rejected-below-floor (설정 존재 — none/global 과 구분)"
# Claude 도 effort 를 받으므로 상태는 도구와 상관없다 (spec D7, not-applicable 분기 삭제). 도구 인자도 없다.

# ============================================================
# 3) 어댑터 전달 계약 (AC 10) — stub codex
# ============================================================
# 자동 재시도는 없다. effort 를 전달하고, 거부되면 즉시 실패하며 부모가 복구 경로를 안내한다.
echo "=== 어댑터 전달 계약 ==="

STUB="$TMP/bin/codex"
mkdir -p "$TMP/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# stub codex. STUB_MODE 로 시나리오를 제어한다.
has_effort=0
effort_val=""
for a in "$@"; do
  case "$a" in
    model_reasoning_effort=*) has_effort=1; effort_val="${a#model_reasoning_effort=}" ;;
  esac
done
cat > /dev/null   # 프롬프트 stdin 소비
{ printf 'has_effort=%s\n' "$has_effort"; printf 'effort_val=%s\n' "$effort_val"; } > "$ARGS_CAP"

write_turn() {
  printf '# Turn\n\n리뷰 본문\n' > "$EXPECTED_TURN_FILE"
  sed -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' \
    "$SESSION_PATH/SESSION.md" > "$SESSION_PATH/SESSION.md.tmp"
  mv "$SESSION_PATH/SESSION.md.tmp" "$SESSION_PATH/SESSION.md"
}

case "${STUB_MODE:-normal}" in
  normal) write_turn; exit 0 ;;
  reject-effort)
    # codex 가 지원하지 않는 effort 값을 거부하는 상황
    if [ "$has_effort" -eq 1 ]; then
      echo "error: invalid value for '-c model_reasoning_effort': unknown variant \`ultra\`" >&2
      exit 2
    fi
    write_turn; exit 0 ;;
esac
STUBEOF
chmod +x "$STUB"

prep_session() { # prep_session <이름> → 세션 디렉토리 출력
  local d="$TMP/adp_$1"
  rm -rf "$d"; mkdir -p "$d/turns"
  printf '# Review Session\n\n## Status\nawaiting-reviewer\n\n## Current Owner\nReviewer\n' > "$d/SESSION.md"
  printf '# Checkpoint\n\n## Open Issues\n- 없음\n' > "$d/CHECKPOINT.md"
  printf '# User Action\n\n## Question For User\n-\n' > "$d/USER_ACTION.md"
  printf '# Turn 001\n' > "$d/turns/001_claude.md"
  printf '%s' "$d"
}
printf 'prompt\n' > "$TMP/prompt.txt"

run_adapter() { # run_adapter <mode> <effort> <이름>
  local mode="$1" effort="$2" name="$3"
  local d; d="$(prep_session "$name")"
  : > "$TMP/args_$name"
  (
    set +e
    export STUB_MODE="$mode" TOOL_BIN="$STUB" \
      SESSION_PATH="$d" PROMPT_FILE="$TMP/prompt.txt" \
      EXPECTED_TURN_FILE="$d/turns/002_reviewer.md" \
      PROJECT_ROOT="$TMP" WAIT_TIMEOUT=20 ARGS_CAP="$TMP/args_$name"
    [ -n "$effort" ] && export TOOL_EFFORT="$effort"
    bash "${script_dir}/adapter_codex.sh" >"$TMP/out_$name" 2>"$TMP/err_$name"
    echo "rc=$?"
  )
}

r="$(run_adapter normal xhigh pass_effort)"
eq "$r" "rc=0" "effort 전달 시 정상 완료"
eq "$(grep '^effort_val=' "$TMP/args_pass_effort")" 'effort_val="xhigh"' \
   "AC10 -c model_reasoning_effort 값이 TOML 문자열로 전달됨"

r="$(run_adapter normal '' no_effort)"
eq "$r" "rc=0" "AC2 effort 미전달 시에도 정상 완료 (bash 3.2 빈 배열 전개 안전)"
eq "$(grep '^has_effort=' "$TMP/args_no_effort")" "has_effort=0" \
   "AC2 effort 미전달이면 -c 인자가 붙지 않음 (전역 설정을 따름)"

r="$(run_adapter reject-effort xhigh rejected)"
eq "$r" "rc=1" "effort 거부 시 즉시 실패한다 (자동 재시도 없음)"
grep -q 'unknown variant' "$TMP/err_rejected"
chk $? "거부 사유가 caller stderr 로 그대로 전달됨 (진단 가능)"
grep -q '재시도' "$TMP/err_rejected"; [ $? -ne 0 ]
chk $? "어댑터가 재시도를 시도하지 않음"


# ============================================================
# 4) 호출자 환경 격리 (AC 32) — 사전 export 된 내부 변수가 새지 않아야 한다
# ============================================================
# env -u 로 제거하지 않으면 ① kill switch 를 켜도 어댑터가 상속값을 읽어 실제로 effort 를
# 전달하고 ② claude 어댑터도 상속받아 codex 전용 계약이 깨지며 ③ 표시와 실제가 어긋난다.
echo "=== 호출자 환경 격리 ==="

ISO="$TMP/iso"
mkdir -p "$ISO/rd-workflow/scripts" "$ISO/rd-workflow/config" \
         "$ISO/rd-workflow/docs/flows" "$ISO/rd-workflow/docs/prompts/review" "$ISO/cap"
for f in run_review_turn.sh review_common.sh review_wait.sh adapter_codex.sh adapter_claude.sh model_select.sh; do
  cp "${script_dir}/$f" "$ISO/rd-workflow/scripts/$f"
done
printf '기준\n' > "$ISO/rd-workflow/docs/prompts/review/request_review.md"
printf '규칙\n' > "$ISO/rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md"
printf 'target\n' > "$ISO/TARGET.md"

cat > "$ISO/envstub" <<'ESEOF'
#!/usr/bin/env bash
{ printf 'ARGS=%s\n' "$*"
  printf 'TOOL_EFFORT=%s\n' "${TOOL_EFFORT+SET}"
  printf 'EFFORT_SOURCE=%s\n' "${EFFORT_SOURCE+SET}"
  printf 'VAL=%s\n' "${TOOL_EFFORT:-}"; } > "$CAPFILE"
cat > /dev/null
printf '# T\n' > "$EXPECTED_TURN_FILE"
sed -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' \
  "$SESSION_PATH/SESSION.md" > "$SESSION_PATH/S.tmp"
mv "$SESSION_PATH/S.tmp" "$SESSION_PATH/SESSION.md"
ESEOF
chmod +x "$ISO/envstub"

iso_session() { # iso_session [<리뷰 종류>] [<execution-path>] — 기본 request-review·other
  local rt="${1:-request-review}" ep="${2:-other}"
  rm -rf "$ISO/sess"; mkdir -p "$ISO/sess/turns"
  cat > "$ISO/sess/SESSION.md" <<EOF
# Review Session

## Status
awaiting-reviewer

## Current Owner
Reviewer

## Review Type
${rt}

## Review Target
TARGET.md

## Review Goal
goal

## Turn Limit
20

## Review Scope
- execution-path: ${ep}
EOF
  printf '# C\n\n## Open Issues\n- 없음\n' > "$ISO/sess/CHECKPOINT.md"
  printf '# U\n\n## Question For User\n-\n' > "$ISO/sess/USER_ACTION.md"
  printf '# T1\n' > "$ISO/sess/turns/001_claude.md"
}
iso_cfg() { # iso_cfg <priority tool> <codex effort|"">
  local ef=""
  [ -n "$2" ] && ef=", \"reasoning_effort\": \"$2\""
  cat > "$ISO/rd-workflow/config/review-tools.json" <<EOF
{ "default_priority": ["$1"],
  "tools": { "codex": { "bin": "$ISO/envstub"$ef },
             "claude": { "bin": "$ISO/envstub", "self_review_policy": "warn", "self_review_warning": false } } }
EOF
}

# 케이스 A: kill switch 가 켜졌는데 호출자 환경에 TOOL_EFFORT 가 남아 있음
iso_session; iso_cfg codex high
( cd "$ISO" && RD_REVIEW_EFFORT_OVERRIDE=0 TOOL_EFFORT=xhigh EFFORT_SOURCE=bogus \
    CAPFILE="$ISO/cap/a" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_a" 2>"$ISO/err_a" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/a")" "TOOL_EFFORT=" \
   "kill switch 시 상속된 TOOL_EFFORT 가 어댑터에 도달하지 않음"
grep -q 'model_reasoning_effort' "$ISO/cap/a"; [ $? -ne 0 ]
chk $? "kill switch 시 -c model_reasoning_effort 가 실제로 전달되지 않음"
grep -q 'effort override: disabled-by-kill-switch' "$ISO/out_a"
chk $? "표시와 실제가 일치 (거짓 보고 없음)"

# 케이스 B: claude 선택 + 호출자가 내부 변수를 export
iso_session; iso_cfg claude high
( cd "$ISO" && TOOL_EFFORT=xhigh EFFORT_SOURCE=review-type \
    CAPFILE="$ISO/cap/b" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_b" 2>"$ISO/err_b" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/b")"   "TOOL_EFFORT="   "AC32 claude 환경에 TOOL_EFFORT 부재"
eq "$(grep '^EFFORT_SOURCE=' "$ISO/cap/b")" "EFFORT_SOURCE=" "AC32 claude 환경에 EFFORT_SOURCE 부재"
grep -q 'effort override: none/global' "$ISO/out_b"
chk $? "AC23 claude 선택 시 codex 값을 보고하지 않음 (claude effort 미설정 → none/global)"

# 케이스 C: 설정 부재 + 호출자가 TOOL_EFFORT export (후퇴 없음 보증)
iso_session; iso_cfg codex ""
( cd "$ISO" && TOOL_EFFORT=xhigh CAPFILE="$ISO/cap/c" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_c" 2>"$ISO/err_c" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/c")" "TOOL_EFFORT=" \
   "AC2 설정 부재 시 상속값이 전역 설정을 덮어쓰지 못함"
grep -q 'effort override: none/global' "$ISO/out_c"
chk $? "AC2 설정 부재 시 none/global 로 보고"

# 케이스 D: 정상 주입 경로가 여전히 동작 (격리가 기능을 죽이지 않았는지)
iso_session; iso_cfg codex high
( cd "$ISO" && CAPFILE="$ISO/cap/d" WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_d" 2>"$ISO/err_d" )
eq "$(grep '^TOOL_EFFORT=' "$ISO/cap/d")" "TOOL_EFFORT=SET" "설정된 effort 는 정상 주입됨"
eq "$(grep '^VAL=' "$ISO/cap/d")"         "VAL=high"        "주입값이 계산 결과와 일치"
grep -q 'effort override: applied:high (source: tool-default)' "$ISO/out_d"
chk $? "AC23 applied 상태와 source 표시"

# 케이스 E: 어댑터 실패 시 복구 안내 (자동 재시도의 대체 경로)
iso_session
cat > "$ISO/failstub" <<'FSEOF'
#!/usr/bin/env bash
cat > /dev/null
echo "error: invalid value for '-c model_reasoning_effort': unknown variant" >&2
exit 2
FSEOF
chmod +x "$ISO/failstub"
cat > "$ISO/rd-workflow/config/review-tools.json" <<EOF
{ "default_priority": ["codex"],
  "tools": { "codex": { "bin": "$ISO/failstub", "reasoning_effort": "ultra" } } }
EOF
( cd "$ISO" && WAIT_TIMEOUT=20 \
    bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$ISO/out_e" 2>"$ISO/err_e" )
grep -q "\[effort\] 이번 호출에 넘긴 값: ultra" "$ISO/err_e"
chk $? "실패 시 전달한 effort 값을 알려줌"
grep -q 'RD_REVIEW_EFFORT_OVERRIDE=0' "$ISO/err_e"
chk $? "실패 시 kill switch 복구 경로를 안내함"
grep -q 'review-tools.json' "$ISO/err_e"
chk $? "effort 값 확인 안내"
! grep -q '제거' "$ISO/err_e"
chk $? "영구 변경(제거) 지시 부재"

# ============================================================
# 4b) 리뷰 턴의 모델·effort 적용 (spec D4~D7) — 판정은 fn_run(함수 단위), 인자 배선은 ab_run(실행기 전체)
#     ab_run 은 가짜 codex·claude 가 받은 인자를 본다. 실행기 한 번이 수 초라 배선 확인에만 쓴다.
#     HOME 은 표본 캐시를 둔 임시 홈이다. 실제 모델·실제 ~/.codex 는 쓰지 않는다.
# ============================================================
echo "=== 리뷰 턴 모델·effort 적용 ==="

ISO_CFG="$ISO/rd-workflow/config"
ABH="$TMP/abhome"; mkdir -p "$ABH/.codex"
cp "$MS_SAMPLE" "$ABH/.codex/models_cache.json"
AB_BIN="$TMP/abbin"; AB_BIN_CLAUDE="$TMP/abbin_claude"; mkdir -p "$AB_BIN" "$AB_BIN_CLAUDE"
# 가짜 CLI: 받은 인자를 한 줄씩 $ARGDIR/args.<이름> 에 남기고 턴 파일을 만든다. FAKE_FAIL=1 이면 원인 불명 오류로 rc 1.
# FAKE_LOG=<파일> 이면 그 내용을 출력하고 rc 1 — Claude 는 stdout(stream-json), Codex 는 stderr 다.
cat > "$AB_BIN/fakecli" <<'FKEOF'
#!/usr/bin/env bash
me="$(basename "$0")"
: > "$ARGDIR/args.$me"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGDIR/args.$me"; done
cat > /dev/null
if [ "${FAKE_FAIL:-0}" = 1 ]; then echo "something odd happened" >&2; exit 1; fi
if [ -n "${FAKE_LOG:-}" ]; then
  if [ "$me" = claude ]; then cat "$FAKE_LOG"; else cat "$FAKE_LOG" >&2; fi
  exit 1
fi
printf '# T\n' > "$EXPECTED_TURN_FILE"
sed -e 's/^awaiting-reviewer$/awaiting-author/' -e 's/^Reviewer$/Author/' \
  "$SESSION_PATH/SESSION.md" > "$SESSION_PATH/S.tmp"
mv "$SESSION_PATH/S.tmp" "$SESSION_PATH/SESSION.md"
FKEOF
chmod +x "$AB_BIN/fakecli"
ln -s "$AB_BIN/fakecli" "$AB_BIN/codex"
ln -s "$AB_BIN/fakecli" "$AB_BIN/claude"
ln -s "$AB_BIN/fakecli" "$AB_BIN_CLAUDE/claude"
# jq 없는 PATH: 기본 유틸 폴더를 심링크하고 jq 만 뺀다 (/usr/bin/jq 가 있는 머신도 있음).
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for d in /bin /usr/bin /usr/sbin /sbin; do [ -d "$d" ] && ln -s "$d"/* "$NOJQ/" 2>/dev/null; done
rm -f "$NOJQ/jq"

ab_models() { if [ -z "$1" ]; then rm -f "$ISO_CFG/models.json"; else printf '%s' "$1" > "$ISO_CFG/models.json"; fi; }
ab_toml()   { if [ -z "$1" ]; then rm -f "$ABH/.codex/config.toml"; else printf '%s\n' "$1" > "$ABH/.codex/config.toml"; fi; }
ab_legacy() { # ab_legacy <도구> [<병합할 JSON>] — 그 도구 하나만 실행한다. Claude self-review 는 off.
  local x="${2:-}"; [ -n "$x" ] || x='{}'
  jq -n --arg t "$1" --argjson x "$x" \
    '{default_priority:[$t], tools:{claude:{self_review_policy:"off"}}} * $x' > "$ISO_CFG/review-tools.json"
}
ab_reset() { ab_models ""; ab_toml ""; rm -f "$ISO_CFG/review-tools.json"; }
ab_run() { # ab_run <이름> <리뷰 종류> <execution-path> [VAR=값...]
  local name="$1" rt="$2" ep="$3"; shift 3
  iso_session "$rt" "$ep"
  rm -rf "$TMP/ab/$name"; mkdir -p "$TMP/ab/$name"
  ( cd "$ISO" && env -u RD_MODELS_CONFIG -u REVIEW_TOOLS_CONFIG -u CODEX_HOME -u TOOL_MODEL -u TOOL_EFFORT \
      -u RD_REVIEW_EFFORT_OVERRIDE HOME="$ABH" ARGDIR="$TMP/ab/$name" WAIT_TIMEOUT=20 PATH="$AB_BIN:$PATH" "$@" \
      bash "$ISO/rd-workflow/scripts/run_review_turn.sh" sess >"$TMP/ab/$name/out" 2>"$TMP/ab/$name/err" )
}
ab_args() { local f="$TMP/ab/$1/args.$2"; if [ -f "$f" ]; then printf ' %s ' "$(tr '\n' ' ' < "$f")"; else printf 'NOFILE'; fi; }
ab_has()  { case "$(ab_args "$1" "$2")" in *" $3 "*) return 0 ;; esac; return 1; }  # ab_has <이름> <도구> <인자 조각>
ab_ran()  { [ -f "$TMP/ab/$1/args.$2" ]; }
ab_noarg() { ab_ran "$1" "$2" && ! ab_has "$1" "$2" "$3"; }                     # 실행됐고 그 조각이 없음
ab_noeff() { ab_ran "$1" codex && ! grep -q 'model_reasoning_effort' "$TMP/ab/$1/args.codex"; }
ab_err()  { grep -qF -- "$2" "$TMP/ab/$1/err"; }
ab_errn() { grep -cF -- "$2" "$TMP/ab/$1/err"; }
ab_out()  { grep -qF -- "$2" "$TMP/ab/$1/out"; }
MJ="$ISO_CFG/models.json"
EFF() { printf 'model_reasoning_effort="%s"' "$1"; }

# 함수 단위 판정 — 실행기를 source 해 실행기와 같은 순서로 부른다:
#   load_review_config → resolve_review_selection → format_selection_line
#   (SEL_LOG=<실패 로그> 이면 이어서 classify_adapter_failure_cause → print_selection_recovery).
# 어댑터·가짜 CLI 는 띄우지 않는다. 결과는 $TMP/ab/<이름>/out(MODEL=·EFFORT=)·err(경고·실행 줄·복구 안내).
# MODEL·EFFORT 는 실행기가 어댑터에 넘기는 TOOL_MODEL·TOOL_EFFORT 값이다(빈 값 = 인자 없음).
# 그 값이 실제 CLI 인자(-m·-c·--model·--effort)가 되는 배선은 ab_run 케이스(A1·A2·A12·A14·A15·R5·R6·R7)가 본다.
cat > "$TMP/seldrv.sh" <<'SDEOF'
source "$1" 2>/dev/null
set +e
load_review_config "$3"
resolve_review_selection "$2" "$4" "$3"
format_selection_line "$2" >&2; echo >&2
printf 'MODEL=%s\nEFFORT=%s\n' "$MODEL_VALUE" "$EFFORT_VALUE"
if [ -n "${SEL_LOG:-}" ]; then
  print_selection_recovery "$2" "$(classify_adapter_failure_cause "$SEL_LOG" "$2")"
fi
SDEOF
fn_run() { # fn_run <이름> <tool> <리뷰 종류> <execution-path> [VAR=값...] — ab_run 과 같은 환경으로 판정만 한다
  local name="$1" tool="$2" rt="$3" ep="$4"; shift 4
  rm -rf "$TMP/ab/$name"; mkdir -p "$TMP/ab/$name"
  ( cd "$ISO" && env -u RD_MODELS_CONFIG -u REVIEW_TOOLS_CONFIG -u CODEX_HOME -u TOOL_MODEL -u TOOL_EFFORT \
      -u RD_REVIEW_EFFORT_OVERRIDE HOME="$ABH" PATH="$AB_BIN:$PATH" "$@" \
      bash "$TMP/seldrv.sh" "$ISO/rd-workflow/scripts/run_review_turn.sh" "$tool" "$rt" "$ep" ) \
    >"$TMP/ab/$name/out" 2>"$TMP/ab/$name/err"
}
fv()    { sed -n "s/^$2=//p" "$TMP/ab/$1/out"; }      # fv <이름> MODEL|EFFORT → 넘길 값
fnone() { grep -qx "$2=" "$TMP/ab/$1/out"; }          # fnone <이름> MODEL|EFFORT → 판정이 끝났고 값이 비어 있음

# --- A1 옛 키만 — Codex 는 -m 없이 옛 effort 그대로, Claude 는 옛 모델만 (실행기 실행: 옛 설정 동등) ---
ab_reset; ab_toml 'model = "gpt-6.1-sol"'
ab_legacy codex '{"tools":{"codex":{"reasoning_effort":"high"},"claude":{"model":"sonnet"}}}'
ab_run a1x request-review other
ab_noarg a1x codex "-m";                        chk $? "A1 옛 키만 → Codex 인자에 -m 없음"
ab_has a1x codex "-c $(EFF high)";              chk $? "A1 옛 키 effort high 를 그대로 전달"
eq "$(ab_errn a1x 'ℹ️  옛 설정 ')" "1"               "A1 Codex 실행에 옛 키 안내 1줄 (effort 칸)"
ab_legacy claude '{"tools":{"codex":{"reasoning_effort":"high"},"claude":{"model":"sonnet"}}}'
ab_run a1c request-review other
ab_has a1c claude "--model sonnet";             chk $? "A1 Claude 옛 tools.claude.model → --model sonnet"
ab_noarg a1c claude "--effort";                 chk $? "A1 Claude 는 Codex 옛 effort 를 쓰지 않음 (--effort 없음)"
eq "$(ab_errn a1c 'ℹ️  옛 설정 ')" "1"               "A1 Claude 실행에 옛 키 안내 1줄 (모델 칸)"

# --- A2 계열 sol + ultra — 실행 줄의 표기 (실행기 실행: Codex -m·-c 배선) ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"model":"sol","effort":"ultra"}}}'
ab_run a2 request-review other
ab_has a2 codex "-m gpt-6.2-sol";               chk $? "A2 계열 sol → -m gpt-6.2-sol"
ab_has a2 codex "-c $(EFF ultra)";              chk $? "A2 지원 단계 ultra 그대로"
ab_err a2 "모델 요청: sol→gpt-6.2-sol (source: models.json · file:${MJ}#review.codex.model)"; chk $? "A2 실행 줄 모델 표기"
ab_err a2 "effort 시도: ultra (source: tool-default · file:${MJ}#review.codex.effort)";       chk $? "A2 실행 줄 effort 표기"

# --- A3 luna + ultra → max 하향 ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"model":"luna","effort":"ultra"}}}'
fn_run a3 codex request-review other
eq "$(fv a3 MODEL)"  "gpt-6-luna"               "A3 계열 luna → -m gpt-6-luna"
eq "$(fv a3 EFFORT)" "max"                      "A3 luna 가 지원하지 않는 ultra → max"
ab_err a3 "지원하지 않는 effort 'ultra' 를 'max'"; chk $? "A3 하향 경고"

# --- A4 옛 키 값은 변환하지 않음 ---
ab_reset
ab_legacy codex '{"tools":{"codex":{"reasoning_effort":"ultra"}}}'
ab_models '{"review":{"codex":{"model":"luna"}}}'
fn_run a4 codex request-review other
eq "$(fv a4 EFFORT)" "ultra"                    "A4 옛 키 ultra 는 luna 여도 그대로"

# --- A5 계열 해석 실패 ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"model":"nosuch"}}}'
fn_run a5 codex request-review other
fnone a5 MODEL;                                 chk $? "A5 해석 실패 → -m 없음"
ab_err a5 "계열 'nosuch'";                      chk $? "A5 해석 실패 경고"
ab_err a5 "모델 요청: none (source: unresolved · file:${MJ}#review.codex.model = nosuch) — CLI 기본값으로 실행"; chk $? "A5 실행 줄 (파일 위치)"
ab_models ""
fn_run a5e codex request-review other RD_REVIEW_CODEX_MODEL=nosuch
fnone a5e MODEL;                                chk $? "A5 환경 변수 해석 실패 → -m 없음"
ab_err a5e "모델 요청: none (source: unresolved · env:RD_REVIEW_CODEX_MODEL = nosuch) — CLI 기본값으로 실행"; chk $? "A5 실행 줄 (환경 변수 위치)"

# --- A6 환경 변수가 models.json 을 이김 ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"model":"sol","effort":"medium"}}}'
fn_run a6 codex request-review other RD_REVIEW_CODEX_MODEL=astra RD_REVIEW_CODEX_EFFORT=xhigh
eq "$(fv a6 MODEL)"  "gpt-6.2-astra"            "A6 RD_REVIEW_CODEX_MODEL=astra 가 이김"
eq "$(fv a6 EFFORT)" "xhigh"                    "A6 RD_REVIEW_CODEX_EFFORT=xhigh 가 이김"

# --- A7 kill switch 0·빈 문자열·yes ---
ab_reset; ab_legacy codex '{"tools":{"codex":{"reasoning_effort":"high"}}}'
fn_run a7z codex request-review other RD_REVIEW_EFFORT_OVERRIDE=0   RD_REVIEW_CODEX_EFFORT=high
fn_run a7e codex request-review other RD_REVIEW_EFFORT_OVERRIDE=    RD_REVIEW_CODEX_EFFORT=high
fn_run a7y codex request-review other RD_REVIEW_EFFORT_OVERRIDE=yes RD_REVIEW_CODEX_EFFORT=high
fnone a7z EFFORT; chk $? "A7 kill switch 0 → effort 없음"
fnone a7e EFFORT; chk $? "A7 kill switch 빈 문자열 → effort 없음"
fnone a7y EFFORT; chk $? "A7 kill switch yes → effort 없음"
! ab_err a7z "인식할 수 없습니다"; chk $? "A7 kill switch 0 → 인식 불가 경고 없음"
ab_err a7e "인식할 수 없습니다";   chk $? "A7 kill switch 빈 문자열 → 인식 불가 경고"
ab_err a7y "인식할 수 없습니다";   chk $? "A7 kill switch yes → 인식 불가 경고"

# --- A8 small-task 단계와 하한 ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"small_task_effort":"high"}}}'
fn_run a8 codex diff-review small-task
eq "$(fv a8 EFFORT)" "high"                     "A8 small-task high 전달"
ab_err a8 "effort 시도: high (source: small-task · "; chk $? "A8 실행 줄 small-task 출처"
ab_toml 'model = "gpt-6.2-sol"'
ab_models '{"review":{"codex":{"small_task_effort":"lowest"}}}'
fn_run a8f codex diff-review small-task
fnone a8f EFFORT;                               chk $? "A8 small-task lowest(→low) 는 하한 미만 → effort 없음"
ab_err a8f "effort 시도: none (source: below-floor · "; chk $? "A8 실행 줄 below-floor"
ab_err a8f "허용 하한(medium) 미만";            chk $? "A8 하한 경고"

# --- A8b 하한은 small-task 단계에만 ---
ab_reset; ab_legacy codex; ab_toml 'model = "gpt-6.2-sol"'
ab_models '{"review":{"codex":{"effort":"low"}}}'
fn_run a8b codex diff-review other
eq "$(fv a8b EFFORT)" "low"                     "A8b 일반 세션 effort low 는 그대로 전달"

# --- A9 리뷰 종류별 칸이 도구 기본을 이김 ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"effort":"medium","review_types":{"request-review":{"effort":"xhigh"}}}}}'
fn_run a9 codex request-review other
eq "$(fv a9 EFFORT)" "xhigh"                    "A9 review_types.request-review.effort=xhigh"
ab_err a9 "effort 시도: xhigh (source: review-type · "; chk $? "A9 실행 줄 review-type 출처"

# --- A10 default 는 미전달로 멈추고 옛 키로 내려가지 않음 ---
ab_reset; ab_legacy codex '{"tools":{"codex":{"reasoning_effort":"high"}}}'
ab_models '{"review":{"codex":{"effort":"default"}}}'
fn_run a10 codex request-review other
fnone a10 EFFORT;                               chk $? "A10 effort default → 인자 없음 (옛 키 high 로 내려가지 않음)"
! ab_err a10 "옛 설정";                         chk $? "A10 쓰지 않은 옛 키는 안내하지 않음"
ab_err a10 "effort 시도: none (source: tool-default · "; chk $? "A10 실행 줄 none·tool-default"
ab_err a10 "#review.codex.effort = default)";    chk $? "A10 실행 줄에 = default 위치"

# --- A10b 모델 default 도 옛 키로 내려가지 않음 ---
ab_reset; ab_legacy claude '{"tools":{"claude":{"model":"sonnet"}}}'
ab_models '{"review":{"claude":{"model":"default"}}}'
fn_run a10b claude request-review other
fnone a10b MODEL;                               chk $? "A10b Claude 모델 default → --model 없음"
! ab_err a10b "옛 설정";                        chk $? "A10b 옛 키 안내 없음"

# --- D2c skill setup 의 「옛 설정을 따름」 → models.json 칸을 null 로 비워 옛 키로 내려감 ---
ab_reset; ab_legacy claude '{"tools":{"claude":{"model":"sonnet"}}}'
ab_models '{"review":{"claude":{"model":"haiku"}}}'
{ printf '%s\n' 'legacy tools.codex.bin null'; skill_line review-config-legacy-choice; } > "$TMP/d2c.list"
( cd "$ISO" && HOME="$ABH" list="$TMP/d2c.list" bash -c "$(skill_line review-config-apply)" ) >"$TMP/d2c.out" 2>&1
fn_run d2c claude request-review other
eq "$(fv d2c MODEL)" "sonnet"                   "D2c 옛 설정을 따름 → --model sonnet (haiku 에서 바뀜)"
eq "$(jq -r '.tools.claude.model' "$ISO_CFG/review-tools.json")" "sonnet" "D2c review-tools.json 의 tools.claude.model 보존"

# --- D2b skill setup 의 「CLI 기본값」 → default 로 저장해 옛 키로 내려가지 않음 ---
ab_reset; ab_legacy claude '{"tools":{"claude":{"model":"sonnet"}}}'
skill_line review-config-default-choice > "$TMP/d2b.list"
( cd "$ISO" && HOME="$ABH" list="$TMP/d2b.list" bash -c "$(skill_line review-config-apply)" ) >"$TMP/d2b.out" 2>&1
fn_run d2b claude request-review other
fnone d2b MODEL;                                chk $? "D2b CLI 기본값 선택 → --model 없음"

# --- A11 null 은 비어 있음 → 옛 키, 손상 파일은 무시 ---
ab_reset; ab_legacy codex '{"tools":{"codex":{"reasoning_effort":"high"}}}'
ab_models '{"review":{"codex":{"effort":null}}}'
fn_run a11 codex request-review other
eq "$(fv a11 EFFORT)" "high"                    "A11 effort null → 옛 키 high"
eq "$(ab_errn a11 'ℹ️  옛 설정 ')" "1"               "A11 옛 키 안내 1줄"
ab_models '{'
fn_run a11c codex request-review other
ab_err a11c "models.json 을 읽지 못했습니다";    chk $? "A11 models.json 손상 경고"
eq "$(fv a11c EFFORT)" "high"                   "A11 손상 시 옛 키 high"

# --- A12 Claude 모델·effort (a12 는 실행기 실행: Claude --model·--effort 배선) ---
ab_reset; ab_legacy claude
ab_models '{"review":{"claude":{"model":"haiku","effort":"high"}}}'
ab_run a12 request-review other
ab_has a12 claude "--model haiku";              chk $? "A12 Claude --model haiku"
ab_has a12 claude "--effort high";              chk $? "A12 Claude --effort high"
fn_run a12p claude request-review other RD_REVIEW_CLAUDE_MODEL=claude-opus-5-5
ab_err a12p "고정 이름입니다";                  chk $? "A12 Claude 고정 이름 경고"
eq "$(fv a12p MODEL)" "claude-opus-5-5"         "A12 Claude 고정 이름 그대로 전달"
fn_run a12u claude request-review other RD_REVIEW_CLAUDE_EFFORT=ultra
eq "$(fv a12u EFFORT)" "max"                    "A12 Claude ultra → --effort max"
ab_err a12u "지원하지 않는 effort 'ultra'";      chk $? "A12 Claude 하향 경고"

# --- A12b Codex 고정 이름 ---
ab_reset; ab_legacy codex
fn_run a12b codex request-review other RD_REVIEW_CODEX_MODEL=gpt-6.2-sol
! ab_err a12b "고정 이름입니다";                chk $? "A12b Codex 고정 이름은 리뷰 턴에서 경고하지 않음"
eq "$(fv a12b MODEL)" "gpt-6.2-sol"             "A12b Codex 고정 이름 -m 전달"

# --- A13 Claude 성공 요약 (a12·a1c 실행기 실행의 stdout) ---
ab_out a12 "effort override: applied:high (source: tool-default)"; chk $? "A13 Claude effort 전달 → applied:high (source: tool-default)"
ab_out a1c "effort override: none/global";      chk $? "A13 Claude effort 미전달 → none/global"
! cat "$TMP"/ab/*/out | grep -q 'not-applicable'; chk $? "A13 not-applicable 표시 없음"

# --- A14 호출 환경의 TOOL_MODEL·TOOL_EFFORT 는 어댑터에 닿지 않음 (실행기 실행: 상속 환경 차단) ---
ab_reset; ab_models '{"version":1}'
ab_legacy codex
ab_run a14x request-review other TOOL_MODEL=x TOOL_EFFORT=y
ab_legacy claude
ab_run a14c request-review other TOOL_MODEL=x TOOL_EFFORT=y
ab_ran a14x codex && ! grep -qxE 'x|.*"y"|y' "$TMP/ab/a14x/args.codex";  chk $? "A14 Codex 인자에 상속값 x·y 없음"
ab_ran a14c claude && ! grep -qxE 'x|y' "$TMP/ab/a14c/args.claude";      chk $? "A14 Claude 인자에 상속값 x·y 없음"

# --- A16 옛 설정 파싱 실패 → 옛 값 모두 빠짐 ---
ab_reset
printf '{"default_priority":"codex","tools":{"codex":{"reasoning_effort":"high"}}}' > "$ISO_CFG/review-tools.json"
fn_run a16 codex request-review other
ab_err a16 "설정 파일 파싱 실패";               chk $? "A16 파싱 실패 경고"
fnone a16 EFFORT;                               chk $? "A16 파싱 실패 → effort 없음 (옛 키를 다시 읽지 않음)"

# --- A17 무효 새 칸 → 옛 키 (조회와 실행 일치) ---
ab_reset; ab_legacy claude '{"tools":{"claude":{"model":"sonnet"}}}'
ab_models '{"review":{"claude":{"model":"Opus"}}}'
fn_run a17 claude request-review other
ab_err a17 "값이 올바르지 않습니다: Opus";        chk $? "A17 무효 값 경고"
eq "$(fv a17 MODEL)" "sonnet"                   "A17 무효 새 칸 → 옛 키 sonnet"

# --- A18 config.toml 작은따옴표 모델로 effort 변환 ---
ab_reset; ab_legacy codex; ab_toml "model = 'gpt-6-luna'"
fn_run a18 codex request-review other RD_REVIEW_CODEX_EFFORT=ultra
eq "$(fv a18 EFFORT)" "max"                     "A18 config.toml 의 luna 기준으로 ultra → max"
fnone a18 MODEL;                                chk $? "A18 모델 설정 없음 → -m 없음"
ab_err a18 "지원하지 않는 effort 'ultra'";       chk $? "A18 하향 경고"

# --- A19 첫 저장 뒤에도 옛 effort 칸이 살아 있음 ---
ab_reset
ab_legacy codex '{"tools":{"codex":{"small_task_reasoning_effort":"high"}},"overrides":{"request-review":{"tools":{"codex":{"reasoning_effort":"xhigh"}}}}}'
# 예시 파일을 두어 「첫 저장은 예시가 아니라 {"version":1} 에서 시작」 을 이 경로에서도 확인한다(M66).
printf '{"version":1,"review":{"codex":{"small_task_effort":"medium"}}}' > "$ISO_CFG/models.json.example"
( cd "$ISO" && env -u RD_MODELS_CONFIG HOME="$ABH" bash "$ISO/rd-workflow/scripts/model_select.sh" set review.claude.model haiku ) >/dev/null 2>&1
chk $? "A19 set review.claude.model haiku rc 0"
rm -f "$ISO_CFG/models.json.example"
fn_run a19s codex diff-review small-task
eq "$(fv a19s EFFORT)" "high"                   "A19 저장 뒤 small-task 세션 → 옛 small-task high"
fn_run a19r codex request-review other
eq "$(fv a19r EFFORT)" "xhigh"                  "A19 저장 뒤 request-review 세션 → 옛 종류별 xhigh"

# --- A15 jq 없음 → 모든 설정·환경 변수를 쓰지 않음 (실행기 실행: jq 판정은 실행기가 턴 시작 때 한다) ---
# Codex 는 원인 불명 실패(FAKE_FAIL)로 함께 돌려 인자와 복구 안내 한 줄(A15b)을 한 실행에서 본다.
ab_reset; ab_legacy codex '{"tools":{"codex":{"reasoning_effort":"high"}}}'
ab_models '{"review":{"codex":{"model":"sol","effort":"high"},"claude":{"model":"haiku","effort":"high"}}}'
ab_run a15x request-review other PATH="$AB_BIN:$NOJQ" FAKE_FAIL=1 RD_REVIEW_CODEX_EFFORT=high RD_REVIEW_CODEX_MODEL=sol
ab_noeff a15x;                                  chk $? "A15 jq 없음 → Codex effort 없음 (환경 변수도 무시)"
ab_noarg a15x codex "-m";                       chk $? "A15 jq 없음 → Codex -m 없음"
eq "$(ab_errn a15x 'jq가 설치되지 않아')" "1"       "A15 jq 경고 1번"
ab_err a15x "jq 가 없어";                       chk $? "A15b 복구 안내에 jq 가 없어"
ab_err a15x "config.toml";                      chk $? "A15b 복구 안내에 config.toml"
! ab_err a15x "RD_REVIEW_CODEX_EFFORT=";        chk $? "A15b 환경 변수 덮어쓰기를 권하지 않음"
ab_run a15c request-review other PATH="$AB_BIN_CLAUDE:$NOJQ" RD_SELF_REVIEW_APPROVE=1 \
  RD_REVIEW_CLAUDE_MODEL=haiku RD_REVIEW_CLAUDE_EFFORT=high
ab_noarg a15c claude "--model";                 chk $? "A15 jq 없음 → Claude --model 없음"
ab_noarg a15c claude "--effort";                chk $? "A15 jq 없음 → Claude --effort 없음"
# jq 없음 + 원인이 용량 부족(모델·effort 아님) → jq 안내 줄을 내지 않음 (D10 「표 대신」, T2-m1)
printf 'ERROR: model is at capacity\n' > "$TMP/a15n_capacity.log"
ab_run a15n request-review other PATH="$AB_BIN:$NOJQ" FAKE_LOG="$TMP/a15n_capacity.log"
ab_err a15n "용량 부족";                         chk $? "A15n 원인 용량 부족으로 분류"
! ab_err a15n "jq 가 없어";                     chk $? "A15n 원인이 모델·effort 가 아니면 jq 안내 없음"

# ============================================================
# 4c) 거부 시 복구 안내 (spec D10) — 칸마다 넘긴 값이면 그 출처, 넘기지 않았으면 cli-default 안내
#     안내 문구는 fn_run 에 SEL_LOG=<오류 로그> 를 주어 함수로 본다. 안내 줄은 `    [모델] `·`    [effort] ` 로 시작한다.
#     실행기 실행은 R6(실패 분기의 원인 줄·안내 연결)과 R5·R7 의 「안내대로 다시 실행」 만 쓴다.
# ============================================================
echo "=== 거부 시 복구 안내 ==="
RV="$TMP/rv"; mkdir -p "$RV"
printf 'ERROR: reasoning_effort unknown variant\n' > "$RV/codex_effort.log"
printf 'ERROR: model not found\n' > "$RV/codex_model.log"
printf 'ERROR: model not found\nERROR: reasoning_effort unknown variant\n' > "$RV/codex_both.log"
printf '{"type":"result","is_error":true,"result":"Request failed"}\n' > "$RV/claude_unknown.log"
RV_CL_MODEL="${script_dir}/fixtures/claude_unrecognized_model.stream.log"
rv_sec() { grep -F "    [$2] " "$TMP/ab/$1/err"; }                  # rv_sec <이름> <모델|effort>
rv_has() { rv_sec "$1" "$2" | grep -qF -- "$3"; }                  # rv_has <이름> <모델|effort> <조각>

# --- R1 models.json 칸 출처 Codex effort 거부 ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"effort":"high"}}}'
fn_run r1 codex request-review other SEL_LOG="$RV/codex_effort.log"
rv_has r1 effort "$MJ";                         chk $? "R1 effort 안내에 models.json 절대 경로"
rv_has r1 effort "review.codex.effort";         chk $? "R1 effort 안내에 review.codex.effort"
rv_has r1 effort "RD_REVIEW_EFFORT_OVERRIDE=0"; chk $? "R1 일회성 무력화 RD_REVIEW_EFFORT_OVERRIDE=0"
rv_has r1 effort "RD_REVIEW_CODEX_EFFORT=default"; chk $? "R1 이번만 인자 빼기 RD_REVIEW_CODEX_EFFORT=default"
! rv_sec r1 모델 >/dev/null;                    chk $? "R1 effort 만 거부 → 모델 안내 없음"

# --- R2 환경 변수 출처 Codex effort 거부 ---
ab_reset; ab_legacy codex
fn_run r2 codex request-review other RD_REVIEW_CODEX_EFFORT=high SEL_LOG="$RV/codex_effort.log"
rv_has r2 effort "RD_REVIEW_CODEX_EFFORT 에";   chk $? "R2 effort 안내가 RD_REVIEW_CODEX_EFFORT 를 고치라고 함"
! rv_has r2 effort "$MJ";                       chk $? "R2 models.json 경로 없음"

# --- R3 REVIEW_TOOLS_CONFIG 의 옛 키 거부 ---
ab_reset
jq -n '{default_priority:["codex"], tools:{codex:{reasoning_effort:"high"}, claude:{self_review_policy:"off"}}}' > "$TMP/alt.json"
fn_run r3 codex request-review other REVIEW_TOOLS_CONFIG="$TMP/alt.json" SEL_LOG="$RV/codex_effort.log"
rv_has r3 effort "$TMP/alt.json";               chk $? "R3 effort 안내에 REVIEW_TOOLS_CONFIG 경로"
rv_has r3 effort "tools.codex.reasoning_effort"; chk $? "R3 effort 안내에 옛 키 tools.codex.reasoning_effort"

# --- R4 Codex 모델 미전달 + 모델 거부 ---
ab_reset; ab_legacy codex
fn_run r4 codex request-review other SEL_LOG="$RV/codex_model.log"
rv_has r4 모델 "프로젝트는 모델을 넘기지 않았습니다"; chk $? "R4 프로젝트는 모델을 넘기지 않았습니다"
rv_has r4 모델 "$ABH/.codex/config.toml";        chk $? "R4 Codex 홈의 config.toml 경로"
rv_has r4 모델 "RD_REVIEW_CODEX_MODEL=";         chk $? "R4 RD_REVIEW_CODEX_MODEL= 덮어쓰기"
! ab_err r4 "=default";                         chk $? "R4 =default 를 권하지 않음"

# --- R5 kill switch 설정 + Codex effort 거부, 이어서 해제 후 재실행 (r5b 는 실행기 실행) ---
ab_reset; ab_legacy codex
fn_run r5 codex request-review other RD_REVIEW_EFFORT_OVERRIDE=0 SEL_LOG="$RV/codex_effort.log"
rv_has r5 effort "model_reasoning_effort";      chk $? "R5 config.toml 의 model_reasoning_effort 확인"
rv_has r5 effort "unset RD_REVIEW_EFFORT_OVERRIDE"; chk $? "R5 kill switch 해제 안내"
rv_has r5 effort "RD_REVIEW_CODEX_EFFORT=";     chk $? "R5 RD_REVIEW_CODEX_EFFORT= 덮어쓰기"
! ab_err r5 "=default";                         chk $? "R5 =default 를 권하지 않음"
ab_run r5b request-review other RD_REVIEW_CODEX_EFFORT=high
ab_has r5b codex "-c $(EFF high)";              chk $? "R5 안내대로 다시 실행 → model_reasoning_effort=high 전달"

# --- R6 Claude 실측 모델 거부 + models.json 고정 이름 (실행기 실행: 실패 분기의 원인 줄과 안내 연결) ---
ab_reset; ab_legacy claude
ab_models '{"review":{"claude":{"model":"claude-nonexistent-zz9"}}}'
ab_run r6 request-review other FAKE_LOG="$RV_CL_MODEL"
ab_err r6 "원인(로그 끝 오류 줄 기준): 모델 없음"; chk $? "R6 원인 모델 없음"
rv_has r6 모델 "$MJ";                           chk $? "R6 모델 안내에 models.json 경로"
rv_has r6 모델 "review.claude.model";           chk $? "R6 모델 안내에 review.claude.model"
rv_has r6 모델 "RD_REVIEW_CLAUDE_MODEL=default"; chk $? "R6 이번만 인자 빼기 RD_REVIEW_CLAUDE_MODEL=default"

# --- R7 Claude 원인 불명 + effort 미전달, 이어서 안내대로 재실행 (r7b 는 실행기 실행) ---
ab_reset; ab_legacy claude
fn_run r7 claude request-review other SEL_LOG="$RV/claude_unknown.log"
rv_has r7 effort "CLI 기본값";                  chk $? "R7 effort 안내에 CLI 기본값"
rv_has r7 effort "RD_REVIEW_CLAUDE_EFFORT=";    chk $? "R7 RD_REVIEW_CLAUDE_EFFORT= 덮어쓰기"
! rv_has r7 effort ".claude";                   chk $? "R7 위치를 추측하지 않음 (.claude 없음)"
! rv_has r7 effort "settings.json";             chk $? "R7 위치를 추측하지 않음 (settings.json 없음)"
! rv_has r7 effort "=default";                  chk $? "R7 effort 안내에 =default 없음"
ab_run r7b request-review other RD_REVIEW_CLAUDE_EFFORT=high
ab_has r7b claude "--effort high";              chk $? "R7 안내대로 다시 실행 → --effort high"

# --- R8 Claude 원인 불명 + models.json effort 넘김 ---
ab_models '{"review":{"claude":{"effort":"high"}}}'
fn_run r8 claude request-review other SEL_LOG="$RV/claude_unknown.log"
rv_has r8 effort "$MJ";                         chk $? "R8 effort 안내에 models.json 경로"
rv_has r8 effort "review.claude.effort";        chk $? "R8 effort 안내에 review.claude.effort"
rv_has r8 effort "RD_REVIEW_CLAUDE_EFFORT=default"; chk $? "R8 이번만 인자 빼기 RD_REVIEW_CLAUDE_EFFORT=default"

# --- R9 Claude 원인 불명 + models.json effort=default (넘기지 않음) ---
ab_models '{"review":{"claude":{"effort":"default"}}}'
fn_run r9 claude request-review other SEL_LOG="$RV/claude_unknown.log"
rv_has r9 effort "review.claude.effort 의 값 때문에 넘기지 않았습니다"; chk $? "R9 넘기지 않은 이유의 위치"
rv_has r9 effort "CLI 기본값";                  chk $? "R9 CLI 기본값 안내"
! rv_has r9 effort "=default";                  chk $? "R9 effort 안내에 =default 없음"

# --- R10 Codex 복합 오류(effort·model 후보) → 두 칸 모두 안내 ---
ab_reset; ab_legacy codex
ab_models '{"review":{"codex":{"model":"sol","effort":"ultra"}}}'
fn_run r10 codex request-review other SEL_LOG="$RV/codex_both.log"
rv_has r10 모델 "review.codex.model";           chk $? "R10 모델 안내에 review.codex.model"
rv_has r10 effort "review.codex.effort";        chk $? "R10 effort 안내에 review.codex.effort"
ab_reset

# ============================================================
# 5) B·C 인라인 상태 표시 (AC 23) — 부모 표시와 프롬프트 식별자가 정확히 일치해야 한다
# ============================================================
echo "=== 인라인 상태 표시 5 케이스 ==="
IR="$TMP/inline"; mkdir -p "$IR/sess/turns" "$IR/rd-workflow/docs/prompts/review" "$IR/rd-workflow/docs/flows"
printf '# S\n\n## Status\nawaiting-reviewer\n' > "$IR/sess/SESSION.md"
printf '# C\n\n## Open Issues\n- 없음\n'       > "$IR/sess/CHECKPOINT.md"
printf '# U\n\n## Question For User\n-\n'      > "$IR/sess/USER_ACTION.md"
printf '# T\n\n본문\n'                          > "$IR/sess/turns/001_claude.md"
printf '리뷰 기준 본문\n'                       > "$IR/rd-workflow/docs/prompts/review/request_review.md"
{ i=0; while [ $i -lt 300 ]; do printf 'filler %s ------------------------------------------------\n' "$i"; i=$((i+1)); done; } \
  > "$IR/rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md"

PIPE_REL='rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md'
CRIT_REL='rd-workflow/docs/prompts/review/request_review.md'

gen_inline_raw() { # gen_inline_raw <출력> <review_type> <cap> → 부모 표시 줄 원문
  (
    source "${script_dir}/review_common.sh" 2>/dev/null
    set +e
    PROJECT_ROOT="$IR" REVIEW_PROMPT_INLINE_MAX_BYTES="$3" \
      build_review_prompt "$1" \
        sess sess/SESSION.md sess/CHECKPOINT.md sess/USER_ACTION.md \
        sess/turns/001_claude.md sess/turns/002_reviewer.md \
        "$2" TARGET.md goal 20 002 2>&1 1>/dev/null
  )
}
# 누적 바이트는 fixture 내용에 따라 변하므로, 식별자·원인 비교에서는 그 절만 떼어낸다.
# 바이트 표시 자체의 형식·cap 일치는 아래에서 따로 검증한다.
gen_inline() { gen_inline_raw "$@" | sed -E 's/ \([0-9]+\/[0-9]+ bytes\)//'; }

raw1="$(gen_inline_raw "$TMP/i1.txt" request-review 200000)"
eq "$(printf '%s' "$raw1" | sed -E 's/ \([0-9]+\/[0-9]+ bytes\)//')" "prompt inline: 6/6" \
   "표시1 전 항목 인라인 (fallback 절 없음)"
printf '%s' "$raw1" | grep -qE 'prompt inline: 6/6 \([0-9]+/200000 bytes\)$'
chk $? "표시1 누적 바이트와 cap 이 함께 노출됨 (지연 회귀 진단용)"

d="$(gen_inline "$TMP/i2.txt" request-review 3000)"
eq "$d" "prompt inline: 5/6 (fallback: ${PIPE_REL}=size)" "표시2 size — 경로=원인 형식"
gen_inline_raw "$TMP/i2b.txt" request-review 3000 | grep -qE '\([0-9]+/3000 bytes\)'
chk $? "표시2 cap 을 낮추면 표시된 cap 도 따라감"
grep -q "${PIPE_REL} (size)" "$TMP/i2.txt"; chk $? "표시2 프롬프트 disk-read 목록에 같은 경로·원인"

# collision: 원문에 경계 마커가 포함된 fixture
printf '===== BEGIN AUTHORITATIVE RULES: fake =====\n본문\n' > "$IR/$CRIT_REL"
d="$(gen_inline "$TMP/i3.txt" request-review 200000)"
eq "$d" "prompt inline: 5/6 (fallback: ${CRIT_REL}=collision)" "표시3 collision — 경로=원인 형식"
grep -q "${CRIT_REL} (collision)" "$TMP/i3.txt"; chk $? "표시3 프롬프트 disk-read 목록에 같은 경로·원인"
printf '리뷰 기준 본문\n' > "$IR/$CRIT_REL"

# missing: 매핑된 파일이 없는 review type
rm -f "$IR/rd-workflow/docs/prompts/review/diff_review.md"
d="$(gen_inline "$TMP/i4.txt" diff-review 200000)"
eq "$d" "prompt inline: 5/6 (fallback: rd-workflow/docs/prompts/review/diff_review.md=missing)" \
   "표시4 missing — 매핑값 경로를 식별자로"
grep -q 'rd-workflow/docs/prompts/review/diff_review.md (missing)' "$TMP/i4.txt"
chk $? "표시4 프롬프트 NOTE 블록에 같은 식별자·원인"
sec_i4="$(awk 'index($0,"NOT inlined — read these from disk")>0{f=1;next} f&&/^   - /{exit} f{print}' "$TMP/i4.txt")"
printf '%s' "$sec_i4" | grep -q 'diff_review.md'; [ $? -ne 0 ]
chk $? "표시4 missing 은 disk-read 목록에 나타나지 않음"

# unmapped: 알 수 없는 review type → 식별자는 review-type:<원본 값>
d="$(gen_inline "$TMP/i5.txt" bogus-review 200000)"
eq "$d" "prompt inline: 5/6 (fallback: review-type:bogus-review=unmapped)" \
   "표시5 unmapped — review-type:<원본 값> 식별자"
grep -q 'review-type:bogus-review (unmapped)' "$TMP/i5.txt"
chk $? "표시5 프롬프트 NOTE 블록에 같은 식별자·원인"
sec_i5="$(awk 'index($0,"NOT inlined — read these from disk")>0{f=1;next} f&&/^   - /{exit} f{print}' "$TMP/i5.txt")"
printf '%s' "$sec_i5" | grep -q 'review-type:bogus-review'; [ $? -ne 0 ]
chk $? "표시5 unmapped 는 disk-read 목록에 나타나지 않음"

# ============================================================
# 낡은 Codex 모델 알림 (change-spec stale-pinned-model-warning D1~D6·D9)
# 격리 디렉터리(.git 없음)에 복사한 model_select.sh 를 source 해, 프로젝트 루트가 격리 디렉터리가 되게 한다.
# 임시 HOME·CODEX_HOME·XDG_STATE_HOME 으로 돌아 실제 ~/.codex·상태 폴더를 읽거나 쓰지 않는다.
# ============================================================
echo "=== 낡은 Codex 모델 알림 ==="
NISO="$TMP/niso"; mkdir -p "$NISO/rd-workflow/scripts" "$NISO/rd-workflow/config"
for f in model_select.sh adapter_codex.sh adapter_claude.sh init_review_pipeline.sh; do cp "${script_dir}/$f" "$NISO/rd-workflow/scripts/"; done
NSH="$TMP/nshome"; mkdir -p "$NSH/.codex"; cp "$MS_SAMPLE" "$NSH/.codex/models_cache.json"
NBIN="$TMP/nbin"; mkdir -p "$NBIN"
for f in codex claude; do printf '#!/bin/sh\nexit 0\n' > "$NBIN/$f"; chmod +x "$NBIN/$f"; done
# ns_tools <우선순위 JSON 배열> [<codex bin>] [<claude bin>] — REVIEW_TOOLS_CONFIG 파일을 쓴다
ns_tools() {
  jq -n --argjson p "$1" --arg cb "${2:-}" --arg lb "${3:-}" '
    {default_priority: $p, tools: ((if $cb != "" then {codex: {bin: $cb}} else {} end)
      + (if $lb != "" then {claude: {bin: $lb}} else {} end))}' > "$TMP/ns-tools.json"
}
# ns <함수|명령...> — NISO 의 model_select.sh 를 source 해 부른다. stderr 는 $TMP/ns.err, 환경은 임시 홈들.
ns() {
  ( export HOME="$NSH" XDG_STATE_HOME="${NS_STATE:-$NSH/state}" CODEX_HOME="${NS_CODEX:-$NSH/.codex}" \
      REVIEW_TOOLS_CONFIG="$TMP/ns-tools.json" RD_MODELS_CONFIG="${NS_MODELS:-$NISO/rd-workflow/config/models.json}"
    cd "${NS_ROOT:-$NISO}" || exit 99
    source rd-workflow/scripts/model_select.sh
    "$@" ) 2>"$TMP/ns.err"
}
ns_reset() { # 케이스마다 models.json·config.toml·기록 파일을 지우고 N1 의 기본 도구 배치로 되돌린다
  rm -rf "$NISO/rd-workflow/config/models.json" "$NSH/.codex/config.toml" "$NISO/.codex" "$NSH/state" "$NSH/.local"
  cp "$MS_SAMPLE" "$NSH/.codex/models_cache.json"
  ns_tools '["codex","claude"]' "$NBIN/codex"
}
ns_models() { printf '%s\n' "$1" > "$NISO/rd-workflow/config/models.json"; }
ns_none() { [ ! -s "$TMP/ns.err" ]; }
ns_has() { grep -qF -- "$1" "$TMP/ns.err"; }
N1_FRAGS=(
  "새 모델 'gpt-6.2-sol'"
  "review.codex.model 을 계열 이름 'sol'"
  "set review.codex.model sol"
  "선택 1 — 이번만 옛 모델로 진행"
  "선택 2 — 옛 모델을 계속 쓰고 기록: bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol"
  "사용자에게 물을 수 있으면 첫 리뷰 턴 전에 두 선택지를 묻고 답대로 진행합니다"
  "무인 실행(autopilot·claude -p)이면 묻지 않고 선택 1 로 진행하고, 그 실행의 보고에 이 경고를 옮깁니다"
)
n1_check() { # n1_check <stderr 파일> <라벨> — 일곱 문자열이 모두 있고 경고 첫 줄이 정확히 한 번
  local f="$1" lab="$2" s ok=0 n
  for s in "${N1_FRAGS[@]}"; do grep -qF -- "$s" "$f" || { ok=1; echo "    누락: $s"; }; done
  n="$(grep -cF "새 모델 'gpt-6.2-sol'" "$f")"
  [ "$n" = 1 ] || { ok=1; echo "    경고 첫 줄 수=$n"; }
  chk "$ok" "$lab"
}
NS_T0=$SECONDS

# --- N1 계열 최신보다 낮은 고정 이름 ---
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.1-sol"}}}'
ns ms_codex_stale_notice request-review; rc=$?
eq "$rc" 0 "N1 알림 함수는 rc 0"
n1_check "$TMP/ns.err" "N1 경고 묶음(일곱 문자열 + 첫 줄 한 번)"

# --- N2 이미 최신 / 계열 이름 ---
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.2-sol"}}}'
ns ms_codex_stale_notice request-review; ns_none; chk $? "N2 최신 고정 이름은 알리지 않음"
ns_reset; ns_models '{"review":{"codex":{"model":"sol"}}}'
ns ms_codex_stale_notice request-review; ns_none; chk $? "N2 계열 이름은 알리지 않음"

# --- N3 config.toml 모델 (고정 값 없음·default·해석 실패) ---
ns_reset; printf 'model = "gpt-6-sol"\n' > "$NSH/.codex/config.toml"
ns ms_codex_stale_notice request-review
ns_has "새 모델 'gpt-6.2-sol'" && ns_has "config.toml 의 model" && ns_has "review.codex.model 을 계열"; chk $? "N3 models.json 없음: config.toml 출처, 바꿀 곳 review.codex.model"
RD_REVIEW_CODEX_MODEL=default ns ms_codex_stale_notice request-review
ns_has "새 모델 'gpt-6.2-sol'" && ns_has "config.toml 의 model" && ns_has "환경 변수 RD_REVIEW_CODEX_MODEL 을 계열"; chk $? "N3 환경 변수 default: 바꿀 곳이 환경 변수"
! ns_has "set review.codex.model"; chk $? "N3 환경 변수는 set 명령을 붙이지 않음"
ns_models '{"review":{"codex":{"model":"nosuch"}}}'
ns ms_codex_stale_notice request-review
ns_has "새 모델 'gpt-6.2-sol'" && ns_has "config.toml 의 model" && ns_has "review.codex.model 을 계열"; chk $? "N3 해석 실패 값: config.toml 출처, 바꿀 곳 review.codex.model"

# --- N3b Codex 가 다른 층에서 모델을 정할 수 있으면 알리지 않음 ---
ns_reset; printf 'model = "gpt-6-sol"\n' > "$NSH/.codex/config.toml"
mkdir -p "$NISO/.codex"; printf 'model = "gpt-6.2-sol"\n' > "$NISO/.codex/config.toml"
ns ms_codex_stale_notice request-review; ns_none; chk $? "N3b 프로젝트 .codex/config.toml 의 model 이 있으면 알리지 않음"
printf '"model" = "gpt-6.2-sol"\n' > "$NISO/.codex/config.toml"
ns ms_codex_stale_notice request-review; ns_none; chk $? "N3b 인용한 키(\"model\")도 같은 최상위 키로 보고 알리지 않음"
printf 'developer_instructions = """\n[Project guide](https://example.org/guide)\n"""\nm = [\n  [1, 2],\n]\nmodel = "gpt-6.2-sol"\n' > "$NISO/.codex/config.toml"
ns ms_codex_stale_notice request-review; ns_none; chk $? "N3b 여러 줄 문자열·배열 안의 [ 줄을 절 시작으로 보지 않고 뒤의 model 을 찾음"
ns_reset; printf 'model = "gpt-6-sol"\nprofile = "x"\n' > "$NSH/.codex/config.toml"
ns ms_codex_stale_notice request-review; ns_none; chk $? "N3b 홈 config.toml 의 profile 이 있으면 알리지 않음"

# --- N3c 저장소 하위 폴더를 프로젝트 루트로 쓰는 배치 (.git 파일 경계) ---
NOUT="$TMP/nouter"; NREP="$NOUT/nrepo"; NSUB="$NREP/sub"
mkdir -p "$NSUB/rd-workflow/scripts"
for f in model_select.sh adapter_codex.sh adapter_claude.sh init_review_pipeline.sh; do cp "${script_dir}/$f" "$NSUB/rd-workflow/scripts/"; done
printf 'gitdir: %s\n' "$TMP/nowhere" > "$NREP/.git"
ns_reset; ns_tools '["codex"]' "$NBIN/codex"; printf 'model = "gpt-6-sol"\n' > "$NSH/.codex/config.toml"
mkdir -p "$NREP/.codex"; printf 'model = "gpt-6.2-sol"\n' > "$NREP/.codex/config.toml"
NS_ROOT="$NSUB" NS_MODELS="$TMP/none.json" ns ms_codex_stale_notice request-review; ns_none; chk $? "N3c 저장소 경계 안의 설정을 반영(알리지 않음)"
mkdir -p "$NOUT/.codex"; mv "$NREP/.codex/config.toml" "$NOUT/.codex/config.toml"; rmdir "$NREP/.codex"
NS_ROOT="$NSUB" NS_MODELS="$TMP/none.json" ns ms_codex_stale_notice request-review
ns_has "새 모델 'gpt-6.2-sol'" && ns_has "config.toml 의 model"; chk $? "N3c 경계 밖 설정은 보지 않고 알림"

# --- N4 환경 변수와 models.json 의 우선순위 ---
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.2-sol"}}}'
RD_REVIEW_CODEX_MODEL=gpt-6.1-sol ns ms_codex_stale_notice request-review
ns_has "'gpt-6.1-sol'(환경 변수 RD_REVIEW_CODEX_MODEL)" && ns_has "환경 변수 RD_REVIEW_CODEX_MODEL 을 계열"; chk $? "N4 환경 변수가 낡으면 출처·바꿀 곳이 환경 변수"
ns_models '{"review":{"codex":{"model":"gpt-6.1-sol"}}}'
RD_REVIEW_CODEX_MODEL=gpt-6.2 ns ms_codex_stale_notice request-review
ns_has "'gpt-6.1-sol'(" && ns_has "review.codex.model)보다 새 모델" && ! ns_has "환경 변수 RD_REVIEW_CODEX_MODEL 을 계열"; chk $? "N4 무효한 환경 변수는 무시하고 models.json 을 판정"

# --- N4a RD_MODELS_CONFIG 가 다른 파일(경로에 공백) ---
mkdir -p "$TMP/my cfg"; NQ="$(printf %q "$TMP/my cfg/m.json")"
ns_reset; printf '%s\n' '{"review":{"codex":{"model":"gpt-6.1-sol"}}}' > "$TMP/my cfg/m.json"
NS_MODELS="$TMP/my cfg/m.json" ns ms_codex_stale_notice request-review
ns_has "RD_MODELS_CONFIG=$NQ bash rd-workflow/scripts/model_select.sh set review.codex.model sol" && ! ns_has "rd-workflow/config/models.json" \
  && ns_has "'gpt-6.1-sol'($TMP/my cfg/m.json 의 review.codex.model)"; chk $? "N4a 다른 models.json: 출처·명령이 그 파일, 기본 경로 없음"
ns_reset; printf '%s\n' '{"version":1}' > "$TMP/my cfg/m.json"; printf 'model = "gpt-6-sol"\n' > "$NSH/.codex/config.toml"
NS_MODELS="$TMP/my cfg/m.json" ns ms_codex_stale_notice request-review
ns_has "RD_MODELS_CONFIG=$NQ bash rd-workflow/scripts/model_select.sh set review.codex.model sol" && ! ns_has "rd-workflow/config/models.json"; chk $? "N4a 칸 없음: 명령이 그 파일, 기본 경로 없음"
ns_has "config.toml 의 model" && ns_has "$TMP/my cfg/m.json 의 review.codex.model 을 계열 이름 'sol'"; chk $? "N4a 칸 없음: 출처 config.toml, 바꿀 곳이 그 파일 경로 전문"

# --- N5 기록 명령 뒤에는 알리지 않고, 더 새 모델이 나오면 다시 알림 ---
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.1-sol"}}}'
ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null
ns ms_codex_stale_notice request-review; ns_none; chk $? "N5 기록한 쌍은 다시 알리지 않음"
mkdir -p "$TMP/nc2"; jq '.models += [{"slug":"gpt-6.4-sol","visibility":"list","priority":0}]' "$MS_SAMPLE" > "$TMP/nc2/models_cache.json"
NS_CODEX="$TMP/nc2" ns ms_codex_stale_notice request-review; ns_has "새 모델 'gpt-6.4-sol'"; chk $? "N5 더 새 계열 모델이 나오면 다시 알림"

# --- N6 숨은 더 높은 버전은 최신으로 보지 않음 ---
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.3-sol"}}}'
ns ms_codex_stale_notice request-review; ns_none; chk $? "N6 visibility 가 list 가 아닌 더 높은 버전은 무시"

# --- N7 판정 불가(캐시 없음) ---
mkdir -p "$TMP/nocodex"
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.1-sol"}}}'
NS_CODEX="$TMP/nocodex" ns ms_codex_stale_notice request-review
eq "$(grep -cF '고정됨, 낡을 수 있음' "$TMP/ns.err")" 1 "N7 고정 이름: 판정 불가 한 줄"
ns_reset; printf 'model = "gpt-6-sol"\n' > "$TMP/nocodex/config.toml"
NS_CODEX="$TMP/nocodex" ns ms_codex_stale_notice request-review; ns_none; chk $? "N7 config.toml 모델: 판정 불가여도 알리지 않음"
rm -f "$TMP/nocodex/config.toml"

# --- N8 첫 실행 가능 도구가 Codex 가 아니면 알리지 않음 ---
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.1-sol"}}}'
printf '%s\n' "{\"default_priority\":[\"codex\"],\"overrides\":{\"request-review\":{\"priority\":[\"claude\"]}},\"tools\":{\"codex\":{\"bin\":\"$NBIN/codex\"},\"claude\":{\"bin\":\"$NBIN/claude\"}}}" > "$TMP/ns-tools.json"
ns ms_codex_stale_notice request-review; ns_none; chk $? "N8 리뷰 종류 우선순위의 첫 도구가 claude 면 알리지 않음"
ns_tools '["codex"]' "$TMP/nobin/codex"
ns ms_codex_stale_notice request-review; ns_none; chk $? "N8 Codex 실행 파일이 없으면 알리지 않음"
ns_tools '["claude","codex"]' "$NBIN/codex" "$TMP/nobin/claude"
ns ms_codex_stale_notice request-review; ns_has "새 모델 'gpt-6.2-sol'"; chk $? "N8 Claude 실행 파일이 없으면 다음 도구 Codex 로 알림"

# --- N10 keep-codex-model ---
NKEEP="$NSH/state/rd-workflow/codex-model-keep.tsv"
ns_reset
ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-astra >/dev/null; rc=$?
eq "$rc" 1 "N10 (1) 계열이 다르면 exit 1"
ns bash rd-workflow/scripts/model_select.sh keep-codex-model sol gpt-6.2-sol >/dev/null; rc=$?
eq "$rc" 1 "N10 (2) 고정 이름이 아니면 exit 1"
ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null
out="$(ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol)"; rc=$?
eq "$(wc -l < "$NKEEP" | tr -d ' ')" 1 "N10 (3) 같은 쌍을 두 번 실행해도 파일 줄 수 1"
printf '%s' "$out" | grep -qF "이미 기록돼"; chk $? "N10 (3) 둘째 실행은 이미 기록돼 있음 안내"
printf 'x' > "$TMP/notdir"
NS_STATE="$TMP/notdir/sub" ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null 2>&1; rc=$?
eq "$rc" 1 "N10 (4a) 폴더를 만들 수 없으면 exit 1"
NS_STATE="$TMP/notdir/sub" ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null
ns_has "폴더를 만들지 못함"; chk $? "N10 (4a) 안내에 폴더를 만들지 못함"
mkdir -p "$TMP/st4b/rd-workflow/codex-model-keep.tsv"
NS_STATE="$TMP/st4b" ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null 2>&1; rc=$?
eq "$rc" 1 "N10 (4b) 덧붙일 수 없으면 exit 1"
NS_STATE="$TMP/st4b" ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null
ns_has "파일에 쓰지 못함"; chk $? "N10 (4b) 안내에 파일에 쓰지 못함"
NS_STATE=rel ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null
grep -qF "gpt-6.1-sol	gpt-6.2-sol" "$NSH/.local/state/rd-workflow/codex-model-keep.tsv" 2>/dev/null; chk $? "N10 (5) 상태 폴더가 상대 경로면 HOME 아래에 기록"
rm -rf "$NSH/state"; mkdir -p "$NSH/state/rd-workflow"; printf 'a\tb' > "$NKEEP"
ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6.1-sol gpt-6.2-sol >/dev/null
eq "$(wc -l < "$NKEEP" | tr -d ' ')" 2 "N10 (6) 줄바꿈 없이 끝난 파일에 덧붙여도 줄 수 2"
eq "$(sed -n 2p "$NKEEP")" "$(printf 'gpt-6.1-sol\tgpt-6.2-sol')" "N10 (6) 둘째 줄이 새 쌍"
# (7) 잠금 폴더가 남아 있으면 30번 다시 시도한 뒤(몇 초) 기록하지 않고 안내한다. 두 기록이 겹치는 경합 자체는 테스트로 두지 않는다.
mkdir "$NKEEP.lock"
ns bash rd-workflow/scripts/model_select.sh keep-codex-model gpt-6-sol gpt-6.2-sol >/dev/null; rc=$?
eq "$rc" 1 "N10 (7) 잠금을 얻지 못하면 exit 1"
ns_has "잠금 폴더(" && ! grep -qF "gpt-6-sol	gpt-6.2-sol" "$NKEEP"; chk $? "N10 (7) 잠금 폴더 안내, 기록하지 않음"
rmdir "$NKEEP.lock"

# --- N11 세션 생성이 알림을 한 번 낸다 ---
ns_reset; ns_models '{"review":{"codex":{"model":"gpt-6.1-sol"}}}'
( cd "$NISO" && HOME="$NSH" XDG_STATE_HOME="$NSH/state" CODEX_HOME="$NSH/.codex" REVIEW_TOOLS_CONFIG="$TMP/ns-tools.json" \
    RD_MODELS_CONFIG="$NISO/rd-workflow/config/models.json" bash rd-workflow/scripts/init_review_pipeline.sh n11 request-review ) \
  >"$TMP/n11.out" 2>"$TMP/n11.err"; rc=$?
eq "$rc" 0 "N11 init 은 exit 0"
n11_line="$(head -n 1 "$TMP/n11.out")"
{ [ "$(wc -l < "$TMP/n11.out" | tr -d ' ')" = 1 ] && case "$n11_line" in rd-workflow-workspace/handoffs/review_pipeline/*) true ;; *) false ;; esac \
  && [ -f "$NISO/$n11_line/SESSION.md" ]; }; chk $? "N11 stdout 은 세션 경로 한 줄이고 SESSION.md 가 있음"
n1_check "$TMP/n11.err" "N11 init 의 stderr 가 경고 묶음 한 번"
echo "  (낡은 Codex 모델 알림 절 실행 $((SECONDS - NS_T0))초)"

echo "=== 구현 subagent 칸 ==="; subagent_cli_case

echo "=== 예시 복사 ==="
example_copy_case "${RD_TEST_TREE:-$(cd "${script_dir}/../.." && pwd)}"

finish
