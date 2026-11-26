#!/usr/bin/env bash
# test_archive_submodule.sh — submodule 을 품은 작업 worktree 의 정리(spec 2.4 D15~D18)를 검증한다.
# git 은 전부 mktemp -d 안의 임시 저장소에서만 실행한다.
set -euo pipefail
trap 'ec=$?; echo "  FAIL: 스위트가 line ${LINENO} 에서 rc=${ec} 로 중단됐습니다 (조용한 중단)" >&2' ERR
DONE=0
_cleanup=()
_on_exit() {
  local _ec=$? _d
  for _d in ${_cleanup[@]+"${_cleanup[@]}"}; do [[ -z "$_d" ]] || rm -rf "$_d"; done
  [[ "$DONE" == 1 ]] || echo "  FAIL: 스위트가 결과줄 없이 rc=${_ec} 로 중단됐습니다" >&2
}
trap _on_exit EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HERDR_ENV=
export ORCA_AGENT_SESSION_ID= ORCA_TERMINAL_HANDLE=
export RD_CHILD_SESSION=1
unset project_root TASK_STATE_PATH

# 실제 ps 를 쓸 수 없는 환경(Codex 샌드박스는 /bin/ps 실행과 프로세스 목록 조회를 막는다)에서는
# 점유 판정이 늘 판정불가로 보류돼 정상 정리 흐름을 검증할 수 없다. 그때만 lsof 가 본 pid 를 내는
# 대역 ps 를 PATH 앞에 둔다. 대역 디렉터리는 fixture 저장소 밖에 둔다(기본 체크아웃 미커밋 판정에 섞이지 않게).
if ! ps -U "$(id -u)" -o pid=,uid=,stat= >/dev/null 2>&1; then
  PS_STUB_DIR="$(mktemp -d)" || { echo "$(basename "$0"): 대역 ps 디렉터리 생성 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
  _cleanup+=("$PS_STUB_DIR")
  cat > "$PS_STUB_DIR/ps" <<'PS_STUB_EOF'
#!/usr/bin/env bash
# 대역 ps — tasks_path_occupied 의 `ps -U <uid> -o pid=,uid=,stat=` 호출에만 답한다.
# 그 밖의 형식은 샌드박스의 실제 ps 처럼 실패한다(publish_queue.sh·session_launch.sh 의 다른 ps 호출).
if [[ "$#" -ne 4 || "$1" != "-U" || "$3" != "-o" || "$4" != "pid=,uid=,stat=" ]]; then
  echo "ps(대역): 지원하지 않는 형식: $*" >&2; exit 1
fi
"${RD_TEST_REAL_LSOF:-lsof}" -a -u "$2" -d cwd -Fp 2>/dev/null | sed -n 's/^p//p' | awk -v u="$2" '{ print $1, u, "S" }'
PS_STUB_EOF
  chmod +x "$PS_STUB_DIR/ps"
  # 대역 ps 는 준비 시점의 실제 lsof 를 쓴다 — 케이스가 PATH 에 넣는 실패용 lsof(O2)가 프로세스 열거까지 망가뜨리지 않게.
  RD_TEST_REAL_LSOF="$(command -v lsof || true)"; export RD_TEST_REAL_LSOF
  export PATH="$PS_STUB_DIR:$PATH"
  echo "  NOTE: 실제 ps 를 쓸 수 없는 환경 — lsof 기반 대역 ps 로 정상 정리 흐름을 검증합니다"
fi
# 로컬 file 프로토콜 submodule 을 하위 프로세스(promote·archive 포함)까지 허용한다.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1" >&2; }

# 지연 정리가 「점유 판정불가」 로 보류됐을 때 그 보류가 환경 탓인지 제품과 별개로 확인한다.
# 내 계정(유효 uid 도 나)의 살아 있는 프로세스를 ps 로 보고, lsof 로 그 CWD 를 모두 읽을 수 있으면 0(판정 가능한 환경)이다.
# 0 이면 제품의 판정불가는 회귀이므로 env-skip 으로 세지 않고 FAIL 한다.
occ_env_judgeable() {
  local u ps_live cwd_seen
  u="$(id -u)"
  ps_live="$(ps -U "$u" -o pid=,uid=,stat= 2>/dev/null | awk -v me="$u" '$1 ~ /^[0-9]+$/ && $2 == me && $3 !~ /^Z/ {print $1}')"
  [[ -n "$ps_live" ]] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  # `n/proc/<pid>/cwd (readlink: Permission denied)` 처럼 괄호 오류 설명이 붙은 n 줄은 읽은 것으로 치지 않는다.
  cwd_seen="$(lsof -a -u "$u" -d cwd -Fpn 2>/dev/null | awk '/^p/ {c = substr($0, 2)} /^n\// && !/\(.*\)$/ && c != "" {print c}')"
  [[ -n "$cwd_seen" ]] || return 1
  printf '%s\n' "$ps_live" | CWD_SEEN="$cwd_seen" awk '
    BEGIN { n = split(ENVIRON["CWD_SEEN"], a, "\n"); for (i = 1; i <= n; i++) seen[a[i]] = 1 }
    !($1 in seen) { print $1 }' | while IFS= read -r pid; do
      kill -0 "$pid" 2>/dev/null || continue   # 그사이 끝난 프로세스는 세지 않는다
      exit 1
    done
}

TMP="$(mktemp -d)" || { echo "test_archive_submodule.sh: mktemp 실패" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "test_archive_submodule.sh: 임시 경로 검증 실패" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
_cleanup+=("$TMP")
cd "$TMP"
# 빈 경로 `git -C ""` 같은 실수가 작업 worktree 에 닿지 않도록 TMP 위로 git 탐색을 막는다.
export GIT_CEILING_DIRECTORIES="$(dirname "$TMP")"

# mk_sub_consumer <dir> — 로컬 bare 원격 overlay.git·prod.git·vendor.git 을 만들고, overlay 에
# `libs/prod` submodule(그 안에 중첩 submodule `vendor`)과 rd-workflow 설치를 담은 저장소 경로를 출력한다.
mk_sub_consumer() {
  local d="$1" r="$1/repo" s
  mkdir -p "$d"
  git init -q --bare -b main "$d/vendor.git"
  git init -q --bare -b main "$d/prod.git"
  git init -q --bare -b main "$d/overlay.git"
  s="$d/vendor-src"; git init -q -b main "$s"
  ( cd "$s" && echo v > v.txt && git add -A && git commit -q -m vendor && git push -q "$d/vendor.git" main )
  s="$d/prod-src"; git init -q -b main "$s"
  ( cd "$s" && echo p > p.txt && git add -A && git commit -q -m prod \
    && git submodule add -q "$d/vendor.git" vendor && git commit -q -m "prod: vendor" \
    && git push -q "$d/prod.git" main )
  mkdir -p "$r/rd-workflow"
  cp -R "$SCRIPT_DIR/.." "$r/rd-workflow/scripts"
  git init -q -b main "$r"
  mkdir -p "$r/rd-workflow-workspace/.lifecycle" "$r/rd-workflow-workspace/backlog/items"
  cp "$SCRIPT_DIR/../../../.gitignore" "$r/.gitignore"
  # 기존 케이스는 팀 main 이 아닌 케이스 브랜치로 submodule 을 push 한다 — 팀 저장소 반영 게이트(기본 pr)를 끄고 종전 동작을 유지한다.
  mkdir -p "$r/rd-workflow/config"
  printf '{"team_publish": {"mode": "manual"}}\n' > "$r/rd-workflow/config/workflow.json"
  bash -c "source '$SCRIPT_DIR/_lifecycle_common.sh'; emit_current_task_baseline" > "$r/CURRENT_TASK.md"
  printf 'schema=1\nshort-title=-\nstatus=대기 중\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=null\n' \
    > "$r/rd-workflow-workspace/.lifecycle/task-state"
  printf '# Change Request\n\n## Source FR\n-\n' > "$r/REQUEST.md"
  ( cd "$r" && git submodule add -q "$d/prod.git" libs/prod \
    && git -C libs/prod submodule update -q --init \
    && git add -A && git commit -q -m seed \
    && git remote add origin "$d/overlay.git" && git push -q origin main )
  printf '%s\n' "$r"
}

# 템플릿 consumer 는 한 번만 만든다(느린 부분). 케이스마다 repo 와 overlay.git 을 복사해 쓰고,
# prod.git·vendor.git 은 공유한다 — 케이스의 submodule push 는 케이스 이름의 브랜치로만 해 서로 간섭하지 않는다.
TEMPLATE_DIR="$TMP/_template"
mk_sub_consumer "$TEMPLATE_DIR" >/dev/null

# prep_case <name> — 템플릿을 복사하고 promote 한 뒤 작업 worktree 의 submodule 을 초기화한다(재귀).
#   전역: CASE_NAME CASE_REPO CASE_WT
prep_case() {
  CASE_NAME="$1"
  mkdir -p "$TMP/$1"
  cp -R "$TEMPLATE_DIR/repo" "$TMP/$1/repo"
  cp -R "$TEMPLATE_DIR/overlay.git" "$TMP/$1/overlay.git"
  CASE_REPO="$TMP/$1/repo"
  git -C "$CASE_REPO" remote set-url origin "$TMP/$1/overlay.git"
  # CASE_CFG: 비어 있으면 템플릿 설정(manual) 그대로, none 이면 workflow.json 삭제(team_publish 키 없음), 그 밖은 그 JSON 을 쓴다.
  if [[ -n "${CASE_CFG-}" ]]; then
    if [[ "$CASE_CFG" == none ]]; then git -C "$CASE_REPO" rm -q -f rd-workflow/config/workflow.json
    else printf '%s\n' "$CASE_CFG" > "$CASE_REPO/rd-workflow/config/workflow.json"; git -C "$CASE_REPO" add rd-workflow/config/workflow.json; fi
    git -C "$CASE_REPO" commit -q -m "test: team_publish 설정"
  fi
  # CASE_PRE: 비어 있지 않으면 promote 전에 그 이름의 함수를 부른다(기준점 커밋을 바꾸는 fixture 용).
  if [[ -n "${CASE_PRE-}" ]]; then "$CASE_PRE"; fi
  bash "$CASE_REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title "$1" --size large --source-fr - >/dev/null 2>&1 \
    || { echo "promote 실패: $1" >&2; exit 1; }
  CASE_WT="$CASE_REPO/.worktrees/$1"
  git -C "$CASE_WT" submodule update -q --init --recursive
  git -C "$CASE_WT/libs/prod" config user.email t@t
  git -C "$CASE_WT/libs/prod" config user.name t
}
# sub_push <wt> — submodule libs/prod 의 HEAD 를 원격 prod.git 의 케이스 브랜치로 push 한다.
sub_push() { git -C "$1/libs/prod" push -q origin "HEAD:refs/heads/$CASE_NAME"; }

# sub_commit <wt> — submodule libs/prod 에 커밋 하나를 만든다. (push 는 호출자가 결정)
sub_commit() { echo "c-$RANDOM" >> "$1/libs/prod/p.txt"; git -C "$1/libs/prod" commit -q -am "sub change"; }
# record_gitlink <wt> — gitlink 를 올리는 작업 커밋(실제 변경 하나 포함).
record_gitlink() { echo work > "$1/work.txt"; git -C "$1" add -A; git -C "$1" commit -q -m "구현: gitlink"; }

run_archive() {  # <repo> <slug> [--force-dirty] — 기본 worktree 에서 --task 로 호출한다. 출력은 ARCH_OUT, rc 는 ARCH_RC.
  ARCH_RC=0
  ARCH_OUT="$( cd "$1" && bash rd-workflow/scripts/lifecycle/archive.sh --task "$2" --no-remote ${3:+"$3"} \
    --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || ARCH_RC=$?
}

echo "== W1: 푸시·gitlink 반영 완료 — submodule worktree 제거 =="
prep_case w1
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
run_archive "$CASE_REPO" w1
if [[ "$ARCH_RC" == 0 && ! -d "$CASE_WT" ]] && ! git -C "$CASE_REPO" rev-parse --verify --quiet refs/heads/fr/w1 >/dev/null; then
  pass "W1: archive rc=0, worktree 디렉터리와 fr/w1 브랜치가 없다"
else
  fail "W1: rc=$ARCH_RC worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi
if [[ "$ARCH_RC" == 0 && "$ARCH_OUT" == *"안내 — 반영 방식 manual 인 submodule 의 발행 gitlink 가 팀 기본 브랜치에 없는 커밋입니다"* \
   && "$ARCH_OUT" == *"- libs/prod: "*"origin/main 에 없습니다"* && "$ARCH_OUT" == *"fetch origin refs/heads/main && git -C "*"checkout --no-overwrite-ignore --detach FETCH_HEAD"* && "$ARCH_OUT" == *"git --literal-pathspecs -C $CASE_REPO commit -m "*" -- libs/prod"* && "$ARCH_OUT" == *"workflow.json 의 team_publish.mode 를 pr 로"* \
   && "$ARCH_OUT" == *"team_publish.mode 를 pr 로 바꾸면"* ]]; then
  pass "W1: manual gitlink 가 팀 main 밖 — 발행 성공과 발행 끝 안내"
else
  fail "W1: 발행 끝 안내 — rc=$ARCH_RC $ARCH_OUT"
fi
if [[ "$(grep -c "안내 — 반영 방식 manual" <<<"$ARCH_OUT")" == 1 ]]; then pass "W1: 안내는 한 번"; else fail "W1: 안내 횟수 — $ARCH_OUT"; fi

echo "== W1c: 발행 뒤 기본 worktree 의 prod 체크아웃이 발행 gitlink 와 같고 merge 메시지에 autopilot 이 없다 =="
w1_gl="$(git -C "$CASE_REPO" ls-tree -r HEAD libs/prod | awk '{print $3}')"
w1_co="$(git -C "$CASE_REPO/libs/prod" rev-parse HEAD)"
w1_st="$(git -C "$CASE_REPO" status --porcelain)"
w1_msgs="$(git -C "$CASE_REPO" log --first-parent --format=%s -6)"
# 팀 원격에 push 한 커밋이므로 기본 체크아웃 submodule 에 rd-archive 브랜치를 만들지 않는다(FR archive-carry-worktree-submodule-commits).
w1_br="$(git -C "$CASE_REPO/libs/prod" for-each-ref --format='%(refname)' refs/heads/rd-archive)"
if [[ -n "$w1_gl" && "$w1_gl" == "$w1_co" && -z "$w1_st" && -z "$w1_br" && "$ARCH_OUT" == *"체크아웃을 발행된 커밋으로 맞췄습니다"* ]] \
   && grep -qxF "merge: w1 (archive)" <<<"$w1_msgs" && ! grep -q autopilot <<<"$w1_msgs"; then
  pass "W1c: 체크아웃=gitlink, status 깨끗, rd-archive 브랜치 없음, merge 메시지 'merge: w1 (archive)'"
else
  fail "W1c: gitlink=$w1_gl checkout=$w1_co status=[$w1_st] rd-archive=[$w1_br] msgs=[$w1_msgs] — $ARCH_OUT"
fi

echo "== W1t: submodule 커밋을 팀 원격에 태그로만 push, 기본 체크아웃엔 객체만 미리 받음 — rd-archive 브랜치를 만들지 않고 worktree 를 지운다 =="
# 릴리스 태그로만 push 한 커밋은 원격 추적 ref 가 없다. 작업 쪽 submodule 의 태그를 보지 않으면 이미 팀 원격에 있는 커밋에 브랜치를
#   만들고 push 하라고 안내한다(AC2 의 부정 조건). 기본 체크아웃에 커밋 객체를 태그 없이 미리 받아 두어, 발행이 커밋을 옮기지 않는
#   경로에서도 같은 판정을 하는지 본다(옮기는 경로는 W1c·W3b 가 지난다).
prep_case w1t
sub_commit "$CASE_WT"
git -C "$CASE_WT/libs/prod" tag -a w1t-rel -m w1t-rel
git -C "$CASE_WT/libs/prod" push -q origin refs/tags/w1t-rel
record_gitlink "$CASE_WT"
w1t_gl="$(git -C "$CASE_WT" ls-tree HEAD libs/prod | awk '{print $3}')"
git -C "$CASE_REPO/libs/prod" fetch -q --no-tags origin "$w1t_gl"
[[ -z "$(git -C "$CASE_REPO/libs/prod" for-each-ref --contains "$w1t_gl")" ]] || { echo "준비 실패: w1t 기본 쪽 ref" >&2; exit 1; }
run_archive "$CASE_REPO" w1t
w1t_co="$(git -C "$CASE_REPO/libs/prod" rev-parse HEAD)"
w1t_br="$(git -C "$CASE_REPO/libs/prod" for-each-ref --format='%(refname)' refs/heads/rd-archive)"
if [[ "$ARCH_RC" == 0 && -n "$w1t_gl" && "$w1t_co" == "$w1t_gl" && -z "$w1t_br" && ! -d "$CASE_WT" \
   && "$ARCH_OUT" != *"팀 원격에 없어"* ]]; then
  pass "W1t: rc=0, 체크아웃=gitlink, rd-archive 브랜치·push 안내 없음, worktree 제거"
else
  fail "W1t: rc=$ARCH_RC gitlink=$w1t_gl checkout=$w1t_co rd-archive=[$w1t_br] worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi
echo "== W1b: 작업 worktree 안에서 archive → 기본 체크아웃 rd task list 가 정리 =="
prep_case w1b
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
rc=0; out="$( cd "$CASE_WT" && bash rd-workflow/scripts/lifecycle/archive.sh \
  --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || rc=$?
if [[ "$rc" != 0 || ! -d "$CASE_WT" ]]; then
  fail "W1b: 호출 worktree archive rc=$rc (rc=0 이고 worktree 는 남아야 함) — $out"
else
  tl="$( cd "$CASE_REPO" && bash rd-workflow/scripts/rd task list 2>&1 )" || true
  if [[ ! -d "$CASE_WT" ]] && ! git -C "$CASE_REPO" rev-parse --verify --quiet refs/heads/fr/w1b >/dev/null; then
    pass "W1b: rd task list 가 submodule worktree 와 브랜치를 지연 정리했다"
  elif w1b_hold="$(printf '%s\n' "$tl" | grep -m1 '정리 보류: w1b — 점유 판정불가')" && ! occ_env_judgeable \
    && [[ -d "$CASE_WT" ]] && git -C "$CASE_REPO" rev-parse --verify --quiet refs/heads/fr/w1b >/dev/null; then
    # 점유 판정을 할 수 없는 환경(ps·lsof 불가 샌드박스)에서는 제품이 정리를 보류하는 것이 맞다 — 그 환경을 따로 확인했고
    # worktree·브랜치가 그대로 남았을 때만 env-skip 으로 센다. 판정 가능한 환경의 판정불가는 아래 FAIL 이다.
    printf 'env-skip: test_archive_submodule W1b 지연 정리 — 점유 판정을 할 수 없는 환경(%s)\n' "${w1b_hold#*정리 보류: w1b — }" >&2
  else
    fail "W1b: 지연 정리 안 됨 — $tl"
  fi
fi

echo "== W3b: submodule 커밋을 push 하지 않음 — 발행이 기본 체크아웃 submodule 로 옮기고 브랜치로 남긴 뒤 worktree 를 지운다 =="
# FR archive-carry-worktree-submodule-commits: 커밋이 작업 worktree 전용 submodule 저장소에만 있으면 submodule update 가
#   `not our ref` 로 실패하고 기본 체크아웃이 ` M libs/prod` 로 남으며, 정리 판정이 worktree 를 계속 보존했다.
prep_case w3b
sub_commit "$CASE_WT"; record_gitlink "$CASE_WT"
w3b_gl="$(git -C "$CASE_WT" ls-tree HEAD libs/prod | awk '{print $3}')"
run_archive "$CASE_REPO" w3b
w3b_co="$(git -C "$CASE_REPO/libs/prod" rev-parse HEAD)"
w3b_br="$(git -C "$CASE_REPO/libs/prod" rev-parse -q --verify refs/heads/rd-archive/w3b || true)"
w3b_st="$(git -C "$CASE_REPO" status --porcelain)"
if [[ "$ARCH_RC" == 0 && -n "$w3b_gl" && "$w3b_co" == "$w3b_gl" && "$w3b_br" == "$w3b_gl" && -z "$w3b_st" && ! -d "$CASE_WT" \
   && "$ARCH_OUT" == *"브랜치 rd-archive/w3b 로 남겼습니다"* && "$ARCH_OUT" == *"libs/prod push --no-follow-tags origin rd-archive/w3b"* \
   && "$ARCH_OUT" != *"정리 잔여 있음"* ]]; then
  pass "W3b: rc=0, 기본 체크아웃 submodule HEAD=gitlink=rd-archive/w3b, status 깨끗, worktree 제거, 브랜치·push 안내"
else
  fail "W3b: rc=$ARCH_RC gitlink=$w3b_gl checkout=$w3b_co branch=$w3b_br status=[$w3b_st] worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

echo "== W3: gitlink 커밋을 이 컴퓨터에서 옮길 수 없으면 rc=0, 갱신 실패 잔여, worktree 보존 =="
# 로컬 전송(file)을 막아 옮기기와 원격 fetch 가 모두 실패하게 한다. archive 가 체크아웃 갱신 실패를 정리 잔여로 남기고,
#   정리 판정이 기본 체크아웃에 없는 커밋을 미push 로 보고 worktree 를 보존하는 연결을 본다.
prep_case w3
sub_commit "$CASE_WT"; record_gitlink "$CASE_WT"
GIT_CONFIG_VALUE_0=never run_archive "$CASE_REPO" w3
if [[ "$ARCH_RC" == 0 && "$ARCH_OUT" == *"기본 체크아웃 submodule 로 옮기지 못했습니다"* && "$ARCH_OUT" == *"[submodule]"* \
   && "$ARCH_OUT" == *"체크아웃 갱신 실패"* && "$ARCH_OUT" == *"archive: core 완료 (정리 잔여 있음)"* \
   && -d "$CASE_WT" && "$ARCH_OUT" == *"원격에 없는 커밋"* && "$ARCH_OUT" == *"log --oneline --all --not --remotes"* ]] \
   && ! git -C "$CASE_REPO/libs/prod" rev-parse -q --verify refs/heads/rd-archive/w3 >/dev/null; then
  pass "W3: rc=0, 옮기지 못함 안내, [submodule] 갱신 실패 잔여, worktree 보존·사유·복구 명령, core 완료"
else
  fail "W3: rc=$ARCH_RC worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

# W3c·W3d·W3e 는 보존 판정 함수를 직접 부른다 — 공용 함수를 source 한 뒤인 U 구간 뒤에 있다.

# ---- 팀 저장소 반영 게이트 (change spec D10) · Step 4 PR 기록 정리 ----
PR_CFG='{"team_publish": {"mode": "pr"}}'
gate_main_head() { git -C "$CASE_REPO" rev-parse refs/heads/main; }

echo "== t_gate_rejects_unpublished: 팀 저장소에 없는 gitlink 는 발행을 거부하고 main 을 바꾸지 않는다 =="
CASE_CFG="$PR_CFG" prep_case tg1
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
tg1_before="$(gate_main_head)"
run_archive "$CASE_REPO" tg1
if [[ "$ARCH_RC" != 0 && "$(gate_main_head)" == "$tg1_before" && "$ARCH_OUT" == *"libs/prod"* && "$ARCH_OUT" == *"rd pr open"* \
   && "$ARCH_OUT" == *"rd pr check --apply"* && "$ARCH_OUT" == *"team_publish.mode"* && "$ARCH_OUT" == *"manual"* ]] \
   && git -C "$CASE_REPO" rev-parse --verify --quiet refs/heads/fr/tg1 >/dev/null; then
  pass "t_gate_rejects_unpublished: rc=$ARCH_RC, main 불변, 경로·rd pr 안내·manual 설정 안내 출력"
else
  fail "t_gate_rejects_unpublished: rc=$ARCH_RC main=$(gate_main_head) 이전=$tg1_before — $ARCH_OUT"
fi

echo "== t_gate_fetch_fail: 팀 저장소 원격을 가져올 수 없으면 판정 불가로 거부한다 (fail-closed) =="
tg1_url="$(git -C "$CASE_WT/libs/prod" remote get-url origin)"
git -C "$CASE_WT/libs/prod" remote set-url origin "$TMP/tg1/missing.git"  # 게이트는 작업 worktree 의 submodule 로 판정한다
run_archive "$CASE_REPO" tg1
if [[ "$ARCH_RC" != 0 && "$ARCH_OUT" == *"가져오지 못해"* && "$(gate_main_head)" == "$tg1_before" ]]; then
  pass "t_gate_fetch_fail: 거부, 판정 불가 사유 출력"
else
  fail "t_gate_fetch_fail: rc=$ARCH_RC — $ARCH_OUT"
fi

echo "== t_gate_bypass_audit: --allow-unpublished-submodule 은 사유 필수이고 audit 에 [team-publish] 를 남긴다 =="
# t_gate_rejects_unpublished 의 거부된 상태를 이어 쓴다(promote 한 번을 아낀다 — archive 두 번은 종전과 같다). 원격 주소를 되돌려
# 거부 사유를 「반영되지 않음」 으로 맞춘 뒤 우회한다.
git -C "$CASE_WT/libs/prod" remote set-url origin "$tg1_url"
tg3_rc=0
tg3_out="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task tg1 --no-remote --force-skip-review-check 테스트 \
  --allow-status-mismatch 테스트 --allow-unpublished-submodule 2>&1 )" || tg3_rc=$?
if [[ "$tg3_rc" != 0 && "$tg3_out" == *"--allow-unpublished-submodule 사유 필수"* ]]; then
  pass "t_gate_bypass_audit: 사유 누락은 차단"
else
  fail "t_gate_bypass_audit(사유 누락): rc=$tg3_rc — $tg3_out"
fi
tg3_rc=0
tg3_out="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task tg1 --no-remote --force-skip-review-check 테스트 \
  --allow-status-mismatch 테스트 --allow-unpublished-submodule 팀저장소_사후반영 2>&1 )" || tg3_rc=$?
tg3_audit="$(cat "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" 2>/dev/null || true)"
if [[ "$tg3_rc" == 0 && "$tg3_out" == *"팀 저장소 반영 검사 우회"* && "$tg3_audit" == *"[team-publish] 팀저장소_사후반영"* ]]; then
  pass "t_gate_bypass_audit: 사유와 함께 우회, audit 에 [team-publish] 기록"
else
  fail "t_gate_bypass_audit: rc=$tg3_rc audit=[$tg3_audit] — $tg3_out"
fi

echo "== t_gate_passes_published: 팀 main 에 반영된 gitlink 는 통과한다 =="
CASE_CFG="$PR_CFG" prep_case tg2
sub_commit "$CASE_WT"; git -C "$CASE_WT/libs/prod" push -q origin HEAD:refs/heads/main; record_gitlink "$CASE_WT"
run_archive "$CASE_REPO" tg2
tg2_msgs="$(git -C "$CASE_REPO" log --first-parent --format=%s -8)"
if [[ "$ARCH_RC" == 0 && "$ARCH_OUT" != *"반영되지 않은"* ]] && grep -qxF "merge: tg2 (archive)" <<<"$tg2_msgs"; then
  pass "t_gate_passes_published: rc=0, merge 완료"
else
  fail "t_gate_passes_published: rc=$ARCH_RC — $ARCH_OUT"
fi
if [[ "$ARCH_OUT" != *"팀 기본 브랜치와 비교"* && "$ARCH_OUT" != *"안내 — 반영 방식 manual"* ]]; then pass "t_gate_passes_published: pr 방식은 manual 안내 없음"; else fail "t_gate_passes_published: manual 안내가 나옴 — $ARCH_OUT"; fi

echo "== t_gate_default_notice: team_publish 키가 없으면 거부 출력에 첫 실행 안내가 들어간다 =="
CASE_CFG=none prep_case tg4
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
run_archive "$CASE_REPO" tg4
if [[ "$ARCH_RC" != 0 && "$ARCH_OUT" == *"이번부터 마감 때 팀 저장소에 PR 을 올립니다(기본 반영 방식 pr). 이전 방식은 rd-workflow/config/workflow.json 의 team_publish.mode 를 manual 로 설정하십시오."* ]]; then
  pass "t_gate_default_notice: 거부 + D8 안내"
else
  fail "t_gate_default_notice: rc=$ARCH_RC — $ARCH_OUT"
fi

echo "== t_gate_config_from_fr: fr 브랜치에서만 mode=manual 로 바꿔도 게이트가 그 값을 따른다 (rd pr open 과 같은 기준) =="
CASE_CFG="$PR_CFG" prep_case tg6
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
printf '{"team_publish": {"mode": "manual"}}\n' > "$CASE_WT/rd-workflow/config/workflow.json"
git -C "$CASE_WT" add rd-workflow/config/workflow.json; git -C "$CASE_WT" commit -q -m "설정: manual"
# t_step4_clears_record 도 이 발행으로 본다(같은 발행 성공 경로 — promote·archive 한 번씩을 아낀다).
tg5_rec="rd-workflow-workspace/.lifecycle/team-prs.tsv"
printf 'path\trepo\tbranch\tbase\turl\thead-oid\tstate\tmerged-oid\tcommits\nlibs/prod\to/r\tb\tmain\thttps://example.invalid/pr/1\t0000000000000000000000000000000000000001\tmerged\t-\t1\n' > "$CASE_WT/$tg5_rec"
git -C "$CASE_WT" add "$tg5_rec"; git -C "$CASE_WT" commit -q -m "기록: PR"
run_archive "$CASE_REPO" tg6
tg6_msgs="$(git -C "$CASE_REPO" log --first-parent --format=%s -8)"
if [[ "$ARCH_RC" == 0 && "$ARCH_OUT" != *"반영되지 않은"* ]] && grep -qxF "merge: tg6 (archive)" <<<"$tg6_msgs"; then
  pass "t_gate_config_from_fr: fr tip 설정(manual)으로 통과"
else
  fail "t_gate_config_from_fr: rc=$ARCH_RC — $ARCH_OUT"
fi
echo "== t_step4_clears_record: Step 4 baseline 커밋이 PR 기록 파일을 지운다 (t_gate_config_from_fr 의 발행) =="
if [[ "$ARCH_RC" == 0 && ! -e "$CASE_REPO/$tg5_rec" ]] && ! git -C "$CASE_REPO" cat-file -e "HEAD:$tg5_rec" 2>/dev/null; then
  pass "t_step4_clears_record: rc=0, 기본 브랜치에 기록 파일 없음"
else
  fail "t_step4_clears_record: rc=$ARCH_RC 파일=$([[ -e "$CASE_REPO/$tg5_rec" ]] && echo 있음 || echo 없음) — $ARCH_OUT"
fi

echo "== t_gate_uninit_sub: 작업 worktree 의 submodule 이 초기화되지 않았으면 원인을 밝히고 거부하며 overlay 저장소에 fetch·set-head 를 하지 않는다 =="
CASE_CFG="$PR_CFG" prep_case tg7
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
git -C "$CASE_WT" submodule deinit -q -f libs/prod
tg7_before="$(gate_main_head)"
run_archive "$CASE_REPO" tg7
if [[ "$ARCH_RC" != 0 && "$ARCH_OUT" == *"작업 worktree 의 submodule 이 초기화되지 않았습니다"* && "$ARCH_OUT" == *"cd $CASE_WT && git submodule update --init libs/prod"* \
   && "$ARCH_OUT" != *"반영되지 않았습니다"* && "$(gate_main_head)" == "$tg7_before" ]] \
   && ! git -C "$CASE_REPO" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
  pass "t_gate_uninit_sub: 미초기화 사유로 거부, overlay origin/HEAD 불변"
else
  fail "t_gate_uninit_sub: rc=$ARCH_RC — $ARCH_OUT"
fi

echo "== t_gate_new_sub: 이 작업이 새로 더한 submodule 은 작업 worktree 의 submodule 로 반영 여부를 판정한다 (기본 worktree 에는 디렉터리가 없음) =="
# 없으면 새는 실수: 기본 worktree 기준이면 새 submodule 은 늘 「초기화되지 않았습니다」 로 거부되고, 안내한 update --init 도 merge 전이라 듣지 않습니다.
CASE_CFG="$PR_CFG" prep_case tg8
git -C "$CASE_WT" submodule add -q "$TEMPLATE_DIR/vendor.git" libs/newsub
git -C "$CASE_WT/libs/newsub" config user.email t@t; git -C "$CASE_WT/libs/newsub" config user.name t
echo n >> "$CASE_WT/libs/newsub/v.txt"; git -C "$CASE_WT/libs/newsub" commit -q -am "newsub change"
record_gitlink "$CASE_WT"
tg8_before="$(gate_main_head)"
run_archive "$CASE_REPO" tg8
if [[ "$ARCH_RC" != 0 && "$ARCH_OUT" == *"libs/newsub"*"팀 저장소 origin/main 에 반영되지 않았습니다"* && "$ARCH_OUT" != *"초기화되지 않았습니다"* \
   && "$(gate_main_head)" == "$tg8_before" ]]; then
  pass "t_gate_new_sub: 새 submodule 을 작업 worktree 에서 판정해 미반영 사유로 거부"
else
  fail "t_gate_new_sub: rc=$ARCH_RC — $ARCH_OUT"
fi

# ---- 결정표 단위 시험: rd_submodule_checkout_sync 를 직접 부른다(promote·archive 없음) ----
# 이 상태들은 `--force-dirty` 없이는 archive Step 0 이 먼저 막는 상태라 통합 경로가 아니다.
source "$SCRIPT_DIR/../_state_common.sh"
source "$SCRIPT_DIR/../_submodule_common.sh"

# mk_direct_case <name> [vendor] — 템플릿 repo 를 복사하고 prod(와 선택적으로 중첩 vendor)에 새 커밋을 만들어 prod.git 에 올린 뒤
# 상위에 gitlink 로 기록한다(= 발행 커밋 DPUB). 그 다음 libs/prod 체크아웃을 옛 커밋으로 되돌려 「불일치」 상태를 만든다.
#   전역: DREPO DPUB DNEW DOLD (prod 의 새·옛 커밋) DVOLD (vendor 옛 커밋)
mk_direct_case() {
  local n="$1" r
  mkdir -p "$TMP/$n"; cp -R "$TEMPLATE_DIR/repo" "$TMP/$n/repo"; r="$TMP/$n/repo"; DREPO="$r"
  git -C "$r/libs/prod" config user.email t@t; git -C "$r/libs/prod" config user.name t
  DOLD="$(git -C "$r/libs/prod" rev-parse HEAD)"; DVOLD="$(git -C "$r/libs/prod/vendor" rev-parse HEAD)"
  if [[ "${2:-}" == vendor ]]; then
    git -C "$r/libs/prod/vendor" config user.email t@t; git -C "$r/libs/prod/vendor" config user.name t
    echo v2 >> "$r/libs/prod/vendor/v.txt"; git -C "$r/libs/prod/vendor" commit -q -am "vendor change"
    git -C "$r/libs/prod/vendor" push -q origin "HEAD:refs/heads/$n"
    git -C "$r/libs/prod" add vendor; git -C "$r/libs/prod" commit -q -m "prod: vendor 갱신"
  else
    echo "c-$RANDOM" >> "$r/libs/prod/p.txt"; git -C "$r/libs/prod" commit -q -am "prod change"
  fi
  git -C "$r/libs/prod" push -q origin "HEAD:refs/heads/$n"
  DNEW="$(git -C "$r/libs/prod" rev-parse HEAD)"
  git -C "$r" add libs/prod; git -C "$r" commit -q -m "gitlink 이동"; DPUB="$(git -C "$r" rev-parse HEAD)"
  git -C "$r/libs/prod" checkout -q --detach "$DOLD"
  [[ "${2:-}" == vendor ]] && git -C "$r/libs/prod/vendor" checkout -q --detach "$DVOLD"
  return 0
}
# sync_out <repo> — 새 단계 함수를 부르고 레코드를 줄로 풀어 SYNC_OUT 에 둔다(필드 구분은 줄바꿈).
sync_out() { SYNC_OUT="$(rd_submodule_checkout_sync "$1" "$DPUB" | tr '\0' '\n')"; }

echo "== W2: 기본 worktree 의 prod 에 미추적 파일 — 갱신하지 않고 잔여로 남긴다 =="
mk_direct_case w2
echo scratch > "$DREPO/libs/prod/untracked.txt"
sync_out "$DREPO"
if [[ "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$DOLD" && "$SYNC_OUT" == *submodule* && "$SYNC_OUT" == *"변경이 있어 갱신하지 않았습니다"* \
      && "$SYNC_OUT" == *"status --short"* && "$SYNC_OUT" == *"git -C $DREPO submodule update --init --recursive -- libs/prod"* ]]; then
  pass "W2: 체크아웃 미갱신, 사유와 status --short 복구 명령"
else
  fail "W2: $SYNC_OUT"
fi

echo "== W5: 기본 worktree 의 prod 가 이미 발행 gitlink 와 같으면 건너뛴다 =="
mk_direct_case w5
git -C "$DREPO/libs/prod" checkout -q --detach "$DNEW"
sync_out "$DREPO"
if [[ -z "$SYNC_OUT" && "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$DNEW" ]]; then
  pass "W5: 불일치 없는 항목은 건너뜀(출력 없음)"
else
  fail "W5: $SYNC_OUT"
fi

echo "== W6: 기본 worktree 에서 libs/prod 가 초기화되지 않음 — 건너뜀 =="
mk_direct_case w6
git -C "$DREPO" submodule deinit -q -f libs/prod
sync_out "$DREPO"
[[ -z "$SYNC_OUT" ]] && pass "W6: 미초기화 submodule 은 건너뛰고 출력 없음" || fail "W6: $SYNC_OUT"

echo "== W7: prod 는 발행 gitlink 에 맞고 중첩 vendor 만 옛 커밋 — vendor 가 맞춰진다 =="
mk_direct_case w7 vendor
git -C "$DREPO/libs/prod" checkout -q --detach "$DNEW"
git -C "$DREPO/libs/prod/vendor" checkout -q --detach "$DVOLD"
sync_out "$DREPO"
w7_want="$(git -C "$DREPO/libs/prod" ls-files -s vendor | awk '{print $2}')"
w7_got="$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)"
if [[ "$SYNC_OUT" == ok* && -n "$w7_want" && "$w7_want" == "$w7_got" && "$w7_got" != "$DVOLD" ]]; then
  pass "W7: 중첩 vendor 체크아웃이 prod 인덱스의 gitlink 로 맞춰졌다"
else
  fail "W7: want=$w7_want got=$w7_got old=$DVOLD out=$SYNC_OUT"
fi

echo "== W8: 기본 worktree 의 prod 가 어떤 ref 에도 없는 커밋을 가리킴 — 갱신하지 않는다 =="
mk_direct_case w8
git -C "$DREPO/libs/prod" commit -q --allow-empty -m "분리 HEAD 커밋"
w8_head="$(git -C "$DREPO/libs/prod" rev-parse HEAD)"
sync_out "$DREPO"
if [[ "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$w8_head" && "$SYNC_OUT" == *"어떤 브랜치·태그에도 없어"* && "$SYNC_OUT" == *"branch <이름>"* ]]; then
  pass "W8: 체크아웃 미갱신, 닿지 않는 HEAD 사유 출력"
else
  fail "W8: $SYNC_OUT"
fi

echo "== W9: 옛 prod 에 기록된 vendor 의 분리 HEAD 커밋 U — prod 이동이 vendor 를 옮기므로 갱신하지 않는다 =="
# vendor 는 `+` 가 아니다(옛 prod 인덱스와 일치). prod 만 `+` 이고 prod HEAD 는 ref 에서 닿는다.
mkdir -p "$TMP/w9"; cp -R "$TEMPLATE_DIR/repo" "$TMP/w9/repo"; DREPO="$TMP/w9/repo"
for w9_d in libs/prod libs/prod/vendor; do git -C "$DREPO/$w9_d" config user.email t@t; git -C "$DREPO/$w9_d" config user.name t; done
DVOLD="$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)"
git -C "$DREPO/libs/prod/vendor" checkout -q --detach; echo u >> "$DREPO/libs/prod/vendor/v.txt"
git -C "$DREPO/libs/prod/vendor" commit -q -am "분리 HEAD 커밋 U"; w9_u="$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)"
git -C "$DREPO/libs/prod" add vendor; git -C "$DREPO/libs/prod" commit -q -m "옛 prod: vendor=U"
w9_oldmid="$(git -C "$DREPO/libs/prod" rev-parse HEAD)"; git -C "$DREPO/libs/prod" push -q origin "HEAD:refs/heads/w9-old"
git -C "$DREPO/libs/prod/vendor" checkout -q --detach "$DVOLD"
git -C "$DREPO/libs/prod" add vendor; git -C "$DREPO/libs/prod" commit -q -m "발행 prod: vendor=옛 커밋"
git -C "$DREPO/libs/prod" push -q origin "HEAD:refs/heads/w9"
git -C "$DREPO" add libs/prod; git -C "$DREPO" commit -q -m "gitlink 이동"; DPUB="$(git -C "$DREPO" rev-parse HEAD)"
git -C "$DREPO/libs/prod" checkout -q --detach "$w9_oldmid"; git -C "$DREPO/libs/prod/vendor" checkout -q --detach "$w9_u"
sync_out "$DREPO"
if [[ "$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD)" == "$w9_u" && "$(git -C "$DREPO/libs/prod" rev-parse HEAD)" == "$w9_oldmid" \
      && "$SYNC_OUT" == submodule* && "$SYNC_OUT" == *"submodule libs/prod/vendor 의 체크아웃 커밋이 어떤 브랜치·태그에도 없어"* ]]; then
  pass "W9: 중첩 vendor 의 닿지 않는 HEAD 를 보고 prod 를 갱신하지 않았다"
else
  fail "W9: vendor=$(git -C "$DREPO/libs/prod/vendor" rev-parse HEAD) U=$w9_u out=$SYNC_OUT"
fi

seal_work() {
  local sid="$1-review-001" h hd
  prep_case "$1"
  sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
  h="$( cd "$CASE_WT" && bash -c 'source rd-workflow/scripts/_state_common.sh; rd_protected_tree_hash HEAD' )"
  hd="$(git -C "$CASE_WT" rev-parse HEAD)"
  mkdir -p "$CASE_WT/rd-workflow-workspace/.lifecycle/review-seals"
  printf 'schema=1\nsession-id=%s\nreview-type=diff-review\ntree-hash=%s\nhead=%s\nbranch-mode=fr\nfr-branch=fr/%s\nrd-version=unknown\nverified=yes\nsealed-at=2026-11-03-0000\n' \
    "$sid" "$h" "$hd" "$1" > "$CASE_WT/rd-workflow-workspace/.lifecycle/review-seals/$sid.seal"
  sed -i.bak -e "s/^review-session=.*/review-session=$sid/" -e 's/^status=.*/status=아카이브 보류/' "$CASE_WT/rd-workflow-workspace/.lifecycle/task-state"; rm -f "$CASE_WT/rd-workflow-workspace/.lifecycle/task-state.bak"
  git -C "$CASE_WT" add -A; git -C "$CASE_WT" commit -q -m "review: seal"
  git -C "$CASE_WT/libs/prod" commit -q --allow-empty -m "merge-like: 같은 트리"
  sub_push "$CASE_WT"
  git -C "$CASE_WT" add libs/prod; git -C "$CASE_WT" commit -q -m "기록: gitlink 이동"
}
run_archive_sealed() {  # <repo> <slug> — 우회 플래그 없이 진짜 seal 검증 경로를 탄다.
  ARCH_RC=0
  ARCH_OUT="$( cd "$1" && bash rd-workflow/scripts/lifecycle/archive.sh --task "$2" --no-remote 2>&1 )" || ARCH_RC=$?
}

echo "== W4a: seal 뒤 prod gitlink 를 같은 트리의 커밋으로 옮겨도 발행된다 (기본 worktree 의 prod 에는 그 커밋 객체가 없다 — 작업 worktree 저장소에서 대체 조회) =="
seal_work w4a
run_archive_sealed "$CASE_REPO" w4a
if [[ "$ARCH_RC" == 0 && "$ARCH_OUT" != *"리뷰 대상 불일치"* ]]; then
  pass "W4a: 같은 트리로 gitlink 이동 — 발행 통과"
else
  fail "W4a: rc=$ARCH_RC — $ARCH_OUT"
fi

# ---- 판정 함수를 직접 부르는 케이스의 준비 ----
# copy_case <name> — 템플릿을 복사만 한다(promote 없음). 전역: CASE_NAME CASE_REPO CASE_WT
copy_case() {
  CASE_NAME="$1"; mkdir -p "$TMP/$1"
  cp -R "$TEMPLATE_DIR/repo" "$TMP/$1/repo"; cp -R "$TEMPLATE_DIR/overlay.git" "$TMP/$1/overlay.git"
  CASE_REPO="$TMP/$1/repo"; CASE_WT="$CASE_REPO/.worktrees/$1"
  git -C "$CASE_REPO" remote set-url origin "$TMP/$1/overlay.git"
}
# light_case <name> — 템플릿을 복사하고 promote 없이 fr/<name> worktree 를 만들어 submodule 을 재귀로 초기화한다.
#   promote 가 쓰는 상태(task-state·CURRENT_TASK)는 만들지 않는다. archive·promote 를 돌리지 않고 판정 함수를
#   직접 부르는 케이스만 쓴다(promote 호출 한 번, 부하 9 에서 약 9초를 아낀다). 전역: CASE_NAME CASE_REPO CASE_WT
light_case() {
  copy_case "$1"
  git -C "$CASE_REPO" worktree add -q -b "fr/$1" "$CASE_WT"
  git -C "$CASE_WT" submodule update -q --init --recursive
  git -C "$CASE_WT/libs/prod" config user.email t@t
  git -C "$CASE_WT/libs/prod" config user.name t
}
source "$SCRIPT_DIR/_merge_precheck.sh"
ARCH_SH="$SCRIPT_DIR/archive.sh"
# arch_fns <이름...> — archive.sh 에서 그 이름의 함수 정의만 꺼낸다(archive.sh 는 라이브러리가 아니라 직접 source 할 수 없다).
arch_fns() {
  awk -v names=" $* " '
    /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { n = $0; sub(/\(.*/, "", n); on = (index(names, " " n " ") > 0) }
    on { print; if ($0 ~ /^\}/ || ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{.*\}[[:space:]]*$/)) on = 0 }' "$ARCH_SH"
}

# ---- submodule gitlink 누락 검사 (change spec 2026-11-06-2215 D1~D4) ----
# prep_gitlink_conflict <name> [extra] — 기본 브랜치가 libs/prod 를 A 로 전진, 작업 브랜치가 갈라진 B 로 전진한 뒤
# 작업 worktree 에서 `git merge main` 으로 gitlink 충돌을 만든다. A·B 는 submodule 원격에 push 한다.
#   준비는 GL_PREP(기본 prep_case)로 한다 — 병합 전 검사를 직접 부르는 케이스는 light_case 를 준다.
#   전역: CASE_NAME CASE_REPO CASE_WT GL_A GL_B
prep_gitlink_conflict() {
  local n="$1" s
  "${GL_PREP:-prep_case}" "$n"
  git -C "$CASE_REPO/libs/prod" config user.email t@t; git -C "$CASE_REPO/libs/prod" config user.name t
  echo "a-$n" > "$CASE_REPO/libs/prod/a.txt"; git -C "$CASE_REPO/libs/prod" add a.txt; git -C "$CASE_REPO/libs/prod" commit -q -m "main side A"
  GL_A="$(git -C "$CASE_REPO/libs/prod" rev-parse HEAD)"
  git -C "$CASE_REPO/libs/prod" push -q origin "HEAD:refs/heads/$n-a"
  git -C "$CASE_REPO" add libs/prod; git -C "$CASE_REPO" commit -q -m "main: gitlink A"
  sub_commit "$CASE_WT"; sub_push "$CASE_WT"; GL_B="$(git -C "$CASE_WT/libs/prod" rev-parse HEAD)"
  record_gitlink "$CASE_WT"
  if [[ "${2:-}" == extra ]]; then   # 작업 브랜치가 새 submodule libs/extra 를 추가한다
    git init -q --bare -b main "$TMP/$n/extra.git"
    s="$TMP/$n/extra-src"; git init -q -b main "$s"
    ( cd "$s" && echo e > e.txt && git add -A && git commit -q -m extra && git push -q "$TMP/$n/extra.git" main )
    git -C "$CASE_WT" submodule add -q "$TMP/$n/extra.git" libs/extra
    git -C "$CASE_WT" commit -q -m "구현: libs/extra 추가"
  fi
  git -C "$CASE_WT" merge main >/dev/null 2>&1 || true
  [[ "$(git -C "$CASE_WT" diff --name-only --diff-filter=U)" == "libs/prod" ]] || { echo "준비 실패: $n 의 충돌 경로가 libs/prod 하나가 아님" >&2; exit 1; }
}
# gl_resolve <oid> — 충돌한 libs/prod 를 oid 로 풀어 병합 커밋을 만든다.
gl_resolve() {
  git -C "$CASE_WT" update-index --add --cacheinfo "160000,$1,libs/prod"
  git -C "$CASE_WT" commit -q --no-edit
}
# gl_commit_gitlink <oid> — 일반 커밋으로 libs/prod gitlink 를 oid 로 올린다.
gl_commit_gitlink() {
  git -C "$CASE_WT" update-index --add --cacheinfo "160000,$1,libs/prod"
  git -C "$CASE_WT" commit -q -m "gitlink 갱신: ${1:0:7}"
}
# gl_make_c — 작업 worktree 의 submodule 에서 A·B 를 모두 담은 커밋 C 를 만들어 push 한다. GL_C.
gl_make_c() {
  git -C "$CASE_WT/libs/prod" fetch -q origin "$CASE_NAME-a"
  git -C "$CASE_WT/libs/prod" merge -q --no-edit FETCH_HEAD >/dev/null
  GL_C="$(git -C "$CASE_WT/libs/prod" rev-parse HEAD)"
  git -C "$CASE_WT/libs/prod" push -q origin "HEAD:refs/heads/$CASE_NAME-c"
}
# gl_make_c_clone — 별도 clone(케이스 디렉터리 안)에서 C 를 만든다. submodule 원격에는 올리지 않는다(G3 가 직접 push). GL_C.
gl_make_c_clone() {
  local c="$TMP/$CASE_NAME/clone"
  git clone -q "$TEMPLATE_DIR/prod.git" "$c"
  git -C "$c" config user.email t@t; git -C "$c" config user.name t
  git -C "$c" checkout -q -b cc "origin/$CASE_NAME"
  git -C "$c" merge -q --no-edit "origin/$CASE_NAME-a" >/dev/null
  GL_C="$(git -C "$c" rev-parse HEAD)"
}
run_gl_wt() {    # 작업 worktree 안에서 archive (기본 체크아웃으로 재실행된다)
  ARCH_RC=0
  ARCH_OUT="$( cd "$CASE_WT" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || ARCH_RC=$?
}
run_gl_repo() {  # 기본 체크아웃에서 --task 로 archive
  ARCH_RC=0
  ARCH_OUT="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task "$CASE_NAME" \
    --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || ARCH_RC=$?
}
# gl_gate_direct — archive 의 병합 전 gitlink 검사(`archive_gitlink_merge_check fr/<이름> HEAD pre`)를 기본 체크아웃에서
#   직접 부른다. 누락·판정 불가 케이스는 archive 가 이 검사에서 멈추므로 판정이 같다. archive 가 검사를 부르고 멈출 때
#   기본 브랜치·원격·tag 가 그대로인지와 우회 안내는 G1(누락)이, 판정 불가에서 멈추는지는 G3 의 push 전 실행이 본다.
#   출력은 ARCH_OUT, rc 는 ARCH_RC.
gl_gate_direct() {
  ARCH_RC=0
  ARCH_OUT="$( cd "$CASE_REPO" && eval "$(arch_fns archive_gitlink_merge_check _archive_gl_oid _archive_gitlink_is_ancestor)" \
    && archive_gitlink_merge_check "fr/$CASE_NAME" HEAD pre 2>&1 )" || ARCH_RC=$?
}
gl_snap() { printf '%s|%s|%s' "$(git -C "$CASE_REPO" rev-parse HEAD)" "$(git -C "$TMP/$CASE_NAME/overlay.git" rev-parse refs/heads/main 2>/dev/null)" "$(git -C "$CASE_REPO" tag --list | tr '\n' ,)"; }
gl_head() { git -C "$CASE_REPO" rev-parse HEAD; }
gl_remote() { git -C "$TMP/$CASE_NAME/overlay.git" rev-parse refs/heads/main 2>/dev/null; }
gl_tags() { git -C "$CASE_REPO" tag --list | tr '\n' ,; }
# ok_if <라벨> <명령...> — 명령이 참이면 PASS, 아니면 FAIL(스위트는 멈추지 않는다).
ok_if() { local l="$1"; shift; if "$@"; then pass "$l"; else fail "$l — rc=$ARCH_RC $ARCH_OUT"; fi; }
out_has() { [[ "$ARCH_OUT" == *"$1"* ]]; }
out_lacks() { [[ "$ARCH_OUT" != *"$1"* ]]; }
eq() { [[ "$1" == "$2" ]]; }
neq() { [[ "$1" != "$2" ]]; }
remote_gitlink() { git -C "$TMP/$CASE_NAME/overlay.git" ls-tree refs/heads/main libs/prod 2>/dev/null | awk '{print $3}'; }

echo "== G1: 누락 병합(A 로 풀음) — 작업 worktree 에서 archive 가 병합 전에 막는다 =="
prep_gitlink_conflict g1; gl_resolve "$GL_A"
g1_head="$(gl_head)"; g1_rem="$(gl_remote)"; g1_tags="$(gl_tags)"
run_gl_wt
ok_if "G1: rc≠0" test "$ARCH_RC" -ne 0
ok_if "G1: 출력에 libs/prod" out_has "libs/prod"
ok_if "G1: 출력에 빠진 B 짧은 해시" out_has "${GL_B:0:7}"
ok_if "G1: 복구 안내" out_has "복구:"
ok_if "G1: 기본 브랜치 HEAD 불변" eq "$(gl_head)" "$g1_head"
ok_if "G1: 원격 main 불변" eq "$(gl_remote)" "$g1_rem"
ok_if "G1: tag 불변" eq "$(gl_tags)" "$g1_tags"
ok_if "G1: 우회 옵션 안내" out_has "--allow-gitlink-drop"
echo "== G1b: 같은 상태로 다시 실행 =="
run_gl_wt
ok_if "G1b: 두 번째 실행도 rc≠0" test "$ARCH_RC" -ne 0
ok_if "G1b: 기본 브랜치 HEAD 불변" eq "$(gl_head)" "$g1_head"
# G5 — 같은 누락을 사유와 함께 우회하면 발행되고 audit 로그에 남는다(squash·rebase submodule 의 출구).
ARCH_RC=0
ARCH_OUT="$( cd "$CASE_WT" && bash rd-workflow/scripts/lifecycle/archive.sh \
  --force-skip-review-check 테스트 --allow-status-mismatch 테스트 --allow-gitlink-drop "squash 병합 확인" 2>&1 )" || ARCH_RC=$?
ok_if "G5: 우회 발행 rc 0" test "$ARCH_RC" -eq 0
ok_if "G5: 원격 main 갱신" test "$(gl_remote)" != "$g1_rem"
ok_if "G5: audit 기록" grep -qF "[gitlink:rc1] squash 병합 확인" "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log"

echo "== G1c: 기본 체크아웃이 먼저 병합해 둔 경우 — 병합 뒤 검사가 막는다 =="
prep_gitlink_conflict g1c; gl_resolve "$GL_A"
git -C "$CASE_REPO" merge -q --no-ff fr/g1c -m "merge: g1c (archive)" >/dev/null
g1c_rem="$(gl_remote)"; g1c_tags="$(gl_tags)"
run_gl_repo
ok_if "G1c: 첫 실행 rc≠0" test "$ARCH_RC" -ne 0
ok_if "G1c: 병합 뒤 검사가 막았다(출력에 libs/prod)" out_has "libs/prod"
ok_if "G1c: 3.6b 가 거부하지 않음(리뷰하지 않은 변경 없음)" out_lacks "리뷰하지 않은 변경"
ok_if "G1c: 되돌림 안내 git reset --keep" out_has "git reset --keep"
run_gl_repo
ok_if "G1c: 두 번째 실행도 rc≠0" test "$ARCH_RC" -ne 0
ok_if "G1c: 두 번째도 되돌림 안내" out_has "git reset --keep"
ok_if "G1c: tag 불변" eq "$(gl_tags)" "$g1c_tags"
ok_if "G1c: 원격 main 불변" eq "$(gl_remote)" "$g1c_rem"

echo "== G2: 누락 병합 뒤 A·B 를 담은 C 로 gitlink 를 더하면 발행된다 =="
prep_gitlink_conflict g2; gl_resolve "$GL_A"; gl_make_c; gl_commit_gitlink "$GL_C"
run_gl_wt
ok_if "G2: rc 0" test "$ARCH_RC" -eq 0
ok_if "G2: 원격 main gitlink == C" eq "$(remote_gitlink)" "$GL_C"

echo "== G2d: 정상 병합(C) 뒤 일반 커밋으로 gitlink 를 B 로 되돌려도 발행된다 =="
prep_gitlink_conflict g2d; gl_make_c; gl_resolve "$GL_C"; gl_commit_gitlink "$GL_B"
run_gl_wt
ok_if "G2d: rc 0" test "$ARCH_RC" -eq 0

echo "== G2e: 누락 병합 → C → A 로 되돌림 — 발행된다 =="
prep_gitlink_conflict g2e; gl_resolve "$GL_A"; gl_make_c; gl_commit_gitlink "$GL_C"; gl_commit_gitlink "$GL_A"
run_gl_wt
ok_if "G2e: rc 0" test "$ARCH_RC" -eq 0


echo "== G2c: 새 submodule 추가 + 충돌한 libs/prod 를 삭제로 풂 — 발행된다 =="
prep_gitlink_conflict g2c extra
git -C "$CASE_WT" rm -q -f libs/prod; git -C "$CASE_WT" commit -q --no-edit
run_gl_wt
ok_if "G2c: rc 0" test "$ARCH_RC" -eq 0

echo "== G2f: 누락 병합 뒤 libs/prod 를 일반 커밋으로 삭제(발행 끝에 libs/extra 가 남음) — 발행된다 =="
prep_gitlink_conflict g2f extra; gl_resolve "$GL_A"
git -C "$CASE_WT" rm -q -f libs/prod; git -C "$CASE_WT" commit -q -m "libs/prod 삭제"
run_gl_wt
ok_if "G2f: rc 0" test "$ARCH_RC" -eq 0

echo "== G2g: 한쪽만 gitlink 를 바꾼 정상 병합 — 작업 브랜치가 libs/prod 를 이전 커밋으로 롤백, 기본 브랜치는 무관한 파일만 전진 =="
prep_case g2g
record_gitlink "$CASE_WT"
g2g_y="$(git -C "$CASE_WT" ls-tree HEAD libs/prod | awk '{print $3}')"
g2g_y="$(git -C "$CASE_WT/libs/prod" rev-parse "${g2g_y}^")"
gl_commit_gitlink "$g2g_y"
echo main-only > "$CASE_REPO/main-only.txt"; git -C "$CASE_REPO" add main-only.txt; git -C "$CASE_REPO" commit -q -m "main: 무관한 파일"
run_gl_wt
ok_if "G2g: rc 0" test "$ARCH_RC" -eq 0
ok_if "G2g: 원격 main libs/prod gitlink == 작업 브랜치 값" eq "$(remote_gitlink)" "$g2g_y"

echo "== G2h: 후손 갈래(topic)를 병합하면서 gitlink 를 이전 값으로 고름 — 부모가 조상 관계여도 막는다 (병합 전 검사 직접 호출) =="
light_case g2h
g2h_old="$(git -C "$CASE_WT" rev-parse HEAD:libs/prod)"
git -C "$CASE_WT" checkout -qb topic
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
git -C "$CASE_WT" checkout -q fr/g2h
git -C "$CASE_WT" merge --no-ff --no-commit topic >/dev/null 2>&1 || true
git -C "$CASE_WT" update-index --cacheinfo "160000,$g2h_old,libs/prod"
git -C "$CASE_WT" commit -qm "merge topic (이전 gitlink 선택)"
gl_gate_direct
ok_if "G2h: 누락으로 판정(rc 1)" test "$ARCH_RC" -eq 1
ok_if "G2h: 빠진 gitlink 안내" out_has "submodule libs/prod 의 커밋을 빠뜨렸습니다"

echo "== G3: C 를 push 하기 전에는 판정 불가로 병합 전에 멈추고, submodule 원격에 push 한 뒤 다시 실행하면 fetch 로 확인하고 발행된다 =="
prep_gitlink_conflict g3; gl_resolve "$GL_A"; gl_make_c_clone; gl_commit_gitlink "$GL_C"
# push 전: 병합 전 검사가 판정 불가(rc 2)를 내면 archive 는 병합하지 않는다. G4·G4b 는 판정만 직접 부르므로
#   archive 게이트가 rc 2 를 차단으로 다루는지는 이 실행이 본다.
g3_head="$(gl_head)"
run_gl_wt
ok_if "G3: push 전 rc≠0" test "$ARCH_RC" -ne 0
ok_if "G3: push 전 판정 불가 안내" out_has "판정 불가"
ok_if "G3: push 전 기본 브랜치 HEAD 불변" eq "$(gl_head)" "$g3_head"
git -C "$TMP/g3/clone" push -q origin "HEAD:refs/heads/g3-c"
run_gl_wt
ok_if "G3: rc 0" test "$ARCH_RC" -eq 0
ok_if "G3: fetch 시작 안내" out_has "원격에서 받습니다"
ok_if "G3: fetch 완료 안내" out_has "fetch 완료"

echo "== G4: C 를 push 하지 않고 submodule 원격 주소도 접근 불가 — fetch 실패, 판정 불가로 멈춘다 (병합 전 검사 직접 호출) =="
GL_PREP=light_case prep_gitlink_conflict g4; gl_resolve "$GL_A"; gl_make_c_clone; gl_commit_gitlink "$GL_C"
git -C "$CASE_REPO/libs/prod" remote set-url origin "$TMP/g4/missing.git"
gl_gate_direct
ok_if "G4: 판정 불가(rc 2)" test "$ARCH_RC" -eq 2
ok_if "G4: fetch 시작 안내" out_has "원격에서 받습니다"
ok_if "G4: fetch 실패 안내" out_has "fetch 실패"
ok_if "G4: 판정 불가 안내" out_has "판정 불가"

echo "== G4b: C 를 push 하지 않음(원격은 정상) — fetch 가 성공해도 객체가 없어 판정 불가로 멈춘다 (병합 전 검사 직접 호출) =="
GL_PREP=light_case prep_gitlink_conflict g4b; gl_resolve "$GL_A"; gl_make_c_clone; gl_commit_gitlink "$GL_C"
gl_gate_direct
ok_if "G4b: 판정 불가(rc 2)" test "$ARCH_RC" -eq 2
ok_if "G4b: fetch 시작 안내" out_has "원격에서 받습니다"
ok_if "G4b: fetch 완료 안내" out_has "fetch 완료"
ok_if "G4b: 판정 불가 안내" out_has "판정 불가"

# ---- promote 의 submodule 초기화 (FR promote-submodule-worktree-init) ----
# copy_case 는 G 구간 앞에 있다.
run_promote() {  # <slug> — stdout 은 PR_OUT, stderr 는 PR_ERR, rc 는 PR_RC
  PR_RC=0
  PR_OUT="$(bash "$CASE_REPO/rd-workflow/scripts/lifecycle/promote.sh" --short-title "$1" --size large --source-fr - 2>"$TMP/pr.err")" || PR_RC=$?
  PR_ERR="$(cat "$TMP/pr.err")"
}

oid_of() { git -C "$1" rev-parse HEAD; }
# bump_gitlink <repo> <name> <경로> <원격 bare> — 원격에 케이스 브랜치 커밋을 만들고, 메인 체크아웃의 submodule 은 그대로 둔 채
# 저장소 main 의 gitlink 만 그 커밋으로 올려 커밋한다. 새 커밋 oid 를 출력한다.
bump_gitlink() {
  local repo="$1" n="$2" sp="$3" remote="$4" c oid
  c="$(mktemp -d "$TMP/$2/bump.XXXXXX")" || { echo "bump_gitlink: 임시 디렉터리 생성 실패" >&2; return 1; }
  git clone -q "$remote" "$c"
  basename "$c" > "$c/bump.txt"; git -C "$c" add -A; git -C "$c" commit -q -m bump
  git -C "$c" push -q origin "HEAD:refs/heads/${n}-$(basename "$c")"
  oid="$(git -C "$c" rev-parse HEAD)"
  git -C "$repo" update-index --cacheinfo "160000,${oid},${sp}"
  git -C "$repo" commit -q -m "bump $sp"
  printf '%s\n' "$oid"
}
# rd_init <worktree|메인> [경로...] — 그 디렉터리에서 rd submodule init 을 실행한다. 출력(stdout+stderr)은 INIT_OUT, rc 는 INIT_RC.
rd_init() {
  local d="$1"; shift
  INIT_RC=0; INIT_OUT="$( cd "$d" && bash rd-workflow/scripts/rd submodule init "$@" 2>&1 )" || INIT_RC=$?
}
# file_inode <파일> — macOS·Linux 공통.
file_inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

echo "== P1: promote 가 원격 없이 기본 설정에서 메인 체크아웃의 submodule 을 중첩까지 받는다 =="
copy_case p1
git -C "$CASE_REPO" config submodule.libs/prod.url "$TMP/p1/missing.git"
p1_cfg_before="$(git -C "$CASE_REPO" config submodule.libs/prod.url)"
# 기본 설정(protocol.file.allow 없음)에서 돌린다 — 로컬 원천 명령만 file 프로토콜을 허용해야 한다.
p1_ck="$GIT_CONFIG_COUNT $GIT_CONFIG_KEY_0 $GIT_CONFIG_VALUE_0"
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
run_promote p1
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
read -r GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 <<<"$p1_ck"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
p1_wtmod="$(git -C "$CASE_WT/libs/prod" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
p1_f="$(cd "$p1_wtmod/objects" 2>/dev/null && find . -type f | sort | head -n 1 || true)"
p1_main="$CASE_REPO/.git/modules/libs/prod/objects/$p1_f"
p1_ino_ok=0
[[ -n "$p1_f" && -f "$p1_wtmod/objects/$p1_f" && -f "$p1_main" && "$(file_inode "$p1_wtmod/objects/$p1_f")" == "$(file_inode "$p1_main")" ]] && p1_ino_ok=1
p1_vo="$(git -C "$CASE_WT/libs/prod/vendor" remote get-url origin 2>/dev/null || true)"
if [[ "$PR_RC" == 0 && -f "$CASE_WT/libs/prod/p.txt" && -f "$CASE_WT/libs/prod/vendor/v.txt" ]]; then pass "P1: rc=0, libs/prod·vendor 체크아웃됨"; else fail "P1: rc=$PR_RC — $PR_OUT / $PR_ERR"; fi
if [[ "$(git -C "$CASE_WT/libs/prod" remote get-url origin 2>/dev/null || true)" == "$TMP/p1/missing.git" ]]; then pass "P1: libs/prod origin 이 원래 URL"; else fail "P1: libs/prod origin 이 원래 URL 이 아님"; fi
if [[ -n "$p1_vo" && "$p1_vo" != "$CASE_REPO"* ]]; then pass "P1: vendor origin 이 메인 체크아웃 경로가 아님"; else fail "P1: vendor origin=$p1_vo"; fi
if [[ "$(git -C "$CASE_REPO" config submodule.libs/prod.url)" == "$p1_cfg_before" ]]; then pass "P1: 공용 config URL 불변"; else fail "P1: 공용 config URL 이 바뀜"; fi
if [[ "$PR_OUT" == *"submodule 준비 완료"* && "$PR_OUT$PR_ERR" != *"비워 두었습니다"* ]]; then pass "P1: 준비 완료 안내, 비움 안내 없음"; else fail "P1: $PR_OUT / $PR_ERR"; fi
if [[ "$p1_ino_ok" == 1 ]]; then pass "P1: 객체 파일이 메인과 hardlink (inode 동일)"; else fail "P1: hardlink 아님 (file=$p1_f)"; fi
if [[ "$PR_RC" == 0 && "$PR_ERR" == *"submodule libs/prod 를 팀 기본 브랜치와 비교하지 못해 알림을 건너뜁니다 — fatal:"* ]]; then pass "P1: 팀 원격 조회 실패 — 알림을 건너뛰고 착수 계속"; else fail "P1: 조회 실패 건너뜀 — rc=$PR_RC $PR_ERR"; fi

echo "== P2: 메인에 없는 gitlink 커밋은 원격 접근이 필요하다는 안내와 함께 원격에서 받는다 =="
copy_case p2
p2_new="$(bump_gitlink "$CASE_REPO" p2 libs/prod "$TEMPLATE_DIR/prod.git")"
run_promote p2
if [[ "$PR_RC" == 0 && "$PR_ERR" == *"원격 접근이 필요합니다: libs/prod — 커밋 ${p2_new:0:7} 이 메인 체크아웃에 없습니다"* ]]; then pass "P2: 원격 접근 안내"; else fail "P2: rc=$PR_RC — $PR_ERR"; fi
if [[ "$(oid_of "$CASE_WT/libs/prod" 2>/dev/null || true)" == "$p2_new" ]]; then pass "P2: 새 커밋이 체크아웃됨"; else fail "P2: HEAD=$(oid_of "$CASE_WT/libs/prod" 2>&1) — $PR_ERR"; fi

echo "== P3: 응답 없는 원격은 상한에서 멈추고 로컬 시간은 상한에서 제외한다 =="
copy_case p3
( cd "$CASE_REPO" \
  && git submodule add -q "$TEMPLATE_DIR/vendor.git" libs/v2 && git submodule add -q "$TEMPLATE_DIR/vendor.git" libs/v3 \
  && git submodule add -q "$TEMPLATE_DIR/vendor.git" libs/v4 && git commit -q -m "v2 v3 v4" \
  && git submodule deinit -q -f libs/v4 )
p3_v2="$(bump_gitlink "$CASE_REPO" p3 libs/v2 "$TEMPLATE_DIR/vendor.git")"
p3_v3="$(bump_gitlink "$CASE_REPO" p3 libs/v3 "$TEMPLATE_DIR/vendor.git")"
mkdir -p "$TMP/p3/hooks"
printf '#!/bin/sh\ncase "$PWD" in */libs/prod) sleep 3;; esac\n' > "$TMP/p3/hooks/post-checkout"; chmod +x "$TMP/p3/hooks/post-checkout"
# 늦춘 원격은 60초 sleep 을 마치면 완료 표식(ssh-done)을 남긴다. `&&` 라 상한이 sleep 을 끊으면 표식을 쓰지 않는다
# (`;` 면 그룹 KILL 중 sleep 이 먼저 죽을 때 셸이 다음 줄을 실행해 표식이 생긴다 — U5 주석의 실측).
printf '#!/bin/sh\necho $$ >> "%s"\nsleep 60 && echo x >> "%s"\n' "$TMP/p3/ssh-pids" "$TMP/p3/ssh-done" > "$TMP/p3/ssh-hang.sh"; chmod +x "$TMP/p3/ssh-hang.sh"
git -C "$CASE_REPO" config submodule.libs/v2.url "ssh://h/v2.git"
git -C "$CASE_REPO" config submodule.libs/v3.url "ssh://h/v3.git"
p3_t0=$SECONDS
GIT_SSH_COMMAND="$TMP/p3/ssh-hang.sh" GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1="$TMP/p3/hooks" \
  RD_SUBMODULE_REMOTE_TIMEOUT=2 run_promote p3
p3_late=0; [[ ! -e "$TMP/p3/ssh-done" ]] || p3_late=1
p3_el=$((SECONDS - p3_t0))
# 반환 판정은 고정 경과 문턱이 아니라 늦춘 원격의 완료 표식으로 한다. 상한이 듣지 않으면 원격이 60초 sleep 을 마치고
# 표식을 남긴 뒤에야 promote 가 돌아온다. 고정 60초 문턱은 부하 평균 9~10 에서 정상 경로도 넘겼다(64초 실측, 2026-11-23).
# 경과 초는 표시용이다.
if [[ "$PR_RC" == 0 && "$p3_late" == 0 && -f "$CASE_WT/libs/prod/p.txt" ]]; then pass "P3: rc=0, 늦춘 원격의 지연이 끝나기 전에 반환(경과 ${p3_el}초), 로컬 submodule 은 받음"; else fail "P3: rc=$PR_RC 늦춘 원격 완료 표식=$([[ "$p3_late" == 1 ]] && echo 있음 || echo 없음) 경과=${p3_el}초 prod=$([[ -f "$CASE_WT/libs/prod/p.txt" ]] && echo 있음 || echo 없음) — $PR_ERR"; fi
if [[ "$PR_ERR" == *"submodule 받기 실패: libs/v2"* && "$PR_ERR" == *"시간 초과(2초)"* ]]; then pass "P3: libs/v2 시간 초과(2초) — 로컬 시간이 예산을 깎지 않음"; else fail "P3: libs/v2 안내 — $PR_ERR"; fi
if [[ "$PR_ERR" == *"submodule 받기 실패: libs/v3"* && "$PR_ERR" == *"원격 대기 상한(2초)을 다 써서 시도하지 않았습니다"* ]]; then pass "P3: libs/v3 예산 소진으로 시도하지 않음"; else fail "P3: libs/v3 안내 — $PR_ERR"; fi
if [[ "$PR_ERR" == *"재시도: bash rd-workflow/scripts/rd submodule init libs/v2"* && "$PR_ERR" == *"재시도: bash rd-workflow/scripts/rd submodule init libs/v3"* ]]; then pass "P3: 재시도 명령 두 개"; else fail "P3: 재시도 — $PR_ERR"; fi
p3_alive=""
while read -r p3_pid; do kill -0 "$p3_pid" 2>/dev/null && p3_alive="$p3_alive $p3_pid"; done < "$TMP/p3/ssh-pids"
if [[ -s "$TMP/p3/ssh-pids" && -z "$p3_alive" ]]; then pass "P3: 시간 초과로 멈춘 원격 명령의 자식(ssh)이 반환 뒤에 남지 않음"; else fail "P3: 반환 뒤 살아 있는 ssh:${p3_alive:- (pid 기록 없음)}"; fi
if [[ "$PR_ERR" == *"submodule 준비 실패"* && "$PR_ERR" == *"비워 두었습니다: libs/v4"* ]]; then pass "P3: 실패가 있어도 비워 둔 경로(libs/v4)를 알림"; else fail "P3: 실패·비움 혼합 안내 — $PR_ERR"; fi
if [[ "$(git -C "$CASE_WT/libs/v2" remote get-url origin 2>/dev/null || true)" == "ssh://h/v2.git" ]]; then pass "P3: libs/v2 origin 이 원래 URL"; else fail "P3: libs/v2 origin=$(git -C "$CASE_WT/libs/v2" remote get-url origin 2>&1)"; fi
git -C "$CASE_REPO" config submodule.libs/v2.url "$TEMPLATE_DIR/vendor.git"
rd_init "$CASE_WT" libs/v2
if [[ "$INIT_RC" == 0 && "$(oid_of "$CASE_WT/libs/v2" 2>/dev/null || true)" == "$p3_v2" ]]; then pass "P3: 재시도 명령으로 libs/v2 를 받음"; else fail "P3: 재시도 rc=$INIT_RC — $INIT_OUT"; fi

echo "== P4: 메인에서 초기화하지 않은 submodule 은 비워 두고 공용 config 를 건드리지 않으며, archive 가 worktree 를 지운다 =="
copy_case p4
git -C "$CASE_REPO" submodule deinit -q -f libs/prod
run_promote p4
p4_st="$(git -C "$CASE_WT" submodule status -- libs/prod 2>/dev/null || true)"
if [[ "$PR_RC" == 0 && "${p4_st:0:1}" == "-" && "$PR_ERR" == *"비워 두었습니다: libs/prod"* && "$PR_ERR" == *"rd submodule init"* && -z "$(git -C "$CASE_REPO" config submodule.libs/prod.url || true)" ]]; then
  pass "P4: rc=0, 비어 있음(-), 안내, 공용 config URL 없음"
else
  fail "P4: rc=$PR_RC st=[$p4_st] — $PR_OUT / $PR_ERR"
fi
run_archive "$CASE_REPO" p4
if [[ ! -d "$CASE_WT" ]]; then pass "P4: archive 후 worktree 디렉터리가 사라짐"; else fail "P4: worktree 남음 rc=$ARCH_RC — $ARCH_OUT"; fi
rd_init "$CASE_REPO" libs/prod
if [[ "$INIT_RC" == 0 && "$INIT_OUT" == *"메인 체크아웃이라 원천이 자기 자신입니다"* && -f "$CASE_REPO/libs/prod/p.txt" ]]; then pass "P4: 메인에서 rd submodule init 이 원격으로 받음"; else fail "P4: 메인 init rc=$INIT_RC — $INIT_OUT"; fi

echo "== P5: 중첩 submodule 만 메인에서 비어 있으면 그 경로만 비워 두고, init 은 인자를 먼저 모두 검증한다 =="
copy_case p5
git -C "$CASE_REPO/libs/prod" submodule deinit -q -f vendor
run_promote p5
p5_st="$(git -C "$CASE_WT/libs/prod" submodule status 2>/dev/null || true)"
p5_list="$(printf '%s\n' "$PR_ERR" | grep -o '비워 두었습니다: .*' || true)"
if [[ "$PR_RC" == 0 && -f "$CASE_WT/libs/prod/p.txt" && "${p5_st:0:1}" == "-" && "$p5_list" == "비워 두었습니다: libs/prod/vendor" ]]; then
  pass "P5: libs/prod 는 받고 비워 둔 목록은 libs/prod/vendor 하나"
else
  fail "P5: rc=$PR_RC st=[$p5_st] list=[$p5_list] — $PR_ERR"
fi
rd_init "$CASE_WT" libs/prod/vendor nope
p5_st="$(git -C "$CASE_WT/libs/prod" submodule status 2>/dev/null || true)"
if [[ "$INIT_RC" == 1 && "$INIT_OUT" == *"submodule 이 아닙니다: nope"* && "${p5_st:0:1}" == "-" ]]; then pass "P5: 잘못된 인자가 있으면 아무것도 받지 않음"; else fail "P5: rc=$INIT_RC st=[$p5_st] — $INIT_OUT"; fi
rd_init "$CASE_WT" libs/prod/vendor
if [[ "$INIT_RC" == 0 && -f "$CASE_WT/libs/prod/vendor/v.txt" && "$INIT_OUT" == *"메인 체크아웃에서 초기화하지 않았습니다"* ]]; then pass "P5: worktree 에서 중첩 경로를 받음"; else fail "P5: rc=$INIT_RC — $INIT_OUT"; fi
rd_init "$CASE_REPO" libs/prod/vendor
if [[ "$INIT_RC" == 0 && -f "$CASE_REPO/libs/prod/vendor/v.txt" && "$INIT_OUT" == *"메인 체크아웃이라 원천이 자기 자신입니다"* ]]; then pass "P5: 메인 분기에서 중첩 경로를 받음"; else fail "P5: 메인 rc=$INIT_RC — $INIT_OUT"; fi

# ---- 반영 방식 manual 인 submodule 의 gitlink 알림 (FR archive-gitlink-team-default-branch) ----
# lag_case <name> — copy_case 에 케이스 전용 팀 저장소(prod.git 복사본)를 붙인다. 공유 prod.git 의 main 은 다른 케이스가 옮기므로 쓰지 않는다.
lag_case() {
  copy_case "$1"
  cp -R "$TEMPLATE_DIR/prod.git" "$TMP/$1/prod.git"
  git -C "$CASE_REPO" config submodule.libs/prod.url "$TMP/$1/prod.git"
  git -C "$CASE_REPO/libs/prod" remote set-url origin "$TMP/$1/prod.git"
  LAG_GL="$(git -C "$CASE_REPO" ls-tree HEAD libs/prod | awk '{print $3}')"
}
# team_main_push <name> — 케이스 팀 저장소 main 에 커밋 하나를 올린다.
team_main_push() {
  local c
  c="$(mktemp -d "$TMP/$1/main.XXXXXX")" || { echo "team_main_push: 임시 디렉터리 생성 실패" >&2; return 1; }
  git clone -q "$TMP/$1/prod.git" "$c"
  echo n > "$c/n.txt"; git -C "$c" add -A; git -C "$c" commit -q -m n; git -C "$c" push -q origin HEAD:main
}
wt_gitlink() { git -C "$CASE_WT" ls-tree HEAD libs/prod | awk '{print $3}'; }

echo "== P6: manual gitlink 가 팀 기본 브랜치보다 뒤 — 몇 커밋 뒤인지와 브랜치를 따는 명령을 알리고 gitlink 는 옮기지 않는다 =="
lag_case p6
team_main_push p6
p6_n="$(git -C "$TMP/p6/prod.git" rev-list --count "$LAG_GL..main")"
run_promote p6
if [[ "$PR_RC" == 0 && "$PR_ERR" == *"submodule libs/prod 의 gitlink ${LAG_GL:0:7} 가 팀 기본 브랜치 origin/main 끝"*"${p6_n} 커밋 뒤입니다"* ]]; then pass "P6: ${p6_n} 커밋 뒤 알림"; else fail "P6: 뒤짐 알림 — rc=$PR_RC $PR_ERR"; fi
if [[ "$PR_ERR" == *"git -C $CASE_WT/libs/prod fetch origin refs/heads/main && git -C $CASE_WT/libs/prod switch --no-overwrite-ignore -c p6 FETCH_HEAD"* ]]; then pass "P6: 브랜치를 따는 명령 전문"; else fail "P6: 명령 — $PR_ERR"; fi
if [[ "$(wt_gitlink)" == "$LAG_GL" ]]; then pass "P6: 작업 브랜치 gitlink 불변"; else fail "P6: gitlink=$(wt_gitlink) 기대=$LAG_GL"; fi

echo "== P7: manual gitlink 가 팀 기본 브랜치에 없는 커밋 — 기본 브랜치 밖 커밋이라고 알린다 =="
lag_case p7
p7_new="$(bump_gitlink "$CASE_REPO" p7 libs/prod "$TMP/p7/prod.git")"
run_promote p7
if [[ "$PR_RC" == 0 && "$PR_ERR" == *"gitlink ${p7_new:0:7} 는 팀 기본 브랜치 origin/main 에 없는 커밋입니다"* && "$PR_ERR" == *"switch --no-overwrite-ignore -c p7 FETCH_HEAD"* ]]; then pass "P7: 기본 브랜치 밖 커밋 알림"; else fail "P7: rc=$PR_RC — $PR_ERR"; fi

echo "== P8: 반영 방식 pr 이면 gitlink 가 뒤져도 promote 가 비교하지 않는다 =="
lag_case p8
printf '%s\n' '{"team_publish": {"mode": "pr"}}' > "$CASE_REPO/rd-workflow/config/workflow.json"
git -C "$CASE_REPO" commit -q -am "test: pr"
team_main_push p8
run_promote p8
if [[ "$PR_RC" == 0 && "$PR_ERR" != *"팀 기본 브랜치와 비교"* && "$PR_ERR" != *"팀 기본 브랜치 origin/"* ]]; then pass "P8: pr 방식은 알림 없음"; else fail "P8: rc=$PR_RC — $PR_ERR"; fi

echo "== Q1: 받기 실패로 남은 잔여 상태에서 사용자 파일을 덮어쓰지 않는다 =="
copy_case q1
q1_new="$(bump_gitlink "$CASE_REPO" q1 libs/prod "$TEMPLATE_DIR/prod.git")"
git -C "$CASE_REPO" worktree add -q "$CASE_WT" -b fr/q1
git -C "$CASE_REPO" config submodule.libs/prod.url "$TMP/q1/missing.git"
rd_init "$CASE_WT"
mkdir -p "$CASE_WT/libs/prod"; printf 'USER' > "$CASE_WT/libs/prod/p.txt"
git -C "$CASE_REPO" config submodule.libs/prod.url "$TEMPLATE_DIR/prod.git"
rd_init "$CASE_WT" libs/prod
if [[ "$INIT_RC" == 1 && "$INIT_OUT" == *"submodule 받기 실패: libs/prod"* && "$(cat "$CASE_WT/libs/prod/p.txt")" == "USER" ]]; then pass "Q1: rc=1, 사용자 파일 유지"; else fail "Q1: rc=$INIT_RC p.txt=$(cat "$CASE_WT/libs/prod/p.txt" 2>&1) — $INIT_OUT"; fi
# 같은 잔여 상태(index 없는 저장소)에서 git 이 받기를 건너뛰면(update=none) 성공으로 세지 않는다.
rm -f "$CASE_WT/libs/prod/p.txt"
git -C "$CASE_REPO" config submodule.libs/prod.update none
rd_init "$CASE_WT" libs/prod
if [[ "$INIT_RC" == 1 && "$INIT_OUT" == *"submodule 받기 실패: libs/prod"* && "$INIT_OUT" == *"update=none"* ]]; then pass "Q1: 잔여 상태에서 건너뛴 받기는 실패로 알림"; else fail "Q1: update=none 재시도 rc=$INIT_RC — $INIT_OUT"; fi

echo "== Q2: 이미 받은 submodule 은 건드리지 않는다 =="
copy_case q2
git -C "$CASE_REPO" worktree add -q "$CASE_WT" -b fr/q2
rd_init "$CASE_WT" libs/prod
echo extra >> "$CASE_WT/libs/prod/p.txt"; git -C "$CASE_WT/libs/prod" commit -q -am "q2 commit"
echo dirty >> "$CASE_WT/libs/prod/p.txt"
q2_head="$(oid_of "$CASE_WT/libs/prod")"; q2_body="$(cat "$CASE_WT/libs/prod/p.txt")"
rd_init "$CASE_WT" libs/prod
if [[ "$INIT_RC" == 0 && "$INIT_OUT" == *"이미 받았습니다: libs/prod"* && "$(oid_of "$CASE_WT/libs/prod")" == "$q2_head" && "$(cat "$CASE_WT/libs/prod/p.txt")" == "$q2_body" ]]; then
  pass "Q2: rc=0, 이미 받았습니다, HEAD·수정 불변"
else
  fail "Q2: rc=$INIT_RC — $INIT_OUT"
fi

echo "== Q3: 중첩만 실패하면 재시도 명령으로 이어 받고 받은 부분은 건드리지 않는다 =="
copy_case q3
git -C "$CASE_REPO" submodule deinit -q -f libs/prod
git -C "$CASE_REPO" worktree add -q "$CASE_WT" -b fr/q3
q3_rc=0; q3_out="$( cd "$CASE_WT" && GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1="url.$TMP/q3/missing.git.insteadOf" GIT_CONFIG_VALUE_1="$TEMPLATE_DIR/vendor.git" \
  bash rd-workflow/scripts/rd submodule init libs/prod 2>&1 )" || q3_rc=$?
q3_st="$(git -C "$CASE_WT/libs/prod" submodule status 2>/dev/null || true)"
if [[ "$q3_rc" == 1 && -f "$CASE_WT/libs/prod/p.txt" && "${q3_st:0:1}" == "-" && "$q3_out" == *"submodule 받기 실패: libs/prod"* \
      && "$q3_out" == *"재시도: bash rd-workflow/scripts/rd submodule init libs/prod"* ]]; then
  pass "Q3: 첫 호출 rc=1, prod 는 받고 vendor 는 비어 있으며 재시도 명령 안내"
else
  fail "Q3: rc=$q3_rc st=[$q3_st] — $q3_out"
fi
printf 'USER2' > "$CASE_WT/libs/prod/p.txt"; q3_head="$(oid_of "$CASE_WT/libs/prod")"
rd_init "$CASE_WT" libs/prod
if [[ "$INIT_RC" == 0 && -f "$CASE_WT/libs/prod/vendor/v.txt" && "$(oid_of "$CASE_WT/libs/prod")" == "$q3_head" && "$(cat "$CASE_WT/libs/prod/p.txt")" == "USER2" ]]; then
  pass "Q3: 재시도로 vendor 를 받고 prod HEAD·수정 불변"
else
  fail "Q3: 재시도 rc=$INIT_RC — $INIT_OUT"
fi

echo "== Q4: git 이 받기를 건너뛰는 설정(update=none)에서 상위 origin 을 바꾸지 않고 실패로 알린다 =="
copy_case q4
git -C "$CASE_REPO" config submodule.libs/prod.update none
q4_origin="$(git -C "$CASE_REPO" remote get-url origin)"
run_promote q4
q4_st="$(git -C "$CASE_WT" submodule status -- libs/prod 2>/dev/null || true)"
if [[ "$PR_RC" == 0 && "$(git -C "$CASE_REPO" remote get-url origin)" == "$q4_origin" && "${q4_st:0:1}" == "-" \
      && "$PR_ERR" == *"submodule 받기 실패: libs/prod"* && "$PR_ERR" == *"update=none"* && "$PR_ERR" == *"submodule 준비 실패"* ]]; then
  pass "Q4: 상위 origin 불변, 비어 있음(-), 실패·원인 안내"
else
  fail "Q4: rc=$PR_RC origin=$(git -C "$CASE_REPO" remote get-url origin) st=[$q4_st] — $PR_ERR"
fi
# 원천이 없어 원격에서 받는 분기도 같은 확인을 거친다 — 메인에서 비우고 update=none 을 둔 뒤 worktree 에서 받는다.
git -C "$CASE_REPO" submodule deinit -q -f libs/prod
git -C "$CASE_REPO" config submodule.libs/prod.update none
rd_init "$CASE_WT" libs/prod
if [[ "$INIT_RC" == 1 && "$(git -C "$CASE_REPO" remote get-url origin)" == "$q4_origin" && "$INIT_OUT" == *"원격 접근이 필요합니다: libs/prod"* && "$INIT_OUT" == *"update=none"* ]]; then
  pass "Q4: 원격 분기에서도 상위 origin 불변, 실패·원인 안내"
else
  fail "Q4: init rc=$INIT_RC origin=$(git -C "$CASE_REPO" remote get-url origin) — $INIT_OUT"
fi

# ---- 미push 판정의 원격 tag (FR submodule-unpushed-check-remote-tags) ----
tree_clean() {  # stdout 은 TC_OUT, stderr 는 TC_ERR, rc 는 TC_RC
  TC_RC=0; TC_OUT="$(rd_submodule_tree_clean "$1" --require-pushed 2>"$TMP/tc.err")" || TC_RC=$?
  TC_ERR="$(cat "$TMP/tc.err")"
}

echo "== U1: 원격에 push 한 annotated tag 로만 닿는 submodule 커밋은 미push 가 아니다 =="
light_case u1
sub_commit "$CASE_WT"
git -C "$CASE_WT/libs/prod" tag -a "u1-t1" -m t1; git -C "$CASE_WT/libs/prod" push -q origin "refs/tags/u1-t1"
record_gitlink "$CASE_WT"
tree_clean "$CASE_WT"
if [[ "$TC_RC" == 0 ]]; then pass "U1: clean"; else fail "U1: rc=$TC_RC — $TC_OUT"; fi

echo "== U2: push 하지 않은 로컬 tag 로 닿는 커밋은 여전히 미push 다 =="
sub_commit "$CASE_WT"
git -C "$CASE_WT/libs/prod" tag -a "u1-t2" -m t2
record_gitlink "$CASE_WT"
tree_clean "$CASE_WT"
if [[ "$TC_RC" == 1 && "$TC_OUT" == "unpushed"$'\t'"libs/prod" ]]; then pass "U2: unpushed"; else fail "U2: rc=$TC_RC — $TC_OUT"; fi

echo "== U3: 원격 tag 조회(ls-remote)가 실패하면 미push 로 본다 =="
light_case u3
sub_commit "$CASE_WT"
git -C "$CASE_WT/libs/prod" tag -a "u3-t1" -m t1; git -C "$CASE_WT/libs/prod" push -q origin "refs/tags/u3-t1"
record_gitlink "$CASE_WT"
git -C "$CASE_WT/libs/prod" remote set-url origin "$TMP/u3/missing.git"
tree_clean "$CASE_WT"
if [[ "$TC_RC" == 1 && "$TC_OUT" == "unpushed"$'\t'"libs/prod" && "$TC_ERR" == *"submodule libs/prod: 원격 origin tag 조회 실패"* ]]; then
  pass "U3: unpushed, 조회 실패 안내"
else
  fail "U3: rc=$TC_RC — $TC_OUT / $TC_ERR"
fi

echo "== U4: 저장소의 core.sshCommand 로만 닿는 원격도 tag 를 조회한다 (사용자 전송 설정을 덮어쓰지 않음) =="
# u3 의 worktree 를 이어 쓴다: tag u3-t1 은 prod.git 에 push 돼 있다. 원격 주소는 ssh 로 바꾸고,
# 저장소 설정의 sshCommand 래퍼만 실제 prod.git 의 upload-pack 으로 잇는다.
printf '#!/bin/sh\nexec git-upload-pack "%s"\n' "$TEMPLATE_DIR/prod.git" > "$TMP/u3/ssh-wrap.sh"; chmod +x "$TMP/u3/ssh-wrap.sh"
git -C "$CASE_WT/libs/prod" remote set-url origin "ssh://127.0.0.1:1/prod.git"
git -C "$CASE_WT/libs/prod" config core.sshCommand "$TMP/u3/ssh-wrap.sh"
git -C "$CASE_WT/libs/prod" config ssh.variant ssh
tree_clean "$CASE_WT"
if [[ "$TC_RC" == 0 ]]; then pass "U4: clean"; else fail "U4: rc=$TC_RC — $TC_OUT / $TC_ERR"; fi

echo "== U5: 응답하지 않는 원격은 대기 상한에서 멈추고 미push 로 본다 — TERM 을 무시하는 실행에서도 (공유 락을 오래 붙잡지 않음) =="
# 래퍼는 u5_hang 초 동안 응답하지 않다가 스스로 끝납니다. 제품이 상한에서 프로세스 그룹을 끊으면 그보다 훨씬 먼저 돌아오고,
# 끊지 못하면 래퍼가 끝날 때까지 기다립니다. 그래서 경과를 래퍼 수명과 비교합니다. 고정 상한(종전 10초)은 쓰지 않습니다 —
# 병렬 self_test 부하에서 정상 경과(약 5초)가 33초까지 늘어나는 것을 실측했습니다(2026-11-18).
# 래퍼가 끝난 뒤 표식을 쓰게 하는 판정은 쓰지 않습니다 — macOS 에서 그룹 KILL 중에 sleep 이 먼저 죽으면 래퍼 셸이
# 다음 줄을 실행해 표식을 남기는 경합을 10회 중 5회 실측했습니다.
u5_hang=120
printf '#!/bin/sh\nexec sleep %s\n' "$u5_hang" > "$TMP/u3/ssh-hang.sh"; chmod +x "$TMP/u3/ssh-hang.sh"
git -C "$CASE_WT/libs/prod" config core.sshCommand "$TMP/u3/ssh-hang.sh"
u5_t0=$SECONDS
# 호출 셸이 TERM 을 무시하면 git·래퍼도 무시를 상속합니다. 그래도 상한 + 유예(2초) 뒤 KILL 로 끊고 돌아와야 합니다.
trap '' TERM
RD_LSREMOTE_TIMEOUT=2 tree_clean "$CASE_WT"
trap - TERM
u5_el=$((SECONDS - u5_t0))
if [[ "$TC_RC" == 1 && "$TC_OUT" == "unpushed"$'\t'"libs/prod" && "$TC_ERR" == *"2초 안에 끝나지 않아 멈췄습니다"* && "$u5_el" -lt "$u5_hang" ]]; then
  pass "U5: unpushed, 시간 초과 안내, 응답 없는 원격(${u5_hang}초)을 끊고 ${u5_el}초 만에 돌아옴"
else
  fail "U5: rc=$TC_RC 경과=${u5_el}초 (원격 수명 ${u5_hang}초) — $TC_OUT / $TC_ERR"
fi

echo "== U6: 기본 체크아웃 submodule 의 로컬 브랜치로 닿는 커밋만 미push 에서 빼고, 원격 추적 ref·객체로만 닿는 커밋은 남긴다 =="
# 없으면 새는 실수: 기본 체크아웃에 gitlink 커밋이 있다는 이유로 worktree 의 다른 미push 커밋까지 빼거나, 객체가 있다는 것만
#   보고 빼서 worktree 를 지운 뒤 그 커밋을 gc 로 잃는다(FR archive-carry-worktree-submodule-commits). 기본 쪽 원격 추적 ref 는
#   원격 브랜치가 지워진 뒤 fetch --prune 으로 사라지므로 근거가 아니다 — c2 는 지워진 원격 브랜치의 뒤처진 추적 ref 로만 닿는다.
light_case u6
sub_commit "$CASE_WT"; u6_c1="$(git -C "$CASE_WT/libs/prod" rev-parse HEAD)"
sub_commit "$CASE_WT"; u6_c2="$(git -C "$CASE_WT/libs/prod" rev-parse HEAD)"
sub_commit "$CASE_WT"; u6_c3="$(git -C "$CASE_WT/libs/prod" rev-parse HEAD)"
u6_src="$(git -C "$CASE_WT/libs/prod" rev-parse --absolute-git-dir)"
git -C "$CASE_REPO/libs/prod" fetch -q "$u6_src" "$u6_c1:refs/heads/rd-archive/u6"
git -C "$CASE_REPO/libs/prod" fetch -q "$u6_src" "$u6_c2:refs/remotes/origin/u6-gone"   # 뒤처진 원격 추적 ref 로만 닿는다
git -C "$CASE_REPO/libs/prod" fetch -q "$u6_src" "$u6_c3"   # FETCH_HEAD 만 — 브랜치로 닿지 않는다
u6_rc=0; u6_out="$(_rd_unpushed_commits "$CASE_WT/libs/prod" libs/prod "$CASE_REPO/libs/prod" 2>/dev/null)" || u6_rc=$?
u6_want="$(printf '%s\n' "$u6_c2" "$u6_c3" | sort)"
if [[ "$u6_rc" == 0 && "$(sort <<<"$u6_out")" == "$u6_want" ]]; then
  pass "U6: 미push 목록 = 원격 추적 ref 로만 닿는 커밋과 객체만 있는 커밋(브랜치로 닿는 커밋은 뺌)"
else
  fail "U6: rc=$u6_rc 목록=[$u6_out] (기대: $u6_c2 $u6_c3)"
fi

echo "== U7: 미push 이력이 길어도(15000 커밋) 기본 체크아웃 대조가 목록을 잃지 않는다 =="
# 없으면 새는 실수: 목록을 환경 변수·인자로 넘기면 OS 인자 크기 상한(macOS ARG_MAX 1MB)을 넘어 awk·git 실행이 실패하고, 빈 출력이
#   「모두 보존됨」 으로 읽혀 긴 로컬 이력을 가진 worktree 를 지운다. 커밋은 fast-import 로 만든다(약 1초).
light_case u7
u7_sub="$CASE_WT/libs/prod"
u7_from="$(git -C "$u7_sub" rev-parse HEAD)"
awk -v n=15000 -v from="$u7_from" 'BEGIN { for (i = 1; i <= n; i++) {
    printf "commit refs/heads/u7-history\nmark :%d\ncommitter t <t@t> %d +0000\ndata 2\nc\n", i, 1700000000 + i
    if (i == 1) printf "from %s\n", from; else printf "from :%d\n", i - 1
    printf "\n" } }' | git -C "$u7_sub" fast-import --quiet
