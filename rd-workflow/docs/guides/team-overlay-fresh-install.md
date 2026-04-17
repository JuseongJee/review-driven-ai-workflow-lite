# Team Overlay 설치 가이드 (신규)

팀 프로젝트에 AI 워크플로 템플릿을 처음 설치할 때, 템플릿 파일을 팀 repo가 아닌 개인 private repo로 분리하여 관리하는 방법.

## 언제 사용하는가

- 팀 프로젝트에서 나만 이 템플릿을 사용한다
- 템플릿 관련 파일(`rd-workflow/`, `CLAUDE.md`, `.claude/`)을 팀 repo에 커밋하고 싶지 않다
- 여러 컴퓨터에서 워크플로 산출물(handoffs, workspace 등)에 접근하고 싶다

## 사전 준비

- GitHub (또는 다른 Git 호스팅)에 private repo를 하나 만든다
  - 예: `me/myproject-ai-overlay`
- 개인 overlay 디렉토리 경로를 정한다
  - 예: `~/ai-overlays/myproject/`

## 설치 절차

### 1. 개인 overlay repo 생성

```bash
# overlay 디렉토리 생성
mkdir -p ~/ai-overlays/myproject
cd ~/ai-overlays/myproject
git init

# 템플릿 파일 복사 (ai-dev-template repo에서)
# 방법 A: 배포 repo에서 직접 복사
cp -r /path/to/ai-dev-template/rd-workflow/ .
cp /path/to/ai-dev-template/CLAUDE.md .
cp /path/to/ai-dev-template/CURRENT_TASK.md .
cp /path/to/ai-dev-template/REQUEST.md .
cp /path/to/ai-dev-template/PROJECT_CONTEXT.md .

# 방법 B: 배포 repo를 임시 clone해서 복사
git clone --depth 1 git@github.com:owner/ai-dev-template.git /tmp/ai-template
cp -r /tmp/ai-template/rd-workflow/ .
cp /tmp/ai-template/CLAUDE.md .
cp /tmp/ai-template/CURRENT_TASK.md .
cp /tmp/ai-template/REQUEST.md .
cp /tmp/ai-template/PROJECT_CONTEXT.md .
rm -rf /tmp/ai-template

# 초기 커밋 + push
git add -A
git commit -m "init: AI workflow overlay for myproject"
git remote add origin git@github.com:me/myproject-ai-overlay.git
git push -u origin main
```

### 2. 팀 프로젝트에 symlink 연결

```bash
cd /path/to/team-project

# symlink 생성
ln -s ~/ai-overlays/myproject/ai ai
ln -s ~/ai-overlays/myproject/CLAUDE.md CLAUDE.md
ln -s ~/ai-overlays/myproject/CURRENT_TASK.md CURRENT_TASK.md
ln -s ~/ai-overlays/myproject/REQUEST.md REQUEST.md
ln -s ~/ai-overlays/myproject/PROJECT_CONTEXT.md PROJECT_CONTEXT.md
```

### 3. 팀 repo에서 무시 설정

**방법 A: `.gitignore`에 추가 (팀에 공유 가능한 경우)**

```bash
cat >> .gitignore << 'EOF'
rd-workflow/
CLAUDE.md
CURRENT_TASK.md
REQUEST.md
PROJECT_CONTEXT.md
.claude/
EOF

git add .gitignore
git commit -m "chore: AI workflow 개인 설정 파일 ignore"
```

**방법 B: `.git/info/exclude` 사용 (팀 repo 변경 불가한 경우)**

```bash
cat >> .git/info/exclude << 'EOF'
rd-workflow/
CLAUDE.md
CURRENT_TASK.md
REQUEST.md
PROJECT_CONTEXT.md
.claude/
EOF
```

### 4. 프로젝트 설정

파일 복사와 symlink가 완료되었으면, `rd-workflow/docs/guides/setup_with_claude.md`의 **3단계(PROJECT_CONTEXT.md 채우기)부터** 따라 진행한다.

