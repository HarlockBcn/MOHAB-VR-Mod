-- In-game VR menu made of TextRenderActors floating in front of the player.
--   Hold LEFT Y to open / close.
--   Stick up/down: select.  Stick left/right: change value.  A or trigger: toggle / activate.  B: close.
-- While the menu is open the pawn's input is disabled (no walking/turning/shooting).
local U = require("util")
local C = require("config")

local M = {}

M.open = false

local OPEN_KEY = "OculusTouch_Left_Y_Click"

-- Menu items ---------------------------------------------------------------------------------
local function fmtNum(v, digits) return string.format("%." .. (digits or 2) .. "f", v) end

local items = {
    { header = "SYRINGES" },
    { key = "syringe_require_trigger", label = "Require trigger to inject", kind = "bool" },
    { key = "syringe_trigger_threshold", label = "Trigger threshold", kind = "num", min = 0.1, max = 1.0, step = 0.05 },
    { key = "syringe_small_holstered", label = "Smaller on the sleeve", kind = "bool" },
    { key = "syringe_holster_scale", label = "Sleeve scale", kind = "num", min = 0.25, max = 1.0, step = 0.05 },
    { key = "syringe_grab_distance", label = "Sleeve grab distance", kind = "num", min = 0.25, max = 1.0, step = 0.05, suffix = "x" },
    { header = "WEAPONS" },
    { key = "weapon_grip_reach", label = "Second hand grab distance", kind = "num", min = 5, max = 40, step = 1, digits = 0, suffix = " cm" },
    { key = "holster_head_zone", label = "No holster over head", kind = "num", min = 0, max = 30, step = 1, digits = 0, suffix = " cm" },
    { header = "HAPTICS" },
    { key = "haptics_damage", label = "Vibrate on damage", kind = "bool" },
    { key = "haptics_intensity", label = "Intensity", kind = "num", min = 0.1, max = 1.0, step = 0.1, digits = 1 },
    { key = "haptics_duration", label = "Duration (s)", kind = "num", min = 0.05, max = 1.0, step = 0.05 },
    { key = "haptics_directional", label = "Stronger on hit side", kind = "bool" },
    { key = "haptics_weapons", label = "Vibrate when reloading", kind = "bool" },
    { header = "MOVEMENT" },
    { key = "crouch_stick", label = "Crouch with turn stick", kind = "bool" },
    { key = "jump_enabled", label = "Jump (turn stick up)", kind = "bool" },
    { key = "jump_height", label = "Jump height", kind = "num", min = 20, max = 80, step = 5, digits = 0, suffix = " cm" },
    { key = "jump_sound", label = "Jump sounds", kind = "choice",
      choices = { "all", "cloth", "off" },
      names = { all = "Voice + cloth", cloth = "Cloth only", off = "Off" } },
    { key = "jump_guard", label = "Jump: stay inside level", kind = "bool" },
    { key = "sprint_mode", label = "Sprint", kind = "choice",
      choices = { "stick", "arms", "both" },
      names = { stick = "Stick click", arms = "Arm swing", both = "Click + arms" } },
    { key = "sprint_arm_sensitivity", label = "Arm swing sensitivity", kind = "num", min = 0.3, max = 2.0, step = 0.1, digits = 1 },
    { key = "sprint_speed_multiplier", label = "Sprint speed", kind = "num", min = 1.0, max = 1.5, step = 0.05, digits = 2, suffix = "x" },
    { key = "slide_enabled", label = "Slide (sprint + crouch)", kind = "bool" },
    { key = "slide_strength", label = "Slide length", kind = "num", min = 0.5, max = 2.0, step = 0.1, digits = 1, suffix = "x" },
    { key = "slide_sound", label = "Slide sound", kind = "choice",
      choices = { "body", "wood", "metal", "off" },
      names = { body = "Body", wood = "Wood scrape", metal = "Metal scrape", off = "Off" } },
    { header = "CUTSCENES" },
    { key = "skip_cutscenes", label = "Skip: hold triggers + grips", kind = "bool" },
    { key = "skip_speed", label = "Dialogue fast-forward", kind = "num", min = 2, max = 15, step = 1, digits = 0, suffix = "x" },
    { action = "close", label = "Close menu" },
}

local function valueText(it)
    local v = C.get(it.key)
    if it.kind == "bool" then return v and "ON" or "OFF" end
    if it.kind == "num" then return fmtNum(v, it.digits) .. (it.suffix or "") end
    if it.kind == "choice" then return (it.names and it.names[v]) or tostring(v) end
    return ""
end

local function lineText(it, selected)
    if it.header then return "- " .. it.header .. " -" end
    local t = it.label
    if it.key then t = t .. ":  " .. valueText(it) end
    if selected then t = ">  " .. t .. "  <" end
    return t
