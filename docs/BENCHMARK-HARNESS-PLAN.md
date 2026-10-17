# Benchmark harness plan

**Status: phases 1 to 4 are implemented and the first AC measurements were taken on 2026-10-17 (see BENCHMARKS.md); phase 5 is a proposal.** Written 2026-10-17 after a session
in which several published numbers turned out to depend on conditions nobody had
checked. When a phase ships, its entry moves to [BENCHMARKS.md](BENCHMARKS.md) and the
README, and this file records what was decided.

## Naming (renamed 2026-10-17)

One pattern: **`<Verb>-Bench<What>`**. The verb says what kind of thing it is, the noun says what it
measures, and a script's help (`Get-Help .\Scripts\<name>.ps1`) starts with the same sentence.

| Kind | Pattern | Scripts |
| --- | --- | --- |
| Measure something | `Invoke-Bench<What>` | `Invoke-BenchDecode`, `Invoke-BenchPrefill`, `Invoke-BenchFoundry`, `Invoke-BenchFoundryContext`, `Invoke-BenchOrtGenAi`, `Invoke-BenchControl`, `Invoke-BenchPlacement`, `Invoke-BenchToolCalling` |
| Run a set, or check the machine | `Invoke-Bench<Suite or Canary>` | `Invoke-BenchSuite`, `Invoke-BenchCanary` |
| Report | `Compare-Bench...`, `Mark-Bench...` | `Compare-BenchStacks`, `Mark-BenchInvalid` |
| Support | `New-Bench...`, `Bench*.psm1` | `New-BenchPrompt`, `BenchConditions`, `BenchFoundry`, `BenchCompare`, `BenchCanary` |
| Check that the scripts work | `Test-Bench...` | `Test-BenchGuards`, `Test-BenchSuite`, `Test-BenchCompare`, `Test-BenchCanary`, `Test-BenchConditions`, `Test-BenchHistory`, `Test-BenchPrompt` |

Former names, for anything that still mentions them (old records in the history keep the old
names in `source`; `Compare-BenchStacks` treats a former name and its current one as the same cell):

| Was | Is |
| --- | --- |
| `Invoke-Benchmark` | `Invoke-BenchDecode` |
| `Invoke-PrefillBench` | `Invoke-BenchPrefill` |
| `Invoke-FoundryBench` | `Invoke-BenchFoundry` |
| `Invoke-FoundryContextBench` | `Invoke-BenchFoundryContext` |
| `Invoke-LlamaCppControl` (and `llamacpp-control.json`, step `llamacpp-control`) | `Invoke-BenchControl` (`bench-control.json`, step `control`) |
| `Invoke-OrtGenAiBench` | `Invoke-BenchOrtGenAi` |
| `Invoke-AtlasCanary` | `Invoke-BenchCanary` |
| `Invoke-AtlasBenchSuite` | `Invoke-BenchSuite` |
| `Compare-AtlasBenchmarks` | `Compare-BenchStacks` |
| `Mark-AtlasInvalidRecords` | `Mark-BenchInvalid` |
| `Test-ComputeUnits` | `Invoke-BenchPlacement` (it measures, it does not test the code) |
| `Test-ToolCalling` | `Invoke-BenchToolCalling` |
| `Test-BenchmarkGuards`, `Test-AtlasCanary`, `Test-AtlasCompare`, `Test-AtlasConditions`, `Test-AtlasHistory` | `Test-BenchGuards`, `Test-BenchCanary`, `Test-BenchCompare`, `Test-BenchConditions`, `Test-BenchHistory` |
| `AtlasConditions.psm1`, `AtlasCanary.psm1`, `AtlasCompare.psm1`, `AtlasFoundry.psm1` | `BenchConditions.psm1`, `BenchCanary.psm1`, `BenchCompare.psm1`, `BenchFoundry.psm1` |

Not renamed: the functions inside the modules (`Get-AtlasBenchmarkHistory`, `Add-AtlasBenchmarkRecord`,
`Assert-AtlasConditions`, ...), `AtlasBaseline.psm1` (stack identity and baseline, which are not
benchmark-specific), `Update-Workspace.ps1` and the setup scripts, and the Python harnesses, which
already follow the pattern (`bench_foundry_sdk.py`, `bench_ort_genai.py`). Scripts are still in
`Scripts/`; grouping them into a folder is a separate step.

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
| Canary | Phase 4 (built, thresholds provisional): warn below about 85 % of the AC reference, abort below about 60 % unless overridden |
| History format | **Additive**: new fields, old records stay valid and read as "unknown" |
| C# benchmark mode | **Its own project**, `src/csharp/OrtBench`; `GenAiProbe` stays a smoke probe |
| Foundry loaded-model check | Run `foundry server status` first. Only if the daemon is up, `foundry model list --loaded`. **Never start it, and never stop one we did not start.** Checked on this machine: `status` has no side effect, `foundry cache ls` starts the daemon, and a stopped daemon holds no models |
| Run folders | `.atlas-local/benchmarks/runs/`, git-ignored |
| Page form | **Generated tables in BENCHMARKS.md first**; an HTML page with charts can be built from the same JSON later |
| The published figure for a cell | **The latest valid AC run**, with a small pin list that overrides it when an older run is the right one |
| Existing records | **Backfill** the valid ones into the new format, flagged `schemaVersion: "1-migrated"`, with fields that were never recorded left null |

