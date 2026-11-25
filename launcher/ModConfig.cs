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
        new("syringe_require_trigger", "Syringe: require trigger to inject", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_trigger_threshold", "Syringe: trigger threshold", OptionKind.Float, "0.5", 0.1, 1.0, 0.05, Section: "Syringes"),
        new("syringe_small_holstered", "Syringe: smaller when on the sleeve", OptionKind.Bool, "true", Section: "Syringes"),
        new("syringe_holster_scale", "Syringe: sleeve scale", OptionKind.Float, "0.5", 0.25, 1.0, 0.05, Section: "Syringes"),

        new("manual_holster", "Grabbing: manual holsters (letting go of a weapon drops it; take it to a free holster to put it away)", OptionKind.Bool, "true", Section: "Grabbing"),
        new("holster_store_distance", "Grabbing: manual holsters, distance to the holster to put a weapon away (cm)", OptionKind.Float, "30", 10, 50, 1, Section: "Grabbing"),
        new("grenade_row", "Grabbing: every grenade you carry is shown on your chest (take the one you want)", OptionKind.Bool, "true", Section: "Grabbing"),
        new("grenade_row_scale", "Grabbing: size of the grenades on the chest", OptionKind.Float, "0.75", 0.4, 1.0, 0.05, Section: "Grabbing"),
        new("body_grab_distance", "Grabbing: distance to take grenades, objects and syringes you carry (cm)", OptionKind.Float, "10", 5, 30, 1, Section: "Grabbing"),
        new("holster_grab_distance", "Grabbing: distance to take a weapon from a holster, back weapons excluded (cm)", OptionKind.Float, "25", 5, 30, 1, Section: "Grabbing"),
        new("weapon_grip_reach", "Grabbing: second hand distance to a weapon's front grip (cm)", OptionKind.Float, "10", 5, 40, 1, Section: "Grabbing"),
        new("teeth_pin_distance", "Grabbing: how close a held grenade must get to your mouth to pull its pin with your teeth (cm; game 10, 0 = never)", OptionKind.Float, "5", 0, 15, 1, Section: "Grabbing"),
        new("cocking", "Grabbing: cocking - manual (work the bolt / slide yourself) or auto (the game does it, original)", OptionKind.Choice, "manual", Choices: new[] { "manual", "auto" }, Section: "Grabbing"),
        new("holster_below_eyes", "Grabbing: no holster grab with the hand above the eyes", OptionKind.Bool, "true", Section: "Grabbing"),

        new("haptics_damage", "Haptics on damage", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_intensity", "Haptics: intensity", OptionKind.Float, "1.0", 0.1, 1.0, 0.1, Section: "Haptics"),
        new("haptics_duration", "Haptics: duration (s)", OptionKind.Float, "0.35", 0.05, 1.0, 0.05, Section: "Haptics"),
        new("haptics_directional", "Haptics: stronger on the side of the hit", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_weapons", "Haptics when reloading / opening weapons", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_no_ammo", "Haptics when pressing grip at the magazine pouch with no ammo left", OptionKind.Bool, "true", Section: "Haptics"),
        new("haptics_holster_zone", "Haptics: light tap when an empty hand can take a weapon or item you carry", OptionKind.Bool, "true", Section: "Haptics"),

        new("crouch_stick", "Crouch with turn stick (down / up)", OptionKind.Bool, "true", Section: "Crouch"),
        new("crouch_stick_threshold", "Crouch: how far the stick must be pushed to crouch / stand up", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Crouch"),
        new("crouch_speed", "Crouch: walking speed while crouched (x normal)", OptionKind.Float, "0.6", 0.3, 1.0, 0.05, Section: "Crouch"),

        new("jump_enabled", "Jump with turn stick up (while standing)", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("jump_stick_threshold", "Jump: how far the stick must be pushed up", OptionKind.Float, "0.7", 0.3, 0.95, 0.05, Section: "Jump (experimental)"),
        new("jump_height", "Jump: height (cm)", OptionKind.Float, "100", 20, 120, 5, Section: "Jump (experimental)"),
        new("jump_sound", "Jump: sounds", OptionKind.Choice, "all", Choices: new[] { "all", "cloth", "off" }, Section: "Jump (experimental)"),
        new("jump_guard", "Jump: stay inside the level (furniture can still be climbed)", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("land_crouch", "Hard landings: bend down on landing, with a grunt and a jolt", OptionKind.Bool, "true", Section: "Jump (experimental)"),
        new("land_crouch_height", "Hard landings: from a fall of (m)", OptionKind.Float, "2", 1, 6, 0.5, Section: "Jump (experimental)"),

        new("fall_damage_custom", "Custom fall damage (off = the game's rules)", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_safe_height", "Fall damage: safe height (m)", OptionKind.Float, "3.5", 1, 10, 0.5, Section: "Fall damage"),
        new("fall_fatal_height", "Fall damage: fatal height (m)", OptionKind.Float, "10", 4, 30, 1, Section: "Fall damage"),
        new("fall_damage_progressive", "Fall damage: grows with the height of the fall", OptionKind.Bool, "true", Section: "Fall damage"),
        new("fall_damage_scale", "Fall damage: amount (x the game's)", OptionKind.Float, "1.0", 0.0, 2.0, 0.1, Section: "Fall damage"),

        new("sprint_mode", "Sprint mode (always sprint: you only walk while you hold a weapon up or shoot)", OptionKind.Choice, "both",
            Choices: new[] { "stick", "arms", "both", "always" }, Section: "Sprint",
            ChoiceLabels: new[] { "Stick click", "Arm swing", "Stick + arms", "Always sprint" }),
        new("sprint_arm_sensitivity", "Sprint: arm swing sensitivity", OptionKind.Float, "1.3", 0.3, 2.0, 0.1, Section: "Sprint"),
        new("sprint_speed_multiplier", "Sprint: max speed multiplier", OptionKind.Float, "1.3", 1.0, 1.5, 0.05, Section: "Sprint"),
        new("sprint_turn_slowdown", "Sprint: slow down on sharp turns (0 = off)", OptionKind.Float, "1.0", 0.0, 1.0, 0.1, Section: "Sprint"),

        new("slide_enabled", "Slide when crouching while sprinting", OptionKind.Bool, "true", Section: "Slide"),
        new("slide_strength", "Slide: length", OptionKind.Float, "1.5", 0.5, 2.0, 0.1, Section: "Slide"),
        new("slide_sound", "Slide: sound", OptionKind.Choice, "body", Choices: new[] { "body", "wood", "metal", "off" }, Section: "Slide"),

        new("skip_cutscenes", "Skip cutscenes (hold both triggers + grips)", OptionKind.Bool, "true", Section: "Cutscenes"),
        new("skip_hold_time", "Skip: hold time (s)", OptionKind.Float, "1.0", 0.3, 3.0, 0.1, Section: "Cutscenes"),
        new("skip_speed", "Skip: dialogue fast-forward speed (x)", OptionKind.Float, "12", 2, 15, 1, Section: "Cutscenes"),

        new("menu_hold_time", "Menu: hold time to open (s)", OptionKind.Float, "1.5", 0.3, 2.0, 0.1, Section: "Menu"),

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
