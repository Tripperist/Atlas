"""Pull published AI Hub performance for a curated model set on one device.

Qualcomm publishes measured numbers per model per device, so most questions
about "how fast is X on my chip" need no benchmarking and no job submission.
This collects them for the models relevant to a Scout-style travel assistant
and writes JSON that README section 6 is built from. Use --markdown to render it.

    python src/setup/model_catalog.py --device "Snapdragon X2 Elite CRD"
    python src/setup/model_catalog.py --only llm --out catalog.json

Read-only: shells out to `qai-hub-models perf`, which reads the public
catalogue. No upload, no job submission, no API token required.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# Curated rather than exhaustive: the full catalogue is 231 models, most of
# them image classifiers with no bearing on a travel assistant.
CURATED: dict[str, list[tuple[str, str]]] = {
    "llm": [
        ("Qwen3-0.6B", "Smallest Qwen3; fast drafts, speculative decoding"),
        ("Qwen3-1.7B", "Small general chat; low latency"),
        ("Qwen3-4B", "Balanced general chat; reasoning-capable"),
        ("Qwen3-4B-Instruct-2507", "Newer 4B instruct tune"),
        ("Qwen3-8B", "Largest Qwen3 here; best quality, slowest"),
        ("Phi-3.5-Mini-Instruct", "Strong instruction following at 3.8B"),
        ("Phi-4-Mini-Instruct", "Newer Phi; strong reasoning for size"),
        ("Llama-v3.2-1B-Instruct", "Tiny Llama; edge latency"),
        ("Llama-v3.2-3B-Instruct", "Mid Llama; general assistant"),
        ("Llama-v3.2-3B-Instruct-SSD", "3B tuned for speculative decoding"),
        ("Llama-v3.1-8B-Instruct", "8B general assistant"),
        ("Llama-v3-8B-Instruct", "Previous-gen 8B"),
        ("Falcon3-7B-Instruct", "7B alternative architecture"),
        ("Llama-SEA-LION-v3.5-8B-R", "Southeast Asian languages"),
        ("Llama-v3-ELYZA-JP-8B", "Japanese-tuned"),
        ("Llama3-TAIDE-LX-8B-Chat-Alpha1", "Traditional Chinese-tuned"),
    ],
    "vlm": [
        ("Qwen3-VL-4B-Instruct", "Vision-language; photos of signs, menus, landmarks"),
        ("Qwen3-VL-8B-Instruct", "Larger VLM; better visual reasoning"),
        ("Qwen2.5-VL-7B-Instruct", "Previous-gen VLM"),
        ("Intern3.5-VL-2B", "Compact VLM; lowest-latency vision"),
        ("Gemma-4-E4B-it", "Google VLM"),
    ],
    "speech": [
        ("Whisper-Tiny", "Fastest ASR; voice input where accuracy can slip"),
        ("Whisper-Base", "Small ASR; better accuracy than Tiny"),
        ("Whisper-Small", "Mid ASR; good accuracy/speed balance"),
        ("Whisper-Large-V3-Turbo-Quantized", "Best ASR accuracy, quantized"),
        ("Distil-Whisper", "Distilled Whisper; faster at similar accuracy"),
    ],
    "tts": [
        ("MeloTTS-EN", "English speech synthesis for spoken replies"),
        ("PiperTTS-EN", "Lightweight English TTS"),
    ],
    "ocr": [
        ("EasyOCR", "Reads menus, signs, tickets from photos"),
        ("TrOCR", "Transformer OCR; handwriting and harder text"),
    ],
    "translate": [
        ("OpusMT-En-Es", "English to Spanish"),
        ("OpusMT-Es-En", "Spanish to English"),
        ("OpusMT-En-Zh", "English to Chinese"),
    ],
    "embed": [
        ("Nomic-Embed-Text", "Text embeddings for Scout's retrieval index"),
        ("MiniLM-v2", "Compact sentence embeddings"),
    ],
    "vision": [
        ("OpenAI-Clip", "Image/text similarity; landmark and scene matching"),
        ("SigLIP2", "Newer CLIP-style image/text model"),
    ],
}


def to_model_id(display_name: str) -> str:
    """AI Hub ids are the display name lowercased with separators as _."""
    return re.sub(r"[^a-z0-9]+", "_", display_name.lower()).strip("_")


def run_perf(model_id: str, device: str, timeout: int = 180) -> str:
    exe = Path(__file__).resolve().parents[2] / ".venv" / "Scripts" / "qai-hub-models.exe"
    cmd = [str(exe) if exe.exists() else "qai-hub-models", "perf", model_id, "-d", device]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.stdout + proc.stderr
    except subprocess.TimeoutExpired:
        return "__TIMEOUT__"


# Column layout varies by model family: LLMs carry Context Len / Tokens per
# Second / Prefill, vision models carry Inference Time / Peak Memory with
# Compute Unit LAST, and multi-part models (Whisper, EasyOCR) insert a
# Component column. Parsing by fixed position silently mis-assigns fields --
# it read a latency of 3.45 ms as the compute unit. Map by header instead.
HEADER_KEYS = {
    "precision": "precision",
    "runtime": "runtime",
    "device": "device",
    "component": "component",
    "context len": "context",
    "compute unit": "compute_unit",
    "tokens/sec": "tokens_per_sec",
    "tokens per second": "tokens_per_sec",
    "time to first token (ms)": "ttft_ms",
    "prefill tokens/sec": "prefill_tps",
    "prefill tokens per second": "prefill_tps",
    "inference (ms)": "inference_ms",
    "inference time (ms)": "inference_ms",
    "estimated inference time (ms)": "inference_ms",
    "peak memory (mb)": "peak_memory_mb",
    "estimated peak memory (mb)": "peak_memory_mb",
    "sdk versions": "sdk",
}


def _split_row(line: str) -> list[str] | None:
    if not line.startswith("|") or set(line.strip()) <= set("|+- "):
        return None
    return [c.strip() for c in line.strip().strip("|").split("|")]


def parse_perf(text: str) -> list[dict]:
    """Pull the data rows out of the ASCII table `perf` prints, by header."""
    header: list[str] | None = None
    rows: list[dict] = []

    for line in text.splitlines():
        cells = _split_row(line)
        if cells is None:
            continue
        lowered = [c.lower() for c in cells]
        if "precision" in lowered and "runtime" in lowered:
            header = [HEADER_KEYS.get(c, c.replace(" ", "_")) for c in lowered]
            continue
        if header is None or not any(cells):
            continue
        if len(cells) != len(header):
            continue
        row = {k: v for k, v in zip(header, cells) if k and v}
        if row.get("precision"):
            rows.append(row)
    return rows


def _num(value: str | None) -> float | None:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def best_npu(rows: list[dict], field: str) -> tuple[float | None, str]:
    """Best NPU value for `field`, plus the context length it came from."""
    best, ctx = None, ""
    for row in rows:
        if row.get("compute_unit", "").upper() != "NPU":
            continue
        value = _num(row.get(field))
        if value is not None and (best is None or value > best):
            best, ctx = value, row.get("context", "")
    return best, ctx


def _latency(row: dict) -> float | None:
    """Header text varies ('Inference (ms)' vs 'Inference Time (ms)')."""
    for key in ("inference_ms", "inference_(ms)", "inference_time_(ms)"):
        value = _num(row.get(key))
        if value is not None:
            return value
    return None


def fastest_npu_latency(rows: list[dict]) -> tuple[float | None, str, int]:
    """Lowest NPU inference time in ms, the runtime, and component count.

    Multi-part models (Whisper encoder+decoder, EasyOCR detector+recognizer)
    report a row per component, so the single fastest row understates the
    end-to-end cost. Return the component count so the caller can say so.
    """
    best, runtime = None, ""
    components = {row.get("component") for row in rows if row.get("component")}
    for row in rows:
        if row.get("compute_unit", "").upper() != "NPU":
            continue
        value = _latency(row)
        if value is not None and (best is None or value < best):
            best, runtime = value, row.get("runtime", "")
    return best, runtime, len(components)


def npu_total_latency(rows: list[dict]) -> float | None:
    """Sum the fastest NPU latency per component: the end-to-end figure."""
    per_component: dict[str, float] = {}
    for row in rows:
        if row.get("compute_unit", "").upper() != "NPU":
            continue
        value = _latency(row)
        if value is None:
            continue
        key = row.get("component", "_")
        if key not in per_component or value < per_component[key]:
            per_component[key] = value
    return sum(per_component.values()) if per_component else None


def emit_markdown(data: dict) -> str:
    """Render the collected data as the tables used in README section 6."""
    device = data["device"]
    models = data["models"]
    out: list[str] = []

    gen = [(n, v) for n, v in models.items() if v["category"] in ("llm", "vlm")]
    ranked = []
    for name, v in gen:
        tps, ctx = best_npu(v["rows"], "tokens_per_sec")
        pre, _ = best_npu(v["rows"], "prefill_tps")
        ranked.append((tps or -1, name, v, tps, ctx, pre))
    ranked.sort(reverse=True)

    out.append(f"| Model | Type | NPU tok/s | Ctx | Prefill tok/s | Best for |")
    out.append("| --- | --- | --- | --- | --- | --- |")
    for _, name, v, tps, ctx, pre in ranked:
        kind = "VLM" if v["category"] == "vlm" else "LLM"
        out.append(
            f"| `qualcomm/{name}` | {kind} | {tps if tps else 'n/a'} | {ctx or 'n/a'} "
            f"| {pre if pre else 'n/a'} | {v['summary']} |"
        )

    out.append("")
    out.append("| Model | Task | NPU latency | Parts | Runtime | Best for |")
    out.append("| --- | --- | --- | --- | --- | --- |")
    labels = {
        "speech": "Speech-to-text",
        "tts": "Text-to-speech",
        "ocr": "OCR",
        "translate": "Translation",
        "embed": "Embeddings",
        "vision": "Image/text",
    }
    ordered = sorted(
        (v for v in models.values() if v["category"] in labels),
        key=lambda v: (list(labels).index(v["category"]), npu_total_latency(v["rows"]) or 1e9),
    )
    for v in ordered:
        name = next(n for n, x in models.items() if x is v)
        total = npu_total_latency(v["rows"])
        _, runtime, parts = fastest_npu_latency(v["rows"])
        out.append(
            f"| `{name}` | {labels[v['category']]} | "
            f"{f'{total:.2f} ms' if total else 'n/a'} | {parts or 1} "
            f"| {runtime or 'n/a'} | {v['summary']} |"
        )

    out.append("")
    out.append(f"_Published by Qualcomm for {device}._")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", default="Snapdragon X2 Elite CRD")
    parser.add_argument("--only", nargs="*", help="Category keys to include.")
    parser.add_argument("--out", default="model_catalog.json")
    parser.add_argument(
        "--markdown",
        metavar="JSON",
        help="Skip collection; render tables from an existing JSON file.",
    )
    args = parser.parse_args()

    if args.markdown:
        print(emit_markdown(json.loads(Path(args.markdown).read_text())))
        return 0

    categories = args.only or list(CURATED)
    results: dict[str, dict] = {}
    total = sum(len(CURATED[c]) for c in categories if c in CURATED)
    done = 0

    for category in categories:
        for display, blurb in CURATED.get(category, []):
            done += 1
            model_id = to_model_id(display)
            print(f"[{done}/{total}] {display} ({model_id}) ...", flush=True)
            text = run_perf(model_id, args.device)
            if text == "__TIMEOUT__":
                status, rows = "timeout", []
            elif "not found" in text.lower() or "no such" in text.lower():
                status, rows = "not_found", []
            else:
                rows = parse_perf(text)
                status = "ok" if rows else "no_data_for_device"
            results[display] = {
                "model_id": model_id,
                "category": category,
                "summary": blurb,
                "status": status,
                "rows": rows,
            }
            print(f"          -> {status} ({len(rows)} rows)", flush=True)

    out = Path(args.out)
    out.write_text(json.dumps({"device": args.device, "models": results}, indent=2))
    print(f"\nwrote {out} ({len(results)} models)")

    ok = sum(1 for v in results.values() if v["status"] == "ok")
    print(f"with published data for {args.device}: {ok}/{len(results)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
