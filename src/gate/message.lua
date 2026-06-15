local gate_state = require("gate.state")
local net_message = require("net.message")
local result = require("core.result")
local validate = require("core.validate")

local message = {}

---@param payload any
---@return SgcResult
function message.validate_state_payload(payload)
    local errors = {}
    net_message.validate_snapshot_payload(payload, errors, "gate_state", "state", gate_state.validate_snapshot)

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param state_snapshot SgcGateState
---@param sequence integer
---@param emitted_at integer
---@return table
function message.build_state_payload(state_snapshot, sequence, emitted_at)
    return net_message.build_snapshot_payload("gate_state", "state", state_snapshot, sequence, emitted_at)
end

return message
