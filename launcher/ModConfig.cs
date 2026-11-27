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
/// The option list must stay in sync with Scripts/config.lua.
/// </summary>
internal sealed class ModConfig
{
    public static readonly ModOption[] Options =
    {
        new("syringe_require_trigger", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_trigger_threshold", OptionKind.Float, "0.5", 0.1, 1.0, 0.05, Section: "Syringes"),
        new("syringe_small_holstered", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_holster_scale", OptionKind.Float, "0.5", 0.25, 1.0, 0.05, Section: "Syringes"),

        new("grab_aim", OptionKind.Bool, "true", Section: "Grabbing"),
        new("auto_holster", OptionKind.Bool, "true", Section: "Grabbing"),
        new("holster_store_distance", OptionKind.Float, "30", 10, 50, 1, Section: "Grabbing"),
        new("flick_drop", OptionKind.Bool, "true", Section: "Grabbing"),
        new("flick_drop_speed", OptionKind.Float, "250", 100, 500, 10, Section: "Grabbing"),
        new("holster_nearest", OptionKind.Bool, "true", Section: "Grabbing"),
        new("grenade_row", OptionKind.Bool, "true", Section: "Grabbing"),
        new("grenade_row_scale", OptionKind.Float, "0.75", 0.4, 1.0, 0.05, Section: "Grabbing"),
        new("body_grab_distance", OptionKind.Float, "10", 5, 30, 1, Section: "Grabbing"),
        new("holster_grab_distance", OptionKind.Float, "20", 5, 30, 1, Section: "Grabbing"),
        new("weapon_grip_reach", OptionKind.Float, "10", 5, 40, 1, Section: "Grabbing"),
        new("grenade_physics", OptionKind.Bool, "true", Section: "Grabbing"),
        new("grenade_throw_strength", OptionKind.Float, "1.2", 0.5, 2.0, 0.1, Section: "Grabbing"),
        new("teeth_pin_distance", OptionKind.Float, "5", 0, 15, 1, Section: "Grabbing"),
        new("cocking", OptionKind.Choice, "manual", Choices: new[] { "manual", "auto" }, Section: "Grabbing"),
        new("holster_below_eyes", OptionKind.Bool, "true", Section: "Grabbing"),

        new("haptics_damage", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_intensity", OptionKind.Float, "1.0", 0.1, 1.0, 0.1, Section: "Haptics"),
        new("haptics_duration", OptionKind.Float, "0.35", 0.05, 1.0, 0.05, Section: "Haptics"),
        new("haptics_directional", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_weapons", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_no_ammo", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_holster_zone", OptionKind.Bool, "true", Section: "Haptics"),

        new("crouch_stick", OptionKind.Bool, "true", Section: "Crouch"),
        new("crouch_stick_threshold", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Crouch"),
        new("crouch_speed", OptionKind.Float, "0.6", 0.3, 1.0, 0.05, Section: "Crouch"),

        new("jump_enabled", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("jump_stick_threshold", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Jump (experimental)"),
        new("jump_height", OptionKind.Float, "100", 20, 120, 5, Section: "Jump (experimental)"),
        new("jump_sound", OptionKind.Choice, "all", Choices: new[] { "all", "cloth", "off" }, Section: "Jump (experimental)"),
        new("jump_guard", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("land_crouch", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("land_crouch_height", OptionKind.Float, "2", 1, 6, 0.5, Section: "Jump (experimental)"),

        new("fall_damage_custom", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_safe_height", OptionKind.Float, "3.5", 1, 10, 0.5, Section: "Fall damage"),
        new("fall_fatal_height", OptionKind.Float, "10", 4, 30, 1, Section: "Fall damage"),
        new("fall_damage_progressive", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_damage_scale", OptionKind.Float, "1.0", 0.0, 2.0, 0.1, Section: "Fall damage"),

        new("sprint_mode", OptionKind.Choice, "always",
            Choices: new[] { "stick", "arms", "both", "always" }, Section: "Sprint"),
        new("sprint_arm_sensitivity", OptionKind.Float, "1.3", 0.3, 2.0, 0.1, Section: "Sprint"),
        new("sprint_speed_multiplier", OptionKind.Float, "1.3", 1.0, 1.5, 0.05, Section: "Sprint"),
        new("sprint_turn_slowdown", OptionKind.Float, "1.0", 0.0, 1.0, 0.1, Section: "Sprint"),
        new("stairs_steady_speed", OptionKind.Bool, "true", Section: "Sprint"),

        new("slide_enabled", OptionKind.Bool, "true", Section: "Slide"),
        new("slide_strength", OptionKind.Float, "1.5", 0.5, 2.0, 0.1, Section: "Slide"),
        new("slide_sound", OptionKind.Choice, "body", Choices: new[] { "body", "wood", "metal", "off" }, Section: "Slide"),

        new("skip_cutscenes", OptionKind.Bool, "true", Section: "Cutscenes"),
        new("skip_hold_time", OptionKind.Float, "1.0", 0.3, 3.0, 0.1, Section: "Cutscenes"),
        new("skip_speed", OptionKind.Float, "12", 2, 15, 1, Section: "Cutscenes"),

        // Not shown as an option: the BASIC / ADVANCED selector of the settings page (and of the in-game menu).
        new("menu_view", OptionKind.Choice, "basic", Choices: new[] { "basic", "advanced" }, Section: "Menu"),
        new("menu_hold_time", OptionKind.Float, "1.5", 0.3, 2.0, 0.1, Section: "Menu"),

        new("debug_log", OptionKind.Bool, "false", Section: "Debug"),
    };

    public const string ViewKey = "menu_view";

    /// <summary>
    /// Basic view: the main options in three categories. Keep in sync with basicLayout in Scripts/menu.lua.
    /// </summary>
    public static readonly (string Section, string[] Keys)[] BasicLayout =
    {
        ("Movement", new[] { "sprint_mode", "crouch_stick", "slide_enabled", "jump_enabled" }),
        ("Weapons", new[] { "cocking", "auto_holster", "grenade_row", "grenade_physics", "syringe_require_trigger" }),
        ("Comfort", new[] { "haptics_intensity", "haptics_holster_zone", "fall_damage_custom", "skip_cutscenes" }),
    };

    /// <summary>
    /// Detailed descriptions (paragraphs) per option, from descriptions.txt: the file installed next to config.ini if
    /// there is one (same text the in-game menu shows), else the copy embedded in the launcher.
    /// </summary>
    public static Dictionary<string, List<string>> LoadDescriptions(string configPath)
    {
        string? text = null;
        try
        {
            var file = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(configPath)!, "descriptions.txt");
            if (File.Exists(file)) text = File.ReadAllText(file);
        }
        catch { }
        if (text == null)
        {
            using var s = typeof(ModConfig).Assembly.GetManifestResourceStream("MOHABPlus.descriptions.txt");
            if (s != null) using (var r = new StreamReader(s)) text = r.ReadToEnd();
        }
        var result = new Dictionary<string, List<string>>();
        List<string>? cur = null;
        foreach (var raw in (text ?? "").Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length > 2 && line[0] == '[' && line[^1] == ']') { cur = new List<string>(); result[line[1..^1]] = cur; }
            else if (cur != null && line.Length > 0 && line[0] != '#') cur.Add(line);
        }
        return result;
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

    public void Load()
    {
        if (!File.Exists(Path)) return;
        foreach (var raw in File.ReadAllLines(Path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.StartsWith(';')) continue;
            int eq = line.IndexOf('=');
            if (eq <= 0) continue;
            string k = line[..eq].Trim(), v = line[(eq + 1)..].Trim();
            if (Values.ContainsKey(k)) Values[k] = v;
        }
    }

    public void Save()
    {
        var sb = new StringBuilder();
        sb.AppendLine("# MOHAB Plus configuration. Edited by the launcher and by the in-game menu.");
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
