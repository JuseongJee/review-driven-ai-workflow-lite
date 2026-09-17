# Team Overlay Migration 가이드 (기존 프로젝트)

이미 팀 repo에 AI 워크플로 템플릿 파일이 커밋되어 있거나 symlink 방식 overlay로 연결되어 있는 프로젝트를,
git submodule 기반 overlay 구조로 이관하는 절차.

## 언제 사용하는가

- 팀 프로젝트에 이미 `rd-workflow/`, `CLAUDE.md` 등이 커밋되어 있다
- 또는 구 버전 가이드로 symlink overlay(`ai` 심링크, 로컬 exclude 설정, `skip-worktree`)를 이미 설치했다
- 이 상태를 [신규 설치 가이드의 구조](team-overlay-fresh-install.md#structure)와 같은 submodule 구조로 옮기고 싶다

새 프로젝트에 처음부터 overlay를 설치하는 경우는 이 가이드가 아니라 [신규 설치 가이드](team-overlay-fresh-install.md)를 씁니다.

## 최종 상태

이관이 끝나면 [신규 설치 가이드의 구조](team-overlay-fresh-install.md#structure)와
같은 형태가 됩니다. 먼저 그 절을 읽어 최종 형태를 확인하십시오.

## 0단계: 분류와 사전 검사 [읽기 전용 — 미지원 판정과 목록 확정]

**이 단계는 아무것도 바꾸지 않습니다. 지원하지 않는 형태인지도 여기서 판정합니다.**

### A. 저장소 사전 검사

```bash
SRC=/path/to/team-project
OVERLAY=~/ai-overlays/myproject
DEST="$OVERLAY/<소스디렉토리>"

cd "$SRC"
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || { echo "중단: 저장소 루트에서 실행하십시오"; exit 1; }
[ "$(git worktree list | wc -l)" -eq 1 ] || { echo "중단: linked worktree 가 있습니다 — 미지원 표를 보십시오"; exit 1; }
[ -d .git ] || { echo "중단: .git 이 디렉토리가 아닙니다 — 미지원 표를 보십시오"; exit 1; }
[ ! -e "$DEST" ] || { echo "중단: $DEST 가 이미 존재합니다"; exit 1; }
mkdir -p "$OVERLAY"
[ "$(df -P "$SRC" | awk 'NR==2{print $1}')" = "$(df -P "$OVERLAY" | awk 'NR==2{print $1}')" ] \
  || { echo "중단: 다른 파일시스템입니다 — 같은 볼륨 안 경로를 고르십시오"; exit 1; }
echo "사전 검사 통과"
```

### A-2. 이관 목록 확정 — `PATHS` 로 덮이지 않는 개인 내용

**고정 `PATHS` 만으로는 개인 내용이 빠진다.** 구 overlay 안에만 있는 개인 자산(팀 저장소에 링크가 없는
`rd-workflow-workspace/` 등)과, 직접 설치 경로가 넣은 추가 문서(`WORKING_WITH_AI.md` 등)는 `PATHS` 에
없어 **B 의 분류에도, 2단계 확보에도, 6단계 비교에도 들어가지 않는다.** 그대로 진행하면 개인 편집본이
소스에 남고 새 overlay 에는 배포본이 들어간다 (6단계 3)이 배포본을 그대로 채우고, 6)의 비교는 staging
목록을 도는 것이라 staging 에 없는 것은 검사 대상도 아니다).

**그래서 여기서 실제 상태를 열거해 보여주고, 사용자가 이관 대상을 고른다.** 열거가 실패하면 중단한다 —
열거 실패를 「없음」으로 바꾸지 않는다. 고른 항목은 새 도구를 타지 않고 아래 두 변수로 **기존 흐름에
얹힌다**.

**(1) 소스 저장소의 추가 AI 문서**

```bash
cd "$SRC"
EXTRA_CANDIDATES="WORKING_WITH_AI.md"   # 직접 설치 경로가 넣는 문서. 프로젝트에 따라 더 적는다.

echo "=== PATHS 밖의 AI 문서 후보 ==="
for f in $EXTRA_CANDIDATES; do
  if idx_out=$(git ls-files -- "$f"); then :
  else rc=$?; echo "중단: $f 의 index 조회 실패 (git ls-files exit $rc)"; exit 1; fi
  if [ -n "$idx_out" ]; then idx=tracked; else idx=untracked; fi
  if   [ -L "$f" ]; then wt=symlink
  elif [ -e "$f" ]; then wt=real
  else wt=absent; fi
  printf '%-24s index=%-9s worktree=%s\n' "$f" "$idx" "$wt"
done
```

**`tracked` 가 곧 「팀 파일」은 아니다.** A-정리의 대상이 정확히 「추적되고 있는 개인 파일」이기 때문이다.
**팀원과 공유하기로 한 문서만 목록에서 뺀다** — 넣으면 4-2 가 소스에서 그 파일을 지운다. 판단이 서지
않으면 넣지 말고 팀과 합의한 뒤 다시 한다. `worktree=absent` 인 후보도 넣지 않는다.

고른 경로를 `PATHS` 에 더한다. 그러면 B 의 분류부터 2단계 확보·3단계·4단계 정리·6단계 비교까지 **기존
경로를 그대로 탄다** — 별도 처리를 만들지 않는다.

```bash
# 기본 목록은 여기서 한 번만 정한다. B 가 다시 대입하면 아래 선택이 지워진다.
PATHS="rd-workflow rd-workflow-workspace ai CLAUDE.md CURRENT_TASK.md REQUEST.md PROJECT_CONTEXT.md .claude"
EXTRA_PATHS=""      # 예: EXTRA_PATHS="WORKING_WITH_AI.md"
PATHS="$PATHS $EXTRA_PATHS"
echo "PATHS: $PATHS"
```

`EXTRA_PATHS` 에 넣은 경로가 추적 중이면 **4-1 의 `.gitignore` 추가 목록에도 그 경로를 적는다** — 빼면
tracking 제거 뒤 삭제가 미추적 변경으로 다시 보인다.

**(2) 구 overlay 에만 있는 개인 자산**

구 overlay 를 쓴 적이 없으면 이 절을 건너뛴다. 아래는 **소스 저장소에 대응 항목이 없는** 최상위 항목만
보여준다. 판정 기준을 「`PATHS` 에 이름이 있는가」로 잡으면 안 된다 — 문제의 개인
`rd-workflow-workspace/` 는 `PATHS` 에 이름이 **있으면서** 소스에는 실체·링크가 없어 B 가 `absent` 로
분류하는 바로 그 경우이고, 이름으로 거르면 그것이 목록에서 사라진다 (재현 확인).

