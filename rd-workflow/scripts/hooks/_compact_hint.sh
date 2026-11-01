#!/usr/bin/env bash
# _compact_hint.sh — source 전용 (함수 정의만, source 시 동작 없음)
# 압축(compact) 뒤 SessionStart 에서 autopilot 규칙 재독 안내를 낸다.

# compact_hint_emit <hook-input> <status> <slug> <project_root>
compact_hint_emit() {
  local input="${1:-}" status="${2:-}" slug="${3:-}" root="${4:-}"
  local src section
  src="$(printf '%s' "$input" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n 1)"
  [[ "$src" == "compact" ]] || return 0
  bash "${root}/rd-workflow/scripts/autopilot_driver.sh" check >/dev/null 2>&1 || return 0

  # Status → 절 대응표 (이 함수 안 한 곳에만 둔다)
  case "$status" in
    "대기 중"|"REQUEST review 대기"|"spec/plan review 대기"|"diff review 대기")
      section='`### 2. 리뷰`' ;;
    "spec/plan 작성 중"|"구현 대기"|"구현 중"|"검증 중")
      section='`### 4. 자율 구현` 과 `### 5. 세션 한계 대응`' ;;
    "아카이브 보류"|"완료")
      section='`### 6. 마무리` 와 `### 7. 최종 보고`' ;;
    *)
      section='`## Execution Rules` 전체' ;;
  esac

  echo "[hooks] 압축 안내: 이 작업(${slug})이 autopilot 으로 진행 중이었다면 규칙이 압축으로 빠졌을 수 있습니다."
  echo "  rd-workflow/claude_skills/autopilot/SKILL.md 에서 \`## Autonomy Override\` 와 ${section} 을 Read 로 다시 읽고 따르십시오."
  echo "  (사람이 수동으로 이어가는 중이면 이 안내는 무시해도 됩니다. 현재 Status: ${status})"
  return 0
}
