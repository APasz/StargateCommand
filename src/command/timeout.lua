local constants = require("core.constants")

local timeout = {}

---@param action SgcGateCommandAction?
---@return number
function timeout.for_action(action)
    if action == "dial" then
        return constants.DEFAULT_DIAL_COMMAND_TIMEOUT_SECONDS
    end

    if action == "status" then
        return constants.DEFAULT_STATUS_COMMAND_TIMEOUT_SECONDS
    end

    return constants.DEFAULT_COMMAND_TIMEOUT_SECONDS
end

return timeout
