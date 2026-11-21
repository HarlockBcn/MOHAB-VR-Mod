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
            Say($"The game is already running (PID {running[0].Id}). Injecting into it.");
            await Task.Run(() => TryInject(running[0], lateInjection: true));
            return;
        }
        string exe = GameLocator.ShippingExe(gameDir);
        if (!File.Exists(exe)) { Say("Game executable not found: " + exe); return; }

        var psi = new ProcessStartInfo(exe)
        {
            WorkingDirectory = Path.GetDirectoryName(exe)!,
            UseShellExecute = true,   // do not inherit our console/pipe handles
            Arguments = extraArgs ?? string.Empty,
        };
        Say("Starting " + exe + " " + psi.Arguments);
        var p = Process.Start(psi);
        if (p == null) { Say("Process.Start returned null."); return; }
        lock (_lock) _handled.Add(p.Id);
        await Task.Run(() =>
        {
            Say("Waiting for the game window...");
            if (!Injector.WaitForGameWindow(p, 180000, 3000)) { Say("The game window did not appear (or the game exited)."); return; }
            TryInject(p, lateInjection: false);
        });
    }

    private void TryInject(Process p, bool lateInjection)
    {
        try
        {
            if (Injector.IsModuleLoaded(p.Id, Ue4ssDllName))
            {
                Say($"PID {p.Id}: mod already loaded.");
                return;
            }
            Say($"PID {p.Id}: injecting {Ue4ssDll}{(lateInjection ? " (game already running)" : "")} ...");
            Injector.Inject(p.Id, Ue4ssDll);
            Say($"PID {p.Id}: mod loaded. Hold LEFT Y in-game to open the MOHAB Plus menu.");
        }
        catch (Exception ex)
        {
            Say($"PID {p.Id}: injection failed: {ex.Message}");
        }
    }

    /// <summary>Polls for game processes started by someone else (Virtual Desktop, Oculus app) and injects them.</summary>
    public void StartWatching()
    {
        if (_watchTimer != null) return;
        Say("Waiting for the game to start (launch it from Virtual Desktop / Oculus)...");
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
                Say($"Detected game process PID {p.Id}.");
                if (!Injector.WaitForGameWindow(p, 180000, 3000)) { Say("The game window did not appear (or the game exited)."); continue; }
                TryInject(p, lateInjection: (DateTime.Now - SafeStartTime(p)).TotalSeconds > 30);
            }
        }
        catch (Exception ex) { Say("Watcher error: " + ex.Message); }
        finally { Interlocked.Exchange(ref _ticking, 0); }
    }

    private static DateTime SafeStartTime(Process p)
    {
        try { return p.StartTime; } catch { return DateTime.Now; }
    }

    public void Dispose() => StopWatching();
}
