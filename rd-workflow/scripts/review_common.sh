#!/usr/bin/env bash
# review_common.sh — 리뷰 파이프라인 공통 함수
# source로 로드하여 사용

set -euo pipefail

resolve_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s\n' "${PROJECT_ROOT:-.}/${input}"
  fi
}

extract_section() {
  local file="$1"
  local section="$2"
  awk -v target="## ${section}" '
    $0 == target { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$file"
}

trim_blank_lines() {
  awk '
    NF { last = NR }
    { lines[NR] = $0 }
    END {
      start = 1
      while (start <= NR && lines[start] ~ /^[[:space:]]*$/) start++
      for (i = start; i <= last; i++) print lines[i]
    }
  '
}

validate_owner_input() {
  local owner="$1"
  case "$owner" in
    Author|Claude|Reviewer|Codex|User)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_owner_output() {
  local owner="$1"
  case "$owner" in
    Author|Claude|User)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# 세션 디렉토리 구조 검증
# 사용: validate_session_dir <session_dir>
# 설정: SESSION_FILE, CHECKPOINT_FILE, USER_ACTION_FILE, TURNS_DIR 변수
validate_session_dir() {
  local session_dir="$1"

  SESSION_FILE="${session_dir}/SESSION.md"
  CHECKPOINT_FILE="${session_dir}/CHECKPOINT.md"
  USER_ACTION_FILE="${session_dir}/USER_ACTION.md"
  TURNS_DIR="${session_dir}/turns"

  for required_file in "$SESSION_FILE" "$CHECKPOINT_FILE" "$USER_ACTION_FILE"; do
    if [[ ! -f "$required_file" ]]; then
      echo "required file not found: $required_file" >&2
      return 1
    fi
  done

  if [[ ! -d "$TURNS_DIR" ]]; then
    echo "turns directory not found: $TURNS_DIR" >&2
    return 1
  fi
}

# 세션 상태 추출
# 사용: load_session_state <session_file>
# 설정: STATUS, CURRENT_OWNER, REVIEW_TYPE, REVIEW_TARGET, REVIEW_GOAL 변수
load_session_state() {
  local session_file="$1"
  STATUS="$(extract_section "$session_file" "Status" | trim_blank_lines)"
  CURRENT_OWNER="$(extract_section "$session_file" "Current Owner" | trim_blank_lines)"
  REVIEW_TYPE="$(extract_section "$session_file" "Review Type" | trim_blank_lines)"
  REVIEW_TARGET="$(extract_section "$session_file" "Review Target" | trim_blank_lines)"
  REVIEW_GOAL="$(extract_section "$session_file" "Review Goal" | trim_blank_lines)"
}

# 다음 턴 번호 계산
# 사용: compute_next_turn <turns_dir> <agent_label>
# 설정: LATEST_TURN_FILE, NEXT_TURN_NUMBER, NEXT_TURN_INDEX, EXPECTED_TURN_FILE, EXISTING_TURN_COUNT 변수
compute_next_turn() {
  local turns_dir="$1"
  local agent_label="$2"

  LATEST_TURN_FILE="$(find "$turns_dir" -maxdepth 1 -type f -name '*.md' | sort | tail -n 1)"

  if [[ -z "$LATEST_TURN_FILE" ]]; then
    echo "session has no prior turns; Author should write the first turn before Reviewer runs" >&2
    return 1
  fi

  local latest_turn_base
  latest_turn_base="$(basename "$LATEST_TURN_FILE")"
  local latest_turn_number="${latest_turn_base%%_*}"
  local latest_turn_agent="${latest_turn_base#*_}"
  latest_turn_agent="${latest_turn_agent%.md}"

  # legacy 파일명 alias 정규화 (codex→reviewer, claude→author)
  case "$latest_turn_agent" in
    codex) latest_turn_agent="reviewer" ;;
    claude) latest_turn_agent="author" ;;
  esac

  # 최신 턴이 이미 같은 역할인지 충돌 방지 검사
  if [[ "$latest_turn_agent" == "$agent_label" ]]; then
    echo "latest turn already belongs to ${agent_label}; refusing to run due to session state conflict" >&2
    return 1
  fi

  EXISTING_TURN_COUNT="$(find "$turns_dir" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d '[:space:]')"

  NEXT_TURN_NUMBER="$(printf '%03d' "$((10#${latest_turn_number} + 1))")"
  NEXT_TURN_INDEX="$((10#${NEXT_TURN_NUMBER}))"
  EXPECTED_TURN_FILE="${turns_dir}/${NEXT_TURN_NUMBER}_${agent_label}.md"
}

# 리뷰 프롬프트 생성
build_review_prompt() {
  local output_file="$1"
  local session_dir_rel="$2"
  local session_file_rel="$3"
  local checkpoint_file_rel="$4"
  local user_action_file_rel="$5"
  local latest_turn_file_rel="$6"
  local expected_turn_file_rel="$7"
  local review_type="$8"
  local review_target="$9"
  local review_goal="${10}"
  local turn_limit="${11}"
  local next_turn_number="${12}"

  cat <<EOF > "$output_file"
You are continuing an existing file-based review session.

Follow the rules in:
- rd-workflow/docs/flows/FILE_BASED_REVIEW_PIPELINE.md

Session execution contract:
- SESSION_DIR: ${session_dir_rel}
- SESSION_FILE: ${session_file_rel}
- CHECKPOINT_FILE: ${checkpoint_file_rel}
- USER_ACTION_FILE: ${user_action_file_rel}
- LATEST_TURN_FILE: ${latest_turn_file_rel}
- EXPECTED_TURN_FILE: ${expected_turn_file_rel}
- REVIEW_TYPE: ${review_type}
- TURN_LIMIT: ${turn_limit} total turns
- THIS_TURN_NUMBER: ${next_turn_number}

Review target:
${review_target}

Review goal:
${review_goal}

You must do all of the following:
1. Read SESSION.md, CHECKPOINT.md, USER_ACTION.md, the latest turn files, and the review target.
2. Create exactly one new turn file at EXPECTED_TURN_FILE.
3. Update CHECKPOINT_FILE.
4. Update SESSION_FILE so that Current Owner is no longer Reviewer.
5. If unresolved objections remain after your review, default to Status=awaiting-author and hand the session back to Author.
6. Only set Status=awaiting-user if one of these is true: you explicitly have no remaining objections, user input is required, or this turn reaches the ${turn_limit}-turn limit.
7. If you have no remaining objections, say that explicitly in Disagreement and Proposed Decision.

Constraints:
- Do not modify files outside the review session except to read the review target.
- Do not create a second turn file.
- Use EXPECTED_TURN_FILE exactly as given. Do not rename, renumber, or "fix" the turn file path.
- Do not leave Current Owner as Reviewer.
- The session may not exceed ${turn_limit} total turn files.
- If this is turn ${turn_limit}, you must stop the loop by setting Status=awaiting-user.
- Do not answer the human directly; the files are the source of truth.
- Do not implement code changes or create commits.

Required turn file sections:
- Summary
- Findings
- Agreement
- Disagreement
- Questions
- Proposed Decision
- Next Owner

If you cannot continue safely, record the blocker in CHECKPOINT_FILE and set Current Owner to User with Status awaiting-user.
At the end, print a short summary of what you changed.
EOF
}

# 턴 실행 후 출력 검증
validate_turn_output() {
  local session_file="$1"
  local expected_turn_file="$2"
  local next_turn_index="$3"
  local turn_limit="$4"
  local tool_name="$5"

  if [[ ! -f "$expected_turn_file" ]]; then
    echo "${tool_name} did not create the expected turn file: $expected_turn_file" >&2
    return 1
  fi

  local updated_status
  local updated_owner
  updated_status="$(extract_section "$session_file" "Status" | trim_blank_lines)"
  updated_owner="$(extract_section "$session_file" "Current Owner" | trim_blank_lines)"

  case "$updated_status" in
    awaiting-author|awaiting-claude|awaiting-user|closed)
      ;;
    *)
      echo "invalid session status after ${tool_name} run: $updated_status" >&2
      return 1
      ;;
  esac

  if ! validate_owner_output "$updated_owner"; then
    echo "invalid current owner after ${tool_name} run: $updated_owner" >&2
    return 1
  fi

  if [[ "$next_turn_index" -eq "$turn_limit" && "$updated_status" == "awaiting-author" ]]; then
    echo "turn limit reached but ${tool_name} handed the session back to Author" >&2
    return 1
  fi

  echo "$updated_status"
}

# SESSION.md에 Tool History 행 추가
append_tool_history() {
  local session_file="$1"
  local turn_number="$2"
  local tool_name="$3"
  local mode="$4"

  # Tool History 섹션이 없으면 추가
  if ! grep -q "^## Tool History" "$session_file"; then
    printf '\n## Tool History\n| Turn | Tool | Mode |\n|------|------|------|\n' >> "$session_file"
  fi

  printf '| %s | %s | %s |\n' "$turn_number" "$tool_name" "$mode" >> "$session_file"
}
