local command_schema = require("command.schema")
local constants = require("core.constants")
local gate_interface = require("gate.interface")
local gate_state = require("gate.state")
local result = require("core.result")

local command = {}
local DIRECT_DIAL_SYMBOL_DELAY_SECONDS = 0.4
local ROTATION_THINK_DELAY_SECONDS = 0.2
local ROTATION_POLL_DELAY_SECONDS = 0.05
local CHEVRON_OPEN_DELAY_SECONDS = 0.35
local CHEVRON_CLOSE_DELAY_SECONDS = 0.35
local CHEVRON_ENCODE_DELAY_SECONDS = 0.25
local ROTATION_POLL_LIMIT = 2000
local MILKY_WAY_GENERATION = 2
local PEGASUS_GENERATION = 3
local STARGATE_SYMBOL_COUNT = 39

---@param hooks table?
---@return SgcResult
local function check_continue(hooks)
    if type(hooks) == "table" and type(hooks.poll) == "function" then
        local continued = hooks.poll()
        if result.is_result(continued) then
            return continued
        end
    end

    return result.ok(true)
end

---@param delay_seconds number
---@param hooks table?
---@return SgcResult
local function sleep_if_available(delay_seconds, hooks)
    if delay_seconds <= 0 then
        return check_continue(hooks)
    end

    if type(sleep) == "function" then
        local remaining = delay_seconds
        while remaining > 0 do
            local slice = math.min(0.05, remaining)
            sleep(slice)
            remaining = remaining - slice
            local continued = check_continue(hooks)
            if not continued.ok then
                return continued
            end
        end

        return result.ok(true)
    end

    return check_continue(hooks)
end

---@param instance table
---@param hooks table?
---@return SgcResult
local function publish_state_snapshot(instance, hooks)
    if type(hooks) ~= "table" or type(hooks.state_changed) ~= "function" then
        return result.ok(true)
    end

    local refreshed = nil
    if type(hooks.read_state) == "function" then
        refreshed = hooks.read_state()
    else
        refreshed = gate_state.read(instance)
    end
    if not refreshed.ok then
        return refreshed
    end

    local notified = hooks.state_changed(refreshed.value)
    if result.is_result(notified) then
        return notified
    end

    return result.ok(true)
end

