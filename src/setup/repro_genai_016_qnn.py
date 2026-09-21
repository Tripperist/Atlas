"""Minimal reproduction: onnxruntime-genai 0.16.0 regresses EPContext/QNN models.

Self-contained. Downloads the NPU build of microsoft/Phi-4-mini-reasoning-onnx,
attaches the QNN execution provider, and runs a single prompt pass.

    pip install onnxruntime-genai==0.15.2 onnxruntime-qnn huggingface_hub
    python repro_genai_016_qnn.py          # expect PASS

    pip install onnxruntime-genai==0.16.0
    python repro_genai_016_qnn.py          # expect FAIL

Exit code 0 on success, 1 on the regression, 2 on a setup problem.
"""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

REPO = "microsoft/Phi-4-mini-reasoning-onnx"
SUBDIR = "npu/qnn-int4"
LOCAL = Path("Phi-4-mini-reasoning-onnx")
PROMPT = "<|user|>\nWhat is 17 times 23?<|end|>\n<|assistant|>"


def fetch_model() -> Path:
    target = LOCAL / SUBDIR
    if (target / "genai_config.json").exists():
        print(f"[ OK ] model already present at {target}")
        return target
    print(f"[INFO] downloading {REPO} ({SUBDIR}, ~2.8 GB) ...")
    from huggingface_hub import snapshot_download

    snapshot_download(repo_id=REPO, allow_patterns=f"{SUBDIR}/*", local_dir=str(LOCAL))
    return target


def main() -> int:
    try:
        import onnxruntime as ort
        import onnxruntime_genai as og
        import onnxruntime_qnn as qnn_ep
    except ImportError as exc:
        print(f"[SETUP] missing dependency: {exc}")
        return 2

    print(f"onnxruntime-genai : {getattr(og, '__version__', '?')}")
    print(f"onnxruntime       : {ort.__version__}")
    print(f"python            : {sys.version.split()[0]} {sys.platform}")

    try:
        model_dir = fetch_model()
    except Exception as exc:  # noqa: BLE001
        print(f"[SETUP] download failed: {exc}")
        return 2

    og.register_execution_provider_library(
        "QNNExecutionProvider", qnn_ep.get_library_path()
    )

    # Registering the library is not sufficient: the provider must also be
    # attached to the config, or GenAI builds a CPU-only session and the
    # EPContext nodes have no execution provider to run on.
    config = og.Config(str(model_dir))
    config.clear_providers()
    config.append_provider("QNNExecutionProvider")

    model = og.Model(config)
    tokenizer = og.Tokenizer(model)
    print("[ OK ] model loaded")

    generator = og.Generator(model, og.GeneratorParams(model))

    try:
        # Fails here on 0.16.0.
        generator.append_tokens(tokenizer.encode(PROMPT))
    except Exception as exc:  # noqa: BLE001
        print("\n[FAIL] append_tokens raised:\n")
        traceback.print_exc()
        del generator
        return 1

    stream = tokenizer.create_stream()
    produced = 0
    while not generator.is_done() and produced < 20:
        generator.generate_next_token()
        produced += 1
        print(stream.decode(generator.get_next_tokens()[0]), end="", flush=True)

    del generator
    print(f"\n\n[PASS] generated {produced} tokens")
    return 0


if __name__ == "__main__":
    sys.exit(main())