end

local function isSelectable(it) return not it.header end

local function change(it, dir)
    if it.kind == "bool" then
        C.set(it.key, not C.get(it.key))
    elseif it.kind == "num" then
        local v = C.get(it.key) + dir * it.step
        v = math.floor(v / it.step + 0.5) * it.step
        C.set(it.key, U.clamp(v, it.min, it.max))
    elseif it.kind == "choice" then
        local cur = C.get(it.key)
        local idx = 1
        for i, c in ipairs(it.choices) do if c == cur then idx = i end end
        idx = ((idx - 1 + dir) % #it.choices) + 1
        C.set(it.key, it.choices[idx])
    end
end

-- Rendering ----------------------------------------------------------------------------------
local actors = {}       -- one TextRenderActor per line (index = item index + 1 for the title, footer last)
local selected = 2
local dirty = true
local textRenderClass = nil
local hasChanges = false

local COLOR_TITLE = { R = 255, G = 200, B = 60, A = 255 }
local COLOR_HEADER = { R = 140, G = 170, B = 255, A = 255 }
local COLOR_NORMAL = { R = 230, G = 230, B = 230, A = 255 }
local COLOR_SELECTED = { R = 255, G = 230, B = 0, A = 255 }
local COLOR_FOOTER = { R = 160, G = 160, B = 160, A = 255 }

local WORLD_SIZE = 1.7      -- character height in cm
local LINE_SPACING = 2.3    -- cm
local DISTANCE = 55         -- cm in front of the eyes

local function setText(actor, text, color, size)
    local tr = U.get(actor, "TextRender")
    if not U.valid(tr) then return end
    U.call(tr, "K2_SetText", FText(text))
    U.call(tr, "SetTextRenderColor", color)
    if size then U.call(tr, "SetWorldSize", size) end
end

local function destroyActors()
    for _, a in pairs(actors) do
        if U.valid(a) then U.call(a, "K2_DestroyActor") end
    end
    actors = {}
end

local function buildLines()
    local lines = { { text = "MOHAB PLUS", color = COLOR_TITLE, size = WORLD_SIZE * 1.4 } }
    for i, it in ipairs(items) do
        local sel = (i == selected)
        local color = it.header and COLOR_HEADER or (sel and COLOR_SELECTED or COLOR_NORMAL)
        lines[#lines + 1] = { text = lineText(it, sel), color = color }
    end
    lines[#lines + 1] = { text = "Stick: select / change    A: toggle    B or hold Y: close", color = COLOR_FOOTER, size = WORLD_SIZE * 0.8 }
    return lines
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
    local world = pawn:GetWorld()
    if not U.valid(world) then return false end

    -- Copy the font/material the game uses for its own floating texts (fallback: engine default).
    local refText = U.get(pawn, "LeftHandHolsterUIText")
    local refMat = U.get(refText, "TextMaterial")
    local refFont = U.get(refText, "Font")

    local lines = buildLines()
    local total = (#lines - 1) * LINE_SPACING
    local center = U.vadd(camLoc, U.vmul(fwd, DISTANCE))
    center.Z = center.Z - 6
    for i, ln in ipairs(lines) do
        local loc = { X = center.X, Y = center.Y, Z = center.Z + total / 2 - (i - 1) * LINE_SPACING }
        local ok, a = pcall(function()
            return world:SpawnActor(textRenderClass, loc, { Pitch = 0, Yaw = yaw + 180, Roll = 0 })
        end)
        if ok and U.valid(a) then
            local tr = U.get(a, "TextRender")
            if U.valid(tr) then
                U.call(tr, "SetHorizontalAlignment", 1)   -- EHTA_Center
                U.call(tr, "SetVerticalAlignment", 1)     -- EVRTA_TextCenter
                if U.valid(refMat) then U.call(tr, "SetTextMaterial", refMat) end
                if U.valid(refFont) then U.call(tr, "SetFont", refFont) end
                U.call(tr, "SetWorldSize", ln.size or WORLD_SIZE)
                pcall(function() tr.CastShadow = false end)
            end
            -- Follow the player (VR origin) so the menu stays put relative to the body.
            local origin = U.get(pawn, "VROrigin")
            if U.valid(origin) then
                U.call(a, "K2_AttachToComponent", origin, FName("None"), 1, 1, 1, false)
            end
            setText(a, ln.text, ln.color, ln.size or WORLD_SIZE)
            actors[i] = a
        end
    end
    local n = 0
    for _ in pairs(actors) do n = n + 1 end
    U.log("menu: %d/%d lines spawned, centre (%.0f, %.0f, %.0f), camera (%.0f, %.0f, %.0f) yaw %.0f",
        n, #lines, center.X, center.Y, center.Z, camLoc.X, camLoc.Y, camLoc.Z, yaw)
    dirty = false
    return n > 0
end

function M.debugInfo()
    local out = {}
    for i, a in pairs(actors) do
        if U.valid(a) then
            local ok, loc = U.call(a, "K2_GetActorLocation")
            local tr = U.get(a, "TextRender")
            local txt = U.get(tr, "Text")
            local ts = ""
            if txt then pcall(function() ts = txt:ToString() end) end
            out[#out + 1] = string.format("  line %d at (%.0f,%.0f,%.0f) '%s'", i, ok and loc.X or 0, ok and loc.Y or 0, ok and loc.Z or 0, ts)
        end
    end
    return out
end

local function refresh()
    local lines = buildLines()
    for i, ln in ipairs(lines) do
        if U.valid(actors[i]) then setText(actors[i], ln.text, ln.color) end
    end
    dirty = false
end

-- Input handling ------------------------------------------------------------------------------
local holdStart = nil
local holdConsumed = false
local navRepeatAt = 0
local navDirY, navDirX = 0, 0
local prevA, prevB, prevTrig = false, false, false

local function stickY()
    local r = U.axis("OculusTouch_Right_Thumbstick_Y")
    local l = U.axis("OculusTouch_Left_Thumbstick_Y")
    return math.abs(r) >= math.abs(l) and r or l
end
local function stickX()
    local r = U.axis("OculusTouch_Right_Thumbstick_X")
    local l = U.axis("OculusTouch_Left_Thumbstick_X")
    return math.abs(r) >= math.abs(l) and r or l
end

local function moveSelection(dir)
    local n = #items
    local i = selected
    for _ = 1, n do
        i = ((i - 1 + dir) % n) + 1
        if isSelectable(items[i]) then break end
    end
    selected = i
    dirty = true
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
    prevA, prevB, prevTrig = true, true, true   -- ignore buttons already held
    navDirX, navDirY = 0, 0
    U.log("menu opened")
end

function M.closeMenu(pawn, pc)
    if not M.open then return end
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
    if not U.valid(actors[1]) then
        M.open = false
        actors = {}
        setPawnInput(pawn, pc, true)
        return false
    end

    -- Navigation with auto-repeat
    local sy, sx = stickY(), stickX()
    local dy = (sy > 0.6 and 1) or (sy < -0.6 and -1) or 0
    local dx = (sx > 0.6 and 1) or (sx < -0.6 and -1) or 0
    if dy ~= navDirY or dx ~= navDirX then
        navDirY, navDirX = dy, dx
        navRepeatAt = now + 0.4
        if dy ~= 0 then moveSelection(-dy) end
        if dx ~= 0 and items[selected].key then change(items[selected], dx); hasChanges = true; dirty = true end
    elseif (dy ~= 0 or dx ~= 0) and now >= navRepeatAt then
        navRepeatAt = now + 0.15
        if dy ~= 0 then moveSelection(-dy) end
        if dx ~= 0 and items[selected].kind == "num" then change(items[selected], dx); hasChanges = true; dirty = true end
    end

    local a = U.down("OculusTouch_Right_A_Click") or U.down("OculusTouch_Left_X_Click")
    local trig = math.max(U.trigger("Right"), U.trigger("Left")) > 0.7
    local b = U.down("OculusTouch_Right_B_Click")
    local activate = (a and not prevA) or (trig and not prevTrig)
    if activate then
        local it = items[selected]
        if it.action == "close" then
            M.closeMenu(pawn, pc)
            return false
        elseif it.kind == "bool" or it.kind == "choice" then
            change(it, 1); hasChanges = true; dirty = true
        end
    end
    if b and not prevB then
        prevA, prevB, prevTrig = a, b, trig
        M.closeMenu(pawn, pc)
        return false
    end
    prevA, prevB, prevTrig = a, b, trig

    if dirty then refresh() end
    return true
end

-- Test helper (cmd.txt): simulate navigation without controllers.
function M.debugInput(cmd)
    if not M.open then return end
    if cmd == "down" then moveSelection(1)
    elseif cmd == "up" then moveSelection(-1)
    elseif (cmd == "left" or cmd == "right") and items[selected].key then
        change(items[selected], cmd == "right" and 1 or -1); hasChanges = true
    elseif cmd == "select" and (items[selected].kind == "bool" or items[selected].kind == "choice") then
        change(items[selected], 1); hasChanges = true
    end
    dirty = true
end

function M.reset()
    destroyActors()
    M.open = false
    holdStart = nil
end

return M
