-- Haptic feedback when the player takes damage.
-- Polls the player's health component and vibrates both controllers when health drops.
-- If the damage causer is known (HandleDamageLocationIndicator hook) the controller on the hit side vibrates harder.
local U = require("util")
local C = require("config")

local M = {}

local HAND_LEFT, HAND_RIGHT = 0, 1   -- EControllerHand

local lastHealth = nil
local lastHealthComp = nil
local stopAt = { [HAND_LEFT] = nil, [HAND_RIGHT] = nil }
local lastCauserLoc = nil
local lastCauserTime = -100

local function setHaptics(pc, hand, freq, amp)
    U.call(pc, "SetHapticsByValue", freq, amp, hand)
end

function M.pulse(pc, now, leftAmp, rightAmp, duration)
    if leftAmp > 0 then
        setHaptics(pc, HAND_LEFT, 1.0, U.clamp(leftAmp, 0, 1))
        stopAt[HAND_LEFT] = now + duration
    end
    if rightAmp > 0 then
        setHaptics(pc, HAND_RIGHT, 1.0, U.clamp(rightAmp, 0, 1))
        stopAt[HAND_RIGHT] = now + duration
    end
end

-- Post-hook of BP_VRPlayerCharacter_C:HandleDamageLocationIndicator(DamageCauser)
function M.onDamageCauser(causer, now)
    if U.valid(causer) then
        local ok, loc = U.call(causer, "K2_GetActorLocation")
        if ok and loc then
            lastCauserLoc = U.vec(loc)
            lastCauserTime = now
        end
    end
end

function M.tick(pawn, pc, now)
    -- Stop finished pulses
    for hand, t in pairs(stopAt) do
        if t and now >= t then
            setHaptics(pc, hand, 0, 0)
            stopAt[hand] = nil
        end
    end

    local hc = U.get(pawn, "VRPlayerCharacterHealthAndDamageComponent")
    if not U.valid(hc) then return end
    local health = U.get(hc, "Health")
    if type(health) ~= "number" then return end
    if not U.same(hc, lastHealthComp) then
        lastHealthComp = hc
        lastHealth = health
        return
    end
    local prev = lastHealth
    lastHealth = health
    if not C.get("haptics_damage") or not prev or health >= prev - 0.01 then return end

    local maxH = U.get(hc, "MaxHealth")
    if type(maxH) ~= "number" or maxH <= 0 then maxH = 400 end
    local frac = (prev - health) / maxH               -- 0..1 of max health lost in this hit
    local intensity = U.clamp(C.get("haptics_intensity"), 0, 1)
    local amp = U.clamp(0.55 + frac * 2.0, 0.55, 1.0) * intensity
    local dur = U.clamp(C.get("haptics_duration"), 0.05, 1.5) * U.clamp(0.8 + frac * 2.0, 0.8, 2.0)

    local left, right = amp, amp
    if C.get("haptics_directional") and lastCauserLoc and now - lastCauserTime < 0.5 then
        local cam = U.get(pawn, "VRReplicatedCamera")
        local okL, camLoc = U.call(cam, "K2_GetComponentLocation")
        local okR, camRight = U.call(cam, "GetRightVector")
        if okL and okR and camLoc and camRight then
            local dir = U.vnorm(U.vsub(lastCauserLoc, U.vec(camLoc)))
            local side = U.vdot(dir, U.vec(camRight))      -- +1 = right, -1 = left
            if side > 0.25 then left = amp * 0.45 elseif side < -0.25 then right = amp * 0.45 end
        end
    end
    U.dlog("damage %.1f -> haptics L=%.2f R=%.2f dur=%.2f", prev - health, left, right, dur)
    M.pulse(pc, now, left, right, dur)
end

function M.reset(pc)
    lastHealth, lastHealthComp = nil, nil
    if U.valid(pc) then
        setHaptics(pc, HAND_LEFT, 0, 0)
        setHaptics(pc, HAND_RIGHT, 0, 0)
    end
    stopAt = { [HAND_LEFT] = nil, [HAND_RIGHT] = nil }
end

return M
