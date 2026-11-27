using System.Text.RegularExpressions;

namespace MOHABPlus;

/// <summary>
/// Launcher texts in the chosen language, from lang/&lt;code&gt;.txt (shared with the in-game menu, see Scripts/lang.lua).
/// Format: "key = text", "#" comments, "\n" = new line, {0} {1}... = arguments. English (en.txt) is the reference: a key
/// missing from another language is taken from it, a key missing everywhere shows as the key itself. Each file is read
/// from the installed mod folder if it is there, else from the copy embedded in the launcher.
/// </summary>
internal static class Lang
{
    private static Dictionary<string, string> _texts = new();
    private static string? _dir;

    public static string Code { get; private set; } = "";

    /// <summary>Folder of the installed lang files (ue4ss/Mods/MOHABPlus/lang); embedded copies are used without it.</summary>
    public static void Init(string? langDir) { _dir = langDir; Code = ""; }

    public static void SetLanguage(string code)
    {
        code = string.IsNullOrWhiteSpace(code) ? "en" : code.Trim().ToLowerInvariant();
        if (code == Code && _texts.Count > 0) return;
        Code = code;
        var t = new Dictionary<string, string>();
        Read("en", t);
        if (code != "en") Read(code, t);
        _texts = t;
    }

    private static void Read(string code, Dictionary<string, string> into)
    {
        string? text = null;
        try
        {
            if (_dir != null)
            {
                var file = Path.Combine(_dir, code + ".txt");
                if (File.Exists(file)) text = File.ReadAllText(file);
            }
        }
        catch { }
        if (text == null)
        {
            using var s = typeof(Lang).Assembly.GetManifestResourceStream($"MOHABPlus.lang.{code}.txt");
            if (s != null) using (var r = new StreamReader(s)) text = r.ReadToEnd();
        }
        if (text == null) return;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] == '#') continue;
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            into[line[..eq].Trim()] = line[(eq + 1)..].Trim().Replace("\\n", "\n");
        }
    }

    /// <summary>Languages that have a file (installed or embedded): code and own name (lang.name), English first.</summary>
    public static List<(string Code, string Name)> Available()
    {
        var codes = new SortedSet<string>(StringComparer.Ordinal);
        const string prefix = "MOHABPlus.lang.";
        foreach (var n in typeof(Lang).Assembly.GetManifestResourceNames())
            if (n.StartsWith(prefix) && n.EndsWith(".txt")) codes.Add(n[prefix.Length..^4]);
        try
        {
            if (_dir != null && Directory.Exists(_dir))
                foreach (var f in Directory.GetFiles(_dir, "*.txt")) codes.Add(Path.GetFileNameWithoutExtension(f).ToLowerInvariant());
        }
        catch { }
        var list = new List<(string Code, string Name)>();
        foreach (var c in codes)
        {
            if (!Regex.IsMatch(c, "^[a-z]{2}$")) continue;
            var t = new Dictionary<string, string>();
            Read(c, t);
            list.Add((c, t.TryGetValue("lang.name", out var n) ? n : c));
        }
        list.Sort((a, b) => a.Code == "en" ? -1 : b.Code == "en" ? 1 : string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
        return list;
    }

    /// <summary>Language for a "language" setting: the code itself, or for "auto" Windows' language if there is a file
    /// for it (else English).</summary>
    public static string Resolve(string? setting)
    {
        if (!string.IsNullOrWhiteSpace(setting) && setting != "auto") return setting.Trim().ToLowerInvariant();
        var win = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.ToLowerInvariant();
        return Available().Any(l => l.Code == win) ? win : "en";
    }

    /// <summary>Text of a key with its {0} {1}... filled in.</summary>
    public static string T(string key, params object?[] args)
    {
        if (_texts.Count == 0) SetLanguage("en");
        var s = _texts.TryGetValue(key, out var v) ? v : key;
        if (args.Length > 0)
            s = Regex.Replace(s, @"\{(\d)\}", m => int.Parse(m.Groups[1].Value) is var i && i < args.Length ? args[i]?.ToString() ?? "" : "");
        return s;
    }

    /// <summary>Text of a key, or null if no language has it.</summary>
    public static string? Find(string key)
    {
        if (_texts.Count == 0) SetLanguage("en");
        return _texts.TryGetValue(key, out var v) ? v : null;
    }

    /// <summary>Category name ("Fall damage" -> section.fall_damage; same rule as the in-game menu).</summary>
    public static string Section(string name)
    {
        var slug = Regex.Replace(name.ToLowerInvariant(), "[^a-z0-9]+", "_").Trim('_');
        return Find("section." + slug) ?? name;
    }

    /// <summary>Multi-line text with Windows line breaks (labels, message boxes).</summary>
    public static string Lines(string key, params object?[] args) => T(key, args).Replace("\n", Environment.NewLine);
}
