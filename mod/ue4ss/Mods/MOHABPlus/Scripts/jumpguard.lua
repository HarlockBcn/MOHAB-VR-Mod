-- Jump guard: jumping must not take the player out of the playable area, while still letting them climb onto and
-- walk around on tables, rocks, crates...
--
-- The levels are bounded by invisible player blockers (actors like "PlayerCollision91" or hidden cubes) sized for a
-- player who cannot jump, so they are often low enough to jump over. The guard makes them infinitely tall: while
-- the player is in the air or standing above the floor they last walked on, every horizontal move is swept with a
-- hidden capsule that has the player's exact collision and reaches from that floor up to the player's head. Only
-- invisible blockers count: anything visible the capsule touches (the table under the player, a rock, a wall) is
-- ignored from then on, because the player's own movement collision already handles it. If an invisible blocker
-- is in the way, the player stays where they were (keeping the height) and loses the horizontal speed.
--
-- "Invisible blocker" = an actor whose primitive components are all invisible (props with a hidden collision box
-- but a visible mesh are climbable). Pawns (NPC capsules are hidden) never count.
local U = require("util")

local M = {}

local PARK = { X = 0, Y = 0, Z = -200000 }
local MAX_RETRIES = 8

local st = nil               -- state while guarding (nil = inactive)
local helper, helperCap = nil, nil
local helperPawnAddr = nil
local invisibleCache = {}    -- actor address -> { name =, invisible = }
local primClass, pawnClass = nil, nil

local function vec(x, y, z) return { X = x, Y = y, Z = z } end

local function capsuleDims(pawn)
    local cap = U.get(pawn, "CapsuleComponent")
    local ok1, r = U.call(cap, "GetScaledCapsuleRadius")
    local ok2, hh = U.call(cap, "GetScaledCapsuleHalfHeight")
    if ok1 and ok2 and type(r) == "number" and type(hh) == "number" and r > 0 and hh > 0 then return r, hh end
    return nil
end

local function location(obj, fn)
    local ok, l = U.call(obj, fn or "K2_GetActorLocation")
    if ok and l then return vec(l.X, l.Y, l.Z) end
    return nil
end

local function stepHeight(pawn)
    local s = U.get(U.get(pawn, "CharacterMovement"), "MaxStepHeight")
    if type(s) ~= "number" then s = 45 end
    return U.clamp(s, 10, 60)
end

local function name(o)
    if not U.valid(o) then return "?" end
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or "?"
end

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

-- ---------------------------------------------------------------------------------------------
-- Helper capsule with the player's collision
-- ---------------------------------------------------------------------------------------------
local function ensureHelper(pawn)
    if U.valid(helper) and U.valid(helperCap) and helperPawnAddr == pawn:GetAddress() then return true end
    if U.valid(helper) then U.call(helper, "K2_DestroyActor") end
    helper, helperCap = nil, nil
    invisibleCache = {}
    local cls = StaticFindObject("/Script/Engine.TriggerCapsule")
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not U.valid(cls) or not U.valid(gs) then U.log("jump guard: TriggerCapsule class not found"); return false end
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = PARK, Scale3D = vec(1, 1, 1) }
    local ok, a = U.call(gs, "BeginDeferredActorSpawnFromClass", pawn, cls, xf, 1, nil)
    if not ok or not U.valid(a) then U.log("jump guard: could not spawn the helper (%s)", tostring(a)); return false end
    U.call(gs, "FinishSpawningActor", a, xf)
    local cap = U.get(a, "CollisionComponent")
    if not U.valid(cap) then U.log("jump guard: helper has no capsule"); return false end
    local src = U.get(pawn, "CapsuleComponent")
    U.call(cap, "SetMobility", 2)                       -- Movable
    U.call(cap, "SetGenerateOverlapEvents", false)      -- never fire level triggers
    local okT, objType = U.call(src, "GetCollisionObjectType")
    if okT and type(objType) == "number" then U.call(cap, "SetCollisionObjectType", objType) end
    for ch = 0, 31 do
        local okR, resp = U.call(src, "GetCollisionResponseToChannel", ch)
        if okR and type(resp) == "number" then U.call(cap, "SetCollisionResponseToChannel", ch, resp) end
    end
    U.call(cap, "SetCollisionResponseToChannel", 3, 0)  -- Visibility: ignore (never block AI sight traces)
    U.call(cap, "SetCollisionResponseToChannel", 4, 0)  -- Camera: ignore
    U.call(cap, "SetCollisionEnabled", 1)               -- query only
    U.call(cap, "IgnoreActorWhenMoving", pawn, true)
    U.call(src, "IgnoreActorWhenMoving", a, true)       -- the player never bumps into it either
    U.call(a, "SetActorHiddenInGame", true)
    helper, helperCap, helperPawnAddr = a, cap, pawn:GetAddress()
    U.dlog("jump guard: helper capsule ready (object type %s)", tostring(objType))
    return true
end

local function park()
    if U.valid(helperCap) then U.call(helperCap, "K2_SetWorldLocation", PARK, false, {}, true) end
end

local function hitInfo(hit)
    local actor, comp = nil, nil
    pcall(function()
        local x = hit.Actor
        if x and x.Get then x = x:Get() end
        if U.valid(x) then actor = x end
    end)
    pcall(function()
        local x = hit.Component
        if x and x.Get then x = x:Get() end
        if U.valid(x) then comp = x end
    end)
    return actor, comp
end

