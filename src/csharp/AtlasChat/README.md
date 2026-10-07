# atlas-chat

A chat console for comparing local inference runtimes on Snapdragon,
interactively rather than from a benchmark table.

```powershell
dotnet run -c Release --project src\csharp\AtlasChat
dotnet run -c Release --project src\csharp\AtlasChat -- qwen2.5-0.5b --quiet
```

Commands: `/reset` `/stats` `/model` `/help` `/quit`

```
> what is the capital of portugal?
The capital of Portugal is Lisbon.
  80.3 tok/s · 7~ tok · first 0.14s · compute 100%
```

## Backends

| `--runtime` | Status |
| --- | --- |
| `foundry` | Implemented — Foundry Local in-process SDK 2.1.0 |
| `geniex` | Implemented — `geniex serve`, OpenAI-compatible |
| `ort-genai` | Planned — ONNX Runtime GenAI + QNN |

New backends implement `IChatRuntime`; the REPL does not change.

**Conversation history belongs to the backend, not the harness.** Each has its
own native mechanism and they do not compose: Foundry's `ChatSession` keeps
turns itself, GenieX's endpoint wants the whole message array per request, and
ORT GenAI wants an accumulated token sequence. A shared history passed down
would be double-counted by the first.

## Reading the stats line

- **tok/s** covers the decode phase only, and divides by tokens *after* the
  first — the first token is where the decode window starts, so counting it
  against that window makes short replies report absurd rates. Short turns are
  still noisy; the steady-state figure for this model is ~107 tok/s.
- **`~`** marks an estimated token count, from streamed chunks. Foundry's
  `GetUsage().CompletionTokens` is not used: it reported 48 tokens for *"Your
  name is Mike."* and 34 for a longer reply, so it is neither per-turn nor
  cumulative in any usable way.
- **engine types, not "NPU"**. The Adreno exposes `engtype_Compute` instances
  too, so a Compute reading alone does not prove the work ran on the Hexagon.
  Counters are attributed to this process by PID — something the out-of-process
  PowerShell samplers in `Scripts/` cannot do.

## The GenieX backend

```powershell
geniex serve                                     # separate terminal; 127.0.0.1:18181
dotnet run -c Release --project src\csharp\AtlasChat -- --runtime geniex
dotnet run ... -- --runtime geniex unsloth/Qwen3-4B-GGUF:Q4_0 --show-think
```

The server must already be running; `atlas-chat` will not start one, and says
so with the fix rather than a connection error. Any model the server has cached
works — it lists them on a bad name.

Three differences from the in-process backend, all of which the harness has to
handle rather than hide:

- **Utilization counters belong to the server process.** `IChatRuntime.SamplePid`
  points at it, so the stats line still attributes correctly. The console prints
  which PID it is sampling.
- **The endpoint reports neither `usage` nor `timings`** — both come back
  zeroed — so token counts are the streamed SSE chunks, counted client-side.
- **Reasoning models think over HTTP and there is no `--think=false`.** Qwen3
  and the reasoning Phi builds emit `<think>` blocks. These are hidden by
  default (`--show-think` reveals them) but still counted, because generating
  them is real work. If a whole budget disappears into reasoning the console
  says so instead of printing nothing.

> `<think>` content is **not** fed back into history. Doing so measurably
> degrades the model: it stopped recalling a name given one turn earlier.

## Why the model repeats itself

A small model answering an open-ended question will degenerate into one
sentence repeated until something stops it. Three things are in play, and only
the first is the harness's fault:

- **No token cap means no stop.** Generation runs to the 32k context window.
  `--max-tokens` (default 512) bounds it, and the stats line reports
  `ended: length` so a runaway is visible rather than silent.
- **Sampling helps a little.** `DoSample` is on with `--temperature` (0.7) and
  `--top-k` (40). Verified working: the same prompt at 0.1 and 1.5 gives
  different answers, and two runs at 1.5 differ from each other. Lowering
  `--top-k 10` reduces repetition further.
- **The model is the real limit.** `qwen2.5-0.5b` still loops on open-ended
  prompts at any of these settings. It is fine on factual questions. For
  comparison, `phi-3.5-mini` at 2.0 GB answered the same class of prompt
  coherently for 357 tokens over the HTTP endpoint.

That is awkward for this backend specifically: Foundry Local publishes only two
NPU models here, and the larger one does not load through the SDK, so the NPU
path is effectively capped at 0.5B. The GenieX backend, which takes any GGUF,
is the way out.

> **`FrequencyPenalty` and `PresencePenalty` do not work.** `SearchOptions`
> exposes both, but any non-zero value fails the request with *"Error executing
> streaming request."* They are the obvious lever for repetition and they are
> unavailable, so `--top-k` is the substitute.

## Gotchas worth knowing

- The project needs `<RuntimeIdentifier>win-arm64</RuntimeIdentifier>`; the
  Foundry package is RID-specific and the build fails without it.
- `FoundryLocalManager.CreateAsync` needs a **real** `ILogger`. A null one makes
  startup failures surface as an `ArgumentNullException` thrown from inside the
  exception constructor, hiding the cause.
- `TextItem.Text` is the payload. `ToString()` returns the type name, so the
  reply streams as `Microsoft.AI.Foundry.Local.TextItem` repeated — it looks
  like garbled output rather than an error.
