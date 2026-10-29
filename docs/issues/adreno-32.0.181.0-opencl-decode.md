# Adreno X2-85 driver 32.0.181.0: OpenCL token generation about 7x slower than 32.0.172.2 in llama.cpp (prefill unaffected)

*An issue-ready page: paste the body into a tracker. The longer account is in
[ADRENO-DRIVER-32.0.181.0.md](../ADRENO-DRIVER-32.0.181.0.md); the data is in
[BENCHMARKS.md](../BENCHMARKS.md#adreno-driver-3201810-against-3201722-2026-10-29). Not yet filed anywhere.*

## Summary

After updating the Qualcomm Adreno graphics driver from **32.0.172.2** to **32.0.181.0**, llama.cpp's OpenCL backend
generates tokens (`tg`) **70 to 87 % more slowly** on a Snapdragon X2 Elite. Prompt processing (`pp`) is
unchanged for small models. The CPU backend and a different GPU path (WebGPU, through ONNX Runtime GenAI) on the
same GPU are unchanged, and so is the NPU. It reproduced in both directions on identical software: new driver,
old driver restored, new driver again.

## Environment

- Microsoft Surface Laptop, Snapdragon X2 Elite (X2E78100), Adreno X2-85, 64 GB, Windows 11 ARM64 (10.0.28120)
- NPU driver 30.0.228.10000 (unchanged)
- llama.cpp **b10566** (`bb4caa754`), the official `ggml-org` release asset
  `llama-b10566-bin-win-opencl-adreno-arm64.zip`, SHA256
  `d78bd4db577eff9f8e3d77fe43e921c2c43aed9bacb35350723b23eaf373decd`
- Model: `unsloth/Qwen3-0.6B-GGUF`, `Qwen3-0.6B-Q4_0.gguf`
- On AC power, 100 % battery, power scheme Balanced, CPU idle

## Steps to reproduce

```powershell
llama-bench.exe -m Qwen3-0.6B-Q4_0.gguf -ngl 99 -p 256 -n 32 -r 3     # GPU, OpenCL
llama-bench.exe -m Qwen3-0.6B-Q4_0.gguf -ngl 0  -p 256 -n 32 -r 3     # CPU, for contrast
```

Run it on 32.0.172.2, then on 32.0.181.0.

## Actual result on 32.0.181.0

```text
| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |  99 |           pp256 |      1183.38 ± 25.35 |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |  99 |            tg32 |         12.58 ± 0.02 |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |   0 |           pp256 |      1635.23 ± 24.97 |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |   0 |            tg32 |       162.10 ± 18.44 |

build: bb4caa754 (10566)
```

(The `-ngl 99` and `-ngl 0` runs are two invocations; `llama-bench` labels both `OpenCL`, the backend it loaded.)

## Expected result (32.0.172.2)

`-ngl 99`, `tg32` about **93 to 101 tok/s**, `pp256` about 1,260 to 1,360. These come from the same command and
model run through a wrapper (`-p 256 -n 32`, two rounds per run): three runs that afternoon (98 to 101 tok/s) and
twelve readings on 2026-10-17 (mean 95.3, range 93 to 97). A `llama-bench` table from the old driver was not
captured in this form, since it was not installed when this page was written.

| | 32.0.172.2 | 32.0.181.0 |
| --- | --- | --- |
| Qwen3-0.6B Q4_0, GPU `tg32` | 93 to 101 tok/s | **12.6 to 13.1** (6 runs; 12.58 ± 0.02 above) |
| Qwen3-0.6B Q4_0, GPU `pp256` | 1,264 to 1,355 (3 runs) | 1,164 to 1,217 |
| Qwen3-0.6B Q4_0, CPU `tg32` | 184 to 195 (3 runs) | 159 to 191 |
| Qwen3-Coder-30B-A3B Q4_0, GPU `tg128` | 26.8 | **5.9** |
| Qwen3-Coder-30B-A3B Q4_0, GPU `pp512` | 248 | **68** |

The 30B row is the same build with `-ngl 99 -p 512 -n 128`, the median of 3 interleaved rounds. The 4B model through GenieX's
llama.cpp build (also OpenCL) went from 29.5 to 9.0 tok/s decode, so the effect is not specific to one build.

## What is not affected

- **CPU backend** (`-ngl 0`): within about 5 % on every model tried.
- **The NPU** (a separate driver), on several runtimes: within about 3 %.
- **WebGPU on the same Adreno**: Qwen3-0.6B through Foundry Local / ONNX Runtime GenAI's WebGPU execution
  provider decoded at 87.9 to 90.9 tok/s on 32.0.172.2 and 89.4 to 90.7 on 32.0.181.0, with identical output
  token counts, and the GPU engine equally busy. The same model through OpenCL is at 12.6 tok/s on 32.0.181.0.
- **`pp` for small models**: 0.6B +1.5 %, 4B -8.8 % (inside this figure's noise). The 30B's `pp` did fall.

## Notes

- The pattern (token generation collapses, prefill is spared except on the largest model) suggests the kernels used
  for single-token generation, but nothing was profiled and that is a guess.
- Nothing else changed between the two measurement sets (same llama.cpp binary, same model file, same OS build, same
  NPU driver); the only component that differs is the Adreno driver version.
- Happy to provide the raw `llama-bench` JSON from both drivers, or to test a driver build.

## Where to file it

The reproducer uses only the stock llama.cpp release, so the llama.cpp OpenCL backend's tracker (`ggml-org/llama.cpp`)
is the natural place, with Qualcomm's driver feedback channel for the driver itself.
