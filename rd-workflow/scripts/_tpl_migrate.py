"""migrate 하위 명령 — 마이그레이션 M000~M018 (spec 4.6).

`migrate pre|post|<Mxxx> [--decide '<제목>=adopt|keep|defer']...`
항목마다 첫 줄 `<Mxxx><TAB><APPLIED|NOOP|ASK|NOTICE|FAIL><TAB><한 줄 요약>`, 그 아래 세부 줄은 두 칸 들여씁니다.
옮긴 항목(M003·M005·M008·M009·M015)의 세부 줄은 MIGRATIONS.md 옛 스니펫의 출력 줄에 두 칸을 더한 것입니다.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from collections import namedtuple

from _tpl_classify import fingerprint, plan_refresh, structure_pending
from _tpl_common import TplError, atomic_write, git_path, out, prev_version, require_clone

Result = namedtuple("Result", "id status summary details")

SETTINGS = ".claude/settings.json"
FR_PATH = "rd-workflow-workspace/backlog/FUTURE_REQUESTS.md"
MARKER_MSG = "스크립트에 없는 항목 — MIGRATIONS.md 를 읽고 처리하십시오"


class Ctx:
    def __init__(self, clone: str, project: str, decisions: dict, prev: str) -> None:
        self.clone = clone
        self.project = project
        self.decisions = decisions
        self.prev = prev

    def p(self, rel: str) -> str:
        return os.path.join(self.project, rel)

    def c(self, rel: str) -> str:
        return os.path.join(self.clone, rel)


def _fail(mid: str, msg: str, extra=()) -> Result:
    return Result(mid, "FAIL", "실패 — 원본을 바꾸지 않았습니다", ["%s 실패: %s" % (mid, msg)] + list(extra))


def _load_json(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _render(cfg) -> bytes:
    return (json.dumps(cfg, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


class _RefreshFailed(Exception):
    """파일은 이미 바뀌었고 계획 파일 갱신만 실패했을 때."""


def _write_tracked(ctx: Ctx, rel: str, data: bytes) -> None:
    """프로젝트 파일을 원자 교체하고, 계획 파일에 있는 경로면 그 줄을 맞춘다 (쓰기 직전 지문 기준)."""
    before = fingerprint(ctx.p(rel))
    atomic_write(ctx.p(rel), data)
    try:
        plan_refresh(ctx.clone, ctx.project, rel, before)
    except OSError as e:
        raise _RefreshFailed("%s 는 바꿨으나 계획 파일 갱신에 실패했습니다 (%s)" % (rel, e))


def _call(mid: str, fn, ctx: Ctx) -> list:
    try:
        return fn(ctx)
    except _RefreshFailed as e:
        return [Result(mid, "FAIL", "파일은 바꿨고 계획 갱신 실패 — classify 부터 다시",
                       ["%s 실패: %s — classify 부터 다시 실행하십시오" % (mid, e)])]
    except OSError as e:
        # 한 항목의 파일 입출력 실패가 뒤 항목의 감지·안내를 지우지 않게 그 항목만 FAIL 로 낸다
        return [Result(mid, "FAIL", "파일 입출력 실패", ["%s 실패: %s — 원인을 고친 뒤 migrate %s 를 다시 실행하십시오" % (mid, e, mid)])]


def _git(project: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", project] + list(args), stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


# ---------------------------------------------------------------- M000~M002

def _m000(ctx: Ctx) -> list:
    return [Result("M000", "NOOP", "문서 규칙으로 충족 (하위 명령은 clone 스크립트로 실행됨)", [])]


def _structure(mid: str, summary: str):
    def run(ctx: Ctx) -> list:
        if mid in structure_pending(ctx.project):
            return [Result(mid, "ASK", summary, ["MIGRATIONS.md %s 를 읽고 처리하십시오 (사용자 파일 경로 치환 판단 필요)" % mid])]
        return [Result(mid, "NOOP", "해당 없음", [])]
    return run


# ---------------------------------------------------------------- M003

def _triples(cfg: dict) -> set:
    res = set()
    for event, gs in (cfg.get("hooks") or {}).items():
        for g in gs:
            for h in g.get("hooks", []):
                if isinstance(h, dict) and isinstance(h.get("command"), str):
                    res.add((event, g.get("matcher", ""), h["command"]))
    return res


def _m003_gitignore(ctx: Ctx):
    """clone .gitignore 의 유효 라인 가운데 프로젝트에 없는 것을 파일 끝에 더한다. (추가한 라인 목록, 실패 Result|None)"""
    tpl_p = ctx.c(".gitignore")
    if not os.path.isfile(tpl_p):
        return [], None
    try:
        with open(tpl_p, "rb") as f:
            tpl_lines = f.read().decode("utf-8", "surrogateescape").split("\n")
        proj_p = ctx.p(".gitignore")
        text = ""
        if os.path.exists(proj_p):
            with open(proj_p, "rb") as f:
                text = f.read().decode("utf-8", "surrogateescape")
    except OSError as e:
        return [], _fail("M003", ".gitignore 를 읽지 못했습니다 (%s)" % e)
    have = set(text.split("\n"))
    added = []
    for line in tpl_lines:
        if not line or line.startswith("#") or line in have:
            continue
        have.add(line)
        added.append(line)
    if not added:
        return [], None
    if text and not text.endswith("\n"):
        text += "\n"  # 마지막 줄 끝 개행이 없으면 추가 라인이 그 줄에 붙지 않게 한다
    text += "".join(l + "\n" for l in added)
    try:
        _write_tracked(ctx, ".gitignore", text.encode("utf-8", "surrogateescape"))
    except OSError as e:
        return [], _fail("M003", ".gitignore 저장 중 오류 — 원본이 유지됩니다 (%s)" % e)
    return added, None


def _m003(ctx: Ctx) -> list:
    details = []
    parts = []
    try:
        tpl = _load_json(ctx.c(SETTINGS))
    except Exception as e:
        return [_fail("M003", "템플릿 settings 를 읽지 못했습니다 (%s)" % e)]
    proj_p = ctx.p(SETTINGS)
    if not os.path.lexists(proj_p):
        try:
            with open(ctx.c(SETTINGS), "rb") as f:
                data = f.read()
            os.makedirs(os.path.dirname(proj_p), exist_ok=True)
            _write_tracked(ctx, SETTINGS, data)
        except OSError as e:
            return [_fail("M003", "settings 복사 중 오류 (%s)" % e)]
        details.append("M003: settings.json 없음 — 템플릿 판을 복사했습니다")
        parts.append("settings.json 복사")
    else:
        try:
            proj = _load_json(proj_p)
        except Exception as e:
            return [_fail("M003", "프로젝트 settings 를 읽지 못했습니다 (%s)" % e)]
        if not isinstance(proj, dict):
            return [_fail("M003", "settings 최상위가 객체가 아닙니다")]
        hooks = proj.get("hooks", {}) if "hooks" in proj else {}
        if not isinstance(hooks, dict):
            return [_fail("M003", "hooks 가 객체가 아닙니다")]
        for event, gs in hooks.items():
            if not isinstance(gs, list) or any(not isinstance(g, dict) or not isinstance(g.get("hooks", []), list) for g in gs):
                return [_fail("M003", "hooks.%s 의 형식이 올바르지 않습니다" % event)]
        try:
            have = _triples(proj)
            added = []
            for event, gs in (tpl.get("hooks") or {}).items():
                for g in gs:
                    matcher = g.get("matcher", "")
                    for h in g.get("hooks", []):
                        if not (isinstance(h, dict) and isinstance(h.get("command"), str)):
                            continue
                        key = (event, matcher, h["command"])
                        if key in have:
                            continue
                        pgs = hooks.setdefault(event, [])
                        tgt = next((pg for pg in pgs if pg.get("matcher", "") == matcher), None)
                        if tgt is None:
                            tgt = {k: v for k, v in g.items() if k != "hooks"}
                            tgt["hooks"] = []
                            pgs.append(tgt)
                        tgt.setdefault("hooks", []).append(dict(h))
                        have.add(key)
                        added.append(key)
        except (AttributeError, TypeError):
            return [_fail("M003", "템플릿 hooks 의 형식이 올바르지 않습니다")]
        if added:
            proj["hooks"] = hooks
            try:
                _write_tracked(ctx, SETTINGS, _render(proj))
            except OSError as e:
                return [_fail("M003", "저장 중 오류 — 원본이 유지됩니다 (%s)" % e)]
            details.append("M003: added %d" % len(added))
            for event, matcher, cmd in added:
                details.append("  + %s / %s / %s" % (event, matcher or "(matcher 없음)", cmd))
            parts.append("hooks %d건 추가" % len(added))
    gi_added, gi_fail = _m003_gitignore(ctx)
    if gi_fail is not None:
        if parts:  # settings 는 이미 바뀐 상태 — 세부 줄과 실제 상태를 함께 보고한다
            return [Result("M003", "FAIL", "%s 적용 후 .gitignore 실패 (.gitignore 는 바꾸지 않았습니다)" % ", ".join(parts),
                           details + gi_fail.details)]
        return [gi_fail]
    if gi_added:
        details.append(".gitignore: added %d" % len(gi_added))
        for line in gi_added:
            details.append("  + " + line)
        parts.append(".gitignore %d줄 추가" % len(gi_added))
    if not parts:
        return [Result("M003", "NOOP", "해당 없음", ["M003: 해당 없음"])]
    return [Result("M003", "APPLIED", ", ".join(parts), details)]


# ---------------------------------------------------------------- M005

def _m005(ctx: Ctx) -> list:
    proj_p = ctx.p(SETTINGS)
    if not os.path.exists(proj_p):
        return [Result("M005", "NOOP", "해당 없음 (.claude/settings.json 없음)", ["removed: 없음"])]
    try:
        proj = _load_json(proj_p)
    except Exception as e:
        return [_fail("M005", "프로젝트 settings 를 읽지 못했습니다 (%s)" % e)]
    tpl = {}
    if os.path.exists(ctx.c(SETTINGS)):
        try:
            tpl = _load_json(ctx.c(SETTINGS))
        except Exception as e:
            return [_fail("M005", "템플릿 settings 를 읽지 못했습니다 (%s)" % e)]
    try:
        tpl_entries = set()
        for event, groups in (tpl.get("hooks") or {}).items():
            for g in groups:
                for h in g.get("hooks", []):
                    tpl_entries.add((event, g.get("matcher", ""), h.get("command", "")))
        removed = []
        hooks = proj.get("hooks") or {}
        for event in list(hooks.keys()):
            for g in hooks[event]:
                kept = []
                for h in g.get("hooks", []):
                    cmd = h.get("command", "")
                    m = re.search(r'rd-workflow/scripts/hooks/[^\s"\']+', cmd)
                    is_stale = (
                        m is not None
                        and not os.path.exists(os.path.join(ctx.clone, m.group(0)))
                        and (event, g.get("matcher", ""), cmd) not in tpl_entries
                    )
                    if is_stale:
                        removed.append((event, g.get("matcher", ""), cmd))
                    else:
                        kept.append(h)
                g["hooks"] = kept
            hooks[event] = [g for g in hooks[event] if g.get("hooks")]
            if not hooks[event]:
                del hooks[event]
    except (AttributeError, TypeError):
        return [_fail("M005", "settings 의 hooks 형식이 올바르지 않습니다")]
    if not removed:
        return [Result("M005", "NOOP", "제거할 stale hook 없음", ["removed: 없음"])]
    try:
        _write_tracked(ctx, SETTINGS, _render(proj))
    except OSError as e:
        return [_fail("M005", "저장 중 오류 — 원본이 유지됩니다 (%s)" % e)]
    details = ["removed: %s / %s / %s" % (event, matcher or "(matcher 없음)", cmd) for event, matcher, cmd in removed]
    return [Result("M005", "APPLIED", "stale hook %d건 제거" % len(removed), details)]


# ---------------------------------------------------------------- M008

OLD_PREFIX = "bash rd-workflow/scripts/hooks/"
NEW_PREFIX = 'bash "${CLAUDE_PROJECT_DIR:-.}"/rd-workflow/scripts/hooks/'


def _m008(ctx: Ctx) -> list:
    proj_p = ctx.p(SETTINGS)
    if not os.path.exists(proj_p):
        return [Result("M008", "NOOP", "해당 없음 (.claude/settings.json 없음)", ["M008: .claude/settings.json 없음 — 해당 없음"])]

    def fail(msg: str) -> list:
        return [_fail("M008", msg)]

    try:
        with open(proj_p, "rb") as f:
            original = f.read()
    except OSError as e:
        return fail("읽기 오류 — 원본을 바꾸지 않았습니다: %s" % e)
    try:
        cfg = json.loads(original.decode("utf-8"))
    except Exception as e:
        return fail("JSON parse 오류 — 원본을 바꾸지 않았습니다: %s" % e)
    if not isinstance(cfg, dict):
        return fail("최상위가 객체가 아닙니다 — 원본을 바꾸지 않았습니다")
    hooks = cfg.get("hooks")
    if hooks is None:
        return [Result("M008", "NOOP", "hooks 키 없음", ["M008: hooks 키 없음 — 무변경"])]
    if not isinstance(hooks, dict):
        return fail("hooks 가 객체가 아닙니다 — 원본을 바꾸지 않았습니다")
    for ev, groups in hooks.items():
        if not isinstance(groups, list):
            return fail("hooks[%s] 가 배열이 아닙니다 — 원본을 바꾸지 않았습니다" % ev)
        for g in groups:
            if not isinstance(g, dict) or not isinstance(g.get("hooks", []), list):
                return fail("hooks[%s] 의 group 구조가 예상과 다릅니다 — 원본을 바꾸지 않았습니다" % ev)
            for it in g.get("hooks", []):
                if not isinstance(it, dict):
                    return fail("hooks[%s] 의 item 이 객체가 아닙니다 — 원본을 바꾸지 않았습니다" % ev)

    normalized = folded = 0
    seen_across: dict = {}
    for ev, groups in hooks.items():
        for g in groups:
            kept, seen = [], set()
            for it in g.get("hooks", []):
                cmd = it.get("command")
                if isinstance(cmd, str) and cmd.startswith(OLD_PREFIX):
                    it["command"] = NEW_PREFIX + cmd[len(OLD_PREFIX):]
                    normalized += 1
                    cmd = it["command"]
                # command 가 문자열이 아닌 item 은 중복 판정 대상이 아니다 — 내용·순서를 그대로 보존한다.
                if not isinstance(cmd, str):
                    kept.append(it)
                    continue
                key = json.dumps(cmd, ensure_ascii=False)
                if key in seen:  # first-wins: 처음 항목 전체를 남기고 나머지를 버린다
                    folded += 1
                    continue
                seen.add(key)
                # 알림 키에 matcher 를 포함한다 — matcher 가 다른 group 의 같은 command 는 정상 구성이다.
                mk = (ev, json.dumps(g.get("matcher"), ensure_ascii=False), key)
                seen_across[mk] = seen_across.get(mk, 0) + 1
                kept.append(it)
            if "hooks" in g:
                g["hooks"] = kept

    details = []
    for (ev, matcher, key), n in seen_across.items():
        if n > 1:
            details.append("M008 알림: event %s / matcher %s 에서 같은 command 가 %d 개 group 에 걸쳐 있습니다 (group 경계는 합치지 않습니다): %s" % (ev, matcher, n, key))
    if normalized == 0 and folded == 0:
        details.append("M008: 변경 없음 (이미 정규화됨) — 파일을 재작성하지 않았습니다")
        return [Result("M008", "NOOP", "변경 없음 (이미 정규화됨)", details)]
    try:
        _write_tracked(ctx, SETTINGS, _render(cfg))
    except OSError as e:
        return fail("교체 중 오류 — 원본이 유지됩니다: %s" % e)
    msg = "표기 정규화 %d건, 중복 접기 %d건" % (normalized, folded)
    details.append("M008: " + msg)
    return [Result("M008", "APPLIED", msg, details)]


# ---------------------------------------------------------------- M009

STATUS_ITEM = (
    "- `blocked`: 무인 드레인(ralph)이 중단조건에 걸려 set-aside 한 항목. 활성 인덱스에 "
    "잔류하되 auto-pick·`/fr pri`·`/fr push` 대상에서 제외되고 `/fr list` 에는 set-aside "
    "요약(건수)으로만 표기. 원인 해소 후 `validated` 로 복원해 재시도"
)
SPLIT_ITEM = (
    "- **`blocked` 항목**: 활성 인덱스에 **잔류**합니다 (parked 처럼 별도 파일로 옮기지 "
    "않습니다). auto-pick·`/fr pri`·`/fr push` 대상에서 제외되고 `/fr list` 에는 "
    "set-aside 요약으로만 표기됩니다."
)
MARKERS = {"상태 값": "- `blocked`:", "파일 분리": "- **`blocked` 항목**:"}


def _m009(ctx: Ctx) -> list:
    path = ctx.p(FR_PATH)
    if not os.path.exists(path):
        return [Result("M009", "NOOP", "해당 없음 (FUTURE_REQUESTS.md 없음)", ["M009: %s 없음 — 해당 없음" % FR_PATH])]
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except (OSError, UnicodeDecodeError) as e:
        return [_fail("M009", "읽기 오류 — 원본을 바꾸지 않았습니다: %s" % e)]

    targets = {}
    for name in ("상태 값", "파일 분리"):
        hits = [i for i, l in enumerate(lines) if l.strip() == "## " + name]
        if len(hits) != 1:
            return [_fail(
                "M009",
                "'## %s' 헤딩이 %d개입니다 (정확히 1개여야 합니다) — 원본을 바꾸지 않았습니다." % (name, len(hits)),
                ["  조치: %s 에서 그 헤딩을 하나만 남기거나, 배포본의 해당 섹션 문구를 직접 옮겨 적으십시오." % FR_PATH],
            )]
        targets[name] = hits[0]

    def section_end(start: int) -> int:
        for i in range(start + 1, len(lines)):
            if lines[i].startswith("## "):
                return i
        return len(lines)

    pending = []
    for name, item in (("상태 값", STATUS_ITEM), ("파일 분리", SPLIT_ITEM)):
        start = targets[name]
        body = lines[start + 1:section_end(start)]
        if any(l.startswith(MARKERS[name]) for l in body):
            continue
        offset = None
        if name == "상태 값":
            for j, l in enumerate(body):
                if l.startswith("- `done`"):
                    offset = j
                    break
        if offset is None:
            for j, l in enumerate(body):
                if l.startswith("- "):
                    offset = j
                    break
        if offset is None:
            return [_fail(
                "M009",
                "'## %s' 섹션에 목록 항목이 없습니다 — 원본을 바꾸지 않았습니다." % name,
                ["  조치: 배포본의 해당 섹션 문구를 직접 옮겨 적으십시오."],
            )]
        pending.append((start + 1 + offset, item))

    if not pending:
        return [Result("M009", "NOOP", "두 섹션에 이미 blocked 서술이 있습니다",
                       ["M009: 두 섹션에 이미 blocked 서술이 있습니다 — 해당 없음"])]

    for idx, text in sorted(pending, reverse=True):
        lines.insert(idx, text)
    try:
        _write_tracked(ctx, FR_PATH, "\n".join(lines).encode("utf-8"))
    except OSError as e:
        return [_fail("M009", "쓰기 오류 — 원본을 바꾸지 않았습니다: %s" % e)]
    msg = "%d개 섹션에 blocked 서술을 삽입했습니다." % len(pending)
    return [Result("M009", "APPLIED", msg, ["M009: " + msg])]


# ---------------------------------------------------------------- M015

def _m015(ctx: Ctx) -> list:
    try:
        tpl = _load_json(ctx.c(SETTINGS))
        tpl_allow = tpl["permissions"]["allow"]
        if not isinstance(tpl_allow, list):
            raise TypeError("템플릿 permissions.allow 가 list 가 아닙니다")
    except Exception as e:
        return [_fail("M015", "템플릿 settings 를 읽지 못했습니다 (%s)" % e)]
    proj_p = ctx.p(SETTINGS)
    try:
        proj = _load_json(proj_p)
    except FileNotFoundError:
        return [Result("M015", "NOOP", "해당 없음 (.claude/settings.json 없음)", ["M015: 해당 없음 (.claude/settings.json 없음)"])]
    except Exception as e:
        return [_fail("M015", "프로젝트 settings 를 읽지 못했습니다 (%s)" % e)]
    if not isinstance(proj, dict):
        return [_fail("M015", "settings 최상위가 객체가 아닙니다")]
    perms = proj.get("permissions", {}) if "permissions" in proj else {}
    if not isinstance(perms, dict):
        return [_fail("M015", "permissions 가 객체가 아닙니다")]
    allow = perms.get("allow", []) if "allow" in perms else []
    if not isinstance(allow, list):
        return [_fail("M015", "permissions.allow 가 list 가 아닙니다")]
    added = [r for r in tpl_allow if r not in allow]
    if not added:
        return [Result("M015", "NOOP", "해당 없음", ["M015: 해당 없음"])]
    perms["allow"] = allow + added
    proj["permissions"] = perms
    try:
        _write_tracked(ctx, SETTINGS, _render(proj))
    except OSError as e:
        return [_fail("M015", "저장 중 오류 — 원본이 유지됩니다 (%s)" % e)]
    details = ["M015: added %d" % len(added)] + ["  + " + r for r in added]
    return [Result("M015", "APPLIED", "permissions.allow %d건 추가" % len(added), details)]


# ---------------------------------------------------------------- 감지 항목 (post)

def _m004(ctx: Ctx) -> list:
    rd = ctx.p("rd-workflow/scripts/rd")
    state = ctx.p("rd-workflow-workspace/.lifecycle/task-state")
    if not os.path.isfile(rd):
        return [Result("M004", "NOOP", "해당 없음 (rd 없음)", [])]
    if os.path.exists(state):
        return [Result("M004", "NOOP", "task-state 가 이미 있습니다", [])]
    try:
        r = subprocess.run(["bash", rd, "task", "status"], cwd=ctx.project, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return [Result("M004", "FAIL", "rd task status 를 실행하지 못했습니다", ["%s" % e])]
    if r.returncode == 3:
        return [Result("M004", "ASK", "CURRENT_TASK.md 의 Status 를 수동으로 복구하십시오", [
            "복구 절차: rd-workflow/docs/guides/task-state-guide.md 의 「실패 시 복구」",
            "복구 뒤 rd task status 를 다시 실행하십시오",
        ])]
    if r.returncode != 0:
        tail = os.fsdecode(r.stderr).strip().splitlines()[-1:] or ["(출력 없음)"]
        return [Result("M004", "FAIL", "rd task status 가 exit %d 로 끝났습니다" % r.returncode, tail)]
    if os.path.exists(state):
        return [Result("M004", "APPLIED", "task-state 를 만들었습니다",
                       ["tracked 변경(active-fr 삭제·task-state 생성)을 다음 정규 커밋에 포함하십시오"])]
    return [Result("M004", "NOOP", "변경 없음", [])]


def _m011_detect(ctx: Ctx) -> list:
    r = _git(ctx.project, "check-ignore", "-q", "rd-workflow-workspace/.lifecycle/review-seals/x.seal")
    if r.returncode == 0:
        return [Result("M011", "ASK", ".gitignore 가 review-seals/ 를 가립니다", [
            ".gitignore 에서 review-seals/ 를 가리는 규칙을 고치십시오 (사용자 파일 편집)",
            "확인: git check-ignore -v rd-workflow-workspace/.lifecycle/review-seals/x.seal",
        ])]
    return [Result("M011", "NOOP", "seal 이 무시되지 않습니다", [])]


def _m014(ctx: Ctx) -> list:
    r = _git(ctx.project, "ls-files")
    tracked = [l for l in os.fsdecode(r.stdout).split("\n") if ".turn_ready" in l] if r.returncode == 0 else []
    if not tracked:
        return [Result("M014", "NOOP", "추적 중인 .turn_ready 없음", [])]
    return [Result("M014", "ASK", "추적 중인 .turn_ready 마커 %d건 — 추적 해제는 사용자가 합니다" % len(tracked), [
        "git ls-files 'rd-workflow-workspace/handoffs/review_pipeline/*/.turn_ready' | xargs git rm --cached",
        'git commit -m "chore: 추적 중인 .turn_ready 마커 추적 해제"',
    ])]


def _m017_detect(ctx: Ctx) -> list:
    if os.path.exists(ctx.p("rd-workflow-workspace/.batch-manifest.json")):
        return [Result("M017", "ASK", "남은 batch manifest 항목을 /fr do 로 이어 처리하십시오", [
            "rd-workflow-workspace/.batch-manifest.json 에서 state 가 completed 가 아니고 feasibility 가 excluded 가 아닌 항목이 대상입니다",
            "확인이 끝나면 manifest 파일을 직접 지웁니다",
        ])]
    return [Result("M017", "NOOP", "batch manifest 없음", [])]


def _m013(ctx: Ctx) -> list:
    # 조건: clone 에 .claude/rules/rd-workflow/ 가 있고 프로젝트에 CLAUDE.md 가 있을 때. 아니면 NOOP.
    if not (os.path.isdir(ctx.c(".claude/rules/rd-workflow")) and os.path.isfile(ctx.p("CLAUDE.md"))):
        return [Result("M013", "NOOP", "해당 없음", [])]
    try:
        import _tpl_m013  # Task 4 모듈 — 조건이 맞을 때만 지연 import
    except ImportError as e:
        return [Result("M013", "FAIL", "M013 모듈을 불러오지 못했습니다", [str(e)])]
    status, details = _tpl_m013.run(ctx.clone, ctx.project, ctx.decisions)
    summary = {"APPLIED": "CLAUDE.md 절 정리", "NOOP": "해당 없음", "ASK": "사용자 선택이 필요한 절이 있습니다",
               "NOTICE": "안내", "FAIL": "실패"}.get(status, status)
    return [Result("M013", status, summary, list(details))]


# ---------------------------------------------------------------- 안내 (NOTICE)

def _notice(mid: str, since: str, summary: str):
    def run(ctx: Ctx) -> list:
        if not ctx.prev_date or ctx.prev_date <= since:
            return [Result(mid, "NOTICE", summary, [])]
        return []
    return run


def _combine(*fns):
    def run(ctx: Ctx) -> list:
        res = []
        for fn in fns:
            res += fn(ctx)
        return res
    return run


def _entry(kind: str, phase: str, since, detect=None, notice=None) -> dict:
    fns = [f for f in (detect, notice) if f is not None]
    return {"kind": kind, "phase": phase, "since": since, "run": _combine(*fns),
            "detect": detect, "notice": notice}


_N006 = _notice("M006", "2026-08-03", "source-fr 계약 구현 — MIGRATIONS.md M006 안내를 읽으십시오")
_N007 = _notice("M007", "2026-08-20", "게이트 정리 — MIGRATIONS.md M007 안내를 읽으십시오")
_N010 = _notice("M010", "2026-09-04", "위험 등급 도입 — MIGRATIONS.md M010 안내를 읽으십시오 (CLAUDE.md 정리는 M013 이 대신함)")
_N011 = _notice("M011", "2026-09-06", "종결 마커(seal)·아카이브 보류 상태 — MIGRATIONS.md M011 안내를 읽으십시오")
_N012 = _notice("M012", "2026-09-06", "기본 실행 모드 semi-auto 전환 — MIGRATIONS.md M012 안내를 읽으십시오")
_N016 = _notice("M016", "2026-11-07", "자기 worktree 삭제 가드 — MIGRATIONS.md M016 안내를 읽으십시오 (등록은 M005·M003 이 처리)")
_N017 = _notice("M017", "2026-11-08", "/fr batch 별칭화 — MIGRATIONS.md M017 안내를 읽으십시오")
_N018 = _notice("M018", "2026-11-16", "마감 때 팀 저장소 PR 단계·기본 반영 방식 pr — MIGRATIONS.md M018 안내를 읽으십시오 (설정 파일은 자동으로 쓰지 않음)")

REGISTRY: dict = {
    "M000": _entry("procedure", "pre", None, detect=_m000),
    "M001": _entry("ask", "pre", None, detect=_structure("M001", "ai/ 를 rd-workflow/ 로 옮겨야 합니다")),
    "M002": _entry("ask", "pre", None, detect=_structure("M002", "rd-workflow/workspace/ 를 rd-workflow-workspace/ 로 옮겨야 합니다")),
    "M003": _entry("auto", "pre", None, detect=_m003),
    "M004": _entry("auto", "post", None, detect=_m004),
    "M005": _entry("auto", "pre", None, detect=_m005),
    "M006": _entry("notice", "post", "2026-08-03", notice=_N006),
    "M007": _entry("notice", "post", "2026-08-20", notice=_N007),
    "M008": _entry("auto", "pre", None, detect=_m008),
    "M009": _entry("auto", "pre", None, detect=_m009),
    "M010": _entry("notice", "post", "2026-09-04", notice=_N010),
    "M011": _entry("mixed", "post", "2026-09-06", detect=_m011_detect, notice=_N011),
    "M012": _entry("notice", "post", "2026-09-06", notice=_N012),
    "M013": _entry("mixed", "post", None, detect=_m013),
    "M014": _entry("ask", "post", None, detect=_m014),
    "M015": _entry("auto", "pre", None, detect=_m015),
    "M016": _entry("notice", "post", "2026-11-07", notice=_N016),
    "M017": _entry("mixed", "post", "2026-11-08", detect=_m017_detect, notice=_N017),
    "M018": _entry("notice", "post", "2026-11-16", notice=_N018),
}

PRE_ORDER = ["M000", "M001", "M002", "M005", "M008", "M003", "M015", "M009"]
POST_DETECT = ["M004", "M013", "M011", "M014", "M017"]
POST_NOTICE = ["M006", "M007", "M010", "M011", "M012", "M016", "M017", "M018"]


# ---------------------------------------------------------------- 실행

def _emit(results: list) -> bool:
    """결과를 출력하고 FAIL 이 있었는지 돌려준다."""
    failed = False
    for r in results:
        out(r.id, r.status, r.summary)
        for d in r.details:
            out("  " + d)
        failed = failed or r.status == "FAIL"
    return failed


def _prev_date(project: str) -> str:
    m = re.search(r"\d{4}-\d{2}-\d{2}", prev_version(project))
    return m.group(0) if m else ""


def _unregistered(clone: str) -> list:
    path = os.path.join(clone, "rd-workflow/MIGRATIONS.md")
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8", "surrogateescape")
    except OSError:
        return []
    found = []
    for m in re.finditer(r"^## M(\d+):", text, re.M):
        mid = "M%03d" % int(m.group(1))
        if mid not in REGISTRY and mid not in found:
            found.append(mid)
    return [Result(mid, "ASK", MARKER_MSG, []) for mid in found]


def _run_pre(ctx: Ctx) -> int:
    failed = False
    for mid in PRE_ORDER:
        res = _call(mid, REGISTRY[mid]["detect"], ctx)
        failed = _emit(res) or failed
        if mid in ("M001", "M002") and any(r.status == "ASK" for r in res):
            return 3  # 구조 마이그레이션 대기 — 나머지를 실행하지 않는다
    return 1 if failed else 0


def _run_post(ctx: Ctx) -> int:
    failed = False
    for mid in POST_DETECT:
        failed = _emit(_call(mid, REGISTRY[mid]["detect"], ctx)) or failed
    for mid in POST_NOTICE:
        failed = _emit(REGISTRY[mid]["notice"](ctx)) or failed
    if not ctx.prev_date:
        out("NOTICE", "-", "이전 VERSION 을 몰라 안내를 모두 보였습니다")
    failed = _emit(_unregistered(ctx.clone)) or failed
    return 1 if failed else 0


def _parse(argv: list) -> tuple:
    target = None
    decisions: dict = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--decide":
            if i + 1 >= len(argv):
                raise TplError(2, "사용법: --decide '<제목>=adopt|keep|defer'")
            spec = argv[i + 1]
            title, sep, val = spec.rpartition("=")
            if not sep or not title or val not in ("adopt", "keep", "defer"):
                raise TplError(2, "사용법: --decide '<제목>=adopt|keep|defer' (받은 값: %s)" % spec)
            decisions[title] = val
            i += 2
        elif target is None and not a.startswith("-"):
            target = a
            i += 1
        else:
            raise TplError(2, "사용법: migrate pre|post|<Mxxx> [--decide '<제목>=adopt|keep|defer']...")
    if target is None:
        raise TplError(2, "사용법: migrate pre|post|<Mxxx> [--decide '<제목>=adopt|keep|defer']...")
    if decisions and target != "M013":
        raise TplError(2, "오류: --decide 는 migrate M013 에만 쓸 수 있습니다")
    return target, decisions


def main(sub: str, clone: str, project: str, argv: list) -> int:
    require_clone(clone, project)
    git_path(project, "rd-tpl-prev-version")  # git 저장소가 아니면 exit 2
    target, decisions = _parse(argv)
    if target not in ("pre", "post") and target not in REGISTRY:
        raise TplError(2, "오류: 알 수 없는 마이그레이션입니다: %s" % target)
    prev = _prev_date(project)
    ctx = Ctx(clone, project, decisions, prev_version(project))
    ctx.prev_date = prev
    if target == "pre":
        return _run_pre(ctx)
    if target == "post":
        return _run_post(ctx)
    return 1 if _emit(_call(target, REGISTRY[target]["run"], ctx)) else 0
