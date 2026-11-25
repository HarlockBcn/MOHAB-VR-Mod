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
-- weapon back in its holster, so it is never lost.
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

local MAX_DROP_SPEED = 900              -- cm/s
local FORCED_GRIP = 0.9                 -- grip still pressed this much: the player did not let go
local STEP_IN = 30                      -- cm in front of the head: where a weapon released behind a wall falls

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------
local held = {}        -- address -> { w, name, side, kind, ammo, canFire, vel }  weapons in the player's hands
local dropped = {}     -- address -> { w, name, ammo, canFire }  dropped weapons still on the floor
local zone = {}        -- side -> slot the held weapon would go to now
local lastPawn = nil
local wasOn = false

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

-- The free holster a weapon would go to if the hand let go of it now.
local function storeSlot(pawn, hc, w, ctrl)
    local d = U.valid(ctrl) and holsterDistances(pawn, ctrl) or nil
    if not d then return nil, d end
    local reach = C.get("holster_store_distance")
    local best = nil
    for _, s in ipairs(freeSlots(pawn, hc, w)) do
        if d[s] and d[s] <= reach and (best == nil or d[s] < d[best]) then best = s end
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

    local v = t.vel
    if v and not moved then
        local s = U.vlen(v)
        if s > MAX_DROP_SPEED then v = U.vmul(v, MAX_DROP_SPEED / s) end
        U.call(U.get(w, "Model"), "SetAllPhysicsLinearVelocity", v, false)
    end

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
        dropped[w:GetAddress()] = { w = w, name = t.name, ammo = t.ammo, canFire = t.canFire, ammoType = ammoType }
    end
    return moved
end

-- Picking up a weapon from the floor makes the game load it from the player's reserve (LockAndLoadWeapon). A weapon
-- the player dropped comes back as it was: dropping it and picking it up is not a reload.
local function pickedUp(w)
    local addr = w:GetAddress()
    local d = dropped[addr]
    if not d then return end
    dropped[addr] = nil
    if d.name ~= fname(w) or type(d.ammo) ~= "number" then return end
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
    local forced = grip > FORCED_GRIP or U.get(ctrl, "ForceDrop") == true
    local slot, d = storeSlot(pawn, hc, w, ctrl)
    local how = "hand at the holster"
    if not slot and forced then
        how = "released by the game"
        local own = U.get(w, "HolsterSlot")
        if not loose and U.same(occupant(hc, own), w) then slot = own else slot = freeSlots(pawn, hc, w)[1] end
    end

    if slot then
        if store(hc, t, slot) then U.log("manual holster: %s -> holster %d (%s; cm %s; grip %.2f)", t.name, slot, how, distText(d), grip) end
    else
        local free = table.concat(freeSlots(pawn, hc, w), ",")
        local carried = {}
        for s = 0, MAX_SLOT do
            local o = occupant(hc, s)
            if o then carried[#carried + 1] = s .. "=" .. fname(o) end
        end
        local moved = drop(pawn, hc, t)
        U.log("manual holster: %s (%s) dropped by the %s hand%s%s (free holsters [%s] of [%s]; carried %s; cm %s; grip %.2f%s)",
            t.name, t.kind, t.side, loose and ", no holster" or "", moved and ", hand behind a wall" or "", free,
            table.concat(fittingSlots(pawn, t.kind), ","), table.concat(carried, " "), distText(d), grip,
            forced and "; released by the game" or "")
    end
end

local function isHeld(w) return U.get(w, "IsGripped") == true or U.get(w, "HoldingWeaponWithOffhand") == true end

-- The weapon a hand holds (by its main grip, or only by the front grip), or nil. A weapon taken from the floor with the
-- off hand is the hand's AttachedObject too, but not IsGripped.
local function weaponInHand(ctrl)
    local o = U.get(ctrl, "AttachedObject")
    if not U.valid(o) then return nil end
    if kindOf(o) then return isHeld(o) and o or nil end
    if not className(o):find("Grip") then return nil end
    for _, fn in ipairs({ "GetParentActor", "GetAttachParentActor" }) do
        local ok, p = U.call(o, fn)
        if ok and U.valid(p) and isGun(kindOf(p)) and isHeld(p) then return p end
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
    t.ammo, t.canFire = U.get(w, "Ammo"), U.get(w, "CanFireNow")
    if t.kind == "grenade" then
        local okA, n = U.call(U.get(w, "MyPlayerStateOwner"), "GetAmmoByIndex", U.get(w, "AmmoType"))
        t.reserve = okA and n or nil
    end
    local ok, v = U.call(U.get(w, "VelocityEstimator"), "GetLinearVelocityEstimate")
    t.vel = (ok and v) and U.vec(v) or nil
end

local function trackHands(pawn)
    local ctrls = { Left = U.get(pawn, "LeftController"), Right = U.get(pawn, "RightController") }
    local found = {}        -- address -> { w, side }
    for side, ctrl in pairs(ctrls) do
        local w = weaponInHand(ctrl)
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
    if U.valid(off) and isGun(kindOf(off)) and isHeld(off) and not found[off:GetAddress()] then
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
        elseif not isHeld(w) then
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

-- A light tap when letting go would put the weapon into a holster.
local function zoneTaps(pawn, hc, now)
    local tap = C.get("haptics_holster_zone")
    local cur = {}
    for _, t in pairs(held) do
        local s = storeSlot(pawn, hc, t.w, U.get(pawn, t.side .. "Controller"))
        if s then cur[t.side] = s end
    end
    for i, side in ipairs({ "Left", "Right" }) do
        if cur[side] and cur[side] ~= zone[side] and tap then Haptics.zoneTap(now, i - 1) end
        zone[side] = cur[side]
    end
end

-- Off (option or master switch): the game's behaviour again.
local function disable()
    for addr, c in pairs(candidates) do
        if U.valid(c.w) and fname(c.w) == c.name and not held[addr] and not isHeld(c.w) then c.w.HolsterSlot = floorSlot(c.kind) end
    end
    held, candidates, zone = {}, {}, {}
end

function M.reset()
    held, dropped, candidates, zone, kinds = {}, {}, {}, {}, {}
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

    checkReleases(pawn, hc)
    trackHands(pawn)
    adoptSlots(pawn, hc)
    prepareWorld(pawn, hc)
    zoneTaps(pawn, hc, now)
end

return M
