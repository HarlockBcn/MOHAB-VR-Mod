-- MOHABDump: development helper. Dumps reflection info for the classes MOHAB Plus touches.
-- Enable it in Mods/mods.txt ("MOHABDump : 1"). Output: Mods/MOHABDump/dump.txt and CXXHeaderDump.

local modDir = debug.getinfo(1, "S").source:match("^@(.*)[\\/]Scripts[\\/]main%.lua$") or "."
local outPath = modDir .. "\\dump.txt"
local out = {}
local function W(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
local function flush()
    local f = io.open(outPath, "w")
    if f then f:write(table.concat(out, "\n")); f:close() end
end

local trivial = { FloatProperty = true, IntProperty = true, BoolProperty = true, ByteProperty = true,
    NameProperty = true, StrProperty = true, DoubleProperty = true, Int64Property = true, UInt32Property = true }

local function valueStr(obj, name, pclass)
    if not trivial[pclass] and pclass ~= "ObjectProperty" and pclass ~= "EnumProperty" then return "" end
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return "<err>" end
    if pclass == "ObjectProperty" then
        if v and v.IsValid and v:IsValid() then
            local ok2, n = pcall(function() return v:GetFullName() end)
            return ok2 and n or "<obj>"
        end
        return "None"
    end
    if pclass == "NameProperty" then return v:ToString() end
    if pclass == "StrProperty" then return v:ToString() end
    return tostring(v)
end

local function dumpClassChain(obj, title, stopAt)
    W("==================== %s: %s", title, obj:GetFullName())
    local cls = obj:GetClass()
    while cls and cls:IsValid() do
        local cname = cls:GetFName():ToString()
        W("---- class %s", cls:GetFullName())
        cls:ForEachProperty(function(p)
            local pname = p:GetFName():ToString()
            local pclass = p:GetClass():GetFName():ToString()
            W("  P %-40s %-22s %s", pname, pclass, valueStr(obj, pname, pclass))
        end)
        cls:ForEachFunction(function(f)
            W("  F %s", f:GetFName():ToString())
        end)
        if cname == stopAt then break end
        cls = cls:GetSuperStruct()
    end
end

local function listComponents(actor)
    W("==================== components of %s", actor:GetFullName())
    local comps = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
    if comps then
        for i = 1, #comps do
            local c = comps[i]:get()
            if c:IsValid() then W("  C %s", c:GetFullName()) end
        end
    end
end

local done = false
local function tryDump()
    if done then return true end
    local pawn = FindFirstOf("BP_VRPlayerCharacter_C")
    if not pawn or not pawn:IsValid() then return false end
    done = true
    print("[MOHABDump] Player found, dumping...\n")
    local ok, err = pcall(function()
        dumpClassChain(pawn, "PAWN", "Pawn")
        listComponents(pawn)
        local cm = pawn.CharacterMovement
        if cm and cm:IsValid() then dumpClassChain(cm, "MOVEMENT", "MovementComponent") end
        local pc = pawn.Controller
        if pc and pc:IsValid() then dumpClassChain(pc, "CONTROLLER", "Controller") end
        local hc = pawn.VRPlayerCharacterHealthAndDamageComponent
        if hc and hc:IsValid() then dumpClassChain(hc, "HEALTH", "ActorComponent") end
        for _, k in ipairs({ "LeftController", "RightController", "MovementHandController" }) do
            local ok2, mc = pcall(function() return pawn[k] end)
            if ok2 and mc and mc.IsValid and mc:IsValid() then dumpClassChain(mc, "CTRL " .. k, "Actor") end
        end
        local syr = FindAllOf("BP_HealthSyringe_C")
        if syr and #syr > 0 then dumpClassChain(syr[1], "SYRINGE", "Actor") end
    end)
    if not ok then W("ERROR: %s", tostring(err)) end
    flush()
    print("[MOHABDump] dump.txt written, generating SDK headers...\n")
    pcall(GenerateSDK)
    print("[MOHABDump] done\n")
    return true
end

LoopAsync(3000, function()
    local finished = false
    ExecuteInGameThread(function() finished = tryDump() end)
    return done
end)
print("[MOHABDump] loaded, waiting for the player pawn...\n")
