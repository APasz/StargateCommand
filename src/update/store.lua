local constants = require("core.constants")
local result = require("core.result")
local schema = require("update.schema")

local store = {}

---@param path string
---@return string?
local function dirname(path)
    local normalized = path:gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$")
end

---@param path string
---@return boolean
local function exists(path)
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
function store.load_optional(path)
    if not exists(path) then
        return result.ok(nil)
    end

    local ok, loaded = pcall(dofile, path)
    if not ok then
        return result.err("update_state_load_failed", {
            path = path,
            cause = tostring(loaded),
        })
    end

    local validation = schema.validate_state(loaded)
    if not validation.ok then
        if validation.details == nil then
            validation.details = {}
        end
        validation.details.path = path
        return validation
    end

    return validation
end

---@param path string
---@param state SgcUpdateState
---@return SgcResult
function store.save(path, state)
    local validation = schema.validate_state(state)
    if not validation.ok then
        return validation
    end

    if fs == nil or type(fs.open) ~= "function" or type(fs.makeDir) ~= "function" then
        return result.err("filesystem_unavailable", {
            path = path,
        })
    end

    local parent = dirname(path)
    if parent ~= nil and parent ~= "" and type(fs.exists) == "function" and not fs.exists(parent) then
        fs.makeDir(parent)
    end

    local handle = fs.open(path, "w")
    if handle == nil then
        return result.err("update_state_save_failed", {
            path = path,
        })
    end

    if textutils == nil or type(textutils.serialize) ~= "function" then
        handle.close()
        return result.err("textutils_unavailable")
    end

    handle.write("return ")
    handle.write(textutils.serialize(validation.value, { compact = false }))
    handle.write("\n")
    handle.close()

    return result.ok(true, {
        path = path,
        schema = constants.UPDATE_STATE_SCHEMA_VERSION,
    })
end

return store