```bash
OLD_OVERLAY="<구 overlay 절대경로>"

OLD_LIST=$(mktemp)
( cd "$OLD_OVERLAY" && find . -mindepth 1 -maxdepth 1 -print ) > "$OLD_LIST" \
  || { echo "중단: 구 overlay 열거 실패 ($OLD_OVERLAY)"; rm -f "$OLD_LIST"; exit 1; }
[ -s "$OLD_LIST" ] \
  || { echo "중단: 구 overlay 열거 결과가 비었습니다 ($OLD_OVERLAY)"; rm -f "$OLD_LIST"; exit 1; }

echo "=== 구 overlay 안에서 소스에 대응이 없는 항목 ==="
while IFS= read -r p; do
  n=${p#./}
  [ -n "$n" ] || continue
  case "$n" in .git|setup.sh) continue ;; esac
  # 소스에 같은 이름의 실체·심링크가 있으면 B 가 그쪽으로 확보한다 — 여기서는 뺀다.
  if [ -e "$SRC/$n" ] || [ -L "$SRC/$n" ]; then continue; fi
  printf '  %s\n' "$n"
done < "$OLD_LIST"
rm -f "$OLD_LIST"
```

**0단계 C 가 링크 대상으로 확보할 항목은 고르지 않는다.** 소스의 링크 이름과 구 overlay 안의 이름이
다르면(예: `ai -> <구 overlay>/rd-workflow`) 위 목록에 `rd-workflow` 가 남을 수 있다. C 에서 그 대상이
잡히므로 중복해서 넣지 않는다 — 넣으면 2단계가 같은 내용을 두 번 복사한다.

여기 나온 것 중 **팀 저장소에 링크가 없어 B 가 `absent` 로 분류할** 개인 자산(대표적으로 개인
`rd-workflow-workspace/`)을 고른다. 이들은 **소스 저장소에 실체가 없으므로 삭제 대상이 아니다** —
`SECURED`(4-2 의 삭제 입력)가 아니라 별도 목록에 넣어 2단계에서 staging 으로만 복사한다.

```bash
# "구 overlay 안의 절대경로|staging(=새 overlay) 에서의 이름" 쌍.
OLD_ONLY_MAP=""   # 예: OLD_ONLY_MAP="$OLD_OVERLAY/rd-workflow-workspace|rd-workflow-workspace"
```

`OLD_ONLY_MAP` 은 2단계 (4) 에서 staging 에 복사되고, staging 에 들어가는 순간 6단계 3)의 보충에서
배포본에 덮이지 않고 6)의 비교에도 **자동으로 포함**된다. 0단계 E 에서 「새로 시작」을 골라도 같다 —
배포본 기준 위에 이 목록이 얹히는 것이 8)이 약속하는 동작이다.

### B. 경로별 분류와 목록 4개

```bash
# PATHS 는 0단계 A-2 (1) 에서 정했다. 여기서 다시 대입하지 않는다 —
# 대입하면 A-2 에서 고른 EXTRA_PATHS 가 조용히 사라져 확보·정리·비교에서 모두 빠진다.
[ -n "${PATHS:-}" ] || { echo "중단: PATHS 가 비었습니다 — 0단계 A-2 (1) 부터 다시 실행하십시오"; exit 1; }
echo "대상 경로: $PATHS"

echo "=== 경로별 상태 ==="
LINK_PATHS=""; RESTORE_PATHS=""; UNTRACK_PATHS=""; REAL_PATHS=""
for f in $PATHS; do
  # index 조회는 '성공' 을 먼저 확인한다. 실패의 빈 출력을 '미추적' 으로 읽으면
  # 이후 모든 단계의 입력이 통째로 틀어진다.
  if idx_out=$(git ls-files -- "$f"); then :
  else rc=$?; echo "중단: $f 의 index 조회 실패 (git ls-files exit $rc)"; exit 1; fi
  if [ -n "$idx_out" ]; then idx=tracked; else idx=untracked; fi
  if   [ -L "$f" ]; then wt=symlink; tgt=$(cd "$(dirname "$f")" && readlink "$(basename "$f")")
  elif [ -e "$f" ]; then wt=real; tgt='-'
  else wt=absent; tgt='-'; fi
  printf '%-24s index=%-9s worktree=%-7s target=%s\n' "$f" "$idx" "$wt" "$tgt"
  [ "$wt" = symlink ] && LINK_PATHS="$LINK_PATHS $f"
  [ "$wt" = real ]    && REAL_PATHS="$REAL_PATHS $f"
  [ "$idx" = tracked ] && [ "$wt" != real ] && RESTORE_PATHS="$RESTORE_PATHS $f"
  [ "$idx" = tracked ] && UNTRACK_PATHS="$UNTRACK_PATHS $f"
done
echo "LINK_PATHS:   $LINK_PATHS"
echo "RESTORE_PATHS:$RESTORE_PATHS"
echo "UNTRACK_PATHS:$UNTRACK_PATHS"
echo "REAL_PATHS:   $REAL_PATHS"
```

**bit 는 파일 단위로 모은다** — 디렉토리 안에서 `H` 와 `S` 가 섞일 수 있고, 디렉토리 경로에 `git update-index` 를 걸면 `Unable to mark file` 로 실패한다. `-z` 를 쓰는 이유는 특수문자 경로 인용을 피하기 위함이다.

```bash
SKIP_FILES_F=$(mktemp)
for f in $PATHS; do
  git ls-files -v -z -- "$f" 2>/dev/null | while IFS= read -r -d '' line; do
    st=${line%% *}; pth=${line#* }
    case "$st" in S|s) printf '%s\n' "$pth" >> "$SKIP_FILES_F" ;; esac
  done
done
echo "=== skip-worktree 가 걸린 파일 ==="; cat "$SKIP_FILES_F"
```

이 네 목록과 파일 목록을 **적어 둔다** — 이후 각 단계가 자기 목록만 쓴다.

### C. 개인 내용의 출처 확정

| index | 워킹트리 | 개인 내용의 출처 |
|---|---|---|
| tracked | real | 팀 워킹트리의 이 실체 파일 (팀 버전과 섞여 있을 수 있으니 확인) |
| tracked | symlink | **링크가 가리키는 실제 대상** |
| tracked | absent | **구 overlay** — 대상을 특정할 수 없으면 중단 |
| untracked | symlink | **링크가 가리키는 실제 대상** |
| untracked | real | 이 실체 파일 |
| untracked | absent | 없음 |

**출처는 「구 overlay 안의 같은 이름」이 아니라 「링크 대상」이다.** 구 가이드의 `ai` 는 `rd-workflow` 를 가리켰으므로 `ai` 의 출처는 `<구 overlay>/ai` 가 아니다. B 에서 기록한 `target` 값을 쓴다.

