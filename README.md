# Atlas

Atlas is the model development workspace for Tripperist's **Scout** travel assistant: dataset preparation, fine-tuning, evaluation, and optimization for **local inference on Windows ARM64 / Qualcomm Snapdragon** hardware.

This README is the single entry point. It supersedes the former `Setup.MD` and `docs/Hardware.md`, and it distinguishes **verified** facts (measured on the target machine) from **untested** guidance.

- [1. Determining your hardware](#1-determining-your-hardware)
- [2. Verification status](#2-verification-status)
- [3. Choosing a stack](#3-choosing-a-stack)
- [4. Machine setup](#4-machine-setup)
- [5. Inference paths](#5-inference-paths)
- [6. Proving which compute unit actually runs](#6-proving-which-compute-unit-actually-runs)
- [7. Training and asset optimization](#7-training-and-asset-optimization)
- [8. Benchmarking](#8-benchmarking)
- [9. Atlas project scope](#9-atlas-project-scope)
- [10. Troubleshooting](#10-troubleshooting)

## Automation

Every manual sequence below is wrapped in a script. Each section still explains what the steps do and why — run the script, read the section when something fails.

| Script | Automates | Safe to run |
| --- | --- | --- |
| [`Scripts/Install-Prerequisites.ps1`](Scripts/Install-Prerequisites.ps1) | §4.1 toolchain | Reports only; `-Install` to act |
| [`Scripts/Initialize-Workspace.ps1`](Scripts/Initialize-Workspace.ps1) | §4.3 venv + deps | Yes |
| [`Scripts/Get-SystemInfo.ps1`](Scripts/Get-SystemInfo.ps1) | §1 hardware inventory | Yes, read-only |
| [`Scripts/Test-Environment.ps1`](Scripts/Test-Environment.ps1) | §2 status table | Yes, read-only |
| [`Scripts/Test-ComputeUnits.ps1`](Scripts/Test-ComputeUnits.ps1) | §6 quick CPU/GPU/NPU check | Yes; runs inference |
| [`Scripts/Invoke-Benchmark.ps1`](Scripts/Invoke-Benchmark.ps1) | §8 full benchmark + CPU sampling → CSV | Yes; runs inference |
| [`src/setup/check_qnn.py`](src/setup/check_qnn.py) | §5 QNN provider + model format | Yes, read-only |
| [`src/setup/model_format.py`](src/setup/model_format.py) | §5 classify a model directory | Yes, read-only |
| [`src/setup/run_ort_genai.py`](src/setup/run_ort_genai.py) | §5 Method D generation loop | Yes |

First run, in order:

```powershell
.\Scripts\Install-Prerequisites.ps1        # report what is missing
.\Scripts\Initialize-Workspace.ps1         # create .venv, sync deps
.\Scripts\Get-SystemInfo.ps1               # record your hardware
.\Scripts\Test-Environment.ps1             # verify the stack loads
geniex pull ai-hub-models/Qwen3-4B         # get a model
.\Scripts\Test-ComputeUnits.ps1            # compare CPU/GPU/NPU
```

---

## 1. Determining your hardware

Everything downstream depends on four facts: the **exact SoC SKU**, the **NPU and GPU driver versions**, the **AI Hub device name** that matches your chip, and whether your shell is **really ARM64**. Compiled NPU artifacts are generation-specific — an asset built for X Elite will not be tuned for X2 Elite — so record these before downloading anything.

### 1.1 Run the inventory

```bash
.\Scripts\Get-SystemInfo.ps1
```

Add `-OutFile inventory.md` to save a copy. The script runs everything in this section and flags a missing NPU driver or a non-ARM64 shell. What it runs, and why each part matters:

All read-only. Run in a native ARM64 PowerShell session:

```powershell
# Machine, SoC, memory
Get-CimInstance Win32_ComputerSystem |
  Select-Object Manufacturer, Model, SystemType,
    @{n='RAM_GiB';e={[math]::Round($_.TotalPhysicalMemory / 1GB, 1)}}

Get-CimInstance Win32_Processor |
  Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed

# OS build and architecture
Get-CimInstance Win32_OperatingSystem |
  Select-Object Caption, Version, BuildNumber, OSArchitecture

# Free space — budget for source weights, converted copies, and caches
Get-Volume | Where-Object DriveLetter |
  Select-Object DriveLetter,
    @{n='Size_GiB';e={[math]::Round($_.Size/1GB,1)}},
    @{n='Free_GiB';e={[math]::Round($_.SizeRemaining/1GB,1)}}

# Is this shell actually ARM64?
[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
```

**Find the NPU and GPU, with driver versions.** This is the step most guides omit, and it is the one that yields your exact SoC SKU:

```powershell
Get-PnpDevice -Class 'Display','ComputeAccelerator' -Status OK |
  Select-Object Class, FriendlyName

Get-CimInstance Win32_PnPSignedDriver |
  Where-Object { $_.DeviceName -match 'Adreno|Hexagon|NPU|Neural' } |
  Select-Object DeviceName, DriverVersion, DriverDate
```

The NPU appears under class **`ComputeAccelerator`**, not `Display`. If nothing returns there, the NPU driver is missing or the device is disabled — no runtime will reach the Hexagon HTP until that is fixed.

### 1.2 Match your chip to a runtime target

`Get-SystemInfo.ps1` reports this too. Manually:

```powershell
geniex config get chipset          # GenieX auto-detects; no configuration needed
qai-hub-models devices             # find the row whose Chipset matches your SoC
```

Take the **Name** column from `qai-hub-models devices` — that exact string is what you pass to `--device` when compiling. Note its **HTP Version**; assets are compiled against it.

### 1.3 Keep firmware current

Install Windows updates plus your device model's firmware/driver package, reboot, then re-run section 1.1 and record the new driver versions. NPU driver updates change inference behavior and performance. Use [Microsoft's Surface driver downloads](https://support.microsoft.com/en-US/surface/drivers-firmware/download-drivers-and-firmware-for-surface) — never another model's firmware package.

### 1.4 Measured values for this machine

Captured 2026-09-19. Update this table when firmware, OS build, or package versions change.

| Component | Measured value |
| --- | --- |
| Device | Microsoft Surface Laptop 13.8in 8th Ed Snapdragon |
| SoC | **Snapdragon X2 Elite**, SKU **X2E78100** @ 4.03 GHz, 12 cores / 12 logical |
| NPU | Qualcomm Hexagon NPU — driver **30.0.228.10000** (2026-07-20) |
| GPU | Qualcomm **Adreno X2-85** — driver **32.0.163.2** (2026-06-29) |
| Memory | **63.5 GiB (64 GB)** LPDDR5x |
| Storage | C: 850 GiB (432 GiB free), D: 102 GiB (87 GiB free) |
| OS | Windows 11 Pro Insider Preview 10.0.28120, ARM64 |
| Shell arch | `Arm64` |
| GenieX chipset detection | `Snapdragon X2 Elite CRD` |
| AI Hub device target | `Snapdragon X2 Elite CRD` — **HTP version 81**, SoC model 88 |
| Python | 3.14.7, ARM64, 64-bit (`.venv`) |
| GenieX CLI | v0.7.0 — QAIRT runtime 2.45, llama.cpp hash `4ff829e` |
| onnxruntime | 1.30.0 |
| onnxruntime-genai | 0.16.0 |
| onnxruntime-qnn | provides `onnxruntime_providers_qnn.dll` |
| qai-hub-models-cli | 0.62.2, installed and running **natively on ARM64** |

> Earlier revisions of this repo documented 32 GB RAM and an unconfirmed SoC. Both are superseded above. NPU TOPS figures are marketing throughput, not an LLM capacity or speed measurement.

<details>
<summary>Raw command output (2026-09-19)</summary>

```text
Manufacturer          Model                                   SystemType     RAM_GiB
------------          -----                                   ----------     -------
Microsoft Corporation Surface Laptop 13.8in 8th Ed Snapdragon ARM64-based PC   63.50

Name                           NumberOfCores NumberOfLogicalProcessors
----                           ------------- -------------------------
Snapdragon X2 Elite @ 4.03 GHz            12                        12

Caption                                  Version    BuildNumber OSArchitecture
-------                                  -------    ----------- --------------
Microsoft Windows 11 Pro Insider Preview 10.0.28120 28120       ARM 64-bit Processor

DriveLetter         Size SizeRemaining
-----------         ---- -------------
          D 109924319232   93916835840
          C 912680546304  464068063232

ProcessArchitecture : Arm64

Class              FriendlyName
-----              ------------
ComputeAccelerator Snapdragon(R) X2 Elite - X2E78100 - Qualcomm(R) Hexagon(TM) NPU
Display            Qualcomm(R) Adreno(TM) X2-85 GPU

DeviceName                                                      DriverVersion   DriverDate
----------                                                      -------------   ----------
Snapdragon(R) X2 Elite - X2E78100 - Qualcomm(R) Hexagon(TM) NPU 30.0.228.10000  7/20/2026
Qualcomm(R) Adreno(TM) X2-85 GPU                                32.0.163.2      6/29/2026
```

</details>

> These commands are what [`Scripts/Get-SystemInfo.ps1`](Scripts/Get-SystemInfo.ps1) runs. It replaces the earlier `System-Info.ps1`, which mixed the inventory with scratch setup notes that silently `winget install`ed packages.

---

## 2. Verification status

```bash
.\Scripts\Test-Environment.ps1
```

Prints this table for your machine and exits non-zero if anything fails. Add `-SkipNetwork` to skip the AI Hub checks.

| Capability | Status | Evidence |
| --- | --- | --- |
| Native ARM64 Python + ONNX stack installs | ✅ Verified | `.venv` on Python 3.14.7 ARM64 |
| `QNNExecutionProvider` registers in ONNX Runtime | ✅ Verified | Appears in `get_available_providers()` after registration |
| GenieX CLI installed, detects chipset | ✅ Verified | `geniex config get chipset` → `Snapdragon X2 Elite CRD` |
| AI Hub CLI authenticated, lists devices | ✅ Verified | `qai-hub-models devices` returns the catalog |
| `Snapdragon X2 Elite CRD` is a valid AI Hub target | ✅ Verified | HTP 81, SoC model 88 |
| `qwen3_4b` publishes **no** ONNX asset | ✅ Verified | `qai-hub-models fetch qwen3_4b -i` |
| `qualcomm/Qwen3-4B` W4A16 bundle cached (3.0 GiB) | ✅ Verified | `geniex list` |
| **`geniex infer` generates text** | ✅ **Verified** | Qwen3-4B W4A16, **~33 tok/s**, 0.1 s to first token |
| `og.is_qnn_available()` | ✅ Verified | Returns `True` |
| GenieX Python SDK | ⬜ Untested | `geniex==0.7.0` resolves for ARM64 py3.14; not installed |
| `geniex serve` + OpenAI-compatible client | ⬜ Untested | — |
| ONNX Runtime GenAI running a model on the NPU | ❌ **Blocked** | Phi-4 NPU bundle is compiled for X Elite (`soc_model 60`); QNN rejects it on X2 Elite — see [Phi-4 on the NPU](#phi-4-on-the-npu) |
| **Phi-4 on the NPU via GenieX GGUF** | ✅ **Verified** | Phi-4-mini-reasoning Q4_0, **24.1 tok/s** |
| ORT GenAI loads an EPContext model | ✅ Verified | Loads in 4.2 s; fails at generation, not load |
| GGUF via llama.cpp engine | ✅ **Verified** | Qwen3-1.7B and 4B Q4_0 |
| `--compute` works on the llama.cpp engine | ✅ **Verified** | 28 % tok/s spread; CPU load drops 68.7 %→15.2 % |
| Direct NPU utilization measurement | ✅ **Verified** | `GPU Engine(*engtype_compute)`, luid `0x13d0d` → **100 %** |
| Direct GPU utilization measurement | ✅ **Verified** | `GPU Engine(*engtype_3d)`, luid `0x133c8` → **87 %** |
| NPU faster than CPU on sustained load | ✅ **Verified** | 29.1 vs 27.5 tok/s at 4B; CPU throttles 19 %, NPU does not |
| `--compute` changes placement for QAIRT bundles | ❌ **No effect** | 1.4 % spread — flag is `llama_cpp only`; see [Section 6](#6-proving-which-compute-unit-actually-runs) |

---

## 3. Choosing a stack

| Goal | Layer | Compute | Accepted format |
| --- | --- | --- | --- |
| Fastest path to working inference | GenieX CLI | NPU / GPU / CPU | AI Hub bundles, GGUF |
| Inference inside Python | GenieX Python SDK | NPU / GPU / CPU | AI Hub bundles, GGUF |
| Drop-in for LangChain / OpenAI clients | `geniex serve` | NPU / GPU / CPU | AI Hub bundles, GGUF |
| Custom graph / token-loop control | `onnxruntime-genai` + QNN EP | NPU via QNN EP | ONNX dir with `genai_config.json` |
| Quantize / compile / profile a model | `qai-hub-models` | AI Hub cloud | PyTorch, ONNX FP32 |
| Training / fine-tuning | PyTorch on a separate host | **Not the NPU** | Standard float tensors |

**Start with GenieX.** It is the only path with a model already cached and a runtime already bundled.

---

## 4. Machine setup

### 4.1 Native ARM64 toolchain

```bash
.\Scripts\Install-Prerequisites.ps1
```

Reports what is present or missing and installs **nothing**. Re-run with `-Install` to install the missing packages via winget, each pinned to `--architecture arm64`. Add `-IncludeDotnet` if you need the .NET SDK for Scout.

Prefer native ARM64 builds throughout. An x64 binary under emulation does not demonstrate native performance, and an emulated Python cannot reach the Hexagon NPU at all. See [Windows on Arm overview](https://learn.microsoft.com/en-us/windows/arm/overview).

| Tool | Notes |
| --- | --- |
| Git | [Git for Windows](https://git-scm.com/downloads/win), ARM64 build |
| Editor | [VS Code ARM64](https://code.visualstudio.com/download) + Python and Pylance extensions |
| Shell | Native ARM64 PowerShell 7+ |
| Python | 3.14 ARM64 (pinned by `.python-version` and `pyproject.toml`) |
| uv | Manages the venv and one-off tool execution |
| MSVC / Windows SDK | Only if building a runtime from source; prebuilt packages avoid this |

Confirm the interpreter is genuinely ARM64 — if it prints `AMD64` you are in an emulated interpreter:

```powershell
python -c "import sys, platform, struct; print(sys.executable, platform.machine(), struct.calcsize('P') * 8)"
```

### 4.2 GenieX CLI

GenieX is Qualcomm's on-device inference runtime. It bundles **two** engines and picks between them based on the model you give it:

- **llama.cpp** — community GGUF models, runs on CPU / GPU / Hexagon HTP
- **QAIRT (Qualcomm AI Engine Direct)** — precompiled AI Hub bundles, NPU only

Install: download the Windows ARM64 installer from the [GenieX CLI install page](https://geniex.aihub.qualcomm.com/en/run/cli/install) and run it. The installer is **not code-signed** — SmartScreen will warn; choose **More info → Run anyway**.

It installs to `%LOCALAPPDATA%\GenieX CLI\geniex.exe`. If it is not on `PATH` in your session:

```powershell
Set-Alias geniex (where.exe geniex)
```

Verify — chipset detection is automatic:

```powershell
geniex version
geniex config get chipset
```

Expected on this machine: `Snapdragon X2 Elite CRD`.

### 4.3 Python workspace

```bash
.\Scripts\Initialize-Workspace.ps1
```

Creates `.venv` on the version pinned in `.python-version`, runs `uv sync`, and verifies the interpreter is genuinely ARM64. Use `-Recreate` to rebuild, and `-CacheRoot D:\atlas` to place model caches off the system drive (see §4.5). Equivalent manual steps:

```powershell
uv venv --python 3.14
.\.venv\Scripts\Activate.ps1
uv sync
```

Current dependencies (`pyproject.toml`): `onnx`, `onnxruntime-genai`, `onnxruntime-qnn`, `qai-hub-models-cli`.

To add the GenieX Python SDK (resolves for ARM64 py3.14; not yet installed here):

```powershell
uv add geniex
```

### 4.4 Qualcomm AI Hub CLI

**The "ARM64 won't install" warning is only half true.** `qai-hub-models-cli` installs and runs natively on ARM64 Python 3.14 — it is already in this venv and `qai-hub-models --help` works. What *is* x86_64-constrained is the heavy source-export dependency set (PyTorch and friends) that `qai-hub-models install` / `export` pulls in.

So:

```powershell
# Catalog, metadata, precompiled asset download — works natively on ARM64
qai-hub-models models
qai-hub-models devices
qai-hub-models info qwen3_4b
qai-hub-models fetch <model>
```

```powershell
# Source-based export/eval — if native resolution fails, run it sandboxed under uvx
uvx --from qai-hub-models-cli qai-hub-models export <model> ...
```

Authenticate once with your Qualcomm ID before any command that contacts AI Hub.

### 4.5 Where models and data live

Model weights never belong in Git. The root `.gitignore` already excludes `.venv/`, `__pycache__/`, `models/`, `.atlas-local/`, `.env`, `*.gguf`, and `*.onnx` — verify with `git status --short --untracked-files=all` before staging. Ignore rules do not untrack files already committed.

Caches land outside the repo by default:

| Location | Holds |
| --- | --- |
| `%USERPROFILE%\.cache\geniex\models` | GenieX pulled models (`geniex list`) |
| `models/` | Local assets, git-ignored |
| `%LOCALAPPDATA%\Atlas\` | Proposed convention for data, runs, and HF cache |

Set cache paths **before** the first download, or you will fill `C:` and copy gigabytes later:

```powershell
$env:GENIEX_DATADIR = 'D:\atlas\geniex'            # honored by geniex today
$env:HF_HOME        = 'D:\atlas\cache\huggingface'  # honored by huggingface_hub
```

`geniex --data-dir` sets the same thing per-invocation, and [`Initialize-Workspace.ps1 -CacheRoot`](Scripts/Initialize-Workspace.ps1) sets both for you. The `ATLAS_DATA_DIR` / `ATLAS_MODEL_DIR` / `ATLAS_RUN_DIR` names from earlier notes are a **proposed convention — nothing reads them yet.**

Budget for source weights, converted copies, temporary conversion files, and caches. The Qwen3-4B W4A16 bundle alone is 3.0 GiB. Keep model locations configurable; never hardcode a `D:` path that a training host will not have.

---

## 5. Inference paths

### Method A: GenieX CLI (recommended first)

GenieX requires a model to be **cached before inference** — `pull` first, then `infer`.

```powershell
# Precompiled NPU bundle from Qualcomm AI Hub
geniex pull ai-hub-models/Qwen3-4B
geniex infer qualcomm/Qwen3-4B:W4A16 --prompt "What is Rayleigh scattering?"
```

```powershell
# Any GGUF from Hugging Face, via the bundled llama.cpp engine
geniex pull unsloth/Qwen3-1.7B-GGUF:Q4_0 --model-hub hf
geniex infer unsloth/Qwen3-1.7B-GGUF:Q4_0 --compute cpu
```

**No separate Hugging Face utility is needed.** `geniex pull --model-hub hf` *is* the CLI — it resolves the repo, picks the quantization from the `:TAG` suffix, and caches it. Supported hubs: `aihub`, `hf`, `modelscope`, `docker`, `localfs`. To see available quantizations before pulling, query the HF API directly:

```powershell
(Invoke-RestMethod 'https://huggingface.co/api/models/unsloth/Qwen3-4B-GGUF').siblings.rfilename |
  Where-Object { $_ -match '\.gguf$' }
```

Install the separate `hf` CLI (from `huggingface_hub`) only if you need auth for gated repos or partial-file downloads; GenieX does not require it.

> **`geniex pull` hangs when its output is redirected.** Run it in a real terminal. In a background job or with stdout piped to a file, the progress bar blocks after the download completes — the file lands fully on disk but never registers in `geniex list`. Killing the process and re-running in the foreground completes it in seconds.

> **A pull can report success without downloading anything.** `geniex pull ai-hub-models/Qwen3-4B:q4_0` printed `Download success / Precision: q4_0` in 18 seconds and produced **no GGUF** — the name already resolved to the cached W4A16 QAIRT bundle, which it left untouched. Two tells: a real download prints a `Location:` line, and `geniex list` shows the new precision. To confirm which engine a cached model will use, read `PluginId` in its `geniex.json` (`llama_cpp` or `qairt`). The AI Hub GGUF assets are not served by `qai-hub-models fetch` either — pull them from Hugging Face with `--model-hub hf`.

```powershell
# A GGUF file already on disk
geniex pull my-local-model --model-hub localfs --local-path D:\repos\Atlas\models\phi-4-instruct.gguf
geniex infer my-local-model
```

Cache management:

```powershell
geniex list      # cached models, sizes, precisions
geniex remove <model>
geniex clean
```

**Flags that matter** (from `geniex infer --help` on v0.7.0):

| Flag | Values | Notes |
| --- | --- | --- |
| `-c, --compute` | `cpu`, `gpu`, `npu`, `hybrid`, or `HTP0,HTP1,...` | **Defaults to `npu`.** Explicit HTP lists are llama.cpp-only |
| `--power-mode` | `low_power_saver` … `burst` | Defaults to `burst`. Pin this when benchmarking |
| `--nctx` | int | Context window, default 4096, llama.cpp-only |
| `-n, --ngl` | int | Layers offloaded to GPU/NPU, `-1` = all, llama.cpp-only |
| `--max-tokens` | int | Default 2048 |
| `--think` | bool | Default **true**; use `--think=false` for Qwen3-style models |
| `--vit-compute` | e.g. `CPU`, `HTP2` | VLM vision encoder placement |
| `--spec-type` | `draft-mtp`, `ngram-cache`, … | Speculative decoding, llama.cpp-only |

> **Correction to earlier notes.** `geniex` has **no `--runtime` flag**. The engine is selected automatically by model format; `llama_cpp` and `qairt` appear in help text only as "(llama_cpp only)" / "(qairt only)" qualifiers on other flags.
>
> `geniex_llamacpp` and `geniex_qairt` *are* real identifiers — but they belong to **`qai-hub-models fetch --runtime`**, a different tool. Passing them to `geniex` will fail. See [Section 7.2](#72-ai-hub-runtime-targets).

### Method B: GenieX Python SDK

Untested here. Install with `uv add geniex`.

```python
from geniex import AutoModelForCausalLM

model = AutoModelForCausalLM.from_pretrained("unsloth/Qwen3.5-2B-GGUF", precision="Q4_0")

messages = [{"role": "user", "content": "What is Rayleigh scattering?"}]
prompt = model.tokenizer.apply_chat_template(messages, add_generation_prompt=True)

for chunk in model.generate(prompt, max_new_tokens=256, stream=True):
    print(chunk, end="", flush=True)

model.close()
```

### Method C: OpenAI-compatible local server

For LangChain, AutoGen, CrewAI, or any OpenAI-shaped client.

`geniex serve` takes **no model argument** and **no `--port` flag** — pull the model first, and set the address with `--host`:

```powershell
geniex pull ai-hub-models/Qwen3-4B-Instruct-2507
geniex serve                              # defaults to 127.0.0.1:18181
geniex serve --host 127.0.0.1:8080 --compute npu --power-mode burst
```

The endpoint is `http://127.0.0.1:18181/v1`.

```python
import requests

BASE = "http://127.0.0.1:18181/v1"

def generate(prompt: str, model: str = "qualcomm/Qwen3-4B") -> str:
    """Send one chat completion to the local GenieX server."""
    response = requests.post(
        f"{BASE}/chat/completions",
        json={
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.7,
        },
        timeout=120,
    )
    response.raise_for_status()
    return response.json()["choices"][0]["message"]["content"]


if __name__ == "__main__":
    print(generate("Explain quantum computing briefly."))
```

`geniex run <model>` is the CLI equivalent against an already-running server.

> **Corrections to earlier notes.** The URL `http://127.0.0` was truncated and missing `/v1/chat/completions`, and `response.json()['choices']['message']` was missing the `[0]` index — `choices` is a list.

### Method D: ONNX Runtime GenAI + QNN

Use this when you need your own token loop, or when Python is a stepping stone to a C# application — the .NET API mirrors it closely. **No ONNX Runtime GenAI model has yet run on this machine's NPU**, for two separate reasons documented below: most GenieX models are the wrong format, and the one correctly-formatted Phi-4 NPU bundle is compiled for the wrong chipset. See [Phi-4 on the NPU](#phi-4-on-the-npu) for what does work.

```bash
.\.venv\Scripts\python.exe src\setup\check_qnn.py --model-dir "$env:USERPROFILE\.cache\geniex\models\qualcomm\Qwen3-4B"
```

[`check_qnn.py`](src/setup/check_qnn.py) verifies the provider stack and classifies any model directory *without loading it*, so a format mismatch is explained rather than surfacing as an opaque parse error. [`run_ort_genai.py`](src/setup/run_ort_genai.py) runs the actual generation loop and refuses to start unless the directory is loadable:

```bash
.\.venv\Scripts\python.exe src\setup\run_ort_genai.py --model-dir models\Phi-4-mini-reasoning-onnx\npu\qnn-int4
```

The QNN provider registration works — verified:

```python
import onnxruntime as ort
import onnxruntime_qnn as qnn_ep

ort.register_execution_provider_library("QNNExecutionProvider", qnn_ep.get_library_path())
print(ort.get_available_providers())
# ['AzureExecutionProvider', 'CPUExecutionProvider', 'QNNExecutionProvider']
```

Note that `QNNExecutionProvider` is **not** present before that call — the `onnxruntime-qnn` package ships the DLL as a plugin that must be registered explicitly.

**The blocker.** `onnxruntime-genai` requires a directory containing an `onnx/` graph plus `genai_config.json`. The cached GenieX bundle at `C:\Users\mike\.cache\geniex\models\qualcomm\Qwen3-4B` contains:

```
config.json  genie_config.json  geniex.json  htp_backend_ext_config.json
metadata.json  sample_prompt.txt  tokenizer.json  vocab.json  merges.txt
part1_of_4.bin  part2_of_4.bin  part3_of_4.bin  part4_of_4.bin
```

That is `genie_config.json` (**Qualcomm Genie**), not `genai_config.json` (**Microsoft ONNX Runtime GenAI**) — and the weights are four QNN context binaries with **no `.onnx` file anywhere**. The two names differ by one letter and are entirely different formats. Pointing `og.Model()` at this directory cannot succeed — which is why [`check_qnn.py`](src/setup/check_qnn.py) classifies a directory before anything tries to load it.

**A naming trap to avoid.** AI Hub offers a runtime called **`genie` / "GenAI Inference Extensions"**. Despite the name, that is *Qualcomm Genie*, not *Microsoft ONNX Runtime GenAI* — it produces the same `genie_config.json` bundle shown above and will not help here. The similarly-named pair is the single most confusing thing in this stack:

| Looks like | Actually is | Config file |
| --- | --- | --- |
| `genie` / "GenAI Inference Extensions" | Qualcomm Genie bundle | `genie_config.json` |
| `onnxruntime-genai` | Microsoft ORT GenAI | `genai_config.json` |

**To unblock.** Check what a model actually ships before committing to it:

```powershell
qai-hub-models fetch qwen3_4b -i     # list assets without downloading
```

For `qwen3_4b` today that returns only `q4_0/geniex_llamacpp`, `w4a16/genie`, and `w4a16/geniex_qairt` — **no ONNX asset at all**, which is why this model cannot feed Method D. Models that do publish an `onnx` or `precompiled_qnn_onnx` asset are the AI Hub candidates.

Even then, AI Hub's ONNX assets target plain ONNX Runtime with the QNN EP; `onnxruntime-genai` additionally needs `genai_config.json`, which those bundles may not contain. The reliable source for ORT-GenAI models is Microsoft's own `*-onnx` Hugging Face repos, which ship `genai_config.json` alongside the graph.

### Phi-4 on the NPU

Microsoft publishes a correctly-formatted ORT GenAI NPU bundle for Phi-4. **It does not run on Snapdragon X2 Elite.** Both repos, verified against the Hugging Face API:

| Repo | `npu/` assets | Notes |
| --- | --- | --- |
| `microsoft/Phi-4-mini-reasoning-onnx` | ✅ `npu/qnn-int4/` (2.8 GB) | `genai_config.json` + ONNX + 4 QNN context binaries |
| `microsoft/Phi-4-mini-instruct-onnx` | ❌ none | Ships `cpu_and_mobile/` and `gpu/` only |

```powershell
uv add huggingface-hub          # provides the `hf` CLI
hf download microsoft/Phi-4-mini-reasoning-onnx --include "npu/*" --local-dir models\Phi-4-mini-reasoning-onnx
```

> Use `hf`, not `huggingface-cli` — the latter is superseded in `huggingface_hub` 1.x. Install `hf_xet` as well for faster transfers on Xet-backed repos.

**What happens on this machine.** The model loads in 4.2 s, then generation fails:

```
RuntimeError: ... GroupQueryAttention ... 'present_keys_0' has shape {1,8,80,128}
but the computed output shape for this run is {1,8,4096,128}
```

That mismatch is a **symptom**. Loading the context binary directly under plain ONNX Runtime with `disable_cpu_ep_fallback` gives the real cause:

```
NOT_IMPLEMENTED : EPContext node generated by 'QNNExecutionProvider' is not
compatible with any execution provider added to the session.
```

QNN declines the graph, ORT falls back to CPU, and the EPContext wrapper holds no CPU-executable weights — hence the shape error further downstream.

**Why it is declined.** `genai_config.json` specifies `soc_model: 60`, and these `*_ctx.onnx` files are **ahead-of-time compiled** context binaries:

| soc_model | Chipset | HTP |
| --- | --- | --- |
| 60 | Snapdragon X Elite | v73 |
| **88** | **Snapdragon X2 Elite (this machine)** | **v81** |

Overriding `soc_model` to 88 does not help — tested, and it fails identically. The binary itself targets the other architecture. This is the concrete case of the warning in §1: assets published for X Elite are not automatically X2 Elite compatible.

Note also that the QNN options live **inside each pipeline stage**, not on the top-level decoder — this is a 4-stage pipeline (embedding → prompt-processor → token-generator → transformer-head). Inspecting `model.decoder.session_options.provider_options` alone shows an empty list and tells you nothing.

#### What does work: Phi-4 on the NPU via GenieX

The same model in GGUF form runs on the NPU today through the llama.cpp engine:

```powershell
geniex pull unsloth/Phi-4-mini-reasoning-GGUF:Q4_0 --model-hub hf
geniex infer unsloth/Phi-4-mini-reasoning-GGUF:Q4_0 -p "What is 17 times 23?" --compute npu
```

Measured: **24.1 tok/s**, 0.1 s to first token, on the NPU. Benchmark it against the other compute units with `.\Scripts\Invoke-Benchmark.ps1 -Model "unsloth/Phi-4-mini-reasoning-GGUF:Q4_0"`.

Other Phi options, from `qai-hub-models fetch <model> -i`:

| Model | Available asset | X2 Elite? |
| --- | --- | --- |
| `phi_4_mini_instruct` | `q4_0` GenieX (Llama.cpp), Universal | ✅ via llama.cpp |
| `phi_3_5_mini_instruct` | `w4a16` genie (QAIRT), QAIRT 2.43.1 | ✅ **explicitly lists X2 Elite** |

`qualcomm/Phi-3.5-Mini-Instruct` is the only Phi with a *native NPU* bundle listing X2 Elite support — but it is a `genie` bundle, so it runs through GenieX, **not** `onnxruntime-genai`. Recall the naming trap above.

#### Recompiling for X2 Elite (soc_model 88)

**Read the blocker first.** Recompiling needs a **QDQ-quantized source ONNX** of the transformer stages. Microsoft publishes only the already-compiled `phi_4_mini_ctx.onnx_ctx.onnx` and `phi_4_mini_iter.onnx_ctx.onnx` — you cannot recompile a context binary, it is the output. Two facts close off the obvious shortcuts:

- The ONNX Runtime GenAI **model builder cannot target QNN**. Verified locally: `onnxruntime_genai/models/builder.py` accepts `-e` of only `cpu`, `cuda`, `dml`, `webgpu`, `NvTensorRtRtx`. Microsoft's NPU bundle came from a different toolchain.
- `microsoft/Phi-4-mini-instruct-onnx` ships no NPU assets, and its `cpu_and_mobile` / `gpu` graphs are not QDQ-quantized for HTP.

So this is a build-from-scratch exercise, not a re-run of a published step.

**Route A — ONNX Runtime's compile API (no QAIRT SDK).** The local package already supports your chipset: `onnxruntime_qnn` ships `QnnHtpV81Stub.dll` (v81 = X2 Elite) alongside V68 and V73, plus the `QnnHtpPrepare.dll` compiler. ORT enumerates QNN as an NPU device:

```python
import onnxruntime as ort, onnxruntime_qnn as qnn_ep
ort.register_execution_provider_library("QNNExecutionProvider", qnn_ep.get_library_path())

so = ort.SessionOptions()
so.set_provider_selection_policy(ort.OrtExecutionProviderDevicePolicy.PREFER_NPU)

ort.ModelCompiler(so, "source_qdq.onnx").compile_to_file("compiled_v81_ctx.onnx")
```

Compiling on the target machine means the binary matches your HTP by construction — no `soc_model` guessing.

> `sess_options.add_provider("QNNExecutionProvider", {...})` is rejected with *"Provider configuration is not supported"* for this plugin EP. Use `set_provider_selection_policy` instead.

**Always verify the output.** If QNN will not take the graph, `compile_to_file` **succeeds silently and emits a pass-through** with no EPContext nodes. Measured here on the bundle's embedding graph: 615 MB in, 614.6 MB out, 1.2 s, **zero** EPContext nodes:

```python
import onnx, collections
m = onnx.load("compiled_v81_ctx.onnx", load_external_data=False)
print(collections.Counter(n.op_type for n in m.graph.node)["EPContext"])   # must be > 0
```

**Route A was tested against AI Hub assets and currently fails on this stack.** Both models publish a `w8a8 / ONNX Runtime / Universal` QDQ graph — the correct input for compilation — and AI Hub states each was *"verified with QAIRT 2.45.0.260326154327, ONNX Runtime 1.27.1"*. This machine runs **ONNX Runtime 1.30.0**:

| Model | Result on ORT 1.30.0 |
| --- | --- |
| `squeezenet1_1` w8a8 | Loads, but QNN claims **0 of 49 nodes** — profiling shows every node on `CPUExecutionProvider`. `ModelCompiler` fails: *"Conv with domain com.ms.internal.nhwc was inserted using the NHWC format as requested by QNNExecutionProvider, but was not selected by that EP ... could be a bug in layout transformer, or in the GetCapability implementation of the EP"* |
| `mobilenet_v2` w8a8 | Will not load at all: *"This is an invalid model. Error: two nodes with same node name (node_Conv_239)"* — a validation strictness change |

Two different failures, both consistent with **version skew rather than anything about the chipset or the models**. Take AI Hub's version note literally: pin `onnxruntime` to the stated version in a separate environment before concluding anything about NPU compatibility. Doing so here would mean testing whether `onnxruntime-genai` 0.16 and `onnxruntime-qnn` still work against ORT 1.27.1 — untested.

Verify node assignment rather than trusting a successful `run()`:

```python
so = ort.SessionOptions(); so.enable_profiling = True
sess = ort.InferenceSession(model, sess_options=so, providers=["QNNExecutionProvider"],
                            provider_options=[{"backend_path": "QnnHtp.dll"}])
sess.run(None, feeds)
import json, collections
events = json.load(open(sess.end_profiling()))
print(collections.Counter(e["args"]["provider"] for e in events
                          if e.get("cat") == "Node" and "provider" in e.get("args", {})))
```

**Route B — full QAIRT SDK.** Needed when the graph requires Qualcomm's own quantizer. Broadly: install the QAIRT SDK, convert and quantize with `qairt-converter` / `qairt-quantizer` using a representative calibration set, generate the context binary with `qnn-context-binary-generator` against `QnnHtp.dll` for your SoC, then wrap it with ONNX Runtime's `gen_qnn_ctx_onnx_model.py` and hand-write a `genai_config.json` describing the pipeline stages. Consult [Qualcomm's ONNX model preparation docs](https://docs.qualcomm.com/doc/80-80022-15B/topic/onnx-prepare-model.html) and [ORT's Snapdragon build guide](https://onnxruntime.ai/docs/genai/howto/build-models-for-snapdragon.html) for current commands.

**Neither route has been completed here.** Route A's API is verified working; producing a functioning Phi-4 EPContext model is not. Budget real effort, and weigh it against the GenieX GGUF path above, which already runs Phi-4 on the NPU today.

**A second, independent breakage.** The generation API changed, and code written against older `onnxruntime-genai` examples fails on 0.16 even with a correct model:

| Removed | Replacement |
| --- | --- |
| `params.set_input_ids(tokens)` | `generator.append_tokens(tokens)` |
| `params.set_search_property("max_length", 512)` | `params.set_search_options(max_length=512)` |
| `generator.compute_logits()` | removed — `generate_next_token()` suffices |

The current shape, as implemented in [`run_ort_genai.py`](src/setup/run_ort_genai.py):

```python
import onnxruntime_genai as og
import onnxruntime_qnn as qnn_ep

og.register_execution_provider_library("QNNExecutionProvider", qnn_ep.get_library_path())
print(og.is_qnn_available())  # True on this machine

MODEL_DIR = r"models\Phi-3-mini-4k-instruct-onnx"  # must contain genai_config.json
model = og.Model(MODEL_DIR)
tokenizer = og.Tokenizer(model)

params = og.GeneratorParams(model)
params.set_search_options(max_length=512, temperature=0.7)

generator = og.Generator(model, params)
generator.append_tokens(tokenizer.encode("Write a fast sorting algorithm in Python."))

stream = tokenizer.create_stream()
while not generator.is_done():
    generator.generate_next_token()
    print(stream.decode(generator.get_next_tokens()[0]), end="", flush=True)

del generator
```

---

## 6. Proving which compute unit actually runs

A provider appearing in a list, or a busy NPU graph in Task Manager, does **not** prove the whole model executes there. The checks below are comparative because no single run is self-evident.

```bash
.\Scripts\Test-ComputeUnits.ps1
```

Runs the same prompt across `cpu`, `gpu`, and `npu` with a fixed seed, a pinned power mode, and a discarded warm-up run, then interprets the spread. Useful switches: `-Model`, `-MaxTokens`, `-Repeat 3`, `-Compute npu,cpu`.

**Step 1 — compare placements on identical input.** This is what the script automates. If `--compute cpu` and `--compute npu` give the same throughput, the flag is not changing where work happens.

Both engines were measured on this machine, and they behave completely differently.

**QAIRT bundle — `qualcomm/Qwen3-4B` W4A16, 48 tokens:**

| Compute | Tok/s |
| --- | --- |
| `npu` | 33.2 |
| `cpu` | 34.1 |
| `gpu` | 33.3 |

A **1.4 % spread**: `--compute` does nothing. The CLI help explains why — the flag is annotated *"llama_cpp only"*. A QAIRT bundle is NPU-targeted by construction, so it very likely runs on the NPU for all three values. **The flag is a no-op, not evidence of CPU execution.**

**llama.cpp engine — `unsloth/Qwen3-1.7B-GGUF` Q4_0, 64 tokens, 3 runs each:**

| Compute | Tok/s | Startup (s) | First token (s) |
| --- | --- | --- | --- |
| `cpu` | **65.8** | 1.52 | 0.10 |
| `npu` | 63.3 | 3.87 | **0.00** |
| `gpu` | 47.4 | 2.58 | 0.10 |

A **28 % spread**: on llama.cpp, `--compute` genuinely works.

> **This short run is shown because it is misleading.** At only 64 tokens on a cold machine the CPU appears to win. Extending to 400 tokens on a warmed-up machine reverses it — the CPU throttles ~19 % while the NPU holds steady, and the NPU finishes ahead at both model sizes. See [§8.3](#83-what-these-numbers-mean). Compare generation rate rather than wall-clock, and generate enough tokens to reach steady state before drawing a conclusion.

Note that even here the NPU already wins **first-token latency** (0.00 s vs 0.10 s): prefill is batched, which suits the NPU, while the short decode loop favoured the then-cold CPU.

**Step 2 — make GenieX say what it is doing.** The default log level is `none`:

```powershell
geniex infer qualcomm/Qwen3-4B:W4A16 -p "hello" --log debug --verbose
```

Look for the engine selected (`qairt` vs `llama_cpp`), the compute unit, and any fallback.

**Step 3 — for ONNX models, prove it directly.** This is the only *non*-comparative proof available:

```bash
.\.venv\Scripts\python.exe src\setup\check_qnn.py --prove-npu
```

It builds a small quantized graph and loads it twice — once with CPU fallback allowed, once with `session.disable_cpu_ep_fallback` set. Pass `--onnx <path>` to test your own model.

This matters more than it sounds. Measured here, with fallback **allowed**, the session loaded successfully and reported `providers=['CPUExecutionProvider']` — QNN silently took no nodes while everything looked fine. With fallback **disabled**, it failed loudly:

```
FAIL : This session contains graph nodes that are assigned to the default CPU EP,
but fallback to CPU EP has been explicitly disabled by the user.
```

Two habits follow: always read `session.get_providers()` *after* creating the session, and set `disable_cpu_ep_fallback` during validation so a silent fallback becomes an error.

**Step 4 — watch the hardware.** Task Manager → Performance shows separate **NPU** and **GPU** graphs on this device. Correlate a sustained generation against those counters rather than a brief spike.

**Step 5 — pin the conditions.** `--power-mode burst` is the default and will skew comparisons against a machine on battery or a power-saver profile. Benchmark on AC, let temperatures settle, and repeat runs.

Record for each configuration: cold-load time, time to first token, tokens/second, peak memory, context length, power mode, engine, compute unit, and driver versions.

---

## 7. Training and asset optimization

### 7.1 The NPU does not train

The Hexagon NPU is a forward-pass inference accelerator. It has no backward-propagation path, no gradient accumulation, and no optimizer state handling. You cannot fine-tune on it.

Local options for gradient work on this machine are limited to the **Adreno GPU via DirectML** or **CPU/WSL2**, both of which are appropriate only for tiny experiments. Plan substantial LoRA/QLoRA training on a **separate CUDA host**. Paid GPU infrastructure requires explicit authorization.

### 7.2 AI Hub runtime targets

`qai-hub-models fetch --runtime` and `export --target-runtime` accept these IDs (from `qai-hub-models runtimes`). "Ahead-of-Time" means the asset is compiled per chipset and must match your SoC; "On-Device" means it compiles on first load.

| ID | Name | Ext | Compiled | Use for |
| --- | --- | --- | --- | --- |
| `geniex_llamacpp` | GenieX (Llama.cpp) | `.gguf` | On-Device | GenieX, any chipset |
| `geniex_qairt` | GenieX (QAIRT) | `.geniex.zip` | Ahead-of-Time | GenieX on NPU |
| `genie` | GenAI Inference Extensions | `.genie.zip` | Ahead-of-Time | Qualcomm Genie — **not** ORT GenAI |
| `onnx` | ONNX Runtime | `.onnx.zip` | On-Device | ONNX Runtime + QNN EP |
| `precompiled_qnn_onnx` | Precompiled QAIRT ONNX | `.onnx.zip` | Ahead-of-Time | QAIRT context binary wrapped in ONNX |
| `qnn_context_binary` | QAIRT Context Binary | `.bin` | Ahead-of-Time | Direct QAIRT integration |
| `qnn_dlc` | QAIRT DLC | `.dlc` | On-Device | QAIRT deep-learning container |
| `tflite` | TensorFlow Lite | `.tflite` | On-Device | LiteRT |

Precision values include `q4_0`, `w4a16`, `w8a8`, `w8a16`, `w16a16`, `mxfp4`, and `float`. Always run `fetch <model> -i` first — most models publish only a subset.

### 7.3 Compile, quantize, profile

Once a model is trained and exported to PyTorch or FP32 ONNX, convert it to an NPU-compatible INT4/INT8 layout through AI Hub. Target **`Snapdragon X2 Elite CRD`** — confirmed present in the device catalog with HTP version 81.

```powershell
qai-hub-models info mobilenet_v2

qai-hub-models export yolov7 `
  --target-runtime onnx `
  --precision int8 `
  --device "Snapdragon X2 Elite CRD"

qai-hub-models demo yolov7 --eval-mode fp
```

> **Correction to earlier notes.** `"Snapdragon X Elite CRD"` is the previous generation (HTP 73). Compiling against it will not produce artifacts tuned for this machine's HTP 81.

If native resolution of the source-export dependencies fails on ARM64, prefix with `uvx --from qai-hub-models-cli`. Note that AI Hub compilation and profiling **upload your model to Qualcomm's cloud** — treat it as a data transfer requiring authorization for the artifacts involved.

---

## 8. Benchmarking

```bash
.\Scripts\Invoke-Benchmark.ps1 -Model "unsloth/Qwen3-4B-GGUF:Q4_0" -Repeat 3
```

Runs each compute unit N times, samples **per-core CPU utilization during** each run, and writes a timestamped CSV to `.atlas-local/benchmarks/` (git-ignored). [`Test-ComputeUnits.ps1`](Scripts/Test-ComputeUnits.ps1) is the quick sanity check; this is the one that produces a recorded result.

### 8.1 Measuring NPU and GPU utilization

All three accelerators are directly measurable. The NPU is not exotic: it registers as an **MCDM compute accelerator** (device class GUID `{F01A9D53-3FF6-48D2-9F97-C8A7004BE10C}`, which Task Manager reports as *DirectX 12, FL 1.0: Compute*), so Windows exposes it through the ordinary **`GPU Engine`** counter set — under its own adapter LUID with `engtype_compute`. Task Manager's NPU graph reads the same engine.

| Signal | Counter |
| --- | --- |
| CPU, per core | `\Processor Information(0,N)\% Processor Utility` |
| CPU by core tier | Same, grouped by registry `~MHz` |
| **NPU** | `\GPU Engine(*engtype_compute)\Utilization Percentage` |
| **GPU** | `\GPU Engine(*engtype_3d)\Utilization Percentage` |

On this machine the adapters resolve as:

| Adapter LUID | Engine type | Device |
| --- | --- | --- |
| `0x00013d0d` | `compute` | Hexagon NPU |
| `0x000133c8` | `3d` | Adreno X2-85 GPU |

`Invoke-Benchmark.ps1` does not hardcode these — it self-calibrates by taking whichever adapter is busiest during the `--compute npu` runs as the NPU, and likewise for GPU.

**Two pitfalls will convince you the counters don't exist.** Both cost me a wrong conclusion before I caught them:

1. **`GPU Engine` instances are per-process** — `pid_N_luid_..._engtype_X` — and only exist while that process runs. Enumerating instance paths *before* launching the workload finds nothing, forever. You must query with a wildcard that re-expands on every sample.
2. **Each `Get-Counter` call costs ~1 s**, because utilization counters need two samples to compute a rate. Two separate calls per loop iteration left short runs with only two samples, which missed the active window entirely and recorded a spurious `0`. Collect cores and engines in a single call, and generate enough tokens (≥400) for the sampling window to cover steady state.

Note also that the driver can report **over 100 %** for an adapter aggregating multiple sub-engines; the script clamps to 100.

**The result is unambiguous** — each compute unit lights up exactly one accelerator:

| Run | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- |
| `--compute cpu` | **83.8** | 0 | 5.1 |
| `--compute npu` | 18.9 | **100** | 5.8 |
| `--compute gpu` | 18.2 | 0 | **87.3** |

### 8.2 Measured results

Q4_0 GGUF via the llama.cpp engine, 400 tokens, 3 runs each, `--power-mode burst`, on AC.

**`unsloth/Qwen3-4B-GGUF`:**

| Compute | Tok/s | First token (s) | Startup (s) | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- | --- | --- | --- |
| `npu` | **29.1** | 0.10 | 6.30 | 18.9 | 100 | 5.8 |
| `cpu` | 27.5 | 0.23 | 2.29 | 83.8 | 0 | 5.1 |
| `gpu` | 24.6 | 0.20 | 5.27 | 18.2 | 0 | 87.3 |

**`unsloth/Qwen3-1.7B-GGUF`:**

| Compute | Tok/s | Startup (s) | CPU % | NPU peak | GPU peak |
| --- | --- | --- | --- | --- | --- |
| `npu` | **65.3** | 4.51 | 27.0 | 100 | 5.3 |
| `gpu` | 54.3 | 3.52 | 27.8 | 0 | 95.0 |
| `cpu` | 53.4 | 1.79 | 82.5 | 0 | 4.9 |

### 8.3 What these numbers mean

**The NPU wins at both model sizes**, and the margin grows with generation length.

> **Correction.** An earlier revision of this README claimed the CPU won. That was an artifact of benchmarking a cold machine with short generations. Longer runs on a warmed-up machine reverse the result. The measurement method mattered more than the hardware.

**The CPU throttles; the NPU does not.** Repeated 1.7B measurements across one session, as the machine warmed:

| Tokens | CPU tok/s | NPU tok/s |
| --- | --- | --- |
| 64 (cold) | **65.8** | 63.3 |
| 160 | 61.0 | 63.3 |
| 400 (warm) | 53.4 | **65.3** |

CPU throughput fell **19 %** while the NPU held within ~2 tok/s. Any benchmark short enough to run on a cold machine will flatter the CPU. This is the single biggest methodological trap here — if you measure once, briefly, you will reach the wrong conclusion.

**The NPU is dramatically more consistent.** Across every run at 4B it stayed within 0.1 tok/s (29.1–29.2); the CPU ranged 20.5–32.6 across the session. For predictable latency, that stability matters more than peak throughput.

**It also frees ~65 points of CPU.** NPU runs sit at 18.9 % CPU versus 83.8 %. On a machine also running Scout, an editor and a browser, the NPU wins on throughput *and* leaves the CPU available.

**Offloaded work lands on the slower core tier.** During NPU runs the fast tier sat at 5.5 % while the slow tier ran 32.2 %; same pattern on GPU (6.3 % vs 30.2 %). Windows schedules the residual coordination thread onto efficiency cores. During CPU inference both tiers ran evenly (84.0 % / 83.6 %), so llama.cpp spreads across all 12.

**The GPU is the weakest option here** — slowest at 4B and barely ahead of a throttled CPU at 1.7B, while pegging the Adreno at ~87–95 %. It also pays first-run shader compilation (21 s observed once, settling to ~4 s).

**NPU startup is the real cost** — 4.5 s at 1.7B and 6.3 s at 4B, against ~2 s for CPU. For a short-lived process that can exceed the generation savings; for `geniex serve` it amortizes to nothing.

**Caveats.** Single machine, one quantization (Q4_0), one prompt, nothing else running, AC power, `burst` power mode. Battery operation is untested. Thermal state materially changes CPU results, so record run order. Re-measure after driver or firmware updates and note the versions from §1 alongside results.

### 8.4 Memory

This machine has **64 GB of shared system memory**, not a 64 GB model budget. Weights, KV cache, activations, runtime buffers, Windows, and your editor all draw from the same pool. Four-bit weights are roughly `parameters × 0.5 bytes` before quantization metadata and runtime overhead — the Qwen3-4B W4A16 bundle is 3.0 GiB on disk, the Q4_0 GGUF 2.2 GiB.

64 GB is generous for this class of work: 7B–14B quantized models are realistic. Long contexts are usually the binding constraint rather than weights, since KV cache grows with context length.

Start with one model, one request, and the default 4096-token context. Increase only after measuring. Keep the page file system-managed and avoid sustained paging during measurements. Tune thread count empirically — maximum logical cores is not automatically fastest.

---

## 9. Atlas project scope

### Repository boundaries

- **Tripperist** owns the production application and authoritative travel data/schema.
- **Scout** owns the experimental API, orchestration, tools, retrieval, embeddings, and inference integration.
- **Atlas** owns training-data preparation, model experiments, evaluation, adapters, export, quantization, and model documentation.

Atlas must not depend on changes to the production Tripperist repository. Scout can use an existing base model while Atlas is developed. Scout's embedding pipeline is separate; changes to an embedding model must be coordinated explicitly.

Improve travel-assistant behavior only where measured evaluations establish a need: preference interpretation, structured responses, tool selection, and grounded explanations. Keep changing travel facts in Scout's retrieval sources rather than memorizing them through training.

### Development workflow

1. Establish a base-model baseline using representative Scout scenarios.
2. Diagnose failures in data, retrieval, tools, prompts, and model behavior separately.
3. Prepare reviewed examples for failures that training can reasonably address.
4. Split training, validation, and held-out evaluation data before training.
5. Run a reproducible adapter-training experiment.
6. Compare against the unchanged base model on the same evaluation set.
7. Export or merge, quantize, and evaluate the actual deployment artifact.
8. Publish an identified artifact and compatibility manifest for Scout when authorized.

Begin with roughly 50–100 reviewed evaluation scenarios. That is an evaluation starting point, not a prescribed training-set size.

### Runtime acceptance gate

Before investing in training, demonstrate on this machine:

- Repeatable base-model generation and a documented Scout-compatible invocation boundary.
- Pinned tokenizer/chat template, correct stop tokens, known context limits.
- Structured-response and tool-call behavior under representative Scout prompts.
- A supported adapter loading or merge path, followed by export/quantization.
- **Actual CPU/GPU/NPU execution evidence** plus measured memory and latency.

A working training checkpoint does not guarantee Windows ARM or NPU compatibility. Verify the export path, tokenizer and chat template, adapter support, quantization, and target runtime before training.

### Dataset requirements

Track provenance, usage rights, preparation version, and review status. Deduplicate across splits and separate trips/regions to detect memorization. Exclude held-out answers from training and calibration inputs.

Use synthetic or approved sanitized fixtures in Git. Keep private travel records, raw conversations, large datasets, checkpoints, adapters, and model weights in external storage. Document artifact identifiers and checksums instead of committing binaries.

### Evaluation

Measure structured-output validity, tool-call correctness, grounding, invented places, hard-constraint violations, and explanation quality. Compare both pre-export and deployed quantized artifacts under identical conditions. Record latency, peak memory, context length, hardware, runtime version, and actual acceleration. Do not claim improvement from training loss alone.

### Scout delivery contract

Maintain a versioned manifest with artifact identity/version/location/checksums; base-model identity, revision, and licenses; adapter identity and merge status; tokenizer and chat-template identity; quantization, context limits, I/O conventions, and tool-call format; supported runtime versions and tested hardware; and evaluation dataset version, results, limitations, and reproduction instructions.

Model-directed tool calls are proposals; Scout remains responsible for validation and execution.

### Layout

| Path | Status | Purpose |
| --- | --- | --- |
| `src/atlas/` | exists | Package entry point |
| `src/setup/` | exists | QNN diagnostics and the ORT GenAI runner |
| `Scripts/` | exists | PowerShell automation for every section above |
| `docs/` | planned | Decisions, model cards, experiment records |
| `models/` | empty | Local model assets (git-ignored) |
| `configs/` | planned | Versioned training/eval/export configs |
| `schemas/` | planned | Dataset and manifest definitions |
| `evaluations/` | planned | Scenarios, metrics, result summaries |
| `tests/` | planned | Data and pipeline checks |

Keep model locations configurable. Never assume a `D:` path exists on a training host.

---

## 10. Troubleshooting

| Symptom | Check |
| --- | --- |
| `geniex` not found after install | `Set-Alias geniex (where.exe geniex)`, or add `%LOCALAPPDATA%\GenieX CLI` to `PATH` |
| SmartScreen blocks the installer | Installer is unsigned by design — **More info → Run anyway** |
| `geniex infer` says model not found | `pull` before `infer`; check `geniex list` for the exact cached name and precision |
| Ambiguous precision prompt | Append it: `model:W4A16` |
| `geniex: unknown flag --runtime` | `geniex` has no such flag — engine follows model format. `geniex_llamacpp`/`geniex_qairt` belong to `qai-hub-models fetch --runtime` |
| Fetched a `genie` asset expecting ORT GenAI | "GenAI Inference Extensions" is Qualcomm Genie, not Microsoft ORT GenAI |
| `--port` rejected on `serve` | Use `--host 127.0.0.1:<port>` |
| `QNNExecutionProvider` missing from providers | Call `ort.register_execution_provider_library(...)` first — it is a plugin, not built in |
| `og.Model()` fails to parse the model dir | Run `check_qnn.py --model-dir <dir>` — it names the format. `genai_config.json` is required; `genie_config.json` + `part*_of_*.bin` is a QAIRT bundle that will not load |
| `set_input_ids` / `compute_logits` AttributeError | Removed in onnxruntime-genai 0.16. Use `append_tokens` and drop `compute_logits` — see [Method D](#method-d-onnx-runtime-genai--qnn) |
| Session loads but `get_providers()` shows only CPU | QNN took no nodes. Set `session.disable_cpu_ep_fallback` to turn the silent fallback into an error |
| `--compute` makes no measurable difference | Expected for QAIRT bundles — the flag is `llama_cpp only`. Test placement with a GGUF model |
| `pull` says success but nothing downloaded | The name resolved to an already-cached bundle. A real download prints `Location:`. Check `PluginId` in the model's `geniex.json` |
| NPU looks slower than CPU | Likely a cold machine and too few tokens. Generate ≥400 and repeat — the CPU throttles ~19 %, the NPU does not. See [Section 8](#8-benchmarking) |
| `geniex pull` never finishes | It blocks when stdout is redirected. Run it in a real terminal, not a background job |
| NPU counter appears to be missing | It is `\GPU Engine(*engtype_compute)`, not an "NPU" counter set. Instances are per-process, so query with a wildcard *while* the workload runs |
| Accelerator utilization reads 0 | Sampling missed the window. Each `Get-Counter` call costs ~1 s — use one combined call and a longer generation |
| Utilization reads over 100 % | Normal for an adapter aggregating sub-engines; clamp to 100 |
| `EPContext node ... is not compatible` | The context binary was compiled for another chipset. Check `soc_model` in `genai_config.json`: 60 = X Elite, 88 = X2 Elite. Overriding it does not help |
| `GroupQueryAttention` / `present_keys` shape error | Usually a symptom of the row above — QNN declined the graph and CPU fallback has no weights. Also check whether you overrode `max_length` on a `past_present_share_buffer` model |
| `provider_options` looks empty | On pipeline models the QNN options live inside each stage, not on the top-level decoder |
| `huggingface-cli` not found | Superseded by `hf` in `huggingface_hub` 1.x |
| `pip install` finds no ARM64 wheel | Check Python minor version and ABI. Use `uvx` for x86-constrained tooling; do not silently switch native benchmarks to emulation |
| DLL load or architecture error | Interpreter, runtime, and native libraries must share an architecture |
| Model runs but NPU is idle | Re-run with `--log debug --verbose`; CPU success is not NPU validation |
| Export produces wrong-generation artifacts | Use `--device "Snapdragon X2 Elite CRD"` (HTP 81), not `X Elite` (HTP 73) |
| Out-of-memory or sustained paging | Reduce `--nctx`, concurrency, or model size; account for duplicate cached copies |
| Exported model regresses | Compare tokenizer/template, merge, quantization calibration, stop tokens, and context against the baseline |

---

## References

- [GenieX — what is GenieX](https://geniex.aihub.qualcomm.com/en/get-started/what-is-geniex) · [CLI install](https://geniex.aihub.qualcomm.com/en/run/cli/install) · [qualcomm/GenieX on GitHub](https://github.com/qualcomm/GenieX)
- [qualcomm/ai-hub-models](https://github.com/qualcomm/ai-hub-models)
- [ONNX Runtime GenAI QNN guidance](https://github.com/microsoft/onnxruntime-genai/blob/main/docs/qnn.md)
- [QNN Execution Provider](https://github.com/onnxruntime/onnxruntime-qnn/blob/main/docs/execution_providers/QNN-ExecutionProvider.md)
- [Windows on Arm overview](https://learn.microsoft.com/en-us/windows/arm/overview)
- [AGENTS.md](AGENTS.md) — contributor and coding-agent rules

Environment facts verified 2026-09-19 against GenieX v0.7.0, onnxruntime 1.30.0, onnxruntime-genai 0.16.0, qai-hub-models-cli 0.62.2. Update the status table in [Section 2](#2-verification-status) as paths are proven.
