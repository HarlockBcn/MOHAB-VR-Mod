-- Developer tools, only loaded when debug_log=true in config.ini.
-- Write a command into Mods/MOHABPlus/cmd.txt and the mod executes it on the next frame (results go to UE4SS.log).
-- Lets the features be exercised without wearing the headset.
--
--   status                 dump the state of every feature
--   menu                   open / close the menu;  up | down | left | right | select  navigate it
--   crouch | stand         virtual crouch on / off
--   haptic                 test vibration;   damage   remove 40 health
--   simwalk | simgesture   pretend the movement stick is pushed / the arms are swinging
--   set <key> <value>      change a setting in memory (not saved)
--   openlevel <path>       open a map, e.g. /Game/R6/Maps/100_BasicTraining/P_100_BasicTraining
--   spawnsyringe | gripsyringe | syringe_overlapon   syringe tests
--   unlock                 clear the controller's foot lock (tutorial intro)
--   where                  list player controllers / pawns
local U = require("util")
local C = require("config")
local Syringe = require("syringe")
local Haptics = require("haptics")
local Crouch = require("crouch")
local Sprint = require("sprint")
local Menu = require("menu")

local M = {}
M.walk = false
M.gesture = false

local ctx = nil
local cmdPath = nil
local lastCheck = -100

function M.install(context)
    ctx = context
    cmdPath = ctx.modDir .. "\\cmd.txt"
    -- Post-hook of the movement stick axis event: overrides the value when "simwalk" is on.
    table.insert(ctx.hooks, {
        path = "/Game/R6/Core/VR/BP_VRPlayerCharacter.BP_VRPlayerCharacter_C:InpAxisEvt_MovementStick_Y_K2Node_InputAxisEvent_32",
        fn = function(c)
            if M.walk then pcall(function() c:get().MovementStick_YAxis = 1.0 end) end
        end,
    })
    U.log("devtools enabled (write commands to %s)", cmdPath)
end

-- Called every frame after the regular tick.
M.gestureIntensity = 0
function M.afterTick()
    if M.gesture then
        Sprint.gestureActive = true
        Sprint.intensity = M.gestureIntensity
    end
end

