local constants = require("core.constants")
local result = require("core.result")
local validate = require("core.validate")

local event = {}

---@param payload any
---@return SgcResult
function event.validate_payload(payload)
    local errors = {}
    if not validate.expect_table(errors, "payload", payload) then
        return validate.result(errors)
    end

    if validate.expect_string(errors, "payload.kind", payload.kind, false) and payload.kind ~= "gate_event" then
        validate.push_error(errors, "payload.kind", "unexpected event payload kind")
    end

    validate.expect_integer(errors, "payload.sequence", payload.sequence)
    validate.expect_integer(errors, "payload.emitted_at", payload.emitted_at)

    if validate.expect_string(errors, "payload.signal", payload.signal, false)
        and not constants.GATE_EVENT_SIGNAL_SET[payload.signal]
    then
        validate.push_error(errors, "payload.signal", "unsupported gate event signal")
    end

    if payload.details ~= nil then
        validate.expect_table(errors, "payload.details", payload.details)
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param signal_name SgcGateEventSignalName
---@param sequence integer
---@param emitted_at integer
---@param details table?
---@return table
function event.build_payload(signal_name, sequence, emitted_at, details)
    return {
        kind = "gate_event",
        sequence = sequence,
        emitted_at = emitted_at,
        signal = signal_name,
        details = details,
    }
end

return event
