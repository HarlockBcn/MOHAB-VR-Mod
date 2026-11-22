-- Second-hand grab distance on two-handed weapons.
--
-- BP_MotionController picks what to grab purely by overlap: actors/components that overlap the hand's GrabCapsule
-- go into OverlappingGrabActors / OverlappingGrabComponents and the nearest one is grabbed. The off-hand grip of a
-- weapon is a child actor attached to it (BP_Weapon_Grip subclasses on rifles/SMGs/pistols, the shotgun pump, the
-- bazooka/panzerschreck/panzerfaust inner grips) with several large collision components, so the free hand grabs
-- it from far away.
--
-- The hand's GrabCapsule is not a small sphere: every frame BP_MotionController:UpdateGrabCapsule stretches it
-- forward along the hand (relative X and half height = clamp(-160 * forward.Z, 40, 100) cm), so it reaches up to
-- 2 m in front of the hand like a pointer - meant for picking things up from the floor. While the other hand holds
-- a weapon we shrink the free hand's capsule to weapon_grip_reach around the hand, by changing the parameters of the
-- two native calls UpdateGrabCapsule makes (K2_SetRelativeLocation / SetCapsuleHalfHeight) in pre-hooks, so the
-- big capsule never exists for a frame. Grabbing at a distance with a free hand is unchanged otherwise.
--
-- In addition, while one hand holds a weapon we measure the distance from the other hand's GrabCapsule to each of that weapon's
-- off-hand grips (its HandAttachPoint). Beyond weapon_grip_reach (cm) we turn off overlap events on the grip's
-- collision components, which makes the engine end the overlap with the hand; within reach they are restored and
-- the hand's next movement begins the overlap again. Everything is restored when the weapon is not held.
local U = require("util")
local C = require("config")

local M = {}

local GRIP_CLASSES = { "BP_Weapon_Grip_C", "BP_CombatShotgunPump_C", "BP_Bazooka_Inner_OffhandGrip_C" }
local COMP_NAMES = { "StaticMeshComponent", "ActualMesh", "GripCap", "GrippableCapsule", "Pump", "StaticMesh" }

local grips = {}          -- list of { actor =, parent = }
local gated = {}          -- grip address -> { actor =, comps = { { comp =, orig = } } }
local lastScan = -100
local weaponClass = nil
local caps = {}           -- free hand GrabCapsule address -> { center =, half = } while the other hand holds a weapon
local setFailed = false
local shrinking = false
local gripWasDown = false
local NEAR_ON, NEAR_OFF = 3, 8     -- cm beyond weapon_grip_reach where the capsule shrink starts / stops

local function parentOf(actor)
    local ok, p = U.call(actor, "GetAttachParentActor")
    if ok and U.valid(p) then return p end
    ok, p = U.call(actor, "GetParentActor")
    if ok and U.valid(p) then return p end
    return nil
end

-- An off-hand grip (child actor) that is no longer attached to its weapon while no hand holds it: after letting go
-- of the second grip it sometimes detaches and falls through the world, and the weapon can no longer be held with
-- two hands. Put it back on the weapon's child actor component.
local lastReattach = {}

-- The grip actor's root can stay in place while one of its collision components (the part the hand actually grabs)
-- starts simulating physics: it detaches from the grip and falls forever, so the hand never reaches it again. We
-- remember where each collision component sits while healthy and snap it back when it starts simulating or loses
-- its attach parent.
local compHome = {}       -- component address -> { parent =, socket =, loc =, rot = }
local classHome = {}      -- "<grip class>/<component name>" -> { loc =, rot = } (fallback for a grip first seen loose)

local function rotOf(r)
    if not r then return nil end
    local ok, v = pcall(function() return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end)
    return ok and v or nil
end

local function relLoc(comp)
    local v = U.get(comp, "RelativeLocation")
    return v and U.vec(v) or nil
end

