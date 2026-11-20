"""sync_template changelog — 9단계 「변경 이력 보이기」. CHANGELOG 를 읽기만 한다."""
from __future__ import annotations

import os
import re
import sys

from _tpl_common import TplError, git_path

_DATE = r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}"
_FULL = re.compile("^" + _DATE + "$")
_ANY = re.compile(_DATE)
CAP = 40


def _read(path: str) -> str:
    """bash 의 $(cat) 처럼 끝 개행을 모두 뗀다. 값은 문자열로만 쓴다."""
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "surrogateescape").rstrip("\n")
    except OSError:
        return ""


def _say(msg: str) -> None:
    sys.stdout.write(msg + "\n")


def _lite_strip(v: str) -> str:
    return v[5:] if v.startswith("lite-") else v


def main(sub: str, clone: str, project: str, argv: list) -> int:
    pv = git_path(project, "rd-tpl-prev-version")
    prev = _read(pv) if os.path.isfile(pv) else ""
    cur = _read(os.path.join(project, "rd-workflow", "VERSION"))
    f = "rd-workflow/CHANGELOG.md"
    fpath = os.path.join(project, f)
    p, c = _lite_strip(prev), _lite_strip(cur)

    if not os.path.isfile(fpath):
        _say("템플릿 변경 이력: 받은 템플릿에 %s 가 없어 보여 줄 변화가 없습니다." % f)
        return 0
    if not _FULL.match(p):
        _say("템플릿 변경 이력: 이전 VERSION 을 알 수 없어(값: '%s') 새 변화를 고르지 못했습니다. %s 를 직접 확인하십시오."
             % (prev or "없음", f))
        return 0
    if _FULL.match(c) and not c > p:
        _say("템플릿 변경 이력: 받은 VERSION(%s)이 이전 VERSION(%s)보다 뒤가 아니어서 새 변화가 없습니다." % (cur, prev))
        return 0

    with open(fpath, "rb") as fh:
        text = fh.read().decode("utf-8", "surrogateescape")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()

    heads: list = []
    bodies: list = []
    cnts: list = []
    cur_i = -1
    inold = False
    start = ""
    for line in lines:
        if line.startswith("## "):
            h = line[3:]
            cur_i = -1
            inold = h == "그 이전"
            if h == "다음 발행" or (_FULL.match(h) and h > p):
                heads.append(line)
                bodies.append(line + "\n")
                cnts.append(0)
                cur_i = len(heads) - 1
            continue
        if inold and start == "":
            m = _ANY.search(line)
            if m:
                start = m.group(0)
        if cur_i >= 0:
            bodies[cur_i] += line + "\n"
            if line.startswith("- "):
                cnts[cur_i] += 1

    keep = [i for i in range(len(heads)) if cnts[i] > 0]
    total = sum(cnts[i] for i in keep)
    if not keep:
        _say("템플릿 변경 이력: 이전 VERSION(%s) 뒤로 기록된 변화가 없습니다." % p)
        return 0
    _say("템플릿 변경 이력 (이전 VERSION %s 뒤의 절):" % p)
    if total <= CAP:
        for i in keep:
            sys.stdout.write(bodies[i])
    else:
        sys.stdout.write(bodies[keep[0]])
        for i in keep[1:]:
            _say("%s — 항목 %d개" % (heads[i], cnts[i]))
        _say("항목이 %d개라 가장 최근 절만 전문으로 보였습니다. 전체는 %s 에 있습니다." % (total, f))
    if start != "" and p < start:
        _say("이전 VERSION 이 기록 시작(%s)보다 오래되어 그 사이 변화 일부는 기록에 없습니다. 구조 전환은 rd-workflow/MIGRATIONS.md 를 봅니다." % start)
    if prev.split("-", 1)[0] == "lite":
        _say("「(full)」 표시 항목은 lite 배포본에 없습니다.")
    return 0
