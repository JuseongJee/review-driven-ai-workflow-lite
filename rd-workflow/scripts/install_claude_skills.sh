#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd "${script_dir}/../.." && pwd)"

usage() {
  cat <<'EOF' >&2
사용법:
  bash rd-workflow/scripts/install_claude_skills.sh [project|personal] [link|copy] [skill-name ...]

기본값:
  scope: personal
  mode: link

예:
  bash rd-workflow/scripts/install_claude_skills.sh
  bash rd-workflow/scripts/install_claude_skills.sh project
  bash rd-workflow/scripts/install_claude_skills.sh personal copy request-to-reviewed-plan

메모:
  - canonical skill source는 `rd-workflow/claude_skills/`입니다.
  - `project`는 `rd-workflow/claude_skills/`를 `.claude/skills/`로 bootstrap합니다.
  - `personal`은 `rd-workflow/claude_skills/`를 `~/.claude/skills/`로 설치합니다.
EOF
}

canonical_dir() {
  local path="$1"
  (cd "$path" && pwd -P)
}

detect_project_dest_root() {
  if [[ "$(basename "$source_root")" == "_ROOT_FILES" && -f "${source_root}/CLAUDE.md" && -f "${source_root}/REQUEST.md" ]]; then
    local parent_root
    parent_root="$(cd "${source_root}/.." && pwd)"
    printf '%s\n' "$parent_root"
    return 0
  fi

  printf '%s\n' "$source_root"
}

scope="${1:-personal}"
if [[ $# -gt 0 ]]; then
  shift
fi

mode="${1:-link}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$scope" in
  project|personal)
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "알 수 없는 scope: $scope" >&2
    usage
    exit 1
    ;;
esac

case "$mode" in
  link|copy)
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "알 수 없는 mode: $mode" >&2
    usage
    exit 1
    ;;
esac

skills_source_dir="${source_root}/rd-workflow/claude_skills"
if [[ ! -d "$skills_source_dir" ]]; then
  echo "Claude skill source directory not found: $skills_source_dir" >&2
  echo "This script expects skill source files to already exist at rd-workflow/claude_skills." >&2
  echo "Creating an empty directory is not enough; the skill folders and SKILL.md files must be there." >&2
  echo "In a copied project, this usually means rd-workflow/claude_skills was not copied." >&2
  echo "Copy rd-workflow/claude_skills from the template as well, then rerun this installer." >&2
  exit 1
fi

if [[ "$scope" == "project" ]]; then
  dest_root="$(detect_project_dest_root)"
  dest_base="${dest_root}/.claude/skills"
else
  dest_base="${HOME}/.claude/skills"
fi

mkdir -p "$dest_base"

source_base_real="$(canonical_dir "$skills_source_dir")"
dest_base_real="$(canonical_dir "$dest_base")"
dest_root_real="${dest_base_real%/.claude/skills}"

