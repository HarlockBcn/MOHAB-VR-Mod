-- Jump (EXPERIMENTAL: the game was not designed for jumping): push the turn stick up while standing (pushing it up while crouched still stands you up, see crouch.lua).
--
-- The player pawn is an ACharacter, so we use the engine's own LaunchCharacter with a vertical speed computed from
-- the configured height (v = sqrt(2 * g * h)). Horizontal speed is kept, so a running jump goes further. The game
-- already handles the rest of the fall: landing sound, Comp_FallDamage (only for big drops) and the walking mode
-- coming back on landing. LaunchCharacter is used instead of Character:Jump because it does not depend on the
-- movement component's bCanJump / JumpMaxCount, which this game may never have set up.
--
-- A jump request is kept for a moment (M.request): if the jump cannot happen right now for a passing reason (just
-- landed, a few frames off the ground on a slope or a step), it happens as soon as it can instead of being lost.
--
-- Sounds (jump_sound = "all" | "cloth" | "off"):
--  * effort voice: the player's own "Climb_Short" corporeal event (BFL_Global.CallPlayerCorporealEvent), the grunt
--    the game plays when climbing. It picks the right voice for the current character and respects the game's VO
--    cooldowns, so not every jump grunts.
--  * cloth: foley rustle on take-off and a cloth snap on landing.
--  * landing thud: BP_VRPlayerCharacter.OnLanded already plays Play_Player_Landing_Light/Heavy (>= 120 / 500 cm/s)
--    with the surface switch, but only once "Enable Landing Sound" is set; if it is not, we play it ourselves.
--    The voice is posted on the same frame as the jump (the game's own VO path is synchronous and the media is in
--    memory), so any delay heard is in the recording itself.
--
-- Hard landings (land_crouch): any fall (jumped or walked off a ledge) of at least land_crouch_height metres, from
-- its highest point, makes the player bend down on landing (crouch.lua lowers the view and brings it back up), with
-- a bigger "Climb_Long" grunt (forced past the game's VO cooldowns: the take-off grunt just played) and a jolt in
-- both controllers. The deeper the fall (up to the fall damage height) the deeper and longer the crouch. When the
-- landing hurts, the game's own pain voice / damage haptics play instead of ours.
--
-- jump_guard: the level's invisible barriers become infinitely tall, so jumps cannot leave the playable area, but
-- anything visible (tables, rocks, crates) can be climbed (see jumpguard.lua).
local U = require("util")
local C = require("config")
local Audio = require("audio")
local Guard = require("jumpguard")
local Haptics = require("haptics")

local M = {}

local lastJump = -100
local lastLand = -100
local wasFalling = false
local jumping = false       -- the current fall started with our jump
local peakDown = 0          -- fastest downward speed of the current fall (cm/s), for the log
local preloaded = false
local pending = nil         -- kept jump request: { untilT =, why = last reason it could not happen }
local fall = nil            -- current fall: { t0 =, apex = highest feet Z, lastFeet =, hp = health before landing }
local BUFFER = 0.3          -- s a jump request is kept
local REAL_FALL = 0.15      -- s in the air for a fall to count as a landing (stepping down stairs does not)

-- Set on a hard landing, consumed by crouch.lua: { k = 0..1 (how hard), t = time }.
M.landing = nil

local SND = {
    takeoff = "/Game/R6/Audio/Foley/Movement/Cotton_A/Play_Mov_Cotton_A_Med.Play_Mov_Cotton_A_Med",
    land = "/Game/R6/Audio/Foley/Movement/Cotton_A/Play_Cotton_A_Snap.Play_Cotton_A_Snap",
    thudLight = "/Game/R6/Audio/Character/Play_Player_Landing_Light.Play_Player_Landing_Light",
    thudHeavy = "/Game/R6/Audio/Character/Play_Player_Landing_Heavy.Play_Player_Landing_Heavy",
}
M.SOUND_NAMES = { "all", "cloth", "off" }

local bfl = nil
-- force = true skips the game's VO cooldowns (third parameter of CallPlayerCorporealEvent is ForcePlay).
local function effortVoice(pawn, event, force)
    if not U.valid(bfl) then bfl = StaticFindObject("/Game/R6/Core/BFL_Global.Default__BFL_Global_C") end
    local ok, err = U.call(bfl, "CallPlayerCorporealEvent", FName(event), pawn, force == true, pawn)
    if not ok then U.dlog("jump voice failed: %s", tostring(err)) end
end

-- Loads the banks before the first jump (a bank load on the jump frame could delay the sound).
local function preload()
    if preloaded then return end
    preloaded = true
    for _, path in pairs(SND) do
        if not Audio.loadEvent(path) then U.dlog("jump sound not found: %s", path) end
    end
end

local function blockedReason(pawn, ctrl)
    if U.get(ctrl, "bGamelocked") == true then return "game locked" end
    if U.get(ctrl, "bFootlocked") == true then return "foot locked" end
    if U.get(ctrl, "bDeathlocked") == true then return "dead" end
    if U.get(pawn, "IsClimbing") == true then return "climbing" end
    -- Skiing / sledding attach the player to the skis / sled (BP_PC_Ski, BP_PC_Sled: AttachPlayer).
    local okA, parent = U.call(pawn, "GetAttachParentActor")
    if okA and U.valid(parent) then return "attached to " .. parent:GetFName():ToString() end
    -- Only from normal walking (not swimming, flying or a custom mode).
    local mode = U.get(U.get(pawn, "CharacterMovement"), "MovementMode")
    if type(mode) == "number" and mode ~= 1 and mode ~= 2 then return "movement mode " .. mode end
    -- Swimming / treading water is driven by BP_Swimming actors.
    for _, sw in ipairs(FindAllOf("BP_Swimming_C") or {}) do
        if U.valid(sw) and (U.get(sw, "Swimming") == true or U.get(sw, "TreadingWater") == true) then
            local who = U.get(sw, "Player")
            if not U.valid(who) or U.same(who, pawn) then return "swimming" end
        end
    end
    local seat = U.get(pawn, "SeatInformation")
    if seat then
        local ok, sitting = pcall(function() return seat.bSitting end)
        if ok and sitting then return "seated" end
    end
    return nil
end

-- One jump attempt. Returns true, or false + reason + whether the reason may go away in a moment.
local function attempt(pawn, ctrl, now)
    if not C.get("jump_enabled") then return false, "jump off", false end
    local why = blockedReason(pawn, ctrl)
    if why then return false, why, false end
    local cmc = U.get(pawn, "CharacterMovement")
    if not U.valid(cmc) then return false, "no movement component", false end
    local okG, onGround = U.call(cmc, "IsMovingOnGround")
    if okG and not onGround then return false, "not on the ground", true end
    -- Short pause after landing / jumping: no bunny hopping.
    if now - lastLand < 0.25 or now - lastJump < 0.5 then return false, "cooldown", true end

    local okZ, g = U.call(cmc, "GetGravityZ")
    if not okZ or type(g) ~= "number" or g >= 0 then g = -980 end
    local h = U.clamp(C.get("jump_height"), 10, 120)
    -- No jump when the head would hit a ceiling / something above (logged by the guard).
    if not Guard.headClear(pawn, h) then return false, "ceiling", false end
    local vz = math.sqrt(2 * -g * h)
    local ok, err = U.call(pawn, "LaunchCharacter", { X = 0, Y = 0, Z = vz }, false, true)
    if not ok then return false, "LaunchCharacter failed: " .. tostring(err), false end
    lastJump = now
    jumping = true
    if C.get("jump_guard") then Guard.start(pawn) else Guard.stop() end
    Guard.headStart(pawn)
    local snd = C.get("jump_sound")
    if snd ~= "off" then
        Audio.post(SND.takeoff, pawn)
        if snd == "all" then effortVoice(pawn, "Climb_Short", false) end
    end
    if U.debug then
        local v = U.get(cmc, "Velocity")
        U.dlog("jump: height %.0f cm, vz %.0f (gravity %.0f), horizontal %.0f", h, vz, g,
            v and math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2) or -1)
    end
    return true
