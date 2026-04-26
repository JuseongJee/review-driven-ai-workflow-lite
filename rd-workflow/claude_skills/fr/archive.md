## /fr archive

`FUTURE_REQUESTS.md` 인덱스에서 종료 상태(`done`/`dropped`) 항목을 일괄 삭제한다. 상세 파일(`items/`)은 삭제하지 않는다.

### 절차

1. `rd-workflow-workspace/backlog/FUTURE_REQUESTS.md` 읽기.
2. 인덱스에서 status가 `done` 또는 `dropped`인 행을 모두 찾는다.
3. 대상이 0건이면 "삭제할 종료 항목이 없습니다" 출력 후 종료.
4. 대상 행을 인덱스에서 일괄 삭제한다.
5. 완료 메시지 출력: "archive 완료: done {N}건, dropped {M}건 인덱스에서 삭제"
6. archive 대상 항목들의 short-title 을 모은다 — Step 2 에서 식별한 done/dropped 대상 행의 두 번째 컬럼 (short-title) 을 `TITLES` 배열로 수집. **Step 4 의 인덱스 행 삭제 전에 추출하거나 임시 보관해 두어야 함** (삭제 후에는 행 데이터 접근 불가).
7. 각 short-title에 대해 frontmatter 기반 exact match로 `fr` stage 캡처를 `rd-workflow-workspace/raw-captures/archive/` 로 이동한다 (collision-safe matcher):
   ```bash
   mkdir -p rd-workflow-workspace/raw-captures/archive
   for SHORT_TITLE in "${TITLES[@]}"; do
     find rd-workflow-workspace/raw-captures -maxdepth 1 -type f -name "*-fr-*.md" 2>/dev/null \
       | while IFS= read -r f; do
           if awk -v t="${SHORT_TITLE}" -v s="fr" '
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
   - 디렉토리 없으면 생성
   - 매칭 0건이면 skip (경고 없음)
   - `request`/`spec`/`plan` stage 캡처는 이동 안 함 (REQUEST archive 책임)
8. 완료 메시지에 "raw capture 이동: {N}건" 추가

### 규칙

- `done`과 `dropped` 상태 모두 대상이다. 두 상태 모두 종료 상태이며, 상세 파일에서 원래 상태를 추적할 수 있다.
- 상세 파일(`items/*.md`)은 삭제하지 않는다 — 이력 보존. done/dropped 구분은 상세 파일의 status 필드로 유지된다.
- 인덱스 테이블 형식을 변경하지 않는다.
