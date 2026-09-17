#!/usr/bin/env bash
# acceptance_sync_once.sh — 종단 수용 검증 (REQUEST AC 13)
#
# 세 사전조건을 함께 가진 설치본 fixture 에 sync 절차를 1회 수행하고, 중간 수동 교정 없이
# 직후 self_test.sh consumer 가 통과하는지 판정한다.
#
#   (1) blocked 서술이 없는 구형 FUTURE_REQUESTS.md + 인덱스 항목 1건
#   (2) 설치본 레이아웃 (<proj>/rd-workflow/scripts)
#   (3) rd-workflow/config/workflow.json 부재 — fixture 는 config 부재로 시작하고,
#       sync 5단계가 배포본을 둡니다 (절차 뒤에는 이 경로가 존재합니다)
#
# 이어서 **경로 보존 시나리오 셋**을 같은 clone 으로 추가 검증합니다. 보존 목록
# (sync_template.md 2단계) 의 workflow.json 은 경로가 이미 있으면 내용도 경로 자체도
# 손대지 않아야 하며, 이것이 깨지면 사용자의 명시적 `manual` opt-out 이 조용히 지워집니다.
#   (A) 기존 regular file  -> byte-for-byte 동일
#   (B) dangling symlink   -> 링크 자체 보존 (`-e` 만 보면 "부재" 로 오판해 덮어씁니다)
#   (C) 유효 symlink       -> 링크 정체성 + target 내용 보존 (역참조 덮어쓰기 방지)
#
# 절차는 sync_template.md 의 단계 순서를 그대로 따른다:
#   1단계 sync_template.sh(clone) -> 4단계 마이그레이션 -> 5단계 복사 -> 5.1 -> 6단계 검증
#
# **sync_template.sh 는 파일을 복사하지 않는다** (clone 경로만 출력). 5단계 복사는 이
# 스크립트가 수행한다.
#
# **self_test.sh 스텝으로 등록하지 않는다.** 등록하면 self_test 가 self_test 를 호출하는
# 재귀가 된다. 릴리즈 수용 검증이므로 검증 단계에서 1회 직접 실행한다.
# **정본 저장소 전용** — remote 구성에 _ROOT_FILES/ 배포 루트가 필요하다.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 배포 원본(_ROOT_FILES) 위치를 실행 레이아웃에 따라 판별한다.
#   - 정본 배포 원본에서 실행: <repo>/_ROOT_FILES/rd-workflow/scripts  -> two_up 이 곧 _ROOT_FILES
#   - 루트 dogfooding 사본에서 실행: <repo>/rd-workflow/scripts        -> two_up/_ROOT_FILES
# 고정 `../..` 로 계산하면 전자에서 `_ROOT_FILES/_ROOT_FILES` 를 찾는다 — 이 스크립트가
# 고치려는 결함(self_test 의 root_dir 계산)과 같은 부류이므로 같은 판별을 쓴다.
# `build_template.sh` 존재를 함께 보는 이유는 저장소 이름 자체가 `_ROOT_FILES` 인 경우의
# 오인을 막기 위함이다 (`self_test.sh` 의 `_hook_repo_root()` 와 같은 판단).
_two_up="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if [[ "$(basename "$_two_up")" == "_ROOT_FILES" ]] \
   && [[ -f "$(dirname "$_two_up")/scripts/build_template.sh" ]]; then
  REPO_ROOT="$(dirname "$_two_up")"
  DIST_ROOT="$_two_up"
else
  REPO_ROOT="$_two_up"
  DIST_ROOT="${REPO_ROOT}/_ROOT_FILES"