end

-- Tries to jump right now. Returns true if the player was launched (console command / tests).
function M.tryJump(pawn, ctrl, now)
    local ok, why = attempt(pawn, ctrl, now)
    if not ok then U.log("jump refused: %s", tostring(why)) end
    return ok
end

-- Stick pushed up: jump now, or within BUFFER s if the reason it can't is a passing one.
function M.request(pawn, ctrl, now)
    local ok, why, transient = attempt(pawn, ctrl, now)
    if ok then pending = nil; return true end
    if transient then
        pending = { untilT = now + BUFFER, why = why }
        U.dlog("jump delayed: %s", why)
    else
        pending = nil
        if why ~= "ceiling" then U.log("jump refused: %s", why) end
    end
    return false
end

local function feetZ(pawn)
    local ok, loc = U.call(pawn, "K2_GetActorLocation")
    local okH, hh = U.call(U.get(pawn, "CapsuleComponent"), "GetScaledCapsuleHalfHeight")
    if ok and loc and okH and type(hh) == "number" then return loc.Z - hh end
    return nil
end

local function health(pawn)
    local v = U.get(U.get(pawn, "VRPlayerCharacterHealthAndDamageComponent"), "Health")
    return type(v) == "number" and v or nil
end

-- Landing of a fall of `drop` cm: bend down, grunt and jolt if it was a hard one.
local function hardLanding(pawn, now, drop, hurt)
    if not C.get("land_crouch") then return end
    local minH = U.clamp(tonumber(C.get("land_crouch_height")) or 2, 0.5, 10)
    local m = drop / 100
    if m < minH then return end
    local ctrl = U.pc
    if U.get(ctrl, "bGamelocked") == true or U.get(ctrl, "bDeathlocked") == true or U.get(pawn, "IsClimbing") == true then return end
    local mode = U.get(U.get(pawn, "CharacterMovement"), "MovementMode")
    if type(mode) == "number" and mode ~= 1 then return end    -- landed in water etc.
    -- Full crouch at the height where falls start to hurt.
    local safeH = C.get("fall_damage_custom") and U.clamp(tonumber(C.get("fall_safe_height")) or 4, 1, 30) or 3.3
    local k = U.clamp((m - minH) / math.max(safeH - minH, 0.5), 0, 1)
    M.landing = { k = k, t = now }
    if not hurt then
        if C.get("jump_sound") == "all" then effortVoice(pawn, "Climb_Long", true) end
        if U.valid(ctrl) then
            local amp = (0.45 + 0.55 * k) * U.clamp(C.get("haptics_intensity") or 1, 0, 1)
            Haptics.pulse(ctrl, now, amp, amp, 0.1 + 0.12 * k)
        end
    end
    U.log("hard landing: fell %.1f m (crouch %.0f%%)%s", m, 100 * (0.45 + 0.55 * k), hurt and ", hurt" or "")
