-- Virtual crouch with the turn stick: push down = crouch, push up = stand up (or jump if already standing, see jump.lua).
-- The turn stick Y axis is not used by the game (turning only uses X).
--
-- Standing play mode (IsStandingMode = true, the usual case): the game has no button crouch; it derives
-- "crouched" from the real head height (camera height above the floor <= PlayerCrouchHeight, 120 cm) and scales
-- the capsule from that height. We lower the VR origin by CrouchDistance (60 cm) so the camera goes down and the
-- game itself treats the player as crouched (capsule, AI visibility, crouch walking speed).
--
-- Seated mode (IsStandingMode = false): we use the game's own button crouch (UserToggleVRCrouch).
local U = require("util")
local C = require("config")
local Slide = require("slide")
local Jump = require("jump")

local M = {}

M.virtualCrouched = false
local armed = true          -- the stick must return to the centre before the next action
local applied = 0           -- offset currently applied to VROrigin (cm, positive = down)
local baseApplied = 0       -- part of it from the crouch / slide (applied also includes the landing dip)
local lastPawnAddr = nil
local lastNow = nil
local SPEED = 260           -- cm/s transition speed
local lastSprintT = -100    -- last time the controller was sprinting (the game may clear it the frame we crouch)
local physArmed = false     -- physical crouch: the head must be above the crouch height before a new slide
local PHYS_EASE = 0.18      -- s to ease the view into the crouch height at the start of a physical slide
local lastStandH = nil      -- standing head height (cm): follows the head up, decays slowly
local lastStandT = nil
local PHYS_DROP = 22        -- cm below the standing height that counts as a physical crouch while sprinting
-- Slide started by a physical crouch: { head0 = head height at start, cam0 = camera tracking Z at start,
-- targetHead = the head height the stick crouch would give }. While it lasts, the view is held at targetHead
-- whatever the real head does; afterwards it goes back to the real height.
M.physSlide = nil
M.minHeadHeight = 70        -- never push the camera below this height above the floor (cm)
-- Hard landing (see jump.lua): the view bends down and comes back up by itself.
-- { t0 =, depth = cm, down =, hold =, up = s }
M.land = nil
local STICK_CONE = 0.7      -- stick crouch / jump: |x| <= 0.7 |y|, i.e. within 35 degrees of straight up / down
local stickPeak = 0         -- strongest up push since the stick left the centre (for the "too weak" log)

-- In standing mode the game keeps VROrigin at Z = 0 (ConfigureCharacterHeight / ResetOrientation), so the
-- crouch offset is written as an absolute Z = -offset.
local function applyOffset(pawn, offset)
    local origin = U.get(pawn, "VROrigin")
    if not U.valid(origin) then return false end
    local rel = U.get(origin, "RelativeLocation")
    local x, y = 0, 0
    if rel then x, y = rel.X or 0, rel.Y or 0 end
    local ok, err = U.call(origin, "K2_SetRelativeLocation", { X = x, Y = y, Z = -offset }, false, {}, true)
    if not ok then U.dlog("K2_SetRelativeLocation failed: %s", tostring(err)) end
    return ok
end

local function originZ(pawn)
    local rel = U.get(U.get(pawn, "VROrigin"), "RelativeLocation")
    return rel and rel.Z or 0
end

-- Camera height from tracking only (relative to the VR origin): not affected by our offset or the capsule resize.
local function camTrackZ(pawn)
    local rel = U.get(U.get(pawn, "VRReplicatedCamera"), "RelativeLocation")
    return rel and rel.Z or nil
end

-- Offset the stick crouch applies for a given real head height (cm, positive = down).
local function crouchDepth(pawn, raw)
    local dist = U.get(pawn, "CrouchDistance")
    if type(dist) ~= "number" or dist <= 0 then dist = 60 end
    local crouchH = U.get(pawn, "PlayerCrouchHeight")
    if type(crouchH) ~= "number" then crouchH = 120 end
    -- deep enough for the game to detect the crouch (<= PlayerCrouchHeight) even for tall players,
    -- but never bring the eyes closer than minHeadHeight to the floor.
    local fixed = math.max(dist, raw - (crouchH - 10))
    return U.clamp(math.min(fixed, raw - M.minHeadHeight), 0, 150)
end