fi
# clone 경로가 "이번 실행이 만든, 폐기해도 되는 임시 clone" 인지 판정한다.
# `sync_template.sh` 는 `$(mktemp -d)/template` 에 clone 한다 (sync_template.sh:70,77).
# 네 조건을 모두 만족하지 않으면 복사 원본으로 쓰지도, 재귀 삭제하지도 않는다. `mktemp` 가
# 실패해 값이 비거나 예상 밖 경로가 오면 `$(dirname ...)` 재귀 삭제가 남의 디렉터리를
# 지울 수 있고, 그 위험을 경로 문자열만으로 차단하는 것이 이 함수의 목적이다.
# (TMPDIR 을 작업 디렉터리 안으로 묶는 방법은 쓰지 않는다 — macOS `mktemp` 는 TMPDIR 을
#  무시하고 `/var/folders/...` 로 폴백하므로 플랫폼마다 결과가 갈린다.)
is_disposable_clone() { # $1=clone 경로
  local c="$1" parent
  [[ -n "$c" && -d "$c" ]] || return 1
  [[ "$(basename "$c")" == "template" ]] || return 1
  parent="$(dirname "$c")"
  case "$(basename "$parent")" in tmp.*) ;; *) return 1 ;; esac
  # mktemp -d 직후라 clone 하나만 들어 있어야 한다 — 마지막 방어선
  [[ "$(cd "$parent" && ls -A | tr '\n' ' ')" == "template " ]] || return 1
  return 0
}

# 가드 단독 판정 모드 (회귀 테스트용). 배포 루트 검사보다 앞에 둔다 — 이 판정은 레이아웃과
# 무관하고, 뒤에 두면 설치본에서 도달하지 못한다.
if [[ "${1:-}" == "--check-clone" ]]; then
  is_disposable_clone "${2:-}"
  exit $?
fi

if [[ ! -d "$DIST_ROOT" ]]; then
  echo "acceptance_sync_once: _ROOT_FILES 를 찾을 수 없습니다 — 이 검증은 정본 저장소에서만 실행합니다." >&2
  echo "  경로: $DIST_ROOT" >&2
  exit 1
fi

fail=0
check() { # $1 설명  $2 실제  $3 기대
  if [[ "$2" == "$3" ]]; then echo "  ok  $1"
  else echo "  FAIL $1 (got='$2' want='$3')"; fail=1; fi
}

