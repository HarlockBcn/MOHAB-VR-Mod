-- Helpers shared by all MOHAB Plus modules.
local M = {}

M.debug = false

function M.log(fmt, ...)
    local ok, s = pcall(string.format, fmt, ...)
    print("[MOHABPlus] " .. (ok and s or tostring(fmt)) .. "\n")
end

function M.dlog(fmt, ...)
    if M.debug then M.log(fmt, ...) end
end

function M.valid(o)
    if o == nil then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r == true
end

-- Safe property read: returns nil on any error.
function M.get(o, name)
    if not M.valid(o) then return nil end
    local ok, v = pcall(function() return o[name] end)
    if not ok then return nil end
    return v
end

-- Safe call of a UFunction: returns ok, result.
function M.call(o, fname, ...)
    if not M.valid(o) then return false, "invalid object" end
    local args = { ... }
    local n = select("#", ...)
    return pcall(function() return o[fname](o, table.unpack(args, 1, n)) end)
end

function M.same(a, b)
    if not M.valid(a) or not M.valid(b) then return false end
    local ok, r = pcall(function() return a:GetAddress() == b:GetAddress() end)
    return ok and r
end

function M.clamp(x, lo, hi)
    if x < lo then return lo elseif x > hi then return hi end
    return x
end

-- Vector helpers (tables with X, Y, Z)
function M.vsub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
function M.vadd(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
function M.vmul(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end
function M.vdot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function M.vlen(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
function M.vnorm(a)
    local l = M.vlen(a)
    if l < 1e-6 then return { X = 0, Y = 0, Z = 0 } end
    return M.vmul(a, 1 / l)
end
function M.vec(o) -- copy a UE FVector (userdata/table) into a plain table
    return { X = o.X, Y = o.Y, Z = o.Z }
end

-- ---------------------------------------------------------------------------------------------
-- Input. Reads raw key state from the PlayerController (works even while pawn input is disabled).
-- ---------------------------------------------------------------------------------------------
local keyCache = {}
local function key(name)
    local k = keyCache[name]
    if not k then
        k = { KeyName = FName(name) }
        keyCache[name] = k
    end
    return k
end

M.pc = nil -- set every tick by main.lua

function M.axis(name)
    if not M.valid(M.pc) then return 0 end
    local ok, v = pcall(function() return M.pc:GetInputAnalogKeyState(key(name)) end)
    if ok and type(v) == "number" then return v end
    return 0
end

function M.down(name)
    if not M.valid(M.pc) then return false end
    local ok, v = pcall(function() return M.pc:IsInputKeyDown(key(name)) end)
    return ok and v == true
end

-- Trigger value (0..1) for "Left" / "Right".
function M.trigger(hand)
    return M.axis("OculusTouch_" .. hand .. "_Trigger_Axis")
end

-- ---------------------------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------------------------
local gameplayStatics = nil
function M.now(worldContext)
    if not M.valid(gameplayStatics) then
        gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    if M.valid(gameplayStatics) and M.valid(worldContext) then
        local ok, t = pcall(function() return gameplayStatics:GetRealTimeSeconds(worldContext) end)
        if ok and type(t) == "number" then return t end
    end
    return os.clock()
end

return M
