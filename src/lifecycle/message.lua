local constants = require("core.constants")
local net_message = require("net.message")
local result = require("core.result")
local validate = require("core.validate")

local message = {}

local VALID_SITE_ACTIONS = {
    reboot_hosts = true,
}

local VALID_SITE_SCOPES = {
    role = true,
    site = true,
}

local VALID_HOST_ACTIONS = {
    reboot_host = true,
}

---@param role any
---@return boolean
local function is_valid_role(role)
    return type(role) == "string" and constants.ROLE_SET[role] == true
end

---@param candidate table
---@param errors table[]
---@param path_prefix string
---@return boolean
local function validate_site_command(candidate, errors, path_prefix)
    if not validate.expect_table(errors, path_prefix, candidate) then
        return false
    end

    if validate.expect_string(errors, path_prefix .. ".action", candidate.action, false)
        and VALID_SITE_ACTIONS[candidate.action] ~= true
    then
        validate.push_error(errors, path_prefix .. ".action", "unsupported lifecycle action")
    end

    if candidate.request_id ~= nil then
        validate.expect_string(errors, path_prefix .. ".request_id", candidate.request_id, false)
    end

    if validate.expect_string(errors, path_prefix .. ".scope", candidate.scope, false)
        and VALID_SITE_SCOPES[candidate.scope] ~= true
    then
        validate.push_error(errors, path_prefix .. ".scope", "unsupported lifecycle scope")
    end

    if candidate.scope == "role" then
        if validate.expect_string(errors, path_prefix .. ".target_role", candidate.target_role, false)
            and not is_valid_role(candidate.target_role)
        then
            validate.push_error(errors, path_prefix .. ".target_role", "unsupported target role")
        end
    elseif candidate.target_role ~= nil then
        validate.push_error(errors, path_prefix .. ".target_role", "target_role is only valid for role scope")
    end

    if candidate.reason ~= nil then
        validate.expect_string(errors, path_prefix .. ".reason", candidate.reason, false)
    end

    return true
end

---@param candidate table
---@param errors table[]
---@param path_prefix string
---@return boolean
local function validate_host_command(candidate, errors, path_prefix)
    if not validate.expect_table(errors, path_prefix, candidate) then
        return false
    end

    if validate.expect_string(errors, path_prefix .. ".action", candidate.action, false)
        and VALID_HOST_ACTIONS[candidate.action] ~= true
    then
        validate.push_error(errors, path_prefix .. ".action", "unsupported lifecycle action")
    end

    if candidate.request_id ~= nil then
        validate.expect_string(errors, path_prefix .. ".request_id", candidate.request_id, false)
    end

    if candidate.reason ~= nil then
        validate.expect_string(errors, path_prefix .. ".reason", candidate.reason, false)
    end

    if candidate.requested_by_role ~= nil then
        if validate.expect_string(errors, path_prefix .. ".requested_by_role", candidate.requested_by_role, false)
            and not is_valid_role(candidate.requested_by_role)
        then
            validate.push_error(errors, path_prefix .. ".requested_by_role", "unsupported role")
        end
    end

    if candidate.requested_by_site ~= nil then
        if validate.expect_string(errors, path_prefix .. ".requested_by_site", candidate.requested_by_site, false)
            and not validate.is_site_id(candidate.requested_by_site)
        then
            validate.push_error(errors, path_prefix .. ".requested_by_site", "invalid site id")
        end
    end

    return true
end

---@param payload table
---@return SgcResult
function message.validate_site_request_payload(payload)
    local errors = {}
    if not net_message.validate_routed_payload(payload, errors, "site_lifecycle_request", "site_controller", false) then
        return validate.result(errors)
    end

    if validate.expect_table(errors, "payload.command", payload.command) then
        validate_site_command(payload.command, errors, "payload.command")
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param payload table
---@return SgcResult
function message.validate_host_request_payload(payload)
    local errors = {}
    if not net_message.validate_routed_payload(payload, errors, "host_lifecycle_request", constants.ROLE_SET, false) then
        return validate.result(errors)
    end

    if validate.expect_table(errors, "payload.command", payload.command) then
        validate_host_command(payload.command, errors, "payload.command")
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param target_site string
---@param command table
---@return table
function message.build_site_request_payload(target_site, command)
    return net_message.build_routed_payload("site_lifecycle_request", "site_controller", target_site, {
        command = command,
    })
end

---@param target_site string
---@param target_role SgcRole
---@param command table
---@return table
function message.build_host_request_payload(target_site, target_role, command)
    return net_message.build_routed_payload("host_lifecycle_request", target_role, target_site, {
        command = command,
    })
end

return message
