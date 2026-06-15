local net_message = require("net.message")
local result = require("core.result")
local site_state = require("site.state")
local validate = require("core.validate")

local message = {}

---@param payload any
---@return SgcResult
function message.validate_status_payload(payload)
    local errors = {}
    net_message.validate_snapshot_payload(payload, errors, "site_status", "status", site_state.validate_status)

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param status SgcSiteStatus
---@param sequence integer
---@param emitted_at integer
---@return table
function message.build_status_payload(status, sequence, emitted_at)
    return net_message.build_snapshot_payload("site_status", "status", status, sequence, emitted_at)
end

return message
