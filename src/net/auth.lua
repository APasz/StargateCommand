local result = require("core.result")

local auth = {}

---@param config table
---@param sender_id integer
---@return boolean
function auth.is_sender_allowed(config, sender_id)
    local security = config.security or {}
    if security.allowlist_enabled ~= true then
        return true
    end

    for _, allowed_id in ipairs(security.allowed_computer_ids or {}) do
        if allowed_id == sender_id then
            return true
        end
    end

    return false
end

---@param config table
---@param sender_id integer
---@return SgcResult
function auth.authorize_sender(config, sender_id)
    if auth.is_sender_allowed(config, sender_id) then
        return result.ok(true)
    end

    return result.err("sender_not_allowed", {
        sender_id = sender_id,
    })
end

---@param envelope_message SgcEnvelope
---@param _shared_secret string?
---@return SgcEnvelope
function auth.attach_placeholder(envelope_message, _shared_secret)
    return envelope_message
end

return auth

