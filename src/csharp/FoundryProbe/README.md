# FoundryProbe

Benchmarks Foundry Local through its **in-process C# SDK**, the .NET
counterpart to `src/setup/bench_foundry_sdk.py`.

```powershell
dotnet run -c Release --project src\csharp\FoundryProbe
dotnet run -c Release --project src\csharp\FoundryProbe qwen2.5-0.5b
```

Targets the **Session API** introduced in SDK 2.0.1 — `Model -> Session ->
Request -> Response` — using `Microsoft.AI.Foundry.Local` 2.1.0. Do **not** use
the `.WinML` package; it was retired in 2.0.1 and is frozen at 1.2.4.

Two things that will stop you otherwise:

- The project needs `<RuntimeIdentifier>win-arm64</RuntimeIdentifier>`. The
  package is RID-specific and the build fails without it.
- `FoundryLocalManager.CreateAsync` needs a **real** `ILogger`. Passing null
  makes any startup failure surface as an `ArgumentNullException` thrown from
  inside the exception constructor, hiding the real cause.

See the README section "Hello world — in-process SDK" for measured results.
