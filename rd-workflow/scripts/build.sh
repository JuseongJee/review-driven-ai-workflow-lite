#!/usr/bin/env bash
# TEMPLATE_STUB
set -euo pipefail

echo "rd-workflow/scripts/build.sh를 프로젝트에 맞는 실제 build 명령으로 수정하세요." >&2
exit 1
# 예:
# npm run build
# pnpm build
# xcodebuild -scheme MyApp -configuration Debug build
#
# 안내:
# - build 실패는 verify 게이트 실패로 전파됩니다 (test/lint/typecheck/build 4종 게이트).
# - stale 산출물에 의존하지 않는 빌드를 권장합니다 (예: clean 후 빌드, 캐시 무효화).
# - 빌드 개념이 없는 프로젝트는 no-op으로 교체하세요:
#   echo "이 프로젝트에서는 사용하지 않습니다" && exit 0
# - typecheck와 사실상 동일 명령이면 그 명령을 재사용해도 됩니다.