## Phase 1: conditions check (done)

A PowerShell module, `Scripts/BenchConditions.psm1`, used by every harness. Python
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

- `Scripts/BenchConditions.psm1` and the history format fields, as planned. Checked live
  against a Foundry daemon with a model loaded on the NPU and a running `geniex serve`.
- `#requires -Version 7` is on the harness scripts, `Update-Workspace.ps1` and the tests,
  **not** on the four bootstrap scripts: `Install-Prerequisites.ps1` does not install
  PowerShell 7, so they must run on a stock machine.
- `Update-Workspace.ps1` records its conditions and never refuses (`-WarnOnly`), because
  refusing would block the update its smoke check is verifying.
- `bench_foundry_sdk.py` does not expect the Foundry daemon: it needs the NPU for itself, so
  a daemon holding a model there blocks it. (A daemon holding the same model during the one
  464 s in-process load is a candidate cause; that is not established.) `Invoke-BenchFoundry.ps1`
  talks to the daemon and does expect it.
- Two test-only hooks were added: `ATLAS_HISTORY_PATH` redirects the history, and
  `ATLAS_TEST_ON_BATTERY` makes the check report battery, so the refusal can be tested
  plugged in.
- Six existing records are marked `valid: false` by `Mark-BenchInvalid.ps1`, which is
  committed and idempotent.
- Tests: `Test-BenchConditions.ps1` (the policy over 14 synthetic cases, a live capture, and the
  battery hook), `Test-BenchHistory.ps1` (PowerShell and Python) and `Test-BenchGuards.ps1` (all seven harnesses refuse on battery in about 5 s,
  and four tiny real runs record the override).
- Not yet exercised on AC power: the pass path is covered by synthetic cases, and the
  battery hook, but no harness has been run for real while plugged in under this check.

## Phase 2: committed harnesses (built; unverified on AC power)

Each records directly to the history, replacing the hand-typed recorders.

| Harness | Replaces | Measures |
| --- | --- | --- |
| `Invoke-BenchFoundryContext.ps1` | scratch prefill and stream scripts | Prefill and decode against prompt length over HTTP, stateless, UTF-8 request bodies, exact token counts from `usage`, units interleaved |
| the same, `-InProcess` | inline loops over `bench_foundry_sdk.py` | The same lengths through the SDK, fresh session per run |
| `Invoke-BenchControl.ps1` | inline `llama-bench` loops | Stock llama.cpp, pinned release and SHA256 in a manifest, GPU and CPU interleaved, recorded as `control: true` |
| `Invoke-BenchOrtGenAi.ps1` | the inline Python/C#/Python sequence | `bench_ort_genai.py` and the new `src/csharp/OrtBench` project, interleaved, with package versions recorded |
| `Invoke-BenchPrefill.ps1` takes a list of prompt sizes | inline loops | Alternates unit order itself |
| `New-BenchPrompt` | scratch prompt files | A deterministic prompt built from repository source, to a target size, cached locally |

Known traps to build in from the start: `pwsh -File` cannot bind array parameters; a
request body must be sent as UTF-8 bytes; `max_tokens=1` fails on Foundry; a reused chat
session accumulates history; a sampler running beside the timed request lowers the rate.

**Done when:** each harness runs from a clean checkout, records, and reproduces a figure
already in BENCHMARKS within its own spread.

**What shipped, and what has not been checked.**

- All six items exist and have been run, on battery with `-AllowBattery`, as tiny checks that
  recorded to a temporary history: `New-BenchPrompt.ps1` (with `Test-BenchPrompt.ps1`),
  `Invoke-BenchPrefill.ps1` with a size list, `Invoke-BenchFoundryContext.ps1` over HTTP and
  `-InProcess`, `Invoke-BenchControl.ps1` (on a supplied build), and
  `Invoke-BenchOrtGenAi.ps1` with the `OrtBench` project. `Test-BenchGuards.ps1` covers
  their refusal on battery.
- **"Reproduces a figure already in BENCHMARKS" has not been checked for any of them.** That
  needs AC power and the full-size models, and the plan's own definition of done depends on it.
- The llama.cpp control's `-Download` path has **not** been run (it fetches a release zip and
  needs the user's go-ahead). Its manifest SHA256 is the one recorded for the original run.
