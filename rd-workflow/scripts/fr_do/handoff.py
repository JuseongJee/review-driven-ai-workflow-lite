#!/usr/bin/env python3
"""줄기 인계 파일을 만들고, --launch 면 promote.sh 로 줄기를 띄웁니다.

사용: python3 rd-workflow/scripts/fr_do/handoff.py <spec.json> [--launch]

spec.json 예:
{
  "wave": "2026-11-08-p1",
  "why": "주성님 지시 「착수 가능한 것들 띄워」 로 띄웠습니다.",
  "context": "(선택) 모든 줄기에 공통인 배경 한두 문장",
  "streams": [
    {"slug": "task-common", "title": "작업 상태 공통 스크립트 결함 3건",
     "frs": ["2026-11-07-fr-index-awk-locale-collation"],
     "owns": "`rd-workflow/scripts/_task_common.sh`, 그 테스트",
     "owns_paths": ["rd-workflow/scripts/_task_common.sh"],
     "notes": "- 알아 둘 것 불릿들(마크다운)\\n- 검증: 프로젝트 규칙의 검증 절차"}
  ]
}
frs 는 items/ 파일 이름에서 .md 를 뗀 stem 입니다.
owns 는 인계 파일에 보이는 사람용 문자열이고, owns_paths 는 --launch 성공 시 active.tsv 에 쓰는 경로 배열입니다.
active.tsv 한 줄은 `<slug>\t<owns_paths 를 ; 로 이음>\t<frs 를 ; 로 이음>` 입니다(pick.py 가 3번째 칸의 FR 을 재선정에서 보류).
인계 파일은 <상태 폴더>/waves/<wave>/handoff-<slug>.md 에 씁니다.
상태 폴더는 <기본 체크아웃>/rd-workflow-workspace/.lifecycle/fr-do/ 입니다.
"""
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent


def main_checkout() -> pathlib.Path:
    out = subprocess.run(["git", "-C", str(HERE), "worktree", "list", "--porcelain"],
                         capture_output=True, text=True, check=True).stdout
    return pathlib.Path(out.splitlines()[0].split(" ", 1)[1])


def state_dir(root: pathlib.Path) -> pathlib.Path:
    d = root / "rd-workflow-workspace/.lifecycle/fr-do"
    d.mkdir(parents=True, exist_ok=True)
    return d


def check_names(spec):
    names = [("wave", spec["wave"])] + [("slug", s["slug"]) for s in spec["streams"]]
    for kind, v in names:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", v) or v in (".", ".."):
            print(f"{kind} 값이 올바르지 않습니다(영문·숫자·._- 만, . 와 .. 제외): {v!r}", file=sys.stderr)
            sys.exit(2)


def build(spec, root, state):
    streams = spec["streams"]
    names = ", ".join(f"`{s['slug']}`" for s in streams)
    own_rows = "\n".join(f"| `{s['slug']}` | {s['owns']} |" for s in streams)
    reports = state / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    tail = (HERE / "handoff-tail.md").read_text().replace("{REPORTS}", str(reports))
    wave = state / "waves" / spec["wave"]
    wave.mkdir(parents=True, exist_ok=True)
    items = root / "rd-workflow-workspace/backlog/items"
    for s in streams:
        for stem in s["frs"]:
            if not (items / f"{stem}.md").is_file():
                sys.exit(f"FR 상세 없음: {items / (stem + '.md')}")
        fr_rows = "\n".join(
            f"| `{stem[11:]}` | `rd-workflow-workspace/backlog/items/{stem}.md` |" for stem in s["frs"])
        ctx = f"\n{spec['context']}\n" if spec.get("context") else ""
        body = f"""# 인계 — 줄기 `{s['slug']}` ({s['title']})

호출 세션이 띄웠습니다. {spec['why']} 지금 {len(streams)}줄기가 함께 돕니다: {names}.

## 이 세션이 맡는 FR

| FR | 상세 |
| --- | --- |
{fr_rows}
{ctx}
## 알아 둘 것

{s['notes'].strip()}

## 파일 소유

| 줄기 | 소유 파일 |
| --- | --- |
{own_rows}

- 다른 줄기 소유 파일을 고쳐야 하면 고치지 말고 호출 세션에 묻거나 마감 보고에 적습니다. 테스트 등록 변경도 마감 보고에 적습니다(호출 세션이 등록합니다).
- `.claude/rules/rd-workflow/*.md` 를 고쳐야 하면 고치지 말고 마감 보고에 적습니다. FR 인덱스는 자기 Source FR 행만 고칩니다.
- issue 는 이 줄기가 닫지 않습니다(호출 세션이 발행 뒤 닫습니다).

"""
        (wave / f"handoff-{s['slug']}.md").write_text(body + tail)
        print(f"인계 작성: {wave / ('handoff-' + s['slug'] + '.md')}")
    return wave


def launch_verdict(rc, lines):
    """promote 출력 → (요약 줄, 감시 목록 등록 여부).

    promote 는 기동이 실패해도 rc 0 으로 끝나고 결과는 「promote: 세션 기동 …」 줄로만 냅니다.
    기동 결과가 failed 면 살아 있는 줄기가 없으므로 등록하지 않습니다.
    unknown·상태 기록 미완료는 줄기가 떠 있을 수 있어 등록합니다(do.md 가 resolve-launch 로 확인).
    """
    found = [l for l in lines if l.startswith("promote: 세션 기동")]
    summary = found[-1] if found else ""
    failed = summary.startswith("promote: 세션 기동 결과 — failed")
    return summary, rc == 0 and not failed


def active_row(s):
    """줄기 spec 하나 → active.tsv 한 줄(줄바꿈 포함)."""
    return s["slug"] + "\t" + ";".join(s.get("owns_paths", [])) + "\t" + ";".join(s["frs"]) + "\n"


def launch(spec, root, state, wave):
    log = wave / "promote.log"
    active = state / "active.tsv"
    for s in spec["streams"]:
        cmd = ["bash", "rd-workflow/scripts/lifecycle/promote.sh", "--short-title", s["slug"], "--size", "small"]
        for stem in s["frs"]:
            cmd += ["--source-fr", f"rd-workflow-workspace/backlog/items/{stem}.md"]
        cmd += ["--handoff", str(wave / f"handoff-{s['slug']}.md")]
        with log.open("a") as f:
            f.write(f"=== {s['slug']}\n")
            f.flush()
            rc = subprocess.run(cmd, cwd=root, stdout=f, stderr=subprocess.STDOUT).returncode
        summary, register = launch_verdict(rc, log.read_text().split(f"=== {s['slug']}\n")[-1].splitlines())
        print(f"{s['slug']}: promote rc={rc} {summary or '(기동 결과 줄 없음 — ' + str(log) + ' 확인)'}")
        if register:
            rows = active.read_text().splitlines() if active.exists() else []
            if s["slug"] not in [r.split("\t", 1)[0] for r in rows]:
                with active.open("a") as f:
                    f.write(active_row(s))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
    check_names(spec)
    root = main_checkout()
    state = state_dir(root)
    wave = build(spec, root, state)
    if "--launch" in sys.argv[2:]:
        launch(spec, root, state, wave)
