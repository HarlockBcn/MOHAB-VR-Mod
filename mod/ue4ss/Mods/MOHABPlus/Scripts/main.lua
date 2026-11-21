-- MOHAB Plus - quality-of-life mod for Medal of Honor: Above and Beyond (UE 4.25, UE4SS Lua).
local VERSION = "0.1.0"

local modDir = debug.getinfo(1, "S").source:match("^@(.*)[\\/]Scripts[\\/]main%.lua$") or "."

local U = require("util")
local C = require("config")
local Syringe = require("syringe")
local WeaponGrip = require("weapongrip")
local Haptics = require("haptics")
local Crouch = require("crouch")
local Sprint = require("sprint")
local Menu = require("menu")
local Slide = require("slide")
local Cutscene = require("cutscene")

C.init(modDir)
U.debug = C.get("debug_log") == true
U.log("v%s loaded (mod dir: %s)", VERSION, modDir)

-- ---------------------------------------------------------------------------------------------
-- Hooks. Blueprint classes are only in memory once a level that uses them is loaded, so hooks are
-- (re)tried until they register.
-- ---------------------------------------------------------------------------------------------
local lastTickInput = nil
local hooks = {
    {
        path = "/Game/R6/Core/Player/BP_R6PlayerController.BP_R6PlayerController_C:TickInput",
        fn = function(ctx)
            local ok, err = pcall(function()
                local ctrl = ctx:get()
                local pawn = U.get(ctrl, "SpawnedPlayerCharacter")
                local t = os.clock()
                local dt = lastTickInput and math.min(t - lastTickInput, 0.1) or 0.016
                lastTickInput = t
                Sprint.afterTickInput(ctrl, pawn, dt)
            end)
            if not ok then U.dlog("TickInput hook error: %s", tostring(err)) end
        end,
    },
    {
        path = "/Game/R6/Core/Placeables/BP_HealthSyringe.BP_HealthSyringe_C:SyringeOverlapOn",
        fn = function(ctx)
            pcall(function() Syringe.onOverlapOn(ctx:get()) end)
        end,
    },
    {
        path = "/Game/R6/Core/VR/BP_VRPlayerCharacter.BP_VRPlayerCharacter_C:HandleDamageLocationIndicator",
        fn = function(ctx, causer)
            pcall(function()
                local pawn = ctx:get()
                Haptics.onDamageCauser(causer:get(), U.now(pawn))
            end)
        end,
    },
    {
        -- Native function: the first callback runs BEFORE the grip is created.
        path = "/Script/VRExpansionPlugin.GripMotionControllerComponent:GripObjectByInterface",
        fn = function(ctx, objectToGrip)
            pcall(function() Syringe.onBeforeGrab(objectToGrip:get()) end)
        end,
    },
    {
        -- Native, pre: BP_MotionController:UpdateGrabCapsule moves the hand's grab capsule forward every frame.
        path = "/Script/Engine.SceneComponent:K2_SetRelativeLocation",
        fn = function(ctx, newLoc)
            pcall(WeaponGrip.onSetRelativeLocation, ctx, newLoc)
        end,
    },
    {
        -- Native, pre: ... and stretches it (half height 40-100 cm).
        path = "/Script/Engine.CapsuleComponent:SetCapsuleHalfHeight",
        fn = function(ctx, halfHeight)
            pcall(WeaponGrip.onSetHalfHeight, ctx, halfHeight)
        end,
    },
    {
        -- Native: BP_MotionController:AttachObjectToHand reads the syringe scale right before attaching it
        -- (and then the hand) to the controller - restore full size first.
        path = "/Script/Engine.Actor:GetActorRelativeScale3D",
        fn = function(ctx)
            pcall(function() Syringe.onBeforeGrab(ctx:get()) end)
        end,
    },
}

-- Developer tools (cmd.txt test channel), only with debug_log=true at start-up.
local Dev = nil
if C.get("debug_log") == true then
    Dev = require("devtools")
end

local function tryRegisterHooks()
    local pending = 0
    for _, h in ipairs(hooks) do
        if not h.done then
            local ok, err = pcall(RegisterHook, h.path, h.fn)
            if ok then
                h.done = true
                U.log("hooked %s", h.path)
            else
                pending = pending + 1
                h.lastErr = tostring(err)
            end
        end
    end
    return pending