git -C "$CASE_REPO/libs/prod" fetch -q --no-tags "$(git -C "$u7_sub" rev-parse --absolute-git-dir)" refs/heads/u7-history
u7_rc=0; u7_out="$(_rd_unpushed_commits "$u7_sub" libs/prod "$CASE_REPO/libs/prod" 2>/dev/null)" || u7_rc=$?
u7_n="$(grep -c . <<<"$u7_out" || true)"
if [[ "$u7_rc" == 0 && "$u7_n" == 15000 ]]; then
  pass "U7: 미push 15000 커밋이 모두 목록에 남음"
else
  fail "U7: rc=$u7_rc 목록 수=$u7_n (기대 15000)"
fi

# ---- worktree 보존 판정 (spec 2.4 D15~D18): rd_worktree_remove_safe·rd_worktree_hold_info 를 직접 부른다 ----
# archive 는 worktree 정리에서 이 두 함수로 지울지 정하고 보존 사유를 낸다. archive 가 두 함수를 부르는 연결(보존·사유·복구
# 명령 출력)은 W3b 가 본다. 여기서는 상태별 판정과 사유만 본다(케이스마다 promote·archive 한 번씩을 아낀다).
# wt_hold — 기본 체크아웃에서 작업 worktree 정리를 시도한다. rc 는 HOLD_RC, 보존 사유 줄은 HOLD_INFO.
wt_hold() {
  local out
  HOLD_RC=0; out="$( cd "$CASE_REPO" && rd_worktree_remove_safe "$CASE_WT" )" || HOLD_RC=$?
  HOLD_INFO="$out"
  [[ "$HOLD_RC" != 1 ]] || HOLD_INFO="$(rd_worktree_hold_info "${out%%$'\t'*}" "${out#*$'\t'}" "$CASE_WT")"
}

echo "== W3c: submodule 커밋을 push 했지만 gitlink 는 올리지 않음 =="
light_case w3c
echo work > "$CASE_WT/work.txt"; git -C "$CASE_WT" add work.txt; git -C "$CASE_WT" commit -q -m "구현: work"
sub_commit "$CASE_WT"; sub_push "$CASE_WT"
wt_hold
if [[ "$HOLD_RC" == 1 && -d "$CASE_WT" && "$HOLD_INFO" == *"gitlink 로 올리지 않은 커밋"* ]]; then
  pass "W3c: worktree 보존, gitlink 미반영 사유"
else
  fail "W3c: rc=$HOLD_RC worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $HOLD_INFO"
fi

echo "== W3d: 중첩 submodule(libs/prod/vendor) 안 미추적 파일 — 모든 깊이 검사 =="
light_case w3d
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; record_gitlink "$CASE_WT"
echo scratch > "$CASE_WT/libs/prod/vendor/untracked.txt"
wt_hold
if [[ "$HOLD_RC" == 1 && -d "$CASE_WT" && "$HOLD_INFO" == *"미커밋 변경"*"submodule 경로: libs/prod/vendor"* ]]; then
  pass "W3d: worktree 보존, 중첩 submodule 경로의 미커밋 변경 사유"
else
  fail "W3d: rc=$HOLD_RC worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $HOLD_INFO"
fi

echo "== W3e: submodule 커밋·push 후 상위에서 gitlink 를 스테이징만 하고 커밋하지 않음 =="
light_case w3e
echo work > "$CASE_WT/work.txt"; git -C "$CASE_WT" add work.txt; git -C "$CASE_WT" commit -q -m "구현: work"
sub_commit "$CASE_WT"; sub_push "$CASE_WT"; git -C "$CASE_WT" add libs/prod
wt_hold
if [[ "$HOLD_RC" == 1 && -d "$CASE_WT" && "$HOLD_INFO" == *"미커밋 변경"* ]]; then
  pass "W3e: worktree 보존, 스테이징만 된 gitlink 를 미커밋 변경으로 안내"
else
  fail "W3e: rc=$HOLD_RC worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $HOLD_INFO"
fi

echo "== W3f: 기본 체크아웃 submodule 이 작업 worktree submodule 의 객체를 빌려 씀(alternates) — 그 브랜치를 보존 근거로 쓰지 않음 =="
# 없으면 새는 실수: 기본 체크아웃 submodule 이 objects/info/alternates 로 작업 worktree submodule 의 객체를 읽으면, 발행이 fetch
#   없이 그 커밋에 rd-archive 브랜치를 만들고 정리 판정이 그 브랜치를 근거로 worktree 를 지운다. 지운 뒤 브랜치가 가리키는 커밋을
#   읽을 수 없다(리뷰 F6). 발행이 만드는 브랜치는 update-ref 로 대신한다.
light_case w3f
sub_commit "$CASE_WT"; record_gitlink "$CASE_WT"
w3f_c="$(git -C "$CASE_WT/libs/prod" rev-parse HEAD)"
w3f_kg="$(git -C "$CASE_REPO/libs/prod" rev-parse --absolute-git-dir)"
mkdir -p "$w3f_kg/objects/info"
printf '%s\n' "$(git -C "$CASE_WT/libs/prod" rev-parse --absolute-git-dir)/objects" > "$w3f_kg/objects/info/alternates"
git -C "$CASE_REPO/libs/prod" update-ref refs/heads/rd-archive/w3f "$w3f_c"
wt_hold 2>"$TMP/w3f.err"
if [[ "$HOLD_RC" == 1 && -d "$CASE_WT" && "$HOLD_INFO" == *"원격에 없는 커밋"* ]] \
   && grep -q -F 'objects/info/alternates' "$TMP/w3f.err" \
   && git -C "$CASE_REPO/libs/prod" cat-file -e "${w3f_c}^{commit}" 2>/dev/null; then
  pass "W3f: worktree 보존, 원격에 없는 커밋 사유, alternates 안내 줄, 기본 쪽 브랜치 커밋을 읽을 수 있음"
else
  fail "W3f: rc=$HOLD_RC worktree=$([[ -d "$CASE_WT" ]] && echo 있음 || echo 없음) — $HOLD_INFO / stderr=[$(cat "$TMP/w3f.err")]"
fi


# ---- gitlink 조상·자손 자동 해소와 반영 대상 기준점 (change spec 2026-11-18-0900 D1-4·D1-5·D3-2·D3-3) ----
# _merge_precheck.sh source 와 arch_fns 는 G 구간 앞에 있다(G2h·G4·G4b 가 병합 전 검사를 직접 부른다).
ARCH_FN_LIST="archive_merge_commit_check archive_gitlink_auto_resolve _archive_gl_print_notes _archive_gl_note _archive_gl_acquire _archive_gl_fetch"
# arch_mcc <repo> <M> — archive_merge_commit_check 를 직접 부른다. 출력 MCC_OUT, rc MCC_RC.
arch_mcc() {
  MCC_RC=0
  MCC_OUT="$( cd "$1" && eval "$(arch_fns $ARCH_FN_LIST)" && archive_merge_commit_check "$2" 2>&1 )" || MCC_RC=$?
}
# gl_set_sub <wt> <oid> — 작업 worktree(또는 기본 체크아웃)의 libs/prod 를 oid 로 체크아웃하고 gitlink 를 커밋한다.
gl_set_sub() {
  git -C "$1/libs/prod" cat-file -e "${2}^{commit}" 2>/dev/null || git -C "$1/libs/prod" fetch -q origin "+refs/heads/*:refs/remotes/origin/*"
  git -C "$1/libs/prod" checkout -q --detach "$2"
  git -C "$1" add libs/prod; git -C "$1" commit -q -m "gitlink: ${2:0:7}"
}
# sp_ci <dir> <이름> — submodule 저장소에 파일 하나를 더한 커밋을 만들고 OID 를 낸다.
sp_ci() { echo "$2-$RANDOM" > "$1/$2.txt"; git -C "$1" add "$2.txt"; git -C "$1" commit -q -m "$2"; git -C "$1" rev-parse HEAD; }
# conflict_stop — 종전 충돌 안내로 멈췄는가: 사전 판정 안내(「코드 충돌이 있습니다」 + 목록 `- libs/prod`) 또는
#   병합 단계의 「merge 실패 — conflict resolve 후 재실행」 + git 원래 출력의 libs/prod.
conflict_stop() {
  { out_has "코드 충돌이 있습니다" && out_has "- libs/prod"; } \
    || { out_has "merge 실패 — conflict resolve 후 재실행" && out_has "libs/prod"; }
}
# resume_cmd <출력> — 재실행 안내 줄(성공형 또는 (다))에서 checkout 명령을 뽑는다.
resume_cmd() { printf '%s\n' "$1" | sed -n 's/^archive:  .*발행이 중간에 멈춰 다시 실행해야 하면: .* 확인한 뒤 //p; s/^archive:     (다) .* 확인한 뒤 //p' | head -1; }

echo "== AC2 (가): 자손 커밋이 작업 worktree submodule 에만 있음 — 자손으로 병합, push 거부 뒤 안내대로 재실행 =="
# 없으면 새는 실수: 병합 분기가 gitlink 를 풀지 않음, 재실행 절차가 없어 Step 0 에 막힘, 객체 확보 누락.
prep_case ga2
git -C "$CASE_REPO/libs/prod" config user.email t@t; git -C "$CASE_REPO/libs/prod" config user.name t
GA_A="$(sp_ci "$CASE_REPO/libs/prod" a)"; git -C "$CASE_REPO/libs/prod" push -q origin "HEAD:refs/heads/ga2-a"
git -C "$CASE_REPO" add libs/prod; git -C "$CASE_REPO" commit -q -m "main: gitlink A"
git -C "$CASE_WT/libs/prod" fetch -q origin ga2-a; git -C "$CASE_WT/libs/prod" checkout -q --detach "$GA_A"
GA_B="$(sp_ci "$CASE_WT/libs/prod" b)"; record_gitlink "$CASE_WT"
git -C "$CASE_REPO/libs/prod" cat-file -e "${GA_B}^{commit}" 2>/dev/null && { echo "준비 실패: ga2 의 B 가 기본 체크아웃 submodule 에 있음" >&2; exit 1; }
printf '#!/bin/sh\n[ -e "%s" ] && { echo "pre-receive: 표식이 있어 거부" >&2; exit 1; }\nexit 0\n' "$TMP/ga2/block" > "$TMP/ga2/overlay.git/hooks/pre-receive"
chmod +x "$TMP/ga2/overlay.git/hooks/pre-receive"; : > "$TMP/ga2/block"
run_gl_repo
ok_if "AC2(가): 첫 실행 rc≠0 (push 거부)" test "$ARCH_RC" -ne 0
ok_if "AC2(가): 해소 줄(경로·7자리)" out_has "archive: submodule libs/prod 충돌을 자손 커밋 ${GA_B:0:7} 로 해결했습니다"
ok_if "AC2(가): 기본 브랜치 libs/prod = B" eq "$(git -C "$CASE_REPO" rev-parse main:libs/prod)" "$GA_B"
ok_if "AC2(가): 객체 확보 성공 — 복구 절차가 아닌 재실행 안내 줄" out_lacks "fetch origin refs/heads/rd-archive/"
ga2_cmd="$(resume_cmd "$ARCH_OUT")"
ok_if "AC2(가): 재실행 안내 줄에서 checkout 명령을 뽑음" test -n "$ga2_cmd"
ga2_rc=0; ( eval "$ga2_cmd" ) >/dev/null 2>&1 || ga2_rc=$?
rm -f "$TMP/ga2/block"
ok_if "AC2(가): 뽑은 명령 실행 rc 0, 상위 status 깨끗" eq "$ga2_rc/$(git -C "$CASE_REPO" status --porcelain)" "0/"
run_gl_repo
ok_if "AC2 재실행: rc 0" test "$ARCH_RC" -eq 0
ok_if "AC2 재실행: 손 병합 거부 없음" out_lacks "리뷰하지 않은 변경"
ok_if "AC2 재실행: 원격 main libs/prod = B" eq "$(remote_gitlink)" "$GA_B"

echo "== AC2 (나): 기준 gitlink 가 옆 가지 — 객체가 있어도 git 이 거부하는 경우를 자손으로 병합, 재실행 검사 예외 =="
gb2_pre() {
  local s="$CASE_REPO/libs/prod" p0
  git -C "$s" config user.email t@t; git -C "$s" config user.name t
  p0="$(git -C "$s" rev-parse HEAD)"
  GB_X="$(sp_ci "$s" x)"; git -C "$s" push -q origin "HEAD:refs/heads/gb2-side"
  git -C "$s" checkout -q --detach "$p0"
  GB_S="$(sp_ci "$s" s)"; GB_A="$(sp_ci "$s" a)"; GB_B="$(sp_ci "$s" b)"
  git -C "$s" push -q origin "$GB_S:refs/heads/gb2-team" "$GB_A:refs/heads/gb2-a" "$GB_B:refs/heads/gb2-b"
  git -C "$s" checkout -q --detach "$GB_X"
  git -C "$CASE_REPO" add libs/prod; git -C "$CASE_REPO" commit -q -m "기준: libs/prod = 옆 가지 X"
}
CASE_PRE=gb2_pre prep_case gb2
gl_set_sub "$CASE_REPO" "$GB_A"
gl_set_sub "$CASE_WT" "$GB_B"; record_gitlink "$CASE_WT"
gb2_mt="$(git -C "$CASE_REPO" merge-tree --write-tree --name-only --no-messages main fr/gb2 2>/dev/null | sed 1d)" || true
[[ "$gb2_mt" == libs/prod ]] || { echo "준비 실패: gb2 merge-tree 충돌=[$gb2_mt]" >&2; exit 1; }
gb2_tip="$(git -C "$CASE_REPO" rev-parse fr/gb2)"
run_gl_repo
ok_if "AC2(나): rc 0" test "$ARCH_RC" -eq 0
ok_if "AC2(나): 해소 줄(경로·7자리)" out_has "archive: submodule libs/prod 충돌을 자손 커밋 ${GB_B:0:7} 로 해결했습니다"
ok_if "AC2(나): 기본 브랜치 libs/prod = B" eq "$(git -C "$CASE_REPO" rev-parse main:libs/prod)" "$GB_B"
gb2_m="$(git -C "$CASE_REPO" rev-list --first-parent --merges --parents main | awk -v t="$gb2_tip" '$3 == t {print $1; exit}')"
arch_mcc "$CASE_REPO" "$gb2_m"
ok_if "AC2(나) D1-5: 재실행 검사 archive_merge_commit_check M → rc 0 (M=${gb2_m:0:7})" eq "$MCC_RC/$MCC_OUT" "0/"

# mk_plain_sub_repo <dir> — 상위 저장소(main)와 그 .git/modules/libs/prod 에 bare 객체 저장소를 둔다(작업 트리 경로는 초기화하지 않음).
#   전역: PR_DIR
mk_plain_sub_repo() {
  PR_DIR="$1"; git init -q -b main "$PR_DIR"
  echo r > "$PR_DIR/r.txt"; git -C "$PR_DIR" add r.txt; git -C "$PR_DIR" commit -q -m root
  mkdir -p "$PR_DIR/.git/modules/libs"; git init -q --bare "$PR_DIR/.git/modules/libs/prod"
  git init -q -b main "$PR_DIR.src"
}
# plain_ci <이름> — 객체 저장소용 커밋을 만들어 bare 에 push 하고 OID 를 낸다.
plain_ci() { local o; o="$(sp_ci "$PR_DIR.src" "$1")"; git -C "$PR_DIR.src" push -q "$PR_DIR/.git/modules/libs/prod" "HEAD:refs/heads/$1"; printf '%s\n' "$o"; }
# plain_gl <oid> <메시지> — 상위 저장소에 libs/prod gitlink 를 oid 로 커밋한다.
plain_gl() { git -C "$PR_DIR" update-index --add --cacheinfo "160000,$1,libs/prod"; git -C "$PR_DIR" commit -q -m "$2"; }

echo "== AC2 (마): 기준의 일반 파일을 두 줄기가 gitlink 로 바꿈 — stage 1 blob 을 기준으로 넘기지 않음, 미초기화 대상 보호 =="
mk_plain_sub_repo "$TMP/f15/r"
f15_A="$(plain_ci a)"; f15_B="$(plain_ci b)"
mkdir -p "$PR_DIR/libs"; echo file > "$PR_DIR/libs/prod"; git -C "$PR_DIR" add libs/prod; git -C "$PR_DIR" commit -q -m "기준: 일반 파일"
git -C "$PR_DIR" checkout -q -b fr; git -C "$PR_DIR" rm -q --cached libs/prod; rm -f "$PR_DIR/libs/prod"; plain_gl "$f15_B" "fr: gitlink B"
git -C "$PR_DIR" checkout -q main; git -C "$PR_DIR" rm -q --cached libs/prod; rm -f "$PR_DIR/libs/prod"; plain_gl "$f15_A" "main: gitlink A"
mkdir -p "$PR_DIR/libs/prod"
git -C "$PR_DIR" merge -q --no-commit --no-ff fr >/dev/null 2>&1 || true
f15_u="$(git -C "$PR_DIR" ls-files -u | awk '{print $1 ":" $3}' | tr '\n' ' ')"
[[ "$f15_u" == "100644:1 160000:2 160000:3 " ]] || { echo "준비 실패: f15 미병합 stage=[$f15_u]" >&2; exit 1; }
f15_fh0="$(cat "$PR_DIR/.git/FETCH_HEAD" 2>/dev/null || echo 없음)"
f15_rc=0
f15_out="$( cd "$PR_DIR" && eval "$(arch_fns $ARCH_FN_LIST)" && CURRENT_WT="$PR_DIR" SLUG=f15 && archive_gitlink_auto_resolve fr 2>&1 && _archive_gl_print_notes 2>&1 )" || f15_rc=$?
ok_if "AC2(마): archive_gitlink_auto_resolve rc 0" eq "$f15_rc" 0
ok_if "AC2(마): 인덱스 libs/prod = B" eq "$(git -C "$PR_DIR" ls-files -s libs/prod | awk '{print $1 " " $2 " " $3}')" "160000 $f15_B 0"
ok_if "AC2(마): 상위 저장소에 B 객체가 생기지 않음" bash -c '! git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null' _ "$PR_DIR" "$f15_B"
ok_if "AC2(마): 상위 FETCH_HEAD 불변" eq "$(cat "$PR_DIR/.git/FETCH_HEAD" 2>/dev/null || echo 없음)" "$f15_fh0"
ok_if "AC2(마): 미초기화 대상에는 재실행 안내 없음 [$f15_out]" bash -c '[[ "$1" != *"다시 실행해야 하면"* ]]' _ "$f15_out"
git -C "$PR_DIR" commit -q --no-edit
arch_mcc "$PR_DIR" HEAD
ok_if "AC2(마) D1-5: 재실행 검사 rc 0" eq "$MCC_RC/$MCC_OUT" "0/"

echo "== AC8: 충돌 없이 merge-tree 가 조상 A 를 고른 경로를 손 병합이 자손 B 로 바꾸면 차이로 낸다 =="
mk_plain_sub_repo "$TMP/ac8/r"
ac8_A="$(plain_ci a)"; ac8_B="$(plain_ci b)"
plain_gl "$ac8_B" "기준: B"
git -C "$PR_DIR" checkout -q -b fr; plain_gl "$ac8_A" "fr: A 로 되돌림(리뷰함)"
git -C "$PR_DIR" checkout -q main; echo m > "$PR_DIR/m.txt"; git -C "$PR_DIR" add m.txt; git -C "$PR_DIR" commit -q -m "main: 무관한 파일"
git -C "$PR_DIR" merge -q --no-commit --no-ff fr >/dev/null 2>&1 || { echo "준비 실패: ac8 병합" >&2; exit 1; }
git -C "$PR_DIR" update-index --cacheinfo "160000,$ac8_B,libs/prod"; git -C "$PR_DIR" commit -q --no-edit
arch_mcc "$PR_DIR" HEAD
ok_if "AC8: rc 1, 출력 libs/prod" eq "$MCC_RC/$MCC_OUT" "1/libs/prod"
echo "== AC8b: 교차 병합 — 병합 기준 하나(X1)는 A, 가상 기준은 B 일 때 충돌 없이 merge-tree 가 고른 롤백 A 를 손 병합이 B 로 바꾸면 차이로 낸다 =="
# 없으면 새는 실수: D1-5 예외를 충돌 경로가 아닌 gitlink 경로에도 걸고 기준을 git merge-base 첫 값(X1, A)으로 잡으면
#   롤백 판정이 빠져 손 병합 B 를 통과시킨다. AC8 은 기준이 B 라 롤백 판정이 대신 막아 이 실수를 보지 못한다.
mk_plain_sub_repo "$TMP/ac8b/r"
ac8b_A="$(plain_ci a)"; ac8b_B="$(plain_ci b)"; ac8b_t="$(date +%s)"
# ac8b_git <초> <git 인자...> — 커미터 시각을 고정한다(X1 을 X2 보다 뒤로 두어 병합 기준 순서를 정함).
ac8b_git() { local s="$1"; shift; GIT_COMMITTER_DATE="@$((ac8b_t + s)) +0000" GIT_AUTHOR_DATE="@$((ac8b_t + s)) +0000" git -C "$PR_DIR" "$@"; }
git -C "$PR_DIR" update-index --add --cacheinfo "160000,$ac8b_A,libs/prod"; ac8b_git 1 commit -q -m "O: A"
git -C "$PR_DIR" checkout -q -b x2; git -C "$PR_DIR" update-index --cacheinfo "160000,$ac8b_B,libs/prod"; ac8b_git 2 commit -q -m "X2: B"
git -C "$PR_DIR" checkout -q -b x1 main; echo x > "$PR_DIR/x1.txt"; git -C "$PR_DIR" add x1.txt; ac8b_git 3 commit -q -m "X1: 무관한 파일"
git -C "$PR_DIR" checkout -q -b fr x2; ac8b_git 4 merge -q --no-ff --no-edit x1
git -C "$PR_DIR" update-index --cacheinfo "160000,$ac8b_A,libs/prod"; ac8b_git 5 commit -q -m "fr: A 로 되돌림(리뷰함)"
git -C "$PR_DIR" checkout -q x1; ac8b_git 6 merge -q --no-ff --no-edit x2
ac8b_n="$(git -C "$PR_DIR" merge-base --all x1 fr | grep -c .)"
ac8b_t2="$(git -C "$PR_DIR" merge-tree --write-tree --name-only --no-messages x1 fr)" || { echo "준비 실패: ac8b merge-tree 충돌" >&2; exit 1; }
[[ "$ac8b_n" -eq 2 && "$(git -C "$PR_DIR" ls-tree "$ac8b_t2" libs/prod | awk '{print $3}')" == "$ac8b_A" ]] || { echo "준비 실패: ac8b 병합 기준 ${ac8b_n}개" >&2; exit 1; }
ac8b_git 7 merge -q --no-commit --no-ff fr >/dev/null 2>&1 || { echo "준비 실패: ac8b 병합" >&2; exit 1; }
git -C "$PR_DIR" update-index --cacheinfo "160000,$ac8b_B,libs/prod"; ac8b_git 7 commit -q --no-edit
arch_mcc "$PR_DIR" HEAD
ok_if "AC8b: 교차 병합에서 rc 1, 출력 libs/prod" eq "$MCC_RC/$MCC_OUT" "1/libs/prod"

echo "== AC2 (바): 로컬 전송이 막힌 대상 — 원인·정책 안내와 (가)(나)(다) 복구 절차, 안내대로 실행하면 대상에 B =="
# 대상의 origin 은 submodule 기준 상대 URL 이다 — (가) push 가 (나) fetch 와 같은 기준(submodule 디렉터리)으로 원격을 풀어야
# 테스트 셸의 현재 폴더와 무관하게 안내대로 실행된다.
prep_case gf6
git -C "$CASE_REPO/libs/prod" config user.email t@t; git -C "$CASE_REPO/libs/prod" config user.name t
GF_A="$(sp_ci "$CASE_REPO/libs/prod" a)"; git -C "$CASE_REPO/libs/prod" push -q origin "HEAD:refs/heads/gf6-a"
git -C "$CASE_REPO" add libs/prod; git -C "$CASE_REPO" commit -q -m "main: gitlink A"
git -C "$CASE_WT/libs/prod" fetch -q origin gf6-a; git -C "$CASE_WT/libs/prod" checkout -q --detach "$GF_A"
GF_B="$(sp_ci "$CASE_WT/libs/prod" b)"; record_gitlink "$CASE_WT"
git init -q --bare "$TMP/gf6/fork.git"; git -C "$CASE_WT/libs/prod" remote set-url origin "$TMP/gf6/fork.git"
git clone -q --bare "$TEMPLATE_DIR/prod.git" "$TMP/gf6/team remote.git"
gf_t="$CASE_REPO/libs/prod"
git -C "$gf_t" remote set-url origin "../../../team remote.git"
[[ "$(cd "$gf_t" && cd "../../../team remote.git" && pwd -P)" == "$(cd "$TMP/gf6/team remote.git" && pwd -P)" ]] || { echo "준비 실패: gf6 상대 origin" >&2; exit 1; }
git -C "$gf_t" config protocol.file.allow never
git -C "$gf_t" config --replace-all remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
git -C "$CASE_REPO" merge -q --no-ff --no-commit fr/gf6 >/dev/null 2>&1 || true
[[ "$(git -C "$CASE_REPO" diff --name-only --diff-filter=U)" == libs/prod ]] || { echo "준비 실패: gf6 충돌 경로" >&2; exit 1; }
gf_rc=0
( unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  [[ "$(git -C "$gf_t" config --get protocol.file.allow)" == never ]] || { echo "준비 실패: gf6 protocol.file.allow" >&2; exit 9; }
  cd "$CASE_REPO" && eval "$(arch_fns $ARCH_FN_LIST)" && CURRENT_WT="$CASE_REPO" && SLUG=gf6
  r=0; archive_gitlink_auto_resolve fr/gf6 >"$TMP/gf6/out" 2>"$TMP/gf6/err" || r=$?
  printf '%s' "$ARCHIVE_GL_RESUME_NOTES" > "$TMP/gf6/notes"; exit "$r" ) || gf_rc=$?
[[ "$gf_rc" != 9 ]] || exit 1
gf_err="$(cat "$TMP/gf6/err")"; gf_notes="$(cat "$TMP/gf6/notes")"
ARCH_OUT="err=[$gf_err] notes=[$gf_notes]"; ARCH_RC="$gf_rc"
ok_if "AC2(바): rc 0, 인덱스 libs/prod = B" eq "$gf_rc/$(git -C "$CASE_REPO" ls-files -s libs/prod | awk '{print $2}')" "0/$GF_B"
ok_if "AC2(바): 원인 줄(transport 'file' not allowed)" bash -c 'grep -q "받지 못했습니다 — .*transport '"'"'file'"'"' not allowed" <<<"$1"' _ "$gf_err"
ok_if "AC2(바): 전송 정책 안내 줄" bash -c 'grep -qF "이 저장소가 file 전송을 막고 있습니다" <<<"$1"' _ "$gf_err"
ok_if "AC2(바): (가) push 줄" bash -c 'grep -q "^archive:     (가) git -C .* --git-dir=.* push --no-follow-tags " <<<"$1"' _ "$gf_notes"
ok_if "AC2(바): (나) fetch origin refs/heads/rd-archive/" bash -c 'grep -q "^archive:     (나) git -C .* fetch origin refs/heads/rd-archive/gf6-" <<<"$1"' _ "$gf_notes"
ok_if "AC2(바): (다) checkout" bash -c 'grep -q "^archive:     (다) .* checkout --detach " <<<"$1"' _ "$gf_notes"
ok_if "AC2(바): 로컬 fetch 재안내 없음" bash -c '! grep -q "fetch .*worktrees/gf6/modules" <<<"$1"' _ "$gf_notes"
ok_if "AC2(바): 대상에 B 없음 그대로" bash -c '! env -u GIT_ALTERNATE_OBJECT_DIRECTORIES git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null' _ "$gf_t" "$GF_B"
git -C "$gf_t" config --unset protocol.file.allow
gf_run=0
( unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  c1="$(printf '%s\n' "$gf_notes" | sed -n 's/^archive:     (가) //p')"
  c2="$(printf '%s\n' "$gf_notes" | sed -n 's/^archive:     (나) //p')"
  c3="$(resume_cmd "$gf_notes")"
  eval "$c1" && eval "$c2" && eval "$c3" ) >"$TMP/gf6/run.log" 2>&1 || gf_run=$?
ARCH_OUT="$(cat "$TMP/gf6/run.log")"
ok_if "AC2(바): (가)(나)(다) 실행 rc 0" eq "$gf_run" 0
ok_if "AC2(바): 실행 뒤 대상 체크아웃 = B" eq "$(git -C "$gf_t" rev-parse HEAD 2>/dev/null)" "$GF_B"

# rb_pre — 기준점 커밋의 libs/prod 를 seed 의 자손 X 로 둔다(AC2c 롤백 fixture). 전역 RB_P0 RB_X RB_B
rb_pre() {
  local s="$CASE_REPO/libs/prod"
  git -C "$s" config user.email t@t; git -C "$s" config user.name t
  RB_P0="$(git -C "$s" rev-parse HEAD)"; RB_X="$(sp_ci "$s" x)"; RB_B="$(sp_ci "$s" b)"
  git -C "$s" push -q origin "$RB_X:refs/heads/${CASE_NAME}-x" "$RB_B:refs/heads/${CASE_NAME}-b"
  git -C "$s" checkout -q --detach "$RB_X"
  git -C "$CASE_REPO" add libs/prod; git -C "$CASE_REPO" commit -q -m "기준: libs/prod = X"
}
echo "== AC2c: 롤백 충돌(기준 X, main B, fr A=X 의 조상) — archive 는 기본 브랜치를 바꾸지 않고 충돌 안내로 멈춘다 =="
CASE_PRE=rb_pre prep_case rb2
gl_set_sub "$CASE_REPO" "$RB_B"
gl_set_sub "$CASE_WT" "$RB_P0"; record_gitlink "$CASE_WT"
rb_head="$(gl_head)"
run_gl_repo
ok_if "AC2c: rc≠0" test "$ARCH_RC" -ne 0
ok_if "AC2c: 기본 브랜치 HEAD 불변" eq "$(gl_head)" "$rb_head"
ok_if "AC2c: libs/prod 충돌 안내" conflict_stop
echo "== AC2c 재실행 검사: 롤백 상태를 손 병합으로 B 로 덮은 M — 차이로 낸다 =="
git -C "$CASE_REPO" merge -q --no-ff --no-commit fr/rb2 >/dev/null 2>&1 || true
git -C "$CASE_REPO" update-index --cacheinfo "160000,$RB_B,libs/prod"; git -C "$CASE_REPO" commit -q --no-edit
arch_mcc "$CASE_REPO" HEAD
ok_if "AC2c 재실행 검사: rc 1, 출력 libs/prod" eq "$MCC_RC/$MCC_OUT" "1/libs/prod"

echo "== AC2e: 교차 병합(병합 기준 둘) — 조상·자손이라도 자동 해소하지 않는다 =="
prep_case cx2
git -C "$CASE_REPO/libs/prod" config user.email t@t; git -C "$CASE_REPO/libs/prod" config user.name t
echo p > "$CASE_REPO/p.txt"; git -C "$CASE_REPO" add p.txt; git -C "$CASE_REPO" commit -q -m "main: P"
echo q > "$CASE_WT/q.txt"; git -C "$CASE_WT" add q.txt; git -C "$CASE_WT" commit -q -m "fr: Q"
cx_p="$(git -C "$CASE_REPO" rev-parse main)"; cx_q="$(git -C "$CASE_WT" rev-parse HEAD)"
git -C "$CASE_REPO" merge -q --no-ff --no-edit "$cx_q" >/dev/null
git -C "$CASE_WT" merge -q --no-ff --no-edit "$cx_p" >/dev/null
CX_A="$(sp_ci "$CASE_REPO/libs/prod" a)"; git -C "$CASE_REPO/libs/prod" push -q origin "HEAD:refs/heads/cx2-a"
git -C "$CASE_REPO" add libs/prod; git -C "$CASE_REPO" commit -q -m "main: gitlink A"
git -C "$CASE_WT/libs/prod" fetch -q origin cx2-a; git -C "$CASE_WT/libs/prod" checkout -q --detach "$CX_A"
CX_B="$(sp_ci "$CASE_WT/libs/prod" b)"; git -C "$CASE_WT/libs/prod" push -q origin "HEAD:refs/heads/cx2-b"
# B 는 기본 체크아웃 submodule 에 받지 않는다 — 받아 두면 git 이 가상 병합 기준으로 조상·자손을 풀어 충돌이 나지 않는다.
record_gitlink "$CASE_WT"
cx_n="$(git -C "$CASE_REPO" merge-base --all main fr/cx2 | grep -c .)"
cx_mt="$(git -C "$CASE_REPO" merge-tree --write-tree --name-only --no-messages main fr/cx2 2>/dev/null | sed 1d)" || true
[[ "$cx_n" -eq 2 && "$cx_mt" == libs/prod ]] || { echo "준비 실패: cx2 merge-base ${cx_n}개, 충돌=[$cx_mt]" >&2; exit 1; }
cx_head="$(gl_head)"
run_gl_repo
ok_if "AC2e: rc≠0" test "$ARCH_RC" -ne 0
ok_if "AC2e: 기본 브랜치 HEAD 불변" eq "$(gl_head)" "$cx_head"
ok_if "AC2e: libs/prod 충돌 안내" conflict_stop
git -C "$CASE_REPO" merge -q --no-ff --no-commit fr/cx2 >/dev/null 2>&1 || true
git -C "$CASE_REPO" update-index --cacheinfo "160000,$CX_B,libs/prod"; git -C "$CASE_REPO" commit -q --no-edit
arch_mcc "$CASE_REPO" HEAD
ok_if "AC2e 재실행 검사: 교차 병합 M → rc 1, 출력 libs/prod" eq "$MCC_RC/$MCC_OUT" "1/libs/prod"

echo "== AC2d: 진행 중인 병합이 있으면 clean 검사보다 먼저 알리고 그 상태를 바꾸지 않는다 =="
prep_case md2
record_gitlink "$CASE_WT"
git -C "$CASE_REPO" merge -q --no-ff --no-commit fr/md2 >/dev/null 2>&1 || true
md_snap() { printf '%s|%s|%s' "$(git -C "$CASE_REPO" rev-parse -q --verify MERGE_HEAD)" "$(git -C "$CASE_REPO" write-tree)" "$(git -C "$CASE_REPO" rev-parse HEAD)"; }
md_before="$(md_snap)"
[[ "$md_before" == "$(git -C "$CASE_REPO" rev-parse fr/md2)|"* ]] || { echo "준비 실패: md2 MERGE_HEAD" >&2; exit 1; }
run_gl_repo
ok_if "AC2d: rc≠0" test "$ARCH_RC" -ne 0
ok_if "AC2d: 진행 중인 병합 안내" out_has "진행 중인 병합이 있습니다"
ok_if "AC2d: clean 검사 안내가 앞서지 않음" out_lacks "worktree dirty"
ok_if "AC2d: MERGE_HEAD·인덱스 트리·HEAD 불변" eq "$(md_snap)" "$md_before"

echo "== AC2b: --force-dirty 아래 병합이 시작되지 않은 실패 — 병합 커밋을 만들지 않고 git 원인과 함께 멈춘다 =="
prep_case fd2
record_gitlink "$CASE_WT"
echo different > "$CASE_REPO/work.txt"; git -C "$CASE_REPO" add work.txt
fd_before="$(git -C "$CASE_REPO" rev-parse HEAD)|$(git -C "$CASE_REPO" write-tree)"
ARCH_RC=0
ARCH_OUT="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --task fd2 --force-dirty \
  --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || ARCH_RC=$?
ok_if "AC2b: rc≠0" test "$ARCH_RC" -ne 0
ok_if "AC2b: git 의 원래 실패 줄(work.txt)" out_has "work.txt"
ok_if "AC2b: MERGE_HEAD 없음" bash -c '! git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null' _ "$CASE_REPO"
ok_if "AC2b: HEAD·인덱스 트리 불변(새 커밋 없음)" eq "$(git -C "$CASE_REPO" rev-parse HEAD)|$(git -C "$CASE_REPO" write-tree)" "$fd_before"

# ---- no-fr 팀 저장소 반영 게이트 (spec D3-2·D3-5, AC6·AC6b·AC11) ----
# nofr_case <name> <workflow.json|nosub> [session] — 템플릿을 복사하고(promote 없음) 기본 브랜치에서 no-fr 작업을 커밋한다.
#   두 번째 인자: workflow.json 내용. 세 번째 인자 nosub 이면 libs/prod 를 지우는 작업, 아니면 팀 원격에 없는 커밋으로 gitlink 를 올린다.
#   네 번째 인자 session 이면 review-session 과 tip 의 seal 마커·SESSION.md(review-base-oid = 작업 전 HEAD)를 둔다.
nofr_case() {
  local n="$1" cfg="$2" kind="${3:-}" ses="${4:-}" base sid="$1-review-001"
  copy_case "$n"
  base="$(git -C "$CASE_REPO" rev-parse HEAD)"
  printf '%s\n' "$cfg" > "$CASE_REPO/rd-workflow/config/workflow.json"
  printf 'schema=1\nshort-title=%s\nstatus=아카이브 보류\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=%s\n' \
    "$n" "$([[ "$ses" == session ]] && echo "$sid" || echo null)" > "$CASE_REPO/rd-workflow-workspace/.lifecycle/task-state"
  if [[ "$ses" == session ]]; then
    mkdir -p "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-seals" "$CASE_REPO/rd-workflow-workspace/handoffs/review_pipeline/$sid"
    printf 'schema=1\nsession-id=%s\nreview-type=diff-review\nbranch-mode=no-fr\nfr-branch=null\n' "$sid" > "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-seals/$sid.seal"
    printf '# Session\n\n- review-base-oid: %s\n' "$base" > "$CASE_REPO/rd-workflow-workspace/handoffs/review_pipeline/$sid/SESSION.md"
  fi
  if [[ "$kind" == nosub ]]; then
    git -C "$CASE_REPO" rm -q -f libs/prod
  else
    git -C "$CASE_REPO/libs/prod" config user.email t@t; git -C "$CASE_REPO/libs/prod" config user.name t
    sp_ci "$CASE_REPO/libs/prod" w >/dev/null; git -C "$CASE_REPO/libs/prod" push -q origin "HEAD:refs/heads/$n"
  fi
  echo work > "$CASE_REPO/work.txt"; git -C "$CASE_REPO" add -A; git -C "$CASE_REPO" commit -q -m "구현: no-fr"
}
run_nofr() {  # 기본 체크아웃에서 no-fr archive (seal·Status 게이트는 우회). 추가 인자는 그대로 넘긴다.
  ARCH_RC=0
  ARCH_OUT="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
    --force-skip-review-check 테스트 --allow-status-mismatch 테스트 "$@" 2>&1 )" || ARCH_RC=$?
}
PUSH_CFG='{"team_publish": {"mode": "push"}}'

