"""Independent oracle and test-case generator for the planner task.

This is a second implementation of prompt.txt, written in Python and without
looking at any model output, so that the expected results do not come from the
programs being judged. It is itself checked three ways before it is trusted:
a few answers derived by hand (self-test below), a differential run against the
C# reference in reference/Program.cs, and the fact that every test that the
reference passes was generated here.

    python oracle.py selftest
    python oracle.py gen <outdir>          write cases.json and the input files
    python oracle.py run <file> [--format text|json]
"""

from __future__ import annotations

import json
import random
import re
import sys
from pathlib import Path

NAME = re.compile(r"[A-Za-z0-9_.\-]+")
DIGITS = re.compile(r"[0-9]+")
USAGE = "usage: planner <file> [--format text|json]"


class Fail(Exception):
    """An error the program must report: exit code, stderr line, and how to check it."""

    def __init__(self, code: int, line: str, check: str, prefix: str | None = None):
        self.code, self.line, self.check, self.prefix = code, line, check, prefix


def strip_blank(s: str) -> str:
    return s.strip(" \t")


def parse(text: str):
    tasks: dict[str, tuple[list[str], int, int]] = {}
    order: list[str] = []
    lines = text.replace("\r\n", "\n").split("\n")
    for number, raw in enumerate(lines, start=1):
        s = strip_blank(raw.rstrip("\r"))
        if s == "" or s.startswith("#"):
            continue

        def bad(reason: str) -> Fail:
            return Fail(3, f"error: line {number}: {reason}", "prefix", f"error: line {number}:")

        duration = 1
        if s.endswith("]"):
            i = s.rfind("[")
            if i < 0:
                raise bad("unbalanced bracket")
            digits = strip_blank(s[i + 1 : -1])
            if not DIGITS.fullmatch(digits):
                raise bad("invalid duration")
            duration = int(digits)
            if not 1 <= duration <= 1_000_000:
                raise bad("duration out of range")
            head = strip_blank(s[:i])
        else:
            head = s
        if "[" in head or "]" in head:
            raise bad("misplaced bracket")

        deps: list[str] = []
        if ":" in head:
            name_part, dep_part = head.split(":", 1)
            name = strip_blank(name_part)
            for piece in dep_part.split(","):
                d = strip_blank(piece)
                if not NAME.fullmatch(d):
                    raise bad("invalid dependency")
                if d not in deps:
                    deps.append(d)
        else:
            name = strip_blank(head)
        if not NAME.fullmatch(name):
            raise bad("invalid name")
        if name in tasks:
            raise bad(f"duplicate task '{name}'")
        tasks[name] = (deps, duration, number)
        order.append(name)
    return tasks, order


def solve(text: str, fmt: str = "text") -> tuple[str, list[list[str]], int, list[str]]:
    tasks, order = parse(text)

    for t in order:
        for d in tasks[t][0]:
            if d not in tasks:
                line = f"error: task '{t}' depends on unknown task '{d}'"
                raise Fail(4, line, "equals")

    indeg = {t: len(tasks[t][0]) for t in order}
    succ: dict[str, list[str]] = {t: [] for t in order}
    for t in order:
        for d in tasks[t][0]:
            succ[d].append(t)

    stages: list[list[str]] = []
    current = sorted(t for t in order if indeg[t] == 0)
    seen = 0
    while current:
        stages.append(current)
        seen += len(current)
        nxt: list[str] = []
        for t in current:
            for s in succ[t]:
                indeg[s] -= 1
                if indeg[s] == 0:
                    nxt.append(s)
        current = sorted(nxt)
    if seen < len(order):
        raise Fail(5, "error: dependency cycle", "prefix", "error: dependency cycle")

    topo = [t for stage in stages for t in stage]
    total: dict[str, int] = {}
    nxt_of: dict[str, str | None] = {}

    def smaller(a: str | None, b: str | None) -> bool:
        while a is not None and b is not None:
            if a != b:
                return a < b
            a, b = nxt_of[a], nxt_of[b]
        return False

    for t in reversed(topo):
        best: str | None = None
        for s in succ[t]:
            if best is None or total[s] > total[best] or (total[s] == total[best] and smaller(s, best)):
                best = s
        total[t] = tasks[t][1] + (total[best] if best is not None else 0)
        nxt_of[t] = best

    start: str | None = None
    for t in topo:
        if start is None or total[t] > total[start] or (total[t] == total[start] and smaller(t, start)):
            start = t
    path: list[str] = []
    cur = start
    while cur is not None:
        path.append(cur)
        cur = nxt_of[cur]
    return "", stages, (total[start] if start is not None else 0), path


def render(text: str, fmt: str) -> tuple[int, str, str]:
    try:
        _, stages, duration, path = solve(text, fmt)
    except Fail as f:
        return f.code, "", f.line + "\n"
    count = sum(len(s) for s in stages)
    if fmt == "json":
        doc = {"stages": stages, "totalTasks": count, "criticalPath": {"duration": duration, "tasks": path}}
        return 0, json.dumps(doc, separators=(",", ":")) + "\n", ""
    out = [f"Stage {i}: {', '.join(s)}" for i, s in enumerate(stages, start=1)]
    out.append(f"Total tasks: {count}")
    if count:
        out.append(f"Critical path ({duration}): {' -> '.join(path)}")
    return 0, "\n".join(out) + "\n", ""


