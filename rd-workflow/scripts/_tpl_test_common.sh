# _tpl_test_common.sh — test_sync_template_*.sh 가 source 하는 fixture 함수 모음 (직접 실행하지 않음)
# 호출 쪽이 SCRIPT_DIR, WORK(mktemp -d), FAIL 을 먼저 정의한다.
# TPL_SRC_DIR: 스크립트 사본 디렉터리. 변이 검사 때 변이를 넣은 사본을 가리킨다 (기본은 SCRIPT_DIR).

TPL_SRC="${TPL_SRC_DIR:-$SCRIPT_DIR}"
TPL_GIT=(git -c user.email=t@t.t -c user.name=t -c commit.gpgsign=false)

tpl_put() { # tpl_put <루트> <상대 경로> <내용> — 내용 뒤에 개행을 붙여 쓴다
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
}

tpl_copy_scripts() { # tpl_copy_scripts <루트> — TPL_SRC 의 실제 스크립트를 <루트>/rd-workflow/scripts 에 복사
  local d="$1/rd-workflow/scripts" f
  mkdir -p "$d"
  for f in sync_template.sh sync_template_lib.py claudemd_rules_migrate.sh "$TPL_SRC"/_tpl_*.py; do
    [[ "$f" == */* ]] || f="$TPL_SRC/$f"
    [[ -e "$f" ]] && cp -p "$f" "$d/"
  done
}

tpl_commit() { # tpl_commit <git 디렉터리> — 호출 쪽이 먼저 git init 해 둔 디렉터리에 add -A + commit
  "${TPL_GIT[@]}" -C "$1" add -A
  "${TPL_GIT[@]}" -C "$1" commit -q --allow-empty -m fixture
}

tpl_make_clone() { # tpl_make_clone <디렉터리> [full|lite] — 스크립트·VERSION 만 있는 clone 디렉터리.
  # 계약: git 저장소가 아니다(classify 는 clone 의 git 이력이 필요 없다). git 이력이 필요한 시험은
  # 파일을 더 둔 뒤 호출 쪽이 `git -C <dir> init -q` 와 tpl_commit 을 부른다.
  local dir="$1" kind="${2:-full}" ver="2026-11-13-000000"
  [[ "$kind" == "lite" ]] && ver="lite-2026-11-13-000000"
  mkdir -p "$dir"
  tpl_copy_scripts "$dir"
  tpl_put "$dir" rd-workflow/VERSION "$ver"
}

tpl_make_project() { # tpl_make_project <디렉터리> <clone> — clone 의 스크립트·VERSION 사본을 같은 경로에 둔 git 프로젝트
  local dir="$1" clone="$2"
  mkdir -p "$dir/rd-workflow"
  git -C "$dir" init -q
  cp -pR "$clone/rd-workflow/scripts" "$dir/rd-workflow/"
  cp -p "$clone/rd-workflow/VERSION" "$dir/rd-workflow/VERSION"
}

tpl_run() { # tpl_run <프로젝트> <clone> <하위 명령> [인자...] — clone 의 스크립트를 프로젝트 cwd 로 실행. TPL_OUT·TPL_ERR·TPL_RC 에 저장
  local proj="$1" clone="$2"; shift 2
  TPL_OUT="$(cd "$proj" && bash "$clone/rd-workflow/scripts/sync_template.sh" "$@" 2>"$WORK/.tpl_err")"; TPL_RC=$?
  TPL_ERR="$(cat "$WORK/.tpl_err")"
}

tpl_check() { # tpl_check <설명> <실제> <기대>
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    diff <(printf '%s\n' "$3") <(printf '%s\n' "$2") | sed 's/^/    /'
    FAIL=1
  fi
}
