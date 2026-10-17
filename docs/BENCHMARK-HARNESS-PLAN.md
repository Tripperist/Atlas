# Benchmark harness plan

**Status: phase 1 is implemented (2026-10-17); the rest is a proposal.** Written 2026-10-17 after a session
in which several published numbers turned out to depend on conditions nobody had
checked. When a phase ships, its entry moves to [BENCHMARKS.md](BENCHMARKS.md) and the
README, and this file records what was decided.

## Why

Three problems, all seen this session:

1. **Published numbers that cannot be regenerated.** The Foundry context-length curves,
   the unsampled variant comparison, the stock llama.cpp control and the
   Python-versus-C# ORT comparison were inline commands or scratch scripts, and the
   control results were entered into the history by hand from typed numbers.
2. **Runs under conditions nobody checked.** An ORT GenAI benchmark ran with the
   laptop on battery and looked like a 3× regression in a package upgrade. Earlier,
   a stray `geniex serve`, a Foundry model left loaded on the NPU, a utilization
   sampler competing for the CPU, and an unexplained half-speed state each produced
   a plausible wrong figure.
3. **Comparisons built by hand.** The v0.8.0-to-v0.9.0 and Foundry re-measurement
   tables were assembled manually, twice.

**Principle:** every number in the docs maps to a committed command, and every run
records the conditions it ran under.

## Decisions taken

| Question | Decision |
| --- | --- |
| Laptop on battery | **Refuse** unless `-AllowBattery` is given; the run is then recorded with `onAcPower: false` |
| First pass | Conditions check plus committed harnesses (phases 1 and 2) |
| Canary | Later (phase 4): warn below about 85 % of the AC reference, abort below about 60 % unless overridden |
| History format | **Additive**: new fields, old records stay valid and read as "unknown" |
| C# benchmark mode | **Its own project**, `src/csharp/OrtBench`; `GenAiProbe` stays a smoke probe |
| Foundry loaded-model check | Run `foundry server status` first. Only if the daemon is up, `foundry model list --loaded`. **Never start it, and never stop one we did not start.** Checked on this machine: `status` has no side effect, `foundry cache ls` starts the daemon, and a stopped daemon holds no models |
| Run folders | `.atlas-local/benchmarks/runs/`, git-ignored |
| Page form | **Generated tables in BENCHMARKS.md first**; an HTML page with charts can be built from the same JSON later |
| The published figure for a cell | **The latest valid AC run**, with a small pin list that overrides it when an older run is the right one |
| Existing records | **Backfill** the valid ones into the new format, flagged `schemaVersion: "1-migrated"`, with fields that were never recorded left null |

## Phase 1: conditions check (done)

A PowerShell module, `Scripts/AtlasConditions.psm1`, used by every harness. Python
harnesses reach it through `atlas_history.py`, the way they already reach the stack
hash in `AtlasBaseline.psm1`.

Collected before a run and stored in each record:

- AC or battery, and battery percent
- the Windows power scheme
- CPU idle over about 3 s
- processes that compete: `geniex` (serve or infer), `llama-*`, `foundrylocald` and any
  model it has loaded, `atlas-chat`
- background consumers above about 0.3 core, such as `CrossDeviceService`

Policy defaults, adjustable in review:

- **Block:** on battery (override `-AllowBattery`).
- **Block for NPU runs:** another process holding the NPU. Warn otherwise.
- **Warn:** CPU idle above about 15 %, or a background consumer above the threshold.

Also in this phase: `#requires -Version 7` on every script, so a Windows PowerShell 5.1
launch fails with a clear message instead of a parse error, and a one-off migration that
marks the history records already known to be contaminated (battery, contended load)
with an explicit `valid: false` and a reason.

**Done when:** running on battery refuses; `-AllowBattery` runs and records `false`; on
AC it passes; with a `geniex serve` running, an NPU run refuses.

**What shipped, and where it differs from the plan.**

- `Scripts/AtlasConditions.psm1` and the history format fields, as planned. Checked live
  against a Foundry daemon with a model loaded on the NPU and a running `geniex serve`.
- `#requires -Version 7` is on the harness scripts, `Update-Workspace.ps1` and the tests,
  **not** on the four bootstrap scripts: `Install-Prerequisites.ps1` does not install
  PowerShell 7, so they must run on a stock machine.
- `Update-Workspace.ps1` records its conditions and never refuses (`-WarnOnly`), because
  refusing would block the update its smoke check is verifying.
- `bench_foundry_sdk.py` does not expect the Foundry daemon: it needs the NPU for itself, so
  a daemon holding a model there blocks it. (A daemon holding the same model during the one
  464 s in-process load is a candidate cause; that is not established.) `Invoke-FoundryBench.ps1`
  talks to the daemon and does expect it.
- Two test-only hooks were added: `ATLAS_HISTORY_PATH` redirects the history, and
  `ATLAS_TEST_ON_BATTERY` makes the check report battery, so the refusal can be tested
  plugged in.
