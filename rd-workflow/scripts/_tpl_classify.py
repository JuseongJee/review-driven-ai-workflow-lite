"""classify·policy 하위 명령 — 전파 정책 표(정본)와 2단계 분류.

정책 표 `POLICY` 가 정본이다 (sync_template.md 2.1 절 표를 옮긴 것).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from collections import namedtuple
from typing import Optional

from _tpl_common import TplError, atomic_write, git_path, out, read_version, require_clone

# (경로 패턴, 정책, 수정·삭제 가능성). 패턴은 정확한 경로이거나 '/' 로 끝나는 디렉터리 prefix 이고, 더 긴 패턴이 이긴다.
POLICY: list[tuple[str, str, str]] = [
    ('rd-workflow/scripts/', '덮어쓰기', '템플릿에 없는 파일은 3단계 확인 뒤 삭제합니다.'),
    ('rd-workflow/scripts/build.sh', '미전파', '프로젝트별 명령이 들어 있어 덮어쓰지도 지우지도 않습니다.'),
    ('rd-workflow/scripts/test.sh', '미전파', '프로젝트별 명령이 들어 있어 덮어쓰지도 지우지도 않습니다.'),
    ('rd-workflow/scripts/lint.sh', '미전파', '프로젝트별 명령이 들어 있어 덮어쓰지도 지우지도 않습니다.'),
    ('rd-workflow/scripts/typecheck.sh', '미전파', '프로젝트별 명령이 들어 있어 덮어쓰지도 지우지도 않습니다.'),
    ('rd-workflow/docs/', '덮어쓰기', '템플릿에 없는 파일은 3단계 확인 뒤 삭제합니다.'),
    ('rd-workflow/claude_skills/', '덮어쓰기', 'extension 으로 설치된 스킬(예: verify, design-review)은 삭제 후보에서 제외하고 보존합니다. 그 스킬의 최신본은 8단계가 다시 설치합니다.'),
    ('rd-workflow/extensions/', '덮어쓰기', '템플릿에 없는 파일은 삭제 후보입니다.'),
    ('rd-workflow/config/extensions.json.example', '덮어쓰기', '없음.'),
    ('rd-workflow/config/loop-guard.json.example', '덮어쓰기', '없음.'),
    ('rd-workflow/config/model-strategy.json.example', '덮어쓰기', '없음.'),
    ('rd-workflow/config/models.json.example', '덮어쓰기', '없음.'),
    ('rd-workflow/config/review-tools.json.example', '덮어쓰기', '없음.'),
    ('rd-workflow/config/workflow.json.example', '덮어쓰기', '없음.'),
    ('rd-workflow/config/extensions.json', '미전파', '설치된 extension 이력입니다. 8단계가 읽고 다시 씁니다.'),
    ('rd-workflow/config/models.json', '미전파', '프로젝트별 모델·effort 설정입니다.'),
    ('rd-workflow/config/review-tools.json', '미전파', '프로젝트별 리뷰 도구 설정입니다.'),
    ('rd-workflow/config/verification.json', '미전파', '프로젝트별 검증 설정입니다. 8.6 절의 verify preset 머지가 verifier 단위로 수정합니다.'),
    ('rd-workflow/config/workflow.json', '부재 시 생성', '5.1 절이 `defect_report_upstream` 키 하나만, 값이 비어 있을 때에 한해 씁니다. 다른 키와 경로 종류는 바뀌지 않습니다.'),
    ('rd-workflow/CHANGELOG.md', '덮어쓰기', '없음.'),
    ('rd-workflow/MIGRATIONS.md', '덮어쓰기', '없음.'),
    ('rd-workflow/VERSION', '덮어쓰기', '없음.'),
    ('.claude/rules/rd-workflow/', '덮어쓰기', '템플릿에 없는 파일은 삭제 후보입니다. 이 폴더 밖의 `.claude/rules/` 파일은 프로젝트 소유이며 보존합니다.'),
    ('.claude/settings.json', '부재 항목 머지', '템플릿 유래인데 가리키는 스크립트가 없어진 hook 등록은 제거됩니다(M005). 옛 표기 command 는 새 표기로 바뀌고 같은 group 안의 중복 등록은 접힙니다(M008). 템플릿 `permissions.allow` 의 부재 규칙은 추가됩니다(M015). 기존 permissions 와 프로젝트 고유 hook 은 보존됩니다.'),
    ('.claudeignore', '부재 시 생성', '경로가 있으면 건드리지 않습니다(보존 목록의 「… 등」에 속한다는 해석).'),
    ('.gitignore', '부재 항목 머지', '부재한 라인만 파일 끝에 추가합니다. 기존 라인은 바꾸지 않습니다. 이미 추적 중인 파일은 건드리지 않습니다. 새 ignore 패턴에 걸리는 기존 추적 파일의 추적 해제는 해당 마이그레이션의 안내가 처리합니다(예: M014).'),
    ('WORKING_WITH_AI.md', '덮어쓰기', '없음.'),
    ('CLAUDE.md', '부재 시 생성', '조건에 해당하는 기존 프로젝트는 M013 이 템플릿 규칙 절을 정리합니다.'),
    ('README.md', '미전파', '없음.'),
    ('PROJECT_CONTEXT.md', '부재 시 생성', '경로가 있으면 건드리지 않습니다.'),
    ('REQUEST.md', '조건부 보존', 'CURRENT_TASK.md 와 한 묶음으로 판정합니다. 두 파일 중 하나라도 템플릿 본 외의 줄이 남으면 둘 다 보존합니다(2절 A3). 조건 불충족이면 템플릿 본으로 바뀝니다.'),
    ('CURRENT_TASK.md', '조건부 보존', 'REQUEST.md 와 한 묶음으로 판정합니다. 두 파일 중 하나라도 템플릿 본 외의 줄이 남으면 둘 다 보존합니다(2절 A3). 조건 불충족이면 템플릿 본으로 바뀝니다.'),
    ('rd-workflow-workspace/backlog/FUTURE_REQUESTS.md', '조건부 보존', '표에 행이 있으면 보존합니다(2절 A1). 조건 불충족이면 템플릿 본으로 바뀝니다.'),
    ('rd-workflow-workspace/backlog/FUTURE_REQUESTS_PARKED.md', '조건부 보존', '표에 행이 있으면 보존합니다(2절 A1). 조건 불충족이면 템플릿 본으로 바뀝니다.'),
    ('rd-workflow-workspace/review-standards.md', '부재 시 생성', '프로젝트 리뷰 표준입니다. 경로가 있으면 건드리지 않습니다.'),
    ('rd-workflow-workspace/backlog/request-archive/', '미전파', '아카이브 파일을 덮어쓰거나 지우지 않습니다.'),
    ('rd-workflow-workspace/backlog/request-archive/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/backlog/items/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/specs/', '미전파', '작업 산출물을 덮어쓰거나 지우지 않습니다.'),
    ('rd-workflow-workspace/specs/base/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/specs/changes/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/plans/', '미전파', '작업 산출물을 덮어쓰거나 지우지 않습니다.'),
    ('rd-workflow-workspace/plans/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/handoffs/', '미전파', '작업 내용물을 덮어쓰거나 지우지 않습니다.'),
    ('rd-workflow-workspace/.lifecycle/', '미전파', 'sync 가 읽지도 쓰지도 않습니다.'),
    ('rd-workflow-workspace/raw-captures/', '미전파', 'capture 본문은 입력 원문이라 덮어쓰거나 지우지 않습니다.'),
    ('rd-workflow-workspace/raw-captures/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/reports/', '미전파', '보고서를 덮어쓰거나 지우지 않습니다.'),
    ('rd-workflow-workspace/reports/tier-log.md', '조건부 보존', '`light` 마감 기록이 쌓이는 파일입니다. 표에 행이 있으면 보존합니다(2절 A1). 조건 불충족이면 템플릿 본으로 바뀝니다.'),
    ('rd-workflow-workspace/reports/autopilot/.gitkeep', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/reports/completions/.gitkeep', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/reports/reviews/.gitkeep', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/reports/workflow-defects/.gitkeep', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/reports/completions/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/reports/reviews/README.md', '덮어쓰기', '없음.'),
    ('rd-workflow-workspace/reports/verifications/README.md', '덮어쓰기', '없음.'),
]


Entry = namedtuple("Entry", "cls path proj_fp clone_fp note policy")

OVERWRITE = "덮어쓰기"
MERGE = "부재 항목 머지"
CREATE = "부재 시 생성"
CONDITIONAL = "조건부 보존"
NOSYNC = "미전파"

A1_FILES = (
    "rd-workflow-workspace/backlog/FUTURE_REQUESTS.md",
    "rd-workflow-workspace/backlog/FUTURE_REQUESTS_PARKED.md",
    "rd-workflow-workspace/reports/tier-log.md",
)
A3_FILES = ("REQUEST.md", "CURRENT_TASK.md")  # 묶음 판정

# 2026-11-13 까지 archive 가 쓰던 CURRENT_TASK.md 초기본(_lifecycle_common.sh 의
# emit_current_task_baseline_legacy 와 같은 내용). 배포 템플릿에 없는 세 줄(`[REQUEST.md](REQUEST.md)`,
# `main`, `## Output Files`)이 있어, archive 를 거친 프로젝트가 매 update 마다 A3 보존이 됐습니다.
# 이 줄들도 템플릿 본 줄로 인정합니다. 고치지 않습니다.
A3_LEGACY_BASELINE = {
    "CURRENT_TASK.md": (
        "# Current Task\n\n## Task\n-\n\n## Short Title\n-\n\n## Status\n대기 중\n"
        "<!-- 허용 상태값은 .claude/rules/rd-workflow/task-tracking.md 참조. 변경은 rd task set-status 경유 -->\n\n"
        "## Request\n[REQUEST.md](REQUEST.md)\n\n## Source FR\n-\n"
        "<!-- 권위는 rd-workflow-workspace/.lifecycle/task-state. 변경은 rd task set-source-fr 경유 -->\n"
        "<!-- 복수(묶은 작업)이면 미러 쓰기가 자동으로 한 줄에 1건씩 나열합니다 — 여기 직접 목록을 적지 않습니다 -->\n\n"
        "## Spec\n-\n\n## Plan\n-\n\n"
        "## Branch / Worktree\nmain\n\n## Output Files\n-\n\n## Next Step\n-\n\n## Notes\n-\n"
    ),
}

PLAN_NAME = "rd-tpl-plan.tsv"
PLAN_HEAD = "# rd-tpl-plan v1"


def _hit(pattern: str, path: str) -> bool:
    return path.startswith(pattern) if pattern.endswith("/") else path == pattern


def policy_of(path: str) -> Optional[tuple]:
    """path 에 걸리는 POLICY 행 중 가장 긴 패턴. 없으면 None."""
    best = None
    for row in POLICY:
        if _hit(row[0], path) and (best is None or len(row[0]) > len(best[0])):
            best = row
    return best


def fingerprint(path: str) -> str:
    """missing | dir | link:<링크 대상> | file:<sha256>. 「있음」 은 lexists (dangling symlink 도 있음)."""
    if not os.path.lexists(path):
        return "missing"
    if os.path.islink(path):
        return "link:" + os.readlink(path)
    if os.path.isdir(path):
        return "dir"
    if not os.path.isfile(path):
        return "other"
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return "unreadable"
    return "file:" + h.hexdigest()


def _kind(fp: str) -> str:
    return fp.split(":", 1)[0]


def symlink_ancestor(project: str, path: str) -> Optional[str]:
    """프로젝트 루트 아래 상위 디렉터리(path 자신 제외) 중 첫 symlink 의 상대 경로. 없으면 None."""
    parts = path.split("/")
    for i in range(1, len(parts)):
        if os.path.islink(os.path.join(project, *parts[:i])):
            return "/".join(parts[:i])
    return None


def structure_pending(project: str) -> list:
    """남아 있는 구조 마이그레이션. M001: ai/ 있음 + rd-workflow/ 없음, M002: rd-workflow/workspace/ 있음 + rd-workflow-workspace/ 없음."""
    pending = []
    has = lambda rel: os.path.lexists(os.path.join(project, rel))  # noqa: E731
    if has("ai") and not has("rd-workflow"):
        pending.append("M001")
    if has("rd-workflow/workspace") and not has("rd-workflow-workspace"):
        pending.append("M002")
    return pending


# ---------------------------------------------------------------- A1 · A3

def _a1_count(text: str) -> Optional[int]:
    """첫 구분선 줄 뒤에서 '|' 로 시작하고 구분선이 아닌 줄의 수. 구분선이 없으면 None."""
    seen_sep = False
    n = 0
    for line in text.split("\n"):
        is_sep = line.startswith("|---") or line.startswith("| ---")
        if not seen_sep:
            seen_sep = is_sep
        elif line.startswith("|") and not is_sep:
            n += 1
    return n if seen_sep else None


def a1_has_rows(text: str) -> Optional[bool]:
    """True: 행 있음, False: 행 없음, None: 구분선 없음(판정 불가 — 호출 쪽이 보존으로 다룬다)."""
    n = _a1_count(text)
    if n is None:
        return None
    return n > 0


def _closes_clean(s: str) -> bool:
    return s.count("-->") == 1 and re.search(r"-->[ \t\r\n\f\v]*$", s) is not None


def _a3_strip_comments(text: str) -> list:
    """sync_template.md 의 awk 를 줄 단위로 옮긴 것. 주석만 있는 줄·블록을 뺀 나머지 줄."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    res: list = []
    in_c = False
    buf: list = []
    for line in lines:
        if in_c:
            buf.append(line)
            if "-->" in line:
                if _closes_clean(line) and "<!--" not in line:
                    buf = []
                res.extend(buf)
                buf = []
                in_c = False
            continue
        if re.match(r"[ \t\r\n\f\v]*<!--", line):
            n = line.count("<!--")
            if n == 1 and _closes_clean(line):
                continue
            if n == 1 and "-->" not in line:
                in_c = True
                buf = [line]
                continue
        res.append(line)
    if in_c:
        res.extend(buf)
    return res


