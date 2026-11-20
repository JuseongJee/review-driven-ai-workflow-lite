"""apply 하위 명령 — 저장한 계획대로 복사·삭제하고 마지막에 VERSION 을 갱신한다 (spec 4.5)."""
from __future__ import annotations

import os
import shutil

from _tpl_classify import (
    PLAN_NAME, _overwrite_prefixes, classify, read_plan,
)
from _tpl_common import TplError, git_path, out, read_version, require_clone

VERSION_PATH = "rd-workflow/VERSION"
STALE = "오류: 분류 뒤 프로젝트가 바뀌었습니다 — classify 부터 다시"


def _parse(argv: list) -> tuple:
    delete = False
    excludes: list[str] = []
    it = iter(argv)
    for a in it:
        if a == "--delete":
            delete = True
        elif a == "--exclude":
            v = next(it, None)
            if v is None:
                raise TplError(2, "오류: --exclude 에 경로가 필요합니다")
            excludes.append(v)
        else:
            raise TplError(2, "오류: apply 의 알 수 없는 인자: %s" % a)
    return delete, excludes


def _key(e) -> tuple:
    return (e.cls, e.path, e.proj_fp, e.clone_fp)  # 근거 칸은 비교하지 않는다


def _why(old, new) -> str:
    """분류가 같은데 멈춘 경우, 어느 쪽 내용이 바뀌었는지 덧붙인다."""
    if old is None or new is None or old[0] != new[0]:
        return ""
    why = []
    if old[2] != new[2]:
        why.append("프로젝트 내용 바뀜")
    if old[3] != new[3]:
        why.append("clone 내용 바뀜")
    return " (%s)" % ", ".join(why) if why else ""


def _copy(clone: str, project: str, path: str) -> None:
    dst = os.path.join(project, path)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    src = os.path.join(clone, path)
    shutil.copyfile(src, dst)
    shutil.copymode(src, dst)


def _prune_empty_dirs(project: str, path: str) -> None:
    """지운 파일의 상위 디렉터리 중 비게 된 것을 덮어쓰기 prefix 루트 아래까지만 지운다."""
    roots = _overwrite_prefixes()
    parent = os.path.dirname(path)
    while parent:
        if not any(parent.startswith(r) for r in roots):  # prefix 루트 자신은 남긴다
            break
        try:
            os.rmdir(os.path.join(project, parent))
        except OSError:
            break
        parent = os.path.dirname(parent)


def main(sub: str, clone: str, project: str, argv: list) -> int:
    delete, excludes = _parse(argv)
    require_clone(clone, project)
    git_path(project, PLAN_NAME)
    plan_version, planned = read_plan(project)
    if plan_version != read_version(clone):
        raise TplError(1, "오류: 계획의 clone 버전이 지금 clone 과 다릅니다 — classify 부터 다시")
    planned_paths = {e.path for e in planned}
    for x in excludes:
        if x not in planned_paths:
            raise TplError(2, "오류: 계획에 없는 --exclude 경로: %s" % x)

    now = classify(clone, project)
    a = {e.path: _key(e) for e in planned}
    b = {e.path: _key(e) for e in now}
    if a != b:
        for p in sorted(set(a) | set(b), key=os.fsencode):
            if a.get(p) != b.get(p):
                out("changed", p, "계획: %s" % ("/".join(a[p][0:1]) if p in a else "없음"),
                    "지금: %s%s" % (b[p][0] if p in b else "없음", _why(a.get(p), b.get(p))))
        raise TplError(1, STALE)

    excluded = set(excludes)
    version_entry = None
    prev = read_version(project)
    try:
        for e in planned:
            if e.path == VERSION_PATH:
                version_entry = e
                continue
            if e.path in excluded:
                out("skipped", e.path, "exclude")
            elif e.cls in ("update", "add"):
                _copy(clone, project, e.path)
                out("copied" if e.cls == "update" else "added", e.path)
            elif e.cls == "delete":
                if not delete:
                    out("skipped", e.path, "delete-not-confirmed")
                else:
                    os.unlink(os.path.join(project, e.path))
                    out("deleted", e.path)
                    _prune_empty_dirs(project, e.path)
            elif e.cls == "ask":
                out("skipped", e.path, "ask")
        if version_entry is not None:
            if VERSION_PATH in excluded:
                out("skipped", VERSION_PATH, "exclude")
            elif version_entry.cls == "ask":
                out("skipped", VERSION_PATH, "ask")
            elif version_entry.cls in ("update", "add"):
                _copy(clone, project, VERSION_PATH)
                out("version", prev, read_version(project))
    except OSError as err:
        raise TplError(1, "오류: 복사·삭제 중 실패: %s" % err)
    return 0
