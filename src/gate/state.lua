local gate_interface = require("gate.interface")
local result = require("core.result")
local validate = require("core.validate")

local state = {}
local ACTIVITY_SET = {
    idle = true,
    partial_dial = true,
    dialing_out = true,
    incoming_open = true,
    incoming_connected = true,
    outgoing_open = true,
    outgoing_connected = true,
}
local CONNECTION_DIRECTION_SET = {
    incoming = true,
    outgoing = true,
}

---@param errors table[]
---@param path string
---@param value any
local function validate_optional_number(errors, path, value)
    if value ~= nil and type(value) ~= "number" then
        validate.push_error(errors, path, "expected number")
    end
end

---@param errors table[]
---@param path string
---@param value any
local function validate_optional_boolean(errors, path, value)
    if value ~= nil and type(value) ~= "boolean" then
        validate.push_error(errors, path, "expected boolean")
    end
end

---@param errors table[]
---@param path string
---@param value any
local function validate_optional_string(errors, path, value)
    if value ~= nil and type(value) ~= "string" then
        validate.push_error(errors, path, "expected string")
    end
end

---@param errors table[]
---@param path string
---@param value any
local function validate_optional_integer(errors, path, value)
    if value ~= nil and not validate.is_integer(value) then
        validate.push_error(errors, path, "expected integer")
    end
end

---@param errors table[]
---@param path string
---@param address any
local function validate_optional_address(errors, path, address)
    if address == nil then
        return
    end

    if not validate.expect_integer_array(errors, path, address) then
        return
    end

    for index, symbol in ipairs(address) do
        if symbol < 0 then
            validate.push_error(errors, path .. "[" .. index .. "]", "symbol must be >= 0")
        end
    end
end

---@param left integer[]?
---@param right integer[]?
---@return boolean
local function same_address(left, right)
    if left == right then
        return true
    end

    if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
        return false
    end

    for index, value in ipairs(left) do
        if right[index] ~= value then
            return false
        end
    end

    return true
end

---@param query SgcResult
---@param fallback any
---@return any
local function value_or(query, fallback)
    if query.ok then
        return query.value
    end

    return fallback
end

---@param connected boolean
---@param open boolean
---@param dialing_out boolean
---@param chevrons_engaged integer?
---@return boolean
local function keep_transient_address_data(connected, open, dialing_out, chevrons_engaged)
    return connected == true
        or open == true
        or dialing_out == true
        or (type(chevrons_engaged) == "number" and chevrons_engaged > 0)
end

