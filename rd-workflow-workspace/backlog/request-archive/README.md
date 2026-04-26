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
   # collision-safe: 원본 basename 보존하면서 -2, -3 suffix 부여
   # (DEST 를 제자리 갱신하면 -2-3 누적이 되므로 BASE 를 immutable 로 유지)
   BASE="rd-workflow-workspace/backlog/request-archive/{YYYY-MM-DD-HHMM}-{title}.md"
   DEST="$BASE"
   N=2
   while [ -e "$DEST" ]; do
     DEST="${BASE%.md}-${N}.md"
     N=$((N+1))
   done
   cp REQUEST.md "$DEST"
   ```

2. **같은 short-title 의 raw capture 이동 (frontmatter exact match — collision-safe, macOS/zsh-safe):**
   ```bash
   # SHORT_TITLE 은 CURRENT_TASK.md ## Short Title 에서 read
   SHORT_TITLE="..."
   mkdir -p rd-workflow-workspace/raw-captures/archive
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
             mv "$f" rd-workflow-workspace/raw-captures/archive/
           fi
         done
   done
   ```
   `fr` stage 캡처는 `/fr archive` 책임 — 여기서는 이동 안 함. filename glob 대신 frontmatter `short-title:` + `stage:` 둘 다 검증 → `foo` 와 `foo-bar` 충돌 방지.

3. **`CURRENT_TASK.md ## Short Title` reset:**
   default 값 `-` 로 복귀.

4. **REQUEST.md 비우기:**
   초기 템플릿 상태로 reset (또는 새 REQUEST 로 덮어쓰기).
