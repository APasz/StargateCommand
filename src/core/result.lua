local result = {}

---@param value any?
---@param details table?
---@return SgcResult
function result.ok(value, details)
    return {
        ok = true,
        value = value,
        details = details,
    }
end

---@param error_code string
---@param details table?
---@return SgcResult
function result.err(error_code, details)
    return {
        ok = false,
        error = error_code,
        details = details,
    }
end

---@param candidate any
---@return boolean
function result.is_result(candidate)
    return type(candidate) == "table" and type(candidate.ok) == "boolean"
end

return result

