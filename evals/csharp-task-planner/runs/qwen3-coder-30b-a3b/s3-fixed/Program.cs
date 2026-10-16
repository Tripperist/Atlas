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

            // Parse command line arguments
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--format")
                {
                    if (i + 1 >= args.Length || (args[i + 1] != "text" && args[i + 1] != "json"))
                    {
                        Console.Error.WriteLine("usage: planner <file> [--format text|json]");
                        Environment.Exit(1);
                    }
                    format = args[i + 1];
                    i++;
                }
                else if (filePath == null)
                {
                    filePath = args[i];
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

            // Read file
            string[] lines = Array.Empty<string>();
            try
            {
                lines = File.ReadAllLines(filePath);
            }
            catch (Exception)
            {
                Console.Error.WriteLine($"error: cannot read file: {filePath}");
                Environment.Exit(2);
            }

            // Parse tasks
            var tasks = new Dictionary<string, Task>();
            var taskLines = new Dictionary<string, int>();
            var lineNumbers = new List<int>();
            var lineContents = new List<string>();

            for (int i = 0; i < lines.Length; i++)
            {
                var line = lines[i];
                var trimmed = line.Trim();
                if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith('#'))
                {
                    continue;
                }

                lineNumbers.Add(i + 1);
                lineContents.Add(line);

                var match = Regex.Match(trimmed, @"^([a-zA-Z0-9_.\-]+)(?:\s*:\s*(.*?))?(?:\s*\[(\d+)\])?$");
                if (!match.Success)
                {
                    Console.Error.WriteLine($"error: line {i + 1}: invalid syntax");
                    Environment.Exit(3);
                }

                var name = match.Groups[1].Value;
                var deps = new HashSet<string>();
                var duration = 1;

                if (match.Groups[2].Success)
                {
                    var depStr = match.Groups[2].Value;
                    if (string.IsNullOrEmpty(depStr))
                    {
                        Console.Error.WriteLine($"error: line {i + 1}: empty dependency");
                        Environment.Exit(3);
                    }

                    var parts = depStr.Split(',');
                    foreach (var part in parts)
                    {
                        var dep = part.Trim();
                        if (string.IsNullOrEmpty(dep))
                        {
                            Console.Error.WriteLine($"error: line {i + 1}: empty dependency");
                            Environment.Exit(3);
                        }
                        deps.Add(dep);
                    }
                }

                if (match.Groups[3].Success)
                {
                    if (!int.TryParse(match.Groups[3].Value, out duration) || duration <= 0 || duration > 1000000)
                    {
                        Console.Error.WriteLine($"error: line {i + 1}: invalid duration");
                        Environment.Exit(3);
                    }
                }

                if (tasks.ContainsKey(name))
                {
                    Console.Error.WriteLine($"error: line {i + 1}: duplicate task definition");
                    Environment.Exit(3);
                }

                tasks[name] = new Task(name, deps, duration);
                taskLines[name] = i + 1;
            }

            // Check for unknown dependencies
            foreach (var task in tasks.Values)
            {
                foreach (var dep in task.Dependencies)
                {
                    if (!tasks.ContainsKey(dep))
                    {
                        Console.Error.WriteLine($"error: task '{task.Name}' depends on unknown task '{dep}'");
                        Environment.Exit(4);
                    }
                }
            }

            // Check for cycles
            var visited = new HashSet<string>();
            var visiting = new HashSet<string>();
            var cycle = new List<string>();

            foreach (var task in tasks.Values)
            {
                if (!visited.Contains(task.Name))
                {
                    if (HasCycle(task.Name, tasks, visited, visiting, cycle))
                    {
                        Console.Error.WriteLine("error: dependency cycle");
                        Environment.Exit(5);
                    }
                }
            }

            // Calculate stages
            var stages = new List<List<string>>();
            var taskToStage = new Dictionary<string, int>();
            var readyTasks = new Queue<string>();
            var taskDurations = new Dictionary<string, int>();

            foreach (var task in tasks.Values)
            {
                taskDurations[task.Name] = task.Duration;
            }

            // Initialize ready tasks
            foreach (var task in tasks.Values)
            {
                if (task.Dependencies.Count == 0)
                {
                    readyTasks.Enqueue(task.Name);
                    taskToStage[task.Name] = 1;
                }
            }

            int currentStage = 1;
            var stageTasks = new List<string>();

            while (readyTasks.Count > 0)
            {
                stageTasks.Clear();
                int count = readyTasks.Count;
                for (int i = 0; i < count; i++)
                {
                    var taskName = readyTasks.Dequeue();
                    stageTasks.Add(taskName);
                }

                stageTasks.Sort(StringComparer.Ordinal);
                stages.Add(stageTasks.ToList());

                // Update dependencies for next stage
                var nextReady = new HashSet<string>();
                foreach (var taskName in stageTasks)
                {
                    foreach (var otherTask in tasks.Values)
                    {
                        if (otherTask.Dependencies.Contains(taskName))
                        {
                            otherTask.Dependencies.Remove(taskName);
                            if (otherTask.Dependencies.Count == 0)
                            {
                                nextReady.Add(otherTask.Name);
                            }
                        }
                    }
                }

                foreach (var taskName in nextReady)
                {
                    readyTasks.Enqueue(taskName);
                    taskToStage[taskName] = currentStage + 1;
                }

                currentStage++;
            }

            // Calculate critical path
            var criticalPath = new List<string>();
            var criticalPathDuration = 0;

            if (tasks.Count > 0)
            {
                // Build dependency graph
                var graph = new Dictionary<string, List<string>>();
                var inDegree = new Dictionary<string, int>();
                foreach (var task in tasks.Values)
                {
                    graph[task.Name] = new List<string>();
                    inDegree[task.Name] = task.Dependencies.Count;
                }

                foreach (var task in tasks.Values)
                {
                    foreach (var dep in task.Dependencies)
                    {
                        graph[dep].Add(task.Name);
                    }
                }

                // Topological sort with critical path calculation
                var queue = new Queue<string>();
                var maxDuration = new Dictionary<string, int>();
                var predecessor = new Dictionary<string, string>();

                foreach (var task in tasks.Values)
                {
                    if (inDegree[task.Name] == 0)
                    {
                        queue.Enqueue(task.Name);
                        maxDuration[task.Name] = task.Duration;
                    }
                }

                var allTasks = new List<string>();
                while (queue.Count > 0)
                {
                    var current = queue.Dequeue();
                    allTasks.Add(current);

                    foreach (var neighbor in graph[current])
                    {
                        inDegree[neighbor]--;
                        if (inDegree[neighbor] == 0)
                        {
                            queue.Enqueue(neighbor);
                        }

                        // Update max duration
                        int newDuration = maxDuration[current] + tasks[neighbor].Duration;
                        if (!maxDuration.ContainsKey(neighbor) || newDuration > maxDuration[neighbor])
                        {
                            maxDuration[neighbor] = newDuration;
                            predecessor[neighbor] = current;
                        }
                    }
                }

                // Find critical path
                var maxTotal = 0;
                string endTask = null;
                foreach (var task in tasks.Values)
                {
                    if (maxDuration.ContainsKey(task.Name) && maxDuration[task.Name] > maxTotal)
                    {
                        maxTotal = maxDuration[task.Name];
                        endTask = task.Name;
                    }
                }

                if (endTask != null)
                {
                    criticalPathDuration = maxTotal;
                    var path = new List<string>();
                    var current = endTask;
                    while (current != null)
                    {
                        path.Add(current);
                        current = predecessor.ContainsKey(current) ? predecessor[current] : null;
                    }
                    path.Reverse();
                    criticalPath = path;
                }
            }

            // Output
            if (format == "json")
            {
                var stagesJson = new List<object>();
                foreach (var stage in stages)
                {
                    stagesJson.Add(stage.ToArray());
                }

                var criticalPathJson = new
                {
                    duration = criticalPathDuration,
                    tasks = criticalPath.ToArray()
                };

                var result = new
                {
                    stages = stagesJson.ToArray(),
                    totalTasks = tasks.Count,
                    criticalPath = criticalPathJson
                };

                Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(result));
            }
            else
            {
                if (tasks.Count == 0)
                {
                    Console.WriteLine("Total tasks: 0");
                }
                else
                {
                    foreach (var stage in stages)
                    {
                        if (stage.Count > 0)
                        {
                            Console.WriteLine($"Stage {stages.IndexOf(stage) + 1}: {string.Join(", ", stage)}");
                        }
                    }

                    Console.WriteLine($"Total tasks: {tasks.Count}");

                    if (criticalPath.Count > 0)
                    {
                        Console.WriteLine($"Critical path ({criticalPathDuration}): {string.Join(" -> ", criticalPath)}");
                    }
                }
            }
        }

        static bool HasCycle(string taskName, Dictionary<string, Task> tasks, HashSet<string> visited, HashSet<string> visiting, List<string> cycle)
        {
            if (visiting.Contains(taskName))
            {
                cycle.Add(taskName);
                return true;
            }

            if (visited.Contains(taskName))
            {
                return false;
            }

            visiting.Add(taskName);
            cycle.Add(taskName);

            var task = tasks[taskName];
            foreach (var dep in task.Dependencies)
            {
                if (HasCycle(dep, tasks, visited, visiting, cycle))
                {
                    return true;
                }
            }

            visiting.Remove(taskName);
            visited.Add(taskName);
            cycle.RemoveAt(cycle.Count - 1);
            return false;
        }
    }

    class Task
    {
        public string Name { get; }
        public HashSet<string> Dependencies { get; }
        public int Duration { get; }

        public Task(string name, HashSet<string> dependencies, int duration)
        {
            Name = name;
            Dependencies = dependencies;
            Duration = duration;
        }
    }
}
