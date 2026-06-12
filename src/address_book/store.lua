local constants = require("core.constants")
local result = require("core.result")
local schema = require("address_book.schema")
local sample = require("address_book.sample")

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
function store.load(path)
    if not exists(path) then
        return result.err("address_book_missing", {
            path = path,
        })
    end

    local ok, loaded = pcall(dofile, path)
    if not ok then
        return result.err("address_book_load_failed", {
            path = path,
            cause = tostring(loaded),
        })
    end

    local validation = schema.validate(loaded)
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
---@param book SgcAddressBook
---@return SgcResult
function store.save(path, book)
    local validation = schema.validate(book)
    if not validation.ok then
        return validation
    end

    if fs == nil or type(fs.open) ~= "function" then
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
        return result.err("address_book_save_failed", {
            path = path,
        })
    end

    local serialized = nil
    if textutils ~= nil and type(textutils.serialize) == "function" then
        serialized = textutils.serialize(validation.value, { compact = false })
    else
        return result.err("textutils_unavailable")
    end

    handle.write("return ")
    handle.write(serialized)
    handle.write("\n")
    handle.close()

    return result.ok(true, {
        path = path,
    })
end

---@return SgcAddressBook
function store.default_book()
    local defaults = sample.create()
    defaults.schema = constants.ADDRESS_BOOK_SCHEMA_VERSION
    return defaults
end

return store

