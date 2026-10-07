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
| `geniex` | Planned — `geniex serve`, OpenAI-compatible |
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

## Gotchas worth knowing

- The project needs `<RuntimeIdentifier>win-arm64</RuntimeIdentifier>`; the
  Foundry package is RID-specific and the build fails without it.
- `FoundryLocalManager.CreateAsync` needs a **real** `ILogger`. A null one makes
  startup failures surface as an `ArgumentNullException` thrown from inside the
  exception constructor, hiding the cause.
- `TextItem.Text` is the payload. `ToString()` returns the type name, so the
  reply streams as `Microsoft.AI.Foundry.Local.TextItem` repeated — it looks
  like garbled output rather than an error.
