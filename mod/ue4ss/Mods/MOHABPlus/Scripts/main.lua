-- MOHAB Plus - quality-of-life mod for Medal of Honor: Above and Beyond (UE 4.25, UE4SS Lua).
local VERSION = "0.1.0"

local modDir = debug.getinfo(1, "S").source:match("^@(.*)[\\/]Scripts[\\/]main%.lua$") or "."

local U = require("util")
local C = require("config")
local Syringe = require("syringe")
local WeaponGrip = require("weapongrip")
local Holster = require("holster")
local Haptics = require("haptics")
local Crouch = require("crouch")
local Sprint = require("sprint")
local Menu = require("menu")
local Slide = require("slide")
local Jump = require("jump")
local Cutscene = require("cutscene")
local FallDamage = require("falldamage")

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
                if C.enabled then Sprint.afterTickInput(ctrl, pawn, dt) end
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

-- Fall damage: StopFalling runs right before ApplyFallDamage (BP function, post-hook).
hooks[#hooks + 1] = {
    path = "/Game/R6/Core/Components/Comp_FallDamage.Comp_FallDamage_C:StopFalling",
    fn = function(ctx)
        pcall(function() FallDamage.onStopFalling(ctx:get()) end)
    end,
}

-- Weapon reload / break-action haptics (BP functions: post-hooks; each override in a subclass is its own UFunction).
for _, e in ipairs({
    { "/Game/R6/Weapons/BP_Weapon_Rifle_MagazineLoaded.BP_Weapon_Rifle_MagazineLoaded_C:LoadMag", "load" },
    { "/Game/R6/Weapons/BP_Weapon_Pistol_MagazineLoaded.BP_Weapon_Pistol_MagazineLoaded_C:LoadMag", "load" },
    { "/Game/R6/Weapons/M1_Garand/BP_m1_Garand.BP_m1_Garand_C:LoadMag", "load" },
    { "/Game/R6/Weapons/LittleJoeCrossbow/BP_LittleJoeCrossbow.BP_LittleJoeCrossbow_C:LoadMag", "load" },
    { "/Game/R6/Weapons/Speargun/BP_Speargun.BP_Speargun_C:LoadMag", "load" },
    { "/Game/R6/Weapons/SawedOff/BP_SawedOff.BP_SawedOff_C:LoadMag", "load" },
    { "/Game/R6/Weapons/BP_CombatShotgun.BP_CombatShotgun_C:LoadAnotherShell", "load" },
    { "/Game/R6/Weapons/LeverAction/BP_LeverAction.BP_LeverAction_C:LoadAnotherShell", "load" },
    { "/Game/R6/Weapons/Bazooka/BP_Bazooka.BP_Bazooka_C:LoadAmmo", "load" },
    { "/Game/R6/Weapons/SawedOff/BP_SawedOff.BP_SawedOff_C:AnimateBarrelsOpen", "open" },
    { "/Game/R6/Weapons/SawedOff/BP_SawedOff.BP_SawedOff_C:AnimateBarrelsClosed", "close" },
}) do
    local kind = e[2]
    hooks[#hooks + 1] = {
        path = e[1],
        fn = function(ctx)
            pcall(function() Haptics.onWeaponEvent(ctx:get(), kind) end)
        end,
    }
end

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

local lastPawnCheck, lastPCCheck = -100, -100
local stale = {}           -- address -> full name of a replaced pawn / controller: never pick them again

local function isStale(o)
    local name = stale[o:GetAddress()]
    return name ~= nil and name == o:GetFullName()   -- the address may be reused by a new object
end

local function dropStale(controllerToo)
    if U.valid(cachedPawn) then stale[cachedPawn:GetAddress()] = cachedPawn:GetFullName() end
    if controllerToo and U.valid(cachedPC) then stale[cachedPC:GetAddress()] = cachedPC:GetFullName() end
    cachedPawn, cachedPC = nil, nil
    lastPawnSearch = -100
end

