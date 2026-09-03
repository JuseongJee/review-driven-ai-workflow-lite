#!/usr/bin/env bash
# acceptance_sync_once.sh — 종단 수용 검증 (REQUEST AC 13)
#
# 세 사전조건을 함께 가진 설치본 fixture 에 sync 절차를 1회 수행하고, 중간 수동 교정 없이
# 직후 self_test.sh consumer 가 통과하는지 판정한다.
#
#   (1) blocked 서술이 없는 구형 FUTURE_REQUESTS.md + 인덱스 항목 1건
#   (2) 설치본 레이아웃 (<proj>/rd-workflow/scripts)
#   (3) rd-workflow/config/workflow.json 부재
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

# 디렉터리 내용을 대상에 병합 복사한다 (cp -R 의 "이미 있으면 안으로 넣기" 함정 회피).
copy_into() { # $1=src dir  $2=dst dir
  mkdir -p "$2"
  ( cd "$1" && tar cf - . ) | ( cd "$2" && tar xf - )
}

# 임시 작업 디렉터리는 **경로를 파생하기 전에** fail-closed 로 확정한다.
# `set -e` 를 쓰지 않는 스크립트이므로 `mktemp` 가 실패해도 멈추지 않고, 그러면 WORK 가 빈
# 문자열이 되어 REMOTE=/remote · PROJ=/proj 로 계산된다. 권한이 있는 CI·컨테이너에서는
# 루트 바로 아래에 실제 파일을 만들면서도 trap 은 빈 경로만 받아 정리하지 못한다.
WORK="$(mktemp -d 2>/dev/null)" || WORK=""
if [[ -z "$WORK" || ! -d "$WORK" ]]; then
  echo "acceptance_sync_once: 임시 작업 디렉터리 생성 실패 — 경로를 파생하지 않고 중단합니다." >&2
  echo "  mktemp -d 가 실패했습니다 (TMPDIR='${TMPDIR:-}')." >&2
  exit 1
fi
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
# (3) workflow.json 을 두지 않는다 (config 디렉터리도 만들지 않는다)

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
for base in $(cd "$CLONE" && ls -A | grep -v '^\.git$'); do
  if [[ -d "$CLONE/$base" ]]; then
    if ! copy_into "$CLONE/$base" "$PROJ/$base"; then
      echo "  복사 실패(디렉터리): $base" >&2; copy_failed=1
    fi
  else
    if ! cp "$CLONE/$base" "$PROJ/$base"; then
      echo "  복사 실패(파일): $base" >&2; copy_failed=1
    fi
  fi
done
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

echo "== 5.1: defect_report_upstream (config 부재) =="
( cd "$PROJ" && bash rd-workflow/scripts/defect_reports.sh set-upstream \
    "https://github.com/example/repo" ) > "$WORK/up.out" 2>&1
check "5.1 set-upstream 종료코드 0" "$?" "0"
check "5.1 이 config 를 만들지 않음" \
  "$( [ -e "$PROJ/rd-workflow/config/workflow.json" ] && echo exists || echo absent )" "absent"

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
