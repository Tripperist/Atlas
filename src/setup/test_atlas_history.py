"""Check the Python side of the benchmark history format.

Writes to a temporary history (ATLAS_HISTORY_PATH), never the real one.
Called by Scripts/Test-AtlasHistory.ps1; exit code is the number of failures.

    python src/setup/test_atlas_history.py
"""

import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

tmp = Path(tempfile.mkdtemp()) / "history.jsonl"
os.environ["ATLAS_HISTORY_PATH"] = str(tmp)

import atlas_history  # noqa: E402

failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    if not ok:
        failures += 1
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f"   {detail}" if detail and not ok else ""))


def last() -> dict:
    return json.loads(tmp.read_text(encoding="utf-8").strip().splitlines()[-1])


STATE = {"id": "ab" * 32, "geniex": {"version": "vtest"}}

print("Python record(), against a temporary history")

atlas_history.record(source="t", model="m", compute="npu", tok_per_sec=1.0, state=STATE)
r = last()
check("schemaVersion 2", r.get("schemaVersion") == 2)
check("12-hex id", isinstance(r.get("id"), str) and len(r["id"]) == 12 and all(c in "0123456789abcdef" for c in r["id"]))
check("kind defaults to benchmark", r.get("kind") == "benchmark")
check("onAcPower null with no conditions", "onAcPower" in r and r["onAcPower"] is None)
check("no conditions object when none was checked", "conditions" not in r)
check("codeRev recorded", "codeRev" in r and len(r["codeRev"]) >= 7, str(r.get("codeRev")))
check("unused optional fields left out", not any(k in r for k in ("n", "stdev", "reps", "ctxSize", "seed", "order")))

atlas_history.record(source="t", model="m", compute="npu", state=STATE, kind="smoke", n=3, stdev=0.5,
                     reps=[1.0, 2.0, 3.0], ctx_size=16384, seed=42, order="npu>gpu",
                     conditions={"onAcPower": False, "powerScheme": "Balanced"}, extra={"repetitions": 3})
r = last()
check("kind, n, stdev, reps, ctxSize, seed, order recorded",
      (r["kind"], r["n"], r["stdev"], r["reps"], r["ctxSize"], r["seed"], r["order"]) == ("smoke", 3, 0.5, [1.0, 2.0, 3.0], 16384, 42, "npu>gpu"))
check("explicit conditions stamped, onAcPower copied", r["conditions"]["powerScheme"] == "Balanced" and r["onAcPower"] is False)
check("-extra still works", r.get("repetitions") == 3)

ids = set()
for _ in range(20):
    atlas_history.record(source="t", model="m", compute="npu", state=STATE)
    ids.add(last()["id"])
check("ids are unique across rapid records", len(ids) == 20)

print("\nPython check_conditions(), against the live machine")
try:
    cond = atlas_history.check_conditions(needs=("cpu",))
    refused = False
except SystemExit as e:
    refused = True
    check("a refusal exits with code 3", e.code == 3, f"code {e.code}")
if refused:
    cond = atlas_history.check_conditions(needs=("cpu",), allow_battery=True)
    check("-allow_battery runs and marks the override", cond.get("overrides") == ["allowBattery"] and cond.get("onAcPower") is False)
else:
    check("on AC the check passes", cond.get("onAcPower") in (True, None))
atlas_history.record(source="t", model="m", compute="cpu", state=STATE)
r = last()
check("records after a check carry the conditions", "conditions" in r and r["onAcPower"] == cond.get("onAcPower"))

print(f"\n{'all checks passed' if not failures else str(failures) + ' FAILED'}")
sys.exit(failures)
