-- Holster grabs only below the eyes.
-- BP_VRPlayerCharacter:GetNearestHolsterSlot measures the hand's distance to every holster (indices 0-5: back,
-- shoulders, hips...; 6-7: the sleeves) and takes the nearest one if it is within SlotToDistanceSquaredLeewayMap
-- [index]. The back/shoulder holsters reach over the top of the head, so reaching for a hat or helmet grabbed a
-- weapon instead. Taking a weapon from the back or a shoulder is done with the hand behind the shoulder, below the
-- eyes; so while a hand is above eye level we set the leeway of holsters 0-5 to 0 and it grabs what it touches (the
-- hat). The sleeves (6-7) are handled by syringe.lua.
--
-- Eye level is taken with the head upright, from a neck pivot (below and behind the eyes): nodding the head down to
-- reach a shoulder holster moves the eyes forward and down, but the neck pivot barely moves, so the limit stays put.
local U = require("util")
local C = require("config")

local M = {}

local INDICES = { 0, 1, 2, 3, 4, 5 }
local orig = {}            -- index -> original leeway (for the current pawn)
local origPawn = nil
local blocked = false

local NECK_BACK, NECK_DOWN = 9, 12   -- cm from the eyes to the neck pivot, along the head's own forward / up axes

-- Neck pivot and the head's horizontal frame (yaw only).
local function headFrame(pawn)
    local cam = U.get(pawn, "VRReplicatedCamera")
    local okL, camLoc = U.call(cam, "K2_GetComponentLocation")
    local okF, fwd = U.call(cam, "GetForwardVector")
    local okU, up = U.call(cam, "GetUpVector")
    local okR, right = U.call(cam, "GetRightVector")
    if not (okL and okF and okU and okR and camLoc and fwd and up and right) then return nil end
    camLoc, fwd, up, right = U.vec(camLoc), U.vec(fwd), U.vec(up), U.vec(right)
    local neck = {
        X = camLoc.X - fwd.X * NECK_BACK - up.X * NECK_DOWN,
        Y = camLoc.Y - fwd.Y * NECK_BACK - up.Y * NECK_DOWN,
        Z = camLoc.Z - fwd.Z * NECK_BACK - up.Z * NECK_DOWN,
    }
    local hr = U.vnorm({ X = right.X, Y = right.Y, Z = 0 })
    local hf = U.vnorm({ X = fwd.X, Y = fwd.Y, Z = 0 })
    if hf.X == 0 and hf.Y == 0 then hf = { X = -hr.Y, Y = hr.X, Z = 0 } end   -- looking straight down
    return {
        cam = camLoc, neck = neck, fwd = hf, right = hr,
        eyeZ = neck.Z + NECK_DOWN,                          -- eye height with the head upright
        pitch = math.deg(math.asin(U.clamp(fwd.Z, -1, 1))),
    }
end

local function handLoc(ctrl)
    if not U.valid(ctrl) then return nil end
    local ok, l = U.call(U.get(ctrl, "MotionController"), "K2_GetComponentLocation")
    return (ok and l) and U.vec(l) or nil
end

local function handAboveEyes(ctrl, f)
    local l = handLoc(ctrl)
    return l ~= nil and l.Z > f.eyeZ
end

local function setLeeway(pawn, block)
    local map = U.get(pawn, "SlotToDistanceSquaredLeewayMap")
    if not map then return end
    for _, i in ipairs(INDICES) do
        pcall(function()
            if not map:Contains(i) then return end
            if orig[i] == nil then orig[i] = map:Find(i):get() end
            map:Add(i, block and 0 or orig[i])
        end)
    end
    blocked = block
    U.dlog("holsters %s (hand above the eyes)", block and "blocked" or "restored")
end

-- Diagnostics (debug_log only): when a hand with nothing in it presses grip near the shoulders/head, log where the game's holster
-- points are relative to the neck pivot (forward / right / up, cm, head yaw frame), the head pitch, the hand, and the
-- distances the game measured. Shows whether the holsters move with the head when nodding.
local gripWas = { Left = false, Right = false }
-- GetNearestHolsterSlot's distance array index -> holster slot enum it measures (indices 2 and 3 use named sockets)
local SLOT_OF_INDEX = { [0] = 3, [1] = 0, [4] = 4, [5] = 1 }

local function rel(f, p)
    local d = U.vsub(p, f.neck)
    return string.format("(%.0f,%.0f,%.0f)", U.vdot(d, f.fwd), U.vdot(d, f.right), d.Z)
end

local function logGrip(pawn, side, ctrl, f)
    local l = handLoc(ctrl)
    if not l or l.Z < f.neck.Z - 30 or U.valid(U.get(ctrl, "AttachedObject")) then return end
    local slots = {}
    for idx = 0, 5 do
        local slot = SLOT_OF_INDEX[idx]
        if slot then
            local out = {}
            local ok = U.call(pawn, "GetHolsterLocationBySlot", slot, out)
            if ok and out.Pos then slots[#slots + 1] = string.format("i%d=%s", idx, rel(f, U.vec(out.Pos))) end
        end
    end
    local dists = {}
    pcall(function()
        local arr = pawn.HolsterDistanceSquaredFromHand
        for i = 1, #arr do
            local v = arr[i]
            if type(v) ~= "number" and v and v.get then v = v:get() end
            dists[#dists + 1] = type(v) == "number" and string.format("%.0f", math.sqrt(math.max(v, 0))) or "?"
        end
    end)
    local lee = {}
    pcall(function()
        local map = pawn.SlotToDistanceSquaredLeewayMap
        for i = 0, 5 do
            if map:Contains(i) then lee[#lee + 1] = string.format("%.0f", math.sqrt(math.max(map:Find(i):get(), 0))) end
        end
    end)
    U.dlog("holster diag: %s grip, pitch %.0f, eyes %s, hand %s, above eyes %s | holsters %s | distances cm [%s] | leeway cm [%s]",
        side, f.pitch, rel(f, f.cam), rel(f, l), blocked and "BLOCKING" or "off", table.concat(slots, " "),
        table.concat(dists, ","), table.concat(lee, ","))
end

function M.tick(pawn)
    local addr = pawn:GetAddress()
    if addr ~= origPawn then origPawn, orig, blocked = addr, {}, false end

    local f = headFrame(pawn)
    local want = false
    if f and C.get("holster_below_eyes") then
        want = handAboveEyes(U.get(pawn, "LeftController"), f) or handAboveEyes(U.get(pawn, "RightController"), f)
    end
    if want ~= blocked then setLeeway(pawn, want) end

    if f then
        for _, side in ipairs({ "Left", "Right" }) do
            local down = U.axis("OculusTouch_" .. side .. "_Grip_Axis") > 0.6
            if down and not gripWas[side] then pcall(logGrip, pawn, side, U.get(pawn, side .. "Controller"), f) end
            gripWas[side] = down
        end
    end
end

return M
