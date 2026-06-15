local validate = require("core.validate")

local message = {}

---@param errors table[]
---@param prefix string
---@param nested_result SgcResult
function message.append_nested_validation(errors, prefix, nested_result)
    local nested_errors = nested_result.details ~= nil and nested_result.details.errors or nil
    if type(nested_errors) ~= "table" then
        validate.push_error(errors, prefix, nested_result.error or "nested validation failed")
        return
    end

    for _, nested_error in ipairs(nested_errors) do
        validate.push_error(errors, prefix .. "." .. nested_error.path, nested_error.message)
    end
end

---@param payload table
---@param errors table[]
---@param expected_kind string
---@param expected_role string|table<string, boolean>
---@param allow_request_id boolean?
---@return boolean
function message.validate_routed_payload(payload, errors, expected_kind, expected_role, allow_request_id)
    if not validate.expect_table(errors, "payload", payload) then
        return false
    end

    if validate.expect_string(errors, "payload.kind", payload.kind, false) and payload.kind ~= expected_kind then
        validate.push_error(errors, "payload.kind", "unexpected payload kind")
    end

    if validate.expect_string(errors, "payload.target_role", payload.target_role, false) then
        local role_matches = payload.target_role == expected_role
        if type(expected_role) == "table" then
            role_matches = expected_role[payload.target_role] == true
        end

        if not role_matches then
            validate.push_error(errors, "payload.target_role", "unexpected target role")
        end
    end

    if validate.expect_string(errors, "payload.target_site", payload.target_site, false)
        and not validate.is_site_id(payload.target_site)
    then
        validate.push_error(errors, "payload.target_site", "invalid site id")
    end

    if allow_request_id and payload.request_id ~= nil then
        validate.expect_string(errors, "payload.request_id", payload.request_id, false)
    end

    return true
end

---@param kind string
---@param target_role SgcRole
---@param target_site string
---@param body table?
---@return table
function message.build_routed_payload(kind, target_role, target_site, body)
    local payload = {
        kind = kind,
        target_role = target_role,
        target_site = target_site,
    }

    if type(body) == "table" then
        for key, value in pairs(body) do
            payload[key] = value
        end
    end

    return payload
end

---@param payload table
---@param errors table[]
---@param expected_kind string
---@param on_success fun(payload: table, errors: table[])?
---@return boolean
function message.validate_operation_result(payload, errors, expected_kind, on_success)
    if not validate.expect_table(errors, "payload", payload) then
        return false
    end

    if validate.expect_string(errors, "payload.kind", payload.kind, false) and payload.kind ~= expected_kind then
        validate.push_error(errors, "payload.kind", "unexpected payload kind")
    end

    validate.expect_string(errors, "payload.request_id", payload.request_id, false)
    validate.expect_boolean(errors, "payload.ok", payload.ok)

    if payload.ok == true then
        if type(on_success) == "function" then
            on_success(payload, errors)
        end
    else
        validate.expect_string(errors, "payload.error", payload.error, false)
        if payload.details ~= nil then
            validate.expect_table(errors, "payload.details", payload.details)
        end
    end

    return true
end

---@param kind string
---@param request_id string
---@param success_field string
---@param operation SgcResult
---@return table
function message.build_operation_result(kind, request_id, success_field, operation)
    if operation.ok then
        return {
            kind = kind,
            request_id = request_id,
            ok = true,
            [success_field] = operation.value,
        }
    end

    return {
        kind = kind,
        request_id = request_id,
        ok = false,
        error = operation.error,
        details = operation.details,
    }
end

---@param payload table
---@param errors table[]
---@param expected_kind string
---@param value_field string
---@param nested_validator fun(candidate: any): SgcResult
---@return boolean
function message.validate_snapshot_payload(payload, errors, expected_kind, value_field, nested_validator)
    if not validate.expect_table(errors, "payload", payload) then
        return false
    end

    if validate.expect_string(errors, "payload.kind", payload.kind, false) and payload.kind ~= expected_kind then
        validate.push_error(errors, "payload.kind", "unexpected state payload kind")
    end

    validate.expect_integer(errors, "payload.sequence", payload.sequence)
    validate.expect_integer(errors, "payload.emitted_at", payload.emitted_at)

    local value = payload[value_field]
    if validate.expect_table(errors, "payload." .. value_field, value) then
        local nested = nested_validator(value)
        if not nested.ok then
            message.append_nested_validation(errors, "payload." .. value_field, nested)
        end
    end

    return true
end

---@param kind string
---@param value_field string
---@param value table
---@param sequence integer
---@param emitted_at integer
---@return table
function message.build_snapshot_payload(kind, value_field, value, sequence, emitted_at)
    return {
        kind = kind,
        sequence = sequence,
        emitted_at = emitted_at,
        [value_field] = value,
    }
end

---@param payload table
---@param target_role SgcRole
---@param target_site string
---@param kind string
---@return boolean
function message.is_targeted_routed_payload(payload, target_role, target_site, kind)
    return type(payload) == "table"
        and payload.kind == kind
        and payload.target_role == target_role
        and payload.target_site == target_site
end

return message
