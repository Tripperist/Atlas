"""Compile and profile a model on a cloud-hosted Qualcomm device.

Automates README section 8.4. Submits a compile job followed by a profile
job, then prints the compute-unit split that the profile reports -- which is
the one thing local performance counters cannot tell you. Local counters show
that *an* accelerator is busy; a profile job reports, per layer, which unit
actually executed it.

Jobs run in Qualcomm's cloud, so the model is uploaded. Only submit artifacts
you are authorized to transfer.

    python src/setup/hub_profile.py --model models/squeezenet1_1-onnx-w8a8/squeezenet1_1.onnx \
        --input-name image_tensor --input-shape 1,3,224,224

Requires an API token:  qai-hub configure --api_token <token>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", required=True, help="Path to the source model.")
    parser.add_argument("--device", default="Snapdragon X2 Elite CRD")
    parser.add_argument("--input-name", default="image_tensor")
    parser.add_argument("--input-shape", default="1,3,224,224")
    parser.add_argument("--input-dtype", default="uint8")
    parser.add_argument(
        "--target-runtime",
        default="onnx",
        help="onnx, qnn_context_binary, tflite, qnn_dlc, precompiled_qnn_onnx",
    )
    parser.add_argument(
        "--compile-only", action="store_true", help="Skip the profile job."
    )
    args = parser.parse_args()

    try:
        import qai_hub as hub
    except ImportError:
        print("[FAIL] qai-hub not installed. Run: uv add qai-hub")
        return 1

    model_path = Path(args.model)
    if not model_path.exists():
        print(f"[FAIL] model not found: {model_path}")
        return 1

    shape = tuple(int(x) for x in args.input_shape.split(","))
    input_specs = {args.input_name: (shape, args.input_dtype)}

    # An ONNX split across a .data sidecar uploads as the .onnx alone, and the
    # job fails server-side with "should be stored in ... but it is not regular
    # file". Materialize a self-contained copy first.
    upload_path = _inline_external_data(model_path)

    print(f"[INFO] device        : {args.device}")
    print(f"[INFO] model         : {upload_path}")
    print(f"[INFO] target runtime: {args.target_runtime}")
    print(f"[INFO] input specs   : {input_specs}")
    print("[INFO] uploading to Qualcomm's cloud ...")

    device = hub.Device(args.device)

    try:
        compile_job = hub.submit_compile_job(
            model=str(upload_path),
            device=device,
            input_specs=input_specs,
            options=f"--target_runtime {args.target_runtime}",
        )
        print(f"[ OK ] compile job : {compile_job.url}")
        target = compile_job.get_target_model()
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] compile: {type(exc).__name__}: {str(exc)[:300]}")
        return 1

    if not _ok(compile_job, "compile") or target is None:
        return 1

    if args.compile_only:
        return 0

    try:
        profile_job = hub.submit_profile_job(model=target, device=device)
        print(f"[ OK ] profile job : {profile_job.url}")
        profile = profile_job.download_profile()
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] profile: {type(exc).__name__}: {str(exc)[:300]}")
        return 1

    if not _ok(profile_job, "profile"):
        return 1

    _summarize(profile)
    return 0


def _ok(job, label: str, timeout_s: int = 1800) -> bool:
    """Block until the job reaches a terminal state, then report.

    get_target_model() returns a future placeholder rather than blocking, and a
    freshly submitted job sits in CREATED with success=False and failure=False.
    Checking immediately therefore looks like a failure when the job is merely
    queued -- devices take a minute or so to provision.
    """
    import time

    started = time.time()
    while time.time() - started < timeout_s:
        status = job.get_status()
        if getattr(status, "success", False) or getattr(status, "failure", False):
            break
        time.sleep(15)

    status = job.get_status()
    waited = time.time() - started
    if getattr(status, "success", False):
        print(f"[ OK ] {label} job succeeded after {waited:.0f}s")
        return True

    message = (getattr(status, "message", "") or "").strip()
    state = getattr(status, "state", status)
    print(f"[FAIL] {label} job did not succeed after {waited:.0f}s: {state}")
    if message:
        print(f"       {message[:500]}")
    print(f"       {job.url}")
    return False


def _inline_external_data(model_path: Path) -> Path:
    """Return a path whose ONNX carries its weights internally.

    ONNX stores tensors over ~2 GB -- and sometimes smaller ones -- in a
    sidecar file. Uploading only the .onnx leaves the server unable to resolve
    them.
    """
    if model_path.suffix != ".onnx":
        return model_path
    sidecars = [p for p in model_path.parent.glob("*.data") if p.is_file()]
    if not sidecars:
        return model_path

    try:
        import onnx
    except ImportError:
        print("[WARN] onnx not installed; uploading as-is may fail")
        return model_path

    out = model_path.with_name(model_path.stem + "_selfcontained.onnx")
    if out.exists():
        return out
    print(f"[INFO] inlining external data ({', '.join(p.name for p in sidecars)})")
    model = onnx.load(str(model_path))  # loads sidecar data by default
    onnx.save(model, str(out), save_as_external_data=False)
    print(f"[ OK ] wrote {out.name} ({out.stat().st_size / 1e6:.1f} MB)")
    return out


def _summarize(profile: dict) -> None:
    """Print the compute-unit split and headline timings from a profile."""
    import collections

    print("\n--- Profile summary ---")
    segments = profile.get("execution_detail") or []
    units = collections.Counter(
        seg.get("compute_unit", "?") for seg in segments
    )
    total = sum(units.values())
    if total:
        print(f"Layers: {total}")
        for unit, count in units.most_common():
            print(f"  {unit:<6} {count:>5}  ({count / total:.0%})")
    else:
        print("No per-layer detail returned.")

    summary = profile.get("execution_summary") or {}
    interesting = [
        ("estimated_inference_time", "Inference time", "us"),
        ("estimated_inference_peak_memory", "Peak memory", "bytes"),
        ("first_load_time", "First load", "us"),
        ("warm_load_time", "Warm load", "us"),
        ("compile_time", "Compile time", "us"),
    ]
    for key, label, unit in interesting:
        if key in summary:
            value = summary[key]
            if unit == "us" and isinstance(value, (int, float)):
                print(f"{label:<16} {value / 1000:.2f} ms")
            elif unit == "bytes" and isinstance(value, (int, float)):
                print(f"{label:<16} {value / 1e6:.1f} MB")
            else:
                print(f"{label:<16} {value}")

    print(
        "\nNPU here means the layer executed on the Hexagon NPU. A layer listed "
        "as CPU\nfell back, which local utilization counters cannot reveal."
    )


if __name__ == "__main__":
    sys.exit(main())
