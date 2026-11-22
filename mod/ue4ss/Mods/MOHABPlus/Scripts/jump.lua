-- Jump: push the turn stick up while standing (pushing it up while crouched still stands you up, see crouch.lua).
--
-- The player pawn is an ACharacter, so we use the engine's own LaunchCharacter with a vertical speed computed from
-- the configured height (v = sqrt(2 * g * h)). Horizontal speed is kept, so a running jump goes further. The game
-- already handles the rest of the fall: landing sound, Comp_FallDamage (only for big drops) and the walking mode
-- coming back on landing. LaunchCharacter is used instead of Character:Jump because it does not depend on the
-- movement component's bCanJump / JumpMaxCount, which this game may never have set up.
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
-- jump_guard: the level's invisible barriers become infinitely tall, so jumps cannot leave the playable area, but
-- anything visible (tables, rocks, crates) can be climbed (see jumpguard.lua).
local U = require("util")
local C = require("config")
local Audio = require("audio")
local Guard = require("jumpguard")

local M = {}

local lastJump = -100
local lastLand = -100
local wasFalling = false
local jumping = false       -- the current fall started with our jump
local peakDown = 0          -- fastest downward speed of the current fall (cm/s), for the log
local preloaded = false

local SND = {
    takeoff = "/Game/R6/Audio/Foley/Movement/Cotton_A/Play_Mov_Cotton_A_Med.Play_Mov_Cotton_A_Med",
    land = "/Game/R6/Audio/Foley/Movement/Cotton_A/Play_Cotton_A_Snap.Play_Cotton_A_Snap",
    thudLight = "/Game/R6/Audio/Character/Play_Player_Landing_Light.Play_Player_Landing_Light",
    thudHeavy = "/Game/R6/Audio/Character/Play_Player_Landing_Heavy.Play_Player_Landing_Heavy",
}
M.SOUND_NAMES = { "all", "cloth", "off" }

local bfl = nil
local function effortVoice(pawn)
    if not U.valid(bfl) then bfl = StaticFindObject("/Game/R6/Core/BFL_Global.Default__BFL_Global_C") end
    local ok, err = U.call(bfl, "CallPlayerCorporealEvent", FName("Climb_Short"), pawn, false, pawn)
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

-- Tries to jump. Returns true if the player was launched.
function M.tryJump(pawn, ctrl, now)
    if not C.get("jump_enabled") then return false end
    local why = blockedReason(pawn, ctrl)
    if why then U.dlog("jump refused: %s", why); return false end
    local cmc = U.get(pawn, "CharacterMovement")
    if not U.valid(cmc) then return false end
    local okG, onGround = U.call(cmc, "IsMovingOnGround")
    if okG and not onGround then U.dlog("jump refused: not on the ground"); return false end
    -- Short pause after landing / jumping: no bunny hopping.
    if now - lastLand < 0.25 or now - lastJump < 0.5 then U.dlog("jump refused: cooldown"); return false end

    local okZ, g = U.call(cmc, "GetGravityZ")
    if not okZ or type(g) ~= "number" or g >= 0 then g = -980 end
    local h = U.clamp(C.get("jump_height"), 10, 100)
    -- No jump when the head would hit a ceiling / something above.
    if not Guard.headClear(pawn, h) then return false end
    local vz = math.sqrt(2 * -g * h)
    local ok, err = U.call(pawn, "LaunchCharacter", { X = 0, Y = 0, Z = vz }, false, true)
    if not ok then U.log("LaunchCharacter failed: %s", tostring(err)); return false end
    lastJump = now
    jumping = true
    if C.get("jump_guard") then Guard.start(pawn) else Guard.stop() end
    Guard.headStart(pawn)
    local snd = C.get("jump_sound")
    if snd ~= "off" then
        Audio.post(SND.takeoff, pawn)
        if snd == "all" then effortVoice(pawn) end
    end
    if U.debug then
        local v = U.get(cmc, "Velocity")
        local fd = U.get(pawn, "Comp_FallDamage")
        U.dlog("jump: height %.0f cm, vz %.0f (gravity %.0f), horizontal %.0f; fall damage from %s cm/s (fatal %s)",
            h, vz, g, v and math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2) or -1,
            tostring(U.get(fd, "NonFatalFallVelocity")), tostring(U.get(fd, "FatalFallVelocity")))
    end
    return true
end

-- Every frame: tracks landings for the cooldown (and logs how hard each jump landed).
function M.tick(pawn, now)
    if C.get("jump_enabled") and C.get("jump_sound") ~= "off" then preload() end
    local cmc = U.get(pawn, "CharacterMovement")
    local okF, falling = U.call(cmc, "IsFalling")
    if not okF then return end
    if not C.get("jump_guard") then
        if Guard.active() then Guard.stop() end
    elseif Guard.active() then
        Guard.update(pawn, falling == true, now)
    end
    if falling then
        if jumping then Guard.headUpdate(pawn) end
        local v = U.get(cmc, "Velocity")
        if v and v.Z and -v.Z > peakDown then peakDown = -v.Z end
    elseif wasFalling then
        lastLand = now
        if jumping then
            U.dlog("jump landed: %.0f cm/s down, %.2f s in the air", peakDown, now - lastJump)
            if C.get("jump_sound") ~= "off" then
                Audio.post(SND.land, pawn)
                if U.get(pawn, "Enable Landing Sound") == false then
                    Audio.post(peakDown >= 500 and SND.thudHeavy or SND.thudLight, pawn)
                    U.dlog("jump landed: game landing sound disabled, played our own")
                end
            end
        end
        jumping, peakDown = false, 0
        Guard.headStop()
    end
    wasFalling = falling == true
end

function M.reset()
    lastJump, lastLand = -100, -100
    wasFalling, jumping, peakDown = false, false, 0
    preloaded = false
    Guard.stop()
end

return M