def a3_remaining(proj_text: str, tpl_text: Optional[str], legacy_text: Optional[str] = None) -> list:
    """프로젝트 파일에서 빈 줄·주석만 있는 줄·clone 파일(또는 이전 초기본)에 글자 그대로 있는 줄을 뺀 남는 줄.

    tpl_text 가 None(clone 에 같은 이름 파일 없음)이면 세 번째 제외를 하지 않는다.
    """
    rest = [l for l in _a3_strip_comments(proj_text) if not re.fullmatch(r"[ \t\r\n\f\v]*", l)]
    if tpl_text is None:
        return rest
    tpl_lines = set(tpl_text.split("\n"))
    if legacy_text is not None:
        tpl_lines.update(legacy_text.split("\n"))
    return [l for l in rest if l not in tpl_lines]


def _read_text(path: str) -> Optional[str]:
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "surrogateescape")
    except OSError:
        return None


# ---------------------------------------------------------------- 수집·분류

def _walk_files(root: str, prune_git: bool) -> list:
    """root 아래 파일(과 파일 symlink)의 root 기준 상대 경로. symlink 디렉터리 안으로 들어가지 않는다."""
    res = []
    for d, dirs, files in os.walk(root, followlinks=False):
        if prune_git and d == root and ".git" in dirs:
            dirs.remove(".git")
        rel = os.path.relpath(d, root)
        for f in files:
            res.append(f if rel == "." else rel.replace(os.sep, "/") + "/" + f)
    return res


