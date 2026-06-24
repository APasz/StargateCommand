local address_book_message = require("address_book.message")
local address_book_network = require("address_book.network")
local address_book_client = require("address_book.client")
local command_message = require("command.message")
local command_network = require("command.network")
local command_timeout = require("command.timeout")
local constants = require("core.constants")
local discovery = require("net.discovery")
local gate_message = require("gate.message")
local host_lifecycle = require("lifecycle.host")
local lifecycle_message = require("lifecycle.message")
local log_messages = require("core.log_messages")
local envelope = require("net.envelope")
local net_inbox = require("net.inbox")
local protocols = require("net.protocols")
local result = require("core.result")
local site_command = require("site.command")
local site_message = require("site.message")
local site_state = require("site.state")
local time = require("core.time")
local transport = require("net.rednet_transport")
local ui_monitor = require("ui.monitor")

local controller = {}
local SITE_CONTROLLER_MONITOR_SCALE = 0.5
local GATE_CONTACT_FRESH_MS = 5000
local SITE_STATE_POLL_INTERVAL_SECONDS = 0.25
local ADMIN_INPUT_POLL_INTERVAL_SECONDS = 0.05
local SITE_STATUS_HEARTBEAT_INTERVAL_MS = 2000
local ADDRESS_BOOK_RECOVERY_RETRY_INTERVAL_MS = 5000
local HOST_REBOOT_ACK_TIMEOUT_SECONDS = 2
local ADMIN_RESTART_INPUT_SIDE = "back"
local current_warnings = nil
local dispatch_incoming = nil
local wait_for_gate_result = nil
local NOOP_LOGGER = {
    debug = function() end,
    info = function() end,
    warn = function() end,
    error = function() end,
}

---@param attempt SgcResult
---@param warnings table[]
local function record_warning(attempt, warnings)
    if attempt.ok then
        return
    end

    warnings[#warnings + 1] = {
        error = attempt.error,
        details = attempt.details,
    }
end

---@param logger table?
---@return table
local function normalize_logger(logger)
    return logger or NOOP_LOGGER
end

---@param runtime table
---@param source string
---@param operation SgcResult
local function record_internal_error(runtime, source, operation)
    if type(runtime.health) ~= "table" then
        runtime.health = {
            last_internal_error = nil,
            internal_error_count = 0,
            last_internal_error_source = nil,
        }
    end

    runtime.health.internal_error_count = runtime.health.internal_error_count + 1
    runtime.health.last_internal_error = operation.error
    runtime.health.last_internal_error_source = source
end

---@param runtime table
local function clear_internal_error(runtime)
    if type(runtime.health) ~= "table" then
        return
    end

    runtime.health.last_internal_error = nil
    runtime.health.last_internal_error_source = nil
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

---@param runtime table
---@return string
local function address_book_summary(runtime)
    if runtime.address_book == nil then
        return "unavailable"
    end

    if runtime.address_book.book ~= nil and type(runtime.address_book.book.revision) == "number" then
        return "rev " .. tostring(runtime.address_book.book.revision)
    end

    if runtime.address_book.error ~= nil then
        return tostring(runtime.address_book.error)
    end

    return "pending"
end

---@param runtime table
---@return string?
local function warning_summary(runtime)
    local warning = current_warnings(runtime)[1]
    if type(warning) ~= "table" then
        return nil
    end

    return tostring(warning.error)
end

---@return boolean
local function restart_input_active()
    if redstone == nil or colors == nil or type(colors.black) ~= "number" then
        return false
    end

    if type(redstone.testBundledInput) == "function" then
        local ok, active = pcall(redstone.testBundledInput, ADMIN_RESTART_INPUT_SIDE, colors.black)
        return ok and active == true
    end

    if type(redstone.getBundledInput) == "function" and type(colors.test) == "function" then
        local ok, mask = pcall(redstone.getBundledInput, ADMIN_RESTART_INPUT_SIDE)
        if ok and type(mask) == "number" then
            local tested, active = pcall(colors.test, mask, colors.black)
            return tested and active == true
        end
    end

    return false
end

---@param runtime table
---@return boolean
local function gate_busy_for_restart(runtime)
    local gate_state = type(runtime.gate_contact) == "table" and runtime.gate_contact.last_state or nil
    if type(gate_state) ~= "table" then
        return false
    end

    return gate_state.connected == true
        or gate_state.open == true
        or gate_state.partial_dial == true
        or gate_state.dialing_out == true
end

---@param runtime table
---@param role string
---@return boolean
local function has_discovered_role(runtime, role)
    return type(runtime.discovered_services) == "table" and type(runtime.discovered_services[role]) == "table"
end