```bash
# 링크가 있는 자리에서 대상을 한 번 읽고, 그 문자열을 기준으로 절대 경로를 만든다.
# 중복 대상은 한 번만 쓴다.
echo "=== 개인 내용 출처 ==="
for f in $LINK_PATHS; do
  d=$(dirname "$f"); b=$(basename "$f")
  raw=$(cd "$d" && readlink "$b") \
    || { echo "중단: $f 의 링크를 읽을 수 없습니다"; exit 1; }
  [ -n "$raw" ] || { echo "중단: $f 의 링크 대상이 비어 있습니다"; exit 1; }
  tdir=$(dirname "$raw"); tbase=$(basename "$raw")
  tgt=$(cd "$d" && cd "$tdir" && printf '%s/%s\n' "$(pwd -P)" "$tbase") \
    || { echo "중단: $f 의 대상 디렉토리 $tdir 로 이동할 수 없습니다"; exit 1; }
  [ -e "$tgt" ] \
    || { echo "중단: $f 의 링크 대상이 실재하지 않습니다 (대상=$tgt)"; exit 1; }
  [ -L "$tgt" ] \
    && { echo "중단: $f 의 대상 $tgt 이 다시 심링크입니다 — 링크 연쇄는 지원하지 않습니다."; \
         echo "      최종 대상을 확인해 수동으로 지정한 뒤 다시 진행하십시오"; exit 1; }
  printf '%-24s <- %s\n' "$f" "$tgt"
done
```

**`readlink` 의 `-f` 옵션에 의존하지 않는다.** 그 옵션은 macOS 12 미만에 없고, 그 대체로 「대상 디렉토리로 `cd` 한 뒤 같은
이름을 다시 `readlink`」 하면 **원래 링크가 없는 자리에서 찾게 되어** 두 번째 `readlink` 가 실패해도
`printf` 가 성공하고 `<대상 디렉토리>/` 를 내놓는다. 그 값은 뒤의 `-e` 검사를 통과해 **파일 대신 overlay
디렉토리 전체가 그 파일 이름으로 복사**된다 (재현 확인). 위 방식은 **링크가 있는 자리에서 한 번만 읽으므로**
`-f` 유무와 무관하고 상대·절대 대상 모두에 동작한다. 링크 연쇄 등 지원하지 않는 형태는 **안전하게 중단**하고
수동 지정을 안내한다 — 범용 경로 해석기를 만들지 않는다.

`tracked+absent` 경로는 구 overlay 에서 대응 내용을 찾아 경로를 적어 둔다. 찾지 못하면 **여기서 중단**한다 — 복사 실패로 미루면 이미 링크·bit 를 바꾼 뒤가 된다.

같은 대상을 가리키는 링크가 둘이면(예: `ai` 와 `rd-workflow`) **한 번만 복사**하고 overlay 에서의 이름을 정한다 (보통 `rd-workflow`).

### D. 구 hook 활성 여부 / E. 구 overlay 재사용

**부재 / 정상 읽기 / 읽기 오류를 구분한다.** `grep` 의 종료 코드 0·1·그 밖을 각각 다르게 처리하고, **오류는 통과가 아니라 중단**이다.

```bash
( cd "$SRC" || exit 1
  HOOKS=$(git rev-parse --git-path hooks) || { echo "중단: hooks 경로 조회 실패"; exit 1; }
  for h in post-checkout post-merge; do
    if [ ! -e "$HOOKS/$h" ]; then echo "$h: 없음"; continue; fi
    if [ ! -f "$HOOKS/$h" ] || [ ! -r "$HOOKS/$h" ]; then
      echo "중단: $h 를 읽을 수 없습니다 (정규 파일이 아니거나 권한 없음)"; exit 1; fi
    if grep -q 'overlay-branch-sync' "$HOOKS/$h"; then :    # 발견 — 계속 판정
    else
      rc=$?
      case "$rc" in
        1) echo "$h: 마커 없음"; continue ;;
        *) echo "중단: $h 검사 중 오류 (grep exit $rc)"; exit 1 ;;
      esac
    fi
    bin=$(sed -n 's/^OVERLAY_BRANCH_SYNC_BIN="\(.*\)"$/\1/p' "$HOOKS/$h" | head -n1)
    [ -n "$bin" ] || { echo "중단: $h 의 마커 블록을 해석하지 못했습니다"; exit 1; }
    if [ -x "$bin" ]; then echo "$h: 마커 있음 — 본체 실재 (활성)"
    else echo "$h: 마커 있음 — 본체 부재 (비활성, 소음만)"; fi
  done ) || { echo "중단: hook 상태를 확인하지 못했습니다"; exit 1; }
```

각주로 적는다 — `git -C <소스> rev-parse --git-path hooks` 는 **소스 기준 상대 경로**를 돌려주므로 다른 디렉토리에서 열면 안 된다. `core.hooksPath` 가 설정된 저장소는 자동 정리 대상이 아니지만, **그 경로에서 활성 hook 을 확인하지 못한 것을 통과로 처리하지 않는다** — 확인 불가면 중단하고 수동 확인을 안내한다.

**E. 구 overlay 재사용 여부를 지금 정한다** (이력 유지 / 새로 시작).

## 1단계: 구 hook 비활성화

마커 블록은 다음 형태다. `# >>> overlay-branch-sync >>>` ~ `# <<< overlay-branch-sync <<<` 를 지운다. **hook 파일 전체를 지우지 않는다.**

```sh
# >>> overlay-branch-sync >>>
# Managed by rd-workflow install_overlay_branch_sync.sh; do not edit between markers.
OVERLAY_BRANCH_SYNC_BIN="..."
OVERLAY_PATH="..."
"$OVERLAY_BRANCH_SYNC_BIN" "$OVERLAY_PATH" || true
# <<< overlay-branch-sync <<<
```

제거 확인 — **마커가 남아 있으면 진행하지 않는다**:

```bash
( cd "$SRC" || exit 1
  HOOKS=$(git rev-parse --git-path hooks) || exit 1
  rc_all=0
  for h in post-checkout post-merge; do
    [ -e "$HOOKS/$h" ] || { echo "$h: 없음"; continue; }
    if grep -q 'overlay-branch-sync' "$HOOKS/$h"; then echo "$h: 마커 잔존"; rc_all=1
    else
      rc=$?
      case "$rc" in
        1) echo "$h: ok" ;;
        *) echo "$h: 검사 오류 (exit $rc)"; rc_all=1 ;;
      esac
    fi
  done
  exit "$rc_all" ) || { echo "중단: hook 정리가 끝나지 않았습니다"; exit 1; }
```

## 2단계: 개인 내용 확보 [어떤 삭제보다 먼저]

