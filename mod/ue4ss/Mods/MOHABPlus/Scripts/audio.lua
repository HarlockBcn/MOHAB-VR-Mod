-- Shared Wwise helpers. Events need their sound bank loaded; we load each event's RequiredBank once.
local U = require("util")

local M = {}

local ak = nil
local loadedBanks = {}

function M.statics()
    if not U.valid(ak) then ak = StaticFindObject("/Script/AkAudio.Default__AkGameplayStatics") end
    return ak
end

-- Finds (loading it if needed) an AkAudioEvent by object path and makes sure its bank is loaded.
function M.loadEvent(path)
    if not path then return nil end
    local ev = StaticFindObject(path)
    if not U.valid(ev) then
        pcall(LoadAsset, path)
        ev = StaticFindObject(path)
    end
    if not U.valid(ev) then return nil end
    local bank = U.get(ev, "RequiredBank")
    if U.valid(bank) and not loadedBanks[bank:GetAddress()] then
        -- SynchronizeSoundBanks MUST be false: true makes Wwise unload every bank not in this list
        -- (all of the game's sounds and music).
        local ok = U.call(M.statics(), "LoadBanks", { bank }, false)
        loadedBanks[bank:GetAddress()] = ok
        U.dlog("sound bank %s loaded=%s", bank:GetFName():ToString(), tostring(ok))
    end
    return ev
end

-- Posts an event (object or path) on an actor. Returns the playing id, or nil.
function M.post(ev, actor)
    if type(ev) == "string" then ev = M.loadEvent(ev) end
    if not U.valid(ev) or not U.valid(actor) then return nil end
    local ok, id = U.call(M.statics(), "PostEventAttached", ev, actor, FName("None"), true, "")
    return ok and id or nil
end

-- Stops an event that has no Stop_ counterpart (ExecuteActionOnEvent(Stop) with a short fade).
function M.stopEvent(ev, actor)
    if U.valid(ev) and U.valid(actor) then
        U.call(M.statics(), "ExecuteActionOnEvent", ev, 0, actor, 200, 4, 0)
    end
end

return M
