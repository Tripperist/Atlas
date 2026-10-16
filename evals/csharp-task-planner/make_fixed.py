"""Apply the smallest edit that makes each failing program compile.

The repair round showed that one round of compiler feedback rarely makes either
model fix its own code, which leaves the test suite scoring every sample at zero
and says nothing about the logic. This stage separates the two questions: how
many edits does a human need to get the program to compile (reported), and once
it compiles, does it do the right thing (scored by eval.py).

Every edit is a single exact replacement, asserted to match exactly once, and is
written to FIXES.md beside the result so the intervention is auditable. Edits
change as little as possible and, where a choice is forced, keep the model's own
intent. They were written by hand (by Claude), not by either model under test.

    python make_fixed.py
"""

from __future__ import annotations

import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNS = HERE / "runs"

CS0165_ARRAY = (
    "CS0165 'lines' unassigned: the compiler cannot know Environment.Exit never returns",
    "string[] lines;", "string[] lines = Array.Empty<string>();",
)
STRING_LT = "CS0019 '<' on strings"
OUT_PROPERTY = (
    "CS0206 property passed as out: parse into a local and assign",
    "out task.Duration) || task.Duration <= 0)",
    "out var parsedDuration) || (task.Duration = parsedDuration) <= 0)",
)

FIXES: dict[str, list[tuple[str, str, str]]] = {
    "qwen3-coder-30b-a3b/s1": [CS0165_ARRAY],
    "qwen3-coder-30b-a3b/s2": [
        ("CS0165 'lines' unassigned: the compiler cannot know Environment.Exit never returns",
         "List<string> lines;", "List<string> lines = new();"),
        (STRING_LT, "pred[0] < predecessors[0]", "string.CompareOrdinal(pred[0], predecessors[0]) < 0"),
    ],
    "qwen3-coder-30b-a3b/s3": [CS0165_ARRAY],
    "qwen2.5-coder-7b/s1": [
        OUT_PROPERTY,
        (STRING_LT, 'string.Join(",", path) < string.Join(",", criticalPath)',
         'string.CompareOrdinal(string.Join(",", path), string.Join(",", criticalPath)) < 0'),
    ],
    "qwen2.5-coder-7b/s2": [
        OUT_PROPERTY,
        (STRING_LT, 'string.Join("", currentPath) < string.Join("", criticalPath)',
         'string.CompareOrdinal(string.Join("", currentPath), string.Join("", criticalPath)) < 0'),
        ("CS1656 assignment to a foreach variable (1 of 2)", "foreach (var line in lines)", "foreach (var rawLine in lines)"),
        ("CS1656 assignment to a foreach variable (2 of 2)", "line = line.Trim();", "var line = rawLine.Trim();"),
    ],
    "qwen2.5-coder-7b/s3": [
        ("CS0708/0710/0713/0718 a data class declared static (1 of 4)", "static class Task", "class Task"),
        ("same, exception type (2 of 4)", "static class SyntaxErrorException", "class SyntaxErrorException"),
        ("same, exception type (3 of 4)", "static class UnknownDependencyException", "class UnknownDependencyException"),
        ("same, exception type (4 of 4)", "static class DependencyCycleException", "class DependencyCycleException"),
        ("CS0103 uses Newtonsoft's JsonConvert, a NuGet package the task forbids; use System.Text.Json",
         "JsonConvert.SerializeObject(result, Formatting.Indented)", "System.Text.Json.JsonSerializer.Serialize(result)"),
    ],
}


def main() -> int:
    summary = {}
    for rel, edits in FIXES.items():
        src = RUNS / rel
        out = src.parent / f"{src.name}-fixed"
        out.mkdir(exist_ok=True)
        code = (src / "Program.cs").read_text(encoding="utf-8")
        notes = []
        for why, old, new in edits:
            if code.count(old) != 1:
                raise SystemExit(f"{rel}: expected exactly one match for {old!r}, found {code.count(old)}")
            code = code.replace(old, new)
            notes.append(f"- {why}\n  - before: `{old}`\n  - after:  `{new}`")
        (out / "Program.cs").write_text(code, encoding="utf-8")
        (out / "FIXES.md").write_text(
            f"# Minimal compile fixes for {rel}\n\n{len(edits)} edit(s), made by hand so the program builds; "
            "behaviour is otherwise the model's own.\n\n" + "\n".join(notes) + "\n", encoding="utf-8")
        summary[rel] = len(edits)
        print(f"{rel}: {len(edits)} edit(s) -> {out.relative_to(HERE)}")
    (RUNS / "fix-counts.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
