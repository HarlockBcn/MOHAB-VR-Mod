-- How close a hand must be to take something you carry on your body.
--
-- BP_VRPlayerCharacter:GetNearestHolsterSlot measures the hand's distance to 8 points: indices 0-5 are the holster
-- slots on the body (index -> EHolsterSlot 3, 0, 5, 2, 4, 1: hips, chest / grenade, mission objects, back weapons...)
-- and 6-7 the sleeves (syringes). The nearest one is taken when its squared distance is <= SlotToDistanceSquaredLeewayMap
-- [index] (or always within 3 cm). The mod writes into each entry:
--   * holster_grab_distance (cm) for weapon holsters: slots holding a weapon (HolstersComponent.Actors, grenades
--     excluded) and the slot a held weapon goes back to (AppropriateHolsterSlot), so holstering works the same;
--   * body_grab_distance (cm) for everything else you carry (grenades, objects, syringes on the sleeves);
--   * the game's value for the back / shoulder weapon slots (PrimaryBackHolsterSlot / SecondaryBackHolsterSlot) and
--     the magazine pouch of the weapon in your hands (its MagazineHolsterSlot), so reloading is not harder.
-- holster.lua can also block holsters 0-5 while a hand is over the head (setHeadBlock).
-- With the options at -1 (master switch off) every entry gets the game's value back.
local U = require("util")
local C = require("config")
local Haptics = require("haptics")

local M = {}

local SLOT_OF_INDEX = { [0] = 3, [1] = 0, [2] = 5, [3] = 2, [4] = 4, [5] = 1 }   -- 6, 7 = sleeves

local orig = {}          -- index -> the game's leeway (squared cm) for the current pawn
local origPawn = nil
local headBlock = false
local lastApply = -100
local lastSig = nil

-- holster.lua: true while a hand is over the head -> holsters 0-5 take only what the hand touches.
function M.setHeadBlock(block)
    if block ~= headBlock then
        headBlock = block
        lastApply = -100     -- apply on the next tick
    end
end

local weaponClass, grenadeClass = nil, nil
local function isA(o, cls) local ok, r = pcall(function() return o:IsA(cls) end); return ok and r == true end
local function isWeapon(o)
    if not U.valid(weaponClass) then weaponClass = StaticFindObject("/Game/R6/Core/Weapons/BP_WeaponBase.BP_WeaponBase_C") end
    if not U.valid(grenadeClass) then grenadeClass = StaticFindObject("/Game/R6/Core/Weapons/BP_GrenadeBase.BP_GrenadeBase_C") end
    if not U.valid(o) or not U.valid(weaponClass) or not isA(o, weaponClass) then return false end
    return not (U.valid(grenadeClass) and isA(o, grenadeClass))
end

