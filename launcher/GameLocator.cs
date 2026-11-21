using Microsoft.Win32;

namespace MOHABPlus;

internal static class GameLocator
{
    public const string CanonicalName = "respawn-entertainment-medal-of-honor-above-and-beyond";
    public const string ShippingExeName = "Mohab-Win64-Shipping";
    public const string ShippingRelPath = @"Mohab\Binaries\Win64\Mohab-Win64-Shipping.exe";

    /// <summary>Tries to find the game folder through the Oculus library registry entries.</summary>
    public static string? Find()
    {
        foreach (var lib in OculusLibraries())
        {
            var dir = System.IO.Path.Combine(lib, "Software", CanonicalName);
            if (IsGameDir(dir)) return dir;
        }
        const string fallback = @"C:\Program Files\Oculus\Software\Software\" + CanonicalName;
        return IsGameDir(fallback) ? fallback : null;
    }

    public static bool IsGameDir(string? dir) =>
        !string.IsNullOrWhiteSpace(dir) && File.Exists(System.IO.Path.Combine(dir, ShippingRelPath));

    public static string ShippingExe(string gameDir) => System.IO.Path.Combine(gameDir, ShippingRelPath);

    private static IEnumerable<string> OculusLibraries()
    {
        var result = new List<string>();
        try
        {
            using var libs = Registry.CurrentUser.OpenSubKey(@"Software\Oculus VR, LLC\Oculus\Libraries");
            if (libs != null)
            {
                foreach (var name in libs.GetSubKeyNames())
                {
                    using var k = libs.OpenSubKey(name);
                    if (k?.GetValue("OriginalPath") is string p && Directory.Exists(p)) result.Add(p);
                    else if (k?.GetValue("Path") is string vp)
                    {
                        // "Path" is a \\?\Volume{...}\ path; try to keep it as-is (works with File APIs).
                        if (Directory.Exists(vp)) result.Add(vp);
                    }
                }
            }
        }
        catch { /* ignore */ }
        // Also look for manifests on fixed drives (cheap check of the usual library folder names).
        foreach (var d in DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady))
        {
            foreach (var n in new[] { "OculusLibrary", "Oculus", @"Program Files\Oculus\Software" })
            {
                var p = System.IO.Path.Combine(d.RootDirectory.FullName, n);
                if (Directory.Exists(System.IO.Path.Combine(p, "Software"))) result.Add(p);
            }
        }
        return result.Distinct(StringComparer.OrdinalIgnoreCase);
    }
}
