-- Virtual crouch with the turn stick: push down = crouch, push up = stand up.
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

local M = {}

M.virtualCrouched = false
local armed = true          -- the stick must return to the centre before the next action
local applied = 0           -- offset currently applied to VROrigin (cm, positive = down)
local lastPawnAddr = nil
local lastNow = nil
local SPEED = 260           -- cm/s transition speed
M.minHeadHeight = 70        -- never push the camera below this height above the floor (cm)

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

local function updateOffset(pawn, now)
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
    if not standing or blocked then M.virtualCrouched = false end

    local target = 0
    if M.virtualCrouched then
        if not M.fixedTarget then
            -- Decide the depth once, when the crouch starts (avoids feedback with the capsule resize).
            local dist = U.get(pawn, "CrouchDistance")
            if type(dist) ~= "number" or dist <= 0 then dist = 60 end
            local fixed = dist
            local h = headHeight(pawn)
            if h then
                local raw = h + applied                       -- head height without our offset
                local crouchH = U.get(pawn, "PlayerCrouchHeight")
                if type(crouchH) ~= "number" then crouchH = 120 end
                -- deep enough for the game to detect the crouch (<= PlayerCrouchHeight) even for tall players,
                -- but never bring the eyes closer than minHeadHeight to the floor.
                fixed = math.max(dist, raw - (crouchH - 10))
                fixed = U.clamp(math.min(fixed, raw - M.minHeadHeight), 0, 150)
            end
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
    if applied == 0 and target == 0 then return end
    local step = SPEED * dt
    local newApplied
    if target > applied then newApplied = math.min(target, applied + step)
    else newApplied = math.max(target, applied - step) end
    if newApplied < 0.01 then newApplied = 0 end
    -- Write when the value changes or when the game moved the origin back (e.g. recenter).
    if newApplied ~= applied or math.abs(originZ(pawn) + newApplied) > 0.5 then
        if applyOffset(pawn, newApplied) then
            applied = newApplied
            U.call(pawn, "AdjustCapsuleHeightForCrouch")
        end
    end
end

function M.tick(pawn, menuOpen, now)
    local addr = pawn:GetAddress()
    if addr ~= lastPawnAddr then
        lastPawnAddr = addr
        applied, lastNow, armed = 0, nil, false
        M.fixedTarget = nil
        M.virtualCrouched = false
    end

    if not C.get("crouch_stick") then
        M.virtualCrouched = false
        armed = false
    elseif not menuOpen then
        local y = U.get(pawn, "FlickTurningStick_YAxis")
        if type(y) ~= "number" then y = U.axis("OculusTouch_Right_Thumbstick_Y") end
        local thr = C.get("crouch_stick_threshold")
        if math.abs(y) < 0.3 then
            armed = true
        elseif armed then
            if y <= -thr then
                armed = false
                M.setCrouched(pawn, true)
            elseif y >= thr then
                armed = false
                M.setCrouched(pawn, false)
            end
        end
    end

    -- Sprinting stands the player up (like the game's own crouch).
    if M.virtualCrouched and U.pc and U.get(U.pc, "IsSprinting") == true then
        M.virtualCrouched = false
    end

    updateOffset(pawn, now)
end

function M.status(pawn)
    local h = pawn and headHeight(pawn)
    return string.format("virtualCrouched=%s offset=%.1f head=%s", tostring(M.virtualCrouched), applied,
        h and string.format("%.0f", h) or "?")
end

return M