echo "== AC6b (가): 기준점 없는 no-fr, submodule 없음 — 게이트 통과·발행 =="
nofr_case nb1 "$PUSH_CFG" nosub
run_nofr
ok_if "AC6b(가): rc 0" test "$ARCH_RC" -eq 0
echo "== AC6b (나): 기준점 없는 no-fr, libs/prod 반영 방식 manual — 게이트 통과·발행 =="
nofr_case nb2 '{"team_publish": {"mode": "push", "submodules": {"libs/prod": {"mode": "manual"}}}}'
run_nofr
ok_if "AC6b(나): rc 0" test "$ARCH_RC" -eq 0
echo "== AC6b (다): 기준점 없는 no-fr, libs/prod 반영 방식 push — 거부·복구 안내, 기본 브랜치 불변 =="
nofr_case nb3 "$PUSH_CFG"
nb3_head="$(gl_head)"
run_nofr
ok_if "AC6b(다): rc 1" test "$ARCH_RC" -eq 1
ok_if "AC6b(다): 기본 브랜치 불변" eq "$(gl_head)" "$nb3_head"
ok_if "AC6b(다): rd task set-base 안내" out_has "bash rd-workflow/scripts/rd task set-base"
ok_if "AC6b(다): --allow-unpublished-submodule 안내" out_has '--allow-unpublished-submodule "<사유>"'
echo "== AC6b (라): 같은 상태에 --allow-unpublished-submodule \"사유\" — audit 기록 뒤 발행 =="
run_nofr --allow-unpublished-submodule 기준점없음_확인
ok_if "AC6b(라): rc 0" test "$ARCH_RC" -eq 0
ok_if "AC6b(라): audit 에 [team-publish] 사유" grep -qF "[team-publish] 기준점없음_확인" "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log"

