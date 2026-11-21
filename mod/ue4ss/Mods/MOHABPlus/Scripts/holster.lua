-- Head zone for holster grabs.
-- BP_VRPlayerCharacter:GetNearestHolsterSlot measures the hand's distance to every holster (indices 0-5: back,
-- shoulders, hips...; 6-7: the sleeves) and takes the nearest one if it is within SlotToDistanceSquaredLeewayMap
-- [index]. The back/shoulder holsters reach over the top of the head, so reaching for a hat or helmet grabbed a
-- weapon instead. While a hand is over the head (above eye level, within SIDE cm to the left/right of the head's axis
-- and within holster_head_zone cm in front/behind it) we set the leeway of holsters 0-5 to 0, so the hand grabs what it touches (the hat); beside the
-- head, at the shoulders, the holsters work as before. The sleeves (6-7) are handled by syringe.lua.
local U = require("util")
local C = require("config")

local M = {}

local INDICES = { 0, 1, 2, 3, 4, 5 }
local orig = {}            -- index -> original leeway (for the current pawn)
local origPawn = nil
local blocked = false

local SIDE = 14             -- cm from the head's axis to the side: beyond it the hand is at a shoulder, not on the head

local function handInZone(pawn, ctrl, headLoc, right, radius)
    if not U.valid(ctrl) then return false end
    local mc = U.get(ctrl, "MotionController")
    local ok, l = U.call(mc, "K2_GetComponentLocation")
    if not (ok and l) then return false end
    l = U.vec(l)
    if l.Z < headLoc.Z - 3 then return false end           -- below eye level: shoulders, chest...
    local dx, dy = l.X - headLoc.X, l.Y - headLoc.Y
    -- To the left or right of the head the hand is reaching for a shoulder holster, however high it is.
    if math.abs(dx * right.X + dy * right.Y) > SIDE then return false end
    return dx * dx + dy * dy <= radius * radius             -- over the head, within radius front/back
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
    U.dlog("holsters %s (hand over the head)", block and "blocked" or "restored")
end

function M.tick(pawn)
    local addr = pawn:GetAddress()
    if addr ~= origPawn then origPawn, orig, blocked = addr, {}, false end

    local radius = C.get("holster_head_zone")
    local want = false
    if type(radius) == "number" and radius > 0 then
        local cam = U.get(pawn, "VRReplicatedCamera")
        local okL, camLoc = U.call(cam, "K2_GetComponentLocation")
        local okF, fwd = U.call(cam, "GetForwardVector")
        local okR, right = U.call(cam, "GetRightVector")
        if okL and okF and okR and camLoc and fwd and right then
            right = U.vec(right)
            right.Z = 0
            right = U.vnorm(right)
            camLoc, fwd = U.vec(camLoc), U.vec(fwd)
            fwd.Z = 0
            fwd = U.vnorm(fwd)
            -- the head's vertical axis is a bit behind the eyes
            local head = { X = camLoc.X - fwd.X * 8, Y = camLoc.Y - fwd.Y * 8, Z = camLoc.Z }
            want = handInZone(pawn, U.get(pawn, "LeftController"), head, right, radius)
                or handInZone(pawn, U.get(pawn, "RightController"), head, right, radius)
        end
    end
    if want ~= blocked then setLeeway(pawn, want) end
end

return M
