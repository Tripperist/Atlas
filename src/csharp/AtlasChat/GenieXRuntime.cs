using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace AtlasChat;

/// <summary>
/// GenieX through its OpenAI-compatible server (<c>geniex serve</c>).
/// </summary>
/// <remarks>
/// Unlike the Foundry backend this is out of process, which has three
/// consequences the harness has to handle rather than hide:
///
/// * The server must already be running. <c>geniex serve</c> takes no model
///   argument and no <c>--port</c>; the address is set with <c>--host</c> and
///   defaults to 127.0.0.1:18181.
/// * Conversation history lives here, because the endpoint is stateless and
///   wants the whole message array on every request.
/// * Utilization counters belong to the server process, so
///   <see cref="SamplePid"/> points at it rather than at us.
///
/// The endpoint populates neither <c>usage</c> nor <c>timings</c> — both come
/// back zeroed — so token counts are the streamed chunks, counted here.
/// </remarks>
internal sealed class GenieXRuntime : IChatRuntime
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(10) };
    private readonly List<(string Role, string Content)> _history = new();
    private readonly string _baseUrl;
    private readonly int _maxOutputTokens;
    private readonly float _temperature;
    private readonly bool _showThinking;
    private int _streamedTokens;

    public GenieXRuntime(string host, int maxOutputTokens, float temperature, bool showThinking)
    {
        _baseUrl = $"http://{host}/v1";
        _maxOutputTokens = maxOutputTokens;
        _temperature = temperature;
        _showThinking = showThinking;
    }

    public string Name => "geniex";
    public string ModelId { get; private set; } = "(not loaded)";
    public TimeSpan LoadTime { get; private set; }
    public int? LastTokenCount => _streamedTokens > 0 ? _streamedTokens : null;
    public string? LastFinishReason { get; private set; }
    public int SamplePid { get; private set; } = Environment.ProcessId;
    public double? LastFirstTokenSeconds { get; private set; }

    public async Task StartAsync(string modelAlias, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();

        // Fail with the fix rather than a connection-refused stack trace: the
        // server is a separate thing the user has to have started.
        List<string> available;
        try
        {
            using var doc = JsonDocument.Parse(await _http.GetStringAsync($"{_baseUrl}/models", ct));
            available = doc.RootElement.GetProperty("data").EnumerateArray()
                .Select(m => m.GetProperty("id").GetString() ?? "")
                .Where(s => s.Length > 0).ToList();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"no GenieX server at {_baseUrl} ({ex.Message.Split('\n')[0]}). Start one with: geniex serve");
        }

        ModelId = available.FirstOrDefault(m => m.Equals(modelAlias, StringComparison.OrdinalIgnoreCase))
                  ?? available.FirstOrDefault(m => m.StartsWith(modelAlias, StringComparison.OrdinalIgnoreCase))
                  ?? throw new InvalidOperationException(
                      $"'{modelAlias}' is not cached. Available:{Environment.NewLine}  " +
                      string.Join($"{Environment.NewLine}  ", available));

        // Counters are per-process, so sample the server, not ourselves.
        var server = Process.GetProcesses().FirstOrDefault(p => p.ProcessName.StartsWith("geniex", StringComparison.OrdinalIgnoreCase));
        if (server is not null) SamplePid = server.Id;

        // The server loads lazily on first use, so the real cost lands on the
        // first turn rather than here.
        LoadTime = sw.Elapsed;
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string userMessage, [EnumeratorCancellation] CancellationToken ct)
    {
        LastFinishReason = null;
        _streamedTokens = 0;
        LastFirstTokenSeconds = null;
        var ttft = Stopwatch.StartNew();
        _history.Add(("user", userMessage));

        var payload = new
        {
            model = ModelId,
            messages = _history.Select(m => new { role = m.Role, content = m.Content }).ToArray(),
            max_tokens = _maxOutputTokens,
            temperature = _temperature,
            stream = true,
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl}/chat/completions")
        {
            Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json"),
        };

        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);

        // Only the visible reply goes back into history. Feeding a model its
        // own <think> block on the next turn degrades it -- it stopped
        // recalling facts stated one turn earlier.
        var visible = new StringBuilder();
        bool inThinking = false;
        bool yieldedAny = false;

        while (!reader.EndOfStream)
        {
            ct.ThrowIfCancellationRequested();
            string? line = await reader.ReadLineAsync(ct);
            if (string.IsNullOrWhiteSpace(line)) continue;
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;

            string data = line["data:".Length..].Trim();
            if (data == "[DONE]") break;

            string? piece;
            try
            {
                using var doc = JsonDocument.Parse(data);
                var choice = doc.RootElement.GetProperty("choices")[0];
                if (choice.TryGetProperty("finish_reason", out var fr) &&
                    fr.ValueKind == JsonValueKind.String)
                {
                    LastFinishReason = fr.GetString();
                }
                piece = choice.TryGetProperty("delta", out var delta) &&
                        delta.TryGetProperty("content", out var c)
                    ? c.GetString()
                    : null;
            }
            catch (JsonException)
            {
                continue;   // a partial frame; the next line completes it
            }

            if (string.IsNullOrEmpty(piece)) continue;

            // Every chunk is generation work, so all of them count toward the
            // rate even when the text is hidden below -- and the clock starts
            // at the first one, not the first visible one.
            LastFirstTokenSeconds ??= ttft.Elapsed.TotalSeconds;
            _streamedTokens++;

            // Qwen3 and the reasoning Phi builds emit <think> blocks, and the
            // server has no equivalent of the CLI's --think=false. The markers
            // arrive as whole chunks, so a flag is enough.
            if (!_showThinking)
            {
                if (piece.Contains("<think>", StringComparison.Ordinal)) { inThinking = true; continue; }
                if (piece.Contains("</think>", StringComparison.Ordinal)) { inThinking = false; continue; }
                if (inThinking) continue;
            }

            // A reasoning model leaves blank lines where its think block was.
            if (!yieldedAny)
            {
                piece = piece.TrimStart();
                if (piece.Length == 0) continue;
                yieldedAny = true;
            }

            visible.Append(piece);
            yield return piece;
        }

        _history.Add(("assistant", visible.ToString()));
    }

    public void Reset() => _history.Clear();

    public ValueTask DisposeAsync()
    {
        _http.Dispose();
        return ValueTask.CompletedTask;
    }
}
