local result = require("core.result")
local schema = require("address_book.schema")
local tablex = require("core.tablex")
local time = require("core.time")
local validate = require("core.validate")

local editor = {}

---@param updated_by string?
---@return string
local function normalize_updated_by(updated_by)
    if type(updated_by) == "string" and updated_by ~= "" then
        return updated_by
    end

    return "system"
end

---@param updated_at integer?
---@return integer
local function normalize_updated_at(updated_at)
    if validate.is_integer(updated_at) then
        return updated_at
    end

    return time.now_ms()
end

---@param book SgcAddressBook
---@return SgcResult
local function validate_book(book)
    return schema.validate(book)
end

---@param validated_book SgcResult
---@param updated_by string?
---@param updated_at integer?
---@return SgcAddressBook
local function prepare_updated_book(validated_book, updated_by, updated_at)
    local updated_book = tablex.deep_copy(validated_book.value)
    updated_book.revision = updated_book.revision + 1
    updated_book.updated_at = normalize_updated_at(updated_at)
    updated_book.updated_by = normalize_updated_by(updated_by)
    return updated_book
end

---@param book SgcAddressBook
---@param site SgcSiteEntry
---@param updated_by string?
---@param updated_at integer?
---@return SgcResult
function editor.add_site(book, site, updated_by, updated_at)
    local validated_book = validate_book(book)
    if not validated_book.ok then
        return validated_book
    end

    local site_id = type(site) == "table" and site.id or nil
    if not validate.is_site_id(site_id) then
        return result.err("address_book_invalid_site_id", {
            site_id = site_id,
        })
    end

    if validated_book.value.sites[site_id] ~= nil then
        return result.err("address_book_site_exists", {
            site_id = site_id,
        })
    end

    local updated_book = prepare_updated_book(validated_book, updated_by, updated_at)
    updated_book.sites[site_id] = tablex.deep_copy(site)

    return schema.validate(updated_book)
end

---@param book SgcAddressBook
---@param site SgcSiteEntry
---@param updated_by string?
---@param updated_at integer?
---@return SgcResult
function editor.update_site(book, site, updated_by, updated_at)
    local validated_book = validate_book(book)
    if not validated_book.ok then
        return validated_book
    end

    local site_id = type(site) == "table" and site.id or nil
    if not validate.is_site_id(site_id) then
        return result.err("address_book_invalid_site_id", {
            site_id = site_id,
        })
    end

    if validated_book.value.sites[site_id] == nil then
        return result.err("address_book_site_missing", {
            site_id = site_id,
        })
    end

    local updated_book = prepare_updated_book(validated_book, updated_by, updated_at)
    updated_book.sites[site_id] = tablex.deep_copy(site)

    return schema.validate(updated_book)
end

---@param book SgcAddressBook
---@param site_id string
---@param updated_by string?
---@param updated_at integer?
---@return SgcResult
function editor.remove_site(book, site_id, updated_by, updated_at)
    local validated_book = validate_book(book)
    if not validated_book.ok then
        return validated_book
    end

    if not validate.is_site_id(site_id) then
        return result.err("address_book_invalid_site_id", {
            site_id = site_id,
        })
    end

    if validated_book.value.sites[site_id] == nil then
        return result.err("address_book_site_missing", {
            site_id = site_id,
        })
    end

    local updated_book = prepare_updated_book(validated_book, updated_by, updated_at)
    updated_book.sites[site_id] = nil

    return schema.validate(updated_book)
end

return editor
