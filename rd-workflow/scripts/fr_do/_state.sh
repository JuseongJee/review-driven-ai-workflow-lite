#!/usr/bin/env bash
# fr_do 스크립트 공용 함수. source 전용입니다. bash 3.2 호환.
# 상태 폴더: <기본 체크아웃>/rd-workflow-workspace/.lifecycle/fr-do/ (active.tsv, reports/, waves/<wave>/, log.md)
# active.tsv 한 줄: <slug><TAB><소유 경로;…><TAB><FR stem;…> (3번째 칸이 없는 옛 줄도 읽습니다)

# 기본 체크아웃 절대 경로. 어느 worktree 에서 불러도 같습니다(git worktree list 의 첫 항목).
fr_do_main_root() {
  git -C "$(dirname "${BASH_SOURCE[0]}")" worktree list --porcelain | sed -n '1s/^worktree //p'
}

# 상태 폴더 절대 경로. 없으면 만듭니다.
fr_do_state_dir() {
  local root dir
  root="$(fr_do_main_root)" || return 1
  [[ -n "$root" ]] || return 1
  dir="$root/rd-workflow-workspace/.lifecycle/fr-do"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# 브랜치 refs/heads/fr/<slug> 가 체크아웃된 worktree 경로. 없으면 rc 1.
fr_do_worktree_of() {
  local slug="$1" root
  root="$(fr_do_main_root)" || return 1
  git -C "$root" worktree list --porcelain | awk -v b="branch refs/heads/fr/$slug" '
    /^worktree /{p=substr($0,10)}
    $0==b{print p; found=1; exit}
    END{exit found?0:1}'
}

# promote 가 띄운 줄기의 herdr 에이전트 이름. slug 가 32자 이하면 그대로, 길면 앞 32자에서 끝의 `-` 를 뗍니다.
# lifecycle/session_launch.sh 의 session_agent_name 과 같은 규칙 — 바꾸면 함께 바꿉니다.
# (session_launch.sh 를 source 하지 않습니다: 부수 효과와 fixture 의존을 만들지 않기 위함)
fr_do_agent_name() {
  local s="$1"
  if [[ "${#s}" -le 32 ]]; then printf '%s\n' "$s"; return 0; fi
  s="${s:0:32}"
  printf '%s\n' "${s%-}"
}