echo "== AC6: no-fr 발행에서 팀 저장소에 없는 포인터를 막고 no-fr 문구로 안내한다 =="
nofr_case nf6 "$PUSH_CFG" "" session
nf6_head="$(gl_head)"
run_nofr
ok_if "AC6: rc≠0, 기본 브랜치 불변" eq "$([[ "$ARCH_RC" != 0 ]] && echo x)|$(gl_head)" "x|$nf6_head"
ok_if "AC6: 반영되지 않은 포인터 거부" out_has "팀 저장소에 반영되지 않은 submodule 포인터"
ok_if "AC6: no-fr 문구" out_has "이번 작업(기본 브랜치)에서 설정을 바꾸려면"
ok_if "AC6: fr 문구 없음" out_lacks "이번 fr 브랜치에서"

# ac11_run <name> — AC6 fixture 의 libs/prod 원격 조회를 늦추고 RD_MERGE_FETCH_TIMEOUT=1 로 archive 를 백그라운드에서 돌린다.
#   원격 조회가 시작되면(표식) 그 순간 출력에 시작 줄이 있는지 AC11_EARLY 에 남긴다.
#   늦춘 원격은 지연(sleep 60)을 마치면 완료 표식을 남긴다. archive 가 돌아온 순간 그 표식이 있으면 상한이 듣지 않고
#   원격을 끝까지 기다린 것이므로 AC11_LATE=1 이다. 경과 시간(AC11_EL)은 표시용이다 — archive 의 원격 조회 밖 단계도
#   들어가 부하에서 늘어나므로 판정에 쓰지 않는다. 전역 ARCH_OUT ARCH_RC AC11_EL AC11_EARLY AC11_LATE
ac11_run() {
  local n="$1" want="$2" mark="$TMP/$1/upload-started" done_mark="$TMP/$1/upload-delay-done" outf="$TMP/$1/arch.out" rcf="$TMP/$1/arch.rc" t0 i=0 pid
  # `sleep 60 && echo` — 상한이 sleep 만 끊었을 때 셸이 다음 명령을 실행해 완료 표식을 남기지 않게 한다.
  git -C "$CASE_REPO/libs/prod" config remote.origin.uploadpack "echo x > '$mark'; sleep 60 && echo x > '$done_mark'; git-upload-pack"
  t0=$SECONDS
  # 백그라운드 서브셸은 스위트의 EXIT·ERR trap 과 set -e 를 물려받는다 — 풀어 두어야 archive 실패 뒤에도 rc 를 남긴다.
  ( trap - EXIT ERR; set +e; cd "$CASE_REPO" || exit 1
    RD_MERGE_FETCH_TIMEOUT=1 bash rd-workflow/scripts/lifecycle/archive.sh --no-remote \
      --force-skip-review-check 테스트 --allow-status-mismatch 테스트 >"$outf" 2>&1; echo $? >"$rcf" ) &
  pid=$!
  while [[ ! -e "$mark" && "$i" -lt 600 ]] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  AC11_EARLY=0; [[ -e "$mark" ]] && grep -qF "$want" "$outf" && AC11_EARLY=1
  wait "$pid" || true
  AC11_LATE=0; [[ -e "$done_mark" ]] && AC11_LATE=1
  AC11_EL=$((SECONDS - t0))
  ARCH_OUT="$(cat "$outf")"; ARCH_RC="$(cat "$rcf" 2>/dev/null || echo 99)"
}
# 반환 판정은 고정 경과 문턱이 아니라 늦춘 원격의 완료 표식으로 한다. 고정 20초는 부하 평균 12~17 에서 정상 경로도
# 넘겼고(31초 실측), archive 시작부터 잰 경과는 원격 조회 밖 단계까지 더해져 62초까지 늘어난 관측이 있다.
echo "== AC11 (A): 팀 브랜치 fetch 가 상한을 넘으면 시작 줄·원인·재시도 안내와 함께 거부 =="
nofr_case ta1 '{"team_publish": {"mode": "push", "base": "main"}}' "" session
ta1_head="$(gl_head)"
ac11_run ta1 "archive: 팀 저장소 반영 확인 — libs/prod 의 origin/main 를 조회합니다 (git fetch, 최대 1초)"
ok_if "AC11(A): 원격이 응답하기 전 시작 줄이 이미 나옴" eq "$AC11_EARLY" 1
ok_if "AC11(A): rc 1, 기본 브랜치 불변" eq "$ARCH_RC|$(gl_head)" "1|$ta1_head"
ok_if "AC11(A): 초과 원인" out_has "1초 안에 끝나지 않았습니다"
ok_if "AC11(A): 재시도 안내" out_has "네트워크·인증을 확인한 뒤 같은 명령을 다시 실행하거나"
ok_if "AC11(A): 늦춘 원격이 지연을 마치기 전에 반환 (경과 ${AC11_EL}초)" eq "$AC11_LATE" 0
echo "== AC11 (B): 설정·origin/HEAD 가 없을 때 remote set-head 가 상한을 넘으면 같은 안내로 거부 =="
nofr_case tb1 "$PUSH_CFG" "" session
git -C "$CASE_REPO/libs/prod" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
tb1_head="$(gl_head)"
ac11_run tb1 "archive: 팀 저장소 반영 확인 — libs/prod 의 origin 기본 브랜치를 조회합니다 (git remote set-head, 최대 1초)"
ok_if "AC11(B): 원격이 응답하기 전 시작 줄이 이미 나옴" eq "$AC11_EARLY" 1
ok_if "AC11(B): rc 1, 기본 브랜치 불변" eq "$ARCH_RC|$(gl_head)" "1|$tb1_head"
ok_if "AC11(B): 초과 원인" out_has "1초 안에 끝나지 않았습니다"
ok_if "AC11(B): 재시도 안내" out_has "네트워크·인증을 확인한 뒤 같은 명령을 다시 실행하거나"
ok_if "AC11(B): 늦춘 원격이 지연을 마치기 전에 반환 (경과 ${AC11_EL}초)" eq "$AC11_LATE" 0