# ----------------------------------------------------------------- self-test

BASIC = """# a small build
fetch [2]
configure: fetch [1]
compile: fetch, configure [4]
test: compile [5]
package: compile, docs [3]
docs [2]
"""

BASIC_TEXT = """Stage 1: docs, fetch
Stage 2: configure
Stage 3: compile
Stage 4: package, test
Total tasks: 6
Critical path (12): fetch -> configure -> compile -> test
"""


def selftest() -> None:
    """Answers worked out by hand, not by running anything."""
    code, out, _ = render(BASIC, "text")
    assert (code, out) == (0, BASIC_TEXT), out
    # diamond, all durations 1: both a-b-d and a-c-d total 3, the smaller names win
    code, out, _ = render("d: b, c\nb: a\nc: a\na\n", "text")
    assert out == "Stage 1: a\nStage 2: b, c\nStage 3: d\nTotal tasks: 4\nCritical path (3): a -> b -> d\n", out
    # ordinal order: digits < upper case < '_' < lower case; culture order would differ
    code, out, _ = render("b\nB\n_x\n9\nA\n", "text")
    assert out.splitlines()[0] == "Stage 1: 9, A, B, _x, b", out
    # a longer chain wins over a shorter, heavier branch only if its total is larger
    code, out, _ = render("a [1]\nb: a [1]\nc: a [5]\n", "text")
    assert out.endswith("Critical path (6): a -> c\n"), out
    assert render("a: a\n", "text")[0] == 5
    assert render("a: b\n", "text")[0] == 4
    assert render("a [0]\n", "text")[0] == 3
    print("oracle self-test: ok")


# ------------------------------------------------------------------ cases


def chain(n: int, prefix: str, duration) -> str:
    lines = []
    for i in range(1, n + 1):
        name = f"{prefix}{i:06d}"
        dur = duration(i) if callable(duration) else duration
        dep = f": {prefix}{i - 1:06d}" if i > 1 else ""
        lines.append(f"{name}{dep} [{dur}]")
    return "\n".join(lines) + "\n"


def random_dag(seed: int, n: int, max_deps: int, max_dur: int, mixed_case: bool) -> str:
    rnd = random.Random(seed)
    pool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    names = []
    seen = set()
    while len(names) < n:
        nm = "".join(rnd.choice(pool if mixed_case else pool[:26]) for _ in range(rnd.randint(1, 3)))
        if rnd.random() < 0.2:
            nm += rnd.choice("_-.")
        if nm not in seen:
            seen.add(nm)
            names.append(nm)
    lines = []
    for i, nm in enumerate(names):
        deps = rnd.sample(names[:i], min(i, rnd.randint(0, max_deps))) if i else []
        dur = rnd.randint(1, max_dur)
        line = nm + (": " + ", ".join(deps) if deps else "") + f" [{dur}]"
        lines.append(line)
    rnd.shuffle(lines)
    return "\n".join(lines) + "\n"


