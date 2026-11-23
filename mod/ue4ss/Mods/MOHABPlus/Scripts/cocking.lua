-- Manual cocking: after a reload that leaves the chamber empty the game wants the bolt (rifles, SMGs) or the slide
-- (pistols) pulled. Meanwhile it disables the front grip (BP_Weapon_Rifle_MagazineLoaded:DisableGripGrabbing) and
-- makes the bolt / slide actor grabbable (DisablePickup = false, overlap events on). Cocking itself only happens
-- through the held bolt (BoltInHand + hand velocity -> PlayerPulledBolt) or slide, so when the free hand reaches for
-- the front grip it actually grabs the bolt's large grab collider and the weapon cocks "by itself".
--
-- With cocking = "manual", while the bolt / slide waits to be pulled it only stays grabbable when the free hand is at
-- its handle (within REACH_ON cm of the point the hand snaps to, and not clearly closer to the front grip). Farther
-- away its collision components get overlap events turned off, so the hand no longer picks it up from the grip. Every
-- change is undone as soon as the hand is at the handle, the weapon is cocked or put away, or the option is "auto".
--
-- Bolt-action rifles (BP_ScopedWeapon: Springfield, Kar98) cycle in 4 steps (BoltPosition 1 lift, 2 back, 3 forward,
-- 4 down). If the bolt is let go at step 2 or 3 the weapon's tick finishes the cycle by itself (AutoFinishReload_*),
-- unless AutoFinishingReload is already true, and BoltReleased turns the bolt handle off. In manual mode we keep
-- AutoFinishingReload true during steps 1-3 (it is only read by that branch) and, if the bolt was let go mid-cycle,
-- turn the handle back on so the player can finish it; grabbing again resumes from the same step.
local U = require("util")
local C = require("config")

local M = {}

-- cm from the hand to the point the hand snaps to on the bolt / slide (hysteresis: grabbable within REACH_ON, kept
-- grabbable up to REACH_OFF). The hand is measured at its mesh (GhostHandMesh follows the tracked controller even while
-- the visible hand is attached to something), the same reference as the game's HandAttach points. Measured from the
-- GrabSphere instead (first versions) the MP40 gave the same 13 / 13 cm to bolt and grip with the hand on either, so
-- grabs at the grip still cocked. On the pistol slide it is the other way round: with the hand on the slide the mesh
-- measured 16-22 cm and the GrabSphere 8-14 cm (front grip 25-45 cm away). So the bolt / slide is grabbable when
-- EITHER reference says the hand is within reach and nearer to it than to the front grip; at the MP40 grip both said
-- the grip was nearer (mesh 22-23 / 7-10 cm, sphere 18-33 / 2-9 cm).
local REACH_ON, REACH_OFF = 22, 28
local GRIP_MARGIN = 0     -- the bolt is grabbable only when the hand is nearer to it than to the front grip (+ margin)

local weaponClass, primClass = nil, nil
local gated = nil         -- { piece =, comps = { component, ... } } while the bolt / slide is kept out of reach
local grabTime = {}       -- piece address -> time of the last grab (diagnostics)
local gripWasDown = false

local function isA(obj, path, cache)
    if not U.valid(obj) then return false, cache end
    if not U.valid(cache) then
        cache = StaticFindObject(path)
        if not U.valid(cache) then return false, cache end
    end
    local ok, r = pcall(function() return obj:IsA(cache) end)
    return ok and r == true, cache
end

local function isWeapon(obj)
    local r
    r, weaponClass = isA(obj, "/Game/R6/Core/Weapons/BP_WeaponBase.BP_WeaponBase_C", weaponClass)
    return r
end

local function location(comp)
    local ok, v = U.call(comp, "K2_GetComponentLocation")
    if ok and v then return U.vec(v) end
    return nil
end

local function dist(a, b)
    if not (a and b) then return nil end
    return U.vlen(U.vsub(a, b))
end

local function sphereLocation(hand)
    return location(U.get(hand, "GrabSphere")) or location(U.get(hand, "GrabCapsule"))
end

local function handLocation(hand)
    return location(U.get(hand, "GhostHandMesh")) or location(U.get(hand, "HandMesh")) or sphereLocation(hand)
end

local function fmtd(d) return d and string.format("%.0f", d) or "?" end

