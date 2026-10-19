using System.Diagnostics;
using System.Runtime.CompilerServices;
using Betalgo.Ranul.OpenAI.ObjectModels.RequestModels;
using Microsoft.AI.Foundry.Local;
using Microsoft.Extensions.Logging;

namespace AtlasChat;

/// <summary>
/// Foundry Local through the EARLIER in-process chat API of SDK 2.x:
/// <c>model.GetChatClientAsync()</c> and <c>CompleteChatStreamingAsync</c>, with OpenAI-style
/// <see cref="ChatMessage"/> objects. <see cref="FoundryRuntime"/> uses the newer Session API
/// (Model, Session, Request, Response) for the same model; running both is how to tell whether a
/// difference comes from the API or from the model.
/// </summary>
/// <remarks>
/// Written to reproduce microsoft/foundry-local#1207, which reports the Session API as far slower and
/// degenerate (a repeated sentence until the context fills, a cancellation token ignored) against this
/// one, on the same model and prompt.
///
/// The old client is stateless: it takes the whole message list on every call, so this class keeps the
/// history itself. <c>--default-options</c> leaves every setting at the SDK's own default, which is what
/// the issue's code does; without it the generation options are set explicitly, as FoundryRuntime does.
/// </remarks>
internal sealed class FoundryClientRuntime : IChatRuntime
{
    private readonly ILoggerFactory _loggerFactory;
    private readonly int _maxOutputTokens;
    private readonly float _temperature;
    private readonly int _topK;
    private readonly string? _system;
    private readonly bool _defaultOptions;
    private readonly bool _noStream;
    private readonly bool _greedy;
    private readonly List<ChatMessage> _history = new();
    private IModel? _model;
    private OpenAIChatClient? _client;

    public FoundryClientRuntime(int maxOutputTokens, float temperature, int topK, string? system, bool defaultOptions, bool noStream = false, bool greedy = false)
    {
        _maxOutputTokens = maxOutputTokens;
        _temperature = temperature;
        _topK = topK;
        _system = system;
        _defaultOptions = defaultOptions;
        _noStream = noStream;
        _greedy = greedy;
        // See FoundryRuntime: a null logger turns any startup failure into an ArgumentNullException.
        _loggerFactory = LoggerFactory.Create(b => b
            .AddConsole()
            .SetMinimumLevel(Microsoft.Extensions.Logging.LogLevel.Warning));
    }

    public string Name => "foundry-client";
    public string ModelId { get; private set; } = "(not loaded)";
    public TimeSpan LoadTime { get; private set; }
    public int? LastTokenCount { get; private set; }
    public string? LastFinishReason { get; private set; }
    public double? LastFirstTokenSeconds { get; private set; }

    /// Inference happens in this process.
    public int SamplePid => Environment.ProcessId;

    public async Task StartAsync(string modelAlias, CancellationToken ct)
    {
        var logger = _loggerFactory.CreateLogger("atlas-chat");
        await FoundryLocalManager.CreateAsync(new Configuration { AppName = "atlas_chat" }, logger, ct);
        var manager = FoundryLocalManager.Instance;
        await manager.DownloadAndRegisterEpsAsync(null);

        var catalog = await manager.GetCatalogAsync(ct);
        _model = await catalog.GetModelAsync(modelAlias, ct)
                 ?? throw new InvalidOperationException(
                     $"'{modelAlias}' is not in the Foundry catalogue. Try: foundry model list");

        var sw = Stopwatch.StartNew();
        if (!await _model.IsCachedAsync(ct))
        {
            Console.WriteLine($"  downloading {modelAlias} ...");
            await _model.DownloadAsync(null, ct);
        }
        await _model.LoadAsync(ct);
        LoadTime = sw.Elapsed;
        ModelId = _model.Id;

        _client = await _model.GetChatClientAsync(ct);
        if (_greedy)
        {
            _client.Settings.Temperature = 0f;   // greedy; MaxTokens left unset
        }
        else if (!_defaultOptions)
        {
            // The same options FoundryRuntime sets on its session, so the two differ only in the API.
            _client.Settings.MaxTokens = _maxOutputTokens;
            _client.Settings.Temperature = _temperature;
            _client.Settings.TopP = 0.9f;
            _client.Settings.TopK = _topK;
        }
        Reset();
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string userMessage, [EnumeratorCancellation] CancellationToken ct)
    {
        if (_client is null) throw new InvalidOperationException("StartAsync first.");
        LastTokenCount = null;
        LastFinishReason = null;
        LastFirstTokenSeconds = null;
        var ttft = Stopwatch.StartNew();

        _history.Add(new ChatMessage("user", userMessage));
        var reply = new System.Text.StringBuilder();
        int chunks = 0;
        try
        {
            if (_noStream)
            {
                // The call the issue's code makes: one request, one reply.
                var response = await _client.CompleteChatAsync(_history, ct);
                var choice0 = response.Choices?.FirstOrDefault();
                if (Environment.GetEnvironmentVariable("ATLAS_DUMP_RESPONSE") == "1")
                {
                    // What the old client returns besides the text, e.g. a separate reasoning field.
                    Console.Error.WriteLine("[response] " + System.Text.Json.JsonSerializer.Serialize(response,
                        new System.Text.Json.JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull }));
                }
                LastFinishReason = choice0?.FinishReason;
                if (response.Usage is { CompletionTokens: > 0 } usage) LastTokenCount = usage.CompletionTokens;
                string? whole = choice0?.Message?.Content;
                LastFirstTokenSeconds = ttft.Elapsed.TotalSeconds;
                if (!string.IsNullOrEmpty(whole)) { reply.Append(whole); yield return whole; }
                yield break;
            }
            await foreach (var chunk in _client.CompleteChatStreamingAsync(_history, ct))
            {
                var choice = chunk.Choices?.FirstOrDefault();
                if (choice?.FinishReason is { Length: > 0 } fr) LastFinishReason = fr;
                if (chunk.Usage is { CompletionTokens: > 0 } u) LastTokenCount = u.CompletionTokens;
                string? text = choice?.Delta?.Content ?? choice?.Message?.Content;
                if (string.IsNullOrEmpty(text)) continue;
                LastFirstTokenSeconds ??= ttft.Elapsed.TotalSeconds;
                chunks++;
                reply.Append(text);
                yield return text;
            }
        }
        finally
        {
            // A turn that was cut short is still part of the conversation; keep what was said.
            _history.Add(new ChatMessage("assistant", reply.ToString()));
        }
    }

    public void Reset()
    {
        // The client is stateless; the history is ours.
        _history.Clear();
        if (!string.IsNullOrEmpty(_system)) _history.Add(new ChatMessage("system", _system));
    }

    public async ValueTask DisposeAsync()
    {
        if (_model is not null)
        {
            try { await _model.UnloadAsync(); } catch { /* best effort */ }
        }
        _loggerFactory.Dispose();
    }
}
