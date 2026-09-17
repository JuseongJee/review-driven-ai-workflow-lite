# Team Overlay 설치 가이드 (신규)

팀 프로젝트에 AI 워크플로 템플릿을 처음 설치할 때, 템플릿 파일을 팀 repo가 아닌 개인 private repo로 분리하여 관리하는 방법. 소스 코드는 git submodule로 개인 overlay repo에 편입한다.

## 언제 사용하는가

- 팀 프로젝트에서 나만 이 템플릿을 사용한다
- 템플릿 관련 파일(`rd-workflow/`, `CLAUDE.md`, `.claude/`)을 팀 repo에 커밋하고 싶지 않다
- 여러 컴퓨터에서 워크플로 산출물(handoffs, workspace 등)에 접근하고 싶다

<a id="structure"></a>
## 구조 — 무엇이 어디에 놓이는가

```
~/ai-overlays/myproject/          ← overlay repo (내 private repo)
├── .claude/                      ← Claude Code 설정 (hook 포함)
├── .claudeignore
├── .gitignore
├── .gitmodules                   ← submodule 등록 정보
├── CLAUDE.md
├── CURRENT_TASK.md
├── PROJECT_CONTEXT.md
├── REQUEST.md
├── WORKING_WITH_AI.md
├── rd-workflow/                  ← 워크플로 템플릿
├── rd-workflow-workspace/        ← 작업 산출물 (spec·plan·review·backlog)
└── <소스디렉토리>/                ← 팀 저장소 (git submodule)
    └── ... 팀 코드 ...
```

| 무엇 | 저장소 | 커밋이 가는 곳 |
|---|---|---|
| `<소스디렉토리>/` 안의 코드 | 팀 저장소 | **팀원 전원에게 전파** |
| 그 밖 overlay 루트의 모든 것 | 내 private overlay repo | 나만 |
| `<소스디렉토리>` 리비전 포인터 (gitlink) | overlay repo | 나만 |

팀 repo 워킹트리에는 아무것도 두지 않는다. symlink도, 개인 설정 파일도 없다. 그래서 팀 저장소에서 `git reset --hard`나 `git clean -fd`를 실행해도 overlay 설정이 함께 날아가지 않고, 머신을 옮길 때 팀 repo 쪽에 다시 무언가를 심을 필요도 없다. 개인 설정은 overlay repo 하나에만 존재하며, 팀 저장소는 `<소스디렉토리>` 안에 submodule로 편입되어 있을 뿐 그 자체로는 아무것도 모른다.

## 사전 준비

- GitHub (또는 다른 Git 호스팅)에 private repo를 하나 만든다
  - 예: `me/myproject-ai-overlay`
- 개인 overlay 디렉토리 경로를 정한다
  - 예: `~/ai-overlays/myproject/`

## 설치 절차

### 1. overlay repo 생성

```bash
mkdir -p ~/ai-overlays/myproject
cd ~/ai-overlays/myproject
git init -b main
# git 2.28 미만이면: git init && git branch -M main
```

### 2. 배포본 배치

```bash
# 임시 디렉토리를 직접 만들고, clone 성공을 확인한 뒤 복사한다
TMPL=$(mktemp -d)
git clone --depth 1 git@github.com:owner/ai-dev-template.git "$TMPL/template" || {
  echo "clone 실패 — 중단합니다"; rm -rf "$TMPL"; exit 1
}

# .git 을 제외한 배포본 루트 전체를 복사한다.
# 골라 복사하면 .claude/(hook 설정)·WORKING_WITH_AI.md·.gitignore 를 빠뜨린다.
rm -rf "$TMPL/template/.git"
cp -R "$TMPL/template/." ./

rm -rf "$TMPL"
```

**왜 통째로 옮기는가.** 배포본 `.gitignore`에는 "`review-seals/`는 반드시 추적해야 하고 `.lifecycle/`을 통째로 제외하면 발행이 차단된다" 같은, 개별 항목마다 이유가 있는 규칙이 담겨 있다. 필요해 보이는 파일만 손으로 골라 옮기면 이런 규칙이 조용히 빠지고, 나중에 워크플로가 원인을 알 수 없는 방식으로 망가진다. 통째로 복사하면 이런 실수를 원천적으로 막는다.

### 3. 소스 저장소를 submodule 로 추가

```bash
# <소스디렉토리> 는 보통 소스 repo 이름을 그대로 쓴다
git submodule add git@github.com:team/project.git <소스디렉토리>
```

### 4. .gitignore 에 overlay 고유 항목 추가

