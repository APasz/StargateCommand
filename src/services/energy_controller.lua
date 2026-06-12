local gate_interface = require("gate.interface")
local result = require("core.result")

local energy_controller = {}

---@param instance table
---@return SgcResult
function energy_controller.read(instance)
    local stored = gate_interface.get_energy(instance)
    local capacity = gate_interface.get_capacity(instance)

    return result.ok({
        stored = stored.ok and stored.value or nil,
        capacity = capacity.ok and capacity.value or nil,
        available = stored.ok and capacity.ok,
    })
end

---@param _config table
---@return SgcResult
function energy_controller.start(_config)
    local discovered = gate_interface.discover()
    if not discovered.ok then
        return discovered
    end

    return energy_controller.read(discovered.value)
end

return energy_controller

