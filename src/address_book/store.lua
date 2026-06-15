local constants = require("core.constants")
local persistence = require("core.persistence")
local result = require("core.result")
local schema = require("address_book.schema")
local sample = require("address_book.sample")

local store = {}

---@param path string
---@return boolean
local function is_json_path(path)
    return type(path) == "string" and path:sub(-5) == ".json"
end

---@param path string
---@return string?
local function legacy_path_for(path)
    if not is_json_path(path) then
        return nil
    end

    return path:sub(1, -6) .. ".lua"
end

---@param path string
---@return SgcResult
local function load_path(path)
    if is_json_path(path) then
        return persistence.load_json_table(path)
    end

    return persistence.load_serialized_table(path)
end

---@param path string
---@return SgcResult
local function load_with_legacy_fallback(path)
    if persistence.exists(path) then
        local loaded = load_path(path)
        if loaded.ok then
            loaded.details = {
                path = path,
                format = is_json_path(path) and "json" or "serialized",
                migrated = false,
            }
        end
        return loaded
    end

    local legacy_path = legacy_path_for(path)
    if legacy_path == nil or not persistence.exists(legacy_path) then
        return result.err("address_book_missing", {
            path = path,
        })
    end

    local loaded = load_path(legacy_path)
    if loaded.ok then
        loaded.details = {
            path = legacy_path,
            format = "serialized",
            migrated = true,
            requested_path = path,
        }
    end
    return loaded
end

---@param path string
---@return SgcResult
function store.load(path)
    local loaded = load_with_legacy_fallback(path)
    if not loaded.ok then
        return result.err("address_book_load_failed", {
            path = loaded.details ~= nil and loaded.details.path or path,
            cause = loaded.error,
            details = loaded.details,
        })
    end

    local validation = schema.validate(loaded.value)
    if not validation.ok then
        if validation.details == nil then
            validation.details = {}
        end
        validation.details.path = loaded.details ~= nil and loaded.details.path or path
        return validation
    end

    validation.details = loaded.details
    return validation
end

---@param path string
---@param book SgcAddressBook
---@return SgcResult
function store.save(path, book)
    local validation = schema.validate(book)
    if not validation.ok then
        return validation
    end

    local saved = is_json_path(path)
        and persistence.save_json_table(path, validation.value)
        or persistence.save_serialized_table(path, validation.value)
    if not saved.ok then
        return result.err("address_book_save_failed", {
            path = path,
            cause = saved.error,
            details = saved.details,
        })
    end

    return saved
end

---@return SgcAddressBook
function store.default_book()
    local defaults = sample.create()
    defaults.schema = constants.ADDRESS_BOOK_SCHEMA_VERSION
    return defaults
end

return store
