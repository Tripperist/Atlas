using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Planner
{
    class Program
    {
        static void Main(string[] args)
        {
            string filePath = null;
            string format = "text";

            int i = 0;
            while (i < args.Length)
            {
                if (args[i] == "--format")
                {
                    if (i + 1 >= args.Length)
                    {
                        Console.Error.WriteLine("usage: planner <file> [--format text|json]");
                        Environment.Exit(1);
                    }
                    format = args[i + 1];
                    i += 2;
                }
                else if (filePath == null)
                {
                    filePath = args[i];
                    i++;
                }
                else
                {
                    Console.Error.WriteLine("usage: planner <file> [--format text|json]");
                    Environment.Exit(1);
                }
            }

            if (filePath == null)
            {
                Console.Error.WriteLine("usage: planner <file> [--format text|json]");
                Environment.Exit(1);
            }

            if (format != "text" && format != "json")
            {
                Console.Error.WriteLine("usage: planner <file> [--format text|json]");
                Environment.Exit(1);
            }

            List<string> lines;
            try
            {
                lines = File.ReadAllLines(filePath).ToList();
            }
            catch (Exception)
            {
                Console.Error.WriteLine($"error: cannot read file: {filePath}");
                Environment.Exit(2);
            }

            var tasks = new Dictionary<string, Task>();
            var taskLines = new Dictionary<string, int>();
            var lineNumbers = new Dictionary<string, int>();
            var lineErrors = new Dictionary<int, string>();
            int lineNumber = 0;

            for (int lineIndex = 0; lineIndex < lines.Count; lineIndex++)
            {
                string line = lines[lineIndex];
                lineNumber++;
                line = line.Trim();
                if (string.IsNullOrEmpty(line) || line.StartsWith("#"))
                    continue;

                var match = Regex.Match(line, @"^([a-zA-Z0-9_.\-]+)(?:\s*:\s*(.*?))?(?:\s*\[(\d+)\])?$");
                if (!match.Success)
                {
                    lineErrors[lineNumber] = "invalid syntax";
                    continue;
                }

                string name = match.Groups[1].Value;
                string depsStr = match.Groups[2].Value;
                string durationStr = match.Groups[3].Value;

                if (tasks.ContainsKey(name))
                {
                    lineErrors[lineNumber] = "duplicate task definition";
                    continue;
                }

                int duration = 1;
                if (!string.IsNullOrEmpty(durationStr))
                {
                    if (!int.TryParse(durationStr, out duration) || duration <= 0 || duration > 1000000)
                    {
                        lineErrors[lineNumber] = "invalid duration";
                        continue;
                    }
                }

                var deps = new HashSet<string>();
                if (!string.IsNullOrEmpty(depsStr))
                {
                    var depMatches = Regex.Matches(depsStr, @"[^,]+");
                    foreach (Match depMatch in depMatches)
                    {
                        string dep = depMatch.Value.Trim();
                        if (string.IsNullOrEmpty(dep))
                        {
                            lineErrors[lineNumber] = "empty dependency";
                            break;
                        }
                        deps.Add(dep);
                    }
                }

                if (lineErrors.ContainsKey(lineNumber))
                    continue;

                tasks[name] = new Task { Name = name, Dependencies = deps.ToList(), Duration = duration };
                taskLines[name] = lineNumber;
                lineNumbers[name] = lineNumber;
            }

            if (lineErrors.Count > 0)
            {
                int firstErrorLine = lineErrors.Keys.Min();
                Console.Error.WriteLine($"error: line {firstErrorLine}: {lineErrors[firstErrorLine]}");
                Environment.Exit(3);
            }

            // Check for unknown dependencies
            foreach (var task in tasks.Values)
            {
                foreach (string dep in task.Dependencies)
                {
                    if (!tasks.ContainsKey(dep))
                    {
                        Console.Error.WriteLine($"error: task '{task.Name}' depends on unknown task '{dep}'");
                        Environment.Exit(4);
                    }
                }
            }

            // Detect cycles
            var visited = new HashSet<string>();
            var visiting = new HashSet<string>();
            var cyclePath = new List<string>();

            foreach (string taskName in tasks.Keys)
            {
                if (!visited.Contains(taskName))
                {
                    if (HasCycle(taskName, tasks, visited, visiting, cyclePath))
                    {
                        Console.Error.WriteLine("error: dependency cycle");
                        Environment.Exit(5);
                    }
                }
            }

            // Build dependency graph
            var graph = new Dictionary<string, List<string>>();
            foreach (var task in tasks.Values)
            {
                graph[task.Name] = new List<string>();
                foreach (string dep in task.Dependencies)
                {
                    graph[task.Name].Add(dep);
                }
            }

            // Topological sort to determine stages
            var stages = new List<List<string>>();
            var taskToStage = new Dictionary<string, int>();
            var inDegree = new Dictionary<string, int>();

            foreach (var task in tasks.Values)
            {
                inDegree[task.Name] = task.Dependencies.Count;
            }

            var queue = new Queue<string>();
            foreach (var task in tasks.Values)
            {
                if (inDegree[task.Name] == 0)
                {
                    queue.Enqueue(task.Name);
                }
            }

            int stage = 1;
            while (queue.Count > 0)
            {
                var currentStage = new List<string>();
                int count = queue.Count;
                for (int j = 0; j < count; j++)
                {
                    string taskName = queue.Dequeue();
                    currentStage.Add(taskName);
                    taskToStage[taskName] = stage;

                    foreach (string dep in graph[taskName])
                    {
                        inDegree[dep]--;
                        if (inDegree[dep] == 0)
                        {
                            queue.Enqueue(dep);
                        }
                    }
                }
                currentStage.Sort(StringComparer.Ordinal);
                stages.Add(currentStage);
                stage++;
            }

            // Calculate critical path
            var taskDurations = tasks.ToDictionary(t => t.Key, t => t.Value.Duration);
            var taskDependents = new Dictionary<string, List<string>>();
            foreach (var task in tasks.Values)
            {
                foreach (string dep in task.Dependencies)
                {
                    if (!taskDependents.ContainsKey(dep))
                        taskDependents[dep] = new List<string>();
                    taskDependents[dep].Add(task.Name);
                }
            }

            var criticalPath = new List<string>();
            var maxDuration = 0L;
            var taskMaxDuration = new Dictionary<string, long>();
            var taskPredecessors = new Dictionary<string, List<string>>();

            foreach (string taskName in tasks.Keys)
            {
                taskMaxDuration[taskName] = 0;
                taskPredecessors[taskName] = new List<string>();
            }

            foreach (var stageTasks in stages)
            {
                foreach (string taskName in stageTasks)
                {
                    long currentDuration = taskDurations[taskName];
                    long maxPredecessorDuration = 0;
                    List<string> predecessors = new List<string>();

                    foreach (string dep in tasks[taskName].Dependencies)
                    {
                        if (taskMaxDuration[dep] > maxPredecessorDuration)
                        {
                            maxPredecessorDuration = taskMaxDuration[dep];
                            predecessors = new List<string>(taskPredecessors[dep]);
                        }
                        else if (taskMaxDuration[dep] == maxPredecessorDuration)
                        {
                            var pred = taskPredecessors[dep];
                            if (pred.Count > 0 && string.Compare(pred[0], predecessors[0], StringComparison.Ordinal) < 0)
                            {
                                predecessors = new List<string>(pred);
                            }
                        }
                    }

                    long totalDuration = maxPredecessorDuration + currentDuration;
                    taskMaxDuration[taskName] = totalDuration;
                    if (totalDuration > maxDuration)
                    {
                        maxDuration = totalDuration;
                        criticalPath = new List<string>(predecessors);
                        criticalPath.Add(taskName);
                    }
                    else if (totalDuration == maxDuration)
                    {
                        // Check if this path is lexicographically smaller
                        var currentPath = new List<string>(predecessors);
                        currentPath.Add(taskName);
                        if (IsLexicographicallySmaller(currentPath, criticalPath))
                        {
                            criticalPath = currentPath;
                        }
                    }
                }
            }

            // Output
            if (format == "text")
            {
                if (stages.Count == 0)
                {
                    Console.WriteLine("Total tasks: 0");
                }
                else
                {
                    for (int s = 0; s < stages.Count; s++)
                    {
                        Console.WriteLine($"Stage {s + 1}: {string.Join(", ", stages[s])}");
                    }
                    Console.WriteLine($"Total tasks: {tasks.Count}");
                    if (criticalPath.Count > 0)
                    {
                        Console.WriteLine($"Critical path ({maxDuration}): {string.Join(" -> ", criticalPath)}");
                    }
                }
            }
            else // JSON
            {
                var sb = new StringBuilder();
                sb.Append("{");
                sb.Append("\"stages\":[");
                for (int s = 0; s < stages.Count; s++)
                {
                    if (s > 0) sb.Append(",");
                    sb.Append("[");
                    for (int t = 0; t < stages[s].Count; t++)
                    {
                        if (t > 0) sb.Append(",");
                        sb.Append("\"").Append(stages[s][t]).Append("\"");
                    }
                    sb.Append("]");
                }
                sb.Append("],");
                sb.Append("\"totalTasks\":").Append(tasks.Count).Append(",");
                sb.Append("\"criticalPath\":{");
                sb.Append("\"duration\":").Append(maxDuration).Append(",");
                sb.Append("\"tasks\":[");
                for (int t = 0; t < criticalPath.Count; t++)
                {
                    if (t > 0) sb.Append(",");
                    sb.Append("\"").Append(criticalPath[t]).Append("\"");
                }
                sb.Append("]}");
                sb.Append("}");
                Console.WriteLine(sb.ToString());
            }
        }

        static bool HasCycle(string taskName, Dictionary<string, Task> tasks, HashSet<string> visited, HashSet<string> visiting, List<string> path)
        {
            if (visiting.Contains(taskName))
            {
                return true;
            }

            if (visited.Contains(taskName))
            {
                return false;
            }

            visiting.Add(taskName);
            path.Add(taskName);

            foreach (string dep in tasks[taskName].Dependencies)
            {
                if (HasCycle(dep, tasks, visited, visiting, path))
                {
                    return true;
                }
            }

            visiting.Remove(taskName);
            visited.Add(taskName);
            path.RemoveAt(path.Count - 1);
            return false;
        }

        static bool IsLexicographicallySmaller(List<string> a, List<string> b)
        {
            if (b.Count == 0) return false;
            if (a.Count == 0) return true;

            int minLen = Math.Min(a.Count, b.Count);
            for (int i = 0; i < minLen; i++)
            {
                int cmp = string.Compare(a[i], b[i], StringComparison.Ordinal);
                if (cmp < 0) return true;
                if (cmp > 0) return false;
            }

            return a.Count < b.Count;
        }
    }

    class Task
    {
        public string Name { get; set; }
        public List<string> Dependencies { get; set; }
        public int Duration { get; set; }
    }
}
