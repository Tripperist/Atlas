# Benchmarks

Every number here was measured on one machine: a Snapdragon X2 Elite
(X2E78100) Surface Laptop, on AC power, in `burst` power mode, with nothing
else running. Treat them as a reference point for the platform, not as a
specification.

For how to run any of these, see the [README](../README.md). For superseded
figures and the investigations behind them, see [ARCHIVE.md](ARCHIVE.md).

**The stack these were measured on:**

| Component | Version |
| --- | --- |
| Adreno GPU driver | 32.0.172.2 |
| Hexagon NPU driver | 30.0.228.10000 |
| Windows build | 28120 |
| GenieX | v0.8.0 (llama.cpp `9425611`) |
| onnxruntime / -genai / -qnn | 1.30.0 / 0.17.1 / 2.6.0 |
| Foundry Local | 0.10.3 |

Recorded as stack `44a1e6e37bc4` in the benchmark history.

---

## Contents

- [How these are measured](#how-these-are-measured)
- [Decode throughput by compute unit](#decode-throughput-by-compute-unit)
- [Prefill vs decode](#prefill-vs-decode)
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

---

## Decode throughput by compute unit

Q4_0 GGUF via the llama.cpp engine, 400 tokens, 3 runs each, `burst`, on AC.

**Current — 2026-10-05**, GenieX v0.8.0 (llama.cpp `9425611`), Adreno driver 32.0.172.2, stack `44a1e6e37bc4`:

| Model | Compute | Tok/s | First token (s) | Startup (s) | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3-4B | `npu` | **30.5** | 1.53 | 9.54 | 17.8 | 100 | 4.9 |
| Qwen3-4B | `cpu` | 28.7 | **0.20** | 2.82 | 81.8 | 0 | 4.8 |
| Qwen3-4B | `gpu` | 24.0 | 0.20 | 5.92 | 17.9 | 0 | 87.9 |
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

## Foundry Local

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

> Throughput here is wall time around the HTTP request divided by the server's
> reported `completion_tokens`, so it includes request overhead. That is what a
> real client would actually see, but it is **not** comparable to
> `geniex-bench`'s isolated decode rate in [prefill vs decode](#prefill-vs-decode).

### In-process SDK vs the HTTP endpoint

`qwen2.5-0.5b` (NPU variant), 400 tokens, SDK 2.1.0:

| Route | tok/s | First token | Model load |
| --- | --- | --- | --- |
| **C# in-process SDK** | **109.3** | 0.08 s | 2.9 s |
| **Python in-process SDK** | **107.3** | 0.07 s | 2.9 s |
| CLI + HTTP endpoint | 27.6 | — | server start |

The two SDK bindings agree to within 2 %, as they should — one native core
behind two wrappers. Against the HTTP endpoint the gap is about **4x**.

**The gap is not purely transport.** The CLI serving the endpoint is versioned
separately and is older (CLI 0.10.3, Foundry Local Core 1.0.0, ORT 1.26.0) than
the SDK measured here (2.1.0, ORT GenAI 0.17.1), so runtime vintage is mixed in
with the HTTP hop. The direction is not in doubt; the split is unattributed.

**Every other Foundry figure in this file was taken over HTTP** and therefore
describes the endpoint rather than Foundry Local's ceiling. Read them that way.

> Measured with [`bench_foundry_sdk.py`](../src/setup/bench_foundry_sdk.py) and
> [`src/csharp/FoundryProbe`](../src/csharp/FoundryProbe). The retired
> `foundry-local-sdk-winml` 1.2.4 was also tried: throughput was erratic (103
> tok/s on the first run, then 9–15) and the process segfaulted on exit. Use
> 2.x.

### All three compute units, same model

Foundry Local publishes one variant per compute unit. `qwen2.5-0.5b`, 400
tokens, 3 runs, over the HTTP endpoint:

| Variant | Execution provider | Size | tok/s | NPU peak | CPU mean |
| --- | --- | --- | --- | --- | --- |
| `-generic-gpu` | WebGPU | 700 MB | **42.7** | 0 % | 14.5 % |
| `-generic-cpu` | CPU | 822 MB | 40.5 | 0 % | 43.9 % |
| `-qnn-npu` | QNN (HTP) | 442 MB | 27.6 | 63.6 % | 61.0 % |

The NPU variant is the slowest, and the counters confirm each variant used the
unit its name claims — NPU peak is 0 % for both the GPU and CPU variants.

**This is the expected result for this workload, not a contradiction of the
GenieX numbers above.** A 0.5B model answering a short prompt is almost
entirely decode, the phase where the NPU has no advantage. The NPU variant was
also by far the least consistent, at 17.4 / 18.5 / 46.8 tok/s across its three
runs, against 39.0–43.3 for CPU.

It is a useful counterexample to "put it on the NPU": at this model size and
prompt length, the Adreno GPU is both the fastest option and the cheapest in
CPU time.

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
