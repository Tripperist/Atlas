namespace AtlasChat;

/// <summary>
/// One local inference backend, driven as a multi-turn chat.
/// </summary>
/// <remarks>
/// Conversation history belongs to the implementation, not to the caller.
/// Each backend has its own native mechanism and they do not compose: Foundry
/// Local's ChatSession keeps turns internally, GenieX's OpenAI endpoint wants
/// the whole message array on every request, and ONNX Runtime GenAI wants an
/// accumulated token sequence. Handing a shared history down would double it
/// on the first of those.
/// </remarks>
internal interface IChatRuntime : IAsyncDisposable
{
    /// <summary>Short name for the stats line, e.g. "foundry".</summary>
    string Name { get; }

    /// <summary>The variant actually resolved, once <see cref="StartAsync"/> has run.</summary>
    string ModelId { get; }

    /// <summary>How long loading the model took. Part of the comparison.</summary>
    TimeSpan LoadTime { get; }

    Task StartAsync(string modelAlias, CancellationToken ct);

    /// <summary>Stream one assistant turn, yielding text as it arrives.</summary>
    IAsyncEnumerable<string> StreamAsync(string userMessage, CancellationToken ct);

    /// <summary>
    /// Token count for the turn just streamed, if the backend reports one.
    /// Null means fall back to counting streamed chunks, which is an estimate.
    /// </summary>
    int? LastTokenCount { get; }

    /// <summary>
    /// Why the last turn ended -- "stop", "length", "toolCalls". Distinguishing
    /// a natural stop from hitting the cap is the difference between a finished
    /// answer and a truncated one, so it belongs on the stats line.
    /// </summary>
    string? LastFinishReason { get; }

    /// <summary>
    /// Seconds to the first token of the last turn, measured by the backend.
    /// The caller cannot derive this reliably: a backend may suppress leading
    /// output (a reasoning model's &lt;think&gt; block), so the first token the
    /// caller *sees* can be far later than the first the model produced.
    /// Counting those hidden tokens against the visible window inflates the
    /// rate wildly.
    /// </summary>
    double? LastFirstTokenSeconds { get; }

    /// <summary>
    /// The process that actually runs inference, for utilization sampling.
    /// In-process backends return our own PID; a server-backed one returns the
    /// server's, since the counters are per-process.
    /// </summary>
    int SamplePid { get; }

    /// <summary>Forget the conversation so far.</summary>
    void Reset();
}
