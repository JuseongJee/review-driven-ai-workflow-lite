#!/usr/bin/env python3
"""/fr do 고르기. fr_relations.sh candidates 출력을 줄기·순서·보류·제외 줄로 바꿉니다.

사용: python3 -I pick.py --mode interactive|headless [--slugs "<s> <s>"]
        [--max-streams N] [--root <ROOT>] [--active <active.tsv 경로>]
출력: stream/order/hold/skip 줄(탭 구분). rc 0 정상 / 2 실행 불가.
"""
import argparse
import json
import os
import re
import subprocess
import sys

CHAIN_CAP = 3
DEFAULT_MAX_STREAMS = 4
INTERACTIVE_STATUSES = ("idea", "validated", "ready-for-request")
HEADLESS_STATUSES = ("validated", "ready-for-request")
PATH_SHAPE = re.compile(r"^[A-Za-z0-9_./-]+$")
SHARED_FILES = ("rd-workflow/scripts/self_test.sh",)
SHARED_PREFIXES = (".claude/rules/rd-workflow/",)


def die(msg):
    print("pick.py: " + msg, file=sys.stderr)
    sys.exit(2)


def normalize(p):
    if p.startswith("_ROOT_FILES/"):
        p = p[len("_ROOT_FILES/"):]
    return p


def is_path(tok):
    return bool(PATH_SHAPE.match(tok)) and not tok.startswith("-") and tok not in (".", "..")


def is_shared(p):
    return p in SHARED_FILES or p.startswith(SHARED_PREFIXES)


def owned_paths(root, stem):
    """FR 상세의 `- related files:` 줄에서 백틱 안 경로 모양 토큰을 모읍니다."""
    f = os.path.join(root, "rd-workflow-workspace", "backlog", "items", stem + ".md")
    try:
        with open(f, encoding="utf-8") as fh:
            for ln in fh:
                if ln.startswith("- related files:"):
                    toks = re.findall(r"`([^`]*)`", ln)
                    out = []
                    for t in toks:
                        t = t.strip()
                        if is_path(t):
                            t = normalize(t)
                            if not is_shared(t) and t not in out:
                                out.append(t)
                    return out
    except OSError:
        pass
    return []


def p_overlap(p, q):
    if p == q:
        return True
    if p.endswith("/") and q.startswith(p):
        return True
    return q.endswith("/") and p.startswith(q)


def overlap(a, b):
    return any(p_overlap(p, q) for p in a for q in b)