local function headHeight(pawn)
    -- Same formula as BP_VRPlayerCharacter:GetPlayerCurrentHeight
    local ok1, loc = U.call(pawn, "K2_GetActorLocation")
    local cap = U.get(pawn, "CapsuleComponent")
    local ok2, half = U.call(cap, "GetUnscaledCapsuleHalfHeight")
    local cam = U.get(pawn, "VRReplicatedCamera")
    local ok3, camLoc = U.call(cam, "K2_GetComponentLocation")
    if not (ok1 and ok2 and ok3) then U.dlog("headHeight: %s %s %s / %s", tostring(ok1), tostring(ok2), tostring(ok3), tostring(half)) end
    if ok1 and ok2 and ok3 and type(half) == "number" then
        return camLoc.Z - (loc.Z - half)
    end
    return nil
end

function M.setCrouched(pawn, want)
    if U.get(pawn, "IsStandingMode") == false then
        -- Seated mode: game's own crouch.
        local crouched = U.get(pawn, "IsCurrentlyCrouched") == true
        if crouched ~= want then U.call(pawn, "UserToggleVRCrouch") end
        M.virtualCrouched = false
        return
    end
    M.virtualCrouched = want
    U.dlog("virtual crouch -> %s", tostring(want))
end

function M.toggle(pawn)
    M.setCrouched(pawn, not M.virtualCrouched)
end

-- Respawn: the game keeps the same pawn when it reloads a checkpoint, so a stick crouch from before dying would go on.
-- The screen is still black: the view goes up at once.
function M.standUp(pawn)
    if U.get(pawn, "IsStandingMode") == false then
        M.setCrouched(pawn, false)
        return
    end
    local was = M.virtualCrouched or applied ~= 0
    M.virtualCrouched, M.physSlide, M.land, M.fixedTarget = false, nil, nil, nil
    armed, stickPeak, lastStandH, lastStandT = false, 0, nil, nil
    if was and applyOffset(pawn, 0) then
        applied, baseApplied = 0, 0
        U.call(pawn, "AdjustCapsuleHeightForCrouch")
        U.log("respawn: standing up")
    end
end

local function smooth(x) x = U.clamp(x, 0, 1); return x * x * (3 - 2 * x) end

-- k = 0..1: how hard the landing was. Depth goes from 45% of the stick crouch to all of it.
local function startLand(pawn, k, now)
    if U.get(pawn, "IsStandingMode") == false then return end
    local h = headHeight(pawn)
    if not h then return end
    local raw = h + applied                         -- real head height without our offset
    local depth = crouchDepth(pawn, raw) * (0.45 + 0.55 * k)
    depth = math.min(depth, raw - M.minHeadHeight)
    if depth <= 1 then return end
    M.land = { t0 = now, depth = depth, down = 0.1, hold = 0.12 + 0.3 * k, up = 0.45 + 0.4 * k }
    U.dlog("hard landing: view down %.0f cm (head %.0f)", depth, raw)
end

local function landDip(now)
    local L = M.land
    if not L then return 0 end
    local t = now - L.t0
    local f
    if t < L.down then f = smooth(t / L.down)
    elseif t < L.down + L.hold then f = 1
    elseif t < L.down + L.hold + L.up then f = 1 - smooth((t - L.down - L.hold) / L.up)
    else M.land = nil; return 0 end
    return L.depth * f
end

