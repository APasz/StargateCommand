local command_schema = require("command.schema")
local net_message = require("net.message")
local result = require("core.result")
local validate = require("core.validate")

local message = {}

---@param payload table
---@return SgcResult
function message.validate_site_request_payload(payload)
    local errors = {}
    if not net_message.validate_routed_payload(payload, errors, "site_request", "site_controller", false) then
        return validate.result(errors)
    end

    if validate.expect_table(errors, "payload.command", payload.command) then
        local nested = command_schema.validate_site_command_request(payload.command)
        if not nested.ok then
            net_message.append_nested_validation(errors, "payload.command", nested)
        end
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param payload table
---@return SgcResult
function message.validate_gate_request_payload(payload)
    local errors = {}
    if not net_message.validate_routed_payload(payload, errors, "gate_request", "gate_controller", false) then
        return validate.result(errors)
    end

    if validate.expect_table(errors, "payload.command", payload.command) then
        local nested = command_schema.validate_gate_command(payload.command)
        if not nested.ok then
            net_message.append_nested_validation(errors, "payload.command", nested)
        end
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param payload table
---@return SgcResult
function message.validate_result_payload(payload)
    local errors = {}
    net_message.validate_operation_result(payload, errors, "command_result", function(candidate, nested_errors)
        if candidate.result ~= nil then
            validate.expect_table(nested_errors, "payload.result", candidate.result)
        end
    end)

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param target_site string
---@param command_payload SgcSiteCommandRequest
---@return table
function message.build_site_request_payload(target_site, command_payload)
    return net_message.build_routed_payload("site_request", "site_controller", target_site, {
        command = command_payload,
    })
end

---@param target_site string
---@param command_payload SgcGateCommand
---@return table
function message.build_gate_request_payload(target_site, command_payload)
    return net_message.build_routed_payload("gate_request", "gate_controller", target_site, {
        command = command_payload,
    })
end

---@param request_id string
---@param operation SgcResult
---@return table
function message.build_result_payload(request_id, operation)
    return net_message.build_operation_result("command_result", request_id, "result", operation)
end

return message
