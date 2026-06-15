local command_message = require("command.message")
local command_network = require("command.network")
local constants = require("core.constants")
local lifecycle_message = require("lifecycle.message")
local net_message = require("net.message")
local persistence = require("core.persistence")
local result = require("core.result")
local time = require("core.time")
local validate = require("core.validate")

local host = {}
local INTENT_SCHEMA_VERSION = 1

local NOOP_LOGGER = {
    info = function() end,
    warn = function() end,
    error = function() end,
}

---@param logger table?
---@return table
local function normalize_logger(logger)
    return logger or NOOP_LOGGER
end

---@param config table
---@return string
function host.intent_path(config)
    local lifecycle_config = type(config.lifecycle) == "table" and config.lifecycle or nil
    if lifecycle_config ~= nil and type(lifecycle_config.intent_path) == "string" and lifecycle_config.intent_path ~= "" then
        return lifecycle_config.intent_path
    end

    return constants.DEFAULT_HOST_LIFECYCLE_INTENT_PATH
end

---@param path string
---@return SgcResult
local function delete_file(path)
    if fs == nil or type(fs.exists) ~= "function" or type(fs.delete) ~= "function" then
        return result.err("filesystem_unavailable", {
            path = path,
        })
    end

    if not fs.exists(path) then
        return result.ok(false)
    end

    local ok, delete_error = pcall(fs.delete, path)
    if not ok then
        return result.err("file_delete_failed", {
            path = path,
            cause = tostring(delete_error),
        })
    end

    return result.ok(true)
end

---@param candidate any
---@return SgcResult
local function validate_intent(candidate)
    local errors = {}
    if not validate.expect_table(errors, "intent", candidate) then
        return validate.result(errors)
    end

    validate.expect_integer(errors, "intent.schema", candidate.schema)
    if candidate.schema ~= INTENT_SCHEMA_VERSION then
        validate.push_error(errors, "intent.schema", "unsupported lifecycle intent schema")
    end

    if validate.expect_string(errors, "intent.site", candidate.site, false) and not validate.is_site_id(candidate.site) then
        validate.push_error(errors, "intent.site", "invalid site id")
    end

    if validate.expect_string(errors, "intent.role", candidate.role, false) and constants.ROLE_SET[candidate.role] ~= true then
        validate.push_error(errors, "intent.role", "unsupported role")
    end

    validate.expect_string(errors, "intent.action", candidate.action, false)
    validate.expect_integer(errors, "intent.requested_at", candidate.requested_at)

    if candidate.request_id ~= nil then
        validate.expect_string(errors, "intent.request_id", candidate.request_id, false)
    end

    if candidate.reason ~= nil then
        validate.expect_string(errors, "intent.reason", candidate.reason, false)
    end

    if candidate.requested_by_role ~= nil then
        if validate.expect_string(errors, "intent.requested_by_role", candidate.requested_by_role, false)
            and constants.ROLE_SET[candidate.requested_by_role] ~= true
        then
            validate.push_error(errors, "intent.requested_by_role", "unsupported role")
        end
    end

    if candidate.requested_by_site ~= nil then
        if validate.expect_string(errors, "intent.requested_by_site", candidate.requested_by_site, false)
            and not validate.is_site_id(candidate.requested_by_site)
        then
            validate.push_error(errors, "intent.requested_by_site", "invalid site id")
        end
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(candidate)
end

---@param config table
---@param request table
---@return SgcResult
function host.build_intent(config, request)
    if os == nil or type(os.reboot) ~= "function" then
        return result.err("reboot_unavailable", {
            role = config.role,
            site = config.site,
        })
    end

    local intent = {
        schema = INTENT_SCHEMA_VERSION,
        site = config.site,
        role = config.role,
        action = request.action,
        request_id = request.request_id,
        reason = request.reason,
        requested_at = time.now_ms(),
        requested_by_role = request.requested_by_role,
        requested_by_site = request.requested_by_site,
    }

    return validate_intent(intent)
end

---@param config table
---@param intent table
---@return SgcResult
function host.persist_intent(config, intent)
    return persistence.save_serialized_table(host.intent_path(config), intent)
end

