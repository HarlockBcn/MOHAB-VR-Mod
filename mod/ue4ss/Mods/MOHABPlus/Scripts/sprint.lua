-- Sprint:
--  * "arms" mode: sprint while moving with the stick AND swinging the arms like running (no stick click).
--  * "both": stick click works as usual, arm swinging also sprints.
--  * "always": sprinting whenever the stick is pushed (no click, no arm swing); walking speed only while a hand
--    holding a gun, a grenade or another explosive is raised, or fires a gun. How far the stick is pushed still sets the speed (half way = close to walking).
--  * arm-swing sprint is progressive: walking speed -> game sprint speed x multiplier, by arm swing speed.
--  * the stick-click and "always" sprints are progressive too: they start at walking speed and reach the top speed over
--    RAMP_TIME; stopping, sliding, crouching or shooting starts them over.
--  * speed multiplier (1.0 - 1.5) on top of the game's sprint speed (also used by the stick-click sprint).
--
-- The game (BP_R6PlayerController.TickInput, every frame) sets CharacterMovement.MaxWalkSpeed:
--   IsSprinting -> lerp(StartSprintSpeed, MaxSprintSpeed); otherwise walking speed. IsSprinting is cleared when the
--   movement stick is released. We run right after TickInput (post-hook) to drive IsSprinting and scale the speed.
local U = require("util")
local C = require("config")
local Crouch = require("crouch")
local Slide = require("slide")

local M = {}

-- Arm swing detector state
local prev = nil          -- { t, lA, lB, rA, rB }
local energy = 0          -- smoothed swing speed (cm/s)
local active = false
local lastAbove = -100
local startedByUs = false

M.gestureActive = false
M.energy = 0
M.intensity = 0           -- 0..1: arm swing speed between the start and the full-speed thresholds

-- Called every frame from the main tick with the player pawn.
function M.updateGesture(pawn, now)
    local cam = U.get(pawn, "VRReplicatedCamera")
    local lmc = U.get(pawn, "LeftMotionController")
    local rmc = U.get(pawn, "RightMotionController")
    if not (U.valid(cam) and U.valid(lmc) and U.valid(rmc)) then
        prev = nil; energy = 0; active = false; M.gestureActive = false
        return
    end
    local ok1, camLoc = U.call(cam, "K2_GetComponentLocation")
    local ok2, fwd = U.call(cam, "GetForwardVector")
    local ok3, l = U.call(lmc, "K2_GetComponentLocation")
    local ok4, r = U.call(rmc, "K2_GetComponentLocation")
    if not (ok1 and ok2 and ok3 and ok4) then return end
    camLoc, fwd, l, r = U.vec(camLoc), U.vec(fwd), U.vec(l), U.vec(r)
    fwd.Z = 0
    fwd = U.vnorm(fwd)
    local lr, rr = U.vsub(l, camLoc), U.vsub(r, camLoc)
    -- Forward and vertical position of each hand relative to the head.
    local cur = { t = now, lA = U.vdot(lr, fwd), lB = lr.Z, rA = U.vdot(rr, fwd), rB = rr.Z }
    if prev then
        local dt = now - prev.t
        if dt > 0.0005 and dt < 0.25 then
            local vlA, vlB = (cur.lA - prev.lA) / dt, (cur.lB - prev.lB) / dt
            local vrA, vrB = (cur.rA - prev.rA) / dt, (cur.rB - prev.rB) / dt
            local sl = math.sqrt(vlA * vlA + vlB * vlB)
            local sr = math.sqrt(vrA * vrA + vrB * vrB)
            local score = 0
            if sl > 1 and sr > 1 then
                local anti = -(vlA * vrA + vlB * vrB) / (sl * sr)   -- 1 = hands move in opposite directions
                if anti > 0.2 then score = math.min(sl, sr) * anti end
            end
            -- The raw score pulses with every swing (hands stop at the ends of each swing), so rise fast and fall
            -- slowly: the energy follows the swing rhythm, not each individual swing.
            local tau = score > energy and 0.1 or 0.7
            local a = 1 - math.exp(-dt / tau)
            energy = energy + (score - energy) * a
        elseif dt >= 0.25 then
            energy = 0
        end
    end
    prev = cur

    local sens = U.clamp(C.get("sprint_arm_sensitivity"), 0.1, 5)
    local onThr = 38 / sens       -- start sprinting
    local offThr = 30 / sens      -- stop sprinting
    local fullThr = 140 / sens    -- full speed
    if energy >= onThr then
        active = true
        lastAbove = now
    elseif energy >= offThr then
        if active then lastAbove = now end
    elseif active and now - lastAbove > 0.45 then
        active = false
    end
    M.gestureActive = active
    M.energy = energy
    M.intensity = U.clamp((energy - onThr) / (fullThr - onThr), 0, 1)