# 정리 커밋은 review-session·base-commit 을 지운다. 재실행 게이트가 그 HEAD 를 판정하면 기준점이 없어 거부된다.
# push 실패는 overlay 원격의 pre-receive 거부로 만든다(원격 URL 을 틀리게 두면 Step 4 전의 fetch --tags 에서 멈춰 정리 커밋이 생기지 않는다).
echo "== AC6c: no-fr 정리 커밋 뒤 push 실패 → 원격 고침 → set-title 커밋 → 안내된 두 플래그로 재실행 — 게이트 통과·발행 =="
nofr_case nr1 '{"team_publish": {"mode": "push", "base": "nr1"}}' "" session
printf '#!/bin/sh\necho "pre-receive 거부(테스트)" >&2\nexit 1\n' > "$TMP/nr1/overlay.git/hooks/pre-receive"
chmod +x "$TMP/nr1/overlay.git/hooks/pre-receive"
ARCH_RC=0
ARCH_OUT="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
  --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || ARCH_RC=$?
ok_if "AC6c: 첫 실행은 정리 커밋 뒤 push 거부로 실패" eq "$([[ "$ARCH_RC" != 0 ]] && echo x)|$(git -C "$CASE_REPO" log -1 --format=%s)" "x|chore(lifecycle): archive nr1 metadata 정리"
rm -f "$TMP/nr1/overlay.git/hooks/pre-receive"
( cd "$CASE_REPO" && bash rd-workflow/scripts/rd task set-title nr1 ) >/dev/null 2>&1
git -C "$CASE_REPO" add -A; git -C "$CASE_REPO" commit -q -m "chore: set-title 복구"
ARCH_RC=0
ARCH_OUT="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
  --force-skip-review-check 테스트 --allow-status-mismatch 테스트 2>&1 )" || ARCH_RC=$?
