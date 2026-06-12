local result = require("core.result")

local validate = {}

---@param errors table[]
---@param path string
---@param message string
function validate.push_error(errors, path, message)
    errors[#errors + 1] = {
        path = path,
        message = message,
    }
end

---@param value any
---@return boolean
function validate.is_integer(value)
    return type(value) == "number" and value % 1 == 0
end

---@param value any
---@return boolean
function validate.is_site_id(value)
    return type(value) == "string" and value:match("^[a-z][a-z0-9_-]*$") ~= nil
end

---@param errors table[]
---@param path string
---@param value any
---@return boolean
function validate.expect_table(errors, path, value)
    if type(value) ~= "table" then
        validate.push_error(errors, path, "expected table")
        return false
    end
    return true
end

---@param errors table[]
---@param path string
---@param value any
---@param allow_empty boolean?
---@return boolean
function validate.expect_string(errors, path, value, allow_empty)
    if type(value) ~= "string" then
        validate.push_error(errors, path, "expected string")
        return false
    end

    if not allow_empty and value == "" then
        validate.push_error(errors, path, "expected non-empty string")
        return false
    end

    return true
end

---@param errors table[]
---@param path string
---@param value any
---@return boolean
function validate.expect_boolean(errors, path, value)
    if type(value) ~= "boolean" then
        validate.push_error(errors, path, "expected boolean")
        return false
    end
    return true
end

---@param errors table[]
---@param path string
---@param value any
---@return boolean
function validate.expect_integer(errors, path, value)
    if not validate.is_integer(value) then
        validate.push_error(errors, path, "expected integer")
        return false
    end
    return true
end

---@param errors table[]
---@param path string
---@param value any
---@param expected_length integer?
---@return boolean
function validate.expect_integer_array(errors, path, value, expected_length)
    if type(value) ~= "table" then
        validate.push_error(errors, path, "expected integer array")
        return false
    end

    if expected_length ~= nil and #value ~= expected_length then
        validate.push_error(errors, path, "unexpected array length")
        return false
    end

    for index, item in ipairs(value) do
        if not validate.is_integer(item) then
            validate.push_error(errors, path .. "[" .. index .. "]", "expected integer")
            return false
        end
    end

    return true
end

---@param errors table[]
---@param path string
---@param value any
---@return boolean
function validate.expect_string_array(errors, path, value)
    if type(value) ~= "table" then
        validate.push_error(errors, path, "expected string array")
        return false
    end

    for index, item in ipairs(value) do
        if type(item) ~= "string" or item == "" then
            validate.push_error(errors, path .. "[" .. index .. "]", "expected non-empty string")
            return false
        end
    end

    return true
end

---@param errors table[]
---@return SgcResult
function validate.result(errors)
    if #errors == 0 then
        return result.ok(true)
    end

    return result.err("validation_failed", {
        errors = errors,
    })
end

return validate

