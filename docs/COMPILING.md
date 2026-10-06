# Compiling and profiling your own models

The [README](../README.md) covers running models that someone else has already
built for this hardware. This file covers the other direction: taking a model
of your own through Qualcomm AI Hub, or compiling an NPU context binary on the
machine itself.

You do not need any of this to run a model. Reach for it when no published
asset fits, or when you want per-layer evidence of where a graph executes.

---

## Contents

- [Why training does not happen here](#why-training-does-not-happen-here)
- [The AI Hub CLI](#the-ai-hub-cli)
- [Runtime targets](#runtime-targets)
- [Compile, quantize, profile](#compile-quantize-profile)
- [AI Hub Workbench](#ai-hub-workbench)
- [Compiling an EPContext model locally](#compiling-an-epcontext-model-locally)
- [Why you cannot simply recompile a published bundle](#why-you-cannot-simply-recompile-a-published-bundle)

---

## Why training does not happen here

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


---

## The AI Hub CLI

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


---

## Runtime targets

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


---

## Compile, quantize, profile

Once a model is trained and exported to PyTorch or FP32 ONNX, convert it to an NPU-compatible INT4/INT8 layout through AI Hub. Target **`Snapdragon X2 Elite CRD`** — confirmed present in the device catalog with HTP version 81.

```powershell
qai-hub-models info mobilenet_v2

qai-hub-models export yolov7 `
  --target-runtime onnx `
  --precision int8 `
  --device "Snapdragon X2 Elite CRD"

qai-hub-models demo yolov7 --eval-mode fp
```

> **Check the device string carefully.** `"Snapdragon X Elite CRD"` is the *previous* generation (HTP 73). Compiling against it will not produce artifacts tuned for this machine's HTP 81.

If native resolution of the source-export dependencies fails on ARM64, prefix with `uvx --from qai-hub-models-cli`. Note that AI Hub compilation and profiling **upload your model to Qualcomm's cloud** — treat it as a data transfer requiring authorization for the artifacts involved.


---

## AI Hub Workbench

Workbench is the cloud optimization service: compile, quantize, run inference and profile on hosted Qualcomm devices. It is a **separate SDK** (`qai-hub`) from the model catalog CLI (`qai-hub-models`), and unlike the catalog it **requires an API token**.

```powershell
uv add qai-hub
.\.venv\Scripts\qai-hub.exe configure --api_token <YOUR_TOKEN>   # from the AI Hub web UI
```

The token is a credential: keep it out of Git and out of shared logs. It lands in `%USERPROFILE%\.qai_hub\client.ini`, which is outside the repo.

```python
import qai_hub as hub

device = hub.Device("Snapdragon X2 Elite CRD")           # matches the README's [chip-to-target step](../README.md#22-match-your-chip-to-a-runtime-target)
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

[`hub_profile.py`](../src/setup/hub_profile.py) submits a compile job followed by a profile job and prints the per-layer compute-unit split.

**Measured — `squeezenet1_1` w8a8 on a hosted Snapdragon X2 Elite CRD:**

| Metric | Hosted device | Local (compiled here) |
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

**What it is good for, and what it is not.**

- ✅ **The right tool for this file** — quantizing and compiling a model you trained yourself for Snapdragon. A profile job reports the compute unit actually used plus per-layer runtime, which is stronger evidence than anything measurable locally.
- ❌ **Not the tool for LLMs.** Qualcomm's own guidance says so: *"If you're working with a LLM, we recommend following the GenieX Docs."* It will not answer the Phi-4 benchmark in [the archive](ARCHIVE.md).
- ⚠️ **`qai-hub[torch]` will not install here** — see the training note above. Export on the training host; submit from anywhere.
- ⚠️ Quantization wants **500–1000 calibration samples**, drawn from data you are authorized to upload. Held-out evaluation answers must stay out of calibration data.

Compile and profile jobs upload the model to Qualcomm's cloud. Treat every submission as an outbound data transfer.

---

## Compiling an EPContext model locally

`onnxruntime_qnn` ships `QnnHtpV81Stub.dll` (v81 = X2 Elite) alongside V68 and
V73, plus the `QnnHtpPrepare.dll` compiler. **Compiling on the target machine
means the binary matches your HTP by construction** — no `soc_model` guessing.

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

> **Use the session options, not `ort.ModelCompiler`.** The latter fails here: It fails with *"Conv with domain com.ms.internal.nhwc was inserted using the NHWC format as requested by QNNExecutionProvider, but was not selected by that EP ... could be a bug in layout transformer"* — on both ORT 1.30.0 and 1.27.0, with the policy API correctly applied. Use the session-option route above.

**Verify the output has EPContext nodes.** A failed compile can still emit a pass-through:

```python
import onnx, collections
m = onnx.load("model_epctx.onnx", load_external_data=False)
print(collections.Counter(n.op_type for n in m.graph.node)["EPContext"])   # must be > 0
```

Not every AI Hub asset is usable: `mobilenet_v2` w8a8 will not load at all (*"two nodes with same node name"*).

**Route B — full QAIRT SDK.** Needed when the graph requires Qualcomm's own quantizer. Broadly: install the QAIRT SDK, convert and quantize with `qairt-converter` / `qairt-quantizer` using a representative calibration set, generate the context binary with `qnn-context-binary-generator` against `QnnHtp.dll` for your SoC, then wrap it with ONNX Runtime's `gen_qnn_ctx_onnx_model.py` and hand-write a `genai_config.json` describing the pipeline stages. Consult [Qualcomm's ONNX model preparation docs](https://docs.qualcomm.com/doc/80-80022-15B/topic/onnx-prepare-model.html) and [ORT's Snapdragon build guide](https://onnxruntime.ai/docs/genai/howto/build-models-for-snapdragon.html) for current commands.

**The API is verified; a full model is not.** The compile route below works on a small graph. Producing a functioning Phi-4 EPContext model end to end has not been done here. Budget real effort, and weigh it against simply using the GenieX GGUF path, which runs Phi-4 on the NPU today.

**The generation API changed.** Code written against older `onnxruntime-genai` examples fails on 0.16 and later, even with a correct model:

| Removed | Replacement |
| --- | --- |
| `params.set_input_ids(tokens)` | `generator.append_tokens(tokens)` |
| `params.set_search_property("max_length", 512)` | `params.set_search_options(max_length=512)` |
| `generator.compute_logits()` | removed — `generate_next_token()` suffices |

The current shape, as implemented in [`run_ort_genai.py`](../src/setup/run_ort_genai.py):

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


---

## Why you cannot simply recompile a published bundle

**Read the blocker first.** Recompiling needs a **QDQ-quantized source ONNX** of the transformer stages. Microsoft publishes only the already-compiled `phi_4_mini_ctx.onnx_ctx.onnx` and `phi_4_mini_iter.onnx_ctx.onnx` — you cannot recompile a context binary, it is the output. Two facts close off the obvious shortcuts:

- The ONNX Runtime GenAI **model builder cannot target QNN**. Verified locally: `onnxruntime_genai/models/builder.py` accepts `-e` of only `cpu`, `cuda`, `dml`, `webgpu`, `NvTensorRtRtx`. Microsoft's NPU bundle came from a different toolchain.
- `microsoft/Phi-4-mini-instruct-onnx` ships no NPU assets, and its `cpu_and_mobile` / `gpu` graphs are not QDQ-quantized for HTP.

So this is a build-from-scratch exercise, not a re-run of a published step.
