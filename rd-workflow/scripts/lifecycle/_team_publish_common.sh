#!/usr/bin/env bash
# _team_publish_common.sh — overlay 마감 때 submodule 의 팀 저장소 PR 반영에 쓰는 공용 함수.
#   rd pr open · rd pr check · archive 게이트 · rd task list 가 이 이름 그대로 부릅니다.
#   Spec: rd-workflow-workspace/specs/changes/2026-11-16-1330-publish-via-pull-request-change-spec.md (D1·D2·D4·D8·D9·D14)
#
# 이 파일은 source 되기만 합니다. 부르는 쪽이 먼저 아래 순서로 source 해야 합니다.
#   1. lifecycle/_lifecycle_common.sh   (→ _state_common.sh 를 함께 source)
#   2. _state_common.sh                 (RD_TEAM_PR_RECORD · rd_team_pr_preserved)
#   3. _submodule_common.sh             (_rd_run_limited)
#   4. lifecycle/_tasks_index.sh        (tasks_index_get)
#   5. lifecycle/_team_publish_common.sh
#
# 종료 코드: 성공 0, 실패 1, 사용법·판정 불가 2, light-check 상향 3, 사용자 승인 필요 10 (호출부가 씀)
# 환경 변수: RD_PR_CHECK_TIMEOUT (gh 조회 상한 초, 기본 15)
#
# bash 3.2 호환: 연관 배열·${var,,} 를 쓰지 않는다.

_TP_NOTICED="${_TP_NOTICED:-}"
_TP_RECORD_FIELDS="path repo branch base url head-oid state merged-oid commits"

_tp_cfg_file() { printf '%s/rd-workflow/config/workflow.json\n' "${1%/}"; }

# tp_config_present <root> — workflow.json 에 team_publish 키가 있으면 rc 0, 없거나 읽을 수 없으면 rc 1.
tp_config_present() {
  local f; f="$(_tp_cfg_file "${1:?root}")"
  [[ -f "$f" ]] || return 1
  python3 -I - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and "team_publish" in d else 1)
PY
}

# tp_config <root> <submodule-path|""> <key> — key ∈ mode|base|branch_prefix|light.
# 우선순위: submodules.<경로> → 전역 → 기본값(mode=pr, base="", branch_prefix="", light=pr).
# 잘못된 값(mode ∉ pr|push|manual, light ∉ pr|merge)·파싱 실패·알 수 없는 key 는 rc 2 (조용히 manual 로 흡수하지 않음).
tp_config() {
  local root="${1:?root}" sub="${2-}" key="${3:?key}" f out rc
  f="$(_tp_cfg_file "$root")"
  case "$key" in mode|base|branch_prefix|light) ;; *) printf 'tp_config: 알 수 없는 key: %s\n' "$key" >&2; return 2 ;; esac
  out="$(python3 -I - "$f" "$sub" "$key" <<'PY'
import json, os, sys
f, sub, key = sys.argv[1], sys.argv[2], sys.argv[3]
defaults = {"mode": "pr", "base": "", "branch_prefix": "", "light": "pr"}
allowed = {"mode": ("pr", "push", "manual"), "light": ("pr", "merge")}
def bad(msg):
    sys.stderr.write("team_publish 설정 오류: %s\n" % msg); sys.exit(2)
if not os.path.exists(f):
    print(defaults[key]); sys.exit(0)
try:
    d = json.load(open(f, encoding="utf-8"))
except Exception:
    bad("workflow.json 을 읽을 수 없습니다")
if not isinstance(d, dict):
    bad("workflow.json 최상위가 객체가 아닙니다")
tp = d.get("team_publish", {})
if not isinstance(tp, dict):
    bad("team_publish 가 객체가 아닙니다")
def check(k, v, where):
    if k in allowed:
        if v not in allowed[k]:
            bad("%s.%s 값 %r 은 허용 값 %s 이 아닙니다" % (where, k, v, "|".join(allowed[k])))
    elif not isinstance(v, str):
        bad("%s.%s 는 문자열이어야 합니다" % (where, k))
for k in defaults:
    if k in tp:
        check(k, tp[k], "team_publish")
subs = tp.get("submodules", {})
if not isinstance(subs, dict):
    bad("team_publish.submodules 가 객체가 아닙니다")
sv = subs.get(sub) if sub else None
if sub and sv is not None:
    if not isinstance(sv, dict):
        bad("team_publish.submodules.%s 가 객체가 아닙니다" % sub)
    for k in defaults:
        if k in sv:
            check(k, sv[k], "team_publish.submodules.%s" % sub)
if isinstance(sv, dict) and key in sv:
    print(sv[key])
