-- Shared key=value configuration (also edited by the launcher, see launcher/ModConfig.cs).
local M = {}

M.defaults = {
    syringe_require_trigger = true,
    syringe_trigger_threshold = 0.5,
    syringe_small_holstered = true,
    syringe_holster_scale = 0.5,
    syringe_grab_distance = 0.25,

    holster_below_eyes = true,    -- no holster grabs with the hand above the eyes (hats/helmets)
    weapon_grip_reach = 15,       -- cm from the free hand to a weapon's off-hand grip
    weapon_empty_click = false,   -- dry-fire click when the second hand grabs an empty weapon

    haptics_damage = true,
    haptics_intensity = 1.0,
    haptics_duration = 0.35,
    haptics_directional = true,
    haptics_weapons = true,
    haptics_empty = true,         -- two knocks when the second hand grabs an empty weapon
    haptics_no_ammo = true,       -- two taps when pressing grip at the magazine pouch with no ammo left

    crouch_stick = true,
    crouch_stick_threshold = 0.95,

    jump_enabled = true,            -- EXPERIMENTAL: turn stick up while standing
    jump_height = 75,               -- cm
    jump_sound = "all",             -- "all" (voice + cloth) | "cloth" | "off"
    jump_guard = true,              -- invisible level barriers become infinitely tall (anything visible can be climbed)

    sprint_mode = "both",           -- "stick" | "arms" | "both"
    sprint_arm_sensitivity = 1.3,
    sprint_speed_multiplier = 1.4,
    sprint_turn_slowdown = 1.0,     -- 0..1: speed lost on sharp turns while sprinting (0 = off)

    slide_enabled = true,
    slide_strength = 1.5,
    slide_sound = "body",           -- "body" | "wood" | "metal" | "off"

    skip_cutscenes = true,
    skip_hold_time = 1.0,
    skip_speed = 12,               -- fast-forward speed for dialogue scenes

    menu_hold_time = 1.5,
    debug_log = false,
}

-- Order + sections used when writing the file (keep in sync with the launcher).
M.order = {
    { "Syringes", { "syringe_require_trigger", "syringe_trigger_threshold", "syringe_small_holstered", "syringe_holster_scale", "syringe_grab_distance" } },
    { "Weapons", { "weapon_grip_reach", "holster_below_eyes", "weapon_empty_click" } },
    { "Haptics", { "haptics_damage", "haptics_intensity", "haptics_duration", "haptics_directional", "haptics_weapons", "haptics_empty", "haptics_no_ammo" } },
    { "Crouch", { "crouch_stick", "crouch_stick_threshold" } },
    { "Jump (experimental)", { "jump_enabled", "jump_height", "jump_sound", "jump_guard" } },
    { "Sprint", { "sprint_mode", "sprint_arm_sensitivity", "sprint_speed_multiplier", "sprint_turn_slowdown" } },
    { "Slide", { "slide_enabled", "slide_strength", "slide_sound" } },
    { "Cutscenes", { "skip_cutscenes", "skip_hold_time", "skip_speed" } },
    { "Menu", { "menu_hold_time" } },
    { "Debug", { "debug_log" } },
}

M.values = {}
for k, v in pairs(M.defaults) do M.values[k] = v end

local path = nil
local lastText = nil

local function parseValue(key, s)
    local def = M.defaults[key]
    if type(def) == "boolean" then
        s = s:lower()
        return s == "true" or s == "1" or s == "on" or s == "yes"
    elseif type(def) == "number" then
        return tonumber(s) or def
    end
    return s
end

local function fmt(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then
        local s = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
        return s
    end
    return tostring(v)
end

function M.init(modDir)
    path = modDir .. "\\config.ini"
    if not M.reload() then M.save() end
end

-- Returns true if the file existed. Only re-parses when the content changed.
function M.reload()
    local f = io.open(path, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    if text == lastText then return true end
    lastText = text
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and M.defaults[k] ~= nil then M.values[k] = parseValue(k, v) end
    end
    return true
end

function M.save()
    local lines = { "# MOHAB Plus configuration. Edited by the launcher and by the in-game menu." }
    for _, sec in ipairs(M.order) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = "# --- " .. sec[1] .. " ---"
        for _, k in ipairs(sec[2]) do
            lines[#lines + 1] = k .. "=" .. fmt(M.values[k])
        end
    end
    local text = table.concat(lines, "\n") .. "\n"
    local f = io.open(path, "w")
    if f then
        f:write(text)
        f:close()
        lastText = text
    end
end

-- Master switch (in-game menu only, never saved): false = every feature behaves as in the original game, to compare
-- with and without the mod. The settings themselves are kept; M.get just answers with the "feature off" value of each
-- option that changes the game, so every module takes its own switched-off path (and restores what it changed).
-- Modules without an off option (sprint speed/direction rules, two-handed grip) are skipped by main.lua.
M.enabled = true
M.vanilla = {
    syringe_require_trigger = false,
    syringe_small_holstered = false,
    syringe_grab_distance = 1.0,
    holster_below_eyes = false,
    weapon_empty_click = false,
    haptics_damage = false,
    haptics_weapons = false,
    haptics_empty = false,
    haptics_no_ammo = false,
    crouch_stick = false,
    jump_enabled = false,
    jump_guard = false,
    sprint_mode = "stick",
    sprint_speed_multiplier = 1.0,
    sprint_turn_slowdown = 0,
    slide_enabled = false,
    skip_cutscenes = false,
}

function M.get(k)
    if not M.enabled then
        local v = M.vanilla[k]
        if v ~= nil then return v end
    end
    return M.values[k]
end
-- The configured value, whatever the master switch says (menu display / editing).
function M.raw(k) return M.values[k] end
function M.set(k, v) M.values[k] = v end

return M
