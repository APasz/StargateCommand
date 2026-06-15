local constants = require("core.constants")
local result = require("core.result")
local validate = require("core.validate")

local schema = {}

local VALID_SITE_ACTIONS = {
    dial = true,
    disconnect = true,
    open_iris = true,
    close_iris = true,
    stop_iris = true,
    status = true,
}

local VALID_GATE_ACTIONS = {
    dial = true,
    disconnect = true,
    open_iris = true,
    close_iris = true,
    stop_iris = true,
    reset = true,
    status = true,
}

---@param address integer[]
---@return boolean
local function is_valid_address_length(address)
    for _, expected_length in pairs(constants.ADDRESS_LENGTHS) do
        if #address == expected_length then
            return true
        end

        if #address == expected_length + 1 and address[#address] == constants.POINT_OF_ORIGIN_SYMBOL then
            return true
        end
    end

    return false
end

---@param valid_actions table<string, boolean>
---@param payload table
---@param errors table[]
---@param path_prefix string
---@return boolean
local function validate_base_payload(valid_actions, payload, errors, path_prefix)
    if not validate.expect_table(errors, path_prefix, payload) then
        return false
    end

    if validate.expect_string(errors, path_prefix .. ".action", payload.action, false) then
        if not valid_actions[payload.action] then
            validate.push_error(errors, path_prefix .. ".action", "unsupported command action")
        end
    end

    if payload.request_id ~= nil then
        validate.expect_string(errors, path_prefix .. ".request_id", payload.request_id, false)
    end

    if payload.dial_mode ~= nil then
        if validate.expect_string(errors, path_prefix .. ".dial_mode", payload.dial_mode, false) then
            if not constants.DIAL_MODE_SET[payload.dial_mode] then
                validate.push_error(errors, path_prefix .. ".dial_mode", "unsupported dial mode")
            end
        end
    end

    return true
end

---@param payload table
---@param path_prefix string
---@return SgcResult
local function validate_site_command_request_impl(payload, path_prefix)
    local errors = {}
    if not validate_base_payload(VALID_SITE_ACTIONS, payload, errors, path_prefix) then
        return validate.result(errors)
    end

    if payload.action == "dial" then
        if validate.expect_string(errors, path_prefix .. ".destination_site", payload.destination_site, false) then
            if not validate.is_site_id(payload.destination_site) then
                validate.push_error(errors, path_prefix .. ".destination_site", "invalid site id")
            end
        end
    else
        if payload.destination_site ~= nil then
            validate.push_error(errors, path_prefix .. ".destination_site", "destination_site is only valid for dial")
        end

        if payload.dial_mode ~= nil then
            validate.push_error(errors, path_prefix .. ".dial_mode", "dial_mode is only valid for dial")
        end
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(payload)
end

---@param payload table
---@param path_prefix string
---@return SgcResult
local function validate_gate_command_impl(payload, path_prefix)
    local errors = {}
    if not validate_base_payload(VALID_GATE_ACTIONS, payload, errors, path_prefix) then
        return validate.result(errors)
    end

    if payload.action == "dial" then
        if validate.expect_integer_array(errors, path_prefix .. ".address", payload.address) then
            if not is_valid_address_length(payload.address) then
                validate.push_error(errors, path_prefix .. ".address", "unexpected address length")
            end

            for index, symbol in ipairs(payload.address) do
                if symbol < 0 then
                    validate.push_error(errors, path_prefix .. ".address[" .. index .. "]", "symbol must be >= 0")
                end
            end
        end

        if payload.destination_site ~= nil then
            if validate.expect_string(errors, path_prefix .. ".destination_site", payload.destination_site, false) then
                if not validate.is_site_id(payload.destination_site) then
                    validate.push_error(errors, path_prefix .. ".destination_site", "invalid site id")
                end
            end
        end
    else
        if payload.address ~= nil then
            validate.push_error(errors, path_prefix .. ".address", "address is only valid for dial")
        end

        if payload.destination_site ~= nil then
            validate.push_error(errors, path_prefix .. ".destination_site", "destination_site is only valid for dial")
        end

        if payload.dial_mode ~= nil then
            validate.push_error(errors, path_prefix .. ".dial_mode", "dial_mode is only valid for dial")
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
function schema.validate_site_command_request(payload)
    return validate_site_command_request_impl(payload, "site_command")
end

---@param payload table
---@return SgcResult
function schema.validate_gate_command(payload)
    return validate_gate_command_impl(payload, "gate_command")
end

return schema
