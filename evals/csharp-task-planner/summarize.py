"""Collect the saved results of every run into one markdown table (runs/summary.md).

    python summarize.py
    python summarize.py --runs scratch/runs      # a folder made with generate.py --out

Needs both models and seeds 1 to 3, each with its -repair1 and -fixed results and an entry in analysis.json.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNS = HERE / "runs"
MODELS = [("qwen3-coder-30b-a3b", "Qwen3-Coder-30B-A3B"), ("qwen2.5-coder-7b", "Qwen2.5-Coder-7B")]


def load(p: Path):
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else None


def main() -> None:
    global RUNS
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default=str(RUNS), metavar="DIR", help="the folder to summarize (default: runs/)")
    RUNS = Path(ap.parse_args().runs)
    fixes = load(RUNS / "fix-counts.json") or {}
    analysis = load(RUNS / "analysis.json") or {}
    rows = []
    for key, label in MODELS:
        for seed in (1, 2, 3):
            base = RUNS / key / f"s{seed}"
            meta, res = load(base / "meta.json"), load(base / "result.json")
            rep_meta, rep_res = load(RUNS / key / f"s{seed}-repair1" / "meta.json"), load(RUNS / key / f"s{seed}-repair1" / "result.json")
            fixed = load(RUNS / key / f"s{seed}-fixed" / "result.json")
            same = (base / "Program.cs").read_text(encoding="utf-8") == (RUNS / key / f"s{seed}-repair1" / "Program.cs").read_text(encoding="utf-8")
            a = next((v for k, v in analysis.items() if k.replace("\\", "/").endswith(f"{key}/s{seed}-fixed")), None)
            tok = meta.get("completionTokens")
            rows.append(
                f"| {label} | {seed} | {tok} | {meta['wallSeconds']:.0f} s | {res['lines']} | "
                f"{'yes' if meta['followedFormat'] else 'no'} | **{res['build']['errors']}** | "
                f"{'identical' if same else 'changed'}, {'builds' if rep_res['build']['built'] else str(rep_res['build']['errors']) + ' errors'} | "
                f"{fixes.get(f'{key}/s{seed}', '—')} | "
                f"**{fixed['passed']}/{fixed['total']}** ({fixed['byCategory'].get('functional')}, {fixed['byCategory'].get('error')}, {fixed['byCategory'].get('scale')}) | "
                f"{a['stages']}/{a['of']} | {a['critical']}/{a['of']} |"
            )
    header = (
        "| Model | Seed | Tokens | Time | Lines | One code block | Compile errors | After one feedback round | Edits to compile | "
        "Tests after fix (functional, error, scale) | Stages right | Critical path right |\n"
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
    )
    (RUNS / "summary.md").write_text(header + "\n".join(rows) + "\n", encoding="utf-8")
    print(header + "\n".join(rows))


if __name__ == "__main__":
    main()
