-- Grab what you point at.
--
-- An empty hand shows a guide (DirectionalPointer, a thin line along the hand's GrabCapsule axis), but the game does not
-- choose by it. The object lit in blue (GrabSphereTraceObject, the one grip takes) is chosen by SelectGrabObject:
--   * only when something enters the capsule or the chosen one leaves it: moving the guide from one object to another
--     while both are inside changes nothing;
--   * by distance to the middle of the capsule (40-100 cm in front of the hand) or to the hand, whatever the guide
--     points at. The capsule is a 40 cm wide tube, so something far from the line often wins;
--   * from OverlappingGrabActors, which holds an actor once per overlapping component, but when ONE component leaves,
--     RemoveItem removes them all: an object still under the guide stops being a candidate.
--
-- Here we choose again among the objects the capsule really touches, by their angle to the guide's line (an object at
-- the hand itself comes first), and pass the choice to the game through its own HighlightGrabObject. Objects that fell
-- off the game's list are put back with its own BeginOverlapCheck. From how far things can be grabbed is unchanged, but what
-- is beside or behind the hand, away from the guide's direction, is not lit (a hand hanging down lit whatever was around).
--
-- While a hand is where it would take something from the chest (grenades, objects) or a sleeve, nothing loose is lit: the
-- game grabs the lit object first, and the thing on the body would not be taken.
--
-- Colours of the game: strong blue = what the weapon hand would take, light blue = the other hand, orange = important
-- things nearby, grey = other things nearby, red = can't be used.
--
-- Left to the game: parts of weapons and anything attached to the player or to what a hand holds (second grips, bolts,
-- magazines, pins, holstered things), climbing holds, and levers / sliders (components).
local U = require("util")
local C = require("config")

local BodyGrab = require("bodygrab")
local Row = require("grenaderow")

local M = {}

local PERIOD = 0.05            -- s between evaluations of each hand
local REACH = 220              -- cm: longest grab capsule (2 * 100 + its radius)
local POINTER_X = 34.3552      -- the guide starts this far in front of the capsule's start (UpdateGrabCapsule)
local HAND_X = 14              -- the hand itself, on the same line (GrabSphere)
local TOUCH = 5                -- cm from the hand: the object is at the hand
local KEEP = 0.015             -- another object must be this much (radians) better aimed to replace the chosen one
local MAX_AIM = 0.35           -- farther than this (about radians) from the guide is not lit; only matters close to the hand,
local MAX_AIM_LIT = 0.42       -- farther away the capsule is narrower than that. The lit one may drift a bit more.
local PORTABLE = 100           -- cm: bigger meshes (half size) are not limited, what the hand takes may be a part of them
local GRIP_FREEZE = 0.3        -- closing the hand tilts it: no changes while grip is being pressed
local MAX_COMPS = 6

local CHEST_AND_SLEEVES = { [1] = true, [4] = true, [7] = true, [8] = true }   -- EHolsterSlot

