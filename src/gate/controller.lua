local command_message = require("command.message")
local command_network = require("command.network")
local constants = require("core.constants")
local discovery = require("net.discovery")
local gate_command = require("gate.command")
local gate_event = require("gate.event")
local gate_interface = require("gate.interface")
local gate_message = require("gate.message")
local gate_state = require("gate.state")
local host_lifecycle = require("lifecycle.host")
local envelope = require("net.envelope")
local net_inbox = require("net.inbox")
local protocols = require("net.protocols")
local result = require("core.result")
local tablex = require("core.tablex")
local time = require("core.time")
local transport = require("net.rednet_transport")

local controller = {}
local OUTBOUND_STATUS_GRACE_MS = 15000
local STATE_HEARTBEAT_INTERVAL_MS = 2000
local STATE_HEARTBEAT_INTERVAL_SECONDS = STATE_HEARTBEAT_INTERVAL_MS / 1000
local WORMHOLE_REFRESH_DELAY_SECONDS = 0.5
local GATE_EVENT_SET = {
    stargate_chevron_engaged = true,
    stargate_incoming_connection = true,
    stargate_incoming_wormhole = true,
    stargate_outgoing_wormhole = true,
    stargate_disconnected = true,
    stargate_reset = true,
    stargate_deconstructing_entity = true,
    stargate_reconstructing_entity = true,
    stargate_message_received = true,
}
local RAW_GATE_EVENT_TO_SIGNAL = {
    stargate_chevron_engaged = "chevron_engaged",
    stargate_incoming_wormhole = "wormhole_incoming",
    stargate_outgoing_wormhole = "wormhole_outgoing",
    stargate_deconstructing_entity = "traveller_in",
    stargate_reconstructing_entity = "traveller_out",
    stargate_message_received = "message_received",
    stargate_reset = "reset",
}
local enrich_state
local NOOP_LOGGER = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
}

---@param incoming table
---@return string
local function request_id_for(incoming)
    if type(incoming.envelope.payload) == "table"
        and type(incoming.envelope.payload.command) == "table"
        and type(incoming.envelope.payload.command.request_id) == "string"
    then
        return incoming.envelope.payload.command.request_id
    end

    return incoming.envelope.msg_id
end

---@param logger table?
---@return table
local function normalize_logger(logger)
    return logger or NOOP_LOGGER
end

---@param payload table?
---@param target_role SgcRole
---@param target_site string
---@param kind string
---@return boolean
local function is_targeted_payload(payload, target_role, target_site, kind)
    return type(payload) == "table"
        and payload.kind == kind
        and payload.target_role == target_role
        and payload.target_site == target_site
end

---@param activity table?
---@return boolean
local function is_stable_connected_activity(activity)
    return type(activity) == "table"
        and activity.connected == true
        and activity.open ~= true
        and activity.dialing_out ~= true
        and activity.chevrons_engaged == 0
end

---@param reset_attempt SgcResult
---@return boolean
local function is_nonfatal_startup_reset_failure(reset_attempt)
    if reset_attempt.ok or reset_attempt.error ~= "gate_reset_incomplete" or type(reset_attempt.details) ~= "table" then
        return false
    end

    return is_stable_connected_activity(reset_attempt.details.before)
        and is_stable_connected_activity(reset_attempt.details.after)
end

---@param runtime table
local function clear_active_outbound(runtime)
    runtime.active_outbound = nil
end

