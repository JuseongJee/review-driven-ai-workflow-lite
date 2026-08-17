#!/usr/bin/env bash
set -euo pipefail

# 템플릿 버전 가드
# 배포 repo를 임시 clone하고, 로컬 VERSION과 비교하여 다운그레이드를 방지한다.
# 버전 비교 전에 템플릿 타입(full/lite)을 대조하여 교차 다운그레이드를 차단한다.
# 통과 시 임시 clone 경로를 stdout에 출력한다.
#
# 사용법: sync_template.sh <배포 repo URL> [--force] [--allow-type-mismatch]

REPO_URL=""
FORCE=""
ALLOW_TYPE_MISMATCH=""

# --print-upstream <url>: URL → defect_report_upstream canonical 값 (부작용 없음)
# github.com 이면 owner/repo, 그 외 host 면 host/owner/repo. 미지원 문법은 빈 출력 + exit 1.
if [[ "${1:-}" == "--print-upstream" ]]; then
  raw="${2:-}"
  [[ -z "$raw" ]] && exit 1
  host=""; path=""
  if [[ "$raw" =~ ^[A-Za-z0-9._-]+@([A-Za-z0-9][A-Za-z0-9.-]*):(.+)$ ]]; then   # scp 형식
    host="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^https://([^/]+)/(.+)$ ]]; then                            # https 만 허용
    host="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
    host="${host##*@}"                                                         # credential 제거
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || exit 1
  else
    exit 1
  fi
  path="${path%/}"; path="${path%.git}"; path="${path%/}"                      # / → .git → / 순으로 제거
  # owner/repo 정확히 2세그먼트, 안전한 문자만 (공백·? ·# ·제어문자 거부)
  [[ "$path" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || exit 1
  if [[ "$host" == "github.com" ]]; then printf '%s\n' "$path"
  else printf '%s/%s\n' "$host" "$path"; fi
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE="1"; shift ;;
    --allow-type-mismatch) ALLOW_TYPE_MISMATCH="1"; shift ;;
    -*) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    *) REPO_URL="$1"; shift ;;
  esac
done

if [[ -z "$REPO_URL" ]]; then
  echo "사용법: sync_template.sh <배포 repo URL> [--force] [--allow-type-mismatch]" >&2
  exit 1
fi

# 프로젝트 루트 감지 (rd-workflow/scripts/ 기준으로 2단계 위)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# VERSION 값 → 템플릿 타입 (full | lite | unknown)
# 엄격한 형식 매칭 — 빈 값·형식 불일치는 unknown (타입 미확정, fail-closed)
template_type_of() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
    echo "full"
  elif [[ "$v" =~ ^lite-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]; then
    echo "lite"
  else
    echo "unknown"
  fi
}

# 임시 clone
CLONE_DIR="$(mktemp -d)"
# 성공 시 cleanup은 호출자(sync_template.md 6단계)가 담당
# 실패 시 스크립트가 self-cleanup
cleanup_on_failure() { rm -rf "$CLONE_DIR"; }
trap 'cleanup_on_failure' ERR

echo "--- 템플릿 소스 clone ---" >&2
git clone --depth 1 --quiet "$REPO_URL" "$CLONE_DIR/template"

# rd-workflow/ 우선, ai/ fallback (구버전 배포 repo 호환)
if [[ -f "$CLONE_DIR/template/rd-workflow/VERSION" ]]; then
  REMOTE_VERSION_FILE="$CLONE_DIR/template/rd-workflow/VERSION"
elif [[ -f "$CLONE_DIR/template/ai/VERSION" ]]; then
  REMOTE_VERSION_FILE="$CLONE_DIR/template/ai/VERSION"
else
  REMOTE_VERSION_FILE="$CLONE_DIR/template/rd-workflow/VERSION"
fi
# rd-workflow/ 우선, ai/ fallback (M001 마이그레이션 전 프로젝트 호환)
if [[ -f "$PROJECT_ROOT/rd-workflow/VERSION" ]]; then
  LOCAL_VERSION_FILE="$PROJECT_ROOT/rd-workflow/VERSION"
elif [[ -f "$PROJECT_ROOT/ai/VERSION" ]]; then
  LOCAL_VERSION_FILE="$PROJECT_ROOT/ai/VERSION"
else
  LOCAL_VERSION_FILE="$PROJECT_ROOT/rd-workflow/VERSION"
fi

# VERSION 파일 읽기 (없으면 빈 문자열)
REMOTE_VERSION=""
LOCAL_VERSION=""

