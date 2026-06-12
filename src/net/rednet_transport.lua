local auth = require("net.auth")
local envelope = require("net.envelope")
local protocols = require("net.protocols")
local result = require("core.result")
local validate = require("core.validate")

local transport = {}

---@return SgcResult
local function ensure_rednet()
    if rednet == nil then
        return result.err("rednet_unavailable")
    end

    return result.ok(true)
end

---@param side string?
---@return SgcResult
function transport.open(side)
    local available = ensure_rednet()
    if not available.ok then
        return available
    end

    if side == nil then
        return result.err("missing_modem_side")
    end

    if type(rednet.isOpen) == "function" and rednet.isOpen(side) then
        return result.ok(true, { side = side })
    end

    local ok, open_error = pcall(rednet.open, side)
    if not ok then
        return result.err("rednet_open_failed", {
            side = side,
            cause = tostring(open_error),
        })
    end

    return result.ok(true, { side = side })
end

---@param receiver_id integer
---@param protocol_name SgcProtocol
---@param envelope_message SgcEnvelope
---@return SgcResult
function transport.send(receiver_id, protocol_name, envelope_message)
    local available = ensure_rednet()
    if not available.ok then
        return available
    end

    if not validate.is_integer(receiver_id) then
        return result.err("invalid_receiver_id", {
            receiver_id = receiver_id,
        })
    end

    if not protocols.is_valid(protocol_name) then
        return result.err("invalid_protocol", {
            protocol = protocol_name,
        })
    end

    local validated = envelope.validate(envelope_message)
    if not validated.ok then
        return validated
    end

    local ok, sent = pcall(rednet.send, receiver_id, envelope_message, protocol_name)
    if not ok then
        return result.err("rednet_send_failed", {
            receiver_id = receiver_id,
            protocol = protocol_name,
            cause = tostring(sent),
        })
    end

    return result.ok(sent == true)
end

---@param protocol_name SgcProtocol
---@param envelope_message SgcEnvelope
---@return SgcResult
function transport.broadcast(protocol_name, envelope_message)
    local available = ensure_rednet()
    if not available.ok then
        return available
    end

    if not protocols.is_valid(protocol_name) then
        return result.err("invalid_protocol", {
            protocol = protocol_name,
        })
    end

    local validated = envelope.validate(envelope_message)
    if not validated.ok then
        return validated
    end

    local ok, send_error = pcall(rednet.broadcast, envelope_message, protocol_name)
    if not ok then
        return result.err("rednet_broadcast_failed", {
            protocol = protocol_name,
            cause = tostring(send_error),
        })
    end

    return result.ok(true)
end

---@param accepted_protocols string[]?
---@param protocol_name string
---@return boolean
local function protocol_allowed(accepted_protocols, protocol_name)
    if accepted_protocols == nil then
        return protocols.is_valid(protocol_name)
    end

    for _, accepted in ipairs(accepted_protocols) do
        if accepted == protocol_name then
            return true
        end
    end

    return false
end

---@param config table
---@param timeout number?
---@param accepted_protocols string[]?
---@return SgcResult
function transport.receive(config, timeout, accepted_protocols)
    local available = ensure_rednet()
    if not available.ok then
        return available
    end

    local ok, sender_id, message, protocol_name = pcall(rednet.receive, nil, timeout)
    if not ok then
        return result.err("rednet_receive_failed", {
            cause = tostring(sender_id),
        })
    end

    if sender_id == nil then
        return result.err("receive_timeout")
    end

    if type(protocol_name) ~= "string" or not protocol_allowed(accepted_protocols, protocol_name) then
        return result.err("unexpected_protocol", {
            sender_id = sender_id,
            protocol = protocol_name,
        })
    end

    if type(message) ~= "table" then
        return result.err("invalid_message_body", {
            sender_id = sender_id,
            protocol = protocol_name,
        })
    end

    local authorization = auth.authorize_sender(config, sender_id)
    if not authorization.ok then
        return authorization
    end

    local validation = envelope.validate(message)
    if not validation.ok then
        return validation
    end

    return result.ok({
        sender_id = sender_id,
        protocol = protocol_name,
        envelope = message,
    })
end

return transport

