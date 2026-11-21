-- Shared key=value configuration (also edited by the launcher, see launcher/ModConfig.cs).
local M = {}

M.defaults = {
    syringe_require_trigger = true,
    syringe_trigger_threshold = 0.5,
    syringe_small_holstered = true,
    syringe_holster_scale = 0.5,

    haptics_damage = true,
    haptics_intensity = 1.0,
    haptics_duration = 0.25,
    haptics_directional = true,

    crouch_stick = true,
    crouch_stick_threshold = 0.7,

    sprint_mode = "stick",          -- "stick" | "arms" | "both"
    sprint_arm_sensitivity = 1.0,
    sprint_speed_multiplier = 1.5,

    menu_hold_time = 0.8,
    debug_log = false,
}

-- Order + sections used when writing the file (keep in sync with the launcher).
M.order = {
    { "Syringes", { "syringe_require_trigger", "syringe_trigger_threshold", "syringe_small_holstered", "syringe_holster_scale" } },
    { "Haptics", { "haptics_damage", "haptics_intensity", "haptics_duration", "haptics_directional" } },
    { "Crouch", { "crouch_stick", "crouch_stick_threshold" } },
    { "Sprint", { "sprint_mode", "sprint_arm_sensitivity", "sprint_speed_multiplier" } },
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

function M.get(k) return M.values[k] end
function M.set(k, v) M.values[k] = v end

return M
