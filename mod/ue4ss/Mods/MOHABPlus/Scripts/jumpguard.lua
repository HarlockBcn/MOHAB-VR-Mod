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
-- but a visible mesh are climbable) and that does not block the Visibility channel (invisible collision standing in
-- for real walls and props does, see isInvisibleBlocker). Pawns (NPC capsules are hidden) never count.
local U = require("util")

local M = {}

local PARK = { X = 0, Y = 0, Z = -200000 }
local MAX_RETRIES = 8

local st = nil               -- state while guarding (nil = inactive)
local helper, helperCap = nil, nil
local helperPawnAddr = nil
local invisibleCache = {}    -- actor address -> { name =, invisible = }
local headIgnore = {}        -- the player's own actors, ignored by the head traces (reset with the helper)
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
    headIgnore = {}
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

-- An invisible level boundary: not a pawn, none of its primitive components is visible, and it does not stand in
-- for real geometry. Levels also use invisible simplified collision for visible walls, crates and props (e.g.
-- "WorldStaticCollision121"); those block sight / bullets (the Visibility channel) like the geometry they replace,
-- while boundaries only meant for the player ("PlayerCollision91") let them through. Names that say "Player" are
-- always boundaries.
local function isInvisibleBlocker(actor)
    if not U.valid(actor) then return false end
    local addr = actor:GetAddress()
    local key = name(actor)
    local c = invisibleCache[addr]
    if c and c.name == key then return c.invisible end
    if not U.valid(primClass) then primClass = StaticFindObject("/Script/Engine.PrimitiveComponent") end
    if not U.valid(pawnClass) then pawnClass = StaticFindObject("/Script/Engine.Pawn") end
    local invisible, why = true, ""
    local okP, isPawn = pcall(function() return actor:IsA(pawnClass) end)
    if okP and isPawn then invisible, why = false, "pawn" end
    local ok, arr = U.call(actor, "K2_GetComponentsByClass", primClass)
    local comps = ok and arrayItems(arr) or {}
    local hidden = U.get(actor, "bHidden") == true
    local blocksSight = false
    for _, comp in ipairs(comps) do
        if invisible and not hidden then
            local okV, vis = U.call(comp, "IsVisible")
            if okV and vis then invisible, why = false, "visible" end
        end
        local okE, enabled = U.call(comp, "GetCollisionEnabled")
        local okR, resp = U.call(comp, "GetCollisionResponseToChannel", 3)
        if okE and type(enabled) == "number" and enabled ~= 0 and okR and resp == 2 then blocksSight = true end
    end
    local cls = "?"
    pcall(function() cls = actor:GetClass():GetFName():ToString() end)
    if invisible and blocksSight and not key:find("Player") and not cls:find("Player") then
        invisible, why = false, "invisible collision of real geometry (blocks sight)"
    end
    invisibleCache[addr] = { name = key, invisible = invisible }
    U.dlog("jump guard: %s [%s] is %s", key, cls, invisible and "an invisible boundary" or ("ignored: " .. why))
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

-- ---------------------------------------------------------------------------------------------
-- Head vs visible geometry. Ceilings and upper walls the player was never meant to reach often have no collision
-- for the player capsule, so the body passes through them; they still block the Visibility channel (sight,
-- bullets). The head is checked against that channel.
-- ---------------------------------------------------------------------------------------------
local HEAD_RADIUS = 12
local kismet = nil
local head = nil             -- per jump: { loc = actor location, cam = head location } of the last valid frame

local function headLoc(pawn)
    return location(U.get(pawn, "VRReplicatedCamera"), "K2_GetComponentLocation")
end

