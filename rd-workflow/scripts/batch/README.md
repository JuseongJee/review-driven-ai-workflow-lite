# scripts/batch

`/fr batch` 오케스트레이터의 결정적 헬퍼 디렉토리.

- `batch_manifest.sh` — manifest JSON을 읽어 결정적 파생값만 반환하는 SSOT 헬퍼 (validate/next/set-state/skip-dependents/summary/verify-done). bash 3.2 호환(연관배열 미사용), jq 전제.
- `test_batch_manifest.sh` — 헬퍼 단위 테스트.

오케스트레이션 지능(선별·brainstorming 보강·의존 확정·요약)은 `claude_skills/fr/batch.md`(살아있는 Claude 세션) 소관입니다. 이 디렉토리는 규칙의 단일 출처이며 skill 문서는 여기로 위임합니다.
