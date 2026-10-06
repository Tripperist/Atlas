// Prove whether ONNX Runtime's QNN execution provider actually executes a graph
// on the Hexagon NPU from C#, and which attachment API is required.
//
// The Python equivalent is src/setup/check_qnn.py --prove-npu. That established
// that passing providers=["QNNExecutionProvider"] is SILENTLY IGNORED and the
// session runs on CPU. This checks whether C#'s AppendExecutionProvider has the
// same trap, by counting node placement from the profiler rather than trusting
// a successful Run().
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

const string ProviderName = "QNNExecutionProvider";

string[] positional = args.Where(a => !a.StartsWith("--")).ToArray();
string modelPath = positional.Length > 0
    ? positional[0]
    : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
        "..", "..", "..", "..", "..", "setup", "_qnn_probe.onnx"));

string nativeDir = Path.Combine(AppContext.BaseDirectory, "runtimes", "win-arm64", "native");
string pluginPath = Path.Combine(nativeDir, "onnxruntime_providers_qnn.dll");

Console.WriteLine($"ORT            : {typeof(SessionOptions).Assembly.GetName().Version}");
Console.WriteLine($"model          : {modelPath}");
Console.WriteLine($"plugin         : {pluginPath}");
Console.WriteLine($"plugin exists  : {File.Exists(pluginPath)}");

if (!File.Exists(modelPath))
{
    Console.WriteLine("\nModel not found. Generate it with:");
    Console.WriteLine(@"  .\.venv\Scripts\python.exe src\setup\check_qnn.py --prove-npu");
    return 2;
}

// The QNN DLLs live under runtimes/win-arm64/native, not beside the exe, so the
// loader needs to be told where to find QnnHtp.dll and its V81 stub.
Environment.SetEnvironmentVariable(
    "PATH", nativeDir + ";" + Environment.GetEnvironmentVariable("PATH"));

// Is GetAvailableProviders simply cached on its first call? Skip the
// "before" probe when asked, so registration happens before the list is
// ever requested.
bool regFirst = args.Contains("--register-first");
if (!regFirst)
{
    Console.WriteLine($"\nproviders before register : {string.Join(", ", OrtEnv.Instance().GetAvailableProviders())}");
}
try
{
    OrtEnv.Instance().RegisterExecutionProviderLibrary(ProviderName, pluginPath);
}
catch (Exception ex)
{
    Console.WriteLine($"registration FAILED: {ex.Message}");
    return 1;
}
Console.WriteLine($"providers after register  : {string.Join(", ", OrtEnv.Instance().GetAvailableProviders())}");

var results = new List<(string Strategy, string Outcome, string Placement)>();

foreach (var strategy in new[] { "none (baseline)", "AppendExecutionProvider", "SetEpSelectionPolicy" })
{
    var so = new SessionOptions();
    string profilePrefix = Path.Combine(Path.GetTempPath(), $"qnnprobe_{Guid.NewGuid():N}");
    so.EnableProfiling = true;
    so.ProfileOutputPathPrefix = profilePrefix;

    try
    {
        switch (strategy)
        {
            case "AppendExecutionProvider":
                // The documented-everywhere approach.
                so.AppendExecutionProvider("QNN", new Dictionary<string, string>
                {
                    ["backend_type"] = "htp",
                    ["htp_performance_mode"] = "burst",
                    ["enable_htp_fp16_precision"] = "1",
                });
                break;

            case "SetEpSelectionPolicy":
                // The plugin-EP approach, equivalent to Python's
                // set_provider_selection_policy(PREFER_NPU).
                so.SetEpSelectionPolicy(ExecutionProviderDevicePolicy.PREFER_NPU);
                break;
        }
    }
    catch (Exception ex)
    {
        results.Add((strategy, "attach threw: " + ex.Message.Split('\n')[0], "-"));
        continue;
    }

    try
    {
        using var session = new InferenceSession(modelPath, so);

        // The probe graph is quantized, so its inputs are uint8 rather than
        // float. Build whatever element type the metadata actually declares.
        var inputs = new List<NamedOnnxValue>();
        foreach (var kv in session.InputMetadata)
        {
            int[] dims = kv.Value.Dimensions.Select(d => d < 0 ? 1 : d).ToArray();
            int count = dims.Aggregate(1, (a, b) => a * b);
            Type t = kv.Value.ElementType;
            NamedOnnxValue v =
                t == typeof(byte)  ? NamedOnnxValue.CreateFromTensor(kv.Key, new DenseTensor<byte>(new byte[count], dims)) :
                t == typeof(sbyte) ? NamedOnnxValue.CreateFromTensor(kv.Key, new DenseTensor<sbyte>(new sbyte[count], dims)) :
                t == typeof(ushort)? NamedOnnxValue.CreateFromTensor(kv.Key, new DenseTensor<ushort>(new ushort[count], dims)) :
                t == typeof(short) ? NamedOnnxValue.CreateFromTensor(kv.Key, new DenseTensor<short>(new short[count], dims)) :
                t == typeof(int)   ? NamedOnnxValue.CreateFromTensor(kv.Key, new DenseTensor<int>(new int[count], dims)) :
                                     NamedOnnxValue.CreateFromTensor(kv.Key, new DenseTensor<float>(new float[count], dims));
            inputs.Add(v);
        }

        using (var _ = session.Run(inputs)) { }
        string profile = session.EndProfiling();

        // Count which provider each node was assigned to. A successful Run()
        // says nothing; this is the only direct evidence.
        var counts = new Dictionary<string, int>();
        using (var doc = JsonDocument.Parse(File.ReadAllText(profile)))
        {
            foreach (var e in doc.RootElement.EnumerateArray())
            {
                if (e.TryGetProperty("cat", out var cat) && cat.GetString() == "Node" &&
                    e.TryGetProperty("args", out var a) &&
                    a.TryGetProperty("provider", out var pv))
                {
                    string name = pv.GetString() ?? "?";
                    counts[name] = counts.GetValueOrDefault(name) + 1;
                }
            }
        }
        File.Delete(profile);

        string placement = counts.Count == 0
            ? "(no node events)"
            : string.Join(", ", counts.OrderByDescending(c => c.Value).Select(c => $"{c.Key}={c.Value}"));
        results.Add((strategy, "ran", placement));
    }
    catch (Exception ex)
    {
        results.Add((strategy, "FAILED: " + ex.Message.Split('\n')[0], "-"));
    }
}

Console.WriteLine("\n--- node placement by attachment strategy ---");
Console.WriteLine($"{"strategy",-26} {"outcome",-12} placement");
foreach (var r in results)
{
    Console.WriteLine($"{r.Strategy,-26} {r.Outcome,-12} {r.Placement}");
}

// The decisive check: with CPU fallback disabled, a session that is not really
// on the NPU fails loudly instead of quietly running on CPU.
Console.WriteLine("\n--- session.disable_cpu_ep_fallback=1 with the policy API ---");
try
{
    var so = new SessionOptions();
    so.SetEpSelectionPolicy(ExecutionProviderDevicePolicy.PREFER_NPU);
    so.AddSessionConfigEntry("session.disable_cpu_ep_fallback", "1");
    using var session = new InferenceSession(modelPath, so);
    Console.WriteLine("  loaded with CPU fallback disabled -> the graph is genuinely on the NPU");
}
catch (Exception ex)
{
    Console.WriteLine("  refused: " + ex.Message.Split('\n')[0]);
}

return 0;
