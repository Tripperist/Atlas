# Data sheet: Adreno driver 32.0.172.2 and 32.0.181.0, llama.cpp OpenCL, 2026-10-29

Measurements only. No interpretation: that is in [../ADRENO-DRIVER-32.0.181.0.md](../ADRENO-DRIVER-32.0.181.0.md)
and [../BENCHMARKS.md](../BENCHMARKS.md#adreno-driver-3201810-against-3201722-2026-10-29).

## System

| | |
| --- | --- |
| Machine | Microsoft Surface Laptop, Snapdragon X2 Elite (X2E78100), 64 GB |
| GPU | Qualcomm Adreno X2-85 |
| Adreno driver, before / after | 32.0.172.2 / 32.0.181.0 |
| NPU driver (both) | 30.0.228.10000 |
| OS (both) | Windows 11 ARM64, 10.0.28120 |
| Power | AC, battery 100 %, scheme Balanced, CPU idle at the start of each run |

## Software (identical before and after)

| | |
| --- | --- |
| llama.cpp (stock) | b10566, `bb4caa754`, asset `llama-b10566-bin-win-opencl-adreno-arm64.zip`, SHA256 `d78bd4db577eff9f8e3d77fe43e921c2c43aed9bacb35350723b23eaf373decd` |
| GenieX | v0.9.3 (llama.cpp `e467e5b`) |
| Foundry Local | 0.12.1 |
| ONNX Runtime / GenAI / QNN | 1.30.0 / 0.17.1 / 2.7.0 |
| Models | `unsloth/Qwen3-0.6B-GGUF` `Qwen3-0.6B-Q4_0.gguf`; `unsloth/Qwen3-4B-GGUF` Q4_0; `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF` Q4_0 |

## GenieX was benchmarked and shows the same slowdown

GenieX (v0.9.3, which runs GGUF models on its bundled llama.cpp `e467e5b`, OpenCL backend for the GPU) was measured
on both drivers with two of its own tools, in the same two `stack-compare` runs as everything else below. On the GPU
it is affected; on the CPU and NPU it is not.

| GenieX measurement (Qwen3-4B Q4_0, GGUF, llama.cpp engine) | 32.0.172.2 | 32.0.181.0 | Change |
| --- | --- | --- | --- |
| GPU decode, `geniex-bench`, 512-token prompt (tok/s) | 29.54 | 9.04 | −69 % |
| GPU decode, `geniex infer --compute gpu`, short prompt (tok/s) | 31.2 | 8.9 | −72 % |
| GPU prefill, `geniex-bench`, 512 tokens (tok/s) | 335.07 | 305.71 | −8.8 % |
| GPU first token, `geniex-bench`, 512 tokens (s) | 1.53 | 1.68 | +0.15 s |
| CPU decode, `geniex-bench` / `geniex infer` (tok/s) | 30.21 / 33.7 | 30.49 / 32.0 | +0.9 % / −5 % |
| NPU decode, `geniex-bench` / `geniex infer` (tok/s) | 28.97 / 31.4 | 28.69 / 31.6 | −1.0 % / +0.6 % |
| NPU decode, QAIRT engine, `geniex-bench` (tok/s) | 33.68 | 32.80 | −2.6 % |

GenieX's CPU and NPU paths, and its QAIRT engine, did not move; only the GPU path did. The stock llama.cpp b10566
control on the same GPU fell by a similar amount (Qwen3-0.6B decode 98.12 to 12.84 tok/s, Qwen3-Coder-30B decode
26.80 to 5.86), so the slowdown is not specific to GenieX's build. GenieX's repository
(`qualcomm/GenieX`, commit `d66de04`) builds llama.cpp with `GGML_OPENCL` on and carries three Adreno OpenCL patches
(`sdk/patches/llama-opencl-adreno-*.patch`); the QAIRT engine ignores `--compute`.

### More GenieX models, GPU and CPU, on 32.0.181.0 only (2026-10-31)

The same two tools on three more models, all Q4_0 GGUF through the llama.cpp engine, run on the new driver after the
suite runs above (AC power, battery 100 %, Balanced, CPU 3 to 5 % busy at the start of each step, nothing else
running). Prefill is a 512-token prompt, 3 repeats; `geniex infer` is the 160-token short-prompt run, 3 runs per unit.
Stock llama.cpp b10566 on the same driver is from the `stack-compare` run above.

| Model | Tool | GPU decode | GPU prefill | GPU first token | CPU decode | CPU prefill |
| --- | --- | --- | --- | --- | --- | --- |
| Qwen3-0.6B | `geniex-bench` | 11.79 | 1,291.08 | 397 ms | 110.95 | 1,339.26 |
| Qwen3-0.6B | `geniex infer` | 11.80 | | 0.1 s | 121.10 | |
| Qwen3-1.7B | `geniex-bench` | 11.66 | 681.33 | 752 ms | 59.39 | 551.07 |
| Qwen3-1.7B | `geniex infer` | 11.30 | | 0.2 s | 60.90 | |
| Qwen3-Coder-30B | `geniex-bench` | 4.88 | 67.53 | 7,582 ms | 29.52 | 125.92 |
| Qwen3-Coder-30B | `geniex infer` | 4.70 | | 0.6 s | 32.90 | |

Same driver, stock llama.cpp b10566 for comparison: Qwen3-0.6B GPU decode 12.84, prefill (256) 1,201.80; Qwen3-Coder-30B
GPU decode 5.86, prefill 68.19. The Qwen3-1.7B was not run on stock llama.cpp.

Old-driver GenieX figures for the same cells: there are none for the Qwen3-0.6B or the Qwen3-1.7B. For the
Qwen3-Coder-30B (`geniex-bench`, 512-token prompt, 32.0.172.2) the history holds GenieX v0.9.0 on 2026-10-17, on AC
power: decode 31.57, prefill 288.48. Earlier sessions on the same driver (GenieX v0.8.0 and v0.9.0, 2026-10-15 and
10-16) gave decode 17.42 to 28.9 and prefill 285.8 to 302.9; those records do not say whether the machine was on AC
power. The 30B was run with `-CtxSize 4096`; the others used the model default. The GenieX version differs from the
v0.9.3 used on the new driver.

A first pass of the 0.6B and 1.7B steps (15:09 to 15:25) overlapped a background file search (`find`, about one
core); the harness warned at the start of those steps and the CPU figures were far too low (0.6B CPU decode 1.5 to
5 tok/s). Those eight records are marked `valid = false` in the history and the figures above are from a rerun on the
idle machine (15:32 to 15:38). The 30B steps ran after the search had finished and were not rerun.

Not measured with GenieX: the `geniex serve` OpenAI-compatible endpoint on the GPU, the long-context runs
(`longctx`, 896 to 6,784 tokens) on the new driver, any quantisation other than Q4_0, any model other than the four
above, and any GenieX build other than v0.9.3.

## Commands

```text
llama-bench.exe -m Qwen3-0.6B-Q4_0.gguf -ngl 99 -p 256 -n 32 -r 3     (GPU)
llama-bench.exe -m Qwen3-0.6B-Q4_0.gguf -ngl 0  -p 256 -n 32 -r 3     (CPU)
llama-bench.exe -m Qwen3-Coder-30B-A3B-Instruct-Q4_0.gguf -ngl 99 -p 512 -n 128 -r 1   (30B, GPU)
llama-bench.exe -m Qwen3-Coder-30B-A3B-Instruct-Q4_0.gguf -ngl 0  -p 512 -n 128 -r 1   (30B, CPU)
```

GenieX v0.9.3, `geniex-bench` (512-token prompt, 128 generated tokens, 3 repeats; reports the median of the repeats):

```text
geniex-bench.exe --plugin llama_cpp --device gpu -m unsloth/Qwen3-4B-GGUF:Q4_0 -p 512 -n 128 -r 3                       (4B, GPU)
geniex-bench.exe --plugin llama_cpp --device cpu -m unsloth/Qwen3-4B-GGUF:Q4_0 -p 512 -n 128 -r 3                       (4B, CPU)
geniex-bench.exe --plugin llama_cpp --device npu -m unsloth/Qwen3-4B-GGUF:Q4_0 -p 512 -n 128 -r 3                       (4B, NPU)
geniex-bench.exe --plugin qairt     --device npu -m qualcomm/Qwen3-4B:W4A16 -p 512 -n 128 -r 3                          (4B, QAIRT, NPU)
geniex-bench.exe --plugin llama_cpp --device cpu -m unsloth/Phi-4-mini-reasoning-GGUF:Q4_0 -p 512 -n 128 -r 3           (Phi-4-mini, CPU)
geniex-bench.exe --plugin llama_cpp --device npu -m unsloth/Phi-4-mini-reasoning-GGUF:Q4_0 -p 512 -n 128 -r 3           (Phi-4-mini, NPU)
geniex-bench.exe --plugin llama_cpp --device gpu -m unsloth/Qwen3-0.6B-GGUF:Q4_0 -p 512 -n 128 -r 3                     (0.6B, GPU; new driver only)
geniex-bench.exe --plugin llama_cpp --device cpu -m unsloth/Qwen3-0.6B-GGUF:Q4_0 -p 512 -n 128 -r 3                     (0.6B, CPU; new driver only)
geniex-bench.exe --plugin llama_cpp --device gpu -m unsloth/Qwen3-1.7B-GGUF:Q4_0 -p 512 -n 128 -r 3                     (1.7B, GPU; new driver only)
geniex-bench.exe --plugin llama_cpp --device cpu -m unsloth/Qwen3-1.7B-GGUF:Q4_0 -p 512 -n 128 -r 3                     (1.7B, CPU; new driver only)
geniex-bench.exe --plugin llama_cpp --device gpu -m unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_0 -p 512 -n 128 -r 3 -c 4096   (30B, GPU; new driver only)
geniex-bench.exe --plugin llama_cpp --device cpu -m unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_0 -p 512 -n 128 -r 3 -c 4096   (30B, CPU; new driver only)
```

GenieX v0.9.3, `geniex infer` (short prompt, 160 tokens; each line run 3 times per model and unit, the units
interleaved and the order reversed on alternate rounds; one warm-up call per model, excluded:
`geniex infer <model> -p 'hi' --max-tokens 8 --think=false`):

```text
geniex infer unsloth/Qwen3-4B-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute gpu --power-mode burst --seed 42 --think=false   (4B, GPU)
geniex infer unsloth/Qwen3-4B-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute cpu --power-mode burst --seed 42 --think=false   (4B, CPU)
geniex infer unsloth/Qwen3-4B-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute npu --power-mode burst --seed 42 --think=false   (4B, NPU)
geniex infer unsloth/Qwen3-0.6B-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute gpu --power-mode burst --seed 42 --think=false   (0.6B, GPU; new driver only)
geniex infer unsloth/Qwen3-0.6B-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute cpu --power-mode burst --seed 42 --think=false   (0.6B, CPU; new driver only)
geniex infer unsloth/Qwen3-1.7B-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute gpu --power-mode burst --seed 42 --think=false   (1.7B, GPU; new driver only)
geniex infer unsloth/Qwen3-1.7B-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute cpu --power-mode burst --seed 42 --think=false   (1.7B, CPU; new driver only)
geniex infer unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute gpu --power-mode burst --seed 42 --think=false   (30B, GPU; new driver only)
geniex infer unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_0 -p "Explain how a lithium-ion battery works, in detail." --max-tokens 160 --compute cpu --power-mode burst --seed 42 --think=false   (30B, CPU; new driver only)
```

`geniex-bench.exe` is the harness published with the GenieX release (`geniex-bench-windows-arm64-v0.9.3.zip`). The
repository's wrappers run these lines and record the results: `Scripts/Invoke-BenchPrefill.ps1` (`-Matrix` for the
first six; `-Model <model> -Plugin llama_cpp -Device gpu,cpu`, and `-CtxSize 4096` for the 30B, for the rest) and
`Scripts/Invoke-BenchDecode.ps1` (`-Model <model> -Compute gpu,cpu[,npu] -Repeat 3`). The wrapper adds `--output-json
<file>` to each `geniex-bench` line. `--compute` and `--device` have no effect on the QAIRT bundle.

