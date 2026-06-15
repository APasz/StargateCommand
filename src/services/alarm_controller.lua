local alarm_output = require("alarm.output")
local alarm_signal = require("alarm.signal")
local alarm_speaker = require("alarm.speaker")
local alarm_monitor = require("alarm.monitor")
local command_message = require("command.message")
local command_network = require("command.network")
local config_defaults = require("config.default")
local command_timeout = require("command.timeout")
local constants = require("core.constants")
local discovery = require("net.discovery")
local gate_event = require("gate.event")
local gate_message = require("gate.message")
local host_lifecycle = require("lifecycle.host")
local net_inbox = require("net.inbox")
local log_messages = require("core.log_messages")
local result = require("core.result")
local site_message = require("site.message")
local tablex = require("core.tablex")
local time = require("core.time")
local transport = require("net.rednet_transport")

local alarm_controller = {}
local DEFAULT_POLL_INTERVAL_MS = 250
local SOURCE_STALE_MS = 5000
local ACTIVE_DIAL_STALE_MS = 30000
local RAW_GATE_EVENT_TO_SIGNAL = {
    stargate_chevron_engaged = "chevron_engaged",
    stargate_incoming_wormhole = "wormhole_incoming",
    stargate_outgoing_wormhole = "wormhole_outgoing",
    stargate_deconstructing_entity = "traveller_in",
    stargate_reconstructing_entity = "traveller_out",
    stargate_message_received = "message_received",
    stargate_reset = "reset",
}
local resolve_speaker_config = nil
local NOOP_LOGGER = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
}

---@class SgcAlarmConfig
---@field outputs table[]
---@field poll_interval_ms integer
---@field monitor_text_scale number
---@field trigger_on_fault boolean
---@field speaker table

---@param logger table?
---@return table
local function normalize_logger(logger)
    return logger or NOOP_LOGGER
end

---@param runtime table
---@param config table
---@return table
local function ensure_speaker_runtime(runtime, config)
    if type(runtime.speaker) == "table" then
        return runtime.speaker
    end

    local speaker_config = resolve_speaker_config(config)
    runtime.speaker = alarm_speaker.new_runtime(speaker_config)
    return runtime.speaker
end

---@return table[]
local function default_outputs()
    return tablex.deep_copy(config_defaults.for_role("alarm_controller").alarm.outputs)
end

---@return table[]
local function default_speaker_bindings()
    return tablex.deep_copy(config_defaults.for_role("alarm_controller").alarm.speaker.bindings)
end

---@param config table
---@return table
resolve_speaker_config = function(config)
    local alarm = type(config.alarm) == "table" and config.alarm or {}
    local speaker = type(alarm.speaker) == "table" and alarm.speaker or {}
    local peripheral_side = config.modems ~= nil and config.modems.peripheral or nil
    local bindings = nil
    if type(speaker.bindings) == "table" then
        bindings = speaker.bindings
    else
        bindings = default_speaker_bindings()
    end

    return {
        bindings = bindings,
        peripheral_side = peripheral_side,
    }
end

---@param config table
---@return SgcAlarmConfig
local function resolve_alarm_config(config)
    local alarm = type(config.alarm) == "table" and config.alarm or {}
    local outputs = nil
    if type(alarm.outputs) == "table" and #alarm.outputs > 0 then
        outputs = alarm.outputs
    elseif type(alarm.output_side) == "string" then
        outputs = {
            {
                driver = "redstone",
                side = alarm.output_side,
                signal = "connection_established",
                active_high = alarm.active_high ~= false,
            },
        }
    else
        outputs = default_outputs()
    end

    return {
        outputs = outputs,
        poll_interval_ms = type(alarm.poll_interval_ms) == "number" and alarm.poll_interval_ms or DEFAULT_POLL_INTERVAL_MS,
        monitor_text_scale = type(alarm.monitor_text_scale) == "number"
            and alarm.monitor_text_scale
            or constants.DEFAULT_ALARM_MONITOR_TEXT_SCALE,
        trigger_on_fault = alarm.trigger_on_fault ~= false,
        speaker = resolve_speaker_config(config),
    }
end

---@param runtime table
---@return table
local function ensure_output_state(runtime)
    if type(runtime.output_state) == "table" then
        return runtime.output_state
    end

    runtime.output_state = alarm_output.new_state()
    return runtime.output_state
end

---@param gate_state SgcGateState?
---@return boolean
local function gate_transition_active(gate_state)
    if type(gate_state) ~= "table" then
        return false
    end

    if gate_state.dialing_out == true or gate_state.partial_dial == true then
        return true
    end

    return gate_state.connection_direction == "outgoing"
        and gate_state.connected ~= true
        and gate_state.open ~= true