**A-정리 대상이 없어도 이 단계는 수행합니다.** 개인 내용의 수명을 tracking 제거에 묶으면 순수 심링크 설치에서 확보 자체가 사라집니다.

```bash
STAGE=$(mktemp -d)
SECURED=""   # 개인 내용 확보가 확인된 '소스 경로'. 4-2 의 삭제 입력이 된다.
             # '지금 실체가 있는가' 와는 다른 판정이다 — tracked+absent 는 3-3 복원 후 실체가 생긴다.
SECURED_MAP="" # "소스경로|staging 상대경로" 쌍. 소스 이름과 overlay 에서의 이름은 다를 수 있다.
             # 중복 대상은 한 번만 복사하므로 여러 소스가 같은 staging 경로를 가리킨다 (ai|rd-workflow).
             # 경로에 공백·'|' 가 없다는 전제는 $PATHS 를 도는 다른 루프들과 같다.
echo "staging: $STAGE   ← 이 경로를 적어 두십시오. 이후 단계가 실패하면 여기서 회수합니다."

# (1) 실체 파일 — 그 자리에서
for f in $REAL_PATHS; do
  cp -R "$f" "$STAGE/" || { echo "중단: $f 복사 실패 (staging: $STAGE)"; exit 1; }
  SECURED="$SECURED $f"; SECURED_MAP="$SECURED_MAP $f|$f"
done

# (2) 심링크 — 대상을 따라가 '내용' 을 복사한다. 0단계 C 에서 확정한 대상·이름을 쓴다.
#     같은 대상을 가리키는 링크가 둘이면 한 번만 복사한다.
#     예: ai -> rd-workflow 이면 rd-workflow 만 복사
cp -RL "<링크 대상 절대경로>" "$STAGE/<overlay 에서의 이름>" \
  || { echo "중단: 복사 실패 (staging: $STAGE)"; exit 1; }
# 0단계 C 가 정한 'overlay 에서의 이름' 이 staging 경로다. 같은 대상을 가리키던 링크가 둘이면
# 둘 다 소스 경로로 등록하되 staging 경로는 하나를 공유한다 (예: rd-workflow|rd-workflow, ai|rd-workflow).
for l in <그 대상을 가리키던 링크 경로들>; do
  SECURED="$SECURED $l"; SECURED_MAP="$SECURED_MAP $l|<overlay 에서의 이름>"
done

# (3) tracked+absent — 0단계 C 에서 확정한 구 overlay 경로에서 '복사' 한다.
#     (출처를 찾지 못했으면 0단계에서 이미 중단했다)
#     지금은 워킹트리에 없지만 3-3 에서 '팀 파일' 로 복원되므로 SECURED 에 넣는다.
#     넣지 않으면 복원된 팀 파일이 소스에 남은 채 '소스 정리 완료' 가 나온다.
#     주석만 두고 SECURED 에 넣지 않는다 — '확보' 는 복사와 확인이 끝났다는 뜻이다.
src="<0단계 C 가 확정한 출처 절대경로>"; rel="<소스에서의 경로>"
[ -e "$src" ] || { echo "중단: $rel 의 출처 $src 가 없습니다 (staging: $STAGE)"; exit 1; }
mkdir -p "$STAGE/$(dirname "$rel")" \
  || { echo "중단: $rel 의 staging 디렉토리 생성 실패 (staging: $STAGE)"; exit 1; }
cp -RL "$src" "$STAGE/$rel" \
  || { echo "중단: $rel 확보 실패 (staging: $STAGE)"; exit 1; }
SECURED="$SECURED $rel"; SECURED_MAP="$SECURED_MAP $rel|$rel"

# (4) 구 overlay 에만 있는 개인 자산 — 0단계 A-2 (2) 가 확정한 OLD_ONLY_MAP.
#     소스 저장소에 실체가 없으므로 SECURED 에 넣지 않는다 (4-2 는 이것을 지울 것이 없다).
#     staging 에만 넣으면 6단계 3)의 보충과 6)의 비교가 그대로 덮는다.
EXTRA_MAP=""
for pair in $OLD_ONLY_MAP; do
  osrc=${pair%%|*}; odst=${pair#*|}
  [ -e "$osrc" ] || { echo "중단: $osrc 가 없습니다 (staging: $STAGE)"; exit 1; }
  mkdir -p "$STAGE/$(dirname "$odst")" \
    || { echo "중단: $odst 의 staging 디렉토리 생성 실패 (staging: $STAGE)"; exit 1; }
  cp -RL "$osrc" "$STAGE/$odst" \
    || { echo "중단: $osrc 확보 실패 (staging: $STAGE)"; exit 1; }
  EXTRA_MAP="$EXTRA_MAP $osrc|$odst"
done
```

**복사 결과 검증 — 두 검사를 함께 한다:**

```bash
# 심링크가 그대로 복사되지 않았는가 (cp -R 는 링크를 링크로 복사한다)
# 열거를 파일로 확정하고 '열거가 성공했는가' 를 먼저 본다 — find 가 실패해 출력이 없는 것을
# '심링크 없음' 으로 읽으면 검증이 통과로 둔갑한다.
LINK_LIST=$(mktemp)
find "$STAGE" -type l -print > "$LINK_LIST" \
  || { echo "중단: staging 심링크 열거 실패 (staging: $STAGE)"; rm -f "$LINK_LIST"; exit 1; }
if [ -s "$LINK_LIST" ]; then
  echo "중단: staging 에 심링크가 있습니다 (staging: $STAGE)"; cat "$LINK_LIST"
  rm -f "$LINK_LIST"; exit 1
fi
rm -f "$LINK_LIST"; echo "ok: staging 에 심링크 없음"
# 내용이 실제로 있는가
find "$STAGE" -type f | head -5
[ -n "$(find "$STAGE" -type f -print -quit)" ] || { echo "중단: staging 이 비었습니다"; exit 1; }

# 경로별 확보 확인 — '전역으로 비어 있지 않은가' 로는 한 경로의 누락을 잡지 못한다.
# 소스 이름과 staging 이름이 같다고 가정하지 않는다 — 0단계 C 가 정한 대응(SECURED_MAP)을 쓴다.
# 그렇게 하지 않으면 ai -> rd-workflow 처럼 이름이 다른 정상 확보를 '없음' 으로 잘못 중단한다.
# 0단계 A-2 가 고른 항목도 같은 확인을 받는다 — 누락은 여기서 사용자에게 보인다.
echo "=== 확보 확인 ==="
for pair in $SECURED_MAP $EXTRA_MAP; do
  f=${pair%%|*}; d=${pair#*|}
  [ -e "$STAGE/$d" ] \
    || { echo "중단: $f 의 확보본이 staging 에 없습니다 (기대: $STAGE/$d)"; exit 1; }
  printf '  %-24s -> %s\n' "$f" "$d"
done
```

