using System.Diagnostics;
using System.Runtime.Versioning;

namespace AtlasChat;

/// <summary>
/// Samples Windows' <c>GPU Engine</c> counters for THIS process while a turn runs,
/// so the stats line can say where the work actually went.
/// </summary>
/// <remarks>
/// Three things make this harder than it looks, each of which cost a wrong
/// reading somewhere in this repository:
///
/// 1. Instances are per-process and only exist once that process touches the
///    hardware, so the instance list has to be re-enumerated on every sample
///    rather than captured once at startup.
/// 2. The engine type in the instance name is <c>engtype_Compute</c>, capital C.
///    PowerShell counter paths are case-insensitive, so the wildcard form works
///    there; .NET string matching is not, and a lower-case filter silently
///    matches nothing.
/// 3. <b>A compute engine is not necessarily the NPU.</b> The Adreno exposes
///    <c>engtype_Compute</c> instances too. So this reports engine types rather
///    than claiming "NPU", and attributes them to this process by PID, which an
///    out-of-process sampler cannot do.
///
/// Utilization is a rate counter: the first read of a given counter returns 0,
/// so counters are cached across samples rather than recreated.
/// </remarks>
[SupportedOSPlatform("windows")]
internal sealed class EngineSampler : IDisposable
{
    private const string Category = "GPU Engine";
    private const string Counter = "Utilization Percentage";

    private readonly Dictionary<string, PerformanceCounter> _counters = new();
    private readonly Dictionary<string, double> _peak = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _pidPrefix = $"pid_{Environment.ProcessId}_";
    private readonly int _intervalMs;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public EngineSampler(int intervalMs = 200) => _intervalMs = intervalMs;

    /// <summary>True when the counter category is unavailable, so callers can degrade quietly.</summary>
    public bool Unavailable { get; private set; }

    public void Start()
    {
        _peak.Clear();
        _cts = new CancellationTokenSource();
        _loop = Task.Run(() => Loop(_cts.Token));
    }

    /// <summary>Peak utilization per engine type for this process, e.g. {"Compute", 98.9}.</summary>
    public IReadOnlyDictionary<string, double> Stop()
    {
        _cts?.Cancel();
        try { _loop?.Wait(TimeSpan.FromSeconds(2)); } catch { /* best effort */ }
        _cts?.Dispose();
        _cts = null;
        return new Dictionary<string, double>(_peak, StringComparer.OrdinalIgnoreCase);
    }

    private void Loop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                Sample();
            }
            catch (Exception)
            {
                // The category can be missing or momentarily unreadable. A stats
                // line is never worth failing a chat turn over.
                Unavailable = true;
                return;
            }

            try { Task.Delay(_intervalMs, ct).Wait(ct); }
            catch (OperationCanceledException) { return; }
        }
    }

    private void Sample()
    {
        var category = new PerformanceCounterCategory(Category);

        // Re-enumerated every pass: our instances do not exist until the model
        // actually touches the hardware, which happens after the first token.
        foreach (string instance in category.GetInstanceNames())
        {
            if (!instance.StartsWith(_pidPrefix, StringComparison.OrdinalIgnoreCase)) continue;

            if (!_counters.TryGetValue(instance, out var counter))
            {
                counter = new PerformanceCounter(Category, Counter, instance, readOnly: true);
                _counters[instance] = counter;
                counter.NextValue();   // prime; a rate counter's first read is 0
                continue;
            }

            float value;
            try { value = counter.NextValue(); }
            catch (InvalidOperationException)
            {
                // The instance went away mid-run.
                _counters.Remove(instance);
                counter.Dispose();
                continue;
            }

            string engine = EngineTypeOf(instance);
            // The driver can report over 100 % for an adapter aggregating
            // sub-engines; clamp so the figure stays interpretable.
            double clamped = Math.Min(value, 100.0);
            if (!_peak.TryGetValue(engine, out double best) || clamped > best)
            {
                _peak[engine] = clamped;
            }
        }
    }

    private static string EngineTypeOf(string instance)
    {
        const string marker = "engtype_";
        int i = instance.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        return i < 0 ? "unknown" : instance[(i + marker.Length)..];
    }

    public void Dispose()
    {
        Stop();
        foreach (var c in _counters.Values) c.Dispose();
        _counters.Clear();
    }
}
