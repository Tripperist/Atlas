"""Verify the ONNX Runtime + QNN execution provider stack on Snapdragon.

Replaces the earlier test_qnn.py, which tried to prove QNN worked by loading a
model. That conflated two independent questions. This script answers only the
first one, needs no model, and is safe to run any time:

    Is the QNN execution provider present and registrable?

Use --model-dir to additionally classify a bundle without loading it.

    python src/setup/check_qnn.py
    python src/setup/check_qnn.py --model-dir "$env:USERPROFILE\\.cache\\geniex\\models\\qualcomm\\Qwen3-4B"

Exit code 0 if QNN registered, 1 otherwise.
"""

from __future__ import annotations

import argparse
import platform
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from model_format import classify  # noqa: E402

OK = "[ OK ]"
FAIL = "[FAIL]"
WARN = "[WARN]"
INFO = "[INFO]"


def section(title: str) -> None:
    print(f"\n{title}\n{'-' * len(title)}")


def check_interpreter() -> bool:
    section("Interpreter")
    machine = platform.machine()
    bits = struct.calcsize("P") * 8
    native = machine.upper() in {"ARM64", "AARCH64"}
    print(f"{INFO} {sys.version.split()[0]} at {sys.executable}")
    print(f"{OK if native else WARN} architecture {machine}, {bits}-bit")
    if not native:
        print(
            f"{WARN} Not an ARM64 interpreter. QNN requires native ARM64; "
            "an emulated x64 Python cannot reach the Hexagon NPU."
        )
    return native


def check_runtime() -> bool:
    section("ONNX Runtime + QNN")
    try:
        import onnxruntime as ort
    except ImportError as exc:
        print(f"{FAIL} onnxruntime not importable: {exc}")
        return False

    print(f"{INFO} onnxruntime {ort.__version__}")
    before = ort.get_available_providers()
    print(f"{INFO} providers before registration: {before}")

    if "QNNExecutionProvider" in before:
        print(f"{OK} QNNExecutionProvider already available")
        return True

    try:
        import onnxruntime_qnn as qnn_ep
    except ImportError as exc:
        print(f"{FAIL} onnxruntime-qnn not installed: {exc}")
        print(f"{INFO} install it with: uv add onnxruntime-qnn")
        return False

    lib = qnn_ep.get_library_path()
    print(f"{INFO} provider library: {lib}")
    if not Path(lib).exists():
        print(f"{FAIL} provider DLL missing at that path")
        return False

    # QNN ships as a plugin in onnxruntime-qnn; it is absent from the provider
    # list until registered explicitly. This is expected, not an error.
    try:
        ort.register_execution_provider_library("QNNExecutionProvider", lib)
    except Exception as exc:  # noqa: BLE001 - surface whatever the runtime raises
        print(f"{FAIL} registration failed: {type(exc).__name__}: {exc}")
        return False

    after = ort.get_available_providers()
    print(f"{INFO} providers after registration:  {after}")
    if "QNNExecutionProvider" in after:
        print(f"{OK} QNNExecutionProvider registered")
        return True

    print(f"{FAIL} registration reported success but provider is still absent")
    return False


def check_genai() -> bool:
    section("ONNX Runtime GenAI")
    try:
        import onnxruntime_genai as og
    except ImportError as exc:
        print(f"{WARN} onnxruntime-genai not importable: {exc}")
        return False

    version = getattr(og, "__version__", "unknown")
    print(f"{INFO} onnxruntime-genai {version}")

    if hasattr(og, "is_qnn_available"):
        available = og.is_qnn_available()
        print(f"{OK if available else WARN} og.is_qnn_available() -> {available}")
    else:
        print(f"{WARN} og.is_qnn_available() not present in this build")

    try:
        import onnxruntime_qnn as qnn_ep

        og.register_execution_provider_library(
            "QNNExecutionProvider", qnn_ep.get_library_path()
        )
        print(f"{OK} QNN provider library bound to the GenAI engine")
    except Exception as exc:  # noqa: BLE001
        print(f"{WARN} could not bind QNN to GenAI: {type(exc).__name__}: {exc}")
        return False
    return True


