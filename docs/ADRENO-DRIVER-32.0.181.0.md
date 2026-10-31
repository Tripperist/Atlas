# Adreno driver 32.0.181.0: GPU decode regression

**Finding, 2026-10-29.** After updating the Adreno graphics driver from **32.0.172.2** to **32.0.181.0**, the GPU
generates tokens **70 to 87 % more slowly** through llama.cpp's OpenCL backend. Nothing else moved: the NPU, the
CPU, and the GPU through WebGPU are unchanged. The result reproduced in both directions (new, old, new), on
identical software, on AC power. Stay on 32.0.172.2 for any GPU work until this is understood.

The measurements are tabulated in
[BENCHMARKS.md](BENCHMARKS.md#adreno-driver-3201810-against-3201722-2026-10-29). This page is the account of what
was done, what it shows, and what it does not.

## What was measured

The machine: Microsoft Surface Laptop, Snapdragon X2 Elite (X2E78100), Adreno X2-85, 64 GB, Windows 11 ARM64
build 28120, NPU driver 30.0.228.10000. Everything below was on AC power at 100 % battery, power scheme
Balanced, with the CPU idle at the start of each run.

The software stack was identical in the two `stack-compare` runs: GenieX v0.9.3 (llama.cpp `e467e5b`), Foundry
Local 0.12.1, ONNX Runtime 1.30.0, `onnxruntime-genai` 0.17.1, `onnxruntime-qnn` 2.7.0, Atlas code `bb4cf1d`.
`Compare-BenchStacks` lists exactly one difference between the two stacks, `drivers.adreno`.

| | Before | After |
| --- | --- | --- |
| Adreno driver | 32.0.172.2 | 32.0.181.0 |
| Stack | `50595dce79eb` | `b1e7645e6ede` |
| Run folder | `20261029-145037-stack-compare` | `20261029-151203-stack-compare` |
| Canary | ok before and after | abort before and after (suite run with `-IgnoreCanary`) |

The order was deliberate: the new driver was installed and the canary run, the old one restored and the full suite
run, then the new one installed again and the suite re-run. That is new, old, new, so a drift in the machine
during the afternoon cannot account for it.

## What changed

**GPU decode, through llama.cpp's OpenCL backend (stock b10566 and GenieX's build):**

| Measurement | 32.0.172.2 | 32.0.181.0 | Change |
| --- | --- | --- | --- |
| Qwen3-0.6B, stock llama.cpp, decode | 98.1 tok/s | 12.8 | **−87 %** |
| Qwen3-4B, GenieX llama.cpp, decode | 29.5 | 9.0 | **−69 %** |
| Qwen3-4B, short-prompt decode | 31.2 | 8.9 | **−72 %** |
| Qwen3-Coder-30B, stock llama.cpp, decode | 26.8 | 5.9 | **−78 %** |
| Qwen3-Coder-30B, stock llama.cpp, **prefill** | 248 | 68 | **−73 %** |

On the new driver the 4B model decodes at about 9 tok/s on the GPU, against about 30 on the CPU and 29 to 32 on the
NPU: the GPU is no longer a useful place to generate tokens.

**Unchanged (every figure within about 5 %, the largest 8.8 %):**

- **The NPU.** QAIRT Qwen3-4B decode 33.7 to 32.8 tok/s and prefill 2,198 to 2,127; llama.cpp on the NPU
  (Qwen3-4B 29.0 to 28.7 decode, Phi-4-mini 31.2 to 31.6); ONNX Runtime GenAI from Python (16.3 to 16.7) and
  from C# (18.8 to 18.5). The NPU driver did not change, so this is the negative control.
- **The CPU.** Qwen3-4B 30.2 to 30.5 tok/s decode, Phi-4-mini 33.6 to 33.4, and both stock CPU controls
  (30B decode 40.0 to 41.5). The CPU result is the check that the machine itself was in the same state.
- **GPU prefill for the small models.** Qwen3-0.6B 1,184 to 1,202 tok/s (+1.5 %); Qwen3-4B 335 to 306 (−8.8 %,
  inside the noise of this figure). Only the 30B's GPU prefill collapsed.

**The canary reproduced the decode figure nine times.** The canary is a half-minute fixed run of the stock
llama.cpp on Qwen3-0.6B. On the old driver three runs gave GPU decode 98.2, 100.3 and 100.7 tok/s; on the new one
six runs gave 12.6 to 13.1, in the order new, old, new. The old driver's figure also matches the 24 readings taken
on 2026-10-17 (95.3 mean). GPU prefill in the canary fell by about 9 % (1,307 to 1,193), and CPU prefill and
decode did not move.