ok_if "AC6c: 재실행 rc 0" test "$ARCH_RC" -eq 0
ok_if "AC6c: 재실행에 기준점 거부 없음" out_lacks "반영 대상을 판정할 수 없습니다"
ok_if "AC6c: 원격 main 이 로컬 main 을 따라옴" eq "$(gl_remote)" "$(gl_head)"

# 정리 커밋 판정은 .gitmodules 의 ignore 설정과 무관하게 모든 바뀐 경로를 봅니다.
# 없으면 새는 실수: ignore=all 인 gitlink 와 task-state 를 함께 바꾼 커밋을 lifecycle 전용으로 보고, 재실행 게이트가
# 새 포인터가 든 HEAD 대신 정리 전 조상을 판정합니다. 위 AC6c 저장소에 커밋 두 개를 더해 archive.sh 의 판정 함수를 직접 부릅니다.
git -C "$CASE_REPO" config -f "$CASE_REPO/.gitmodules" submodule.libs/prod.ignore all
git -C "$CASE_REPO" add .gitmodules; git -C "$CASE_REPO" commit -q -m "libs/prod ignore=all"
git -C "$CASE_REPO" update-index --cacheinfo "160000,$(git -C "$CASE_REPO" rev-parse HEAD),libs/prod"
printf 'x\n' >>"$CASE_REPO/rd-workflow-workspace/.lifecycle/task-state"
git -C "$CASE_REPO" add rd-workflow-workspace/.lifecycle/task-state; git -C "$CASE_REPO" commit -q -m "포인터 + task-state"
ARCH_RC=0
( cd "$CASE_REPO" && project_root="$CASE_REPO" && source "$SCRIPT_DIR/_lifecycle_common.sh" >/dev/null 2>&1 \
    && eval "$(arch_fns _archive_only_lifecycle_paths)" && _archive_only_lifecycle_paths HEAD ) >/dev/null 2>&1 || ARCH_RC=$?
