local constants = require("core.constants")

local signal = {}

---@param state table
local function reset_connection_cycle(state)
    state.connection_cycle_active = false
    state.wormhole_cycle_pulsed = {
        incoming = false,
        outgoing = false,
    }
end

---@param state table
local function begin_connection_cycle(state)
    state.connection_cycle_active = true
    state.wormhole_cycle_pulsed = {
        incoming = false,
        outgoing = false,
    }
end

---@param gate_state SgcGateState?
---@return boolean?
local function connection_cycle_active(gate_state)
    if type(gate_state) ~= "table" then
        return nil
    end

    return gate_state.connected == true
        or gate_state.open == true
        or gate_state.partial_dial == true
        or gate_state.dialing_out == true
        or gate_state.activity == "dialing_out"
        or gate_state.activity == "partial_dial"
        or gate_state.activity == "incoming_open"
        or gate_state.activity == "incoming_connected"
        or gate_state.activity == "outgoing_open"
        or gate_state.activity == "outgoing_connected"
end

---@param state table
---@param gate_state SgcGateState?
local function sync_connection_cycle(state, gate_state)
    local active = connection_cycle_active(gate_state)
    if active == nil then
        return
    end

    if active == true then
        if state.connection_cycle_active ~= true then
            begin_connection_cycle(state)
        end
        return
    end

    reset_connection_cycle(state)
end

---@param signal_name SgcAlarmSignalName
---@return "incoming" | "outgoing"?
local function wormhole_direction(signal_name)
    if signal_name == "wormhole_incoming" then
        return "incoming"
    end

    if signal_name == "wormhole_outgoing" then
        return "outgoing"
    end

    return nil
end

---@return table
function signal.new_state()
    local state = {
        pulse_until = {},
        last_connected = false,
        connection_cycle_active = false,
        wormhole_cycle_pulsed = {
            incoming = false,
            outgoing = false,
        },
    }

    reset_connection_cycle(state)
    return state
end

---@param state table
---@param signal_name SgcAlarmSignalName
---@param now_ms integer
function signal.activate_pulse(state, signal_name, now_ms)
    if constants.ALARM_SIGNAL_SET[signal_name] ~= true then
        return
    end

    local direction = wormhole_direction(signal_name)
    if direction ~= nil then
        if state.connection_cycle_active ~= true then
            begin_connection_cycle(state)
        end

        if state.wormhole_cycle_pulsed[direction] == true then
            return
        end

        state.wormhole_cycle_pulsed[direction] = true
    end

    state.pulse_until[signal_name] = now_ms + constants.ALARM_PULSE_DURATION_MS
end

---@param state table
---@param previous_gate_state SgcGateState?
---@param gate_state SgcGateState?
---@param now_ms integer
function signal.observe_gate_state(state, previous_gate_state, gate_state, now_ms)
    local previous_connected = type(previous_gate_state) == "table" and previous_gate_state.connected == true or false
    local connected = type(gate_state) == "table" and gate_state.connected == true or false
    local previous_open = type(previous_gate_state) == "table" and previous_gate_state.open == true or false
    local open = type(gate_state) == "table" and gate_state.open == true or false
    if previous_connected == true and connected ~= true then
        signal.activate_pulse(state, "connection_disconnected", now_ms)
    end

    sync_connection_cycle(state, gate_state)

    if type(previous_gate_state) == "table" and previous_open ~= true and open == true and type(gate_state) == "table" then
        if gate_state.connection_direction == "incoming" then
            signal.activate_pulse(state, "wormhole_incoming", now_ms)
        elseif gate_state.connection_direction == "outgoing" then
            signal.activate_pulse(state, "wormhole_outgoing", now_ms)
        end
    end

    state.last_connected = connected
end

---@param snapshot table
---@return boolean
local function system_error_active(snapshot)
    if snapshot.trigger_on_fault == true and (snapshot.gate_fault ~= nil or snapshot.site_fault ~= nil) then
        return true
    end

    return type(snapshot.site_status) == "table" and snapshot.site_status.healthy ~= true or false
end

---@param gate_state SgcGateState?
---@return boolean
local function connection_incoming_active(gate_state)
    return type(gate_state) == "table"
        and gate_state.connected == true
        and gate_state.connection_direction == "incoming"
end

---@param gate_state SgcGateState?
---@return boolean
local function connection_outgoing_active(gate_state)
    return type(gate_state) == "table"
        and gate_state.connected == true
        and gate_state.connection_direction == "outgoing"
end

---@param gate_state SgcGateState?
---@return boolean
local function dialing_active(gate_state)
    if type(gate_state) ~= "table" then
        return false
    end

    if gate_state.activity == "dialing_out" or gate_state.dialing_out == true then
        return true
    end

    return gate_state.connection_direction == "outgoing"
        and gate_state.partial_dial == true
        and gate_state.connected ~= true
        and gate_state.open ~= true
end

---@param state table
---@param snapshot table
---@param now_ms integer
---@return table<string, boolean>
function signal.evaluate(state, snapshot, now_ms)
    local gate_state = type(snapshot.gate_state) == "table" and snapshot.gate_state or nil
    local site_status = type(snapshot.site_status) == "table" and snapshot.site_status or nil
    local signals = {}

    for _, signal_name in ipairs(constants.ALARM_SIGNAL_NAMES) do
        signals[signal_name] = false
    end

    signals.connection_established = type(gate_state) == "table" and gate_state.connected == true or false
    signals.connection_incoming = connection_incoming_active(gate_state)
    signals.connection_outgoing = connection_outgoing_active(gate_state)
    signals.dialing = dialing_active(gate_state)
    signals.system_error = system_error_active(snapshot)

    for signal_name, expires_at in pairs(state.pulse_until) do
        if type(expires_at) == "number" and expires_at > now_ms then
            signals[signal_name] = true
        end
    end

    return signals
end

return signal
