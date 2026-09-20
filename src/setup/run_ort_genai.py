"""Run a generation loop through ONNX Runtime GenAI with the QNN provider.

Replaces run_phi4_qnn.py, which was hardcoded to an empty directory and used
an API that no longer exists in onnxruntime-genai 0.16:

    params.set_input_ids(...)       -> generator.append_tokens(...)
    params.set_search_property(...) -> params.set_search_options(...)
    generator.compute_logits()      -> removed; generate_next_token() suffices

This version takes the model directory as an argument and refuses to start
until the directory is a layout onnxruntime-genai can actually open, so a
format mismatch is reported plainly instead of as a parse error.

    python src/setup/run_ort_genai.py --model-dir models/Phi-3-mini-4k-instruct-onnx
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
            "\n[DIAG] The QNN execution provider refused the pre-compiled context\n"
            "       binary. These are ahead-of-time compiled for one Hexagon\n"
            "       architecture and do not run on another:\n"
            "         soc_model 60 = Snapdragon X Elite  (HTP v73)\n"
            "         soc_model 88 = Snapdragon X2 Elite (HTP v81)\n"
            "       Overriding soc_model does not help -- the binary itself is\n"
            "       built for the other target. Either obtain assets compiled for\n"
            "       your chipset, recompile from the source ONNX with QAIRT, or\n"
            "       run the model through GenieX with a GGUF build instead."
        )
        return

    if "GroupQueryAttention" in msg or "present_keys" in msg:
        print(
            "\n[DIAG] A KV-cache shape mismatch on a CPU-executed attention node.\n"
            "       This is usually a SYMPTOM, not the cause: QNN declined the\n"
            "       graph, ORT fell back to CPU, and the EPContext wrapper holds\n"
            "       no real weights for the CPU to run. Re-run with ORT verbose\n"
            "       logging to see the provider rejection underneath.\n"
            "       Note also that 'past_present_share_buffer' models size their\n"
            "       KV cache from genai_config.json -- overriding max_length can\n"
            "       produce a similar mismatch on its own."
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

    try:
        import onnxruntime_qnn as qnn_ep

        og.register_execution_provider_library(
            "QNNExecutionProvider", qnn_ep.get_library_path()
        )
        print("[ OK ] QNN execution provider registered.")
    except Exception as exc:  # noqa: BLE001
        print(f"[WARN] QNN unavailable ({type(exc).__name__}: {exc}); using CPU.")

    print(f"[INFO] Loading {fmt.path}")
    load_start = time.perf_counter()
    try:
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
    print("\n[INFO] Throughput alone does not prove NPU execution. See README section 6.")

    del generator
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