end

-- ---------------------------------------------------------------------------------------------
-- Main per-frame tick (game thread)
-- ---------------------------------------------------------------------------------------------
local cachedPawn, cachedPC = nil, nil
local lastHookTry, lastConfigCheck, lastPawnSearch = -100, -100, -100
local errorCount = 0

local function findPlayer(now)
    if U.valid(cachedPawn) and U.valid(cachedPC) then return cachedPawn, cachedPC end
    if now - lastPawnSearch < 1.0 and now >= lastPawnSearch then return nil, nil end
    lastPawnSearch = now
    local pcs = FindAllOf("BP_R6PlayerController_C")
    if pcs then
        for _, pc in ipairs(pcs) do
            if U.valid(pc) then
                local ok, isLocal = U.call(pc, "IsLocalController")
                local pawn = U.get(pc, "SpawnedPlayerCharacter")
                if (not ok or isLocal) and U.valid(pawn) then
                    local okc, cls = pcall(function() return pawn:GetClass():GetFName():ToString() end)
                    if okc and cls and cls:find("BP_VRPlayerCharacter") then
                        cachedPawn, cachedPC = pawn, pc
                        U.log("player found: %s", pawn:GetFullName())
                        Haptics.reset(pc)
                        Slide.reset(pawn)
                        Sprint.reset()
                        Syringe.reset()
                        WeaponGrip.reset()
                        return pawn, pc
                    end
                end
            end
        end
    end
    return nil, nil
end

local function tick()
    local pawn, pc = findPlayer(os.clock())
    if not pawn then
        if Menu.open then Menu.reset() end
        return
    end
    local now = U.now(pawn)
    U.pc = pc
    U.debug = C.get("debug_log") == true

    if now - lastHookTry > 2.0 or now < lastHookTry then
        lastHookTry = now
        tryRegisterHooks()
    end
    if now - lastConfigCheck > 2.0 or now < lastConfigCheck then
        lastConfigCheck = now
        if not Menu.open then C.reload() end
    end

    local menuOpen = Menu.tick(pawn, pc, now)
    if menuOpen and Slide.active then Slide.stop(pawn, "menu") end
    Cutscene.tick(pawn, pc, now, menuOpen, function(ok)
        -- short confirmation buzz (two pulses if something was skipped)
        Haptics.pulse(pc, now, ok and 0.6 or 0.25, ok and 0.6 or 0.25, ok and 0.15 or 0.08)
    end)
    Sprint.updateGesture(pawn, now)
    if Dev then Dev.afterTick() end
    Crouch.tick(pawn, menuOpen, now)
    Syringe.tick(pawn, now)
    WeaponGrip.tick(pawn, now)
    Haptics.tick(pawn, pc, now)
end

local function safeTick()
    if Dev then
        local ok, err = pcall(Dev.process)
        if not ok then U.log("devtools error: %s", tostring(err)) end
    end
    local ok, err = pcall(tick)
    if not ok then
        errorCount = errorCount + 1
        if errorCount <= 20 or errorCount % 500 == 0 then
            U.log("tick error #%d: %s", errorCount, tostring(err))
        end
        -- Drop cached objects; they may have been destroyed by a level change.
        cachedPawn, cachedPC = nil, nil
    end
end

if Dev then
    Dev.install({ modDir = modDir, hooks = hooks, getPlayer = function() return cachedPawn, cachedPC end })
end

RegisterLoadMapPreHook(function()
    pcall(function()
        Menu.reset()
        cachedPawn, cachedPC = nil, nil
    end)
end)

if EngineTickAvailable then
    LoopInGameThreadAfterFrames(1, safeTick)
    U.log("using per-frame engine tick")
else
    LoopInGameThreadWithDelay(11, safeTick)
    U.log("EngineTick unavailable, using 11 ms timer")
end

-- Console helpers (UE console is not accessible in VR, but handy when testing on a monitor).
RegisterConsoleCommandHandler("mohabplus_debug", function()
    U.debug = not U.debug
    U.log("debug logging %s", U.debug and "ON" or "OFF")
    return true
end)
