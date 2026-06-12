local address_book_client = require("address_book.client")
local shared = require("apps.shared")

local app = {}

---@param config table
---@return SgcResult
function app.run(config)
    local logger = shared.logger("app.dial_console", config)
    logger:info("starting", {
        site = config.site,
    })

    local cached = address_book_client.start(config)
    return shared.as_result({
        role = config.role,
        address_book = cached.ok and cached.value or nil,
        note = "Dial UI is not implemented yet.",
    })
end

return app

