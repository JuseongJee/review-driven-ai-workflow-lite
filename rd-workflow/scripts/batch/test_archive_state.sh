#!/bin/bash
# test_archive_state.sh — batch_manifest.sh archive-state 의 판정 검증.
# 외부 네트워크 없이 임시 로컬 저장소 + bare remote 로 수행한다.
# macOS /bin/bash 3.2 호환.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BM="$DIR/batch_manifest.sh"
PASS=0
FAIL=0
WORK=""
SLUG="probe-task"
TAG="fr/2026-09-09/${SLUG}"

cleanup() { if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf "$WORK"; WORK=""; fi; }
trap cleanup EXIT INT TERM

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $*" >&2; }

# check <이름> <manifest> <기대 state> [기대 missing 토큰] [기대 reason]
check() {
  local name="$1" mf="$2" want_state="$3" want_missing="${4:-}" want_reason="${5:-}"
  local line state missing reason
  line="$(bash "$BM" archive-state "$mf" "$SLUG" 2>/dev/null | head -n1)"
  state="$(printf '%s' "$line"   | sed -n 's/.*state=\([^ ]*\).*/\1/p')"
  missing="$(printf '%s' "$line" | sed -n 's/.*missing=\([^ ]*\).*/\1/p')"
  reason="$(printf '%s' "$line"  | sed -n 's/.*reason=\([^ ]*\).*/\1/p')"
  if [[ "$state" != "$want_state" ]]; then
    bad "$name — 기대 state=$want_state, 실제 '$state' (줄: $line)"; return
  fi
  if [[ -n "$want_missing" && "$missing" != *"$want_missing"* ]]; then
    bad "$name — missing 에 '$want_missing' 없음 (실제 '$missing')"; return
  fi
  if [[ -n "$want_reason" && "$reason" != "$want_reason" ]]; then
    bad "$name — 기대 reason=$want_reason, 실제 '$reason'"; return
  fi
  ok
}

setup() {
  WORK="$(mktemp -d)" || { echo "test_archive_state.sh: 임시 디렉터리 생성 실패 (mktemp rc≠0, TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  [[ -n "$WORK" && -d "$WORK" ]] || { echo "test_archive_state.sh: 임시 디렉터리 경로 검증 실패 (TMPDIR='${TMPDIR:-}')" >&2; return 1; }
  mkdir -p "$WORK/remote"
  # bare 의 기본 브랜치를 고정한다. init.defaultBranch=master 인 환경에서는 bare HEAD 가
  # 없는 ref 를 가리켜 이후 clone 이 경고를 내고 push 가 non-fast-forward 로 거부된다.
  git init --bare -q -b main "$WORK/remote/origin.git"
  mkdir -p "$WORK/repo"
  cd "$WORK/repo" || return 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name t
  git config tag.gpgSign false
  git remote add origin "$WORK/remote/origin.git"

  # workspace 사실 (verify-done 충족)
  mkdir -p rd-workflow-workspace/backlog/items rd-workflow-workspace/backlog/request-archive
  printf '%s\n' "# 2026-09-09 ${SLUG}" "- status: done" \
    > "rd-workflow-workspace/backlog/items/2026-09-09-${SLUG}.md"
  printf '%s\n' "# archive" \
    > "rd-workflow-workspace/backlog/request-archive/2026-09-09-1200-${SLUG}.md"

  echo base > base.txt
  git add -A && git commit -q -m "chore: base"
  BASE_OID="$(git rev-parse HEAD)"

  git checkout -q -b "fr/${SLUG}"
  echo work > work.txt
  git add -A && git commit -q -m "feat: work"
  git checkout -q main
  git merge -q --no-ff "fr/${SLUG}" -m "merge: ${SLUG} (autopilot 완료)"

  # metadata cleanup commit = 발행 커밋 (archive.sh 의 PUBLISH_OID 자리)
  echo meta > meta.txt
  git add -A && git commit -q -m "chore(lifecycle): archive ${SLUG} metadata 정리"
  PUBLISH_OID="$(git rev-parse HEAD)"

  # archive.sh 는 annotated tag 를 만든다
  git tag -a "$TAG" "$PUBLISH_OID" -m "archive: ${SLUG}"
  TAG_OID="$(git rev-parse "$TAG")"

  printf '%s' '{"finish_policy":"push","status":"running","items":[]}'  > mf-push.json
  printf '%s' '{"finish_policy":"merge","status":"running","items":[]}' > mf-merge.json
  return 0
}

setup || { echo "fixture 생성 실패" >&2; exit 1; }

# 5) merge 근거 없음 — 다른 slug 로 조회
line="$(bash "$BM" archive-state mf-push.json "no-such-slug" 2>/dev/null | head -n1)"
case "$line" in *state=not-archived*) ok ;; *) bad "5 merge 근거 없음 — 실제 '$line'" ;; esac