The 0.6B "runs" below are the same command with `-p 256 -n 32 -r 1 -o json`, two rounds (GPU first, then CPU first),
reported as the mean of the two rounds. The 30B rows are 3 interleaved rounds, the median.

## llama-bench output captured on 32.0.181.0 (0.6B, `-r 3`)

```text
| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |  99 |           pp256 |      1183.38 ± 25.35 |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |  99 |            tg32 |         12.58 ± 0.02 |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |   0 |           pp256 |      1635.23 ± 24.97 |
| qwen3 0.6B Q4_0                | 358.78 MiB |   596.05 M | OpenCL     |   0 |            tg32 |       162.10 ± 18.44 |

build: bb4caa754 (10566)
```

`llama-bench` reports `gpu_info` "Qualcomm(R) Adreno(TM) X2-85 GPU", `cpu_info` "Snapdragon X2 Elite @ 4.03 GHz",
`backends` "OpenCL". No `llama-bench` table was captured on 32.0.172.2.

## 0.6B, tok/s, one row per run (mean of 2 rounds)

| Time | Driver | GPU `tg32` | GPU `pp256` | CPU `tg32` | CPU `pp256` |
| --- | --- | --- | --- | --- | --- |
| 2026-10-29 14:35 | 181.0 | 13.0 | 1,164 | 189 | 1,645 |
| 2026-10-29 14:41 | 181.0 | 12.6 | 1,196 | 159 | 1,503 |
| 2026-10-29 14:42 | 181.0 | 13.1 | 1,193 | 188 | 1,664 |
| 2026-10-29 14:49 | 172.2 | 100.3 | 1,355 | 195 | 1,685 |
| 2026-10-29 14:50 | 172.2 | 100.7 | 1,303 | 184 | 1,556 |
| 2026-10-29 15:06 | 172.2 | 98.2 | 1,264 | 184 | 1,544 |
| 2026-10-29 15:11 | 181.0 | 13.0 | 1,194 | 187 | 1,572 |
| 2026-10-29 15:12 | 181.0 | 13.0 | 1,217 | 191 | 1,560 |
| 2026-10-29 15:25 | 181.0 | 12.9 | 1,193 | 188 | 1,565 |
| 2026-10-17 (12 readings) | 172.2 | mean 95.3, range 93 to 97 | mean 1,508, range 1,352 to 1,792 | mean 166, range 127 to 187 | mean 1,541, range 1,363 to 1,662 |