---@param config table
---@return SgcResult
function host.consume_pending_intent(config)
    local path = host.intent_path(config)
    if not persistence.exists(path) then
        return result.ok(nil)
    end

    local loaded = persistence.load_serialized_table(path)
    local deleted = delete_file(path)
    if not deleted.ok then
        return deleted
    end

    if not loaded.ok then
        return result.ok(nil, {
            cleared_invalid = true,
            error = loaded.error,
            details = loaded.details,
        })
    end

    local validated = validate_intent(loaded.value)
    if not validated.ok then
        return result.ok(nil, {
            cleared_invalid = true,
            error = validated.error,
            details = validated.details,
        })
    end

    return result.ok(validated.value)
end

---@param logger table?
---@param intent table
local function reboot_now(logger, intent)
    normalize_logger(logger):warn("rebooting host for lifecycle request", {
        action = intent.action,
        request_id = intent.request_id,
        reason = intent.reason,
    })
    os.reboot()
end

---@param config table
---@param logger table?
---@param intent table
---@return SgcResult
function host.reboot_local(config, logger, intent)
    local persisted = host.persist_intent(config, intent)
    if not persisted.ok then
        return persisted
    end

    reboot_now(logger, intent)
    return result.ok({
        reboot_requested = true,
        intent_path = host.intent_path(config),
    })
end

---@param config table
---@param intent table
---@return SgcResult
local function persist_reboot_commit(config, intent)
    return host.persist_intent(config, intent)
end

---@param config table
---@param incoming table
---@return boolean
function host.is_targeted_request(config, incoming)
    return incoming.envelope.type == "command"
        and net_message.is_targeted_routed_payload(
            incoming.envelope.payload,
            config.role,
            config.site,
            "host_lifecycle_request"
        )
end

---@param request_id string
---@param action string
---@param config table
---@return table
local function build_success_payload(request_id, action, config)
    return command_message.build_result_payload(request_id, result.ok({
        action = action,
        request_id = request_id,
        scheduled = true,
        role = config.role,
        site = config.site,
    }))
end

---@param config table
---@param incoming table
---@param request_id string
---@param operation SgcResult
---@return SgcResult
local function reply_with_operation(config, incoming, request_id, operation)
    local replied = command_network.send_result_reply(
        config,
        incoming.sender_id,
        incoming.envelope,
        command_message.build_result_payload(request_id, operation)
    )
    if not replied.ok then
        return replied
    end

    return result.ok({
        handled = true,
        replied = true,
    })
end

---@param config table
---@param incoming table
---@param logger table?
---@return SgcResult
function host.handle_command(config, incoming, logger, options)
    if incoming.envelope.type ~= "command" then
        return result.ok({
            handled = false,
        })
    end

    if not host.is_targeted_request(config, incoming) then
        return result.ok({
            handled = false,
        })
    end

    local validated = lifecycle_message.validate_host_request_payload(incoming.envelope.payload)
    local request_id = type(incoming.envelope.payload.command) == "table"
            and incoming.envelope.payload.command.request_id
        or incoming.envelope.msg_id
    if not validated.ok then
        return reply_with_operation(config, incoming, request_id, result.err(validated.error, validated.details))
    end

    local intent = host.build_intent(config, validated.value.command)
    if not intent.ok then
        return reply_with_operation(config, incoming, request_id, intent)
    end

    local committed = persist_reboot_commit(config, intent.value)
    if not committed.ok then
        return reply_with_operation(config, incoming, request_id, committed)
    end

    local before_reboot = type(options) == "table" and options.before_reboot or nil
    if type(before_reboot) == "function" then
        local prepared = before_reboot(intent.value)
        if not result.is_result(prepared) then
            prepared = result.ok(prepared)
        end
        if not prepared.ok then
            return reply_with_operation(config, incoming, request_id, prepared)
        end
    end

    local replied = command_network.send_result_reply(
        config,
        incoming.sender_id,
        incoming.envelope,
        build_success_payload(request_id, validated.value.command.action, config)
    )
    if not replied.ok then
        reboot_now(logger, intent.value)
        return replied
    end

    reboot_now(logger, intent.value)
    return result.ok({
        handled = true,
        reboot_requested = true,
    })
end

return host