ARCH_OUT="$(git -C "$CASE_REPO" diff-tree --no-commit-id --name-only -r --ignore-submodules=none HEAD | tr '\n' ' ')"
ok_if "AC6c: ignore=all gitlink 가 섞인 커밋은 lifecycle 전용이 아님 (바뀐 경로: $ARCH_OUT)" test "$ARCH_RC" -eq 1

# 팀 저장소 반영 게이트의 대상 판정: 실제 대상 경로를 나타낼 수 없으면(탭) 원인 줄과 우회 안내로 거부하고,
# --allow-unpublished-submodule "<사유>" 이면 audit 기록 뒤 통과합니다. 경로에 0x01 이 든 gitlink 는 사전 검사에서
# 거부하지 않고 그 경로의 반영 방식대로 판정합니다.
# 없으면 새는 실수: (다) 판정 실패가 우회 처리를 거치지 않아 안내한 복구 옵션이 듣지 않음 / 경로의 0x01 을 개행으로 읽어 오거부함.
# 위 AC6c 저장소에 커밋을 더하고 archive.sh 의 게이트 함수를 직접 부릅니다(새 fixture·archive 실행 없음).
tpg_gate() {  # <tip> [사유] — 출력 ARCH_OUT, rc ARCH_RC
  ARCH_RC=0
  ARCH_OUT="$( cd "$CASE_REPO" && project_root="$CASE_REPO" && export project_root \
    && source "$SCRIPT_DIR/_lifecycle_common.sh" && source "$SCRIPT_DIR/../_state_common.sh" \
    && source "$SCRIPT_DIR/../_submodule_common.sh" && source "$SCRIPT_DIR/_tasks_index.sh" \
    && source "$SCRIPT_DIR/_team_publish_common.sh" \
    && eval "$(arch_fns archive_team_publish_gate _archive_team_publish_gate_run _archive_nofr_name_hint _archive_only_lifecycle_paths _archive_status_at _archive_tpg_bypass _archive_tpg_tree_unreadable _archive_tpg_remote)" \
    && CURRENT_WT="$CASE_REPO" FR_BRANCH=null BRANCH_MODE=no-fr SLUG=tpg UNPUB_REASON="${2-}" \
    && ALLOW_UNPUB=0 && { [[ -z "${2-}" ]] || ALLOW_UNPUB=1; } \
    && AUDIT_LOG="$CASE_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log" \
    && archive_team_publish_gate "$1" 2>&1 )" || ARCH_RC=$?
}
# tpg_seal <세션> <기준점> <리뷰한 끝> — task-state review-session 과 seal 마커를 커밋하고 tip OID 를 TPG_TIP 에 둔다.
tpg_seal() {
  mkdir -p "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-seals"
  printf 'schema=1\nsession-id=%s\nreview-base=%s\nreview-head=%s\nhead=%s\n' "$1" "$2" "$3" "$3" \
    > "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-seals/$1.seal"
  printf 'schema=1\nshort-title=nr1\nstatus=아카이브 보류\nfr-branch=null\nworktree-path=null\nsource-fr=-\nbase-commit=null\nreview-session=%s\n' "$1" \
    > "$CASE_REPO/rd-workflow-workspace/.lifecycle/task-state"
  git -C "$CASE_REPO" add -f rd-workflow-workspace/.lifecycle; git -C "$CASE_REPO" commit -q -m "seal $1"
  TPG_TIP="$(git -C "$CASE_REPO" rev-parse HEAD)"
}
echo "== 게이트 (다): 리뷰한 범위의 gitlink 경로에 탭 — 원인·우회 안내로 거부, --allow-unpublished-submodule 은 audit 뒤 통과 =="
tpg_b="$(git -C "$CASE_REPO" rev-parse HEAD)"
tpg_oid="$(git -C "$CASE_REPO" rev-parse "HEAD:libs/prod")"
git -C "$CASE_REPO" update-index --add --cacheinfo "160000,$tpg_oid,t"$'\t'"ab"
git -C "$CASE_REPO" commit -q -m "탭 경로 gitlink"
tpg_seal tpg-s1 "$tpg_b" "$(git -C "$CASE_REPO" rev-parse HEAD)"
tpg_gate "$TPG_TIP"
ok_if "게이트(다): 탭 경로 실제 대상 → rc 1" test "$ARCH_RC" -eq 1
ok_if "게이트(다): 원인 줄" out_has "tp_targets: gitlink 경로에 탭·개행이 있어 반영 대상을 판정할 수 없습니다: \$'t\\tab'"
ok_if "게이트(다): 우회 안내" out_has '--allow-unpublished-submodule "<사유>"'
tpg_gate "$TPG_TIP" 탭경로_확인
ok_if "게이트(다): --allow-unpublished-submodule → rc 0" test "$ARCH_RC" -eq 0
ok_if "게이트(다): audit 에 [team-publish] 사유" grep -qF "[team-publish] 탭경로_확인" "$CASE_REPO/rd-workflow-workspace/.lifecycle/review-skip-audit.log"
echo "== 게이트 (가): 0x01 이 든 gitlink 경로는 오거부하지 않고 그 경로의 반영 방식(push)대로 대상이 된다 =="
git -C "$CASE_REPO" rm -q --cached "t"$'\t'"ab"; git -C "$CASE_REPO" commit -q -m "탭 경로 제거"
tpg_b="$(git -C "$CASE_REPO" rev-parse HEAD)"
printf '%s\n' '{"team_publish": {"mode": "manual", "submodules": {"a\u0001sub": {"mode": "push"}}}}' > "$CASE_REPO/rd-workflow/config/workflow.json"
git -C "$CASE_REPO" add rd-workflow/config/workflow.json
git -C "$CASE_REPO" update-index --add --cacheinfo "160000,$tpg_oid,a"$'\001'"sub"
git -C "$CASE_REPO" commit -q -m "0x01 경로 gitlink"
tpg_seal tpg-s2 "$tpg_b" "$(git -C "$CASE_REPO" rev-parse HEAD)"
tpg_gate "$TPG_TIP"
ok_if "게이트(가): 0x01 경로를 판정 불가로 거부하지 않음" out_lacks "판정할 수 없습니다"
ok_if "게이트(가): 0x01 경로가 push 대상으로 판정됨(초기화 안 된 submodule 안내)" out_has "- a"$'\001'"sub: 작업 worktree 의 submodule 이 초기화되지 않았습니다"