# 12) verify-done 미충족
printf '%s\n' "# 2026-09-09 ${SLUG}" "- status: validated" \
  > "rd-workflow-workspace/backlog/items/2026-09-09-${SLUG}.md"
check "12 verify-done 미충족(push)" mf-push.json incomplete-archive "verify-done"
printf '%s\n' "# 2026-09-09 ${SLUG}" "- status: done" \
  > "rd-workflow-workspace/backlog/items/2026-09-09-${SLUG}.md"

# 3) tag 없음
git tag -d "$TAG" >/dev/null 2>&1
check "3 tag 없음(push)" mf-push.json incomplete-archive "tag"
# annotated tag object 는 생성 시각을 포함하므로 재생성하면 OID 가 바뀐다.
# TAG_OID 를 갱신하지 않으면 초 경계를 넘는 순간 케이스 1 이 스스로 mismatch 를 만든다.
git tag -a "$TAG" "$PUBLISH_OID" -m "archive: ${SLUG}"
TAG_OID="$(git rev-parse "$TAG")"

# 4) 로컬 fr 브랜치 잔존
check "4 로컬 fr 브랜치 잔존(push)" mf-push.json incomplete-archive "local-branch"

# 6) merge 정책 — 원격을 조회하지 않는다.
#    ls-remote 줄 수 비교로는 읽기 호출 여부도, 같은 개수의 ref 변경도 검출하지 못한다.
#    대신 "접근 불가능한 origin 에서도 complete 가 나온다" 로 확인한다 — 조회한다면
#    unknown(remote-unreachable) 로 떨어지므로, complete 자체가 비조회의 증거다.
git branch -q -D "fr/${SLUG}"
GOOD_URL="$(git remote get-url origin)"
git remote set-url origin "$WORK/remote/does-not-exist.git"
check "6 접근 불가 origin 에서도 complete(merge)" mf-merge.json complete
git remote set-url origin "$GOOD_URL"

# 2) 미push
check "2 미push(push)" mf-push.json incomplete-archive "remote-branch"

# 1) 전 단계 완료
git push -q origin "${PUBLISH_OID}:refs/heads/main"
git push -q origin "${TAG_OID}:refs/tags/${TAG}"
check "1 전 단계 완료(push)" mf-push.json complete

# 11) 원격 fr 브랜치 잔존
git push -q origin "${PUBLISH_OID}:refs/heads/fr/${SLUG}"
check "11 원격 fr 브랜치 잔존(push)" mf-push.json incomplete-archive "remote-fr-branch"
git push -q origin --delete "fr/${SLUG}" >/dev/null 2>&1

# 8) 원격 tag 가 다른 OID (F3) — 이름만 보면 complete 로 오판된다
git push -q origin ":refs/tags/${TAG}"
git push -q origin "${BASE_OID}:refs/tags/${TAG}"
check "8 원격 tag OID 불일치(push)" mf-push.json incomplete-archive "remote-tag-mismatch"
git push -q origin ":refs/tags/${TAG}"
git push -q origin "${TAG_OID}:refs/tags/${TAG}"

# 9) 다른 clone 이 원격 기본 브랜치를 전진 (F2) — 로컬에 없는 object 가 tip 이 된다
git clone -q --branch main "$WORK/remote/origin.git" "$WORK/other" \
  || bad "준비: 두 번째 clone 실패 — 케이스 9 를 검증할 수 없습니다"