end

-- Every frame: jump requests, landings (cooldown, hard landings) and the jump guard.
function M.tick(pawn, now)
    if C.get("jump_enabled") and C.get("jump_sound") ~= "off" then preload() end
    local cmc = U.get(pawn, "CharacterMovement")
    local okF, falling = U.call(cmc, "IsFalling")
    if not okF then return end
    falling = falling == true
    if not C.get("jump_guard") then
        if Guard.active() then Guard.stop() end
    elseif Guard.active() then
        Guard.update(pawn, falling, now)
    end

    local feet = feetZ(pawn)
    if falling then
        if not fall then fall = { t0 = now, apex = feet, lastFeet = feet, hp = health(pawn) } end
        if feet then
            -- A big jump between two frames is a teleport, not a fall: count from there.
            if not fall.lastFeet or math.abs(feet - fall.lastFeet) > 300 then fall.apex = feet end
            if not fall.apex or feet > fall.apex then fall.apex = feet end
            fall.lastFeet = feet
        end
        fall.hp = health(pawn) or fall.hp
        if jumping then Guard.headUpdate(pawn) end
        local v = U.get(cmc, "Velocity")
        if v and v.Z and -v.Z > peakDown then peakDown = -v.Z end
    elseif wasFalling then
        local f = fall or { t0 = now }
        local airTime = now - f.t0
        if jumping or airTime >= REAL_FALL then lastLand = now end
        local drop = (f.apex and feet) and (f.apex - feet) or 0
        local hp = health(pawn)
        local hurt = f.hp and hp and hp < f.hp - 0.001 or false
        if jumping then
            U.dlog("jump landed: %.0f cm/s down, %.2f s in the air, fell %.0f cm", peakDown, now - lastJump, drop)
            if C.get("jump_sound") ~= "off" then
                Audio.post(SND.land, pawn)
                if U.get(pawn, "Enable Landing Sound") == false then
                    Audio.post(peakDown >= 500 and SND.thudHeavy or SND.thudLight, pawn)
                    U.dlog("jump landed: game landing sound disabled, played our own")
                end
            end
        end
        if airTime >= REAL_FALL then hardLanding(pawn, now, drop, hurt) end
        jumping, peakDown = false, 0
        Guard.headStop()
    end
    if not falling then fall = nil end
    wasFalling = falling

    -- Kept jump request: retry until it works or runs out.
    if pending then
        if now > pending.untilT then
            U.log("jump refused: %s", pending.why == "cooldown" and "just landed / jumped" or tostring(pending.why))
            pending = nil
        else
            local ok, why, transient = attempt(pawn, U.pc, now)
            if ok then
                pending = nil
                U.dlog("jump: delayed jump done")
            elseif not transient then
                pending = nil
                if why ~= "ceiling" then U.log("jump refused: %s", why) end
            else
                pending.why = why
            end
        end
    end
end

function M.reset()
    lastJump, lastLand = -100, -100
    wasFalling, jumping, peakDown = false, false, 0
    preloaded = false
    pending, fall, M.landing = nil, nil, nil
    Guard.stop()
end

return M