def _overwrite_prefixes() -> list:
    return [p for p, pol, _ in POLICY if pol == OVERWRITE and p.endswith("/")]


def _population(clone: str, project: str) -> list:
    paths = set(_walk_files(clone, True))
    for prefix in _overwrite_prefixes():
        root = os.path.join(project, prefix[:-1])
        if os.path.isdir(root) and not os.path.islink(root):
            paths.update(prefix + p for p in _walk_files(root, False))
    return sorted(paths, key=os.fsencode)


def _extension_names(clone: str, project: str) -> set:
    names = set()
    for root in (clone, project):
        d = os.path.join(root, "rd-workflow", "extensions")
        if os.path.isdir(d):
            names.update(n for n in os.listdir(d) if os.path.isdir(os.path.join(d, n)))
    text = _read_text(os.path.join(project, "rd-workflow", "config", "extensions.json"))
    if text is not None:
        try:
            ext = json.loads(text).get("extensions")
        except (ValueError, AttributeError):
            ext = None
        if isinstance(ext, dict):
            names.update(ext.keys())
        elif isinstance(ext, list):
            names.update(x for x in ext if isinstance(x, str))
    return names


def _is_extension_skill(path: str, names: set) -> bool:
    prefix = "rd-workflow/claude_skills/"
    if not path.startswith(prefix):
        return False
    rest = path[len(prefix):]
    return "/" in rest and rest.split("/", 1)[0] in names


