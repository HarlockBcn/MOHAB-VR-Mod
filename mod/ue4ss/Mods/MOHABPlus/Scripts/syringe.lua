-- Health syringes:
--  * require holding the trigger of the hand that holds the syringe to inject it.
--    BP_HealthSyringe injects when its "Box" component begins overlapping the player's chest. The BP enables
--    Box overlap events 0.05 s after the grab (SyringeOverlapOn). We keep them disabled until the trigger is held.
--  * draw syringes smaller while they sit on the sleeve, full size when grabbed.
--
--    Grabbing a syringe (BP_MotionController:AttachObjectToHand, grab behaviour "attach") reads the actor's relative
--    scale, attaches the syringe with it and then attaches the hand mesh to the syringe. The scale must therefore be
--    back to 1 *before* that: we pre-hook AActor:GetActorRelativeScale3D (native) for syringes. Changing the scale
--    of a syringe that already has the hand attached would scale the hand too, so a gripped syringe is never rescaled.
local U = require("util")
local C = require("config")

local M = {}

local SYRINGE_CLASS = "BP_HealthSyringe_C"
local tracked = {}      -- address -> { actor=, overlap=, latchUntil=, wasPressed= }
local lastScan = -1
local scanList = {}

local function isSyringe(obj)
    local ok, cls = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and cls == SYRINGE_CLASS
end

local function state(syr)
    local addr = syr:GetAddress()
    local st = tracked[addr]
    if not st then
        st = { actor = syr }
        tracked[addr] = st
    end
    return st
end

local function handOf(pawn, syr)
    local gc = U.get(syr, "GrippingController")
    if not U.valid(gc) then return nil end
    if U.same(gc, U.get(pawn, "RightController")) then return "Right" end
    if U.same(gc, U.get(pawn, "LeftController")) then return "Left" end
    local ok, right = pcall(function() return gc.Hand end)       -- EControllerHand on BP_MotionController
    if ok and type(right) == "number" then return right == 1 and "Right" or "Left" end
    return nil
end

local function setOverlap(st, syr, on)
    if st.overlap == on then return end
    local box = U.get(syr, "Box")
    if U.valid(box) then
        U.call(box, "SetGenerateOverlapEvents", on)
        st.overlap = on
        if on then
            -- Enabling overlap events does not re-test overlaps until the box moves: nudge it so an
            -- already-touching chest generates the BeginOverlap right away.
            U.call(box, "K2_AddRelativeLocation", { X = 0, Y = 0, Z = 0.05 }, false, {}, false)
            U.call(box, "K2_AddRelativeLocation", { X = 0, Y = 0, Z = -0.05 }, false, {}, false)
        end
    end
end

local function currentScale(syr)
    local ok, s = U.call(syr, "GetActorScale3D")
    if ok and s then return s.X end
    return nil
end

local function setScale(syr, s)
    local cur = currentScale(syr)
    if cur and math.abs(cur - s) < 0.001 then return end
    U.call(syr, "SetActorScale3D", { X = s, Y = s, Z = s })
end

-- Is the syringe stored on the player (attached, directly or indirectly, to the sleeves / hands / pawn)?
local function isOnPlayer(syr, pawn)
    local owners = {}
    for _, k in ipairs({ "PlayerLeftCuff", "PlayerRightCuff", "LeftController", "RightController" }) do
        local o = U.get(pawn, k)
        if U.valid(o) then owners[#owners + 1] = o end
    end
    owners[#owners + 1] = pawn
    local cur = syr
    for _ = 1, 4 do
        local ok, parent = U.call(cur, "GetAttachParentActor")
        if not ok or not U.valid(parent) then return false end
        for _, o in ipairs(owners) do
            if U.same(parent, o) then return true end
        end
        cur = parent
    end
    return false
end

-- Post-hook of SyringeOverlapOn (the BP just enabled the overlap box).
function M.onOverlapOn(syr)
    if not C.get("syringe_require_trigger") then return end
    local st = state(syr)
    st.overlap = nil
    setOverlap(st, syr, false)     -- the tick re-enables it while the trigger is held
end

-- Pre-hook of native functions that read/consume the syringe scale right before it is grabbed.
function M.onBeforeGrab(obj)
    if not U.valid(obj) or not isSyringe(obj) then return end
    if U.get(obj, "IsGripped") == true then return end
    local cur = currentScale(obj)
    if cur and math.abs(cur - 1) > 0.001 then
        U.call(obj, "SetActorScale3D", { X = 1, Y = 1, Z = 1 })
    end
end

function M.tick(pawn, now)
    if now - lastScan > 0.5 or now < lastScan then
        lastScan = now
        scanList = FindAllOf(SYRINGE_CLASS) or {}
    end
    local requireTrigger = C.get("syringe_require_trigger")
    local thr = C.get("syringe_trigger_threshold")
    local small = C.get("syringe_small_holstered")
    local hscale = U.clamp(C.get("syringe_holster_scale"), 0.1, 1.0)

    for _, syr in ipairs(scanList) do
        if U.valid(syr) then
            local st = state(syr)
            local gripped = U.get(syr, "IsGripped") == true
            local used = U.get(syr, "Used") == true
            local stuck = U.get(syr, "StuckInPlayer") == true

            -- Trigger requirement
            if gripped and not used then
                if requireTrigger then
                    local hand = handOf(pawn, syr)
                    local value = hand and U.trigger(hand) or math.max(U.trigger("Left"), U.trigger("Right"))
                    local pressed = value >= thr
                    -- Keep the box enabled a little after releasing so a quick squeeze is enough
                    -- (the BP checks the overlap again 3 frames after it begins).
                    if pressed then st.latchUntil = now + 0.4 end
                    setOverlap(st, syr, pressed or (st.latchUntil ~= nil and now < st.latchUntil))
                elseif st.overlap == false then
                    setOverlap(st, syr, true)   -- feature switched off: give control back to the game
                end
            else
                st.latchUntil = nil
            end

            -- Sleeve scale (never touch a gripped syringe: the hand is attached to it)
            if not gripped then
                if small and not used and not stuck and isOnPlayer(syr, pawn) then
                    setScale(syr, hscale)
                else
                    setScale(syr, 1.0)
                end
            end
        end
    end

    for addr, st in pairs(tracked) do
        if not U.valid(st.actor) then tracked[addr] = nil end
    end
end

function M.debugInfo(pawn)
    local out = {}
    for _, syr in ipairs(FindAllOf(SYRINGE_CLASS) or {}) do
        if U.valid(syr) then
            local box = U.get(syr, "Box")
            local ok, parent = U.call(syr, "GetAttachParentActor")
            out[#out + 1] = string.format("  syringe gripped=%s used=%s onPlayer=%s scale=%s boxOverlap=%s parent=%s",
                tostring(U.get(syr, "IsGripped")), tostring(U.get(syr, "Used")), tostring(isOnPlayer(syr, pawn)),
                tostring(currentScale(syr)), tostring(U.get(box, "bGenerateOverlapEvents")),
                (ok and U.valid(parent)) and parent:GetFName():ToString() or "none")
        end
    end
    return out
end

function M.reset()
    tracked = {}
    scanList = {}
    lastScan = -1
end

return M