- Differences from the plan: the Foundry context bench takes prefill from the streamed request's
  first-token time rather than a separate non-streamed request (a small `max_tokens` fails in
  `GroupQueryAttention`, which the separate request needed); `New-BenchPrompt.ps1` reads text
  from a pinned git revision, so a prompt does not change when the docs do; the control and the
  ORT script are `Invoke-*` scripts that call llama-bench and OrtBench, not new engines.
- Found on the way: on `qwen2.5-0.5b` (NPU), a `max_tokens` of 8 failed with a 1,408-token prompt
  and 16 failed with a 49-token one, and the daemon stopped answering after a failure. Not
  explained; the README open question about `max_tokens` already covers it.

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

- **Phase 3, suite runner (built):** `Invoke-BenchSuite.ps1 -Suite <name>` over committed
  manifests in `Scripts/suites/` (`smoke`, `stack-compare`, `runtimes`, `longctx`, `ort`),
  writing a run folder and a summary table.

  - Each step runs in its own `pwsh` process (array arguments bind there, and state cannot
    leak); the conditions are checked once up front, and each step checks again.
  - A failed step does not stop the rest unless `-StopOnError`; exit 4 means "prerequisite
    absent" and is reported as skipped (the llama.cpp control uses it).
  - The run folder is `.atlas-local/benchmarks/runs/<time>-<suite>/`: `suite.json`,
    `steps.json`, `records.jsonl`, `logs/<id>.log`, `summary.md`. Records carry `suiteRun`.
  - Tested with stub steps (`Test-BenchSuite.ps1`), and `smoke` was run for real on battery
    (both steps ok, six records, about a minute). **`stack-compare`, `runtimes`, `longctx` and
    `ort` have only been dry-run**, so their time estimates are guesses and the full-size model
    arguments in them have not been exercised through the runner. `longctx` relies on its HTTP
    step running before the in-process step, for the exact prompt lengths.
  - Not built: a `-Set key=value` override of a step's arguments (edit the manifest or run the
    script directly), and the comparison of two suite runs (that is `Compare-BenchStacks.ps1`, below).
- **Phase 5, export and page:** the export script, the marker-delimited generated tables
  in BENCHMARKS.md, and the backfill migration. The schema fields they need are added in
  phase 1, so records written from then on are complete.
- **Phase 4, canary and compare (built):**
  - `Compare-BenchStacks.ps1` (rules in `BenchCompare.psm1`) compares two stacks cell by
    cell. Checked against the real history, where it reproduces the hand-built v0.8.0 to v0.9.0
    findings (control held; 30B GPU decode -39.7 %; 30B NPU first token 13.9 to 0.35 s). It
    adds a `noisy` verdict where a stack's own records disagree by half the mean or more
    (several first-token cells did, where an earlier lazy-mapping artifact had been recorded).
  - `Invoke-BenchCanary.ps1` (rules in `BenchCanary.psm1`) runs the pinned llama.cpp on
    Qwen3-0.6B (CPU and GPU, 256-token prompt, 32 generated, two rounds) and compares with the
    median of the last five healthy AC canary runs. The suite runner runs it before and after
    the steps; abort stops the suite (exit 11), warn adds a caveat.
  - **The thresholds are not data-driven.** The plan said to wait for AC data; there is none (no
    record in the history has `onAcPower: true`), so 0.85 and 0.60 are provisional values chosen
    from the failures seen (a 3x slowdown on battery, a half-speed state) and the 3 to 7 %
    spread of the controls. Until three healthy AC canary runs exist the verdict is
    `no-reference` and nothing is gated, so the canary currently only records.
  - Tested over synthetic records, and the canary script for real against llama-bench with
    a seeded history (no-reference; abort against an inflated reference; ok against a tiny one).
    Not tested: a canary on AC power building its own reference, or a genuine abort.
  - The canary needs the pinned build unpacked, which needs `Invoke-BenchControl.ps1
    -Download` (not run). Without it the canary is unavailable.
  - **Update 2026-10-17, first AC data.** The pinned build was downloaded and the suites run on AC power
    (`stack-compare`, the `genie-30b` step of `longctx`, `ort`). The canary now has a reference (six healthy
    runs). Twelve readings gave spreads of GPU decode 4 %, CPU prefill 19 %, GPU prefill 29 % and CPU decode
    37 %, so CPU decode became information only and the rest gate; 85 % and 60 % stay provisional, with
    little margin on prefill. The measured suite times were far below the guessed ones (`stack-compare` 10
    minutes against 38), and the manifests were updated. The AC results contradicted several published
    figures, the largest being the 30B's GPU decode on GenieX v0.9.0 (31.6 tok/s, not 17.4): see
    BENCHMARKS.md, 'First measurements on AC power'. Still to do: `runtimes` and the Foundry steps of
    `longctx` at full size, and v0.8.0 on AC for a like-for-like version comparison.

## Not in scope

Re-benchmarking everything, changing any published figure, scheduled or unattended runs,
and rewriting the harnesses that already work.

## Details to settle while building

- Canary thresholds, once there is AC data to set them from.