```bash
# 재작성하지 않고 덧붙인다
cat >> .gitignore <<'EOF'

# ── overlay 고유 ──
# 코드 본체(<소스디렉토리>)는 git submodule 이므로 이 파일이 다루지 않는다.
# submodule 내부 무시 규칙은 <소스디렉토리>/.gitignore 가 관리한다.
EOF
```

### 5. 첫 커밋과 push

```bash
git add -A
git commit -m "init: AI workflow overlay"
git remote add origin git@github.com:me/myproject-ai-overlay.git
git push -u origin main
```

<a id="install-check"></a>
## 설치 확인

설치가 조용히 반쯤 된 상태를 사용자가 알 수 있게 한다.

```bash
# 배포 자산이 다 왔는가
ls .claude/settings.json WORKING_WITH_AI.md .gitignore CLAUDE.md PROJECT_CONTEXT.md

# submodule 이 등록되고 소스가 체크아웃되었는가
git submodule status
ls <소스디렉토리>

# 런타임 로그가 추적 대상으로 잡히지 않는가 (배포 .gitignore 가 적용되는지)
git status --short
```

`.claude/settings.json`이 없으면 hook이 동작하지 않는다. 이 파일은 이후 설치 단계가 만들어 주지 않으므로, 여기서 빠졌으면 2단계로 돌아가 배포본을 다시 확인한다.

## 프로젝트 설정 이어가기

파일 복사와 submodule 편입이 완료되었으면, `rd-workflow/docs/guides/setup_with_claude.md`의 **3단계(PROJECT_CONTEXT.md 채우기)부터** 따라 진행한다.

```text
이 가이드대로 설정 이어해줘: rd-workflow/docs/guides/setup_with_claude.md (3단계부터)
```

이 단계에서 처리되는 항목:
- PROJECT_CONTEXT.md 채우기
- 검증 스크립트(build/test/lint/typecheck) 채우기
- Skill 설치
- 리뷰 도구 감지
- 확장 기능 설치 (선택)

<a id="project-context"></a>
## PROJECT_CONTEXT 규약 추가

`<소스디렉토리>`를 자기 값으로 바꿔 아래 블록을 `PROJECT_CONTEXT.md`에 붙여 넣는다.

```markdown
## Code Root

코드 본체는 이 저장소가 아니라 `<소스디렉토리>/` submodule 안에 있습니다.

- **문서·spec·plan·review 의 코드 경로는 overlay 루트 기준**으로 씁니다 —
  `<소스디렉토리>/src/...`. 접두어를 빠뜨리면 실재하지 않는 경로가 됩니다.
- **패키지 매니저·빌드·테스트 명령은 `<소스디렉토리>/` 안에서 실행**합니다.

## 팀 공유 영역

`<소스디렉토리>/` 는 팀 저장소입니다. **여기 커밋하는 것은 전부 팀원에게 전파됩니다.**

- 이 안의 `.gitignore` 는 팀 전체에 영향을 주므로 개인 사정으로 고치지 않습니다.
  개인 파일을 감춰야 하면 소스 저장소의 로컬 exclude 를 씁니다:
  `cd <소스디렉토리> && "$EDITOR" "$(git rev-parse --git-path info/exclude)"`
- AI 워크플로 산출물은 overlay 루트에만 둡니다.
```

`.git/info/exclude` 같은 직접 경로는 쓰지 않는다. submodule의 `.git`은 보통 gitdir을 가리키는 파일이라 그 경로가 존재하지 않으므로, 항상 `git rev-parse --git-path`로 실제 경로를 구한다.

## 다른 컴퓨터에서 설정

```bash
git clone --recurse-submodules git@github.com:me/myproject-ai-overlay.git ~/ai-overlays/myproject
cd ~/ai-overlays/myproject

# --recurse-submodules 를 빠뜨렸다면
git submodule update --init
```

clone 직후 소스는 detached HEAD 상태다. 브랜치를 붙이는 방법은 「일상 운용」을 따른다.

<a id="daily-ops"></a>
## 일상 운용

### 1. 명령의 실행 위치

| 무엇 | 어디서 |
|---|---|
| 패키지 매니저·빌드·테스트·린트 | 소스 디렉토리 안 |
| 워크플로 스크립트, Claude Code 세션 | overlay 루트 |
| 소스 코드의 git 작업 | 소스 디렉토리 안 |
| 워크플로 산출물의 git 작업 | overlay 루트 |

### 2. gitlink 변경