-- Sphere trace against the real triangles (complex collision: architecture often has no simple collision) on the
-- Visibility and Camera channels (TraceTypeQuery1 / 2). Returns the blocking actor (false if unknown) or nil.
local traceFailLogged = false
local function sightBlocked(pawn, a, b)
    if not U.valid(kismet) then kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    for _, channel in ipairs({ 0, 1 }) do
        for _ = 1, MAX_RETRIES do
            local hit = {}
            local ok, blocked = U.call(kismet, "SphereTraceSingle", pawn, a, b, HEAD_RADIUS, channel, true, headIgnore, 0,
                hit, true, NOCOLOR, NOCOLOR, 0)
            if not ok then
                if not traceFailLogged then traceFailLogged = true; U.log("jump guard: head trace failed: %s", tostring(blocked)) end
                break
            end
            if not blocked then break end
            local actor = hitInfo(hit)
            if actor and belongsToPawn(actor, pawn) then
                headIgnore[#headIgnore + 1] = actor
            else
                local okS, startPen = pcall(function() return hit.bStartPenetrating end)
                if not (okS and startPen) then return actor or false end   -- head already inside: never trap
                break
            end
        end
    end
    return nil
end

-- Called when a jump starts.
function M.headStart(pawn)
    local loc, cam = location(pawn), headLoc(pawn)
    head = (loc and cam) and { loc = loc, cam = cam } or nil
end

-- Every airborne frame of a jump: the head may not pass through visible geometry. Returns true if it was stopped.
function M.headUpdate(pawn)
    if not head then return false end
    local loc, cam = location(pawn), headLoc(pawn)
    if not loc or not cam then return false end
    local dx, dy, dz = cam.X - head.cam.X, cam.Y - head.cam.Y, cam.Z - head.cam.Z
    if dx * dx + dy * dy + dz * dz < 0.25 then return false end
    local blocker = sightBlocked(pawn, head.cam, cam)
    if blocker == nil then
        head.loc, head.cam = loc, cam
        return false
    end
    -- Back to the last valid position, no horizontal speed, and no more rising.
    U.call(pawn, "K2_SetActorLocation", head.loc, false, {}, true)
    local cmc = U.get(pawn, "CharacterMovement")
    pcall(function()
        local v = cmc.Velocity
        cmc.Velocity = { X = 0, Y = 0, Z = math.min(v.Z, 0) }
    end)
    if not head.logged then
        head.logged = true
        U.dlog("jump guard: head stopped by %s", name(blocker or nil))
    end
    return true
end

function M.headStop()
    head = nil
end

-- Room above the player's head before a jump: sweeps the player's capsule straight up by `height` cm.
-- Returns true when nothing (visible or not) is in the way. Unknown (helper unavailable) counts as clear.
function M.headClear(pawn, height)
    local loc = location(pawn)
    local r, hh = capsuleDims(pawn)
    if not loc or not r or not ensureHelper(pawn) then return true end
    U.call(helperCap, "SetCapsuleSize", math.max(1, r - 1), hh, false)
    local target = vec(loc.X, loc.Y, loc.Z + height)
    local clear = true
    for _ = 1, MAX_RETRIES do
        U.call(helperCap, "K2_SetWorldLocation", loc, false, {}, true)
        local hit = {}
        U.call(helperCap, "K2_SetWorldLocation", target, true, hit, false)
        local p = location(helperCap, "K2_GetComponentLocation") or loc
        if target.Z - p.Z < 2 then clear = true; break end
        local actor = hitInfo(hit)
        if actor and belongsToPawn(actor, pawn) then
            U.call(helperCap, "IgnoreActorWhenMoving", actor, true)
        else
            clear = false
            U.log("jump refused: ceiling %.0f cm above the head (%s)", p.Z - loc.Z, name(actor))
            break
        end
    end
    park()
    -- Ceilings without player collision: the head must not go through visible geometry either.
    if clear then
        local cam = headLoc(pawn)
        if cam then
            local blocker = sightBlocked(pawn, cam, vec(cam.X, cam.Y, cam.Z + height + 5))
            if blocker ~= nil then
                clear = false
                U.log("jump refused: something visible above the head (%s)", name(blocker or nil))
            else
                U.dlog("jump: nothing above the head for %.0f cm (head at %.0f)", height + 5, cam.Z)
            end
        end
    end
    return clear
end

function M.stop()
    st = nil
    park()
end

return M
