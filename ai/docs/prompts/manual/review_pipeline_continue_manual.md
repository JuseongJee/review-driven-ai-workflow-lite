# 리뷰 파이프라인 이어가기 (수동)

아래 세션 경로의 리뷰를 이어가세요.

## 절차

1. `SESSION.md`를 읽어 현재 상태를 파악합니다.
2. `Current Owner`가 `Author`이면:
   - 최신 Reviewer 턴을 읽습니다.
   - 지적 사항에 대해 Author 턴을 작성합니다.
   - 턴 파일명: `NNN_author.md` (NNN은 다음 번호)
3. `Current Owner`가 `Reviewer`이면:
   - 최신 Author 턴을 읽습니다.
   - `bash ai/scripts/run_review_turn.sh <session-path>`를 실행합니다.
   - CLI를 사용할 수 없으면 직접 Reviewer 턴을 작성합니다.
4. 최신 Reviewer 턴이 `이의 없음`을 명시하면 리뷰를 종료합니다.
5. 총 턴이 제한(기본 20)에 도달하면 남은 쟁점을 정리하고 `awaiting-user`로 전환합니다.
