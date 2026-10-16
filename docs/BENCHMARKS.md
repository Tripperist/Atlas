# Benchmarks

Every number here was measured on one machine: a Snapdragon X2 Elite
(X2E78100) Surface Laptop, on AC power, in `burst` power mode, with nothing
else running. Treat them as a reference point for the platform, not as a
specification.

For how to run any of these, see the [README](../README.md). For superseded
figures and the investigations behind them, see [ARCHIVE.md](ARCHIVE.md).

**The stack most of these were measured on:**

| Component | Version |
| --- | --- |
| Adreno GPU driver | 32.0.172.2 |
| Hexagon NPU driver | 30.0.228.10000 |
| Windows build | 28120 |
| GenieX | v0.8.0 (llama.cpp `9425611`) |
| onnxruntime / -genai / -qnn | 1.30.0 / 0.17.1 / 2.6.0 |
| Foundry Local | 0.10.3 |

Recorded as stack `44a1e6e37bc4` in the benchmark history. Where a section does not
say otherwise, that is the stack. GenieX v0.9.0 is a different one, `af42e97d18e1`,
and is compared in [GenieX v0.9.0 against v0.8.0](#geniex-v090-against-v080).

---

## Contents

- [How these are measured](#how-these-are-measured)
- [Decode throughput by compute unit](#decode-throughput-by-compute-unit)
- [Prefill vs decode](#prefill-vs-decode)
- [A 30B mixture-of-experts model](#a-30b-mixture-of-experts-model)
- [GenieX v0.9.0 against v0.8.0](#geniex-v090-against-v080)
- [Foundry Local](#foundry-local)
- [What the numbers mean](#what-the-numbers-mean)
- [Qualcomm's published figures](#qualcomms-published-figures)
- [Model catalogue](#model-catalogue)
- [Memory](#memory)
- [Benchmark history](#benchmark-history)

---

## How these are measured

Four harnesses, measuring different things. Mixing their outputs is a mistake:

| Harness | Measures | Script |
| --- | --- | --- |
| `geniex infer` loop | decode throughput from a short prompt, plus CPU/NPU/GPU utilization | [`Invoke-Benchmark.ps1`](../Scripts/Invoke-Benchmark.ps1) |
| `geniex-bench` | prefill and decode **separately**, from a fixed 512-token prompt | [`Invoke-PrefillBench.ps1`](../Scripts/Invoke-PrefillBench.ps1) |
| ORT GenAI loop | prefill and decode separately, same axes as `geniex-bench` | [`bench_ort_genai.py`](../src/setup/bench_ort_genai.py) |
| OpenAI endpoint | end-to-end throughput including HTTP overhead | [`Invoke-FoundryBench.ps1`](../Scripts/Invoke-FoundryBench.ps1) |

### Utilization counters

The NPU registers as an **MCDM compute accelerator** (device class GUID
`{F01A9D53-3FF6-48D2-9F97-C8A7004BE10C}`, which Task Manager shows as
*DirectX 12, FL 1.0: Compute*), so Windows exposes it through the ordinary
`GPU Engine` counter set under its own adapter LUID:

| Signal | Counter |
| --- | --- |
| CPU, per core | `\Processor Information(0,N)\% Processor Utility` |
| CPU by core tier | Same, grouped by registry `~MHz` |
| **NPU** | `\GPU Engine(*engtype_compute)\Utilization Percentage` |
| **GPU** | `\GPU Engine(*engtype_3d)\Utilization Percentage` |

Adapter LUIDs are assigned **per boot** — never hardcode them. The README
explains how to re-derive them.

### Two pitfalls that will convince you the counters do not exist

1. **`GPU Engine` instances are per-process** — `pid_N_luid_..._engtype_X` — and only exist while that process runs. Enumerating instance paths *before* launching the workload finds nothing, forever. You must query with a wildcard that re-expands on every sample.
2. **Each `Get-Counter` call costs ~1 s**, because utilization counters need two samples to compute a rate. Two separate calls per loop iteration left short runs with only two samples, which missed the active window entirely and recorded a spurious `0`. Collect cores and engines in a single call, and generate enough tokens (≥400) for the sampling window to cover steady state.

Note also that the driver can report **over 100 %** for an adapter aggregating multiple sub-engines; the script clamps to 100.

### Placement is unambiguous once sampled correctly

| Run | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- |
| `--compute cpu` | **83.8** | 0 | 5.1 |
| `--compute npu` | 18.9 | **100** | 5.8 |
| `--compute gpu` | 18.2 | 0 | **87.3** |

### The cold-machine trap

The single biggest methodological hazard here. Repeated 1.7B measurements
across one session, as the machine warmed:

| Tokens | CPU tok/s | NPU tok/s |
| --- | --- | --- |
| 64 (cold) | **65.8** | 63.3 |
| 160 | 61.0 | 63.3 |
| 400 (warm) | 53.4 | **65.3** |

CPU throughput fell **19 %** while the NPU held within ~2 tok/s. **Any benchmark
short enough to run on a cold machine will flatter the CPU.** Measure once,
briefly, and you will reach the wrong conclusion.

### Run order

A warm-up fixes the start of a run, not the drift across it. Running every
repeat of one compute unit before moving to the next charges all of that drift
to whichever unit went last, and a community report on this same SoC saw a
9 % gap between two configurations shrink to 2 % once the runs were
interleaved. [`Invoke-Benchmark.ps1`](../Scripts/Invoke-Benchmark.ps1)
therefore **round-robins across the units and reverses the order on alternate
rounds**.

Qwen3-4B, re-measured that way on 2026-10-09 (three rounds):

| Compute | Tok/s by round | Spread |
| --- | --- | --- |
| `npu` | 30.6, 30.5, 30.0 | 2 % |
| `gpu` | 24.0, 20.3, 21.3 | 18 % |
| `cpu` | 20.4, 26.5, 26.9 | 31 % |

The NPU figure did not move when the order changed (30.5 blocked, 30.4
interleaved). The CPU and GPU figures did: 28.7 and 24.0 blocked against 24.6
and 21.9 interleaved. The blocked figures sit at or above the top of the
interleaved range, which is consistent with order bias — but with a 31 % CPU
spread across only three rounds, the data cannot establish order as the cause.
Read the CPU and GPU rows as approximate and the ordering as the finding.

**A later measurement does not support order bias as the cause.** On 2026-10-16
the same model, interleaved but with the utilization sampler switched off
(`-NoUtilization`), gave NPU 31.3, CPU 28.3 and GPU 27.6 tok/s: the CPU back at
its blocked-order figure. The CPU varied by 33 % inside that single run (24.7 to
32.8). So the CPU and GPU figures move 15–30 % between sessions for reasons that
were not isolated, while the NPU stays within about 3 %. What the data does
support is that the NPU leads, by roughly 11–24 % depending on the session, and
that its figure is the only stable one. Do not read a CPU or GPU digit as
precise.

Results taken before this change, on the 1.7B and 0.6B models, were run in
blocks and are marked as such.

---

## Decode throughput by compute unit

Q4_0 GGUF via the llama.cpp engine, 400 tokens, 3 runs each, `burst`, on AC.
GenieX v0.8.0 (llama.cpp `9425611`), Adreno driver 32.0.172.2, stack
`44a1e6e37bc4`.

**Qwen3-4B — 2026-10-09, units interleaved** (see [run order](#run-order)):

| Model | Compute | Tok/s | First token (s) | Startup (s) | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3-4B | `npu` | **30.4** | 1.43 | 8.47 | 18.8 | 100 | 4.6 |
| Qwen3-4B | `cpu` | 24.6 | 0.67 | 4.75 | 77.5 | 0 | 4.5 |
| Qwen3-4B | `gpu` | 21.9 | **0.20** | 7.57 | 17.6 | 0 | 93.1 |
| Qwen3-4B | `hybrid` | 23.2 | 3.27 | 10.85 | 16.3 | 93.5 | 45.4 |

**`hybrid` is not the faster path here.** Qualcomm's GenieX documentation
describes it as llama.cpp's per-tensor HTP + CPU scheduler and calls it "the
faster path on Snapdragon". On Qwen3-4B it was third of four, 24 % behind plain
`npu`, with the slowest first token (3.27 s) and startup (10.85 s). Its
utilization does not match the description either: the NPU peaked at 93.5 %
and the GPU at 45.4 %, with the CPU no busier than in the `npu` run (16.3 %
against 18.8 %). Something was using the Adreno. Per-round spread was 2 %
(23.2, 23.5, 23.0), so the figure is stable even though the explanation is
not known. One model, one size: this says nothing about larger ones.

**Qwen3-4B — 2026-10-16, units interleaved, utilization sampler off**
(`Invoke-Benchmark.ps1 -NoUtilization`, three rounds, order cpu > gpu > npu,
then reversed, then as the first):

| Model | Compute | Tok/s (rounds) | First token (s) | Startup (s) |
| --- | --- | --- | --- | --- |
| Qwen3-4B | `npu` | **31.3** (31.1 / 31.2 / 31.5) | 9.3 | 25.2 |
| Qwen3-4B | `cpu` | 28.3 (32.8 / 24.7 / 27.5) | 0.83 | 4.4 |
| Qwen3-4B | `gpu` | 27.6 (26.8 / 28.0 / 28.0) | **0.20** | 5.7 |

The NPU's first token and startup are far above the 1.43 s and 8.5 s of the
2026-10-09 run, on the same stack. That was not explained, and it means NPU
first-token and startup figures do not carry between sessions.

**Qwen3-1.7B — 2026-10-05, units run in blocks.** These predate interleaving,
so the CPU and GPU rows may be overstated; the NPU row is the one to trust.

| Model | Compute | Tok/s | First token (s) | Startup (s) | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3-1.7B | `npu` | **61.3** | 1.13 | 4.78 | 25.2 | 100 | 4.9 |
| Qwen3-1.7B | `cpu` | 51.0 | 0.20 | 3.26 | 72.8 | 0 | 52.1 * |
| Qwen3-1.7B | `gpu` | 47.9 | **0.10** | 3.66 | 26.4 | 0 | 89.9 |

\* Peak columns aggregate by maximum, so one contended sample is enough to
raise them. The GPU was otherwise idle across that run's other two repetitions.

> **These are a re-measurement**, taken after GenieX was uninstalled, reverted to
> v0.7.0, and reinstalled at v0.8.0. Against the earlier independent run on the
> same stack, the agreement is uneven in an informative way:
>
> | Compute | Spread between the two runs |
> | --- | --- |
> | `npu` | **0.3 % and 0.8 %** |
> | `cpu` | 1.8 % and 7.9 % |
> | `gpu` | 11 % and 12 % |
>
> The NPU is by far the most repeatable unit on this machine. The CPU varies
> within a single run as well — the three Qwen3-1.7B repetitions came in at
> 38.4, 61.5 and 53.2 tok/s — which is the thermal behaviour described in
> [what the numbers mean](#what-the-numbers-mean) showing up directly. **Treat a single CPU or GPU number here as
> approximate; treat the ordering as solid.** Any CPU-versus-NPU comparison
> drawn from one short run is unsafe, which is exactly the error made earlier in
> this project.

---

## Prefill vs decode

The runs above use short prompts, so prefill is negligible and decode dominates. That understates the NPU badly. `geniex-bench` — shipped in the GenieX releases, llama-bench style — reports prefill and decode separately against a fixed 512-token prompt, which is far closer to a retrieval-augmented workload.

```powershell
.\Scripts\Invoke-PrefillBench.ps1 -Matrix     # the whole table below
.\Scripts\Invoke-PrefillBench.ps1 -Model 'unsloth/Qwen3-4B-GGUF:Q4_0' -Device npu
```

`geniex-bench` ships as a per-release archive rather than with the CLI, so the
script fetches the build matching the **installed** GenieX version and verifies
its SHA256. Benchmarking a v0.7.0 harness against a v0.8.0 runtime would quietly
compare two different things. Results are appended to the benchmark history
([benchmark history](#benchmark-history)) with prefill and decode kept as separate fields.

**Qwen3-4B, 512-token prompt, 128 generated, 3 repetitions, GenieX v0.8.0, stack `44a1e6e37bc4`:**

| Plugin | Device | Quantization | TTFT | Prefill tok/s | Decode tok/s | v0.7.0 prefill |
| --- | --- | --- | --- | --- | --- | --- |
| **qairt** | **NPU** | W4A16 | **247 ms** | **2072.0** | 27.8 | 2079.7 |
| llama.cpp | NPU | Q4_0 | 374 ms | 1380.0 | 18.2 | 1414.8 |
| llama.cpp | GPU | Q4_0 | 1564 ms | 327.6 | 22.4 | 326.8 |
| llama.cpp | CPU | Q4_0 | 2138 ms | 239.5 | **28.5** | 238.9 |

**Same model across runtimes — `Phi-4-mini-reasoning`, 512-token prompt, 128 generated, 3 repetitions:**

The Qwen3-4B table above compares GenieX's two plugins, but Qwen3 has no ORT GenAI build. Phi-4-mini-reasoning exists as both a GGUF and a Microsoft ORT GenAI NPU bundle, so it puts all three runtimes on one model:

| Runtime | Plugin / device | Quantization | TTFT | Prefill tok/s | Decode tok/s |
| --- | --- | --- | --- | --- | --- |
| GenieX | llama.cpp, NPU | Q4_0 | **325 ms** | **1590.2** | 19.9 |
| GenieX | llama.cpp, CPU | Q4_0 | 1715 ms | 298.6 | **32.1** |
| ONNX Runtime GenAI | QNN EP, NPU | qnn-int4 | 1172 ms | 436.9 | 17.5 |

All three rows are now re-measured on the current stack.

Measured with [`bench_ort_genai.py`](../src/setup/bench_ort_genai.py), which mirrors `geniex-bench`'s method: a fixed-length prompt of random token ids, a fixed generated-token count, and prefill timed separately from decode.

**ORT GenAI is still the weakest path on prefill** — 436.9 tok/s against 1546.0 for the same model on GenieX's llama.cpp NPU, a **3.5× gap**. The earlier figure put it *below* llama.cpp on CPU; at 436.9 against 296.6 it is now clearly **above** CPU, so that particular claim no longer holds. Decode is comparable to llama.cpp NPU (17.5 vs 22.4), with both behind CPU.

**The architecture explains it.** As described in the [README](../README.md#6-onnx-runtime-genai), this bundle's graph is a hybrid: **36 `EPContext` nodes** that QNN executes on the NPU, plus **32 `GroupQueryAttention` nodes that run on CPU**. Prefill is attention-heavy across all 512 positions, so pushing attention to the CPU costs exactly where the NPU should be strongest. That it still reports ~98 % NPU utilization is a good illustration of why a utilization figure is not a throughput measurement.

**Conclusion for runtime selection.** On prefill-dominated work, the ordering is unambiguous: **GenieX QAIRT > GenieX llama.cpp ≫ ORT GenAI**. ORT GenAI's value is in-process control of the token loop and a first-party C# path — not speed. If you need that control, the cost is roughly 3.5× on prefill against the GenieX llama.cpp path; if you do not, `geniex serve` is both faster and simpler.

**This reframes the CPU-versus-NPU question entirely.**

- **Prefill is where the NPU earns its place.** QAIRT on NPU is **8.7×** the CPU's prefill rate, and llama.cpp on NPU is **5.8×**. Time to first token drops from 2.14 s to 0.25 s — a difference a user feels directly.
- **Decode is much closer.** QAIRT NPU 27.8 against CPU 28.5 is effectively a tie; llama.cpp NPU at 18.2 is actually *slower* than the CPU.
- **The runtime matters more than the compute unit.** On the same NPU, QAIRT delivers 2072.0 / 27.8 against llama.cpp's 1380.0 / 18.2 — **1.5× the prefill and 1.5× the decode**. This confirms the ~2× gap inferred from Qualcomm's published figures in [Qualcomm's published figures](#qualcomms-published-figures).
- **The GPU is not competitive** on either axis here.

**For a retrieval-augmented workload, this settles the question.** Such prompts are long and replies are often short or structured, so the workload is prefill-dominated — and prefill is exactly where the NPU wins by 6–9× (5.8× on llama.cpp, 8.7× on QAIRT, against the same CPU baseline). The short-prompt benchmarks [above](#decode-throughput-by-compute-unit), which show the NPU only marginally ahead, measure the wrong thing for that use case.


---

## Same model, two runtimes

`Phi-4-mini-reasoning` is the one model published in a format each runtime can
load, so it is the only direct runtime comparison available. Driven through
[`atlas-chat`](../src/csharp/AtlasChat), same prompt, same 1500-token cap,
reasoning tokens counted:

| Runtime | Asset | Model load | Decode | First token |
| --- | --- | --- | --- | --- |
| **GenieX** (llama.cpp, NPU) | `Q4_0` GGUF | lazy, ~7 s on first use | **31.7 · 30.6 tok/s** | 0.11 s warm |
| **ORT GenAI** (QNN EP, NPU) | `qnn-int4` ONNX | 7.6 s | **15.2 · 16.1 tok/s** | 0.14 s |

**GenieX is roughly 2x faster for the same model**, with both at 100 % on the
compute engine. That agrees with the prefill/decode matrix above, measured by a
different harness on the same pair.

> **This is a path comparison, not a pure runtime one.** The quantizations
> differ — `Q4_0` against `qnn-int4` — so some of the gap is the weights rather
> than the runtime. Nobody publishes this model in one quantization for both,
> so the confounder cannot be removed with what exists today.

A second turn costs both of them, as context grows: GenieX 31.7 to 29.4
(-7 %), ORT GenAI 15.2 to 12.7 (-16 %).

> **ORT GenAI is sensitive to background CPU load; GenieX is not.** Re-measured
> three days later on an otherwise unchanged stack — same drivers, same OS
> build, same runtime versions, verified against the baseline — with a browser,
> Task Manager and an updater consuming about **1.35 cores**:
>
> | Runtime | Quiet machine | ~1.35 cores busy |
> | --- | --- | --- |
> | GenieX (llama.cpp, NPU) | 31.7 tok/s | **34.0 / 31.3** — unaffected |
> | ORT GenAI (QNN EP, NPU) | 15.2 tok/s | **7.3 / 8.0** — less than half |
>
> The cause is structural, and already documented above: this bundle runs 36
> `EPContext` nodes on the NPU but **32 `GroupQueryAttention` nodes on CPU**, so
> contention for the CPU hits it directly. GenieX's llama.cpp path keeps the
> whole graph off the CPU and holds its rate.
>
> So the ~2x figure in this table is the *quiet-machine* number. Under load the
> gap widens to 4x. Measure on an idle machine, and treat any ORT GenAI figure
> taken otherwise as a floor.

> The first GenieX turn after a cold start showed a 7.01 s time to first token.
> That is `geniex serve` loading the model on first use, not prefill — the next
> turn was 0.11 s. A server pays it once; a one-shot CLI invocation pays it
> every time.

---

## A 30B mixture-of-experts model

> Measured on GenieX v0.8.0 (stack `44a1e6e37bc4`). GenieX v0.9.0 changed several of
> these results, notably the NPU cold start and the GPU decode rate; see
> [GenieX v0.9.0 against v0.8.0](#geniex-v090-against-v080).

`Qwen3-Coder-30B-A3B-Instruct`, Q4_0 GGUF from unsloth: architecture
`qwen3moe`, 30.5 B parameters (per `llama-bench`; published as about 3.3 B
active per token), 16.2 GiB on disk. Through GenieX v0.8.0 on the llama.cpp
engine, 2026-10-15, stack `44a1e6e37bc4`. It was chosen to find out whether a
model far larger than the ~3.5 GB per-session figure in llama.cpp's Hexagon
documentation runs on the NPU at all, and as a candidate for a local coding
agent.

**Prefill and decode** — `geniex-bench`, 512-token prompt, 128 generated, three
interleaved rounds (order npu > gpu > cpu, then reversed, then as the first),
every round shown:

| Compute | Prefill tok/s | First token (s) | Decode tok/s |
| --- | --- | --- | --- |
| `npu` | **451.1, 458.9, 456.1** | 1.14, 1.12, 1.13 | 18.2, 23.8, 17.5 |
| `gpu` | 302.9, 296.2, 299.3 | 1.69, 1.73, 1.71 | **28.8, 27.5, 26.8** |
| `cpu` | 40.0, 110, 61.2 | 12.8, 4.66, 8.37 | 12.2, 27.4, 24.4 |

**Decode and utilization** — `geniex infer`, short prompt, 256 tokens, two
interleaved rounds:

| Compute | Tok/s | First token (s) | Startup (s) | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- | --- | --- | --- |
| `npu` | **30.0** | 13.9 | 41.7 | 16.8 | 100 | 4.9 |
| `gpu` | 29.4 | **0.3** | 12.4 | 18.4 | 0 | 91.7 |
| `cpu` | 24.0 | 1.1 | 10.2 | 59.8 | 0 | 3.7 |

What the two tables show:

- **It runs with the NPU engaged.** Under `--compute npu` the NPU counters
  peaked at 100 % with the CPU at 17 %; under `--compute gpu` the NPU read 0 and
  the GPU 92 %. A peak of 100 % does not say what fraction of the work is on the
  NPU, and nothing here explains how a 16 GiB model fits a session limit
  documented as ~3.5 GB. GenieX evidently handles it; how was not investigated.
- **Decode matches a dense 4B model.** About 30 tok/s on the NPU and GPU, the
  same as dense Qwen3-4B (30.4) at 7.6 times the parameter count.
- **The NPU leads on prefill.** About 455 tok/s against 299 on the GPU, 1.5
  times faster, and both were stable to about 2 % across rounds. The 30B's GPU
  prefill is within 9 % of dense Qwen3-4B's (327.6, above).
- **CPU prefill is not reliable here.** Three rounds gave 40, 110 and 61 tok/s.
  The CPU figures above should not be quoted as a number.
- **The two harnesses disagree on NPU decode**, 17.5–23.8 against 30.0, while
  they agree on the GPU. Dense Qwen3-4B shows the same split (18.2 in the
  prefill table above, 30.4 from `geniex infer`), so this is not specific to the
  30B. For long-context use the post-prefill figure is the relevant
  one, and it keeps falling with prompt length; see [long prompts](#long-prompts).
- **The NPU has a heavy cold start.** The first token took 13.9 s and startup
  41.7 s, against 0.3 s and 12.4 s on the GPU. That is far larger than the
  4B's 1.43 s first token, and consistent with the one-time per-process
  initialisation described in the [archive](ARCHIVE.md#geniex-v080-first-token-penalty),
  apparently growing with model size. Whether a long-lived `geniex serve` pays it
  once was not measured.

Limits: three rounds for the prefill table and two for the decode table, one
512-token prompt, `burst` mode on AC. Prefill slows as context grows; the
[long-prompt measurements](#long-prompts) below go to 6,784 tokens, and nothing
here covers 10 000.

### Long prompts

The same file, GenieX v0.8.0, `geniex-bench` with the context fixed at 16,384
(`-c`) and 64 generated tokens, three repetitions per cell. The prompt lengths
match the [Foundry 7B curve](#a-7-gb-model-on-the-npu-qwen25-coder-7b), and the
NPU and GPU order alternated between sizes. Each figure is what `geniex-bench`
reports for the cell; the spread between repetitions is not shown.

| Prompt tokens | NPU prefill tok/s | NPU first token | NPU decode | GPU prefill tok/s | GPU first token | GPU decode |
| --- | --- | --- | --- | --- | --- | --- |
| 512 | **445** | 1.2 s | 16.7 | 303 | 1.7 s | **28.9** |
| 896 | **393** | 2.3 s | 16.5 | 278 | 3.2 s | **25.2** |
| 1,792 | **377** | 4.7 s | 12.7 | 250 | 7.2 s | **21.3** |
| 3,456 | **383** | 9.0 s | 10.8 | 198 | 17.5 s | **18.7** |
| 6,784 | **337** | 20.1 s | 9.1 | 138 | 49.1 s | **14.9** |

- **Fixing the context changed nothing.** The 512-token row, run with the
  context set, gives 445 and 303 tok/s against about 455 and 299 with the
  default.
- **The NPU's prefill holds up.** It fell by 24 % from 512 to 6,784 tokens; the
  GPU's fell by 54 %, about what Foundry's 7B lost over a similar range (about
  55 %, from 485 at 320 tokens to 216 at 6,784).
- **Against the Foundry 7B**, the 30B on GenieX is slower to ingest short prompts
  and faster to ingest long ones. Foundry leads at 896 tokens (520 against 393)
  and 1,792 (458 against 377); GenieX leads at 3,456 (383 against 337) and at
  6,784 (337 against 216, 1.6 times). The two used different harnesses and
  different prompts, so treat the crossover, between about 1,800 and 3,500
  tokens, as approximate.
- **Decode falls with context, on both units.** The NPU goes from 16.7 to 9.1
  tok/s and the GPU from 28.9 to 14.9, so after a prompt the GPU decodes
  1.5 to 1.7 times faster than the NPU at every length. The tie between them on a short
  prompt (30.0 and 29.4 from `geniex infer`) does not survive a long one.

**Arithmetic, not a measurement.** A turn with a 6,784-token prompt takes
20.1 s plus *G* ÷ 9.1 on the NPU and 49.1 s plus *G* ÷ 14.9 on the GPU for *G*
generated tokens. At 500 generated tokens that is about **75 s on the NPU and
83 s on the GPU**. The two break even at roughly 680 generated tokens: below
that the NPU finishes first, above it the GPU does. An agent turn that is mostly
reading favours the NPU, and one that is mostly writing favours the GPU.

Limits: `geniex-bench` fills the prompt with **random token ids**, not code. On a
mixture-of-experts model the routing of random ids may differ from real text, so
these prefill rates could be off in either direction; the Foundry curve used
real code on a dense model. The CPU was not run, nothing beyond 6,784 tokens was
tried, and 64 generated tokens is a short decode.

### Stock llama.cpp on the same file

The same GGUF through an unmodified upstream build: llama.cpp **b10566**
(2026-08-21), the official `ggml-org` release asset
`llama-b10566-bin-win-opencl-adreno-arm64.zip`, SHA256
`d78bd4db577eff9f8e3d77fe43e921c2c43aed9bacb35350723b23eaf373decd`. It was
unpacked into a scratch directory and run from there; nothing was installed.
The Adreno OpenCL backend needs no test signing, unlike the Hexagon one. This
is the engine family inside LM Studio and Ollama, but neither app was measured.

`llama-bench`, pp512 and tg128, three interleaved rounds (GPU first, then CPU
first, then GPU first), every round shown:

| Config | Prefill tok/s | Decode tok/s |
| --- | --- | --- |
| stock, Adreno OpenCL (`-ngl 99`) | 293.0, 293.8, 291.5 | 22.0, 26.1, 23.0 |
| stock, CPU only (`-ngl 0`) | 118.7, 121.4, 117.9 | **40.1, 37.5, 38.3** |

```powershell
llama-bench.exe -m <path>\Qwen3-Coder-30B-A3B-Instruct-Q4_0.gguf -ngl 99 -p 512 -n 128 -r 1   # Adreno OpenCL
llama-bench.exe -m <path>\Qwen3-Coder-30B-A3B-Instruct-Q4_0.gguf -ngl 0  -p 512 -n 128 -r 1   # CPU
```

Against the GenieX figures above (means, rounded):

| | Prefill | Decode |
| --- | --- | --- |
| GenieX NPU | **455** | 30 short prompt, 20 after a 512-token prompt |
| GenieX GPU | 299 | 28–29 |
| stock GPU (OpenCL) | 293 | 24 |
| stock CPU | 119 | **39** |
| GenieX CPU | 40–110 | 21–27 |

- **GPU prefill is the same engine doing the same work**: 293 against 299, within
  2 %. GenieX decoded about 20 % faster; the two are different llama.cpp builds.
- **Stock CPU decode beats everything GenieX gave**, NPU and GPU included. A
  mixture-of-experts model with about 3 B active parameters is a good fit for 12
  CPU cores.
- **Stock CPU was stable**: 3 % spread in prefill and 7 % in decode, in either
  position. GenieX's erratic CPU prefill therefore looks specific to its CPU
  path rather than to the machine, though that was not isolated.
- **The NPU is still far ahead on prefill**, about 3.8 times stock CPU.

Limits: `llama-bench` labels both configurations `OpenCL`, because that is the
backend it loaded. That `-ngl 0` ran on the CPU is inferred from the very different
numbers, since no utilization was sampled in these runs. One repetition per
round, three rounds. Thread count was the default.

**Arithmetic, not a measurement.** For a turn with a 10 000-token prompt and 500
generated tokens, using the rates above (post-prefill decode for the NPU):

| | Prefill | Decode | Turn |
| --- | --- | --- | --- |
| GenieX NPU | 22 s | 25 s | about 47 s |
| GenieX GPU | 33 s | 18 s | about 52 s |
| stock GPU | 34 s | 21 s | about 55 s |
| stock CPU | 84 s | 13 s | about 97 s |

This assumes the 512-token prefill rate holds at 10 000 tokens. It will not, so
every row is optimistic and the real turns are longer. Measured at 6,784 tokens
the NPU prefills at 337 tok/s, not 455, and decodes at 9.1, not about 20, so a
turn with that prompt and 500 generated tokens takes about 75 s on the NPU and
83 s on the GPU; see [long prompts](#long-prompts).

---

## GenieX v0.9.0 against v0.8.0

GenieX v0.9.0 was installed on 2026-10-16 (rc.4 was installed first and never measured). It is a
different stack, `af42e97d18e1`: GenieX v0.9.0, **llama.cpp `e467e5b`** (v0.8.0 and
rc.4 both ship `9425611`), **QAIRT 2.50** (was 2.45) and `onnxruntime-qnn` 2.7.0
(was 2.6.0), with the same drivers and Windows build. The
[release notes](https://github.com/qualcomm/GenieX/releases/tag/v0.9.0) list about
thirty changes; the ones that touch what is measured here are the lazy Hexagon
mapping warm-up (qualcomm/GenieX#1529), the removal of a 64 MiB Windows Hexagon
buffer cap (#1530), the llama.cpp bump (#1544) and the QAIRT bump (#1535).

Everything below was measured with the utilization sampler off and the compute units
interleaved, and `geniex-bench` figures are the median of three repetitions.
v0.8.0 figures are those recorded earlier in this file.

**Small models, `geniex-bench`, 512-token prompt** (prefill / decode tok/s):

| Model | Plugin, device | v0.8.0 | v0.9.0 |
| --- | --- | --- | --- |
| Qwen3-4B | QAIRT, NPU (W4A16) | 2072 / 27.8 | 2009 / **30.4** |
| Qwen3-4B | llama.cpp, NPU | 1380 / 18.2 | 1392 / 18.4 |
| Qwen3-4B | llama.cpp, GPU | 328 / 22.4 | 325 / 23.9 |
| Qwen3-4B | llama.cpp, CPU | 240 / 28.5 | 234 / 26.6 |
| Phi-4-mini-reasoning | llama.cpp, NPU | 1590 / 19.9 | 1526 / 21.1 |
| Phi-4-mini-reasoning | llama.cpp, CPU | 299 / 32.1 | 285 / 27.9 |

The small models are essentially unchanged: within about 7 % everywhere except
Phi-4-mini on the CPU, whose decode is 13 % lower. QAIRT decode is 9 % higher, which
fits the runtime bump.

**`Qwen3-Coder-30B-A3B`, `geniex-bench`**, context 16,384, 64 generated tokens
(prefill / decode tok/s):

| Prompt tokens | NPU v0.8.0 | NPU v0.9.0 | GPU v0.8.0 | GPU v0.9.0 |
| --- | --- | --- | --- | --- |
| 512 | 445 / 16.7 | 456 / **19.3** | 303 / 28.9 | 286 / **17.4** |
| 896 | 393 / 16.5 | **478** / **23.4** | 278 / 25.2 | 271 / **18.1** |
| 1,792 | 377 / 12.7 | **454** / **17.5** | 250 / 21.3 | 243 / **15.3** |
| 3,456 | 383 / 10.8 | 373 / 12.4 | 198 / 18.7 | 195 / 15.3 |
| 6,784 | 337 / 9.1 | 329 / 10.4 | 138 / 14.9 | 137 / 14.4 |

**One-shot CLI, `geniex infer`**, time to first token and the rest of process startup
(startup is the process wall time minus decode time, so it includes load, the new
warm-up, the first token and teardown). The 30B used 256 tokens, two rounds; the 4B
400 tokens, three rounds. The v0.8.0 30B figures were taken with the sampler on:

| | v0.8.0 first token / startup | v0.9.0 first token / startup |
| --- | --- | --- |
| 30B, NPU | 13.9 s / 41.7 s | **0.3 s / 121 s** (111, 131) |
| 30B, GPU | 0.3 s / 12.4 s | 0.35 s / 21.5 s |
| 30B, CPU | 1.05 s / 10.2 s | 1.45 s / 20.9 s |
| Qwen3-4B, NPU | 9.3 s / 25.2 s | **0.1 s / 37.0 s** |
| Qwen3-4B, GPU | 0.20 s / 5.7 s | 0.2 s / 5.4 s |

**Control.** Stock llama.cpp b10566 on the same 30B file, run in the same session,
gave GPU prefill 286 and 290, decode 21.2 and 21.0, and CPU prefill 111 and 121,
decode 27.6 and 39.3. That is within a few per cent of its earlier results (GPU
293 / 22–26, CPU 119 / 38–40), so the machine was in its normal state.

- **The NPU got better at decode and at some prefill lengths.** Prefill is
  unchanged at 512 and from 3,456 tokens up, and 20 % higher at 896 and 1,792.
  Decode is 14 to 42 % higher at every length. The Windows buffer-cap removal did
  not move prefill at 512 tokens.
- **The first token no longer pays the NPU mapping cost, but the process does.** The
  warm-up moved the roughly 14 s of lazy mapping into load, as the release notes
  describe. The one-shot total is not smaller: a cold 30B process now takes about
  121 s against 42 s, and the 4B about 37 s against 25 s. Why the total grew by more
  than the cost it moved was not isolated. A long-lived `geniex serve` pays it once
  at load; that was not measured.
- **GPU decode on the 30B fell sharply at short prompts**, about 40 % at 512 tokens
  (28.9 to 17.4), and is now below the stock engine's 21 where v0.8.0 was above it.
  At 6,784 tokens it is unchanged (14.4 against 14.9). The small dense models did
  not move, so in these data it is specific to this mixture-of-experts model. The
  llama.cpp bump is the obvious suspect; it was not isolated.
- **NPU and GPU decode now cross over.** The NPU decodes faster than the GPU up to
  about 1,800 prompt tokens and slower from 3,456; on v0.8.0 the GPU was faster at
  every length.
- **Arithmetic, not a measurement.** A 6,784-token prompt with 500 generated tokens
  takes about 69 s on the NPU and 84 s on the GPU (about 75 s and 83 s on v0.8.0).
  They break even near 1,060 generated tokens, against about 680 before: below that
  the NPU finishes first. At a 512-token prompt and 500 generated tokens it is about
  27 s on the NPU and 31 s on the GPU.

Limits: random-token prompts (see the 30B section), the median of three, one
session, `burst` mode on AC. The `geniex-bench` wrapper needed a fix to produce
these: from v0.9.0 the harness prints its result line only at `--log debug`, so the
old wrapper saw every llama.cpp cell as a failure. It now reads the harness's JSON
report.

---

## Foundry Local

> **Several Foundry throughput figures below did not reproduce on 2026-10-16.**
> The harness's own utilization sampler lowered the rates it reported; the
> 0.5B variant ordering reversed; the "4x" and "2.3x" in-process-versus-HTTP gaps
> shrank to roughly nothing at 7B; and some runs sat in an unexplained
> half-speed state. Details and replacements are in
> [Re-measured 2026-10-16](#re-measured-2026-10-16). Absolute Foundry tok/s
> figures from before that date are single-session snapshots and can be 10–40 %
> low.

**Measured here** with [`Invoke-FoundryBench.ps1`](../Scripts/Invoke-FoundryBench.ps1),
`phi-3.5-mini` (variant `phi-3.5-mini-instruct-qnn-npu`) over the OpenAI endpoint, 357 tokens, 3 runs:

| Metric | Value | Previously |
| --- | --- | --- |
| Throughput | **27.7 tok/s** (28.7 / 29.3 / 25.1) | 26.5 |
| NPU peak | **100 %** on all three runs | 100 % |
| CPU mean | 79.0 % | 53.6 % |
| Wall | ~12.9 s | ~13.2 s |

Throughput reproduces within 4.5 %, and **NPU placement is confirmed again at
100 % on every run**. The CPU figure is *not* a like-for-like comparison: this
harness samples `\Processor Information(_Total)\% Processor Time`, while the
method behind the earlier 53.6 % was never recorded. Read it as "Foundry's CPU
cost is substantial", which both numbers support, rather than as a regression.

Re-measured on 2026-10-16 with the same sampled harness: **19.7 tok/s**
(18.5 / 21.5 / 19.1), NPU peak 84 %, CPU mean 68 %. That is 29 % below the figure
above, in the opposite direction to the 0.5B and 7B models, which both measured
higher than before. Not explained.

> Throughput here is wall time around the HTTP request divided by the server's
> reported `completion_tokens`, so it includes request overhead. That is what a
> real client would actually see, but it is **not** comparable to
> `geniex-bench`'s isolated decode rate in [prefill vs decode](#prefill-vs-decode).

### Re-measured 2026-10-16

A `qwen2.5-coder-7b` result that came out at half the speed it should have
prompted a re-test of four things that looked settled. Foundry daemon running
since the restart, stack `44a1e6e37bc4`.

**1. The harness's sampler lowered the numbers it reported.**
`Invoke-FoundryBench.ps1` timed each request while a performance-counter loop
ran alongside it, competing for the CPU the model's graph uses. The same request
with and without the loop, NPU variants:

| Model | Unsampled | Sampled | Cost |
| --- | --- | --- | --- |
| `qwen2.5-coder-7b` | 15.5 tok/s | 14.1 | about 9 % |
| `qwen2.5-0.5b` | 52–58 | 30–44 | about 40 % |

Fixed in the harness: throughput is timed on a request with nothing else
running, and a second, sampled request supplies placement only.

**2. The 0.5B variant ordering reversed.** Unsampled, temperature 0, order
rotated across three rounds, over HTTP:

| Variant | tok/s by round | Mean | Published 2026-10-05 |
| --- | --- | --- | --- |
| `-generic-cpu` | 70.0, 100.1, 87.6 | **85.9** | 40.5 |
| `-qnn-npu` | 56.6, 47.0, 56.2 | 53.3 | 27.6 |
| `-generic-gpu` | 40.2, 44.5, 42.0 | 42.2 | 42.7 |

Only the GPU variant, which barely touches the CPU, matched its published
figure. The other two roughly doubled, which is what a sampler competing for CPU
would do. The earlier conclusion that the GPU is fastest and the NPU slowest at
this size is **withdrawn**: unsampled, the CPU variant is fastest, the NPU second
and the GPU last. The CPU variant itself ranged from 70 to 100 between rounds.

**3. The in-process-versus-HTTP gap shrank.**

| Model | Python in-process SDK | HTTP, unsampled |
| --- | --- | --- |
| `qwen2.5-0.5b` | 30.4 (a 139-token reply), 53.9, 97.0 | 53.3 |
| `qwen2.5-coder-7b` | 16.0 | 15.5 |

At 7B the two routes agree to within 3 %. At 0.5B the in-process rate itself
rose threefold across three consecutive runs, so a single run is not a figure.
The 4x published for 0.5B and the 2.3x for 7B are **withdrawn**; at 0.5B the
routes are within about 2x with a wide spread.

**4. An intermittent half-speed state.** Some earlier figures are about half of
what the same model gave later: `qwen2.5-coder-7b` over HTTP gave three runs of
381 tokens in 53.5–53.7 s (7.1 tok/s, NPU peak 35–39 %), where the same harness
later gave 14.1 with the NPU at 75 %; and the 0.5B NPU variant's 17.4 and 18.5
sit inside its published 27.6 mean. The daemon that produced the 7B figure later
closed the connection during `model.load` and was replaced, and the state has not
been seen over HTTP since. The cause is unknown. The low NPU peak during it
suggests the NPU was waiting rather than working.

**What still holds:** NPU placement of the NPU variants (peaks of 62–84 %, and 0 %
for the GPU and CPU variants); the prefill-by-length curves, which are over a
stateless HTTP request; and the 2026-10-15 tool-calling results, which were taken
after the restart. **What does not:** any Foundry tok/s from before this date
unless restated here.

### In-process SDK vs the HTTP endpoint

`qwen2.5-0.5b` (NPU variant), 400 tokens, SDK 2.1.0, as measured on
2026-10-05 — **the gap did not reproduce**, see
[re-measured](#re-measured-2026-10-16):

| Route | tok/s | First token | Model load |
| --- | --- | --- | --- |
| **C# in-process SDK** | **109.3** | 0.08 s | 2.9 s |
| **Python in-process SDK** | **107.3** | 0.07 s | 2.9 s |
| CLI + HTTP endpoint | 27.6 | — | server start |

The two SDK bindings agree to within 2 %, as they should — one native core
behind two wrappers. Against the HTTP endpoint the gap was about 4x on that
day, and a sampler running during the HTTP runs accounts for a large part of it.

**Treat the 4x as withdrawn.** The CLI serving the endpoint is also versioned
separately and is older (CLI 0.10.3, Foundry Local Core 1.0.0, ORT 1.26.0) than
the SDK measured here (2.1.0, ORT GenAI 0.17.1), so runtime vintage was mixed in
as well. Re-measured, the two routes are within about 2x at 0.5B and within 3 %
at 7B, so there is no established transport penalty to attribute.

At 7B, re-measured, the two routes agree to within about 3 % (16.0 in-process,
15.5 over HTTP unsampled); see
[the `qwen2.5-coder-7b` measurements](#a-7-gb-model-on-the-npu-qwen25-coder-7b).

**Every other Foundry figure in this file was taken over HTTP** with the
utilization sampler running (until 2026-10-16), so it describes the endpoint
under load rather than Foundry Local's ceiling, and may be 10–40 % low. Read
them that way.

> Measured with [`bench_foundry_sdk.py`](../src/setup/bench_foundry_sdk.py) and
> [`src/csharp/FoundryProbe`](../src/csharp/FoundryProbe). The retired
> `foundry-local-sdk-winml` 1.2.4 was also tried: throughput was erratic (103
> tok/s on the first run, then 9–15) and the process segfaulted on exit. Use
> 2.x.

### All three compute units, same model

Foundry Local publishes one variant per compute unit. `qwen2.5-0.5b`, 400
tokens, 3 runs, over the HTTP endpoint, **as measured on 2026-10-05 with the
sampler running. The ordering below was reversed on re-measurement**; see
[re-measured](#re-measured-2026-10-16) for the unsampled figures:

| Variant | Execution provider | Size | tok/s | NPU peak | CPU mean |
| --- | --- | --- | --- | --- | --- |
| `-generic-gpu` | WebGPU | 700 MB | **42.7** | 0 % | 14.5 % |
| `-generic-cpu` | CPU | 822 MB | 40.5 | 0 % | 43.9 % |
| `-qnn-npu` | QNN (HTP) | 442 MB | 27.6 | 63.6 % | 61.0 % |

The counters confirmed each variant used the unit its name claims — NPU peak is
0 % for both the GPU and CPU variants — and that still holds.

**The ordering did not.** That run had the GPU fastest and the NPU slowest.
Re-measured without the sampler, the CPU variant is fastest (85.9), the NPU
second (53.3) and the GPU last (42.2). The GPU figure reproduced; the other two
roughly doubled. What survives is narrower: a 0.5B model answering a short prompt
is not where the NPU shows an advantage, and the GPU variant costs the least CPU
(about 10 % in the sampled placement runs, against 37–43 % for the CPU variant
and 56–74 % for the NPU one). The NPU variant's 17.4 / 18.5 / 46.8 were mostly the
half-speed state described under re-measured.

### A 7 GB model on the NPU: `qwen2.5-coder-7b`

Variant `qwen2.5-coder-7b-instruct-qnn-npu`, 7.1 GB, 2026-10-15, stack
`44a1e6e37bc4`, Foundry CLI 0.10.3, SDK 2.1.0. Its `genai_config.json` declares
a 32,768-token context and a 64-token sliding window. The same Lisbon prompt as
the other Foundry rows, 400 tokens, three runs:

| Route | tok/s | First token | Model load |
| --- | --- | --- | --- |
| Python in-process SDK | **16.0** (15.8 / 16.0 / 16.2) | 0.38 s | 15.6 s |
| HTTP, streamed, 320-token prompt | 16.0 (16.1 / 15.8) | 0.54 s | 38.7 s |
| HTTP, non-streamed, unsampled | 15.5 (15.6 / 15.5 / 15.4) | — | — |
| HTTP, harness with its sampler | 14.1 (13.9 / 14.2 / 14.2) | — | — |
| HTTP on 2026-10-15, **half-speed state** | 7.1 (7.1 / 7.1 / 7.1) | — | — |

The routes agree. The 7.1 tok/s first measured over HTTP, and the "2.3 times
faster in-process" and per-token-overhead figures built on it, are **withdrawn**:
the same harness gave 14.1 once the daemon had been replaced. See
[re-measured](#re-measured-2026-10-16).

**Placement, in-process**, sampled per adapter LUID once the model had loaded:

| Engine | Peak | Mean |
| --- | --- | --- |
| NPU adapter, `compute` | 79.0 % | 64.3 % |
| Adreno, `3d` | 4.6 % | 2.8 % |
| CPU (total) | — | 49.6 % |

The NPU is genuinely engaged, and the CPU is half busy at the same time, so this
is a mixed NPU-and-CPU graph and not a pure NPU one. Over HTTP in the half-speed
state the NPU peaked at only 35–39 % with the CPU at 48.8 %; re-run, it peaked at
75 % with the CPU at 67 %, which includes the sampler's own CPU use.

**Prefill against prompt length** — over HTTP, which is stateless and reports
`prompt_tokens`, so the counts are exact. Real code from this repository, two
requests per size, wall time including about two generated tokens:

| Prompt tokens | Seconds | Prefill tok/s |
| --- | --- | --- |
| 320 | 0.66 | 487, 482 |
| 896 | 1.72 | 520, 521 |
| 1,792 | 3.9 | 462, 455 |
| 3,456 | 10.2 | 337, 338 |
| 6,784 | 31 | 220, 212 |

Run to run the figures agree within 3 %. **Prefill falls by 2.4 times** as the
prompt grows from 896 to 6,784 tokens. Over the last doubling, time grew as
roughly the 1.7th power of length, which would put a 10,000-token prompt at about
a minute. That is an extrapolation, not a measurement. At around 500 tokens this
model prefills at about the rate the 30B reaches on GenieX (455), but that
GenieX figure was measured only at 512 tokens and should not be assumed to hold
at length.

**First token and decode at length, both routes.** The prompt asks for an
explanation, so the model writes a real answer. HTTP is streamed and stateless
(256 tokens, temperature 0, two requests per size); in-process uses a fresh
session per run (100 tokens, two runs). Prompt lengths are approximate to a few
tokens, taken from the usage block on the same text with a different suffix:

| Prompt tokens | HTTP first token | HTTP decode | In-process first token | In-process decode |
| --- | --- | --- | --- | --- |
| 320 | 0.54 s | 16.0 | 0.74 s | 16.0 |
| 896 | 1.52 s | 12.4 | 2.00 s | 14.1 |
| 1,792 | 3.67 s | 9.8 | 5.12 s | 12.4 |
| 3,456 | 10.0 s | 6.7 | 15.05 s | 10.2 |
| 6,784 | 30.7 s | 4.2 | 46.0 s | 7.4 |

- **The routes trade places.** HTTP reaches the first token sooner (30.7 s against
  46.0 s at 6,784 tokens, 1.5 times), and in-process decodes faster at length
  (7.4 against 4.2). Neither dominates, and neither difference was explained.
- **Decode falls steeply with context**: by 54 % in-process and 74 % over HTTP
  between 320 and 6,784 tokens.
- **Against the 30B on GenieX** ([long prompts](#long-prompts)), at 6,784 tokens
  the 30B reaches its first token in 20.1 s on the NPU and decodes at 9.1 tok/s on
  the NPU and 14.9 on the GPU, ahead of the 7B on both counts.
- **Arithmetic, not a measurement**, for a 6,784-token prompt and 500 generated
  tokens: about 75 s on the 30B's NPU and 83 s on its GPU, against about 114 s
  for the 7B in-process and about 150 s over HTTP. At around 500 prompt tokens
  they are close: about 31 s for the 30B's NPU, 19 s for its GPU and 32 s for the
  7B. Answer quality was not compared.

**Six traps hit while measuring this**, each of which produced a plausible but
wrong number first:

- **One `ChatSession` across runs accumulates the conversation.** Run 2 of an
  identical prompt took 2.5–3.4 times longer to first token than run 1 at every
  length. With a fresh session per run it gave 5.3 / 5.9 / 5.8 s. Fixed in
  `bench_foundry_sdk.py`.
- **Windows PowerShell 5.1 can mangle a non-ASCII string body.** The 16,000- and
  32,000-character prompts returned HTTP 500 and the daemon logged JSON
  deserialization errors. The first non-ASCII character sits at index 13,676,
  and the 8,000-character prompt (all ASCII) worked. Sending the body as UTF-8
  bytes made all five sizes succeed.
- **`max_tokens=1` returns 500**, consistent with the known `GroupQueryAttention`
  bug in [README section 13](../README.md#13-open-questions). Raising it did not
  fix the encoding problem above, which is a separate cause.
- **The Foundry daemon died once during `model.load`** ("Daemon closed the
  connection"). It restarted on the next `foundry server start` and the model
  loaded. Not reproduced and not explained.
- **A utilization sampler running alongside the timed request lowers the rate**,
  by about 9 % at 7B and about 40 % at 0.5B. Time throughput on its own request.
- **An intermittent half-speed state** produced the 7.1 tok/s above and probably
  some of the 0.5B variance. A figure that is half what the same model gave later
  should be repeated on a fresh daemon before it is believed.

One in-process load took **464 s** while the daemon held the same model loaded.
Unloading the daemon's copy and repeating gave 15.6 s. Whether the cause was
contention or a first-ever load is not known; the slow run is kept in the history
with a note.

### Tool calling and NPU placement

Three 25-second windows against `qwen2.5-0.5b-instruct-qnn-npu`, NPU sampled
throughout, measured with
[`Test-ToolCalling.ps1`](../Scripts/Test-ToolCalling.ps1):

| Condition | Requests | Tokens | Tool calls | NPU peak |
| --- | --- | --- | --- | --- |
| plain, length-matched control | 116 | 1392 | 0 | **56.7 %** |
| `tool_choice=auto` | 35 | 1424 | 9 | 62.0 % |
| `tool_choice=required` | 18 | 396 | **18 of 18** | **24.4 %** |

Tool calling works on the NPU variant: every forced request returned a
well-formed `tool_calls` entry with valid JSON arguments.

But NPU peak falls from 56.7 % to 24.4 % during forced tool calling, and
throughput drops from 116 requests in the window to 18. That is consistent with
constrained decoding leaving the accelerated path. It is **not proof** — peak
sampling over roughly one-second requests is coarse, and the tools schema also
lengthens the prompt — but the direction is consistent across runs.

The control had to be **length-matched** to say anything at all. An
unconstrained completion generates far more tokens per request, so comparing
against one would have attributed a duty-cycle difference to a fallback.

Under `tool_choice=auto` the model often does not call the tool at all — 9 of
35 requests here. That is a 0.5B model failing to *decide* to use a tool, a
capability limit rather than a runtime one.

The 0.5B figures above were taken on the earlier Foundry daemon, before the
half-speed state was known; whether it touched them is not known.

**The same test on `qwen2.5-coder-7b`**, 2026-10-15, 25-second windows:

| Condition | Requests | Tokens | Tool calls | NPU peak |
| --- | --- | --- | --- | --- |
| plain, length-matched control | 31 | 372 | 0 | 74.1 % |
| `tool_choice=auto` | 14 | 336 | **0** | 77.6 % |
| `tool_choice=required` | 9 | 198 | **9 of 9** | 77.2 % |

- **The NPU does not drop at 7B.** 77.2 % during forced tool calls against 74.1 %
  for the control, where the 0.5B fell from 56.7 % to 24.4 %. So the "constrained
  decoding leaves the accelerated path" reading does not hold across these two
  models. The harness takes the peak over all compute engines; in the per-adapter
  run above the Adreno showed no compute activity, so the figure here is the NPU.
- **Forced calls work**: 9 of 9 returned `tool_calls`.
- **`tool_choice=auto` produced none in 14 requests.** The 0.5B model called the
  tool in 9 of 35. A larger coding model doing worse than a 0.5B one is
  surprising, and the cause was not investigated — it could be the model, the
  chat template Foundry applies for tools, or the prompt.

---

## What the numbers mean

**The NPU wins at both model sizes on throughput**, and the ordering has now held across a GenieX major version and two Adreno driver updates. But the short prompts used here understate it: with a realistic 512-token prompt the NPU leads prefill by 6–9× ([prefill vs decode](#prefill-vs-decode)). Note also that its first-token advantage **did not survive** the move to v0.8.0 — see the caveat in [decode throughput](#decode-throughput-by-compute-unit).
**The NPU is dramatically more consistent.** Across every run at 4B it stayed within 0.1 tok/s (29.1–29.2); the CPU ranged 20.5–32.6 across the session. For predictable latency, that stability matters more than peak throughput.

**It also frees ~65 points of CPU.** NPU runs sit at 18.9 % CPU versus 83.8 %. On a machine also running your application, an editor and a browser, the NPU wins on throughput *and* leaves the CPU available.

**Offloaded work lands on the slower core tier.** During NPU runs the fast tier sat at 5.5 % while the slow tier ran 32.2 %; same pattern on GPU (6.3 % vs 30.2 %). Windows schedules the residual coordination thread onto efficiency cores. During CPU inference both tiers ran evenly (84.0 % / 83.6 %), so llama.cpp spreads across all 12.

**The GPU is the weakest option here** — slowest at 4B and barely ahead of a throttled CPU at 1.7B, while pegging the Adreno at ~87–95 %. It also pays first-run shader compilation (21 s observed once, settling to ~4 s).

**NPU startup is the real cost** — 4.5 s at 1.7B and 6.3 s at 4B, against ~2 s for CPU. For a short-lived process that can exceed the generation savings; for `geniex serve` it amortizes to nothing.

**Caveats.** Single machine, one quantization (Q4_0), one prompt, nothing else running, AC power, `burst` power mode. Battery operation is untested. Thermal state materially changes CPU results, so record run order. Re-measure after driver or firmware updates and record the stack versions alongside results — the benchmark history does this automatically.

---

## Qualcomm's published figures

Before benchmarking anything yourself, check whether AI Hub already measured it. This is free, instant, and needs no job submission:

```powershell
qai-hub-models perf phi_4_mini_instruct -d "Snapdragon X2 Elite CRD"
qai-hub-models numerics phi_4_mini_instruct      # accuracy metrics
```

**`phi_4_mini_instruct` q4_0, GenieX llama.cpp, Snapdragon X2 Elite CRD:**

| Context | Compute | Decode tok/s | Prefill tok/s | Time to first token (ms) |
| --- | --- | --- | --- | --- |
| 512 | CPU | **34.2** | 504.1 | 1016–4064 |
| 512 | GPU | 28.0 | 632.9 | 813–3252 |
| 512 | NPU | 26.9 | **1660.2** | **309–1235** |
| 4096 | CPU | **22.4** | 290.7 | 14090–450868 |
| 4096 | GPU | 21.1 | 349.8 | 11711–374765 |
| 4096 | NPU | 18.1 | **1276.5** | **3210–102712** |

**This reframes the CPU-vs-NPU question.** The two phases behave oppositely:

- **Decode** (token-by-token): CPU leads by ~25 %. Sequential and memory-bound, which suits wide CPU cores.
- **Prefill** (processing the prompt): NPU leads by **3.3×** at 512 and **4.4×** at 4096. Batched matrix work, which is what the NPU is for.

Time to first token follows prefill: the NPU is **3–4× faster** to start responding.

**Which matters depends on your workload.** A retrieval-augmented assistant sends long prompts carrying retrieved context and tool definitions, and often gets back short or structured replies. That is prefill-dominated, and points at the NPU. A chat workload generating long prose would favour the CPU. Measure your own prompt/response ratio before choosing.

**The native QAIRT path is roughly twice as fast as llama.cpp on the NPU:**

| Model | Runtime | Device | Decode tok/s |
| --- | --- | --- | --- |
| `phi_3_5_mini_instruct` w4a16 | QAIRT Context Binary | **X2 Elite** | **34.2** |
| `phi_3_5_mini_instruct` w4a16 | QAIRT Context Binary | X Elite | 10.2 |
| `phi_4_mini_instruct` q4_0 | GenieX llama.cpp NPU | X2 Elite | 18.1 |

Two things fall out. The QAIRT bundle reaches 34.2 tok/s against 18.1 for llama.cpp on the same NPU — so **runtime choice matters more than compute-unit choice**. And X2 Elite is **3.4× X Elite** on that path, which is why assets and numbers published for X Elite are a poor guide to this machine.

> These are Qualcomm's measurements under their harness, not ours. Context length is the configured window, not the number of tokens generated, so they are not directly comparable with [decode throughput](#decode-throughput-by-compute-unit). Use them as a reference point and a sanity check, not as a substitute for measuring your own model.

---

## Model catalogue

Qualcomm publishes measured performance per model per device, so "how fast is X on my chip" rarely needs benchmarking. Everything below is **Qualcomm's published figure for Snapdragon X2 Elite CRD**, not our measurement:

```bash
.\.venv\Scripts\python.exe src\setup\model_catalog.py --device "Snapdragon X2 Elite CRD" --out .atlas-local\model_catalog.json
```

[`model_catalog.py`](../src/setup/model_catalog.py) is read-only: it shells out to `qai-hub-models perf`, needs no API token, and uploads nothing. Re-run it to refresh, then pass `--markdown <json>` to regenerate these tables.
### Language and vision-language models

Decode rate on the NPU, best across published context lengths. **Prefill matters as much as decode** — see [Qualcomm's published figures](#qualcomms-published-figures).

| Model | Type | NPU tok/s | Ctx | Prefill tok/s | Best for |
| --- | --- | --- | --- | --- | --- |
| `qualcomm/Qwen3-0.6B` | LLM | 112.1 | 512 | 7917.9 | Smallest Qwen3; fast drafts, speculative decoding |
| `qualcomm/Llama-v3.2-1B-Instruct` | LLM | 90.6 | 4096 | 4670.9 | Tiny Llama; edge latency |
| `qualcomm/Llama-v3.2-3B-Instruct-SSD` | LLM | 77.5 | 4096 | 1990.4 | 3B tuned for speculative decoding |
| `qualcomm/Qwen3-1.7B` | LLM | 68.4 | 512 | 4297.6 | Small general chat; low latency |
| `qualcomm/Intern3.5-VL-2B` | VLM | 62.0 | 4096 | 4302.1 | Compact VLM; lowest-latency vision |
| `qualcomm/Llama-v3.2-3B-Instruct` | LLM | 42.8 | 4096 | 2068.7 | Mid Llama; general assistant |
| `qualcomm/Qwen3-4B-Instruct-2507` | LLM | 42.6 | 4096 | 2831.5 | Newer 4B instruct tune |
| `qualcomm/Qwen3-VL-4B-Instruct` | VLM | 39.3 | 4096 | 2594.8 | Vision-language; photos of signs, menus, landmarks |
| `qualcomm/Qwen3-4B` | LLM | 36.2 | 512 | 2306.7 | Balanced general chat; reasoning-capable |
| `qualcomm/Phi-3.5-Mini-Instruct` | LLM | 34.2 | 4096 | n/a | Strong instruction following at 3.8B |
| `qualcomm/Phi-4-Mini-Instruct` | LLM | 26.9 | 512 | 1660.2 | Newer Phi; strong reasoning for size |
| `qualcomm/Qwen3-8B` | LLM | 25.0 | 4096 | 1895.7 | Largest Qwen3 here; best quality, slowest |
| `qualcomm/Falcon3-7B-Instruct` | LLM | 24.1 | 4096 | 1048.8 | 7B alternative architecture |
| `qualcomm/Qwen2.5-VL-7B-Instruct` | VLM | 23.4 | 2048 | 1755.6 | Previous-gen VLM |
| `qualcomm/Llama3-TAIDE-LX-8B-Chat-Alpha1` | LLM | 22.9 | 4096 | 1308.8 | Traditional Chinese-tuned |
| `qualcomm/Qwen3-VL-8B-Instruct` | VLM | 22.7 | 4096 | 1809.3 | Larger VLM; better visual reasoning |
| `qualcomm/Llama-v3.1-8B-Instruct` | LLM | 22.4 | 4096 | 1131.9 | 8B general assistant |
| `qualcomm/Gemma-4-E4B-it` | VLM | 22.3 | 4096 | 933.8 | Google VLM |
| `qualcomm/Llama-v3-ELYZA-JP-8B` | LLM | 21.4 | 4096 | 1092.2 | Japanese-tuned |
| `qualcomm/Llama-v3-8B-Instruct` | LLM | 21.2 | 4096 | 1112.8 | Previous-gen 8B |
| `qualcomm/Llama-SEA-LION-v3.5-8B-R` | LLM | n/a | n/a | n/a | Southeast Asian languages |

**Running any of them** — all are in the GenieX catalogue:

```powershell
geniex pull ai-hub-models/Qwen3-4B
geniex infer qualcomm/Qwen3-4B -p "Plan a day in Lisbon." --compute npu
geniex serve                                   # OpenAI-compatible, port 18181
```

`geniex model list` shows the catalogue. For the ONNX Runtime GenAI route instead, see [ONNX Runtime GenAI](../README.md#6-onnx-runtime-genai).

### Task models

End-to-end NPU latency: for multi-part models the fastest run of **each** component is summed, since Whisper is encoder + decoder and EasyOCR is detector + recognizer. Quoting a single component would understate the real cost.

| Model | Task | NPU latency | Parts | Runtime | Best for |
| --- | --- | --- | --- | --- | --- |
| `Whisper-Tiny` | Speech-to-text | 14.04 ms | 2 | Precompiled QAIRT ONNX | Fastest ASR; voice input where accuracy can slip |
| `Whisper-Base` | Speech-to-text | 24.96 ms | 2 | Precompiled QAIRT ONNX | Small ASR; better accuracy than Tiny |
| `Distil-Whisper` | Speech-to-text | 65.45 ms | 2 | ONNX Runtime | Distilled Whisper; faster at similar accuracy |
| `Whisper-Small` | Speech-to-text | 66.92 ms | 2 | Precompiled QAIRT ONNX | Mid ASR; good accuracy/speed balance |
| `Whisper-Large-V3-Turbo-Quantized` | Speech-to-text | 683.60 ms | 2 | Precompiled QAIRT ONNX | Best ASR accuracy, quantized |
| `PiperTTS-EN` | Text-to-speech | 38.23 ms | 6 | Voice AI | Lightweight English TTS |
| `MeloTTS-EN` | Text-to-speech | 184.64 ms | 6 | Voice AI | English speech synthesis for spoken replies |
| `TrOCR` | OCR | 5.82 ms | 2 | ONNX Runtime | Transformer OCR; handwriting and harder text |
| `EasyOCR` | OCR | 15.84 ms | 2 | ONNX Runtime | Reads menus, signs, tickets from photos |
| `OpusMT-En-Es` | Translation | 4.33 ms | 2 | Voice AI | English to Spanish |
| `OpusMT-Es-En` | Translation | 4.34 ms | 2 | Voice AI | Spanish to English |
| `OpusMT-En-Zh` | Translation | 4.41 ms | 2 | Voice AI | English to Chinese |
| `MiniLM-v2` | Embeddings | 0.67 ms | 1 | ONNX Runtime | Compact sentence embeddings |
| `Nomic-Embed-Text` | Embeddings | 3.45 ms | 1 | ONNX Runtime | Text embeddings for a retrieval index |
| `SigLIP2` | Image/text | 3.88 ms | 2 | ONNX Runtime | Newer CLIP-style image/text model |
| `OpenAI-Clip` | Image/text | 13.42 ms | 1 | ONNX Runtime | Image/text similarity; landmark and scene matching |

```powershell
qai-hub-models fetch whisper_tiny -r precompiled_qnn_onnx -p float -o models
qai-hub-models info whisper_tiny          # inputs, outputs, licence
qai-hub-models numerics whisper_tiny      # accuracy metrics
```

These are **not** GenieX models. They are ONNX/QAIRT assets run through ONNX Runtime with the QNN provider ([ONNX Runtime GenAI](../README.md#6-onnx-runtime-genai)) — remember to attach QNN with the policy API, not `providers=[...]`.

### Choosing a model for a job

| Job | Candidate | Why |
| --- | --- | --- |
| General assistant | `Qwen3-4B-Instruct-2507` | 42.6 tok/s with 2832 prefill — best quality-per-token at 4B |
| Latency-critical | `Llama-v3.2-3B-Instruct-SSD` | **77.5 tok/s**, nearly 2× the plain 3B at the same parameter count |
| Draft model | `Qwen3-0.6B` | 112 tok/s, 7918 prefill — pairs with a larger target for speculative decoding |
| Photos of menus, signs | `Qwen3-VL-4B-Instruct` | 39.3 tok/s VLM; `Intern3.5-VL-2B` at 62.0 if latency dominates |
| Retrieval embeddings | `MiniLM-v2` (0.67 ms) or `Nomic-Embed-Text` (3.45 ms) | Cheap enough to run per document; pick once, because changing the model means re-embedding the index |
| Voice input | `Whisper-Tiny` (14 ms) to `Whisper-Small` (67 ms) | 49× spread up to `Large-V3-Turbo` at 684 ms — choose on accuracy need |
| Reading text in images | `TrOCR` (5.8 ms) or `EasyOCR` (15.8 ms) | Menus, signs, tickets |
| Translation | `OpusMT-*` (~4.3 ms) | Far cheaper than asking the LLM to translate |

Three things in the numbers that are easy to miss:

- **Speculative decoding is the biggest single win Qualcomm publishes — but we could not verify it.** `Llama-v3.2-3B-Instruct-SSD` is listed at 77.5 tok/s against 42.8 for the base model on the same runtime and context, an 81 % gain. See the caveats in [the archive](ARCHIVE.md#superseded-measurements) before relying on it.
- **Task models are cheap.** Embeddings at 0.67 ms and translation at ~4.3 ms cost a rounding error next to a single LLM token. Routing work to a specialist model beats prompting the LLM to do it.
- **8B models cluster at 21–25 tok/s** regardless of family. If 4B quality suffices, that tier is roughly twice as fast.

> These are Qualcomm's measurements under their harness. Context length is the configured window, not tokens generated, and rows come from different runtimes — `Phi-3.5-Mini-Instruct` at 34.2 is a QAIRT bundle while `Phi-4-Mini-Instruct` at 26.9 is llama.cpp, so that particular comparison is runtime as much as model. `Llama-SEA-LION-v3.5-8B-R` publishes no X2 Elite data at all. Verify anything you depend on ([how these are measured](#how-these-are-measured)).

---

## Memory

This machine has **64 GB of shared system memory**, not a 64 GB model budget. Weights, KV cache, activations, runtime buffers, Windows, and your editor all draw from the same pool. Four-bit weights are roughly `parameters × 0.5 bytes` before quantization metadata and runtime overhead — the Qwen3-4B W4A16 bundle is 3.0 GiB on disk, the Q4_0 GGUF 2.2 GiB.

64 GB is generous for this class of work: 7B–14B quantized models are realistic. Long contexts are usually the binding constraint rather than weights, since KV cache grows with context length.

Start with one model, one request, and the default 4096-token context. Increase only after measuring. Keep the page file system-managed and avoid sustained paging during measurements. Tune thread count empirically — maximum logical cores is not automatically fastest.

---

## Benchmark history

Every benchmark run is appended to `.atlas-local/benchmarks/history.jsonl`,
stamped with a short hash of the stack it ran under — drivers, OS build, GenieX
version, llama.cpp revision and ONNX Runtime versions. Results measured under
different stacks are never silently compared.

```powershell
.\Scripts\Update-Workspace.ps1 -History
```

```
stack 09770a092b9b
  adreno 32.0.172.2 | npu 30.0.228.10000 | os 28120 | geniex v0.7.0 | llama.cpp 4ff829e

when             model                        compute       prefill decode firstTok source
2026-10-05 20:48 unsloth/Qwen3-1.7B-GGUF:Q4_0 npu           -        65.20     0.00 Update-Workspace.ps1

stack 44a1e6e37bc4  <-- current stack
  adreno 32.0.172.2 | npu 30.0.228.10000 | os 28120 | geniex v0.8.0 | llama.cpp 9425611

when             model                        compute       prefill decode firstTok source
2026-10-05 21:24 qualcomm/Qwen3-4B:W4A16      qairt/npu     2105.00  27.80     0.24 Invoke-PrefillBench.ps1
```

**Why the stack is hashed.** A throughput number means little without the
software that produced it. The hash is built from an explicit field list, so it
survives a JSON round-trip and adding a descriptive field later does not
invalidate existing history. Each record embeds its full state snapshot, so the
history stays readable after the baseline is replaced.

The format is JSON Lines and append-only: records are never rewritten, so the
file concatenates and diffs cleanly, and a crashed run costs at most its own
line.

**Prefill is stored as its own field** rather than folded into throughput,
because short-prompt decode rates understate the NPU's prefill advantage by a
wide margin. Records predating the field show `-`.

All five harnesses write to the same history —
[`Invoke-Benchmark.ps1`](../Scripts/Invoke-Benchmark.ps1),
[`Invoke-PrefillBench.ps1`](../Scripts/Invoke-PrefillBench.ps1),
[`Invoke-FoundryBench.ps1`](../Scripts/Invoke-FoundryBench.ps1),
[`Update-Workspace.ps1`](../Scripts/Update-Workspace.ps1) and
[`bench_ort_genai.py`](../src/setup/bench_ort_genai.py). The Python harness
shells out to [`AtlasBaseline.psm1`](../Scripts/AtlasBaseline.psm1) rather than
reimplementing the hash, so both sides derive the same id for the same machine.