# link 모드 symlink target 계산.
# project scope에서 source가 프로젝트 안에 있으면 symlink 위치(.claude/skills) 기준
# 상대 경로를 반환한다 — 절대 경로 symlink은 커밋 후 다른 머신/경로 clone에서 파손된다.
# personal scope와 프로젝트 밖 source는 기존 절대 경로를 유지한다.
symlink_target_for() {
  local skill_name="$1"
  if [[ "$scope" == "project" && "$source_base_real" == "${dest_root_real}"/* ]]; then
    printf '../../%s/%s' "${source_base_real#"${dest_root_real}"/}" "$skill_name"
  else
    printf '%s/%s' "$source_base_real" "$skill_name"
  fi
}

if [[ "$source_base_real" == "$dest_base_real" ]]; then
  echo "source and destination are the same: $source_base_real"
  echo "Nothing to install for scope '$scope'."
  echo "Use 'personal' only if you want to install these skills into ~/.claude/skills."
  exit 0
fi

declare -a skill_names=()
if [[ $# -gt 0 ]]; then
  skill_names=("$@")
else
  while IFS= read -r skill_dir; do
    [[ -n "$skill_dir" ]] || continue
    skill_names+=("$(basename "$skill_dir")")
  done < <(find "$skills_source_dir" -mindepth 1 -maxdepth 1 -type d | sort)
fi

if ((${#skill_names[@]} == 0)); then
  echo "No Claude skills found in source: $skills_source_dir" >&2
  exit 1
fi

installed_count=0
skipped_count=0
refreshed_count=0
run_timestamp="$(date +%Y%m%d%H%M%S)"

for skill_name in "${skill_names[@]}"; do
  src="${skills_source_dir}/${skill_name}"
  dst="${dest_base}/${skill_name}"

  if [[ -L "$dst" && ! -e "$dst" ]]; then
    rm "$dst"
  fi

  if [[ ! -d "$src" ]]; then
    echo "skill not found: $skill_name" >&2
    exit 1
  fi

  src_real="$(canonical_dir "$src")"

  if [[ -e "$dst" ]]; then
    if [[ -L "$dst" && "$(canonical_dir "$dst")" != "$src_real" ]]; then
      rm "$dst"
    elif [[ -d "$dst" && "$(canonical_dir "$dst")" == "$src_real" ]]; then
      desired_target="$(symlink_target_for "$skill_name")"
      if [[ -L "$dst" && "$desired_target" != /* && "$(readlink "$dst")" != "$desired_target" ]]; then
        # 해석 결과가 이미 동일한 symlink만 literal target을 원하는 상대 형식으로 교체한다.
        # (기존 설치본 갱신은 이번 실행의 mode 인자와 무관 — copy refresh와 동일 철학)
        rm "$dst"
        ln -s "$desired_target" "$dst"
        echo "refreshed (symlink -> relative): $skill_name -> $dst"
        refreshed_count=$((refreshed_count + 1))
        continue
      fi
      echo "already installed: $skill_name"
      skipped_count=$((skipped_count + 1))
      continue
    elif [[ -d "$dst" && ! -L "$dst" ]]; then
      # copy 모드 설치본 — 내용이 같으면 skip, 다르면 백업 후 갱신.
      # 기존 설치본 갱신은 이번 실행의 mode 인자와 무관하다 (mode는 신규 설치에만 적용).
      diff_rc=0
      diff -rq "$src" "$dst" >/dev/null 2>&1 || diff_rc=$?
      if [[ "$diff_rc" -eq 0 ]]; then
        echo "already up to date (copy): $skill_name"
        skipped_count=$((skipped_count + 1))
        continue
      elif [[ "$diff_rc" -ne 1 ]]; then
        echo "copy 설치본 비교 실패 (diff exit ${diff_rc}), 건너뜁니다: $dst" >&2
        skipped_count=$((skipped_count + 1))
        continue
      fi

      backup_root="$(dirname "$dest_base")/skills-backup"
      mkdir -p "$backup_root"
      backup="${backup_root}/${skill_name}-${run_timestamp}"
      backup_suffix=2
      while [[ -e "$backup" ]]; do
        backup="${backup_root}/${skill_name}-${run_timestamp}-${backup_suffix}"
        backup_suffix=$((backup_suffix + 1))
      done

      # 새 내용을 임시 경로에 먼저 복사한 뒤 교체한다 — 어느 단계가 실패해도
      # 기존 설치본이 $dst 또는 $backup 에 항상 남는다.
      tmp_new="${backup_root}/.${skill_name}-new-$$"
      rm -rf "$tmp_new"
      if ! cp -R "$src" "$tmp_new"; then
        rm -rf "$tmp_new"
        echo "재복사 실패로 갱신을 건너뜁니다 (기존 설치본 유지): $dst" >&2
        skipped_count=$((skipped_count + 1))
        continue
      fi
      if ! mv "$dst" "$backup"; then
        rm -rf "$tmp_new"
        echo "백업 실패로 갱신을 건너뜁니다: $dst" >&2
        skipped_count=$((skipped_count + 1))
        continue
      fi
      if ! mv "$tmp_new" "$dst"; then
        mv "$backup" "$dst"
        rm -rf "$tmp_new"
        echo "교체 실패로 기존 설치본을 복구했습니다: $dst" >&2
        skipped_count=$((skipped_count + 1))
        continue
      fi
      echo "refreshed: $skill_name -> $dst (backup: $backup)"
      refreshed_count=$((refreshed_count + 1))
      continue
    else
      echo "destination already exists, skipping: $dst" >&2
      skipped_count=$((skipped_count + 1))
      continue
    fi
  fi

  if [[ "$mode" == "link" ]]; then
    ln -s "$(symlink_target_for "$skill_name")" "$dst"
  else
    cp -R "$src" "$dst"
  fi

  echo "installed: $skill_name -> $dst"
  installed_count=$((installed_count + 1))
done

# --- settings.json 설치 ---
settings_source="${source_root}/.claude/settings.json"
if [[ "$scope" == "project" && -f "$settings_source" ]]; then
  settings_dest="${dest_root}/.claude/settings.json"
  mkdir -p "$(dirname "$settings_dest")"

  if [[ ! -f "$settings_dest" ]]; then
    cp "$settings_source" "$settings_dest"
    echo "settings.json installed: $settings_dest"
  elif diff -q "$settings_source" "$settings_dest" &>/dev/null; then
    echo "settings.json already up to date"
  else
    echo "settings.json conflict detected — 수동 머지가 필요합니다." >&2
    echo "--- diff ---" >&2
    diff "$settings_dest" "$settings_source" >&2 || true
    echo "--- end diff ---" >&2
    echo "현재 파일: $settings_dest" >&2
    echo "템플릿 파일: $settings_source" >&2
    echo "settings.json 설치를 건너뜁니다. 직접 머지하세요." >&2
  fi
fi

echo
echo "install complete"
echo "scope: $scope"
echo "mode: $mode"
echo "source: $source_base_real"
echo "destination: $dest_base"
echo "installed: $installed_count"
echo "refreshed: $refreshed_count"
echo "skipped: $skipped_count"
echo "Restart Claude Code to pick up new skills."