```text
이 가이드대로 설정 이어해줘: rd-workflow/docs/guides/setup_with_claude.md (3단계부터)
```

이 단계에서 처리되는 항목:
- PROJECT_CONTEXT.md 채우기
- 검증 스크립트(build/test/lint/typecheck) 채우기
- Skill 설치
- 리뷰 도구 감지
- 확장 기능 설치 (선택)

### 5. setup.sh 생성 (다른 컴퓨터용)

개인 overlay repo에 setup script를 넣어둔다:

```bash
cat > ~/ai-overlays/myproject/setup.sh << 'SCRIPT'
#!/bin/bash
# 사용법: team-project 루트에서 실행
#   bash ~/ai-overlays/myproject/setup.sh

OVERLAY_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(pwd)"

if [ ! -d "$PROJECT_DIR/.git" ]; then
  echo "error: git repo 루트에서 실행하세요"
  exit 1
fi

# 기존 파일/디렉토리 제거
for f in ai CLAUDE.md CURRENT_TASK.md REQUEST.md PROJECT_CONTEXT.md .claude; do
  rm -rf "$PROJECT_DIR/$f"
done

# symlink 생성
ln -s "$OVERLAY_DIR/ai" "$PROJECT_DIR/ai"
for f in CLAUDE.md CURRENT_TASK.md REQUEST.md PROJECT_CONTEXT.md; do
  [ -f "$OVERLAY_DIR/$f" ] && ln -s "$OVERLAY_DIR/$f" "$PROJECT_DIR/$f"
done
[ -d "$OVERLAY_DIR/.claude" ] && ln -s "$OVERLAY_DIR/.claude" "$PROJECT_DIR/.claude"

# .git/info/exclude 설정
for f in "rd-workflow/" "CLAUDE.md" "CURRENT_TASK.md" "REQUEST.md" "PROJECT_CONTEXT.md" ".claude/"; do
  grep -qxF "$f" "$PROJECT_DIR/.git/info/exclude" 2>/dev/null || echo "$f" >> "$PROJECT_DIR/.git/info/exclude"
done

echo "done: $PROJECT_DIR ← $OVERLAY_DIR"
SCRIPT

chmod +x ~/ai-overlays/myproject/setup.sh
cd ~/ai-overlays/myproject
git add setup.sh
git commit -m "chore: setup script 추가"
git push
```

### 6. 다른 컴퓨터에서 설정

```bash
# 1. 팀 repo clone
git clone git@github.com:team/project.git
cd project

# 2. 개인 overlay clone
git clone git@github.com:me/myproject-ai-overlay.git ~/ai-overlays/myproject

# 3. setup 실행
bash ~/ai-overlays/myproject/setup.sh
```

## 일상 작업 흐름

```bash
cd team-project

# 평소 작업 — rd-workflow/ 파일은 symlink를 통해 자연스럽게 접근
# Claude Code, autopilot 등 모두 정상 동작

# 팀 작업 커밋 (rd-workflow/ 파일은 .gitignore/exclude로 무시됨)
git add src/
git commit -m "feat: 새 기능"

# AI 워크플로 산출물 커밋 (개인 overlay repo)
cd ~/ai-overlays/myproject
git add -A
git commit -m "chore: handoff 산출물 업데이트"
git push
```

## 주의사항

- `rd-workflow/` 내부에서 절대경로를 사용하는 스크립트가 있으면 symlink 환경에서 깨질 수 있다. 상대경로를 사용한다.
- `.git/info/exclude` 방식은 `git reset --hard`, `git clean -fd` 시 symlink가 삭제될 수 있다. setup.sh를 다시 실행하면 복구된다.
- overlay repo의 커밋은 자동화되지 않는다. 작업 세션 끝에 수동으로 push하거나, hook으로 자동화할 수 있다.
