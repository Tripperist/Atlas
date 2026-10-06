"""Append benchmark results to the Atlas history from Python.

The history (the README "Keeping the workspace current" section) stamps every measurement with a short hash of
the stack it ran under -- drivers, OS build, GenieX version, llama.cpp revision
and ONNX Runtime versions -- so results taken under different stacks are never
silently compared.

State capture and hashing live in Scripts/AtlasBaseline.psm1 and are **not**
reimplemented here. A second implementation would have to agree with the first
exactly, and any drift would split one machine into two apparent stacks, which
is precisely the confusion the history exists to prevent. So this shells out to
the module and appends the record itself.

Recording is best-effort: a benchmark that completed is never failed over
bookkeeping.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

_REPO = Path(__file__).resolve().parents[2]
_MODULE = _REPO / "Scripts" / "AtlasBaseline.psm1"
_HISTORY = _REPO / ".atlas-local" / "benchmarks" / "history.jsonl"


def _powershell() -> str | None:
    return shutil.which("pwsh") or shutil.which("powershell")


def get_state() -> dict[str, Any] | None:
    """Capture the current stack via the PowerShell module, or None."""
    exe = _powershell()
    if exe is None or not _MODULE.exists():
        return None
    script = (
        f"Import-Module '{_MODULE}' -Force; "
        "Get-AtlasState | ConvertTo-Json -Depth 6 -Compress"
    )
    try:
        out = subprocess.run(
            [exe, "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            text=True,
            timeout=180,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def record(
    *,
    source: str,
    model: str,
    compute: str,
    tok_per_sec: float | None = None,
    first_token_s: float | None = None,
    tokens: int | None = None,
    prefill_tps: float | None = None,
    prompt_tokens: int | None = None,
    csv_path: str | None = None,
    extra: dict[str, Any] | None = None,
    state: dict[str, Any] | None = None,
) -> str | None:
    """Append one measurement. Returns the short stack id, or None if skipped.

    Field names mirror Add-AtlasBenchmarkRecord exactly; `Update-Workspace.ps1
    -History` reads both without knowing which wrote a given line.
    """
    state = state if state is not None else get_state()
    if not state:
        return None

    full_id = state.get("id") or ""
    if not full_id:
        return None
    short_id = full_id[:12]

    record_obj: dict[str, Any] = {
        # PowerShell writes ISO 8601 with an offset; match it so both are
        # parsed by the same [datetime] cast on the way back out.
        "ts": datetime.now().astimezone().isoformat(timespec="microseconds"),
        "stateId": short_id,
        "source": source,
        "model": model,
        "compute": compute,
        "tokPerSec": tok_per_sec,
        "firstTokenS": first_token_s,
        "tokens": tokens,
        "prefillTps": prefill_tps,
        "promptTokens": prompt_tokens,
        "csv": csv_path,
        "state": state,
    }
    if extra:
        record_obj.update(extra)

    try:
        _HISTORY.parent.mkdir(parents=True, exist_ok=True)
        # One record per line, appended: never rewrite, so a crash costs at
        # most the line being written.
        with _HISTORY.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record_obj, separators=(",", ":")) + "\n")
    except OSError:
        return None
    return short_id
