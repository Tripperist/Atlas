"""Score the parts of the output separately, for programs that build.

eval.py is all-or-nothing per case, which hides the difference between a program
that gets every stage right and one that cannot parse the input. This scores,
across the text-format functional cases that exit 0:

  parses        the program exits 0 on valid input at all
  stages        every "Stage N: ..." line matches
  total         the "Total tasks" line matches
  critical      the "Critical path" line matches

    python analyze.py runs/<model>/s1-fixed ...
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CASES = HERE / "tests" / "generated"


def parts(text: str) -> dict:
    lines = [ln.rstrip() for ln in text.replace("\r\n", "\n").split("\n") if ln.strip()]
    return {
        "stages": [ln for ln in lines if ln.startswith("Stage ")],
        "total": [ln for ln in lines if ln.startswith("Total tasks")],
        "critical": [ln for ln in lines if ln.startswith("Critical path")],
    }


def main() -> int:
    manifest = json.loads((CASES / "cases.json").read_text(encoding="utf-8"))
    cases = [c for c in manifest if c["category"] == "functional" and c["expect"]["exit"] == 0 and not c["expect"].get("json")]
    out = {}
    for arg in sys.argv[1:]:
        d = Path(arg)
        exe = HERE / ".work" / d.as_posix().replace("/", "_").replace(":", "") / "out" / "planner.exe"
        if not exe.exists():
            print(f"{d}: not built")
            continue
        tally = {"parses": 0, "stages": 0, "total": 0, "critical": 0}
        for c in cases:
            args = [str(CASES / c["file"]) if a == "{file}" else a for a in c["args"]]
            try:
                p = subprocess.run([str(exe), *args], capture_output=True, timeout=30)
            except subprocess.TimeoutExpired:
                continue
            if p.returncode != 0:
                continue
            tally["parses"] += 1
            got, want = parts(p.stdout.decode("utf-8", "replace")), parts(c["expect"]["stdout"])
            for k in ("stages", "total", "critical"):
                tally[k] += got[k] == want[k]
        out[str(d)] = {**tally, "of": len(cases)}
        n = len(cases)
        print(f"{str(d):42s} parses {tally['parses']:2d}/{n}  stages {tally['stages']:2d}/{n}  "
              f"total {tally['total']:2d}/{n}  critical path {tally['critical']:2d}/{n}")
    (HERE / "runs" / "analysis.json").write_text(json.dumps(out, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
