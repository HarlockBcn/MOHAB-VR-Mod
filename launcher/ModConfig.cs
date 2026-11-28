using System.Globalization;
using System.Text;

namespace MOHABPlus;

internal enum OptionKind { Bool, Float, Choice }

/// <summary>An option of config.ini. Its texts come from the lang files (see Lang): name "opt.KEY" (or "opt.KEY.long"
/// in the launcher), choices "opt.KEY.choice.VALUE"; Section is the English category id, shown as "section.*".</summary>
internal sealed record ModOption(
    string Key, OptionKind Kind, string Default,
    double Min = 0, double Max = 1, double Step = 0.1, string[]? Choices = null, string Section = "General")
{
    public string Label => Lang.Find($"opt.{Key}.long") ?? Lang.T($"opt.{Key}");
    public string ChoiceLabel(string value) => Lang.Find($"opt.{Key}.choice.{value}") ?? value;
}

/// <summary>
/// Reads/writes the key=value config shared with the Lua mod (ue4ss/Mods/MOHABPlus/config.ini).
/// The option list (order and sections) must stay in sync with Scripts/config.lua (M.order) and the
/// categories of Scripts/menu.lua.
/// </summary>
internal sealed class ModConfig
{
    public static readonly ModOption[] Options =
    {
        new("crouch_stick", OptionKind.Bool, "true", Section: "Movement"),
        new("crouch_stick_threshold", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Movement"),
        new("crouch_speed", OptionKind.Float, "0.6", 0.3, 1.0, 0.05, Section: "Movement"),
        new("sprint_mode", OptionKind.Choice, "always",
            Choices: new[] { "stick", "arms", "both", "always" }, Section: "Movement"),
        new("sprint_arm_sensitivity", OptionKind.Float, "1.3", 0.3, 2.0, 0.1, Section: "Movement"),
        new("sprint_speed_multiplier", OptionKind.Float, "1.3", 1.0, 1.5, 0.05, Section: "Movement"),
        new("sprint_turn_slowdown", OptionKind.Float, "1.0", 0.0, 1.0, 0.1, Section: "Movement"),
        new("stairs_steady_speed", OptionKind.Bool, "true", Section: "Movement"),
        new("slide_enabled", OptionKind.Bool, "true", Section: "Movement"),
        new("slide_strength", OptionKind.Float, "1.5", 0.5, 2.0, 0.1, Section: "Movement"),
        new("slide_sound", OptionKind.Choice, "body", Choices: new[] { "body", "wood", "metal", "off" }, Section: "Movement"),

        new("jump_enabled", OptionKind.Bool, "true", Section: "Jump"),
        new("jump_stick_threshold", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Jump"),
        new("jump_height", OptionKind.Float, "100", 20, 120, 5, Section: "Jump"),
        new("jump_sound", OptionKind.Choice, "all", Choices: new[] { "all", "cloth", "off" }, Section: "Jump"),
        new("jump_guard", OptionKind.Bool, "true", Section: "Jump"),
        new("land_crouch", OptionKind.Bool, "true", Section: "Jump"),
        new("land_crouch_height", OptionKind.Float, "2", 1, 6, 0.5, Section: "Jump"),

        new("fall_damage_custom", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_safe_height", OptionKind.Float, "3.5", 1, 10, 0.5, Section: "Fall damage"),
        new("fall_fatal_height", OptionKind.Float, "10", 4, 30, 1, Section: "Fall damage"),
        new("fall_damage_progressive", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_damage_scale", OptionKind.Float, "1.0", 0.0, 2.0, 0.1, Section: "Fall damage"),

        new("cocking", OptionKind.Choice, "manual", Choices: new[] { "manual", "auto" }, Section: "Weapons"),
        new("weapon_grip_reach", OptionKind.Float, "10", 5, 40, 1, Section: "Weapons"),

        new("grenade_row", OptionKind.Bool, "true", Section: "Grenades"),
        new("grenade_row_scale", OptionKind.Float, "0.6", 0.4, 1.0, 0.05, Section: "Grenades"),
        new("grenade_physics", OptionKind.Bool, "true", Section: "Grenades"),
        new("grenade_throw_strength", OptionKind.Float, "1.2", 0.5, 2.0, 0.1, Section: "Grenades"),
        new("teeth_pin_distance", OptionKind.Float, "5", 0, 15, 1, Section: "Grenades"),

        new("grab_aim", OptionKind.Bool, "true", Section: "Grab and drop"),
        new("body_grab_distance", OptionKind.Float, "10", 5, 30, 1, Section: "Grab and drop"),
        new("flick_drop", OptionKind.Bool, "true", Section: "Grab and drop"),
        new("flick_drop_speed", OptionKind.Float, "250", 100, 500, 10, Section: "Grab and drop"),

        new("auto_holster", OptionKind.Bool, "true", Section: "Holsters"),
        new("holster_store_distance", OptionKind.Float, "30", 10, 50, 1, Section: "Holsters"),
        new("holster_nearest", OptionKind.Bool, "true", Section: "Holsters"),
        new("holster_grab_distance", OptionKind.Float, "20", 5, 30, 1, Section: "Holsters"),
        new("holster_below_eyes", OptionKind.Bool, "true", Section: "Holsters"),

        new("syringe_require_trigger", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_trigger_threshold", OptionKind.Float, "0.5", 0.1, 1.0, 0.05, Section: "Syringes"),
        new("syringe_small_holstered", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_holster_scale", OptionKind.Float, "0.5", 0.25, 1.0, 0.05, Section: "Syringes"),

        new("haptics_damage", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_intensity", OptionKind.Float, "1.0", 0.1, 1.0, 0.1, Section: "Haptics"),
        new("haptics_duration", OptionKind.Float, "0.35", 0.05, 1.0, 0.05, Section: "Haptics"),
        new("haptics_directional", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_weapons", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_no_ammo", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_holster_zone", OptionKind.Bool, "true", Section: "Haptics"),

        new("skip_cutscenes", OptionKind.Bool, "true", Section: "Cutscenes"),
        new("skip_hold_time", OptionKind.Float, "1.0", 0.3, 3.0, 0.1, Section: "Cutscenes"),
        new("skip_speed", OptionKind.Float, "12", 2, 15, 1, Section: "Cutscenes"),

        // Not shown as options: the language picker (launcher top bar) and the BASIC / ADVANCED selector of the settings
        // page (and of the in-game menu). "auto": the launcher follows Windows, the in-game menu the game's language.
        new("language", OptionKind.Choice, "auto", Choices: new[] { "auto", "en", "es" }, Section: "Menu"),
        new("menu_view", OptionKind.Choice, "basic", Choices: new[] { "basic", "advanced" }, Section: "Menu"),
        new("menu_hold_time", OptionKind.Float, "1.5", 0.3, 2.0, 0.1, Section: "Menu"),

        new("debug_log", OptionKind.Bool, "false", Section: "Debug"),
    };

    public const string ViewKey = "menu_view";
    public const string LanguageKey = "language";

    /// <summary>Options with their own control instead of a row in the settings grid (and kept by "Defaults").</summary>
    public static bool HasOwnControl(string key) => key is ViewKey or LanguageKey;

    /// <summary>
    /// Basic view: the main options in four categories. Keep in sync with basicLayout in Scripts/menu.lua.
    /// </summary>
    public static readonly (string Section, string[] Keys)[] BasicLayout =
    {
        ("Movement", new[] { "sprint_mode", "crouch_stick", "slide_enabled", "jump_enabled", "fall_damage_custom" }),
        ("Weapons", new[] { "cocking", "grenade_physics" }),
        ("Inventory", new[] { "auto_holster", "grenade_row", "grab_aim", "syringe_require_trigger", "haptics_holster_zone" }),
        ("Other", new[] { "haptics_intensity", "skip_cutscenes" }),
    };

    /// <summary>
    /// Detailed descriptions (paragraphs) per option in a language, from lang/descriptions.&lt;code&gt;.txt (same text the
    /// in-game menu shows): the file installed next to config.ini if there is one, else the copy embedded in the launcher.
    /// Options the language's file does not describe keep the English text.
    /// </summary>
    public static Dictionary<string, List<string>> LoadDescriptions(string configPath, string language)
    {
        var result = new Dictionary<string, List<string>>();
        ReadDescriptions(configPath, "en", result);
        if (language != "en") ReadDescriptions(configPath, language, result);
        return result;
    }

    private static void ReadDescriptions(string configPath, string language, Dictionary<string, List<string>> result)
    {
        string name = $"descriptions.{language}.txt";
        string? text = null;
        try
        {
            var file = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(configPath)!, "lang", name);
            if (File.Exists(file)) text = File.ReadAllText(file);
        }
        catch { }
        if (text == null)
        {
            using var s = typeof(ModConfig).Assembly.GetManifestResourceStream("MOHABPlus.lang." + name);
            if (s != null) using (var r = new StreamReader(s)) text = r.ReadToEnd();
        }
        List<string>? cur = null;
        foreach (var raw in (text ?? "").Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF');
            if (line.Length > 2 && line[0] == '[' && line[^1] == ']') { cur = new List<string>(); result[line[1..^1]] = cur; }
            else if (cur != null && line.Length > 0 && line[0] != '#') cur.Add(line);
        }
    }

    /// <summary>Text shown for a value: the choice label, ON/OFF, or the number.</summary>
    public static string DisplayValue(ModOption o, string value)
    {
        switch (o.Kind)
        {
            case OptionKind.Bool: return Lang.T(value.Equals("true", StringComparison.OrdinalIgnoreCase) ? "value.on" : "value.off");
            case OptionKind.Choice: return o.ChoiceLabel(value);
            default: return value;
        }
    }

    public readonly Dictionary<string, string> Values = new();
    public string Path { get; }

    public ModConfig(string path)
    {
        Path = path;
        foreach (var o in Options) Values[o.Key] = o.Default;
    }

    /// <summary>
    /// Version of the settings written as "config_version=N" (keep in sync with ConfigVersion in Scripts/config.lua).
    /// A config.ini with an older (or no) version is reset to this release's defaults when it is read, and rewritten.
    /// Raise it only in a release whose defaults every player must get, even over their own changes.
    /// </summary>
    public const int ConfigVersion = 2;
    private const string VersionKey = "config_version";

    public void Load()
    {
        if (!File.Exists(Path)) return;
        var read = new Dictionary<string, string>();
        int version = 0;
        foreach (var raw in File.ReadAllLines(Path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.StartsWith(';')) continue;
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            string k = line[..eq].Trim(), v = line[(eq + 1)..].Trim();
            if (k == VersionKey) int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out version);
            else if (Values.ContainsKey(k)) read[k] = v;
        }
        if (version < ConfigVersion)
        {
            // Settings of an older release: this release's defaults instead.
            foreach (var o in Options) Values[o.Key] = o.Default;
            try { Save(); } catch { /* read-only folder: the defaults are still used */ }
            return;
        }
        foreach (var kv in read) Values[kv.Key] = kv.Value;
    }

    public void Save()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# MOHAB Plus configuration. Edited by the launcher and by the in-game menu.");
        sb.AppendLine($"{VersionKey}={ConfigVersion}");
        string? section = null;
        foreach (var o in Options)
        {
            if (o.Section != section) { sb.AppendLine(); sb.AppendLine($"# --- {o.Section} ---"); section = o.Section; }
            sb.AppendLine($"{o.Key}={Values[o.Key]}");
        }
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        File.WriteAllText(Path, sb.ToString());
    }

    public bool GetBool(string k) => Values[k].Equals("true", StringComparison.OrdinalIgnoreCase);
    public double GetFloat(string k) => double.TryParse(Values[k], NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : 0;
    public void Set(string k, bool v) => Values[k] = v ? "true" : "false";
    public void Set(string k, double v) => Values[k] = v.ToString("0.###", CultureInfo.InvariantCulture);
    public void Set(string k, string v) => Values[k] = v;
}
