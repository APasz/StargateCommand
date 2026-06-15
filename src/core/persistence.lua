local json = require("core.json")
local result = require("core.result")

local persistence = {}

---@param path string
---@return string?
function persistence.dirname(path)
    local normalized = path:gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$")
end

---@param path string
---@return boolean
function persistence.exists(path)
    if fs ~= nil and type(fs.exists) == "function" then
        local ok, value = pcall(fs.exists, path)
        return ok and value == true
    end

    local handle = io.open(path, "r")
    if handle ~= nil then
        handle:close()
        return true
    end

    return false
end

---@param path string
---@return SgcResult
function persistence.read_text(path)
    if fs ~= nil and type(fs.open) == "function" then
        local handle = fs.open(path, "r")
        if handle == nil then
            return result.err("file_read_failed", {
                path = path,
            })
        end

        local ok, content = pcall(handle.readAll)
        handle.close()
        if not ok or type(content) ~= "string" then
            return result.err("file_read_failed", {
                path = path,
            })
        end

        return result.ok(content)
    end

    local handle = io.open(path, "r")
    if handle == nil then
        return result.err("file_read_failed", {
            path = path,
        })
    end

    local content = handle:read("*a")
    handle:close()
    if type(content) ~= "string" then
        return result.err("file_read_failed", {
            path = path,
        })
    end

    return result.ok(content)
end

---@return fun(value: string): any?
local function resolve_unserializer()
    if textutils ~= nil and type(textutils.unserialize) == "function" then
        return textutils.unserialize
    end

    if textutils ~= nil and type(textutils.unserialise) == "function" then
        return textutils.unserialise
    end

    return nil
end

---@param payload string
---@return SgcResult
function persistence.decode_serialized_table(payload)
    local unserialize = resolve_unserializer()
    if unserialize == nil then
        return result.err("textutils_unavailable")
    end

    local normalized = tostring(payload or ""):match("^%s*(.-)%s*$")
    normalized = normalized:gsub("^return%s+", "", 1)

    local ok, decoded = pcall(unserialize, normalized)
    if not ok or type(decoded) ~= "table" then
        return result.err("serialized_table_decode_failed")
    end

    return result.ok(decoded)
end

---@param path string
---@return SgcResult
function persistence.load_serialized_table(path)
    local content = persistence.read_text(path)
    if not content.ok then
        return content
    end

    local decoded = persistence.decode_serialized_table(content.value)
    if not decoded.ok then
        if decoded.details == nil then
            decoded.details = {}
        end
        decoded.details.path = path
        return decoded
    end

    return decoded
end

---@param path string
---@return SgcResult
function persistence.load_json_table(path)
    local content = persistence.read_text(path)
    if not content.ok then
        return content
    end

    if textutils ~= nil and type(textutils.unserializeJSON) == "function" then
        local ok, decoded = pcall(textutils.unserializeJSON, content.value)
        if ok and type(decoded) == "table" then
            return result.ok(decoded)
        end
    end

    if textutils ~= nil and type(textutils.unserialiseJSON) == "function" then
        local ok, decoded = pcall(textutils.unserialiseJSON, content.value)
        if ok and type(decoded) == "table" then
            return result.ok(decoded)
        end
    end

    local decoded = json.decode(content.value)
    if not decoded.ok or type(decoded.value) ~= "table" then
        return result.err("json_decode_failed", {
            path = path,
            cause = decoded.ok and "decoded value was not a table" or decoded.details,
        })
    end

    return decoded
end

---@param path string
---@param value table
---@return SgcResult
function persistence.save_serialized_table(path, value)
    if fs == nil or type(fs.open) ~= "function" or type(fs.makeDir) ~= "function" then
        return result.err("filesystem_unavailable", {
            path = path,
        })
    end

    if textutils == nil or type(textutils.serialize) ~= "function" then
        return result.err("textutils_unavailable", {
            path = path,
        })
    end

    local parent = persistence.dirname(path)
    if parent ~= nil and parent ~= "" and type(fs.exists) == "function" and not fs.exists(parent) then
        fs.makeDir(parent)
    end

    local handle = fs.open(path, "w")
    if handle == nil then
        return result.err("file_write_failed", {
            path = path,
        })
    end

    handle.write(textutils.serialize(value, { compact = false }))
    handle.write("\n")
    handle.close()

    return result.ok(true, {
        path = path,
    })
end

---@param path string
---@param value table
---@return SgcResult
function persistence.save_json_table(path, value)
    if fs == nil or type(fs.open) ~= "function" or type(fs.makeDir) ~= "function" then
        return result.err("filesystem_unavailable", {
            path = path,
        })
    end

    local encoded_result = json.encode(value)
    if not encoded_result.ok then
        return result.err("json_encode_failed", {
            path = path,
            cause = encoded_result.details,
        })
    end
    local encoded = encoded_result.value

    local parent = persistence.dirname(path)
    if parent ~= nil and parent ~= "" and type(fs.exists) == "function" and not fs.exists(parent) then
        fs.makeDir(parent)
    end

    local handle = fs.open(path, "w")
    if handle == nil then
        return result.err("file_write_failed", {
            path = path,
        })
    end

    handle.write(encoded)
    handle.write("\n")
    handle.close()

    return result.ok(true, {
        path = path,
    })
end

return persistence
