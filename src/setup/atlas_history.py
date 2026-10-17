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

import hashlib
import json
import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

_REPO = Path(__file__).resolve().parents[2]
_MODULE = _REPO / "Scripts" / "AtlasBaseline.psm1"
_CONDITIONS_MODULE = _REPO / "Scripts" / "BenchConditions.psm1"
_HISTORY = _REPO / ".atlas-local" / "benchmarks" / "history.jsonl"


def _history_path() -> Path:
    """ATLAS_HISTORY_PATH redirects the history, for tests that must not touch the real one."""
    override = os.environ.get("ATLAS_HISTORY_PATH")
    return Path(override) if override else _HISTORY


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


_SCHEMA_VERSION = 2
_CONDITIONS: dict[str, Any] | None = None
_CODE_REV: str | None = None


def _ps_list(items) -> str:
    return "@(" + ",".join("'" + str(i).replace("'", "''") + "'" for i in items) + ")"


def check_conditions(needs=(), allow_battery: bool = False, expect=(), seconds: int = 3) -> dict[str, Any]:
    """Capture the run conditions and refuse (exit code 3) when the policy says so.

    The policy lives in Scripts/BenchConditions.psm1 and is not repeated here:
    battery is refused unless allow_battery; a competing process or a Foundry NPU
    model refuses a run that needs the NPU; the rest only warns. The result is kept
    and stamped on every record written afterwards. If PowerShell is unavailable the
    check is skipped with a warning, because bookkeeping must not stop a benchmark.
    """
    global _CONDITIONS
    exe = _powershell()
    if exe is None or not _CONDITIONS_MODULE.exists():
        print("[conditions] PowerShell not available; running without a conditions check")
        return {}
    script = (
        f"Import-Module '{_CONDITIONS_MODULE}' -Force; "
        f"$c = Get-AtlasConditions -Seconds {int(seconds)}; "
        f"$r = Test-AtlasConditions -Conditions $c -Needs {_ps_list(needs)} -Expect {_ps_list(expect)}"
        + (" -AllowBattery" if allow_battery else "")
        + "; [pscustomobject]@{ conditions = $c; summary = (Get-AtlasConditionsSummary -Conditions $c); "
        "ok = $r.Ok; blockers = @($r.Blockers); warnings = @($r.Warnings) } | ConvertTo-Json -Depth 8 -Compress"
    )
    try:
        out = subprocess.run([exe, "-NoProfile", "-NonInteractive", "-Command", script],
                             capture_output=True, text=True, timeout=120)
        data = json.loads(out.stdout.strip().splitlines()[-1])
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        print("[conditions] could not check the run conditions; running without the check")
        return {}
    print("conditions: " + data["summary"])
    for w in data["warnings"]:
        print("  warning: " + w)
    if not data["ok"]:
        import sys

        for b in data["blockers"]:
            print("  refusing: " + b, file=sys.stderr)
        print("The conditions for a valid benchmark are not met (see above).", file=sys.stderr)
        raise SystemExit(3)
    cond = data["conditions"]
    if allow_battery and cond.get("onAcPower") is False:
        cond["overrides"] = ["allowBattery"]
    _CONDITIONS = cond
    return cond


def code_rev() -> str | None:
    """The Atlas revision, with +dirty when Scripts, src or evals differ from it."""
    global _CODE_REV
    if _CODE_REV:
        return _CODE_REV
    try:
        rev = subprocess.run(["git", "-C", str(_REPO), "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, timeout=30)
        if rev.returncode != 0 or not rev.stdout.strip():
            return None
        dirty = subprocess.run(["git", "-C", str(_REPO), "status", "--porcelain", "--", "Scripts", "src", "evals"],
                               capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    _CODE_REV = rev.stdout.strip() + ("+dirty" if dirty else "")
    return _CODE_REV


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
    # ---- history format 2
    kind: str = "benchmark",
    conditions: dict[str, Any] | None = None,
    harness: str | None = None,
    harness_version: str | None = None,
    n: int | None = None,
    stdev: float | None = None,
    reps: list[float] | None = None,
    order: str | None = None,
    prompt_kind: str | None = None,
    ctx_size: int | None = None,
    seed: int | None = None,
    model_artifact: Any = None,
) -> str | None:
    """Append one measurement. Returns the short stack id, or None if skipped.

    Field names mirror Add-AtlasBenchmarkRecord exactly; `Update-Workspace.ps1
    -History` reads both without knowing which wrote a given line. Fields that do
    not apply are left out, as the PowerShell side does.
    """
    state = state if state is not None else get_state()
    if not state:
        return None

    full_id = state.get("id") or ""
    if not full_id:
        return None
    short_id = full_id[:12]

    cond = conditions if conditions is not None else _CONDITIONS
    # PowerShell writes ISO 8601 with an offset; match it so both are
    # parsed by the same [datetime] cast on the way back out.
    ts = datetime.now().astimezone().isoformat(timespec="microseconds")
    record_id = hashlib.sha256(f"{ts}|{source}|{model}|{compute}|{prompt_tokens}|{short_id}".encode()).hexdigest()[:12]

    record_obj: dict[str, Any] = {
        "schemaVersion": _SCHEMA_VERSION,
        "id": record_id,
        "ts": ts,
        "stateId": short_id,
        "kind": kind,
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
    optional = {"harness": harness, "harnessVersion": harness_version, "n": n, "stdev": stdev, "reps": reps,
                "order": order, "promptKind": prompt_kind, "ctxSize": ctx_size, "seed": seed,
                "modelArtifact": model_artifact}
    record_obj.update({k: v for k, v in optional.items() if v is not None and v != ""})
    suite_run = os.environ.get("ATLAS_SUITE_RUN")
    if suite_run:
        record_obj["suiteRun"] = suite_run
    record_obj["onAcPower"] = cond.get("onAcPower") if cond else None
    if cond:
        record_obj["conditions"] = cond
    rev = code_rev()
    if rev:
        record_obj["codeRev"] = rev
    if extra:
        record_obj.update(extra)

    try:
        history = _history_path()
        history.parent.mkdir(parents=True, exist_ok=True)
        # One record per line, appended: never rewrite, so a crash costs at
        # most the line being written.
        with history.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record_obj, separators=(",", ":")) + "\n")
    except OSError:
        return None
    return short_id