---@param roles table<string, boolean>
---@return string[]
local function ordered_roles(roles)
    local ordered = {}
    local seen = {}

    for _, role in ipairs(constants.ROLE_ORDER) do
        if roles[role] == true then
            ordered[#ordered + 1] = role
            seen[role] = true
        end
    end

    for role in pairs(roles) do
        if not seen[role] then
            ordered[#ordered + 1] = role
        end
    end

    return ordered
end

---@param runtime table
---@param request table
---@return string[]
local function resolve_restart_target_roles(runtime, request)
    if request.scope == "role" then
        return { request.target_role }
    end

    local discovered_roles = {}
    for _, role in ipairs(constants.HOST_LIFECYCLE_ROLE_ORDER) do
        discovered_roles[role] = true
    end

    if type(runtime.discovered_services) == "table" then
        for role in pairs(runtime.discovered_services) do
            discovered_roles[role] = true
        end
    end

    discovered_roles.site_controller = true
    return ordered_roles(discovered_roles)
end

---@param address_book_state table?
---@return table?
local function address_book_warning(address_book_state)
    if type(address_book_state) ~= "table" or address_book_state.availability ~= "degraded" then
        return nil
    end

    return {
        error = "address_book_degraded",
        details = {
            fetch_error = address_book_state.fetch_error,
            fetch_details = address_book_state.fetch_details,
        },
    }
end

---@param runtime table
---@return table[]
current_warnings = function(runtime)
    local warnings = {}
    local persistent_warnings = type(runtime.warnings) == "table" and runtime.warnings or {}
    for index, warning in ipairs(persistent_warnings) do
        warnings[index] = warning
    end

    local degraded_warning = address_book_warning(type(runtime.address_book) == "table" and runtime.address_book or nil)
    if degraded_warning ~= nil then
        warnings[#warnings + 1] = degraded_warning
    end

    return warnings
end

---@param address_book_state table?
---@return string?
local function current_address_book_error(address_book_state)
    if type(address_book_state) ~= "table" then
        return nil
    end

    if address_book_state.availability == "degraded" then
        return address_book_state.fetch_error or "address_book_degraded"
    end

    return address_book_state.error
end

---@param runtime table
---@param sender_id integer
---@param envelope_message SgcEnvelope
local function record_service_hello(runtime, sender_id, envelope_message)
    local payload = discovery.validate_payload(envelope_message.payload)
    if not payload.ok then
        return
    end

    local services = payload.value.services or { envelope_message.role }
    runtime.discovered_services = runtime.discovered_services or {}

    for _, role in ipairs(services) do
        runtime.discovered_services[role] = {
            sender_id = sender_id,
            computer_id = payload.value.computer_id,
            declared_role = envelope_message.role,
            last_seen_at = time.now_ms(),
        }
    end
end

---@param config table
---@param runtime table
---@return SgcSiteStatus
local function build_site_status(config, runtime)
    local address_book_state = type(runtime.address_book) == "table" and runtime.address_book or nil
    local address_book_available = address_book_state ~= nil and type(address_book_state.book) == "table"
    local last_internal_error = runtime.health ~= nil and runtime.health.last_internal_error or nil
    local address_book_revision = address_book_available and address_book_state.book.revision or nil
    local maintenance = type(runtime.maintenance) == "table" and runtime.maintenance or nil
    local warnings = current_warnings(runtime)

    return {
        site = config.site,
        role = config.role,
        healthy = #warnings == 0 and address_book_available and last_internal_error == nil,
        warnings_count = #warnings,
        address_book_available = address_book_available,
        address_book_error = current_address_book_error(address_book_state),
        address_book_revision = address_book_revision,
        last_internal_error = last_internal_error,
        started_at = runtime.state ~= nil and runtime.state.started_at or nil,
        maintenance_mode = maintenance ~= nil,
        maintenance_reason = maintenance ~= nil and maintenance.reason or nil,
        maintenance_action = maintenance ~= nil and maintenance.action or nil,
    }
end

---@param config table
---@param runtime table
---@return SgcSiteStatus
local function current_site_status(config, runtime)
    return build_site_status(config, runtime)
end

---@param config table
---@param runtime table
---@param force boolean?
---@return SgcResult
local function publish_site_status(config, runtime, force)
    local status = current_site_status(config, runtime)
    local now_ms = time.now_ms()
    local should_publish = force == true
        or runtime.last_published_site_status == nil
        or not site_state.same_status(runtime.last_published_site_status, status)
        or runtime.last_site_status_publish_at == nil
        or now_ms - runtime.last_site_status_publish_at >= SITE_STATUS_HEARTBEAT_INTERVAL_MS
    if not should_publish then
        return result.ok(false)
    end

    local next_sequence = (runtime.site_status_sequence or 0) + 1
    local payload = site_message.build_status_payload(status, next_sequence, now_ms)
    local built = envelope.new("state", config.site, config.role, payload)
    if not built.ok then
        return built
    end

    local sent = transport.broadcast(protocols.for_type("state"), built.value)
    if not sent.ok then
        return sent
    end

    runtime.site_status_sequence = next_sequence
    runtime.last_published_site_status = status
    runtime.last_site_status_publish_at = now_ms
    return result.ok(true)
end

---@param config table
---@param runtime table
---@return boolean
local function address_book_recovery_needed(config, runtime)
    if type(config.address_book) ~= "table" or config.address_book.server_site == nil then
        return false
    end

    local address_book_state = type(runtime.address_book) == "table" and runtime.address_book or nil
    if address_book_state ~= nil and address_book_state.availability == "available" and address_book_state.book ~= nil then
        return false
    end

    local retry_state = type(runtime.address_book_recovery) == "table" and runtime.address_book_recovery or nil
    if retry_state ~= nil
        and type(retry_state.next_retry_at) == "number"
        and time.now_ms() < retry_state.next_retry_at
    then
        return false
    end

    return true
end

---@param config table
---@param runtime table
---@param logger table?
---@return SgcResult
local function ensure_gate_available(config, runtime, logger)
    local active_logger = normalize_logger(logger)
    local last_failure = nil
    local now_ms = time.now_ms()

    if type(runtime.gate_contact) == "table"
        and type(runtime.gate_contact.last_success_at) == "number"
        and now_ms - runtime.gate_contact.last_success_at <= GATE_CONTACT_FRESH_MS
    then
        return result.ok(true)
    end

    for attempt = 1, 3 do
        local sent = command_network.broadcast_command(config, command_message.build_gate_request_payload(config.site, {
            action = "status",
            request_id = "gate-status-probe-" .. tostring(attempt),
        }))
        if sent.ok then
            local waited =
                wait_for_gate_result(config, runtime, sent.value.msg_id, command_timeout.for_action("status"), active_logger)
            if waited.ok and waited.value.payload.ok == true then
                return result.ok(true)
            end

            last_failure = waited.ok and result.err(waited.value.payload.error, waited.value.payload.details) or waited
        else
            last_failure = sent
        end
    end

    return result.err("gate_controller_unavailable", {
        site = config.site,
        cause = last_failure ~= nil and last_failure.error or nil,
        details = last_failure ~= nil and last_failure.details or nil,
    })
end

---@param runtime table
---@param state_snapshot SgcGateState?
---@param sequence integer?
---@return boolean
local function record_gate_contact(runtime, state_snapshot, sequence)
    if type(sequence) == "number"
        and type(runtime.gate_contact) == "table"
        and type(runtime.gate_contact.last_state_sequence) == "number"
        and sequence <= runtime.gate_contact.last_state_sequence
    then
        return false
    end

    runtime.gate_contact = runtime.gate_contact or {
        last_success_at = nil,
        last_state = nil,
        last_state_sequence = nil,
    }
    runtime.gate_contact.last_success_at = time.now_ms()

    if type(state_snapshot) == "table" then
        runtime.gate_contact.last_state = state_snapshot
    end

    if type(sequence) == "number" then
        runtime.gate_contact.last_state_sequence = sequence
    end

    return true
end

---@param runtime table
---@return string
local function last_command_summary(runtime)
    if type(runtime.last_command) ~= "table" then
        return "idle"
    end

    if runtime.last_command.ok == true then
        local action = runtime.last_command.action or "command"
        local destination = runtime.last_command.destination_site or "-"
        local dial_mode = runtime.last_command.dial_mode_used or runtime.last_command.dial_mode or "-"
        return string.format("%s %s [%s]", action, destination, dial_mode)
    end

    return "failed: " .. tostring(runtime.last_command.error)
end

---@param config table
---@param runtime table
local function render_monitor(config, runtime)
    local monitor_side = config.modems ~= nil and config.modems.peripheral or nil
    if monitor_side == nil then
        return
    end

    local rendered = ui_monitor.render(monitor_side, {
        "SGC Site Ctrl",
        tostring(config.site),
        "Role " .. tostring(config.role),
        "Modem S:" .. (runtime.state.modems.site and "open" or "closed")
            .. " I:" .. (runtime.state.modems.intersite and "open" or "closed"),
        "Book " .. address_book_summary(runtime),
        "Warn " .. tostring(#current_warnings(runtime)),
        "Last " .. last_command_summary(runtime),
        warning_summary(runtime) ~= nil and ("W1 " .. tostring(warning_summary(runtime))) or "",
    }, {
        text_scale = SITE_CONTROLLER_MONITOR_SCALE,
    })

    if not rendered.ok then
        -- Monitor output is optional; do not fail startup or command handling if absent.
    end
end

---@param config table
---@param runtime table
---@return SgcResult
local function recover_address_book(config, runtime)
    if not address_book_recovery_needed(config, runtime) then
        return result.ok({
            refreshed = false,
        })
    end

    runtime.address_book_recovery = runtime.address_book_recovery or {
        next_retry_at = nil,
    }
    runtime.address_book_recovery.next_retry_at = time.now_ms() + ADDRESS_BOOK_RECOVERY_RETRY_INTERVAL_MS

    local fetched = address_book_client.fetch_remote(config, {
        inbox = runtime.inbox,
    })
    if not fetched.ok then
        if type(runtime.address_book) == "table" and type(runtime.address_book.book) == "table" then
            runtime.address_book.availability = "degraded"
            runtime.address_book.fetch_error = fetched.error
            runtime.address_book.fetch_details = fetched.details
        else
            runtime.address_book = {
                mode = "client",
                availability = "unavailable",
                cache_loaded = false,
                fetched_remote = false,
                error = fetched.error,
                details = fetched.details,
            }
        end

        return result.ok({
            refreshed = false,
            error = fetched.error,
        })
    end

    runtime.address_book = {
        mode = "client",
        availability = "available",
        cache_loaded = false,
        fetched_remote = true,
        book = fetched.value,
    }
    runtime.address_book_recovery.next_retry_at = nil
    render_monitor(config, runtime)
    local published = publish_site_status(config, runtime, true)
    if not published.ok then
        return published
    end

    return result.ok({
        refreshed = true,
        revision = fetched.value.revision,
    })
end

---@param config table
---@param runtime table
---@param logger table?
---@return SgcResult
local function handle_local_admin_inputs(config, runtime, logger)
    local active = restart_input_active()
    local previous = type(runtime.admin_inputs) == "table" and runtime.admin_inputs.restart_active == true or false
    runtime.admin_inputs = runtime.admin_inputs or {}
    runtime.admin_inputs.restart_active = active
    if not active or previous then
        return result.ok(false)
    end

    local orchestrated = controller.orchestrate_reboot_request(config, runtime, {
        action = "reboot_hosts",
        request_id = "admin-redstone-reboot-" .. tostring(time.now_ms()),
        scope = "site",
        reason = "bundled_redstone_restart",
    }, {
        requested_by_role = config.role,
        requested_by_site = config.site,
    }, logger)
    if not orchestrated.ok then
        return orchestrated
    end

    if orchestrated.value.local_intent ~= nil then
        return host_lifecycle.reboot_local(config, logger, orchestrated.value.local_intent)
    end

    return result.ok(true)
end

---@param config table
---@param runtime table
---@param logger table?
---@return SgcResult
local function poll_local_admin_inputs(config, runtime, logger)
    local active_logger = normalize_logger(logger)
    local admin_inputs = handle_local_admin_inputs(config, runtime, active_logger)
    if not admin_inputs.ok then
        record_internal_error(runtime, "handle_local_admin_inputs", admin_inputs)
        active_logger:warn("site controller admin input handling failed", {
            error = admin_inputs.error,
            details = admin_inputs.details,
        })
        return result.ok(false)
    end

    return admin_inputs
end

---@param config table
---@param state table
---@param opened_modems string[]
---@param hello_message SgcEnvelope
---@param address_book_state table?
---@param warnings table[]
---@return table
local function new_runtime(config, state, opened_modems, hello_message, address_book_state, warnings)
    return {
        state = state,
        opened_modems = opened_modems,
        hello = hello_message,
        address_book = address_book_state,
        health = {
            last_internal_error = nil,
            internal_error_count = 0,
            last_internal_error_source = nil,
        },
        warnings = warnings,
        last_command = nil,
        gate_contact = {
            last_success_at = nil,
            last_state = nil,
            last_state_sequence = nil,
        },
        inbox = net_inbox.new(),
        site_status_sequence = 0,
        last_published_site_status = nil,
        last_site_status_publish_at = nil,
        maintenance = nil,
        admin_inputs = {
            restart_active = restart_input_active(),
        },
        address_book_recovery = {
            next_retry_at = nil,
        },
        discovered_services = {
            [config.role] = {
                sender_id = os ~= nil and type(os.getComputerID) == "function" and os.getComputerID() or nil,
                computer_id = os ~= nil and type(os.getComputerID) == "function" and os.getComputerID() or nil,
                declared_role = config.role,
                last_seen_at = time.now_ms(),
            },
        },
    }
end

---@param config table
---@return SgcResult
function controller.start(config)
    local state = site_state.new(config)
    local warnings = {}
    local opened_modems = {}

    if config.modems.site ~= nil then
        local opened = transport.open(config.modems.site)
        if opened.ok then
            state.modems.site = true
            opened_modems[#opened_modems + 1] = config.modems.site
        else
            record_warning(opened, warnings)
        end
    end

    if config.role == "site_controller" and config.modems.intersite ~= nil then
        local opened = transport.open(config.modems.intersite)
        if opened.ok then
            state.modems.intersite = true
            opened_modems[#opened_modems + 1] = config.modems.intersite
        else
            record_warning(opened, warnings)
        end
    end

    local hello = discovery.create_hello(config, {
        services = { config.role },
        capabilities = {
            wireless = config.modems.intersite ~= nil,
        },
    })

    if not hello.ok then
        return hello
    end

    local address_book_state = address_book_client.start(config)
    record_warning(address_book_state, warnings)
    return result.ok(new_runtime(
        config,
        state,
        opened_modems,
        hello.value,
        address_book_state.ok and address_book_state.value or nil,
        warnings
    ))
end

---@param config table
---@param runtime table
---@param incoming table
---@param logger table?
---@return SgcResult
function controller.handle_command(config, runtime, incoming, logger)
    if incoming.envelope.type ~= "command" then
        return result.ok({
            handled = false,
        })
    end

    if not is_targeted_payload(incoming.envelope.payload, "site_controller", config.site, "site_request") then
        return result.ok({
            handled = false,
        })
    end

    local active_logger = normalize_logger(logger)
    local validated = command_message.validate_site_request_payload(incoming.envelope.payload)
    if not validated.ok then
        runtime.last_command = {
            ok = false,
            error = validated.error,
        }
        render_monitor(config, runtime)
        local response_payload = command_message.build_result_payload(
            incoming.envelope.msg_id,
            result.err(validated.error, validated.details)
        )
        return command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, response_payload)
    end

    local request_payload = validated.value.command
    local request_id = request_payload.request_id or incoming.envelope.msg_id
    if request_payload.action == "status" then
        runtime.last_command = {
            ok = true,
            action = "status",
        }
        render_monitor(config, runtime)
        return command_network.send_result_reply(
            config,
            incoming.sender_id,
            incoming.envelope,
            command_message.build_result_payload(request_id, result.ok({
                action = "status",
                request_id = request_id,
                site_status = build_site_status(config, runtime),
            }))
        )
    end

    local gate_available = ensure_gate_available(config, runtime, active_logger)
    if not gate_available.ok then
        if request_payload.action == "dial" or request_payload.action == "disconnect" then
            active_logger:warn("gate availability probe failed; forwarding command anyway", {
                error = gate_available.error,
                details = gate_available.details,
            })
        else
            record_internal_error(runtime, "ensure_gate_available", gate_available)
            runtime.last_command = {
                ok = false,
                error = gate_available.error,
            }
            render_monitor(config, runtime)
            local response_payload = command_message.build_result_payload(request_id, gate_available)
            return command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, response_payload)
        end
    end

    local planned = site_command.plan(runtime.address_book ~= nil and runtime.address_book.book or nil, config.site, {
        action = request_payload.action,
        request_id = request_id,
        destination_site = request_payload.destination_site,
        dial_mode = request_payload.dial_mode,
    })
    if not planned.ok then
        runtime.last_command = {
            ok = false,
            error = planned.error,
        }
        render_monitor(config, runtime)
        local response_payload = command_message.build_result_payload(request_id, planned)
        return command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, response_payload)
    end

    local forwarded = command_network.broadcast_command(
        config,
        command_message.build_gate_request_payload(config.site, planned.value)
    )
    if not forwarded.ok then
        record_internal_error(runtime, "forward_gate_command", forwarded)
        runtime.last_command = {
            ok = false,
            error = forwarded.error,
        }
        render_monitor(config, runtime)
        local response_payload = command_message.build_result_payload(request_id, forwarded)
        return command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, response_payload)
    end

    local waited = wait_for_gate_result(
        config,
        runtime,
        forwarded.value.msg_id,
        command_timeout.for_action(planned.value.action),
        active_logger
    )
    if not waited.ok then
        record_internal_error(runtime, "wait_for_gate_result", waited)
        runtime.last_command = {
            ok = false,
            error = waited.error,
        }
        render_monitor(config, runtime)
        local response_payload = command_message.build_result_payload(request_id, waited)
        return command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, response_payload)
    end

    if waited.value.payload.ok == true and type(waited.value.payload.result) == "table" then
        runtime.last_command = {
            ok = true,
            action = waited.value.payload.result.action,
            destination_site = waited.value.payload.result.destination_site,
            dial_mode_used = waited.value.payload.result.dial_mode_used,
        }
    else
        runtime.last_command = {
            ok = false,
            error = waited.value.payload.error,
        }
    end
    render_monitor(config, runtime)
    publish_site_status(config, runtime, false)

    return command_network.send_result_reply(config, incoming.sender_id, incoming.envelope, waited.value.payload)
end

---@param config table
---@param runtime table
---@param incoming table
---@return SgcResult
function controller.handle_gate_state_update(config, runtime, incoming)
    if incoming.protocol ~= constants.PROTOCOLS.state or incoming.envelope.type ~= "state" then
        return result.ok({
            handled = false,
        })
    end

    if incoming.envelope.role ~= "gate_controller" or incoming.envelope.site ~= config.site then
        return result.ok({
            handled = false,
        })
    end

    local validated = gate_message.validate_state_payload(incoming.envelope.payload)
    if not validated.ok then
        return validated
    end

    record_gate_contact(runtime, validated.value.state, validated.value.sequence)
    return result.ok({
        handled = true,
    })
end

---@param config table
---@param runtime table
---@param incoming table
---@return SgcResult
function controller.handle_service_hello(config, runtime, incoming)
    if incoming.protocol ~= constants.PROTOCOLS.hello or incoming.envelope.type ~= "hello" then
        return result.ok({
            handled = false,
        })
    end

    if incoming.envelope.site ~= config.site then
        return result.ok({
            handled = false,
        })
    end

    record_service_hello(runtime, incoming.sender_id, incoming.envelope)
    if incoming.envelope.role == "address_book" then
        local recovered = recover_address_book(config, runtime)
        if not recovered.ok then
            return recovered
        end
    end

    return result.ok({
        handled = true,
    })
end

---@param config table
---@param runtime table
---@param target_role string
---@param request_id string
---@param reason string?
---@param logger table?
---@return SgcResult
local function request_remote_host_reboot(config, runtime, target_role, request_id, reason, logger)
    local sent = command_network.broadcast_command(config, lifecycle_message.build_host_request_payload(config.site, target_role, {
        action = "reboot_host",
        request_id = request_id,
        reason = reason,
        requested_by_role = config.role,
        requested_by_site = config.site,
    }))
    if not sent.ok then
        return sent
    end

    local waited = command_network.wait_for_result(config, sent.value.msg_id, HOST_REBOOT_ACK_TIMEOUT_SECONDS, {
        logger = logger,
        inbox = runtime.inbox,
        on_unmatched = function(unmatched)
            local handled = dispatch_incoming(config, runtime, unmatched, logger)
            if not handled.ok then
                return handled
            end

            return result.ok(type(handled.value) == "table" and handled.value.handled == true)
        end,
    })
    if not waited.ok then
        return waited
    end

    if waited.value.payload.ok ~= true then
        return result.err(waited.value.payload.error, waited.value.payload.details)
    end

    return result.ok(type(waited.value.payload.result) == "table" and waited.value.payload.result or {
        role = target_role,
    })
end

---@param config table
---@param runtime table
---@param request table
---@param requester table
---@param logger table?
---@return SgcResult
function controller.orchestrate_reboot_request(config, runtime, request, requester, logger)
    local target_roles = resolve_restart_target_roles(runtime, request)
    local includes_gate_controller = false
    local local_reboot_requested = false
    for _, role in ipairs(target_roles) do
        if role == "gate_controller" then
            includes_gate_controller = true
        end
        if role == config.role then
            local_reboot_requested = true
        end
    end

    if includes_gate_controller and gate_busy_for_restart(runtime) then
        return result.err("restart_blocked_gate_busy", {
            site = config.site,
        })
    end

    local acknowledged_roles = {}
    local skipped_roles = {}
    local failed_roles = {}
    for _, role in ipairs(target_roles) do
        if role ~= config.role then
            local role_request_id = request.request_id .. ":" .. role
            local rebooted = request_remote_host_reboot(config, runtime, role, role_request_id, request.reason, logger)
            if rebooted.ok then
                acknowledged_roles[#acknowledged_roles + 1] = role
            elseif request.scope == "site" and not has_discovered_role(runtime, role) then
                skipped_roles[#skipped_roles + 1] = {
                    role = role,
                    error = rebooted.error,
                }
            else
                failed_roles[#failed_roles + 1] = {
                    role = role,
                    error = rebooted.error,
                    details = rebooted.details,
                }
            end
        end
    end

    if #failed_roles > 0 then
        return result.err("host_restart_partial_failure", {
            requested_roles = target_roles,
            acknowledged_roles = acknowledged_roles,
            skipped_roles = skipped_roles,
            failed_roles = failed_roles,
        })
    end

    local local_intent = nil
    if local_reboot_requested then
        local built_intent = host_lifecycle.build_intent(config, {
            action = "reboot_host",
            request_id = request.request_id .. ":site_controller",
            reason = request.reason,
            requested_by_role = requester.requested_by_role,
            requested_by_site = requester.requested_by_site,
        })
        if not built_intent.ok then
            return built_intent
        end

        local_intent = built_intent.value
        runtime.maintenance = {
            action = request.action,
            reason = request.reason,
        }
        render_monitor(config, runtime)
        local published = publish_site_status(config, runtime, true)
        if not published.ok then
            return published
        end
    end

    return result.ok({
        action = request.action,
        request_id = request.request_id,
        scope = request.scope,
        requested_roles = target_roles,
        acknowledged_roles = acknowledged_roles,
        skipped_roles = skipped_roles,
        local_reboot_requested = local_reboot_requested,
        local_intent = local_intent,
    })
end

---@param config table
---@param runtime table
---@param incoming table
---@param logger table?
---@return SgcResult
function controller.handle_lifecycle_request(config, runtime, incoming, logger)
    if incoming.envelope.type ~= "command" then
        return result.ok({
            handled = false,
        })
    end

    if host_lifecycle.is_targeted_request(config, incoming) then
        return host_lifecycle.handle_command(config, incoming, logger, {
            before_reboot = function(intent)
                runtime.maintenance = {
                    action = intent.action,
                    reason = intent.reason,
                }
                render_monitor(config, runtime)
                return publish_site_status(config, runtime, true)
            end,
        })
    end

    if not is_targeted_payload(incoming.envelope.payload, "site_controller", config.site, "site_lifecycle_request") then
        return result.ok({
            handled = false,
        })
    end

    local validated = lifecycle_message.validate_site_request_payload(incoming.envelope.payload)
    local request_id = type(incoming.envelope.payload.command) == "table" and incoming.envelope.payload.command.request_id
        or incoming.envelope.msg_id
    if not validated.ok then
        return command_network.send_result_reply(
            config,
            incoming.sender_id,
            incoming.envelope,
            command_message.build_result_payload(request_id, result.err(validated.error, validated.details))
        )
    end

    local request = validated.value.command
    local orchestrated = controller.orchestrate_reboot_request(config, runtime, request, {
        requested_by_role = incoming.envelope.role,
        requested_by_site = incoming.envelope.site,
    }, logger)
    if not orchestrated.ok then
        return command_network.send_result_reply(
            config,
            incoming.sender_id,
            incoming.envelope,
            command_message.build_result_payload(request_id, orchestrated)
        )
    end

    local reply = command_network.send_result_reply(
        config,
        incoming.sender_id,
        incoming.envelope,
        command_message.build_result_payload(request_id, result.ok(orchestrated.value))
    )
    if not reply.ok then
        if orchestrated.value.local_intent ~= nil then
            return host_lifecycle.reboot_local(config, logger, orchestrated.value.local_intent)
        end

        return reply
    end

    if orchestrated.value.local_intent ~= nil then
        return host_lifecycle.reboot_local(config, logger, orchestrated.value.local_intent)
    end

    return result.ok({
        handled = true,
    })
end

---@param config table
---@param runtime table
---@return SgcResult
local function ensure_address_book_available(config, runtime)
    if runtime.address_book ~= nil and runtime.address_book.book ~= nil then
        return result.ok(runtime.address_book.book)
    end

    local fetched = address_book_client.fetch_remote(config, {
        inbox = runtime.inbox,
    })
    if not fetched.ok then
        return fetched
    end

    runtime.address_book = {
        mode = "client",
        availability = "available",
        cache_loaded = false,
        fetched_remote = true,
        book = fetched.value,
    }
    render_monitor(config, runtime)
    return result.ok(fetched.value)
end

---@param config table
---@param runtime table
---@param book SgcAddressBook
---@return SgcResult
local function apply_pushed_address_book(config, runtime, book)
    local saved = address_book_client.save_cached(config, book)
    if not saved.ok then
        return saved
    end

    runtime.address_book = {
        mode = "client",
        availability = "available",
        cache_loaded = false,
        fetched_remote = true,
        book = book,
    }
    render_monitor(config, runtime)
    publish_site_status(config, runtime, true)
    return result.ok({
        applied = true,
        revision = book.revision,
    })
end

---@param config table
---@param runtime table
---@param incoming table
---@return SgcResult
function controller.handle_address_book_request(config, runtime, incoming)
    if incoming.protocol ~= constants.PROTOCOLS.addressbook or incoming.envelope.type ~= "addressbook" then
        return result.ok({
            handled = false,
        })
    end

    if not address_book_message.is_targeted_request(incoming.envelope.payload, "site_controller", config.site) then
        return result.ok({
            handled = false,
        })
    end

    local validated = address_book_message.validate_get_book_request(incoming.envelope.payload)
    local request_id = type(incoming.envelope.payload.request_id) == "string" and incoming.envelope.payload.request_id
        or incoming.envelope.msg_id
    if not validated.ok then
        return address_book_network.send_result(
            config,
            incoming.sender_id,
            incoming.envelope,
            address_book_message.build_book_result(request_id, result.err(validated.error, validated.details))
        )
    end

    local resolved_book = ensure_address_book_available(config, runtime)
    return address_book_network.send_result(
        config,
        incoming.sender_id,
        incoming.envelope,
        address_book_message.build_book_result(request_id, resolved_book)
    )
end

---@param config table
---@param runtime table
---@param incoming table
---@return SgcResult
function controller.handle_address_book_push(config, runtime, incoming)
    if incoming.protocol ~= constants.PROTOCOLS.addressbook or incoming.envelope.type ~= "addressbook" then
        return result.ok({
            handled = false,
        })
    end

    local validated = address_book_message.validate_push_book_payload(incoming.envelope.payload)
    if not validated.ok then
        if type(incoming.envelope.payload) ~= "table" or incoming.envelope.payload.kind ~= "push_book" then
            return result.ok({
                handled = false,
            })
        end

        return validated
    end

    local current_revision = runtime.address_book ~= nil
        and runtime.address_book.book ~= nil
        and runtime.address_book.book.revision
        or nil
    if type(current_revision) == "number" and current_revision >= validated.value.book.revision then
        return result.ok({
            handled = true,
            applied = false,
            revision = current_revision,
        })
    end

    local applied = apply_pushed_address_book(config, runtime, validated.value.book)
    if not applied.ok then
        return applied
    end

    return result.ok({
        handled = true,
        applied = true,
        revision = validated.value.book.revision,
    })
end

---@param config table
---@param runtime table
---@param incoming table
---@param logger table?
---@return SgcResult
dispatch_incoming = function(config, runtime, incoming, logger)
    local handled = controller.handle_service_hello(config, runtime, incoming)
    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = controller.handle_lifecycle_request(config, runtime, incoming, logger)
    end

    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = controller.handle_address_book_request(config, runtime, incoming)
    end

    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = controller.handle_address_book_push(config, runtime, incoming)
    end

    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = controller.handle_gate_state_update(config, runtime, incoming)
    end

    if handled.ok and type(handled.value) == "table" and handled.value.handled == false then
        handled = controller.handle_command(config, runtime, incoming, logger)
    end

    return handled
end

---@param config table
---@param runtime table
---@param expected_reply_to string
---@param timeout_seconds number?
---@param logger table?
---@return SgcResult
wait_for_gate_result = function(config, runtime, expected_reply_to, timeout_seconds, logger)
    local active_logger = normalize_logger(logger)
    local waited = command_network.wait_for_result(config, expected_reply_to, timeout_seconds, {
        logger = active_logger,
        inbox = runtime.inbox,
        before_receive = function()
            return poll_local_admin_inputs(config, runtime, active_logger)
        end,
        poll_interval_seconds = ADMIN_INPUT_POLL_INTERVAL_SECONDS,
        on_unmatched = function(incoming)
            local handled = dispatch_incoming(config, runtime, incoming, active_logger)
            if not handled.ok then
                record_internal_error(runtime, "nested_dispatch", handled)
                active_logger:error("site controller nested handling failed", {
                    error = handled.error,
                    details = handled.details,
                })
                return handled
            end

            if type(handled.value) == "table" and handled.value.handled == false then
                active_logger:debug("queueing unrelated envelope while waiting for gate reply", {
                    msg_id = incoming.envelope.msg_id,
                    protocol = incoming.protocol,
                    role = incoming.envelope.role,
                })
                return result.ok(false)
            end

            return result.ok(true)
        end,
    })
    if not waited.ok then
        return waited
    end

    if waited.value.payload.ok == true then
        local gate_result = type(waited.value.payload.result) == "table" and waited.value.payload.result or nil
        record_gate_contact(runtime, gate_result ~= nil and gate_result.state or nil, nil)
    end

    return waited
end

---@param config table
---@param book SgcAddressBook
---@param request_payload table
---@return SgcResult
function controller.plan_command(config, book, request_payload)
    return site_command.plan(book, config.site, request_payload)
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
    if runtime.hello ~= nil then
        local announced = transport.broadcast(protocols.for_type(runtime.hello.type), runtime.hello)
        if not announced.ok then
            active_logger:warn("failed to broadcast hello", announced.details)
        end
    end

    active_logger:info(log_messages.ready())
    render_monitor(config, runtime)
    local published = publish_site_status(config, runtime, true)
    if not published.ok then
        active_logger:warn("site status publish failed", {
            error = published.error,
            details = published.details,
        })
    end

    local admin_input_receive_options = {
        before_receive = function()
            return poll_local_admin_inputs(config, runtime, active_logger)
        end,
        poll_interval_seconds = ADMIN_INPUT_POLL_INTERVAL_SECONDS,
    }

    while true do
        local received = net_inbox.receive_next(
            config,
            runtime.inbox,
            SITE_STATE_POLL_INTERVAL_SECONDS,
            nil,
            active_logger,
            admin_input_receive_options
        )
        if not received.ok then
            if received.error == "receive_timeout" then
                local recovered = recover_address_book(config, runtime)
                if not recovered.ok then
                    active_logger:warn("address book recovery failed", {
                        error = recovered.error,
                        details = recovered.details,
                    })
                end

                local heartbeat = publish_site_status(config, runtime, false)
                if not heartbeat.ok then
                    active_logger:warn("site status heartbeat failed", {
                        error = heartbeat.error,
                        details = heartbeat.details,
                    })
                else
                    clear_internal_error(runtime)
                end
            else
                active_logger:error("site command receive failed", {
                    error = received.error,
                    details = received.details,
                })
                return received
            end
        else
            local handled = dispatch_incoming(config, runtime, received.value, active_logger)

            if not handled.ok then
                record_internal_error(runtime, "dispatch", handled)
                active_logger:error("site controller handling failed", {
                    error = handled.error,
                    details = handled.details,
                })
            elseif type(handled.value) == "table" and handled.value.handled == false then
                active_logger:debug("ignoring unrelated envelope", {
                    msg_id = received.value.envelope.msg_id,
                    protocol = received.value.protocol,
                    role = received.value.envelope.role,
                })
                clear_internal_error(runtime)
            else
                clear_internal_error(runtime)
            end
        end
    end
end

return controller