def build_cases() -> list[dict]:
    C: list[dict] = []

    def add(cid, category, text, args, note=""):
        C.append({"id": cid, "category": category, "text": text, "args": args, "note": note})

    f = ["{file}"]
    fj = ["{file}", "--format", "json"]
    # ---- functional
    add("f01-basic", "functional", BASIC, f, "the example in the prompt")
    add("f02-basic-json", "functional", BASIC, fj, "JSON output")
    add("f03-format-before-file", "functional", BASIC, ["--format", "json", "{file}"], "flag order")
    add("f04-format-text-explicit", "functional", BASIC, ["{file}", "--format", "text"], "")
    add("f05-roots-tie", "functional", "c\nb\na\n", f, "critical path tie among single tasks")
    add("f06-diamond-tie", "functional", "d: b, c\nb: a\nc: a\na\n", f, "tie between two chains")
    add("f07-whitespace-crlf", "functional",
        "# header\r\n\r\n  \tfetch  [ 2 ]  \r\n\tconfigure :fetch\t[1]\r\n  compile:fetch,configure[4]\r\n#end\r\n", f,
        "tabs, CRLF, spacing, comments")
    add("f08-ordinal-sort", "functional", "b\nB\n_x\n9lives\nA\na.b\na-b\na_b\nZed\nalpha\n", f,
        "ordinal not culture ordering")
    add("f09-dup-deps", "functional", "a\nb: a, a, a [2]\n", f, "repeated dependency")
    add("f10-forward-reference", "functional", "b: a\na\n", f, "dependency defined later")
    add("f11-empty-file", "functional", "# nothing here\n\n", f, "zero tasks, text")
    add("f12-empty-file-json", "functional", "", fj, "zero tasks, JSON")
    add("f13-heavy-branch", "functional", "a [1]\nb: a [1]\nc: a [5]\nd: b [1]\n", f, "longest by duration not length")
    add("f14-chain-20", "functional", chain(20, "step", lambda i: (i % 5) + 1), f, "")
    add("f15-fanout-50", "functional",
        "root [3]\n" + "".join(f"leaf{i:02d}: root [{(i * 7) % 11 + 1}]\n" for i in range(50)), f, "")
    for k in range(1, 7):
        add(f"f{15 + k}-random-ties-{k}", "functional",
            random_dag(100 + k, 12 + 3 * k, 3, 2, mixed_case=(k % 2 == 0)), fj if k % 3 == 0 else f,
            "many equal-duration chains")
    # ---- errors
    add("e01-no-args", "error", "", [], "")
    add("e02-bad-format", "error", "a\n", ["{file}", "--format", "xml"], "")
    add("e03-two-files", "error", "a\n", ["{file}", "{file}"], "")
    add("e04-format-missing-value", "error", "a\n", ["{file}", "--format"], "")
    add("e05-missing-file", "error", "", ["{missing}"], "")
    add("e06-bad-name", "error", "a\nb!\nc\n", f, "line 2")
    add("e07-duration-zero", "error", "a\nb [0]\n", f, "")
    add("e08-duration-text", "error", "a [two]\n", f, "")
    add("e09-duration-fraction", "error", "a [2.5]\n", f, "")
    add("e10-duration-range", "error", "a [1000001]\n", f, "")
    add("e11-unclosed-bracket", "error", "a [2\n", f, "")
    add("e12-empty-deps", "error", "a\nb:\n", f, "")
    add("e13-empty-dep-item", "error", "a\nc\nb: a,,c\n", f, "")
    add("e14-duplicate-task", "error", "# c\na\n\nb\na [2]\n", f, "line number counts blank and comment lines")
    add("e15-unknown-dep", "error", "a: ghost\nb: a\n", f, "")
    add("e16-unknown-dep-order", "error", "b: a, zed, yak\na\n", f, "first unknown in listed order")
    add("e17-cycle-3", "error", "a: c\nb: a\nc: b\nd\n", f, "")
    add("e18-self-cycle", "error", "a: a\n", f, "")
    add("e19-unknown-before-cycle", "error", "a: b\nb: a\nc: ghost\n", f, "exit 4 wins over 5")
    add("e20-syntax-before-unknown", "error", "a: ghost\nb!\n", f, "exit 3 wins over 4")
    # ---- scale and robustness
    add("s01-large-durations", "scale", chain(3000, "big", 1_000_000), f, "total exceeds 32 bits")
    add("s02-chain-100000", "scale", chain(100_000, "n", lambda i: 1 + (i % 3)), f, "deep chain: recursion overflows")
    add("s03-fanout-100000", "scale",
        "root\n" + "".join(f"x{i:06d}: root [{1 + i % 4}]\n" for i in range(1, 100_000)), f, "wide stage")
    add("s04-random-dag-3000", "scale", random_dag(7, 3000, 4, 3, mixed_case=True), f, "dense random DAG")
    return C


def generate(outdir: Path) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    manifest = []
    for c in build_cases():
        path = outdir / f"{c['id']}.txt"
        # write bytes so CRLF cases keep their line endings
        path.write_bytes(c["text"].encode("utf-8"))
        fmt = "json" if "--format" in c["args"] and c["args"][c["args"].index("--format") + 1 : c["args"].index("--format") + 2] == ["json"] else "text"
        exp: dict
        usage_error = (
            not c["args"]
            or c["args"] == ["{file}", "{file}"]
            or c["args"] == ["{file}", "--format", "xml"]
            or c["args"] == ["{file}", "--format"]
        )
        if usage_error:
            exp = {"exit": 1, "stdout": "", "stderrStartsWith": "usage: planner"}
        elif c["args"] == ["{missing}"]:
            exp = {"exit": 2, "stdout": "", "stderrStartsWith": "error: cannot read file:"}
        else:
            try:
                code, out, err = render(c["text"], fmt)
            except Fail as f:  # pragma: no cover - render catches Fail
                raise
            if code == 0:
                exp = {"exit": 0, "stdout": out, "json": fmt == "json"}
            else:
                line = err.rstrip("\n")
                # the oracle reports the same line the spec asks for; derive how to check it
                try:
                    solve(c["text"], fmt)
                except Fail as f:
                    key = "stderrEquals" if f.check == "equals" else "stderrStartsWith"
                    exp = {"exit": code, "stdout": "", key: f.line if f.check == "equals" else f.prefix}
        manifest.append(
            {"id": c["id"], "category": c["category"], "file": path.name, "args": c["args"], "note": c["note"], "expect": exp}
        )
    (outdir / "cases.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    print(f"wrote {len(manifest)} cases to {outdir}")


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "selftest":
        selftest()
        return 0
    if len(argv) >= 3 and argv[1] == "gen":
        generate(Path(argv[2]))
        return 0
    if len(argv) >= 3 and argv[1] == "run":
        fmt = "json" if argv[-2:] == ["--format", "json"] else "text"
        code, out, err = render(Path(argv[2]).read_text(encoding="utf-8"), fmt)
        sys.stdout.write(out)
        sys.stderr.write(err)
        return code
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
