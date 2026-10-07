// atlas-chat -- a chat console for comparing local inference runtimes on
// Snapdragon, one backend at a time.
//
//   atlas-chat                              foundry, qwen2.5-0.5b
//   atlas-chat --runtime foundry qwen2.5-0.5b
//   atlas-chat --quiet                      hide the per-turn stats line
//
// Commands: /reset  /stats  /model  /help  /quit
using System.Diagnostics;
using AtlasChat;

string runtimeName = "foundry";
string? model = null;
bool showStats = true;
int maxTokens = 512;
float temperature = 0.7f;
int topK = 40;

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--runtime" when i + 1 < args.Length: runtimeName = args[++i]; break;
        case "--quiet": showStats = false; break;
        case "--max-tokens" when i + 1 < args.Length: maxTokens = int.Parse(args[++i]); break;
        case "--temperature" when i + 1 < args.Length: temperature = float.Parse(args[++i]); break;
        case "--top-k" when i + 1 < args.Length: topK = int.Parse(args[++i]); break;
        case "--help" or "-h": Usage(); return 0;
        default:
            if (args[i].StartsWith('-')) { Console.Error.WriteLine($"unknown option {args[i]}"); return 2; }
            model ??= args[i];
            break;
    }
}

IChatRuntime runtime;
switch (runtimeName)
{
    case "foundry":
        runtime = new FoundryRuntime(maxTokens, temperature, topK);
        model ??= "qwen2.5-0.5b";
        break;

    // GenieX and ONNX Runtime GenAI slot in behind IChatRuntime; the REPL below
    // does not change when they do.
    case "geniex":
    case "ort-genai":
        Console.Error.WriteLine($"'{runtimeName}' is not implemented yet. Available: foundry");
        return 2;

    default:
        Console.Error.WriteLine($"unknown runtime '{runtimeName}'. Available: foundry");
        return 2;
}

Console.WriteLine($"atlas-chat · {runtime.Name} · {model}");
Console.Write("loading ... ");

using var cancel = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancel.Cancel(); };

try
{
    await runtime.StartAsync(model, cancel.Token);
}
catch (Exception ex)
{
    Console.WriteLine();
    Console.Error.WriteLine($"failed to start: {ex.Message.Split('\n')[0]}");
    return 1;
}

Console.WriteLine($"ready in {runtime.LoadTime.TotalSeconds:F1}s");
Console.WriteLine($"variant: {runtime.ModelId}");
Console.WriteLine("type /help for commands, /quit to exit");
Console.WriteLine();

using var sampler = OperatingSystem.IsWindows() ? new EngineSampler() : null;

while (true)
{
    Console.ForegroundColor = ConsoleColor.Cyan;
    Console.Write("> ");
    Console.ResetColor();

    string? line = Console.ReadLine();
    if (line is null) break;                       // ctrl-Z / piped EOF
    line = line.Trim();
    if (line.Length == 0) continue;

    if (line.StartsWith('/'))
    {
        string cmd = line.Split(' ')[0].ToLowerInvariant();
        if (cmd is "/quit" or "/exit" or "/q") break;
        if (cmd == "/help") { Usage(); continue; }
        if (cmd == "/model") { Console.WriteLine($"  {runtime.Name} · {runtime.ModelId}"); continue; }
        if (cmd == "/stats") { showStats = !showStats; Console.WriteLine($"  stats {(showStats ? "on" : "off")}"); continue; }
        if (cmd == "/reset") { runtime.Reset(); Console.WriteLine("  conversation cleared"); continue; }
        Console.WriteLine($"  unknown command {cmd}; try /help");
        continue;
    }

    int chunks = 0;
    double? firstTokenS = null;
    var sw = Stopwatch.StartNew();
    sampler?.Start();

    try
    {
        await foreach (string piece in runtime.StreamAsync(line, cancel.Token))
        {
            firstTokenS ??= sw.Elapsed.TotalSeconds;
            chunks++;
            Console.Write(piece);
        }
    }
    catch (OperationCanceledException)
    {
        Console.WriteLine("\n  (cancelled)");
    }
    catch (Exception ex)
    {
        Console.WriteLine();
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine($"  error: {ex.Message.Split('\n')[0]}");
        Console.ResetColor();
        sampler?.Stop();
        continue;
    }

    sw.Stop();
    var engines = sampler?.Stop();
    Console.WriteLine();

    if (showStats)
    {
        // Rate covers the decode phase only, so it is comparable with the
        // benchmark harnesses rather than diluted by time to first token.
        // The divisor is tokens AFTER the first, because the first one is what
        // the decode window starts at -- counting it against that window makes
        // short replies report absurd rates.
        int tokens = runtime.LastTokenCount ?? chunks;
        bool estimated = runtime.LastTokenCount is null;
        double decodeS = sw.Elapsed.TotalSeconds - (firstTokenS ?? 0);
        double rate = decodeS > 0 && chunks > 1 ? (chunks - 1) / decodeS : 0;

        var parts = new List<string>
        {
            rate > 0 ? $"{rate:F1} tok/s" : "rate n/a",
            $"{tokens}{(estimated ? "~" : "")} tok",
            $"first {firstTokenS ?? 0:F2}s",
        };

        // "length" means the cap stopped it, not the model. Without this the
        // only symptom of a runaway generation is a wall of repeated text.
        if (runtime.LastFinishReason is { Length: > 0 } reason && reason != "stop")
        {
            parts.Add($"ended: {reason}");
        }

        // Engine types rather than "NPU": the Adreno exposes compute engines
        // too, so a Compute reading alone does not identify the Hexagon.
        if (engines is { Count: > 0 })
        {
            parts.AddRange(engines
                .Where(e => e.Value >= 1.0)
                .OrderByDescending(e => e.Value)
                .Select(e => $"{e.Key.ToLowerInvariant()} {e.Value:F0}%"));
        }

        Console.ForegroundColor = ConsoleColor.DarkGray;
        Console.WriteLine($"  {string.Join(" · ", parts)}");
        Console.ResetColor();
    }

    Console.WriteLine();
}

await runtime.DisposeAsync();
return 0;

static void Usage()
{
    Console.WriteLine("""
      usage: atlas-chat [--runtime foundry] [model] [--quiet]
                        [--max-tokens N] [--temperature T]
                        [--top-k K]

      commands:
        /reset    forget the conversation so far
        /stats    toggle the per-turn stats line
        /model    show the resolved model variant
        /help     this
        /quit     exit

      the stats line reports engine types, not "NPU": the Adreno exposes
      compute engines as well, so a Compute reading alone does not prove
      the work ran on the Hexagon.
      """);
}