---@param address integer[]?
---@return integer[]?
local function with_point_of_origin(address)
    if type(address) ~= "table" then
        return nil
    end

    if address[#address] == constants.POINT_OF_ORIGIN_SYMBOL then
        return address
    end

    local copy = {}
    for index, symbol in ipairs(address) do
        copy[index] = symbol
    end
    copy[#copy + 1] = constants.POINT_OF_ORIGIN_SYMBOL
    return copy
end

---@param left integer[]?
---@param right integer[]?
---@return boolean
local function addresses_equal(left, right)
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

---@param runtime table
---@param raw_state SgcGateState
---@return boolean
local function outbound_matches_gate_state(runtime, raw_state)
    if type(runtime.active_outbound) ~= "table" or type(runtime.active_outbound.address) ~= "table" then
        return false
    end

    local outbound_address = with_point_of_origin(runtime.active_outbound.address)
    return addresses_equal(outbound_address, raw_state.dialed_address)
        or addresses_equal(outbound_address, raw_state.connected_address)
end

---@param runtime table
---@param command table
local function begin_active_outbound(runtime, command)
    runtime.active_outbound = {
        destination_site = command.destination_site,
        address = command.address,
        dial_mode = command.dial_mode,
        expires_at = time.now_ms() + OUTBOUND_STATUS_GRACE_MS,
    }
end

---@param runtime table
---@param raw_state SgcGateState
---@return boolean
local function has_active_outbound(runtime, raw_state)
    if type(runtime.active_outbound) ~= "table" then
        return false
    end

    if runtime.executing_dial == true then
        return true
    end

    if raw_state.dialing_out == true or raw_state.partial_dial == true or raw_state.open == true or raw_state.connected == true then
        runtime.active_outbound.expires_at = time.now_ms() + OUTBOUND_STATUS_GRACE_MS
        return true
    end

    if type(runtime.active_outbound.expires_at) == "number" and time.now_ms() <= runtime.active_outbound.expires_at then
        return true
    end

    clear_active_outbound(runtime)
    return false
end

---@param runtime table
---@param raw_state SgcGateState
---@param command_action SgcGateCommandAction?
---@return boolean
local function update_runtime_state(runtime, raw_state, command_action)
    local enriched = enrich_state(runtime, raw_state, command_action)
    local changed = not gate_state.same(runtime.state, enriched)
    runtime.state = enriched
    return changed
end

---@param config table
---@param runtime table
---@param logger table?
---@param force boolean?
---@return SgcResult
local function publish_state(config, runtime, logger, force)
    if type(runtime.state) ~= "table" then
        return result.err("missing_gate_state")
    end

    local now_ms = time.now_ms()
    local should_publish = force == true
        or runtime.last_published_state == nil
        or not gate_state.same(runtime.last_published_state, runtime.state)
        or runtime.last_state_publish_at == nil
        or now_ms - runtime.last_state_publish_at >= STATE_HEARTBEAT_INTERVAL_MS
    if not should_publish then
        return result.ok(false)
    end

    local next_sequence = (runtime.state_sequence or 0) + 1
    local payload = gate_message.build_state_payload(runtime.state, next_sequence, now_ms)
    local built = envelope.new("state", config.site, config.role, payload)
    if not built.ok then
        return built
    end

    local sent = transport.broadcast(protocols.for_type("state"), built.value)
    if not sent.ok then
        return sent
    end

    runtime.state_sequence = next_sequence
    runtime.last_published_state = tablex.deep_copy(runtime.state)
    runtime.last_state_publish_at = now_ms
    return result.ok(true)
end

---@param config table
---@param runtime table
---@param signal_name SgcGateEventSignalName
---@param details table?
---@return SgcResult
local function publish_gate_event(config, runtime, signal_name, details)
    local next_sequence = (runtime.event_sequence or 0) + 1
    local payload = gate_event.build_payload(signal_name, next_sequence, time.now_ms(), details)
    local built = envelope.new("event", config.site, config.role, payload)
    if not built.ok then
        return built
    end

    local sent = transport.broadcast(protocols.for_type("event"), built.value)
    if not sent.ok then
        return sent
    end

    runtime.event_sequence = next_sequence
    return result.ok(true)
end

---@param config table
---@param runtime table
---@param logger table?
---@param command_action SgcGateCommandAction?
---@param force boolean?
---@return SgcResult
local function refresh_and_publish_state(config, runtime, logger, command_action, force)
    local refreshed = gate_state.read(runtime.interface)
    if not refreshed.ok then
        return refreshed
    end

    local changed = update_runtime_state(runtime, refreshed.value, command_action)
    if changed or force == true then
        return publish_state(config, runtime, logger, true)
    end

    return publish_state(config, runtime, logger, false)
end

---@param config table
---@param runtime table
---@param logger table?
---@param command_action SgcGateCommandAction?
---@param force boolean?
---@return SgcResult
local function refresh_and_publish_live_state(config, runtime, logger, command_action, force)
    local refreshed = gate_state.read_live(runtime.interface, runtime.state)
    if not refreshed.ok then
        return refreshed
    end

    local changed = update_runtime_state(runtime, refreshed.value, command_action)
    if changed or force == true then
        return publish_state(config, runtime, logger, true)
    end

    return publish_state(config, runtime, logger, false)
end

---@param runtime table
---@return table
local function build_live_state_hooks(runtime)
    return {
        final_state_reader = function()
            return gate_state.read_live(runtime.interface, runtime.state)
        end,
    }
end

---@param runtime table
---@param raw_state SgcGateState
---@param command_action SgcGateCommandAction?
---@return SgcGateState
enrich_state = function(runtime, raw_state, command_action)
    if command_action == "disconnect" or command_action == "reset" then
        clear_active_outbound(runtime)
    end

    local active_outbound = has_active_outbound(runtime, raw_state) or command_action == "dial"
    local previous_direction = runtime.connection_direction
    local connection_direction = nil

    if raw_state.dialing_out == true or command_action == "dial" then
        connection_direction = "outgoing"
    elseif raw_state.partial_dial == true then
        connection_direction = previous_direction or (active_outbound and "outgoing" or nil)
    elseif raw_state.open == true or raw_state.connected == true then
        if outbound_matches_gate_state(runtime, raw_state) then
            connection_direction = "outgoing"
        elseif previous_direction == "incoming" then
            connection_direction = "incoming"
        else
            connection_direction = "incoming"
        end
    elseif raw_state.idle ~= true then
        connection_direction = previous_direction
    end

    runtime.connection_direction = connection_direction

    local enriched = tablex.shallow_copy(raw_state)
    enriched.connection_direction = connection_direction
    if raw_state.dialing_out == true
        or (
            runtime.executing_dial == true
            and raw_state.connected ~= true
            and raw_state.open ~= true
            and raw_state.partial_dial ~= true
        )
    then
        enriched.activity = "dialing_out"
    elseif raw_state.connected == true then
        if connection_direction == "incoming" then
            enriched.activity = "incoming_connected"
        else
            enriched.activity = "outgoing_connected"
        end
    elseif raw_state.open == true then
        if connection_direction == "incoming" then
            enriched.activity = "incoming_open"
        else
            enriched.activity = "outgoing_open"
        end
    elseif raw_state.partial_dial == true then
        enriched.activity = "partial_dial"
    else
        enriched.activity = "idle"
    end

    if enriched.activity == "idle" and raw_state.connected ~= true and raw_state.open ~= true and raw_state.partial_dial ~= true then
        clear_active_outbound(runtime)
    end
    return enriched
end

---@param _config table
---@return SgcResult
function controller.start(config)
    local discovered = gate_interface.discover()
    if not discovered.ok then
        return discovered
    end

    local opened_modems = {}
    if config.modems.site ~= nil then
        local opened = transport.open(config.modems.site)
        if not opened.ok then
            return opened
        end
        opened_modems[#opened_modems + 1] = config.modems.site
    end

    local startup_reset = gate_command.reset_to_idle(discovered.value)
    if not startup_reset.ok and not is_nonfatal_startup_reset_failure(startup_reset) then
        return startup_reset
    end

    local state = gate_state.read(discovered.value)
    if not state.ok then
        return state
    end

    local runtime = {
        interface = discovered.value,
        opened_modems = opened_modems,
        startup_reset = startup_reset.ok and startup_reset.value or {
            reset_performed = false,
            blocked = true,
            reason = startup_reset.error,
            before = startup_reset.details.before,
            after = startup_reset.details.after,
        },
        connection_direction = nil,
        active_outbound = nil,
        executing_dial = false,
        event_sequence = 0,
        inbox = net_inbox.new(),
        state_sequence = 0,
        last_published_state = nil,
        last_state_publish_at = nil,
    }
    runtime.state = enrich_state(runtime, state.value, nil)

    return result.ok(runtime)
end

---@param instance table
---@param payload table
---@param hooks table?
---@return SgcResult
function controller.execute(instance, payload, hooks)
    return gate_command.execute(instance, payload, hooks)
end

---@param config table
---@param runtime table
---@param incoming table
---@param operation SgcResult
---@return SgcResult
local function reply_with_operation(config, runtime, incoming, operation)
    if operation.ok and type(operation.value) == "table" and type(operation.value.state) == "table" then
        runtime.state = enrich_state(runtime, operation.value.state, operation.value.action)
        operation.value.state = runtime.state
    end

    local response_payload = command_message.build_result_payload(request_id_for(incoming), operation)
    local replied = command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, response_payload)
    if not replied.ok then
        return replied
    end

    if operation.ok and type(operation.value) == "table" and type(operation.value.state) == "table" then
        publish_state(config, runtime, nil, false)
    end

    return replied
end

---@param config table
---@param runtime table
---@param incoming table
---@param logger table?
---@return SgcResult
local function handle_nested_gate_command(config, runtime, incoming, logger)
    if incoming.envelope.type ~= "command" then
        return result.ok({
            handled = false,
        })
    end

    if not is_targeted_payload(incoming.envelope.payload, "gate_controller", config.site, "gate_request") then
        return result.ok({
            handled = false,
        })
    end

    local validated = command_message.validate_gate_request_payload(incoming.envelope.payload)
    if not validated.ok then
        return reply_with_operation(config, runtime, incoming, result.err(validated.error, validated.details))
    end

    local action = validated.value.command.action
    if action == "status" then
        local state = gate_state.read(runtime.interface)
        if state.ok then
            runtime.state = enrich_state(runtime, state.value, nil)
            state = result.ok({
                action = "status",
                request_id = request_id_for(incoming),
                state = runtime.state,
            })
        end

        return reply_with_operation(config, runtime, incoming, state)
    end

    if action == "disconnect" then
        local hooks = build_live_state_hooks(runtime)
        local executed = controller.execute(runtime.interface, validated.value.command, hooks)
        if executed.ok and type(executed.value) == "table" and type(executed.value.state) == "table" then
            runtime.state = enrich_state(runtime, executed.value.state, action)
            executed.value.state = runtime.state
        end

        local replied = reply_with_operation(config, runtime, incoming, executed)
        if not replied.ok then
            return replied
        end

        return result.ok({
            handled = true,
            abort_active_command = true,
        })
    end

    local active_logger = normalize_logger(logger)
    active_logger:debug("gate controller rejected nested command while busy", {
        action = action,
        msg_id = incoming.envelope.msg_id,
    })
    return reply_with_operation(config, runtime, incoming, result.err("gate_busy", {
        action = action,
    }))
end

---@param config table
---@param runtime table
---@param incoming table
---@return SgcResult
function controller.handle_command(config, runtime, incoming)
    if incoming.envelope.type ~= "command" then
        return result.ok({
            handled = false,
        })
    end

    if not is_targeted_payload(incoming.envelope.payload, "gate_controller", config.site, "gate_request") then
        return result.ok({
            handled = false,
        })
    end

    local validated = command_message.validate_gate_request_payload(incoming.envelope.payload)
    local request_id = request_id_for(incoming)

    local response_payload = nil
    if not validated.ok then
        response_payload = command_message.build_result_payload(request_id, result.err(validated.error, validated.details))
    else
        local hooks = build_live_state_hooks(runtime)
        if validated.value.command.action == "dial" then
            begin_active_outbound(runtime, validated.value.command)
            runtime.executing_dial = true
            hooks.poll = function()
                    local received = net_inbox.receive_next(config, runtime.inbox, 0, nil, nil)
                    if not received.ok then
                        if received.error == "receive_timeout" then
                            return result.ok(true)
                        end

                        return received
                    end

                    local handled = handle_nested_gate_command(config, runtime, received.value)
                    if not handled.ok then
                        return handled
                    end

                    if type(handled.value) == "table" and handled.value.abort_active_command == true then
                        return result.err("dial_cancelled")
                    end

                    return result.ok(true)
            end
            hooks.read_state = function()
                return gate_state.read_live(runtime.interface, runtime.state)
            end
            hooks.state_changed = function(raw_state)
                update_runtime_state(runtime, raw_state, validated.value.command.action)
                publish_state(config, runtime, nil, false)
                return result.ok(true)
            end
        end

        local executed = controller.execute(runtime.interface, validated.value.command, hooks)
        runtime.executing_dial = false
        if executed.ok and type(executed.value) == "table" and type(executed.value.state) == "table" then
            runtime.state = enrich_state(runtime, executed.value.state, validated.value.command.action)
            executed.value.state = runtime.state
        elseif validated.value.command.action == "dial" then
            clear_active_outbound(runtime)
        end
        response_payload = command_message.build_result_payload(request_id, executed)
    end

    local replied = command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, response_payload)
    if not replied.ok then
        return replied
    end

    if validated.ok and type(runtime.state) == "table" then
        publish_state(config, runtime, nil, false)
    end

    return replied
end

---@param delay_seconds number
---@return integer?
local function start_timer(delay_seconds)
    if os == nil or type(os.startTimer) ~= "function" then
        return nil
    end

    return os.startTimer(delay_seconds)
end

---@param runtime table
---@param event_name string
---@param peripheral_name any
---@param third any
---@return boolean
local function apply_gate_event_hint(runtime, event_name, peripheral_name, third)
    if GATE_EVENT_SET[event_name] ~= true or peripheral_name ~= runtime.interface.side then
        return false
    end

    if event_name == "stargate_chevron_engaged" then
        runtime.connection_direction = third == true and "incoming" or "outgoing"
    elseif event_name == "stargate_incoming_connection" or event_name == "stargate_incoming_wormhole" then
        runtime.connection_direction = "incoming"
    elseif event_name == "stargate_outgoing_wormhole" then
        runtime.connection_direction = "outgoing"
    end

    return true
end

---@param config table
---@param runtime table
---@param logger table?
---@param event_name string
---@param peripheral_name any
---@param third any
---@return SgcResult
local function handle_gate_interface_event(config, runtime, logger, event_name, peripheral_name, third)
    if not apply_gate_event_hint(runtime, event_name, peripheral_name, third) then
        return result.ok(false)
    end

    local signal_name = RAW_GATE_EVENT_TO_SIGNAL[event_name]
    if signal_name ~= nil then
        local published_event = publish_gate_event(config, runtime, signal_name)
        if not published_event.ok then
            return published_event
        end
    end

    local refreshed = refresh_and_publish_live_state(config, runtime, logger, nil, false)
    if not refreshed.ok then
        return refreshed
    end

    if event_name == "stargate_incoming_wormhole" or event_name == "stargate_outgoing_wormhole" then
        runtime.pending_refresh_timer = start_timer(WORMHOLE_REFRESH_DELAY_SECONDS)
    end

    return result.ok(true)
end

---@param config table
---@param runtime table
---@param sender_id any
---@param message any
---@param protocol_name any
---@param logger table
---@return SgcResult
local function handle_rednet_message_event(config, runtime, sender_id, message, protocol_name, logger)
    local parsed = transport.parse_received_message(config, sender_id, message, protocol_name, nil)
    if not parsed.ok then
        if transport.is_nonfatal_receive_error(parsed.error) then
            logger:debug("ignoring invalid rednet message", {
                sender_id = sender_id,
                protocol = protocol_name,
                error = parsed.error,
                details = parsed.details,
            })
            return result.ok({
                handled = true,
            })
        end

        return parsed
    end

    local handled = host_lifecycle.handle_command(config, parsed.value, logger, {
        before_reboot = function(intent)
            if type(print) == "function" then
                print("Host restarting" .. (intent.reason ~= nil and ": " .. tostring(intent.reason) or ""))
            end
            return result.ok(true)
        end,
    })
    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = controller.handle_command(config, runtime, parsed.value)
    end
    if not handled.ok then
        return handled
    end

    if type(handled.value) == "table" and handled.value.handled == false then
        logger:debug("ignoring unrelated command envelope", {
            msg_id = parsed.value.envelope.msg_id,
            protocol = parsed.value.protocol,
            role = parsed.value.envelope.role,
        })
    end

    return handled
end

---@param config table
---@param runtime table
---@param logger table
---@return SgcResult
local function serve_event_loop(config, runtime, logger)
    local heartbeat_timer = start_timer(STATE_HEARTBEAT_INTERVAL_SECONDS)
    runtime.pending_refresh_timer = nil

    while true do
        local event_name, first, second, third, fourth, fifth = os.pullEvent()
        if event_name == "rednet_message" then
            local handled = handle_rednet_message_event(config, runtime, first, second, third, logger)
            if not handled.ok then
                if handled.error == "unexpected_protocol" then
                    logger:debug("ignoring unrelated rednet message", {
                        sender_id = first,
                        protocol = third,
                    })
                else
                    logger:error("gate command handling failed", {
                        error = handled.error,
                        details = handled.details,
                    })
                    return handled
                end
            end
        elseif event_name == "timer" and first == heartbeat_timer then
            heartbeat_timer = start_timer(STATE_HEARTBEAT_INTERVAL_SECONDS)
            local refreshed = refresh_and_publish_state(config, runtime, logger, nil, false)
            if not refreshed.ok then
                logger:warn("gate state refresh failed", {
                    error = refreshed.error,
                    details = refreshed.details,
                })
            end
        elseif event_name == "timer" and first == runtime.pending_refresh_timer then
            runtime.pending_refresh_timer = nil
            local refreshed = refresh_and_publish_state(config, runtime, logger, nil, false)
            if not refreshed.ok then
                logger:warn("gate state follow-up refresh failed", {
                    error = refreshed.error,
                    details = refreshed.details,
                })
            end
        elseif GATE_EVENT_SET[event_name] == true then
            local gate_event = nil
            if event_name == "stargate_chevron_engaged" then
                gate_event = handle_gate_interface_event(config, runtime, logger, event_name, first, fourth)
            else
                gate_event = handle_gate_interface_event(config, runtime, logger, event_name, first, second)
            end

            if not gate_event.ok then
                logger:warn("gate state event handling failed", {
                    event = event_name,
                    error = gate_event.error,
                    details = gate_event.details,
                })
            end
        end
    end
end

---@param config table
---@param runtime table
---@param logger table
---@return SgcResult
local function serve_polling_loop(config, runtime, logger)
    while true do
        local received = net_inbox.receive_next(config, runtime.inbox, STATE_HEARTBEAT_INTERVAL_SECONDS, nil, logger)
        if not received.ok then
            if received.error == "receive_timeout" then
                local refreshed = refresh_and_publish_state(config, runtime, logger, nil, false)
                if not refreshed.ok then
                    logger:warn("gate state refresh failed", {
                        error = refreshed.error,
                        details = refreshed.details,
                    })
                end
            else
                logger:error("gate command receive failed", {
                    error = received.error,
                    details = received.details,
                })
                return received
            end
        else
            local handled = host_lifecycle.handle_command(config, received.value, logger, {
                before_reboot = function(intent)
                    if type(print) == "function" then
                        print("Host restarting" .. (intent.reason ~= nil and ": " .. tostring(intent.reason) or ""))
                    end
                    return result.ok(true)
                end,
            })
            if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
                handled = controller.handle_command(config, runtime, received.value)
            end
            if not handled.ok then
                logger:error("gate command handling failed", {
                    error = handled.error,
                    details = handled.details,
                })
            elseif type(handled.value) == "table" and handled.value.handled == false then
                logger:debug("ignoring unrelated command envelope", {
                    msg_id = received.value.envelope.msg_id,
                    protocol = received.value.protocol,
                    role = received.value.envelope.role,
                })
            end
        end
    end
end

---@param config table
---@param logger table?
---@return SgcResult
function controller.serve(config, logger)
    local active_logger = normalize_logger(logger)
    local started = controller.start(config)
    if not started.ok then
        return started
    end

    local runtime = started.value
    local announced = discovery.announce(config, {
        services = { config.role },
    })
    if not announced.ok then
        active_logger:warn("failed to broadcast hello", announced.details)
    end

    active_logger:info("Ready: " .. tostring(config.role), {
        interface_type = runtime.interface.interface_type,
        startup_reset = runtime.startup_reset ~= nil and runtime.startup_reset.reset_performed == true or false,
    })
    local published = publish_state(config, runtime, active_logger, true)
    if not published.ok then
        active_logger:warn("gate state publish failed", {
            error = published.error,
            details = published.details,
        })
    end

    if os ~= nil and type(os.pullEvent) == "function" and type(os.startTimer) == "function" then
        return serve_event_loop(config, runtime, active_logger)
    end

    return serve_polling_loop(config, runtime, active_logger)
end

return controller