-- The weapon's bolt or slide actor (nil for weapons without one: shotguns, lever action, bazookas...). Bolt-action
-- rifles (BP_ScopedWeapon) keep theirs in RifleBolt ("Bolt" there is the child actor component, skipped): when empty
-- the game also disables their front grip and turns the bolt handle on, so the second hand reaching for the grip took
-- the bolt and the cycle ran by itself.
local function pieceOf(weapon)
    for _, name in ipairs({ "Bolt", "Slide", "P08LugerSlide", "RifleBolt" }) do
        local p = U.get(weapon, name)
        if U.valid(p) and type(U.get(p, "DisablePickup")) == "boolean" then return p end
    end
    return nil
end

-- Where the hand snaps to when it takes the bolt / slide (= its handle).
local function handlePoint(piece, left)
    local names = left and { "HandAttachLeft", "SlideGrabHandAttachPointLeft", "HandAttachPoint" }
        or { "HandAttachRight", "SlideGrabHandAttachPointRight", "HandAttachPoint" }
    for _, n in ipairs(names) do
        local l = location(U.get(piece, n))
        if l then return l end
    end
    local ok, v = U.call(piece, "K2_GetActorLocation")
    return (ok and v) and U.vec(v) or nil
end

-- Where the hand snaps to on the front grip (rifles: child actor component; pistols: the grip actor).
local function gripPoint(weapon)
    local g = U.get(weapon, "Grip")
    local child = U.get(g, "ChildActor")
    if U.valid(child) then g = child end
    if not U.valid(g) then return nil end
    local l = location(U.get(g, "HandAttachPoint"))
    if l then return l end
    local ok, v = U.call(g, "K2_GetActorLocation")
    return (ok and v) and U.vec(v) or nil
end

