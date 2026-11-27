using System.Globalization;
using System.Text;

namespace MOHABPlus;

internal enum OptionKind { Bool, Float, Choice }

internal sealed record ModOption(
    string Key, string Label, OptionKind Kind, string Default,
    double Min = 0, double Max = 1, double Step = 0.1, string[]? Choices = null, string Section = "General",
    string[]? ChoiceLabels = null);   // text shown for each choice (default: the value itself)

/// <summary>
/// Reads/writes the key=value config shared with the Lua mod (ue4ss/Mods/MOHABPlus/config.ini).
/// The option list must stay in sync with Scripts/config.lua.
/// </summary>
internal sealed class ModConfig
{
    public static readonly ModOption[] Options =
    {
        new("syringe_require_trigger", "Trigger to inject", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_trigger_threshold", "Trigger threshold", OptionKind.Float, "0.5", 0.1, 1.0, 0.05, Section: "Syringes"),
        new("syringe_small_holstered", "Smaller on the sleeve", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_holster_scale", "Sleeve scale", OptionKind.Float, "0.5", 0.25, 1.0, 0.05, Section: "Syringes"),

        new("grab_aim", "Grab what you point at", OptionKind.Bool, "true", Section: "Grabbing"),
        new("auto_holster", "Automatic holsters", OptionKind.Bool, "true", Section: "Grabbing"),
        new("holster_store_distance", "Put away distance (cm)", OptionKind.Float, "30", 10, 50, 1, Section: "Grabbing"),
        new("flick_drop", "Flick to drop", OptionKind.Bool, "true", Section: "Grabbing"),
        new("flick_drop_speed", "Flick speed (cm/s)", OptionKind.Float, "250", 100, 500, 10, Section: "Grabbing"),
        new("holster_nearest", "Nearest holster", OptionKind.Bool, "true", Section: "Grabbing"),
        new("grenade_row", "All grenades on chest", OptionKind.Bool, "true", Section: "Grabbing"),
        new("grenade_row_scale", "Chest grenade size", OptionKind.Float, "0.75", 0.4, 1.0, 0.05, Section: "Grabbing"),
        new("body_grab_distance", "Inventory grab distance (cm)", OptionKind.Float, "10", 5, 30, 1, Section: "Grabbing"),
        new("holster_grab_distance", "Holster grab distance (cm)", OptionKind.Float, "20", 5, 30, 1, Section: "Grabbing"),
        new("weapon_grip_reach", "Second hand reach (cm)", OptionKind.Float, "10", 5, 40, 1, Section: "Grabbing"),
        new("grenade_physics", "Realistic grenade throws", OptionKind.Bool, "true", Section: "Grabbing"),
        new("grenade_throw_strength", "Grenade throw strength (x hand speed)", OptionKind.Float, "1.2", 0.5, 2.0, 0.1, Section: "Grabbing"),
        new("teeth_pin_distance", "Pull pin with teeth (cm, 0 = never)", OptionKind.Float, "5", 0, 15, 1, Section: "Grabbing"),
        new("cocking", "Cocking", OptionKind.Choice, "manual", Choices: new[] { "manual", "auto" }, Section: "Grabbing",
            ChoiceLabels: new[] { "Manual", "Automatic" }),
        new("holster_below_eyes", "No holster grab above eyes", OptionKind.Bool, "true", Section: "Grabbing"),

        new("haptics_damage", "Vibrate on damage", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_intensity", "Vibration intensity", OptionKind.Float, "1.0", 0.1, 1.0, 0.1, Section: "Haptics"),
        new("haptics_duration", "Damage duration (s)", OptionKind.Float, "0.35", 0.05, 1.0, 0.05, Section: "Haptics"),
        new("haptics_directional", "Stronger on hit side", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_weapons", "Vibrate when reloading", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_no_ammo", "Vibrate when out of ammo", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_holster_zone", "Vibrate at holsters", OptionKind.Bool, "true", Section: "Haptics"),

        new("crouch_stick", "Crouch with turn stick", OptionKind.Bool, "true", Section: "Crouch"),
        new("crouch_stick_threshold", "Crouch stick threshold", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Crouch"),
        new("crouch_speed", "Crouched speed (x walking)", OptionKind.Float, "0.6", 0.3, 1.0, 0.05, Section: "Crouch"),

        new("jump_enabled", "Jump (experimental)", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("jump_stick_threshold", "Jump stick threshold", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Jump (experimental)"),
        new("jump_height", "Jump height (cm)", OptionKind.Float, "100", 20, 120, 5, Section: "Jump (experimental)"),
        new("jump_sound", "Jump sounds", OptionKind.Choice, "all", Choices: new[] { "all", "cloth", "off" }, Section: "Jump (experimental)",
            ChoiceLabels: new[] { "Voice + cloth", "Cloth only", "Off" }),
        new("jump_guard", "Stay inside the level", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("land_crouch", "Hard landings", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("land_crouch_height", "Hard landing from (m)", OptionKind.Float, "2", 1, 6, 0.5, Section: "Jump (experimental)"),

        new("fall_damage_custom", "Custom fall damage", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_safe_height", "Safe height (m)", OptionKind.Float, "3.5", 1, 10, 0.5, Section: "Fall damage"),
        new("fall_fatal_height", "Fatal height (m)", OptionKind.Float, "10", 4, 30, 1, Section: "Fall damage"),
        new("fall_damage_progressive", "Damage grows with height", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_damage_scale", "Damage amount (x the game's)", OptionKind.Float, "1.0", 0.0, 2.0, 0.1, Section: "Fall damage"),

        new("sprint_mode", "Sprint", OptionKind.Choice, "always",
            Choices: new[] { "stick", "arms", "both", "always" }, Section: "Sprint",
            ChoiceLabels: new[] { "Stick click", "Arm swing", "Stick + arms", "Always sprint" }),
        new("sprint_arm_sensitivity", "Arm swing sensitivity", OptionKind.Float, "1.3", 0.3, 2.0, 0.1, Section: "Sprint"),
        new("sprint_speed_multiplier", "Sprint speed (x original)", OptionKind.Float, "1.3", 1.0, 1.5, 0.05, Section: "Sprint"),
        new("sprint_turn_slowdown", "Slow down on sharp turns (0 = off)", OptionKind.Float, "1.0", 0.0, 1.0, 0.1, Section: "Sprint"),
        new("stairs_steady_speed", "Steady speed on stairs", OptionKind.Bool, "true", Section: "Sprint"),

        new("slide_enabled", "Slide", OptionKind.Bool, "true", Section: "Slide"),
        new("slide_strength", "Slide length", OptionKind.Float, "1.5", 0.5, 2.0, 0.1, Section: "Slide"),
        new("slide_sound", "Slide sound", OptionKind.Choice, "body", Choices: new[] { "body", "wood", "metal", "off" }, Section: "Slide",
            ChoiceLabels: new[] { "Body", "Wood scrape", "Metal scrape", "Off" }),

        new("skip_cutscenes", "Skip cutscenes", OptionKind.Bool, "true", Section: "Cutscenes"),
        new("skip_hold_time", "Skip hold time (s)", OptionKind.Float, "1.0", 0.3, 3.0, 0.1, Section: "Cutscenes"),
        new("skip_speed", "Dialogue fast-forward (x)", OptionKind.Float, "12", 2, 15, 1, Section: "Cutscenes"),

        // Not shown as an option: the BASIC / ADVANCED selector of the settings page (and of the in-game menu).
        new("menu_view", "Menu view", OptionKind.Choice, "basic", Choices: new[] { "basic", "advanced" }, Section: "Menu"),
        new("menu_hold_time", "Menu hold time to open (s)", OptionKind.Float, "1.5", 0.3, 2.0, 0.1, Section: "Menu"),

        new("debug_log", "Verbose logging to UE4SS.log", OptionKind.Bool, "false", Section: "Debug"),
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
            case OptionKind.Bool: return value.Equals("true", StringComparison.OrdinalIgnoreCase) ? "ON" : "OFF";
            case OptionKind.Choice:
                int i = Array.IndexOf(o.Choices!, value);
                return i >= 0 && o.ChoiceLabels != null ? o.ChoiceLabels[i] : value;
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
