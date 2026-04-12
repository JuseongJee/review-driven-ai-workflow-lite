#!/usr/bin/env bash
set -euo pipefail

# 템플릿 버전 가드
# 배포 repo를 임시 clone하고, 로컬 VERSION과 비교하여 다운그레이드를 방지한다.
# 통과 시 임시 clone 경로를 stdout에 출력한다.
#
# 사용법: sync_template.sh <배포 repo URL> [--force]

REPO_URL=""
FORCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE="1"; shift ;;
    -*) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    *) REPO_URL="$1"; shift ;;
  esac
done

if [[ -z "$REPO_URL" ]]; then
  echo "사용법: sync_template.sh <배포 repo URL> [--force]" >&2
  exit 1
fi

# 프로젝트 루트 감지 (rd-workflow/scripts/ 기준으로 2단계 위)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# 비교
if [[ -n "$REMOTE_VERSION" && -n "$LOCAL_VERSION" ]]; then
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
