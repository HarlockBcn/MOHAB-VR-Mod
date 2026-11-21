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

    /// <summary>Disclaimer shown in the launcher's ABOUT tab (keep in sync with the README "Disclaimer" section).</summary>
    public static readonly string[] Disclaimer =
    {
        "MOHAB Plus is a personal, non-commercial fan project made by Harlock.",
        "I have used artificial intelligence (AI) tools to make this mod: much of the research and code was done together with an AI assistant.",
        "My purpose is purely practical: to play Medal of Honor: Above and Beyond in a way that I personally find smoother and more fun, and to share it with anyone who feels the same.",
        "This mod has nothing to do with Respawn Entertainment, the studio that created the game, nor with Electronic Arts or Meta. It is not affiliated with, endorsed or supported by them, so please do not contact them about problems with the mod.",
        "Medal of Honor and the game's artwork and trademarks belong to their respective owners. The mod does not modify any game file. Use it at your own risk.",
    };

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
