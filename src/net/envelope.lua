local constants = require("core.constants")
local result = require("core.result")
local time = require("core.time")
local uuid = require("core.uuid")
local validate = require("core.validate")

local envelope = {}

---@param value any
---@return boolean
local function is_payload(value)
    return type(value) == "table"
end

---@param candidate table
---@return SgcResult
function envelope.validate(candidate)
    local errors = {}

    if not validate.expect_table(errors, "envelope", candidate) then
        return validate.result(errors)
    end

    if not validate.expect_integer(errors, "envelope.schema", candidate.schema) then
        return validate.result(errors)
    end

    if candidate.schema ~= constants.SCHEMA_VERSION then
        validate.push_error(errors, "envelope.schema", "unsupported schema version")
    end

    if validate.expect_string(errors, "envelope.type", candidate.type, false) then
        if not constants.ENVELOPE_TYPE_SET[candidate.type] then
            validate.push_error(errors, "envelope.type", "unsupported envelope type")
        end
    end

    validate.expect_string(errors, "envelope.msg_id", candidate.msg_id, false)

    if validate.expect_string(errors, "envelope.site", candidate.site, false) then
        if not validate.is_site_id(candidate.site) then
            validate.push_error(errors, "envelope.site", "invalid site id")
        end
    end

    if validate.expect_string(errors, "envelope.role", candidate.role, false) then
        if not constants.ROLE_SET[candidate.role] then
            validate.push_error(errors, "envelope.role", "unsupported role")
        end
    end

    validate.expect_integer(errors, "envelope.sent_at", candidate.sent_at)

    if candidate.reply_to ~= nil then
        validate.expect_string(errors, "envelope.reply_to", candidate.reply_to, false)
    end

    if not is_payload(candidate.payload) then
        validate.push_error(errors, "envelope.payload", "expected table payload")
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(candidate)
end

---@param envelope_type SgcEnvelopeType
---@param site string
---@param role SgcRole
---@param payload table?
---@param options table?
---@return SgcResult
function envelope.new(envelope_type, site, role, payload, options)
    local candidate = {
        schema = constants.SCHEMA_VERSION,
        type = envelope_type,
        msg_id = options and options.msg_id or uuid.new("msg"),
        site = site,
        role = role,
        sent_at = options and options.sent_at or time.now_ms(),
        reply_to = options and options.reply_to or nil,
        payload = payload or {},
    }

    local validation = envelope.validate(candidate)
    if not validation.ok then
        return validation
    end

    return result.ok(candidate)
end

---@param request SgcEnvelope
---@param site string
---@param role SgcRole
---@param payload table?
---@return SgcResult
function envelope.reply(request, site, role, payload)
    return envelope.new("result", site, role, payload or {}, {
        reply_to = request.msg_id,
    })
end

return envelope

