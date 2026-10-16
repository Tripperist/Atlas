using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

class Program
{
    static void Main(string[] args)
    {
        if (args.Length < 1 || args.Length > 2 || (args.Length == 2 && args[1] != "--format text" && args[1] != "--format json"))
        {
            Console.Error.WriteLine("usage: planner <file> [--format text|json]");
            Environment.Exit(1);
        }

        string filePath = args[0];
        if (!File.Exists(filePath))
        {
            Console.Error.WriteLine($"error: cannot read file: {filePath}");
            Environment.Exit(2);
        }

        try
        {
            var tasks = ParseFile(filePath);
            var result = CalculatePlan(tasks);
            if (args.Length == 2 && args[1] == "--format json")
            {
                Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(result));
            }
            else
            {
                PrintPlan(result);
            }
        }
        catch (SyntaxErrorException ex)
        {
            Console.Error.WriteLine($"error: line {ex.LineNumber}: {ex.Message}");
            Environment.Exit(3);
        }
        catch (UnknownDependencyException ex)
        {
            Console.Error.WriteLine($"error: task '{ex.TaskName}' depends on unknown task '{ex.DependencyName}'");
            Environment.Exit(4);
        }
        catch (DependencyCycleException)
        {
            Console.Error.WriteLine("error: dependency cycle");
            Environment.Exit(5);
        }
    }

    static Dictionary<string, Task> ParseFile(string filePath)
    {
        var tasks = new Dictionary<string, Task>();
        var lines = File.ReadLines(filePath).Select(line => line.Trim()).Where(line => !string.IsNullOrEmpty(line) && line[0] != '#').ToList();

        foreach (var line in lines)
        {
            var parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            var name = parts[0];
            if (tasks.ContainsKey(name))
            {
                throw new SyntaxErrorException(name, "redefined");
            }

            var duration = 1;
            var dependencies = new HashSet<string>();

            for (int i = 1; i < parts.Length; i++)
            {
                if (parts[i][0] == '[')
                {
                    if (i != parts.Length - 1)
                    {
                        throw new SyntaxErrorException(name, "invalid duration");
                    }
                    if (!int.TryParse(parts[i].Trim('[', ']'), out duration) || duration <= 0 || duration > 1000000)
                    {
                        throw new SyntaxErrorException(name, "invalid duration");
                    }
                    break;
                }
                else if (parts[i].Contains(","))
                {
                    dependencies.UnionWith(parts[i].Split(',').Select(d => d.Trim()));
                }
                else
                {
                    dependencies.Add(parts[i]);
                }
            }

            tasks[name] = new Task(name, duration, dependencies);
        }

        return tasks;
    }

    static (List<List<string>>, int, (int, List<string>)) CalculatePlan(Dictionary<string, Task> tasks)
    {
        var graph = new Dictionary<string, List<string>>();
        var inDegree = new Dictionary<string, int>();
        var stages = new List<List<string>>();
        var criticalPath = (0, new List<string>());

        foreach (var task in tasks)
        {
            graph[task.Key] = new List<string>();
            inDegree[task.Key] = 0;
        }

        foreach (var task in tasks)
        {
            foreach (var dependency in task.Value.Dependencies)
            {
                if (!tasks.ContainsKey(dependency))
                {
                    throw new UnknownDependencyException(task.Key, dependency);
                }
                graph[dependency].Add(task.Key);
                inDegree[task.Key]++;
            }
        }

        var queue = new Queue<string>(tasks.Keys.Where(task => inDegree[task] == 0));
        var currentStage = 0;

        while (queue.Count > 0)
        {
            stages.Add(new List<string>());
            currentStage++;

            for (int i = queue.Count; i > 0; i--)
            {
                var task = queue.Dequeue();
                stages[currentStage - 1].Add(task);

                foreach (var neighbor in graph[task])
                {
                    inDegree[neighbor]--;
                    if (inDegree[neighbor] == 0)
                    {
                        queue.Enqueue(neighbor);
                    }
                }
            }
        }

        var totalTasks = tasks.Count;
        var criticalPathDuration = 0;

        for (int i = 0; i < stages.Count; i++)
        {
            var stageDuration = stages[i].Sum(task => tasks[task].Duration);
            if (stageDuration > criticalPathDuration)
            {
                criticalPathDuration = stageDuration;
                criticalPath = (stageDuration, stages[i].OrderBy(t => t).ToList());
            }
        }

        return (stages, totalTasks, criticalPath);
    }

    static void PrintPlan((List<List<string>>, int, (int, List<string>)) result)
    {
        Console.WriteLine($"Total tasks: {result.Item2}");
        for (int i = 0; i < result.Item1.Count; i++)
        {
            Console.WriteLine($"Stage {i + 1}: {string.Join(", ", result.Item1[i].OrderBy(t => t))}");
        }
        Console.WriteLine($"Critical path ({result.Item3.Item1}): {string.Join(" -> ", result.Item3.Item2.OrderBy(t => t))}");
    }

    class Task
    {
        public string Name { get; }
        public int Duration { get; }
        public HashSet<string> Dependencies { get; }

        public Task(string name, int duration, HashSet<string> dependencies)
        {
            Name = name;
            Duration = duration;
            Dependencies = dependencies;
        }
    }

    class SyntaxErrorException : Exception
    {
        public int LineNumber { get; }

        public SyntaxErrorException(string taskName, string message) : base(message)
        {
            LineNumber = 0; // This should be set to the actual line number
        }
    }

    class UnknownDependencyException : Exception
    {
        public string TaskName { get; }
        public string DependencyName { get; }

        public UnknownDependencyException(string taskName, string dependencyName) : base($"unknown task '{dependencyName}'")
        {
            TaskName = taskName;
            DependencyName = dependencyName;
        }
    }

    class DependencyCycleException : Exception
    {
        public DependencyCycleException() : base("dependency cycle")
        {
        }
    }
}
