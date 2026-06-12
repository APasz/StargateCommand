local log = require("core.log")
local result = require("core.result")

local shared = {}

---@param component string
---@param config table
---@return table
function shared.logger(component, config)
    local level = "info"
    if config.logging ~= nil and type(config.logging.level) == "string" then
        level = config.logging.level
    end

    return log.new(component, level)
end

---@param value any
---@return SgcResult
function shared.as_result(value)
    if result.is_result(value) then
        return value
    end

    return result.ok(value)
end

return shared