The driver was changed between 14:42 and 14:49 (to 172.2) and between 15:06 and 15:11 (to 181.0).

## Full suite runs, same software, only the driver differs

Run folders `20261029-145037-stack-compare` (172.2, stack `50595dce79eb`) and `20261029-151203-stack-compare` (181.0,
stack `b1e7645e6ede`). Each has 21 figures. Prefill is tok/s on a 512-token prompt unless stated; decode is tok/s.

**GPU, OpenCL**

| Model, build, test | 172.2 | 181.0 |
| --- | --- | --- |
| Qwen3-0.6B, stock, `-p 256 -n 32`: decode | 98.12 | 12.84 |
| Qwen3-0.6B, stock: prefill (256) | 1,184.49 | 1,201.80 |
| Qwen3-4B, GenieX llama.cpp: decode | 29.54 | 9.04 |
| Qwen3-4B, GenieX llama.cpp: prefill | 335.07 | 305.71 |
| Qwen3-4B, GenieX llama.cpp: first token (s) | 1.53 | 1.68 |
| Qwen3-4B, short prompt, 160 tokens: decode | 31.2 | 8.9 |
| Qwen3-4B, short prompt: first token (s) | 0.2 | 0.3 |
| Qwen3-Coder-30B, stock, `-p 512 -n 128`: decode | 26.80 | 5.86 |
| Qwen3-Coder-30B, stock: prefill | 248.36 | 68.19 |