# ---- AC7: no-fr 재실행이 작업 이름 차이로 기준점을 못 찾으면 첫 이름과 복구 순서를 안내 (spec D8) ----
# nr_first <이름> — no-fr 작업을 만들고 첫 실행이 정리 커밋 뒤 push 거부로 실패하게 한 다음 원격을 고친다(HEAD = 정리 커밋).
nr_first() {
  nofr_case "$1" "{\"team_publish\": {\"mode\": \"push\", \"base\": \"$1\"}}" "" session
  printf '#!/bin/sh\necho "pre-receive 거부(테스트)" >&2\nexit 1\n' > "$TMP/$1/overlay.git/hooks/pre-receive"
  chmod +x "$TMP/$1/overlay.git/hooks/pre-receive"
  ( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check 테스트 --allow-status-mismatch 테스트 ) >/dev/null 2>&1 || true
  rm -f "$TMP/$1/overlay.git/hooks/pre-receive"
}
nr_rerun() {  # 추가 인자는 archive.sh 로 넘긴다
  ARCH_RC=0
  ARCH_OUT="$( cd "$CASE_REPO" && bash rd-workflow/scripts/lifecycle/archive.sh \
    --force-skip-review-check 테스트 --allow-status-mismatch 테스트 "$@" 2>&1 )" || ARCH_RC=$?
}
nr_cmd() { ( cd "$CASE_REPO" && "$@" ) >/dev/null 2>&1; }
NR_PATHS="rd-workflow-workspace/.lifecycle/task-state CURRENT_TASK.md"

echo "== AC7(HEAD): 정리 커밋이 HEAD 인데 다른 이름으로 재실행 — 첫 이름과 새 커밋 안내, 안내대로 하면 통과 =="
nr_first nr2
ok_if "AC7(HEAD): 첫 실행 뒤 HEAD 는 정리 커밋" eq "$(git -C "$CASE_REPO" log -1 --format=%s)" "chore(lifecycle): archive nr2 metadata 정리"
nr_cmd bash rd-workflow/scripts/rd task set-title other
nr_rerun --force-dirty  # 커밋하지 않은 set-title 은 worktree clean 검사에 걸려 --force-dirty 가 있어야 기준점 판정까지 간다
ok_if "AC7(HEAD): 거부 rc 1" test "$ARCH_RC" -eq 1
ok_if "AC7(HEAD): 첫 실행의 작업 이름" out_has "첫 실행의 작업 이름은 nr2"
# 아래 복구 단계는 안내 줄의 명령을 글자 그대로 옮긴 것입니다 — 안내 단언이 전체 명령을 고정하므로 안내가 달라지면 여기서 FAIL 합니다.
ok_if "AC7(HEAD): set-title nr2 --force 안내" out_has "다시 실행: bash rd-workflow/scripts/rd task set-title nr2 --force (복구 전용) → "
ok_if "AC7(HEAD): git commit -m 안내" out_has " → git commit -m \"chore(lifecycle): nr2 작업 이름 복구\" -- $NR_PATHS → archive.sh 재실행"
nr_cmd bash rd-workflow/scripts/rd task set-title nr2 --force
git -C "$CASE_REPO" commit -q -m "chore(lifecycle): nr2 작업 이름 복구" -- $NR_PATHS
nr_rerun
ok_if "AC7(HEAD): 안내대로 하면 발행 성공" test "$ARCH_RC" -eq 0

echo "== AC7(같은 이름): 정리 커밋이 HEAD 이고 같은 이름을 커밋하지 않은 채 --force-dirty 로 재실행 — 정리 커밋을 알아보고 발행 =="
# 없으면 새는 실수: 게이트가 HEAD 인 정리 커밋을 알아보지 못해도 위·아래 복구(커밋 뒤 재실행)는 부모 갈래로 통과해 드러나지 않습니다.
nr_first nr6
nr_cmd bash rd-workflow/scripts/rd task set-title nr6
nr_rerun --force-dirty
ok_if "AC7(같은 이름): 발행 성공" test "$ARCH_RC" -eq 0

echo "== AC7(부모): 정리 커밋 위에 set-title 커밋 — amend 안내, 안내대로 하면 통과 =="
nr_first nr3
nr_cmd bash rd-workflow/scripts/rd task set-title other
git -C "$CASE_REPO" commit -q -m "chore: set-title other" -- $NR_PATHS
nr_rerun
ok_if "AC7(부모): 거부 rc 1" test "$ARCH_RC" -eq 1
ok_if "AC7(부모): 첫 실행의 작업 이름" out_has "첫 실행의 작업 이름은 nr3"
ok_if "AC7(부모): git commit --amend 안내" out_has "다시 실행: bash rd-workflow/scripts/rd task set-title nr3 --force (복구 전용) → git commit --amend --no-edit -- $NR_PATHS (정리 커밋이 HEAD 의 부모로 남아야 합니다) → archive.sh 재실행"
nr_cmd bash rd-workflow/scripts/rd task set-title nr3 --force
git -C "$CASE_REPO" commit -q --amend --no-edit -- $NR_PATHS
nr_rerun
ok_if "AC7(부모): 안내대로 하면 발행 성공" test "$ARCH_RC" -eq 0

echo "== AC7(원격): 부모 상태의 HEAD 가 이미 원격에 있으면 고쳐 쓰지 않는다고 안내 =="
# 다른 체크아웃이 push 한 상황 — 이 체크아웃의 원격 추적 ref 는 push 전 값으로 뒤처져 있습니다.
# 원격 모드는 preflight 의 fetch 가 추적 ref 를 갱신하므로, fetch 하지 않는 --no-remote 재실행으로 봅니다.
nr_first nr4
nr_cmd bash rd-workflow/scripts/rd task set-title other
git -C "$CASE_REPO" commit -q -m "chore: set-title other" -- $NR_PATHS
NR_STALE="$(git -C "$CASE_REPO" rev-parse refs/remotes/origin/main)"
git -C "$CASE_REPO" push -q origin HEAD:refs/heads/main
git -C "$CASE_REPO" update-ref refs/remotes/origin/main "$NR_STALE"
nr_rerun --no-remote
ok_if "AC7(원격): 거부 rc 1" test "$ARCH_RC" -eq 1
ok_if "AC7(원격): 첫 실행의 작업 이름" out_has "첫 실행의 작업 이름은 nr4"
ok_if "AC7(원격): 고쳐 쓰지 않음 안내" out_has "HEAD 가 원격에 있어 고쳐 쓰지 않습니다"
ok_if "AC7(원격): --amend 없음" out_lacks "--amend"

echo "== AC7(무관): 정리 커밋 위에 코드 파일을 바꾼 커밋 — 이름 안내 없음 =="
nr_first nr5
nr_cmd bash rd-workflow/scripts/rd task set-title other
echo more > "$CASE_REPO/work2.txt"
git -C "$CASE_REPO" add work2.txt
git -C "$CASE_REPO" commit -q -m "구현: 정리 뒤 코드 변경" -- work2.txt $NR_PATHS
nr_rerun
ok_if "AC7(무관): 거부 rc 1" test "$ARCH_RC" -eq 1
ok_if "AC7(무관): 이름 안내 없음" out_lacks "첫 실행의 작업 이름"

DONE=1
echo "test_archive_submodule: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == 0 ]]
