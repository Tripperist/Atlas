using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntimeGenAI;

namespace AtlasChat;

/// <summary>
/// ONNX Runtime GenAI with the QNN execution provider, in this process.
/// </summary>
/// <remarks>
/// Takes a model DIRECTORY rather than an alias: this backend has no
/// catalogue, and needs a folder containing an ONNX graph plus
/// <c>genai_config.json</c>. In practice that means one of Microsoft's own
/// <c>*-onnx</c> repositories.
///
/// Two requirements, neither of which fails loudly on its own:
///
/// * The QNN plugin must be registered, through ONNX Runtime's OrtEnv --
///   GenAI exposes no registration helper of its own in C#.
/// * The provider must then be attached to the Config. Registering alone
///   leaves GenAI building a CPU-only session with nothing to run the
///   EPContext nodes on.
///
/// <c>max_length</c> is deliberately never set. This model class sizes its KV
/// cache from <c>genai_config.json</c> via <c>past_present_share_buffer</c>,
/// and forcing a different value breaks that allocation. Generation is capped
/// by counting tokens here instead.
/// </remarks>
internal sealed class OrtGenAiRuntime : IChatRuntime
{
    private const string ProviderName = "QNNExecutionProvider";

    private readonly List<(string Role, string Content)> _history = new();
    private readonly int _maxOutputTokens;
    private readonly float _temperature;
    private readonly int _topK;
    private readonly ThinkingFilter _thinking;
    private readonly bool _verbose;
    private Model? _model;
    private Tokenizer? _tokenizer;
    private OgaHandle? _oga;
    private int _streamedTokens;

    public OrtGenAiRuntime(int maxOutputTokens, float temperature, int topK, bool showThinking, bool verbose)
    {
        _verbose = verbose;
        _maxOutputTokens = maxOutputTokens;
        _temperature = temperature;
        _topK = topK;
        _thinking = new ThinkingFilter(showThinking);
    }

    public string Name => "ort-genai";
    public string ModelId { get; private set; } = "(not loaded)";
    public TimeSpan LoadTime { get; private set; }
    public int? LastTokenCount => _streamedTokens > 0 ? _streamedTokens : null;
    public string? LastFinishReason { get; private set; }
    public double? LastFirstTokenSeconds { get; private set; }

    /// Inference runs here, so our own counters are the right ones.
    public int SamplePid => Environment.ProcessId;

