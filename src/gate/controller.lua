local gate_interface = require("gate.interface")
local gate_state = require("gate.state")
local result = require("core.result")

local controller = {}

---@param _config table
---@return SgcResult
function controller.start(_config)
    local discovered = gate_interface.discover()
    if not discovered.ok then
        return discovered
    end

    local state = gate_state.read(discovered.value)
    if not state.ok then
        return state
    end

    return result.ok({
        interface = discovered.value,
        state = state.value,
    })
end

return controller