local function findPlayer(now)
    if U.valid(cachedPawn) and U.valid(cachedPC) then
        -- The game can spawn a new player pawn (respawn, checkpoint, new mission) while the old one is still alive
        -- for a while; keep following the controller's current pawn or every feature works on the stale one.
        local t = os.clock()
        if t - lastPawnCheck < 0.5 and t >= lastPawnCheck then return cachedPawn, cachedPC end
        lastPawnCheck = t
        -- Every few seconds also make sure the cached controller is still the local one (a new level brings a new
        -- controller while the previous one may not be destroyed yet).
        if t - lastPCCheck > 3.0 or t < lastPCCheck then
            lastPCCheck = t
            for _, pc in ipairs(FindAllOf("BP_R6PlayerController_C") or {}) do
                if U.valid(pc) and not U.same(pc, cachedPC) then
                    local ok, isLocal = U.call(pc, "IsLocalController")
                    local pawn = U.get(pc, "SpawnedPlayerCharacter")
                    if (not ok or isLocal) and U.valid(pawn) and not U.same(pawn, cachedPawn) then
                        if not isStale(pc) and not isStale(pawn) then
                            U.log("player controller changed (%s -> %s)", cachedPC:GetFName():ToString(), pc:GetFName():ToString())
                            dropStale(true)
                            break
                        end
                    end
                end
            end
            if not cachedPawn then return nil, nil end
        end
        local current = U.get(cachedPC, "SpawnedPlayerCharacter")
        if not U.valid(current) then current = U.get(cachedPC, "Pawn") end
        if not U.valid(current) or U.same(current, cachedPawn) then return cachedPawn, cachedPC end
        U.log("player pawn changed (%s -> %s)", cachedPawn:GetFName():ToString(), current:GetFName():ToString())
        dropStale(false)
    end
    if now - lastPawnSearch < 1.0 and now >= lastPawnSearch then return nil, nil end
    lastPawnSearch = now
    local pcs = FindAllOf("BP_R6PlayerController_C")
    if pcs then
        for _, pc in ipairs(pcs) do
            if U.valid(pc) then
                local ok, isLocal = U.call(pc, "IsLocalController")
                local pawn = U.get(pc, "SpawnedPlayerCharacter")
                if (not ok or isLocal) and U.valid(pawn) and not isStale(pc) and not isStale(pawn) then
                    local okc, cls = pcall(function() return pawn:GetClass():GetFName():ToString() end)
                    if okc and cls and cls:find("BP_VRPlayerCharacter") then
                        cachedPawn, cachedPC = pawn, pc
                        U.log("player found: %s", pawn:GetFullName())
                        Haptics.reset(pc)
                        Slide.reset(pawn)
                        Jump.reset()
                        Sprint.reset()
                        Syringe.reset()
                        WeaponGrip.reset()
                        Cutscene.reset(pawn)
                        FallDamage.reset()
                        return pawn, pc
                    end
                end
            end
        end
    end
    return nil, nil
end

local modWasOn = true      -- master switch state seen by the last tick
local moduleErrors = {}
local function guarded(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local n = (moduleErrors[name] or 0) + 1
        moduleErrors[name] = n
        if n <= 5 or n % 500 == 0 then U.log("%s error #%d: %s", name, n, tostring(err)) end
    end
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

    -- Master switch (in-game menu): with the mod off, config.get answers "feature off" for every option, so the
    -- modules below that keep ticking restore what they changed (crouch offset, syringe sizes, grab distances...);
    -- the ones without an off option are stopped here and skipped.
    local on = C.enabled
    if on ~= modWasOn then
        modWasOn = on
        if not on then
            guarded("disable", function()
                Slide.stop(pawn, "mod off")
                Sprint.disable(pc)
                WeaponGrip.disable()
                Jump.reset()
                Cutscene.reset(pawn)
            end)
        end
        U.log("all mod changes %s", on and "ON" or "OFF (original game)")
    end

    -- Each feature runs isolated: an error in one must not stop the others.
    guarded("cutscene", Cutscene.tick, pawn, pc, now, menuOpen, function(ok)
        -- short confirmation buzz (two pulses if something was skipped)
        Haptics.pulse(pc, now, ok and 0.6 or 0.25, ok and 0.6 or 0.25, ok and 0.15 or 0.08)
    end)
    if on then guarded("sprint", Sprint.updateGesture, pawn, now) end
    if Dev then guarded("devtools", Dev.afterTick) end
    if on then guarded("jump", Jump.tick, pawn, now) end
    guarded("crouch", Crouch.tick, pawn, menuOpen, now)
    guarded("falldamage", FallDamage.tick, pawn)
    guarded("syringe", Syringe.tick, pawn, now)
    if on then guarded("weapongrip", WeaponGrip.tick, pawn, now) end
    guarded("holster", Holster.tick, pawn)
    guarded("haptics", Haptics.tick, pawn, pc, now)
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
