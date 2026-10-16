"""One round of compiler feedback for programs that did not build.

    python repair.py runs/<model>/s<seed> [...]

For each run directory whose result.json says the build failed, send the model
the original task, its own reply, and the compiler errors, and ask for a fixed
Program.cs. The result is saved beside it as <dir>-repair1/ and can be scored
with eval.py like any other run. One round only: the question is whether a
single piece of feedback is enough, not how long a model can be left to flail.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.request
from pathlib import Path

import generate as g

HERE = Path(__file__).resolve().parent


def feedback(errors: list[str]) -> str:
    listing = "\n".join(errors)
    return (
        "That program does not compile. The compiler reported:\n\n"
        f"{listing}\n\n"
        "Fix it. Reply with exactly one ```csharp code block containing the complete corrected "
        "Program.cs, and no other text."
    )


def chat(spec_key: str, messages: list[dict], seed: int) -> tuple[str, dict]:
    spec = g.MODELS[spec_key]
    if spec_key == "7b":
        endpoint = g.foundry_endpoint()
        catalog = json.load(urllib.request.urlopen(f"{endpoint}/v1/models", timeout=60))
        model = next((m["id"] for m in catalog["data"] if m.get("parent") == spec["id"] and "qnn-npu" in m["id"]), spec["id"])
        body = {"model": model, "messages": messages, "max_tokens": g.MAX_TOKENS,
                "temperature": g.TEMPERATURE, "top_p": g.TOP_P, "seed": seed}
        req = urllib.request.Request(f"{endpoint}/v1/chat/completions", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        t0 = time.time()
        r = json.load(urllib.request.urlopen(req, timeout=1800))
        return r["choices"][0]["message"]["content"], {
            "wallSeconds": round(time.time() - t0, 1), "completionTokens": r.get("usage", {}).get("completion_tokens")}
    return serve_chat(messages, seed)


def serve_chat(messages: list[dict], seed: int) -> tuple[str, dict]:
    """A real multi-turn request to `geniex serve`, as the 7B gets from Foundry."""
    base = "http://127.0.0.1:18181/v1"
    ids = [m["id"] for m in json.load(urllib.request.urlopen(f"{base}/models", timeout=60))["data"]]
    want = g.MODELS["30b"]["id"]
    model = next((i for i in ids if i.lower() == want.lower()), None) or next(i for i in ids if i.lower().startswith(want.lower().split(":")[0]))
    body = {"model": model, "messages": messages, "max_tokens": g.MAX_TOKENS,
            "temperature": g.TEMPERATURE, "top_p": g.TOP_P, "seed": seed}
    req = urllib.request.Request(f"{base}/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=1800))
    # the endpoint reports no usage, so there is no token count to record
    return r["choices"][0]["message"]["content"], {"wallSeconds": round(time.time() - t0, 1)}


def start_server():
    """geniex serve on the GPU, so it cannot contend with the NPU."""
    import subprocess
    proc = subprocess.Popen(["geniex", "serve", "--compute", "gpu", "--nctx", "8192", "--skip-update"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            urllib.request.urlopen("http://127.0.0.1:18181/v1/models", timeout=2)
            return proc
        except Exception:
            time.sleep(1)
    proc.kill()
    raise SystemExit("geniex serve did not come up")


def stop_server(proc) -> None:
    import subprocess
    subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)


def main() -> int:
    return run(None)


def run(server) -> int:
    try:
        for arg in sys.argv[1:]:
            d = Path(arg)
            result = json.loads((d / "result.json").read_text(encoding="utf-8"))
            if result["build"]["built"]:
                print(f"{d}: builds, nothing to repair")
                continue
            meta = json.loads((d / "meta.json").read_text(encoding="utf-8"))
            key = "30b" if "30b" in str(d) else "7b"
            messages = [
                {"role": "user", "content": g.PROMPT},
                {"role": "assistant", "content": (d / "raw.txt").read_text(encoding="utf-8")},
                {"role": "user", "content": feedback(result["build"]["errorSample"] or ["(no error text captured)"])},
            ]
            print(f"{d}: asking for a fix ...", flush=True)
            if key == "30b" and server is None:
                server = start_server()
            reply, m = chat(key, messages, meta["seed"])
            code, info = g.extract(reply)
            out = d.parent / f"{d.name}-repair1"
            out.mkdir(exist_ok=True)
            (out / "raw.txt").write_text(reply, encoding="utf-8")
            (out / "Program.cs").write_text(code, encoding="utf-8")
            m.update(info, repairOf=str(d.name), errorsShown=result["build"]["errorSample"], seed=meta["seed"])
            (out / "meta.json").write_text(json.dumps(m, indent=1), encoding="utf-8")
            print(f"  saved {out}  ({m.get('completionTokens')} tokens, followed format: {info['followedFormat']})", flush=True)
    finally:
        if server is not None:
            stop_server(server)
    return 0


if __name__ == "__main__":
    sys.exit(main())