**WebGPU is not affected.** Foundry Local runs `qwen3-0.6b-generic-gpu:2` through ONNX Runtime GenAI's WebGPU
execution provider on the same Adreno. The same AtlasChat runs as on 2026-10-19 (old driver), repeated today on the
new one: 89.4 to 90.7 tok/s decode against 87.9 to 90.9, with the same token counts from the greedy runs (929 and
689), so the same computation at the same speed. The GPU engine was 95 to 98 % busy before and 95 to 96 % now. The same model
through OpenCL is at 12.8 tok/s on the new driver, so WebGPU is about seven times faster on it.

## What this does and does not show

- **It shows** a large, reproducible, driver-specific slowdown of OpenCL token generation on the Adreno X2-85,
  on three model sizes and in two builds of llama.cpp (the stock release and GenieX's), with prefill spared for
  the small models.
- **It points at** the driver's OpenCL path, since the hardware, the model, the software and the WebGPU path on
  the same GPU are all unchanged. The CPU and the NPU do not move.
- **It does not show why.** Decode is the phase that collapsed (and prefill on the 30B), which suggests the
  kernels llama.cpp uses for token generation, but no profiling was done and that is only a guess.
- **WebGPU was checked on one model**, Qwen3-0.6B, and not on the 4B or the 30B. The OpenCL regression was widest
  on the larger ones.
- **The GenieX 30B on the GPU** was re-run on the new driver at a 512-token prompt only (decode 4.9 tok/s, prefill
  67.5, against 31.6 and 288 on GenieX v0.9.0 on the old driver; a different GenieX version). The long-context runs
  (`longctx`, `genie-30b`) were not re-run. The 0.6B, 1.7B and 30B GenieX GPU figures are in the
  [data sheet](data/adreno-driver-32.0.181.0.md); there is no old-driver GenieX baseline for the 0.6B or 1.7B.
- **The pre-update run is healthy**: its canary passed before and after, and its figures are within about 13 % of
  the 2026-10-17 baseline, which was taken on GenieX v0.9.0 (the largest gaps are QAIRT prefill, −13 %, and the
  4B on the CPU, +12 %). It ran about twenty minutes before the post-update run.
- **No other cause was ruled out by experiment**, but the workspace reports one changed component, and the three
  controls (CPU, NPU, WebGPU) did not move.

## Where this leaves the workspace

- The recorded baseline (`50595dce79eb`) is still the **old** driver; do **not** run
  `Update-Workspace.ps1 -Accept` on the new one. An accepted baseline claims that the combination worked.
- Do **not** run `Export-BenchResults.ps1` while on the new driver. It publishes the latest AC session of each
  cell, and for every GPU cell that is now the slow one. The published tables in BENCHMARKS.md ("Current
  figures") were generated before this and still show the old driver's figures.
- The history holds both. `Compare-BenchStacks.ps1 -From 50595dce -To b1e7645e` reproduces the comparison.
  Its headline says "A control moved", because the stock GPU control is the thing under test here: read the
  GPU control rows as the result, and the CPU control rows as the machine-state check.

## Reproducing it

On the old driver, then the new:

```powershell
.\Scripts\Invoke-BenchCanary.ps1                                   # about a minute: GPU decode 98 against 13 tok/s
.\Scripts\Invoke-BenchSuite.ps1 -Suite stack-compare -IgnoreCanary # about 10 minutes (the canary aborts on the new driver)
.\Scripts\Compare-BenchStacks.ps1 -From 50595dce -To b1e7645e
```

The smallest reproducer, with nothing from this repository: the stock llama.cpp b10566 Windows ARM64 OpenCL
release (`llama-b10566-bin-win-opencl-adreno-arm64.zip`, SHA256
`d78bd4db577eff9f8e3d77fe43e921c2c43aed9bacb35350723b23eaf373decd`) and
`unsloth/Qwen3-0.6B-GGUF` `Qwen3-0.6B-Q4_0.gguf`:

```powershell
llama-bench.exe -m Qwen3-0.6B-Q4_0.gguf -ngl 99 -p 256 -n 32 -r 2
```

Expect about 98 tok/s on the `tg32` line on 32.0.172.2 and about 13 on 32.0.181.0, with the CPU (`-ngl 0`) at
about 180 on both.

## Next steps

1. Roll the driver back to 32.0.172.2 for GPU work, and keep the installer for 32.0.181.0 so it can be retried.
2. Report it, with the reproducer above, to Qualcomm (the driver) and to the llama.cpp OpenCL backend's Adreno
   maintainers. Not done; a plain data sheet to write the report from is [data/adreno-driver-32.0.181.0.md](data/adreno-driver-32.0.181.0.md); llama.cpp requires such reports to be written by the person filing them.
3. Re-test each new Adreno driver with the canary first: its GPU decode figure caught this in one minute.
4. Optional, to learn how far it reaches: a larger Foundry GPU model on WebGPU (for example `qwen3-4b`), the
   GenieX 30B on the GPU, and the 1.7B.