def _clean(note: str) -> str:
    return note.replace("\r", "").replace("\t", " ").replace("\n", " ")


def _a3_bundle(clone: str, project: str) -> tuple:
    """(보존 여부, 근거). 두 파일 중 하나라도 남는 줄이 있거나 읽지 못하면 보존."""
    total = 0
    first = None
    unreadable = False
    for name in A3_FILES:
        pp = os.path.join(project, name)
        if not os.path.lexists(pp):
            continue
        text = _read_text(pp) if os.path.isfile(pp) and not os.path.islink(pp) else None
        if text is None:
            unreadable = True
            continue
        cp = os.path.join(clone, name)
        rest = a3_remaining(text, _read_text(cp) if os.path.isfile(cp) else None, A3_LEGACY_BASELINE.get(name))
        total += len(rest)
        if rest and first is None:
            first = rest[0]
    if unreadable:
        return True, "A3 읽지 못함"
    if total:
        return True, _clean("A3 남은 줄 %d개: %s" % (total, first))
    return False, ""


def _classify_path(path: str, clone: str, project: str, ext_names: set, bundle: tuple) -> Entry:
    pol = policy_of(path)
    policy = pol[1] if pol else ""
    pfp = fingerprint(os.path.join(project, path))
    cfp = fingerprint(os.path.join(clone, path))
    p_has = pfp != "missing"
    c_has = cfp != "missing"

    def entry(cls: str, note: str) -> Entry:
        if cls in ("update", "add", "delete"):
            anc = symlink_ancestor(project, path)
            if anc is not None:
                cls, note = "ask", "상위 경로 symlink: " + anc
        return Entry(cls, path, pfp, cfp, note, policy)

    def overwrite_like(same_note: str = "내용 다름") -> Entry:
        # 덮어쓰기·조건부 보존이 실제로 쓰는 경로: symlink·종류 불일치는 판단을 사용자에게 넘긴다
        if pfp == cfp:
            return entry("same", "")
        if _kind(pfp) == "link":
            return entry("ask", "symlink — 판단 필요")
        if _kind(pfp) != _kind(cfp):
            return entry("ask", "종류가 다름 — 판단 필요")
        return entry("update", same_note)

    if pol is None:
        return entry("ask", "전파 정책 표에 없음")
    if policy == OVERWRITE:
        if c_has and p_has:
            return overwrite_like()
        if c_has:
            return entry("add", "템플릿에만 있음")
        if _is_extension_skill(path, ext_names):
            return entry("keep", "extension 스킬")
        if _kind(pfp) == "link":
            return entry("ask", "symlink — 판단 필요")
        return entry("delete", "템플릿에 없음")
    if policy == MERGE:
        return entry("keep", "마이그레이션이 처리" if p_has else "M003 이 만듦")
    if policy == CREATE:
        return entry("keep", "부재 시 생성: 경로 있음") if p_has else entry("add", "부재 시 생성: 경로 없음")
    if policy == NOSYNC:
        if not c_has:
            return entry("keep", "미전파")
        return entry("keep", "미전파") if p_has else entry("add", "미전파: 경로 없음")
    # 조건부 보존
    if not c_has:
        return entry("keep", "조건부 보존")
    if not p_has:
        return entry("add", "조건부 보존: 경로 없음")
    if _kind(pfp) == "link":
        return entry("ask", "symlink — 판단 필요")
    if _kind(pfp) != "file" or _kind(cfp) != "file":
        return entry("ask", "종류가 다름 — 판단 필요")
    if path in A1_FILES:
        text = _read_text(os.path.join(project, path))
        if text is None:
            return entry("keep", "A1 읽지 못함")
        rows = a1_has_rows(text)
        if rows is None:
            return entry("keep", "A1 구분선 없음(판정 불가)")
        if rows:
            return entry("keep", "A1 행 %d개" % _a1_count(text))
        return overwrite_like()
    keep, note = bundle
    if keep:
        return entry("keep", note)
    return overwrite_like()