- Six existing records are marked `valid: false` by `Mark-AtlasInvalidRecords.ps1`, which is
  committed and idempotent.
- Tests: `Test-AtlasConditions.ps1` (the policy over 14 synthetic cases, a live capture, and the
  battery hook), `Test-AtlasHistory.ps1` (PowerShell and Python) and `Test-BenchmarkGuards.ps1` (all seven harnesses refuse on battery in about 5 s,
  and four tiny real runs record the override).
- Not yet exercised on AC power: the pass path is covered by synthetic cases, and the
  battery hook, but no harness has been run for real while plugged in under this check.

## Phase 2: committed harnesses

Each records directly to the history, replacing the hand-typed recorders.

| Harness | Replaces | Measures |
| --- | --- | --- |
| `Invoke-FoundryContextBench.ps1` | scratch prefill and stream scripts | Prefill and decode against prompt length over HTTP, stateless, UTF-8 request bodies, exact token counts from `usage`, units interleaved |
| the same, `-InProcess` | inline loops over `bench_foundry_sdk.py` | The same lengths through the SDK, fresh session per run |
| `Invoke-LlamaCppControl.ps1` | inline `llama-bench` loops | Stock llama.cpp, pinned release and SHA256 in a manifest, GPU and CPU interleaved, recorded as `control: true` |
| `Invoke-OrtGenAiBench.ps1` | the inline Python/C#/Python sequence | `bench_ort_genai.py` and the new `src/csharp/OrtBench` project, interleaved, with package versions recorded |
| `Invoke-PrefillBench.ps1` takes a list of prompt sizes | inline loops | Alternates unit order itself |
| `New-BenchPrompt` | scratch prompt files | A deterministic prompt built from repository source, to a target size, cached locally |

Known traps to build in from the start: `pwsh -File` cannot bind array parameters; a
request body must be sent as UTF-8 bytes; `max_tokens=1` fails on Foundry; a reused chat
session accumulates history; a sampler running beside the timed request lowers the rate.

**Done when:** each harness runs from a clean checkout, records, and reproduces a figure
already in BENCHMARKS within its own spread.

## History format (additive)

Measured on the current history (132 records, 96 KB, 4 stacks): forty-odd field names
have accumulated one harness at a time. `harness` is on 102 records, `statistic` on 17,
`runs` and `repetitions` mean the same thing in different records, there is no unique id,
and every record carries a local path. That is the case for fixing the format now,
before more records are written.

New optional fields: `schemaVersion`, `id` (stable hash of the identifying fields),
`kind` (`benchmark`, `control` or `smoke`), `conditions` (the phase 1 object),
`onAcPower`, `harness`, `harnessVersion`, `codeRev` (Atlas git revision and whether the
tree was dirty), `modelArtifact` (file name, size and SHA256, or the Foundry variant id;
hashes cached by path, size and mtime), `statistic`, `n`, `stdev`, `reps` (the
per-repetition values), `order`, `promptKind`, `ctxSize`, `seed`, `valid` and
`validReason`. One name each: `n`, not `runs` or `repetitions`. Readers treat a missing
field as unknown. A `-Valid` filter on `Get-AtlasBenchmarkHistory` leaves out invalid
records and those with `onAcPower: false`.

## Data and the page (proposed)

The history stays a local, append-only ledger. A **curated export**,
`docs/data/benchmarks.json`, is committed: generated by an export script that selects
valid AC records by a stated rule, strips local paths, and carries provenance (stack,
harness, conditions, `n`, spread). Pages are generated from that file, and the
hand-written narrative stays hand-written; generated tables sit between marker comments
in BENCHMARKS.md. Every generated figure shows its stack and date, so a v0.8.0 number is
visibly not a v0.9.0 number. Smoke records are never published.

Decided: generated tables first, the latest valid AC run as the published figure for a
cell (a pin list overrides it), and a backfill of the existing valid records marked as
migrated. The export script reports any cell where its choice differs from the figure now
quoted in BENCHMARKS.md, which is where stale or wrong published numbers would show up.

## Later

- **Phase 3, suite runner:** `Invoke-AtlasBenchSuite -Suite <name>` over committed
  manifests (`smoke`, `stack-compare`, `runtimes`, `longctx`, `ort`), writing a run
  folder and a summary table.
- **Phase 5, export and page:** the export script, the marker-delimited generated tables
  in BENCHMARKS.md, and the backfill migration. The schema fields they need are added in
  phase 1, so records written from then on are complete.
- **Phase 4, canary and compare:** a short fixed run compared with the AC history, and
  `Compare-AtlasBenchmarks -From <stack> -To <stack>`. Thresholds need AC data that
  mostly does not exist yet, so this waits until phases 1 to 3 have produced it.

## Not in scope

Re-benchmarking everything, changing any published figure, scheduled or unattended runs,
and rewriting the harnesses that already work.

## Details to settle while building

- Canary thresholds, once there is AC data to set them from.