---@param address integer[]
---@return integer[]
local function with_point_of_origin(address)
    if address[#address] == constants.POINT_OF_ORIGIN_SYMBOL then
        return address
    end

    local dial_address = {}
    for index, symbol in ipairs(address) do
        dial_address[index] = symbol
    end
    dial_address[#dial_address + 1] = constants.POINT_OF_ORIGIN_SYMBOL
    return dial_address
end

---@class SgcGateActivity
---@field connected boolean
---@field open boolean
---@field dialing_out boolean
---@field chevrons_engaged integer

---@param instance table
---@return SgcResult
local function read_gate_activity(instance)
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

    local engaged = gate_interface.get_chevrons_engaged(instance)
    if not engaged.ok then
        return engaged
    end

    return result.ok({
        connected = connected.value == true,
        open = open.value == true,
        dialing_out = dialing_out.value == true,
        chevrons_engaged = engaged.value,
    })
end

---@param activity SgcGateActivity
---@return boolean
local function is_idle_activity(activity)
    return activity.connected ~= true
        and activity.open ~= true
        and activity.dialing_out ~= true
        and activity.chevrons_engaged <= 0
end

---@param instance table
---@return SgcResult
local function reset_partial_dial(instance)
    local activity = read_gate_activity(instance)
    if not activity.ok then
        return activity
    end

    if activity.value.chevrons_engaged <= 0 then
        return result.ok(false)
    end

    local disconnected = gate_interface.disconnect(instance)
    if not disconnected.ok then
        return disconnected
    end

    local after = read_gate_activity(instance)
    if not after.ok then
        return after
    end

    if not is_idle_activity(after.value) then
        return result.err("gate_reset_failed", {
            side = instance.side,
            interface_type = instance.interface_type,
            before = activity.value,
            after = after.value,
            disconnect_result = disconnected.value,
        })
    end

    return result.ok(true)
end

---@param instance table
---@return SgcResult
local function ensure_gate_idle(instance)
    local activity = read_gate_activity(instance)
    if not activity.ok then
        return activity
    end

    if activity.value.connected == true then
        return result.err("gate_already_connected", {
            side = instance.side,
            interface_type = instance.interface_type,
        })
    end

    if activity.value.dialing_out == true then
        return result.err("gate_already_dialing", {
            side = instance.side,
            interface_type = instance.interface_type,
        })
    end

    local reset = reset_partial_dial(instance)
    if not reset.ok then
        return reset
    end

    return result.ok(true)
end

---@param instance table
---@return SgcResult
function command.reset_to_idle(instance)
    local before = read_gate_activity(instance)
    if not before.ok then
        return before
    end

    local should_reset = before.value.connected == true
        or before.value.open == true
        or before.value.dialing_out == true
        or before.value.chevrons_engaged > 0
    if not should_reset then
        return result.ok({
            reset_performed = false,
            before = before.value,
            after = before.value,
        })
    end

    local disconnected = gate_interface.disconnect(instance)
    if not disconnected.ok then
        return disconnected
    end

    local after = read_gate_activity(instance)
    if not after.ok then
        return after
    end

    if not is_idle_activity(after.value) then
        return result.err("gate_reset_incomplete", {
            side = instance.side,
            interface_type = instance.interface_type,
            before = before.value,
            after = after.value,
            disconnect_result = disconnected.value,
        })
    end

    return result.ok({
        reset_performed = true,
        before = before.value,
        after = after.value,
    })
end

---@param instance table
---@param address integer[]
---@param hooks table?
---@return SgcResult
local function dial_fast(instance, address, hooks)
    if instance.capabilities.direct_dial ~= true then
        return result.err("gate_dial_unsupported_interface", {
            side = instance.side,
            interface_type = instance.interface_type,
            dial_mode = "fast",
        })
    end

    for index, symbol in ipairs(address) do
        local engaged = gate_interface.engage_symbol(instance, symbol)
        if not engaged.ok then
            return engaged
        end

        local published = publish_state_snapshot(instance, hooks)
        if not published.ok then
            return published
        end

        local continued = check_continue(hooks)
        if not continued.ok then
            return continued
        end

        if index < #address then
            local delayed = sleep_if_available(DIRECT_DIAL_SYMBOL_DELAY_SECONDS, hooks)
            if not delayed.ok then
                return delayed
            end
        end
    end

    return result.ok(true)
end

---@param current_symbol integer
---@param target_symbol integer
---@return integer?
local function clockwise_distance(current_symbol, target_symbol)
    if current_symbol < 0 or current_symbol >= STARGATE_SYMBOL_COUNT then
        return nil
    end

    if target_symbol < 0 or target_symbol >= STARGATE_SYMBOL_COUNT then
        return nil
    end

    if target_symbol >= current_symbol then
        return target_symbol - current_symbol
    end

    return (STARGATE_SYMBOL_COUNT - current_symbol) + target_symbol
end

---@param current_symbol integer
---@param target_symbol integer
---@return integer?
local function anti_clockwise_distance(current_symbol, target_symbol)
    if current_symbol < 0 or current_symbol >= STARGATE_SYMBOL_COUNT then
        return nil
    end

    if target_symbol < 0 or target_symbol >= STARGATE_SYMBOL_COUNT then
        return nil
    end

    if current_symbol >= target_symbol then
        return current_symbol - target_symbol
    end

    return current_symbol + (STARGATE_SYMBOL_COUNT - target_symbol)
end

---@param current_symbol integer
---@param target_symbol integer
---@return "clockwise" | "anti_clockwise"
local function fastest_rotation_direction(current_symbol, target_symbol)
    local clockwise = clockwise_distance(current_symbol, target_symbol)
    local anti_clockwise = anti_clockwise_distance(current_symbol, target_symbol)
    if clockwise == nil or anti_clockwise == nil then
        return "clockwise"
    end

    if anti_clockwise < clockwise then
        return "anti_clockwise"
    end

    return "clockwise"
end

---@param operation SgcResult
---@return boolean
local function can_fallback_to_slow(operation)
    if operation.error == "unsupported_method" then
        return true
    end

    return operation.error == "peripheral_call_failed"
        and type(operation.details) == "table"
        and (operation.details.method == "getCurrentSymbol" or operation.details.method == "rotateAntiClockwise")
end

---@param instance table
---@param symbol integer
---@param hooks table?
---@return SgcResult
local function wait_for_current_symbol(instance, symbol, hooks)
    for _ = 1, ROTATION_POLL_LIMIT do
        local continued = check_continue(hooks)
        if not continued.ok then
            return continued
        end

        local current = gate_interface.is_current_symbol(instance, symbol)
        if not current.ok then
            return current
        end

        if current.value == true then
            return result.ok(true)
        end

        local delayed = sleep_if_available(ROTATION_POLL_DELAY_SECONDS, hooks)
        if not delayed.ok then
            return delayed
        end
    end

    return result.err("gate_rotation_timeout", {
        side = instance.side,
        interface_type = instance.interface_type,
        symbol = symbol,
    })
end

---@param instance table
---@param symbol integer
---@param direction "clockwise" | "anti_clockwise"
---@param stargate_generation integer
---@param hooks table?
---@return SgcResult
local function encode_rotated_symbol(instance, symbol, direction, stargate_generation, hooks)
    local rotated = nil
    if direction == "anti_clockwise" then
        rotated = gate_interface.rotate_anti_clockwise(instance, symbol)
    else
        rotated = gate_interface.rotate_clockwise(instance, symbol)
    end
    if not rotated.ok then
        return rotated
    end

    local continued = check_continue(hooks)
    if not continued.ok then
        return continued
    end

    local ready = wait_for_current_symbol(instance, symbol, hooks)
    if not ready.ok then
        return ready
    end

    if stargate_generation == MILKY_WAY_GENERATION then
        local delayed = sleep_if_available(ROTATION_THINK_DELAY_SECONDS, hooks)
        if not delayed.ok then
            return delayed
        end
        local opened = gate_interface.open_chevron(instance)
        if not opened.ok then
            return opened
        end

        delayed = sleep_if_available(CHEVRON_OPEN_DELAY_SECONDS, hooks)
        if not delayed.ok then
            return delayed
        end
        local closed = gate_interface.close_chevron(instance)
        if not closed.ok then
            return closed
        end

        delayed = sleep_if_available(CHEVRON_CLOSE_DELAY_SECONDS, hooks)
        if not delayed.ok then
            return delayed
        end

        local published = publish_state_snapshot(instance, hooks)
        if not published.ok then
            return published
        end
        return result.ok(true)
    end

    local delayed = sleep_if_available(ROTATION_THINK_DELAY_SECONDS, hooks)
    if not delayed.ok then
        return delayed
    end
    local encoded = gate_interface.encode_chevron(instance)
    if not encoded.ok then
        return encoded
    end

    delayed = sleep_if_available(CHEVRON_ENCODE_DELAY_SECONDS, hooks)
    if not delayed.ok then
        return delayed
    end

    local published = publish_state_snapshot(instance, hooks)
    if not published.ok then
        return published
    end
    return result.ok(true)
end

---@param instance table
---@param address integer[]
---@param dial_mode "medium" | "slow"
---@param hooks table?
---@return SgcResult
local function dial_rotating(instance, address, dial_mode, hooks)
    local generation = gate_interface.get_stargate_generation(instance)
    if not generation.ok then
        return generation
    end

    if generation.value == PEGASUS_GENERATION then
        return result.err("gate_slow_dial_unsupported_generation", {
            side = instance.side,
            interface_type = instance.interface_type,
            stargate_generation = generation.value,
            dial_mode = dial_mode,
        })
    end

    local current_symbol_value = nil
    if dial_mode == "medium" then
        local current_symbol = gate_interface.get_current_symbol(instance)
        if not current_symbol.ok then
            return current_symbol
        end

        current_symbol_value = current_symbol.value
    end

    local rotate_clockwise = true
    for _, symbol in ipairs(address) do
        local direction = "clockwise"
        if dial_mode == "medium" then
            direction = fastest_rotation_direction(current_symbol_value, symbol)
        else
            direction = rotate_clockwise and "clockwise" or "anti_clockwise"
            rotate_clockwise = not rotate_clockwise
        end

        local encoded = encode_rotated_symbol(instance, symbol, direction, generation.value, hooks)
        if not encoded.ok then
            return encoded
        end

        local continued = check_continue(hooks)
        if not continued.ok then
            return continued
        end

        if dial_mode == "medium" then
            current_symbol_value = symbol
        end
    end

    return result.ok(true)
end

---@param instance table
---@param address integer[]
---@param dial_mode SgcDialMode
---@param hooks table?
---@return SgcResult
local function dial_address(instance, address, dial_mode, hooks)
    local idle = ensure_gate_idle(instance)
    if not idle.ok then
        return idle
    end

    local dial_address_with_origin = with_point_of_origin(address)

    if dial_mode == "fast" then
        return dial_fast(instance, dial_address_with_origin, hooks)
    end

    if dial_mode == "medium" then
        return dial_rotating(instance, dial_address_with_origin, "medium", hooks)
    end

    if dial_mode == "slow" then
        return dial_rotating(instance, dial_address_with_origin, "slow", hooks)
    end

    local fast = dial_fast(instance, dial_address_with_origin, hooks)
    if fast.ok then
        return result.ok("fast")
    end

    if fast.error ~= "gate_dial_unsupported_interface" then
        return fast
    end

    local medium = dial_rotating(instance, dial_address_with_origin, "medium", hooks)
    if medium.ok then
        return result.ok("medium")
    end

    local slow = dial_rotating(instance, dial_address_with_origin, "slow", hooks)
    if slow.ok then
        return result.ok("slow")
    end

    if can_fallback_to_slow(medium) then
        return slow
    end

    return medium
end

---@param instance table
---@param gate_command SgcGateCommand
---@param hooks table?
---@return SgcResult
local function run_gate_action(instance, gate_command, hooks)
    if gate_command.action == "disconnect" then
        return gate_interface.disconnect(instance)
    end

    if gate_command.action == "open_iris" then
        return gate_interface.open_iris(instance)
    end

    if gate_command.action == "close_iris" then
        return gate_interface.close_iris(instance)
    end

    if gate_command.action == "stop_iris" then
        return gate_interface.stop_iris(instance)
    end

    if gate_command.action == "reset" then
        return command.reset_to_idle(instance)
    end

    if gate_command.action == "status" then
        return result.ok(true)
    end

    if gate_command.action == "dial" then
        local selected_dial_mode = gate_command.dial_mode or constants.DEFAULT_DIAL_MODE
        local dialed = dial_address(instance, gate_command.address, selected_dial_mode, hooks)
        if not dialed.ok then
            return dialed
        end

        if selected_dial_mode == "auto" then
            return dialed
        end

        return result.ok(selected_dial_mode)
    end

    return result.err("unsupported_gate_command", {
        action = gate_command.action,
    })
end

---@param instance table
---@param payload table
---@param hooks table?
---@return SgcResult
function command.execute(instance, payload, hooks)
    local validated = command_schema.validate_gate_command(payload)
    if not validated.ok then
        return validated
    end

    local applied = run_gate_action(instance, validated.value, hooks)
    if not applied.ok then
        return applied
    end

    local refreshed_state = nil
    if type(hooks) == "table" and type(hooks.final_state_reader) == "function" then
        refreshed_state = hooks.final_state_reader()
    else
        refreshed_state = gate_state.read(instance)
    end
    if not refreshed_state.ok then
        return refreshed_state
    end

    return result.ok({
        action = validated.value.action,
        request_id = validated.value.request_id,
        destination_site = validated.value.destination_site,
        dial_mode_used = validated.value.action == "dial" and applied.value or nil,
        reset_performed = validated.value.action == "reset" and type(applied.value) == "table" and applied.value.reset_performed
            or nil,
        state = refreshed_state.value,
    })
end

return command