end

---@param delay_ms integer
local function sleep_ms(delay_ms)
    if type(sleep) == "function" and delay_ms > 0 then
        sleep(delay_ms / 1000)
    end
end

---@param runtime table
---@param state_snapshot SgcGateState
---@param sequence integer?
---@return boolean
local function apply_gate_state_snapshot(runtime, state_snapshot, sequence)
    if type(sequence) == "number"
        and type(runtime.last_gate_state_sequence) == "number"
        and sequence <= runtime.last_gate_state_sequence
    then
        return false
    end

    local previous_state = runtime.last_gate_state
    runtime.last_gate_state = state_snapshot
    runtime.last_gate_state_at = time.now_ms()
    runtime.last_gate_fault = nil
    if type(state_snapshot.side) == "string" then
        runtime.gate_event_side = state_snapshot.side
    end
    alarm_signal.observe_gate_state(runtime.signal_state, previous_state, state_snapshot, runtime.last_gate_state_at)
    if type(sequence) == "number" then
        runtime.last_gate_state_sequence = sequence
    end

    return true
end

---@param runtime table
---@param site_status SgcSiteStatus
---@param sequence integer?
---@return boolean
local function apply_site_status_snapshot(runtime, site_status, sequence)
    if type(sequence) == "number"
        and type(runtime.last_site_status_sequence) == "number"
        and sequence <= runtime.last_site_status_sequence
    then
        return false
    end

    runtime.last_site_status = site_status
    runtime.last_site_status_at = time.now_ms()
    runtime.last_site_fault = nil
    if site_status.maintenance_mode == true then
        alarm_monitor.note(runtime.monitor, "site restarting", time.now_ms())
    end
    if type(sequence) == "number" then
        runtime.last_site_status_sequence = sequence
    end

    return true
end

---@param runtime table
---@param logger table?
---@return SgcResult
local function evaluate_runtime(runtime, logger)
    local active_logger = normalize_logger(logger)
    local speaker_runtime = ensure_speaker_runtime(runtime, runtime.config or {})
    local output_state = ensure_output_state(runtime)
    local now_ms = time.now_ms()
    local gate_fault = runtime.last_gate_fault
    local site_fault = runtime.last_site_fault
    local gate_state = runtime.last_gate_state
    local site_status = runtime.last_site_status
    local stale_ms = gate_transition_active(gate_state) and ACTIVE_DIAL_STALE_MS or SOURCE_STALE_MS

    if gate_state == nil then
        gate_fault = gate_fault or "missing_gate_state"
    elseif runtime.last_gate_state_at == nil or now_ms - runtime.last_gate_state_at > stale_ms then
        gate_fault = "stale_gate_state"
        gate_state = nil
    else
        gate_fault = nil
    end

    if site_status == nil then
        site_fault = site_fault or "missing_site_status"
    elseif runtime.last_site_status_at == nil or now_ms - runtime.last_site_status_at > stale_ms then
        site_fault = "stale_site_status"
        site_status = nil
    else
        site_fault = nil
    end

    local signals = alarm_signal.evaluate(runtime.signal_state, {
        gate_state = gate_state,
        site_status = site_status,
        gate_fault = gate_fault,
        site_fault = site_fault,
        trigger_on_fault = runtime.alarm.trigger_on_fault == true,
    }, now_ms)

    local applied = alarm_output.apply(runtime.alarm.outputs, signals, output_state, now_ms)
    if not applied.ok then
        return applied
    end

    local speaker_state = alarm_speaker.update(speaker_runtime, signals)
    if not speaker_state.ok then
        active_logger:warn("alarm controller speaker update failed", {
            error = speaker_state.error,
            details = speaker_state.details,
        })
    end

    runtime.signals = signals
    runtime.last_gate_fault = gate_fault
    runtime.last_site_fault = site_fault

    local rendered = alarm_monitor.render(runtime, now_ms)
    if not rendered.ok and rendered.error ~= "missing_monitor" then
        active_logger:debug("alarm controller monitor render failed", {
            error = rendered.error,
            details = rendered.details,
        })
    end

    return result.ok({
        signals = signals,
        outputs = applied.value,
        gate_fault = gate_fault,
        site_fault = site_fault,
        gate_state = gate_state,
        site_status = site_status,
        speaker = speaker_state.ok and speaker_state.value or nil,
    })
end

