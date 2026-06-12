local gate_interface = require("gate.interface")
local result = require("core.result")

local state = {}

---@param query SgcResult
---@param fallback any
---@return any
local function value_or(query, fallback)
    if query.ok then
        return query.value
    end

    return fallback
end

---@param instance table
---@return SgcResult
function state.read(instance)
    if type(instance) ~= "table" then
        return result.err("missing_interface_instance")
    end

    local energy = {
        stored = value_or(gate_interface.get_energy(instance), nil),
        capacity = value_or(gate_interface.get_capacity(instance), nil),
        available = true,
    }

    if energy.stored == nil or energy.capacity == nil then
        energy.available = false
    end

    local iris_identifier = gate_interface.get_iris(instance)
    local iris_progress = gate_interface.get_iris_progress(instance)
    local iris_percent = gate_interface.get_iris_progress_percent(instance)

    local gate_state = {
        side = instance.side,
        interface_type = instance.interface_type,
        connected = value_or(gate_interface.is_connected(instance), false),
        open = value_or(gate_interface.is_open(instance), false),
        dialing_out = value_or(gate_interface.is_dialing_out(instance), false),
        local_address = value_or(gate_interface.get_local_address(instance), nil),
        dialed_address = value_or(gate_interface.get_dialed_address(instance), nil),
        connected_address = value_or(gate_interface.get_connected_address(instance), nil),
        energy = energy,
        iris = {
            supported = instance.capabilities.iris == true,
            identifier = value_or(iris_identifier, nil),
            installed = iris_identifier.ok and iris_identifier.value ~= nil or nil,
            progress = value_or(iris_progress, nil),
            progress_percent = value_or(iris_percent, nil),
        },
    }

    return result.ok(gate_state)
end

return state