---@param instance table
---@param previous_state SgcGateState?
---@return SgcResult
local function read_live_snapshot(instance, previous_state)
    if type(instance) ~= "table" then
        return result.err("missing_interface_instance")
    end

    local connected = gate_interface.is_connected(instance)
    if not connected.ok then
        return connected
    end

    local open = gate_interface.is_open(instance)
    if not open.ok then
        return open
    end

    local dialing_out = gate_interface.is_dialing_out(instance)
    if not dialing_out.ok then
        return dialing_out
    end

    local chevrons_engaged = value_or(gate_interface.get_chevrons_engaged(instance), nil)
    local current_symbol = value_or(gate_interface.get_current_symbol(instance), nil)
    local carried_energy = type(previous_state) == "table" and previous_state.energy or nil
    local carried_iris = type(previous_state) == "table" and previous_state.iris or nil
    local connected_value = connected.value == true
    local open_value = open.value == true
    local dialing_out_value = dialing_out.value == true
    local carry_transient = keep_transient_address_data(connected_value, open_value, dialing_out_value, chevrons_engaged)
    local previous_current_symbol = type(previous_state) == "table" and previous_state.current_symbol or nil
    local live_current_symbol = current_symbol ~= nil and current_symbol or previous_current_symbol

    return result.ok({
        side = instance.side,
        interface_type = instance.interface_type,
        connected = connected_value,
        open = open_value,
        dialing_out = dialing_out_value,
        idle = connected_value ~= true
            and open_value ~= true
            and dialing_out_value ~= true
            and (chevrons_engaged == nil or chevrons_engaged <= 0),
        partial_dial = type(chevrons_engaged) == "number" and chevrons_engaged > 0 or false,
        local_address = previous_state ~= nil and previous_state.local_address or nil,
        dialed_address = carry_transient and previous_state ~= nil and previous_state.dialed_address or nil,
        connected_address = carry_transient and previous_state ~= nil and previous_state.connected_address or nil,
        chevrons_engaged = chevrons_engaged,
        stargate_generation = previous_state ~= nil and previous_state.stargate_generation or nil,
        current_symbol = carry_transient and live_current_symbol or nil,
        energy = carried_energy or {
            stored = nil,
            capacity = nil,
            available = false,
        },
        iris = carried_iris or {
            supported = instance.capabilities.iris == true,
            identifier = nil,
            installed = nil,
            progress = nil,
            progress_percent = nil,
        },
    })
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
    local connected = value_or(gate_interface.is_connected(instance), false)
    local open = value_or(gate_interface.is_open(instance), false)
    local dialing_out = value_or(gate_interface.is_dialing_out(instance), false)
    local chevrons_engaged = value_or(gate_interface.get_chevrons_engaged(instance), nil)

    local gate_state = {
        side = instance.side,
        interface_type = instance.interface_type,
        connected = connected,
        open = open,
        dialing_out = dialing_out,
        idle = connected ~= true and open ~= true and dialing_out ~= true and (chevrons_engaged == nil or chevrons_engaged <= 0),
        partial_dial = type(chevrons_engaged) == "number" and chevrons_engaged > 0 or false,
        local_address = value_or(gate_interface.get_local_address(instance), nil),
        dialed_address = value_or(gate_interface.get_dialed_address(instance), nil),
        connected_address = value_or(gate_interface.get_connected_address(instance), nil),
        chevrons_engaged = chevrons_engaged,
        stargate_generation = value_or(gate_interface.get_stargate_generation(instance), nil),
        current_symbol = value_or(gate_interface.get_current_symbol(instance), nil),
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

---@param instance table
---@param previous_state SgcGateState?
---@return SgcResult
function state.read_live(instance, previous_state)
    return read_live_snapshot(instance, previous_state)
end

---@param candidate any
---@return SgcResult
function state.validate_snapshot(candidate)
    local errors = {}
    if not validate.expect_table(errors, "gate_state", candidate) then
        return validate.result(errors)
    end

    validate.expect_string(errors, "gate_state.side", candidate.side, false)
    validate.expect_string(errors, "gate_state.interface_type", candidate.interface_type, false)
    validate.expect_boolean(errors, "gate_state.connected", candidate.connected)
    validate.expect_boolean(errors, "gate_state.open", candidate.open)
    validate.expect_boolean(errors, "gate_state.dialing_out", candidate.dialing_out)
    validate.expect_boolean(errors, "gate_state.idle", candidate.idle)
    validate.expect_boolean(errors, "gate_state.partial_dial", candidate.partial_dial)

    if validate.expect_string(errors, "gate_state.activity", candidate.activity, false)
        and ACTIVITY_SET[candidate.activity] ~= true
    then
        validate.push_error(errors, "gate_state.activity", "unsupported gate activity")
    end

    if candidate.connection_direction ~= nil then
        if validate.expect_string(errors, "gate_state.connection_direction", candidate.connection_direction, false)
            and CONNECTION_DIRECTION_SET[candidate.connection_direction] ~= true
        then
            validate.push_error(errors, "gate_state.connection_direction", "unsupported connection direction")
        end
    end

    validate_optional_address(errors, "gate_state.local_address", candidate.local_address)
    validate_optional_address(errors, "gate_state.dialed_address", candidate.dialed_address)
    validate_optional_address(errors, "gate_state.connected_address", candidate.connected_address)
    validate_optional_integer(errors, "gate_state.chevrons_engaged", candidate.chevrons_engaged)
    validate_optional_integer(errors, "gate_state.stargate_generation", candidate.stargate_generation)
    validate_optional_integer(errors, "gate_state.current_symbol", candidate.current_symbol)

    if validate.expect_table(errors, "gate_state.energy", candidate.energy) then
        validate_optional_number(errors, "gate_state.energy.stored", candidate.energy.stored)
        validate_optional_number(errors, "gate_state.energy.capacity", candidate.energy.capacity)
        validate.expect_boolean(errors, "gate_state.energy.available", candidate.energy.available)
    end

    if validate.expect_table(errors, "gate_state.iris", candidate.iris) then
        validate.expect_boolean(errors, "gate_state.iris.supported", candidate.iris.supported)
        validate_optional_string(errors, "gate_state.iris.identifier", candidate.iris.identifier)
        validate_optional_boolean(errors, "gate_state.iris.installed", candidate.iris.installed)
        validate_optional_number(errors, "gate_state.iris.progress", candidate.iris.progress)
        validate_optional_number(errors, "gate_state.iris.progress_percent", candidate.iris.progress_percent)
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(candidate)
end

---@param left SgcGateState?
---@param right SgcGateState?
---@return boolean
function state.same(left, right)
    if left == right then
        return true
    end

    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end

    return left.side == right.side
        and left.interface_type == right.interface_type
        and left.connected == right.connected
        and left.open == right.open
        and left.dialing_out == right.dialing_out
        and left.activity == right.activity
        and left.connection_direction == right.connection_direction
        and left.idle == right.idle
        and left.partial_dial == right.partial_dial
        and same_address(left.local_address, right.local_address)
        and same_address(left.dialed_address, right.dialed_address)
        and same_address(left.connected_address, right.connected_address)
        and left.chevrons_engaged == right.chevrons_engaged
        and left.stargate_generation == right.stargate_generation
        and left.current_symbol == right.current_symbol
        and type(left.energy) == "table"
        and type(right.energy) == "table"
        and left.energy.stored == right.energy.stored
        and left.energy.capacity == right.energy.capacity
        and left.energy.available == right.energy.available
        and type(left.iris) == "table"
        and type(right.iris) == "table"
        and left.iris.supported == right.iris.supported
        and left.iris.identifier == right.iris.identifier
        and left.iris.installed == right.iris.installed
        and left.iris.progress == right.iris.progress
        and left.iris.progress_percent == right.iris.progress_percent
end

return state
