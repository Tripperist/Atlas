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
            string[] lines;
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
                var line = lines[i].Trim();
                if (string.IsNullOrEmpty(line) || line.StartsWith('#'))
                {
                    continue;
                }

                lineNumbers.Add(i + 1);
                lineContents.Add(line);

                var match = Regex.Match(line, @"^([a-zA-Z0-9_.\-]+)(?:\s*:\s*(.*?))?(?:\s*\[(\d+)\])?$");
                if (!match.Success)
                {
                    Console.Error.WriteLine($"error: line {i + 1}: invalid syntax");
                    Environment.Exit(3);
                }

                var name = match.Groups[1].Value;
                var depsStr = match.Groups[2].Value;
                var durationStr = match.Groups[3].Value;

                if (tasks.ContainsKey(name))
                {
                    Console.Error.WriteLine($"error: line {i + 1}: duplicate task definition");
                    Environment.Exit(3);
                }

                int duration = 1;
                if (!string.IsNullOrEmpty(durationStr))
                {
                    if (!int.TryParse(durationStr, out duration) || duration <= 0 || duration > 1000000)
                    {
                        Console.Error.WriteLine($"error: line {i + 1}: invalid duration");
                        Environment.Exit(3);
                    }
                }

                var deps = new HashSet<string>();
                if (!string.IsNullOrEmpty(depsStr))
                {
                    var depParts = depsStr.Split(',');
                    foreach (var depPart in depParts)
                    {
                        var dep = depPart.Trim();
                        if (string.IsNullOrEmpty(dep))
                        {
                            Console.Error.WriteLine($"error: line {i + 1}: empty dependency");
                            Environment.Exit(3);
                        }
                        deps.Add(dep);
                    }
                }

                tasks[name] = new Task { Name = name, Dependencies = deps.ToList(), Duration = duration };
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

            // Detect cycles
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

            // Build execution plan
            var stages = new List<List<string>>();
            var taskToStage = new Dictionary<string, int>();
            var inDegree = new Dictionary<string, int>();

            // Initialize in-degree
            foreach (var task in tasks.Values)
            {
                inDegree[task.Name] = 0;
            }

            foreach (var task in tasks.Values)
            {
                foreach (var dep in task.Dependencies)
                {
                    inDegree[dep]++;
                }
            }

            // Find all tasks with in-degree 0
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
                for (int i = 0; i < count; i++)
                {
                    var taskName = queue.Dequeue();
                    currentStage.Add(taskName);
                    taskToStage[taskName] = stage;

                    // Reduce in-degree of dependents
                    foreach (var task in tasks.Values)
                    {
                        if (task.Dependencies.Contains(taskName))
                        {
                            inDegree[task.Name]--;
                            if (inDegree[task.Name] == 0)
                            {
                                queue.Enqueue(task.Name);
                            }
                        }
                    }
                }

                currentStage.Sort(StringComparer.Ordinal);
                stages.Add(currentStage);
                stage++;
            }

            // Calculate critical path
            var criticalPath = new List<string>();
            var maxDuration = 0L;
            var taskDurations = new Dictionary<string, long>();
            var taskMaxDurations = new Dictionary<string, long>();

            foreach (var task in tasks.Values)
            {
                taskDurations[task.Name] = task.Duration;
                taskMaxDurations[task.Name] = 0;
            }

            // Topological sort to compute max durations
            var sortedTasks = new List<string>();
            var tempInDegree = new Dictionary<string, int>(inDegree);
            var tempQueue = new Queue<string>();

            foreach (var kvp in tempInDegree)
            {
                if (kvp.Value == 0)
                {
                    tempQueue.Enqueue(kvp.Key);
                }
            }

            while (tempQueue.Count > 0)
            {
                var taskName = tempQueue.Dequeue();
                sortedTasks.Add(taskName);

                foreach (var task in tasks.Values)
                {
                    if (task.Dependencies.Contains(taskName))
                    {
                        tempInDegree[task.Name]--;
                        if (tempInDegree[task.Name] == 0)
                        {
                            tempQueue.Enqueue(task.Name);
                        }
                    }
                }
            }

            // Compute max durations
            foreach (var taskName in sortedTasks)
            {
                var task = tasks[taskName];
                var maxDepDuration = 0L;
                foreach (var dep in task.Dependencies)
                {
                    maxDepDuration = Math.Max(maxDepDuration, taskMaxDurations[dep]);
                }
                taskMaxDurations[taskName] = maxDepDuration + task.Duration;
                if (taskMaxDurations[taskName] > maxDuration)
                {
                    maxDuration = taskMaxDurations[taskName];
                }
            }

            // Backtrack to find critical path
            if (maxDuration > 0)
            {
                var criticalPathTasks = new List<string>();
                var currentTask = "";
                var currentMax = 0L;

                // Find the task with max duration
                foreach (var kvp in taskMaxDurations)
                {
                    if (kvp.Value == maxDuration)
                    {
                        currentTask = kvp.Key;
                        currentMax = kvp.Value;
                        break;
                    }
                }

                // Backtrack to find the path
                var path = new List<string>();
                var visitedBacktrack = new HashSet<string>();
                while (currentTask != null && !visitedBacktrack.Contains(currentTask))
                {
                    visitedBacktrack.Add(currentTask);
                    path.Add(currentTask);
                    var task = tasks[currentTask];
                    var maxDep = 0L;
                    var depTask = "";
                    foreach (var dep in task.Dependencies)
                    {
                        if (taskMaxDurations[dep] > maxDep)
                        {
                            maxDep = taskMaxDurations[dep];
                            depTask = dep;
                        }
                    }
                    if (maxDep == 0)
                    {
                        currentTask = null;
                    }
                    else
                    {
                        currentTask = depTask;
                    }
                }

                // Reverse path to get correct order
                path.Reverse();
                criticalPath = path;
            }

            // Output
            if (format == "json")
            {
                var stagesJson = stages.Select(s => s.ToArray()).ToArray();
                var criticalPathJson = new { duration = maxDuration, tasks = criticalPath.ToArray() };
                var result = new { stages = stagesJson, totalTasks = tasks.Count, criticalPath = criticalPathJson };
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
                    for (int i = 0; i < stages.Count; i++)
                    {
                        Console.WriteLine($"Stage {i + 1}: {string.Join(", ", stages[i])}");
                    }
                    Console.WriteLine($"Total tasks: {tasks.Count}");
                    if (maxDuration > 0)
                    {
                        Console.WriteLine($"Critical path ({maxDuration}): {string.Join(" -> ", criticalPath)}");
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
        public string Name { get; set; }
        public List<string> Dependencies { get; set; }
        public int Duration { get; set; }
    }
}
