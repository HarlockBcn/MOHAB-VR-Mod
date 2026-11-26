-- In-game VR menu made of TextRenderActors floating in front of the player.
--   Hold LEFT Y to open / close.
--   Two columns: the master switch, the view switch and the categories on the left, the options of the chosen category
--   on the right, and a help line for the selected option at the bottom.
--   Two views (menu_view, shared with the launcher): "basic" shows the main options in three categories, "advanced"
--   every option. Options hidden in the basic view keep their values.
--   Left column:  stick up/down = choose, A / trigger / stick right = open the category (or flip the master / view
--                 switch), B = close the menu.
--   Right column: stick up/down = choose, A / trigger = switch an ON/OFF option or start editing any other one,
--                 X = detailed description of the option (descriptions.txt; X / B / stick left = back to the list),
--                 B / stick left = back to the categories. The stick alone never changes a value.
--   Editing:      stick left/right = change (applied live), A / trigger = confirm, B = cancel. Nothing else works;
--                 closing the menu cancels too.
--   Not editing:  grips = previous / next category, holding a stick click = master switch (all mod changes on / off).
-- While the menu is open the pawn's input is disabled (no walking/turning/shooting).
local U = require("util")
local C = require("config")

local M = {}

M.open = false

local OPEN_KEY = "OculusTouch_Left_Y_Click"

-- Menu items ---------------------------------------------------------------------------------
local function fmtNum(v, digits) return string.format("%." .. (digits or 2) .. "f", v) end

