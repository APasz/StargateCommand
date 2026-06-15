local command_message = require("command.message")
local constants = require("core.constants")
local envelope = require("net.envelope")
local inbox = require("net.inbox")
local protocols = require("net.protocols")
local result = require("core.result")
local transport = require("net.rednet_transport")

local network = {}

local NOOP_LOGGER = {
    debug = function() end,
}

---@param logger table?
---@return table
local function normalize_logger(logger)
    return logger or NOOP_LOGGER
end

---@param config table
---@param payload table
---@return SgcResult
function network.broadcast_command(config, payload)
    local built = envelope.new("command", config.site, config.role, payload)
    if not built.ok then
        return built
    end

    local sent = transport.broadcast(protocols.for_type("command"), built.value)
    if not sent.ok then
        return sent
    end

    return result.ok(built.value)
end

---@param config table
---@param receiver_id integer
---@param request_envelope SgcEnvelope
---@param payload table
---@return SgcResult
function network.send_result_reply(config, receiver_id, request_envelope, payload)
    local reply = envelope.reply(request_envelope, config.site, config.role, payload)
    if not reply.ok then
        return reply
    end

    return transport.send(receiver_id, protocols.for_type(reply.value.type), reply.value)
end

---@param config table
---@param expected_reply_to string
---@param timeout_seconds number?
---@param options table?
---@return SgcResult
function network.wait_for_result(config, expected_reply_to, timeout_seconds, options)
    local active_options = type(options) == "table" and options or {}
    local active_logger = normalize_logger(active_options.logger)
    local queue = type(active_options.inbox) == "table" and active_options.inbox or inbox.new()

    local received = inbox.wait_for_match(
        config,
        queue,
        timeout_seconds,
        nil,
        function(incoming)
            return incoming.protocol == constants.PROTOCOLS.command
                and incoming.envelope.type == "result"
                and incoming.envelope.reply_to == expected_reply_to
        end,
        active_logger,
        active_options.on_unmatched
    )
    if not received.ok then
        if received.error == "receive_timeout" then
            return result.err("command_timeout", {
                reply_to = expected_reply_to,
            })
        end

        return received
    end

    local validated = command_message.validate_result_payload(received.value.envelope.payload)
    if not validated.ok then
        return validated
    end

    return result.ok({
        sender_id = received.value.sender_id,
        envelope = received.value.envelope,
        payload = validated.value,
    })
end

return network
