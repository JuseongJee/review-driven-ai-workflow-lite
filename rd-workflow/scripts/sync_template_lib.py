#!/usr/bin/env python3
"""sync_template.sh 하위 명령 진입 모듈.

사용: sync_template_lib.py <하위 명령> <clone 루트> [인자...]
프로젝트 루트는 현재 디렉터리다. 표준 라이브러리만 쓰고 python 3.9 이상에서 동작한다.
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # clone 의 scripts/ 에 __pycache__ 를 남기지 않는다 (분류 모집단 오염 방지)

if sys.version_info < (3, 9):
    sys.stderr.write("오류: python3 3.9 이상이 필요합니다 (지금 %d.%d)\n" % sys.version_info[:2])
    sys.exit(2)

import importlib
import os

SUBCOMMANDS = {
    "policy": "_tpl_classify",
    "classify": "_tpl_classify",
    "apply": "_tpl_apply",
    "migrate": "_tpl_migrate",
    "reinstall": "_tpl_reinstall",
    "changelog": "_tpl_changelog",
}


def run(argv: list[str]) -> int:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="surrogateescape")
    if len(argv) < 2 or argv[0] not in SUBCOMMANDS:
        sys.stderr.write("사용법: sync_template.sh <%s> ...\n" % "|".join(SUBCOMMANDS))
        return 2
    sub, clone_root, rest = argv[0], argv[1], argv[2:]
    from _tpl_common import TplError
    try:
        module = importlib.import_module(SUBCOMMANDS[sub])
        return module.main(sub, os.path.abspath(clone_root), os.getcwd(), rest)
    except TplError as e:
        sys.stderr.write(e.msg + "\n")
        return e.code
    except ModuleNotFoundError as e:
        if e.name != SUBCOMMANDS[sub]:
            raise
        sys.stderr.write("오류: 하위 명령 모듈이 없습니다: %s\n" % SUBCOMMANDS[sub])
        return 2


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
