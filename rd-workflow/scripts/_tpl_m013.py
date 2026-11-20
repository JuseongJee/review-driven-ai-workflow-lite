"""sync_template migrate M013 — CLAUDE.md 의 템플릿 규칙 절 정리 (기계 처리 + 결정 반영)."""
from __future__ import annotations

import difflib
import os
import subprocess
from typing import Dict, List, Optional, Tuple

from _tpl_common import TplError, atomic_write, git_path

MARKER = "<!-- rd-workflow:project-override -->"
INDEX_HEADING = "rd-workflow 규칙"
CLASSIFIER = os.path.join("rd-workflow", "scripts", "claudemd_rules_migrate.sh")
VALID = ("adopt", "keep", "defer")


class _Fail(Exception):
    pass


class _Abort(Exception):
    pass


def _split(data: bytes) -> Tuple[List[bytes], bool]:
    """\\n 기준 줄 목록(개행 제외)과 끝 개행 유무. 분류기(awk)의 줄 번호와 같게 센다."""
    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
        return lines, True
    return lines, False


def _join(lines: List[bytes], trailing_nl: bool) -> bytes:
    if not lines:
        return b""
    return b"\n".join(lines) + (b"\n" if trailing_nl else b"")


def _read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def _classify(clone: str, project: str) -> Tuple[List[Tuple[str, int, int, str, str]], Optional[str]]:
    """분류기 실행. 반환: (절 행 목록, index 상태). abort 면 _Abort, 종료코드≠0 이면 _Fail."""
    script = os.path.join(clone, CLASSIFIER)
    try:
        r = subprocess.run(
            ["bash", script, "classify", "CLAUDE.md", clone], cwd=project,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except OSError as e:
        raise _Fail("분류기를 실행할 수 없습니다: %s" % e)
    if r.returncode != 0:
        msg = os.fsdecode(r.stderr).strip().splitlines()
        raise _Fail("분류기 종료코드 %d: %s" % (r.returncode, msg[-1] if msg else "-"))
    rows: List[Tuple[str, int, int, str, str]] = []
    index = None
    for ln in r.stdout.decode("utf-8", "replace").splitlines():
        f = ln.split("\t")
        if f[0] == "abort":
            raise _Abort(f[1] if len(f) > 1 else "")
        if f[0] == "index":
            index = f[1] if len(f) > 1 else None
        elif len(f) >= 5:
            rows.append((f[0], int(f[1]), int(f[2]), f[3], f[4]))
    return rows, index


def _section(lines: List[bytes], heading: str) -> List[bytes]:
    """`## heading` 절(제목 줄부터 다음 `## ` 직전, 끝 빈 줄 제외). 없으면 빈 목록."""
    want = ("## " + heading).encode("utf-8")
    out: List[bytes] = []
    on = False
    for ln in lines:
        t = ln.rstrip(b" \t\r")
        if t.startswith(b"##") and (len(t) == 2 or t[2:3] in (b" ", b"\t")):
            if on:
                break
            on = t == want
        if on:
            out.append(ln)
    while out and out[-1].strip() == b"":
        out.pop()
    return out


def _remove(path: str, start: int, end: int) -> None:
    lines, nl = _split(_read(path))
    del lines[start - 1:end]
    atomic_write(path, _join(lines, nl))


def _mark(path: str, start: int) -> None:
    lines, nl = _split(_read(path))
    lines.insert(start, MARKER.encode("utf-8"))
    atomic_write(path, _join(lines, nl))


def _append_index(clone: str, path: str) -> None:
    sec = _section(_split(_read(os.path.join(clone, "CLAUDE.md")))[0], INDEX_HEADING)
    if not sec:
        raise _Fail("clone CLAUDE.md 에 `## %s` 절이 없습니다" % INDEX_HEADING)
    lines, nl = _split(_read(path))
    while lines and lines[-1].strip() == b"":
        lines.pop()
    if lines:
        lines.append(b"")
    lines.extend(sec)
    atomic_write(path, _join(lines, True))


def _pick(rows, decisions):
    for row in rows:
        if row[0] == "template":
            return row
        if row[0] == "modified" and decisions.get(row[3]) in ("adopt", "keep"):
            return row
    return None


def _loop(clone: str, project: str, path: str, decisions: Dict[str, str], det: Dict[str, List[str]]):
    """재분류 편집 루프: 매번 분류기를 새로 실행하고 첫 처리 대상 하나만 편집한다."""
    for _ in range(100000):
        rows, index = _classify(clone, project)
        row = _pick(rows, decisions)
        if row is None:
            return rows, index
        cls, start, end, heading, _dest = row
        if cls == "template" or decisions[heading] == "adopt":
            _remove(path, start, end)
            det["removed"].append(heading)
        else:
            _mark(path, start)
            det["override"].append(heading)
    raise _Fail("재분류 루프가 끝나지 않습니다")


def _gitignore_lines(project: str) -> List[str]:
    try:
        r = subprocess.run(
            ["git", "-C", project, "check-ignore", "-v", ".claude/rules/rd-workflow/core.md"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except OSError:
        return []
    txt = r.stdout.decode("utf-8", "replace").strip()
    if r.returncode != 0 or not txt:
        return []
    return [
        "gitignore\t%s\t.gitignore 의 해당 줄이 `.claude/` 폴더 전체를 가리면 `.claude/*` 로 바꾸고 다음 줄에 "
        "`!.claude/rules/` 를 넣은 뒤 같은 명령을 다시 실행해 출력이 없는지 확인하십시오 (MIGRATIONS.md M013)" % txt
    ]


def _fresh(clone: str, project: str, path: str, base: str,
           det: Dict[str, List[str]]) -> Tuple[str, List[str]]:
    """결정 없이 실행: template 절 제거, 목차 보충, 기준본·diff 저장."""
    diffdir = git_path(project, "rd-tpl-m013")
    # 이전 실행의 diff 를 치운다(번호가 겹쳐 낡은 diff 를 읽지 않게).
    if os.path.isdir(diffdir):
        for n in os.listdir(diffdir):
            if n.endswith(".diff"):
                os.remove(os.path.join(diffdir, n))
    rows, index = _loop(clone, project, path, {}, det)
    lines: List[str] = []
    indexed = False
    if index == "missing":
        _append_index(clone, path)
        det["index"].append("1")
        indexed = True
        rows, index = _classify(clone, project)
    modified = [r for r in rows if r[0] == "modified"]
    if modified:
        os.makedirs(diffdir, exist_ok=True)
        os.makedirs(os.path.dirname(base), exist_ok=True)
        atomic_write(base, _read(path))
        proj_lines = _split(_read(path))[0]
        for i, (_c, _s, _e, heading, dest) in enumerate(modified, 1):
            mine = _section(proj_lines, heading)
            theirs: List[bytes] = []
            if dest != "-":
                rp = os.path.join(clone, ".claude", "rules", "rd-workflow", dest)
                if os.path.isfile(rp):
                    theirs = _section(_split(_read(rp))[0], heading)
            a = [x.decode("utf-8", "replace") + "\n" for x in mine]
            b = [x.decode("utf-8", "replace") + "\n" for x in theirs]
            d = "".join(difflib.unified_diff(
                a, b, "CLAUDE.md (프로젝트: %s)" % heading,
                "rules/%s (템플릿: %s)" % (dest, heading)))
            dp = os.path.join(diffdir, "%d.diff" % i)
            atomic_write(dp, d.encode("utf-8"))
            lines.append("modified\t%s\t%s" % (heading, dp))
    else:
        if os.path.exists(base):
            os.remove(base)
    for r in rows:
        if r[0] == "ambiguous":
            lines.append("ambiguous\t%s" % r[3])
    lines += ["removed\t%s" % h for h in det["removed"]]
    if indexed:
        lines.append("index\t목차 절을 보충했습니다")
    lines += _gitignore_lines(project)
    if modified or any(x.startswith("gitignore\t") for x in lines):
        return "ASK", lines
    return ("APPLIED" if (det["removed"] or indexed) else "NOOP"), lines


def run(clone: str, project: str, decisions: Dict[str, str]) -> Tuple[str, List[str]]:
    for t, v in decisions.items():
        if v not in VALID:
            raise TplError(2, "오류: 결정 값은 adopt|keep|defer 입니다: %s=%s" % (t, v))
    path = os.path.join(project, "CLAUDE.md")
    if not os.path.isdir(os.path.join(clone, ".claude", "rules", "rd-workflow")) or not os.path.isfile(path):
        return "NOOP", []
    base = git_path(project, "rd-tpl-m013-base.md")
    if decisions and not os.path.isfile(base):
        raise TplError(2, "결정 없이 먼저 실행하십시오")
    det: Dict[str, List[str]] = {"removed": [], "override": [], "index": []}
    try:
        pre: List[str] = []
        if decisions and _read(base) != _read(path):
            pre = ["changed\tCLAUDE.md 가 결정을 받는 동안 바뀌어 다시 묻습니다"]
            decisions = {}
        if not decisions:
            st, lines = _fresh(clone, project, path, base, det)
            if pre:
                st = "ASK"
            return st, pre + lines
        rows, index = _loop(clone, project, path, decisions, det)
        indexed = False
        if index == "missing":
            _append_index(clone, path)
            det["index"].append("1")
            indexed = True
            rows, index = _classify(clone, project)
        os.remove(base)
        lines = ["removed\t%s" % h for h in det["removed"]]
        lines += ["override\t%s\t이 절과 rules 판이 함께 로드되므로 절 첫 줄에 대체 대상을 적으십시오" % h
                  for h in det["override"]]
        if indexed:
            lines.append("index\t목차 절을 보충했습니다")
        mods = {r[3] for r in rows if r[0] == "modified"}
        ask = False
        for t in decisions:
            if t not in mods and t not in det["removed"] and t not in det["override"]:
                lines.append("unknown-decision\t%s\t분류 결과에 modified 절로 없어 반영하지 않았습니다" % t)
                ask = True
        notice = False
        for t in sorted(mods):
            lines.append("deferred\t%s\t이 절과 rules 판이 두 벌로 로드되는 상태입니다" % t)
            notice = True
        lines += ["ambiguous\t%s" % r[3] for r in rows if r[0] == "ambiguous"]
        g = _gitignore_lines(project)
        lines += g
        if ask or g:
            return "ASK", lines
        if notice:
            return "NOTICE", lines
        return ("APPLIED" if (det["removed"] or det["override"] or indexed) else "NOOP"), lines
    except _Abort as e:
        return "ASK", ["abort\t%s\t편집하지 않았습니다. 사용자가 절 목록과 diff 를 보고 직접 정리한 뒤 sync 를 다시 실행하십시오" % e]
    except (_Fail, OSError) as e:
        # 이미 걷어낸 절·표식·덧붙인 목차는 파일에 반영된 상태이므로 함께 보고한다
        done = ["removed\t%s" % h for h in det["removed"]]
        done += ["override\t%s\t표식을 넣었습니다" % h for h in det["override"]]
        if det["index"]:
            done.append("index\t목차 절을 보충했습니다")
        if isinstance(e, OSError):
            target = getattr(e, "filename2", None) or e.filename
            where = " (%s)" % target if target else ""
            msg = ("파일 입출력 실패%s: %s. 위 줄의 변경은 CLAUDE.md 에 이미 반영됐습니다. "
                   "원인(디스크 공간·권한·경로 충돌)을 고친 뒤 결정 없이 `migrate M013` 을 다시 실행하십시오"
                   % (where, e.strerror or e))
        else:
            msg = str(e)
        return "FAIL", done + ["fail\t%s" % msg]
