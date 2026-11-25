-- Grenades in a row on the chest.
--
-- The game carries up to 3 grenades (American, stick and Gammon bombs together) only as ammo counts per type. A single
-- real grenade sits in the chest holster slot; the one in a hand still counts as ammo until it is thrown, and keeps the
-- slot, so the next one only appears afterwards. A grenade picked up from the floor replaces the one on the chest.
--
-- With the mod the chest shows one mesh per grenade that is not in a hand (plain StaticMeshActors, no collision), next
-- to each other. The game's own mesh (the slot's proxy) is hidden. The real grenade is kept as the one of the type the
-- hand is closest to: the game's grab then takes the right one. When the game takes nothing (the mesh is away from the
-- game's chest point, or the other hand holds one of the same type), the mod takes it itself, after the game's own grab
-- (hooks on BP_VRPlayerCharacter:...GrabPressed).
--
-- Grenades thrown while another real one waits on the chest: the game clears the slot and spawns a new one, leaving the
-- other without a slot; those are destroyed (they are only a picture of the ammo count).
--
-- The ring or cap (a child actor) of a grenade on the chest cannot be taken: the game turns it on again when the grenade
-- is grabbed. It is drawn with the mesh.
--
-- More grenades from the floor (3 on the chest and one in each hand): with 3 or more counted, the game turns a grenade
-- off as soon as a hand points at it (HighlightOn -> SuppressGrabbingTemporarily) and refuses it in OnGrab. So while an
-- empty hand is close to a grenade on the floor, part of the count is kept here ("loan") and the game's own count stays
-- below 3; it is given back when the hand leaves. The grenades in the hands are never lent (a throw consumes one). The
-- slot is emptied too when the other hand holds a grenade (the game would destroy that one).
local U = require("util")
local C = require("config")
local H = require("holsters")
local Haptics = require("haptics")

local M = {}

local GRENADE_CLASS = "/Game/R6/Core/Weapons/BP_GrenadeBase.BP_GrenadeBase_C"
-- EAmmoType -> the grenade class the game gives for it
local TYPES = {
    [2] = "/Game/R6/Weapons/BP_M2Grenade.BP_M2Grenade_C",
    [3] = "/Game/R6/Weapons/BP_PotatoMasher.BP_PotatoMasher_C",
    [7] = "/Game/R6/Weapons/GammonGrenade/BP_GammonBomb_Grenade.BP_GammonBomb_Grenade_C",
}
local TYPE_ORDER = { 2, 3, 7 }
local MAX_CARRIED = 3

local SPACING = 9                    -- cm between two grenades
local FILL_ORDER = { 2, 1, 3 }       -- positions: 1 outwards, 2 the game's chest point, 3 towards the middle of the chest
local GAME_MAX = 2                   -- what the game may count while a hand is about to take one from the floor
local FLOOR_RANGE = 230              -- cm from the hand (its grab capsule reaches up to 2 m ahead)
local HOVER_SCALE = 1.3              -- x, the one the hand would take
local CHEST_RIGHT, CHEST_LEFT = 1, 4

M.active = false

local row = {}                       -- position (1-3) -> ammo type
local visuals = {}                   -- position -> { actor, comp, type, scale }
local meshes = {}                    -- type -> { mesh, mats, loc, rot, scale }  as the game draws it on the chest
local classOf = {}                   -- type -> class of the last one seen (some maps use their own variants)
local known = {}                     -- address -> { g, name }  real grenades seen on the chest
local hover = {}                     -- side -> position the hand would take
local holding = {}                   -- side -> address of the grenade in the hand
local quiet = {}                     -- side -> true: the hand has just put a grenade away (no growing until it leaves)
local pressed = {}                   -- side -> true: the game has just handled a grip press
local hiddenProxy = nil
local loan = { [2] = 0, [3] = 0, [7] = 0 }   -- type -> grenades the game does not count for the moment
local bag = {}                       -- type -> the game's count at the end of the last tick
local nearFloor, lastFloorScan = {}, -100    -- side -> true: a grenade on the floor within reach
local lastPawn = nil
local retryAt = 0                    -- os.clock(): no spawning before (after a failure)
local failed = {}                    -- one log line per kind of failure
local spawnedMeshes = {}             -- address -> { a, name }  every mesh actor made here (to find leftovers)
local lastStrayScan = -100

local function failOnce(key, fmt, ...)
    if failed[key] then return end
    failed[key] = true
    U.log("grenade row: " .. fmt, ...)
end

