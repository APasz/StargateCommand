local constants = require("core.constants")
local envelope = require("net.envelope")
local inbox = require("net.inbox")
local result = require("core.result")
local transport = require("net.rednet_transport")

local network = {}

---@param config table
---@param payload table
---@return SgcResult
function network.broadcast_payload(config, payload)
    local built = envelope.new("addressbook", config.site, config.role, payload)
    if not built.ok then
        return built
    end

    local sent = transport.broadcast(constants.PROTOCOLS.addressbook, built.value)
    if not sent.ok then
        return sent
    end

    return result.ok(built.value)
end

---@param config table
---@param payload table
---@return SgcResult
function network.broadcast_request(config, payload)
    return network.broadcast_payload(config, payload)
end

---@param config table
---@param receiver_id integer
---@param request_envelope SgcEnvelope
---@param payload table
---@return SgcResult
function network.send_result(config, receiver_id, request_envelope, payload)
    local reply = envelope.reply(request_envelope, config.site, config.role, payload)
    if not reply.ok then
        return reply
    end

    return transport.send(receiver_id, constants.PROTOCOLS.addressbook, reply.value)
end

---@param config table
---@param expected_reply_to string
---@param timeout_seconds number?
---@param options table?
---@return SgcResult
function network.wait_for_result(config, expected_reply_to, timeout_seconds, options)
    local active_options = type(options) == "table" and options or {}
    local queue = type(active_options.inbox) == "table" and active_options.inbox or inbox.new()

    local received = inbox.wait_for_match(
        config,
        queue,
        timeout_seconds,
        nil,
        function(incoming)
            return incoming.protocol == constants.PROTOCOLS.addressbook
                and incoming.envelope.type == "result"
                and incoming.envelope.reply_to == expected_reply_to
        end,
        active_options.logger,
        active_options.on_unmatched
    )
    if not received.ok then
        if received.error == "receive_timeout" then
            return result.err("address_book_timeout", {
                reply_to = expected_reply_to,
            })
        end

        return received
    end

    return result.ok(received.value)
end

return network
