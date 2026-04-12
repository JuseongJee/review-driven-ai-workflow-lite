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
      echo "already installed: $skill_name"
      skipped_count=$((skipped_count + 1))
      continue
    else
      echo "destination already exists, skipping: $dst" >&2
      skipped_count=$((skipped_count + 1))
      continue
    fi
  fi

  if [[ "$mode" == "link" ]]; then
    ln -s "$src_real" "$dst"
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
echo "skipped: $skipped_count"
echo "Restart Claude Code to pick up new skills."
