"""Benchmark ONNX Runtime GenAI on the same axes as `geniex-bench`.

README section 9.3 compares GenieX's QAIRT and llama.cpp plugins by prefill
throughput, decode throughput and time to first token. This puts the ORT GenAI
path on those same axes so the three runtimes are directly comparable.

Mirrors geniex-bench's method deliberately:
  * a fixed-length prompt of random token ids (default 512), so prompt
    processing is exactly N tokens for any tokenizer
  * a fixed number of generated tokens (default 128)
  * prefill and decode timed separately, not averaged into one tok/s figure

    python src/setup/bench_ort_genai.py --model-dir models/Phi-4-mini-reasoning-onnx/npu/qnn-int4

Requires onnxruntime-genai >=0.13.2 (0.16.x is broken for EPContext models;
see README section 5 Method D).
"""

from __future__ import annotations

import argparse
import random
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from model_format import classify  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--n-prompt", type=int, default=512, help="Prefill length.")
    parser.add_argument("--n-gen", type=int, default=128, help="Tokens to generate.")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--cpu-only",
        action="store_true",
        help="Skip QNN attachment, for a CPU baseline on the same model.",
    )
    args = parser.parse_args()

    fmt = classify(args.model_dir)
    if not fmt.loadable_by_ort_genai:
        print("Cannot benchmark this model with onnxruntime-genai.\n")
        print(fmt.report())
        return 1

    import onnxruntime_genai as og

    version = getattr(og, "__version__", "?")
    print(f"onnxruntime-genai : {version}")
    if version.startswith("0.16"):
        print("[WARN] 0.16.x regresses EPContext/QNN models; expect failure.")

    provider = "cpu"
    if not args.cpu_only:
        try:
            import onnxruntime_qnn as qnn_ep

            og.register_execution_provider_library(
                "QNNExecutionProvider", qnn_ep.get_library_path()
            )
            config = og.Config(str(fmt.path))
            config.clear_providers()
            config.append_provider("QNNExecutionProvider")
            provider = "QNNExecutionProvider"
        except Exception as exc:  # noqa: BLE001
            print(f"[WARN] QNN unavailable ({exc}); falling back to CPU.")
            config = og.Config(str(fmt.path))
    else:
        config = og.Config(str(fmt.path))

    print(f"provider          : {provider}")
    print(f"prompt / generate : {args.n_prompt} / {args.n_gen} tokens")

    load_start = time.perf_counter()
    model = og.Model(config)
    tokenizer = og.Tokenizer(model)
    load_s = time.perf_counter() - load_start
    print(f"model load        : {load_s:.1f}s\n")

    # Random token ids, as geniex-bench does, so prefill is exactly n_prompt
    # regardless of how the tokenizer would segment real text.
    rng = random.Random(args.seed)
    vocab_hint = 32000
    prompt_ids = [rng.randrange(1, vocab_hint) for _ in range(args.n_prompt)]

    prefills: list[float] = []
    decodes: list[float] = []

    for rep in range(1, args.repetitions + 1):
        params = og.GeneratorParams(model)
        generator = og.Generator(model, params)

        t0 = time.perf_counter()
        generator.append_tokens(prompt_ids)
        prefill_s = time.perf_counter() - t0

        produced = 0
        t1 = time.perf_counter()
        while not generator.is_done() and produced < args.n_gen:
            generator.generate_next_token()
            produced += 1
        decode_s = time.perf_counter() - t1
        del generator

        if produced == 0:
            print(f"  rep {rep}: produced no tokens")
            continue

        pp = args.n_prompt / prefill_s if prefill_s > 0 else 0.0
        tg = produced / decode_s if decode_s > 0 else 0.0
        prefills.append(pp)
        decodes.append(tg)
        print(
            f"  rep {rep}: ttft {prefill_s * 1000:7.1f} ms  "
            f"prefill {pp:8.1f} tok/s  decode {tg:6.1f} tok/s  ({produced} gen)"
        )

    if not prefills:
        print("\nno successful repetitions")
        return 1

    print(
        f"\n[result] ttft {args.n_prompt / statistics.mean(prefills) * 1000:.1f} ms  "
        f"prefill {statistics.mean(prefills):.1f} tok/s  "
        f"decode {statistics.mean(decodes):.1f} tok/s"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
