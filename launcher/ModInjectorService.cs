using System.Diagnostics;

namespace MOHABPlus;

/// <summary>Launches the game and/or watches for game processes and injects UE4SS into them.</summary>
internal sealed class ModInjectorService : IDisposable
{
    public const string Ue4ssDllName = "UE4SS.dll";

    private readonly HashSet<int> _handled = new();
    private System.Threading.Timer? _watchTimer;
    private readonly object _lock = new();

    public event Action<string>? Log;
    public string BaseDir { get; }
    public string Ue4ssDll => Path.Combine(BaseDir, "ue4ss", Ue4ssDllName);

    public ModInjectorService(string baseDir) { BaseDir = baseDir; }

    private void Say(string msg) => Log?.Invoke($"[{DateTime.Now:HH:mm:ss}] {msg}");

    public static Process[] FindGameProcesses() => Process.GetProcessesByName(GameLocator.ShippingExeName);

    /// <summary>Starts the game (or reuses a running instance) and injects the mod.</summary>
    public async Task LaunchAsync(string gameDir, string extraArgs)
    {
        var running = FindGameProcesses();
        if (running.Length > 0)
        {
            Say(Lang.T("svc.already_running", running[0].Id));
            await Task.Run(() => TryInject(running[0], lateInjection: true));
            return;
        }
        string exe = GameLocator.ShippingExe(gameDir);
        if (!File.Exists(exe)) { Say(Lang.T("svc.exe_not_found", exe)); return; }

        var psi = new ProcessStartInfo(exe)
        {
            WorkingDirectory = Path.GetDirectoryName(exe)!,
            UseShellExecute = true,   // do not inherit our console/pipe handles
            Arguments = extraArgs ?? string.Empty,
        };
        Say(Lang.T("svc.starting", exe, psi.Arguments));
        var p = Process.Start(psi);
        if (p == null) { Say("Process.Start returned null."); return; }
        lock (_lock) _handled.Add(p.Id);
        await Task.Run(() =>
        {
            Say(Lang.T("svc.waiting_window"));
            if (!Injector.WaitForGameWindow(p, 180000, 3000)) { Say(Lang.T("svc.no_window")); return; }
            TryInject(p, lateInjection: false);
        });
    }

    private void TryInject(Process p, bool lateInjection)
    {
        try
        {
            if (Injector.IsModuleLoaded(p.Id, Ue4ssDllName))
            {
                Say(Lang.T("svc.already_loaded", p.Id));
                return;
            }
            Say(Lang.T(lateInjection ? "svc.injecting_late" : "svc.injecting", p.Id, Ue4ssDll));
            Injector.Inject(p.Id, Ue4ssDll);
            Say(Lang.T("svc.loaded", p.Id));
        }
        catch (Exception ex)
        {
            Say(Lang.T("svc.inject_failed", p.Id, ex.Message));
        }
    }

    /// <summary>Polls for game processes started by someone else (Virtual Desktop, Oculus app) and injects them.</summary>
    public void StartWatching()
    {
        if (_watchTimer != null) return;
        Say(Lang.T("svc.waiting_game"));
        _watchTimer = new System.Threading.Timer(_ => WatchTick(), null, 0, 250);
    }

    public void StopWatching()
    {
        _watchTimer?.Dispose();
        _watchTimer = null;
    }

    public bool IsWatching => _watchTimer != null;

    private int _ticking;
    private void WatchTick()
    {
        if (Interlocked.Exchange(ref _ticking, 1) == 1) return;
        try
        {
            foreach (var p in FindGameProcesses())
            {
                lock (_lock)
                {
                    if (_handled.Contains(p.Id)) continue;
                    _handled.Add(p.Id);
                }
                Say(Lang.T("svc.detected", p.Id));
                if (!Injector.WaitForGameWindow(p, 180000, 3000)) { Say(Lang.T("svc.no_window")); continue; }
                TryInject(p, lateInjection: (DateTime.Now - SafeStartTime(p)).TotalSeconds > 30);
            }
        }
        catch (Exception ex) { Say(Lang.T("svc.watcher_error", ex.Message)); }
        finally { Interlocked.Exchange(ref _ticking, 0); }
    }

    private static DateTime SafeStartTime(Process p)
    {
        try { return p.StartTime; } catch { return DateTime.Now; }
    }

    public void Dispose() => StopWatching();
}
