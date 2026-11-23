-- Configurable fall damage.
--
-- The game's Comp_FallDamage (a component of the player pawn) ignores how far you fall: on landing it takes the
-- vertical speed of the last frame before touching the ground; at NonFatalFallVelocity or more (800 cm/s, a drop of
-- about 3.3 m) it removes a FIXED NonFatalDamage however hard the landing was, at FatalFallVelocity or more
-- (1400 cm/s, about 10 m) it kills. Horizontal speed does not count.
--
-- This module turns the heights chosen in the menu into those speeds (v = sqrt(2 * g * h)) and, optionally, makes the
-- damage grow with the height of the fall instead of being one flat amount. NonFatalDamage is rewritten every frame
-- from the component's own LastVelocity (the value ApplyFallDamage will use) and once more right before the damage is
-- applied (post-hook of StopFalling, which the component calls just before ApplyFallDamage).
-- With the option or the whole mod off the game's values are put back.
local U = require("util")
local C = require("config")

local M = {}

local comp = nil         -- the pawn's Comp_FallDamage we work on
local vanilla = nil      -- its original values { safe, fatal, damage } (cm/s, cm/s, health points)
local applied = nil      -- thresholds we wrote { safe, fatal, sig }
local grav = 980
-- Original values per component (address + full name), so finding the same pawn again after a reset never mistakes
-- our own values for the game's.
local originals = {}

local function gravity(pawn)
    local ok, g = U.call(U.get(pawn, "CharacterMovement"), "GetGravityZ")
    if ok and type(g) == "number" and g < 0 then return -g end
    return 980
end

local function speedFor(meters) return math.sqrt(2 * grav * meters * 100) end
local function heightFor(speed) return speed * speed / (2 * grav) / 100 end

local function restore()
    if applied and vanilla and U.valid(comp) then
        pcall(function()
            comp.NonFatalFallVelocity = vanilla.safe
            comp.FatalFallVelocity = vanilla.fatal
            comp.NonFatalDamage = vanilla.damage
        end)
        U.log("fall damage: game rules restored")
    end
    applied = nil
end

-- Finds the pawn's component and remembers its original values the first time.
local function capture(pawn)
    local c = U.get(pawn, "Comp_FallDamage")
    if not U.valid(c) then return nil end
    if comp and vanilla and U.same(c, comp) then return c end
    comp, vanilla, applied = nil, nil, nil
    local okId, id = pcall(function() return tostring(c:GetAddress()) .. c:GetFullName() end)
    if not okId then return nil end
    grav = gravity(pawn)
    if originals[id] then
        comp, vanilla = c, originals[id]
        applied = { sig = "" }   -- force our thresholds to be written again
        return c
    end
    local s, f, d = U.get(c, "NonFatalFallVelocity"), U.get(c, "FatalFallVelocity"), U.get(c, "NonFatalDamage")
    if type(s) ~= "number" or type(f) ~= "number" or type(d) ~= "number" then return nil end
    comp, vanilla = c, { safe = s, fatal = f, damage = d }
    originals[id] = vanilla
    U.log("fall damage (game): %.1f damage from %.0f cm/s (%.1f m drop), fatal from %.0f cm/s (%.1f m), gravity %.0f, enabled %s",
        d, s, heightFor(s), f, heightFor(f), grav, tostring(U.get(c, "EnableFallDamage")))
    return c
end

-- Damage for a landing at `down` cm/s (only used between the two thresholds).
local function damageFor(down)
    local base = vanilla.damage * U.clamp(C.get("fall_damage_scale") or 1, 0, 3)
    if not C.get("fall_damage_progressive") then return base end
    -- From 10 % just above the safe height up to 100 % just below the fatal one.
    local t = U.clamp((down - applied.safe) / math.max(applied.fatal - applied.safe, 1), 0, 1)
    return base * (0.1 + 0.9 * t)
end

local function lastDown(c)
    local v = U.get(c, "LastVelocity")
    local z = v and v.Z
    if type(z) ~= "number" or z >= 0 then return 0 end
    return -z
end

local function setDamage(c, down)
    local dmg = damageFor(down)
    local cur = U.get(c, "NonFatalDamage")
    if type(cur) ~= "number" or math.abs(cur - dmg) > 0.001 then
        pcall(function() c.NonFatalDamage = dmg end)
    end
    return dmg
end

function M.tick(pawn)
    local c = capture(pawn)
    if not c then return end
    if not C.get("fall_damage_custom") then
        if applied then restore() end
        return
    end
    local safeH = U.clamp(C.get("fall_safe_height") or 4, 0.5, 30)
    local fatalH = math.max(U.clamp(C.get("fall_fatal_height") or 10, 1, 50), safeH + 0.5)
    local safeV, fatalV = speedFor(safeH), speedFor(fatalH)
    local sig = string.format("%.1f|%.1f", safeV, fatalV)
    if not applied or applied.sig ~= sig then
        local ok = pcall(function()
            c.NonFatalFallVelocity = safeV
            c.FatalFallVelocity = fatalV
        end)
        if not ok then return end
        applied = { safe = safeV, fatal = fatalV, sig = sig }
        U.log("fall damage: hurts from %.1f m (%.0f cm/s), fatal from %.1f m (%.0f cm/s), %s, x%.1f",
            safeH, safeV, fatalH, fatalV, C.get("fall_damage_progressive") and "grows with height" or "flat",
            C.get("fall_damage_scale") or 1)
    end
    setDamage(c, lastDown(c))
end

-- Post-hook of Comp_FallDamage:StopFalling: the component applies the damage right after it.
function M.onStopFalling(c)
    if not U.valid(c) then return end
    local down = lastDown(c)
    local mine = comp and U.same(c, comp)
    if mine and applied and C.get("fall_damage_custom") then
        local dmg = setDamage(c, down)
        if down >= applied.fatal then
            U.dlog("fall: landed at %.0f cm/s (%.1f m drop) -> fatal", down, heightFor(down))
        elseif down >= applied.safe then
            U.dlog("fall: landed at %.0f cm/s (%.1f m drop) -> %.1f damage", down, heightFor(down), dmg)
        else
            U.dlog("fall: landed at %.0f cm/s (%.1f m drop) -> no damage", down, heightFor(down))
        end
    elseif U.debug then
        local s, f, d = U.get(c, "NonFatalFallVelocity"), U.get(c, "FatalFallVelocity"), U.get(c, "NonFatalDamage")
        U.dlog("fall (game rules): landed at %.0f cm/s (%.1f m drop); damage %s from %s, fatal from %s",
            down, heightFor(down), tostring(d), tostring(s), tostring(f))
    end
end

function M.reset()
    comp, vanilla, applied = nil, nil, nil
end

return M
