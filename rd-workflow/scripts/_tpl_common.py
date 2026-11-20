"""sync_template 하위 명령 공통 함수."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile


class TplError(Exception):
    """진입 모듈이 msg 를 stderr 에 내고 code 로 종료한다."""

    def __init__(self, code: int, msg: str) -> None:
        super().__init__(msg)
        self.code = code
        self.msg = msg


def out(*cols: str) -> None:
    """TAB 으로 이은 한 줄을 stdout 에 쓴다."""
    sys.stdout.write("\t".join(cols) + "\n")


def atomic_write(path: str, data: bytes) -> None:
    """같은 디렉터리의 임시 파일에 쓴 뒤 os.replace 로 바꾼다.

    symlink 면 링크가 가리키는 실경로 자리에서 교체한다(링크를 일반 파일로 바꾸지 않는다).
    원본이 있으면 그 권한을 잇고, 없으면 0o666 & ~umask 로 맞춘다(mkstemp 의 0600 을 쓰지 않는다).
    """
    target = os.path.realpath(path)
    d = os.path.dirname(target) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(target):
            shutil.copymode(target, tmp)
        else:
            um = os.umask(0)
            os.umask(um)
            os.chmod(tmp, 0o666 & ~um)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def git_path(project: str, name: str) -> str:
    """`git -C project rev-parse --git-path name` 의 절대 경로. git 저장소가 아니면 TplError."""
    try:
        r = subprocess.run(
            ["git", "-C", project, "rev-parse", "--git-path", name],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except OSError:
        raise TplError(2, "오류: git 을 실행할 수 없습니다")
    if r.returncode != 0:
        raise TplError(2, "오류: 프로젝트 루트가 git 저장소가 아닙니다: %s" % project)
    p = os.fsdecode(r.stdout).rstrip("\n")
    return os.path.abspath(os.path.join(project, p))


def _read_text_or_empty(path: str) -> str:
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "surrogateescape").rstrip("\r\n")
    except OSError:
        return ""


def read_version(root: str) -> str:
    """rd-workflow/VERSION, 없으면 ai/VERSION. 둘 다 없으면 빈 문자열. 끝 개행은 뺀다."""
    for rel in ("rd-workflow/VERSION", "ai/VERSION"):
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            return _read_text_or_empty(p)
    return ""


def prev_version(project: str) -> str:
    """git 디렉터리의 rd-tpl-prev-version 내용. 없으면 빈 문자열."""
    return _read_text_or_empty(git_path(project, "rd-tpl-prev-version"))


def require_clone(clone: str, project: str) -> None:
    """로컬 스크립트로 잘못 부른 경우(clone 과 프로젝트의 실경로가 같음)를 막는다."""
    if os.path.realpath(clone) == os.path.realpath(project):
        raise TplError(2, "오류: clone 의 스크립트로 실행하십시오")