각주: `cp -R` 는 링크를 링크로 복사하고, 원본·사본의 파일 수가 둘 다 1이라 개수 대조만으로는 잡히지 않는다. 그래서 `-type l` 검사를 함께 한다.

**`SECURED` 를 그대로 다음 단계에 넘긴다.** 4-2 는 이 목록만 지운다 — `$PATHS` 전체를 넘기면 확보하지
않은 경로까지 삭제 대상이 된다.

**`SECURED` 는 「개인 내용을 확보했는가」이지 「지금 워킹트리에 실체가 있는가」가 아니다.** 두 판정을
섞으면 `tracked+absent` 경로가 빠진다 — 그 경로는 2단계 시점에 실체가 없지만 3-3 에서 **팀 파일로
복원**되므로, 정리 대상에서 빼면 소스에 AI 파일이 남은 채 「소스 정리 완료」가 나온다. 실체 유무는 4-2 의
`[ -e "$f" ]` 가 그 시점에 판단한다.

## 3단계: B-정리 [bit 해제 → 링크 제거 → 팀 파일 복원]

**`skip-worktree` 가 켜진 경로는 `git checkout -- <경로>` 가 실패한다** (`pathspec did not match`). bit 해제가 복원보다 앞선다.

```bash
cd "$SRC"

# 3-1. bit 해제 — 0단계 B 의 파일 목록에만. 디렉토리 경로에 걸지 않는다.
while IFS= read -r pth; do
  [ -n "$pth" ] || continue
  git update-index --no-skip-worktree -- "$pth" || { echo "중단: $pth bit 해제 실패"; exit 1; }
done < "$SKIP_FILES_F"
echo "bit 해제 완료"

# 3-2. 링크 제거 — LINK_PATHS 에만. rm -rf 를 쓰지 않는다 (대상을 따라가 원본을 지운다).
for f in $LINK_PATHS; do
  [ -L "$f" ] || { echo "중단: $f 가 더 이상 심링크가 아닙니다 — 0단계를 다시 하십시오"; exit 1; }
  rm "$f" && echo "removed symlink: $f"
done

# 3-3. 팀 파일 복원 — RESTORE_PATHS 에만. REAL_PATHS 는 건드리지 않는다
#      (그 안에 개인 미커밋 내용이 있을 수 있다).
for f in $RESTORE_PATHS; do
  git checkout -- "$f" || { echo "중단: $f 복원 실패"; exit 1; }
done
echo "팀 파일 복원 완료"
```

**3-4. 로컬 ignore 원복 — overlay 항목만**

```bash
"$EDITOR" "$(git rev-parse --git-path info/exclude)"
```

overlay 를 숨기려고 넣은 줄만 지운다. **파일 전체를 비우지 않는다** — 사용자가 다른 목적으로 넣은 줄이 함께 있다.

**3-5. 손대지 않는 것**: `.git/config`, 다른 도구의 hook 내용, 관련 없는 exclude 항목, 관련 없는 `skip-worktree`·sparse checkout 설정.

**합의 전 중단 경로**: 3-3 까지 하고 멈추면 팀 파일은 복원되고 개인 내용은 staging 에 있다 — 저장소가 구 설치 직전 상태로 복귀한다.

**구 `setup.sh`** 는 구 overlay 쪽에 있다. 재사용하기로 했으면 삭제한다.

## 4단계: A-정리 [팀 합의 필요]

> **4-1(tracking 제거)은 `UNTRACK_PATHS` 가 비어 있지 않을 때만 수행합니다.** 추적 중인 overlay 경로가
> 하나도 없으면 팀 `.gitignore` 변경도, 커밋도, 팀 합의도 필요 없습니다 — 그 저장소는 4-1 을 건너뜁니다.
> **4-2(소스 정리)는 A 대상 유무와 무관하게 항상 수행합니다.** 2단계에서 확보한 개인 실체 파일이 소스
> 저장소에 그대로 남으면 이관이 끝나지 않습니다. 미추적 실체 `PROJECT_CONTEXT.md` 만 있는 저장소(0단계 C 가
> 지원하는 경우)가 정확히 이 경로를 지납니다.

### 4-1. tracking 제거 — `UNTRACK_PATHS` 가 있을 때만

> **`git commit -- <경로>` 를 쓰지 마십시오.** `git rm --cached` 로 index 에서 지운 뒤 그 경로를 pathspec 으로 커밋하면, git 은 **워킹트리 내용을 다시 커밋**해 삭제를 취소합니다. 커밋은 성공하고 변경 목록에는 `.gitignore` 만 보이지만 파일은 여전히 추적됩니다. 그 상태에서 워킹트리를 지우면 **추적 중인 파일을 삭제**하게 됩니다.

```bash
cd "$SRC"
if staged=$(git diff --cached --name-only); then :
else rc=$?; echo "중단: staged 변경 조회 실패 (git diff exit $rc)"; exit 1; fi
[ -z "$staged" ] \
  || { echo "중단: staged 변경이 있습니다. 먼저 커밋하거나 unstage 하십시오"; exit 1; }
git diff --quiet -- .gitignore \
  || { echo "중단: .gitignore 에 unstaged 변경이 있습니다"; exit 1; }

# 추적되는 경로만 제거 — 한 번에 넘기면 하나가 미추적일 때 전체가 실패한다
REMOVED=""
for f in $UNTRACK_PATHS; do
  # 조회 실패를 '미추적' 으로 바꾸지 않는다 — 그러면 tracking 제거에서 조용히 빠진다.
  if idx_out=$(git ls-files -- "$f"); then :
  else rc=$?; echo "중단: $f 의 index 조회 실패 (git ls-files exit $rc)"; exit 1; fi
  [ -n "$idx_out" ] || continue
  git rm -r --cached -q "$f" || { echo "중단: $f tracking 제거 실패"; exit 1; }
  REMOVED="$REMOVED $f"
done
echo "tracking 제거 예정:$REMOVED"

cat >> .gitignore <<'EOF'
rd-workflow/
rd-workflow-workspace/
CLAUDE.md
CURRENT_TASK.md
REQUEST.md
PROJECT_CONTEXT.md
.claude/
EOF
# 0단계 A-2 (1) 에서 EXTRA_PATHS 에 넣은 추적 경로가 있으면 위 목록에 함께 적는다.
git add .gitignore
git diff --cached --stat        # ← 의도한 것만 있는지 확인한 뒤 다음으로

git commit -m "chore: AI workflow 파일을 개인 관리로 전환" || { echo "중단: 커밋 실패"; exit 1; }

# 커밋 결과 검증 — HEAD 에서도 사라졌는가
# `git cat-file -e "HEAD:<경로>"` 를 쓰지 않는다. 경로 부재도 exit 128 이라 '부재' 와
# '조회 오류' 를 구분할 수 없고, 둘 다 통과로 읽힌다 (실측: git 2.55).
# `git ls-tree` 는 조회 성공이 exit 0 이고 부재는 '출력 없음' 이라 둘을 나눌 수 있다.
for f in $REMOVED; do
  if idx_out=$(git ls-files -- "$f"); then :
  else rc=$?; echo "중단: $f 의 index 재조회 실패 (git ls-files exit $rc)"; exit 1; fi
  [ -z "$idx_out" ] || { echo "중단: $f 가 아직 index 에 있습니다"; exit 1; }
  if head_out=$(git ls-tree -r --name-only HEAD -- "$f"); then :
  else rc=$?; echo "중단: $f 의 HEAD 조회 실패 (git ls-tree exit $rc)"; exit 1; fi
  [ -z "$head_out" ] || { echo "중단: $f 가 아직 HEAD 에 있습니다"; exit 1; }
done
echo "tracking 제거 확인 완료"
```