local function checkComponents(grip, root)
    local cls = grip:GetClass():GetFName():ToString()
    for _, name in ipairs(COMP_NAMES) do
        local comp = U.get(grip, name)
        if U.valid(comp) and not U.same(comp, root) then
            local addr = comp:GetAddress()
            local okS, sim = U.call(comp, "IsSimulatingPhysics", FName("None"))
            local okP, parent = U.call(comp, "GetAttachParent")
            local attached = okP and U.valid(parent)
            local simulating = okS and sim
            if attached and not simulating then
                if not compHome[addr] then
                    local okN, socket = U.call(comp, "GetAttachSocketName")
                    local home = {
                        parent = parent, socket = okN and socket or FName("None"),
                        loc = relLoc(comp), rot = rotOf(U.get(comp, "RelativeRotation")),
                    }
                    if home.loc and home.rot then
                        compHome[addr] = home
                        classHome[cls .. "/" .. name] = classHome[cls .. "/" .. name] or { loc = home.loc, rot = home.rot }
                    end
                end
            else
                local key = addr .. "c"
                local t = os.clock()
                if not (lastReattach[key] and t - lastReattach[key] < 1.0) then
                    lastReattach[key] = t
                    local home = compHome[addr]
                    local target = home and U.valid(home.parent) and home.parent or root
                    local socket = home and home.socket or FName("None")
                    local rel = home or classHome[cls .. "/" .. name]
                    U.call(comp, "SetSimulatePhysics", false)
                    U.call(comp, "SetPhysicsLinearVelocity", { X = 0, Y = 0, Z = 0 }, false, FName("None"))
                    -- Location/rotation SnapToTarget (2), scale KeepRelative (0).
                    U.call(comp, "K2_AttachToComponent", target, socket, 2, 2, 0, true)
                    if rel then
                        U.call(comp, "K2_SetRelativeLocationAndRotation", rel.loc, rel.rot, false, {}, true)
                    end
                    local okA, p2 = U.call(comp, "GetAttachParent")
                    U.log("weapon grip %s: %s was loose (physics %s, attached %s) -> reattached=%s%s",
                        grip:GetFName():ToString(), name, tostring(simulating), tostring(attached),
                        tostring(okA and U.valid(p2)), rel and "" or " (position unknown)")
                end
            end
        end
    end
end

local function checkAttached(grip, weapon, otherHeld, freeHeld)
    if U.same(otherHeld, grip) or U.same(freeHeld, grip) then return end
    pcall(checkComponents, grip, select(2, U.call(grip, "K2_GetRootComponent")))
    local okC, cac = U.call(grip, "GetParentComponent")
    if not (okC and U.valid(cac)) then return end
    local okR, root = U.call(grip, "K2_GetRootComponent")
    local ok, ap = U.call(grip, "GetAttachParentActor")
    -- Still attached in the hierarchy is not enough: the grip's root may be simulating physics (it then falls while
    -- "attached"), so also compare its position with the child actor component it belongs to.
    local okS, simulating = U.call(root, "IsSimulatingPhysics", FName("None"))
    local okG, gl = U.call(grip, "K2_GetActorLocation")
    local okP, pl = U.call(cac, "K2_GetComponentLocation")
    local away = 0
    if okG and okP and gl and pl then
        local d = U.vsub(U.vec(gl), U.vec(pl))
        away = math.sqrt(U.vdot(d, d))
    end
    if ok and U.same(ap, weapon) and not (okS and simulating) and away < 30 then return end
    local addr = grip:GetAddress()
    local t = os.clock()
    if lastReattach[addr] and t - lastReattach[addr] < 1.0 then return end
    lastReattach[addr] = t
    if okR and U.valid(root) then U.call(root, "SetSimulatePhysics", false) end
    -- EAttachmentRule::SnapToTarget = 2
    U.call(grip, "K2_AttachToComponent", cac, FName("None"), 2, 2, 2, true)
    local okA, ap2 = U.call(grip, "GetAttachParentActor")
    U.log("weapon grip %s was loose on %s (parent %s, physics %s, %.0f cm away) -> reattached=%s",
        grip:GetFName():ToString(), weapon:GetFName():ToString(),
        (ok and U.valid(ap)) and ap:GetFName():ToString() or "none", tostring(okS and simulating), away,
        tostring(okA and U.same(ap2, weapon)))
end

-- Priority for the second grip: while the free hand is within reach of the held weapon's grip, other grabbable
-- things touching that hand (another weapon, an ammo box...) stop overlapping it, so the game can only pick the
-- grip. Overlap events are restored as soon as the hand leaves the grip's reach (or grabs it).
local blocked = {}        -- actor address -> { actor =, comps = { component, ... } }
local primClass = nil

local function arrayItems(arr)
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

