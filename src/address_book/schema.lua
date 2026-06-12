local constants = require("core.constants")
local result = require("core.result")
local tablex = require("core.tablex")
local validate = require("core.validate")

local schema = {}

---@param visibility SgcSiteVisibility?
---@return SgcSiteVisibility
local function normalize_visibility(visibility)
    local normalized = tablex.deep_copy(visibility or {})

    if normalized.hidden_at == nil and type(normalized.hidden_from) == "table" then
        normalized.hidden_at = tablex.deep_copy(normalized.hidden_from)
    end

    normalized.hidden_from = nil

    return normalized
end

---@param book SgcAddressBook
---@return SgcAddressBook
function schema.normalize(book)
    local normalized = tablex.deep_copy(book)

    if type(normalized.sites) ~= "table" then
        return normalized
    end

    for site_id, site in pairs(normalized.sites) do
        if type(site) == "table" then
            site.id = site.id or site_id
            site.visibility = normalize_visibility(site.visibility)
        end
    end

    return normalized
end

---@param refs string[]?
---@param path string
---@param site_ids table<string, boolean>
---@param errors table[]
local function validate_refs(refs, path, site_ids, errors)
    if refs == nil then
        return
    end

    if not validate.expect_string_array(errors, path, refs) then
        return
    end

    for index, ref in ipairs(refs) do
        if ref ~= "*" and not site_ids[ref] then
            validate.push_error(errors, path .. "[" .. index .. "]", "unknown site reference")
        end
    end
end

---@param path string
---@param addresses SgcAddressSet
---@param errors table[]
local function validate_addresses(path, addresses, errors)
    if not validate.expect_table(errors, path, addresses) then
        return
    end

    local has_address = false
    for key, expected_length in pairs(constants.ADDRESS_LENGTHS) do
        local address = addresses[key]
        if address ~= nil then
            has_address = true
            if validate.expect_integer_array(errors, path .. "." .. key, address, expected_length) then
                for index, symbol in ipairs(address) do
                    if symbol < 0 then
                        validate.push_error(errors, path .. "." .. key .. "[" .. index .. "]", "symbol must be >= 0")
                    end
                end
            end
        end
    end

    if not has_address then
        validate.push_error(errors, path, "at least one address must be provided")
    end
end

---@param path string
---@param site_id string
---@param site SgcSiteEntry
---@param site_ids table<string, boolean>
---@param errors table[]
local function validate_site(path, site_id, site, site_ids, errors)
    if not validate.expect_table(errors, path, site) then
        return
    end

    validate.expect_boolean(errors, path .. ".enabled", site.enabled)
    validate.expect_boolean(errors, path .. ".allow_outbound", site.allow_outbound)

    if validate.expect_string(errors, path .. ".id", site.id, false) and site.id ~= site_id then
        validate.push_error(errors, path .. ".id", "site id must match sites table key")
    end

    validate.expect_string(errors, path .. ".name", site.name, false)

    if validate.expect_table(errors, path .. ".location", site.location) then
        validate.expect_string(errors, path .. ".location.universe", site.location.universe, false)
        validate.expect_string(errors, path .. ".location.galaxy", site.location.galaxy, false)
        validate.expect_string(errors, path .. ".location.dimension", site.location.dimension, false)
    end

    validate_addresses(path .. ".addresses", site.addresses, errors)

    if validate.expect_table(errors, path .. ".visibility", site.visibility) then
        validate.expect_boolean(errors, path .. ".visibility.listed", site.visibility.listed)
        validate_refs(site.visibility.hidden_at, path .. ".visibility.hidden_at", site_ids, errors)
        validate_refs(site.visibility.visible_from, path .. ".visibility.visible_from", site_ids, errors)
        validate_refs(site.visibility.intergalactic, path .. ".visibility.intergalactic", site_ids, errors)
    end

    if site.tags ~= nil then
        validate.expect_string_array(errors, path .. ".tags", site.tags)
    end

    if site.notes ~= nil then
        validate.expect_string(errors, path .. ".notes", site.notes, true)
    end
end

---@param book SgcAddressBook
---@return SgcResult
function schema.validate(book)
    local normalized = schema.normalize(book)
    local errors = {}

    if not validate.expect_table(errors, "address_book", normalized) then
        return validate.result(errors)
    end

    if validate.expect_integer(errors, "address_book.schema", normalized.schema) then
        if normalized.schema ~= constants.ADDRESS_BOOK_SCHEMA_VERSION then
            validate.push_error(errors, "address_book.schema", "unsupported schema version")
        end
    end

    validate.expect_integer(errors, "address_book.revision", normalized.revision)
    validate.expect_integer(errors, "address_book.updated_at", normalized.updated_at)
    validate.expect_string(errors, "address_book.updated_by", normalized.updated_by, false)

    if not validate.expect_table(errors, "address_book.sites", normalized.sites) then
        return validate.result(errors)
    end

    local site_ids = {}
    for site_id in pairs(normalized.sites) do
        if not validate.is_site_id(site_id) then
            validate.push_error(errors, "address_book.sites." .. tostring(site_id), "invalid site id")
        else
            site_ids[site_id] = true
        end
    end

    for site_id, site in pairs(normalized.sites) do
        validate_site("address_book.sites." .. site_id, site_id, site, site_ids, errors)
    end

    local validation = validate.result(errors)
    if not validation.ok then
        return validation
    end

    return result.ok(normalized)
end

return schema

