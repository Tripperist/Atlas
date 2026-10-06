// Benchmark Foundry Local through its in-process C# SDK.
//
// Two other routes are measured elsewhere in this repo:
//   Scripts/Invoke-FoundryBench.ps1   CLI + OpenAI HTTP endpoint
//   src/setup/bench_foundry_sdk.py    in-process Python SDK
//
// This is the .NET equivalent of the Python one, so the three can be compared
// on the same model. It targets the Session API introduced in SDK 2.0.1, which
// replaced the in-process OpenAI-style clients: Model -> Session -> Request ->
// Response, identical in shape across C#, Python, JavaScript and Rust.
using System.Diagnostics;
using Microsoft.AI.Foundry.Local;
using Microsoft.Extensions.Logging;

string alias = args.FirstOrDefault(a => !a.StartsWith("--")) ?? "qwen2.5-0.5b";
int maxTokens = 400;
int repeat = 3;
const string Prompt =
    "Plan a detailed day in Lisbon, with specific neighbourhoods, food and timings.";

Console.WriteLine($"sdk      : {typeof(ChatSession).Assembly.GetName().Version}");
Console.WriteLine($"model    : {alias}");

// A null ILogger is not tolerated: the failure path logs through it, so a
// null turns any startup error into an ArgumentNullException that hides the
// real cause. Always pass a real logger.
using var loggerFactory = LoggerFactory.Create(b => b.AddConsole().SetMinimumLevel(Microsoft.Extensions.Logging.LogLevel.Warning));
var logger = loggerFactory.CreateLogger("atlas");
await FoundryLocalManager.CreateAsync(new Configuration { AppName = "atlas_bench" }, logger, null);
var manager = FoundryLocalManager.Instance;

// Execution providers come from Windows ML on first use; a no-op once
// registered. 2.x picks the provider itself -- the model variant decides.
await manager.DownloadAndRegisterEpsAsync(null);

var catalog = await manager.GetCatalogAsync();
var model = await catalog.GetModelAsync(alias);
if (model is null)
{
    Console.WriteLine($"model '{alias}' not found in the catalogue");
    return 2;
}

var loadWatch = Stopwatch.StartNew();
if (!await model.IsCachedAsync())
{
    Console.WriteLine("downloading ...");
    await model.DownloadAsync(p => Console.Write($"\r  {p:F1}%"));
    Console.WriteLine();
}
await model.LoadAsync();
loadWatch.Stop();
Console.WriteLine($"variant  : {model.Id}");
Console.WriteLine($"load     : {loadWatch.Elapsed.TotalSeconds:F1}s");

var rates = new List<double>();
var firsts = new List<double>();

using (var session = new ChatSession(model))
{
    session.SetStreaming(true);

    for (int run = 1; run <= repeat; run++)
    {
        using var request = new Request();
        request.AddItem(MessageItem.User(Prompt), false);

        int produced = 0;
        double? firstAt = null;
        var sw = Stopwatch.StartNew();

        var streaming = session.ProcessStreamingRequestAsync(request, default);
        await foreach (var item in streaming)
        {
            if (item is MessageItem m && !string.IsNullOrEmpty(m.GetSimpleText()))
            {
                firstAt ??= sw.Elapsed.TotalSeconds;
                if (++produced >= maxTokens) break;
            }
            else if (item is TextItem)
            {
                firstAt ??= sw.Elapsed.TotalSeconds;
                if (++produced >= maxTokens) break;
            }
        }
        sw.Stop();

        if (produced == 0)
        {
            Console.WriteLine($"  run {run}: produced nothing");
            continue;
        }

        // The usage block is authoritative where a stream chunk count is not.
        int generated = produced;
        try
        {
            var final = await streaming.FinalResponse;
            var usage = final.GetUsage();
            var prop = usage.GetType().GetProperty("CompletionTokens");
            if (prop?.GetValue(usage) is int ct && ct > 0) generated = ct;
        }
        catch { /* usage is best effort */ }

        double decodeS = sw.Elapsed.TotalSeconds - (firstAt ?? 0);
        double rate = decodeS > 0 ? generated / decodeS : 0;
        rates.Add(rate);
        firsts.Add(firstAt ?? 0);
        Console.WriteLine($"  run {run}: {rate,6:F1} tok/s  {generated} tok in " +
                          $"{sw.Elapsed.TotalSeconds,5:F1}s  first {firstAt ?? 0:F2}s");
    }
}

try { await model.UnloadAsync(); } catch { /* best effort */ }

if (rates.Count == 0)
{
    Console.WriteLine("\nno run produced output");
    return 1;
}

Console.WriteLine($"\nmean     : {rates.Average():F1} tok/s, first token {firsts.Average():F2}s");
Console.WriteLine("\nPASS");
manager.Shutdown();
return 0;
