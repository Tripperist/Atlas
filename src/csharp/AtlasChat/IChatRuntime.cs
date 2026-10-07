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

    /// <summary>Forget the conversation so far.</summary>
    void Reset();
}
