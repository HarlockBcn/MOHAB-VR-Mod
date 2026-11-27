-- What the player's holsters hold (shared by manualholster.lua and grenaderow.lua).
local U = require("util")

local M = {}

local PROXY_CLASS = "/Game/R6/Core/Weapons/BP_WeaponBaseProxy.BP_WeaponBaseProxy_C"

function M.fname(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or "?"
end

function M.className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

local classCache = {}
function M.class(path)
    local cls = classCache[path]
    if not U.valid(cls) then
        cls = StaticFindObject(path)
        classCache[path] = cls
    end
    return U.valid(cls) and cls or nil
end

function M.isA(o, path)
    local cls = M.class(path)
    if not cls or not U.valid(o) then return false end
    local ok, r = pcall(function() return o:IsA(cls) end)
    return ok and r == true
end

-- The actor registered in a holster slot: weapons are registered through a proxy (the mesh shown in the holster).
function M.registered(hc, slot)
    local a = nil
    pcall(function()
        local arr = hc.Actors
        if slot + 1 > #arr then return end
        a = arr[slot + 1]
        if type(a) == "userdata" and a.get and not a.GetAddress then a = a:get() end
    end)
    return U.valid(a) and a or nil
end

function M.isProxy(a)
    return a ~= nil and (M.isA(a, PROXY_CLASS) or M.className(a):lower():find("proxy") ~= nil)
end

-- What a holster slot holds: the weapon / object, or nil.
function M.occupant(hc, slot)
    local a = M.registered(hc, slot)
    if not M.isProxy(a) then return a end
    local w = U.get(a, "WeaponRef")
    return U.valid(w) and w or nil
end

-- ---------------------------------------------------------------------------------------------
-- Handling a weapon (shared by manualholster.lua: no holster taps, and sprint.lua: walk while aiming)
-- ---------------------------------------------------------------------------------------------

-- Held with both hands: each controller's AttachedObject is the weapon or one of its grips (child actors).
function M.bothHands(pawn, w)
    local n = 0
    for _, side in ipairs({ "LeftController", "RightController" }) do
        local o = U.get(U.get(pawn, side), "AttachedObject")
        if U.valid(o) then
            if U.same(o, w) then
                n = n + 1
            else
                for _, fn in ipairs({ "GetParentActor", "GetAttachParentActor" }) do
                    local ok, p = U.call(o, fn)
                    if ok and U.same(p, w) then n = n + 1; break end
                end
            end
        end
    end
    return n >= 2
end

-- The gun's barrel: { pos, dir } in world space (MuzzleDirectionArrow, else MuzzleLocation), or nil.
function M.muzzle(w)
    for _, name in ipairs({ "MuzzleDirectionArrow", "MuzzleLocation" }) do
        local c = U.get(w, name)
        if U.valid(c) then
            local okD, d = U.call(c, "GetForwardVector")
            local okP, p = U.call(c, "K2_GetComponentLocation")
            if okD and d and okP and p then
                d = U.vec(d)
                if U.vlen(d) > 0.01 then return { pos = U.vec(p), dir = U.vnorm(d) } end
            end
        end
    end
    return nil
end

-- Cosine between the barrel and where the player looks (1 = pointing straight where they look), or nil.
function M.aimCos(pawn, w)
    local m = M.muzzle(w)
    local okC, c = U.call(U.get(pawn, "VRReplicatedCamera"), "GetForwardVector")
    if not m or not okC or not c then return nil end
    c = U.vec(c)
    if U.vlen(c) < 0.01 then return nil end
    return U.vdot(m.dir, U.vnorm(c))
end

return M
