"""sync_template reinstall — 7단계 skill 재설치, 8단계 extension 자동 재설치·preset 머지·매니페스트 저장.

프로젝트 파일만 읽는다(clone 의 스크립트로 실행해도, 프로젝트의 스크립트로 실행해도 같다).
묻지 못하는 항목은 줄(ask-*)로 내고, 답은 다음 실행의 인자로 받는다.
"""
from __future__ import annotations

import datetime
import json
import os
import re
import shutil
import subprocess

from _tpl_common import TplError, atomic_write, out

PRESETS = ("react-web", "api", "cli", "ios", "macos")
MANIFEST = "rd-workflow/config/extensions.json"
VERIFICATION = "rd-workflow/config/verification.json"
JUDGE = ("verify", "design-review")  # 이름이 고정된 파일시스템 판정 대상


def _csv(value: str) -> list[str]:
    return [x for x in value.split(",") if x]


def _parse(argv: list[str]) -> dict:
    opts = {"declined": [], "failed": [], "verifier-add": [], "verifier-skip": [], "preset": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        key = a[2:] if a.startswith("--") else ""
        if key not in opts or i + 1 >= len(argv):
            raise TplError(2, "사용법: reinstall [--declined a,b] [--failed a] [--verifier-add x,y] [--verifier-skip x,y] [--preset <값>]")
        opts[key] = argv[i + 1] if key == "preset" else _csv(argv[i + 1])
        i += 2
    return opts


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _dump(obj: object) -> bytes:
    return (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def _load_json(path: str):
    """파일이 없거나 JSON 이 아니면 None."""
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def _str_list(v: object):
    """문자열 배열이면 그 list, 아니면 None(없음·형식 오류)."""
    if isinstance(v, list) and all(isinstance(x, str) for x in v):
        return v
    return None


def _description(project: str, name: str) -> str:
    try:
        with open(os.path.join(project, "rd-workflow/extensions", name, "SKILL.md"), encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return ""
    if not lines or lines[0].strip() != "---":
        return ""
    for ln in lines[1:]:
        if ln.strip() == "---":
            break
        m = re.match(r"description:\s*(.*)$", ln)
        if m:
            v = m.group(1).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            return v
    return ""


# ---------------------------------------------------------------- 7단계
def _install_skills(project: str) -> list[list[str]]:
    script = os.path.join(project, "rd-workflow/scripts/install_claude_skills.sh")
    if not os.path.isfile(script):
        raise TplError(1, "FAIL\tskills\tinstall_claude_skills.sh 가 없습니다")
    r = subprocess.run(
        ["bash", script, "project"], cwd=project,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    text = os.fsdecode(r.stdout)
    err = os.fsdecode(r.stderr)
    if r.returncode != 0:
        tail = (err.strip().splitlines() or text.strip().splitlines() or [""])[-1]
        raise TplError(1, "FAIL\tskills\tinstall_claude_skills.sh 실패 (exit %d): %s" % (r.returncode, tail))
    counts = {}
    for ln in text.splitlines():
        m = re.match(r"(installed|refreshed|skipped): (\d+)$", ln)
        if m:
            counts[m.group(1)] = m.group(2)
    rows: list[list[str]] = []
    if len(counts) == 3:
        rows.append(["skills"] + ["%s=%s" % (k, counts[k]) for k in ("installed", "refreshed", "skipped")])
    else:
        rows.append(["skills", (text.strip().splitlines() or [""])[-1]])
    for ln in text.splitlines():
        if ln.startswith("refreshed") and not re.match(r"refreshed: \d+$", ln):
            rows.append(["note", "skill 갱신: " + ln])
    if "settings.json conflict" in err:
        rows.append(["note", "settings.json 충돌 — 수동 머지가 필요합니다"])
    return rows


# ---------------------------------------------------------------- 8.6 머지
def _merge(project: str, preset: str, seen: object, opts: dict):
    """(summary 줄 | None, 노트 목록, 새 seen_verifiers | None(만들지·고치지 않음), 질문 이름 목록)."""
    tpl = _load_json(os.path.join(project, "rd-workflow/extensions/verify/presets", preset, "verification.json"))
    vpath = os.path.join(project, VERIFICATION)
    proj = _load_json(vpath)
    notes: list[str] = []
    if not isinstance(tpl, dict) or not isinstance(tpl.get("verifiers"), dict):
        return None, ["preset 머지 건너뜀: template preset 파일을 읽을 수 없습니다 (%s)" % preset], None, []
    if not isinstance(proj, dict) or not isinstance(proj.get("verifiers"), dict):
        return None, ["preset 머지 건너뜀: %s 를 읽을 수 없습니다" % VERIFICATION], None, []
    tv, pv = tpl["verifiers"], proj["verifiers"]
    before = json.dumps(proj, sort_keys=True)
    s_valid = _str_list(seen)
    added, kept, updated, req, c_add, c_del, deleted, asked = [], [], [], [], [], [], [], []
    for name, t in tv.items():
        if not isinstance(t, dict):
            continue
        if name in pv and isinstance(pv[name], dict):
            p = pv[name]
            changed = False
            for k in ("run", "adapter"):
                if k in t and p.get(k) != t[k]:
                    p[k] = t[k]
                    changed = True
            if changed:
                updated.append(name)
            if isinstance(t.get("criteria"), list):
                tnames = [c.get("name") for c in t["criteria"] if isinstance(c, dict)]
                pcrit = p.get("criteria") if isinstance(p.get("criteria"), list) else []
                keep_c = [c for c in pcrit if isinstance(c, dict) and c.get("name") in tnames]
                have = [c.get("name") for c in keep_c]
                for c in pcrit:
                    if not (isinstance(c, dict) and c.get("name") in tnames):
                        c_del.append("%s:%s" % (name, c.get("name") if isinstance(c, dict) else "?"))
                for c in t["criteria"]:
                    if isinstance(c, dict) and c.get("name") not in have:
                        keep_c.append(c)
                        c_add.append("%s:%s" % (name, c.get("name")))
                p["criteria"] = keep_c
            if "requires_env" in t and "requires_env" not in p:
                p["requires_env"] = t["requires_env"]
                req.append(name)
        elif name in pv:
            kept.append(name)  # 형식이 다른 프로젝트 항목은 건드리지 않는다
        else:
            if s_valid is not None:
                if name in s_valid:
                    deleted.append(name)
                else:
                    pv[name] = t
                    added.append(name)
            elif name in opts["verifier-add"]:
                pv[name] = t
                added.append(name)
            elif name in opts["verifier-skip"]:
                pass
            else:
                asked.append(name)
    kept = [n for n in pv if n not in tv] + kept
    if json.dumps(proj, sort_keys=True) != before:
        try:
            atomic_write(vpath, _dump(proj))
        except OSError as e:
            raise TplError(1, "FAIL\t%s\tverification.json 쓰기 실패: %s" % (VERIFICATION, e))
    new_seen = None
    if not asked:
        new_seen = sorted(set(s_valid or []) | set(tv))
        if seen is None:
            notes.append("seen_verifiers 새로 기록")
        elif s_valid is None:
            notes.append("seen_verifiers 형식 오류 — 다시 만듦")
    elif seen is not None and s_valid is None:
        notes.append("seen_verifiers 형식 오류 — 초기화 보류, 다음 대화형 /tpl update 에서 확인")

    def j(v: list[str]) -> str:
        return ",".join(v) if v else "-"

    summary = ["merge", "added=" + j(added), "kept=" + j(kept), "updated=" + j(updated), "requires_env=" + j(req),
               "criteria+=" + j(c_add), "criteria-=" + j(c_del), "deleted=" + j(deleted)]
    return summary, notes, new_seen, asked


# ---------------------------------------------------------------- main
def main(sub: str, clone: str, project: str, argv: list) -> int:
    opts = _parse(argv)
    if opts["preset"] is not None and opts["preset"] not in PRESETS:
        raise TplError(2, "오류: 허용되지 않는 preset: %s (허용: %s)" % (opts["preset"], ", ".join(PRESETS)))
    rows = _install_skills(project)  # 실패하면 TplError(1) — 진입 모듈이 stderr·exit 1 로 바꾼다
    notes: list[list[str]] = []
    added_rows: list[list[str]] = []
    removed_rows: list[list[str]] = []
    ask_rows: list[list[str]] = []

    mpath = os.path.join(project, MANIFEST)
    manifest = _load_json(mpath)
    if not isinstance(manifest, dict):
        manifest = None
    if manifest is not None and not isinstance(manifest.get("extensions"), dict):
        manifest["extensions"] = {}
    seen_ext_raw = manifest.get("seen_extensions") if manifest is not None else None
    E = _str_list(seen_ext_raw) if manifest is not None else None
    forced_new: list[str] = []

    # 8.1.1 legacy presets
    if manifest is not None and "presets" in manifest["extensions"]:
        legacy = manifest["extensions"].pop("presets")
        value = legacy.get("preset") if isinstance(legacy, dict) else None
        exts = manifest["extensions"]
        if value:
            if isinstance(exts.get("verify"), dict):  # Case A
                exts["verify"]["preset"] = value
                notes.append(["note", "legacy presets.preset 를 verify.preset 으로 옮김"])
            elif os.path.isfile(os.path.join(project, "rd-workflow/claude_skills/verify/SKILL.md")):  # Case B, 설치됨
                exts["verify"] = {"installed_at": _now(), "preset": value}
                notes.append(["note", "legacy presets.preset 로 verify 항목을 만들고 preset 을 옮김"])
            else:  # Case B, 미설치
                forced_new.append("verify")
                ask_rows.append(["ask-preset", str(value)])
                notes.append(["note", "legacy presets 삭제, verify 미설치 — verify 와 preset 설치를 묻습니다"])
        else:  # Case C
            notes.append(["note", "legacy presets 키 삭제"])
    # 파일시스템 잔재
    old_presets = os.path.join(project, "rd-workflow/extensions/presets")
    if os.path.isdir(old_presets):
        try:
            shutil.rmtree(old_presets)
        except OSError as e:
            raise TplError(1, "FAIL\tpresets\t구 폴더 삭제 실패: %s" % e)
        notes.append(["note", "presets → verify/presets 통합으로 구 폴더 삭제됨"])

    # 8.2 스캔
    ext_dir = os.path.join(project, "rd-workflow/extensions")
    fs_available = sorted(d for d in os.listdir(ext_dir) if os.path.isdir(os.path.join(ext_dir, d))) if os.path.isdir(ext_dir) else []

    def installed(n: str) -> bool:
        return os.path.isfile(os.path.join(project, "rd-workflow/claude_skills", n, "SKILL.md"))

    fs_installed = [n for n in fs_available if installed(n)]

    # 8.3 조정
    if manifest is not None:
        exts = manifest["extensions"]
        for n in sorted(set(fs_available) | set(JUDGE)):
            if n in exts and not installed(n):
                del exts[n]
                removed_rows.append(["removed", n])
            elif n not in exts and installed(n):
                exts[n] = {"installed_at": _now()}
                added_rows.append(["added", n])

    # --preset 답
    if opts["preset"] is not None:
        v = manifest["extensions"].get("verify") if manifest is not None else None
        if isinstance(v, dict):
            v["preset"] = opts["preset"]
        else:
            notes.append(["note", "--preset 무시: verify 가 설치돼 있지 않습니다"])
    # 허용 밖 preset
    if manifest is not None and isinstance(manifest["extensions"].get("verify"), dict):
        v = manifest["extensions"]["verify"]
        if "preset" in v and v["preset"] not in PRESETS:
            ask_rows.append(["ask-preset", str(v["preset"])])
            del v["preset"]

    # 8.4 분류
    if manifest is not None:
        in_manifest = set(manifest["extensions"])
        auto = [n for n in fs_available if n in in_manifest]
        not_installed = [n for n in fs_available if n not in in_manifest]
        if E is not None:
            new = [n for n in not_installed if n not in E]
            declined = [n for n in not_installed if n in E and n not in forced_new]
        else:
            new, declined = [], [n for n in not_installed if n not in forced_new]
    else:
        auto, new, declined = list(fs_installed), [n for n in fs_available if n not in fs_installed], []
        if auto or new:
            manifest = {"extensions": {}}

    # 8.5 자동 재설치
    ok_auto: list[str] = []
    for n in list(auto):
        src = os.path.join(ext_dir, n)
        dst = os.path.join(project, "rd-workflow/claude_skills", n)
        try:
            if not os.path.isfile(os.path.join(src, "SKILL.md")):
                raise OSError("extension SKILL.md 가 없습니다")
            os.makedirs(dst, exist_ok=True)
            for f in ("SKILL.md", "rules.md"):
                if os.path.isfile(os.path.join(src, f)):
                    shutil.copyfile(os.path.join(src, f), os.path.join(dst, f))
        except OSError as e:
            manifest["extensions"].pop(n, None)
            if n not in forced_new:
                forced_new.append(n)
            rows.append(["failed", n, "자동 재설치 실패: %s" % e])
            continue
        ent = manifest["extensions"].get(n)
        if not isinstance(ent, dict):
            ent = manifest["extensions"][n] = {}
        ent["installed_at"] = _now()
        ok_auto.append(n)
        rows.append(["auto", n])
    for n in forced_new:
        if n not in new:
            new.append(n)
    new = sorted(new)

    # 8.6 preset 머지
    new_seen = None
    ask_verifiers: list[str] = []
    v = manifest["extensions"].get("verify") if manifest is not None else None
    if "verify" in ok_auto and isinstance(v, dict) and v.get("preset") in PRESETS:
        summary, mnotes, new_seen, ask_verifiers = _merge(project, v["preset"], v.get("seen_verifiers"), opts)
        if summary:
            rows.append(summary)
        notes.extend([["note", t] for t in mnotes])
        if new_seen is not None:
            v["seen_verifiers"] = new_seen

    # 8.7 질문 (답은 인자)
    answered = set(opts["declined"]) | set(opts["failed"])
    unasked = [n for n in new if n not in answered]
    for n in sorted(set(opts["failed"])):
        rows.append(["failed", n])
    for n in opts["declined"]:
        if n in new:
            notes.append(["note", "거절 기록: %s" % n])
    for n in declined:
        rows.append(["declined", n])
    for n in unasked:
        ask_rows.append(["ask-ext", n, _description(project, n)])
    for n in ask_verifiers:
        ask_rows.append(["ask-verifier", n])

    # 8.8 저장
    if manifest is not None and (manifest["extensions"] or fs_available or os.path.exists(mpath)):
        if fs_available:
            E2 = (set(E or []) | set(fs_available)) - set(unasked) - set(opts["failed"])
            if E is None:
                notes.append(["note", "seen_extensions 새로 기록" if seen_ext_raw is None else "seen_extensions 형식 오류 — 다시 만듦"])
            manifest["seen_extensions"] = sorted(E2)
        try:
            atomic_write(mpath, _dump(manifest))
        except OSError as e:
            raise TplError(1, "FAIL\t%s\t매니페스트 쓰기 실패: %s" % (MANIFEST, e))

    for r in rows[:1] + notes + added_rows + removed_rows + rows[1:] + ask_rows:
        out(*r)
    return 0