def classify(clone: str, project: str) -> list:
    """모집단 전체(same 포함)를 경로순 Entry 목록으로 돌려준다."""
    ext_names = _extension_names(clone, project)
    bundle = _a3_bundle(clone, project)
    return [_classify_path(p, clone, project, ext_names, bundle) for p in _population(clone, project)]


# ---------------------------------------------------------------- 계획 파일

def _plan_path(project: str) -> str:
    return git_path(project, PLAN_NAME)


def write_plan(project: str, clone_version: str, entries: list) -> None:
    lines = ["%s\tclone-version=%s" % (PLAN_HEAD, clone_version)]
    for e in entries:
        lines.append("\t".join((e.cls, e.path, e.proj_fp, e.clone_fp, e.note)))
    atomic_write(_plan_path(project), ("\n".join(lines) + "\n").encode("utf-8", "surrogateescape"))


def read_plan(project: str) -> tuple:
    path = _plan_path(project)
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8", "surrogateescape")
    except OSError:
        raise TplError(2, "오류: 계획 파일이 없습니다 — classify 를 먼저 실행하십시오")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    m = re.fullmatch(re.escape(PLAN_HEAD) + r"\tclone-version=(.*)", lines[0]) if lines else None
    if not m:
        raise TplError(2, "오류: 계획 파일 형식이 맞지 않습니다 — classify 를 다시 실행하십시오")
    entries = []
    for line in lines[1:]:
        if line.startswith("#") or not line:
            continue
        cols = line.split("\t")
        if len(cols) != 5:
            raise TplError(2, "오류: 계획 파일 형식이 맞지 않습니다 — classify 를 다시 실행하십시오")
        pol = policy_of(cols[1])
        entries.append(Entry(cols[0], cols[1], cols[2], cols[3], cols[4], pol[1] if pol else ""))
    return m.group(1), entries


