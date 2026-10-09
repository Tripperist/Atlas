using System.Text;

namespace AtlasChat;

/// <summary>
/// Tracks a reasoning model's <c>&lt;think&gt;</c> block, hiding it by default.
/// </summary>
/// <remarks>
/// Qwen3 and the reasoning Phi builds emit their chain of thought inline. The
/// GenieX CLI has <c>--think=false</c>, but neither its HTTP endpoint nor ONNX
/// Runtime GenAI does, so the filtering happens here.
///
/// <b>The markers are not reliably whole pieces.</b> GenieX's SSE stream
/// delivers <c>&lt;think&gt;</c> as a single chunk, but ONNX Runtime GenAI
/// decodes token by token and splits it, so a substring test on each piece
/// misses it entirely. This buffers instead, holding back only as much tail as
/// a marker could still span.
///
/// The scan runs even when reasoning is shown, because <see cref="InThinking"/>
/// has to stay accurate either way — a turn that runs out of budget mid-thought
/// produced no answer, and with reasoning displayed that is otherwise invisible.
///
/// Two further rules:
///
/// * Hidden tokens still count. Generating them is real work, so excluding
///   them from the rate would overstate throughput.
/// * Hidden text must not go back into the conversation. Feeding a model its
///   own think block on the next turn measurably degrades it.
/// </remarks>
internal sealed class ThinkingFilter
{
    private const string Open = "<think>";
    private const string Close = "</think>";

    private readonly bool _showThinking;
    private readonly StringBuilder _pending = new();
    private bool _inThinking;
    private bool _emittedAny;

    public ThinkingFilter(bool showThinking) => _showThinking = showThinking;

    /// <summary>
    /// True when the stream stopped inside a reasoning block — the model never
    /// closed it, so it never produced an answer.
    /// </summary>
    public bool InThinking => _inThinking;

    public void Reset()
    {
        _pending.Clear();
        _inThinking = false;
        _emittedAny = false;
    }

    /// <summary>Text to show for this piece; empty when everything was swallowed.</summary>
    public string Visible(string piece)
    {
        _pending.Append(piece);
        var output = new StringBuilder();

        while (true)
        {
            string buffer = _pending.ToString();

            if (_inThinking)
            {
                int close = buffer.IndexOf(Close, StringComparison.Ordinal);
                if (close < 0)
                {
                    // Still reasoning. Keep just enough to catch a split marker.
                    int safe = Math.Max(0, buffer.Length - (Close.Length - 1));
                    if (_showThinking) output.Append(buffer[..safe]);
                    Keep(buffer, safe);
                    break;
                }
                if (_showThinking) output.Append(buffer[..(close + Close.Length)]);
                Keep(buffer, close + Close.Length);
                _inThinking = false;
                continue;
            }

            int open = buffer.IndexOf(Open, StringComparison.Ordinal);
            if (open >= 0)
            {
                output.Append(buffer[..open]);
                if (_showThinking) output.Append(Open);
                Keep(buffer, open + Open.Length);
                _inThinking = true;
                continue;
            }

            // No marker in view. Emit everything that cannot be the start of
            // one, and hold the rest until more arrives.
            int tail = Math.Max(0, buffer.Length - (Open.Length - 1));
            output.Append(buffer[..tail]);
            Keep(buffer, tail);
            break;
        }

        return Trim(output.ToString());
    }

    /// <summary>Release anything still held back at the end of a turn.</summary>
    public string Flush()
    {
        string rest = _pending.ToString();
        _pending.Clear();
        if (!_showThinking && _inThinking) return string.Empty;
        return Trim(rest);
    }

    private void Keep(string buffer, int from)
    {
        _pending.Clear();
        _pending.Append(buffer[from..]);
    }

    /// <summary>A suppressed block leaves the blank lines that surrounded it.</summary>
    private string Trim(string text)
    {
        if (text.Length == 0) return text;
        if (!_emittedAny)
        {
            text = text.TrimStart();
            if (text.Length == 0) return text;
            _emittedAny = true;
        }
        return text;
    }
}