    public Task StartAsync(string modelDir, CancellationToken ct)
    {
        if (!Directory.Exists(modelDir))
        {
            // Show the absolute path and the working directory: the usual cause
            // is a relative path resolved against an unexpected cwd.
            throw new InvalidOperationException(
                $"no such directory: {Path.GetFullPath(modelDir)}" + Environment.NewLine +
                $"  working directory: {Environment.CurrentDirectory}" + Environment.NewLine +
                "  this backend needs a folder containing genai_config.json, e.g. " +
                "models/Phi-4-mini-reasoning-onnx/npu/qnn-int4");
        }
        if (!File.Exists(Path.Combine(modelDir, "genai_config.json")))
        {
            throw new InvalidOperationException(
                $"no genai_config.json in '{modelDir}'. A GenieX bundle has genie_config.json, " +
                "which is a different format and cannot be loaded here.");
        }

        var sw = Stopwatch.StartNew();

        // Where the QNN natives land depends on how the project is built: a
        // RID-specific build puts them beside the exe, a portable one under
        // runtimes/win-arm64/native. Check both rather than assuming.
        string plugin = new[]
            {
                Path.Combine(AppContext.BaseDirectory, "onnxruntime_providers_qnn.dll"),
                Path.Combine(AppContext.BaseDirectory, "runtimes", "win-arm64", "native",
                             "onnxruntime_providers_qnn.dll"),
            }
            .FirstOrDefault(File.Exists)
            ?? throw new InvalidOperationException(
                "onnxruntime_providers_qnn.dll not found next to the executable. " +
                "Is the Qualcomm.ML.OnnxRuntime.QNN package referenced?");

        Environment.SetEnvironmentVariable(
            "PATH", Path.GetDirectoryName(plugin) + ";" + Environment.GetEnvironmentVariable("PATH"));

        try
        {
            OrtEnv.Instance().RegisterExecutionProviderLibrary(ProviderName, plugin);
        }
        catch (Exception ex) when (ex.Message.Contains("already", StringComparison.OrdinalIgnoreCase))
        {
            // Registered earlier in this process; nothing to do.
        }

        // ORT and GenAI both log warnings through their own environments while
        // loading this bundle -- roughly twenty lines of provider-option
        // overwrites and node-assignment notes. Informative once, noise on
        // every start.
        if (!_verbose)
        {
            try { OrtEnv.Instance().EnvLogLevel = OrtLoggingLevel.ORT_LOGGING_LEVEL_ERROR; }
            catch (Exception) { /* best effort */ }
        }

        _oga = new OgaHandle();

        // Registering is not enough; attach the provider to the config.
        using var config = new Config(modelDir);
        config.ClearProviders();
        config.AppendProvider(ProviderName);

        _model = new Model(config);
        _tokenizer = new Tokenizer(_model);

        LoadTime = sw.Elapsed;
        ModelId = Path.GetFileName(Path.TrimEndingDirectorySeparator(modelDir));
        return Task.CompletedTask;
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string userMessage, [EnumeratorCancellation] CancellationToken ct)
    {
        if (_model is null || _tokenizer is null) throw new InvalidOperationException("StartAsync first.");

        LastFinishReason = null;
        LastFirstTokenSeconds = null;
        _streamedTokens = 0;
        _thinking.Reset();
        _history.Add(("user", userMessage));

        string prompt = BuildPrompt();
        var sequences = _tokenizer.Encode(prompt);

        using var genParams = new GeneratorParams(_model);
        // Sampling only. Anything touching max_length is off limits here.
        genParams.SetSearchOption("do_sample", true);
        genParams.SetSearchOption("temperature", _temperature);
        genParams.SetSearchOption("top_k", _topK);

        using var generator = new Generator(_model, genParams);

        // Start the clock BEFORE the prompt pass: AppendTokenSequences is the
        // prefill, and time to first token has to include it.
        var ttft = Stopwatch.StartNew();
        generator.AppendTokenSequences(sequences);

        using var stream = _tokenizer.CreateStream();
        var visible = new StringBuilder();

        while (!generator.IsDone())
        {
            ct.ThrowIfCancellationRequested();

            if (_streamedTokens >= _maxOutputTokens)
            {
                LastFinishReason = "length";
                break;
            }

            generator.GenerateNextToken();
            LastFirstTokenSeconds ??= ttft.Elapsed.TotalSeconds;
            _streamedTokens++;

            string piece = stream.Decode(generator.GetSequence(0)[^1]);
            if (string.IsNullOrEmpty(piece)) continue;

            string shown = _thinking.Visible(piece);
            if (shown.Length == 0) continue;

            visible.Append(shown);
            yield return shown;
        }

        string tail = _thinking.Flush();
        if (tail.Length > 0)
        {
            visible.Append(tail);
            yield return tail;
        }

        LastFinishReason ??= "stop";
        _history.Add(("assistant", visible.ToString()));
        await Task.CompletedTask;
    }

    /// <summary>
    /// Render the conversation with the model's own chat template where it has
    /// one. This bundle ships no <c>chat_template</c> in genai_config.json, so
    /// the Phi-style fallback below is what actually runs for it.
    /// </summary>
    private string BuildPrompt()
    {
        string messages = JsonSerializer.Serialize(
            _history.Select(m => new { role = m.Role, content = m.Content }));

        try
        {
            string templated = _tokenizer!.ApplyChatTemplate(null!, messages, null!, true);
            if (!string.IsNullOrWhiteSpace(templated)) return templated;
        }
        catch (Exception)
        {
            // No template in the config; fall through.
        }

        var sb = new StringBuilder();
        foreach (var (role, content) in _history)
        {
            sb.Append($"<|{role}|>\n{content}<|end|>\n");
        }
        sb.Append("<|assistant|>");
        return sb.ToString();
    }

    public void Reset() => _history.Clear();

    public ValueTask DisposeAsync()
    {
        _tokenizer?.Dispose();
        _model?.Dispose();
        _oga?.Dispose();
        return ValueTask.CompletedTask;
    }
}
