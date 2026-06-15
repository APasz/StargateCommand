local time = require("core.time")
local result = require("core.result")
local validate = require("core.validate")

local site_state = {}

---@param config table
---@return table
function site_state.new(config)
    return {
        site = config.site,
        role = config.role,
        started_at = time.now_ms(),
        modems = {
            site = false,
            intersite = false,
        },
    }
end

---@param candidate any
---@return SgcResult
function site_state.validate_status(candidate)
    local errors = {}
    if not validate.expect_table(errors, "site_status", candidate) then
        return validate.result(errors)
    end

    if validate.expect_string(errors, "site_status.site", candidate.site, false) then
        if not validate.is_site_id(candidate.site) then
            validate.push_error(errors, "site_status.site", "invalid site id")
        end
    end

    validate.expect_string(errors, "site_status.role", candidate.role, false)
    validate.expect_boolean(errors, "site_status.healthy", candidate.healthy)
    validate.expect_integer(errors, "site_status.warnings_count", candidate.warnings_count)
    validate.expect_boolean(errors, "site_status.address_book_available", candidate.address_book_available)

    if candidate.address_book_error ~= nil then
        validate.expect_string(errors, "site_status.address_book_error", candidate.address_book_error, false)
    end

    if candidate.address_book_revision ~= nil then
        validate.expect_integer(errors, "site_status.address_book_revision", candidate.address_book_revision)
    end

    if candidate.last_internal_error ~= nil then
        validate.expect_string(errors, "site_status.last_internal_error", candidate.last_internal_error, false)
    end

    if candidate.started_at ~= nil then
        validate.expect_integer(errors, "site_status.started_at", candidate.started_at)
    end

    if candidate.maintenance_mode ~= nil then
        validate.expect_boolean(errors, "site_status.maintenance_mode", candidate.maintenance_mode)
    end

    if candidate.maintenance_reason ~= nil then
        validate.expect_string(errors, "site_status.maintenance_reason", candidate.maintenance_reason, false)
    end

    if candidate.maintenance_action ~= nil then
        validate.expect_string(errors, "site_status.maintenance_action", candidate.maintenance_action, false)
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(candidate)
end

---@param left SgcSiteStatus?
---@param right SgcSiteStatus?
---@return boolean
function site_state.same_status(left, right)
    if left == right then
        return true
    end

    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end

    return left.site == right.site
        and left.role == right.role
        and left.healthy == right.healthy
        and left.warnings_count == right.warnings_count
        and left.address_book_available == right.address_book_available
        and left.address_book_error == right.address_book_error
        and left.address_book_revision == right.address_book_revision
        and left.last_internal_error == right.last_internal_error
        and left.started_at == right.started_at
        and left.maintenance_mode == right.maintenance_mode
        and left.maintenance_reason == right.maintenance_reason
        and left.maintenance_action == right.maintenance_action
end

return site_state