local function blockActor(actor)
    local addr = actor:GetAddress()
    if blocked[addr] then return end
    if not U.valid(primClass) then primClass = StaticFindObject("/Script/Engine.PrimitiveComponent") end
    local st = { actor = actor, comps = {} }
    local ok, arr = U.call(actor, "K2_GetComponentsByClass", primClass)
    if ok then
        for _, comp in ipairs(arrayItems(arr)) do
            if U.get(comp, "bGenerateOverlapEvents") ~= false then
                U.call(comp, "SetGenerateOverlapEvents", false)
                st.comps[#st.comps + 1] = comp
            end
        end
    end
    blocked[addr] = st
    U.dlog("2-hand priority: %s blocked near the grip", actor:GetFName():ToString())
end

local function unblockAll()
    for addr, st in pairs(blocked) do
        blocked[addr] = nil
        if U.valid(st.actor) then
            for _, comp in ipairs(st.comps) do
                if U.valid(comp) then U.call(comp, "SetGenerateOverlapEvents", true) end
            end
        end
    end
end

-- Blocks everything the free hand overlaps except the held weapon and its grips.
local function prioritiseGrip(free, weapon)
    local function keep(actor)
        if U.same(actor, weapon) then return true end
        for _, g in ipairs(grips) do
            if U.same(actor, g.actor) then return true end
        end
        local okP, p = U.call(actor, "GetAttachParentActor")
        return okP and U.same(p, weapon)
    end
    for _, actor in ipairs(arrayItems(U.get(free, "OverlappingGrabActors"))) do
        if not keep(actor) then blockActor(actor) end
    end
    for _, comp in ipairs(arrayItems(U.get(free, "OverlappingGrabComponents"))) do
        local ok, owner = U.call(comp, "GetOwner")
        if ok and U.valid(owner) and not keep(owner) then blockActor(owner) end
    end
end

local function scan()
    grips = {}
    for _, cls in ipairs(GRIP_CLASSES) do
        local list = FindAllOf(cls)
        if list then
            for _, a in ipairs(list) do
                if U.valid(a) then grips[#grips + 1] = { actor = a, parent = parentOf(a) } end
            end
        end
    end
end

local function setGated(grip, want, dist)
    local addr = grip:GetAddress()
    local st = gated[addr]
    if want then
        if st then return end
        st = { actor = grip, comps = {} }
        for _, name in ipairs(COMP_NAMES) do
            local comp = U.get(grip, name)
            if U.valid(comp) then
                local orig = U.get(comp, "bGenerateOverlapEvents")
                if orig ~= false then
                    U.call(comp, "SetGenerateOverlapEvents", false)
                    st.comps[#st.comps + 1] = comp
                end
            end
        end
        gated[addr] = st
        U.dlog("weapon grip %s out of reach (%.0f cm)", grip:GetFName():ToString(), dist or -1)
    elseif st then
        gated[addr] = nil
        if U.valid(grip) then
            for _, comp in ipairs(st.comps) do
                if U.valid(comp) then U.call(comp, "SetGenerateOverlapEvents", true) end
            end
            U.dlog("weapon grip %s in reach (%s cm)", grip:GetFName():ToString(), dist and string.format("%.0f", dist) or "-")
        end
    end
end

local function location(comp)
    local ok, v = U.call(comp, "K2_GetComponentLocation")
    if ok and v then return U.vec(v) end
    return nil
end

local function isWeapon(obj)
    if not U.valid(obj) then return false end
    if not U.valid(weaponClass) then
        weaponClass = StaticFindObject("/Game/R6/Core/Weapons/BP_WeaponBase.BP_WeaponBase_C")
        if not U.valid(weaponClass) then return false end
    end
    local ok, r = pcall(function() return obj:IsA(weaponClass) end)
    return ok and r
end

function M.tick(pawn, now)
    if now - lastScan > 1.0 or now < lastScan then
        lastScan = now
        scan()
    end

    -- Which hand holds a weapon, and which one is free.
    local left, right = U.get(pawn, "LeftController"), U.get(pawn, "RightController")
    local weapon, free = nil, nil
    if U.valid(left) and U.valid(right) then
        local lo, ro = U.get(left, "AttachedObject"), U.get(right, "AttachedObject")
        if isWeapon(ro) then weapon, free = ro, left
        elseif isWeapon(lo) then weapon, free = lo, right end
    end

    local reach = U.clamp(C.get("weapon_grip_reach"), 3, 100)
    local handLoc = nil
    local freeHeld = nil
    local minDist = nil
    if weapon then
        handLoc = location(U.get(free, "GrabSphere")) or location(U.get(free, "GrabCapsule"))
        freeHeld = U.get(free, "AttachedObject")
    end

    for _, g in ipairs(grips) do
        local grip = g.actor
        if U.valid(grip) then
            local want, dist = false, nil
            if weapon and g.parent and U.same(g.parent, weapon) then
                pcall(checkAttached, grip, weapon, U.get(U.same(free, left) and right or left, "AttachedObject"), freeHeld)
            end
            if weapon and handLoc and g.parent and U.same(g.parent, weapon) and not U.same(freeHeld, grip) then
                -- Distance from the hand to the nearest point of the grip's collision (its HandAttachPoint can be
                -- far from where the hand actually touches it, e.g. pistols and scoped rifles).
                for _, name in ipairs(COMP_NAMES) do
                    local comp = U.get(grip, name)
                    if U.valid(comp) then
                        local ok, d = U.call(comp, "GetClosestPointOnCollision", handLoc, { X = 0, Y = 0, Z = 0 }, FName("None"))
                        if ok and type(d) == "number" and d >= 0 and (not dist or d < dist) then dist = d end
                    end
                end
                if not dist then
                    local target = location(U.get(grip, "HandAttachPoint"))
                    if not target then
                        local ok, v = U.call(grip, "K2_GetActorLocation")
                        if ok and v then target = U.vec(v) end
                    end
                    if target then
                        local d = U.vsub(target, handLoc)
                        dist = math.sqrt(U.vdot(d, d))
                    end
                end
                if dist then
                    want = dist > reach
                    if not minDist or dist < minDist then minDist = dist end
                end
            end
            setGated(grip, want, dist)
        end
    end

    -- Shrink the free hand's grab capsule only while it is within reach of the held weapon's grips (taking the second
    -- grip). Otherwise it keeps the game's long forward capsule, so ammo, grenades... can still be picked up (also
    -- near the weapon); the grip itself stays out of reach thanks to the gate above. Hysteresis avoids flicker.
    local near = minDist and minDist <= reach + (shrinking and NEAR_OFF or NEAR_ON)
    caps = {}
    shrinking = false
    if weapon and near and not U.valid(freeHeld) then
        local cap = U.get(free, "GrabCapsule")
        if U.valid(cap) then
            local ok, r = U.call(cap, "GetUnscaledCapsuleRadius")
            if not (ok and type(r) == "number") then r = 8 end
            -- capsule along the hand's forward axis, centred on the hand: reaches `reach` in front of and behind it
            -- (pistols are two-handed from below/behind the other hand), and r sideways.
            caps[cap:GetAddress()] = { center = r * 0.5, half = reach + r }
            shrinking = true
        end
    end
    if shrinking then pcall(prioritiseGrip, free, weapon) elseif next(blocked) then unblockAll() end

    -- Diagnostics (debug_log only, once per press): free hand presses grip while the other hand holds a weapon.
    if weapon and U.debug then
        local side = U.same(free, left) and "Left" or "Right"
        local down = U.axis("OculusTouch_" .. side .. "_Grip_Axis") > 0.6
        if down and not gripWasDown then
            local parts = {}
            for _, g in ipairs(grips) do
                if U.valid(g.actor) and g.parent and U.same(g.parent, weapon) then
                    local st = gated[g.actor:GetAddress()]
                    parts[#parts + 1] = string.format("%s gated=%s", g.actor:GetFName():ToString(), tostring(st ~= nil))
                end
            end
            U.dlog("2-hand diag: %s hand grip on %s: nearest grip %s cm (reach %.0f), small capsule=%s, holding=%s, grips: %s",
                side, weapon:GetFName():ToString(), minDist and string.format("%.1f", minDist) or "none", reach,
                tostring(shrinking), U.valid(freeHeld) and freeHeld:GetFName():ToString() or "nothing",
                #parts > 0 and table.concat(parts, ", ") or "NONE FOUND")
        end
        gripWasDown = down
    else
        gripWasDown = false
    end

    -- Grips that disappeared from the list (scan) but are still gated: restore them.
    for addr, st in pairs(gated) do
        local found = false
        for _, g in ipairs(grips) do
            if U.valid(g.actor) and g.actor:GetAddress() == addr then found = true; break end
        end
        if not found then setGated(st.actor, false) ; gated[addr] = nil end
    end
end

-- Pre-hook of SceneComponent:K2_SetRelativeLocation(NewLocation, bSweep, SweepHitResult, bTeleport).
function M.onSetRelativeLocation(ctx, newLoc)
    if next(caps) == nil then return end
    local comp = ctx:get()
    local c = caps[comp:GetAddress()]
    if not c then return end
    local v = newLoc:get()
    local ok, err = pcall(function() newLoc:set({ X = c.center, Y = v.Y, Z = v.Z }) end)
    if not ok and not setFailed then setFailed = true; U.log("grab capsule location override failed: %s", tostring(err)) end
end

-- Pre-hook of CapsuleComponent:SetCapsuleHalfHeight(HalfHeight, bUpdateOverlaps).
function M.onSetHalfHeight(ctx, halfHeight)
    if next(caps) == nil then return end
    local comp = ctx:get()
    local c = caps[comp:GetAddress()]
    if not c then return end
    local ok, err = pcall(function() halfHeight:set(c.half) end)
    if not ok and not setFailed then setFailed = true; U.log("grab capsule size override failed: %s", tostring(err)) end
end

function M.reset()
    pcall(unblockAll)
    blocked = {}
    caps, shrinking = {}, false
    grips, gated = {}, {}
    compHome, lastReattach = {}, {}
    lastScan = -100
end

return M