end

local gameSpeeds = U.gameSpeeds
M.gameSpeeds = gameSpeeds

local smoothSpeed = nil

-- Moves the speed towards the target with limited acceleration plus easing, so it never jumps.
local ACCEL, DECEL = 260, 380      -- cm/s^2
local TURN_DECEL = 1200            -- cm/s^2 when a sharp turn cuts the speed
function M.glide(cur, target, dt, decel, accel, tauUp)
    dt = dt or 0.016
    local a = 1 - math.exp(-dt / (target > cur and tauUp or 0.3))
    local want = cur + (target - cur) * a
    local maxUp, maxDown = (accel or ACCEL) * dt, (decel or DECEL) * dt
    if want > cur + maxUp then want = cur + maxUp end
    if want < cur - maxDown then want = cur - maxDown end
    return want
end

-- Progressive start of the stick-click and "always" sprints: 0 (walking speed) -> 1 (full sprint) over RAMP_TIME, with
-- a soft start and end. Back to 0 whenever the sprint ends.
local RAMP_TIME = 1.5
local ramp = 0
local rampSpeed = nil     -- speed of the stick-click sprint last frame (the arm swing takes over from it)
local function resetRamp() ramp, rampSpeed = 0, nil end
local function advanceRamp(dt)
    ramp = math.min(1, ramp + (dt or 0.016) / RAMP_TIME)
    return ramp * ramp * (3 - 2 * ramp)
end

local lastSeen = nil      -- pawn seen last frame (detects respawn / new pawn)

