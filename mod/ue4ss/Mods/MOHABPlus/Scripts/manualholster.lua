-- Manual holsters: letting go of a weapon drops it, unless the hand is at a free holster that fits it.
--
-- The original game flies every released weapon back to its holster: BP_WeaponBase:OnRelease -> HolsterLerp starts a
-- timeline for weapon.HolsterSlot, whose end (e.g. MoveWeaponToHolster__FinishedFunc) attaches the weapon to the
-- holster and shows its proxy. A held weapon keeps its slot reserved (HolstersComponent.Actors[slot] is its proxy).
--
-- The release itself is left to the game (hand, two-handed grip, bolts, magazines...). The mod sees it on the next
-- tick (the weapon was held, now it is not), stops the flight and, depending on where the hand is:
--   * at a free holster that fits: puts the weapon there at once (the timeline's end, without the flight);
--   * anywhere else: drops it (ThrowHolsteredWeaponInFrontOfOwner, what the game does with swapped weapons, without
--     moving it in front of the player), keeping its ammo and the hand's speed.
-- Releases the player did not ask for (cutscenes, the game taking the weapon away: the grip is still pressed) put the
-- weapon back in its holster, so it is never lost. A gun registered in its own holster flies back there with the
-- game's animation (e.g. taking another weapon with the other hand: the game keeps one weapon at a time).
--
-- Fits: pistols only go to the hip; every other gun (also the sawed-off shotgun, which the game keeps at the hip) to
-- either back slot; grenades to the chest. Free: empty, or the slot the weapon already has.
--
-- Picking up a weapon from the floor with no free holster for it makes the game throw the holstered one to the floor.
-- With the mod it stays in the hand ("loose"): before it is grabbed its HolsterSlot is set to the free chest slot (the
-- mission objects' side), so the game registers it there and finds nothing to swap. The two-handed grip needs a real,
-- registered slot: with a weapon held only by its front grip the game takes it again from pawn.WeaponHeldWithOffhand's
-- slot. A loose weapon takes a holster that fits as soon as one is free, and is never put away on the chest.
--
-- Held by the off hand: a rifle sets HoldingWeaponWithOffhand; a pistol (also the sawed-off shotgun) sets neither that
-- nor IsGripped, only pawn.WeaponHeldWithOffhand, while it is the hand's AttachedObject. Both hang from the hand's
-- MotionController, and the game's throw detaches a weapon only when it finds where to throw it: a drop detaches first.
--
-- Not touched: mission objects (BP_HolsterObject), mission weapons (extinguisher, mine detector, C4, melee...: only
-- the classes below are handled), weapons tagged MissionObjective, bazookas (no holster: the game drops them itself).
local U = require("util")
local C = require("config")
local Haptics = require("haptics")
local H = require("holsters")
local Row = require("grenaderow")

local M = {}

local PISTOL_CLASS = "/Game/R6/Weapons/BP_Weapon_Pistol_MagazineLoaded.BP_Weapon_Pistol_MagazineLoaded_C"
local SAWED_OFF = "/Game/R6/Weapons/SawedOff/BP_SawedOff.BP_SawedOff_C"    -- a subclass of the pistol
local LONG_CLASSES = {
    "/Game/R6/Weapons/BP_Weapon_Rifle_MagazineLoaded.BP_Weapon_Rifle_MagazineLoaded_C",
    "/Game/R6/Core/Weapons/BP_ScopedWeapon.BP_ScopedWeapon_C",
    "/Game/R6/Weapons/BP_CombatShotgun.BP_CombatShotgun_C",
    "/Game/R6/Weapons/LeverAction/BP_LeverAction.BP_LeverAction_C",
}
local GRENADE_CLASS = "/Game/R6/Core/Weapons/BP_GrenadeBase.BP_GrenadeBase_C"
-- Mission variants with their own holster logic
local EXCLUDED = { BP_1911A_Pistol_Tunisia_C = true, BP_132_Dynamite_C = true }

-- EHolsterSlot (left-handed players use the mirrored ones; weapons on the floor have the right-handed ones)
local RIGHT_HIP, RIGHT_CHEST, RIGHT_BACK, LEFT_HIP, LEFT_CHEST, NONE = 0, 1, 2, 3, 4, 6
local MAX_SLOT = 5                      -- 0-5 = body holsters
-- GetNearestHolsterSlot's distance array index -> holster slot it measures
local INDEX_OF_SLOT = { [3] = 0, [0] = 1, [5] = 2, [2] = 3, [4] = 4, [1] = 5 }

local MAX_DROP_SPEED = 600              -- cm/s
local VEL_WINDOW = 0.1                  -- s of hand positions the drop speed is measured over
local ROOT_GAP = 8                      -- cm between a weapon's model and where its actor should be before it is moved
local POSE_RUNS = 4                     -- ticks in a row the off-hand pose may need fixing before the mod gives up
local PAWN_FREE_TIME = 0.5              -- s a dropped weapon passes through the player's body
local ECC_PAWN = 2
local FORCED_GRIP = 0.9                 -- grip still pressed this much: the player did not let go
local STEP_IN = 30                      -- cm in front of the head: where a weapon released behind a wall falls
local GRENADE_STORE_EXTRA = 5            -- cm beyond body_grab_distance: a held grenade at the chest row is put away
local SLOW_SPEED = 35                   -- cm/s (relative to the body): a hand this slow at a holster has stopped there
local EXIT_MARGIN = 10                  -- cm beyond the holster's reach before the hand counts as gone from it
local REARM = 1.0                       -- s gone from a holster before it may vibrate again
local AIM_COS = 0.82                    -- cos 35 deg: a long gun pointing this close to where the player looks is aimed

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------
local held = {}        -- address -> { w, name, side, kind, how, ammo, canFire }  weapons in the player's hands
local dropped = {}     -- address -> { w, name, ammo, canFire }  dropped weapons still on the floor
local zone = {}        -- side -> { z = slot the held weapon is at, fired = true, gone = time it left }
local samples = {}     -- side -> list of { t, p } hand positions (the last VEL_WINDOW or so)
local passing = {}     -- address -> { w, name, t0, resp }  dropped weapons ignoring the player's body for a moment
local lastPawn = nil
local clock = 0         -- the tick's time (s)
local flying = {}       -- address -> time its flight back was last logged
local wasOn = false
local offWas = nil      -- address of what the off hand held last tick

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
local fname, className, isA, occupant = H.fname, H.className, H.isA, H.occupant

local function hasTag(w, tag)
    local ok, r = U.call(U.get(w, "Model"), "ComponentHasTag", FName(tag))
    return ok and r == true
end

-- "pistol", "long", "grenade" or nil (not handled: the game's behaviour). Cached per object.
local kinds = {}
local function kindOf(w)
    if not U.valid(w) then return nil end
    local addr, name = w:GetAddress(), fname(w)
    local c = kinds[addr]
    if c and c.name == name then return c.kind end
    local kind = nil
    if not EXCLUDED[className(w)] then
        if isA(w, GRENADE_CLASS) then kind = "grenade"
        elseif isA(w, SAWED_OFF) then kind = "long"
        elseif isA(w, PISTOL_CLASS) then kind = "pistol"
        else
            for _, path in ipairs(LONG_CLASSES) do
                if isA(w, path) then kind = "long"; break end
            end
        end
        if kind and hasTag(w, "MissionObjective") then kind = nil end
    end
    kinds[addr] = { name = name, kind = kind }
    return kind
end

local function isGun(kind) return kind == "pistol" or kind == "long" end

local function items(arr)
    local list = {}
    if not arr then return list end
    pcall(function()
        for i = 1, #arr do
            local o = arr[i]
            if type(o) == "userdata" and o.get and not o.GetAddress then o = o:get() end
            if U.valid(o) then list[#list + 1] = o end
        end
    end)
    return list
end

local function rightHanded(pawn) return U.get(pawn, "RightHandIsWeaponHand") ~= false end

-- Slot of a weapon on the floor, as the game expects it to pick it up.
local function floorSlot(kind)
    if kind == "pistol" then return RIGHT_HIP end
    if kind == "long" then return RIGHT_BACK end
    return LEFT_CHEST
end

-- Where a held weapon without a holster is registered.
local function looseSlot(pawn) return rightHanded(pawn) and RIGHT_CHEST or LEFT_CHEST end

local function isLoose(pawn, w, kind)
    return isGun(kind) and U.get(w, "HolsterSlot") == looseSlot(pawn)
end

-- Holster slots a weapon may go to.
local function fittingSlots(pawn, kind)
    if kind == "long" then return { U.get(pawn, "PrimaryBackHolsterSlot"), U.get(pawn, "SecondaryBackHolsterSlot") } end
    if kind == "pistol" then return { rightHanded(pawn) and RIGHT_HIP or LEFT_HIP } end
    return { U.get(pawn, "GrenadeHolsterSlot") }
end

local function freeSlots(pawn, hc, w)
    local list = {}
    -- The chest takes several grenades (grenaderow.lua), besides the ones in the hands.
    if kindOf(w) == "grenade" and Row.active then
        return Row.onChest() < Row.MAX_CARRIED and fittingSlots(pawn, "grenade") or {}
    end
    for _, s in ipairs(fittingSlots(pawn, kindOf(w))) do
        local o = occupant(hc, s)
        if o == nil or U.same(o, w) then list[#list + 1] = s end
    end
    return list
end

-- The game's distances (cm) from a hand to each holster slot (the same points it grabs from).
local function holsterDistances(pawn, ctrl)
    local ok = U.call(pawn, "GetNearestHolsterSlot", ctrl, false, {})
    if not ok then return nil end
    local d = {}
    pcall(function()
        local arr = pawn.HolsterDistanceSquaredFromHand
        for slot, i in pairs(INDEX_OF_SLOT) do
            local v = arr[i + 1]
            if type(v) ~= "number" and v and v.get then v = v:get() end
            if type(v) == "number" then d[slot] = math.sqrt(math.max(v, 0)) end
        end
    end)
    return d
end

-- A held grenade is measured against the row on the chest (grenaderow.lua: the grenades drawn there, the empty places
-- next to them, and the game's chest point, which is the middle of the row), not against the game's chest point alone
-- with the weapons' distance: that zone was far wider than the one where a grenade of the row grows to be taken.
local function grenadeAtRow(pawn, w)
    return kindOf(w) == "grenade" and Row.active
end

local function reachOf(pawn, w, s)
    if grenadeAtRow(pawn, w) and s == U.get(pawn, "GrenadeHolsterSlot") then
        local take = tonumber(C.get("body_grab_distance")) or 10
        return math.max(take + GRENADE_STORE_EXTRA, 8)
    end
    return C.get("holster_store_distance")
end

-- The free holster a weapon would go to if the hand let go of it now.
local function storeSlot(pawn, hc, w, ctrl)
    local d = U.valid(ctrl) and holsterDistances(pawn, ctrl) or nil
    if not d then return nil, d end
    if grenadeAtRow(pawn, w) then
        local gs = U.get(pawn, "GrenadeHolsterSlot")
        local okH, h = U.call(U.get(ctrl, "MotionController"), "K2_GetComponentLocation")
        local hand = (okH and h) and U.vec(h) or nil
        if type(gs) == "number" and hand then
            for _, p in ipairs(Row.rowPoints()) do
                local dist = U.vlen(U.vsub(p, hand))
                if d[gs] == nil or dist < d[gs] then d[gs] = dist end
            end
        end
    end
    local best = nil
    for _, s in ipairs(freeSlots(pawn, hc, w)) do
        if d[s] and d[s] <= reachOf(pawn, w, s) and (best == nil or d[s] < d[best]) then best = s end
    end
    return best, d
end

local function distText(d)
    if not d then return "?" end
    local t = {}
    for s = 0, MAX_SLOT do
        if d[s] then t[#t + 1] = string.format("%d:%.0f", s, d[s]) end
    end
    return table.concat(t, " ")
end

local function stopFlight(w)
    U.call(w, "CancelAllHolsterLerping")
    U.call(w, "StopLerp")
end

local function location(o, fn)
    local ok, l = U.call(o, fn)
    return (ok and l) and U.vec(l) or nil
end

-- ---------------------------------------------------------------------------------------------
-- Hand speed and the weapon's actor vs its model
-- ---------------------------------------------------------------------------------------------
-- The hand's own speed (its tracked controller), not the weapon's VelocityEstimator: a weapon just grabbed jumps from
-- the floor to the hand, and one held by the off hand hangs from an actor that can be far from the hand (see below),
-- so its estimate turned a drop into a throw.
local function sampleHands(pawn, t)
    local body = location(pawn, "K2_GetActorLocation")
    for _, side in ipairs({ "Left", "Right" }) do
        local mc = U.get(U.get(pawn, side .. "Controller"), "MotionController")
        local p = U.valid(mc) and location(mc, "K2_GetComponentLocation") or nil
        local list = samples[side] or {}
        if p then
            list[#list + 1] = { t = t, p = p, r = body and U.vsub(p, body) or nil }
            while #list > 2 and t - list[2].t >= VEL_WINDOW do table.remove(list, 1) end
        end
        samples[side] = list
    end
end

-- The hand's speed relative to the body (cm/s, walking does not count), or nil.
local function bodySpeed(side)
    local list = samples[side]
    if not list or #list < 2 then return nil end
    local a, b = list[1], list[#list]
    local dt = b.t - a.t
    if dt <= 0.005 or dt > 0.5 or not a.r or not b.r then return nil end
    return U.vlen(U.vsub(b.r, a.r)) / dt
end

local function handVelocity(side)
    local list = samples[side]
    if not list or #list < 2 then return nil end
    local a, b = list[1], list[#list]
    local dt = b.t - a.t
    if dt <= 0.005 or dt > 0.5 then return nil end
    return U.vmul(U.vsub(b.p, a.p), 1 / dt)
end

-- A weapon is an actor (root) with its model under it. A dropped weapon falls by its model while the actor stays
-- where the hand let go. The off hand's grab (BP_Weapon_Rifle_MagazineLoaded) puts the model back on the actor, attaches
-- the actor to the hand where it is (keeping its distance) and moves the model to the hand turned 45 degrees; its
-- release (OffhandDroppedWeapon) then zeroes the model's rotation relative to the actor. With the actor still up where
-- the last drop happened, the model swung around it on every release, and the distance grew with each grab: the
-- weapon jumped up / forward, more every time. The fix keeps the actor under its model.
local kml = nil
local function rotate(v, rot)
    if not U.valid(kml) then kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary") end
    local ok, r = U.call(kml, "GreaterGreater_VectorRotator", v, rot)
    return (ok and r) and U.vec(r) or v
end

local function angleDiff(a, b)
    return math.abs((a - b + 180) % 360 - 180)
end

-- Where the actor should be for its model (model turned like the actor, at its stored offset). Returns the model's
-- location and rotation, the actor's target location and how far the actor is from it (cm, or 999 if turned).
local function rootTarget(w)
    local model = U.get(w, "Model")
    local mLoc, aLoc = location(model, "K2_GetComponentLocation"), location(w, "K2_GetActorLocation")
    local okM, mr = U.call(model, "K2_GetComponentRotation")
    local okA, ar = U.call(w, "K2_GetActorRotation")
    if not mLoc or not aLoc or not okM or not mr or not okA or not ar then return nil end
    local rot = { Pitch = mr.Pitch, Yaw = mr.Yaw, Roll = mr.Roll }
    local rel = { X = 0, Y = 0, Z = 0 }
    pcall(function() rel = U.vec(w.StoredModelTransform.Translation) end)
    local target = U.vsub(mLoc, rotate(rel, rot))
    local gap = U.vlen(U.vsub(aLoc, target))
    if angleDiff(ar.Pitch, rot.Pitch) > 1 or angleDiff(ar.Yaw, rot.Yaw) > 1 or angleDiff(ar.Roll, rot.Roll) > 1 then
        gap = math.max(gap, 999)
    end
    return model, mLoc, rot, target, gap
end

-- Puts the actor under its model; the model stays where it is (min: only if the actor is farther than that, cm).
-- Returns the distance the actor was off, or nil if it was not moved.
local function alignRoot(w, min)
    local model, mLoc, rot, target, gap = rootTarget(w)
    if not model or gap <= (min or 0) then return nil end
    U.call(w, "K2_SetActorLocationAndRotation", target, rot, false, {}, true)
    -- A model attached to the actor has moved / turned with it: back where it was. A falling one (physics) has not.
    -- (Checking only the location let a model near the actor's origin turn again every tick: the weapon spun.)
    local now = location(model, "K2_GetComponentLocation")
    local okR, nr = U.call(model, "K2_GetComponentRotation")
    local turned = okR and nr and (angleDiff(nr.Pitch, rot.Pitch) > 0.5 or angleDiff(nr.Yaw, rot.Yaw) > 0.5
        or angleDiff(nr.Roll, rot.Roll) > 0.5)
    if (now and U.vlen(U.vsub(now, mLoc)) > 0.5) or turned then
        U.call(model, "K2_SetWorldLocationAndRotation", mLoc, rot, false, {}, true)
    end
    return gap
end

-- A rifle held by the off hand only: its actor is kept under the model, so the release does not swing it. Once the
-- actor is under the model it stays there; if it has to be moved again tick after tick, something else (the game
-- moving the weapon to the other hand...) places the model: the mod gives up for this hold rather than fight it.
local function keepOffhandPose(pawn, t)
    if t.kind ~= "long" or t.how ~= "off hand" or t.poseOff then return end
    if U.get(t.w, "IsGripped") == true or U.same(U.get(U.get(pawn, "WeaponHandController"), "AttachedObject"), t.w) then
        t.poseRuns = 0
        return
    end
    local gap = alignRoot(t.w, ROOT_GAP)
    if not gap then t.poseRuns = 0; return end
    t.poseRuns = (t.poseRuns or 0) + 1
    if t.poseRuns >= POSE_RUNS then
        t.poseOff = true
        U.log("manual holster: %s in the off hand: actor moved %d ticks in a row, left alone", t.name, t.poseRuns)
    elseif not t.aligned then
        t.aligned = true
        U.dlog("manual holster: %s in the off hand: actor moved %s under its model", t.name,
            gap >= 999 and "and turned" or string.format("%.0f cm", gap))
    end
end

-- Dropped weapons: the actor follows its falling model, so a weapon grabbed again (even before it lands) has its
-- actor where it is.
local function followDropped(pawn)
    for addr, d in pairs(dropped) do
        local w = d.w
        if not U.valid(w) or fname(w) ~= d.name or U.get(w, "HeldByAI") == true then
            dropped[addr] = nil
        elseif not held[addr] and not U.same(U.get(w, "WeaponOwner"), pawn) then
            local okS, sim = U.call(U.get(w, "Model"), "IsSimulatingPhysics", FName("None"))
            if okS and sim == true then alignRoot(w, ROOT_GAP) end
        end
    end
end

-- A weapon let go of by the off hand has its stock in the player's body: the physics pushed it out forward / up.
local function passThroughPlayer(w, name, now)
    local model = U.get(w, "Model")
    local ok, resp = U.call(model, "GetCollisionResponseToChannel", ECC_PAWN)
    U.call(model, "SetCollisionResponseToChannel", ECC_PAWN, 0)
    passing[w:GetAddress()] = { w = w, name = name, t0 = now, resp = (ok and type(resp) == "number") and resp or 2 }
end

local function passingTick(pawn, now)
    for addr, p in pairs(passing) do
        if not U.valid(p.w) or fname(p.w) ~= p.name then
            passing[addr] = nil
        elseif now - p.t0 >= PAWN_FREE_TIME then
            passing[addr] = nil
            -- Grabbed again: the game has set the weapon's collision itself.
            if not held[addr] and not U.same(U.get(p.w, "WeaponOwner"), pawn) then
                U.call(U.get(p.w, "Model"), "SetCollisionResponseToChannel", ECC_PAWN, p.resp)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Putting a weapon into a holster, without the flight
-- ---------------------------------------------------------------------------------------------
-- Gives a held / released weapon a holster slot (clears the one it had).
local function register(hc, w, slot)
    local old = U.get(w, "HolsterSlot")
    if type(old) == "number" and old ~= slot then
        if U.same(occupant(hc, old), w) then U.call(hc, "ClearHolsterSlot", old) end
    end
    w.HolsterSlot = slot
    if not U.same(occupant(hc, slot), w) then
        -- true: the proxy starts inactive, as for a weapon in the hand (an active one blocks AttachActorToHolster...)
        U.call(hc, "SetWeaponToHolsterSlot", w, true)
    end
    return U.same(occupant(hc, slot), w)
end

local function store(hc, t, slot)
    local w = t.w
    stopFlight(w)
    if not register(hc, w, slot) then
        -- The timeline's end destroys a weapon that is not registered in its slot: never call it then.
        U.log("manual holster: %s could not be registered in slot %d, left to the game", t.name, slot)
        U.call(hc, "LerpObjectBackToHolsterSlot", w)
        return false
    end
    w.AppropriateHolsterSlot = slot
    local ok, err = U.call(w, "MoveWeaponToHolster__FinishedFunc")
    if not ok then
        U.log("manual holster: %s: %s", t.name, tostring(err))
        U.call(hc, "LerpObjectBackToHolsterSlot", w)
    end
    return ok
end

-- ---------------------------------------------------------------------------------------------
-- Dropping
-- ---------------------------------------------------------------------------------------------
local kismet = nil
local function wallBetween(pawn, w, a, b)
    if not U.valid(kismet) then kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    local ignore = { pawn, w }
    for _, side in ipairs({ "LeftController", "RightController" }) do
        local c = U.get(pawn, side)
        if U.valid(c) then
            ignore[#ignore + 1] = c
            local o = U.get(c, "AttachedObject")
            if U.valid(o) and isA(o, "/Script/Engine.Actor") then ignore[#ignore + 1] = o end
        end
    end
    local ok, blocked = U.call(kismet, "LineTraceSingle", pawn, a, b, 0, false, ignore, 0, {}, true,
        { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
    return ok and blocked == true
end

-- A hand through a wall would drop the weapon out of the level: bring it to the player's side.
local function keepInside(pawn, w)
    local cam = U.get(pawn, "VRReplicatedCamera")
    local a, b = location(cam, "K2_GetComponentLocation"), location(w, "K2_GetActorLocation")
    if not a or not b or not wallBetween(pawn, w, a, b) then return false end
    local ok, f = U.call(cam, "GetForwardVector")
    if not ok or not f then return false end
    local dir = U.vnorm({ X = f.X, Y = f.Y, Z = 0 })
    local p = U.vadd(a, U.vmul(dir, STEP_IN))
    if wallBetween(pawn, w, a, p) then p = { X = a.X, Y = a.Y, Z = a.Z } end
    p.Z = p.Z - 40
    U.call(w, "K2_SetActorLocation", p, false, {}, true)
    return true
end

-- Diagnostics: how a dropped weapon falls (attachment, physics, distance from where it was let go) for a second.
local watch
local watching = {}       -- address -> { w, name, t0, from, how, parent, n }
function watch(w, t)
    local ok, l = U.call(w, "K2_GetActorLocation")
    watching[w:GetAddress()] = { w = w, name = t.name, t0 = os.clock(), from = ok and l and U.vec(l) or nil,
        how = t.how or "?", parent = t.parent, side = t.side, n = 0 }
end

local function watchTick()
    local t = os.clock()
    for addr, d in pairs(watching) do
        if not U.valid(d.w) or fname(d.w) ~= d.name then
            watching[addr] = nil
        else
            local age = t - d.t0
            local mark = d.n == 0 and age >= 0.05 or d.n == 1 and age >= 0.3 or d.n == 2 and age >= 1.0
            if mark then
                d.n = d.n + 1
                local okP, p = U.call(d.w, "GetAttachParentActor")
                local model = U.get(d.w, "Model")
                local okS, sim = U.call(model, "IsSimulatingPhysics", FName("None"))
                local okL, l = U.call(d.w, "K2_GetActorLocation")
                local okM, ml = U.call(model, "K2_GetComponentLocation")
                local okV, v = U.call(model, "GetPhysicsLinearVelocity", FName("None"))
                local dist = (okL and l and d.from) and U.vlen(U.vsub(U.vec(l), d.from)) or -1
                local gap = (okL and l and okM and ml) and U.vlen(U.vsub(U.vec(l), U.vec(ml))) or -1
                U.log("manual holster: %s dropped (%s hand, %s%s) +%.2fs: attached to %s, physics %s, moved %.0f cm, model %.0f cm from the actor, speed %.0f",
                    d.name, tostring(d.side), d.how, d.parent and (", was attached to " .. d.parent) or "", age,
                    (okP and U.valid(p)) and fname(p) or "nothing", tostring(okS and sim), dist, gap,
                    (okV and v) and U.vlen(U.vec(v)) or -1)
                if d.n >= 3 then watching[addr] = nil end
            end
        end
    end
end

local function drop(pawn, hc, t)
    local w = t.w
    local grenade = t.kind == "grenade"
    local slot = U.get(pawn, "GrenadeHolsterSlot")
    local state = U.get(w, "MyPlayerStateOwner")
    if not U.valid(state) then state = U.get(pawn, "PlayerState") end
    local ammoType = U.get(w, "AmmoType")

    stopFlight(w)
    U.call(U.get(w, "Ak"), "Stop")            -- the holster sound the release has just started
    local moved = keepInside(pawn, w)

    -- Still hanging from a hand (held by the off hand): the throw below only detaches it when it finds where to throw it.
    local okP, parent = U.call(w, "GetAttachParentActor")
    t.parent = (okP and U.valid(parent)) and fname(parent) or nil
    if t.parent then U.call(w, "K2_DetachFromActor", 1, 1, 1) end
    t.rootGap = alignRoot(w, ROOT_GAP)

    -- The throw clears weapon.HolsterSlot: only let it when that slot is really this weapon's.
    local current = U.get(w, "HolsterSlot")
    if type(current) == "number" and current ~= NONE and not U.same(occupant(hc, current), w) then w.HolsterSlot = NONE end

    local ok, err = U.call(w, "ThrowHolsteredWeaponInFrontOfOwner", pawn, false, false, nil, nil)
    if not ok then
        U.log("manual holster: %s could not be dropped (%s), left to the game", t.name, tostring(err))
        U.call(hc, "LerpObjectBackToHolsterSlot", w)
        return
    end
    -- The throw empties the weapon (the game has already given its ammo to the player when it swaps weapons).
    if type(t.ammo) == "number" then w.Ammo = t.ammo end
    if type(t.canFire) == "boolean" then w.CanFireNow = t.canFire end
    w.HolsterSlot = floorSlot(t.kind)

    -- The hand's speed at the release (none behind a wall), no spin: whatever the weapon had from the grab, the
    -- off hand's swing or the throw is discarded.
    local v = (not moved) and handVelocity(t.side) or nil
    v = v or { X = 0, Y = 0, Z = 0 }
    local s = U.vlen(v)
    if s > MAX_DROP_SPEED then v = U.vmul(v, MAX_DROP_SPEED / s) end
    t.dropSpeed = math.min(s, MAX_DROP_SPEED)
    local model = U.get(w, "Model")
    U.call(model, "SetAllPhysicsLinearVelocity", v, false)
    U.call(model, "SetAllPhysicsAngularVelocityInDegrees", { X = 0, Y = 0, Z = 0 }, false)
    if not grenade then passThroughPlayer(w, t.name, clock) end

    if grenade then
        U.call(w, "SetGrenadeState", 0)
        U.call(w, "SetActorTickEnabled", false)
        -- The grenade in the hand counts as ammo until it is thrown; the next one appears on the chest.
        -- (With more than the maximum of its type the game has already taken it away on release.)
        local okA, n = U.call(state, "GetAmmoByIndex", ammoType)
        local before = Row.active and Row.counted(ammoType) or t.reserve
        if okA and type(n) == "number" and (type(before) ~= "number" or n >= before) then
            U.call(state, "ConsumeAmmoByIndex", ammoType, 1)
        end
        if type(slot) == "number" and occupant(hc, slot) == nil then U.call(w, "SpawnGrenadeIntoHolsterSlot", pawn, slot) end
    else
        dropped[w:GetAddress()] = { w = w, name = t.name, ammo = t.ammo, canFire = t.canFire, ammoType = ammoType,
            magOut = t.magOut, slideOut = t.slideOut }
    end
    watch(w, t)
    return moved
end

-- Picking up a weapon from the floor makes the game load it from the player's reserve (LockAndLoadWeapon). A weapon
-- the player dropped comes back as it was: dropping it and picking it up is not a reload.
local function restoreRounds(w, d)
    local now, state = U.get(w, "Ammo"), U.get(w, "MyPlayerStateOwner")
    if type(now) ~= "number" or now <= d.ammo then return end
    if not U.valid(state) or type(d.ammoType) ~= "number" then return end
    local ok, reserve = U.call(state, "GetAmmoByIndex", d.ammoType)
    if not ok or type(reserve) ~= "number" then return end
    U.call(state, "SetAmmoByIndex", d.ammoType, reserve + (now - d.ammo))
    w.Ammo = d.ammo
    if type(d.canFire) == "boolean" then w.CanFireNow = d.canFire end
    U.call(w, "UpdateAmmoCount")
    U.dlog("manual holster: %s picked up again with its %d rounds (not reloaded)", d.name, d.ammo)
end

-- The same load also puts the magazine back in (LockAndLoadWeapon: MagazineEjected = false, magazine shown) and may close
-- the slide / bolt. A weapon dropped with its magazine out comes back without it, as the game leaves a weapon whose
-- ammo it takes on a swap (ExtractAmmoForSwapping: grip off, magazine hidden, MagazineEjected), with the magazine on
-- the hip again if there is ammo for it (CreateHipMagazine checks the reserve itself).
local function restoreMagazine(w, d)
    local fixed = {}
    if d.magOut == true and U.get(w, "MagazineEjected") == false then
        U.call(U.get(w, "Magazine"), "SetHiddenInGame", true, false)
        w.MagazineEjected = true
        U.call(w, "DisableGripGrabbing")
        fixed[#fixed + 1] = "magazine out"
    end
    if d.magOut == true and d.slideOut == true and U.get(w, "SlideOut") == false then
        U.call(w, "PlayerSetsSlideOut")
        fixed[#fixed + 1] = "slide back"
    end
    if d.magOut == true and U.get(w, "MagazineOnHip") == false then U.call(w, "CreateHipMagazine") end
    if #fixed > 0 then U.log("manual holster: %s picked up again as it was dropped (%s)", d.name, table.concat(fixed, ", ")) end
end

local function pickedUp(w)
    local addr = w:GetAddress()
    local d = dropped[addr]
    if not d then return end
    dropped[addr] = nil
    if d.name ~= fname(w) or type(d.ammo) ~= "number" then return end
    restoreRounds(w, d)
    restoreMagazine(w, d)
end

-- ---------------------------------------------------------------------------------------------
-- Releases
-- ---------------------------------------------------------------------------------------------
local function released(pawn, hc, t)
    local w = t.w
    if t.kind == "grenade" and U.get(w, "Cooking") == true then return end        -- thrown with the pin out
    if U.get(w, "TurretModeActive") == true then return end                       -- standing on its bipod
    if not U.same(U.get(w, "WeaponOwner"), pawn) then return end                  -- the game has taken it (swap...)
    local loose = isLoose(pawn, w, t.kind)

    local ctrl = U.get(pawn, t.side .. "Controller")
    local grip = U.axis("OculusTouch_" .. t.side .. "_Grip_Axis")
    local forced = grip > FORCED_GRIP or U.get(ctrl, "ForceDrop") == true or t.putAway == true
    local slot, d = storeSlot(pawn, hc, w, ctrl)
    local how = "hand at the holster"
    if not slot and forced then
        how = "released by the game"
        local own = U.get(w, "HolsterSlot")
        if not loose and U.same(occupant(hc, own), w) then
            -- Its own holster: the game's flight back (started by the release) is left to run. If the weapon is in
            -- fact still in the hand nothing happens either (the game's flags can all be false for a moment).
            if isGun(t.kind) then
                local addr = w:GetAddress()
                if clock - (flying[addr] or -10) > 2 then
                    U.log("manual holster: %s flies back to holster %d (released by the game, %s hand, %s; grip %.2f)",
                        t.name, own, t.side, t.how or "?", grip)
                end
                flying[addr] = clock
                return
            end
            slot = own
        else
            slot = freeSlots(pawn, hc, w)[1]
        end
    end

    if slot then
        if store(hc, t, slot) then U.log("manual holster: %s -> holster %d (%s, %s hand, %s; cm %s; grip %.2f)", t.name, slot, how, t.side, t.how or "?", distText(d), grip) end
    else
        local free = table.concat(freeSlots(pawn, hc, w), ",")
        local carried = {}
        for s = 0, MAX_SLOT do
            local o = occupant(hc, s)
            if o then carried[#carried + 1] = s .. "=" .. fname(o) end
        end
        local moved = drop(pawn, hc, t)
        U.log("manual holster: %s (%s) dropped by the %s hand (%s)%s%s (free holsters [%s] of [%s]; carried %s; cm %s; grip %.2f%s; speed %.0f%s)",
            t.name, t.kind, t.side, t.how or "?", loose and ", no holster" or "", moved and ", hand behind a wall" or "", free,
            table.concat(fittingSlots(pawn, t.kind), ","), table.concat(carried, " "), distText(d), grip,
            forced and "; released by the game" or "", t.dropSpeed or -1,
            t.rootGap and (t.rootGap >= 999 and "; actor turned under the model" or string.format("; actor %.0f cm off the model", t.rootGap)) or "")
    end
end

-- Held by the off hand only (see the top): a pistol that a hand holds while the game counts it as the off hand's.
local function offhandPistol(pawn, w)
    if not U.same(U.get(pawn, "WeaponHeldWithOffhand"), w) then return false end
    for _, side in ipairs({ "LeftController", "RightController" }) do
        if U.same(U.get(U.get(pawn, side), "AttachedObject"), w) then return true end
    end
    return false
end

local function isHeld(w, pawn)
    return U.get(w, "IsGripped") == true or U.get(w, "HoldingWeaponWithOffhand") == true
        or (pawn ~= nil and offhandPistol(pawn, w))
end

-- The weapon a hand holds (by its main grip, or only by the front grip), or nil. A weapon taken from the floor with the
-- off hand is the hand's AttachedObject too, but not IsGripped.
local function weaponInHand(ctrl, pawn)
    local o = U.get(ctrl, "AttachedObject")
    if not U.valid(o) then return nil end
    if kindOf(o) then return isHeld(o, pawn) and o or nil end
    if not className(o):find("Grip") then return nil end
    for _, fn in ipairs({ "GetParentActor", "GetAttachParentActor" }) do
        local ok, p = U.call(o, fn)
        if ok and U.valid(p) and isGun(kindOf(p)) and isHeld(p, pawn) then return p end
    end
    return nil
end

local function track(w, side)
    local addr = w:GetAddress()
    local t = held[addr]
    if not t or t.name ~= fname(w) then
        t = { w = w, name = fname(w), kind = kindOf(w) }
        held[addr] = t
        pickedUp(w)
    end
    t.side = side
    t.how = U.get(w, "IsGripped") == true and "main grip" or (U.get(w, "HoldingWeaponWithOffhand") == true and "off hand"
        or "off hand (pistol)")
    t.ammo, t.canFire = U.get(w, "Ammo"), U.get(w, "CanFireNow")
    t.magOut, t.slideOut = U.get(w, "MagazineEjected"), U.get(w, "SlideOut")
    if t.kind == "grenade" then
        local okA, n = U.call(U.get(w, "MyPlayerStateOwner"), "GetAmmoByIndex", U.get(w, "AmmoType"))
        t.reserve = okA and n or nil
    end
end

local function trackHands(pawn)
    local ctrls = { Left = U.get(pawn, "LeftController"), Right = U.get(pawn, "RightController") }
    local found = {}        -- address -> { w, side }
    for side, ctrl in pairs(ctrls) do
        local w = weaponInHand(ctrl, pawn)
        if w then
            -- In two hands: the one at the main grip counts.
            local main = U.get(w, "IsGripped") == true and U.get(w, "GrippingController") or nil
            for s, c in pairs(ctrls) do
                if U.same(main, c) then side = s end
            end
            found[w:GetAddress()] = { w = w, side = side }
        end
    end
    local off = U.get(pawn, "WeaponHeldWithOffhand")
    if U.valid(off) and isGun(kindOf(off)) and isHeld(off, pawn) and not found[off:GetAddress()] then
        local side = U.same(U.get(pawn, "MovementHandController"), ctrls.Right) and "Right" or "Left"
        found[off:GetAddress()] = { w = off, side = side }
    end
    for _, f in pairs(found) do track(f.w, f.side) end
end

local function checkReleases(pawn, hc)
    for addr, t in pairs(held) do
        local w = t.w
        if not U.valid(w) or fname(w) ~= t.name then
            held[addr] = nil
        elseif not isHeld(w, pawn) then
            held[addr] = nil
            local ok, err = pcall(released, pawn, hc, t)
            if not ok then
                U.log("manual holster: %s: %s", t.name, tostring(err))
                if U.same(U.get(w, "WeaponOwner"), pawn) then U.call(hc, "LerpObjectBackToHolsterSlot", w) end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Picking up with no free holster
-- ---------------------------------------------------------------------------------------------
local candidates = {}      -- address -> weapon on the floor near a hand with the loose slot

local function sameAsCarried(hc, w)
    local ok, def = pcall(function() return w.WeaponDefName:ToString() end)
    if not ok then return false end
    for s = 0, MAX_SLOT do
        local o = occupant(hc, s)
        if o and not U.same(o, w) and kindOf(o) then
            local ok2, d2 = pcall(function() return o.WeaponDefName:ToString() end)
            if ok2 and d2 == def then return true end
        end
    end
    return false
end

local function prepareWorld(pawn, hc)
    local seen = {}
    for _, side in ipairs({ "Left", "Right" }) do
        local ctrl = U.get(pawn, side .. "Controller")
        if U.valid(ctrl) and not U.valid(U.get(ctrl, "AttachedObject")) then
            local list = items(U.get(ctrl, "OverlappingGrabActors"))
            list[#list + 1] = U.get(ctrl, "GrabSphereTraceObject")
            for _, w in ipairs(list) do
                local kind = kindOf(w)
                if isGun(kind) and not held[w:GetAddress()] and not isHeld(w) and not U.same(U.get(w, "WeaponOwner"), pawn)
                    and U.get(w, "HeldByAI") ~= true then
                    local addr, want = w:GetAddress(), floorSlot(kind)
                    -- Picking up a weapon like one already carried makes the game merge both: leave it alone. With
                    -- another object in the loose slot the game's swap is left to happen.
                    if #freeSlots(pawn, hc, w) == 0 and not sameAsCarried(hc, w) and occupant(hc, looseSlot(pawn)) == nil then
                        want = RIGHT_CHEST
                        seen[addr] = true
                        candidates[addr] = { w = w, name = fname(w), kind = kind }
                    end
                    if U.get(w, "HolsterSlot") ~= want then w.HolsterSlot = want end
                end
            end
        end
    end
    for addr, c in pairs(candidates) do
        if not seen[addr] then
            candidates[addr] = nil
            if U.valid(c.w) and fname(c.w) == c.name and not held[addr] and not isHeld(c.w) and not U.same(U.get(c.w, "WeaponOwner"), pawn) then
                c.w.HolsterSlot = floorSlot(c.kind)
            end
        end
    end
end

-- A held gun in a slot that is not its own (loose, or a sawed-off shotgun from the hip) takes one that fits as soon as
-- it is free.
local function adoptSlots(pawn, hc)
    for _, t in pairs(held) do
        if isGun(t.kind) and U.same(U.get(t.w, "WeaponOwner"), pawn) then
            local cur, fits = U.get(t.w, "HolsterSlot"), false
            for _, s in ipairs(fittingSlots(pawn, t.kind)) do fits = fits or s == cur end
            local s = not fits and freeSlots(pawn, hc, t.w)[1] or nil
            if s then
                local ok = register(hc, t.w, s)
                U.log("manual holster: %s in the hand: holster %s -> %d%s", t.name, tostring(cur), s, ok and "" or " (NOT registered)")
            end
        end
    end
end

-- No holster feedback while the player handles the weapon rather than putting it away: aiming a rifle brings one
-- hand to the shoulder.
--   * Held with both hands: nobody puts a weapon away with both hands on it.
--   * A long gun pointing where the player looks (barrel within 35 deg of the view): aimed. A weapon taken to the
--     back points up / back. Not for pistols: putting one away at the hip, the player looks down at it.
local function bothHands(pawn, w)
    local n = 0
    for _, side in ipairs({ "LeftController", "RightController" }) do
        local o = U.get(U.get(pawn, side), "AttachedObject")
        if U.valid(o) then
            if U.same(o, w) then
                n = n + 1
            else
                for _, fn in ipairs({ "GetParentActor", "GetAttachParentActor" }) do
                    local ok, p = U.call(o, fn)
                    if ok and U.same(p, w) then n = n + 1; break end
                end
            end
        end
    end
    return n >= 2
end

local function aimed(pawn, t)
    if t.kind ~= "long" then return false end
    local arrow = U.get(t.w, "MuzzleDirectionArrow")
    if not U.valid(arrow) then arrow = U.get(t.w, "MuzzleLocation") end
    local okA, a = U.call(arrow, "GetForwardVector")
    local okC, c = U.call(U.get(pawn, "VRReplicatedCamera"), "GetForwardVector")
    if not okA or not a or not okC or not c then return false end
    local va, vc = U.vec(a), U.vec(c)
    local la, lc = U.vlen(va), U.vlen(vc)
    if la < 0.01 or lc < 0.01 then return false end
    return (va.X * vc.X + va.Y * vc.Y + va.Z * vc.Z) / (la * lc) >= AIM_COS
end

local function handling(pawn, t)
    if bothHands(pawn, t.w) then return "both hands" end
    if aimed(pawn, t) then return "aimed" end
    return nil
end

-- A light tap when letting go would put the weapon into a holster. None while the weapon is handled. When:
--   * the hand slows down at the holster (SLOW_SPEED): putting a weapon away ends with the hand stopping there, a hand
--     passing by is fast;
--   * once per visit: the hand counts as gone only beyond the reach + EXIT_MARGIN for REARM, so a hand resting by a
--     holster, swaying across its edge, does not vibrate again and again.
local function zoneTaps(pawn, hc, now)
    local tap = C.get("haptics_holster_zone")
    local cur = {}
    for _, t in pairs(held) do
        local s, d = storeSlot(pawn, hc, t.w, U.get(pawn, t.side .. "Controller"))
        local why = s and handling(pawn, t) or nil
        if why then
            if t.quiet ~= why then U.dlog("manual holster: %s near a holster, no feedback (%s)", t.name, why) end
            t.quiet = why
            s, d = nil, nil
        else
            t.quiet = nil
        end
        -- Still at the holster it was at, within the margin: the same visit.
        local st = zone[t.side]
        if not s and st and d then
            local slot = st.z
            if slot and d[slot] and d[slot] <= reachOf(pawn, t.w, slot) + EXIT_MARGIN then s = slot end
        end
        if s then cur[t.side] = s end
    end
    for i, side in ipairs({ "Left", "Right" }) do
        local z = cur[side]
        local st = zone[side]
        if z then
            if not st or st.z ~= z then
                st = { z = z }
                zone[side] = st
            end
            st.gone = nil
        elseif st then
            st.gone = st.gone or now
            if now - st.gone >= REARM then zone[side] = nil end
            st = nil
        end
        local speed = st and not st.fired and bodySpeed(side) or nil
        if st and not st.fired and speed and speed <= SLOW_SPEED then
            st.fired = true
            if tap then Haptics.zoneTap(now, i - 1) end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The off hand takes a gun while the weapon hand holds another one
-- ---------------------------------------------------------------------------------------------
-- The game keeps one weapon at a time: BP_WeaponBase ReceiveTick drops what BOTH hands hold when the other hand of a
-- gripped weapon holds another weapon, so both fly back to their holsters. Instead, right after the off hand takes
-- the gun, the weapon hand lets go of its own: it flies back to its holster (released with the grip still pressed, see
-- released) and the off hand keeps the new one. Grenades are not concerned (the game allows a weapon and a grenade).
local function weaponOf(o)
    if not U.valid(o) then return nil end
    if kindOf(o) then return o end
    for _, fn in ipairs({ "GetParentActor", "GetAttachParentActor" }) do
        local ok, p = U.call(o, fn)
        if ok and U.valid(p) and kindOf(p) then return p end
    end
    return nil
end

local function offhandTook(pawn, ctrl)
    if C.get("manual_holster") ~= true or not U.valid(pawn) then return end
    if not U.same(ctrl, U.get(pawn, "MovementHandController")) then return end
    local o = U.get(ctrl, "AttachedObject")
    if not U.valid(o) or not isGun(kindOf(o)) then return end
    local main = U.get(pawn, "WeaponHandController")
    local mw = weaponOf(U.get(main, "AttachedObject"))
    if not mw or U.same(mw, o) or not isGun(kindOf(mw)) then return end
    U.log("manual holster: the off hand took %s: %s leaves the weapon hand", fname(o), fname(mw))
    local t = held[mw:GetAddress()]
    if t then t.putAway = true end          -- released counts it as released by the game: back to its holster
    U.call(main, "ReleaseActor")
end

-- Post-hook of BP_MotionController:GrabActor (a hand takes what it touches, e.g. a weapon on the floor).
function M.onGrabActor(ctrl) offhandTook(U.get(ctrl, "PlayerCharacter"), ctrl) end

-- Post-hook of NonWeaponHandControllerGrabPressed (the off hand may have taken a weapon from a holster).
function M.onOffhandGrabPressed(pawn) offhandTook(pawn, U.get(pawn, "MovementHandController")) end

-- Off (option or master switch): the game's behaviour again.
local function disable()
    for addr, c in pairs(candidates) do
        if U.valid(c.w) and fname(c.w) == c.name and not held[addr] and not isHeld(c.w) then c.w.HolsterSlot = floorSlot(c.kind) end
    end
    held, candidates, zone = {}, {}, {}
end

function M.reset()
    held, dropped, candidates, zone, kinds, watching, samples, passing, flying = {}, {}, {}, {}, {}, {}, {}, {}, {}
end

function M.tick(pawn, now)
    local on = C.get("manual_holster") == true
    if not on then
        if wasOn then disable() end
        wasOn = false
        return
    end
    wasOn = true
    local addr = pawn:GetAddress()
    if addr ~= lastPawn then lastPawn = addr; M.reset() end
    local hc = U.get(pawn, "HolstersComponent")
    if not U.valid(hc) then return end

    clock = now
    sampleHands(pawn, now)
    checkReleases(pawn, hc)
    trackHands(pawn)
    for _, t in pairs(held) do keepOffhandPose(pawn, t) end
    watchTick()
    followDropped(pawn)
    passingTick(pawn, now)
    adoptSlots(pawn, hc)
    prepareWorld(pawn, hc)
    zoneTaps(pawn, hc, now)
    -- In case the grab hooks ran before the attach: only when the off hand has just taken something.
    local off = U.get(pawn, "MovementHandController")
    local o = U.get(off, "AttachedObject")
    local oa = U.valid(o) and o:GetAddress() or nil
    if oa ~= offWas then
        offWas = oa
        if oa then offhandTook(pawn, off) end
    end
end

return M
