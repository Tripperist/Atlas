// Benchmark ONNX Runtime GenAI from C# on the same axes as src/setup/bench_ort_genai.py.
//
// The same method as the Python harness, on purpose, so a difference between the two is a
// difference between the runtimes and not between the methods:
//   * a fixed-length prompt of random token ids (default 512), so prefill is exactly N tokens
//   * a fixed number of generated tokens (default 128)
//   * prefill and decode timed separately
//
// Run it through Scripts/Invoke-OrtGenAiBench.ps1, which checks the machine's conditions
// first (a battery-powered run looks like a 3x regression) and records the result. Run
// directly, it prints and, with --json-out, writes one JSON object.
//
//   dotnet run -c Release --project src\csharp\OrtBench -- <model-dir> [--cpu-only]
//       [--n-prompt 512] [--n-gen 128] [--repetitions 3] [--seed 42] [--json-out result.json]
//
// GenAiProbe stays what it is, a smoke probe that proves a model runs.
using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using Microsoft.ML.OnnxRuntimeGenAI;

string modelDir = args.FirstOrDefault(a => !a.StartsWith("--")) ?? "";
bool cpuOnly = args.Contains("--cpu-only");
int nPrompt = IntArg("--n-prompt", 512);
int nGen = IntArg("--n-gen", 128);
int repetitions = IntArg("--repetitions", 3);
int seed = IntArg("--seed", 42);
string? jsonOut = StrArg("--json-out");

int IntArg(string name, int fallback) => int.TryParse(StrArg(name), out var v) ? v : fallback;
string? StrArg(string name)
{
    int i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}

if (!Directory.Exists(modelDir))
{
    Console.WriteLine($"model dir not found: '{modelDir}'");
    return 2;
}

string nativeDir = Path.Combine(AppContext.BaseDirectory, "runtimes", "win-arm64", "native");
Environment.SetEnvironmentVariable("PATH", nativeDir + ";" + Environment.GetEnvironmentVariable("PATH"));

string FileVersion(string file)
{
    string p = Path.Combine(nativeDir, file);
    return File.Exists(p) ? FileVersionInfo.GetVersionInfo(p).ProductVersion ?? "?" : "absent";
}

// The GenAI managed assembly reports 0.0.0.0, so its version is read from the native library below.
string AssemblyVersion(Assembly asm) =>
    FileVersionInfo.GetVersionInfo(asm.Location).ProductVersion?.Split('+')[0] ?? "?";

var versions = new Dictionary<string, string>
{
    ["Microsoft.ML.OnnxRuntime"] = AssemblyVersion(Assembly.Load("Microsoft.ML.OnnxRuntime")),
    ["onnxruntime_providers_qnn.dll"] = FileVersion("onnxruntime_providers_qnn.dll"),
    ["onnxruntime-genai.dll"] = FileVersion("onnxruntime-genai.dll"),
};
foreach (var kv in versions) Console.WriteLine($"{kv.Key,-32}: {kv.Value}");

string provider = cpuOnly ? "cpu" : "QNNExecutionProvider";
Console.WriteLine($"provider                        : {provider}");
Console.WriteLine($"prompt / generate               : {nPrompt} / {nGen} tokens");

if (!cpuOnly)
{
    // Registering the library is not enough on its own; the provider is attached to the
    // Config below. See GenAiProbe for the reasoning.
    string plugin = Path.Combine(nativeDir, "onnxruntime_providers_qnn.dll");
    var ortAsm = Assembly.Load("Microsoft.ML.OnnxRuntime");
    var env = ortAsm.GetType("Microsoft.ML.OnnxRuntime.OrtEnv")!;
    object inst = env.GetMethod("Instance", BindingFlags.Public | BindingFlags.Static)!.Invoke(null, null)!;
    env.GetMethod("RegisterExecutionProviderLibrary")!.Invoke(inst, new object[] { "QNNExecutionProvider", plugin });
}

using var ogaHandle = new OgaHandle();
var load = Stopwatch.StartNew();
Model model;
if (cpuOnly) model = new Model(modelDir);
else
{
    using var config = new Config(modelDir);
    config.ClearProviders();
    config.AppendProvider("QNNExecutionProvider");
    model = new Model(config);
}
double loadS = load.Elapsed.TotalSeconds;
Console.WriteLine($"model load                      : {loadS:F1}s\n");

// Random token ids from a seeded generator. They are not the Python harness's ids (the two
// languages' generators differ), which does not matter: the timing depends on the count.
var rng = new Random(seed);
int[] promptIds = Enumerable.Range(0, nPrompt).Select(_ => rng.Next(1, 32000)).ToArray();

var prefills = new List<double>();
var decodes = new List<double>();
var ttfts = new List<double>();
using (model)
{
    for (int rep = 1; rep <= repetitions; rep++)
    {
        using var genParams = new GeneratorParams(model);
        using var generator = new Generator(model, genParams);

        var t0 = Stopwatch.StartNew();
        generator.AppendTokens(promptIds);
        double prefillS = t0.Elapsed.TotalSeconds;

        int produced = 0;
        var t1 = Stopwatch.StartNew();
        while (!generator.IsDone() && produced < nGen)
        {
            generator.GenerateNextToken();
            produced++;
        }
        double decodeS = t1.Elapsed.TotalSeconds;
        if (produced == 0) { Console.WriteLine($"  rep {rep}: produced no tokens"); continue; }

        double pp = prefillS > 0 ? nPrompt / prefillS : 0;
        double tg = decodeS > 0 ? produced / decodeS : 0;
        prefills.Add(pp); decodes.Add(tg); ttfts.Add(prefillS);
        Console.WriteLine($"  rep {rep}: ttft {prefillS * 1000,7:F1} ms  prefill {pp,8:F1} tok/s  decode {tg,6:F1} tok/s  ({produced} gen)");
    }
}

if (prefills.Count == 0) { Console.WriteLine("\nno successful repetitions"); return 1; }

double Mean(List<double> v) => v.Average();
double Stdev(List<double> v) => v.Count > 1 ? Math.Sqrt(v.Sum(x => (x - v.Average()) * (x - v.Average())) / (v.Count - 1)) : 0;

Console.WriteLine($"\n[result] ttft {Mean(ttfts) * 1000:F1} ms  prefill {Mean(prefills):F1} tok/s  decode {Mean(decodes):F1} tok/s");

if (jsonOut is not null)
{
    var result = new Dictionary<string, object?>
    {
        ["provider"] = provider,
        ["nPrompt"] = nPrompt, ["nGen"] = nGen, ["n"] = prefills.Count, ["seed"] = seed,
        ["loadSeconds"] = Math.Round(loadS, 2),
        ["prefillTps"] = Mean(prefills), ["decodeTps"] = Mean(decodes), ["ttftSeconds"] = Mean(ttfts),
        ["decodeStdev"] = Stdev(decodes), ["decodeReps"] = decodes,
        ["prefillStdev"] = Stdev(prefills),
        ["versions"] = versions,
    };
    File.WriteAllText(jsonOut, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
}
return 0;