def plan_refresh(clone: str, project: str, path: str, before_fp: str) -> None:
    """마이그레이션이 path 를 바꾼 뒤 계획 파일의 그 줄을 맞춘다 (spec 4.6 「계획 파일 갱신」).

    계획 파일이 없거나 그 경로 줄이 없거나 before_fp 가 계획의 프로젝트 지문과 다르면 아무것도 하지 않는다.
    """
    if not os.path.exists(_plan_path(project)):
        return
    version, entries = read_plan(project)
    idx = next((i for i, e in enumerate(entries) if e.path == path), None)
    if idx is None or entries[idx].proj_fp != before_fp:
        return
    old = entries[idx]
    new_fp = fingerprint(os.path.join(project, path))
    new = next((e for e in classify(clone, project) if e.path == path), None)
    if new is not None and (new.cls == old.cls or (old.cls == "update" and new.cls == "same")):
        entries[idx] = old._replace(cls=new.cls, proj_fp=new_fp, note=new.note)
    else:
        entries[idx] = old._replace(proj_fp=new_fp)  # 분류는 옛 값 — apply 가 불일치로 멈춘다
    write_plan(project, version, entries)


# ---------------------------------------------------------------- 하위 명령

def _cmd_policy() -> int:
    for row in POLICY:
        out(*row)
    return 0


def _cmd_classify(clone: str, project: str, argv: list) -> int:
    save = True
    for a in argv:
        if a == "--no-save":
            save = False
        else:
            raise TplError(2, "오류: classify 의 알 수 없는 인자: %s" % a)
    require_clone(clone, project)
    git_path(project, PLAN_NAME)  # git 저장소가 아니면 exit 2
    pending = structure_pending(project)
    if pending:
        for m in pending:
            out("ask", m, "구조 마이그레이션 먼저")
        return 3
    version = read_version(clone)
    entries = classify(clone, project)
    counts = {c: 0 for c in ("update", "add", "delete", "keep", "ask", "same")}
    out(PLAN_HEAD, "clone-version=" + version)
    for e in entries:
        counts[e.cls] += 1
        if e.cls != "same":
            out(e.cls, e.path, e.note)
    out("# 요약", *("%s=%d" % (c, counts[c]) for c in counts))
    if save:
        write_plan(project, version, entries)
    return 0


def main(sub: str, clone: str, project: str, argv: list) -> int:
    if sub == "policy":
        return _cmd_policy()
    return _cmd_classify(clone, project, argv)
