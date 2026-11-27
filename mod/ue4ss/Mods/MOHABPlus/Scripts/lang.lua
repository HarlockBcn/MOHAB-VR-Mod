-- Texts of the in-game menu in the chosen language (lang/<code>.txt next to config.ini, shared with the launcher:
-- see launcher/Lang.cs). Format: "key = text", "#" comments, "\n" = new line, {0} {1}... = arguments.
-- English (en.txt) is the reference: a key missing from another language is taken from it, and a key missing
-- everywhere shows as the key itself.
local M = {}

local dir = nil
local code = nil
local texts = {}

local function readFile(path, into)
    local f = io.open(path, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end   -- UTF-8 BOM
    for raw in text:gmatch("[^\r\n]+") do
        local k, v = raw:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if k and raw:match("^%s*#") == nil then into[k] = v:gsub("\\n", "\n") end
    end
    return true
end

function M.init(modDir) dir = modDir end

-- Loads a language (English if it has no file). Only reads the files when the language changes.
function M.setLanguage(c)
    c = (c or "en"):lower()
    if c == code then return end
    code = c
    local t = {}
    if dir then
        readFile(dir .. "\\lang\\en.txt", t)
        if c ~= "en" then readFile(dir .. "\\lang\\" .. c .. ".txt", t) end
    end
    texts = t
end

function M.language() return code end

-- The game's language ("es", "fr"...; Kismet GetCurrentLanguage), nil while it can't be read.
local gameCode = nil
function M.gameLanguage()
    if gameCode then return gameCode end
    local ok, s = pcall(function()
        local lib = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
        if not lib or not lib:IsValid() then return nil end
        local v = lib:GetCurrentLanguage()
        if type(v) ~= "string" then v = v:ToString() end
        return v
    end)
    if ok and type(s) == "string" then
        gameCode = s:lower():match("^(%a%a)")
        if gameCode and M.onGameLanguage then M.onGameLanguage(s, gameCode) end
    end
    return gameCode
end

-- Applies the "language" setting: a language code, or "auto" = the game's language (English until it is known).
function M.apply(setting)
    if setting == nil or setting == "" or setting == "auto" then setting = M.gameLanguage() or "en" end
    M.setLanguage(setting)
end

-- Text of a key with its {0} {1}... filled in.
function M.t(key, ...)
    local s = texts[key] or key
    local n = select("#", ...)
    if n > 0 then
        local args = { ... }
        s = s:gsub("{(%d)}", function(i) local v = args[tonumber(i) + 1]; return v ~= nil and tostring(v) or "" end)
    end
    return s
end

-- Text of a key, or nil if no language has it.
function M.find(key) return texts[key] end

-- Lines of a multi-line text.
function M.lines(key)
    local out = {}
    for line in (M.t(key) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end

-- Key of a category name ("Fall damage" -> "section.fall_damage"; same rule as the launcher).
function M.section(name)
    local slug = name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    local s = texts["section." .. slug]
    return s or name
end

-- Number of characters (not bytes) of a UTF-8 text.
function M.len(s)
    local n = utf8 and utf8.len(s)
    return n or #s
end

-- Upper case, also for accented Latin letters (string.upper only knows A-Z).
local UPPER = { ["\197\147"] = "\197\146", ["\195\191"] = "\197\184" }   -- oe, y diaeresis
function M.upper(s)
    s = s:upper()
    return (s:gsub("[\195\197][\128-\191]", function(ch)
        if UPPER[ch] then return UPPER[ch] end
        local a, b = ch:byte(1, 2)
        -- U+00E0..U+00FE (except U+00F7 division sign) -> U+00C0..U+00DE
        if a == 195 and b >= 160 and b <= 190 and b ~= 183 then return string.char(195, b - 32) end
        return ch
    end))
end

return M
