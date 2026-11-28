-- Shared key=value configuration (also edited by the launcher, see launcher/ModConfig.cs).
local M = {}

M.defaults = {
    syringe_require_trigger = true,
    syringe_trigger_threshold = 0.5,
    syringe_small_holstered = true,
    syringe_holster_scale = 0.5,

    holster_below_eyes = true,    -- no holster grabs with the hand above the eyes (hats/helmets)
    auto_holster = true,          -- false: a released weapon falls, unless the hand is at a free holster that fits it
    holster_store_distance = 30,  -- cm: how close to the holster the hand must be to put a weapon away
    flick_drop = true,            -- automatic holsters: letting go with a sharp flick drops the weapon instead
    flick_drop_speed = 250,       -- cm/s (hand relative to the body) that counts as a flick
    holster_nearest = true,       -- automatic holsters: a released weapon flies to the free holster nearest the hand
    grenade_row = true,           -- every grenade you carry is drawn on the chest and can be taken
    grenade_row_scale = 0.6,      -- size of the grenades on the chest
    grab_aim = true,              -- an empty hand takes what its guide points at (game: see grabaim.lua)
    weapon_grip_reach = 10,       -- cm from the free hand to a weapon's off-hand grip
    body_grab_distance = 10,      -- cm: taking things you carry (grenades, objects, syringes on the sleeves)
    holster_grab_distance = 20,   -- cm: taking a weapon from a holster (not back / shoulder weapons: game's distance)
    grenade_physics = true,       -- realistic throws and bounces (game: twice the hand speed, sticky floors)
    grenade_throw_strength = 1.2, -- x the hand's speed when a grenade is let go of (1.0 = real; 1.2 feels better in play)
    teeth_pin_distance = 5,       -- cm: a held grenade this close to the mouth loses its pin (game: 10; 0 = never)
    cocking = "manual",           -- "manual": pull the bolt / slide yourself | "auto": the game finishes it for you

    haptics_damage = true,
    haptics_intensity = 1.0,
    haptics_duration = 0.35,
    haptics_directional = true,
    haptics_weapons = true,
    haptics_no_ammo = true,       -- three taps when pressing grip at the magazine pouch with no ammo left
    haptics_holster_zone = true,  -- light tap when an empty hand can take something you carry

    crouch_stick = true,
    crouch_stick_threshold = 0.7,   -- 0..1: how far the stick must be pushed to crouch / stand up
    crouch_speed = 0.6,             -- walking speed while crouched (x normal walking); the game has its own multiplier

    jump_enabled = true,            -- EXPERIMENTAL: turn stick up while standing
    jump_stick_threshold = 0.7,     -- 0..1: how far the stick must be pushed up to jump
    jump_height = 100,              -- cm
    jump_sound = "all",             -- "all" (voice + cloth) | "cloth" | "off"
    jump_guard = true,              -- invisible level barriers become infinitely tall (anything visible can be climbed)
    land_crouch = true,             -- hard landings: bend down, grunt and jolt the controllers
    land_crouch_height = 2.0,       -- m: falls from at least this high (from the top of a jump) are hard landings

    fall_damage_custom = true,      -- false = the game's rules (flat damage from ~3.3 m, death from ~10 m)
    fall_safe_height = 3.5,         -- m: shorter drops don't hurt
    fall_fatal_height = 10,         -- m: longer drops kill
    fall_damage_progressive = true, -- damage grows with the height instead of the game's flat amount
    fall_damage_scale = 1.0,        -- x the game's damage

    sprint_mode = "always",         -- "stick" | "arms" | "both" (stick + arms) | "always"
    sprint_arm_sensitivity = 1.3,
    sprint_speed_multiplier = 1.3,
    sprint_turn_slowdown = 1.0,     -- 0..1: speed lost on sharp turns while sprinting (0 = off)
    stairs_steady_speed = true,     -- same speed along stairs / ramps as on flat ground (the engine is faster there)

    slide_enabled = true,
    slide_strength = 1.5,
    slide_sound = "body",           -- "body" | "wood" | "metal" | "off"

    skip_cutscenes = true,
    skip_hold_time = 1.0,
    skip_speed = 12,               -- fast-forward speed for dialogue scenes

    language = "auto",              -- "auto" (in game: the game's language) | "en" | "es" (lang/<code>.txt)
    menu_view = "basic",            -- "basic" (the main options) | "advanced" (every option); in-game menu and launcher
    menu_hold_time = 1.5,
    debug_log = false,
}

-- Order + sections used when writing the file (keep in sync with the launcher).
M.order = {
    { "Syringes", { "syringe_require_trigger", "syringe_trigger_threshold", "syringe_small_holstered", "syringe_holster_scale" } },
    { "Grabbing", { "grab_aim", "auto_holster", "holster_store_distance", "flick_drop", "flick_drop_speed", "holster_nearest", "grenade_row", "grenade_row_scale", "body_grab_distance", "holster_grab_distance", "weapon_grip_reach", "grenade_physics", "grenade_throw_strength", "teeth_pin_distance", "cocking", "holster_below_eyes" } },
    { "Haptics", { "haptics_damage", "haptics_intensity", "haptics_duration", "haptics_directional", "haptics_weapons", "haptics_no_ammo", "haptics_holster_zone" } },
    { "Crouch", { "crouch_stick", "crouch_stick_threshold", "crouch_speed" } },
    { "Jump (experimental)", { "jump_enabled", "jump_stick_threshold", "jump_height", "jump_sound", "jump_guard", "land_crouch", "land_crouch_height" } },
    { "Fall damage", { "fall_damage_custom", "fall_safe_height", "fall_fatal_height", "fall_damage_progressive", "fall_damage_scale" } },
    { "Sprint", { "sprint_mode", "sprint_arm_sensitivity", "sprint_speed_multiplier", "sprint_turn_slowdown", "stairs_steady_speed" } },
    { "Slide", { "slide_enabled", "slide_strength", "slide_sound" } },
    { "Cutscenes", { "skip_cutscenes", "skip_hold_time", "skip_speed" } },
    { "Menu", { "language", "menu_view", "menu_hold_time" } },
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

-- Detailed option descriptions (lang/descriptions.<language>.txt next to config.ini, shared with the launcher):
-- "[key]" followed by one paragraph per line. Returns key -> list of paragraphs, English for an option the language's
-- file does not describe; re-read when a file changes.
local function readDescriptions(path, into)
    local f = io.open(path, "r")
    if not f then return "" end
    local text = f:read("*a")
    f:close()
    local cur = nil
    for raw in text:gmatch("[^\r\n]+") do
        local line = raw:match("^%s*(.-)%s*$")
        if line:sub(1, 3) == "\239\187\191" then line = line:sub(4) end   -- UTF-8 BOM
        local k = line:match("^%[([%w_]+)%]$")
        if k then
            cur = {}
            into[k] = cur
        elseif cur and line ~= "" and line:sub(1, 1) ~= "#" then
            cur[#cur + 1] = line
        end
    end
    return text
end
local descSig, descs = nil, {}
function M.descriptions(lang)
    if not M.dir then return descs end
    lang = lang or "en"
    local t = {}
    local sig = lang .. "|" .. readDescriptions(M.dir .. "\\lang\\descriptions.en.txt", t)
    if lang ~= "en" then sig = sig .. readDescriptions(M.dir .. "\\lang\\descriptions." .. lang .. ".txt", t) end
    if sig ~= descSig then descSig, descs = sig, t end
    return descs
end

function M.init(modDir)
    M.dir = modDir
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
    body_grab_distance = -1,        -- -1 = the game's distances
    holster_grab_distance = -1,
    grab_aim = false,
    auto_holster = true,
    flick_drop = false,
    holster_nearest = false,
    grenade_row = false,
    teeth_pin_distance = -1,        -- -1 = the game's distance
    grenade_physics = false,
    holster_below_eyes = false,
    cocking = "auto",
    haptics_damage = false,
    haptics_weapons = false,
    haptics_no_ammo = false,
    haptics_holster_zone = false,
    crouch_stick = false,
    crouch_speed = 0,               -- 0 = the game's own crouch speed
    jump_enabled = false,
    jump_guard = false,
    land_crouch = false,
    fall_damage_custom = false,
    sprint_mode = "stick",
    sprint_speed_multiplier = 1.0,
    sprint_turn_slowdown = 0,
    stairs_steady_speed = false,
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