-- ---------------------------------------------------------------------------------------------
-- The game's side
-- ---------------------------------------------------------------------------------------------
local function typeOf(g)
    if not H.isA(g, GRENADE_CLASS) then return nil end
    local t = U.get(g, "AmmoType")
    if type(t) ~= "number" or not TYPES[t] then return nil end
    return t
end

local function isHeld(g) return U.get(g, "IsGripped") == true end

local function ammoCounts(pawn)
    local ps = U.get(pawn, "PlayerState")
    if not U.valid(ps) then return nil end
    local n = {}
    for _, t in ipairs(TYPE_ORDER) do
        local ok, v = U.call(ps, "GetAmmoByIndex", t)
        if not ok or type(v) ~= "number" then return nil end
        n[t] = math.max(0, v)
    end
    return n
end

local function setAmmo(ps, t, n)
    U.call(ps, "SetAmmoByIndex", t, n)
    local ok, v = U.call(ps, "GetAmmoByIndex", t)
    return (ok and type(v) == "number") and v or n
end

-- Gives the loan back (whatever the game does not accept stays here).
local function giveBack(pawn)
    local ps = U.get(pawn, "PlayerState")
    if not U.valid(ps) then return end
    for _, t in ipairs(TYPE_ORDER) do
        if loan[t] > 0 then
            local ok, n = U.call(ps, "GetAmmoByIndex", t)
            if ok and type(n) == "number" then loan[t] = loan[t] - math.max(0, setAmmo(ps, t, n + loan[t]) - n) end
        end
    end
end

-- Keeps the game's count at GAME_MAX at most, without touching the grenades in the hands.
local function lend(pawn, ammo, inHands)
    local ps = U.get(pawn, "PlayerState")
    local excess = ammo[2] + ammo[3] + ammo[7] - GAME_MAX
    for _, t in ipairs(TYPE_ORDER) do
        local n = math.min(excess, ammo[t] - inHands[t])
        if n > 0 then
            local now = setAmmo(ps, t, ammo[t] - n)
            loan[t] = loan[t] + (ammo[t] - now)
            excess = excess - (ammo[t] - now)
        end
    end
end

-- The saved counts are about to be loaded: the loan belongs to the past.
function M.forgetLoan() for _, t in ipairs(TYPE_ORDER) do loan[t] = 0 end end

local function remember(g)
    known[g:GetAddress()] = { g = g, name = H.fname(g) }
    local t = typeOf(g)
    local ok, cls = pcall(function() return g:GetClass() end)
    if t and ok and U.valid(cls) then classOf[t] = cls end
end

-- The one spawned by SpawnGrenadeAccordingToAmmo (out parameter; otherwise the one that was not there before).
local function spawned(hc, cls)
    local before = {}
    for _, g in ipairs(FindAllOf("BP_GrenadeBase_C") or {}) do before[g:GetAddress()] = H.fname(g) end
    local out = {}
    local ok, err = U.call(hc, "SpawnGrenadeAccordingToAmmo", cls, out)
    if not ok then failOnce("spawn", "could not spawn a grenade: %s", tostring(err)); return nil end
    local g = out.Result
    if type(g) == "userdata" and g.get and not g.GetAddress then g = g:get() end
    if U.valid(g) and H.isA(g, GRENADE_CLASS) then return g end
    for _, o in ipairs(FindAllOf("BP_GrenadeBase_C") or {}) do
        if U.valid(o) and before[o:GetAddress()] ~= H.fname(o) then return o end
    end
    failOnce("spawned", "the game spawned no grenade")
    return nil
end

-- The ring or cap of a grenade.
local function pinOf(g)
    local pin = U.get(g, "PinActor")
    if not U.valid(pin) then pin = U.get(U.get(g, "Pin"), "ChildActor") end
    return U.valid(pin) and pin or nil
end

-- On the chest it must not be grabbable (its sphere is a grab target of its own).
local function lockPin(g)
    local pin = pinOf(g)
    if not pin then return end
    if U.get(pin, "DisablePickup") ~= true then
        pin.DisablePickup = true
        U.call(pin, "OnRep_DisablePickup")
    end
    local sphere = U.get(pin, "GrippableSphere")
    if not U.valid(sphere) then return end
    if U.get(sphere, "bGenerateOverlapEvents") ~= false then U.call(sphere, "SetGenerateOverlapEvents", false) end
    local ok, c = U.call(sphere, "GetCollisionEnabled")
    if not ok or c ~= 0 then U.call(sphere, "SetCollisionEnabled", 0) end
end