### 4-2. 소스 워킹트리 정리 — 항상 수행한다

**2단계의 staging 검증을 통과하지 못했으면 여기까지 오지 않는다.** 확보되지 않은 내용을 지우지 않기 위해
순서를 이렇게 잡았고, 삭제 입력도 `$PATHS` 전체가 아니라 **확보가 확인된 `$SECURED`** 로 한정한다.

```bash
cd "$SRC"
for f in $SECURED; do
  [ -e "$f" ] || continue
  # 4-1 을 건너뛴 저장소라도, 지우려는 경로가 추적 중이 아님을 여기서 다시 확인한다.
  # **조회가 성공했음을 먼저 확인한다.** git 이 실패했는데 그 빈 출력을 '미추적' 으로 읽으면
  # 추적 여부를 확인하지 못한 채 바로 아래 rm -rf 에 도달한다 — staging 이 있다는 사실은
  # 「팀의 추적 파일을 지워도 된다」는 확인을 대신하지 못한다.
  if idx_out=$(git ls-files -- "$f"); then :
  else rc=$?; echo "중단: $f 의 index 조회 실패 (git ls-files exit $rc / staging 보존: $STAGE)"; exit 1; fi
  [ -z "$idx_out" ] \
    || { echo "중단: $f 가 아직 index 에 있습니다 — 4-1 을 먼저 수행하십시오"; exit 1; }
  if head_out=$(git ls-tree -r --name-only HEAD -- "$f"); then :
  else rc=$?; echo "중단: $f 의 HEAD 조회 실패 (git ls-tree exit $rc / staging 보존: $STAGE)"; exit 1; fi
  [ -z "$head_out" ] \
    || { echo "중단: $f 가 아직 HEAD 에 있습니다 — 4-1 을 먼저 수행하십시오"; exit 1; }
  rm -rf "$f" || { echo "중단: $f 정리 실패 (staging 보존: $STAGE)"; exit 1; }
  echo "정리: $f"
done
echo "소스 정리 완료"
```

## 5단계: 편입 [한 번만]

**왜 보존되는가**: `git submodule add` 는 대상 경로에 이미 유효한 git 저장소가 있으면 clone 하지 않고 등록한다. `mv` 는 같은 파일시스템 안에서 inode 를 옮긴다.

```bash
cd "$SRC"
git status --porcelain            # 미커밋·미추적
git status --ignored --porcelain  # 무시 대상 (기본 status 에 안 나온다)
git branch
git stash list
```

```bash
[ ! -e "$DEST" ] || { echo "중단: $DEST 가 이미 존재합니다"; exit 1; }
mv "$SRC" "$DEST"
cd "$OVERLAY"
git init -b main        # 구 overlay 를 재사용하면 생략
git submodule add git@github.com:team/project.git <소스디렉토리>
```

| 미지원 형태 | 이유 | 대안 |
|---|---|---|
| linked worktree 가 딸린 저장소 | main 을 옮기면 linked 쪽 gitdir 연결이 끊어진다 | 기존 클론을 **그대로 두고** [신규 설치](team-overlay-fresh-install.md)로 별도 clone |
| 저장소 자신이 linked worktree | `.git` 이 파일이라 이동 시 포인터가 깨진다 | main worktree 에서 진행하거나 신규 설치 |
| 이미 다른 저장소의 submodule | 중첩 submodule 은 범위 밖 | 신규 설치 |
| 다른 파일시스템 | `mv` 가 복사+삭제가 된다 | 같은 볼륨 안 경로를 고른다 |

## 6단계: overlay 구성 [개인 내용이 이긴다]

> 신규 설치는 배포본을 **통째로 복사**합니다. 이관은 **개인 내용이 이깁니다** — 배포본이 개인
> `PROJECT_CONTEXT.md`·`CLAUDE.md` 를 덮지 않습니다.

**1) 배포본을 별도 staging 에 — 비교가 끝날 때까지 지우지 않는다**

```bash
cd "$OVERLAY"

TPL=$(mktemp -d)
git clone --depth 1 git@github.com:owner/ai-dev-template.git "$TPL/t" \
  || { echo "중단: 배포본 clone 실패"; rm -rf "$TPL"; exit 1; }
rm -rf "$TPL/t/.git"
```

**2) 2단계에서 확보한 개인 내용을 먼저 배치한다**

```bash
cp -R "$STAGE/." ./ || { echo "중단: 개인 내용 배치 실패 (staging 보존: $STAGE)"; exit 1; }
```

**3) 배포본에만 있는 것을 채운다.** 이미 있는 것은 건드리지 않고 차이를 보여준다.
목록 생성과 소비를 나눈다 — heredoc 안의 `$( )` 는 실패해도 입력이 빌 뿐이라
열거 실패가 '대상 없음' 으로 둔갑한다. 열거가 성공했을 때만 보충을 시작한다.

```bash
TPL_LIST=$(mktemp)
( cd "$TPL/t" && find . -type f -print ) > "$TPL_LIST" \
  || { echo "중단: 배포본 열거 실패 (staging 보존: $STAGE / 배포본: $TPL)"; exit 1; }
[ -s "$TPL_LIST" ] \
  || { echo "중단: 배포본이 비었습니다 (staging 보존: $STAGE / 배포본: $TPL)"; exit 1; }

rc=0
while IFS= read -r rel; do
  rel=${rel#./}
  [ -n "$rel" ] || continue
  if [ -e "$rel" ]; then
    diff -q "$TPL/t/$rel" "$rel" >/dev/null 2>&1 || echo "diff (개인 내용 유지): $rel"
  else
    mkdir -p "$(dirname "$rel")" || { echo "FAIL: $rel 디렉토리 생성 실패"; rc=1; continue; }
    if cp "$TPL/t/$rel" "$rel"; then echo "add: $rel"
    else echo "FAIL: $rel 복사 실패"; rc=1; fi
  fi
done < "$TPL_LIST"
[ "$rc" -eq 0 ] \
  || { echo "중단: 배포본 보충에 실패했습니다 (staging 보존: $STAGE / 배포본: $TPL)"; exit 1; }
```