local hands = {}               -- "Left" / "Right" -> { next =, target = address, cleared = true: nothing lit, hand at the body, off = true: ..., nothing in the guide's direction }
local shapes = {}              -- actor address -> { name =, t =, comps = { { comp =, origin =, extent = } } }
local classes = {}
local warned = {}
local relistBroken = false     -- putting objects back in the game's list does not work: don't try any more

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    U.log("grab aim: " .. fmt, ...)
end

-- At most one line per second and hand.
local lastLog = {}
local function logSome(side, now, fmt, ...)
    if not U.debug and lastLog[side] and now - lastLog[side] < 1 and now >= lastLog[side] then return end
    lastLog[side] = now
    U.log("grab aim: " .. fmt, ...)
end

local function class(path)
    local c = classes[path]
    if not U.valid(c) then
        c = StaticFindObject(path)
        classes[path] = c
    end
    return U.valid(c) and c or nil
end

local function isA(o, path)
    local c = class(path)
    if not c then return false end
    local ok, r = pcall(function() return o:IsA(c) end)
    return ok and r == true
end

local PICKUP = "/Game/R6/Core/Placeables/BP_GenericPickupActor.BP_GenericPickupActor_C"

local function name(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and s or "?"
end

local function className(o)
    local ok, s = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and s or ""
end

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

-- A bool out parameter of a Blueprint function.
local function ask(o, fname, param, ...)
    local out = {}
    local args = { ... }
    args[#args + 1] = out
    local ok = U.call(o, fname, table.unpack(args))
    local v = out[param]
    if type(v) == "userdata" and v.get then v = v:get() end
    return ok and v == true
end

-- ---------------------------------------------------------------------------------------------
-- Geometry (pure Lua). A box is { loc =, ax = { x, y, z axes }, c = centre along the axes, e = half sizes }.
-- ---------------------------------------------------------------------------------------------
local function toBox(box, p)
    local d = U.vsub(p, box.loc)
    return { U.vdot(d, box.ax[1]) - box.c[1], U.vdot(d, box.ax[2]) - box.c[2], U.vdot(d, box.ax[3]) - box.c[3] }
end

local function boxDist(box, q)
    local s = 0
    for i = 1, 3 do
        local d = math.abs(q[i]) - box.e[i]
        if d > 0 then s = s + d * d end
    end
    return math.sqrt(s)
end

-- Distance from the segment o + t * dir (0 <= t <= len) to the box, and the t where it is.
function M.rayBox(box, o, dir, len)
    local q = toBox(box, o)
    local v = { U.vdot(dir, box.ax[1]), U.vdot(dir, box.ax[2]), U.vdot(dir, box.ax[3]) }
    local t0, t1 = 0, len
    for i = 1, 3 do
        if math.abs(v[i]) < 1e-6 then
            if math.abs(q[i]) > box.e[i] then t0, t1 = 1, 0 end
        else
            local a, b = (-box.e[i] - q[i]) / v[i], (box.e[i] - q[i]) / v[i]
            if a > b then a, b = b, a end
            if a > t0 then t0 = a end
            if b < t1 then t1 = b end
        end
    end
    if t0 <= t1 then return 0, t0 end
    local function at(t) return boxDist(box, { q[1] + v[1] * t, q[2] + v[2] * t, q[3] + v[3] * t }) end
    -- The distance to a box is convex along a line.
    local lo, hi = 0, len
    for _ = 1, 24 do
        local a, b = lo + (hi - lo) / 3, hi - (hi - lo) / 3
        if at(a) <= at(b) then hi = b else lo = a end
    end
    local t = (lo + hi) / 2
    return at(t), t
end

-- The lower the better: the angle to the guide, and the nearer / smaller one when the line goes through several.
-- Negative at the hand. The second result is the angle alone (0 at the hand or for things that are not limited).
function M.score(boxes, o, dir)
    local best, aim = nil, nil
    local hand = U.vadd(o, U.vmul(dir, HAND_X))
    for _, box in ipairs(boxes) do
        local near = boxDist(box, toBox(box, hand))
        local size = math.max(box.e[1], box.e[2], box.e[3])
        local s, a
        if near < TOUCH then
            s, a = -1 + near * 0.01, 0
        else
            local d, t = M.rayBox(box, o, dir, REACH)
            a = d / (t + 20)
            s = a + 0.0003 * t
        end
        s = s + 0.0002 * size
        if box.unknown or size > PORTABLE then a = 0 end
        if not best or s < best then best = s end
        if not aim or a < aim then aim = a end
    end
    return best, aim
end

-- ---------------------------------------------------------------------------------------------
-- Boxes of an actor: the local bounds of its visible meshes, oriented as they are in the world.
-- ---------------------------------------------------------------------------------------------
local function meshBounds(comp)
    local mesh = U.get(comp, "StaticMesh")
    if not U.valid(mesh) then mesh = U.get(comp, "SkeletalMesh") end
    if not U.valid(mesh) then return nil end
    for _, field in ipairs({ "ExtendedBounds", "ImportedBounds" }) do
        local ok, o, e = pcall(function()
            local b = mesh[field]
            return U.vec(b.Origin), U.vec(b.BoxExtent)
        end)
        if ok and type(e.X) == "number" and U.vlen(e) > 0.1 then return o, e end
    end
    return nil
end

local function shapeOf(actor, now)
    local addr = actor:GetAddress()
    local s = shapes[addr]
    local n = name(actor)
    if s and s.name == n and now - s.t < 5 and now >= s.t then return s end
    s = { name = n, t = now, comps = {} }
    local cls = class("/Script/Engine.MeshComponent")
    if cls then
        local ok, arr = U.call(actor, "K2_GetComponentsByClass", cls)
        for _, comp in ipairs(ok and items(arr) or {}) do
            local o, e = meshBounds(comp)
            if o then s.comps[#s.comps + 1] = { comp = comp, origin = o, extent = e, size = U.vlen(e) } end
        end
    end
    table.sort(s.comps, function(a, b) return a.size > b.size end)
    shapes[addr] = s
    return s
end

local function vecOf(o, fname)
    local ok, v = U.call(o, fname)
    if not ok or not v then return nil end
    local okV, t = pcall(U.vec, v)
    return okV and type(t.X) == "number" and t or nil
end

local function boxesOf(actor, now)
    local list = {}
    for _, c in ipairs(shapeOf(actor, now).comps) do
        if #list >= MAX_COMPS then break end
        local okV, vis = U.call(c.comp, "IsVisible")
        if okV and vis then
            local loc = vecOf(c.comp, "K2_GetComponentLocation")
            local x, y, z = vecOf(c.comp, "GetForwardVector"), vecOf(c.comp, "GetRightVector"), vecOf(c.comp, "GetUpVector")
            local sc = vecOf(c.comp, "K2_GetComponentScale")
            if loc and x and y and z and sc then
                list[#list + 1] = {
                    loc = loc, ax = { x, y, z },
                    c = { c.origin.X * sc.X, c.origin.Y * sc.Y, c.origin.Z * sc.Z },
                    e = { math.abs(c.extent.X * sc.X), math.abs(c.extent.Y * sc.Y), math.abs(c.extent.Z * sc.Z) },
                }
            end
        end
    end
    if #list == 0 then
        local loc = vecOf(actor, "K2_GetActorLocation")
        if loc then
            list[1] = {
                loc = loc, c = { 0, 0, 0 }, e = { 5, 5, 5 }, unknown = true,
                ax = { { X = 1, Y = 0, Z = 0 }, { X = 0, Y = 1, Z = 0 }, { X = 0, Y = 0, Z = 1 } },
            }
        end
    end
    return list
end

-- ---------------------------------------------------------------------------------------------
-- Candidates
-- ---------------------------------------------------------------------------------------------

-- A climbing hold: taken by distance, not by aiming.
local function isClimb(actor)
    return className(actor):find("Climbable", 1, true) ~= nil
end

-- Loose in the world: not a weapon part, nor attached to the player, a hand or something that can be picked up.
local function isLoose(actor, pawn)
    local okT, part = U.call(actor, "ActorHasTag", FName("WeaponComponent"))
    if not okT or part then return false end
    local a = actor
    for _ = 1, 6 do
        local ok, p = U.call(a, "GetAttachParentActor")
        if not ok then return false end
        if not U.valid(p) then return true end
        if U.same(p, pawn) or isA(p, PICKUP) or className(p):find("MotionController", 1, true) then return false end
        a = p
    end
    return false
end

-- Actors the hand's grab capsule touches right now (not the game's list, see above). nil if it can't be asked.
local function touching(hand)
    local cap, cls = U.get(hand, "GrabCapsule"), class("/Script/Engine.Actor")
    if not (U.valid(cap) and cls) then return nil end
    local out = {}
    local ok, err = U.call(cap, "GetOverlappingActors", out, cls)
    if not ok then
        warnOnce("overlap", "can't read what the hand touches (%s); using the game's list", tostring(err))
        return nil
    end
    local arr = out.OverlappingActors or out
    if type(arr) == "userdata" and arr.get and not arr.ForEach then
        local okG, a = pcall(function() return arr:get() end)
        if okG then arr = a end
    end
    return items(arr)
end

-- The guide's line.
local function line(hand)
    local p = U.get(hand, "DirectionalPointer")
    local loc, dir = vecOf(p, "K2_GetComponentLocation"), vecOf(p, "GetForwardVector")
    if not (loc and dir) then return nil end
    dir = U.vnorm(dir)
    return U.vsub(loc, U.vmul(dir, POINTER_X)), dir
end

local function has(list, o)
    for _, x in ipairs(list) do if U.same(x, o) then return true end end
    return false
end

local function canGrab(hand, actor) return ask(hand, "CanPlayerGrabObject", "Result", actor) end

-- A lever, slider... that the hand could take.
local function hasComponent(hand)
    for _, c in ipairs(items(U.get(hand, "OverlappingGrabComponents"))) do
        if canGrab(hand, c) then return true end
    end
    return false
end

local function evaluate(side, hand, other, st, pawn, now)
    local current = U.get(hand, "GrabSphereTraceObject")
    if U.valid(current) then
        -- A component (lever, slider...), a weapon part, something on the player or a climbing hold: the game's choice.
        if not isA(current, "/Script/Engine.Actor") or isClimb(current) or not isLoose(current, pawn) then return end
    end
    local o, dir = line(hand)
    if not o then return end

    local listed = items(U.get(hand, "OverlappingGrabActors"))
    local real = touching(hand)
    local seen, cands, otherKind = {}, {}, false
    for _, a in ipairs(real or listed) do
        local addr = a:GetAddress()
        if not seen[addr] then
            seen[addr] = true
            if canGrab(hand, a) then
                if isClimb(a) then return end
                if isLoose(a, pawn) then cands[#cands + 1] = a else otherKind = true end
            end
        end
    end
    if #cands == 0 then return end

    -- Put back what the game's list lost while it is still touched, so the game also drops it when it goes away.
    if real and not relistBroken then
        for _, a in ipairs(cands) do
            if not has(listed, a) then
                logSome(side, now, "%s hand: %s is touched but was off the game's list", side, name(a))
                U.call(hand, "BeginOverlapCheck", a, nil)
                if not has(items(U.get(hand, "OverlappingGrabActors")), a) then
                    relistBroken = true
                    warnOnce("relist", "can't put %s back in the game's list", name(a))
                    break
                end
            end
        end
        -- The game has just chosen again.
        current = U.get(hand, "GrabSphereTraceObject")
        if U.valid(current) and not (isA(current, "/Script/Engine.Actor") and isLoose(current, pawn)) then return end
    end
    -- Nothing chosen: the game is refusing for its own reasons, unless it was us.
    if U.valid(current) then st.off = nil elseif not st.off then return end

    local best, bestS, curS, curAim = nil, nil, nil, nil
    for _, a in ipairs(cands) do
        local s, aim = M.score(boxesOf(a, now), o, dir)
        if s then
            local isCurrent = U.same(a, current)
            if isCurrent then curS, curAim = s, aim end
            if aim <= (isCurrent and MAX_AIM_LIT or MAX_AIM) and (not bestS or s < bestS) then best, bestS = a, s end
        end
    end
    if not best then
        -- Nothing in the guide's direction. (Something else left to the game may be there: then it stays its choice.)
        if curAim and not otherKind and not hasComponent(hand) then
            logSome(side, now, "%s hand: %s not lit, %.2f away from the guide", side, name(current), curAim)
            U.call(hand, "HighlightGrabObject", nil)
            st.off = true
            if U.same(U.get(other, "GrabSphereTraceObject"), current) then U.call(other, "HighlightGrabObject", current) end
        end
        return
    end
    if U.same(best, current) then return end
    if curS and curAim <= MAX_AIM_LIT and bestS > curS - KEEP then return end
    st.off = nil

    logSome(side, now, "%s hand: %s (%.3f) instead of %s (%s), %d candidates", side, name(best), bestS,
        U.valid(current) and name(current) or "nothing",
        curS and string.format("%.3f", curS) or "not touched", #cands)
    U.call(hand, "HighlightGrabObject", best)
    -- Taking the highlight away from the old one also removed the other hand's, if it points at it too.
    local otherTarget = U.get(other, "GrabSphereTraceObject")
    if U.valid(current) and U.same(otherTarget, current) then U.call(other, "HighlightGrabObject", otherTarget) end
end

local function ready(hand)
    return U.valid(hand) and not U.valid(U.get(hand, "AttachedObject"))
        and U.get(hand, "GrabEnabledPreviousFrame") == true and U.get(hand, "GripStateAllowsGrab") == true
        and U.get(hand, "GrabbingDisabled") ~= true and U.get(hand, "EnablingGrabCapsule") ~= true
end

local function addressOf(o)
    return U.valid(o) and o:GetAddress() or 0
end

-- The hand would take something from the chest or a sleeve.
local function atBody(side, other)
    if Row.isAt(side) then return true end
    local slot = BodyGrab.zoneOf(side)
    if not slot or not CHEST_AND_SLEEVES[slot] then return false end
    local w = U.get(other, "AttachedObject")       -- its magazine pouch has a longer reach
    return not (U.valid(w) and U.get(w, "MagazineHolsterSlot") == slot)
end

-- Nothing loose is lit for this hand.
local function clear(side, hand, st, pawn, now)
    local current = U.get(hand, "GrabSphereTraceObject")
    if not U.valid(current) then return end
    if isA(current, "/Script/Engine.Actor") and (isClimb(current) or not isLoose(current, pawn)) then return end
    logSome(side, now, "%s hand at the body: %s not lit", side, name(current))
    U.call(hand, "HighlightGrabObject", nil)
    if U.valid(U.get(hand, "GrabSphereTraceObject")) then warnOnce("clear", "can't clear the lit object") end
    st.cleared = true
end

-- The hand left the body: the game chooses again (it would not do it by itself).
local function restore(hand, st)
    st.cleared = nil
    if U.valid(U.get(hand, "GrabSphereTraceObject")) then return end
    local out = {}
    U.call(hand, "SelectGrabObject", out)
    local o = out.GrabObject
    if type(o) == "userdata" and o.get and not o.GetAddress then o = o:get() end
    if U.valid(o) then U.call(hand, "HighlightGrabObject", o) end
    st.next = 0
end

function M.tick(pawn, now)
    if not C.get("grab_aim") then hands = {}; return end
    for _, side in ipairs({ "Left", "Right" }) do
        local hand = U.get(pawn, side .. "Controller")
        local st = hands[side]
        if not st then
            st = { next = side == "Left" and now or now + PERIOD / 2, target = 0 }   -- the hands take turns
            hands[side] = st
        end
        local other = U.get(pawn, side == "Left" and "RightController" or "LeftController")
        local free = ready(hand)
        local body = free and atBody(side, other)
        if not free then
            st.cleared, st.off = nil, nil       -- holding something: the game starts afresh when the hand is empty again
        elseif body then
            clear(side, hand, st, pawn, now)
        elseif st.cleared then
            restore(hand, st)
        end
        if free and not body and U.axis("OculusTouch_" .. side .. "_Grip_Axis") < GRIP_FREEZE then
            -- At once when the game changed its choice.
            local target = addressOf(U.get(hand, "GrabSphereTraceObject"))
            if target ~= st.target or now >= st.next or st.next > now + 1 then
                st.next = now + PERIOD
                local ok, err = pcall(evaluate, side, hand, other, st, pawn, now)
                if not ok then warnOnce("error", "%s", tostring(err)) end
                st.target = addressOf(U.get(hand, "GrabSphereTraceObject"))
            end
        end
    end
    -- Forget shapes not used lately.
    for addr, s in pairs(shapes) do
        if now - s.t > 10 or now < s.t then shapes[addr] = nil end
    end
end

function M.reset()
    hands, shapes, classes = {}, {}, {}
end

return M