local function status(pawn, pc)
    local cmc = U.get(pawn, "CharacterMovement")
    U.log("crouched=%s sprinting=%s maxWalk=%s gesture=%s energy=%.1f syringes=%d health=%s",
        tostring(U.get(pawn, "IsCurrentlyCrouched")), tostring(U.get(pc, "IsSprinting")),
        tostring(U.get(cmc, "MaxWalkSpeed")), tostring(Sprint.gestureActive), Sprint.energy or 0,
        #(FindAllOf("BP_HealthSyringe_C") or {}),
        tostring(U.get(U.get(pawn, "VRPlayerCharacterHealthAndDamageComponent"), "Health")))
    for _, h in ipairs(ctx.hooks) do U.log("hook %s: %s", h.done and "OK " or "-- ", h.path) end
    U.log("menu open=%s  %s  standing=%s", tostring(Menu.open), Crouch.status(pawn), tostring(U.get(pawn, "IsStandingMode")))
    local cfg = {}
    for _, sec in ipairs(C.order) do for _, k in ipairs(sec[2]) do cfg[#cfg + 1] = k .. "=" .. tostring(C.get(k)) end end
    U.log("config in memory: %s", table.concat(cfg, " "))
    local w, r = Sprint.gameSpeeds(pc, pawn)
    U.log("game speeds walk=%s sprint=%s intensity=%.2f lastSpeed=%s", tostring(w), tostring(r), Sprint.intensity or 0, tostring(Sprint.lastSpeed))
    U.log("locks: game=%s foot=%s death=%s  stickY=%s inputFwd=%s moving=%s",
        tostring(U.get(pc, "bGamelocked")), tostring(U.get(pc, "bFootlocked")), tostring(U.get(pc, "bDeathlocked")),
        tostring(U.get(pawn, "MovementStick_YAxis")), tostring(U.get(pc, "InputForward")), tostring(U.get(pc, "IsCurrentlyMoving")))
    for _, l in ipairs(Syringe.debugInfo(pawn)) do U.log("%s", l) end
    local okA, vA = pcall(function() return pc:GetInputAnalogKeyState({ KeyName = FName("OculusTouch_Right_Trigger_Axis") }) end)
    local okD, vD = pcall(function() return pc:IsInputKeyDown({ KeyName = FName("OculusTouch_Left_Y_Click") }) end)
    U.log("input api: analog ok=%s v=%s | keydown ok=%s v=%s", tostring(okA), tostring(vA), tostring(okD), tostring(vD))
    local rel = U.get(U.get(pawn, "VROrigin"), "RelativeLocation")
    if rel then U.log("VROrigin rel Z=%.1f", rel.Z) end
    for _, l in ipairs(Menu.debugInfo()) do U.log("%s", l) end
end

function M.process()
    local now = os.clock()
    if now - lastCheck < 0.5 and now >= lastCheck then return end
    lastCheck = now
    local f = io.open(cmdPath, "r")
    if not f then return end
    local cmd = (f:read("*a") or ""):gsub("%s+$", "")
    f:close()
    os.remove(cmdPath)
    local pawn, pc = ctx.getPlayer()
    U.log("command: %s (player %s)", cmd, U.valid(pawn) and "ok" or "missing")

    if cmd == "where" then
        for _, c in ipairs(FindAllOf("BP_R6PlayerController_C") or {}) do
            local p = U.get(c, "SpawnedPlayerCharacter")
            U.log("PC %s spawned=%s", c:GetFullName(), U.valid(p) and p:GetFullName() or "nil")
        end
        for _, c in ipairs(FindAllOf("BP_VRPlayerCharacter_C") or {}) do U.log("pawn %s", c:GetFullName()) end
        return
    end
    if not U.valid(pawn) then return end

    if cmd == "status" then
        status(pawn, pc)
    elseif cmd == "menu" then
        if Menu.open then Menu.closeMenu(pawn, pc) else Menu.openMenu(pawn, pc) end
    elseif cmd == "up" or cmd == "down" or cmd == "left" or cmd == "right" or cmd == "select" then
        Menu.debugInput(cmd)
    elseif cmd == "crouch" or cmd == "stand" then
        Crouch.setCrouched(pawn, cmd == "crouch")
    elseif cmd == "haptic" then
        Haptics.pulse(pc, U.now(pawn), 1.0, 0.5, 0.5)
    elseif cmd == "damage" then
        local hc = U.get(pawn, "VRPlayerCharacterHealthAndDamageComponent")
        local h = U.get(hc, "Health")
        if type(h) == "number" then pcall(function() hc.Health = h - 40 end) end
    elseif cmd == "simwalk" then
        M.walk = not M.walk
        U.log("simwalk=%s", tostring(M.walk))
    elseif cmd:sub(1, 10) == "simgesture" then
        local v = tonumber(cmd:sub(12))
        if v then M.gesture, M.gestureIntensity = true, v else M.gesture = not M.gesture end
        U.log("simgesture=%s intensity=%s", tostring(M.gesture), tostring(M.gestureIntensity))
    elseif cmd:sub(1, 5) == "lift " then
        -- Simulates the head height of a standing player when testing without the headset.
        U.call(U.get(pawn, "VROrigin"), "K2_SetRelativeLocation", { X = 0, Y = 0, Z = tonumber(cmd:sub(6)) or 0 }, false, {}, true)
        U.call(pawn, "AdjustCapsuleHeightForCrouch")
    elseif cmd == "unlock" then
        pcall(function() pc.bFootlocked = false end)
    elseif cmd:sub(1, 4) == "set " then
        local k, v = cmd:match("^set%s+([%w_]+)%s+(.+)$")
        if k and C.defaults[k] ~= nil then
            local def = C.defaults[k]
            if type(def) == "boolean" then v = (v == "true") elseif type(def) == "number" then v = tonumber(v) end
            C.set(k, v)
            U.log("config %s = %s", k, tostring(v))
        end
    elseif cmd:sub(1, 10) == "openlevel " then
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        U.call(gs, "OpenLevel", pawn, FName(cmd:sub(11)), true, "")
    elseif cmd == "spawnsyringe" then
        local cls = StaticFindObject("/Game/R6/Core/Placeables/BP_HealthSyringe.BP_HealthSyringe_C")
        local ok, loc = U.call(pawn, "K2_GetActorLocation")
        if U.valid(cls) and ok then
            local a = pawn:GetWorld():SpawnActor(cls, { X = loc.X + 30, Y = loc.Y, Z = loc.Z + 40 }, { Pitch = 0, Yaw = 0, Roll = 0 })
            local cuff = U.get(pawn, "PlayerLeftCuff")
            if U.valid(a) then U.call(a, "K2_AttachToActor", U.valid(cuff) and cuff or pawn, FName("None"), 1, 1, 1, false) end
            U.log("spawned syringe valid=%s", tostring(U.valid(a)))
        end
    elseif cmd == "gripsyringe" then
        local syr = (FindAllOf("BP_HealthSyringe_C") or {})[1]
        local mc = U.get(pawn, "LeftMotionController")
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
        U.call(mc, "GripObjectByInterface", syr, xf, true, FName("None"), FName("None"), false)
    elseif cmd == "attachgrab" then
        -- Same path as grabbing a syringe from the sleeve in game.
        local syr = (FindAllOf("BP_HealthSyringe_C") or {})[1]
        local rc = U.get(pawn, "RightController")
        local okS, s0 = U.call(syr, "GetActorScale3D")
        U.call(rc, "AttachObjectToHand", syr, false)
        local okS2, s1 = U.call(syr, "GetActorScale3D")
        local hm = U.get(rc, "HandMesh")
        local okH, hs = U.call(hm, "K2_GetComponentScale")
        U.log("attachgrab: syringe scale %s -> %s, gripped=%s, hand world scale=%s",
            okS and tostring(s0.X) or "?", okS2 and tostring(s1.X) or "?", tostring(U.get(syr, "IsGripped")), okH and tostring(hs.X) or "?")
    elseif cmd == "release" then
        local rc = U.get(pawn, "RightController")
        U.call(rc, "ReleaseObjectFromHand")
        local hm = U.get(rc, "HandMesh")
        local okH, hs = U.call(hm, "K2_GetComponentScale")
        U.log("release: hand world scale=%s", okH and tostring(hs.X) or "?")
    elseif cmd == "syringe_overlapon" then
        for _, syr in ipairs(FindAllOf("BP_HealthSyringe_C") or {}) do U.call(syr, "SyringeOverlapOn") end
    end
end

return M