3 의 `diff (개인 내용 유지)` 목록을 사용자가 하나씩 보고 배포본 쪽을 가져올지 정한다 — `$TPL` 이 아직 살아 있으므로 `diff "$TPL/t/<경로>" <경로>` 로 확인할 수 있다.

**배포본 쪽을 채택한 경로는 `ADOPTED` 에 적는다.** 그 경로는 개인 내용과 달라지는 것이 의도이므로 6)의
비교 기대값에서 제외해야 한다. 아무것도 채택하지 않으면 `ADOPTED=""` 로 둔다.

```bash
ADOPTED=""    # 배포본을 그대로 채택한 경로. 예: ADOPTED="WORKING_WITH_AI.md"
MERGED=""     # 개인 내용과 배포본을 손으로 섞은 경로 (있으면)
# 채택한 경로마다: cp "$TPL/t/<경로>" <경로> && ADOPTED="$ADOPTED <경로>"
# 손으로 섞었으면:  MERGED="$MERGED <경로>"
```

**4) `.gitignore` 는 자동 병합하지 않는다.**

```bash
if [ -f .gitignore ]; then
  cp .gitignore .gitignore.old || { echo "중단: .gitignore 백업 실패"; exit 1; }
fi
cp "$TPL/t/.gitignore" .gitignore || { echo "중단: 배포본 .gitignore 복사 실패"; exit 1; }
echo "기존 규칙은 .gitignore.old 에 있습니다. 두 파일을 비교해 필요한 항목만 옮기십시오:"
echo "  diff .gitignore.old .gitignore"
```

**단순 이어붙이기를 하지 않는 이유**: 기존에 `rd-workflow-workspace/.lifecycle/` 같은 광범위 규칙이 있으면, 배포본의 `review-seals` 예외보다 **뒤에 붙어 그것을 무력화**한다. 그러면 종결 마커가 추적되지 않아 **발행이 차단된다.**

**5) 결과를 규칙 검사로 검증한다 — 실패는 경고가 아니라 중단이다.**

**사용자 overlay 에 파일을 만들지도, 지우지도 않는다.** 이 명령은 실제 사용자 상태 위에서 돈다. 고정 이름
(`.lifecycle/loop-state`, `review-seals/sample.seal`)에 `echo x >` 를 쓰면 **이미 있는 loop-state 와 동명
seal 을 덮어쓰고 마지막 `rm` 이 그것을 지운다.** 그래서 `--no-index` 로 **경로에 적용되는 규칙만** 본다
(경로가 실재하지 않아도 판정된다). 실제 파일을 만들어 보는 검증은 Task 7 의 **소유 fixture 안에서만** 한다.

```bash
# 런타임 상태 제외 규칙은 full 배포본에만 있다 (lite 는 loop-guard 를 포함하지 않는다).
# 변형을 가정하지 않고, 배포본에 그 규칙이 있을 때만 최종 .gitignore 에 살아남았는지 본다.
# grep 의 exit 1(규칙 없음)과 exit 2(배포본을 읽지 못함)를 구분한다. 읽지 못한 것을
# 'lite 라서 규칙이 없다' 로 읽으면 full 의 런타임 ignore 검사를 통째로 건너뛴다.
# 아래 review-seals 블록과 같은 if/else + case idiom 을 쓴다.
if grep -q '^rd-workflow-workspace/\.lifecycle/loop-state$' "$TPL/t/.gitignore"; then
  git check-ignore -q --no-index rd-workflow-workspace/.lifecycle/loop-state \
    || { echo "중단: 런타임 상태가 ignore 되지 않습니다 — .gitignore 를 고치십시오"; exit 1; }
  echo "ok: 런타임 상태 제외 규칙 유지됨"
else
  rc=$?
  case "$rc" in
    1) echo "skip: 배포본에 런타임 상태 제외 규칙이 없습니다 (lite)" ;;
    *) echo "중단: 배포본 .gitignore 검사 오류 (grep exit $rc)"; exit 1 ;;
  esac
fi

# 추적 가능해야 하는 경로: exit 1(=ignore 아님)만 정상. Git 오류(2 이상)를 통과로 넘기지 않는다.
# `cmd; rc=$?` 를 쓰지 않는다 — Task 7 처럼 `set -e` 가 켜진 shell 에서는 정상인 exit 1 에
# shell 이 먼저 죽어 case 에 도달하지 못한다. 예상되는 비영 종료는 if/else 로 받는다.
if git check-ignore -q --no-index rd-workflow-workspace/.lifecycle/review-seals/sample.seal; then
  echo "중단: review-seals 가 ignore 됩니다 — 발행이 차단됩니다"; exit 1
else
  rc=$?
  case "$rc" in
    1) echo "ok: review-seals 는 추적 가능" ;;
    *) echo "중단: check-ignore 실행 오류 (exit $rc)"; exit 1 ;;
  esac
fi
echo "ok: ignore 규칙 검증 통과"
```

**6) 개인 내용의 내용 일치를 확인한 뒤에야 staging 을 정리한다.**

**주석으로 「MISMATCH 가 없으면」 이라고 적어 두고 그 아래에 `rm -rf` 를 두지 않는다.** 주석은 삭제를 막지
못한다 — 불일치가 나와도 `rm` 이 그대로 실행되어 **회수용 staging 이 사라진다** (재현 확인: `exit=0`,
`MISMATCH: PROJECT_CONTEXT.md`, staging 없음). 판정을 종료 코드로 만들고 **성공 분기에서만 정리**한다.

**채택한 경로도 검증에서 빼지 않는다.** 배포본을 가져오기로 한 것은 **기대값이 바뀌는 이유**이지 검증을
없앨 이유가 아니다 — 채택 후 파일이 누락되거나 잘못 편집돼도 유일한 회수본이 사라진다. 경로마다 기대값을
`$STAGE`(개인 유지) 또는 `$TPL/t`(배포본 채택)로 **고르고**, 존재·내용은 **언제나** 확인한다. 둘을 손으로
섞은 경로는 `MERGED` 에 적고 **존재·비어 있지 않음**까지는 확인한 뒤, 그 자리에서 `diff` 로 사람이 확정한다.