local advancedTabs = {
    { name = "Syringes", items = {
        { key = "syringe_require_trigger", label = "Trigger to inject", kind = "bool",
          help = "Hold the trigger of the hand with the syringe to inject it" },
        { key = "syringe_trigger_threshold", label = "Trigger threshold", kind = "num", min = 0.1, max = 1.0, step = 0.05,
          help = "How far the trigger must be pulled to inject" },
        { key = "syringe_small_holstered", label = "Smaller on the sleeve", kind = "bool",
          help = "Syringes on the sleeve are drawn smaller (full size in the hand)" },
        { key = "syringe_holster_scale", label = "Sleeve scale", kind = "num", min = 0.25, max = 1.0, step = 0.05,
          help = "Size of the syringes on the sleeve" },
    } },
    { name = "Grabbing", items = {
        { key = "manual_holster", label = "Manual holsters", kind = "bool",
          help = "Letting go drops the weapon; take it to a free holster to put it away" },
        { key = "holster_store_distance", label = "Put away distance", kind = "num", min = 10, max = 50, step = 1, digits = 0, suffix = " cm",
          help = "Manual holsters: how close to the holster the hand must be to put a weapon away" },
        { key = "grenade_row", label = "All grenades on chest", kind = "bool",
          help = "Every grenade you carry is shown on your chest; take the one you want" },
        { key = "grenade_row_scale", label = "Chest grenade size", kind = "num", min = 0.4, max = 1.0, step = 0.05,
          help = "Size of the grenades on the chest (full size in the hand)" },
        { key = "body_grab_distance", label = "Inventory grab distance", kind = "num", min = 5, max = 30, step = 1, digits = 0, suffix = " cm",
          help = "How close the hand must be to take grenades, objects or syringes you carry" },
        { key = "holster_grab_distance", label = "Holster grab distance", kind = "num", min = 5, max = 30, step = 1, digits = 0, suffix = " cm",
          help = "How close the hand must be to take a weapon from a holster (not back weapons)" },
        { key = "grab_aim", label = "Grab what you point at", kind = "bool",
          help = "The object lit in blue is the one your hand's guide points at" },
        { key = "weapon_grip_reach", label = "Second hand reach", kind = "num", min = 5, max = 40, step = 1, digits = 0, suffix = " cm",
          help = "How close the second hand must be to grab a weapon's front grip" },
        { key = "grenade_physics", label = "Realistic grenade throws", kind = "bool",
          help = "Grenades fly at your hand's speed and bounce by their weight (game: 2x, stop dead)" },
        { key = "grenade_throw_strength", label = "Grenade throw strength", kind = "num", min = 0.5, max = 2.0, step = 0.1,
          help = "Realistic grenade throws: x your hand's speed (1.0 = exactly as fast as your hand)" },
        { key = "teeth_pin_distance", label = "Pull pin with teeth", kind = "num", min = 0, max = 15, step = 1, digits = 0, suffix = " cm",
          help = "How close a grenade must get to your mouth to pull its pin (game: 10, 0 = never)" },
        { key = "cocking", label = "Cocking", kind = "choice",
          choices = { "manual", "auto" },
          names = { manual = "Manual", auto = "Automatic" },
          helps = { manual = "Manual: after a reload, pull the bolt or slide yourself",
                    auto = "Automatic: grabbing the front grip cocks the weapon (original game)" },
          help = "Manual: work the bolt or slide yourself.  Automatic: the game does it (original)" },
        { key = "holster_below_eyes", label = "No holster grab above eyes", kind = "bool",
          help = "A hand above your eyes grabs hats and helmets, not back weapons" },
    } },
    { name = "Haptics", items = {
        { key = "haptics_damage", label = "Vibrate on damage", kind = "bool",
          help = "Both controllers vibrate when you are hit" },
        { key = "haptics_intensity", label = "Vibration intensity", kind = "num", min = 0.1, max = 1.0, step = 0.1, digits = 1,
          help = "Strength of all the mod's vibrations" },
        { key = "haptics_duration", label = "Damage duration", kind = "num", min = 0.05, max = 1.0, step = 0.05, suffix = " s",
          help = "Length of the damage vibration (longer on big hits)" },
        { key = "haptics_directional", label = "Stronger on hit side", kind = "bool",
          help = "The controller on the side the hit came from vibrates harder" },
        { key = "haptics_weapons", label = "Vibrate when reloading", kind = "bool",
          help = "Magazines, shells and opening / closing the sawed-off" },
        { key = "haptics_no_ammo", label = "Vibrate when out of ammo", kind = "bool",
          help = "Two taps when you reach for the magazine pouch with no ammo left" },
        { key = "haptics_holster_zone", label = "Vibrate at grab zones", kind = "bool",
          help = "Light tap when your empty hand can take a weapon or item you carry" },
    } },
    { name = "Movement", items = {
        { key = "crouch_stick", label = "Crouch with turn stick", kind = "bool",
          help = "Turn stick down: crouch.  Up: stand up" },
        { key = "crouch_stick_threshold", label = "Crouch stick threshold", kind = "num", min = 0.3, max = 0.95, step = 0.05,
          help = "How far the turn stick must be pushed to crouch or stand up" },
        { key = "crouch_speed", label = "Crouched speed", kind = "num", min = 0.3, max = 1.0, step = 0.05, digits = 2, suffix = "x",
          help = "Walking speed while crouched, for real or with the stick (1x = normal walking)" },
        { key = "sprint_mode", label = "Sprint", kind = "choice",
          choices = { "stick", "arms", "both", "always" },
          names = { stick = "Stick click", arms = "Arm swing", both = "Stick + arms", always = "Always sprint" },
          helps = { stick = "Stick click: click the movement stick to sprint (original game)",
                    arms = "Arm swing: swing your arms like a runner; faster swing, faster run",
                    both = "Stick + arms: click the stick or swing your arms to sprint",
                    always = "Always sprint: you only walk while you hold a weapon up or shoot" },
          help = "How you sprint: stick click, arm swing, both, or always" },
        { key = "sprint_arm_sensitivity", label = "Arm swing sensitivity", kind = "num", min = 0.3, max = 2.0, step = 0.1, digits = 1,
          help = "Higher: less arm swinging needed to sprint" },
        { key = "sprint_speed_multiplier", label = "Sprint speed", kind = "num", min = 1.0, max = 1.5, step = 0.05, digits = 2, suffix = "x",
          help = "Top sprint speed (1x = original)" },
        { key = "sprint_turn_slowdown", label = "Slow down on sharp turns", kind = "num", min = 0.0, max = 1.0, step = 0.1, digits = 1,
          help = "Speed lost when turning hard while sprinting (0 = off)" },
        { key = "stairs_steady_speed", label = "Steady speed on stairs", kind = "bool",
          help = "Stairs and slopes no longer speed you up (the original game does)" },
        { key = "slide_enabled", label = "Slide", kind = "bool",
          help = "Crouch while sprinting (stick or for real) to slide" },
        { key = "slide_strength", label = "Slide length", kind = "num", min = 0.5, max = 2.0, step = 0.1, digits = 1, suffix = "x",
          help = "How far the slide takes you" },
        { key = "slide_sound", label = "Slide sound", kind = "choice",
          choices = { "body", "wood", "metal", "off" },
          names = { body = "Body", wood = "Wood scrape", metal = "Metal scrape", off = "Off" },
          helps = { body = "Your body scraping along the floor", wood = "A wooden scrape while sliding",
                    metal = "A metal scrape while sliding", off = "No sound while sliding" },
          help = "Sound played while sliding" },
    } },
    { name = "Jump", items = {
        { key = "jump_enabled", label = "Jump (experimental)", kind = "bool",
          help = "Turn stick up while standing to jump" },
        { key = "jump_stick_threshold", label = "Jump stick threshold", kind = "num", min = 0.3, max = 0.95, step = 0.05,
          help = "How far the turn stick must be pushed up to jump" },
        { key = "jump_height", label = "Jump height", kind = "num", min = 20, max = 120, step = 5, digits = 0, suffix = " cm",
          help = "How high you jump" },
        { key = "jump_sound", label = "Jump sounds", kind = "choice",
          choices = { "all", "cloth", "off" },
          names = { all = "Voice + cloth", cloth = "Cloth only", off = "Off" },
          helps = { all = "Effort voice and cloth rustle when jumping", cloth = "Only the cloth rustle when jumping",
                    off = "No sound when jumping" },
          help = "Effort voice and cloth rustle when jumping" },
        { key = "jump_guard", label = "Stay inside the level", kind = "bool",
          help = "Jumps can't take you over the level's invisible barriers" },
        { key = "land_crouch", label = "Hard landings", kind = "bool",
          help = "Big falls make you bend down on landing, with a grunt and a jolt" },
        { key = "land_crouch_height", label = "Hard landing from", kind = "num", min = 1.0, max = 6.0, step = 0.5, digits = 1, suffix = " m",
          help = "Falls from this high or more (from the top of a jump)" },
    } },
    { name = "Fall damage", items = {
        { key = "fall_damage_custom", label = "Custom fall damage", kind = "bool",
          help = "OFF: the game's rules (hurts from about 3.3 m, kills from 10 m)" },
        { key = "fall_safe_height", label = "Safe height", kind = "num", min = 1.0, max = 10.0, step = 0.5, digits = 1, suffix = " m",
          help = "Shorter falls don't hurt (counted from the top of a jump)" },
        { key = "fall_fatal_height", label = "Fatal height", kind = "num", min = 4, max = 30, step = 1, digits = 0, suffix = " m",
          help = "Longer falls kill you" },
        { key = "fall_damage_progressive", label = "Damage grows with height", kind = "bool",
          help = "Small drops hurt a little, big ones a lot (game: always the same)" },
        { key = "fall_damage_scale", label = "Damage amount", kind = "num", min = 0.0, max = 2.0, step = 0.1, digits = 1, suffix = "x",
          help = "Damage of a non-fatal fall (1x = the game's)" },
    } },
    { name = "Cutscenes", items = {
        { key = "skip_cutscenes", label = "Skip cutscenes", kind = "bool",
          help = "Hold both triggers and both grips for a second to skip" },
        { key = "skip_speed", label = "Dialogue fast-forward", kind = "num", min = 2, max = 15, step = 1, digits = 0, suffix = "x",
          help = "Speed of dialogue scenes where you just stand and wait" },
    } },
}