local function updateOffset(pawn, now)
    -- (now is also used by the physical-slide ease)
    local dt = 0
    if lastNow then dt = U.clamp(now - lastNow, 0, 0.1) end
    lastNow = now

    local standing = U.get(pawn, "IsStandingMode") ~= false
    local blocked = U.get(pawn, "IsClimbing") == true
    local seat = U.get(pawn, "SeatInformation")
    if seat then
        local ok, sitting = pcall(function() return seat.bSitting end)
        if ok and sitting then blocked = true end
    end
    if not standing or blocked then M.virtualCrouched = false; M.physSlide = nil; M.land = nil end

    local target = 0
    local direct = false
    if M.physSlide and not Slide.active then M.physSlide = nil end
    if M.physSlide then
        local ps = M.physSlide
        local camZ = camTrackZ(pawn) or ps.cam0
        local raw = ps.head0 + (camZ - ps.cam0)           -- real head height now
        target = U.clamp(raw - ps.targetHead, -60, 150)   -- negative raises the view if the real head is lower
        -- Ease into the held height (smoothstep over PHYS_EASE s); the target already follows the real head every
        -- frame, so it is applied directly instead of through the speed limit.
        local k = U.clamp((now - ps.t0) / PHYS_EASE, 0, 1)
        target = target * k * k * (3 - 2 * k)
        direct = true
        M.fixedTarget = nil
    elseif M.virtualCrouched then
        if not M.fixedTarget then
            -- Decide the depth once, when the crouch starts (avoids feedback with the capsule resize).
            local dist = U.get(pawn, "CrouchDistance")
            if type(dist) ~= "number" or dist <= 0 then dist = 60 end
            local fixed = dist
            local h = headHeight(pawn)
            if h then fixed = crouchDepth(pawn, h + applied) end   -- real head height without our offset
            M.fixedTarget = fixed
        end
        target = M.fixedTarget
    else
        M.fixedTarget = nil
    end

    if U.debug and (M._dbgT or 0) + 1 < now then
        M._dbgT = now
        U.dlog("crouch dbg: want=%s target=%.1f applied=%.1f dt=%.4f standing=%s blocked=%s", tostring(M.virtualCrouched), target, applied, dt, tostring(standing), tostring(blocked))
    end
    if applied == 0 and target == 0 and not M.land then baseApplied = 0; return end
    local step = (Slide.active and 520 or SPEED) * dt
    local newBase
    if direct then newBase = target
    elseif target > baseApplied then newBase = math.min(target, baseApplied + step)
    else newBase = math.max(target, baseApplied - step) end
    if math.abs(newBase) < 0.01 then newBase = 0 end
    -- The landing dip goes on top: whichever is lower wins.
    local newApplied = math.max(newBase, landDip(now))
    if math.abs(newApplied) < 0.01 then newApplied = 0 end
    -- Write when the value changes or when the game moved the origin back (e.g. recenter).
    if newApplied ~= applied or math.abs(originZ(pawn) + newApplied) > 0.5 then
        if applyOffset(pawn, newApplied) then
            applied, baseApplied = newApplied, newBase
            U.call(pawn, "AdjustCapsuleHeightForCrouch")
        end
    else
        baseApplied = newBase
    end
end

-- Crouched walking speed. BP_R6PlayerController.TickInput multiplies the walking speed by its CrouchSpeedMultiplier
-- while the pawn IsCurrentlyCrouched, which covers the physical crouch, the stick crouch (the lowered view makes the game
-- detect a crouch) and the seated button crouch; the slide also ends at that speed. We set it to crouch_speed and keep
-- the game's own value per controller (crouch_speed <= 0 puts it back: master switch off).
local origCrouchMult, multPC = nil, nil
local function applyCrouchSpeed()
    local pc = U.pc
    if not U.valid(pc) then return end
    local addr = pc:GetAddress()
    if addr ~= multPC then multPC, origCrouchMult = addr, nil end
    local cur = U.get(pc, "CrouchSpeedMultiplier")
    if type(cur) ~= "number" then return end
    if origCrouchMult == nil then
        origCrouchMult = cur
        U.log("game crouch speed multiplier: %.2f", cur)
    end
    local want = tonumber(C.get("crouch_speed")) or 0
    if want <= 0 then want = origCrouchMult end
    if math.abs(cur - want) > 0.001 then pcall(function() pc.CrouchSpeedMultiplier = want end) end
end