**CPU**

| Model, build, test | 172.2 | 181.0 |
| --- | --- | --- |
| Qwen3-0.6B, stock: decode / prefill | 181.11 / 1,671.77 | 187.18 / 1,692.12 |
| Qwen3-4B, GenieX llama.cpp: decode / prefill | 30.21 / 264.07 | 30.49 / 261.12 |
| Qwen3-4B, short prompt: decode | 33.7 | 32.0 |
| Phi-4-mini-reasoning, GenieX llama.cpp: decode / prefill | 33.56 / 313.22 | 33.42 / 318.91 |
| Qwen3-Coder-30B, stock: decode / prefill | 40.04 / 126.25 | 41.53 / 134.18 |

**NPU (separate driver, unchanged)**

| Model, runtime | 172.2 | 181.0 |
| --- | --- | --- |
| Qwen3-4B, QAIRT: decode / prefill | 33.68 / 2,197.58 | 32.80 / 2,127.32 |
| Qwen3-4B, GenieX llama.cpp: decode / prefill | 28.97 / 1,482.48 | 28.69 / 1,486.89 |
| Qwen3-4B, short prompt: decode | 31.4 | 31.6 |
| Qwen3-1.7B, short prompt: decode | 68.4 | 67.8 |
| Phi-4-mini-reasoning, GenieX llama.cpp: decode / prefill | 31.18 / 1,638.17 | 31.56 / 1,649.95 |
| Phi-4-mini-reasoning, ONNX Runtime GenAI, Python: decode / prefill | 16.32 / 405.70 | 16.69 / 413.80 |
| Phi-4-mini-reasoning, ONNX Runtime GenAI, C#: decode / prefill | 18.80 / 456.80 | 18.53 / 453.50 |