if [[ -f "$REMOTE_VERSION_FILE" ]]; then
  REMOTE_VERSION="$(cat "$REMOTE_VERSION_FILE")"
fi

if [[ -f "$LOCAL_VERSION_FILE" ]]; then
  LOCAL_VERSION="$(cat "$LOCAL_VERSION_FILE")"
fi

# 템플릿 타입 가드 — 버전 비교 전에 full/lite 타입을 대조한다 (교차 다운그레이드 방지)
# 타입 미확정(unknown)은 타입 일치로 간주하지 않는다 (fail-closed).
# --allow-type-mismatch 는 불일치·미확정 케이스에서만 효력이 있다 —
# same-type 에서는 알림만 출력하고 기존 버전 가드(다운그레이드 차단 + --force)를 그대로 적용한다.
REMOTE_TYPE="$(template_type_of "$REMOTE_VERSION")"
LOCAL_TYPE="$(template_type_of "$LOCAL_VERSION")"
TYPE_GUARD_BYPASSED=""

type_guard_bypass_warn() {
  echo "" >&2
  echo "경고: --allow-type-mismatch 지정됨 — 템플릿 타입 가드와 버전 비교를 건너뜁니다." >&2
  echo "타입이 다른 템플릿을 sync하면 현재 타입 전용 파일이 삭제 후보로 분류될 수 있습니다." >&2
}

if [[ "$REMOTE_TYPE" == "unknown" || "$LOCAL_TYPE" == "unknown" ]]; then
  if [[ -n "$ALLOW_TYPE_MISMATCH" ]]; then
    type_guard_bypass_warn
    TYPE_GUARD_BYPASSED="1"
  else
    echo "" >&2
    echo "오류: 템플릿 타입을 확정할 수 없습니다 — 로컬 VERSION: '${LOCAL_VERSION:-없음}', 원격 VERSION: '${REMOTE_VERSION:-없음}'" >&2
    echo "VERSION이 없거나 형식이 규약(YYYY-MM-DD-HHMMSS | lite-YYYY-MM-DD-HHMMSS)과 다릅니다." >&2
    echo "진행하려면 VERSION 상태를 확인한 뒤 --allow-type-mismatch 를 사용하세요." >&2
    cleanup_on_failure
    exit 1
  fi
elif [[ "$REMOTE_TYPE" != "$LOCAL_TYPE" ]]; then
  if [[ -n "$ALLOW_TYPE_MISMATCH" ]]; then
    type_guard_bypass_warn
    TYPE_GUARD_BYPASSED="1"
  else
    echo "" >&2
    echo "오류: 템플릿 타입 불일치 — 로컬: ${LOCAL_TYPE}(${LOCAL_VERSION}), 원격: ${REMOTE_TYPE}(${REMOTE_VERSION})" >&2
    echo "타입이 다른 템플릿을 sync하면 현재 타입 전용 파일이 삭제 후보로 분류될 수 있습니다." >&2
    echo "배포 repo URL이 올바른지 먼저 확인하세요. 의도한 교차 적용/복구라면 --allow-type-mismatch 를 사용하세요." >&2
    cleanup_on_failure
    exit 1
  fi
elif [[ -n "$ALLOW_TYPE_MISMATCH" ]]; then
  echo "알림: 템플릿 타입이 일치하므로 --allow-type-mismatch 는 효과가 없습니다. 기존 버전 가드를 그대로 적용합니다." >&2
fi

# 비교
if [[ -z "$TYPE_GUARD_BYPASSED" && -n "$REMOTE_VERSION" && -n "$LOCAL_VERSION" ]]; then
  # VERSION 형식: YYYY-MM-DD-HHMMSS (고정 너비, 사전순 == 시간순)
  if [[ "$REMOTE_VERSION" < "$LOCAL_VERSION" ]]; then
    echo "" >&2
    echo "경고: 원격 템플릿($REMOTE_VERSION)이 로컬($LOCAL_VERSION)보다 오래되었습니다." >&2
    echo "다운그레이드하면 최신 변경사항이 사라질 수 있습니다." >&2

    if [[ -n "$FORCE" ]]; then
      echo "--force 지정됨. 계속 진행합니다." >&2
    else
      echo "강제 진행하려면 --force를 사용하세요." >&2
      cleanup_on_failure
      exit 1
    fi
  fi
fi

echo "" >&2
echo "버전 확인 통과 (원격: ${REMOTE_VERSION:-없음}, 로컬: ${LOCAL_VERSION:-없음})" >&2
echo "$CLONE_DIR/template"
