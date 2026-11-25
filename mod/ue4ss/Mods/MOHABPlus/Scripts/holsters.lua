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

return M
