// Reference implementation of prompt.txt, used to validate the test suite.
//
// It is not a model output and is not scored against the models. It exists so
// that every test is known to be passable by a correct program, and it computes
// the critical path differently from oracle.py (a backward longest-path value
// plus a greedy forward walk, instead of comparing path suffixes), so agreement
// between the two means something.
using System.Text;

const string Usage = "usage: planner <file> [--format text|json]";

return Run(args);

static int Fail(int code, string message)
{
    Console.Error.WriteLine(message);
    return code;
}

static bool IsNameChar(char c) => char.IsAsciiLetterOrDigit(c) || c is '_' or '-' or '.';

static bool IsName(string s) => s.Length > 0 && s.All(IsNameChar);

static int Run(string[] args)
{
    string? path = null;
    var json = false;
    for (var i = 0; i < args.Length; i++)
    {
        if (args[i] == "--format")
        {
            if (i + 1 >= args.Length) return Fail(1, Usage);
            var value = args[++i];
            if (value == "json") json = true;
            else if (value != "text") return Fail(1, Usage);
        }
        else if (path is null) path = args[i];
        else return Fail(1, Usage);
    }
    if (path is null) return Fail(1, Usage);

    string text;
    try { text = File.ReadAllText(path); }
    catch (Exception) { return Fail(2, $"error: cannot read file: {path}"); }

    var names = new List<string>();
    var index = new Dictionary<string, int>(StringComparer.Ordinal);
    var depNames = new List<List<string>>();
    var durations = new List<int>();

    var lines = text.Split('\n');
    for (var n = 0; n < lines.Length; n++)
    {
        var line = lines[n].Trim(' ', '\t', '\r');
        if (line.Length == 0 || line[0] == '#') continue;

        string Bad(string reason) => $"error: line {n + 1}: {reason}";

        var duration = 1;
        var head = line;
        if (line[^1] == ']')
        {
            var open = line.LastIndexOf('[');
            if (open < 0) return Fail(3, Bad("unbalanced bracket"));
            var digits = line[(open + 1)..^1].Trim(' ', '\t');
            if (digits.Length == 0 || !digits.All(char.IsAsciiDigit)) return Fail(3, Bad("invalid duration"));
            if (digits.Length > 7 || !int.TryParse(digits, out duration) || duration is < 1 or > 1_000_000)
                return Fail(3, Bad("duration out of range"));
            head = line[..open].Trim(' ', '\t');
        }
        if (head.Contains('[') || head.Contains(']')) return Fail(3, Bad("misplaced bracket"));

        var deps = new List<string>();
        string name;
        var colon = head.IndexOf(':');
        if (colon >= 0)
        {
            name = head[..colon].Trim(' ', '\t');
            foreach (var piece in head[(colon + 1)..].Split(','))
            {
                var dep = piece.Trim(' ', '\t');
                if (!IsName(dep)) return Fail(3, Bad("invalid dependency"));
                if (!deps.Contains(dep)) deps.Add(dep);
            }
        }
        else name = head;
        if (!IsName(name)) return Fail(3, Bad("invalid name"));
        if (index.ContainsKey(name)) return Fail(3, Bad($"duplicate task '{name}'"));

        index[name] = names.Count;
        names.Add(name);
        depNames.Add(deps);
        durations.Add(duration);
    }

    var count = names.Count;
    var succ = new List<int>[count];
    var indegree = new int[count];
    for (var i = 0; i < count; i++) succ[i] = new List<int>();
    for (var i = 0; i < count; i++)
    {
        foreach (var dep in depNames[i])
        {
            if (!index.TryGetValue(dep, out var d))
                return Fail(4, $"error: task '{names[i]}' depends on unknown task '{dep}'");
            succ[d].Add(i);
            indegree[i]++;
        }
    }

    var stages = new List<List<int>>();
    var current = Enumerable.Range(0, count).Where(i => indegree[i] == 0).ToList();
    var placed = 0;
    while (current.Count > 0)
    {
        current.Sort((a, b) => string.CompareOrdinal(names[a], names[b]));
        stages.Add(current);
        placed += current.Count;
        var next = new List<int>();
        foreach (var t in current)
            foreach (var s in succ[t])
                if (--indegree[s] == 0) next.Add(s);
        current = next;
    }
    if (placed < count) return Fail(5, "error: dependency cycle");

    // total[v]: the longest duration of any chain that starts at v.
    var total = new long[count];
    for (var s = stages.Count - 1; s >= 0; s--)
    {
        foreach (var v in stages[s])
        {
            long best = 0;
            foreach (var w in succ[v]) best = Math.Max(best, total[w]);
            total[v] = durations[v] + best;
        }
    }

    var critical = new List<int>();
    long pathTotal = 0;
    if (count > 0)
    {
        var start = -1;
        for (var v = 0; v < count; v++)
        {
            if (start < 0 || total[v] > total[start] ||
                (total[v] == total[start] && string.CompareOrdinal(names[v], names[start]) < 0))
                start = v;
        }
        pathTotal = total[start];
        // Among chains of maximal total, the smallest list of names takes the smallest
        // name that still lies on a maximal chain at every step.
        var cur = start;
        while (true)
        {
            critical.Add(cur);
            var want = total[cur] - durations[cur];
            if (want == 0) break;
            var pick = -1;
            foreach (var w in succ[cur])
                if (total[w] == want && (pick < 0 || string.CompareOrdinal(names[w], names[pick]) < 0)) pick = w;
            cur = pick;
        }
    }

    var sb = new StringBuilder();
    if (json)
    {
        sb.Append("{\"stages\":[");
        for (var s = 0; s < stages.Count; s++)
        {
            if (s > 0) sb.Append(',');
            sb.Append('[').Append(string.Join(',', stages[s].Select(i => $"\"{names[i]}\""))).Append(']');
        }
        sb.Append("],\"totalTasks\":").Append(count);
        sb.Append(",\"criticalPath\":{\"duration\":").Append(pathTotal);
        sb.Append(",\"tasks\":[").Append(string.Join(',', critical.Select(i => $"\"{names[i]}\""))).Append("]}}\n");
    }
    else
    {
        for (var s = 0; s < stages.Count; s++)
            sb.Append("Stage ").Append(s + 1).Append(": ").AppendJoin(", ", stages[s].Select(i => names[i])).Append('\n');
        sb.Append("Total tasks: ").Append(count).Append('\n');
        if (count > 0)
            sb.Append("Critical path (").Append(pathTotal).Append("): ").AppendJoin(" -> ", critical.Select(i => names[i])).Append('\n');
    }

    using var stdout = Console.OpenStandardOutput();
    stdout.Write(new UTF8Encoding(false).GetBytes(sb.ToString()));
    return 0;
}
