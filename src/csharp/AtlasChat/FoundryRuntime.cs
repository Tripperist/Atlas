using System.Diagnostics;
using System.Runtime.CompilerServices;
using Microsoft.AI.Foundry.Local;
using Microsoft.Extensions.Logging;

namespace AtlasChat;

/// <summary>
/// Foundry Local through its in-process SDK, using the Session API introduced
/// in SDK 2.0.1 (Model -> Session -> Request -> Response).
/// </summary>
/// <remarks>
/// Requires <c>Microsoft.AI.Foundry.Local</c> 2.x. The <c>.WinML</c> package was
/// retired in 2.0.1 and is frozen at 1.2.4, which carries an older ONNX Runtime
/// GenAI and behaves erratically; see docs/BENCHMARKS.md.
///
/// The project also needs an explicit <c>win-arm64</c> RuntimeIdentifier, since
/// the package is RID-specific and the build fails without one.
/// </remarks>
internal sealed class FoundryRuntime : IChatRuntime
{
    private readonly ILoggerFactory _loggerFactory;
    private readonly int _maxOutputTokens;
    private readonly float _temperature;
    private readonly int _topK;
    private IModel? _model;
    private ChatSession? _session;

    public FoundryRuntime(int maxOutputTokens, float temperature, int topK)
    {
        _maxOutputTokens = maxOutputTokens;
        _temperature = temperature;
        _topK = topK;

        // A null ILogger is not tolerated. FoundryLocalException logs through
        // the logger it is handed, so passing null turns any startup failure
        // into an ArgumentNullException raised from inside the exception
        // constructor, which hides the real cause entirely.
        _loggerFactory = LoggerFactory.Create(b => b
            .AddConsole()
            .SetMinimumLevel(Microsoft.Extensions.Logging.LogLevel.Warning));
    }

    public string Name => "foundry";
    public string ModelId { get; private set; } = "(not loaded)";
    public TimeSpan LoadTime { get; private set; }
    public int? LastTokenCount { get; private set; }
    public string? LastFinishReason { get; private set; }

    /// Inference happens in this process, so our own counters are the right ones.
    public int SamplePid => Environment.ProcessId;

    public double? LastFirstTokenSeconds { get; private set; }

    public async Task StartAsync(string modelAlias, CancellationToken ct)
    {
        var logger = _loggerFactory.CreateLogger("atlas-chat");
        await FoundryLocalManager.CreateAsync(new Configuration { AppName = "atlas_chat" }, logger, ct);
        var manager = FoundryLocalManager.Instance;

        // Execution providers are obtained through Windows ML on first use and
        // cached thereafter. 2.x chooses the provider itself; the model variant
        // decides whether that lands on NPU, GPU or CPU.
        await manager.DownloadAndRegisterEpsAsync(null);

        var catalog = await manager.GetCatalogAsync(ct);
        _model = await catalog.GetModelAsync(modelAlias, ct)
                 ?? throw new InvalidOperationException(
                     $"'{modelAlias}' is not in the Foundry catalogue. Try: foundry model list");

        var sw = Stopwatch.StartNew();
        if (!await _model.IsCachedAsync(ct))
        {
            // A carriage-return progress line is unreadable once stdout is
            // redirected, which is how this gets smoke-tested.
            if (Console.IsOutputRedirected)
            {
                Console.WriteLine($"  downloading {modelAlias} ...");
                await _model.DownloadAsync(null, ct);
            }
            else
            {
                await _model.DownloadAsync(
                    p => Console.Write($"\r  downloading {modelAlias} {p:F0}%   "), ct);
                Console.WriteLine();
            }
        }
        await _model.LoadAsync(ct);
        LoadTime = sw.Elapsed;

        ModelId = _model.Id;
        _session = NewSession();
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string userMessage, [EnumeratorCancellation] CancellationToken ct)
    {
        if (_session is null) throw new InvalidOperationException("StartAsync first.");
        LastTokenCount = null;
        LastFinishReason = null;
        LastFirstTokenSeconds = null;
        var ttft = System.Diagnostics.Stopwatch.StartNew();

        using var request = new Request();
        request.AddItem(MessageItem.User(userMessage), false);

        // StreamingResponse and the Response it yields both wrap native
        // handles. Leaving them to finalizers works -- handle count plateaus
        // rather than climbing -- but releases them non-deterministically.
        await using var streaming = _session.ProcessStreamingRequestAsync(request, ct);
        await foreach (var item in streaming.WithCancellation(ct))
        {
            // TextItem.Text is the payload. ToString() returns the type name,
            // so the stream reads as "Microsoft.AI.Foundry.Local.TextItem" per
            // chunk -- the failure looks like garbled output, not an error.
            string? text = item switch
            {
                TextItem t => t.Text,
                // Guard before GetSimpleText: a multi-part message is not
                // simple text, and asking for it anyway is undefined.
                MessageItem m when m.IsSimpleText() => m.GetSimpleText(),
                _ => null,
            };
            if (string.IsNullOrEmpty(text)) continue;
            LastFirstTokenSeconds ??= ttft.Elapsed.TotalSeconds;
            yield return text;
        }

        try
        {
            using var final = await streaming.FinalResponse;
            LastFinishReason = final.FinishReason.ToString().ToLowerInvariant();
        }
        catch
        {
            // Best effort; the stats line simply omits it.
        }

        // LastTokenCount is deliberately left null for this backend. Response.GetUsage()
        // .CompletionTokens does not correspond to the streamed reply here --
        // it reported 48 tokens for "Your name is Mike." and 34 for a longer
        // one, so it is neither per-turn nor cumulative in any usable way.
        // The caller counts streamed chunks instead, which is what the
        // benchmark harnesses in this repo do.
    }

    public void Reset()
    {
        // ChatSession owns the history, so a fresh session is the reset.
        _session?.Dispose();
        _session = NewSession();
    }

    /// <summary>
    /// A session carrying the generation options. Without these the backend
    /// decodes greedily and without a cap, which on a small model produces a
    /// single sentence repeated until the context window fills.
    /// </summary>
    private ChatSession NewSession()
    {
        var session = new ChatSession(_model!);
        session.SetStreaming(true);
        session.SetOptions(new RequestOptions
        {
            Search = new SearchOptions
            {
                MaxOutputTokens = _maxOutputTokens,
                DoSample = true,          // greedy decoding is what loops
                Temperature = _temperature,
                TopP = 0.9f,
                TopK = _topK,
            },
        });
        return session;
    }

    public async ValueTask DisposeAsync()
    {
        _session?.Dispose();
        if (_model is not null)
        {
            // Unloading before the session is released fails with
            // "1 session(s) still using it".
            try { await _model.UnloadAsync(); } catch { /* best effort */ }
        }
        _loggerFactory.Dispose();
    }
}