-- Weapon holster slots (holding a weapon, or where a held weapon goes back) and the held weapons' magazine pouches.
-- Holstered weapons are found among all weapons (FindAllOf includes subclasses; refreshed every second): those owned
-- by the player's HolstersComponent and not in a hand give their HolsterSlot.
local holstered, lastScan, scanNames = {}, -100, ""
local function scanHolstered(pawn, now)
    if now - lastScan < 1.0 and now >= lastScan then return end
    lastScan = now
    holstered = {}
    local names = {}
    local hc = U.get(pawn, "HolstersComponent")
    if not U.valid(hc) then return end
    for _, w in ipairs(FindAllOf("BP_WeaponBase_C") or {}) do
        if isWeapon(w) and U.same(U.get(w, "OwningHolsterComponent"), hc) and U.get(w, "IsGripped") ~= true then
            local s = U.get(w, "HolsterSlot")
            if type(s) == "number" then
                holstered[s] = true
                local ok, n = pcall(function() return w:GetClass():GetFName():ToString() end)
                names[#names + 1] = string.format("%s=%d", ok and n or "?", s)
            end
        end
    end
    table.sort(names)
    scanNames = table.concat(names, " ")
end

local function weaponSlots(pawn, now)
    scanHolstered(pawn, now)
    local weapons, mags = {}, {}
    for s in pairs(holstered) do weapons[s] = true end
    for _, side in ipairs({ "LeftController", "RightController" }) do
        local w = U.get(U.get(pawn, side), "AttachedObject")
        if isWeapon(w) then
            local m, a = U.get(w, "MagazineHolsterSlot"), U.get(w, "AppropriateHolsterSlot")
            if type(m) == "number" then mags[m] = true end
            if type(a) == "number" then weapons[a] = true end
        end
    end
    return weapons, mags
end

function M.tick(pawn, now)
    if now - lastApply < 0.25 and now >= lastApply then return end
    lastApply = now
    local map = U.get(pawn, "SlotToDistanceSquaredLeewayMap")
    if not map then return end
    local id = pawn:GetAddress()
    if id ~= origPawn then origPawn, orig, lastSig = id, {}, nil end

    local d = C.get("body_grab_distance")
    local dw = C.get("holster_grab_distance")
    local custom = type(d) == "number" and d >= 0
    local keep, weapon = {}, {}
    if custom then
        d = U.clamp(d, 0, 30)
        dw = U.clamp(type(dw) == "number" and dw >= 0 and dw or d, 0, 30)
        local b1, b2 = U.get(pawn, "PrimaryBackHolsterSlot"), U.get(pawn, "SecondaryBackHolsterSlot")
        local ws, mags = weaponSlots(pawn, now)
        for i, s in pairs(SLOT_OF_INDEX) do
            if s == b1 or s == b2 or mags[s] then keep[i] = true
            elseif ws[s] then weapon[i] = true end
        end
    end

    local parts = {}
    for i = 0, 7 do
        pcall(function()
            if not map:Contains(i) then return end
            local cur = map:Find(i):get()
            if orig[i] == nil then orig[i] = cur end
            local want = orig[i]
            if custom and not keep[i] then want = weapon[i] and dw * dw or d * d end
            if headBlock and i <= 5 then want = 0 end
            if math.abs(cur - want) > 0.01 then map:Add(i, want) end
            parts[#parts + 1] = string.format("%d:%s%.0f", i, keep[i] and "game " or (weapon[i] and "weapon " or ""), math.sqrt(math.max(want, 0)))
        end)
    end
    local sig = table.concat(parts, " ")
    if sig ~= lastSig then
        if lastSig == nil then
            local o = {}
            for i = 0, 7 do
                if orig[i] then o[#o + 1] = string.format("%d:%.0f", i, math.sqrt(math.max(orig[i], 0))) end
            end
            U.log("body grab distances (game), cm: %s; back slots %s/%s", table.concat(o, " "),
                tostring(U.get(pawn, "PrimaryBackHolsterSlot")), tostring(U.get(pawn, "SecondaryBackHolsterSlot")))
        end
        U.log("body grab distances now, cm: %s%s | holstered weapons: %s", sig, headBlock and " (hand over the head)" or "",
            scanNames ~= "" and scanNames or "none")
        lastSig = sig
    end
end

-- ---------------------------------------------------------------------------------------------
-- Grab zones: asks the game, for each empty hand, what it would take now (GetNearestHolsterSlot with NearestValid,
-- the same call the game makes on grip). A light tap when the answer changes to something grabbable.
-- The game only considers the NEAREST point that holds something: if that one is out of its distance, nothing is
-- taken even when another item is within its own. Grip presses that take nothing near a holster are logged.
-- DesiredSlot 6 = nothing.
-- ---------------------------------------------------------------------------------------------
local NONE = 6
local zone = { Left = NONE, Right = NONE }
local gripWas = { Left = false, Right = false }

local function nearestSlot(pawn, ctrl)
    local out = {}
    local ok = U.call(pawn, "GetNearestHolsterSlot", ctrl, true, out)
    local s = out.DesiredSlot
    if not ok or type(s) ~= "number" then return nil end
    return s
end

local function logMiss(pawn, side)
    local dist, lee = {}, {}
    local best, bestD = nil, 1e9
    pcall(function()
        local arr = pawn.HolsterDistanceSquaredFromHand
        for i = 1, #arr do
            local v = arr[i]
            if type(v) ~= "number" and v and v.get then v = v:get() end
            local d = type(v) == "number" and math.sqrt(math.max(v, 0)) or nil
            dist[#dist + 1] = d and (d > 900 and "empty" or string.format("%.0f", d)) or "?"
            if d and d < bestD and d < 900 then best, bestD = i - 1, d end
        end
    end)
    if not best or bestD > 50 then return end     -- not reaching for anything on the body
    pcall(function()
        local map = pawn.SlotToDistanceSquaredLeewayMap
        for i = 0, 7 do
            lee[#lee + 1] = map:Contains(i) and string.format("%.0f", math.sqrt(math.max(map:Find(i):get(), 0))) or "-"
        end
    end)
    U.log("grab missed (%s hand): nearest point %d at %.0f cm | distances cm [%s] | allowed cm [%s]",
        side, best, bestD, table.concat(dist, ","), table.concat(lee, ","))
end

function M.handTick(pawn, now)
    local hapticsOn = C.get("haptics_holster_zone")
    for i, side in ipairs({ "Left", "Right" }) do
        local ctrl = U.get(pawn, side .. "Controller")
        local empty = U.valid(ctrl) and not U.valid(U.get(ctrl, "AttachedObject"))
        local s = empty and nearestSlot(pawn, ctrl) or NONE
        s = s or NONE
        if s ~= zone[side] then
            if s ~= NONE and hapticsOn then Haptics.zoneTap(now, i - 1) end
            zone[side] = s
        end
        local down = U.axis("OculusTouch_" .. side .. "_Grip_Axis") > 0.6
        if down and not gripWas[side] and empty and s == NONE then pcall(logMiss, pawn, side) end
        gripWas[side] = down
    end
end

return M