def prove_npu(onnx_path: str | None) -> bool:
    """Show whether QNN actually claims graph nodes, or silently yields to CPU.

    A successful InferenceSession proves nothing on its own: ORT will happily
    fall back to CPU while reporting success. Two things expose the truth --
    session.get_providers() after creation, and the session config entry
    'session.disable_cpu_ep_fallback', which turns a silent fallback into a
    hard error.
    """
    section("NPU execution proof")
    import numpy as np
    import onnxruntime as ort

    path = onnx_path or _build_probe_graph()
    if not Path(path).exists():
        print(f"{FAIL} model not found: {path}")
        return False

    print(f"{INFO} probing with {path}")
    claimed = False
    for label, disable in (("fallback allowed", "0"), ("fallback disabled", "1")):
        opts = ort.SessionOptions()
        opts.add_session_config_entry("session.disable_cpu_ep_fallback", disable)
        # CRITICAL: do NOT pass providers=["QNNExecutionProvider"]. QNN is a
        # plugin EP registered via register_execution_provider_library, and the
        # legacy providers list SILENTLY IGNORES it -- the session runs entirely
        # on CPU while appearing to honour the request. The policy API attaches
        # it properly.
        opts.set_provider_selection_policy(
            ort.OrtExecutionProviderDevicePolicy.PREFER_NPU
        )
        try:
            session = ort.InferenceSession(path, sess_options=opts)
            providers = session.get_providers()
            on_npu = "QNNExecutionProvider" in providers
            claimed = claimed or (on_npu and disable == "1")
            print(f"{OK if on_npu else WARN} {label}: loaded, providers={providers}")
            if not on_npu:
                print(f"{WARN}   -> QNN took no nodes; this ran on CPU.")
            if onnx_path is None:
                inputs = {
                    i.name: np.random.randint(0, 255, i.shape).astype(np.uint8)
                    for i in session.get_inputs()
                }
                session.run(None, inputs)
        except Exception as exc:  # noqa: BLE001
            msg = str(exc).splitlines()[0][:160]
            print(f"{WARN} {label}: {type(exc).__name__}: {msg}")

    print()
    if claimed:
        print(f"{OK} QNN claimed graph nodes with CPU fallback disabled.")
    else:
        print(
            f"{WARN} QNN did not claim this graph. That is expected for a trivial "
            "probe: HTP accelerates specific quantized op/shape combinations, and "
            "an unsupported graph falls back to CPU."
        )
        print(
            f"{INFO} The technique is the point. Apply these two settings to YOUR "
            "model -- a session that 'works' on CPU looks identical to one that "
            "works on the NPU unless you check."
        )
    return claimed


def _build_probe_graph() -> str:
    """Emit a tiny quantized MatMul used only to exercise QNN partitioning."""
    import numpy as np
    import onnx
    from onnx import TensorProto, helper

    out = Path(__file__).resolve().parent / "_qnn_probe.onnx"
    weights = np.random.randint(0, 255, (256, 256)).astype(np.uint8)
    graph = helper.make_graph(
        [
            helper.make_node(
                "QLinearMatMul",
                ["A", "a_s", "a_z", "B", "b_s", "b_z", "y_s", "y_z"],
                ["Y"],
                name="probe_qmatmul",
            )
        ],
        "qnn_probe",
        [helper.make_tensor_value_info("A", TensorProto.UINT8, [1, 256])],
        [helper.make_tensor_value_info("Y", TensorProto.UINT8, [1, 256])],
        [
            helper.make_tensor("a_s", TensorProto.FLOAT, [], [0.02]),
            helper.make_tensor("a_z", TensorProto.UINT8, [], [128]),
            helper.make_tensor("B", TensorProto.UINT8, [256, 256], weights.tobytes(), raw=True),
            helper.make_tensor("b_s", TensorProto.FLOAT, [], [0.02]),
            helper.make_tensor("b_z", TensorProto.UINT8, [], [128]),
            helper.make_tensor("y_s", TensorProto.FLOAT, [], [0.05]),
            helper.make_tensor("y_z", TensorProto.UINT8, [], [128]),
        ],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 21)])
    model.ir_version = 10
    onnx.save(model, str(out))
    return str(out)


def check_model(model_dir: str) -> bool:
    section("Model format")
    result = classify(model_dir)
    print(result.report())
    marker = OK if result.loadable_by_ort_genai else WARN
    print(f"{marker} onnxruntime-genai can load this: {result.loadable_by_ort_genai}")
    return result.loadable_by_ort_genai


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--model-dir",
        help="Optionally classify a model directory without loading it.",
    )
    parser.add_argument(
        "--prove-npu",
        action="store_true",
        help="Test whether QNN claims graph nodes or silently falls back to CPU.",
    )
    parser.add_argument(
        "--onnx",
        help="Use this .onnx file for --prove-npu instead of a generated probe.",
    )
    args = parser.parse_args()

    print("Atlas QNN environment check")
    check_interpreter()
    qnn_ok = check_runtime()
    check_genai()
    if args.model_dir:
        check_model(args.model_dir)
    if args.prove_npu or args.onnx:
        prove_npu(args.onnx)

    section("Result")
    if qnn_ok:
        print(f"{OK} QNN execution provider is available.")
        print(
            f"{INFO} This proves the provider loads. It does NOT prove any model "
            "executes on the NPU -- see README section 6."
        )
    else:
        print(f"{FAIL} QNN execution provider is not available.")
    return 0 if qnn_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
