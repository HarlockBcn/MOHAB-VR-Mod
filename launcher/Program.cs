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
    ///   --install-zip ZIP  install a downloaded release zip over this folder (offline update; settings are kept)
    ///   --updated X.Y.Z    (internal) open the window after a self-update
    /// Headless modes write to launcher.log next to the exe.
    /// </summary>
    [STAThread]
    private static int Main(string[] args)
    {
        string baseDir = AppContext.BaseDirectory;
        var settings = LauncherSettings.Load(baseDir);

        bool justUpdated = args.Length > 0 && args[0].Equals("--updated", StringComparison.OrdinalIgnoreCase);
        if (args.Length > 0 && !justUpdated)
            return RunHeadless(args, baseDir, settings);

        // Leftovers of a previous self-update. Right after an update the old launcher may still be closing.
        if (justUpdated) Task.Delay(4000).ContinueWith(_ => Updater.CleanupOldFiles(baseDir));
        else Updater.CleanupOldFiles(baseDir);

        // One launcher window per user: starting it again shows the running one (it may be hidden in the tray)
        // instead of opening a second copy that would also watch and inject.
        using var mutex = new Mutex(true, SingleInstanceName, out bool first);
        if (!first)
        {
            // After a self-update the old launcher is still closing: wait for it instead of handing over.
            bool acquired = false;
            if (justUpdated) { try { acquired = mutex.WaitOne(15000); } catch (AbandonedMutexException) { acquired = true; } }
            if (!acquired)
            {
                try { using var show = EventWaitHandle.OpenExisting(ShowEventName); show.Set(); } catch { /* old version without the event */ }
                return 0;
            }
        }
        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);

        ApplicationConfiguration.Initialize();
        Lang.Init(Path.Combine(baseDir, "ue4ss", "Mods", "MOHABPlus", "lang"));
        Lang.SetLanguage("en");
        var form = new MainForm(baseDir, settings, justUpdated);
        var listener = new Thread(() =>
        {
            while (showEvent.WaitOne())
            {
                if (form.IsDisposed) return;
                try { form.BeginInvoke(form.RestoreFromTray); } catch (InvalidOperationException) { return; }
            }
        }) { IsBackground = true, Name = "single-instance" };
        listener.Start();
        Application.Run(form);
        return 0;
    }

    private const string SingleInstanceName = @"Local\MOHABPlusLauncher.SingleInstance";
    private const string ShowEventName = @"Local\MOHABPlusLauncher.Show";

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
            case "--install-zip":
                if (args.Length < 2 || !File.Exists(args[1])) { Log("usage: --install-zip PATH_TO_ZIP"); return 2; }
                if (ModInjectorService.FindGameProcesses().Length > 0) { Log("Close the game before updating."); return 1; }
                try
                {
                    Updater.InstallFromZip(args[1], baseDir, new Progress<string>(Log));
                    Log("Installed " + args[1]);
                    return 0;
                }
                catch (Exception ex) { Log("Install failed: " + ex.Message); return 1; }
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
