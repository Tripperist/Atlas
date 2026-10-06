// Run a language model on the Hexagon NPU through ONNX Runtime GenAI from C#.
//
// The Python equivalent is src/setup/run_ort_genai.py. That path needs two
// things beyond downloading the model: the QNN plugin registered, and the
// provider attached to the Config -- registering alone leaves GenAI building a
// CPU-only session with nothing to run the EPContext nodes on.
using System.Diagnostics;
using System.Reflection;
using Microsoft.ML.OnnxRuntimeGenAI;

string modelDir = args.FirstOrDefault(a => !a.StartsWith("--"))
    ?? Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
        "..", "..", "..", "..", "..", "..", "models",
        "Phi-4-mini-reasoning-onnx", "npu", "qnn-int4"));

bool cpuOnly = args.Contains("--cpu-only");
int maxTokens = 64;

string nativeDir = Path.Combine(AppContext.BaseDirectory, "runtimes", "win-arm64", "native");
Environment.SetEnvironmentVariable(
    "PATH", nativeDir + ";" + Environment.GetEnvironmentVariable("PATH"));

Console.WriteLine($"model dir : {modelDir}");
Console.WriteLine($"exists    : {Directory.Exists(modelDir)}");
Console.WriteLine($"provider  : {(cpuOnly ? "CPU (control)" : "QNNExecutionProvider")}");

if (!Directory.Exists(modelDir))
{
    Console.WriteLine("\nModel not found. Download it with:");
    Console.WriteLine("  hf download microsoft/Phi-4-mini-reasoning-onnx --include \"npu/*\" " +
                      "--local-dir models\\Phi-4-mini-reasoning-onnx");
    return 2;
}

// GenAI exposes no registration helper of its own in this binding. Ask ORT to
// register the plugin library, which is the same native runtime underneath.
if (!cpuOnly)
{
    string plugin = Path.Combine(nativeDir, "onnxruntime_providers_qnn.dll");
    Console.WriteLine($"plugin    : {plugin} (exists: {File.Exists(plugin)})");
    try
    {
        var ortAsm = Assembly.Load("Microsoft.ML.OnnxRuntime");
        var env = ortAsm.GetType("Microsoft.ML.OnnxRuntime.OrtEnv")!;
        object inst = env.GetMethod("Instance", BindingFlags.Public | BindingFlags.Static)!
                         .Invoke(null, null)!;
        env.GetMethod("RegisterExecutionProviderLibrary")!
           .Invoke(inst, new object[] { "QNNExecutionProvider", plugin });
        Console.WriteLine("register  : ok (via Microsoft.ML.OnnxRuntime)");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"register  : skipped ({ex.InnerException?.Message ?? ex.Message})");
    }
}

using var ogaHandle = new OgaHandle();
var sw = Stopwatch.StartNew();

Model model;
try
{
    if (cpuOnly)
    {
        model = new Model(modelDir);
    }
    else
    {
        // Registering the library is NOT enough -- attach the provider to the
        // config, exactly as the Python path does.
        using var config = new Config(modelDir);
        config.ClearProviders();
        config.AppendProvider("QNNExecutionProvider");
        model = new Model(config);
    }
}
catch (Exception ex)
{
    Console.WriteLine($"\nmodel load FAILED: {ex.Message.Split('\n')[0]}");
    return 1;
}
Console.WriteLine($"model load: {sw.Elapsed.TotalSeconds:F1}s");

using (model)
using (var tokenizer = new Tokenizer(model))
{
    const string prompt = "<|user|>\nWhat is 17 times 23?<|end|>\n<|assistant|>";
    var sequences = tokenizer.Encode(prompt);

    using var genParams = new GeneratorParams(model);
    using var generator = new Generator(model, genParams);

    var prefill = Stopwatch.StartNew();
    try
    {
        generator.AppendTokenSequences(sequences);
    }
    catch (Exception ex)
    {
        // This is where onnxruntime-genai 0.16.x fails on EPContext models.
        Console.WriteLine($"\nprompt pass FAILED: {ex.Message.Split('\n')[0]}");
        return 1;
    }
    prefill.Stop();

    using var stream = tokenizer.CreateStream();
    int produced = 0;
    var decode = Stopwatch.StartNew();
    Console.Write("\noutput: ");
    while (!generator.IsDone() && produced < maxTokens)
    {
        generator.GenerateNextToken();
        Console.Write(stream.Decode(generator.GetSequence(0)[^1]));
        produced++;
    }
    decode.Stop();

    Console.WriteLine();
    Console.WriteLine($"\nprompt tokens : {sequences[0].Length}");
    Console.WriteLine($"time to first : {prefill.Elapsed.TotalSeconds:F2}s");
    Console.WriteLine($"generated     : {produced} tokens");
    Console.WriteLine($"decode rate   : {produced / decode.Elapsed.TotalSeconds:F1} tok/s");
}

Console.WriteLine("\nPASS - generation completed");
return 0;
