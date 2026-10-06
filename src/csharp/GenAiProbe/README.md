# GenAiProbe

Runs a language model on the Hexagon NPU through **ONNX Runtime GenAI from C#**.
The Python equivalent is `src/setup/run_ort_genai.py`.

```powershell
dotnet run -c Release --project src\csharp\GenAiProbe
dotnet run -c Release --project src\csharp\GenAiProbe -- --cpu-only   # skips registration
```

Expects `models/Phi-4-mini-reasoning-onnx/npu/qnn-int4`; pass another path as
the first argument. Download it with:

```powershell
hf download microsoft/Phi-4-mini-reasoning-onnx --include "npu/*" --local-dir models\Phi-4-mini-reasoning-onnx
```

Two things must both be right, and neither fails loudly on its own: the QNN
plugin has to be registered, and the provider has to be attached to the
`Config`. Registering alone leaves GenAI building a CPU-only session with
nothing to run the EPContext nodes on.

See the README section "Hello world — C#" for measured results.
