local constants = require("core.constants")
local result = require("core.result")
local store = require("address_book.store")

local server = {}

---@param config table
---@return string
local function resolve_server_path(config)
    if config.address_book ~= nil and type(config.address_book.server_path) == "string" then
        return config.address_book.server_path
    end

    return constants.DEFAULT_ADDRESS_BOOK_SERVER_PATH
end

---@param config table
---@return SgcResult
function server.start(config)
    local path = resolve_server_path(config)
    local loaded = store.load(path)

    if loaded.ok then
        return result.ok({
            mode = "server",
            path = path,
            book = loaded.value,
        })
    end

    return result.ok({
        mode = "server",
        path = path,
        book = store.default_book(),
        warning = loaded.error,
    })
end

return server

