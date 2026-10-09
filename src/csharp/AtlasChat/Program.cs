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
string host = "127.0.0.1:18181";
bool showThinking = false;
bool verbose = false;

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--runtime" when i + 1 < args.Length: runtimeName = args[++i]; break;
        case "--quiet": showStats = false; break;
        case "--max-tokens" when i + 1 < args.Length: maxTokens = int.Parse(args[++i]); break;
        case "--temperature" when i + 1 < args.Length: temperature = float.Parse(args[++i]); break;
        case "--top-k" when i + 1 < args.Length: topK = int.Parse(args[++i]); break;
        case "--host" when i + 1 < args.Length: host = args[++i]; break;
        case "--show-think": showThinking = true; break;
        case "--verbose": verbose = true; break;
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

    case "geniex":
        runtime = new GenieXRuntime(host, maxTokens, temperature, showThinking);
        // Whatever the server has cached; the smallest is a sensible default.
        model ??= "unsloth/Qwen3-0.6B-GGUF:Q4_0";
        break;

    case "ort-genai":
        runtime = new OrtGenAiRuntime(maxTokens, temperature, topK, showThinking, verbose);
        // A directory, not an alias: this backend has no catalogue. Resolved
        // against the repository root as well as the working directory, so it
        // works from anywhere rather than only from the repo root.
        model = RepoPaths.Resolve(
            model ?? Path.Combine("models", "Phi-4-mini-reasoning-onnx", "npu", "qnn-int4"));
        break;

    default:
        Console.Error.WriteLine($"unknown runtime '{runtimeName}'. Available: foundry, geniex, ort-genai");
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

// Sample whichever process actually runs inference: ourselves for an
// in-process backend, the server for GenieX.
using var sampler = OperatingSystem.IsWindows() ? new EngineSampler(runtime.SamplePid) : null;
if (runtime.SamplePid != Environment.ProcessId)
{
    Console.WriteLine($"sampling pid {runtime.SamplePid} (the server)");
}

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

    // A reasoning model can spend the whole budget inside <think>, which is
    // hidden by default -- without this the turn just looks broken.
    if (chunks == 0 && (runtime.LastTokenCount ?? 0) > 0)
    {
        Console.ForegroundColor = ConsoleColor.DarkGray;
        Console.WriteLine($"  (all {runtime.LastTokenCount} tokens went to hidden reasoning; "
                          + "raise --max-tokens or pass --show-think)");
        Console.ResetColor();
    }

    if (showStats)
    {
        // Rate covers the decode phase only, so it is comparable with the
        // benchmark harnesses rather than diluted by time to first token.
        // The divisor is tokens AFTER the first, because the first one is what
        // the decode window starts at -- counting it against that window makes
        // short replies report absurd rates.
        int tokens = runtime.LastTokenCount ?? chunks;
        bool estimated = runtime.LastTokenCount is null;
        // Prefer the backend's own first-token time; see IChatRuntime.
        double firstS = runtime.LastFirstTokenSeconds ?? firstTokenS ?? 0;
        double decodeS = sw.Elapsed.TotalSeconds - firstS;
        int counted = runtime.LastTokenCount ?? chunks;
        double rate = decodeS > 0 && counted > 1 ? (counted - 1) / decodeS : 0;

        var parts = new List<string>
        {
            rate > 0 ? $"{rate:F1} tok/s" : "rate n/a",
            $"{tokens}{(estimated ? "~" : "")} tok",
            $"first {firstS:F2}s",
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
      usage: atlas-chat [--runtime foundry|geniex|ort-genai] [model] [--quiet]
                        [--max-tokens N] [--temperature T] [--top-k K]
                        [--host 127.0.0.1:18181] [--show-think]

      geniex needs a running server:  geniex serve
      ort-genai takes a model DIRECTORY, not an alias

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
