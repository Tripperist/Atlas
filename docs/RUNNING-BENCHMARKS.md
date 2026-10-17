# Running, reporting and comparing benchmarks

How to run the Atlas benchmarks, read what they show, and compare two runs. The
results themselves, and what they mean, are in [BENCHMARKS.md](BENCHMARKS.md); this
guide is the instructions.

Everything here runs from the repository root on the Snapdragon X2 Elite machine,
in PowerShell 7.

**Contents**

1. [What the benchmarks show](#1-what-the-benchmarks-show)
2. [Before you run anything](#2-before-you-run-anything)
3. [A first run, in order](#3-a-first-run-in-order)
4. [The scripts](#4-the-scripts)
5. [Suites: running several at once](#5-suites-running-several-at-once)
6. [The conditions check](#6-the-conditions-check)
7. [Reporting: where results go](#7-reporting-where-results-go)
8. [Comparing two stacks](#8-comparing-two-stacks)
9. [Reading a result: what to trust](#9-reading-a-result-what-to-trust)
10. [When something goes wrong](#10-when-something-goes-wrong)
11. [Adding a benchmark](#11-adding-a-benchmark)
12. [Former script names](#12-former-script-names)

---

> **Status of the tooling (2026-10-17): what has actually been run.**
>
> - **Run for real on AC power:** the `stack-compare` suite (about 10 minutes, against a guessed 38), the
>   `genie-30b` step of `longctx` (7 minutes), the `ort` suite (4 minutes when the machine is healthy, 9 when it
>   was not), the C# `OrtBench` against `onnxruntime-qnn` 2.6.0 and 2.7.0, the canary six times, and the
>   `smoke` suite. The results are in
>   [BENCHMARKS.md](BENCHMARKS.md#first-measurements-on-ac-power-2026-10-17).
> - **Run only as tiny checks, or on battery:** the Foundry scripts, `Invoke-BenchPlacement` and
>   `Invoke-BenchToolCalling` (the last two not since they were renamed).
> - **Never run at full size:** the `runtimes` suite, the `longctx` Foundry steps (7B over HTTP and in process).
>   Their time estimates are guesses.
> - **The canary now has a reference** (six healthy AC runs). CPU decode is information only because it moved
>   about 37 % between healthy runs; the 85 % and 60 % lines are still provisional and have little margin on
>   the prefill figures.
> - **No published table from before 2026-10-17 has been reproduced as it stood.** The re-measurements on AC
>   differ from several of them, in places by a lot (the 30B's GPU decode on GenieX v0.9.0).

## 1. What the benchmarks show

A local language model is used in two phases, and they behave differently:

- **Prefill** reads the prompt. It is measured in prompt tokens per second. A long
  prompt (retrieved documents, a code file) is mostly prefill, so for that work
  prefill speed sets how long you wait for the first word.
- **Decode** writes the answer one token at a time. It is measured in generated
  tokens per second, and it is what you feel while the answer streams.

The first token arrives after prefill, so **first-token time** is the prompt length
divided by the prefill rate, plus a little.

Every benchmark answers one of these questions:

| Question | Measured by |
| --- | --- |
| How fast does a model write, on the CPU, GPU and NPU? | [`Invoke-BenchDecode`](#invoke-benchdecode) |
| How fast does it read a prompt, and how does that change with prompt length? | [`Invoke-BenchPrefill`](#invoke-benchprefill) (GenieX), [`Invoke-BenchFoundryContext`](#invoke-benchfoundrycontext) (Foundry) |
| How do the three runtimes compare: GenieX, Foundry Local, ONNX Runtime GenAI? | [`Invoke-BenchFoundry`](#invoke-benchfoundry), [`Invoke-BenchOrtGenAi`](#invoke-benchortgenai), and the suite `runtimes` |
| Is the NPU actually doing the work? | [`Invoke-BenchPlacement`](#invoke-benchplacement), [`Invoke-BenchToolCalling`](#invoke-benchtoolcalling) |
| Did something change after an update? | [`Invoke-BenchSuite`](#5-suites-running-several-at-once) then [`Compare-BenchStacks`](#8-comparing-two-stacks) |
| Is the machine in its normal state right now? | [`Invoke-BenchCanary`](#invoke-benchcanary), [`Invoke-BenchControl`](#invoke-benchcontrol) |

Three words are used throughout:

- **Compute unit:** the CPU, the GPU (Adreno) or the NPU (Hexagon). The NPU is the point of
  this repository; the other two are what it is compared against.
- **Stack:** the exact software a result was measured on: the drivers, GenieX and its
  llama.cpp, Foundry, the ONNX Runtime packages. Every result is stamped with a stack id (a
  short hash), so a result from one GenieX version is visibly not a result from another.
- **Control:** a measurement of something that should not have changed (the unmodified,
  pinned llama.cpp). If a control moves between two runs, the machine changed, not the software.

## 2. Before you run anything

- **PowerShell 7** (`pwsh`). The scripts refuse to start under Windows PowerShell 5.1 and say
  so. A parameter that takes a list (`-Compute cpu,gpu`) does not bind under `pwsh -File`, so
  from a shell write `pwsh -Command "& .\Scripts\Invoke-BenchDecode.ps1 -Compute cpu,gpu"`.
  From inside PowerShell 7 it just works.
- **The workspace works:** `.\Scripts\Test-Environment.ps1` passes and `uv sync` has been run
  ([README, shared setup](../README.md#4-shared-setup)).
- **`gh`** (the GitHub CLI) is installed and signed in. `Invoke-BenchPrefill` fetches
  `geniex-bench` through it.
- **The models are present.** GenieX: `geniex pull <model>` (`geniex list` shows what is cached).
  Foundry: `foundry model download <alias>`. ONNX Runtime GenAI: the `hf download` command the
  script prints when the bundle is missing.
- **Plugged in, and nothing else busy.** On battery the same code ran at roughly a third of its
  speed or worse (two single-run smoke checks of a 0.5B model on Foundry: 24 tok/s on battery, 92 on AC). The scripts check
  this and refuse; see [the conditions check](#6-the-conditions-check). Close browsers too:
  ONNX Runtime GenAI lost more than half its speed to about 1.35 cores of background load.
- **One time:** `.\Scripts\Invoke-BenchControl.ps1 -Download` fetches the pinned stock llama.cpp
  (a release zip, checked against a SHA256 in `Scripts/bench-control.json`; nothing is installed).
  The control and the canary need it. Without it they report themselves unavailable.

## 3. A first run, in order

```powershell
.\Scripts\Test-Environment.ps1                               # the machine and the workspace
.\Scripts\Invoke-BenchSuite.ps1 -Suite smoke                 # about 2 minutes: do the harnesses run?
.\Scripts\Invoke-BenchControl.ps1 -Download                  # once: the pinned llama.cpp
.\Scripts\Invoke-BenchSuite.ps1 -Suite stack-compare -DryRun # what the real run will do
.\Scripts\Invoke-BenchSuite.ps1 -Suite stack-compare         # about 10 minutes; the canary runs first
.\Scripts\Compare-BenchStacks.ps1 -List                      # the stacks that now have results
```

The `smoke` suite is not a result: it uses small models to prove everything runs. A real
measurement starts with `stack-compare`.

After a stack change (a GenieX, Foundry or package update), the order is:
`.\Scripts\Update-Workspace.ps1 -Apply`, then `-Accept` once it verifies, then the `stack-compare`
suite, then `.\Scripts\Compare-BenchStacks.ps1` to see what moved
([README section 11](../README.md#11-keeping-the-workspace-current) covers updating).

## 4. The scripts

Names follow one pattern, **`<Verb>-Bench<What>`**: `Invoke-Bench…` measures or runs something,
`Compare-Bench…` and `Mark-Bench…` report, `New-Bench…` builds an input, and `Test-Bench…`
checks that the benchmark code itself works. `Get-Help .\Scripts\<name>.ps1 -Full` shows a
script's own documentation.

| Script | Answers | Typical time | Writes to the history |
| --- | --- | --- | --- |
| [`Invoke-BenchDecode`](#invoke-benchdecode) | How fast does a model write, per compute unit? | minutes | yes |
| [`Invoke-BenchPrefill`](#invoke-benchprefill) | How fast does GenieX read a prompt, and does it slow with length? | 3 min (the matrix) to 7 min (the 30B, three lengths) | yes |
| [`Invoke-BenchFoundry`](#invoke-benchfoundry) | Foundry Local speed, and is it on the NPU? | minutes | yes |
| [`Invoke-BenchFoundryContext`](#invoke-benchfoundrycontext) | Foundry speed against prompt length, over HTTP or in process | 5 to 20 min | yes |
| [`Invoke-BenchOrtGenAi`](#invoke-benchortgenai) | ONNX Runtime GenAI from Python and C# | about 4 min | yes |
| [`Invoke-BenchControl`](#invoke-benchcontrol) | What does unmodified llama.cpp give on this machine? | about 2 min (the 30B) | yes (kind `control`) |
| [`Invoke-BenchCanary`](#invoke-benchcanary) | Is the machine in its normal state? | about a minute | yes (kind `canary`) |
| [`Invoke-BenchPlacement`](#invoke-benchplacement) | Does the compute-unit flag change where the work runs? | minutes | no |
| [`Invoke-BenchToolCalling`](#invoke-benchtoolcalling) | Does a Foundry model call tools, and stay on the NPU doing so? | a couple of minutes | no |
| [`Invoke-BenchSuite`](#5-suites-running-several-at-once) | Run a named set of the above | 2 to about 40 min | via its steps |
| [`Compare-BenchStacks`](#8-comparing-two-stacks) | What moved between two stacks? | seconds | reads it |
| [`Mark-BenchInvalid`](#mark-benchinvalid) | Flag records known not to be comparable | seconds | edits it |
| [`New-BenchPrompt`](#new-benchprompt) | Build a long prompt of a known size | seconds | no |

The times are rough, from runs on one machine.

### Invoke-BenchDecode

**Question:** how fast does a GenieX model write, and which compute unit is it using?

```powershell
.\Scripts\Invoke-BenchDecode.ps1 -Model 'unsloth/Qwen3-4B-GGUF:Q4_0' -Repeat 3
```

Runs `geniex infer` from a short prompt on the CPU, GPU and NPU in rotation (the order reverses on
alternate rounds, so thermal drift is not one unit's), sampling CPU, GPU and NPU utilization during
each run. A short prompt means prefill is negligible and the figure is decode speed.

- **Output:** a table of tokens per second, first-token time and startup per compute unit, with
  CPU percentage and the NPU and GPU peaks; a CSV in `.atlas-local/benchmarks/`.
- **Read it:** the NPU row should show an NPU peak near 100 % and the CPU and GPU rows near 0 %; that
  is the evidence the work ran where it says. Decode alone understates the NPU, whose advantage is
  prefill, so read it with [`Invoke-BenchPrefill`](#invoke-benchprefill).
- **Options:** `-Compute cpu,gpu,npu,hybrid`, `-MaxTokens`, `-Repeat` (3 or more; thermals move
  these numbers), `-NoUtilization` (timing only; the sampler competes for the CPU and can lower the
  rate), `-PowerMode`.
- **Without `-Model`** it uses the first model `geniex list` shows.

### Invoke-BenchPrefill

**Question:** how fast does GenieX read a prompt, and how does that change as the prompt grows?

```powershell
.\Scripts\Invoke-BenchPrefill.ps1 -Matrix                          # the standard comparison table
.\Scripts\Invoke-BenchPrefill.ps1 -Model 'unsloth/Qwen3-4B-GGUF:Q4_0' -Device npu
pwsh -Command "& .\Scripts\Invoke-BenchPrefill.ps1 -Device gpu,npu -PromptTokens 512,2048,8192 -CtxSize 10240"
```

Drives `geniex-bench`, which reports prefill and decode separately for a prompt of a fixed
length. It fetches the `geniex-bench` build matching the installed GenieX version and verifies
its SHA256, so a v0.7.0 harness is never run against a v0.8.0 runtime.

- **Output:** per model, engine and device: first-token time (ms), prefill tok/s and decode tok/s.
  With several `-PromptTokens` sizes, one row per size.
- **Read it:** prefill is where the NPU leads (several times the CPU and GPU); decode is where it is
  closest. With several sizes, watch how prefill falls as the prompt grows.
- **Options:** `-Matrix` (the standard set: both GenieX engines on Qwen3-4B, and Phi-4-mini);
  `-PromptTokens` takes a list and the unit order reverses on alternate sizes; `-CtxSize` sets the
  context window and must cover the longest prompt plus `-GenTokens` (the script refuses
  otherwise); `-Plugin llama_cpp|qairt`; `-Repeat`.

### Invoke-BenchFoundry

**Question:** how fast is Foundry Local, and is it on the NPU?

```powershell
.\Scripts\Invoke-BenchFoundry.ps1 -Model qwen2.5-0.5b -Repeat 3
```

Drives Foundry's OpenAI-compatible HTTP endpoint. Each run is timed on a request with nothing
else running; a second request, with a utilization sampler, shows where the work ran (the sampler
lowers throughput, so its rate is reported separately and not relied on).

- **Output:** tokens per second per run, and NPU and CPU utilization from the placement request.
- **Read it:** the timed rate is the speed; the NPU peak is the placement evidence.
- **It leaves the model loaded and the daemon running.** The next NPU benchmark will refuse
  because of that; run `foundry model unload <alias>` first (the refusal tells you).

### Invoke-BenchFoundryContext

**Question:** how does Foundry's speed change with prompt length, and does the route (HTTP or the
in-process SDK) matter?

```powershell
pwsh -Command "& .\Scripts\Invoke-BenchFoundryContext.ps1 -Model qwen2.5-coder-7b -PromptTokens 512,2048,4096,6784"
pwsh -Command "& .\Scripts\Invoke-BenchFoundryContext.ps1 -Model qwen2.5-coder-7b -PromptTokens 512,2048,4096,6784 -InProcess"
```

For each prompt size and model, one stateless streamed request gives the first-token time, the
**exact** prompt length (from the server's usage block), prefill tok/s (that length over the
first-token time) and decode tok/s. The prompt comes from [`New-BenchPrompt`](#new-benchprompt), so it
can be rebuilt byte for byte. `-InProcess` runs the same prompts through the Python SDK; it takes
the exact lengths from an earlier HTTP run, so run the HTTP route first.

- **Output:** one line per size and model: prompt tokens, prefill, first token, decode.
- **Read it:** prefill and decode both fall as the prompt grows; the figure that matters for a
  long-prompt workload is the one at your prompt length, not the 512-token one.
- **Options:** `-Model` takes several aliases, and `alias@npu`, `alias@gpu` or `alias@cpu` selects a
  hardware variant over HTTP. `-MaxTokens` must be 64 or more: a smaller value fails inside
  Foundry. It loads only the models it needs, unloads only the ones it loaded, and stops the daemon
  only if it started it.

### Invoke-BenchOrtGenAi

**Question:** how fast is ONNX Runtime GenAI, from Python and from C#, and did a package change
slow it?

```powershell
.\Scripts\Invoke-BenchOrtGenAi.ps1 -Rounds 3
pwsh -Command "& .\Scripts\Invoke-BenchOrtGenAi.ps1 -Runtime csharp -Rounds 3 -QnnVersion 2.7.0"
```

Runs `bench_ort_genai.py` (Python) and the [`OrtBench`](../src/csharp/OrtBench) C# project on the same
model with the same method (a fixed-length prompt of random token ids, prefill and decode timed
apart), interleaved, the order alternating by round.

- **Output:** per round and runtime: prefill, decode and first-token time; then a summary per runtime.
- **Read it:** compare the runtimes only within one run. **By default the two sides use different
  `onnxruntime-qnn` versions** (Python the virtual environment's, C# the project's pin), and every
  record says which; `-QnnVersion` builds the C# side against another (NuGet downloads it if it is
  not cached).
- **Options:** `-Runtime python,csharp`, `-Rounds`, `-NPrompt`, `-NGen`, `-Repetitions`, `-CpuOnly`.

### Invoke-BenchControl

**Question:** what does unmodified upstream llama.cpp give on this machine, for comparison with
GenieX's build?

```powershell
.\Scripts\Invoke-BenchControl.ps1 -Download           # first time: fetch the pinned build
.\Scripts\Invoke-BenchControl.ps1                      # the 30B coder model, 3 interleaved rounds
```

Runs the pinned stock `llama-bench` (release and SHA256 in `Scripts/bench-control.json`) on the GPU
and CPU, rounds alternating order. Nothing is downloaded without `-Download`, and a hash mismatch is
refused. `-LlamaBenchPath` uses a build you already unpacked (the record says it was supplied).

- **Output:** prefill and decode tok/s per round and unit, then a summary with the range.
- **Read it:** a control is for comparison. If it is steady between two runs, the machine was in the
  same state and a change in a GenieX or Foundry figure is the software. If it moved, nothing else
  can be trusted. It is recorded as kind `control`.

### Invoke-BenchCanary

**Question:** is the machine in the state earlier AC runs measured, right now?

```powershell
.\Scripts\Invoke-BenchCanary.ps1
```

A half-minute fixed run of the pinned llama.cpp on Qwen3-0.6B, CPU and GPU. It is compared with
the median of the last five healthy AC canary runs:

| Verdict | Meaning | Exit code |
| --- | --- | --- |
| `ok` | at or above 85 % of the reference | 0 |
| `warn` | below 85 %: carry on, but caveat the figures | 10 |
| `abort` | below 60 %: do not benchmark now | 11 |
| `no-reference` | fewer than three earlier AC runs: recorded, nothing gated | 0 |
| (unavailable) | the pinned build is not unpacked | 4 |

**CPU decode is shown but does not count.** It moved about 37 % between healthy runs (127 to 187 tok/s on the
0.6B model), where GPU decode moved 4 %, so GPU prefill, GPU decode and CPU prefill decide the verdict.

**The 85 % and 60 % lines are provisional.** They were chosen before there was any AC data, and the first
12 AC readings show little margin on the prefill figures (their lowest readings were about 90 % of their
means). A reference exists from three healthy AC runs; until then the verdict is `no-reference`, which
records and gates nothing. [`Invoke-BenchSuite`](#5-suites-running-several-at-once) runs it before
and after its steps.

### Invoke-BenchPlacement

**Question:** does the compute-unit flag change where the work actually runs?

```powershell
pwsh -Command "& .\Scripts\Invoke-BenchPlacement.ps1 -Model 'unsloth/Qwen3-0.6B-GGUF:Q4_0' -Compute cpu,gpu,npu"
```

A quick three-way sanity check: the same prompt, token budget and seed on each unit. If `-Compute
cpu` and `-Compute npu` give the same throughput, the flag is not moving the work. Prints a table;
it does not write to the history. (`--compute` steers the llama.cpp engine; QAIRT bundles are
NPU-only by construction, so it may be ignored for them.)

### Invoke-BenchToolCalling

**Question:** does a Foundry model emit tool calls, and does it stay on the NPU while it does?

```powershell
.\Scripts\Invoke-BenchToolCalling.ps1 -Model qwen2.5-0.5b
```

Drives three conditions for a fixed window each: a length-matched plain control, `tool_choice=auto`
and `tool_choice=required`, with NPU utilization sampled throughout. Exits non-zero if the model
does not return tool calls. It prints the result; it does not write to the history.

### Mark-BenchInvalid

```powershell
.\Scripts\Mark-BenchInvalid.ps1 -DryRun     # what it would mark
.\Scripts\Mark-BenchInvalid.ps1             # mark them, after writing a backup
```

Flags records that carry a free-text `note` or were measured on battery as `valid: false`, so
[`Get-AtlasBenchmarkHistory -Valid`](#7-reporting-where-results-go) and the comparison leave them
out. It is the one thing that rewrites the history; it rewrites only the lines it changes and writes
a timestamped backup first. Running it again marks nothing.

### New-BenchPrompt

```powershell
(.\Scripts\New-BenchPrompt.ps1 -Tokens 4096).Path
```

Builds a long prompt of about the requested size from text pinned to a git revision (not the working
tree), so the same size always gives the same bytes, and caches it with a SHA256. The size is a
target: the real token count differs by several percent between tokenizers, and the benchmarks that can report it
(Foundry's usage block) do.

## 5. Suites: running several at once

A suite is a list of the scripts above, with their arguments, in `Scripts/suites/<name>.json`.
Committing it means "the stack-compare numbers" is a command, not a recollection.

| Suite | For | About |
| --- | --- | --- |
| `smoke` | Proving the harnesses run end to end on small models | 2 min |
| `stack-compare` | After a stack change: the prefill matrix, short-prompt decode, the llama.cpp control, ONNX Runtime GenAI | about 10 min (measured) |
| `runtimes` | GenieX, Foundry and ONNX Runtime GenAI side by side at 512 tokens | about 13 min (the Foundry step is a guess) |
| `longctx` | Prefill and decode from 512 to 6,784 tokens: GenieX 30B, Foundry 7B | about 40 min (the 30B step took 7; the Foundry steps are guesses) |
| `ort` | ONNX Runtime GenAI from Python and C#, after an `onnxruntime` package change | about 4 min (measured) |

```powershell
.\Scripts\Invoke-BenchSuite.ps1 -List
.\Scripts\Invoke-BenchSuite.ps1 -Suite stack-compare -DryRun      # the steps and exact commands
.\Scripts\Invoke-BenchSuite.ps1 -Suite stack-compare
pwsh -Command "& .\Scripts\Invoke-BenchSuite.ps1 -Suite longctx -Skip foundry-7b-inprocess"
```

- **The conditions are checked once, up front**, and a suite on battery stops before anything loads.
- **The canary runs before the first step and after the last** (skipped by `-NoCanary` and by `smoke`).
  `ok` and `no-reference` go on; `warn` goes on with a caveat in the summary; `abort` stops the suite
  (exit 11) unless `-IgnoreCanary`.
- **Each step runs in its own process.** A failed step is reported and the rest still run
  (`-StopOnError` stops). A step that exits 4 (a prerequisite is missing, such as the llama.cpp build)
  is reported as skipped.
- **`-Only` and `-Skip`** select steps by id (`-DryRun` lists them).
- **The run folder**, `.atlas-local/benchmarks/runs/<time>-<suite>/`, holds `suite.json` (the manifest
  as run, the stack, the code revision, the conditions), `steps.json`, `canary.json`, `records.jsonl`,
  a log per step and **`summary.md`**, the table to read first. The records also go to the history,
  tagged `suiteRun`.

## 6. The conditions check

A benchmark figure depends on more than the software. Every script checks, before it loads anything,
and records what it found with the result:

| Condition | What happens |
| --- | --- |
| On battery | **Refused.** `-AllowBattery` (`--allow-battery` for Python) runs anyway; the result is recorded `onAcPower: false` and kept out of published figures |
| A run that needs the NPU, and another process may hold it (`geniex`, `llama-*`, `atlas-chat`, or a Foundry model loaded on the NPU) | **Refused**, naming the process |
| A busy CPU, a background process using more than about 0.3 core | A warning |

The reason is measured. An ONNX Runtime GenAI run on battery looked like a 3x regression from a package
upgrade, and an unchanged control on the older package fell by the same factor. A Foundry model left
loaded on the NPU, and a utilization sampler competing for the CPU, each produced a plausible wrong
figure earlier.

The check looks at Windows' power state, the power scheme (recorded: `Balanced` here), CPU load and the
processes above. It does not start the Foundry daemon to look (asking `foundry cache ls` starts it).
`Update-Workspace.ps1`'s own smoke check runs warn-only, because refusing would block the update it is
there to verify.

## 7. Reporting: where results go

Every benchmark appends to `.atlas-local/benchmarks/history.jsonl`: one JSON record per line, git-ignored
and local to the machine, written by the scripts and never edited except by
[`Mark-BenchInvalid`](#mark-benchinvalid). A record carries the figures and what produced them:

- **What:** model, compute unit, prompt tokens, the figures (`tokPerSec`, `prefillTps`, `firstTokenS`), and
  `n`, `stdev` and `reps` where several repetitions were taken.
- **On what:** the stack (drivers, GenieX and llama.cpp, Foundry, ONNX Runtime packages), the Atlas code
  revision (`+dirty` if the scripts had uncommitted changes), the harness and its version.
- **Under what:** `onAcPower`, the power scheme and the other conditions, the order the units were run in,
  the prompt's SHA256 where there is one.
- **`kind`:** `benchmark`, `control`, `canary` or `smoke`; **`valid`**, false for a record known not to be
  comparable; **`suiteRun`**, the run folder it came from.

```powershell
.\Scripts\Update-Workspace.ps1 -History                 # the history grouped by stack
Import-Module .\Scripts\AtlasBaseline.psm1
Get-AtlasBenchmarkHistory -Valid                        # without invalid records and battery runs
Get-AtlasBenchmarkHistory -Kind control                 # one kind
Get-AtlasBenchmarkHistory -Valid | Where-Object model -like '*Coder-30B*' | Format-Table ts, compute, promptTokens, tokPerSec, prefillTps
```

The published tables in [BENCHMARKS.md](BENCHMARKS.md) are written by hand from these results; each names
what produced it. Records from before the conditions check existed have no recorded power state, and read as
unknown.

## 8. Comparing two stacks

```powershell
.\Scripts\Compare-BenchStacks.ps1 -List                       # the stacks that have records
.\Scripts\Compare-BenchStacks.ps1                             # the previous stack against the current one
.\Scripts\Compare-BenchStacks.ps1 -From 44a1e6e -To af42e97   # two named stacks
.\Scripts\Compare-BenchStacks.ps1 -From 44a1e6e -To af42e97 -Markdown   # a table to paste into a document
```

It pairs every cell (model, compute unit, prompt length, measuring script) measured on both stacks and shows
the figure on each, the change, and a verdict. The rules:

- **Which record stands for a cell:** never one measured on battery, never one marked invalid; AC power is
  preferred over "not recorded"; the latest of its kind wins.
- **Verdicts:** `same` (a change under 10 %, adjustable with `-Threshold`); `better` or `worse` (lower is
  better for first-token time); `within noise` (the change is smaller than twice the spread among that
  stack's own records for the cell); `noisy` (those records disagree by half their mean or more, so no change
  can be read from them).
- **The control comes first.** If it held, "the machine looks to have been in the same state". If it moved,
  the output says so in capitals: read nothing else as the software.
- **It says what it could not compare:** cells on one stack only are counted, not listed. `-All` lists the
  `same` rows too, `-IncludeBattery` admits battery records (marked), `-PassThru` returns the rows as objects.
- **The `Power` column** shows each side's power state: `AC`, `battery`, or `?` (not recorded, true of every
  record before the conditions check).

Example, on the real history: GenieX v0.8.0 against v0.9.0. The control held (4 figures within 10 %); the 30B
GPU decode fell from 28.9 to 17.4 tok/s (-40 %); the 30B NPU first token fell from 13.9 s to 0.35 s; NPU decode
rose 14 to 42 %.

## 9. Reading a result: what to trust

- **Only compare what shares conditions.** The same model, compute unit, prompt length, stack, and AC power.
  The comparison and the history carry all of these for you; a hand-built table does not.
- **A figure is a measurement, not a spec.** Run to run, controls varied 3 to 7 %. A change smaller than that
  is not a finding.
- **Short-prompt decode hides the NPU's advantage.** The NPU leads on prefill by several times and on decode by
  little. Judge a long-prompt workload by the prefill and by the figure at its own prompt length: both prefill
  and decode fall as the prompt grows.
- **A utilization sampler lowers the rate it is measuring**, by about 9 % at 7B and about 40 % at 0.5B on
  Foundry. Placement and speed are measured on separate requests, or with `-NoUtilization`.
- **A reused chat session accumulates history**, so every later run prefills the earlier ones. The harnesses use
  a fresh session or a stateless request per run.
- **Half-speed states.** The machine has sat, unexplained, at about half speed for stretches, on AC power too.
  A figure that is half what the same model gave later should be repeated before it is believed; the canary is
  there to catch this once it has a reference.
- **A suspicious result is a reason to look at the conditions,** not at the software. The cases where that was
  the answer are in [BENCHMARKS.md](BENCHMARKS.md#how-these-are-measured) and the
  [README](../README.md#12-troubleshooting).

## 10. When something goes wrong

| You see | Cause and fix |
| --- | --- |
| `refusing: on battery` | Plug in. Or `-AllowBattery`, accepting that the result is kept out of published figures |
| `refusing: ... may hold the NPU` | Another process has the NPU: stop `geniex serve`, close `atlas-chat`, or `foundry model unload <alias>`. The message names it |
| `#requires` / "requires PowerShell 7" | You are in Windows PowerShell. Run `pwsh` |
| A list parameter ends up as one string | `pwsh -File` does not bind arrays. Use `pwsh -Command "& .\Scripts\X.ps1 -List a,b"` |
| The control or canary says the build is not unpacked | `.\Scripts\Invoke-BenchControl.ps1 -Download`, once (exit code 4; a suite reports the step skipped) |
| `max_tokens` errors, HTTP 500, from Foundry | A small `max_tokens` fails inside Foundry's `GroupQueryAttention`; use 64 or more. After one such failure the daemon has stopped answering; restart it |
| A Foundry benchmark leaves a model loaded | `foundry model unload <alias>`, and `foundry server stop` if you want the daemon down |
| `-InProcess` warns it is using the target prompt length | There is no earlier HTTP run of that prompt and model to take the exact count from. Run the HTTP route first |
| Numbers about half what you expected | Check the conditions, run `Invoke-BenchCanary`, and repeat. See [what to trust](#9-reading-a-result-what-to-trust) |
| Results look different after an update | That is the point: `Compare-BenchStacks`. Read the control line first |

The checks that the benchmark code itself works:

```powershell
.\Scripts\Test-BenchGuards.ps1                  # every harness refuses on battery
.\Scripts\Test-BenchGuards.ps1 -IncludeRuns     # and records the override on tiny real runs
.\Scripts\Test-BenchSuite.ps1                   # the suite runner, over stub steps
.\Scripts\Test-BenchCompare.ps1                 # the comparison rules
.\Scripts\Test-BenchCanary.ps1                  # the canary rules; -IncludeRuns runs it for real
.\Scripts\Test-BenchConditions.ps1              # the conditions policy, then the conditions right now
.\Scripts\Test-BenchHistory.ps1                 # the history format
.\Scripts\Test-BenchPrompt.ps1                  # prompts are rebuilt byte for byte
.\Scripts\Test-BenchLint.ps1                    # PSScriptAnalyzer over Scripts/ (install it once: see the script)
```

Each prints `ok` or `FAIL` per check and exits with the number of failures.

## 11. Adding a benchmark

1. **Name it** `Invoke-Bench<What>.ps1` (a `.py` harness: `bench_<what>.py`), with a `.SYNOPSIS` that says
   what question it answers, and examples in its header.
2. **Check the conditions first:** import `BenchConditions.psm1` and call `Assert-AtlasConditions -Needs
   <cpu|gpu|npu> -AllowBattery:$AllowBattery`, with `#requires -Version 7` and an `-AllowBattery` switch. Say
   `-Expect` for anything the script itself starts.
3. **Interleave** whatever it compares, reversing the order on alternate rounds, and time a request with nothing
   else running.
4. **Record** with `Add-AtlasBenchmarkRecord` (Python: `atlas_history.record`): the figures, `-N`, `-Stdev`,
   `-Order`, `-PromptKind`, `-Harness`. The conditions, the stack, the code revision and `suiteRun` are added for
   you.
5. **Test it:** add it to `Test-BenchGuards.ps1` so a battery run is refused.
6. **Put it in a suite** (`Scripts/suites/*.json`) if it should run with the others, and add a row to the table
   in section 4.

## 12. Former script names

The scripts were renamed to one pattern on 2026-10-17. Old records in the history keep the old names in their
`source` field, and `Compare-BenchStacks` treats a former name and its current one as the same cell. The full
mapping is in [BENCHMARK-HARNESS-PLAN.md](BENCHMARK-HARNESS-PLAN.md#naming-renamed-2026-10-17).
