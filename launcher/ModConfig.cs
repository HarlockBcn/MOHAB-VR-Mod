using System.Globalization;
using System.Text;

namespace MOHABPlus;

internal enum OptionKind { Bool, Float, Choice }

internal sealed record ModOption(
    string Key, string Label, OptionKind Kind, string Default,
    double Min = 0, double Max = 1, double Step = 0.1, string[]? Choices = null, string Section = "General");

/// <summary>
/// Reads/writes the key=value config shared with the Lua mod (ue4ss/Mods/MOHABPlus/config.ini).
/// The option list must stay in sync with Scripts/config.lua.
/// </summary>
internal sealed class ModConfig
{
    public static readonly ModOption[] Options =
    {
        new("syringe_require_trigger", "Syringe: require trigger to inject", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_trigger_threshold", "Syringe: trigger threshold", OptionKind.Float, "0.5", 0.1, 1.0, 0.05, Section: "Syringes"),
        new("syringe_small_holstered", "Syringe: smaller when on the sleeve", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_holster_scale", "Syringe: sleeve scale", OptionKind.Float, "0.5", 0.25, 1.0, 0.05, Section: "Syringes"),

        new("syringe_grab_distance", "Syringe: sleeve grab distance", OptionKind.Float, "0.25", 0.25, 1.0, 0.05, Section: "Syringes"),

        new("weapon_grip_reach", "Weapons: second hand grab distance (cm)", OptionKind.Float, "15", 5, 40, 1, Section: "Weapons"),
        new("holster_head_zone", "Weapons: no holster grab over the head (cm, 0 = off)", OptionKind.Float, "30", 0, 30, 1, Section: "Weapons"),

        new("haptics_damage", "Haptics on damage", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_intensity", "Haptics: intensity", OptionKind.Float, "1.0", 0.1, 1.0, 0.1, Section: "Haptics"),
        new("haptics_duration", "Haptics: duration (s)", OptionKind.Float, "0.35", 0.05, 1.0, 0.05, Section: "Haptics"),
        new("haptics_directional", "Haptics: stronger on the side of the hit", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_weapons", "Haptics when reloading / opening weapons", OptionKind.Bool, "true", Section: "Haptics"),

        new("crouch_stick", "Crouch with turn stick (down / up)", OptionKind.Bool, "true", Section: "Crouch"),
        new("crouch_stick_threshold", "Crouch: stick threshold", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Crouch"),

        new("sprint_mode", "Sprint mode", OptionKind.Choice, "both", Choices: new[] { "stick", "arms", "both" }, Section: "Sprint"),
        new("sprint_arm_sensitivity", "Sprint: arm swing sensitivity", OptionKind.Float, "1.0", 0.3, 2.0, 0.1, Section: "Sprint"),
        new("sprint_speed_multiplier", "Sprint: max speed multiplier", OptionKind.Float, "1.5", 1.0, 1.5, 0.05, Section: "Sprint"),

        new("slide_enabled", "Slide when crouching while sprinting", OptionKind.Bool, "true", Section: "Slide"),
        new("slide_strength", "Slide: length", OptionKind.Float, "1.5", 0.5, 2.0, 0.1, Section: "Slide"),
        new("slide_sound", "Slide: sound", OptionKind.Choice, "body", Choices: new[] { "body", "wood", "metal", "off" }, Section: "Slide"),

        new("skip_cutscenes", "Skip cutscenes (hold both triggers + grips)", OptionKind.Bool, "true", Section: "Cutscenes"),
        new("skip_hold_time", "Skip: hold time (s)", OptionKind.Float, "1.0", 0.3, 3.0, 0.1, Section: "Cutscenes"),
        new("skip_speed", "Skip: dialogue fast-forward speed (x)", OptionKind.Float, "12", 2, 15, 1, Section: "Cutscenes"),

        new("menu_hold_time", "Menu: hold time to open (s)", OptionKind.Float, "1.0", 0.3, 2.0, 0.1, Section: "Menu"),

        new("debug_log", "Verbose logging to UE4SS.log", OptionKind.Bool, "false", Section: "Debug"),
    };

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