## GPU through WebGPU (Foundry Local, `qwen3-0.6b-generic-gpu:2`)

Streamed, open-ended prompt ("Write a long, detailed essay about the history of maritime navigation."), 60-second
limit, one run each, console runs.

| Run | 172.2 (2026-10-19) | 181.0 (2026-10-29) |
| --- | --- | --- |
| Session API, greedy: tok/s, tokens | 87.9, 929 | 90.1, 929 |
| Chat client API, greedy: tok/s, tokens | 90.9, 689 | 89.9, 689 |
| Session API, SDK defaults: tok/s | 88.2 | 90.7 |
| Chat client API, SDK defaults: tok/s | 90.9 | 89.4 |
| GPU engine utilization | 95 to 98 % | 95 to 96 % |

## llama.cpp OpenCL: Adreno xmem GEMM setting, new driver only (2026-10-31)

Run on 32.0.181.0, AC power, battery 100 %, scheme Balanced, stock b10566, GPU (`-ngl 99`). The two settings were
interleaved, one after the other in each round; each cell is `llama-bench` `avg_ts` in tok/s, per round, then the
median. The 0.6B used `-p 256 -n 32 -r 3` (2 rounds); the 30B used `-p 512 -n 128 -r 1` (3 rounds).

```text
GGML_OPENCL_ADRENO_XMEM_GEMM unset      (xmem off in b10566)
GGML_OPENCL_ADRENO_XMEM_GEMM=0          (xmem on in b10566: the variable only has to be set)
```

In b10566 (`ggml-opencl.cpp`, line 5997) `adreno_xmem_gemm_enabled` is `getenv("GGML_OPENCL_ADRENO_XMEM_GEMM") != nullptr`
on Adreno, so any value, including `0`, enables it. Upstream `19cce69` (2026-10-27) reads the value and defaults to on.

| Test | Variable unset | Variable set to `0` |
| --- | --- | --- |
| Qwen3-0.6B prefill (256) | 1,216.73 / 1,230.11, median 1,223.42 | 1,213.26 / 1,186.34, median 1,199.80 |
| Qwen3-0.6B decode | 11.97 / 11.86, median 11.91 | 11.91 / 11.85, median 11.88 |
| Qwen3-Coder-30B prefill (512) | 70.56 / 70.49 / 70.26, median 70.49 | 69.38 / 70.09 / 70.50, median 70.09 |
| Qwen3-Coder-30B decode | 5.28 / 6.00 / 6.18, median 6.00 | 6.03 / 6.01 / 5.34, median 6.01 |

Enabling the xmem path did not change any figure outside the run-to-run spread. The models are Q4_0; the xmem path
is described upstream as an F16 x F32 GEMM. Not run on 32.0.172.2. `llama-bench -o json` left the output array
without its closing `]` and the wrapper script exited with code 5; all ten files held complete results.

## Not measured

- The 4B and 30B models through WebGPU.
- The GenieX long-context runs (`longctx`, `genie-30b`) on 32.0.181.0; the GenieX 30B was measured at a 512-token
  prompt only.
- The GenieX 0.6B, 1.7B and 30B on 32.0.172.2 with the v0.9.3 harness; see the GenieX section for the baselines that
  exist.
- A `llama-bench` table on 32.0.172.2 (the figures above for that driver come from the wrapper's JSON runs).
- Any profile, driver log, or OpenCL kernel timing.
- Driver versions other than 32.0.172.2 and 32.0.181.0.
- Machines other than the one above.

## Where the raw data is

Suite output: `.atlas-local/benchmarks/runs/20261029-145037-stack-compare` and `...-151203-stack-compare` (git-ignored,
on the measuring machine): `summary.md`, `records.jsonl`, `canary.json`, a log per step. History records:
`.atlas-local/benchmarks/history.jsonl`, stacks `50595dce79eb` and `b1e7645e6ede`. `llama-bench ... -o json` prints the
per-sample times and the device strings. The xmem runs wrote ten JSON files to a session scratch folder outside the
repository; the figures in that table are copied from them.