# JSON 문자열 값 하나를 읽습니다. `jq` 를 요구하지 않으려고 이 저장소의 다른 스크립트
# (`defect_reports.sh` 의 `cfg_upstream`) 와 같은 `sed` 방식을 씁니다. 파일이 없으면
# 빈 문자열이 나오고, 그 자체가 판정에 쓰입니다.
json_str_value() { # $1=파일  $2=키
  [[ -f "$1" ]] || return 0
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# 5.1 이 추가한 `defect_report_upstream` 줄만 걷어낸 결과를 출력합니다. 그 결과가 5단계
# 직후 사본과 byte 로 같으면 「5.1 이 그 키 하나만 추가했고 나머지 줄은 손대지 않았다」가
# 증명됩니다 (값·형식·들여쓰기·키 순서 전부 포함).
strip_upstream_line() { # $1=파일
  grep -v '"defect_report_upstream"' "$1"
}

# 5.1 절(`defect_reports.sh set-upstream`)을 프로젝트 디렉터리에서 실행합니다.
# 실사용 sync 절차는 5단계 복사 뒤에 반드시 이 절을 돌리므로, 보존 시나리오도 여기까지
# 통과해야 「보존됐다」고 말할 수 있습니다.
run_step51() { # $1=proj  $2=로그 파일
  ( cd "$1" && bash rd-workflow/scripts/defect_reports.sh set-upstream \
      "https://github.com/example/repo" ) > "$2" 2>&1
}

# 디렉터리 내용을 대상에 병합 복사한다 (cp -R 의 "이미 있으면 안으로 넣기" 함정 회피).
copy_into() { # $1=src dir  $2=dst dir
  mkdir -p "$2"
  ( cd "$1" && tar cf - . ) | ( cd "$2" && tar xf - )
}

# sync_template.md 5단계(복사·신규 추가)를 모사합니다. 2단계 보존 목록 중
# `rd-workflow/config/workflow.json` 은 **경로가 이미 있으면 내용도 경로 자체도
# 손대지 않습니다.** 「있으면」의 판정은 `[ -e ] || [ -L ]` 입니다 — dangling symlink 는
# `-e` 가 거짓이므로 `-L` 을 함께 보지 않으면 "부재" 로 오판해 배포본으로 덮어씁니다.
# 보존은 링크를 따라가지 않는 `mv` 로 옮겼다가 되돌리는 방식이라, 유효 symlink 도
# 역참조되지 않고 링크 정체성과 target 내용이 그대로 남습니다.
sync_copy_step() { # $1=clone  $2=proj  (실패하면 1 을 반환합니다)
  local clone="$1" proj="$2" base rc=0
  local cfg="$proj/rd-workflow/config/workflow.json" saved=""
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then
    saved="$proj/rd-workflow/config/.workflow.json.preserve.$$"
    if ! mv "$cfg" "$saved"; then
      echo "  보존 대상 대피 실패: $cfg" >&2; rc=1; saved=""
    fi
  fi
  for base in $(cd "$clone" && ls -A | grep -v '^\.git$'); do
    if [[ -d "$clone/$base" ]]; then
      if ! copy_into "$clone/$base" "$proj/$base"; then
        echo "  복사 실패(디렉터리): $base" >&2; rc=1
      fi
    else
      if ! cp "$clone/$base" "$proj/$base"; then
        echo "  복사 실패(파일): $base" >&2; rc=1
      fi
    fi
  done
  if [[ -n "$saved" ]]; then
    rm -f "$cfg"
    if ! mv "$saved" "$cfg"; then
      echo "  보존 대상 복원 실패: $cfg" >&2; rc=1
    fi
  fi
  return $rc
}

# 임시 작업 디렉터리는 **경로를 파생하기 전에** fail-closed 로 확정한다.
# 실패하면 WORK 가 빈 문자열이 되어 REMOTE=/remote · PROJ=/proj 로 계산되고, 권한이 있는
# CI·컨테이너에서는 루트 바로 아래에 실제 파일을 만들면서도 trap 은 빈 경로만 받아
# 정리하지 못한다. 형태는 전 지점 공통 템플릿을 따른다.
WORK="$(mktemp -d)" || { echo "acceptance_sync_once: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "acceptance_sync_once: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
REMOTE="$WORK/remote"
PROJ="$WORK/proj"

echo "== fixture 준비 =="
# remote: 배포 루트 **전체**를 담는다. rd-workflow/ 하위만 담으면 consumer 가 요구하는
# 루트 파일(CLAUDE.md 등)이 없다.
mkdir -p "$REMOTE"
copy_into "$DIST_ROOT" "$REMOTE"
rm -f "$REMOTE/.DS_Store"
printf '9999-12-31-000000
' > "$REMOTE/rd-workflow/VERSION"
git -C "$REMOTE" init --quiet
git -C "$REMOTE" -c user.email=t@t.t -c user.name=t add -A
git -C "$REMOTE" -c user.email=t@t.t -c user.name=t commit --quiet -m fixture

# (2) 설치본 레이아웃 — sync 진입점과 before 대조에 필요한 것만 두고 시작한다
mkdir -p "$PROJ/rd-workflow/scripts" "$PROJ/rd-workflow-workspace/backlog"
cp "$DIST_ROOT/rd-workflow/scripts/sync_template.sh" "$PROJ/rd-workflow/scripts/"
cp "$DIST_ROOT/rd-workflow/scripts/test_fr_blocked_status.sh" "$PROJ/rd-workflow/scripts/"
copy_into "$DIST_ROOT/rd-workflow/claude_skills" "$PROJ/rd-workflow/claude_skills"
printf '2026-01-01-000000
' > "$PROJ/rd-workflow/VERSION"
# (3) workflow.json 을 두지 않습니다 (config 디렉터리도 만들지 않습니다).
#     config 없는 기존 프로젝트가 바로 이 시나리오이며, sync 5단계가 배포본을 둡니다.

# (1) 구형 정의 문구
cat > "$PROJ/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md" <<'FR'
# FUTURE_REQUESTS

## 상태 값

- `idea`: 아직 검증 안 됨
- `validated`: 필요성 확인, 우선순위 아님
- `ready-for-request`: REQUEST.md로 바로 올릴 수 있음
- `parked`: 검토 완료, 지금은 안 함
- `done` / `dropped`: 인덱스에서 삭제

## 파일 분리

- **이 파일**: 활성 항목(idea, validated, ready-for-request)
- **`FUTURE_REQUESTS_PARKED.md`**: 보류 항목 (parked)
- **`items/`**: 상세 파일

## 인덱스

| 날짜 | 제목 |
|------|------|
| 2026-01-01 | sample-item |
FR

echo "== before: 결함이 실제로 재현되는지 =="
# 통과가 의미를 갖도록 "원래 실패했다" 를 먼저 단언한다 (M008 검증의 대조군 E3 과 같은 역할)
( cd "$PROJ" && bash rd-workflow/scripts/test_fr_blocked_status.sh ) > "$WORK/before.out" 2>&1
check "before — test_fr_blocked_status FAIL" "$?" "1"
check "before — 파일 분리 미명시가 원인" \
  "$(grep -c '파일 분리에 blocked 미명시' "$WORK/before.out")" "1"

echo "== 1단계: sync_template.sh (clone 경로 확보) =="
( cd "$PROJ" && bash rd-workflow/scripts/sync_template.sh "$REMOTE" ) > "$WORK/sync.out" 2>&1
SYNC_RC=$?
check "sync_template.sh 종료코드 0" "$SYNC_RC" "0"
CLONE="$(tail -1 "$WORK/sync.out")"
check "clone 경로가 폐기 가능한 임시 clone" \
  "$( is_disposable_clone "$CLONE" && echo yes || echo no )" "yes"
# clone 확보가 실패하면 **여기서 끝낸다.** 이후 5단계는 `$CLONE` 을 복사 원본으로 쓰고
# 마지막에 그 부모를 재귀 삭제하므로, 검증되지 않은 경로로 계속 가면 진단이 아니라 사고가 된다.
if [[ "$SYNC_RC" != "0" ]] || ! is_disposable_clone "$CLONE"; then
  echo "acceptance_sync_once: clone 경로를 확보하지 못해 중단합니다." >&2
  echo "  종료코드='$SYNC_RC' 경로='$CLONE'" >&2
  echo "  기대: mktemp 임시 디렉터리(tmp.*) 안의 'template' 디렉터리 하나" >&2
  echo "--- sync_template.sh 출력 ---" >&2
  cat "$WORK/sync.out" >&2
  echo "acceptance_sync_once: FAIL"
  exit 1
fi

echo "== 4단계: 구조 마이그레이션 (M009) =="
# clone 사본의 MIGRATIONS.md 가 권위다 (sync_template.md Step 4 규정).
python3 - "$CLONE/rd-workflow/MIGRATIONS.md" "$WORK/m9_zzfx.py" <<'M9EXTRACT'
import sys
md, out = sys.argv[1], sys.argv[2]
lines = open(md, encoding="utf-8").read().split("\n")
start = None
for i, l in enumerate(lines):
    if l.startswith("## M009"):
        start = i
        break
if start is None:
    sys.exit("M009 절을 찾지 못했습니다")
body, grab = [], False
for l in lines[start:]:
    t = l.strip()
    if t == "python3 - <<'PY'":
        grab = True
        continue
    if grab and t == "PY":
        break
    if grab:
        body.append(l[3:] if l.startswith("   ") else l)
if not body:
    sys.exit("M009 의 python3 heredoc 본문이 비어 있습니다")
open(out, "w", encoding="utf-8").write("\n".join(body) + "\n")
M9EXTRACT
( cd "$PROJ" && python3 "$WORK/m9_zzfx.py" ) > "$WORK/m9.out" 2>&1
M9_RC=$?
check "M009 종료코드 0" "$M9_RC" "0"
if [[ "$M9_RC" != "0" ]]; then
  echo "--- M009 출력 ---" >&2
  cat "$WORK/m9.out" >&2
  echo "--- 추출된 snippet 앞 12줄 ---" >&2
  head -12 "$WORK/m9_zzfx.py" >&2
fi

echo "== 5단계: 동기화 실행 (복사·신규 추가) =="
# sync_template.md 2단계 보존 목록은 덮지 않는다. 이 fixture 에 삭제 후보는 없다.
#
# `set -e` 를 켜지 않는다 — 이 스크립트는 진단을 여러 개 모아 보여주는 방식이고 `check "$?"`
# 패턴이 그것에 의존한다. 대신 복사 실패를 국소 변수에 누적해 명명된 판정으로 낸다.
# 이것이 없으면 항목 하나의 tar/cp 가 실패해도 루프가 계속되고, 실패한 것이 대표 파일이
# 아니면 최종 PASS 가 되어 "오류 없는 절차 완주" 주장이 거짓이 된다.
copy_failed=0
if ! cp "$PROJ/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md" "$WORK/preserve_FR.md"; then
  echo "  보존 대상 백업 실패" >&2; copy_failed=1
fi
sync_copy_step "$CLONE" "$PROJ" || copy_failed=1
if ! cp "$WORK/preserve_FR.md" "$PROJ/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"; then
  echo "  보존 대상 복원 실패" >&2; copy_failed=1
fi
check "5단계 복사 종료코드 0" "$copy_failed" "0"

echo "== 5단계 결과: consumer 에 필요한 파일이 들어왔는지 =="
check "self_test.sh 존재" \
  "$( [ -f "$PROJ/rd-workflow/scripts/self_test.sh" ] && echo yes || echo no )" "yes"
check "defect_reports.sh 존재" \
  "$( [ -f "$PROJ/rd-workflow/scripts/defect_reports.sh" ] && echo yes || echo no )" "yes"
check "루트 CLAUDE.md 존재" \
  "$( [ -f "$PROJ/CLAUDE.md" ] && echo yes || echo no )" "yes"
check "보존 대상 FUTURE_REQUESTS.md 가 덮이지 않음 (M009 결과 유지)" \
  "$(grep -c '^- `blocked`:' "$PROJ/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md")" "1"
check "sync 5단계가 workflow.json 을 배포함" \
  "$( [ -f "$PROJ/rd-workflow/config/workflow.json" ] && echo yes || echo no )" "yes"
check "배포된 workflow.json 의 default_execution_mode" \
  "$(json_str_value "$PROJ/rd-workflow/config/workflow.json" default_execution_mode)" "semi-auto"

echo "== 5.1: defect_report_upstream (sync 가 배포한 config) =="
( cd "$PROJ" && bash rd-workflow/scripts/defect_reports.sh set-upstream \
    "https://github.com/example/repo" ) > "$WORK/up.out" 2>&1
check "5.1 set-upstream 종료코드 0" "$?" "0"
check "5.1 이 defect_report_upstream 을 canonical 값으로 넣음" \
  "$(json_str_value "$PROJ/rd-workflow/config/workflow.json" defect_report_upstream)" "example/repo"
check "5.1 이후에도 default_execution_mode 가 유지됨" \
  "$(json_str_value "$PROJ/rd-workflow/config/workflow.json" default_execution_mode)" "semi-auto"

echo "== 6단계: 직후 self_test consumer =="
# 여기까지 sync 절차 밖에서 fixture 를 손댄 명령이 없다 = 중간 수동 교정 없음
( cd "$PROJ" && bash rd-workflow/scripts/self_test.sh consumer ) > "$WORK/consumer.out" 2>&1
CONSUMER_RC=$?
check "self_test.sh consumer 종료코드 0" "$CONSUMER_RC" "0"
if [[ "$CONSUMER_RC" != "0" ]]; then
  echo "--- consumer 실패 스텝 ---" >&2
  grep -E '^  -> FAIL|^FAIL |: FAIL' "$WORK/consumer.out" >&2 || tail -30 "$WORK/consumer.out" >&2
fi
check "인덱스 항목 보존" \
  "$(grep -c '^| 2026-01-01 | sample-item |' \
      "$PROJ/rd-workflow-workspace/backlog/FUTURE_REQUESTS.md")" "1"

echo "== 보존 시나리오 A: 기존 workflow.json (regular file) =="
# 사용자의 명시적 `manual` opt-out 이 조용히 지워지는 것이 이 변경 최대의 위험이므로,
# 값이 아니라 **byte** 를 비교합니다 — 「값은 맞는데 형식이 다시 쓰였다」도
# 「내용을 읽지도 고치지도 않는다」 계약 위반입니다. 그래서 fixture 에 다른 사용자 키·
# 고유한 들여쓰기·다른 키 순서를 함께 둡니다.
KEEP="$WORK/proj_keep"
mkdir -p "$KEEP/rd-workflow/config"
cat > "$KEEP/rd-workflow/config/workflow.json" <<'KEEPJSON'
{
      "review_tools_profile": "local",
  "default_execution_mode": "manual",
        "default_branch": "main"
}
KEEPJSON
cp "$KEEP/rd-workflow/config/workflow.json" "$WORK/keep_before.json"
sync_copy_step "$CLONE" "$KEEP"
check "A 복사 종료코드 0" "$?" "0"
check "A 기존 config 가 byte-for-byte 동일" \
  "$( cmp -s "$WORK/keep_before.json" "$KEEP/rd-workflow/config/workflow.json" \
        && echo same || echo differ )" "same"

# 5단계에서 멈추면 실사용과 다릅니다 — sync 는 이어서 5.1 을 돌리고, 그 절이 같은 경로를
# 씁니다. 여기서부터는 「byte 동일」이 아니라 「경로 종류·기존 줄 유지 + 그 키만 추가」가
# 계약입니다.
run_step51 "$KEEP" "$WORK/keep_up.out"
check "A 5.1 종료코드 0" "$?" "0"
check "A 5.1 후에도 regular file" \
  "$( [ -f "$KEEP/rd-workflow/config/workflow.json" ] \
      && [ ! -L "$KEEP/rd-workflow/config/workflow.json" ] && echo yes || echo no )" "yes"
check "A 5.1 이 defect_report_upstream 을 넣음" \
  "$(json_str_value "$KEEP/rd-workflow/config/workflow.json" defect_report_upstream)" "example/repo"
check "A 5.1 후 default_execution_mode 가 manual 그대로" \
  "$(json_str_value "$KEEP/rd-workflow/config/workflow.json" default_execution_mode)" "manual"
check "A 5.1 후 사용자 키 review_tools_profile 생존" \
  "$(json_str_value "$KEEP/rd-workflow/config/workflow.json" review_tools_profile)" "local"
check "A 5.1 후 사용자 키 default_branch 생존" \
  "$(json_str_value "$KEEP/rd-workflow/config/workflow.json" default_branch)" "main"
strip_upstream_line "$KEEP/rd-workflow/config/workflow.json" > "$WORK/keep_after_stripped.json"
check "A 5.1 이 추가한 것이 defect_report_upstream 줄뿐" \
  "$( cmp -s "$WORK/keep_before.json" "$WORK/keep_after_stripped.json" \
        && echo same || echo differ )" "same"

echo "== 보존 시나리오 B: dangling symlink =="
# `-e` 만 보면 "부재" 로 오판해 경로를 배포본(regular file)으로 덮어씁니다. 그러면
# 사용자의 링크가 사라지고, 판정 불가(manual)여야 할 상태가 조용히 semi-auto 로 올라갑니다.
DANG="$WORK/proj_dangling"
DANG_TARGET="../../../dotfiles-not-mounted/workflow.json"
mkdir -p "$DANG/rd-workflow/config"
ln -s "$DANG_TARGET" "$DANG/rd-workflow/config/workflow.json"
sync_copy_step "$CLONE" "$DANG"
check "B 복사 종료코드 0" "$?" "0"
check "B 경로가 여전히 symlink" \
  "$( [ -L "$DANG/rd-workflow/config/workflow.json" ] && echo yes || echo no )" "yes"
check "B 링크 대상이 그대로" \
  "$(readlink "$DANG/rd-workflow/config/workflow.json")" "$DANG_TARGET"

# 5.1 은 `[ -f ]` 검사에서 걸러져(dangling 은 거짓) 아무것도 쓰지 않고 종료 0 이어야 합니다.
# 여기서 파일을 만들어 버리면 링크가 실체를 얻어, 마운트되면 나타날 사용자 설정을 가립니다.
run_step51 "$DANG" "$WORK/dang_up.out"
check "B 5.1 종료코드 0" "$?" "0"
check "B 5.1 후에도 dangling symlink" \
  "$( [ -L "$DANG/rd-workflow/config/workflow.json" ] \
      && [ ! -e "$DANG/rd-workflow/config/workflow.json" ] && echo yes || echo no )" "yes"
check "B 5.1 후 링크 대상이 그대로" \
  "$(readlink "$DANG/rd-workflow/config/workflow.json")" "$DANG_TARGET"

echo "== 보존 시나리오 C: 유효 symlink =="
# B 와 중복이 아닙니다 — B 는 `-L` 누락(경로가 새 파일로 바뀜)을, C 는 sync 가 링크를
# **역참조해 target 내용을 덮는** 결함을 잡습니다. 후자는 target 이 없는 B 에서는
# 일어날 수 없습니다. (`readlink -f` 등 GNU 전용 옵션은 쓰지 않습니다 — 대상은 macOS 입니다.)
LNK="$WORK/proj_symlink"
LNK_TARGET="../../dotfiles/workflow.json"
mkdir -p "$LNK/rd-workflow/config" "$LNK/dotfiles"
cat > "$LNK/dotfiles/workflow.json" <<'LNKJSON'
{
        "default_branch": "main",
  "default_execution_mode": "manual",
    "review_tools_profile": "local"
}
LNKJSON
cp "$LNK/dotfiles/workflow.json" "$WORK/symlink_target_before.json"
ln -s "$LNK_TARGET" "$LNK/rd-workflow/config/workflow.json"
sync_copy_step "$CLONE" "$LNK"
check "C 복사 종료코드 0" "$?" "0"
check "C 경로가 여전히 symlink" \
  "$( [ -L "$LNK/rd-workflow/config/workflow.json" ] && echo yes || echo no )" "yes"
check "C 링크 대상이 그대로" \
  "$(readlink "$LNK/rd-workflow/config/workflow.json")" "$LNK_TARGET"
check "C target 파일 내용이 그대로" \
  "$( cmp -s "$WORK/symlink_target_before.json" "$LNK/dotfiles/workflow.json" \
        && echo same || echo differ )" "same"

# 5.1 은 이 경로를 실제로 씁니다(`[ -f ]` 가 링크를 따라가 참). 링크를 regular file 로
# 갈아치우지 않고 **최종 referent 를 해석해 그 옆에 만든 임시 파일을 원자 교체**해야 사용자의
# 링크와 원본이 모두 남습니다. 링크를 통해 내용을 흘려보내면(`> 링크경로`) 쓰기 도중 실패했을
# 때 원본이 부분 훼손되므로 그 방식은 쓰지 않습니다.
run_step51 "$LNK" "$WORK/lnk_up.out"
check "C 5.1 종료코드 0" "$?" "0"
check "C 5.1 후에도 symlink" \
  "$( [ -L "$LNK/rd-workflow/config/workflow.json" ] && echo yes || echo no )" "yes"
check "C 5.1 후 링크 대상이 그대로" \
  "$(readlink "$LNK/rd-workflow/config/workflow.json")" "$LNK_TARGET"
check "C 5.1 후 target 파일이 살아 있음" \
  "$( [ -f "$LNK/dotfiles/workflow.json" ] && echo yes || echo no )" "yes"
check "C 5.1 이 defect_report_upstream 을 넣음" \
  "$(json_str_value "$LNK/dotfiles/workflow.json" defect_report_upstream)" "example/repo"
check "C 5.1 후 default_execution_mode 가 manual 그대로" \
  "$(json_str_value "$LNK/dotfiles/workflow.json" default_execution_mode)" "manual"
check "C 5.1 후 사용자 키 review_tools_profile 생존" \
  "$(json_str_value "$LNK/dotfiles/workflow.json" review_tools_profile)" "local"
strip_upstream_line "$LNK/dotfiles/workflow.json" > "$WORK/symlink_target_after_stripped.json"
check "C 5.1 이 추가한 것이 defect_report_upstream 줄뿐" \
  "$( cmp -s "$WORK/symlink_target_before.json" "$WORK/symlink_target_after_stripped.json" \
        && echo same || echo differ )" "same"

# 임시 clone 정리 — 삭제 직전에 조건을 다시 확인한다. 이 지점에 오기까지 clone 부모의
# 내용은 바뀌지 않지만(5단계는 clone 에서 읽기만 한다), 재귀 삭제 앞에서 존재 여부만 보고
# 넘어가지 않는 것이 요점이다.
if is_disposable_clone "$CLONE"; then
  rm -rf "$(dirname "$CLONE")"
else
  echo "임시 clone 정리를 건너뜁니다 (폐기 가능 조건 불충족): '$CLONE'" >&2
fi

if [[ "$fail" -ne 0 ]]; then echo "acceptance_sync_once: FAIL"; exit 1; fi
echo "acceptance_sync_once: PASS"