( cd "$WORK/other" && git config user.email t@example.com && git config user.name t \
  && echo other > other.txt && git add -A && git commit -q -m "chore: other" \
  && git push -q origin HEAD:refs/heads/main ) \
  || bad "준비: 원격 전진 실패 — 케이스 9 를 검증할 수 없습니다"
check "9 원격 tip object 부재(push)" mf-push.json unknown "" "remote-object-missing"

# 10) 기본 브랜치 이름은 알지만 로컬 ref 부재 (F2)
mkdir -p rd-workflow/config
printf '%s' '{"default_branch":"no-such-branch"}' > rd-workflow/config/workflow.json
check "10 로컬 기본 ref 부재(push)" mf-push.json unknown "" "default-ref-missing"
rm -f rd-workflow/config/workflow.json

# 7) origin 자체 접근 불가
git remote set-url origin "$WORK/remote/does-not-exist.git"
check "7 원격 접근 불가(push)" mf-push.json unknown "" "remote-unreachable"

# --- F1 회귀: branch ancestry 를 archive 증거로 쓰지 않는다 ---
# promote 직후에는 fr tip == 기본 브랜치 tip 이므로 ancestor 조건이 참이다. 이것을 merge
# 증거로 쓰면 착수 직후 중단된 작업이 "merge 됐으나 발행 미완" 으로 오판정되고, 재개
# 스윕이 archive.sh 를 호출해 blocked 로 떨어뜨린다 (final diff review F1).
# origin 접근 불가 상태(케이스 7)가 남아 있어도 merge 미성립은 원격 조회 전에 결정되므로
# 판정에 영향이 없다.
FRESH="fresh-task"
git branch "fr/${FRESH}" 2>/dev/null
fresh_state() {
  bash "$BM" archive-state "$1" "$FRESH" 2>/dev/null | head -n1 \
    | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}
st="$(fresh_state mf-merge.json)"
if [[ "$st" == "not-archived" ]]; then ok; else
  bad "F1-a 막 생성한 fr 브랜치(merge) — 기대 not-archived, 실제 '$st'"; fi
st="$(fresh_state mf-push.json)"
if [[ "$st" == "not-archived" ]]; then ok; else
  bad "F1-b 막 생성한 fr 브랜치(push) — 기대 not-archived, 실제 '$st'"; fi
# 기본 브랜치만 전진해도 fr tip 은 여전히 ancestor 다.
git commit -q --allow-empty -m "기본 브랜치 전진" 2>/dev/null
st="$(fresh_state mf-merge.json)"
if [[ "$st" == "not-archived" ]]; then ok; else
  bad "F1-c 기본 브랜치만 전진한 뒤 — 기대 not-archived, 실제 '$st'"; fi
# 반면 실제 merge 커밋(tag 이전)은 계속 회수돼야 한다 — 케이스 3 이 덮지만 여기서도
# 같은 slug 로 한 번 더 확인해 F1 수정이 회수 경로를 죽이지 않았음을 보인다.
# fr 를 실제로 갈라지게 만든 뒤 merge 한다 — ancestor 상태에서 git merge 는
# "Already up to date" 로 exit 0 을 내고 merge 커밋을 만들지 않는다.
_base_branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
git checkout -q "fr/${FRESH}" \
  && git commit -q --allow-empty -m "fr 작업 커밋" \
  && git checkout -q "$_base_branch" \
  && git merge -q --no-ff "fr/${FRESH}" -m "merge: ${FRESH} (autopilot 완료)"
_prep_rc=$?
if [[ "$_prep_rc" -ne 0 ]]; then
  bad "F1-d 준비 실패 (rc=$_prep_rc) — merge 회수 경로를 검증하지 못했습니다"
else
  st="$(fresh_state mf-merge.json)"
  if [[ "$st" == "incomplete-archive" ]]; then ok; else
    bad "F1-d 실제 merge 커밋 존재(tag 이전) — 기대 incomplete-archive, 실제 '$st'"; fi
fi

