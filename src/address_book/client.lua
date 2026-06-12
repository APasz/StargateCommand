local constants = require("core.constants")
local result = require("core.result")
local store = require("address_book.store")

local client = {}

---@param config table
---@return SgcResult
function client.load_cached(config)
    local path = config.address_book and config.address_book.cache_path or constants.DEFAULT_ADDRESS_BOOK_CACHE_PATH
    return store.load(path)
end

---@param config table
---@param book SgcAddressBook
---@return SgcResult
function client.save_cached(config, book)
    local path = config.address_book and config.address_book.cache_path or constants.DEFAULT_ADDRESS_BOOK_CACHE_PATH
    return store.save(path, book)
end

---@param config table
---@return SgcResult
function client.start(config)
    if config.address_book.mode == "disabled" then
        return result.ok({
            mode = "disabled",
        })
    end

    local cached = client.load_cached(config)
    if cached.ok then
        return result.ok({
            mode = "client",
            cache_loaded = true,
            book = cached.value,
        })
    end

    return result.ok({
        mode = "client",
        cache_loaded = false,
        error = cached.error,
    })
end

return client

