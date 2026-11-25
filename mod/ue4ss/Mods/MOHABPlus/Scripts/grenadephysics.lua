-- Realistic grenade throws.
--
-- The original game (BP_GrenadeBase, R6GrenadeMasterComponent, BP_Def_Grenade):
--   * a grenade released with its pin out flies at TWICE the fastest hand speed of the last 12 frames (GetThrowValues);
--     with the pin in it falls like any weapon (manualholster.lua: the hand's speed, at most 9 m/s);
--   * it weighs 100 g (American and Gammon grenades) and brakes hard in the air (linear damping 0.5: -40% speed per
--     second);
--   * on the floor its speed is cut to 10-50% at once, and a "favourable bounce" steers it towards enemies within
--     3.6 m.
--
-- Here every grenade the player lets go of (pin out or in) leaves at the hand's own speed (x grenade_throw_strength)
-- and spin, flies with almost no air braking, and bounces by its own restitution / friction (metal M2, stick grenade,
-- soft Gammon bag): the game's floor cut and steering are overwritten in a post-hook of its ReceiveHit. After the first
-- bounce it brakes like a rolling / sliding object.
local U = require("util")
local C = require("config")

local M = {}

local GRENADE_CLASS = "/Game/R6/Core/Weapons/BP_GrenadeBase.BP_GrenadeBase_C"
local TYPES = {          -- checked in this order (class paths), real-world-ish values
    { path = "/Game/R6/Weapons/GammonGrenade/BP_GammonBomb_Grenade.BP_GammonBomb_Grenade_C", name = "Gammon",
      mass = 0.45, restitution = 0.08, friction = 0.85 },
    { path = "/Game/R6/Weapons/BP_PotatoMasher.BP_PotatoMasher_C", name = "stick",
      mass = 0.6, restitution = 0.25, friction = 0.5 },
    { path = "/Game/R6/Weapons/BP_M2Grenade.BP_M2Grenade_C", name = "M2",
      mass = 0.6, restitution = 0.3, friction = 0.4 },
}
local DEFAULT = { name = "grenade", mass = 0.6, restitution = 0.3, friction = 0.45 }

local SAMPLES = 16             -- frames of hand movement kept while held
local WINDOW = 0.045           -- s: velocity measured over this time
local LOOKBACK = 0.12          -- s: the fastest window among the last ones (the hand slows down before letting go)
local AIR_DAMPING, AIR_SPIN_DAMPING = 0.02, 0.05
local GROUND_DAMPING, GROUND_SPIN_DAMPING = 0.8, 1.5
local MIN_BOUNCE = 80          -- cm/s towards the surface: slower contacts are left to the engine (resting, rolling)
local MAX_SPIN = 1500          -- deg/s
local TRACK_TIME = 15          -- s after the release

local held = {}                -- address -> { g, name, samples = { { t, pos, quat } } }
local flying = {}              -- address -> { g, name, kind, t0, vel, hits, ground }
local classes = {}
local warned = {}

local function class(path)
    local c = classes[path]
    if not U.valid(c) then c = StaticFindObject(path); classes[path] = c end
    return U.valid(c) and c or nil
end

local function isA(o, path)
    local c = class(path)
    if not c then return false end
    local ok, r = pcall(function() return o:IsA(c) end)
    return ok and r == true
end

local function fname(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and s or "?"
end

local function kindOf(g)
    for _, k in ipairs(TYPES) do
        if isA(g, k.path) then return k end
    end
    return DEFAULT
end

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    U.log("grenade physics: " .. fmt, ...)
end

-- ---------------------------------------------------------------------------------------------
-- Maths (pure Lua)
-- ---------------------------------------------------------------------------------------------
local function qmul(a, b)
    return {
        W = a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z,
        X = a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y,
        Y = a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
        Z = a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W,
    }
end
local function qconj(q) return { W = q.W, X = -q.X, Y = -q.Y, Z = -q.Z } end

-- World angular velocity (deg/s) turning q1 into q2 in dt.
function M.angular(q1, q2, dt)
    local d = qmul(q2, qconj(q1))
    if d.W < 0 then d = { W = -d.W, X = -d.X, Y = -d.Y, Z = -d.Z } end
    local s = math.sqrt(d.X * d.X + d.Y * d.Y + d.Z * d.Z)
    if s < 1e-7 or dt <= 0 then return { X = 0, Y = 0, Z = 0 } end
    local angle = 2 * math.atan(s, d.W)
    local k = math.deg(angle) / dt / s
    return { X = d.X * k, Y = d.Y * k, Z = d.Z * k }
end

-- Release velocity (cm/s) and spin (deg/s) from the samples: the fastest WINDOW-long movement among the last LOOKBACK
-- seconds.
function M.release(samples)
    local n = #samples
    if n < 2 then return nil end
    local last = samples[n].t
    local best, bestSpeed, spin = nil, -1, nil
    for i = n, 2, -1 do
        local b = samples[i]
        if last - b.t > LOOKBACK then break end
        local j = i - 1
        while j > 1 and b.t - samples[j].t < WINDOW do j = j - 1 end
        local a = samples[j]
        local dt = b.t - a.t
        if dt > 0.004 then
            local v = U.vmul(U.vsub(b.pos, a.pos), 1 / dt)
            local s = U.vlen(v)
            if s > bestSpeed then
                best, bestSpeed = v, s
                spin = (a.quat and b.quat) and M.angular(a.quat, b.quat, dt) or nil
            end
        end
    end
    if spin then
        local s = U.vlen(spin)
        if s > MAX_SPIN then spin = U.vmul(spin, MAX_SPIN / s) end
    end
    return best, spin
end

-- Velocity after hitting a surface with normal n (unit, pointing out of it): restitution on the normal part, Coulomb
-- friction on the tangential part. nil when the object is not moving into the surface fast enough.
function M.bounce(v, n, restitution, friction)
    local vn = U.vdot(v, n)
    if vn > -MIN_BOUNCE then return nil end
    local normal = U.vmul(n, vn)
    local tangent = U.vsub(v, normal)
    local ts = U.vlen(tangent)
    local jn = (1 + restitution) * -vn                         -- normal impulse per unit mass
    local keep = ts > 1e-3 and math.max(0, 1 - friction * jn / ts) or 0
    return U.vadd(U.vmul(n, -vn * restitution), U.vmul(tangent, keep))
end

-- ---------------------------------------------------------------------------------------------
-- Game objects
-- ---------------------------------------------------------------------------------------------
local function vecOf(o, fn, ...)
    local ok, v = U.call(o, fn, ...)
    if not ok or not v then return nil end
    local okV, t = pcall(U.vec, v)
    return okV and type(t.X) == "number" and t or nil
end

local function sample(g)
    local model = U.get(g, "Model")
    local ok, xf = U.call(model, "K2_GetComponentToWorld")
    if not ok or not xf then return nil end
    local s = nil
    pcall(function()
        local p, r = xf.Translation, xf.Rotation
        s = { t = os.clock(), pos = { X = p.X, Y = p.Y, Z = p.Z }, quat = { X = r.X, Y = r.Y, Z = r.Z, W = r.W } }
    end)
    return s
end

local function isHeld(g) return U.get(g, "IsGripped") == true end

local function flyingNow(g)
    local okA, parent = U.call(g, "GetAttachParentActor")
    if okA and U.valid(parent) then return false end
    local okS, sim = U.call(U.get(g, "Model"), "IsSimulatingPhysics", FName("None"))
    return okS and sim == true
end

local function throw(g, h)
    local model = U.get(g, "Model")
    local kind = kindOf(g)
    local v, spin = M.release(h.samples)
    local strength = U.clamp(C.get("grenade_throw_strength") or 1, 0.5, 2.5)
    local game = vecOf(model, "GetPhysicsLinearVelocity", FName("None"))
    if not v then return end
    v = U.vmul(v, strength)
    U.call(model, "SetLinearDamping", AIR_DAMPING)
    U.call(model, "SetAngularDamping", AIR_SPIN_DAMPING)
    U.call(model, "SetMassOverrideInKg", FName("None"), kind.mass, true)
    -- Back to where the hand let it go, a frame later at its own speed (the game moved it with its own for a frame).
    local last = h.samples[#h.samples]
    local dt = math.min(os.clock() - last.t, 0.05)
    U.call(model, "K2_SetWorldLocation", U.vadd(last.pos, U.vmul(v, dt)), false, {}, true)
    U.call(model, "SetAllPhysicsLinearVelocity", v, false)
    if spin then U.call(model, "SetAllPhysicsAngularVelocityInDegrees", spin, false) end
    flying[g:GetAddress()] = { g = g, name = h.name, kind = kind, t0 = os.clock(), vel = v, hits = 0 }
    U.log("grenade physics: %s (%s, %s) thrown at %.1f m/s (game: %.1f m/s), spin %.0f deg/s",
        h.name, kind.name, U.get(g, "Cooking") == true and "pin out" or "pin in", U.vlen(v) / 100,
        game and U.vlen(game) / 100 or -1, spin and U.vlen(spin) or 0)
end

-- Post-hook of BP_GrenadeBase:ReceiveHit (after the game's own floor cut and steering).
function M.onHit(g, normal)
    if not C.get("grenade_physics") or not U.valid(g) then return end
    local f = flying[g:GetAddress()]
    if not f or f.name ~= fname(g) or not f.vel then return end
    local n = U.vnorm(normal)
    local v = M.bounce(f.vel, n, f.kind.restitution, f.kind.friction)
    if not v then return end
    local model = U.get(g, "Model")
    U.call(model, "SetAllPhysicsLinearVelocity", v, false)
    local spin = vecOf(model, "GetPhysicsAngularVelocityInDegrees", FName("None"))
    if spin then U.call(model, "SetAllPhysicsAngularVelocityInDegrees", U.vmul(spin, 0.6), false) end
    if not f.ground then
        f.ground = true
        U.call(model, "SetLinearDamping", GROUND_DAMPING)
        U.call(model, "SetAngularDamping", GROUND_SPIN_DAMPING)
    end
    f.hits = f.hits + 1
    if f.hits <= 3 then
        U.log("grenade physics: %s bounce %d: %.1f -> %.1f m/s (into the surface %.1f m/s)", f.name, f.hits,
            U.vlen(f.vel) / 100, U.vlen(v) / 100, -U.vdot(f.vel, n) / 100)
    end
    f.vel = v
end

function M.tick(pawn, now)
    if not C.get("grenade_physics") then held, flying = {}, {}; return end
    local seen = {}
    for _, side in ipairs({ "LeftController", "RightController" }) do
        local g = U.get(U.get(pawn, side), "AttachedObject")
        if U.valid(g) and isA(g, GRENADE_CLASS) and isHeld(g) then
            local addr = g:GetAddress()
            seen[addr] = true
            local h = held[addr]
            if not h or h.name ~= fname(g) then
                h = { g = g, name = fname(g), samples = {} }
                held[addr] = h
                flying[addr] = nil
            end
            local s = sample(g)
            if s then
                h.samples[#h.samples + 1] = s
                if #h.samples > SAMPLES then table.remove(h.samples, 1) end
            end
        end
    end
    -- Let go of: thrown or dropped (not put back on the chest). The game may need a frame to set it free.
    for addr, h in pairs(held) do
        if not seen[addr] then
            local g = h.g
            h.left = h.left or os.clock()
            if not U.valid(g) or fname(g) ~= h.name or isHeld(g) or os.clock() - h.left > 0.2 then
                held[addr] = nil
            elseif flyingNow(g) then
                held[addr] = nil
                local ok, err = pcall(throw, g, h)
                if not ok then warnOnce("throw", "%s", tostring(err)) end
            end
        end
    end
    -- Speed of the flying ones before each hit.
    for addr, f in pairs(flying) do
        if not U.valid(f.g) or fname(f.g) ~= f.name or os.clock() - f.t0 > TRACK_TIME or isHeld(f.g) or not flyingNow(f.g) then
            flying[addr] = nil
        else
            f.vel = vecOf(U.get(f.g, "Model"), "GetPhysicsLinearVelocity", FName("None")) or f.vel
        end
    end
end

function M.reset()
    held, flying, classes = {}, {}, {}
end

return M