elif key in tp:
    print(tp[key])
else:
    print(defaults[key])
PY
)"; rc=$?
  [[ "$rc" == 0 ]] || return 2
  printf '%s\n' "$out"
}

# tp_notice_default <root> — team_publish 키가 없으면 D8 안내를 stderr 로 프로세스당 한 번 냅니다.
# (명령 치환 안에서 부르면 부모 셸의 표시가 남지 않으므로, 부르는 쪽은 치환 밖에서 부릅니다.)
tp_notice_default() {
  [[ -n "$_TP_NOTICED" ]] && return 0
  # 설정 파일을 읽을 수 없거나 값이 잘못되면(tp_config rc 2) 안내하지 않습니다 — 호출부가 tp_config 의 오류로 멈춥니다.
  tp_config "${1:?root}" "" mode >/dev/null 2>&1 || return 0
  tp_config_present "$1" && return 0
  _TP_NOTICED=1
  printf '%s\n' '이번부터 마감 때 팀 저장소에 PR 을 올립니다(기본 반영 방식 pr). 이전 방식은 rd-workflow/config/workflow.json 의 team_publish.mode 를 manual 로 설정하십시오.' >&2
}

# _tp_gitlink_changes <root> <a> <b> [<mode>] — a 와 b 사이에 gitlink 가 바뀐 경로를 `path<TAB>old-oid<TAB>new-oid` 로.
# .gitmodules 의 ignore 설정과 무관하게 셉니다(--ignore-submodules=none). -z 출력은 NUL 경계 그대로 읽습니다 —
# 개행으로 바꾸면 경로 안의 개행이 메타데이터와 경로의 짝을 어긋나게 합니다. 비교 실패는 rc 2.
# <mode>:
#   (없음) 모든 gitlink 변경을 냅니다.
#   paths  출력 없이 바뀐 gitlink 경로를 배열 _TP_GL_SET 에 더합니다(경로 그대로 — 표현 검사 없음).
#   only   _TP_GL_SET 에 있는 경로의 변경만 냅니다.
# 내는 경로에 탭·개행이 있으면 출력 형식으로 나타낼 수 없어 원인 한 줄(stderr)과 rc 2(출력 없음)입니다. 내지 않는 경로는 검사하지 않습니다.
_tp_gitlink_changes() {
  local root="$1" a="$2" b="$3" mode="${4-}" tmpf meta path o n m1 m2 rest rc=0 i hit out=""
  tmpf="$(mktemp "${TMPDIR:-/tmp}/rd-tpdt.XXXXXX")" || return 2
  git -C "$root" diff-tree -r -z --no-renames --ignore-submodules=none "$a" "$b" >"$tmpf" 2>/dev/null || { rm -f "$tmpf"; return 2; }
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    [[ "$meta" == :* ]] || continue
    # :oldmode newmode oldoid newoid status
    m1="${meta%% *}"; rest="${meta#* }"; m2="${rest%% *}"; rest="${rest#* }"
    o="${rest%% *}"; rest="${rest#* }"; n="${rest%% *}"
    [[ "$m1" == ":160000" || "$m2" == "160000" ]] || continue
    if [[ "$mode" == paths ]]; then
      _TP_GL_SET[${#_TP_GL_SET[@]}]="$path"; continue
    fi
    if [[ "$mode" == only ]]; then
      hit=0
      for ((i = 0; i < ${#_TP_GL_SET[@]}; i++)); do
        [[ "${_TP_GL_SET[$i]}" == "$path" ]] && { hit=1; break; }
      done
      [[ "$hit" == 1 ]] || continue
    fi
    case "$path" in
      *$'\n'*|*$'\t'*)
        printf 'tp_targets: gitlink 경로에 탭·개행이 있어 반영 대상을 판정할 수 없습니다: %q\n' "$path" >&2
        rc=2; break ;;
    esac
    # 한쪽만 gitlink 인 형식 변경(submodule ↔ 일반 파일·심볼릭 링크)은 gitlink 가 아닌 쪽을 「없음」(0)으로 봅니다.
    # 그 쪽 OID 는 blob 이라 반영할 포인터가 아닙니다.
    [[ "$m1" == ":160000" ]] || o="${o//?/0}"
    [[ "$m2" == "160000" ]] || n="${n//?/0}"
    out="${out}${path}"$'\t'"${o}"$'\t'"${n}"$'\n'
  done <"$tmpf"
  rm -f "$tmpf"
  # 판정 불가면 앞서 모은 줄도 내지 않습니다(일부만 보이면 빈 대상과 같은 오판을 부릅니다).
  [[ "$rc" != 0 ]] || printf '%s' "$out"
  return "$rc"
}

# tp_targets <root> <base-commit> <tip> [<reviewed-head>] — gitlink 가 바뀐 최상위 submodule 을 `path<TAB>old-oid<TAB>new-oid` 로.
# 추가·삭제·변경 모두 셉니다(없는 쪽과 gitlink 가 아닌 쪽은 0 으로 채운 OID). 판정 불가(커밋을 못 읽음)는 rc 2.
# <reviewed-head>(tp_reviewed_head 의 값)가 있으면 대상 「경로」는 리뷰한 범위(base..reviewed-head)에서 gitlink 가 바뀐
# 경로로 한정하고, 「포인터 값」은 base..tip 에서 읽습니다(old 는 기준점, new 는 tip 의 값 — rd pr check --apply 가 옮긴
# 포인터를 archive 가 확인할 수 있게). 리뷰 뒤 병합으로 들어온 다른 submodule 변경은 대상이 아닙니다.
# 범위는 경로 그대로(NUL 경계) 먼저 한정하고 탭·개행 검사는 실제 대상 경로에만 합니다 — 범위 밖 경로가 정상 대상을 막지 않습니다.
# tip 의 값이 기준점과 같아진 경로는 내지 않습니다(반영할 변경 없음).
tp_targets() {
  local root="${1:?root}" base="${2:?base}" tip="${3:?tip}" rh="${4-}"
  local -a _TP_GL_SET=()
  git -C "$root" rev-parse --verify -q "${base}^{commit}" >/dev/null 2>&1 || return 2
  git -C "$root" rev-parse --verify -q "${tip}^{commit}" >/dev/null 2>&1 || return 2
  if [[ -z "$rh" ]]; then
    _tp_gitlink_changes "$root" "$base" "$tip" || return 2
    return 0
  fi
  git -C "$root" rev-parse --verify -q "${rh}^{commit}" >/dev/null 2>&1 || return 2
  _tp_gitlink_changes "$root" "$base" "$rh" paths || return 2
  [[ "${#_TP_GL_SET[@]}" -gt 0 ]] || return 0
  _tp_gitlink_changes "$root" "$base" "$tip" only || return 2
  return 0
}

# 판정 기준(rd pr open·check·archive 게이트·rd task list 공통): 대상은 tp_target_base 가 정한 기준점부터 tip 까지이고
# (seal 마커로 정했으면 경로는 리뷰한 끝 커밋까지 바뀐 것만 — tp_reviewed_head),
# 설정은 tip 의 rd-workflow/config/workflow.json 입니다. 기준점은 리뷰한 범위입니다 — tip 의 seal 마커 기준점(review-base,
# 없으면 tip 의 SESSION.md review-base-oid), 마커가 없거나 기준점이 없는 옛 마커면 fr 은 merge-base(기본 브랜치, tip),
# 그다음 tip 의 task-state base-commit 순입니다. 모두 tip 커밋에서 읽고 작업 worktree 의 파일은 보지 않습니다.

# _tp_tip_file <root> <tip> <path> — tip 커밋의 파일 본문(없으면 빈 값, rc 1).
_tp_tip_file() { git -C "$1" show "${2}:${3}" 2>/dev/null; }

# _tp_kv <key> — stdin 의 `key=value` 줄에서 첫 값.
_tp_kv() { awk -F= -v k="$1" '$1==k{sub(/^[^=]+=/,""); print; exit}'; }

# _tp_valid_base <root> <oid> <tip> — oid 가 커밋이고 tip 의 조상이면 rc 0 과 전체 OID. 커밋 아님 rc 1, 조상 아님 rc 3.
_tp_valid_base() {
  local full
  full="$(git -C "$1" rev-parse --verify -q "${2}^{commit}" 2>/dev/null)" || return 1
  git -C "$1" merge-base --is-ancestor "$full" "$3" 2>/dev/null || return 3
  printf '%s\n' "$full"
}

# _tp_tip_default_branch <root> <tip> — 기본 브랜치를 작업 트리 설정 없이 정합니다(spec D2-1 2순위).
# tip 의 workflow.json default_branch → 비면 설정 파일 없이 get_default_branch 의 나머지 체인(origin/HEAD → main/master 유일).
_tp_tip_default_branch() {
  local root="$1" tip="$2" b empty rc=0
  b="$(_tp_tip_file "$root" "$tip" rd-workflow/config/workflow.json \
    | sed -n 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  empty="$(mktemp -d "${TMPDIR:-/tmp}/rd-tpdb.XXXXXX")" || return 1
  b="$(cd "$root" && project_root="$empty" get_default_branch 2>/dev/null)" || rc=1
  rmdir "$empty" 2>/dev/null
  [[ "$rc" == 0 && -n "$b" ]] || return 1
  printf '%s\n' "$b"
}

# tp_target_base <root> <tip> <fr-branch 값> — 반영 대상 기준점(spec D2-1). stdout 기준 커밋 OID, rc 0.
# 정하지 못하면 rc 2 와 stderr 의 원인·다음 행동. 순위:
#   1. (두 모드) tip 의 task-state review-session S 와 seal 마커 S.seal 이 있으면 마커 review-base → tip 의 SESSION.md
#      review-base-oid. 기록된 값이 커밋이 아니거나 tip 의 조상이 아니면 rc 2(아래 순위로 내려가지 않음).
#      이 순위로 정하면 마커의 리뷰한 끝 커밋(review-head=, 없는 옛 마커는 head=)도 같은 조건을 거칩니다(어기면 rc 2).
#      대상 경로는 기준점..리뷰한 끝으로 한정합니다(tp_reviewed_head → tp_targets 넷째 인자). 끝 정보가 없는 마커는 한정하지 않습니다.
#      둘 다 없으면(옛 마커) 경고 한 줄을 내고 2·3순위로 갑니다.
#   2. (fr) merge-base <기본 브랜치> <tip>
#   3. tip 의 task-state base-commit
# 각 후보는 커밋이고 tip 의 조상이어야 합니다.
_TP_NEW_SESSION_HINT='tip 의 조상 중 리뷰할 범위의 기준 커밋 <ref> 로 새 세션을 여십시오: bash rd-workflow/scripts/prepare_review_pipeline.sh diff --base <ref> — 종결한 뒤 bash rd-workflow/scripts/rd review seal <새 세션 경로> 를 실행하고, task-state(review-session)와 새 마커를 커밋한 뒤 다시 실행하십시오'

# _tp_seal_range <root> <tip> — tip 의 task-state review-session S 의 seal 마커를 읽어 _TP_MS(S)·_TP_MRB(리뷰 기준점: 마커
# review-base → tip 의 SESSION.md review-base-oid)·_TP_MHEAD(리뷰한 끝 커밋: 마커 review-head= → 옛 마커는 head=)에 둡니다. 마커가 있으면 rc 0, 없으면 rc 1.
# tp_target_base 와 tp_reviewed_head 가 같은 마커 판정을 쓰도록 한 곳에 둡니다. 명령 치환 밖에서 부릅니다.
_TP_MS=""; _TP_MRB=""; _TP_MHEAD=""
_tp_seal_range() {
  local root="$1" tip="$2" s marker
  _TP_MS=""; _TP_MRB=""; _TP_MHEAD=""
  s="$(_tp_tip_file "$root" "$tip" rd-workflow-workspace/.lifecycle/task-state | _tp_kv review-session || true)"
  case "$s" in ""|null|*/*|*..*) return 1 ;; esac
  git -C "$root" cat-file -e "${tip}:rd-workflow-workspace/.lifecycle/review-seals/${s}.seal" 2>/dev/null || return 1
  marker="$(_tp_tip_file "$root" "$tip" "rd-workflow-workspace/.lifecycle/review-seals/${s}.seal" || true)"
  _TP_MS="$s"
  _TP_MRB="$(printf '%s\n' "$marker" | _tp_kv review-base)"
  # 리뷰한 끝은 마커 review-head=(seal 이 검증한 세션의 review-head-oid)를 먼저 씁니다. head= 는 seal 시점 HEAD 라
  # 리뷰 대상을 고정한 뒤 seal 전에 병합한 커밋까지 담습니다. review-head= 가 없는 옛 마커만 head= 를 씁니다.
  _TP_MHEAD="$(printf '%s\n' "$marker" | _tp_kv review-head)"
  [[ -n "$_TP_MHEAD" ]] || _TP_MHEAD="$(printf '%s\n' "$marker" | _tp_kv head)"
  if [[ -z "$_TP_MRB" ]]; then
    _TP_MRB="$(_tp_tip_file "$root" "$tip" "rd-workflow-workspace/handoffs/review_pipeline/${s}/SESSION.md" \
      | awk 'index($0, "- review-base-oid:") == 1 { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit }' || true)"
  fi
  return 0
}

# tp_reviewed_head <root> <tip> — 반영 대상 경로를 한정할 리뷰한 끝 커밋(tp_targets 의 넷째 인자). tp_target_base 가 1순위
# (seal 마커의 리뷰 기준점)로 기준점을 정했으면 그 마커의 리뷰한 끝(review-head=, 없으면 head=) 전체 OID 를, 아니면(마커 없음·옛 마커·끝 정보 없는 마커)
# 빈 값을 냅니다(rc 0, 경로를 한정하지 않음 — 종전 대상). head 가 커밋이 아니거나 tip 의 조상이 아니면 rc 2 —
# tp_target_base 가 같은 경우를 원인과 함께 먼저 거부합니다.
tp_reviewed_head() {
  local root="${1:?root}" tip="${2:?tip}"
  _tp_seal_range "$root" "$tip" || return 0
  [[ -n "$_TP_MRB" && -n "$_TP_MHEAD" ]] || return 0
  _tp_valid_base "$root" "$_TP_MHEAD" "$tip" || return 2
}

tp_target_base() {
  local root="${1:?root}" tip="${2:?tip}" frb="${3-}" s rb label v full rc db hrc
  if [[ "$frb" == "null" || -z "$frb" ]]; then label=base-commit; else label=merge-base; fi
  if _tp_seal_range "$root" "$tip"; then
    s="$_TP_MS"; rb="$_TP_MRB"
    if [[ -n "$rb" ]]; then
      rc=0; full="$(_tp_valid_base "$root" "$rb" "$tip")" || rc=$?
      if [[ "$rc" == 0 ]]; then
        # 리뷰한 끝(마커 review-head=, 옛 마커는 head=)도 같은 조건을 거칩니다 — 대상 경로를 그 범위로 한정하기 때문입니다(tp_reviewed_head).
        hrc=0
        # review-head=·head= 가 모두 없는 마커(rd review seal 이 만들지 않는 형식 — 리뷰 검사 우회로만 남음)는 경로를 한정하지 않습니다.
        [[ -z "$_TP_MHEAD" ]] || _tp_valid_base "$root" "$_TP_MHEAD" "$tip" >/dev/null || hrc=$?
        if [[ "$hrc" == 0 ]]; then printf '%s\n' "$full"; return 0; fi
        if [[ "$hrc" == 1 ]]; then v="커밋이 아닙니다"; else v="tip 의 조상이 아닙니다(이력이 다시 쓰였을 수 있습니다)"; fi
        printf 'tp_target_base: seal 마커 %s 의 리뷰한 끝 커밋 %s 를 쓸 수 없습니다 — %s\n' "$s" "${_TP_MHEAD:0:7}" "$v" >&2
        printf '%s\n' "$_TP_NEW_SESSION_HINT" >&2
        return 2
      fi
      if [[ "$rc" == 1 ]]; then v="커밋이 아닙니다"; else v="tip 의 조상이 아닙니다(이력이 다시 쓰였을 수 있습니다)"; fi
      printf 'tp_target_base: seal 마커 %s 의 리뷰 기준점 %s 를 쓸 수 없습니다 — %s\n' "$s" "${rb:0:7}" "$v" >&2
      printf '%s\n' "$_TP_NEW_SESSION_HINT" >&2
      return 2
    fi
    printf 'tp_target_base: seal 마커 %s 에 리뷰 기준점이 없어 종전 기준(%s)으로 판정합니다\n' "$s" "$label" >&2
  fi
  if [[ "$label" == merge-base ]] && db="$(_tp_tip_default_branch "$root" "$tip")"; then
    if v="$(git -C "$root" merge-base "$db" "$tip" 2>/dev/null)" && full="$(_tp_valid_base "$root" "$v" "$tip")"; then
      printf '%s\n' "$full"; return 0
    fi
  fi
  v="$(tp_tip_base_commit "$root" "$tip" || true)"
  if [[ -n "$v" && "$v" != null ]] && full="$(_tp_valid_base "$root" "$v" "$tip")"; then
    printf '%s\n' "$full"; return 0
  fi
  printf 'tp_target_base: 반영 대상 기준점을 정할 수 없습니다 — tip 에 리뷰 기준점이 있는 seal 마커가 없고, %s 를 쓸 수 없습니다\n' \
    "$([[ "$label" == merge-base ]] && echo 'merge-base 와 task-state 의 base-commit' || echo 'task-state 의 base-commit')" >&2
  return 2
}

# tp_base_fail_line <stderr 파일> — tp_target_base 실패의 stderr 를 조회 표의 한 줄 「원인 / 복구: 명령」 으로 만듭니다.
# rd pr check·rd task list 가 씁니다. 같은 경우 rd pr check --apply 는 rc 2 로 멈추므로 조회는 --apply 대신 이 줄을 보입니다.
tp_base_fail_line() {
  local c h=""
  c="$(grep -m1 -e '^tp_target_base: .*쓸 수 없습니다' -e '^tp_target_base: .*정할 수 없습니다' "$1" 2>/dev/null)"
  c="${c#tp_target_base: }"
  [[ -n "$c" ]] || c="반영 대상 기준점을 정할 수 없습니다"
  if grep -qxF -e "$_TP_NEW_SESSION_HINT" "$1" 2>/dev/null; then
    h="$_TP_NEW_SESSION_HINT"
  elif [[ "$c" == "반영 대상 기준점을 정할 수 없습니다"* ]]; then
    h="bash rd-workflow/scripts/rd task set-base <ref> 로 리뷰한 diff 의 기준 커밋을 정하고 task-state 를 커밋한 뒤 다시 실행하십시오"
  fi
  printf '%s%s\n' "$c" "${h:+ / 복구: $h}"
}

# tp_tip_base_commit <root> <tip> — tip 커밋의 task-state 에서 base-commit (없으면 빈 값). tp_target_base 의 3순위.
tp_tip_base_commit() {
  git -C "$1" show "${2}:rd-workflow-workspace/.lifecycle/task-state" 2>/dev/null \
    | awk -F= '$1=="base-commit"{sub(/^[^=]+=/,""); print; exit}'
}

# tp_tip_config_root <root> <tip> <dest> — tip 의 workflow.json 을 <dest>/rd-workflow/config/ 에 풉니다(tip 에 없으면
# 파일을 두지 않아 tp_config 가 기본값을 냅니다). 그 뒤 tp_config <dest> ... 로 읽습니다. 읽기 실패 rc 1.
tp_tip_config_root() {
  local root="$1" tip="$2" dest="$3"
  rm -f "$dest/rd-workflow/config/workflow.json"
  git -C "$root" cat-file -e "${tip}:rd-workflow/config/workflow.json" 2>/dev/null || return 0
  mkdir -p "$dest/rd-workflow/config" || return 1
  git -C "$root" show "${tip}:rd-workflow/config/workflow.json" >"$dest/rd-workflow/config/workflow.json" 2>/dev/null
}

_tp_record_file() { printf '%s/%s\n' "${1%/}" "$RD_TEAM_PR_RECORD"; }

# tp_record_get <root> <path> <field> — 기록 한 칸을 stdout 으로. 줄 없음·파일 없음 rc 1, 알 수 없는 field rc 2.
tp_record_get() {
  local root="${1:?root}" p="${2:?path}" field="${3:?field}" f idx=0 i n out
  f="$(_tp_record_file "$root")"
  n=0
  for i in $_TP_RECORD_FIELDS; do n=$((n + 1)); [[ "$i" == "$field" ]] && idx=$n; done
  [[ "$idx" -gt 0 ]] || return 2
  [[ -f "$f" ]] || return 1
  out="$(awk -F'\t' -v p="$p" -v n="$idx" 'NR == 1 && $1 == "path" && $2 == "repo" { next } $1 == p { print $n; found = 1; exit } END { exit found ? 0 : 1 }' "$f")" || return 1
  printf '%s\n' "$out"
}

# tp_record_upsert <root> <path> <repo> <branch> <base> <url> <head-oid> <state> <merged-oid> <commits>
# 한 path 에 한 줄. 있으면 그 자리의 줄을 바꾸고 없으면 덧붙입니다. 헤더 줄 하나를 둡니다. 탭·개행이 든 값은 rc 2.
tp_record_upsert() {
  local root="${1:?root}" p="${2:?path}" f tmp v i
  [[ "$#" -eq 10 ]] || { printf 'tp_record_upsert: 인자는 10개입니다\n' >&2; return 2; }
  for v in "$@"; do
    case "$v" in *$'\t'*|*$'\n'*) printf 'tp_record_upsert: 값에 탭·개행을 쓸 수 없습니다\n' >&2; return 2 ;; esac
  done
  case "$8" in open|merged|pushed|closed) ;; *) printf 'tp_record_upsert: state 는 open|merged|pushed|closed 입니다\n' >&2; return 2 ;; esac
  f="$(_tp_record_file "$root")"
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  local newline
  newline="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "${@:2}")"
  {
    printf 'path\trepo\tbranch\tbase\turl\thead-oid\tstate\tmerged-oid\tcommits\n'
    if [[ -f "$f" ]]; then
      awk -F'\t' -v p="$p" -v nl="$newline" '
        NR == 1 && $1 == "path" && $2 == "repo" { next }
        $0 == "" { next }
        $1 == p { if (!done) { print nl; done = 1 } ; next }
        { print }
        END { if (!done) print nl }' "$f"
    else
      printf '%s\n' "$newline"
    fi
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# tp_gh <timeout-sec> <args...> — gh 를 시간 상한 안에서 부릅니다. stdout·stderr·rc 를 그대로 돌려줍니다.
# gh 없음 rc 127, 시간 초과 rc 124.
tp_gh() {
  local lim="${1:?timeout}" errf rc=0
  shift
  command -v gh >/dev/null 2>&1 || { printf 'gh 를 찾을 수 없습니다\n' >&2; return 127; }
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpgh.XXXXXX")" || return 1
  _rd_run_limited "$lim" "$errf" gh "$@" || rc=$?
  cat "$errf" >&2
  rm -f "$errf"
  return "$rc"
}

# tp_pr_state <url> — stdout `<판정><TAB><merge-oid><TAB><head-oid><TAB><commits><TAB><요약>`.
# 판정 ∈ MERGED|CHANGES_REQUESTED|CLOSED|OPEN|ERROR. 요약은 CHANGES_REQUESTED 면 최근 검토 의견 3건(`작성자: 첫 줄`, ` / ` 로 이음),
# ERROR 면 오류 첫 줄. 항상 rc 0(판정은 첫 칸에 있음).
tp_pr_state() {
  local url="${1:?url}" lim="${RD_PR_CHECK_TIMEOUT:-15}" out errf rc=0 msg
  errf="$(mktemp "${TMPDIR:-/tmp}/rd-tpst.XXXXXX")" || { printf 'ERROR\t\t\t\t임시 파일을 만들 수 없습니다\n'; return 0; }
  out="$(tp_gh "$lim" pr view "$url" --json state,mergeCommit,reviewDecision,headRefOid,commits,latestReviews 2>"$errf")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    case "$rc" in
      124) msg="gh 조회가 ${lim}초 안에 끝나지 않았습니다 (시간 초과)" ;;
      127) msg="gh 를 찾을 수 없습니다" ;;
      *)   msg="$(head -1 "$errf" | tr '\t\r' '  ')"; [[ -n "$msg" ]] || msg="gh 가 종료 코드 ${rc} 로 실패했습니다" ;;
    esac
    rm -f "$errf"
    printf 'ERROR\t\t\t\t%s\n' "$msg"
    return 0
  fi
  rm -f "$errf"
  printf '%s' "$out" | python3 -I -c '
import json, sys
def err(m):
    print("ERROR\t\t\t\t" + m); sys.exit(0)
try:
    d = json.load(sys.stdin)
    assert isinstance(d, dict)
except Exception:
    err("gh 응답을 해석할 수 없습니다")
def clean(s):
    return str(s).replace("\t", " ").replace("\r", " ").replace("\n", " ")
st = d.get("state") or ""
mc = d.get("mergeCommit") or {}
mo = mc.get("oid", "") if isinstance(mc, dict) else ""
head = d.get("headRefOid") or ""
cm = d.get("commits")
n = len(cm) if isinstance(cm, list) else 0
rd = d.get("reviewDecision") or ""
summary = ""
if st == "MERGED":
    verdict = "MERGED"
elif st == "CLOSED":
    verdict = "CLOSED"
elif rd == "CHANGES_REQUESTED":
    verdict = "CHANGES_REQUESTED"
    revs = d.get("latestReviews") or []
    revs = [r for r in revs if isinstance(r, dict)]
    revs.sort(key=lambda r: r.get("submittedAt") or "", reverse=True)
    parts = []
    for r in revs[:3]:
        a = (r.get("author") or {}).get("login", "?") if isinstance(r.get("author"), dict) else "?"
        body = (r.get("body") or "").strip()
        first = body.splitlines()[0].strip() if body else ""
        parts.append("%s: %s" % (clean(a), clean(first) if first else "(본문 없음)"))
    summary = " / ".join(parts)
elif st == "OPEN":
    verdict = "OPEN"
else:
    err("알 수 없는 PR state: " + clean(st))
print("\t".join([verdict, clean(mo), clean(head), str(n), summary]))
'
  return 0
}

# tp_preserved <repo-dir> <merged-oid> <recorded-head> <gh-head> <commits>
# (가) gh 의 headRefOid 가 기록의 head-oid 와 같아야 합니다. 다르면 rc 1, stdout `head-mismatch`.
# 그 밖은 rd_team_pr_preserved 의 결과(rc 0 보존 / 1 미보존 / 2 판정 불가, stdout 원인)를 그대로 돌려줍니다.
tp_preserved() {
  local repo="${1-}" m="${2-}" rec="${3-}" gh="${4-}" k="${5-}"
  if [[ "$gh" != "$rec" ]]; then
    echo "head-mismatch"; return 1
  fi
  rd_team_pr_preserved "$repo" "$m" "$rec" "$k"
}

# tp_approval_required <root> <slug> — rc 0 이면 사용자 승인이 필요합니다.
# publish_queue.sh 의 pq_cmd_request 와 같은 규칙: publish_approval=user, 또는 색인의 caller-id 가 비었거나 launch != ok.
# publish_approval 읽기는 pq_approval_mode 와 같은 규칙: 파일·키 없음 caller, caller|user 외 값·파싱 실패는 user(+경고).
# publish_queue.sh 는 source 하지 않고 이 규칙을 복사해 둡니다(source 하면 main() 등 전역을 덮어쓰고 session_launch.sh·
# _merge_precheck.sh 까지 끌고 옵니다 — tasks_list.sh 도 하위 셸에서만 source 합니다). 갈라짐은 test_team_publish_common.sh 의
# t_approval_parity 가 pq_approval_mode 출력과 대조해 잡습니다.
tp_approval_required() {
  local root="${1:?root}" slug="${2:?slug}" f mode cid launch
  f="$(_tp_cfg_file "$root")"
  if [[ ! -f "$f" ]]; then
    mode=caller
  else
    mode="$(python3 -I - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("ERR"); sys.exit(0)
if not isinstance(d, dict):
    print("ERR"); sys.exit(0)
if "publish_approval" not in d:
    print("caller"); sys.exit(0)
v = d["publish_approval"]
print(v if v in ("caller", "user") else "ERR")
PY
)" || mode=ERR
    case "$mode" in
      caller|user) ;;
      *)
        printf '경고: workflow.json 의 publish_approval 을 읽을 수 없거나 허용 값(caller|user)이 아닙니다 — user 로 처리합니다\n' >&2
        mode=user ;;
    esac
  fi
  cid="$(project_root="$root" tasks_index_get "$slug" caller-id 2>/dev/null || true)"
  launch="$(project_root="$root" tasks_index_get "$slug" launch 2>/dev/null || true)"
  if [[ "$mode" == user || -z "$cid" || "$launch" != ok ]]; then
    return 0
  fi
  return 1
}

# tp_light_check <root> <base-ref> — D9. 최상위 submodule 마다 "바뀜" 을 판정합니다.
# 바뀜은 (1) <base-ref> 의 gitlink 와 index·워킹트리(submodule HEAD)의 gitlink 가 다름,
#        (2) submodule HEAD 가 상위 index 의 gitlink 와 다름(안쪽 커밋),
#        (3) 안쪽 `status --porcelain` 이 비어 있지 않음(staged·unstaged·untracked).
# 바뀐 submodule 중 반영 방식이 pr·push 인 것이 있으면 team_publish.light 에 따라 상향(rc 3) 또는 light 유지(rc 0).
# stdout 한 줄. 설정 오류는 rc 2.
tp_light_check() {
  local root="${1:?root}" base="${2:?base-ref}" line mode path idx_oid base_oid head_oid changed hit="" hitmode="" light
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # ls-files -s: "<mode> <oid> <stage>\t<path>"
    path="${line#*$'\t'}"; idx_oid="$(printf '%s' "${line%%$'\t'*}" | awk '{print $2}')"
    changed=""
    base_oid="$(git -C "$root" ls-tree "$base" -- "$path" 2>/dev/null | awk '$1 == "160000" {print $3}')"
    if [[ -e "$root/$path/.git" ]]; then
      head_oid="$(git -C "$root/$path" rev-parse HEAD 2>/dev/null || true)"
      [[ -n "$head_oid" && "$head_oid" != "$idx_oid" ]] && changed=1
      [[ -n "$head_oid" && "$head_oid" != "$base_oid" ]] && changed=1
      [[ -n "$(git -C "$root/$path" status --porcelain 2>/dev/null)" ]] && changed=1
    fi
    [[ "$idx_oid" != "$base_oid" ]] && changed=1
    [[ -n "$changed" ]] || continue
    mode="$(tp_config "$root" "$path" mode)" || return 2
    if [[ "$mode" == pr || "$mode" == push ]]; then
      [[ -n "$hit" ]] || { hit="$path"; hitmode="$mode"; }
    fi
  done <<EOF_LC
$(git -C "$root" ls-files -s 2>/dev/null | awk '$1 == "160000"')
EOF_LC
  if [[ -z "$hit" ]]; then
    printf '반영 대상 없음\n'; return 0
  fi
  light="$(tp_config "$root" "" light)" || return 2
  if [[ "$light" == merge ]]; then
    printf 'light 유지 — team_publish.light=merge\n'; return 0
  fi
  printf 'standard 로 상향 — %s (반영 방식 %s, team_publish.light=pr)\n' "$hit" "$hitmode"
  return 3
}
