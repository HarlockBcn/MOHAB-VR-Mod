-- Skip cinematics: hold BOTH triggers and BOTH grips for skip_hold_time seconds.
--  1. If the game marks the current scene as skippable (BP_R6GameModeBase.bInSkippableScene, the narrative scenes the
--     game itself lets you skip), run the game's own skip (TimerExpired_SceneSkip -> CutsceneSkipped on the level).
--  2. Otherwise jump every playing (non-looping) level sequence to its end, so the level continues as if it had
--     finished.
local U = require("util")
local C = require("config")

local M = {}

local holdStart = nil
local fired = false

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

function M.skip(pawn, pc, now)
    local gm = gameMode(pawn)
    if gm and U.get(gm, "bInSkippableScene") == true then
        U.log("cutscene skip: game's own skip")
        U.call(gm, "TimerExpired_SceneSkip")
        return true
    end
    -- Only while the player is held in a scene (locked): during normal play the sequences are gameplay
    -- events (explosions, fly-bys...) that must not be skipped.
    local locked = U.get(pc, "bFootlocked") == true or U.get(pc, "bGamelocked") == true
    if not locked then
        U.log("cutscene skip: not in a cutscene")
        return false
    end
    local seqs = M.playingSequences()
    for _, sp in ipairs(seqs) do
        U.log("cutscene skip: sequence %s -> end", U.valid(sp:GetOuter()) and sp:GetOuter():GetFName():ToString() or "?")
        U.call(sp, "GoToEndAndStop")
    end
    if #seqs == 0 then U.log("cutscene skip: nothing to skip") end
    return #seqs > 0
end

function M.tick(pawn, pc, now, menuOpen, onSkipped)
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
