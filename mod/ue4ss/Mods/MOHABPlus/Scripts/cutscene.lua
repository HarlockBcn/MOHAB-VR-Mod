-- Skip cinematics: hold BOTH triggers and BOTH grips for skip_hold_time seconds.
--  1. If the game marks the current scene as skippable (BP_R6GameModeBase.bInSkippableScene, the narrative scenes the
--     game itself lets you skip), run the game's own skip (TimerExpired_SceneSkip -> CutsceneSkipped on the level).
--  2. Otherwise jump every playing (non-looping) level sequence to its end, so the level continues as if it had
--     finished.
--  3. Dialogue scenes are "skits" (BP_SkitNode: an NPC plays a list of anim montages with voice while the player is
--     footlocked). The skit advances on native timers set from the montage lengths, so jumping animations does not
--     work (the NPCs then wait for the timer). Instead we fast-forward: global time dilation skip_speed (2-15x) while the
--     player stays locked and skits are playing, and the NPCs' voices are stopped every frame. Everything (timers,
--     montages, level script) then plays out by itself, just faster. Only while the player is locked: ambient skits in
--     hubs must keep playing.
local U = require("util")
local C = require("config")

local M = {}

local holdStart = nil
local fired = false
local ff = nil             -- fast-forward state: { start = real time, lastSkit = real time }
local FF_MAX = 25          -- real seconds before giving up
local FF_IDLE = 0.6        -- real seconds without playing skits before stopping

local function comboHeld()
    local t = math.min(U.trigger("Left"), U.trigger("Right"))
    local g = math.min(U.axis("OculusTouch_Left_Grip_Axis"), U.axis("OculusTouch_Right_Grip_Axis"))
    return t > 0.7 and g > 0.7
end

local function gameMode(pawn)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, gm = U.call(gs, "GetGameMode", pawn)
    if ok and U.valid(gm) then return gm end
    return nil
end

-- Level sequences currently playing that are worth skipping (not looping ambience).
function M.playingSequences()
    local list = {}
    for _, sp in ipairs(FindAllOf("LevelSequencePlayer") or {}) do
        if U.valid(sp) then
            local okP, playing = U.call(sp, "IsPlaying")
            if okP and playing then
                local loops = 0
                pcall(function() loops = sp.PlaybackSettings.LoopCount.Value end)
                if loops == 0 then list[#list + 1] = sp end
            end
        end
    end
    return list
end

-- Diagnostics for scenes we cannot skip.
local function logSceneState(pawn, pc)
    local gm = gameMode(pawn)
    U.log("cutscene diag: footlocked=%s gamelocked=%s skippable=%s",
        tostring(U.get(pc, "bFootlocked")), tostring(U.get(pc, "bGamelocked")),
        tostring(gm and U.get(gm, "bInSkippableScene")))
    local n = 0
    for _, node in ipairs(FindAllOf("BP_SkitNode_C") or {}) do
        if U.valid(node) and U.get(node, "IsPlaying") == true then
            n = n + 1
            local ai = U.get(node, "AI")
            U.log("cutscene diag: playing skit %s dialog=%s ai=%s", node:GetFullName(),
                tostring(U.get(node, "HasDialog?")), U.valid(ai) and ai:GetFName():ToString() or "?")
        end
    end
    U.log("cutscene diag: %d playing skit nodes", n)
end

local function isLocked(pc)
    return U.get(pc, "bFootlocked") == true or U.get(pc, "bGamelocked") == true
end

function M.playingSkits()
    local list = {}
    for _, node in ipairs(FindAllOf("BP_SkitNode_C") or {}) do
        if U.valid(node) and U.get(node, "IsPlaying") == true then list[#list + 1] = node end
    end
    return list
end

local ak = nil
local function stopVoice(actor)
    if not U.valid(actor) then return end
    if not U.valid(ak) then ak = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics") end
    U.call(ak, "StopActor", actor)
end

local function setTimeDilation(pawn, v)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    U.call(gs, "SetGlobalTimeDilation", pawn, v)
end

local function startFastForward(pawn)
    local speed = U.clamp(C.get("skip_speed"), 1, 15)
    ff = { start = os.clock(), lastSkit = os.clock() }
    setTimeDilation(pawn, speed)
    U.log("cutscene skip: fast-forwarding skits (x%.0f)", speed)
end

local function stopFastForward(pawn, reason)
    if not ff then return end
    ff = nil
    if U.valid(pawn) then setTimeDilation(pawn, 1.0) end
    U.log("cutscene skip: fast-forward end (%s)", reason)
end

local function updateFastForward(pawn, pc)
    if not ff then return end
    local t = os.clock()
    if not isLocked(pc) then return stopFastForward(pawn, "player unlocked") end
    if t - ff.start > FF_MAX then return stopFastForward(pawn, "timeout") end
    local skits = M.playingSkits()
    if #skits > 0 then ff.lastSkit = t
    elseif t - ff.lastSkit > FF_IDLE then return stopFastForward(pawn, "no more skits") end
    for _, node in ipairs(skits) do stopVoice(U.get(node, "AI")) end
end

function M.skip(pawn, pc, now)
    local gm = gameMode(pawn)
    if gm and U.get(gm, "bInSkippableScene") == true then
        U.log("cutscene skip: game's own skip")
        U.call(gm, "TimerExpired_SceneSkip")
        return true
    end
    -- Only while the player is held in a scene (locked): during normal play the sequences are gameplay
    -- events (explosions, fly-bys...) that must not be skipped.
    if not isLocked(pc) then
        U.log("cutscene skip: not in a cutscene")
        pcall(logSceneState, pawn, pc)
        return false
    end
    local seqs = M.playingSequences()
    for _, sp in ipairs(seqs) do
        U.log("cutscene skip: sequence %s -> end", U.valid(sp:GetOuter()) and sp:GetOuter():GetFName():ToString() or "?")
        U.call(sp, "GoToEndAndStop")
    end
    if #M.playingSkits() > 0 then
        if not ff then startFastForward(pawn) end
        return true
    end
    if #seqs == 0 then
        U.log("cutscene skip: nothing to skip")
        pcall(logSceneState, pawn, pc)
    end
    return #seqs > 0
end

-- Safety: never leave the game sped up (level change, menu, mod reload).
function M.reset(pawn)
    if ff then stopFastForward(pawn, "reset") end
end

function M.tick(pawn, pc, now, menuOpen, onSkipped)
    local ok, err = pcall(updateFastForward, pawn, pc)
    if not ok then U.log("cutscene fast-forward error: %s", tostring(err)); pcall(stopFastForward, pawn, "error") end
    if not C.get("skip_cutscenes") or menuOpen then
        holdStart, fired = nil, false
        return
    end
    if comboHeld() then
        if not holdStart then holdStart = now; fired = false end
        if not fired and now - holdStart >= C.get("skip_hold_time") then
            fired = true
            local ok = M.skip(pawn, pc, now)
            if onSkipped then onSkipped(ok) end
        end
    else
        holdStart, fired = nil, false
    end
end

return M