소스에서 커밋하거나 브랜치를 바꾸면 overlay의 `git status`에 `modified: <소스디렉토리> (new commits)` 한 줄이 잡힌다. 파일 내용이 아니라 **기록된 리비전 포인터**의 변경이다. 세 가지 중 하나를 선택한다 — 기록한다(overlay에서 커밋) / 되돌린다(`git submodule update`) / 무시한다(overlay 커밋에 포함하지 않는다).

### 3. `submodule.recurse` 켜고 끔

이 설정이 다음 항목(소스에 미커밋 작업이 있을 때)의 동작을 바꾸므로 먼저 설명한다.

```bash
# 현재 설정 확인 (global 에 이미 켜져 있을 수 있다)
git config --show-origin --get submodule.recurse

# overlay 저장소에만 켜기
git config submodule.recurse true

# 켜져 있을 때 소스를 건드리지 않고 한 번만 전환
git checkout --no-recurse-submodules <브랜치>
```

- **꺼져 있으면 (기본)**: overlay 브랜치를 바꿔도 소스 워킹트리는 그대로다. 소스 리비전을 맞추려면 `git submodule update`를 직접 실행한다.
- **켜져 있으면**: `checkout`·`switch`·`pull`이 소스 체크아웃까지 함께 시도한다. 소스에 미커밋 작업이 있으면 그 명령이 실패할 수 있다.

### 4. 소스에 미커밋 작업이 있을 때

recurse가 꺼져 있으면 overlay 브랜치 전환은 소스를 건드리지 않는다. 켜져 있거나 `git submodule update`를 실행하면 체크아웃이 시도되고, 충돌하면 git이 거부한다. **update 전에 소스에서 커밋하거나 stash**하고, 실패했으면 `git -C <소스디렉토리> status`로 상태를 확인한다.

### 5. 재귀 clone·update 뒤 detached HEAD 와 작업 브랜치 선택

`git clone --recurse-submodules`나 `git submodule update` 직후 소스는 **detached HEAD**다. 그대로 커밋하면 브랜치에 붙지 않아 잃기 쉽다.

```bash
cd <소스디렉토리>
git status                    # HEAD detached at <해시>
LC_ALL=C git remote show origin | sed -n 's/.*HEAD branch: *//p'   # 참고용 — 팀 저장소 기본 브랜치
git switch <브랜치>            # 자신이 작업할 브랜치로 (기본 브랜치가 아니어도 무방하다)
```

`LC_ALL=C`를 씌우는 이유: Git은 출력을 로케일에 맞춰 번역한다. 한국어 환경에서는 `HEAD branch:`가
`HEAD 브랜치:`로 나와 영문 문자열을 찾는 방식이 빗나간다. 로케일을 고정하면 어느 환경에서도 같은 줄을 집는다.

`.gitmodules`의 `branch` 항목은 `git submodule update --remote`가 따라갈 브랜치를 정할 뿐, 평소 체크아웃을 정하지 않는다.

### 6. 다른 머신 재현 조건

overlay에 기록된 소스 리비전이 **원격에서 접근 가능해야** 다른 머신이 체크아웃할 수 있다. **push 순서는 소스 먼저 → overlay 나중**이다 — overlay를 먼저 push하면, 그 안의 gitlink가 아직 원격에 없는 소스 커밋을 가리키게 되어 다른 머신에서 clone·update가 실패한다.

### 7. 구 hook 과의 차이

구 `overlay-branch-sync`는 **브랜치 이름 1:1 동기화**였고, 새 구조에서 git이 하는 일은 **리비전 복원**이다. 소스와 overlay의 브랜치 이름이 달라도 무방하다.

## 주의사항과 한계

- overlay repo의 커밋은 자동화되지 않는다. 작업 세션 끝에 수동으로 push한다.
- overlay는 팀 저장소 권한을 우회하지 않는다. submodule로 편입해도 push 권한이 없는 저장소에는 여전히 push할 수 없다.
- 소스를 팀원과 같은 브랜치에서 작업하면 gitlink가 자주 바뀐다. 기록할지 무시할지의 판단 기준은 「일상 운용」의 gitlink 변경 항목을 따른다.
- 구 `overlay-branch-sync` hook을 팀 repo에 설치해 둔 적이 있다면: 본체가 이 템플릿에서 제거되었다. 호출이 `|| true`로 감싸여 있어 **git 동작을 막지는 않고** `command not found` 소음만 남는다. 급하지 않으니 편할 때 정리하면 되며, 절차는 마이그레이션 가이드에 있다.
