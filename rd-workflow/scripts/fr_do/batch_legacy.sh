#!/usr/bin/env bash
# /fr batch 별칭용 안내. 남은 batch manifest 가 있으면 이어 처리할 slug 를 보입니다. 안내 전용이라 rc 는 항상 0 입니다.
# 사용: bash rd-workflow/scripts/fr_do/batch_legacy.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_state.sh"
echo "/fr batch 는 /fr do --headless 로 바뀌었습니다. 이번 배포까지 별칭으로 동작하고 다음 배포에서 없어집니다."
echo "발행 기본값은 push(원격까지)입니다 — --finish merge 로 바꿀 수 있습니다."
root="$(fr_do_main_root)" || exit 0
mf="$root/rd-workflow-workspace/.batch-manifest.json"
[[ -f "$mf" ]] || exit 0
python3 -I - "$mf" <<'PY' || true
import json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        m = json.load(f)
    if m.get("status") in ("preparing", "running", "paused"):
        rest = [i for i in m["items"]
                if i.get("state") != "completed" and i.get("feasibility") != "excluded"]
        rest.sort(key=lambda i: i.get("order", 0))
        if rest:
            print("남은 batch manifest 를 발견했습니다 — 남은 항목은 /fr do <slug들> 로 이어 처리하십시오: "
                  + " ".join(i["slug"] for i in rest))
except Exception:
    print(f"남은 batch manifest 를 읽지 못했습니다: {path} — 직접 열어 남은 항목을 확인하십시오")
PY
exit 0