-- True for the player's own hands, held weapons and anything else attached to / owned by the pawn.
local function belongsToPawn(actor, pawn)
    local a = actor
    for _ = 1, 5 do
        if not U.valid(a) then return false end
        if U.same(a, pawn) then return true end
        local ok, parent = U.call(a, "GetAttachParentActor")
        if ok and U.valid(parent) then a = parent else a = U.get(a, "Owner") end
    end
    return false
end

-- An invisible level blocker: not a pawn, and none of its primitive components is visible.
local function isInvisibleBlocker(actor)
    if not U.valid(actor) then return false end
    local addr = actor:GetAddress()
    local key = name(actor)
    local c = invisibleCache[addr]
    if c and c.name == key then return c.invisible end
    if not U.valid(primClass) then primClass = StaticFindObject("/Script/Engine.PrimitiveComponent") end
    if not U.valid(pawnClass) then pawnClass = StaticFindObject("/Script/Engine.Pawn") end
    local invisible = true
    local okP, isPawn = pcall(function() return actor:IsA(pawnClass) end)
    if okP and isPawn then invisible = false end
    if invisible and U.get(actor, "bHidden") ~= true then
        local ok, arr = U.call(actor, "K2_GetComponentsByClass", primClass)
        local comps = ok and arrayItems(arr) or {}
        for _, comp in ipairs(comps) do
            local okV, vis = U.call(comp, "IsVisible")
            if okV and vis then invisible = false; break end
        end
    end
    invisibleCache[addr] = { name = key, invisible = invisible }
    U.dlog("jump guard: %s is %s", key, invisible and "an invisible blocker" or "visible (ignored)")
    return invisible
end

-- Sweeps the helper capsule from a to b. Returns the invisible blocker in the way, or nil.
-- Visible things and the player's own stuff are ignored from then on and the sweep is repeated.
local function sweepForBlocker(pawn, a, b)
    for _ = 1, MAX_RETRIES do
        U.call(helperCap, "K2_SetWorldLocation", a, false, {}, true)
        local hit = {}
        U.call(helperCap, "K2_SetWorldLocation", b, true, hit, false)
        local p = location(helperCap, "K2_GetComponentLocation") or a
        local dx, dy, dz = b.X - p.X, b.Y - p.Y, b.Z - p.Z
        if dx * dx + dy * dy + dz * dz < 0.04 then return nil end
        local actor, comp = hitInfo(hit)
        if not actor and not comp then return nil end         -- no information: do not block
        if actor and belongsToPawn(actor, pawn) then
            U.call(helperCap, "IgnoreActorWhenMoving", actor, true)
        elseif actor and isInvisibleBlocker(actor) then
            -- Also when the sweep starts touching it (the player jumped while pressed against it): the engine only
            -- reports a starting overlap as blocking when moving further into it, moving away is let through.
            return actor
        elseif comp then
            U.call(helperCap, "IgnoreComponentWhenMoving", comp, true)
        else
            U.call(helperCap, "IgnoreActorWhenMoving", actor, true)
        end
    end
    return nil
end

local function teleportXY(pawn, x, y, z)
    U.call(pawn, "K2_SetActorLocation", vec(x, y, z), false, {}, true)
    local cmc = U.get(pawn, "CharacterMovement")
    pcall(function()
        local v = cmc.Velocity
        cmc.Velocity = { X = 0, Y = 0, Z = v.Z }
    end)
end

-- ---------------------------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------------------------
function M.active() return st ~= nil end

-- Called when a jump starts (keeps the current state if already guarding: jumping off a table).
function M.start(pawn)
    if st then return end
    local loc = location(pawn)
    local r, hh = capsuleDims(pawn)
    if not loc or not r or not ensureHelper(pawn) then return end
    st = { px = loc.X, py = loc.Y, base = loc.Z - hh, lastBlocker = nil, t0 = os.clock() }
    U.dlog("jump guard: on (floor %.0f)", st.base)
end

-- Every frame while active.
function M.update(pawn, falling)
    if not st then return end
    if not U.valid(helperCap) then st = nil; return end
    local cur = location(pawn)
    local r, hh = capsuleDims(pawn)
    if not cur or not r then return end
    local step = stepHeight(pawn)
    local feet = cur.Z - hh

    -- Floor the player last walked on: follows them on the ground (stairs, ramps, lower floors), but not up onto
    -- things they jumped onto.
    if not falling and feet <= st.base + step then st.base = feet end
    if not falling and feet < st.base then st.base = feet end

    local dx, dy = cur.X - st.px, cur.Y - st.py
    if dx * dx + dy * dy > 0.25 then
        -- Capsule from just above that floor up to the player's head.
        local bottom = math.min(st.base, feet) + 2
        local top = cur.Z + hh
        local half = math.max(r, (top - bottom) / 2)
        U.call(helperCap, "SetCapsuleSize", r, half, false)
        local z = bottom + half
        local blocker = sweepForBlocker(pawn, vec(st.px, st.py, z), vec(cur.X, cur.Y, z))
        park()
        if blocker then
            local n = name(blocker)
            if st.lastBlocker ~= n then
                st.lastBlocker = n
                U.dlog("jump guard: stopped by invisible blocker %s (%.0f cm above the floor)", n, feet - st.base)
            end
            teleportXY(pawn, st.px, st.py, cur.Z)
            return
        end
        st.px, st.py = cur.X, cur.Y
    end

    -- Back on the floor: stop guarding (the game's own collision is enough there).
    if not falling and feet <= st.base + step and os.clock() - st.t0 > 0.2 then
        U.dlog("jump guard: off")
        st = nil
    end
end

function M.stop()
    st = nil
    park()
end

return M