function M.tick(pawn, menuOpen, now)
    pcall(applyCrouchSpeed)
    local addr = pawn:GetAddress()
    if addr ~= lastPawnAddr then
        lastPawnAddr = addr
        applied, baseApplied, lastNow, armed = 0, 0, nil, false
        M.land = nil
        M.fixedTarget = nil
        M.virtualCrouched = false
        M.physSlide, lastStandH, lastStandT = nil, nil, nil
    end

    local crouchOn, jumpOn = C.get("crouch_stick"), C.get("jump_enabled")
    if not crouchOn then M.virtualCrouched = false end
    if not crouchOn and not jumpOn then
        armed = false
    elseif not menuOpen then
        local y = U.get(pawn, "FlickTurningStick_YAxis")
        if type(y) ~= "number" then y = U.axis("OculusTouch_Right_Thumbstick_Y") end
        local x = U.get(pawn, "FlickTurningStick_XAxis")
        if type(x) ~= "number" then x = U.axis("OculusTouch_Right_Thumbstick_X") end
        local thr = C.get("crouch_stick_threshold")
        -- Direction, not just the vertical part: a push slightly to the side still counts (the vertical part of
        -- a stick pushed fully at 20 degrees is only 0.94), while snap turns (mostly sideways) never do.
        local mag = math.sqrt(x * x + y * y)
        local inCone = math.abs(x) <= STICK_CONE * math.abs(y)
        if math.abs(y) < 0.3 then
            if armed and stickPeak >= 0.6 and jumpOn then
                U.log("jump stick: pushed up to %.2f only (needs %.2f)", stickPeak, thr)
            end
            armed, stickPeak = true, 0
        elseif armed then
            if y > 0 and inCone and mag > stickPeak then stickPeak = mag end
            if y < 0 and inCone and mag >= thr and crouchOn then
                armed, stickPeak = false, 0
                -- Crouching while sprinting starts a slide (ends crouched).
                if U.pc and U.get(U.pc, "IsSprinting") == true and U.get(pawn, "IsStandingMode") ~= false then
                    local walk = U.gameSpeeds(U.pc, pawn)
                    Slide.tryStart(pawn, U.pc, now, walk)
                end
                -- Always sprinting: without this the rule below (sprinting stands the player up) would undo a crouch
                -- that did not become a slide.
                if C.get("sprint_mode") == "always" and U.pc then
                    pcall(function() U.pc.IsSprinting = false end)
                end
                M.setCrouched(pawn, true)
            elseif y > 0 and inCone and mag >= thr then
                armed, stickPeak = false, 0
                -- Up: stand up if crouched with the stick, otherwise jump.
                local seatedCrouch = U.get(pawn, "IsStandingMode") == false and U.get(pawn, "IsCurrentlyCrouched") == true
                if (crouchOn and (M.virtualCrouched or seatedCrouch)) or not jumpOn then
                    M.setCrouched(pawn, false)
                elseif U.pc then
                    Jump.request(pawn, U.pc, now)
                end
            end
        end
    end

    -- Physical crouch while sprinting also starts a slide. It triggers as soon as the real head drops PHYS_DROP cm
    -- below the standing height (or below the game's crouch height, whichever comes first), so it reacts at the
    -- start of the crouch instead of waiting for the head to reach 120 cm; the slide then holds the view at the
    -- crouch height, which makes the game treat the player as crouched.
    if U.pc and U.get(U.pc, "IsSprinting") == true then lastSprintT = now end
    if Slide.active or M.virtualCrouched or applied ~= 0 or U.get(pawn, "IsStandingMode") == false then
        physArmed = false
    else
        local h = headHeight(pawn)
        local crouchH = U.get(pawn, "PlayerCrouchHeight")
        if type(crouchH) ~= "number" then crouchH = 120 end
        if h then
            -- Standing height: follows the head up at once, down only slowly (running bob / a real crouch must
            -- not lower it).
            local dt = lastStandT and U.clamp(now - lastStandT, 0, 0.5) or 0
            lastStandT = now
            if h > crouchH and (not lastStandH or h > lastStandH) then lastStandH = h
            elseif lastStandH then lastStandH = math.max(h, lastStandH - 4 * dt) end
            local trigger = math.max(crouchH, (lastStandH or 0) - PHYS_DROP)
            local sprinting = now - lastSprintT < 0.3
            if h > trigger + 8 then
                physArmed = true
            elseif physArmed and sprinting and h <= trigger then
                physArmed = false
                U.dlog("physical crouch while sprinting (head %.0f cm, standing %.0f)", h, lastStandH or -1)
                local walk = U.gameSpeeds(U.pc, pawn)
                if Slide.tryStart(pawn, U.pc, now, walk) then
                    -- Hold the view at the stick-crouch height during the slide.
                    local standH = lastStandH or (crouchH + 50)
                    local cam0 = camTrackZ(pawn)
                    if cam0 then
                        M.physSlide = { t0 = now, head0 = h, cam0 = cam0, targetHead = standH - crouchDepth(pawn, standH) }
                        U.dlog("physical slide: stand %.0f, view held at %.0f cm", standH, M.physSlide.targetHead)
                    end
                end
            elseif not sprinting then
                physArmed = h > trigger + 8
            end
        end
    end

    -- Sprinting stands the player up (like the game's own crouch).
    if M.virtualCrouched and not Slide.active and U.pc and U.get(U.pc, "IsSprinting") == true then
        M.virtualCrouched = false
    end

    if Jump.landing then
        if now - Jump.landing.t < 0.2 then startLand(pawn, Jump.landing.k, now) end
        Jump.landing = nil
    end

    updateOffset(pawn, now)
end

function M.status(pawn)
    local h = pawn and headHeight(pawn)
    return string.format("virtualCrouched=%s offset=%.1f head=%s", tostring(M.virtualCrouched), applied,
        h and string.format("%.0f", h) or "?")
end

return M