---@param runtime table
---@param incoming table
---@return SgcResult
local function handle_state_message(runtime, incoming)
    if incoming.protocol ~= constants.PROTOCOLS.state or incoming.envelope.type ~= "state" then
        return result.ok({
            handled = false,
        })
    end

    if incoming.envelope.site ~= runtime.config.site then
        return result.ok({
            handled = false,
        })
    end

    if incoming.envelope.role == "gate_controller" then
        local validated_gate = gate_message.validate_state_payload(incoming.envelope.payload)
        if not validated_gate.ok then
            return validated_gate
        end

        return result.ok({
            handled = true,
            source = "gate_controller",
            changed = apply_gate_state_snapshot(runtime, validated_gate.value.state, validated_gate.value.sequence),
        })
    end

    if incoming.envelope.role == "site_controller" then
        local validated_site = site_message.validate_status_payload(incoming.envelope.payload)
        if not validated_site.ok then
            return validated_site
        end

        return result.ok({
            handled = true,
            source = "site_controller",
            changed = apply_site_status_snapshot(runtime, validated_site.value.status, validated_site.value.sequence),
        })
    end

    return result.ok({
        handled = false,
    })
end

---@param runtime table
---@param signal_name SgcGateEventSignalName
local function record_gate_event_signal(runtime, signal_name)
    alarm_signal.activate_pulse(runtime.signal_state, signal_name, time.now_ms())
    alarm_monitor.note(runtime.monitor, "event " .. tostring(signal_name), time.now_ms())
end

---@param entry table
---@param active boolean
---@return string
local function monitor_toggle_status(entry, active)
    local wire = entry.driver == "bundled" and tostring(entry.wire_color)
        or entry.driver == "speaker" and tostring(entry.pattern)
        or tostring(entry.side)
    return string.format(
        "%s %s %s %s",
        wire,
        entry.mode == "pulse" and "pulse" or "steady",
        tostring(entry.signal),
        active == true and "manual on" or "manual off"
    )
end

---@param runtime table
---@param incoming table
---@return SgcResult
local function handle_event_message(runtime, incoming)
    if incoming.protocol ~= constants.PROTOCOLS.event or incoming.envelope.type ~= "event" then
        return result.ok({
            handled = false,
        })
    end

    if incoming.envelope.site ~= runtime.config.site or incoming.envelope.role ~= "gate_controller" then
        return result.ok({
            handled = false,
        })
    end

    local validated = gate_event.validate_payload(incoming.envelope.payload)
    if not validated.ok then
        return validated
    end

    record_gate_event_signal(runtime, validated.value.signal)
    return result.ok({
        handled = true,
        changed = true,
        source = "gate_controller_event",
    })
end

---@param runtime table
---@param event_name string
---@param peripheral_name any
---@return SgcResult
local function handle_local_gate_event(runtime, event_name, peripheral_name)
    local signal_name = RAW_GATE_EVENT_TO_SIGNAL[event_name]
    if signal_name == nil then
        return result.ok(false)
    end

    if runtime.gate_event_side ~= nil and peripheral_name ~= runtime.gate_event_side then
        return result.ok(false)
    end

    record_gate_event_signal(runtime, signal_name)
    return result.ok(true)
end

---@param runtime table
---@param incoming table
---@return SgcResult
local function handle_unsolicited_message(runtime, incoming)
    local handled = host_lifecycle.handle_command(runtime.config, incoming, nil, {
        before_reboot = function(intent)
            alarm_monitor.note(runtime.monitor, "site restarting", time.now_ms(), 3000)
            return alarm_monitor.render(runtime, time.now_ms())
        end,
    })
    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = handle_event_message(runtime, incoming)
    end
    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = handle_state_message(runtime, incoming)
    end
    return handled
end

---@param config table
---@param logger table?
---@param wait_options table?
---@return SgcResult
local function read_gate_status(config, logger, wait_options)
    local sent = command_network.broadcast_command(config, command_message.build_gate_request_payload(config.site, {
        action = "status",
    }))
    if not sent.ok then
        return sent
    end

    local waited = command_network.wait_for_result(config, sent.value.msg_id, command_timeout.for_action("status"), wait_options)
    if not waited.ok then
        return waited
    end

    local payload = waited.value.payload
    if payload.ok ~= true then
        return result.err(payload.error, payload.details)
    end

    local remote_result = payload.result
    if type(remote_result) ~= "table" or type(remote_result.state) ~= "table" then
        return result.err("missing_gate_state", {
            site = config.site,
            role = config.role,
        })
    end

    return result.ok(remote_result.state)
end

