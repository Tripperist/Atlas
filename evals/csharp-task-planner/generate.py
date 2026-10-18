"""Ask each model to solve prompt.txt, several times, and save what it wrote.

    python generate.py --model 30b --samples 3
    python generate.py --model 7b  --samples 3
    python generate.py --model 7b  --samples 1 --out scratch/runs

Both models get the identical prompt and the same sampling settings. Each sample
is saved under <out>/<model>/s<seed>/ as raw.txt (the whole reply), Program.cs
(the extracted code) and meta.json (settings, token counts, timings). <out> is
runs/ next to this file unless --out says otherwise. The committed samples live in
runs/, and a sample of the same model and seed there is REPLACED, so generate into
another folder with --out to keep them.

The 30B runs through `geniex infer` on the GPU so that it cannot contend for the
NPU with the 7B, which runs on the NPU through Foundry Local's HTTP endpoint.
The compute unit does not change what the weights compute; it changes speed.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROMPT = (HERE / "prompt.txt").read_text(encoding="utf-8")
MARKER = "=== END OF TASK ==="
TEMPERATURE = 0.2
TOP_P = 0.95
MAX_TOKENS = 4096

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
SPINNER = re.compile("(?:[\U0001F30D-\U0001F30F][A-Za-z ]+\\.\\.\\.)+")
STATS_LINE = re.compile("—\\s*[\\d.]+ tok/s.*?first token\\s*—")
FENCE = re.compile(r"```([A-Za-z#+]*)[ \t]*\r?\n(.*?)```", re.DOTALL)
STATS = re.compile(r"([\d.]+) tok/s\s*[•·]\s*(\d+) tok\s*[•·]\s*([\d.]+) s first token")

MODELS = {
    "30b": {
        "label": "qwen3-coder-30b-a3b",
        "backend": "geniex infer, llama.cpp engine, GPU",
        "id": "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_0",
    },
    "7b": {
        "label": "qwen2.5-coder-7b",
        "backend": "Foundry Local HTTP, QNN NPU variant",
        "id": "qwen2.5-coder-7b",
    },
}


def extract(reply: str) -> tuple[str, dict]:
    """Pick the program out of a reply and say how well the reply followed the format."""
    blocks = [(m.group(1).lower(), m.group(2)) for m in FENCE.finditer(reply)]
    truncated = False
    if not blocks:
        # an unterminated fence means the reply was cut off mid-program
        m = re.search(r"```([A-Za-z#+]*)[ \t]*\r?\n(.*)\Z", reply, re.DOTALL)
        if m:
            blocks, truncated = [(m.group(1).lower(), m.group(2))], True
    csharp = [b for b in blocks if b[0] in ("csharp", "cs", "c#")]
    pool = csharp or blocks
    code = max(pool, key=lambda b: len(b[1]))[1] if pool else ""
    stripped = FENCE.sub("", reply).strip()
    info = {
        "codeBlocks": len(blocks),
        "followedFormat": len(blocks) == 1 and stripped == "" and not truncated,
        "truncated": truncated,
        "hadCode": bool(code.strip()),
    }
    return code.strip("\n") + "\n" if code else "", info


def run_geniex(model_id: str, seed: int) -> tuple[str, dict]:
    cmd = [
        "geniex", "infer", model_id, "-i", str(HERE / "prompt.txt"), "--compute", "gpu",
        "--nctx", "8192", "--max-tokens", str(MAX_TOKENS), "--temperature", str(TEMPERATURE),
        "--top-p", str(TOP_P), "--seed", str(seed), "--think=false",
    ]
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, timeout=1800)
    wall = time.time() - t0
    out = ANSI.sub("", p.stdout.decode("utf-8", "replace") + p.stderr.decode("utf-8", "replace"))
    # the CLI echoes the prompt; keep only what follows the last copy of its final line
    reply = out.rsplit(MARKER, 1)[1] if MARKER in out else out
    # the CLI draws a loading spinner and prints a stats line around the reply
    reply = STATS_LINE.sub("", SPINNER.sub("", reply)).strip()
    meta = {"wallSeconds": round(wall, 1), "exitCode": p.returncode}
    m = STATS.search(out)
    if m:
        meta.update(tokPerSec=float(m.group(1)), completionTokens=int(m.group(2)), firstTokenSeconds=float(m.group(3)))
    return reply, meta


def foundry_endpoint() -> str:
    # The CLI prints UTF-8 (box and bullet characters). Under the Windows code page, text=True makes the
    # reader fail and .stdout come back None, so say UTF-8 and replace what cannot be read.
    def cli(*args: str) -> str:
        return subprocess.run(["foundry", *args], capture_output=True, text=True, encoding="utf-8", errors="replace").stdout or ""

    out = cli("server", "start") + cli("status")
    m = re.search(r"http://127\.0\.0\.1:\d+", ANSI.sub("", out))
    if not m:
        raise SystemExit("could not find the Foundry endpoint")
    return m.group(0)


def run_foundry(alias: str, seed: int) -> tuple[str, dict]:
    endpoint = foundry_endpoint()
    subprocess.run(["foundry", "model", "load", alias], capture_output=True)
    catalog = json.load(urllib.request.urlopen(f"{endpoint}/v1/models", timeout=60))
    model = next((m["id"] for m in catalog["data"] if m.get("parent") == alias and "qnn-npu" in m["id"]), alias)

    def post(with_seed: bool):
        body = {"model": model, "messages": [{"role": "user", "content": PROMPT}],
                "max_tokens": MAX_TOKENS, "temperature": TEMPERATURE, "top_p": TOP_P}
        if with_seed:
            body["seed"] = seed
        req = urllib.request.Request(f"{endpoint}/v1/chat/completions", json.dumps(body).encode("utf-8"),
                                     {"Content-Type": "application/json"})
        return json.load(urllib.request.urlopen(req, timeout=1800))

    t0 = time.time()
    try:
        r = post(True)
    except urllib.error.HTTPError:
        r = post(False)
    wall = time.time() - t0
    meta = {"wallSeconds": round(wall, 1), "seedAccepted": True, "model": model}
    usage = r.get("usage", {})
    meta["completionTokens"] = usage.get("completion_tokens")
    meta["promptTokens"] = usage.get("prompt_tokens")
    if meta["completionTokens"]:
        meta["tokPerSec"] = round(meta["completionTokens"] / wall, 1)
    choice = r["choices"][0]
    meta["finishReason"] = choice.get("finish_reason")
    return choice["message"]["content"], meta


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=list(MODELS) + ["all"], default="all")
    ap.add_argument("--samples", type=int, default=3)
    ap.add_argument("--out", default=str(HERE / "runs"), metavar="DIR",
                    help="where to save the samples (default: runs/ next to this file, which holds the "
                         "committed samples and has them replaced). Relative paths are from the current directory.")
    a = ap.parse_args()
    out_root = Path(a.out).resolve()
    for key in (list(MODELS) if a.model == "all" else [a.model]):
        spec = MODELS[key]
        for seed in range(1, a.samples + 1):
            out_dir = out_root / spec["label"] / f"s{seed}"
            replacing = (out_dir / "Program.cs").exists()
            out_dir.mkdir(parents=True, exist_ok=True)
            print(f"{spec['label']} seed {seed} -> {out_dir}{'  (replacing the sample already there)' if replacing else ''} ...", flush=True)
            reply, meta = (run_geniex if key == "30b" else run_foundry)(spec["id"], seed)
            code, info = extract(reply)
            (out_dir / "raw.txt").write_text(reply, encoding="utf-8")
            (out_dir / "Program.cs").write_text(code, encoding="utf-8")
            meta.update(info, model=spec["id"], backend=spec["backend"], seed=seed,
                        temperature=TEMPERATURE, topP=TOP_P, maxTokens=MAX_TOKENS)
            (out_dir / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
            print(f"  {meta.get('completionTokens')} tokens, {meta.get('wallSeconds')} s, "
                  f"{len(code.splitlines())} lines of code, followed format: {info['followedFormat']}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
