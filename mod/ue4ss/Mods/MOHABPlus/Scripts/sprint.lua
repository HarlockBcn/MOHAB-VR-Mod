-- Sprint:
--  * "arms" mode: sprint while moving with the stick AND swinging the arms like running (no stick click).
--  * "both": stick click works as usual, arm swinging also sprints.
--  * arm-swing sprint is progressive: walking speed -> game sprint speed x multiplier, by arm swing speed.
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
function M.glide(cur, target, dt)
    dt = dt or 0.016
    local a = 1 - math.exp(-dt / 0.3)
    local want = cur + (target - cur) * a
    local maxUp, maxDown = ACCEL * dt, DECEL * dt
    if want > cur + maxUp then want = cur + maxUp end
    if want < cur - maxDown then want = cur - maxDown end
    return want
end
local lastSeen = nil      -- pawn seen last frame (detects respawn / new pawn)

-- Post-hook of BP_R6PlayerController_C:TickInput (runs every frame right after the game set MaxWalkSpeed).
function M.afterTickInput(ctrl, pawn, dt)
    if not U.valid(pawn) then return end
    -- A slide in progress drives the movement itself.
    if Slide.update(ctrl, pawn, U.now(pawn)) then
        startedByUs, smoothSpeed = false, nil
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
    if not moving then startedByUs = false; smoothSpeed = nil end

    if mode == "arms" or mode == "both" then
        local disabled = U.get(ctrl, "DisableSprinting") == true
        if M.gestureActive and moving and not disabled and Crouch.virtualCrouched and not Slide.blockGesture then
            Crouch.virtualCrouched = false        -- swinging the arms while crouched stands the player up
        end
        local crouched = U.get(pawn, "IsCurrentlyCrouched") == true
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
            local target = (walk + (sprint * mult - walk) * M.intensity) * stick
            if not smoothSpeed then
                local cur = U.get(cmc, "MaxWalkSpeed")
                smoothSpeed = (type(cur) == "number" and cur > 0) and cur or walk * stick
            end
            smoothSpeed = M.glide(smoothSpeed, target, dt)
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

    -- Stick-click sprint (game behaviour) with the speed multiplier.
    if isSprinting and mult > 1.001 and U.get(pawn, "IsCurrentlyCrouched") ~= true then
        local speed = U.get(cmc, "MaxWalkSpeed")
        if type(speed) == "number" and speed > 0 then
            pcall(function() cmc.MaxWalkSpeed = speed * mult end)
        end
    end
end

function M.reset()
    prev, energy, active, startedByUs = nil, 0, false, false
    M.gestureActive, M.intensity, M.energy = false, 0, 0
end

return M
