#!/usr/bin/env bash
# verify.sh — 프롬프트 기반 산출물 검증
# 용도: test/lint/typecheck 대신 AI 프롬프트로 산출물 품질을 평가
# 종료코드: 0 = PASS, 1 = FAIL
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── 필수 파일 확인 ──────────────────────────────────────
PROJECT_CONTEXT="${PROJECT_ROOT}/PROJECT_CONTEXT.md"
REQUEST="${PROJECT_ROOT}/REQUEST.md"
CURRENT_TASK="${PROJECT_ROOT}/CURRENT_TASK.md"
DEFAULT_VERIFY_PROMPT="rd-workflow/docs/prompts/verify/default.md"

if [[ ! -f "$PROJECT_CONTEXT" ]]; then
  echo "ERROR: PROJECT_CONTEXT.md를 찾을 수 없습니다." >&2
  exit 1
fi

if [[ ! -f "$REQUEST" ]]; then
  echo "ERROR: REQUEST.md를 찾을 수 없습니다." >&2
  exit 1
fi

# ── verify_prompt 경로 추출 ──────────────────────────────
# PROJECT_CONTEXT.md에서 verify_prompt 값을 읽음
verify_prompt_rel="$(grep -E '^\s*-?\s*verify_prompt:' "$PROJECT_CONTEXT" \
  | head -1 \
  | sed 's/^.*verify_prompt:\s*//' \
  | xargs)" || true

if [[ -z "$verify_prompt_rel" ]]; then
  verify_prompt_rel="$DEFAULT_VERIFY_PROMPT"
  echo "INFO: verify_prompt 설정 없음 → 기본값 사용 ($DEFAULT_VERIFY_PROMPT)" >&2
fi

VERIFY_PROMPT="${PROJECT_ROOT}/${verify_prompt_rel}"

if [[ ! -f "$VERIFY_PROMPT" ]]; then
  echo "ERROR: 검증 프롬프트 파일을 찾을 수 없습니다: $VERIFY_PROMPT" >&2
  exit 1
fi

# ── 산출물 파일 탐색 ─────────────────────────────────────
# 우선순위: CURRENT_TASK.md의 Output Files → REQUEST.md의 Affected Area
output_files=()

if [[ -f "$CURRENT_TASK" ]]; then
  # CURRENT_TASK.md에서 "Output Files" 또는 "산출물" 섹션 파싱
  while IFS= read -r line; do
    # "- path/to/file" 형태의 줄에서 경로 추출
    file_path="$(echo "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)/\1/p' | xargs)"
    if [[ -n "$file_path" ]]; then
      resolved="${PROJECT_ROOT}/${file_path}"
      [[ -f "$resolved" ]] && output_files+=("$file_path")
    fi
  done < <(awk '
    /^##\s*(Output Files|산출물)/ { in_section = 1; next }
    in_section && /^##/ { exit }
    in_section { print }
  ' "$CURRENT_TASK")
fi

# Output Files가 비었으면 REQUEST.md의 affected area에서 탐색
if [[ ${#output_files[@]} -eq 0 ]]; then
  while IFS= read -r line; do
    file_path="$(echo "$line" | sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)/\1/p' | xargs)"
    if [[ -n "$file_path" ]]; then
      resolved="${PROJECT_ROOT}/${file_path}"
      [[ -f "$resolved" ]] && output_files+=("$file_path")
    fi
  done < <(awk '
    /^##\s*(Affected Area|영향 범위|산출물)/ { in_section = 1; next }
    in_section && /^##/ { exit }
    in_section { print }
  ' "$REQUEST")
fi

if [[ ${#output_files[@]} -eq 0 ]]; then
  echo "WARNING: 검증 대상 산출물 파일을 찾지 못했습니다." >&2
  echo "CURRENT_TASK.md에 'Output Files' 섹션 또는 REQUEST.md에 'Affected Area'를 확인하세요." >&2
  echo "산출물 없이 검증을 건너뜁니다." >&2
  exit 0
fi

echo "=== 검증 대상 산출물 ==="
for f in "${output_files[@]}"; do
  echo "  - $f"
done
echo ""

# ── 산출물 내용 수집 ─────────────────────────────────────
output_contents=""
for f in "${output_files[@]}"; do
  resolved="${PROJECT_ROOT}/${f}"
  output_contents+="
--- 파일: ${f} ---
$(cat "$resolved")

"
done

# ── 검증 프롬프트 조립 ───────────────────────────────────
verify_instructions="$(cat "$VERIFY_PROMPT")"
project_context="$(cat "$PROJECT_CONTEXT")"
request_content="$(cat "$REQUEST")"

combined_prompt="$(cat <<PROMPT_EOF
${verify_instructions}

---

## PROJECT_CONTEXT.md

${project_context}

---

## REQUEST.md

${request_content}

---

## 검증 대상 산출물

${output_contents}

---

위 지시에 따라 각 기준별 PASS/FAIL 판정과 종합 판정을 출력하세요.
PROMPT_EOF
)"

# ── Claude CLI 실행 ───────────────────────────────────────
claude_bin="${TOOL_BIN:-claude}"

if ! command -v "$claude_bin" &>/dev/null; then
  echo "ERROR: Claude CLI를 찾을 수 없습니다: $claude_bin" >&2
  echo "Claude CLI가 설치되어 있는지 확인하세요." >&2
  exit 1
fi

REPORT_DIR="${PROJECT_ROOT}/rd-workflow-workspace/reports/verifications"
mkdir -p "$REPORT_DIR"
TIMESTAMP="$(date '+%Y-%m-%d-%H%M%S')"
REPORT_FILE="${REPORT_DIR}/${TIMESTAMP}-verify.md"

echo "=== Claude CLI로 검증 실행 중... ==="
echo ""

# 임시 프롬프트 파일 생성
tmp_prompt="$(mktemp)"
chmod 600 "$tmp_prompt"
echo "$combined_prompt" > "$tmp_prompt"
trap 'rm -f "$tmp_prompt"' EXIT

# Claude CLI 호출
result="$("$claude_bin" -p "$(cat "$tmp_prompt")" \
  --allowedTools 'Read' 'Glob' 'Grep' \
  2>/dev/null)" || {
  echo "ERROR: Claude CLI 실행 실패" >&2
  exit 1
}

if [[ -z "$result" ]]; then
  echo "ERROR: Claude CLI가 빈 응답을 반환했습니다." >&2
  exit 1
fi

# ── 결과 저장 ─────────────────────────────────────────────
cat <<REPORT_EOF > "$REPORT_FILE"
# 검증 결과

- 일시: ${TIMESTAMP}
- 검증 프롬프트: ${verify_prompt_rel}
- 대상 파일: $(printf '%s, ' "${output_files[@]}" | sed 's/, $//')

---

${result}
REPORT_EOF

echo "$result"
echo ""
echo "=== 검증 보고서 저장: ${REPORT_FILE#"$PROJECT_ROOT"/} ==="

# ── PASS/FAIL 판정 ────────────────────────────────────────
# 종합 판정에서 FAIL이 있으면 exit 1
if echo "$result" | grep -qiE '(종합|overall)[^:]*:\s*FAIL'; then
  echo ""
  echo "❌ 검증 실패 — 위 피드백을 확인하고 산출물을 수정하세요."
  exit 1
fi

echo ""
echo "✅ 검증 통과"
exit 0