local function components(actor)
    local list = {}
    if not U.valid(primClass) then primClass = StaticFindObject("/Script/Engine.PrimitiveComponent") end
    local ok, arr = U.call(actor, "K2_GetComponentsByClass", primClass)
    if not ok or not arr then return list end
    pcall(function()
        for i = 1, #arr do
            local c = arr[i]
            if type(c) == "userdata" and c.get and not c.GetAddress then c = c:get() end
            if U.valid(c) then list[#list + 1] = c end
        end
    end)
    return list
end

local function release(why)
    if not gated then return end
    local st = gated
    gated = nil
    for _, comp in ipairs(st.comps) do
        if U.valid(comp) then U.call(comp, "SetGenerateOverlapEvents", true) end
    end
    if U.valid(st.piece) then U.dlog("cocking: %s grabbable again (%s)", st.piece:GetFName():ToString(), why) end
end

-- Keeps the piece's components without overlap events. The game turns them back on when it re-enables bolt grabbing,
-- so this runs every frame.
local function hold(piece, d)
    if gated and not U.same(gated.piece, piece) then release("other weapon") end
    if not gated then
        gated = { piece = piece, comps = {}, known = {} }
        U.dlog("cocking: %s out of reach (%s cm)", piece:GetFName():ToString(), d and string.format("%.0f", d) or "?")
    end
    for _, comp in ipairs(components(piece)) do
        if U.get(comp, "bGenerateOverlapEvents") == true then
            U.call(comp, "SetGenerateOverlapEvents", false)
            local a = comp:GetAddress()
            if not gated.known[a] then
                gated.known[a] = true
                gated.comps[#gated.comps + 1] = comp
            end
        end
    end
end

-- Bolt-action rifles: no automatic finish of the bolt cycle (see the top of the file).
local touched = {}        -- weapon address -> weapon whose AutoFinishingReload we set

local function boltAction(weapon)
    local keep = nil
    local bolt = U.get(weapon, "RifleBolt")
    local pos = U.get(weapon, "BoltPosition")
    if U.valid(bolt) and type(pos) == "number" and pos >= 1 and pos <= 3 then
        keep = weapon:GetAddress()
        if U.get(weapon, "AutoFinishingReload") ~= true then
            pcall(function() weapon.AutoFinishingReload = true end)
            if not touched[keep] then
                U.dlog("cocking: %s bolt at step %d: no automatic finish", weapon:GetFName():ToString(), pos)
            end
        end
        touched[keep] = weapon
        -- Let go mid-cycle: the game turned the handle off and the grip on; give the bolt back to the player.
        if pos >= 2 and U.get(weapon, "GrabbingBolt") == false and U.get(bolt, "DisablePickup") == true then
            U.call(weapon, "TurnOnBoltHandle")
            U.call(weapon, "DisableGripGrabbing")
            U.log("cocking: %s bolt let go at step %d: handle on again", weapon:GetFName():ToString(), pos)
        end
    end
    for a, w in pairs(touched) do
        if a ~= keep then
            touched[a] = nil
            if U.valid(w) and U.get(w, "AutoFinishingReload") == true then
                pcall(function() w.AutoFinishingReload = false end)
            end
        end
    end
end

function M.tick(pawn)
    local manual = C.get("cocking") == "manual"
    local left, right = U.get(pawn, "LeftController"), U.get(pawn, "RightController")
    local weapon, free
    if U.valid(left) and U.valid(right) then
        local lo, ro = U.get(left, "AttachedObject"), U.get(right, "AttachedObject")
        if isWeapon(ro) then weapon, free = ro, left
        elseif isWeapon(lo) then weapon, free = lo, right end
    end
    boltAction(manual and weapon or nil)
    if not manual then return release("option auto") end
    if not weapon then return release("no weapon") end

    local piece = pieceOf(weapon)
    -- DisablePickup false = the game waits for the bolt / slide to be pulled.
    if not piece or U.get(piece, "DisablePickup") ~= false then return release("cocked") end
    if U.get(piece, "IsGripped") == true or U.get(weapon, "GrabbingBolt") == true
        or U.same(U.get(free, "AttachedObject"), piece) then return release("in hand") end

    local hp, gp = handlePoint(piece, U.same(free, left)), gripPoint(weapon)
    local hand, sphere = handLocation(free), sphereLocation(free)
    local dBolt, dGrip = dist(hand, hp), dist(hand, gp)
    local sBolt, sGrip = dist(sphere, hp), dist(sphere, gp)
    local reach = (gated and U.same(gated.piece, piece)) and REACH_ON or REACH_OFF
    local function near(b, g) return b and b <= reach and (not g or b < g + GRIP_MARGIN) end
    if near(dBolt, dGrip) or near(sBolt, sGrip) then return release("hand at handle") end
    hold(piece, dBolt)

    -- Diagnostics: grip pressed while the bolt / slide is kept out of reach.
    local down = U.axis("OculusTouch_" .. (U.same(free, left) and "Left" or "Right") .. "_Grip_Axis") > 0.6
    if down and not gripWasDown then
        U.log("cocking: grab blocked: hand %s cm from the %s handle (needs %d), %s cm from the front grip"
            .. " | grab sphere %s / %s cm",
            fmtd(dBolt), piece:GetFName():ToString(), reach, fmtd(dGrip), fmtd(sBolt), fmtd(sGrip))
    end
    gripWasDown = down
end

function M.reset()
    release("reset")
    boltAction(nil)
end

-- Diagnostics (always logged, a couple of lines per reload): where the hand was when the bolt / slide was taken,
-- and the hand speed when the game counted it as pulled.
function M.onPieceGrab(piece, hand)
    if not U.valid(piece) then return end
    grabTime[piece:GetAddress()] = os.clock()
    local ok, weapon = U.call(piece, "GetParentActor")
    if not (ok and U.valid(weapon)) then ok, weapon = U.call(piece, "GetAttachParentActor") end
    if not (ok and U.valid(weapon)) then weapon = nil end
    local isLeft = false
    if U.valid(hand) then
        local out = {}
        local okR = U.call(hand, "IsRightHand", out)
        if okR and type(out.Result) == "boolean" then isLeft = not out.Result end
    end
    local h, s = handLocation(hand), sphereLocation(hand)
    local hp, gp = handlePoint(piece, isLeft), weapon and gripPoint(weapon)
    U.log("cocking: %s grabbed (%s): hand %s cm from the handle, %s cm from the front grip | grab sphere %s / %s cm,"
        .. " mode=%s, mod %s",
        piece:GetFName():ToString(), weapon and weapon:GetFName():ToString() or "?",
        fmtd(dist(h, hp)), fmtd(dist(h, gp)), fmtd(dist(s, hp)), fmtd(dist(s, gp)),
        tostring(C.get("cocking")), C.enabled and "on" or "off")
end

function M.onBoltPulled(weapon)
    if not U.valid(weapon) then return end
    local piece = pieceOf(weapon)
    -- The game calls this every frame while the bolt is held back: log it once per grab.
    local t = piece and grabTime[piece:GetAddress()]
    if not t then return end
    grabTime[piece:GetAddress()] = nil
    U.log("cocking: %s cocked: hand speed %s cm/s (game needs %s), %s s after the grab",
        weapon:GetFName():ToString(),
        string.format("%.0f", U.get(weapon, "PlayerHandBoltRelativeVelocity") or -1),
        string.format("%.0f", U.get(weapon, "HandVelocityBoltThreshold") or -1),
        string.format("%.2f", os.clock() - t))
end

return M