-- Realistic turns: a sharp change of direction while sprinting costs speed, which then comes back gradually.
-- The turn is the angle between where the player is going (velocity) and where the input pushes (the movement
-- component's acceleration, which follows the stick and the head/hand direction). Below TURN_FREE degrees it is
-- free; from there to 180 degrees the severity goes 0 -> 1. The penalty keeps the highest recent severity and
-- recovers over TURN_RECOVER seconds; it scales the part of the speed above walking:
--   speed = walk + (sprint - walk) * (1 - strength * penalty)
-- so a 90 degree turn at full strength sprints at about half the extra speed, and a U-turn drops to walking.
local TURN_FREE = 30
local TURN_RECOVER = 1.2          -- seconds from full penalty back to none
local TURN_MIN_SPEED = 150        -- cm/s: slower than this there is no direction to compare
local COS_FREE = math.cos(math.rad(TURN_FREE))
local penalty = 0
local lastTurnLog = -100

local function updateTurnPenalty(pawn, cmc, dt)
    local strength = U.clamp(tonumber(C.get("sprint_turn_slowdown")) or 0, 0, 1)
    if strength <= 0 then penalty = 0; return 0 end
    local sev, angle = 0, 0
    local okV, v = U.call(pawn, "GetVelocity")
    local okA, a = U.call(cmc, "GetCurrentAcceleration")
    if okV and okA and v and a then
        local vx, vy, ax, ay = v.X, v.Y, a.X, a.Y
        local vs, as = math.sqrt(vx * vx + vy * vy), math.sqrt(ax * ax + ay * ay)
        if vs > TURN_MIN_SPEED and as > 1 then
            local cos = (vx * ax + vy * ay) / (vs * as)
            sev = U.clamp((COS_FREE - cos) / (COS_FREE + 1), 0, 1)
            angle = math.deg(math.acos(U.clamp(cos, -1, 1)))
        end
    end
    penalty = math.max(sev, penalty - (dt or 0.016) / TURN_RECOVER)
    if sev > 0.3 and U.now(pawn) - lastTurnLog > 0.5 then
        lastTurnLog = U.now(pawn)
        U.dlog("sprint: sharp turn %.0f deg -> speed x%.2f of the extra", angle, 1 - strength * penalty)
    end
    return strength * penalty
end

-- Direction: sprinting sideways or backwards reaches at most SIDE_BACK_FACTOR of the sprint speed (never below
-- walking). Straight ahead keeps the full speed; in between it scales with how much of the input points forward:
--   factor = SIDE_BACK_FACTOR + (1 - SIDE_BACK_FACTOR) * max(0, forward share)   (45 deg forward-diagonal ~0.85)
-- The stick input is relative to where the player faces. Used by both the arm-swing and the stick-click sprint.
local SIDE_BACK_FACTOR = 0.5
local function directionFactor(ctrl)
    local fwd, right = U.get(ctrl, "InputForward") or 0, U.get(ctrl, "InputRight") or 0
    local len = math.sqrt(fwd * fwd + right * right)
    if len < 0.05 then return 1 end
    return SIDE_BACK_FACTOR + (1 - SIDE_BACK_FACTOR) * math.max(0, fwd / len)
end

-- Firing: the trigger of a hand holding a weapon is pulled (or the weapon is firing). Stick-click sprint is cancelled
-- while firing, and so is the "always" sprint (guns only, not grenades); the arm-swing sprint is not (swinging the arms
-- and shooting is the player's choice).
local weaponClass = nil
local isGun
local function isFiring(pawn, gunsOnly)
    if not U.valid(weaponClass) then
        weaponClass = StaticFindObject("/Game/R6/Core/Weapons/BP_WeaponBase.BP_WeaponBase_C")
        if not U.valid(weaponClass) then return false end
    end
    for _, side in ipairs({ "Left", "Right" }) do
        local obj = U.get(U.get(pawn, side .. "Controller"), "AttachedObject")
        if U.valid(obj) then
            local ok, weapon = pcall(function() return obj:IsA(weaponClass) end)
            if ok and weapon and (not gunsOnly or isGun(obj))
                and (U.trigger(side) > 0.5 or U.get(obj, "IsWeaponFiring_0") == true) then return true end
        end
    end
    return false
end
local lastFireCancelLog = -100

-- "Always" and stick-click sprints: is a gun (or a grenade / explosive to throw) raised? The hand that counts is the one holding the gun by its main grip (the off hand holds
-- the front grip, another actor), so a rifle carried across the chest while running is not "raised". Compared with the
-- eyes, so it works for any height: raised from RAISE_ON cm below the eyes up, lowered from RAISE_OFF down. It has to
-- stay that way for a moment, so hands that swing up while running or move while reloading don't change the pace.
local RAISE_ON, RAISE_OFF = 35, 42
local RAISE_DELAY, LOWER_DELAY = 0.12, 0.25     -- s
local FIRE_HOLD = 0.6                           -- s walking after the last shot (no sprint burst between shots)
local RAISE_DECEL = 900                         -- cm/s^2: quick but not instant slow down to aim
local grenadeClass = nil
local raised, raisedSince = false, nil
local lastFireT = -100
local coast = nil         -- speed left after raising a weapon cancelled the stick-click sprint (slows down gradually)

isGun = function(obj)
    if not U.valid(obj) then return false end
    if not U.valid(weaponClass) then
        weaponClass = StaticFindObject("/Game/R6/Core/Weapons/BP_WeaponBase.BP_WeaponBase_C")
    end
    if not U.valid(grenadeClass) then
        grenadeClass = StaticFindObject("/Game/R6/Core/Weapons/BP_GrenadeBase.BP_GrenadeBase_C")
    end
    if not U.valid(weaponClass) then return false end
    local ok, gun = pcall(function()
        return obj:IsA(weaponClass) and not (U.valid(grenadeClass) and obj:IsA(grenadeClass))
    end)
    return ok and gun == true
end

-- Weapons (grenades and C4 included) and the explosives that are mission objects, which have no common class (they
-- share it with ashtrays, bottles...) and are told apart by name. Grenade pins / caps held by the other hand don't count.
local EXPLOSIVES = { "Dynamite", "Grenade", "TimedExplosive", "ThrowMine", "MakeshiftBomb", "BombHolster", "ChargeBlock",
    "ChemicalCharge" }
local function countsWhenRaised(obj)
    if not U.valid(obj) then return false end
    if isGun(obj) then return true end
    local okG, grenade = pcall(function() return U.valid(grenadeClass) and obj:IsA(grenadeClass) end)
    if okG and grenade then return true end
    local okN, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    if not okN or type(name) ~= "string" or name:find("_Pin") or name:find("_Cap") then return false end
    for _, s in ipairs(EXPLOSIVES) do
        if name:find(s, 1, true) then return true end
    end
    return false
end

local function updateRaised(pawn, now)
    local okC, cam = U.call(U.get(pawn, "VRReplicatedCamera"), "K2_GetComponentLocation")
    local best = nil        -- cm below the eyes of the highest hand holding a gun or explosive
    if okC and cam then
        for _, side in ipairs({ "Left", "Right" }) do
            if countsWhenRaised(U.get(U.get(pawn, side .. "Controller"), "AttachedObject")) then
                local ok, l = U.call(U.get(pawn, side .. "MotionController"), "K2_GetComponentLocation")
                if ok and l then
                    local below = cam.Z - l.Z
                    if not best or below < best then best = below end
                end
            end
        end
    end
    local want = best ~= nil and best <= (raised and RAISE_OFF or RAISE_ON)
    if want == raised then
        raisedSince = nil
    else
        if not raisedSince or now < raisedSince then raisedSince = now end
        -- Let go / thrown: nothing to aim any more, no need to wait.
        if best == nil or now - raisedSince >= (want and RAISE_DELAY or LOWER_DELAY) then
            raised, raisedSince = want, nil
            U.dlog("sprint: weapon %s (%s cm below the eyes)", want and "raised" or "lowered",
                best and string.format("%.0f", best) or "let go,")
        end
    end
    return raised
end

-- "Always" mode, every frame after TickInput. Returns false when the game's own rules apply (crouched, sprint disabled).
local function alwaysSprint(ctrl, pawn, cmc, dt, mult, isSprinting, moving)
    local now = U.now(pawn)
    local gunUp = raised
    if isFiring(pawn, true) then lastFireT = now end
    if now < lastFireT then lastFireT = -100 end
    local firing = now - lastFireT < FIRE_HOLD
    if not moving then return true end
    if U.get(ctrl, "DisableSprinting") == true or Crouch.virtualCrouched
        or U.get(pawn, "IsCurrentlyCrouched") == true then
        -- Crouched: our sprint ends; one the player starts with a stick click stands them up as usual.
        if startedByUs then pcall(function() ctrl.IsSprinting = false end) end
        startedByUs, smoothSpeed, penalty = false, nil, 0
        resetRamp()
        return false
    end
    local walk, sprint = gameSpeeds(ctrl, pawn)
    local fwd, right = U.get(ctrl, "InputForward") or 0, U.get(ctrl, "InputRight") or 0
    local stick = U.clamp(math.sqrt(fwd * fwd + right * right), 0, 1)
    local slow = walk * stick
    local target, decel, accel, run = slow, RAISE_DECEL, nil, false
    if gunUp or firing then
        penalty = 0
        -- No shooting at sprint speed: down to walking at once (raising a gun slows down gradually).
        if firing then
            smoothSpeed = slow
            resetRamp()
        else
            -- A gun raised only for a moment does not start over from walking: follows the slow down.
            ramp = math.max(0, ramp - (dt or 0.016))
        end
    else
        local cut = updateTurnPenalty(pawn, cmc, dt)
        local back = directionFactor(ctrl)
        local full = math.max(walk, (walk + (sprint * mult - walk) * (1 - cut)) * back)
        -- Squared: small pushes stay close to walking, so there is still fine control without raising a gun.
        target = slow + (full - walk) * stick * stick * advanceRamp(dt)
        accel = 1.5 * (sprint * mult - walk) / RAMP_TIME      -- steepest point of the ramp: the glide must not slow it down
        if cut > 0.05 or back < 0.99 then decel = TURN_DECEL end
        run = target > walk * (isSprinting and 1.0 or 1.15)
    end
    if run ~= isSprinting then
        if run then U.call(ctrl, "StartSprinting") else pcall(function() ctrl.IsSprinting = false end) end
    end
    startedByUs = run
    smoothSpeed = math.max(slow, M.glide(smoothSpeed or slow, target, dt, decel, accel, 0.08))
    pcall(function() cmc.MaxWalkSpeed = smoothSpeed end)
    M.lastSpeed = smoothSpeed
    return true
end

-- Speed guard: MaxWalkSpeed must never go above the configured top sprint speed (game sprint speed x multiplier).
-- The game's own sprint speed is Lerp(StartSprintSpeed, MaxSprintSpeed, alpha) with an unclamped alpha, so it can
-- overshoot; anything above the cap is clamped and logged with the values involved (to find the cause).
local lastGuardLog = -100
local MSD = {
    start = "StartSprintSpeed_16_8A5281B24785F79CEDE59E92E0DBE5AB",
    max = "MaxSprintSpeed_3_6EB63D2A41BC620D5EEA93B63C088CB3",
    lerpTime = "SprintSpeedLerpTime_9_5ECBA5464BDB5F0BFA39FFAAE8ADB235",
    alphaMult = "SprintSpeedLerpAlphaMultiplier_11_3D016C8C4C823D5F0A4EEDA9AC38CC5D",
}
local function guardSpeed(ctrl, pawn, gameSpeed)
    if Slide.active then return end
    local cmc = U.get(pawn, "CharacterMovement")
    local speed = U.get(cmc, "MaxWalkSpeed")
    if type(speed) ~= "number" then return end
    local _, sprint = gameSpeeds(ctrl, pawn)
    local cap = sprint * U.clamp(C.get("sprint_speed_multiplier"), 1.0, 1.5)
    local v = U.get(cmc, "Velocity")
    local vh = v and math.sqrt(v.X * v.X + v.Y * v.Y) or 0
    local over = speed > cap * 1.02
    local fast = vh > cap * 1.2 and U.get(cmc, "MovementMode") == 1    -- walking on the ground
    if over then pcall(function() cmc.MaxWalkSpeed = cap end) end
    if (over or fast) and U.now(pawn) - lastGuardLog > 1.0 then
        lastGuardLog = U.now(pawn)
        local msd = {}
        pcall(function()
            local d = pawn.MoveSpeedData
            for k, f in pairs(MSD) do msd[k] = d[f] end
        end)
        U.log("sprint guard: MaxWalkSpeed %.0f (game set %s) velocity %.0f, cap %.0f%s | sprinting=%s ours=%s arms=%s(%.2f) " ..
            "smooth=%s | MoveSpeedData start=%s max=%s lerpTime=%s alphaMult=%s speedMult=%s",
            speed, tostring(gameSpeed), vh, cap, over and " -> clamped" or "",
            tostring(U.get(ctrl, "IsSprinting")), tostring(startedByUs), tostring(M.gestureActive), M.intensity or 0,
            tostring(smoothSpeed), tostring(msd.start), tostring(msd.max), tostring(msd.lerpTime),
            tostring(msd.alphaMult), tostring(U.get(ctrl, "MovementSpeedMultiplier")))
    end
end

local afterTickInput

-- Post-hook of BP_R6PlayerController_C:TickInput (runs every frame right after the game set MaxWalkSpeed).
function M.afterTickInput(ctrl, pawn, dt)
    if not U.valid(pawn) then return end
    local gameSpeed = U.get(U.get(pawn, "CharacterMovement"), "MaxWalkSpeed")
    afterTickInput(ctrl, pawn, dt)
    pcall(guardSpeed, ctrl, pawn, gameSpeed)
end

afterTickInput = function(ctrl, pawn, dt)
    -- A slide in progress drives the movement itself.
    if Slide.update(ctrl, pawn, U.now(pawn)) then
        startedByUs, smoothSpeed, coast = false, nil, nil
        resetRamp()
        return
    end
    if not M.gestureActive then Slide.gestureReleased() end
    local mode = C.get("sprint_mode")
    local mult = U.clamp(C.get("sprint_speed_multiplier"), 1.0, 1.5)
    local cmc = U.get(pawn, "CharacterMovement")
    local isSprinting = U.get(ctrl, "IsSprinting") == true
    local moving = U.get(ctrl, "IsCurrentlyMoving") == true
    local dead = U.get(ctrl, "bDeathlocked") == true

    -- New pawn or death: forget any sprint state.
    local addr = pawn:GetAddress()
    if addr ~= lastSeen or dead then
        lastSeen = addr
        if isSprinting then pcall(function() ctrl.IsSprinting = false end) end
        isSprinting, startedByUs, smoothSpeed = false, false, nil
        M.reset()
        if dead then return end
    end
    if not moving then startedByUs = false; smoothSpeed = nil; penalty = 0; coast = nil; resetRamp() end
    if mode ~= "arms" then updateRaised(pawn, U.now(pawn)) end

    if mode == "always" then
        coast = nil
        if alwaysSprint(ctrl, pawn, cmc, dt, mult, isSprinting, moving) then return end
        isSprinting = U.get(ctrl, "IsSprinting") == true
    elseif mode == "arms" or mode == "both" then
        local disabled = U.get(ctrl, "DisableSprinting") == true
        -- Swinging the arms while crouched (stick crouch or the game's own) does nothing: no sprint, no standing up.
        local crouched = Crouch.virtualCrouched or U.get(pawn, "IsCurrentlyCrouched") == true
        local want = M.gestureActive and moving and not disabled and not crouched
        local walk, sprint = gameSpeeds(ctrl, pawn)
        local fwd, right = U.get(ctrl, "InputForward") or 0, U.get(ctrl, "InputRight") or 0
        local stick = U.clamp(math.sqrt(fwd * fwd + right * right), 0, 1)

        if want then
            if not isSprinting then
                U.call(ctrl, "StartSprinting")    -- IsSprinting = true (sprint animation / camera shake)
                isSprinting = true
            end
            startedByUs = true
            -- Progressive: the swing rhythm sets the top speed; the speed glides towards it (no jumps per swing).
            local cut = updateTurnPenalty(pawn, cmc, dt)
            local target = (walk + (sprint * mult - walk) * M.intensity * (1 - cut)) * stick
            local back = directionFactor(ctrl)
            target = math.max(walk * stick, target * back)
            if not smoothSpeed then
                local cur = rampSpeed or coast or U.get(cmc, "MaxWalkSpeed")
                smoothSpeed = (type(cur) == "number" and cur > 0) and cur or walk * stick
            end
            resetRamp()
            coast = nil
            smoothSpeed = M.glide(smoothSpeed, target, dt, (cut > 0.05 or back < 0.99) and TURN_DECEL or nil)
            pcall(function() cmc.MaxWalkSpeed = smoothSpeed end)
            M.lastSpeed = smoothSpeed
            return
        end
        if startedByUs and moving and smoothSpeed and not disabled and not crouched and smoothSpeed > walk * stick + 5 then
            -- Arms stopped: slow down smoothly to walking speed instead of braking at once.
            smoothSpeed = M.glide(smoothSpeed, walk * stick, dt)
            pcall(function() cmc.MaxWalkSpeed = smoothSpeed end)
            M.lastSpeed = smoothSpeed
            return
        end
        if startedByUs or (mode == "arms" and isSprinting) then
            -- Stop: back to walking speed this very frame (the game computed a sprint speed).
            pcall(function() ctrl.IsSprinting = false end)
            pcall(function() cmc.MaxWalkSpeed = walk * stick end)
            isSprinting, startedByUs, smoothSpeed = false, false, nil
            return
        end
    end

    -- Stick-click sprint (game behaviour) with the speed multiplier. No sprinting while firing: cancel it (click the
    -- stick again to sprint after shooting).
    if isSprinting and isFiring(pawn) then
        pcall(function() ctrl.IsSprinting = false end)
        local walk = gameSpeeds(ctrl, pawn)
        local fwd, right = U.get(ctrl, "InputForward") or 0, U.get(ctrl, "InputRight") or 0
        local stick = U.clamp(math.sqrt(fwd * fwd + right * right), 0, 1)
        pcall(function() cmc.MaxWalkSpeed = walk * stick end)
        penalty, coast = 0, nil
        resetRamp()
        if U.now(pawn) - lastFireCancelLog > 1.0 then
            lastFireCancelLog = U.now(pawn)
            U.dlog("sprint: stick sprint cancelled (firing)")
        end
        return
    end
    local crouched = Crouch.virtualCrouched or U.get(pawn, "IsCurrentlyCrouched") == true
    -- Nor while a weapon is raised (not "arms": no stick click there). Crouched, the click stands the player up first.
    if isSprinting and raised and not crouched then
        pcall(function() ctrl.IsSprinting = false end)
        isSprinting = false
        coast = rampSpeed or coast or 0     -- 0: not running yet, straight to walking (the game computed a sprint speed)
        U.dlog("sprint: stick sprint cancelled (weapon raised)")
    end
    if coast then
        local walk = gameSpeeds(ctrl, pawn)
        local fwd, right = U.get(ctrl, "InputForward") or 0, U.get(ctrl, "InputRight") or 0
        local slow = walk * U.clamp(math.sqrt(fwd * fwd + right * right), 0, 1)
        coast = math.max(slow, M.glide(coast, slow, dt, RAISE_DECEL))
        if isFiring(pawn) then coast = slow end
        if isSprinting or crouched then
            coast = nil
        else
            pcall(function() cmc.MaxWalkSpeed = coast end)
            if coast <= slow + 5 then coast = nil end
        end
    end
    if isSprinting and U.get(pawn, "IsCurrentlyCrouched") ~= true then
        local cut = updateTurnPenalty(pawn, cmc, dt)
        local speed = U.get(cmc, "MaxWalkSpeed")
        local back = directionFactor(ctrl)
        local k = advanceRamp(dt)
        if type(speed) == "number" and speed > 0 then
            local walk = gameSpeeds(ctrl, pawn)
            local fast = speed * mult
            if type(walk) == "number" and fast > walk then
                fast = walk + (fast - walk) * (1 - cut)
                fast = math.max(walk, fast * back)
                fast = walk + (fast - walk) * k
            end
            pcall(function() cmc.MaxWalkSpeed = fast end)
            rampSpeed = fast
        end
    else
        penalty = 0
        resetRamp()
    end
end

-- Master switch turned off: hand the movement back to the game (it sets MaxWalkSpeed again on its next TickInput).
function M.disable(ctrl)
    if startedByUs and U.valid(ctrl) then pcall(function() ctrl.IsSprinting = false end) end
    smoothSpeed, penalty = nil, 0
    M.reset()
end

function M.reset()
    prev, energy, active, startedByUs = nil, 0, false, false
    raised, raisedSince, coast = false, nil, nil
    resetRamp()
    M.gestureActive, M.intensity, M.energy = false, 0, 0
end

return M
