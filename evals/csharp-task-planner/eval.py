"""Build and score planner programs against the generated black-box tests.

    python oracle.py gen tests/generated                  # once
    python eval.py reference                              # validate the tests
    python eval.py runs/qwen3-coder-30b/s1 runs/...       # score model output
    python eval.py --all runs                             # every run under runs/

Each directory holds a Program.cs. It is built unmodified, with the project file
below, and written back next to it as result.json.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CSPROJ = """<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <AssemblyName>planner</AssemblyName>
  </PropertyGroup>
</Project>
"""
STACK_OVERFLOW = {3221225725, -1073741571}  # 0xC00000FD
TIMEOUT_S = 30


def canon(value):
    if isinstance(value, dict):
        return {k: canon(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [canon(v) for v in value]
    return value


def norm_text(s: str) -> list[str]:
    lines = [ln.rstrip() for ln in s.replace("\r\n", "\n").split("\n")]
    while lines and lines[-1] == "":
        lines.pop()
    return lines


def build(src: Path, work: Path) -> dict:
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    shutil.copy(src / "Program.cs", work / "Program.cs")
    (work / "planner.csproj").write_text(CSPROJ, encoding="utf-8")
    t0 = time.time()
    p = subprocess.run(
        ["dotnet", "build", "-c", "Release", "--nologo", "-v", "q", "-o", str(work / "out")],
        cwd=work, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    text = p.stdout + p.stderr
    errors = sorted({m.group(0) for m in re.finditer(r"Program\.cs\(\d+,\d+\): error CS\d+: [^\r\n\[]+", text)})
    warnings = sorted({m.group(0) for m in re.finditer(r"Program\.cs\(\d+,\d+\): warning (?:CS|CA|IDE)\d+: [^\r\n\[]+", text)})
    exe = work / "out" / "planner.exe"
    return {
        "built": p.returncode == 0 and exe.exists(),
        "errors": len(errors), "errorSample": errors[:30],
        "warnings": len(warnings), "warningSample": warnings[:5],
        "buildSeconds": round(time.time() - t0, 1),
        "exe": str(exe),
    }


def check(case: dict, exe: str, cases_dir: Path) -> tuple[bool, str, float]:
    file = cases_dir / case["file"]
    missing = cases_dir / "does-not-exist.txt"
    args = [str(file) if a == "{file}" else str(missing) if a == "{missing}" else a for a in case["args"]]
    exp = case["expect"]
    t0 = time.time()
    try:
        p = subprocess.run([exe, *args], capture_output=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return False, f"timeout after {TIMEOUT_S}s", time.time() - t0
    elapsed = time.time() - t0
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace")
    if p.returncode in STACK_OVERFLOW or "Stack overflow" in err:
        return False, "stack overflow", elapsed
    if p.returncode != exp["exit"]:
        first = (err.strip().splitlines() or [""])[0][:90]
        return False, f"exit {p.returncode}, expected {exp['exit']} ({first})", elapsed
    if exp["exit"] == 0:
        if exp.get("json"):
            try:
                same = canon(json.loads(out)) == canon(json.loads(exp["stdout"]))
            except json.JSONDecodeError:
                return False, "stdout is not valid JSON", elapsed
            return (same, "" if same else "JSON differs", elapsed)
        got, want = norm_text(out), norm_text(exp["stdout"])
        if got == want:
            return True, "", elapsed
        for i, (a, b) in enumerate(zip(got, want)):
            if a != b:
                return False, f"line {i + 1}: got {a[:70]!r}, expected {b[:70]!r}", elapsed
        return False, f"{len(got)} lines, expected {len(want)}", elapsed
    if out.strip():
        return False, "wrote to stdout on an error", elapsed
    first = (err.strip().splitlines() or [""])[0]
    if "stderrEquals" in exp and first != exp["stderrEquals"]:
        return False, f"stderr {first[:80]!r}", elapsed
    if "stderrStartsWith" in exp and not first.startswith(exp["stderrStartsWith"]):
        return False, f"stderr {first[:80]!r}", elapsed
    return True, "", elapsed


def score(src: Path, cases_dir: Path, work_root: Path) -> dict:
    result = {"source": str(src)}
    code = (src / "Program.cs").read_text(encoding="utf-8", errors="replace")
    result["lines"] = sum(1 for ln in code.splitlines() if ln.strip())
    b = build(src, work_root / src.as_posix().replace("/", "_").replace(":", ""))
    result["build"] = {k: v for k, v in b.items() if k != "exe"}
    cases = json.loads((cases_dir / "cases.json").read_text(encoding="utf-8"))
    by_cat: dict[str, list[int]] = {}
    failures = []
    slowest = 0.0
    if b["built"]:
        for c in cases:
            ok, why, secs = check(c, b["exe"], cases_dir)
            cat = by_cat.setdefault(c["category"], [0, 0])
            cat[1] += 1
            if ok:
                cat[0] += 1
            else:
                failures.append({"id": c["id"], "why": why})
            if c["category"] == "scale":
                slowest = max(slowest, secs)
    else:
        for c in cases:
            by_cat.setdefault(c["category"], [0, 0])[1] += 1
    result["passed"] = sum(v[0] for v in by_cat.values())
    result["total"] = sum(v[1] for v in by_cat.values())
    result["byCategory"] = {k: f"{v[0]}/{v[1]}" for k, v in by_cat.items()}
    result["failures"] = failures
    result["slowestScaleCaseSeconds"] = round(slowest, 1)
    (src / "result.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="*")
    ap.add_argument("--all", metavar="ROOT")
    ap.add_argument("--cases", default=str(HERE / "tests" / "generated"))
    ap.add_argument("--work", default=str(HERE / ".work"))
    a = ap.parse_args()
    dirs = [Path(d) for d in a.dirs]
    if a.all:
        dirs += sorted(p.parent for p in Path(a.all).rglob("Program.cs"))
    cases_dir, work = Path(a.cases), Path(a.work)
    if not (cases_dir / "cases.json").exists():
        print("no cases: run  python oracle.py gen tests/generated", file=sys.stderr)
        return 2
    for d in dirs:
        r = score(d, cases_dir, work)
        b = r["build"]
        status = "BUILD FAILED" if not b["built"] else f"{r['passed']}/{r['total']}"
        extra = f"  errors={b['errors']}" if not b["built"] else f"  warnings={b['warnings']}  slowest scale case {r['slowestScaleCaseSeconds']}s"
        print(f"{str(d):45s} {status:>13s}{extra}  {r['byCategory']}")
        for f in r["failures"][:12]:
            print(f"    - {f['id']}: {f['why']}")
        if not b["built"]:
            for e in b["errorSample"][:3]:
                print(f"    ! {e[:150]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
