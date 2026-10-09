namespace AtlasChat;

/// <summary>
/// Locates repository-relative assets regardless of where the app was started.
/// </summary>
/// <remarks>
/// A default like <c>models/Phi-4-mini-reasoning-onnx/npu/qnn-int4</c> resolves
/// against the current working directory, so it only worked when run from the
/// repository root. <c>dotnet run --project .</c> from inside the project
/// directory failed with "is not a directory", which is accurate and useless.
///
/// The root is found by walking up from the executable, which does not move
/// with the shell's location.
/// </remarks>
internal static class RepoPaths
{
    /// <summary>
    /// Resolve a path the user supplied, or a default, to something absolute.
    /// A relative path is tried against the working directory first, because
    /// that is what someone typing one expects, and the repository root second.
    /// </summary>
    public static string Resolve(string path)
    {
        if (Path.IsPathRooted(path)) return path;

        string fromCwd = Path.GetFullPath(path);
        if (Directory.Exists(fromCwd) || File.Exists(fromCwd)) return fromCwd;

        string? root = FindRoot();
        if (root is not null)
        {
            string fromRoot = Path.GetFullPath(Path.Combine(root, path));
            if (Directory.Exists(fromRoot) || File.Exists(fromRoot)) return fromRoot;
        }

        // Nothing matched. Return the working-directory form so the error
        // message shows the path the user most likely meant.
        return fromCwd;
    }

    /// <summary>The repository root, or null when the app runs outside one.</summary>
    public static string? FindRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            // Two markers rather than one, so a stray .git elsewhere on the
            // path cannot produce a false positive.
            if (Directory.Exists(Path.Combine(dir.FullName, ".git")) &&
                File.Exists(Path.Combine(dir.FullName, "README.md")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }
        return null;
    }
}
