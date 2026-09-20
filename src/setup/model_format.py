"""Classify a local model directory before trying to load it.

The Snapdragon stack ships several bundle layouts whose names collide badly.
The worst pair differs by a single letter:

    genai_config.json   Microsoft ONNX Runtime GenAI   -> onnxruntime-genai
    genie_config.json   Qualcomm Genie                 -> geniex / QAIRT

Pointing `onnxruntime_genai.Model()` at a Genie bundle produces an opaque
parse error. This module answers "what is this directory?" up front so the
failure is explained instead of discovered.
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass, field
from pathlib import Path

ORT_GENAI = "onnxruntime-genai"
QUALCOMM_GENIE = "qualcomm-genie"
GENIEX_BUNDLE = "geniex-bundle"
RAW_ONNX = "raw-onnx"
GGUF = "gguf"
UNKNOWN = "unknown"
MISSING = "missing"


@dataclass
class ModelFormat:
    """What a model directory turned out to be."""

    kind: str
    path: Path
    loadable_by_ort_genai: bool
    summary: str
    remedy: str = ""
    evidence: list[str] = field(default_factory=list)

    def report(self) -> str:
        lines = [
            f"Path:   {self.path}",
            f"Format: {self.kind}",
            f"Status: {self.summary}",
        ]
        if self.evidence:
            lines.append("Found:  " + ", ".join(sorted(self.evidence)[:8]))
        if self.remedy:
            lines.append(f"Fix:    {self.remedy}")
        return "\n".join(lines)


def _matches(names: list[str], pattern: str) -> list[str]:
    return fnmatch.filter(names, pattern)


def classify(model_dir: str | Path) -> ModelFormat:
    """Identify the bundle layout in `model_dir` without loading it."""
    path = Path(model_dir)

    if not path.is_dir():
        return ModelFormat(
            kind=MISSING,
            path=path,
            loadable_by_ort_genai=False,
            summary="Directory does not exist.",
            remedy="Download a model first, e.g. 'geniex pull ai-hub-models/Qwen3-4B'.",
        )

    names = [p.name for p in path.iterdir()]
    onnx_files = _matches(names, "*.onnx")
    gguf_files = _matches(names, "*.gguf")
    split_bins = _matches(names, "part*_of_*.bin")
    nested_onnx = list(path.glob("*/*.onnx"))

    # ONNX Runtime GenAI: the only layout onnxruntime-genai can open.
    if "genai_config.json" in names:
        return ModelFormat(
            kind=ORT_GENAI,
            path=path,
            loadable_by_ort_genai=True,
            summary="ONNX Runtime GenAI model. Ready to load.",
            evidence=["genai_config.json", *onnx_files[:3]],
        )

    # Qualcomm Genie / GenieX bundle. Note the single-letter difference above.
    if "genie_config.json" in names or "geniex.json" in names:
        kind = GENIEX_BUNDLE if "geniex.json" in names else QUALCOMM_GENIE
        evidence = [n for n in ("genie_config.json", "geniex.json") if n in names]
        evidence += split_bins[:4]
        return ModelFormat(
            kind=kind,
            path=path,
            loadable_by_ort_genai=False,
            summary=(
                "Qualcomm Genie/QAIRT bundle. onnxruntime-genai CANNOT load this: "
                "it needs 'genai_config.json' plus an ONNX graph, and this bundle "
                "has 'genie_config.json' with QNN context binaries."
            ),
            remedy=(
                "Run it with GenieX instead: 'geniex infer <model>'. "
                "For onnxruntime-genai, obtain a model that ships genai_config.json "
                "(for example a Microsoft *-onnx repo on Hugging Face)."
            ),
            evidence=evidence,
        )

    if gguf_files:
        return ModelFormat(
            kind=GGUF,
            path=path,
            loadable_by_ort_genai=False,
            summary="GGUF weights. onnxruntime-genai does not read GGUF.",
            remedy="Use GenieX (llama.cpp engine): 'geniex infer <model>'.",
            evidence=gguf_files[:4],
        )

    if onnx_files or nested_onnx:
        found = onnx_files or [f"{p.parent.name}/{p.name}" for p in nested_onnx]
        return ModelFormat(
            kind=RAW_ONNX,
            path=path,
            loadable_by_ort_genai=False,
            summary=(
                "ONNX graph present but 'genai_config.json' is missing, so "
                "onnxruntime-genai cannot drive a generation loop over it."
            ),
            remedy=(
                "Use plain onnxruntime with the QNN execution provider, or obtain "
                "the ORT GenAI packaging of this model."
            ),
            evidence=found[:4],
        )

    if split_bins:
        return ModelFormat(
            kind=QUALCOMM_GENIE,
            path=path,
            loadable_by_ort_genai=False,
            summary="Split QNN context binaries with no recognizable config file.",
            remedy="Load through GenieX/QAIRT, not onnxruntime-genai.",
            evidence=split_bins[:4],
        )

    return ModelFormat(
        kind=UNKNOWN,
        path=path,
        loadable_by_ort_genai=False,
        summary="No recognizable model layout in this directory.",
        remedy="Check the path. 'geniex list' shows cached GenieX models.",
        evidence=names[:8],
    )


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print("usage: python -m setup.model_format <model-dir>")
        raise SystemExit(2)
    result = classify(sys.argv[1])
    print(result.report())
    raise SystemExit(0 if result.loadable_by_ort_genai else 1)