# --- restore-dependents ---
RT="$WORK/restore-mf.json"
cat > "$RT" <<'JSON'
{"finish_policy":"push","status":"done","items":[
  {"slug":"aa","order":1,"depends_on":[],"state":"completed","feasibility":"eligible","block_reason":"","outcome":"completed"},
  {"slug":"bb","order":2,"depends_on":["aa"],"state":"skipped","feasibility":"eligible","block_reason":"","outcome":""},
  {"slug":"cc","order":3,"depends_on":["bb"],"state":"skipped","feasibility":"eligible","block_reason":"","outcome":""},
  {"slug":"ee","order":5,"depends_on":[],"state":"blocked","feasibility":"eligible","block_reason":"다른 실패","outcome":""},
  {"slug":"ff","order":6,"depends_on":["aa","ee"],"state":"skipped","feasibility":"eligible","block_reason":"","outcome":""},
  {"slug":"dd","order":4,"depends_on":[],"state":"skipped","feasibility":"excluded","exclude_reason":"자율 불가","block_reason":"","outcome":""},
  {"slug":"gg","order":7,"depends_on":["zz"],"state":"skipped","feasibility":"eligible","block_reason":"","outcome":""},
  {"slug":"zz","order":8,"depends_on":[],"state":"completed","feasibility":"eligible","block_reason":"","outcome":"completed"}
]}
JSON
RESTORED="$(bash "$BM" restore-dependents "$RT" aa 2>/dev/null | tr '\n' ' ')"
case " $RESTORED " in *" bb "*) ok ;; *) bad "restore: 직접 의존 bb 미산출 ('$RESTORED')" ;; esac
case " $RESTORED " in *" cc "*) ok ;; *) bad "restore: 간접 의존 cc 미산출 ('$RESTORED')" ;; esac
case " $RESTORED " in *" ff "*) bad "restore: blocked 선행(ee)이 남은 ff 를 산출했습니다 ('$RESTORED')" ;; *) ok ;; esac
case " $RESTORED " in *" dd "*) bad "restore: excluded 항목 dd 를 산출했습니다 ('$RESTORED')" ;; *) ok ;; esac
case " $RESTORED " in *" gg "*) bad "restore: root 와 무관한 가지 gg 를 산출했습니다 ('$RESTORED')" ;; *) ok ;; esac

# --- F2 회귀: 완료 기록·후속 복원 사이에 중단돼도 재조정이 수렴한다 ---
# 완료 전이와 각 후속 pending 전이는 별도 set-state 로 flush 되므로 그 사이 중단이
# 가능하다. 재조정 패스는 `completed` 인 선행 전량을 매번 재계산하므로, 이미 completed
# 인 aa(위 fixture)에서도 후속이 산출돼야 하고(위 검사), 후속을 일부만 복원한 뒤
# 중단된 상태에서도 남은 후속이 산출돼야 한다 (final diff review F2).
bash "$BM" set-state "$RT" bb pending - - >/dev/null 2>&1
RESTORED2="$(bash "$BM" restore-dependents "$RT" aa 2>/dev/null | tr '\n' ' ')"
case " $RESTORED2 " in *" cc "*) ok ;; *) bad "restore(부분 복원 후): 남은 후속 cc 미산출 ('$RESTORED2')" ;; esac
case " $RESTORED2 " in *" bb "*) bad "restore(부분 복원 후): 이미 pending 인 bb 를 다시 산출했습니다 ('$RESTORED2')" ;; *) ok ;; esac
case " $RESTORED2 " in *" ff "*) bad "restore(부분 복원 후): blocked 선행(ee)이 남은 ff 를 산출했습니다 ('$RESTORED2')" ;; *) ok ;; esac
case " $RESTORED2 " in *" dd "*) bad "restore(부분 복원 후): excluded 항목 dd 를 산출했습니다 ('$RESTORED2')" ;; *) ok ;; esac
case " $RESTORED2 " in *" gg "*) bad "restore(부분 복원 후): 무관한 가지 gg 를 산출했습니다 ('$RESTORED2')" ;; *) ok ;; esac

echo "test_archive_state: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
