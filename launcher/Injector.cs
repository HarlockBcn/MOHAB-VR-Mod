using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace MOHABPlus;

/// <summary>Classic LoadLibraryW + CreateRemoteThread DLL injection for x64 processes.</summary>
internal static class Injector
{
    private const uint PROCESS_ALL_ACCESS = 0x001F0FFF;
    private const uint MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_RELEASE = 0x8000;
    private const uint PAGE_READWRITE = 0x04;
    private const uint WAIT_OBJECT_0 = 0;
    private const uint TH32CS_SNAPMODULE = 0x08, TH32CS_SNAPMODULE32 = 0x10;

    [DllImport("kernel32", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32", SetLastError = true)] private static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32", SetLastError = true)] private static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32", SetLastError = true)] private static extern bool VirtualFreeEx(IntPtr p, IntPtr addr, UIntPtr size, uint type);
    [DllImport("kernel32", SetLastError = true)] private static extern bool WriteProcessMemory(IntPtr p, IntPtr addr, byte[] buf, UIntPtr size, out UIntPtr written);
    [DllImport("kernel32", SetLastError = true)] private static extern IntPtr CreateRemoteThread(IntPtr p, IntPtr attr, UIntPtr stack, IntPtr start, IntPtr param, uint flags, out uint tid);
    [DllImport("kernel32", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32", SetLastError = true)] private static extern bool GetExitCodeThread(IntPtr h, out uint code);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr GetModuleHandleW(string name);
    [DllImport("kernel32", CharSet = CharSet.Ansi, SetLastError = true)] private static extern IntPtr GetProcAddress(IntPtr mod, string name);
    [DllImport("kernel32", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, int pid);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Module32FirstW(IntPtr snap, ref MODULEENTRY32W me);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Module32NextW(IntPtr snap, ref MODULEENTRY32W me);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MODULEENTRY32W
    {
        public uint dwSize, th32ModuleID, th32ProcessID, GlblcntUsage, ProccntUsage;
        public IntPtr modBaseAddr;
        public uint modBaseSize;
        public IntPtr hModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szModule;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExePath;
    }

    /// <summary>Returns the loaded module names of a process, or null if the process is not ready yet.</summary>
    public static List<string>? GetModules(int pid)
    {
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return null;
        try
        {
            var list = new List<string>();
            var me = new MODULEENTRY32W { dwSize = (uint)Marshal.SizeOf<MODULEENTRY32W>() };
            if (!Module32FirstW(snap, ref me)) return null;
            do { list.Add(me.szModule); } while (Module32NextW(snap, ref me));
            return list;
        }
        finally { CloseHandle(snap); }
    }

    public static bool IsModuleLoaded(int pid, string moduleName)
    {
        var mods = GetModules(pid);
        return mods != null && mods.Any(m => string.Equals(m, moduleName, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Injects <paramref name="dllPath"/> into <paramref name="pid"/>. Throws on failure.</summary>
    public static void Inject(int pid, string dllPath, uint timeoutMs = 60000)
    {
        if (!File.Exists(dllPath)) throw new FileNotFoundException("DLL not found", dllPath);
        IntPtr hProc = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
        if (hProc == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed (try running the launcher as the same user as the game)");
        IntPtr remote = IntPtr.Zero;
        try
        {
            byte[] bytes = Encoding.Unicode.GetBytes(dllPath + "\0");
            remote = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)bytes.Length, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (remote == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualAllocEx failed");
            if (!WriteProcessMemory(hProc, remote, bytes, (UIntPtr)bytes.Length, out _))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed");
            IntPtr loadLibrary = GetProcAddress(GetModuleHandleW("kernel32.dll"), "LoadLibraryW");
            IntPtr hThread = CreateRemoteThread(hProc, IntPtr.Zero, UIntPtr.Zero, loadLibrary, remote, 0, out _);
            if (hThread == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateRemoteThread failed");
            try
            {
                if (WaitForSingleObject(hThread, timeoutMs) != WAIT_OBJECT_0)
                    throw new TimeoutException("LoadLibraryW did not return in time");
                GetExitCodeThread(hThread, out uint code);
                if (code == 0) throw new Exception("LoadLibraryW returned NULL inside the game (DLL failed to load)");
            }
            finally { CloseHandle(hThread); }
        }
        finally
        {
            if (remote != IntPtr.Zero) VirtualFreeEx(hProc, remote, UIntPtr.Zero, MEM_RELEASE);
            CloseHandle(hProc);
        }
    }

    /// <summary>
    /// Waits until the game created its main window and then a little longer, so UE4SS starts after the engine
    /// and the CRT are initialised (injecting right at process start crashes the game).
    /// </summary>
    public static bool WaitForGameWindow(Process p, int timeoutMs, int extraDelayMs)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            if (p.HasExited) return false;
            p.Refresh();
            if (p.MainWindowHandle != IntPtr.Zero)
            {
                Thread.Sleep(extraDelayMs);
                return !p.HasExited;
            }
            Thread.Sleep(200);
        }
        return false;
    }

    /// <summary>Waits until the Windows loader has mapped the basic system modules of a freshly started process.</summary>
    public static bool WaitForProcessReady(Process p, int timeoutMs)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            if (p.HasExited) return false;
            var mods = GetModules(p.Id);
            if (mods != null && mods.Any(m => m.Equals("kernel32.dll", StringComparison.OrdinalIgnoreCase))
                && mods.Any(m => m.Equals("user32.dll", StringComparison.OrdinalIgnoreCase)))
                return true;
            Thread.Sleep(50);
        }
        return false;
    }
}
