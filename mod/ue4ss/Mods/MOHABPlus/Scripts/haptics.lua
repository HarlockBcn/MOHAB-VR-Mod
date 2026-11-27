-- Haptic feedback when the player takes damage.
-- Polls the player's health component and vibrates both controllers when health drops.
-- If the damage causer is known (HandleDamageLocationIndicator hook) the controller on the hit side vibrates harder.
--
-- How long a vibration lasts (tested in the headset, 2026-11-27, devtools "haptictest"): one SetHapticsByValue is felt
-- as a short tap whatever the duration asked, and sending the same value again does not make it longer (it is
-- ignored); a value that changes every tick is felt as one continuous vibration. So every vibration longer than a tap
-- is kept going by alternating its strength with a slightly weaker one (HOLD_DIP) every tick until it ends.
local U = require("util")
local C = require("config")

local M = {}

local HAND_LEFT, HAND_RIGHT = 0, 1   -- EControllerHand

local lastHealth = nil
local lastHealthComp = nil
local stopAt = { [HAND_LEFT] = nil, [HAND_RIGHT] = nil }
local lastCauserLoc = nil
local lastCauserTime = -100

local HOLD_DIP = 0.75                -- every other tick a held vibration runs at this fraction of its strength
local held = {}                      -- hand -> { amp, n } vibrations being kept going until stopAt[hand]

local function setHaptics(pc, hand, freq, amp)
    U.call(pc, "SetHapticsByValue", freq, amp, hand)
end

-- Starts a vibration on one hand for `duration` seconds (kept going by M.tick).
local function start(pc, hand, amp, duration, now)
    amp = U.clamp(amp, 0, 1)
    if amp <= 0 then return end
    setHaptics(pc, hand, 1.0, amp)
    stopAt[hand] = now + duration
    held[hand] = { amp = amp, n = 0, t0 = now }
end

function M.pulse(pc, now, leftAmp, rightAmp, duration)
    if leftAmp > 0 then start(pc, HAND_LEFT, leftAmp, duration, now) end
    if rightAmp > 0 then start(pc, HAND_RIGHT, rightAmp, duration, now) end
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

-- Queued pulse patterns: { t =, hand =, amp =, dur = } started when their time comes (see M.tick).
local queue = {}

-- "No ammo left": two taps on one hand (EControllerHand: 0 left, 1 right).
function M.noAmmoBuzz(now, hand)
    if not C.get("haptics_no_ammo") then return end
    local k = U.clamp(C.get("haptics_intensity"), 0, 1)
    queue[#queue + 1] = { t = now, hand = hand, amp = 0.7 * k, dur = 0.05 }
    queue[#queue + 1] = { t = now + 0.18, hand = hand, amp = 0.7 * k, dur = 0.05 }
end

-- A hand with nothing in it entered the grab zone of something you carry: one light tap.
function M.zoneTap(now, hand)
    local k = U.clamp(C.get("haptics_intensity"), 0, 1)
    queue[#queue + 1] = { t = now, hand = hand, amp = 0.3 * k, dur = 0.04 }
end

function M.tick(pawn, pc, now)
    -- Start queued pulses
    for i = #queue, 1, -1 do
        local q = queue[i]
        if now >= q.t then
            table.remove(queue, i)
            start(pc, q.hand, q.amp, q.dur, now)
        end
    end
    -- Stop finished vibrations, keep the others going
    for hand, t in pairs(stopAt) do
        if t and now >= t then
            setHaptics(pc, hand, 0, 0)
            stopAt[hand] = nil
            held[hand] = nil
        elseif held[hand] then
            local h = held[hand]
            if now > h.t0 then          -- not in the tick it started
                h.n = h.n + 1
                setHaptics(pc, hand, 1.0, h.n % 2 == 1 and h.amp * HOLD_DIP or h.amp)
            end
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

-- Weapon handling feedback (the game has none for reloading).
-- kind: "load" (magazine / shell / clip / rocket inserted), "open" / "close" (break-action barrels).
-- Amplitudes are for { hand holding the weapon, other hand } and the pulse duration in seconds.
local WEAPON_FX = {
    load  = { 0.45, 0.8, 0.09 },
    open  = { 0.55, 0.0, 0.07 },
    close = { 0.8, 0.0, 0.1 },
}

function M.onWeaponEvent(weapon, kind)
    if not C.get("haptics_weapons") or not U.valid(weapon) then return end
    local pc = U.pc
    local pawn = U.get(pc, "SpawnedPlayerCharacter")
    if not U.valid(pawn) then return end
    -- Only weapons in the player's hands (AI soldiers reload through the same functions).
    local left, right = U.get(pawn, "LeftController"), U.get(pawn, "RightController")
    local inLeft = U.valid(left) and U.same(U.get(left, "AttachedObject"), weapon)
    local inRight = U.valid(right) and U.same(U.get(right, "AttachedObject"), weapon)
    if not (inLeft or inRight) then return end
    local fx = WEAPON_FX[kind]
    if not fx then return end
    local k = U.clamp(C.get("haptics_intensity"), 0, 1)
    local held, other = fx[1] * k, fx[2] * k
    local l, r
    if inRight then l, r = other, held else l, r = held, other end
    U.dlog("weapon %s %s -> haptics L=%.2f R=%.2f", weapon:GetFName():ToString(), kind, l, r)
    M.pulse(pc, U.now(pawn), l, r, fx[3])
end

function M.reset(pc)
    lastHealth, lastHealthComp = nil, nil
    if U.valid(pc) then
        setHaptics(pc, HAND_LEFT, 0, 0)
        setHaptics(pc, HAND_RIGHT, 0, 0)
    end
    stopAt = { [HAND_LEFT] = nil, [HAND_RIGHT] = nil }
    queue = {}
    held = {}
end

return M