```bash
# 확보했던 파일이 overlay 에 있는지 확인한다. 열거 실패를 '대상 없음' 으로 읽지 않는다.
STAGE_LIST=$(mktemp)
( cd "$STAGE" && find . -type f -print ) > "$STAGE_LIST" \
  || { echo "중단: 개인 내용 staging 열거 실패 (staging 보존: $STAGE / 배포본: $TPL)"; exit 1; }
[ -s "$STAGE_LIST" ] \
  || { echo "중단: staging 목록이 비었습니다 (staging 보존: $STAGE / 배포본: $TPL)"; exit 1; }

rc=0
while IFS= read -r rel; do
  rel=${rel#./}
  [ -n "$rel" ] || continue
  [ -e "$rel" ] || { echo "MISSING: $rel"; rc=1; continue; }
  [ -r "$rel" ] || { echo "UNREADABLE: $rel"; rc=1; continue; }
  case " $MERGED " in
    *" $rel "*) [ -s "$rel" ] || { echo "EMPTY(merged): $rel"; rc=1; }
                echo "merged (사람 확정 필요): $rel"
                continue ;;
  esac
  case " $ADOPTED " in
    *" $rel "*) exp="$TPL/t/$rel" ;;     # 배포본을 채택한 경로 — 기대값이 배포본이다
    *)          exp="$STAGE/$rel" ;;     # 개인 내용을 유지한 경로
  esac
  diff -q "$exp" "$rel" >/dev/null 2>&1 \
    || { echo "MISMATCH: $rel (기대: $exp)"; rc=1; }
done < "$STAGE_LIST"

if [ "$rc" -ne 0 ]; then
  echo "중단: 개인 내용이 일치하지 않습니다. 회수용 staging 을 그대로 둡니다."
  echo "  개인 내용 staging : $STAGE"
  echo "  배포본 staging    : $TPL"
  echo "  위 목록을 확인해 overlay 를 고친 뒤 이 6)만 다시 실행하십시오."
  exit 1
fi

# 손으로 섞은 경로가 있으면 자동 정리하지 않는다. '확인이 필요하다' 고 표시한 바로 그 실행에서
# 비교 자료를 지우면 확인할 수가 없다. 확정은 사람이 하고, 정리도 사람이 한다.
if [ -n "$MERGED" ]; then
  echo "보류: 손으로 섞은 경로가 있어 staging 을 정리하지 않습니다."
  echo "  다른 경로의 비교는 모두 통과했습니다."
  for rel in $MERGED; do
    echo "  diff \"$STAGE/$rel\" \"$rel\"     # 개인 원본과"
    echo "  diff \"$TPL/t/$rel\" \"$rel\"     # 배포본과"
  done
  echo "  개인 staging: $STAGE"
  echo "  배포본      : $TPL"
  echo "  확인이 끝나면 직접 지우십시오:  rm -rf \"$STAGE\" \"$TPL\""
  rm -f "$STAGE_LIST" "$TPL_LIST"
else
  rm -f "$STAGE_LIST" "$TPL_LIST"
  rm -rf "$STAGE" "$TPL"
  echo "ok: 개인 내용 일치 확인 — staging 정리 완료"
fi
```

**7) 확인 항목과 경로 규약은 링크로 넘긴다.**

- 확인: [신규 설치 가이드의 「설치 확인」](team-overlay-fresh-install.md#install-check)
- 경로 규약 추가: [「PROJECT_CONTEXT 규약 추가」](team-overlay-fresh-install.md#project-context)

**8) overlay 커밋.**

**「새로 시작」 선택**도 같은 절차다 — 배포본 기준에 구 overlay 의 작업 산출물과 개인 설정을 얹는다.
그 「작업 산출물과 개인 설정」이 `PATHS` 로 덮이지 않는다면 **0단계 A-2 에서 목록에 넣어야** 이 약속이
실제로 지켜진다. A-2 를 건너뛰면 그 자산은 staging 에 없고, 6단계 3)이 배포본의 빈
`rd-workflow-workspace/` 를 채운 뒤 6)의 비교(= staging 목록 순회)도 누락을 보지 못한 채 끝난다.

## 검증 체크리스트

- [ ] `ls -la <소스디렉토리>` → overlay 심링크가 없다 (`ai` 포함)
- [ ] 0단계 B 의 `SKIP_FILES` 목록에 있던 파일의 bit 가 해제되어 있다
- [ ] 그 목록에 없던 `skip-worktree`·sparse checkout 설정은 그대로 있다
- [ ] `( cd <소스디렉토리> && cat "$(git rev-parse --git-path info/exclude)" )` → overlay 항목이 없고 내가 넣었던 다른 항목은 남아 있다
- [ ] `( cd <소스디렉토리> && HOOKS=$(git rev-parse --git-path hooks); grep -c overlay-branch-sync "$HOOKS"/post-checkout "$HOOKS"/post-merge )` → 0 (또는 파일 부재)
- [ ] 같은 hook 파일의 다른 도구(husky 등) 내용이 보존되어 있고 **실제로 동작한다**
- [ ] A-정리한 경로가 팀 repo 의 **HEAD 에서도** 사라졌다 (`git -C <소스디렉토리> ls-tree -r --name-only HEAD -- <경로>` 가 **성공하고 출력이 비어 있다**. `cat-file -e` 는 부재도 조회 오류도 exit 128 이라 쓰지 않는다 — 4-1 의 각주 참조)
- [ ] `git submodule status` → `<소스디렉토리>` 가 리비전과 함께 표시된다
- [ ] `git -C <소스디렉토리> branch` / `stash list` → 이관 전 목록과 같다
- [ ] `git -C <소스디렉토리> status --porcelain` / `--ignored --porcelain` → 이관 전 목록과 같다
- [ ] overlay 의 개인 문서(`PROJECT_CONTEXT.md`·`CLAUDE.md`·`rd-workflow-workspace/`) **내용**이 이관 전과 같다
- [ ] overlay 에 심링크가 하나도 복사되지 않았다 (`find . -maxdepth 2 -type l`)
- [ ] `.claude/settings.json` 과 `WORKING_WITH_AI.md` 가 있다
- [ ] 0단계 A-2 에서 고른 `EXTRA_PATHS`·`OLD_ONLY_MAP` 항목이 overlay 에 **내용 그대로** 있고, 소스에는 (팀 파일이 아닌 한) 남아 있지 않다
- [ ] 6단계 5 의 ignore 검증이 통과했다

## 일상 운용

새 구조에서 평소에 무엇이 보이고 어떻게 처리하는지는
[신규 설치 가이드의 「일상 운용」](team-overlay-fresh-install.md#daily-ops)에 있습니다.
