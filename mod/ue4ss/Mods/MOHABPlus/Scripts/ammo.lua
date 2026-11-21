-- Ammo box outline (backlog: red outline when the player's ammo of that type is full).
-- Highlights are drawn by a post-process material (/Game/Base/PPI_OutlineColored, parameters Color1-Color5) from the
-- mesh's custom depth stencil: BFL_Global uses 252 / 253 (left / right hand can use) and 254 (can't use);
-- BP_VRPlayerCharacter_ItemHighlight uses 251 and 255 for items within the player's capsule.
-- First step: log the five outline colours so the stencil -> colour mapping can be worked out.
local U = require("util")

local M = {}

local dumped = false
local lastTry = -100

function M.dumpOutlineColors()
    if dumped or os.clock() - lastTry < 5 then return end
    lastTry = os.clock()
    local mi = StaticFindObject("/Game/Base/PPI_OutlineColored.PPI_OutlineColored")
    if not U.valid(mi) then return end
    dumped = true
    local ok, err = pcall(function()
        local arr = mi.VectorParameterValues
        for i = 1, #arr do
            local p = arr[i]
            local name = p.ParameterInfo.Name:ToString()
            local v = p.ParameterValue
            U.log("outline colour %s = (%.2f, %.2f, %.2f, %.2f)", name, v.R, v.G, v.B, v.A)
        end
        local sarr = mi.ScalarParameterValues
        for i = 1, #sarr do
            local p = sarr[i]
            U.log("outline scalar %s = %.3f", p.ParameterInfo.Name:ToString(), p.ParameterValue)
        end
    end)
    if not ok then U.log("outline colour dump failed: %s", tostring(err)) end
end

return M
