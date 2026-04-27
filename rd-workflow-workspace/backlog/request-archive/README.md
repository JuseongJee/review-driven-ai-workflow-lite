# Request Archive

완료된 `REQUEST.md`를 보관하는 디렉토리입니다.

## 목적

- 과거 작업 요청의 이력을 추적할 수 있게 합니다
- git log 없이도 어떤 작업이 있었는지 빠르게 확인할 수 있습니다
- 비슷한 작업을 다시 할 때 과거 REQUEST를 참고할 수 있습니다

## 파일명 형식

`YYYY-MM-DD-HHMM-작업명.md`

## 언제 아카이브하나

- 작업이 완료(`done`)되어 `CURRENT_TASK.md`를 초기화할 때
- 새 REQUEST로 `REQUEST.md`를 덮어쓰기 전에

## 아카이브 방법

1. 현재 `REQUEST.md` 내용을 이 디렉토리에 날짜-작업명 형식으로 복사합니다
2. `REQUEST.md`를 새 내용으로 교체합니다

> **자세한 절차는 아래 `## 수동 REQUEST archive 절차` 참조.** raw-capture archive 와 `CURRENT_TASK.md ## Short Title` reset 단계 포함.

## 수동 REQUEST archive 절차 (autopilot 미사용 흐름)

archive 실행 주체는 Claude (CLAUDE.md 의 Task Tracking 섹션 규약). 사용자가 archive 트리거.

1. **REQUEST.md 복사:**
   ```bash
   # assert_no_symlink_in_path: POSIX dirname 반복으로 절대경로 component 단위 traverse
   # bash/sh/zsh/dash 호환 — local 미사용, IFS split 의존 안 함
   assert_no_symlink_in_path() {
     _aslnp_p="$1"
     case "$_aslnp_p" in
       /*) ;;
       *)  _aslnp_p="$PWD/$_aslnp_p" ;;
     esac
     _aslnp_d="$_aslnp_p"
     while [ "$_aslnp_d" != "/" ] && [ -n "$_aslnp_d" ]; do
       if [ -L "$_aslnp_d" ]; then
         echo "경고: path component ($_aslnp_d) 가 symlink 입니다. 보안상 중단합니다." >&2
         unset _aslnp_p _aslnp_d
         return 1
       fi
       _aslnp_d=$(dirname "$_aslnp_d")
     done
     unset _aslnp_p _aslnp_d
     return 0
   }

   # collision-safe: 원본 basename 보존하면서 -2, -3 suffix 부여
   # (DEST 를 제자리 갱신하면 -2-3 누적이 되므로 BASE 를 immutable 로 유지)
   # SHORT_TITLE 은 CURRENT_TASK.md ## Short Title 에서 read (canonical 검증된 값)
   BASE="rd-workflow-workspace/backlog/request-archive/{YYYY-MM-DD-HHMM}-${SHORT_TITLE}.md"
   DEST="$BASE"

   # 조상 경로 symlink escape 방어
   assert_no_symlink_in_path "$(dirname "$DEST")" || exit 1

   N=2
   while [ -e "$DEST" ] || [ -L "$DEST" ]; do
     DEST="${BASE%.md}-${N}.md"
     N=$((N+1))
   done
   # DEST 자체가 symlink 면 거부
   if [ -L "$DEST" ]; then
     echo "경고: archive 대상 ($DEST) 이 symlink 입니다. 보안상 중단합니다." >&2
     exit 1
   fi
   cp REQUEST.md "$DEST"
   ```

2. **같은 short-title 의 raw capture 이동 (frontmatter exact match — collision-safe, macOS/zsh-safe):**
   ```bash
   # SHORT_TITLE 은 CURRENT_TASK.md ## Short Title 에서 read
   SHORT_TITLE="..."
   archive_dir="rd-workflow-workspace/raw-captures/archive"
   parent_dir="rd-workflow-workspace/raw-captures"

   # 조상 경로 symlink escape 방어
   assert_no_symlink_in_path "$archive_dir" || exit 1

   # 디렉토리 생성 + 권한 hardening (기존 0755 보정 포함)
   mkdir -p "$archive_dir"
   chmod 0700 "$parent_dir"
   chmod 0700 "$archive_dir"

   for STAGE in request spec plan; do
     find rd-workflow-workspace/raw-captures -maxdepth 1 -type f -name "*-${STAGE}-*.md" 2>/dev/null \
       | while IFS= read -r f; do
           if awk -v t="${SHORT_TITLE}" -v s="${STAGE}" '
               BEGIN{c=0; st=0; sg=0}
               /^---$/{c++; if(c==2)exit}
               c==1 && $0=="short-title: " t {st=1}
               c==1 && $0=="stage: " s {sg=1}
               END{exit !(st && sg)}
             ' "$f"; then
             mv "$f" "$archive_dir/"
           fi
         done
   done
   ```
   `fr` stage 캡처는 `/fr archive` 책임 — 여기서는 이동 안 함. filename glob 대신 frontmatter `short-title:` + `stage:` 둘 다 검증 → `foo` 와 `foo-bar` 충돌 방지.

3. **`CURRENT_TASK.md ## Short Title` reset:**
   default 값 `-` 로 복귀.

4. **REQUEST.md 비우기:**
   초기 템플릿 상태로 reset (또는 새 REQUEST 로 덮어쓰기).
