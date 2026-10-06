"""Benchmark Foundry Local through its in-process Python SDK.

Scripts/Invoke-FoundryBench.ps1 measures the other route: the CLI plus the
OpenAI-compatible HTTP endpoint. That number carries request overhead the SDK
does not pay, because the SDK loads the Foundry Local Core API into this
process and calls it directly. Run both against the same model to see what the
HTTP hop costs.

Targets the **Session API** introduced in SDK 2.0.1, which replaced the
in-process OpenAI-style clients. The shape is Model -> Session -> Request ->
Response, and it is the same across C#, Python, JavaScript and Rust.

    python src/setup/bench_foundry_sdk.py --model qwen2.5-0.5b

Results are appended to the benchmark history, stamped with the stack.
"""

from __future__ import annotations

import argparse
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import atlas_history  # noqa: E402

MIN_SDK = (2, 0, 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", default="qwen2.5-0.5b", help="Foundry model alias.")
    parser.add_argument("--max-tokens", type=int, default=400)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument(
        "--prompt",
        default="Plan a detailed day in Lisbon, with specific neighbourhoods, food and timings.",
    )
    parser.add_argument("--no-record", action="store_true")
    args = parser.parse_args()

    try:
        import foundry_local_sdk as fl
        from foundry_local_sdk import (
            ChatSession,
            Configuration,
            FoundryLocalManager,
            MessageItem,
            Request,
        )
    except ImportError:
        print("[SETUP] pip install 'foundry-local-sdk>=2.1.0'")
        print("        NOT foundry-local-sdk-winml -- that variant was retired in 2.0.1")
        return 2

    version = getattr(fl, "__version__", "0")
    print(f"sdk      : {version}")
    if tuple(int(p) for p in version.split(".")[:3] if p.isdigit()) < MIN_SDK:
        print(f"[SETUP] needs >= {'.'.join(map(str, MIN_SDK))}; the Session API landed there.")
        return 2

    FoundryLocalManager.initialize(Configuration(app_name="atlas_bench"))
    manager = FoundryLocalManager.instance

    # Execution providers are acquired through Windows ML on first use; a no-op
    # once registered. 2.x picks the provider itself, so there is no NPU/GPU
    # switch here -- the model variant decides.
    manager.download_and_register_eps()

    model = manager.catalog.get_model(args.model)
    print(f"model    : {model.id}")

    load_start = time.perf_counter()
    if not model.is_cached:
        model.download()
    model.load()
    load_s = time.perf_counter() - load_start
    print(f"load     : {load_s:.1f}s")

    session = ChatSession(model)
    session.set_streaming(True)

    rates: list[float] = []
    first_tokens: list[float] = []
    counts: list[int] = []

    for run in range(1, args.repeat + 1):
        request = Request()
        request.add_item(MessageItem.user(args.prompt))

        produced = 0
        first_at: float | None = None
        start = time.perf_counter()

        streaming = session.process_streaming_request(request)
        for item in streaming:
            text = getattr(item, "get_simple_text", lambda: None)() or str(item)
            if not text:
                continue
            if first_at is None:
                first_at = time.perf_counter() - start
            produced += 1
            if produced >= args.max_tokens:
                break

        total = time.perf_counter() - start

        # The usage block is authoritative where the stream chunk count is not.
        generated = produced
        try:
            usage = streaming.final_response().get_usage()
            generated = getattr(usage, "completion_tokens", None) or produced
        except Exception:  # noqa: BLE001
            pass

        if produced == 0:
            print(f"  run {run}: produced nothing")
            continue

        decode_s = total - (first_at or 0.0)
        rate = generated / decode_s if decode_s > 0 else 0.0
        rates.append(rate)
        first_tokens.append(first_at or 0.0)
        counts.append(generated)
        print(
            f"  run {run}: {rate:6.1f} tok/s  {generated} tok in {total:5.1f}s  "
            f"first {first_at or 0.0:.2f}s"
        )

    # The session holds a reference to the model; unloading before it is
    # released fails with "1 session(s) still using it".
    del session
    import gc

    gc.collect()
    try:
        model.unload()
    except Exception:  # noqa: BLE001
        pass

    if not rates:
        print("\nno run produced output")
        return 1

    mean_rate = statistics.mean(rates)
    mean_first = statistics.mean(first_tokens)
    print(f"\nmean     : {mean_rate:.1f} tok/s, first token {mean_first:.2f}s")

    if not args.no_record:
        stack = atlas_history.record(
            source="bench_foundry_sdk.py",
            model=args.model,
            compute="foundry-sdk/auto",
            tok_per_sec=round(mean_rate, 1),
            first_token_s=round(mean_first, 3),
            tokens=int(statistics.mean(counts)),
            extra={
                "runs": len(rates),
                "harness": "foundry local in-process sdk (Session API)",
                "sdkVersion": version,
                "loadSeconds": round(load_s, 1),
            },
        )
        if stack:
            print(f"[history] recorded under stack {stack}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
