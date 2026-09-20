"""Run a generation loop through ONNX Runtime GenAI with the QNN provider.

Replaces run_phi4_qnn.py, which was hardcoded to an empty directory and used
an API that no longer exists in onnxruntime-genai 0.16:

    params.set_input_ids(...)       -> generator.append_tokens(...)
    params.set_search_property(...) -> params.set_search_options(...)
    generator.compute_logits()      -> removed; generate_next_token() suffices

This version takes the model directory as an argument and refuses to start
until the directory is a layout onnxruntime-genai can actually open, so a
format mismatch is reported plainly instead of as a parse error.

    python src/setup/run_ort_genai.py --model-dir models/Phi-4-mini-reasoning-onnx/npu/qnn-int4
    python src/setup/run_ort_genai.py --model-dir <dir> --prompt "Explain Rayleigh scattering."
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from model_format import classify  # noqa: E402


def _explain(exc: Exception) -> None:
    """Turn the two known low-level failures into an actionable diagnosis."""
    msg = str(exc)

    if "EPContext node" in msg and "not compatible" in msg:
        print(
            "\n[DIAG] No execution provider in the session can run the EPContext\n"
            "       nodes. Read the message literally -- 'not compatible with any\n"
            "       execution provider ADDED TO THE SESSION'. Almost always this\n"
            "       means QNN was never attached, not that the binary is wrong for\n"
            "       your chipset:\n"
            "         - GenAI: Config.clear_providers() + append_provider(...)\n"
            "         - plain ORT: set_provider_selection_policy(PREFER_NPU),\n"
            "           NOT providers=['QNNExecutionProvider'], which is silently\n"
            "           ignored for this plugin EP\n"
            "       A genuine chipset mismatch is rarer than it looks: bundles\n"
            "       declaring soc_model 60 (X Elite) do load on X2 Elite."
        )
        return

    if "GroupQueryAttention" in msg or "present_keys" in msg:
        print(
            "\n[DIAG] KV-cache shape mismatch in a CPU-executed attention node.\n"
            "       On this stack that is onnxruntime-genai 0.16.x: it regresses\n"
            "       EPContext/QNN pipeline models. Measured working on 0.13.2,\n"
            "       0.14.1 and 0.15.2, so pin one of those:\n"
            "         uv add 'onnxruntime-genai>=0.13.2,<0.16'\n"
            "       Two other causes to rule out: QNN not actually attached to\n"
            "       the config (register_execution_provider_library alone is not\n"
            "       enough), and overriding max_length on a model that sets\n"
            "       past_present_share_buffer."
        )
        return


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--model-dir",
        required=True,
        help="Directory containing genai_config.json and the ONNX graph.",
    )
    parser.add_argument(
        "--prompt",
        default="Write a fast sorting algorithm in Python.",
        help="Prompt text.",
    )
    parser.add_argument(
        "--max-length",
        type=int,
        default=None,
        help="Override max_length. Omit to use genai_config.json (safer for "
             "models with past_present_share_buffer).",
    )
    parser.add_argument("--temperature", type=float, default=None)
    parser.add_argument(
        "--no-chat-template",
        action="store_true",
        help="Encode the prompt verbatim instead of applying the chat template.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()

    # Pre-flight: fail with an explanation, not an opaque parse error.
    fmt = classify(args.model_dir)
    if not fmt.loadable_by_ort_genai:
        print("Cannot run this model with onnxruntime-genai.\n")
        print(fmt.report())
        return 1

    import onnxruntime_genai as og

    version = getattr(og, "__version__", "?")
    print(f"[INFO] onnxruntime-genai {version}")
    if version.startswith("0.16"):
        print(
            "[WARN] 0.16.x regresses EPContext/QNN models: the prompt pass fails\n"
            "       with a GroupQueryAttention KV-cache shape mismatch. Verified\n"
            "       working on 0.13.2, 0.14.1 and 0.15.2."
        )

    qnn_ready = False
    try:
        import onnxruntime_qnn as qnn_ep

        og.register_execution_provider_library(
            "QNNExecutionProvider", qnn_ep.get_library_path()
        )
        qnn_ready = True
        print("[ OK ] QNN execution provider registered.")
    except Exception as exc:  # noqa: BLE001
        print(f"[WARN] QNN unavailable ({type(exc).__name__}: {exc}); using CPU.")

    print(f"[INFO] Loading {fmt.path}")
    load_start = time.perf_counter()
    try:
        # Registering the library is not enough: the provider must also be
        # attached to the config, otherwise GenAI builds a CPU-only session and
        # EPContext nodes have no EP to run on.
        if qnn_ready and hasattr(og, "Config"):
            config = og.Config(str(fmt.path))
            config.clear_providers()
            config.append_provider("QNNExecutionProvider")
            model = og.Model(config)
        else:
            model = og.Model(str(fmt.path))
        tokenizer = og.Tokenizer(model)
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] {type(exc).__name__}: {str(exc)[:300]}")
        _explain(exc)
        return 1
    print(f"[ OK ] Model loaded in {time.perf_counter() - load_start:.1f}s")

    if args.no_chat_template:
        text = args.prompt
    else:
        try:
            text = tokenizer.apply_chat_template(
                messages=f'[{{"role":"user","content":"{args.prompt}"}}]',
                add_generation_prompt=True,
            )
        except Exception:  # noqa: BLE001 - not every model ships a template
            text = args.prompt

    params = og.GeneratorParams(model)
    # Only override search options when asked. Models with
    # "past_present_share_buffer" size their KV cache from genai_config.json,
    # and forcing a different max_length can break that allocation.
    opts = {}
    if args.max_length:
        opts["max_length"] = args.max_length
    if args.temperature is not None:
        opts["temperature"] = args.temperature
    if opts:
        params.set_search_options(**opts)

    try:
        generator = og.Generator(model, params)
        generator.append_tokens(tokenizer.encode(text))
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] {type(exc).__name__}: {str(exc)[:300]}")
        _explain(exc)
        return 1

    stream = tokenizer.create_stream()
    print(f"\n--- Prompt ---\n{args.prompt}\n\n--- Response ---")

    first_token_at: float | None = None
    tokens = 0
    start = time.perf_counter()
    try:
        while not generator.is_done():
            generator.generate_next_token()
            if first_token_at is None:
                first_token_at = time.perf_counter()
            tokens += 1
            print(stream.decode(generator.get_next_tokens()[0]), end="", flush=True)
    except KeyboardInterrupt:
        print("\n[INFO] Cancelled.")

    elapsed = time.perf_counter() - start
    print("\n\n--- Stats ---")
    if first_token_at is not None:
        print(f"Time to first token: {first_token_at - start:.2f}s")
    print(f"Tokens generated:    {tokens}")
    if elapsed > 0:
        print(f"Throughput:          {tokens / elapsed:.1f} tok/s")
    print("\n[INFO] Throughput alone does not prove NPU execution. See README section 7.")

    del generator
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
