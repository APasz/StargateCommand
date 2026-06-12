local result = require("core.result")

local bridge = {}

---@param _config table
---@return SgcResult
function bridge.start(_config)
    return result.ok({
        enabled = false,
        note = "Bridge protocol space is reserved only.",
    })
end

return bridge

