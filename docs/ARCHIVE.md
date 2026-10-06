# Archive — resolved investigations and superseded measurements

Everything here is **history**. It is kept because the diagnoses were expensive
and the failure modes are worth recognising again, not because any of it
describes the current state of the toolchain.

For how things work today, see the [README](../README.md). For current numbers,
see [BENCHMARKS.md](BENCHMARKS.md).

Each case study follows the same shape:

> **Symptom** → **What was eliminated** → **Root cause** → **Lesson that survives**

The lessons are the only part that made it into the README, and they appear
there as plain rules rather than as stories.

---

## Contents

- [Case studies](#case-studies)
  - [Adreno driver 32.0.172.1 broke all GGUF inference](#adreno-driver-3201721-broke-all-gguf-inference)
  - [onnxruntime-genai 0.16.0 broke EPContext/QNN models](#onnxruntime-genai-0160-broke-epcontextqnn-models)
  - [GenieX v0.8.0 first-token penalty](#geniex-v080-first-token-penalty)
  - [ORT GenAI prefill moved 1.7x with no known cause](#ort-genai-prefill-moved-17x-with-no-known-cause)
  - [Foundry Local's NPU catalogue shrank from 11 models to 2](#foundry-locals-npu-catalogue-shrank-from-11-models-to-2)
  - [A silently ignored provider list invalidated three conclusions](#a-silently-ignored-provider-list-invalidated-three-conclusions)
- [Superseded measurements](#superseded-measurements)
- [Corrections to earlier claims](#corrections-to-earlier-claims)
- [Closed backlog items](#closed-backlog-items)

---

# Case studies

## Adreno driver 32.0.172.1 broke all GGUF inference

**Status: resolved** by a patch-level graphics driver update.

### Symptom

`geniex infer` fail-fasted with `0xC0000409` (`STATUS_STACK_BUFFER_OVERRUN`) in
about 0.2 s on **every** GGUF model, for **every** `--compute` value, after
printing only `loading model...`. `geniex version` crashed too, because it
reports the llama.cpp runtime hash and so loads the same plugin. QAIRT bundles
were unaffected throughout.

`0xC0000409` is `__fastfail`. It produces **no Windows Error Reporting event and
no faulting module**, so the usual crash-triage route was unavailable from the
start.

### What was eliminated

Each by direct test, each negative:

- the model cache — fresh re-pull
- an HTP-specific code path — all three `--compute` values crashed identically
- PATH DLL conflicts
- missing plugin files
- a stale GenieX build — v0.7.0 and v0.8.0 both crashed
- a corrupted installation — hash-verified clean reinstall
- Foundry Local — fully uninstalled

Every candidate inside the project was negative, which is what left an external
cause as the only remaining explanation.

### Root cause

The Adreno GPU driver. Updating it, and nothing else, fixed it:

| | Broken | Fixed |
| --- | --- | --- |
| **Adreno GPU driver** | **32.0.172.1** (2026-08-26) | **32.0.172.2** (2026-09-08) |
| Hexagon NPU driver | 30.0.228.10000 | unchanged |
| GenieX | v0.8.0 | unchanged |
| GGUF `--compute cpu` | crash | 139.8 tok/s |
| GGUF `--compute gpu` | crash | 85.9 tok/s |
| GGUF `--compute npu` | crash | 131.3 tok/s |
| `geniex version` | crash | works |

A patch-level bump with the NPU driver and GenieX build held constant — the
controlled experiment the earlier investigation could not run, because the
previous driver was never staged in the driver store and so could not be rolled
back.

The mechanism: the llama.cpp plugin requires `ggml-opencl.dll`. Renaming that
file aside converted the hard crash into a clean `exit=1` dependency error,
which is what identified it. OpenCL on Snapdragon is serviced by the Adreno
driver, so a broken OpenCL ABI took down the entire llama.cpp plugin during
initialisation — regardless of which compute unit was requested, which is why
even `--compute cpu` crashed.

### Lessons that survive

- A **patch-level GPU driver change can break a runtime that appears to have
  nothing to do with graphics**. Record driver versions alongside measurements
  and re-check them before assuming a failed reproduction is your own error.
  This is why the workspace baseline tracks drivers at all.
- `0xC0000409` means `__fastfail`: no WER event, no faulting module.
- When a diagnosis rests on correlation plus a plausible mechanism, **say so**.
  This was written up as a confirmed root cause before it had been tested, then
  correctly downgraded to a hypothesis when challenged, and only promoted back
  once the driver update provided actual evidence.

---

## onnxruntime-genai 0.16.0 broke EPContext/QNN models

**Status: resolved** in 0.17.0. Filed upstream as
[microsoft/onnxruntime-genai#2603](https://github.com/microsoft/onnxruntime-genai/issues/2603).

### Symptom

`microsoft/Phi-4-mini-reasoning-onnx` (`npu/qnn-int4`) loaded successfully, then
failed on the first prompt pass:

```
RuntimeError: ... GroupQueryAttention ... 'present_keys_0' has shape {1,8,80,128}
but the computed output shape for this run is {1,8,4096,128}
```

Easy to misread as a model or hardware problem — it names a tensor shape, not a
version.

### Version matrix

| onnxruntime-genai | Result |
| --- | --- |
| 0.12.0 | *"QNN execution provider is not supported in this build"* |
| 0.13.2 | 19.6 tok/s |
| 0.14.1 | 20.8 tok/s |
| 0.15.2 | 18.8 tok/s |
| **0.16.0** | **fails on the prompt pass** |
| **0.16.0.dev1001407373** (nightly) | **also failed** — not fixed on `main` at the time |
| **0.17.0** | fixed — 4032 tokens, accelerator at 99.7 % |
| **0.17.1** | fixed — current pin |

### Root cause

From the upstream thread: 0.16.0 added
`src/models/io/ep_managed_sliding_kv_cache.{h,cpp}` and
`GetWindowedKeyValueCacheSize()`. `DetectAndConfigureFixedKvShape()` saw the
QNN-compiled `EPContext` layers declare a static `past_key` sequence dimension
and force-enabled `past_present_share_buffer` for the **whole** model —
including the 32 `GroupQueryAttention` layers that execute on CPU. Combined with
the model's declared `sliding_window.window_size` of 64, that produced the fixed
80-element allocation.

The fix landed in PR #2565 on `main` but **missed the 0.16 branch**, which is
why the 0.16 nightly still failed and why the issue appeared closed while the
released artifact was still broken.

### Lessons that survive

- **Being current is not the same as working.** 0.16.0 was the latest release
  and was unusable for this model class. A version check would have called it an
  upgrade. Only running the model caught it — which is why
  [`repro_genai_016_qnn.py`](../src/setup/repro_genai_016_qnn.py) is kept as a
  regression guard and run automatically after every upgrade.
- An upstream issue being closed does not mean the fix is in a release.
- `og.is_qnn_available()` returned `True` on 0.12.0, which has no QNN support at
  all. Do not rely on it alone.

---

## GenieX v0.8.0 first-token penalty

**Status: resolved as a non-issue.** An upstream report was drafted and
deliberately dropped.

### Symptom

After upgrading to GenieX v0.8.0, one-shot `geniex infer` on the llama.cpp NPU
path showed time-to-first-token rising from 0.10 s to 1.6–1.8 s — initially
written up as a 13–18x prefill regression.

### What the first write-up got wrong

It was measured **only** through one-shot `geniex infer`. Challenged with a
direct question about which version the numbers came from, the measurement was
redone across more axes, and the picture changed completely:

| How it is driven | Engine | v0.7.0 | v0.8.0 |
| --- | --- | --- | --- |
| `geniex infer`, one-shot | llama.cpp NPU | 0.10 s | **1.6–1.8 s** |
| `geniex infer`, one-shot | QAIRT NPU | 0.10 s | 0.1 s — unaffected |
| `geniex-bench`, 512-tok prompt | llama.cpp NPU | 365 ms | 375 ms — unaffected |
| `geniex-bench`, 512-tok prompt | QAIRT NPU | 246 ms | 246 ms — unaffected |

Over `geniex serve`, the first request cost 13.8 s (model load plus init) and
subsequent ones settled at 3.9 s for 120 tokens — roughly the pure generation
time.

### Root cause

A **one-time, per-process initialisation cost** on the llama.cpp path. Not a
prefill regression. `geniex-bench` hides it by measuring after warm-up; a server
pays it once at startup; only repeated one-shot CLI invocations feel it.

Independently reconfirmed twice since: by re-running the full `geniex-bench`
matrix after a clean v0.8.0 reinstall (prefill reproduced within 2.5 % across
the major version), and by the benchmark history, which recorded throughput
moving 65.2 → 62.4 tok/s, inside run-to-run noise, while first-token went
0.00 → 1.20 s.

### Lessons that survive

- **A latency change with throughput held constant is an initialisation cost,
  not a slower runtime.** Averaging the two into one "it got slower" impression
  destroys exactly the distinction that identifies it.
- One harness is not a measurement. The same build looked 13–18x worse or
  entirely unaffected depending on how it was driven.
- Not every finding is worth an upstream issue. This one was too narrow to be
  worth a maintainer's attention, and the first draft mischaracterised it.

---

## ORT GenAI prefill moved 1.7x with no known cause

**Status: unexplained, and now unexplainable.**

Re-running [`bench_ort_genai.py`](../src/setup/bench_ort_genai.py) on
`Phi-4-mini-reasoning-onnx` gave substantially better numbers than the recorded
ones:

| | TTFT | Prefill | Decode |
| --- | --- | --- | --- |
| recorded | 1996 ms | 256.5 tok/s | 14.1 tok/s |
| re-measured | 1172 ms | **436.9 tok/s** | 17.5 tok/s |

Three repetitions came in at 436.3, 441.6 and 432.9 tok/s, so it is not noise.

**One candidate was tested and ruled out.** Foundry Local had been fully
uninstalled during the Adreno investigation, making its absence a plausible
explanation. Reinstalling it (0.10.3, service idle) and re-running gave 404.2
tok/s — within run-to-run variance of 436.9, and nowhere near 256.5. A *running*
Foundry service remains untested.

The ONNX Runtime versions were unchanged (1.30.0 / 0.17.1 / QNN 2.6.0) and this
path does not touch GenieX, which rules out the other obvious candidates and
leaves the driver, the OS build or thermal state — none of which can be checked
retroactively, because **the original measurement predates the benchmark history
and carries no record of the stack it ran under**.

### Consequence

Two claims derived from the old number were wrong and were corrected: the
prefill gap to llama.cpp NPU is 3.5x rather than 6x, and ORT GenAI is no longer
*below* llama.cpp running on CPU — at 436.9 against 296.6 it is clearly above.

### Lesson that survives

This is the gap the benchmark history exists to close, demonstrated at its own
expense. Every measurement is now stamped with a hash of the drivers, OS build,
runtime versions and engine revisions it ran under, precisely so that
"what changed?" is answerable later.

---

## Foundry Local's NPU catalogue shrank from 11 models to 2

**Status: current behaviour as of Foundry Local 0.10.3.** Recorded here because
it invalidated a planned experiment.

The README previously recorded 11 NPU-targeted models in Foundry Local's
catalogue, 6 of them supporting tool calling — the whole Qwen2.5 family
including `qwen2.5-7b` and three `qwen2.5-coder` variants.

Re-checked on 0.10.3, `foundry model list` reports **two** NPU-targeted models:

| Model | Size | Device | Tools |
| --- | --- | --- | --- |
| `qwen2.5-0.5b` | 442 MB | NPU | yes |
| `phi-3.5-mini` | 2.0 GB | NPU | no |

`foundry model info qwen2.5-7b` offers **no NPU variant at all** — only
`generic-gpu` (WebGPU, 5.2 GB) and `generic-cpu` (6.2 GB). `qwen2.5-1.5b`,
`qwen2.5-14b` and every `qwen2.5-coder` size now route to GPU.

Whether Foundry withdrew those variants or re-targeted them for this machine is
not something the CLI explains.

### Consequence

A backlog item to verify tool calling on `qwen2.5-7b` could not be run as
written. It was redirected to `qwen2.5-0.5b`, and one of its three risks — that
a 6.8 GB NPU model might not hold context without paging — became untestable,
since the largest NPU model now published is 2.0 GB.

### Lesson that survives

A vendor catalogue is not a stable interface. Model availability and device
targeting can change between CLI versions, so capability claims should be
re-checked rather than cited from notes.

---

## A silently ignored provider list invalidated three conclusions

**Status: resolved.** The rule now lives in the README; this records the damage.

`providers=["QNNExecutionProvider"]` does **not** attach the QNN execution
provider. It is silently ignored, the session runs entirely on CPU, and nothing
warns you. Verbose ORT logging shows only *"Adding default CPU execution
provider"* followed by *"All nodes placed on [CPUExecutionProvider]"* — no QNN
initialization line at all.

Measured on `squeezenet1_1` w8a8, same model and machine:

| Attachment | Nodes on QNN |
| --- | --- |
| `providers=["QNNExecutionProvider"]` | **0 / 49** — all CPU |
| `set_provider_selection_policy(PREFER_NPU)` | **1 / 1** — whole graph fused |

### Why it is in the archive

Three separate conclusions recorded in earlier revisions of the README were
drawn from sessions that were silently running on CPU, and all three were wrong:

1. That Phi-4 was blocked by a `soc_model: 60` versus 88 chipset mismatch.
2. That X Elite context binaries were incompatible with X2 Elite.
3. That the `EPContext ... not compatible` error indicated a hardware problem.

The error's exact wording was the clue that was missed: *"not compatible with
any execution provider **added to the session**"*. Nothing had been added.

### Lesson that survives

**Never trust a successful `run()` as evidence of placement.** Confirm with
profiling, or set `session.disable_cpu_ep_fallback` to turn a silent fallback
into a hard error. Both are in the README.

---

# Superseded measurements

Kept so that older notes and commit messages remain interpretable. **Do not
compare these against current numbers** — the stacks differ.

## Benchmarks, 2026-09-19

GenieX v0.7.0 (llama.cpp `4ff829e`), Adreno driver **32.0.163.2**. Q4_0 GGUF,
400 tokens, 3 runs, `burst`, on AC:

| Model | Compute | Tok/s | First token (s) | Startup (s) |
| --- | --- | --- | --- | --- |
| Qwen3-4B | `npu` | 29.1 | 0.10 | 6.30 |
| Qwen3-4B | `cpu` | 27.5 | 0.23 | 2.29 |
| Qwen3-4B | `gpu` | 24.6 | 0.20 | 5.27 |
| Qwen3-1.7B | `npu` | 65.3 | 0.00 | 4.51 |
| Qwen3-1.7B | `cpu` | 53.4 | 0.03 | 1.79 |
| Qwen3-1.7B | `gpu` | 49.0 | 0.10 | 3.52 |

The throughput ordering — NPU > CPU > GPU at both sizes — has held across a
GenieX major version and two driver updates.

## Prefill/decode, GenieX v0.7.0

| Plugin | Device | TTFT | Prefill tok/s | Decode tok/s |
| --- | --- | --- | --- | --- |
| qairt | NPU | 246 ms | 2079.7 | 29.5 |
| llama.cpp | NPU | 365 ms | 1414.8 | 16.5 |
| llama.cpp | GPU | 1570 ms | 326.8 | 22.4 |
| llama.cpp | CPU | 2144 ms | 238.9 | 28.5 |

## Other superseded figures

| Figure | Superseded by |
| --- | --- |
| ORT GenAI Phi-4: 1996 ms / 256.5 prefill / 14.1 decode | 1172 ms / 436.9 / 17.5 — see the case study above |
| ORT GenAI Phi-4: 17.1 tok/s on 0.15.2 | Not directly comparable; measured on a different version and token budget |
| Foundry Local phi-3.5-mini: 26.5 tok/s, CPU 53.6 % | 27.7 tok/s; the CPU figure is not like-for-like, see BENCHMARKS |
| Phi-4 GGUF via GenieX: 24.1 tok/s | Superseded by the prefill/decode matrix |
| Adapter LUIDs `0x00013d0d`, `0x000152a6`, `0x0001501b`, `0x000151f3`, `0x133c8`, `0x000148c0` | **All stale by design.** LUIDs are assigned per boot; re-derive them, never cite them |

---

# Corrections to earlier claims

Every claim an earlier revision of the README stated and later had to withdraw.

| Earlier claim | Correction |
| --- | --- |
| "CPU beats NPU on throughput" | An artifact of benchmarking a cold machine with short generations. The CPU throttles ~19 % under sustained load; the NPU holds steady and finishes ahead at both model sizes |
| "Phi-4 is blocked by a `soc_model: 60` chipset mismatch" | Wrong. X Elite binaries load cleanly on X2 Elite; all four context binaries open with only a benign file-mapping warning. `soc_model` was a red herring |
| "Phi-4 is blocked by a hybrid graph; pinning an older onnxruntime-genai is the untested next step" | Superseded. The blocker was the 0.16.0 regression, fixed in 0.17.0, and the pin has been lifted. The hybrid graph (36 `EPContext` on NPU, 32 `GroupQueryAttention` on CPU) is real and explains the *prefill gap*, not a failure |
| "`providers=[...]` attaches the QNN provider" | It is silently ignored. Use the policy API |
| "No NPU performance counter exists" | It does. The probe enumerated `GPU Engine` instances *before* launching the workload, but those instances are per-process and did not exist yet |
| "`geniex` has a `--runtime` flag" | It does not. The engine is selected by model format. `geniex_llamacpp` / `geniex_qairt` are `qai-hub-models fetch` asset names |
| "GenieX v0.8.0 regressed NPU first-token by 13–18x" | A one-time per-process init cost on one-shot `geniex infer` only. See the case study above |
| "Foundry Local reports ORT GenAI 0.14.1" | On 0.10.3 that field reads `0.0.0` whether the server is stopped or ready. The figure no longer reproduces |
| "`qwen2.5-7b` is the largest NPU model with tool calling" | It has no NPU variant on 0.10.3. The largest is now `qwen2.5-0.5b` at 442 MB |
| "The AI Hub CLI will not install on ARM64" | Only half true. `qai-hub-models-cli` installs and runs natively; only the PyTorch-dependent export path is constrained |
| "`ATLAS_DATA_DIR` / `ATLAS_MODEL_DIR` / `ATLAS_RUN_DIR` are the cache convention" | A proposal only. Nothing reads them. `GENIEX_DATADIR` and `HF_HOME` are the variables that work |
| "Two model ids were fabricated" | They were not. Both came from Qualcomm's own documentation |

---

# Closed backlog items

| Item | Outcome |
| --- | --- |
| Scope of the 0.16.0 regression | **Closed.** Fixed in 0.17.0 via PR #2565, verified here |
| GenieX crashes on every GGUF model | **Resolved** by Adreno 32.0.172.2 |
| Lift the `onnxruntime-genai` pin | **Done.** Now `>=0.17.0`, resolving to 0.17.1, repro passing |
| NPU first-token regression | **Closed, not reported.** Scoped to a one-time init cost; upstream issue drafted and deliberately dropped |
| Benchmark ORT GenAI against GenieX GGUF for Phi-4 | **Closed.** All three runtimes measured on the same axes; see BENCHMARKS |
| Verify tool calling on the NPU | **Measured, with caveats.** Works on the NPU variant; NPU utilization during forced tool calls is well below a length-matched control. Redirected from `qwen2.5-7b`, which no longer has an NPU variant |