def state_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(["git", "-C", here, "worktree", "list", "--porcelain"],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if r.returncode != 0 or not r.stdout.startswith("worktree "):
        return None
    main = r.stdout.splitlines()[0][len("worktree "):]
    return os.path.join(main, "rd-workflow-workspace", ".lifecycle", "fr-do")


def read_active(path):
    """active.tsv → [(slug, [경로], [FR stem])]. 파일이 없으면 빈 목록.

    줄 형식은 `<slug>\t<경로;…>\t<stem;…>` 입니다. 3번째 칸이 없는 옛 줄은 stem 목록이 비고 경로만 봅니다.
    """
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for ln in fh:
                ln = ln.rstrip("\n")
                if not ln:
                    continue
                cols = ln.split("\t")
                slug = cols[0]
                paths = [normalize(x.strip()) for x in (cols[1] if len(cols) > 1 else "").split(";") if x.strip()]
                stems = [x.strip() for x in (cols[2] if len(cols) > 2 else "").split(";") if x.strip()]
                out.append((slug, paths, stems))
    except OSError:
        pass
    return out


def max_streams_default(root):
    try:
        with open(os.path.join(root, "rd-workflow", "config", "workflow.json"), encoding="utf-8") as fh:
            v = json.load(fh).get("fr_do_max_streams")
        if isinstance(v, int) and not isinstance(v, bool) and v > 0:
            return v
    except (OSError, ValueError, AttributeError):
        pass
    return DEFAULT_MAX_STREAMS


def short(stem):
    return stem[11:]


def main():
    ap = argparse.ArgumentParser(prog="pick.py")
    ap.add_argument("--mode", required=True, choices=("interactive", "headless"))
    ap.add_argument("--slugs", default="")
    ap.add_argument("--max-streams", type=int, default=None)
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("--active", default=None)
    try:
        a = ap.parse_args()
    except SystemExit as e:
        sys.exit(0 if e.code == 0 else 2)
    if a.max_streams is not None and a.max_streams < 1:
        die("--max-streams 는 1 이상이어야 합니다")

    here = os.path.dirname(os.path.abspath(__file__))
    cmd = ["bash", os.path.join(here, "..", "fr_relations.sh"), "candidates", "--root", a.root]
    if a.slugs.strip():
        cmd += ["--slugs", a.slugs]
    r = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        die("candidates 실행 불가 (rc %d)" % r.returncode)
    cands = []
    for ln in r.stdout.splitlines():
        f = ln.split("\t")
        if len(f) == 4:
            cands.append(f)

    interactive = a.mode == "interactive"
    statuses = INTERACTIVE_STATUSES if interactive else HEADLESS_STATUSES
    active = []
    if interactive:
        active_path = a.active
        if active_path is None:
            sd = state_dir()
            if not sd:
                die("상태 폴더를 찾지 못했습니다 — git worktree list 실패. --active 로 지정하십시오")
            active_path = os.path.join(sd, "active.tsv")
        active = read_active(active_path)
    running = {}
    for slug, _paths, stems in active:
        for st_ in stems:
            running.setdefault(st_, slug)

    holds = {}
    order, skips, eligible = [], [], []
    for stem, st, _pri, verdict in cands:
        if stem in running:
            # 이미 실행 중인 줄기가 맡은 FR 은 상태·경로와 상관없이 다시 띄우지 않습니다.
            holds[stem] = "실행 중 줄기 %s 의 FR" % running[stem]
        elif st not in statuses:
            skips.append("skip\t%s\t상태 %s" % (stem, st))
        elif interactive:
            if verdict == "ready":
                eligible.append(stem)
            else:
                skips.append("skip\t%s\t%s" % (stem, verdict))
        elif verdict.startswith("error:"):
            skips.append("skip\t%s\t%s" % (stem, verdict))
        else:
            order.append("order\t%s\t%s" % (stem, verdict))

    if not interactive:
        if order or skips:
            print("\n".join(order + skips))
        return 0

    own = {s: owned_paths(a.root, s) for s in eligible}
    limit = a.max_streams if a.max_streams is not None else max_streams_default(a.root)

    free = []
    for s in eligible:
        hit = next((slug for slug, paths, _ in active if overlap(own[s], paths)), None)
        if hit is not None:
            holds[s] = "실행 중 줄기 %s 와 겹침" % hit
        else:
            free.append(s)

    # 우선순위 순으로 하나씩 겹치는 묶음에 합칩니다. 합친 크기가 상한을 넘는 FR 은 보류하고
    # 묶음 연결에 쓰지 않습니다 — 보류된 FR 이 서로 겹치지 않는 FR 을 한 줄기로 잇지 않게 합니다.
    streams = []
    for s in free:
        hit = [g for g in streams if any(overlap(own[s], own[t]) for t in g)]
        if sum(len(g) for g in hit) + 1 > CHAIN_CAP:
            holds[s] = "겹침 보류 — %s 와 같은 파일, 줄기당 %d건 상한" % (short(hit[0][0]), CHAIN_CAP)
            continue
        if not hit:
            streams.append([s])
            continue
        merged = sorted([t for g in hit for t in g] + [s], key=free.index)
        at = streams.index(hit[0])
        streams = [g for g in streams if g not in hit]
        streams.insert(at, merged)

    room = max(limit - len(set(slug for slug, _, _ in active)), 0)
    final = streams[:room]
    for kept in streams[room:]:
        for s in kept:
            holds[s] = "동시 줄기 상한 %d" % limit

    lines = []
    for n, kept in enumerate(final, 1):
        paths = []
        for s in kept:
            for p in own[s]:
                if p not in paths:
                    paths.append(p)
        lines.append("stream\t%d\t%s\t%s" % (n, ",".join(kept), ";".join(paths)))
    for c in cands:
        if c[0] in holds:
            lines.append("hold\t%s\t%s" % (c[0], holds[c[0]]))
    lines += skips
    if lines:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