---@param config table
---@param logger table?
---@param wait_options table?
---@return SgcResult
local function read_site_status(config, logger, wait_options)
    local sent = command_network.broadcast_command(config, command_message.build_site_request_payload(config.site, {
        action = "status",
    }))
    if not sent.ok then
        return sent
    end

    local waited = command_network.wait_for_result(config, sent.value.msg_id, command_timeout.for_action("status"), wait_options)
    if not waited.ok then
        return waited
    end

    local payload = waited.value.payload
    if payload.ok ~= true then
        return result.err(payload.error, payload.details)
    end

    local remote_result = payload.result
    if type(remote_result) ~= "table" or type(remote_result.site_status) ~= "table" then
        return result.err("missing_site_status", {
            site = config.site,
            role = config.role,
        })
    end

    return result.ok(remote_result.site_status)
end

---@param runtime table
---@param logger table?
---@return SgcResult
function alarm_controller.run_once(runtime, logger)
    local active_logger = normalize_logger(logger)
    local speaker_runtime = ensure_speaker_runtime(runtime, runtime.config or {})
    local output_state = ensure_output_state(runtime)
    local wait_options = {
        logger = active_logger,
        inbox = runtime.inbox,
        on_unmatched = function(incoming)
            local handled = handle_unsolicited_message(runtime, incoming)
            if not handled.ok then
                return handled
            end

            return result.ok(type(handled.value) == "table" and handled.value.handled == true)
        end,
    }
    local gate_status = read_gate_status(runtime.config, active_logger, wait_options)
    local site_status = read_site_status(runtime.config, active_logger, wait_options)
    local gate_fault = nil
    local site_fault = nil

    if gate_status.ok then
        apply_gate_state_snapshot(runtime, gate_status.value, nil)
    else
        gate_fault = gate_status.error
        active_logger:warn("alarm controller gate status read failed", {
            error = gate_status.error,
            details = gate_status.details,
        })
    end

    if site_status.ok then
        apply_site_status_snapshot(runtime, site_status.value, nil)
    else
        site_fault = site_status.error
        active_logger:warn("alarm controller site status read failed", {
            error = site_status.error,
            details = site_status.details,
        })
    end

    local now_ms = time.now_ms()
    local signals = alarm_signal.evaluate(runtime.signal_state, {
        gate_state = gate_status.ok and gate_status.value or nil,
        site_status = site_status.ok and site_status.value or nil,
        gate_fault = gate_fault,
        site_fault = site_fault,
        trigger_on_fault = runtime.alarm.trigger_on_fault == true,
    }, now_ms)

    local applied = alarm_output.apply(runtime.alarm.outputs, signals, output_state, now_ms)
    if not applied.ok then
        return applied
    end

    local speaker_state = alarm_speaker.update(speaker_runtime, signals)
    if not speaker_state.ok then
        active_logger:warn("alarm controller speaker update failed", {
            error = speaker_state.error,
            details = speaker_state.details,
        })
    end

    runtime.signals = signals
    runtime.last_gate_fault = gate_fault
    runtime.last_site_fault = site_fault

    local rendered = alarm_monitor.render(runtime, now_ms)
    if not rendered.ok and rendered.error ~= "missing_monitor" then
        active_logger:debug("alarm controller monitor render failed", {
            error = rendered.error,
            details = rendered.details,
        })
    end

    return result.ok({
        signals = signals,
        outputs = applied.value,
        gate_fault = gate_fault,
        site_fault = site_fault,
        gate_state = gate_status.ok and gate_status.value or nil,
        site_status = site_status.ok and site_status.value or nil,
        speaker = speaker_state.ok and speaker_state.value or nil,
    })
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
---@param logger table
---@return SgcResult
local function serve_event_loop(runtime, logger)
    local tick_seconds = runtime.alarm.poll_interval_ms / 1000
    local tick_timer = start_timer(tick_seconds)

    while true do
        local event_name, first, second, third = os.pullEvent()
        if event_name == "rednet_message" then
            local parsed = transport.parse_received_message(runtime.config, first, second, third, nil)
            if not parsed.ok then
                if transport.is_nonfatal_receive_error(parsed.error) then
                    logger:debug("ignoring invalid alarm input message", {
                        sender_id = first,
                        protocol = third,
                        error = parsed.error,
                        details = parsed.details,
                    })
                else
                    return parsed
                end
            else
                local handled = handle_unsolicited_message(runtime, parsed.value)
                if not handled.ok then
                    logger:warn("alarm controller message handling failed", {
                        error = handled.error,
                        details = handled.details,
                    })
                elseif type(handled.value) == "table" and handled.value.handled == true and handled.value.changed == true then
                    local evaluated = evaluate_runtime(runtime, logger)
                    if not evaluated.ok then
                        return evaluated
                    end
                end
            end
        elseif RAW_GATE_EVENT_TO_SIGNAL[event_name] ~= nil then
            local handled_local = handle_local_gate_event(runtime, event_name, first)
            if not handled_local.ok then
                return handled_local
            end

            if handled_local.value == true then
                local evaluated = evaluate_runtime(runtime, logger)
                if not evaluated.ok then
                    return evaluated
                end
            end
        elseif event_name == "monitor_touch" then
            local touched_entry = alarm_monitor.handle_touch(runtime, tostring(first), second, third, time.now_ms())
            if touched_entry ~= nil then
                if touched_entry.driver == "speaker" then
                    local manual_active = alarm_speaker.toggle_override(
                        runtime.speaker,
                        touched_entry.binding_key,
                        touched_entry.active == true,
                        touched_entry.natural_active == true
                    )
                    alarm_monitor.note(runtime.monitor, monitor_toggle_status(touched_entry, manual_active), time.now_ms())
                    local evaluated = evaluate_runtime(runtime, logger)
                    if not evaluated.ok then
                        return evaluated
                    end
                else
                    local manual_active = alarm_output.toggle_override(
                        runtime.output_state,
                        touched_entry.binding_key,
                        touched_entry.active == true,
                        touched_entry.natural_active == true
                    )
                    alarm_monitor.note(runtime.monitor, monitor_toggle_status(touched_entry, manual_active), time.now_ms())
                    local evaluated = evaluate_runtime(runtime, logger)
                    if not evaluated.ok then
                        return evaluated
                    end
                end
            end
        elseif event_name == "timer" and first == tick_timer then
            tick_timer = start_timer(tick_seconds)
            local evaluated = evaluate_runtime(runtime, logger)
            if not evaluated.ok then
                return evaluated
            end
        end
    end
