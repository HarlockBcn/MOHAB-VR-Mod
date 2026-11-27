using System.Reflection;

namespace MOHABPlus;

/// <summary>Version and repository information shared by the UI and the updater.</summary>
internal static class AppInfo
{
    public const string RepoOwner = "HarlockBcn";
    public const string RepoName = "MOHAB-VR-Mod";
    public const string RepoUrl = "https://github.com/" + RepoOwner + "/" + RepoName;
    public const string ReleasesUrl = RepoUrl + "/releases";

    public const string Author = "Harlock";
    public const string Credit = "by " + Author;

    // The disclaimer shown in the ABOUT tab is ui.disclaimer_text in the lang files (keep it in sync with the README
    // "Disclaimer" section).

    /// <summary>Mod version (x.y.z), taken from the VERSION file at build time.</summary>
    public static readonly Version Version = Normalize(Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0, 0));

    public static string VersionText => Format(Version);

    public static string Format(Version v) => $"v{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";

    public static Version Normalize(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build));

    /// <summary>Parses "v1.2.3" / "1.2.3" (anything after the third number, e.g. "-beta", is ignored).</summary>
    public static Version? ParseTag(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        string s = tag.Trim().TrimStart('v', 'V');
        int cut = s.IndexOfAny(new[] { '-', '+', ' ' });
        if (cut >= 0) s = s[..cut];
        var parts = s.Split('.');
        if (parts.Length != 3) return null;
        return int.TryParse(parts[0], out int a) && int.TryParse(parts[1], out int b) && int.TryParse(parts[2], out int c)
            ? new Version(a, b, c) : null;
    }
}