-- Basic view: the main options (what is on and how you play), grouped in three categories. The items are the ones of
-- the advanced view, so labels, ranges and help texts are shared. Keep in sync with ModConfig.BasicLayout (launcher).
local basicLayout = {
    { name = "Movement", keys = { "sprint_mode", "crouch_stick", "slide_enabled", "jump_enabled" } },
    { name = "Weapons", keys = { "cocking", "manual_holster", "grenade_row", "grenade_physics", "syringe_require_trigger" } },
    { name = "Comfort", keys = { "haptics_intensity", "fall_damage_custom", "skip_cutscenes" } },
}
local basicTabs = {}
do
    local byKey = {}
    for _, t in ipairs(advancedTabs) do
        for _, it in ipairs(t.items) do byKey[it.key] = it end
    end
    for _, b in ipairs(basicLayout) do
        local t = { name = b.name, items = {} }
        for _, k in ipairs(b.keys) do
            if byKey[k] then t.items[#t.items + 1] = byKey[k] end
        end
        basicTabs[#basicTabs + 1] = t
    end
end

local function isAdvanced() return C.raw("menu_view") == "advanced" end
local function tabs() return isAdvanced() and advancedTabs or basicTabs end

-- Text shown in the right column while the master switch is selected.
local MASTER_INFO = {
    "Turns every change of the mod on or off",
    "at once, to compare with the original game.",
    "",
    "Your settings are kept. This switch is not",
    "saved: the mod is on every time you start.",
    "",
    "Shortcut anywhere in this menu:",
    "hold a thumbstick click.",
}

-- Text shown in the right column while the view switch is selected.
local VIEW_INFO = {
    "BASIC: the main options, in three",
    "categories.",
    "",
    "ADVANCED: every option, including the",
    "fine-tuning ones (distances, sizes, sounds).",
    "",
    "Options hidden in the basic view keep",
    "working with their values.",
    "",
    "Also available in the launcher.",
}

-- Rows of both columns: enough for the longest category and for the left column (master switch, view switch, gap,
-- categories).
local ROWS = #advancedTabs + 3
for _, t in ipairs(advancedTabs) do ROWS = math.max(ROWS, #t.items) end

-- Detailed description of an option: wrapped to the width of the right column, at most ROWS lines.
local DETAIL_WIDTH = 46
local function wrap(text, width, out)
    local line = ""
    for word in text:gmatch("%S+") do
        if line == "" then line = word
        elseif #line + 1 + #word <= width then line = line .. " " .. word
        else
            out[#out + 1] = line
            line = word
        end
    end
    if line ~= "" then out[#out + 1] = line end
end

local function valueText(it, v)
    if v == nil then v = C.raw(it.key) end
    if it.kind == "bool" then return v and "ON" or "OFF" end
    if it.kind == "num" then return fmtNum(v, it.digits) .. (it.suffix or "") end
    if it.kind == "choice" then return (it.names and it.names[v]) or tostring(v) end
    return ""
end

-- Help line of an option: for choices with one text per value, the one of the current value.
local function helpText(it)
    if it.helps then
        local h = it.helps[C.raw(it.key)]
        if h then return h end
    end
    return it.help or ""
end

local function change(it, dir)
    if it.kind == "bool" then
        C.set(it.key, not C.raw(it.key))
    elseif it.kind == "num" then
        local v = C.raw(it.key) + dir * it.step
        v = math.floor(v / it.step + 0.5) * it.step
        C.set(it.key, U.clamp(v, it.min, it.max))
    elseif it.kind == "choice" then
        local cur = C.raw(it.key)
        local idx = 1
        for i, c in ipairs(it.choices) do if c == cur then idx = i end end
        idx = ((idx - 1 + dir) % #it.choices) + 1
        C.set(it.key, it.choices[idx])
    end
end

-- Navigation state (kept between openings: the menu reopens where it was left).
-- Left column positions: 1 = master switch, 2 = view switch, 2 + i = category i.
local LEFT_MASTER, LEFT_VIEW, LEFT_TABS = 1, 2, 2
local focus = "left"    -- "left" (categories) | "right" (options)
local leftSel = LEFT_TABS + 1
local sel = 1           -- option in the open category
local lastTab = 1       -- category shown on the right while a switch is selected
local editing = nil     -- option being edited: { item, old = value before editing }
local details = false   -- right column shows the selected option's detailed description
local shownView = nil   -- view the navigation state was last checked against
local dirty = true

local function tabIndex() return leftSel - LEFT_TABS end   -- < 1 while a switch is selected
local function currentTab()
    local t = tabs()
    return t[tabIndex()] or t[lastTab] or t[1]
end

-- Keep the selection valid when the view changes (menu, launcher, config file).
local function checkView()
    local v = C.raw("menu_view")
    if v == shownView then return end
    shownView = v
    local n = #tabs()
    if tabIndex() > n then leftSel = LEFT_TABS + n end
    if lastTab > n then lastTab = 1 end
    if sel > #currentTab().items then sel = 1 end
    if focus == "right" and tabIndex() < 1 then focus = "left" end
    details = false
    dirty = true
end

-- Rendering ----------------------------------------------------------------------------------
local actors = {}       -- slot name -> TextRenderActor
local shown = {}        -- slot name -> last text .. colour (skip redundant updates)
local textRenderClass = nil
local hasChanges = false

local COLOR_TITLE = { R = 255, G = 200, B = 60, A = 255 }
local COLOR_HEADER = { R = 140, G = 170, B = 255, A = 255 }
local COLOR_NORMAL = { R = 230, G = 230, B = 230, A = 255 }
local COLOR_SELECTED = { R = 255, G = 230, B = 0, A = 255 }
local COLOR_EDIT = { R = 255, G = 130, B = 30, A = 255 }       -- option being edited
local COLOR_CURRENT = { R = 150, G = 200, B = 255, A = 255 }   -- open category while the options have the focus
local COLOR_DIM = { R = 120, G = 120, B = 120, A = 255 }
local COLOR_ON = { R = 110, G = 230, B = 110, A = 255 }
local COLOR_OFF = { R = 230, G = 110, B = 100, A = 255 }
local COLOR_HELP = { R = 190, G = 205, B = 230, A = 255 }
local COLOR_FOOTER = { R = 150, G = 150, B = 150, A = 255 }

local WORLD_SIZE = 1.6      -- character height in cm
local LINE_SPACING = 2.4    -- cm
local DISTANCE = 60         -- cm in front of the eyes
-- Column positions, cm to the right of the panel centre (tune here if the columns overlap).
local X_LEFT = -32          -- categories (left-aligned)
local X_LABEL = -12         -- option names (left-aligned)
local X_VALUE = 32          -- option values (right-aligned)

local ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT = 0, 1, 2

-- Slots: name, horizontal position (cm), vertical position (lines below the top), alignment, size factor.
local slots = {}
local function addSlot(name, x, line, align, size)
    slots[#slots + 1] = { name = name, x = x, line = line, align = align, size = size or 1 }
end
addSlot("title", 0, 0, ALIGN_CENTER, 1.4)
addSlot("heading", X_LABEL, 2, ALIGN_LEFT, 1.0)
for r = 1, ROWS do
    addSlot("L" .. r, X_LEFT, 2 + r, ALIGN_LEFT)
    addSlot("R" .. r, X_LABEL, 2 + r, ALIGN_LEFT)
    addSlot("V" .. r, X_VALUE, 2 + r, ALIGN_RIGHT)
end
addSlot("help", 0, 3 + ROWS + 0.6, ALIGN_CENTER, 0.85)
addSlot("footer", 0, 3 + ROWS + 1.6, ALIGN_CENTER, 0.75)
local TOTAL_LINES = 3 + ROWS + 1.6

local FOOTER_LEFT = "Stick: choose   A: open   B: close   Grips: category   Hold stick click: mod on/off"
local FOOTER_RIGHT = "Stick: choose   A: change   X: details   B: back   Grips: category   Hold stick click: mod on/off"
local FOOTER_DETAILS = "DETAILS   Stick up/down: other option   A: change   X or B: back to the list"
local FOOTER_EDIT = "EDITING (was %s)   Stick left/right: change   A: confirm   B: cancel"

-- Text and colour of every slot for the current state.
local function content()
    local out = {}
    local on = C.enabled
    out.title = on and { "MOHAB PLUS", COLOR_TITLE } or { "MOHAB PLUS  -  MOD OFF (original game)", COLOR_OFF }

    -- Left column: master switch, view switch, a gap, the categories.
    local list = tabs()
    local mSel = focus == "left" and leftSel == LEFT_MASTER
    out.L1 = { (mSel and "> " or "") .. (on and "MOD: ON" or "MOD: OFF"), mSel and COLOR_SELECTED or (on and COLOR_ON or COLOR_OFF) }
    local vSel = focus == "left" and leftSel == LEFT_VIEW
    out.L2 = { (vSel and "> " or "") .. (isAdvanced() and "VIEW: ADVANCED" or "VIEW: BASIC"), vSel and COLOR_SELECTED or COLOR_HEADER }
    out.L3 = { "", COLOR_NORMAL }
    -- Rows below the last category: empty (a text render left alone shows the engine's default "Text").
    for r = #list + 4, ROWS do out["L" .. r] = { "", COLOR_NORMAL } end
    for i, t in ipairs(list) do
        local r = i + 3
        if r <= ROWS then
            local color, prefix = COLOR_NORMAL, "   "
            if tabIndex() == i then
                prefix = "> "
                color = focus == "left" and COLOR_SELECTED or COLOR_CURRENT
            end
            out["L" .. r] = { prefix .. t.name, color }
        end
    end

    -- Right column
    local detailItem = details and focus == "right" and not editing and currentTab().items[sel] or nil
    if leftSel == LEFT_MASTER or leftSel == LEFT_VIEW then
        local info = leftSel == LEFT_MASTER and MASTER_INFO or VIEW_INFO
        out.heading = { leftSel == LEFT_MASTER and "ALL MOD CHANGES" or "MENU VIEW", COLOR_HEADER }
        for r = 1, ROWS do
            out["R" .. r] = { info[r] or "", COLOR_NORMAL }
            out["V" .. r] = { "", COLOR_NORMAL }
        end
        if leftSel == LEFT_MASTER then
            out.help = { on and "A or trigger: turn the whole mod OFF" or "A or trigger: turn the whole mod back ON", COLOR_HELP }
        else
            out.help = { isAdvanced() and "A or trigger: switch to the basic view (main options only)"
                or "A or trigger: switch to the advanced view (every option)", COLOR_HELP }
        end
    elseif detailItem then
        local it = detailItem
        out.heading = { it.label:upper(), COLOR_HEADER }
        local lines = {}
        local paras = C.descriptions()[it.key] or { it.help or "" }
        for i, p in ipairs(paras) do
            if i > 1 then lines[#lines + 1] = "" end
            wrap(p, DETAIL_WIDTH, lines)
        end
        local tail = { "", "Now: " .. valueText(it) .. "     Default: " .. valueText(it, C.defaults[it.key]) }
        -- Drop the blank lines between paragraphs if the text does not fit, then cut it.
        if #lines + #tail > ROWS then
            local packed = {}
            for _, l in ipairs(lines) do if l ~= "" then packed[#packed + 1] = l end end
            lines = packed
        end
        while #lines + #tail > ROWS do table.remove(lines) end
        for _, l in ipairs(tail) do lines[#lines + 1] = l end
        for r = 1, ROWS do
            out["R" .. r] = { lines[r] or "", r == #lines and COLOR_HELP or COLOR_NORMAL }
            out["V" .. r] = { "", COLOR_NORMAL }
        end
        out.help = { helpText(it), COLOR_HELP }
    else
        local tab = currentTab()
        out.heading = { tab.name:upper() .. (on and "" or "   (mod off: not applied)"), on and COLOR_HEADER or COLOR_DIM }
        for r = 1, ROWS do
            local it = tab.items[r]
            if it then
                local s = focus == "right" and sel == r
                local v = valueText(it)
                local vc = COLOR_NORMAL
                if it.kind == "bool" then vc = C.raw(it.key) and COLOR_ON or COLOR_OFF end
                if not on then vc = COLOR_DIM end
                local lc = on and COLOR_NORMAL or COLOR_DIM
                if s and editing then
                    v = "<  " .. v .. "  >"
                    vc, lc = COLOR_EDIT, COLOR_EDIT
                elseif s then
                    vc, lc = COLOR_SELECTED, COLOR_SELECTED
                end
                out["R" .. r] = { (s and "> " or "") .. it.label, lc }
                out["V" .. r] = { v, vc }
            else
                out["R" .. r] = { "", COLOR_NORMAL }
                out["V" .. r] = { "", COLOR_NORMAL }
            end
        end
        local it = focus == "right" and tab.items[sel] or nil
        if it then
            out.help = { helpText(it), COLOR_HELP }
        else
            out.help = { "A or stick right: open " .. tab.name, COLOR_HELP }
        end
    end
    if editing then
        out.footer = { string.format(FOOTER_EDIT, valueText(editing.item, editing.old)), COLOR_EDIT }
    elseif detailItem then
        out.footer = { FOOTER_DETAILS, COLOR_FOOTER }
    else
        out.footer = { focus == "left" and FOOTER_LEFT or FOOTER_RIGHT, COLOR_FOOTER }
    end
    return out
end

local function setText(actor, text, color)
    local tr = U.get(actor, "TextRender")
    if not U.valid(tr) then return end
    U.call(tr, "K2_SetText", FText(text))
    U.call(tr, "SetTextRenderColor", color)
end

local function destroyActors()
    for _, a in pairs(actors) do
        if U.valid(a) then U.call(a, "K2_DestroyActor") end
    end
    actors = {}
    shown = {}
end

local function refresh()
    local c = content()
    for name, a in pairs(actors) do
        local v = c[name]
        if v and U.valid(a) then
            local col = v[2]
            local sig = string.format("%s|%d,%d,%d", v[1], col.R, col.G, col.B)
            if shown[name] ~= sig then
                shown[name] = sig
                setText(a, v[1], col)
            end
        end
    end
    dirty = false
end

local function spawnMenu(pawn)
    destroyActors()
    if not U.valid(textRenderClass) then
        textRenderClass = StaticFindObject("/Script/Engine.TextRenderActor")
    end
    if not U.valid(textRenderClass) then
        U.log("TextRenderActor class not found; menu unavailable")
        return false
    end
    local cam = U.get(pawn, "VRReplicatedCamera")
    local ok1, camLoc = U.call(cam, "K2_GetComponentLocation")
    local ok2, camRot = U.call(cam, "K2_GetComponentRotation")
    if not (ok1 and ok2) then return false end
    camLoc = U.vec(camLoc)
    local yaw = camRot.Yaw
    local rad = math.rad(yaw)
    local fwd = { X = math.cos(rad), Y = math.sin(rad), Z = 0 }
    local right = { X = -math.sin(rad), Y = math.cos(rad), Z = 0 }
    local world = pawn:GetWorld()
    if not U.valid(world) then return false end

    -- Copy the font/material the game uses for its own floating texts (fallback: engine default).
    local refText = U.get(pawn, "LeftHandHolsterUIText")
    local refMat = U.get(refText, "TextMaterial")
    local refFont = U.get(refText, "Font")
    local origin = U.get(pawn, "VROrigin")

    local center = U.vadd(camLoc, U.vmul(fwd, DISTANCE))
    center.Z = center.Z - 6
    local top = center.Z + TOTAL_LINES * LINE_SPACING / 2
    local n = 0
    for _, s in ipairs(slots) do
        local base = U.vadd(center, U.vmul(right, s.x))
        local loc = { X = base.X, Y = base.Y, Z = top - s.line * LINE_SPACING }
        local ok, a = pcall(function()
            return world:SpawnActor(textRenderClass, loc, { Pitch = 0, Yaw = yaw + 180, Roll = 0 })
        end)
        if ok and U.valid(a) then
            local tr = U.get(a, "TextRender")
            if U.valid(tr) then
                U.call(tr, "SetHorizontalAlignment", s.align)
                U.call(tr, "SetVerticalAlignment", 1)     -- EVRTA_TextCenter
                if U.valid(refMat) then U.call(tr, "SetTextMaterial", refMat) end
                if U.valid(refFont) then U.call(tr, "SetFont", refFont) end
                U.call(tr, "SetWorldSize", WORLD_SIZE * s.size)
                pcall(function() tr.CastShadow = false end)
            end
            -- Follow the player (VR origin) so the menu stays put relative to the body.
            if U.valid(origin) then
                U.call(a, "K2_AttachToComponent", origin, FName("None"), 1, 1, 1, false)
            end
            actors[s.name] = a
            n = n + 1
        end
    end
    U.log("menu: %d/%d texts spawned, centre (%.0f, %.0f, %.0f), camera (%.0f, %.0f, %.0f) yaw %.0f",
        n, #slots, center.X, center.Y, center.Z, camLoc.X, camLoc.Y, camLoc.Z, yaw)
    refresh()
    return n > 0
end

function M.debugInfo()
    local out = {}
    for _, s in ipairs(slots) do
        local a = actors[s.name]
        if U.valid(a) then
            local ok, loc = U.call(a, "K2_GetActorLocation")
            local tr = U.get(a, "TextRender")
            local txt = U.get(tr, "Text")
            local ts = ""
            if txt then pcall(function() ts = txt:ToString() end) end
            if ts ~= "" then
                out[#out + 1] = string.format("  %s at (%.0f,%.0f,%.0f) '%s'", s.name, ok and loc.X or 0, ok and loc.Y or 0, ok and loc.Z or 0, ts)
            end
        end
    end
    return out
end

-- Navigation ---------------------------------------------------------------------------------
local WAIT = "wait"
local stickDir = WAIT       -- nil (centred) | "up" | "down" | "left" | "right" | WAIT (ignored until centred)

local function toggleMaster()
    C.enabled = not C.enabled
    U.log("menu: all mod changes %s", C.enabled and "ON" or "OFF")
    dirty = true
end

local function toggleView()
    C.set("menu_view", isAdvanced() and "basic" or "advanced")
    hasChanges = true
    U.log("menu: %s view", C.raw("menu_view"))
    checkView()
end

local function toggleDetails()
    if editing or focus ~= "right" then return end
    details = not details
    dirty = true
end

local function startEdit(it)
    details = false
    editing = { item = it, old = C.raw(it.key) }
    stickDir, dirty = WAIT, true
end

local function confirmEdit()
    if C.raw(editing.item.key) ~= editing.old then hasChanges = true end
    editing = nil
    stickDir, dirty = WAIT, true
end

local function cancelEdit()
    if not editing then return end
    C.set(editing.item.key, editing.old)
    editing = nil
    stickDir, dirty = WAIT, true
end

local function moveVertical(dir)
    if focus == "left" then
        local n = LEFT_TABS + #tabs()
        leftSel = ((leftSel - 1 + dir) % n) + 1         -- master, view, categories
        if tabIndex() >= 1 then lastTab = tabIndex() end
    else
        local n = #currentTab().items
        sel = ((sel - 1 + dir) % n) + 1
    end
    dirty = true
end

local function enter()
    if leftSel == LEFT_MASTER then
        toggleMaster()
    elseif leftSel == LEFT_VIEW then
        toggleView()
    else
        focus, sel = "right", 1
        stickDir, dirty = WAIT, true
    end
end

-- B: cancel the edit, or go back to the categories. False when there is nothing to go back from (close the menu).
local function back()
    if editing then
        cancelEdit()
        return true
    end
    if details then
        details = false
        stickDir, dirty = WAIT, true
        return true
    end
    if focus == "right" then
        focus = "left"
        stickDir, dirty = WAIT, true
        return true
    end
    return false
end

-- Previous / next category (skips the switches).
local function switchTab(dir)
    if editing then return end
    local n = #tabs()
    local i = tabIndex()
    if i < 1 then i = dir > 0 and 0 or n + 1 end
    i = ((i - 1 + dir) % n) + 1
    leftSel, lastTab, sel = LEFT_TABS + i, i, 1
    dirty = true
end

local function activate()
    if editing then
        confirmEdit()
        return
    end
    if focus == "left" then
        enter()
        return
    end
    local it = currentTab().items[sel]
    if not it then return end
    if it.kind == "bool" then
        change(it, 1)
        hasChanges, dirty = true, true
    else
        startEdit(it)
    end
end

-- One step of the stick (repeating = held down).
local function stickStep(dir, repeating)
    if editing then
        if dir ~= "left" and dir ~= "right" then return end
        if repeating and editing.item.kind ~= "num" then return end
        change(editing.item, dir == "right" and 1 or -1)
        dirty = true
    elseif dir == "up" or dir == "down" then
        moveVertical(dir == "up" and -1 or 1)
    elseif not repeating then
        if dir == "right" and focus == "left" and tabIndex() >= 1 then enter()
        elseif dir == "left" and focus == "right" then back() end
    end
end

-- Input handling ------------------------------------------------------------------------------
local STICK_ON, STICK_OFF = 0.6, 0.35   -- deflection that counts as a push / as released
local STICK_DOMINANCE = 1.5             -- a push must be this much stronger on its axis than on the other (no diagonals)
local CLICK_HOLD = 0.5                  -- seconds of stick click for the master switch
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

local holdStart = nil
local holdConsumed = false
local stickRepeatAt = 0
local clickStart = nil
local prev = {}         -- button name -> was down last frame

-- Deflection of the stick that is pushed the most.
local function stick()
    local rx, ry = U.axis("OculusTouch_Right_Thumbstick_X"), U.axis("OculusTouch_Right_Thumbstick_Y")
    local lx, ly = U.axis("OculusTouch_Left_Thumbstick_X"), U.axis("OculusTouch_Left_Thumbstick_Y")
    if math.max(math.abs(rx), math.abs(ry)) >= math.max(math.abs(lx), math.abs(ly)) then return rx, ry end
    return lx, ly
end

-- Direction of a clear push, nil if centred or diagonal.
local function pushDirection(x, y)
    local ax, ay = math.abs(x), math.abs(y)
    if ay > STICK_ON and ay >= ax * STICK_DOMINANCE then return y > 0 and "up" or "down" end
    if ax > STICK_ON and ax >= ay * STICK_DOMINANCE then return x > 0 and "right" or "left" end
    return nil
end

-- Stick navigation with auto-repeat. A push keeps its direction until the stick is centred (or flicked to the opposite
-- side), so a wandering thumb can't turn it into another one.
local function stickTick(now)
    local x, y = stick()
    if math.max(math.abs(x), math.abs(y)) < STICK_OFF then
        stickDir = nil
        return
    end
    if stickDir == WAIT then return end
    local dir = pushDirection(x, y)
    if dir and (stickDir == nil or dir == OPPOSITE[stickDir]) then
        stickDir = dir
        stickRepeatAt = now + 0.4
        stickStep(dir, false)
    elseif dir and dir == stickDir and now >= stickRepeatAt then
        stickRepeatAt = now + 0.15
        stickStep(dir, true)
    end
end

local function buttons()
    -- Analog buttons: released well below the point where they are pressed, so they can't flicker.
    local function pull(v, was) return v > (was and 0.4 or 0.7) end
    return {
        a = U.down("OculusTouch_Right_A_Click"),
        x = U.down("OculusTouch_Left_X_Click"),
        trig = pull(math.max(U.trigger("Right"), U.trigger("Left")), prev.trig),
        b = U.down("OculusTouch_Right_B_Click"),
        gripL = pull(U.axis("OculusTouch_Left_Grip_Axis"), prev.gripL),
        gripR = pull(U.axis("OculusTouch_Right_Grip_Axis"), prev.gripR),
        click = U.down("OculusTouch_Left_Thumbstick_Click") or U.down("OculusTouch_Right_Thumbstick_Click"),
    }
end

local function setPawnInput(pawn, pc, enabled)
    if enabled then
        U.call(pawn, "EnableInput", pc)
        U.call(pc, "SetIgnoreMoveInput", false)
        U.call(pc, "SetIgnoreLookInput", false)
    else
        U.call(pawn, "DisableInput", pc)
        U.call(pc, "SetIgnoreMoveInput", true)
        U.call(pc, "SetIgnoreLookInput", true)
        -- Axis values are cached by the pawn's input events; clear them so the player does not keep walking.
        for _, k in ipairs({ "MovementStick_XAxis", "MovementStick_YAxis", "FlickTurningStick_XAxis", "FlickTurningStick_YAxis" }) do
            pcall(function() pawn[k] = 0.0 end)
        end
    end
end

function M.openMenu(pawn, pc)
    if M.open then return end
    if not spawnMenu(pawn) then return end
    M.open = true
    hasChanges = false
    setPawnInput(pawn, pc, false)
    prev = buttons()            -- ignore buttons already held
    stickDir, clickStart = WAIT, nil
    U.log("menu opened")
end

function M.closeMenu(pawn, pc)
    if not M.open then return end
    cancelEdit()
    M.open = false
    destroyActors()
    if U.valid(pawn) and U.valid(pc) then setPawnInput(pawn, pc, true) end
    if hasChanges then C.save() end
    U.log("menu closed")
end

-- Returns true while the menu consumes input.
function M.tick(pawn, pc, now)
    -- Open / close with a long press of left Y
    local y = U.down(OPEN_KEY)
    if y then
        if not holdStart then holdStart = now; holdConsumed = false end
        if not holdConsumed and now - holdStart >= C.get("menu_hold_time") then
            holdConsumed = true
            if M.open then M.closeMenu(pawn, pc) else M.openMenu(pawn, pc) end
        end
    else
        holdStart = nil
    end
    if not M.open then return false end

    -- Menu actors can be destroyed by a level change.
    if not U.valid(actors.title) then
        cancelEdit()
        M.open = false
        actors, shown = {}, {}
        setPawnInput(pawn, pc, true)
        return false
    end

    checkView()
    stickTick(now)

    local cur = buttons()
    local function pressed(k) return cur[k] and not prev[k] end
    if pressed("a") or pressed("trig") then activate() end
    if pressed("x") then toggleDetails() end
    if pressed("gripL") then switchTab(-1) end
    if pressed("gripR") then switchTab(1) end
    if pressed("click") then clickStart = now end
    if editing or not cur.click then clickStart = nil end
    if clickStart and now - clickStart >= CLICK_HOLD then
        clickStart = nil
        toggleMaster()
    end
    if pressed("b") and not back() then
        prev = cur
        M.closeMenu(pawn, pc)
        return false
    end
    prev = cur

    if dirty then refresh() end
    return true
end

-- Test helper (cmd.txt): simulate navigation without controllers.
function M.debugInput(cmd)
    if not M.open then return end
    if OPPOSITE[cmd] then stickStep(cmd, false)
    elseif cmd == "select" then activate()
    elseif cmd == "back" then back()
    elseif cmd == "tabnext" then switchTab(1)
    elseif cmd == "tabprev" then switchTab(-1)
    elseif cmd == "master" and not editing then toggleMaster()
    elseif cmd == "view" and not editing then toggleView()
    elseif cmd == "details" then toggleDetails()
    end
    if dirty then refresh() end
end

function M.reset()
    cancelEdit()
    destroyActors()
    M.open = false
    holdStart = nil
end

return M
