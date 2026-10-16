using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

class Program
{
    static void Main(string[] args)
    {
        if (args.Length < 1 || (args.Length > 2 && !args[1].StartsWith("--format=")))
        {
            Console.Error.WriteLine("usage: planner <file> [--format text|json]");
            Environment.Exit(1);
        }

        string filePath = args[0];
        string format = args.Length == 2 ? args[1].Substring(10) : "text";

        if (format != "text" && format != "json")
        {
            Console.Error.WriteLine("error: unknown format: " + format);
            Environment.Exit(1);
        }

        try
        {
            var tasks = ReadTasks(filePath);
            var plan = CalculatePlan(tasks);
            PrintPlan(plan, format);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("error: " + ex.Message);
            Environment.Exit(1);
        }
    }

    static Dictionary<string, Task> ReadTasks(string filePath)
    {
        var tasks = new Dictionary<string, Task>();
        var lines = File.ReadAllLines(filePath);

        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i].Trim();
            if (string.IsNullOrEmpty(line) || line.StartsWith('#'))
                continue;

            var parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            var name = parts[0];

            if (tasks.ContainsKey(name))
            {
                Console.Error.WriteLine($"error: line {i + 1}: redefinition of task '{name}'");
                Environment.Exit(1);
            }

            var task = new Task { Name = name };
            tasks[name] = task;

            if (parts.Length > 1)
            {
                if (parts[1].StartsWith('['))
                {
                    if (!int.TryParse(parts[1].Trim('[', ']'), out task.Duration) || task.Duration <= 0)
                    {
                        Console.Error.WriteLine($"error: line {i + 1}: invalid duration '{parts[1]}'");
                        Environment.Exit(1);
                    }
                }
                else
                {
                    task.Dependencies = parts[1].Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries).Select(d => d.Trim()).Where(d => !string.IsNullOrEmpty(d)).Distinct().ToList();
                }
            }
        }

        return tasks;
    }

    static Plan CalculatePlan(Dictionary<string, Task> tasks)
    {
        var graph = new Dictionary<string, List<string>>();
        var inDegree = new Dictionary<string, int>();
        var durations = new Dictionary<string, int>();
        var criticalPath = new List<string>();
        var criticalPathDuration = 0;

        foreach (var task in tasks.Values)
        {
            graph[task.Name] = new List<string>();
            inDegree[task.Name] = 0;
            durations[task.Name] = task.Duration ?? 1;
        }

        foreach (var task in tasks.Values)
        {
            foreach (var dependency in task.Dependencies)
            {
                if (!tasks.ContainsKey(dependency))
                {
                    Console.Error.WriteLine($"error: task '{task.Name}' depends on unknown task '{dependency}'");
                    Environment.Exit(1);
                }

                graph[dependency].Add(task.Name);
                inDegree[task.Name]++;
            }
        }

        var queue = new Queue<string>(tasks.Keys.Where(k => inDegree[k] == 0));
        var stages = new List<List<string>>();
        var stage = new List<string>();

        while (queue.Count > 0)
        {
            stage.Clear();
            while (queue.Count > 0)
            {
                var current = queue.Dequeue();
                stage.Add(current);

                foreach (var next in graph[current])
                {
                    inDegree[next]--;
                    if (inDegree[next] == 0)
                        queue.Enqueue(next);
                }
            }

            stages.Add(stage.OrderBy(t => t).ToList());
        }

        var visited = new HashSet<string>();
        var currentPath = new List<string>();
        var currentPathDuration = 0;

        foreach (var task in tasks.Keys.OrderBy(t => t))
        {
            if (!visited.Contains(task))
            {
                var path = new List<string>();
                var pathDuration = 0;

                if (Dfs(task, visited, graph, durations, path, ref pathDuration))
                {
                    if (pathDuration > criticalPathDuration)
                    {
                        criticalPathDuration = pathDuration;
                        criticalPath = path;
                    }
                    else if (pathDuration == criticalPathDuration && string.Join(",", path) < string.Join(",", criticalPath))
                    {
                        criticalPath = path;
                    }
                }
            }
        }

        return new Plan
        {
            Stages = stages,
            TotalTasks = tasks.Count,
            CriticalPath = new CriticalPath
            {
                Duration = criticalPathDuration,
                Tasks = criticalPath
            }
        };
    }

    static bool Dfs(string task, HashSet<string> visited, Dictionary<string, List<string>> graph, Dictionary<string, int> durations, List<string> path, ref int pathDuration)
    {
        if (visited.Contains(task))
            return false;

        visited.Add(task);
        path.Add(task);
        pathDuration += durations[task];

        foreach (var next in graph[task])
        {
            if (!Dfs(next, visited, graph, durations, path, ref pathDuration))
                return false;
        }

        path.RemoveAt(path.Count - 1);
        pathDuration -= durations[task];
        visited.Remove(task);

        return true;
    }

    static void PrintPlan(Plan plan, string format)
    {
        if (format == "text")
        {
            Console.WriteLine("Total tasks: " + plan.TotalTasks);
            for (int i = 0; i < plan.Stages.Count; i++)
            {
                Console.WriteLine($"Stage {i + 1}: " + string.Join(", ", plan.Stages[i]));
            }
            Console.WriteLine($"Critical path ({plan.CriticalPath.Duration}): " + string.Join(" -> ", plan.CriticalPath.Tasks));
        }
        else if (format == "json")
        {
            var json = JsonSerializer.Serialize(new
            {
                stages = plan.Stages,
                totalTasks = plan.TotalTasks,
                criticalPath = new
                {
                    duration = plan.CriticalPath.Duration,
                    tasks = plan.CriticalPath.Tasks
                }
            }, new JsonSerializerOptions { WriteIndented = true });
            Console.WriteLine(json);
        }
    }

    class Task
    {
        public string Name { get; set; }
        public int? Duration { get; set; }
        public List<string> Dependencies { get; set; } = new List<string>();
    }

    class Plan
    {
        public List<List<string>> Stages { get; set; } = new List<List<string>>();
        public int TotalTasks { get; set; }
        public CriticalPath CriticalPath { get; set; }
    }

    class CriticalPath
    {
        public int Duration { get; set; }
        public List<string> Tasks { get; set; } = new List<string>();
    }
}
