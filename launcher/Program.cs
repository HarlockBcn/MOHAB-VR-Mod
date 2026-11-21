using System.Diagnostics;

namespace MOHABPlus;

internal static class Program
{
    /// <summary>
    /// MOHAB Plus launcher.
    ///   (no args)          open the launcher window
    ///   --launch           start the game with the mod and exit (no window)
    ///   --watch            stay in the background and inject when the game starts (no window)
    ///   --inject PID       inject into a running game process and exit
    /// Headless modes write to launcher.log next to the exe.
    /// </summary>
    [STAThread]
    private static int Main(string[] args)
    {
        string baseDir = AppContext.BaseDirectory;
        var settings = LauncherSettings.Load(baseDir);

        if (args.Length > 0)
            return RunHeadless(args, baseDir, settings);

        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm(baseDir, settings));
        return 0;
    }

    private static int RunHeadless(string[] args, string baseDir, LauncherSettings settings)
    {
        string logPath = Path.Combine(baseDir, "launcher.log");
        void Log(string s) { try { File.AppendAllText(logPath, s + Environment.NewLine); } catch { } Console.WriteLine(s); }

        using var svc = new ModInjectorService(baseDir);
        svc.Log += Log;
        string gameDir = settings.GameDir ?? GameLocator.Find() ?? "";

        switch (args[0].ToLowerInvariant())
        {
            case "--launch":
                svc.LaunchAsync(gameDir, settings.ExtraArgs).GetAwaiter().GetResult();
                return 0;
            case "--inject":
                if (args.Length < 2 || !int.TryParse(args[1], out int pid)) { Log("usage: --inject PID"); return 2; }
                try
                {
                    Injector.Inject(pid, svc.Ue4ssDll);
                    Log($"Injected into {pid}");
                    return 0;
                }
                catch (Exception ex) { Log("Injection failed: " + ex.Message); return 1; }
            case "--watch":
                svc.StartWatching();
                Thread.Sleep(Timeout.Infinite);
                return 0;
            default:
                Log("Unknown argument " + args[0]);
                return 2;
        }
    }
}

internal sealed class LauncherSettings
{
    public string? GameDir;
    public bool AutoWatch = true;
    public string ExtraArgs = "";
    private string _path = "";

    public static LauncherSettings Load(string baseDir)
    {
        var s = new LauncherSettings { _path = Path.Combine(baseDir, "launcher.ini") };
        if (File.Exists(s._path))
        {
            foreach (var line in File.ReadAllLines(s._path))
            {
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string k = line[..eq].Trim(), v = line[(eq + 1)..].Trim();
                switch (k)
                {
                    case "game_dir": s.GameDir = v.Length > 0 ? v : null; break;
                    case "auto_watch": s.AutoWatch = v.Equals("true", StringComparison.OrdinalIgnoreCase); break;
                    case "extra_args": s.ExtraArgs = v; break;
                }
            }
        }
        if (!GameLocator.IsGameDir(s.GameDir)) s.GameDir = GameLocator.Find();
        return s;
    }

    public void Save()
    {
        File.WriteAllLines(_path, new[]
        {
            "game_dir=" + (GameDir ?? ""),
            "auto_watch=" + (AutoWatch ? "true" : "false"),
            "extra_args=" + ExtraArgs,
        });
    }
}
