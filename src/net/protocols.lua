local constants = require("core.constants")

local protocols = {}

protocols.names = constants.PROTOCOLS

---@param protocol_name string
---@return boolean
function protocols.is_valid(protocol_name)
    return constants.PROTOCOL_SET[protocol_name] == true
end

---@param envelope_type SgcEnvelopeType
---@return SgcProtocol?
function protocols.for_type(envelope_type)
    if envelope_type == "hello" then
        return constants.PROTOCOLS.hello
    end

    if envelope_type == "event" then
        return constants.PROTOCOLS.event
    end

    if envelope_type == "state" then
        return constants.PROTOCOLS.state
    end

    if envelope_type == "addressbook" then
        return constants.PROTOCOLS.addressbook
    end

    if envelope_type == "command" or envelope_type == "result" then
        return constants.PROTOCOLS.command
    end

    return nil
end

---@return SgcProtocol[]
function protocols.all()
    return {
        constants.PROTOCOLS.hello,
        constants.PROTOCOLS.command,
        constants.PROTOCOLS.event,
        constants.PROTOCOLS.state,
        constants.PROTOCOLS.addressbook,
        constants.PROTOCOLS.update,
    }
end

return protocols

