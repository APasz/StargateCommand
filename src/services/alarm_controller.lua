local result = require("core.result")

local alarm_controller = {}

---@param gate_state SgcGateState
---@return boolean
function alarm_controller.should_alarm(gate_state)
    return gate_state.open == true and gate_state.connected == true
end

---@param _config table
---@return SgcResult
function alarm_controller.start(_config)
    return result.ok({
        alarm_ready = true,
        note = "Alarm outputs are scaffolded only.",
    })
end

return alarm_controller