-- The grenade itself and its pin (a child actor; shown again only if it was hidden here: pulled pins are the game's).
local hiddenPins = {}                -- address -> name
local function setHidden(g, hidden)
    if U.get(g, "bHidden") ~= hidden then U.call(g, "SetActorHiddenInGame", hidden) end
    local pin = pinOf(g)
    if not pin then return end
    local addr, name = pin:GetAddress(), H.fname(pin)
    if hidden and U.get(pin, "bHidden") ~= true then
        hiddenPins[addr] = name
        U.call(pin, "SetActorHiddenInGame", true)
    elseif not hidden and hiddenPins[addr] then
        if hiddenPins[addr] == name then U.call(pin, "SetActorHiddenInGame", false) end
        hiddenPins[addr] = nil
    end
end

-- Every mesh of a proxy: the Gammon and stick grenade proxies draw their cap with a mesh of their own (under the base
-- proxy's MagazineRoot), besides the DisplayMesh. Only the meshes hidden here are shown again.
local proxyHidden = {}               -- proxy address -> { name =, comps = { mesh, ... } }
local function setProxyVisible(p, visible)
    local addr = p:GetAddress()
    local st = proxyHidden[addr]
    if st and st.name ~= H.fname(p) then st = nil end
    if visible then
        proxyHidden[addr] = nil
        for _, comp in ipairs(st and st.comps or {}) do
            if U.valid(comp) then U.call(comp, "SetVisibility", true, false) end
        end
        if not st then U.call(U.get(p, "DisplayMesh"), "SetVisibility", true, false) end
        return
    end
    st = st or { name = H.fname(p), comps = {} }
    proxyHidden[addr] = st
    local cls = H.class("/Script/Engine.MeshComponent")
    local ok, arr = U.call(p, "K2_GetComponentsByClass", cls)
    local list = {}
    pcall(function()
        for i = 1, #arr do
            local c = arr[i]
            if type(c) == "userdata" and c.get and not c.GetAddress then c = c:get() end
            if U.valid(c) then list[#list + 1] = c end
        end
    end)
    if not ok or #list == 0 then list = { U.get(p, "DisplayMesh") } end
    for _, comp in ipairs(list) do
        if U.valid(comp) and U.get(comp, "bVisible") ~= false then
            U.call(comp, "SetVisibility", false, false)
            st.comps[#st.comps + 1] = comp
        end
    end
end

-- Hides what the game shows on the chest: the slot's proxy and, for the variants without one (Quartermaster), the
-- grenade itself.
local function hideReal(hc, slot)
    local p = H.registered(hc, slot)
    local g = H.occupant(hc, slot)
    if H.isProxy(p) then
        setProxyVisible(p, false)
        hiddenProxy = p
    end
    if g and not isHeld(g) then
        setHidden(g, true)
        lockPin(g)
    end
end

local function showReal(hc, slot)
    local p = H.registered(hc, slot)
    local g = H.occupant(hc, slot)
    if H.isProxy(p) then
        setProxyVisible(p, true)
    elseif g and typeOf(g) then
        setHidden(g, false)
    end
end

-- Frees the chest slot. The one in a hand only loses the slot; one waiting on the chest is destroyed.
local function clearChest(hc, slot)
    local occ = H.occupant(hc, slot)
    if occ == nil then return true end
    if not typeOf(occ) then return false end
    U.call(hc, isHeld(occ) and "ClearHolsterSlot" or "ClearAndDeleteFromHolsterSlot", slot)
    return true
end

-- A real grenade of this type on the chest, ready to be taken (what SpawnGrenadeIntoHolsterSlot does).
local function ensureReal(pawn, hc, slot, t)
    local occ = H.occupant(hc, slot)
    if occ and not isHeld(occ) and typeOf(occ) == t then return occ end
    if os.clock() < retryAt then return nil end
    local cls = U.valid(classOf[t]) and classOf[t] or H.class(TYPES[t])
    if not cls then failOnce("class" .. t, "class of grenade type %d not found", t); retryAt = os.clock() + 2; return nil end
    if not clearChest(hc, slot) then return nil end
    giveBack(pawn)                   -- the game only spawns what it counts
    local g = spawned(hc, cls)
    if not g then retryAt = os.clock() + 2; return nil end
    U.call(g, "SetupChestGrenade", slot)
    U.call(U.get(g, "Model"), "SetGenerateOverlapEvents", false)
    U.call(hc, "SetWeaponToHolsterSlot", g, false)
    U.call(pawn, "AttachActorToHolsterBySlotSnap", g, slot)
    if not U.same(H.occupant(hc, slot), g) then
        failOnce("register", "a spawned grenade was not registered on the chest")
        U.call(g, "K2_DestroyActor")
        retryAt = os.clock() + 2
        return nil
    end
    remember(g)
    hideReal(hc, slot)
    return g
end

-- Real grenades left on the chest without the slot.
local function destroyOrphans(pawn, hc, slot)
    local occ = H.occupant(hc, slot)
    for addr, k in pairs(known) do
        local g = k.g
        if not U.valid(g) or H.fname(g) ~= k.name then
            known[addr] = nil
        elseif not U.same(g, occ) and not isHeld(g) and U.get(g, "Cooking") ~= true then
            -- Still the player's, not flying back (that one has the slot) and not on the floor (no owner there).
            known[addr] = nil
            if U.same(U.get(g, "WeaponOwner"), pawn) and U.get(g, "HolsterSlot") == slot then U.call(g, "K2_DestroyActor") end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Meshes
-- ---------------------------------------------------------------------------------------------
local function vec(o, d)
    local ok, v = pcall(function() return { X = o.X, Y = o.Y, Z = o.Z } end)
    return ok and v or { X = d, Y = d, Z = d }
end

local function rotator(o)
    local ok, v = pcall(function() return { Pitch = o.Pitch, Yaw = o.Yaw, Roll = o.Roll } end)
    return ok and v or { Pitch = 0, Yaw = 0, Roll = 0 }
end

local function materials(comp)
    local mats = {}
    local ok, n = U.call(comp, "GetNumMaterials")
    for i = 0, (ok and type(n) == "number" and n or 0) - 1 do
        local okM, m = U.call(comp, "GetMaterial", i)
        if okM and U.valid(m) then mats[i] = m end
    end
    return mats
end

-- World position, axes and scale of a component.
local function frame(comp)
    local ok1, l = U.call(comp, "K2_GetComponentLocation")
    local ok2, f = U.call(comp, "GetForwardVector")
    local ok3, r = U.call(comp, "GetRightVector")
    local ok4, u = U.call(comp, "GetUpVector")
    local ok5, s = U.call(comp, "K2_GetComponentScale")
    if not (ok1 and ok2 and ok3 and ok4 and ok5 and l and f and r and u and s) then return nil end
    return { loc = U.vec(l), x = U.vec(f), y = U.vec(r), z = U.vec(u), scale = U.vec(s) }
end

local function intoFrame(v, f) return { X = U.vdot(v, f.x), Y = U.vdot(v, f.y), Z = U.vdot(v, f.z) } end

-- The ring / cap, relative to the grenade's own mesh (only if that is the mesh drawn: otherwise it may include it).
local function learnPin(g, mesh)
    local model, pin = U.get(g, "Model"), pinOf(g)
    local comp = pin and U.get(pin, "StaticMesh") or nil
    local pinMesh = U.get(comp, "StaticMesh")
    if not U.valid(pinMesh) or not U.same(U.get(model, "StaticMesh"), mesh) then return nil end
    local a, b = frame(model), frame(comp)
    if not a or not b then return nil end
    local function div(x, y) return math.abs(y) > 1e-4 and x / y or x end
    local d = intoFrame(U.vsub(b.loc, a.loc), a)
    local x, y, z = intoFrame(b.x, a), intoFrame(b.y, a), intoFrame(b.z, a)
    local yaw = math.atan(x.Y, x.X)
    local side = { X = -math.sin(yaw), Y = math.cos(yaw), Z = 0 }
    return {
        mesh = pinMesh, mats = materials(comp),
        loc = { X = div(d.X, a.scale.X), Y = div(d.Y, a.scale.Y), Z = div(d.Z, a.scale.Z) },
        rot = { Pitch = math.deg(math.atan(x.Z, math.sqrt(x.X * x.X + x.Y * x.Y))), Yaw = math.deg(yaw),
            Roll = math.deg(math.atan(U.vdot(z, side), U.vdot(y, side))) },
        scale = { X = div(b.scale.X, a.scale.X), Y = div(b.scale.Y, a.scale.Y), Z = div(b.scale.Z, a.scale.Z) },
    }
end

-- How the game draws this grenade on the chest: the mesh of its proxy (or its own, when it has no proxy).
local function learn(hc, slot)
    local a = H.registered(hc, slot)
    local occ = H.occupant(hc, slot)
    local t = occ and typeOf(occ) or nil
    if not t or isHeld(occ) or U.get(occ, "Cooking") == true then return end
    local known = meshes[t] and U.valid(meshes[t].mesh) and meshes[t]
    if known then
        if known.pin == nil then known.pin = learnPin(occ, known.mesh) end
        return
    end
    local comp = H.isProxy(a) and U.get(a, "DisplayMesh") or U.get(occ, "Model")
    local mesh = U.get(comp, "StaticMesh")
    if not U.valid(mesh) then
        comp = U.get(occ, "Model")
        mesh = U.get(comp, "StaticMesh")
    end
    if not U.valid(mesh) then failOnce("mesh" .. t, "no mesh for grenade type %d", t); return end
    local mats = materials(comp)
    meshes[t] = { mesh = mesh, mats = mats, loc = vec(U.get(comp, "RelativeLocation"), 0),
        rot = rotator(U.get(comp, "RelativeRotation")), scale = vec(U.get(comp, "RelativeScale3D"), 1), pin = learnPin(occ, mesh) }
    U.log("grenade row: type %d drawn with %s, ring / cap %s", t, H.fname(mesh),
        meshes[t].pin and H.fname(meshes[t].pin.mesh) or "none")
end

local function spawnVisual(pawn)
    local cls = StaticFindObject("/Script/Engine.StaticMeshActor")
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not U.valid(cls) or not U.valid(gs) then return nil end
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, a = U.call(gs, "BeginDeferredActorSpawnFromClass", pawn, cls, xf, 1, nil)
    if not ok or not U.valid(a) then failOnce("visual", "could not spawn a mesh: %s", tostring(a)); return nil end
    U.call(a, "SetMobility", 2)                     -- Movable
    U.call(gs, "FinishSpawningActor", a, xf)
    U.call(a, "SetActorEnableCollision", false)
    local comp = U.get(a, "StaticMeshComponent")
    U.call(comp, "SetGenerateOverlapEvents", false)
    spawnedMeshes[a:GetAddress()] = { a = a, name = H.fname(a) }
    return a, comp
end

local function destroyVisual(i)
    local v = visuals[i]
    visuals[i] = nil
    if v and U.valid(v.pin) then U.call(v.pin, "K2_DestroyActor") end
    if v and U.valid(v.actor) then U.call(v.actor, "K2_DestroyActor") end
end

local function location(o, fn)
    local ok, l = U.call(o, fn)
    return (ok and l) and U.vec(l) or nil
end

local function actorLoc(a) return location(a, "K2_GetActorLocation") end

-- Extra rings / caps on the chest (a Gammon cap was seen drawn twice while hovering): meshes made here that no grenade
-- of the row uses any more are destroyed; a real ring / cap shown next to the row while its grenade is hidden or gone
-- is hidden. Each case is logged.
local function strayScan(now)
    if now - lastStrayScan < 0.25 and now >= lastStrayScan then return end
    lastStrayScan = now
    local used = {}
    for i = 1, MAX_CARRIED do
        local v = visuals[i]
        if v then
            if U.valid(v.actor) then used[v.actor:GetAddress()] = true end
            if U.valid(v.pin) then used[v.pin:GetAddress()] = true end
        end
    end
    for addr, s in pairs(spawnedMeshes) do
        if not U.valid(s.a) or H.fname(s.a) ~= s.name then
            spawnedMeshes[addr] = nil
        elseif not used[addr] then
            spawnedMeshes[addr] = nil
            U.log("grenade row: leftover mesh %s destroyed", s.name)
            U.call(s.a, "K2_DestroyActor")
        end
    end
    local spots = {}
    for i = 1, MAX_CARRIED do
        local v = visuals[i]
        local p = v and U.valid(v.actor) and actorLoc(v.actor) or nil
        if p then spots[#spots + 1] = p end
    end
    if #spots == 0 then return end
    for _, pin in ipairs(FindAllOf("BP_Weapon_GrenadePin_Base_C") or {}) do
        if U.valid(pin) and U.get(pin, "bHidden") ~= true and U.get(pin, "IsGripped") ~= true then
            local p = actorLoc(pin)
            local near = false
            for _, s in ipairs(spots) do
                if p and U.vlen(U.vsub(p, s)) < 20 then near = true; break end
            end
            if near then
                local okG, g = U.call(pin, "GetParentActor")
                if not (okG and U.valid(g)) then okG, g = U.call(pin, "GetAttachParentActor") end
                local owner = (okG and U.valid(g)) and g or nil
                local ownerHidden = owner and U.get(owner, "bHidden") == true
                if not owner or (ownerHidden and not isHeld(owner)) then
                    U.log("grenade row: extra ring / cap %s on the chest (grenade %s) hidden", H.fname(pin),
                        owner and (H.fname(owner) .. ", hidden") or "gone")
                    hiddenPins[pin:GetAddress()] = H.fname(pin)     -- shown again with its grenade (setHidden)
                    U.call(pin, "SetActorHiddenInGame", true)
                elseif not failed["pin" .. pin:GetAddress()] then
                    failed["pin" .. pin:GetAddress()] = true
                    U.log("grenade row: a ring / cap is shown on the chest: %s of %s (hidden %s, held %s)", H.fname(pin),
                        H.fname(owner), tostring(ownerHidden), tostring(isHeld(owner)))
                end
            end
        end
    end
end

local function setScale(v, m, s)
    if v.scale and math.abs(v.scale - s) < 0.001 then return end
    v.scale = s
    U.call(v.actor, "SetActorScale3D", { X = m.scale.X * s, Y = m.scale.Y * s, Z = m.scale.Z * s })
end

local function makeVisual(pawn, slot, i, t)
    destroyVisual(i)
    local m = meshes[t]
    local a, comp = spawnVisual(pawn)
    if not a then return end
    U.call(comp, "SetStaticMesh", m.mesh)
    for k, mat in pairs(m.mats) do U.call(comp, "SetMaterial", k, mat) end
    -- The row goes along the line between both chest points.
    U.call(pawn, "AttachActorToHolsterBySlotSnap", a, slot == CHEST_LEFT and CHEST_RIGHT or CHEST_LEFT)
    local other = actorLoc(a)
    U.call(pawn, "AttachActorToHolsterBySlotSnap", a, slot)
    local here = actorLoc(a)
    U.call(a, "K2_AddActorLocalOffset", m.loc, false, {}, true)
    U.call(a, "K2_AddActorLocalRotation", m.rot, false, {}, true)
    if other and here then
        local dir = U.vnorm(U.vsub(other, here))
        U.call(a, "K2_AddActorWorldOffset", U.vmul(dir, (i - 2) * SPACING), false, {}, true)
    end
    visuals[i] = { actor = a, comp = comp, type = t }
    if not m.pin or not U.valid(m.pin.mesh) then return end
    local pa, pc = spawnVisual(pawn)
    if not pa then return end
    U.call(pc, "SetStaticMesh", m.pin.mesh)
    for k, mat in pairs(m.pin.mats) do U.call(pc, "SetMaterial", k, mat) end
    U.call(pa, "K2_AttachToComponent", comp, FName("None"), 2, 2, 2, false)
    U.call(pa, "K2_SetActorRelativeLocation", m.pin.loc, false, {}, true)
    U.call(pa, "K2_SetActorRelativeRotation", m.pin.rot, false, {}, true)
    U.call(pa, "SetActorRelativeScale3D", m.pin.scale)
    visuals[i].pin = pa
end

-- ---------------------------------------------------------------------------------------------
-- The row
-- ---------------------------------------------------------------------------------------------
local function countRow(t)
    local n = 0
    for i = 1, MAX_CARRIED do if row[i] == t then n = n + 1 end end
    return n
end

local function reconcile(want)
    for _, t in ipairs(TYPE_ORDER) do
        for _ = 1, countRow(t) - want[t] do
            for i = MAX_CARRIED, 1, -1 do
                if row[i] == t then row[i] = nil; break end
            end
        end
    end
    for _, t in ipairs(TYPE_ORDER) do
        for _ = 1, want[t] - countRow(t) do
            for _, i in ipairs(FILL_ORDER) do
                if row[i] == nil then row[i] = t; break end
            end
        end
    end
end

local function firstType()
    for _, i in ipairs(FILL_ORDER) do if row[i] then return row[i] end end
    return nil
end

local function handLoc(ctrl)
    local ok, l = U.call(U.get(ctrl, "MotionController"), "K2_GetComponentLocation")
    return (ok and l) and U.vec(l) or nil
end

local function nearest(ctrl)
    local l = handLoc(ctrl)
    if not l then return nil end
    local best, bestD = nil, math.max(C.get("body_grab_distance"), 3)
    for i = 1, MAX_CARRIED do
        local v = visuals[i]
        local p = v and row[i] and U.valid(v.actor) and actorLoc(v.actor) or nil
        if p then
            local d = U.vlen(U.vsub(p, l))
            if d <= bestD then best, bestD = i, d end
        end
    end
    return best
end

-- Grenades on the floor within reach of each empty hand.
local function scanFloor(pawn, now, ctrls, empty, occ)
    if now - lastFloorScan < 0.15 and now >= lastFloorScan then return end
    lastFloorScan = now
    nearFloor = {}
    local hands = {}
    for side, c in pairs(ctrls) do if empty[side] then hands[side] = handLoc(c) end end
    if next(hands) == nil then return end
    for _, g in ipairs(FindAllOf("BP_GrenadeBase_C") or {}) do
        if U.valid(g) and typeOf(g) and not isHeld(g) and U.get(g, "Cooking") ~= true and not U.same(g, occ)
            and not U.same(U.get(g, "WeaponOwner"), pawn) and not known[g:GetAddress()] then
            local l = location(U.get(g, "Model"), "K2_GetComponentLocation") or actorLoc(g)
            if l then
                for side, h in pairs(hands) do
                    if U.vlen(U.vsub(l, h)) <= FLOOR_RANGE then nearFloor[side] = true end
                end
            end
        end
    end
end

-- What EquipGrenadeFromHolsterSlot does, whatever the other hand holds.
local function take(pawn, hc, slot, side, ctrl, i)
    local t = row[i]
    local g = ensureReal(pawn, hc, slot, t)
    if not g then return end
    g.DisablePickup = true
    U.call(g, "OnRep_DisablePickup")
    U.call(g, "StopLerp")
    local ok, err = U.call(ctrl, "AttachObjectToHand", g, false)
    if not ok or not isHeld(g) then
        failOnce("take", "could not take a grenade: %s", tostring(err))
        return
    end
    if U.get(ctrl, "GameHand") == 0 then pawn.CurrentGunMainhand = g else pawn.CurrentGunOffhand = g end
    row[i] = nil
    holding[side] = g:GetAddress()
    setHidden(g, false)
    U.log("grenade row: %s taken by the %s hand", H.fname(g), side)
end

-- Hooks: the game has handled a grip press (its own grab is done).
function M.onGrabPressed(pawn, weaponHand)
    if not M.active then return end
    local ctrl = U.get(pawn, weaponHand and "WeaponHandController" or "MovementHandController")
    if U.same(ctrl, U.get(pawn, "LeftController")) then pressed.Left = true
    elseif U.same(ctrl, U.get(pawn, "RightController")) then pressed.Right = true end
end

-- Grenades on the chest, and the game's count of a type at the end of the last tick.
function M.onChest()
    local n = 0
    for i = 1, MAX_CARRIED do if row[i] then n = n + 1 end end
    return n
end
function M.counted(t) return bag[t] end
M.MAX_CARRIED = MAX_CARRIED

-- Is that hand at one of the grenades?
function M.isAt(side) return M.active and hover[side] ~= nil end

-- Is this the chest zone that the row handles? (bodygrab.lua's own tap is skipped there)
function M.ownsSlot(pawn, slot) return M.active and slot == U.get(pawn, "GrenadeHolsterSlot") end

local function disable(pawn, hc)
    giveBack(pawn)
    for i = 1, MAX_CARRIED do destroyVisual(i) end
    local slot = U.get(pawn, "GrenadeHolsterSlot")
    if U.valid(hiddenProxy) then setProxyVisible(hiddenProxy, true) end
    if U.valid(hc) and type(slot) == "number" then
        local t = firstType()
        if t and H.occupant(hc, slot) == nil then ensureReal(pawn, hc, slot, t) end
        showReal(hc, slot)
    end
    hiddenProxy = nil
    row, hover, holding, pressed, quiet = {}, {}, {}, {}, {}
end

function M.reset()
    for i = 1, MAX_CARRIED do destroyVisual(i) end
    row, visuals, meshes, classOf, known, hover, holding, pressed, quiet = {}, {}, {}, {}, {}, {}, {}, {}, {}
    hiddenProxy, hiddenPins, nearFloor, bag, proxyHidden = nil, {}, {}, {}, {}
    for _, s in pairs(spawnedMeshes) do
        if U.valid(s.a) and H.fname(s.a) == s.name then U.call(s.a, "K2_DestroyActor") end
    end
    spawnedMeshes = {}
    M.forgetLoan()
end

function M.tick(pawn, now)
    local hc = U.get(pawn, "HolstersComponent")
    local slot = U.get(pawn, "GrenadeHolsterSlot")
    local addr = pawn:GetAddress()
    if addr ~= lastPawn then lastPawn = addr; M.reset() end
    local ammo = U.valid(hc) and type(slot) == "number" and C.get("grenade_row") == true
        and U.get(hc, "InfiniteAmmoInInventory") ~= true and ammoCounts(pawn) or nil
    if not ammo then
        if M.active then M.active = false; disable(pawn, hc) end
        return
    end
    M.active = true

    -- Grenades in the hands still count as ammo.
    local want = {}
    for _, t in ipairs(TYPE_ORDER) do want[t] = ammo[t] + loan[t] end
    local ctrls = { Left = U.get(pawn, "LeftController"), Right = U.get(pawn, "RightController") }
    local empty = {}
    for _, side in ipairs({ "Left", "Right" }) do
        local o = U.get(ctrls[side], "AttachedObject")
        local t = U.valid(o) and typeOf(o) or nil
        empty[side] = U.valid(ctrls[side]) and not U.valid(o)
        if t and isHeld(o) then
            remember(o)
            want[t] = math.max(0, want[t] - 1)
            -- (Only makes the game take one away when it is put back with more than 3 of its type.)
            if U.get(o, "GrabbedFromWorld") == true then o.GrabbedFromWorld = false end
            if holding[side] ~= o:GetAddress() then
                holding[side] = o:GetAddress()
                -- Taken from the chest by the game: leave a gap where the hand was.
                local i = hover[side]
                if i and row[i] == t then row[i] = nil end
            end
            setHidden(o, false)
        else
            if holding[side] then quiet[side] = true end
            holding[side] = nil
        end
    end
    -- More than the chest takes (an ammo box taken while part of the count is lent): the rest of the loan is lost.
    local over = want[2] + want[3] + want[7] - MAX_CARRIED
    for _, t in ipairs(TYPE_ORDER) do
        local n = math.min(over, loan[t], want[t])
        if n > 0 then loan[t], want[t], over = loan[t] - n, want[t] - n, over - n end
    end
    reconcile(want)

    local occ = H.occupant(hc, slot)
    if occ and typeOf(occ) then remember(occ) end
    destroyOrphans(pawn, hc, slot)

    -- Hands about to take a grenade from the floor.
    scanFloor(pawn, now, ctrls, empty, occ)
    local floor = (nearFloor.Left and empty.Left) or (nearFloor.Right and empty.Right)
    if floor and occ and typeOf(occ) and isHeld(occ) then
        clearChest(hc, slot)
        occ = nil
    end

    -- A real one on the chest, also to learn the mesh of each type.
    local learnType = nil
    for i = 1, MAX_CARRIED do
        if row[i] and not (meshes[row[i]] and U.valid(meshes[row[i]].mesh)) then learnType = row[i]; break end
    end
    if learnType then
        if not failed["mesh" .. learnType] then ensureReal(pawn, hc, slot, learnType) end
    elseif H.occupant(hc, slot) == nil and firstType() then
        ensureReal(pawn, hc, slot, firstType())
    end
    learn(hc, slot)
    local real = H.occupant(hc, slot)
    if real and typeOf(real) and not isHeld(real) then hideReal(hc, slot) end

    -- Meshes
    local scale = C.get("grenade_row_scale")
    for i = 1, MAX_CARRIED do
        local t, v = row[i], visuals[i]
        if v and (not U.valid(v.actor) or v.type ~= t or (meshes[t] and meshes[t].pin and not U.valid(v.pin))) then destroyVisual(i); v = nil end
        if t and not v and meshes[t] and U.valid(meshes[t].mesh) then makeVisual(pawn, slot, i, t) end
    end

    -- What each hand would take
    for k, side in ipairs({ "Left", "Right" }) do
        local ctrl = ctrls[side]
        local can = empty[side] and U.get(ctrl, "GrabbingDisabled") ~= true and U.get(hc, "DisableGrenadeGrabbing") ~= true
        local i = can and nearest(ctrl) or nil
        if not i then quiet[side] = nil end
        if i ~= hover[side] then
            if i and not quiet[side] and C.get("haptics_holster_zone") then Haptics.zoneTap(now, k - 1) end
            hover[side] = i
        end
        if i then
            ensureReal(pawn, hc, slot, row[i])
            if pressed[side] then take(pawn, hc, slot, side, ctrl, i) end
        end
        pressed[side] = nil
    end
    for i = 1, MAX_CARRIED do
        local v = visuals[i]
        if v and row[i] then
            local big = (hover.Left == i and not quiet.Left) or (hover.Right == i and not quiet.Right)
            setScale(v, meshes[v.type], scale * (big and HOVER_SCALE or 1))
        elseif v then
            destroyVisual(i)
        end
    end

    strayScan(now)

    -- The loan (last: what the mod itself has just taken or spawned counts).
    if not floor then giveBack(pawn) end
    local count = ammoCounts(pawn) or ammo
    if floor then
        local hands = { [2] = 0, [3] = 0, [7] = 0 }
        for _, side in ipairs({ "Left", "Right" }) do
            local o = U.get(ctrls[side], "AttachedObject")
            local t = U.valid(o) and typeOf(o) or nil
            if t and isHeld(o) then hands[t] = hands[t] + 1 end
        end
        lend(pawn, count, hands)
        count = ammoCounts(pawn) or count
    end
    bag = count
end

return M
