-- Pulling a grenade's pin with your teeth.
--
-- The check is native (R6GrenadeMasterComponent): the pin comes out when the held grenade gets within
-- PinInteraction.MaxDistanceForTeethPulling (and MaxDistanceSqForTeethPulling, its square) of the player's mouth
-- (R6PlayerCharacter.PlayerMouthLocation). Both come from the grenade definition R6Def_Grenade, whose only
-- blueprint is BP_Def_Grenade: 10 cm / 100 in the game. The definition is shared by all grenades, so we write the
-- configured distance into it (the class default object and every definition a grenade component returns from
-- GetDef) and put the game's values back when the option is -1 (master switch off).
-- teeth_pin_distance = 0 makes it impossible (pin only by hand).
-- Every teeth pull is logged with the distances, to tune the value.
local U = require("util")
local C = require("config")

local M = {}

local DEF_CDO = "/Game/R6/Core/Weapons/Def/BP_Def_Grenade.Default__BP_Def_Grenade_C"

local orig = {}          -- def address -> { d = game distance, sq = game squared distance }
local defs = {}          -- def address -> def object
local lastScan = -100
local lastWant = nil
local warned = false
local pawnRef = nil

local function readPI(def)
    local ok, d, sq = pcall(function()
        local pi = def.PinInteraction
        return pi.MaxDistanceForTeethPulling, pi.MaxDistanceSqForTeethPulling
    end)
    if ok and type(d) == "number" and type(sq) == "number" then return d, sq end
    return nil
end

local function writePI(def, d, sq)
    pcall(function()
        local pi = def.PinInteraction
        pi.MaxDistanceForTeethPulling = d
        pi.MaxDistanceSqForTeethPulling = sq
    end)
    local rd, rsq = readPI(def)
    if (rd == nil or math.abs(rd - d) > 0.01 or math.abs(rsq - sq) > 0.01) and not warned then
        warned = true
        U.log("teeth pin: could not write the grenade definition (read back %s / %s)", tostring(rd), tostring(rsq))
    end
end

local function addDef(def)
    if not U.valid(def) then return end
    local id = def:GetAddress()
    if defs[id] and U.same(defs[id], def) then return end
    local d, sq = readPI(def)
    if not d then return end
    defs[id] = def
    orig[id] = { d = d, sq = sq }
    lastWant = nil   -- apply again
    local ok, n = pcall(function() return def:GetFullName() end)
    U.log("teeth pin: grenade definition %s, game distance %.1f cm (squared %.1f)", ok and n or "?", d, sq)
end

local function scan()
    addDef(StaticFindObject(DEF_CDO))
    for _, comp in ipairs(FindAllOf("R6GrenadeMasterComponent") or {}) do
        local ok, def = U.call(comp, "GetDef")
        if ok then addDef(def) end
    end
end

function M.tick(pawn, now)
    pawnRef = pawn
    if now - lastScan > 1.0 or now < lastScan then
        lastScan = now
        for id, def in pairs(defs) do
            if not U.valid(def) then defs[id], orig[id] = nil, nil end
        end
        scan()
    end
    local want = C.get("teeth_pin_distance")
    if type(want) ~= "number" then want = -1 end
    local sig = want
    for id, def in pairs(defs) do
        local o = orig[id]
        local d = want >= 0 and U.clamp(want, 0, 30) or o.d
        local sq = want >= 0 and d * d or o.sq
        local cd, csq = readPI(def)
        if cd and (math.abs(cd - d) > 0.01 or math.abs(csq - sq) > 0.01) then writePI(def, d, sq) end
    end
    if sig ~= lastWant then
        lastWant = sig
        local n = 0
        for _ in pairs(defs) do n = n + 1 end
        if n > 0 then
            U.log("teeth pin distance now: %s (%d definition(s))", want >= 0 and string.format("%.1f cm", want) or "game", n)
        end
    end
end

local function loc(o, fn)
    local ok, v = U.call(o, fn)
    if ok and v and type(v.X) == "number" then return U.vec(v) end
    return nil
end

local function dist(a, b)
    if not a or not b then return "?" end
    return string.format("%.1f", U.vlen(U.vsub(a, b)))
end

-- BP_GrenadeBase z_OnPinPulledWithTeeth / z_OnPinPulled (post-hooks). Always logged.
function M.onPinPulled(grenade, teeth)
    local pawn = pawnRef
    local mouth = loc(U.get(pawn, "PlayerMouthLocation"), "K2_GetComponentLocation")
    local cam = loc(U.get(pawn, "VRReplicatedCamera"), "K2_GetComponentLocation")
    local pin = loc(U.get(grenade, "PinActor"), "K2_GetActorLocation")
    local gren = loc(grenade, "K2_GetActorLocation")
    local hand = loc(U.get(grenade, "GrippingController"), "K2_GetActorLocation")
    local limit = "?"
    for _, def in pairs(defs) do
        local d = readPI(def)
        if d then limit = string.format("%.1f", d) end
        break
    end
    U.log("grenade pin pulled %s: mouth->pin %s cm, mouth->grenade %s cm, mouth->hand %s cm, head->grenade %s cm (teeth limit %s cm)",
        teeth and "WITH TEETH" or "by hand", dist(mouth, pin), dist(mouth, gren), dist(mouth, hand), dist(cam, gren), limit)
end

return M
