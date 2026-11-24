-- Respawning at a checkpoint: facing the right way, no view turn 2 s later, and always standing (see crouch.lua).
--
-- The game reloads the checkpoint in place, with the same player pawn: BP_R6CampaignGameMode:CheckpointLoad may call
-- MovePlayerToCheckpoint (recenters the headset + TeleportPlayer with the checkpoint's rotation) and ends with
-- bDeathlocked = false. The pawn is restarted on the way, and 2 s after that it calls ConfigureCharacterHeight, which
-- recenters the headset again, orientation included, without turning the body: the view snaps back to the direction
-- it had when respawning, undoing whatever the player turned the head in those 2 s (confirmed in the log).
--
-- Facing: MovePlayerToCheckpoint zeroes the headset's yaw and then TeleportPlayer still compensates for it, so the body
-- ends at (checkpoint yaw - old headset yaw) and the player faces off by as much as they were physically turned. In the
-- first frame after the respawn (black screen) the body is turned to the checkpoint's direction.
--
-- For a few seconds after a respawn that recenter is limited to the position (native pre-hook). Safety nets: a sudden
-- jump of the view that does not come from the turn stick is undone, and LastPlayerYaw (the direction the pawn turns
-- to when the headset system itself recenters) is kept equal to the direction the player is really looking at.
local U = require("util")

local M = {}

local WINDOW = 6.0          -- s after the respawn during which the view is watched
local GRACE = 0.4           -- s: the screen is still black and the game is placing the player; jumps are accepted
local JUMP_MIN = 12         -- degrees in one frame
local JUMP_RATE = 900       -- degrees/s: a head cannot turn faster (long frames)
local SETTLE_FRAMES = 2     -- frames between a jump and its correction (the game recenters + turns in two steps)

local active = nil          -- { t0 =, good = yaw the player should keep, lastT =, jump = nil | { frames =, yaw = } }
local wasDead = false
local wasDeadPawn = nil
local loaded = false        -- CheckpointLoad ran since the last tick
local teleportYaw = nil     -- rotation of the last TeleportPlayer since the last tick
local lastStick = -100
local lastDead = nil       -- directions in the last frame before the respawn (log)

local function wrap(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- Yaw the player looks at (from the camera's right vector: not affected by looking up or down).
local function viewYaw(pawn)
    local ok, r = U.call(U.get(pawn, "VRReplicatedCamera"), "GetRightVector")
    if not ok or not r then return nil end
    local x, y = r.X, r.Y
    if type(x) ~= "number" or type(y) ~= "number" or x * x + y * y < 0.05 then return nil end
    return wrap(math.deg(math.atan(y, x)) - 90)
end

local function actorYaw(pawn)
    local ok, r = U.call(pawn, "K2_GetActorRotation")
    if not ok or not r then return nil end
    local yaw = r.Yaw
    return type(yaw) == "number" and wrap(yaw) or nil
end

local function num(v) return type(v) == "number" and string.format("%.0f", v) or "?" end

local function describe(pawn)
    return string.format("view %s, body %s, game's stored yaw %s", num(viewYaw(pawn)), num(actorYaw(pawn)),
        num(U.get(pawn, "LastPlayerYaw")))
end

-- Moments when the view legitimately follows something else.
local function busy(pawn)
    if U.get(pawn, "GamePaused") == true or U.get(pawn, "IsClimbing") == true then return "paused / climbing" end
    local sitting = false
    pcall(function() sitting = pawn.SeatInformation.bSitting == true end)
    if sitting then return "seated" end
    local ok, parent = U.call(pawn, "GetAttachParentActor")
    if ok and U.valid(parent) then return "attached" end
    return nil
end

local function storeYaw(pawn, yaw)
    pcall(function() pawn.LastPlayerYaw = yaw end)
end

-- Hooks (main.lua) -----------------------------------------------------------------------------
-- BP post-hook. Also covers failed missions and reloading the checkpoint from the pause menu.
function M.onCheckpointLoad()
    loaded = true
end

-- Native pre-hook of R6PlayerCharacter:TeleportPlayer.
function M.onTeleport(pawn, rot)
    if U.valid(pawn) and U.valid(U.pc) and not U.same(pawn, U.get(U.pc, "SpawnedPlayerCharacter")) then return end
    local yaw = rot and rot.Yaw
    if type(yaw) == "number" then teleportYaw = wrap(yaw) end
end

-- Native pre-hook of HeadMountedDisplayFunctionLibrary:ResetOrientationAndPosition(Yaw, Options).
-- The manual recenter (ResetOrientation) and the recentered event turn the body first, so they are left alone.
function M.onResetHMD(options)
    local a = active
    if not a or not a.settled or not a.body or not U.valid(a.pawn) then return end
    if busy(a.pawn) then return end
    local body = actorYaw(a.pawn)
    if not body or math.abs(wrap(body - a.body)) > 5 then return end
    if options:get() ~= 2 then return end           -- 0 orientation, 1 position, 2 both
    options:set(1)
    U.log("respawn: recenter limited to the position, %.1f s after respawning (%s)", U.now(a.pawn) - a.t0, describe(a.pawn))
end

-- BP post-hook of the HMDRecenteredDelegate handler (only logs).
function M.onRecentered(pawn)
    if active then U.log("respawn: the game recentered the headset (%s)", describe(pawn)) end
end

-- ---------------------------------------------------------------------------------------------
-- Returns true in the frame the player respawns.
local function detect(pawn, pc, now)
    local dead = U.get(pc, "bDeathlocked") == true
    local addr = pawn:GetAddress()
    local revived = wasDead and not dead and wasDeadPawn == addr
    wasDead, wasDeadPawn = dead, addr
    if dead then lastDead = describe(pawn) end
    local l = loaded
    loaded = false
    if dead then return false end
    return revived or l
end

-- The headset's yaw was just zeroed by the game, so body yaw = view yaw.
local function faceCheckpoint(pawn, yaw)
    local why = busy(pawn)
    if why then U.log("respawn: direction left alone (%s)", why); return end
    local body = actorYaw(pawn)
    if not body or math.abs(wrap(yaw - body)) < 1 then return end
    local ok, err = U.call(pawn, "K2_SetActorRotation", { Pitch = 0, Yaw = yaw, Roll = 0 }, true)
    U.log("respawn: turned %.0f deg to face the checkpoint's direction (%s)%s", wrap(yaw - body), describe(pawn),
        ok and "" or (" FAILED: " .. tostring(err)))
end

local function watch(pawn, now)
    local a = active
    local yaw = viewYaw(pawn)
    local tele = teleportYaw
    teleportYaw = nil
    a.pawn, a.body = pawn, actorYaw(pawn)

    local stick = U.get(pawn, "FlickTurningStick_XAxis")
    if type(stick) ~= "number" then stick = U.axis("OculusTouch_Right_Thumbstick_X") end
    if math.abs(stick) > 0.2 or U.get(pawn, "IsStickTurning") == true then lastStick = now end

    if now - a.t0 > WINDOW or now < a.t0 then
        U.log("respawn: done (%s)", describe(pawn))
        active = nil
        return
    end
    local dt = U.clamp(now - a.lastT, 0.001, 1)
    a.lastT = now
    if not yaw then return end

    -- Placed by the game (checkpoint, scripted teleport): this is the new direction.
    if tele then a.good, a.jump, a.tele = tele, nil, true end
    if now - a.t0 < GRACE then
        -- A recenter arriving now must leave the player facing the checkpoint's direction.
        if not a.tele then a.good = yaw end
        storeYaw(pawn, a.good)
        return
    end
    if not a.settled then
        a.settled = true
        U.log("respawn: view settled (%s)", describe(pawn))
        a.good = yaw
    end

    if busy(pawn) or now - lastStick < 0.6 or tele then
        a.good, a.jump = yaw, nil
        storeYaw(pawn, a.good)
        return
    end

    local diff = wrap(yaw - a.good)
    if a.jump then
        a.jump.frames = a.jump.frames + 1
        if a.jump.frames < SETTLE_FRAMES then return end
        a.jump = nil
        if math.abs(diff) > 3 then
            local body = actorYaw(pawn)
            if body then
                local ok, err = U.call(pawn, "K2_SetActorRotation", { Pitch = 0, Yaw = wrap(body - diff), Roll = 0 }, true)
                U.log("respawn: view turn of %.0f deg undone, %.1f s after respawning (%s)%s", diff, now - a.t0,
                    describe(pawn), ok and "" or (" FAILED: " .. tostring(err)))
                if not ok then a.good = yaw end
            end
        else
            a.good = yaw
        end
    elseif math.abs(diff) > math.max(JUMP_MIN, JUMP_RATE * math.min(dt, 0.05)) then
        a.jump = { frames = 0 }
        U.log("respawn: sudden view turn of %.0f deg, %.1f s after respawning (%s)", diff, now - a.t0, describe(pawn))
    else
        a.good = yaw
    end
    storeYaw(pawn, a.good)
end

-- onRespawn(): called once per respawn (stand up...).
function M.tick(pawn, pc, now, onRespawn)
    if detect(pawn, pc, now) and not (active and now - active.t0 < 1.0 and now >= active.t0) then
        active = { t0 = now, lastT = now, good = viewYaw(pawn) or actorYaw(pawn) or 0 }
        lastStick = -100
        U.log("respawn: checkpoint reloaded (%s, placed at yaw %s; before: %s)", describe(pawn), num(teleportYaw),
            lastDead or "?")
        lastDead = nil
        if teleportYaw then faceCheckpoint(pawn, teleportYaw) end
        if onRespawn then onRespawn() end
    end
    if active then watch(pawn, now) else teleportYaw = nil end
end

-- Master switch off, new pawn.
function M.reset()
    active, loaded, teleportYaw = nil, false, nil
    wasDead, wasDeadPawn = false, nil
    lastStick = -100
    lastDead = nil
end

return M