end

---@param runtime table
---@param logger table
---@return SgcResult
local function serve_receive_loop(runtime, logger)
    while true do
        local received = net_inbox.receive_next(runtime.config, runtime.inbox, runtime.alarm.poll_interval_ms / 1000, nil, logger)
        if received.ok then
            local handled = handle_unsolicited_message(runtime, received.value)
            if not handled.ok then
                logger:warn("alarm controller message handling failed", {
                    error = handled.error,
                    details = handled.details,
                })
            end
        elseif received.error ~= "receive_timeout" then
            return received
        end

        local evaluated = evaluate_runtime(runtime, logger)
        if not evaluated.ok then
            return evaluated
        end
    end
end

---@param config table
---@param logger table?
---@return SgcResult
function alarm_controller.start(config, logger)
    local active_logger = normalize_logger(logger)
    local opened = transport.open(config.modems.site)
    if not opened.ok then
        return opened
    end

    local resolved_alarm = resolve_alarm_config(config)

    local runtime = {
        config = config,
        alarm = resolved_alarm,
        speaker = alarm_speaker.new_runtime(resolved_alarm.speaker),
        signals = {},
        signal_state = alarm_signal.new_state(),
        output_state = alarm_output.new_state(),
        monitor = alarm_monitor.new_state(),
        inbox = net_inbox.new(),
        gate_event_side = nil,
        last_gate_fault = nil,
        last_site_fault = nil,
        last_gate_state = nil,
        last_gate_state_at = nil,
        last_gate_state_sequence = nil,
        last_site_status = nil,
        last_site_status_at = nil,
        last_site_status_sequence = nil,
    }

    local cleared_outputs = alarm_output.clear(runtime.alarm.outputs, runtime.output_state)
    if not cleared_outputs.ok then
        return cleared_outputs
    end

    local cleared_speaker = alarm_speaker.clear_runtime(runtime.speaker)
    if not cleared_speaker.ok then
        return cleared_speaker
    end

    local initial = alarm_controller.run_once(runtime, active_logger)
    if not initial.ok then
        return initial
    end

    active_logger:info(log_messages.ready())
    local announced = discovery.announce(config, {
        services = { config.role },
    })
    if not announced.ok then
        active_logger:warn("failed to broadcast hello", announced.details)
    end

    if os ~= nil and type(os.pullEvent) == "function" and type(os.startTimer) == "function" then
        return serve_event_loop(runtime, active_logger)
    end

    return serve_receive_loop(runtime, active_logger)
end

return alarm_controller
