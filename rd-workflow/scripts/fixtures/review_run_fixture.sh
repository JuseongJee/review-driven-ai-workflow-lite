#!/usr/bin/env bash
# review_run_fixture.sh — 테스트용 「리뷰어 턴이 실제로 실행된 세션」 fixture.
# `rd review seal` 은 reviewer_runs.tsv 의 실행 기록을 대조하므로, 손으로 종결한 세션은
# 거부됩니다. 이 함수는 리뷰어 턴 파일을 쓰고 기록은 **제품 함수**(append_reviewer_run)로
# 남겨, 쓰는 쪽과 읽는 쪽의 형식이 어긋나면 이 fixture 를 쓰는 seal 테스트가 실패하게 합니다.
# 이 파일은 source 용이며 직접 실행하지 않습니다. bash 3.2 호환.

# fixture_reviewer_turn <session_dir> <scripts_dir> [open-issues 본문]
#   <scripts_dir>: review_common.sh 와 hooks/_open_issues.awk 가 있는 scripts 디렉터리
#   open-issues 본문 기본값은 `- 없음`. 다음 턴 번호는 turns/ 의 NNN_ 최댓값 + 1 (없으면 002).
fixture_reviewer_turn() {
  local sd="$1" scripts_dir="$2" oi="${3:-- 없음}"
  local max=1 n f turn turn_file head
  sd="$(cd "$sd" 2>/dev/null && pwd)" || return 1
  scripts_dir="$(cd "$scripts_dir" 2>/dev/null && pwd)" || return 1
  mkdir -p "${sd}/turns" || return 1
  for f in "${sd}"/turns/[0-9][0-9][0-9]_*; do
    [ -e "$f" ] || continue
    n="$(basename "$f")"; n="${n%%_*}"
    n=$((10#$n))
    [ "$n" -gt "$max" ] && max="$n"
  done
  turn="$(printf '%03d' $((max + 1)))"
  turn_file="${sd}/turns/${turn}_reviewer.md"
  printf '# Turn %s — Reviewer\n\n## Disagreement\n- 이의 없음.\n' "$turn" > "$turn_file" || return 1

  # CHECKPOINT 의 Open Issues 절 본문을 인자로 바꿉니다 (파일·절이 없으면 새로 만듭니다).
  if [ -f "${sd}/CHECKPOINT.md" ] && grep -q '^## Open Issues' "${sd}/CHECKPOINT.md"; then
    awk -v body="$oi" '
      /^## Open Issues/ { print; print body; print ""; skip = 1; next }
      skip && /^## / { skip = 0 }
      skip { next }
      { print }' "${sd}/CHECKPOINT.md" > "${sd}/.checkpoint.fx" || return 1
    cat "${sd}/.checkpoint.fx" > "${sd}/CHECKPOINT.md"
    rm -f "${sd}/.checkpoint.fx"
  else
    printf '# Review Checkpoint\n\n## Open Issues\n%s\n\n## Suggested Next Owner\nAuthor\n' "$oi" \
      > "${sd}/CHECKPOINT.md" || return 1
  fi

  head="$(awk '
    /^## Branch Context/ { f = 1; next }
    f && /^## / { exit }
    f && index($0, "- review-head-oid:") == 1 { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }
  ' "${sd}/SESSION.md" 2>/dev/null)"
  [ -n "$head" ] || head="-"

  # git hash-object 는 세션이 든 저장소의 object format(sha1/sha256)으로 계산해야 seal 의 대조와
  # 맞으므로 세션 디렉터리에서 부릅니다 (run_review_turn.sh 는 저장소 루트에서 부릅니다).
  ( cd "$sd" && source "${scripts_dir}/review_common.sh" && \
    append_reviewer_run "$sd" "$turn" codex reviewer "$head" "$turn_file" )
}
