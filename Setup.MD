# Atlas development setup

This guide prepares a Windows ARM Snapdragon Surface with **32 GB RAM** for Atlas development, dataset review, evaluation, and local inference experiments. Substantial fine-tuning belongs on a separate supported GPU host. The Surface NPU is not assumed to support general-purpose training.

Atlas currently contains documentation only. No base model, dependency lock, training pipeline, export format, or Scout runtime integration has been selected or tested. Commands below inspect or prepare an environment; they are not Atlas training commands. Runtime choices are candidates until measured on the target machine.

## 1. Confirm the target hardware

The owner supplied this [hardware reference](https://share.google/aimode/pPf90gGwCzCaoq00z) and the specifications below. The share link could not be retrieved; these are user-provided specifications, not independently verified hardware measurements. The actual machine is configured with **32 GB RAM**, overriding the supplied specification sheet's 16 GB base configuration.

| Component | Reported target configuration |
| --- | --- |
| Device | 13.8-inch Surface, exact product generation/model identifier to record |
| CPU | Qualcomm Snapdragon X2 Elite, 12 cores |
| NPU | Qualcomm Hexagon, advertised up to 80 TOPS |
| GPU | Integrated Qualcomm Adreno |
| Memory | 32 GB LPDDR5x |
| Storage | Specification sheet lists 512 GB replaceable NVMe, with larger options; verify installed capacity and free space |
| Display | 2304 x 1536 PixelSense Flow touchscreen, up to 120 Hz |
| Connectivity | Reported USB4/Thunderbolt 4 USB-C ports, USB-A, Wi-Fi 7, Bluetooth 5.4 |

NPU TOPS are not an LLM throughput or model-capacity measurement. Confirm **X2 Elite** support explicitly in the chosen runtime, driver, and model compilation recipe; support documented for earlier Snapdragon X devices does not establish X2 compatibility. Record the exact processor SKU and Windows build from the device before selecting compiled artifacts. External SSDs can hold model copies, but active inference performance still requires measurement on the chosen storage.

Run in PowerShell on the target Surface:

```powershell
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemType, @{Name='RAM_GiB';Expression={[math]::Round($_.TotalPhysicalMemory / 1GB, 1)}}
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, Size, SizeRemaining
[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
```

Also inspect Task Manager's Performance tab and Device Manager for GPU/NPU names and driver versions. Keep a sanitized hardware summary with the first experiment; omit serial numbers and other device identifiers. The shell process architecture should be Arm64 for native checks.

Install Windows updates and the Surface model's applicable firmware/driver updates, restart, then record versions. Use [Microsoft's Surface update instructions](https://support.microsoft.com/en-US/surface/drivers-firmware/download-drivers-and-firmware-for-surface); do not install another Surface model's firmware.

## 2. Install the development tools

Prefer native ARM64 tools. An x64 application running through emulation does not demonstrate native inference performance. See [Microsoft's Windows on Arm overview](https://learn.microsoft.com/en-us/windows/arm/overview).

| Tool | Setup and purpose |
| --- | --- |
| Git | Install [Git for Windows](https://git-scm.com/downloads/win); choose ARM64 when offered. Required for source and experiment history. |
| Editor | Install [Visual Studio Code for Windows ARM64](https://code.visualstudio.com/download). Add Microsoft's Python and Pylance extensions for Python work. |
| Shell | Use a native ARM64 PowerShell session. [PowerShell installation instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) cover the available packages. |
| Python | Install a full Windows ARM64 Python distribution from [Python's Windows downloads](https://www.python.org/downloads/windows/), not the embeddable package. Select a supported minor version with wheels for the planned dependencies. Pin the exact version when the first pipeline is implemented. |
| Native build tools, conditional | For source builds, install Arm-native Visual Studio with Desktop development with C++, an ARM64 MSVC toolset, Windows SDK, and the CMake/LLVM components required by the selected runtime. Follow [Visual Studio on Arm](https://learn.microsoft.com/en-us/visualstudio/install/visual-studio-on-arm-devices) and that runtime's build guide. Prebuilt runtime packages may avoid this requirement. |
| .NET SDK, conditional | For Scout integration, install the ARM64 SDK matching Scout's own SDK selection/global.json. Check `dotnet --info`. Atlas does not yet require a .NET SDK. |

Verify the basic tools in a fresh terminal:

```powershell
git --version
code --version
python --version
python -c "import sys, platform, struct; print(sys.executable); print(platform.machine()); print(struct.calcsize('P') * 8)"
```

Python must report ARM64 and 64 bits for the native environment. If it reports AMD64, select the installed ARM64 interpreter explicitly. In VS Code, use **Python: Select Interpreter** to select the environment created below.

WSL, Docker, CUDA, and a full training stack are not prerequisites for this documentation-stage checkout. If Linux tooling later needs WSL, remember that Linux ARM64 packages differ from Windows ARM64 packages; do not assume a WSL environment provides the Windows QNN/NPU path.

## 3. Prepare the checkout and local storage

Open your existing Atlas checkout, or clone its actual repository URL into a directory you control. The commands below assume PowerShell is already at the repository root. No particular drive letter is required.

Before creating environments or outputs in the checkout, add these entries to the root `.gitignore` if absent:

```gitignore
# Local Python environments and caches
.venv/
.venv-*/
__pycache__/
*.py[cod]
.pytest_cache/
.ruff_cache/
.ipynb_checkpoints/
# Local data, model binaries, and run outputs
.atlas-local/
.env
.env.*
!.env.example
```

These are setup instructions; this document does not itself change ignore rules. Keep generated data and models in external storage or `.atlas-local/`, and verify exclusions with `git status --short --untracked-files=all` before staging. Ignore rules do not remove previously tracked files. Keep compact reviewed fixtures, configurations, manifests, and result summaries in Git.

Create a small native environment without changing PowerShell execution policy:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip --version
.\.venv\Scripts\python.exe -c "import platform; print(platform.machine())"
```

Use the explicit interpreter path rather than requiring script activation. There is no requirements file to install yet. When adding dependencies, verify ARM64 wheel availability, record exact resolved versions, and commit the appropriate lock/configuration files. Use separate environments for data preparation, inference, conversion, and training when their requirements differ; never reuse a virtual environment across architectures or hosts.

Example session-local storage configuration outside the repository:

```powershell
$env:ATLAS_DATA_DIR = Join-Path $env:LOCALAPPDATA 'Atlas\data'
$env:ATLAS_MODEL_DIR = Join-Path $env:LOCALAPPDATA 'Atlas\models'
$env:ATLAS_RUN_DIR = Join-Path $env:LOCALAPPDATA 'Atlas\runs'
$env:HF_HOME = Join-Path $env:LOCALAPPDATA 'Atlas\cache\huggingface'
```

The `ATLAS_*` names are proposed conventions for future scripts, not implemented configuration. Set them to suitable storage on each host. Set cache locations before downloading models. Budget for source weights, converted copies, temporary conversion files, adapters, and caches; storage requirements depend on the chosen model. Use a credential manager or session secrets for authenticated downloads, never tracked configuration. External storage still requires suitable access controls for private data.

## 4. Prove a local inference path before fine-tuning

Select a small instruct model only after checking its license, tokenizer/chat template, runtime architecture support, and adaptation/export path. A quantized 1-4B model is a reasonable **initial experiment**, not an established Atlas model choice or a performance guarantee.

### Candidate A: native CPU baseline

Use a pinned Windows ARM64 build of [llama.cpp](https://github.com/ggml-org/llama.cpp) with a supported GGUF model to establish a local CPU reference. Follow its [Windows ARM64 build instructions](https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md) if building from source; compiler and preset requirements depend on the selected revision. Record the release/commit and binary checksum. Verify the selected model's conversion and adapter merge workflow before adopting GGUF.

Use the selected release's supplied CLI help to configure a short prompt, batch size one, and a modest context. Record a successful generation and runtime logs. A working CPU route is useful even if NPU support is unavailable; it does not establish Scout compatibility by itself.

### Candidate B: Qualcomm NPU inference

Evaluate ONNX Runtime/QNN with a model prepared for the selected backend. Installing a package or exporting arbitrary ONNX is not enough to make a model run on the NPU. ONNX Runtime GenAI's [QNN guidance](https://github.com/microsoft/onnxruntime-genai/blob/main/docs/qnn.md) describes the model packaging and runtime path.

Choose one documented, compatible release set for the runtime, QNN provider, QAIRT dependencies, model recipe, Python or .NET binding, and device drivers. The [QNN provider documentation](https://github.com/onnxruntime/onnxruntime-qnn/blob/main/docs/execution_providers/QNN-ExecutionProvider.md) and [older integrated-provider documentation](https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html) describe different generations; do not mix their installation or provider-registration instructions. Published Python requirements also differ between prebuilt packages and source builds. Verify the actual Windows ARM64 wheel and Python ABI for the chosen release before creating its environment.

Perform conversion/quantization on the host architecture supported by that release's recipe, which may require an x64 host. Keep conversion tooling separate from native Surface inference. Hosted conversion or profiling sends data outside the machine and requires authorization for the artifacts involved.

Run the release's official sample with its supported model, then the Atlas candidate. Capture provider initialization, partition/profiling evidence, and fallback behavior. A listed provider or NPU utilization graph alone does not prove the entire model executes there. Report CPU fallback and mixed execution explicitly. Use native Windows for this validation.

### Runtime acceptance gate

Before training, demonstrate on the Surface:

- Repeatable base-model generation and a documented Scout-compatible invocation boundary.
- Pinned tokenizer/chat template; correct stop tokens and supported context limits.
- Structured-response and tool-call behavior under representative Scout prompts.
- A supported adapter loading or merge path, followed by export/quantization of the resulting model.
- Actual CPU/GPU/NPU execution evidence and measured memory/latency.

Keep the original base weights and baseline results unchanged. A deployment-format conversion of the base should be tracked as a separate artifact.

## 5. Tune experiments for 32 GB shared memory

Start with one model loaded, one request at a time, and a 2,048-token context if supported by the chosen artifact. Increase context and concurrency only after measuring. These are proposed starting settings, not benchmark results.

The 32 GB is system memory, not a dedicated 32 GB model budget. Weights, KV cache, activations, runtime buffers, Windows, Scout, and other applications all consume memory. Four-bit weights alone are approximately parameter-count times 0.5 bytes, before quantization metadata and runtime overhead. Long contexts can materially increase memory consumption.

Keep the Windows page file system-managed and avoid sustained paging during measurements. Close unnecessary memory-heavy apps. Benchmark on AC power with a recorded power mode, allow temperatures to settle, and repeat measurements to expose thermal effects. Test battery operation separately if it matters to deployment. Tune thread count empirically; maximum logical-core count is not automatically fastest.

For each configuration, record cold-load time, time to first token, generation tokens/second, end-to-end latency, peak process/system memory, context length, prompt/output token counts, concurrency, and accelerator evidence. Include warm-up policy, repeated-run statistics, power mode, driver versions, and runtime settings. Compare artifacts under the same conditions and retain quality measurements alongside speed.

## 6. Prepare data and a separate training host

Begin with approximately 50-100 reviewed evaluation scenarios covering preference interpretation, grounding, constraints, structured output, and tool selection. Diagnose retrieval, tool, data, and prompt failures before deciding that training is needed.

Use synthetic or approved sanitized examples with provenance and permitted-use records. Deduplicate and split before training; hold out trips/regions where practical. Keep held-out answers out of training and quantization calibration. Production databases and raw private conversations are not setup inputs.

When a behavioral gap justifies an adapter experiment:

1. Select a supported GPU host, typically Linux with an NVIDIA GPU, sized for the chosen model, sequence length, and training method. Local Snapdragon RAM/NPU specifications do not establish training capacity. Paid infrastructure requires explicit authorization.
2. Install the driver and a matching supported PyTorch/CUDA stack using [PyTorch's installation selector](https://pytorch.org/get-started/locally/). Capture `nvidia-smi` and verify GPU execution there. Do not install this CUDA stack on the Surface.
3. Pin the training framework, tokenizer stack, adapter library, and any quantization backend against that host. LoRA/QLoRA support must be confirmed for the model and hardware before selecting package versions.
4. Transfer only approved data, use configurable paths, and run a tiny reproducible adapter smoke experiment before longer training.
5. Return the adapter/merged artifact through the already proven export path, then evaluate the final quantized artifact on the actual Surface.

No Atlas training command exists yet. Add a locked environment and runnable reproduction instructions with the first implemented experiment rather than installing an unvalidated package bundle now.

## 7. Record and hand off reproducible results

For each experiment retain the base-model immutable revision and license, dataset version and split hashes, code commit plus any local changes, configuration, seeds, dependency versions, host hardware/drivers, tokenizer and template revisions, adapter/merge details, and artifact checksums. Use `git rev-parse HEAD` and `git status --short` to identify code state; use PowerShell `Get-FileHash -Algorithm SHA256` with the actual artifact path to calculate checksums.

Version the Scout model manifest with artifact locations, runtime compatibility, context limits, quantization, input/output/tool-call conventions, evaluation results, and known limitations. Scout validates and executes tool proposals. Compare the base, tuned model, and final quantized artifact on identical held-out tasks, including regressions and local latency/memory.

Setup is ready for the first experiment when:

- Exact Surface/SoC, Windows build, drivers, memory, and storage are recorded.
- Editor, Git, and Python work; the local interpreter and inference runtime are native ARM64.
- Local environments/data/model outputs are excluded from Git and paths are configurable.
- A licensed candidate produces reproducible baseline output within measured memory limits.
- Export/adapter and Scout runtime compatibility are demonstrated before training investment.
- Training, conversion, and target-inference environments have separate recorded dependencies.

## Troubleshooting

| Symptom | Next check |
| --- | --- |
| No matching Python distribution/wheel | Check Python minor version, ABI, OS, and ARM64 wheel availability. Use a supported separate environment or conversion host; do not silently switch native benchmarks to x64 emulation. |
| DLL load or architecture error | Check that interpreter, runtime, dependencies, and native libraries share the required architecture. Install the runtime's documented redistributables. |
| QNN unavailable or model fails to load | Check device support, driver/provider/runtime versions, backend libraries, model recipe, and provider registration for the chosen release. |
| Model works but NPU is idle | Inspect runtime profiling and partition/fallback logs; CPU inference success is not NPU validation. |
| Out-of-memory or sustained paging | Reduce context, concurrency, batch size, or model size; account for caches and duplicate model copies. |
| Exported model regresses | Compare tokenizer/template, merge, quantization/calibration, stop tokens, and context settings against the unchanged baseline. |

Documentation sources were consulted on 2026-09-17. Installation and inference have not been performed as part of writing this guide. Update this document with tested versions and results as pipelines are implemented. See [README.md](README.md) for project scope and [AGENTS.md](AGENTS.md) for repository rules.
