# Atlas

Atlas is the model development workspace for Tripperist's **Scout** travel assistant: dataset preparation, fine-tuning, evaluation, and optimization for **local inference on Windows ARM64 / Qualcomm Snapdragon** hardware.

This README is the single entry point. It supersedes the former `Setup.MD` and `docs/Hardware.md`, and it distinguishes **verified** facts (measured on the target machine) from **untested** guidance.

- [1. Determining your hardware](#1-determining-your-hardware)
- [2. Verification status](#2-verification-status)
- [3. Choosing a stack](#3-choosing-a-stack)
- [4. Machine setup](#4-machine-setup)
- [5. Inference paths](#5-inference-paths)
- [6. Available models](#6-available-models)
- [7. Proving which compute unit actually runs](#7-proving-which-compute-unit-actually-runs)
- [8. Training and asset optimization](#8-training-and-asset-optimization)
- [9. Benchmarking](#9-benchmarking)
- [10. Atlas project scope](#10-atlas-project-scope)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Backlog](#12-backlog)

## Automation

Every manual sequence below is wrapped in a script. Each section still explains what the steps do and why — run the script, read the section when something fails.

| Script | Automates | Safe to run |
| --- | --- | --- |
| [`Scripts/Install-Prerequisites.ps1`](Scripts/Install-Prerequisites.ps1) | §4.1 toolchain | Reports only; `-Install` to act |
| [`Scripts/Initialize-Workspace.ps1`](Scripts/Initialize-Workspace.ps1) | §4.3 venv + deps | Yes |
| [`Scripts/Get-SystemInfo.ps1`](Scripts/Get-SystemInfo.ps1) | §1 hardware inventory | Yes, read-only |
| [`Scripts/Test-Environment.ps1`](Scripts/Test-Environment.ps1) | §2 status table | Yes, read-only |
| [`Scripts/Test-ComputeUnits.ps1`](Scripts/Test-ComputeUnits.ps1) | §7 quick CPU/GPU/NPU check | Yes; runs inference |
| [`Scripts/Invoke-Benchmark.ps1`](Scripts/Invoke-Benchmark.ps1) | §9 full benchmark + CPU sampling → CSV | Yes; runs inference |
| [`src/setup/check_qnn.py`](src/setup/check_qnn.py) | §5 QNN provider + model format | Yes, read-only |
| [`src/setup/model_format.py`](src/setup/model_format.py) | §5 classify a model directory | Yes, read-only |
| [`src/setup/run_ort_genai.py`](src/setup/run_ort_genai.py) | §5 Method D generation loop | Yes |
| [`src/setup/hub_profile.py`](src/setup/hub_profile.py) | §8.4 cloud compile + profile | Uploads model; needs API token |
| [`src/setup/model_catalog.py`](src/setup/model_catalog.py) | §6 published perf per model | Yes, read-only; no token |

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
| **ONNX Runtime GenAI generating on the NPU** | ✅ **Verified** | Phi-4-mini-reasoning, **17.1 tok/s**, NPU peak **97.7 %** |
| `onnxruntime-genai` 0.16.0 with EPContext models | ❌ **Regressed** | Fails on the prompt pass; 0.13.2–0.15.2 work |
| **Compiling an EPContext model for this chipset** | ✅ **Verified** | SqueezeNet w8a8 → 1 EPContext node, NPU-only, **0.46 ms** |
| X Elite context binaries load on X2 Elite | ✅ Verified | All 4 Phi-4 parts load; `soc_model` was a red herring |
| **Phi-4 on the NPU via GenieX GGUF** | ✅ **Verified** | Phi-4-mini-reasoning Q4_0, **24.1 tok/s** |
| **Foundry Local on the NPU** | ✅ **Verified** | phi-3.5-mini qnn-npu, **26.5 tok/s**, NPU **100 %** |
| ORT GenAI loads an EPContext model | ✅ Verified | Loads in 6.3 s; fails at generation, not load |
| `providers=[...]` attaches a plugin EP | ❌ **No** | Silently ignored — use `set_provider_selection_policy` |
| GGUF via llama.cpp engine | ✅ **Verified** | Qwen3-1.7B and 4B Q4_0 |
| `--compute` works on the llama.cpp engine | ✅ **Verified** | 28 % tok/s spread; CPU load drops 68.7 %→15.2 % |
| Speculative decoding (SSD) 81 % claim | ⬜ **Unverified** | Llama assets licence-restricted; local `ngram-*` gives ~4 % — see [§6.4](#64-what-we-could-and-could-not-verify) |
| Direct NPU utilization measurement | ✅ **Verified** | `GPU Engine(*engtype_compute)`, luid `0x13d0d` → **100 %** |
| Direct GPU utilization measurement | ✅ **Verified** | `GPU Engine(*engtype_3d)`, luid `0x133c8` → **87 %** |
| NPU faster than CPU on sustained load | ✅ **Verified** | 29.1 vs 27.5 tok/s at 4B; CPU throttles 19 %, NPU does not |
| `--compute` changes placement for QAIRT bundles | ❌ **No effect** | 1.4 % spread — flag is `llama_cpp only`; see [Section 7](#7-proving-which-compute-unit-actually-runs) |

---

## 3. Choosing a stack

| Goal | Layer | Compute | Accepted format |
| --- | --- | --- | --- |
| Fastest path to working inference | GenieX CLI | NPU / GPU / CPU | AI Hub bundles, GGUF |
| Inference inside Python | GenieX Python SDK | NPU / GPU / CPU | AI Hub bundles, GGUF |
| Drop-in for LangChain / OpenAI clients | `geniex serve` | NPU / GPU / CPU | AI Hub bundles, GGUF |
| **C#/.NET, or least setup** | **Foundry Local** | Auto-selected (NPU here) | Curated catalogue |
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
> `geniex_llamacpp` and `geniex_qairt` *are* real identifiers — but they belong to **`qai-hub-models fetch --runtime`**, a different tool. Passing them to `geniex` will fail. See [Section 8.2](#82-ai-hub-runtime-targets).

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

Use this when you need your own token loop, or when Python is a stepping stone to a C# application — the .NET API mirrors it closely. **This works**: Phi-4-mini-reasoning runs on the Hexagon NPU at ~17 tok/s with the NPU measured at 97.7 % — see [Phi-4 on the NPU](#phi-4-on-the-npu). Two things have to be right, and both fail silently if they are not: the model format, and the `onnxruntime-genai` version.

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

Microsoft publishes a correctly-formatted ORT GenAI NPU bundle for Phi-4, and **it runs on Snapdragon X2 Elite** despite declaring `soc_model: 60` (X Elite). Both repos, verified against the Hugging Face API:

| Repo | `npu/` assets | Notes |
| --- | --- | --- |
| `microsoft/Phi-4-mini-reasoning-onnx` | ✅ `npu/qnn-int4/` (2.8 GB) | `genai_config.json` + ONNX + 4 QNN context binaries |
| `microsoft/Phi-4-mini-instruct-onnx` | ❌ none | Ships `cpu_and_mobile/` and `gpu/` only |

```powershell
uv add huggingface-hub          # provides the `hf` CLI
hf download microsoft/Phi-4-mini-reasoning-onnx --include "npu/*" --local-dir models\Phi-4-mini-reasoning-onnx
```

> Use `hf`, not `huggingface-cli` — the latter is superseded in `huggingface_hub` 1.x. Install `hf_xet` as well for faster transfers on Xet-backed repos.

**Running it.** Two requirements beyond downloading the model:

```powershell
uv add "onnxruntime-genai>=0.13.2,<0.16"
.\.venv\Scripts\python.exe src\setup\run_ort_genai.py --model-dir models\Phi-4-mini-reasoning-onnx\npu\qnn-int4
```

```python
import onnxruntime_genai as og, onnxruntime_qnn as qnn_ep

og.register_execution_provider_library("QNNExecutionProvider", qnn_ep.get_library_path())

# Registering the library is NOT enough -- attach the provider to the config,
# or GenAI builds a CPU-only session and the EPContext nodes have no EP to run on.
config = og.Config(MODEL_DIR)
config.clear_providers()
config.append_provider("QNNExecutionProvider")
model = og.Model(config)
```

Measured: loads in 5.5 s, **17.1 tok/s**, 389 tokens, **NPU peak 97.7 %** (GPU 5.1 %, compositor noise).

**Version matters more than anything else here.** `onnxruntime-genai` **0.16.0 regresses EPContext/QNN pipeline models**. Same model, same machine, same code:

| onnxruntime-genai | Result |
| --- | --- |
| 0.12.0 | *"QNN execution provider is not supported in this build"* — no QNN in that wheel |
| 0.13.2 | ✅ 19.6 tok/s |
| 0.14.1 | ✅ 20.8 tok/s |
| 0.15.2 | ✅ 18.8 tok/s |
| **0.16.0** | ❌ fails on the prompt pass |

On 0.16.0 the failure looks like this, and is easy to misread as a model or hardware problem:

```
RuntimeError: ... GroupQueryAttention ... 'present_keys_0' has shape {1,8,80,128}
but the computed output shape for this run is {1,8,4096,128}
```

`run_ort_genai.py` warns when it detects 0.16.x. Note that `og.is_qnn_available()` returned `True` on 0.12.0 even though that build has no QNN support — do not rely on it alone.

> **Correction.** Earlier revisions of this README blamed, in turn, `soc_model: 60` (X Elite) versus this machine's 88, and then a chipset incompatibility. **Both were wrong.** The model runs fine here. The `EPContext ... not compatible` error came from QNN never being attached to the session — see [the mistake above](#the-mistake-that-invalidates-most-qnn-debugging); note its exact wording, *"not compatible with any execution provider **added to the session**"*. The remaining failure was an `onnxruntime-genai` 0.16.0 regression.

**The X Elite binaries do load on X2 Elite.** Attaching QNN via the policy API, all four context binaries load cleanly:

```
QnnBackendManager::LoadCachedQnnContextFromBuffer]
  Context binary of QNNExecutionProvider_QNN_part0_... is 3.2.1.
  File mapping is only supported for versions >= 3.3.3. Disabling file mapping for this node.
```

`part0` through `part3`, with only a benign file-mapping warning. The session opens with `providers=['QNNExecutionProvider', 'CPUExecutionProvider']`. So `soc_model` was a red herring, and assets published for X Elite are **not** automatically incompatible with X2 Elite.

**What actually blocks Phi-4.** The graph is a hybrid — `{'EPContext': 36, 'GroupQueryAttention': 32, 'QuantizeLinear': 1, 'DequantizeLinear': 1}`. QNN runs the 36 compiled chunks; the 32 attention ops are ORT contrib nodes that stay on **CPU** by design. Generation then fails inside one of those CPU attention nodes on a KV-cache shape mismatch: the buffer is allocated at `{1,8,80,128}` while the run computes `{1,8,4096,128}`, tracking `max_length` from `genai_config.json`.

That points at a mismatch between this bundle and `onnxruntime-genai` 0.16's handling of `past_present_share_buffer`, not at the hardware. Pinning an older `onnxruntime-genai` is the untested next step.

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

#### The mistake that invalidates most QNN debugging

**`providers=["QNNExecutionProvider"]` does not attach the QNN execution provider.** It is silently ignored, the session runs entirely on CPU, and nothing warns you. Verbose ORT logging shows only *"Adding default CPU execution provider"* followed by *"All nodes placed on [CPUExecutionProvider]"* — no QNN initialization line at all.

QNN is a **plugin EP** registered through `register_execution_provider_library`, and the legacy `providers` list does not resolve plugin EPs. Attach it with the policy API instead:

```python
import onnxruntime as ort, onnxruntime_qnn as qnn_ep
ort.register_execution_provider_library("QNNExecutionProvider", qnn_ep.get_library_path())

so = ort.SessionOptions()
so.set_provider_selection_policy(ort.OrtExecutionProviderDevicePolicy.PREFER_NPU)
sess = ort.InferenceSession(model_path, sess_options=so)   # note: NO providers= argument
```

Measured on `squeezenet1_1` w8a8, same model and machine:

| Attachment | Nodes on QNN |
| --- | --- |
| `providers=["QNNExecutionProvider"]` | **0 / 49** — all CPU |
| `set_provider_selection_policy(PREFER_NPU)` | **1 / 1** — whole graph fused onto the NPU |

`sess_options.add_provider("QNNExecutionProvider", {...})` is a third option but is rejected here with *"Provider configuration is not supported"*.

Always confirm with profiling rather than trusting a successful `run()`:

```python
so.enable_profiling = True
sess.run(None, feeds)
import json, collections
events = json.load(open(sess.end_profiling()))
print(collections.Counter(e["args"]["provider"] for e in events
                          if e.get("cat") == "Node" and "provider" in e.get("args", {})))
```

#### Route A — compile an EPContext model, verified working

`onnxruntime_qnn` already ships `QnnHtpV81Stub.dll` (v81 = X2 Elite) alongside V68 and V73, plus the `QnnHtpPrepare.dll` compiler. Compiling on the target machine means the binary matches your HTP by construction — no `soc_model` guessing.

Use the **`ep.context_*` session options**, not `ModelCompiler`:

```python
import onnxruntime as ort, onnxruntime_qnn as qnn_ep
ort.register_execution_provider_library("QNNExecutionProvider", qnn_ep.get_library_path())

so = ort.SessionOptions()
so.set_provider_selection_policy(ort.OrtExecutionProviderDevicePolicy.PREFER_NPU)
so.add_session_config_entry("ep.context_enable", "1")
so.add_session_config_entry("ep.context_file_path", "model_epctx.onnx")
so.add_session_config_entry("ep.context_embed_mode", "1")

ort.InferenceSession("source_qdq.onnx", sess_options=so)   # writes model_epctx.onnx
```

Verified end to end on `squeezenet1_1` w8a8 from AI Hub (`qai-hub-models fetch squeezenet1_1 -r onnx -p w8a8`):

| Step | Result |
| --- | --- |
| Source | 231-node QDQ graph, 4.8 MB |
| Compile | 2.1 s → `squeezenet1_1_epctx.onnx`, **1.44 MB, 1 EPContext node** |
| Reload | **0.28 s** with `disable_cpu_ep_fallback` — NPU only |
| Inference | **0.46 ms** per run |

The payoff is load time: 2.1 s compiling on-device every session versus 0.28 s from the cached context.

> **`ort.ModelCompiler` does not work for this.** It fails with *"Conv with domain com.ms.internal.nhwc was inserted using the NHWC format as requested by QNNExecutionProvider, but was not selected by that EP ... could be a bug in layout transformer"* — on both ORT 1.30.0 and 1.27.0, with the policy API correctly applied. Use the session-option route above.

**Verify the output has EPContext nodes.** A failed compile can still emit a pass-through:

```python
import onnx, collections
m = onnx.load("model_epctx.onnx", load_external_data=False)
print(collections.Counter(n.op_type for n in m.graph.node)["EPContext"])   # must be > 0
```

Two further notes from testing: `mobilenet_v2` w8a8 will not load at all (*"two nodes with same node name"*), so not every AI Hub asset is usable. And ONNX Runtime **1.27.1 does not exist on PyPI** — 1.27.0 is the closest to AI Hub's stated version; testing on it changed nothing, so version skew was not the issue here.

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

### Method E: Microsoft Foundry Local

Microsoft's on-device runtime. It wraps ONNX Runtime, picks an execution provider automatically, manages the model cache, and exposes an OpenAI-compatible server — **with a first-party C# SDK**, which makes it the most direct route to Scout of anything here.

> The [github.com/microsoft-foundry](https://github.com/microsoft-foundry) organisation is the **Azure** Foundry platform and is cloud-oriented. The on-device project is [github.com/microsoft/foundry-local](https://github.com/microsoft/foundry-local).

```powershell
winget install --id Microsoft.FoundryLocal -e
foundry status                      # hardware + versions
foundry server start                # OpenAI-compatible, dynamic port
foundry model list                  # catalogue, with the device chosen per model
foundry model download phi-3.5-mini
foundry complete phi-3.5-mini "Plan a day in Lisbon."
```

The winget installer is `foundry-0.10.3-win-arm64-winml.msix` — a native ARM64 build on Windows ML.

**It detects this hardware correctly and does use the NPU.** `foundry status` reports the Hexagon NPU by its full SKU, and `foundry server start` downloads and initialises `QNNExecutionProvider` on first run.

**Measured here**, `phi-3.5-mini` (variant `phi-3.5-mini-instruct-qnn-npu`) over the OpenAI endpoint, 354 tokens, 3 runs:

| Metric | Value |
| --- | --- |
| Throughput | **26.5 tok/s** (26.0 / 26.8 / 26.8) |
| NPU peak | **100 %** on all three runs |
| CPU mean | 53.6 % |
| Wall | ~13.2 s |

For context, Qualcomm publishes 34.2 tok/s for the same model as a QAIRT bundle ([§9.4](#94-qualcomms-published-numbers-for-this-device)) — so Foundry Local reaches roughly 78 % of the native path while being far easier to consume. Note the CPU cost: 53.6 % against ~19 % for GenieX NPU runs, which matters on a machine also running Scout.

**It sidesteps the 0.16 regression by construction.** `foundry status` reports **ORT GenAI 0.14.1** and ORT 1.26.0 — inside the range we verified working in [Method D](#method-d-onnx-runtime-genai--qnn). The version trap is handled for you.

**Device targeting is per model, and visible.** `foundry model list` has a Device column showing what this machine will actually use, and `foundry model info <model>` lists every variant with its execution provider:

| Variant | Device | Execution provider | Size |
| --- | --- | --- | --- |
| `phi-3.5-mini-instruct-qnn-npu` | NPU | QNNExecutionProvider | 2.0 GB |
| `Phi-3.5-mini-instruct-generic-gpu` | GPU | WebGpuExecutionProvider | 2.2 GB |
| `Phi-3.5-mini-instruct-generic-cpu` | CPU | CPUExecutionProvider | 2.5 GB |

**Tool calling and NPU placement do overlap** — relevant because Scout needs tool calls. Of 37 chat/multimodal models:

| Device | With tools | Without |
| --- | --- | --- |
| NPU | **6** | 5 |
| GPU | 18 | 5 |
| CPU | 3 | 0 |

The six NPU models with tool calling are the **Qwen2.5 family**: `qwen2.5-0.5b`, `qwen2.5-1.5b`, `qwen2.5-7b` and the three `qwen2.5-coder` variants. The NPU models *without* tools are `phi-3.5-mini`, `phi-3-mini-4k`, `phi-3-mini-128k` and the two `deepseek-r1` sizes. Notably the entire `phi-4` family and all of `qwen3` route to **GPU** here, not NPU.

**Where it fits against the other paths:**

| | Foundry Local | GenieX | ORT GenAI direct |
| --- | --- | --- | --- |
| C# support | **First-party SDK** | HTTP only | NuGet, version-sensitive |
| Model sourcing | Curated catalogue (~50) | Any GGUF on HF + AI Hub | Hand-assembled |
| EP selection | Automatic | `--compute` flag | Manual, easy to get wrong |
| Version pinning | Handled | n/a | You must pin `<0.16` |
| Speed (Phi-3.5 NPU) | 26.5 tok/s | 34.2 published (QAIRT) | — |
| Licence | Proprietary | Proprietary | MIT |

**Caveats.** Microsoft states it is *"not designed as a server inference stack"*. The catalogue is curated, so arbitrary Hugging Face models are not an option the way they are with GenieX. The server binds a **dynamic port**, so discover it from `foundry status` rather than hardcoding. And `foundry report` is a bug-reporting command — it opens a pre-filled GitHub issue in your browser rather than printing a diagnostic.

---

## 6. Available models

Qualcomm publishes measured performance per model per device, so "how fast is X on my chip" rarely needs benchmarking. Everything below is **Qualcomm's published figure for Snapdragon X2 Elite CRD**, not our measurement:

```bash
.\.venv\Scripts\python.exe src\setup\model_catalog.py --device "Snapdragon X2 Elite CRD" --out .atlas-local\model_catalog.json
```

[`model_catalog.py`](src/setup/model_catalog.py) is read-only: it shells out to `qai-hub-models perf`, needs no API token, and uploads nothing. Re-run it to refresh, then pass `--markdown <json>` to regenerate these tables.

### 6.1 Language and vision-language models

Decode rate on the NPU, best across published context lengths. **Prefill matters as much as decode** — see [§9.4](#94-qualcomms-published-numbers-for-this-device).

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

`geniex model list` shows the catalogue. For the ONNX Runtime GenAI route instead, see [§5 Method D](#method-d-onnx-runtime-genai--qnn).

### 6.2 Task models

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
| `Nomic-Embed-Text` | Embeddings | 3.45 ms | 1 | ONNX Runtime | Text embeddings for Scout's retrieval index |
| `SigLIP2` | Image/text | 3.88 ms | 2 | ONNX Runtime | Newer CLIP-style image/text model |
| `OpenAI-Clip` | Image/text | 13.42 ms | 1 | ONNX Runtime | Image/text similarity; landmark and scene matching |

```powershell
qai-hub-models fetch whisper_tiny -r precompiled_qnn_onnx -p float -o models
qai-hub-models info whisper_tiny          # inputs, outputs, licence
qai-hub-models numerics whisper_tiny      # accuracy metrics
```

These are **not** GenieX models. They are ONNX/QAIRT assets run through ONNX Runtime with the QNN provider ([§5 Method D](#method-d-onnx-runtime-genai--qnn)) — remember to attach QNN with the policy API, not `providers=[...]`.

### 6.3 Choosing for Scout

| Job | Candidate | Why |
| --- | --- | --- |
| Main assistant | `Qwen3-4B-Instruct-2507` | 42.6 tok/s with 2832 prefill — best quality-per-token at 4B |
| Latency-critical | `Llama-v3.2-3B-Instruct-SSD` | **77.5 tok/s**, nearly 2× the plain 3B at the same parameter count |
| Draft model | `Qwen3-0.6B` | 112 tok/s, 7918 prefill — pairs with a larger target for speculative decoding |
| Photos of menus, signs | `Qwen3-VL-4B-Instruct` | 39.3 tok/s VLM; `Intern3.5-VL-2B` at 62.0 if latency dominates |
| Retrieval embeddings | `MiniLM-v2` (0.67 ms) or `Nomic-Embed-Text` (3.45 ms) | Scout owns the embedding pipeline; changing it is a coordinated decision ([§10](#10-atlas-project-scope)) |
| Voice input | `Whisper-Tiny` (14 ms) to `Whisper-Small` (67 ms) | 49× spread up to `Large-V3-Turbo` at 684 ms — choose on accuracy need |
| Reading text in images | `TrOCR` (5.8 ms) or `EasyOCR` (15.8 ms) | Menus, signs, tickets |
| Translation | `OpusMT-*` (~4.3 ms) | Far cheaper than asking the LLM to translate |

Three things in the numbers that are easy to miss:

- **Speculative decoding is the biggest single win Qualcomm publishes — but we could not verify it.** `Llama-v3.2-3B-Instruct-SSD` is listed at 77.5 tok/s against 42.8 for the base model on the same runtime and context, an 81 % gain. See the caveats in [§6.4](#64-what-we-could-and-could-not-verify) before relying on it.
- **Task models are cheap.** Embeddings at 0.67 ms and translation at ~4.3 ms cost a rounding error next to a single LLM token. Routing work to a specialist model beats prompting the LLM to do it.
- **8B models cluster at 21–25 tok/s** regardless of family. If 4B quality suffices, that tier is roughly twice as fast.

> These are Qualcomm's measurements under their harness. Context length is the configured window, not tokens generated, and rows come from different runtimes — `Phi-3.5-Mini-Instruct` at 34.2 is a QAIRT bundle while `Phi-4-Mini-Instruct` at 26.9 is llama.cpp, so that particular comparison is runtime as much as model. `Llama-SEA-LION-v3.5-8B-R` publishes no X2 Elite data at all. Verify anything you depend on ([§9](#9-benchmarking)).

### 6.4 What we could and could not verify

An attempt to reproduce the 77.5 tok/s SSD figure on this machine failed for reasons worth recording.

**What "SSD" means — confirmed.** `qai-hub-models info llama_v3_2_3b_instruct_ssd` describes **Self Speculative Decoding**: *"Single-model LLM inference acceleration solution that achieves on-target speed up with guaranteed output accuracy identical to the base model."* Single-model — it drafts with part of itself rather than a separate draft model.

**Why it cannot be tested here.** Every Llama asset on AI Hub is licence-restricted:

```
No pre-compiled assets available due to licensing restrictions.
Please use the qai-hub-models Python package to manually export the model.
```

Manual export needs PyTorch, which has **no Windows ARM64 wheel** ([§8.1](#81-the-npu-does-not-train)). So reproducing this number requires a separate export host — it is not a five-minute check.

**The nearest local substitute is much weaker.** GenieX exposes speculative decoding for GGUF models on the llama.cpp engine. Measured on `unsloth/Qwen3-4B-GGUF` Q4_0, NPU, 220 tokens, 2 runs each:

| Config | Tok/s | vs baseline | Wall |
| --- | --- | --- | --- |
| baseline | 30.7 | — | 9.1 s |
| `--spec-type ngram-cache` | 32.0 | **+4.2 %** | 11.1–14.6 s |
| `--spec-type ngram-simple` | 31.8 | +3.6 % | ~14 s |
| `--spec-type ngram-mod` | 31.8 | +3.6 % | 13.6–14.9 s |

**~4 %, not 81 %.** That is not a refutation — `ngram-*` is draft-free speculation, a fundamentally weaker mechanism than SSD, on a different runtime and model. But it does mean the 81 % figure rests entirely on Qualcomm's published numbers, with no independent confirmation here.

**Watch the wall-clock column.** Throughput rose ~4 % while wall time rose **30–60 %**. Speculative decoding generates and discards candidate tokens, so tok/s counts accepted tokens while the real work grows. A tok/s figure alone can make a configuration look better than it is.

**Draft-model speculation did not work at all.** `--spec-type draft-simple --draft-model unsloth/Qwen3-0.6B-GGUF:Q4_0` (a sensible ~7:1 target-to-draft ratio) failed with `SDKError(Text generation failed)` at both 3 and 5 draft tokens. Unresolved — possibly a tokenizer or configuration mismatch.

**Bottom line for Scout:** treat 77.5 tok/s as a vendor claim worth chasing, not a number to design around. The mechanism is real and Qualcomm guarantees identical output, but confirming it on this hardware means standing up an export host first.

---

## 7. Proving which compute unit actually runs

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

> **This short run is shown because it is misleading.** At only 64 tokens on a cold machine the CPU appears to win. Extending to 400 tokens on a warmed-up machine reverses it — the CPU throttles ~19 % while the NPU holds steady, and the NPU finishes ahead at both model sizes. See [§9.3](#93-what-these-numbers-mean). Compare generation rate rather than wall-clock, and generate enough tokens to reach steady state before drawing a conclusion.

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

This matters more than it sounds, and it caught a real bug in this repo's own tooling. While `providers=["QNNExecutionProvider"]` was being used, the session loaded successfully, reported `providers=['CPUExecutionProvider']`, and returned correct-shaped output — entirely on CPU. With `disable_cpu_ep_fallback` set it failed loudly instead:

```
FAIL : This session contains graph nodes that are assigned to the default CPU EP,
but fallback to CPU EP has been explicitly disabled by the user.
```

The underlying cause was the plugin-EP attachment bug in [Method D](#the-mistake-that-invalidates-most-qnn-debugging), not an unsupported graph. Three habits follow:

1. Attach QNN with `set_provider_selection_policy`, never the `providers` list.
2. Read `session.get_providers()` *after* creating the session.
3. Set `disable_cpu_ep_fallback` during validation so a silent fallback becomes an error.

**Step 4 — watch the hardware.** Task Manager → Performance shows separate **NPU** and **GPU** graphs on this device. Correlate a sustained generation against those counters rather than a brief spike.

**Step 5 — pin the conditions.** `--power-mode burst` is the default and will skew comparisons against a machine on battery or a power-saver profile. Benchmark on AC, let temperatures settle, and repeat runs.

Record for each configuration: cold-load time, time to first token, tokens/second, peak memory, context length, power mode, engine, compute unit, and driver versions.

---

## 8. Training and asset optimization

### 8.1 The NPU does not train

The Hexagon NPU is a forward-pass inference accelerator. It has no backward-propagation path, no gradient accumulation, and no optimizer state handling. You cannot fine-tune on it.

**Nor can you train on this machine at all, in native Python.** Verified against PyPI: **PyTorch publishes no `win_arm64` wheel in any release**, and `torch-directml` ships only `win_amd64` / `manylinux x86_64`. So the often-repeated "use DirectML through PyTorch on the Adreno GPU" is not achievable here with pip — there is nothing to install.

That leaves, for local gradient work:

| Option | Reality |
| --- | --- |
| Native Windows ARM64 PyTorch | ❌ No wheel exists |
| `torch-directml` on Adreno | ❌ x86-only |
| WSL2 (Linux aarch64) | ⚠️ `manylinux_2_28_aarch64` wheels exist — CPU only, tiny experiments |
| Build PyTorch from source | ⚠️ Possible in principle; substantial effort, untested |

Plan substantial LoRA/QLoRA training on a **separate CUDA host**. Paid GPU infrastructure requires explicit authorization. This also means the `qai-hub[torch]` install in Qualcomm's Workbench walkthrough **cannot succeed on this machine** — export your model on the training host, then submit the exported artifact from here.

### 8.2 AI Hub runtime targets

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

### 8.3 Compile, quantize, profile

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

### 8.4 AI Hub Workbench

Workbench is the cloud optimization service: compile, quantize, run inference and profile on hosted Qualcomm devices. It is a **separate SDK** (`qai-hub`) from the model catalog CLI (`qai-hub-models`), and unlike the catalog it **requires an API token**.

```powershell
uv add qai-hub
.\.venv\Scripts\qai-hub.exe configure --api_token <YOUR_TOKEN>   # from the AI Hub web UI
```

The token is a credential: keep it out of Git and out of shared logs. It lands in `%USERPROFILE%\.qai_hub\client.ini`, which is outside the repo.

```python
import qai_hub as hub

device = hub.Device("Snapdragon X2 Elite CRD")           # matches §1.2
compile_job  = hub.submit_compile_job(model=exported, device=device,
                                      input_specs=..., options="--target_runtime onnx")
quantize_job = hub.submit_quantize_job(model=..., calibration_data=...,
                                       weights_dtype=hub.QuantizeDtype.INT8,
                                       activations_dtype=hub.QuantizeDtype.INT8)
profile_job  = hub.submit_profile_job(model=target, device=device)
```

```bash
.\.venv\Scripts\python.exe src\setup\hub_profile.py --model models\squeezenet1_1-onnx-w8a8\squeezenet1_1.onnx --input-name image_tensor --input-shape 1,3,224,224 --input-dtype uint8
```

[`hub_profile.py`](src/setup/hub_profile.py) submits a compile job followed by a profile job and prints the per-layer compute-unit split.

**Measured — `squeezenet1_1` w8a8 on a hosted Snapdragon X2 Elite CRD:**

| Metric | Hosted device | Local (§ Route A) |
| --- | --- | --- |
| Layers on **NPU** | **46 / 46 (100 %)** | not visible per-layer |
| Inference | 0.21 ms (device-measured) | 0.46 ms (Python wall-clock) |
| First load | 2.42 s | 2.1 s (on-device compile) |
| Warm load | 0.34 s | 0.28 s (cached EPContext) |
| Peak memory | 32 MB | not measured |

The load figures agree closely across two independent measurements, which is good evidence both are right. The inference times are **not** comparable — the hosted number is device-measured, the local one is wall-clock around a Python call including interpreter overhead.

The per-layer split is what makes this worth the round trip: local counters show *an* accelerator is busy, while a profile job states that **every one of the 46 layers ran on the NPU** with none falling back.

**Two traps in the SDK**, both of which cost a failed run here:

- An ONNX with a `.data` sidecar uploads as the `.onnx` alone and fails server-side with *"should be stored in ... but it is not regular file"*. `hub_profile.py` inlines external data before uploading.
- `get_target_model()` returns a **future placeholder** rather than blocking, and a freshly submitted job sits in `CREATED` with both `success` and `failure` false. Checking immediately looks like failure when the job is merely queued. Poll until `success` or `failure` — compile took 51 s, profile 332 s including device provisioning.

**Where this fits Atlas, and where it does not.**

- ✅ **The right tool for §8 generally** — quantizing and compiling an Atlas-trained model for Snapdragon, once one exists. A profile job reports the compute unit actually used plus per-layer runtime, which is stronger evidence than anything measurable locally.
- ❌ **Not the tool for LLMs.** Qualcomm's own guidance says so: *"If you're working with a LLM, we recommend following the GenieX Docs."* It will not answer the Phi-4 benchmark in [§12](#12-backlog).
- ⚠️ **`qai-hub[torch]` will not install here** — see §8.1. Export on the training host; submit from anywhere.
- ⚠️ Quantization wants **500–1000 calibration samples**, drawn from data you are authorized to upload. Held-out evaluation answers must stay out of calibration data (§10).

Compile and profile jobs upload the model to Qualcomm's cloud. Treat every submission as an outbound data transfer.

---

## 9. Benchmarking

```bash
.\Scripts\Invoke-Benchmark.ps1 -Model "unsloth/Qwen3-4B-GGUF:Q4_0" -Repeat 3
```

Runs each compute unit N times, samples **per-core CPU utilization during** each run, and writes a timestamped CSV to `.atlas-local/benchmarks/` (git-ignored). [`Test-ComputeUnits.ps1`](Scripts/Test-ComputeUnits.ps1) is the quick sanity check; this is the one that produces a recorded result.

### 9.1 Measuring NPU and GPU utilization

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

### 9.2 Measured results

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

### 9.3 What these numbers mean

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

### 9.4 Qualcomm's published numbers for this device

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

**Which matters depends on the workload.** For Scout — retrieval-augmented prompts carrying itinerary context and tool definitions — prompts are long and replies are often short or structured. That is prefill-dominated, and points at the NPU. A chat workload generating long prose would favour the CPU. Measure your own prompt/response ratio before choosing.

**The native QAIRT path is roughly twice as fast as llama.cpp on the NPU:**

| Model | Runtime | Device | Decode tok/s |
| --- | --- | --- | --- |
| `phi_3_5_mini_instruct` w4a16 | QAIRT Context Binary | **X2 Elite** | **34.2** |
| `phi_3_5_mini_instruct` w4a16 | QAIRT Context Binary | X Elite | 10.2 |
| `phi_4_mini_instruct` q4_0 | GenieX llama.cpp NPU | X2 Elite | 18.1 |

Two things fall out. The QAIRT bundle reaches 34.2 tok/s against 18.1 for llama.cpp on the same NPU — so **runtime choice matters more than compute-unit choice**. And X2 Elite is **3.4× X Elite** on that path, which is why assets and numbers published for X Elite are a poor guide to this machine.

> These are Qualcomm's measurements under their harness, not ours. Context length is the configured window, not the number of tokens generated, so they are not directly comparable with [§9.2](#92-measured-results). Use them as a reference point and a sanity check, not as a substitute for measuring your own model.

### 9.5 Memory

This machine has **64 GB of shared system memory**, not a 64 GB model budget. Weights, KV cache, activations, runtime buffers, Windows, and your editor all draw from the same pool. Four-bit weights are roughly `parameters × 0.5 bytes` before quantization metadata and runtime overhead — the Qwen3-4B W4A16 bundle is 3.0 GiB on disk, the Q4_0 GGUF 2.2 GiB.

64 GB is generous for this class of work: 7B–14B quantized models are realistic. Long contexts are usually the binding constraint rather than weights, since KV cache grows with context length.

Start with one model, one request, and the default 4096-token context. Increase only after measuring. Keep the page file system-managed and avoid sustained paging during measurements. Tune thread count empirically — maximum logical cores is not automatically fastest.

---

## 10. Atlas project scope

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

## 11. Troubleshooting

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
| NPU looks slower than CPU | Likely a cold machine and too few tokens. Generate ≥400 and repeat — the CPU throttles ~19 %, the NPU does not. See [Section 9](#9-benchmarking) |
| `geniex pull` never finishes | It blocks when stdout is redirected. Run it in a real terminal, not a background job |
| NPU counter appears to be missing | It is `\GPU Engine(*engtype_compute)`, not an "NPU" counter set. Instances are per-process, so query with a wildcard *while* the workload runs |
| Accelerator utilization reads 0 | Sampling missed the window. Each `Get-Counter` call costs ~1 s — use one combined call and a longer generation |
| Utilization reads over 100 % | Normal for an adapter aggregating sub-engines; clamp to 100 |
| `EPContext node ... is not compatible` | QNN is not attached to the session. Use `set_provider_selection_policy(PREFER_NPU)`, or `Config.append_provider` for GenAI. Rarely a chipset issue |
| `GroupQueryAttention` / `present_keys` shape error | `onnxruntime-genai` 0.16.x regression with EPContext models. Pin `>=0.13.2,<0.16`. Also check you did not override `max_length` on a `past_present_share_buffer` model |
| `provider_options` looks empty | On pipeline models the QNN options live inside each stage, not on the top-level decoder |
| `huggingface-cli` not found | Superseded by `hf` in `huggingface_hub` 1.x |
| `pip install` finds no ARM64 wheel | Check Python minor version and ABI. Use `uvx` for x86-constrained tooling; do not silently switch native benchmarks to emulation |
| DLL load or architecture error | Interpreter, runtime, and native libraries must share an architecture |
| Model runs but NPU is idle | Re-run with `--log debug --verbose`; CPU success is not NPU validation |
| Export produces wrong-generation artifacts | Use `--device "Snapdragon X2 Elite CRD"` (HTP 81), not `X Elite` (HTP 73) |
| Out-of-memory or sustained paging | Reduce `--nctx`, concurrency, or model size; account for duplicate cached copies |
| Exported model regresses | Compare tokenizer/template, merge, quantization calibration, stop tokens, and context against the baseline |

---

## 12. Backlog

### Benchmark ORT GenAI against GenieX GGUF for Phi-4

**What.** Run a controlled head-to-head of the two working NPU paths on the same model, using [`Invoke-Benchmark.ps1`](Scripts/Invoke-Benchmark.ps1) conditions for both: same prompt, ≥400 tokens, 3+ runs, `burst` power mode, AC power, warm machine, with NPU utilization sampled.

**Why.** Both paths now work, and the numbers so far disagree — but they were not measured comparably:

| Path | Model | Measured |
| --- | --- | --- |
| GenieX GGUF (llama.cpp) | `unsloth/Phi-4-mini-reasoning-GGUF` Q4_0 | 24.1 tok/s |
| ORT GenAI (EPContext) | `microsoft/Phi-4-mini-reasoning-onnx` qnn-int4 | 17.1 tok/s |

Those are **different quantizations, different runtimes, different token counts, and different thermal states**, so the ~40 % gap is not yet a real result. Section 9 already showed that measuring a cold machine briefly reverses a conclusion outright, so this needs the same discipline.

**Why it matters.** Scout needs a runtime decision, and the two paths trade off differently:

- **ORT GenAI** — in-process control over the token loop, and the direct route to C# via `Microsoft.ML.OnnxRuntimeGenAI`. Costs a version pin (`>=0.13.2,<0.16`) and a narrow supply of compatible models.
- **GenieX** — faster in the numbers so far, far easier model sourcing (any GGUF from Hugging Face), and an OpenAI-compatible server. Costs process isolation and an HTTP hop.

If GenieX really is ~40 % faster, that likely outweighs in-process control and C# should talk to `geniex serve`. If the gap closes under fair conditions, ORT GenAI is the cleaner integration. Decide with numbers, not architecture preference.

**Confounder to resolve first.** `qnn-int4` and `Q4_0` are not the same quantization, so part of any gap is the weights rather than the runtime. Either find one model published in both formats, or treat the result as a path comparison rather than a runtime comparison and say so.

**Measure prefill separately from decode.** Qualcomm's own figures ([§9.4](#94-qualcomms-published-numbers-for-this-device)) show the two phases favouring different compute units — NPU 3–4× on prefill, CPU ~25 % on decode. A single tok/s number averages away the distinction that actually decides the runtime for Scout, whose prompts are long and replies often short.

**Also benchmark the native QAIRT path.** Qualcomm measures `phi_3_5_mini_instruct` w4a16 QAIRT at 34.2 tok/s against 18.1 for `phi_4_mini_instruct` q4_0 on llama.cpp NPU. If that ~2× holds, the comparison is really three-way: ORT GenAI, GenieX llama.cpp, and GenieX QAIRT — and the QAIRT bundle may beat both paths measured so far.

### Verify tool calling on the NPU with `qwen2.5-7b`

**What.** Pull `qwen2.5-7b` through Foundry Local, confirm it loads the NPU variant, and verify that **tool calling actually works while running on the NPU** — not just that the catalogue advertises it.

```powershell
foundry model info qwen2.5-7b            # confirm an NPU variant with QNNExecutionProvider
foundry model download qwen2.5-7b        # ~6.8 GB
foundry server start
# POST /v1/chat/completions with a `tools` array; assert tool_calls in the response
```

Sample the NPU counter during the call, the same way [`Invoke-Benchmark.ps1`](Scripts/Invoke-Benchmark.ps1) does:
`\GPU Engine(*engtype_compute)\Utilization Percentage`, adapter luid `0x00013d0d`.

**Why this model.** Scout needs tool calls, and of Foundry Local's 37 chat/multimodal models only **six** combine NPU placement with tool support — all Qwen2.5:

| Model | Size | Device | Tools |
| --- | --- | --- | --- |
| `qwen2.5-7b` | 6.8 GB | NPU | yes |
| `qwen2.5-1.5b` | 1.1 GB | NPU | yes |
| `qwen2.5-0.5b` | 442 MB | NPU | yes |
| `qwen2.5-coder-7b` / `-1.5b` / `-0.5b` | 0.4–7.1 GB | NPU | yes |

Everything else either loses tool calling (`phi-3.5-mini`, `phi-3-mini-*`, `deepseek-r1-*`) or moves off the NPU (the whole `phi-4` family, all of `qwen3`, routed to GPU here). `qwen2.5-7b` is the largest NPU + tools option, so it sets the quality ceiling for that combination.

**Why it is not settled.** Three things could each break it:

- The **Tools** flag may describe the model family rather than the specific NPU variant. The catalogue lists one flag per model while `foundry model info` lists separate NPU/GPU/CPU variants.
- Tool calling may **force a fallback**. Constrained or grammar-based decoding sometimes runs outside the accelerated path; if so the NPU counter will sit near zero during a tool-calling request even though a plain completion pegs it at 100 %.
- At 6.8 GB it is the **largest NPU model** in the catalogue. Confirm it loads and holds context without paging — `phi-3.5-mini` at 2.0 GB is the only NPU model measured so far.

**What good looks like.** A tool-calling request returns a well-formed `tool_calls` payload, the NPU counter peaks near 100 % during it, and throughput is within range of the 26.5 tok/s measured for `phi-3.5-mini`. If tool calls work but drop to CPU, that is still a usable answer — it just means Scout pays NPU speed only on plain generation.

**If it fails**, fall back to `qwen2.5-1.5b` to separate a size problem from a tool-calling problem, and compare against the same request on the GPU variant.

### Other open threads

| Item | Note |
| --- | --- |
| Scope of the 0.16.0 regression | Unknown whether it broke EPContext models specifically or QNN more broadly. Worth reporting upstream if reproducible on a second model |
| C# / .NET path | Foundry Local ships a first-party C# SDK and handles the version pin itself ([§5 Method E](#method-e-microsoft-foundry-local)) — likely the shortest route for Scout. Untested |
| NPU headroom | Utilization is clamped to 100 % in tooling (raw readings hit 238 %), and a hosted profile gives per-layer placement but not saturation. SqueezeNet peaked at 32 MB, suggesting room; unmeasured for LLMs |
| `ort.ModelCompiler` NHWC failure | Fails on both ORT 1.27.0 and 1.30.0 where the `ep.context_*` session options succeed. Possibly an ORT bug |
| Long-context behaviour | All benchmarks are short generations. KV cache growth is the likely binding constraint for Scout and is unmeasured |
| Battery operation | Everything measured on AC with `burst`. Deployment behaviour on battery is unknown |
| `mobilenet_v2` w8a8 | Will not load at all (*"two nodes with same node name"*), so AI Hub assets are not uniformly usable |
| Workbench profile job for a *trained* Atlas model | Done once for SqueezeNet (§8.4, 46/46 layers on NPU). Repeat for real artifacts once Atlas produces one |
| Scout's prompt/response ratio | Decides CPU vs NPU. Prefill-heavy favours NPU 3–4×, decode-heavy favours CPU ~25 % (§9.4). Measure real Scout traffic |
| `qualcomm/Phi-3.5-Mini-Instruct` QAIRT | Published at 34.2 tok/s on X2 Elite, ~2× the llama.cpp NPU path. Already in the GenieX catalogue — pull and verify |
| Verify the SSD 81 % speedup | Needs an export host with PyTorch, since Llama assets are licence-restricted (§6.4). Worth it: 81 % dwarfs every other tuning lever found so far |
| `--spec-type draft-simple` failure | Fails with `SDKError(Text generation failed)` using Qwen3-0.6B as draft for Qwen3-4B. Tokenizer or config mismatch unknown |

---

## References

- [GenieX — what is GenieX](https://geniex.aihub.qualcomm.com/en/get-started/what-is-geniex) · [CLI install](https://geniex.aihub.qualcomm.com/en/run/cli/install) · [qualcomm/GenieX on GitHub](https://github.com/qualcomm/GenieX)
- [qualcomm/ai-hub-models](https://github.com/qualcomm/ai-hub-models)
- [ONNX Runtime GenAI QNN guidance](https://github.com/microsoft/onnxruntime-genai/blob/main/docs/qnn.md)
- [QNN Execution Provider](https://github.com/onnxruntime/onnxruntime-qnn/blob/main/docs/execution_providers/QNN-ExecutionProvider.md)
- [Windows on Arm overview](https://learn.microsoft.com/en-us/windows/arm/overview)
- [AGENTS.md](AGENTS.md) — contributor and coding-agent rules

Environment facts verified 2026-09-19 against GenieX v0.7.0, onnxruntime 1.30.0, onnxruntime-genai 0.16.0, qai-hub-models-cli 0.62.2. Update the status table in [Section 2](#2-verification-status) as paths are proven.
